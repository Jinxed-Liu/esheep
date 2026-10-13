import Foundation
import SwiftUI

public struct MotionActivationPlan: Hashable, Sendable {
    public let contentDelay: Duration
    public let motionDelay: Duration

    public init(
        contentDelay: Duration,
        motionDelay: Duration
    ) {
        self.contentDelay = contentDelay
        self.motionDelay = motionDelay
    }

    public static let immediate = MotionActivationPlan(
        contentDelay: .zero,
        motionDelay: .zero
    )
}

public enum MotionActivationPhase: Sendable {
    case transitioning
    case content
    case live

    public var showsDeferredContent: Bool {
        self != .transitioning
    }

    public var playsContinuousMotion: Bool {
        self == .live
    }
}

public struct MotionActivationGate<Content: View>: View {
    private let plan: MotionActivationPlan
    private let content: (MotionActivationPhase) -> Content

    @State private var phase = MotionActivationPhase.transitioning

    public init(
        plan: MotionActivationPlan,
        @ViewBuilder content: @escaping (MotionActivationPhase) -> Content
    ) {
        self.plan = plan
        self.content = content
    }

    public var body: some View {
        content(phase)
            .task(id: plan) {
                phase = .transitioning
                do {
                    try await Task.sleep(for: plan.contentDelay)
                    guard !Task.isCancelled else { return }
                    phase = .content
                    try await Task.sleep(for: plan.motionDelay)
                    guard !Task.isCancelled else { return }
                    phase = .live
                } catch {
                    return
                }
            }
    }
}
