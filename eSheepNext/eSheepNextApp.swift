import ESMotion
import SwiftData
import SwiftUI

@main
struct eSheepNextApp: App {
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var cloudShareDelegate

    @State private var bootstrap = AppBootstrapController()
    @State private var session = AppSession()
    @State private var subscription = SubscriptionService()
    @State private var notifications = FarmNotificationService()
    @State private var preferences = AppPreferences()
    @State private var motionEngine = MotionEngine()

    var body: some Scene {
        WindowGroup {
            Group {
                if let modelContainer = bootstrap.modelContainer,
                   let collaboration = bootstrap.collaboration {
                    MotionHost(engine: motionEngine) {
                        RootView()
                            .environment(session)
                            .environment(collaboration)
                            .environment(subscription)
                            .environment(notifications)
                            .environment(preferences)
                            .environment(\.locale, preferences.language.locale)
                            .preferredColorScheme(preferences.appearance.preferredColorScheme)
                            .transaction {
                                if preferences.shouldReduceMotion {
                                    $0.animation = nil
                                }
                            }
                            .tint(AppTheme.brand)
                            .modelContainer(modelContainer)
                    }
                    .onChange(
                        of: preferences.reduceMotionEnabled,
                        initial: true
                    ) { _, reduceMotion in
                        motionEngine.updatePreferences(
                            reduceMotion: reduceMotion,
                            powerSaving: preferences.powerSavingEnabled
                        )
                    }
                    .onChange(
                        of: preferences.powerSavingEnabled,
                        initial: true
                    ) { _, powerSaving in
                        motionEngine.updatePreferences(
                            reduceMotion: preferences.reduceMotionEnabled,
                            powerSaving: powerSaving
                        )
                    }
                } else if let failure = bootstrap.failure {
                    LocalStoreRecoveryView(bootstrap: bootstrap, failure: failure)
                } else {
                    ProgressView("正在检查本地数据")
                }
            }
            .task { bootstrap.start() }
        }
    }
}
