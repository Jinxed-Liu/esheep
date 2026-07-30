import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class CompactBaselineOptimizationTests: XCTestCase {
    func testCompactArchiveRoundTripPreservesManifestAndFarmSnapshot() throws {
        let ownerID = UUID()
        let farmID = UUID()
        let migrationID = UUID()
        let package = FarmCompactBaselinePackageV1(
            manifest: .init(
                schema: FarmCompactBaselinePackageV1.schema,
                farmID: farmID,
                migrationID: migrationID,
                authorityGeneration: 1,
                frozenOperationSequence: 55,
                projectionCount: 0,
                activeProjectionCount: 0,
                tombstoneProjectionCount: 0,
                tombstoneHistoryCount: 0,
                historyOperationCount: 0,
                assetCount: 0,
                projectionDigest: "projection",
                historyDigest: "history",
                tombstoneDigest: "tombstone",
                assetDigest: "asset"
            ),
            farm: .init(
                id: farmID,
                ownerAccountID: ownerID,
                name: "星露谷",
                role: .owner,
                membershipStatusRawValue: "active",
                createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                updatedAt: Date(timeIntervalSince1970: 1_735_689_700),
                locationDisplayName: nil,
                latitude: nil,
                longitude: nil,
                coordinateReferenceSystem: "WGS84",
                addressSnapshot: nil,
                timeZoneIdentifier: "Asia/Shanghai",
                locationSourceRawValue: nil,
                horizontalAccuracyMeters: nil,
                locationUpdatedAt: nil
            ),
            projections: [],
            history: [],
            tombstones: [],
            assets: []
        )

        let archive = try FarmCompactBaselineArchive.encode(package)
        XCTAssertLessThan(archive.count, 4_096)
        XCTAssertEqual(
            try FarmCompactBaselineArchive.decode(archive),
            package
        )
        XCTAssertEqual(
            FarmCompactBaselineArchive.digest(archive).count,
            64
        )
    }

    func testCompactArchiveRejectsUnframedJSON() throws {
        XCTAssertThrowsError(
            try FarmCompactBaselineArchive.decode(Data("{}".utf8))
        ) { error in
            guard case .invalidHeader =
                    error as? FarmCompactBaselineArchiveError else {
                return XCTFail("应拒绝缺少 ESBC 文件头的 JSON")
            }
        }
    }

    func testMigrationBackupArchiveRoundTripReducesRepetitiveJSON() throws {
        let clear = Data(
            String(repeating: #"{"farm":"星露谷","count":3073}"#, count: 5_000)
                .utf8
        )
        let archive = try SupabaseMigrationBackupArchiveCodec.encode(clear)
        XCTAssertLessThan(archive.count, clear.count / 10)
        XCTAssertEqual(
            try SupabaseMigrationBackupArchiveCodec.decode(archive),
            clear
        )
    }

    func testCompactCheckpointRestoresFarmOffMainAndActivatesOnlyAfterValidation()
        async throws {
        let container = try AppSchema.makeContainer(
            name: "compact-discovery-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let ownerID = UUID()
        let farmID = UUID()
        let migrationID = UUID()
        let penID = UUID()
        let payload = try FarmCommandCloudPayloadEncoder.encode(
            .createPen(name: "恢复圈舍", note: "compact")
        )
        let projection = FarmCompactBaselinePackageV1.Projection(
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            revision: 1,
            payload: payload,
            payloadDigest: FarmCompactBaselineArchive.digest(payload),
            modifiedAt: Date(timeIntervalSince1970: 1_735_689_700),
            deletedAt: nil,
            replayOrder: 10
        )
        let package = FarmCompactBaselinePackageV1(
            manifest: .init(
                schema: FarmCompactBaselinePackageV1.schema,
                farmID: farmID,
                migrationID: migrationID,
                authorityGeneration: 3,
                frozenOperationSequence: 0,
                projectionCount: 1,
                activeProjectionCount: 1,
                tombstoneProjectionCount: 0,
                tombstoneHistoryCount: 0,
                historyOperationCount: 0,
                assetCount: 0,
                projectionDigest: "projection",
                historyDigest: "history",
                tombstoneDigest: "tombstone",
                assetDigest: "asset"
            ),
            farm: .init(
                id: farmID,
                ownerAccountID: ownerID,
                name: "星露谷",
                role: .owner,
                membershipStatusRawValue: "active",
                createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                updatedAt: Date(timeIntervalSince1970: 1_735_689_700),
                locationDisplayName: nil,
                latitude: nil,
                longitude: nil,
                coordinateReferenceSystem: "WGS84",
                addressSnapshot: nil,
                timeZoneIdentifier: "Asia/Shanghai",
                locationSourceRawValue: nil,
                horizontalAccuracyMeters: nil,
                locationUpdatedAt: nil
            ),
            projections: [projection],
            history: [],
            tombstones: [],
            assets: []
        )
        let archive = try FarmCompactBaselineArchive.encode(package)

        try await FarmCompactBaselineRebuildService()
            .restoreAuthoritativeCache(
                package: package,
                packageDigest: FarmCompactBaselineArchive.digest(archive),
                ownerAccountID: ownerID,
                cursor: 9,
                container: container
            )

        let context = ModelContext(container)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FarmRecord>())
                .first { $0.id == farmID }?.name,
            "星露谷"
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<PenRecord>())
                .first { $0.id == penID }?.name,
            "恢复圈舍"
        )
        let profile = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FarmStorageProfile>())
                .first { $0.farmID == farmID }
        )
        XCTAssertEqual(profile.mode, .supabase)
        XCTAssertEqual(profile.transitionState, .idle)
        XCTAssertEqual(profile.authorityGeneration, 3)
        let binding = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first { $0.farmID == farmID }
        )
        XCTAssertEqual(binding.state, .active)
        XCTAssertEqual(binding.lastPulledRevision, 9)
    }

    func testPrecommitAbortPreservesTargetOutbox() throws {
        let container = try AppSchema.makeContainer(
            name: "compact-abort-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "星露谷")
        let profile = FarmStorageProfile(
            farmID: farm.id,
            mode: .localOnly
        )
        context.insert(farm)
        context.insert(profile)
        try context.save()

        let migrationID = try FarmStorageTransitionCoordinator.begin(
            farmID: farm.id,
            targetMode: .supabase,
            context: context
        )
        let progress = FarmBaselineMigrationRecord(
            farmID: farm.id,
            migrationID: migrationID,
            frozenOperationSequence: 0,
            packageRelativePath: "SupabaseCompactCheckpoints/test.esbc",
            packageDigest: "digest",
            operationCount: 0,
            entityCount: 0,
            tombstoneCount: 0,
            assetCount: 0
        )
        let outbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: UUID(),
            deliveryProvider: .supabase,
            authorityGeneration: 1
        )
        context.insert(progress)
        context.insert(outbox)
        try context.save()

        try FarmStorageTransitionCoordinator.abortBeforeCommit(
            farmID: farm.id,
            migrationID: migrationID,
            context: context
        )

        XCTAssertEqual(profile.mode, .localOnly)
        XCTAssertEqual(profile.transitionState, .idle)
        XCTAssertNil(profile.migrationID)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FarmBaselineMigrationRecord>())
                .filter { $0.farmID == farm.id }.count,
            0
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<OutboxItem>())
                .filter { $0.id == outbox.id }.count,
            1,
            "已产生的新命令必须留给替代迁移继续发送"
        )
    }

    func testLocalOptimizationRefusesUnverifiedAuthority() async throws {
        let container = try AppSchema.makeContainer(
            name: "compact-cleanup-guard-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let migrationID = UUID()
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .localOnly
        ))
        try context.save()

        do {
            _ = try await LocalStorageOptimizationService()
                .optimizeAfterVerifiedSupabaseActivation(
                    farmID: farmID,
                    migrationID: migrationID,
                    context: context
                )
            XCTFail("未验证权威时不应执行本地清理")
        } catch {
            guard case .authorityNotVerified =
                    error as? LocalStorageOptimizationError else {
                return XCTFail("未验证权威时不应执行本地清理")
            }
        }
    }
}
