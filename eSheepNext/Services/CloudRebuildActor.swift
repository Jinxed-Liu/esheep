import CloudKit
import Foundation
import SwiftData

enum CloudRebuildError: LocalizedError, Equatable {
    case featureDisabled
    case bindingMissing
    case sessionMissing
    case sessionNotReady
    case sessionNotResumable
    case lowerMembershipGeneration(cloud: Int, worker: Int)
    case blockingIssues(Int)
    case noAuthoritativeOperations
    case farmMismatch
    case stagingValidation(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .featureDisabled: "当前构建没有启用 Development 云协作。"
        case .bindingMissing: "当前牧场没有可用于重建的 CloudKit 绑定。"
        case .sessionMissing: "找不到云缓存重建会话。"
        case .sessionNotReady: "重建结果尚未通过校验，不能切换本地缓存。"
        case .sessionNotResumable: "该重建会话不能继续执行。"
        case .lowerMembershipGeneration(let cloud, let worker): "云端成员快照 generation 为 \(cloud)，低于身份服务的 \(worker)。"
        case .blockingIssues(let count): "重建存在 \(count) 个阻断问题。"
        case .noAuthoritativeOperations: "云端 Zone 中没有可验证的权威业务操作。"
        case .farmMismatch: "重建记录与目标牧场不一致。"
        case .stagingValidation(let detail): "staging 牧场校验失败：\(detail)"
        case .cancelled: "重建已取消。"
        }
    }
}

struct CloudRebuildRootSnapshot: Codable, Sendable, Equatable {
    let farmID: UUID
    let name: String
    let ownerAccountID: UUID
    let modifiedAt: Date
}

struct CloudRebuildAssetSnapshot: Codable, Sendable, Equatable {
    let envelope: FarmAssetEnvelope
    let relativePath: String
    let cloudRecordName: String
}

struct CloudRebuildMembershipSnapshot: Codable, Sendable, Equatable {
    let farmID: UUID
    let generation: Int
    let issuedAt: Date
    let payload: Data
    let signedByAccountID: UUID
    let signedByDeviceID: UUID
    let capabilityCertificate: String
    let signature: Data
    let cloudRecordName: String
}

struct CloudRebuildBundle: Codable, Sendable, Equatable {
    let sessionID: UUID
    let farmID: UUID
    let scope: CloudDatabaseScope
    let root: CloudRebuildRootSnapshot
    let operations: [CloudOperationEnvelope]
    let assets: [CloudRebuildAssetSnapshot]
    let membershipSnapshot: CloudRebuildMembershipSnapshot?
    let deletedRecordNames: [String]
    let pageCount: Int
    let recordCount: Int
    let createdAt: Date
}

