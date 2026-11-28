#if ESHEEP_APPLE_PILOT
import AuthenticationServices
import CryptoKit
import Darwin
import Foundation
import Supabase
import SwiftUI

/// Included only in the individually distributed acceptance archive.
struct MiniAppleAcceptanceView: View {
    static var supportsDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        var system = utsname()
        guard uname(&system) == 0 else { return false }
        let model = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model == "iPhone17,1"
        #endif
    }

    @State private var originalUser: UUID?
    @State private var nonce: String?
    @State private var submitting = false
    @State private var passed = false
    @State private var message = "正在核对手机当前登录的牧场账号。"

    var body: some View {
        Form {
            Section("原账号") {
                if let originalUser {
                    LabeledContent("验收编号", value: Self.fingerprint(originalUser))
                        .monospacedDigit().textSelection(.enabled)
                }
                Text(message)
            }
            if originalUser != nil && !passed {
                Section {
                    SignInWithAppleButton(.continue) { request in
                        let value = AppleIdentityActor.makeNonce()
                        nonce = value
                        request.nonce = AppleIdentityActor.hashedNonce(value)
                    } onCompletion: { result in
                        guard !submitting else { return }
                        let expectedNonce = nonce
                        nonce = nil
                        guard case let .success(authorization) = result,
                              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                              let expectedNonce, let originalUser else {
                            message = "Apple 授权未完成。"
                            return
                        }
                        submitting = true
                        Task {
                            defer { submitting = false }
                            do {
                                let payload = try AppleIdentityActor.payload(from: credential, rawNonce: expectedNonce)
                                try await MiniAppleAcceptance.verify(payload, originalUser: originalUser)
                                passed = true
                                message = "Apple 登录通过，会话刷新通过，两次均为原牧场账号。"
                            } catch let error as MiniAppleAcceptance.Failure {
                                message = error.message
                            } catch {
                                message = "未能完成 Apple 授权。"
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.black).frame(height: 46).disabled(submitting)
                } footer: {
                    Text("等收到入口开放通知后，再点一次继续。牧场业务仍使用原服务。")
                }
            }
        }
        .navigationTitle("Mac mini 登录验收")
        .task {
            guard Self.supportsDevice, ProductionBackend.selected == .hosted,
                  let hosted = AccountIdentityClients.client(for: .hosted) else {
                message = "当前设备或牧场服务不符合此次验收条件。"
                return
            }
            do {
                originalUser = try await hosted.supabase.auth.user().id
                message = "原账号已核对。"
            } catch {
                message = "无法核对原登录状态，请返回并检查网络后重试。"
            }
        }
    }

    private static func fingerprint(_ id: UUID) -> String {
        let bytes = Data(("esheep-apple-pilot-v1/" + id.uuidString.lowercased()).utf8)
        return SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private enum MiniAppleAcceptance {
    enum Failure: Error {
        case window, login, identity, refresh
        var message: String {
            switch self {
            case .window: "验收入口尚未开放或已到期。请等收到通知后再继续。"
            case .login: "mini 未接受本次 Apple 登录。请核对入口开放时间及账号映射。"
            case .identity: "mini 返回的账号与手机原账号不一致，本次验收停止。"
            case .refresh: "Apple 登录通过，mini 会话刷新尚未通过。"
            }
        }
    }

    static func verify(_ payload: AppleAuthorizationPayload, originalUser: UUID) async throws {
        guard let mini = SupabaseAccountConfiguration.credentials(for: .mini) else { throw Failure.login }
        let origin = mini.url.appendingPathComponent("auth/v1")
        let transport = URLSession(configuration: .ephemeral, delegate: PilotRedirectPolicy(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        // The regular API may later serve the whole farm. This build works only during its own window.
        var check = URLRequest(url: mini.url.appendingPathComponent(".well-known/esheep-apple-16pro-170"))
        check.cachePolicy = .reloadIgnoringLocalCacheData
        check.timeoutInterval = 8
        guard let (_, response) = try? await transport.data(for: check),
              let http = response as? HTTPURLResponse, http.statusCode == 204,
              http.value(forHTTPHeaderField: "X-ESheep-Acceptance") == "16pro-170",
              let value = http.value(forHTTPHeaderField: "X-ESheep-Expires"),
              let expiry = TimeInterval(value) else { throw Failure.window }
        let remaining = expiry - Date.now.timeIntervalSince1970
        guard remaining > 0, remaining <= 1800 else { throw Failure.window }
        let client = AuthClient(
            url: origin, headers: ["apikey": mini.publishableKey],
            storageKey: "esheep-apple-acceptance", localStorage: PilotSessionMemory(),
            fetch: { request in
                guard let url = request.url, url.scheme == "https", url.host == origin.host,
                      url.port == nil, url.user == nil, url.password == nil,
                      url.path == "/auth/v1/token", request.httpMethod == "POST",
                      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      query.count == 1, query[0].name == "grant_type",
                      ["id_token", "refresh_token"].contains(query[0].value ?? "") else {
                    throw URLError(.unsupportedURL)
                }
                return try await transport.data(for: request)
            }, autoRefreshToken: false
        )
        let signedIn: Session
        do {
            signedIn = try await client.signInWithIdToken(credentials: .init(
                provider: .apple, idToken: payload.identityToken, nonce: payload.rawNonce
            ))
        } catch { throw Failure.login }
        guard signedIn.user.id == originalUser else { throw Failure.identity }
        let refreshed: Session
        do { refreshed = try await client.refreshSession() }
        catch { throw Failure.refresh }
        guard refreshed.user.id == originalUser else { throw Failure.identity }
    }
}

private final class PilotRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class PilotSessionMemory: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { contents[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { contents[key] } }
    func remove(key: String) throws { lock.withLock { contents[key] = nil } }
}
#endif
