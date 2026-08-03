import CloudKit
import Foundation
import SwiftData

enum FarmCheckpointReason: String, Codable, Sendable, CaseIterable {
    case initialCloudSetup
    case scheduled
    case operationThreshold
    case beforeMemberRevocation
    case afterMemberRevocation
    case manual

    var displayName: String {
        switch self {
        case .initialCloudSetup: "初始云端恢复点"
        case .scheduled: "每日恢复点"
        case .operationThreshold: "操作数量恢复点"
        case .beforeMemberRevocation: "撤权前恢复点"
        case .afterMemberRevocation: "撤权后恢复点"
        case .manual: "手动恢复点"
        }
    }
}

enum FarmCheckpointError: LocalizedError {
    case checkpointMissing
    case digestMismatch
    case manifestFarmMismatch
    case ownerBindingRequired
    case restoreConflict(UUID)

    var errorDescription: String? {
        switch self {
        case .checkpointMissing: "恢复点文件不存在。"
        case .digestMismatch: "恢复点校验值不一致。"
        case .manifestFarmMismatch: "恢复点不属于当前牧场。"
        case .ownerBindingRequired: "只有场主的 Private Database 牧场可以创建恢复点。"
        case .restoreConflict(let entityID): "恢复点中的实体 \(entityID.uuidString.lowercased()) 与当前业务数据冲突，未提交恢复操作。"
        }
    }
}

struct FarmCheckpointRestoreResult: Sendable, Equatable {
    let checkpointID: UUID
    let recoveryOperationIDs: [UUID]
    let photoAssetIDs: [UUID]
}

struct FarmCheckpointCreationTaskRegistry {
    struct Lease: Sendable {
        fileprivate let token: UUID
        let task: Task<UUID, any Error>
        let startedNewTask: Bool
    }

    private struct Entry {
        let token: UUID
        let task: Task<UUID, any Error>
    }

    private var entriesByFarmID: [UUID: Entry] = [:]

    mutating func acquire(
        farmID: UUID,
        operation: @escaping @Sendable () async throws -> UUID
    ) -> Lease {
        if let existing = entriesByFarmID[farmID] {
            return Lease(token: existing.token, task: existing.task, startedNewTask: false)
        }
        let entry = Entry(
            token: UUID(),
            task: Task<UUID, any Error> { try await operation() }
        )
        entriesByFarmID[farmID] = entry
        return Lease(token: entry.token, task: entry.task, startedNewTask: true)
    }

    mutating func release(_ lease: Lease, farmID: UUID) {
        guard lease.startedNewTask, entriesByFarmID[farmID]?.token == lease.token else { return }
        entriesByFarmID.removeValue(forKey: farmID)
    }

    func contains(farmID: UUID) -> Bool {
        entriesByFarmID[farmID] != nil
    }
}

