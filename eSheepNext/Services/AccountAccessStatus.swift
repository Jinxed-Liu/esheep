import Foundation
import Supabase

enum AccountAccessStatus: Equatable {
    case checking
    case verified
    case transferred
    case availableWithWarning(String)
    case localOnly(String)
    case requiresSignIn(String)

    var allowsCloudOperations: Bool {
        switch self {
        case .verified, .transferred, .availableWithWarning:
            true
        case .checking, .localOnly, .requiresSignIn:
            false
        }
    }

    var requiresSignIn: Bool {
        if case .requiresSignIn = self { return true }
        return false
    }

    var taskKey: String {
        switch self {
        case .checking: "checking"
        case .verified: "verified"
        case .transferred: "transferred"
        case .availableWithWarning: "available-with-warning"
        case .localOnly: "local-only"
        case .requiresSignIn: "requires-sign-in"
        }
    }
}

@MainActor
enum AccountAccessResolver {
    static func resolve(for account: AccountProfile) async -> AccountAccessStatus {
        await resolve(
            for: account,
            appleStatusProvider: {
                await AppleCredentialVerifier.currentStatus()
            },
            remoteSessionProvider: {
                if AccountIdentityClients.activeProvider == .supabase {
                    let session = try await AccountIdentityClients.active().refreshSession()
                    return WorkerAccountStatus(
                        accountID: session.accountID,
                        displayName: session.displayName,
                        status: "active",
                        memberships: []
                    )
                }
                return try await IdentityWorkerClient.shared.restoreSession()
            }
        )
    }

    static func resolve(
        for account: AccountProfile,
        appleStatusProvider: () async -> AppleCredentialStatus,
        remoteSessionProvider: () async throws -> WorkerAccountStatus
    ) async -> AccountAccessStatus {
        let appleStatus: AppleCredentialStatus
        if account.authenticationMethod == .password {
            appleStatus = .authorized
        } else {
            appleStatus = await appleStatusProvider()
            if appleStatus == .requiresSignIn {
                return .requiresSignIn("Apple 登录已撤销或不再可用，请重新登录。")
            }
        }

        do {
            let remote = try await remoteSessionProvider()
            guard remote.accountID == account.effectiveAccountID else {
                return .requiresSignIn("云端会话与当前本机账户不一致，请重新登录。")
            }
            guard remote.status == "active" else {
                return .requiresSignIn("账户当前不可用，请重新登录确认账户状态。")
            }

            switch appleStatus {
            case .transferred:
                return .transferred
            case .unavailable(let message):
                return .availableWithWarning("\(message) 云端会话仍然有效。")
            case .checking:
                return .availableWithWarning("Apple 登录状态仍在确认，云端会话仍然有效。")
            case .authorized:
                return .verified
            case .requiresSignIn:
                return .requiresSignIn("Apple 登录已撤销或不再可用，请重新登录。")
            }
        } catch let error as IdentityWorkerError {
            if error.requiresFreshAuthentication {
                return .requiresSignIn(error.localizedDescription)
            }
            return .localOnly(error.localizedDescription)
        } catch let error as AuthError {
            if error.requiresFreshAuthentication {
                return .requiresSignIn("Supabase 登录会话不存在或已失效，请重新登录。")
            }
            return .localOnly(error.localizedDescription)
        } catch let error as URLError {
            return .localOnly(error.localizedDescription)
        } catch {
            return .localOnly("身份服务暂时不可用，稍后会自动重试。")
        }
    }
}

extension AuthError {
    var requiresFreshAuthentication: Bool {
        switch self {
        case .sessionMissing:
            true
        case .api(_, let errorCode, _, _):
            [
                ErrorCode.noAuthorization,
                ErrorCode.userNotFound,
                ErrorCode.sessionNotFound,
                ErrorCode.sessionExpired,
                ErrorCode.refreshTokenNotFound,
                ErrorCode.refreshTokenAlreadyUsed,
                ErrorCode.userBanned,
                ErrorCode.invalidJWT,
            ].contains(errorCode)
        case .jwtVerificationFailed:
            true
        case .missingExpClaim, .malformedJWT:
            true
        case .weakPassword,
             .pkceGrantCodeExchange,
             .implicitGrantRedirect,
             .invalidRedirectScheme,
             .missingURL:
            false
        }
    }
}

extension IdentityWorkerError {
    var requiresFreshAuthentication: Bool {
        switch self {
        case .missingSession:
            true
        case .server(let code, _):
            [
                "account_deleted",
                "account_unavailable",
                "authentication_required",
                "invalid_access_token",
                "invalid_grant",
                "invalid_refresh_token",
                "missing_access_token",
                "revoked_session",
                "session_expired",
                "unauthorized",
            ].contains(code.lowercased())
        case .notConfigured, .invalidResponse, .networkUnavailable:
            false
        }
    }
}
