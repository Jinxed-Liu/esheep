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

enum SupabaseOwnedFarmDiscoveryError: LocalizedError {
    case invalidCheckpoint
    case accountMismatch
    case farmAlreadyExists
    case assetMismatch(UUID)
    case restoreRecordMismatch

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
        }
    }
}

@MainActor
struct SupabaseOwnedFarmDiscoveryService {
    private struct RegistryRow: Decodable, Sendable {
        let farmID: UUID
        let ownerUserID: UUID
        let provider: String
        let status: String
        let authorityGeneration: Int
        let currentRevision: Int

        enum CodingKeys: String, CodingKey {
            case farmID = "farm_id"
            case ownerUserID = "owner_user_id"
            case provider
            case status
            case authorityGeneration = "authority_generation"
            case currentRevision = "current_revision"
        }
    }

    private struct MemberRow: Decodable, Sendable {
        let userID: UUID
        let appAccountID: UUID
        let role: String

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case appAccountID = "app_account_id"
            case role
        }
    }

    private let client: SupabaseClient
    private let transport: SupabaseFarmTransport

    init(client: SupabaseClient) {
        self.client = client
        self.transport = SupabaseFarmTransport(client: client)
    }

    @discardableResult
    func discoverAndRestoreOwnedFarms(
        accountID: UUID,
        context: ModelContext
    ) async throws -> [UUID] {
        let session = try await client.auth.session
        let rows: [RegistryRow] = try await client
            .from("farm_registry")
            .select(
                "farm_id,owner_user_id,provider,status," +
                    "authority_generation,current_revision"
            )
            .eq("owner_user_id", value: session.user.id)
            .eq("provider", value: "supabase")
            .eq("status", value: "active")
            .execute()
            .value
        var restored: [UUID] = []
        for row in rows {
            let pendingRecords = try context.fetch(
                FetchDescriptor<FarmRemoteRestoreRecord>()
            ).filter {
                $0.accountID == accountID &&
                    $0.farmID == row.farmID &&
                    $0.state != .completed
            }
            if pendingRecords.isEmpty,
               try context.fetch(FetchDescriptor<FarmRemoteBinding>())
                .contains(where: {
                    $0.farmID == row.farmID &&
                        $0.provider == .supabase &&
                        $0.state == .active
                }) {
                continue
            }
            let restoreRecord = try prepareRestoreRecord(
                row: row,
                accountID: accountID,
                ownerAccountID: accountID,
                memberRole: .owner,
                memberUserID: row.ownerUserID,
                pendingRecords: pendingRecords,
                context: context
            )
            do {
                try await restore(
                    row: row,
                    accountID: accountID,
                    ownerAccountID: accountID,
                    record: restoreRecord,
                    context: context
                )
                restored.append(row.farmID)
            } catch {
                restoreRecord.stateRawValue =
                    FarmRemoteRestoreState.failed.rawValue
                restoreRecord.lastErrorCode = Self.errorCode(error)
                restoreRecord.updatedAt = .now
                try? context.save()
                throw error
            }
        }
        return restored
    }

    @discardableResult
    func restoreRedeemedFarm(
        farmID: UUID,
        authorityGeneration: Int,
        accountID: UUID,
        context: ModelContext
    ) async throws -> FarmRecord {
        let session = try await client.auth.session
        let registryRows: [RegistryRow] = try await client
            .from("farm_registry")
            .select(
                "farm_id,owner_user_id,provider,status," +
                    "authority_generation,current_revision"
            )
            .eq("farm_id", value: farmID)
            .eq("provider", value: "supabase")
            .eq("status", value: "active")
            .limit(1)
            .execute()
            .value
        guard let row = registryRows.first,
              row.authorityGeneration == authorityGeneration else {
            throw SupabaseOwnedFarmDiscoveryError.invalidCheckpoint
        }

        let memberRows: [MemberRow] = try await client
            .from("farm_members")
            .select("user_id,app_account_id,role")
            .eq("farm_id", value: farmID)
            .eq("status", value: "active")
            .execute()
            .value
        guard let owner = memberRows.first(where: {
            $0.userID == row.ownerUserID && $0.role == FarmRole.owner.rawValue
        }),
        let member = memberRows.first(where: { $0.userID == session.user.id }),
        let memberRole = FarmRole(rawValue: member.role) else {
            throw SupabaseOwnedFarmDiscoveryError.accountMismatch
        }

        if let existing = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == farmID }),
           try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .contains(where: {
                $0.farmID == farmID &&
                    $0.provider == .supabase &&
                    $0.state == .active
            }) {
            existing.roleRawValue = memberRole.rawValue
            existing.membershipStatusRawValue =
                FarmMembershipStatus.active.rawValue
            try context.save()
            return existing
        }

        let pendingRecords = try context.fetch(
            FetchDescriptor<FarmRemoteRestoreRecord>()
        ).filter {
            $0.accountID == accountID &&
                $0.farmID == farmID &&
                $0.state != .completed
        }
        let restoreRecord = try prepareRestoreRecord(
            row: row,
            accountID: accountID,
            ownerAccountID: owner.appAccountID,
            memberRole: memberRole,
            memberUserID: session.user.id,
            pendingRecords: pendingRecords,
            context: context
        )
        do {
            try await restore(
                row: row,
                accountID: accountID,
                ownerAccountID: owner.appAccountID,
                record: restoreRecord,
                context: context
            )
        } catch {
            restoreRecord.stateRawValue = FarmRemoteRestoreState.failed.rawValue
            restoreRecord.lastErrorCode = Self.errorCode(error)
            restoreRecord.updatedAt = .now
            try? context.save()
            throw error
        }
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == farmID }) else {
            throw SupabaseOwnedFarmDiscoveryError.invalidCheckpoint
        }
        return farm
    }

    private func prepareRestoreRecord(
        row: RegistryRow,
        accountID: UUID,
        ownerAccountID: UUID,
        memberRole: FarmRole,
        memberUserID: UUID,
        pendingRecords: [FarmRemoteRestoreRecord],
        context: ModelContext
    ) throws -> FarmRemoteRestoreRecord {
        let serverMembershipID = Self.serverMembershipID(
            farmID: row.farmID,
            userID: memberUserID
        )
        let record: FarmRemoteRestoreRecord
        if let existing = Self.preferredRestoreRecord(pendingRecords) {
            guard existing.authorityGeneration == row.authorityGeneration else {
                throw SupabaseOwnedFarmDiscoveryError.restoreRecordMismatch
            }
            record = existing
            for duplicate in pendingRecords where duplicate.id != existing.id {
                context.delete(duplicate)
            }
        } else {
            record = FarmRemoteRestoreRecord(
                accountID: accountID,
                farmID: row.farmID,
                authorityGeneration: row.authorityGeneration,
                ownerAccountID: ownerAccountID,
                memberRole: memberRole,
                serverMembershipID: serverMembershipID,
                targetCursorRevision: row.currentRevision
            )
            context.insert(record)
        }
        record.ownerAccountID = ownerAccountID
        record.memberRoleRawValue = memberRole.rawValue
        record.serverMembershipID = serverMembershipID
        record.targetCursorRevision = max(
            record.targetCursorRevision,
            row.currentRevision
        )
        record.updatedAt = .now
        try context.save()
        return record
    }

    static func preferredRestoreRecord(
        _ records: [FarmRemoteRestoreRecord]
    ) -> FarmRemoteRestoreRecord? {
        records.max { lhs, rhs in
            let lhsProgress = (
                lhs.currentCursorRevision,
                lhs.promotedAssetCount,
                lhs.downloadedAssetCount,
                lhs.restoredEntityCount,
                lhs.checkpointRelativePath == nil ? 0 : 1
            )
            let rhsProgress = (
                rhs.currentCursorRevision,
                rhs.promotedAssetCount,
                rhs.downloadedAssetCount,
                rhs.restoredEntityCount,
                rhs.checkpointRelativePath == nil ? 0 : 1
            )
            if lhsProgress.0 != rhsProgress.0 {
                return lhsProgress.0 < rhsProgress.0
            }
            if lhsProgress.1 != rhsProgress.1 {
                return lhsProgress.1 < rhsProgress.1
            }
            if lhsProgress.2 != rhsProgress.2 {
                return lhsProgress.2 < rhsProgress.2
            }
            if lhsProgress.3 != rhsProgress.3 {
                return lhsProgress.3 < rhsProgress.3
            }
            if lhsProgress.4 != rhsProgress.4 {
                return lhsProgress.4 < rhsProgress.4
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func restore(
        row: RegistryRow,
        accountID: UUID,
        ownerAccountID: UUID,
        record: FarmRemoteRestoreRecord,
        context: ModelContext
    ) async throws {
        guard let memberRole = record.memberRole else {
            throw SupabaseOwnedFarmDiscoveryError.restoreRecordMismatch
        }
        let session = try await client.auth.session
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
            ownerAccountID: ownerAccountID
        )
        record.checkpointID = checkpoint.checkpointID
        record.checkpointMigrationID = checkpoint.migrationID
        record.checkpointDigest = checkpoint.archiveDigest
        record.checkpointRevision = checkpoint.throughRevision
        record.totalEntityCount = checkpoint.projectionCount
        record.totalAssetCount = checkpoint.assetCount

        let rebuildService = FarmCompactBaselineRebuildService()
        if let resumeCursor = try await rebuildService
            .resumeActivatedFarmIfPossible(
                farmID: row.farmID,
                migrationID: checkpoint.migrationID,
                packageDigest: checkpoint.archiveDigest,
                ownerAccountID: ownerAccountID,
                membershipAccountID: accountID,
                memberRole: memberRole,
                authorityGeneration: row.authorityGeneration,
                serverMembershipID: record.serverMembershipID ??
                    Self.serverMembershipID(
                        farmID: row.farmID,
                        userID: session.user.id
                    ),
                checkpointCursor: checkpoint.throughRevision,
                restoreCursor: record.currentCursorRevision,
                container: context.container
            ) {
            record.restoredEntityCount = checkpoint.projectionCount
            record.downloadedAssetCount = checkpoint.assetCount
            record.promotedAssetCount = checkpoint.assetCount
            record.currentCursorRevision = resumeCursor
            record.advance(to: .catchingUp)
            try context.save()
            await DevelopmentSupabaseRestoreGate.pauseIfArmed(at: .catchingUp)
            let syncResult = try await FarmRemoteSyncCoordinator(
                container: context.container,
                transport: transport
            ).catchUpRestoredFarm(farmID: row.farmID)
            record.currentCursorRevision = syncResult.cursorRevision
            record.targetCursorRevision = max(
                record.targetCursorRevision,
                syncResult.cursorRevision
            )
            try await rebuildService.activatePreparedRestoredFarm(
                farmID: row.farmID,
                ownerAccountID: ownerAccountID,
                memberRole: memberRole,
                authorityGeneration: row.authorityGeneration,
                container: context.container
            )
            record.advance(to: .completed)
            try context.save()
            return
        }

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
        try await rebuildService.verify(
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

        if let existingFarm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == row.farmID }) {
            guard existingFarm.ownerAccountID == ownerAccountID else {
                throw SupabaseOwnedFarmDiscoveryError.accountMismatch
            }
            let markerPrefix = "compact-discovery:" +
                "\(checkpoint.migrationID.uuidString.lowercased()):"
            let isResumable = try context
                .fetch(FetchDescriptor<CloudOperationReceipt>())
                .contains {
                    $0.farmID == row.farmID &&
                        $0.recordName.hasPrefix(markerPrefix)
                }
            let hasMatchingProfile = try context.fetch(
                FetchDescriptor<FarmStorageProfile>()
            ).contains {
                $0.farmID == row.farmID &&
                    $0.mode == .supabase &&
                    $0.authorityGeneration == row.authorityGeneration
            }
            guard isResumable || hasMatchingProfile else {
                throw SupabaseOwnedFarmDiscoveryError.farmAlreadyExists
            }
        }

        try await rebuildService.restoreAuthoritativeCache(
                package: package,
                packageDigest: checkpoint.archiveDigest,
                ownerAccountID: ownerAccountID,
                cursor: checkpoint.throughRevision,
                activate: false,
                container: context.container
            )
        try promoteAssets(
            package: package,
            record: record,
            context: context
        )
        try await rebuildService.finalizeRestoredFarm(
            package: package,
            ownerAccountID: ownerAccountID,
            cursor: checkpoint.throughRevision,
            serverMembershipID: record.serverMembershipID,
            membershipAccountID: accountID,
            memberRole: memberRole,
            activate: false,
            container: context.container
        )

        record.currentCursorRevision = checkpoint.throughRevision
        record.advance(to: .catchingUp)
        try context.save()
        await DevelopmentSupabaseRestoreGate.pauseIfArmed(at: .catchingUp)
        let syncResult = try await FarmRemoteSyncCoordinator(
            container: context.container,
            transport: transport
        ).catchUpRestoredFarm(farmID: row.farmID)
        record.currentCursorRevision = syncResult.cursorRevision
        record.targetCursorRevision = max(
            record.targetCursorRevision,
            syncResult.cursorRevision
        )
        try await rebuildService.activatePreparedRestoredFarm(
            farmID: row.farmID,
            ownerAccountID: ownerAccountID,
            memberRole: memberRole,
            authorityGeneration: row.authorityGeneration,
            container: context.container
        )
        record.advance(to: .completed)
        try context.save()
    }

    private func loadCheckpoint(
        row: RegistryRow,
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
        row: RegistryRow,
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
            throw SupabaseOwnedFarmDiscoveryError.invalidCheckpoint
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
                throw SupabaseOwnedFarmDiscoveryError.assetMismatch(
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
                throw SupabaseOwnedFarmDiscoveryError.assetMismatch(
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
                throw SupabaseOwnedFarmDiscoveryError.assetMismatch(
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
            throw SupabaseOwnedFarmDiscoveryError.invalidCheckpoint
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
        return "\(value.domain):\(value.code):" +
            String(error.localizedDescription.prefix(320))
    }

    private static func serverMembershipID(
        farmID: UUID,
        userID: UUID
    ) -> String {
        "supabase:\(farmID.uuidString.lowercased()):" +
            userID.uuidString.lowercased()
    }
}
