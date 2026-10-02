import Observation
import SwiftUI
import UIKit

/// Owns presentation effects; the gesture reducer stays independent of SwiftUI.
@MainActor
@Observable
final class AccountAvatarMotionCoordinator {
    private(set) var interaction = AccountAvatarInteraction()
    private(set) var scrollOffset: CGFloat = 0
    private(set) var expansion: CGFloat = 0
    private(set) var sourceFrame: CGRect = .zero
    private(set) var availableWidth: CGFloat = 100
    private(set) var contentOrigin: CGPoint = .zero
    private(set) var titleHeight: CGFloat = floor(
        UIFont.systemFont(ofSize: 28, weight: .medium).ascender -
            UIFont.systemFont(ofSize: 28, weight: .medium).descender
    )
    private(set) var isSourceHidden = false
    @ObservationIgnored private(set) var rendererSourceProvider: (@MainActor () -> AccountAvatarTransitionSource?)?
    private(set) var animationsEnabled = true
    private(set) var isViewerPresented = false
    private(set) var expansionFeedback = 0
    private(set) var collapseFeedback = 0
    private(set) var viewerFeedback = 0
    private(set) var previewImage: UIImage?
    private(set) var previewDigest: String?

    private var editAfterDismissal = false

    var titleProgress: CGFloat {
        let distance = 107 + titleHeight / 2
        if !animationsEnabled {
            return scrollOffset >= distance ? 1 : 0
        }
        return min(max(scrollOffset / distance, 0), 1)
    }

    func configure(animationsEnabled: Bool) {
        guard self.animationsEnabled != animationsEnabled else { return }
        self.animationsEnabled = animationsEnabled
        if !animationsEnabled, interaction.presentation != .presenting {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expansion = interaction.presentation == .expanded ? 1 : 0
            }
        }
    }

    func updateAvailableWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        let bounded = max(width, 100)
        if abs(availableWidth - bounded) > 0.5 {
            availableWidth = bounded
        }
    }

    func updateTitleHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        if abs(titleHeight - height) > 0.5 {
            titleHeight = height
        }
    }

    func updateContentOrigin(_ origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        if abs(contentOrigin.x - origin.x) > 0.5 || abs(contentOrigin.y - origin.y) > 0.5 {
            contentOrigin = origin
        }
    }

    func installRendererSourceProvider(_ provider: (@MainActor () -> AccountAvatarTransitionSource?)?) {
        rendererSourceProvider = provider
    }

    func setSourceHidden(_ hidden: Bool) {
        guard isSourceHidden != hidden else { return }
        isSourceHidden = hidden
    }

    func updateSourceFrame(_ frame: CGRect) {
        guard frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return }
        if sourceFrame != frame {
            sourceFrame = frame
        }
    }

    func storePreview(_ thumbnail: ImageThumbnail, digest: String) {
        previewImage = UIImage(cgImage: thumbnail.cgImage, scale: thumbnail.scale, orientation: .up)
        previewDigest = digest
    }

    func beginDragging() {
        interaction.beginDragging()
    }

    func endDragging() {
        // Eligibility is reset at finger release, before scroll deceleration.
        interaction.endDragging()
    }

    func updateScroll(offsetY: CGFloat, hasImage: Bool) {
        guard offsetY.isFinite else { return }
        scrollOffset = offsetY
        apply(interaction.update(offsetY: offsetY, hasImage: hasImage))
    }

    func tapAvatar() {
        switch interaction.presentation {
        case .collapsed:
            apply(interaction.expand())
        case .expanded:
            apply(interaction.presentViewer())
        case .presenting, .viewing, .dismissing:
            break
        }
    }

    func viewerDidPresent() {
        interaction.viewerDidPresent()
        guard interaction.presentation == .viewing else { return }
        // The presentation lifecycle callback runs after all photo transition tracks complete.
        // Restore the return target while it is covered by the viewer.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expansion = 0
        }
    }

    func requestDismissal(editAvatar: Bool = false) {
        guard isViewerPresented else { return }
        editAfterDismissal = editAvatar
        interaction.beginDismissal()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expansion = 0
        }
        isViewerPresented = false
    }

    func viewerDidDismiss() -> Bool {
        let shouldEdit = editAfterDismissal
        interaction.viewerDidDismiss()
        reset()
        return shouldEdit
    }

    func resetIfNotPresenting() {
        guard !isViewerPresented,
              interaction.presentation != .dismissing else { return }
        reset()
    }

    func reset() {
        interaction.reset()
        // Keep the last measured offset: navigation preserves the scroll view.
        expansion = 0
        isViewerPresented = false
        editAfterDismissal = false
        isSourceHidden = false
    }

    private func apply(_ effect: AccountAvatarInteractionEffect) {
        switch effect {
        case .none:
            break
        case .expand:
            expansionFeedback += 1
            animateExpansion(to: 1)
        case .collapse:
            collapseFeedback += 1
            animateExpansion(to: 0)
        case .presentViewer:
            viewerFeedback += 1
            isViewerPresented = true
        }
    }

    private func animateExpansion(to value: CGFloat) {
        if animationsEnabled {
            withAnimation(.timingCurve(0.38, 0.70, 0.125, 1, duration: 0.35)) {
                expansion = value
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expansion = value
            }
        }
    }
}
