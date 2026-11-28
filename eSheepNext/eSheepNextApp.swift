import ESMotion
import SwiftData
import SwiftUI

@main
struct eSheepNextApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrap = AppBootstrapController()
    @State private var session = AppSession()
    @State private var subscription = SubscriptionService()
    @State private var notifications = FarmNotificationService()
    @State private var preferences = AppPreferences()
    @State private var motionEngine = MotionEngine()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--design-acceptance") {
                    DevelopmentDesignAcceptanceView()
                } else {
                    applicationContent
                }
                #else
                applicationContent
                #endif
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active, AppEnvironment.current == .production else { return }
                Task { _ = await ProductionBackendStatus.shared.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: ProductionBackend.changed)) { note in
                guard let raw = note.object as? String, let previous = ProductionBackend(rawValue: raw) else { return }
                if let old = AccountIdentityClients.client(for: previous)?.supabase {
                    Task { await old.auth.stopAutoRefresh(); await old.removeAllChannels() }
                }
                bootstrap.rebindBackend()
                session.requestAuthenticationRefresh()
            }
            .environment(\.locale, preferences.language.locale)
            .task {
                #if DEBUG
                guard !ProcessInfo.processInfo.arguments.contains("--design-acceptance") else { return }
                #endif
                ImageThumbnailMemoryPressureMonitor.start()
                let interval = PerformanceTrace.begin(.appLaunch)
                bootstrap.start()
                PerformanceTrace.end(interval)
            }
        }
    }

    @ViewBuilder
    private var applicationContent: some View {
                if let modelContainer = bootstrap.modelContainer,
                   let collaboration = bootstrap.collaboration {
                    MotionHost(engine: motionEngine) {
                        RootView()
                            .environment(session)
                            .environment(collaboration)
                            .environment(subscription)
                            .environment(notifications)
                            .environment(preferences)
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
}
