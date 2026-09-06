import CryptoKit
import Foundation
import Observation
import SQLite3
import SwiftData

struct ESheepCloudFarmSeedV2: Sendable, Equatable {
    let id: UUID
    let ownerAccountID: UUID
    let memberAccountID: UUID
    let name: String
    let role: FarmRole
    let membershipStatusRawValue: String
    let createdAt: Date
    let updatedAt: Date
    let locationDisplayName: String?
    let latitude: Double?
    let longitude: Double?
    let coordinateReferenceSystem: String
    let addressSnapshot: String?
    let timeZoneIdentifier: String
    let locationSourceRawValue: String?
    let horizontalAccuracyMeters: Double?
    let locationUpdatedAt: Date?

    init(
        profile: ESheepCloudFarmProfileV2,
        memberAccountID: UUID,
        memberRole: FarmRole,
        membershipStatus: String
    ) {
        id = profile.farmID
        ownerAccountID = profile.ownerAccountID
        self.memberAccountID = memberAccountID
        name = profile.name
        role = memberRole
        membershipStatusRawValue = membershipStatus
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
        locationDisplayName = profile.locationDisplayName
        latitude = profile.latitude
        longitude = profile.longitude
        coordinateReferenceSystem = profile.coordinateReferenceSystem
        addressSnapshot = profile.addressSnapshot
        timeZoneIdentifier = profile.timeZoneIdentifier
        locationSourceRawValue = profile.locationSourceRawValue
        horizontalAccuracyMeters = profile.horizontalAccuracyMeters
        locationUpdatedAt = profile.locationUpdatedAt
    }

    @MainActor
    init(farm: FarmRecord) {
        id = farm.id
        ownerAccountID = farm.ownerAccountID
        memberAccountID = farm.ownerAccountID
        name = farm.name
        role = farm.role
        membershipStatusRawValue = farm.membershipStatusRawValue
        createdAt = farm.createdAt
        updatedAt = farm.updatedAt
        locationDisplayName = farm.locationDisplayName
        latitude = farm.latitude
        longitude = farm.longitude
        coordinateReferenceSystem = farm.coordinateReferenceSystem
        addressSnapshot = farm.addressSnapshot
        timeZoneIdentifier = farm.timeZoneIdentifier
        locationSourceRawValue = farm.locationSourceRawValue
        horizontalAccuracyMeters = farm.horizontalAccuracyMeters
        locationUpdatedAt = farm.locationUpdatedAt
    }
}

enum ESheepCloudInitialSyncError: LocalizedError {
    case manifestMismatch
    case insufficientSpace(requiredBytes: Int64)
    case chunkMissing(Int)
    case chunkDigestMismatch(Int)
    case countMismatch(String)
    case streamMismatch(String)
    case eventBoundaryMismatch
    /// The persisted verifier prefix (receipts, event sequence, or digest)
    /// disagrees with the immutable snapshot prefix. This is distinct from a
    /// business projection error raised while applying a new event: only this
    /// case is allowed to quarantine the existing verification store.
    case existingVerificationCheckpointMismatch
    case associationMismatch(String)
    case verificationStoreIntegrity(String)
    case existingFarmRequiresMigration
    case farmGenerationChanged
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .manifestMismatch, .chunkDigestMismatch, .streamMismatch,
             .eventBoundaryMismatch, .existingVerificationCheckpointMismatch,
             .countMismatch, .associationMismatch,
             .verificationStoreIntegrity:
            "部分牧场资料没有接收完整。"
        case .insufficientSpace(let bytes):
            "本机空间不足，至少还需要 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))。"
        case .chunkMissing:
            "部分牧场资料尚未接收完成。"
        case .existingFarmRequiresMigration:
            "这座牧场已有本机资料，需要先完成安全迁移，不能按新安装方式覆盖。"
        case .farmGenerationChanged:
            "牧场云端身份已经更新，需要重新接收完整资料。"
        case .accountMismatch:
            "当前登录账号与这次牧场资料接收不一致，已停止继续写入。"
        }
    }
}

struct ESheepCloudInitialSyncReport: Sendable, Equatable {
    let snapshotID: UUID
    let farmGeneration: Int
    let appliedEventHead: Int64
    let streamCount: Int
    let assetCount: Int
    let receivedByteCount: Int64
}

