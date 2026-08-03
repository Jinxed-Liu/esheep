import Foundation
import Supabase
import SwiftData

enum DevelopmentSupabaseRestoreGate {
    static let pausePointKey = "development.supabase.restorePausePoint"
    static let lastPausedPointKey = "development.supabase.lastRestorePausePoint"

    static let pausePoints: [FarmRemoteRestoreState] = [
        .downloadingCheckpoint,
        .rebuildingStaging,
        .downloadingAssets,
        .promoting,
        .catchingUp,
    ]

    @MainActor
    static func consumePausePointIfArmed(
        at state: FarmRemoteRestoreState,
        defaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        #if DEBUG
        guard bundleIdentifier == "com.sheepfarm.next.dev",
              pausePoints.contains(state),
              defaults.string(forKey: pausePointKey) == state.rawValue else {
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
    static func pauseIfArmed(at state: FarmRemoteRestoreState) async {
        guard consumePausePointIfArmed(at: state) else { return }
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in
            // Development-only acceptance hook. The durable restore state is
            // already saved, so force-termination proves idempotent resume.
        }
    }
}

struct SupabaseFarmAccessDescriptor: Decodable, Equatable, Sendable {
    let farmID: UUID
    let ownerUserID: UUID
    let ownerAccountID: UUID
    let memberUserID: UUID
    let memberAccountID: UUID
    let memberRoleRawValue: String
    let providerRawValue: String
    let farmStatus: String
    let authorityGeneration: Int
    let currentRevision: Int

    enum CodingKeys: String, CodingKey {
        case farmID = "farm_id"
        case ownerUserID = "owner_user_id"
        case ownerAccountID = "owner_app_account_id"
        case memberUserID = "member_user_id"
        case memberAccountID = "member_app_account_id"
        case memberRoleRawValue = "member_role"
        case providerRawValue = "provider"
        case farmStatus = "farm_status"
        case authorityGeneration = "authority_generation"
        case currentRevision = "current_revision"
    }

    var memberRole: FarmRole? {
        FarmRole(rawValue: memberRoleRawValue)
    }

    var serverMembershipID: String {
        "supabase:\(farmID.uuidString.lowercased()):" +
            memberUserID.uuidString.lowercased()
    }
}

enum SupabaseFarmAccessIsolationPolicy {
    static func isVisible(
        bindingState: FarmRemoteBindingState,
        membershipStatus: FarmMembershipStatus?,
        restoreState: FarmRemoteRestoreState?
    ) -> Bool {
        bindingState == .active &&
            membershipStatus == .active &&
            (restoreState == nil || restoreState == .completed)
    }

    static func shouldQuarantine(_ status: OutboxStatus) -> Bool {
        !status.isTerminalDelivery
    }
}

enum SupabaseFarmAccessRecoveryError: LocalizedError {
    case invalidCheckpoint
    case accountMismatch
    case farmAlreadyExists
    case assetMismatch(UUID)
    case restoreRecordMismatch
    case inactiveMembership

    var errorDescription: String? {
        switch self {
        case .invalidCheckpoint:
            "Supabase 牧场 checkpoint 无法通过完整性验证。"
        case .accountMismatch:
            "Supabase 牧场与当前本地账号不一致。"
        case .farmAlreadyExists:
            "本机已有同 ID 牧场，已停止覆盖。"
        case .assetMismatch(let assetID):
            "照片文件与云端摘要不一致：\(assetID.uuidString.lowercased())。"
        case .restoreRecordMismatch:
            "本地恢复断点与当前云端牧场不一致。"
        case .inactiveMembership:
            "当前账号已经没有该 Supabase 牧场的有效访问权限。"
        }
    }
}

@MainActor
struct SupabaseFarmAccessRecoveryService {
    private let client: SupabaseClient
    private let transport: SupabaseFarmTransport

    init(client: SupabaseClient) {
        self.client = client
        self.transport = SupabaseFarmTransport(client: client)
    }

