import Foundation
import XCTest
@testable import eSheepNext

final class InsightRateAnalysisIntentTests: XCTestCase {
    private let penNames = [
        "大棚一舍", "大棚四舍", "大棚十二舍", "大棚十三舍", "大棚十四舍", "大棚十五舍",
    ]

    func testDefaultPlanUsesAppWeightTimelineAndEndCohort() throws {
        let intent = try XCTUnwrap(detect("大棚十二舍日增重多少"))
        XCTAssertEqual(intent.penNames, ["大棚十二舍"])
        XCTAssertEqual(intent.penName, "大棚十二舍")
        let arguments = intent.calculationArguments
        XCTAssertEqual(arguments["sample_policy"] as? String, "canonical_timeline")
        XCTAssertEqual(arguments["cohort"] as? String, "all_profiles")
        XCTAssertEqual(arguments["pen_membership"] as? String, "at_cutoff")
        XCTAssertEqual(arguments["pen_names"] as? [String], ["大棚十二舍"])
        XCTAssertEqual(arguments["date_from"] as? String, "")
        XCTAssertEqual(arguments["date_to"] as? String, "")
        XCTAssertEqual(arguments["as_of"] as? String, "")
        XCTAssertEqual(arguments["window"] as? String, "adjacent")
        XCTAssertEqual(arguments["transform"] as? String, "difference_per_day")
        XCTAssertEqual(arguments["analysis_scope"] as? String, "complete")
        XCTAssertEqual(arguments["group_by"] as? String, "none")
    }

    func testScreenshotSixPenRequestKeepsEveryPenAndDate() throws {
        let intent = try XCTUnwrap(detect(
            "把大棚一舍、大棚四舍、大棚十二舍、大棚十三舍、大棚十四舍、大棚十五舍8月20日到9月30日的称重数据分析一下，计算一下日增重"
        ))
        XCTAssertEqual(intent.penNames, penNames)
        XCTAssertNil(intent.penName)
        XCTAssertEqual(intent.calculationArguments["pen_name"] as? String, "")
        XCTAssertEqual(intent.calculationArguments["pen_names"] as? [String], penNames)
        XCTAssertEqual(intent.dateFrom, "2026-08-20")
        XCTAssertEqual(intent.dateTo, "2026-09-30")
        XCTAssertTrue(intent.instruction.contains("2026-08-20 至 2026-09-30"))
        XCTAssertTrue(intent.instruction.contains("大棚十五舍"))
    }

    func testScreenshotFollowupUsesOnlyTheThreeRequestedPens() throws {
        let intent = try XCTUnwrap(detect(
            "大棚十三舍、大棚十四舍、大棚十五舍8月20日到9月30日的称重数据分析一下，计算一下日增重"
        ))
        XCTAssertEqual(intent.penNames, ["大棚十三舍", "大棚十四舍", "大棚十五舍"])
        XCTAssertFalse(intent.penNames.contains("大棚十二舍"))
        XCTAssertEqual(intent.dateFrom, "2026-08-20")
        XCTAssertEqual(intent.dateTo, "2026-09-30")
    }

    func testPenMatchingPreservesUserOrderAndShieldsShorterNames() throws {
        let intent = try XCTUnwrap(InsightRateAnalysisIntent.detect(
            question: "大棚十五舍、大棚十二舍、大棚十五舍称重数据分析一下",
            availablePenNames: ["十二舍", "大棚十二舍", "大棚十五舍"],
            now: referenceDate,
            timeZone: shanghai
        ))
        XCTAssertEqual(intent.penNames, ["大棚十五舍", "大棚十二舍"])
    }

    func testUnknownPenDoesNotBecomeFarmOrPartialAnalysis() {
        XCTAssertNil(detect("大棚十六舍日增重多少"))
        XCTAssertNil(detect("大棚十三舍、大棚十六舍日增重多少"))
        XCTAssertNil(InsightRateAnalysisIntent.detect(
            question: "大棚十一舍日增重多少",
            availablePenNames: ["一舍"]
        ))
        XCTAssertNil(detect("大棚十二舍东日增重多少"))
    }

    func testExplicitYearsSupportAStatedCrossYearRange() throws {
        let intent = try XCTUnwrap(detect("大棚十二舍2025年12月20日到2026年1月10日日增重分析"))
        XCTAssertEqual(intent.dateFrom, "2025-12-20")
        XCTAssertEqual(intent.dateTo, "2026-01-10")
        let sameYear = try XCTUnwrap(detect("大棚十二舍从2025年8月20日至9月30日期间计算日增重"))
        XCTAssertEqual(sameYear.dateFrom, "2025-08-20")
        XCTAssertEqual(sameYear.dateTo, "2025-09-30")
    }

