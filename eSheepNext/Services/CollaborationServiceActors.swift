import CryptoKit
import Foundation
import SwiftData

actor MembershipActor {
    private let client: IdentityWorkerClient
    private let persistence: FarmPersistenceActor

    init(client: IdentityWorkerClient = .shared, persistence: FarmPersistenceActor) {
        self.client = client
        self.persistence = persistence
    }

    func changeRole(memberID: String, farmID: UUID, role: FarmRole) async throws {
        guard role != .owner else { throw FarmPermissionError.denied(.manageMembers) }
        try await client.changeMemberRole(memberID: memberID, farmID: farmID, role: role)
    }

    func remove(memberID: String, farmID: UUID) async throws {
        try await client.removeMember(memberID: memberID, farmID: farmID)
    }

    func refresh(farmID: UUID) async throws -> WorkerFarmSecuritySnapshot {
        let snapshot = try await client.farmSecuritySnapshot(farmID: farmID)
        try await persistence.saveSecuritySnapshot(snapshot)
        return snapshot
    }
}

actor InviteServiceActor {
    private let client: IdentityWorkerClient
    private let device: DeviceIdentityActor
    private let persistence: FarmPersistenceActor

    init(client: IdentityWorkerClient = .shared, device: DeviceIdentityActor = .shared, persistence: FarmPersistenceActor) {
        self.client = client
        self.device = device
        self.persistence = persistence
    }

    func create(
        farmID: UUID,
        role: FarmRole,
        shareParticipantID: String? = nil,
        shareURL: URL? = nil
    ) async throws -> WorkerInviteResponse {
        guard role == .administrator || role == .worker else { throw FarmPermissionError.denied(.manageMembers) }
        return try await client.createInvite(
            farmID: farmID,
            role: role,
            shareParticipantID: shareParticipantID,
            shareURL: shareURL
        )
    }

    func redeem(
        code: String,
        cloudKitUserRecordName: String
    ) async throws -> WorkerRedeemResponse {
        _ = try await device.register(using: client)
        return try await client.redeemInvite(
            code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            cloudKitUserRecordName: cloudKitUserRecordName
        )
    }

    func redeem(shareParticipantID: String) async throws -> WorkerRedeemResponse {
        _ = try await device.register(using: client)
        return try await client.redeemInvite(
            shareParticipantID: shareParticipantID
        )
    }

    func pending(farmID: UUID) async throws -> [WorkerPendingInviteResponse] {
        try await client.pendingInvites(farmID: farmID)
    }

    func confirm(inviteID: String, participantRecordName: String) async throws {
        try await client.confirmInvite(inviteID: inviteID, participantRecordName: participantRecordName)
    }

    func refreshCapability(accountID: UUID, farmID: UUID) async throws -> WorkerCapabilityResponse {
        let identity = try await device.register(using: client)
        let response = try await client.issueCapability(farmID: farmID, deviceID: identity.deviceID)
        try await persistence.saveCapability(response, accountID: accountID, farmID: farmID, deviceID: identity.deviceID)
        return response
    }
}

actor PhotoDigestActor {
    func digest(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func validate(fileURL: URL, expectedDigest: String) throws -> Bool {
        try digest(fileURL: fileURL) == expectedDigest
    }
}

actor ConflictResolutionActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func resolve(conflictID: UUID, decision: ConflictResolutionDecision, note: String, farm: FarmContext) async throws -> UUID {
        try await MainActor.run {
            let context = ModelContext(container)
            return try FarmCommandService().resolveConflict(conflictID: conflictID, decision: decision, note: note, in: farm, context: context)
        }
    }
}

enum CapabilityCertificateVerifier {
    static func verify(_ jws: String, publicKeyPEM: String) throws -> CapabilityCertificateClaims {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Data(base64URL: String(parts[0])),
              let payloadData = Data(base64URL: String(parts[1])),
              let signatureData = Data(base64URL: String(parts[2])) else {
            throw CloudContractError.invalidCertificate
        }
        let header = try JSONDecoder().decode(JWSHeader.self, from: headerData)
        guard header.alg == "ES256", header.typ == "esheep-capability+jwt" else {
            throw CloudContractError.invalidCertificate
        }
        let key = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM.replacingOccurrences(of: "\\n", with: "\n"))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let signedData = Data("\(parts[0]).\(parts[1])".utf8)
        guard key.isValidSignature(signature, for: signedData) else { throw CloudContractError.invalidCertificate }
        return try JSONDecoder().decode(CapabilityCertificateClaims.self, from: payloadData)
    }

    private struct JWSHeader: Codable {
        let alg: String
        let kid: String
        let typ: String
    }
}

private extension Data {
    init?(base64URL value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        self.init(base64Encoded: normalized)
    }
}
