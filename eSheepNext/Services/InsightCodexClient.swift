import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class InsightCodexRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Authenticated bridge transport. OAuth/provider credentials remain on the approved host.
/// The owning App-level session coordinator polls while foreground and closes on scope changes.
actor InsightCodexClient {
    private struct Failure: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }
    private let configuration: InsightCodexHostConfiguration
    private let scope: InsightCodexScope
    private let bridgeToken: String
    private let session: URLSession
    private var thread: InsightCodexThread?

    init(configuration: InsightCodexHostConfiguration, gate: InsightCodexConnectionGate,
         scope: InsightCodexScope, bridgeToken: String, session: URLSession? = nil) throws {
        if let reason = gate.unavailableReason { throw InsightCodexError.unavailable(reason) }
        guard (32...1024).contains(bridgeToken.count),
              !bridgeToken.contains(where: { $0.isWhitespace }) else {
            throw InsightCodexError.missingBridgeCredential
        }
        self.configuration = configuration
        self.scope = scope
        self.bridgeToken = bridgeToken
        self.session = session ?? URLSession(configuration: .ephemeral,
                                            delegate: InsightCodexRedirectBlocker(), delegateQueue: nil)
    }

    func models() async throws -> [InsightCodexModel] {
        struct Response: Decodable { let models: [InsightCodexModel] }
        let response: Response = try await get(path: "v1/models")
        return response.models
    }

    func open(modelSlug: String, tools: [InsightCodexToolDefinition],
              instructions: String) async throws -> InsightCodexThread {
        struct Request: Encodable {
            let scope: InsightCodexScope
            let modelSlug: String
            let tools: [InsightCodexToolDefinition]
            let instructions: String
        }
        let result: InsightCodexThread = try await post(path: "v1/sessions", body: Request(
            scope: scope, modelSlug: modelSlug, tools: tools, instructions: instructions
        ))
        guard result.scope == scope, result.modelSlug == modelSlug,
              result.sessionID.count == 64,
              result.sessionID.allSatisfy({ $0.isHexDigit }), !result.threadID.isEmpty else {
            throw InsightCodexError.scopeMismatch
        }
        thread = result
        return result
    }

    func startTurn(text: String, effort: String?, requestID: UUID) async throws -> InsightCodexTurn {
        guard let thread else { throw InsightCodexError.invalidResponse }
        if let effort, !thread.supportedReasoningEfforts.contains(effort) {
            throw InsightCodexError.unsupportedReasoningEffort
        }
        struct Request: Encodable { let text: String; let effort: String?; let requestID: UUID }
        return try await post(path: "v1/sessions/\(thread.sessionID)/turn", body: Request(
            text: text, effort: effort, requestID: requestID
        ))
    }

    /// This request also renews the host lease. Poll only while the foreground scope is active.
    func events(after cursor: Int) async throws -> InsightCodexEventBatch {
        guard let thread else { throw InsightCodexError.invalidResponse }
        let result: InsightCodexEventBatch = try await get(
            path: "v1/sessions/\(thread.sessionID)/events", query: [URLQueryItem(name: "after", value: String(cursor))]
        )
        guard result.cursor >= cursor,
              result.events.allSatisfy({ $0.scope == scope && $0.threadID == thread.threadID && $0.sequence > cursor }),
              zip(result.events, result.events.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }),
              result.events.last.map({ $0.sequence <= result.cursor }) ?? true else {
            throw InsightCodexError.scopeMismatch
        }
        return result
    }

    func submitToolResult(callID: String, text: String, success: Bool) async throws {
        guard let thread else { throw InsightCodexError.invalidResponse }
        struct Request: Encodable { let callID: String; let text: String; let success: Bool }
        struct Response: Decodable { let accepted: Bool }
        let response: Response = try await post(path: "v1/sessions/\(thread.sessionID)/tool-result",
            body: Request(callID: callID, text: text, success: success))
        guard response.accepted else { throw InsightCodexError.invalidResponse }
    }

    func pause() async throws {
        guard let thread else { return }
        struct Request: Encodable {}
        struct Response: Decodable { let paused: Bool }
        let response: Response = try await post(path: "v1/sessions/\(thread.sessionID)/interrupt", body: Request())
        guard response.paused else { throw InsightCodexError.invalidResponse }
        self.thread = nil
    }

    func close() async throws {
        guard let thread else { return }
        struct Request: Encodable {}
        struct Response: Decodable { let closed: Bool }
        let response: Response = try await post(path: "v1/sessions/\(thread.sessionID)/close", body: Request())
        guard response.closed else { throw InsightCodexError.invalidResponse }
        self.thread = nil
    }

    /// Also removes the host's protocol history. The owner retries failures using the local
    /// conversation deletion tombstone; closing the view alone must not call this method.
    func removeConversation() async throws {
        struct Request: Encodable { let scope: InsightCodexScope }
        struct Response: Decodable { let removed: Bool }
        let response: Response = try await post(path: "v1/conversations/remove", body: Request(scope: scope))
        guard response.removed else { throw InsightCodexError.invalidResponse }
        thread = nil
    }

    private func get<Response: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> Response {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw InsightCodexError.invalidResponse }
        return try await perform(URLRequest(url: url))
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ initialRequest: URLRequest) async throws -> Response {
        var request = initialRequest
        request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(bridgeToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url?.host == configuration.baseURL.host,
              response.url?.scheme == configuration.baseURL.scheme,
              response.url?.port == configuration.baseURL.port,
              data.count <= 2 * 1024 * 1024 else { throw InsightCodexError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            guard let failure = try? JSONDecoder().decode(Failure.self, from: data) else {
                throw InsightCodexError.invalidResponse
            }
            throw InsightCodexError.host(code: failure.error.code)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw InsightCodexError.invalidResponse
        }
        return decoded
    }
}
