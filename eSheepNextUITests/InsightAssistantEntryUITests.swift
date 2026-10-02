import XCTest

final class InsightAssistantEntryUITests: XCTestCase {
    @MainActor
    func testListComposerUsesReturnForNewlineAndSendPersistsConversation() {
        continueAfterFailure = false
        let firstLine = "Composer \(UUID().uuidString.prefix(8))"
        let message = firstLine + "\nSecond line"
        let response = "离线发送验收：已收到两行输入。"
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-ready", "--design-insight-offline-send",
            "--design-insight-expected-message-base64", Data(message.utf8).base64EncodedString(),
            "--design-role", "administrator",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openAssistantEntry(in: app)
        assertConversationList(in: app, screenshotName: "composer-empty-before-send")

        let composer = composerField(in: app)
        let emptyValue = composer.value as? String ?? ""
        XCTAssertTrue(emptyValue.isEmpty || emptyValue == "信息", "The new draft was not empty.")
        composer.tap()
        composer.typeText(firstLine)
        let returnKey = app.keyboards.buttons.matching(
            NSPredicate(format: "label IN %@", ["Return", "return", "换行", "回车"])
        ).firstMatch
        XCTAssertTrue(returnKey.waitForExistence(timeout: 5), "The multiline editor has no native Return key.")
        returnKey.tap()
        XCTAssertEqual(composer.value as? String, firstLine + "\n", "Return must insert a newline into the draft.")
        XCTAssertFalse(app.staticTexts[response].exists, "Return unexpectedly submitted the draft.")
        composer.typeText("Second line")
        XCTAssertEqual(composer.value as? String, message)

        let send = app.buttons["insight.composer.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertTrue(send.isHittable, "The dedicated send button is covered or unreachable.")
        XCTAssertEqual(send.label, "发送")
        let microphone = app.buttons["insight.audio.record"]
        XCTAssertTrue(microphone.isEnabled, "Local recording is incorrectly disabled.")
        XCTAssertTrue(microphone.isHittable, "The recording button is not reachable.")
        attachScreenshot(of: app, named: "composer-typed-ready-to-send")
        // Slightly longer normal presses must still send. The voice long-press
        // recognizer previously participated even while this arrow was shown.
        send.press(forDuration: 0.25)

        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 20), "The send button did not create the user message.")
        XCTAssertTrue(app.staticTexts[response].waitForExistence(timeout: 30), "The real controller did not complete the offline model response.")
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", emptyValue), object: composerField(in: app)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed, "A sent draft remained in the composer.")
        XCTAssertFalse(app.buttons["insight.composer.stop"].exists, "The completed response still appears to be generating.")
        attachScreenshot(of: app, named: "composer-after-send")

        // Re-launch the process so neither cached controllers nor an in-memory
        // view can stand in for saved conversation and message records.
        app.terminate()
        app.launch()
        openAssistantEntry(in: app)
        XCTAssertEqual(composerField(in: app).value as? String ?? "", emptyValue, "The consumed list draft returned after relaunch.")
        let savedConversation = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", firstLine)
        ).firstMatch
        XCTAssertTrue(savedConversation.waitForExistence(timeout: 15), "The sent conversation was not saved in history.")
        savedConversation.tap()
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 15), "The persisted user message lost its newline or text.")
        XCTAssertTrue(app.staticTexts[response].exists, "The completed assistant response was not persisted.")
        XCTAssertEqual(app.state, .runningForeground)
        attachScreenshot(of: app, named: "composer-persisted-conversation-after-relaunch")
    }

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
        app.resetAuthorizationStatus(for: .microphone)
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

        // Recording is local. It must remain actionable before model service
        // setup and route into the real system permission workflow.
        XCTAssertTrue(app.buttons["insight.availability.settings"].waitForExistence(timeout: 10))
        let microphone = app.buttons["insight.audio.record"]
        XCTAssertTrue(microphone.isEnabled, "Recording must not require a model credential.")
        XCTAssertTrue(microphone.isHittable, "The microphone is covered or unreachable.")
        let denialMonitor = addUIInterruptionMonitor(withDescription: "Deny the microphone permission") { alert in
            guard alert.label.localizedCaseInsensitiveContains("microphone") || alert.label.contains("麦克风") else {
                return false
            }
            let deny = alert.buttons.matching(
                NSPredicate(format: "label IN %@", ["不允许", "Don’t Allow", "Don't Allow"])
            ).firstMatch
            guard deny.exists else { return false }
            deny.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(denialMonitor) }
        microphone.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemPermission = springboard.alerts.firstMatch
        XCTAssertTrue(systemPermission.waitForExistence(timeout: 10), "Recording did not request microphone access.")
        // App interaction invokes XCTest's interruption monitor and verifies
        // dismissal, rather than assuming a direct SpringBoard tap succeeded.
        app.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: systemPermission
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed, "The system permission prompt did not close after denial.")
        let permissionFailure = app.alerts["AI 助手"]
        XCTAssertTrue(permissionFailure.waitForExistence(timeout: 15), "The microphone tap did not reach the permission workflow.")
        XCTAssertTrue(permissionFailure.staticTexts["未获得麦克风权限。"].exists, "The denied microphone permission was not explained.")
        attachScreenshot(of: app, named: "microphone-permission-denied-feedback")
        permissionFailure.buttons["好"].tap()
        let retryMicrophone = app.buttons["insight.audio.record"]
        XCTAssertTrue(retryMicrophone.isEnabled)
        retryMicrophone.tap()
        XCTAssertTrue(permissionFailure.waitForExistence(timeout: 15), "A repeated permission failure became a silent microphone tap.")
        XCTAssertTrue(permissionFailure.staticTexts["未获得麦克风权限。"].exists)
        permissionFailure.buttons["好"].tap()
        XCTAssertTrue(app.buttons["新建聊天"].exists, "Recording did not open the editable chat screen.")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func openAssistantEntry(in app: XCUIApplication) {
        let analysisTab = app.tabBars.buttons["分析"]
        let didLaunch = analysisTab.waitForExistence(timeout: 30)
        if !didLaunch { attachScreenshot(of: app, named: "assistant-workspace-launch-failure") }
        XCTAssertTrue(didLaunch, "The isolated workspace did not launch: \(app.debugDescription)")
        analysisTab.tap()
        let entry = app.buttons["analysis-assistant-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
    }

    @MainActor
    private func composerField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "insight.composer.text").firstMatch
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
