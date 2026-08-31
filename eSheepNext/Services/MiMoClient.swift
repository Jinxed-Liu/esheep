import Foundation

struct MiMoInputImage: Sendable, Equatable {
    let mimeType: String
    let data: Data
}

struct MiMoInputAudio: Sendable, Equatable {
    let mimeType: String
    let data: Data
}

struct MiMoInputMessage: Sendable, Equatable {
    let role: InsightMessageRole
    let text: String
    let images: [MiMoInputImage]
    let audios: [MiMoInputAudio]

    init(
        role: InsightMessageRole,
        text: String,
        images: [MiMoInputImage] = [],
        audios: [MiMoInputAudio] = []
    ) {
        self.role = role
        self.text = text
        self.images = images
        self.audios = audios
    }
}

struct InsightContextPreparation: Sendable, Equatable {
    let messages: [MiMoInputMessage]
    let didCompress: Bool
    let originalEstimatedTokens: Int
    let preparedEstimatedTokens: Int
    let compressedMessageCount: Int
}

struct InsightContextWindowUsage: Sendable, Equatable {
    let estimatedTokens: Int
    let limitTokens: Int
    let lastCompressedAt: Date?

    var fraction: Double {
        guard limitTokens > 0 else { return 0 }
        return min(1, max(0, Double(estimatedTokens) / Double(limitTokens)))
    }

    var percentage: Int {
        min(100, max(0, Int((fraction * 100).rounded())))
    }
}

enum InsightContextCompressor {
    static let compressionThresholdTokens = 512 * 1_024
    static let compressedTargetTokens = 384 * 1_024
    static let compressionToolName = "context_compression"

    static func prepare(
        messages: [MiMoInputMessage],
        additionalEstimatedTokens: Int = 0
    ) -> InsightContextPreparation {
        let originalTokens = additionalEstimatedTokens +
            messages.reduce(0) { $0 + estimatedTokens(for: $1) }
        guard originalTokens >= compressionThresholdTokens else {
            return InsightContextPreparation(
                messages: messages,
                didCompress: false,
                originalEstimatedTokens: originalTokens,
                preparedEstimatedTokens: originalTokens,
                compressedMessageCount: 0
            )
        }

        let availableTokens = max(
            96 * 1_024,
            compressedTargetTokens - additionalEstimatedTokens
        )
        let summaryBudget = min(64 * 1_024, max(16 * 1_024, availableTokens / 5))
        let recentBudget = max(64 * 1_024, availableTokens - summaryBudget)
        var recent: [MiMoInputMessage] = []
        var recentTokens = 0

        for message in messages.reversed() {
            let tokens = estimatedTokens(for: message)
            if recent.isEmpty, tokens > recentBudget {
                let characterBudget = max(1, recentBudget - 32)
                recent.append(MiMoInputMessage(
                    role: message.role,
                    text: String(message.text.prefix(characterBudget)) + "\n[本条消息已按上下文上限截断]",
                    images: message.images,
                    audios: message.audios
                ))
                recentTokens = estimatedTokens(for: recent[0])
                break
            }
            if !recent.isEmpty, recentTokens + tokens > recentBudget {
                break
            }
            recent.append(message)
            recentTokens += tokens
        }
        recent.reverse()

        let compressedCount = max(0, messages.count - recent.count)
        let olderMessages = Array(messages.prefix(compressedCount))
        let summary = compressedSummary(
            for: olderMessages,
            tokenBudget: summaryBudget
        )
        let summaryMessage = MiMoInputMessage(
            role: .system,
            text: summary
        )
        let preparedMessages = [summaryMessage] + recent
        let preparedTokens = additionalEstimatedTokens +
            preparedMessages.reduce(0) { $0 + estimatedTokens(for: $1) }
        return InsightContextPreparation(
            messages: preparedMessages,
            didCompress: true,
            originalEstimatedTokens: originalTokens,
            preparedEstimatedTokens: preparedTokens,
            compressedMessageCount: compressedCount
        )
    }

