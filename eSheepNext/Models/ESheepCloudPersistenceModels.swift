import Foundation
import SwiftData

enum ESheepCloudFarmActivityState: String, Codable, Sendable {
    case preparing
    case active
    case readOnly
    case integrityHold
    case accessRevoked
}

enum ESheepCloudIntegrityState: String, Codable, Sendable {
    case notChecked
    case checking
    case passed
    case failed
}

enum ESheepCloudIntentLifecycle: String, Codable, Sendable, CaseIterable {
    case waitingForNetwork
    case waitingForDependency
    case ready
    case sending
    case awaitingResult
    case accepted
    case needsConfirmation
    case rejected
    case supersededLocally

    var isTerminal: Bool {
        switch self {
        case .accepted, .rejected, .supersededLocally:
            true
        case .waitingForNetwork, .waitingForDependency, .ready, .sending,
             .awaitingResult, .needsConfirmation:
            false
        }
    }
}

enum ESheepCloudAttentionState: String, Codable, Sendable {
    case open
    case resolving
    case resolved
    case obsolete
}

enum ESheepCloudAssetTransferState: String, Codable, Sendable {
    case localOnly
    case queued
    case transferring
    case verified
    case failed
    case unavailable
    case recycleBin
    case deleted
}

enum ESheepCloudInitialSyncState: String, Codable, Sendable, CaseIterable {
    case connecting
    case receiving
    case verifying
    case applyingRecentChanges
    case buildingIndexes
    case readyToActivate
    case active
    case paused
    case failed
}

enum ESheepCloudMigrationPhase: String, Codable, Sendable {
    case notStarted
    case backupVerified
    case shadowConverted
    case parityVerified
    case readyToCutOver
    case v1WriteClosed
    case v2Active
    case forwardRepairRequired
}

/// One row per farm and active local store generation. This is the local
/// authority marker for V2; it never attempts to mirror a provider-specific
/// cursor or an entity-wide client revision.
@Model
final class ESheepCloudFarmState {
    var id: UUID
    var farmID: UUID
    var farmGeneration: Int
    var protocolVersion: Int
    var schemaVersion: Int
    var cloudEventHead: Int64
    var lastAppliedEventSequence: Int64
    var lastVerifiedEventSequence: Int64
    var activityStateRawValue: String
    var integrityStateRawValue: String
    var projectionDigest: String
    var lastIntegrityCheckAt: Date?
    var lastSafeSaveAt: Date?
    var integrityFailureTraceID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        farmGeneration: Int,
        protocolVersion: Int = 2,
        schemaVersion: Int = 12,
        activityState: ESheepCloudFarmActivityState = .preparing
    ) {
        self.id = id
        self.farmID = farmID
        self.farmGeneration = max(0, farmGeneration)
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.cloudEventHead = 0
        self.lastAppliedEventSequence = 0
        self.lastVerifiedEventSequence = 0
        self.activityStateRawValue = activityState.rawValue
        self.integrityStateRawValue = ESheepCloudIntegrityState.notChecked.rawValue
        self.projectionDigest = String(repeating: "0", count: 64)
        self.createdAt = .now
        self.updatedAt = .now
    }

    var activityState: ESheepCloudFarmActivityState {
        get { ESheepCloudFarmActivityState(rawValue: activityStateRawValue) ?? .integrityHold }
        set { activityStateRawValue = newValue.rawValue; updatedAt = .now }
    }

    var integrityState: ESheepCloudIntegrityState {
        get { ESheepCloudIntegrityState(rawValue: integrityStateRawValue) ?? .failed }
        set { integrityStateRawValue = newValue.rawValue; updatedAt = .now }
    }
}

/// Canonical local view of one independently mergeable business stream.
/// `canonicalState` and field-version entries use versioned domain codecs;
/// unknown schemas fail closed before this row is changed.
@Model
final class ESheepCloudStreamState {
    var id: UUID
    var farmID: UUID
    var farmGeneration: Int
    var streamType: String
    var streamID: UUID
    var streamVersion: Int64
    var fieldVersionsData: Data
    var canonicalStateData: Data
    var contentDigest: String
    var lastEventSequence: Int64
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        farmGeneration: Int,
        streamType: String,
        streamID: UUID,
        streamVersion: Int64 = 0,
        fieldVersionsData: Data = Data("[]".utf8),
        canonicalStateData: Data = Data("{}".utf8),
        contentDigest: String = "",
        lastEventSequence: Int64 = 0
    ) {
        self.id = id
        self.farmID = farmID
        self.farmGeneration = max(0, farmGeneration)
        self.streamType = streamType
        self.streamID = streamID
        self.streamVersion = max(0, streamVersion)
        self.fieldVersionsData = fieldVersionsData
        self.canonicalStateData = canonicalStateData
        self.contentDigest = contentDigest
        self.lastEventSequence = max(0, lastEventSequence)
        self.createdAt = .now
        self.updatedAt = .now
    }
}

