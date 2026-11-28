import Foundation

enum ProductionBackend: String, Decodable, Sendable {
    case hosted, maintenance, mini

    static let hostedOrigin = "https://rnqrvthbunrzqtprquqx.supabase.co"
    static let miniOrigin = "https://api.esheepplus.com"
    static let selectionKey = "eSheepNext.productionBackend"
    static let changed = Notification.Name("eSheepNext.productionBackendChanged")
    static var selected: Self {
        UserDefaults.standard.string(forKey: selectionKey) == "mini" ? .mini : .hosted
    }

    func matches(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        switch self {
        case .hosted: return url.host == "rnqrvthbunrzqtprquqx.supabase.co"
        case .mini: return url.host == "api.esheepplus.com"
        case .maintenance: return false
        }
    }
}

actor ProductionBackendStatus {
    static let shared = ProductionBackendStatus()
    private struct Payload: Decodable { let state: ProductionBackend }
    static let endpoint = URL(string: "https://app.esheepplus.com/api/backend-status")!

    static func decode(_ bytes: Data, _ response: URLResponse) -> ProductionBackend? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == endpoint, http.mimeType == "application/json", bytes.count < 1024 else { return nil }
        return (try? JSONDecoder().decode(Payload.self, from: bytes))?.state
    }

    private var lastState: ProductionBackend?
    private var lastChecked = Date.distantPast
    private var inFlight: Task<ProductionBackend?, Never>?

    func refresh() async -> ProductionBackend? {
        if let inFlight { return await inFlight.value }
        let probe = Task<ProductionBackend?, Never> {
            var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (bytes, response) = try? await URLSession.shared.data(for: request),
                  let state = Self.decode(bytes, response) else { return nil }
            let previous = ProductionBackend.selected
            if state != .maintenance && state != previous {
                UserDefaults.standard.set(state.rawValue, forKey: ProductionBackend.selectionKey)
                await MainActor.run {
                    NotificationCenter.default.post(name: ProductionBackend.changed, object: previous.rawValue)
                }
            }
            return state
        }
        inFlight = probe
        let result = await probe.value
        inFlight = nil
        lastState = result
        lastChecked = Date()
        return result
    }

    func authorize(_ url: URL, method: String?) async throws {
        if ["GET", "HEAD"].contains(method ?? "GET"), lastState?.matches(url) == true,
           Date().timeIntervalSince(lastChecked) < 15 { return }
        guard let state = await refresh(), state.matches(url) else {
            throw URLError(.notConnectedToInternet, userInfo: [
                NSLocalizedDescriptionKey: "云端维护中或暂时无法确认服务状态。待传记录已保留。"
            ])
        }
    }
}
