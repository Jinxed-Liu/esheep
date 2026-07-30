import CryptoKit
import Foundation

enum IdentityWorkerConfiguration {
    static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "IDENTITY_WORKER_URL") as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    static func endpointURL(baseURL: URL, path: String) -> URL {
        let relativePath = path.drop(while: { $0 == "/" })
        return baseURL.appending(path: String(relativePath))
    }
}

enum CloudFeatureConfiguration {
    static var isEnabled: Bool {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CLOUD_COLLABORATION_ENABLED") as? Bool { return value }
        if let value = Bundle.main.object(forInfoDictionaryKey: "CLOUD_COLLABORATION_ENABLED") as? String {
            return ["yes", "true", "1"].contains(value.lowercased())
        }
        return false
    }
}

enum MemberSharingConfiguration {
    /// 正式迁移牧场完成云端基线并激活后开放成员共享。
    static let isEnabled = true
}

enum IdentityWorkerError: LocalizedError, Equatable {
    case notConfigured
    case missingSession
    case invalidResponse
    case networkUnavailable(host: String, code: URLError.Code)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "身份服务尚未配置。请先部署大陆身份网关并填写 IDENTITY_WORKER_URL。"
        case .missingSession: "身份服务会话不存在，请重新使用 Apple 登录。"
        case .invalidResponse: "身份服务返回了无法解析的响应。"
        case .networkUnavailable(let host, .timedOut): "连接身份服务超时（\(host)）。请检查网络后重试。"
        case .networkUnavailable(let host, _): "无法连接身份服务（\(host)）。密码注册和登录需要账号服务器可用，请检查网络后重试。"
        case .server(_, let message): message
        }
    }

}

struct WorkerSessionResponse: Codable, Sendable {
    let accessToken: String
    let accessExpiresAt: Int
    let refreshToken: String
    let refreshExpiresAt: Int
    let accountID: UUID
    let displayName: String?
}

struct WorkerEmailVerificationResponse: Codable, Sendable {
    let verificationID: String
    let expiresIn: Int
}

struct WorkerHealthResponse: Codable, Sendable {
    let status: String
    let environment: String
    let version: String
    let database: String
}

struct WorkerDeviceResponse: Codable, Sendable {
    let deviceID: UUID
    let registeredAt: Int
}

struct WorkerSignOutResult: Sendable {
    let serverSessionRevoked: Bool
    let warningMessage: String?
}

struct WorkerAccountDeletionResponse: Codable, Sendable, Equatable {
    let deletionJobID: String
    let status: String
}

struct WorkerInviteResponse: Codable, Sendable {
    let inviteID: String
    let code: String
    let role: FarmRole
    let expiresAt: Int
    let shareParticipantID: String?
}

struct WorkerRedeemResponse: Codable, Sendable {
    let inviteID: String
    let farmID: UUID
    let role: FarmRole
    let membershipStatus: String
    let shareURL: URL?
}

struct WorkerPendingInviteResponse: Codable, Sendable {
    let inviteID: String
    let farmID: UUID
    let role: FarmRole
    let shareParticipantID: String?
    let cloudKitUserRecordName: String?
    let expiresAt: Int
}

struct WorkerCapabilityResponse: Codable, Sendable {
    let certificateID: String
    let certificate: String
    let role: FarmRole
    let capabilities: [FarmCapability]
    let issuedAt: Int
    let expiresAt: Int
}

struct WorkerAccountStatus: Codable, Sendable {
    struct Features: Codable, Sendable {
        let mimoInsights: Bool?
    }

    struct Membership: Codable, Sendable {
        let farm_id: UUID
        let ownerAccountID: UUID?
        let role: FarmRole
        let status: String
        let cloudZoneName: String?
        let shareRecordName: String?
    }

    let accountID: UUID
    let displayName: String?
    let status: String
    let memberships: [Membership]
    let features: Features?

    init(
        accountID: UUID,
        displayName: String?,
        status: String,
        memberships: [Membership],
        features: Features? = nil
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.status = status
        self.memberships = memberships
        self.features = features
    }
}

