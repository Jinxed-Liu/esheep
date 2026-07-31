import CryptoKit
import Foundation
import Security
import SwiftData
import Supabase

enum DevelopmentSupabaseActivationGate {
    static let pausePointKey = "development.supabase.activationPausePoint"
    static let lastPausedPointKey = "development.supabase.lastPausedPoint"

    static let pausePoints: [FarmStorageTransitionState] = [
        .preparing,
        .uploadingBaseline,
        .rebuildingStagingStore,
        .verifying,
        .committingAuthority,
        .drainingOperations,
        .archivingSource,
    ]

    @MainActor
    static func consumePausePointIfArmed(
        at state: FarmStorageTransitionState,
        defaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        #if DEBUG
        guard bundleIdentifier == "com.sheepfarm.next.dev",
              pausePoints.contains(state) else {
            return false
        }
        let selectedPoint = defaults.string(forKey: pausePointKey)
        let chainsRealBaselineCommit =
            selectedPoint == nil &&
            state == .committingAuthority &&
            defaults.string(forKey: lastPausedPointKey) ==
                FarmStorageTransitionState.uploadingBaseline.rawValue
        guard selectedPoint == state.rawValue || chainsRealBaselineCommit else {
            return false
        }
        defaults.removeObject(forKey: pausePointKey)
        defaults.set(state.rawValue, forKey: lastPausedPointKey)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    static func pauseIfArmed(at state: FarmStorageTransitionState) async {
        guard consumePausePointIfArmed(at: state) else { return }
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in
            // Intentionally never resumed. This Development-only acceptance
            // hook leaves the durable state on disk so force-terminating and
            // relaunching the App proves idempotent recovery.
        }
    }
}

struct SupabaseCloudEntitlement: Sendable, Equatable {
    let state: String
    let validUntil: Date?
    let graceUntil: Date?
    let readOnlyUntil: Date?

    var allowsOwnerWrites: Bool {
        guard ["active", "grace_period", "billing_retry"].contains(state) else {
            return false
        }
        let now = Date.now
        return validUntil == nil || validUntil! > now || (graceUntil.map { $0 > now } ?? false)
    }
}

enum SupabaseFarmCloudError: LocalizedError {
    case notConfigured
    case entitlementRequired
    case activationAlreadyRunning
    case farmNotEligible(String)
    case migrationDrainPending(Int)
    case migrationConflict(Int)
    case migrationCursorBehind(local: Int, remote: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Development Supabase 尚未配置。"
        case .entitlementRequired:
            "当前账号没有服务端 Development 云授权。"
        case .activationAlreadyRunning:
            "当前牧场的 Supabase 启云任务已经在运行，请查看现有进度。"
        case .farmNotEligible(let reason):
            reason
        case .migrationDrainPending(let count):
            "仍有 \(count) 条迁移后操作等待上传；保持当前迁移状态并在网络恢复后继续。"
        case .migrationConflict(let count):
            "迁移后操作存在 \(count) 条冲突；解决冲突前不会归档来源。"
        case .migrationCursorBehind(let local, let remote):
            "本机 cursor \(local) 尚未追到服务端 revision \(remote)，稍后会继续补拉。"
        case .malformedResponse:
            "Supabase 返回的数据无法验证。"
        }
    }
}

struct SupabaseAuthorityDrainSnapshot: Sendable, Equatable {
    let pendingCount: Int
    let conflictCount: Int
    let cursorRevision: Int
    let remoteRevision: Int

    var isReadyToArchive: Bool {
        pendingCount == 0 &&
            conflictCount == 0 &&
            cursorRevision >= remoteRevision
    }
}

actor SupabaseEntitlementClient {
    private struct Row: Decodable, Sendable {
        let state: String
        let validUntil: Date?
        let graceUntil: Date?
        let readOnlyUntil: Date?

        enum CodingKeys: String, CodingKey {
            case state
            case validUntil = "valid_until"
            case graceUntil = "grace_until"
            case readOnlyUntil = "read_only_until"
        }
    }

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func current() async throws -> SupabaseCloudEntitlement? {
        let rows: [Row] = try await client
            .from("entitlements")
            .select("state,valid_until,grace_until,read_only_until")
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return nil }
        return SupabaseCloudEntitlement(
            state: row.state,
            validUntil: row.validUntil,
            graceUntil: row.graceUntil,
            readOnlyUntil: row.readOnlyUntil
        )
    }
}

struct SupabaseFarmInvite: Sendable, Equatable {
    let code: String
    let expiresAt: Date
}

