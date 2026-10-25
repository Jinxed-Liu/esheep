import XCTest

final class PenManagementUITests: XCTestCase {
    @MainActor
    func testManagementEntryCreateEditRetireReactivateAndSafeDelete() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-role", "administrator",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let workbench = app.tabBars.buttons["工作台"]
        XCTAssertTrue(workbench.waitForExistence(timeout: 30))
        workbench.tap()
        app.buttons["workbench-pen-management"].tap()
        let add = app.buttons["add-pen"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let name = "QA-" + UUID().uuidString.prefix(8)
        let nameField = app.textFields["羊舍名称"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["保存"].isEnabled)
        nameField.tap(); nameField.typeText(name)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10), "New empty pens must appear in the default list.")
        let created = XCTAttachment(screenshot: app.screenshot())
        created.name = "new-empty-pen-visible-in-management"
        created.lifetime = .keepAlways
        self.add(created)
        app.staticTexts[name].tap()
        XCTAssertTrue(app.staticTexts["启用 · 空舍"].waitForExistence(timeout: 10))
        app.buttons["编辑"].tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "The first edit presentation must contain its pen.")
        nameField.tap(); nameField.typeText("-edited")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars[name + "-edited"].waitForExistence(timeout: 10))
        app.buttons["编辑"].tap()
        let retire = app.buttons["停用羊舍"]
        XCTAssertTrue(retire.waitForExistence(timeout: 10))
        retire.tap()
        app.buttons["停用"].tap()
        XCTAssertTrue(app.staticTexts["已停用 · 空舍"].waitForExistence(timeout: 10))
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.buttons["重新启用羊舍"].waitForExistence(timeout: 10))
        app.buttons["重新启用羊舍"].tap()
        XCTAssertTrue(app.staticTexts["启用 · 空舍"].waitForExistence(timeout: 10))
        app.buttons["编辑"].tap()
        XCTAssertTrue(retire.waitForExistence(timeout: 10))
        // The native type differs by OS, and the placeholder disappears after
        // typing. Keep the same real input addressable throughout the edit.
        let reason = app.descendants(matching: .any)["pen-deletion-reason"].firstMatch
        XCTAssertTrue(reason.exists)
        if !reason.isHittable { app.swipeUp() }
        // The legacy TextView's synthesized hit point lies on its top edge
        // (45, 571.33 for a frame of 40, 571.33, 350, 23), missing text focus.
        reason.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        reason.typeText("Isolated UI test cleanup")
        XCTAssertEqual(reason.value as? String, "Isolated UI test cleanup")
        let delete = app.buttons["delete-unused-pen"]
        let keyboard = app.keyboards.firstMatch
        let visibleBottom = keyboard.exists ? keyboard.frame.minY : app.frame.maxY - 44
        if !delete.isHittable || delete.frame.maxY > visibleBottom - 8 {
            // The iOS 17 candidate bar starts above Keyboard.frame.minY.
            // Begin above the focused field, on the visible form, so the
            // keyboard cannot consume the scroll intended to reveal this row.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let startY = min(visibleBottom - 24, reason.frame.minY - 16)
            let start = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: startY - app.frame.minY))
            let endY = max(app.navigationBars.firstMatch.frame.maxY + 24, startY - 176)
            let end = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: endY - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(delete.isHittable)
        XCTAssertLessThanOrEqual(delete.frame.maxY, keyboard.exists ? keyboard.frame.minY - 8 : app.frame.maxY - 44)
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        app.buttons["确认删除"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Deleting must return to management.")
        XCTAssertFalse(app.staticTexts[name + "-edited"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "pen-management-after-complete-lifecycle"
        screenshot.lifetime = .keepAlways
        self.add(screenshot)
    }
}
