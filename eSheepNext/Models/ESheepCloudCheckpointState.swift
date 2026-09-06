import Foundation
import SwiftData

/// The proof boundary replacing individual receipts before a verified checkpoint.
/// It is local state and is never accepted as cloud authority from another phone.
@Model
final class ESheepCloudCheckpointState {
    var id: UUID
    var farmID: UUID
    var farmGeneration: Int
    var accountID: UUID
    var boundaryEventSequence: Int64
    var boundaryEventDigest: String
    var receiptChainDigest: String
    var manifestDigest: String
    var importedChunkCount: Int
    var stateRawValue: String
    var createdAt: Date

    init(manifest: ESheepCloudCheckpointManifest, accountID: UUID) throws {
        id = manifest.checkpointID
        farmID = manifest.farmID
        farmGeneration = manifest.farmGeneration
        self.accountID = accountID
        boundaryEventSequence = manifest.boundaryEventSequence
        boundaryEventDigest = manifest.boundaryEventDigest
        receiptChainDigest = manifest.receiptChainDigest
        manifestDigest = ESheepCloudCheckpointArchive.digest(try ESheepCloudCanonicalCodec.encode(manifest))
        importedChunkCount = 0
        stateRawValue = "importing"
        createdAt = .now
    }
}
