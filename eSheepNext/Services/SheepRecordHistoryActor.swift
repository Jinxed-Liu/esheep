import Foundation
import SwiftData

struct SheepHistoryWeight: Identifiable, Sendable, Hashable {
    let id: UUID
    let kilogramsText: String
    let occurredAt: Date
    let note: String
}

struct SheepHistoryTransfer: Identifiable, Sendable, Hashable {
    let id: UUID
    let fromPenID: UUID?
    let toPenID: UUID?
    let occurredAt: Date
    let note: String
}

struct SheepHistoryRemoval: Identifiable, Sendable, Hashable {
    let id: UUID
    let kind: RemovalKind
    let reason: String
    let amountText: String?
    let removalBatchID: UUID?
    let batchTotalAmountText: String?
    let occurredAt: Date
    let note: String
}

struct SheepHistoryTombstone: Identifiable, Sendable, Hashable {
    let id: UUID
    let entityType: String
    let reason: String
}

struct SheepHistoryPen: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let isActive: Bool
}

struct SheepRecordHistorySnapshot: Sendable {
    let weights: [SheepHistoryWeight]
    let transfers: [SheepHistoryTransfer]
    let removals: [SheepHistoryRemoval]
    let tombstones: [SheepHistoryTombstone]
    let pens: [SheepHistoryPen]

    func penName(_ id: UUID?) -> String {
        id.flatMap { id in pens.first { $0.id == id }?.name } ?? "未分圈"
    }
}

actor SheepRecordHistoryActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID, sheepID: UUID) throws -> SheepRecordHistorySnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let weights = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.restoredAt == nil
        }))
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))

        var relatedIDs = Set(weights.map(\.id))
        relatedIDs.formUnion(transfers.map(\.id))
        relatedIDs.formUnion(removals.map(\.id))
        relatedIDs.formUnion(photos.map(\.id))
        try Task.checkCancellation()

        return SheepRecordHistorySnapshot(
            weights: weights.compactMap { record in
                guard record.deletedAt == nil else { return nil }
                return SheepHistoryWeight(id: record.id, kilogramsText: record.kilogramsText, occurredAt: record.occurredAt, note: record.note)
            }.sorted { $0.occurredAt > $1.occurredAt },
            transfers: transfers.compactMap { record in
                guard record.deletedAt == nil else { return nil }
                return SheepHistoryTransfer(id: record.id, fromPenID: record.fromPenID, toPenID: record.toPenID, occurredAt: record.occurredAt, note: record.note)
            }.sorted { $0.occurredAt > $1.occurredAt },
            removals: removals.compactMap { record in
                guard record.deletedAt == nil else { return nil }
                return SheepHistoryRemoval(
                    id: record.id,
                    kind: record.kind,
                    reason: record.reason,
                    amountText: record.amountText,
                    removalBatchID: record.removalBatchID,
                    batchTotalAmountText: record.batchTotalAmountText,
                    occurredAt: record.occurredAt,
                    note: record.note
                )
            }.sorted { $0.occurredAt > $1.occurredAt },
            tombstones: tombstones.compactMap { record in
                guard relatedIDs.contains(record.entityID), !record.reason.hasPrefix("修正：") else { return nil }
                return SheepHistoryTombstone(id: record.id, entityType: record.entityType, reason: record.reason)
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            pens: pens.map { SheepHistoryPen(id: $0.id, name: $0.name, isActive: $0.isActive) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }
}
