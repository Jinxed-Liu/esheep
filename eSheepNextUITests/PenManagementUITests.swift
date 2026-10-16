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
        let reason = app.textFields["删除原因"]
        if !reason.isHittable { app.swipeUp() }
        reason.tap(); reason.typeText("Isolated UI test cleanup")
        let delete = app.buttons["delete-unused-pen"]
        if !delete.isHittable { app.swipeUp() }
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
