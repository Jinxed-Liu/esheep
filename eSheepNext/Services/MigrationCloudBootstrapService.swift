import Foundation
import SwiftData

struct MigrationCloudBootstrapResult: Sendable, Equatable {
    let operationCount: Int
    let photoCount: Int
    let baselineDigest: String
    let wasAlreadyPrepared: Bool
}

struct FarmBootstrapEntitySnapshot: Sendable, Equatable {
    let entityType: CloudEntityType
    let entityID: UUID
    let sourceRevision: Int
    let sourcePayload: Data
    let replayOrder: Int
}

enum MigrationCloudBootstrapError: LocalizedError {
    case farmMissing
    case ownerMismatch
    case commitMissing
    case conflictingCloudBinding
    case duplicateEarTag
    case missingPhoto(String)
    case photoDigestMismatch(String)
    case invalidExistingBaselineOperation
    case conflictingBaselineOutbox

    var errorDescription: String? {
        switch self {
        case .farmMissing: "找不到需要准备云端基线的迁移牧场。"
        case .ownerMismatch: "迁移提交与当前牧场主不一致，未升级云端状态。"
        case .commitMissing: "缺少完整迁移提交凭据，未升级云端状态。"
        case .conflictingCloudBinding: "牧场已经绑定其他 iCloud 区域，不能自动升级。"
        case .duplicateEarTag: "迁移牧场存在重复耳号，不能生成云端基线。"
        case .missingPhoto(let key): "迁移照片文件缺失：\(key)。"
        case .photoDigestMismatch(let key): "迁移照片摘要不一致：\(key)。"
        case .invalidExistingBaselineOperation: "已有迁移基线操作与当前已验证快照不一致，已停止自动覆盖。"
        case .conflictingBaselineOutbox: "迁移基线的本地上传凭据重复或不一致，已停止自动覆盖。"
        }
    }
}

enum MigrationCloudReadyEvidenceError: LocalizedError {
    case baselineMissing
    case invalidBaselineOperation
    case baselineSetMismatch
    case bindingMismatch
    case outboxMismatch
    case receiptMissing
    case photoMismatch

    var errorDescription: String? {
        switch self {
        case .baselineMissing: "缺少可验证的迁移云端基线。"
        case .invalidBaselineOperation: "迁移基线操作的身份、载荷或摘要不一致。"
        case .baselineSetMismatch: "迁移基线操作集与已验证的数量或摘要不一致。"
        case .bindingMismatch: "迁移牧场缺少唯一的场主私有云端绑定。"
        case .outboxMismatch: "迁移基线的本地上传凭据缺失、重复或未确认。"
        case .receiptMissing: "迁移基线缺少与当前牧场和数据库范围匹配的云端回执。"
        case .photoMismatch: "迁移照片缺少摘要匹配的已完成上传凭据。"
        }
    }
}

struct MigrationBaselineV2RequiredSet {
    let operations: [DomainOperation]
    let version: Int
    let cutoffAt: Date
}

enum MigrationBaselineV2EvidenceContract {
    static let summaryPrefix = "迁移云端基线："
    static let currentVersion = 2

    private struct LogicalEntity: Hashable {
        let entityType: String
        let entityID: UUID
    }

    private struct LogicalSlot: Hashable {
        let entity: LogicalEntity
        let slot: String
    }

    private struct ParsedOperation {
        let operation: DomainOperation
        let snapshot: BootstrapEntityEnvelopeV1
        let version: Int
        let cutoffAt: Date?
        let slot: String
        let digestLine: String
    }

    static func requiredOperations(
        commit: MigrationCommitRecord,
        farmID: UUID,
        context: ModelContext
    ) throws -> MigrationBaselineV2RequiredSet {
        guard commit.farmID == farmID,
              commit.status == .completed,
              !commit.baselineDigest.isEmpty,
              commit.baselineEntityCount > 0,
              commit.baselinePhotoCount >= 0 else {
            throw MigrationCloudReadyEvidenceError.baselineMissing
        }

        let farmOperations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farmID
        }
        let parsed = try farmOperations.compactMap { try parseBootstrapOperation($0) }
        guard parsed.contains(where: { $0.version == currentVersion }),
              let cutoffAt = parsed
                .filter({ $0.version == currentVersion })
                .compactMap(\.cutoffAt)
                .max() else {
            throw MigrationCloudReadyEvidenceError.baselineSetMismatch
        }

        var deletedBeforeCutoff = Set<LogicalEntity>()
        for operation in farmOperations where operation.occurredAt <= cutoffAt {
            guard operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue else { continue }
            guard CloudPayloadDigest.hex(for: operation.payload) == operation.payloadDigest,
                  let payload = try? decodePayload(operation.payload),
                  payload.kind == .tombstoneEntity,
                  let entityType = payload.strings["entityType"],
                  let entityID = payload.identifiers["entityID"] else {
                throw MigrationCloudReadyEvidenceError.invalidBaselineOperation
            }
            deletedBeforeCutoff.insert(.init(entityType: entityType, entityID: entityID))
        }

        var candidates: [LogicalSlot: [ParsedOperation]] = [:]
        for value in parsed where value.version <= currentVersion {
            let key = LogicalSlot(
                entity: .init(entityType: value.snapshot.entityType, entityID: value.snapshot.entityID),
                slot: value.slot
            )
            candidates[key, default: []].append(value)
        }

        var selected: [ParsedOperation] = []
        for (slot, values) in candidates {
            guard let selectedVersion = values.map(\.version).max() else { continue }
            let sameVersion = values.filter { $0.version == selectedVersion }
            let selectedCutoff = sameVersion.compactMap(\.cutoffAt).max()
            let newest = sameVersion.filter { $0.cutoffAt == selectedCutoff }
            guard newest.count == 1, let value = newest.first else {
                throw MigrationCloudReadyEvidenceError.invalidBaselineOperation
            }
            if deletedBeforeCutoff.contains(slot.entity), selectedVersion < currentVersion {
                continue
            }
            selected.append(value)
        }

