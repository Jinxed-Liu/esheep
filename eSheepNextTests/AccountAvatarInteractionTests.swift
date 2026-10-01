import Foundation
import XCTest
@testable import eSheepNext

@MainActor
final class AccountAvatarInteractionTests: XCTestCase {
    func testFirstPullExpandsAndASeparatePullPresentsViewer() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -31, hasImage: true), .none)
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
        XCTAssertEqual(interaction.presentation, .expanded)
        XCTAssertEqual(interaction.update(offsetY: -200, hasImage: true), .none)

        interaction.endDragging()
        XCTAssertEqual(interaction.presentation, .expanded)

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -31, hasImage: true), .none)
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .presentViewer)
        XCTAssertEqual(interaction.presentation, .presenting)
    }

    func testDuplicateDragBeginCannotUnlockViewerDuringFirstPull() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
        interaction.beginDragging()

        XCTAssertEqual(interaction.update(offsetY: -150, hasImage: true), .none)
        XCTAssertEqual(interaction.presentation, .expanded)
    }

    func testThresholdJitterDoesNotRepeatPullEffects() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
        for offset in [CGFloat(-31), -33, -30, -80, 0, -32] {
            XCTAssertEqual(interaction.update(offsetY: offset, hasImage: true), .none)
        }

        interaction.endDragging()
        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .presentViewer)
        for offset in [CGFloat(-31), -33, 2, -80] {
            XCTAssertEqual(interaction.update(offsetY: offset, hasImage: true), .none)
        }
    }

    func testReverseScrollCanCollapseAfterExpansionInTheSameDrag() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -40, hasImage: true), .expand)
        XCTAssertEqual(interaction.update(offsetY: 0.9, hasImage: true), .none)
        XCTAssertEqual(interaction.update(offsetY: 1, hasImage: true), .collapse)
        XCTAssertEqual(interaction.presentation, .collapsed)
        XCTAssertEqual(interaction.update(offsetY: 2, hasImage: true), .none)
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)

        interaction.endDragging()
        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
    }

    func testCollapsingAtStartOfSecondDragRevokesViewerEligibility() {
        var interaction = AccountAvatarInteraction()
        XCTAssertEqual(interaction.expand(), .expand)

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: 1, hasImage: true), .collapse)
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)
        XCTAssertEqual(interaction.presentation, .collapsed)

        interaction.endDragging()
        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
        XCTAssertEqual(interaction.presentation, .expanded)
    }

    func testMissingImageDoesNotExpandOrConsumePullThreshold() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -200, hasImage: false), .none)
        XCTAssertEqual(interaction.presentation, .collapsed)
        XCTAssertEqual(interaction.update(offsetY: -200, hasImage: true), .expand)
    }

    func testMissingImageBlocksViewerButStillAllowsCollapse() {
        var interaction = AccountAvatarInteraction()
        interaction.expand()

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -200, hasImage: false), .none)
        XCTAssertEqual(interaction.presentation, .expanded)
        XCTAssertEqual(interaction.update(offsetY: 1, hasImage: false), .collapse)
        XCTAssertEqual(interaction.presentation, .collapsed)
    }

    func testNonFiniteOffsetsAreIgnoredWithoutConsumingThreshold() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        for offset in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            XCTAssertEqual(interaction.update(offsetY: offset, hasImage: true), .none)
            XCTAssertEqual(interaction.presentation, .collapsed)
        }
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)

        for offset in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            XCTAssertEqual(interaction.update(offsetY: offset, hasImage: true), .none)
            XCTAssertEqual(interaction.presentation, .expanded)
        }
    }

    func testOffsetsOutsideActiveGestureCannotChangePresentation() {
        var interaction = AccountAvatarInteraction()
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
        interaction.endDragging()

        // A scroll view's deceleration or bounce must not become the second pull.
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)
        XCTAssertEqual(interaction.update(offsetY: 10, hasImage: true), .none)
        XCTAssertEqual(interaction.presentation, .expanded)
    }

    func testCancelledDragCanRestartWithoutStaleViewerEligibility() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -20, hasImage: true), .none)
        interaction.endDragging()
        interaction.endDragging()

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)
    }

    func testTappingToExpandDuringADragDoesNotUnlockViewer() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        XCTAssertEqual(interaction.expand(), .expand)
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)
        interaction.endDragging()

        XCTAssertEqual(interaction.presentViewer(), .presentViewer)
        XCTAssertEqual(interaction.presentation, .presenting)
    }

    func testViewerLifecycleIgnoresRepeatedActionsAndStaleCallbacks() {
        var interaction = AccountAvatarInteraction()

        XCTAssertEqual(interaction.presentViewer(), .none)
        interaction.viewerDidPresent()
        interaction.beginDismissal()
        interaction.viewerDidDismiss()
        XCTAssertEqual(interaction.presentation, .collapsed)

        XCTAssertEqual(interaction.expand(), .expand)
        XCTAssertEqual(interaction.expand(), .none)
        XCTAssertEqual(interaction.presentViewer(), .presentViewer)
        XCTAssertEqual(interaction.presentViewer(), .none)
        XCTAssertEqual(interaction.expand(), .none)
        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: 10, hasImage: true), .none)

        interaction.viewerDidPresent()
        XCTAssertEqual(interaction.presentation, .viewing)
        interaction.viewerDidPresent()
        XCTAssertEqual(interaction.presentation, .viewing)

        interaction.beginDismissal()
        interaction.beginDismissal()
        XCTAssertEqual(interaction.presentation, .dismissing)
        interaction.viewerDidPresent()
        XCTAssertEqual(interaction.presentation, .dismissing)
        interaction.viewerDidDismiss()
        XCTAssertEqual(interaction.presentation, .collapsed)
        interaction.viewerDidDismiss()
        XCTAssertEqual(interaction.presentation, .collapsed)
    }

    func testClosingDuringPresentationCannotBeReopenedByCompletion() {
        var interaction = AccountAvatarInteraction()
        interaction.expand()
        interaction.presentViewer()

        interaction.beginDismissal()
        XCTAssertEqual(interaction.presentation, .dismissing)
        interaction.viewerDidPresent()
        XCTAssertEqual(interaction.presentation, .dismissing)
        XCTAssertEqual(interaction.expand(), .none)
        XCTAssertEqual(interaction.presentViewer(), .none)

        interaction.viewerDidDismiss()
        XCTAssertEqual(interaction.presentation, .collapsed)
        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)
    }

    func testResetClearsActiveDragAndViewerCallbacks() {
        var interaction = AccountAvatarInteraction()

        interaction.beginDragging()
        _ = interaction.update(offsetY: -32, hasImage: true)
        interaction.reset()
        XCTAssertEqual(interaction.presentation, .collapsed)
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)

        interaction.expand()
        interaction.presentViewer()
        interaction.reset()
        interaction.viewerDidPresent()
        interaction.viewerDidDismiss()
        XCTAssertEqual(interaction.presentation, .collapsed)

        interaction.beginDragging()
        XCTAssertEqual(interaction.update(offsetY: -32, hasImage: true), .expand)
        XCTAssertEqual(interaction.update(offsetY: -100, hasImage: true), .none)
    }

    func testNavigationResetKeepsTheActualScrollPosition() {
        let motion = AccountAvatarMotionCoordinator()
        motion.updateScroll(offsetY: 130, hasImage: true)

        motion.resetIfNotPresenting()

        XCTAssertEqual(motion.scrollOffset, 130)
        XCTAssertEqual(motion.titleProgress, 1)
        XCTAssertEqual(motion.interaction.presentation, .collapsed)
    }

    func testReducingMotionDuringEntranceKeepsTheSourceUntilPresentationFinishes() {
        let motion = AccountAvatarMotionCoordinator()
        motion.tapAvatar()
        motion.tapAvatar()
        XCTAssertEqual(motion.interaction.presentation, .presenting)

        motion.configure(animationsEnabled: false)
        XCTAssertEqual(motion.expansion, 1)
        motion.resetIfNotPresenting()
        XCTAssertTrue(motion.isViewerPresented)

        motion.viewerDidPresent()
        XCTAssertEqual(motion.expansion, 0)
        XCTAssertEqual(motion.interaction.presentation, .viewing)
    }

    func testEditingStartsOnlyAfterViewerDismissalAndClearsThePendingIntent() {
        let motion = AccountAvatarMotionCoordinator()
        motion.tapAvatar()
        motion.tapAvatar()
        motion.viewerDidPresent()
        motion.requestDismissal(editAvatar: true)

        XCTAssertFalse(motion.isViewerPresented)
        XCTAssertEqual(motion.interaction.presentation, .dismissing)
        motion.viewerDidPresent()
        XCTAssertEqual(motion.interaction.presentation, .dismissing)

        XCTAssertTrue(motion.viewerDidDismiss())
        XCTAssertEqual(motion.interaction.presentation, .collapsed)
        XCTAssertFalse(motion.viewerDidDismiss())
    }

}
