import Foundation
import OSLog

/// The existing first-party web gateway reaches the same production project.
enum AccountLoginRoute: CaseIterable, Sendable {
    case direct, webGateway

    static let projectHost = "rnqrvthbunrzqtprquqx.supabase.co"
    private static let gatewayHost = "app.esheepplus.com"

    static func isProductionProject(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == projectHost && url.port == nil
            && url.user == nil && url.password == nil
    }

    static func isAccountRequest(_ request: URLRequest) -> Bool {
        guard let url = request.url, isProductionProject(url) else { return false }
        switch (request.httpMethod, url.path) {
        case ("POST", "/auth/v1/token"), ("POST", "/auth/v1/signup"),
             ("GET", "/auth/v1/user"), ("GET", "/rest/v1/profiles"),
             ("POST", "/rest/v1/rpc/record_legal_consent"), ("POST", "/rest/v1/rpc/register_device"):
            return true
        default:
            return false
        }
    }

    func routed(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url, Self.isProductionProject(url) else { throw URLError(.badURL) }
        guard self == .webGateway else { return request }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        parts.host = Self.gatewayHost
        parts.percentEncodedPath = "/api/cloud" + parts.percentEncodedPath
        guard let destination = parts.url else { throw URLError(.badURL) }
        var result = request
        result.url = destination
        result.setValue(Self.projectHost, forHTTPHeaderField: "x-esheep-cloud-host")
        return result
    }

    static func available(publicKey: String) async throws -> Self {
        guard let url = URL(string: "https://\(projectHost)/auth/v1/health") else { throw URLError(.badURL) }
        var health = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        health.setValue(publicKey, forHTTPHeaderField: "apikey")
        let request = health
        return try await firstAvailable { route in
            let (data, response) = try await AccountLoginNetwork.session.data(for: route.routed(request))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  route == .direct || http.value(forHTTPHeaderField: "x-esheep-cloud-transport") == "same-origin",
                  (try? JSONDecoder().decode(Health.self, from: data))?.name == "GoTrue"
            else { throw URLError(.badServerResponse) }
        }
    }

    private struct Health: Decodable { let name: String }

    /// Only public health checks race. A password, refresh token or account mutation is sent once.
    static func firstAvailable(check: @escaping @Sendable (Self) async throws -> Void) async throws -> Self {
        try await withThrowingTaskGroup(of: Self.self) { group in
            for route in allCases {
                group.addTask {
                    try await check(route)
                    return route
                }
            }
            defer { group.cancelAll() }
            var failure: Error = URLError(.cannotConnectToHost)
            while let result = await group.nextResult() {
                try Task.checkCancellation()
                switch result {
                case .success(let route): return route
                case .failure(let error): failure = error
                }
            }
            throw failure
        }
    }
}

private final class AccountLoginNetwork: NSObject, URLSessionTaskDelegate {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: AccountLoginNetwork(), delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let url = task.originalRequest?.url, url.path.hasSuffix("/auth/v1/token"),
              let transaction = metrics.transactionMetrics.last else { return }
        let isDirect = url.host == AccountLoginRoute.projectHost
        let status = (transaction.response as? HTTPURLResponse)?.statusCode ?? 0
        Logger(subsystem: "com.sheepfarm.ios", category: "LoginTransport")
            .info("Token request: direct=\(isDirect, privacy: .public) cellular=\(transaction.isCellular, privacy: .public) HTTP=\(status, privacy: .public)")
    }
}

/// Installed only on the production project's SDK session. Realtime, storage and farm writes
/// keep their own transport. The SDK remains responsible for tokens, refresh and Keychain storage.
final class AccountLoginURLProtocol: URLProtocol, @unchecked Sendable {
    private var operation: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { AccountLoginRoute.isAccountRequest(request) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        operation = Task {
            do {
                guard let key = request.value(forHTTPHeaderField: "apikey") else { throw URLError(.badServerResponse) }
                let route = try await AccountLoginRoute.available(publicKey: key)
                try Task.checkCancellation()
                let outbound = try route.routed(request)
                let (data, response) = try await AccountLoginNetwork.session.data(for: outbound)
                guard let http = response as? HTTPURLResponse, !(300..<400).contains(http.statusCode)
                else { throw URLError(.badServerResponse) }
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }

    override func stopLoading() { operation?.cancel() }
}
