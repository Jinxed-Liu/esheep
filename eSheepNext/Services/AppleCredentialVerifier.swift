import AuthenticationServices
import Foundation

enum AppleCredentialStatus: Equatable {
    case checking
    case authorized
    case transferred
    case requiresSignIn
    case unavailable(String)
}

@MainActor
enum AppleCredentialVerifier {
    static func currentStatus() async -> AppleCredentialStatus {
        do {
            guard let identifier = try SecureAccountStore.appleUserIdentifier() else {
                return .requiresSignIn
            }
            return await withCheckedContinuation { continuation in
                ASAuthorizationAppleIDProvider().getCredentialState(forUserID: identifier) { state, error in
                    if error != nil {
                        continuation.resume(returning: .unavailable("暂时无法验证 Apple 登录状态。"))
                        return
                    }
                    switch state {
                    case .authorized: continuation.resume(returning: .authorized)
                    case .transferred: continuation.resume(returning: .transferred)
                    case .revoked, .notFound: continuation.resume(returning: .requiresSignIn)
                    @unknown default: continuation.resume(returning: .unavailable("Apple 登录状态未知，请稍后重试。"))
                    }
                }
            }
        } catch {
            return .unavailable("无法读取本机安全登录状态。")
        }
    }
}
