import CryptoKit
import Foundation
import Security
import UIKit

struct DeviceSigningIdentity: Sendable, Equatable {
    let deviceID: UUID
    let publicKeyX963: Data
    let usesSecureEnclave: Bool

    var publicKeyJWK: [String: String] {
        let coordinates = publicKeyX963.dropFirst()
        let x = coordinates.prefix(32)
        let y = coordinates.dropFirst(32).prefix(32)
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": Data(x).base64URLEncoded,
            "y": Data(y).base64URLEncoded,
            "use": "sig",
            "alg": "ES256",
        ]
    }
}

actor DeviceIdentityActor {
    static let shared = DeviceIdentityActor()

    func identity() throws -> DeviceSigningIdentity {
        let scope = Self.currentAccountScope()
        let deviceID = try loadOrCreateDeviceID(scope: scope)
        if SecureEnclave.isAvailable {
            let key = try secureEnclaveKey(scope: scope)
            return DeviceSigningIdentity(deviceID: deviceID, publicKeyX963: key.publicKey.x963Representation, usesSecureEnclave: true)
        }
        let key = try softwareKey(scope: scope)
        return DeviceSigningIdentity(deviceID: deviceID, publicKeyX963: key.publicKey.x963Representation, usesSecureEnclave: false)
    }

    func sign(_ data: Data) throws -> Data {
        let scope = Self.currentAccountScope()
        if SecureEnclave.isAvailable {
            return try secureEnclaveKey(scope: scope).signature(for: data).rawRepresentation
        }
        return try softwareKey(scope: scope).signature(for: data).rawRepresentation
    }

    func register(using client: IdentityWorkerClient = .shared) async throws -> DeviceSigningIdentity {
        let identity = try identity()
        _ = try await client.registerDevice(
            deviceID: identity.deviceID,
            publicKeyJWK: identity.publicKeyJWK,
            displayName: UIDevice.current.name
        )
        return identity
    }

    func registerWithActiveAccountProvider() async throws -> DeviceSigningIdentity {
        let identity = try identity()
        _ = try await AccountIdentityClients.active().registerDevice(
            deviceID: identity.deviceID,
            publicKeyJWK: identity.publicKeyJWK,
            displayName: UIDevice.current.name
        )
        return identity
    }

    /// A device signing identity belongs to an authenticated account, not to
    /// the physical installation. Reusing one unscoped identity after an
    /// account switch causes the server to correctly reject registration as a
    /// cross-account device takeover.
    nonisolated static func storageAccountName(base: String, accountID: UUID?) -> String {
        guard let accountID else { return base }
        return "\(base).account.\(accountID.uuidString.lowercased())"
    }

    private nonisolated static func currentAccountScope() -> UUID? {
        if AccountIdentityClients.activeProvider == .supabase,
           let authUserID = SecureAccountStore.supabaseSession()?.authUserID {
            return authUserID
        }
        return SecureAccountStore.persistedSessionAccountID()
    }

    private func loadOrCreateDeviceID(scope: UUID?) throws -> UUID {
        let account = Self.storageAccountName(base: "device-id", accountID: scope)
        if let data = try SecureAccountStore.data(account: account),
           let text = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: text) {
            return id
        }
        let id = UUID()
        try SecureAccountStore.save(Data(id.uuidString.utf8), account: account)
        return id
    }

    private func secureEnclaveKey(scope: UUID?) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let account = Self.storageAccountName(base: "device-secure-enclave-key", accountID: scope)
        if let data = try SecureAccountStore.data(account: account) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        try SecureAccountStore.save(key.dataRepresentation, account: account)
        return key
    }

    private func softwareKey(scope: UUID?) throws -> P256.Signing.PrivateKey {
        let account = Self.storageAccountName(base: "device-software-key", accountID: scope)
        if let data = try SecureAccountStore.data(account: account) {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = P256.Signing.PrivateKey()
        try SecureAccountStore.save(key.rawRepresentation, account: account)
        return key
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
