import SwiftData
import SwiftUI

@main
struct eSheepNextApp: App {
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var cloudShareDelegate

    private let modelContainer: ModelContainer

    @State private var session = AppSession()
    @State private var collaboration: CloudCollaborationStore

    init() {
        do {
            modelContainer = try AppSchema.makeContainer()
        } catch {
            fatalError("无法初始化本地数据存储：\(error.localizedDescription)")
        }
        _collaboration = State(initialValue: CloudCollaborationStore(container: modelContainer))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(collaboration)
                .tint(AppTheme.brand)
        }
        .modelContainer(modelContainer)
    }
}
