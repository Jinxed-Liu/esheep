import XCTest
import Supabase
@testable import eSheepNext

@MainActor
final class AccountAccessResolverTests: XCTestCase {
    func testNetworkFailureKeepsLocalWorkspaceAvailableAndPausesCloudOperations() async {
        let account = makeAccount()

        let status = await AccountAccessResolver.resolve(
            for: account,
            appleStatusProvider: { .authorized },
            remoteSessionProvider: {
                throw IdentityWorkerError.networkUnavailable(
                    host: "identity.example",
                    code: .notConnectedToInternet
                )
            }
        )

        guard case .localOnly = status else {
            return XCTFail("网络失败应进入本地可用状态，实际为 \(status)")
        }
        XCTAssertFalse(status.allowsCloudOperations)
        XCTAssertFalse(status.requiresSignIn)
    }

    func testAppleRevocationRequiresReauthenticationWithoutCallingRemoteSession() async {
        let account = makeAccount()
        var remoteSessionWasCalled = false

        let status = await AccountAccessResolver.resolve(
            for: account,
            appleStatusProvider: { .requiresSignIn },
            remoteSessionProvider: {
                remoteSessionWasCalled = true
                return self.makeRemoteStatus(accountID: account.effectiveAccountID)
            }
        )

        XCTAssertTrue(status.requiresSignIn)
        XCTAssertFalse(remoteSessionWasCalled)
    }

    func testAppleUnavailableRemainsVisibleWhenRemoteSessionIsValid() async {
        let account = makeAccount()

        let status = await AccountAccessResolver.resolve(
            for: account,
            appleStatusProvider: { .unavailable("暂时无法验证 Apple 登录状态。") },
            remoteSessionProvider: {
                self.makeRemoteStatus(accountID: account.effectiveAccountID)
            }
        )

        guard case .availableWithWarning(let message) = status else {
            return XCTFail("Apple 状态不可用不应被折叠成已验证，实际为 \(status)")
        }
        XCTAssertTrue(message.contains("暂时无法验证"))
        XCTAssertTrue(status.allowsCloudOperations)
    }

    func testRemoteAccountMismatchRequiresReauthentication() async {
        let account = makeAccount()

        let status = await AccountAccessResolver.resolve(
            for: account,
            appleStatusProvider: { .authorized },
            remoteSessionProvider: {
                self.makeRemoteStatus(accountID: UUID())
            }
        )

        XCTAssertTrue(status.requiresSignIn)
        XCTAssertFalse(status.allowsCloudOperations)
    }

    func testOnlyDefinitiveSessionErrorsRequireFreshAuthentication() {
        XCTAssertTrue(IdentityWorkerError.missingSession.requiresFreshAuthentication)
        XCTAssertTrue(
            IdentityWorkerError.server(
                code: "invalid_refresh_token",
                message: "expired"
            ).requiresFreshAuthentication
        )
        XCTAssertFalse(
            IdentityWorkerError.server(
                code: "service_unavailable",
                message: "retry later"
            ).requiresFreshAuthentication
        )
        XCTAssertFalse(IdentityWorkerError.invalidResponse.requiresFreshAuthentication)
    }

    func testMissingSupabaseSessionRequiresReauthenticationInsteadOfOfflineMode() async {
        let account = makeAccount()

        let status = await AccountAccessResolver.resolve(
            for: account,
            appleStatusProvider: { .authorized },
            remoteSessionProvider: {
                throw AuthError.sessionMissing
            }
        )

        XCTAssertTrue(status.requiresSignIn)
        XCTAssertFalse(status.allowsCloudOperations)
    }

    func testOnlyDefinitiveSupabaseSessionErrorsRequireFreshAuthentication() {
        XCTAssertTrue(AuthError.sessionMissing.requiresFreshAuthentication)
        XCTAssertTrue(
            AuthError.api(
                message: "expired",
                errorCode: .refreshTokenNotFound,
                underlyingData: Data(),
                underlyingResponse: HTTPURLResponse(
                    url: URL(string: "https://example.com")!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!
            ).requiresFreshAuthentication
        )
        XCTAssertFalse(
            AuthError.api(
                message: "temporarily unavailable",
                errorCode: .unexpectedFailure,
                underlyingData: Data(),
                underlyingResponse: HTTPURLResponse(
                    url: URL(string: "https://example.com")!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!
            ).requiresFreshAuthentication
        )
    }

    private func makeAccount() -> AccountProfile {
        let account = AccountProfile(
            appleUserIdentifier: "apple-test-user",
            displayName: "测试账户",
            serverBindingStateRaw: ServerBindingState.verified.rawValue,
            authenticationMethod: .apple
        )
        account.serverAccountID = UUID()
        return account
    }

    private func makeRemoteStatus(accountID: UUID) -> WorkerAccountStatus {
        WorkerAccountStatus(
            accountID: accountID,
            displayName: "测试账户",
            status: "active",
            memberships: []
        )
    }
}
