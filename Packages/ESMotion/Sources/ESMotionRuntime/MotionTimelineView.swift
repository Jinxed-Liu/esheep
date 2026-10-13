import ESMotionCore
import SwiftUI

@MainActor
public struct MotionTimelineView<Scene: MotionSceneDescriptor, Content: View>: View {
    @Environment(MotionEngine.self) private var engine

    private let scene: Scene
    private let isSuspended: Bool
    private let content: (MotionFrame) -> Content

    @State private var callbackID: UUID?
    @State private var frame: MotionFrame?

    public init(
        scene: Scene,
        isSuspended: Bool = false,
        @ViewBuilder content: @escaping (MotionFrame) -> Content
    ) {
        self.scene = scene
        self.isSuspended = isSuspended
        self.content = content
        let timestamp = ProcessInfo.processInfo.systemUptime
        _frame = State(
            initialValue: MotionFrame(
                timestamp: timestamp,
                targetTimestamp: timestamp,
                deltaTime: 0,
                wrappedTime: MotionClock.wrappedTime(
                    for: Date(),
                    wrap: scene.budget.timeWrap
                ),
                renderScale: scene.budget.baseRenderScale,
                quality: .full
            )
        )
    }

    public var body: some View {
        Group {
            if let frame {
                content(frame)
            } else {
                Color.clear
            }
        }
        .onAppear {
            register()
        }
        .onChange(of: scene) { _, _ in
            register()
        }
        .onChange(of: isSuspended) { _, _ in
            updateRegistration()
        }
        .onDisappear {
            unregister()
        }
    }

    private func register() {
        unregister()
        callbackID = engine.displayCoordinator.register(
            budget: scene.budget,
            isSuspended: isSuspended
        ) { newFrame in
            frame = newFrame
        }
    }

    private func updateRegistration() {
        guard let callbackID else { return }
        engine.displayCoordinator.updateRegistration(
            callbackID,
            budget: scene.budget,
            isSuspended: isSuspended
        )
    }

    private func unregister() {
        guard let callbackID else { return }
        engine.displayCoordinator.unregister(callbackID)
        self.callbackID = nil
    }
}
