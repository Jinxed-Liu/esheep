import Foundation
import XCTest
@testable import eSheepNext

final class InsightWeightGainRendererTests: XCTestCase {
    func testNativeMultiPenAnalysisKeepsDatesAndAppAverageWithEveryDimension() throws {
        let pens = ["大棚十三舍", "大棚十四舍", "大棚十五舍"]
        let evidence = try completeEvidence(pens: pens)

        let answer = try rendered(evidence)

        XCTAssertTrue(answer.contains("## 大棚十三舍、大棚十四舍、大棚十五舍日增重完整分析"))
        XCTAssertTrue(answer.contains("分析日期：2026-08-20 至 2026-09-30（Asia/Shanghai）"))
        XCTAssertTrue(answer.contains("| 平均日增重（逐羊等权） | 0.350 kg/天 |"))
        XCTAssertTrue(answer.contains("| 区间等权平均（补充） | 0.550 kg/天 |"))
        XCTAssertFalse(answer.contains("| 平均日增重（逐羊等权） | 0.550 kg/天 |"))
        for heading in ["总体结论", "期末圈舍", "称重区间", "生产批次", "生命周期", "数据完整性"] {
            XCTAssertTrue(answer.contains("### \(heading)"), "Missing dimension: \(heading)")
        }
        XCTAssertTrue(answer.contains("| 大棚十三舍 | 2 | 1 | 0.300 kg/天 |"))
        XCTAssertTrue(answer.contains("| 大棚十四舍 | 2 | 1 | 0.400 kg/天 |"))
        XCTAssertTrue(answer.contains("| 大棚十五舍 | 0 | 0 | — kg/天 |"))
        XCTAssertFalse(answer.contains("| 大棚十五舍 | 0 | 0 | 0.000 kg/天 |"))
        XCTAssertTrue(answer.contains("| 2026-08-20 → 2026-09-20（31天） | 4 | 2 | 0.350 kg/天 |"))
        XCTAssertTrue(answer.contains("| 育肥一批 | 4 | 2 | 0.350 kg/天 |"))
        XCTAssertTrue(answer.contains("| 当前在群 | 4 | 2 | 0.350 kg/天 |"))
        XCTAssertTrue(answer.contains("各维度均未截断"))
    }

    func testNativeTransferFactsIncludeEventsAfterTheLastWeighingAtFarmLocalDate() throws {
        let evidence = try completeEvidence(extra: [
            "cross_pen_interval_count": 2,
            "cross_pen_sheep_count": 1,
            "transfer_sheep_count": 2,
            "transfer_event_count": 2,
            "pen_history_basis": "包含末次称重后至分析截止的调群；截止后的调群不影响结果。",
            "transfer_events": [
                [
                    "ear_tag": "S-001", "occurred_at": "2026-09-10T16:30:00Z",
                    "from_pen_name": "大棚十二舍", "to_pen_name": "大棚十三舍",
                ],
                [
                    "ear_tag": "S-002", "occurred_at": "2026-09-30T14:00:00Z",
                    "from_pen_name": "大棚十三舍", "to_pen_name": "大棚十四舍",
                ],
            ],
        ])

        let answer = try rendered(evidence)

        XCTAssertTrue(answer.contains("数据范围：2026-08-20 至 2026-09-20"))
        XCTAssertTrue(answer.contains("转群事实：2026-09-11 · S-001 · 大棚十二舍 → 大棚十三舍"))
        XCTAssertTrue(answer.contains("转群事实：2026-09-30 · S-002 · 大棚十三舍 → 大棚十四舍"))
        XCTAssertTrue(answer.contains("2 个有效区间涉及 1 只羊"))
        XCTAssertTrue(answer.contains("分析期间有转群事实的羊共 2 只"))
        XCTAssertTrue(answer.contains("包含末次称重后至分析截止的调群"))
        XCTAssertTrue(answer.contains("跨舍增重保留"))
    }

    func testNativeExclusionsUseSharedRuleCountsInsteadOfDefaultCrossPenExclusion() throws {
        let evidence = try completeEvidence(extra: [
            "exclusion_counts": ["称重点不足": 2, "分析范围外": 1],
            "excluded_native_intervals": 1,
            // The legacy counter must not become the native exclusion policy.
            "excluded_non_continuous_pen_intervals": 9,
            "cross_pen_interval_count": 2,
            "cross_pen_sheep_count": 1,
        ])

        let answer = try rendered(evidence)

        XCTAssertTrue(answer.contains("未纳入原因（分类计数）"))
        XCTAssertTrue(answer.contains("称重点不足 2"))
        XCTAssertTrue(answer.contains("分析范围外 1"))
        XCTAssertTrue(answer.contains("未纳入的候选称重区间：1 个"))
        XCTAssertTrue(answer.contains("跨舍增重保留"))
        XCTAssertFalse(answer.contains("圈舍归属不连续"))
        XCTAssertFalse(answer.contains("9 个候选区间"))
        XCTAssertFalse(answer.contains("跨舍排除"))
    }

