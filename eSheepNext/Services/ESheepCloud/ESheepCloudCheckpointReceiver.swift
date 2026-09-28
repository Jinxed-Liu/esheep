import Foundation
import SwiftData

/// Coordinators may be recreated by navigation. Serialize receipt by the
/// destination store, rather than only by a particular receiver instance.
private actor ESheepCloudCheckpointReceiveCycles {
    static let shared = ESheepCloudCheckpointReceiveCycles()
    private struct Cycle {
        let accountID: UUID
        let checkpointID: UUID
        let manifestDigest: String
        let task: Task<ESheepCloudInitialSyncReport, Error>
    }
    private var cycles: [String: Cycle] = [:]

    func run(key: String, accountID: UUID, checkpointID: UUID, manifestDigest: String,
             operation: @escaping @Sendable () async throws -> ESheepCloudInitialSyncReport) async throws -> ESheepCloudInitialSyncReport {
        if let existing = cycles[key] {
            guard existing.accountID == accountID else { throw ESheepCloudInitialSyncError.accountMismatch }
            guard existing.checkpointID == checkpointID else { throw ESheepCloudCheckpointError.incomplete }
            guard existing.manifestDigest == manifestDigest else { throw ESheepCloudCheckpointError.digestMismatch }
            return try await existing.task.value
        }
        let task = Task { try await operation() }
        cycles[key] = Cycle(accountID: accountID, checkpointID: checkpointID, manifestDigest: manifestDigest, task: task)
        defer { cycles[key] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

actor ESheepCloudCheckpointReceiver {
    private let container: ModelContainer
    private let support: URL
    private let gateway: any ESheepCloudGateway
    private let transport: any ESheepCloudCheckpointGateway
    private let availableCapacity: @Sendable (URL) throws -> Int64?

    init(container: ModelContainer, support: URL, gateway: any ESheepCloudGateway,
         transport: any ESheepCloudCheckpointGateway,
         availableCapacity: @escaping @Sendable (URL) throws -> Int64? = { url in
             let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
             return values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
         }) {
        self.container = container
        self.support = support
        self.gateway = gateway
        self.transport = transport
        self.availableCapacity = availableCapacity
    }

    func receive(ticket initialTicket: ESheepCloudCheckpointTicket,
                 seed: ESheepCloudFarmSeedV2) async throws -> ESheepCloudInitialSyncReport {
        guard let manifest = initialTicket.manifest else { throw ESheepCloudCheckpointError.incomplete }
        try manifest.validate()
        guard manifest.farmID == seed.id else { throw ESheepCloudCheckpointError.foreignFarm }
        let key = container.configurations.map { $0.url.standardizedFileURL.path }.sorted().joined(separator: "|")
            + "|" + seed.id.uuidString
        return try await ESheepCloudCheckpointReceiveCycles.shared.run(key: key,
            accountID: seed.memberAccountID, checkpointID: manifest.checkpointID,
            manifestDigest: ESheepCloudCheckpointArchive.digest(try ESheepCloudCanonicalCodec.encode(manifest))) {
                try await self.receiveExclusively(ticket: initialTicket, seed: seed)
            }
    }

    private func receiveChunk(_ descriptor: ESheepCloudCheckpointManifest.Chunk,
                              ticket: ESheepCloudCheckpointTicket,
                              manifest: ESheepCloudCheckpointManifest,
                              directory: URL) async throws -> Data {
        try Task.checkCancellation()
        let file = directory.appending(path: String(format: "%05d.json.gz", descriptor.index))
        if let cached = try? Data(contentsOf: file),
           cached.count == descriptor.compressedBytes,
           ESheepCloudCheckpointArchive.digest(cached) == descriptor.compressedSHA256 { return cached }
        let compressed: Data
        do {
            compressed = try await transport.downloadCheckpointChunk(ticket.downloads[descriptor.index], descriptor: descriptor)
        } catch {
            guard case ESheepCloudInfrastructureError.transferFailed(let status) = error,
                  [400, 401, 403].contains(status) else { throw error }
            let renewed = try await transport.openCheckpoint(farmID: manifest.farmID,
                farmGeneration: manifest.farmGeneration, checkpointID: manifest.checkpointID)
            guard renewed.manifest == manifest, renewed.downloads.count == manifest.chunks.count else {
                throw ESheepCloudCheckpointError.incomplete
            }
            compressed = try await transport.downloadCheckpointChunk(renewed.downloads[descriptor.index], descriptor: descriptor)
        }
        try Task.checkCancellation()
        try compressed.write(to: file, options: .atomic)
        return compressed
    }

    private func receiveExclusively(ticket initialTicket: ESheepCloudCheckpointTicket,
                                    seed: ESheepCloudFarmSeedV2) async throws -> ESheepCloudInitialSyncReport {
        guard let manifest = initialTicket.manifest else { throw ESheepCloudCheckpointError.incomplete }
        try manifest.validate()
        let requiredWorkingBytes = manifest.chunks.reduce(Int64(32 * 1024 * 1024)) {
            $0 + Int64($1.compressedBytes) + Int64($1.uncompressedBytes) * 3
        }
        if let available = try availableCapacity(support),
           available < requiredWorkingBytes { throw ESheepCloudCheckpointError.insufficientDiskSpace }
        guard initialTicket.downloads.map(\.index) == Array(manifest.chunks.indices) else {
            throw ESheepCloudCheckpointError.malformedRecord
        }
        guard seed.id == manifest.farmID else { throw ESheepCloudCheckpointError.foreignFarm }
        let relative = "ESheepCloud/Checkpoints/\(seed.memberAccountID.uuidString.lowercased())/" +
            "\(seed.id.uuidString.lowercased())/\(manifest.checkpointID.uuidString.lowercased())"
        let directory = support.appending(path: relative)
        let sessionID = try begin(manifest: manifest, seed: seed, relative: relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ESheepCloudCanonicalCodec.encode(manifest).write(to: directory.appending(path: "manifest.json"), options: .atomic)
        do {
            let importer = try ESheepCloudCheckpointImporter(manifest: manifest,
                accountID: seed.memberAccountID, storeURL: directory.appending(path: "verification.store"))
            var received = 0
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var nextDownload = 0
                var nextImport = 0
                var ready: [Int: Data] = [:]
                func enqueue() {
                    guard nextDownload < manifest.chunks.count else { return }
                    let descriptor = manifest.chunks[nextDownload]
                    nextDownload += 1
                    group.addTask {
                        let data = try await self.receiveChunk(descriptor, ticket: initialTicket,
                            manifest: manifest, directory: directory)
                        return (descriptor.index, data)
                    }
                }
                for _ in 0..<min(3, manifest.chunks.count) { enqueue() }
                while let (index, data) = try await group.next() {
                    ready[index] = data
                    received += data.count
                    try progress(sessionID: sessionID, state: .receiving, received: Int64(received))
                    while let compressed = ready.removeValue(forKey: nextImport) {
                        try Task.checkCancellation()
                        // Start the next transfer while this chunk is imported.
                        enqueue()
                        let phase = ESheepCloudDiagnostics.Phase("checkpoint-import")
                        try await importer.importChunk(compressed, index: nextImport)
                        phase.end(items: manifest.chunks[nextImport].recordCount)
                        try progress(sessionID: sessionID, state: .receiving,
                            received: Int64(received), chunkIndex: nextImport)
                        nextImport += 1
                    }
                }
            }
            try progress(sessionID: sessionID, state: .verifying)
            try await importer.finish()
            try progress(sessionID: sessionID, state: .applyingRecentChanges, head: manifest.boundaryEventSequence)
            while true {
                try Task.checkCancellation()
                let after = try await importer.currentHead()
                let page = try await gateway.pullEvents(farmID: seed.id, farmGeneration: manifest.farmGeneration,
                                                       after: after, limit: 500)
                try await importer.applyRecentPage(page)
                let head = try await importer.currentHead()
                try progress(sessionID: sessionID, state: .applyingRecentChanges, head: head, target: page.cloudHead)
                guard !page.hasMore || head > after else { throw ESheepCloudCheckpointError.incomplete }
                if !page.hasMore { break }
            }
            let expected = try await importer.verifiedSummary(seed: seed)
            // Recheck membership immediately before activation; admission role
            // comes from this account, never from the publisher's FarmRecord.
            let admission = try await gateway.openInitialSync(farmID: seed.id, farmGeneration: manifest.farmGeneration)
            try Task.checkCancellation()
            guard admission.memberAccountID == seed.memberAccountID, admission.membershipStatus == "active",
                  admission.farmProfile.farmID == seed.id,
                  admission.manifest.farmGeneration == manifest.farmGeneration,
                  admission.expiresAt > .now else {
                throw ESheepCloudInitialSyncError.accountMismatch
            }
            let currentSeed = ESheepCloudFarmSeedV2(profile: admission.farmProfile,
                memberAccountID: admission.memberAccountID, memberRole: admission.memberRole,
                membershipStatus: admission.membershipStatus)
            try progress(sessionID: sessionID, state: .activating, head: expected.eventHead)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            try requireEmptyFarm(seed.id, context: context)
            do {
                for adapter in ESheepCloudCheckpointRegistry.adapters where adapter.disposition == .transfer {
                    try Task.checkCancellation()
                    for row in try await importer.records(model: adapter.name) {
                        try adapter.insertRow(row, seed.id, context)
                    }
                }
                try ESheepCloudProjectionTransaction.seedFarm(currentSeed, context: context)
                let state = ESheepCloudFarmState(farmID: seed.id, farmGeneration: manifest.farmGeneration, activityState: .active)
                state.lastAppliedEventSequence = expected.eventHead
                state.lastVerifiedEventSequence = expected.eventHead
                state.cloudEventHead = expected.eventHead
                state.projectionDigest = expected.projectionDigest
                state.integrityState = .passed
                state.lastIntegrityCheckAt = .now
                context.insert(state)
                let anchor = try ESheepCloudCheckpointState(manifest: manifest, accountID: seed.memberAccountID)
                anchor.importedChunkCount = manifest.chunks.count
                anchor.stateRawValue = "active"
                context.insert(anchor)
                // Post-boundary events were verified before copying their
                // resulting business projection. The activation proof covers
                // that final prefix too, so never replay it into this copy.
                anchor.boundaryEventSequence = expected.eventHead
                anchor.receiptChainDigest = expected.projectionDigest
                if expected.eventHead != manifest.boundaryEventSequence {
                    anchor.boundaryEventDigest = try await importer.eventDigest(at: expected.eventHead)
                }
                try FarmHistoryRebuilder().rebuild(farmID: seed.id, context: context)
                let actual = try ESheepCloudProjectionTransaction(context: context, seed: currentSeed,
                    farmGeneration: manifest.farmGeneration, seedEmptyStore: false).projectionSummary()
                guard actual.streams == expected.streams, actual.assetCount == expected.assetCount,
                      actual.eventHead == expected.eventHead, actual.projectionDigest == expected.projectionDigest else {
                    throw ESheepCloudCheckpointError.digestMismatch
                }
                let session = try session(sessionID, context: context)
                session.state = .active
                session.activatedAt = .now
                session.targetEventHead = expected.eventHead
                session.activationProjectionEventSequence = expected.eventHead
                if let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>()).first(where: { $0.farmID == seed.id }) {
                    profile.authorityGeneration = manifest.farmGeneration
                }
                if let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>()).first(where: { $0.farmID == seed.id }) {
                    binding.stateRawValue = FarmRemoteBindingState.active.rawValue
                    binding.authorityGeneration = manifest.farmGeneration
                }
                try Task.checkCancellation()
                // Copying rows awaits the importer and can yield this actor.
                // Recheck persisted state after the last suspension so a new
                // local intent or competing activation cannot be overwritten.
                try requireEmptyFarm(seed.id, context: ModelContext(container))
                _ = try ESheepCloudCompletedCheckpointReceive.reconcile(
                    farmID: seed.id, generation: manifest.farmGeneration,
                    accountID: seed.memberAccountID, context: context)
                try context.save()
            } catch { context.rollback(); throw error }
            // Never unlink a verification store while its container is alive.
            // A later maintenance pass can remove this exact completed scope.
            let readback = ModelContext(container)
            let checkpointID = manifest.checkpointID
            let saved = (try? readback.fetch(FetchDescriptor<ESheepCloudCheckpointState>(predicate: #Predicate {
                $0.id == checkpointID && $0.stateRawValue == "active"
            }))) ?? []
            if let anchor = saved.first, saved.count == 1 {
                let proof = ESheepCloudCheckpointActivationProof(processToken: ESheepCloudCheckpointActivationProof.currentProcessToken,
                    checkpointID: anchor.id, accountID: anchor.accountID, farmID: anchor.farmID,
                    generation: anchor.farmGeneration, eventHead: anchor.boundaryEventSequence, manifestDigest: anchor.manifestDigest)
                try? JSONEncoder().encode(proof).write(to: directory.appending(path: "activation-complete"), options: .atomic)
            }
            return ESheepCloudInitialSyncReport(snapshotID: manifest.checkpointID,
                farmGeneration: manifest.farmGeneration, appliedEventHead: expected.eventHead,
                streamCount: expected.streams.count, assetCount: expected.assetCount,
                receivedByteCount: Int64(received))
        } catch {
            try? progress(sessionID: sessionID, state: error is CancellationError ? .paused : .failed)
            throw error
        }
    }

    private func requireEmptyFarm(_ farmID: UUID, context: ModelContext) throws {
        guard try context.fetchCount(FetchDescriptor<FarmRecord>(predicate: #Predicate { $0.id == farmID })) == 0,
              try context.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate { $0.farmID == farmID })) == 0,
              try context.fetchCount(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate { $0.farmID == farmID })) == 0 else {
            throw ESheepCloudCheckpointError.incomplete
        }
        for adapter in ESheepCloudCheckpointRegistry.adapters where adapter.disposition == .transfer {
            guard try adapter.exportRows(farmID, context).isEmpty else {
                throw ESheepCloudCheckpointError.duplicateRecord
            }
        }
    }

    private func begin(manifest: ESheepCloudCheckpointManifest, seed: ESheepCloudFarmSeedV2, relative: String) throws -> UUID {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try requireEmptyFarm(seed.id, context: context)
        let id = manifest.checkpointID, accountID = seed.memberAccountID
        let existing = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>(predicate: #Predicate {
            $0.snapshotID == id && $0.accountID == accountID
        }))
        guard existing.count <= 1 else { throw ESheepCloudCheckpointError.duplicateRecord }
        // Continue the admission row instead of leaving a second, permanently
        // connecting session behind when checkpoint transport is selected.
        let admission = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .filter { $0.farmID == seed.id && $0.farmGeneration == manifest.farmGeneration &&
                $0.accountID == accountID && $0.snapshotID == nil &&
                $0.manifestData == nil && $0.receivedByteCount == 0 && $0.state != .active }
            .min { $0.startedAt < $1.startedAt }
        let session = existing.first ?? admission ?? ESheepCloudInitialSyncSession(farmID: seed.id,
            farmGeneration: manifest.farmGeneration, stagingGeneration: 1,
            stagingStoreRelativePath: relative + "/verification.store", accountID: accountID)
        if existing.isEmpty && admission == nil { context.insert(session) }
        session.stagingStoreRelativePath = relative + "/verification.store"
        session.snapshotID = id
        session.manifestData = try ESheepCloudCanonicalCodec.encode(manifest)
        session.manifestDigest = try ESheepCloudCanonicalCodec.digest(manifest)
        session.boundaryEventSequence = manifest.boundaryEventSequence
        session.targetEventHead = manifest.boundaryEventSequence
        session.expectedByteCount = Int64(manifest.chunks.reduce(0) { $0 + $1.compressedBytes })
        session.state = .receiving
        try context.save()
        return session.id
    }

    private func session(_ id: UUID, context: ModelContext) throws -> ESheepCloudInitialSyncSession {
        guard let row = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>(predicate: #Predicate { $0.id == id })).first else {
            throw ESheepCloudCheckpointError.incomplete
        }
        return row
    }

    private func progress(sessionID: UUID, state: ESheepCloudInitialSyncState, received: Int64? = nil, head: Int64? = nil, target: Int64? = nil, chunkIndex: Int? = nil) throws {
        let context = ModelContext(container)
        let value = try session(sessionID, context: context)
        value.state = state
        if let received { value.receivedByteCount = received }
        if let head { value.verifiedProjectionEventSequence = head }
        if let target { value.targetEventHead = max(value.targetEventHead, target) }
        if let chunkIndex { value.verifiedChunkIndexesData = try ESheepCloudCanonicalCodec.encode(Array(0...chunkIndex)) }
        value.lastProgressAt = .now
        try context.save()
    }
}

