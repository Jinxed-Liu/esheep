import SwiftData
import SwiftUI

@main
struct eSheepNextApp: App {
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var cloudShareDelegate

    private let modelContainer: ModelContainer

    @State private var session = AppSession()
    @State private var collaboration: CloudCollaborationStore
    @State private var subscription = SubscriptionService()
    @State private var notifications = FarmNotificationService()

    init() {
        do {
            modelContainer = try AppSchema.makeContainer()
        } catch {
            fatalError("无法初始化本地数据存储：\(error.localizedDescription)")
        }
        let collaboration = CloudCollaborationStore(container: modelContainer)
        _collaboration = State(initialValue: collaboration)
        FarmBackgroundRefresh.register(collaboration: collaboration)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(collaboration)
                .environment(subscription)
                .environment(notifications)
                .tint(AppTheme.brand)
        }
        .modelContainer(modelContainer)
    }
}
