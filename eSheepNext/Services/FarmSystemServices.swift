import BackgroundTasks
import Foundation
import Observation
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
}

enum FarmBackgroundRefresh {
    static let identifier = "com.sheepfarm.esheepnext.refresh"

    @MainActor
    static func register(collaboration: CloudCollaborationStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            schedule()
            let work = Task { @MainActor in
                await collaboration.synchronizeNow()
                refreshTask.setTaskCompleted(success: collaboration.lastErrorMessage == nil)
            }
            refreshTask.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The system can reject duplicate or quota-limited requests. Foreground sync remains available.
        }
    }
}
