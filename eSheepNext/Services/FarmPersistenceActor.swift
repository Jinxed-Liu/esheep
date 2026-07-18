import CloudKit
import Foundation
import SwiftData

struct PendingCloudOperation: Sendable {
    let envelope: CloudOperationEnvelope
    let databaseScope: CloudDatabaseScope
}

struct CloudFarmBindingSnapshot: Sendable {
    let farmID: UUID
    let ownerAccountID: UUID
    let zoneName: String
    let zoneOwnerName: String
    let databaseScope: CloudDatabaseScope
    let shareRecordName: String?
    let state: CloudFarmBindingState
}

struct CloudTrustSnapshot: Sendable {
    let capabilityPublicKeyPEM: String?
    let devicePublicKeys: [UUID: Data]
    let revokedCertificateIDs: Set<String>
}

struct FarmCacheReplacementResult: Sendable, Equatable {
    let appliedOperationCount: Int
    let preservedOutboxCount: Int
    let highestRevision: Int
    let entityDigest: String
}

actor FarmPersistenceActor {
    private let container: ModelContainer
    private let mapper = CloudRecordMapper()

    init(container: ModelContainer) {
        self.container = container
    }

    func cloudTrustSnapshot(farmID: UUID) throws -> CloudTrustSnapshot {
        let context = ModelContext(container)
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        let revoked = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
            .filter { $0.farmID == farmID }
        return CloudTrustSnapshot(
            capabilityPublicKeyPEM: Bundle.main.object(forInfoDictionaryKey: "CAPABILITY_SIGNING_PUBLIC_KEY_PEM") as? String,
            devicePublicKeys: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.publicKeyX963) }),
            revokedCertificateIDs: Set(revoked.map(\.serverCertificateID))
        )
    }

    func setRebuildLock(farmID: UUID, enabled: Bool, errorCode: String?) throws {
        let context = ModelContext(container)
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farmID }) else {
            throw CloudSyncError.farmBindingMissing
        }
        if enabled {
            binding.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
        } else if binding.state == .rebuildingCache {
            binding.stateRawValue = CloudFarmBindingState.active.rawValue
        }
        binding.lastErrorCode = errorCode
        binding.updatedAt = .now
        try context.save()
    }

    func captureDiagnosticSnapshot(farmID: UUID, workerHealth: String, cloudAccount: String) throws {
        let context = ModelContext(container)
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farmID }) else {
            throw CloudSyncError.farmBindingMissing
        }
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == farmID }
        let assets = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        var entityParts: [String] = []
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "pen:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "sheep:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "weight:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<WeaningRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "weaning:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<BreedingProgramRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "breedingProgram:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "breedingProgramStep:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "transfer:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "feed:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "health:\($0.id):\(CloudDateText.string(from: $0.occurredAt))" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "reproduction:\($0.id):\(CloudDateText.string(from: $0.occurredAt))" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "note:\($0.id):\($0.revision)" })
        let entityDigest = CloudPayloadDigest.hex(for: Data(entityParts.sorted().joined(separator: "\n").utf8))
        let assetDigest = CloudPayloadDigest.hex(for: Data(assets.map { "\($0.id):\($0.sha256)" }.sorted().joined(separator: "\n").utf8))
        context.insert(CloudSyncDiagnosticSnapshotRecord(
            farmID: farmID,
            workerHealth: workerHealth,
            cloudAccount: cloudAccount,
            zoneName: binding.zoneName,
            databaseScope: binding.databaseScope,
            engineStateModifiedAt: CloudEngineStateDiskStore.modifiedAt(scope: binding.databaseScope),
            pendingOutboxCount: outbox.filter { $0.status == .pending || $0.status == .retryableFailure }.count,
            uploadingOutboxCount: outbox.filter { $0.status == .uploading || $0.status == .awaitingConfirmation }.count,
            blockedOutboxCount: outbox.filter { $0.status == .blockedConflict || $0.status == .rejectedPermission }.count,
            membershipGeneration: binding.securityGeneration,
            authoritativeEntityCount: entityParts.count,
            assetCount: assets.count,
            entityDigest: entityDigest,
            assetDigest: assetDigest
        ))
        try context.save()
    }

    func replaceConfirmedFarmCache(using bundle: CloudRebuildBundle) throws -> FarmCacheReplacementResult {
        try CloudRebuildBundleValidator.validate(bundle)
        let context = ModelContext(container)
        var createdAssetRoot: URL?
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == bundle.farmID }) else {
            throw CloudRebuildError.farmMismatch
        }
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == bundle.farmID }
        let pendingOutbox = outbox.filter { $0.status != .confirmed }
        let pendingIDs = Set(pendingOutbox.map(\.operationID))
        let pendingOperations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == bundle.farmID && pendingIDs.contains($0.id) }
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                return $0.id.uuidString < $1.id.uuidString
            }

        do {
            try purgeConfirmedBusinessCache(farmID: bundle.farmID, context: context)
            farm.name = bundle.root.name
            farm.ownerAccountID = bundle.root.ownerAccountID
            farm.updatedAt = bundle.root.modifiedAt

            var applied = 0
            var earliestHistoryChange: Date?
            let service = RemoteDomainApplyService()
            for envelope in bundle.operations {
                guard envelope.farmID == bundle.farmID else { throw CloudRebuildError.farmMismatch }
                switch try service.apply(envelope, context: context) {
                case .applied(let changedAt):
                    applied += 1
                    if let changedAt { earliestHistoryChange = min(earliestHistoryChange ?? changedAt, changedAt) }
                case .duplicate:
                    break
                case .conflict:
                    throw CloudRebuildError.blockingIssues(1)
                }
                context.insert(CloudOperationReceipt(
                    farmID: bundle.farmID,
                    operationID: envelope.operationID,
                    recordName: mapper.recordName(for: envelope.operationID),
                    serverChangeTag: nil,
                    databaseScope: bundle.scope
                ))
            }

            for operation in pendingOperations {
                guard let entityID = operation.entityID else { continue }
                let envelope = CloudOperationEnvelope(
                    farmID: operation.farmID,
                    entityID: entityID,
                    entityType: operation.entityType,
                    schemaVersion: operation.schemaVersion,
                    revision: operation.resultingRevision,
                    baseRevision: operation.baseRevision,
                    operationID: operation.id,
                    modifiedAt: operation.occurredAt,
                    modifiedByAccountID: operation.accountID,
                    modifiedByDeviceID: operation.modifiedByDeviceID ?? UUID(),
                    payload: operation.payload,
                    payloadDigest: operation.payloadDigest,
                    capabilityCertificate: operation.capabilityCertificate,
                    operationSignature: operation.operationSignature ?? Data(),
                    deletedAt: nil
                )
                switch try service.apply(envelope, context: context) {
                case .applied(let changedAt):
                    if let changedAt { earliestHistoryChange = min(earliestHistoryChange ?? changedAt, changedAt) }
                case .duplicate:
                    break
                case .conflict:
                    throw CloudRebuildError.blockingIssues(1)
                }
            }

            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let stagingRoot = support.appending(path: "CloudRebuild/\(bundle.sessionID.uuidString.lowercased())", directoryHint: .isDirectory)
            let assetRoot = support.appending(path: "CloudAssets/\(bundle.farmID.uuidString.lowercased())/\(bundle.sessionID.uuidString.lowercased())", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
            createdAssetRoot = assetRoot
            for snapshot in bundle.assets {
                let source = stagingRoot.appending(path: snapshot.relativePath)
                let fileName = source.lastPathComponent
                let destination = assetRoot.appending(path: fileName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                let relativePath = "CloudAssets/\(bundle.farmID.uuidString.lowercased())/\(bundle.sessionID.uuidString.lowercased())/\(fileName)"
                let photo = PhotoAssetRecord(
                    id: snapshot.envelope.assetID,
                    farmID: bundle.farmID,
                    sheepID: snapshot.envelope.entityID,
                    legacySourceKey: "cloud:\(snapshot.cloudRecordName)",
                    originalEarTag: "",
                    relativePath: relativePath,
                    sha256: snapshot.envelope.payloadDigest,
                    mimeType: snapshot.envelope.mimeType
                )
                photo.sourceSHA256 = snapshot.envelope.sourceDigest
                photo.cloudPixelWidth = snapshot.envelope.pixelWidth
                photo.cloudPixelHeight = snapshot.envelope.pixelHeight
                photo.capturedAt = snapshot.envelope.capturedAt
                photo.cloudRecordName = snapshot.cloudRecordName
                photo.isCloudAuthoritative = true
                context.insert(photo)
            }

            if let snapshot = bundle.membershipSnapshot {
                context.insert(FarmMembershipSnapshotRecord(
                    farmID: snapshot.farmID,
                    generation: snapshot.generation,
                    issuedAt: snapshot.issuedAt,
                    payload: snapshot.payload,
                    signedByAccountID: snapshot.signedByAccountID,
                    signedByDeviceID: snapshot.signedByDeviceID,
                    capabilityCertificate: snapshot.capabilityCertificate,
                    signature: snapshot.signature
                ))
            }
            try FarmHistoryRebuilder().rebuild(farmID: bundle.farmID, context: context, from: earliestHistoryChange ?? .distantPast)
            try context.save()
            return FarmCacheReplacementResult(
                appliedOperationCount: applied,
                preservedOutboxCount: pendingOutbox.count,
                highestRevision: bundle.operations.map(\.revision).max() ?? 0,
                entityDigest: Self.entityDigest(bundle.operations)
            )
        } catch {
            context.rollback()
            if let createdAssetRoot {
                try? FileManager.default.removeItem(at: createdAssetRoot)
            }
            throw error
        }
    }

    func pendingRecordIDs() throws -> [(CKRecord.ID, CloudDatabaseScope)] {
        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
            .filter {
                [.pending, .retryableFailure, .uploading, .awaitingConfirmation].contains($0.status) &&
                ($0.nextRetryAt == nil || $0.nextRetryAt! <= .now)
            }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        let operationByID = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0) })
        var bindingValues: [UUID: (zoneName: String, ownerName: String, scope: CloudDatabaseScope)] = [:]
        for binding in bindings where binding.state == .active {
            bindingValues[binding.farmID] = (binding.zoneName, binding.zoneOwnerName, binding.databaseScope)
        }
        var result: [(CKRecord.ID, CloudDatabaseScope)] = []
        var seen = Set<String>()
        for item in outbox {
            guard let binding = bindingValues[item.farmID] else { continue }
            let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.ownerName)
            var recordNames = [mapper.recordName(for: item.operationID)]
            if let entityID = item.entityID { recordNames.append(mapper.entityRecordName(for: entityID)) }
            for recordName in recordNames {
                let key = "\(binding.scope.rawValue)|\(zoneID.zoneName)|\(recordName)"
                if seen.insert(key).inserted {
                    result.append((CKRecord.ID(recordName: recordName, zoneID: zoneID), binding.scope))
                }
            }
            if operationByID[item.operationID]?.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
               let entityID = item.entityID {
                let recordName = mapper.tombstoneRecordName(for: entityID)
                let key = "\(binding.scope.rawValue)|\(zoneID.zoneName)|\(recordName)"
                if seen.insert(key).inserted {
                    result.append((CKRecord.ID(recordName: recordName, zoneID: zoneID), binding.scope))
                }
            }
        }
        return result
    }

    func bindingSnapshot(farmID: UUID) throws -> CloudFarmBindingSnapshot? {
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        guard let binding = bindings.first(where: { $0.farmID == farmID }) else { return nil }
        return CloudFarmBindingSnapshot(
            farmID: binding.farmID,
            ownerAccountID: binding.ownerAccountID,
            zoneName: binding.zoneName,
            zoneOwnerName: binding.zoneOwnerName,
            databaseScope: binding.databaseScope,
            shareRecordName: binding.shareRecordName,
            state: binding.state
        )
    }

    func isCloudPreparationReady(farmID: UUID) throws -> Bool {
        let context = ModelContext(container)
        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farmID }
        guard operations.allSatisfy({
            $0.schemaVersion >= 2 &&
            $0.entityID != nil &&
            !$0.payload.isEmpty &&
            CloudPayloadDigest.hex(for: $0.payload) == $0.payloadDigest
        }) else { return false }
        let targets = Set(operations.compactMap(\.entityID))
        var requiredTargets = Set<UUID>()
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<WeaningRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<BreedingProgramRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<FeedRecipeRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<SemenRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == farmID }.map(\.id))
        return requiredTargets.isSubset(of: targets)
    }

    /// 云端准入必须在服务层执行：Development 只接收固定测试牧场，
    /// Staging/Production 只接收正式新建牧场，旧版迁移牧场永久保持 localOnly。
    func requireCloudAdmission(farmID: UUID, environment: AppEnvironment) throws {
        let context = ModelContext(container)
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        guard let farm = farms.first(where: { $0.id == farmID }) else {
            throw CloudSyncError.inactiveFarm
        }
        let request = CloudAdmissionRequest(
            environment: environment,
            role: farm.role,
            membershipIsActive: farm.membershipStatusRawValue == "active",
            isDeleted: farm.deletedAt != nil,
            isDevelopmentTestFarm: farm.isDevelopmentTestFarm,
            developmentSeed: farm.developmentSeed,
            isLocalOnlyMigration: farm.isLocalOnlyMigration
        )
        do {
            try CloudAdmissionPolicy.validate(request)
        } catch let denial as CloudAdmissionDenial {
            switch denial {
            case .developmentTestFarmRequired:
                throw CloudSyncError.developmentTestFarmRequired
            case .formalFarmRequired:
                throw CloudSyncError.formalFarmRequired
            case .localOnlyMigration:
                throw CloudSyncError.localOnlyMigration
            case .ownerRequired:
                throw CloudSyncError.ownerRequired
            case .deletedFarm, .inactiveMembership:
                throw CloudSyncError.inactiveFarm
            }
        }
    }

    /// 保留现有测试调用面，语义明确固定为 Development。
    func requireDevelopmentTestFarm(farmID: UUID) throws {
        try requireCloudAdmission(farmID: farmID, environment: .development)
    }

    func stageAcceptedSharedFarm(farmID: UUID, temporaryOwnerAccountID: UUID) throws {
        let context = ModelContext(container)
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        guard !farms.contains(where: { $0.id == farmID }) else { return }
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: temporaryOwnerAccountID,
            name: "待加入的共享牧场",
            role: .worker
        )
        farm.membershipStatusRawValue = FarmMembershipStatus.pendingOwnerConfirmation.rawValue
        context.insert(farm)
        try context.save()
    }

    func record(for recordID: CKRecord.ID, scope: CloudDatabaseScope, device: DeviceIdentityActor) async -> CKRecord? {
        do {
            let context = ModelContext(container)
            let operations = try context.fetch(FetchDescriptor<DomainOperation>())
            let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
            let operationID: UUID?
            if let direct = mapper.operationID(from: recordID) {
                operationID = direct
            } else if let entityID = mapper.entityID(from: recordID) {
                operationID = outbox
                    .filter { $0.entityID == entityID && $0.status != .confirmed }
                    .compactMap { item in operations.first(where: { $0.id == item.operationID }) }
                    .max(by: {
                        if $0.resultingRevision != $1.resultingRevision { return $0.resultingRevision < $1.resultingRevision }
                        return $0.createdAt < $1.createdAt
                    })?.id
            } else if let entityID = mapper.tombstoneEntityID(from: recordID) {
                operationID = operations
                    .filter { $0.entityID == entityID && $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue }
                    .max(by: { $0.createdAt < $1.createdAt })?.id
            } else {
                operationID = nil
            }
            guard let operationID else { return nil }
            guard let operation = operations.first(where: { $0.id == operationID }),
                  let item = outbox.first(where: { $0.operationID == operationID }),
                  let entityID = operation.entityID else { return nil }
            let certificates = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
            guard let certificate = certificates
                .filter({ $0.farmID == operation.farmID && $0.accountID == operation.accountID && $0.isUsable })
                .max(by: { $0.expiresAt < $1.expiresAt }) else {
                item.statusRawValue = OutboxStatus.rejectedPermission.rawValue
                item.errorMessage = "没有当前牧场可用的能力证书。"
                try context.save()
                return nil
            }
            let identity = try await device.identity()
            let tombstone = try context.fetch(FetchDescriptor<TombstoneRecord>()).first(where: { $0.operationID == operation.id })
            var envelope = CloudOperationEnvelope(
                farmID: operation.farmID,
                entityID: entityID,
                entityType: operation.entityType,
                schemaVersion: operation.schemaVersion,
                revision: operation.resultingRevision,
                baseRevision: operation.baseRevision,
                operationID: operation.id,
                modifiedAt: operation.occurredAt,
                modifiedByAccountID: operation.accountID,
                modifiedByDeviceID: identity.deviceID,
                payload: operation.payload,
                payloadDigest: operation.payloadDigest,
                capabilityCertificate: certificate.certificateJWS,
                operationSignature: Data(),
                deletedAt: tombstone?.deletedAt
            )
            let signature = try await device.sign(envelope.canonicalSigningData)
            envelope = CloudOperationEnvelope(
                farmID: envelope.farmID,
                entityID: envelope.entityID,
                entityType: envelope.entityType,
                schemaVersion: envelope.schemaVersion,
                revision: envelope.revision,
                baseRevision: envelope.baseRevision,
                operationID: envelope.operationID,
                modifiedAt: envelope.modifiedAt,
                modifiedByAccountID: envelope.modifiedByAccountID,
                modifiedByDeviceID: envelope.modifiedByDeviceID,
                payload: envelope.payload,
                payloadDigest: envelope.payloadDigest,
                capabilityCertificate: envelope.capabilityCertificate,
                operationSignature: signature,
                deletedAt: envelope.deletedAt
            )
            operation.modifiedByDeviceID = identity.deviceID
            operation.capabilityCertificate = certificate.certificateJWS
            operation.operationSignature = signature
            item.operationSignature = signature
            item.capabilityCertificate = certificate.certificateJWS
            item.statusRawValue = OutboxStatus.uploading.rawValue
            item.lastAttemptAt = .now
            item.attemptCount += 1
            try context.save()
            if mapper.entityID(from: recordID) != nil {
                return mapper.entityRecord(from: envelope, zoneID: recordID.zoneID)
            }
            if recordID.recordName.hasPrefix("tombstone_"), let tombstone, let operationID = tombstone.operationID {
                let value = FarmTombstoneEnvelope(
                    tombstoneID: tombstone.id,
                    farmID: tombstone.farmID,
                    entityType: tombstone.entityType,
                    entityID: tombstone.entityID,
                    revision: tombstone.revision,
                    deletedAt: tombstone.deletedAt,
                    deletedByAccountID: tombstone.deletedByAccountID,
                    reason: tombstone.reason,
                    operationID: operationID,
                    restoresTombstoneID: nil
                )
                return mapper.tombstoneRecord(envelope: value, certificate: certificate.certificateJWS, signature: signature, zoneID: recordID.zoneID)
            }
            return mapper.operationRecord(from: envelope, zoneID: recordID.zoneID)
        } catch {
            return nil
        }
    }

    func confirmSavedRecords(_ records: [CKRecord], scope: CloudDatabaseScope) throws {
        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        var receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>())
        var affectedOperationIDs = Set<UUID>()
        for record in records {
            let operationID = mapper.operationID(from: record.recordID) ??
                ((record[CloudRecordField.operationID] as? String).flatMap(UUID.init(uuidString:)))
            guard let operationID,
                  let item = outbox.first(where: { $0.operationID == operationID }) else { continue }
            affectedOperationIDs.insert(operationID)
            if !receipts.contains(where: { $0.operationID == operationID && $0.recordName == record.recordID.recordName }) {
                let receipt = CloudOperationReceipt(
                    farmID: item.farmID,
                    operationID: operationID,
                    recordName: record.recordID.recordName,
                    serverChangeTag: record.recordChangeTag,
                    databaseScope: scope
                )
                context.insert(receipt)
                receipts.append(receipt)
            }
        }
        for operationID in affectedOperationIDs {
            guard let item = outbox.first(where: { $0.operationID == operationID }),
                  let operation = operations.first(where: { $0.id == operationID }) else { continue }
            var requiredNames: Set<String> = [mapper.recordName(for: operationID)]
            if let entityID = operation.entityID {
                let latestOperation = operations
                    .filter { $0.farmID == operation.farmID && $0.entityID == entityID }
                    .max(by: {
                        if $0.resultingRevision != $1.resultingRevision { return $0.resultingRevision < $1.resultingRevision }
                        return $0.createdAt < $1.createdAt
                    })
                if latestOperation?.id == operationID {
                    requiredNames.insert(mapper.entityRecordName(for: entityID))
                }
            }
            if operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
               let entityID = operation.entityID {
                requiredNames.insert(mapper.tombstoneRecordName(for: entityID))
            }
            let confirmedNames = Set(receipts.filter { $0.operationID == operationID }.map(\.recordName))
            if requiredNames.isSubset(of: confirmedNames) {
                item.statusRawValue = OutboxStatus.confirmed.rawValue
                item.errorMessage = nil
                item.cloudRecordName = mapper.recordName(for: operationID)
            } else {
                item.statusRawValue = OutboxStatus.awaitingConfirmation.rawValue
            }
        }
        try context.save()
    }

    func markFailedRecords(_ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave]) throws {
        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
        for failure in failures {
            let operationID = mapper.operationID(from: failure.record.recordID) ??
                ((failure.record[CloudRecordField.operationID] as? String).flatMap(UUID.init(uuidString:)))
            guard let operationID,
                  let item = outbox.first(where: { $0.operationID == operationID }) else { continue }
            let classification = CloudErrorClassifier.classify(failure.error)
            item.statusRawValue = classification.status.rawValue
            item.errorMessage = classification.message
            item.nextRetryAt = classification.retryAt
        }
        try context.save()
    }

    func ingest(_ records: [CKRecord], scope: CloudDatabaseScope) async throws {
        let context = ModelContext(container)
        try ingestFarmRoots(records, scope: scope, context: context)
        try ingestFarmAssets(records, context: context)
        let existingReceipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>())
        var receivedOperationIDs = Set(existingReceipts.map(\.operationID))
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        let revokedCertificates = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        let certificatePublicKey = Bundle.main.object(forInfoDictionaryKey: "CAPABILITY_SIGNING_PUBLIC_KEY_PEM") as? String
        var historyRebuilds: [UUID: Date] = [:]
        for record in records where record.recordType == CloudRecordType.farmOperation.rawValue || record.recordType == CloudRecordType.farmEntity.rawValue {
            do {
                let envelope = try mapper.operationEnvelope(from: record)
                guard CloudPayloadDigest.hex(for: envelope.payload) == envelope.payloadDigest else {
                    throw CloudContractError.invalidPayloadDigest
                }
                if receivedOperationIDs.contains(envelope.operationID) { continue }
                guard let certificatePublicKey, !certificatePublicKey.isEmpty else {
                    try quarantine(envelope: envelope, recordName: record.recordID.recordName, reason: "capabilityPublicKeyMissing", context: context)
                    continue
                }
                let claims = try CapabilityCertificateVerifier.verify(envelope.capabilityCertificate, publicKeyPEM: certificatePublicKey)
                if revokedCertificates.contains(where: { $0.farmID == envelope.farmID && $0.serverCertificateID == claims.certificateID }) {
                    try quarantine(envelope: envelope, recordName: record.recordID.recordName, reason: "capabilityRevoked", context: context)
                    continue
                }
                guard let device = devices.first(where: { $0.id == claims.deviceID && $0.accountID == claims.accountID }) else {
                    try quarantine(envelope: envelope, recordName: record.recordID.recordName, reason: "devicePublicKeyMissing", context: context)
                    continue
                }
                try CloudOperationSecurity.validate(envelope: envelope, claims: claims, devicePublicKeyX963: device.publicKeyX963)
                let outcome = try RemoteDomainApplyService().apply(envelope, context: context)
                switch outcome {
                case .applied(let changedAt):
                    if let changedAt {
                        historyRebuilds[envelope.farmID] = min(historyRebuilds[envelope.farmID] ?? changedAt, changedAt)
                    }
                case .duplicate:
                    break
                case .conflict(let localRevision):
                    let localPayload = try context.fetch(FetchDescriptor<DomainOperation>())
                        .filter { $0.farmID == envelope.farmID && $0.entityID == envelope.entityID }
                        .max(by: { $0.resultingRevision < $1.resultingRevision })?.payload ?? Data()
                    let conflict = SyncConflictRecord(
                        farmID: envelope.farmID,
                        entityID: envelope.entityID,
                        entityType: envelope.entityType,
                        localRevision: localRevision,
                        remoteRevision: envelope.revision,
                        localPayload: localPayload,
                        remotePayload: envelope.payload,
                        remoteAccountID: envelope.modifiedByAccountID,
                        remoteDeviceID: envelope.modifiedByDeviceID,
                        reasonCode: "baseRevisionMismatch"
                    )
                    conflict.remoteEnvelopeData = try JSONEncoder.cloud.encode(envelope)
                    context.insert(conflict)
                    continue
                }
                context.insert(CloudOperationReceipt(
                    farmID: envelope.farmID,
                    operationID: envelope.operationID,
                    recordName: record.recordID.recordName,
                    serverChangeTag: record.recordChangeTag,
                    databaseScope: scope
                ))
                receivedOperationIDs.insert(envelope.operationID)
            } catch {
                context.insert(SecurityIncidentRecord(
                    farmID: nil,
                    incidentType: "malformedCloudOperation",
                    recordName: record.recordID.recordName,
                    detail: error.localizedDescription
                ))
            }
        }
        for (farmID, changedAt) in historyRebuilds {
            try FarmHistoryRebuilder().rebuild(farmID: farmID, context: context, from: changedAt)
        }
        try context.save()
        let validator = MembershipSnapshotActor(modelContainer: container, persistence: self)
        for record in records where record.recordType == CloudRecordType.farmMembershipSnapshot.rawValue {
            do {
                _ = try await validator.validate(record)
            } catch {
                let incidentContext = ModelContext(container)
                incidentContext.insert(SecurityIncidentRecord(
                    farmID: CloudZoneName.farmID(from: record.recordID.zoneID.zoneName),
                    incidentType: error is CloudContractError && (error as? CloudContractError) == .membershipSnapshotRollback ? "membershipSnapshotRollback" : "invalidMembershipSnapshot",
                    recordName: record.recordID.recordName,
                    detail: error.localizedDescription
                ))
                try incidentContext.save()
            }
        }
    }

    private func ingestFarmAssets(_ records: [CKRecord], context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
        let transfers = try context.fetch(FetchDescriptor<CloudAssetTransfer>())
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        let revokedCertificates = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        let certificatePublicKey = Bundle.main.object(forInfoDictionaryKey: "CAPABILITY_SIGNING_PUBLIC_KEY_PEM") as? String
        for record in records where record.recordType == CloudRecordType.farmAsset.rawValue {
            guard let farmText = record[CloudRecordField.farmID] as? String,
                  let farmID = UUID(uuidString: farmText),
                  let assetID = mapper.assetID(from: record.recordID),
                  let digest = record[CloudRecordField.payloadDigest] as? String,
                  let accountText = record[CloudRecordField.modifiedByAccountID] as? String,
                  let accountID = UUID(uuidString: accountText),
                  let deviceText = record[CloudRecordField.modifiedByDeviceID] as? String,
                  let deviceID = UUID(uuidString: deviceText),
                  let certificate = record[CloudRecordField.capabilityCertificate] as? String,
                  let signature = record[CloudRecordField.signature] as? Data else {
                context.insert(SecurityIncidentRecord(farmID: nil, incidentType: "malformedFarmAsset", recordName: record.recordID.recordName, detail: "照片记录缺少牧场、资产或校验字段。"))
                continue
            }
            let sourceDigest = record[CloudRecordField.sourceDigest] as? String ?? ""
            let mimeType = record[CloudRecordField.mimeType] as? String ?? "image/jpeg"
            let byteCount = (record[CloudRecordField.byteCount] as? NSNumber)?.int64Value ?? 0
            let linkedID = (record["linkedEntityID"] as? String).flatMap(UUID.init(uuidString:))
            let envelope = FarmAssetEnvelope(
                farmID: farmID,
                assetID: assetID,
                entityID: linkedID,
                sourceDigest: sourceDigest,
                payloadDigest: digest,
                mimeType: mimeType,
                pixelWidth: (record[CloudRecordField.pixelWidth] as? NSNumber)?.intValue ?? 0,
                pixelHeight: (record[CloudRecordField.pixelHeight] as? NSNumber)?.intValue ?? 0,
                capturedAt: record[CloudRecordField.capturedAt] as? Date,
                byteCount: byteCount,
                createdAt: record[CloudRecordField.modifiedAt] as? Date ?? .distantPast,
                modifiedByAccountID: accountID,
                modifiedByDeviceID: deviceID,
                capabilityCertificate: certificate,
                signature: signature
            )
            do {
                guard let certificatePublicKey, !certificatePublicKey.isEmpty else { throw CloudContractError.invalidCertificate }
                let claims = try CapabilityCertificateVerifier.verify(certificate, publicKeyPEM: certificatePublicKey)
                guard claims.farmID == farmID, claims.accountID == accountID, claims.deviceID == deviceID,
                      claims.capabilities.contains(.recordProduction), claims.isValid(at: envelope.createdAt),
                      !revokedCertificates.contains(where: { $0.farmID == farmID && $0.serverCertificateID == claims.certificateID }),
                      let device = devices.first(where: { $0.id == deviceID && $0.accountID == accountID }) else {
                    throw CloudContractError.capabilityDenied
                }
                try DeviceSignatureVerifier.verify(signature: signature, data: envelope.canonicalSigningData, publicKeyX963: device.publicKeyX963)
            } catch {
                context.insert(SecurityIncidentRecord(farmID: farmID, incidentType: "invalidFarmAssetSignature", recordName: record.recordID.recordName, accountID: accountID, deviceID: deviceID, detail: error.localizedDescription))
                continue
            }
            let asset: PhotoAssetRecord
            if let value = existing.first(where: { $0.id == assetID }) {
                asset = value
            } else {
                asset = PhotoAssetRecord(id: assetID, farmID: farmID, sheepID: linkedID, legacySourceKey: "cloud:\(record.recordID.recordName)", originalEarTag: "", relativePath: "", sha256: digest, mimeType: mimeType)
                context.insert(asset)
            }
            asset.sourceSHA256 = sourceDigest
            asset.cloudPixelWidth = (record[CloudRecordField.pixelWidth] as? NSNumber)?.intValue ?? 0
            asset.cloudPixelHeight = (record[CloudRecordField.pixelHeight] as? NSNumber)?.intValue ?? 0
            asset.capturedAt = record[CloudRecordField.capturedAt] as? Date
            asset.cloudRecordName = record.recordID.recordName
            asset.isCloudAuthoritative = true
            if asset.relativePath.isEmpty && !transfers.contains(where: { $0.assetID == assetID && $0.direction == .download && $0.status != .failed }) {
                context.insert(CloudAssetTransfer(farmID: farmID, assetID: assetID, localRelativePath: "", payloadDigest: digest, byteCount: byteCount, direction: .download, sourceDigest: sourceDigest))
            }
        }
    }

    private func ingestFarmRoots(_ records: [CKRecord], scope: CloudDatabaseScope, context: ModelContext) throws {
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        let accounts = try context.fetch(FetchDescriptor<AccountProfile>())
        let localAccountID = accounts.first?.effectiveAccountID
        let memberships = try context.fetch(FetchDescriptor<FarmMembershipBinding>())
        for record in records where record.recordType == CloudRecordType.farmRoot.rawValue {
            do {
                let root = try mapper.farmRootValue(from: record)
                if let farm = farms.first(where: { $0.id == root.farmID }) {
                    if farm.name == "待加入的共享牧场" {
                        farm.name = root.name
                        farm.ownerAccountID = root.ownerAccountID
                        farm.updatedAt = root.modifiedAt
                        continue
                    }
                    if farm.name != root.name || farm.ownerAccountID != root.ownerAccountID {
                        context.insert(SecurityIncidentRecord(
                            farmID: root.farmID,
                            incidentType: "unsignedFarmRootModification",
                            recordName: record.recordID.recordName,
                            detail: "检测到未通过签名操作修改牧场根记录，未覆盖本地牧场资料。"
                        ))
                    }
                    continue
                }
                let role = localAccountID.flatMap { accountID in
                    memberships.first(where: { $0.farmID == root.farmID && $0.accountID == accountID })?.role
                } ?? (scope == .privateDatabase ? .owner : .worker)
                context.insert(FarmRecord(
                    id: root.farmID,
                    ownerAccountID: root.ownerAccountID,
                    name: root.name,
                    role: role,
                    createdAt: root.modifiedAt,
                    updatedAt: root.modifiedAt
                ))
            } catch {
                context.insert(SecurityIncidentRecord(
                    farmID: CloudZoneName.farmID(from: record.recordID.zoneID.zoneName),
                    incidentType: "malformedFarmRoot",
                    recordName: record.recordID.recordName,
                    detail: error.localizedDescription
                ))
            }
        }
    }

    private func quarantine(envelope: CloudOperationEnvelope, recordName: String, reason: String, context: ModelContext) throws {
        let conflict = SyncConflictRecord(
            farmID: envelope.farmID,
            entityID: envelope.entityID,
            entityType: envelope.entityType,
            localRevision: 0,
            remoteRevision: envelope.revision,
            localPayload: Data(),
            remotePayload: envelope.payload,
            remoteAccountID: envelope.modifiedByAccountID,
            remoteDeviceID: envelope.modifiedByDeviceID,
            reasonCode: reason,
            status: .quarantined
        )
        conflict.remoteEnvelopeData = try JSONEncoder.cloud.encode(envelope)
        context.insert(conflict)
        context.insert(SecurityIncidentRecord(
            farmID: envelope.farmID,
            incidentType: reason,
            recordName: recordName,
            accountID: envelope.modifiedByAccountID,
            deviceID: envelope.modifiedByDeviceID,
            detail: "云端操作已隔离，未覆盖本地数据。"
        ))
    }

    func recordUnexpectedDeletions(_ deletions: [CKDatabase.RecordZoneChange.Deletion]) throws {
        let context = ModelContext(container)
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
        let assets = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
        let transfers = try context.fetch(FetchDescriptor<CloudAssetTransfer>())
        for deletion in deletions where deletion.recordType == CloudRecordType.farmEntity.rawValue || deletion.recordType == CloudRecordType.farmAsset.rawValue {
            var farmID = CloudZoneName.farmID(from: deletion.recordID.zoneID.zoneName)
            var entityID: UUID?
            if deletion.recordType == CloudRecordType.farmEntity.rawValue,
               let deletedEntityID = mapper.entityID(from: deletion.recordID) {
                entityID = deletedEntityID
                farmID = operations.first(where: { $0.entityID == deletedEntityID })?.farmID ?? farmID
            } else if let assetID = mapper.assetID(from: deletion.recordID) {
                entityID = assetID
                farmID = assets.first(where: { $0.id == assetID })?.farmID ?? farmID
            }
            if let farmID, let entityID, tombstones.contains(where: { $0.farmID == farmID && $0.entityID == entityID && $0.restoredAt == nil }) {
                continue
            }
            context.insert(SecurityIncidentRecord(
                farmID: farmID,
                incidentType: "unexpectedHardDelete",
                recordName: deletion.recordID.recordName,
                detail: "检测到没有合法 Tombstone 的 CloudKit 实体硬删除，未删除本地数据。"
            ))
            if deletion.recordType == CloudRecordType.farmAsset.rawValue,
               let farmID, let assetID = entityID,
               let asset = assets.first(where: { $0.id == assetID && $0.recoveryRecordName != nil }),
               !transfers.contains(where: { $0.assetID == assetID && $0.direction == .recoveryRestore && $0.status != .completed }) {
                context.insert(CloudAssetTransfer(farmID: farmID, assetID: assetID, localRelativePath: asset.relativePath, payloadDigest: asset.sha256, byteCount: 0, direction: .recoveryRestore, sourceDigest: asset.sourceSHA256))
            }
        }
        try context.save()
    }

    func saveEngineState(_ serialization: CKSyncEngine.State.Serialization, scope: CloudDatabaseScope) throws {
        let encoded = try JSONEncoder().encode(serialization)
        try CloudEngineStateDiskStore.save(encoded, scope: scope)
        let context = ModelContext(container)
        let states = try context.fetch(FetchDescriptor<CloudZoneState>())
        let state = states.first(where: { $0.databaseScopeRawValue == scope.rawValue }) ?? CloudZoneState(databaseScope: scope)
        if state.modelContext == nil { context.insert(state) }
        state.serializedState = encoded
        state.updatedAt = .now
        try context.save()
    }

    func revokeSharedAccess(farmID: UUID) throws {
        let context = ModelContext(container)
        if let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farmID }) {
            binding.stateRawValue = CloudFarmBindingState.accessRevoked.rawValue
            binding.updatedAt = .now
        }
        for item in try context.fetch(FetchDescriptor<OutboxItem>())
        where item.farmID == farmID && item.status != .confirmed {
            item.statusRawValue = OutboxStatus.rejectedPermission.rawValue
            item.errorMessage = "牧场共享访问已经撤销，未确认操作保留在本机只读导出区。"
        }
        for certificate in try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        where certificate.farmID == farmID && certificate.revokedAt == nil {
            certificate.revokedAt = .now
        }
        try purgeFarmCache(farmID: farmID, context: context)
        try context.save()
    }

    private func purgeFarmCache(farmID: UUID, context: ModelContext) throws {
        for value in try context.fetch(FetchDescriptor<PenRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SheepRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<WeightRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<TransferRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<DailyPenCountRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedIngredientRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecordLine>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<InventoryTransactionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<ReproductionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SemenRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<NoteRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<PhotoAssetRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthSubjectLink>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<LambingOffspringRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmActivity>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmMembershipBinding>()) where value.farmID == farmID { context.delete(value) }
        if let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) { context.delete(farm) }
    }

    private func purgeConfirmedBusinessCache(farmID: UUID, context: ModelContext) throws {
        for value in try context.fetch(FetchDescriptor<PenRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SheepRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<WeightRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<TransferRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<DailyPenCountRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedIngredientRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecordLine>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<InventoryTransactionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<ReproductionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SemenRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<NoteRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<PhotoAssetRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthSubjectLink>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<LambingOffspringRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmActivity>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<TombstoneRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<CloudOperationReceipt>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SyncConflictRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<CloudAssetTransfer>()) where value.farmID == farmID && value.direction == .download { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmMembershipSnapshotRecord>()) where value.farmID == farmID { context.delete(value) }
    }

    private static func entityDigest(_ operations: [CloudOperationEnvelope]) -> String {
        let text = operations.sorted { $0.operationID.uuidString < $1.operationID.uuidString }.map {
            "\($0.operationID.uuidString.lowercased()):\($0.revision):\($0.payloadDigest)"
        }.joined(separator: "\n")
        return CloudPayloadDigest.hex(for: Data(text.utf8))
    }

    func upsertBinding(farmID: UUID, ownerAccountID: UUID, scope: CloudDatabaseScope, shareRecordName: String?, zoneOwnerName: String = CKCurrentUserDefaultName, state: CloudFarmBindingState) throws {
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let binding = bindings.first(where: { $0.farmID == farmID }) ?? CloudFarmBinding(farmID: farmID, ownerAccountID: ownerAccountID, databaseScope: scope)
        if binding.modelContext == nil { context.insert(binding) }
        binding.databaseScopeRawValue = scope.rawValue
        binding.zoneOwnerName = zoneOwnerName
        binding.shareRecordName = shareRecordName
        binding.stateRawValue = state.rawValue
        binding.updatedAt = .now
        if scope == .privateDatabase,
           let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) {
            farm.ownerAccountID = ownerAccountID
            farm.roleRawValue = FarmRole.owner.rawValue
            farm.membershipStatusRawValue = FarmMembershipStatus.active.rawValue
            farm.updatedAt = .now
            let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>())
            let confirmed = Set(receipts.map(\.operationID))
            for operation in try context.fetch(FetchDescriptor<DomainOperation>())
            where operation.farmID == farmID && !confirmed.contains(operation.id) {
                operation.accountID = ownerAccountID
            }
        }
        try context.save()
    }

    func saveCapability(_ response: WorkerCapabilityResponse, accountID: UUID, farmID: UUID, deviceID: UUID) throws {
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        for certificate in existing where certificate.farmID == farmID && certificate.accountID == accountID && certificate.revokedAt == nil {
            certificate.revokedAt = .now
        }
        let capabilitiesData = try JSONEncoder().encode(response.capabilities)
        context.insert(CapabilityCertificateRecord(
            serverCertificateID: response.certificateID,
            accountID: accountID,
            farmID: farmID,
            deviceID: deviceID,
            role: response.role,
            capabilitiesJSON: String(decoding: capabilitiesData, as: UTF8.self),
            certificateJWS: response.certificate,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(response.issuedAt)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAt))
        ))
        if let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farmID }) {
            if binding.databaseScope == .privateDatabase && response.role == .owner {
                binding.stateRawValue = CloudFarmBindingState.active.rawValue
            } else {
                binding.stateRawValue = CloudFarmBindingState.requiresAccountReview.rawValue
            }
            binding.updatedAt = .now
        }
        if let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) {
            farm.roleRawValue = response.role.rawValue
            farm.membershipStatusRawValue = response.role == .owner ? FarmMembershipStatus.active.rawValue : FarmMembershipStatus.pendingOwnerConfirmation.rawValue
            farm.updatedAt = .now
        }
        try Self.activateSharedFarmIfFullyVerified(farmID: farmID, accountID: accountID, context: context)
        try context.save()
    }

    func saveSecuritySnapshot(_ snapshot: WorkerFarmSecuritySnapshot) throws {
        let context = ModelContext(container)
        let memberships = try context.fetch(FetchDescriptor<FarmMembershipBinding>())
        for member in snapshot.members {
            let status: FarmMembershipStatus = switch member.status {
            case "active": .active
            case "pending": .pendingOwnerConfirmation
            case "revoked": .revoked
            default: .pendingInvite
            }
            if let existing = memberships.first(where: { $0.serverMembershipID == member.membershipID }) {
                existing.displayName = member.displayName
                existing.roleRawValue = member.role.rawValue
                existing.statusRawValue = status.rawValue
                existing.shareParticipantRecordName = member.shareParticipantRecordName
                existing.updatedAt = .now
            } else {
                let binding = FarmMembershipBinding(
                    serverMembershipID: member.membershipID,
                    farmID: snapshot.farmID,
                    accountID: member.accountID,
                    displayName: member.displayName,
                    role: member.role,
                    status: status
                )
                binding.shareParticipantRecordName = member.shareParticipantRecordName
                context.insert(binding)
            }
        }
        if let owner = snapshot.members.first(where: { $0.role == .owner }),
           let cloudBinding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == snapshot.farmID }) {
            cloudBinding.ownerAccountID = owner.accountID
            cloudBinding.securityGeneration = max(cloudBinding.securityGeneration, snapshot.generation)
            cloudBinding.updatedAt = .now
        }
        if let localAccountID = try context.fetch(FetchDescriptor<AccountProfile>()).first?.effectiveAccountID,
           let localMember = snapshot.members.first(where: { $0.accountID == localAccountID }),
           let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == snapshot.farmID }) {
            farm.roleRawValue = localMember.role.rawValue
            farm.membershipStatusRawValue = localMember.status
            farm.updatedAt = .now
        }
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        for device in snapshot.devices {
            guard let publicKey = Self.x963PublicKey(fromJWKJSON: device.publicKeyJWK) else { continue }
            if let existing = devices.first(where: { $0.id == device.deviceID }) {
                existing.publicKeyX963 = publicKey
                existing.isRegistered = true
                existing.lastRegisteredAt = .now
            } else {
                let record = DeviceIdentityRecord(id: device.deviceID, accountID: device.accountID, publicKeyX963: publicKey, usesSecureEnclave: false)
                record.isRegistered = true
                record.lastRegisteredAt = .now
                context.insert(record)
            }
        }
        let revoked = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        let localCertificates = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        for item in snapshot.revokedCertificates {
            let revokedAt = Date(timeIntervalSince1970: TimeInterval(item.revokedAt))
            if !revoked.contains(where: { $0.serverCertificateID == item.certificateID }) {
                context.insert(RevokedCapabilityCertificateRecord(
                    serverCertificateID: item.certificateID,
                    farmID: snapshot.farmID,
                    revokedAt: revokedAt
                ))
            }
            if let local = localCertificates.first(where: { $0.serverCertificateID == item.certificateID }) {
                local.revokedAt = revokedAt
            }
        }
        try context.save()
    }

    func lockAllCloudFarmsForAccountReview() throws {
        let context = ModelContext(container)
        for binding in try context.fetch(FetchDescriptor<CloudFarmBinding>()) where binding.state != .accessRevoked {
            binding.stateRawValue = CloudFarmBindingState.requiresAccountReview.rawValue
            binding.lastErrorCode = "cloudAccountChanged"
            binding.updatedAt = .now
        }
        for item in try context.fetch(FetchDescriptor<OutboxItem>()) where item.status == .uploading || item.status == .awaitingConfirmation {
            item.statusRawValue = OutboxStatus.pending.rawValue
            item.errorMessage = "iCloud 账号发生变化，等待重新验证。"
        }
        try context.save()
    }

    func saveMembershipSnapshotRecord(_ value: MembershipSnapshotRecordValue) throws {
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<FarmMembershipSnapshotRecord>()).filter { $0.farmID == value.farmID }
        guard existing.allSatisfy({ $0.generation <= value.generation }) else {
            throw CloudContractError.membershipSnapshotRollback
        }
        if let same = existing.first(where: { $0.generation == value.generation }) {
            same.cloudRecordName = value.cloudRecordName ?? same.cloudRecordName
            same.validatedAt = value.validatedAt ?? same.validatedAt
            if let accountID = try context.fetch(FetchDescriptor<AccountProfile>()).first?.effectiveAccountID {
                try Self.activateSharedFarmIfFullyVerified(farmID: value.farmID, accountID: accountID, context: context)
            }
            try context.save()
            return
        }
        for old in existing where old.generation < value.generation { context.delete(old) }
        let record = FarmMembershipSnapshotRecord(
            id: value.id,
            farmID: value.farmID,
            generation: value.generation,
            issuedAt: value.issuedAt,
            payload: value.payload,
            signedByAccountID: value.signedByAccountID,
            signedByDeviceID: value.signedByDeviceID,
            capabilityCertificate: value.capabilityCertificate,
            signature: value.signature
        )
        record.cloudRecordName = value.cloudRecordName
        record.validatedAt = value.validatedAt
        context.insert(record)
        if let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == value.farmID }) {
            binding.securityGeneration = value.generation
            binding.lastMembershipSnapshotAt = value.issuedAt
            binding.updatedAt = .now
        }
        if let accountID = try context.fetch(FetchDescriptor<AccountProfile>()).first?.effectiveAccountID {
            try Self.activateSharedFarmIfFullyVerified(farmID: value.farmID, accountID: accountID, context: context)
        }
        try context.save()
    }

    private static func activateSharedFarmIfFullyVerified(farmID: UUID, accountID: UUID, context: ModelContext) throws {
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: {
            $0.farmID == farmID && $0.databaseScope == .sharedDatabase && $0.state != .accessRevoked
        }) else { return }
        let snapshots = try context.fetch(FetchDescriptor<FarmMembershipSnapshotRecord>())
            .filter { $0.farmID == farmID && $0.validatedAt != nil }
        guard let latest = snapshots.max(by: { $0.generation < $1.generation }),
              let envelope = try? JSONDecoder.membershipPersistence.decode(FarmMembershipSnapshotEnvelope.self, from: latest.payload),
              envelope.generation == latest.generation,
              latest.generation >= binding.securityGeneration,
              envelope.members.contains(where: { $0.accountID == accountID && $0.status == "active" }) else {
            binding.stateRawValue = CloudFarmBindingState.requiresAccountReview.rawValue
            return
        }
        let certificates = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        guard let certificate = certificates.first(where: {
            $0.farmID == farmID && $0.accountID == accountID && $0.isUsable
        }), envelope.devices.contains(where: { $0.accountID == accountID && $0.deviceID == certificate.deviceID }) else {
            binding.stateRawValue = CloudFarmBindingState.requiresAccountReview.rawValue
            return
        }
        binding.securityGeneration = latest.generation
        binding.stateRawValue = CloudFarmBindingState.active.rawValue
        binding.lastErrorCode = nil
        binding.updatedAt = .now
        if let member = envelope.members.first(where: { $0.accountID == accountID }),
           let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) {
            farm.roleRawValue = member.role.rawValue
            farm.membershipStatusRawValue = FarmMembershipStatus.active.rawValue
            farm.updatedAt = .now
        }
    }

    func recordSecurityIncident(farmID: UUID?, type: String, recordName: String? = nil, detail: String) throws {
        let context = ModelContext(container)
        context.insert(SecurityIncidentRecord(
            farmID: farmID,
            incidentType: type,
            recordName: recordName,
            detail: detail
        ))
        try context.save()
    }

    private static func x963PublicKey(fromJWKJSON json: String) -> Data? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let x = object["x"].flatMap(Data.init(base64URLText:)),
              let y = object["y"].flatMap(Data.init(base64URLText:)),
              x.count == 32, y.count == 32 else { return nil }
        return Data([0x04]) + x + y
    }

}

