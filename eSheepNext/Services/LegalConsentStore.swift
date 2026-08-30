import Foundation

enum LegalPolicyVersions {
    static let terms = "2026.09.01"
    static let privacy = "2026.09.01"
    static let crossBorder = "2026.09.01"
    static let ai = "2026.09.01"
    static let updatedAt = "2026-08-27"
    static let effectiveAt = "2026-09-01"
}

struct LegalConsentReceipt: Codable, Equatable, Sendable {
    let termsVersion: String
    let privacyVersion: String
    let crossBorderVersion: String
    let consentedAt: Date
    let appVersion: String
    let localeIdentifier: String

    init(
        consentedAt: Date = .now,
        appVersion: String = LegalConsentReceipt.currentAppVersion,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.termsVersion = LegalPolicyVersions.terms
        self.privacyVersion = LegalPolicyVersions.privacy
        self.crossBorderVersion = LegalPolicyVersions.crossBorder
        self.consentedAt = consentedAt
        self.appVersion = appVersion
        self.localeIdentifier = localeIdentifier
    }

    var isCurrent: Bool {
        termsVersion == LegalPolicyVersions.terms &&
            privacyVersion == LegalPolicyVersions.privacy &&
            crossBorderVersion == LegalPolicyVersions.crossBorder
    }

    static var currentAppVersion: String {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        switch (shortVersion, build) {
        case let (.some(version), .some(build)) where !build.isEmpty:
            return "\(version) (\(build))"
        case let (.some(version), _):
            return version
        default:
            return "unknown"
        }
    }
}

struct LegalConsentWithdrawalEvent: Codable, Equatable, Sendable {
    let termsVersion: String
    let privacyVersion: String
    let crossBorderVersion: String
    let occurredAt: Date
    let appVersion: String
    let localeIdentifier: String

    init(
        occurredAt: Date = .now,
        appVersion: String = LegalConsentReceipt.currentAppVersion,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.termsVersion = LegalPolicyVersions.terms
        self.privacyVersion = LegalPolicyVersions.privacy
        self.crossBorderVersion = LegalPolicyVersions.crossBorder
        self.occurredAt = occurredAt
        self.appVersion = appVersion
        self.localeIdentifier = localeIdentifier
    }
}

enum LegalConsentStore {
    static func save(_ receipt: LegalConsentReceipt, for accountID: UUID) throws {
        try SecureAccountStore.save(
            JSONEncoder().encode(receipt),
            account: storageKey(for: accountID)
        )
    }

    static func receipt(for accountID: UUID) -> LegalConsentReceipt? {
        guard let data = try? SecureAccountStore.data(account: storageKey(for: accountID)) else {
            return nil
        }
        return try? JSONDecoder().decode(LegalConsentReceipt.self, from: data)
    }

    static func hasCurrentConsent(for accountID: UUID) -> Bool {
        receipt(for: accountID)?.isCurrent == true
    }

    static func remove(for accountID: UUID) throws {
        try SecureAccountStore.remove(account: storageKey(for: accountID))
    }

    static func storageKey(for accountID: UUID) -> String {
        "legal-consent.\(accountID.uuidString.lowercased())"
    }
}

struct AIPrivacyConsentReceipt: Codable, Equatable, Sendable {
    let version: String
    let consentedAt: Date

    init(version: String = LegalPolicyVersions.ai, consentedAt: Date = .now) {
        self.version = version
        self.consentedAt = consentedAt
    }

    var isCurrent: Bool { version == LegalPolicyVersions.ai }
}

enum AIPrivacyConsentAction: String, Codable, Sendable {
    case accepted
    case withdrawn
}

struct AIPrivacyConsentEvent: Codable, Equatable, Sendable {
    let version: String
    let action: AIPrivacyConsentAction
    let occurredAt: Date
    let appVersion: String
    let localeIdentifier: String

    init(
        action: AIPrivacyConsentAction,
        occurredAt: Date = .now,
        appVersion: String = LegalConsentReceipt.currentAppVersion,
        localeIdentifier: String = Locale.current.identifier
    ) {
        self.version = LegalPolicyVersions.ai
        self.action = action
        self.occurredAt = occurredAt
        self.appVersion = appVersion
        self.localeIdentifier = localeIdentifier
    }
}

enum AIPrivacyConsentStore {
    static func saveCurrentConsent(for accountID: UUID) throws {
        try SecureAccountStore.save(
            JSONEncoder().encode(AIPrivacyConsentReceipt()),
            account: storageKey(for: accountID)
        )
    }

    static func receipt(for accountID: UUID) -> AIPrivacyConsentReceipt? {
        guard let data = try? SecureAccountStore.data(account: storageKey(for: accountID)) else {
            return nil
        }
        return try? JSONDecoder().decode(AIPrivacyConsentReceipt.self, from: data)
    }

    static func hasCurrentConsent(for accountID: UUID) -> Bool {
        receipt(for: accountID)?.isCurrent == true
    }

    static func withdraw(for accountID: UUID) throws {
        try SecureAccountStore.remove(account: storageKey(for: accountID))
    }

    static func storageKey(for accountID: UUID) -> String {
        "ai-privacy-consent.\(accountID.uuidString.lowercased())"
    }
}
