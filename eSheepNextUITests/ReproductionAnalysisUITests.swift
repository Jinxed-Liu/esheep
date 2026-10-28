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
    func testEvidenceLambingDetailOpensAndReturns() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-reproduction", "--design-reproduction-evidence",
            "--design-role", "administrator", "--design-fixture-id", UUID().uuidString,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["繁殖依据与历史"].waitForExistence(timeout: 90))
        let record = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "产羔")).firstMatch
        reveal(record, in: app)
        record.tap()
        XCTAssertTrue(app.navigationBars["产羔详情"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "QA-001")).firstMatch.exists)
        screenshot(app, name: "reproduction-lambing-record-detail")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(app.navigationBars["繁殖依据与历史"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAllEvidenceKindsFromSheepProfileAndCorrectionCancellation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-reproduction", "--design-reproduction-evidence",
            "--design-reproduction-evidence-from-sheep", "--design-role", "administrator",
            "--design-fixture-id", UUID().uuidString, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let evidence = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@",
            "本轮依据与繁殖历史", "繁殖资料待核实")).firstMatch
        XCTAssertTrue(app.navigationBars["QA-001"].waitForExistence(timeout: 90))
        reveal(evidence, in: app)
        evidence.tap()
        XCTAssertTrue(app.navigationBars["繁殖依据与历史"].waitForExistence(timeout: 10))
        for kind in ["产羔", "孕检", "配种", "流产", "胎次确认"] {
            let detailTitle = kind == "产羔" ? "产羔详情" : "繁殖记录详情"
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", kind)).firstMatch
            reveal(row, in: app)
            let openedAt = Date()
            row.tap()
            XCTAssertTrue(app.navigationBars[detailTitle].waitForExistence(timeout: 10), kind)
            XCTAssertLessThan(Date().timeIntervalSince(openedAt), 10, "\(kind)详情打开过慢")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "QA-001")).firstMatch.exists)
            if kind == "产羔" || kind == "孕检" {
                let correct = app.buttons["修正记录"]
                reveal(correct, in: app)
                correct.tap()
                let title = kind == "产羔" ? "修正产羔记录" : "修正繁殖记录"
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
                app.navigationBars[title].descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", "取消")).firstMatch.tap()
                XCTAssertTrue(app.navigationBars[detailTitle].waitForExistence(timeout: 10))
            }
            if kind == "孕检" {
                // Verify live model/query updates still pass through the stable
                // navigation boundary. All mutations use the isolated fixture.
                app.buttons["撤销记录"].tap()
                XCTAssertTrue(app.buttons["恢复记录"].waitForExistence(timeout: 10))
                let back = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                back.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
                XCTAssertTrue(app.navigationBars["繁殖依据与历史"].waitForExistence(timeout: 10))
                let revoked = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "孕检", "已撤销")).firstMatch
                XCTAssertTrue(revoked.waitForExistence(timeout: 10))
                revoked.tap()
                app.buttons["恢复记录"].tap()
                XCTAssertTrue(app.buttons["修正记录"].waitForExistence(timeout: 10))
            }
            screenshot(app, name: "reproduction-evidence-" + kind)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            XCTAssertTrue(app.navigationBars["繁殖依据与历史"].waitForExistence(timeout: 10), kind)
        }
    }

    @MainActor
    func testEventHistoryLambingChildNavigationAndFilterRetention() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-reproduction", "--design-reproduction-history",
            "--design-role", "administrator", "--design-fixture-id", UUID().uuidString,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["事件记录"].waitForExistence(timeout: 30))
        let breeding = app.buttons["event-type-breeding"]
        XCTAssertTrue(breeding.waitForExistence(timeout: 10))
        breeding.tap()
        let eventRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "farm-event-"))
        XCTAssertTrue(eventRows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(eventRows.allElementsBoundByIndex.allSatisfy { $0.label.contains("配种") })
        app.buttons["event-type-lambing"].tap()
        let search = app.searchFields.firstMatch
        if !search.isHittable {
            let searchButton = app.buttons["搜索"].firstMatch
            if searchButton.isHittable { searchButton.tap() } else { app.swipeDown() }
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("QA-OLD")
        if app.keyboards.buttons["搜索"].exists { app.keyboards.buttons["搜索"].tap() }
        let row = eventRows.matching(NSPredicate(format: "label CONTAINS %@", "QA-001")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        screenshot(app, name: "history-lambing-filter-and-original-ear-tag")

        func back() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        }
        for index in 0..<3 {
            let openedAt = Date()
            row.tap()
            XCTAssertTrue(app.navigationBars["产羔详情"].waitForExistence(timeout: 10))
            XCTAssertLessThan(Date().timeIntervalSince(openedAt), 10, "产羔详情打开过慢")
            let live = app.buttons["lambing-child-QA-LIVE"]
            reveal(live, in: app)
            XCTAssertTrue(live.label.contains("QA-OLD"))
            let childOpenedAt = Date()
            live.tap()
            XCTAssertTrue(app.navigationBars["QA-LIVE"].waitForExistence(timeout: 10))
            XCTAssertLessThan(Date().timeIntervalSince(childOpenedAt), 10, "羔羊档案打开过慢")
            back()
            XCTAssertTrue(app.navigationBars["产羔详情"].waitForExistence(timeout: 10))
            let dead = app.buttons["lambing-child-QA-DEAD"]
            reveal(dead, in: app)
            XCTAssertTrue(dead.label.contains("活产"))
            XCTAssertTrue(dead.label.contains("死亡"))
            XCTAssertTrue(dead.label.contains("后续称重"))
            if index == 0 {
                screenshot(app, name: "lambing-children-current-and-birth-outcomes")
                dead.tap()
                XCTAssertTrue(app.navigationBars["QA-DEAD"].waitForExistence(timeout: 10))
                back()
                XCTAssertTrue(app.navigationBars["产羔详情"].waitForExistence(timeout: 10))
            }
            back()
            // With search still active, iOS can hide the navigation title.
            XCTAssertTrue(app.buttons["event-type-lambing"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["event-type-lambing"].isSelected)
            XCTAssertEqual(search.value as? String, "QA-OLD")
            XCTAssertTrue(row.waitForExistence(timeout: 10))
        }
        row.tap()
        let missing = app.staticTexts["另有 1 只羔羊缺少逐只明细。"]
        reveal(missing, in: app)
        XCTAssertFalse(app.buttons["lambing-child-QA-UNLINKED"].exists)
        let revoke = app.buttons["撤销记录"]
        reveal(revoke, in: app); revoke.tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("隔离回归验证")
        app.alerts.buttons["撤销"].tap()
        XCTAssertTrue(app.buttons["安全恢复产羔"].waitForExistence(timeout: 10))
        back()
        XCTAssertTrue(app.buttons["event-type-lambing"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["没有匹配的事件"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testEventTypePickerAndExportRetainLambingScope() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-reproduction", "--design-reproduction-history",
            "--design-role", "administrator", "--design-fixture-id", UUID().uuidString,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.navigationBars["事件记录"].waitForExistence(timeout: 30))
        screenshot(app, name: "event-type-bar-all")
        app.buttons["筛选事件"].tap()
        XCTAssertTrue(app.navigationBars["筛选事件"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "事件类型")).firstMatch.tap()
        let lambingOption = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "产羔", "event-type-lambing")).firstMatch
        XCTAssertTrue(lambingOption.waitForExistence(timeout: 10))
        screenshot(app, name: "event-types-grouped-picker")
        lambingOption.tap()
        app.navigationBars["筛选事件"].buttons["完成"].tap()
        XCTAssertTrue(app.buttons["event-type-lambing"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["event-type-lambing"].isSelected)
        XCTAssertFalse(app.buttons["移除产羔"].exists)
        screenshot(app, name: "event-type-bar-lambing")
        app.buttons["导出事件记录"].tap()
        XCTAssertTrue(app.navigationBars["导出事件记录"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "事件类型", "产羔")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "当前筛选结果")).firstMatch.exists)
        screenshot(app, name: "event-export-keeps-lambing-scope")
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