/// Repairs only empty admission metadata after durable checkpoint activation.
/// Callers must validate current server membership before using this on startup
/// or retry. No business rows, queued operations, or staging files are removed.
enum ESheepCloudCompletedCheckpointReceive {
    static func reconcile(farmID: UUID, generation: Int, accountID: UUID,
                          context: ModelContext) throws -> ESheepCloudInitialSyncReport? {
        let anchors = try context.fetch(FetchDescriptor<ESheepCloudCheckpointState>())
            .filter { $0.farmID == farmID && $0.farmGeneration == generation &&
                $0.accountID == accountID && $0.stateRawValue == "active" }
        guard anchors.count == 1, let anchor = anchors.first else { return nil }
        let states = try context.fetch(FetchDescriptor<ESheepCloudFarmState>())
            .filter { $0.farmID == farmID && $0.farmGeneration == generation }
        guard states.count == 1, let state = states.first,
              state.activityState == .active, state.integrityState == .passed,
              state.lastVerifiedEventSequence >= anchor.boundaryEventSequence,
              state.lastAppliedEventSequence >= state.lastVerifiedEventSequence,
              try context.fetchCount(FetchDescriptor<FarmRecord>(predicate: #Predicate { $0.id == farmID })) == 1,
              try context.fetch(FetchDescriptor<FarmRemoteBinding>()).contains(where: {
                  $0.farmID == farmID && $0.provider == .eSheepCloud &&
                      $0.state == .active && $0.authorityGeneration == generation
              }),
              try context.fetch(FetchDescriptor<FarmMembershipBinding>()).contains(where: {
                  $0.farmID == farmID && $0.accountID == accountID && $0.status == .active
              }) else { return nil }
        let sessions = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
            .filter { $0.farmID == farmID && $0.farmGeneration == generation && $0.accountID == accountID }
        guard let completed = sessions.first(where: {
            $0.state == .active && $0.snapshotID == anchor.id &&
                $0.manifestDigest == anchor.manifestDigest && $0.activatedAt != nil &&
                $0.activationProjectionEventSequence == anchor.boundaryEventSequence
        }) else { return nil }
        let streamCount = try context.fetchCount(FetchDescriptor<ESheepCloudStreamState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        }))
        let assetCount = try context.fetchCount(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        }))
        for session in sessions where session.state != .active && session.snapshotID == nil &&
            session.manifestData == nil && session.manifestDigest.isEmpty &&
            session.receivedByteCount == 0 && session.expectedByteCount == 0 &&
            session.verifiedProjectionEventSequence == 0 && session.activationProjectionEventSequence == 0 {
            context.delete(session)
        }
        return ESheepCloudInitialSyncReport(snapshotID: anchor.id, farmGeneration: generation,
            appliedEventHead: state.lastAppliedEventSequence, streamCount: streamCount,
            assetCount: assetCount, receivedByteCount: completed.receivedByteCount)
    }
}
