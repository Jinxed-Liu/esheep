import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FarmRemoteRestoreAndStorageTests: XCTestCase {
    func testRestoreRetryKeepsTheMostAdvancedDuplicateRecord() {
        let accountID = UUID()
        let farmID = UUID()
        let advanced = FarmRemoteRestoreRecord(
            accountID: accountID,
            farmID: farmID,
            authorityGeneration: 1,
            state: .failed,
            targetCursorRevision: 847
        )
        advanced.currentCursorRevision = 842
        advanced.restoredEntityCount = 21_479
        advanced.downloadedAssetCount = 7
        advanced.promotedAssetCount = 7

        let newerButEarlier = FarmRemoteRestoreRecord(
            accountID: accountID,
            farmID: farmID,
            authorityGeneration: 1,
            state: .promoting,
            targetCursorRevision: 847
        )
        newerButEarlier.restoredEntityCount = 21_479
        newerButEarlier.updatedAt = advanced.updatedAt.addingTimeInterval(60)

        XCTAssertEqual(
            SupabaseOwnedFarmDiscoveryService.preferredRestoreRecord([
                newerButEarlier,
                advanced,
            ])?.id,
            advanced.id
        )
    }

    func testActivatedRestoreResumeUsesConservativeCursor() {
        XCTAssertEqual(
            FarmCompactBaselineRebuildService.conservativeResumeCursor(
                checkpointRevision: 0,
                restoreRevision: 842,
                bindingRevision: 845
            ),
            842
        )
        XCTAssertEqual(
            FarmCompactBaselineRebuildService.conservativeResumeCursor(
                checkpointRevision: 0,
                restoreRevision: 0,
                bindingRevision: 845
            ),
            0
        )
        XCTAssertEqual(
            FarmCompactBaselineRebuildService.conservativeResumeCursor(
                checkpointRevision: 100,
                restoreRevision: 120,
                bindingRevision: 110
            ),
            110
        )
    }

    func testActivatedRestoreResumePreparesOwnerUntilCatchUpCompletes() async throws {
        let container = try AppSchema.makeContainer(
            name: "ActivatedSupabaseRestoreResumeTests",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerAccountID = UUID()
        let migrationID = UUID()
        let packageDigest = String(repeating: "a", count: 64)
        let serverMembershipID =
            "supabase:\(farmID.uuidString.lowercased()):\(UUID().uuidString.lowercased())"
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: ownerAccountID,
            name: "恢复牧场",
            role: .worker
        )
        farm.membershipStatusRawValue = FarmMembershipStatus.revoked.rawValue
        context.insert(farm)
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .supabase,
            authorityGeneration: 1
        ))
        let binding = FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            provider: .supabase,
            state: .accessRevoked,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        )
        binding.lastPulledRevision = 845
        binding.lastErrorCode = "membership_revoked"
        context.insert(binding)
        context.insert(FarmMembershipBinding(
            serverMembershipID: serverMembershipID,
            farmID: farmID,
            accountID: ownerAccountID,
            role: .owner,
            status: .revoked
        ))
        context.insert(CloudOperationReceipt(
            farmID: farmID,
            operationID: UUID(),
            recordName:
                "compact-discovery:\(migrationID.uuidString.lowercased()):root",
            serverChangeTag: packageDigest,
            databaseScope: .privateDatabase
        ))
        try context.save()

        let resumedCursor = try await FarmCompactBaselineRebuildService()
            .resumeActivatedFarmIfPossible(
                farmID: farmID,
                migrationID: migrationID,
                packageDigest: packageDigest,
                ownerAccountID: ownerAccountID,
                authorityGeneration: 1,
                serverMembershipID: serverMembershipID,
                checkpointCursor: 0,
                restoreCursor: 842,
                container: container
            )

        XCTAssertEqual(resumedCursor, 842)
        let verification = ModelContext(container)
        let resumedFarm = try XCTUnwrap(
            verification.fetch(FetchDescriptor<FarmRecord>())
                .first { $0.id == farmID }
        )
        let resumedBinding = try XCTUnwrap(
            verification.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first { $0.farmID == farmID }
        )
        let resumedMembership = try XCTUnwrap(
            verification.fetch(FetchDescriptor<FarmMembershipBinding>())
                .first {
                    $0.farmID == farmID && $0.accountID == ownerAccountID
                }
        )
        XCTAssertEqual(resumedFarm.role, .owner)
        XCTAssertEqual(
            resumedFarm.membershipStatusRawValue,
            FarmMembershipStatus.active.rawValue
        )
        XCTAssertEqual(resumedBinding.state, .preparing)
        XCTAssertEqual(resumedBinding.lastPulledRevision, 842)
        XCTAssertNil(resumedBinding.lastErrorCode)
        XCTAssertEqual(resumedMembership.status, .active)
        XCTAssertEqual(resumedMembership.role, .owner)
        XCTAssertEqual(
            resumedMembership.serverMembershipID,
            serverMembershipID
        )

        try await FarmCompactBaselineRebuildService()
            .activatePreparedRestoredFarm(
                farmID: farmID,
                ownerAccountID: ownerAccountID,
                authorityGeneration: 1,
                container: container
            )
        let activatedContext = ModelContext(container)
        XCTAssertEqual(
            try activatedContext.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first { $0.farmID == farmID }?.state,
            .active
        )
    }

    func testActivatedRestoreResumePreservesInvitedWorkerIdentity() async throws {
        let container = try AppSchema.makeContainer(
            name: "InvitedWorkerSupabaseRestoreResumeTests",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerAccountID = UUID()
        let workerAccountID = UUID()
        let migrationID = UUID()
        let packageDigest = String(repeating: "b", count: 64)
        let serverMembershipID =
            "supabase:\(farmID.uuidString.lowercased()):worker-user"
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: ownerAccountID,
            name: "受邀恢复牧场",
            role: .owner
        )
        context.insert(farm)
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .supabase,
            authorityGeneration: 1
        ))
        let binding = FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            provider: .supabase,
            state: .preparing,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        )
        context.insert(binding)
        context.insert(CloudOperationReceipt(
            farmID: farmID,
            operationID: UUID(),
            recordName:
                "compact-discovery:\(migrationID.uuidString.lowercased()):root",
            serverChangeTag: packageDigest,
            databaseScope: .privateDatabase
        ))
        try context.save()

        let resumedCursor = try await FarmCompactBaselineRebuildService()
            .resumeActivatedFarmIfPossible(
                farmID: farmID,
                migrationID: migrationID,
                packageDigest: packageDigest,
                ownerAccountID: ownerAccountID,
                membershipAccountID: workerAccountID,
                memberRole: .worker,
                authorityGeneration: 1,
                serverMembershipID: serverMembershipID,
                checkpointCursor: 20,
                restoreCursor: 20,
                container: container
            )

        XCTAssertEqual(resumedCursor, 20)
        let verification = ModelContext(container)
        let restoredFarm = try XCTUnwrap(
            verification.fetch(FetchDescriptor<FarmRecord>())
                .first { $0.id == farmID }
        )
        let membership = try XCTUnwrap(
            verification.fetch(FetchDescriptor<FarmMembershipBinding>())
                .first {
                    $0.farmID == farmID &&
                        $0.accountID == workerAccountID
                }
        )
        XCTAssertEqual(restoredFarm.ownerAccountID, ownerAccountID)
        XCTAssertEqual(restoredFarm.role, .worker)
        XCTAssertEqual(membership.accountID, workerAccountID)
        XCTAssertEqual(membership.role, .worker)
        XCTAssertEqual(membership.status, .active)
        XCTAssertEqual(membership.serverMembershipID, serverMembershipID)

        try await FarmCompactBaselineRebuildService()
            .activatePreparedRestoredFarm(
                farmID: farmID,
                ownerAccountID: ownerAccountID,
                memberRole: .worker,
                authorityGeneration: 1,
                container: container
            )
        let activatedContext = ModelContext(container)
        XCTAssertEqual(
            try activatedContext.fetch(FetchDescriptor<FarmRecord>())
                .first { $0.id == farmID }?.role,
            .worker
        )
    }

    func testRevokedMembershipOutboxStatusRemainsTerminal() {
        XCTAssertTrue(
            OutboxStatus.quarantinedMembershipRevoked.isTerminalDelivery
        )
        XCTAssertFalse(OutboxStatus.retryableFailure.isTerminalDelivery)
    }

    @MainActor
    func testDevelopmentRestorePausePointIsConsumedOnce() {
        let suiteName = "DevelopmentSupabaseRestoreGateTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            FarmRemoteRestoreState.downloadingAssets.rawValue,
            forKey: DevelopmentSupabaseRestoreGate.pausePointKey
        )

        #if DEBUG
        XCTAssertTrue(
            DevelopmentSupabaseRestoreGate.consumePausePointIfArmed(
                at: .downloadingAssets,
                defaults: defaults,
                bundleIdentifier: "com.sheepfarm.next.dev"
            )
        )
        XCTAssertFalse(
            DevelopmentSupabaseRestoreGate.consumePausePointIfArmed(
                at: .downloadingAssets,
                defaults: defaults,
                bundleIdentifier: "com.sheepfarm.next.dev"
            )
        )
        XCTAssertEqual(
            defaults.string(
                forKey: DevelopmentSupabaseRestoreGate.lastPausedPointKey
            ),
            FarmRemoteRestoreState.downloadingAssets.rawValue
        )
        #else
        XCTAssertFalse(
            DevelopmentSupabaseRestoreGate.consumePausePointIfArmed(
                at: .downloadingAssets,
                defaults: defaults,
                bundleIdentifier: "com.sheepfarm.next.dev"
            )
        )
        XCTAssertEqual(
            defaults.string(forKey: DevelopmentSupabaseRestoreGate.pausePointKey),
            FarmRemoteRestoreState.downloadingAssets.rawValue
        )
        XCTAssertNil(
            defaults.string(forKey: DevelopmentSupabaseRestoreGate.lastPausedPointKey)
        )
        #endif
    }

    func testRestoreRecordPersistsEveryRecoveryBoundary() throws {
        let accountID = UUID()
        let farmID = UUID()
        let record = FarmRemoteRestoreRecord(
            accountID: accountID,
            farmID: farmID,
            authorityGeneration: 1,
            targetCursorRevision: 42
        )

        XCTAssertEqual(record.state, .discovering)
        XCTAssertFalse(record.state.isTerminal)
        for state in [
            FarmRemoteRestoreState.downloadingCheckpoint,
            .rebuildingStaging,
            .downloadingAssets,
            .promoting,
            .catchingUp,
            .failed,
        ] {
            record.advance(to: state)
            XCTAssertEqual(record.state, state)
            XCTAssertNil(record.completedAt)
        }
        record.advance(to: .completed)
        XCTAssertTrue(record.state.isTerminal)
        XCTAssertNotNil(record.completedAt)
        XCTAssertEqual(record.accountID, accountID)
        XCTAssertEqual(record.farmID, farmID)
        XCTAssertEqual(record.authorityGeneration, 1)
        XCTAssertEqual(record.targetCursorRevision, 42)
    }

    func testPostRecoveryProjectionRepairKeepsDuplicateTransferRowsNonFatal() throws {
        let container = try AppSchema.makeContainer(
            name: "PostRecoveryDuplicateTransferTests",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let sheepID = UUID()
        let cutoff = Date().addingTimeInterval(-3_600)

        context.insert(CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            state: .active
        ))
        let session = CloudRebuildSessionRecord(
            farmID: farmID,
            databaseScope: .privateDatabase,
            reason: .manualVerification,
            stagingRelativePath: "CloudRebuild/duplicate-transfer"
        )
        session.statusRawValue = CloudRebuildStatus.completed.rawValue
        session.completedAt = cutoff
        context.insert(session)

        let sheep = SheepRecord(
            id: sheepID,
            farmID: farmID,
            earTag: "DUP-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: cutoff.addingTimeInterval(-86_400)
        )
        sheep.legacyStatusSnapshotIsAuthoritative = true
        sheep.legacyPenSnapshotIsAuthoritative = true
        context.insert(sheep)

        // A recovery/import can leave two rows with the same cloud entity ID.
        // Both rows must remain visible to the repair, but neither may crash
        // startup while the tombstone index is built.
        let duplicateTransferID = UUID()
        let firstTransfer = TransferRecord(
            id: duplicateTransferID,
            farmID: farmID,
            sheepID: sheepID,
            fromPenID: nil,
            toPenID: nil,
            occurredAt: cutoff.addingTimeInterval(60)
        )
        firstTransfer.recordedAt = cutoff.addingTimeInterval(61)
        let secondTransfer = TransferRecord(
            id: duplicateTransferID,
            farmID: farmID,
            sheepID: sheepID,
            fromPenID: nil,
            toPenID: nil,
            occurredAt: cutoff.addingTimeInterval(120)
        )
        secondTransfer.recordedAt = cutoff.addingTimeInterval(121)
        context.insert(firstTransfer)
        context.insert(secondTransfer)
        try context.save()

        XCTAssertNoThrow(
            try PostRecoveryHistoryProjectionRepair.repair(container: container)
        )
        XCTAssertFalse(
            try XCTUnwrap(
                ModelContext(container)
                    .fetch(FetchDescriptor<SheepRecord>())
                    .first { $0.id == sheepID }
            ).legacyStatusSnapshotIsAuthoritative ?? false
        )
    }

    func testInventoryOnlyCleansAllowlistedTerminalWorkspacesAfterBackupConfirmation() throws {
        let container = try AppSchema.makeContainer(
            name: "StorageInventoryTests",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let farmID = UUID()
        let failedSessionID = UUID()
        let activeSessionID = UUID()
        let migrationSessionID = UUID()
        let failedRelative =
            "CloudRebuild/\(failedSessionID.uuidString.lowercased())"
        let activeRelative =
            "CloudRebuild/\(activeSessionID.uuidString.lowercased())"
        let migrationRelative =
            "eSheepNext/MigrationWorkspaces/\(migrationSessionID.uuidString)"
        let failedURL = support.appending(path: failedRelative)
        let activeURL = support.appending(path: activeRelative)
        let migrationURL = support.appending(path: migrationRelative)
        let protectedURL = support
            .appending(path: "CloudAssets", directoryHint: .isDirectory)
            .appending(path: "storage-test-\(UUID().uuidString)")
        let diagnosticRoot = support.appending(
            path: "LocalStorageCleanupDiagnostics",
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: failedURL)
            try? FileManager.default.removeItem(at: activeURL)
            try? FileManager.default.removeItem(at: migrationURL)
            try? FileManager.default.removeItem(at: protectedURL)
        }
        for url in [failedURL, activeURL, migrationURL, protectedURL] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x5A, count: 8_192).write(
                to: url.appending(path: "evidence.bin"),
                options: .atomic
            )
        }

        let failed = CloudRebuildSessionRecord(
            id: failedSessionID,
            farmID: farmID,
            databaseScope: .privateDatabase,
            reason: .manualVerification,
            stagingRelativePath: failedRelative
        )
        failed.statusRawValue = CloudRebuildStatus.failed.rawValue
        failed.lastErrorCode = "network"
        context.insert(failed)

        let active = CloudRebuildSessionRecord(
            id: activeSessionID,
            farmID: farmID,
            databaseScope: .privateDatabase,
            reason: .manualVerification,
            stagingRelativePath: activeRelative
        )
        active.statusRawValue = CloudRebuildStatus.fetching.rawValue
        context.insert(active)
        context.insert(MigrationCommitRecord(
            sessionID: migrationSessionID,
            sourceChecksum: "digest",
            farmID: farmID,
            ownerAccountID: UUID(),
            recordCountsJSON: "{}",
            assetsRelativeDirectory: "assets"
        ))
        try context.save()

        let service = LocalStorageInventoryService()
        let inventory = try service.inventory(context: context)
        XCTAssertEqual(inventory.cleanupCandidates.count, 2)
        XCTAssertTrue(inventory.cleanupCandidates.contains {
            $0.sessionID == failedSessionID &&
                $0.kind == .cloudRebuild
        })
        XCTAssertTrue(inventory.cleanupCandidates.contains {
            $0.sessionID == migrationSessionID &&
                $0.kind == .completedMigrationWorkspace
        })
        XCTAssertFalse(inventory.cleanupCandidates.contains {
            $0.sessionID == activeSessionID
        })

        XCTAssertThrowsError(try service.clean(
            candidates: inventory.cleanupCandidates,
            externalBackupConfirmed: false,
            context: context
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrationURL.path))

        let receipt = try service.clean(
            candidates: inventory.cleanupCandidates,
            externalBackupConfirmed: true,
            context: context
        )
        XCTAssertEqual(receipt.candidates.count, 2)
        XCTAssertGreaterThan(receipt.reclaimedByteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: support
                .appending(path: receipt.diagnosticRelativePath)
                .path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticRoot.path))
    }
}
