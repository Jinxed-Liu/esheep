import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class RetiredCloudFarmRemovalServiceTests: XCTestCase {
    func testStartupCleanupDeletesRetiredFarmAndPreservesSupabaseFarm() throws {
        let container = try AppSchema.makeContainer(
            name: "RetiredCloudFarmRemoval-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let retiredFarmID = UUID()
        let supabaseFarmID = UUID()

        context.insert(AccountProfile(
            id: accountID,
            appleUserIdentifier: "retired-cloud-cleanup",
            displayName: "旧云清理测试"
        ))

        context.insert(FarmRecord(
            id: retiredFarmID,
            ownerAccountID: accountID,
            name: "应删除旧云牧场"
        ))
        context.insert(PenRecord(farmID: retiredFarmID, name: "应删除圈舍"))
        context.insert(FarmStorageProfile(farmID: retiredFarmID, mode: .retiredAppleCloud))
        context.insert(FarmRemoteBinding(
            farmID: retiredFarmID,
            ownerAccountID: accountID,
            provider: .retiredAppleCloud,
            state: .active
        ))
        context.insert(CloudFarmBinding(
            farmID: retiredFarmID,
            ownerAccountID: accountID,
            state: .active
        ))

        context.insert(FarmRecord(
            id: supabaseFarmID,
            ownerAccountID: accountID,
            name: "应保留 eSheep 云牧场"
        ))
        context.insert(PenRecord(farmID: supabaseFarmID, name: "应保留圈舍"))
        context.insert(FarmStorageProfile(farmID: supabaseFarmID, mode: .retiredAppleCloud))
        context.insert(FarmRemoteBinding(
            farmID: supabaseFarmID,
            ownerAccountID: accountID,
            provider: .supabase,
            state: .active,
            authorityGeneration: 2,
            remoteFarmID: supabaseFarmID.uuidString.lowercased()
        ))
        context.insert(CloudFarmBinding(
            farmID: supabaseFarmID,
            ownerAccountID: accountID,
            state: .active
        ))
        context.insert(CloudZoneState(databaseScope: .privateDatabase))
        try context.save()

        let supportDirectory = FileManager.default.temporaryDirectory
            .appending(path: "RetiredCloudFarmRemovalAssets-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let retiredAsset = try makeAsset(
            farmID: retiredFarmID,
            applicationSupportDirectory: supportDirectory
        )
        let supabaseAsset = try makeAsset(
            farmID: supabaseFarmID,
            applicationSupportDirectory: supportDirectory
        )

        let report = try RetiredCloudFarmRemovalService.removeRetiredCloudFarms(
            from: container,
            applicationSupportDirectory: supportDirectory
        )

        XCTAssertEqual(report.removedFarmIDs, [retiredFarmID])
        XCTAssertGreaterThan(report.removedRecordCount, 0)
        XCTAssertEqual(report.pendingFileCleanupCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retiredAsset.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: supabaseAsset.path))

        let verified = ModelContext(container)
        let farms = try verified.fetch(FetchDescriptor<FarmRecord>())
        XCTAssertFalse(farms.contains { $0.id == retiredFarmID })
        XCTAssertTrue(farms.contains { $0.id == supabaseFarmID })

        let pens = try verified.fetch(FetchDescriptor<PenRecord>())
        XCTAssertFalse(pens.contains { $0.farmID == retiredFarmID })
        XCTAssertTrue(pens.contains { $0.farmID == supabaseFarmID })

        let profiles = try verified.fetch(FetchDescriptor<FarmStorageProfile>())
        XCTAssertFalse(profiles.contains { $0.farmID == retiredFarmID })
        XCTAssertEqual(profiles.first { $0.farmID == supabaseFarmID }?.mode, .supabase)

        let remoteBindings = try verified.fetch(FetchDescriptor<FarmRemoteBinding>())
        XCTAssertFalse(remoteBindings.contains { $0.provider == .retiredAppleCloud })
        XCTAssertTrue(remoteBindings.contains {
            $0.farmID == supabaseFarmID && $0.provider == .supabase && $0.state == .active
        })
        XCTAssertEqual(try verified.fetchCount(FetchDescriptor<CloudFarmBinding>()), 0)
        XCTAssertEqual(try verified.fetchCount(FetchDescriptor<CloudZoneState>()), 0)
    }

    func testSupabaseProfileNormalizationPersistsWithoutDeletedRows() throws {
        let container = try AppSchema.makeContainer(
            name: "RetiredCloudProfileNormalization-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        context.insert(FarmRecord(
            id: farmID,
            ownerAccountID: accountID,
            name: "已迁移 eSheep 云牧场"
        ))
        context.insert(FarmStorageProfile(farmID: farmID, mode: .retiredAppleCloud))
        context.insert(FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        ))
        try context.save()

        let supportDirectory = FileManager.default.temporaryDirectory
            .appending(path: "RetiredCloudProfileNormalizationAssets-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let report = try RetiredCloudFarmRemovalService.removeRetiredCloudFarms(
            from: container,
            applicationSupportDirectory: supportDirectory
        )

        XCTAssertTrue(report.removedFarmIDs.isEmpty)
        XCTAssertEqual(report.removedRecordCount, 0)
        let verified = ModelContext(container)
        XCTAssertEqual(
            try verified.fetch(FetchDescriptor<FarmStorageProfile>()).first?.mode,
            .supabase
        )
        XCTAssertEqual(try verified.fetchCount(FetchDescriptor<FarmRecord>()), 1)
        XCTAssertEqual(try verified.fetchCount(FetchDescriptor<FarmRemoteBinding>()), 1)
    }

    private func makeAsset(
        farmID: UUID,
        applicationSupportDirectory: URL
    ) throws -> URL {
        let directory = applicationSupportDirectory
            .appending(path: "eSheepNext/FarmAssets/\(farmID.uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let asset = directory.appending(path: "photo.jpg")
        try Data("fixture".utf8).write(to: asset, options: .atomic)
        return asset
    }
}
