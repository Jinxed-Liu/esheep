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
