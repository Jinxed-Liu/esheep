import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import eSheepNext

@MainActor
final class InsightAssistantTests: XCTestCase {
    func testBornLambSkillOverridesConflictingRawTableParameters() throws {
        var arguments = farmQueryArguments(subject: "sheep")
        arguments["query_kind"] = FarmDataQuerySkill.QueryKind.bornLambs.rawValue
        arguments["date_field"] = "birth_at"
        arguments["kind"] = ""
        arguments["metric"] = "count"

        let normalized = try FarmDataQuerySkill.normalize(arguments: arguments)
        XCTAssertEqual(normalized["subject"] as? String, "reproduction")
        XCTAssertEqual(normalized["date_field"] as? String, "occurred_at")
        XCTAssertEqual(normalized["kind"] as? String, ReproductionRecordKind.lambing.rawValue)
        XCTAssertEqual(normalized["metric"] as? String, "sum")
    }

    func testGenericFarmCalculatorComposesDifferentMetricsFromTheSameFacts() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-generic-calculation-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let farm = insertFarm(farmID, into: context)
        farm.name = "通用计算测试牧场"
        let targetPen = PenRecord(farmID: farmID, name: "大棚十二舍")
        let otherPen = PenRecord(farmID: farmID, name: "其他圈舍")
        context.insert(targetPen)
        context.insert(otherPen)

