import SwiftUI

public struct MotionRenderSurface<Content: View>: View {
    private let renderScale: Double
    private let content: (CGSize) -> Content

    public init(
        renderScale: Double,
        @ViewBuilder content: @escaping (CGSize) -> Content
    ) {
        self.renderScale = min(max(renderScale, 0.35), 1)
        self.content = content
    }

    public var body: some View {
        GeometryReader { geometry in
            let scale = CGFloat(renderScale)
            let renderSize = CGSize(
                width: geometry.size.width * scale,
                height: geometry.size.height * scale
            )

            content(renderSize)
                .frame(
                    width: renderSize.width,
                    height: renderSize.height
                )
                .scaleEffect(1 / scale, anchor: .topLeading)
        }
        .clipped()
    }
}

public enum MotionAnimations {
    public static let contentChange = Animation.smooth(duration: 0.42)
    public static let ambientChange = Animation.smooth(duration: 0.70)
}
