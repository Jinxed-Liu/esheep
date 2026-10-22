import Foundation
import XCTest
@testable import eSheepNext

final class ReproductionCycleResolverTests: XCTestCase {
    struct Fixture: Decodable {
        let name: String
        let eweID: UUID
        let asOf: Double
        let records: [Record]
        let expectedState: String
        let expectedParity: Int?
        let expectedRoundID: UUID?
        let expectedCycleID: UUID
        let expectedCheckID: UUID?
        let expectedIssues: [String]?
    }
    struct Record: Decodable {
        let id: UUID
        let eweID: UUID
        let kindRawValue: String
        let occurredAt: Double
        var result: String?
        var parity: Int?
        var reproductionCycleID: UUID?
        var breedingRoundID: UUID?
        var breedingIntentRawValue: String?
        var relatedBreedingRecordID: UUID?
        var deletedAt: Double?
        var fact: FarmAnalyticsSnapshot.ReproductionFact {
            .init(id: id, eweID: eweID, kind: ReproductionRecordKind(rawValue: kindRawValue)!,
                  occurredAt: Date(timeIntervalSince1970: occurredAt / 1000), result: result ?? "",
                  relatedBreedingRecordID: relatedBreedingRecordID, parity: parity,
                  reproductionCycleID: reproductionCycleID, breedingRoundID: breedingRoundID,
                  breedingIntentRawValue: breedingIntentRawValue)
        }
    }

    func testLambReviewScopePreservesUnknownParityAndRealReproductionEvidence() throws {
        let date: (String) -> Date = { ISO8601DateFormatter().date(from: $0 + "T00:00:00+08:00")! }
        let now = date("2026-10-17"), birth = date("2026-09-11")
        func isLamb(_ purpose: String = "哺乳羔羊", birthAt: Date? = nil, removedAt: Date? = nil,
                    hasFacts: Bool = false, asOf: Date? = nil) -> Bool {
            ReproductionReviewPolicy.isPreBreedingLamb(purpose: purpose, birthAt: birthAt ?? birth,
                removedAt: removedAt, hasReproductionFacts: hasFacts, asOf: asOf ?? now,
                timeZoneIdentifier: "Asia/Shanghai")
        }
        XCTAssertTrue(isLamb())
        XCTAssertTrue(isLamb("断奶羔羊"))
        XCTAssertTrue(isLamb(removedAt: date("2026-09-14"), asOf: date("2030-10-17")), "A deceased lamb does not age into a review case")
        XCTAssertFalse(isLamb(hasFacts: true), "Own breeding or pregnancy evidence must remain reviewable")
        XCTAssertFalse(isLamb("繁殖母羊"))
        XCTAssertFalse(isLamb("后备母羊"))
        XCTAssertFalse(isLamb(birthAt: date("2025-01-01")), "A stale lamb purpose must not hide an adult")
        XCTAssertFalse(isLamb(birthAt: date("2026-11-01")))
        XCTAssertFalse(ReproductionReviewPolicy.isPreBreedingLamb(purpose: "哺乳羔羊", birthAt: nil,
            removedAt: nil, hasReproductionFacts: false, asOf: now, timeZoneIdentifier: "Asia/Shanghai"))
        XCTAssertTrue(isLamb(birthAt: date("2025-12-17")))
        XCTAssertFalse(isLamb(birthAt: date("2025-12-17"), asOf: date("2026-10-18")))
        let sourceState = ReproductionCycleResolver.resolve(eweID: UUID(), facts: [], asOf: now)
        XCTAssertNil(sourceState.completedParity, "Review scope must not fabricate parity zero")
        XCTAssertNil(sourceState.targetParity)
    }

    func testSharedAppAndWebCycleContract() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reproduction-cycle-cases", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(fixtures.count, 19)
        let names: [ReproductionPregnancyState: String] = [.pregnant: "pregnant", .open: "open", .recheck: "recheck", .unexamined: "unexamined", .uncertain: "uncertain"]
        for fixture in fixtures {
            let facts = fixture.records.filter { $0.deletedAt == nil }.map(\.fact)
            let at = Date(timeIntervalSince1970: fixture.asOf / 1000)
            for ordered in [facts, Array(facts.reversed())] {
                let state = ReproductionCycleResolver.resolve(eweID: fixture.eweID, facts: ordered, asOf: at)
                XCTAssertEqual(names[state.pregnancy], fixture.expectedState, fixture.name)
                XCTAssertEqual(state.completedParity, fixture.expectedParity, fixture.name)
                XCTAssertEqual(state.breedingRoundID, fixture.expectedRoundID, fixture.name)
                XCTAssertEqual(state.cycleID, fixture.expectedCycleID, fixture.name)
            }
        }
    }
}


extension ReproductionCycleResolverTests {
    func testAuthoritativeReadOnlyCloudAuditMatchesWebAtSameCutoffWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["ESHEEP_REPRODUCTION_AUDIT_FIXTURE"] else {
            throw XCTSkip("Provide the private, read-only authoritative cloud audit fixture")
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(fixtures.isEmpty)
        let names: [ReproductionPregnancyState: String] = [.pregnant: "pregnant", .open: "open", .recheck: "recheck", .unexamined: "unexamined", .uncertain: "uncertain"]
        let started = Date.now
        for fixture in fixtures {
            let state = ReproductionCycleResolver.resolve(eweID: fixture.eweID,
                facts: fixture.records.filter { $0.deletedAt == nil }.map(\.fact), asOf: Date(timeIntervalSince1970: fixture.asOf / 1000))
            XCTAssertEqual(names[state.pregnancy], fixture.expectedState, fixture.name)
            XCTAssertEqual(state.completedParity, fixture.expectedParity, fixture.name)
            XCTAssertEqual(state.breedingRoundID, fixture.expectedRoundID, fixture.name)
            XCTAssertEqual(state.cycleID, fixture.expectedCycleID, fixture.name)
            XCTAssertEqual(state.check?.id, fixture.expectedCheckID, fixture.name)
            XCTAssertEqual(state.issues, fixture.expectedIssues, fixture.name)
        }
        print("NATIVE_WEB_AUDIT_EWES=\(fixtures.count) SECONDS=\(Date.now.timeIntervalSince(started))")
    }
}