        let firstAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-01T00:00:00+08:00")
        )
        let lastAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-11T00:00:00+08:00")
        )
        let asOf = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-20T00:00:00+08:00")
        )
        let firstSheep = SheepRecord(
            farmID: farmID,
            earTag: "7022",
            breed: "湖羊",
            sex: .ewe,
            penID: targetPen.id,
            enteredAt: firstAt.addingTimeInterval(-86_400)
        )
        let secondSheep = SheepRecord(
            farmID: farmID,
            earTag: "7028",
            breed: "湖羊",
            sex: .ewe,
            penID: targetPen.id,
            enteredAt: firstAt.addingTimeInterval(-86_400)
        )
        let excludedSheep = SheepRecord(
            farmID: farmID,
            earTag: "9999",
            breed: "湖羊",
            sex: .ewe,
            penID: otherPen.id,
            enteredAt: firstAt.addingTimeInterval(-86_400)
        )
        for sheep in [firstSheep, secondSheep, excludedSheep] {
            context.insert(sheep)
        }
        for (sheep, firstWeight, lastWeight) in [
            (firstSheep, "10", "12"),
            (secondSheep, "20", "23"),
            (excludedSheep, "10", "110"),
        ] {
            context.insert(WeightRecord(
                farmID: farmID,
                sheepID: sheep.id,
                kilogramsText: firstWeight,
                occurredAt: firstAt
            ))
            context.insert(WeightRecord(
                farmID: farmID,
                sheepID: sheep.id,
                kilogramsText: lastWeight,
                occurredAt: lastAt
            ))
        }
        try context.save()

        var ratePlan = farmCalculationArguments(
            penName: targetPen.name,
            asOf: ISO8601DateFormatter().string(from: asOf)
        )
        ratePlan["window"] = "adjacent"
        ratePlan["transform"] = "difference_per_day"
        ratePlan["group_by"] = "interval_end_day"
        ratePlan["reduce"] = "average"
        ratePlan["selection"] = "latest"
        let rateOutput = try InsightFarmCalculationEngine().execute(
            arguments: ratePlan,
            farmID: farmID,
            context: context,
            now: asOf
        )
        let rateObject = try calculationObject(rateOutput)
        let rateGroups = try XCTUnwrap(rateObject["groups"] as? [[String: Any]])
        let rateGroup = try XCTUnwrap(rateGroups.first)

        XCTAssertEqual(rateObject["result_unit"] as? String, "kg/day")
        XCTAssertEqual(rateObject["observation_count"] as? Int, 2)
        XCTAssertEqual(rateObject["eligible_profile_count"] as? Int, 2)
        XCTAssertEqual(rateGroup["key"] as? String, "2026-07-11")
        XCTAssertEqual(rateGroup["sample_count"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(rateGroup["value"] as? Double), 0.25, accuracy: 0.000_001)

        var changePlan = ratePlan
        changePlan["window"] = "first_to_last"
        changePlan["transform"] = "difference"
        changePlan["group_by"] = "none"
        changePlan["reduce"] = "average"
        changePlan["selection"] = "all"
        let changeOutput = try InsightFarmCalculationEngine().execute(
            arguments: changePlan,
            farmID: farmID,
            context: context,
            now: asOf
        )
        let changeObject = try calculationObject(changeOutput)
        let changeGroups = try XCTUnwrap(changeObject["groups"] as? [[String: Any]])
        let changeGroup = try XCTUnwrap(changeGroups.first)

        XCTAssertEqual(changeObject["result_unit"] as? String, "kg")
        XCTAssertEqual(changeObject["observation_count"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(changeGroup["value"] as? Double), 2.5, accuracy: 0.000_001)
        XCTAssertEqual(changeObject["operator_pipeline"] as? [String], [
            "filter", "sheep", "first_to_last", "difference", "focused", "none", "average", "all",
        ])

        let grounded = try XCTUnwrap(
            InsightFarmCalculationEngine.GroundedOutput(toolOutput: rateOutput)
        )
        XCTAssertEqual(grounded.contractVersion, FarmFactContract.version)
        XCTAssertEqual(grounded.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(grounded.observationCount, 2)
        XCTAssertTrue(grounded.isComplete)

        var invalidPlan = ratePlan
        invalidPlan["window"] = "none"
        XCTAssertThrowsError(try InsightFarmCalculationEngine().execute(
            arguments: invalidPlan,
            farmID: farmID,
            context: context,
            now: asOf
        ))
    }

    func testHistoricalPenCalculationUsesMeasurementMembershipWithoutPretendingItIsCurrentHerd() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-historical-pen-calculation-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let pen = PenRecord(farmID: farmID, name: "大棚十二舍")
        let firstAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-06-01T00:00:00+08:00")
        )
        let lastAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-06-11T00:00:00+08:00")
        )
        let removedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-06-20T00:00:00+08:00")
        )
        let asOf = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-01T00:00:00+08:00")
        )
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "HISTORICAL-PEN-001",
            breed: "湖羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: firstAt.addingTimeInterval(-86_400)
        )
        sheep.statusRawValue = SheepStatus.removed.rawValue
        sheep.currentPenID = nil
        sheep.removedAt = removedAt
        context.insert(pen)
        context.insert(sheep)
        context.insert(WeightRecord(
            farmID: farmID,
            sheepID: sheep.id,
            kilogramsText: "10",
            occurredAt: firstAt
        ))
        context.insert(WeightRecord(
            farmID: farmID,
            sheepID: sheep.id,
            kilogramsText: "12",
            occurredAt: lastAt
        ))
        context.insert(RemovalRecord(
            farmID: farmID,
            sheepID: sheep.id,
            kind: .sold,
            reason: "出售",
            occurredAt: removedAt
        ))
        try context.save()

        var historicalPlan = farmCalculationArguments(
            penName: pen.name,
            asOf: ISO8601DateFormatter().string(from: asOf)
        )
        historicalPlan["cohort"] = "all_profiles"
        historicalPlan["pen_membership"] = "at_measurement"
        historicalPlan["window"] = "adjacent"
        historicalPlan["transform"] = "difference_per_day"
        historicalPlan["group_by"] = "interval_end_day"
        historicalPlan["reduce"] = "average"
        historicalPlan["selection"] = "latest"
        let historicalOutput = try InsightFarmCalculationEngine().execute(
            arguments: historicalPlan,
            farmID: farmID,
            context: context,
            now: asOf
        )
        let historicalObject = try calculationObject(historicalOutput)
        let historicalGroups = try XCTUnwrap(historicalObject["groups"] as? [[String: Any]])
        let historicalValue = try XCTUnwrap(historicalGroups.first?["value"] as? Double)

        XCTAssertEqual(historicalValue, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(historicalObject["observation_count"] as? Int, 1)
        XCTAssertEqual(historicalObject["eligible_profile_count"] as? Int, 1)

        var currentPlan = historicalPlan
        currentPlan["cohort"] = "current_in_herd"
        currentPlan["pen_membership"] = "at_cutoff"
        let currentOutput = try InsightFarmCalculationEngine().execute(
            arguments: currentPlan,
            farmID: farmID,
            context: context,
            now: asOf
        )
        let currentObject = try calculationObject(currentOutput)

        XCTAssertEqual(currentObject["observation_count"] as? Int, 0)
        XCTAssertEqual(currentObject["eligible_profile_count"] as? Int, 0)
    }

    func testRateAnalysisIntentRoutesNaturalLanguageToCompletePlan() throws {
        let intent = try XCTUnwrap(
            InsightRateAnalysisIntent.detect(
                question: "大棚十二舍日增重多少",
                availablePenNames: ["一舍西", "大棚十二舍"]
            )
        )

        XCTAssertEqual(intent.penName, "大棚十二舍")
        XCTAssertEqual(intent.calculationArguments["source"] as? String, "weight_samples")
        XCTAssertEqual(intent.calculationArguments["window"] as? String, "adjacent")
        XCTAssertEqual(intent.calculationArguments["transform"] as? String, "difference_per_day")
        XCTAssertEqual(intent.calculationArguments["analysis_scope"] as? String, "complete")
        XCTAssertEqual(intent.calculationArguments["group_by"] as? String, "none")

        XCTAssertNil(
            InsightRateAnalysisIntent.detect(
                question: "大棚十二舍最近一次称重记录",
                availablePenNames: ["大棚十二舍"]
            )
        )
        XCTAssertNil(
            InsightRateAnalysisIntent.detect(
                question: "2026年7月大棚十二舍日增重多少",
                availablePenNames: ["大棚十二舍"]
            )
        )
        XCTAssertNil(
            InsightRateAnalysisIntent.detect(
                question: "大棚十二舍每只羊日增重多少",
                availablePenNames: ["大棚十二舍"]
            )
        )
    }

    func testCompleteRateAnalysisSeparatesIntervalsBatchesAndLifecycleOutcomes() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-complete-rate-analysis-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let pen = PenRecord(farmID: farmID, name: "分析圈舍")
        let firstAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-01T00:00:00+08:00")
        )
        let secondAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-11T00:00:00+08:00")
        )
        let removalAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-15T00:00:00+08:00")
        )
        let asOf = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-20T00:00:00+08:00")
        )
        let batchA = ProductionBatchRecord(
            farmID: farmID,
            name: "育肥一批",
            purpose: "育肥",
            startedAt: firstAt.addingTimeInterval(-86_400)
        )
        let batchB = ProductionBatchRecord(
            farmID: farmID,
            name: "育肥二批",
            purpose: "育肥",
            startedAt: firstAt.addingTimeInterval(-86_400)
        )
        context.insert(pen)
        context.insert(batchA)
        context.insert(batchB)

        func makeSheep(_ earTag: String) -> SheepRecord {
            let sheep = SheepRecord(
                farmID: farmID,
                earTag: earTag,
                breed: "湖羊",
                sex: .ram,
                penID: pen.id,
                enteredAt: firstAt.addingTimeInterval(-86_400)
            )
            context.insert(sheep)
            return sheep
        }
        func addWeights(_ sheep: SheepRecord, _ first: String, _ second: String) {
            context.insert(WeightRecord(
                farmID: farmID,
                sheepID: sheep.id,
                kilogramsText: first,
                occurredAt: firstAt
            ))
            context.insert(WeightRecord(
                farmID: farmID,
                sheepID: sheep.id,
                kilogramsText: second,
                occurredAt: secondAt
            ))
        }
        func assign(_ sheep: SheepRecord, to batch: ProductionBatchRecord) {
            context.insert(BatchMembershipRecord(
                farmID: farmID,
                batchID: batch.id,
                sheepID: sheep.id,
                joinedAt: firstAt.addingTimeInterval(-86_400)
            ))
        }
        func remove(_ sheep: SheepRecord, kind: RemovalKind) {
            sheep.statusRawValue = kind.resultingStatus.rawValue
            sheep.currentPenID = nil
            sheep.removedAt = removalAt
            context.insert(RemovalRecord(
                farmID: farmID,
                sheepID: sheep.id,
                kind: kind,
                reason: kind.displayName,
                occurredAt: removalAt
            ))
        }

        let active = makeSheep("ACTIVE-A")
        addWeights(active, "10", "12")
        assign(active, to: batchA)

        let sold = makeSheep("SOLD-A")
        addWeights(sold, "20", "23")
        assign(sold, to: batchA)
        remove(sold, kind: .sold)

        let deceased = makeSheep("DECEASED-B")
        addWeights(deceased, "30", "31")
        assign(deceased, to: batchB)
        remove(deceased, kind: .deceased)

        let crossBatch = makeSheep("CROSS-BATCH")
        addWeights(crossBatch, "40", "44")
        let firstMembership = BatchMembershipRecord(
            farmID: farmID,
            batchID: batchA.id,
            sheepID: crossBatch.id,
            joinedAt: firstAt.addingTimeInterval(-86_400)
        )
        firstMembership.leftAt = firstAt
        context.insert(firstMembership)
        context.insert(BatchMembershipRecord(
            farmID: farmID,
            batchID: batchB.id,
            sheepID: crossBatch.id,
            joinedAt: secondAt
        ))
        try context.save()

        var plan = farmCalculationArguments(
            penName: pen.name,
            asOf: ISO8601DateFormatter().string(from: asOf)
        )
        plan["sample_policy"] = "recorded_only"
        plan["cohort"] = "all_profiles"
        plan["pen_membership"] = "at_measurement"
        plan["window"] = "adjacent"
        plan["transform"] = "difference_per_day"
        plan["analysis_scope"] = "complete"
        plan["group_by"] = "none"
        plan["reduce"] = "average"
        plan["selection"] = "all"

        let output = try InsightFarmCalculationEngine().execute(
            arguments: plan,
            farmID: farmID,
            context: context,
            now: asOf
        )
        let object = try calculationObject(output)
        let contract = try XCTUnwrap(object["analysis_contract"] as? [String: Any])
        let requiredDimensions = try XCTUnwrap(contract["required_dimensions"] as? [String])
        let sections = try XCTUnwrap(object["analysis_sections"] as? [[String: Any]])

        XCTAssertEqual(requiredDimensions, [
            "none", "weighing_interval", "production_batch", "lifecycle_status",
        ])
        XCTAssertEqual(sections.compactMap { $0["dimension"] as? String }, requiredDimensions)
        XCTAssertEqual(object["observation_count"] as? Int, 4)
        XCTAssertEqual(object["analyzed_profile_count"] as? Int, 4)

        let overall = try sectionGroup("none", key: "all", in: sections)
        XCTAssertEqual(try XCTUnwrap(overall["average"] as? Double), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(overall["minimum"] as? Double), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(overall["maximum"] as? Double), 0.4, accuracy: 0.000_001)
        XCTAssertEqual(overall["sample_count"] as? Int, 4)
        XCTAssertEqual(overall["sheep_count"] as? Int, 4)
        XCTAssertEqual(overall["elapsed_days_minimum"] as? Int, 10)
        XCTAssertEqual(overall["elapsed_days_maximum"] as? Int, 10)

        let batchAGroup = try sectionGroup("production_batch", key: "育肥一批", in: sections)
        XCTAssertEqual(batchAGroup["sample_count"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(batchAGroup["average"] as? Double), 0.25, accuracy: 0.000_001)
        let batchBGroup = try sectionGroup("production_batch", key: "育肥二批", in: sections)
        XCTAssertEqual(try XCTUnwrap(batchBGroup["average"] as? Double), 0.1, accuracy: 0.000_001)
        let crossGroup = try sectionGroup("production_batch", key: "跨生产批次区间", in: sections)
        XCTAssertEqual(try XCTUnwrap(crossGroup["average"] as? Double), 0.4, accuracy: 0.000_001)

        let activeGroup = try sectionGroup("lifecycle_status", key: "当前在群", in: sections)
        XCTAssertEqual(activeGroup["sample_count"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(activeGroup["average"] as? Double), 0.3, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(sectionGroup("lifecycle_status", key: "出售", in: sections)["average"] as? Double),
            0.3,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(sectionGroup("lifecycle_status", key: "死亡", in: sections)["average"] as? Double),
            0.1,
            accuracy: 0.000_001
        )

        for (key, invalidValue) in [
            ("sample_policy", "canonical_timeline"),
            ("cohort", "current_in_herd"),
            ("pen_membership", "at_cutoff"),
            ("group_by", "weighing_interval"),
        ] {
            var invalidPlan = plan
            invalidPlan[key] = invalidValue
            XCTAssertThrowsError(try InsightFarmCalculationEngine().execute(
                arguments: invalidPlan,
                farmID: farmID,
                context: context,
                now: asOf
            ), "complete analysis accepted semantically narrowed \(key)=\(invalidValue)")
        }
    }

    func testAdjacentPenRateDoesNotBridgeAcrossAnOutsidePenMeasurement() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-no-false-adjacent-interval-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let target = PenRecord(farmID: farmID, name: "目标圈")
        let outside = PenRecord(farmID: farmID, name: "外圈")
        let day1 = Date(timeIntervalSince1970: 1_783_353_600)
        let day2 = day1.addingTimeInterval(10 * 86_400)
        let day3 = day2.addingTimeInterval(10 * 86_400)
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "PEN-TIMELINE",
            breed: "湖羊",
            sex: .ram,
            penID: target.id,
            enteredAt: day1.addingTimeInterval(-86_400)
        )
        context.insert(target)
        context.insert(outside)
        context.insert(sheep)
        context.insert(WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "10", occurredAt: day1))
        context.insert(TransferRecord(
            farmID: farmID,
            sheepID: sheep.id,
            fromPenID: target.id,
            toPenID: outside.id,
            occurredAt: day1.addingTimeInterval(86_400)
        ))
        context.insert(WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "20", occurredAt: day2))
        context.insert(TransferRecord(
            farmID: farmID,
            sheepID: sheep.id,
            fromPenID: outside.id,
            toPenID: target.id,
            occurredAt: day2.addingTimeInterval(86_400)
        ))
        context.insert(WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "30", occurredAt: day3))
        try context.save()

        var plan = farmCalculationArguments(
            penName: target.name,
            asOf: ISO8601DateFormatter().string(from: day3.addingTimeInterval(86_400))
        )
        plan["cohort"] = "all_profiles"
        plan["pen_membership"] = "at_measurement"
        plan["window"] = "adjacent"
        plan["transform"] = "difference_per_day"
        plan["group_by"] = "none"
        plan["reduce"] = "average"

        let output = try InsightFarmCalculationEngine().execute(
            arguments: plan,
            farmID: farmID,
            context: context,
            now: day3.addingTimeInterval(86_400)
        )
        let object = try calculationObject(output)

        XCTAssertEqual(object["observation_count"] as? Int, 0)
        XCTAssertEqual(object["excluded_non_continuous_pen_intervals"] as? Int, 2)
        XCTAssertEqual(object["excluded_insufficient_sample_profiles"] as? Int, 1)
        XCTAssertTrue((object["groups"] as? [[String: Any]])?.isEmpty == true)
    }

    func testCompleteCalculationAnswerContractRejectsCollapsedSingleAverage() {
        let output = #"{"evidence_kind":"farm_calculation","analysis_contract":{"kind":"multidimensional_adjacent_rate_analysis","required_answer_sections":["总体结论","称重区间","生产批次","生命周期","数据完整性"]}}"#
        let exchange = MiMoFunctionExchange(
            call: InsightFunctionCall(
                callID: "complete-analysis",
                name: InsightFarmCalculationEngine.toolName,
                argumentsJSON: "{}"
            ),
            output: output
        )

        XCTAssertNotNil(InsightCalculationAnswerContract.correctiveInstruction(
            candidate: "总体平均日增重 0.25 kg/day。",
            exchanges: [exchange]
        ))
        XCTAssertNil(InsightCalculationAnswerContract.correctiveInstruction(
            candidate: "# 总体结论\n# 称重区间\n# 生产批次\n# 生命周期\n# 数据完整性",
            exchanges: [exchange]
        ))
    }

    func testCompleteCalculationAnswerContractRejectsGroupValueDrift() {
        let output = #"{"evidence_kind":"farm_calculation","analysis_contract":{"kind":"multidimensional_adjacent_rate_analysis","required_answer_sections":["总体结论","称重区间","生产批次","生命周期","数据完整性"]},"analysis_sections":[{"dimension":"lifecycle_status","groups":[{"key":"出售","sample_count":180,"sheep_count":85,"value":0.3288059857}]}]}"#
        let exchange = MiMoFunctionExchange(
            call: InsightFunctionCall(
                callID: "complete-analysis-values",
                name: InsightFarmCalculationEngine.toolName,
                argumentsJSON: "{}"
            ),
            output: output
        )
        let sections = "# 总体结论\n# 称重区间\n# 生产批次\n# 生命周期\n# 数据完整性\n"

        XCTAssertNotNil(InsightCalculationAnswerContract.correctiveInstruction(
            candidate: sections + "| 出售 | 179 | 85 | 0.329 kg/天 |",
            exchanges: [exchange]
        ))
        XCTAssertNil(InsightCalculationAnswerContract.correctiveInstruction(
            candidate: sections + "| 出售 | 180 | 85 | 0.329 kg/天 |",
            exchanges: [exchange]
        ))
    }

    func testNativeHarnessFeedsToolEvidenceBackAndRetriesAnOffTargetAnswer() async throws {
        let toolCall = InsightFunctionCall(
            callID: "calculation-1",
            name: InsightFarmCalculationEngine.toolName,
            argumentsJSON: #"{"source":"weight_samples"}"#
        )
        let client = ScriptedMiMoResponder(scripts: [
            [
                .responseStarted(id: "response-1"),
                .functionCall(toolCall),
                .completed(responseID: "response-1", usage: nil),
            ],
            [
                .responseStarted(id: "response-2"),
                .textDelta("查询到两条称重记录。"),
                .completed(responseID: "response-2", usage: nil),
            ],
            [
                .responseStarted(id: "response-3"),
                .textDelta("大棚十二舍最近一次区间的平均日增重是 0.25 千克/天。"),
                .completed(responseID: "response-3", usage: nil),
            ],
        ])
        let tool = InsightToolDefinition(
            name: InsightFarmCalculationEngine.toolName,
            description: "测试用通用计算工具",
            parameters: ["type": .string("object")]
        )
        let credential = try MiMoCredential(apiKey: "sk-1234567890-harness")
        let harness = InsightAgentHarness(client: client, maximumToolRoundTrips: 4)
        var executionCount = 0
        var reviewCount = 0

        let result = try await harness.run(
            model: MiMoCredential.textModel,
            instructions: "回答用户实际问题。",
            messages: [MiMoInputMessage(role: .user, text: "大棚十二舍之前日增重多少")],
            tools: [tool],
            credential: credential,
            execute: { call in
                executionCount += 1
                XCTAssertEqual(call, toolCall)
                return .init(
                    output: #"{"evidence_kind":"farm_calculation","result_unit":"kg/day","groups":[{"value":0.25}]}"#,
                    succeeded: true
                )
            },
            reviewCandidate: { text, exchanges, successfulTools in
                reviewCount += 1
                XCTAssertEqual(exchanges.count, 1)
                XCTAssertEqual(exchanges.first?.call, toolCall)
                XCTAssertTrue(successfulTools.contains(InsightFarmCalculationEngine.toolName))
                if text.contains("两条称重记录") {
                    return .retry("工具返回的是计算证据，最终答案必须给出用户询问的数值和单位。")
                }
                return .accept
            },
            resolveRejectedCandidate: { _, _, _, _ in
                XCTFail("该脚本应在内部修复后通过，不应进入确定性兜底。")
                return ""
            }
        )

        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(reviewCount, 2)
        XCTAssertEqual(result.exchanges.count, 1)
        XCTAssertEqual(result.successfulToolNames, [InsightFarmCalculationEngine.toolName])
        XCTAssertEqual(result.text, "大棚十二舍最近一次区间的平均日增重是 0.25 千克/天。")
        let requests = client.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[0].functionExchanges.isEmpty)
        XCTAssertEqual(requests[1].functionExchanges.count, 1)
        XCTAssertEqual(requests[2].functionExchanges.count, 1)
        XCTAssertEqual(requests.map(\.model), Array(repeating: MiMoCredential.textModel, count: 3))
    }

    func testNativeHarnessResolvesRepeatedReviewFailureInsideTheSameRequest() async throws {
        let badAnswer: [InsightModelEvent] = [
            .responseStarted(id: "response"),
            .textDelta("请重试。"),
            .completed(responseID: "response", usage: nil),
        ]
        let client = ScriptedMiMoResponder(scripts: [badAnswer, badAnswer, badAnswer])
        let credential = try MiMoCredential(apiKey: "sk-1234567890-no-retry")
        let harness = InsightAgentHarness(
            client: client,
            maximumToolRoundTrips: 4,
            maximumCandidateRepairs: 2
        )
        var fallbackCount = 0

        let result = try await harness.run(
            model: MiMoCredential.textModel,
            instructions: "回答用户实际问题。",
            messages: [MiMoInputMessage(role: .user, text: "S2-U033什么时候出生的")],
            tools: [],
            credential: credential,
            execute: { _ in
                XCTFail("这个脚本不应执行工具。")
                return .init(output: "", succeeded: false)
            },
            reviewCandidate: { _, _, _ in
                .retry("没有本地权威证据支持具体羊只的出生日期。")
            },
            resolveRejectedCandidate: { _, issue, _, _ in
                fallbackCount += 1
                return InsightGroundedFallbackRenderer.render(
                    question: "S2-U033什么时候出生的",
                    queries: [],
                    calculationEvidence: [],
                    issue: issue
                )
            }
        )

        XCTAssertEqual(client.capturedRequests().count, 3)
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertTrue(result.text.contains("没有取得足以支持结论的本地牧场证据"))
        XCTAssertTrue(result.text.contains("出生日期"))
        XCTAssertFalse(result.text.contains("重试"))
    }

    func testNativeHarnessAutomaticallyRecoversTransientTransportFailure() async throws {
        let client = FlakyMiMoResponder(
            failures: [.networkUnavailable],
            events: [
                .responseStarted(id: "recovered-response"),
                .textDelta("已经在内部恢复并完成回答。"),
                .completed(responseID: "recovered-response", usage: nil),
            ]
        )
        let credential = try MiMoCredential(apiKey: "sk-1234567890-transport-recovery")
        let harness = InsightAgentHarness(
            client: client,
            maximumToolRoundTrips: 1,
            maximumTransportRecoveries: 1
        )

        let result = try await harness.run(
            model: MiMoCredential.textModel,
            instructions: "回答用户实际问题。",
            messages: [MiMoInputMessage(role: .user, text: "说明当前情况")],
            tools: [],
            credential: credential,
            execute: { _ in
                XCTFail("这个脚本不应执行工具。")
                return .init(output: "", succeeded: false)
            },
            reviewCandidate: { _, _, _ in .accept },
            resolveRejectedCandidate: { _, _, _, _ in
                XCTFail("恢复成功后不应进入兜底。")
                return ""
            }
        )

        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(result.text, "已经在内部恢复并完成回答。")
        XCTAssertFalse(result.text.contains("重试"))
    }

    func testSemanticReviewerCannotAcceptFarmSpecificClaimWithoutSuccessfulEvidence() async throws {
        let reviewCall = InsightFunctionCall(
            callID: "review-1",
            name: "review_grounded_farm_answer",
            argumentsJSON: #"{"verdict":"accept","claim_scope":"farm_specific","evidence_sufficient":true,"issue":"","corrective_instruction":""}"#
        )
        let client = ScriptedMiMoResponder(scripts: [[
            .responseStarted(id: "review-response"),
            .functionCall(reviewCall),
            .completed(responseID: "review-response", usage: nil),
        ]])
        let credential = try MiMoCredential(apiKey: "sk-1234567890-reviewer")

        let review = try await InsightGroundedAnswerReviewer.review(
            question: "当前用户消息：S2-U033什么时候出生的",
            candidate: "S2-U033 不在牧场记录中。",
            exchanges: [],
            successfulToolNames: [],
            model: MiMoCredential.textModel,
            credential: credential,
            client: client
        )

        XCTAssertFalse(review.isAccepted)
        XCTAssertEqual(review.claimScope, "farm_specific")
        XCTAssertTrue(review.evidenceSufficient)
        XCTAssertTrue(review.issue.contains("没有足以支持"))
    }

    func testFarmQueryMonthGroupingUsesLocalFarmDateInsteadOfUTCDate() throws {
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2025-12-31T16:00:00Z")
        )
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        XCTAssertEqual(
            InsightFarmQueryEngine.day(instant, timeZone: shanghai),
            "2026-01-01"
        )
        XCTAssertEqual(
            InsightFarmQueryEngine.month(instant, timeZone: shanghai),
            "2026-01"
        )
    }

    func testGroundedFallbackUsesVerifiedCalculationWithoutAskingTheUserToRetry() {
        let calculation = #"{"evidence_kind":"farm_calculation","result_unit":"kg/day","observation_count":2,"is_complete":true,"formula":"(end_value - start_value) / farm_calendar_days(start_at, end_at)","groups":[{"key":"2026-07-11","value":0.25,"sample_count":2,"sheep_count":2}]}"#

        let answer = InsightGroundedFallbackRenderer.render(
            question: "大棚十二舍日增重多少",
            queries: [],
            calculationEvidence: [calculation],
            issue: "最终答案没有通过复核，请重试。"
        )

        XCTAssertTrue(answer.contains("0.25 kg/day"))
        XCTAssertTrue(answer.contains("样本 2"))
        XCTAssertTrue(answer.contains("数据完整性：完整"))
        XCTAssertFalse(answer.contains("重试"))

        for error in [
            MiMoClientError.invalidResponse,
            MiMoClientError.incomplete(reason: "max_output_tokens"),
            MiMoClientError.server(status: 500, message: "服务异常，请重试。"),
        ] {
            XCTAssertFalse(
                InsightConversationController.generationFailureDescription(error).contains("重试")
            )
            XCTAssertFalse(error.localizedDescription.contains("重试"))
            XCTAssertFalse(error.localizedDescription.contains("再试"))
        }

        for error in [
            InsightMediaError.audioRecordingFailed,
            InsightMediaError.audioTooLarge,
            InsightMediaError.audioStorageFailed,
        ] {
            XCTAssertFalse(error.localizedDescription.contains("重试"))
            XCTAssertFalse(error.localizedDescription.contains("再试"))
        }
    }

    func testGroundedFallbackPreservesEveryCompleteRateAnalysisDimension() {
        let calculation = #"{"evidence_kind":"farm_calculation","result_unit":"kg/day","observation_count":4,"is_complete":false,"formula":"(end_value - start_value) / farm_calendar_days(start_at, end_at)","source_description":"WeightRecord 常规称重","time_zone":"Asia/Shanghai","canonical_arguments":{"pen_name":"大棚十二舍"},"batch_attribution_counts":{"assigned":2,"cross_batch":1,"unassigned":1},"relevant_profile_count":5,"analyzed_profile_count":4,"excluded_insufficient_sample_profiles":1,"excluded_non_continuous_pen_intervals":2,"excluded_non_positive_day_intervals":0,"groups":[{"key":"all","value":0.25,"average":0.25,"minimum":0.1,"maximum":0.4,"sample_count":4,"sheep_count":4}],"analysis_contract":{"kind":"multidimensional_adjacent_rate_analysis","required_answer_sections":["总体结论","称重区间","生产批次","生命周期","数据完整性"]},"analysis_sections":[{"title":"总体口径","dimension":"none","is_complete":true,"groups":[{"key":"all","value":0.25,"average":0.25,"minimum":0.1,"maximum":0.4,"median":0.24,"sample_count":4,"sheep_count":4,"positive_count":3,"zero_count":0,"negative_count":1,"total_weight_change":10.555,"total_observation_days":40,"first_interval_start":"2026-07-01T00:00:00.000Z","last_interval_end":"2026-07-11T00:00:00.000Z","elapsed_days_average":10,"elapsed_days_minimum":10,"elapsed_days_maximum":10,"sheep_weighted_daily_rate":0.25,"pooled_daily_rate":0.263875}]},{"title":"不同称重区间","dimension":"weighing_interval","is_complete":true,"groups":[{"key":"2026-07-01 → 2026-07-11（10天）","value":0.25,"average":0.25,"minimum":0.1,"maximum":0.4,"sample_count":4,"sheep_count":4}]},{"title":"生产批次","dimension":"production_batch","is_complete":true,"groups":[{"key":"育肥一批","value":0.3,"average":0.3,"minimum":0.3,"maximum":0.3,"sample_count":2,"sheep_count":2},{"key":"跨生产批次区间","value":0.4,"average":0.4,"minimum":0.4,"maximum":0.4,"sample_count":1,"sheep_count":1}]},{"title":"生命周期","dimension":"lifecycle_status","is_complete":true,"groups":[{"key":"当前在群","value":0.3,"average":0.3,"minimum":0.2,"maximum":0.4,"sample_count":2,"sheep_count":2},{"key":"出售","value":0.3,"average":0.3,"minimum":0.3,"maximum":0.3,"sample_count":1,"sheep_count":1},{"key":"死亡","value":0.1,"average":0.1,"minimum":0.1,"maximum":0.1,"sample_count":1,"sheep_count":1}]}]}"#

        let answer = InsightGroundedFallbackRenderer.render(
            question: "大棚十二舍日增重多少",
            queries: [],
            calculationEvidence: [calculation],
            issue: "候选答案只给了一个平均数，请重试。"
        )

        for heading in ["总体结论", "称重区间", "生产批次", "生命周期", "数据完整性"] {
            XCTAssertTrue(answer.contains("### \(heading)"), "missing heading: \(heading)")
        }
        XCTAssertTrue(answer.contains("## 大棚十二舍日增重完整分析"))
        XCTAssertTrue(answer.contains("| 区间等权平均 | 0.250 kg/天 |"))
        XCTAssertTrue(answer.contains("| 羊只等权平均 | 0.250 kg/天 |"))
        XCTAssertTrue(answer.contains("| 总增重 ÷ 总观察天数 | 0.264 kg/天 |"))
        XCTAssertTrue(answer.contains("| 区间总增重 | 10.56 kg |"))
        XCTAssertTrue(answer.contains("WeightRecord 常规称重"))
        XCTAssertTrue(answer.contains("育肥一批"))
        XCTAssertTrue(answer.contains("跨生产批次区间"))
        XCTAssertTrue(answer.contains("当前在群"))
        XCTAssertTrue(answer.contains("出售"))
        XCTAssertTrue(answer.contains("死亡"))
        XCTAssertTrue(answer.contains("称重点不足"))
        XCTAssertTrue(answer.contains("完整性：受限"))
        XCTAssertFalse(answer.contains("重试"))
    }

    func testVerifiedCompleteAnalysisAlwaysComposesTablesFromCalculationEvidence() {
        let complete = #"{"evidence_kind":"farm_calculation","result_unit":"kg/day","observation_count":181,"is_complete":false,"canonical_arguments":{"pen_name":"大棚十二舍"},"relevant_profile_count":86,"analyzed_profile_count":85,"excluded_insufficient_sample_profiles":1,"excluded_non_continuous_pen_intervals":0,"excluded_non_positive_day_intervals":0,"groups":[{"key":"all","value":0.33,"sample_count":181,"sheep_count":85}],"analysis_contract":{"kind":"multidimensional_adjacent_rate_analysis"},"analysis_sections":[{"title":"总体口径","dimension":"none","is_complete":true,"groups":[{"key":"all","value":0.33,"median":0.32,"minimum":0.1,"maximum":0.5,"sample_count":181,"sheep_count":85,"positive_count":181,"zero_count":0,"negative_count":0,"sheep_weighted_daily_rate":0.34,"pooled_daily_rate":0.35}]},{"title":"不同称重区间","dimension":"weighing_interval","is_complete":true,"groups":[{"key":"2026-06-01 → 2026-07-01（30天）","value":0.33,"sample_count":181,"sheep_count":85}]},{"title":"生产批次","dimension":"production_batch","is_complete":true,"groups":[{"key":"育肥批次","value":0.33,"sample_count":181,"sheep_count":85}]},{"title":"生命周期","dimension":"lifecycle_status","is_complete":true,"groups":[{"key":"出售","value":0.3288059857,"sample_count":180,"sheep_count":85},{"key":"死亡","value":0.297,"sample_count":1,"sheep_count":1}]}]}"#
        let focused = #"{"evidence_kind":"farm_calculation","result_unit":"kg/day","observation_count":1,"is_complete":true,"groups":[{"key":"all","value":99,"sample_count":1,"sheep_count":1}]}"#

        let answer = InsightGroundedFallbackRenderer.verifiedCompleteAnalysis(
            calculationEvidence: [complete]
        )

        XCTAssertNotNil(answer)
        XCTAssertTrue(answer?.contains("| 出售 | 180 | 85 | 0.329 kg/天 |") == true)
        XCTAssertFalse(answer?.contains("179") == true)
        XCTAssertNil(InsightGroundedFallbackRenderer.verifiedCompleteAnalysis(
            calculationEvidence: [focused]
        ))
    }

    func testGroundedFallbackKeepsCompleteStructureWhenNoIntervalIsAvailable() {
        let calculation = #"{"evidence_kind":"farm_calculation","result_unit":"kg/day","observation_count":0,"is_complete":false,"formula":"(end_value - start_value) / farm_calendar_days(start_at, end_at)","relevant_profile_count":3,"analyzed_profile_count":0,"excluded_insufficient_sample_profiles":3,"excluded_non_continuous_pen_intervals":0,"excluded_non_positive_day_intervals":0,"groups":[],"analysis_contract":{"kind":"multidimensional_adjacent_rate_analysis"},"analysis_sections":[{"title":"总体口径","groups":[],"is_complete":true},{"title":"不同称重区间","groups":[],"is_complete":true},{"title":"生产批次","groups":[],"is_complete":true},{"title":"生命周期","groups":[],"is_complete":true}]}"#

        let answer = InsightGroundedFallbackRenderer.render(
            question: "某圈舍日增重多少",
            queries: [],
            calculationEvidence: [calculation],
            issue: "候选答案不完整"
        )

        for heading in ["总体结论", "称重区间", "生产批次", "生命周期", "数据完整性"] {
            XCTAssertTrue(answer.contains("### \(heading)"), "missing heading: \(heading)")
        }
        XCTAssertTrue(answer.contains("没有符合该维度条件的有效相邻称重区间"))
        XCTAssertTrue(answer.contains("称重点不足 3 只"))
    }

    func testIPhoneAirCurrentHerdRegressionUsesTheSameCountAcrossAIHomeAndExport() async throws {
        let container = try AppSchema.makeContainer(
            name: "insight-iphone-air-current-herd-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let farm = FarmRecord(id: farmID, ownerAccountID: UUID(), name: "星露谷牧场")
        farm.timeZoneIdentifier = "Asia/Shanghai"
        let pen = PenRecord(farmID: farmID, name: "一号圈")
        let enteredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var allSheep: [SheepRecord] = []
        allSheep.reserveCapacity(945)

        context.insert(farm)
        context.insert(pen)
        for index in 0..<380 {
            let sheep = SheepRecord(
                farmID: farmID,
                earTag: String(format: "ACTIVE-%03d", index),
                breed: "湖羊",
                sex: index.isMultiple(of: 2) ? .ewe : .ram,
                penID: pen.id,
                enteredAt: enteredAt
            )
            allSheep.append(sheep)
            context.insert(sheep)
        }
        for index in 0..<258 {
            let sheep = SheepRecord(
                farmID: farmID,
                earTag: String(format: "LEGACY-REMOVED-%03d", index),
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: enteredAt
            )
            sheep.statusRawValue = SheepStatus.removed.rawValue
            sheep.legacyStatusSnapshotIsAuthoritative = true
            allSheep.append(sheep)
            context.insert(sheep)
        }
        for index in 0..<307 {
            let sheep = SheepRecord(
                farmID: farmID,
                earTag: String(format: "HISTORICAL-%03d", index),
                isHistoricalArchive: true,
                breed: "未知",
                sex: .unknown,
                penID: nil,
                enteredAt: enteredAt
            )
            allSheep.append(sheep)
            context.insert(sheep)
        }
        try context.save()

        var arguments = farmQueryArguments(subject: "sheep")
        arguments["query_kind"] = FarmDataQuerySkill.QueryKind.currentHerd.rawValue
        arguments["metric"] = "count"
        let output = try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: now
        )
        let grounded = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: output))
        XCTAssertEqual(grounded.queryKind, FarmDataQuerySkill.QueryKind.currentHerd.rawValue)
        XCTAssertEqual(grounded.totalMatchingCount, 380)
        XCTAssertEqual(grounded.contractVersion, FarmFactContract.version)
        XCTAssertEqual(grounded.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(grounded.unknownStateCount, 0)
        XCTAssertEqual(grounded.projectionMismatchCount, 0)
        XCTAssertEqual(
            Set(grounded.stateBasis),
            Set([
                FarmFactContract.SheepStateBasis.currentEventProjection.rawValue,
                FarmFactContract.SheepStateBasis.currentLegacySnapshot.rawValue,
                FarmFactContract.SheepStateBasis.currentHistoricalArchive.rawValue,
            ])
        )

        let canonical = try XCTUnwrap(InsightFarmQueryEngine.canonicalArguments(in: output))
        XCTAssertEqual(canonical["query_kind"] as? String, FarmDataQuerySkill.QueryKind.currentHerd.rawValue)
        XCTAssertEqual(canonical["status"] as? String, SheepStatus.active.rawValue)
        XCTAssertEqual(canonical["as_of"] as? String, "")
        let replayOutput = try InsightFarmQueryEngine().execute(
            arguments: canonical,
            farmID: farmID,
            context: context,
            now: now
        )
        let replay = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: replayOutput))
        XCTAssertEqual(replay.totalMatchingCount, grounded.totalMatchingCount)
        XCTAssertEqual(replay.canonicalArgumentsJSON, grounded.canonicalArgumentsJSON)
        XCTAssertEqual(replay.markdown, grounded.markdown)

        let home = try await FarmHomeSnapshotActor(container: container).load(
            farmID: farmID,
            now: now
        )
        XCTAssertEqual(home.activeSheepCount, 380)

        let csvData = InHerdSheepExport.csvData(farmID: farmID, sheep: allSheep, pens: [pen])
        let csv = String(decoding: csvData.dropFirst(3), as: UTF8.self)
        XCTAssertEqual(csv.components(separatedBy: "\"ACTIVE-").count - 1, 380)
        XCTAssertTrue(csv.contains("ACTIVE-000"))
        XCTAssertFalse(csv.contains("LEGACY-REMOVED-000"))
        XCTAssertFalse(csv.contains("HISTORICAL-000"))
    }

    func testCurrentHerdRefusesAStaleProjectionInsteadOfReturningAnApproximation() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-current-herd-stale-projection-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let enteredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let removalAt = enteredAt.addingTimeInterval(86_400)
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "STALE-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: enteredAt
        )
        context.insert(sheep)
        context.insert(RemovalRecord(
            farmID: farmID,
            sheepID: sheep.id,
            kind: .sold,
            reason: "出售",
            occurredAt: removalAt
        ))
        var arguments = farmQueryArguments(subject: "sheep")
        arguments["query_kind"] = FarmDataQuerySkill.QueryKind.currentHerd.rawValue
        arguments["metric"] = "count"

        XCTAssertThrowsError(try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: removalAt.addingTimeInterval(86_400)
        )) { error in
            guard let toolError = error as? InsightToolError else {
                return XCTFail("应返回牧场事实不可用错误，实际为 \(error)")
            }
            guard case .farmFactsUnavailable(let message) = toolError else {
                return XCTFail("应停止返回近似数字，实际为 \(toolError)")
            }
            XCTAssertTrue(message.contains("停止返回"))
        }
    }

    func testHistoricalStatusQueryRefusesUndatedLegacyRemoval() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-historical-unknown-state-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "UNDATED-REMOVED",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        sheep.statusRawValue = SheepStatus.removed.rawValue
        sheep.legacyStatusSnapshotIsAuthoritative = true
        context.insert(sheep)
        var arguments = farmQueryArguments(subject: "sheep", status: SheepStatus.active.rawValue)
        arguments["as_of"] = "2025-01-01T00:00:00Z"
        arguments["metric"] = "count"

        XCTAssertThrowsError(try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )) { error in
            guard let toolError = error as? InsightToolError else {
                return XCTFail("应返回牧场事实不可用错误，实际为 \(error)")
            }
            guard case .farmFactsUnavailable(let message) = toolError else {
                return XCTFail("历史未知状态不应被默认为在场，实际为 \(toolError)")
            }
            XCTAssertTrue(message.contains("缺少可证明"))
        }
    }

    func testFarmDataQuerySkillRejectsFiltersThatTheSelectedMetricCannotApply() {
        var arguments = farmQueryArguments(subject: "feeding", breed: "湖羊")
        arguments["query_kind"] = FarmDataQuerySkill.QueryKind.feedingRecords.rawValue

        XCTAssertThrowsError(try FarmDataQuerySkill.normalize(arguments: arguments)) { error in
            XCTAssertTrue(error.localizedDescription.contains("breed"))
        }

        var historicalCurrentHerd = farmQueryArguments(subject: "sheep")
        historicalCurrentHerd["query_kind"] = FarmDataQuerySkill.QueryKind.currentHerd.rawValue
        historicalCurrentHerd["as_of"] = "2025-12-31T23:59:59Z"
        XCTAssertThrowsError(try FarmDataQuerySkill.normalize(arguments: historicalCurrentHerd)) { error in
            XCTAssertTrue(error.localizedDescription.contains("as_of"))
        }

        var contradictoryCurrentHerd = farmQueryArguments(
            subject: "sheep",
            status: SheepStatus.removed.rawValue
        )
        contradictoryCurrentHerd["query_kind"] = FarmDataQuerySkill.QueryKind.currentHerd.rawValue
        XCTAssertThrowsError(try FarmDataQuerySkill.normalize(arguments: contradictoryCurrentHerd)) { error in
            XCTAssertTrue(error.localizedDescription.contains("status"))
        }
    }

    func testFarmQueryReadsTheFarmTimeZoneBeforeGroupingRecords() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-farm-time-zone-query-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let farm = FarmRecord(id: farmID, ownerAccountID: UUID(), name: "上海测试场")
        farm.timeZoneIdentifier = "Asia/Shanghai"
        let ewe = SheepRecord(
            farmID: farmID,
            earTag: "TZ-EWE",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-12-31T16:00:00Z"))
        context.insert(farm)
        context.insert(ewe)
        context.insert(ReproductionRecord(
            farmID: farmID,
            eweID: ewe.id,
            kind: .lambing,
            occurredAt: instant,
            lambCount: 2
        ))
        var arguments = farmQueryArguments(subject: "reproduction")
        arguments["query_kind"] = FarmDataQuerySkill.QueryKind.bornLambs.rawValue
        arguments["date_from"] = "2025-12-01T00:00:00Z"
        arguments["date_to"] = "2026-01-31T23:59:59Z"
        arguments["group_by"] = "month"
        arguments["metric"] = "sum"

        let output = try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let grounded = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: output))
        XCTAssertEqual(grounded.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertTrue(grounded.markdown.contains("| 2026-01 | 2 |"))
        XCTAssertFalse(grounded.markdown.contains("| 2025-12 | 2 |"))
    }

    func testFarmQueryRefusesMissingFarmContextInsteadOfUsingTheDeviceTimeZone() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-missing-farm-time-zone-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        var arguments = farmQueryArguments(subject: "sheep")
        arguments["query_kind"] = FarmDataQuerySkill.QueryKind.currentHerd.rawValue
        arguments["metric"] = "count"

        XCTAssertThrowsError(try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: UUID(),
            context: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("牧场记录不存在"))
        }
    }

    func testResponseGuardLeavesNaturalLanguageGroundingToTheSemanticReviewer() {
        XCTAssertNil(InsightAssistantResponseGuard.issue(
            for: "S2-U033 目前不在牧场记录中。",
            createdDraftCount: 0,
            earTagEvidence: nil
        ))
        XCTAssertEqual(
            InsightAssistantResponseGuard.issue(
                for: "操作卡片已生成，请确认。",
                createdDraftCount: 0,
                earTagEvidence: nil
            ),
            .actionClaimWithoutDraft
        )
    }

    func testFarmQueryCombinesFiltersAndProducesDeterministicEvidence() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-grounded-query-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let pen = PenRecord(farmID: farmID, name: "一号圈")
        context.insert(pen)
        context.insert(SheepRecord(
            farmID: farmID,
            earTag: "E-001",
            breed: "杜泊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        context.insert(SheepRecord(
            farmID: farmID,
            earTag: "R-002",
            breed: "萨福克",
            sex: .ram,
            penID: pen.id,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let output = try InsightFarmQueryEngine().execute(
            arguments: farmQueryArguments(
                subject: "sheep",
                sex: "ewe",
                status: "active",
                breed: "杜泊",
                penName: "一号圈"
            ),
            farmID: farmID,
            context: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let grounded = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: output))
        XCTAssertEqual(grounded.rowCount, 1)
        XCTAssertEqual(grounded.totalMatchingCount, 1)
        XCTAssertTrue(grounded.isComplete)
        XCTAssertTrue(grounded.markdown.contains("E-001"))
        XCTAssertTrue(grounded.markdown.contains("杜泊"))
        XCTAssertFalse(grounded.markdown.contains("R-002"))
        XCTAssertTrue(grounded.markdown.contains("当前设备的 App 本地数据库直接计算"))
        XCTAssertTrue(grounded.markdown.contains("不代表云端同步已经完成"))
    }

    func testFarmQueryUsesHistoricalPenAtRequestedAsOfDate() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-historical-query-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let firstPen = PenRecord(farmID: farmID, name: "原圈")
        let secondPen = PenRecord(farmID: farmID, name: "新圈")
        let enteredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "H-001",
            breed: "湖羊",
            sex: .ewe,
            penID: firstPen.id,
            enteredAt: enteredAt
        )
        context.insert(firstPen)
        context.insert(secondPen)
        context.insert(sheep)
        context.insert(TransferRecord(
            farmID: farmID,
            sheepID: sheep.id,
            fromPenID: firstPen.id,
            toPenID: secondPen.id,
            occurredAt: enteredAt.addingTimeInterval(20 * 86_400)
        ))
        let asOf = enteredAt.addingTimeInterval(10 * 86_400)
        var arguments = farmQueryArguments(subject: "sheep", penName: "原圈")
        arguments["as_of"] = ISO8601DateFormatter().string(from: asOf)

        let output = try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: enteredAt.addingTimeInterval(30 * 86_400)
        )
        let grounded = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: output))
        XCTAssertEqual(grounded.totalMatchingCount, 1)
        XCTAssertTrue(grounded.markdown.contains("原圈"))
        XCTAssertFalse(grounded.markdown.contains("| 新圈 |"))
    }

    func testSheepBirthDateQueryActuallyFiltersAndGroupsByBirthDate() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-birth-date-query-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let january = Date(timeIntervalSince1970: 1_768_435_200) // 2026-01-15 UTC
        let priorYear = Date(timeIntervalSince1970: 1_736_899_200) // 2025-01-15 UTC
        context.insert(SheepRecord(
            farmID: farmID,
            earTag: "B-2026",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: priorYear,
            birthAt: january
        ))
        context.insert(SheepRecord(
            farmID: farmID,
            earTag: "B-2025",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: priorYear,
            birthAt: priorYear
        ))
        var arguments = farmQueryArguments(subject: "sheep")
        arguments["date_field"] = "birth_at"
        arguments["date_from"] = "2026-01-01T00:00:00Z"
        arguments["date_to"] = "2026-12-31T23:59:59Z"
        arguments["group_by"] = "month"
        arguments["metric"] = "count"

        let output = try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let grounded = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: output))
        XCTAssertEqual(grounded.totalMatchingCount, 1)
        XCTAssertTrue(grounded.markdown.contains("羊只档案出生日期"))
        XCTAssertTrue(grounded.markdown.contains("| 2026-01 | 1 |"))
        XCTAssertFalse(grounded.markdown.contains("B-2025"))
    }

    func testSheepDateRangeWithoutExplicitDateFieldIsRejected() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-date-field-required-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        var arguments = farmQueryArguments(subject: "sheep")
        arguments["date_from"] = "2026-01-01T00:00:00Z"

        XCTAssertThrowsError(try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    func testBornLambCountUsesLambingEventsAndSumsLambCount() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-born-lamb-count-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let ewe = SheepRecord(
            farmID: farmID,
            earTag: "EWE-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        context.insert(ewe)
        context.insert(ReproductionRecord(
            farmID: farmID,
            eweID: ewe.id,
            kind: .lambing,
            occurredAt: Date(timeIntervalSince1970: 1_768_435_200),
            lambCount: 2
        ))
        context.insert(ReproductionRecord(
            farmID: farmID,
            eweID: ewe.id,
            kind: .lambing,
            occurredAt: Date(timeIntervalSince1970: 1_771_113_600),
            lambCount: 1
        ))
        var arguments = farmQueryArguments(subject: "reproduction")
        arguments["date_from"] = "2026-01-01T00:00:00Z"
        arguments["date_to"] = "2026-12-31T23:59:59Z"
        arguments["kind"] = ReproductionRecordKind.lambing.rawValue
        arguments["group_by"] = "month"
        arguments["metric"] = "sum"

        let output = try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let grounded = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: output))
        XCTAssertEqual(grounded.totalMatchingCount, 2)
        XCTAssertTrue(grounded.markdown.contains("| 2026-01 | 2 |"))
        XCTAssertTrue(grounded.markdown.contains("| 2026-02 | 1 |"))
    }

    func testBornLambLifecycleKeepsEventAndProfileCountsSeparate() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-born-lamb-lifecycle-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        insertFarm(farmID, into: context)
        let formatter = ISO8601DateFormatter()
        let enteredAt = try XCTUnwrap(formatter.date(from: "2025-12-01T00:00:00Z"))
        let birthAt = try XCTUnwrap(formatter.date(from: "2026-01-15T00:00:00Z"))
        let asOf = try XCTUnwrap(formatter.date(from: "2026-08-27T00:00:00Z"))
        let ewe = SheepRecord(
            farmID: farmID,
            earTag: "EWE-LIFECYCLE",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: enteredAt
        )
        let activeLamb = SheepRecord(
            farmID: farmID,
            earTag: "LAMB-ACTIVE",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: birthAt,
            birthAt: birthAt
        )
        let soldLamb = SheepRecord(
            farmID: farmID,
            earTag: "LAMB-SOLD",
            breed: "湖羊",
            sex: .ram,
            penID: nil,
            enteredAt: birthAt,
            birthAt: birthAt
        )
        context.insert(ewe)
        context.insert(activeLamb)
        context.insert(soldLamb)
        context.insert(ReproductionRecord(
            farmID: farmID,
            eweID: ewe.id,
            kind: .lambing,
            occurredAt: birthAt,
            lambCount: 3
        ))
        context.insert(RemovalRecord(
            farmID: farmID,
            sheepID: soldLamb.id,
            kind: .sold,
            reason: "出售",
            occurredAt: try XCTUnwrap(formatter.date(from: "2026-06-01T00:00:00Z"))
        ))
        soldLamb.statusRawValue = SheepStatus.removed.rawValue
        soldLamb.currentPenID = nil
        soldLamb.removedAt = try XCTUnwrap(formatter.date(from: "2026-06-01T00:00:00Z"))
        var arguments = farmQueryArguments(subject: "sheep")
        arguments["query_kind"] = FarmDataQuerySkill.QueryKind.bornLambLifecycle.rawValue
        arguments["date_from"] = "2026-01-01T00:00:00Z"
        arguments["date_to"] = "2026-08-27T23:59:59Z"

        let output = try InsightFarmQueryEngine().execute(
            arguments: arguments,
            farmID: farmID,
            context: context,
            now: asOf
        )
        let grounded = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: output))
        XCTAssertEqual(grounded.queryKind, FarmDataQuerySkill.QueryKind.bornLambLifecycle.rawValue)
        XCTAssertEqual(grounded.totalMatchingCount, 3)
        XCTAssertTrue(grounded.markdown.contains("| 2026-01 | 3 | 2 | 1 | 0 | 1 | 0 | 0 | 0 |"))
        XCTAssertTrue(grounded.markdown.contains("两者可能无法逐只对应"))
    }

    private func farmQueryArguments(
        subject: String,
        sex: String = "",
        status: String = "",
        breed: String = "",
        penName: String = ""
    ) -> [String: Any] {
        [
            "query_kind": queryKind(for: subject),
            "subject": subject,
            "date_field": subject == "sheep" || subject == "inventory" ? "none" : "occurred_at",
            "date_from": "",
            "date_to": "",
            "as_of": "",
            "ear_tag": "",
            "sex": sex,
            "status": status,
            "breed": breed,
            "pen_name": penName,
            "kind": "",
            "item_name": "",
            "group_by": "none",
            "metric": "records",
            "minimum_value": "",
            "maximum_value": "",
            "relations": [],
            "limit": 100,
        ]
    }

    private func farmCalculationArguments(
        penName: String = "",
        asOf: String = ""
    ) -> [String: Any] {
        [
            "source": "weight_samples",
            "sample_policy": "recorded_only",
            "cohort": "current_in_herd",
            "pen_membership": "at_cutoff",
            "pen_name": penName,
            "ear_tag": "",
            "breed": "",
            "sex": "",
            "date_from": "",
            "date_to": "",
            "as_of": asOf,
            "partition_by": "sheep",
            "window": "none",
            "transform": "value",
            "analysis_scope": "focused",
            "group_by": "none",
            "reduce": "average",
            "selection": "all",
            "limit": 100,
        ]
    }

    private func calculationObject(_ output: String) throws -> [String: Any] {
        let data = try XCTUnwrap(output.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func sectionGroup(
        _ dimension: String,
        key: String,
        in sections: [[String: Any]]
    ) throws -> [String: Any] {
        let section = try XCTUnwrap(sections.first {
            $0["dimension"] as? String == dimension
        })
        let groups = try XCTUnwrap(section["groups"] as? [[String: Any]])
        return try XCTUnwrap(groups.first { $0["key"] as? String == key })
    }

    @discardableResult
    private func insertFarm(
        _ farmID: UUID,
        into context: ModelContext,
        timeZoneIdentifier: String = "Asia/Shanghai"
    ) -> FarmRecord {
        let farm = FarmRecord(id: farmID, ownerAccountID: UUID(), name: "查询测试牧场")
        farm.timeZoneIdentifier = timeZoneIdentifier
        context.insert(farm)
        return farm
    }

    private func queryKind(for subject: String) -> String {
        switch subject {
        case "sheep": FarmDataQuerySkill.QueryKind.sheepProfiles.rawValue
        case "weights": FarmDataQuerySkill.QueryKind.weightRecords.rawValue
        case "reproduction": FarmDataQuerySkill.QueryKind.reproductionRecords.rawValue
        case "health": FarmDataQuerySkill.QueryKind.healthRecords.rawValue
        case "feeding": FarmDataQuerySkill.QueryKind.feedingRecords.rawValue
        case "inventory": FarmDataQuerySkill.QueryKind.inventory.rawValue
        default: FarmDataQuerySkill.QueryKind.sheepProfiles.rawValue
        }
    }

    func testAssistantIsAvailableToEveryFarmRoleWhileRestrictedWritesStayDenied() throws {
        let account = AccountProfile(
            appleUserIdentifier: "assistant-access-\(UUID().uuidString)",
            displayName: "测试账号"
        )

        for role in FarmRole.allCases {
            let farm = FarmRecord(
                ownerAccountID: account.effectiveAccountID,
                name: "\(role.displayName)牧场",
                role: role
            )
            let controller = InsightConversationController(account: account, farm: farm)
            XCTAssertTrue(controller.canUseAssistant, "\(role.displayName)应可使用 AI 助手")
        }

        let container = try AppSchema.makeContainer(
            name: "insight-role-write-gate-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let registry = InsightToolRegistry()
        let command = FarmCommand.addIngredient(
            name: "玉米",
            unit: "kg",
            dryMatterText: "0.88"
        )
        let payloadText = String(
            decoding: try FarmCommandCloudPayloadEncoder.encode(command),
            as: UTF8.self
        )
        let callData = try JSONSerialization.data(withJSONObject: [
            "operation_kind": DomainOperationKind.addIngredient.rawValue,
            "payload_json": payloadText,
        ])
        let worker = InsightAgentContext(
            accountID: account.effectiveAccountID,
            farmID: farmID,
            role: .worker,
            originDeviceID: UUID(),
            conversationID: UUID()
        )

        XCTAssertThrowsError(try registry.execute(
            .init(
                callID: "restricted-write",
                name: "draft_farm_command",
                argumentsJSON: String(decoding: callData, as: UTF8.self)
            ),
            agent: worker,
            context: context
        )) { error in
            guard let insightError = error as? InsightToolError,
                  case .permissionDenied = insightError else {
                return XCTFail("Expected permissionDenied, got \(error)")
            }
        }
    }

    func testCredentialPrefixSelectsOfficialEndpointAndMasksSecret() throws {
        let standard = try MiMoCredential(apiKey: "sk-1234567890-secret")
        let tokenPlan = try MiMoCredential(apiKey: "tp-1234567890-secret")

        XCTAssertEqual(standard.kind, .payAsYouGo)
        XCTAssertEqual(standard.responsesURL.absoluteString, "https://api.xiaomimimo.com/v1/responses")
        XCTAssertEqual(standard.chatCompletionsURL.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(tokenPlan.kind, .tokenPlan)
        XCTAssertEqual(tokenPlan.responsesURL.absoluteString, "https://token-plan-cn.xiaomimimo.com/v1/responses")
        XCTAssertFalse(standard.maskedValue.contains("1234567890"))
        XCTAssertEqual(InsightInputOrigin.text.model, "mimo-v2.5-pro")
        XCTAssertEqual(InsightInputOrigin.image.model, "mimo-v2.5")
        XCTAssertEqual(InsightInputOrigin.voiceAudio.model, "mimo-v2.5")
    }

    func testCredentialVaultPersistsAndRemovesCredentialForAccount() async throws {
        let accountID = UUID()
        try await MiMoCredentialVault.shared.remove(for: accountID)

        let saved = try await MiMoCredentialVault.shared.save(
            apiKey: "sk-1234567890-persistence",
            for: accountID
        )
        let loaded = try await MiMoCredentialVault.shared.credential(for: accountID)

        XCTAssertEqual(loaded, saved)

        try await MiMoCredentialVault.shared.remove(for: accountID)
        let removed = try await MiMoCredentialVault.shared.credential(for: accountID)
        XCTAssertNil(removed)

        let suffix = accountID.uuidString.lowercased()
        try SecureAccountStore.remove(account: "insights.mimo-api-key-deleted-at.\(suffix)")
        try SecureAccountStore.remove(account: "insights.mimo-api-key-updated-at.\(suffix)")
    }

    func testResponsesSSEParsesTextToolAndUsageWithoutReasoningText() throws {
        let delta = try XCTUnwrap(MiMoSSEParser.parse(
            line: #"data: {"type":"response.output_text.delta","delta":"当前在场 18 只。"}"#
        ))
        XCTAssertEqual(delta, .textDelta("当前在场 18 只。"))

        let tool = try XCTUnwrap(MiMoSSEParser.parse(
            line: #"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"analyze_farm","arguments":"{\"focus\":\"population\",\"year\":\"\"}"}}"#
        ))
        XCTAssertEqual(
            tool,
            .functionCall(.init(
                callID: "call_1",
                name: "analyze_farm",
                argumentsJSON: #"{"focus":"population","year":""}"#
            ))
        )

        let completed = try XCTUnwrap(MiMoSSEParser.parse(
            line: #"data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":12,"output_tokens":8,"total_tokens":20}}}"#
        ))
        XCTAssertEqual(
            completed,
            .completed(
                responseID: "resp_1",
                usage: .init(inputTokens: 12, outputTokens: 8, totalTokens: 20)
            )
        )
    }

    func testResponsesSSEPreservesIncompleteReason() throws {
        XCTAssertThrowsError(
            try MiMoSSEParser.parse(
                line: #"data: {"type":"response.incomplete","response":{"id":"resp_1","incomplete_details":{"reason":"max_output_tokens"}}}"#
            )
        ) { error in
            XCTAssertEqual(
                error as? MiMoClientError,
                .incomplete(reason: "max_output_tokens")
            )
            XCTAssertTrue(
                (error as? MiMoClientError)?.isOutputLimitIncomplete == true
            )
        }
    }

    func testOfficialMiMoUsageParsesBalanceAndTokenPlan() throws {
        let balance = Data("""
        {"code":0,"data":{"balance":"25.51","currency":"USD","cashBalance":"20","giftBalance":"5.51"}}
        """.utf8)
        let detail = Data("""
        {"code":0,"data":{"planCode":"standard","currentPeriodEnd":"2026-08-01 00:00:00","expired":false}}
        """.utf8)
        let usage = Data("""
        {"code":0,"data":{"monthUsage":{"items":[{"used":10100158,"limit":200000000}]}}}
        """.utf8)

        let snapshot = try MiMoOfficialUsageService.parse(
            balanceData: balance,
            detailData: detail,
            usageData: usage,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(snapshot.balance, Decimal(string: "25.51"))
        XCTAssertEqual(snapshot.cashBalance, Decimal(20))
        XCTAssertEqual(snapshot.giftBalance, Decimal(string: "5.51"))
        XCTAssertEqual(snapshot.planCode, "standard")
        XCTAssertEqual(snapshot.tokenUsed, 10_100_158)
        XCTAssertEqual(snapshot.tokenLimit, 200_000_000)
        XCTAssertEqual(snapshot.tokenRemaining, 189_899_842)
        XCTAssertNotNil(snapshot.planPeriodEnd)
    }

    func testToolRegistryExposesAuthoritativeEntityLookupAndDirectExport() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-entities-export-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let otherFarmID = UUID()
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: accountID,
            name: "测试牧场"
        )
        context.insert(farm)
        context.insert(PenRecord(farmID: farmID, name: "育肥一圈"))
        context.insert(PenRecord(farmID: otherFarmID, name: "其他牧场圈舍"))
        try context.save()

        let registry = InsightToolRegistry()
        let farmContext = FarmContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner
        )
        let definitions = registry.definitions(for: farmContext)
        XCTAssertTrue(definitions.contains { $0.name == "get_farm_entities" })
        XCTAssertTrue(definitions.contains { $0.name == "create_farm_export" })

        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let entities = try registry.execute(
            .init(
                callID: "entities",
                name: "get_farm_entities",
                argumentsJSON: #"{"category":"pens","query":"","limit":50}"#
            ),
            agent: agent,
            context: context
        )
        XCTAssertTrue(entities.output.contains("育肥一圈"))
        XCTAssertFalse(entities.output.contains("其他牧场圈舍"))

        let export = try registry.execute(
            .init(
                callID: "export",
                name: "create_farm_export",
                argumentsJSON: #"{"format":"xlsx"}"#
            ),
            agent: agent,
            context: context
        )
        XCTAssertEqual(export.generatedFile?.kind, .xlsx)
        XCTAssertTrue(export.generatedFile?.fileName.hasSuffix(".xlsx") == true)
        XCTAssertFalse(export.generatedFile?.data.isEmpty ?? true)
        XCTAssertTrue(export.output.contains(#""status":"file_generated""#))
    }

    func testImportFileCreatesHighRiskConfirmationDraftWithoutWriting() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-import-preview-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farm = FarmRecord(
            ownerAccountID: accountID,
            name: "导入测试牧场"
        )
        context.insert(farm)
        try context.save()
        let csv = Data("""
        耳号,品种,性别,圈舍,入场日期,出生日期,备注
        QA022,湖羊,母羊,,2026-07-22,,AI导入
        """.utf8)
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farm.id,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )

        let draft = try InsightImportCoordinator.prepare(
            fileName: "羊只.csv",
            fileExtension: "csv",
            data: csv,
            agent: agent,
            farm: farm,
            context: context
        )
        let payload = try InsightImportCoordinator.payload(for: draft)

        XCTAssertEqual(draft.toolName, InsightImportCoordinator.toolName)
        XCTAssertEqual(draft.risk, .high)
        XCTAssertEqual(draft.status, .proposed)
        XCTAssertEqual(payload.acceptedCount, 1)
        XCTAssertEqual(payload.errorCount, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SheepRecord>()).isEmpty)
    }

    func testConfirmedImportUsesExistingAtomicImportService() async throws {
        let container = try AppSchema.makeContainer(
            name: "insight-import-execute-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(
            appleUserIdentifier: "insight-import-\(UUID().uuidString)",
            displayName: "导入测试"
        )
        let farm = FarmRecord(
            ownerAccountID: account.effectiveAccountID,
            name: "导入执行牧场"
        )
        context.insert(account)
        context.insert(farm)
        try context.save()
        let csv = Data("""
        耳号,品种,性别,圈舍,入场日期,出生日期,备注
        QA022,湖羊,母羊,,2026-07-22,,AI导入
        """.utf8)
        let agent = InsightAgentContext(
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let draft = try InsightImportCoordinator.prepare(
            fileName: "羊只.csv",
            fileExtension: "csv",
            data: csv,
            agent: agent,
            farm: farm,
            context: context
        )
        try await InsightLocalImportStore.shared.save(
            data: csv,
            accountID: account.effectiveAccountID,
            draftID: draft.id
        )

        _ = try await InsightImportCoordinator.execute(
            draft,
            account: account,
            farm: farm,
            context: context
        )

        let imported = try context.fetch(FetchDescriptor<SheepRecord>())
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.earTag, "QA022")
        XCTAssertFalse(imported.first?.earTag.contains("-") ?? true)
        XCTAssertFalse(try context.fetch(FetchDescriptor<DomainOperation>()).isEmpty)
    }

    func testToolRegistryIsFarmScopedAndAnalyticsRequiresCapability() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-tools-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let firstFarmID = UUID()
        let secondFarmID = UUID()
        context.insert(SheepRecord(
            farmID: firstFarmID,
            earTag: "A-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        ))
        context.insert(SheepRecord(
            farmID: secondFarmID,
            earTag: "B-001",
            breed: "杜泊",
            sex: .ram,
            penID: nil,
            enteredAt: .now
        ))
        try context.save()

        let registry = InsightToolRegistry()
        let worker = FarmContext(accountID: accountID, farmID: firstFarmID, role: .worker)
        XCTAssertFalse(registry.definitions(for: worker).contains(where: { $0.name == "analyze_farm" }))
        let owner = FarmContext(accountID: accountID, farmID: firstFarmID, role: .owner)
        XCTAssertTrue(registry.definitions(for: owner).contains(where: { $0.name == "analyze_farm" }))

        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: firstFarmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(callID: "find", name: "find_sheep", argumentsJSON: #"{"query":"001"}"#),
            agent: agent,
            context: context
        )
        XCTAssertTrue(result.output.contains("A-001"))
        XCTAssertFalse(result.output.contains("B-001"))
    }

    func testFindSheepReturnsExactProfileBirthDateAndUnifiedCurrentState() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-find-sheep-profile-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let birthAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-01T04:49:00Z")
        )
        context.insert(SheepRecord(
            farmID: farmID,
            earTag: "S2-U033-RELATED",
            breed: "湖羊",
            sex: .ram,
            penID: nil,
            enteredAt: birthAt,
            birthAt: birthAt
        ))
        context.insert(SheepRecord(
            farmID: farmID,
            earTag: "S2-U033",
            breed: "湖羊",
            sex: .ram,
            penID: nil,
            enteredAt: birthAt,
            birthAt: birthAt
        ))
        try context.save()
        let agent = InsightAgentContext(
            accountID: UUID(),
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )

        let execution = try InsightToolRegistry().execute(
            .init(
                callID: "find-exact-profile",
                name: "find_sheep",
                argumentsJSON: #"{"query":"S2-U033"}"#
            ),
            agent: agent,
            context: context
        )
        let data = try XCTUnwrap(execution.output.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        let exact = try XCTUnwrap(rows.first)

        XCTAssertEqual(exact["ear_tag"] as? String, "S2-U033")
        let birthText = try XCTUnwrap(exact["birth_at"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: birthText), birthAt)
        XCTAssertEqual(exact["status"] as? String, SheepStatus.active.rawValue)
        XCTAssertEqual(exact["currently_present"] as? Bool, true)
        XCTAssertEqual(exact["projection_matches_stored_state"] as? Bool, true)
        XCTAssertEqual(object["contract_version"] as? String, FarmFactContract.version)
    }

    func testAssistantInstructionsUseCurrentCalendarYearAndLocalTimeZone() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-07-25T06:50:00Z"))
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        let instructions = InsightConversationController.instructions(
            farmName: "测试牧场",
            now: now,
            timeZone: timeZone
        )

        XCTAssertTrue(instructions.contains("2026-07-25 14:50"))
        XCTAssertTrue(instructions.contains("公历年份是 2026"))
        XCTAssertTrue(instructions.contains("默认使用当前公历年份 2026"))
        XCTAssertTrue(instructions.contains("UTC+08:00"))
        XCTAssertTrue(instructions.contains("批量核对必须一次调用 match_sheep_ear_tags"))
        XCTAssertTrue(instructions.contains("本地批量匹配最多 200 个耳号"))
        XCTAssertTrue(instructions.contains("多个称重必须一次调用 draft_record_weights"))
        XCTAssertTrue(instructions.contains("直接一次调用 draft_sell_sheep_batch"))
        XCTAssertTrue(instructions.contains("单只断奶调用 draft_record_weaning"))
        XCTAssertTrue(instructions.contains("多只断奶必须一次调用 draft_record_weanings"))
        XCTAssertTrue(instructions.contains("不需要母本或胎只数"))
        XCTAssertTrue(instructions.contains("绝不表示已经提交、保存或执行"))
        XCTAssertTrue(instructions.contains("当前聊天页内回复用户"))
        XCTAssertTrue(instructions.contains("不得说“前往 App”"))
        XCTAssertTrue(instructions.contains("不得凭空增加行、改写耳号、把公斤自动换算成斤"))
        XCTAssertTrue(instructions.contains("AI 智能牧场助手"))
        XCTAssertFalse(instructions.contains("MiMo 智能牧场助手"))
    }

    func testAssistantResponseGuardRejectsUnbackedCardsAndIncompleteLeadIns() {
        let fakeSuccess = """
        全部 18 张断奶卡片已生成，请前往 App 逐条确认：
        | 耳号 | 状态 |
        | DH057 | \u{2705} 已提交 |
        """
        XCTAssertEqual(
            InsightAssistantResponseGuard.issue(
                for: fakeSuccess,
                createdDraftCount: 0,
                earTagEvidence: nil
            ),
            .actionClaimWithoutDraft
        )
        XCTAssertEqual(
            InsightAssistantResponseGuard.issue(
                for: "好的，我重新批量生成。\n\n**第一批：断奶记录（18只）**",
                createdDraftCount: 0,
                earTagEvidence: nil
            ),
            .incompleteResponse
        )

        let localized = InsightAssistantResponseGuard.localizedForCurrentApp(
            "请前往 App 逐条确认。"
        )
        XCTAssertEqual(localized, "请在当前聊天页逐条确认。")
        XCTAssertFalse(localized.contains("前往 App"))
        XCTAssertEqual(
            InsightAssistantResponseGuard.draftConfirmationText(
                count: 18,
                stoppedAtToolLimit: false
            ),
            "已在本条回复下方生成 18 张待确认操作卡片，牧场数据尚未写入。请逐张核对后再确认执行。"
        )
    }

    func testAssistantResponseGuardUsesAuthoritativeEarTagEvidence() throws {
        let evidence = try XCTUnwrap(InsightEarTagMatchEvidence(toolOutput: """
        {
          "status": "needs_review",
          "canonical_ear_tags": ["DH057", "DH058"],
          "unmatched_ear_tags": ["QA029"]
        }
        """))
        XCTAssertEqual(
            InsightAssistantResponseGuard.issue(
                for: "请确认 DH057 是否确实存在？我找不到对应信息。",
                createdDraftCount: 0,
                earTagEvidence: evidence
            ),
            .contradictedEarTagEvidence
        )
        XCTAssertEqual(
            InsightAssistantResponseGuard.issue(
                for: "QA029 已匹配，但没有体重。",
                createdDraftCount: 0,
                earTagEvidence: evidence
            ),
            .contradictedEarTagEvidence
        )
        XCTAssertNil(InsightAssistantResponseGuard.issue(
            for: "DH057 与 DH058 已匹配。\nQA029 未匹配，请核对。",
            createdDraftCount: 0,
            earTagEvidence: evidence
        ))
    }

    func testConversationControllerRestoresOnlyTheBoundAccountAndFarm() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-conversation-farm-scope-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(
            appleUserIdentifier: "scope-\(UUID().uuidString)",
            displayName: "测试账号"
        )
        let accountID = account.effectiveAccountID
        let otherAccountID = UUID()
        let stardewFarm = FarmRecord(
            ownerAccountID: accountID,
            name: "星露谷"
        )
        let jihaoFarm = FarmRecord(
            ownerAccountID: accountID,
            name: "吉昊羊场"
        )
        let stardewConversation = InsightConversationRecord(
            accountID: accountID,
            farmID: stardewFarm.id,
            title: "星露谷会话"
        )
        let jihaoConversation = InsightConversationRecord(
            accountID: accountID,
            farmID: jihaoFarm.id,
            title: "吉昊羊场会话"
        )
        let stardewMessage = InsightMessageRecord(
            conversationID: stardewConversation.id,
            accountID: accountID,
            farmID: stardewFarm.id,
            role: .assistant,
            text: "星露谷数据"
        )
        let foreignFarmMessage = InsightMessageRecord(
            conversationID: stardewConversation.id,
            accountID: accountID,
            farmID: jihaoFarm.id,
            role: .assistant,
            text: "不应载入的吉昊羊场数据"
        )
        let foreignAccountMessage = InsightMessageRecord(
            conversationID: stardewConversation.id,
            accountID: otherAccountID,
            farmID: stardewFarm.id,
            role: .assistant,
            text: "不应载入的其他账号数据"
        )
        let stardewDraft = InsightActionDraftRecord(
            conversationID: stardewConversation.id,
            messageID: stardewMessage.id,
            accountID: accountID,
            farmID: stardewFarm.id,
            originDeviceID: UUID(),
            toolName: "draft_farm_command",
            title: "星露谷草案",
            summary: "仅属于星露谷",
            argumentsJSON: Data("{}".utf8),
            risk: .normal,
            requiredCapability: .recordProduction
        )
        let foreignFarmDraft = InsightActionDraftRecord(
            conversationID: stardewConversation.id,
            messageID: stardewMessage.id,
            accountID: accountID,
            farmID: jihaoFarm.id,
            originDeviceID: UUID(),
            toolName: "draft_farm_command",
            title: "吉昊羊场草案",
            summary: "不应载入",
            argumentsJSON: Data("{}".utf8),
            risk: .normal,
            requiredCapability: .recordProduction
        )
        let stardewAttachment = InsightAttachmentRecord(
            conversationID: stardewConversation.id,
            messageID: stardewMessage.id,
            accountID: accountID,
            farmID: stardewFarm.id,
            imageData: Data([0x01]),
            pixelWidth: 1,
            pixelHeight: 1,
            digest: "stardew"
        )
        let foreignFarmAttachment = InsightAttachmentRecord(
            conversationID: stardewConversation.id,
            messageID: stardewMessage.id,
            accountID: accountID,
            farmID: jihaoFarm.id,
            imageData: Data([0x02]),
            pixelWidth: 1,
            pixelHeight: 1,
            digest: "jihao"
        )

        context.insert(account)
        context.insert(stardewFarm)
        context.insert(jihaoFarm)
        context.insert(stardewConversation)
        context.insert(jihaoConversation)
        context.insert(stardewMessage)
        context.insert(foreignFarmMessage)
        context.insert(foreignAccountMessage)
        context.insert(stardewDraft)
        context.insert(foreignFarmDraft)
        context.insert(stardewAttachment)
        context.insert(foreignFarmAttachment)
        try context.save()

        let controller = InsightConversationController(
            account: account,
            farm: stardewFarm
        )
        controller.connectLocalState(to: context)

        XCTAssertEqual(controller.conversations.map(\.id), [stardewConversation.id])
        controller.selectConversation(stardewConversation.id)
        XCTAssertEqual(controller.messages.map(\.id), [stardewMessage.id])
        XCTAssertEqual(controller.drafts.map(\.id), [stardewDraft.id])
        XCTAssertTrue(controller.conversationScope.contains(stardewAttachment))
        XCTAssertFalse(controller.conversationScope.contains(foreignFarmAttachment))

        let baselineContextUsage = controller.contextWindowUsage
        let persistedEvidence = InsightMessageRecord(
            conversationID: stardewConversation.id,
            accountID: accountID,
            farmID: stardewFarm.id,
            role: .system,
            text: String(repeating: "本地查询证据", count: 2_000),
            createdAt: stardewMessage.createdAt.addingTimeInterval(1),
            provider: "local",
            model: FarmFactContract.version,
            toolName: InsightFarmQueryEngine.persistedEvidenceToolName
        )
        context.insert(persistedEvidence)
        try context.save()
        controller.selectConversation(stardewConversation.id)
        XCTAssertEqual(Set(controller.messages.map(\.id)), Set([stardewMessage.id, persistedEvidence.id]))
        XCTAssertEqual(controller.visibleMessages.map(\.id), [stardewMessage.id])
        XCTAssertLessThanOrEqual(
            abs(controller.contextWindowUsage.estimatedTokens - baselineContextUsage.estimatedTokens),
            8,
            "隐藏证据不得进入模型上下文；这里仅允许当前时间文本造成的极小估算波动。"
        )
        XCTAssertEqual(controller.contextWindowUsage.lastCompressedAt, baselineContextUsage.lastCompressedAt)

        controller.selectConversation(jihaoConversation.id)
        XCTAssertNil(controller.currentConversationID)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(controller.drafts.isEmpty)
        XCTAssertEqual(controller.errorMessage, "该会话不属于当前牧场，已停止打开。")
    }

    func testConversationControllerCachesCardPresentationAndContextUsageBeforeTap() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-card-tap-cache-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(
            appleUserIdentifier: "card-cache-\(UUID().uuidString)",
            displayName: "测试账号"
        )
        let farm = FarmRecord(
            ownerAccountID: account.effectiveAccountID,
            name: "长会话测试场"
        )
        let conversation = InsightConversationRecord(
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            title: "长会话卡片"
        )
        let baseDate = Date(timeIntervalSince1970: 1_767_225_600)
        var latestAssistantMessage: InsightMessageRecord?

        context.insert(account)
        context.insert(farm)
        context.insert(conversation)
        for index in 0..<160 {
            let role: InsightMessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let message = InsightMessageRecord(
                conversationID: conversation.id,
                accountID: account.effectiveAccountID,
                farmID: farm.id,
                role: role,
                text: "历史消息 \(index) " + String(repeating: "羊", count: 80),
                createdAt: baseDate.addingTimeInterval(Double(index))
            )
            context.insert(message)
            if role == .assistant {
                latestAssistantMessage = message
            }
        }

        let occurredAt = Date(timeIntervalSince1970: 1_767_229_200)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let draft = InsightActionDraftRecord(
            conversationID: conversation.id,
            messageID: try XCTUnwrap(latestAssistantMessage).id,
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            originDeviceID: UUID(),
            toolName: "draft_record_weight",
            title: "记录称重",
            summary: "DH057 · 52.5 kg",
            argumentsJSON: try encoder.encode(RecordWeightToolPayload(
                sheepID: UUID(),
                earTag: "DH057",
                kilogramsText: "52.5",
                occurredAt: occurredAt,
                note: ""
            )),
            risk: .normal,
            requiredCapability: .recordProduction
        )
        context.insert(draft)
        try context.save()

        let controller = InsightConversationController(account: account, farm: farm)
        controller.connectLocalState(to: context)
        controller.selectConversation(conversation.id)

        let cachedUsage = controller.contextWindowUsage
        let cachedPresentation = controller.presentation(for: draft)
        XCTAssertGreaterThan(cachedUsage.estimatedTokens, 0)
        XCTAssertEqual(cachedPresentation.occurredAt, occurredAt)
        XCTAssertTrue(cachedPresentation.editablePayloadText?.contains("DH057") == true)
        XCTAssertNil(cachedPresentation.editablePayloadError)
        XCTAssertEqual(controller.drafts(forMessageID: try XCTUnwrap(draft.messageID)).map(\.id), [draft.id])

        // A tap causes SwiftUI to reevaluate the page. These model mutations
        // deliberately happen without a controller reload: the hot path must
        // keep returning the already-built values instead of rescanning the
        // whole conversation or reparsing the draft JSON during rendering.
        try XCTUnwrap(latestAssistantMessage).text += String(repeating: "新", count: 20_000)
        draft.argumentsJSON = Data("{}".utf8)
        XCTAssertEqual(controller.contextWindowUsage, cachedUsage)
        XCTAssertEqual(controller.presentation(for: draft), cachedPresentation)

        controller.selectConversation(conversation.id)
        XCTAssertGreaterThan(controller.contextWindowUsage.estimatedTokens, cachedUsage.estimatedTokens)
        XCTAssertNil(controller.presentation(for: draft).occurredAt)
        let reloadedPayloadText = try XCTUnwrap(
            controller.presentation(for: draft).editablePayloadText
        )
        XCTAssertTrue(reloadedPayloadText.contains("{"))
        XCTAssertFalse(reloadedPayloadText.contains("DH057"))
    }

    func testBatchEarTagMatcherResolvesOneHundredTwentyOneNumericReferencesInOneCall() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-ear-tag-match-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let otherFarmID = UUID()
        let canonicalEarTags = (1...121).map { String(format: "FARM%04d", $0) }
        let numericReferences = (1...121).map { String(format: "%04d", $0) }

        for earTag in canonicalEarTags {
            context.insert(SheepRecord(
                farmID: farmID,
                earTag: earTag,
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now
            ))
        }
        context.insert(SheepRecord(
            farmID: otherFarmID,
            earTag: "OTHER0001",
            breed: "杜泊",
            sex: .ram,
            penID: nil,
            enteredAt: .now
        ))
        try context.save()

        let registry = InsightToolRegistry()
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        XCTAssertTrue(
            registry.definitions(for: farm).contains(where: {
                $0.name == "match_sheep_ear_tags"
            })
        )
        let argumentsData = try JSONSerialization.data(
            withJSONObject: ["ear_tags": numericReferences]
        )
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "batch-match",
                name: "match_sheep_ear_tags",
                argumentsJSON: String(decoding: argumentsData, as: UTF8.self)
            ),
            agent: agent,
            context: context
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["status"] as? String, "all_matched")
        XCTAssertEqual(object["input_count"] as? Int, 121)
        XCTAssertEqual(object["matched_count"] as? Int, 121)
        XCTAssertEqual(object["unmatched_count"] as? Int, 0)
        XCTAssertEqual(object["ambiguous_count"] as? Int, 0)
        XCTAssertEqual(object["duplicate_input_count"] as? Int, 0)
        XCTAssertEqual(object["canonical_ear_tags"] as? [String], canonicalEarTags)
        XCTAssertTrue(result.actionDrafts.isEmpty)
    }

    func testBatchEarTagMatcherReportsAmbiguousMissingAndDuplicateReferencesTogether() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-ear-tag-review-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        for earTag in ["A7090", "B7090", "A7003"] {
            context.insert(SheepRecord(
                farmID: farmID,
                earTag: earTag,
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now
            ))
        }
        try context.save()

        let argumentsData = try JSONSerialization.data(withJSONObject: [
            "ear_tags": ["7090", "7003", "A7003", "9999"],
        ])
        let registry = InsightToolRegistry()
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "batch-review",
                name: "match_sheep_ear_tags",
                argumentsJSON: String(decoding: argumentsData, as: UTF8.self)
            ),
            agent: agent,
            context: context
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["status"] as? String, "needs_review")
        XCTAssertEqual(object["matched_count"] as? Int, 1)
        XCTAssertEqual(object["ambiguous_count"] as? Int, 1)
        XCTAssertEqual(object["unmatched_count"] as? Int, 1)
        XCTAssertEqual(object["duplicate_input_count"] as? Int, 1)
        XCTAssertEqual(object["canonical_ear_tags"] as? [String], ["A7003"])
        XCTAssertEqual(object["unmatched_ear_tags"] as? [String], ["9999"])
        XCTAssertEqual(object["duplicate_input_ear_tags"] as? [String], ["A7003"])
    }

    func testBatchSaleToolAcceptsUniqueNumericReferencesForPrefixedEarTags() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-sale-numeric-match-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        for earTag in ["A7090", "A7003"] {
            context.insert(SheepRecord(
                farmID: farmID,
                earTag: earTag,
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now.addingTimeInterval(-86_400)
            ))
        }
        try context.save()

        let registry = InsightToolRegistry()
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "batch-sale-numeric",
                name: "draft_sell_sheep_batch",
                argumentsJSON: """
                {
                  "occurred_at": "2026-07-13T08:00:00+08:00",
                  "total_amount": "150780",
                  "note": "",
                  "ear_tags": ["7090", "7003"]
                }
                """
            ),
            agent: agent,
            context: context
        )

        XCTAssertEqual(result.actionDrafts.count, 2)
        XCTAssertEqual(
            Set(result.actionDrafts.map(\.summary)),
            Set([
                "A7090 · 批量出售，总价 ¥150780",
                "A7003 · 批量出售，总价 ¥150780",
            ])
        )
        XCTAssertTrue(result.output.contains(#""proposal_count":2"#))
        XCTAssertTrue(try context.fetch(FetchDescriptor<RemovalRecord>()).isEmpty)
    }

    func testConversationRequestKeepsMessagesBeyondLegacySixteenMessageLimit() {
        let messages = (0..<24).map {
            MiMoInputMessage(role: .user, text: "消息 \($0)")
        }

        let request = MiMoConversationRequest(
            instructions: "测试",
            messages: messages
        )

        XCTAssertEqual(request.messages, messages)
    }

    func testContextCompressorWaitsFor512KThreshold() {
        let messages = [
            MiMoInputMessage(
                role: .user,
                text: String(repeating: "羊", count: 32_000)
            ),
        ]

        let preparation = InsightContextCompressor.prepare(
            messages: messages,
            additionalEstimatedTokens: 8_192
        )

        XCTAssertFalse(preparation.didCompress)
        XCTAssertEqual(preparation.messages, messages)
        XCTAssertLessThan(
            preparation.originalEstimatedTokens,
            InsightContextCompressor.compressionThresholdTokens
        )
    }

    func testContextCompressorSummarizesOlderMessagesAt512KAndKeepsLatest() {
        let messages = (0..<600).map { index in
            MiMoInputMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "消息 \(index) " + String(repeating: "羊", count: 1_000)
            )
        }

        let preparation = InsightContextCompressor.prepare(
            messages: messages,
            additionalEstimatedTokens: 12_000
        )

        XCTAssertTrue(preparation.didCompress)
        XCTAssertGreaterThan(preparation.compressedMessageCount, 0)
        XCTAssertEqual(preparation.messages.first?.role, .system)
        XCTAssertTrue(preparation.messages.first?.text.contains("512K") == true)
        XCTAssertTrue(preparation.messages.last?.text.contains("消息 599") == true)
        XCTAssertLessThan(
            preparation.preparedEstimatedTokens,
            InsightContextCompressor.compressionThresholdTokens
        )
    }

    func testContextWindowUsageClampsCircularPercentage() {
        let usage = InsightContextWindowUsage(
            estimatedTokens: 600 * 1_024,
            limitTokens: 512 * 1_024,
            lastCompressedAt: nil
        )

        XCTAssertEqual(usage.fraction, 1)
        XCTAssertEqual(usage.percentage, 100)
    }

    func testWeaningToolCreatesOneTrueWeaningCardWithAtomicTransferCommands() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-weaning-card-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "insight-weaning-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "测试场")
        let sourcePen = PenRecord(farmID: farm.id, name: "羔羊圈")
        let targetPen = PenRecord(farmID: farm.id, name: "育成圈")
        let enteredAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-01T00:00:00+08:00"))
        let sheep = SheepRecord(
            farmID: farm.id,
            earTag: "L001",
            breed: "湖羊",
            sex: .ram,
            penID: sourcePen.id,
            enteredAt: enteredAt,
            birthAt: enteredAt
        )
        context.insert(account)
        context.insert(farm)
        context.insert(sourcePen)
        context.insert(targetPen)
        context.insert(sheep)
        try context.save()

        let registry = InsightToolRegistry()
        let farmContext = FarmContext(
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            role: .owner
        )
        XCTAssertTrue(registry.definitions(for: farmContext).contains {
            $0.name == "draft_record_weaning" &&
                $0.description.contains("断奶不需要母本或胎只数")
        })
        let agent = InsightAgentContext(
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "weaning",
                name: "draft_record_weaning",
                argumentsJSON: """
                {
                  "ear_tag": "L001",
                  "wean_weight": "24.5",
                  "to_pen_name": "育成圈",
                  "occurred_at": "2026-07-22T08:00:00+08:00",
                  "note": "正常断奶"
                }
                """
            ),
            agent: agent,
            context: context
        )

        let draft = try XCTUnwrap(result.actionDraft)
        XCTAssertEqual(result.actionDrafts.count, 1)
        XCTAssertEqual(draft.toolName, "draft_record_weaning")
        XCTAssertEqual(draft.title, "记录断奶")
        XCTAssertEqual(draft.summary, "L001 · 24.5 kg · 调入 育成圈")
        let payloadDecoder = JSONDecoder()
        payloadDecoder.dateDecodingStrategy = .iso8601
        let payload = try payloadDecoder.decode(
            RecordWeaningToolPayload.self,
            from: draft.argumentsJSON
        )
        XCTAssertEqual(payload.sheepID, sheep.id)
        XCTAssertEqual(payload.toPenID, targetPen.id)
        try registry.validate(draft, agent: agent, context: context)

        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        let legacyDraft = InsightActionDraftRecord(
            conversationID: agent.conversationID,
            accountID: agent.accountID,
            farmID: agent.farmID,
            originDeviceID: agent.originDeviceID,
            toolName: "draft_farm_command",
            title: "记录断奶",
            summary: "缺少断奶后目标圈舍",
            argumentsJSON: try legacyEncoder.encode(CanonicalFarmCommandToolPayload(
                commandPayload: try FarmCommandCloudPayloadEncoder.encode(.recordWeaning(
                    sheepID: sheep.id,
                    weanWeightText: "24.5",
                    occurredAt: payload.occurredAt,
                    birthAt: sheep.birthAt,
                    birthWeightText: nil,
                    averageDailyGainText: nil,
                    damID: nil,
                    litterSize: nil,
                    note: "旧版卡片"
                ))
            )),
            risk: .normal,
            requiredCapability: .recordProduction,
            expectedEntityID: sheep.id,
            expectedRevision: sheep.revision
        )
        XCTAssertThrowsError(try registry.validate(legacyDraft, agent: agent, context: context)) {
            XCTAssertEqual(
                $0.localizedDescription,
                InsightToolError.obsoleteWeaningDraft.localizedDescription
            )
        }

        let commands = try registry.farmCommands(for: draft)
        XCTAssertEqual(commands.count, 2)
        guard case .recordWeaning(_, _, _, _, _, _, let damID, let litterSize, _) = commands[0] else {
            return XCTFail("Expected recordWeaning as the primary card command")
        }
        XCTAssertNil(damID)
        XCTAssertNil(litterSize)
        guard case .transferSheep(let sheepID, let toPenID, _, _) = commands[1] else {
            return XCTFail("Expected required transfer as the companion command")
        }
        XCTAssertEqual(sheepID, sheep.id)
        XCTAssertEqual(toPenID, targetPen.id)

        let receipts = try FarmCommandService().executeBatch(
            [
                (command: commands[0], sourceRequestID: draft.id),
                (
                    command: commands[1],
                    sourceRequestID: WeaningWorkflow.transferSourceRequestID(for: draft.id)
                ),
            ],
            in: farmContext,
            context: context
        )
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WeaningRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TransferRecord>()).count, 1)
        XCTAssertEqual(sheep.currentPenID, targetPen.id)
    }

    func testBatchWeaningToolCreatesEveryCompleteCardInOneCall() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-weaning-card-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let sourcePen = PenRecord(farmID: farmID, name: "羔羊圈")
        let targetPen = PenRecord(farmID: farmID, name: "大棚九舍")
        let enteredAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-03-01T00:00:00+08:00")
        )
        let sheep = [
            (earTag: "DH057", weight: "7.8"),
            (earTag: "DH058", weight: "18.8"),
            (earTag: "PA036", weight: "15.8"),
        ].map { value in
            SheepRecord(
                farmID: farmID,
                earTag: value.earTag,
                breed: "湖羊",
                sex: .ewe,
                penID: sourcePen.id,
                enteredAt: enteredAt,
                birthAt: enteredAt
            )
        }
        context.insert(sourcePen)
        context.insert(targetPen)
        sheep.forEach(context.insert)
        try context.save()

        let registry = InsightToolRegistry()
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        XCTAssertTrue(registry.definitions(for: farm).contains {
            $0.name == "draft_record_weanings" &&
                $0.description.contains("整批校验成功后才生成")
        })
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "batch-weaning",
                name: "draft_record_weanings",
                argumentsJSON: """
                {
                  "occurred_at": "2026-07-21T08:00:00+08:00",
                  "to_pen_name": "大棚九舍",
                  "note": "图片批量录入",
                  "items": [
                    {"ear_tag": "DH057", "wean_weight": "7.8"},
                    {"ear_tag": "DH058", "wean_weight": "18.8"},
                    {"ear_tag": "PA036", "wean_weight": "15.8"}
                  ]
                }
                """
            ),
            agent: agent,
            context: context
        )

        XCTAssertEqual(result.actionDrafts.count, 3)
        XCTAssertTrue(result.output.contains(#""proposal_count":3"#))
        XCTAssertEqual(Set(result.actionDrafts.map(\.toolName)), ["draft_record_weaning"])
        XCTAssertEqual(
            Set(result.actionDrafts.map(\.summary)),
            Set([
                "DH057 · 7.8 kg · 调入 大棚九舍",
                "DH058 · 18.8 kg · 调入 大棚九舍",
                "PA036 · 15.8 kg · 调入 大棚九舍",
            ])
        )
        try registry.validate(result.actionDrafts, agent: agent, context: context)
        XCTAssertTrue(result.actionDrafts.allSatisfy {
            (try? registry.farmCommands(for: $0).count) == 2
        })
        XCTAssertTrue(try context.fetch(FetchDescriptor<WeaningRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TransferRecord>()).isEmpty)

        XCTAssertThrowsError(try registry.execute(
            .init(
                callID: "batch-weaning-invalid",
                name: "draft_record_weanings",
                argumentsJSON: """
                {
                  "occurred_at": "2026-07-21T08:00:00+08:00",
                  "to_pen_name": "大棚九舍",
                  "note": "",
                  "items": [
                    {"ear_tag": "DH057", "wean_weight": "7.8"},
                    {"ear_tag": "NOT-FOUND", "wean_weight": "10"}
                  ]
                }
                """
            ),
            agent: agent,
            context: context
        ))
    }

    func testBatchWeightToolCreatesAllPendingDraftsInOneCall() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-weight-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let first = SheepRecord(
            farmID: farmID,
            earTag: "A001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let second = SheepRecord(
            farmID: farmID,
            earTag: "A002",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        let registry = InsightToolRegistry()
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        XCTAssertTrue(
            registry.definitions(for: farm).contains(where: {
                $0.name == "draft_record_weights"
            })
        )
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "batch-weights",
                name: "draft_record_weights",
                argumentsJSON: """
                {
                  "occurred_at": "2026-07-22T00:00:00+08:00",
                  "note": "",
                  "items": [
                    {"ear_tag": "A001", "kilograms": "52.0"},
                    {"ear_tag": "A002", "kilograms": "51.5"}
                  ]
                }
                """
            ),
            agent: agent,
            context: context
        )

        XCTAssertEqual(result.actionDrafts.count, 2)
        XCTAssertTrue(result.actionDrafts.allSatisfy { $0.status == .proposed })
        XCTAssertTrue(result.output.contains(#""proposal_count":2"#))
        XCTAssertTrue(result.output.contains(#""executed_count":0"#))
        XCTAssertEqual(result.actionDrafts.map(\.summary), [
            "A001 · 52.0 kg",
            "A002 · 51.5 kg",
        ])
        let occurredAt = try XCTUnwrap(
            registry.occurredAt(for: result.actionDrafts[0])
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: occurredAt
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 22)
    }

    func testBatchSaleToolCreatesFifteenPendingDraftsWithSharedTotal() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-sale-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let earTags = (1...15).map { String(format: "SALE%03d", $0) }
        for earTag in earTags {
            context.insert(SheepRecord(
                farmID: farmID,
                earTag: earTag,
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now.addingTimeInterval(-86_400)
            ))
        }
        try context.save()

        let registry = InsightToolRegistry()
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        XCTAssertTrue(
            registry.definitions(for: farm).contains(where: {
                $0.name == "draft_sell_sheep_batch"
            })
        )
        let earTagsJSON = try XCTUnwrap(
            String(
                data: JSONSerialization.data(withJSONObject: earTags),
                encoding: .utf8
            )
        )
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "batch-sale",
                name: "draft_sell_sheep_batch",
                argumentsJSON: """
                {
                  "occurred_at": "2026-07-22T08:00:00+08:00",
                  "total_amount": "17100",
                  "note": "",
                  "ear_tags": \(earTagsJSON)
                }
                """
            ),
            agent: agent,
            context: context
        )

        XCTAssertEqual(result.actionDrafts.count, 15)
        XCTAssertTrue(result.actionDrafts.allSatisfy {
            $0.status == .proposed &&
                $0.toolName == "draft_farm_command" &&
                $0.summary.contains("总价 ¥17100")
        })
        XCTAssertTrue(result.output.contains(#""proposal_count":15"#))
        XCTAssertTrue(result.output.contains(#""executed_count":0"#))

        var batchIDs = Set<UUID>()
        var draftedSheepIDs = Set<UUID>()
        let commandDecoder = JSONDecoder()
        commandDecoder.dateDecodingStrategy = .iso8601
        for draft in result.actionDrafts {
            let wrapper = try JSONDecoder().decode(
                CanonicalFarmCommandToolPayload.self,
                from: draft.argumentsJSON
            )
            let payload = try commandDecoder.decode(
                FarmCommandCloudPayload.self,
                from: wrapper.commandPayload
            )
            let command = try FarmCommandCloudPayloadDecoder.decode(payload)
            guard case .removeSheep(
                let sheepID,
                let kind,
                let reason,
                let amountText,
                let occurredAt,
                _,
                _,
                let removalBatchID,
                let batchTotalAmountText
            ) = command else {
                return XCTFail("Expected removeSheep command")
            }
            draftedSheepIDs.insert(sheepID)
            XCTAssertEqual(kind, .sold)
            XCTAssertEqual(reason, "出售")
            XCTAssertNil(amountText)
            XCTAssertEqual(batchTotalAmountText, "17100")
            batchIDs.insert(try XCTUnwrap(removalBatchID))

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: occurredAt
            )
            XCTAssertEqual(components.year, 2026)
            XCTAssertEqual(components.month, 7)
            XCTAssertEqual(components.day, 22)
        }
        XCTAssertEqual(batchIDs.count, 1)
        XCTAssertEqual(draftedSheepIDs.count, 15)
        XCTAssertTrue(result.actionDrafts.allSatisfy {
            registry.removalBatchID(for: $0) == batchIDs.first
        })
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<RemovalRecord>()).isEmpty,
            "Draft creation must not write removal records before confirmation."
        )
    }

    func testBatchDraftExecutionCommitsAllReceiptsOnce() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-execution-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let batchID = UUID()
        let sheep = ["SALE001", "SALE002"].map {
            SheepRecord(
                farmID: farmID,
                earTag: $0,
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now.addingTimeInterval(-86_400)
            )
        }
        sheep.forEach(context.insert)
        try context.save()

        let sourceRequestIDs = [UUID(), UUID()]
        let occurredAt = Date.now
        let requests = zip(sheep, sourceRequestIDs).map { item, sourceRequestID in
            (
                command: FarmCommand.removeSheep(
                    sheepID: item.id,
                    kind: .sold,
                    reason: "出售",
                    amountText: nil,
                    occurredAt: occurredAt,
                    note: "",
                    removalBatchID: batchID,
                    batchTotalAmountText: "17100"
                ),
                sourceRequestID: sourceRequestID
            )
        }
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        let service = FarmCommandService()

        let first = try service.executeBatch(requests, in: farm, context: context)
        let second = try service.executeBatch(requests, in: farm, context: context)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.sourceRequestID), sourceRequestIDs)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RemovalRecord>()).count, 2)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<DomainOperation>()).filter {
                sourceRequestIDs.contains($0.sourceRequestID ?? UUID())
            }.count,
            2
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).filter {
                sourceRequestIDs.contains($0.sourceRequestID)
            }.count,
            2
        )
    }

    func testBatchDraftValidationBenchmark() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-validation-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let originDeviceID = UUID()
        let conversationID = UUID()
        let batchID = UUID()
        let occurredAt = Date.now
        let sheep = (1...1_500).map { index in
            SheepRecord(
                farmID: farmID,
                earTag: String(format: "PERF%04d", index),
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: occurredAt.addingTimeInterval(-86_400)
            )
        }
        sheep.forEach(context.insert)
        try context.save()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let drafts = try sheep.prefix(121).map { item in
            let command = FarmCommand.removeSheep(
                sheepID: item.id,
                kind: .sold,
                reason: "出售",
                amountText: nil,
                occurredAt: occurredAt,
                note: "",
                removalBatchID: batchID,
                batchTotalAmountText: "150780"
            )
            return InsightActionDraftRecord(
                conversationID: conversationID,
                accountID: accountID,
                farmID: farmID,
                originDeviceID: originDeviceID,
                toolName: "draft_farm_command",
                title: command.summary,
                summary: command.summary,
                argumentsJSON: try encoder.encode(CanonicalFarmCommandToolPayload(
                    commandPayload: try FarmCommandCloudPayloadEncoder.encode(command)
                )),
                risk: .high,
                requiredCapability: command.requiredCapability,
                expectedEntityID: item.id,
                expectedRevision: item.revision
            )
        }
        let registry = InsightToolRegistry()
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: originDeviceID,
            conversationID: conversationID
        )

        let startedAt = Date.now
        try registry.validate(drafts, agent: agent, context: context)
        let elapsed = Date.now.timeIntervalSince(startedAt)

        print("BATCH_DRAFT_VALIDATION_SECONDS=\(elapsed)")
        XCTAssertEqual(drafts.count, 121)
        XCTAssertLessThan(
            elapsed,
            2,
            "121-item draft validation must not regress to repeated full-farm scans."
        )
    }

    func testBatchRemovalValidationStillRejectsStaleAndCrossFarmReferences() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-validation-safety-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let otherFarmID = UUID()
        let originDeviceID = UUID()
        let conversationID = UUID()
        let batchID = UUID()
        let occurredAt = Date.now
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "SAFE001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: occurredAt.addingTimeInterval(-86_400)
        )
        let otherFarmSheep = SheepRecord(
            farmID: otherFarmID,
            earTag: "OTHER001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: occurredAt.addingTimeInterval(-86_400)
        )
        context.insert(sheep)
        context.insert(otherFarmSheep)
        try context.save()

        func draft(for target: SheepRecord, expectedRevision: Int) throws -> InsightActionDraftRecord {
            let command = FarmCommand.removeSheep(
                sheepID: target.id,
                kind: .sold,
                reason: "出售",
                amountText: nil,
                occurredAt: occurredAt,
                note: "",
                removalBatchID: batchID,
                batchTotalAmountText: "17100"
            )
            return InsightActionDraftRecord(
                conversationID: conversationID,
                accountID: accountID,
                farmID: farmID,
                originDeviceID: originDeviceID,
                toolName: "draft_farm_command",
                title: command.summary,
                summary: command.summary,
                argumentsJSON: try JSONEncoder().encode(CanonicalFarmCommandToolPayload(
                    commandPayload: try FarmCommandCloudPayloadEncoder.encode(command)
                )),
                risk: .high,
                requiredCapability: command.requiredCapability,
                expectedEntityID: target.id,
                expectedRevision: expectedRevision
            )
        }

        let registry = InsightToolRegistry()
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: originDeviceID,
            conversationID: conversationID
        )
        let staleDraft = try draft(for: sheep, expectedRevision: sheep.revision)
        sheep.revision += 1
        XCTAssertThrowsError(try registry.validate([staleDraft], agent: agent, context: context)) { error in
            guard case InsightToolError.staleRevision = error else {
                return XCTFail("Expected staleRevision, got \(error)")
            }
        }

        let validDraft = try draft(for: sheep, expectedRevision: sheep.revision)
        let crossFarmDraft = try draft(
            for: otherFarmSheep,
            expectedRevision: otherFarmSheep.revision
        )
        XCTAssertThrowsError(
            try registry.validate([validDraft, crossFarmDraft], agent: agent, context: context)
        ) { error in
            guard case InsightToolError.crossFarmReference = error else {
                return XCTFail("Expected crossFarmReference, got \(error)")
            }
        }
    }

    func testBatchDraftExecutionBenchmark() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-command-performance-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let batchID = UUID()
        let occurredAt = Date.now
        let sheep = (1...1_500).map { index in
            SheepRecord(
                farmID: farmID,
                earTag: String(format: "EXEC%04d", index),
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: occurredAt.addingTimeInterval(-86_400)
            )
        }
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .supabase,
            authorityGeneration: 1
        ))
        context.insert(FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        ))
        sheep.forEach(context.insert)
        try context.save()

        let requests = sheep.prefix(121).map { item in
            (
                command: FarmCommand.removeSheep(
                    sheepID: item.id,
                    kind: .sold,
                    reason: "出售",
                    amountText: nil,
                    occurredAt: occurredAt,
                    note: "",
                    removalBatchID: batchID,
                    batchTotalAmountText: "150780"
                ),
                sourceRequestID: UUID()
            )
        }
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)

        let startedAt = Date.now
        let receipts = try FarmCommandService().executeBatch(
            requests,
            in: farm,
            context: context
        )
        let elapsed = Date.now.timeIntervalSince(startedAt)

        print("BATCH_DRAFT_EXECUTION_SECONDS=\(elapsed)")
        XCTAssertLessThan(
            elapsed,
            2,
            "121-item command execution must keep shared batch indexes and one save."
        )
        XCTAssertEqual(receipts.count, 121)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RemovalRecord>()).count, 121)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DomainOperation>()).count, 121)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).count, 121)
        XCTAssertEqual(try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).count, 121)
    }

    func testBatchDraftExecutionRollsBackEveryWriteWhenOneCommandFails() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-rollback-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "SALE001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now.addingTimeInterval(-86_400)
        )
        context.insert(sheep)
        try context.save()

        let batchID = UUID()
        let requests = [
            (
                command: FarmCommand.removeSheep(
                    sheepID: sheep.id,
                    kind: .sold,
                    reason: "出售",
                    amountText: nil,
                    occurredAt: .now,
                    note: "",
                    removalBatchID: batchID,
                    batchTotalAmountText: "17100"
                ),
                sourceRequestID: UUID()
            ),
            (
                command: FarmCommand.removeSheep(
                    sheepID: UUID(),
                    kind: .sold,
                    reason: "出售",
                    amountText: nil,
                    occurredAt: .now,
                    note: "",
                    removalBatchID: batchID,
                    batchTotalAmountText: "17100"
                ),
                sourceRequestID: UUID()
            ),
        ]

        XCTAssertThrowsError(
            try FarmCommandService().executeBatch(
                requests,
                in: FarmContext(accountID: accountID, farmID: farmID, role: .owner),
                context: context
            )
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<RemovalRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DomainOperation>()).isEmpty)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).isEmpty
        )
    }

    func testDraftExecutionIsIdempotentBySourceRequestID() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-idempotency-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "W-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        context.insert(sheep)
        try context.save()

        let sourceRequestID = UUID()
        let command = FarmCommand.recordWeight(
            sheepID: sheep.id,
            kilogramsText: "42.5",
            occurredAt: .now,
            note: "AI 草案"
        )
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        let service = FarmCommandService()
        let first = try service.execute(
            command,
            in: farm,
            context: context,
            sourceRequestID: sourceRequestID
        )
        let second = try service.execute(
            command,
            in: farm,
            context: context,
            sourceRequestID: sourceRequestID
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WeightRecord>()).count, 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<DomainOperation>()).filter {
                $0.sourceRequestID == sourceRequestID
            }.count,
            1
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).filter {
                $0.sourceRequestID == sourceRequestID
            }.count,
            1
        )
    }

    func testCanonicalFarmCommandCodecCoversEveryAuthorizedCommandCase() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<40).map { _ in UUID() }
        let healthDraft = CareHealthDraft(
            id: ids[20],
            batchID: ids[21],
            subjectIDs: [ids[0]],
            penID: ids[1],
            catalogItemID: ids[22],
            kind: .treatment,
            itemName: "青霉素",
            occurredAt: now,
            note: "测试",
            inventoryLotID: ids[23],
            dosePerSubjectText: "1",
            unit: "支",
            route: "肌注",
            reminderAt: now.addingTimeInterval(86_400)
        )
        let reproductionDraft = CareReproductionBatchDraft(
            id: ids[24],
            kind: .breeding,
            subjects: [.init(
                id: ids[25],
                eweID: ids[0],
                result: "完成",
                relatedBreedingRecordID: ids[26]
            )],
            occurredAt: now,
            sireID: ids[2],
            semenID: ids[27],
            semenUnitsPerEweText: "1",
            note: "测试",
            reminderAt: nil
        )
        let lambingDraft = CareLambingDraft(
            id: ids[28],
            eweID: ids[0],
            occurredAt: now,
            sireID: ids[2],
            semenID: nil,
            relatedBreedingRecordID: ids[26],
            parity: 2,
            birthDeadCount: 0,
            offspring: [.init(
                id: ids[29],
                sheepID: ids[30],
                earTag: "L-001",
                sex: .ewe,
                birthWeightText: "3.5"
            )],
            penID: ids[1],
            note: "测试"
        )
        let pedigreeDraft = CarePedigreeUpdateDraft(
            id: ids[31],
            sheepID: ids[0],
            damID: ids[3],
            sireID: ids[2],
            semenDonorID: nil,
            reason: "核对档案",
            expectedRevision: 1
        )
        let donorDraft = CareSemenDonorDraft(
            id: ids[32],
            name: "供体",
            registrationNumber: "D-01",
            breed: "杜泊",
            linkedRamID: ids[2],
            note: "测试",
            status: .active,
            expectedRevision: 0
        )
        let pedigreeSnapshot = CarePedigreeAuditSnapshot(
            id: ids[33],
            sheepID: ids[0],
            beforeDamID: nil,
            afterDamID: ids[3],
            beforeSireID: nil,
            afterSireID: ids[2],
            beforeSemenDonorID: nil,
            afterSemenDonorID: nil,
            beforeDamSourceRawValue: nil,
            afterDamSourceRawValue: PedigreeRelationSource.manual.rawValue,
            beforeSireSourceRawValue: nil,
            afterSireSourceRawValue: PedigreeRelationSource.manual.rawValue,
            reason: "恢复测试",
            changedByAccountID: ids[34],
            sheepRevision: 2,
            occurredAt: now
        )
        let careCommands: [CareCommand] = [
            .upsertHealthCatalog(
                id: ids[22],
                kindRawValue: HealthRecordKind.treatment.rawValue,
                name: "青霉素",
                category: "抗生素",
                unit: "支",
                defaultDoseText: "1",
                defaultRoute: "肌注",
                reminderIntervalDays: 7,
                note: "测试",
                isActive: true
            ),
            .recordHealth(healthDraft),
            .correctHealth(originalID: ids[35], replacement: healthDraft, reason: "录入错误"),
            .receiveInventory(
                id: ids[36],
                catalogName: "青霉素",
                catalogItemID: ids[22],
                kindRawValue: HealthRecordKind.treatment.rawValue,
                batchNumber: "B-1",
                supplier: "供应商",
                unit: "支",
                expiresAt: now,
                quantityText: "10",
                occurredAt: now,
                note: "测试"
            ),
            .adjustInventory(id: ids[36], lotID: ids[23], quantityDeltaText: "-1", occurredAt: now, note: "盘点"),
            .setInventoryLotActive(lotID: ids[23], isActive: false),
            .adjustSemen(id: ids[36], semenID: ids[27], quantityDeltaText: "-1", occurredAt: now, note: "盘点"),
            .upsertSemenDonor(donorDraft),
            .setSemenDonor(semenID: ids[27], donorID: ids[32], expectedRevision: 1),
            .updateSheepPedigree(pedigreeDraft),
            .setBreedingRam(sheepID: ids[2], isBreedingRam: true, expectedRevision: 1),
            .restorePedigreeAudit(pedigreeSnapshot),
            .recordReproductionBatch(reproductionDraft),
            .recordLambing(lambingDraft),
            .correctReproduction(originalID: ids[26], replacement: reproductionDraft, reason: "日期错误"),
            .correctLambing(originalID: ids[37], replacement: lambingDraft, reason: "羔羊信息错误"),
            .revokeLambing(recordID: ids[37], reason: "重复记录"),
            .restoreLambing(recordID: ids[37]),
            .updateRules(id: ids[38], pregnancyCheckDays: 45, gestationDays: 150),
            .setReminderStatus(reminderID: ids[39], status: .completed),
        ]
        let commands: [FarmCommand] = [
            .updateFarmLocation(
                displayName: "测试牧场",
                latitude: 31.2,
                longitude: 121.5,
                addressSnapshot: "上海",
                timeZoneIdentifier: "Asia/Shanghai",
                source: .mapSearch,
                horizontalAccuracyMeters: 5
            ),
            .createPen(name: "一号圈", note: ""),
            .updatePen(penID: ids[1], name: "一号圈", note: "更新"),
            .setPenActive(penID: ids[1], isActive: false),
            .addSheep(earTag: "A-001", breed: "湖羊", sex: .ewe, penID: ids[1], occurredAt: now, birthAt: now, note: ""),
            .updateSheepProfile(sheepID: ids[0], earTag: "A-001", breed: "湖羊", sex: .ewe, birthAt: now, note: ""),
            .recordWeight(sheepID: ids[0], kilogramsText: "42.5", occurredAt: now, note: ""),
            .correctWeight(originalID: ids[4], kilogramsText: "43", occurredAt: now, note: "", reason: "录入错误"),
            .recordWeaning(sheepID: ids[0], weanWeightText: "25", occurredAt: now, birthAt: now, birthWeightText: "3.5", averageDailyGainText: "0.2", damID: ids[3], litterSize: 2, note: ""),
            .createBreedingProgram(name: "同期发情", createdAt: now, steps: [.init(id: ids[5], dayOffset: 0, action: "开始")]),
            .transferSheep(sheepID: ids[0], toPenID: ids[1], occurredAt: now, note: ""),
            .correctTransfer(originalID: ids[6], toPenID: ids[1], occurredAt: now, note: "", reason: "圈舍错误"),
            .removeSheep(sheepID: ids[0], kind: .sold, reason: "出售", amountText: "1000", occurredAt: now, note: ""),
            .correctRemoval(originalID: ids[7], kind: .culled, reason: "淘汰", amountText: nil, occurredAt: now, note: "", correctionReason: "类型错误"),
            .restoreSheep(removalID: ids[7]),
            .createBatch(name: "育肥批次", purpose: "育肥", startedAt: now, sheepIDs: [ids[0]], note: ""),
            .assignSheepToBatch(batchID: ids[8], sheepID: ids[0], joinedAt: now),
            .leaveBatch(batchID: ids[8], sheepID: ids[0], leftAt: now, reason: "完成"),
            .addIngredient(name: "玉米", unit: "kg", dryMatterText: "0.88"),
            .createRecipe(name: "育肥料", note: ""),
            .addRecipeComponent(recipeID: ids[9], ingredientID: ids[10], kilogramsText: "5"),
            .recordFeed(penID: ids[1], recipeID: ids[9], mode: .limited, occurredAt: now, lines: [.init(id: ids[11], ingredientID: ids[10], kilogramsText: "5")], note: ""),
            .recordHealth(sheepID: ids[0], penID: nil, kind: .treatment, itemName: "青霉素", occurredAt: now, note: "", inventoryLotID: ids[23], quantityText: "1"),
            .receiveInventory(catalogName: "青霉素", kind: .treatment, expiresAt: now, quantityText: "10", occurredAt: now, note: ""),
            .addSemen(code: "S-001", breed: "杜泊", source: "供应商", batchNumber: "B-1", quantityText: "10"),
            .recordReproduction(eweID: ids[0], kind: .lambing, occurredAt: now, sireID: ids[2], semenName: nil, result: "完成", lambCount: 1, parity: 2, birthDeadCount: 0, offspring: [.init(id: ids[12], sheepID: ids[13], earTag: "L-001", sex: .female, birthWeightText: "3.5")], note: ""),
            .addNote(sheepID: ids[0], penID: nil, text: "观察", occurredAt: now),
            .tombstoneEntity(entityType: .weight, entityID: ids[4], reason: "重复"),
            .restoreTombstonedEntity(tombstoneID: ids[14]),
        ] + careCommands.map(FarmCommand.care)

        XCTAssertEqual(commands.count, 49)
        for (index, command) in commands.enumerated() {
            let encoded = try FarmCommandCloudPayloadEncoder.encode(command)
            let decoded = try FarmCommandCloudPayloadDecoder.decode(encoded)
            XCTAssertEqual(
                try FarmCommandCloudPayloadEncoder.encode(decoded),
                encoded,
                "Codec mismatch at command index \(index): \(command.summary)"
            )
        }
    }

    func testCareActionSchemaDescribesEveryCareCommandCase() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-care-schema-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let agent = InsightAgentContext(
            accountID: UUID(),
            farmID: UUID(),
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try InsightToolRegistry().execute(
            .init(
                callID: "care-schema",
                name: "get_farm_action_schema",
                argumentsJSON: #"{"operation_kind":"care"}"#
            ),
            agent: agent,
            context: context
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        let payloadRoot = try XCTUnwrap(root["payload_root"] as? [String: Any])
        let careCommand = try XCTUnwrap(payloadRoot["careCommand"] as? [String: Any])
        let cases = try XCTUnwrap(careCommand["cases"] as? [String: Any])

        XCTAssertEqual(cases.count, 20)
        XCTAssertNotNil(cases["recordHealth"])
        XCTAssertNotNil(cases["recordLambing"])
        XCTAssertNotNil(cases["setReminderStatus"])
    }

    func testGenericFarmDraftDerivesHighRiskPolicyAndRejectsCrossFarmReference() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-generic-draft-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let firstFarmID = UUID()
        let secondFarmID = UUID()
        let firstSheep = SheepRecord(
            farmID: firstFarmID,
            earTag: "A-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let secondSheep = SheepRecord(
            farmID: secondFarmID,
            earTag: "B-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let firstWeight = WeightRecord(
            farmID: firstFarmID,
            sheepID: firstSheep.id,
            kilogramsText: "40",
            occurredAt: .now
        )
        let secondWeight = WeightRecord(
            farmID: secondFarmID,
            sheepID: secondSheep.id,
            kilogramsText: "41",
            occurredAt: .now
        )
        [firstSheep, secondSheep].forEach(context.insert)
        [firstWeight, secondWeight].forEach(context.insert)
        try context.save()

        let registry = InsightToolRegistry()
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: firstFarmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let command = FarmCommand.correctWeight(
            originalID: firstWeight.id,
            kilogramsText: "42",
            occurredAt: .now,
            note: "",
            reason: "录入错误"
        )
        let payloadText = String(decoding: try FarmCommandCloudPayloadEncoder.encode(command), as: UTF8.self)
        let callData = try JSONSerialization.data(withJSONObject: [
            "operation_kind": DomainOperationKind.correctWeight.rawValue,
            "payload_json": payloadText,
        ])
        let execution = try registry.execute(
            .init(
                callID: "draft",
                name: "draft_farm_command",
                argumentsJSON: String(decoding: callData, as: UTF8.self)
            ),
            agent: agent,
            context: context
        )
        let draft = try XCTUnwrap(execution.actionDraft)
        XCTAssertEqual(draft.risk, .high)
        XCTAssertEqual(draft.requiredCapability, .editHistoricalFacts)
        XCTAssertEqual(draft.expectedEntityID, firstWeight.id)
        XCTAssertEqual(draft.expectedRevision, firstWeight.revision)

        draft.riskRawValue = InsightActionRisk.normal.rawValue
        XCTAssertThrowsError(try registry.validate(draft, agent: agent, context: context))

        let crossFarmCommand = FarmCommand.correctWeight(
            originalID: secondWeight.id,
            kilogramsText: "43",
            occurredAt: .now,
            note: "",
            reason: "恶意跨场"
        )
        let crossFarmPayload = String(
            decoding: try FarmCommandCloudPayloadEncoder.encode(crossFarmCommand),
            as: UTF8.self
        )
        let crossFarmCall = try JSONSerialization.data(withJSONObject: [
            "operation_kind": DomainOperationKind.correctWeight.rawValue,
            "payload_json": crossFarmPayload,
        ])
        XCTAssertThrowsError(try registry.execute(
            .init(
                callID: "cross-farm",
                name: "draft_farm_command",
                argumentsJSON: String(decoding: crossFarmCall, as: UTF8.self)
            ),
            agent: agent,
            context: context
        )) { error in
            guard let insightError = error as? InsightToolError,
                  case .crossFarmReference = insightError else {
                return XCTFail("Expected crossFarmReference, got \(error)")
            }
        }
    }

    func testExtendedFarmRecordsRequireSingleCallDisclosureAndRemainFarmScoped() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-extended-data-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let otherFarmID = UUID()
        context.insert(NoteRecord(
            farmID: farmID,
            text: "当前牧场私密备注",
            occurredAt: .now
        ))
        context.insert(NoteRecord(
            farmID: otherFarmID,
            text: "其他牧场备注",
            occurredAt: .now
        ))
        try context.save()
        let registry = InsightToolRegistry()
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let from = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-86_400))
        let to = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(86_400))
        let arguments = #"{"category":"raw_notes","from":"\#(from)","to":"\#(to)","limit":10}"#
        let call = InsightFunctionCall(
            callID: "extended",
            name: "get_extended_farm_records",
            argumentsJSON: arguments
        )

        let disclosure = try XCTUnwrap(registry.extendedDataDisclosure(
            for: call,
            agent: agent,
            context: context
        ))
        XCTAssertEqual(disclosure.rowCount, 1)
        XCTAssertThrowsError(try registry.execute(call, agent: agent, context: context)) { error in
            guard let insightError = error as? InsightToolError,
                  case .extendedDataConsentRequired = insightError else {
                return XCTFail("Expected extendedDataConsentRequired, got \(error)")
            }
        }
        let result = try registry.execute(
            call,
            agent: agent,
            context: context,
            extendedDataAuthorized: true
        )
        XCTAssertTrue(result.output.contains("当前牧场私密备注"))
        XCTAssertFalse(result.output.contains("其他牧场备注"))
    }

    func testImageOptimizationRemovesGPSMetadata() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let sourceData = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            sourceData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2,
                kCGImagePropertyGPSLongitude: 121.5,
            ],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let optimized = try InsightImageOptimizer.optimize(sourceData as Data)
        let optimizedSource = try XCTUnwrap(CGImageSourceCreateWithData(
            optimized.data as CFData,
            nil
        ))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(optimizedSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertLessThanOrEqual(max(optimized.pixelWidth, optimized.pixelHeight), 1_600)
    }

    func testVoiceRetentionPreferenceDefaultsOffAndIsAccountScoped() throws {
        let suiteName = "insight-voice-privacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstAccountID = UUID()
        let secondAccountID = UUID()

        XCTAssertFalse(InsightVoicePrivacyPreference.retainsSentAudio(
            for: firstAccountID,
            defaults: defaults
        ))
        InsightVoicePrivacyPreference.setRetainsSentAudio(
            true,
            for: firstAccountID,
            defaults: defaults
        )

        XCTAssertTrue(InsightVoicePrivacyPreference.retainsSentAudio(
            for: firstAccountID,
            defaults: defaults
        ))
        XCTAssertFalse(InsightVoicePrivacyPreference.retainsSentAudio(
            for: secondAccountID,
            defaults: defaults
        ))
    }

    func testLocalVoiceStoreRoundTripsAndRemovesConversation() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "insight-audio-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = InsightLocalAudioStore(rootDirectory: rootDirectory)
        let accountID = UUID()
        let conversationID = UUID()
        let messageID = UUID()
        let audio = PendingInsightAudio(
            data: Data([0, 1, 2, 3, 4, 5]),
            mimeType: "audio/mp4",
            duration: 2.4,
            waveformSamples: [0.1, 0.5, 0.9]
        )

        try await store.save(
            audio,
            messageID: messageID,
            conversationID: conversationID,
            accountID: accountID
        )
        let loaded = try await store.load(
            messageID: messageID,
            conversationID: conversationID,
            accountID: accountID
        )

        XCTAssertEqual(loaded?.messageID, messageID)
        XCTAssertEqual(loaded?.pendingAudio, audio)

        try await store.removeConversation(
            conversationID: conversationID,
            accountID: accountID
        )
        let removed = try await store.load(
            messageID: messageID,
            conversationID: conversationID,
            accountID: accountID
        )
        XCTAssertNil(removed)
    }
}

