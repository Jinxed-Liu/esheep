import Foundation

/// Availability is a release gate, not a successful OAuth login or a model entitlement.
struct InsightCodexConnectionGate: Sendable, Equatable {
    var partnerApproved = false
    var callbackApproved = false
    var privacyApproved = false
    var runtimeIsolationVerified = false

    var unavailableReason: String? {
        if !partnerApproved { return "ChatGPT 订阅接入尚未取得官方接入资格。" }
        if !callbackApproved { return "ChatGPT 授权回调尚未完成验证。" }
        if !privacyApproved { return "请先同意 Codex 受控服务的数据处理说明。" }
        if !runtimeIsolationVerified { return "Codex 运行宿主尚未通过工具与账户隔离验证。" }
        return nil
    }

    var isAvailable: Bool { unavailableReason == nil }
}

struct InsightCodexScope: Codable, Sendable, Equatable {
    let accountID: UUID
    let farmID: UUID
    let conversationID: UUID
}

struct InsightCodexHostConfiguration: Sendable, Equatable {
    let hostID: UUID
    let baseURL: URL

    init(hostID: UUID, baseURL: URL) throws {
        let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]
        guard baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil, let host = baseURL.host,
              baseURL.scheme == "https" || (baseURL.scheme == "http" && loopbackHosts.contains(host)) else {
            throw InsightCodexError.insecureHost
        }
        self.hostID = hostID
        self.baseURL = baseURL
    }
}

enum InsightCodexError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case insecureHost
    case missingBridgeCredential
    case invalidResponse
    case scopeMismatch
    case unsupportedReasoningEffort
    case unsupportedInput
    case host(code: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .insecureHost: "Codex 宿主必须使用 HTTPS；HTTP 仅允许本机回环地址。"
        case .missingBridgeCredential: "Codex 宿主认证尚未配置，请连接已授权的宿主。"
        case .invalidResponse: "Codex 宿主返回了无法验证的响应。"
        case .scopeMismatch: "Codex 会话不属于当前账号、牧场或聊天。"
        case .unsupportedReasoningEffort: "当前 Codex 模型不支持此思考强度。"
        case .unsupportedInput: "Codex 当前连接仅接受文字，请先在本机转写语音或解析附件。"
        case .host(let code):
            switch code {
            case "codex_connection_not_approved": "Codex 接入资格、授权回调或隔离验证尚未完成。"
            case "authentication_required", "chatgpt_reauthorization_required": "Codex 授权已失效，请重新连接。"
            case "host_capacity_reached": "Codex 宿主正在处理其他聊天，请稍后重试。"
            case "unsupported_reasoning_effort": "当前 Codex 模型不支持此思考强度。"
            case "turn_status_uncertain", "checkpoint_reconciliation_required": "上次请求的结果尚未对账，已暂停以避免重复执行。"
            case "chatgpt_usage_limit_exceeded": "ChatGPT 授权额度已达限制，任务已暂停；请在 ChatGPT 设置中查看用量。"
            case "codex_session_budget_exceeded": "Codex 当前会话已达运行预算，任务已暂停。"
            case "codex_context_window_exceeded": "Codex 当前会话上下文已达限制，任务已暂停。"
            case "codex_rate_limit_exceeded": "Codex 请求频率已达限制，请稍后重试。"
            case "event_history_expired": "连接中断期间的过程记录已过期，请恢复会话后再继续。"
            default: "Codex 连接已暂停（\(code)），聊天草稿已保留。"
            }
        }
    }
}

indirect enum InsightCodexJSONValue: Codable, Sendable, Equatable {
    case object([String: InsightCodexJSONValue])
    case array([InsightCodexJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode([String: Self].self) { self = .object(result) }
        else { self = .array(try value.decode([Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .string(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .bool(let result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }
}

struct InsightCodexToolDefinition: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: [String: InsightCodexJSONValue]
}

struct InsightCodexModel: Codable, Sendable, Equatable, Identifiable {
    let slug: String
    let displayName: String
    var id: String { slug }
}

struct InsightCodexThread: Codable, Sendable, Equatable {
    let sessionID: String
    let scope: InsightCodexScope
    let threadID: String
    let modelSlug: String
    let supportedReasoningEfforts: [String]
    /// Catalog membership does not grant access. Only a completed real turn establishes this.
    let accessVerified: Bool
}

struct InsightCodexTurn: Codable, Sendable, Equatable {
    let turnID: String
    let status: String
}

struct InsightCodexEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case textDelta, reasoningSummaryDelta, toolCall, turnCompleted, blockedTool, failed, paused
    }
    let sequence: Int
    let kind: Kind
    let scope: InsightCodexScope
    let threadID: String?
    let turnID: String?
    let callID: String?
    let toolName: String?
    let argumentsJSON: String?
    let text: String?
    let status: String?
    let errorCode: String?

    var didCompleteSuccessfully: Bool { kind == .turnCompleted && status == "completed" }
}

struct InsightCodexEventBatch: Codable, Sendable, Equatable {
    let events: [InsightCodexEvent]
    let cursor: Int
}
