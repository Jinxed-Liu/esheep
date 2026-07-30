import Foundation
import Supabase

struct SupabaseFarmStorageMetrics: Decodable, Sendable, Equatable {
    let farmID: UUID
    let authorityGeneration: Int
    let currentRevision: Int64
    let entityCount: Int64
    let operationCount: Int64
    let tombstoneCount: Int64
    let registeredAssetCount: Int64
    let registeredAssetBytes: Int64
    let storageObjectCount: Int64
    let storageObjectBytes: Int64
    let duplicateAssetSHACount: Int64
    let checkpointCount: Int64
    let checkpointArchiveBytes: Int64
    let logicalPayloadBytes: Int64

    enum CodingKeys: String, CodingKey {
        case farmID = "farm_id"
        case authorityGeneration = "authority_generation"
        case currentRevision = "current_revision"
        case entityCount = "entity_count"
        case operationCount = "operation_count"
        case tombstoneCount = "tombstone_count"
        case registeredAssetCount = "registered_asset_count"
        case registeredAssetBytes = "registered_asset_bytes"
        case storageObjectCount = "storage_object_count"
        case storageObjectBytes = "storage_object_bytes"
        case duplicateAssetSHACount = "duplicate_asset_sha_count"
        case checkpointCount = "checkpoint_count"
        case checkpointArchiveBytes = "checkpoint_archive_bytes"
        case logicalPayloadBytes = "logical_payload_bytes"
    }
}

struct SupabaseFarmStorageMetricsClient: Sendable {
    private struct Parameters: Encodable, Sendable {
        let p_farm_id: UUID
    }

    let client: SupabaseClient

    func metrics(farmID: UUID) async throws -> SupabaseFarmStorageMetrics? {
        let rows: [SupabaseFarmStorageMetrics] = try await client
            .rpc(
                "get_farm_storage_metrics",
                params: Parameters(p_farm_id: farmID)
            )
            .execute()
            .value
        return rows.first
    }
}