    func testTransferSummaryReportsActualDisplayedCountWhenToolEvidenceIsTruncated() throws {
        let evidence = try completeEvidence(extra: [
            "transfer_event_count": 8,
            "transfer_events_truncated": true,
            "transfer_events": [
                [
                    "ear_tag": "S-001", "occurred_at": "2026-09-30T14:00:00Z",
                    "from_pen_name": "大棚十三舍", "to_pen_name": "大棚十四舍",
                ],
            ],
        ])

        let answer = try rendered(evidence)

        XCTAssertEqual(answer.components(separatedBy: "- 转群事实：").count - 1, 1)
        XCTAssertTrue(answer.contains("本段展示 1 条转群事实，分析期间共 8 条"))
        XCTAssertFalse(answer.contains("展示 6 条"))
        XCTAssertFalse(answer.contains("展示前 6 条"))
    }

    func testVerifiedCompleteAnalysisMergesDifferentCanonicalDateRangesInEvidenceOrder() throws {
        let first = try completeEvidence(
            pens: ["大棚十三舍"], dateFrom: "2026-08-20", dateTo: "2026-08-31", value: 0.11
        )
        let second = try completeEvidence(
            pens: ["大棚十三舍"], dateFrom: "2026-09-01", dateTo: "2026-09-30", value: 0.22
        )

        let answer = try XCTUnwrap(InsightGroundedFallbackRenderer.verifiedCompleteAnalysis(
            calculationEvidence: [first, second]
        ))

        XCTAssertEqual(answer.components(separatedBy: "## 大棚十三舍日增重完整分析").count - 1, 2)
        let firstDate = try XCTUnwrap(answer.range(of: "2026-08-20 至 2026-08-31"))
        let secondDate = try XCTUnwrap(answer.range(of: "2026-09-01 至 2026-09-30"))
        XCTAssertLessThan(firstDate.lowerBound, secondDate.lowerBound)
        XCTAssertTrue(answer.contains("| 平均日增重（逐羊等权） | 0.110 kg/天 |"))
        XCTAssertTrue(answer.contains("| 平均日增重（逐羊等权） | 0.220 kg/天 |"))
    }

    func testTransferTruncationIsDisclosedWhenNoDetailFitsTheEvidenceBudget() throws {
        let evidence = try completeEvidence(extra: [
            "transfer_event_count": 8,
            "transfer_events_truncated": true,
            "transfer_events": [[String: Any]](),
        ])
        let answer = try rendered(evidence)
        XCTAssertTrue(answer.contains("本段展示 0 条转群事实，分析期间共 8 条"))
    }

    func testVerifiedCompleteAnalysisKeepsLatestEvidenceForTheSameCanonicalArguments() throws {
        let first = try completeEvidence(pens: ["大棚十三舍"], value: 0.11)
        let other = try completeEvidence(pens: ["大棚十四舍"], value: 0.22)
        let latest = try completeEvidence(pens: ["大棚十三舍"], value: 0.33)

        let answer = try XCTUnwrap(InsightGroundedFallbackRenderer.verifiedCompleteAnalysis(
            calculationEvidence: [first, other, latest]
        ))

        XCTAssertEqual(answer.components(separatedBy: "## 大棚十三舍日增重完整分析").count - 1, 1)
        XCTAssertTrue(answer.contains("## 大棚十四舍日增重完整分析"))
        XCTAssertTrue(answer.contains("| 平均日增重（逐羊等权） | 0.330 kg/天 |"))
        XCTAssertTrue(answer.contains("| 平均日增重（逐羊等权） | 0.220 kg/天 |"))
        XCTAssertFalse(answer.contains("0.110 kg/天"))
    }

    func testLaterFocusedEvidenceCannotHideVerifiedCompleteAnalysis() throws {
        let complete = try completeEvidence(pens: ["大棚十三舍"], value: 0.35)
        let focused = try json([
            "evidence_kind": "farm_calculation", "result_unit": "kg/day",
            "observation_count": 1, "is_complete": true,
            "canonical_arguments": [
                "pen_names": ["大棚十三舍"], "date_from": "2026-08-20", "date_to": "2026-09-30",
                "pen_membership": "at_cutoff", "analysis_scope": "focused",
            ],
            "groups": [group("all", value: 99, samples: 1, sheep: 1)],
        ])

        XCTAssertNil(InsightGroundedFallbackRenderer.verifiedCompleteAnalysis(
            calculationEvidence: [focused]
        ))
        let verified = try XCTUnwrap(InsightGroundedFallbackRenderer.verifiedCompleteAnalysis(
            calculationEvidence: [complete, focused]
        ))
        let fallback = InsightGroundedFallbackRenderer.render(
            question: "大棚十三舍日增重分析", queries: [],
            calculationEvidence: [complete, focused], issue: "候选回答缺少分组"
        )

        XCTAssertEqual(fallback, verified)
        XCTAssertTrue(verified.contains("| 平均日增重（逐羊等权） | 0.350 kg/天 |"))
        XCTAssertTrue(verified.contains("### 生产批次"))
        XCTAssertFalse(verified.contains("99"))
    }

