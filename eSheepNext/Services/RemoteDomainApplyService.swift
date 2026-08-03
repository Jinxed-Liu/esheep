import CryptoKit
import Foundation
import SwiftData

enum RemoteApplyOutcome: Sendable, Equatable {
    case applied(rebuildHistoryFrom: Date?)
    case duplicate
    case conflict(localRevision: Int)
}

enum RemoteDomainApplyError: LocalizedError {
    case invalidPayload(String)
    case missingReference(String)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let field): "云端命令缺少或无法解析字段：\(field)。"
        case .missingReference(let field): "云端命令引用的本地对象不存在：\(field)。"
        case .unsupportedOperation(let kind): "当前版本不支持云端命令：\(kind)。"
        }
    }
}

struct RemoteDomainReplayResult: Sendable, Equatable {
    let appliedOperationCount: Int
    let acknowledgedSupersededOperationCount: Int
    let earliestHistoryChange: Date?
}

/// Reconstructs the local audit projection from an already authenticated
/// immutable cloud operation. Bootstrap operations are internal migration
/// machinery and deliberately remain absent from user/business history.
///
/// `DomainOperation` is not the remote authority, but omitting it on live
/// ingest or a clean-install rebuild makes audit history device-local. Keep
/// this projection idempotent by operationID and never create an Outbox row.
enum RemoteDomainAuditProjection {
    @discardableResult
    static func restore(
        _ envelopes: [CloudOperationEnvelope],
        context: ModelContext
    ) throws -> Int {
        var inserted = 0
        for envelope in envelopes {
            if try insertIfNeeded(envelope, context: context) {
                inserted += 1
            }
        }
        return inserted
    }

    @discardableResult
    static func insertIfNeeded(
        _ envelope: CloudOperationEnvelope,
        context: ModelContext
    ) throws -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(
            FarmCommandCloudPayload.self,
            from: envelope.payload
        )
        guard payload.kind != .bootstrapEntity else { return false }
        var descriptor = FetchDescriptor<DomainOperation>(
            predicate: #Predicate<DomainOperation> {
                $0.id == envelope.operationID
            }
        )
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).first == nil else { return false }

        let summary: String
        if let command = try? FarmCommandCloudPayloadDecoder.decode(payload),
           command.operationKind == payload.kind {
            summary = command.summary
        } else {
            summary = fallbackSummary(for: payload.kind)
        }
        let operation = DomainOperation(
            id: envelope.operationID,
            farmID: envelope.farmID,
            accountID: envelope.modifiedByAccountID,
            kind: payload.kind,
            occurredAt: envelope.modifiedAt,
            summary: summary,
            entityType: envelope.entityType,
            entityID: envelope.entityID,
            baseRevision: envelope.baseRevision,
            resultingRevision: envelope.revision,
            payload: envelope.payload
        )
        operation.createdAt = envelope.modifiedAt
        operation.schemaVersion = envelope.schemaVersion
        operation.payloadDigest = envelope.payloadDigest
        operation.modifiedByDeviceID = envelope.modifiedByDeviceID
        operation.capabilityCertificate = envelope.capabilityCertificate
        operation.operationSignature = envelope.operationSignature
        context.insert(operation)
        return true
    }

    /// A correction can be replay-safe even when both its source and result
    /// were later authoritatively deleted. The business row is correctly
    /// absent, but the correction's deletion evidence still belongs in the
    /// audit projection and must survive a clean install.
    @discardableResult
    static func insertSupersededCorrectionTombstoneIfNeeded(
        envelope: CloudOperationEnvelope,
        payload: FarmCommandCloudPayload,
        context: ModelContext
    ) throws -> Bool {
        guard [.correctWeight, .correctTransfer, .correctRemoval]
            .contains(payload.kind),
              let originalID = payload.identifiers["originalID"] else {
            return false
        }
        let operationID: UUID? = envelope.operationID
        var operationDescriptor = FetchDescriptor<TombstoneRecord>(
            predicate: #Predicate<TombstoneRecord> {
                $0.operationID == operationID
            }
        )
        operationDescriptor.fetchLimit = 1
        guard try context.fetch(operationDescriptor).first == nil else {
            return false
        }
        let farmID = envelope.farmID
        let resultID = envelope.entityID
        let tombstones = try context.fetch(
            FetchDescriptor<TombstoneRecord>(
                predicate: #Predicate<TombstoneRecord> {
                    $0.farmID == farmID &&
                        ($0.entityID == originalID || $0.entityID == resultID)
                }
            )
        )
        guard tombstones.contains(where: { $0.entityID == originalID }),
              tombstones.contains(where: { $0.entityID == resultID }) else {
            return false
        }
        let tombstone = TombstoneRecord(
            farmID: envelope.farmID,
            entityType: envelope.entityType,
            entityID: originalID,
            deletedByAccountID: envelope.modifiedByAccountID,
            reason: "远端修正记录已由后续删除覆盖",
            revision: envelope.revision,
            operationID: envelope.operationID
        )
        tombstone.deletedAt = envelope.deletedAt ?? envelope.modifiedAt
        context.insert(tombstone)
        return true
    }

    private static func fallbackSummary(
        for kind: DomainOperationKind
    ) -> String {
        switch kind {
        case .createFarm: "新建牧场"
        case .addPhoto: "添加照片"
        case .resolveConflict: "解决同步冲突"
        case .recoverEntity: "恢复权威记录"
        case .bootstrapEntity: "迁移基线"
        default: kind.rawValue
        }
    }
}

/// Replays an already dependency-sorted authoritative operation set.
/// Missing references fail closed before another operation is attempted.
///
/// A correction whose source and result are both authoritatively tombstoned is
/// the one narrow exception to fail-closed replay: its active business result
/// is provably absent from the final state, so retaining its receipt is safer
/// than repeatedly downloading an unchanged bundle that can never recreate the
/// deleted source row.
enum RemoteDomainReplayExecutor {
    private struct TombstoneFact {
        let index: Int
        let farmID: UUID
        let entityType: String
        let entityID: UUID
        let deletedAt: Date
    }

    private struct ReplayFacts {
        let effectivePayloads: [UUID: FarmCommandCloudPayload]
        let bootstrapOperationIDs: Set<UUID>
        let tombstones: [TombstoneFact]
        let containsRestore: Bool
    }

