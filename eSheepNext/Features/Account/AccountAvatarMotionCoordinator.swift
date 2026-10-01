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
    private(set) var availableWidth: CGFloat = 96
    private(set) var animationsEnabled = true
    private(set) var isViewerPresented = false
    private(set) var expansionFeedback = 0
    private(set) var collapseFeedback = 0
    private(set) var viewerFeedback = 0
    private(set) var previewImage: UIImage?
    private(set) var previewDigest: String?

    private var editAfterDismissal = false

    var titleProgress: CGFloat {
        if !animationsEnabled {
            return scrollOffset >= 76 ? 1 : 0
        }
        return min(max(scrollOffset / 94, 0), 1)
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
        let bounded = min(max(width, 96), 420)
        if abs(availableWidth - bounded) > 0.5 {
            availableWidth = bounded
        }
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
        // The presentation lifecycle callback runs after the zoom completes.
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
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
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
