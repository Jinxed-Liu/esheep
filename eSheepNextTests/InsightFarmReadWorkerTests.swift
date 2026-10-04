import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class InsightFarmReadWorkerTests: XCTestCase {
    func testConversationCalculationFiltersBatchAndAllSixPensWhileKeepingCrossPenGain() async throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let registry = InsightToolRegistry()
        let result = try await registry.executeForConversation(
            try calculationCall(batchID: fixture.batchID, penNames: fixture.penNames),
            agent: .init(
                accountID: UUID(), farmID: fixture.farmID, role: .owner,
                originDeviceID: UUID(), conversationID: UUID()
            ),
            context: context
        )
        let object = try outputObject(result.output)
        XCTAssertEqual(object["analysis_engine"] as? String, "WeightGainAnalyticsEngine")
        XCTAssertEqual(object["analyzed_profile_count"] as? Int, 6)
        XCTAssertEqual(object["observation_count"] as? Int, 6)
        XCTAssertEqual(object["cross_pen_interval_count"] as? Int, 1)
        let arguments = try XCTUnwrap(object["canonical_arguments"] as? [String: Any])
        XCTAssertEqual(arguments["batch_id"] as? String, fixture.batchID.uuidString.lowercased())
        XCTAssertEqual(arguments["pen_names"] as? [String], fixture.penNames)
        let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(groups.first?["value"] as? Double), 0.2, accuracy: 0.000_001)
        let sections = try XCTUnwrap(object["analysis_sections"] as? [[String: Any]])
        let penGroups = try XCTUnwrap(sections.first { $0["dimension"] as? String == "pen" }?["groups"] as? [[String: Any]])
        XCTAssertEqual(penGroups.compactMap { $0["key"] as? String }, fixture.penNames)
        XCTAssertTrue(penGroups.allSatisfy { $0["sheep_count"] as? Int == 1 })
        XCTAssertTrue(result.actionDrafts.isEmpty)
        XCTAssertFalse(context.hasChanges)
    }

    func testUnknownOrOtherFarmBatchCannotFallBackToAllBatches() throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let foreignBatch = ProductionBatchRecord(
            farmID: UUID(), name: "第八批", purpose: "育肥", startedAt: .distantPast
        )
        context.insert(foreignBatch)
        try context.save()
        for id in [UUID(), foreignBatch.id] {
            let call = try calculationCall(batchID: id, penNames: fixture.penNames)
            let arguments = try outputObject(call.argumentsJSON)
            XCTAssertThrowsError(try InsightFarmCalculationEngine().execute(
                arguments: arguments, farmID: fixture.farmID, context: context
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("batch_id"))
            }
        }
    }

    func testBatchFilterRejectsAnUnsupportedOperatorPlan() throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        var arguments = try outputObject(calculationCall(
            batchID: fixture.batchID, penNames: fixture.penNames
        ).argumentsJSON)
        arguments["sample_policy"] = "recorded_only"
        XCTAssertThrowsError(try InsightFarmCalculationEngine().execute(
            arguments: arguments, farmID: fixture.farmID, context: context
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("batch_id"))
        }
    }

    func testCancelledReadDoesNotFetchOrReturnEvidence() async throws {
        let container = try AppSchema.makeContainer(
            name: "insight-cancelled-read-\(UUID())", isStoredInMemoryOnly: true
        )
        let worker = InsightFarmReadWorker(container: container)
        let call = try calculationCall(batchID: UUID(), penNames: [])
        let task = Task { try await worker.execute(call, farmID: UUID()) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled task must not return factual evidence")
        } catch is CancellationError {
            // No farm was inserted; cancellation must precede any fetch.
        }
    }

    private struct Fixture {
        let container: ModelContainer
        let farmID: UUID
        let batchID: UUID
        let penNames: [String]
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-six-pens-\(UUID())", isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "批次多舍测试牧场")
        farm.timeZoneIdentifier = "Asia/Shanghai"
        context.insert(farm)
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-01T00:00:00+08:00"))
        let end = start.addingTimeInterval(10 * 86_400)
        let names = ["大棚一舍", "大棚四舍", "大棚十二舍", "大棚十三舍", "大棚十四舍", "大棚十五舍"]
        let pens = names.map { PenRecord(farmID: farm.id, name: $0) }
        for pen in pens { context.insert(pen) }
        let outside = PenRecord(farmID: farm.id, name: "其他舍")
        context.insert(outside)
        let batch = ProductionBatchRecord(
            farmID: farm.id, name: "第八批", purpose: "育肥", startedAt: start.addingTimeInterval(-86_400)
        )
        let otherBatch = ProductionBatchRecord(
            farmID: farm.id, name: "第九批", purpose: "育肥", startedAt: start.addingTimeInterval(-86_400)
        )
        context.insert(batch)
        context.insert(otherBatch)
        func addSheep(_ earTag: String, pen: PenRecord, batchID: UUID, gain: String, transferred: Bool = false) {
            let sheep = SheepRecord(
                farmID: farm.id, earTag: earTag, breed: "湖羊", sex: .ram,
                penID: transferred ? outside.id : pen.id,
                enteredAt: start.addingTimeInterval(-86_400)
            )
            context.insert(sheep)
            context.insert(BatchMembershipRecord(
                farmID: farm.id, batchID: batchID, sheepID: sheep.id,
                joinedAt: start.addingTimeInterval(-86_400)
            ))
            context.insert(WeightRecord(
                farmID: farm.id, sheepID: sheep.id, kilogramsText: "10", occurredAt: start
            ))
            context.insert(WeightRecord(
                farmID: farm.id, sheepID: sheep.id, kilogramsText: gain, occurredAt: end
            ))
            if transferred {
                context.insert(TransferRecord(
                    farmID: farm.id, sheepID: sheep.id, fromPenID: outside.id,
                    toPenID: pen.id, occurredAt: start.addingTimeInterval(5 * 86_400)
                ))
                sheep.currentPenID = pen.id
            }
        }
        for (index, pen) in pens.enumerated() {
            addSheep("B8-\(index)", pen: pen, batchID: batch.id, gain: "12", transferred: index == 0)
        }
        // A wrong batch in a selected pen and the right batch in an unrelated
        // pen deliberately have much larger gains to expose a dropped filter.
        addSheep("B9-IN", pen: pens[0], batchID: otherBatch.id, gain: "110")
        addSheep("B8-OUT", pen: outside, batchID: batch.id, gain: "210")
        try context.save()
        return Fixture(container: container, farmID: farm.id, batchID: batch.id, penNames: names)
    }

    private func calculationCall(batchID: UUID, penNames: [String]) throws -> InsightFunctionCall {
        let arguments: [String: Any] = [
            "source": "weight_samples", "sample_policy": "canonical_timeline",
            "cohort": "all_profiles", "pen_membership": "at_cutoff",
            "pen_name": "", "pen_names": penNames, "batch_id": batchID.uuidString,
            "ear_tag": "", "breed": "", "sex": "", "date_from": "2026-09-01",
            "date_to": "2026-09-11", "as_of": "", "partition_by": "sheep",
            "window": "adjacent", "transform": "difference_per_day",
            "analysis_scope": "complete", "group_by": "none", "reduce": "average",
            "selection": "all", "limit": 100,
        ]
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return .init(callID: "batch-six-pens", name: InsightFarmCalculationEngine.toolName,
                     argumentsJSON: String(decoding: data, as: UTF8.self))
    }

    private func outputObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
