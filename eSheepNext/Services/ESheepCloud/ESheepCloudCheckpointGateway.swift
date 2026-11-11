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

extension ESheepCloudGateway {
    /// A pull is read-only even though the RPC uses HTTP POST. CFNetwork cannot
    /// infer that property and can decline to retry a lost reused connection.
    func pullInitialSyncEvents(farmID: UUID, farmGeneration: Int, after cursor: Int64,
                               limit: Int, onRetry: (Int) async throws -> Void = { _ in }) async throws -> ESheepCloudEventPageV2 {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await pullEvents(farmID: farmID, farmGeneration: farmGeneration,
                                            after: cursor, limit: limit)
            } catch let error as URLError where [
                .networkConnectionLost, .timedOut, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
            ].contains(error.code) {
                try Task.checkCancellation()
                attempt += 1
                try await onRetry(attempt)
                try await Task.sleep(for: .seconds(1 << min(attempt - 1, 5)))
            }
        }
    }
}
