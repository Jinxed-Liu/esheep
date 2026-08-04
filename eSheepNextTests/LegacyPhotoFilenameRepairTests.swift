import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class LegacyPhotoFilenameRepairTests: XCTestCase {
    func testRepairReassignsPhotoAndTombstonesSyntheticFilenameSheep() throws {
        let container = try AppSchema.makeContainer(
            name: "legacy-photo-repair-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(
            appleUserIdentifier: UUID().uuidString,
            displayName: "测试场主"
        )
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "照片修复场")
        let target = SheepRecord(
            farmID: farm.id,
            earTag: "S005",
            legacyEarTag: "S005",
            legacySourceKey: "herd.sheep[0]",
            breed: "萨福克",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let ghost = SheepRecord(
            farmID: farm.id,
            earTag: "S005.jpg",
            legacyEarTag: "S005.jpg",
            legacySourceKey: "history.archive.S005.JPG",
            isHistoricalArchive: true,
            breed: "未知",
            purpose: "历史归档",
            sex: .unknown,
            penID: nil,
            enteredAt: .distantPast,
            note: "由照片历史记录自动补建"
        )
        ghost.statusRawValue = SheepStatus.removed.rawValue
        let digest = String(repeating: "a", count: 64)
        let photo = PhotoAssetRecord(
            farmID: farm.id,
            sheepID: ghost.id,
            legacySourceKey: "media.photoData[0]",
            originalEarTag: "S005.jpg",
            relativePath: "MigrationAssets/s005.jpg",
            sha256: digest
        )
        context.insert(account)
        context.insert(farm)
        context.insert(target)
        context.insert(ghost)
        context.insert(photo)
        context.insert(FarmStorageProfile(farmID: farm.id, mode: .supabase))
        context.insert(FarmRemoteBinding(
            farmID: farm.id,
            ownerAccountID: account.effectiveAccountID,
            provider: .supabase,
            state: .active,
            remoteFarmID: farm.id.uuidString.lowercased()
        ))
        try context.save()

        let report = try FarmCommandService().repairLegacyPhotoFilenameSheep(
            in: FarmContext(
                accountID: account.effectiveAccountID,
                farmID: farm.id,
                role: .owner
            ),
            context: context
        )

        XCTAssertEqual(report, LegacyPhotoFilenameRepairReport(
            repairedSheepCount: 1,
            reassignedPhotoCount: 1,
            skippedCandidateCount: 0
        ))
        XCTAssertEqual(photo.sheepID, target.id)
        XCTAssertEqual(photo.originalEarTag, "S005")
        XCTAssertNotNil(ghost.deletedAt)
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        XCTAssertEqual(operations.count, 2)
        let photoOperation = try XCTUnwrap(operations.first { $0.kindRawValue == DomainOperationKind.addPhoto.rawValue })
        XCTAssertEqual(photoOperation.entityID, photo.id)
        XCTAssertEqual(photoOperation.baseRevision, 1)
        XCTAssertEqual(photoOperation.resultingRevision, 2)
        let payload = try JSONDecoder().decode(
            FarmCommandCloudPayload.self,
            from: photoOperation.payload
        )
        XCTAssertEqual(payload.optionalIdentifiers["sheepID"] ?? nil, target.id)
        XCTAssertEqual(payload.strings["originalEarTag"], "S005")
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).count, 2)
    }

    func testRemotePhotoProjectionRefreshUpdatesExistingAssociation() throws {
        let container = try AppSchema.makeContainer(
            name: "remote-photo-repair-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let target = SheepRecord(
            farmID: farmID,
            earTag: "S005",
            breed: "萨福克",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let ghost = SheepRecord(
            farmID: farmID,
            earTag: "S005.jpg",
            breed: "未知",
            sex: .unknown,
            penID: nil,
            enteredAt: .distantPast
        )
        let digest = String(repeating: "b", count: 64)
        let photo = PhotoAssetRecord(
            farmID: farmID,
            sheepID: ghost.id,
            legacySourceKey: "cloud:test",
            originalEarTag: "S005.jpg",
            relativePath: "",
            sha256: digest
        )
        context.insert(target)
        context.insert(ghost)
        context.insert(photo)
        try context.save()
        var payload = FarmCommandCloudPayload(kind: .addPhoto)
        payload.strings = [
            "sha256": digest,
            "sourceSHA256": digest,
            "mimeType": "image/jpeg",
            "originalEarTag": "S005"
        ]
        payload.optionalIdentifiers = ["sheepID": target.id]
        let payloadData = try JSONEncoder.cloud.encode(payload)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: photo.id,
            entityType: CloudEntityType.photoAsset.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payloadData,
            payloadDigest: CloudPayloadDigest.hex(for: payloadData),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        XCTAssertEqual(
            try RemoteDomainApplyService().apply(envelope, context: context),
            .applied(rebuildHistoryFrom: nil)
        )
        XCTAssertEqual(photo.sheepID, target.id)
        XCTAssertEqual(photo.originalEarTag, "S005")
    }
}