actor CloudRebuildActor {
    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private let persistence: FarmPersistenceActor
    private let worker: IdentityWorkerClient
    private let mapper = CloudRecordMapper()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    init(
        modelContainer: ModelContainer,
        persistence: FarmPersistenceActor,
        containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String,
        worker: IdentityWorkerClient = .shared
    ) {
        self.modelContainer = modelContainer
        self.persistence = persistence
        self.cloudContainer = containerIdentifier.flatMap { $0.isEmpty ? nil : CKContainer(identifier: $0) } ?? .default()
        self.worker = worker
    }

    @discardableResult
    func rebuild(farmID: UUID, scope: CloudDatabaseScope, reason: CloudRebuildReason) async throws -> UUID {
        guard CloudFeatureConfiguration.isEnabled else { throw CloudRebuildError.featureDisabled }
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID), binding.databaseScope == scope else {
            throw CloudRebuildError.bindingMissing
        }
        let sessionID = UUID()
        let relativePath = "CloudRebuild/\(sessionID.uuidString.lowercased())"
        try createSession(id: sessionID, farmID: farmID, scope: scope, reason: reason, relativePath: relativePath)
        try await persistence.setRebuildLock(farmID: farmID, enabled: true, errorCode: nil)
        startBuild(sessionID: sessionID, binding: binding)
        return sessionID
    }

    func cancel(sessionID: UUID) async throws {
        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = nil
        guard let session = try session(id: sessionID) else { throw CloudRebuildError.sessionMissing }
        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.cancelled.rawValue
            value.lastErrorCode = "cancelled"
            value.lastErrorMessage = CloudRebuildError.cancelled.localizedDescription
        }
        try await persistence.setRebuildLock(farmID: session.farmID, enabled: false, errorCode: "rebuildCancelled")
    }

    func resume(sessionID: UUID) async throws {
        guard let current = try session(id: sessionID) else { throw CloudRebuildError.sessionMissing }
        guard [.failed, .cancelled].contains(current.status) else { throw CloudRebuildError.sessionNotResumable }
        guard let binding = try await persistence.bindingSnapshot(farmID: current.farmID) else { throw CloudRebuildError.bindingMissing }
        try removeStagingContents(sessionID: sessionID)
        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.preparing.rawValue
            value.progress = 0
            value.pageCount = 0
            value.fetchedRecordCount = 0
            value.fetchedOperationCount = 0
            value.fetchedAssetCount = 0
            value.downloadedAssetCount = 0
            value.lastErrorCode = nil
            value.lastErrorMessage = nil
            value.retryAt = nil
        }
        try await persistence.setRebuildLock(farmID: current.farmID, enabled: true, errorCode: nil)
        startBuild(sessionID: sessionID, binding: binding)
    }

    func commit(sessionID: UUID) async throws -> CloudRebuildResult {
        guard let current = try session(id: sessionID) else { throw CloudRebuildError.sessionMissing }
        guard current.status == .readyToCommit else { throw CloudRebuildError.sessionNotReady }
        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.committing.rawValue
            value.progress = 0.95
        }
        do {
            let bundle = try loadBundle(sessionID: sessionID)
            guard bundle.farmID == current.farmID else { throw CloudRebuildError.farmMismatch }
            try CloudRebuildStagingBuilder.verify(bundle: bundle, workspace: workspaceURL(sessionID: sessionID))
            let commit = try await persistence.replaceConfirmedFarmCache(using: bundle)
            try CloudEngineStateDiskStore.remove(scope: bundle.scope)
            let result = CloudRebuildResult(
                sessionID: sessionID,
                farmID: current.farmID,
                fetchedRecordCount: current.fetchedRecordCount,
                fetchedOperationCount: current.fetchedOperationCount,
                fetchedAssetCount: current.fetchedAssetCount,
                appliedOperationCount: commit.appliedOperationCount,
                preservedOutboxCount: commit.preservedOutboxCount,
                highestRevision: commit.highestRevision,
                entityDigest: commit.entityDigest,
                completedAt: .now
            )
            try updateSession(sessionID) { value in
                value.statusRawValue = CloudRebuildStatus.completed.rawValue
                value.progress = 1
                value.appliedOperationCount = commit.appliedOperationCount
                value.preservedOutboxCount = commit.preservedOutboxCount
                value.highestRevision = commit.highestRevision
                value.entityDigest = commit.entityDigest
                value.completedAt = result.completedAt
                value.lastErrorCode = nil
                value.lastErrorMessage = nil
            }
            try await persistence.setRebuildLock(farmID: current.farmID, enabled: false, errorCode: nil)
            return result
        } catch {
            try? updateSession(sessionID) { value in
                value.statusRawValue = CloudRebuildStatus.failed.rawValue
                value.lastErrorCode = "commitFailed"
                value.lastErrorMessage = error.localizedDescription
            }
            try? await persistence.setRebuildLock(farmID: current.farmID, enabled: true, errorCode: "rebuildCommitFailed")
            throw error
        }
    }

    private func startBuild(sessionID: UUID, binding: CloudFarmBindingSnapshot) {
        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.build(sessionID: sessionID, binding: binding)
            } catch is CancellationError {
                try? await self.markCancelled(sessionID: sessionID)
            } catch {
                try? await self.markFailed(sessionID: sessionID, error: error)
            }
            await self.clearTask(sessionID: sessionID)
        }
    }

    private func build(sessionID: UUID, binding: CloudFarmBindingSnapshot) async throws {
        let workspace = try workspaceURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appending(path: "Assets", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.fetching.rawValue
            value.progress = 0.05
        }

        let database = binding.databaseScope == .privateDatabase ? cloudContainer.privateCloudDatabase : cloudContainer.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let fetcher = CloudZoneChangeFetcher(database: database)
        var records: [CKRecord] = []
        var deletions: [CKDatabase.RecordZoneChange.Deletion] = []
        var pageCount = 0
        for try await page in await fetcher.fetchAll(zoneID: zoneID) {
            try Task.checkCancellation()
            records.append(contentsOf: page.records)
            deletions.append(contentsOf: page.deletions)
            pageCount = page.index
            try updateSession(sessionID) { value in
                value.pageCount = page.index
                value.fetchedRecordCount = records.count
                value.progress = min(0.45, 0.08 + Double(page.index) * 0.04)
            }
        }

        let parsed = try await parseAndValidate(
            sessionID: sessionID,
            binding: binding,
            records: records,
            deletions: deletions,
            pageCount: pageCount,
            workspace: workspace
        )
        try saveBundle(parsed, sessionID: sessionID)
        _ = try CloudRebuildStagingBuilder.build(bundle: parsed, workspace: workspace)
        let blocking = try issues(sessionID: sessionID).filter { $0.severity == .blocking }.count
        guard blocking == 0 else { throw CloudRebuildError.blockingIssues(blocking) }
        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.readyToCommit.rawValue
            value.progress = 0.9
            value.fetchedOperationCount = parsed.operations.count
            value.fetchedAssetCount = parsed.assets.count
            value.downloadedAssetCount = parsed.assets.count
            value.highestRevision = parsed.operations.map(\.revision).max() ?? 0
            value.entityDigest = Self.entityDigest(parsed.operations)
        }
    }

    private func parseAndValidate(
        sessionID: UUID,
        binding: CloudFarmBindingSnapshot,
        records: [CKRecord],
        deletions: [CKDatabase.RecordZoneChange.Deletion],
        pageCount: Int,
        workspace: URL
    ) async throws -> CloudRebuildBundle {
        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.downloadingAssets.rawValue
            value.progress = 0.5
        }
        guard let rootRecord = records.first(where: { $0.recordType == CloudRecordType.farmRoot.rawValue }) else {
            try addIssue(sessionID: sessionID, farmID: binding.farmID, code: "farmRootMissing", detail: "Zone 中缺少 FarmRoot。")
            throw CloudContractError.malformedRecord
        }
        let rootValue = try mapper.farmRootValue(from: rootRecord)
        guard rootValue.farmID == binding.farmID else { throw CloudRebuildError.farmMismatch }
        let root = CloudRebuildRootSnapshot(farmID: rootValue.farmID, name: rootValue.name, ownerAccountID: rootValue.ownerAccountID, modifiedAt: rootValue.modifiedAt)

        let trust = try await persistence.cloudTrustSnapshot(farmID: binding.farmID)
        var byOperationID: [UUID: CloudOperationEnvelope] = [:]
        for record in records where record.recordType == CloudRecordType.farmOperation.rawValue || record.recordType == CloudRecordType.farmEntity.rawValue {
            do {
                let envelope = try mapper.operationEnvelope(from: record)
                guard envelope.farmID == binding.farmID else { throw CloudRebuildError.farmMismatch }
                try Self.validate(envelope: envelope, trust: trust)
                if let old = byOperationID[envelope.operationID] {
                    if envelope.revision > old.revision { byOperationID[envelope.operationID] = envelope }
                } else {
                    byOperationID[envelope.operationID] = envelope
                }
            } catch {
                try addIssue(sessionID: sessionID, farmID: binding.farmID, code: "invalidOperation", recordName: record.recordID.recordName, detail: error.localizedDescription)
            }
        }
        let operations = Self.sortedOperations(Array(byOperationID.values))
        guard !operations.isEmpty else { throw CloudRebuildError.noAuthoritativeOperations }

        var assets: [CloudRebuildAssetSnapshot] = []
        for record in records where record.recordType == CloudRecordType.farmAsset.rawValue {
            do {
                let value = try Self.assetEnvelope(record: record, mapper: mapper)
                try Self.validate(asset: value, trust: trust)
                guard let ckAsset = record[CloudRecordField.asset] as? CKAsset, let sourceURL = ckAsset.fileURL else {
                    throw CloudContractError.malformedRecord
                }
                let extensionName = value.mimeType == "image/heic" ? "heic" : "jpg"
                let relativePath = "Assets/\(value.assetID.uuidString.lowercased()).\(extensionName)"
                let destination = workspace.appending(path: relativePath)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                let digest = CloudPayloadDigest.hex(for: try Data(contentsOf: destination, options: .mappedIfSafe))
                guard digest == value.payloadDigest else { throw CloudContractError.invalidPayloadDigest }
                assets.append(CloudRebuildAssetSnapshot(envelope: value, relativePath: relativePath, cloudRecordName: record.recordID.recordName))
            } catch {
                try addIssue(sessionID: sessionID, farmID: binding.farmID, code: "invalidAsset", recordName: record.recordID.recordName, detail: error.localizedDescription)
            }
        }

        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.validating.rawValue
            value.progress = 0.72
            value.fetchedOperationCount = operations.count
            value.fetchedAssetCount = records.filter { $0.recordType == CloudRecordType.farmAsset.rawValue }.count
            value.downloadedAssetCount = assets.count
        }
        let membership = try await validateMembership(records: records, binding: binding, trust: trust)
        let bundle = CloudRebuildBundle(
            sessionID: sessionID,
            farmID: binding.farmID,
            scope: binding.databaseScope,
            root: root,
            operations: operations,
            assets: assets,
            membershipSnapshot: membership,
            deletedRecordNames: deletions.map(\.recordID.recordName).sorted(),
            pageCount: pageCount,
            recordCount: records.count,
            createdAt: .now
        )
        try CloudRebuildBundleValidator.validate(bundle)
        return bundle
    }

    private func validateMembership(records: [CKRecord], binding: CloudFarmBindingSnapshot, trust: CloudTrustSnapshot) async throws -> CloudRebuildMembershipSnapshot? {
        let candidates = records.filter { $0.recordType == CloudRecordType.farmMembershipSnapshot.rawValue }
        guard let record = candidates.max(by: { Self.integer($0[CloudRecordField.generation]) < Self.integer($1[CloudRecordField.generation]) }) else {
            return binding.databaseScope == .privateDatabase ? nil : try missingMembership()
        }
        let snapshot = try Self.membershipSnapshot(record: record, trust: trust)
        if IdentityWorkerConfiguration.baseURL != nil {
            let workerSnapshot = try await worker.farmSecuritySnapshot(farmID: binding.farmID)
            guard snapshot.generation >= workerSnapshot.generation else {
                throw CloudRebuildError.lowerMembershipGeneration(cloud: snapshot.generation, worker: workerSnapshot.generation)
            }
        }
        return snapshot
    }

    private func missingMembership() throws -> CloudRebuildMembershipSnapshot? {
        throw CloudContractError.malformedRecord
    }

    private static func validate(envelope: CloudOperationEnvelope, trust: CloudTrustSnapshot) throws {
        guard let publicKey = trust.capabilityPublicKeyPEM, !publicKey.isEmpty else { throw CloudContractError.invalidCertificate }
        let claims = try CapabilityCertificateVerifier.verify(envelope.capabilityCertificate, publicKeyPEM: publicKey)
        guard !trust.revokedCertificateIDs.contains(claims.certificateID), let deviceKey = trust.devicePublicKeys[claims.deviceID] else {
            throw CloudContractError.capabilityDenied
        }
        try CloudOperationSecurity.validate(envelope: envelope, claims: claims, devicePublicKeyX963: deviceKey)
    }

    private static func validate(asset: FarmAssetEnvelope, trust: CloudTrustSnapshot) throws {
        guard let publicKey = trust.capabilityPublicKeyPEM, !publicKey.isEmpty else { throw CloudContractError.invalidCertificate }
        let claims = try CapabilityCertificateVerifier.verify(asset.capabilityCertificate, publicKeyPEM: publicKey)
        guard claims.farmID == asset.farmID,
              claims.accountID == asset.modifiedByAccountID,
              claims.deviceID == asset.modifiedByDeviceID,
              claims.capabilities.contains(.recordProduction),
              claims.isValid(at: asset.createdAt),
              !trust.revokedCertificateIDs.contains(claims.certificateID),
              let key = trust.devicePublicKeys[claims.deviceID] else { throw CloudContractError.capabilityDenied }
        try DeviceSignatureVerifier.verify(signature: asset.signature, data: asset.canonicalSigningData, publicKeyX963: key)
    }

    private static func assetEnvelope(record: CKRecord, mapper: CloudRecordMapper) throws -> FarmAssetEnvelope {
        guard let farmText = record[CloudRecordField.farmID] as? String,
              let farmID = UUID(uuidString: farmText),
              let assetID = mapper.assetID(from: record.recordID),
              let digest = record[CloudRecordField.payloadDigest] as? String,
              let accountText = record[CloudRecordField.modifiedByAccountID] as? String,
              let accountID = UUID(uuidString: accountText),
              let deviceText = record[CloudRecordField.modifiedByDeviceID] as? String,
              let deviceID = UUID(uuidString: deviceText),
              let certificate = record[CloudRecordField.capabilityCertificate] as? String,
              let signature = record[CloudRecordField.signature] as? Data else { throw CloudContractError.malformedRecord }
        return FarmAssetEnvelope(
            farmID: farmID,
            assetID: assetID,
            entityID: (record["linkedEntityID"] as? String).flatMap(UUID.init(uuidString:)),
            sourceDigest: record[CloudRecordField.sourceDigest] as? String ?? "",
            payloadDigest: digest,
            mimeType: record[CloudRecordField.mimeType] as? String ?? "image/jpeg",
            pixelWidth: (record[CloudRecordField.pixelWidth] as? NSNumber)?.intValue ?? 0,
            pixelHeight: (record[CloudRecordField.pixelHeight] as? NSNumber)?.intValue ?? 0,
            capturedAt: record[CloudRecordField.capturedAt] as? Date,
            byteCount: (record[CloudRecordField.byteCount] as? NSNumber)?.int64Value ?? 0,
            createdAt: record[CloudRecordField.modifiedAt] as? Date ?? .distantPast,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: deviceID,
            capabilityCertificate: certificate,
            signature: signature
        )
    }

    private static func membershipSnapshot(record: CKRecord, trust: CloudTrustSnapshot) throws -> CloudRebuildMembershipSnapshot {
        guard let farmText = record[CloudRecordField.farmID] as? String,
              let farmID = UUID(uuidString: farmText),
              integer(record[CloudRecordField.generation]) >= 0,
              let issuedAt = record[CloudRecordField.issuedAt] as? Date,
              let payload = record[CloudRecordField.payload] as? Data,
              let digest = record[CloudRecordField.payloadDigest] as? String,
              digest == CloudPayloadDigest.hex(for: payload),
              let accountText = record[CloudRecordField.modifiedByAccountID] as? String,
              let accountID = UUID(uuidString: accountText),
              let deviceText = record[CloudRecordField.modifiedByDeviceID] as? String,
              let deviceID = UUID(uuidString: deviceText),
              let certificate = record[CloudRecordField.capabilityCertificate] as? String,
              let signature = record[CloudRecordField.signature] as? Data,
              let publicKey = trust.capabilityPublicKeyPEM,
              let deviceKey = trust.devicePublicKeys[deviceID] else { throw CloudContractError.malformedRecord }
        let generation = integer(record[CloudRecordField.generation])
        let claims = try CapabilityCertificateVerifier.verify(certificate, publicKeyPEM: publicKey)
        guard claims.role == .owner, claims.farmID == farmID, claims.accountID == accountID, claims.deviceID == deviceID, claims.capabilities.contains(.manageMembers), !trust.revokedCertificateIDs.contains(claims.certificateID) else {
            throw CloudContractError.capabilityDenied
        }
        let signingData = MembershipSnapshotActor.signingData(farmID: farmID, generation: generation, issuedAt: issuedAt, payloadDigest: digest, accountID: accountID, deviceID: deviceID)
        try DeviceSignatureVerifier.verify(signature: signature, data: signingData, publicKeyX963: deviceKey)
        return CloudRebuildMembershipSnapshot(farmID: farmID, generation: generation, issuedAt: issuedAt, payload: payload, signedByAccountID: accountID, signedByDeviceID: deviceID, capabilityCertificate: certificate, signature: signature, cloudRecordName: record.recordID.recordName)
    }

    private static func sortedOperations(_ operations: [CloudOperationEnvelope]) -> [CloudOperationEnvelope] {
        operations.sorted {
            let left = operationRank($0)
            let right = operationRank($1)
            if left != right { return left < right }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            if $0.revision != $1.revision { return $0.revision < $1.revision }
            return $0.operationID.uuidString < $1.operationID.uuidString
        }
    }

    private static func operationRank(_ envelope: CloudOperationEnvelope) -> Int {
        guard let payload = try? JSONDecoder.cloudRebuild.decode(FarmCommandCloudPayload.self, from: envelope.payload) else { return 900 }
        return switch payload.kind {
        case .createFarm: 0
        case .updateFarmLocation: 5
        case .createPen, .addIngredient, .createRecipe, .receiveInventory, .addSemen, .createBatch, .createBreedingProgram: 10
        case .addSheep, .addRecipeComponent: 20
        case .recordWeight, .recordWeaning, .transferSheep, .removeSheep, .restoreSheep, .recordFeed, .recordHealth, .recordReproduction, .addNote, .assignBatchMembership, .leaveBatchMembership: 30
        case .tombstoneEntity, .restoreTombstonedEntity, .resolveConflict, .recoverEntity: 40
        }
    }

    private static func entityDigest(_ operations: [CloudOperationEnvelope]) -> String {
        let text = operations.sorted { $0.operationID.uuidString < $1.operationID.uuidString }.map {
            "\($0.operationID.uuidString.lowercased()):\($0.revision):\($0.payloadDigest)"
        }.joined(separator: "\n")
        return CloudPayloadDigest.hex(for: Data(text.utf8))
    }

    private static func integer(_ value: CKRecordValue?) -> Int {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue ?? -1
    }

    private func createSession(id: UUID, farmID: UUID, scope: CloudDatabaseScope, reason: CloudRebuildReason, relativePath: String) throws {
        let context = ModelContext(modelContainer)
        for old in try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()) where old.farmID == farmID && old.status.isRunning {
            old.statusRawValue = CloudRebuildStatus.cancelled.rawValue
            old.lastErrorCode = "superseded"
            old.lastErrorMessage = "已由新的重建会话替代。"
            old.updatedAt = .now
        }
        context.insert(CloudRebuildSessionRecord(id: id, farmID: farmID, databaseScope: scope, reason: reason, stagingRelativePath: relativePath))
        try context.save()
    }

    private func session(id: UUID) throws -> CloudRebuildSessionRecord? {
        try ModelContext(modelContainer).fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first { $0.id == id }
    }

    private func issues(sessionID: UUID) throws -> [CloudRebuildIssueRecord] {
        try ModelContext(modelContainer).fetch(FetchDescriptor<CloudRebuildIssueRecord>()).filter { $0.sessionID == sessionID }
    }

    private func updateSession(_ id: UUID, mutate: (CloudRebuildSessionRecord) -> Void) throws {
        let context = ModelContext(modelContainer)
        guard let value = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: { $0.id == id }) else { throw CloudRebuildError.sessionMissing }
        mutate(value)
        value.updatedAt = .now
        try context.save()
    }

    private func addIssue(sessionID: UUID, farmID: UUID, code: String, recordName: String? = nil, detail: String) throws {
        let context = ModelContext(modelContainer)
        context.insert(CloudRebuildIssueRecord(sessionID: sessionID, farmID: farmID, severity: .blocking, code: code, recordName: recordName, detail: detail))
        try context.save()
    }

    private func workspaceURL(sessionID: UUID) throws -> URL {
        let context = ModelContext(modelContainer)
        guard let value = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: { $0.id == sessionID }) else { throw CloudRebuildError.sessionMissing }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appending(path: value.stagingRelativePath, directoryHint: .isDirectory)
    }

    private func saveBundle(_ bundle: CloudRebuildBundle, sessionID: UUID) throws {
        let data = try JSONEncoder.cloudRebuild.encode(bundle)
        let url = try workspaceURL(sessionID: sessionID).appending(path: "bundle.json")
        try data.write(to: url, options: .atomic)
    }

    private func loadBundle(sessionID: UUID) throws -> CloudRebuildBundle {
        let data = try Data(contentsOf: workspaceURL(sessionID: sessionID).appending(path: "bundle.json"))
        return try JSONDecoder.cloudRebuild.decode(CloudRebuildBundle.self, from: data)
    }

    private func removeStagingContents(sessionID: UUID) throws {
        let url = try workspaceURL(sessionID: sessionID)
        try? FileManager.default.removeItem(at: url)
    }

    private func markCancelled(sessionID: UUID) async throws {
        guard let value = try session(id: sessionID) else { return }
        try updateSession(sessionID) { session in
            session.statusRawValue = CloudRebuildStatus.cancelled.rawValue
            session.lastErrorCode = "cancelled"
            session.lastErrorMessage = CloudRebuildError.cancelled.localizedDescription
        }
        try await persistence.setRebuildLock(farmID: value.farmID, enabled: false, errorCode: "rebuildCancelled")
    }

    private func markFailed(sessionID: UUID, error: Error) async throws {
        guard let value = try session(id: sessionID) else { return }
        try updateSession(sessionID) { session in
            session.statusRawValue = CloudRebuildStatus.failed.rawValue
            session.lastErrorCode = String(describing: type(of: error))
            session.lastErrorMessage = error.localizedDescription
            session.retryAt = .now.addingTimeInterval(60)
        }
        try await persistence.setRebuildLock(farmID: value.farmID, enabled: true, errorCode: "rebuildValidationFailed")
    }

    private func clearTask(sessionID: UUID) {
        activeTasks[sessionID] = nil
    }
}

private extension JSONEncoder {
    static var cloudRebuild: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var cloudRebuild: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