struct WorkerAccountProfileResponse: Codable, Sendable, Equatable {
    let accountID: UUID
    let displayName: String
}

struct WorkerAccountAvatarResponse: Codable, Sendable, Equatable {
    let accountID: UUID
    let revision: Int64?
    let digest: String?
    let hasAvatar: Bool
    let dataBase64: String?
}

struct WorkerInsightDeviceResponse: Codable, Sendable, Equatable {
    let deviceID: UUID
    let status: String
    let requestedAt: Int?
    let approvedAt: Int?
    let keyVersion: Int?
}

struct WorkerInsightDeviceList: Codable, Sendable {
    struct Device: Codable, Sendable, Identifiable {
        let deviceID: UUID
        let displayName: String
        let publicKeyJWK: [String: String]
        let status: String
        let requestedAt: Int
        let approvedAt: Int?
        let revokedAt: Int?

        var id: UUID { deviceID }
    }

    let devices: [Device]
}

struct WorkerInsightEnvelopeList: Codable, Sendable {
    struct Envelope: Codable, Sendable {
        let targetDeviceID: UUID
        let keyVersion: Int
        let sealedEnvelopeBase64: String
        let createdAt: Int
    }

    let envelopes: [Envelope]
}

struct WorkerInsightSyncRecord: Codable, Sendable {
    let recordID: UUID
    let recordKind: String
    let conversationID: UUID?
    let revision: Int64
    let ciphertextBase64: String
    let deletedAt: Int64?
    let updatedAt: Int64?
}

struct WorkerInsightSyncResponse: Codable, Sendable {
    let cursor: Int64
    let keyVersion: Int
    let hasMore: Bool
    let records: [WorkerInsightSyncRecord]
}

struct WorkerInsightRotationEnvelope: Codable, Sendable, Equatable {
    let targetDeviceID: UUID
    let sealedEnvelopeBase64: String
}

struct WorkerInsightRecoveryResponse: Codable, Sendable {
    struct Recovery: Codable, Sendable {
        let keyVersion: Int
        let ciphertextBase64: String
        let updatedAt: Int
    }

    let recovery: Recovery?
}

struct WorkerFarmSecuritySnapshot: Codable, Sendable {
    struct Member: Codable, Sendable {
        let membershipID: String
        let accountID: UUID
        let displayName: String
        let role: FarmRole
        let status: String
        let shareParticipantRecordName: String?
    }

    struct Device: Codable, Sendable {
        let deviceID: UUID
        let accountID: UUID
        let publicKeyJWK: String
    }

    struct RevokedCertificate: Codable, Sendable {
        let certificateID: String
        let revokedAt: Int
    }

    let farmID: UUID
    let generation: Int
    let issuedAt: Int
    let members: [Member]
    let devices: [Device]
    let revokedCertificates: [RevokedCertificate]
}

private struct WorkerErrorEnvelope: Codable {
    struct Detail: Codable {
        let code: String
        let message: String
    }
    let error: Detail
}

private struct WorkerFlatErrorEnvelope: Codable {
    let code: String
    let message: String
}

