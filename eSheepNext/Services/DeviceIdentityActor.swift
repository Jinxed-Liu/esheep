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
        let deviceID = try loadOrCreateDeviceID()
        if SecureEnclave.isAvailable {
            let key = try secureEnclaveKey()
            return DeviceSigningIdentity(deviceID: deviceID, publicKeyX963: key.publicKey.x963Representation, usesSecureEnclave: true)
        }
        let key = try softwareKey()
        return DeviceSigningIdentity(deviceID: deviceID, publicKeyX963: key.publicKey.x963Representation, usesSecureEnclave: false)
    }

    func sign(_ data: Data) throws -> Data {
        if SecureEnclave.isAvailable {
            return try secureEnclaveKey().signature(for: data).rawRepresentation
        }
        return try softwareKey().signature(for: data).rawRepresentation
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

    private func loadOrCreateDeviceID() throws -> UUID {
        if let data = try SecureAccountStore.data(account: "device-id"),
           let text = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: text) {
            return id
        }
        let id = UUID()
        try SecureAccountStore.save(Data(id.uuidString.utf8), account: "device-id")
        return id
    }

    private func secureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let data = try SecureAccountStore.data(account: "device-secure-enclave-key") {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        try SecureAccountStore.save(key.dataRepresentation, account: "device-secure-enclave-key")
        return key
    }

    private func softwareKey() throws -> P256.Signing.PrivateKey {
        if let data = try SecureAccountStore.data(account: "device-software-key") {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = P256.Signing.PrivateKey()
        try SecureAccountStore.save(key.rawRepresentation, account: "device-software-key")
        return key
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
