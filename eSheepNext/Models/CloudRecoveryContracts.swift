import Foundation

struct FarmAssetEnvelope: Codable, Sendable, Equatable {
    let farmID: UUID
    let assetID: UUID
    let entityID: UUID?
    let sourceDigest: String
    let payloadDigest: String
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let capturedAt: Date?
    let byteCount: Int64
    let createdAt: Date
    let modifiedByAccountID: UUID
    let modifiedByDeviceID: UUID
    let capabilityCertificate: String
    let signature: Data

    var canonicalSigningData: Data {
        Data([
            farmID.uuidString.lowercased(),
            assetID.uuidString.lowercased(),
            entityID?.uuidString.lowercased() ?? "",
            sourceDigest,
            payloadDigest,
            mimeType,
            String(pixelWidth),
            String(pixelHeight),
            String(byteCount),
            modifiedByAccountID.uuidString.lowercased(),
            modifiedByDeviceID.uuidString.lowercased(),
        ].joined(separator: "\n").utf8)
    }
}

struct FarmRecoveryAssetEnvelope: Codable, Sendable, Equatable {
    let farmID: UUID
    let assetID: UUID
    let payloadDigest: String
    let byteCount: Int64
    let encryptedAt: Date
}

struct FarmCheckpointManifest: Codable, Sendable, Equatable {
    struct EntitySnapshot: Codable, Sendable, Equatable {
        let entityType: String
        let entityID: UUID
        let revision: Int
        let payload: Data
        let payloadDigest: String
    }

    struct AssetReference: Codable, Sendable, Equatable {
        let assetID: UUID
        let payloadDigest: String
        let recoveryRecordName: String?
    }

    let schemaVersion: Int
    let checkpointID: UUID
    let farmID: UUID
    let createdAt: Date
    let operationWatermark: Date
    let securityGeneration: Int
    let entities: [EntitySnapshot]
    let tombstones: [FarmTombstoneEnvelope]
    let assets: [AssetReference]
    let entityCounts: [String: Int]
    let entityDigests: [String: String]
}

struct FarmMembershipSnapshotEnvelope: Codable, Sendable, Equatable {
    struct Member: Codable, Sendable, Equatable {
        let membershipID: String
        let accountID: UUID
        let role: FarmRole
        let status: String
        let shareParticipantRecordName: String?
    }

    struct Device: Codable, Sendable, Equatable {
        let deviceID: UUID
        let accountID: UUID
        let publicKeyJWK: String
    }

    struct RevokedCertificate: Codable, Sendable, Equatable {
        let certificateID: String
        let revokedAt: Int
    }

    let farmID: UUID
    let generation: Int
    let issuedAt: Date
    let members: [Member]
    let devices: [Device]
    let revokedCertificates: [RevokedCertificate]
}

struct MembershipSnapshotRecordValue: Sendable, Equatable {
    let id: UUID
    let farmID: UUID
    let generation: Int
    let issuedAt: Date
    let payload: Data
    let signedByAccountID: UUID
    let signedByDeviceID: UUID
    let capabilityCertificate: String
    let signature: Data
    let cloudRecordName: String?
    let validatedAt: Date?
}

struct FarmTombstoneEnvelope: Codable, Sendable, Equatable {
    let tombstoneID: UUID
    let farmID: UUID
    let entityType: String
    let entityID: UUID
    let revision: Int
    let deletedAt: Date
    let deletedByAccountID: UUID
    let reason: String
    let operationID: UUID
    let restoresTombstoneID: UUID?
}

enum ConflictResolutionDecision: Codable, Sendable, Equatable {
    case acceptLocal
    case acceptRemote
    case mergeText(String)
}

struct FarmRecoveryPackage: Codable, Sendable, Equatable {
    let version: Int
    let farmID: UUID
    let salt: Data
    let sealedRecoveryKey: Data
    let createdAt: Date
    let checksum: String
}
