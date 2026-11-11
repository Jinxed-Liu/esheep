import Foundation
import Supabase

struct InsightAgentStatus: Decodable {
    let configured: Bool
    let models: [String: String]
    let modelOptions: [String: [String]]
    let consentVersion: String

    func model(for provider: InsightProvider, saved: String?) throws -> String {
        guard configured, consentVersion == AgentServerConsent.version else {
            throw InsightServerAgentError("助手服务或数据处理说明已更新，请检查 App 更新后重试。")
        }
        guard let choice = saved ?? models[provider.rawValue],
              modelOptions[provider.rawValue]?.contains(choice) == true else {
            throw InsightServerAgentError("所选模型已不可用，请在 AI 助手设置中重新选择。")
        }
        return choice
    }
}

/// Runs the shared Responses agent on the eSheep service. Supabase reads happen
/// there using the current user's JWT; native draft/device tools stay local.
@MainActor
struct InsightServerAgentHarness {
    let accountID: UUID
    let farmID: UUID
    private static let endpoint = URL(string: "https://app.esheepplus.com/api/assistant/agent/turn")!

    private struct Failure: Decodable {
        let error: String?
        let message: String?
    }

    static func turnBody(provider: String, model: String, input: [[String: Any]], instructions: String,
                         tools: [[String: Any]], limits: [String: Int], thinkingEnabled: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "provider": provider, "model": model, "input": input, "instructions": instructions,
            "thinkingEnabled": thinkingEnabled, "clientTools": tools, "limits": limits
        ])
    }

    private func request(for endpoint: URL) async throws -> URLRequest {
        guard let client = AccountIdentityClients.supabaseClient,
              let metadata = SecureAccountStore.supabaseSession(), metadata.accountID == accountID else {
            throw InsightServerAgentError("请先登录当前牧场账号。")
        }
        let auth = try await client.auth.session
        try Task.checkCancellation()
        guard auth.user.id == metadata.authUserID, SecureAccountStore.supabaseSession()?.accountID == accountID else {
            throw CancellationError()
        }
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "farm_id", value: farmID.uuidString.lowercased())]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "authorization")
        return request
    }

    private static func httpFailure(_ data: Data, status: Int) -> InsightServerAgentError {
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        if let message = failure?.error ?? failure?.message { return InsightServerAgentError(message) }
        switch status {
        case 401: return InsightServerAgentError("登录状态已失效，请重新登录。")
        case 403: return InsightServerAgentError("当前账号无权访问此牧场，请检查牧场权限。")
        case 429, 503: return InsightServerAgentError("助手暂时繁忙，请稍后手动重试。")
        default: return InsightServerAgentError("助手连接失败，请检查网络后手动重试。")
        }
    }

    func status() async throws -> InsightAgentStatus {
        var request = try await request(for: Self.endpoint.deletingLastPathComponent().appending(path: "status"))
        request.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral, delegate: InsightAgentRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.httpFailure(data, status: status) }
        return try JSONDecoder().decode(InsightAgentStatus.self, from: data)
    }

    private struct Event: Decodable {
        let type: String
        let message: String?
        let text: String?
        let needsUserInput: Bool?
        let model: String?
        let exchanges: [MiMoFunctionExchange]?
        let exchange: MiMoFunctionExchange?
        let clientCalls: [Call]?
        let continuation: [JSONValue]?
        let inputTokens: Int?
        let outputTokens: Int?
        struct Call: Decodable {
            let call_id: String
            let name: String
            let arguments: String
        }
    }

    func run(
        model: String, instructions: String, messages: [MiMoInputMessage], tools: [InsightToolDefinition],
        credential: MiMoCredential, initialExchanges: [MiMoFunctionExchange],
        execute: (InsightFunctionCall) async -> InsightAgentHarness.ToolObservation,
        budget: InsightRunBudget,
        onEvent: @escaping @MainActor (InsightHarnessEvent) -> Void,
        onCheckpoint: @MainActor ([MiMoFunctionExchange]) async throws -> Void
    ) async throws -> InsightAgentHarness.Result {
        guard AgentServerConsent.hasConsent(for: accountID) else {
            throw InsightServerAgentError("请登录当前账号，并在 AI 助手设置中同意云端 Agent 数据处理说明。")
        }
        let provider = credential.kind == .openAI ? "openai" : "mimo"
        let clientTools = tools.filter {
            $0.name.hasPrefix("draft_") || $0.name == "get_farm_action_schema" || $0.name == "create_farm_export"
        }
        let request = MiMoConversationRequest(model: model, instructions: instructions,
            messages: messages, functionExchanges: initialExchanges, tools: clientTools)
        let providerRequest = try MiMoClient().makeResponsesURLRequest(request: request, credential: credential, stream: true)
        guard let data = providerRequest.httpBody,
              let original = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var input = original["input"] as? [[String: Any]] else { throw InsightServerAgentError("无法构造助手上下文。") }
        // Compressed historical summaries are data, not server instructions.
        input = input.map { item in
            var copy = item
            if copy["role"] as? String == "system" { copy["role"] = "user" }
            return copy
        }
        var exchanges = initialExchanges
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 260
        configuration.timeoutIntervalForResource = 300
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: InsightAgentRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for _ in 0..<6 {
            try Task.checkCancellation()
            try budget.checkActiveTime()
            let remainingRequests = budget.configuration.maximumModelRequests - budget.snapshot.modelRequests
            let remainingOutput = budget.configuration.maximumOutputTokens - budget.snapshot.outputTokens
            let remainingTools = max(0, budget.configuration.maximumToolRoundTrips - budget.snapshot.toolRoundTrips)
            guard remainingRequests > 0, remainingOutput >= 128 else {
                throw InsightRunPause(reason: remainingRequests <= 0 ? .modelRequests : .outputTokens, snapshot: budget.snapshot)
            }
            guard SecureAccountStore.supabaseSession()?.accountID == accountID,
                  AgentServerConsent.hasConsent(for: accountID) else { throw CancellationError() }
            var urlRequest = try await self.request(for: Self.endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "x-assistant-api-key")
            urlRequest.setValue(AgentServerConsent.version, forHTTPHeaderField: "x-agent-consent")
            urlRequest.httpBody = try Self.turnBody(provider: provider, model: model, input: input,
                instructions: instructions, tools: original["tools"] as? [[String: Any]] ?? [],
                limits: ["modelRequests": remainingRequests, "outputTokens": remainingOutput,
                         "toolCalls": remainingTools, "additionalReviews": budget.configuration.additionalReviewCount],
                thinkingEnabled: budget.configuration.thinkingEnabled)
            guard (urlRequest.httpBody?.count ?? 0) <= 18 * 1_024 * 1_024 else { throw InsightServerAgentError("上下文过长，请新建会话或减少附件。") }
            onEvent(.phase(.preparing))
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.value(forHTTPHeaderField: "content-type")?.contains("application/x-ndjson") == true else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 8192 { break }
                }
                throw Self.httpFailure(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            var result: Event?
            var receivedBytes = 0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                try budget.checkActiveTime()
                receivedBytes += line.utf8.count
                guard receivedBytes <= 18 * 1_024 * 1_024 else { throw InsightServerAgentError("工具结果超过接收上限。") }
                guard !line.isEmpty else { continue }
                let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
                switch event.type {
                case "usage":
                    try budget.recordRemoteUsage(input: event.inputTokens ?? 0, output: event.outputTokens ?? 0)
                    onEvent(.budgetUpdated(budget.snapshot))
                case "status": onEvent(.phase(.querying))
                case "evidence":
                    if let item = event.exchange {
                        exchanges.append(item)
                        try budget.beginToolRoundTrip()
                        onEvent(.toolStarted(callID: item.call.callID, name: item.call.name))
                        onEvent(.toolFinished(callID: item.call.callID, name: item.call.name, succeeded: item.succeeded))
                        try await onCheckpoint(exchanges)
                    }
                case "error": throw InsightServerAgentError(event.message ?? "云端助手未完成本次任务。")
                case "result": result = event
                default: break
                }
            }
            guard let result else { throw InsightServerAgentError("回答连接已中断；本轮未完成，请重试。") }
            guard result.model == model else {
                throw InsightServerAgentError("服务返回的模型与本轮选择不一致，请重新选择模型后重试。")
            }
            let calls = result.clientCalls ?? []
            if calls.isEmpty {
                return InsightAgentHarness.Result(text: result.text ?? "", exchanges: exchanges,
                    successfulToolNames: Set(exchanges.filter(\.succeeded).map { $0.call.name }),
                    needsUserInput: result.needsUserInput == true)
            }
            guard let continuation = result.continuation else { throw InsightServerAgentError("客户端工具缺少可继续的上下文。") }
            input = continuation.compactMap { $0.foundationValue as? [String: Any] }
            for call in calls {
                try Task.checkCancellation()
                try budget.beginToolRoundTrip()
                guard clientTools.contains(where: { $0.name == call.name }) else { throw InsightToolError.permissionDenied }
                let native = InsightFunctionCall(callID: call.call_id, name: call.name, argumentsJSON: call.arguments)
                onEvent(.toolStarted(callID: native.callID, name: native.name))
                let observation = await execute(native)
                try Task.checkCancellation()
                exchanges.append(MiMoFunctionExchange(call: native, output: observation.output, succeeded: observation.succeeded))
                onEvent(.toolFinished(callID: native.callID, name: native.name, succeeded: observation.succeeded))
                input.append(["type": "function_call_output", "call_id": call.call_id, "output": observation.output])
                try await onCheckpoint(exchanges)
            }
        }
        return InsightAgentHarness.Result(text: "本轮已达到客户端工具调用上限，已停止。请核对现有草稿或补充信息后继续。", exchanges: exchanges,
            successfulToolNames: Set(exchanges.filter(\.succeeded).map { $0.call.name }), needsUserInput: true)
    }
}

struct InsightServerAgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class InsightAgentRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
