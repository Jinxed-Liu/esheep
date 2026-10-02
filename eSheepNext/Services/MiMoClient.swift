import Foundation

struct MiMoInputImage: Sendable, Equatable {
    let mimeType: String
    let data: Data
}

struct MiMoInputAudio: Sendable, Equatable {
    let mimeType: String
    let data: Data
}

struct MiMoReasoningRecord: Codable, Sendable, Equatable, Identifiable {
    enum Source: String, Codable, Sendable { case responses, chat }
    let id: String
    let text: String
    let source: Source
    let contentTexts: [String]

    init(id: String, text: String, source: Source = .responses, contentTexts: [String]? = nil) {
        self.id = id
        self.text = text
        self.source = source
        self.contentTexts = contentTexts ?? [text]
    }

    var responsesObject: [String: Any] {
        [
            "id": id,
            "type": "reasoning",
            "content": contentTexts.map { ["type": "reasoning_text", "text": $0] },
            "status": "completed",
        ]
    }
}

struct MiMoInputMessage: Sendable, Equatable {
    let role: InsightMessageRole
    let text: String
    let images: [MiMoInputImage]
    let audios: [MiMoInputAudio]
    let reasoningRecords: [MiMoReasoningRecord]

    init(
        role: InsightMessageRole,
        text: String,
        images: [MiMoInputImage] = [],
        audios: [MiMoInputAudio] = [],
        reasoningRecords: [MiMoReasoningRecord] = []
    ) {
        self.role = role
        self.text = text
        self.images = images
        self.audios = audios
        self.reasoningRecords = reasoningRecords
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
                    audios: message.audios,
                    reasoningRecords: message.reasoningRecords
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
            message.reasoningRecords.reduce(0) { $0 + estimatedTokens(for: $1.text) } +
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

struct MiMoFunctionExchange: Codable, Sendable, Equatable {
    let call: InsightFunctionCall
    let output: String
    let reasoningRecords: [MiMoReasoningRecord]
    let assistantTurnID: String?
    let assistantText: String
    let succeeded: Bool

    init(
        call: InsightFunctionCall,
        output: String,
        reasoningRecords: [MiMoReasoningRecord] = [],
        assistantTurnID: String? = nil,
        assistantText: String = "",
        succeeded: Bool = true
    ) {
        self.call = call
        self.output = output
        self.reasoningRecords = reasoningRecords
        self.assistantTurnID = assistantTurnID
        self.assistantText = assistantText
        self.succeeded = succeeded
    }
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
    let thinkingEnabled: Bool

    init(
        model: String = MiMoCredential.model,
        instructions: String,
        messages: [MiMoInputMessage],
        functionExchanges: [MiMoFunctionExchange] = [],
        tools: [InsightToolDefinition] = [],
        maximumOutputTokens: Int = 1_200,
        thinkingEnabled: Bool = true
    ) {
        self.model = model
        self.instructions = instructions
        self.messages = messages
        self.functionExchanges = functionExchanges
        self.tools = tools
        self.maximumOutputTokens = min(max(128, maximumOutputTokens), 8_192)
        self.thinkingEnabled = thinkingEnabled
    }

    func withMaximumOutputTokens(_ maximum: Int) -> Self {
        Self(
            model: model,
            instructions: instructions,
            messages: messages,
            functionExchanges: functionExchanges,
            tools: tools,
            maximumOutputTokens: maximum,
            thinkingEnabled: thinkingEnabled
        )
    }
}

struct InsightFunctionCall: Codable, Sendable, Equatable {
    let callID: String
    let name: String
    let argumentsJSON: String
}

struct InsightTokenUsage: Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let reasoningTokens: Int
    let cachedInputTokens: Int

    init(
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        reasoningTokens: Int = 0,
        cachedInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.reasoningTokens = reasoningTokens
        self.cachedInputTokens = cachedInputTokens
    }
}

enum InsightModelEvent: Sendable, Equatable {
    case responseStarted(id: String)
    case textDelta(String)
    case reasoningDelta(String)
    case reasoningRecorded(MiMoReasoningRecord)
    case functionCall(InsightFunctionCall)
    case completed(responseID: String?, usage: InsightTokenUsage?)
    case usage(InsightTokenUsage)
}

enum MiMoClientError: LocalizedError, Equatable {
    case invalidRequest
    case requestTooLarge(maximumBytes: Int)
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
        case .invalidRequest, .requestTooLarge, .authenticationFailed, .quotaExceeded, .incomplete:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "发送给 MiMo 的请求无效。"
        case .requestTooLarge(let maximumBytes):
            "本次请求超过 \(maximumBytes / (1_024 * 1_024)) MiB 容量上限，已停止发送；请减少附件或上下文范围后继续。"
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
                        for event in try parser.finishStream() {
                            continuation.yield(event)
                        }
                    } else {
                        var didComplete = false
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard let event = try MiMoSSEParser.parse(line: line) else { continue }
                            if case .completed = event { didComplete = true }
                            continuation.yield(event)
                        }
                        guard didComplete else { throw MiMoClientError.invalidResponse }
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
            maximumOutputTokens: 128,
            thinkingEnabled: false
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

