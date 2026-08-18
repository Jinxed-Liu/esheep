import Foundation
import SwiftData

struct CareManagementSummarySnapshot: Sendable, Equatable {
    let healthRecordCount: Int
    let reproductionRecordCount: Int

    static let empty = CareManagementSummarySnapshot(
        healthRecordCount: 0,
        reproductionRecordCount: 0
    )
}

/// The care landing page displays counts, not record bodies. Keep historical
/// health and reproduction rows out of its live SwiftUI query graph.
actor CareManagementSummarySnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID) throws -> CareManagementSummarySnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let healthCount = try context.fetchCount(FetchDescriptor<HealthRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        return CareManagementSummarySnapshot(
            healthRecordCount: healthCount,
            reproductionRecordCount: reproduction.count { $0.kind != .parityBaseline }
        )
    }
}
