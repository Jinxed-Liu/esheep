import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FarmRemoteRestoreAndStorageTests: XCTestCase {
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