    @discardableResult
    func discoverAndRestoreAccessibleFarms(
        accountID: UUID,
        context: ModelContext
    ) async throws -> [UUID] {
        let session = try await client.auth.session
        let rows: [SupabaseFarmAccessDescriptor] = try await client
            .rpc("list_my_active_farm_access")
            .execute()
            .value
        guard rows.allSatisfy({
            $0.memberUserID == session.user.id &&
                $0.memberAccountID == accountID &&
                $0.memberRole != nil &&
                $0.providerRawValue == "supabase" &&
                ["active", "read_only"].contains($0.farmStatus)
        }) else {
            throw SupabaseFarmAccessRecoveryError.accountMismatch
        }
        try reconcileRevokedAccess(
            accountID: accountID,
            activeFarmIDs: Set(rows.map(\.farmID)),
            context: context
        )
        var restored: [UUID] = []
        for row in rows {
            guard let memberRole = row.memberRole else {
                throw SupabaseFarmAccessRecoveryError.accountMismatch
            }
            let restoreRecords = try context.fetch(
                FetchDescriptor<FarmRemoteRestoreRecord>()
            ).filter {
                $0.accountID == accountID &&
                    $0.farmID == row.farmID
            }
            let restoreRecord = restoreRecords.first {
                $0.state != .completed
            } ?? restoreRecords.max { $0.updatedAt < $1.updatedAt }
            if try activateVerifiedLocalCacheIfAvailable(
                descriptor: row,
                accountID: accountID,
                role: memberRole,
                existingRecord: restoreRecord,
                context: context
            ) {
                restored.append(row.farmID)
                continue
            }
            do {
                try await restore(
                    row: row,
                    accountID: accountID,
                    existingRecord: restoreRecord,
                    context: context
                )
                restored.append(row.farmID)
            } catch {
                if let record = try context.fetch(
                    FetchDescriptor<FarmRemoteRestoreRecord>()
                ).first(where: {
                    $0.accountID == accountID && $0.farmID == row.farmID
                }) {
                    record.stateRawValue = FarmRemoteRestoreState.failed.rawValue
                    record.lastErrorCode = Self.errorCode(error)
                    record.updatedAt = .now
                    try? context.save()
                }
                throw error
            }
        }
        try context.save()
        return restored
    }

    private func restore(
        row: SupabaseFarmAccessDescriptor,
        accountID: UUID,
        existingRecord: FarmRemoteRestoreRecord?,
        context: ModelContext
    ) async throws {
        let record: FarmRemoteRestoreRecord
        if let existingRecord {
            guard existingRecord.authorityGeneration == row.authorityGeneration,
                  existingRecord.ownerAccountID == nil ||
                    existingRecord.ownerAccountID == row.ownerAccountID,
                  existingRecord.serverMembershipID == nil ||
                    existingRecord.serverMembershipID == row.serverMembershipID else {
                throw SupabaseFarmAccessRecoveryError.restoreRecordMismatch
            }
            record = existingRecord
            record.ownerAccountID = row.ownerAccountID
            record.memberRoleRawValue = row.memberRoleRawValue
            record.serverMembershipID = row.serverMembershipID
            record.targetCursorRevision = max(
                record.targetCursorRevision,
                row.currentRevision
            )
        } else {
            record = FarmRemoteRestoreRecord(
                accountID: accountID,
                farmID: row.farmID,
                authorityGeneration: row.authorityGeneration,
                ownerAccountID: row.ownerAccountID,
                memberRole: row.memberRole,
                serverMembershipID: row.serverMembershipID,
                targetCursorRevision: row.currentRevision
            )
            context.insert(record)
        }
        record.advance(to: .downloadingCheckpoint)
        try context.save()
        await DevelopmentSupabaseRestoreGate.pauseIfArmed(
            at: .downloadingCheckpoint
        )

        let checkpoint = try await loadCheckpoint(
            row: row,
            record: record,
            context: context
        )
        let package = try FarmCompactBaselineArchive.decode(
            checkpoint.archive
        )
        try validate(
            checkpoint: checkpoint,
            package: package,
            row: row,
            ownerAccountID: row.ownerAccountID
        )
        record.checkpointID = checkpoint.checkpointID
        record.checkpointMigrationID = checkpoint.migrationID
        record.checkpointDigest = checkpoint.archiveDigest
        record.checkpointRevision = checkpoint.throughRevision
        record.totalEntityCount = checkpoint.projectionCount
        record.totalAssetCount = checkpoint.assetCount
        record.advance(to: .rebuildingStaging)
        try context.save()
        await DevelopmentSupabaseRestoreGate.pauseIfArmed(
            at: .rebuildingStaging
        )

        let sourceCounts = FarmCompactBaselineSourceCounts(
            sheep: package.projections.count {
                $0.entityType == CloudEntityType.sheep.rawValue &&
                    $0.deletedAt == nil
            },
            pens: package.projections.count {
                $0.entityType == CloudEntityType.pen.rawValue &&
                    $0.deletedAt == nil
            },
            activePhotos: package.assets.count
        )
        try await FarmCompactBaselineRebuildService().verify(
            package: package,
            packageDigest: checkpoint.archiveDigest,
            sourceCounts: sourceCounts
        )
        record.restoredEntityCount = checkpoint.projectionCount
        record.advance(to: .downloadingAssets)
        try context.save()
        await DevelopmentSupabaseRestoreGate.pauseIfArmed(
            at: .downloadingAssets
        )

        try await downloadAssets(
            package: package,
            record: record,
            context: context
        )
        record.advance(to: .promoting)
        try context.save()
        await DevelopmentSupabaseRestoreGate.pauseIfArmed(at: .promoting)

        var usesExistingAuthoritativeCache = false
        if let existingFarm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == row.farmID }) {
            guard existingFarm.ownerAccountID == row.ownerAccountID else {
                throw SupabaseFarmAccessRecoveryError.accountMismatch
            }
            let markerPrefix = "compact-discovery:" +
                "\(checkpoint.migrationID.uuidString.lowercased()):"
            let isResumable = try context
                .fetch(FetchDescriptor<CloudOperationReceipt>())
                .contains {
                    $0.farmID == row.farmID &&
                        $0.recordName.hasPrefix(markerPrefix)
                }
            let hasMatchingProfile = try context
                .fetch(FetchDescriptor<FarmStorageProfile>())
                .contains {
                $0.farmID == row.farmID &&
                    $0.mode == .supabase &&
                    $0.transitionState == .idle &&
                    $0.authorityGeneration == row.authorityGeneration
            }
            guard isResumable || hasMatchingProfile else {
                throw SupabaseFarmAccessRecoveryError.farmAlreadyExists
            }
            let hasMatchingBinding = try context
                .fetch(FetchDescriptor<FarmRemoteBinding>())
                .contains {
                    $0.farmID == row.farmID &&
                        $0.provider == .supabase &&
                        $0.authorityGeneration == row.authorityGeneration &&
                        [.active, .accessRevoked].contains($0.state)
                }
            usesExistingAuthoritativeCache =
                hasMatchingProfile && hasMatchingBinding
        }