/// Immutable command bytes and their lifecycle. The command body, observed
/// field versions, dependencies and digest are frozen at construction time;
/// retries update only transport/lifecycle columns.
@Model
final class ESheepCloudPendingIntent {
    var id: UUID
    var farmID: UUID
    var farmGeneration: Int
    var accountID: UUID
    var deviceID: UUID
    var deviceSequence: Int64
    var sourceRequestID: UUID
    var bundleID: UUID?
    var commandKind: String
    var commandEnvelopeData: Data
    var commandDigest: String
    var affectedStreamsData: Data
    var affectedFieldsData: Data
    var prerequisiteCommandIDsData: Data
    var requiredAssetIDsData: Data
    var lifecycleRawValue: String
    var createdAt: Date
    var occurredAt: Date
    var firstAttemptAt: Date?
    var lastAttemptAt: Date?
    var nextRetryAt: Date?
    var attemptCount: Int
    var lastTransportMessage: String?
    var acceptedEventSequence: Int64?
    var attentionItemID: UUID?
    var serverResultData: Data?
    var updatedAt: Date

    init(
        commandID: UUID,
        farmID: UUID,
        farmGeneration: Int,
        accountID: UUID,
        deviceID: UUID,
        deviceSequence: Int64,
        sourceRequestID: UUID,
        bundleID: UUID? = nil,
        commandKind: String,
        commandEnvelopeData: Data,
        commandDigest: String,
        affectedStreamsData: Data,
        affectedFieldsData: Data,
        prerequisiteCommandIDsData: Data,
        requiredAssetIDsData: Data,
        lifecycle: ESheepCloudIntentLifecycle,
        createdAt: Date,
        occurredAt: Date
    ) {
        self.id = commandID
        self.farmID = farmID
        self.farmGeneration = max(0, farmGeneration)
        self.accountID = accountID
        self.deviceID = deviceID
        self.deviceSequence = max(1, deviceSequence)
        self.sourceRequestID = sourceRequestID
        self.bundleID = bundleID
        self.commandKind = commandKind
        self.commandEnvelopeData = commandEnvelopeData
        self.commandDigest = commandDigest
        self.affectedStreamsData = affectedStreamsData
        self.affectedFieldsData = affectedFieldsData
        self.prerequisiteCommandIDsData = prerequisiteCommandIDsData
        self.requiredAssetIDsData = requiredAssetIDsData
        self.lifecycleRawValue = lifecycle.rawValue
        self.createdAt = createdAt
        self.occurredAt = occurredAt
        self.attemptCount = 0
        self.updatedAt = createdAt
    }

    var lifecycle: ESheepCloudIntentLifecycle {
        get { ESheepCloudIntentLifecycle(rawValue: lifecycleRawValue) ?? .rejected }
        set { lifecycleRawValue = newValue.rawValue; updatedAt = .now }
    }
}

@Model
final class ESheepCloudEventReceipt {
    var id: UUID
    var farmID: UUID
    var farmGeneration: Int
    var eventSequence: Int64
    var commandID: UUID
    var eventDigest: String
    var appliedProjectionDigest: String
    var appliedAt: Date

    init(
        eventID: UUID,
        farmID: UUID,
        farmGeneration: Int,
        eventSequence: Int64,
        commandID: UUID,
        eventDigest: String,
        appliedProjectionDigest: String,
        appliedAt: Date = .now
    ) {
        self.id = eventID
        self.farmID = farmID
        self.farmGeneration = max(0, farmGeneration)
        self.eventSequence = max(1, eventSequence)
        self.commandID = commandID
        self.eventDigest = eventDigest
        self.appliedProjectionDigest = appliedProjectionDigest
        self.appliedAt = appliedAt
    }
}

@Model
final class ESheepCloudAttentionItem {
    var id: UUID
    var farmID: UUID
    var farmGeneration: Int
    var commandID: UUID
    var streamType: String
    var streamID: UUID
    var recordType: String
    var recordID: UUID
    var recordDisplayName: String
    var fieldKey: String
    var fieldDisplayName: String
    var deviceValueData: Data
    var cloudValueData: Data
    var baseValueDigest: String
    var deviceAccountID: UUID
    var deviceAccountDisplayName: String?
    var deviceID: UUID
    var deviceDisplayName: String?
    var deviceOccurredAt: Date
    var cloudAccountID: UUID?
    var cloudAccountDisplayName: String?
    var cloudDeviceID: UUID?
    var cloudDeviceDisplayName: String?
    var cloudReceivedAt: Date?
    var explanation: String
    var dependentCommandIDsData: Data
    var stateRawValue: String
    var resolutionRawValue: String?
    var resolutionCommandID: UUID?
    var resolutionExpectedCloudValueDigest: String?
    var resolverAccountID: UUID?
    var resolverDeviceID: UUID?
    var resolutionDeviceSequence: Int64?
    var resolutionAttemptCount: Int
    var resolutionAwaitingStatus: Bool
    var resolutionNextRetryAt: Date?
    var resolutionLastErrorMessage: String?
    var resolutionServerResultData: Data?
    var resolutionStartedAt: Date?
    var resolutionEventID: UUID?
    var createdAt: Date
    var resolvedAt: Date?
    var updatedAt: Date