    func testNewRequestRenderedWithOnlyCurrentTurnEvidenceDoesNotReuseHistoricalPens() throws {
        let previous = try completeEvidence(pens: ["大棚十二舍"], value: 0.12)
        XCTAssertNotNil(InsightGroundedFallbackRenderer.verifiedCompleteAnalysis(
            calculationEvidence: [previous]
        ))
        let current = try completeEvidence(pens: ["大棚十三舍", "大棚十四舍", "大棚十五舍"])

        let answer = InsightGroundedFallbackRenderer.render(
            question: "大棚十三舍、大棚十四舍、大棚十五舍8月20日到9月30日日增重分析",
            queries: [], calculationEvidence: [current], issue: "候选回答未引用本轮计算"
        )

        XCTAssertTrue(answer.contains("## 大棚十三舍、大棚十四舍、大棚十五舍日增重完整分析"))
        XCTAssertFalse(answer.contains("大棚十二舍"))
        XCTAssertFalse(answer.contains("0.120 kg/天"))
    }

    private func rendered(_ evidence: String) throws -> String {
        try XCTUnwrap(InsightGroundedFallbackRenderer.verifiedCompleteAnalysis(
            calculationEvidence: [evidence]
        ))
    }

    private func completeEvidence(
        pens: [String] = ["大棚十三舍", "大棚十四舍", "大棚十五舍"],
        dateFrom: String = "2026-08-20",
        dateTo: String = "2026-09-30",
        value: Double = 0.35,
        extra: [String: Any] = [:]
    ) throws -> String {
        let intervalEnd = min(dateTo, "2026-09-20")
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "\(dateFrom)T00:00:00+08:00"))
        let end = try XCTUnwrap(formatter.date(from: "\(intervalEnd)T00:00:00+08:00"))
        let days = Int(end.timeIntervalSince(start) / 86_400)
        var overall = group("all", value: value)
        overall["interval_weighted_daily_rate"] = 0.55
        overall["first_interval_start"] = "\(dateFrom)T00:00:00+08:00"
        overall["last_interval_end"] = "\(intervalEnd)T00:00:00+08:00"
        let penGroups = pens.enumerated().map { index, pen in
            pens.count == 1
                ? group(pen, value: value)
                : group(pen, value: index == 2 ? nil : 0.3 + Double(index) * 0.1,
                        samples: index == 2 ? 0 : 2, sheep: index == 2 ? 0 : 1)
        }
        var object: [String: Any] = [
            "evidence_kind": "farm_calculation", "analysis_engine": "WeightGainAnalyticsEngine",
            "result_unit": "kg/day", "time_zone": "Asia/Shanghai",
            "observation_count": 4, "is_complete": true,
            "relevant_profile_count": 2, "analyzed_profile_count": 2,
            "canonical_arguments": [
                "pen_names": pens, "date_from": dateFrom, "date_to": dateTo,
                "pen_membership": "at_cutoff", "analysis_scope": "complete",
            ],
            "groups": [overall],
            "analysis_contract": [
                "kind": "multidimensional_adjacent_rate_analysis",
                "required_dimensions": ["none", "weighing_interval", "production_batch", "lifecycle_status", "pen"],
            ],
            "analysis_sections": [
                section("none", groups: [overall]),
                section("weighing_interval", groups: [group("\(dateFrom) → \(intervalEnd)（\(days)天）", value: value)]),
                section("production_batch", groups: [group("育肥一批", value: value)]),
                section("lifecycle_status", groups: [group("当前在群", value: value)]),
                section("pen", groups: penGroups),
            ],
        ]
        object.merge(extra) { _, newValue in newValue }
        return try json(object)
    }

    private func group(
        _ key: String, value: Double?, samples: Int = 4, sheep: Int = 2
    ) -> [String: Any] {
        var result: [String: Any] = ["key": key, "sample_count": samples, "sheep_count": sheep]
        if let value { result["value"] = value }
        return result
    }

    private func section(_ dimension: String, groups: [[String: Any]]) -> [String: Any] {
        ["dimension": dimension, "is_complete": true, "groups": groups]
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