struct SupabaseFarmInviteRedemption: Sendable, Equatable {
    let farmID: UUID
    let role: FarmRole
    let authorityGeneration: Int
}

actor SupabaseFarmInviteClient {
    private struct CreateParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_role: String
        let p_code_digest_hex: String
        let p_expires_at: String
    }

    private struct CreateRow: Decodable, Sendable {
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
        }
    }

    private struct RedeemParameters: Encodable, Sendable {
        let p_code: String
    }

    private struct RedeemRow: Decodable, Sendable {
        let farmID: UUID
        let role: String
        let authorityGeneration: Int

        enum CodingKeys: String, CodingKey {
            case farmID = "farm_id"
            case role
            case authorityGeneration = "authority_generation"
        }
    }

    private struct RevokeParameters: Encodable, Sendable {
        let p_farm_id: UUID
        let p_member_user_id: UUID
    }

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func create(farmID: UUID, role: FarmRole) async throws -> SupabaseFarmInvite {
        guard role == .administrator || role == .worker else {
            throw SupabaseFarmCloudError.farmNotEligible("只能邀请管理员或员工。")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SupabaseFarmCloudError.malformedResponse
        }
        let code = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let digest = SHA256.hash(data: Data(code.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let requestedExpiry = Date.now.addingTimeInterval(24 * 60 * 60 - 5)
        let rows: [CreateRow] = try await client.rpc(
            "create_farm_invite",
            params: CreateParameters(
                p_farm_id: farmID,
                p_role: role.rawValue,
                p_code_digest_hex: digest,
                p_expires_at: CloudDateText.string(from: requestedExpiry)
            )
        ).execute().value
        guard let row = rows.first else {
            throw SupabaseFarmCloudError.malformedResponse
        }
        return SupabaseFarmInvite(code: code, expiresAt: row.expiresAt)
    }

    func redeem(code: String) async throws -> SupabaseFarmInviteRedemption {
        let rows: [RedeemRow] = try await client.rpc(
            "redeem_farm_invite",
            params: RedeemParameters(
                p_code: code.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        ).execute().value
        guard let row = rows.first, let role = FarmRole(rawValue: row.role) else {
            throw SupabaseFarmCloudError.malformedResponse
        }
        return SupabaseFarmInviteRedemption(
            farmID: row.farmID,
            role: role,
            authorityGeneration: row.authorityGeneration
        )
    }

    func revoke(farmID: UUID, memberUserID: UUID) async throws {
        try await client.rpc(
            "revoke_farm_member",
            params: RevokeParameters(
                p_farm_id: farmID,
                p_member_user_id: memberUserID
            )
        ).execute()
    }
}

@MainActor
final class SupabaseFarmJoinService {
    private struct FarmEntityRow: Decodable {
        let payloadBase64: String
        let payloadDigest: String

        enum CodingKeys: String, CodingKey {
            case payloadBase64 = "payload_base64"
            case payloadDigest = "payload_digest"
        }
    }

    private struct OwnerRow: Decodable {
        let appAccountID: UUID

        enum CodingKeys: String, CodingKey {
            case appAccountID = "app_account_id"
        }
    }

    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func redeemAndInstall(
        code: String,
        accountID: UUID,
        context: ModelContext
    ) async throws -> FarmRecord {
        let redemption = try await SupabaseFarmInviteClient(client: client)
            .redeem(code: code)
        let entities: [FarmEntityRow] = try await client
            .from("farm_entities")
            .select("payload_base64,payload_digest")
            .eq("farm_id", value: redemption.farmID)
            .eq("entity_type", value: CloudEntityType.farm.rawValue)
            .limit(1)
            .execute()
            .value
        guard let entity = entities.first,
              let payloadData = Data(base64Encoded: entity.payloadBase64),
              CloudPayloadDigest.hex(for: payloadData) == entity.payloadDigest,
              let payload = try? JSONDecoder().decode(
                  FarmCommandCloudPayload.self,
                  from: payloadData
              ),
              payload.kind == .createFarm,
              let farmName = payload.strings["name"],
              !farmName.isEmpty else {
            throw SupabaseFarmCloudError.malformedResponse
        }
        let owners: [OwnerRow] = try await client
            .from("farm_members")
            .select("app_account_id")
            .eq("farm_id", value: redemption.farmID)
            .eq("role", value: FarmRole.owner.rawValue)
            .eq("status", value: "active")
            .limit(1)
            .execute()
            .value
        guard let owner = owners.first else {
            throw SupabaseFarmCloudError.malformedResponse
        }

        if let existing = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == redemption.farmID }) {
            return existing
        }
        let farm = FarmRecord(
            id: redemption.farmID,
            ownerAccountID: owner.appAccountID,
            name: farmName,
            role: redemption.role
        )
        context.insert(farm)
        context.insert(FarmStorageProfile(
            farmID: farm.id,
            mode: .supabase,
            authorityGeneration: redemption.authorityGeneration
        ))
        let binding = FarmRemoteBinding(
            farmID: farm.id,
            ownerAccountID: owner.appAccountID,
            provider: .supabase,
            state: .active,
            authorityGeneration: redemption.authorityGeneration,
            remoteFarmID: farm.id.uuidString.lowercased()
        )
        context.insert(binding)
        context.insert(FarmMembershipBinding(
            serverMembershipID: "supabase:\(farm.id.uuidString):\(accountID.uuidString)",
            farmID: farm.id,
            accountID: accountID,
            role: redemption.role,
            status: .active
        ))
        try context.save()
        CloudRuntimeNotification.postSyncWake(farmID: farm.id)
        return farm
    }
}