    static func estimatedTokens(for text: String) -> Int {
        var tokens = 0
        var asciiRun = 0

        func flushASCII() {
            guard asciiRun > 0 else { return }
            tokens += max(1, (asciiRun + 3) / 4)
            asciiRun = 0
        }

        for scalar in text.unicodeScalars {
            if scalar.value <= 0x7F {
                asciiRun += 1
            } else {
                flushASCII()
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    tokens += 1
                }
            }
        }
        flushASCII()
        return max(1, tokens)
    }

    static func estimatedTokens(for message: MiMoInputMessage) -> Int {
        estimatedTokens(for: message.text) +
            message.images.count * 2_048 +
            message.audios.count * 8_192 +
            12
    }

    private static func compressedSummary(
        for messages: [MiMoInputMessage],
        tokenBudget: Int
    ) -> String {
        let header = """
        [系统：上下文压缩]
        当前会话达到 512K 上下文阈值。以下是较早对话的压缩摘录；最近对话优先，若内容冲突，以最近消息为准。
        """
        guard !messages.isEmpty else { return header }

        var selected: [String] = []
        var usedTokens = estimatedTokens(for: header)
        for message in messages.reversed() {
            let role = switch message.role {
            case .user: "用户"
            case .assistant: "AI 助手"
            case .system: "系统"
            case .tool: "工具"
            }
            let compact = message.text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !compact.isEmpty else { continue }
            let excerpt = "\(role)：\(String(compact.prefix(1_200)))"
            let excerptTokens = estimatedTokens(for: excerpt)
            guard usedTokens + excerptTokens <= tokenBudget else { continue }
            selected.append(excerpt)
            usedTokens += excerptTokens
        }
        selected.reverse()

        if let first = messages.first {
            let compactFirst = first.text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            let earliest = "最早背景：\(String(compactFirst.prefix(600)))"
            if !compactFirst.isEmpty,
               !selected.contains(earliest),
               usedTokens + estimatedTokens(for: earliest) <= tokenBudget {
                selected.insert(earliest, at: 0)
            }
        }
        return ([header] + selected).joined(separator: "\n")
    }
}

struct MiMoFunctionExchange: Sendable, Equatable {
    let call: InsightFunctionCall
    let output: String
}

struct InsightToolDefinition: Sendable, Equatable {
    let name: String
    let description: String
    let parameters: [String: JSONValue]
}

struct MiMoConversationRequest: Sendable {
    let model: String
    let instructions: String
    let messages: [MiMoInputMessage]
    let functionExchanges: [MiMoFunctionExchange]
    let tools: [InsightToolDefinition]
    let maximumOutputTokens: Int

    init(
        model: String = MiMoCredential.textModel,
        instructions: String,
        messages: [MiMoInputMessage],
        functionExchanges: [MiMoFunctionExchange] = [],
        tools: [InsightToolDefinition] = [],
        maximumOutputTokens: Int = 1_200
    ) {
        self.model = model
        self.instructions = instructions
        self.messages = messages
        self.functionExchanges = functionExchanges
        self.tools = tools
        self.maximumOutputTokens = min(max(128, maximumOutputTokens), 4_096)
    }
}

struct InsightFunctionCall: Sendable, Equatable {
    let callID: String
    let name: String
    let argumentsJSON: String
}

struct InsightTokenUsage: Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}

enum InsightModelEvent: Sendable, Equatable {
    case responseStarted(id: String)
    case textDelta(String)
    case functionCall(InsightFunctionCall)
    case completed(responseID: String?, usage: InsightTokenUsage?)
}

