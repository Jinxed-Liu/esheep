import SwiftData
import UIKit
import XCTest
@testable import eSheepNext

@MainActor
final class InsightLifecycleTests: XCTestCase {
    func testSameAccountRefreshAndReauthenticationDoNotChangeIdentityRevision() {
        let accountID = UUID()
        let session = AppSession(
            activeAccountProfileID: accountID,
            persistActiveAccountProfileID: { _ in }, clearActiveAccountProfileID: {}
        )
        let identityRevision = session.authenticationIdentityRevision
        let refreshRevision = session.authenticationRevision
        session.requestAuthenticationRefresh()
        XCTAssertEqual(session.authenticationIdentityRevision, identityRevision)
        XCTAssertEqual(session.authenticationRevision, refreshRevision + 1)
        session.authenticationDidSucceed(accountProfileID: accountID)
        XCTAssertEqual(session.authenticationIdentityRevision, identityRevision)
        session.authenticationDidSucceed(accountProfileID: UUID())
        XCTAssertEqual(session.authenticationIdentityRevision, identityRevision + 1)
        session.authenticationDidSignOut()
        XCTAssertEqual(session.authenticationIdentityRevision, identityRevision + 2)
    }

    func testBriefBackgroundAndLateExpirationPreserveTheAdmittedResponse() async throws {
        let backgroundTasks = FakeBackgroundTasks()
        let coordinator = InsightSessionCoordinator(backgroundTasks: backgroundTasks)
        let scope = InsightConversationScope(accountID: UUID(), farmID: UUID())
        coordinator.activate(scope: scope)
        let requestID = UUID()
        try await coordinator.acquire(scope: scope, requestID: requestID)
        coordinator.prepareForBackgroundTransition()
        XCTAssertEqual(backgroundTasks.beginCount, 1)
        coordinator.setForeground(false)
        XCTAssertTrue(coordinator.allowsWork(scope: scope))
        XCTAssertEqual(coordinator.requestQueue.entries[requestID]?.state, .running)
        coordinator.setForeground(true)
        XCTAssertEqual(backgroundTasks.ended.count, 1)
        backgroundTasks.expireMostRecent()
        XCTAssertEqual(coordinator.requestQueue.entries[requestID]?.state, .running)
        coordinator.release(requestID: requestID)
    }

    func testExpirationAndAuthenticationFailureRevokeBackgroundAdmission() async throws {
        let backgroundTasks = FakeBackgroundTasks()
        let coordinator = InsightSessionCoordinator(backgroundTasks: backgroundTasks)
        let scope = InsightConversationScope(accountID: UUID(), farmID: UUID())
        coordinator.activate(scope: scope)
        let requestID = UUID()
        try await coordinator.acquire(scope: scope, requestID: requestID)
        coordinator.setForeground(false)
        backgroundTasks.expireMostRecent()
        XCTAssertFalse(coordinator.allowsWork(scope: scope))
        XCTAssertEqual(coordinator.requestQueue.entries[requestID]?.state, .paused)
        XCTAssertEqual(backgroundTasks.ended.count, 1)
        coordinator.setForeground(true)
        coordinator.resumeBackgroundPausesIfVerified(scope: scope, accessStatus: .checking)
        XCTAssertEqual(coordinator.requestQueue.activeRequestCount, 0)
        coordinator.resumeBackgroundPausesIfVerified(scope: scope, accessStatus: .requiresSignIn("真实会话已失效"))
        XCTAssertEqual(coordinator.requestQueue.activeRequestCount, 0)
        XCTAssertEqual(backgroundTasks.ended.count, 1)
    }

    func testFailedSystemLeaseCannotLeaveUnboundedBackgroundWork() async throws {
        let backgroundTasks = FakeBackgroundTasks()
        backgroundTasks.grantsLease = false
        let coordinator = InsightSessionCoordinator(backgroundTasks: backgroundTasks)
        let scope = InsightConversationScope(accountID: UUID(), farmID: UUID())
        coordinator.activate(scope: scope)
        let requestID = UUID()
        try await coordinator.acquire(scope: scope, requestID: requestID)
        coordinator.setForeground(false)
        XCTAssertFalse(coordinator.allowsWork(scope: scope))
        XCTAssertEqual(coordinator.requestQueue.entries[requestID]?.state, .paused)
        XCTAssertEqual(coordinator.requestQueue.activeRequestCount, 0)
    }
}

@MainActor
private final class FakeBackgroundTasks: InsightBackgroundTaskManaging {
    var grantsLease = true
    private(set) var beginCount = 0
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var expiration: (@MainActor @Sendable () -> Void)?

    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        beginCount += 1
        self.expiration = expiration
        return grantsLease ? UIBackgroundTaskIdentifier(rawValue: beginCount) : .invalid
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) { ended.append(identifier) }
    func expireMostRecent() { expiration?() }
}
