import Foundation

/// Server worker input consists exclusively of a verified cloud checkpoint and
/// a SELECT-sealed cloud event prefix. Original historical fields survive by
/// importing the parent rather than replaying pre-checkpoint migrations.
extension ESheepCloudCheckpointBuilder {
    func refresh(sourceURL: URL, outputURL: URL) async throws -> ESheepCloudCheckpointManifest {
        let inventory = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: sourceURL.appending(path: "inventory.json")))
        for required in ["source.json", "profile.json", "parent.json", "parent-manifest.json"] {
            guard inventory[required] != nil else { throw ESheepCloudCheckpointError.incomplete }
        }
        for (name, hash) in inventory {
            guard !name.contains("/"), !name.contains(".."),
                  ESheepCloudCheckpointArchive.digest(try Data(contentsOf: sourceURL.appending(path: name))) == hash else {
                throw ESheepCloudCheckpointError.digestMismatch
            }
        }
        let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: sourceURL.appending(path: "source.json")))
        let raw = try Data(contentsOf: sourceURL.appending(path: "parent-manifest.json"))
        let parent = try ESheepCloudCanonicalCodec.decode(ESheepCloudCheckpointManifest.self, from: raw)
        let attestation = try JSONDecoder().decode(CloudParentAttestation.self,
            from: Data(contentsOf: sourceURL.appending(path: "parent.json")))
        guard attestation.manifest == parent,
              attestation.manifestSHA256 == ESheepCloudCheckpointArchive.digest(raw),
              parent.farmID == source.farmID, parent.farmGeneration == source.generation,
              parent.boundaryEventSequence < source.head else { throw ESheepCloudCheckpointError.foreignFarm }
        let profile = try ESheepCloudCanonicalCodec.decode(ESheepCloudFarmProfileV2.self,
            from: Data(contentsOf: sourceURL.appending(path: "profile.json")))
        guard profile.farmID == source.farmID, !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ESheepCloudCheckpointError.incomplete
        }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let importer = try ESheepCloudCheckpointImporter(manifest: parent, accountID: profile.ownerAccountID,
            storeURL: outputURL.appending(path: "baseline.store"))
        for chunk in parent.chunks {
            let name = String(format: "parent-%05d.gz", chunk.index)
            guard inventory[name] != nil else { throw ESheepCloudCheckpointError.incomplete }
            try await importer.importChunk(Data(contentsOf: sourceURL.appending(path: name)), index: chunk.index)
        }
        try await importer.finish()
        for name in inventory.keys.filter({ $0.hasPrefix("events-") }).sorted() {
            try Task.checkCancellation()
            let records = try ESheepCloudSnapshotCodec.decode(Data(contentsOf: sourceURL.appending(path: name)),
                farmID: source.farmID, farmGeneration: source.generation)
            let events = try records.map { record in
                guard case .event(let event) = record else { throw ESheepCloudCheckpointError.malformedRecord }
                return event
            }
            let current = try await importer.currentHead()
            guard !events.isEmpty, events.map(\.eventSequence) == Array((current + 1)...(current + Int64(events.count))),
                  events.last!.eventSequence <= source.head else { throw ESheepCloudCheckpointError.incomplete }
            try await importer.applyRecentPage(.init(events: events, cloudHead: source.head,
                                                     hasMore: events.last!.eventSequence < source.head))
        }
        var expectations: [ESheepCloudSnapshotRecordV2] = []
        for name in inventory.keys.filter({ $0.hasPrefix("streams-") || $0.hasPrefix("assets-") }).sorted() {
            expectations += try ESheepCloudSnapshotCodec.decode(Data(contentsOf: sourceURL.appending(path: name)),
                farmID: source.farmID, farmGeneration: source.generation)
        }
        let seed = ESheepCloudFarmSeedV2(profile: profile, memberAccountID: profile.ownerAccountID,
            memberRole: .owner, membershipStatus: "active")
        let manifest = try await importer.exportRefreshedCheckpoint(seed: seed, head: source.head,
            expectations: expectations, directory: outputURL.appending(path: "archive"))
        let proof = RefreshProof(passed: true, parentCheckpointID: parent.checkpointID,
            parentManifestSHA256: attestation.manifestSHA256, parentBoundary: parent.boundaryEventSequence,
            boundary: source.head, manifestSHA256: ESheepCloudCheckpointArchive.digest(
                try Data(contentsOf: outputURL.appending(path: "archive/manifest.json"))),
            sourceInventorySHA256: ESheepCloudCheckpointArchive.digest(
                try Data(contentsOf: sourceURL.appending(path: "inventory.json"))))
        try JSONEncoder().encode(proof).write(to: outputURL.appending(path: "refresh-lineage.json"), options: .atomic)
        return manifest
    }
}

private struct CloudParentAttestation: Decodable {
    let manifest: ESheepCloudCheckpointManifest
    let manifestSHA256: String
}

private struct RefreshProof: Encodable {
    let passed: Bool
    let parentCheckpointID: UUID
    let parentManifestSHA256: String
    let parentBoundary: Int64
    let boundary: Int64
    let manifestSHA256: String
    let sourceInventorySHA256: String
}
