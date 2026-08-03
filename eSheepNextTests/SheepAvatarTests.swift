import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class SheepAvatarTests: XCTestCase {
    func testLocalAvatarSelectionUsesProfileCommandAndFallsBackForDeletedPhoto() throws {
        let fixture = try makeFixture()
        let sheep = SheepRecord(
            farmID: fixture.farm.id,
            earTag: "A001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let otherSheep = SheepRecord(
            farmID: fixture.farm.id,
            earTag: "A002",
            breed: "湖羊",
            sex: .ram,
            penID: nil,
            enteredAt: .now
        )
        let photo = PhotoAssetRecord(
            farmID: fixture.farm.id,
            sheepID: sheep.id,
            legacySourceKey: "test:avatar",
            originalEarTag: sheep.earTag,
            relativePath: "Assets/avatar.jpg",
            sha256: "avatar-digest"
        )
        let otherPhoto = PhotoAssetRecord(
            farmID: fixture.farm.id,
            sheepID: otherSheep.id,
            legacySourceKey: "test:other-avatar",
            originalEarTag: otherSheep.earTag,
            relativePath: "Assets/other-avatar.jpg",
            sha256: "other-avatar-digest"
        )
        [sheep, otherSheep].forEach(fixture.context.insert)
        [photo, otherPhoto].forEach(fixture.context.insert)
        try fixture.context.save()

        XCTAssertThrowsError(try fixture.service.setSheepAvatar(
            sheepID: sheep.id,
            photoAssetID: otherPhoto.id,
            in: fixture.farmContext,
            context: fixture.context
        ))
        try fixture.service.setSheepAvatar(
            sheepID: sheep.id,
            photoAssetID: photo.id,
            in: fixture.farmContext,
            context: fixture.context
        )

        XCTAssertEqual(
            try SheepAvatarSelectionStore.reference(
                sheepID: sheep.id,
                farmID: fixture.farm.id,
                context: fixture.context
            ),
            SheepPhotoReference(id: photo.id, digest: photo.sha256)
        )
        let operation = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.entityID == sheep.id }
            .max(by: { $0.resultingRevision < $1.resultingRevision }))
        let payload = try JSONDecoder.cloudTest.decode(FarmCommandCloudPayload.self, from: operation.payload)
        XCTAssertEqual(payload.kind, .updateSheepProfile)
        XCTAssertEqual(SheepAvatarCloudPayload.update(from: payload)?.photoAssetID, photo.id)

        photo.deletedAt = .now
        try fixture.context.save()
        XCTAssertNil(try SheepAvatarSelectionStore.reference(
            sheepID: sheep.id,
            farmID: fixture.farm.id,
            context: fixture.context
        ))
        photo.deletedAt = nil
        try fixture.context.save()
        XCTAssertEqual(try SheepAvatarSelectionStore.reference(
            sheepID: sheep.id,
            farmID: fixture.farm.id,
            context: fixture.context
        )?.id, photo.id)

        try fixture.service.setSheepAvatar(
            sheepID: sheep.id,
            photoAssetID: nil,
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertNil(try SheepAvatarSelectionStore.reference(
            sheepID: sheep.id,
            farmID: fixture.farm.id,
            context: fixture.context
        ))
    }

    func testRemoteProfileReplaySetsAndClearsAvatarBeforePhotoDownload() throws {
        let container = try AppSchema.makeContainer(
            name: "remote-avatar-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "R001",
            breed: "萨福克",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        context.insert(sheep)
        try context.save()
        let photoID = UUID()
        let command = FarmCommand.updateSheepProfile(
            sheepID: sheep.id,
            earTag: sheep.earTag,
            breed: sheep.breed,
            sex: sheep.sex,
            birthAt: sheep.birthAt,
            note: sheep.note
        )

        let setPayload = try FarmCommandCloudPayloadEncoder.encode(
            command,
            sheepAvatarUpdate: SheepAvatarPhotoUpdate(photoAssetID: photoID)
        )
        XCTAssertEqual(
            try RemoteDomainApplyService().apply(
                envelope(
                    farmID: farmID,
                    sheepID: sheep.id,
                    revision: 2,
                    baseRevision: 1,
                    payload: setPayload
                ),
                context: context
            ),
            .applied(rebuildHistoryFrom: nil)
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<SheepAvatarRecord>()).first?.photoAssetID,
            photoID
        )

        let clearPayload = try FarmCommandCloudPayloadEncoder.encode(
            command,
            sheepAvatarUpdate: SheepAvatarPhotoUpdate(photoAssetID: nil)
        )
        XCTAssertEqual(
            try RemoteDomainApplyService().apply(
                envelope(
                    farmID: farmID,
                    sheepID: sheep.id,
                    revision: 3,
                    baseRevision: 2,
                    payload: clearPayload
                ),
                context: context
            ),
            .applied(rebuildHistoryFrom: nil)
        )
        XCTAssertNil(try context.fetch(FetchDescriptor<SheepAvatarRecord>()).first?.photoAssetID)
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(
            name: "avatar-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试账户")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "头像测试牧场")
        context.insert(account)
        context.insert(farm)
        try context.save()
        return Fixture(
            context: context,
            farm: farm,
            service: FarmCommandService(),
            farmContext: FarmContext(
                accountID: account.effectiveAccountID,
                farmID: farm.id,
                role: farm.role
            )
        )
    }

    private func envelope(
        farmID: UUID,
        sheepID: UUID,
        revision: Int,
        baseRevision: Int,
        payload: Data
    ) -> CloudOperationEnvelope {
        CloudOperationEnvelope(
            farmID: farmID,
            entityID: sheepID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: revision,
            baseRevision: baseRevision,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
    }

    private struct Fixture {
        let context: ModelContext
        let farm: FarmRecord
        let service: FarmCommandService
        let farmContext: FarmContext
    }
}

private extension JSONDecoder {
    static var cloudTest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
