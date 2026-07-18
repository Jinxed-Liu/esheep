import Foundation

enum FarmRole: String, CaseIterable, Codable, Sendable {
    case owner
    case administrator
    case worker

    var displayName: String {
        switch self {
        case .owner: "牧场主"
        case .administrator: "管理员"
        case .worker: "员工"
        }
    }
}

enum FarmCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case readFarm
    case recordProduction
    case editHistoricalFacts
    case manageCatalogs
    case viewAnalytics
    case deleteProtectedFacts
    case manageMembers
    case manageFarm
    case editFarmLocation
    case exportFarm
    case resolveConflicts
    case recoverFarm
}

struct CapabilitySet: Sendable, Equatable {
    let role: FarmRole
    let grantedWorkerCapabilities: Set<FarmCapability>

    init(role: FarmRole, grantedWorkerCapabilities: Set<FarmCapability> = []) {
        self.role = role
        self.grantedWorkerCapabilities = grantedWorkerCapabilities
    }

    func allows(_ capability: FarmCapability) -> Bool {
        switch role {
        case .owner:
            true
        case .administrator:
            switch capability {
            case .readFarm, .recordProduction, .editHistoricalFacts, .manageCatalogs, .viewAnalytics, .editFarmLocation:
                true
            case .deleteProtectedFacts, .manageMembers, .manageFarm, .exportFarm, .resolveConflicts, .recoverFarm:
                false
            }
        case .worker:
            switch capability {
            case .readFarm, .recordProduction:
                true
            default:
                grantedWorkerCapabilities.contains(capability)
            }
        }
    }
}

struct FarmContext: Sendable, Equatable {
    let accountID: UUID
    let farmID: UUID
    let role: FarmRole
    let capabilities: CapabilitySet

    init(accountID: UUID, farmID: UUID, role: FarmRole, grantedWorkerCapabilities: Set<FarmCapability> = []) {
        self.accountID = accountID
        self.farmID = farmID
        self.role = role
        self.capabilities = CapabilitySet(role: role, grantedWorkerCapabilities: grantedWorkerCapabilities)
    }
}

enum FarmPermissionError: LocalizedError {
    case denied(FarmCapability)

    var errorDescription: String? {
        switch self {
        case .denied:
            "当前牧场角色没有执行此操作的权限。"
        }
    }
}
