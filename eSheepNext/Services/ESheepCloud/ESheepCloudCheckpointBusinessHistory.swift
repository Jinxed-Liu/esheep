import Foundation
import SwiftData

/// Restores the missing business-only history on already activated devices.
/// It reads only indexed history shards and never replaces an existing farm,
/// rewinds its cursor, deletes receipts, or changes an original pending command.
actor ESheepCloudCheckpointBusinessHistory {
    struct Result: Sendable { let verified: Bool; let inserted: Int }
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    func restore(farmID: UUID, accountID: UUID, generation: Int,
                 gateway: any ESheepCloudGateway,
                 transport: any ESheepCloudCheckpointGateway) async throws -> Result {
        let key = container.configurations.map { $0.url.standardizedFileURL.path }.sorted().joined(separator: "|")
            + "|" + farmID.uuidString
        return try await ESheepCloudBusinessHistoryCycles.shared.run(key: key,
            accountID: accountID, generation: generation) {
                try await self.restoreExclusively(farmID: farmID, accountID: accountID,
                    generation: generation, gateway: gateway, transport: transport)
            }
    }

    private func restoreExclusively(farmID: UUID, accountID: UUID, generation: Int,
                 gateway: any ESheepCloudGateway,
                 transport: any ESheepCloudCheckpointGateway) async throws -> Result {
        let phase = ESheepCloudDiagnostics.Phase("checkpoint-business-history")
        var inserted = 0
        defer { phase.end(items: inserted, fullTableReads: 0) }
        var ticket = try await transport.openCheckpoint(farmID: farmID, farmGeneration: generation, checkpointID: nil)
        guard let manifest = ticket.manifest else { return Result(verified: false, inserted: 0) }
        try manifest.validate()
        guard manifest.chunks.allSatisfy({ $0.modelNames != nil }) else { return Result(verified: false, inserted: 0) }
        guard manifest.farmID == farmID, manifest.farmGeneration == generation,
              let expected = manifest.modelCounts["DomainOperation"] else { throw ESheepCloudCheckpointError.foreignFarm }
        let proofID = StableCloudUUID.derived(namespace: manifest.checkpointID,
            name: "purpose-history-backfill:\(accountID.uuidString.lowercased())")
        let digest = ESheepCloudCheckpointArchive.digest(try ESheepCloudCanonicalCodec.encode(manifest))
        let initial = ModelContext(container)
        guard try hasQuiescentBoundary(manifest, accountID: accountID, manifestDigest: digest,
                                      context: initial) else { return Result(verified: false, inserted: 0) }
        if try initial.fetch(FetchDescriptor<ESheepCloudCheckpointState>(predicate: #Predicate {
            $0.id == proofID && $0.accountID == accountID && $0.stateRawValue == "historyBackfilled"
        })).contains(where: { $0.manifestDigest == digest }) { return Result(verified: true, inserted: 0) }
        var records: [ESheepCloudCheckpointRecord] = []
        for descriptor in manifest.chunks where descriptor.modelNames?.contains("DomainOperation") == true {
            try Task.checkCancellation()
            guard let download = ticket.downloads.first(where: { $0.index == descriptor.index }) else {
                throw ESheepCloudCheckpointError.incomplete
            }
            let data: Data
            do { data = try await transport.downloadCheckpointChunk(download, descriptor: descriptor) }
            catch {
                guard case ESheepCloudInfrastructureError.transferFailed(let status) = error,
                      [400, 401, 403].contains(status) else { throw error }
                ticket = try await transport.openCheckpoint(farmID: farmID, farmGeneration: generation,
                                                            checkpointID: manifest.checkpointID)
                guard let renewed = ticket.manifest,
                      ESheepCloudCheckpointArchive.digest(try ESheepCloudCanonicalCodec.encode(renewed)) == digest,
                      let retry = ticket.downloads.first(where: { $0.index == descriptor.index }) else {
                    throw ESheepCloudCheckpointError.digestMismatch
                }
                data = try await transport.downloadCheckpointChunk(retry, descriptor: descriptor)
            }
            records += try ESheepCloudCheckpointImporter.decode(data, descriptor: descriptor)
                .filter { $0.model == "DomainOperation" }
            guard records.count <= expected else { throw ESheepCloudCheckpointError.duplicateRecord }
        }
        guard records.count == expected else { throw ESheepCloudCheckpointError.incomplete }
        let admission = try await gateway.openInitialSync(farmID: farmID, farmGeneration: generation)
        guard admission.memberAccountID == accountID, admission.membershipStatus == "active",
              admission.farmProfile.farmID == farmID, admission.manifest.farmGeneration == generation,
              admission.expiresAt > .now else { throw ESheepCloudInitialSyncError.accountMismatch }
        try Task.checkCancellation()
        let context = ModelContext(container); context.autosaveEnabled = false
        guard try hasQuiescentBoundary(manifest, accountID: accountID, manifestDigest: digest,
                                      context: context) else { return Result(verified: false, inserted: 0) }
        let adapter = ESheepCloudCheckpointRegistry.adapters.first { $0.name == "DomainOperation" }!
        var seen = Set<UUID>()
        do {
            for row in records {
                try Task.checkCancellation()
                guard case .string(let identifier) = row.values["id"], let id = UUID(uuidString: identifier),
                      seen.insert(id).inserted else { throw ESheepCloudCheckpointError.duplicateRecord }
                var query = FetchDescriptor<DomainOperation>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })
                query.fetchLimit = 1
                if let existing = try context.fetch(query).first {
                    // Date fields export as Double; integral JSON timestamps
                    // decode as Int64. Compare canonical wire content rather
                    // than the enum case chosen by the numeric decoder.
                    guard try ESheepCloudCanonicalCodec.encode(adapter.exportRecord(existing)) ==
                        ESheepCloudCanonicalCodec.encode(row) else { throw ESheepCloudCheckpointError.digestMismatch }
                } else {
                    guard case .string(let sheepIdentifier) = row.values["entityID"],
                          let sheepID = UUID(uuidString: sheepIdentifier),
                          try context.fetchCount(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                              $0.id == sheepID && $0.farmID == farmID
                          })) == 1 else { throw ESheepCloudCheckpointError.incomplete }
                    try adapter.insertRow(row, farmID, context); inserted += 1
                }
            }
            try Task.checkCancellation()
            let proof = try ESheepCloudCheckpointState(manifest: manifest, accountID: accountID)
            proof.id = proofID; proof.stateRawValue = "historyBackfilled"
            context.insert(proof)
            try context.save()
        } catch { context.rollback(); throw error }
        return Result(verified: true, inserted: inserted)
    }

    private func hasQuiescentBoundary(_ manifest: ESheepCloudCheckpointManifest, accountID: UUID,
                                     manifestDigest: String, context: ModelContext) throws -> Bool {
        let farmID = manifest.farmID, generation = manifest.farmGeneration, head = manifest.boundaryEventSequence
        let terminal = ["accepted", "rejected", "supersededLocally"]
        guard try context.fetchCount(FetchDescriptor<FarmRecord>(predicate: #Predicate { $0.id == farmID })) == 1,
              try context.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && !terminal.contains($0.lifecycleRawValue)
        })) == 0,
              try context.fetchCount(FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
                  $0.farmID == farmID && ($0.stateRawValue == "open" || $0.stateRawValue == "resolving")
              })) == 0,
              let state = try context.fetch(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate {
                  $0.farmID == farmID && $0.farmGeneration == generation
              })).first,
              state.integrityState == .passed, state.activityState == .active,
              state.lastAppliedEventSequence >= head else { return false }
        if head == 0 { return true }
        let receipts = try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation && $0.eventSequence == head
        }))
        if receipts.contains(where: { $0.eventDigest == manifest.boundaryEventDigest &&
            $0.appliedProjectionDigest == manifest.receiptChainDigest }) { return true }
        let anchors = try context.fetch(FetchDescriptor<ESheepCloudCheckpointState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation &&
                $0.accountID == accountID && $0.stateRawValue == "active"
        }))
        if anchors.contains(where: { $0.boundaryEventSequence == head &&
            $0.boundaryEventDigest == manifest.boundaryEventDigest && $0.receiptChainDigest == manifest.receiptChainDigest }) {
            return true
        }
        // Activation verifies the checkpoint and its subsequent events before
        // copying the farm. Its anchor advances to that final event head, so
        // the original checkpoint boundary need not have a local receipt.
        // Recognize only this exact manifest and its durable completed session.
        let sessions = try context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation && $0.accountID == accountID
        }))
        if anchors.contains(where: { anchor in
            anchor.id == manifest.checkpointID && anchor.manifestDigest == manifestDigest &&
                anchor.importedChunkCount == manifest.chunks.count && anchor.boundaryEventSequence >= head &&
                state.lastVerifiedEventSequence >= anchor.boundaryEventSequence &&
                state.lastAppliedEventSequence >= state.lastVerifiedEventSequence &&
                sessions.contains(where: {
                    $0.state == .active && $0.snapshotID == anchor.id && $0.activatedAt != nil &&
                        $0.manifestDigest == manifestDigest && $0.boundaryEventSequence == head &&
                        $0.activationProjectionEventSequence == anchor.boundaryEventSequence
                })
        }) { return true }
        throw ESheepCloudCheckpointError.digestMismatch
    }
}

private actor ESheepCloudBusinessHistoryCycles {
    static let shared = ESheepCloudBusinessHistoryCycles()
    private struct Cycle {
        let accountID: UUID
        let generation: Int
        let task: Task<ESheepCloudCheckpointBusinessHistory.Result, Error>
    }
    private var cycles: [String: Cycle] = [:]
    func run(key: String, accountID: UUID, generation: Int,
             operation: @escaping @Sendable () async throws -> ESheepCloudCheckpointBusinessHistory.Result)
        async throws -> ESheepCloudCheckpointBusinessHistory.Result {
        if let existing = cycles[key] {
            guard existing.accountID == accountID, existing.generation == generation else {
                throw ESheepCloudInitialSyncError.accountMismatch
            }
            return try await existing.task.value
        }
        let task = Task { try await operation() }
        cycles[key] = Cycle(accountID: accountID, generation: generation, task: task)
        defer { cycles[key] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