    static func replay(
        _ operations: [CloudOperationEnvelope],
        farmID: UUID,
        scope: CloudDatabaseScope,
        context: ModelContext,
        service: RemoteDomainApplyService,
        mapper: CloudRecordMapper,
        conflictStage: String,
        baselineCutoffAt: Date?
    ) throws -> RemoteDomainReplayResult {
        guard operations.allSatisfy({ $0.farmID == farmID }) else {
            throw CloudRebuildError.farmMismatch
        }
        let facts = try replayFacts(for: operations)
        var appliedCount = 0
        var acknowledgedSupersededCount = 0
        var earliestHistoryChange: Date?
        var supersededCorrections: [(CloudOperationEnvelope, FarmCommandCloudPayload)] = []

        for (index, envelope) in operations.enumerated() {
            if index.isMultiple(of: 500) {
                try Task.checkCancellation()
            }
            do {
                let isBaselineAuthority =
                    facts.bootstrapOperationIDs.contains(envelope.operationID) ||
                    baselineCutoffAt.map {
                        CloudRebuildRootSnapshot.milliseconds(envelope.modifiedAt) <=
                            CloudRebuildRootSnapshot.milliseconds($0)
                    } == true
                switch try service.applyForAuthoritativeReplay(
                    envelope,
                    context: context,
                    preservesLegacySnapshotAuthority: isBaselineAuthority
                ) {
                case .applied(let changedAt):
                    appliedCount += 1
                    if let changedAt {
                        earliestHistoryChange = min(
                            earliestHistoryChange ?? changedAt,
                            changedAt
                        )
                    }
                case .duplicate:
                    break
                case .conflict(let localRevision):
                    throw CloudRebuildError.operationReplayConflict(
                        stage: conflictStage,
                        operationID: envelope.operationID,
                        baseRevision: envelope.baseRevision,
                        localRevision: localRevision
                    )
                }
            } catch let error as RemoteDomainApplyError {
                guard case .missingReference = error else {
                    throw error
                }
                guard isSafelySuperseded(
                    index: index,
                    envelope: envelope,
                    facts: facts
                ) else {
                    throw CloudRebuildError.stagingValidation(
                        "操作 \(envelope.operationID.uuidString.lowercased()) 无法解析依赖：\(error.localizedDescription)"
                    )
                }
                let payload = facts.effectivePayloads[envelope.operationID]
                let originalID = payload?.identifiers["originalID"]
                context.insert(SecurityIncidentRecord(
                    farmID: farmID,
                    incidentType: "supersededMissingReplayDependency",
                    recordName: mapper.recordName(for: envelope.operationID),
                    accountID: envelope.modifiedByAccountID,
                    deviceID: envelope.modifiedByDeviceID,
                    detail: "权威 \(payload?.kind.rawValue ?? "correction") 引用的原记录 \(originalID?.uuidString.lowercased() ?? "unknown") 已删除，且修正结果 \(envelope.entityID.uuidString.lowercased()) 随后也被权威删除；已按最终权威状态确认为废弃空操作。",
                    rawPayload: envelope.payload
                ))
                insertReceipt(
                    for: envelope,
                    farmID: farmID,
                    scope: scope,
                    context: context,
                    mapper: mapper
                )
                _ = try RemoteDomainAuditProjection.insertIfNeeded(
                    envelope,
                    context: context
                )
                if let payload {
                    // A later Tombstone can be the proof that makes this
                    // correction safely superseded. Delay the synthetic audit
                    // projection until the whole authoritative set has been
                    // replayed, so the result does not depend on operation
                    // iteration order.
                    supersededCorrections.append((envelope, payload))
                }
                acknowledgedSupersededCount += 1
                continue
            }
            _ = try RemoteDomainAuditProjection.insertIfNeeded(
                envelope,
                context: context
            )
            insertReceipt(
                for: envelope,
                farmID: farmID,
                scope: scope,
                context: context,
                mapper: mapper
            )
        }

        for (envelope, payload) in supersededCorrections {
            _ = try RemoteDomainAuditProjection
                .insertSupersededCorrectionTombstoneIfNeeded(
                    envelope: envelope,
                    payload: payload,
                    context: context
                )
        }

        return RemoteDomainReplayResult(
            appliedOperationCount: appliedCount,
            acknowledgedSupersededOperationCount: acknowledgedSupersededCount,
            earliestHistoryChange: earliestHistoryChange
        )
    }

    private static func insertReceipt(
        for envelope: CloudOperationEnvelope,
        farmID: UUID,
        scope: CloudDatabaseScope,
        context: ModelContext,
        mapper: CloudRecordMapper
    ) {
        context.insert(CloudOperationReceipt(
            farmID: farmID,
            operationID: envelope.operationID,
            recordName: mapper.recordName(for: envelope.operationID),
            serverChangeTag: nil,
            databaseScope: scope
        ))
    }

    private static func isSafelySuperseded(
        index: Int,
        envelope: CloudOperationEnvelope,
        facts: ReplayFacts
    ) -> Bool {
        guard !facts.containsRestore,
              let payload = facts.effectivePayloads[envelope.operationID],
              let originalID = payload.identifiers["originalID"] else {
            return false
        }
        let expectedType: CloudEntityType
        switch payload.kind {
        case .correctWeight:
            expectedType = .weight
        case .correctTransfer:
            expectedType = .transfer
        case .correctRemoval:
            expectedType = .removal
        default:
            return false
        }
        guard envelope.entityType == expectedType.rawValue else { return false }
        let originalWasDeleted = facts.tombstones.contains {
            $0.farmID == envelope.farmID &&
                $0.entityType == expectedType.rawValue &&
                $0.entityID == originalID
        }
        let replacementWasDeletedLater = facts.tombstones.contains {
            $0.farmID == envelope.farmID &&
                $0.entityType == expectedType.rawValue &&
                $0.entityID == envelope.entityID &&
                ($0.deletedAt > envelope.modifiedAt ||
                    ($0.deletedAt == envelope.modifiedAt && $0.index > index))
        }
        return originalWasDeleted && replacementWasDeletedLater
    }

    private static func replayFacts(
        for operations: [CloudOperationEnvelope]
    ) throws -> ReplayFacts {
        var payloads: [UUID: FarmCommandCloudPayload] = [:]
        var bootstrapOperationIDs = Set<UUID>()
        var tombstones: [TombstoneFact] = []
        var containsRestore = false

        for (index, envelope) in operations.enumerated() {
            let resolved = try effectivePayload(for: envelope)
            let payload = resolved.payload
            payloads[envelope.operationID] = payload
            if resolved.isBootstrap {
                bootstrapOperationIDs.insert(envelope.operationID)
            }
            switch payload.kind {
            case .restoreTombstonedEntity:
                containsRestore = true
            case .tombstoneEntity:
                guard let entityType = payload.strings["entityType"],
                      entityType == envelope.entityType,
                      let entityID = payload.identifiers["entityID"],
                      entityID == envelope.entityID else {
                    throw RemoteDomainApplyError.invalidPayload("tombstoneEntity")
                }
                tombstones.append(TombstoneFact(
                    index: index,
                    farmID: envelope.farmID,
                    entityType: entityType,
                    entityID: entityID,
                    deletedAt: envelope.deletedAt ?? envelope.modifiedAt
                ))
            default:
                break
            }
        }
        return ReplayFacts(
            effectivePayloads: payloads,
            bootstrapOperationIDs: bootstrapOperationIDs,
            tombstones: tombstones,
            containsRestore: containsRestore
        )
    }

    private static func effectivePayload(
        for envelope: CloudOperationEnvelope
    ) throws -> (payload: FarmCommandCloudPayload, isBootstrap: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var encoded = envelope.payload
        var isBootstrap = false
        for _ in 0..<16 {
            let payload = try decoder.decode(FarmCommandCloudPayload.self, from: encoded)
            switch payload.kind {
            case .bootstrapEntity:
                isBootstrap = true
                guard let snapshotData = payload.dataValues["snapshot"] else {
                    throw RemoteDomainApplyError.invalidPayload("snapshot")
                }
                let snapshot = try decoder.decode(BootstrapEntityEnvelopeV1.self, from: snapshotData)
                try snapshot.validate(for: envelope)
                encoded = snapshot.sourcePayload
            case .recoverEntity:
                guard let source = payload.dataValues["resolvedPayload"],
                      payload.strings["entityType"] == envelope.entityType,
                      let expectedDigest = payload.strings["sourcePayloadDigest"],
                      CloudPayloadDigest.hex(for: source) == expectedDigest else {
                    throw RemoteDomainApplyError.invalidPayload("resolvedPayload")
                }
                encoded = source
            default:
                return (payload, isBootstrap)
            }
        }
        throw RemoteDomainApplyError.invalidPayload("nestedRecoveryDepth")
    }
}

/// A replay-only index for a business store that has just been created or purged.
/// Live sync deliberately does not use it because other writers may mutate that store.
private final class RemoteDomainReplayIndex {
    private struct FarmSheepKey: Hashable {
        let farmID: UUID
        let sheepID: UUID
    }

    private var entities: [ObjectIdentifier: [UUID: any PersistentModel]] = [:]
    private var transfersBySheep: [FarmSheepKey: [TransferRecord]] = [:]
    private var normalizedEarTagOwners: [UUID: [String: Set<UUID>]] = [:]
    /// Farm rows do not carry a revision field. During an empty-store replay,
    /// keep their revision lineage here instead of consulting the retained
    /// local DomainOperation audit log from the cache being replaced.
    private var farmRevisions: [UUID: Int] = [:]
    func rebuildFromPendingInserts(in context: ModelContext) {
        entities.removeAll(keepingCapacity: true)
        transfersBySheep.removeAll(keepingCapacity: true)
        normalizedEarTagOwners.removeAll(keepingCapacity: true)
        for model in context.insertedModelsArray {
            register(model)
        }
    }

