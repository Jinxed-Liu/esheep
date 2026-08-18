import Foundation
import Supabase

enum AccountIdentityProvider: String, Sendable {
    case cloudBaseLegacy
    case supabase
}

struct LegacyAccountClaim: Codable, Sendable, Equatable {
    let ticket: String
}

enum AccountIdentityClientError: LocalizedError {
    case notConfigured
    case legacyOperationUnavailable
    case invalidProfile

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Supabase 账号服务尚未配置。"
        case .legacyOperationUnavailable:
            "该操作只在旧账号认领窗口内可用。"
        case .invalidProfile:
            "Supabase 账号映射缺失或无效，请稍后重试。"
        }
    }
}

enum AccountRegistrationResult: Sendable {
    case authenticated(WorkerSessionResponse)
    case verificationRequired(email: String)
}

protocol AccountIdentityClient: Sendable {
    var provider: AccountIdentityProvider { get }

    func authenticateWithApple(
        identityToken: String,
        authorizationCode: String,
        nonce: String,
        displayName: String?
    ) async throws -> WorkerSessionResponse

    func authenticate(email: String, password: String) async throws -> WorkerSessionResponse
    func register(email: String, password: String, displayName: String) async throws -> AccountRegistrationResult
    func refreshSession() async throws -> WorkerSessionResponse
    func signOut() async throws -> WorkerSignOutResult
    func deleteAccount() async throws -> WorkerAccountDeletionResponse
    func registerDevice(
        deviceID: UUID,
        publicKeyJWK: [String: String],
        displayName: String
    ) async throws -> WorkerDeviceResponse
    func claimLegacyAccount(_ claim: LegacyAccountClaim) async throws -> UUID
}

actor CloudBaseAccountIdentityClient: AccountIdentityClient {
    static let shared = CloudBaseAccountIdentityClient()

    nonisolated let provider = AccountIdentityProvider.cloudBaseLegacy
    private let client: IdentityWorkerClient

    init(client: IdentityWorkerClient = .shared) {
        self.client = client
    }

    func authenticateWithApple(
        identityToken: String,
        authorizationCode: String,
        nonce: String,
        displayName: String?
    ) async throws -> WorkerSessionResponse {
        try await client.authenticateWithApple(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            nonce: nonce,
            displayName: displayName
        )
    }

    func authenticate(email: String, password: String) async throws -> WorkerSessionResponse {
        try await client.authenticate(username: email, password: password)
    }

    func register(email: String, password: String, displayName: String) async throws -> AccountRegistrationResult {
        throw AccountIdentityClientError.legacyOperationUnavailable
    }

    func refreshSession() async throws -> WorkerSessionResponse {
        let status = try await client.restoreSession()
        guard let metadata = SecureAccountStore.workerSession(),
              let access = try SecureAccountStore.data(account: "worker-access-token"),
              let refresh = try SecureAccountStore.data(account: "worker-refresh-token"),
              let accessToken = String(data: access, encoding: .utf8),
              let refreshToken = String(data: refresh, encoding: .utf8) else {
            throw IdentityWorkerError.missingSession
        }
        return WorkerSessionResponse(
            accessToken: accessToken,
            accessExpiresAt: metadata.accessExpiresAt,
            refreshToken: refreshToken,
            refreshExpiresAt: metadata.refreshExpiresAt,
            accountID: status.accountID,
            displayName: status.displayName
        )
    }

    func signOut() async throws -> WorkerSignOutResult {
        try await client.signOut()
    }

    func deleteAccount() async throws -> WorkerAccountDeletionResponse {
        try await client.deleteAccount()
    }

    func registerDevice(
        deviceID: UUID,
        publicKeyJWK: [String: String],
        displayName: String
    ) async throws -> WorkerDeviceResponse {
        try await client.registerDevice(
            deviceID: deviceID,
            publicKeyJWK: publicKeyJWK,
            displayName: displayName
        )
    }

    func claimLegacyAccount(_ claim: LegacyAccountClaim) async throws -> UUID {
        throw AccountIdentityClientError.legacyOperationUnavailable
    }
}

enum SupabaseAccountConfiguration {
    struct Credentials: Sendable {
        let url: URL
        let publishableKey: String
    }

    static var credentials: Credentials? {
        guard isEnabled else { return nil }
        guard let rawURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String,
              key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sb_publishable_") else {
            return nil
        }
        return Credentials(url: url, publishableKey: key)
    }

    static var isEnabled: Bool {
        if let value = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ENABLED") as? Bool {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ENABLED") as? String {
            return ["yes", "true", "1"].contains(value.lowercased())
        }
        return false
    }

    static var isConfigured: Bool { credentials != nil }
}

