import Foundation
import SwiftData

struct ESheepCloudCheckpointActivationProof: Codable, Sendable {
    static let currentProcessToken = UUID()
    let processToken: UUID
    let checkpointID: UUID
    let accountID: UUID
    let farmID: UUID
    let generation: Int
    let eventHead: Int64
    let manifestDigest: String
}

/// Handles only the new, explicitly completed checkpoint scope. Legacy Air
/// staging directories require their separate backup/reconciliation inventory.
actor ESheepCloudCheckpointMaintenance {
    private let container: ModelContainer
    private let support: URL
    init(container: ModelContainer, support: URL) { self.container = container; self.support = support.resolvingSymlinksInPath() }

    func removeCompletedReceiveFiles(farmID: UUID, accountID: UUID) throws -> Int64 {
        let context = ModelContext(container)
        let terminal = ["accepted", "rejected", "supersededLocally"]
        guard try context.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && !terminal.contains($0.lifecycleRawValue)
        })) == 0 else { return 0 }
        let active = try context.fetch(FetchDescriptor<ESheepCloudCheckpointState>(predicate: #Predicate {
            $0.farmID == farmID && $0.accountID == accountID && $0.stateRawValue == "active"
        }))
        let farmStates = try context.fetch(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate { $0.farmID == farmID }))
        var removed: Int64 = 0
        for anchor in active {
            guard farmStates.contains(where: { $0.farmGeneration == anchor.farmGeneration &&
                $0.integrityState == .passed && $0.lastVerifiedEventSequence >= anchor.boundaryEventSequence }) else { continue }
            let directory = support.appending(path: "ESheepCloud/Checkpoints/\(accountID.uuidString.lowercased())/\(farmID.uuidString.lowercased())/\(anchor.id.uuidString.lowercased())")
            guard directory.standardizedFileURL == directory.resolvingSymlinksInPath(),
                  let proofData = try? Data(contentsOf: directory.appending(path: "activation-complete")),
                  let proof = try? JSONDecoder().decode(ESheepCloudCheckpointActivationProof.self, from: proofData),
                  proof.processToken != ESheepCloudCheckpointActivationProof.currentProcessToken,
                  proof.checkpointID == anchor.id, proof.accountID == accountID, proof.farmID == farmID,
                  proof.generation == anchor.farmGeneration, proof.eventHead == anchor.boundaryEventSequence,
                  proof.manifestDigest == anchor.manifestDigest else { continue }
            let manifestData = try Data(contentsOf: directory.appending(path: "manifest.json"))
            guard ESheepCloudCheckpointArchive.digest(manifestData) == proof.manifestDigest else {
                throw ESheepCloudCheckpointError.digestMismatch
            }
            let manifest = try ESheepCloudCanonicalCodec.decode(ESheepCloudCheckpointManifest.self, from: manifestData)
            try manifest.validate()
            let names = manifest.chunks.map { String(format: "%05d.json.gz", $0.index) } +
                ["verification.store", "verification.store-wal", "verification.store-shm"]
            // A different process token proves the old process exited and its
            // verification-store handles were closed by the OS.
            for name in names {
                let file = directory.appending(path: name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ESheepCloudCheckpointError.malformedRecord }
                let size = Int64(values.fileSize ?? 0)
                try FileManager.default.removeItem(at: file)
                removed += size
            }
        }
        return removed
    }
}
