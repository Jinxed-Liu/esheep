import XCTest
import UIKit

final class PlatformCompatibilityUITests: XCTestCase {
    /// Run the same gestures on iOS 17's scroll bridge and the newer native
    /// scroll APIs. This uses a separate local fixture and never saves an edit.
    @MainActor
    func testAvatarPullViewerDismissalRestoresLayoutAndNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-account-settings",
            "--design-account-avatar-image", "--design-fixture-id", UUID().uuidString,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-settings.avatar-motion", "YES", "-settings.reduce-motion", "NO",
            "-settings.power-saving", "NO",
        ]
        app.launch()

        let avatar = app.buttons["account-avatar-entry"]
        waitForReady(avatar, in: app, timeout: 30)
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        waitForState("The collapsed avatar did not settle at the top of settings.", in: app) {
            let frame = avatar.frame
            let window = app.windows.firstMatch.frame
            return frame.width > 44 && frame.width < window.width / 2 &&
                abs(frame.width - frame.height) <= 2 && abs(frame.midX - window.midX) <= 2
        }
        let initialFrame = avatar.frame
        attachScreenshot(of: app, named: "avatar-settings-collapsed")

        pullDown(in: scrollView, below: avatar)
        var previousExpandedFrame: CGRect?
        var settledAt: Date?
        waitForState("The first pull did not expand the avatar.", in: app) {
            guard avatar.exists, avatar.isHittable else { return false }
            let frame = avatar.frame
            guard frame.width > initialFrame.width * 2,
                  frame.height > initialFrame.height * 2 else { return false }
            defer { previousExpandedFrame = frame }
            guard let previous = previousExpandedFrame,
                  abs(frame.minX - previous.minX) <= 1,
                  abs(frame.minY - previous.minY) <= 1,
                  abs(frame.width - previous.width) <= 1,
                  abs(frame.height - previous.height) <= 1 else {
                settledAt = nil
                return false
            }
            let since = settledAt ?? .now
            settledAt = since
            return Date.now.timeIntervalSince(since) >= 0.5
        }
        let close = app.buttons["account-avatar-viewer-close"]
        XCTAssertFalse(close.exists, "A single pull must expand the avatar before a second pull opens the viewer.")
        attachScreenshot(of: app, named: "avatar-settings-expanded-after-first-pull")
        attachAccessibilityHierarchy(of: app, named: "avatar-settings-expanded-accessibility-hierarchy")

        // A new drag must capture the expanded state. Reusing the first drag
        // would miss regressions in native scroll phase or bridge pan tracking.
        pullDown(in: scrollView, below: avatar)
        waitForReady(close, in: app)
        let image = app.images["account-avatar-viewer-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10), "The full-screen avatar image is missing.")
        attachScreenshot(of: app, named: "avatar-viewer-after-second-pull")

        close.tap()
        waitForState("Closing the viewer did not restore the original avatar layout.", in: app) {
            guard !close.exists, avatar.exists, avatar.isHittable else { return false }
            let frame = avatar.frame
            return abs(frame.minX - initialFrame.minX) <= 3 &&
                abs(frame.minY - initialFrame.minY) <= 3 &&
                abs(frame.width - initialFrame.width) <= 3 &&
                abs(frame.height - initialFrame.height) <= 3
        }
        attachScreenshot(of: app, named: "avatar-settings-restored-after-viewer")

        // The real navigation action must remain reachable after dismissal.
        let edit = app.navigationBars.buttons["编辑"]
        waitForReady(edit, in: app)
        edit.tap()
        let editorBar = app.navigationBars["修改名称"]
        XCTAssertTrue(editorBar.waitForExistence(timeout: 10))
        let name = app.textFields["显示名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "设计验收")
        attachScreenshot(of: app, named: "avatar-restored-settings-navigation-opens-name-editor")

        // Leave through the native back action. Saving would invoke account
        // identity services, which this local compatibility test does not use.
        let back = editorBar.buttons.matching(
            NSPredicate(format: "label IN %@", ["返回", "Back", "设计验收"])
        ).firstMatch
        waitForReady(back, in: app)
        back.tap()
        waitForReady(avatar, in: app)
        waitForReady(edit, in: app)
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(of: app, named: "avatar-settings-navigation-return")
    }

    @MainActor
    private func pullDown(in scrollView: XCUIElement, below avatar: XCUIElement) {
        // Start below the current photo button. Reusing a viewport percentage
        // lands inside that button after expansion and mixes tap/scroll input.
        let viewport = scrollView.frame
        let startY = max(avatar.frame.maxY + 24, viewport.minY + viewport.height * 0.25)
        let distance = min(viewport.height * 0.35, viewport.maxY - startY - 24)
        XCTAssertGreaterThanOrEqual(distance, 100, "The avatar leaves insufficient room for a native pull gesture.")
        let start = scrollView.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: viewport.width / 2, dy: startY - viewport.minY)
        )
        let end = start.withOffset(CGVector(dx: 0, dy: distance))
        // Keep the finger down briefly at the destination so native scroll
        // geometry is delivered before release on a loaded hosted simulator.
        // This remains one drag per stage, with no retries or tap fallback.
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    @MainActor
    private func waitForReady(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10) {
        let exists = element.waitForExistence(timeout: timeout)
        if !exists { attachFailureEvidence(of: app) }
        XCTAssertTrue(exists, "The expected control did not appear: \(element).")
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed { attachFailureEvidence(of: app) }
        XCTAssertEqual(result, .completed, "The expected control did not become actionable: \(element).")
    }

    @MainActor
    private func waitForState(
        _ message: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        condition: @escaping () -> Bool
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: app
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed { attachFailureEvidence(of: app) }
        XCTAssertEqual(result, .completed, message)
    }

    @MainActor
    private func attachFailureEvidence(of app: XCUIApplication) {
        attachScreenshot(of: app, named: "avatar-compatibility-failure")
        attachAccessibilityHierarchy(of: app, named: "avatar-compatibility-failure-accessibility-hierarchy")
    }

    @MainActor
    private func attachAccessibilityHierarchy(of app: XCUIApplication, named name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name)-iOS-\(UIDevice.current.systemVersion)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
