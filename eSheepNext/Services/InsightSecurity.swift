import CryptoKit
import Foundation
import Security

enum MiMoCredentialKind: String, Codable, Sendable {
    case payAsYouGo
    case tokenPlan

    var baseURL: URL {
        switch self {
        case .payAsYouGo:
            URL(string: "https://api.xiaomimimo.com/v1")!
        case .tokenPlan:
            URL(string: "https://token-plan-cn.xiaomimimo.com/v1")!
        }
    }
}

struct MiMoCredential: Codable, Equatable, Sendable {
    static let textModel = "mimo-v2.5-pro"
    static let multimodalModel = "mimo-v2.5"

    let apiKey: String
    let kind: MiMoCredentialKind

    init(apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 12, normalized.count <= 512 else {
            throw InsightSecurityError.invalidAPIKey
        }
        if normalized.hasPrefix("sk-") {
            kind = .payAsYouGo
        } else if normalized.hasPrefix("tp-") {
            kind = .tokenPlan
        } else {
            throw InsightSecurityError.invalidAPIKey
        }
        self.apiKey = normalized
    }

    var responsesURL: URL {
        kind.baseURL.appending(path: "responses")
    }

    var chatCompletionsURL: URL {
        kind.baseURL.appending(path: "chat/completions")
    }

    var maskedValue: String {
        let suffix = apiKey.suffix(4)
        return "\(apiKey.prefix(3))••••••••\(suffix)"
    }
}

enum InsightSecurityError: LocalizedError {
    case invalidAPIKey
    case missingMasterKey
    case invalidEnvelope
    case invalidRecoveryCode
    case accountMismatch
    case corruptedCiphertext

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "请输入有效的 MiMo API Key（sk- 或 tp- 开头）。"
        case .missingMasterKey:
            "当前设备还没有洞察加密密钥，请先完成设备批准或恢复。"
        case .invalidEnvelope:
            "设备密钥信封无效。"
        case .invalidRecoveryCode:
            "洞察恢复码无效。"
        case .accountMismatch:
            "加密数据不属于当前 eSheep 账号。"
        case .corruptedCiphertext:
            "洞察加密数据已损坏或无法解密。"
        }
    }
}

