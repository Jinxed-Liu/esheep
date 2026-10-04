import Foundation

/// Compiles with the production queue on Linux or macOS, without iOS SDK stubs.
/// Tests scheduling behavior; it does not replace controller or iOS UI tests.
@main
struct InsightSessionQueueRegression {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    @MainActor
    static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        throw Failure(description: message)
    }

    @MainActor
    static func reject(
        _ expected: InsightSessionQueueError,
        _ action: () async throws -> Void
    ) async throws {
        do {
            try await action()
            throw Failure(description: "Expected queue rejection: \(expected)")
        } catch let error as InsightSessionQueueError {
            try require(String(describing: error) == String(describing: expected),
                        "Expected \(expected), got \(error)")
        }
    }

    @MainActor
    static func main() async throws {
        let scope = InsightSessionScope(accountID: UUID(), farmID: UUID())
        let otherAccount = InsightSessionScope(accountID: UUID(), farmID: scope.farmID)
        let otherFarm = InsightSessionScope(accountID: scope.accountID, farmID: UUID())
        let queue = InsightSessionRequestQueue(maximumConcurrentRequests: 2)
        queue.activate(scope: scope)
        let first = UUID(), second = UUID(), third = UUID(), fourth = UUID()
        let firstConversation = UUID()
        try await queue.acquire(scope: scope, requestID: first, conversationID: firstConversation)
        try await queue.acquire(scope: scope, requestID: second, conversationID: UUID())
        try require(queue.activeRequestCount == 2, "Two foreground slots must be admitted.")
        let thirdTask = Task { @MainActor in
            try await queue.acquire(scope: scope, requestID: third, conversationID: UUID())
        }
        try await eventually("Third request was not queued.") { queue.queuedRequestCount == 1 }
        let fourthTask = Task { @MainActor in
            try await queue.acquire(scope: scope, requestID: fourth, conversationID: UUID())
        }
        try await eventually("Fourth request was not queued.") { queue.queuedRequestCount == 2 }
        try require(queue.activeRequestCount == 2, "Queue exceeded its foreground slot limit.")
        queue.release(requestID: first)
        try await thirdTask.value
        try require(queue.entries[third]?.state == .running, "FIFO third request not running.")
        try require(queue.entries[fourth]?.state == .queued, "Fourth request bypassed FIFO.")
        queue.release(requestID: second)
        try await fourthTask.value
        try require(queue.activeRequestCount == 2, "Released slots did not admit queued work.")
        print("PASS: two foreground slots and FIFO admission")

        try await reject(.duplicateRequest) {
            try await queue.acquire(scope: scope, requestID: first, conversationID: UUID())
        }
        try await reject(.conversationBusy) {
            try await queue.acquire(scope: scope, requestID: UUID(),
                                    conversationID: queue.entries[third]!.conversationID)
        }
        print("PASS: stable request replay and overlapping conversation rejection")

        try await reject(.inactiveScope) {
            try await queue.acquire(scope: otherAccount, requestID: UUID())
        }
        try await reject(.inactiveScope) {
            try await queue.acquire(scope: otherFarm, requestID: UUID())
        }
        print("PASS: account and farm scope isolation")

        let waitingID = UUID()
        let waitingTask = Task { @MainActor in
            try await queue.acquire(scope: scope, requestID: waitingID, conversationID: UUID())
        }
        try await eventually("Background fixture not queued.") { queue.queuedRequestCount == 1 }
        queue.setForeground(false)
        try await reject(.paused) { try await waitingTask.value }
        try require(queue.activeRequestCount == 0 && queue.queuedRequestCount == 0,
                    "Background pause must release all admission slots.")
        try require(queue.entries[third]?.state == .paused && queue.entries[fourth]?.state == .paused,
                    "Running admission must become paused in background.")
        queue.setForeground(true)
        try require(queue.activeRequestCount == 0, "Foreground return silently restarted paused work.")
        print("PASS: background pause and explicit resume requirement")

        let scopeChangeRunning = UUID(), scopeChangeQueued = UUID()
        try await queue.acquire(scope: scope, requestID: scopeChangeRunning)
        try await queue.acquire(scope: scope, requestID: UUID())
        let scopeChangeTask = Task { @MainActor in
            try await queue.acquire(scope: scope, requestID: scopeChangeQueued)
        }
        try await eventually("Scope change fixture not queued.") { queue.queuedRequestCount == 1 }
        queue.activate(scope: otherFarm)
        try await reject(.paused) { try await scopeChangeTask.value }
        try require(queue.entries[scopeChangeRunning]?.state == .paused && queue.activeRequestCount == 0,
                    "Farm change kept old farm admission running.")
        print("PASS: switching farm pauses both running and queued admission")

        let serialQueue = InsightSessionRequestQueue(maximumConcurrentRequests: 1)
        serialQueue.activate(scope: scope)
        let runningID = UUID(), cancelledID = UUID(), nextID = UUID()
        try await serialQueue.acquire(scope: scope, requestID: runningID)
        let cancelledTask = Task { @MainActor in
            try await serialQueue.acquire(scope: scope, requestID: cancelledID)
        }
        try await eventually("Cancellation fixture not queued.") { serialQueue.queuedRequestCount == 1 }
        let nextTask = Task { @MainActor in
            try await serialQueue.acquire(scope: scope, requestID: nextID)
        }
        try await eventually("Next request not queued.") { serialQueue.queuedRequestCount == 2 }
        cancelledTask.cancel()
        do {
            try await cancelledTask.value
            throw Failure(description: "Cancelled queued task unexpectedly admitted.")
        } catch is CancellationError {}
        try require(serialQueue.entries[cancelledID]?.state == .cancelled,
                    "Cancellation state not preserved.")
        serialQueue.release(requestID: runningID)
        try await nextTask.value
        serialQueue.release(requestID: cancelledID)
        try require(serialQueue.entries[cancelledID]?.state == .cancelled,
                    "Late release resurrected a cancelled request.")
        try require(serialQueue.activeRequestCount == 1 && serialQueue.entries[nextID]?.state == .running,
                    "Cancelled waiter blocked the next queued task.")
        print("PASS: cancelled waiter cleanup and late-release safety")

        let resumeQueue = InsightSessionRequestQueue(maximumConcurrentRequests: 1)
        resumeQueue.activate(scope: scope)
        let resumeID = UUID(), resumeConversation = UUID(), blockingID = UUID(), aheadID = UUID()
        try await resumeQueue.acquire(scope: scope, requestID: resumeID, conversationID: resumeConversation)
        resumeQueue.release(requestID: resumeID)
        try await resumeQueue.acquire(scope: scope, requestID: blockingID)
        let aheadTask = Task { @MainActor in try await resumeQueue.acquire(scope: scope, requestID: aheadID) }
        try await eventually("Ahead-of-resume request not queued.") { resumeQueue.queuedRequestCount == 1 }
        let resumedTask = Task { @MainActor in
            try await resumeQueue.acquire(scope: scope, requestID: resumeID, conversationID: resumeConversation)
        }
        try await eventually("Released turn did not rejoin queue tail.") { resumeQueue.queuedRequestCount == 2 }
        resumeQueue.release(requestID: blockingID)
        try await aheadTask.value
        try require(resumeQueue.entries[resumeID]?.state == .queued && resumeQueue.activeRequestCount == 1,
                    "Resuming turn bypassed FIFO or foreground cap.")
        resumeQueue.release(requestID: aheadID)
        try await resumedTask.value
        resumeQueue.setForeground(false)
        resumeQueue.setForeground(true)
        try require(resumeQueue.activeRequestCount == 0, "Paused turn silently resumed with foreground.")
        try await resumeQueue.acquire(scope: scope, requestID: resumeID, conversationID: resumeConversation)
        resumeQueue.cancel(requestID: resumeID)
        do {
            try await resumeQueue.acquire(scope: scope, requestID: resumeID, conversationID: resumeConversation)
            throw Failure(description: "Cancelled durable turn was resumed.")
        } catch is CancellationError {}
        print("PASS: explicit same-turn resume joins FIFO tail and cancelled turn never resumes")

        let graceQueue = InsightSessionRequestQueue(maximumConcurrentRequests: 1)
        graceQueue.activate(scope: scope)
        let graceRunning = UUID(), graceWaiting = UUID()
        try await graceQueue.acquire(scope: scope, requestID: graceRunning)
        let graceWaitingTask = Task { @MainActor in
            try await graceQueue.acquire(scope: scope, requestID: graceWaiting)
        }
        try await eventually("Grace fixture did not queue.") { graceQueue.queuedRequestCount == 1 }
        graceQueue.setForeground(false, preservingRunningRequests: true)
        try await reject(.paused) { try await graceWaitingTask.value }
        try require(!graceQueue.isForeground && graceQueue.allowsRunningWork &&
                    graceQueue.activeRequestCount == 1 && graceQueue.entries[graceRunning]?.state == .running,
                    "Brief backgrounding interrupted admitted work instead of preserving its lease.")
        try await reject(.paused) { try await graceQueue.acquire(scope: scope, requestID: UUID()) }
        graceQueue.setForeground(true)
        graceQueue.expireBackgroundGrace()
        try require(graceQueue.entries[graceRunning]?.state == .running,
                    "Late expiration after foreground return paused the active response.")
        print("PASS: background grace preserves running work, rejects new admission, and ignores late expiration")

        graceQueue.setForeground(false, preservingRunningRequests: true)
        graceQueue.expireBackgroundGrace()
        graceQueue.expireBackgroundGrace()
        try require(!graceQueue.allowsRunningWork && graceQueue.activeRequestCount == 0 &&
                    graceQueue.entries[graceRunning]?.state == .paused,
                    "Background expiration failed to pause work or was not idempotent.")
        graceQueue.setForeground(true)
        try require(graceQueue.activeRequestCount == 0,
                    "Queue bypassed identity verification by resuming an expired lease.")
        try await graceQueue.acquire(scope: scope, requestID: graceRunning)
        print("PASS: expired grace preserves same-turn admission for verified recovery without automatic queue restart")

        graceQueue.setForeground(false, preservingRunningRequests: true)
        graceQueue.activate(scope: otherAccount)
        try require(!graceQueue.hasBackgroundGrace && graceQueue.activeRequestCount == 0 &&
                    graceQueue.entries[graceRunning]?.state == .paused,
                    "Account change retained the old account's background lease.")
        graceQueue.setForeground(true)
        try await reject(.inactiveScope) { try await graceQueue.acquire(scope: scope, requestID: graceRunning) }
        print("PASS: account changes revoke background grace and cannot resurrect old-scope work")
        print("Session queue regression passed: 10 behavioral checks; no iOS build performed.")
    }
}
