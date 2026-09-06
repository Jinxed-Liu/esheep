import Foundation

/// Stable product-level failures; transport SDK details stay at the gateway.
struct ESheepCloudSyncFailure: Error, LocalizedError, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case network, serviceUnavailable, authentication, permission
        case conflict, server, integrity, unknown
    }

    let kind: Kind
    let traceID: String
    let statusCode: Int?

    init(kind: Kind, statusCode: Int? = nil, traceID: String = UUID().uuidString.lowercased()) {
        self.kind = kind
        self.statusCode = statusCode
        self.traceID = traceID
    }

    var errorDescription: String? {
        let message: String = switch kind {
        case .network: "网络暂不可用，联网后继续保存"
        case .serviceUnavailable: "云端保存服务暂不可用"
        case .authentication: "账号登录已经失效，请重新登录"
        case .permission: "云端未允许这次保存，请检查账号与设备权限"
        case .conflict: "这项内容需要核对后才能保存"
        case .server: "云端暂时无法处理，稍后自动重试"
        case .integrity: "牧场资料核对未通过，已保留本机内容"
        case .unknown: "暂未完成云端保存，已保留本机内容"
        }
        return "\(message)。诊断编号：\(traceID)"
    }

    func retryDelay(attempt: Int) -> TimeInterval {
        switch kind {
        case .serviceUnavailable, .authentication, .permission, .conflict, .integrity:
            900
        case .network, .server, .unknown:
            min(300, pow(2, Double(min(8, max(0, attempt - 1)))) * 2)
        }
    }
}