    func makeResponsesURLRequest(
        request: MiMoConversationRequest,
        credential: MiMoCredential,
        stream: Bool
    ) throws -> URLRequest {
        try Self.validatePayloadSize(request)
        var urlRequest = URLRequest(url: credential.responsesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = stream ? 120 : 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "accept")
        urlRequest.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "api-key")
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var input: [[String: Any]] = []
        var replayedReasoningIDs: Set<String> = []
        for message in request.messages {
            if message.role == .assistant {
                for record in message.reasoningRecords where replayedReasoningIDs.insert(record.id).inserted {
                    input.append(record.responsesObject)
                }
            }
            input.append(Self.responsesMessageObject(message))
        }
        for turn in Self.functionTurns(request.functionExchanges) {
            // Keep the actual reasoning item immediately before the matching
            // function-call turn. Multiple calls share one reasoning item.
            for exchange in turn {
                for record in exchange.reasoningRecords where replayedReasoningIDs.insert(record.id).inserted {
                    input.append(record.responsesObject)
                }
            }
            for exchange in turn {
                input.append([
                    "type": "function_call",
                    "call_id": exchange.call.callID,
                    "name": exchange.call.name,
                    "arguments": exchange.call.argumentsJSON,
                ])
            }
            for exchange in turn {
                input.append([
                    "type": "function_call_output",
                    "call_id": exchange.call.callID,
                    "output": exchange.output,
                ])
            }
        }
        var body: [String: Any] = [
            "model": request.model,
            "instructions": request.instructions,
            "input": input,
            "max_output_tokens": request.maximumOutputTokens,
            "stream": stream,
            "reasoning": ["effort": request.thinkingEnabled ? "high" : "none"],
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
        urlRequest.httpBody = try Self.requestBody(body)
        return urlRequest
    }

    func makeChatURLRequest(
        request: MiMoConversationRequest,
        credential: MiMoCredential
    ) throws -> URLRequest {
        try Self.validatePayloadSize(request)
        var urlRequest = URLRequest(url: credential.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.setValue(credential.apiKey, forHTTPHeaderField: "api-key")
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var messages: [[String: Any]] = [
            ["role": "system", "content": request.instructions]
        ]
        messages.append(contentsOf: request.messages.map { message in
            var object = Self.chatMessageObject(message)
            if message.role == .assistant, !message.reasoningRecords.isEmpty {
                object["reasoning_content"] = message.reasoningRecords.map(\.text).joined(separator: "\n")
            }
            return object
        })
        for turn in Self.functionTurns(request.functionExchanges) {
            guard let first = turn.first else { continue }
            var assistant: [String: Any] = [
                "role": "assistant",
                "content": first.assistantText,
                "tool_calls": turn.map { exchange in [
                    "id": exchange.call.callID,
                    "type": "function",
                    "function": [
                        "name": exchange.call.name,
                        "arguments": exchange.call.argumentsJSON,
                    ],
                ] },
            ]
            if request.thinkingEnabled || !first.reasoningRecords.isEmpty {
                assistant["reasoning_content"] = first.reasoningRecords.map(\.text).joined(separator: "\n")
            }
            messages.append(assistant)
            for exchange in turn {
                messages.append([
                    "role": "tool",
                    "tool_call_id": exchange.call.callID,
                    "content": exchange.output,
                ])
            }
        }
        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_completion_tokens": request.maximumOutputTokens,
            "stream": true,
            "thinking": ["type": request.thinkingEnabled ? "enabled" : "disabled"],
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
        urlRequest.httpBody = try Self.requestBody(body)
        return urlRequest
    }

    // Existing recordings allow up to 50 MiB after base64 encoding. Keep
    // room for optimized images and text, and reject the complete body rather
    // than silently clipping any user-selected input or tool evidence.
    static let maximumRequestBodyBytes = 64 * 1_024 * 1_024

    private static func validatePayloadSize(_ request: MiMoConversationRequest) throws {
        // A lower-bound check prevents allocating huge base64 strings for an
        // already oversized media history. The final serialized-body check
        // below still enforces the exact byte limit including JSON overhead.
        var bytes = 0
        func include(_ count: Int) throws {
            guard count <= maximumRequestBodyBytes - bytes else {
                throw MiMoClientError.requestTooLarge(maximumBytes: maximumRequestBodyBytes)
            }
            bytes += count
        }
        try include(request.instructions.utf8.count)
        for message in request.messages {
            try include(message.text.utf8.count)
            guard message.images.count <= 4, message.audios.count <= 1 else {
                throw MiMoClientError.invalidRequest
            }
            if message.role == .user {
                for image in message.images { try include(((image.data.count + 2) / 3) * 4) }
                for audio in message.audios { try include(((audio.data.count + 2) / 3) * 4) }
            }
        }
        for exchange in request.functionExchanges {
            try include(exchange.call.argumentsJSON.utf8.count)
            try include(exchange.output.utf8.count)
        }
    }

    static func requestBody(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MiMoClientError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: object)
        guard body.count <= maximumRequestBodyBytes else {
            throw MiMoClientError.requestTooLarge(maximumBytes: maximumRequestBodyBytes)
        }
        return body
    }

