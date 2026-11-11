import Foundation
import XCTest
@testable import eSheepNext

final class InsightOpenAIProviderTests: XCTestCase {
    func testProviderSwitchCannotForwardAnotherServicesHistory() {
        XCTAssertTrue(InsightProvider.openai.acceptsHistory(providers: ["local", "openai"]))
        XCTAssertTrue(InsightProvider.mimo.acceptsHistory(providers: ["mimo", "local"]))
        XCTAssertFalse(InsightProvider.openai.acceptsHistory(providers: ["mimo"]))
        XCTAssertFalse(InsightProvider.mimo.acceptsHistory(providers: ["openai", "mimo"]))
    }
    @MainActor
    func testSelectedModelFromStatusReachesTurnAndRetiredModelRequiresReselection() throws {
        let data = Data(#"{"configured":true,"models":{"openai":"default"},"modelOptions":{"openai":["default","alternative"]},"consentVersion":"2026-11-05-agent-v1"}"#.utf8)
        let status = try JSONDecoder().decode(InsightAgentStatus.self, from: data)
        XCTAssertEqual(try status.model(for: .openai, saved: nil), "default")
        XCTAssertThrowsError(try status.model(for: .openai, saved: "retired"))
        XCTAssertThrowsError(try status.model(for: .mimo, saved: "alternative"))
        let model = try status.model(for: .openai, saved: "alternative")
        let body = try InsightServerAgentHarness.turnBody(provider: "openai", model: model,
            input: [["role": "user", "content": "查询"]], instructions: "", tools: [], limits: [:], thinkingEnabled: false)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "alternative")
    }

    func testOpenAIKeyUsesIndependentProviderAndModel() throws {
        let key = try MiMoCredential(openAIKey: "sk-test-not-a-real-key")
        XCTAssertEqual(key.kind, .openAI)
        XCTAssertEqual(key.modelName, "gpt-5.4")
        XCTAssertEqual(key.responsesURL.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertThrowsError(try MiMoCredential(openAIKey: "tp-mimo-plan-key"))
    }

    func testOpenAIRequestKeepsStatelessReasoningAndFunctionOutputs() throws {
        let record = MiMoReasoningRecord(id: "rs_test", text: "摘要", source: .openAI, encryptedContent: "test-encrypted-state")
        let exchange = MiMoFunctionExchange(call: .init(callID: "call_test", name: "find_sheep", argumentsJSON: "{}"), output: "{}", reasoningRecords: [record])
        let request = try MiMoClient().makeResponsesURLRequest(request: .init(instructions: "test", messages: [.init(role: .user, text: "查羊")], functionExchanges: [exchange]), credential: .init(openAIKey: "sk-test-not-a-real-key"), stream: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertEqual(object["model"] as? String, "gpt-5.4")
        XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.first(where: { $0["type"] as? String == "reasoning" })?["encrypted_content"] as? String, "test-encrypted-state")
        XCTAssertEqual(input.last?["type"] as? String, "function_call_output")
    }

    @MainActor
    func testCloudConsentIsAccountScopedAndCanBeRevoked() {
        let a = UUID(), b = UUID()
        defer { AgentServerConsent.setConsent(false, for: a); AgentServerConsent.setConsent(false, for: b) }
        XCTAssertFalse(AgentServerConsent.hasConsent(for: a))
        AgentServerConsent.setConsent(true, for: a)
        XCTAssertTrue(AgentServerConsent.hasConsent(for: a))
        XCTAssertFalse(AgentServerConsent.hasConsent(for: b))
        AgentServerConsent.setConsent(false, for: a)
        XCTAssertFalse(AgentServerConsent.hasConsent(for: a))
    }

    @MainActor
    func testServerUsageCountsTowardTheExistingBudget() throws {
        let budget = InsightRunBudget(configuration: .init(effort: .low))
        try budget.recordRemoteUsage(input: 100, output: 200)
        XCTAssertEqual(budget.snapshot.modelRequests, 1)
        XCTAssertEqual(budget.snapshot.inputTokens, 100)
        XCTAssertEqual(budget.snapshot.outputTokens, 200)
        XCTAssertThrowsError(try budget.recordRemoteUsage(input: 0, output: 100000))
    }
}
