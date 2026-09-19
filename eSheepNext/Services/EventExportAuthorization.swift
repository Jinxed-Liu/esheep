import SwiftData
import SwiftUI

struct EventExportIdentity: Equatable, Sendable {
    let accountProfileID: UUID
    let farmID: UUID
}

extension EnvironmentValues {
    @Entry var eventExportIdentity: EventExportIdentity? = nil
}

enum EventExportAuthorization {
    @MainActor
    static func require(_ identity: EventExportIdentity?, session: AppSession, context: ModelContext) throws {
        guard let identity,
              session.activeAccountProfileID == identity.accountProfileID,
              session.selectedFarmID == identity.farmID else {
            throw FarmPermissionError.denied(.exportEvents)
        }
        let farmID = identity.farmID
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate {
            $0.id == farmID && $0.deletedAt == nil
        })).first, farm.membershipStatusRawValue == "active",
              CapabilitySet(role: farm.role).allows(.exportEvents) else {
            throw FarmPermissionError.denied(.exportEvents)
        }
    }
}