private extension Data {
    init?(base64URLText: String) {
        var normalized = base64URLText.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        self.init(base64Encoded: normalized)
    }
}

private extension JSONDecoder {
    static var membershipPersistence: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum CloudErrorClassifier {
    struct Result {
        let status: OutboxStatus
        let message: String
        let retryAt: Date?
    }

    static func classify(_ error: CKError) -> Result {
        switch error.code {
        case .notAuthenticated, .permissionFailure:
            return Result(status: .rejectedPermission, message: error.localizedDescription, retryAt: nil)
        case .serverRecordChanged, .batchRequestFailed:
            return Result(status: .blockedConflict, message: error.localizedDescription, retryAt: nil)
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            let delay = (error.userInfo[CKErrorRetryAfterKey] as? TimeInterval) ?? 30
            return Result(status: .retryableFailure, message: error.localizedDescription, retryAt: .now.addingTimeInterval(delay))
        default:
            return Result(status: .retryableFailure, message: error.localizedDescription, retryAt: .now.addingTimeInterval(60))
        }
    }
}

enum CloudEngineStateDiskStore {
    static func load(scope: CloudDatabaseScope) -> CKSyncEngine.State.Serialization? {
        let fileURL = url(scope: scope)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            let preservedURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: preservedURL)
            UserDefaults.standard.set(true, forKey: corruptionKey(scope: scope))
            return nil
        }
    }

    static func save(_ data: Data, scope: CloudDatabaseScope) throws {
        let fileURL = url(scope: scope)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func remove(scope: CloudDatabaseScope) throws {
        let fileURL = url(scope: scope)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        UserDefaults.standard.removeObject(forKey: corruptionKey(scope: scope))
    }

    static func wasCorrupted(scope: CloudDatabaseScope) -> Bool {
        UserDefaults.standard.bool(forKey: corruptionKey(scope: scope))
    }

    static func modifiedAt(scope: CloudDatabaseScope) -> Date? {
        let values = try? url(scope: scope).resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private static func url(scope: CloudDatabaseScope) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appending(path: "CloudSync", directoryHint: .isDirectory).appending(path: "\(scope.rawValue).json")
    }

    private static func corruptionKey(scope: CloudDatabaseScope) -> String {
        "CloudEngineStateDiskStore.corrupted.\(scope.rawValue)"
    }
}
