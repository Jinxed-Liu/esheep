import XCTest
@testable import eSheepNext

final class InsightPublicProcessTests: XCTestCase {
    func testPublicStepsRemoveSchedulingReasoningAndDuplicateReviews() {
        let records = [
            record("准备分析", detail: "等待可用任务名额"), record("准备请求"),
            record("模型思考", detail: "PRIVATE_PROVIDER_REASONING", kind: .reasoning),
            record("get_farm_entities", kind: .tool, callID: "batch"),
            record("整理结果"), record("复核答案"), record("答案复核"), record("额外复核 2"),
        ]
        let exchange = InsightPublicProcess.compactExchange(
            call: call("batch", "get_farm_entities", #"{"category":"production_batches","query":"第八批"}"#),
            output: #"{"returned_count":1,"rows":[{"id":"b8","name":"第八批","private_note":"PRIVATE_ROW"}]}"#,
            succeeded: true
        )
        let steps = InsightPublicProcess.steps(records: records, exchanges: [exchange], isCompleted: true)
        XCTAssertEqual(steps.map(\.title), ["核对生产批次", "核对分析结果", "生成答复"])
        XCTAssertTrue(steps[0].detail.contains("第八批"))
        XCTAssertTrue(steps[0].detail.contains("已读取 1 个生产批次"))
        XCTAssertFalse(steps.description.contains("PRIVATE"))
        XCTAssertFalse(steps.description.contains("get_farm_entities"))
        XCTAssertTrue(exchange.reasoningRecords.isEmpty)
        XCTAssertTrue(exchange.assistantText.isEmpty)
    }

    func testCalculationSummarizesActualBatchPensDatesSamplesAndCrossPenEvidence() throws {
        let batch = InsightPublicProcess.compactExchange(
            call: call("batch", "get_farm_entities", #"{"category":"production_batches","query":"第八批"}"#),
            output: #"{"returned_count":1,"rows":[{"id":"b8","name":"第八批"}]}"#, succeeded: true
        )
        let calculation = InsightPublicProcess.compactExchange(
            call: call("calc", "calculate_farm_data", #"{"source":"weight_samples","transform":"difference_per_day","batch_id":"b8"}"#),
            output: #"{"canonical_arguments":{"source":"weight_samples","transform":"difference_per_day","batch_id":"b8","pen_names":["大棚一舍","大棚四舍","大棚十二舍","大棚十三舍","大棚十四舍","大棚十五舍"],"date_from":"2026-08-31T16:00:00.000Z","date_to":"2026-10-03T15:59:59.000Z"},"time_zone":"Asia/Shanghai","analyzed_profile_count":85,"observation_count":180,"cross_pen_interval_count":7,"is_complete":false,"excluded_insufficient_sample_profiles":2,"answer_markdown":"PRIVATE_FULL_ANSWER"}"#,
            succeeded: true
        )
        let steps = InsightPublicProcess.steps(records: [record("calculate_farm_data", kind: .tool, callID: "calc")], exchanges: [batch, calculation], isCompleted: false)
        let step = try XCTUnwrap(steps.first)
        XCTAssertEqual(step.title, "计算日增重")
        for expected in ["6 个圈舍", "大棚十五舍", "生产批次：第八批", "2026-09-01 至 2026-10-03", "85 只羊、180 个有效区间", "7 个跨舍区间", "2 只羊缺少成对称重"] {
            XCTAssertTrue(step.detail.contains(expected), expected)
        }
        XCTAssertFalse(step.detail.contains("PRIVATE_FULL_ANSWER"))
        XCTAssertFalse(step.detail.contains("b8"))
    }

    func testRunningAndFailedToolsCannotClaimOutputCountsAndUnknownNamesStayChinese() {
        let exchange = InsightPublicProcess.compactExchange(
            call: call("calc", "calculate_farm_data", #"{"transform":"difference_per_day","pen_names":["大棚一舍"]}"#),
            output: #"{"analyzed_profile_count":85,"observation_count":180}"#, succeeded: true
        )
        for state in [InsightRuntimeRecord.State.running, .failed] {
            let steps = InsightPublicProcess.steps(records: [record("calculate_farm_data", kind: .tool, callID: "calc", state: state)], exchanges: [exchange], isCompleted: false)
            XCTAssertTrue(steps.first?.detail.contains("大棚一舍") == true)
            XCTAssertFalse(steps.first?.detail.contains("85") == true)
            XCTAssertFalse(steps.first?.detail.contains("180") == true)
        }
        let unknown = InsightPublicProcess.steps(records: [record("internal_future_tool", kind: .tool)], exchanges: [], isCompleted: false)
        XCTAssertEqual(unknown.first?.title, "读取牧场资料")
    }

    func testCurrentStepUsesPublicAnalysisStateBeforeAndAfterActualToolWork() throws {
        let preparing = [record("准备请求", state: .running)]
        let firstStep = try XCTUnwrap(InsightPublicProcess.currentStep(records: preparing, steps: []))
        XCTAssertEqual(firstStep.title, "正在理解你的问题")
        XCTAssertEqual(firstStep.state, .running)
        XCTAssertTrue(firstStep.detail.isEmpty)

        let exchange = InsightPublicProcess.compactExchange(
            call: call("weights", "query_farm_data", #"{"query_kind":"weight_records","pen_name":"大棚一舍"}"#),
            output: #"{"total_matching_count":17}"#, succeeded: true
        )
        let records = [
            record("query_farm_data", kind: .tool, callID: "weights"),
            record("模型处理中", state: .running),
            record("模型思考", detail: "PRIVATE_PROVIDER_REASONING", kind: .reasoning, state: .running),
        ]
        let steps = InsightPublicProcess.steps(records: records, exchanges: [exchange], isCompleted: false)
        let current = try XCTUnwrap(InsightPublicProcess.currentStep(records: records, steps: steps))
        XCTAssertEqual(current.title, "结合已读取的数据分析")
        XCTAssertTrue(current.detail.contains("大棚一舍"))
        XCTAssertTrue(current.detail.contains("17 条记录"))
        XCTAssertFalse(current.detail.contains("PRIVATE_PROVIDER_REASONING"))
        XCTAssertFalse(steps.contains { $0.id == current.id })
    }

    func testWeightRecordQueryAndAsOfOnlyUseActualFieldsWithoutInventingDateRange() throws {
        let exchange = InsightPublicProcess.compactExchange(
            call: call("weights", "query_farm_data", #"{"query_kind":"weight_records","as_of":"2026-10-02T16:00:00.000Z"}"#),
            output: #"{"canonical_arguments":{"query_kind":"weight_records","as_of":"2026-10-02T16:00:00.000Z"},"time_zone":"Asia/Shanghai","total_matching_count":17}"#, succeeded: true
        )
        let steps = InsightPublicProcess.steps(records: [record("query_farm_data", kind: .tool, callID: "weights")], exchanges: [exchange], isCompleted: false)
        let step = try XCTUnwrap(steps.first)
        XCTAssertEqual(step.title, "读取称重记录")
        XCTAssertTrue(step.detail.contains("数据截止：2026-10-03"))
        XCTAssertTrue(step.detail.contains("17 条记录"))
        XCTAssertFalse(step.detail.contains("日期："))
    }

    func testCompletedProcessEvidenceRemainsAssociatedWithItsMessageAndOldRuntimeDecodes() throws {
        let firstMessageID = UUID()
        let secondMessageID = UUID()
        var runtime = InsightConversationRuntime(accountID: UUID(), farmID: UUID(), conversationID: UUID())
        runtime.processExchangesByMessageID = [firstMessageID: [InsightPublicProcess.compactExchange(call: call("one", "get_farm_entities", #"{"category":"pens"}"#))]]
        runtime.turn = InsightTurnCheckpoint(requestID: UUID(), userMessageID: nil, assistantMessageID: secondMessageID, text: "第二条", mode: .conversation, configuration: .init(), goalID: nil, isGoalVerification: false)
        let data = try JSONEncoder().encode(runtime)
        let restored = try JSONDecoder().decode(InsightConversationRuntime.self, from: data)
        XCTAssertEqual(restored.processExchangesByMessageID?[firstMessageID]?.first?.call.callID, "one")
        XCTAssertNil(restored.processExchangesByMessageID?[secondMessageID])
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldJSON.removeValue(forKey: "processExchangesByMessageID")
        let old = try JSONDecoder().decode(InsightConversationRuntime.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(old.processExchangesByMessageID)
    }

    private func record(_ title: String, detail: String = "", kind: InsightRuntimeRecord.Kind = .status, callID: String? = nil, state: InsightRuntimeRecord.State = .completed) -> InsightRuntimeRecord {
        InsightRuntimeRecord(title: title, detail: detail, state: state, kind: kind, callID: callID)
    }

    private func call(_ id: String, _ name: String, _ arguments: String) -> InsightFunctionCall {
        InsightFunctionCall(callID: id, name: name, argumentsJSON: arguments)
    }
}
