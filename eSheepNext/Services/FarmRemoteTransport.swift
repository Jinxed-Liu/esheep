import CryptoKit
import Foundation
import Supabase

struct FarmRemoteBaseline: Sendable, Equatable {
    let farmID: UUID
    let authorityGeneration: Int
    let throughRevision: Int
    let manifestDigest: String
    let cloudLocator: Data?

    var canActivateWithoutStaging: Bool {
        authorityGeneration == 0 && throughRevision == 0
    }
}

struct FarmAuthorityTransitionRequest: Sendable, Equatable {
    let farmID: UUID
    let migrationID: UUID
    let sourceMode: FarmStorageMode
    let targetGeneration: Int
    let baselineRevision: Int
    let manifestDigest: String
}

struct FarmAuthorityTransitionReceipt: Sendable, Equatable {
    let migrationID: UUID
    let authorityGeneration: Int
    let status: String
}

struct FarmAuthorityTransitionStatus: Sendable, Equatable {
    let migrationID: UUID
    let farmID: UUID
    let authorityGeneration: Int
    let status: String
    let stagedOperationCount: Int
    let stagedAssetCount: Int
    let currentRevision: Int
    let checkpointID: UUID?
}

struct FarmRemoteCheckpoint: Sendable, Equatable {
    let checkpointID: UUID
    let farmID: UUID
    let migrationID: UUID
    let authorityGeneration: Int
    let throughRevision: Int
    let manifest: Data
    let manifestDigest: String
    let operationCount: Int
    let entityCount: Int
    let tombstoneCount: Int
    let assetCount: Int
}

struct FarmCompactAuthorityTransitionStatus: Sendable, Equatable {
    let migrationID: UUID
    let farmID: UUID
    let authorityGeneration: Int
    let status: String
    let stagedProjectionCount: Int
    let stagedTombstoneCount: Int
    let stagedAssetCount: Int
    let currentRevision: Int
    let checkpointID: UUID?
}

struct FarmCompactRemoteCheckpoint: Sendable, Equatable {
    let checkpointID: UUID
    let farmID: UUID
    let migrationID: UUID
    let authorityGeneration: Int
    let throughRevision: Int
    let archive: Data
    let archiveDigest: String
    let archiveByteCount: Int
    let projectionCount: Int
    let tombstoneProjectionCount: Int
    let tombstoneHistoryCount: Int
    let historyOperationCount: Int
    let assetCount: Int
}

struct FarmAuthorityCommitReceipt: Sendable, Equatable {
    let farmID: UUID
    let authorityGeneration: Int
    let currentRevision: Int
    let status: String
}

struct FarmAuthorityCompletionReceipt: Sendable, Equatable {
    let farmID: UUID
    let authorityGeneration: Int
    let currentRevision: Int
    let status: String
    let transitionState: String
}

struct FarmRemoteOperationReceipt: Codable, Sendable, Equatable {
    let operationID: UUID
    let revision: Int
    let serverReceivedAt: Date
}

struct FarmRemotePendingOperation: Sendable, Equatable {
    let envelope: CloudOperationEnvelope
    let clientSequence: Int64
}

struct FarmRemoteOperationPushResult: Sendable, Equatable {
    let receipts: [FarmRemoteOperationReceipt]
    let conflictOperationID: UUID?
    let conflictCode: String?

    static func accepted(_ receipts: [FarmRemoteOperationReceipt]) -> Self {
        Self(
            receipts: receipts,
            conflictOperationID: nil,
            conflictCode: nil
        )
    }
}

struct FarmRemotePullPage: Sendable, Equatable {
    let operations: [CloudOperationEnvelope]
    let cursorRevision: Int
    let hasMore: Bool
}

struct FarmRemoteAsset: Sendable, Equatable {
    let assetID: UUID
    let farmID: UUID
    let sha256: String
    let byteCount: Int64
    let contentType: String
    let storagePath: String
}

struct FarmRemoteMember: Sendable, Equatable {
    let providerUserID: UUID?
    let accountID: UUID
    let role: FarmRole
    let status: FarmMembershipStatus
}

enum SupabaseRealtimeNotification: Sendable, Equatable {
    case subscribed
    case revision(Int)
}

enum FarmRemoteTransportError: LocalizedError {
    case malformedResponse
    case authorityTransitionMissing
    case invalidAssetDigest
    case baselineStagingRequired
    case unsupportedICloudBridgeOperation

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "云端返回的数据不完整或无法验证。"
        case .authorityTransitionMissing:
            "云端没有找到对应的权威迁移任务。"
        case .invalidAssetDigest:
            "附件内容与声明的 SHA-256 摘要不一致。"
        case .baselineStagingRequired:
            "非空牧场必须先完成可验证的暂存基线，不能直接激活 Supabase 权威。"
        case .unsupportedICloudBridgeOperation:
            "该 iCloud 操作尚未接入通用传输桥。"
        }
    }
}

/// Provider-neutral farm authority boundary. Business commands never call a
/// provider directly; they persist DomainOperation/Outbox first, then a
/// provider-specific coordinator invokes this interface.
protocol FarmRemoteTransport: Sendable {
    var provider: FarmRemoteProvider { get }

