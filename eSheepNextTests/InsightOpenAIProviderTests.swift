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
    func testSavedModelIsSentDirectlyToItsProvider() throws {
        let accountID = UUID()
        for provider in InsightProvider.allCases {
            let defaultModel = try provider.model(for: accountID)
            XCTAssertTrue(provider.availableModels.contains(defaultModel))
            let model = try XCTUnwrap(provider.availableModels.last)
            provider.selectModel(model, for: accountID)
            let credential = try provider == .openai ? MiMoCredential(openAIKey: "sk-test-not-a-real-key") : MiMoCredential(apiKey: "tp-test-not-a-real-key")
            let request = try MiMoClient().makeResponsesURLRequest(
                request: .init(model: provider.model(for: accountID), instructions: "", messages: [.init(role: .user, text: "读取图片")]),
                credential: credential, stream: true)
            XCTAssertEqual(request.url, credential.responsesURL)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, model)
            XCTAssertNil(request.value(forHTTPHeaderField: "x-assistant-api-key"))
            provider.selectModel("retired", for: accountID)
            XCTAssertThrowsError(try provider.model(for: accountID))
        }
    }

    func testGaugeEffortReachesTheSelectedModelAfterBudgeting() throws {
        let credential = try MiMoCredential(openAIKey: "sk-test-not-a-real-key")
        for model in InsightProvider.openai.availableModels {
            for effort in OpenAIReasoningEffort.options(for: model) {
                let turn = MiMoConversationRequest(model: model, instructions: "", messages: [],
                                                   openAIReasoningEffort: effort)
                let request = try MiMoClient().makeResponsesURLRequest(request: turn.withMaximumOutputTokens(600),
                                                                      credential: credential, stream: true)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(body["model"] as? String, model)
                XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], effort.rawValue)
            }
        }
    }

    func testSavedAndLegacyDepthResolveForTheSelectedModel() throws {
        let json = #"{"effort":"high","thinkingEnabled":false,"showReasoning":true}"#
        var configuration = try JSONDecoder().decode(InsightRunConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.openAIEffort(for: "gpt-6-luna"), .off)
        XCTAssertEqual(configuration.openAIEffort(for: "gpt-6.1-sol"), .low)
        configuration.openAIReasoningEffort = .maximum
        let restored = try JSONDecoder().decode(InsightRunConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.openAIEffort(for: "gpt-5.4"), .xhigh)
        XCTAssertEqual(restored.openAIEffort(for: "gpt-6-astra"), .maximum)
        XCTAssertFalse(restored.thinkingEnabled)
        XCTAssertEqual(restored.effort, .high)
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
        XCTAssertEqual(object["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(object["model"] as? String, "gpt-5.4")
        XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.first(where: { $0["type"] as? String == "reasoning" })?["encrypted_content"] as? String, "test-encrypted-state")
        XCTAssertEqual(input.last?["type"] as? String, "function_call_output")
    }

    @MainActor
    func testDirectOpenAIConsentIsAccountScopedAndCanBeRevoked() {
        let id = UUID()
        defer { OpenAIConsent.setConsent(false, for: id) }
        XCTAssertFalse(InsightProvider.openai.hasConsent(for: id))
        OpenAIConsent.setConsent(true, for: id)
        XCTAssertTrue(InsightProvider.openai.hasConsent(for: id))
        XCTAssertFalse(InsightProvider.openai.hasConsent(for: UUID()))
        OpenAIConsent.setConsent(false, for: id)
        XCTAssertFalse(InsightProvider.openai.hasConsent(for: id))
    }
}
