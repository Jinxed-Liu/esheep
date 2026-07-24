import CloudKit
import Foundation
import SwiftData

enum CloudDatabaseScope: String, Codable, Sendable {
    case privateDatabase
    case sharedDatabase
}

enum CloudFarmBindingState: String, Codable, Sendable {
    case localOnly
    case preparingZone
    case active
    case rebuildingCache
    case accessRevoked
    case requiresAccountReview
    case failed
}

enum FarmMembershipStatus: String, Codable, Sendable {
    case pendingInvite
    case pendingShareAcceptance
    case pendingOwnerConfirmation
    case active
    case revoked
}

enum SyncConflictStatus: String, Codable, Sendable {
    case unresolved
    case acceptedLocal
    case acceptedRemote
    case ownerResolved
    case quarantined
}

enum CloudAssetTransferStatus: String, Codable, Sendable {
    case pending
    case uploading
    case downloading
    case completed
    case failed
}

enum CloudAssetTransferDirection: String, Codable, Sendable {
    case upload
    case download
    case recoveryBackup
    case recoveryRestore
}

enum CloudAssetBackupStatus: String, Codable, Sendable {
    case notRequired
    case pending
    case completed
    case failed
}

@Model
final class CloudFarmBinding {
    var id: UUID
    var farmID: UUID
    var ownerAccountID: UUID
    var zoneName: String
    var zoneOwnerName: String
    var databaseScopeRawValue: String
    var shareRecordName: String?
    var stateRawValue: String
    var lastSuccessfulSyncAt: Date?
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date
    var securityGeneration: Int = 0
    var lastMembershipSnapshotAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        ownerAccountID: UUID,
        databaseScope: CloudDatabaseScope = .privateDatabase,
        state: CloudFarmBindingState = .localOnly
    ) {
        self.id = id
        self.farmID = farmID
        self.ownerAccountID = ownerAccountID
        self.zoneName = CloudZoneName.forFarm(farmID)
        self.zoneOwnerName = CKCurrentUserDefaultName
        self.databaseScopeRawValue = databaseScope.rawValue
        self.stateRawValue = state.rawValue
        self.createdAt = .now
        self.updatedAt = .now
    }

    var databaseScope: CloudDatabaseScope {
        CloudDatabaseScope(rawValue: databaseScopeRawValue) ?? .privateDatabase
    }

    var state: CloudFarmBindingState {
        CloudFarmBindingState(rawValue: stateRawValue) ?? .failed
    }
}

@Model
final class CloudZoneState {
    var id: UUID
    var databaseScopeRawValue: String
    var serializedState: Data?
    var lastFetchAt: Date?
    var lastSendAt: Date?
    var lastErrorCode: String?
    var updatedAt: Date

    init(id: UUID = UUID(), databaseScope: CloudDatabaseScope) {
        self.id = id
        self.databaseScopeRawValue = databaseScope.rawValue
        self.updatedAt = .now
    }
}

@Model
final class FarmMembershipBinding {
    var id: UUID
    var serverMembershipID: String
    var farmID: UUID
    var accountID: UUID
    var displayName: String?
    var roleRawValue: String
    var statusRawValue: String
    var shareParticipantRecordName: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        serverMembershipID: String,
        farmID: UUID,
        accountID: UUID,
        displayName: String? = nil,
        role: FarmRole,
        status: FarmMembershipStatus
    ) {
        self.id = id
        self.serverMembershipID = serverMembershipID
        self.farmID = farmID
        self.accountID = accountID
        self.displayName = displayName
        self.roleRawValue = role.rawValue
        self.statusRawValue = status.rawValue
        self.createdAt = .now
        self.updatedAt = .now
    }

    var role: FarmRole { FarmRole(rawValue: roleRawValue) ?? .worker }
    var status: FarmMembershipStatus { FarmMembershipStatus(rawValue: statusRawValue) ?? .revoked }
}

@Model
final class DeviceIdentityRecord {
    var id: UUID
    var accountID: UUID
    var publicKeyX963: Data
    var usesSecureEnclave: Bool
    var isRegistered: Bool
    var createdAt: Date
    var lastRegisteredAt: Date?

    init(id: UUID, accountID: UUID, publicKeyX963: Data, usesSecureEnclave: Bool) {
        self.id = id
        self.accountID = accountID
        self.publicKeyX963 = publicKeyX963
        self.usesSecureEnclave = usesSecureEnclave
        self.isRegistered = false
        self.createdAt = .now
    }
}

@Model
final class CapabilityCertificateRecord {
    var id: UUID
    var serverCertificateID: String
    var accountID: UUID
    var farmID: UUID
    var deviceID: UUID
    var roleRawValue: String
    var capabilitiesJSON: String
    var certificateJWS: String
    var issuedAt: Date
    var expiresAt: Date
    var revokedAt: Date?

