import ESMotionCore
import SwiftUI

public struct MotionSurfaceButtonStyle: ButtonStyle {
    public let pressedScale: CGFloat

    public init(pressedScale: CGFloat = 0.985) {
        self.pressedScale = min(max(pressedScale, 0.9), 1)
    }

    public func makeBody(configuration: Configuration) -> some View {
        MotionSurfaceButton(
            configuration: configuration,
            pressedScale: pressedScale
        )
    }
}

private struct MotionSurfaceButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let configuration: ButtonStyle.Configuration
    let pressedScale: CGFloat

    var body: some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !reduceMotion
                    ? pressedScale
                    : 1
            )
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(
                .spring(
                    duration: MotionSpring.press.response,
                    bounce: max(0, 1 - MotionSpring.press.dampingRatio)
                ),
                value: configuration.isPressed
            )
    }
}
