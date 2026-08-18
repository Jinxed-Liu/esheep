import Foundation
import SwiftData

struct WeaningPenOption: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
}

struct WeaningEntryReferenceSnapshot: Sendable {
    let pens: [WeaningPenOption]
    let gainSamples: [WeaningGainSample]
}

/// Loads the potentially large weight history away from the SwiftUI main
/// actor. The entry form only needs immutable gain samples and active pens.
actor WeaningEntryReferenceSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID) throws -> WeaningEntryReferenceSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let pens = try context.fetch(FetchDescriptor<PenRecord>(
            predicate: #Predicate {
                $0.farmID == farmID &&
                    $0.deletedAt == nil &&
                    $0.isActive
            },
            sortBy: [SortDescriptor(\.name)]
        ))
        let weights = try context.fetch(FetchDescriptor<WeightRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.occurredAt)]
        ))
        try Task.checkCancellation()

        return WeaningEntryReferenceSnapshot(
            pens: pens.map { WeaningPenOption(id: $0.id, name: $0.name) },
            gainSamples: weights.map {
                WeaningGainSample(
                    id: $0.id,
                    sheepID: $0.sheepID,
                    kilograms: NSDecimalNumber(decimal: $0.kilograms).doubleValue,
                    occurredAt: $0.occurredAt
                )
            }
        )
    }
}