actor SupabaseAccountIdentityClient: AccountIdentityClient {
    nonisolated static let signOutScope: SignOutScope = .local

    private struct ProfileRow: Decodable, Sendable {
        let appAccountID: UUID
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case appAccountID = "app_account_id"
            case displayName = "display_name"
        }
    }

    private struct DeviceRegistrationParameters: Encodable, Sendable {
        let deviceID: UUID
        let publicKeyJWK: [String: String]
        let displayName: String
        let tmrDataProtocolVersion: Int

        enum CodingKeys: String, CodingKey {
            case deviceID = "p_device_id"
            case publicKeyJWK = "p_public_key_jwk"
            case displayName = "p_display_name"
            case tmrDataProtocolVersion = "p_tmr_data_protocol_version"
        }
    }

    /// Compatibility payload for farms whose Supabase migration has not yet
    /// added the TMR protocol-version argument to `register_device`.
    ///
    /// Registering the device is still required for ordinary account access.
    /// Omitting the version deliberately leaves that device ineligible for TMR
    /// cloud writes until the server migration is deployed and a later
    /// registration records the supported protocol version.
    private struct LegacyDeviceRegistrationParameters: Encodable, Sendable {
        let deviceID: UUID
        let publicKeyJWK: [String: String]
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case deviceID = "p_device_id"
            case publicKeyJWK = "p_public_key_jwk"
            case displayName = "p_display_name"
        }
    }

    private struct DeviceRegistrationRow: Decodable, Sendable {
        let deviceID: UUID
        let registeredAt: Int

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case registeredAt = "registered_at"
        }
    }

    private struct LegacyClaimParameters: Encodable, Sendable {
        let ticket: String

        enum CodingKeys: String, CodingKey {
            case ticket = "p_ticket"
        }
    }

    private struct LegacyClaimRow: Decodable, Sendable {
        let appAccountID: UUID

        enum CodingKeys: String, CodingKey {
            case appAccountID = "app_account_id"
        }
    }

    private struct AccountDeletionRow: Decodable, Sendable {
        let deletionJobID: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case deletionJobID = "deletion_job_id"
            case status
        }
    }

    nonisolated let provider = AccountIdentityProvider.supabase
    nonisolated let supabase: SupabaseClient

    init(credentials: SupabaseAccountConfiguration.Credentials) {
        let storage = KeychainLocalStorage(
            service: "com.sheepfarm.esheepnext.supabase",
            accessGroup: nil
        )
        let options = SupabaseClientOptions(
            auth: .init(
                storage: storage,
                storageKey: "eSheepNext.supabase.session",
                flowType: .pkce,
                autoRefreshToken: true,
                emitLocalSessionAsInitialSession: true
            )
        )
        self.supabase = SupabaseClient(
            supabaseURL: credentials.url,
            supabaseKey: credentials.publishableKey,
            options: options
        )
    }

    func authenticateWithApple(
        identityToken: String,
        authorizationCode _: String,
        nonce: String,
        displayName: String?
    ) async throws -> WorkerSessionResponse {
        let session = try await supabase.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: identityToken,
                nonce: nonce
            )
        )
        if let displayName = Self.normalizedDisplayName(displayName) {
            let existingProfile = try await profile(userID: session.user.id)
            if existingProfile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                try await updateDisplayName(displayName, userID: session.user.id)
            }
        }
        return try await workerSession(from: session)
    }

    func authenticate(email: String, password: String) async throws -> WorkerSessionResponse {
        let session = try await supabase.auth.signIn(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            password: password
        )
        return try await workerSession(from: session)
    }

    func register(email: String, password: String, displayName: String) async throws -> AccountRegistrationResult {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDisplayName = Self.normalizedDisplayName(displayName)
        let response = try await supabase.auth.signUp(
            email: normalizedEmail,
            password: password,
            data: normalizedDisplayName.map { ["display_name": .string($0)] }
        )
        guard let session = response.session else {
            return .verificationRequired(email: normalizedEmail)
        }
        if let normalizedDisplayName {
            try await updateDisplayName(normalizedDisplayName, userID: session.user.id)
        }
        return .authenticated(try await workerSession(from: session))
    }

    func refreshSession() async throws -> WorkerSessionResponse {
        try await workerSession(from: supabase.auth.refreshSession())
    }

    func signOut() async throws -> WorkerSignOutResult {
        defer { try? SecureAccountStore.removeSupabaseSession() }
        do {
            try await supabase.auth.signOut(scope: Self.signOutScope)
            return WorkerSignOutResult(serverSessionRevoked: true, warningMessage: nil)
        } catch {
            return WorkerSignOutResult(
                serverSessionRevoked: false,
                warningMessage: "本机已经退出，但服务器会话未能即时撤销：\(error.localizedDescription)"
            )
        }
    }

    func deleteAccount() async throws -> WorkerAccountDeletionResponse {
        let rows: [AccountDeletionRow] = try await supabase
            .rpc("request_account_deletion")
            .execute()
            .value
        guard let response = rows.first else {
            throw AccountIdentityClientError.invalidProfile
        }
        _ = try await signOut()
        return WorkerAccountDeletionResponse(
            deletionJobID: response.deletionJobID,
            status: response.status
        )
    }

    func registerDevice(
        deviceID: UUID,
        publicKeyJWK: [String: String],
        displayName: String
    ) async throws -> WorkerDeviceResponse {
        let rows: [DeviceRegistrationRow]
        do {
            rows = try await supabase
                .rpc(
                    "register_device",
                    params: DeviceRegistrationParameters(
                        deviceID: deviceID,
                        publicKeyJWK: publicKeyJWK,
                        displayName: displayName,
                        tmrDataProtocolVersion: TMRCloudDataProtocol.currentVersion
                    )
                )
                .execute()
                .value
        } catch let error as PostgrestError where Self.shouldRetryLegacyDeviceRegistration(
            code: error.code
        ) {
            rows = try await supabase
                .rpc(
                    "register_device",
                    params: LegacyDeviceRegistrationParameters(
                        deviceID: deviceID,
                        publicKeyJWK: publicKeyJWK,
                        displayName: displayName
                    )
                )
                .execute()
                .value
        }
        guard let row = rows.first else {
            throw AccountIdentityClientError.invalidProfile
        }
        return WorkerDeviceResponse(deviceID: row.deviceID, registeredAt: row.registeredAt)
    }

    nonisolated static func shouldRetryLegacyDeviceRegistration(code: String?) -> Bool {
        code == "PGRST202"
    }

    func claimLegacyAccount(_ claim: LegacyAccountClaim) async throws -> UUID {
        let rows: [LegacyClaimRow] = try await supabase
            .rpc(
                "claim_legacy_account",
                params: LegacyClaimParameters(ticket: claim.ticket)
            )
            .execute()
            .value
        guard let row = rows.first else {
            throw AccountIdentityClientError.invalidProfile
        }
        return row.appAccountID
    }

    private func workerSession(from session: Session) async throws -> WorkerSessionResponse {
        let profile = try await profile(userID: session.user.id)
        try SecureAccountStore.saveSupabaseSession(
            StoredSupabaseSession(
                accountID: profile.appAccountID,
                authUserID: session.user.id,
                lastVerifiedAt: .now
            )
        )
        return WorkerSessionResponse(
            accessToken: session.accessToken,
            accessExpiresAt: Int(session.expiresAt),
            refreshToken: session.refreshToken,
            refreshExpiresAt: Int(session.expiresAt),
            accountID: profile.appAccountID,
            displayName: profile.displayName
        )
    }

    private func profile(userID: UUID) async throws -> ProfileRow {
        let row: ProfileRow = try await supabase
            .from("profiles")
            .select("app_account_id,display_name")
            .eq("user_id", value: userID)
            .single()
            .execute()
            .value
        return row
    }

    private func updateDisplayName(_ displayName: String, userID: UUID) async throws {
        struct Update: Encodable { let display_name: String }
        try await supabase
            .from("profiles")
            .update(Update(display_name: displayName))
            .eq("user_id", value: userID)
            .execute()
    }

    nonisolated static func normalizedDisplayName(_ displayName: String?) -> String? {
        guard let displayName else { return nil }
        let withoutControls = displayName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(withoutControls))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(120))
    }
}

enum AccountIdentityClients {
    static let cloudBase: any AccountIdentityClient = CloudBaseAccountIdentityClient.shared

    private static let concreteSupabase: SupabaseAccountIdentityClient? = {
        guard let credentials = SupabaseAccountConfiguration.credentials else { return nil }
        return SupabaseAccountIdentityClient(credentials: credentials)
    }()

    static let supabase: (any AccountIdentityClient)? = concreteSupabase

    static var supabaseClient: SupabaseClient? {
        concreteSupabase?.supabase
    }

    static var activeProvider: AccountIdentityProvider {
        SupabaseAccountConfiguration.isEnabled ? .supabase : .cloudBaseLegacy
    }

    static func active() throws -> any AccountIdentityClient {
        if SupabaseAccountConfiguration.isEnabled {
            guard let supabase else { throw AccountIdentityClientError.notConfigured }
            return supabase
        }
        if IdentityWorkerConfiguration.baseURL != nil { return cloudBase }
        throw AccountIdentityClientError.notConfigured
    }
}
