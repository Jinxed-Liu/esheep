import XCTest
@testable import eSheepNext

@MainActor
final class AppLifecycleCoordinatorTests: XCTestCase {
    func testRefreshRequestsAreCoalescedAcrossOneDebounceWindow() async throws {
        let coordinator = AppLifecycleCoordinator(
            refreshDebounceDuration: .milliseconds(20)
        )

        coordinator.requestRefresh([.systemSnapshot, .operationalAlerts])
        coordinator.requestRefresh(.systemSnapshot)
        coordinator.requestRefresh(.operationalAlerts)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coordinator.systemSnapshotRevision, 1)
        XCTAssertEqual(coordinator.operationalAlertRevision, 1)
    }

    func testSameContextUsesOneSingleFlightTask() async throws {
        let coordinator = AppLifecycleCoordinator()
        let probe = LifecycleConcurrencyProbe()

        let first = Task { @MainActor in
            await coordinator.performSingleFlight(
                kind: .foregroundCloudSync,
                context: "farm-a|generation-1"
            ) { _ in
                await probe.begin()
                try? await Task.sleep(for: .milliseconds(80))
                await probe.end()
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task { @MainActor in
            await coordinator.performSingleFlight(
                kind: .foregroundCloudSync,
                context: "farm-a|generation-1"
            ) { _ in
                XCTFail("Duplicate context must join the existing flight")
            }
        }

        await first.value
        await second.value
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.maximumConcurrentCount, 1)
    }

    func testNewContextCancelsOldTaskAndInvalidatesItsLease() async throws {
        let coordinator = AppLifecycleCoordinator()
        let probe = LifecycleCancellationProbe()

        let oldTask = Task { @MainActor in
            await coordinator.performSingleFlight(
                kind: .systemSnapshot,
                context: "farm-a|generation-1"
            ) { lease in
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    await probe.recordOldCancellation()
                }
                if coordinator.isCurrent(lease) {
                    await probe.recordCompletion("old")
                }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let newTask = Task { @MainActor in
            await coordinator.performSingleFlight(
                kind: .systemSnapshot,
                context: "farm-b|generation-2"
            ) { lease in
                if coordinator.isCurrent(lease) {
                    await probe.recordCompletion("new")
                }
            }
        }

        await oldTask.value
        await newTask.value
        let snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.oldTaskWasCancelled)
        XCTAssertEqual(snapshot.completions, ["new"])
    }

    func testCancelAllStopsManagedTasksAndPendingRefresh() async throws {
        let coordinator = AppLifecycleCoordinator(
            refreshDebounceDuration: .milliseconds(50)
        )
        let probe = LifecycleCancellationProbe()
        coordinator.requestRefresh([.systemSnapshot, .operationalAlerts])

        let task = Task { @MainActor in
            await coordinator.performSingleFlight(
                kind: .accountAvatarSync,
                context: "account-a"
            ) { _ in
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    await probe.recordOldCancellation()
                }
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        coordinator.cancelAll()
        await task.value
        try await Task.sleep(for: .milliseconds(80))

        let snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.oldTaskWasCancelled)
        XCTAssertEqual(coordinator.systemSnapshotRevision, 0)
        XCTAssertEqual(coordinator.operationalAlertRevision, 0)
    }
}

private actor LifecycleConcurrencyProbe {
    private var currentCount = 0
    private var maximumConcurrentCount = 0
    private var startCount = 0

    func begin() {
        currentCount += 1
        startCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, currentCount)
    }

    func end() {
        currentCount -= 1
    }

    func snapshot() -> (startCount: Int, maximumConcurrentCount: Int) {
        (startCount, maximumConcurrentCount)
    }
}

private actor LifecycleCancellationProbe {
    private var oldTaskWasCancelled = false
    private var completions: [String] = []

    func recordOldCancellation() {
        oldTaskWasCancelled = true
    }

    func recordCompletion(_ value: String) {
        completions.append(value)
    }

    func snapshot() -> (oldTaskWasCancelled: Bool, completions: [String]) {
        (oldTaskWasCancelled, completions)
    }
}
