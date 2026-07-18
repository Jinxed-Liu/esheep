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
    case developmentTestFarmRequired
    case formalFarmRequired
}

struct CloudAdmissionRequest: Equatable, Sendable {
    let environment: AppEnvironment
    let role: FarmRole
    let membershipIsActive: Bool
    let isDeleted: Bool
    let isDevelopmentTestFarm: Bool
    let developmentSeed: String?
    let isLocalOnlyMigration: Bool
}

enum CloudAdmissionPolicy {
    static func validate(_ request: CloudAdmissionRequest) throws {
        guard !request.isDeleted else { throw CloudAdmissionDenial.deletedFarm }
        guard request.membershipIsActive else { throw CloudAdmissionDenial.inactiveMembership }
        guard request.role == .owner else { throw CloudAdmissionDenial.ownerRequired }
        guard !request.isLocalOnlyMigration else { throw CloudAdmissionDenial.localOnlyMigration }

        switch request.environment {
        case .development:
            guard request.isDevelopmentTestFarm,
                  request.developmentSeed == TestFarmGeneratorActor.seed else {
                throw CloudAdmissionDenial.developmentTestFarmRequired
            }
        case .staging, .production:
            guard !request.isDevelopmentTestFarm else {
                throw CloudAdmissionDenial.formalFarmRequired
            }
        }
    }
}