    func prepareAuthorityTransition(
        _ request: FarmAuthorityTransitionRequest
    ) async throws -> FarmAuthorityTransitionReceipt
    func prepareCompactAuthorityTransition(
        _ request: FarmAuthorityTransitionRequest
    ) async throws -> FarmAuthorityTransitionReceipt
    func stageBaselineOperations(
        _ operations: [FarmRemotePendingOperation],
        request: FarmAuthorityTransitionRequest
    ) async throws -> FarmRemoteOperationPushResult
    func stageBaselineProjections(
        _ projections: [FarmCompactBaselinePackageV1.Projection],
        request: FarmAuthorityTransitionRequest
    ) async throws
    func authorityTransitionStatus(
        farmID: UUID,
        migrationID: UUID
    ) async throws -> FarmAuthorityTransitionStatus
    func compactAuthorityTransitionStatus(
        farmID: UUID,
        migrationID: UUID
    ) async throws -> FarmCompactAuthorityTransitionStatus
    func abortAuthorityTransition(
        farmID: UUID,
        migrationID: UUID
    ) async throws
    func registerCheckpoint(
        _ checkpoint: FarmRemoteCheckpoint
    ) async throws
    func registerCompactCheckpoint(
        _ checkpoint: FarmCompactRemoteCheckpoint,
        manifest: FarmCompactBaselinePackageV1.Manifest
    ) async throws
    func verifyAndCommitAuthority(
        request: FarmAuthorityTransitionRequest,
        checkpointID: UUID
    ) async throws -> FarmAuthorityCommitReceipt
    func verifyAndCommitCompactAuthority(
        request: FarmAuthorityTransitionRequest,
        checkpointID: UUID
    ) async throws -> FarmAuthorityCommitReceipt
    func completeAuthorityTransition(
        farmID: UUID,
        migrationID: UUID,
        authorityGeneration: Int
    ) async throws -> FarmAuthorityCompletionReceipt
    func downloadLatestCheckpoint(
        farmID: UUID,
        authorityGeneration: Int
    ) async throws -> FarmRemoteCheckpoint
    func downloadLatestCompactCheckpoint(
        farmID: UUID,
        authorityGeneration: Int
    ) async throws -> FarmCompactRemoteCheckpoint
    func establishBaseline(_ baseline: FarmRemoteBaseline) async throws
    func pushOperations(
        _ operations: [CloudOperationEnvelope],
        authorityGeneration: Int
    ) async throws -> [FarmRemoteOperationReceipt]
    func pushPendingOperations(
        _ operations: [FarmRemotePendingOperation],
        authorityGeneration: Int
    ) async throws -> FarmRemoteOperationPushResult
    func pullOperations(
        farmID: UUID,
        authorityGeneration: Int,
        after revision: Int,
        limit: Int
    ) async throws -> FarmRemotePullPage
    func uploadAsset(
        farmID: UUID,
        authorityGeneration: Int,
        assetID: UUID,
        data: Data,
        sha256: String,
        contentType: String
    ) async throws -> FarmRemoteAsset
    func downloadAsset(_ asset: FarmRemoteAsset) async throws -> Data
    func members(farmID: UUID) async throws -> [FarmRemoteMember]
    func deactivate(
        farmID: UUID,
        authorityGeneration: Int,
        archive: Bool
    ) async throws
}

