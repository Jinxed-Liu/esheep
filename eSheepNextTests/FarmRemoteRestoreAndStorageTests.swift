import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FarmRemoteRestoreAndStorageTests: XCTestCase {
    func testUnreadableCompactStagingStoreIsArchivedBeforeRebuild() throws {
        let farmID = UUID()
        let migrationID = UUID()
        let storeURL = FarmCompactBaselineRebuildProgressStore.storeURL(
            farmID: farmID,
            migrationID: migrationID
        )
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let archiveRoot = support
            .appending(path: "SupabaseCompactStagingIncompatible")
            .appending(path: farmID.uuidString.lowercased())
            .appending(path: migrationID.uuidString.lowercased())
        defer {
            try? FileManager.default.removeItem(
                at: storeURL.deletingLastPathComponent()
            )
            try? FileManager.default.removeItem(
                at: archiveRoot
            )
        }

        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unknown-model".utf8).write(to: storeURL)
        try Data("wal".utf8).write(
            to: URL(fileURLWithPath: storeURL.path + "-wal")
        )

        try FarmCompactBaselineRebuildProgressStore
            .archiveIncompatibleStore(
                farmID: farmID,
                migrationID: migrationID,
                error: NSError(
                    domain: NSCocoaErrorDomain,
                    code: 134_504,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Cannot use staged migration with an unknown model version."
                    ]
                )
            )

        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        let archives = try FileManager.default.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(archives.count, 1)
        let archive = try XCTUnwrap(archives.first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.appending(path: "staging.store").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.appending(path: "staging.store-wal").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.appending(path: "recovery.json").path
        ))
    }

    func testSupabaseAccessDescriptorDecodesOwnerAndCurrentMemberSeparately() throws {
        let farmID = UUID()
        let ownerUserID = UUID()
        let ownerAccountID = UUID()
        let memberUserID = UUID()
        let memberAccountID = UUID()
        let json = """
        {
          "farm_id": "\(farmID.uuidString.lowercased())",
          "owner_user_id": "\(ownerUserID.uuidString.lowercased())",
          "owner_app_account_id": "\(ownerAccountID.uuidString.lowercased())",
          "member_user_id": "\(memberUserID.uuidString.lowercased())",
          "member_app_account_id": "\(memberAccountID.uuidString.lowercased())",
          "member_role": "worker",
          "provider": "supabase",
          "farm_status": "active",
          "authority_generation": 1,
          "current_revision": 492
        }
        """
        let value = try JSONDecoder().decode(
            SupabaseFarmAccessDescriptor.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(value.farmID, farmID)
        XCTAssertEqual(value.ownerAccountID, ownerAccountID)
        XCTAssertEqual(value.memberAccountID, memberAccountID)
        XCTAssertEqual(value.memberRole, .worker)
        XCTAssertEqual(value.currentRevision, 492)
        XCTAssertTrue(value.serverMembershipID.contains(
            memberUserID.uuidString.lowercased()
        ))
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
    }

    func testRestoreRecordPersistsEveryRecoveryBoundary() throws {
        let accountID = UUID()
        let ownerAccountID = UUID()
        let farmID = UUID()
        let record = FarmRemoteRestoreRecord(
            accountID: accountID,
            farmID: farmID,
            authorityGeneration: 1,
            ownerAccountID: ownerAccountID,
            memberRole: .worker,
            serverMembershipID: "membership-1",
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
        XCTAssertEqual(record.ownerAccountID, ownerAccountID)
        XCTAssertEqual(record.memberRole, .worker)
        XCTAssertEqual(record.serverMembershipID, "membership-1")
        XCTAssertEqual(record.farmID, farmID)
        XCTAssertEqual(record.authorityGeneration, 1)
        XCTAssertEqual(record.targetCursorRevision, 42)
    }

    func testSupabaseMemberFarmVisibilityRequiresEveryVerifiedBoundary() {
        XCTAssertTrue(SupabaseFarmAccessIsolationPolicy.isVisible(
            bindingState: .active,
            membershipStatus: .active,
            restoreState: .completed
        ))
        XCTAssertFalse(SupabaseFarmAccessIsolationPolicy.isVisible(
            bindingState: .active,
            membershipStatus: .active,
            restoreState: .downloadingAssets
        ))
        XCTAssertFalse(SupabaseFarmAccessIsolationPolicy.isVisible(
            bindingState: .accessRevoked,
            membershipStatus: .revoked,
            restoreState: .completed
        ))
        XCTAssertFalse(SupabaseFarmAccessIsolationPolicy.isVisible(
            bindingState: .active,
            membershipStatus: nil,
            restoreState: nil
        ))
    }

    func testMembershipRevocationQuarantinesOnlyNonterminalOutbox() {
        XCTAssertTrue(SupabaseFarmAccessIsolationPolicy.shouldQuarantine(.pending))
        XCTAssertTrue(SupabaseFarmAccessIsolationPolicy.shouldQuarantine(.uploading))
        XCTAssertTrue(SupabaseFarmAccessIsolationPolicy.shouldQuarantine(.blockedConflict))
        XCTAssertFalse(SupabaseFarmAccessIsolationPolicy.shouldQuarantine(.confirmed))
        XCTAssertFalse(SupabaseFarmAccessIsolationPolicy.shouldQuarantine(
            .quarantinedMembershipRevoked
        ))
        XCTAssertFalse(SupabaseFarmAccessIsolationPolicy.shouldQuarantine(
            .supersededRemoteAuthority
        ))
        XCTAssertTrue(
            OutboxStatus.quarantinedMembershipRevoked.isTerminalDelivery
        )
        XCTAssertTrue(OutboxStatus.supersededRemoteAuthority.isTerminalDelivery)
        XCTAssertFalse(OutboxStatus.blockedConflict.isTerminalDelivery)
    }

    func testMemberAccessActivationPreservesNewerAuthoritativeCache() async throws {
        let container = try AppSchema.makeContainer(
            name: "MemberAccessActivationTests",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerAccountID = UUID()
        let memberAccountID = UUID()
        let operationID = UUID()
        let entityID = UUID()
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: ownerAccountID,
            name: "星露谷",
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
            state: .active,
            authorityGeneration: 1
        )
        binding.lastPulledRevision = 492
        context.insert(binding)
        context.insert(FarmMembershipBinding(
            serverMembershipID: "owner-membership",
            farmID: farmID,
            accountID: ownerAccountID,
            role: .owner,
            status: .active
        ))
        context.insert(DomainOperation(
            id: operationID,
            farmID: farmID,
            accountID: ownerAccountID,
            kind: .addNote,
            summary: "较新增量"
        ))
        context.insert(TombstoneRecord(
            farmID: farmID,
            entityType: CloudEntityType.note.rawValue,
            entityID: entityID,
            deletedByAccountID: ownerAccountID,
            reason: "测试删除",
            revision: 27,
            operationID: operationID
        ))
        try context.save()

        try await FarmCompactBaselineRebuildService()
            .finalizeExistingAuthoritativeCacheAccess(
                farmID: farmID,
                ownerAccountID: ownerAccountID,
                currentAccountID: memberAccountID,
                memberRole: .worker,
                serverMembershipID: "member-membership",
                authorityGeneration: 1,
                checkpointCursor: 0,
                container: container
            )

        let verified = ModelContext(container)
        let verifiedFarm = try XCTUnwrap(
            verified.fetch(FetchDescriptor<FarmRecord>()).first
        )
        let verifiedBinding = try XCTUnwrap(
            verified.fetch(FetchDescriptor<FarmRemoteBinding>()).first
        )
        XCTAssertEqual(verifiedFarm.ownerAccountID, ownerAccountID)
        XCTAssertEqual(verifiedFarm.role, .worker)
        XCTAssertEqual(verifiedBinding.lastPulledRevision, 492)
        XCTAssertEqual(
            try verified.fetchCount(FetchDescriptor<DomainOperation>()),
            1
        )
        XCTAssertEqual(
            try verified.fetchCount(FetchDescriptor<TombstoneRecord>()),
            1
        )
        let member = try XCTUnwrap(
            verified.fetch(FetchDescriptor<FarmMembershipBinding>())
                .first(where: { $0.accountID == memberAccountID })
        )
        XCTAssertEqual(member.role, .worker)
        XCTAssertEqual(member.status, .active)
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
