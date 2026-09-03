import CryptoKit
import Foundation
import Observation
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
    case associationMismatch(String)
    case existingFarmRequiresMigration
    case farmGenerationChanged

    var errorDescription: String? {
        switch self {
        case .manifestMismatch, .chunkDigestMismatch, .streamMismatch,
             .eventBoundaryMismatch, .countMismatch, .associationMismatch:
            "部分牧场资料没有接收完整。"
        case .insufficientSpace(let bytes):
            "本机空间不足，至少还需要 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))。"
        case .chunkMissing:
            "部分牧场资料尚未接收完成。"
        case .existingFarmRequiresMigration:
            "这座牧场已有本机资料，需要先完成安全迁移，不能按新安装方式覆盖。"
        case .farmGenerationChanged:
            "牧场云端身份已经更新，需要重新接收完整资料。"
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

/// Downloads immutable chunks off the main actor, verifies an isolated V12
/// store, catches up from the snapshot boundary, then commits the same
/// verified event sequence to the active store in one ModelContext save.
actor ESheepCloudInitialSyncCoordinator {
    private let farmID: UUID
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
    ) async {
        self.farmID = farmID
        self.gateway = gateway
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.localStore = await ESheepCloudInitialSyncLocalStore(container: container)
    }

    func prepareNewInstallation(
        expectedFarmGeneration: Int? = nil
    ) async throws -> ESheepCloudInitialSyncReport {
        var sessionID: UUID?
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

            let session = try await localStore.beginOrResume(
                manifest: manifest,
                stagingStoreRelativePath: relativeStagingStorePath(
                    farmID: farmID,
                    snapshotID: manifest.snapshotID
                )
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

            try await localStore.updateSession(sessionID: session.id, state: .verifying)
            let verificationURL = stagingRoot.appending(path: "verification.store")
            var recentEvents: [ESheepCloudEventEnvelopeV2] = []
            let verifiedSummary: ESheepCloudVerifiedProjectionSummary
            // Keep the verification container's lifetime bounded to this
            // scope.  A SwiftData container keeps SQLite WAL/SHM handles
            // alive; releasing it before the activation copy or a failed
            // staging cleanup prevents deleting an open store file.
            do {
                let projection = try await ESheepCloudStagingProjection(
                    seed: seed,
                    farmGeneration: manifest.farmGeneration,
                    storeURL: verificationURL
                )
                for descriptor in manifest.chunks.sorted(by: { $0.index < $1.index }) {
                    let records = try decodeChunk(
                        descriptor: descriptor,
                        manifest: manifest,
                        stagingRoot: stagingRoot
                    )
                    try await projection.applySnapshotRecords(records)
                }
                try await projection.verifySnapshotBoundary(manifest)

                try await localStore.updateSession(
                    sessionID: session.id,
                    state: .applyingRecentChanges
                )
                var after = manifest.boundaryEventSequence
                while true {
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
                        try await projection.applyRecentEvents(page.events)
                        recentEvents.append(contentsOf: page.events)
                        after = page.events.last!.eventSequence
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

                try await localStore.updateSession(sessionID: session.id, state: .buildingIndexes)
                verifiedSummary = try await projection.finishVerification()
            }
            let activation = try await localStore.beginNewFarmActivation(
                seed: seed,
                farmGeneration: manifest.farmGeneration
            )
            do {
                for descriptor in manifest.chunks.sorted(by: { $0.index < $1.index }) {
                    let records = try decodeChunk(
                        descriptor: descriptor,
                        manifest: manifest,
                        stagingRoot: stagingRoot
                    )
                    try await activation.applySnapshotRecords(records)
                }
                try await activation.applyRecentEvents(recentEvents)
                try await activation.commit(
                    ifMatching: verifiedSummary,
                    sessionID: session.id
                )
            } catch {
                await activation.rollback()
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
                    try? await localStore.markPaused(sessionID: sessionID)
                } else {
                    try? await localStore.markFailed(sessionID: sessionID)
                }
            }
            throw error
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
                try await localStore.markChunkVerified(
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
        let url = chunkURL(index: descriptor.index, stagingRoot: stagingRoot)
        var existing = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        if Int64(existing.count) == descriptor.byteCount,
           sha256(existing) == descriptor.contentSHA256 {
            return descriptor
        }
        if Int64(existing.count) > descriptor.byteCount {
            existing = Data()
        }
        let remainder = try await gateway.downloadSnapshotChunk(
            snapshotID: snapshotID,
            chunkIndex: descriptor.index,
            byteOffset: Int64(existing.count)
        )
        var complete = existing
        complete.append(remainder)
        guard Int64(complete.count) == descriptor.byteCount,
              sha256(complete) == descriptor.contentSHA256 else {
            throw ESheepCloudInitialSyncError.chunkDigestMismatch(descriptor.index)
        }
        try complete.write(to: url, options: [.atomic])
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
        snapshotID: UUID
    ) -> String {
        "ESheepCloud/Staging/\(farmID.uuidString.lowercased())/" +
            "\(snapshotID.uuidString.lowercased())/verification.store"
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
}

private struct ESheepCloudVerifiedProjectionSummary: Sendable {
    let eventHead: Int64
    let projectionDigest: String
    let streams: [ESheepCloudStreamReferenceV2: ESheepCloudVerifiedStreamSummary]
    let assetCount: Int
}

private struct ESheepCloudVerifiedStreamSummary: Sendable, Equatable {
    let streamVersion: Int64
    let contentDigest: String
    let lastEventSequence: Int64
    let fields: [String: ESheepCloudVerifiedFieldSummary]
}

private struct ESheepCloudVerifiedFieldSummary: Sendable, Equatable {
    let version: Int64
    let valueDigest: String
}

@MainActor
private final class ESheepCloudInitialSyncLocalStore {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func beginOrResume(
        manifest: ESheepCloudSnapshotManifestV2,
        stagingStoreRelativePath: String
    ) throws -> ESheepCloudInitialSyncSessionSnapshot {
        let context = ModelContext(container)
        let sessions = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .filter { $0.farmID == manifest.farmID && $0.state != .active }
        let session: ESheepCloudInitialSyncSession
        let matching = sessions.filter { $0.snapshotID == manifest.snapshotID }
        let admissions = sessions.filter {
            $0.snapshotID == nil && $0.farmGeneration == manifest.farmGeneration
        }
        guard matching.count <= 1, admissions.count <= 1 else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        if let existing = matching.first {
            guard existing.farmGeneration == manifest.farmGeneration else {
                throw ESheepCloudInitialSyncError.farmGenerationChanged
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
            session = existing
        } else if let admission = admissions.first {
            session = admission
            session.snapshotID = manifest.snapshotID
            session.stagingStoreRelativePath = stagingStoreRelativePath
        } else {
            session = ESheepCloudInitialSyncSession(
                farmID: manifest.farmID,
                farmGeneration: manifest.farmGeneration,
                stagingGeneration: manifest.farmGeneration,
                stagingStoreRelativePath: stagingStoreRelativePath
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
                .deletingLastPathComponent
        )
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

@MainActor
private class ESheepCloudProjectionTransaction {
    let context: ModelContext
    let farmID: UUID
    let farmGeneration: Int
    var expectedStreams: [ESheepCloudStreamReferenceV2: ESheepCloudSnapshotStreamV2] = [:]
    var snapshotStreamCount = 0
    var snapshotEventCount = 0
    var snapshotAssetCount = 0
    var earliestHistoryChange: Date?

    init(
        context: ModelContext,
        seed: ESheepCloudFarmSeedV2,
        farmGeneration: Int
    ) throws {
        self.context = context
        farmID = seed.id
        self.farmGeneration = farmGeneration
        try Self.seedFarm(seed, context: context)
        context.insert(ESheepCloudFarmState(
            farmID: seed.id,
            farmGeneration: farmGeneration,
            activityState: .preparing
        ))
    }

    func applySnapshotRecords(_ records: [ESheepCloudSnapshotRecordV2]) throws {
        for record in records {
            switch record {
            case .stream(let value):
                guard expectedStreams[value.stream] == nil else {
                    throw ESheepCloudInitialSyncError.streamMismatch(value.stream.type)
                }
                expectedStreams[value.stream] = value
                snapshotStreamCount += 1
            case .event(let event):
                let outcome = try ESheepCloudEventReducer.apply(
                    event,
                    context: context,
                    savesChanges: false
                )
                if let changedAt = outcome.historyChangedAt {
                    earliestHistoryChange = min(earliestHistoryChange ?? changedAt, changedAt)
                }
                snapshotEventCount += 1
            case .asset(let asset):
                try upsert(asset: asset)
                snapshotAssetCount += 1
            }
        }
    }

    func applyRecentEvents(_ events: [ESheepCloudEventEnvelopeV2]) throws {
        for event in events {
            let outcome = try ESheepCloudEventReducer.apply(
                event,
                context: context,
                savesChanges: false
            )
            if let changedAt = outcome.historyChangedAt {
                earliestHistoryChange = min(earliestHistoryChange ?? changedAt, changedAt)
            }
        }
    }

    func verifySnapshotBoundary(_ manifest: ESheepCloudSnapshotManifestV2) throws {
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
        guard let state = try farmState(),
              state.lastAppliedEventSequence == manifest.boundaryEventSequence,
              state.projectionDigest == manifest.relationshipDigest else {
            throw ESheepCloudInitialSyncError.eventBoundaryMismatch
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
    fileprivate func materializeZeroEventStreamsIfNeeded() throws {
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
                context.insert(ESheepCloudStreamState(
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
                ))
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
        let existing = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .first { $0.id == asset.assetID && $0.farmID == farmID }
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
        value.updatedAt = .now
    }

    private func farmState() throws -> ESheepCloudFarmState? {
        try context.fetch(FetchDescriptor<ESheepCloudFarmState>())
            .first { $0.farmID == farmID && $0.farmGeneration == farmGeneration }
    }

    private static func seedFarm(
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

@MainActor
private final class ESheepCloudStagingProjection: ESheepCloudProjectionTransaction {
    private let container: ModelContainer

    init(
        seed: ESheepCloudFarmSeedV2,
        farmGeneration: Int,
        storeURL: URL
    ) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in LocalStoreRecoveryService.relatedStoreURLs(for: storeURL)
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        container = try AppSchema.makeContainer(
            name: "ESheepCloudInitialVerification",
            url: storeURL
        )
        try super.init(
            context: ModelContext(container),
            seed: seed,
            farmGeneration: farmGeneration
        )
    }

    override func applySnapshotRecords(_ records: [ESheepCloudSnapshotRecordV2]) throws {
        try super.applySnapshotRecords(records)
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

@MainActor
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