enum MiMoClientError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case authenticationFailed
    case rateLimited
    case quotaExceeded
    case incomplete(reason: String?)
    case server(status: Int, message: String)
    case networkUnavailable

    var isOutputLimitIncomplete: Bool {
        guard case .incomplete(let reason) = self else { return false }
        return reason == "max_output_tokens"
    }

    /// Failures for which repeating the same model turn is safe and useful.
    /// The harness owns this recovery; callers must not ask the user to resend
    /// the same natural-language request.
    var isAutomaticallyRecoverable: Bool {
        switch self {
        case .invalidResponse, .rateLimited, .networkUnavailable:
            true
        case .server(let status, _):
            status == 200 || status == 408 || status == 409 || status == 425 ||
                (500...599).contains(status)
        case .invalidRequest, .authenticationFailed, .quotaExceeded, .incomplete:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "发送给 MiMo 的请求无效。"
        case .invalidResponse:
            "MiMo 返回了无法解析的响应。"
        case .authenticationFailed:
            "MiMo API Key 无效或已失效，请重新配置。"
        case .rateLimited:
            "MiMo 当前限制了请求频率。"
        case .quotaExceeded:
            "当前 MiMo API Key 的额度不足。"
        case .incomplete(let reason):
            switch reason {
            case "max_output_tokens":
                "本次回答或操作草案超过 MiMo 单次输出长度，未能完整生成。"
            case "content_filter":
                "MiMo 因内容安全限制未能完成本次回答。"
            case .some(let reason):
                "MiMo 未能完成本次回答（\(reason)）。"
            case .none:
                "MiMo 未能完成本次回答。"
            }
        case .server(_, let message):
            message
                .replacingOccurrences(of: "请重试", with: "")
                .replacingOccurrences(of: "重试", with: "")
                .replacingOccurrences(of: "请稍后再试", with: "")
                .replacingOccurrences(of: "稍后再试", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .networkUnavailable:
            "当前无法连接 MiMo，请检查网络。"
        }
    }
}

protocol MiMoResponding: Sendable {
    func stream(
        request: MiMoConversationRequest,
        credential: MiMoCredential
    ) -> AsyncThrowingStream<InsightModelEvent, Error>

    func validate(credential: MiMoCredential) async throws
}

