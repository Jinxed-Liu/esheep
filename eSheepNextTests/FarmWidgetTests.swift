import XCTest
@testable import eSheepNext

@MainActor
final class FarmWidgetTests: XCTestCase {
    private let farmID = UUID()
    private let penID = UUID()
    private let batchID = UUID()
    private func date(_ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
    private func profile(_ kind: FarmWidgetKind = .coverage) -> FarmWidgetProfile {
        var p = FarmWidgetProfile(farmID: farmID, name: "测试圈舍", kind: kind, palette: .blue)
        p.scopeID = penID
        return p
    }
    private func sheep(_ id: UUID, pen: UUID? = nil, active: Bool = true) -> FarmAnalyticsSnapshot.Sheep {
        .init(id: id, earTag: String(id.uuidString.prefix(6)), breed: "湖羊", purpose: "育肥", sex: .ram,
              status: active ? .active : .removed, initialPenID: pen ?? penID, currentPenID: pen ?? penID,
              birthAt: nil, enteredAt: date(1), removedAt: active ? nil : date(19))
    }
    private func snapshot(sheep: [FarmAnalyticsSnapshot.Sheep], weights: [FarmAnalyticsSnapshot.Weight],
                          transfers: [FarmAnalyticsSnapshot.Transfer] = [], memberships: [FarmAnalyticsSnapshot.BatchMembership] = []) -> FarmAnalyticsSnapshot {
        .init(farmID: farmID, sheep: sheep, pens: [.init(id: penID, name: "03 舍")], weights: weights,
              weanings: [], lambings: [], removals: [], transfers: transfers, batchMemberships: memberships,
              feeds: [], timeZoneIdentifier: "Asia/Shanghai", factsReadAt: date(22))
    }
    private func weight(_ sheep: UUID, _ day: Int, _ kg: Double) -> FarmAnalyticsSnapshot.Weight {
        .init(id: UUID(), sheepID: sheep, kilograms: kg, occurredAt: date(day))
    }
    private func farm(cards: [FarmWidgetCard]? = nil) -> FarmWidgetSnapshot.Farm {
        .init(farmID: farmID, name: "牧场", activeSheepCount: 100, activePenCount: 4,
              todayFeedCount: 8, pendingOperationCount: 2, sheep: [], pens: [], cards: cards)
    }
    func testOldSnapshotDecodesWithoutNewFields() throws {
        let old = """
        {"version":1,"generatedAt":"2026-09-22T04:00:00Z","selectedFarmID":null,"farms":[{"farmID":"\(farmID)","name":"旧牧场","activeSheepCount":2,"activePenCount":1,"todayFeedCount":0,"pendingOperationCount":0,"sheep":[],"pens":[]}]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FarmWidgetSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(decoded.farms.first?.cards)
        XCTAssertEqual(decoded.farms.first?.activeSheepCount, 2)
    }
    func testRollingWeekUsesSevenLocalCalendarDates() {
        let range = profile().dateRange(now: date(22, hour: 0), timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(range.start, date(16, hour: 0))
        XCTAssertEqual(range.end, date(22, hour: 0))
    }
    func testCustomRangeIsStableAndNormalized() {
        var p = profile(); p.period = .custom; p.startDate = date(20); p.endDate = date(10)
        let range = p.dateRange(now: date(22), timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(range.start, date(10, hour: 0)); XCTAssertEqual(range.end, date(20, hour: 0))
    }
    func testSnapshotExpiresAtFarmMidnightBeforeOneHour() {
        let generated = date(21, hour: 23).addingTimeInterval(50 * 60)
        XCTAssertEqual(FarmWidgetSelection.expiry(generatedAt: generated, timeZoneIdentifier: "Asia/Shanghai"), date(22, hour: 0))
        XCTAssertEqual(FarmWidgetSelection.expiry(generatedAt: date(22), timeZoneIdentifier: "Asia/Shanghai"), date(22).addingTimeInterval(3600))
    }
    func testCoverageDeduplicatesAndExcludesOtherPensDepartedInvalidAndFutureSamples() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let source = snapshot(sheep: [sheep(a), sheep(b), sheep(c, pen: UUID()), sheep(d, active: false)],
                              weights: [weight(a, 20, 40), weight(a, 21, 41), weight(b, 20, 0), weight(b, 23, 43), weight(c, 20, 40), weight(d, 20, 40)])
        let coverage = FarmWidgetSnapshotBuilder.currentCoverage(profile: profile(), snapshot: source, now: date(22))
        XCTAssertEqual(coverage.total, 2); XCTAssertEqual(coverage.weighed, 1)
    }
    func testBatchCoverageUsesCurrentMembershipNotHistoricalMembership() {
        let a = UUID(), b = UUID()
        var p = profile(); p.scope = .batch; p.scopeID = batchID
        let source = snapshot(sheep: [sheep(a), sheep(b)], weights: [weight(a, 20, 40), weight(b, 20, 40)], memberships: [
            .init(batchID: batchID, sheepID: a, joinedAt: date(1), leftAt: nil),
            .init(batchID: batchID, sheepID: b, joinedAt: date(1), leftAt: date(22))])
        let coverage = FarmWidgetSnapshotBuilder.currentCoverage(profile: p, snapshot: source, now: date(22))
        XCTAssertEqual(coverage.total, 1); XCTAssertEqual(coverage.weighed, 1)
    }
    func testGainUsesSameEngineAndDoesNotReplaceMissingPairWithZero() {
        let a = UUID()
        let source = snapshot(sheep: [sheep(a)], weights: [weight(a, 20, 40)])
        let card = FarmWidgetSnapshotBuilder.weightCard(profile: profile(.gain), scopeName: "03 舍", snapshot: source, now: date(22))
        XCTAssertEqual(card.value, "—")
        XCTAssertTrue(card.note.contains("不足"))
    }
    func testNegativeGainRemainsVisible() {
        let a = UUID()
        let source = snapshot(sheep: [sheep(a)], weights: [weight(a, 16, 42), weight(a, 21, 40)])
        let card = FarmWidgetSnapshotBuilder.weightCard(profile: profile(.gain), scopeName: "03 舍", snapshot: source, now: date(22))
        XCTAssertEqual(card.value, "-400")
    }
    func testTransferOutAndBackCannotAttributeWholeIntervalToPen() {
        let a = UUID(), other = UUID()
        let source = snapshot(sheep: [sheep(a)], weights: [weight(a, 16, 40), weight(a, 21, 42)], transfers: [
            .init(id: UUID(), sheepID: a, fromPenID: penID, toPenID: other, occurredAt: date(18), recordedAt: date(18)),
            .init(id: UUID(), sheepID: a, fromPenID: other, toPenID: penID, occurredAt: date(20), recordedAt: date(20))])
        let card = FarmWidgetSnapshotBuilder.weightCard(profile: profile(.gain), scopeName: "03 舍", snapshot: source, now: date(22))
        XCTAssertEqual(card.value, "—")
    }
    func testMissingExplicitFarmDoesNotFallbackToFirstFarm() {
        let source = FarmWidgetSnapshot(version: 1, generatedAt: date(22), selectedFarmID: farmID, farms: [farm()])
        let selection = FarmWidgetSelection.resolve(snapshot: source, profiles: [], kind: .overview, profileID: nil, farmID: UUID())
        XCTAssertNil(selection.farm); XCTAssertTrue(selection.card.unavailable)
    }
    func testEditedProfileDoesNotReuseOldResultAndWrongKindIsRejected() {
        let p = profile()
        var card = FarmWidgetCard.waiting(kind: .coverage)
        card.profileID = p.id; card.profileRevision = UUID(); card.unavailable = false
        let source = FarmWidgetSnapshot(version: 1, generatedAt: date(22), selectedFarmID: farmID, farms: [farm(cards: [card])])
        let old = FarmWidgetSelection.resolve(snapshot: source, profiles: [p], kind: .coverage, profileID: p.id, farmID: nil)
        XCTAssertTrue(old.card.unavailable)
        let wrong = FarmWidgetSelection.resolve(snapshot: source, profiles: [p], kind: .gain, profileID: p.id, farmID: nil)
        XCTAssertTrue(wrong.card.unavailable)
    }
    func testWidgetDeepLinkPreservesFarmKindAndProfile() throws {
        let profileID = UUID()
        let url = try XCTUnwrap(URL(string: "esheep://farm/\(farmID)/widget/gain?profile=\(profileID)"))
        let target = try XCTUnwrap(FarmSystemIntegrationService.target(from: url))
        XCTAssertEqual(target.kind, .openWidget); XCTAssertEqual(target.entityID, profileID)
        XCTAssertEqual(target.farmID, farmID); XCTAssertEqual(target.query, "gain")
        XCTAssertNil(FarmSystemIntegrationService.target(from: URL(string: "esheep://farm/\(farmID)/widget/gain?profile=invalid")!))
    }
    func testFeedingCountsPlannedMealsOnceAndDoesNotTreatAmountAsCompletion() {
        var p = profile(.feeding)
        p.scopeID = penID
        func row(meal: TMRMealPeriod, actual: Decimal, planned: Bool = true) -> TMRMonitoringRow {
            .init(id: UUID(), farmID: farmID, localDay: date(22, hour: 0), planID: planned ? UUID() : nil,
                  planRevision: 1, formulaID: UUID(), formulaRevision: 1, formulaName: "配方", penID: penID,
                  penName: "03 舍", meal: meal, cutoffAt: date(22), targetKilograms: 100,
                  actualKilograms: actual, differenceKilograms: actual - 100, differencePercent: nil,
                  status: .inProgress, batchIDs: [], batchCodes: [], runIDs: [], isCompleted: false,
                  completionID: nil, monitoringEnabled: true, fingerprint: "fixture", isAcknowledged: false)
        }
        let source = TMRMonitoringSnapshot(farmID: farmID, localDay: date(22), timeZoneIdentifier: "Asia/Shanghai",
            generatedAt: date(22), monitoringConfigured: true,
            rows: [row(meal: .morning, actual: 30), row(meal: .morning, actual: 20),
                   row(meal: .evening, actual: 0), row(meal: .noon, actual: 100, planned: false)])
        let card = FarmWidgetSnapshotBuilder.feedingCard(profile: p, name: "03 舍", snapshot: source)
        XCTAssertEqual(card.value, "1")
        XCTAssertEqual(card.unit, "/ 2 顿")
        XCTAssertEqual(card.progress, 0.5)
        XCTAssertEqual(card.rows.first?.value, "50/200 kg")
    }

    func testDailySummaryDoesNotPretendToBeOneMeal() {
        let row = TMRMonitoringRow(id: UUID(), farmID: farmID, localDay: date(22), planID: UUID(),
            planRevision: 1, formulaID: UUID(), formulaRevision: 1, formulaName: "配方", penID: penID,
            penName: "03 舍", meal: .allDaySummary, cutoffAt: date(22), targetKilograms: 100,
            actualKilograms: 80, differenceKilograms: -20, differencePercent: nil, status: .low,
            batchIDs: [], batchCodes: [], runIDs: [], isCompleted: false, completionID: nil,
            monitoringEnabled: true, fingerprint: "daily", isAcknowledged: false)
        let source = TMRMonitoringSnapshot(farmID: farmID, localDay: date(22), timeZoneIdentifier: "Asia/Shanghai",
            generatedAt: date(22), monitoringConfigured: true, rows: [row])
        let card = FarmWidgetSnapshotBuilder.feedingCard(profile: profile(.feeding), name: "03 舍", snapshot: source)
        XCTAssertEqual(card.unit, "/ 1 项")
        XCTAssertTrue(card.note.contains("不代表"))
    }

}
