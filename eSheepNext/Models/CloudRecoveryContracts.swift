import Foundation

enum ConflictResolutionDecision: Codable, Sendable, Equatable {
    case acceptLocal
    case acceptRemote
    case mergeText(String)
}

struct FarmRecoveryPackage: Codable, Sendable, Equatable {
    let version: Int
    let farmID: UUID
    let salt: Data
    let sealedRecoveryKey: Data
    let createdAt: Date
    let checksum: String
}
