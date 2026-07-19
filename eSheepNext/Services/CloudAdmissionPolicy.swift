import Foundation

enum AppEnvironment: String, Codable, Sendable {
    case development
    case staging
    case production

    static var current: AppEnvironment {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "APP_ENVIRONMENT") as? String else {
            #if DEBUG
            return .development
            #else
            return .production
            #endif
        }
        return AppEnvironment(rawValue: value.lowercased()) ?? .production
    }
}

enum CloudAdmissionDenial: Error, Equatable, Sendable {
    case deletedFarm
    case inactiveMembership
    case ownerRequired
    case localOnlyMigration
    case verifiedMigrationRequired
}

struct CloudAdmissionRequest: Equatable, Sendable {
    let environment: AppEnvironment
    let role: FarmRole
    let membershipIsActive: Bool
    let isDeleted: Bool
    let isLocalOnlyMigration: Bool
    let hasVerifiedMigrationCommit: Bool
    let hasCompleteMigrationBaseline: Bool

    init(
        environment: AppEnvironment,
        role: FarmRole,
        membershipIsActive: Bool,
        isDeleted: Bool,
        isLocalOnlyMigration: Bool,
        hasVerifiedMigrationCommit: Bool = false,
        hasCompleteMigrationBaseline: Bool = false
    ) {
        self.environment = environment
        self.role = role
        self.membershipIsActive = membershipIsActive
        self.isDeleted = isDeleted
        self.isLocalOnlyMigration = isLocalOnlyMigration
        self.hasVerifiedMigrationCommit = hasVerifiedMigrationCommit
        self.hasCompleteMigrationBaseline = hasCompleteMigrationBaseline
    }
}

enum CloudAdmissionPolicy {
    static func validate(_ request: CloudAdmissionRequest) throws {
        guard !request.isDeleted else { throw CloudAdmissionDenial.deletedFarm }
        guard request.membershipIsActive else { throw CloudAdmissionDenial.inactiveMembership }
        guard request.role == .owner else { throw CloudAdmissionDenial.ownerRequired }
        guard !request.isLocalOnlyMigration else { throw CloudAdmissionDenial.localOnlyMigration }

        switch request.environment {
        case .development:
            let isVerifiedMigrationFarm = request.hasVerifiedMigrationCommit && request.hasCompleteMigrationBaseline
            guard isVerifiedMigrationFarm else {
                throw CloudAdmissionDenial.verifiedMigrationRequired
            }
        case .staging, .production:
            break
        }
    }
}
