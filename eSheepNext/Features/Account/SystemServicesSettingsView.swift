import SwiftUI
import UIKit
import UserNotifications

struct SystemServicesSettingsView: View {
    @Environment(FarmNotificationService.self) private var notifications
    @Environment(\.openURL) private var openURL

    let farm: FarmRecord

    var body: some View {
        List {
            Section("通知") {
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

            Section("系统集成") {
                LabeledContent("Spotlight", value: "按牧场隔离索引")
                LabeledContent("快捷指令", value: "羊只、圈舍、任务、称重、投喂")
                LabeledContent("后台刷新", value: "系统择机补偿同步")
                Text("后台执行时间由 iOS 决定；失败操作会保留在 Outbox，并在前台或下一次后台机会继续处理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("通知与系统能力")
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
