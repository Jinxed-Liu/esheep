import Foundation
import Observation

@MainActor
@Observable
final class AppLifecycleCoordinator {
    enum TaskKind: Hashable, Sendable {
        case authentication
        case foregroundCloudSync
        case sharedFarmAdmission
        case accountAvatarSync
        case insightPersonalSync
        case migrationRecovery
        case identityMaintenance
        case systemSnapshot
        case operationalAlerts
    }

    enum RefreshTarget: Hashable, Sendable {
        case systemSnapshot
        case operationalAlerts
    }

    struct Lease: Hashable, Sendable {
        fileprivate let token: UUID
        let kind: TaskKind
        let context: String
    }

    @ObservationIgnored private let refreshDebounceDuration: Duration
    @ObservationIgnored private var managedTasks: [TaskKind: ManagedTask] = [:]
    @ObservationIgnored private var refreshDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshTargets = Set<RefreshTarget>()

    private(set) var systemSnapshotRevision = 0
    private(set) var operationalAlertRevision = 0

    init(refreshDebounceDuration: Duration = .milliseconds(150)) {
        self.refreshDebounceDuration = refreshDebounceDuration
    }

    deinit {
        refreshDebounceTask?.cancel()
        for task in managedTasks.values {
            task.task.cancel()
        }
    }

    func performSingleFlight(
        kind: TaskKind,
        context: String,
        operation: @escaping @MainActor @Sendable (Lease) async -> Void
    ) async {
        if let existing = managedTasks[kind],
           existing.lease.context == context,
           !existing.task.isCancelled {
            await existing.task.value
            return
        }

        managedTasks[kind]?.task.cancel()
        let lease = Lease(token: UUID(), kind: kind, context: context)
        let task = Task { @MainActor in
            await operation(lease)
        }
        managedTasks[kind] = ManagedTask(lease: lease, task: task)

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        if managedTasks[kind]?.lease == lease {
            managedTasks[kind] = nil
        }
    }

    func isCurrent(_ lease: Lease) -> Bool {
        managedTasks[lease.kind]?.lease == lease && !Task.isCancelled
    }

    func cancel(_ kind: TaskKind) {
        managedTasks.removeValue(forKey: kind)?.task.cancel()
    }

    func cancelAll() {
        let tasks = managedTasks.values.map(\.task)
        managedTasks.removeAll(keepingCapacity: true)
        for task in tasks {
            task.cancel()
        }
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        pendingRefreshTargets.removeAll(keepingCapacity: true)
    }

    func requestRefresh(_ targets: Set<RefreshTarget>) {
        guard !targets.isEmpty else { return }
        pendingRefreshTargets.formUnion(targets)
        refreshDebounceTask?.cancel()
        let delay = refreshDebounceDuration
        refreshDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.flushPendingRefreshes()
        }
    }

    func requestRefresh(_ target: RefreshTarget) {
        requestRefresh([target])
    }

    private func flushPendingRefreshes() {
        let targets = pendingRefreshTargets
        pendingRefreshTargets.removeAll(keepingCapacity: true)
        refreshDebounceTask = nil
        if targets.contains(.systemSnapshot) {
            systemSnapshotRevision &+= 1
        }
        if targets.contains(.operationalAlerts) {
            operationalAlertRevision &+= 1
        }
    }

    private struct ManagedTask {
        let lease: Lease
        let task: Task<Void, Never>
    }
}
