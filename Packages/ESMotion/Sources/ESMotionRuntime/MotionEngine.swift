// Modified for eSheep: deinitialization without the iOS 18.4 runtime. See README.md.
import ESMotionCore
import Foundation
import Observation
import SwiftUI

// Only MainActor appends tokens. Deinit cannot overlap an append because that call
// retains this owner, and NotificationCenter supports removal from any thread.
private final class MotionNotificationObservers: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    @MainActor
    func append(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

public struct MotionEnvironmentState: Equatable, Sendable {
    public var isSceneActive: Bool
    public var systemReduceMotion: Bool
    public var userReduceMotion: Bool
    public var systemLowPowerMode: Bool
    public var userPowerSaving: Bool
    public var thermalPressure: MotionThermalPressure

    public init(
        isSceneActive: Bool = true,
        systemReduceMotion: Bool = false,
        userReduceMotion: Bool = false,
        systemLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        userPowerSaving: Bool = false,
        thermalPressure: MotionThermalPressure = MotionThermalPressure(
            ProcessInfo.processInfo.thermalState
        )
    ) {
        self.isSceneActive = isSceneActive
        self.systemReduceMotion = systemReduceMotion
        self.userReduceMotion = userReduceMotion
        self.systemLowPowerMode = systemLowPowerMode
        self.userPowerSaving = userPowerSaving
        self.thermalPressure = thermalPressure
    }

    public var prefersReducedMotion: Bool {
        systemReduceMotion || userReduceMotion
    }

    public var prefersPowerSaving: Bool {
        systemLowPowerMode || userPowerSaving
    }
}

@MainActor
@Observable
public final class MotionEngine {
    public private(set) var environment: MotionEnvironmentState

    @ObservationIgnored public let displayCoordinator: MotionDisplayCoordinator
    @ObservationIgnored public let metricsStore: MotionMetricsStore
    @ObservationIgnored private let notificationObservers = MotionNotificationObservers()

    public init(
        environment: MotionEnvironmentState = MotionEnvironmentState(),
        metricsStore: MotionMetricsStore = MotionMetricsStore()
    ) {
        self.environment = environment
        self.metricsStore = metricsStore
        displayCoordinator = MotionDisplayCoordinator(metricsStore: metricsStore)
        observeSystemPolicy()
        applyCurrentPolicy()
    }

    public func updateSceneActive(_ isActive: Bool) {
        guard environment.isSceneActive != isActive else { return }
        environment.isSceneActive = isActive
        applyCurrentPolicy()
    }

    public func updateSystemReduceMotion(_ isEnabled: Bool) {
        guard environment.systemReduceMotion != isEnabled else { return }
        environment.systemReduceMotion = isEnabled
        applyCurrentPolicy()
    }

    public func updatePreferences(
        reduceMotion: Bool,
        powerSaving: Bool
    ) {
        guard environment.userReduceMotion != reduceMotion
                || environment.userPowerSaving != powerSaving else {
            return
        }
        environment.userReduceMotion = reduceMotion
        environment.userPowerSaving = powerSaving
        applyCurrentPolicy()
    }

    public func decision(
        for budget: MotionBudget,
        externallySuspended: Bool = false
    ) -> MotionRuntimeDecision {
        MotionRuntimePolicy.resolve(
            budget: budget,
            inputs: MotionRuntimeInputs(
                isExternallySuspended: externallySuspended,
                isSceneActive: environment.isSceneActive,
                prefersReducedMotion: environment.prefersReducedMotion,
                prefersPowerSaving: environment.prefersPowerSaving,
                thermalPressure: environment.thermalPressure
            )
        )
    }

    public func activate(
        budget: MotionBudget,
        externallySuspended: Bool = false
    ) {
        displayCoordinator.apply(
            decision(
                for: budget,
                externallySuspended: externallySuspended
            ),
            timeWrap: budget.timeWrap
        )
    }

    private func observeSystemPolicy() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.environment.systemLowPowerMode =
                        ProcessInfo.processInfo.isLowPowerModeEnabled
                    self?.applyCurrentPolicy()
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.environment.thermalPressure = MotionThermalPressure(
                        ProcessInfo.processInfo.thermalState
                    )
                    self?.applyCurrentPolicy()
                }
            }
        )
    }

    private func applyCurrentPolicy() {
        displayCoordinator.updateRuntimeInputs(
            MotionRuntimeInputs(
                isSceneActive: environment.isSceneActive,
                prefersReducedMotion: environment.prefersReducedMotion,
                prefersPowerSaving: environment.prefersPowerSaving,
                thermalPressure: environment.thermalPressure
            )
        )
    }
}

@MainActor
public struct MotionHost<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var engine: MotionEngine
    private let content: Content

    public init(
        engine: MotionEngine? = nil,
        @ViewBuilder content: () -> Content
    ) {
        _engine = State(initialValue: engine ?? MotionEngine())
        self.content = content()
    }

    public var body: some View {
        content
            .environment(engine)
            .onChange(of: scenePhase, initial: true) { _, phase in
                engine.updateSceneActive(phase == .active)
            }
            .onChange(of: systemReduceMotion, initial: true) { _, enabled in
                engine.updateSystemReduceMotion(enabled)
            }
    }
}

public extension View {
    @MainActor
    func motionEngine(_ engine: MotionEngine) -> some View {
        environment(engine)
    }
}
