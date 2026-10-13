// Modified for eSheep: preserve system navigation on iOS 17. See README.md.
import ESMotionCore
import SwiftUI

public struct MotionTransitionID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init<Value: CustomStringConvertible & Hashable & Sendable>(
        _ value: Value
    ) {
        rawValue = value.description
    }
}

public enum MotionTransitionPreset: String, Codable, Sendable {
    case card
    case avatar
    case listItem
    case sheet
    case numeric
}

public struct MotionTransitionSpec: Equatable, Sendable {
    public let preset: MotionTransitionPreset
    public let cornerRadius: CGFloat
    public let spring: MotionSpring
    public let reducedMotionDuration: TimeInterval
    public let progressThreshold: Double
    public let velocityThreshold: Double

    public init(
        preset: MotionTransitionPreset,
        cornerRadius: CGFloat,
        spring: MotionSpring = .transition,
        reducedMotionDuration: TimeInterval = 0.18,
        progressThreshold: Double = 0.35,
        velocityThreshold: Double = 900
    ) {
        self.preset = preset
        self.cornerRadius = max(cornerRadius, 0)
        self.spring = spring
        self.reducedMotionDuration = max(reducedMotionDuration, 0)
        self.progressThreshold = min(max(progressThreshold, 0), 1)
        self.velocityThreshold = max(velocityThreshold, 0)
    }

    public static let card = MotionTransitionSpec(
        preset: .card,
        cornerRadius: 24
    )
    public static let avatar = MotionTransitionSpec(
        preset: .avatar,
        cornerRadius: 999
    )
    public static let listItem = MotionTransitionSpec(
        preset: .listItem,
        cornerRadius: 16
    )
    public static let sheet = MotionTransitionSpec(
        preset: .sheet,
        cornerRadius: 28
    )
    public static let numeric = MotionTransitionSpec(
        preset: .numeric,
        cornerRadius: 0
    )
}

@MainActor
public struct MotionTransitionHost<Content: View>: View {
    @Namespace private var namespace
    private let content: (Namespace.ID) -> Content

    public init(
        @ViewBuilder content: @escaping (Namespace.ID) -> Content
    ) {
        self.content = content
    }

    public var body: some View {
        content(namespace)
    }
}

public extension View {
    @ViewBuilder
    func motionTransitionSource(
        id: MotionTransitionID,
        in namespace: Namespace.ID,
        spec: MotionTransitionSpec = .card,
        background: Color = .clear
    ) -> some View {
        if #available(iOS 18, macOS 15, *) {
            matchedTransitionSource(id: id, in: namespace) { source in
                source
                    .background(background)
                    .clipShape(.rect(cornerRadius: spec.cornerRadius))
            }
        } else {
            self
        }
    }

    func motionTransitionDestination(
        id: MotionTransitionID,
        in namespace: Namespace.ID,
        spec: MotionTransitionSpec = .card
    ) -> some View {
        modifier(
            MotionTransitionDestinationModifier(
                id: id,
                namespace: namespace,
                spec: spec
            )
        )
    }

    func motionInteractiveDismiss(
        spec: MotionTransitionSpec = .card,
        edgeWidth: CGFloat = 32,
        onDismiss: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(
            MotionInteractiveDismissModifier(
                spec: spec,
                edgeWidth: edgeWidth,
                onDismiss: onDismiss
            )
        )
    }
}

private struct MotionTransitionDestinationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let id: MotionTransitionID
    let namespace: Namespace.ID
    let spec: MotionTransitionSpec

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if reduceMotion {
            content
                .transition(.opacity)
                .animation(
                    .easeOut(duration: spec.reducedMotionDuration),
                    value: reduceMotion
                )
        } else if #available(iOS 18, *) {
            content.navigationTransition(
                .zoom(sourceID: id, in: namespace)
            )
        } else {
            // NavigationStack supplies its standard push/pop animation on iOS 17.
            content
        }
        #else
        content
            .transition(.opacity)
            .animation(
                .easeOut(duration: spec.reducedMotionDuration),
                value: reduceMotion
            )
        #endif
    }
}

private struct MotionInteractiveDismissModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let spec: MotionTransitionSpec
    let edgeWidth: CGFloat
    let onDismiss: @MainActor () -> Void

    @State private var translation: CGFloat = 0
    @State private var gestureStartedAtEdge = false

    func body(content: Content) -> some View {
        content
            .offset(x: reduceMotion ? 0 : max(translation, 0))
            .scaleEffect(
                reduceMotion
                    ? 1
                    : 1 - min(max(translation / 1_800, 0), 0.035)
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if !gestureStartedAtEdge {
                            gestureStartedAtEdge =
                                value.startLocation.x <= edgeWidth
                        }
                        guard gestureStartedAtEdge else { return }
                        translation = max(value.translation.width, 0)
                    }
                    .onEnded { value in
                        defer { gestureStartedAtEdge = false }
                        guard gestureStartedAtEdge else { return }

                        let width = max(value.startLocation.x + 1, 1)
                        var progress = MotionInteractiveProgress(
                            progress: min(translation / max(width * 4, 1), 1)
                        )
                        let projected = min(
                            max(value.predictedEndTranslation.width / 320, 0),
                            1
                        )
                        let velocity = max(
                            value.predictedEndTranslation.width
                                - value.translation.width,
                            0
                        ) * 60
                        let completes = progress.finish(
                            projectedProgress: projected,
                            velocity: velocity,
                            progressThreshold: spec.progressThreshold,
                            velocityThreshold: spec.velocityThreshold
                        )

                        if completes {
                            onDismiss()
                            translation = 0
                        } else {
                            withAnimation(
                                .spring(
                                    duration: spec.spring.response,
                                    bounce: max(0, 1 - spec.spring.dampingRatio)
                                )
                            ) {
                                translation = 0
                            }
                        }
                    }
            )
    }
}
