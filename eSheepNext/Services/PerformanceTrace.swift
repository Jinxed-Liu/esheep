import Foundation
import OSLog

enum PerformanceTraceOperation: String, Sendable {
    case appLaunch = "app-launch"
    case authentication = "authentication"
    case rootWorkspace = "root-workspace"
    case farmSwitch = "farm-switch"
    case systemSnapshot = "system-snapshot"
    case operationalAlerts = "operational-alerts"
    case herdSearch = "herd-search"
    case careLoad = "care-load"
    case tmrLoad = "tmr-load"
    case historyLoad = "history-load"
    case syncPull = "sync-pull"
    case syncPush = "sync-push"
    case syncRebuild = "sync-rebuild"
    case imageDecode = "image-decode"
}

/// Lightweight, privacy-safe intervals for local Instruments and explicitly
/// enabled internal builds. Never put account, farm, sheep, or ear-tag values
/// in these signposts.
enum PerformanceTrace {
    struct Interval: @unchecked Sendable {
        fileprivate let state: OSSignpostIntervalState?
    }

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sheepfarm.next",
        category: "Performance"
    )

    private static var isEnabled: Bool {
        _isDebugAssertConfiguration() ||
            ProcessInfo.processInfo.arguments.contains("-EnablePerformanceTrace")
    }

    static func begin(
        _ operation: PerformanceTraceOperation,
        count: Int? = nil
    ) -> Interval {
        guard isEnabled else { return Interval(state: nil) }
        let id = signposter.makeSignpostID()
        let state: OSSignpostIntervalState
        if let count {
            state = signposter.beginInterval(
                "Operation",
                id: id,
                "name=\(operation.rawValue, privacy: .public) count=\(count)"
            )
        } else {
            state = signposter.beginInterval(
                "Operation",
                id: id,
                "name=\(operation.rawValue, privacy: .public)"
            )
        }
        return Interval(state: state)
    }

    static func end(_ interval: Interval) {
        guard let state = interval.state else { return }
        signposter.endInterval("Operation", state)
    }

    static func event(
        _ operation: PerformanceTraceOperation,
        count: Int? = nil
    ) {
        guard isEnabled else { return }
        if let count {
            signposter.emitEvent(
                "Event",
                "name=\(operation.rawValue, privacy: .public) count=\(count)"
            )
        } else {
            signposter.emitEvent(
                "Event",
                "name=\(operation.rawValue, privacy: .public)"
            )
        }
    }
}