extension FarmRemoteTransport {
    func prepareAuthorityTransition(
        _: FarmAuthorityTransitionRequest
    ) async throws -> FarmAuthorityTransitionReceipt {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func stageBaselineOperations(
        _: [FarmRemotePendingOperation],
        request _: FarmAuthorityTransitionRequest
    ) async throws -> FarmRemoteOperationPushResult {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func prepareCompactAuthorityTransition(
        _: FarmAuthorityTransitionRequest
    ) async throws -> FarmAuthorityTransitionReceipt {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func stageBaselineProjections(
        _: [FarmCompactBaselinePackageV1.Projection],
        request _: FarmAuthorityTransitionRequest
    ) async throws {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func registerCheckpoint(_: FarmRemoteCheckpoint) async throws {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func authorityTransitionStatus(
        farmID _: UUID,
        migrationID _: UUID
    ) async throws -> FarmAuthorityTransitionStatus {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func compactAuthorityTransitionStatus(
        farmID _: UUID,
        migrationID _: UUID
    ) async throws -> FarmCompactAuthorityTransitionStatus {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func abortAuthorityTransition(
        farmID _: UUID,
        migrationID _: UUID
    ) async throws {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func verifyAndCommitAuthority(
        request _: FarmAuthorityTransitionRequest,
        checkpointID _: UUID
    ) async throws -> FarmAuthorityCommitReceipt {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func registerCompactCheckpoint(
        _: FarmCompactRemoteCheckpoint,
        manifest _: FarmCompactBaselinePackageV1.Manifest
    ) async throws {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func verifyAndCommitCompactAuthority(
        request _: FarmAuthorityTransitionRequest,
        checkpointID _: UUID
    ) async throws -> FarmAuthorityCommitReceipt {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func completeAuthorityTransition(
        farmID _: UUID,
        migrationID _: UUID,
        authorityGeneration _: Int
    ) async throws -> FarmAuthorityCompletionReceipt {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func downloadLatestCheckpoint(
        farmID _: UUID,
        authorityGeneration _: Int
    ) async throws -> FarmRemoteCheckpoint {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func downloadLatestCompactCheckpoint(
        farmID _: UUID,
        authorityGeneration _: Int
    ) async throws -> FarmCompactRemoteCheckpoint {
        throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
    }

    func pushPendingOperations(
        _ operations: [FarmRemotePendingOperation],
        authorityGeneration: Int
    ) async throws -> FarmRemoteOperationPushResult {
        .accepted(try await pushOperations(
            operations.map(\.envelope),
            authorityGeneration: authorityGeneration
        ))
    }
}

/// The existing CloudKit implementation remains authoritative. These
/// endpoints allow its proven zone/share/checkpoint services to be composed
/// behind the same contract without reimplementing CloudKit in this type.
struct ICloudFarmTransportEndpoints: Sendable {
    let establishBaseline: @Sendable (FarmRemoteBaseline) async throws -> Void
    let pushOperations: @Sendable ([CloudOperationEnvelope], Int) async throws -> [FarmRemoteOperationReceipt]
    let pullOperations: @Sendable (UUID, Int, Int, Int) async throws -> FarmRemotePullPage
    let uploadAsset: @Sendable (UUID, Int, UUID, Data, String, String) async throws -> FarmRemoteAsset
    let downloadAsset: @Sendable (FarmRemoteAsset) async throws -> Data
    let members: @Sendable (UUID) async throws -> [FarmRemoteMember]
    let deactivate: @Sendable (UUID, Int, Bool) async throws -> Void
}

actor ICloudFarmTransport: FarmRemoteTransport {
    nonisolated let provider = FarmRemoteProvider.iCloud
    private let endpoints: ICloudFarmTransportEndpoints

    init(endpoints: ICloudFarmTransportEndpoints) {
        self.endpoints = endpoints
    }

    func establishBaseline(_ baseline: FarmRemoteBaseline) async throws {
        try await endpoints.establishBaseline(baseline)
    }

    func pushOperations(
        _ operations: [CloudOperationEnvelope],
        authorityGeneration: Int
    ) async throws -> [FarmRemoteOperationReceipt] {
        try await endpoints.pushOperations(operations, authorityGeneration)
    }

    func pullOperations(
        farmID: UUID,
        authorityGeneration: Int,
        after revision: Int,
        limit: Int
    ) async throws -> FarmRemotePullPage {
        try await endpoints.pullOperations(
            farmID,
            authorityGeneration,
            revision,
            max(1, limit)
        )
    }

    func uploadAsset(
        farmID: UUID,
        authorityGeneration: Int,
        assetID: UUID,
        data: Data,
        sha256: String,
        contentType: String
    ) async throws -> FarmRemoteAsset {
        try await endpoints.uploadAsset(
            farmID,
            authorityGeneration,
            assetID,
            data,
            sha256,
            contentType
        )
    }

    func downloadAsset(_ asset: FarmRemoteAsset) async throws -> Data {
        try await endpoints.downloadAsset(asset)
    }

    func members(farmID: UUID) async throws -> [FarmRemoteMember] {
        try await endpoints.members(farmID)
    }

    func deactivate(
        farmID: UUID,
        authorityGeneration: Int,
        archive: Bool
    ) async throws {
        try await endpoints.deactivate(farmID, authorityGeneration, archive)
    }
}

actor SupabaseFarmTransport: FarmRemoteTransport {
    private struct BeginTransitionParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_source_provider: String
        let p_target_generation: Int
        let p_baseline_revision: Int
        let p_manifest_digest: String
    }

    private struct BeginCompactTransitionParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_source_provider: String
        let p_target_generation: Int
        let p_archive_digest: String
    }

    private struct BeginTransitionRow: Decodable, Sendable {
        let migrationID: UUID
        let authorityGeneration: Int
        let status: String

        enum CodingKeys: String, CodingKey {
            case migrationID = "migration_id"
            case authorityGeneration = "authority_generation"
            case status
        }
    }

    private struct RegisterFarmParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_provider: String
        let p_cloud_locator: String?
    }

    private struct ActivateFarmParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_expected_generation: Int
        let p_expected_revision: Int
        let p_manifest_digest: String
    }

    private struct ApplyOperationParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_operation_id: UUID
        let p_authority_generation: Int
        let p_entity_type: String
        let p_entity_id: UUID
        let p_base_revision: Int
        let p_resulting_revision: Int
        let p_schema_version: Int
        let p_payload_base64: String
        let p_payload_digest: String
        let p_modified_by_account_id: UUID
        let p_modified_by_device_id: UUID
        let p_capability_certificate: String
        let p_operation_signature: String
        let p_occurred_at: String
        let p_modified_at: String
        let p_deleted_at: String?
    }

    private struct OperationReceiptRow: Decodable, Sendable {
        let operationID: UUID
        let revision: Int
        let serverReceivedAt: Date

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case revision
            case serverReceivedAt = "server_received_at"
        }
    }

    private struct BatchApplyParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_authority_generation: Int
        let p_operations: [BatchOperationPayload]
    }

    private struct StageBatchParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_authority_generation: Int
        let p_operations: [BatchOperationPayload]
    }

    private struct StageProjectionParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_authority_generation: Int
        let p_projections: [CompactProjectionPayload]
    }

    private struct CompactProjectionPayload: Encodable, Sendable {
        let entity_type: String
        let entity_id: UUID
        let revision: Int
        let payload_base64: String
        let payload_digest: String
        let modified_at: String
        let deleted_at: String?
        let replay_order: Int
    }

    private struct CompactProjectionResultRow: Decodable, Sendable {
        let entityType: String
        let entityID: UUID
        let resultStatus: String

        enum CodingKeys: String, CodingKey {
            case entityType = "entity_type"
            case entityID = "entity_id"
            case resultStatus = "result_status"
        }
    }

    private struct TransitionStatusParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_migration_id: UUID
    }

    private struct TransitionStatusRow: Decodable, Sendable {
        let migrationID: UUID
        let farmID: UUID
        let authorityGeneration: Int
        let status: String
        let stagedOperationCount: Int
        let stagedAssetCount: Int
        let currentRevision: Int
        let checkpointID: UUID?

        enum CodingKeys: String, CodingKey {
            case migrationID = "migration_id"
            case farmID = "farm_id"
            case authorityGeneration = "authority_generation"
            case status
            case stagedOperationCount = "staged_operation_count"
            case stagedAssetCount = "staged_asset_count"
            case currentRevision = "current_revision"
            case checkpointID = "checkpoint_id"
        }
    }

    private struct CompactTransitionStatusRow: Decodable, Sendable {
        let migrationID: UUID
        let farmID: UUID
        let authorityGeneration: Int
        let status: String
        let stagedProjectionCount: Int
        let stagedTombstoneCount: Int
        let stagedAssetCount: Int
        let currentRevision: Int
        let checkpointID: UUID?

        enum CodingKeys: String, CodingKey {
            case migrationID = "migration_id"
            case farmID = "farm_id"
            case authorityGeneration = "authority_generation"
            case status
            case stagedProjectionCount = "staged_projection_count"
            case stagedTombstoneCount = "staged_tombstone_count"
            case stagedAssetCount = "staged_asset_count"
            case currentRevision = "current_revision"
            case checkpointID = "checkpoint_id"
        }
    }

    private struct BatchOperationPayload: Encodable, Sendable {
        let operation_id: UUID
        let client_sequence: Int64
        let entity_type: String
        let entity_id: UUID
        let base_revision: Int
        let resulting_revision: Int
        let schema_version: Int
        let payload_base64: String
        let payload_digest: String
        let modified_by_account_id: UUID
        let modified_by_device_id: UUID
        let capability_certificate: String
        let operation_signature: String
        let occurred_at: String
        let modified_at: String
        let deleted_at: String?
    }

    private struct BatchOperationResultRow: Decodable, Sendable {
        let operationID: UUID
        let revision: Int?
        let serverReceivedAt: Date?
        let resultStatus: String
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case revision
            case serverReceivedAt = "server_received_at"
            case resultStatus = "result_status"
            case errorCode = "error_code"
        }
    }

    private struct RegisterCheckpointParameters: Encodable, Sendable {
        let p_checkpoint_id: UUID
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_authority_generation: Int
        let p_through_revision: Int
        let p_manifest: [String: String]
        let p_manifest_digest: String
        let p_storage_path: String
        let p_operation_count: Int
        let p_entity_count: Int
        let p_tombstone_count: Int
        let p_asset_count: Int
    }

    private struct RegisterCompactCheckpointParameters: Encodable, Sendable {
        let p_checkpoint_id: UUID
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_authority_generation: Int
        let p_archive_digest: String
        let p_archive_byte_count: Int
        let p_storage_path: String
        let p_manifest: FarmCompactBaselinePackageV1.Manifest
        let p_projection_count: Int
        let p_tombstone_projection_count: Int
        let p_tombstone_history_count: Int
        let p_history_operation_count: Int
        let p_asset_count: Int
    }

    private struct CheckpointRow: Decodable, Sendable {
        let checkpointID: UUID
        let farmID: UUID
        let migrationID: UUID
        let authorityGeneration: Int
        let throughRevision: Int
        let manifestDigest: String
        let storagePath: String
        let operationCount: Int
        let entityCount: Int
        let tombstoneCount: Int
        let assetCount: Int

        enum CodingKeys: String, CodingKey {
            case checkpointID = "checkpoint_id"
            case farmID = "farm_id"
            case migrationID = "migration_id"
            case authorityGeneration = "authority_generation"
            case throughRevision = "through_revision"
            case manifestDigest = "manifest_digest"
            case storagePath = "storage_path"
            case operationCount = "operation_count"
            case entityCount = "entity_count"
            case tombstoneCount = "tombstone_count"
            case assetCount = "asset_count"
        }
    }

    private struct CompactCheckpointRow: Decodable, Sendable {
        let checkpointID: UUID
        let farmID: UUID
        let migrationID: UUID
        let authorityGeneration: Int
        let throughRevision: Int
        let archiveDigest: String
        let archiveByteCount: Int
        let storagePath: String
        let entityCount: Int
        let tombstoneCount: Int
        let tombstoneHistoryCount: Int
        let historyOperationCount: Int
        let assetCount: Int
        let verifiedAt: Date?

        enum CodingKeys: String, CodingKey {
            case checkpointID = "checkpoint_id"
            case farmID = "farm_id"
            case migrationID = "migration_id"
            case authorityGeneration = "authority_generation"
            case throughRevision = "through_revision"
            case archiveDigest = "archive_digest"
            case archiveByteCount = "archive_byte_count"
            case storagePath = "storage_path"
            case entityCount = "entity_count"
            case tombstoneCount = "tombstone_count"
            case tombstoneHistoryCount = "tombstone_history_count"
            case historyOperationCount = "history_operation_count"
            case assetCount = "asset_count"
            case verifiedAt = "verified_at"
        }
    }

    private struct VerifyAuthorityParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_checkpoint_id: UUID
        let p_expected_generation: Int
        let p_manifest_digest: String
    }

    private struct VerifyCompactAuthorityParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_checkpoint_id: UUID
        let p_expected_generation: Int
        let p_archive_digest: String
    }

