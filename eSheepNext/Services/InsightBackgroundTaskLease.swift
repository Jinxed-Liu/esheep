import UIKit

@MainActor
protocol InsightBackgroundTaskManaging {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

/// A finite system assertion for an already running assistant response. This
/// is not a background scheduling entitlement or a promise of unlimited work.
@MainActor
final class InsightBackgroundTaskLease: InsightBackgroundTaskManaging {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "Assistant response", expirationHandler: expiration)
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
