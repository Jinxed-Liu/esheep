import XCTest

final class FarmSearchUITests: XCTestCase {
    @MainActor private func launch(query: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-search", "--design-reproduction",
            "--design-role", "administrator", "--design-fixture-id", UUID().uuidString,
            "--design-search-query", query, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        // Fresh simulators can show the system keyboard's first-use tutorial.
        let keyboardContinue = app.buttons["Continue"]
        if keyboardContinue.exists { keyboardContinue.tap() }
        if query.isEmpty {
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 90))
        } else {
            XCTAssertTrue(app.buttons["farm-search-category-all"].waitForExistence(timeout: 90))
        }
        return app
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func back(_ app: XCUIApplication) {
        let sideBack = app.buttons["BackButton"]
        if sideBack.exists { sideBack.tap() }
        else {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        }
        XCTAssertTrue(app.buttons["farm-search-category-all"].waitForExistence(timeout: 15))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func scrollAboveSearchField(_ element: XCUIElement, in app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        if !app.keyboards.firstMatch.exists { search.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if element.exists && element.isHittable && element.frame.maxY < search.frame.minY { break }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.maxX - 30, dy: search.frame.minY - 90))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.maxX - 30, dy: 150)))
        }
        capture(app, "keyboard-scroll-end")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Verify scrolling while the keyboard stays open")
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        XCTAssertLessThan(element.frame.maxY, search.frame.minY, "The complete last action must clear the floating search field")
    }

    @MainActor func testCategoryBarUsesScreenWidthAndLastResultClearsKeyboard() {
        let app = launch(query: "青年母羊舍")
        XCTAssertTrue(app.buttons["farm-search-pen-青年母羊舍"].waitForExistence(timeout: 30))
        let bar = app.scrollViews["farm-search-category-bar"]
        XCTAssertTrue(bar.exists)
        XCTAssertLessThanOrEqual(bar.frame.minX, 1)
        XCTAssertGreaterThanOrEqual(bar.frame.maxX, app.frame.maxX - 1)
        XCTAssertLessThan(app.buttons["farm-search-category-all"].frame.minY, 110)
        bar.swipeLeft()
        let events = app.buttons["farm-search-category-events"]
        XCTAssertTrue(events.isHittable)
        XCTAssertLessThanOrEqual(events.frame.maxX, app.frame.maxX)
        capture(app, "search-full-width-categories")
        let allEvents = app.buttons["farm-search-all-events"]
        scrollAboveSearchField(allEvents, in: app)
        capture(app, "search-last-result-above-keyboard")
        allEvents.tap()
        XCTAssertTrue(app.buttons["farm-search-event-filters"].waitForExistence(timeout: 10))
    }

    @MainActor func testDiscoveryOmitsExplanationAndLastSuggestionClearsKeyboard() {
        let app = launch(query: "")
        XCTAssertFalse(app.staticTexts["搜索当前牧场的羊只、羊舍和事件。"].exists)
        XCTAssertFalse(app.staticTexts["支持耳号、旧耳号、品种、羊舍名称、事件类型、日期和备注。"].exists)
        let feed = app.buttons["投喂"]
        scrollAboveSearchField(feed, in: app)
        capture(app, "search-discovery-above-keyboard")
        feed.tap()
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "投喂")
    }

    @MainActor func testEarTagSearchOpensSheepAndReproductionEventAndRetainsQuery() {
        let app = launch(query: "QA-001")
        let sheep = app.buttons["farm-search-sheep-QA-001"]
        XCTAssertTrue(sheep.waitForExistence(timeout: 30))
        sheep.tap()
        XCTAssertTrue(app.navigationBars["QA-001"].waitForExistence(timeout: 15))
        back(app)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "QA-001")
        app.buttons["farm-search-category-events"].tap()
        let event = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "farm-search-event-", "产羔")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 20))
        reveal(event, in: app)
        event.tap()
        XCTAssertTrue(app.navigationBars["产羔详情"].waitForExistence(timeout: 20))
        capture(app, "search-lambing-detail")
        back(app)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "QA-001")
        XCTAssertTrue(app.buttons["farm-search-event-filters"].exists)
        capture(app, "search-events-retained")
    }

    @MainActor func testPenSearchShowsOccupancyAndOpensPenDetail() {
        let app = launch(query: "青年母羊舍")
        let pen = app.buttons["farm-search-pen-青年母羊舍"]
        XCTAssertTrue(pen.waitForExistence(timeout: 30))
        XCTAssertTrue(pen.label.contains("当前在舍"))
        capture(app, "search-pen-grouped-results")
        pen.tap()
        XCTAssertTrue(app.navigationBars["青年母羊舍"].waitForExistence(timeout: 15))
        back(app)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "青年母羊舍")
        app.buttons["farm-search-category-sheep"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "farm-search-sheep-")).firstMatch.waitForExistence(timeout: 15))
    }

    @MainActor func testTransferEventDetailAndEventFilterSheet() {
        let app = launch(query: "转群")
        app.buttons["farm-search-category-events"].tap()
        let event = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "farm-search-event-", "farm-search-event-filters")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 30))
        event.tap()
        XCTAssertTrue(app.navigationBars["事件详情"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["原圈舍"].exists)
        XCTAssertTrue(app.staticTexts["目标圈舍"].exists)
        XCTAssertTrue(app.buttons["编辑"].exists)
        capture(app, "search-transfer-detail")
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.navigationBars["修正转群"].waitForExistence(timeout: 10))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["事件详情"].waitForExistence(timeout: 15))
        back(app)
        app.buttons["farm-search-event-filters"].tap()
        XCTAssertTrue(app.navigationBars["筛选事件"].waitForExistence(timeout: 10))
        let dateRange = app.switches["限定发生时间"]
        XCTAssertTrue(dateRange.exists)
        dateRange.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(dateRange.value as? String, "1", "Date range switch must actually be enabled")
        capture(app, "search-date-filter-enabled")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["没有匹配结果"].waitForExistence(timeout: 15))
        app.buttons["farm-search-event-filters"].tap()
        app.buttons["清除筛选"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(event.waitForExistence(timeout: 15))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "转群")
        capture(app, "search-transfer-results")
    }
}
