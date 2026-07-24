import SwiftUI
import UIKit
import UserNotifications

struct SystemServicesSettingsView: View {
    @Environment(FarmNotificationService.self) private var notifications
    @Environment(\.openURL) private var openURL

    let farm: FarmRecord

    var body: some View {
        List {
            Section {
                LabeledContent("系统权限", value: notificationStatusText)
                if notifications.authorizationStatus == .notDetermined {
                    Button("允许通知") {
                        Task { await notifications.requestAuthorization() }
                    }
                } else if notifications.authorizationStatus == .denied {
                    Button("打开系统设置") {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
                Text("通知正文不会显示耳号、疾病、成员或库存等敏感生产数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let message = notifications.lastErrorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refreshAuthorizationStatus() }
    }

    private var notificationStatusText: String {
        switch notifications.authorizationStatus {
        case .notDetermined: "尚未询问"
        case .denied: "已关闭"
        case .authorized: "已允许"
        case .provisional: "临时允许"
        case .ephemeral: "临时会话"
        @unknown default: "未知"
        }
    }
}
