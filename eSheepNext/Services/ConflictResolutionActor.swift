import Foundation
import SwiftData

actor ConflictResolutionActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func resolve(
        conflictID: UUID,
        decision: ConflictResolutionDecision,
        note: String,
        farm: FarmContext
    ) async throws -> UUID {
        try await MainActor.run {
            let context = ModelContext(container)
            return try FarmCommandService().resolveConflict(
                conflictID: conflictID,
                decision: decision,
                note: note,
                in: farm,
                context: context
            )
        }
    }
}