        let rebuildService = FarmCompactBaselineRebuildService()
        if !usesExistingAuthoritativeCache {
            try await rebuildService.restoreAuthoritativeCache(
                package: package,
                packageDigest: checkpoint.archiveDigest,
                ownerAccountID: row.ownerAccountID,
                cursor: checkpoint.throughRevision,
                activate: false,
                container: context.container
            )
        }
        try promoteAssets(
            package: package,
            record: record,
            context: context
        )
        if usesExistingAuthoritativeCache {
            try await rebuildService.finalizeExistingAuthoritativeCacheAccess(
                farmID: row.farmID,
                ownerAccountID: row.ownerAccountID,
                currentAccountID: accountID,
                memberRole: row.memberRole ?? .worker,
                serverMembershipID: row.serverMembershipID,
                authorityGeneration: row.authorityGeneration,
                checkpointCursor: checkpoint.throughRevision,
                container: context.container
            )
        } else {
            try await rebuildService.finalizeRestoredFarm(
                package: package,
                ownerAccountID: row.ownerAccountID,
                currentAccountID: accountID,
                memberRole: row.memberRole ?? .worker,
                serverMembershipID: row.serverMembershipID,
                cursor: checkpoint.throughRevision,
                container: context.container
            )
        }

        record.advance(to: .catchingUp)
        try context.save()
        await DevelopmentSupabaseRestoreGate.pauseIfArmed(at: .catchingUp)
        let syncResult = try await FarmRemoteSyncCoordinator(
            container: context.container,
            transport: transport
        ).synchronize(farmID: row.farmID)
        record.currentCursorRevision = syncResult.cursorRevision
        record.targetCursorRevision = max(
            record.targetCursorRevision,
            syncResult.cursorRevision
        )
        record.advance(to: .completed)
        try context.save()
    }

    private func loadCheckpoint(
        row: SupabaseFarmAccessDescriptor,
        record: FarmRemoteRestoreRecord,
        context: ModelContext
    ) async throws -> FarmCompactRemoteCheckpoint {
        if let relativePath = record.checkpointRelativePath,
           let digest = record.checkpointDigest {
            let url = try Self.restoreRootURL()
                .appending(path: relativePath)
            if let archive = try? Data(contentsOf: url),
               FarmCompactBaselineArchive.digest(archive) == digest,
               let migrationID = record.checkpointMigrationID,
               let checkpointID = record.checkpointID {
                let package = try FarmCompactBaselineArchive.decode(archive)
                return FarmCompactRemoteCheckpoint(
                    checkpointID: checkpointID,
                    farmID: row.farmID,
                    migrationID: migrationID,
                    authorityGeneration: row.authorityGeneration,
                    throughRevision: record.checkpointRevision,
                    archive: archive,
                    archiveDigest: digest,
                    archiveByteCount: archive.count,
                    projectionCount: package.manifest.projectionCount,
                    tombstoneProjectionCount:
                        package.manifest.tombstoneProjectionCount,
                    tombstoneHistoryCount:
                        package.manifest.tombstoneHistoryCount,
                    historyOperationCount:
                        package.manifest.historyOperationCount,
                    assetCount: package.manifest.assetCount
                )
            }
        }

        let checkpoint = try await transport.downloadLatestCompactCheckpoint(
            farmID: row.farmID,
            authorityGeneration: row.authorityGeneration
        )
        let relativePath = Self.checkpointRelativePath(
            farmID: row.farmID,
            checkpointID: checkpoint.checkpointID
        )
        let destination = try Self.restoreRootURL()
            .appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try checkpoint.archive.write(
            to: destination,
            options: [.atomic, .completeFileProtection]
        )
        record.checkpointID = checkpoint.checkpointID
        record.checkpointMigrationID = checkpoint.migrationID
        record.checkpointRelativePath = relativePath
        record.checkpointDigest = checkpoint.archiveDigest
        record.checkpointRevision = checkpoint.throughRevision
        try context.save()
        return checkpoint
    }

    private func validate(
        checkpoint: FarmCompactRemoteCheckpoint,
        package: FarmCompactBaselinePackageV1,
        row: SupabaseFarmAccessDescriptor,
        ownerAccountID: UUID
    ) throws {
        guard package.manifest.farmID == row.farmID,
              package.farm.ownerAccountID == ownerAccountID,
              package.manifest.authorityGeneration ==
                row.authorityGeneration,
              package.manifest.migrationID == checkpoint.migrationID,
              package.manifest.projectionCount == checkpoint.projectionCount,
              package.manifest.tombstoneProjectionCount ==
                checkpoint.tombstoneProjectionCount,
              package.manifest.tombstoneHistoryCount ==
                checkpoint.tombstoneHistoryCount,
              package.manifest.historyOperationCount ==
                checkpoint.historyOperationCount,
              package.manifest.assetCount == checkpoint.assetCount,
              checkpoint.archive.count == checkpoint.archiveByteCount,
              FarmCompactBaselineArchive.digest(checkpoint.archive) ==
                checkpoint.archiveDigest else {
            throw SupabaseFarmAccessRecoveryError.invalidCheckpoint
        }
    }

    private func downloadAssets(
        package: FarmCompactBaselinePackageV1,
        record: FarmRemoteRestoreRecord,
        context: ModelContext
    ) async throws {
        var completed = 0
        for asset in package.assets {
            try Task.checkCancellation()
            let destination = try Self.stagedAssetURL(
                farmID: package.manifest.farmID,
                checkpointID: record.checkpointID,
                asset: asset
            )
            if let existing = try? Data(contentsOf: destination),
               Int64(existing.count) == asset.byteCount,
               FarmCompactBaselineArchive.digest(existing) ==
                asset.sha256.lowercased() {
                completed += 1
                continue
            }
            let remote = FarmRemoteAsset(
                assetID: asset.assetID,
                farmID: package.manifest.farmID,
                sha256: asset.sha256.lowercased(),
                byteCount: asset.byteCount,
                contentType: asset.contentType,
                storagePath:
                    "\(package.manifest.farmID.uuidString.lowercased())/" +
                    asset.sha256.lowercased()
            )
            let data = try await transport.downloadAsset(remote)
            guard Int64(data.count) == asset.byteCount,
                  FarmCompactBaselineArchive.digest(data) ==
                    asset.sha256.lowercased() else {
                throw SupabaseFarmAccessRecoveryError.assetMismatch(
                    asset.assetID
                )
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtection]
            )
            completed += 1
            record.downloadedAssetCount = completed
            record.updatedAt = .now
            try context.save()
        }
        record.downloadedAssetCount = completed
        try context.save()
    }

    private func promoteAssets(
        package: FarmCompactBaselinePackageV1,
        record: FarmRemoteRestoreRecord,
        context: ModelContext
    ) throws {
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
        let photosByID = Dictionary(
            uniqueKeysWithValues: photos
                .filter { $0.farmID == package.manifest.farmID }
                .map { ($0.id, $0) }
        )
        var promoted = 0
        for asset in package.assets {
            guard let photo = photosByID[asset.assetID] else {
                throw SupabaseFarmAccessRecoveryError.assetMismatch(
                    asset.assetID
                )
            }
            let source = try Self.stagedAssetURL(
                farmID: package.manifest.farmID,
                checkpointID: record.checkpointID,
                asset: asset
            )
            let data = try Data(contentsOf: source)
            guard Int64(data.count) == asset.byteCount,
                  FarmCompactBaselineArchive.digest(data) ==
                    asset.sha256.lowercased() else {
                throw SupabaseFarmAccessRecoveryError.assetMismatch(
                    asset.assetID
                )
            }
            let fileExtension =
                asset.contentType.lowercased() == "image/heic" ? "heic" : "jpg"
            let destination = try PhotoTransferActor.assetURL(
                farmID: package.manifest.farmID,
                assetID: asset.assetID,
                fileExtension: fileExtension
            )
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtection]
            )
            photo.relativePath = PhotoTransferActor.relativePath(
                for: destination
            )
            photo.sha256 = asset.sha256.lowercased()
            photo.cloudRecordName =
                "\(package.manifest.farmID.uuidString.lowercased())/" +
                asset.sha256.lowercased()
            photo.isCloudAuthoritative = true
            promoted += 1
            record.promotedAssetCount = promoted
            record.updatedAt = .now
            try context.save()
        }
    }

    private static func restoreRootURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "SupabaseRemoteRestores", directoryHint: .isDirectory)
    }

    private static func checkpointRelativePath(
        farmID: UUID,
        checkpointID: UUID
    ) -> String {
        "\(farmID.uuidString.lowercased())/" +
            "\(checkpointID.uuidString.lowercased())/checkpoint.esbc"
    }

    private static func stagedAssetURL(
        farmID: UUID,
        checkpointID: UUID?,
        asset: FarmCompactBaselinePackageV1.Asset
    ) throws -> URL {
        guard let checkpointID else {
            throw SupabaseFarmAccessRecoveryError.invalidCheckpoint
        }
        let fileExtension =
            asset.contentType.lowercased() == "image/heic" ? "heic" : "jpg"
        return try restoreRootURL()
            .appending(
                path: farmID.uuidString.lowercased(),
                directoryHint: .isDirectory
            )
            .appending(
                path: checkpointID.uuidString.lowercased(),
                directoryHint: .isDirectory
            )
            .appending(path: "assets", directoryHint: .isDirectory)
            .appending(path: "\(asset.assetID.uuidString.lowercased()).\(fileExtension)")
    }

    private static func errorCode(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}

