import Foundation
import SwiftData

struct RetiredCloudFarmRemovalReport: Sendable, Equatable {
    let removedFarmIDs: [UUID]
    let removedRecordCount: Int
    let pendingFileCleanupCount: Int

    static let empty = RetiredCloudFarmRemovalReport(
        removedFarmIDs: [],
        removedRecordCount: 0,
        pendingFileCleanupCount: 0
    )

    var hasPendingFileCleanup: Bool {
        pendingFileCleanupCount > 0
    }
}

/// One-way cleanup for the retired Apple-cloud implementation.
///
/// A farm is removed when an old storage profile, remote binding, or
/// `CloudFarmBinding` identifies it. A farm that has already acquired a current
/// Supabase profile/binding is protected: only its obsolete provider metadata
/// is removed. The file manifest makes database-first deletion retryable if the
/// process is interrupted while local assets are being erased.
enum RetiredCloudFarmRemovalService {
    private static let retiredRawValue = FarmStorageMode.retiredAppleCloud.rawValue
    private static let manifestRelativePath =
        "eSheepNext/RetiredCloudCleanup/pending.json"

    private struct CleanupManifest: Codable {
        var farmIDs: [UUID]
        var relativePaths: [String]

        static let empty = CleanupManifest(farmIDs: [], relativePaths: [])

        mutating func merge(_ other: CleanupManifest) {
            farmIDs = Array(Set(farmIDs).union(other.farmIDs))
                .sorted { $0.uuidString < $1.uuidString }
            relativePaths = Array(Set(relativePaths).union(other.relativePaths))
                .sorted()
        }
    }

