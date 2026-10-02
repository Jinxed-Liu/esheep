import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class FixtureBook: @unchecked Sendable {
    static let shared = FixtureBook()
    struct Fixture {
        let data: Data
        let status: Int
        let responseURL: URL?
    }
    private let lock = NSLock()
    private var fixtures: [Fixture] = []
    private var requests: [URLRequest] = []

    func append<Value: Encodable>(_ value: Value, status: Int = 200, responseURL: URL? = nil) throws {
        let fixture = Fixture(data: try JSONEncoder().encode(value), status: status, responseURL: responseURL)
        lock.lock(); defer { lock.unlock() }
        fixtures.append(fixture)
    }
    func next(for request: URLRequest) -> Fixture? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return fixtures.isEmpty ? nil : fixtures.removeFirst()
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }
    var last: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }
}

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = FixtureBook.shared.next(for: request),
              let response = HTTPURLResponse(url: fixture.responseURL ?? request.url!,
                  statusCode: fixture.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct InsightCodexProtocolRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }
    @MainActor static func reject(_ expected: InsightCodexError, _ action: () async throws -> Void) async throws {
        do {
            try await action()
            throw Failure(description: "Expected Codex rejection: \(expected)")
        } catch let error as InsightCodexError {
            try require(error == expected, "Expected \(expected), got \(error)")
        }
    }
    static func event(sequence: Int, scope: InsightCodexScope, status: String = "completed") -> InsightCodexEvent {
        .init(sequence: sequence, kind: .turnCompleted, scope: scope, threadID: "thread-1",
              turnID: "turn-1", callID: nil, toolName: nil, argumentsJSON: nil,
              text: nil, status: status, errorCode: nil)
    }

    static func main() async throws {
        let scope = InsightCodexScope(accountID: UUID(), farmID: UUID(), conversationID: UUID())
        let host = try InsightCodexHostConfiguration(hostID: UUID(), baseURL: URL(string: "https://bridge.example.invalid")!)
        try require(!InsightCodexConnectionGate().isAvailable, "Default gate must be closed.")
        let incomplete = InsightCodexConnectionGate(partnerApproved: true, callbackApproved: true,
            privacyApproved: true, runtimeIsolationVerified: false)
        try require(!incomplete.isAvailable, "Runtime isolation must be a mandatory gate.")
        let gate = InsightCodexConnectionGate(partnerApproved: true, callbackApproved: true,
            privacyApproved: true, runtimeIsolationVerified: true)
        try require(gate.isAvailable, "Explicit approved gate rejected.")
        for address in ["http://public.example", "https://user:password@bridge.example", "https://bridge.example?token=x"] {
            do {
                _ = try InsightCodexHostConfiguration(hostID: UUID(), baseURL: URL(string: address)!)
                throw Failure(description: "Insecure bridge URL accepted: \(address)")
            } catch InsightCodexError.insecureHost {}
        }
        _ = try InsightCodexHostConfiguration(hostID: UUID(), baseURL: URL(string: "http://127.0.0.1:8080")!)
        print("PASS: approval gates and secure host configuration")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let token = String(repeating: "x", count: 32) // Synthetic bridge credential, never a real token.
        try await reject(.unavailable(InsightCodexConnectionGate().unavailableReason!)) {
            _ = try InsightCodexClient(configuration: host, gate: .init(), scope: scope,
                                       bridgeToken: token, session: transport)
        }
        let client = try InsightCodexClient(configuration: host, gate: gate, scope: scope,
                                            bridgeToken: token, session: transport)
        let thread = InsightCodexThread(sessionID: String(repeating: "a", count: 64), scope: scope,
            threadID: "thread-1", modelSlug: "authorized-model", supportedReasoningEfforts: ["low", "medium", "high"],
            accessVerified: false)
        let wrongScope = InsightCodexScope(accountID: scope.accountID, farmID: UUID(), conversationID: scope.conversationID)
        let wrongThread = InsightCodexThread(sessionID: thread.sessionID, scope: wrongScope,
            threadID: thread.threadID, modelSlug: thread.modelSlug,
            supportedReasoningEfforts: thread.supportedReasoningEfforts, accessVerified: false)
        try FixtureBook.shared.append(wrongThread)
        try await reject(.scopeMismatch) {
            _ = try await client.open(modelSlug: thread.modelSlug, tools: [], instructions: "approved scope")
        }
        try FixtureBook.shared.append(thread)
        let opened = try await client.open(modelSlug: thread.modelSlug, tools: [], instructions: "approved scope")
        try require(opened == thread && !opened.accessVerified, "Catalog/thread creation must not imply model entitlement.")
        try require(FixtureBook.shared.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)",
                    "Authenticated bridge request lost its credential.")
        print("PASS: thread scope verification and entitlement remains unverified")

        let beforeRejectedEffort = FixtureBook.shared.count
        try await reject(.unsupportedReasoningEffort) {
            _ = try await client.startTurn(text: "question", effort: "ultra", requestID: UUID())
        }
        try require(FixtureBook.shared.count == beforeRejectedEffort, "Unsupported effort reached the host.")
        let requestID = UUID()
        try FixtureBook.shared.append(InsightCodexTurn(turnID: "turn-1", status: "running"))
        _ = try await client.startTurn(text: "question", effort: "medium", requestID: requestID)
        let body = try JSONSerialization.jsonObject(with: FixtureBook.shared.last!.httpBody!) as! [String: Any]
        try require(body["requestID"] as? String == requestID.uuidString, "Stable request ID changed in transport.")
        try require(body["effort"] as? String == "medium", "Native supported effort was not forwarded.")
        try require(body["max_output_tokens"] == nil && body["temperature"] == nil,
                    "MiMo request parameters leaked into the Codex transport.")
        print("PASS: native effort validation and stable turn request ID")

        try FixtureBook.shared.append(InsightCodexEventBatch(events: [event(sequence: 1, scope: wrongScope)], cursor: 1))
        try await reject(.scopeMismatch) { _ = try await client.events(after: 0) }
        try FixtureBook.shared.append(InsightCodexEventBatch(events: [event(sequence: 2, scope: scope), event(sequence: 1, scope: scope)], cursor: 2))
        try await reject(.scopeMismatch) { _ = try await client.events(after: 0) }
        try FixtureBook.shared.append(InsightCodexEventBatch(events: [event(sequence: 1, scope: scope)], cursor: 1))
        try await reject(.scopeMismatch) { _ = try await client.events(after: 1) }
        let completed = event(sequence: 2, scope: scope)
        try FixtureBook.shared.append(InsightCodexEventBatch(events: [completed], cursor: 2))
        let batch = try await client.events(after: 1)
        try require(batch.events == [completed] && completed.didCompleteSuccessfully,
                    "Verified ordered events were rejected.")
        try require(!event(sequence: 2, scope: scope, status: "failed").didCompleteSuccessfully,
                    "Failed turn was classified as complete.")
        try require(!event(sequence: 2, scope: scope, status: "interrupted").didCompleteSuccessfully,
                    "Interrupted turn was classified as complete.")
        print("PASS: event scope/order/replay checks and actual completion status")

        struct Models: Encodable { let models: [InsightCodexModel] }
        try FixtureBook.shared.append(Models(models: []), responseURL: URL(string: "https://another.example.invalid/v1/models")!)
        try await reject(.invalidResponse) { _ = try await client.models() }
        print("PASS: cross-host responses rejected")
        print("Codex transport regression passed: 5 behavioral checks; mock HTTP only, no subscription login or iOS build.")
    }
}
