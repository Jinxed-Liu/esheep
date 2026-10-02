import XCTest

final class InsightAssistantEntryUITests: XCTestCase {
    @MainActor
    func testConfiguredAssistantOpensHistoryAndNewChatComposer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-ready",
            "--design-role", "administrator",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let analysisTab = app.tabBars.buttons["分析"]
        XCTAssertTrue(analysisTab.waitForExistence(timeout: 30))
        analysisTab.tap()
        let assistantEntry = app.buttons["analysis-assistant-entry"]
        XCTAssertTrue(assistantEntry.waitForExistence(timeout: 10))
        assistantEntry.tap()
        assertConversationList(in: app, screenshotName: "configured-assistant-entry")
        let retainedHistory = app.buttons["入口回归历史聊天 1"]
        XCTAssertTrue(retainedHistory.exists, "Persisted chat history did not render.")
        retainedHistory.tap()
        XCTAssertTrue(app.staticTexts["这是第 1 条本机隔离验收聊天记录。"].waitForExistence(timeout: 15), "The persisted conversation did not open.")
        let historyBack = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(historyBack.waitForExistence(timeout: 10))
        historyBack.tap()
        assertConversationList(in: app, screenshotName: "configured-history-return")

        // A stable destination must continue receiving SwiftData changes.
        let removableHistory = app.buttons["入口回归历史聊天 2"]
        XCTAssertTrue(removableHistory.exists)
        removableHistory.press(forDuration: 1)
        let delete = app.buttons["删除聊天"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: removableHistory)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed, "The list did not react to the deleted history record.")
        XCTAssertTrue(retainedHistory.exists)

        app.buttons["新聊天"].tap()
        XCTAssertTrue(app.buttons["新建聊天"].waitForExistence(timeout: 15), "The new-chat screen did not open.")
        let composer = app.descendants(matching: .any).matching(identifier: "insight.composer.text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Entry regression draft")
        XCTAssertTrue(app.buttons["insight.reasoning.settings"].waitForExistence(timeout: 10))
        let send = app.buttons["insight.composer.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, "The configured assistant did not become ready.")
        XCTAssertEqual(app.state, .runningForeground)
        // The fixture key exercises local initialization only; never send it.
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "configured-chat-composer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testAssistantEntryOpensConversationListAndCanReenter() {
        continueAfterFailure = false

        let app = XCUIApplication()
        // This existing Debug-only fixture uses a separate local farm store
        // and disables remote connections. Open the assistant through its
        // real button rather than the automatic acceptance-prompt hook.
        app.launchArguments = [
            "--design-acceptance",
            "--design-role", "administrator",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()

        let analysisTab = app.tabBars.buttons["分析"]
        XCTAssertTrue(analysisTab.waitForExistence(timeout: 30), "The isolated farm workspace did not launch.")
        analysisTab.tap()

        let assistantEntry = app.buttons["analysis-assistant-entry"]
        XCTAssertTrue(assistantEntry.waitForExistence(timeout: 10), "The analysis assistant entry is missing.")
        XCTAssertTrue(assistantEntry.isHittable, "The analysis assistant entry is not reachable.")
        assistantEntry.tap()
        assertConversationList(in: app, screenshotName: "assistant-first-entry")

        // Use the native navigation back button, not the nearby chat menu.
        // Returning must restore the original entry and tab bar.
        let backButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label IN %@", ["返回", "Back"])
        ).firstMatch
        XCTAssertTrue(backButton.exists, "The conversation list has no navigation back button.")
        backButton.tap()
        XCTAssertTrue(assistantEntry.waitForExistence(timeout: 10), "Returning did not restore the analysis page.")
        XCTAssertTrue(assistantEntry.isHittable, "Returning did not restore the reachable assistant entry.")
        XCTAssertTrue(analysisTab.waitForExistence(timeout: 10), "Returning did not restore the tab bar.")
        XCTAssertEqual(app.state, .runningForeground)

        assistantEntry.tap()
        assertConversationList(in: app, screenshotName: "assistant-reentry")
    }

    @MainActor
    private func assertConversationList(in app: XCUIApplication, screenshotName: String) {
        XCTAssertTrue(app.buttons["聊天菜单"].waitForExistence(timeout: 15), "The assistant conversation list did not open.")
        XCTAssertTrue(app.buttons["全部"].exists, "The conversation list filter is missing.")
        XCTAssertTrue(app.buttons["新聊天"].exists, "The conversation list's new-chat action is missing.")
        let composer = app.descendants(matching: .any).matching(identifier: "insight.composer.text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The assistant composer did not render.")
        XCTAssertTrue(composer.isHittable, "The assistant composer is not reachable.")
        XCTAssertTrue(app.buttons["insight.composer.send"].exists, "The assistant send control did not render.")
        XCTAssertEqual(app.state, .runningForeground, "The app terminated after opening the assistant.")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