    func rebuildFromPersistentStore(
        farmID: UUID,
        in context: ModelContext
    ) throws {
        entities.removeAll(keepingCapacity: true)
        transfersBySheep.removeAll(keepingCapacity: true)
        normalizedEarTagOwners.removeAll(keepingCapacity: true)
        farmRevisions.removeAll(keepingCapacity: true)

        for value in try context.fetch(FetchDescriptor<PenRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<SheepRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<WeightRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<TransferRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedIngredientRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(
            FetchDescriptor<FeedRecipeComponentRecord>()
        ) where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<HealthRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<ReproductionRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<SemenRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<NoteRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            where value.farmID == farmID {
            register(value)
        }

        let farmOperations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter {
                $0.farmID == farmID &&
                    $0.entityType == CloudEntityType.farm.rawValue
            }
        setFarmRevision(
            max(1, farmOperations.map(\.resultingRevision).max() ?? 1),
            for: farmID
        )
    }

    func fetch<T: PersistentModel>(_ type: T.Type, id: UUID) -> T? where T: AnyObject {
        entities[ObjectIdentifier(type)]?[id] as? T
    }

    func transfers(farmID: UUID, sheepID: UUID) -> [TransferRecord] {
        transfersBySheep[FarmSheepKey(farmID: farmID, sheepID: sheepID)] ?? []
    }

    func hasEarTagConflict(farmID: UUID, normalizedEarTag: String, excluding sheepID: UUID) -> Bool {
        normalizedEarTagOwners[farmID]?[normalizedEarTag]?.contains(where: { $0 != sheepID }) == true
    }

    func farmRevision(for farmID: UUID) -> Int {
        farmRevisions[farmID] ?? 1
    }

    func setFarmRevision(_ revision: Int, for farmID: UUID) {
        farmRevisions[farmID] = revision
    }

    func replaceEarTag(for sheep: SheepRecord, with normalizedEarTag: String) {
        let oldTag = EarTag.normalized(sheep.earTag)
        if oldTag != normalizedEarTag {
            normalizedEarTagOwners[sheep.farmID]?[oldTag]?.remove(sheep.id)
        }
        normalizedEarTagOwners[sheep.farmID, default: [:]][normalizedEarTag, default: []].insert(sheep.id)
    }

    fileprivate func register(_ model: any PersistentModel) {
        switch model {
        case let value as PenRecord: register(value, id: value.id)
        case let value as SheepRecord:
            register(value, id: value.id)
            normalizedEarTagOwners[value.farmID, default: [:]][EarTag.normalized(value.earTag), default: []].insert(value.id)
        case let value as WeightRecord: register(value, id: value.id)
        case let value as WeaningRecord: register(value, id: value.id)
        case let value as BreedingProgramRecord: register(value, id: value.id)
        case let value as TransferRecord:
            if register(value, id: value.id) {
                transfersBySheep[FarmSheepKey(farmID: value.farmID, sheepID: value.sheepID), default: []].append(value)
            }
        case let value as RemovalRecord: register(value, id: value.id)
        case let value as ProductionBatchRecord: register(value, id: value.id)
        case let value as BatchMembershipRecord: register(value, id: value.id)
        case let value as FeedIngredientRecord: register(value, id: value.id)
        case let value as FeedRecipeRecord: register(value, id: value.id)
        case let value as FeedRecipeComponentRecord: register(value, id: value.id)
        case let value as FeedRecord: register(value, id: value.id)
        case let value as InventoryLotRecord: register(value, id: value.id)
        case let value as HealthRecord: register(value, id: value.id)
        case let value as ReproductionRecord: register(value, id: value.id)
        case let value as SemenRecord: register(value, id: value.id)
        case let value as NoteRecord: register(value, id: value.id)
        case let value as PhotoAssetRecord: register(value, id: value.id)
        default: break
        }
    }

    @discardableResult
    private func register<T: PersistentModel>(_ model: T, id: UUID) -> Bool {
        let typeID = ObjectIdentifier(T.self)
        let inserted = entities[typeID]?[id] == nil
        entities[typeID, default: [:]][id] = model
        return inserted
    }
}

struct RemoteDomainApplyService {
    private let replayIndex: RemoteDomainReplayIndex?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(replayAssumesEmptyBusinessStore: Bool = false) {
        replayIndex = replayAssumesEmptyBusinessStore ? RemoteDomainReplayIndex() : nil
    }

    func prepareResumableReplay(
        farmID: UUID,
        context: ModelContext
    ) throws {
        try replayIndex?.rebuildFromPersistentStore(
            farmID: farmID,
            in: context
        )
    }

    func apply(_ envelope: CloudOperationEnvelope, context: ModelContext) throws -> RemoteApplyOutcome {
        try applyDecoded(
            envelope,
            context: context,
            preservesLegacySnapshotAuthority: false
        )
    }

    fileprivate func applyForAuthoritativeReplay(
        _ envelope: CloudOperationEnvelope,
        context: ModelContext,
        preservesLegacySnapshotAuthority: Bool
    ) throws -> RemoteApplyOutcome {
        try applyDecoded(
            envelope,
            context: context,
            preservesLegacySnapshotAuthority: preservesLegacySnapshotAuthority
        )
    }

    func applyBaselineProjection(
        _ envelope: CloudOperationEnvelope,
        context: ModelContext
    ) throws -> RemoteApplyOutcome {
        try applyDecoded(
            envelope,
            context: context,
            preservesLegacySnapshotAuthority: true
        )
    }

