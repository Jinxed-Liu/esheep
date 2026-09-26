import XCTest
@testable import eSheepNext

final class BoundedSearchMatchesTests: XCTestCase {
    func testMatchesFullSortAcrossInputOrdersAndLimits() {
        let input = (0..<300).map { ($0 * 137) % 53 }
        for values in [input, input.sorted(), input.sorted(by: >)] {
            for limit in [-1, 0, 1, 8, 50, 500, Int.max] {
                var matches = BoundedSearchMatches<Int>(limit: limit, candidateCount: values.count)
                for value in values { matches.insert(value, by: <) }
                XCTAssertEqual(matches.values, Array(values.sorted().prefix(max(0, limit))))
            }
        }
    }

    func testEqualRanksRetainInputOrderAtTheLimit() {
        var matches = BoundedSearchMatches<(rank: Int, id: Int)>(limit: 3, candidateCount: 5)
        for match in [(2, 0), (1, 1), (1, 2), (0, 3), (1, 4)] {
            matches.insert(match) { $0.rank < $1.rank }
        }
        XCTAssertEqual(matches.values.map(\.id), [3, 1, 2])
    }

    func testBroadOrderedInputDoesNotCompareEveryRetainedRow() {
        let count = 20_000
        var comparisons = 0
        var matches = BoundedSearchMatches<Int>(limit: 50, candidateCount: count)
        for value in 0..<count {
            matches.insert(value) {
                comparisons += 1
                return $0 < $1
            }
        }
        XCTAssertEqual(matches.values, Array(0..<50))
        // Protect the search hot path without a flaky wall-clock threshold.
        XCTAssertLessThan(comparisons, count * 2)
    }
}
