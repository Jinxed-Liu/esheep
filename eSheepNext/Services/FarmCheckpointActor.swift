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

actor FarmCheckpointActor {
    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private let recoveryKeys: FarmRecoveryKeyActor

    init(modelContainer: ModelContainer, containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String, recoveryKeys: FarmRecoveryKeyActor = .shared) {
        self.modelContainer = modelContainer
        self.cloudContainer = containerIdentifier.flatMap { $0.isEmpty ? nil : CKContainer(identifier: $0) } ?? .default()
        self.recoveryKeys = recoveryKeys
    }

    func shouldCreateAutomaticCheckpoint(farmID: UUID) throws -> FarmCheckpointReason? {
        let context = ModelContext(modelContainer)
        let checkpoints = try context.fetch(FetchDescriptor<FarmCheckpointRecord>()).filter { $0.farmID == farmID }
        guard let latest = checkpoints.max(by: { $0.createdAt < $1.createdAt }) else { return .initialCloudSetup }
        let confirmed = try context.fetch(FetchDescriptor<CloudOperationReceipt>()).filter { $0.farmID == farmID && $0.confirmedAt > latest.operationWatermark }
        if confirmed.count >= 100 { return .operationThreshold }
        if !confirmed.isEmpty && Date().timeIntervalSince(latest.createdAt) >= 86_400 { return .scheduled }
        return nil
    }

    func createCheckpoint(farmID: UUID, reason: FarmCheckpointReason) async throws -> UUID {
        let context = ModelContext(modelContainer)
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: {
            $0.farmID == farmID && $0.databaseScope == .privateDatabase && $0.state == .active
        }) else { throw FarmCheckpointError.ownerBindingRequired }
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == farmID && $0.entityID != nil }
        let entitySnapshots = try FarmCheckpointOperationHistory.snapshots(
            operations: operations,
            farmID: farmID,
            context: context
        )
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.farmID == farmID }.compactMap { value -> FarmTombstoneEnvelope? in
            guard let operationID = value.operationID else { return nil }
            return FarmTombstoneEnvelope(tombstoneID: value.id, farmID: value.farmID, entityType: value.entityType, entityID: value.entityID, revision: value.revision, deletedAt: value.deletedAt, deletedByAccountID: value.deletedByAccountID, reason: value.reason, operationID: operationID, restoresTombstoneID: value.restoredByOperationID)
        }
        let assets = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map {
            FarmCheckpointManifest.AssetReference(assetID: $0.id, payloadDigest: $0.sha256, recoveryRecordName: $0.recoveryRecordName)
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
        let watermark = operations.map(\.occurredAt).max() ?? .distantPast
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

        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.recovery(for: farmID), ownerName: CKCurrentUserDefaultName)
        _ = try await cloudContainer.privateCloudDatabase.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let recordID = CKRecord.ID(recordName: "checkpoint_\(checkpointID.uuidString.lowercased())", zoneID: zoneID)
        let record = CKRecord(recordType: CloudRecordType.farmCheckpoint.rawValue, recordID: recordID)
        record[CloudRecordField.farmID] = farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.entityID] = checkpointID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.schemaVersion] = manifest.schemaVersion as CKRecordValue
        record[CloudRecordField.modifiedAt] = manifest.createdAt as CKRecordValue
        record["operationWatermark"] = watermark as CKRecordValue
        record[CloudRecordField.generation] = binding.securityGeneration as CKRecordValue
        record[CloudRecordField.payloadDigest] = local.manifestDigest as CKRecordValue
        record[CloudRecordField.byteCount] = local.byteCount as CKRecordValue
        record[CloudRecordField.asset] = CKAsset(fileURL: fileURL)
        let result = try await cloudContainer.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
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
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.recovery(for: farmID), ownerName: CKCurrentUserDefaultName)
        for old in all.dropFirst(count) {
            let fileURL = Self.absoluteURL(for: old.encryptedRelativePath)
            try? FileManager.default.removeItem(at: fileURL)
            if let name = old.cloudRecordName {
                _ = try? await cloudContainer.privateCloudDatabase.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: name, zoneID: zoneID)], savePolicy: .changedKeys, atomically: true)
            }
            context.delete(old)
        }
        try context.save()
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

    private static func relativePath(for url: URL) -> String {
        guard let root = try? baseDirectory().standardizedFileURL.path, url.standardizedFileURL.path.hasPrefix(root + "/") else { return url.path }
        return String(url.standardizedFileURL.path.dropFirst(root.count + 1))
    }

}

enum FarmCheckpointOperationHistory {
    static func snapshots(
        operations: [DomainOperation],
        farmID: UUID,
        context: ModelContext
    ) throws -> [FarmCheckpointManifest.EntitySnapshot] {
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.farmID == farmID }
        let deletedAtByOperationID = Dictionary(uniqueKeysWithValues: tombstones.compactMap { tombstone in
            tombstone.operationID.map { ($0, tombstone.deletedAt) }
        })
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
