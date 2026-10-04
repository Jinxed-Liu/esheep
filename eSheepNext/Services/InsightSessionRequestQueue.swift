import Foundation
import Observation

struct InsightSessionScope: Hashable, Sendable {
    let accountID: UUID
    let farmID: UUID
}

enum InsightSessionRunState: String, Sendable, Equatable {
    case queued, running, paused, cancelled, completed
}

enum InsightSessionQueueError: LocalizedError {
    case inactiveScope, paused, duplicateRequest, conversationBusy

    var errorDescription: String? {
        switch self {
        case .inactiveScope: "当前账号或牧场已切换，该任务未启动。"
        case .paused: "App 已离开前台，任务已暂停。"
        case .duplicateRequest: "该请求已登记，不能重复启动。"
        case .conversationBusy: "请先停止当前会话的回复，再发送下一条消息。"
        }
    }
}

/// Admission is independent of view lifetime. Only admitted computation uses a
/// slot; callers release before waiting for user confirmation or cloud receipts.
@MainActor
@Observable
final class InsightSessionRequestQueue {
    struct Entry: Equatable {
        let requestID: UUID
        let scope: InsightSessionScope
        let conversationID: UUID?
        let sequence: Int
        var state: InsightSessionRunState
    }

    private(set) var entries: [UUID: Entry] = [:]
    private(set) var activeScope: InsightSessionScope?
    private(set) var isForeground = true
    private(set) var hasBackgroundGrace = false
    let maximumConcurrentRequests: Int
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var waiting: [UUID] = []
    @ObservationIgnored private var nextSequence = 0

    init(maximumConcurrentRequests: Int = 2) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    var activeRequestCount: Int { entries.values.count { $0.state == .running } }
    var queuedRequestCount: Int { waiting.count }
    var allowsRunningWork: Bool { isForeground || hasBackgroundGrace }

    func acquire(scope: InsightSessionScope, requestID: UUID, conversationID: UUID? = nil) async throws {
        try Task.checkCancellation()
        guard isForeground else { throw InsightSessionQueueError.paused }
        guard activeScope == scope else { throw InsightSessionQueueError.inactiveScope }
        if let previous = entries[requestID] {
            if previous.state == .queued || previous.state == .running { throw InsightSessionQueueError.duplicateRequest }
            if previous.state == .cancelled { throw CancellationError() }
            guard previous.scope == scope, previous.conversationID == conversationID else {
                throw InsightSessionQueueError.duplicateRequest
            }
            // The same durable turn reacquires after a confirmation wait or
            // explicit resume. It joins the tail, without bypassing the cap.
        }
        if let conversationID, entries.values.contains(where: {
            $0.scope == scope && $0.conversationID == conversationID &&
                ($0.state == .running || $0.state == .queued)
        }) { throw InsightSessionQueueError.conversationBusy }
        nextSequence += 1
        entries[requestID] = Entry(requestID: requestID, scope: scope,
            conversationID: conversationID, sequence: nextSequence, state: .queued)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                continuations[requestID] = continuation
                waiting.append(requestID)
                admitWaitingRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestID: requestID) }
        }
        try Task.checkCancellation()
    }

    func release(requestID: UUID) {
        guard entries[requestID]?.state == .running else { return }
        entries[requestID]?.state = .completed
        admitWaitingRequests()
    }

    func cancel(requestID: UUID) {
        guard let entry = entries[requestID], entry.state == .queued || entry.state == .running else { return }
        entries[requestID]?.state = .cancelled
        waiting.removeAll { $0 == requestID }
        continuations.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
        admitWaitingRequests()
    }

    func activate(scope: InsightSessionScope?) {
        guard activeScope != scope else { return }
        hasBackgroundGrace = false
        activeScope = scope
        pauseRequests { $0.scope != scope }
        admitWaitingRequests()
    }

    func setForeground(_ foreground: Bool, preservingRunningRequests: Bool = false) {
        isForeground = foreground
        hasBackgroundGrace = !foreground && preservingRunningRequests
        if !foreground {
            pauseRequests { !preservingRunningRequests || $0.state == .queued }
        } else {
            admitWaitingRequests()
        }
        // Foregrounding never silently restarts paused work.
    }

    func expireBackgroundGrace() {
        guard !isForeground, hasBackgroundGrace else { return }
        hasBackgroundGrace = false
        pauseRequests { _ in true }
    }

    func pauseAll() {
        hasBackgroundGrace = false
        pauseRequests { _ in true }
    }

    func state(scope: InsightSessionScope, conversationID: UUID) -> InsightSessionRunState? {
        entries.values.filter { $0.scope == scope && $0.conversationID == conversationID }
            .max { $0.sequence < $1.sequence }?.state
    }

    private func pauseRequests(where predicate: (Entry) -> Bool) {
        let ids = entries.values.filter {
            ($0.state == .queued || $0.state == .running) && predicate($0)
        }.map(\.requestID)
        for id in ids {
            entries[id]?.state = .paused
            waiting.removeAll { $0 == id }
            continuations.removeValue(forKey: id)?.resume(throwing: InsightSessionQueueError.paused)
        }
    }

    private func admitWaitingRequests() {
        guard isForeground else { return }
        while activeRequestCount < maximumConcurrentRequests, let id = waiting.first {
            waiting.removeFirst()
            guard entries[id]?.state == .queued, entries[id]?.scope == activeScope else {
                continuations.removeValue(forKey: id)?.resume(throwing: InsightSessionQueueError.inactiveScope)
                continue
            }
            entries[id]?.state = .running
            continuations.removeValue(forKey: id)?.resume()
        }
    }
}
