import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class InsightWeightGainParityTests: XCTestCase {
    func testCompleteMultiPenAnalysisMatchesAppForScreenshotDateRange() throws {
        let fixture = try Fixture()
        let pen13 = fixture.pen("大棚十三舍")
        let pen14 = fixture.pen("大棚十四舍")
        let pen15 = fixture.pen("大棚十五舍")
        let outside = fixture.pen("其他圈舍")

        let moved = fixture.sheep("CROSS-PEN", pen: outside)
        fixture.weight(moved, "10", at: "2026-08-20T10:00:00+08:00")
        fixture.weight(moved, "12", at: "2026-08-30T10:00:00+08:00")
        fixture.transfer(moved, from: outside, to: pen13, at: "2026-09-01T10:00:00+08:00")
        fixture.weight(moved, "14", at: "2026-09-30T23:30:00+08:00")
        fixture.transfer(moved, from: pen13, to: outside, at: "2026-10-01T10:00:00+08:00")

        let movedAfterLastWeighing = fixture.sheep("MOVED-AFTER-WEIGHING", pen: pen13)
        fixture.weight(movedAfterLastWeighing, "20", at: "2026-08-20T10:00:00+08:00")
        fixture.weight(movedAfterLastWeighing, "26", at: "2026-09-20T10:00:00+08:00")
        fixture.transfer(movedAfterLastWeighing, from: pen13, to: pen14, at: "2026-09-29T10:00:00+08:00")

        for (tag, startWeight, endWeight) in [("ZERO-GAIN", "20", "20"), ("NEGATIVE-GAIN", "30", "28")] {
            let sheep = fixture.sheep(tag, pen: pen14)
            fixture.weight(sheep, startWeight, at: "2026-08-20T10:00:00+08:00")
            fixture.weight(sheep, endWeight, at: "2026-09-30T10:00:00+08:00")
        }

        let now = date("2026-10-02T12:00:00+08:00")
        let native = try fixture.native(scope: .pens([pen13.id, pen14.id, pen15.id]), factsReadAt: now)
        let object = try fixture.execute(plan(penNames: [pen13.name, pen14.name, pen15.name]), now: now)
        try assertParity(object, with: native)

        XCTAssertEqual(native.calculableCount, 4)
        XCTAssertEqual(native.intervalCount, 5)
        XCTAssertEqual(native.downwardCount, 1)
        XCTAssertEqual(native.rows.first { $0.sheepID == moved.id }?.analysisEndPenID, pen13.id)
        XCTAssertEqual(native.rows.first { $0.sheepID == movedAfterLastWeighing.id }?.analysisEndPenID, pen14.id)
        XCTAssertTrue(native.intervals.contains { !$0.crossedTransfers.isEmpty })

        let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
        let overall = try XCTUnwrap(groups.first)
        let expectedEqualSheepRate = (4.0 / 41.0 + 6.0 / 31.0 - 2.0 / 41.0) / 4.0
        XCTAssertEqual(try XCTUnwrap(overall["value"] as? Double), expectedEqualSheepRate, accuracy: 0.000_001)
        let intervalAverage = native.intervals.reduce(0) { $0 + $1.gramsPerDay / 1_000 } / Double(native.intervalCount)
        XCTAssertEqual(try XCTUnwrap(overall["interval_weighted_daily_rate"] as? Double), intervalAverage, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(overall["pooled_daily_rate"] as? Double), 8.0 / 154.0, accuracy: 0.000_001)
        XCTAssertNotEqual(expectedEqualSheepRate, intervalAverage, accuracy: 0.000_001)

        let sections = try XCTUnwrap(object["analysis_sections"] as? [[String: Any]])
        let penSection = try XCTUnwrap(sections.first { $0["dimension"] as? String == "pen" })
        let penGroups = try XCTUnwrap(penSection["groups"] as? [[String: Any]])
        XCTAssertEqual(Set(penGroups.compactMap { $0["key"] as? String }), Set([pen13.name, pen14.name, pen15.name]))
        for pen in [pen13, pen14] {
            let group = try sectionGroup("pen", key: pen.name, in: sections)
            let appResult = try fixture.native(scope: .pen(pen.id), factsReadAt: now)
            XCTAssertEqual(group["sample_count"] as? Int, appResult.intervalCount)
            XCTAssertEqual(group["sheep_count"] as? Int, appResult.calculableCount)
            XCTAssertEqual(try XCTUnwrap(group["value"] as? Double), try XCTUnwrap(appResult.averageDailyGainGrams) / 1_000, accuracy: 0.000_001)
        }
        let emptyGroup = try sectionGroup("pen", key: pen15.name, in: sections)
        XCTAssertEqual(emptyGroup["sample_count"] as? Int, 0)
        XCTAssertEqual(emptyGroup["sheep_count"] as? Int, 0)
        XCTAssertTrue(emptyGroup["value"] is NSNull)
        let cutoff = try isoDate(XCTUnwrap(object["as_of"] as? String))
        XCTAssertGreaterThanOrEqual(cutoff, date("2026-09-30T23:59:59+08:00"))
        XCTAssertLessThan(cutoff, date("2026-10-01T00:00:00+08:00"))

        // A later fact-read cutoff cannot move the selected historical cohort
        // to another pen after the analysis period has already ended.
        var laterCutoffPlan = plan(penNames: [pen13.name, pen14.name, pen15.name])
        laterCutoffPlan["as_of"] = "2026-10-02T12:00:00+08:00"
        let laterCutoffObject = try fixture.execute(laterCutoffPlan, now: now)
        try assertParity(laterCutoffObject, with: native)
        XCTAssertEqual(laterCutoffObject["as_of"] as? String, object["as_of"] as? String)

        // Asking for only the overall figure still uses the same App engine.
        var focusedPlan = plan(penNames: [pen13.name, pen14.name, pen15.name])
        focusedPlan["analysis_scope"] = "focused"
        let focusedObject = try fixture.execute(focusedPlan, now: now)
        try assertParity(focusedObject, with: native)
        XCTAssertEqual(focusedObject["analysis_engine"] as? String, "WeightGainAnalyticsEngine")
    }

    func testCompleteAnalysisUsesCanonicalBirthWeaningAndLastSameDayWeight() throws {
        let fixture = try Fixture()
        let pen = fixture.pen("大棚十三舍")
        let regular = fixture.sheep("CANONICAL-REGULAR", pen: pen)
        fixture.weight(regular, "10", at: "2026-08-20T09:00:00+08:00")
        fixture.weight(regular, "12", at: "2026-08-20T18:00:00+08:00")
        fixture.weight(regular, "20", at: "2026-09-30T09:00:00+08:00")
        fixture.context.insert(WeaningRecord(
            farmID: fixture.farmID, sheepID: regular.id,
            occurredAt: date("2026-08-20T20:00:00+08:00"), weanWeightText: "100",
            birthAt: date("2026-08-20T00:00:00+08:00"), birthWeightText: "1"
        ))

        let onlyWeaning = fixture.sheep("CANONICAL-WEANING", pen: pen)
        fixture.context.insert(WeaningRecord(
            farmID: fixture.farmID, sheepID: onlyWeaning.id,
            occurredAt: date("2026-09-30T09:00:00+08:00"), weanWeightText: "15",
            birthAt: date("2026-08-20T00:00:00+08:00"), birthWeightText: "3"
        ))
        let now = date("2026-10-02T12:00:00+08:00")
        let native = try fixture.native(scope: .pen(pen.id), factsReadAt: now)
        var arguments = plan(penNames: [])
        arguments["pen_name"] = pen.name
        let object = try fixture.execute(arguments, now: now)
        try assertParity(object, with: native)

        let regularInterval = try XCTUnwrap(native.intervals.first { $0.sheepID == regular.id })
        XCTAssertEqual(regularInterval.startWeight, 12)
        XCTAssertEqual(regularInterval.startSample.source, .weighing)
        let inferredInterval = try XCTUnwrap(native.intervals.first { $0.sheepID == onlyWeaning.id })
        XCTAssertEqual(inferredInterval.startSample.source, .weaningBirth)
        XCTAssertEqual(inferredInterval.endSample.source, .weaning)
        XCTAssertEqual(object["observation_count"] as? Int, 2)
        let canonical = try XCTUnwrap(object["canonical_arguments"] as? [String: Any])
        XCTAssertEqual(canonical["sample_policy"] as? String, "canonical_timeline")
        XCTAssertEqual(canonical["pen_name"] as? String, pen.name)
    }

    func testExplicitIntradayCutoffCannotBeOverwrittenByLaterSameDayWeight() throws {
        let fixture = try Fixture()
        let pen = fixture.pen("大棚十三舍")
        let sheep = fixture.sheep("INTRADAY-CUTOFF", pen: pen)
        fixture.weight(sheep, "10", at: "2026-08-20T09:00:00+08:00")
        fixture.weight(sheep, "20", at: "2026-09-30T09:00:00+08:00")
        fixture.weight(sheep, "200", at: "2026-09-30T18:00:00+08:00")
        let cutoff = date("2026-09-30T12:00:00+08:00")
        var arguments = plan(penNames: [pen.name])
        arguments["as_of"] = "2026-09-30T12:00:00+08:00"
        arguments["date_to"] = "2026-09-30T12:00:00+08:00"
        let object = try fixture.execute(arguments, now: date("2026-10-02T12:00:00+08:00"))
        let native = try fixture.native(scope: .pen(pen.id), factsReadAt: cutoff, sampleCutoff: cutoff)
        try assertParity(object, with: native)
        XCTAssertEqual(native.rows.first?.endWeight, 20)

        arguments["date_to"] = "2026-09-30"
        let fullDayWithEarlierCutoff = try fixture.execute(arguments, now: date("2026-10-02T12:00:00+08:00"))
        try assertParity(fullDayWithEarlierCutoff, with: native)
        XCTAssertEqual(fullDayWithEarlierCutoff["as_of"] as? String, object["as_of"] as? String)
    }

    func testExplicitIntradayStartExcludesEarlierWeightWeaningAndBirthFacts() throws {
        let fixture = try Fixture()
        let pen = fixture.pen("大棚十三舍")
        let sheep = fixture.sheep("INTRADAY-START", pen: pen)
        fixture.weight(sheep, "10", at: "2026-08-20T09:00:00+08:00")
        fixture.weight(sheep, "20", at: "2026-09-30T09:00:00+08:00")
        fixture.context.insert(WeaningRecord(
            farmID: fixture.farmID, sheepID: sheep.id,
            occurredAt: date("2026-08-20T09:00:00+08:00"), weanWeightText: "8",
            birthAt: date("2026-08-20T00:00:00+08:00"), birthWeightText: "1"
        ))
        fixture.context.insert(WeaningRecord(
            farmID: fixture.farmID, sheepID: sheep.id,
            occurredAt: date("2026-09-30T09:00:00+08:00"), weanWeightText: "100",
            birthAt: date("2026-08-20T00:00:00+08:00"), birthWeightText: "3"
        ))
        var arguments = plan(penNames: [pen.name])
        arguments["date_from"] = "2026-08-20T12:00:00+08:00"
        let now = date("2026-10-02T12:00:00+08:00")
        let missingStart = try fixture.execute(arguments, now: now)
        XCTAssertEqual(missingStart["observation_count"] as? Int, 0)
        XCTAssertTrue((missingStart["groups"] as? [[String: Any]])?.isEmpty == true)

        fixture.weight(sheep, "12", at: "2026-08-20T18:00:00+08:00")
        let calculable = try fixture.execute(arguments, now: now)
        XCTAssertEqual(calculable["observation_count"] as? Int, 1)
        let groups = try XCTUnwrap(calculable["groups"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(groups.first?["value"] as? Double), 8.0 / 41.0, accuracy: 0.000_001)
    }

    func testFocusedHistoricalPenAnalysisRetainsRemovalAndDoesNotBridgeOutsideMeasurements() throws {
        let fixture = try Fixture()
        let target = fixture.pen("历史圈舍")
        let outside = fixture.pen("外圈")
        let moved = fixture.sheep("NO-FALSE-ADJACENT", pen: target)
        fixture.weight(moved, "10", at: "2026-08-20T10:00:00+08:00")
        fixture.transfer(moved, from: target, to: outside, at: "2026-08-21T10:00:00+08:00")
        fixture.weight(moved, "20", at: "2026-08-30T10:00:00+08:00")
        fixture.transfer(moved, from: outside, to: target, at: "2026-09-01T10:00:00+08:00")
        fixture.weight(moved, "30", at: "2026-09-30T10:00:00+08:00")

        let removed = fixture.sheep("HISTORICALLY-SOLD", pen: target)
        fixture.weight(removed, "10", at: "2026-08-20T10:00:00+08:00")
        fixture.weight(removed, "12", at: "2026-08-30T10:00:00+08:00")
        removed.statusRawValue = SheepStatus.removed.rawValue
        removed.currentPenID = nil
        removed.removedAt = date("2026-09-29T10:00:00+08:00")
        fixture.context.insert(RemovalRecord(
            farmID: fixture.farmID, sheepID: removed.id, kind: .sold,
            reason: "出售", occurredAt: try XCTUnwrap(removed.removedAt)
        ))
        let archive = fixture.sheep("HISTORICAL-ARCHIVE", pen: target)
        archive.isHistoricalArchive = true
        fixture.weight(archive, "10", at: "2026-08-20T10:00:00+08:00")
        fixture.weight(archive, "500", at: "2026-09-30T10:00:00+08:00")

        var arguments = plan(penNames: [])
        arguments["sample_policy"] = "recorded_only"
        arguments["pen_name"] = target.name
        arguments["pen_membership"] = "at_measurement"
        arguments["analysis_scope"] = "focused"
        let now = date("2026-10-02T12:00:00+08:00")
        let object = try fixture.execute(arguments, now: now)
        let native = try fixture.native(scope: .pen(target.id), factsReadAt: now, population: .inPen)
        try assertParity(object, with: native)
        XCTAssertEqual(object["observation_count"] as? Int, 1)
        XCTAssertEqual(object["excluded_non_continuous_pen_intervals"] as? Int, 2)
        XCTAssertEqual(native.rows.map(\.sheepID), [removed.id])

        arguments["cohort"] = "current_in_herd"
        arguments["pen_membership"] = "at_cutoff"
        arguments["ear_tag"] = removed.earTag
        let currentObject = try fixture.execute(arguments, now: now)
        XCTAssertEqual(currentObject["eligible_profile_count"] as? Int, 0)
        XCTAssertEqual(currentObject["observation_count"] as? Int, 0)
    }

    func testInterruptedMembershipInSameBatchIsReportedAsCrossBatch() throws {
        let fixture = try Fixture()
        let pen = fixture.pen("大棚十三舍")
        let sheep = fixture.sheep("BATCH-EXIT-REENTRY", pen: pen)
        fixture.weight(sheep, "10", at: "2026-08-20T10:00:00+08:00")
        fixture.weight(sheep, "14", at: "2026-09-30T10:00:00+08:00")
        let batch = ProductionBatchRecord(
            farmID: fixture.farmID, name: "育肥一批", purpose: "育肥",
            startedAt: date("2026-08-01T00:00:00+08:00")
        )
        fixture.context.insert(batch)
        let first = BatchMembershipRecord(
            farmID: fixture.farmID, batchID: batch.id, sheepID: sheep.id,
            joinedAt: date("2026-08-01T00:00:00+08:00")
        )
        first.leftAt = date("2026-09-01T00:00:00+08:00")
        fixture.context.insert(first)
        fixture.context.insert(BatchMembershipRecord(
            farmID: fixture.farmID, batchID: batch.id, sheepID: sheep.id,
            joinedAt: date("2026-09-20T00:00:00+08:00")
        ))
        let now = date("2026-10-02T12:00:00+08:00")
        let object = try fixture.execute(plan(penNames: [pen.name]), now: now)
        let native = try fixture.native(scope: .pen(pen.id), factsReadAt: now)
        try assertParity(object, with: native)
        let sections = try XCTUnwrap(object["analysis_sections"] as? [[String: Any]])
        let crossBatch = try sectionGroup("production_batch", key: "跨生产批次区间", in: sections)
        XCTAssertEqual(crossBatch["sample_count"] as? Int, 1)
        let batchSection = try XCTUnwrap(sections.first { $0["dimension"] as? String == "production_batch" })
        let groups = try XCTUnwrap(batchSection["groups"] as? [[String: Any]])
        XCTAssertFalse(groups.contains { $0["key"] as? String == batch.name })
        let batchOnly = try fixture.native(scope: .batch(batch.id), factsReadAt: now)
        XCTAssertEqual(batchOnly.intervalCount, 0, "退出和重新加入之间不能拼出连续批次区间")
    }

    func testLargeCompleteAnalysisBoundsEvidenceWhilePreservingAllSheepStatistics() throws {
        let fixture = try Fixture()
        let pens = [fixture.pen("大棚十三舍"), fixture.pen("大棚十四舍")]
        let enteredAt = date("2026-08-01T00:00:00+08:00")
        let firstRound = date("2026-08-20T10:00:00+08:00")
        let lastRound = date("2026-09-10T10:00:00+08:00")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let formatter = ISO8601DateFormatter()

        for index in 0..<100 {
            let sheep = fixture.sheep("2026-AUTUMN-\(index + 1)", pen: pens[index % pens.count])
            let start = try XCTUnwrap(calendar.date(byAdding: .day, value: index % 20, to: firstRound))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: index / 20, to: lastRound))
            fixture.weight(sheep, "20", at: formatter.string(from: start))
            fixture.weight(sheep, String(20 + index % 5 - 2), at: formatter.string(from: end))
            let batch = ProductionBatchRecord(
                farmID: fixture.farmID,
                name: "2026年秋季湖羊羔羊育肥第\(index + 1)批·自繁自养标准饲喂跟踪组",
                purpose: "育肥", startedAt: enteredAt
            )
            fixture.context.insert(batch)
            fixture.context.insert(BatchMembershipRecord(
                farmID: fixture.farmID, batchID: batch.id, sheepID: sheep.id, joinedAt: enteredAt
            ))
        }

        let now = date("2026-10-02T12:00:00+08:00")
        let native = try fixture.native(scope: .pens(Set(pens.map(\.id))), factsReadAt: now)
        let object = try fixture.execute(plan(penNames: pens.map(\.name)), now: now)
        try assertParity(object, with: native)
        XCTAssertEqual(object["observation_count"] as? Int, 100)
        XCTAssertEqual(object["analyzed_profile_count"] as? Int, 100)
        XCTAssertEqual(object["is_complete"] as? Bool, false)
        let overall = try XCTUnwrap((object["groups"] as? [[String: Any]])?.first)
        XCTAssertEqual(overall["sample_count"] as? Int, 100)
        XCTAssertEqual(overall["sheep_count"] as? Int, 100)
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(encoded.count, 64 * 1_024)

        let sections = try XCTUnwrap(object["analysis_sections"] as? [[String: Any]])
        XCTAssertTrue(sections.contains { $0["is_complete"] as? Bool == false })
        for dimension in ["weighing_interval", "production_batch"] {
            let section = try XCTUnwrap(sections.first { $0["dimension"] as? String == dimension })
            XCTAssertEqual(section["group_count"] as? Int, 100)
        }
    }

    private func plan(penNames: [String]) -> [String: Any] {
        [
            "source": "weight_samples", "sample_policy": "canonical_timeline",
            "cohort": "all_profiles", "pen_membership": "at_cutoff",
            "pen_name": "", "pen_names": penNames, "ear_tag": "", "breed": "", "sex": "",
            "date_from": "2026-08-20", "date_to": "2026-09-30", "as_of": "",
            "partition_by": "sheep", "window": "adjacent", "transform": "difference_per_day",
            "analysis_scope": "complete", "group_by": "none", "reduce": "average",
            "selection": "all", "limit": 100,
        ]
    }

    private func assertParity(
        _ object: [String: Any], with result: WeightGainAnalysisResult,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(object["observation_count"] as? Int, result.intervalCount, file: file, line: line)
        XCTAssertEqual(object["analyzed_profile_count"] as? Int, result.calculableCount, file: file, line: line)
        let groups = try XCTUnwrap(object["groups"] as? [[String: Any]], file: file, line: line)
        let overall = try XCTUnwrap(groups.first, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(overall["value"] as? Double), try XCTUnwrap(result.averageDailyGainGrams) / 1_000, accuracy: 0.000_001, file: file, line: line)
    }

    private func sectionGroup(_ dimension: String, key: String, in sections: [[String: Any]]) throws -> [String: Any] {
        let section = try XCTUnwrap(sections.first { $0["dimension"] as? String == dimension })
        let groups = try XCTUnwrap(section["groups"] as? [[String: Any]])
        return try XCTUnwrap(groups.first { $0["key"] as? String == key })
    }

    private func date(_ text: String) -> Date { Self.parseDate(text) }

    private static func parseDate(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func isoDate(_ text: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text))
    }

    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let context: ModelContext
        let farmID = UUID()

        init() throws {
            container = try AppSchema.makeContainer(name: "insight-weight-parity-\(UUID().uuidString)", isStoredInMemoryOnly: true)
            context = ModelContext(container)
            let farm = FarmRecord(id: farmID, ownerAccountID: UUID(), name: "称重规则一致性测试")
            farm.timeZoneIdentifier = "Asia/Shanghai"
            context.insert(farm)
        }

        func pen(_ name: String) -> PenRecord {
            let record = PenRecord(farmID: farmID, name: name)
            context.insert(record)
            return record
        }

        func sheep(_ tag: String, pen: PenRecord) -> SheepRecord {
            let record = SheepRecord(farmID: farmID, earTag: tag, breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: InsightWeightGainParityTests.parseDate("2026-08-01T00:00:00+08:00"))
            context.insert(record)
            return record
        }

        func weight(_ sheep: SheepRecord, _ kilograms: String, at text: String) {
            context.insert(WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: kilograms, occurredAt: InsightWeightGainParityTests.parseDate(text)))
        }

        func transfer(_ sheep: SheepRecord, from: PenRecord, to: PenRecord, at text: String) {
            let record = TransferRecord(farmID: farmID, sheepID: sheep.id, fromPenID: from.id, toPenID: to.id, occurredAt: InsightWeightGainParityTests.parseDate(text))
            record.recordedAt = record.occurredAt
            context.insert(record)
            sheep.currentPenID = to.id
        }

        func execute(_ arguments: [String: Any], now: Date) throws -> [String: Any] {
            try context.save()
            let output = try InsightFarmCalculationEngine().execute(arguments: arguments, farmID: farmID, context: context, now: now)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        }

        func native(
            scope: WeightGainAnalysisScope, factsReadAt: Date,
            sampleCutoff: Date? = nil, population: WeightGainAnalysisPopulation = .wholeObject
        ) throws -> WeightGainAnalysisResult {
            try context.save()
            let weights = try context.fetch(FetchDescriptor<WeightRecord>()).filter { record in
                sampleCutoff.map { record.occurredAt <= $0 } ?? true
            }
            let snapshot = FarmAnalyticsSnapshot.make(
                farmID: farmID,
                sheep: try context.fetch(FetchDescriptor<SheepRecord>()),
                pens: try context.fetch(FetchDescriptor<PenRecord>()), weights: weights,
                weanings: try context.fetch(FetchDescriptor<WeaningRecord>()),
                reproduction: try context.fetch(FetchDescriptor<ReproductionRecord>()),
                offspring: try context.fetch(FetchDescriptor<LambingOffspringRecord>()),
                removals: try context.fetch(FetchDescriptor<RemovalRecord>()),
                transfers: try context.fetch(FetchDescriptor<TransferRecord>()),
                memberships: try context.fetch(FetchDescriptor<BatchMembershipRecord>()),
                feeds: [], feedLines: [], timeZoneIdentifier: "Asia/Shanghai", factsReadAt: factsReadAt
            )
            return WeightGainAnalyticsEngine.calculate(snapshot: snapshot, filter: .init(
                scope: scope, startDate: InsightWeightGainParityTests.parseDate("2026-08-20T00:00:00+08:00"),
                endDate: InsightWeightGainParityTests.parseDate("2026-09-30T00:00:00+08:00"), population: population
            ))
        }
    }
}
