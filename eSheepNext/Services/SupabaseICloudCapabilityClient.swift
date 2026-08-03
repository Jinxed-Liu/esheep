import Foundation
import Supabase

struct SupabaseICloudCapabilityResponse: Decodable, Sendable {
    let certificateID: String
    let certificate: String
    let role: FarmRole
    let capabilities: [FarmCapability]
    let issuedAt: Int
    let expiresAt: Int
    let securitySnapshot: WorkerFarmSecuritySnapshot

    var capability: WorkerCapabilityResponse {
        WorkerCapabilityResponse(
            certificateID: certificateID,
            certificate: certificate,
            role: role,
            capabilities: capabilities,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }
}

actor SupabaseICloudCapabilityClient {
    private struct Request: Encodable, Sendable {
        let farmID: UUID
        let ownerAppAccountID: UUID
        let deviceID: UUID
        let zoneName: String
        let zoneOwnerName: String
        let observedSecurityGeneration: Int
    }

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func issueOwnerCapability(
        farmID: UUID,
        ownerAppAccountID: UUID,
        deviceID: UUID,
        zoneName: String,
        zoneOwnerName: String,
        observedSecurityGeneration: Int
    ) async throws -> SupabaseICloudCapabilityResponse {
        try await client.functions.invoke(
            "issue-icloud-capability",
            options: .init(
                body: Request(
                    farmID: farmID,
                    ownerAppAccountID: ownerAppAccountID,
                    deviceID: deviceID,
                    zoneName: zoneName,
                    zoneOwnerName: zoneOwnerName,
                    observedSecurityGeneration: observedSecurityGeneration
                )
            )
        )
    }
}