    private struct CompleteAuthorityParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_migration_id: UUID
        let p_expected_generation: Int
    }

    private struct VerifyAuthorityRow: Decodable, Sendable {
        let farmID: UUID
        let authorityGeneration: Int
        let currentRevision: Int
        let status: String

        enum CodingKeys: String, CodingKey {
            case farmID = "farm_id"
            case authorityGeneration = "authority_generation"
            case currentRevision = "current_revision"
            case status
        }
    }

    private struct CompleteAuthorityRow: Decodable, Sendable {
        let farmID: UUID
        let authorityGeneration: Int
        let currentRevision: Int
        let status: String
        let transitionState: String

        enum CodingKeys: String, CodingKey {
            case farmID = "farm_id"
            case authorityGeneration = "authority_generation"
            case currentRevision = "current_revision"
            case status
            case transitionState = "transition_state"
        }
    }

    private struct OperationRow: Decodable, Sendable {
        let operationID: UUID
        let farmID: UUID
        let authorityGeneration: Int
        let revision: Int
        let baseRevision: Int
        let resultingRevision: Int
        let schemaVersion: Int
        let entityType: String
        let entityID: UUID
        let modifiedByAccountID: UUID
        let modifiedByDeviceID: UUID
        let payloadBase64: String
        let payloadDigest: String
        let capabilityCertificate: String
        let operationSignature: String?
        let deletedAt: Date?
        let occurredAt: Date
        let modifiedAt: Date

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case farmID = "farm_id"
            case authorityGeneration = "authority_generation"
            case revision
            case baseRevision = "base_revision"
            case resultingRevision = "resulting_revision"
            case schemaVersion = "schema_version"
            case entityType = "entity_type"
            case entityID = "entity_id"
            case modifiedByAccountID = "modified_by_account_id"
            case modifiedByDeviceID = "modified_by_device_id"
            case payloadBase64 = "payload_base64"
            case payloadDigest = "payload_digest"
            case capabilityCertificate = "capability_certificate"
            case operationSignature = "operation_signature"
            case deletedAt = "deleted_at"
            case occurredAt = "occurred_at"
            case modifiedAt = "modified_at"
        }
    }

    private struct RegisterAssetParameters: Encodable, Sendable {
        let p_asset_id: UUID
        let p_farm_id: UUID
        let p_authority_generation: Int
        let p_sha256: String
        let p_storage_path: String
        let p_byte_count: Int64
        let p_content_type: String
    }

    private struct AssetRow: Decodable, Sendable {
        let assetID: UUID
        let storagePath: String

        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case storagePath = "storage_path"
        }
    }

    private struct RegisteredAssetRow: Decodable, Sendable {
        let assetID: UUID
        let farmID: UUID
        let sha256: String
        let storagePath: String
        let byteCount: Int64
        let contentType: String

        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case farmID = "farm_id"
            case sha256
            case storagePath = "storage_path"
            case byteCount = "byte_count"
            case contentType = "content_type"
        }
    }

    private struct MemberRow: Decodable, Sendable {
        let userID: UUID
        let appAccountID: UUID
        let role: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case appAccountID = "app_account_id"
            case role
            case status
        }
    }

    private struct DeactivateParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_expected_generation: Int
        let p_archive: Bool
    }

    nonisolated let provider = FarmRemoteProvider.supabase
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func prepareAuthorityTransition(
        _ request: FarmAuthorityTransitionRequest
    ) async throws -> FarmAuthorityTransitionReceipt {
        let rows: [BeginTransitionRow] = try await client.rpc(
            "begin_farm_authority_transition",
            params: BeginTransitionParameters(
                p_farm_id: request.farmID,
                p_migration_id: request.migrationID,
                p_source_provider: request.sourceMode == .localOnly
                    ? "local_only"
                    : request.sourceMode.rawValue.lowercased(),
                p_target_generation: request.targetGeneration,
                p_baseline_revision: request.baselineRevision,
                p_manifest_digest: request.manifestDigest
            )
        ).execute().value
        guard let row = rows.first else {
            throw FarmRemoteTransportError.authorityTransitionMissing
        }
        return FarmAuthorityTransitionReceipt(
            migrationID: row.migrationID,
            authorityGeneration: row.authorityGeneration,
            status: row.status
        )
    }

    func prepareCompactAuthorityTransition(
        _ request: FarmAuthorityTransitionRequest
    ) async throws -> FarmAuthorityTransitionReceipt {
        let rows: [BeginTransitionRow] = try await client.rpc(
            "begin_compact_farm_authority_transition",
            params: BeginCompactTransitionParameters(
                p_farm_id: request.farmID,
                p_migration_id: request.migrationID,
                p_source_provider: request.sourceMode == .localOnly
                    ? "local_only"
                    : request.sourceMode.rawValue.lowercased(),
                p_target_generation: request.targetGeneration,
                p_archive_digest: request.manifestDigest
            )
        ).execute().value
        guard let row = rows.first else {
            throw FarmRemoteTransportError.authorityTransitionMissing
        }
        return FarmAuthorityTransitionReceipt(
            migrationID: row.migrationID,
            authorityGeneration: row.authorityGeneration,
            status: row.status
        )
    }

    func stageBaselineOperations(
        _ operations: [FarmRemotePendingOperation],
        request: FarmAuthorityTransitionRequest
    ) async throws -> FarmRemoteOperationPushResult {
        guard !operations.isEmpty, operations.count <= 25 else {
            return .accepted([])
        }
        let payloads = operations.sorted {
            $0.clientSequence < $1.clientSequence
        }.map(Self.batchPayload(from:))
        let rows: [BatchOperationResultRow] = try await client.rpc(
            "stage_farm_baseline_batch",
            params: StageBatchParameters(
                p_farm_id: request.farmID,
                p_migration_id: request.migrationID,
                p_authority_generation: request.targetGeneration,
                p_operations: payloads
            )
        ).execute().value
        return try Self.pushResult(from: rows)
    }

    func stageBaselineProjections(
        _ projections: [FarmCompactBaselinePackageV1.Projection],
        request: FarmAuthorityTransitionRequest
    ) async throws {
        guard !projections.isEmpty, projections.count <= 100 else {
            if projections.isEmpty { return }
            throw FarmRemoteTransportError.malformedResponse
        }
        let payloads = projections.map {
            CompactProjectionPayload(
                entity_type: $0.entityType,
                entity_id: $0.entityID,
                revision: $0.revision,
                payload_base64: $0.payload.base64EncodedString(),
                payload_digest: $0.payloadDigest,
                modified_at: CloudDateText.string(from: $0.modifiedAt),
                deleted_at: $0.deletedAt.map(CloudDateText.string(from:)),
                replay_order: $0.replayOrder
            )
        }
        let rows: [CompactProjectionResultRow] = try await client.rpc(
            "stage_farm_projection_batch",
            params: StageProjectionParameters(
                p_farm_id: request.farmID,
                p_migration_id: request.migrationID,
                p_authority_generation: request.targetGeneration,
                p_projections: payloads
            )
        ).execute().value
        guard rows.count == projections.count,
              rows.allSatisfy({ $0.resultStatus == "accepted" }),
              Set(rows.map(\.entityID)) == Set(projections.map(\.entityID)) else {
            throw FarmRemoteTransportError.malformedResponse
        }
    }

    func authorityTransitionStatus(
        farmID: UUID,
        migrationID: UUID
    ) async throws -> FarmAuthorityTransitionStatus {
        let rows: [TransitionStatusRow] = try await client.rpc(
            "get_farm_authority_transition_status",
            params: TransitionStatusParameters(
                p_farm_id: farmID,
                p_migration_id: migrationID
            )
        ).execute().value
        guard let row = rows.first else {
            throw FarmRemoteTransportError.authorityTransitionMissing
        }
        return FarmAuthorityTransitionStatus(
            migrationID: row.migrationID,
            farmID: row.farmID,
            authorityGeneration: row.authorityGeneration,
            status: row.status,
            stagedOperationCount: row.stagedOperationCount,
            stagedAssetCount: row.stagedAssetCount,
            currentRevision: row.currentRevision,
            checkpointID: row.checkpointID
        )
    }

    func compactAuthorityTransitionStatus(
        farmID: UUID,
        migrationID: UUID
    ) async throws -> FarmCompactAuthorityTransitionStatus {
        let rows: [CompactTransitionStatusRow] = try await client.rpc(
            "get_compact_authority_transition_status",
            params: TransitionStatusParameters(
                p_farm_id: farmID,
                p_migration_id: migrationID
            )
        ).execute().value
        guard let row = rows.first else {
            throw FarmRemoteTransportError.authorityTransitionMissing
        }
        return FarmCompactAuthorityTransitionStatus(
            migrationID: row.migrationID,
            farmID: row.farmID,
            authorityGeneration: row.authorityGeneration,
            status: row.status,
            stagedProjectionCount: row.stagedProjectionCount,
            stagedTombstoneCount: row.stagedTombstoneCount,
            stagedAssetCount: row.stagedAssetCount,
            currentRevision: row.currentRevision,
            checkpointID: row.checkpointID
        )
    }

    func abortAuthorityTransition(
        farmID: UUID,
        migrationID: UUID
    ) async throws {
        try await client.rpc(
            "abort_farm_authority_transition",
            params: TransitionStatusParameters(
                p_farm_id: farmID,
                p_migration_id: migrationID
            )
        ).execute()
    }

    func registerCheckpoint(_ checkpoint: FarmRemoteCheckpoint) async throws {
        let path = "\(checkpoint.farmID.uuidString.lowercased())/" +
            "\(checkpoint.migrationID.uuidString.lowercased())/" +
            "\(checkpoint.manifestDigest).json"
        try await client.storage
            .from("farm-checkpoints")
            .upload(
                path,
                data: checkpoint.manifest,
                options: FileOptions(contentType: "application/json", upsert: true)
            )
        let manifest = [
            "digest": checkpoint.manifestDigest,
            "schema": "esheepnext.farm-checkpoint.v1",
        ]
        try await client.rpc(
            "register_farm_checkpoint",
            params: RegisterCheckpointParameters(
                p_checkpoint_id: checkpoint.checkpointID,
                p_farm_id: checkpoint.farmID,
                p_migration_id: checkpoint.migrationID,
                p_authority_generation: checkpoint.authorityGeneration,
                p_through_revision: checkpoint.throughRevision,
                p_manifest: manifest,
                p_manifest_digest: checkpoint.manifestDigest,
                p_storage_path: path,
                p_operation_count: checkpoint.operationCount,
                p_entity_count: checkpoint.entityCount,
                p_tombstone_count: checkpoint.tombstoneCount,
                p_asset_count: checkpoint.assetCount
            )
        ).execute()
    }

    func registerCompactCheckpoint(
        _ checkpoint: FarmCompactRemoteCheckpoint,
        manifest: FarmCompactBaselinePackageV1.Manifest
    ) async throws {
        guard checkpoint.archive.count == checkpoint.archiveByteCount,
              Self.digest(checkpoint.archive) == checkpoint.archiveDigest else {
            throw FarmRemoteTransportError.invalidAssetDigest
        }
        let path = "\(checkpoint.farmID.uuidString.lowercased())/" +
            "\(checkpoint.migrationID.uuidString.lowercased())/" +
            "\(checkpoint.archiveDigest).esbc"
        do {
            try await registerCompactCheckpointMetadata(
                checkpoint,
                manifest: manifest,
                storagePath: path
            )
            return
        } catch let error as PostgrestError
            where error.code == "23503" &&
                error.message == "compact_checkpoint_object_missing" {
            // Upload only when the immutable digest path is absent. A resumed
            // migration can register an already verified object immediately.
        }
        try await client.storage
            .from("farm-checkpoints")
            .upload(
                path,
                data: checkpoint.archive,
                options: FileOptions(
                    contentType: "application/vnd.esheepnext.checkpoint",
                    upsert: true
                )
            )
        try await registerCompactCheckpointMetadata(
            checkpoint,
            manifest: manifest,
            storagePath: path
        )
    }

    private func registerCompactCheckpointMetadata(
        _ checkpoint: FarmCompactRemoteCheckpoint,
        manifest: FarmCompactBaselinePackageV1.Manifest,
        storagePath: String
    ) async throws {
        try await client.rpc(
            "register_compact_farm_checkpoint",
            params: RegisterCompactCheckpointParameters(
                p_checkpoint_id: checkpoint.checkpointID,
                p_farm_id: checkpoint.farmID,
                p_migration_id: checkpoint.migrationID,
                p_authority_generation: checkpoint.authorityGeneration,
                p_archive_digest: checkpoint.archiveDigest,
                p_archive_byte_count: checkpoint.archiveByteCount,
                p_storage_path: storagePath,
                p_manifest: manifest,
                p_projection_count: checkpoint.projectionCount,
                p_tombstone_projection_count:
                    checkpoint.tombstoneProjectionCount,
                p_tombstone_history_count: checkpoint.tombstoneHistoryCount,
                p_history_operation_count: checkpoint.historyOperationCount,
                p_asset_count: checkpoint.assetCount
            )
        ).execute()
    }

    func verifyAndCommitAuthority(
        request: FarmAuthorityTransitionRequest,
        checkpointID: UUID
    ) async throws -> FarmAuthorityCommitReceipt {
        let rows: [VerifyAuthorityRow] = try await client.rpc(
            "verify_and_activate_farm_authority",
            params: VerifyAuthorityParameters(
                p_farm_id: request.farmID,
                p_migration_id: request.migrationID,
                p_checkpoint_id: checkpointID,
                p_expected_generation: request.targetGeneration,
                p_manifest_digest: request.manifestDigest
            )
        ).execute().value
        guard let row = rows.first else {
            throw FarmRemoteTransportError.malformedResponse
        }
        return FarmAuthorityCommitReceipt(
            farmID: row.farmID,
            authorityGeneration: row.authorityGeneration,
            currentRevision: row.currentRevision,
            status: row.status
        )
    }

    func verifyAndCommitCompactAuthority(
        request: FarmAuthorityTransitionRequest,
        checkpointID: UUID
    ) async throws -> FarmAuthorityCommitReceipt {
        let rows: [VerifyAuthorityRow] = try await client.rpc(
            "verify_and_activate_compact_farm_authority",
            params: VerifyCompactAuthorityParameters(
                p_farm_id: request.farmID,
                p_migration_id: request.migrationID,
                p_checkpoint_id: checkpointID,
                p_expected_generation: request.targetGeneration,
                p_archive_digest: request.manifestDigest
            )
        ).execute().value
        guard let row = rows.first else {
            throw FarmRemoteTransportError.malformedResponse
        }
        return FarmAuthorityCommitReceipt(
            farmID: row.farmID,
            authorityGeneration: row.authorityGeneration,
            currentRevision: row.currentRevision,
            status: row.status
        )
    }

    func completeAuthorityTransition(
        farmID: UUID,
        migrationID: UUID,
        authorityGeneration: Int
    ) async throws -> FarmAuthorityCompletionReceipt {
        let rows: [CompleteAuthorityRow] = try await client.rpc(
            "complete_farm_authority_transition",
            params: CompleteAuthorityParameters(
                p_farm_id: farmID,
                p_migration_id: migrationID,
                p_expected_generation: authorityGeneration
            )
        ).execute().value
        guard let row = rows.first,
              row.farmID == farmID,
              row.authorityGeneration == authorityGeneration,
              row.status == "active",
              row.transitionState == "completed" else {
            throw FarmRemoteTransportError.malformedResponse
        }
        return FarmAuthorityCompletionReceipt(
            farmID: row.farmID,
            authorityGeneration: row.authorityGeneration,
            currentRevision: row.currentRevision,
            status: row.status,
            transitionState: row.transitionState
        )
    }

    func downloadLatestCheckpoint(
        farmID: UUID,
        authorityGeneration: Int
    ) async throws -> FarmRemoteCheckpoint {
        let rows: [CheckpointRow] = try await client
            .from("farm_checkpoints")
            .select(
                "checkpoint_id,farm_id,migration_id,authority_generation," +
                    "through_revision,manifest_digest,storage_path," +
                    "operation_count,entity_count,tombstone_count,asset_count"
            )
            .eq("farm_id", value: farmID)
            .eq("authority_generation", value: authorityGeneration)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else {
            throw FarmRemoteTransportError.malformedResponse
        }
        let data = try await client.storage
            .from("farm-checkpoints")
            .download(path: row.storagePath)
        guard Self.digest(data) == row.manifestDigest else {
            throw FarmRemoteTransportError.invalidAssetDigest
        }
        return FarmRemoteCheckpoint(
            checkpointID: row.checkpointID,
            farmID: row.farmID,
            migrationID: row.migrationID,
            authorityGeneration: row.authorityGeneration,
            throughRevision: row.throughRevision,
            manifest: data,
            manifestDigest: row.manifestDigest,
            operationCount: row.operationCount,
            entityCount: row.entityCount,
            tombstoneCount: row.tombstoneCount,
            assetCount: row.assetCount
        )
    }

    func downloadLatestCompactCheckpoint(
        farmID: UUID,
        authorityGeneration: Int
    ) async throws -> FarmCompactRemoteCheckpoint {
        let rows: [CompactCheckpointRow] = try await client
            .from("farm_checkpoints")
            .select(
                "checkpoint_id,farm_id,migration_id,authority_generation," +
                    "through_revision,archive_digest,archive_byte_count,storage_path," +
                    "entity_count,tombstone_count,tombstone_history_count," +
                    "history_operation_count,asset_count,verified_at"
            )
            .eq("farm_id", value: farmID)
            .eq("authority_generation", value: authorityGeneration)
            .eq("checkpoint_format", value: "compact_v1")
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        guard let row = rows.first, row.verifiedAt != nil else {
            throw FarmRemoteTransportError.malformedResponse
        }
        let data = try await client.storage
            .from("farm-checkpoints")
            .download(path: row.storagePath)
        guard data.count == row.archiveByteCount,
              Self.digest(data) == row.archiveDigest else {
            throw FarmRemoteTransportError.invalidAssetDigest
        }
        return FarmCompactRemoteCheckpoint(
            checkpointID: row.checkpointID,
            farmID: row.farmID,
            migrationID: row.migrationID,
            authorityGeneration: row.authorityGeneration,
            throughRevision: row.throughRevision,
            archive: data,
            archiveDigest: row.archiveDigest,
            archiveByteCount: row.archiveByteCount,
            projectionCount: row.entityCount,
            tombstoneProjectionCount: row.tombstoneCount,
            tombstoneHistoryCount: row.tombstoneHistoryCount,
            historyOperationCount: row.historyOperationCount,
            assetCount: row.assetCount
        )
    }

    func establishBaseline(_ baseline: FarmRemoteBaseline) async throws {
        guard baseline.canActivateWithoutStaging else {
            throw FarmRemoteTransportError.baselineStagingRequired
        }
        let locator = baseline.cloudLocator.flatMap { String(data: $0, encoding: .utf8) }
        try await client.rpc(
            "register_farm_authority",
            params: RegisterFarmParameters(
                p_farm_id: baseline.farmID,
                p_provider: FarmRemoteProvider.supabase.rawValue,
                p_cloud_locator: locator
            )
        ).execute()
        try await client.rpc(
            "activate_farm_authority",
            params: ActivateFarmParameters(
                p_farm_id: baseline.farmID,
                p_expected_generation: baseline.authorityGeneration,
                p_expected_revision: baseline.throughRevision,
                p_manifest_digest: baseline.manifestDigest
            )
        ).execute()
    }

    func pushOperations(
        _ operations: [CloudOperationEnvelope],
        authorityGeneration: Int
    ) async throws -> [FarmRemoteOperationReceipt] {
        var receipts: [FarmRemoteOperationReceipt] = []
        receipts.reserveCapacity(operations.count)
        for operation in operations {
            let rows: [OperationReceiptRow] = try await client.rpc(
                "apply_farm_operation",
                params: ApplyOperationParameters(
                    p_farm_id: operation.farmID,
                    p_operation_id: operation.operationID,
                    p_authority_generation: authorityGeneration,
                    p_entity_type: operation.entityType,
                    p_entity_id: operation.entityID,
                    p_base_revision: operation.baseRevision,
                    p_resulting_revision: operation.revision,
                    p_schema_version: operation.schemaVersion,
                    p_payload_base64: operation.payload.base64EncodedString(),
                    p_payload_digest: operation.payloadDigest,
                    p_modified_by_account_id: operation.modifiedByAccountID,
                    p_modified_by_device_id: operation.modifiedByDeviceID,
                    p_capability_certificate: operation.capabilityCertificate,
                    p_operation_signature: operation.operationSignature.base64EncodedString(),
                    p_occurred_at: CloudDateText.string(from: operation.modifiedAt),
                    p_modified_at: CloudDateText.string(from: operation.modifiedAt),
                    p_deleted_at: operation.deletedAt.map(CloudDateText.string(from:))
                )
            ).execute().value
            guard let row = rows.first else { throw FarmRemoteTransportError.malformedResponse }
            receipts.append(FarmRemoteOperationReceipt(
                operationID: row.operationID,
                revision: row.revision,
                serverReceivedAt: row.serverReceivedAt
            ))
        }
        return receipts
    }

    func pushPendingOperations(
        _ operations: [FarmRemotePendingOperation],
        authorityGeneration: Int
    ) async throws -> FarmRemoteOperationPushResult {
        guard !operations.isEmpty, operations.count <= 25 else {
            return .accepted([])
        }
        let farmIDs = Set(operations.map(\.envelope.farmID))
        guard let farmID = farmIDs.first, farmIDs.count == 1 else {
            throw FarmRemoteTransportError.malformedResponse
        }
        let payloads = operations.sorted {
            $0.clientSequence < $1.clientSequence
        }.map(Self.batchPayload(from:))
        let rows: [BatchOperationResultRow] = try await client.rpc(
            "apply_farm_operations_batch",
            params: BatchApplyParameters(
                p_farm_id: farmID,
                p_authority_generation: authorityGeneration,
                p_operations: payloads
            )
        ).execute().value

        return try Self.pushResult(from: rows)
    }

    func pullOperations(
        farmID: UUID,
        authorityGeneration: Int,
        after revision: Int,
        limit: Int
    ) async throws -> FarmRemotePullPage {
        let boundedLimit = min(max(1, limit), 500)
        let rows: [OperationRow] = try await client
            .from("farm_operations")
            .select()
            .eq("farm_id", value: farmID)
            .eq("authority_generation", value: authorityGeneration)
            .gt("revision", value: revision)
            .order("revision", ascending: true)
            .limit(boundedLimit + 1)
            .execute()
            .value
        let hasMore = rows.count > boundedLimit
        let selected = rows.prefix(boundedLimit)
        let operations = try selected.map(Self.envelope(from:))
        return FarmRemotePullPage(
            operations: operations,
            cursorRevision: selected.last?.revision ?? revision,
            hasMore: hasMore
        )
    }

    func uploadAsset(
        farmID: UUID,
        authorityGeneration: Int,
        assetID: UUID,
        data: Data,
        sha256: String,
        contentType: String
    ) async throws -> FarmRemoteAsset {
        guard Self.digest(data) == sha256 else {
            throw FarmRemoteTransportError.invalidAssetDigest
        }
        let storagePath = "\(farmID.uuidString.lowercased())/\(sha256)"
        do {
            return try await registerAsset(
                farmID: farmID,
                authorityGeneration: authorityGeneration,
                assetID: assetID,
                sha256: sha256,
                storagePath: storagePath,
                byteCount: Int64(data.count),
                contentType: contentType
            )
        } catch let error as PostgrestError
            where error.code == "23503" &&
                error.message == "asset_object_missing" {
            // The SHA path is not present yet. Upload it once and then let the
            // authenticated RPC verify and register the object. Any other RPC
            // error remains fatal and must not be hidden by a Storage write.
        }
        try await client.storage
            .from("farm-assets")
            .upload(
                storagePath,
                data: data,
                options: FileOptions(contentType: contentType, upsert: true)
            )
        return try await registerAsset(
            farmID: farmID,
            authorityGeneration: authorityGeneration,
            assetID: assetID,
            sha256: sha256,
            storagePath: storagePath,
            byteCount: Int64(data.count),
            contentType: contentType
        )
    }

    private func registerAsset(
        farmID: UUID,
        authorityGeneration: Int,
        assetID: UUID,
        sha256: String,
        storagePath: String,
        byteCount: Int64,
        contentType: String
    ) async throws -> FarmRemoteAsset {
        do {
            let rows: [AssetRow] = try await client.rpc(
                "register_farm_asset",
                params: RegisterAssetParameters(
                    p_asset_id: assetID,
                    p_farm_id: farmID,
                    p_authority_generation: authorityGeneration,
                    p_sha256: sha256,
                    p_storage_path: storagePath,
                    p_byte_count: byteCount,
                    p_content_type: contentType
                )
            ).execute().value
            guard let row = rows.first else {
                throw FarmRemoteTransportError.malformedResponse
            }
            return FarmRemoteAsset(
                assetID: row.assetID,
                farmID: farmID,
                sha256: sha256,
                byteCount: byteCount,
                contentType: contentType,
                storagePath: row.storagePath
            )
        } catch {
            let registrationError = error
            // Storage objects are keyed by SHA-256, while two immutable local
            // photo records may legitimately reference the same bytes. Reuse
            // the existing registered object only after every immutable field
            // has been verified. This deliberately does not depend on the
            // concrete SDK error wrapper: PostgREST may surface the same SQL
            // failure as different Swift error types across SDK releases. A
            // missing row or digest collision with different metadata still
            // returns the original registration error.
            do {
                let rows: [RegisteredAssetRow] = try await client
                    .from("farm_assets")
                    .select("asset_id,farm_id,sha256,storage_path,byte_count,content_type")
                    .eq("farm_id", value: farmID)
                    .eq("sha256", value: sha256)
                    .limit(1)
                    .execute()
                    .value
                guard let row = rows.first,
                      row.farmID == farmID,
                      row.sha256 == sha256,
                      row.storagePath == storagePath,
                      row.byteCount == byteCount,
                      row.contentType == contentType else {
                    throw registrationError
                }
                return FarmRemoteAsset(
                    assetID: row.assetID,
                    farmID: row.farmID,
                    sha256: row.sha256,
                    byteCount: row.byteCount,
                    contentType: row.contentType,
                    storagePath: row.storagePath
                )
            } catch {
                throw registrationError
            }
        }
    }

    func downloadAsset(_ asset: FarmRemoteAsset) async throws -> Data {
        let data = try await client.storage
            .from("farm-assets")
            .download(path: asset.storagePath)
        guard Self.digest(data) == asset.sha256 else {
            throw FarmRemoteTransportError.invalidAssetDigest
        }
        return data
    }

    func members(farmID: UUID) async throws -> [FarmRemoteMember] {
        let rows: [MemberRow] = try await client
            .from("farm_members")
            .select("user_id,app_account_id,role,status")
            .eq("farm_id", value: farmID)
            .execute()
            .value
        return rows.compactMap { row in
            guard let role = FarmRole(rawValue: row.role) else { return nil }
            let status: FarmMembershipStatus = row.status == "active" ? .active : .revoked
            return FarmRemoteMember(
                providerUserID: row.userID,
                accountID: row.appAccountID,
                role: role,
                status: status
            )
        }
    }

    func deactivate(
        farmID: UUID,
        authorityGeneration: Int,
        archive: Bool
    ) async throws {
        try await client.rpc(
            "deactivate_farm_authority",
            params: DeactivateParameters(
                p_farm_id: farmID,
                p_expected_generation: authorityGeneration,
                p_archive: archive
            )
        ).execute()
    }

    /// Realtime is only a low-latency hint. Callers must always use
    /// `pullOperations` with the durable cursor after every event and on a
    /// periodic timer, because broadcasts are intentionally not authoritative.
    func revisionNotifications(
        farmID: UUID
    ) -> AsyncThrowingStream<SupabaseRealtimeNotification, any Error> {
        let client = self.client
        return AsyncThrowingStream { continuation in
            let task = Task {
                let topic = "farm:\(farmID.uuidString.lowercased())"
                // Private Realtime authorization is evaluated at channel join.
                // A restored Keychain session can be available before the
                // Supabase client's auth-state listener has propagated its JWT
                // into RealtimeV2, which otherwise joins with the publishable
                // key and is correctly rejected by realtime.messages RLS.
                do {
                    let session = try await client.auth.session
                    await client.realtimeV2.setAuth(session.accessToken)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let channel = client.channel(topic) { configuration in
                    configuration.isPrivate = true
                }
                let events = channel.broadcastStream(event: "revision_available")
                do {
                    try await channel.subscribeWithError()
                    continuation.yield(.subscribed)
                    for await payload in events {
                        try Task.checkCancellation()
                        if let revision = payload["revision"]?.intValue {
                            continuation.yield(.revision(revision))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await client.removeChannel(channel)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func envelope(from row: OperationRow) throws -> CloudOperationEnvelope {
        guard let payload = Data(base64Encoded: row.payloadBase64),
              CloudPayloadDigest.hex(for: payload) == row.payloadDigest,
              let signature = Data(base64Encoded: row.operationSignature ?? "") else {
            throw FarmRemoteTransportError.malformedResponse
        }
        return CloudOperationEnvelope(
            farmID: row.farmID,
            entityID: row.entityID,
            entityType: row.entityType,
            schemaVersion: row.schemaVersion,
            revision: row.resultingRevision,
            baseRevision: row.baseRevision,
            operationID: row.operationID,
            modifiedAt: row.modifiedAt,
            modifiedByAccountID: row.modifiedByAccountID,
            modifiedByDeviceID: row.modifiedByDeviceID,
            payload: payload,
            payloadDigest: row.payloadDigest,
            capabilityCertificate: row.capabilityCertificate,
            operationSignature: signature,
            deletedAt: row.deletedAt
        )
    }

    private static func batchPayload(
        from pending: FarmRemotePendingOperation
    ) -> BatchOperationPayload {
        let operation = pending.envelope
        return BatchOperationPayload(
            operation_id: operation.operationID,
            client_sequence: pending.clientSequence,
            entity_type: operation.entityType,
            entity_id: operation.entityID,
            base_revision: operation.baseRevision,
            resulting_revision: operation.revision,
            schema_version: operation.schemaVersion,
            payload_base64: operation.payload.base64EncodedString(),
            payload_digest: operation.payloadDigest,
            modified_by_account_id: operation.modifiedByAccountID,
            modified_by_device_id: operation.modifiedByDeviceID,
            capability_certificate: operation.capabilityCertificate,
            operation_signature: operation.operationSignature.base64EncodedString(),
            occurred_at: CloudDateText.string(from: operation.modifiedAt),
            modified_at: CloudDateText.string(from: operation.modifiedAt),
            deleted_at: operation.deletedAt.map(CloudDateText.string(from:))
        )
    }

    private static func pushResult(
        from rows: [BatchOperationResultRow]
    ) throws -> FarmRemoteOperationPushResult {
        var receipts: [FarmRemoteOperationReceipt] = []
        var conflictOperationID: UUID?
        var conflictCode: String?
        for row in rows {
            switch row.resultStatus {
            case "accepted":
                guard let revision = row.revision,
                      let serverReceivedAt = row.serverReceivedAt else {
                    throw FarmRemoteTransportError.malformedResponse
                }
                receipts.append(FarmRemoteOperationReceipt(
                    operationID: row.operationID,
                    revision: revision,
                    serverReceivedAt: serverReceivedAt
                ))
            case "conflict":
                conflictOperationID = row.operationID
                conflictCode = row.errorCode
            default:
                throw FarmRemoteTransportError.malformedResponse
            }
        }
        return FarmRemoteOperationPushResult(
            receipts: receipts,
            conflictOperationID: conflictOperationID,
            conflictCode: conflictCode
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