final class MiMoClient: MiMoResponding, @unchecked Sendable {
    static let shared = MiMoClient()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func stream(
        request: MiMoConversationRequest,
        credential: MiMoCredential
    ) -> AsyncThrowingStream<InsightModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let containsAudio = request.messages.contains { !$0.audios.isEmpty }
                    let urlRequest = try containsAudio
                        ? makeChatURLRequest(request: request, credential: credential)
                        : makeResponsesURLRequest(request: request, credential: credential, stream: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        var errorData = Data()
                        for try await byte in bytes {
                            if errorData.count >= 64 * 1_024 { break }
                            errorData.append(byte)
                        }
                        try Self.validate(response: response, data: errorData)
                    }
                    try Self.validate(response: response)
                    if containsAudio {
                        var parser = MiMoChatSSEParser()
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            for event in try parser.parse(line: line) {
                                continuation.yield(event)
                            }
                        }
                        for event in parser.finish() {
                            continuation.yield(event)
                        }
                    } else {
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard let event = try MiMoSSEParser.parse(line: line) else { continue }
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError {
                    if error.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: MiMoClientError.networkUnavailable)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func validate(credential: MiMoCredential) async throws {
        let request = MiMoConversationRequest(
            instructions: "Return exactly OK.",
            messages: [MiMoInputMessage(role: .user, text: "OK")],
            maximumOutputTokens: 8
        )
        let urlRequest = try makeResponsesURLRequest(
            request: request,
            credential: credential,
            stream: false
        )
        do {
            let (data, response) = try await session.data(for: urlRequest)
            try Self.validate(response: response, data: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["id"] is String else {
                throw MiMoClientError.invalidResponse
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MiMoClientError.networkUnavailable
        }
    }

    private func makeResponsesURLRequest(
        request: MiMoConversationRequest,
        credential: MiMoCredential,
        stream: Bool
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: credential.responsesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = stream ? 120 : 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "accept")
        urlRequest.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "api-key")
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var input = request.messages.map(Self.responsesMessageObject)
        for exchange in request.functionExchanges {
            input.append([
                "type": "function_call",
                "call_id": exchange.call.callID,
                "name": exchange.call.name,
                "arguments": exchange.call.argumentsJSON,
            ])
            input.append([
                "type": "function_call_output",
                "call_id": exchange.call.callID,
                "output": exchange.output,
            ])
        }
        var body: [String: Any] = [
            "model": request.model,
            "instructions": request.instructions,
            "input": input,
            "max_output_tokens": request.maximumOutputTokens,
            "stream": stream,
            "reasoning": ["effort": "none"],
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map {
                [
                    "type": "function",
                    "name": $0.name,
                    "description": $0.description,
                    "parameters": $0.parameters.mapValues(\.foundationValue),
                    "strict": true,
                ] as [String: Any]
            }
            body["tool_choice"] = "auto"
        }
        guard JSONSerialization.isValidJSONObject(body) else {
            throw MiMoClientError.invalidRequest
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func makeChatURLRequest(
        request: MiMoConversationRequest,
        credential: MiMoCredential
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: credential.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "api-key")
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var messages: [[String: Any]] = [
            ["role": "system", "content": String(request.instructions.prefix(24_000))]
        ]
        messages.append(contentsOf: request.messages.map(Self.chatMessageObject))
        for exchange in request.functionExchanges {
            messages.append([
                "role": "assistant",
                "content": "",
                "tool_calls": [[
                    "id": exchange.call.callID,
                    "type": "function",
                    "function": [
                        "name": exchange.call.name,
                        "arguments": exchange.call.argumentsJSON,
                    ],
                ]],
            ])
            messages.append([
                "role": "tool",
                "tool_call_id": exchange.call.callID,
                "content": exchange.output,
            ])
        }
        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_completion_tokens": request.maximumOutputTokens,
            "stream": true,
            "thinking": ["type": "disabled"],
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map {
                [
                    "type": "function",
                    "function": [
                        "name": $0.name,
                        "description": $0.description,
                        "parameters": $0.parameters.mapValues(\.foundationValue),
                        "strict": true,
                    ],
                ] as [String: Any]
            }
            body["tool_choice"] = "auto"
        }
        guard JSONSerialization.isValidJSONObject(body) else {
            throw MiMoClientError.invalidRequest
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private static func responsesMessageObject(_ message: MiMoInputMessage) -> [String: Any] {
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "developer"
        case .tool: role = "user"
        }
        var content = [[String: Any]]()
        if !message.text.isEmpty {
            content.append([
                "type": role == "assistant" ? "output_text" : "input_text",
                "text": String(message.text.prefix(24_000)),
            ])
        }
        if role == "user" {
            content.append(contentsOf: message.images.prefix(4).map {
                [
                    "type": "input_image",
                    "image_url": "data:\($0.mimeType);base64,\($0.data.base64EncodedString())",
                ]
            })
        }
        return ["role": role, "content": content]
    }

    private static func chatMessageObject(_ message: MiMoInputMessage) -> [String: Any] {
        let role = message.role == .assistant ? "assistant" : "user"
        guard role == "user", !message.images.isEmpty || !message.audios.isEmpty else {
            return ["role": role, "content": String(message.text.prefix(24_000))]
        }
        var content = [[String: Any]]()
        content.append(contentsOf: message.audios.prefix(1).map {
            [
                "type": "input_audio",
                "input_audio": [
                    "data": "data:\($0.mimeType);base64,\($0.data.base64EncodedString())",
                ],
            ]
        })
        content.append(contentsOf: message.images.prefix(4).map {
            [
                "type": "image_url",
                "image_url": [
                    "url": "data:\($0.mimeType);base64,\($0.data.base64EncodedString())",
                ],
            ]
        })
        if !message.text.isEmpty {
            content.append([
                "type": "text",
                "text": String(message.text.prefix(24_000)),
            ])
        }
        return ["role": role, "content": content]
    }

    private static func validate(response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MiMoClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403:
                throw MiMoClientError.authenticationFailed
            case 429:
                if let data, errorMessage(data).localizedCaseInsensitiveContains("quota") {
                    throw MiMoClientError.quotaExceeded
                }
                throw MiMoClientError.rateLimited
            default:
                throw MiMoClientError.server(
                    status: http.statusCode,
                    message: data.map(errorMessage) ?? "MiMo 服务暂时不可用（\(http.statusCode)）。"
                )
            }
        }
    }

    private static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return "MiMo 服务返回错误。"
        }
        return error["message"] as? String ?? "MiMo 服务返回错误。"
    }
}