actor IdentityWorkerClient {
    static let shared = IdentityWorkerClient()

    private let session: URLSession
    private let encoder = JSONEncoder.cloud
    private let decoder: JSONDecoder

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func authenticateWithApple(identityToken: String, authorizationCode: String, nonce: String, displayName: String?) async throws -> WorkerSessionResponse {
        let response: WorkerSessionResponse = try await request(
            path: "/v1/auth/apple",
            method: "POST",
            body: [
                "identityToken": identityToken,
                "authorizationCode": authorizationCode,
                "nonce": nonce,
                "displayName": displayName ?? "",
            ],
            authenticated: false
        )
        try persist(response)
        return response
    }

    func requestEmailVerification(email: String) async throws -> WorkerEmailVerificationResponse {
        try await request(
            path: "/v1/auth/verification",
            method: "POST",
            body: EmailVerificationBody(email: email),
            authenticated: false
        )
    }

    func register(email: String, verificationID: String, verificationCode: String, username: String, password: String, displayName: String) async throws -> WorkerSessionResponse {
        let response: WorkerSessionResponse = try await request(
            path: "/v1/auth/register",
            method: "POST",
            body: PasswordRegistrationBody(
                email: email,
                verificationID: verificationID,
                verificationCode: verificationCode,
                username: username,
                password: password,
                displayName: displayName
            ),
            authenticated: false
        )
        try persist(response)
        return response
    }

    func authenticate(username: String, password: String) async throws -> WorkerSessionResponse {
        let response: WorkerSessionResponse = try await request(
            path: "/v1/auth/password",
            method: "POST",
            body: PasswordLoginBody(username: username, password: password),
            authenticated: false
        )
        try persist(response)
        return response
    }

    func health() async throws -> WorkerHealthResponse {
        try await request(path: "/v1/health", method: "GET", body: Optional<String>.none, authenticated: false)
    }

    /// Verifies the persisted session and refreshes it once when required.
    /// A successful return proves that the local tokens still belong to a live
    /// CloudBase account; callers may continue to use local farm data offline
    /// after this initial authenticated session has been established.
    func restoreSession() async throws -> WorkerAccountStatus {
        try await accountStatus()
    }

    func signOut() async throws -> WorkerSignOutResult {
        let warningMessage: String?
        do {
            let _: EmptyWorkerResponse = try await request(
                path: "/v1/auth/logout",
                method: "POST",
                body: Optional<String>.none
            )
            warningMessage = nil
        } catch {
            warningMessage = "本机已经退出，但服务器会话未能即时撤销：\(error.localizedDescription)"
        }
        try SecureAccountStore.removeLoginSecrets()
        return WorkerSignOutResult(
            serverSessionRevoked: warningMessage == nil,
            warningMessage: warningMessage
        )
    }

    func registerDevice(deviceID: UUID, publicKeyJWK: [String: String], displayName: String) async throws -> WorkerDeviceResponse {
        try await request(path: "/v1/devices/register", method: "POST", body: DeviceRegistrationBody(deviceID: deviceID, publicKeyJWK: publicKeyJWK, displayName: displayName))
    }

    func revokeDevice(deviceID: UUID) async throws {
        let _: EmptyWorkerResponse = try await request(path: "/v1/devices/\(deviceID.uuidString.lowercased())", method: "DELETE", body: Optional<String>.none)
    }

    func requestInsightDevice(
        deviceID: UUID,
        publicKeyJWK: [String: String],
        displayName: String
    ) async throws -> WorkerInsightDeviceResponse {
        try await request(
            path: "/v1/insights/devices/request",
            method: "POST",
            body: DeviceRegistrationBody(
                deviceID: deviceID,
                publicKeyJWK: publicKeyJWK,
                displayName: displayName
            )
        )
    }

    func insightDevices() async throws -> WorkerInsightDeviceList {
        try await request(
            path: "/v1/insights/devices",
            method: "GET",
            body: Optional<String>.none
        )
    }

    func approveInsightDevice(
        deviceID: UUID,
        approverDeviceID: UUID,
        keyVersion: Int,
        sealedEnvelope: Data
    ) async throws -> WorkerInsightDeviceResponse {
        try await request(
            path: "/v1/insights/devices/\(deviceID.uuidString.lowercased())/approve",
            method: "POST",
            body: InsightDeviceApprovalBody(
                approverDeviceID: approverDeviceID,
                keyVersion: keyVersion,
                sealedEnvelopeBase64: sealedEnvelope.base64EncodedString()
            )
        )
    }

    func recoverInsightDevice(
        deviceID: UUID,
        keyVersion: Int,
        recoveryProof: Data,
        sealedEnvelope: Data
    ) async throws -> WorkerInsightDeviceResponse {
        try await request(
            path: "/v1/insights/devices/\(deviceID.uuidString.lowercased())/recover",
            method: "POST",
            body: InsightDeviceRecoveryBody(
                keyVersion: keyVersion,
                recoveryProofBase64: recoveryProof.base64EncodedString(),
                sealedEnvelopeBase64: sealedEnvelope.base64EncodedString()
            )
        )
    }

    func insightKeyEnvelopes(deviceID: UUID) async throws -> WorkerInsightEnvelopeList {
        try await request(
            path: "/v1/insights/key-envelopes/\(deviceID.uuidString.lowercased())",
            method: "GET",
            body: Optional<String>.none
        )
    }

    func revokeInsightDevice(
        deviceID: UUID,
        requesterDeviceID: UUID,
        keyVersion: Int,
        envelopes: [WorkerInsightRotationEnvelope]
    ) async throws -> WorkerInsightDeviceResponse {
        try await request(
            path: "/v1/insights/devices/\(deviceID.uuidString.lowercased())",
            method: "DELETE",
            body: InsightDeviceRevocationBody(
                requesterDeviceID: requesterDeviceID,
                keyVersion: keyVersion,
                envelopes: envelopes
            )
        )
    }

    func syncInsightRecords(
        deviceID: UUID,
        cursor: Int64,
        records: [WorkerInsightSyncRecord]
    ) async throws -> WorkerInsightSyncResponse {
        try await request(
            path: "/v1/insights/sync",
            method: "POST",
            body: InsightSyncBody(deviceID: deviceID, cursor: cursor, records: records),
            timeout: 60
        )
    }

    func insightRecovery() async throws -> WorkerInsightRecoveryResponse {
        try await request(
            path: "/v1/insights/recovery",
            method: "GET",
            body: Optional<String>.none
        )
    }

    func updateInsightRecovery(
        deviceID: UUID,
        keyVersion: Int,
        ciphertext: Data,
        proofDigest: String
    ) async throws {
        let _: InsightRecoveryUpdateResponse = try await request(
            path: "/v1/insights/recovery",
            method: "PUT",
            body: InsightRecoveryUpdateBody(
                deviceID: deviceID,
                keyVersion: keyVersion,
                ciphertextBase64: ciphertext.base64EncodedString(),
                proofDigest: proofDigest
            )
        )
    }

    func removeInsightRecovery() async throws {
        let _: EmptyWorkerResponse = try await request(
            path: "/v1/insights/recovery",
            method: "DELETE",
            body: Optional<String>.none
        )
    }

    func registerFarm(farmID: UUID, zoneName: String, shareRecordName: String?, status: String = "active") async throws {
        let _: WorkerFarmRegistrationResponse = try await request(path: "/v1/farms/register", method: "POST", body: FarmRegistrationBody(farmID: farmID, zoneName: zoneName, shareRecordName: shareRecordName, status: status))
    }

    func activateFarm(farmID: UUID) async throws {
        let _: WorkerFarmRegistrationResponse = try await request(path: "/v1/farms/\(farmID.uuidString.lowercased())/activate", method: "POST", body: Optional<String>.none)
    }

    func createInvite(
        farmID: UUID,
        role: FarmRole,
        shareParticipantID: String? = nil,
        shareURL: URL? = nil
    ) async throws -> WorkerInviteResponse {
        try await request(
            path: "/v1/invites",
            method: "POST",
            body: InviteBody(
                farmID: farmID,
                role: role,
                shareParticipantID: shareParticipantID,
                shareURL: shareURL
            )
        )
    }

    func redeemInvite(
        code: String,
        cloudKitUserRecordName: String
    ) async throws -> WorkerRedeemResponse {
        try await request(
            path: "/v1/invites/redeem",
            method: "POST",
            body: [
                "code": code,
                "cloudKitUserRecordName": cloudKitUserRecordName,
            ]
        )
    }

    func redeemInvite(shareParticipantID: String) async throws -> WorkerRedeemResponse {
        try await request(
            path: "/v1/invites/redeem",
            method: "POST",
            body: ["shareParticipantID": shareParticipantID]
        )
    }

    func pendingInvites(farmID: UUID) async throws -> [WorkerPendingInviteResponse] {
        try await request(
            path: "/v1/farms/\(farmID.uuidString.lowercased())/invites/pending",
            method: "GET",
            body: Optional<String>.none
        )
    }

    func confirmInvite(inviteID: String, participantRecordName: String) async throws {
        let _: EmptyWorkerResponse = try await request(path: "/v1/invites/\(inviteID)/confirm", method: "POST", body: ["shareParticipantRecordName": participantRecordName])
    }

    func changeMemberRole(memberID: String, farmID: UUID, role: FarmRole) async throws {
        let _: EmptyWorkerResponse = try await request(
            path: "/v1/members/\(memberID)",
            method: "PATCH",
            body: InviteBody(
                farmID: farmID,
                role: role,
                shareParticipantID: nil,
                shareURL: nil
            )
        )
    }

    func removeMember(memberID: String, farmID: UUID) async throws {
        let _: EmptyWorkerResponse = try await request(path: "/v1/members/\(memberID)", method: "DELETE", body: FarmOnlyBody(farmID: farmID))
    }

    func issueCapability(farmID: UUID, deviceID: UUID) async throws -> WorkerCapabilityResponse {
        try await request(path: "/v1/capabilities/issue", method: "POST", body: CapabilityBody(farmID: farmID, deviceID: deviceID))
    }

    func accountStatus() async throws -> WorkerAccountStatus {
        try await request(path: "/v1/account/status", method: "GET", body: Optional<String>.none)
    }

    func updateAccountDisplayName(_ displayName: String) async throws -> WorkerAccountProfileResponse {
        try await request(
            path: "/v1/account/profile",
            method: "PATCH",
            body: AccountProfileUpdateBody(displayName: displayName)
        )
    }

    func accountAvatarMetadata() async throws -> WorkerAccountAvatarResponse {
        try await request(
            path: "/v1/account/avatar",
            method: "GET",
            body: Optional<String>.none
        )
    }

    func accountAvatarContent() async throws -> WorkerAccountAvatarResponse {
        try await request(
            path: "/v1/account/avatar/content",
            method: "GET",
            body: Optional<String>.none,
            timeout: 30
        )
    }

    func updateAccountAvatar(_ data: Data) async throws -> WorkerAccountAvatarResponse {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try await request(
            path: "/v1/account/avatar",
            method: "PUT",
            body: AccountAvatarUpdateBody(dataBase64: data.base64EncodedString(), digest: digest),
            timeout: 30
        )
    }

    func removeAccountAvatar() async throws -> WorkerAccountAvatarResponse {
        try await request(
            path: "/v1/account/avatar",
            method: "DELETE",
            body: Optional<String>.none
        )
    }

    func farmSecuritySnapshot(farmID: UUID) async throws -> WorkerFarmSecuritySnapshot {
        try await request(path: "/v1/farms/\(farmID.uuidString.lowercased())/security-snapshot", method: "GET", body: Optional<String>.none)
    }

    func deleteAccount() async throws -> WorkerAccountDeletionResponse {
        let response: WorkerAccountDeletionResponse = try await request(
            path: "/v1/account/delete",
            method: "POST",
            body: Optional<String>.none
        )
        try SecureAccountStore.removeIdentitySecrets()
        return response
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        authenticated: Bool = true,
        allowRefresh: Bool = true,
        timeout: TimeInterval = 15
    ) async throws -> Response {
        guard let baseURL = IdentityWorkerConfiguration.baseURL else { throw IdentityWorkerError.notConfigured }
        let url = IdentityWorkerConfiguration.endpointURL(baseURL: baseURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if method != "GET", !(body is Optional<String>) {
            request.httpBody = try encoder.encode(body)
        }
        if authenticated {
            guard let tokenData = try SecureAccountStore.data(account: "worker-access-token"),
                  let token = String(data: tokenData, encoding: .utf8) else {
                throw IdentityWorkerError.missingSession
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw IdentityWorkerError.networkUnavailable(
                host: url.host(percentEncoded: false) ?? "身份服务",
                code: error.code
            )
        }
        guard let http = response as? HTTPURLResponse else { throw IdentityWorkerError.invalidResponse }
        if http.statusCode == 401, authenticated, allowRefresh {
            try await refresh()
            return try await self.request(
                path: path,
                method: method,
                body: body,
                authenticated: true,
                allowRefresh: false,
                timeout: timeout
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? decoder.decode(WorkerErrorEnvelope.self, from: data) {
                throw IdentityWorkerError.server(code: envelope.error.code, message: envelope.error.message)
            }
            if let envelope = try? decoder.decode(WorkerFlatErrorEnvelope.self, from: data) {
                throw IdentityWorkerError.server(code: envelope.code, message: envelope.message)
            }
            throw IdentityWorkerError.invalidResponse
        }
        if Response.self == EmptyWorkerResponse.self, data.isEmpty {
            return EmptyWorkerResponse() as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func refresh() async throws {
        guard let tokenData = try SecureAccountStore.data(account: "worker-refresh-token"),
              let refreshToken = String(data: tokenData, encoding: .utf8) else {
            throw IdentityWorkerError.missingSession
        }
        let response: WorkerSessionResponse = try await request(path: "/v1/auth/refresh", method: "POST", body: ["refreshToken": refreshToken], authenticated: false, allowRefresh: false)
        try persist(response)
    }

    private func persist(_ response: WorkerSessionResponse) throws {
        try SecureAccountStore.save(Data(response.accessToken.utf8), account: "worker-access-token")
        try SecureAccountStore.save(Data(response.refreshToken.utf8), account: "worker-refresh-token")
        try SecureAccountStore.saveWorkerSession(.init(
            accountID: response.accountID,
            accessExpiresAt: response.accessExpiresAt,
            refreshExpiresAt: response.refreshExpiresAt
        ))
    }
}

private struct DeviceRegistrationBody: Codable { let deviceID: UUID; let publicKeyJWK: [String: String]; let displayName: String }
private struct InsightDeviceApprovalBody: Codable {
    let approverDeviceID: UUID
    let keyVersion: Int
    let sealedEnvelopeBase64: String
}
private struct InsightDeviceRecoveryBody: Codable {
    let keyVersion: Int
    let recoveryProofBase64: String
    let sealedEnvelopeBase64: String
}
private struct InsightDeviceRevocationBody: Codable {
    let requesterDeviceID: UUID
    let keyVersion: Int
    let envelopes: [WorkerInsightRotationEnvelope]
}
private struct InsightSyncBody: Codable {
    let deviceID: UUID
    let cursor: Int64
    let records: [WorkerInsightSyncRecord]
}
private struct InsightRecoveryUpdateBody: Codable {
    let deviceID: UUID
    let keyVersion: Int
    let ciphertextBase64: String
    let proofDigest: String
}
private struct InsightRecoveryUpdateResponse: Codable {
    let keyVersion: Int
    let updatedAt: Int
}
private struct EmailVerificationBody: Codable { let email: String }
private struct PasswordRegistrationBody: Codable {
    let email: String
    let verificationID: String
    let verificationCode: String
    let username: String
    let password: String
    let displayName: String
}
private struct PasswordLoginBody: Codable { let username: String; let password: String }
private struct AccountProfileUpdateBody: Codable { let displayName: String }
private struct AccountAvatarUpdateBody: Codable { let dataBase64: String; let digest: String }
private struct FarmRegistrationBody: Codable { let farmID: UUID; let zoneName: String; let shareRecordName: String?; let status: String }
private struct WorkerFarmRegistrationResponse: Codable { let farmID: UUID; let status: String }
private struct InviteBody: Codable {
    let farmID: UUID
    let role: FarmRole
    let shareParticipantID: String?
    let shareURL: URL?
}
private struct CapabilityBody: Codable { let farmID: UUID; let deviceID: UUID }
private struct FarmOnlyBody: Codable { let farmID: UUID }
private struct EmptyWorkerResponse: Codable {}
