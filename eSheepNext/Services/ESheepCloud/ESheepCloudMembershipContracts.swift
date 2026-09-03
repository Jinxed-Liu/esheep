import Foundation

struct ESheepCloudMemberV2: Identifiable, Sendable, Equatable {
    let id: UUID
    let accountID: UUID
    let displayName: String?
    let role: FarmRole
    let status: FarmMembershipStatus
}

struct ESheepCloudInvitationV2: Sendable, Equatable {
    let code: String
    let expiresAt: Date
}

struct ESheepCloudInvitationRedemptionV2: Sendable, Equatable {
    let farmID: UUID
    let farmGeneration: Int
    let role: FarmRole
}

/// An authenticated, account-bound farm admission. This is intentionally a
/// small discovery record: the immutable farm profile still comes only from
/// `openInitialSync`, so a list response can never seed business data.
struct ESheepCloudFarmAccessV2: Sendable, Equatable {
    let farmID: UUID
    let farmGeneration: Int
    let memberAccountID: UUID
    let role: FarmRole
    let initialSyncReady: Bool
}

protocol ESheepCloudMembershipGateway: Sendable {
    func accessibleFarms() async throws -> [ESheepCloudFarmAccessV2]
    func members(farmID: UUID) async throws -> [ESheepCloudMemberV2]
    func createInvitation(
        farmID: UUID,
        role: FarmRole
    ) async throws -> ESheepCloudInvitationV2
    func redeemInvitation(code: String) async throws -> ESheepCloudInvitationRedemptionV2
    func revokeMember(farmID: UUID, memberID: UUID) async throws
}

enum ESheepCloudMembershipError: LocalizedError {
    case malformedResponse
    case invalidRole
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "eSheep+ 云返回的成员资料不完整，请稍后再试。"
        case .invalidRole:
            "只能邀请管理员或员工。"
        case .accountMismatch:
            "当前登录账号与 eSheep+ 云返回的牧场权限不一致，请重新登录。"
        }
    }
}
