import Foundation

struct ESheepCloudCheckpointTicket: Codable, Sendable {
    struct Download: Codable, Sendable { let index: Int; let url: URL }
    let manifest: ESheepCloudCheckpointManifest?
    let downloads: [Download]
}

protocol ESheepCloudCheckpointGateway: Sendable {
    func openCheckpoint(farmID: UUID, farmGeneration: Int, checkpointID: UUID?) async throws -> ESheepCloudCheckpointTicket
    func downloadCheckpointChunk(_ download: ESheepCloudCheckpointTicket.Download,
                                 descriptor: ESheepCloudCheckpointManifest.Chunk) async throws -> Data
}
