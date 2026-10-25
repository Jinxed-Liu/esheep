import XCTest

final class ReproductionAnalysisUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-reproduction", "--design-role", "administrator",
            "--design-fixture-id", UUID().uuidString, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["繁殖分析"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["reproduction-stages-entry"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // iOS 17 reports a row hittable with only a few points exposed beside
        // the home indicator. Move its whole hit target inside the viewport.
        let viewport = app.frame.insetBy(dx: 0, dy: 44)
        for _ in 0..<6 {
            if element.isHittable && viewport.contains(element.frame) { return }
            if element.exists && element.frame.midY < viewport.minY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertTrue(viewport.contains(element.frame), "The complete target must be visible before tapping it.")
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testNavigationStagesAndExact211DayEvidence() {
        let app = launch()
        screenshot(app, name: "reproduction-home-local-fixture")
        app.buttons["reproduction-stages-entry"].tap()
        XCTAssertTrue(app.navigationBars["繁殖阶段与检胎"].waitForExistence(timeout: 10))
        let over210 = app.buttons["reproduction-stage-postpartum-7"]
        reveal(over210, in: app)
        screenshot(app, name: "postpartum-fixed-bands-through-over210")
        over210.tap()
        let ewe = app.buttons["reproduction-ewe-QA-008"]
        XCTAssertTrue(ewe.waitForExistence(timeout: 10))
        ewe.tap()
        XCTAssertTrue(app.staticTexts["实际产后天数"].waitForExistence(timeout: 10))
        let actualDays = app.descendants(matching: .any)["reproduction-actual-postpartum"].firstMatch
        XCTAssertEqual(actualDays.value as? String, "211 天")
        screenshot(app, name: "over210-preserves-actual-211-days")
    }

    @MainActor
    func testOccupiedPenSelectorHidesEmptyPenAndKeepsIndividualChoices() {
        let app = launch()
        let scope = app.buttons["reproduction-scope-entry"]
        reveal(scope, in: app); scope.tap()
        XCTAssertTrue(app.buttons["reproduction-save-scope"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["空舍（繁殖验收）"].exists)
        let adult = app.buttons["reproduction-select-pen-繁殖母羊一舍"]
        let young = app.buttons["reproduction-select-pen-青年母羊舍"]
        XCTAssertTrue(adult.waitForExistence(timeout: 10))
        reveal(young, in: app)
        XCTAssertEqual(young.value as? String, "已勾选")
        screenshot(app, name: "occupied-only-pen-selector")
        young.tap()
        XCTAssertEqual(young.value as? String, "未勾选")
        app.buttons["reproduction-save-scope"].tap()
        XCTAssertTrue(app.navigationBars["繁殖分析"].waitForExistence(timeout: 10))
        let pens = app.buttons["reproduction-pens-entry"]
        if !pens.isHittable { app.swipeDown() }
        reveal(pens, in: app); pens.tap()
        XCTAssertTrue(app.staticTexts["繁殖母羊一舍"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["青年母羊舍"].waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testYoungEweRequiresHumanConfirmationAndHistoryRemainsReachable() {
        let app = launch()
        let readiness = app.buttons["reproduction-readiness-entry"]
        reveal(readiness, in: app); readiness.tap()
        let pending = app.buttons["reproduction-readiness-QA-011"]
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        XCTAssertEqual(pending.value as? String, "未勾选")
        pending.tap()
        XCTAssertEqual(pending.value as? String, "已勾选")
        app.buttons["reproduction-save-readiness"].tap()
        XCTAssertTrue(app.navigationBars["繁殖分析"].waitForExistence(timeout: 10))
        app.swipeDown()
        let stages = app.buttons["reproduction-stages-entry"]
        reveal(stages, in: app); stages.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "青年母羊")).firstMatch.tap()
        XCTAssertTrue(app.buttons["reproduction-ewe-QA-011"].waitForExistence(timeout: 10))
        screenshot(app, name: "young-ewe-after-explicit-human-confirmation")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let history = app.buttons["reproduction-rhythm-entry"]
        reveal(history, in: app); history.tap()
        XCTAssertTrue(app.navigationBars["繁殖节律"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["胎间距"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["产后天数"].exists)
        screenshot(app, name: "historical-reproduction-rhythm-preserved")
    }
}