    init(
        id: UUID = UUID(),
        serverCertificateID: String,
        accountID: UUID,
        farmID: UUID,
        deviceID: UUID,
        role: FarmRole,
        capabilitiesJSON: String,
        certificateJWS: String,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.serverCertificateID = serverCertificateID
        self.accountID = accountID
        self.farmID = farmID
        self.deviceID = deviceID
        self.roleRawValue = role.rawValue
        self.capabilitiesJSON = capabilitiesJSON
        self.certificateJWS = certificateJWS
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    var isUsable: Bool { revokedAt == nil && expiresAt > .now }
    var remainingTime: TimeInterval { max(0, expiresAt.timeIntervalSinceNow) }
}

@Model
final class RevokedCapabilityCertificateRecord {
    var id: UUID
    var serverCertificateID: String
    var farmID: UUID
    var revokedAt: Date

    init(id: UUID = UUID(), serverCertificateID: String, farmID: UUID, revokedAt: Date) {
        self.id = id
        self.serverCertificateID = serverCertificateID
        self.farmID = farmID
        self.revokedAt = revokedAt
    }
}

@Model
final class SyncConflictRecord {
    var id: UUID
    var farmID: UUID
    var entityID: UUID
    var entityType: String
    var localRevision: Int
    var remoteRevision: Int
    var localPayload: Data
    var remotePayload: Data
    var remoteEnvelopeData: Data?
    var remoteAccountID: UUID?
    var remoteDeviceID: UUID?
    var reasonCode: String
    var statusRawValue: String
    var detectedAt: Date
    var resolvedAt: Date?
    var resolutionNote: String
    var resolutionOperationID: UUID?
    var resolvedByAccountID: UUID?
    var resolvedByDeviceID: UUID?
    var localPayloadDigest: String = ""
    var remotePayloadDigest: String = ""
    var resolutionFailureReason: String?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        entityID: UUID,
        entityType: String,
        localRevision: Int,
        remoteRevision: Int,
        localPayload: Data,
        remotePayload: Data,
        remoteAccountID: UUID? = nil,
        remoteDeviceID: UUID? = nil,
        reasonCode: String,
        status: SyncConflictStatus = .unresolved
    ) {
        self.id = id
        self.farmID = farmID
        self.entityID = entityID
        self.entityType = entityType
        self.localRevision = localRevision
        self.remoteRevision = remoteRevision
        self.localPayload = localPayload
        self.remotePayload = remotePayload
        self.remoteEnvelopeData = nil
        self.remoteAccountID = remoteAccountID
        self.remoteDeviceID = remoteDeviceID
        self.reasonCode = reasonCode
        self.statusRawValue = status.rawValue
        self.detectedAt = .now
        self.resolutionNote = ""
        self.localPayloadDigest = CloudPayloadDigest.hex(for: localPayload)
        self.remotePayloadDigest = CloudPayloadDigest.hex(for: remotePayload)
    }
}

@Model
final class CloudOperationReceipt {
    var id: UUID
    var farmID: UUID
    var operationID: UUID
    var recordName: String
    var serverChangeTag: String?
    var databaseScopeRawValue: String
    /// The exact CloudKit zone that produced this acknowledgement. Optional
    /// keeps existing SwiftData stores eligible for lightweight migration;
    /// a legacy nil value is deliberately not treated as proof for any zone.
    var zoneName: String?
    var zoneOwnerName: String?
    var confirmedAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        operationID: UUID,
        recordName: String,
        serverChangeTag: String?,
        databaseScope: CloudDatabaseScope,
        zoneName: String? = nil,
        zoneOwnerName: String? = nil,
        confirmedAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.operationID = operationID
        self.recordName = recordName
        self.serverChangeTag = serverChangeTag
        self.databaseScopeRawValue = databaseScope.rawValue
        self.zoneName = zoneName
        self.zoneOwnerName = zoneOwnerName
        self.confirmedAt = confirmedAt
    }
}

@Model
final class CloudAssetTransfer {
    var id: UUID
    var farmID: UUID
    var assetID: UUID
    var localRelativePath: String
    var payloadDigest: String
    var byteCount: Int64
    var transferredByteCount: Int64
    var statusRawValue: String
    var attemptCount: Int
    var lastErrorCode: String?
    var updatedAt: Date
    var directionRawValue: String = CloudAssetTransferDirection.upload.rawValue
    var sourceDigest: String = ""
    var remoteRecordName: String?
    var recoveryStatusRawValue: String = CloudAssetBackupStatus.pending.rawValue
    var nextRetryAt: Date?