        let operationIDs = Set(selected.map { $0.operation.id })
        guard operationIDs.count == selected.count,
              selected.count == commit.baselineEntityCount else {
            throw MigrationCloudReadyEvidenceError.baselineSetMismatch
        }
        let digest = CloudPayloadDigest.hex(
            for: Data(selected.map(\.digestLine).sorted().joined(separator: "\n").utf8)
        )
        guard digest == commit.baselineDigest else {
            throw MigrationCloudReadyEvidenceError.baselineSetMismatch
        }
        for value in selected {
            let sourceDigest = CloudPayloadDigest.hex(for: value.snapshot.sourcePayload)
            let expectedID = StableMigrationID.uuid(
                sessionID: commit.sessionID,
                sourceKey: "cloud-bootstrap:\(value.snapshot.entityType):\(value.snapshot.entityID.uuidString.lowercased()):\(sourceDigest)"
            )
            guard value.operation.id == expectedID,
                  value.operation.accountID == commit.ownerAccountID else {
                throw MigrationCloudReadyEvidenceError.invalidBaselineOperation
            }
        }
        return .init(
            operations: selected.map(\.operation),
            version: currentVersion,
            cutoffAt: cutoffAt
        )
    }

    @discardableResult
    static func repairOutboxes(
        required: MigrationBaselineV2RequiredSet,
        commit: MigrationCommitRecord,
        databaseScope: CloudDatabaseScope?,
        zoneName: String? = nil,
        zoneOwnerName: String? = nil,
        context: ModelContext
    ) throws -> Int {
        let mapper = CloudRecordMapper()
        let outboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == commit.farmID
        }
        var outboxesByOperationID = Dictionary(grouping: outboxes, by: \.operationID)
        let allOutboxes = try context.fetch(FetchDescriptor<OutboxItem>())
        let allOutboxIDs = Set(allOutboxes.map(\.id))
        let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>()).filter {
            $0.farmID == commit.farmID
        }
        let receiptsByOperationID = Dictionary(grouping: receipts, by: \.operationID)
        var repairCount = 0
        for operation in required.operations {
            let matching = outboxesByOperationID[operation.id] ?? []
            let item: OutboxItem
            if matching.isEmpty {
                let expectedID = StableMigrationID.uuid(
                    sessionID: commit.sessionID,
                    sourceKey: "cloud-bootstrap-outbox:\(operation.id.uuidString.lowercased())"
                )
                guard !allOutboxIDs.contains(expectedID) else {
                    throw MigrationCloudReadyEvidenceError.outboxMismatch
                }
                item = OutboxItem(
                    id: expectedID,
                    farmID: operation.farmID,
                    accountID: operation.accountID,
                    operationID: operation.id,
                    entityType: operation.entityType,
                    entityID: operation.entityID,
                    baseRevision: operation.baseRevision,
                    payloadDigest: operation.payloadDigest
                )
                context.insert(item)
                outboxesByOperationID[operation.id] = [item]
                repairCount += 1
            } else {
                guard matching.count == 1, let existing = matching.first else {
                    throw MigrationCloudReadyEvidenceError.outboxMismatch
                }
                item = existing
            }
            guard item.farmID == operation.farmID,
                  item.accountID == operation.accountID,
                  item.operationID == operation.id,
                  item.entityType == operation.entityType,
                  item.entityID == operation.entityID,
                  item.baseRevision == operation.baseRevision,
                  item.payloadDigest == operation.payloadDigest else {
                throw MigrationCloudReadyEvidenceError.outboxMismatch
            }

            guard item.status == .confirmed, let databaseScope else { continue }
            let expectedRecordName = mapper.recordName(for: operation.id)
            let hasReceipt = (receiptsByOperationID[operation.id] ?? []).contains {
                $0.farmID == operation.farmID &&
                    $0.operationID == operation.id &&
                    $0.databaseScopeRawValue == databaseScope.rawValue &&
                    $0.recordName == expectedRecordName &&
                    $0.zoneName == zoneName &&
                    $0.zoneOwnerName == zoneOwnerName
            }
            if hasReceipt {
                if item.cloudRecordName != expectedRecordName {
                    item.cloudRecordName = expectedRecordName
                    repairCount += 1
                }
            } else {
                // An immutable operation can be sent again safely. CKSyncEngine
                // will either save it or confirm byte-identical server state.
                item.statusRawValue = OutboxStatus.pending.rawValue
                item.cloudRecordName = nil
                item.errorMessage = nil
                item.nextRetryAt = nil
                repairCount += 1
            }
        }
        return repairCount
    }

    static func validateExistingOperation(
        _ operation: DomainOperation,
        commit: MigrationCommitRecord,
        accountID: UUID,
        entityType: CloudEntityType,
        entityID: UUID,
        sourceRevision: Int,
        sourcePayload: Data,
        slot: Int
    ) throws {
        guard let parsed = try parseBootstrapOperation(operation),
              operation.accountID == accountID,
              operation.accountID == commit.ownerAccountID,
              parsed.snapshot.entityType == entityType.rawValue,
              parsed.snapshot.entityID == entityID,
              parsed.snapshot.sourceRevision == max(1, sourceRevision),
              parsed.snapshot.sourcePayload == sourcePayload,
              parsed.slot == String(slot) else {
            throw MigrationCloudBootstrapError.invalidExistingBaselineOperation
        }
        let sourceDigest = CloudPayloadDigest.hex(for: sourcePayload)
        let expectedID = StableMigrationID.uuid(
            sessionID: commit.sessionID,
            sourceKey: "cloud-bootstrap:\(entityType.rawValue):\(entityID.uuidString.lowercased()):\(sourceDigest)"
        )
        guard operation.id == expectedID else {
            throw MigrationCloudBootstrapError.invalidExistingBaselineOperation
        }
    }

    private static func parseBootstrapOperation(_ operation: DomainOperation) throws -> ParsedOperation? {
        let looksLikeBaseline = operation.kindRawValue == DomainOperationKind.bootstrapEntity.rawValue ||
            operation.summary.hasPrefix(summaryPrefix)
        guard looksLikeBaseline else { return nil }
        guard operation.kindRawValue == DomainOperationKind.bootstrapEntity.rawValue,
              operation.schemaVersion >= 2,
              operation.baseRevision == 0,
              CloudPayloadDigest.hex(for: operation.payload) == operation.payloadDigest,
              let payload = try? decodePayload(operation.payload),
              payload.kind == .bootstrapEntity,
              let snapshotData = payload.dataValues["snapshot"],
              let snapshot = try? decodeSnapshot(snapshotData),
              snapshot.schemaVersion == BootstrapEntityEnvelopeV1.schemaVersion,
              snapshot.sourcePayloadDigest == CloudPayloadDigest.hex(for: snapshot.sourcePayload),
              operation.entityType == snapshot.entityType,
              operation.entityID == snapshot.entityID,
              operation.resultingRevision == snapshot.sourceRevision else {
            throw MigrationCloudReadyEvidenceError.invalidBaselineOperation
        }

        let version = payload.integers["baselineVersion"] ?? 1
        guard version == 1 || version == currentVersion else {
            throw MigrationCloudReadyEvidenceError.invalidBaselineOperation
        }
        let slot: String
        let cutoffAt: Date?
        var expected = FarmCommandCloudPayload(kind: .bootstrapEntity)
        expected.dataValues["snapshot"] = snapshotData
        if version == currentVersion {
            guard let value = payload.strings["baselineSlot"],
                  !value.isEmpty,
                  let cutoff = payload.dates["baselineCutoffAt"] else {
                throw MigrationCloudReadyEvidenceError.invalidBaselineOperation
            }
            slot = value
            cutoffAt = cutoff
            expected.integers["baselineVersion"] = currentVersion
            expected.strings["baselineSlot"] = value
            expected.dates["baselineCutoffAt"] = cutoff
        } else {
            slot = try legacyBaselineSlot(snapshot)
            cutoffAt = nil
        }
        guard try JSONEncoder.cloud.encode(expected) == operation.payload else {
            throw MigrationCloudReadyEvidenceError.invalidBaselineOperation
        }
        let sourceDigest = CloudPayloadDigest.hex(for: snapshot.sourcePayload)
        return .init(
            operation: operation,
            snapshot: snapshot,
            version: version,
            cutoffAt: cutoffAt,
            slot: slot,
            digestLine: "\(snapshot.entityType):\(snapshot.entityID.uuidString.lowercased()):\(sourceDigest)"
        )
    }

    private static func legacyBaselineSlot(_ snapshot: BootstrapEntityEnvelopeV1) throws -> String {
        switch CloudEntityType(rawValue: snapshot.entityType) {
        case .farm:
            let payload = try decodePayload(snapshot.sourcePayload)
            return payload.kind == .updateFarmLocation ? "1" : "0"
        case .semenDonor:
            let payload = try decodePayload(snapshot.sourcePayload)
            if case .upsertSemenDonor(let draft) = payload.careCommand {
                return draft.linkedRamID == nil ? "5" : "25"
            }
            return "5"
        case .pen, .breedingProgram, .productionBatch, .feedIngredient, .feedRecipe, .inventoryLot, .semen, .careRule:
            return "10"
        case .sheep, .feedRecipeComponent:
            return "20"
        case .weight, .weaning, .transfer, .removal, .batchMembership, .feed, .health, .reproduction, .note:
            return "30"
        case .tmrBaseline:
            return "32"
        case .pedigreeChange:
            return "35"
        case .alertDeferral:
            return "40"
        default:
            return "revision-\(snapshot.sourceRevision)"
        }
    }

    private static func decodePayload(_ data: Data) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }

    private static func decodeSnapshot(_ data: Data) throws -> BootstrapEntityEnvelopeV1 {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BootstrapEntityEnvelopeV1.self, from: data)
    }
}