    private func applyDecoded(
        _ envelope: CloudOperationEnvelope,
        context: ModelContext,
        preservesLegacySnapshotAuthority: Bool
    ) throws -> RemoteApplyOutcome {
        let payload = try decoder.decode(FarmCommandCloudPayload.self, from: envelope.payload)
        if let expected = expectedEntityType(for: payload.kind), expected.rawValue != envelope.entityType {
            throw RemoteDomainApplyError.invalidPayload("kind")
        }

        switch payload.kind {
        case .care:
            guard let command = payload.careCommand else { throw RemoteDomainApplyError.invalidPayload("careCommand") }
            if try FarmCareCommandHandler
                .repairRemotePedigreeCheckpointOverlapIfNeeded(
                    command,
                    farmID: envelope.farmID,
                    resultingRevision: envelope.revision,
                    accountID: envelope.modifiedByAccountID,
                    modifiedAt: envelope.modifiedAt,
                    context: context
                ) {
                return .applied(rebuildHistoryFrom: command.rebuildHistoryFrom)
            }
            if try FarmCareCommandHandler.isApplied(command, farmID: envelope.farmID, context: context) { return .duplicate }
            let result = try FarmCareCommandHandler.validateAndApply(
                command,
                farmID: envelope.farmID,
                accountID: envelope.modifiedByAccountID,
                context: context,
                modifiedAt: envelope.modifiedAt
            )
            replayIndex?.rebuildFromPendingInserts(in: context)
            guard result.entityType.rawValue == envelope.entityType, result.entityID == envelope.entityID else { throw RemoteDomainApplyError.invalidPayload("careCommand.target") }
            return .applied(rebuildHistoryFrom: command.rebuildHistoryFrom)
        case .createFarm:
            return .duplicate
        case .updateFarmLocation:
            let farmID = envelope.farmID
            var farmDescriptor = FetchDescriptor<FarmRecord>(
                predicate: #Predicate<FarmRecord> { $0.id == farmID && $0.deletedAt == nil }
            )
            farmDescriptor.fetchLimit = 1
            guard let farm = try context.fetch(farmDescriptor).first else {
                throw RemoteDomainApplyError.missingReference("farmID")
            }
            let localRevision: Int
            if let replayIndex {
                localRevision = replayIndex.farmRevision(for: farmID)
            } else {
                let entityID = farm.id
                let operationDescriptor = FetchDescriptor<DomainOperation>(
                    predicate: #Predicate<DomainOperation> { $0.farmID == farmID && $0.entityID == entityID }
                )
                localRevision = try context.fetch(operationDescriptor)
                    .map(\.resultingRevision)
                    .max() ?? 1
            }
            guard localRevision == envelope.baseRevision else { return .conflict(localRevision: localRevision) }
            guard let latitude = Double(try string("latitude", payload)),
                  let longitude = Double(try string("longitude", payload)),
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  let source = FarmLocationSource(rawValue: try string("source", payload)) else {
                throw RemoteDomainApplyError.invalidPayload("location")
            }
            let timeZoneIdentifier = try string("timeZoneIdentifier", payload)
            guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw RemoteDomainApplyError.invalidPayload("timeZoneIdentifier") }
            farm.locationDisplayName = try string("displayName", payload)
            farm.latitude = latitude
            farm.longitude = longitude
            farm.coordinateReferenceSystem = "wgs84"
            farm.addressSnapshot = optionalString("addressSnapshot", payload)
            farm.timeZoneIdentifier = timeZoneIdentifier
            farm.locationSourceRawValue = source.rawValue
            farm.horizontalAccuracyMeters = optionalString("horizontalAccuracyMeters", payload).flatMap(Double.init)
            farm.locationUpdatedAt = envelope.modifiedAt
            farm.updatedAt = envelope.modifiedAt
            replayIndex?.setFarmRevision(envelope.revision, for: farmID)
            return .applied(rebuildHistoryFrom: nil)
        case .createPen:
            if try exists(PenRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(PenRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), note: payload.strings["note"] ?? "", createdAt: envelope.modifiedAt), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .updatePen:
            guard let record = try fetch(PenRecord.self, id: try identifier("penID", payload), context: context) else { throw RemoteDomainApplyError.missingReference("penID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            record.name = try string("name", payload)
            record.note = payload.strings["note"] ?? ""
            record.updatedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: nil)
        case .setPenActive:
            guard let record = try fetch(PenRecord.self, id: try identifier("penID", payload), context: context) else { throw RemoteDomainApplyError.missingReference("penID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            record.isActive = payload.integers["isActive"] == 1
            record.updatedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: nil)
        case .addSheep:
            if try exists(SheepRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let normalizedEarTag = EarTag.normalized(try string("earTag", payload))
            let hasEarTagConflict: Bool
            if let replayIndex {
                hasEarTagConflict = replayIndex.hasEarTagConflict(
                    farmID: envelope.farmID,
                    normalizedEarTag: normalizedEarTag,
                    excluding: envelope.entityID
                )
            } else {
                let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                hasEarTagConflict = sheep.contains(where: {
                    $0.farmID == envelope.farmID &&
                    $0.id != envelope.entityID &&
                    EarTag.normalized($0.earTag) == normalizedEarTag
                })
            }
            if hasEarTagConflict {
                return .conflict(localRevision: 0)
            }
            let record = SheepRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                earTag: try string("earTag", payload),
                legacyEarTag: optionalString("legacyEarTag", payload),
                legacySourceKey: optionalString("legacySourceKey", payload),
                isHistoricalArchive: payload.integers["isHistoricalArchive"] == 1,
                breed: try string("breed", payload),
                purpose: payload.strings["purpose"] ?? "未分类",
                sex: SheepSex(rawValue: try string("sex", payload)) ?? .unknown,
                penID: optionalID("penID", payload),
                enteredAt: try date("occurredAt", payload),
                birthAt: optionalDate("birthAt", payload),
                damID: optionalID("damID", payload),
                sireID: optionalID("sireID", payload),
                damProvenance: optionalString("damProvenance", payload).flatMap(PedigreeRelationSource.init(rawValue:)),
                sireProvenance: optionalString("sireProvenance", payload).flatMap(PedigreeRelationSource.init(rawValue:)),
                semenDonorID: optionalID("semenDonorID", payload),
                semenDonorNameSnapshot: optionalString("semenDonorNameSnapshot", payload),
                semenDonorRegistrationNumberSnapshot: optionalString("semenDonorRegistrationNumberSnapshot", payload),
                semenDonorBreedSnapshot: optionalString("semenDonorBreedSnapshot", payload),
                note: payload.strings["note"] ?? ""
            )
            record.revision = envelope.revision
            record.isBreedingRam = payload.integers["isBreedingRam"] == 1
            record.legacyStatusSnapshotIsAuthoritative = payload.integers["legacyStatusSnapshotIsAuthoritative"] == 1
            record.legacyPenSnapshotIsAuthoritative = payload.integers["legacyPenSnapshotIsAuthoritative"] == 1
            if record.legacyStatusSnapshotIsAuthoritative == true,
               let status = payload.strings["legacyStatusRawValue"].flatMap(SheepStatus.init(rawValue:)) {
                record.statusRawValue = status.rawValue
                record.removedAt = optionalDate("legacyRemovedAt", payload)
            }
            if record.legacyPenSnapshotIsAuthoritative == true, record.status == .active {
                record.currentPenID = optionalID("legacyCurrentPenID", payload)
            } else if record.status != .active {
                record.currentPenID = nil
            }
            record.updatedAt = envelope.modifiedAt
            if let avatarUpdate = SheepAvatarCloudPayload.update(from: payload) {
                try SheepAvatarSelectionStore.apply(
                    avatarUpdate,
                    sheepID: record.id,
                    farmID: envelope.farmID,
                    updatedAt: envelope.modifiedAt,
                    context: context
                )
            }
            insertIndexed(record, context: context)
            if let currentParity = payload.integers["currentParity"] {
                guard currentParity >= 0, record.sex == .ewe else {
                    throw RemoteDomainApplyError.invalidPayload("currentParity")
                }
                let parityID = LambingEntrySemantics.entryParityBaselineID(sheepID: record.id)
                if !(try exists(ReproductionRecord.self, id: parityID, context: context)) {
                    context.insert(ReproductionRecord(
                        id: parityID,
                        farmID: envelope.farmID,
                        eweID: record.id,
                        kind: .parityBaseline,
                        occurredAt: record.enteredAt,
                        parity: currentParity,
                        note: "建档时当前胎次"
                    ))
                }
            }
            return .applied(rebuildHistoryFrom: record.enteredAt)
        case .updateSheepProfile:
            guard let record = try fetch(SheepRecord.self, id: try identifier("sheepID", payload), context: context) else { throw RemoteDomainApplyError.missingReference("sheepID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            let earTag = try string("earTag", payload)
            let normalized = EarTag.normalized(earTag)
            let hasEarTagConflict: Bool
            if let replayIndex {
                hasEarTagConflict = replayIndex.hasEarTagConflict(
                    farmID: envelope.farmID,
                    normalizedEarTag: normalized,
                    excluding: record.id
                )
            } else {
                let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                hasEarTagConflict = sheep.contains(where: {
                    $0.farmID == envelope.farmID && $0.id != record.id && EarTag.normalized($0.earTag) == normalized
                })
            }
            guard !hasEarTagConflict else {
                return .conflict(localRevision: record.revision)
            }
            replayIndex?.replaceEarTag(for: record, with: normalized)
            record.earTag = earTag
            record.breed = try string("breed", payload)
            record.sexRawValue = try string("sex", payload)
            if record.sex != .ram { record.isBreedingRam = false }
            record.birthAt = optionalDate("birthAt", payload)
            record.note = payload.strings["note"] ?? ""
            record.updatedAt = envelope.modifiedAt
            record.revision = envelope.revision
            if let currentParity = payload.integers["currentParity"] {
                guard currentParity >= 0, record.sex == .ewe else {
                    throw RemoteDomainApplyError.invalidPayload("currentParity")
                }
                let parityID = LambingEntrySemantics.parityCorrectionID(sheepID: record.id, sheepRevision: record.revision)
                if !(try exists(ReproductionRecord.self, id: parityID, context: context)) {
                    context.insert(ReproductionRecord(
                        id: parityID,
                        farmID: envelope.farmID,
                        eweID: record.id,
                        kind: .parityBaseline,
                        occurredAt: payload.dates["parityRecordedAt"] ?? envelope.modifiedAt,
                        parity: currentParity,
                        note: "档案确认当前胎次"
                    ))
                }
            }
            if let avatarUpdate = SheepAvatarCloudPayload.update(from: payload) {
                try SheepAvatarSelectionStore.apply(
                    avatarUpdate,
                    sheepID: record.id,
                    farmID: envelope.farmID,
                    updatedAt: envelope.modifiedAt,
                    context: context
                )
            }
            return .applied(rebuildHistoryFrom: nil)
        case .recordWeight:
            if try exists(WeightRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(WeightRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: try identifier("sheepID", payload), kilogramsText: try string("kilogramsText", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .correctWeight:
            if try exists(WeightRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(WeightRecord.self, id: originalID, context: context), original.deletedAt == nil else { throw RemoteDomainApplyError.missingReference("originalID") }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.weight.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["reason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            insertIndexed(WeightRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: original.sheepID, kilogramsText: try string("kilogramsText", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .recordWeaning:
            if try exists(WeaningRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(WeaningRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                sheepID: try identifier("sheepID", payload),
                occurredAt: try date("occurredAt", payload),
                weanWeightText: try string("weanWeightText", payload),
                birthAt: optionalDate("birthAt", payload),
                birthWeightText: optionalString("birthWeightText", payload),
                averageDailyGainText: optionalString("averageDailyGainText", payload),
                damID: optionalID("damID", payload),
                litterSize: payload.integers["litterSize"],
                note: payload.strings["note"] ?? ""
            ), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .createBreedingProgram:
            if try exists(BreedingProgramRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            guard !payload.breedingProgramSteps.isEmpty else { throw RemoteDomainApplyError.invalidPayload("breedingProgramSteps") }
            let createdAt = try date("createdAt", payload)
            insertIndexed(BreedingProgramRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), createdAt: createdAt), context: context)
            for step in payload.breedingProgramSteps.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                guard step.dayOffset >= 0, !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RemoteDomainApplyError.invalidPayload("breedingProgramSteps")
                }
                context.insert(BreedingProgramStepRecord(id: step.id, farmID: envelope.farmID, programID: envelope.entityID, dayOffset: step.dayOffset, action: step.action, sortOrder: step.sortOrder, createdAt: createdAt))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .transferSheep:
            if try exists(TransferRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let sheepID = try identifier("sheepID", payload)
            guard let sheep = try fetch(SheepRecord.self, id: sheepID, context: context) else { throw RemoteDomainApplyError.missingReference("sheepID") }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            let occurredAt = try date("occurredAt", payload)
            let transfers: [TransferRecord]
            if let replayIndex {
                transfers = replayIndex.transfers(farmID: envelope.farmID, sheepID: sheepID).filter { $0.deletedAt == nil }
            } else {
                let farmID = envelope.farmID
                transfers = try context.fetch(FetchDescriptor<TransferRecord>(
                    predicate: #Predicate<TransferRecord> {
                        $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
                    }
                ))
            }
            let record = TransferRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: sheepID, fromPenID: FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers), toPenID: optionalID("toPenID", payload), occurredAt: occurredAt, note: payload.strings["note"] ?? "")
            insertIndexed(record, context: context)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .correctTransfer:
            if try exists(TransferRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(TransferRecord.self, id: originalID, context: context), original.deletedAt == nil,
                  let sheep = try fetch(SheepRecord.self, id: original.sheepID, context: context) else { throw RemoteDomainApplyError.missingReference("originalID") }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.transfer.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["reason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            let occurredAt = try date("occurredAt", payload)
            let sheepID = original.sheepID
            let transfers: [TransferRecord]
            if let replayIndex {
                transfers = replayIndex.transfers(farmID: envelope.farmID, sheepID: sheepID).filter { $0.deletedAt == nil }
            } else {
                let farmID = envelope.farmID
                transfers = try context.fetch(FetchDescriptor<TransferRecord>(
                    predicate: #Predicate<TransferRecord> {
                        $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
                    }
                ))
            }
            let replacement = TransferRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: original.sheepID, fromPenID: FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers), toPenID: optionalID("toPenID", payload), occurredAt: occurredAt, note: payload.strings["note"] ?? "")
            insertIndexed(replacement, context: context)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .removeSheep:
            if try exists(RemovalRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let sheepID = try identifier("sheepID", payload)
            guard let sheep = try fetch(SheepRecord.self, id: sheepID, context: context) else {
                throw RemoteDomainApplyError.missingReference("sheepID")
            }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            let occurredAt = try date("occurredAt", payload)
            insertIndexed(RemovalRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                sheepID: sheepID,
                kind: RemovalKind(rawValue: try string("kind", payload)) ?? .culled,
                reason: try string("reason", payload),
                amountText: optionalString("amountText", payload),
                removalBatchID: optionalID("removalBatchID", payload),
                batchTotalAmountText: optionalString("batchTotalAmountText", payload),
                occurredAt: occurredAt,
                note: payload.strings["note"] ?? ""
            ), context: context)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .correctRemoval:
            if try exists(RemovalRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(RemovalRecord.self, id: originalID, context: context), original.deletedAt == nil else { throw RemoteDomainApplyError.missingReference("originalID") }
            guard let sheep = try fetch(SheepRecord.self, id: original.sheepID, context: context) else {
                throw RemoteDomainApplyError.missingReference("sheepID")
            }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.removal.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["correctionReason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            let occurredAt = try date("occurredAt", payload)
            let replacementKind = RemovalKind(rawValue: try string("kind", payload)) ?? .culled
            let retainsBatch = original.removalBatchID != nil && replacementKind == original.kind
            insertIndexed(RemovalRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                sheepID: original.sheepID,
                kind: replacementKind,
                reason: try string("reason", payload),
                amountText: retainsBatch ? nil : optionalString("amountText", payload),
                removalBatchID: retainsBatch ? original.removalBatchID : nil,
                batchTotalAmountText: retainsBatch ? original.batchTotalAmountText : nil,
                occurredAt: occurredAt,
                note: payload.strings["note"] ?? ""
            ), context: context)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .restoreSheep:
            guard let record = try fetch(RemovalRecord.self, id: envelope.entityID, context: context) else { throw RemoteDomainApplyError.missingReference("removalID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            guard let sheep = try fetch(SheepRecord.self, id: record.sheepID, context: context) else {
                throw RemoteDomainApplyError.missingReference("sheepID")
            }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            record.deletedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: .distantPast)
        case .createBatch:
            if try exists(ProductionBatchRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(ProductionBatchRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), purpose: try string("purpose", payload), startedAt: try date("startedAt", payload), note: payload.strings["note"] ?? ""), context: context)
            let sheepIDs = (payload.strings["sheepIDs"] ?? "")
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
            for sheepID in sheepIDs {
                insertIndexed(BatchMembershipRecord(
                    id: StableCloudUUID.derived(namespace: envelope.entityID, name: "batch-member-\(sheepID.uuidString.lowercased())"),
                    farmID: envelope.farmID,
                    batchID: envelope.entityID,
                    sheepID: sheepID,
                    joinedAt: try date("startedAt", payload)
                ), context: context)
            }
            return .applied(rebuildHistoryFrom: nil)
        case .assignBatchMembership:
            if try exists(BatchMembershipRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = BatchMembershipRecord(id: envelope.entityID, farmID: envelope.farmID, batchID: try identifier("batchID", payload), sheepID: try identifier("sheepID", payload), joinedAt: try date("joinedAt", payload))
            record.leftAt = optionalDate("leftAt", payload)
            record.leaveReason = payload.optionalStrings["leaveReason"] ?? nil
            record.updatedAt = envelope.modifiedAt
            insertIndexed(record, context: context)
            if replayIndex == nil, record.leftAt != nil {
                try ProductionBatchLifecycle.reconcile(batchID: record.batchID, farmID: envelope.farmID, context: context, changedAt: envelope.modifiedAt)
            }
            return .applied(rebuildHistoryFrom: try date("joinedAt", payload))
        case .leaveBatchMembership:
            guard let record = try fetch(BatchMembershipRecord.self, id: envelope.entityID, context: context) else { throw RemoteDomainApplyError.missingReference("batchMembership") }
            if record.leftAt != nil { return .duplicate }
            record.leftAt = try date("leftAt", payload)
            record.leaveReason = payload.strings["reason"] ?? ""
            record.updatedAt = envelope.modifiedAt
            if replayIndex == nil {
                try ProductionBatchLifecycle.reconcile(batchID: record.batchID, farmID: envelope.farmID, context: context, changedAt: envelope.modifiedAt)
            }
            return .applied(rebuildHistoryFrom: record.leftAt)
        case .addIngredient:
            if try exists(FeedIngredientRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(FeedIngredientRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), unit: try string("unit", payload), dryMatterText: optionalString("dryMatterText", payload)), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .createRecipe:
            if try exists(FeedRecipeRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(FeedRecipeRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), note: payload.strings["note"] ?? ""), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .addRecipeComponent:
            if try exists(FeedRecipeComponentRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(FeedRecipeComponentRecord(id: envelope.entityID, farmID: envelope.farmID, recipeID: try identifier("recipeID", payload), ingredientID: try identifier("ingredientID", payload), kilogramsText: try string("kilogramsText", payload)), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .recordFeed:
            if try exists(FeedRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = FeedRecord(id: envelope.entityID, farmID: envelope.farmID, penID: try identifier("penID", payload), recipeID: optionalID("recipeID", payload), mode: FeedMode(rawValue: try string("mode", payload)) ?? .limited, occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? "")
            insertIndexed(record, context: context)
            for line in payload.feedLines {
                guard let ingredient = try fetch(FeedIngredientRecord.self, id: line.ingredientID, context: context),
                      ingredient.farmID == envelope.farmID else {
                    throw RemoteDomainApplyError.missingReference("ingredientID")
                }
                context.insert(FeedRecordLine(
                    id: line.id,
                    farmID: envelope.farmID,
                    feedRecordID: record.id,
                    ingredientID: line.ingredientID,
                    kilogramsText: line.kilogramsText,
                    ingredientNameSnapshot: line.ingredientNameSnapshot ?? ingredient.name,
                    ingredientBatchID: line.ingredientBatchID,
                    ingredientBatchNameSnapshot: line.ingredientBatchNameSnapshot,
                    pricePerKilogramTextSnapshot: line.pricePerKilogramTextSnapshot,
                    nutrientSnapshotJSON: line.nutrientSnapshotJSON ?? ingredient.nutrientSnapshotJSON,
                    unitSnapshot: line.unitSnapshot ?? ingredient.unit,
                    dryMatterTextSnapshot: line.dryMatterTextSnapshot ?? ingredient.dryMatterText
                ))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .recordHealth:
            if try exists(HealthRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = HealthRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: optionalID("sheepID", payload), penID: optionalID("penID", payload), kind: HealthRecordKind(rawValue: try string("kind", payload)) ?? .treatment, itemNameSnapshot: try string("itemName", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? "", inventoryLotID: optionalID("inventoryLotID", payload), quantityText: optionalString("quantityText", payload))
            insertIndexed(record, context: context)
            if let inventoryLotID = record.inventoryLotID, let quantity = record.quantityText {
                context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: record.id, name: "inventory-consumption"), farmID: envelope.farmID, inventoryLotID: inventoryLotID, kind: .consumption, quantityText: quantity, occurredAt: record.occurredAt, sourceRecordID: record.id, note: record.itemNameSnapshot))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .receiveInventory:
            if try exists(InventoryLotRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let lot = InventoryLotRecord(id: envelope.entityID, farmID: envelope.farmID, catalogName: try string("catalogName", payload), kind: HealthRecordKind(rawValue: try string("kind", payload)) ?? .treatment, expiresAt: optionalDate("expiresAt", payload), startingQuantityText: try string("quantityText", payload))
            insertIndexed(lot, context: context)
            context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: lot.id, name: "inventory-receipt"), farmID: envelope.farmID, inventoryLotID: lot.id, kind: .receipt, quantityText: lot.startingQuantityText, occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""))
            FarmCareCommandHandler.refreshInventoryExpiryReminder(for: lot, context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .addSemen:
            if try exists(SemenRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = SemenRecord(id: envelope.entityID, farmID: envelope.farmID, code: try string("code", payload), breed: try string("breed", payload), source: payload.strings["source"] ?? "", batchNumber: payload.strings["batchNumber"] ?? "", quantityText: "0", donorID: optionalID("donorID", payload))
            record.revision = envelope.revision
            record.updatedAt = envelope.modifiedAt
            insertIndexed(record, context: context)
            context.insert(SemenTransactionRecord(id: StableCloudUUID.derived(namespace: record.id, name: "semen-receipt"), farmID: envelope.farmID, semenID: record.id, kind: .receipt, quantityText: try string("quantityText", payload), occurredAt: envelope.modifiedAt, sourceRecordID: record.id, note: "冻精入库"))
            return .applied(rebuildHistoryFrom: nil)
        case .recordReproduction:
            if try exists(ReproductionRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let kind = ReproductionRecordKind(rawValue: try string("kind", payload)) ?? .breeding
            let lambCount = payload.integers["lambCount"] ?? 0
            if kind == .lambing, !payload.lambingOffspring.isEmpty, payload.lambingOffspring.count != lambCount {
                throw RemoteDomainApplyError.invalidPayload("lambingOffspring")
            }
            let record = ReproductionRecord(id: envelope.entityID, farmID: envelope.farmID, eweID: try identifier("eweID", payload), kind: kind, occurredAt: try date("occurredAt", payload), sireID: optionalID("sireID", payload), semenID: optionalID("semenID", payload), batchID: optionalID("batchID", payload), relatedBreedingRecordID: optionalID("relatedBreedingRecordID", payload), semenNameSnapshot: optionalString("semenName", payload), semenDonorID: optionalID("semenDonorID", payload), semenDonorNameSnapshot: optionalString("semenDonorNameSnapshot", payload), semenDonorRegistrationNumberSnapshot: optionalString("semenDonorRegistrationNumberSnapshot", payload), semenDonorBreedSnapshot: optionalString("semenDonorBreedSnapshot", payload), paternalSource: optionalString("paternalSource", payload).flatMap(PaternalIdentitySource.init(rawValue:)), result: payload.strings["result"] ?? "", lambCount: lambCount, parity: payload.integers["parity"], birthDeadCount: payload.integers["birthDeadCount"], note: payload.strings["note"] ?? "")
            record.revision = envelope.revision
            record.updatedAt = envelope.modifiedAt
            insertIndexed(record, context: context)
            for detail in payload.lambingOffspring {
                if let sheepID = detail.sheepID, !(try exists(SheepRecord.self, id: sheepID, context: context)) {
                    throw RemoteDomainApplyError.missingReference("lambingOffspring.sheepID")
                }
                let offspring = LambingOffspringRecord(id: detail.id, farmID: envelope.farmID, lambingRecordID: record.id, sheepID: detail.sheepID, legacyEarTag: detail.earTag, sexRawValue: detail.sexRawValue, birthWeightText: detail.birthWeightText, isStillborn: detail.isStillborn ?? false, autoCreatedSheep: detail.autoCreatedSheep ?? false, autoBirthWeightRecordID: detail.autoBirthWeightRecordID)
                offspring.deletedByLambingRevocation = detail.deletedByLambingRevocation ?? false
                offspring.revision = detail.revision ?? 1
                offspring.updatedAt = detail.updatedAt ?? envelope.modifiedAt
                offspring.deletedAt = detail.deletedAt
                context.insert(offspring)
            }
            return .applied(rebuildHistoryFrom: nil)
        case .addNote:
            if try exists(NoteRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(NoteRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: optionalID("sheepID", payload), penID: optionalID("penID", payload), text: try string("text", payload), occurredAt: try date("occurredAt", payload)), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .addPhoto:
            let sha256 = try string("sha256", payload)
            let mimeType = try string("mimeType", payload)
            guard sha256.count == 64 else {
                throw RemoteDomainApplyError.invalidPayload("sha256")
            }
            let existing: PhotoAssetRecord?
            if let indexed = replayIndex?.fetch(
                PhotoAssetRecord.self,
                id: envelope.entityID
            ) {
                existing = indexed
            } else {
                existing = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                    .first(where: {
                        $0.id == envelope.entityID &&
                            $0.farmID == envelope.farmID
                    })
            }
            if let existing {
                guard existing.sha256 == sha256,
                      existing.mimeType == mimeType else {
                    throw RemoteDomainApplyError.invalidPayload("photo.identity")
                }
                // Base revision zero is the original immutable add. Only a
                // later, explicitly versioned projection refresh may repair a
                // legacy sheep association for the same binary asset.
                guard envelope.baseRevision > 0 else { return .duplicate }
                if let sheepID = optionalID("sheepID", payload) {
                    guard try exists(SheepRecord.self, id: sheepID, context: context) else {
                        throw RemoteDomainApplyError.missingReference("photo.sheepID")
                    }
                    existing.sheepID = sheepID
                }
                if let originalEarTag = payload.strings["originalEarTag"] {
                    existing.originalEarTag = originalEarTag
                }
                existing.sourceSHA256 = payload.strings["sourceSHA256"] ?? existing.sourceSHA256
                existing.sourcePixelWidth = payload.integers["sourcePixelWidth"] ?? existing.sourcePixelWidth
                existing.sourcePixelHeight = payload.integers["sourcePixelHeight"] ?? existing.sourcePixelHeight
                existing.cloudPixelWidth = payload.integers["cloudPixelWidth"] ?? existing.cloudPixelWidth
                existing.cloudPixelHeight = payload.integers["cloudPixelHeight"] ?? existing.cloudPixelHeight
                existing.capturedAt = payload.optionalDates["capturedAt"] ?? existing.capturedAt
                return .applied(rebuildHistoryFrom: nil)
            }
            let asset = PhotoAssetRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                sheepID: optionalID("sheepID", payload),
                legacySourceKey: "supabase:\(envelope.entityID.uuidString.lowercased())",
                originalEarTag: payload.strings["originalEarTag"] ?? "",
                relativePath: "",
                sha256: sha256,
                mimeType: mimeType
            )
            asset.sourceSHA256 = payload.strings["sourceSHA256"] ?? sha256
            asset.sourcePixelWidth = payload.integers["sourcePixelWidth"] ?? 0
            asset.sourcePixelHeight = payload.integers["sourcePixelHeight"] ?? 0
            asset.cloudPixelWidth = payload.integers["cloudPixelWidth"] ?? 0
            asset.cloudPixelHeight = payload.integers["cloudPixelHeight"] ?? 0
            asset.capturedAt = payload.optionalDates["capturedAt"] ?? nil
            insertIndexed(asset, context: context)
            context.insert(CloudAssetTransfer(
                farmID: envelope.farmID,
                assetID: asset.id,
                localRelativePath: "",
                payloadDigest: sha256,
                byteCount: Int64(payload.integers["byteCount"] ?? 0),
                direction: .download,
                sourceDigest: asset.sourceSHA256
            ))
            return .applied(rebuildHistoryFrom: nil)
        case .tombstoneEntity:
            guard let entityTypeText = payload.strings["entityType"], let entityType = CloudEntityType(rawValue: entityTypeText), entityTypeText == envelope.entityType else {
                throw RemoteDomainApplyError.invalidPayload("entityType")
            }
            let entityID = try identifier("entityID", payload)
            guard entityID == envelope.entityID else { throw RemoteDomainApplyError.invalidPayload("entityID") }
            let operationID = envelope.operationID
            var tombstoneDescriptor = FetchDescriptor<TombstoneRecord>(
                predicate: #Predicate<TombstoneRecord> { $0.operationID == operationID }
            )
            tombstoneDescriptor.fetchLimit = 1
            if try context.fetch(tombstoneDescriptor).first != nil { return .duplicate }
            if !preservesLegacySnapshotAuthority {
                try releaseLegacyHistoryProjectionAuthority(
                    affectedBy: entityType,
                    entityID: entityID,
                    context: context
                )
            }
            try DomainEntityDeletionService.setDeletedAt(envelope.deletedAt ?? envelope.modifiedAt, type: entityType, id: entityID, farmID: envelope.farmID, context: context)
            let tombstone = TombstoneRecord(
                farmID: envelope.farmID,
                entityType: entityType.rawValue,
                entityID: entityID,
                deletedByAccountID: envelope.modifiedByAccountID,
                reason: payload.strings["reason"] ?? "远端删除",
                revision: envelope.revision,
                operationID: envelope.operationID
            )
            tombstone.deletedAt = envelope.deletedAt ?? envelope.modifiedAt
            context.insert(tombstone)
            return .applied(rebuildHistoryFrom: .distantPast)
        case .restoreTombstonedEntity:
            let tombstoneID = try identifier("tombstoneID", payload)
            let farmID = envelope.farmID
            var tombstoneDescriptor = FetchDescriptor<TombstoneRecord>(
                predicate: #Predicate<TombstoneRecord> { $0.id == tombstoneID && $0.farmID == farmID }
            )
            tombstoneDescriptor.fetchLimit = 1
            guard let tombstone = try context.fetch(tombstoneDescriptor).first,
                  let entityType = CloudEntityType(rawValue: tombstone.entityType) else {
                throw RemoteDomainApplyError.missingReference("tombstoneID")
            }
            if tombstone.restoredByOperationID == envelope.operationID { return .duplicate }
            if !preservesLegacySnapshotAuthority {
                try releaseLegacyHistoryProjectionAuthority(
                    affectedBy: entityType,
                    entityID: tombstone.entityID,
                    context: context
                )
            }
            try DomainEntityDeletionService.setDeletedAt(nil, type: entityType, id: tombstone.entityID, farmID: envelope.farmID, context: context)
            tombstone.restoredAt = envelope.modifiedAt
            tombstone.restoredByOperationID = envelope.operationID
            return .applied(rebuildHistoryFrom: .distantPast)
        case .resolveConflict:
            guard let resolvedPayload = payload.dataValues["resolvedPayload"], let entityType = payload.strings["entityType"], entityType == envelope.entityType else {
                throw RemoteDomainApplyError.invalidPayload("resolvedPayload")
            }
            let changedAt = try ConflictDomainMergeService.apply(payload: resolvedPayload, entityType: entityType, entityID: envelope.entityID, farmID: envelope.farmID, revision: envelope.revision, context: context)
            _ = try Self.markMatchingConflictsResolved(
                farmID: envelope.farmID,
                entityID: envelope.entityID,
                entityType: entityType,
                throughRevision: envelope.revision,
                resolutionOperationID: envelope.operationID,
                resolvedByAccountID: envelope.modifiedByAccountID,
                resolvedByDeviceID: envelope.modifiedByDeviceID,
                note: payload.strings["note"] ?? "远端场主已解决冲突",
                context: context
            )
            replayIndex?.rebuildFromPendingInserts(in: context)
            return .applied(rebuildHistoryFrom: changedAt)
        case .recoverEntity:
            guard let sourcePayload = payload.dataValues["resolvedPayload"],
                  let entityType = payload.strings["entityType"],
                  entityType == envelope.entityType,
                  let expectedDigest = payload.strings["sourcePayloadDigest"],
                  CloudPayloadDigest.hex(for: sourcePayload) == expectedDigest else {
                throw RemoteDomainApplyError.invalidPayload("resolvedPayload")
            }
            let sourceEnvelope = CloudOperationEnvelope(
                farmID: envelope.farmID,
                entityID: envelope.entityID,
                entityType: envelope.entityType,
                schemaVersion: envelope.schemaVersion,
                revision: payload.integers["sourceRevision"] ?? envelope.revision,
                baseRevision: max(0, (payload.integers["sourceRevision"] ?? envelope.revision) - 1),
                operationID: StableCloudUUID.derived(namespace: envelope.operationID, name: "checkpoint-source"),
                modifiedAt: envelope.modifiedAt,
                modifiedByAccountID: envelope.modifiedByAccountID,
                modifiedByDeviceID: envelope.modifiedByDeviceID,
                payload: sourcePayload,
                payloadDigest: expectedDigest,
                capabilityCertificate: envelope.capabilityCertificate,
                operationSignature: envelope.operationSignature,
                deletedAt: nil
            )
            return try applyDecoded(
                sourceEnvelope,
                context: context,
                preservesLegacySnapshotAuthority: preservesLegacySnapshotAuthority
            )
        case .bootstrapEntity:
            guard let snapshotData = payload.dataValues["snapshot"] else {
                throw RemoteDomainApplyError.invalidPayload("snapshot")
            }
            let snapshot = try decoder.decode(BootstrapEntityEnvelopeV1.self, from: snapshotData)
            try snapshot.validate(for: envelope)
            let sourceEnvelope = CloudOperationEnvelope(
                farmID: envelope.farmID,
                entityID: envelope.entityID,
                entityType: envelope.entityType,
                schemaVersion: envelope.schemaVersion,
                revision: snapshot.sourceRevision,
                baseRevision: max(0, snapshot.sourceRevision - 1),
                operationID: StableCloudUUID.derived(namespace: envelope.operationID, name: "migration-bootstrap-source"),
                modifiedAt: envelope.modifiedAt,
                modifiedByAccountID: envelope.modifiedByAccountID,
                modifiedByDeviceID: envelope.modifiedByDeviceID,
                payload: snapshot.sourcePayload,
                payloadDigest: snapshot.sourcePayloadDigest,
                capabilityCertificate: envelope.capabilityCertificate,
                operationSignature: envelope.operationSignature,
                deletedAt: envelope.deletedAt
            )
            return try applyDecoded(
                sourceEnvelope,
                context: context,
                preservesLegacySnapshotAuthority: true
            )
        }
    }

    /// Repairs conflict projections for resolution operations that were
    /// already ingested by an older client build. This changes only local
    /// conflict/outbox metadata; it never creates a business operation.
    @discardableResult
    static func reconcileResolvedConflictProjections(
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let resolutions = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter {
                $0.farmID == farmID &&
                    $0.kindRawValue == DomainOperationKind.resolveConflict.rawValue
            }
            .sorted { $0.resultingRevision < $1.resultingRevision }
        var repaired = 0
        for operation in resolutions {
            guard let entityID = operation.entityID,
                  let payload = try? decoder.decode(
                    FarmCommandCloudPayload.self,
                    from: operation.payload
                  ),
                  payload.kind == .resolveConflict,
                  let entityType = payload.strings["entityType"],
                  entityType == operation.entityType else {
                continue
            }
            repaired += try markMatchingConflictsResolved(
                farmID: farmID,
                entityID: entityID,
                entityType: entityType,
                throughRevision: operation.resultingRevision,
                resolutionOperationID: operation.id,
                resolvedByAccountID: operation.accountID,
                resolvedByDeviceID: operation.modifiedByDeviceID,
                note: payload.strings["note"] ?? "远端场主已解决冲突",
                context: context
            )
        }
        if repaired > 0 {
            try context.save()
        }
        return repaired
    }

    @discardableResult
    private static func markMatchingConflictsResolved(
        farmID: UUID,
        entityID: UUID,
        entityType: String,
        throughRevision: Int,
        resolutionOperationID: UUID,
        resolvedByAccountID: UUID,
        resolvedByDeviceID: UUID?,
        note: String,
        context: ModelContext
    ) throws -> Int {
        let conflicts = try context.fetch(FetchDescriptor<SyncConflictRecord>())
            .filter {
                $0.farmID == farmID &&
                    $0.entityID == entityID &&
                    $0.entityType == entityType &&
                    ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue ||
                        $0.statusRawValue == SyncConflictStatus.quarantined.rawValue) &&
                    max($0.localRevision, $0.remoteRevision) < throughRevision
            }
        guard !conflicts.isEmpty else { return 0 }
        for conflict in conflicts {
            conflict.statusRawValue = SyncConflictStatus.ownerResolved.rawValue
            conflict.resolutionNote = note
            conflict.resolutionOperationID = resolutionOperationID
            conflict.resolvedByAccountID = resolvedByAccountID
            conflict.resolvedByDeviceID = resolvedByDeviceID
            conflict.resolvedAt = .now
            conflict.resolutionFailureReason = nil
        }
        let blocked = try context.fetch(FetchDescriptor<OutboxItem>())
            .filter {
                $0.farmID == farmID &&
                    $0.entityID == entityID &&
                    $0.entityType == entityType &&
                    $0.status == .blockedConflict
            }
        for item in blocked {
            item.statusRawValue = OutboxStatus.supersededRemoteAuthority.rawValue
            item.errorMessage = "superseded_by_conflict_resolution:\(resolutionOperationID.uuidString.lowercased())"
            item.nextRetryAt = nil
        }
        return conflicts.count
    }

    private func expectedEntityType(for kind: DomainOperationKind) -> CloudEntityType? {
        switch kind {
        case .createFarm: .farm
        case .updateFarmLocation: .farm
        case .createPen, .updatePen, .setPenActive: .pen
        case .addSheep, .updateSheepProfile: .sheep
        case .recordWeight, .correctWeight: .weight
        case .recordWeaning: .weaning
        case .createBreedingProgram: .breedingProgram
        case .transferSheep, .correctTransfer: .transfer
        case .removeSheep, .correctRemoval, .restoreSheep: .removal
        case .createBatch: .productionBatch
        case .assignBatchMembership, .leaveBatchMembership: .batchMembership
        case .addIngredient: .feedIngredient
        case .createRecipe: .feedRecipe
        case .addRecipeComponent: .feedRecipeComponent
        case .recordFeed: .feed
        case .recordHealth: .health
        case .receiveInventory: .inventoryLot
        case .addSemen: .semen
        case .recordReproduction: .reproduction
        case .addNote: .note
        case .addPhoto: .photoAsset
        case .care, .tombstoneEntity, .restoreTombstonedEntity, .resolveConflict, .recoverEntity, .bootstrapEntity: nil
        }
    }

    private func releaseLegacyHistoryProjectionAuthority(for sheep: SheepRecord) {
        sheep.legacyStatusSnapshotIsAuthoritative = false
        sheep.legacyPenSnapshotIsAuthoritative = false
    }

    private func releaseLegacyHistoryProjectionAuthority(
        affectedBy entityType: CloudEntityType,
        entityID: UUID,
        context: ModelContext
    ) throws {
        let sheepID: UUID?
        switch entityType {
        case .transfer:
            sheepID = try fetch(TransferRecord.self, id: entityID, context: context)?.sheepID
        case .removal:
            sheepID = try fetch(RemovalRecord.self, id: entityID, context: context)?.sheepID
        default:
            sheepID = nil
        }
        guard let sheepID,
              let sheep = try fetch(SheepRecord.self, id: sheepID, context: context) else {
            return
        }
        releaseLegacyHistoryProjectionAuthority(for: sheep)
    }

    private func string(_ key: String, _ payload: FarmCommandCloudPayload) throws -> String {
        guard let value = payload.strings[key] else { throw RemoteDomainApplyError.invalidPayload(key) }
        return value
    }

    private func optionalString(_ key: String, _ payload: FarmCommandCloudPayload) -> String? {
        payload.optionalStrings[key] ?? nil
    }

    private func identifier(_ key: String, _ payload: FarmCommandCloudPayload) throws -> UUID {
        guard let value = payload.identifiers[key] else { throw RemoteDomainApplyError.invalidPayload(key) }
        return value
    }

    private func optionalID(_ key: String, _ payload: FarmCommandCloudPayload) -> UUID? {
        payload.optionalIdentifiers[key] ?? nil
    }

    private func date(_ key: String, _ payload: FarmCommandCloudPayload) throws -> Date {
        guard let value = payload.dates[key] else { throw RemoteDomainApplyError.invalidPayload(key) }
        return value
    }

    private func optionalDate(_ key: String, _ payload: FarmCommandCloudPayload) -> Date? {
        payload.optionalDates[key] ?? nil
    }

    private func insertIndexed<T: PersistentModel>(_ model: T, context: ModelContext) {
        context.insert(model)
        replayIndex?.register(model)
    }

    private func exists<T: PersistentModel>(_ type: T.Type, id: UUID, context: ModelContext) throws -> Bool where T: AnyObject {
        if let replayIndex {
            // Every entity type queried through exists is registered at its
            // exact insertion site. Because replay starts from an empty/purged
            // business store, a cache miss is authoritative and avoids an
            // unindexed negative SQL scan for every baseline entity.
            return replayIndex.fetch(type, id: id) != nil
        }
        return try fetch(type, id: id, context: context) != nil
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, id: UUID, context: ModelContext) throws -> T? where T: AnyObject {
        if let cached = replayIndex?.fetch(type, id: id) {
            return cached
        }
        let fetched: T? = switch type {
        case is PenRecord.Type:
            try fetchFirst(FetchDescriptor<PenRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is SheepRecord.Type:
            try fetchFirst(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is WeightRecord.Type:
            try fetchFirst(FetchDescriptor<WeightRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is WeaningRecord.Type:
            try fetchFirst(FetchDescriptor<WeaningRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is BreedingProgramRecord.Type:
            try fetchFirst(FetchDescriptor<BreedingProgramRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is TransferRecord.Type:
            try fetchFirst(FetchDescriptor<TransferRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is RemovalRecord.Type:
            try fetchFirst(FetchDescriptor<RemovalRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is ProductionBatchRecord.Type:
            try fetchFirst(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is BatchMembershipRecord.Type:
            try fetchFirst(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedIngredientRecord.Type:
            try fetchFirst(FetchDescriptor<FeedIngredientRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedRecipeRecord.Type:
            try fetchFirst(FetchDescriptor<FeedRecipeRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedRecipeComponentRecord.Type:
            try fetchFirst(FetchDescriptor<FeedRecipeComponentRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedRecord.Type:
            try fetchFirst(FetchDescriptor<FeedRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is InventoryLotRecord.Type:
            try fetchFirst(FetchDescriptor<InventoryLotRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is HealthRecord.Type:
            try fetchFirst(FetchDescriptor<HealthRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is ReproductionRecord.Type:
            try fetchFirst(FetchDescriptor<ReproductionRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is SemenRecord.Type:
            try fetchFirst(FetchDescriptor<SemenRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is NoteRecord.Type:
            try fetchFirst(FetchDescriptor<NoteRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        default:
            nil
        }
        if let fetched {
            replayIndex?.register(fetched)
        }
        return fetched
    }

    private func fetchFirst<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, context: ModelContext) throws -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

enum StableCloudUUID {
    static func derived(namespace: UUID, name: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace.uuidString.lowercased())\n\(name)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
