import Foundation
import Supabase

/// Provider SDK types terminate here; collaboration UI and domain code see
/// only eSheep+ Cloud membership contracts.
actor ESheepCloudMembershipInfrastructureGateway: ESheepCloudMembershipGateway {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func accessibleFarms() async throws -> [ESheepCloudFarmAccessV2] {
        let wire: FarmAccessListWire = try await client.rpc(
            "esheep_cloud_list_my_farms_v2"
        ).execute().value
        return try wire.farms.map { try $0.domainValue() }
    }

    func members(farmID: UUID) async throws -> [ESheepCloudMemberV2] {
        let wire: MemberListWire = try await client.rpc(
            "esheep_cloud_list_members_v2",
            params: FarmParameters(p_farm_id: farmID)
        ).execute().value
        return try wire.members.map { try $0.domainValue() }
    }

    func createInvitation(
        farmID: UUID,
        role: FarmRole
    ) async throws -> ESheepCloudInvitationV2 {
        guard role == .administrator || role == .worker else {
            throw ESheepCloudMembershipError.invalidRole
        }
        let wire: InvitationWire = try await client.rpc(
            "esheep_cloud_create_invite_v2",
            params: CreateInvitationParameters(
                p_farm_id: farmID,
                p_role: role.rawValue
            )
        ).execute().value
        guard wire.code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw ESheepCloudMembershipError.malformedResponse
        }
        return .init(code: wire.code, expiresAt: wire.expiresAt)
    }

    func redeemInvitation(code: String) async throws -> ESheepCloudInvitationRedemptionV2 {
        let wire: RedemptionWire = try await client.rpc(
            "esheep_cloud_redeem_invite_v2",
            params: RedeemParameters(
                p_code: code.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        ).execute().value
        guard wire.farmGeneration >= 0,
              let role = FarmRole(rawValue: wire.role) else {
            throw ESheepCloudMembershipError.malformedResponse
        }
        return .init(
            farmID: wire.farmID,
            farmGeneration: wire.farmGeneration,
            role: role
        )
    }

    func revokeMember(farmID: UUID, memberID: UUID) async throws {
        let wire: RevocationWire = try await client.rpc(
            "esheep_cloud_revoke_member_v2",
            params: RevokeParameters(
                p_farm_id: farmID,
                p_member_id: memberID
            )
        ).execute().value
        guard wire.memberID == memberID, wire.status == "revoked" else {
            throw ESheepCloudMembershipError.malformedResponse
        }
    }
}

private struct FarmParameters: Encodable, Sendable {
    let p_farm_id: UUID
}

private struct FarmAccessListWire: Decodable, Sendable {
    let farms: [FarmAccessWire]
}

private struct FarmAccessWire: Decodable, Sendable {
    let farmID: UUID
    let farmGeneration: Int
    let memberAccountID: UUID
    let role: String
    let initialSyncReady: Bool

    enum CodingKeys: String, CodingKey {
        case farmID = "farm_id"
        case farmGeneration = "farm_generation"
        case memberAccountID = "member_account_id"
        case role
        case initialSyncReady = "initial_sync_ready"
    }

    func domainValue() throws -> ESheepCloudFarmAccessV2 {
        guard farmGeneration >= 0,
              let role = FarmRole(rawValue: role) else {
            throw ESheepCloudMembershipError.malformedResponse
        }
        return .init(
            farmID: farmID,
            farmGeneration: farmGeneration,
            memberAccountID: memberAccountID,
            role: role,
            initialSyncReady: initialSyncReady
        )
    }
}

private struct CreateInvitationParameters: Encodable, Sendable {
    let p_farm_id: UUID
    let p_role: String
}

private struct RedeemParameters: Encodable, Sendable {
    let p_code: String
}

private struct RevokeParameters: Encodable, Sendable {
    let p_farm_id: UUID
    let p_member_id: UUID
}

private struct MemberListWire: Decodable, Sendable {
    let members: [MemberWire]
}

private struct MemberWire: Decodable, Sendable {
    let memberID: UUID
    let accountID: UUID
    let displayName: String?
    let role: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case accountID = "account_id"
        case displayName = "display_name"
        case role, status
    }

    func domainValue() throws -> ESheepCloudMemberV2 {
        guard let role = FarmRole(rawValue: role) else {
            throw ESheepCloudMembershipError.malformedResponse
        }
        let membershipStatus: FarmMembershipStatus
        switch status {
        case "active": membershipStatus = .active
        case "revoked": membershipStatus = .revoked
        default: throw ESheepCloudMembershipError.malformedResponse
        }
        return .init(
            id: memberID,
            accountID: accountID,
            displayName: displayName,
            role: role,
            status: membershipStatus
        )
    }
}

private struct InvitationWire: Decodable, Sendable {
    let code: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
    }
}

private struct RedemptionWire: Decodable, Sendable {
    let farmID: UUID
    let farmGeneration: Int
    let role: String

    enum CodingKeys: String, CodingKey {
        case farmID = "farm_id"
        case farmGeneration = "farm_generation"
        case role
    }
}

private struct RevocationWire: Decodable, Sendable {
    let memberID: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case status
    }
}