@MainActor
final class SupabaseFarmActivationService {
    private static var activeFarmIDs: Set<UUID> = []

    private let client: SupabaseClient
    private let transport: SupabaseFarmTransport
    private let deviceIdentity: DeviceIdentityActor

    init(
        client: SupabaseClient,
        deviceIdentity: DeviceIdentityActor = .shared
    ) {
        self.client = client
        self.transport = SupabaseFarmTransport(client: client)
        self.deviceIdentity = deviceIdentity
    }

    func eligibilityReason(
        farmID: UUID,
        context: ModelContext
    ) throws -> String? {
        guard let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: { $0.farmID == farmID }) else {
            return "当前牧场缺少 V3 存储配置。"
        }
        let isCommittedResume =
            profile.mode == .supabase &&
            [.drainingOperations, .archivingSource].contains(profile.transitionState)
        guard profile.mode == .localOnly || isCommittedResume else {
            return "当前牧场已经使用云端权威。"
        }
        guard farmID == FarmBaselinePackageBuilder.developmentTargetFarmID else {
            return "本阶段只开放星露谷测试牧场的非空启云。"
        }
        let activeMemberAccounts = Set(
            try context.fetch(FetchDescriptor<FarmMembershipBinding>())
                .filter { $0.farmID == farmID && $0.status == .active }
                .map(\.accountID)
        )
        guard activeMemberAccounts.count <= 1 else {
            return "共享牧场必须先移除成员后才能切换云端权威。"
        }
        return nil
    }

    @discardableResult
    func activate(
        farm: FarmRecord,
        context: ModelContext
    ) async throws -> URL {
        guard Self.activeFarmIDs.insert(farm.id).inserted else {
            throw SupabaseFarmCloudError.activationAlreadyRunning
        }
        defer { Self.activeFarmIDs.remove(farm.id) }
        if let reason = try eligibilityReason(farmID: farm.id, context: context) {
            throw SupabaseFarmCloudError.farmNotEligible(reason)
        }
        let entitlement = try await SupabaseEntitlementClient(client: client).current()
        guard entitlement?.allowsOwnerWrites == true else {
            throw SupabaseFarmCloudError.entitlementRequired
        }
        _ = try await deviceIdentity.registerWithActiveAccountProvider()

        var profile = try storageProfile(farmID: farm.id, context: context)
        if let legacyMigrationID = profile.migrationID,
           profile.mode == .localOnly,
           profile.targetMode == .supabase,
           try isLegacyBaseline(
                farmID: farm.id,
                migrationID: legacyMigrationID,
                context: context
           ) {
            try await abortLegacyPrecommitTransition(
                farmID: farm.id,
                migrationID: legacyMigrationID,
                context: context
            )
            profile = try storageProfile(farmID: farm.id, context: context)
        }

        let migrationID: UUID
        if let existing = profile.migrationID,
           profile.transitionState == .failed {
            try FarmStorageTransitionCoordinator.resumeFailedSupabaseUpload(
                farmID: farm.id,
                migrationID: existing,
                context: context
            )
            migrationID = existing
        } else if let existing = profile.migrationID,
           profile.transitionState != .idle,
           profile.transitionState != .failed {
            migrationID = existing
        } else {
            migrationID = try FarmStorageTransitionCoordinator.begin(
                farmID: farm.id,
                targetMode: .supabase,
                context: context
            )
        }
        let backupURL = try existingOrCreateLocalBackup(
            farmID: farm.id,
            migrationID: migrationID,
            context: context
        )

        try await resume(
            farm: farm,
            migrationID: migrationID,
            context: context
        )
        let compressedBackupURL = backupURL
            .deletingPathExtension()
            .appendingPathExtension("eslb")
        return FileManager.default.fileExists(
            atPath: compressedBackupURL.path
        ) ? compressedBackupURL : backupURL
    }

    /// Repairs a transition that was completed locally by an older build but
    /// remained `draining` remotely. This only closes the already-committed
    /// authority transition; it never restages or reuploads the baseline.
    @discardableResult
    func reconcileCompletedLocalActivation(
        farm: FarmRecord,
        context: ModelContext
    ) async throws -> Bool {
        let profile = try storageProfile(farmID: farm.id, context: context)
        guard profile.mode == .supabase,
              profile.transitionState == .idle,
              let binding = try context
                .fetch(FetchDescriptor<FarmRemoteBinding>())
                .first(where: {
                    $0.farmID == farm.id &&
                        $0.provider == .supabase &&
                        $0.state == .active
                }),
              binding.authorityGeneration == profile.authorityGeneration else {
            return false
        }
        guard let migration = try context
            .fetch(FetchDescriptor<FarmBaselineMigrationRecord>())
            .filter({
                $0.farmID == farm.id &&
                    $0.checkpointID != nil
            })
            .max(by: { $0.updatedAt < $1.updatedAt }) else {
            return false
        }

        let status = try await transport.compactAuthorityTransitionStatus(
            farmID: farm.id,
            migrationID: migration.migrationID
        )
        guard status.authorityGeneration == profile.authorityGeneration else {
            throw SupabaseFarmCloudError.malformedResponse
        }
        guard ["draining", "archiving_source", "completed"].contains(status.status) else {
            return false
        }
        let receipt = try await transport.completeAuthorityTransition(
            farmID: farm.id,
            migrationID: migration.migrationID,
            authorityGeneration: profile.authorityGeneration
        )
        migration.serverRevision = max(
            migration.serverRevision,
            receipt.currentRevision
        )
        migration.updatedAt = .now
        binding.lastPulledRevision = max(
            binding.lastPulledRevision,
            receipt.currentRevision
        )
        binding.lastSuccessfulSyncAt = .now
        binding.lastErrorCode = nil
        binding.updatedAt = .now
        try context.save()
        return true
    }

    private func resume(
        farm: FarmRecord,
        migrationID: UUID,
        context: ModelContext
    ) async throws {
        let startingProfile = try storageProfile(
            farmID: farm.id,
            context: context
        )
        let targetGeneration = startingProfile.mode == .supabase
            ? startingProfile.authorityGeneration
            : startingProfile.authorityGeneration + 1
        // The compressed checkpoint is atomically persisted before the first
        // request. It contains current projections plus the original audit
        // history, without turning every entity into a fake cloud operation.
        let (package, archive, progress) = try FarmCompactBaselinePackageBuilder()
            .loadOrCreate(
            farm: farm,
            migrationID: migrationID,
            authorityGeneration: targetGeneration,
            context: context
        )
        let sourceCounts = FarmCompactBaselineSourceCounts(
            sheep: try context.fetch(FetchDescriptor<SheepRecord>())
                .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count,
            pens: try context.fetch(FetchDescriptor<PenRecord>())
                .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count,
            activePhotos: try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count
        )
        let request = FarmAuthorityTransitionRequest(
            farmID: farm.id,
            migrationID: migrationID,
            sourceMode: .localOnly,
            targetGeneration: targetGeneration,
            baselineRevision: 0,
            manifestDigest: progress.packageDigest
        )
        let checkpointID = deterministicCheckpointID(migrationID: migrationID)

        while true {
            let profile = try storageProfile(farmID: farm.id, context: context)
            await DevelopmentSupabaseActivationGate.pauseIfArmed(
                at: profile.transitionState
            )
            switch profile.transitionState {
            case .preparing:
                _ = try await transport.prepareCompactAuthorityTransition(
                    request
                )
                try FarmStorageTransitionCoordinator.markBaselineUploading(
                    farmID: farm.id,
                    migrationID: migrationID,
                    context: context
                )
            case .uploadingBaseline:
                let remote: FarmCompactAuthorityTransitionStatus
                do {
                    remote = try await transport
                        .compactAuthorityTransitionStatus(
                        farmID: farm.id,
                        migrationID: migrationID
                    )
                } catch FarmRemoteTransportError.authorityTransitionMissing {
                    _ = try await transport
                        .prepareCompactAuthorityTransition(request)
                    remote = try await transport
                        .compactAuthorityTransitionStatus(
                        farmID: farm.id,
                        migrationID: migrationID
                    )
                }
                progress.confirmedOperationCount =
                    remote.stagedProjectionCount
                progress.uploadedAssetCount = remote.stagedAssetCount
                progress.serverRevision = remote.currentRevision
                progress.updatedAt = .now
                try context.save()
                while progress.confirmedOperationCount <
                    package.projections.count {
                    let start = progress.confirmedOperationCount
                    let end = min(start + 100, package.projections.count)
                    let batch = Array(package.projections[start..<end])
                    try await transport.stageBaselineProjections(
                        batch,
                        request: request
                    )
                    progress.confirmedBatchCount += 1
                    progress.confirmedOperationCount = end
                    progress.updatedAt = .now
                    try context.save()
                }
                while progress.uploadedAssetCount < package.assets.count {
                    let asset = package.assets[progress.uploadedAssetCount]
                    let url = try FarmCompactBaselinePackageBuilder.assetURL(
                        relativePath: asset.relativePath
                    )
                    let data = try Data(contentsOf: url)
                    let receipt = try await transport.uploadAsset(
                        farmID: farm.id,
                        authorityGeneration: targetGeneration,
                        assetID: asset.assetID,
                        data: data,
                        sha256: asset.sha256,
                        contentType: asset.contentType
                    )
                    guard receipt.sha256 == asset.sha256,
                          receipt.byteCount == asset.byteCount else {
                        throw SupabaseFarmCloudError.malformedResponse
                    }
                    progress.uploadedAssetCount += 1
                    progress.updatedAt = .now
                    try context.save()
                }
                try FarmStorageTransitionCoordinator.markStagingRebuild(
                    farmID: farm.id,
                    migrationID: migrationID,
                    context: context
                )
            case .rebuildingStagingStore:
                try await FarmCompactBaselineRebuildService().verify(
                    package: package,
                    packageDigest: progress.packageDigest,
                    sourceCounts: sourceCounts
                )
                try FarmStorageTransitionCoordinator.markVerifying(
                    farmID: farm.id,
                    migrationID: migrationID,
                    context: context
                )
            case .verifying:
                try await transport.registerCompactCheckpoint(
                    FarmCompactRemoteCheckpoint(
                        checkpointID: checkpointID,
                        farmID: farm.id,
                        migrationID: migrationID,
                        authorityGeneration: targetGeneration,
                        throughRevision: 0,
                        archive: archive,
                        archiveDigest: progress.packageDigest,
                        archiveByteCount: archive.count,
                        projectionCount: package.manifest.projectionCount,
                        tombstoneProjectionCount:
                            package.manifest.tombstoneProjectionCount,
                        tombstoneHistoryCount:
                            package.manifest.tombstoneHistoryCount,
                        historyOperationCount:
                            package.manifest.historyOperationCount,
                        assetCount: package.manifest.assetCount
                    ),
                    manifest: package.manifest
                )
                progress.checkpointID = checkpointID
                progress.updatedAt = .now
                try context.save()
                try FarmStorageTransitionCoordinator.markReadyToCommit(
                    farmID: farm.id,
                    migrationID: migrationID,
                    context: context
                )
            case .committingAuthority:
                let receipt = try await transport
                    .verifyAndCommitCompactAuthority(
                        request: request,
                        checkpointID: checkpointID
                    )
                guard receipt.status == "active",
                      receipt.authorityGeneration == targetGeneration else {
                    throw SupabaseFarmCloudError.malformedResponse
                }
                try FarmStorageTransitionCoordinator.commitAuthority(
                    farmID: farm.id,
                    migrationID: migrationID,
                    context: context
                )
                upsertBinding(
                    farm: farm,
                    generation: targetGeneration,
                    cursor: receipt.currentRevision,
                    context: context
                )
            case .drainingOperations:
                upsertBinding(
                    farm: farm,
                    generation: targetGeneration,
                    cursor: progress.serverRevision,
                    context: context
                )
                let snapshot = try await drainPostWatermarkOperations(
                    farmID: farm.id,
                    migrationID: migrationID,
                    generation: targetGeneration,
                    context: context
                )
                guard snapshot.isReadyToArchive else {
                    throw SupabaseFarmCloudError.malformedResponse
                }
                progress.serverRevision = max(
                    progress.serverRevision,
                    snapshot.remoteRevision
                )
                progress.updatedAt = .now
                try context.save()
                try FarmStorageTransitionCoordinator.markSourceArchiving(
                    farmID: farm.id,
                    migrationID: migrationID,
                    context: context
                )
            case .archivingSource:
                let receipt = try await transport.completeAuthorityTransition(
                    farmID: farm.id,
                    migrationID: migrationID,
                    authorityGeneration: targetGeneration
                )
                progress.serverRevision = max(
                    progress.serverRevision,
                    receipt.currentRevision
                )
                progress.updatedAt = .now
                try context.save()
                try FarmStorageTransitionCoordinator.finish(
                    farmID: farm.id,
                    migrationID: migrationID,
                    context: context
                )
                // Cleanup is intentionally post-commit and best effort. A
                // pending post-watermark Outbox must never turn an already
                // activated cloud authority into a failed migration.
                _ = try? await LocalStorageOptimizationService()
                    .optimizeAfterVerifiedSupabaseActivation(
                        farmID: farm.id,
                        migrationID: migrationID,
                        context: context
                    )
            case .idle:
                return
            case .failed:
                throw SupabaseFarmCloudError.farmNotEligible(
                    "上次启云在提交前失败，请重新开始。"
                )
            case .readOnlyMigration:
                throw SupabaseFarmCloudError.farmNotEligible(
                    "当前牧场处于只读迁移期。"
                )
            }
        }
    }

    private func drainPostWatermarkOperations(
        farmID: UUID,
        migrationID: UUID,
        generation: Int,
        context: ModelContext
    ) async throws -> SupabaseAuthorityDrainSnapshot {
        let coordinator = FarmRemoteSyncCoordinator(
            container: context.container,
            transport: transport
        )
        var priorPendingCount = Int.max
        while true {
            let before = try drainOutboxCounts(
                farmID: farmID,
                generation: generation,
                context: context
            )
            if before.conflicts > 0 {
                throw SupabaseFarmCloudError.migrationConflict(
                    before.conflicts
                )
            }

            let result = try await coordinator.synchronize(
                farmID: farmID,
                maxOutboxItems: 25
            )
            let after = try drainOutboxCounts(
                farmID: farmID,
                generation: generation,
                context: context
            )
            if result.conflictCount > 0 || after.conflicts > 0 {
                throw SupabaseFarmCloudError.migrationConflict(
                    max(result.conflictCount, after.conflicts)
                )
            }
            if after.pending > 0 {
                guard result.uploadedOperationCount > 0,
                      after.pending < priorPendingCount else {
                    throw SupabaseFarmCloudError.migrationDrainPending(
                        after.pending
                    )
                }
                priorPendingCount = after.pending
                continue
            }

            let remote = try await transport.compactAuthorityTransitionStatus(
                farmID: farmID,
                migrationID: migrationID
            )
            let snapshot = SupabaseAuthorityDrainSnapshot(
                pendingCount: 0,
                conflictCount: 0,
                cursorRevision: result.cursorRevision,
                remoteRevision: remote.currentRevision
            )
            guard snapshot.cursorRevision >= snapshot.remoteRevision else {
                throw SupabaseFarmCloudError.migrationCursorBehind(
                    local: snapshot.cursorRevision,
                    remote: snapshot.remoteRevision
                )
            }
            return snapshot
        }
    }

    private func drainOutboxCounts(
        farmID: UUID,
        generation: Int,
        context: ModelContext
    ) throws -> (pending: Int, conflicts: Int) {
        let readContext = ModelContext(context.container)
        let items = try readContext.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farmID &&
                $0.deliveryProvider == .supabase &&
                $0.authorityGeneration == generation
        }
        return (
            items.count {
                [.pending, .uploading, .awaitingConfirmation, .retryableFailure]
                    .contains($0.status)
            },
            items.count {
                [.blockedConflict, .rejectedPermission].contains($0.status)
            }
        )
    }

    private func signedBaselineOperations(
        _ operations: [DomainOperation],
        context: ModelContext
    ) async throws -> [FarmRemotePendingOperation] {
        let identity = try await deviceIdentity.identity()
        guard let farmID = operations.first?.farmID else { return [] }
        let sequences = try FarmStorageRouter.operationSequences(
            farmID: farmID,
            context: context
        )
        var values: [FarmRemotePendingOperation] = []
        for operation in operations {
            guard let entityID = operation.entityID else {
                throw SupabaseFarmCloudError.malformedResponse
            }
            var envelope = CloudOperationEnvelope(
                farmID: operation.farmID,
                entityID: entityID,
                entityType: operation.entityType,
                schemaVersion: operation.schemaVersion,
                revision: operation.resultingRevision,
                baseRevision: operation.baseRevision,
                operationID: operation.id,
                modifiedAt: operation.occurredAt,
                modifiedByAccountID: operation.accountID,
                modifiedByDeviceID: identity.deviceID,
                payload: operation.payload,
                payloadDigest: operation.payloadDigest,
                capabilityCertificate: "supabase-authenticated-owner",
                operationSignature: Data(),
                deletedAt: nil
            )
            let signature = try await deviceIdentity.sign(envelope.canonicalSigningData)
            envelope = CloudOperationEnvelope(
                farmID: envelope.farmID,
                entityID: envelope.entityID,
                entityType: envelope.entityType,
                schemaVersion: envelope.schemaVersion,
                revision: envelope.revision,
                baseRevision: envelope.baseRevision,
                operationID: envelope.operationID,
                modifiedAt: envelope.modifiedAt,
                modifiedByAccountID: envelope.modifiedByAccountID,
                modifiedByDeviceID: envelope.modifiedByDeviceID,
                payload: envelope.payload,
                payloadDigest: envelope.payloadDigest,
                capabilityCertificate: envelope.capabilityCertificate,
                operationSignature: signature,
                deletedAt: nil
            )
            values.append(FarmRemotePendingOperation(
                envelope: envelope,
                clientSequence: sequences[operation.id] ?? 0
            ))
        }
        return values
    }

    private func verifyTemporaryRebuild(
        farm: FarmRecord,
        package: FarmBaselinePackageV2,
        sourceContext: ModelContext
    ) throws {
        guard package.operations.count == package.manifest.operationCount,
              package.assets.count == package.manifest.assetCount else {
            throw SupabaseFarmCloudError.malformedResponse
        }
        let temporary = try AppSchema.makeContainer(
            name: "SupabaseBaseline-\(package.manifest.migrationID.uuidString)",
            isStoredInMemoryOnly: true
        )
        let staging = ModelContext(temporary)
        staging.insert(FarmRecord(
            id: farm.id,
            ownerAccountID: farm.ownerAccountID,
            name: farm.name,
            role: farm.role,
            createdAt: farm.createdAt,
            updatedAt: farm.updatedAt
        ))
        let applier = RemoteDomainApplyService(
            replayAssumesEmptyBusinessStore: true
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for item in package.operations where item.role != .originalHistory {
            let outcome = try applier.apply(item.envelope, context: staging)
            if case .conflict = outcome {
                throw SupabaseFarmCloudError.malformedResponse
            }
        }
        for item in package.operations {
            let envelope = item.envelope
            let payload = try decoder.decode(
                FarmCommandCloudPayload.self,
                from: envelope.payload
            )
            staging.insert(DomainOperation(
                id: envelope.operationID,
                farmID: envelope.farmID,
                accountID: envelope.modifiedByAccountID,
                kind: payload.kind,
                occurredAt: envelope.modifiedAt,
                summary: item.historySummary.isEmpty
                    ? "Supabase 内部基线"
                    : item.historySummary,
                entityType: envelope.entityType,
                entityID: envelope.entityID,
                baseRevision: envelope.baseRevision,
                resultingRevision: envelope.revision,
                payload: envelope.payload
            ))
            staging.insert(FarmOperationSequenceRecord(
                farmID: envelope.farmID,
                operationID: envelope.operationID,
                clientSequence: item.clientSequence
            ))
        }
        staging.insert(FarmOperationSequenceCounter(
            farmID: farm.id,
            nextSequence: (package.operations.map(\.clientSequence).max() ?? 0) + 1
        ))
        try FarmHistoryRebuilder().rebuild(farmID: farm.id, context: staging)
        try staging.save()
        let sourceSheep = try sourceContext.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count
        let sourcePens = try sourceContext.fetch(FetchDescriptor<PenRecord>())
            .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count
        let sourcePhotoCount = try sourceContext
            .fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farm.id }.count
        let sourceActivePhotoCount = try sourceContext
            .fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count
        let rebuiltSheep = try staging.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count
        let rebuiltPens = try staging.fetch(FetchDescriptor<PenRecord>())
            .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count
        let rebuiltTombstoneCount = try staging
            .fetch(FetchDescriptor<TombstoneRecord>())
            .filter { $0.farmID == farm.id && $0.restoredAt == nil }.count
        let rebuiltPhotoCount = try staging
            .fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farm.id && $0.deletedAt == nil }.count
        guard try staging.fetchCount(FetchDescriptor<FarmRecord>()) == 1,
              try staging.fetchCount(FetchDescriptor<DomainOperation>()) ==
                package.operations.count,
              sourceSheep == rebuiltSheep,
              sourcePens == rebuiltPens,
              sourcePhotoCount == package.manifest.assetCount,
              rebuiltTombstoneCount == package.manifest.tombstoneCount,
              rebuiltPhotoCount == sourceActivePhotoCount else {
            throw SupabaseFarmCloudError.malformedResponse
        }
    }

    private func operationsForBaseline(
        farmID: UUID,
        context: ModelContext
    ) throws -> [DomainOperation] {
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == farmID }
        var sequences = try FarmStorageRouter.operationSequences(
            farmID: farmID,
            context: context
        )
        for operation in operations.sorted(by: {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }) where sequences[operation.id] == nil {
            sequences[operation.id] = try FarmStorageRouter.takeNextOperationSequence(
                farmID: farmID,
                operationID: operation.id,
                context: context
            )
        }
        try context.save()
        return operations.sorted {
                let lhs = sequences[$0.id] ?? 0
                let rhs = sequences[$1.id] ?? 0
                if lhs != rhs {
                    return lhs < rhs
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private func storageProfile(
        farmID: UUID,
        context: ModelContext
    ) throws -> FarmStorageProfile {
        guard let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: { $0.farmID == farmID }) else {
            throw FarmStorageTransitionError.profileMissing
        }
        return profile
    }

    private func upsertBinding(
        farm: FarmRecord,
        generation: Int,
        cursor: Int,
        context: ModelContext
    ) {
        let bindings = (try? context.fetch(FetchDescriptor<FarmRemoteBinding>())) ?? []
        let binding: FarmRemoteBinding
        if let existing = bindings.first(where: {
            $0.farmID == farm.id && $0.provider == .supabase
        }) {
            binding = existing
        } else {
            binding = FarmRemoteBinding(
                farmID: farm.id,
                ownerAccountID: farm.ownerAccountID,
                provider: .supabase
            )
            context.insert(binding)
        }
        binding.stateRawValue = FarmRemoteBindingState.active.rawValue
        binding.authorityGeneration = generation
        binding.remoteFarmID = farm.id.uuidString.lowercased()
        binding.lastPulledRevision = max(binding.lastPulledRevision, cursor)
        binding.lastSuccessfulSyncAt = .now
        binding.updatedAt = .now
        try? context.save()
    }

    private func isLegacyBaseline(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws -> Bool {
        try context.fetch(FetchDescriptor<FarmBaselineMigrationRecord>())
            .contains {
                $0.farmID == farmID &&
                    $0.migrationID == migrationID &&
                    $0.packageRelativePath.hasSuffix(".json")
            }
    }

    private func abortLegacyPrecommitTransition(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) async throws {
        let allowedRemoteStates = Set([
            "preparing",
            "uploading_baseline",
            "verifying",
            "failed",
        ])
        do {
            let remote = try await transport.authorityTransitionStatus(
                farmID: farmID,
                migrationID: migrationID
            )
            guard allowedRemoteStates.contains(remote.status) else {
                throw SupabaseFarmCloudError.farmNotEligible(
                    "旧启云任务可能已经提交，已停止自动替换以保护唯一权威。"
                )
            }
            try await transport.abortAuthorityTransition(
                farmID: farmID,
                migrationID: migrationID
            )
        } catch FarmRemoteTransportError.authorityTransitionMissing {
            // A missing provider transition means no remote authority exists;
            // the still-local profile can safely start a replacement task.
        }

        try FarmStorageTransitionCoordinator.abortBeforeCommit(
            farmID: farmID,
            migrationID: migrationID,
            context: context
        )
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let legacyDirectory = support
            .appending(path: "SupabaseBaselinePackages")
            .appending(path: farmID.uuidString.lowercased())
        if FileManager.default.fileExists(atPath: legacyDirectory.path) {
            try FileManager.default.removeItem(at: legacyDirectory)
        }
        try? FarmCompactBaselineRebuildProgressStore.remove(
            farmID: farmID,
            migrationID: migrationID
        )
    }

    private func existingOrCreateLocalBackup(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(
            path: "SupabaseMigrationBackups/\(farmID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appending(
            path: "migration-\(migrationID.uuidString.lowercased()).json"
        )
        if FileManager.default.fileExists(atPath: url.path),
           let existing = try? Data(contentsOf: url),
           !existing.isEmpty {
            return url
        }
        let data = try FarmLocalBackupService.export(
            farmID: farmID,
            context: context
        )
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private func deterministicCheckpointID(migrationID: UUID) -> UUID {
        let digest = Array(SHA256.hash(data: Data(
            "checkpoint:\(migrationID.uuidString.lowercased())".utf8
        )))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
