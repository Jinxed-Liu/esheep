import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UserNotifications

struct FarmNotificationRoute: Codable, Equatable, Sendable {
    let farmID: UUID
    let kind: FarmSystemNavigationKind
    let entityID: UUID?

    var userInfo: [AnyHashable: Any] {
        [
            "farmID": farmID.uuidString.lowercased(),
            "kind": kind.rawValue,
            "entityID": entityID?.uuidString.lowercased() ?? "",
        ]
    }

    init(farmID: UUID, kind: FarmSystemNavigationKind, entityID: UUID? = nil) {
        self.farmID = farmID
        self.kind = kind
        self.entityID = entityID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let farmText = userInfo["farmID"] as? String,
              let farmID = UUID(uuidString: farmText),
              let kindText = userInfo["kind"] as? String,
              let kind = FarmSystemNavigationKind(rawValue: kindText) else { return nil }
        self.farmID = farmID
        self.kind = kind
        self.entityID = (userInfo["entityID"] as? String).flatMap(UUID.init(uuidString:))
    }
}

@MainActor
@Observable
final class FarmNotificationService {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var lastErrorMessage: String?

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        await refreshAuthorizationStatus()
    }

    func schedulePrivacyFriendlyReminder(farmID: UUID, after interval: TimeInterval = 60) async {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "eSheep+ 提醒"
        content.body = "打开应用查看牧场待处理事项。"
        content.sound = .default
        content.userInfo = FarmNotificationRoute(farmID: farmID, kind: .home).userInfo
        let request = UNNotificationRequest(
            identifier: "farm:\(farmID.uuidString.lowercased()):pending",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func rescheduleCareReminders(_ reminders: [CareReminderRecord], farmID: UUID, now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        authorizationStatus = await center.notificationSettings().authorizationStatus
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        let prefix = "care:\(farmID.uuidString.lowercased()):"
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        let upcoming = reminders.filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.status == .pending && $0.dueAt > now
        }.sorted { $0.dueAt < $1.dueAt }.prefix(60)
        for reminder in upcoming {
            let content = UNMutableNotificationContent()
            content.title = reminder.kind.displayName
            content.body = reminder.title
            content.sound = .default
            content.userInfo = FarmNotificationRoute(farmID: farmID, kind: .openCareReminder, entityID: reminder.id).userInfo
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.dueAt)
            let request = UNNotificationRequest(identifier: prefix + reminder.id.uuidString.lowercased(), content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try? await center.add(request)
        }
    }

    func rescheduleOperationalAlertDigest(
        _ snapshot: FarmOperationalAlertSnapshot,
        now: Date = .now
    ) async {
        let center = UNUserNotificationCenter.current()
        authorizationStatus = await center.notificationSettings().authorizationStatus
        let identifier = FarmOperationalAlertDigestPlan.identifier(farmID: snapshot.farmID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard snapshot.isConfigured,
              snapshot.rule?.digestEnabled == true,
              snapshot.totalPendingCount > 0,
              authorizationStatus == .authorized ||
                authorizationStatus == .provisional ||
                authorizationStatus == .ephemeral,
              let rule = snapshot.rule,
              let deliveryDate = FarmOperationalAlertDigestPlan.nextDeliveryDate(
                now: now,
                timeZoneIdentifier: snapshot.timeZoneIdentifier,
                minuteOfDay: rule.digestMinuteOfDay
              ) else { return }

        let content = UNMutableNotificationContent()
        content.title = "eSheepNext 待办提醒"
        content.body = FarmOperationalAlertDigestPlan.body(count: snapshot.totalPendingCount)
        content.sound = .default
        content.userInfo = FarmNotificationRoute(
            farmID: snapshot.farmID,
            kind: .openOperationalAlerts
        ).userInfo

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: deliveryDate
        )
        components.timeZone = calendar.timeZone
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        do {
            try await center.add(request)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}

enum FarmOperationalAlertDigestPlan {
    static func identifier(farmID: UUID) -> String {
        "operational-alert:\(farmID.uuidString.lowercased())"
    }

    static func body(count: Int) -> String {
        "有 \(max(0, count)) 项待处理事项，打开应用查看详情。"
    }

    static func nextDeliveryDate(
        now: Date,
        timeZoneIdentifier: String,
        minuteOfDay: Int
    ) -> Date? {
        guard (0...1_439).contains(minuteOfDay),
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = minuteOfDay / 60
        let minute = minuteOfDay % 60
        guard let today = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: now
        ) else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }
}

enum FarmBackgroundRefresh {
    static let identifier = "com.sheepfarm.esheepnext.refresh"

    @MainActor
    static func register(collaboration: CloudCollaborationStore, modelContainer: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            guard AppPreferenceStorage.isBackgroundRefreshEnabled else {
                refreshTask.setTaskCompleted(success: true)
                return
            }
            schedule()
            let work = Task { @MainActor in
                await collaboration.synchronizeNow()
                var alertsScheduled = true
                do {
                    let actor = FarmOperationalAlertSnapshotActor(container: modelContainer)
                    let farmIDs = try await actor.availableFarmIDs()
                    let notifications = FarmNotificationService()
                    for farmID in farmIDs {
                        try Task.checkCancellation()
                        let snapshot = try await actor.load(farmID: farmID)
                        await notifications.rescheduleOperationalAlertDigest(snapshot)
                    }
                } catch is CancellationError {
                    alertsScheduled = false
                } catch {
                    alertsScheduled = false
                }
                refreshTask.setTaskCompleted(
                    success: collaboration.lastErrorMessage == nil && alertsScheduled
                )
            }
            refreshTask.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        guard AppPreferenceStorage.isBackgroundRefreshEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The system can reject duplicate or quota-limited requests. Foreground sync remains available.
        }
    }
}
