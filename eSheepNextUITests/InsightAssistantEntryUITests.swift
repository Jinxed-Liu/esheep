import XCTest
import UIKit

final class InsightAssistantEntryUITests: XCTestCase {
    @MainActor
    func testKnownVoiceTimelineUsesASingleRowAndPreservesTheUnsentDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-voice-waveform",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["design.audio.fixture.notice"].waitForExistence(timeout: 30))
        let input = composerField(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let originalDraft = input.value as? String
        XCTAssertEqual(originalDraft, "录音前的原始草稿")
        input.tap()
        let surface = app.descendants(matching: .any).matching(identifier: "insight.composer.surface").firstMatch
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists && keyboard.frame.height > 100 &&
                self.composerHasSideMargins(12, in: app) &&
                surface.frame.maxY <= keyboard.frame.minY + 2
        }, object: app)
        let focusedResult = XCTWaiter.wait(for: [focused], timeout: 10)
        if focusedResult != .completed {
            attachScreenshot(of: app, named: "voice-fixture-focused-composer-geometry-failure")
        }
        XCTAssertEqual(focusedResult, .completed)

        app.buttons["design.audio.fixture.begin"].tap()
        let bar = app.descendants(matching: .any).matching(identifier: "insight.audio.bar").firstMatch
        let waveform = app.descendants(matching: .any).matching(identifier: "insight.audio.waveform").firstMatch
        let cancel = app.buttons["insight.audio.cancel"]
        let stop = app.buttons["insight.audio.stop"]
        let send = app.buttons["insight.composer.send"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let sixSeconds = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0:06"), object: bar)
        XCTAssertEqual(XCTWaiter.wait(for: [sixSeconds], timeout: 5), .completed)
        XCTAssertEqual(app.staticTexts["design.audio.fixture.state"].label, "样本数 60，发送次数 0")
        attachScreenshot(of: app, named: "voice-time-sample-fixture-recording-six-seconds-not-microphone-audio")
        attachVoiceGeometry(in: app, named: "voice-time-sample-fixture-six-seconds-ax-geometry")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "insight.audio.bar").count, 1)
        // A SwiftUI children:.contain AX element can tightly enclose its
        // 44pt buttons even though the visible capsule is 48pt. Keep the
        // visual 48pt requirement in the original PNG review, and do not
        // mistake an AX union for the SwiftUI layout frame.
        if abs(surface.frame.height - 48) <= 1 {
            XCTAssertEqual(surface.frame.height, 48, accuracy: 1)
        } else {
            XCTAssertEqual(surface.frame.height, 44, accuracy: 1,
                           "A composed AX surface must tightly contain the 44pt controls; review its original PNG for 48pt visual height.")
        }
        XCTAssertEqual(bar.frame.height, 44, accuracy: 1, "The accessible recording container must retain its 44pt controls.")
        XCTAssertTrue(waveform.exists)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(stop.isHittable)
        for control in [cancel, stop, send] {
            XCTAssertEqual(control.frame.width, 44, accuracy: 1)
            XCTAssertEqual(control.frame.height, 44, accuracy: 1)
        }
        XCTAssertEqual(waveform.frame.midY, bar.frame.midY, accuracy: 1)
        XCTAssertEqual(cancel.frame.midY, bar.frame.midY, accuracy: 1)
        XCTAssertEqual(stop.frame.midY, bar.frame.midY, accuracy: 1)
        XCTAssertEqual(send.frame.midY, bar.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(waveform.frame.width, 100)
        XCTAssertGreaterThanOrEqual(waveform.frame.minX, cancel.frame.maxX)
        XCTAssertLessThanOrEqual(waveform.frame.maxX, stop.frame.minX)
        XCTAssertLessThanOrEqual(stop.frame.maxX, send.frame.minX)
        XCTAssertFalse(app.buttons["insight.attachment.menu"].exists)
        let firstWaveformFrame = waveform.frame

        app.buttons["design.audio.fixture.advance"].tap()
        let sevenSeconds = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0:07"), object: bar)
        XCTAssertEqual(XCTWaiter.wait(for: [sevenSeconds], timeout: 5), .completed)
        XCTAssertEqual(app.staticTexts["design.audio.fixture.state"].label, "样本数 70，发送次数 0")
        XCTAssertEqual(waveform.frame.minX, firstWaveformFrame.minX, accuracy: 1)
        XCTAssertEqual(waveform.frame.width, firstWaveformFrame.width, accuracy: 1)
        // Inspect the original pair of PNGs to confirm the retained peak moved
        // ten fixed time slots left. AX bounds alone cannot prove pixel motion.
        attachScreenshot(of: app, named: "voice-time-sample-fixture-recording-seven-seconds-peak-shift")

        stop.tap()
        let playback = app.buttons["insight.audio.playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        XCTAssertFalse(stop.exists)
        XCTAssertEqual(bar.label, "待发送语音")
        XCTAssertEqual(bar.value as? String, "0:07")
        XCTAssertEqual(bar.frame.height, 44, accuracy: 1)
        XCTAssertEqual(app.staticTexts["design.audio.fixture.state"].label, "样本数 70，发送次数 0",
                       "Stopping must retain pending audio rather than send it automatically.")
        attachScreenshot(of: app, named: "voice-time-sample-fixture-pending-unsent-single-row")

        cancel.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: bar)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, originalDraft)
        XCTAssertEqual(app.staticTexts["design.audio.fixture.state"].label, "样本数 0，发送次数 0")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        attachScreenshot(of: app, named: "voice-time-sample-fixture-remove-pending-restores-original-draft")

        app.buttons["design.audio.fixture.begin"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertEqual(bar.value as? String, "0:06", "A new recording must not inherit the old seven-second history.")
        cancel.tap()
        // Synchronize with the restored visible state and a fresh query. A
        // reused bar handle can retain its previous snapshot during transition.
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let restoredInput = self.composerField(in: app)
            let currentBar = app.descendants(matching: .any)
                .matching(identifier: "insight.audio.bar").firstMatch
            return app.staticTexts["design.audio.fixture.state"].label == "样本数 0，发送次数 0" &&
                restoredInput.exists && restoredInput.value as? String == originalDraft &&
                !currentBar.exists
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 10), .completed,
                       "Cancelling must restore the original draft with zero samples, no send, and no audio bar.")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, originalDraft)
        XCTAssertEqual(app.staticTexts["design.audio.fixture.state"].label, "样本数 0，发送次数 0")
        attachScreenshot(of: app, named: "voice-time-sample-fixture-cancel-recording-restores-original-draft")

        app.buttons["design.audio.fixture.begin-origin"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertEqual(bar.value as? String, "0:01")
        XCTAssertEqual(app.staticTexts["design.audio.fixture.state"].label, "样本数 10，发送次数 0")
        // The original PNG must distinguish the empty pre-recording portion
        // from the actual silent samples, which are rendered as small dots.
        attachScreenshot(of: app, named: "voice-time-sample-fixture-one-second-origin-gap-and-silence")
        cancel.tap()
        let originCancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let restoredInput = self.composerField(in: app)
            return app.staticTexts["design.audio.fixture.state"].label == "样本数 0，发送次数 0" &&
                restoredInput.exists && restoredInput.value as? String == originalDraft &&
                !app.descendants(matching: .any).matching(identifier: "insight.audio.bar").firstMatch.exists
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [originCancelled], timeout: 10), .completed)
        XCTAssertEqual(input.value as? String, originalDraft)
        XCTAssertEqual(app.staticTexts["design.audio.fixture.state"].label, "样本数 0，发送次数 0")
    }

    @MainActor
    func testFloatingAttachmentPanelPreservesTheDraftAndPresentsTheSelectedAction() {
        continueAfterFailure = false
        let fixtureID = UUID().uuidString
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-ready", "--design-role", "administrator",
            "--design-fixture-id", fixtureID,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openAssistantEntry(in: app)
        let history = app.buttons["入口回归历史聊天 1"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        let removeMode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除")).firstMatch
        if removeMode.exists { removeMode.tap() }
        let input = composerField(in: app)
        let surface = app.descendants(matching: .any).matching(identifier: "insight.composer.surface").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.composerHasSideMargins(38, in: app)
        }, object: surface)
        let compactResult = XCTWaiter.wait(for: [compact], timeout: 5)
        attachScreenshot(of: app, named: "attachment-empty-unfocused-compact-reference-width")
        XCTAssertEqual(compactResult, .completed,
                       "An empty unfocused composer must retain 38pt side margins.")
        input.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return self.composerHasSideMargins(12, in: app) &&
                keyboard.exists && keyboard.frame.height > 100 && surface.frame.maxY <= keyboard.frame.minY + 2
        }, object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 10), .completed,
                       "Focusing the same editor must widen the composer to 12pt side margins.")
        attachScreenshot(of: app, named: "attachment-empty-focused-reference-controls")
        let draft = "附件菜单草稿 \(UUID().uuidString.prefix(8))"
        input.typeText(draft)
        let editableDraft = input.value as? String ?? ""
        XCTAssertTrue(editableDraft.contains(draft))
        let add = app.buttons["insight.attachment.menu"]
        add.tap()
        let panel = app.descendants(matching: .any).matching(identifier: "insight.attachment.panel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let actions = ["camera", "photos", "files", "plan", "goal"].map {
            app.buttons["insight.attachment.\($0)"]
        }
        attachScreenshot(of: app, named: "attachment-floating-panel-open-before-action-checks")
        for action in actions {
            let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: action)
            XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed,
                           "\(action.identifier) is unreachable at \(action.frame); panel \(panel.frame).")
            XCTAssertGreaterThanOrEqual(action.frame.height, 60, "The attachment panel shrank back to compact rows.")
            XCTAssertGreaterThan(action.frame.width, 230)
        }
        attachScreenshot(of: app, named: "attachment-floating-glass-panel-five-real-actions")
        // A tap in the clear transcript dismisses the floating panel without
        // invoking any action or changing the editable draft.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.25)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, editableDraft)
        let insertedText = " 继续编辑\(UUID().uuidString.prefix(8))"
        input.typeText(insertedText)
        let editedDraft = input.value as? String ?? ""
        // The original insertion point can be inside a persisted draft.
        // Check preservation without moving the user's caret to the end.
        XCTAssertEqual(editedDraft.replacingOccurrences(of: insertedText, with: ""), editableDraft)
        XCTAssertEqual(editedDraft.count, editableDraft.count + insertedText.count)

        add.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.buttons["insight.attachment.plan"].tap()
        let plan = app.buttons["移除方案模式，下次发送使用普通对话"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5), "The mode handler was lost during panel dismissal.")
        XCTAssertFalse(panel.exists)
        XCTAssertEqual(input.value as? String, editedDraft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let gauge = app.buttons["insight.reasoning.settings"]
        XCTAssertEqual(plan.frame.midY, gauge.frame.midY, accuracy: 1,
                       "The selected plan must remain in the bottom composer toolbar.")
        XCTAssertLessThanOrEqual(plan.frame.maxX, gauge.frame.minX,
                                 "The plan capsule must not overlap the analysis control.")
        attachScreenshot(of: app, named: "attachment-selected-plan-inline-bottom-toolbar")
        plan.tap()
        attachScreenshot(of: app, named: "attachment-floating-panel-dismissed-original-composer-controls")

        add.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.buttons["insight.attachment.files"].tap()
        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The file picker was not presented after the floating panel finished dismissing.")
        XCTAssertFalse(panel.exists)
        attachScreenshot(of: app, named: "attachment-file-picker-after-floating-panel-dismissal")
        cancel.tap()
        XCTAssertEqual(input.value as? String, editedDraft)
        XCTAssertTrue(app.buttons["BackButton"].exists)

        // A floating window must be removed when its own scene backgrounds;
        // returning must expose the same editor rather than an orphan panel.
        add.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        let removedOnBackground = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: panel
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removedOnBackground], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, editedDraft)
        XCTAssertTrue(app.buttons["BackButton"].isHittable)
        attachScreenshot(of: app, named: "attachment-floating-panel-removed-after-scene-background")
    }

    @MainActor
    func testFocusedAnalysisSelectorUsesThreeLevelsAndPreservesTheDraftAndKeyboard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-ready", "--design-role", "administrator",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openAssistantEntry(in: app)
        let history = app.buttons["入口回归历史聊天 1"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        let draft = "仪表盘草稿 \(UUID().uuidString.prefix(8))\n保留第二行"
        let input = composerField(in: app)
        input.tap()
        input.typeText(draft)
        // This persistent acceptance chat can already have a saved draft from
        // an earlier run. Verify preservation of the actual editable content.
        let editableDraft = input.value as? String ?? ""
        XCTAssertTrue(editableDraft.contains(draft))
        let settings = app.buttons["insight.reasoning.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let originalValue = settings.value as? String ?? "中分析强度"
        settings.tap()
        let selector = app.descendants(matching: .any).matching(identifier: "insight.analysis.selector").firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        let slider = app.descendants(matching: .any).matching(identifier: "insight.analysis.slider").firstMatch
        for (name, title) in [("low", "低"), ("medium", "中"), ("high", "高")] {
            let level = app.buttons["insight.analysis.level.\(name)"]
            XCTAssertTrue(level.exists)
            level.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: slider)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
            attachScreenshot(of: app, named: "focused-analysis-selected-\(name)-partial-fill")
            app.buttons["insight.analysis.dismiss"].coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.25)).tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: selector)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
            XCTAssertTrue((settings.value as? String ?? "").hasPrefix(title))
            attachScreenshot(of: app, named: "focused-analysis-\(name)-gauge-reference-pose")
            if name != "high" {
                settings.tap()
                XCTAssertTrue(selector.waitForExistence(timeout: 5))
            }
        }
        settings.tap()
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        app.buttons["insight.analysis.level.medium"].tap()
        app.buttons["insight.analysis.dismiss"].coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.25)).tap()
        let firstClose = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: selector)
        XCTAssertEqual(XCTWaiter.wait(for: [firstClose], timeout: 5), .completed)
        XCTAssertTrue((settings.value as? String ?? "").hasPrefix("中"), "The selected effort did not update the original gauge.")
        attachScreenshot(of: app, named: "focused-analysis-medium-gauge-and-original-editor")
        settings.tap()
        XCTAssertTrue(selector.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.value as? String, "中", "Reopening the gauge did not preserve the selected effort.")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        let dragged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "高"), object: slider)
        XCTAssertEqual(XCTWaiter.wait(for: [dragged], timeout: 5), .completed)
        XCTAssertTrue(selector.exists, "Dragging the effort thumb navigated away from the focused selector.")
        attachScreenshot(of: app, named: "focused-analysis-selector-three-real-levels")
        app.buttons["insight.analysis.advanced"].tap()
        XCTAssertTrue(app.navigationBars["分析设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(selector.waitForExistence(timeout: 5), "Closing advanced settings discarded the focused selector.")
        let restoredLevel = originalValue.hasPrefix("低") ? "low" : (originalValue.hasPrefix("高") ? "high" : "medium")
        app.buttons["insight.analysis.level.\(restoredLevel)"].tap()
        // The background is a real dismiss control; use a point outside the
        // floating selector instead of its centre behind the model button.
        app.buttons["insight.analysis.dismiss"].coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.25)).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: selector)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, editableDraft, "Selecting an effort changed the original multiline draft.")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Opening or closing the selector lost editor focus.")
        let editSuffix = " 继续编辑\(UUID().uuidString.prefix(8))"
        input.typeText(editSuffix)
        let editedDraft = input.value as? String ?? ""
        XCTAssertEqual(editedDraft.replacingOccurrences(of: editSuffix, with: ""), editableDraft)
        XCTAssertEqual(editedDraft.count, editableDraft.count + editSuffix.count)
        // Checking keyboard existence alone can catch the outgoing sheet's
        // keyboard during its dismissal animation. Require the editor to
        // settle above a full keyboard after continuing to type.
        let keyboardRestored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists && keyboard.frame.height > 100 &&
                input.frame.maxY <= keyboard.frame.minY + 2
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardRestored], timeout: 10), .completed,
                       "The editor did not settle above the restored keyboard after advanced settings closed.")
        XCTAssertEqual(settings.value as? String, originalValue)
        XCTAssertTrue(app.buttons["BackButton"].exists, "Dragging or tapping the dial triggered a content pop.")
        attachScreenshot(of: app, named: "focused-analysis-selector-closed-draft-and-keyboard-preserved")

        let contextUsage = app.buttons["insight.context.usage"]
        XCTAssertTrue(contextUsage.exists)
        let usagePercentage = contextUsage.label.components(separatedBy: " ").last ?? ""
        XCTAssertTrue(usagePercentage.hasSuffix("%"))
        contextUsage.tap()
        let contextPanel = app.descendants(matching: .any).matching(identifier: "insight.context.panel").firstMatch
        let contextProgress = app.descendants(matching: .any).matching(identifier: "insight.context.progress").firstMatch
        XCTAssertTrue(contextPanel.waitForExistence(timeout: 5))
        XCTAssertTrue(contextProgress.exists)
        XCTAssertTrue((contextProgress.value as? String ?? "").contains(usagePercentage),
                      "The expanded context meter must report the same real usage as the original ring.")
        XCTAssertFalse(selector.exists, "Context and analysis must not leave overlapping floating panels.")
        XCTAssertLessThanOrEqual(contextPanel.frame.maxY, app.keyboards.firstMatch.frame.minY + 2,
                                 "Context usage must expand at the original composer above the keyboard.")
        attachScreenshot(of: app, named: "focused-context-real-\(usagePercentage)-leading-capsule-fill")
        app.buttons["insight.context.dismiss"].coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.25)).tap()
        let contextClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: contextPanel)
        XCTAssertEqual(XCTWaiter.wait(for: [contextClosed], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, editedDraft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        attachScreenshot(of: app, named: "focused-context-closed-original-draft-and-toolbar")
        contextUsage.tap()
        XCTAssertTrue(contextPanel.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        let contextRemovedOnBackground = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: contextPanel
        )
        XCTAssertEqual(XCTWaiter.wait(for: [contextRemovedOnBackground], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, editedDraft)
        XCTAssertTrue(app.buttons["BackButton"].isHittable)
    }

    @MainActor
    func testLeadingEdgeSwipeReturnsToListAndKeepsTheReplyRunning() {
        assertNativeSwipeKeepsTheReplyRunning(startingAtEdge: true)
    }

    @MainActor
    func testContentSwipeReturnsToListAndKeepsTheReplyRunning() {
        assertNativeSwipeKeepsTheReplyRunning(startingAtEdge: false)
    }

    @MainActor
    private func assertNativeSwipeKeepsTheReplyRunning(startingAtEdge: Bool) {
        continueAfterFailure = false
        let firstLine = "\(startingAtEdge ? "左缘" : "正文")侧滑返回验收 \(UUID().uuidString.prefix(8))"
        let message = firstLine + "\n返回列表后继续等待本次回复"
        let response = "离线发送验收：已收到两行输入。"
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-ready", "--design-insight-offline-send",
            "--design-insight-edge-swipe-response",
            "--design-insight-expected-message-base64", Data(message.utf8).base64EncodedString(),
            "--design-role", "administrator",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openAssistantEntry(in: app)
        let composer = composerField(in: app)
        composer.tap()
        composer.typeText(message)
        let send = app.buttons["insight.composer.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        send.tap()
        XCTAssertTrue(app.buttons["insight.composer.stop"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[response].exists)

        // Use UIKit's real edge or full-content interactive pop recognizer;
        // do not tap the custom back button or call a navigation action.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: startingAtEdge ? 0.005 : 0.35, dy: 0.45))
        // Starting within the page needs more than a half-width displacement
        // to complete UIKit's interactive transition rather than cancel it.
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: startingAtEdge ? 0.85 : 0.98, dy: 0.45))
        edge.press(forDuration: 0.05, thenDragTo: destination, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["聊天菜单"].waitForExistence(timeout: 5), "The native \(startingAtEdge ? "edge" : "content") return did not complete.")
        XCTAssertTrue(app.activityIndicators["处理中"].exists, "Returning to the list interrupted or completed the delayed response prematurely.")
        attachScreenshot(of: app, named: "\(startingAtEdge ? "edge" : "content")-swipe-list-reply-running")

        let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", firstLine)).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.tap()
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[response].waitForExistence(timeout: 30), "The original response did not finish after edge return and reentry.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", message)).count, 1, "Reentry duplicated the original request.")
        XCTAssertFalse(app.buttons["insight.composer.stop"].exists)
        let identity = app.descendants(matching: .any).matching(identifier: "insight.conversation.identity").firstMatch
        XCTAssertGreaterThanOrEqual(identity.frame.width, 160, "The swipe-back support compressed the custom title.")
        attachScreenshot(of: app, named: "\(startingAtEdge ? "edge" : "content")-swipe-reentered-reply-completed")
    }

    @MainActor
    func testDelayedLongReviewedReplyAppearsOnTheCurrentPage() {
        continueAfterFailure = false
        let message = "检查圈舍查询与长回复布局 \(UUID().uuidString.prefix(8))\n保持当前页面等待完整答复"
        let finalParagraph = "原页长回复验收完成。"
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-ready", "--design-insight-offline-send",
            "--design-insight-long-response",
            "--design-insight-expected-message-base64", Data(message.utf8).base64EncodedString(),
            "--design-role", "administrator",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openAssistantEntry(in: app)
        let composer = composerField(in: app)
        composer.tap()
        composer.typeText(message)
        let send = app.buttons["insight.composer.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        send.tap()
        XCTAssertTrue(app.buttons["insight.composer.stop"].waitForExistence(timeout: 5))
        let process = app.buttons["正在思考，查看处理步骤"]
        XCTAssertTrue(process.waitForExistence(timeout: 5), "The running response did not publish a public process on its current page.")
        process.tap()
        XCTAssertTrue(app.staticTexts["核对圈舍"].waitForExistence(timeout: 5), "The actual read tool did not appear in the current message's process.")
        XCTAssertFalse(app.staticTexts[finalParagraph].exists, "An unreviewed candidate was displayed as the final answer.")
        attachScreenshot(of: app, named: "long-reply-current-page-running")

        // Do not navigate, activate the app, or swipe before these assertions.
        // Existence checks publication/rendering; hittability separately checks
        // that the growing message was laid out and scrolled above the input.
        let finalText = app.staticTexts[finalParagraph]
        XCTAssertTrue(finalText.waitForExistence(timeout: 30), "The completed long answer did not render on the original page.")
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: finalText)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed, "The answer exists but remains outside the readable viewport until reentry.")
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["insight.composer.stop"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed)
        attachScreenshot(of: app, named: "long-reply-current-page-completed-visible")
        // LazyVStack may remove an offscreen user bubble from accessibility
        // after the long answer scrolls into view. Check the visible answer's
        // identity here; the background test covers duplicate user requests.
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", finalParagraph)).count, 1)
        let input = composerField(in: app)
        XCTAssertLessThanOrEqual(finalText.frame.maxY, input.frame.minY, "The input area covers the completed answer.")
        let transcript = app.scrollViews["insight.conversation.transcript"]
        XCTAssertTrue(transcript.exists)
        XCTAssertEqual(transcript.frame.minY, app.frame.minY, accuracy: 1, "The transcript viewport was cut below the top floating bar.")
        XCTAssertEqual(transcript.frame.maxY, app.frame.maxY, accuracy: 1, "The transcript viewport was cut above the input floating bar.")
        attachScreenshot(of: app, named: "long-reply-fullscreen-transcript-viewport")

        // Review the lower blur with real text moving underneath it, rather
        // than judging a material over the blank padding after the last row.
        // This attachment is visual evidence; it does not assert blur quality.
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.42))
            .press(forDuration: 0.05, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.62)))
        attachScreenshot(of: app, named: "long-reply-text-under-bottom-gradient")
        transcript.swipeUp()
        let returnedToEnd = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: finalText)
        XCTAssertEqual(XCTWaiter.wait(for: [returnedToEnd], timeout: 5), .completed)

        let horizontalTable = app.scrollViews["insight.markdown.horizontal-table"].firstMatch
        XCTAssertTrue(horizontalTable.isHittable, "The wide table fixture is outside the readable viewport.")
        horizontalTable.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: horizontalTable.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(app.buttons["BackButton"].exists, "A horizontal table gesture unexpectedly returned to the conversation list.")

        input.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        input.typeText("输入控件手势验收\n第二行\n第三行")
        let keyboardSafe = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            finalText.isHittable && finalText.frame.maxY <= input.frame.minY && input.frame.maxY <= keyboard.frame.minY
        }, object: input)
        let safeResult = XCTWaiter.wait(for: [keyboardSafe], timeout: 10)
        attachScreenshot(of: app, named: "long-reply-keyboard-and-input-safe")
        XCTAssertEqual(safeResult, .completed, "Keyboard avoidance or the measured input height covered the last paragraph.")
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: input.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(app.buttons["BackButton"].exists, "Editing the input unexpectedly triggered a content pop.")
    }

    @MainActor
    func testDenseReviewedReplyScrollsUnderTheComposerInBothFocusStates() {
        continueAfterFailure = false
        let message = "底部正文渐变验收 \(UUID().uuidString.prefix(8))\n保持当前页面检查滚动正文"
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-ready", "--design-insight-offline-send",
            "--design-insight-long-response",
            "--design-insight-expected-message-base64", Data(message.utf8).base64EncodedString(),
            "--design-role", "administrator",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openAssistantEntry(in: app)
        let input = composerField(in: app)
        input.tap()
        input.typeText(message)
        let send = app.buttons["insight.composer.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        send.tap()

        // Use the existing native read, candidate, review and completion path;
        // the final answer is not injected as a pre-rendered screenshot fixture.
        let finalText = app.staticTexts["原页长回复验收完成。"]
        XCTAssertTrue(finalText.waitForExistence(timeout: 30))
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            finalText.isHittable && !app.buttons["insight.composer.stop"].exists
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 10), .completed)
        let surface = app.descendants(matching: .any).matching(identifier: "insight.composer.surface").firstMatch
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists && self.composerHasSideMargins(38, in: app)
        }, object: app)
        let compactResult = XCTWaiter.wait(for: [compact], timeout: 10)
        if compactResult != .completed {
            attachScreenshot(of: app, named: "dense-reply-unfocused-composer-geometry-failure")
        }
        XCTAssertEqual(compactResult, .completed,
                       "The completed response must leave an empty unfocused composer with 38pt side margins.")
        let paragraph = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "这次隔离样本覆盖真实控制器"
        )).firstMatch
        XCTAssertTrue(paragraph.exists, "The reviewed answer did not contain the existing multiline body paragraph.")
        let transcript = app.scrollViews["insight.conversation.transcript"]
        XCTAssertTrue(transcript.exists)
        XCTAssertTrue(positionReplyParagraphBehindComposer(paragraph, surface: surface, transcript: transcript,
                                                          in: app, keepingKeyboard: false),
                      "The unfocused screenshot would show blank footer padding instead of real text under the composer.")
        attachScreenshot(of: app, named: "dense-reply-unfocused-narrow-real-body-under-bottom-fade")

        input.tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists && keyboard.frame.height > 100 &&
                self.composerHasSideMargins(12, in: app) &&
                surface.frame.maxY <= keyboard.frame.minY + 2
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 10), .completed,
                       "The same empty editor did not settle above the keyboard with 12pt side margins.")
        XCTAssertTrue(positionReplyParagraphBehindComposer(paragraph, surface: surface, transcript: transcript,
                                                          in: app, keepingKeyboard: true),
                      "The focused screenshot must retain the keyboard and real multiline text behind the composer.")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertLessThanOrEqual(surface.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        attachScreenshot(of: app, named: "dense-reply-focused-keyboard-real-body-under-bottom-fade")
        XCTAssertTrue(["", "信息", "跟进"].contains(input.value as? String ?? ""),
                      "Reading or focusing the completed answer restored the submitted request as a draft.")
        XCTAssertTrue(app.buttons["BackButton"].exists)
    }

    @MainActor
    func testBriefBackgroundSwitchPreservesTheRunningReply() {
        continueAfterFailure = false
        let message = "分析第八批六个舍的日增重 \(UUID().uuidString.prefix(8))\n短暂切后台验收"
        let response = "离线发送验收：已收到两行输入。"
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-insight-ready", "--design-insight-offline-send",
            "--design-insight-slow-response",
            "--design-insight-expected-message-base64", Data(message.utf8).base64EncodedString(),
            "--design-role", "administrator",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        openAssistantEntry(in: app)
        let composer = composerField(in: app)
        composer.tap()
        composer.typeText(message)
        let send = app.buttons["insight.composer.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        send.tap()
        XCTAssertTrue(app.buttons["insight.composer.stop"].waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "reply-running-before-background")
        XCTAssertFalse(app.staticTexts[response].exists, "The delayed response completed before the background transition was exercised.")

        // Exercise the real SwiftUI scene lifecycle with the existing isolated
        // delayed responder. This fixture makes no provider or farm-data claim.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts[response].waitForExistence(timeout: 30), "A brief background switch abandoned the running response.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", message)).count, 1, "The original request was duplicated after returning.")
        XCTAssertFalse(app.staticTexts["登录状态已变更，请重新检查后继续。"].exists)
        XCTAssertFalse(app.buttons["insight.composer.stop"].exists)
        attachScreenshot(of: app, named: "reply-completed-after-background")
    }

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
        let identity = app.descendants(matching: .any).matching(identifier: "insight.conversation.identity").firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 5), "The conversation title is missing.")
        XCTAssertGreaterThanOrEqual(identity.frame.width, 160, "The conversation title was compressed into a toolbar button slot.")
        let cleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value IN %@", ["", "信息", "跟进"]), object: composerField(in: app)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed, "A sent draft remained in the composer.")
        XCTAssertNotEqual(composerField(in: app).value as? String, message, "The submitted message returned to the draft.")
        XCTAssertFalse(app.buttons["insight.composer.stop"].exists, "The completed response still appears to be generating.")
        attachScreenshot(of: app, named: "composer-after-send")

        let listBack = app.buttons["BackButton"]
        XCTAssertTrue(listBack.waitForExistence(timeout: 10))
        listBack.tap()
        XCTAssertTrue(app.buttons["聊天菜单"].waitForExistence(timeout: 15))
        XCTAssertEqual(composerField(in: app).value as? String ?? "", emptyValue, "The submitted list draft was not consumed.")
        attachScreenshot(of: app, named: "composer-list-draft-cleared-after-send")

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
        let historyBack = app.buttons["BackButton"]
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
    private func composerHasSideMargins(_ margin: CGFloat, in app: XCUIApplication) -> Bool {
        // SwiftUI children:.contain can expose the union of its controls,
        // excluding the surface's 2pt inner padding on each side. Measure the
        // named controls against the main window instead of treating that AX
        // union as the visible capsule's layout frame. Refresh every query as
        // focus and layout settle, while retaining exact margins and targets.
        let window = app.windows.firstMatch
        let leading = app.buttons["insight.attachment.menu"]
        let trailing = app.buttons["insight.composer.send"]
        guard window.exists, leading.exists, trailing.exists else { return false }
        let windowFrame = window.frame
        let leadingFrame = leading.frame
        let trailingFrame = trailing.frame
        let innerPadding: CGFloat = 2
        return !windowFrame.isEmpty &&
            abs(leadingFrame.minX - (windowFrame.minX + margin + innerPadding)) < 1 &&
            abs(trailingFrame.maxX - (windowFrame.maxX - margin - innerPadding)) < 1 &&
            abs(leadingFrame.width - 44) < 1 && abs(leadingFrame.height - 44) < 1 &&
            abs(trailingFrame.width - 44) < 1 && abs(trailingFrame.height - 44) < 1 &&
            abs(leadingFrame.midY - trailingFrame.midY) < 1 &&
            leadingFrame.maxX <= trailingFrame.minX
    }

    @MainActor
    private func positionReplyParagraphBehindComposer(_ paragraph: XCUIElement, surface: XCUIElement,
                                                     transcript: XCUIElement, in app: XCUIApplication,
                                                     keepingKeyboard: Bool) -> Bool {
        // Move actual transcript text through the material with bounded native
        // scroll gestures. The AX geometry proves that the screenshots contain
        // body text both above and behind the surface; blur quality still needs
        // independent review of the original attached PNGs.
        for _ in 0..<8 {
            if keepingKeyboard {
                let keyboard = app.keyboards.firstMatch
                let keyboardReady = keyboard.exists && keyboard.frame.height > 100 &&
                    composerHasSideMargins(12, in: app) &&
                    surface.frame.maxY <= keyboard.frame.minY + 2
                if !keyboardReady {
                    // Interactive transcript scrolling can normally dismiss
                    // the keyboard. Restore actual focus, then remeasure both
                    // surfaces; dismissal alone is not a product failure.
                    composerField(in: app).tap()
                    let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        let keyboard = app.keyboards.firstMatch
                        return keyboard.exists && keyboard.frame.height > 100 &&
                            self.composerHasSideMargins(12, in: app) &&
                            surface.frame.maxY <= keyboard.frame.minY + 2
                    }, object: app)
                    if XCTWaiter.wait(for: [restored], timeout: 5) != .completed {
                        attachScreenshot(of: app, named: "dense-reply-keyboard-refocus-did-not-settle")
                        return false
                    }
                }
            }
            let body = paragraph.frame
            let edge = surface.frame.minY
            if body.width > 150 && body.height > 60 &&
                body.minY <= edge - 20 && body.maxY >= edge + 20 {
                return true
            }
            let delta = min(100, max(-100, (edge - 40) - body.minY))
            let startY = max(160, min(300, edge - 160))
            let start = transcript.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: transcript.frame.width * 0.90, dy: startY - transcript.frame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: delta))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        attachScreenshot(of: app, named: "dense-reply-scroll-position-not-established-\(keepingKeyboard ? "focused" : "unfocused")")
        return false
    }

    @MainActor
    private func attachVoiceGeometry(in app: XCUIApplication, named name: String) {
        let identifiers = [
            "insight.composer.surface", "insight.audio.bar", "insight.audio.waveform",
            "insight.audio.cancel", "insight.audio.stop", "insight.composer.send",
        ]
        let elements: [[String: Any]] = identifiers.map { identifier in
            let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            var record: [String: Any] = ["identifier": identifier, "exists": element.exists]
            if element.exists {
                let frame = element.frame
                record["frame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width,
                                   "height": frame.height, "centerY": frame.midY]
                record["label"] = element.label
                record["value"] = element.value as? String
            }
            return record
        }
        let payload: [String: Any] = [
            "kind": "XCTest accessibility frames, not a SwiftUI layout probe",
            "fixture": "Known time samples; no microphone recording",
            "visualDesignHeightPoints": 48,
            "controlTouchSizePoints": 44,
            "elements": elements,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Unable to attach actual voice AX geometry: \(error)")
        }
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
