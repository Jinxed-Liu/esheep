import Foundation
import SwiftData

/// Explicit, closed restoration shapes. No arbitrary table/column writes and
/// no UI command for authorizing a repair. The server approves exact bytes.
struct ESheepCloudBusinessBaselineRepairV2: Codable, Sendable, Equatable {
    let sourceDigest: String
    let projection: ESheepCloudBusinessBaselineValueV2
}

enum ESheepCloudBusinessBaselineValueV2: Codable, Sendable, Equatable {
    case pen(id: UUID, isActive: Bool)
    case batchMembership(id: UUID, batchID: UUID, sheepID: UUID, joinedAt: Date,
                         leftAt: Date?, leaveReason: String?)
    case productionBatch(id: UUID, status: ProductionBatchStatus, endedAt: Date?)
    case lambingOffspring(id: UUID, lambingRecordID: UUID, sheepID: UUID?,
                          sexRawValue: String, isStillborn: Bool, autoCreatedSheep: Bool,
                          autoBirthWeightRecordID: UUID?)
    case reproduction(id: UUID, eweID: UUID, kind: ReproductionRecordKind, occurredAt: Date,
                      batchID: UUID?, paternalSourceRawValue: String?, duplicateProjectionID: UUID?)
    case transfer(id: UUID, sheepID: UUID, occurredAt: Date, fromPenID: UUID?, recordedAt: Date)
}

/// Lazy once-per-replay indexes; in particular transfer repair must not fetch
/// all 8,600 transfers for every repaired event. Recreated after rollback.
final class ESheepCloudBusinessRepairIndex {
    private(set) var preloadCount = 0
    private var loaded = false
    var memberships: [UUID: BatchMembershipRecord] = [:]
    var batches: [UUID: ProductionBatchRecord] = [:]
    var offspring: [UUID: LambingOffspringRecord] = [:]
    var transfers: [UUID: TransferRecord] = [:]
    var weights: [UUID: WeightRecord] = [:]
    var careBatches: [UUID: CareBatchRecord] = [:]

    func prepare(_ context: ModelContext) throws {
        guard !loaded else { return }
        memberships = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BatchMembershipRecord>()).map { ($0.id,$0) })
        batches = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ProductionBatchRecord>()).map { ($0.id,$0) })
        offspring = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<LambingOffspringRecord>()).map { ($0.id,$0) })
        transfers = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TransferRecord>()).map { ($0.id,$0) })
        weights = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WeightRecord>()).map { ($0.id,$0) })
        careBatches = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CareBatchRecord>()).map { ($0.id,$0) })
        loaded = true
        preloadCount += 1
    }

    func register(_ model: any PersistentModel) {
        guard loaded else { return }
        switch model {
        case let value as BatchMembershipRecord: memberships[value.id] = value
        case let value as ProductionBatchRecord: batches[value.id] = value
        case let value as LambingOffspringRecord: offspring[value.id] = value
        case let value as TransferRecord: transfers[value.id] = value
        case let value as WeightRecord: weights[value.id] = value
        case let value as CareBatchRecord: careBatches[value.id] = value
        default: break
        }
    }
}