actor MiMoCredentialVault {
    static let shared = MiMoCredentialVault()

    func credential(for accountID: UUID) throws -> MiMoCredential? {
        guard let data = try SecureAccountStore.data(account: keychainAccount(for: accountID)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return try MiMoCredential(apiKey: value)
    }

    @discardableResult
    func save(apiKey: String, for accountID: UUID) throws -> MiMoCredential {
        let credential = try MiMoCredential(apiKey: apiKey)
        try SecureAccountStore.save(Data(credential.apiKey.utf8), account: keychainAccount(for: accountID))
        try SecureAccountStore.remove(account: deletionAccount(for: accountID))
        try SecureAccountStore.save(
            Data(String(Date.now.timeIntervalSince1970).utf8),
            account: updateAccount(for: accountID)
        )
        return credential
    }

    func remove(for accountID: UUID) throws {
        try SecureAccountStore.remove(account: keychainAccount(for: accountID))
        try SecureAccountStore.remove(account: updateAccount(for: accountID))
        try SecureAccountStore.save(
            Data(String(Date.now.timeIntervalSince1970).utf8),
            account: deletionAccount(for: accountID)
        )
    }

    func deletionDate(for accountID: UUID) throws -> Date? {
        guard let data = try SecureAccountStore.data(account: deletionAccount(for: accountID)),
              let text = String(data: data, encoding: .utf8),
              let interval = TimeInterval(text) else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func updateDate(for accountID: UUID) throws -> Date? {
        guard let data = try SecureAccountStore.data(account: updateAccount(for: accountID)),
              let text = String(data: data, encoding: .utf8),
              let interval = TimeInterval(text) else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func encryptedCredential(
        for accountID: UUID,
        crypto: InsightPersonalCryptoActor = .shared
    ) async throws -> Data? {
        guard let credential = try credential(for: accountID) else { return nil }
        let payload = try JSONEncoder().encode(credential)
        return try await crypto.seal(payload, accountID: accountID, recordID: "mimo-credential")
    }

    func importEncryptedCredential(
        _ ciphertext: Data,
        for accountID: UUID,
        crypto: InsightPersonalCryptoActor = .shared
    ) async throws {
        let plaintext = try await crypto.open(ciphertext, accountID: accountID, recordID: "mimo-credential")
        let credential = try JSONDecoder().decode(MiMoCredential.self, from: plaintext)
        _ = try save(apiKey: credential.apiKey, for: accountID)
    }

    private func keychainAccount(for accountID: UUID) -> String {
        "insights.mimo-api-key.\(accountID.uuidString.lowercased())"
    }

    private func deletionAccount(for accountID: UUID) -> String {
        "insights.mimo-api-key-deleted-at.\(accountID.uuidString.lowercased())"
    }

    private func updateAccount(for accountID: UUID) -> String {
        "insights.mimo-api-key-updated-at.\(accountID.uuidString.lowercased())"
    }
}

struct InsightDeviceEncryptionIdentity: Sendable, Equatable {
    let deviceID: UUID
    let publicKeyX963: Data
    let usesSecureEnclave: Bool

    var publicKeyJWK: [String: String] {
        let coordinates = publicKeyX963.dropFirst()
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": Data(coordinates.prefix(32)).base64URLEncoded,
            "y": Data(coordinates.dropFirst(32).prefix(32)).base64URLEncoded,
            "use": "enc",
            "alg": "ECDH-ES",
        ]
    }
}

struct InsightKeyEnvelope: Codable, Sendable, Equatable {
    let version: Int
    let accountID: UUID
    let targetDeviceID: UUID
    let keyVersion: Int
    let ephemeralPublicKeyX963: Data
    let salt: Data
    let sealedMasterKey: Data
    let createdAt: Date
}

struct InsightRecoveryPackage: Codable, Sendable, Equatable {
    let version: Int
    let accountID: UUID
    let keyVersion: Int
    let salt: Data
    let sealedMasterKey: Data
    let authorizationSecret: Data
    let createdAt: Date
}

struct InsightRecoveryExport: Sendable {
    let package: InsightRecoveryPackage
    let recoveryCode: String
    let authorizationSecret: Data
}

struct InsightMasterKeyRotationCandidate: Sendable {
    let accountID: UUID
    let keyVersion: Int
    fileprivate let keyData: Data
}

actor InsightDeviceKeyAgreementActor {
    static let shared = InsightDeviceKeyAgreementActor()

    func identity() throws -> InsightDeviceEncryptionIdentity {
        let deviceID = try loadDeviceID()
        if SecureEnclave.isAvailable {
            let key = try secureEnclaveKey()
            return InsightDeviceEncryptionIdentity(
                deviceID: deviceID,
                publicKeyX963: key.publicKey.x963Representation,
                usesSecureEnclave: true
            )
        }
        let key = try softwareKey()
        return InsightDeviceEncryptionIdentity(
            deviceID: deviceID,
            publicKeyX963: key.publicKey.x963Representation,
            usesSecureEnclave: false
        )
    }

    func unwrap(_ envelope: InsightKeyEnvelope, accountID: UUID) throws -> Data {
        guard envelope.version == 1,
              envelope.accountID == accountID,
              envelope.targetDeviceID == (try identity()).deviceID else {
            throw InsightSecurityError.invalidEnvelope
        }
        let sender = try P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKeyX963)
        let secret: SharedSecret
        if SecureEnclave.isAvailable {
            secret = try secureEnclaveKey().sharedSecretFromKeyAgreement(with: sender)
        } else {
            secret = try softwareKey().sharedSecretFromKeyAgreement(with: sender)
        }
        let wrappingKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: envelope.salt,
            sharedInfo: Data("esheep-insights-key-envelope-v1".utf8),
            outputByteCount: 32
        )
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: envelope.sealedMasterKey),
                using: wrappingKey
            )
        } catch {
            throw InsightSecurityError.invalidEnvelope
        }
    }

    static func wrap(
        masterKeyData: Data,
        accountID: UUID,
        targetDeviceID: UUID,
        targetPublicKeyX963: Data,
        keyVersion: Int
    ) throws -> InsightKeyEnvelope {
        let targetKey = try P256.KeyAgreement.PublicKey(x963Representation: targetPublicKeyX963)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeralKey.sharedSecretFromKeyAgreement(with: targetKey)
        let salt = try randomData(count: 16)
        let wrappingKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("esheep-insights-key-envelope-v1".utf8),
            outputByteCount: 32
        )
        guard let combined = try AES.GCM.seal(masterKeyData, using: wrappingKey).combined else {
            throw InsightSecurityError.invalidEnvelope
        }
        return InsightKeyEnvelope(
            version: 1,
            accountID: accountID,
            targetDeviceID: targetDeviceID,
            keyVersion: keyVersion,
            ephemeralPublicKeyX963: ephemeralKey.publicKey.x963Representation,
            salt: salt,
            sealedMasterKey: combined,
            createdAt: .now
        )
    }

    private func loadDeviceID() throws -> UUID {
        if let data = try SecureAccountStore.data(account: "device-id"),
           let text = String(data: data, encoding: .utf8),
           let value = UUID(uuidString: text) {
            return value
        }
        let value = UUID()
        try SecureAccountStore.save(Data(value.uuidString.utf8), account: "device-id")
        return value
    }

    private func secureEnclaveKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let data = try SecureAccountStore.data(account: "insights-key-agreement-secure") {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        try SecureAccountStore.save(key.dataRepresentation, account: "insights-key-agreement-secure")
        return key
    }

    private func softwareKey() throws -> P256.KeyAgreement.PrivateKey {
        if let data = try SecureAccountStore.data(account: "insights-key-agreement-software") {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        let key = P256.KeyAgreement.PrivateKey()
        try SecureAccountStore.save(key.rawRepresentation, account: "insights-key-agreement-software")
        return key
    }
}

