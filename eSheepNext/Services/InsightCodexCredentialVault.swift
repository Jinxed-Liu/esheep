import Foundation

/// This is only the eSheep bridge credential. ChatGPT access/refresh/ID tokens are never
/// copied into the iOS app by this transport or stored in personal-space sync records.
actor InsightCodexCredentialVault {
    static let shared = InsightCodexCredentialVault()

    func token(accountID: UUID, hostID: UUID) throws -> String? {
        guard let data = try SecureAccountStore.data(account: key(accountID: accountID, hostID: hostID)) else { return nil }
        guard let token = String(data: data, encoding: .utf8),
              (32...1024).contains(token.count), !token.contains(where: { $0.isWhitespace }) else {
            throw InsightCodexError.missingBridgeCredential
        }
        return token
    }

    func save(token: String, accountID: UUID, hostID: UUID) throws {
        guard (32...1024).contains(token.count), !token.contains(where: { $0.isWhitespace }) else {
            throw InsightCodexError.missingBridgeCredential
        }
        try SecureAccountStore.save(Data(token.utf8), account: key(accountID: accountID, hostID: hostID))
    }

    func remove(accountID: UUID, hostID: UUID) throws {
        try SecureAccountStore.remove(account: key(accountID: accountID, hostID: hostID))
    }

    private func key(accountID: UUID, hostID: UUID) -> String {
        "insights.codex-bridge.\(accountID.uuidString.lowercased()).\(hostID.uuidString.lowercased())"
    }
}