enum ESheepCloudBusinessBaselineProjection {
    static func apply(_ baseline: ESheepCloudBusinessBaselineRepairV2,
                      event: ESheepCloudEventEnvelopeV2, context: ModelContext,
                      index: ESheepCloudProjectionReplayContext) throws -> RemoteApplyOutcome {
        let cache = index.historyRepairIndex
        try cache.prepare(context)
        let farmID = event.farmID
        func invalid() -> RemoteDomainApplyError { .invalidPayload("historyRepair.businessIdentity") }
        func validSheep(_ id: UUID) throws -> Bool {
            guard let sheep = try index.sheep(id: id, context: context) else { return false }
            return sheep.farmID == farmID && sheep.deletedAt == nil
        }
        switch baseline.projection {
        case .pen(let id, let isActive):
            guard let pen = try index.pen(id: id, context: context),
                  pen.farmID == farmID, pen.deletedAt == nil else { throw invalid() }
            pen.isActive = isActive
            pen.updatedAt = event.receivedAt

        case .batchMembership(let id, let batchID, let sheepID, let joinedAt, let leftAt, let reason):
            guard let record = cache.memberships[id], record.farmID == farmID, record.deletedAt == nil,
                  record.batchID == batchID, record.sheepID == sheepID, record.joinedAt == joinedAt,
                  let batch = cache.batches[batchID], batch.farmID == farmID, batch.deletedAt == nil,
                  try validSheep(sheepID) else { throw invalid() }
            // Owner-approved source restoration is not new data entry. Two
            // legacy intervals are inverted in BOTH preserved sources. Keep
            // those exact facts (listed in the repair quality report); never
            // invent/clamp a date or silently reopen the membership.
            record.leftAt = leftAt
            record.leaveReason = reason
            record.updatedAt = event.receivedAt

        case .productionBatch(let id, let status, let endedAt):
            guard let batch = cache.batches[id], batch.farmID == farmID, batch.deletedAt == nil,
                  endedAt == nil || endedAt! >= batch.startedAt,
                  status != .active || endedAt == nil else { throw invalid() }
            batch.statusRawValue = status.rawValue
            batch.endedAt = endedAt
            batch.updatedAt = event.receivedAt
            // The ordinary history rebuild still recomputes manual batches
            // from their restored membership intervals; this is not a bypass.

        case .lambingOffspring(let id, let parentID, let sheepID, let sex, let stillborn, let autoSheep, let weightID):
            guard let child = cache.offspring[id], child.farmID == farmID, child.deletedAt == nil,
                  child.lambingRecordID == parentID, child.sheepID == sheepID,
                  let parent = try index.reproduction(id: parentID, context: context),
                  parent.farmID == farmID, parent.deletedAt == nil, parent.kind == .lambing else { throw invalid() }
            if let sheepID { guard try validSheep(sheepID) else { throw invalid() } }
            if let weightID {
                guard let weight = cache.weights[weightID], weight.farmID == farmID,
                      weight.deletedAt == nil, weight.sheepID == sheepID else { throw invalid() }
            }
            guard !autoSheep || sheepID != nil else { throw invalid() }
            child.sexRawValue = sex
            child.isStillborn = stillborn
            child.autoCreatedSheep = autoSheep
            child.autoBirthWeightRecordID = weightID
            child.updatedAt = event.receivedAt

        case .reproduction(let id, let eweID, let kind, let occurredAt, let batchID, let source, let duplicateID):
            guard let record = try index.reproduction(id: id, context: context), record.farmID == farmID,
                  record.deletedAt == nil, record.eweID == eweID, record.kind == kind,
                  record.occurredAt == occurredAt, try validSheep(eweID),
                  source == nil || PaternalIdentitySource(rawValue: source!) != nil else { throw invalid() }
            if let batchID {
                guard let batch = cache.careBatches[batchID], batch.farmID == farmID,
                      batch.deletedAt == nil else { throw invalid() }
            }
            if let duplicateID {
                guard duplicateID != id, kind == .abortion,
                      let duplicate = try index.reproduction(id: duplicateID, context: context),
                      duplicate.farmID == farmID, duplicate.deletedAt == nil,
                      duplicate.eweID == eweID, duplicate.kind == kind,
                      duplicate.occurredAt == occurredAt, duplicate.batchID == batchID,
                      duplicate.result == record.result, duplicate.note == record.note else { throw invalid() }
                // Keep both the source event and the rejected projection as
                // evidence; never delete the genuine historical abortion.
                duplicate.deletedAt = event.receivedAt
                let tombstone = TombstoneRecord(id: event.commandID, farmID: farmID,
                    entityType: CloudEntityType.reproduction.rawValue, entityID: duplicateID,
                    deletedByAccountID: event.actorAccountID,
                    reason: "所有者授权历史投影修复：同一来源流产事实的重复派生投影", operationID: event.commandID)
                tombstone.deletedAt = event.receivedAt
                context.insert(tombstone)
            }
            record.batchID = batchID
            record.paternalSourceRawValue = source
            record.updatedAt = event.receivedAt

        case .transfer(let id, let sheepID, let occurredAt, let fromPenID, let recordedAt):
            guard let transfer = cache.transfers[id], transfer.farmID == farmID, transfer.deletedAt == nil,
                  transfer.sheepID == sheepID, transfer.occurredAt == occurredAt,
                  try validSheep(sheepID) else { throw invalid() }
            if let fromPenID {
                guard let pen = try index.pen(id: fromPenID, context: context),
                      pen.farmID == farmID, pen.deletedAt == nil else { throw invalid() }
            }
            transfer.fromPenID = fromPenID
            transfer.recordedAt = recordedAt
        }
        return .applied(rebuildHistoryFrom: .distantPast)
    }
}
