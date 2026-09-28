import Foundation
import SwiftData

enum ProductionBatchVisibility {
    /// 当前生产流程只承认用户人工建立的批次。迁移和旧推断批次继续留在 Store
    /// 以保证迁移可追溯，但不能进入生产批次页面或任何批次分析筛选。
    static func userManaged(farmID: UUID, batches: [ProductionBatchRecord]) -> [ProductionBatchRecord] {
        batches.filter {
            $0.farmID == farmID &&
                $0.deletedAt == nil &&
                $0.sourceRawValue == ProductionBatchSource.manual.rawValue
        }
    }

    static func validatedSelection(_ selectedID: UUID?, farmID: UUID, batches: [ProductionBatchRecord]) -> UUID? {
        guard let selectedID else { return nil }
        return userManaged(farmID: farmID, batches: batches).contains(where: { $0.id == selectedID }) ? selectedID : nil
    }
}

enum ProductionBatchLifecycle {
    static func reconcile(
        batch: ProductionBatchRecord,
        members: [BatchMembershipRecord],
        changedAt: Date = .now
    ) {
        guard !members.isEmpty else { return }

        let activeMemberExists = members.contains { $0.leftAt == nil }
        let projectedStatus: ProductionBatchStatus = activeMemberExists ? .active : .completed
        let projectedEnd: Date? = activeMemberExists ? nil : members.compactMap(\.leftAt).max()
        if batch.status != projectedStatus || batch.endedAt != projectedEnd {
            batch.statusRawValue = projectedStatus.rawValue
            batch.endedAt = projectedEnd
            batch.updatedAt = changedAt
        }
    }

    static func reconcile(batchID: UUID, farmID: UUID, context: ModelContext, changedAt: Date = .now) throws {
        let batchDescriptor = FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate {
            $0.id == batchID && $0.farmID == farmID && $0.deletedAt == nil
        })
        guard let batch = try context.fetch(batchDescriptor).first else { return }
        let members = try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.batchID == batchID && $0.deletedAt == nil
        }))
        reconcile(batch: batch, members: members, changedAt: changedAt)
    }
}

@MainActor
extension FarmCommandService {
    /// Delete the batch and its membership links through the audited command pipeline.
    /// Sheep and their production facts remain intact; any failure rolls back the local batch.
    func deleteProductionBatch(
        batchID: UUID,
        reason: String,
        in farm: FarmContext,
        context: ModelContext
    ) throws {
        let farmID = farm.farmID
        let batches = try context.fetch(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate {
            $0.id == batchID && $0.farmID == farmID && $0.deletedAt == nil
        }))
        guard let batch = batches.first,
              batch.sourceRawValue == ProductionBatchSource.manual.rawValue else {
            throw FarmCommandError.missingRequiredValue("可删除的生产批次")
        }
        let members = try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.batchID == batchID && $0.deletedAt == nil
        }))
        var commands: [FarmCommand] = members.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            .tombstoneEntity(entityType: .batchMembership, entityID: $0.id, reason: reason)
        }
        commands.append(.tombstoneEntity(entityType: .productionBatch, entityID: batchID, reason: reason))
        try executeBatch(commands, in: farm, context: context)
    }

    /// Restore the batch and every membership removed by the same deletion.
    /// Validation runs before staging any command so a later assignment cannot
    /// silently create two active batches for one sheep.
    func restoreDeletedProductionBatch(
        deletionID: UUID,
        in farm: FarmContext,
        context: ModelContext
    ) throws {
        guard farm.capabilities.allows(.manageCatalogs) else {
            throw FarmPermissionError.denied(.manageCatalogs)
        }
        let farmID = farm.farmID
        guard let deletion = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
            $0.id == deletionID && $0.farmID == farmID && $0.restoredAt == nil
        })).first,
            deletion.entityType == CloudEntityType.productionBatch.rawValue else {
            throw FarmCommandError.missingRequiredValue("可撤回的批次删除记录")
        }
        let batchID = deletion.entityID
        guard let batch = try context.fetch(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate {
            $0.id == batchID && $0.farmID == farmID && $0.deletedAt != nil
        })).first,
            batch.sourceRawValue == ProductionBatchSource.manual.rawValue else {
            throw FarmCommandError.missingRequiredValue("可撤回的批次删除记录")
        }

        let allMembers = try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.restoredAt == nil
        }))
        // Match each still-deleted membership to its own active tombstone.
        // Server replay can assign different timestamps to the batch commands,
        // so a wall-clock deletion window would break undo after a fresh sync.
        let deletedMembers = allMembers.filter {
            $0.batchID == batch.id && $0.deletedAt != nil
        }
        var memberDeletions: [TombstoneRecord] = []
        for member in deletedMembers {
            guard let memberDeletion = tombstones.first(where: {
                    $0.entityType == CloudEntityType.batchMembership.rawValue &&
                    $0.entityID == member.id &&
                    $0.reason == deletion.reason
            }) else {
                throw FarmCommandError.missingRequiredValue("完整的批次成员删除记录")
            }
            memberDeletions.append(memberDeletion)
        }
        let restoredActiveIDs = Set(deletedMembers.filter { $0.leftAt == nil }.map(\.sheepID))
        guard !allMembers.contains(where: {
            $0.farmID == farmID && $0.deletedAt == nil && $0.leftAt == nil &&
                restoredActiveIDs.contains($0.sheepID)
        }) else {
            throw FarmCommandError.duplicateBatchMembership
        }

        let commands: [FarmCommand] = [.restoreTombstonedEntity(tombstoneID: deletion.id)] +
            memberDeletions.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                .restoreTombstonedEntity(tombstoneID: $0.id)
            }
        try executeBatch(commands, in: farm, context: context)
    }
}
