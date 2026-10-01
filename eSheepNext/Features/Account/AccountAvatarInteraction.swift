import Foundation

enum AccountAvatarPresentation: Equatable {
    case collapsed
    case expanded
    case presenting
    case viewing
    case dismissing
}

enum AccountAvatarInteractionEffect: Equatable {
    case none
    case expand
    case collapse
    case presentViewer
}

/// Resolves avatar gestures without owning animation, image loading, or haptics.
/// Negative offsets are a pull below the resting position; positive offsets scroll up.
struct AccountAvatarInteraction {
    private(set) var presentation: AccountAvatarPresentation = .collapsed

    private var isDragging = false
    private var canPresentViewerInCurrentDrag = false
    private var didTriggerPullEffect = false

    private static let pullThreshold: CGFloat = -32
    private static let collapseThreshold: CGFloat = 1

    mutating func beginDragging() {
        guard !isDragging else { return }
        guard presentation == .collapsed || presentation == .expanded else { return }

        isDragging = true
        // Capture eligibility once. Expanding during this drag cannot unlock the viewer.
        canPresentViewerInCurrentDrag = presentation == .expanded
        didTriggerPullEffect = false
    }

    mutating func update(offsetY: CGFloat, hasImage: Bool) -> AccountAvatarInteractionEffect {
        guard isDragging, offsetY.isFinite else { return .none }
        guard presentation == .collapsed || presentation == .expanded else { return .none }

        if presentation == .expanded, offsetY >= Self.collapseThreshold {
            presentation = .collapsed
            canPresentViewerInCurrentDrag = false
            // Permit an immediate reversal, but never another pull action in this drag.
            didTriggerPullEffect = true
            return .collapse
        }

        guard hasImage, offsetY <= Self.pullThreshold, !didTriggerPullEffect else {
            return .none
        }

        switch presentation {
        case .collapsed:
            return expand()
        case .expanded where canPresentViewerInCurrentDrag:
            return presentViewer()
        default:
            return .none
        }
    }

    mutating func endDragging() {
        isDragging = false
        canPresentViewerInCurrentDrag = false
        didTriggerPullEffect = false
    }

    @discardableResult
    mutating func expand() -> AccountAvatarInteractionEffect {
        guard presentation == .collapsed else { return .none }
        presentation = .expanded
        canPresentViewerInCurrentDrag = false
        didTriggerPullEffect = isDragging
        return .expand
    }

    @discardableResult
    mutating func presentViewer() -> AccountAvatarInteractionEffect {
        guard presentation == .expanded else { return .none }
        presentation = .presenting
        endDragging()
        return .presentViewer
    }

    mutating func viewerDidPresent() {
        guard presentation == .presenting else { return }
        presentation = .viewing
    }

    mutating func beginDismissal() {
        guard presentation == .presenting || presentation == .viewing else { return }
        presentation = .dismissing
        endDragging()
    }

    mutating func viewerDidDismiss() {
        guard presentation == .dismissing else { return }
        presentation = .collapsed
        endDragging()
    }

    mutating func reset() {
        presentation = .collapsed
        endDragging()
    }
}
