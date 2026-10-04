import SwiftUI
import UIKit

/// Effects above the image; the header owns the black backing and window-space
/// neck mask. The three tracks follow Telegram's DynamicIslandBlurNode reference.
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
    private let radialShade = AvatarIslandRadialShadeView()
    private let blackCover = UIView()
    private var blurAnimator: UIViewPropertyAnimator?
    private var requestedProgress: CGFloat = 0
    private var topOverscan: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        clipsToBounds = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        blurView.isUserInteractionEnabled = false
        blackCover.isUserInteractionEnabled = false
        blackCover.backgroundColor = .black
        addSubview(blurView)
        addSubview(radialShade)
        addSubview(blackCover)
        resetRendering()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let paintBounds = SettingsAvatarIslandGeometry.paintBounds(in: bounds, topOverscan: topOverscan)
        blurView.frame = paintBounds
        // This artwork is a fixed-size rim at the top of the effect canvas.
        // Stretching it to 171pt moves the clear center below the avatar neck.
        radialShade.frame = SettingsAvatarIslandGeometry.paintBounds(
            in: CGRect(x: (bounds.width - 100) / 2, y: 0, width: 100, height: 100),
            topOverscan: topOverscan
        )
        blackCover.frame = paintBounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            resetRendering()
        } else {
            renderProgress()
        }
    }

    func setProgress(_ progress: CGFloat, topOverscan: CGFloat = 0) {
        let overscan = topOverscan.isFinite ? max(0, topOverscan) : 0
        if self.topOverscan != overscan {
            self.topOverscan = overscan
            radialShade.topOverscan = overscan
            setNeedsLayout()
        }
        requestedProgress = boundedAvatarIslandProgress(progress)
        renderProgress()
    }

    func invalidate() {
        requestedProgress = 0
        resetRendering()
    }

    private func renderProgress() {
        guard window != nil, requestedProgress > 0.03 else {
            resetRendering()
            return
        }
        isHidden = false
        let blurFraction = boundedAvatarIslandProgress(-0.1 + 1.1 * requestedProgress)
        if blurFraction > 0 {
            prepareBlurAnimatorIfNeeded()
            blurView.isHidden = false
            blurAnimator?.fractionComplete = blurFraction
        } else {
            stopBlurAnimator()
            blurView.isHidden = true
        }
        // The radial edge is independent of the fade, as in the reference.
        blackCover.alpha = boundedAvatarIslandProgress(-0.25 + 1.55 * requestedProgress)
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
    }
}

/// A 100-point radial rim. Drawing occurs on size changes; scrolling changes
/// only effect values, keeping the clear center at canvas y=88.
@MainActor
final class AvatarIslandRadialShadeView: UIView {
    var topOverscan: CGFloat = 0 {
        didSet {
            if topOverscan != oldValue { setNeedsDisplay() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0,
              let context = UIGraphicsGetCurrentContext(),
              let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor] as CFArray,
                locations: [0, 0.87, 1]
              ) else { return }
        context.saveGState()
        // Extend paint above the artwork without moving its center or rim.
        context.translateBy(x: 0, y: topOverscan)
        context.scaleBy(x: bounds.width / 100, y: (bounds.height - topOverscan) / 100)
        context.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: 50, y: 88), startRadius: 0,
            endCenter: CGPoint(x: 50, y: 88), endRadius: 90,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }
}

private func boundedAvatarIslandProgress(_ progress: CGFloat) -> CGFloat {
    guard progress.isFinite else { return 0 }
    return min(max(progress, 0), 1)
}
