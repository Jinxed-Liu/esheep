import Foundation
import Security

enum SecureAccountStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "无法安全保存登录状态（系统错误 \(status)）。"
        }
    }
}

struct StoredWorkerSession: Codable, Equatable {
    let accountID: UUID
    let accessExpiresAt: Int
    let refreshExpiresAt: Int

    func canResumeOffline(now: Date = .now) -> Bool {
        refreshExpiresAt > Int(now.timeIntervalSince1970)
    }
}

enum SecureAccountStore {
    private static let service = "com.sheepfarm.esheepnext.identity"
    private static let recoveryService = "com.sheepfarm.esheepnext.recovery"
    private static let appleUserKey = "apple-user-identifier"
    private static let activeAccountProfileKey = "active-account-profile-id"
    private static let workerSessionMetadataKey = "worker-session-metadata"

    static func saveAppleUserIdentifier(_ identifier: String) throws {
        try save(Data(identifier.utf8), account: appleUserKey)
    }

    static func saveActiveAccountProfileID(_ identifier: UUID) throws {
        try save(Data(identifier.uuidString.lowercased().utf8), account: activeAccountProfileKey)
    }

    static func activeAccountProfileID() -> UUID? {
        let storedData: Data?
        do {
            storedData = try data(account: activeAccountProfileKey)
        } catch {
            return nil
        }
        guard let storedData,
              let text = String(data: storedData, encoding: .utf8) else {
            return nil
        }
        return UUID(uuidString: text)
    }

    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let lookup = query.filter { $0.key != kSecAttrAccessible as String }
        let update = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }

        let add = SecItemAdd((query.merging([kSecValueData as String: data]) { _, newest in newest }) as CFDictionary, nil)
        guard add == errSecSuccess else { throw SecureAccountStoreError.unexpectedStatus(add) }
    }

    static func appleUserIdentifier() throws -> String? {
        guard let data = try data(account: appleUserKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func data(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureAccountStoreError.unexpectedStatus(status)
        }
        return data
    }

    static func removeAppleUserIdentifier() throws {
        try remove(account: appleUserKey)
    }

    static func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureAccountStoreError.unexpectedStatus(status)
        }
    }

    static func removeIdentitySecrets() throws {
        try removeLoginSecrets()
        try remove(account: activeAccountProfileKey)
        for account in ["device-id", "device-secure-enclave-key", "device-software-key"] {
            try remove(account: account)
        }
    }

    static func removeLoginSecrets() throws {
        for account in ["worker-access-token", "worker-refresh-token", workerSessionMetadataKey, appleUserKey] {
            try remove(account: account)
        }
    }

    static func saveWorkerSession(_ session: StoredWorkerSession) throws {
        try save(JSONEncoder().encode(session), account: workerSessionMetadataKey)
    }

    static func workerSession() -> StoredWorkerSession? {
        guard let stored = try? data(account: workerSessionMetadataKey) else { return nil }
        return try? JSONDecoder().decode(StoredWorkerSession.self, from: stored)
    }

    static func hasPersistedSession(for accountID: UUID) -> Bool {
        persistedSessionAccountID() == accountID
    }

    static func persistedSessionAccountID() -> UUID? {
        guard let session = workerSession(),
              (try? data(account: "worker-refresh-token")) != nil else { return nil }
        return session.accountID
    }

    static func hasWorkerSession(for accountID: UUID, now: Date = .now) -> Bool {
        guard hasPersistedSession(for: accountID),
              let session = workerSession(),
              session.canResumeOffline(now: now) else { return false }
        return true
    }

    static func saveSynchronizable(_ data: Data, account: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recoveryService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        let update = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecureAccountStoreError.unexpectedStatus(update) }
        let add = SecItemAdd((lookup.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]) { _, newest in newest }) as CFDictionary, nil)
        guard add == errSecSuccess else { throw SecureAccountStoreError.unexpectedStatus(add) }
    }

    static func synchronizableData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recoveryService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecureAccountStoreError.unexpectedStatus(status)
        }
        return data
    }
}
