import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class ReproductionManagementAnalyticsTests: XCTestCase {
    private let farmID = UUID()
    private let penID = UUID()
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00+08:00")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))! }
    private func ewe(_ tag: String = "E1", birth: Date? = nil) -> SheepRecord {
        SheepRecord(farmID: farmID, earTag: tag, breed: "测试品种", purpose: "繁殖母羊", sex: .ewe,
            penID: penID, enteredAt: date("2021-01-01T00:00:00+08:00"), birthAt: birth ?? date("2020-01-01T00:00:00+08:00"))
    }
    private func fact(_ sheep: SheepRecord, _ kind: ReproductionRecordKind, at: Date, result: String = "", parity: Int? = nil) -> ReproductionRecord {
        ReproductionRecord(farmID: farmID, eweID: sheep.id, kind: kind, occurredAt: at, result: result,
            lambCount: kind == .lambing ? 1 : 0, parity: parity)
    }
    private func settings(confirmed: [UUID] = []) -> ReproductionManagementSettings {
        var value = ReproductionManagementSettings()
        value.scopeConfigured = true
        value.selectedPenIDs = [penID]
        value.youthBreedingConfirmedSheepIDs = confirmed
        value.setUsage(.breeding, for: penID)
        return value
    }
    private func snapshot(_ sheep: [SheepRecord], facts: [ReproductionRecord], settings: ReproductionManagementSettings? = nil,
                          pens: [PenRecord]? = nil, careRule: ReproductionCareRuleSnapshot? = nil, at: Date? = nil) -> FarmAnalyticsSnapshot {
        FarmAnalyticsSnapshot.make(farmID: farmID, sheep: sheep,
            pens: pens ?? [PenRecord(id: penID, farmID: farmID, name: "繁殖一舍")], weights: [], weanings: [],
            reproduction: facts, offspring: [], removals: [], transfers: [], memberships: [], feeds: [], feedLines: [],
            timeZoneIdentifier: "Asia/Shanghai", factsReadAt: at ?? now,
            reproductionSettings: settings ?? self.settings(), reproductionCareRule: careRule)
    }

    func testEightPostpartumBandsCoverExactBoundariesAndCollapseAllDaysAfter210() throws {
        let cases: [(Int, ReproductionPostpartumBand)] = [
            (0, .days0To30), (29, .days0To30), (30, .days0To30), (31, .days31To60),
            (60, .days31To60), (61, .days61To90), (90, .days61To90), (91, .days91To120),
            (120, .days91To120), (121, .days121To150), (150, .days121To150),
            (151, .days151To180), (180, .days151To180), (181, .days181To210),
            (209, .days181To210), (210, .days181To210), (211, .over210), (240, .over210), (900, .over210),
        ]
        let sheep = cases.map { ewe("D\($0.0)") }
        let facts = zip(sheep, cases).map { fact($0.0, .lambing, at: daysAgo($0.1.0), parity: 1) }
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot(sheep, facts: facts))
        XCTAssertEqual(result.stages().count, 8)
        XCTAssertEqual(result.ewes.count, cases.count)
        for (days, band) in cases {
            let row = try XCTUnwrap(result.ewes.first { $0.earTag == "D\(days)" })
            XCTAssertEqual(row.postpartumDays, days)
            XCTAssertEqual(row.stageID, "postpartum-\(band.rawValue)")
        }
        XCTAssertEqual(result.stages().last?.title, "产后 大于 210 天")
        XCTAssertEqual(result.stages().last?.ewes.count, 3)
        XCTAssertNil(ReproductionPostpartumBand.containing(-1))
    }

    func testYoungRequiresBothCalendarMaturityAndHumanConfirmationAndIsDistinctFromFirstParity() throws {
        let exactTen = ewe("EXACT10", birth: date("2025-12-16T00:00:00+08:00"))
        let overTen = ewe("YOUNG", birth: date("2025-12-15T00:00:00+08:00"))
        let pending = ewe("PENDING", birth: date("2025-12-15T00:00:00+08:00"))
        let first = ewe("FIRST")
        let multi = ewe("MULTI")
        let facts = [exactTen, overTen, pending].map { fact($0, .parityBaseline, at: daysAgo(200), parity: 0) }
            + [fact(first, .lambing, at: daysAgo(40), parity: 1), fact(multi, .lambing, at: daysAgo(40), parity: 2),
               fact(overTen, .pregnancyCheck, at: daysAgo(10), result: "已孕"),
               fact(pending, .pregnancyCheck, at: daysAgo(10), result: "已孕")]
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot([exactTen, overTen, pending, first, multi], facts: facts,
            settings: settings(confirmed: [exactTen.id, overTen.id])))
        let byTag = Dictionary(uniqueKeysWithValues: result.ewes.map { ($0.earTag, $0) })
        XCTAssertEqual(byTag["EXACT10"]?.category, .immature)
        XCTAssertFalse(try XCTUnwrap(byTag["EXACT10"]).isCheckEligible)
        XCTAssertEqual(byTag["YOUNG"]?.ageMonths, 10)
        XCTAssertEqual(byTag["YOUNG"]?.category, .young)
        XCTAssertTrue(try XCTUnwrap(byTag["YOUNG"]).isYoungPregnant)
        XCTAssertEqual(byTag["PENDING"]?.category, .pendingReadiness)
        XCTAssertFalse(try XCTUnwrap(byTag["PENDING"]).isYoungPregnant)
        XCTAssertEqual(byTag["FIRST"]?.category, .firstParity)
        XCTAssertEqual(byTag["MULTI"]?.category, .multiparous)
    }

    func testMissingLambingDateDoesNotTurnParousOrUnknownEweIntoYoung() throws {
        let missing = ewe("MISSING"), unknown = ewe("UNKNOWN"), noBirthday = ewe("NOBIRTHDAY")
        noBirthday.birthAt = nil
        let facts = [fact(missing, .parityBaseline, at: daysAgo(30), parity: 2),
                     fact(noBirthday, .parityBaseline, at: daysAgo(30), parity: 0)]
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot([missing, unknown, noBirthday], facts: facts,
            settings: settings(confirmed: [missing.id, unknown.id, noBirthday.id])))
        let byTag = Dictionary(uniqueKeysWithValues: result.ewes.map { ($0.earTag, $0) })
        XCTAssertEqual(byTag["MISSING"]?.category, .multiparous)
        XCTAssertNil(byTag["MISSING"]?.postpartumDays)
        XCTAssertTrue(try XCTUnwrap(byTag["MISSING"]).stageID.hasPrefix("missing-birth-"))
        XCTAssertEqual(byTag["UNKNOWN"]?.category, .uncertain)
        XCTAssertEqual(byTag["NOBIRTHDAY"]?.category, .uncertain)
        XCTAssertNil(byTag["NOBIRTHDAY"]?.ageMonths)
        XCTAssertTrue(result.ewes.allSatisfy { !$0.issues.isEmpty && !$0.isYoungPregnant })
    }

    func testPregnancyChecksRespectCycleBoundariesAndLatestRecheck() throws {
        let birth = ewe("BIRTH"), rebreed = ewe("REBREED"), abort = ewe("ABORT"), independent = ewe("INDEPENDENT"), repeatCheck = ewe("RECHECK")
        let sheep = [birth, rebreed, abort, independent, repeatCheck]
        var facts = sheep.map { fact($0, .parityBaseline, at: daysAgo(300), parity: 0) }
        facts += sheep.map { fact($0, .pregnancyCheck, at: daysAgo(200), result: "已孕") }
        facts += [fact(birth, .lambing, at: daysAgo(100), parity: 1),
                  fact(rebreed, .breeding, at: daysAgo(100)), fact(abort, .abortion, at: daysAgo(100)),
                  fact(repeatCheck, .pregnancyCheck, at: daysAgo(10), result: "复检")]
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot(sheep, facts: facts, settings: settings(confirmed: sheep.map(\.id))))
        let byTag = Dictionary(uniqueKeysWithValues: result.ewes.map { ($0.earTag, $0) })
        XCTAssertEqual(byTag["BIRTH"]?.pregnancy, .unexamined)
        XCTAssertEqual(byTag["REBREED"]?.pregnancy, .unexamined)
        XCTAssertEqual(byTag["ABORT"]?.pregnancy, .unexamined)
        XCTAssertEqual(byTag["INDEPENDENT"]?.pregnancy, .pregnant)
        XCTAssertEqual(byTag["RECHECK"]?.pregnancy, .recheck)
        XCTAssertEqual(byTag["RECHECK"]?.checkResult, "复检")
        XCTAssertNotNil(byTag["BIRTH"]?.historicalCheckAt)
        XCTAssertNil(byTag["BIRTH"]?.checkAt)
    }

    func testSimultaneousConflictsAndUnknownTextRemainUncertain() throws {
        let conflict = ewe("CONFLICT"), unknown = ewe("UNKNOWN"), simultaneous = ewe("SIMULTANEOUS")
        let facts = [conflict, unknown, simultaneous].map { fact($0, .parityBaseline, at: daysAgo(300), parity: 0) }
            + [fact(conflict, .pregnancyCheck, at: daysAgo(1), result: "已孕"),
               fact(conflict, .pregnancyCheck, at: daysAgo(1), result: "空怀"),
               fact(unknown, .pregnancyCheck, at: daysAgo(1), result: "待核实原文"),
               fact(simultaneous, .breeding, at: daysAgo(1)),
               fact(simultaneous, .pregnancyCheck, at: daysAgo(1), result: "已孕")]
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot([conflict, unknown, simultaneous], facts: facts))
        XCTAssertTrue(result.ewes.allSatisfy { $0.pregnancy == .uncertain && !$0.issues.isEmpty })
        XCTAssertEqual(result.count(.unexamined), 0)
        XCTAssertEqual(result.count(.open), 0)
        XCTAssertEqual(ReproductionPregnancyState.classify("未怀孕"), .open)
        XCTAssertEqual(ReproductionPregnancyState.classify("无法排除怀孕"), .uncertain)
    }

    func testOccupiedSelectorUsesCurrentPresenceAndRetainsSelectionsAcrossEmptyAndRefilledPens() throws {
        let active = ewe("ACTIVE"), historical = ewe("HISTORY"), removed = ewe("REMOVED")
        historical.isHistoricalArchive = true
        removed.statusRawValue = SheepStatus.removed.rawValue
        let emptyPen = PenRecord(farmID: farmID, name: "空舍")
        let inactivePen = PenRecord(farmID: farmID, name: "停用舍"); inactivePen.isActive = false
        let inactive = ewe("INACTIVE"); inactive.currentPenID = inactivePen.id
        let pens = [PenRecord(id: penID, farmID: farmID, name: "繁殖一舍"), emptyPen, inactivePen]
        let first = try ReproductionManagementEngine.calculate(snapshot: snapshot([active, historical, removed, inactive], facts: [], pens: pens))
        XCTAssertEqual(first.occupiedPens.map(\.id), [penID])
        XCTAssertEqual(first.occupiedPens.first?.sheepCount, 1)
        XCTAssertEqual(first.inactiveOccupiedPens.map(\.id), [inactivePen.id])
        active.statusRawValue = SheepStatus.removed.rawValue
        let cleared = try ReproductionManagementEngine.calculate(snapshot: snapshot([active, historical, removed], facts: [], pens: pens))
        XCTAssertTrue(cleared.occupiedPens.isEmpty)
        XCTAssertEqual(cleared.settings.selectedPenIDs, [penID])
        active.statusRawValue = SheepStatus.active.rawValue
        let refilled = try ReproductionManagementEngine.calculate(snapshot: snapshot([active], facts: [], pens: pens))
        XCTAssertEqual(refilled.effectivePenCount, 1)
    }

    func testPostpartumRulesUseConfiguredThresholdsAndDeduplicateCombinedReasons() throws {
        let sheep = [89, 90, 119, 120, 211].map { ewe("D\($0)") }
        var facts = zip(sheep, [89, 90, 119, 120, 211]).map { fact($0.0, .lambing, at: daysAgo($0.1), parity: 1) }
        facts += [fact(sheep[3], .breeding, at: daysAgo(50))]
        var rules = settings(); rules.postpartumReminderDays = 90; rules.postpartumWarningDays = 120
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot(sheep, facts: facts, settings: rules,
            careRule: .init(id: UUID(), revision: 1, pregnancyCheckDays: 45, warningLeadDays: 3, operationalRulesConfigured: true)))
        let byTag = Dictionary(uniqueKeysWithValues: result.ewes.map { ($0.earTag, $0) })
        XCTAssertNil(byTag["D89"]?.severity)
        XCTAssertEqual(byTag["D90"]?.severity, .reminder)
        XCTAssertEqual(byTag["D119"]?.severity, .reminder)
        XCTAssertEqual(byTag["D120"]?.severity, .warning)
        XCTAssertEqual(byTag["D120"]?.concerns.count, 2)
        XCTAssertEqual(result.attention.count, 4)
        XCTAssertEqual(result.operationalAlerts().count, 4)
        let alert = try XCTUnwrap(result.operationalAlerts().first { $0.subjectID == sheep[3].id })
        let deferred = FarmOperationalAlertEngine.Deferral(alertID: alert.id, conditionFingerprint: alert.conditionFingerprint,
            deferredAt: now, deferredUntil: now.addingTimeInterval(86_400))
        XCTAssertEqual(result.operationalAlerts(deferrals: [deferred]).count, 3)
        XCTAssertEqual(result.attention.count, 4, "Deferring display does not change underlying facts")
    }

    func testOver210IsNotAnAutomaticWarningAndChecksResolveMissingCheckAlerts() throws {
        let sheep = ewe()
        let birth = fact(sheep, .lambing, at: daysAgo(400), parity: 2)
        let beforeRules = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: [birth]))
        XCTAssertEqual(beforeRules.ewes.first?.stageID, "postpartum-7")
        XCTAssertTrue(beforeRules.attention.isEmpty)
        var rules = settings(); rules.postpartumReminderDays = 90; rules.postpartumWarningDays = 120
        for resultText in ["已孕", "空怀", "复检", "结果不明"] {
            let check = fact(sheep, .pregnancyCheck, at: daysAgo(10), result: resultText)
            let result = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: [birth, check], settings: rules))
            XCTAssertTrue(result.ewes[0].concerns.allSatisfy { $0.kind != .postpartum })
            XCTAssertNotEqual(result.ewes[0].pregnancy, .unexamined)
        }
    }

    func testFarmCalendarBoundaryAndFutureFacts() throws {
        let at = date("2026-10-16T00:10:00+08:00")
        let sheep = ewe()
        let facts = [fact(sheep, .lambing, at: date("2026-10-15T23:50:00+08:00"), parity: 1),
                     fact(sheep, .pregnancyCheck, at: date("2026-10-16T01:00:00+08:00"), result: "已孕")]
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: facts, at: at))
        XCTAssertEqual(result.ewes[0].postpartumDays, 1)
        XCTAssertEqual(result.ewes[0].pregnancy, .unexamined)
    }

    func testRulesMustBeExplicitAndRejectInvalidPairs() throws {
        var rules = settings()
        XCTAssertFalse(rules.hasThresholdRules)
        rules.postpartumReminderDays = 90
        XCTAssertThrowsError(try rules.validated())
        rules.postpartumWarningDays = 90
        XCTAssertThrowsError(try rules.validated())
        rules.postpartumWarningDays = 120
        rules.maidenReminderMonths = 9; rules.maidenWarningMonths = 12
        XCTAssertThrowsError(try rules.validated())
        rules.maidenReminderMonths = 10
        XCTAssertNoThrow(try rules.validated())
    }

    func testSevenDayDeferralSurvivesCalendarTickButNotWarningUpgrade() throws {
        let sheep = ewe()
        let birth = fact(sheep, .lambing, at: daysAgo(100), parity: 1)
        var rules = settings(); rules.postpartumReminderDays = 90; rules.postpartumWarningDays = 103
        let first = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: [birth], settings: rules))
        let alert = try XCTUnwrap(first.operationalAlerts().first)
        let deferred = FarmOperationalAlertEngine.Deferral(alertID: alert.id, conditionFingerprint: alert.conditionFingerprint,
            deferredAt: now, deferredUntil: calendar.date(byAdding: .day, value: 7, to: now)!)
        let tomorrow = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: [birth], settings: rules,
            at: calendar.date(byAdding: .day, value: 1, to: now)!))
        XCTAssertEqual(tomorrow.ewes[0].postpartumDays, 101)
        XCTAssertTrue(tomorrow.operationalAlerts(deferrals: [deferred]).isEmpty)
        let upgraded = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: [birth], settings: rules,
            at: calendar.date(byAdding: .day, value: 3, to: now)!))
        XCTAssertEqual(upgraded.operationalAlerts(deferrals: [deferred]).first?.kind, .reproductionWarning)
    }

    func testYoungMonthlyReminderNeedsReadinessAndUpgradesAtTwelveMonthAnniversary() throws {
        let eleven = ewe("ELEVEN", birth: calendar.date(byAdding: .month, value: -11, to: calendar.startOfDay(for: now))!)
        let twelve = ewe("TWELVE", birth: calendar.date(byAdding: .month, value: -12, to: calendar.startOfDay(for: now))!)
        let pending = ewe("PENDING", birth: calendar.date(byAdding: .month, value: -13, to: calendar.startOfDay(for: now))!)
        let sheep = [eleven, twelve, pending]
        let facts = sheep.map { fact($0, .parityBaseline, at: daysAgo(100), parity: 0) }
        var rules = settings(confirmed: [eleven.id, twelve.id]); rules.maidenReminderMonths = 10; rules.maidenWarningMonths = 12
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot(sheep, facts: facts, settings: rules))
        let byTag = Dictionary(uniqueKeysWithValues: result.ewes.map { ($0.earTag, $0) })
        XCTAssertEqual(byTag["ELEVEN"]?.severity, .reminder)
        XCTAssertEqual(byTag["TWELVE"]?.severity, .warning)
        XCTAssertEqual(byTag["PENDING"]?.severity, .review)
        XCTAssertFalse(try XCTUnwrap(byTag["PENDING"]).concerns.contains { $0.kind == .maiden })
    }

    func testActualBreedingStillRequiresCheckBeforeMinimumAge() throws {
        let sheep = ewe(birth: calendar.date(byAdding: .month, value: -8, to: calendar.startOfDay(for: now))!)
        let facts = [fact(sheep, .parityBaseline, at: daysAgo(100), parity: 0), fact(sheep, .breeding, at: daysAgo(50))]
        let result = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: facts,
            careRule: .init(id: UUID(), revision: 1, pregnancyCheckDays: 45, warningLeadDays: 3, operationalRulesConfigured: true)))
        XCTAssertEqual(result.ewes[0].category, .immature)
        XCTAssertFalse(result.ewes[0].isCheckEligible)
        XCTAssertEqual(result.ewes[0].concerns.map(\.kind), [.breeding])
    }

    func testMissingLatestLambingMakesEarlierPregnancyEvidenceUncertainUntilNewCheck() throws {
        let sheep = ewe()
        let baseline = fact(sheep, .parityBaseline, at: daysAgo(30), parity: 2)
        let oldCheck = fact(sheep, .pregnancyCheck, at: daysAgo(60), result: "已孕")
        let before = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: [baseline, oldCheck]))
        XCTAssertEqual(before.ewes[0].pregnancy, .uncertain)
        let newCheck = fact(sheep, .pregnancyCheck, at: daysAgo(10), result: "已孕")
        let after = try ReproductionManagementEngine.calculate(snapshot: snapshot([sheep], facts: [baseline, oldCheck, newCheck]))
        XCTAssertEqual(after.ewes[0].pregnancy, .pregnant)
        XCTAssertNil(after.ewes[0].postpartumDays)
        XCTAssertEqual(after.ewes[0].category, .multiparous)
    }

    func testUnreadableSettingsDoNotBecomeAnEmptySuccessfulResult() {
        var value = snapshot([], facts: [])
        value.reproductionSettingsIssue = "Unrecognised future settings"
        XCTAssertThrowsError(try ReproductionManagementEngine.calculate(snapshot: value))
    }
}