    init(
        id: UUID,
        farmID: UUID,
        farmGeneration: Int,
        commandID: UUID,
        streamType: String,
        streamID: UUID,
        recordType: String,
        recordID: UUID,
        recordDisplayName: String,
        fieldKey: String,
        fieldDisplayName: String,
        deviceValueData: Data,
        cloudValueData: Data,
        baseValueDigest: String,
        deviceAccountID: UUID,
        deviceAccountDisplayName: String? = nil,
        deviceID: UUID,
        deviceDisplayName: String? = nil,
        deviceOccurredAt: Date,
        cloudAccountID: UUID? = nil,
        cloudAccountDisplayName: String? = nil,
        cloudDeviceID: UUID? = nil,
        cloudDeviceDisplayName: String? = nil,
        cloudReceivedAt: Date? = nil,
        explanation: String,
        dependentCommandIDsData: Data = Data("[]".utf8),
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.farmGeneration = max(0, farmGeneration)
        self.commandID = commandID
        self.streamType = streamType
        self.streamID = streamID
        self.recordType = recordType
        self.recordID = recordID
        self.recordDisplayName = recordDisplayName
        self.fieldKey = fieldKey
        self.fieldDisplayName = fieldDisplayName
        self.deviceValueData = deviceValueData
        self.cloudValueData = cloudValueData
        self.baseValueDigest = baseValueDigest
        self.deviceAccountID = deviceAccountID
        self.deviceAccountDisplayName = deviceAccountDisplayName
        self.deviceID = deviceID
        self.deviceDisplayName = deviceDisplayName
        self.deviceOccurredAt = deviceOccurredAt
        self.cloudAccountID = cloudAccountID
        self.cloudAccountDisplayName = cloudAccountDisplayName
        self.cloudDeviceID = cloudDeviceID
        self.cloudDeviceDisplayName = cloudDeviceDisplayName
        self.cloudReceivedAt = cloudReceivedAt
        self.explanation = explanation
        self.dependentCommandIDsData = dependentCommandIDsData
        self.stateRawValue = ESheepCloudAttentionState.open.rawValue
        self.resolutionAttemptCount = 0
        self.resolutionAwaitingStatus = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var state: ESheepCloudAttentionState {
        get { ESheepCloudAttentionState(rawValue: stateRawValue) ?? .open }
        set { stateRawValue = newValue.rawValue; updatedAt = .now }
    }
}

@Model
final class ESheepCloudAssetState {
    var id: UUID
    var farmID: UUID
    var farmGeneration: Int
    var sheepID: UUID?
    var contentSHA256: String
    var metadataDigest: String
    var metadataData: Data
    /// The logical asset identity is the optimized original digest above.
    /// Every encoded variant has its own digest because resizing/re-encoding
    /// necessarily changes the bytes.
    var thumbnailSHA256: String?
    var avatarSHA256: String?
    var originalSHA256: String?
    var thumbnailRelativePath: String?
    var avatarRelativePath: String?
    var originalRelativePath: String?
    var thumbnailStateRawValue: String
    var avatarStateRawValue: String
    var originalStateRawValue: String
    var thumbnailRemoteObjectKey: String?
    var avatarRemoteObjectKey: String?
    var originalRemoteObjectKey: String?
    var thumbnailByteCount: Int64
    var avatarByteCount: Int64
    var originalByteCount: Int64
    var thumbnailTransferredByteCount: Int64
    var avatarTransferredByteCount: Int64
    var originalTransferredByteCount: Int64
    /// TUS upload locations are durable resumable-session identifiers. They
    /// are never treated as object authority and may be discarded on expiry.
    var thumbnailUploadSessionURL: String?
    var avatarUploadSessionURL: String?
    var originalUploadSessionURL: String?
    var thumbnailUploadSessionExpiresAt: Date?
    var avatarUploadSessionExpiresAt: Date?
    var originalUploadSessionExpiresAt: Date?
    var verifiedRemoteByteCount: Int64
    var uploadedByteCount: Int64
    var downloadedByteCount: Int64
    var recycleExpiresAt: Date?
    var lastVerifiedAt: Date?
    var lastErrorTraceID: String?
    var transferAttemptCount: Int
    var nextTransferRetryAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        assetID: UUID,
        farmID: UUID,
        farmGeneration: Int,
        sheepID: UUID?,
        contentSHA256: String,
        metadataDigest: String,
        originalByteCount: Int64 = 0
    ) {
        self.id = assetID
        self.farmID = farmID
        self.farmGeneration = max(0, farmGeneration)
        self.sheepID = sheepID
        self.contentSHA256 = contentSHA256
        self.metadataDigest = metadataDigest
        self.metadataData = Data("{}".utf8)
        self.originalSHA256 = contentSHA256
        self.thumbnailStateRawValue = ESheepCloudAssetTransferState.localOnly.rawValue
        self.avatarStateRawValue = ESheepCloudAssetTransferState.localOnly.rawValue
        self.originalStateRawValue = ESheepCloudAssetTransferState.localOnly.rawValue
        self.thumbnailByteCount = 0
        self.avatarByteCount = 0
        self.originalByteCount = max(0, originalByteCount)
        self.thumbnailTransferredByteCount = 0
        self.avatarTransferredByteCount = 0
        self.originalTransferredByteCount = 0
        self.verifiedRemoteByteCount = 0
        self.uploadedByteCount = 0
        self.downloadedByteCount = 0
        self.transferAttemptCount = 0
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@Model
final class ESheepCloudInitialSyncSession {
    var id: UUID
    var farmID: UUID
    var farmGeneration: Int
    var stagingGeneration: Int
    var snapshotID: UUID?
    var boundaryEventSequence: Int64
    var targetEventHead: Int64
    var manifestData: Data?
    var manifestDigest: String
    var verifiedChunkIndexesData: Data
    var receivedByteCount: Int64
    var expectedByteCount: Int64
    var stateRawValue: String
    var stagingStoreRelativePath: String
    var retryCount: Int
    var lastErrorTraceID: String?
    var startedAt: Date
    var updatedAt: Date
    var activatedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        farmGeneration: Int,
        stagingGeneration: Int,
        stagingStoreRelativePath: String
    ) {
        self.id = id
        self.farmID = farmID
        self.farmGeneration = max(0, farmGeneration)
        self.stagingGeneration = max(1, stagingGeneration)
        self.boundaryEventSequence = 0
        self.targetEventHead = 0
        self.manifestDigest = ""
        self.verifiedChunkIndexesData = Data("[]".utf8)
        self.receivedByteCount = 0
        self.expectedByteCount = 0
        self.stateRawValue = ESheepCloudInitialSyncState.connecting.rawValue
        self.stagingStoreRelativePath = stagingStoreRelativePath
        self.retryCount = 0
        self.startedAt = .now
        self.updatedAt = .now
    }

    var state: ESheepCloudInitialSyncState {
        get { ESheepCloudInitialSyncState(rawValue: stateRawValue) ?? .failed }
        set { stateRawValue = newValue.rawValue; updatedAt = .now }
    }
}

@Model
final class ESheepCloudMigrationState {
    var id: UUID
    var farmID: UUID
    var sourceFarmGeneration: Int
    var targetFarmGeneration: Int
    var phaseRawValue: String
    var sourceBackupDirectoryRelativePath: String
    var sourceStoreQuickCheck: String
    var sourceBackupManifestDigest: String
    var sourceManifestDigest: String
    var targetManifestDigest: String
    var targetProjectionDigest: String
    var mappingData: Data
    var parityReportData: Data?
    var parityDigest: String
    var v1FinalEventBoundary: Int64?
    var firstAcceptedV2CommandID: UUID?
    var irreversibleCutoverAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        sourceFarmGeneration: Int,
        targetFarmGeneration: Int,
        sourceBackupDirectoryRelativePath: String
    ) {
        self.id = id
        self.farmID = farmID
        self.sourceFarmGeneration = max(0, sourceFarmGeneration)
        self.targetFarmGeneration = max(sourceFarmGeneration + 1, targetFarmGeneration)
        self.phaseRawValue = ESheepCloudMigrationPhase.notStarted.rawValue
        self.sourceBackupDirectoryRelativePath = sourceBackupDirectoryRelativePath
        self.sourceStoreQuickCheck = ""
        self.sourceBackupManifestDigest = ""
        self.sourceManifestDigest = ""
        self.targetManifestDigest = ""
        self.targetProjectionDigest = ""
        self.mappingData = Data("{}".utf8)
        self.parityDigest = ""
        self.createdAt = .now
        self.updatedAt = .now
    }

    var phase: ESheepCloudMigrationPhase {
        get { ESheepCloudMigrationPhase(rawValue: phaseRawValue) ?? .forwardRepairRequired }
        set { phaseRawValue = newValue.rawValue; updatedAt = .now }
    }
}