@MainActor
private extension SupabaseFarmAccessRecoveryService {
    func activateVerifiedLocalCacheIfAvailable(
        descriptor: SupabaseFarmAccessDescriptor,
        accountID: UUID,
        role: FarmRole,
        existingRecord: FarmRemoteRestoreRecord?,
        context: ModelContext
    ) throws -> Bool {
        let hasVerifiedIdentityRestore = existingRecord?.state == .completed &&
            existingRecord?.authorityGeneration == descriptor.authorityGeneration &&
            (existingRecord?.ownerAccountID == nil ||
                existingRecord?.ownerAccountID == descriptor.ownerAccountID) &&
            (existingRecord?.serverMembershipID == nil ||
                existingRecord?.serverMembershipID == descriptor.serverMembershipID)
        let isExistingOwnerAuthorityCache = role == .owner &&
            descriptor.ownerAccountID == accountID
        guard hasVerifiedIdentityRestore || isExistingOwnerAuthorityCache else {
            return false
        }
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == descriptor.farmID }),
              let profile = try context
                .fetch(FetchDescriptor<FarmStorageProfile>())
                .first(where: { $0.farmID == descriptor.farmID }),
              let binding = try context
                .fetch(FetchDescriptor<FarmRemoteBinding>())
                .first(where: {
                    $0.farmID == descriptor.farmID &&
                        $0.provider == .supabase
                }),
              farm.ownerAccountID == descriptor.ownerAccountID,
              profile.mode == .supabase,
              profile.transitionState == .idle,
              profile.authorityGeneration == descriptor.authorityGeneration,
              binding.ownerAccountID == descriptor.ownerAccountID,
              binding.authorityGeneration == descriptor.authorityGeneration,
              binding.state == .active else {
            return false
        }

        farm.roleRawValue = role.rawValue
        farm.membershipStatusRawValue = FarmMembershipStatus.active.rawValue
        farm.updatedAt = .now
        binding.stateRawValue = FarmRemoteBindingState.active.rawValue
        binding.lastErrorCode = nil
        binding.updatedAt = .now

        if let membership = try context
            .fetch(FetchDescriptor<FarmMembershipBinding>())
            .first(where: {
                $0.farmID == descriptor.farmID && $0.accountID == accountID
            }) {
            membership.serverMembershipID = descriptor.serverMembershipID
            membership.roleRawValue = role.rawValue
            membership.statusRawValue = FarmMembershipStatus.active.rawValue
            membership.updatedAt = .now
        } else {
            context.insert(FarmMembershipBinding(
                serverMembershipID: descriptor.serverMembershipID,
                farmID: descriptor.farmID,
                accountID: accountID,
                role: role,
                status: .active
            ))
        }

        let record = existingRecord ?? FarmRemoteRestoreRecord(
            accountID: accountID,
            farmID: descriptor.farmID,
            authorityGeneration: descriptor.authorityGeneration,
            ownerAccountID: descriptor.ownerAccountID,
            memberRole: role,
            serverMembershipID: descriptor.serverMembershipID,
            targetCursorRevision: descriptor.currentRevision
        )
        if existingRecord == nil {
            context.insert(record)
        }
        record.ownerAccountID = descriptor.ownerAccountID
        record.memberRoleRawValue = role.rawValue
        record.serverMembershipID = descriptor.serverMembershipID
        record.currentCursorRevision = max(
            record.currentCursorRevision,
            binding.lastPulledRevision
        )
        record.targetCursorRevision = max(
            descriptor.currentRevision,
            record.currentCursorRevision
        )
        record.advance(to: .completed)
        try context.save()
        return true
    }

    func reconcileRevokedAccess(
        accountID: UUID,
        activeFarmIDs: Set<UUID>,
        context: ModelContext
    ) throws {
        let supabaseFarmIDs = Set(
            try context.fetch(FetchDescriptor<FarmRemoteBinding>())
                .filter { $0.provider == .supabase }
                .map(\.farmID)
        )
        let revokedFarmIDs = Set(
            try context.fetch(FetchDescriptor<FarmMembershipBinding>())
                .filter {
                    $0.accountID == accountID &&
                        $0.status == .active &&
                        supabaseFarmIDs.contains($0.farmID) &&
                        !activeFarmIDs.contains($0.farmID)
                }
                .map(\.farmID)
        )
        guard !revokedFarmIDs.isEmpty else { return }

        for membership in try context
            .fetch(FetchDescriptor<FarmMembershipBinding>()) where
            membership.accountID == accountID &&
                revokedFarmIDs.contains(membership.farmID) {
            membership.statusRawValue = FarmMembershipStatus.revoked.rawValue
            membership.updatedAt = .now
        }
        for binding in try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            where binding.provider == .supabase &&
                revokedFarmIDs.contains(binding.farmID) {
            binding.stateRawValue = FarmRemoteBindingState.accessRevoked.rawValue
            binding.lastErrorCode = "membership_revoked"
            binding.updatedAt = .now
        }
        for farm in try context.fetch(FetchDescriptor<FarmRecord>())
            where revokedFarmIDs.contains(farm.id) {
            farm.membershipStatusRawValue = FarmMembershipStatus.revoked.rawValue
            farm.updatedAt = .now
        }
        for item in try context.fetch(FetchDescriptor<OutboxItem>())
            where item.accountID == accountID &&
                revokedFarmIDs.contains(item.farmID) &&
                item.deliveryProvider == .supabase &&
                SupabaseFarmAccessIsolationPolicy.shouldQuarantine(item.status) {
            item.statusRawValue =
                OutboxStatus.quarantinedMembershipRevoked.rawValue
            item.errorMessage = "membership_revoked"
            item.nextRetryAt = nil
        }
        try context.save()
    }
}

/// Compatibility facade for the existing foreground recovery call site. The
/// implementation now restores every active access row, including invited
/// members, rather than filtering to registry owners.
@MainActor
struct SupabaseOwnedFarmDiscoveryService {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    @discardableResult
    func discoverAndRestoreOwnedFarms(
        accountID: UUID,
        context: ModelContext
    ) async throws -> [UUID] {
        try await SupabaseFarmAccessRecoveryService(client: client)
            .discoverAndRestoreAccessibleFarms(
                accountID: accountID,
                context: context
            )
    }
}