    static func removeRetiredCloudFarms(
        from container: ModelContainer,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> RetiredCloudFarmRemovalReport {
        let support = applicationSupportDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let context = ModelContext(container)

        let profiles = try context.fetch(FetchDescriptor<FarmStorageProfile>())
        let remoteBindings = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
        let legacyBindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())

        let candidateIDs = Set(
            profiles.lazy
                .filter {
                    $0.modeRawValue == retiredRawValue ||
                        $0.sourceModeRawValue == retiredRawValue ||
                        $0.targetModeRawValue == retiredRawValue
                }
                .map(\.farmID)
        )
        .union(remoteBindings.lazy
            .filter { $0.providerRawValue == retiredRawValue }
            .map(\.farmID))
        .union(legacyBindings.lazy.map(\.farmID))

        let protectedSupabaseIDs = Set(
            profiles.lazy
                .filter { $0.mode == .supabase }
                .map(\.farmID)
        )
        .union(remoteBindings.lazy
            .filter {
                $0.provider == .supabase &&
                    ![.archived, .accessRevoked, .failed].contains($0.state)
            }
            .map(\.farmID))
        let farmIDsToRemove = candidateIDs.subtracting(protectedSupabaseIDs)

        var pendingManifest = try loadManifest(
            applicationSupportDirectory: support,
            fileManager: fileManager
        )
        let currentManifest = try makeManifest(
            farmIDs: farmIDsToRemove,
            context: context
        )
        pendingManifest.merge(currentManifest)
        if !pendingManifest.farmIDs.isEmpty || !pendingManifest.relativePaths.isEmpty {
            try saveManifest(
                pendingManifest,
                applicationSupportDirectory: support,
                fileManager: fileManager
            )
        }

        var removedRecordCount = 0
        let migrationSessionIDs = Set(try context.fetch(FetchDescriptor<MigrationCommitRecord>())
            .lazy.filter { farmIDsToRemove.contains($0.farmID) }.map(\.sessionID))

        removedRecordCount += try deleteFarmScoped(FarmActivity.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(PenRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(SheepRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(WeightRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(WeaningRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(BreedingProgramRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(BreedingProgramStepRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TransferRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(RemovalRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(ProductionBatchRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(BatchMembershipRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(DailyPenCountRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedIngredientRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedRecipeRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedRecipeComponentRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedRecordLine.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedTroughObservationRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedStockTransactionRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedStockCountRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(InventoryLotRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(InventoryTransactionRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(HealthRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(ReproductionRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(SemenRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(SemenDonorRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(PedigreeChangeRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(NoteRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(DomainOperation.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(OutboxItem.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TombstoneRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(MigrationCommitRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteWhere(MigrationAuditRecord.self, context) {
            migrationSessionIDs.contains($0.sessionID)
        }
        removedRecordCount += try deleteFarmScoped(PhotoAssetRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(SheepAvatarRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(HealthSubjectLink.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(LambingOffspringRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FeedIngredientBatchRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(HealthCatalogItemRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(CareBatchRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(SemenTransactionRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FarmCareRuleRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(CareReminderRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FarmAlertDeferralRecord.self, farmIDsToRemove, context, \.farmID)

        removedRecordCount += try deleteFarmScoped(FarmMembershipBinding.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(SyncConflictRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(CloudOperationReceipt.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(CloudAssetTransfer.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteWhere(SecurityIncidentRecord.self, context) {
            $0.farmID.map(farmIDsToRemove.contains) ?? false
        }
        removedRecordCount += try deleteFarmScoped(FarmStorageProfile.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FarmRemoteBinding.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FarmOperationSequenceCounter.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FarmOperationSequenceRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FarmBaselineMigrationRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(FarmRemoteRestoreRecord.self, farmIDsToRemove, context, \.farmID)

        removedRecordCount += try deleteFarmScoped(TMRFormulaProfileRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRFeedingPlanRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRFeedingPlanPenRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRBatchRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRBatchIngredientRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRBatchLoadLineRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRBatchMovementRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRFeedingRunRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRFeedingAllocationRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRMealCompletionRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRDeviationAcknowledgementRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(TMRMonitoringRuleRecord.self, farmIDsToRemove, context, \.farmID)

        removedRecordCount += try deleteFarmScoped(InsightConversationRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(InsightMessageRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(InsightAttachmentRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(InsightActionDraftRecord.self, farmIDsToRemove, context, \.farmID)
        removedRecordCount += try deleteFarmScoped(InsightExecutionReceiptRecord.self, farmIDsToRemove, context, \.farmID)

        // These entities belonged exclusively to the retired cloud engine.
        // Remove them for every farm, including farms already migrated to
        // Supabase, while retaining provider-neutral Supabase state.
        removedRecordCount += try deleteAll(CloudFarmBinding.self, context)
        removedRecordCount += try deleteAll(CloudZoneState.self, context)
        removedRecordCount += try deleteAll(DeviceIdentityRecord.self, context)
        removedRecordCount += try deleteAll(CapabilityCertificateRecord.self, context)
        removedRecordCount += try deleteAll(RevokedCapabilityCertificateRecord.self, context)
        removedRecordCount += try deleteAll(FarmMembershipSnapshotRecord.self, context)
        removedRecordCount += try deleteAll(FarmCheckpointRecord.self, context)
        removedRecordCount += try deleteAll(FarmRecoveryAssetRecord.self, context)
        removedRecordCount += try deleteAll(CloudRebuildSessionRecord.self, context)
        removedRecordCount += try deleteAll(CloudRebuildIssueRecord.self, context)
        removedRecordCount += try deleteAll(CloudSyncDiagnosticSnapshotRecord.self, context)
        removedRecordCount += try deleteWhere(FarmRemoteBinding.self, context) {
            $0.providerRawValue == retiredRawValue
        }
        removedRecordCount += try deleteWhere(OutboxItem.self, context) {
            $0.deliveryProviderRawValue == retiredRawValue
        }

        var normalizedProfileCount = 0
        for profile in profiles where protectedSupabaseIDs.contains(profile.farmID) {
            guard profile.modeRawValue == retiredRawValue ||
                    profile.sourceModeRawValue == retiredRawValue ||
                    profile.targetModeRawValue == retiredRawValue else { continue }
            profile.modeRawValue = FarmStorageMode.supabase.rawValue
            profile.sourceModeRawValue = nil
            profile.targetModeRawValue = nil
            profile.transitionStateRawValue = FarmStorageTransitionState.idle.rawValue
            profile.migrationID = nil
            profile.updatedAt = .now
            normalizedProfileCount += 1
        }

        removedRecordCount += try deleteWhere(FarmRecord.self, context) {
            farmIDsToRemove.contains($0.id)
        }
        if removedRecordCount > 0 || normalizedProfileCount > 0 {
            try context.save()
        }

        let remainingPaths = removeManifestFiles(
            pendingManifest,
            applicationSupportDirectory: support,
            fileManager: fileManager
        )
        if remainingPaths.isEmpty {
            try? fileManager.removeItem(at: manifestURL(applicationSupportDirectory: support))
        } else {
            try saveManifest(
                CleanupManifest(farmIDs: [], relativePaths: remainingPaths),
                applicationSupportDirectory: support,
                fileManager: fileManager
            )
        }

        return RetiredCloudFarmRemovalReport(
            removedFarmIDs: farmIDsToRemove.sorted { $0.uuidString < $1.uuidString },
            removedRecordCount: removedRecordCount,
            pendingFileCleanupCount: remainingPaths.count
        )
    }

    private static func makeManifest(
        farmIDs: Set<UUID>,
        context: ModelContext
    ) throws -> CleanupManifest {
        var paths = Set<String>()
        for farmID in farmIDs {
            let id = farmID.uuidString.lowercased()
            paths.formUnion([
                "eSheepNext/CloudAssets/\(id)",
                "eSheepNext/FarmAssets/\(id)",
                "eSheepNext/Recovery/\(id)",
                "MigrationAssets/\(id)",
                "eSheepNext/MigrationAssets/\(id)",
            ])
        }
        for value in try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            where farmIDs.contains(value.farmID) && !value.relativePath.isEmpty {
            paths.insert(value.relativePath)
        }
        for value in try context.fetch(FetchDescriptor<CloudAssetTransfer>())
            where farmIDs.contains(value.farmID) && !value.localRelativePath.isEmpty {
            paths.insert(value.localRelativePath)
        }
        for value in try context.fetch(FetchDescriptor<FarmRecoveryAssetRecord>())
            where !value.encryptedRelativePath.isEmpty {
            paths.insert(value.encryptedRelativePath)
        }
        for value in try context.fetch(FetchDescriptor<FarmBaselineMigrationRecord>())
            where farmIDs.contains(value.farmID) && !value.packageRelativePath.isEmpty {
            paths.insert(value.packageRelativePath)
        }
        for value in try context.fetch(FetchDescriptor<MigrationCommitRecord>())
            where farmIDs.contains(value.farmID) && !value.assetsRelativeDirectory.isEmpty {
            paths.insert(value.assetsRelativeDirectory)
        }
        for value in try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            where !value.stagingRelativePath.isEmpty {
            paths.insert(value.stagingRelativePath)
        }
        return CleanupManifest(
            farmIDs: farmIDs.sorted { $0.uuidString < $1.uuidString },
            relativePaths: paths.sorted()
        )
    }

    private static func deleteFarmScoped<T: PersistentModel>(
        _ type: T.Type,
        _ farmIDs: Set<UUID>,
        _ context: ModelContext,
        _ farmID: KeyPath<T, UUID>
    ) throws -> Int {
        try deleteWhere(type, context) { farmIDs.contains($0[keyPath: farmID]) }
    }

    private static func deleteAll<T: PersistentModel>(
        _ type: T.Type,
        _ context: ModelContext
    ) throws -> Int {
        try deleteWhere(type, context) { _ in true }
    }

    private static func deleteWhere<T: PersistentModel>(
        _ type: T.Type,
        _ context: ModelContext,
        _ shouldDelete: (T) -> Bool
    ) throws -> Int {
        let values = try context.fetch(FetchDescriptor<T>()).filter(shouldDelete)
        for value in values {
            context.delete(value)
        }
        return values.count
    }

    private static func loadManifest(
        applicationSupportDirectory: URL,
        fileManager: FileManager
    ) throws -> CleanupManifest {
        let url = manifestURL(applicationSupportDirectory: applicationSupportDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(CleanupManifest.self, from: Data(contentsOf: url))
    }

    private static func saveManifest(
        _ manifest: CleanupManifest,
        applicationSupportDirectory: URL,
        fileManager: FileManager
    ) throws {
        let url = manifestURL(applicationSupportDirectory: applicationSupportDirectory)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    private static func manifestURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appending(path: manifestRelativePath)
    }

    private static func removeManifestFiles(
        _ manifest: CleanupManifest,
        applicationSupportDirectory: URL,
        fileManager: FileManager
    ) -> [String] {
        var remaining: [String] = []
        for path in manifest.relativePaths {
            let candidates = safeCandidateURLs(
                for: path,
                applicationSupportDirectory: applicationSupportDirectory
            )
            var failed = candidates.isEmpty
            for url in candidates where fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    failed = true
                }
            }
            if failed {
                remaining.append(path)
            }
        }
        return remaining
    }

    private static func safeCandidateURLs(
        for relativePath: String,
        applicationSupportDirectory: URL
    ) -> [URL] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            return []
        }
        let support = applicationSupportDirectory.standardizedFileURL
        var urls: [URL] = []
        if relativePath.hasPrefix("eSheepNext/") ||
            relativePath.hasPrefix("MigrationAssets/") ||
            relativePath.hasPrefix("Supabase") ||
            relativePath.hasPrefix("CloudRebuild/") {
            urls.append(support.appending(path: relativePath))
        } else {
            urls.append(support.appending(path: "eSheepNext/\(relativePath)"))
            urls.append(support.appending(path: relativePath))
        }
        return Array(Set(urls.map(\.standardizedFileURL))).filter {
            $0.path != support.path && $0.path.hasPrefix(support.path + "/")
        }
    }
}
