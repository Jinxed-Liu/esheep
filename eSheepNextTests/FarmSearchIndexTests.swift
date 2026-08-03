import SwiftData
import XCTest
@testable import eSheepNext

final class FarmSearchIndexTests: XCTestCase {
    func testEmptyQueryDoesNotReturnTheWholeFarm() {
        let source = FarmSearchSource(
            sheep: [sheep("A001", breed: "湖羊", 1)],
            pens: [pen("育肥一舍", 2)]
        )

        let result = FarmSearchEngine.search(query: "   ", source: source)

        XCTAssertEqual(result, .empty)
    }

    func testSearchNormalizesAndRanksEarTagBeforeBreed() {
        let source = FarmSearchSource(
            sheep: [
                sheep("B001", breed: "A01品种", 1),
                sheep("XA01", breed: "湖羊", 2),
                sheep("A010", breed: "湖羊", 3),
                sheep("A01", breed: "湖羊", 4)
            ],
            pens: []
        )

        let result = FarmSearchEngine.search(query: " a01 ", source: source)

        XCTAssertEqual(result.sheep.map(\.earTag), ["A01", "A010", "XA01", "B001"])
    }

    func testSearchSupportsCanonicalAndWidthInsensitiveText() {
        let source = FarmSearchSource(
            sheep: [sheep("Ｅ\u{301}０１", breed: "测试", 1)],
            pens: [pen("育肥１舍", 2)]
        )

        XCTAssertEqual(
            FarmSearchEngine.search(query: "é01", source: source).sheep.map(\.earTag),
            ["Ｅ\u{301}０１"]
        )
        XCTAssertEqual(
            FarmSearchEngine.search(query: "1舍", source: source).pens.map(\.name),
            ["育肥１舍"]
        )
    }

    func testSearchCapsRenderedRowsButPreservesTotalCounts() {
        let source = FarmSearchSource(
            sheep: (1...1_000).map { sheep("A\($0)", breed: "湖羊", $0) },
            pens: (1...100).map { pen("A圈舍\($0)", 2_000 + $0) }
        )

        let result = FarmSearchEngine.search(query: "A", source: source, limit: 20)

        XCTAssertEqual(result.sheep.count, 20)
        XCTAssertEqual(result.totalSheepCount, 1_000)
        XCTAssertTrue(result.hasMoreSheep)
        XCTAssertEqual(result.pens.count, 20)
        XCTAssertEqual(result.totalPenCount, 100)
        XCTAssertTrue(result.hasMorePens)
    }

    @MainActor
    func testIndexLoadsSelectedAvatarAndLeavesUnselectedSheepOnDefault() async throws {
        let container = try AppSchema.makeContainer(
            name: "search-avatar-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let selectedSheep = SheepRecord(
            farmID: farmID,
            earTag: "A001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let defaultSheep = SheepRecord(
            farmID: farmID,
            earTag: "A002",
            breed: "湖羊",
            sex: .ram,
            penID: nil,
            enteredAt: .now
        )
        let photo = PhotoAssetRecord(
            farmID: farmID,
            sheepID: selectedSheep.id,
            legacySourceKey: "test:search-avatar",
            originalEarTag: selectedSheep.earTag,
            relativePath: "Assets/search-avatar.jpg",
            sha256: "search-avatar-digest"
        )
        context.insert(selectedSheep)
        context.insert(defaultSheep)
        context.insert(photo)
        context.insert(SheepAvatarRecord(
            farmID: farmID,
            sheepID: selectedSheep.id,
            photoAssetID: photo.id
        ))
        try context.save()

        let source = try await FarmSearchIndexActor(container: container).load(farmID: farmID)
        let selectedEntry = try XCTUnwrap(source.sheep.first { $0.id == selectedSheep.id })
        let defaultEntry = try XCTUnwrap(source.sheep.first { $0.id == defaultSheep.id })

        XCTAssertEqual(
            selectedEntry.avatarPhoto,
            SheepPhotoReference(id: photo.id, digest: photo.sha256)
        )
        XCTAssertNil(defaultEntry.avatarPhoto)
    }

    private func sheep(
        _ earTag: String,
        breed: String,
        _ suffix: Int
    ) -> FarmSearchSheepEntry {
        FarmSearchSheepEntry(
            id: uuid(suffix),
            earTag: earTag,
            breed: breed,
            statusName: "在场",
            penName: nil
        )
    }

    private func pen(_ name: String, _ suffix: Int) -> FarmSearchPenEntry {
        FarmSearchPenEntry(id: uuid(suffix), name: name)
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
