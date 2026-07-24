import XCTest
@testable import eSheepNext

final class SheepEarTagSearchTests: XCTestCase {
    func testEmptyQueryNeverReturnsTheFullCandidateList() {
        let candidates = [candidate("A001", 1), candidate("A002", 2)]

        let empty = SheepEarTagSearchMatcher.search(query: "", candidates: candidates)
        let whitespace = SheepEarTagSearchMatcher.search(query: "   ", candidates: candidates)

        XCTAssertTrue(empty.matches.isEmpty)
        XCTAssertEqual(empty.totalCount, 0)
        XCTAssertTrue(whitespace.matches.isEmpty)
        XCTAssertEqual(whitespace.totalCount, 0)
    }

    func testSearchNormalizesAndRanksExactPrefixThenContainsMatches() {
        let candidates = [
            candidate("XA01", 1),
            candidate("A010", 2),
            candidate("A01", 3),
            candidate("A02", 4)
        ]

        let result = SheepEarTagSearchMatcher.search(query: " a01 ", candidates: candidates)

        XCTAssertEqual(result.matches.map(\.earTag), ["A01", "A010", "XA01"])
    }

    func testSearchUsesCanonicalUnicodeNormalization() {
        let decomposed = "E\u{301}01"
        let result = SheepEarTagSearchMatcher.search(
            query: "é01",
            candidates: [candidate(decomposed, 1)]
        )

        XCTAssertEqual(result.matches.map(\.earTag), [decomposed])
    }

    func testSearchUsesNaturalStableEarTagOrdering() {
        let candidates = [candidate("A10", 3), candidate("A2", 2), candidate("A1", 1)]

        let result = SheepEarTagSearchMatcher.search(query: "A", candidates: candidates)

        XCTAssertEqual(result.matches.map(\.earTag), ["A1", "A2", "A10"])
    }

    func testSearchExcludesSelectedIDsAndReportsTruncation() {
        let candidates = (1...10).map { candidate("A\($0)", $0) }
        let excluded = Set([candidates[0].id])

        let result = SheepEarTagSearchMatcher.search(
            query: "A",
            candidates: candidates,
            excluding: excluded,
            limit: 8
        )

        XCTAssertEqual(result.matches.count, 8)
        XCTAssertEqual(result.totalCount, 9)
        XCTAssertTrue(result.hasMore)
        XCTAssertFalse(result.matches.contains { excluded.contains($0.id) })
    }

    private func candidate(_ earTag: String, _ suffix: Int) -> SheepEarTagSearchCandidate {
        SheepEarTagSearchCandidate(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
            earTag: earTag,
            detail: "测试"
        )
    }
}