    init(id: UUID = UUID(), farmID: UUID, assetID: UUID, localRelativePath: String, payloadDigest: String, byteCount: Int64, direction: CloudAssetTransferDirection = .upload, sourceDigest: String = "") {
        self.id = id
        self.farmID = farmID
        self.assetID = assetID
        self.localRelativePath = localRelativePath
        self.payloadDigest = payloadDigest
        self.byteCount = byteCount
        self.transferredByteCount = 0
        self.statusRawValue = CloudAssetTransferStatus.pending.rawValue
        self.attemptCount = 0
        self.updatedAt = .now
        self.directionRawValue = direction.rawValue
        self.sourceDigest = sourceDigest
        self.recoveryStatusRawValue = direction == .recoveryBackup ? CloudAssetBackupStatus.pending.rawValue : CloudAssetBackupStatus.notRequired.rawValue
    }

    var status: CloudAssetTransferStatus { CloudAssetTransferStatus(rawValue: statusRawValue) ?? .failed }
    var direction: CloudAssetTransferDirection { CloudAssetTransferDirection(rawValue: directionRawValue) ?? .upload }
}

@Model
final class FarmMembershipSnapshotRecord {
    var id: UUID
    var farmID: UUID
    var generation: Int
    var issuedAt: Date
    var payload: Data
    var payloadDigest: String
    var signedByAccountID: UUID
    var signedByDeviceID: UUID
    var capabilityCertificate: String
    var signature: Data
    var cloudRecordName: String?
    var validatedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, generation: Int, issuedAt: Date, payload: Data, signedByAccountID: UUID, signedByDeviceID: UUID, capabilityCertificate: String, signature: Data) {
        self.id = id
        self.farmID = farmID
        self.generation = generation
        self.issuedAt = issuedAt
        self.payload = payload
        self.payloadDigest = CloudPayloadDigest.hex(for: payload)
        self.signedByAccountID = signedByAccountID
        self.signedByDeviceID = signedByDeviceID
        self.capabilityCertificate = capabilityCertificate
        self.signature = signature
    }
}

@Model
final class FarmCheckpointRecord {
    var id: UUID
    var farmID: UUID
    var reasonRawValue: String
    var operationWatermark: Date
    var manifestDigest: String
    var encryptedRelativePath: String
    var byteCount: Int64
    var entityCount: Int
    var assetCount: Int
    var securityGeneration: Int
    var cloudRecordName: String?
    var createdAt: Date
    var verifiedAt: Date?
    var restoredAt: Date?

    init(id: UUID = UUID(), farmID: UUID, reasonRawValue: String, operationWatermark: Date, manifestDigest: String, encryptedRelativePath: String, byteCount: Int64, entityCount: Int, assetCount: Int, securityGeneration: Int) {
        self.id = id
        self.farmID = farmID
        self.reasonRawValue = reasonRawValue
        self.operationWatermark = operationWatermark
        self.manifestDigest = manifestDigest
        self.encryptedRelativePath = encryptedRelativePath
        self.byteCount = byteCount
        self.entityCount = entityCount
        self.assetCount = assetCount
        self.securityGeneration = securityGeneration
        self.createdAt = .now
    }
}

@Model
final class FarmRecoveryAssetRecord {
    var id: UUID
    var farmID: UUID
    var assetID: UUID
    var payloadDigest: String
    var encryptedRelativePath: String
    var byteCount: Int64
    var cloudRecordName: String?
    var createdAt: Date
    var verifiedAt: Date?
    var eligibleForDeletionAt: Date?

    init(id: UUID = UUID(), farmID: UUID, assetID: UUID, payloadDigest: String, encryptedRelativePath: String, byteCount: Int64) {
        self.id = id
        self.farmID = farmID
        self.assetID = assetID
        self.payloadDigest = payloadDigest
        self.encryptedRelativePath = encryptedRelativePath
        self.byteCount = byteCount
        self.createdAt = .now
    }
}

@Model
final class SecurityIncidentRecord {
    var id: UUID
    var farmID: UUID?
    var incidentType: String
    var recordName: String?
    var accountID: UUID?
    var deviceID: UUID?
    var detail: String
    var rawPayload: Data?
    var detectedAt: Date
    var reviewedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID?,
        incidentType: String,
        recordName: String? = nil,
        accountID: UUID? = nil,
        deviceID: UUID? = nil,
        detail: String,
        rawPayload: Data? = nil
    ) {
        self.id = id
        self.farmID = farmID
        self.incidentType = incidentType
        self.recordName = recordName
        self.accountID = accountID
        self.deviceID = deviceID
        self.detail = detail
        self.rawPayload = rawPayload
        self.detectedAt = .now
    }
}

enum CloudZoneName {
    static func forFarm(_ farmID: UUID) -> String {
        "Farm_\(farmID.uuidString.lowercased())"
    }

    static func farmID(from zoneName: String) -> UUID? {
        guard zoneName.hasPrefix("Farm_") else { return nil }
        return UUID(uuidString: String(zoneName.dropFirst(5)))
    }

    static func recovery(for farmID: UUID) -> String {
        "FarmRecovery_\(farmID.uuidString.lowercased())"
    }
}