    func testYearlessDatesUseTheFarmCalendarYear() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-31T16:30:00Z"))
        let intent = try XCTUnwrap(InsightRateAnalysisIntent.detect(
            question: "大棚十二舍1月1日到1月1日日增重多少",
            availablePenNames: penNames,
            now: now,
            timeZone: shanghai
        ))
        XCTAssertEqual(intent.dateFrom, "2027-01-01")
        XCTAssertEqual(intent.dateTo, "2027-01-01")
        let utcIntent = try XCTUnwrap(InsightRateAnalysisIntent.detect(
            question: "大棚十二舍1月1日到1月1日日增重多少",
            availablePenNames: penNames,
            now: now,
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        ))
        XCTAssertEqual(utcIntent.dateFrom, "2026-01-01")
    }

    func testAmbiguousOrUnsupportedDatesStayWithModelPlanning() {
        for question in [
            "大棚十二舍12月20日到1月10日日增重多少",
            "大棚十二舍2025年12月20日到1月10日日增重多少",
            "大棚十二舍8月32日到9月30日日增重多少",
            "大棚十二舍2月30日到9月30日日增重多少",
            "大棚十二舍2026年7月日增重多少",
            "大棚十二舍今年8月20日到9月30日日增重多少",
            "大棚十二舍8/20到9/30日增重多少",
            "大棚十二舍最近30天日增重多少",
            "大棚十二舍过去一年日增重多少",
            "大棚十二舍上个月日增重多少",
            "大棚十二舍8月20日到9月30日，截至10月1日计算日增重",
            "大棚十二舍8月20日到9月30日和7月1日到7月31日日增重分析",
            "大棚十二舍12月1日到12月31日日增重多少",
        ] {
            XCTAssertNil(detect(question), question)
        }
    }

    func testRawRecordsAndIndividualSheepStayWithModelPlanning() {
        XCTAssertNil(detect("大棚十二舍最近一次称重记录"))
        XCTAssertNil(detect("大棚十二舍每只羊日增重多少"))
        XCTAssertNil(detect("大棚十二舍耳号1234日增重多少"))
    }

    func testNarrowerAnalysisConditionsStayWithModelPlanning() {
        for scope in [
            "在舍期间", "全程连续在舍", "当前仍在群", "当前在场", "存栏", "育肥一批次",
            "公羊", "母羊", "公母", "杜泊", "羔羊", "湖羊品种", "常规称重", "断奶", "初生", "只看", "仅",
            "首末", "两次称重", "按月", "按日", "每月", "每天的", "排名", "中位数", "最大", "最小",
            "出售", "死亡", "淘汰", "转出", "低于200克", "月龄3个月",
        ] {
            let question = "大棚十二舍\(scope)日增重分析"
            XCTAssertNil(detect(question), question)
        }
    }

    func testAFilterWordInsideAnExactPenNameDoesNotNarrowThePopulation() throws {
        let intent = try XCTUnwrap(InsightRateAnalysisIntent.detect(
            question: "母羊舍日增重多少",
            availablePenNames: ["母羊舍"],
            now: referenceDate,
            timeZone: shanghai
        ))
        XCTAssertEqual(intent.penNames, ["母羊舍"])
    }

    func testUnknownBreedAgeAndStageStayWithModelPlanning() {
        for filter in ["澳洲白", "成年羊", "饲养阶段未知", "新育种品系", "适繁年龄组"] {
            XCTAssertNil(detect("大棚十二舍\(filter)日增重分析"), filter)
            XCTAssertNil(detect("大棚十二舍\(filter)8月20日到9月30日的称重数据分析一下，计算一下日增重"), filter)
        }
    }

    func testOrdinaryFarmAndEnglishRequestsRemainSupported() throws {
        for question in [
            "全场日增重分析", "牧场日增重分析", "羊群日增重分析", "大棚十二舍日增重多少",
            "牧场 daily gain", "大棚十二舍 average daily gain", "Please calculate daily gain for the farm",
        ] {
            XCTAssertNotNil(detect(question), question)
        }
    }

    private var referenceDate: Date {
        // 2026-10-01 in Asia/Shanghai.
        Date(timeIntervalSince1970: 1_790_812_800)
    }

    private var shanghai: TimeZone {
        TimeZone(identifier: "Asia/Shanghai")!
    }

    private func detect(_ question: String) -> InsightRateAnalysisIntent? {
        InsightRateAnalysisIntent.detect(
            question: question,
            availablePenNames: penNames,
            now: referenceDate,
            timeZone: shanghai
        )
    }
}
