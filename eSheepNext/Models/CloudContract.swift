import CryptoKit
import Foundation

enum CloudRecordType: String, CaseIterable, Codable, Sendable {
    case farmRoot = "FarmRoot"
    case farmEntity = "FarmEntity"
    case farmOperation = "FarmOperation"
    case farmTombstone = "FarmTombstone"
    case farmAsset = "FarmAsset"
    case farmMembershipSnapshot = "FarmMembershipSnapshot"
    case farmCheckpoint = "FarmCheckpoint"
    case farmRecoveryAsset = "FarmRecoveryAsset"
}

enum CloudEntityType: String, CaseIterable, Codable, Sendable {
    case farm
    case pen
    case sheep
    case weight
    case weaning
    case breedingProgram
    case transfer
    case removal
    case productionBatch
    case batchMembership
    case feedIngredient
    case feedRecipe
    case feedRecipeComponent
    case feed
    case feedLine
    case inventoryLot
    case inventoryTransaction
    case health
    case reproduction
    case semen
    case note
    case photoAsset
    case breedingProgramStep
    case feedIngredientBatch
    case healthCatalogItem
    case healthSubjectLink
    case lambingOffspring
    case careBatch
    case semenTransaction
    case careRule
    case careReminder
}

struct BootstrapEntityEnvelopeV1: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let entityType: String
    let entityID: UUID
    let sourceRevision: Int
    let sourcePayload: Data
    let sourcePayloadDigest: String

    init(entityType: String, entityID: UUID, sourceRevision: Int, sourcePayload: Data) {
        self.schemaVersion = Self.schemaVersion
        self.entityType = entityType
        self.entityID = entityID
        self.sourceRevision = max(1, sourceRevision)
        self.sourcePayload = sourcePayload
        self.sourcePayloadDigest = CloudPayloadDigest.hex(for: sourcePayload)
    }

    func validate(for envelope: CloudOperationEnvelope) throws {
        guard schemaVersion == Self.schemaVersion,
              entityType == envelope.entityType,
              entityID == envelope.entityID,
              CloudPayloadDigest.hex(for: sourcePayload) == sourcePayloadDigest else {
            throw CloudContractError.malformedRecord
        }
    }
}

struct CloudOperationEnvelope: Codable, Sendable, Equatable {
    let farmID: UUID
    let entityID: UUID
    let entityType: String
    let schemaVersion: Int
    let revision: Int
    let baseRevision: Int
    let operationID: UUID
    let modifiedAt: Date
    let modifiedByAccountID: UUID
    let modifiedByDeviceID: UUID
    let payload: Data
    let payloadDigest: String
    let capabilityCertificate: String
    let operationSignature: Data
    let deletedAt: Date?

    var canonicalSigningData: Data {
        let components = [
            farmID.uuidString.lowercased(),
            entityID.uuidString.lowercased(),
            entityType,
            String(schemaVersion),
            String(revision),
            String(baseRevision),
            operationID.uuidString.lowercased(),
            modifiedByAccountID.uuidString.lowercased(),
            modifiedByDeviceID.uuidString.lowercased(),
            payloadDigest,
            deletedAt.map { CloudDateText.string(from: $0) } ?? "",
        ]
        return Data(components.joined(separator: "\n").utf8)
    }
}

struct CapabilityCertificateClaims: Codable, Sendable, Equatable {
    let certificateID: String
    let accountID: UUID
    let farmID: UUID
    let deviceID: UUID
    let role: FarmRole
    let capabilities: [FarmCapability]
    let iat: Int
    let exp: Int
    let iss: String
    let aud: String

    var isCurrentlyValid: Bool {
        let current = Int(Date().timeIntervalSince1970)
        return iat <= current + 60 && exp > current && iss == "esheep-next-identity" && aud == "esheep-next-cloud-operation"
    }

    func isValid(at date: Date) -> Bool {
        let timestamp = Int(date.timeIntervalSince1970)
        return iat <= timestamp + 60 && exp > timestamp && iss == "esheep-next-identity" && aud == "esheep-next-cloud-operation"
    }
}

enum CloudPayloadDigest {
    static func hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CloudContractError: LocalizedError, Equatable {
    case invalidPayloadDigest
    case invalidCertificate
    case expiredCertificate
    case certificateScopeMismatch
    case capabilityDenied
    case invalidDeviceSignature
    case malformedRecord
    case membershipSnapshotRollback

    var errorDescription: String? {
        switch self {
        case .invalidPayloadDigest: "云端记录的内容摘要不匹配。"
        case .invalidCertificate: "云端记录的能力证书无效。"
        case .expiredCertificate: "云端记录使用了已过期的能力证书。"
        case .certificateScopeMismatch: "能力证书与牧场、账号或设备不匹配。"
        case .capabilityDenied: "能力证书不允许执行该操作。"
        case .invalidDeviceSignature: "设备操作签名无效。"
        case .malformedRecord: "云端记录字段不完整或格式无效。"
        case .membershipSnapshotRollback: "成员安全快照版本低于本机已验证版本。"
        }
    }
}

enum CloudOperationSecurity {
    static func requiredCapability(for entityType: String, deletedAt: Date?) -> FarmCapability {
        if deletedAt != nil { return .deleteProtectedFacts }
        switch CloudEntityType(rawValue: entityType) {
        case .feedIngredient, .feedRecipe, .feedRecipeComponent, .semen, .breedingProgram, .healthCatalogItem, .careRule:
            return .manageCatalogs
        default:
            return .recordProduction
        }
    }

    static func requiredCapability(for envelope: CloudOperationEnvelope) -> FarmCapability {
        if let payload = try? JSONDecoder.cloudOperation.decode(FarmCommandCloudPayload.self, from: envelope.payload) {
            switch payload.kind {
            case .updateFarmLocation: return .editFarmLocation
            case .tombstoneEntity, .restoreTombstonedEntity, .correctWeight, .correctTransfer, .correctRemoval: return .deleteProtectedFacts
            case .resolveConflict: return .resolveConflicts
            case .recoverEntity: return .recoverFarm
            default: break
            }
        }
        return requiredCapability(for: envelope.entityType, deletedAt: envelope.deletedAt)
    }

    static func validate(
        envelope: CloudOperationEnvelope,
        claims: CapabilityCertificateClaims,
        devicePublicKeyX963: Data,
        authorizationDate: Date? = nil
    ) throws {
        guard CloudPayloadDigest.hex(for: envelope.payload) == envelope.payloadDigest else {
            throw CloudContractError.invalidPayloadDigest
        }
        // A capability authorizes the cloud write, not the historical business
        // date carried by an offline or migrated operation. CloudKit's server
        // modification date is therefore the authoritative authorization time
        // when it is available. The fallback preserves local/test validation.
        guard claims.isValid(at: authorizationDate ?? envelope.modifiedAt) else {
            throw CloudContractError.expiredCertificate
        }
        guard claims.farmID == envelope.farmID,
              claims.accountID == envelope.modifiedByAccountID,
              claims.deviceID == envelope.modifiedByDeviceID else {
            throw CloudContractError.certificateScopeMismatch
        }
        let required = requiredCapability(for: envelope)
        guard claims.capabilities.contains(required) else { throw CloudContractError.capabilityDenied }
        let publicKey = try P256.Signing.PublicKey(x963Representation: devicePublicKeyX963)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: envelope.operationSignature)
        guard publicKey.isValidSignature(signature, for: envelope.canonicalSigningData) else {
            throw CloudContractError.invalidDeviceSignature
        }
    }
}

private extension JSONDecoder {
    static var cloudOperation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum CloudDateText {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension JSONEncoder {
    static var cloud: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
