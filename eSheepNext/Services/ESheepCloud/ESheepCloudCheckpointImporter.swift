import CryptoKit
import Foundation
import SwiftData

/// Owns only a private verification store. Successful chunks and their durable
/// import cursor commit together; no live farm is replaced by this importer.
actor ESheepCloudCheckpointImporter {
    private let container: ModelContainer
    private let manifest: ESheepCloudCheckpointManifest
    private let accountID: UUID

    init(manifest: ESheepCloudCheckpointManifest, accountID: UUID, storeURL: URL) throws {
        try manifest.validate()
        self.manifest = manifest
        self.accountID = accountID
        container = try AppSchema.makeContainer(name: "CheckpointVerification", url: storeURL)
    }

    func importedChunkCount() throws -> Int {
        let context = ModelContext(container)
        return try checkedState(context)?.importedChunkCount ?? 0
    }

    func importChunk(_ compressed: Data, index: Int) throws {
        try ESheepCloudCheckpointRegistry.validateCoverage()
        guard manifest.chunks.indices.contains(index) else { throw ESheepCloudCheckpointError.malformedRecord }
        let descriptor = manifest.chunks[index]
        let records = try Self.decode(compressed, descriptor: descriptor)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let state: ESheepCloudCheckpointState
        if let existing = try checkedState(context) {
            state = existing
        } else {
            // The verification file is private and must not contain an existing
            // farm or queued user operation when beginning a new import.
            guard try context.fetchCount(FetchDescriptor<FarmRecord>()) == 0,
                  try context.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>()) == 0 else {
                throw ESheepCloudCheckpointError.incomplete
            }
            state = try ESheepCloudCheckpointState(manifest: manifest, accountID: accountID)
            context.insert(state)
        }
        if index < state.importedChunkCount { return }
        guard state.stateRawValue == "importing", index == state.importedChunkCount else {
            throw ESheepCloudCheckpointError.incomplete
        }
        let adapters = Dictionary(uniqueKeysWithValues: ESheepCloudCheckpointRegistry.adapters.map { ($0.name, $0) })
        do {
            for row in records {
                guard let adapter = adapters[row.model] else { throw ESheepCloudCheckpointError.malformedRecord }
                try adapter.insertRow(row, manifest.farmID, context)
            }
            state.importedChunkCount += 1
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func finish() throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let state = try checkedState(context), state.importedChunkCount == manifest.chunks.count else {
            throw ESheepCloudCheckpointError.incomplete
        }
        if state.stateRawValue == "verified" {
            guard let current = try context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first,
                  current.integrityState == .passed,
                  current.lastAppliedEventSequence >= manifest.boundaryEventSequence else {
                throw ESheepCloudCheckpointError.incomplete
            }
            return
        }
        var hasher = SHA256()
        var counts: [String: Int] = [:]
        for adapter in ESheepCloudCheckpointRegistry.adapters where adapter.disposition == .transfer {
            let rows = try adapter.exportRows(manifest.farmID, context)
            var ids = Set<ESheepCloudCheckpointJSONKey>()
            for row in rows {
                guard let id = row.values["id"], case .string(let identifier) = id,
                      UUID(uuidString: identifier) != nil,
                      ids.insert(.init(value: identifier.lowercased())).inserted else {
                    throw ESheepCloudCheckpointError.duplicateRecord
                }
                hasher.update(data: try ESheepCloudCanonicalCodec.encode(row))
                hasher.update(data: Data([10]))
            }
            counts[adapter.name] = rows.count
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard counts == manifest.modelCounts, digest == manifest.businessDigest else {
            throw ESheepCloudCheckpointError.digestMismatch
        }
        // Stream state belongs to exactly the advertised authority generation.
        let farmID = manifest.farmID
        let streams = try context.fetch(FetchDescriptor<ESheepCloudStreamState>(predicate: #Predicate { $0.farmID == farmID }))
        guard streams.allSatisfy({ $0.farmGeneration == manifest.farmGeneration &&
            $0.lastEventSequence <= manifest.boundaryEventSequence }) else {
            throw ESheepCloudCheckpointError.foreignFarm
        }
        let states = try context.fetch(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate { $0.farmID == farmID }))
        let farmState = states.first ?? ESheepCloudFarmState(farmID: farmID, farmGeneration: manifest.farmGeneration)
        guard states.count <= 1 else { throw ESheepCloudCheckpointError.duplicateRecord }
        if states.isEmpty { context.insert(farmState) }
        farmState.lastAppliedEventSequence = manifest.boundaryEventSequence
        farmState.lastVerifiedEventSequence = manifest.boundaryEventSequence
        farmState.cloudEventHead = manifest.boundaryEventSequence
        farmState.projectionDigest = manifest.receiptChainDigest
        farmState.integrityState = .passed
        farmState.activityState = .preparing
        state.stateRawValue = "verified"
        try context.save()
    }

    func currentHead() throws -> Int64 {
        let context = ModelContext(container)
        guard try checkedState(context)?.stateRawValue == "verified",
              let state = try context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first else {
            throw ESheepCloudCheckpointError.incomplete
        }
        return state.lastAppliedEventSequence
    }

    func applyRecentPage(_ page: ESheepCloudEventPageV2) async throws {
        _ = try currentHead()
        let store = ESheepCloudLocalStore(container: container)
        _ = try await store.applyEventPage(page, farmID: manifest.farmID, farmGeneration: manifest.farmGeneration)
    }

    func eventDigest(at sequence: Int64) throws -> String {
        let context = ModelContext(container)
        guard let receipt = try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>(predicate: #Predicate {
            $0.eventSequence == sequence
        })).first else { throw ESheepCloudCheckpointError.incomplete }
        return receipt.eventDigest
    }

    func records(model: String) throws -> [ESheepCloudCheckpointRecord] {
        guard let adapter = ESheepCloudCheckpointRegistry.adapters.first(where: { $0.name == model }),
              adapter.disposition == .transfer else { throw ESheepCloudCheckpointError.malformedRecord }
        return try adapter.exportRows(manifest.farmID, ModelContext(container))
    }

    func verifiedSummary(seed: ESheepCloudFarmSeedV2) throws -> ESheepCloudVerifiedProjectionSummary {
        let context = ModelContext(container)
        let projection = try ESheepCloudProjectionTransaction(context: context, seed: seed,
            farmGeneration: manifest.farmGeneration, seedEmptyStore: false)
        return try projection.projectionSummary()
    }

    static func decode(_ data: Data, descriptor: ESheepCloudCheckpointManifest.Chunk) throws -> [ESheepCloudCheckpointRecord] {
        guard data.count == descriptor.compressedBytes,
              ESheepCloudCheckpointArchive.digest(data) == descriptor.compressedSHA256 else {
            throw ESheepCloudCheckpointError.digestMismatch
        }
        let raw = try ESheepCloudCheckpointGzip.decompress(data, expected: descriptor.uncompressedBytes)
        guard ESheepCloudCheckpointArchive.digest(raw) == descriptor.contentSHA256 else {
            throw ESheepCloudCheckpointError.digestMismatch
        }
        let rows = try ESheepCloudCanonicalCodec.decode([ESheepCloudCheckpointRecord].self, from: raw)
        guard descriptor.modelNames.map({ Set($0) == Set(rows.map(\.model)) }) ?? true else {
            throw ESheepCloudCheckpointError.malformedRecord
        }
        guard rows.count == descriptor.recordCount else { throw ESheepCloudCheckpointError.malformedRecord }
        return rows
    }

    private func checkedState(_ context: ModelContext) throws -> ESheepCloudCheckpointState? {
        let states = try context.fetch(FetchDescriptor<ESheepCloudCheckpointState>())
        guard states.count <= 1 else { throw ESheepCloudCheckpointError.duplicateRecord }
        guard let state = states.first else { return nil }
        guard state.id == manifest.checkpointID, state.farmID == manifest.farmID,
              state.farmGeneration == manifest.farmGeneration, state.accountID == accountID,
              state.manifestDigest == ESheepCloudCheckpointArchive.digest(try ESheepCloudCanonicalCodec.encode(manifest)) else {
            throw ESheepCloudCheckpointError.foreignFarm
        }
        return state
    }
}

private struct ESheepCloudCheckpointJSONKey: Hashable { let value: String }