    private static func functionTurns(_ exchanges: [MiMoFunctionExchange]) -> [[MiMoFunctionExchange]] {
        var turns: [[MiMoFunctionExchange]] = []
        for exchange in exchanges {
            if let id = exchange.assistantTurnID,
               let previous = turns.last?.first,
               previous.assistantTurnID == id {
                turns[turns.count - 1].append(exchange)
            } else {
                turns.append([exchange])
            }
        }
        return turns
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
                "text": message.text,
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
            return ["role": role, "content": message.text]
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
                "text": message.text,
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
        case "response.reasoning_text.delta":
            guard let delta = object["delta"] as? String else {
                throw MiMoClientError.invalidResponse
            }
            return delta.isEmpty ? nil : .reasoningDelta(delta)
        case "response.reasoning_text.done":
            guard let text = object["text"] as? String,
                  let itemID = object["item_id"] as? String else {
                throw MiMoClientError.invalidResponse
            }
            return text.isEmpty ? nil : .reasoningRecorded(.init(id: itemID, text: text))
        case "response.output_item.done":
            guard let item = object["item"] as? [String: Any] else { return nil }
            if item["type"] as? String == "reasoning" {
                guard let id = item["id"] as? String,
                      let content = item["content"] as? [[String: Any]] else {
                    throw MiMoClientError.invalidResponse
                }
                let texts = content.compactMap { part -> String? in
                    guard part["type"] as? String == "reasoning_text" else { return nil }
                    return part["text"] as? String
                }
                guard texts.contains(where: { !$0.isEmpty }) else { return nil }
                return .reasoningRecorded(.init(
                    id: id,
                    text: texts.joined(separator: "\n"),
                    contentTexts: texts
                ))
            }
            guard item["type"] as? String == "function_call",
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
                let outputDetails = $0["output_tokens_details"] as? [String: Any]
                let inputDetails = $0["input_tokens_details"] as? [String: Any]
                return InsightTokenUsage(
                    inputTokens: $0["input_tokens"] as? Int ?? 0,
                    outputTokens: $0["output_tokens"] as? Int ?? 0,
                    totalTokens: $0["total_tokens"] as? Int ?? 0,
                    reasoningTokens: outputDetails?["reasoning_tokens"] as? Int ?? 0,
                    cachedInputTokens: inputDetails?["cached_tokens"] as? Int ?? 0
                )
            }
            return .completed(responseID: response?["id"] as? String, usage: usage)
        case "response.incomplete":
            let response = object["response"] as? [String: Any]
            let details = response?["incomplete_details"] as? [String: Any]
            throw MiMoClientError.incomplete(reason: details?["reason"] as? String)
        case "error", "response.failed":
            let error = object["error"] as? [String: Any]
                ?? (object["response"] as? [String: Any])?["error"] as? [String: Any]
            throw MiMoClientError.server(
                status: 200,
                message: error?["message"] as? String ?? "MiMo 流式响应发生错误。"
            )
        default:
            return nil
        }
    }
}

struct MiMoChatSSEParser {
    private struct PendingCall {
        var callID = ""
        var name = ""
        var arguments = ""
    }

    private var calls: [Int: PendingCall] = [:]
    private var didFinish = false
    private var responseID: String?
    private var reasoning = ""
    private var reportedUsage: InsightTokenUsage?
    private var didStart = false

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
        var events: [InsightModelEvent] = []
        if let id = object["id"] as? String {
            responseID = id
            if !didStart {
                didStart = true
                events.append(.responseStarted(id: id))
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            let completionDetails = usage["completion_tokens_details"] as? [String: Any]
            let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
            let value = InsightTokenUsage(
                inputTokens: usage["prompt_tokens"] as? Int ?? 0,
                outputTokens: usage["completion_tokens"] as? Int ?? 0,
                totalTokens: usage["total_tokens"] as? Int ?? 0,
                reasoningTokens: completionDetails?["reasoning_tokens"] as? Int ?? 0,
                cachedInputTokens: promptDetails?["cached_tokens"] as? Int ?? 0
            )
            reportedUsage = value
            events.append(.usage(value))
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any] else {
            return events
        }
        if let content = delta["reasoning_content"] as? String, !content.isEmpty {
            reasoning += content
            events.append(.reasoningDelta(content))
        }
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
        if let reason = choice["finish_reason"] as? String {
            if reason == "length" {
                throw MiMoClientError.incomplete(reason: "max_output_tokens")
            }
            if reason == "content_filter" {
                throw MiMoClientError.incomplete(reason: "content_filter")
            }
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
        var events: [InsightModelEvent] = []
        if !reasoning.isEmpty {
            events.append(.reasoningRecorded(.init(
                id: responseID ?? UUID().uuidString,
                text: reasoning,
                source: .chat
            )))
        }
        return events + functionEvents + [.completed(responseID: responseID, usage: reportedUsage)]
    }

    mutating func finishStream() throws -> [InsightModelEvent] {
        guard didFinish else { throw MiMoClientError.invalidResponse }
        return []
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
