import Foundation
import Observation

@MainActor
@Observable
final class LoginConnectionCheck {
    private(set) var message: String?
    private var isChecking = false

    /// A credential-free request lets iOS handle first-use network permission
    /// before the person submits a password. No account or farm data is sent.
    func check() async {
        guard !isChecking else { return }
        let endpoint = SupabaseAccountConfiguration.credentials?.url
            ?? IdentityWorkerConfiguration.baseURL
        guard let endpoint else { return }
        isChecking = true
        defer { isChecking = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            guard response is HTTPURLResponse else { throw URLError(.badServerResponse) }
            // Even a 401/404 proves connectivity; this is not an auth or
            // backend-health check and must never block the sign-in action.
            message = nil
        } catch {
            guard !Task.isCancelled else { return }
            message = "暂时无法连接网络。请检查无线局域网或蜂窝数据，并在系统设置中允许 eSheep+ 联网。"
        }
    }
}
