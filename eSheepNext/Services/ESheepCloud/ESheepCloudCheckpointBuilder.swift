import Foundation
import SwiftData

/// A controlled publication worker: inputs are a sealed SELECT-only export of
/// server records, never a device container. The same reducer as the app builds
/// a private baseline, whose typed projection is exported without protocol logs.
actor ESheepCloudCheckpointBuilder {
    struct Source: Codable, Sendable {
        let project: String
        let farmID: UUID
        let generation: Int
        let head: Int64
    }

    func build(sourceURL: URL, outputURL: URL) throws -> ESheepCloudCheckpointManifest {
        let inventory = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: sourceURL.appending(path: "inventory.json")))
        guard inventory["source.json"] != nil, inventory["profile.json"] != nil else {
            throw ESheepCloudCheckpointError.incomplete
        }
        for (name, hash) in inventory {
            guard !name.contains("/"), !name.contains(".."),
                  ESheepCloudCheckpointArchive.digest(try Data(contentsOf: sourceURL.appending(path: name))) == hash else {
                throw ESheepCloudCheckpointError.digestMismatch
            }
        }
        let source = try JSONDecoder().decode(Source.self,
            from: Data(contentsOf: sourceURL.appending(path: "source.json")))
        let profile = try ESheepCloudCanonicalCodec.decode(ESheepCloudFarmProfileV2.self,
            from: Data(contentsOf: sourceURL.appending(path: "profile.json")))
        guard source.farmID == profile.farmID else { throw ESheepCloudCheckpointError.foreignFarm }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ESheepCloudCheckpointError.incomplete
        }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let container = try AppSchema.makeContainer(name: "CloudCheckpointBaseline",
            url: outputURL.appending(path: "baseline.store"))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let seed = ESheepCloudFarmSeedV2(profile: profile, memberAccountID: profile.ownerAccountID,
                                       memberRole: .owner, membershipStatus: "active")
        let projection = try ESheepCloudProjectionTransaction(context: context, seed: seed,
                                                              farmGeneration: source.generation)
        for prefix in ["streams-", "events-", "assets-"] {
            for name in inventory.keys.filter({ $0.hasPrefix(prefix) }).sorted() {
                try Task.checkCancellation()
                let records = try ESheepCloudSnapshotCodec.decode(
                    Data(contentsOf: sourceURL.appending(path: name)),
                    farmID: source.farmID, farmGeneration: source.generation)
                try projection.applySnapshotRecords(records)
                try context.save()
            }
        }
        try projection.materializeZeroEventStreamsIfNeeded()
        let summary = try projection.projectionSummary()
        guard summary.eventHead == source.head,
              summary.streams.count == projection.expectedStreams.count else {
            throw ESheepCloudCheckpointError.incomplete
        }
        for (key, expected) in projection.expectedStreams {
            guard let actual = summary.streams[key], actual.streamVersion == expected.streamVersion,
                  actual.contentDigest == expected.contentDigest,
                  actual.lastEventSequence == expected.lastEventSequence,
                  actual.fields == Dictionary(uniqueKeysWithValues: expected.fieldVersions.map {
                      ($0.field, ESheepCloudVerifiedFieldSummary(version: $0.version, valueDigest: $0.valueDigest))
                  }) else { throw ESheepCloudCheckpointError.digestMismatch }
        }
        let farmID = source.farmID
        guard let state = try context.fetch(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate {
            $0.farmID == farmID
        })).first else { throw ESheepCloudCheckpointError.incomplete }
        state.integrityState = .passed
        state.activityState = .active
        state.lastVerifiedEventSequence = source.head
        if inventory["approved-recording-metadata.json"] != nil {
            try applyApprovedRecordingMetadata(sourceURL: sourceURL, source: source, context: context)
        }
        try context.save()
        return try ESheepCloudCheckpointArchive.export(farmID: farmID, context: context,
                                                       directory: outputURL.appending(path: "archive"))
    }

    private struct ApprovedRecordingMetadata: Decodable {
        struct Entry: Decodable {
            let model: String
            let id: UUID
            let recordedAtReferenceSeconds: Double
        }
        let farmID: UUID
        let farmGeneration: Int
        let approvalSHA256: String
        let auditSHA256: String
        let entries: [Entry]
    }

    private func applyApprovedRecordingMetadata(sourceURL: URL, source: Source, context: ModelContext) throws {
        let metadata = try JSONDecoder().decode(ApprovedRecordingMetadata.self,
            from: Data(contentsOf: sourceURL.appending(path: "approved-recording-metadata.json")))
        guard metadata.farmID == source.farmID, metadata.farmGeneration == source.generation,
              [metadata.approvalSHA256, metadata.auditSHA256].allSatisfy({
                  $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }
              }) else { throw ESheepCloudCheckpointError.foreignFarm }
        let farmID = source.farmID
        let weights = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate { $0.farmID == farmID })).map { ($0.id, $0) })
        let removals = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate { $0.farmID == farmID })).map { ($0.id, $0) })
        let weanings = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate { $0.farmID == farmID })).map { ($0.id, $0) })
        var seen = Set<String>()
        for entry in metadata.entries {
            guard entry.recordedAtReferenceSeconds.isFinite,
                  seen.insert(entry.model + entry.id.uuidString).inserted else { throw ESheepCloudCheckpointError.malformedRecord }
            let date = Date(timeIntervalSinceReferenceDate: entry.recordedAtReferenceSeconds)
            switch entry.model {
            case "WeightRecord":
                guard let value = weights[entry.id] else { throw ESheepCloudCheckpointError.incomplete }
                value.recordedAt = date
            case "RemovalRecord":
                guard let value = removals[entry.id] else { throw ESheepCloudCheckpointError.incomplete }
                value.recordedAt = date
            case "WeaningRecord":
                guard let value = weanings[entry.id] else { throw ESheepCloudCheckpointError.incomplete }
                value.recordedAt = date
            default: throw ESheepCloudCheckpointError.malformedRecord
            }
        }
    }
}
