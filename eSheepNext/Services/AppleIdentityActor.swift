import AuthenticationServices
import CryptoKit
import Foundation

struct AppleAuthorizationPayload: Sendable {
    let appleUserIdentifier: String
    let identityToken: String
    let authorizationCode: String
    let rawNonce: String
    let displayName: String
}

enum AppleIdentityError: LocalizedError {
    case missingIdentityToken
    case missingAuthorizationCode
    case invalidCredentialEncoding

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken: "Apple 登录未返回 identity token。"
        case .missingAuthorizationCode: "Apple 登录未返回 authorization code。"
        case .invalidCredentialEncoding: "Apple 登录凭据编码无效。"
        }
    }
}

actor AppleIdentityActor {
    static let shared = AppleIdentityActor()

    func bind(_ payload: AppleAuthorizationPayload, client: IdentityWorkerClient = .shared) async throws -> WorkerSessionResponse {
        let response = try await client.authenticateWithApple(
            identityToken: payload.identityToken,
            authorizationCode: payload.authorizationCode,
            nonce: payload.rawNonce,
            displayName: payload.displayName
        )
        try SecureAccountStore.saveAppleUserIdentifier(payload.appleUserIdentifier)
        return response
    }

    static func makeNonce() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return Data(bytes).base64EncodedString()
    }

    static func hashedNonce(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func payload(from credential: ASAuthorizationAppleIDCredential, rawNonce: String) throws -> AppleAuthorizationPayload {
        guard let identityTokenData = credential.identityToken else { throw AppleIdentityError.missingIdentityToken }
        guard let authorizationCodeData = credential.authorizationCode else { throw AppleIdentityError.missingAuthorizationCode }
        guard let identityToken = String(data: identityTokenData, encoding: .utf8),
              let authorizationCode = String(data: authorizationCodeData, encoding: .utf8) else {
            throw AppleIdentityError.invalidCredentialEncoding
        }
        let formatter = PersonNameComponentsFormatter()
        let formattedName = credential.fullName.map(formatter.string(from:)) ?? ""
        return AppleAuthorizationPayload(
            appleUserIdentifier: credential.user,
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            rawNonce: rawNonce,
            displayName: formattedName.isEmpty ? "Apple 账户" : formattedName
        )
    }
}