actor FarmCheckpointActor {
    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private let recoveryKeys: FarmRecoveryKeyActor
    private var checkpointCreationTasks = FarmCheckpointCreationTaskRegistry()

    init(modelContainer: ModelContainer, containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String, recoveryKeys: FarmRecoveryKeyActor = .shared) {
        self.modelContainer = modelContainer
        self.cloudContainer = containerIdentifier.flatMap { $0.isEmpty ? nil : CKContainer(identifier: $0) } ?? .default()
        self.recoveryKeys = recoveryKeys
    }

    func shouldCreateAutomaticCheckpoint(farmID: UUID) throws -> FarmCheckpointReason? {
        let context = ModelContext(modelContainer)
        let checkpoints = try context.fetch(FetchDescriptor<FarmCheckpointRecord>()).filter { $0.farmID == farmID }
        guard let latest = checkpoints.max(by: { $0.createdAt < $1.createdAt }) else { return .initialCloudSetup }
        // A local file/row may exist while its CloudKit upload or verification is
        // still running (or was interrupted). Do not manufacture another large
        // checkpoint while that recovery point remains unfinished.
        guard latest.cloudRecordName != nil, latest.verifiedAt != nil else { return nil }
        // Receipts are acknowledgements, so their own confirmation time must be
        // compared with checkpoint creation. The operation watermark describes
        // domain history and can be much older than the checkpoint upload.
        let confirmed = try context.fetch(FetchDescriptor<CloudOperationReceipt>()).filter { $0.farmID == farmID && $0.confirmedAt > latest.createdAt }
        if confirmed.count >= 100 { return .operationThreshold }
        if !confirmed.isEmpty && Date().timeIntervalSince(latest.createdAt) >= 86_400 { return .scheduled }
        return nil
    }

    func createCheckpoint(farmID: UUID, reason: FarmCheckpointReason) async throws -> UUID {
        let lease = checkpointCreationTasks.acquire(farmID: farmID) { [self] in
            try await performCreateCheckpoint(farmID: farmID, reason: reason)
        }
        defer { checkpointCreationTasks.release(lease, farmID: farmID) }
        return try await lease.task.value
    }

    private func performCreateCheckpoint(farmID: UUID, reason: FarmCheckpointReason) async throws -> UUID {
        let context = ModelContext(modelContainer)
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: {
            $0.farmID == farmID && $0.databaseScope == .privateDatabase && $0.state == .active
        }) else { throw FarmCheckpointError.ownerBindingRequired }
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == farmID && $0.entityID != nil }
        let watermark = operations.map(\.occurredAt).max() ?? .distantPast
        let currentEntityCount = Set(operations.compactMap { operation in
            operation.entityID.map { "\(operation.entityType)|\($0.uuidString.lowercased())" }
        }).count
        let assets = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
            .map { FarmCheckpointManifest.AssetReference(assetID: $0.id, payloadDigest: $0.sha256, recoveryRecordName: $0.recoveryRecordName) }

        if reason == .initialCloudSetup {
            let compatible = try context.fetch(FetchDescriptor<FarmCheckpointRecord>())
                .filter { checkpoint in
                    checkpoint.farmID == farmID &&
                    FarmCheckpointResumePolicy.isCompatible(
                        checkpointReason: checkpoint.reasonRawValue,
                        requestedReason: reason,
                        checkpointWatermark: checkpoint.operationWatermark,
                        currentWatermark: watermark,
                        checkpointEntityCount: checkpoint.entityCount,
                        currentEntityCount: currentEntityCount,
                        checkpointAssetCount: checkpoint.assetCount,
                        currentAssetCount: assets.count,
                        checkpointSecurityGeneration: checkpoint.securityGeneration,
                        currentSecurityGeneration: binding.securityGeneration
                    )
                }
            if let completed = compatible
                .filter({ $0.cloudRecordName != nil && $0.verifiedAt != nil })
                .max(by: { $0.createdAt < $1.createdAt }) {
                return completed.id
            }
            if let resumable = compatible
                .filter({ $0.cloudRecordName == nil && $0.verifiedAt == nil && Self.hasCompleteLocalFile($0) })
                .max(by: { $0.createdAt < $1.createdAt }) {
                return try await uploadCheckpoint(resumable, context: context)
            }
        }
        let entitySnapshots = try FarmCheckpointOperationHistory.snapshots(
            operations: operations,
            farmID: farmID,
            context: context
        )
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.farmID == farmID }.compactMap { value -> FarmTombstoneEnvelope? in
            guard let operationID = value.operationID else { return nil }
            return FarmTombstoneEnvelope(tombstoneID: value.id, farmID: value.farmID, entityType: value.entityType, entityID: value.entityID, revision: value.revision, deletedAt: value.deletedAt, deletedByAccountID: value.deletedByAccountID, reason: value.reason, operationID: operationID, restoresTombstoneID: value.restoredByOperationID)
        }
        let grouped = Dictionary(grouping: entitySnapshots, by: \.entityType)
        // Checkpoint v2 keeps the complete operation history, but the user-facing
        // count must continue to describe unique domain entities rather than
        // replay operations.
        let counts = grouped.mapValues { Set($0.map(\.entityID)).count }
        let digests = grouped.mapValues { values in
            let ordered = values.sorted {
                if $0.entityID != $1.entityID { return $0.entityID.uuidString < $1.entityID.uuidString }
                return ($0.operationID?.uuidString ?? "") < ($1.operationID?.uuidString ?? "")
            }
            return CloudPayloadDigest.hex(for: Data(ordered.flatMap { Array($0.payloadDigest.utf8) }))
        }
        let checkpointID = UUID()
        let manifest = FarmCheckpointManifest(
            schemaVersion: 2,
            checkpointID: checkpointID,
            farmID: farmID,
            createdAt: .now,
            operationWatermark: watermark,
            securityGeneration: binding.securityGeneration,
            entities: entitySnapshots,
            tombstones: tombstones,
            assets: assets,
            entityCounts: counts,
            entityDigests: digests
        )
        let clearData = try JSONEncoder.cloud.encode(manifest)
        let encryptedData = try await recoveryKeys.seal(clearData, farmID: farmID)
        let fileURL = try Self.checkpointURL(farmID: farmID, checkpointID: checkpointID)
        try encryptedData.write(to: fileURL, options: .atomic)
        let local = FarmCheckpointRecord(
            id: checkpointID,
            farmID: farmID,
            reasonRawValue: reason.rawValue,
            operationWatermark: watermark,
            manifestDigest: CloudPayloadDigest.hex(for: clearData),
            encryptedRelativePath: Self.relativePath(for: fileURL),
            byteCount: Int64(encryptedData.count),
            entityCount: counts.values.reduce(0, +),
            assetCount: assets.count,
            securityGeneration: binding.securityGeneration
        )
        context.insert(local)
        try context.save()

        return try await uploadCheckpoint(local, context: context)
    }

    private func uploadCheckpoint(_ local: FarmCheckpointRecord, context: ModelContext) async throws -> UUID {
        guard Self.hasCompleteLocalFile(local) else { throw FarmCheckpointError.checkpointMissing }
        let farmID = local.farmID
        let checkpointID = local.id
        let fileURL = Self.absoluteURL(for: local.encryptedRelativePath)
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.recovery(for: farmID), ownerName: CKCurrentUserDefaultName)
        let database = cloudContainer.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let recordID = CKRecord.ID(recordName: "checkpoint_\(checkpointID.uuidString.lowercased())", zoneID: zoneID)
        do {
            let existing = try await database.record(for: recordID)
            guard existing[CloudRecordField.farmID] as? String == farmID.uuidString.lowercased(),
                  existing[CloudRecordField.entityID] as? String == checkpointID.uuidString.lowercased(),
                  existing[CloudRecordField.payloadDigest] as? String == local.manifestDigest,
                  existing[CloudRecordField.asset] as? CKAsset != nil else {
                throw FarmCheckpointError.digestMismatch
            }
            local.cloudRecordName = recordID.recordName
            local.verifiedAt = .now
            try context.save()
            try await pruneOldCheckpoints(farmID: farmID, keeping: 3)
            return checkpointID
        } catch let error as CKError where error.code == .unknownItem {
            // The previous process stopped before CloudKit committed the
            // deterministic record. Reuse the same local checkpoint and ID.
        }
        let record = CKRecord(recordType: CloudRecordType.farmCheckpoint.rawValue, recordID: recordID)
        record[CloudRecordField.farmID] = farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.entityID] = checkpointID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.schemaVersion] = 2 as CKRecordValue
        record[CloudRecordField.modifiedAt] = local.createdAt as CKRecordValue
        record["operationWatermark"] = local.operationWatermark as CKRecordValue
        record[CloudRecordField.generation] = local.securityGeneration as CKRecordValue
        record[CloudRecordField.payloadDigest] = local.manifestDigest as CKRecordValue
        record[CloudRecordField.byteCount] = local.byteCount as CKRecordValue
        record[CloudRecordField.asset] = CKAsset(fileURL: fileURL)
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
        _ = try result.saveResults[recordID]?.get()
        local.cloudRecordName = recordID.recordName
        local.verifiedAt = .now
        try context.save()
        try await pruneOldCheckpoints(farmID: farmID, keeping: 3)
        return checkpointID
    }

    func verifyCheckpoint(id: UUID) async throws -> FarmCheckpointManifest {
        let context = ModelContext(modelContainer)
        guard let checkpoint = try context.fetch(FetchDescriptor<FarmCheckpointRecord>()).first(where: { $0.id == id }) else { throw FarmCheckpointError.checkpointMissing }
        let fileURL = Self.absoluteURL(for: checkpoint.encryptedRelativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw FarmCheckpointError.checkpointMissing }
        let clear = try await recoveryKeys.open(Data(contentsOf: fileURL), farmID: checkpoint.farmID)
        guard CloudPayloadDigest.hex(for: clear) == checkpoint.manifestDigest else { throw FarmCheckpointError.digestMismatch }
        let manifest = try JSONDecoder.checkpoint.decode(FarmCheckpointManifest.self, from: clear)
        guard manifest.farmID == checkpoint.farmID, manifest.checkpointID == checkpoint.id else { throw FarmCheckpointError.manifestFarmMismatch }
        guard manifest.entities.allSatisfy({ CloudPayloadDigest.hex(for: $0.payload) == $0.payloadDigest }) else { throw FarmCheckpointError.digestMismatch }
        checkpoint.verifiedAt = .now
        try context.save()
        return manifest
    }

    func restoreCheckpoint(id: UUID, farm: FarmContext) async throws -> FarmCheckpointRestoreResult {
        guard farm.capabilities.allows(.recoverFarm) else { throw FarmPermissionError.denied(.recoverFarm) }
        let manifest = try await verifyCheckpoint(id: id)
        guard manifest.farmID == farm.farmID else { throw FarmCheckpointError.manifestFarmMismatch }
        let context = ModelContext(modelContainer)
        let ordered = CloudRebuildActor.sortedOperations(
            FarmCheckpointOperationHistory.sourceEnvelopes(
                snapshots: manifest.entities,
                manifest: manifest,
                accountID: farm.accountID
            )
        )
        var operationIDs: [UUID] = []
        var rebuildFrom: Date?
        for sourceEnvelope in ordered {
            switch try RemoteDomainApplyService().apply(sourceEnvelope, context: context) {
            case .applied(let changedAt):
                if let changedAt { rebuildFrom = min(rebuildFrom ?? changedAt, changedAt) }
            case .duplicate:
                break
            case .conflict:
                throw FarmCheckpointError.restoreConflict(sourceEnvelope.entityID)
            }
            var payload = FarmCommandCloudPayload(kind: .recoverEntity)
            payload.identifiers = ["checkpointID": id, "entityID": sourceEnvelope.entityID]
            payload.strings = ["entityType": sourceEnvelope.entityType, "sourcePayloadDigest": sourceEnvelope.payloadDigest]
            payload.integers = ["sourceRevision": sourceEnvelope.revision]
            payload.dataValues = ["resolvedPayload": sourceEnvelope.payload]
            let encoded = try JSONEncoder.cloud.encode(payload)
            let operation = DomainOperation(
                farmID: farm.farmID,
                accountID: farm.accountID,
                kind: .recoverEntity,
                summary: "从恢复点恢复权威记录",
                entityType: sourceEnvelope.entityType,
                entityID: sourceEnvelope.entityID,
                baseRevision: sourceEnvelope.revision,
                resultingRevision: sourceEnvelope.revision + 1,
                payload: encoded
            )
            context.insert(operation)
            context.insert(OutboxItem(
                farmID: farm.farmID,
                accountID: farm.accountID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID,
                baseRevision: operation.baseRevision,
                payloadDigest: operation.payloadDigest
            ))
            operationIDs.append(operation.id)
        }
        if let rebuildFrom {
            try FarmHistoryRebuilder().rebuild(farmID: farm.farmID, context: context, from: rebuildFrom)
        }
        if let checkpoint = try context.fetch(FetchDescriptor<FarmCheckpointRecord>()).first(where: { $0.id == id }) {
            checkpoint.restoredAt = .now
        }
        try context.save()
        return FarmCheckpointRestoreResult(
            checkpointID: id,
            recoveryOperationIDs: operationIDs,
            photoAssetIDs: manifest.assets.compactMap { $0.recoveryRecordName == nil ? nil : $0.assetID }
        )
    }

    private func pruneOldCheckpoints(farmID: UUID, keeping count: Int) async throws {
        let context = ModelContext(modelContainer)
        let all = try context.fetch(FetchDescriptor<FarmCheckpointRecord>()).filter { $0.farmID == farmID }.sorted { $0.createdAt > $1.createdAt }
        let verified = all.filter { $0.cloudRecordName != nil && $0.verifiedAt != nil }
        let retainedIDs = Set(verified.prefix(count).map(\.id))
        let latestVerifiedAt = verified.first?.createdAt
        let removable = all.filter {
            FarmCheckpointPrunePolicy.shouldRemove(
                isVerified: $0.cloudRecordName != nil && $0.verifiedAt != nil,
                isRetained: retainedIDs.contains($0.id),
                createdAt: $0.createdAt,
                latestVerifiedAt: latestVerifiedAt
            )
        }
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.recovery(for: farmID), ownerName: CKCurrentUserDefaultName)
        for old in removable {
            let fileURL = Self.absoluteURL(for: old.encryptedRelativePath)
            try? FileManager.default.removeItem(at: fileURL)
            if let name = old.cloudRecordName {
                _ = try? await cloudContainer.privateCloudDatabase.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: name, zoneID: zoneID)], savePolicy: .changedKeys, atomically: true)
            }
            context.delete(old)
        }
        try context.save()
    }

    @discardableResult
    func cleanupInterruptedCheckpoints(farmID: UUID) throws -> Int {
        // This method is also called during cold-start recovery. Never race a
        // currently running creator for the same farm.
        guard !checkpointCreationTasks.contains(farmID: farmID) else { return 0 }
        let context = ModelContext(modelContainer)
        let all = try context.fetch(FetchDescriptor<FarmCheckpointRecord>()).filter { $0.farmID == farmID }
        let interrupted = all.filter {
            $0.cloudRecordName == nil && $0.verifiedAt == nil
        }
        for checkpoint in interrupted {
            try? FileManager.default.removeItem(at: Self.absoluteURL(for: checkpoint.encryptedRelativePath))
            context.delete(checkpoint)
        }
        if !interrupted.isEmpty { try context.save() }
        return interrupted.count
    }

    private static func baseDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "eSheepNext", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func checkpointURL(farmID: UUID, checkpointID: UUID) throws -> URL {
        let directory = try baseDirectory().appending(path: "Recovery/\(farmID.uuidString.lowercased())/Checkpoints", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(checkpointID.uuidString.lowercased()).checkpoint")
    }

    private static func absoluteURL(for path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return (try? baseDirectory().appending(path: path)) ?? URL(fileURLWithPath: path)
    }

    private static func hasCompleteLocalFile(_ checkpoint: FarmCheckpointRecord) -> Bool {
        let url = absoluteURL(for: checkpoint.encryptedRelativePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return Int64(size) == checkpoint.byteCount
    }

    private static func relativePath(for url: URL) -> String {
        guard let root = try? baseDirectory().standardizedFileURL.path, url.standardizedFileURL.path.hasPrefix(root + "/") else { return url.path }
        return String(url.standardizedFileURL.path.dropFirst(root.count + 1))
    }

}

enum FarmCheckpointResumePolicy {
    static func isCompatible(
        checkpointReason: String,
        requestedReason: FarmCheckpointReason,
        checkpointWatermark: Date,
        currentWatermark: Date,
        checkpointEntityCount: Int,
        currentEntityCount: Int,
        checkpointAssetCount: Int,
        currentAssetCount: Int,
        checkpointSecurityGeneration: Int,
        currentSecurityGeneration: Int
    ) -> Bool {
        checkpointReason == requestedReason.rawValue &&
            checkpointWatermark == currentWatermark &&
            checkpointEntityCount == currentEntityCount &&
            checkpointAssetCount == currentAssetCount &&
            checkpointSecurityGeneration == currentSecurityGeneration
    }
}

enum FarmCheckpointPrunePolicy {
    static func shouldRemove(
        isVerified: Bool,
        isRetained: Bool,
        createdAt: Date,
        latestVerifiedAt: Date?
    ) -> Bool {
        guard !isRetained else { return false }
        if isVerified { return true }
        guard let latestVerifiedAt else { return false }
        return createdAt <= latestVerifiedAt
    }
}

enum FarmCheckpointOperationHistory {
    static func snapshots(
        operations: [DomainOperation],
        farmID: UUID,
        context: ModelContext
    ) throws -> [FarmCheckpointManifest.EntitySnapshot] {
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.farmID == farmID }
        var deletedAtByOperationID: [UUID: Date] = [:]
        for tombstone in tombstones {
            guard let operationID = tombstone.operationID else { continue }
            if let existing = deletedAtByOperationID[operationID] {
                deletedAtByOperationID[operationID] = min(existing, tombstone.deletedAt)
            } else {
                deletedAtByOperationID[operationID] = tombstone.deletedAt
            }
        }
        return operations.compactMap { operation in
            guard let entityID = operation.entityID else { return nil }
            return FarmCheckpointManifest.EntitySnapshot(
                entityType: operation.entityType,
                entityID: entityID,
                revision: operation.resultingRevision,
                payload: operation.payload,
                payloadDigest: operation.payloadDigest,
                operationID: operation.id,
                baseRevision: operation.baseRevision,
                occurredAt: operation.occurredAt,
                deletedAt: deletedAtByOperationID[operation.id]
            )
        }
        .sorted {
            if $0.occurredAt != $1.occurredAt { return ($0.occurredAt ?? .distantPast) < ($1.occurredAt ?? .distantPast) }
            return ($0.operationID?.uuidString ?? "") < ($1.operationID?.uuidString ?? "")
        }
    }

    static func sourceEnvelopes(
        snapshots: [FarmCheckpointManifest.EntitySnapshot],
        manifest: FarmCheckpointManifest,
        accountID: UUID
    ) -> [CloudOperationEnvelope] {
        snapshots.map { snapshot in
            let sourceIdentity = snapshot.operationID?.uuidString.lowercased()
                ?? "\(snapshot.entityType):\(snapshot.entityID.uuidString.lowercased()):\(snapshot.revision)"
            return CloudOperationEnvelope(
                farmID: manifest.farmID,
                entityID: snapshot.entityID,
                entityType: snapshot.entityType,
                schemaVersion: 2,
                revision: snapshot.revision,
                baseRevision: snapshot.baseRevision ?? max(0, snapshot.revision - 1),
                operationID: StableCloudUUID.derived(namespace: manifest.checkpointID, name: "source:\(sourceIdentity)"),
                modifiedAt: snapshot.occurredAt ?? manifest.createdAt,
                modifiedByAccountID: accountID,
                modifiedByDeviceID: StableCloudUUID.derived(namespace: manifest.checkpointID, name: "checkpoint-device"),
                payload: snapshot.payload,
                payloadDigest: snapshot.payloadDigest,
                capabilityCertificate: "checkpoint",
                operationSignature: Data(),
                deletedAt: snapshot.deletedAt
            )
        }
    }
}

private extension JSONDecoder {
    static var checkpoint: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
