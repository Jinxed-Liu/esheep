import Foundation

enum CloudRuntimeNotification {
    static let syncWake = Notification.Name("eSheepNext.cloudSyncWake")
    private static let farmIDKey = "farmID"

    static func postSyncWake(farmID: UUID) {
        NotificationCenter.default.post(
            name: syncWake,
            object: nil,
            userInfo: [farmIDKey: farmID]
        )
    }

    static func farmID(from notification: Notification) -> UUID? {
        notification.userInfo?[farmIDKey] as? UUID
    }
}