/// Downloads immutable chunks off the main actor, verifies an isolated V13
/// store, catches up from the snapshot boundary, then commits the same
/// verified event sequence to the active store in one ModelContext save.
actor ESheepCloudInitialSyncCoordinator {
    private let farmID: UUID
    private let checkpointContainer: ModelContainer
    private let gateway: any ESheepCloudGateway
    private let localStore: ESheepCloudInitialSyncLocalStore
    private let fileManager: FileManager
    private let applicationSupportURL: URL

    init(
        farmID: UUID,
        container: ModelContainer,
        gateway: any ESheepCloudGateway,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) {
        self.farmID = farmID
        self.checkpointContainer = container
        self.gateway = gateway
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.localStore = ESheepCloudInitialSyncLocalStore(
            container: container,
            fileManager: self.fileManager,
            applicationSupportURL: self.applicationSupportURL
        )
    }

    func prepareNewInstallation(
        expectedFarmGeneration: Int? = nil,
        expectedAccountID: UUID? = nil
    ) async throws -> ESheepCloudInitialSyncReport {
        try await prepareInstallation(expectedFarmGeneration: expectedFarmGeneration,
            expectedAccountID: expectedAccountID, preferCheckpoint: true)
    }

    private func resumableCheckpointID(accountID: UUID, generation: Int) throws -> UUID? {
        let context = ModelContext(checkpointContainer)
        let id = farmID
        let rows = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>(predicate: #Predicate {
            $0.farmID == id && $0.accountID == accountID && $0.farmGeneration == generation
        }))
        return rows.filter { $0.state != .active && $0.stagingStoreRelativePath.hasPrefix("ESheepCloud/Checkpoints/") }
            .sorted { ($0.lastProgressAt ?? $0.startedAt) > ($1.lastProgressAt ?? $1.startedAt) }.first?.snapshotID
    }

    private func prepareLegacyInstallation(expectedFarmGeneration: Int?, expectedAccountID: UUID?) async throws -> ESheepCloudInitialSyncReport {
        try await prepareInstallation(expectedFarmGeneration: expectedFarmGeneration,
            expectedAccountID: expectedAccountID, preferCheckpoint: false)
    }

    private func prepareInstallation(expectedFarmGeneration: Int?, expectedAccountID: UUID?, preferCheckpoint: Bool) async throws -> ESheepCloudInitialSyncReport {
        var sessionID: UUID?
        var verificationStoreTrusted = false
        do {
            let ticket = try await gateway.openInitialSync(
                farmID: farmID,
                farmGeneration: expectedFarmGeneration
            )
            let manifest = ticket.manifest
            let seed = ESheepCloudFarmSeedV2(
                profile: ticket.farmProfile,
                memberAccountID: ticket.memberAccountID,
                memberRole: ticket.memberRole,
                membershipStatus: ticket.membershipStatus
            )
            let recordTypes = manifest.recordCounts.map(\.recordType)
            let expectedRecordTypes: Set<String> = ["streams", "events", "assets"]
            guard manifest.farmID == farmID,
                  manifest.farmGeneration >= 0,
                  ticket.farmProfile.farmID == farmID,
                  ticket.membershipStatus == "active",
                  ticket.expiresAt > .now,
                  !ticket.farmProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  TimeZone(identifier: ticket.farmProfile.timeZoneIdentifier) != nil,
                  ticket.farmProfile.coordinateReferenceSystem == "wgs84",
                  manifest.farmProfileDigest.isSHA256Hex,
                  manifest.relationshipDigest.isSHA256Hex,
                  manifest.fieldVersionDigest.isSHA256Hex,
                  manifest.schemaVersion == ESheepCloudProtocolV2.schemaVersion,
                  manifest.boundaryEventSequence >= 0,
                  manifest.boundaryEventSequence == manifest.eventHeadAtCreation,
                  manifest.totalDigest.isSHA256Hex,
                  Set(recordTypes) == expectedRecordTypes,
                  Set(recordTypes).count == recordTypes.count,
                  manifest.recordCounts.allSatisfy({ $0.count >= 0 }),
                  Set(manifest.chunks.map(\.index)).count == manifest.chunks.count,
                  manifest.chunks.map(\.index).sorted() == Array(0..<manifest.chunks.count),
                  manifest.chunks.allSatisfy({
                      $0.byteCount >= 0 && $0.contentSHA256.isSHA256Hex
                  }),
                  Set(manifest.assets.map(\.assetID)).count == manifest.assets.count,
                  manifest.assets.count == manifest.recordCounts.first(where: {
                      $0.recordType == "assets"
                  })?.count,
                  manifest.assets.allSatisfy({ asset in
                      asset.contentSHA256.isSHA256Hex &&
                          asset.originalSHA256.isSHA256Hex &&
                          (asset.thumbnailSHA256?.isSHA256Hex ?? true) &&
                          (asset.avatarSHA256?.isSHA256Hex ?? true) &&
                          asset.thumbnailByteCount >= 0 &&
                          asset.avatarByteCount >= 0 &&
                          asset.originalByteCount >= 0
                  }),
                  manifest.businessHistoryStartedAt == nil ||
                      manifest.businessHistoryEndedAt == nil ||
                      manifest.businessHistoryStartedAt! <= manifest.businessHistoryEndedAt! else {
                throw ESheepCloudInitialSyncError.manifestMismatch
            }
            if let expectedFarmGeneration,
               manifest.farmGeneration != expectedFarmGeneration {
                throw ESheepCloudInitialSyncError.farmGenerationChanged
            }
            if let expectedAccountID,
               ticket.memberAccountID != expectedAccountID {
                throw ESheepCloudInitialSyncError.accountMismatch
            }

            // A stale retry can arrive after activation. Current admission was
            // checked above; return the durable result without importing again.
            let completedContext = ModelContext(checkpointContainer)
            completedContext.autosaveEnabled = false
            if let completed = try ESheepCloudCompletedCheckpointReceive.reconcile(
                farmID: farmID, generation: manifest.farmGeneration,
                accountID: seed.memberAccountID, context: completedContext) {
                try completedContext.save()
                return completed
            }

            if preferCheckpoint, let transport = gateway as? any ESheepCloudCheckpointGateway {
                let checkpointTicket: ESheepCloudCheckpointTicket
                do {
                    checkpointTicket = try await transport.openCheckpoint(farmID: farmID,
                        farmGeneration: manifest.farmGeneration, checkpointID: try resumableCheckpointID(accountID: seed.memberAccountID, generation: manifest.farmGeneration))
                } catch ESheepCloudCheckpointError.unsupportedVersion {
                    // An explicitly unsupported format may use the legacy
                    // protocol. Integrity/authorization errors never do.
                    return try await prepareLegacyInstallation(expectedFarmGeneration: expectedFarmGeneration,
                                                               expectedAccountID: expectedAccountID)
                }
                if checkpointTicket.manifest != nil {
                    return try await ESheepCloudCheckpointReceiver(container: checkpointContainer,
                        support: applicationSupportURL, gateway: gateway, transport: transport)
                        .receive(ticket: checkpointTicket, seed: seed)
                }
            }

            let session = try localStore.beginOrResume(
                manifest: manifest,
                stagingStoreRelativePath: relativeStagingStorePath(
                    farmID: farmID,
                    snapshotID: manifest.snapshotID,
                    accountID: seed.memberAccountID
                ),
                accountID: seed.memberAccountID
            )
            sessionID = session.id
            let stagingRoot = applicationSupportURL.appending(
                path: session.stagingDirectoryRelativePath,
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true
            )
            try ensureAvailableCapacity(for: manifest)
            try await downloadChunks(
                manifest: manifest,
                sessionID: session.id,
                stagingRoot: stagingRoot
            )
            try verifyWholeSnapshot(manifest: manifest, stagingRoot: stagingRoot)

            try localStore.updateProjectionProgress(
                sessionID: session.id,
                state: .verifying,
                activationProjectionEventSequence: 0
            )
            let verificationURL = stagingRoot.appending(path: "verification.store")
            var recentEvents: [ESheepCloudEventEnvelopeV2] = []
            let verifiedSummary: ESheepCloudVerifiedProjectionSummary
            // Keep the verification container's lifetime bounded to this
            // scope.  A SwiftData container keeps SQLite WAL/SHM handles
            // alive; releasing it before the activation copy or a failed
            // staging cleanup prevents deleting an open store file.
            do {
                let previousStateAllowsResume = [
                    ESheepCloudInitialSyncState.verifying,
                    .applyingRecentChanges,
                    .buildingIndexes,
                    .readyToActivate,
                    .activating,
                    .failed,
                    .paused,
                ].contains(session.previousState)
                let hasExistingVerificationFiles = LocalStoreRecoveryService
                    .relatedStoreURLs(for: verificationURL)
                    .contains { fileManager.fileExists(atPath: $0.path) }
                if previousStateAllowsResume {
                    try validateExistingVerificationStore(at: verificationURL)
                }
                // A resumable session row may outlive a verifier directory
                // (for example after an interrupted restore or manual file
                // recovery). Rebuild from the immutable chunks in that case;
                // never compare a stale V13 checkpoint with a newly-created
                // empty store and strand the session in `.failed` forever.
                let canResumeProjection = previousStateAllowsResume &&
                    hasExistingVerificationFiles
                if previousStateAllowsResume && !hasExistingVerificationFiles &&
                    (session.verifiedProjectionEventSequence > 0 ||
                        session.activationProjectionEventSequence > 0) {
                    try localStore.updateProjectionProgress(
                        sessionID: session.id,
                        state: .verifying,
                        verifiedProjectionEventSequence: 0,
                        activationProjectionEventSequence: 0
                    )
                }
                let projection = try ESheepCloudStagingProjection(
                    seed: seed,
                    farmGeneration: manifest.farmGeneration,
                    storeURL: verificationURL,
                    resumeExistingStore: canResumeProjection
                )
                let existingProjectionSequence = canResumeProjection
                    ? try projection.lastAppliedEventSequence()
                    : 0
                let existingProjectionDigest = canResumeProjection
                    ? try projection.currentProjectionDigest()
                    : nil
                // A durable V13 checkpoint and the verifier's farm state must
                // describe the same prefix. A migrated Build 16 session has
                // zero in the new field by design, so enforce this invariant
                // only once a V13 checkpoint has actually been persisted.
                if canResumeProjection,
                   session.verifiedProjectionEventSequence > 0,
                   session.verifiedProjectionEventSequence != existingProjectionSequence {
                    throw ESheepCloudInitialSyncError.existingVerificationCheckpointMismatch
                }
                if canResumeProjection {
                    // Build 16 did not persist the V13 projection sequence.
                    // Recover the durable SQLite checkpoint before replaying
                    // the next record so a later business error is reported
                    // at the real prefix (for example 2,546), never as 0.
                    try localStore.updateProjectionProgress(
                        sessionID: session.id,
                        state: .verifying,
                        verifiedProjectionEventSequence: existingProjectionSequence,
                        activationProjectionEventSequence: 0
                    )
                }
                let resumeWithoutSnapshotReplay = canResumeProjection &&
                    existingProjectionSequence >= manifest.boundaryEventSequence
                for descriptor in manifest.chunks.sorted(by: { $0.index < $1.index }) {
                    try Task.checkCancellation()
                    let records = try decodeChunk(
                        descriptor: descriptor,
                        manifest: manifest,
                        stagingRoot: stagingRoot
                    )
                    if resumeWithoutSnapshotReplay {
                        // A ready-to-activate/activating verifier already has
                        // the snapshot prefix applied. Re-read immutable
                        // records only to rebuild expected stream/asset
                        // metadata and validate receipts; never run the
                        // business reducer over the same prefix again.
                        try projection.inspectSnapshotRecords(
                            records,
                            validatingReceiptsThrough: manifest.boundaryEventSequence
                        )
                    } else {
                        try projection.applySnapshotRecords(
                            records,
                            skippingEventsThrough: existingProjectionSequence
                        )
                    }
                    try localStore.updateProjectionProgress(
                        sessionID: session.id,
                        state: .verifying,
                        verifiedProjectionEventSequence: try projection.lastAppliedEventSequence()
                    )
                }
                if resumeWithoutSnapshotReplay {
                    try projection.verifySnapshotBoundary(
                        manifest,
                        stateMustBeAtBoundary: existingProjectionSequence ==
                            manifest.boundaryEventSequence
                    )
                } else {
                    if canResumeProjection {
                        // The replay has advanced the farm state beyond a
                        // partial checkpoint by this point. Validate the
                        // checkpoint against the digest captured before
                        // replay, rather than incorrectly requiring the
                        // post-replay farm state to still be at that prefix.
                        try projection.validateExistingProjectionPrefix(
                            through: existingProjectionSequence,
                            persistedProjectionDigest: existingProjectionDigest
                        )
                    }
                    try projection.verifySnapshotBoundary(manifest)
                }

                try localStore.updateProjectionProgress(
                    sessionID: session.id,
                    state: .applyingRecentChanges,
                    verifiedProjectionEventSequence: try projection.lastAppliedEventSequence()
                )
                var after = manifest.boundaryEventSequence
                var verifierAlreadyThrough = existingProjectionSequence
                while true {
                    try Task.checkCancellation()
                    let page = try await gateway.pullEvents(
                        farmID: farmID,
                        farmGeneration: manifest.farmGeneration,
                        after: after,
                        limit: 500
                    )
                    guard page.cloudHead >= after else {
                        throw ESheepCloudInitialSyncError.eventBoundaryMismatch
                    }
                    if !page.events.isEmpty {
                        var unapplied: [ESheepCloudEventEnvelopeV2] = []
                        for event in page.events {
                            if event.eventSequence <= verifierAlreadyThrough {
                                // A verifier that was interrupted after the
                                // snapshot boundary may already contain a
                                // tail of recent events. Validate that tail
                                // against the immutable event page before
                                // skipping it; otherwise a damaged receipt
                                // chain could be mistaken for a checkpoint.
                                try projection.validateExistingEvent(event)
                            } else {
                                unapplied.append(event)
                            }
                        }
                        if !unapplied.isEmpty {
                            try projection.applyRecentEvents(unapplied)
                            verifierAlreadyThrough = try projection.lastAppliedEventSequence()
                        }
                        recentEvents.append(contentsOf: page.events)
                        after = page.events.last!.eventSequence
                        try localStore.updateProjectionProgress(
                            sessionID: session.id,
                            state: .applyingRecentChanges,
                            verifiedProjectionEventSequence: try projection.lastAppliedEventSequence(),
                            targetEventHead: page.cloudHead
                        )
                    }
                    if !page.hasMore {
                        guard after == page.cloudHead else {
                            throw ESheepCloudInitialSyncError.eventBoundaryMismatch
                        }
                        break
                    }
                    guard !page.events.isEmpty else {
                        throw ESheepCloudInitialSyncError.eventBoundaryMismatch
                    }
                }

                if canResumeProjection,
                   existingProjectionSequence > manifest.boundaryEventSequence {
                    // Validation walks only the durable prefix that existed
                    // before this attempt.  Any tail applied after that
                    // checkpoint is new work and must not be compared with
                    // the persisted prefix digest after the replay advances.
                    try projection.validateExistingProjectionPrefix(
                        through: existingProjectionSequence,
                        persistedProjectionDigest: existingProjectionDigest
                    )
                }

                try localStore.updateProjectionProgress(
                    sessionID: session.id,
                    state: .buildingIndexes,
                    verifiedProjectionEventSequence: try projection.lastAppliedEventSequence()
                )
                verifiedSummary = try projection.finishVerification()
                try localStore.updateProjectionProgress(
                    sessionID: session.id,
                    state: .readyToActivate,
                    verifiedProjectionEventSequence: verifiedSummary.eventHead
                )
                verificationStoreTrusted = true
            }
            try localStore.updateProjectionProgress(
                sessionID: session.id,
                state: .activating,
                activationProjectionEventSequence: 0
            )
            let activation = try localStore.beginNewFarmActivation(
                seed: seed,
                farmGeneration: manifest.farmGeneration
            )
            do {
                for descriptor in manifest.chunks.sorted(by: { $0.index < $1.index }) {
                    try Task.checkCancellation()
                    let records = try decodeChunk(
                        descriptor: descriptor,
                        manifest: manifest,
                        stagingRoot: stagingRoot
                    )
                    try activation.applySnapshotRecords(records)
                    try localStore.updateProjectionProgress(
                        sessionID: session.id,
                        state: .activating,
                        activationProjectionEventSequence: try activation.lastAppliedEventSequence()
                    )
                }
                try activation.applyRecentEvents(recentEvents)
                try localStore.updateProjectionProgress(
                    sessionID: session.id,
                    state: .activating,
                    activationProjectionEventSequence: try activation.lastAppliedEventSequence()
                )
                try activation.commit(
                    ifMatching: verifiedSummary,
                    sessionID: session.id
                )
            } catch {
                activation.rollback()
                throw error
            }
            return ESheepCloudInitialSyncReport(
                snapshotID: manifest.snapshotID,
                farmGeneration: manifest.farmGeneration,
                appliedEventHead: verifiedSummary.eventHead,
                streamCount: verifiedSummary.streams.count,
                assetCount: verifiedSummary.assetCount,
                receivedByteCount: manifest.chunks.reduce(0) { $0 + $1.byteCount }
            )
        } catch {
            if let sessionID {
                if shouldPauseInitialSync(for: error) {
                    try? localStore.markPaused(sessionID: sessionID)
                } else {
                    if !verificationStoreTrusted &&
                        Self.shouldQuarantineVerificationStore(for: error) {
                        try? localStore.quarantineVerificationStore(
                            sessionID: sessionID
                        )
                    }
                    try? localStore.markFailed(sessionID: sessionID)
                }
            }
            throw error
        }
    }

    /// A business reducer failure must leave the last durable verifier
    /// checkpoint in place so the UI can identify where replay stopped and a
    /// later fixed client can resume from that prefix. Quarantine is reserved
    /// for evidence that the SQLite/WAL/SHM set or the persisted receipt
    /// prefix itself is corrupt.
    static func shouldQuarantineVerificationStore(for error: Error) -> Bool {
        guard let syncError = error as? ESheepCloudInitialSyncError else {
            return false
        }
        switch syncError {
        case .verificationStoreIntegrity,
             .existingVerificationCheckpointMismatch:
            return true
        case .manifestMismatch,
             .insufficientSpace,
             .chunkMissing,
             .chunkDigestMismatch,
             .countMismatch,
             .streamMismatch,
             .eventBoundaryMismatch,
             .associationMismatch,
             .existingFarmRequiresMigration,
             .farmGenerationChanged,
             .accountMismatch:
            return false
        }
    }

    /// A cancelled task or a transport interruption is expected during a
    /// first receive: the app can be killed, backgrounded, or lose its
    /// connection while a verified chunk ledger is already on disk.  Keep the
    /// session resumable in those cases.  Integrity, schema, permission, and
    /// business validation errors remain terminal for this attempt and are
    /// recorded by `markFailed`.
    private func shouldPauseInitialSync(for error: Error) -> Bool {
        if error is CancellationError || error is URLError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    /// SwiftData will normally open a healthy verifier for us, but an
    /// interrupted process can leave a malformed SQLite/WAL/SHM trio that
    /// fails only after replay has started. Validate the existing store before
    /// touching it so the catch path can quarantine the trio and reuse every
    /// already verified immutable chunk. The read-only pragma is applied after
    /// opening read-write, which lets SQLite coordinate an active WAL safely.
    private func validateExistingVerificationStore(at url: URL) throws {
        let relatedURLs = LocalStoreRecoveryService.relatedStoreURLs(for: url)
        let existingRelatedURLs = relatedURLs.filter {
            fileManager.fileExists(atPath: $0.path)
        }
        // A WAL/SHM without its primary database is not a resumable store.
        // Treat it as an integrity failure so the entire set is quarantined
        // together instead of allowing SwiftData to create a fresh database
        // beside orphaned sidecars and silently losing the checkpoint.
        guard fileManager.fileExists(atPath: url.path) else {
            guard existingRelatedURLs.isEmpty else {
                throw ESheepCloudInitialSyncError.verificationStoreIntegrity(
                    "missing_main_store"
                )
            }
            return
        }
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "no_database_handle"
            if let database { sqlite3_close_v2(database) }
            throw ESheepCloudInitialSyncError.verificationStoreIntegrity(
                "open_\(openResult)_\(message)"
            )
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 5_000)
        guard sqlite3_exec(database, "PRAGMA query_only=ON;", nil, nil, nil) == SQLITE_OK else {
            throw ESheepCloudInitialSyncError.verificationStoreIntegrity(
                "query_only_\(String(cString: sqlite3_errmsg(database)))"
            )
        }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "PRAGMA quick_check;",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw ESheepCloudInitialSyncError.verificationStoreIntegrity(
                "prepare_\(prepareResult)_\(String(cString: sqlite3_errmsg(database)))"
            )
        }
        defer { sqlite3_finalize(statement) }
        var result = ""
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                result = String(cString: value)
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE, result == "ok" else {
            let detail = result.isEmpty
                ? String(cString: sqlite3_errmsg(database))
                : result
            throw ESheepCloudInitialSyncError.verificationStoreIntegrity(
                "quick_check_\(detail)"
            )
        }
    }

    private func downloadChunks(
        manifest: ESheepCloudSnapshotManifestV2,
        sessionID: UUID,
        stagingRoot: URL
    ) async throws {
        let descriptors = manifest.chunks.sorted { $0.index < $1.index }
        var iterator = descriptors.makeIterator()
        try await withThrowingTaskGroup(
            of: ESheepCloudSnapshotChunkDescriptorV2.self
        ) { group in
            for _ in 0..<min(3, descriptors.count) {
                if let descriptor = iterator.next() {
                    group.addTask { [self] in
                        try await downloadChunk(
                            descriptor,
                            snapshotID: manifest.snapshotID,
                            stagingRoot: stagingRoot
                        )
                    }
                }
            }
            while let descriptor = try await group.next() {
                try localStore.markChunkVerified(
                    sessionID: sessionID,
                    descriptor: descriptor
                )
                if let next = iterator.next() {
                    group.addTask { [self] in
                        try await downloadChunk(
                            next,
                            snapshotID: manifest.snapshotID,
                            stagingRoot: stagingRoot
                        )
                    }
                }
            }
        }
    }

    private func downloadChunk(
        _ descriptor: ESheepCloudSnapshotChunkDescriptorV2,
        snapshotID: UUID,
        stagingRoot: URL
    ) async throws -> ESheepCloudSnapshotChunkDescriptorV2 {
        try Task.checkCancellation()
        let url = chunkURL(index: descriptor.index, stagingRoot: stagingRoot)
        var existing = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        if Int64(existing.count) == descriptor.byteCount,
           sha256(existing) == descriptor.contentSHA256 {
            return descriptor
        }
        // A full-size file with a mismatched digest is not resumable: asking
        // the gateway for bytes at the end of that file would append nothing
        // and fail forever. Reset the exact-size corrupt chunk so only this
        // descriptor is fetched again; verified sibling chunks stay intact.
        if Int64(existing.count) >= descriptor.byteCount {
            existing = Data()
        }
        let remainder = try await gateway.downloadSnapshotChunk(
            snapshotID: snapshotID,
            chunkIndex: descriptor.index,
            byteOffset: Int64(existing.count)
        )
        try Task.checkCancellation()
        var complete = existing
        complete.append(remainder)
        if Int64(complete.count) == descriptor.byteCount,
           sha256(complete) == descriptor.contentSHA256 {
            try complete.write(to: url, options: [.atomic])
            return descriptor
        }

        // A partial file may contain a corrupt prefix, so appending the
        // gateway's remainder can never repair it. Retry this exact chunk
        // from byte zero once; verified sibling chunks remain untouched. The
        // retry is deliberately bounded so a bad server response still
        // produces a durable failed/diagnostic session rather than a loop.
        let retried = try await gateway.downloadSnapshotChunk(
            snapshotID: snapshotID,
            chunkIndex: descriptor.index,
            byteOffset: 0
        )
        try Task.checkCancellation()
        guard Int64(retried.count) == descriptor.byteCount,
              sha256(retried) == descriptor.contentSHA256 else {
            throw ESheepCloudInitialSyncError.chunkDigestMismatch(descriptor.index)
        }
        try retried.write(to: url, options: [.atomic])
        return descriptor
    }

    private func decodeChunk(
        descriptor: ESheepCloudSnapshotChunkDescriptorV2,
        manifest: ESheepCloudSnapshotManifestV2,
        stagingRoot: URL
    ) throws -> [ESheepCloudSnapshotRecordV2] {
        let url = chunkURL(index: descriptor.index, stagingRoot: stagingRoot)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ESheepCloudInitialSyncError.chunkMissing(descriptor.index)
        }
        guard Int64(data.count) == descriptor.byteCount,
              sha256(data) == descriptor.contentSHA256 else {
            throw ESheepCloudInitialSyncError.chunkDigestMismatch(descriptor.index)
        }
        return try ESheepCloudSnapshotCodec.decode(
            data,
            farmID: manifest.farmID,
            farmGeneration: manifest.farmGeneration
        )
    }

    private func verifyWholeSnapshot(
        manifest: ESheepCloudSnapshotManifestV2,
        stagingRoot: URL
    ) throws {
        var digestLines = manifest.farmProfileDigest
        for descriptor in manifest.chunks.sorted(by: { $0.index < $1.index }) {
            let url = chunkURL(index: descriptor.index, stagingRoot: stagingRoot)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  Int64(data.count) == descriptor.byteCount else {
                throw ESheepCloudInitialSyncError.chunkMissing(descriptor.index)
            }
            let digest = sha256(data)
            guard digest == descriptor.contentSHA256 else {
                throw ESheepCloudInitialSyncError.chunkDigestMismatch(descriptor.index)
            }
            digestLines += digest
        }
        guard sha256(Data(digestLines.utf8)) == manifest.totalDigest else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
    }

    private func ensureAvailableCapacity(
        for manifest: ESheepCloudSnapshotManifestV2
    ) throws {
        let required = max(
            32 * 1_024 * 1_024,
            manifest.chunks.reduce(0) { $0 + $1.byteCount } * 3
        )
        let values = try applicationSupportURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < required {
            throw ESheepCloudInitialSyncError.insufficientSpace(
                requiredBytes: required - available
            )
        }
    }

    private func relativeStagingStorePath(
        farmID: UUID,
        snapshotID: UUID,
        accountID: UUID
    ) -> String {
        "ESheepCloud/Staging/\(farmID.uuidString.lowercased())/" +
            "\(snapshotID.uuidString.lowercased())/" +
            "\(accountID.uuidString.lowercased())/verification.store"
    }

    private func chunkURL(index: Int, stagingRoot: URL) -> URL {
        stagingRoot.appending(path: String(format: "chunk-%06d.json", index))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ESheepCloudInitialSyncSessionSnapshot: Sendable {
    let id: UUID
    let stagingDirectoryRelativePath: String
    let previousState: ESheepCloudInitialSyncState
    let verifiedProjectionEventSequence: Int64
    let activationProjectionEventSequence: Int64
}

struct ESheepCloudVerifiedProjectionSummary: Sendable {
    let eventHead: Int64
    let projectionDigest: String
    let streams: [ESheepCloudStreamReferenceV2: ESheepCloudVerifiedStreamSummary]
    let assetCount: Int
}

struct ESheepCloudVerifiedStreamSummary: Sendable, Equatable {
    let streamVersion: Int64
    let contentDigest: String
    let lastEventSequence: Int64
    let fields: [String: ESheepCloudVerifiedFieldSummary]
}

struct ESheepCloudVerifiedFieldSummary: Sendable, Equatable {
    let version: Int64
    let valueDigest: String
}

private final class ESheepCloudInitialSyncLocalStore {
    private let container: ModelContainer
    private let fileManager: FileManager
    private let applicationSupportURL: URL

    init(
        container: ModelContainer,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) {
        self.container = container
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    }

    func beginOrResume(
        manifest: ESheepCloudSnapshotManifestV2,
        stagingStoreRelativePath: String,
        accountID: UUID? = nil
    ) throws -> ESheepCloudInitialSyncSessionSnapshot {
        let context = ModelContext(container)
        let allSessions = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .filter { $0.farmID == manifest.farmID && $0.state != .active }
        let legacyStagingStoreRelativePath =
            "ESheepCloud/Staging/\(manifest.farmID.uuidString.lowercased())/" +
            "\(manifest.snapshotID.uuidString.lowercased())/verification.store"
        // A session row is not an authorization record.  Once the server has
        // authenticated this manifest, only a row already owned by that
        // account or the deliberately claimable V12 `nil` row may be used.
        // Foreign rows remain untouched so a shared device cannot pause or
        // resume another account's receive attempt.
        let sessions = allSessions.filter { session in
            guard let accountID else { return true }
            return session.accountID == nil || session.accountID == accountID
        }
        let session: ESheepCloudInitialSyncSession
        let previousState: ESheepCloudInitialSyncState
        let matching = sessions.filter { $0.snapshotID == manifest.snapshotID }
        let admissions = sessions.filter {
            $0.snapshotID == nil && $0.farmGeneration == manifest.farmGeneration
        }
        if let accountID,
           matching.isEmpty,
           allSessions.contains(where: {
               $0.snapshotID == manifest.snapshotID &&
                   $0.accountID != nil && $0.accountID != accountID
           }) {
            throw ESheepCloudInitialSyncError.accountMismatch
        }
        guard matching.count <= 1, admissions.count <= 1 else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        if let existing = matching.first {
            previousState = existing.state
            guard existing.farmGeneration == manifest.farmGeneration else {
                throw ESheepCloudInitialSyncError.farmGenerationChanged
            }
            if let accountID,
               let existingAccountID = existing.accountID,
               existingAccountID != accountID {
                throw ESheepCloudInitialSyncError.accountMismatch
            }
            if existing.accountID == nil {
                existing.accountID = accountID
            }
            if let previousData = existing.manifestData {
                let previous = try ESheepCloudCanonicalCodec.decode(
                    ESheepCloudSnapshotManifestV2.self,
                    from: previousData
                )
                guard previous == manifest,
                      existing.manifestDigest == manifest.totalDigest else {
                    throw ESheepCloudInitialSyncError.manifestMismatch
                }
            }
            // The staging path is part of the snapshot identity. A stale row
            // that points at another snapshot directory must not be allowed to
            // combine that directory's files with this manifest, even when a
            // gateway happens to reuse the same farm generation.
            guard existing.stagingStoreRelativePath == stagingStoreRelativePath ||
                existing.stagingStoreRelativePath == legacyStagingStoreRelativePath else {
                throw ESheepCloudInitialSyncError.manifestMismatch
            }
            session = existing
        } else if let admission = admissions.first {
            previousState = admission.state
            if let accountID,
               let existingAccountID = admission.accountID,
               existingAccountID != accountID {
                throw ESheepCloudInitialSyncError.accountMismatch
            }
            if let accountID,
               allSessions.contains(where: {
                   $0.id != admission.id &&
                       $0.accountID != nil &&
                       $0.accountID != accountID &&
                       $0.stagingStoreRelativePath == admission.stagingStoreRelativePath
               }) {
                // A legacy account-less admission may point at the old shared
                // pending directory. Never move or reuse that directory when
                // another account has already claimed the same path.
                throw ESheepCloudInitialSyncError.accountMismatch
            }
            session = admission
            if session.accountID == nil {
                session.accountID = accountID
            }
            if session.stagingStoreRelativePath != stagingStoreRelativePath {
                try relocateStagingDirectory(
                    from: session.stagingStoreRelativePath,
                    to: stagingStoreRelativePath
                )
            }
            session.snapshotID = manifest.snapshotID
            session.stagingStoreRelativePath = stagingStoreRelativePath
        } else {
            previousState = .connecting
            session = ESheepCloudInitialSyncSession(
                farmID: manifest.farmID,
                farmGeneration: manifest.farmGeneration,
                stagingGeneration: manifest.farmGeneration,
                stagingStoreRelativePath: stagingStoreRelativePath,
                accountID: accountID
            )
            session.snapshotID = manifest.snapshotID
            context.insert(session)
        }
        for old in sessions where old.id != session.id {
            old.state = .paused
        }
        session.boundaryEventSequence = manifest.boundaryEventSequence
        session.targetEventHead = manifest.eventHeadAtCreation
        session.expectedByteCount = manifest.chunks.reduce(0) { $0 + $1.byteCount }
        session.manifestData = try ESheepCloudCanonicalCodec.encode(manifest)
        session.manifestDigest = manifest.totalDigest
        if session.accountID == nil {
            session.accountID = accountID
        }
        let verifiedIndexes = try ESheepCloudCanonicalCodec.decode(
            [Int].self,
            from: session.verifiedChunkIndexesData
        )
        let validIndexes = Set(manifest.chunks.map(\.index))
        let verifiedSet = Set(verifiedIndexes)
        let verifiedByteCount = manifest.chunks.reduce(0) { partial, chunk in
            partial + (verifiedSet.contains(chunk.index) ? chunk.byteCount : 0)
        }
        guard Set(verifiedIndexes).count == verifiedIndexes.count,
              verifiedIndexes.allSatisfy(validIndexes.contains),
              session.receivedByteCount == verifiedByteCount,
              verifiedByteCount <= session.expectedByteCount else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        session.state = .receiving
        try context.save()
        return .init(
            id: session.id,
            stagingDirectoryRelativePath: (session.stagingStoreRelativePath as NSString)
                .deletingLastPathComponent,
            previousState: previousState,
            verifiedProjectionEventSequence: session.verifiedProjectionEventSequence,
            activationProjectionEventSequence: session.activationProjectionEventSequence
        )
    }

    /// Move a legacy/account-less admission's complete staging directory into
    /// the account-scoped snapshot path before the manifest is attached. This
    /// keeps chunks, verifier SQLite sidecars, and rejected evidence together;
    /// no bytes are overwritten and a destination collision fails closed.
    private func relocateStagingDirectory(
        from sourceRelativePath: String,
        to destinationRelativePath: String
    ) throws {
        guard sourceRelativePath != destinationRelativePath else { return }
        let sourceStoreURL = applicationSupportURL.appending(path: sourceRelativePath)
        guard fileManager.fileExists(atPath: sourceStoreURL.path) else { return }
        let destinationStoreURL = applicationSupportURL.appending(
            path: destinationRelativePath
        )
        let sourceDirectory = sourceStoreURL.deletingLastPathComponent()
        let destinationDirectory = destinationStoreURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: destinationDirectory.path) {
            let existing = try fileManager.contentsOfDirectory(
                at: destinationDirectory,
                includingPropertiesForKeys: nil
            )
            guard existing.isEmpty else {
                throw ESheepCloudInitialSyncError.manifestMismatch
            }
        } else {
            try fileManager.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        }
        for item in try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ) {
            let destination = destinationDirectory.appending(path: item.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw ESheepCloudInitialSyncError.manifestMismatch
            }
            try fileManager.moveItem(at: item, to: destination)
        }
    }

    func markChunkVerified(
        sessionID: UUID,
        descriptor: ESheepCloudSnapshotChunkDescriptorV2
    ) throws {
        let context = ModelContext(container)
        guard let session = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .first(where: { $0.id == sessionID }) else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        guard let manifestData = session.manifestData else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        let manifest = try ESheepCloudCanonicalCodec.decode(
            ESheepCloudSnapshotManifestV2.self,
            from: manifestData
        )
        guard manifest.snapshotID == session.snapshotID,
              manifest.farmID == session.farmID,
              manifest.farmGeneration == session.farmGeneration,
              manifest.totalDigest == session.manifestDigest,
              manifest.chunks.first(where: { $0.index == descriptor.index }) == descriptor else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        var indexes = try ESheepCloudCanonicalCodec.decode(
            [Int].self,
            from: session.verifiedChunkIndexesData
        )
        let validIndexes = Set(manifest.chunks.map(\.index))
        guard Set(indexes).count == indexes.count,
              indexes.allSatisfy(validIndexes.contains) else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        if !indexes.contains(descriptor.index) {
            indexes.append(descriptor.index)
        }
        indexes.sort()
        let verified = Set(indexes)
        session.receivedByteCount = manifest.chunks.reduce(0) { partial, chunk in
            partial + (verified.contains(chunk.index) ? chunk.byteCount : 0)
        }
        guard session.receivedByteCount <= session.expectedByteCount else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        session.verifiedChunkIndexesData = try ESheepCloudCanonicalCodec.encode(indexes)
        session.state = .receiving
        session.lastProgressAt = .now
        session.updatedAt = .now
        try context.save()
    }

    func updateSession(
        sessionID: UUID,
        state: ESheepCloudInitialSyncState
    ) throws {
        let context = ModelContext(container)
        guard let session = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .first(where: { $0.id == sessionID }) else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        session.state = state
        try context.save()
    }

    func updateProjectionProgress(
        sessionID: UUID,
        state: ESheepCloudInitialSyncState? = nil,
        verifiedProjectionEventSequence: Int64? = nil,
        activationProjectionEventSequence: Int64? = nil,
        targetEventHead: Int64? = nil
    ) throws {
        let context = ModelContext(container)
        guard let session = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .first(where: { $0.id == sessionID }) else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        if let state {
            session.state = state
        }
        if let verifiedProjectionEventSequence {
            session.verifiedProjectionEventSequence = max(0, verifiedProjectionEventSequence)
        }
        if let activationProjectionEventSequence {
            session.activationProjectionEventSequence = max(0, activationProjectionEventSequence)
        }
        if let targetEventHead {
            session.targetEventHead = max(session.targetEventHead, targetEventHead)
        }
        session.lastProgressAt = .now
        session.updatedAt = .now
        try context.save()
    }

    func resetActivationProgress(sessionID: UUID) throws {
        try updateProjectionProgress(
            sessionID: sessionID,
            activationProjectionEventSequence: 0
        )
    }

    /// A failed receive is a resumable session, not an implicit success and
    /// not a reason to touch the active farm.  Keep a short opaque trace token
    /// for support diagnostics while retaining the verified chunk ledger.
    func markFailed(sessionID: UUID) throws {
        let context = ModelContext(container)
        guard let session = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .first(where: { $0.id == sessionID }) else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        guard session.state != .active else { return }
        session.state = .failed
        session.retryCount += 1
        session.lastErrorTraceID = UUID().uuidString.lowercased()
        // Activation is an all-or-nothing main-store transaction. A failed
        // attempt never leaves a resumable prefix in the active store, so the
        // next attempt must expose activation progress as zero and replay the
        // isolated projection again from its trusted checkpoint.
        session.activationProjectionEventSequence = 0
        try context.save()
    }

    /// Pause without incrementing the failure counter.  The verified chunk
    /// indexes and staging files are intentionally left untouched so the next
    /// `beginOrResume` call can continue from the last durable boundary.
    func markPaused(sessionID: UUID) throws {
        let context = ModelContext(container)
        guard let session = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .first(where: { $0.id == sessionID }) else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        guard session.state != .active else { return }
        session.state = .paused
        session.lastErrorTraceID = nil
        session.activationProjectionEventSequence = 0
        session.lastProgressAt = .now
        try context.save()
    }

    /// Move an invalid partial verifier as one unit so the immutable chunks
    /// remain reusable and support can inspect the exact rejected SQLite/WAL/
    /// SHM set. The active main store is never part of this operation.
    func quarantineVerificationStore(sessionID: UUID) throws {
        let context = ModelContext(container)
        guard let session = try context.fetch(
            FetchDescriptor<ESheepCloudInitialSyncSession>()
        ).first(where: { $0.id == sessionID }) else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        let storeURL = applicationSupportURL.appending(
            path: session.stagingStoreRelativePath
        )
        let related = LocalStoreRecoveryService.relatedStoreURLs(for: storeURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
        if !related.isEmpty {
            let stamp = String(Int(Date().timeIntervalSince1970)) + "-" +
                UUID().uuidString.lowercased()
            let rejectedRoot = storeURL.deletingLastPathComponent()
                .appending(path: "Rejected/\(stamp)", directoryHint: .isDirectory)
            try fileManager.createDirectory(
                at: rejectedRoot,
                withIntermediateDirectories: true
            )
            for source in related {
                let destination = rejectedRoot.appending(path: source.lastPathComponent)
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        // The quarantined SQLite prefix is no longer a resumable source. Reset
        // only the verifier checkpoint; immutable snapshot chunks and the
        // manifest ledger stay intact and the next attempt can rebuild from
        // them without tripping the old-sequence consistency check.
        session.verifiedProjectionEventSequence = 0
        session.activationProjectionEventSequence = 0
        session.lastProgressAt = .now
        session.updatedAt = .now
        try context.save()
    }

    func beginNewFarmActivation(
        seed: ESheepCloudFarmSeedV2,
        farmGeneration: Int
    ) throws -> ESheepCloudActivationTransaction {
        let context = ModelContext(container)
        // Activation is a single explicit commit.  Do not allow SwiftData's
        // autosave timer to publish a partially seeded farm while the
        // snapshot is still being replayed.
        context.autosaveEnabled = false
        let hasBusinessData = try hasExistingFarmData(
            farmID: seed.id,
            context: context
        )
        guard !hasBusinessData else {
            throw ESheepCloudInitialSyncError.existingFarmRequiresMigration
        }
        return try ESheepCloudActivationTransaction(
            context: context,
            seed: seed,
            farmGeneration: farmGeneration
        )
    }

    /// A first receive is allowed to seed an empty store only.  Checking just
    /// sheep and pens is not enough: an interrupted restore can leave photos,
    /// tombstones, care/TMR rows, or an old cloud binding behind with no
    /// visible flock.  Seeding over any of those rows would create a mixed
    /// generation that cannot be rebuilt deterministically, so the V1
    /// migration reader must handle it instead.
    private func hasExistingFarmData(
        farmID: UUID,
        context: ModelContext
    ) throws -> Bool {
        if try context.fetch(FetchDescriptor<FarmRecord>())
            .contains(where: { $0.id == farmID }) {
            return true
        }
        return try hasExistingFarmDataAfterFarmShellCheck(
            farmID: farmID,
            context: context
        )
    }

    private func hasExistingFarmDataAfterFarmShellCheck(
        farmID: UUID,
        context: ModelContext
    ) throws -> Bool {
        let checks: [(String, Bool)] = [
            ("FarmStorageProfile", try context.fetch(FetchDescriptor<FarmStorageProfile>())
                .contains { $0.farmID == farmID }),
            ("FarmRemoteBinding", try context.fetch(FetchDescriptor<FarmRemoteBinding>())
                .contains { $0.farmID == farmID }),
            ("FarmMembershipBinding", try context.fetch(FetchDescriptor<FarmMembershipBinding>())
                .contains { $0.farmID == farmID }),
            ("FarmRemoteRestoreRecord", try context.fetch(FetchDescriptor<FarmRemoteRestoreRecord>())
                .contains { $0.farmID == farmID }),
            ("FarmBaselineMigrationRecord", try context.fetch(FetchDescriptor<FarmBaselineMigrationRecord>())
                .contains { $0.farmID == farmID }),
            ("MigrationCommitRecord", try context.fetch(FetchDescriptor<MigrationCommitRecord>())
                .contains { $0.farmID == farmID }),
            ("ESheepCloudFarmState", try context.fetch(FetchDescriptor<ESheepCloudFarmState>())
                .contains { $0.farmID == farmID }),
            ("ESheepCloudStreamState", try context.fetch(FetchDescriptor<ESheepCloudStreamState>())
                .contains { $0.farmID == farmID }),
            ("ESheepCloudPendingIntent", try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
                .contains { $0.farmID == farmID }),
            ("ESheepCloudEventReceipt", try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>())
                .contains { $0.farmID == farmID }),
            ("ESheepCloudAttentionItem", try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>())
                .contains { $0.farmID == farmID }),
            ("ESheepCloudAssetState", try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
                .contains { $0.farmID == farmID }),
            ("ESheepCloudMigrationState", try context.fetch(FetchDescriptor<ESheepCloudMigrationState>())
                .contains { $0.farmID == farmID }),
            ("PenRecord", try context.fetch(FetchDescriptor<PenRecord>())
                .contains { $0.farmID == farmID }),
            ("SheepRecord", try context.fetch(FetchDescriptor<SheepRecord>())
                .contains { $0.farmID == farmID }),
            ("SheepAvatarRecord", try context.fetch(FetchDescriptor<SheepAvatarRecord>())
                .contains { $0.farmID == farmID }),
            ("WeightRecord", try context.fetch(FetchDescriptor<WeightRecord>())
                .contains { $0.farmID == farmID }),
            ("WeaningRecord", try context.fetch(FetchDescriptor<WeaningRecord>())
                .contains { $0.farmID == farmID }),
            ("TransferRecord", try context.fetch(FetchDescriptor<TransferRecord>())
                .contains { $0.farmID == farmID }),
            ("RemovalRecord", try context.fetch(FetchDescriptor<RemovalRecord>())
                .contains { $0.farmID == farmID }),
            ("ProductionBatchRecord", try context.fetch(FetchDescriptor<ProductionBatchRecord>())
                .contains { $0.farmID == farmID }),
            ("BatchMembershipRecord", try context.fetch(FetchDescriptor<BatchMembershipRecord>())
                .contains { $0.farmID == farmID }),
            ("FeedIngredientRecord", try context.fetch(FetchDescriptor<FeedIngredientRecord>())
                .contains { $0.farmID == farmID }),
            ("FeedIngredientBatchRecord", try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
                .contains { $0.farmID == farmID }),
            ("FeedRecipeRecord", try context.fetch(FetchDescriptor<FeedRecipeRecord>())
                .contains { $0.farmID == farmID }),
            ("FeedRecipeComponentRecord", try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>())
                .contains { $0.farmID == farmID }),
            ("FeedRecord", try context.fetch(FetchDescriptor<FeedRecord>())
                .contains { $0.farmID == farmID }),
            ("FeedRecordLine", try context.fetch(FetchDescriptor<FeedRecordLine>())
                .contains { $0.farmID == farmID }),
            ("FeedTroughObservationRecord", try context.fetch(FetchDescriptor<FeedTroughObservationRecord>())
                .contains { $0.farmID == farmID }),
            ("FeedStockTransactionRecord", try context.fetch(FetchDescriptor<FeedStockTransactionRecord>())
                .contains { $0.farmID == farmID }),
            ("FeedStockCountRecord", try context.fetch(FetchDescriptor<FeedStockCountRecord>())
                .contains { $0.farmID == farmID }),
            ("InventoryLotRecord", try context.fetch(FetchDescriptor<InventoryLotRecord>())
                .contains { $0.farmID == farmID }),
            ("InventoryTransactionRecord", try context.fetch(FetchDescriptor<InventoryTransactionRecord>())
                .contains { $0.farmID == farmID }),
            ("HealthRecord", try context.fetch(FetchDescriptor<HealthRecord>())
                .contains { $0.farmID == farmID }),
            ("ReproductionRecord", try context.fetch(FetchDescriptor<ReproductionRecord>())
                .contains { $0.farmID == farmID }),
            ("SemenRecord", try context.fetch(FetchDescriptor<SemenRecord>())
                .contains { $0.farmID == farmID }),
            ("NoteRecord", try context.fetch(FetchDescriptor<NoteRecord>())
                .contains { $0.farmID == farmID }),
            ("PhotoAssetRecord", try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                .contains { $0.farmID == farmID }),
            ("LambingOffspringRecord", try context.fetch(FetchDescriptor<LambingOffspringRecord>())
                .contains { $0.farmID == farmID }),
            ("SemenDonorRecord", try context.fetch(FetchDescriptor<SemenDonorRecord>())
                .contains { $0.farmID == farmID }),
            ("PedigreeChangeRecord", try context.fetch(FetchDescriptor<PedigreeChangeRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRFormulaProfileRecord", try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRFeedingPlanRecord", try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRFeedingPlanPenRecord", try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRBatchRecord", try context.fetch(FetchDescriptor<TMRBatchRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRBatchIngredientRecord", try context.fetch(FetchDescriptor<TMRBatchIngredientRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRBatchLoadLineRecord", try context.fetch(FetchDescriptor<TMRBatchLoadLineRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRBatchMovementRecord", try context.fetch(FetchDescriptor<TMRBatchMovementRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRFeedingRunRecord", try context.fetch(FetchDescriptor<TMRFeedingRunRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRFeedingAllocationRecord", try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRMealCompletionRecord", try context.fetch(FetchDescriptor<TMRMealCompletionRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRDeviationAcknowledgementRecord", try context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>())
                .contains { $0.farmID == farmID }),
            ("TMRMonitoringRuleRecord", try context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>())
                .contains { $0.farmID == farmID }),
            ("CareBatchRecord", try context.fetch(FetchDescriptor<CareBatchRecord>())
                .contains { $0.farmID == farmID }),
            ("SemenTransactionRecord", try context.fetch(FetchDescriptor<SemenTransactionRecord>())
                .contains { $0.farmID == farmID }),
            ("FarmCareRuleRecord", try context.fetch(FetchDescriptor<FarmCareRuleRecord>())
                .contains { $0.farmID == farmID }),
            ("FarmAlertDeferralRecord", try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>())
                .contains { $0.farmID == farmID }),
            ("CareReminderRecord", try context.fetch(FetchDescriptor<CareReminderRecord>())
                .contains { $0.farmID == farmID }),
        ]
        return checks.contains(where: { $0.1 })
    }

}

class ESheepCloudProjectionTransaction {
    let context: ModelContext
    let farmID: UUID
    let farmGeneration: Int
    let replayContext: ESheepCloudProjectionReplayContext
    let domainApplyService: RemoteDomainApplyService
    var expectedStreams: [ESheepCloudStreamReferenceV2: ESheepCloudSnapshotStreamV2] = [:]
    var snapshotStreamCount = 0
    var snapshotEventCount = 0
    var snapshotAssetCount = 0
    var earliestHistoryChange: Date?
    private var validatedPrefixEventSequence: Int64 = 0
    private var validatedPrefixDigest = String(repeating: "0", count: 64)
    private var eventsSinceCancellationCheck = 0

    init(
        context: ModelContext,
        seed: ESheepCloudFarmSeedV2,
        farmGeneration: Int,
        seedEmptyStore: Bool = true
    ) throws {
        self.context = context
        farmID = seed.id
        self.farmGeneration = farmGeneration
        replayContext = ESheepCloudProjectionReplayContext()
        domainApplyService = RemoteDomainApplyService(
            replayAssumesEmptyBusinessStore: seedEmptyStore,
            replayContext: replayContext
        )
        if seedEmptyStore {
            try Self.seedFarm(seed, context: context)
            let state = ESheepCloudFarmState(
                farmID: seed.id,
                farmGeneration: farmGeneration,
                activityState: .preparing
            )
            context.insert(state)
            replayContext.register(state)
            // The domain adapter's index is separate from the protocol
            // ledger cache. Register the freshly seeded farm shell before
            // the first event so a farm-location event can resolve it
            // without falling back to a SQL lookup.
            domainApplyService.rebuildPendingReplayIndex(in: context)
        } else {
            try domainApplyService.prepareResumableReplay(
                farmID: seed.id,
                context: context
            )
        }
        try replayContext.preload(in: context)
    }

    func applySnapshotRecords(
        _ records: [ESheepCloudSnapshotRecordV2],
        skippingEventsThrough: Int64 = 0
    ) throws {
        for record in records {
            switch record {
            case .stream(let value):
                guard expectedStreams[value.stream] == nil else {
                    throw ESheepCloudInitialSyncError.streamMismatch(value.stream.type)
                }
                expectedStreams[value.stream] = value
                snapshotStreamCount += 1
            case .event(let event):
                snapshotEventCount += 1
                try checkCancellationAfterEvent()
                if event.eventSequence <= skippingEventsThrough {
                    try validateExistingEvent(event)
                    continue
                }
                let outcome: ESheepCloudEventApplyOutcome
                do {
                    outcome = try ESheepCloudEventReducer.apply(
                    event,
                    context: context,
                    savesChanges: false,
                    replayContext: replayContext,
                    domainApplyService: domainApplyService
                    )
                } catch {
                    NSLog("V2 snapshot replay failed at event %lld, stream %@: %@",
                          event.eventSequence, event.stream.type, String(describing: error))
                    throw error
                }
                if let changedAt = outcome.historyChangedAt {
                    earliestHistoryChange = min(earliestHistoryChange ?? changedAt, changedAt)
                }
            case .asset(let asset):
                try upsert(asset: asset)
                snapshotAssetCount += 1
            }
        }
        // Child projections created inside a business handler are registered
        // once per immutable chunk. This keeps the cache current for the next
        // chunk without turning insertion bookkeeping into an event-sized
        // scan.
        replayContext.registerInsertedModels(in: context)
        domainApplyService.rebuildPendingReplayIndex(in: context)
    }

    /// Rebuilds the immutable snapshot expectations without invoking the
    /// business reducer. This is the fast resume path for a verifier that has
    /// already reached the snapshot boundary (or the full event head).
    func inspectSnapshotRecords(
        _ records: [ESheepCloudSnapshotRecordV2],
        validatingReceiptsThrough sequence: Int64
    ) throws {
        for record in records {
            switch record {
            case .stream(let value):
                guard expectedStreams[value.stream] == nil else {
                    throw ESheepCloudInitialSyncError.streamMismatch(value.stream.type)
                }
                expectedStreams[value.stream] = value
                snapshotStreamCount += 1
            case .event(let event):
                snapshotEventCount += 1
                guard event.eventSequence <= sequence else { continue }
                try checkCancellationAfterEvent()
                try validateExistingEvent(event)
            case .asset(let asset):
                try upsert(asset: asset)
                snapshotAssetCount += 1
            }
        }
    }

    func lastAppliedEventSequence() throws -> Int64 {
        try farmState()?.lastAppliedEventSequence ?? 0
    }

    func currentProjectionDigest() throws -> String? {
        try farmState()?.projectionDigest
    }

    func validateExistingProjectionPrefix(
        through sequence: Int64,
        persistedProjectionDigest: String? = nil
    ) throws {
        let actualDigest: String?
        if let persistedProjectionDigest {
            actualDigest = persistedProjectionDigest
        } else {
            actualDigest = try farmState()?.projectionDigest
        }
        guard sequence == 0 || validatedPrefixEventSequence == sequence,
              actualDigest ==
                  (sequence == 0
                      ? String(repeating: "0", count: 64)
                      : validatedPrefixDigest) else {
            throw ESheepCloudInitialSyncError.existingVerificationCheckpointMismatch
        }
        if persistedProjectionDigest == nil {
            guard let state = try farmState(), state.lastAppliedEventSequence == sequence else {
                throw ESheepCloudInitialSyncError.existingVerificationCheckpointMismatch
            }
        }
    }

    func validateExistingEvent(
        _ event: ESheepCloudEventEnvelopeV2
    ) throws {
        guard event.eventSequence == validatedPrefixEventSequence + 1,
              let receipt = try replayContext.eventReceipt(
                  eventID: event.eventID,
                  context: context
              ),
              receipt.farmID == event.farmID,
              receipt.farmGeneration == event.farmGeneration,
              receipt.eventSequence == event.eventSequence,
              receipt.commandID == event.commandID,
              receipt.eventDigest == event.eventDigest,
              receipt.appliedProjectionDigest == event.afterDigest else {
            throw ESheepCloudInitialSyncError.existingVerificationCheckpointMismatch
        }
        validatedPrefixEventSequence = event.eventSequence
        validatedPrefixDigest = receiptChainDigest(
            previous: validatedPrefixDigest,
            eventDigest: event.eventDigest
        )
    }

    func applyRecentEvents(_ events: [ESheepCloudEventEnvelopeV2]) throws {
        for event in events {
            try checkCancellationAfterEvent()
            let outcome = try ESheepCloudEventReducer.apply(
                event,
                context: context,
                savesChanges: false,
                replayContext: replayContext,
                domainApplyService: domainApplyService
            )
            if let changedAt = outcome.historyChangedAt {
                earliestHistoryChange = min(earliestHistoryChange ?? changedAt, changedAt)
            }
        }
        replayContext.registerInsertedModels(in: context)
        domainApplyService.rebuildPendingReplayIndex(in: context)
    }

    private func checkCancellationAfterEvent() throws {
        eventsSinceCancellationCheck += 1
        if eventsSinceCancellationCheck >= 256 {
            eventsSinceCancellationCheck = 0
            try Task.checkCancellation()
        }
    }

    func verifySnapshotBoundary(
        _ manifest: ESheepCloudSnapshotManifestV2,
        stateMustBeAtBoundary: Bool = true
    ) throws {
        let counts = Dictionary(uniqueKeysWithValues: manifest.recordCounts.map {
            ($0.recordType, $0.count)
        })
        guard snapshotStreamCount == (counts["streams"] ?? 0) else {
            throw ESheepCloudInitialSyncError.countMismatch("streams")
        }
        guard snapshotEventCount == (counts["events"] ?? 0) else {
            throw ESheepCloudInitialSyncError.countMismatch("events")
        }
        guard snapshotAssetCount == (counts["assets"] ?? 0) else {
            throw ESheepCloudInitialSyncError.countMismatch("assets")
        }
        if stateMustBeAtBoundary {
            guard let state = try farmState(),
                  state.lastAppliedEventSequence == manifest.boundaryEventSequence,
                  state.projectionDigest == manifest.relationshipDigest else {
                throw ESheepCloudInitialSyncError.eventBoundaryMismatch
            }
        } else {
            guard let state = try farmState(),
                  state.lastAppliedEventSequence >= manifest.boundaryEventSequence else {
                throw ESheepCloudInitialSyncError.eventBoundaryMismatch
            }
        }

        // A stream can legitimately have no historical event yet (for
        // example, a newly-created empty avatar or membership stream).  The
        // snapshot's stream row is still authoritative in that case.  The
        // event reducer normally creates a stream while replaying an event,
        // so materialize only the zero-event/empty-state form here; any other
        // missing stream fails closed instead of silently activating an
        // incomplete farm projection.
        try materializeZeroEventStreamsIfNeeded()
        let actual = try context.fetch(FetchDescriptor<ESheepCloudStreamState>())
            .filter { $0.farmID == farmID && $0.farmGeneration == farmGeneration }
        guard actual.count == expectedStreams.count else {
            throw ESheepCloudInitialSyncError.countMismatch("streams")
        }
        for stream in actual {
            let reference = ESheepCloudStreamReferenceV2(
                type: stream.streamType,
                id: stream.streamID
            )
            guard let expected = expectedStreams[reference],
                  stream.streamVersion == expected.streamVersion,
                  stream.contentDigest == expected.contentDigest,
                  stream.lastEventSequence == expected.lastEventSequence else {
                throw ESheepCloudInitialSyncError.streamMismatch(stream.streamType)
            }
            let fields = try ESheepCloudCanonicalCodec.decode(
                [ESheepCloudFieldVersionEntryV2].self,
                from: stream.fieldVersionsData
            )
            let actualFields = Dictionary(uniqueKeysWithValues: fields.map {
                ($0.field, ESheepCloudVerifiedFieldSummary(
                    version: $0.version,
                    valueDigest: $0.valueDigest
                ))
            })
            let expectedFields = Dictionary(uniqueKeysWithValues: expected.fieldVersions.map {
                ($0.field, ESheepCloudVerifiedFieldSummary(
                    version: $0.version,
                    valueDigest: $0.valueDigest
                ))
            })
            guard actualFields == expectedFields else {
                throw ESheepCloudInitialSyncError.streamMismatch(stream.streamType)
            }
        }
    }

    /// Materializes the only valid stream shape that has no event receipt.
    /// This is shared by the verification store and the activation transaction
    /// so a stream cannot pass staging verification and then disappear during
    /// the final atomic copy into the active store.
    func materializeZeroEventStreamsIfNeeded() throws {
        let emptyCanonical: [String: ESheepCloudValueV2] = [:]
        let emptyCanonicalData = try ESheepCloudCanonicalCodec.encode(emptyCanonical)
        let emptyCanonicalDigest = SHA256.hash(data: emptyCanonicalData)
            .map { String(format: "%02x", $0) }
            .joined()
        let actual = try context.fetch(FetchDescriptor<ESheepCloudStreamState>())
            .filter { $0.farmID == farmID && $0.farmGeneration == farmGeneration }
        for expected in expectedStreams.values where expected.lastEventSequence == 0 {
            let matches = actual.filter {
                $0.streamType == expected.stream.type &&
                    $0.streamID == expected.stream.id
            }
            guard matches.count <= 1 else {
                throw ESheepCloudInitialSyncError.streamMismatch(expected.stream.type)
            }
            guard matches.first != nil || (
                expected.streamVersion == 0 &&
                    expected.fieldVersions.isEmpty &&
                    expected.contentDigest == emptyCanonicalDigest
            ) else {
                throw ESheepCloudInitialSyncError.streamMismatch(expected.stream.type)
            }
            if matches.isEmpty {
                let state = ESheepCloudStreamState(
                    farmID: farmID,
                    farmGeneration: farmGeneration,
                    streamType: expected.stream.type,
                    streamID: expected.stream.id,
                    streamVersion: expected.streamVersion,
                    fieldVersionsData: try ESheepCloudCanonicalCodec.encode(
                        expected.fieldVersions
                    ),
                    canonicalStateData: emptyCanonicalData,
                    contentDigest: expected.contentDigest,
                    lastEventSequence: expected.lastEventSequence
                )
                context.insert(state)
                replayContext.register(state)
            }
        }
    }

    func projectionSummary() throws -> ESheepCloudVerifiedProjectionSummary {
        if let earliestHistoryChange {
            try FarmHistoryRebuilder().rebuild(
                farmID: farmID,
                context: context,
                from: earliestHistoryChange
            )
        }
        try verifyAssociations()
        guard let state = try farmState() else {
            throw ESheepCloudInitialSyncError.eventBoundaryMismatch
        }
        let streams = try context.fetch(FetchDescriptor<ESheepCloudStreamState>())
            .filter { $0.farmID == farmID && $0.farmGeneration == farmGeneration }
        let summaries = try Dictionary(uniqueKeysWithValues: streams.map { stream in
            let fields = try ESheepCloudCanonicalCodec.decode(
                [ESheepCloudFieldVersionEntryV2].self,
                from: stream.fieldVersionsData
            )
            return (
                ESheepCloudStreamReferenceV2(type: stream.streamType, id: stream.streamID),
                ESheepCloudVerifiedStreamSummary(
                    streamVersion: stream.streamVersion,
                    contentDigest: stream.contentDigest,
                    lastEventSequence: stream.lastEventSequence,
                    fields: Dictionary(uniqueKeysWithValues: fields.map {
                        ($0.field, .init(version: $0.version, valueDigest: $0.valueDigest))
                    })
                )
            )
        })
        let assets = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .filter { $0.farmID == farmID && $0.farmGeneration == farmGeneration }
        return .init(
            eventHead: state.lastAppliedEventSequence,
            projectionDigest: state.projectionDigest,
            streams: summaries,
            assetCount: assets.count
        )
    }

    func verifyAssociations() throws {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == farmID }
        let sheepIDs = Set(sheep.map(\.id))
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
            .filter { $0.farmID == farmID }
        let penIDs = Set(pens.map(\.id))
        let assets = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID }
        let assetIDs = Set(assets.map(\.id))
        let activeEarTags = sheep.filter { $0.deletedAt == nil }.map {
            $0.earTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard Set(activeEarTags).count == activeEarTags.count,
              sheep.allSatisfy({
                  $0.currentPenID.map(penIDs.contains) ?? true
              }),
              try context.fetch(FetchDescriptor<WeightRecord>())
                .filter({ $0.farmID == farmID }).allSatisfy({ sheepIDs.contains($0.sheepID) }),
              try context.fetch(FetchDescriptor<WeaningRecord>())
                .filter({ $0.farmID == farmID }).allSatisfy({
                    sheepIDs.contains($0.sheepID) && ($0.damID.map(sheepIDs.contains) ?? true)
                }),
              try context.fetch(FetchDescriptor<TransferRecord>())
                .filter({ $0.farmID == farmID }).allSatisfy({
                    sheepIDs.contains($0.sheepID) &&
                    ($0.fromPenID.map(penIDs.contains) ?? true) &&
                    ($0.toPenID.map(penIDs.contains) ?? true)
                }),
              try context.fetch(FetchDescriptor<RemovalRecord>())
                .filter({ $0.farmID == farmID }).allSatisfy({ sheepIDs.contains($0.sheepID) }),
              assets.allSatisfy({ $0.sheepID.map(sheepIDs.contains) ?? true }),
              try context.fetch(FetchDescriptor<SheepAvatarRecord>())
                .filter({ $0.farmID == farmID }).allSatisfy({
                    sheepIDs.contains($0.sheepID) && ($0.photoAssetID.map(assetIDs.contains) ?? true)
                }) else {
            throw ESheepCloudInitialSyncError.associationMismatch("farm")
        }
    }

    private func upsert(asset: ESheepCloudSnapshotAssetV2) throws {
        let existing = try replayContext.assetState(
            assetID: asset.assetID,
            farmID: farmID,
            context: context
        )
        let value = existing ?? ESheepCloudAssetState(
            assetID: asset.assetID,
            farmID: farmID,
            farmGeneration: farmGeneration,
            sheepID: asset.sheepID,
            contentSHA256: asset.contentSHA256,
            metadataDigest: asset.metadataDigest,
            originalByteCount: asset.originalByteCount
        )
        if existing == nil { context.insert(value) }
        replayContext.register(value)
        guard value.contentSHA256 == asset.contentSHA256 else {
            throw ESheepCloudInitialSyncError.associationMismatch("asset")
        }
        value.sheepID = asset.sheepID
        value.metadataDigest = asset.metadataDigest
        value.metadataData = try ESheepCloudCanonicalCodec.encode(asset.metadata)
        value.thumbnailSHA256 = asset.thumbnailSHA256
        value.avatarSHA256 = asset.avatarSHA256
        value.originalSHA256 = asset.originalSHA256
        value.thumbnailStateRawValue = asset.thumbnailState
        value.avatarStateRawValue = asset.avatarState
        value.originalStateRawValue = asset.originalState
        value.thumbnailByteCount = asset.thumbnailByteCount
        value.avatarByteCount = asset.avatarByteCount
        value.originalByteCount = asset.originalByteCount
        if asset.originalState == "verified",
           let originalSHA256 = asset.originalSHA256,
           let photo = try replayContext.photoAsset(id: asset.assetID, context: context) {
            // Asset confirmation is outside the event stream. Reconstruct its
            // verified locator from the same immutable Storage key contract.
            guard photo.farmID == farmID else { throw ESheepCloudInitialSyncError.associationMismatch("asset") }
            photo.cloudRecordName = "\(farmID.uuidString.lowercased())/\(farmGeneration)/\(asset.assetID.uuidString.lowercased())/\(originalSHA256)/original.bin"
        }
        value.updatedAt = .now
    }

    private func farmState() throws -> ESheepCloudFarmState? {
        try replayContext.farmState(
            farmID: farmID,
            generation: farmGeneration,
            context: context
        )
    }

    private func receiptChainDigest(
        previous: String,
        eventDigest: String
    ) -> String {
        SHA256.hash(data: Data("\(previous)\n\(eventDigest)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func seedFarm(
        _ seed: ESheepCloudFarmSeedV2,
        context: ModelContext
    ) throws {
        if let farm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == seed.id }) {
            farm.ownerAccountID = seed.ownerAccountID
            farm.name = seed.name
            farm.roleRawValue = seed.role.rawValue
            farm.membershipStatusRawValue = seed.membershipStatusRawValue
            farm.updatedAt = seed.updatedAt
            farm.locationDisplayName = seed.locationDisplayName
            farm.latitude = seed.latitude
            farm.longitude = seed.longitude
            farm.coordinateReferenceSystem = seed.coordinateReferenceSystem
            farm.addressSnapshot = seed.addressSnapshot
            farm.timeZoneIdentifier = seed.timeZoneIdentifier
            farm.locationSourceRawValue = seed.locationSourceRawValue
            farm.horizontalAccuracyMeters = seed.horizontalAccuracyMeters
            farm.locationUpdatedAt = seed.locationUpdatedAt
        } else {
            let farm = FarmRecord(
                id: seed.id,
                ownerAccountID: seed.ownerAccountID,
                name: seed.name,
                role: seed.role,
                createdAt: seed.createdAt,
                updatedAt: seed.updatedAt
            )
            farm.membershipStatusRawValue = seed.membershipStatusRawValue
            farm.locationDisplayName = seed.locationDisplayName
            farm.latitude = seed.latitude
            farm.longitude = seed.longitude
            farm.coordinateReferenceSystem = seed.coordinateReferenceSystem
            farm.addressSnapshot = seed.addressSnapshot
            farm.timeZoneIdentifier = seed.timeZoneIdentifier
            farm.locationSourceRawValue = seed.locationSourceRawValue
            farm.horizontalAccuracyMeters = seed.horizontalAccuracyMeters
            farm.locationUpdatedAt = seed.locationUpdatedAt
            context.insert(farm)
        }

        if let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: { $0.farmID == seed.id }) {
            profile.modeRawValue = FarmStorageMode.eSheepCloud.rawValue
            profile.transitionStateRawValue = FarmStorageTransitionState.idle.rawValue
            profile.authorityGeneration = max(0, profile.authorityGeneration)
            profile.sourceModeRawValue = nil
            profile.targetModeRawValue = nil
            profile.updatedAt = .now
        } else {
            context.insert(FarmStorageProfile(
                farmID: seed.id,
                mode: .eSheepCloud
            ))
        }

        if let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .first(where: { $0.farmID == seed.id }) {
            binding.ownerAccountID = seed.ownerAccountID
            binding.providerRawValue = FarmRemoteProvider.eSheepCloud.rawValue
            binding.stateRawValue = FarmRemoteBindingState.preparing.rawValue
            binding.remoteFarmID = seed.id.uuidString.lowercased()
            binding.lastErrorCode = nil
            binding.updatedAt = .now
        } else {
            context.insert(FarmRemoteBinding(
                farmID: seed.id,
                ownerAccountID: seed.ownerAccountID,
                provider: .eSheepCloud,
                state: .preparing,
                remoteFarmID: seed.id.uuidString.lowercased()
            ))
        }

        let membershipID = "esheep-cloud:" + seed.id.uuidString.lowercased() +
            ":" + seed.memberAccountID.uuidString.lowercased()
        if let membership = try context.fetch(FetchDescriptor<FarmMembershipBinding>())
            .first(where: {
                $0.farmID == seed.id && $0.accountID == seed.memberAccountID
            }) {
            membership.serverMembershipID = membershipID
            membership.roleRawValue = seed.role.rawValue
            membership.statusRawValue = FarmMembershipStatus.active.rawValue
            membership.updatedAt = .now
        } else {
            context.insert(FarmMembershipBinding(
                serverMembershipID: membershipID,
                farmID: seed.id,
                accountID: seed.memberAccountID,
                role: seed.role,
                status: .active
            ))
        }
    }
}

