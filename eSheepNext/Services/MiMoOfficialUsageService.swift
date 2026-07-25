import Foundation
import WebKit

struct MiMoOfficialUsageSnapshot: Sendable, Equatable {
    let balance: Decimal
    let currency: String
    let cashBalance: Decimal?
    let giftBalance: Decimal?
    let planCode: String?
    let planPeriodEnd: Date?
    let planExpired: Bool
    let tokenUsed: Int64?
    let tokenLimit: Int64?
    let updatedAt: Date

    var tokenRemaining: Int64? {
        guard let tokenUsed, let tokenLimit else { return nil }
        return max(0, tokenLimit - tokenUsed)
    }

    var tokenFraction: Double? {
        guard let tokenUsed, let tokenLimit, tokenLimit > 0 else { return nil }
        return min(1, max(0, Double(tokenUsed) / Double(tokenLimit)))
    }
}

enum MiMoOfficialUsageError: LocalizedError {
    case loginRequired
    case expiredSession
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            "请先登录 MiMo 官方账户，再查询额度。"
        case .expiredSession:
            "MiMo 官方登录已过期，请重新登录。"
        case .invalidResponse:
            "MiMo 官方额度数据暂时无法解析。"
        case .server(let status):
            "MiMo 官方额度服务暂不可用（\(status)）。"
        }
    }
}

actor MiMoOfficialUsageService {
    static let shared = MiMoOfficialUsageService()

    private let baseURL = URL(string: "https://platform.xiaomimimo.com/api/v1")!
    private let requiredCookieNames = ["api-platform_serviceToken", "userId"]
    private let optionalCookieNames = ["api-platform_ph", "api-platform_slh"]

    func fetch() async throws -> MiMoOfficialUsageSnapshot {
        let cookieHeader = try await officialCookieHeader()
        async let balanceData = request(path: "balance", cookieHeader: cookieHeader)
        async let detailData = optionalRequest(path: "tokenPlan/detail", cookieHeader: cookieHeader)
        async let usageData = optionalRequest(path: "tokenPlan/usage", cookieHeader: cookieHeader)
        return try Self.parse(
            balanceData: await balanceData,
            detailData: await detailData,
            usageData: await usageData
        )
    }

    func hasOfficialSession() async -> Bool {
        (try? await officialCookieHeader()) != nil
    }

    func clearSession() async {
        let store = await MainActor.run {
            WKWebsiteDataStore.default().httpCookieStore
        }
        let cookies = await store.allCookies()
        for cookie in cookies where Self.isOfficialCookie(cookie) {
            await store.deleteCookie(cookie)
        }
    }

    private func officialCookieHeader() async throws -> String {
        let store = await MainActor.run {
            WKWebsiteDataStore.default().httpCookieStore
        }
        let cookies = await store.allCookies()
            .filter(Self.isOfficialCookie)
            .filter { requiredCookieNames.contains($0.name) || optionalCookieNames.contains($0.name) }
        let byName = Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { _, latest in latest })
        guard requiredCookieNames.allSatisfy({ byName[$0]?.isEmpty == false }) else {
            throw MiMoOfficialUsageError.loginRequired
        }
        return (requiredCookieNames + optionalCookieNames)
            .compactMap { name in byName[name].map { "\(name)=\($0)" } }
            .joined(separator: "; ")
    }

    private func request(path: String, cookieHeader: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-timeZone")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "https://platform.xiaomimimo.com/#/console/balance",
            forHTTPHeaderField: "Referer"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiMoOfficialUsageError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return data
        case 300..<400, 401:
            throw MiMoOfficialUsageError.loginRequired
        case 403:
            throw MiMoOfficialUsageError.expiredSession
        default:
            throw MiMoOfficialUsageError.server(http.statusCode)
        }
    }

    private func optionalRequest(path: String, cookieHeader: String) async -> Data? {
        try? await request(path: path, cookieHeader: cookieHeader)
    }

    static func parse(
        balanceData: Data,
        detailData: Data?,
        usageData: Data?,
        now: Date = .now
    ) throws -> MiMoOfficialUsageSnapshot {
        let decoder = JSONDecoder()
        let balanceResponse = try decoder.decode(BalanceResponse.self, from: balanceData)
        guard balanceResponse.code == 0,
              let balancePayload = balanceResponse.data,
              let balance = Decimal(string: balancePayload.balance),
              !balancePayload.currency.isEmpty else {
            if balanceResponse.code == 401 {
                throw MiMoOfficialUsageError.loginRequired
            }
            if balanceResponse.code == 403 {
                throw MiMoOfficialUsageError.expiredSession
            }
            throw MiMoOfficialUsageError.invalidResponse
        }

        let detail = detailData
            .flatMap { try? decoder.decode(TokenPlanDetailResponse.self, from: $0) }
            .flatMap(\.data)
        let usageItem = usageData
            .flatMap { try? decoder.decode(TokenPlanUsageResponse.self, from: $0) }
            .flatMap(\.data?.monthUsage?.items.first)
        return MiMoOfficialUsageSnapshot(
            balance: balance,
            currency: balancePayload.currency,
            cashBalance: balancePayload.cashBalance.flatMap { Decimal(string: $0) },
            giftBalance: balancePayload.giftBalance.flatMap { Decimal(string: $0) },
            planCode: detail?.planCode,
            planPeriodEnd: detail?.currentPeriodEnd.flatMap(parseOfficialDate),
            planExpired: detail?.expired ?? false,
            tokenUsed: usageItem?.used,
            tokenLimit: usageItem?.limit,
            updatedAt: now
        )
    }

    private static func parseOfficialDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func isOfficialCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased()
        return domain == "xiaomimimo.com"
            || domain == ".xiaomimimo.com"
            || domain.hasSuffix(".xiaomimimo.com")
    }

    private struct BalanceResponse: Decodable {
        let code: Int
        let data: BalancePayload?
    }

    private struct BalancePayload: Decodable {
        let balance: String
        let currency: String
        let cashBalance: String?
        let giftBalance: String?
    }

    private struct TokenPlanDetailResponse: Decodable {
        let data: TokenPlanDetailPayload?
    }

    private struct TokenPlanDetailPayload: Decodable {
        let planCode: String?
        let currentPeriodEnd: String?
        let expired: Bool
    }

    private struct TokenPlanUsageResponse: Decodable {
        let data: TokenPlanUsagePayload?
    }

    private struct TokenPlanUsagePayload: Decodable {
        let monthUsage: MonthUsage?
    }

    private struct MonthUsage: Decodable {
        let items: [UsageItem]
    }

    private struct UsageItem: Decodable {
        let used: Int64
        let limit: Int64
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }

    func deleteCookie(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            delete(cookie) { continuation.resume() }
        }
    }
}
