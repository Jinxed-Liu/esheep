import CryptoKit
import Foundation
import SwiftData

@Model
final class AccountProfile {
    var id: UUID
    var serverAccountID: UUID?
    var appleSubjectHash: String
    var displayName: String
    @Attribute(.externalStorage) var avatarImageData: Data?
    var avatarCloudRevision: Int64?
    var avatarCloudDigest: String?
    var serverBindingStateRaw: String
    var authenticationMethodRawValue: String = AccountAuthenticationMethod.apple.rawValue
    var acceptedTermsVersion: String
    var acceptedPrivacyVersion: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        appleUserIdentifier: String,
        displayName: String,
        serverBindingStateRaw: String = ServerBindingState.pendingBroker.rawValue,
        authenticationMethod: AccountAuthenticationMethod = .apple,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.serverAccountID = nil
        self.appleSubjectHash = AppleIdentityHash.value(for: appleUserIdentifier)
        self.displayName = displayName
        self.avatarImageData = nil
        self.avatarCloudRevision = nil
        self.avatarCloudDigest = nil
        self.serverBindingStateRaw = serverBindingStateRaw
        self.authenticationMethodRawValue = authenticationMethod.rawValue
        // Consent is never inferred from account construction. WelcomeView
        // records explicit, unchecked-by-default acceptance before activating
        // the account and then sets these version fields.
        self.acceptedTermsVersion = ""
        self.acceptedPrivacyVersion = ""
        self.statusRawValue = "active"
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var serverBindingState: ServerBindingState {
        ServerBindingState(rawValue: serverBindingStateRaw) ?? .pendingBroker
    }

    var authenticationMethod: AccountAuthenticationMethod {
        AccountAuthenticationMethod(rawValue: authenticationMethodRawValue) ?? .apple
    }

    var effectiveAccountID: UUID {
        serverAccountID ?? id
    }
}

enum AccountAuthenticationMethod: String, Codable, Sendable {
    case apple
    case password
}

enum AppleIdentityHash {
    static func value(for identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ServerBindingState: String, Codable, Sendable {
    case pendingBroker
    case verified
    case failed
}
