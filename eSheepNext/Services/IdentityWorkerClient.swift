import Foundation

enum IdentityWorkerConfiguration {
    static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "IDENTITY_WORKER_URL") as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: raw)
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

enum IdentityWorkerError: LocalizedError, Equatable {
    case notConfigured
    case missingSession
    case invalidResponse
    case networkUnavailable(host: String, code: URLError.Code)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "身份服务尚未配置。请先部署 Development Worker 并填写 IDENTITY_WORKER_URL。"
        case .missingSession: "身份服务会话不存在，请重新使用 Apple 登录。"
        case .invalidResponse: "身份服务返回了无法解析的响应。"
        case .networkUnavailable(let host, .timedOut): "连接身份服务超时（\(host)）。请检查网络后重试。"
        case .networkUnavailable(let host, _): "无法连接身份服务（\(host)）。密码注册和登录需要账号服务器可用，请检查网络后重试。"
        case .server(_, let message): message
        }
    }

    var canDeferAppleBroker: Bool {
        guard case .networkUnavailable(_, let code) = self else { return false }
        return switch code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .timedOut:
            true
        default:
            false
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
}

struct WorkerRedeemResponse: Codable, Sendable {
    let inviteID: String
    let farmID: UUID
    let role: FarmRole
    let membershipStatus: String
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
    struct Membership: Codable, Sendable {
        let farm_id: UUID
        let role: FarmRole
        let status: String
    }

    let accountID: UUID
    let displayName: String?
    let status: String
    let memberships: [Membership]
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

    func register(username: String, password: String, displayName: String) async throws -> WorkerSessionResponse {
        let response: WorkerSessionResponse = try await request(
            path: "/v1/auth/register",
            method: "POST",
            body: PasswordRegistrationBody(username: username, password: password, displayName: displayName),
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

    func registerFarm(farmID: UUID, zoneName: String, shareRecordName: String?) async throws {
        let _: EmptyWorkerResponse = try await request(path: "/v1/farms/register", method: "POST", body: FarmRegistrationBody(farmID: farmID, zoneName: zoneName, shareRecordName: shareRecordName))
    }

    func createInvite(farmID: UUID, role: FarmRole) async throws -> WorkerInviteResponse {
        try await request(path: "/v1/invites", method: "POST", body: InviteBody(farmID: farmID, role: role))
    }

    func redeemInvite(code: String) async throws -> WorkerRedeemResponse {
        try await request(path: "/v1/invites/redeem", method: "POST", body: ["code": code])
    }

    func confirmInvite(inviteID: String, participantRecordName: String) async throws {
        let _: EmptyWorkerResponse = try await request(path: "/v1/invites/\(inviteID)/confirm", method: "POST", body: ["shareParticipantRecordName": participantRecordName])
    }

    func changeMemberRole(memberID: String, farmID: UUID, role: FarmRole) async throws {
        let _: EmptyWorkerResponse = try await request(path: "/v1/members/\(memberID)", method: "PATCH", body: InviteBody(farmID: farmID, role: role))
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
        allowRefresh: Bool = true
    ) async throws -> Response {
        guard let baseURL = IdentityWorkerConfiguration.baseURL else { throw IdentityWorkerError.notConfigured }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw IdentityWorkerError.notConfigured }
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
        request.timeoutInterval = 15
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
            return try await self.request(path: path, method: method, body: body, authenticated: true, allowRefresh: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? decoder.decode(WorkerErrorEnvelope.self, from: data) {
                throw IdentityWorkerError.server(code: envelope.error.code, message: envelope.error.message)
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
    }
}

private struct DeviceRegistrationBody: Codable { let deviceID: UUID; let publicKeyJWK: [String: String]; let displayName: String }
private struct PasswordRegistrationBody: Codable { let username: String; let password: String; let displayName: String }
private struct PasswordLoginBody: Codable { let username: String; let password: String }
private struct FarmRegistrationBody: Codable { let farmID: UUID; let zoneName: String; let shareRecordName: String? }
private struct InviteBody: Codable { let farmID: UUID; let role: FarmRole }
private struct CapabilityBody: Codable { let farmID: UUID; let deviceID: UUID }
private struct FarmOnlyBody: Codable { let farmID: UUID }
private struct EmptyWorkerResponse: Codable {}