@MainActor
struct MigrationCloudBootstrapService {
    private static let summaryPrefix = MigrationBaselineV2EvidenceContract.summaryPrefix
    private static let currentBaselineVersion = MigrationBaselineV2EvidenceContract.currentVersion

    /// Builds the provider-neutral entity snapshots used by both CloudKit
    /// migration recovery and Supabase non-empty authority activation. This
    /// method does not insert DomainOperation, Outbox or cloud binding rows.
    func makeProviderNeutralSnapshots(
        farm: FarmRecord,
        context: ModelContext
    ) throws -> [FarmBootstrapEntitySnapshot] {
        guard farm.deletedAt == nil else {
            throw MigrationCloudBootstrapError.farmMissing
        }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farm.id
        }
        let normalizedTags = sheep.map { EarTag.normalized($0.earTag) }
        guard Set(normalizedTags).count == normalizedTags.count else {
            throw MigrationCloudBootstrapError.duplicateEarTag
        }

        var prepared: [(
            entityType: CloudEntityType,
            entityID: UUID,
            revision: Int,
            sourcePayload: Data,
            order: Int
        )] = []
        try appendFarm(farm, to: &prepared)
        try appendRecords(farmID: farm.id, context: context, to: &prepared)
        return prepared.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.entityID.uuidString < $1.entityID.uuidString
        }.map {
            FarmBootstrapEntitySnapshot(
                entityType: $0.entityType,
                entityID: $0.entityID,
                sourceRevision: max(1, $0.revision),
                sourcePayload: $0.sourcePayload,
                replayOrder: $0.order
            )
        }
    }

    func prepare(
        commit: MigrationCommitRecord,
        farm: FarmRecord,
        accountID: UUID,
        context: ModelContext,
        allowsExistingBinding: Bool = false,
        forceRefresh: Bool = false
    ) throws -> MigrationCloudBootstrapResult {
        guard farm.deletedAt == nil else { throw MigrationCloudBootstrapError.farmMissing }
        guard farm.ownerAccountID == accountID, commit.ownerAccountID == accountID else {
            throw MigrationCloudBootstrapError.ownerMismatch
        }
        guard commit.status == .completed, commit.farmID == farm.id else {
            throw MigrationCloudBootstrapError.commitMissing
        }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>()).filter { $0.farmID == farm.id }
        guard bindings.isEmpty || (allowsExistingBinding && bindings.allSatisfy({
            $0.databaseScope == .privateDatabase && $0.state == .active && $0.ownerAccountID == accountID
        })) else { throw MigrationCloudBootstrapError.conflictingCloudBinding }

        if !forceRefresh,
           commit.cloudState != .localCommitted,
           !commit.baselineDigest.isEmpty,
           commit.baselineEntityCount > 0 {
            return .init(
                operationCount: commit.baselineEntityCount,
                photoCount: commit.baselinePhotoCount,
                baselineDigest: commit.baselineDigest,
                wasAlreadyPrepared: true
            )
        }

        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farm.id }
        let normalizedTags = sheep.map { EarTag.normalized($0.earTag) }
        guard Set(normalizedTags).count == normalizedTags.count else {
            throw MigrationCloudBootstrapError.duplicateEarTag
        }

        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == farm.id && $0.deletedAt == nil }
        let existingTransfers = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).filter { $0.farmID == farm.id }
        for photo in photos {
            let url = Self.assetURL(relativePath: photo.relativePath)
            guard let data = try? Data(contentsOf: url) else { throw MigrationCloudBootstrapError.missingPhoto(photo.legacySourceKey) }
            guard CloudPayloadDigest.hex(for: data) == photo.sha256 else {
                throw MigrationCloudBootstrapError.photoDigestMismatch(photo.legacySourceKey)
            }
            if !existingTransfers.contains(where: { $0.assetID == photo.id && $0.direction == .upload }) {
                context.insert(CloudAssetTransfer(
                    id: StableMigrationID.uuid(sessionID: commit.sessionID, sourceKey: "cloud-bootstrap-asset:\(photo.id.uuidString.lowercased())"),
                    farmID: farm.id,
                    assetID: photo.id,
                    localRelativePath: photo.relativePath,
                    payloadDigest: photo.sha256,
                    byteCount: Int64(data.count),
                    direction: .upload,
                    sourceDigest: photo.sourceSHA256.isEmpty ? photo.sha256 : photo.sourceSHA256
                ))
            }
        }

        let snapshots = try makeProviderNeutralSnapshots(farm: farm, context: context)
        let prepared = snapshots.map {
            (
                entityType: $0.entityType,
                entityID: $0.entityID,
                revision: $0.sourceRevision,
                sourcePayload: $0.sourcePayload,
                order: $0.replayOrder
            )
        }

        let existing = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farm.id && $0.kindRawValue == DomainOperationKind.bootstrapEntity.rawValue
        }
        var existingByID: [UUID: DomainOperation] = [:]
        for operation in existing {
            guard existingByID.updateValue(operation, forKey: operation.id) == nil else {
                throw MigrationCloudBootstrapError.invalidExistingBaselineOperation
            }
        }
        var baselineOutboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farm.id
        }
        let allOutboxes = try context.fetch(FetchDescriptor<OutboxItem>())
        var digestLines: [String] = []
        var insertedCount = 0
        let bootstrapAuthorizedAt = Date.now
        for item in prepared {
            let sourceDigest = CloudPayloadDigest.hex(for: item.sourcePayload)
            let operationID = StableMigrationID.uuid(
                sessionID: commit.sessionID,
                sourceKey: "cloud-bootstrap:\(item.entityType.rawValue):\(item.entityID.uuidString.lowercased()):\(sourceDigest)"
            )
            digestLines.append("\(item.entityType.rawValue):\(item.entityID.uuidString.lowercased()):\(sourceDigest)")
            if let existingOperation = existingByID[operationID] {
                try MigrationBaselineV2EvidenceContract.validateExistingOperation(
                    existingOperation,
                    commit: commit,
                    accountID: accountID,
                    entityType: item.entityType,
                    entityID: item.entityID,
                    sourceRevision: item.revision,
                    sourcePayload: item.sourcePayload,
                    slot: item.order
                )
                let matchingOutboxes = baselineOutboxes.filter { $0.operationID == operationID }
                if matchingOutboxes.isEmpty {
                    let outboxID = StableMigrationID.uuid(
                        sessionID: commit.sessionID,
                        sourceKey: "cloud-bootstrap-outbox:\(operationID.uuidString.lowercased())"
                    )
                    guard !allOutboxes.contains(where: { $0.id == outboxID }) else {
                        throw MigrationCloudBootstrapError.conflictingBaselineOutbox
                    }
                    let repaired = OutboxItem(
                        id: outboxID,
                        farmID: existingOperation.farmID,
                        accountID: existingOperation.accountID,
                        operationID: existingOperation.id,
                        entityType: existingOperation.entityType,
                        entityID: existingOperation.entityID,
                        baseRevision: existingOperation.baseRevision,
                        payloadDigest: existingOperation.payloadDigest
                    )
                    context.insert(repaired)
                    baselineOutboxes.append(repaired)
                    insertedCount += 1
                } else {
                    guard matchingOutboxes.count == 1,
                          let outbox = matchingOutboxes.first,
                          outbox.accountID == existingOperation.accountID,
                          outbox.entityType == existingOperation.entityType,
                          outbox.entityID == existingOperation.entityID,
                          outbox.baseRevision == existingOperation.baseRevision,
                          outbox.payloadDigest == existingOperation.payloadDigest else {
                        throw MigrationCloudBootstrapError.conflictingBaselineOutbox
                    }
                }
                continue
            }

            let snapshot = BootstrapEntityEnvelopeV1(
                entityType: item.entityType.rawValue,
                entityID: item.entityID,
                sourceRevision: item.revision,
                sourcePayload: item.sourcePayload
            )
            var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
            wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(snapshot)
            wrapper.integers["baselineVersion"] = Self.currentBaselineVersion
            wrapper.dates["baselineCutoffAt"] = bootstrapAuthorizedAt
            wrapper.strings["baselineSlot"] = String(item.order)
            let payload = try JSONEncoder.cloud.encode(wrapper)
            let operation = DomainOperation(
                id: operationID,
                farmID: farm.id,
                accountID: accountID,
                kind: .bootstrapEntity,
                // This is the cloud bootstrap authorization time. Historical
                // entity dates remain inside sourcePayload and are not rewritten.
                occurredAt: bootstrapAuthorizedAt,
                summary: "\(Self.summaryPrefix)\(item.entityType.rawValue)",
                entityType: item.entityType.rawValue,
                entityID: item.entityID,
                baseRevision: 0,
                resultingRevision: max(1, item.revision),
                payload: payload
            )
            context.insert(operation)
            let outbox = OutboxItem(
                id: StableMigrationID.uuid(sessionID: commit.sessionID, sourceKey: "cloud-bootstrap-outbox:\(operationID.uuidString.lowercased())"),
                farmID: farm.id,
                accountID: accountID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID,
                baseRevision: operation.baseRevision,
                payloadDigest: operation.payloadDigest
            )
            context.insert(outbox)
            baselineOutboxes.append(outbox)
            insertedCount += 1
        }

        let digest = CloudPayloadDigest.hex(for: Data(digestLines.sorted().joined(separator: "\n").utf8))
        commit.cloudState = .baselineReady
        commit.baselineDigest = digest
        commit.baselineEntityCount = prepared.count
        commit.baselinePhotoCount = photos.count
        commit.cloudLastError = nil
        commit.cloudUpgradedAt = .now
        farm.isLocalOnlyMigration = false
        farm.updatedAt = .now

        return .init(
            operationCount: prepared.count,
            photoCount: photos.count,
            baselineDigest: digest,
            wasAlreadyPrepared: insertedCount == 0
        )
    }

    /// Version 1 migration snapshots omitted the authoritative legacy sheep
    /// status/current-pen flags. Refresh an already-synced owner farm once so
    /// reinstall recovery produces the same herd as the verified source device.
    func refreshEligibleSyncedBaselines(accountID: UUID, context: ModelContext) throws -> [MigrationCloudBootstrapResult] {
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).filter {
            $0.ownerAccountID == accountID && $0.status == .completed && $0.cloudState == .synced
        }
        var results: [MigrationCloudBootstrapResult] = []
        for commit in commits {
            guard let farm = farms.first(where: {
                $0.id == commit.farmID && $0.ownerAccountID == accountID && !$0.isLocalOnlyMigration && $0.deletedAt == nil
            }), bindings.contains(where: {
                $0.farmID == farm.id && $0.ownerAccountID == accountID && $0.databaseScope == .privateDatabase && $0.state == .active
            }) else { continue }

            let farmBootstrapOperations = operations.filter {
                $0.farmID == farm.id && $0.kindRawValue == DomainOperationKind.bootstrapEntity.rawValue
            }
            var hasVersion2 = false
            for operation in farmBootstrapOperations {
                guard CloudPayloadDigest.hex(for: operation.payload) == operation.payloadDigest,
                      let payload = try? decodePayload(operation.payload),
                      payload.kind == .bootstrapEntity else {
                    throw MigrationCloudBootstrapError.invalidExistingBaselineOperation
                }
                hasVersion2 = hasVersion2 ||
                    (payload.integers["baselineVersion"] ?? 1) >= Self.currentBaselineVersion
            }
            if hasVersion2 {
                _ = try MigrationBaselineV2EvidenceContract.requiredOperations(
                    commit: commit,
                    farmID: farm.id,
                    context: context
                )
                continue
            }
            if let (_, bundle) = try RecoveredBaselineReuploadRepairService.completedRecoveryBundle(
                commit: commit,
                context: context
            ) {
                guard let bootstrap = bundle.bootstrap,
                      bootstrap.normalizedVersion >= Self.currentBaselineVersion,
                      bootstrap.digest == commit.baselineDigest,
                      bootstrap.entityCount == commit.baselineEntityCount,
                      bootstrap.photoCount == commit.baselinePhotoCount else {
                    throw MigrationCloudBootstrapError.invalidExistingBaselineOperation
                }
                continue
            }

            results.append(try prepare(
                commit: commit,
                farm: farm,
                accountID: accountID,
                context: context,
                allowsExistingBinding: true,
                forceRefresh: true
            ))
            try context.save()
        }
        return results
    }

    func upgradeEligibleLegacyFarms(accountID: UUID, context: ModelContext) throws -> [MigrationCloudBootstrapResult] {
        let farms = try context.fetch(FetchDescriptor<FarmRecord>()).filter {
            $0.ownerAccountID == accountID && $0.isLocalOnlyMigration && $0.deletedAt == nil
        }
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>())
        var results: [MigrationCloudBootstrapResult] = []
        for farm in farms {
            guard let commit = commits.first(where: { $0.farmID == farm.id && $0.ownerAccountID == accountID && $0.status == .completed }) else {
                continue
            }
            do {
                results.append(try prepare(commit: commit, farm: farm, accountID: accountID, context: context))
                try context.save()
            } catch {
                context.rollback()
                if let failedCommit = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commit.id }) {
                    failedCommit.cloudState = .failed
                    failedCommit.cloudLastError = error.localizedDescription
                    failedCommit.cloudRetryCount += 1
                }
                try context.save()
            }
        }
        return results
    }

    private func appendFarm(
        _ farm: FarmRecord,
        to values: inout [(entityType: CloudEntityType, entityID: UUID, revision: Int, sourcePayload: Data, order: Int)]
    ) throws {
        var payload = FarmCommandCloudPayload(kind: .createFarm)
        payload.strings = ["name": farm.name]
        values.append((.farm, farm.id, 1, try JSONEncoder.cloud.encode(payload), 0))
        if let snapshot = farm.locationSnapshot {
            let command = FarmCommand.updateFarmLocation(
                displayName: snapshot.displayName,
                latitude: snapshot.latitude,
                longitude: snapshot.longitude,
                addressSnapshot: farm.addressSnapshot,
                timeZoneIdentifier: snapshot.timeZoneIdentifier,
                source: snapshot.source,
                horizontalAccuracyMeters: farm.horizontalAccuracyMeters
            )
            values.append((.farm, farm.id, 2, try FarmCommandCloudPayloadEncoder.encode(command), 1))
        }
    }

    private func appendRecords(
        farmID: UUID,
        context: ModelContext,
        to values: inout [(entityType: CloudEntityType, entityID: UUID, revision: Int, sourcePayload: Data, order: Int)]
    ) throws {
        for value in try context.fetch(FetchDescriptor<SemenDonorRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let initial = CareSemenDonorDraft(id: value.id, name: value.name, registrationNumber: value.registrationNumber, breed: value.breed, linkedRamID: nil, note: value.note, status: value.status, expectedRevision: 0)
            values.append((.semenDonor, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.care(.upsertSemenDonor(initial))), 5))
            if let linkedRamID = value.linkedRamID {
                let linked = CareSemenDonorDraft(id: value.id, name: value.name, registrationNumber: value.registrationNumber, breed: value.breed, linkedRamID: linkedRamID, note: value.note, status: value.status, expectedRevision: 1)
                values.append((.semenDonor, value.id, 2, try FarmCommandCloudPayloadEncoder.encode(.care(.upsertSemenDonor(linked))), 25))
            }
        }
        for value in try context.fetch(FetchDescriptor<PenRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.pen, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.createPen(name: value.name, note: value.note)), 10))
        }
        let avatarSelections = try context.fetch(FetchDescriptor<SheepAvatarRecord>())
            .filter { $0.farmID == farmID }
        var latestAvatarBySheepID: [UUID: SheepAvatarRecord] = [:]
        for selection in avatarSelections {
            if let current = latestAvatarBySheepID[selection.sheepID],
               current.updatedAt >= selection.updatedAt {
                continue
            }
            latestAvatarBySheepID[selection.sheepID] = selection
        }
        let activePhotos = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let activePhotosByID = Dictionary(uniqueKeysWithValues: activePhotos.map { ($0.id, $0) })
        let activeReproduction = try context.fetch(FetchDescriptor<ReproductionRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        for value in try context.fetch(FetchDescriptor<SheepRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let entryParity = activeReproduction.first {
                $0.id == LambingEntrySemantics.entryParityBaselineID(sheepID: value.id)
            }?.parity
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.addSheep(earTag: value.earTag, breed: value.breed, sex: value.sex, penID: value.initialPenID, occurredAt: value.enteredAt, birthAt: value.birthAt, currentParity: entryParity, note: value.note)))
            payload.optionalStrings["legacyEarTag"] = value.legacyEarTag
            payload.optionalStrings["legacySourceKey"] = value.legacySourceKey
            payload.strings["purpose"] = value.purpose
            payload.integers["isHistoricalArchive"] = value.isHistoricalArchive ? 1 : 0
            payload.integers["isBreedingRam"] = value.isBreedingRam ? 1 : 0
            payload.integers["legacyStatusSnapshotIsAuthoritative"] = value.legacyStatusSnapshotIsAuthoritative == true ? 1 : 0
            payload.integers["legacyPenSnapshotIsAuthoritative"] = value.legacyPenSnapshotIsAuthoritative == true ? 1 : 0
            payload.strings["legacyStatusRawValue"] = value.statusRawValue
            payload.optionalIdentifiers["damID"] = value.damID
            payload.optionalIdentifiers["sireID"] = value.sireID
            payload.optionalIdentifiers["legacyCurrentPenID"] = value.currentPenID
            payload.optionalIdentifiers["semenDonorID"] = value.semenDonorID
            payload.optionalDates["legacyRemovedAt"] = value.removedAt
            payload.optionalStrings["damProvenance"] = value.damProvenanceRawValue
            payload.optionalStrings["sireProvenance"] = value.sireProvenanceRawValue
            payload.optionalStrings["semenDonorNameSnapshot"] = value.semenDonorNameSnapshot
            payload.optionalStrings["semenDonorRegistrationNumberSnapshot"] = value.semenDonorRegistrationNumberSnapshot
            payload.optionalStrings["semenDonorBreedSnapshot"] = value.semenDonorBreedSnapshot
            if let selection = latestAvatarBySheepID[value.id] {
                let selectedPhotoID: UUID?
                if let photoID = selection.photoAssetID,
                   activePhotosByID[photoID]?.sheepID == value.id {
                    selectedPhotoID = photoID
                } else {
                    selectedPhotoID = nil
                }
                SheepAvatarCloudPayload.write(
                    SheepAvatarPhotoUpdate(photoAssetID: selectedPhotoID),
                    to: &payload
                )
            }
            values.append((.sheep, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 20))
        }
        for value in try context.fetch(FetchDescriptor<WeightRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.weight, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.recordWeight(sheepID: value.sheepID, kilogramsText: value.kilogramsText, occurredAt: value.occurredAt, note: value.note)), 30))
        }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.weaning, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.recordWeaning(sheepID: value.sheepID, weanWeightText: value.weanWeightText, occurredAt: value.occurredAt, birthAt: value.birthAt, birthWeightText: value.birthWeightText, averageDailyGainText: value.averageDailyGainText, damID: value.damID, litterSize: value.litterSize, note: value.note)), 30))
        }
        let steps = try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let drafts = steps.filter { $0.programID == value.id }.sorted { $0.sortOrder < $1.sortOrder }.map { BreedingProgramStepDraft(id: $0.id, dayOffset: $0.dayOffset, action: $0.action) }
            values.append((.breedingProgram, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.createBreedingProgram(name: value.name, createdAt: value.createdAt, steps: drafts)), 10))
        }
        for value in try context.fetch(FetchDescriptor<TransferRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.transfer, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.transferSheep(sheepID: value.sheepID, toPenID: value.toPenID, occurredAt: value.occurredAt, note: value.note)), 30))
        }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.removal, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.removeSheep(sheepID: value.sheepID, kind: value.kind, reason: value.reason, amountText: value.amountText, occurredAt: value.occurredAt, note: value.note, recordID: value.id, removalBatchID: value.removalBatchID, batchTotalAmountText: value.batchTotalAmountText)), 30))
        }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.productionBatch, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.createBatch(name: value.name, purpose: value.purpose, startedAt: value.startedAt, sheepIDs: [], note: value.note)), 10))
        }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.assignSheepToBatch(batchID: value.batchID, sheepID: value.sheepID, joinedAt: value.joinedAt)))
            payload.optionalDates["leftAt"] = value.leftAt
            payload.optionalStrings["leaveReason"] = value.leaveReason
            values.append((.batchMembership, value.id, value.leftAt == nil ? 1 : 2, try JSONEncoder.cloud.encode(payload), 30))
        }
        let feedIngredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let feedIngredientIDs = Set(feedIngredients.map(\.id))
        for value in feedIngredients {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.saveFeedIngredient(FeedIngredientDraft(
                id: value.id,
                name: value.name,
                unit: value.unit,
                category: value.category,
                dryMatterText: value.dryMatterText,
                nutrientSnapshotJSON: value.nutrientSnapshotJSON,
                kind: value.kind,
                sourceTemplateID: value.sourceTemplateID,
                sourceTemplateCode: value.sourceTemplateCode,
                mixtureComponentsJSON: value.mixtureComponentsJSON,
                note: value.note
            ))))
            payload.strings["isActive"] = value.isActive ? "1" : "0"
            values.append((.feedIngredient, value.id, 1, try JSONEncoder.cloud.encode(payload), 10))
        }

        let feedBatches = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && feedIngredientIDs.contains($0.ingredientID)
        }
        let feedBatchIDs = Set(feedBatches.map(\.id))
        for value in feedBatches {
            let command = FarmCommand.saveFeedBatch(FeedBatchDraft(
                id: value.id,
                ingredientID: value.ingredientID,
                batchName: value.batchName,
                purchaseDate: value.purchaseDate,
                supplier: value.supplier,
                storageLocation: value.storageLocation,
                pricePerKilogramText: value.pricePerKilogramText,
                purchasedKilogramsText: value.purchasedKilogramsText,
                packagingKind: value.packagingKind,
                packageCountText: value.packageCountText,
                nominalPackageKilogramsText: value.nominalPackageKilogramsText,
                stockWeightConfirmed: value.stockWeightConfirmed,
                initialKilogramsText: value.initialKilogramsText,
                remainingKilogramsText: value.remainingKilogramsText,
                note: value.note,
                isActive: value.isActive
            ))
            values.append((.feedIngredientBatch, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(command), 12))
        }

        // recordFeedV2 deterministically recreates its own consumption rows.
        // Baseline stock snapshots therefore carry every other authoritative
        // ledger row, but deliberately omit feed consumption/reversal rows so
        // a clean-device replay cannot deduct the same delivery twice.
        let allFeedRecords = try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID }
        let allFeedRecordIDs = Set(allFeedRecords.map(\.id))
        let allFeedRecordLines = try context.fetch(FetchDescriptor<FeedRecordLine>()).filter { $0.farmID == farmID }
        var deterministicFeedTransactionIDs = Set(allFeedRecordLines.map { FeedStockLedger.consumptionID(for: $0.id) })
        deterministicFeedTransactionIDs.formUnion(deterministicFeedTransactionIDs.map(FeedStockLedger.reversalID(for:)))
        let stockTransactions = try context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).filter {
            guard $0.farmID == farmID, $0.deletedAt == nil, feedBatchIDs.contains($0.ingredientBatchID) else { return false }
            let hasFeedSource = $0.sourceRecordID.map(allFeedRecordIDs.contains) == true
            let isFeedGenerated = ($0.kind == .consumption || $0.kind == .reversal) &&
                (hasFeedSource || deterministicFeedTransactionIDs.contains($0.id))
            return !isFeedGenerated
        }
        for value in stockTransactions {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.adjustFeedStock(
                batchID: value.ingredientBatchID,
                kind: value.kind,
                quantityText: value.quantityText,
                occurredAt: value.occurredAt,
                note: value.note
            )))
            payload.strings["baselineProjection"] = "1"
            payload.optionalIdentifiers = [
                "sourceRecordID": value.sourceRecordID,
                "sourceLineID": value.sourceLineID,
            ]
            values.append((.feedStockTransaction, value.id, 1, try JSONEncoder.cloud.encode(payload), 14))
        }

        for value in try context.fetch(FetchDescriptor<FeedStockCountRecord>()).filter({
            $0.farmID == farmID && $0.deletedAt == nil && feedBatchIDs.contains($0.ingredientBatchID)
        }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.countFeedStock(
                countID: value.id,
                batchID: value.ingredientBatchID,
                actualKilogramsText: value.actualKilogramsText,
                method: value.method,
                occurredAt: value.occurredAt,
                note: value.note
            )))
            payload.strings["baselineProjection"] = "1"
            payload.strings["bookBalanceText"] = value.bookBalanceText
            payload.optionalStrings["differenceText"] = value.differenceText
            payload.optionalIdentifiers["adjustmentTransactionID"] = value.adjustmentTransactionID
            values.append((.feedStockCount, value.id, 1, try JSONEncoder.cloud.encode(payload), 15))
        }

        let recipeComponents = try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let components = recipeComponents.filter { $0.recipeID == value.id }.map {
                FeedRecipeComponentDraft(
                    id: $0.id,
                    ingredientID: $0.ingredientID,
                    ingredientBatchID: $0.ingredientBatchID,
                    kilogramsText: $0.kilogramsText,
                    pricePerKilogramText: $0.pricePerKilogramText,
                    nutrientSnapshotJSON: $0.nutrientSnapshotJSON
                )
            }
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.saveFeedRecipe(FeedRecipeDraft(
                id: value.id,
                name: value.name,
                targetPenID: value.targetPenID,
                targetPenName: value.targetPenName,
                stage: value.stage,
                headCount: value.headCount,
                components: components,
                note: value.note
            ))))
            payload.strings["isActive"] = value.isActive ? "1" : "0"
            values.append((.feedRecipe, value.id, 1, try JSONEncoder.cloud.encode(payload), 18))
        }
        let feedLines = try context.fetch(FetchDescriptor<FeedRecordLine>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        for value in try context.fetch(FetchDescriptor<FeedRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let records = feedLines.filter { $0.feedRecordID == value.id }
            let lines = records.map { FarmCommandCloudPayload.FeedLine(id: $0.id, ingredientID: $0.ingredientID, kilogramsText: $0.kilogramsText, ingredientBatchID: $0.ingredientBatchID, ingredientNameSnapshot: $0.ingredientNameSnapshot, ingredientBatchNameSnapshot: $0.ingredientBatchNameSnapshot, pricePerKilogramTextSnapshot: $0.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: $0.nutrientSnapshotJSON, unitSnapshot: $0.unitSnapshot, dryMatterTextSnapshot: $0.dryMatterTextSnapshot) }
            let payload: Data
            if value.legacySourceKey != nil || records.contains(where: { $0.ingredientBatchID == nil }) {
                payload = try FarmCommandCloudPayloadEncoder.encode(.importHistoricalFeed(HistoricalFeedEntryDraft(
                    id: value.id,
                    legacySourceKey: value.legacySourceKey ?? "baseline:\(value.id.uuidString.lowercased())",
                    penID: value.penID,
                    mode: value.mode,
                    occurredAt: value.occurredAt,
                    mealName: value.mealName,
                    feederName: value.feederName,
                    remainingKilogramsText: value.remainingKilogramsText,
                    discardedKilogramsText: value.discardedKilogramsText,
                    remainingCompositionJSON: value.remainingCompositionJSON,
                    lines: records.map {
                        HistoricalFeedLineDraft(
                            id: $0.id,
                            ingredientID: $0.ingredientID,
                            kilogramsText: $0.kilogramsText,
                            ingredientNameSnapshot: $0.ingredientNameSnapshot,
                            ingredientBatchNameSnapshot: $0.ingredientBatchNameSnapshot,
                            pricePerKilogramTextSnapshot: $0.pricePerKilogramTextSnapshot,
                            nutrientSnapshotJSON: $0.nutrientSnapshotJSON ?? "{}",
                            unitSnapshot: $0.unitSnapshot ?? "千克",
                            dryMatterTextSnapshot: $0.dryMatterTextSnapshot
                        )
                    },
                    note: value.note
                )))
            } else {
                payload = try FarmCommandCloudPayloadEncoder.encode(.recordFeedV2(FeedEntryDraft(
                    id: value.id,
                    penID: value.penID,
                    recipeID: value.recipeID,
                    mode: value.mode,
                    occurredAt: value.occurredAt,
                    mealName: value.mealName,
                    feederName: value.feederName,
                    remainingKilogramsText: value.remainingKilogramsText,
                    discardedKilogramsText: value.discardedKilogramsText,
                    remainingCompositionJSON: value.remainingCompositionJSON,
                    recipeHeadCountSnapshot: value.recipeHeadCountSnapshot,
                    actualHeadCountSnapshot: value.actualHeadCountSnapshot,
                    scaleFactorText: value.scaleFactorText,
                    excludedSheepIDs: value.excludedSheepIDs,
                    lines: records.map {
                        FeedLineDraft(id: $0.id, ingredientID: $0.ingredientID, ingredientBatchID: $0.ingredientBatchID, kilogramsText: $0.kilogramsText)
                    },
                    note: value.note
                )), resolvedFeedLines: lines)
            }
            values.append((.feed, value.id, value.revision, payload, 30))
        }
        // Raw ingredients, stock ledgers, recipes, and projected FeedRecord
        // facts are restored by the generic feeding baseline above. Restore the
        // relational TMR projection and finished-product ledger only after those
        // dependencies exist so production consumption is never deducted twice.
        let tmrSnapshot = try FarmTMRBackupPayload.capture(farmID: farmID, context: context)
        if !tmrSnapshot.isEmpty {
            let baselineID = StableCloudUUID.derived(
                namespace: farmID,
                name: "tmr-baseline-projection"
            )
            values.append((
                .tmrBaseline,
                baselineID,
                1,
                try FarmCommandCloudPayloadEncoder.encodeTMRBaseline(tmrSnapshot),
                32
            ))
        }
        for value in try context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let payload = try FarmCommandCloudPayloadEncoder.encode(.recordFeedTroughObservation(FeedTroughObservationDraft(
                id: value.id,
                penID: value.penID,
                relatedFeedRecordID: value.relatedFeedRecordID,
                feederName: value.feederName,
                observedAt: value.observedAt,
                actualRemainingKilogramsText: value.actualRemainingKilogramsText,
                discardedKilogramsText: value.discardedKilogramsText,
                measurementMethod: value.measurementMethod,
                compositionSnapshotJSON: value.compositionSnapshotJSON,
                note: value.note
            )))
            values.append((.feedTroughObservation, value.id, value.revision, payload, 35))
        }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.inventoryLot, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.receiveInventory(catalogName: value.catalogName, kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment, expiresAt: value.expiresAt, quantityText: value.startingQuantityText, occurredAt: value.receivedAt ?? value.createdAt, note: "旧版迁移库存")), 10))
        }
        for value in try context.fetch(FetchDescriptor<HealthRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.health, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.recordHealth(sheepID: value.sheepID, penID: value.penID, kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment, itemName: value.itemNameSnapshot, occurredAt: value.occurredAt, note: value.note, inventoryLotID: value.inventoryLotID, quantityText: value.quantityText)), 30))
        }
        let offspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.farmID == farmID }
        for value in activeReproduction where value.id != LambingEntrySemantics.entryParityBaselineID(sheepID: value.eweID) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.recordReproduction(eweID: value.eweID, kind: value.kind, occurredAt: value.occurredAt, sireID: value.sireID, semenName: value.semenNameSnapshot, result: value.result, lambCount: value.lambCount, parity: value.parity, birthDeadCount: value.birthDeadCount, offspring: [], note: value.note)))
            payload.optionalIdentifiers["semenID"] = value.semenID
            payload.optionalIdentifiers["batchID"] = value.batchID
            payload.optionalIdentifiers["relatedBreedingRecordID"] = value.relatedBreedingRecordID
            payload.optionalIdentifiers["semenDonorID"] = value.semenDonorID
            payload.optionalStrings["semenDonorNameSnapshot"] = value.semenDonorNameSnapshot
            payload.optionalStrings["semenDonorRegistrationNumberSnapshot"] = value.semenDonorRegistrationNumberSnapshot
            payload.optionalStrings["semenDonorBreedSnapshot"] = value.semenDonorBreedSnapshot
            payload.optionalStrings["paternalSource"] = value.paternalSourceRawValue
            payload.lambingOffspring = offspring.filter { $0.lambingRecordID == value.id }.map {
                .init(id: $0.id, sheepID: $0.sheepID, earTag: $0.legacyEarTag, sexRawValue: $0.sexRawValue, birthWeightText: $0.birthWeightText, isStillborn: $0.isStillborn, autoCreatedSheep: $0.autoCreatedSheep, autoBirthWeightRecordID: $0.autoBirthWeightRecordID, deletedByLambingRevocation: $0.deletedByLambingRevocation, revision: $0.revision, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            }
            values.append((.reproduction, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 30))
        }
        for value in try context.fetch(FetchDescriptor<SemenRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.addSemen(code: value.code, breed: value.breed, source: value.source, batchNumber: value.batchNumber, quantityText: value.quantityText)))
            payload.optionalIdentifiers["donorID"] = value.donorID
            values.append((.semen, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 10))
        }
        for value in try context.fetch(FetchDescriptor<PedigreeChangeRecord>()).filter({ $0.farmID == farmID }) {
            let snapshot = CarePedigreeAuditSnapshot(id: value.id, sheepID: value.sheepID, beforeDamID: value.beforeDamID, afterDamID: value.afterDamID, beforeSireID: value.beforeSireID, afterSireID: value.afterSireID, beforeSemenDonorID: value.beforeSemenDonorID, afterSemenDonorID: value.afterSemenDonorID, beforeDamSourceRawValue: value.beforeDamSourceRawValue, afterDamSourceRawValue: value.afterDamSourceRawValue, beforeSireSourceRawValue: value.beforeSireSourceRawValue, afterSireSourceRawValue: value.afterSireSourceRawValue, reason: value.reason, changedByAccountID: value.changedByAccountID, sheepRevision: value.sheepRevision, occurredAt: value.occurredAt)
            values.append((.pedigreeChange, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.care(.restorePedigreeAudit(snapshot))), 35))
        }
        for value in try context.fetch(FetchDescriptor<NoteRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.note, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.addNote(sheepID: value.sheepID, penID: value.penID, text: value.text, occurredAt: value.occurredAt)), 30))
        }
        for value in try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).filter({ $0.farmID == farmID }) {
            let command: CareCommand
            if let weaningAgeDays = value.weaningAgeDays,
               value.operationalAlertsConfiguredAt != nil {
                command = .updateOperationalAlertRules(.init(
                    id: value.id,
                    pregnancyCheckDays: value.pregnancyCheckDays,
                    gestationDays: value.gestationDays,
                    weaningAgeDays: weaningAgeDays,
                    warningLeadDays: value.warningLeadDays,
                    digestEnabled: value.alertDigestEnabled,
                    digestMinuteOfDay: value.alertDigestMinuteOfDay
                ))
            } else {
                command = .updateRules(
                    id: value.id,
                    pregnancyCheckDays: value.pregnancyCheckDays,
                    gestationDays: value.gestationDays
                )
            }
            values.append((.careRule, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.care(command)), 10))
        }
        for value in try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).filter({ $0.farmID == farmID }) {
            let draft = FarmAlertDeferralDraft(
                id: value.id,
                alertID: value.alertID,
                alertKindRawValue: value.alertKindRawValue,
                subjectID: value.subjectID,
                sourceEntityID: value.sourceEntityID,
                conditionFingerprint: value.conditionFingerprint,
                deferredUntil: value.deferredUntil
            )
            values.append((.alertDeferral, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.care(.deferOperationalAlert(draft))), 40))
        }
    }

    private func decodePayload(_ data: Data) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }

    private static func assetURL(relativePath: String) -> URL {
        PhotoTransferActor.absoluteURL(for: relativePath)
    }
}