private final class ScriptedMiMoResponder: MiMoResponding, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[InsightModelEvent]]
    private var requests: [MiMoConversationRequest] = []

    init(scripts: [[InsightModelEvent]]) {
        self.scripts = scripts
    }

    func stream(
        request: MiMoConversationRequest,
        credential: MiMoCredential
    ) -> AsyncThrowingStream<InsightModelEvent, Error> {
        let script: [InsightModelEvent]?
        lock.lock()
        requests.append(request)
        script = scripts.isEmpty ? nil : scripts.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            guard let script else {
                continuation.finish(throwing: MiMoClientError.invalidResponse)
                return
            }
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func validate(credential: MiMoCredential) async throws {}

    func capturedRequests() -> [MiMoConversationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class FlakyMiMoResponder: MiMoResponding, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [MiMoClientError]
    private let events: [InsightModelEvent]
    private var requests = 0

    init(failures: [MiMoClientError], events: [InsightModelEvent]) {
        self.failures = failures
        self.events = events
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stream(
        request: MiMoConversationRequest,
        credential: MiMoCredential
    ) -> AsyncThrowingStream<InsightModelEvent, Error> {
        let failure: MiMoClientError?
        lock.lock()
        requests += 1
        failure = failures.isEmpty ? nil : failures.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func validate(credential: MiMoCredential) async throws {}
}
