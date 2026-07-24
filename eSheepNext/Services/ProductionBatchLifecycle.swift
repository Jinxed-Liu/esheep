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