private final class ESheepCloudStagingProjection: ESheepCloudProjectionTransaction {
    private let container: ModelContainer

    init(
        seed: ESheepCloudFarmSeedV2,
        farmGeneration: Int,
        storeURL: URL,
        resumeExistingStore: Bool = false
    ) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hasExistingFiles = LocalStoreRecoveryService.relatedStoreURLs(for: storeURL)
            .contains { FileManager.default.fileExists(atPath: $0.path) }
        let shouldResume = resumeExistingStore && hasExistingFiles
        if !shouldResume {
            for url in LocalStoreRecoveryService.relatedStoreURLs(for: storeURL)
                where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        container = try AppSchema.makeContainer(
            name: "ESheepCloudInitialVerification",
            url: storeURL
        )
        let projectionContext = ModelContext(container)
        // The only durable verifier checkpoints are complete snapshot chunks
        // or event pages. Disabling SwiftData's autosave prevents a scene
        // suspension halfway through a chunk from publishing a projection
        // prefix that is ahead of the session's persisted checkpoint.
        projectionContext.autosaveEnabled = false
        try super.init(
            context: projectionContext,
            seed: seed,
            farmGeneration: farmGeneration,
            seedEmptyStore: !shouldResume
        )
    }

    override func applySnapshotRecords(
        _ records: [ESheepCloudSnapshotRecordV2],
        skippingEventsThrough: Int64 = 0
    ) throws {
        try super.applySnapshotRecords(
            records,
            skippingEventsThrough: skippingEventsThrough
        )
        try context.save()
    }