enum MiMoSSEParser {
    static func parse(line: String) throws -> InsightModelEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw MiMoClientError.invalidResponse
        }
        switch type {
        case "response.created":
            let response = object["response"] as? [String: Any]
            return .responseStarted(id: response?["id"] as? String ?? "")
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else {
                throw MiMoClientError.invalidResponse
            }
            return .textDelta(delta)
        case "response.output_item.done":
            guard let item = object["item"] as? [String: Any],
                  item["type"] as? String == "function_call",
                  let name = item["name"] as? String,
                  let arguments = item["arguments"] as? String else {
                return nil
            }
            let callID = item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString
            return .functionCall(.init(callID: callID, name: name, argumentsJSON: arguments))
        case "response.completed":
            let response = object["response"] as? [String: Any]
            let usageObject = response?["usage"] as? [String: Any]
            let usage = usageObject.map {
                InsightTokenUsage(
                    inputTokens: $0["input_tokens"] as? Int ?? 0,
                    outputTokens: $0["output_tokens"] as? Int ?? 0,
                    totalTokens: $0["total_tokens"] as? Int ?? 0
                )
            }
            return .completed(responseID: response?["id"] as? String, usage: usage)
        case "response.incomplete":
            let response = object["response"] as? [String: Any]
            let details = response?["incomplete_details"] as? [String: Any]
            throw MiMoClientError.incomplete(reason: details?["reason"] as? String)
        case "error":
            let error = object["error"] as? [String: Any]
            throw MiMoClientError.server(
                status: 200,
                message: error?["message"] as? String ?? "MiMo 流式响应发生错误。"
            )
        default:
            return nil
        }
    }
}

private struct MiMoChatSSEParser {
    private struct PendingCall {
        var callID = ""
        var name = ""
        var arguments = ""
    }

    private var calls: [Int: PendingCall] = [:]
    private var didFinish = false

    mutating func parse(line: String) throws -> [InsightModelEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return [] }
        if payload == "[DONE]" {
            return finish()
        }
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiMoClientError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw MiMoClientError.server(
                status: 200,
                message: error["message"] as? String ?? "MiMo 流式响应发生错误。"
            )
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any] else {
            return []
        }
        var events: [InsightModelEvent] = []
        if let content = delta["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        }
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for value in toolCalls {
                let index = value["index"] as? Int ?? 0
                var pending = calls[index] ?? PendingCall()
                if let callID = value["id"] as? String { pending.callID = callID }
                if let function = value["function"] as? [String: Any] {
                    if let name = function["name"] as? String { pending.name += name }
                    if let arguments = function["arguments"] as? String {
                        pending.arguments += arguments
                    }
                }
                calls[index] = pending
            }
        }
        if choice["finish_reason"] is String {
            events.append(contentsOf: finish())
        }
        return events
    }

    mutating func finish() -> [InsightModelEvent] {
        guard !didFinish else { return [] }
        didFinish = true
        let functionEvents = calls.keys.sorted().compactMap { index -> InsightModelEvent? in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return .functionCall(.init(
                callID: call.callID.isEmpty ? UUID().uuidString : call.callID,
                name: call.name,
                argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments
            ))
        }
        return functionEvents + [.completed(responseID: nil, usage: nil)]
    }
}

indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.foundationValue)
        case .array(let value): value.map(\.foundationValue)
        case .null: NSNull()
        }
    }
}
