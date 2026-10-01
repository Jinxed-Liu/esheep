import SwiftUI
import UIKit

/// An original, fixed-topology path; no Telegram artwork or mask data is used.
/// The caller owns the avatar's position and size in the current window.
struct AvatarIslandMask: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { boundedAvatarIslandProgress(progress) }
        set { progress = boundedAvatarIslandProgress(newValue) }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let progress = boundedAvatarIslandProgress(progress)
        let morph = progress * progress * (3 - 2 * progress)
        let diameter = min(rect.width, rect.height)
        let width = diameter + (rect.width - diameter) * morph
        let height = diameter * (1 - 0.66 * morph)
        let initialTop = rect.midY - diameter / 2
        let top = initialTop + (rect.minY - initialTop) * morph
        let bounds = CGRect(
            x: rect.midX - width / 2,
            y: top,
            width: width,
            height: height
        )
        let radius = min(bounds.width, bounds.height) / 2
        let control = radius * 0.5522847498307936
        let left = bounds.minX
        let right = bounds.maxX
        let bottom = bounds.maxY

        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: top))

        // Always emit eight cubic segments, including zero-length sides at p=0.
        // This preserves the correspondence of every control point when reversed.
        addStraightCurve(
            to: &path,
            from: CGPoint(x: left + radius, y: top),
            to: CGPoint(x: right - radius, y: top)
        )
        path.addCurve(
            to: CGPoint(x: right, y: top + radius),
            control1: CGPoint(x: right - radius + control, y: top),
            control2: CGPoint(x: right, y: top + radius - control)
        )
        addStraightCurve(
            to: &path,
            from: CGPoint(x: right, y: top + radius),
            to: CGPoint(x: right, y: bottom - radius)
        )
        path.addCurve(
            to: CGPoint(x: right - radius, y: bottom),
            control1: CGPoint(x: right, y: bottom - radius + control),
            control2: CGPoint(x: right - radius + control, y: bottom)
        )
        addStraightCurve(
            to: &path,
            from: CGPoint(x: right - radius, y: bottom),
            to: CGPoint(x: left + radius, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: left, y: bottom - radius),
            control1: CGPoint(x: left + radius - control, y: bottom),
            control2: CGPoint(x: left, y: bottom - radius + control)
        )
        addStraightCurve(
            to: &path,
            from: CGPoint(x: left, y: bottom - radius),
            to: CGPoint(x: left, y: top + radius)
        )
        path.addCurve(
            to: CGPoint(x: left + radius, y: top),
            control1: CGPoint(x: left, y: top + radius - control),
            control2: CGPoint(x: left + radius - control, y: top)
        )
        path.closeSubpath()
        return path
    }

    private func addStraightCurve(
        to path: inout Path,
        from start: CGPoint,
        to end: CGPoint
    ) {
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + delta.x / 3, y: start.y + delta.y / 3),
            control2: CGPoint(x: start.x + delta.x * 2 / 3, y: start.y + delta.y * 2 / 3)
        )
    }
}

/// A decorative overlay over the existing avatar image.
/// Clip the image and this overlay together with AvatarIslandMask.
@MainActor
struct AvatarIslandEffectView: UIViewRepresentable {
    var progress: CGFloat

    func makeUIView(context: Context) -> AvatarIslandEffectUIView {
        let view = AvatarIslandEffectUIView(frame: .zero)
        view.setProgress(progress)
        return view
    }

    func updateUIView(_ uiView: AvatarIslandEffectUIView, context: Context) {
        uiView.setProgress(progress)
    }

    static func dismantleUIView(_ uiView: AvatarIslandEffectUIView, coordinator: ()) {
        uiView.invalidate()
    }
}

@MainActor
final class AvatarIslandEffectUIView: UIView {
    private let blurView = UIVisualEffectView(effect: nil)
    private let blackCover = UIView()
    private let radialShade = CAGradientLayer()
    private let topShade = CAGradientLayer()
    private var blurAnimator: UIViewPropertyAnimator?
    private var requestedProgress: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        blurView.isUserInteractionEnabled = false
        blackCover.isUserInteractionEnabled = false
        blackCover.backgroundColor = .black
        addSubview(blurView)
        addSubview(blackCover)

        radialShade.type = .radial
        radialShade.startPoint = CGPoint(x: 0.5, y: 0.48)
        radialShade.endPoint = CGPoint(x: 1, y: 1)
        radialShade.colors = [
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.cgColor
        ]
        radialShade.locations = [0, 0.55, 0.82, 1]

        topShade.startPoint = CGPoint(x: 0.5, y: 0)
        topShade.endPoint = CGPoint(x: 0.5, y: 1)
        topShade.colors = [
            UIColor.black.withAlphaComponent(0.8).cgColor,
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.clear.cgColor
        ]
        topShade.locations = [0, 0.4, 1]
        layer.addSublayer(radialShade)
        layer.addSublayer(topShade)
        resetRendering()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        blackCover.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        radialShade.frame = bounds
        topShade.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            resetRendering()
        } else {
            renderProgress()
        }
    }

    func setProgress(_ progress: CGFloat) {
        requestedProgress = boundedAvatarIslandProgress(progress)
        renderProgress()
    }

    func invalidate() {
        requestedProgress = 0
        resetRendering()
    }

    private func renderProgress() {
        guard window != nil, requestedProgress > 0 else {
            resetRendering()
            return
        }

        isHidden = false
        let blurFraction = boundedAvatarIslandProgress(-0.1 + 1.1 * requestedProgress)
        let fadeAlpha = boundedAvatarIslandProgress(-0.25 + 1.55 * requestedProgress)

        if blurFraction > 0 {
            prepareBlurAnimatorIfNeeded()
            blurView.isHidden = false
            blurAnimator?.fractionComplete = blurFraction
        } else {
            stopBlurAnimator()
            blurView.isHidden = true
        }

        // The shades darken the perimeter and the edge nearest the island first.
        // At p=1, the solid cover is opaque and all photo detail disappears.
        blackCover.alpha = fadeAlpha
        let edgeAlpha = requestedProgress * (1 - fadeAlpha)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        radialShade.opacity = Float(edgeAlpha * 0.8)
        topShade.opacity = Float(edgeAlpha)
        CATransaction.commit()
    }

    private func prepareBlurAnimatorIfNeeded() {
        guard blurAnimator == nil else { return }
        blurView.effect = nil
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak blurView] in
            blurView?.effect = UIBlurEffect(style: .dark)
        }
        animator.scrubsLinearly = true
        animator.pausesOnCompletion = true
        animator.startAnimation()
        animator.pauseAnimation()
        animator.fractionComplete = 0
        blurAnimator = animator
    }

    private func stopBlurAnimator() {
        if let animator = blurAnimator {
            animator.stopAnimation(true)
            blurAnimator = nil
        }
        blurView.effect = nil
    }

    private func resetRendering() {
        stopBlurAnimator()
        blurView.isHidden = true
        blackCover.alpha = 0
        isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        radialShade.opacity = 0
        topShade.opacity = 0
        CATransaction.commit()
    }
}

private func boundedAvatarIslandProgress(_ progress: CGFloat) -> CGFloat {
    guard progress.isFinite else { return 0 }
    return min(max(progress, 0), 1)
}
