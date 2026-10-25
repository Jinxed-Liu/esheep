import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class ReproductionQueryConsistencyTests: XCTestCase {
    func testCurrentSheepStateQueryLoadsFactsWithoutARelationFilter() throws {
        let container = try AppSchema.makeContainer(name: "ReproductionQuery-\(UUID())", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "查询一致性")
        context.insert(farm)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for (tag, result) in [("PREGNANT", "已孕"), ("OPEN", "空怀"), ("RECHECK", "复检")] {
            let ewe = SheepRecord(farmID: farm.id, earTag: tag, breed: "湖羊", sex: .ewe,
                                  penID: nil, enteredAt: at.addingTimeInterval(-30 * 86400))
            context.insert(ewe)
            context.insert(ReproductionRecord(farmID: farm.id, eweID: ewe.id, kind: .parityBaseline,
                                              occurredAt: at.addingTimeInterval(-20 * 86400), parity: 0))
            context.insert(ReproductionRecord(farmID: farm.id, eweID: ewe.id, kind: .pregnancyCheck,
                                              occurredAt: at.addingTimeInterval(-86400), result: result))
        }
        try context.save()
        var arguments: [String: Any] = ["query_kind": "current_herd", "subject": "sheep", "sex": "ewe",
            "group_by": "reproduction_state", "metric": "count", "date_field": "none", "date_from": "", "date_to": "",
            "as_of": "", "ear_tag": "", "status": "", "breed": "", "pen_name": "", "kind": "", "item_name": "",
            "minimum_value": "", "maximum_value": "", "relations": [], "limit": 100]
        let engine = InsightFarmQueryEngine()
        let grouped = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput:
            engine.execute(arguments: arguments, farmID: farm.id, context: context, now: at)))
        XCTAssertEqual(grouped.totalMatchingCount, 3)
        for title in ["检胎已孕", "检胎空怀", "待复检"] {
            XCTAssertTrue(grouped.markdown.contains("| \(title) | 1 |"), grouped.markdown)
        }
        XCTAssertFalse(grouped.markdown.contains("结果待核实"))

        arguments["group_by"] = "none"
        arguments["metric"] = "records"
        arguments["ear_tag"] = "PREGNANT"
        let detail = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput:
            engine.execute(arguments: arguments, farmID: farm.id, context: context, now: at)))
        XCTAssertTrue(detail.markdown.contains("检胎已孕"), detail.markdown)
        XCTAssertTrue(detail.markdown.contains("| 0 | 1 |"), detail.markdown)
    }
}
