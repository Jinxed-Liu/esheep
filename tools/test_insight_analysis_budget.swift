import Foundation

private final class ScriptedMiMo: MiMoResponding, @unchecked Sendable {
    struct Reply { let events: [InsightModelEvent]; let error: MiMoClientError? }
    private let lock = NSLock()
    private var replies: [Reply]
    private var requests: [MiMoConversationRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func stream(request: MiMoConversationRequest, credential: MiMoCredential) -> AsyncThrowingStream<InsightModelEvent, Error> {
        lock.lock()
        requests.append(request)
        let reply = replies.isEmpty ? Reply(events: [], error: .invalidResponse) : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in reply.events { continuation.yield(event) }
            if let error = reply.error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
    }
    func validate(credential: MiMoCredential) async throws {}
    var capturedRequests: [MiMoConversationRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
}

private struct HangingMiMo: MiMoResponding {
    func stream(request: MiMoConversationRequest, credential: MiMoCredential) -> AsyncThrowingStream<InsightModelEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("已接收的临时内容"))
            // Deliberately omit any terminal response to exercise the real deadline.
        }
    }
    func validate(credential: MiMoCredential) async throws {}
}

@main
struct InsightAnalysisRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }
    private static func candidate(_ text: String) -> ScriptedMiMo.Reply {
        .init(events: [.textDelta(text), .completed(responseID: "candidate", usage: nil)], error: nil)
    }
    private static var acceptedReview: ScriptedMiMo.Reply {
        .init(events: [.functionCall(.init(callID: "review", name: "review_grounded_farm_answer",
             argumentsJSON: #"{"verdict":"accept","claim_scope":"general","evidence_sufficient":false,"issue":"","corrective_instruction":""}"#)),
            .completed(responseID: "review", usage: .init(inputTokens: 5, outputTokens: 10, totalTokens: 15))], error: nil)
    }
    static func snapshot(requests: Int = 0, rounds: Int = 0, output: Int = 0, active: Double = 0) -> InsightRunBudgetSnapshot {
        .init(modelRequests: requests, toolRoundTrips: rounds, outputTokens: output,
              inputTokens: 0, reasoningTokens: 0, activeSeconds: active, outputIsEstimated: false)
    }
    @MainActor static func consume(_ stream: AsyncThrowingStream<InsightModelEvent, Error>) async throws {
        for try await _ in stream {}
    }
    @MainActor static func pause(_ reason: InsightRunPause.Reason, _ action: () async throws -> Void) async throws {
        do { try await action(); throw Failure(description: "Expected budget pause \(reason)") }
        catch let value as InsightRunPause { try require(value.reason == reason, "Incorrect pause reason.") }
    }

    @MainActor static func main() async throws {
        let credential = try MiMoCredential(apiKey: "sk-portable-tests-only")
        let low = InsightRunConfiguration(effort: .low)
        let high = InsightRunConfiguration(effort: .high)
        try require(InsightRunConfiguration().effort == .medium, "Default effort must be medium.")
        try require(low.maximumToolRoundTrips == 4 && low.maximumModelRequests == 8 && low.additionalReviewCount == 0,
                    "Low workflow limits changed unexpectedly.")
        try require(high.maximumToolRoundTrips == 12 && high.maximumModelRequests == 24 && high.additionalReviewCount == 2,
                    "High workflow limits changed unexpectedly.")
        let defaults = UserDefaults(suiteName: "esheep-analysis-regression-\(UUID())")!
        let account = UUID(), otherAccount = UUID()
        InsightAnalysisPreference.save(high, for: account, defaults: defaults)
        try require(InsightAnalysisPreference.load(for: account, defaults: defaults) == high, "Preference did not round-trip.")
        try require(InsightAnalysisPreference.load(for: otherAccount, defaults: defaults).effort == .medium,
                    "Analysis preference leaked across accounts.")
        InsightAnalysisPreference.remove(for: account, defaults: defaults)
        print("PASS: three workflow levels and account-specific preferences")

        let roundBudget = InsightRunBudget(configuration: low)
        for _ in 0..<4 { try roundBudget.beginToolRoundTrip() }
        try await pause(.toolRoundTrips) { try roundBudget.beginToolRoundTrip() }
        let request = MiMoConversationRequest(instructions: "test", messages: [], maximumOutputTokens: 8_192)
        let noNetwork = ScriptedMiMo([])
        let exhausted = InsightRunBudget(configuration: low, initialSnapshot: snapshot(requests: 8))
        try await pause(.modelRequests) {
            try await consume(exhausted.stream(client: noNetwork, request: request, credential: credential))
        }
        let outputExhausted = InsightRunBudget(configuration: low, initialSnapshot: snapshot(output: 32_700))
        try await pause(.outputTokens) {
            try await consume(outputExhausted.stream(client: noNetwork, request: request, credential: credential))
        }
        let timeExhausted = InsightRunBudget(configuration: low, initialSnapshot: snapshot(active: 121))
        try await pause(.activeTime) { try timeExhausted.checkActiveTime() }
        try require(noNetwork.capturedRequests.isEmpty, "Exhausted budget invoked the provider.")
        print("PASS: tool/request/output/time exhaustion stops before provider or tool use")

        let usage = InsightTokenUsage(inputTokens: 100, outputTokens: 500, totalTokens: 600, reasoningTokens: 200)
        let measured = ScriptedMiMo([.init(events: [.reasoningDelta("observed"), .usage(usage), .completed(responseID: "m", usage: usage)], error: nil)])
        let measuredBudget = InsightRunBudget(configuration: low)
        try await consume(measuredBudget.stream(client: measured, request: request, credential: credential))
        try require(measuredBudget.outputTokens == 500 && measuredBudget.reasoningTokens == 200 && measuredBudget.inputTokens == 100,
                    "Reported output usage counted reasoning or terminal usage twice.")
        try require(!measuredBudget.snapshot.outputIsEstimated, "Reported usage was labeled estimated.")
        let missingUsage = ScriptedMiMo([.init(events: [.reasoningRecorded(.init(id: "reason", text: "真实返回的思考"))], error: .networkUnavailable)])
        let failedBudget = InsightRunBudget(configuration: low)
        do { try await consume(failedBudget.stream(client: missingUsage, request: request, credential: credential)) }
        catch MiMoClientError.networkUnavailable {}
        try require(failedBudget.modelRequests == 1 && failedBudget.outputTokens > 0 && failedBudget.snapshot.outputIsEstimated,
                    "Failed attempt omitted its request or recorded reasoning from estimated usage.")
        let nearLimit = InsightRunBudget(configuration: low, initialSnapshot: snapshot(output: 32_768 - 256))
        let bounded = ScriptedMiMo([.init(events: [.completed(responseID: nil, usage: nil)], error: nil)])
        try await consume(nearLimit.stream(client: bounded, request: request, credential: credential))
        try require(bounded.capturedRequests[0].maximumOutputTokens == 256, "Request bypassed remaining output allowance.")
        print("PASS: real usage, missing-usage failure charge and remaining output cap")

        let clockBudget = InsightRunBudget(configuration: low)
        clockBudget.pauseActiveClock()
        let pausedSeconds = clockBudget.activeSeconds
        try await Task.sleep(for: .milliseconds(20))
        try require(clockBudget.activeSeconds == pausedSeconds, "Waiting consumed active runtime budget.")
        clockBudget.resumeActiveClock()
        try await Task.sleep(for: .milliseconds(20))
        try require(clockBudget.activeSeconds > pausedSeconds && clockBudget.modelRequests == 0,
                    "Resume failed to restart the active clock or replenished request counters.")
        print("PASS: confirmation wait pauses clock without replenishing usage")

        let deadlineBudget = InsightRunBudget(configuration: low, initialSnapshot: snapshot(active: 119.9))
        do {
            try await consume(deadlineBudget.stream(client: HangingMiMo(), request: request, credential: credential))
            throw Failure(description: "A nonterminal stream bypassed the active deadline.")
        } catch let value as InsightRunPause {
            try require(value.reason == .activeTime && value.snapshot.outputTokens > 0 && value.snapshot.modelRequests == 1 && value.snapshot.outputIsEstimated,
                        "Deadline pause lost received output or request charge before checkpointing.")
        }
        print("PASS: real active deadline interrupts a hanging stream after charging received content")

        for configuration in [low, high] {
            let replies = [candidate("general answer")] + Array(repeating: acceptedReview, count: 1 + configuration.additionalReviewCount)
            let client = ScriptedMiMo(replies)
            let budget = InsightRunBudget(configuration: configuration)
            let result = try await InsightAgentHarness(client: client).run(
                model: MiMoCredential.model, instructions: "test", messages: [], tools: [], credential: credential,
                execute: { _ in .init(output: "unused", succeeded: false) },
                reviewCandidate: { text, exchanges, tools in
                    let review = try await InsightGroundedAnswerReviewer.review(question: "general question", candidate: text,
                        exchanges: exchanges, successfulToolNames: tools, model: MiMoCredential.model,
                        credential: credential, client: client, budget: budget)
                    return review.isAccepted ? .accept : .retry(review.issue)
                }, resolveRejectedCandidate: { _, _, _, _ in "safe fallback" },
                configuration: configuration, budget: budget)
            try require(result.text == "general answer", "Verified candidate changed.")
            try require(client.capturedRequests.count == 2 + configuration.additionalReviewCount && budget.modelRequests == client.capturedRequests.count,
                        "Mandatory/extra reviewers bypassed shared request allowance.")
            try require(client.capturedRequests.dropFirst().allSatisfy { !$0.thinkingEnabled },
                        "Mandatory reviewer spent its output allowance on thinking.")
        }
        print("PASS: low/high mandatory reviewers, extra reviews and thinking-off shared accounting")

        let budgetBeforeReview = InsightRunBudget(configuration: low, initialSnapshot: snapshot(requests: 7))
        let rawCandidate = ScriptedMiMo([candidate("unreviewed farm claim")])
        try await pause(.modelRequests) {
            _ = try await InsightAgentHarness(client: rawCandidate).run(
                model: MiMoCredential.model, instructions: "test", messages: [], tools: [], credential: credential,
                execute: { _ in .init(output: "unused", succeeded: false) },
                reviewCandidate: { text, exchanges, tools in
                    let review = try await InsightGroundedAnswerReviewer.review(question: "farm question", candidate: text,
                        exchanges: exchanges, successfulToolNames: tools, model: MiMoCredential.model,
                        credential: credential, client: rawCandidate, budget: budgetBeforeReview)
                    return review.isAccepted ? .accept : .retry(review.issue)
                }, resolveRejectedCandidate: { _, _, _, _ in "safe fallback" }, configuration: low, budget: budgetBeforeReview)
        }
        try require(rawCandidate.capturedRequests.count == 1, "Unreviewed candidate triggered a bypass request.")
        print("PASS: no candidate released when mandatory review cannot fit budget")

        let completionClaim = #"{"analysis":"尚缺云端回执，不能确认完成","completed":true,"remaining":[]}"#
        let pendingClaim = #"{"analysis":"需要确认缺少字段","stepCompleted":false,"remaining":["云端回执"]}"#
        let evidenceCall = InsightFunctionCall(callID: "state", name: "query", argumentsJSON: "{}")
        let successEvidence = MiMoFunctionExchange(call: evidenceCall, output: "权威状态已核验", succeeded: true)
        let failedEvidence = MiMoFunctionExchange(call: evidenceCall, output: "failed", succeeded: false)
        let workflowBudget = InsightRunBudget(configuration: high)
        for (scope, sufficient, candidateJSON, evidence, flag, expected) in [
            ("general", false, completionClaim, [successEvidence], true, false),
            ("clarification", false, completionClaim, [successEvidence], true, false),
            ("farm_specific", true, completionClaim, [failedEvidence], true, false),
            ("farm_specific", true, completionClaim, [successEvidence], true, true),
            ("clarification", false, pendingClaim, [failedEvidence], true, true),
            ("general", false, completionClaim, [], false, true),
        ] {
            let verdict = """
            {"verdict":"accept","claim_scope":"\(scope)","evidence_sufficient":\(sufficient),"issue":"","corrective_instruction":""}
            """
            let reviewer = ScriptedMiMo([.init(events: [.functionCall(.init(callID: "review", name: "review_grounded_farm_answer", argumentsJSON: verdict)), .completed(responseID: "review", usage: nil)], error: nil)])
            let review = try await InsightGroundedAnswerReviewer.review(question: "核验步骤与云端回执",
                candidate: candidateJSON, exchanges: evidence, successfulToolNames: ["query"],
                model: MiMoCredential.model, credential: credential, client: reviewer,
                workflowEvaluation: flag, budget: workflowBudget)
            try require(review.isAccepted == expected, "Workflow completion grounding accepted an unsupported flag or rejected pending work.")
            let sent = reviewer.capturedRequests[0]
            try require(sent.messages[0].text.contains(candidateJSON), "Reviewer discarded workflow JSON fields before reviewing.")
            try require(!sent.thinkingEnabled, "Workflow reviewer bypassed thinking-off policy.")
            if flag {
                try require(sent.instructions.contains("stepCompleted=true") && sent.instructions.contains("云端回执"), "Workflow review instruction did not reach real provider request.")
            }
        }
        try require(workflowBudget.modelRequests == 6, "Workflow reviewers bypassed shared request accounting.")
        let longClaim = "{\"analysis\":\"" + String(repeating: "完整材料A", count: 8_000) + "\",\"completed\":false,\"remaining\":[\"未核验尾部TAIL_CRITERION\"]}"
        for workflowEvaluation in [false, true] {
            let longReviewer = ScriptedMiMo([acceptedReview])
            _ = try await InsightGroundedAnswerReviewer.review(question: "完整核验条件",
                candidate: longClaim, exchanges: [successEvidence], successfulToolNames: ["query"],
                model: MiMoCredential.model, credential: credential, client: longReviewer,
                workflowEvaluation: workflowEvaluation, budget: workflowBudget)
            let longRequest = longReviewer.capturedRequests[0]
            try require(longRequest.messages.map(\.text).joined().contains(longClaim), "Reviewer discarded or altered full candidate content.")
            let longWire = MiMoClientWire()
            for body in [
                try longWire.makeResponsesURLRequest(request: longRequest, credential: credential, stream: true).httpBody!,
                try longWire.makeChatURLRequest(request: longRequest, credential: credential).httpBody!,
            ] {
                let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                let sentMessages = (object["input"] ?? object["messages"]) as! [[String: Any]]
                let encodedText = try JSONSerialization.data(withJSONObject: sentMessages, options: [.withoutEscapingSlashes])
                try require(String(decoding: encodedText, as: UTF8.self).contains("TAIL_CRITERION"), "Real wire dropped the final completion or ordinary answer field.")
            }
        }
        let omittedEvidence = MiMoFunctionExchange(call: evidenceCall,
            output: String(repeating: "whole-json-evidence;", count: 10_000), succeeded: true)
        let incompleteReviewer = ScriptedMiMo([.init(events: [.functionCall(.init(callID: "review", name: "review_grounded_farm_answer",
            argumentsJSON: #"{"verdict":"accept","claim_scope":"farm_specific","evidence_sufficient":true,"issue":"","corrective_instruction":""}"#)),
            .completed(responseID: "review", usage: nil)], error: nil)])
        let incompleteReview = try await InsightGroundedAnswerReviewer.review(question: "核验全部完成条件",
            candidate: completionClaim, exchanges: [omittedEvidence], successfulToolNames: ["query"],
            model: MiMoCredential.model, credential: credential, client: incompleteReviewer,
            workflowEvaluation: true, budget: workflowBudget)
        try require(!incompleteReview.isAccepted && incompleteReviewer.capturedRequests[0].messages[0].text.contains("复核材料不完整"),
                    "Omitted whole evidence packets incorrectly proved complete workflow success.")
        print("PASS: full workflow review rejects ungrounded completion and failed evidence while preserving pending work")

        let firstCall = InsightFunctionCall(callID: "one", name: "query", argumentsJSON: "{}")
        let secondCall = InsightFunctionCall(callID: "two", name: "query", argumentsJSON: "{}")
        let checkpointClient = ScriptedMiMo([.init(events: [.functionCall(firstCall), .functionCall(secondCall), .completed(responseID: "tool-turn", usage: nil)], error: nil)])
        var executed: [String] = []
        do {
            _ = try await InsightAgentHarness(client: checkpointClient).run(
                model: MiMoCredential.model, instructions: "test", messages: [], tools: [], credential: credential,
                execute: { call in executed.append(call.callID); return .init(output: "result", succeeded: true) },
                reviewCandidate: { _, _, _ in .accept }, resolveRejectedCandidate: { _, _, _, _ in "safe fallback" },
                configuration: low, onCheckpoint: { _ in throw Failure(description: "checkpoint write failed") })
            throw Failure(description: "Checkpoint failure did not stop subsequent calls.")
        } catch let error as Failure {
            try require(error.description == "checkpoint write failed", "Unexpected checkpoint failure.")
        }
        try require(executed == ["one"], "Second call executed before first checkpoint was durably saved.")
        let replayClient = ScriptedMiMo([candidate("answer")])
        let failedExchange = MiMoFunctionExchange(call: firstCall, output: "failed", succeeded: false)
        let replay = try await InsightAgentHarness(client: replayClient).run(
            model: MiMoCredential.model, instructions: "test", messages: [], tools: [], credential: credential,
            initialExchanges: [failedExchange], execute: { _ in .init(output: "unused", succeeded: false) },
            reviewCandidate: { _, _, successful in
                try require(!successful.contains("query"), "Failed resumed exchange became grounding evidence.")
                return .accept
            }, resolveRejectedCandidate: { _, _, _, _ in "safe fallback" }, configuration: low)
        try require(replay.successfulToolNames.isEmpty, "Failed replay tool leaked into success set.")
        print("PASS: durable checkpoint before next tool and failed replay remains ungrounded")

        try wireAndParserChecks(credential: credential)
        print("Analysis/harness regression passed: 10 behavioral checks; fixture model streams and production wire/parsers only.")
    }

    @MainActor static func wireAndParserChecks(credential: MiMoCredential) throws {
        let selectedText = String(repeating: "selected-evidence;", count: 10_000) + "SELECTED_RANGE_TAIL"
        let longInstructions = String(repeating: "instruction;", count: 3_000) + "INSTRUCTION_TAIL"
        let selectionRequest = MiMoConversationRequest(instructions: longInstructions,
            messages: [.init(role: .user, text: selectedText)], maximumOutputTokens: 8_192)
        let selectionWire = MiMoClientWire()
        for body in [
            try selectionWire.makeResponsesURLRequest(request: selectionRequest, credential: credential, stream: true).httpBody!,
            try selectionWire.makeChatURLRequest(request: selectionRequest, credential: credential).httpBody!,
        ] {
            let sent = String(decoding: body, as: UTF8.self)
            try require(sent.contains("SELECTED_RANGE_TAIL") && sent.contains("INSTRUCTION_TAIL"),
                        "Selected document ranges or instructions were silently clipped on the real wire.")
        }
        do {
            _ = try MiMoClientWire.requestBody(["oversized": String(repeating: "x", count: 65 * 1_024 * 1_024)])
            throw Failure(description: "Oversized body was silently accepted.")
        } catch let error as MiMoClientError {
            if case .requestTooLarge(let maximum) = error {
                try require(maximum == 64 * 1_024 * 1_024 && !error.isAutomaticallyRecoverable,
                            "Complete request limit has incorrect typed failure or retry semantics.")
            } else { throw error }
        }
        let reasoning = MiMoReasoningRecord(id: "reason-1", text: "完整实际思考", contentTexts: ["完整", "实际思考"])
        let exchanges = ["one", "two"].map { identifier in
            MiMoFunctionExchange(call: .init(callID: identifier, name: "query", argumentsJSON: "{}"),
                output: "result", reasoningRecords: [reasoning], assistantTurnID: "same-turn", assistantText: "provisional")
        }
        let request = MiMoConversationRequest(instructions: "test", messages: [.init(role: .user, text: "question")],
            functionExchanges: exchanges, maximumOutputTokens: 8_192, thinkingEnabled: true)
        let wire = MiMoClientWire()
        let responses = try JSONSerialization.jsonObject(with: wire.makeResponsesURLRequest(request: request, credential: credential, stream: true).httpBody!) as! [String: Any]
        let input = responses["input"] as! [[String: Any]]
        let inputTypes = input.map { ($0["type"] as? String) ?? ($0["role"] == nil ? "unknown" : "message") }
        try require(inputTypes == ["message", "reasoning", "function_call", "function_call", "function_call_output", "function_call_output"],
                    "Responses reasoning and multi-call turn order was not replayable.")
        try require((responses["reasoning"] as? [String: String])?["effort"] == "high", "Native MiMo thinking was disabled.")
        let chat = try JSONSerialization.jsonObject(with: wire.makeChatURLRequest(request: request, credential: credential).httpBody!) as! [String: Any]
        let assistants = (chat["messages"] as! [[String: Any]]).filter { $0["role"] as? String == "assistant" }
        try require(assistants.count == 1 && (assistants[0]["tool_calls"] as? [Any])?.count == 2,
                    "One assistant tool turn was split into incompatible messages.")
        try require(assistants[0]["reasoning_content"] as? String == reasoning.text, "Chat reasoning was omitted or truncated.")
        let responseDelta = try MiMoSSEParser.parse(line: #"data: {"type":"response.reasoning_text.delta","delta":"思考"}"#)
        try require(responseDelta == .reasoningDelta("思考"),
                    "Responses reasoning delta was not parsed.")
        var parser = MiMoChatSSEParser()
        let reasoningEvents = try parser.parse(line: #"data: {"id":"chat-1","choices":[{"delta":{"reasoning_content":"真实思考"},"finish_reason":null}]}"#)
        try require(reasoningEvents.contains(.reasoningDelta("真实思考")), "Chat reasoning delta missing.")
        _ = try parser.parse(line: #"data: {"id":"chat-1","choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}"#)
        let usageEvents = try parser.parse(line: #"data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":11,"total_tokens":18,"completion_tokens_details":{"reasoning_tokens":5}}}"#)
        try require(usageEvents.contains(.usage(.init(inputTokens: 7, outputTokens: 11, totalTokens: 18, reasoningTokens: 5))),
                    "Usage after terminal chat delta was lost.")
        _ = try parser.finishStream()
        var incomplete = MiMoChatSSEParser()
        _ = try incomplete.parse(line: #"data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}"#)
        do { _ = try incomplete.finishStream(); throw Failure(description: "Truncated stream accepted.") }
        catch MiMoClientError.invalidResponse {}
        print("PASS: real reasoning replay, multi-call wire order, stream reasoning/usage and truncated-stream rejection")
    }
}
