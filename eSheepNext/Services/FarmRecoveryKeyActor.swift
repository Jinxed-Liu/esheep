import CryptoKit
import Foundation
import Security

enum FarmRecoveryError: LocalizedError {
    case invalidRecoveryCode
    case invalidRecoveryPackage
    case farmMismatch
    case corruptedCiphertext

    var errorDescription: String? {
        switch self {
        case .invalidRecoveryCode: "恢复码无效。"
        case .invalidRecoveryPackage: "恢复包格式或校验值无效。"
        case .farmMismatch: "恢复包不属于当前牧场。"
        case .corruptedCiphertext: "加密恢复数据已损坏。"
        }
    }
}

struct FarmRecoveryExport: Sendable {
    let packageData: Data
    let recoveryCode: String
}

actor FarmRecoveryKeyActor {
    static let shared = FarmRecoveryKeyActor()

    func key(for farmID: UUID) throws -> SymmetricKey {
        let account = keychainAccount(for: farmID)
        if let data = try SecureAccountStore.synchronizableData(account: account), data.count == 32 {
            return SymmetricKey(data: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SecureAccountStoreError.unexpectedStatus(errSecNotAvailable)
        }
        let data = Data(bytes)
        try SecureAccountStore.saveSynchronizable(data, account: account)
        return SymmetricKey(data: data)
    }

    func exportRecoveryPackage(farmID: UUID) throws -> FarmRecoveryExport {
        let keyData = try key(for: farmID).withUnsafeBytes { Data($0) }
        var codeBytes = [UInt8](repeating: 0, count: 20)
        guard SecRandomCopyBytes(kSecRandomDefault, codeBytes.count, &codeBytes) == errSecSuccess else {
            throw SecureAccountStoreError.unexpectedStatus(errSecNotAvailable)
        }
        let recoveryCode = Self.base32(Data(codeBytes))
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw SecureAccountStoreError.unexpectedStatus(errSecNotAvailable)
        }
        let wrappingKey = Self.wrappingKey(code: recoveryCode, farmID: farmID, salt: Data(salt))
        let sealed = try AES.GCM.seal(keyData, using: wrappingKey)
        guard let combined = sealed.combined else { throw FarmRecoveryError.invalidRecoveryPackage }
        let checksum = CloudPayloadDigest.hex(for: combined)
        let package = FarmRecoveryPackage(version: 1, farmID: farmID, salt: Data(salt), sealedRecoveryKey: combined, createdAt: .now, checksum: checksum)
        return FarmRecoveryExport(packageData: try JSONEncoder.cloud.encode(package), recoveryCode: recoveryCode)
    }

    func importRecoveryPackage(_ data: Data, recoveryCode: String, farmID: UUID) throws {
        let package = try JSONDecoder.cloudRecovery.decode(FarmRecoveryPackage.self, from: data)
        guard package.version == 1 else { throw FarmRecoveryError.invalidRecoveryPackage }
        guard package.farmID == farmID else { throw FarmRecoveryError.farmMismatch }
        guard CloudPayloadDigest.hex(for: package.sealedRecoveryKey) == package.checksum else { throw FarmRecoveryError.invalidRecoveryPackage }
        let normalized = recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count >= 30 else { throw FarmRecoveryError.invalidRecoveryCode }
        let wrappingKey = Self.wrappingKey(code: normalized, farmID: farmID, salt: package.salt)
        do {
            let box = try AES.GCM.SealedBox(combined: package.sealedRecoveryKey)
            let keyData = try AES.GCM.open(box, using: wrappingKey)
            guard keyData.count == 32 else { throw FarmRecoveryError.invalidRecoveryPackage }
            try SecureAccountStore.saveSynchronizable(keyData, account: keychainAccount(for: farmID))
        } catch let error as FarmRecoveryError {
            throw error
        } catch {
            throw FarmRecoveryError.invalidRecoveryCode
        }
    }

    func seal(_ data: Data, farmID: UUID) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key(for: farmID)).combined else {
            throw FarmRecoveryError.corruptedCiphertext
        }
        return combined
    }

    func open(_ data: Data, farmID: UUID) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(for: farmID))
        } catch {
            throw FarmRecoveryError.corruptedCiphertext
        }
    }

    private func keychainAccount(for farmID: UUID) -> String {
        "farm-recovery-key.\(farmID.uuidString.lowercased())"
    }

    private static func wrappingKey(code: String, farmID: UUID, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: salt,
            info: Data(farmID.uuidString.lowercased().utf8),
            outputByteCount: 32
        )
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
        if bits > 0 { result.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return result
    }
}

private extension JSONDecoder {
    static var cloudRecovery: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
