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

    /// Version 2 additionally authenticates user-visible photo metadata. The
    /// legacy representation remains available only for existing records that
    /// do not carry `assetSignatureVersion`.
    var canonicalSigningDataV2: Data {
        Data([
            "eSheepNext.FarmAsset.v2",
            farmID.uuidString.lowercased(),
            assetID.uuidString.lowercased(),
            entityID?.uuidString.lowercased() ?? "",
            sourceDigest,
            payloadDigest,
            mimeType,
            String(pixelWidth),
            String(pixelHeight),
            capturedAt.map(Self.millisecondsText) ?? "",
            String(byteCount),
            Self.millisecondsText(createdAt),
            modifiedByAccountID.uuidString.lowercased(),
            modifiedByDeviceID.uuidString.lowercased(),
        ].joined(separator: "\n").utf8)
    }

    private static func millisecondsText(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }
}

enum FarmAssetSignatureFormat: Int, Sendable, Equatable {
    case legacyV1 = 1
    case v2 = 2
}

/// One verifier for both live change ingestion and full cloud rebuilds. A
/// declared v2 record may contain a legacy signature when an older installed
/// client updated it with CloudKit's `changedKeys` policy, which leaves the v2
/// marker on the server. Accept that narrow case only after v2 verification
/// fails and the complete legacy payload independently verifies.
enum FarmAssetSignatureVerifier {
    static func verify(
        envelope: FarmAssetEnvelope,
        declaredVersion: Int?,
        publicKeyX963: Data
    ) throws -> FarmAssetSignatureFormat {
        switch declaredVersion {
        case nil, FarmAssetSignatureFormat.legacyV1.rawValue:
            try DeviceSignatureVerifier.verify(
                signature: envelope.signature,
                data: envelope.canonicalSigningData,
                publicKeyX963: publicKeyX963
            )
            return .legacyV1
        case FarmAssetSignatureFormat.v2.rawValue:
            do {
                try DeviceSignatureVerifier.verify(
                    signature: envelope.signature,
                    data: envelope.canonicalSigningDataV2,
                    publicKeyX963: publicKeyX963
                )
                return .v2
            } catch {
                try DeviceSignatureVerifier.verify(
                    signature: envelope.signature,
                    data: envelope.canonicalSigningData,
                    publicKeyX963: publicKeyX963
                )
                return .legacyV1
            }
        default:
            throw CloudContractError.invalidDeviceSignature
        }
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
        let operationID: UUID?
        let baseRevision: Int?
        let occurredAt: Date?
        let deletedAt: Date?

        init(
            entityType: String,
            entityID: UUID,
            revision: Int,
            payload: Data,
            payloadDigest: String,
            operationID: UUID? = nil,
            baseRevision: Int? = nil,
            occurredAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.entityType = entityType
            self.entityID = entityID
            self.revision = revision
            self.payload = payload
            self.payloadDigest = payloadDigest
            self.operationID = operationID
            self.baseRevision = baseRevision
            self.occurredAt = occurredAt
            self.deletedAt = deletedAt
        }
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

enum CloudDevicePublicKeyDecoder {
    static func x963Representation(fromJWKJSON json: String) -> Data? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let xText = object["x"],
              let yText = object["y"],
              let x = base64URLData(xText),
              let y = base64URLData(yText),
              x.count == 32,
              y.count == 32 else {
            return nil
        }
        return Data([0x04]) + x + y
    }

    private static func base64URLData(_ text: String) -> Data? {
        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(
            String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        )
        return Data(base64Encoded: normalized)
    }
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