actor InsightPersonalCryptoActor {
    static let shared = InsightPersonalCryptoActor()

    func hasMasterKey(for accountID: UUID) -> Bool {
        (try? SecureAccountStore.data(account: masterKeyAccount(for: accountID))) != nil
    }

    @discardableResult
    func createMasterKeyIfNeeded(for accountID: UUID) throws -> Int {
        if try SecureAccountStore.data(account: masterKeyAccount(for: accountID)) == nil {
            try SecureAccountStore.save(try Self.randomData(count: 32), account: masterKeyAccount(for: accountID))
            try SecureAccountStore.save(Data("1".utf8), account: masterKeyVersionAccount(for: accountID))
        }
        return keyVersion(for: accountID)
    }

    func keyVersion(for accountID: UUID) -> Int {
        guard let data = try? SecureAccountStore.data(account: masterKeyVersionAccount(for: accountID)),
              let text = String(data: data, encoding: .utf8),
              let value = Int(text) else {
            return 1
        }
        return max(1, value)
    }

    func seal(_ data: Data, accountID: UUID, recordID: String) throws -> Data {
        let version = try createMasterKeyIfNeeded(for: accountID)
        let key = try derivedKey(accountID: accountID, recordID: recordID, keyVersion: version)
        let authenticatedData = associatedData(accountID: accountID, recordID: recordID, keyVersion: version)
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: authenticatedData).combined else {
            throw InsightSecurityError.corruptedCiphertext
        }
        var envelope = Data()
        var encodedVersion = UInt32(version).bigEndian
        withUnsafeBytes(of: &encodedVersion) { envelope.append(contentsOf: $0) }
        envelope.append(combined)
        return envelope
    }

    func open(_ envelope: Data, accountID: UUID, recordID: String) throws -> Data {
        guard envelope.count > 4 else { throw InsightSecurityError.corruptedCiphertext }
        let version = envelope.prefix(4).reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        let key = try derivedKey(accountID: accountID, recordID: recordID, keyVersion: Int(version))
        let authenticatedData = associatedData(accountID: accountID, recordID: recordID, keyVersion: Int(version))
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: envelope.dropFirst(4)),
                using: key,
                authenticating: authenticatedData
            )
        } catch {
            throw InsightSecurityError.corruptedCiphertext
        }
    }

    func makeEnvelope(
        for accountID: UUID,
        targetDeviceID: UUID,
        targetPublicKeyX963: Data
    ) throws -> InsightKeyEnvelope {
        let version = try createMasterKeyIfNeeded(for: accountID)
        return try InsightDeviceKeyAgreementActor.wrap(
            masterKeyData: masterKeyData(for: accountID),
            accountID: accountID,
            targetDeviceID: targetDeviceID,
            targetPublicKeyX963: targetPublicKeyX963,
            keyVersion: version
        )
    }

    func prepareRotation(
        for accountID: UUID,
        nextKeyVersion: Int
    ) throws -> InsightMasterKeyRotationCandidate {
        let currentVersion = try createMasterKeyIfNeeded(for: accountID)
        guard nextKeyVersion == currentVersion + 1 else {
            throw InsightSecurityError.invalidEnvelope
        }
        if let pendingVersionData = try SecureAccountStore.data(account: pendingKeyVersionAccount(for: accountID)),
           let pendingVersionText = String(data: pendingVersionData, encoding: .utf8),
           Int(pendingVersionText) == nextKeyVersion,
           let pendingKeyData = try SecureAccountStore.data(account: pendingKeyAccount(for: accountID)),
           pendingKeyData.count == 32 {
            return InsightMasterKeyRotationCandidate(
                accountID: accountID,
                keyVersion: nextKeyVersion,
                keyData: pendingKeyData
            )
        }
        let keyData = try Self.randomData(count: 32)
        try SecureAccountStore.save(keyData, account: pendingKeyAccount(for: accountID))
        try SecureAccountStore.save(
            Data(String(nextKeyVersion).utf8),
            account: pendingKeyVersionAccount(for: accountID)
        )
        return InsightMasterKeyRotationCandidate(
            accountID: accountID,
            keyVersion: nextKeyVersion,
            keyData: keyData
        )
    }

    func makeEnvelope(
        using candidate: InsightMasterKeyRotationCandidate,
        targetDeviceID: UUID,
        targetPublicKeyX963: Data
    ) throws -> InsightKeyEnvelope {
        try InsightDeviceKeyAgreementActor.wrap(
            masterKeyData: candidate.keyData,
            accountID: candidate.accountID,
            targetDeviceID: targetDeviceID,
            targetPublicKeyX963: targetPublicKeyX963,
            keyVersion: candidate.keyVersion
        )
    }

    func commitRotation(_ candidate: InsightMasterKeyRotationCandidate) throws {
        let currentVersion = keyVersion(for: candidate.accountID)
        guard candidate.keyVersion == currentVersion + 1 else {
            throw InsightSecurityError.invalidEnvelope
        }
        let currentKeyData = try masterKeyData(for: candidate.accountID, keyVersion: currentVersion)
        try SecureAccountStore.save(
            currentKeyData,
            account: historicalKeyAccount(for: candidate.accountID, keyVersion: currentVersion)
        )
        try SecureAccountStore.save(candidate.keyData, account: masterKeyAccount(for: candidate.accountID))
        try SecureAccountStore.save(
            Data(String(candidate.keyVersion).utf8),
            account: masterKeyVersionAccount(for: candidate.accountID)
        )
        try SecureAccountStore.remove(account: pendingKeyAccount(for: candidate.accountID))
        try SecureAccountStore.remove(account: pendingKeyVersionAccount(for: candidate.accountID))
    }

    func discardRotation(_ candidate: InsightMasterKeyRotationCandidate) throws {
        try SecureAccountStore.remove(account: pendingKeyAccount(for: candidate.accountID))
        try SecureAccountStore.remove(account: pendingKeyVersionAccount(for: candidate.accountID))
    }

    func importEnvelope(_ envelope: InsightKeyEnvelope, for accountID: UUID) async throws {
        let keyData = try await InsightDeviceKeyAgreementActor.shared.unwrap(envelope, accountID: accountID)
        guard keyData.count == 32 else { throw InsightSecurityError.invalidEnvelope }
        if hasMasterKey(for: accountID) {
            let currentVersion = keyVersion(for: accountID)
            if envelope.keyVersion < currentVersion {
                try SecureAccountStore.save(
                    keyData,
                    account: historicalKeyAccount(for: accountID, keyVersion: envelope.keyVersion)
                )
                return
            }
            if envelope.keyVersion == currentVersion {
                return
            }
            let currentKeyData = try masterKeyData(for: accountID, keyVersion: currentVersion)
            try SecureAccountStore.save(
                currentKeyData,
                account: historicalKeyAccount(for: accountID, keyVersion: currentVersion)
            )
        }
        try SecureAccountStore.save(keyData, account: masterKeyAccount(for: accountID))
        try SecureAccountStore.save(
            Data(String(envelope.keyVersion).utf8),
            account: masterKeyVersionAccount(for: accountID)
        )
        try SecureAccountStore.remove(account: pendingKeyAccount(for: accountID))
        try SecureAccountStore.remove(account: pendingKeyVersionAccount(for: accountID))
    }

    func exportRecovery(for accountID: UUID) throws -> InsightRecoveryExport {
        let keyData = try masterKeyData(for: accountID)
        let recoveryBytes = try Self.randomData(count: 20)
        let recoveryCode = Self.base32(recoveryBytes)
        let salt = try Self.randomData(count: 16)
        let authorizationSecret = try Self.randomData(count: 32)
        let wrappingKey = Self.recoveryWrappingKey(
            code: recoveryCode,
            accountID: accountID,
            salt: salt
        )
        guard let sealed = try AES.GCM.seal(keyData, using: wrappingKey).combined else {
            throw InsightSecurityError.corruptedCiphertext
        }
        return InsightRecoveryExport(
            package: InsightRecoveryPackage(
                version: 2,
                accountID: accountID,
                keyVersion: keyVersion(for: accountID),
                salt: salt,
                sealedMasterKey: sealed,
                authorizationSecret: authorizationSecret,
                createdAt: .now
            ),
            recoveryCode: recoveryCode,
            authorizationSecret: authorizationSecret
        )
    }

    func importRecovery(
        _ package: InsightRecoveryPackage,
        code: String,
        accountID: UUID
    ) throws -> Data {
        guard package.version == 2,
              package.accountID == accountID,
              package.authorizationSecret.count == 32 else {
            throw InsightSecurityError.accountMismatch
        }
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "")
        guard normalized.count >= 30 else { throw InsightSecurityError.invalidRecoveryCode }
        let wrappingKey = Self.recoveryWrappingKey(
            code: normalized,
            accountID: accountID,
            salt: package.salt
        )
        do {
            let keyData = try AES.GCM.open(
                AES.GCM.SealedBox(combined: package.sealedMasterKey),
                using: wrappingKey
            )
            guard keyData.count == 32 else { throw InsightSecurityError.invalidRecoveryCode }
            if hasMasterKey(for: accountID) {
                let currentVersion = keyVersion(for: accountID)
                let currentKeyData = try masterKeyData(for: accountID, keyVersion: currentVersion)
                try SecureAccountStore.save(
                    currentKeyData,
                    account: historicalKeyAccount(for: accountID, keyVersion: currentVersion)
                )
            }
            try SecureAccountStore.save(keyData, account: masterKeyAccount(for: accountID))
            try SecureAccountStore.save(
                Data(String(package.keyVersion).utf8),
                account: masterKeyVersionAccount(for: accountID)
            )
            return package.authorizationSecret
        } catch let error as InsightSecurityError {
            throw error
        } catch {
            throw InsightSecurityError.invalidRecoveryCode
        }
    }

    private func masterKeyData(for accountID: UUID, keyVersion requestedVersion: Int? = nil) throws -> Data {
        let currentVersion = keyVersion(for: accountID)
        let account = requestedVersion == nil || requestedVersion == currentVersion
            ? masterKeyAccount(for: accountID)
            : historicalKeyAccount(for: accountID, keyVersion: requestedVersion!)
        guard let data = try SecureAccountStore.data(account: account),
              data.count == 32 else {
            throw InsightSecurityError.missingMasterKey
        }
        return data
    }

    private func derivedKey(accountID: UUID, recordID: String, keyVersion: Int) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(
                data: try masterKeyData(for: accountID, keyVersion: keyVersion)
            ),
            salt: Data(accountID.uuidString.lowercased().utf8),
            info: Data("esheep-insights:\(keyVersion):\(recordID)".utf8),
            outputByteCount: 32
        )
    }

    private func associatedData(accountID: UUID, recordID: String, keyVersion: Int) -> Data {
        Data("\(accountID.uuidString.lowercased()):\(recordID):\(keyVersion)".utf8)
    }

    private func masterKeyAccount(for accountID: UUID) -> String {
        "insights.master-key.\(accountID.uuidString.lowercased())"
    }

    private func masterKeyVersionAccount(for accountID: UUID) -> String {
        "insights.master-key-version.\(accountID.uuidString.lowercased())"
    }

    private func historicalKeyAccount(for accountID: UUID, keyVersion: Int) -> String {
        "insights.master-key.\(accountID.uuidString.lowercased()).v\(keyVersion)"
    }

    private func pendingKeyAccount(for accountID: UUID) -> String {
        "insights.master-key.\(accountID.uuidString.lowercased()).pending"
    }

    private func pendingKeyVersionAccount(for accountID: UUID) -> String {
        "insights.master-key-version.\(accountID.uuidString.lowercased()).pending"
    }

    private static func recoveryWrappingKey(
        code: String,
        accountID: UUID,
        salt: Data
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: salt,
            info: Data("esheep-insights-recovery:\(accountID.uuidString.lowercased())".utf8),
            outputByteCount: 32
        )
    }

    private static func randomData(count: Int) throws -> Data {
        try InsightDeviceKeyAgreementActor.randomData(count: count)
    }

    private static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var result = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 {
            result.append(alphabet[(buffer << (5 - bits)) & 31])
        }
        return result
    }
}

private extension InsightDeviceKeyAgreementActor {
    static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SecureAccountStoreError.unexpectedStatus(errSecNotAvailable)
        }
        return Data(bytes)
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
