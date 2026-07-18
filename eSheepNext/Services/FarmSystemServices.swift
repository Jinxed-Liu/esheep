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