    override func applyRecentEvents(_ events: [ESheepCloudEventEnvelopeV2]) throws {
        try super.applyRecentEvents(events)
        try context.save()
    }

    func finishVerification() throws -> ESheepCloudVerifiedProjectionSummary {
        let value = try projectionSummary()
        try context.save()
        return value
    }
}

private final class ESheepCloudActivationTransaction: ESheepCloudProjectionTransaction {
    func commit(
        ifMatching expected: ESheepCloudVerifiedProjectionSummary,
        sessionID: UUID
    ) throws {
        // The staging verifier may have materialized an empty stream from the
        // snapshot row.  The activation copy replays records into a fresh
        // context, so repeat that deterministic materialization before taking
        // the final summary; otherwise a valid zero-event stream would vanish
        // between verification and activation.
        try materializeZeroEventStreamsIfNeeded()
        let actual = try projectionSummary()
        guard actual.eventHead == expected.eventHead,
              actual.projectionDigest == expected.projectionDigest,
              actual.streams == expected.streams,
              actual.assetCount == expected.assetCount,
              let state = try context.fetch(FetchDescriptor<ESheepCloudFarmState>())
                .first(where: { $0.farmID == farmID && $0.farmGeneration == farmGeneration }),
              let session = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
                .first(where: {
                    $0.id == sessionID &&
                        $0.farmID == farmID &&
                        $0.farmGeneration == farmGeneration &&
                        $0.state != .active
                }) else {
            throw ESheepCloudInitialSyncError.eventBoundaryMismatch
        }
        state.cloudEventHead = actual.eventHead
        state.lastVerifiedEventSequence = actual.eventHead
        state.integrityState = .passed
        state.activityState = .active
        state.lastIntegrityCheckAt = .now
        if let storage = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: { $0.farmID == farmID }) {
            storage.modeRawValue = FarmStorageMode.eSheepCloud.rawValue
            storage.transitionStateRawValue = FarmStorageTransitionState.idle.rawValue
            storage.authorityGeneration = farmGeneration
            storage.updatedAt = .now
        }
        if let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .first(where: { $0.farmID == farmID }) {
            binding.providerRawValue = FarmRemoteProvider.eSheepCloud.rawValue
            binding.stateRawValue = FarmRemoteBindingState.active.rawValue
            binding.authorityGeneration = farmGeneration
            binding.lastSuccessfulSyncAt = .now
            binding.lastErrorCode = nil
            binding.updatedAt = .now
        }
        session.targetEventHead = actual.eventHead
        session.state = .active
        session.activatedAt = .now
        try context.save()
    }

    func rollback() {
        context.rollback()
    }
}

private extension String {
    var isSHA256Hex: Bool {
        range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}
