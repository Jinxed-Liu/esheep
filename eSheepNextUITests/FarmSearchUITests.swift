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
        // iOS 17 exposes the native back action by its parent title. The
        // baseline hierarchy showed this button while an edge drag did not pop.
        let nativeBack = app.navigationBars.buttons.matching(
            NSPredicate(format: "label IN %@", ["搜索", "返回", "Back"])).firstMatch
        if nativeBack.exists && nativeBack.isHittable {
            nativeBack.tap()
        } else {
            let sideBack = app.buttons["BackButton"].firstMatch
            XCTAssertTrue(sideBack.waitForExistence(timeout: 5))
            XCTAssertTrue(sideBack.isHittable)
            sideBack.tap()
        }
        XCTAssertTrue(app.buttons["farm-search-category-all"].waitForExistence(timeout: 15))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func focusSearch(in app: XCUIApplication) -> XCUIElement {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        for _ in 0..<3 {
            if search.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(search.isHittable)
        search.tap()
        let keyboardContinue = app.buttons["Continue"]
        if keyboardContinue.exists { keyboardContinue.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        return search
    }

    @MainActor private func keyboardResultViewport(in app: XCUIApplication) -> CGRect {
        let search = app.searchFields.firstMatch
        let keyboard = app.keyboards.firstMatch
        let results = app.descendants(matching: .any)["farm-search-results"].firstMatch
        XCTAssertTrue(results.exists)
        let content = app.frame.intersection(results.frame)
        let navigation = app.navigationBars.firstMatch
        var top = max(content.minY, navigation.exists ? navigation.frame.maxY : content.minY)
        var bottom = min(content.maxY, keyboard.frame.minY)
        // iOS 17 places .searchable at the top; newer search tabs can float it
        // above the keyboard. In either layout, keep the complete row clear.
        if search.frame.midY < (content.minY + keyboard.frame.minY) / 2 {
            top = max(top, search.frame.maxY)
        } else {
            bottom = min(bottom, search.frame.minY)
        }
        let viewport = CGRect(x: content.minX, y: top, width: content.width, height: bottom - top)
            .insetBy(dx: 4, dy: 4)
        XCTAssertGreaterThan(viewport.height, 80)
        return viewport
    }

    @MainActor private func scrollLastActionClearOfKeyboard(_ element: XCUIElement, in app: XCUIApplication) {
        _ = focusSearch(in: app)
        for _ in 0..<8 {
            let viewport = keyboardResultViewport(in: app)
            if element.exists && element.isHittable && viewport.contains(element.frame) { break }
            let upper = viewport.minY + viewport.height * 0.2
            let lower = viewport.minY + viewport.height * 0.8
            let scrollDown = element.exists && element.frame.midY < viewport.minY
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: viewport.maxX - 26, dy: scrollDown ? upper : lower))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(
                    CGVector(dx: viewport.maxX - 26, dy: scrollDown ? lower : upper)))
        }
        capture(app, "keyboard-scroll-end")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Verify scrolling while the keyboard stays open")
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        XCTAssertTrue(keyboardResultViewport(in: app).contains(element.frame),
                      "The complete last action must clear the search field and keyboard")
    }

    @MainActor func testCategoryBarUsesScreenWidthAndLastResultClearsKeyboard() {
        let app = launch(query: "青年母羊舍")
        XCTAssertTrue(app.buttons["farm-search-pen-青年母羊舍"].waitForExistence(timeout: 30))
        let bar = app.scrollViews["farm-search-category-bar"]
        XCTAssertTrue(bar.exists)
        if #available(iOS 26, *) {
            XCTAssertLessThanOrEqual(bar.frame.minX, 1)
            XCTAssertGreaterThanOrEqual(bar.frame.maxX, app.frame.maxX - 1)
        } else {
            // iOS 17 keeps the native insetGrouped section margins. The bar
            // must fit the screen, and its final category must remain reachable.
            XCTAssertGreaterThanOrEqual(bar.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(bar.frame.maxX, app.frame.maxX)
        }
        let search = app.searchFields.firstMatch
        let navigation = app.navigationBars.firstMatch
        var topChrome = navigation.exists ? navigation.frame.maxY : app.frame.minY
        if search.exists && search.frame.midY < app.frame.midY {
            topChrome = max(topChrome, search.frame.maxY)
        }
        XCTAssertLessThan(app.buttons["farm-search-category-all"].frame.minY, topChrome + 70,
                          "Categories must stay near the content top below the current system's search chrome")
        bar.swipeLeft()
        let events = app.buttons["farm-search-category-events"]
        XCTAssertTrue(events.isHittable)
        XCTAssertLessThanOrEqual(events.frame.maxX, app.frame.maxX)
        capture(app, "search-full-width-categories")
        let allEvents = app.buttons["farm-search-all-events"]
        scrollLastActionClearOfKeyboard(allEvents, in: app)
        capture(app, "search-last-result-above-keyboard")
        allEvents.tap()
        XCTAssertTrue(app.buttons["farm-search-event-filters"].waitForExistence(timeout: 10))
    }

    @MainActor func testDiscoveryOmitsExplanationAndLastSuggestionClearsKeyboard() {
        let app = launch(query: "")
        XCTAssertFalse(app.staticTexts["搜索当前牧场的羊只、羊舍和事件。"].exists)
        XCTAssertFalse(app.staticTexts["支持耳号、旧耳号、品种、羊舍名称、事件类型、日期和备注。"].exists)
        let feed = app.buttons["投喂"]
        scrollLastActionClearOfKeyboard(feed, in: app)
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

    @MainActor func testLegacyEarTagSearchRetainsCategoryAndEventFiltersAfterDetails() {
        let app = launch(query: "")
        let search = focusSearch(in: app)
        search.typeText("QA-OLD-001\n")
        let sheep = app.buttons["farm-search-sheep-QA-001"]
        XCTAssertTrue(sheep.waitForExistence(timeout: 30))
        XCTAssertTrue(sheep.label.contains("QA-OLD-001"), "The result must identify the matched old ear tag")
        let sheepCategory = app.buttons["farm-search-category-sheep"]
        sheepCategory.tap()
        XCTAssertTrue(sheepCategory.isSelected)
        reveal(sheep, in: app)
        sheep.tap()
        XCTAssertTrue(app.navigationBars["QA-001"].waitForExistence(timeout: 15))
        back(app)
        XCTAssertEqual(search.value as? String, "QA-OLD-001")
        XCTAssertTrue(sheepCategory.isSelected)

        let eventCategory = app.buttons["farm-search-category-events"]
        eventCategory.tap()
        let filters = app.buttons["farm-search-event-filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 15))
        filters.tap()
        XCTAssertTrue(app.navigationBars["筛选事件"].waitForExistence(timeout: 10))
        let scope = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "事件类型")).firstMatch
        scope.tap()
        let lambing = app.buttons.matching(NSPredicate(format: "label == %@", "产羔")).firstMatch
        XCTAssertTrue(lambing.waitForExistence(timeout: 10))
        lambing.tap()
        let dateRange = app.switches["限定发生时间"]
        dateRange.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(dateRange.value as? String, "1")
        app.navigationBars["筛选事件"].buttons["完成"].tap()

        let eventRows = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND identifier != %@", "farm-search-event-", "farm-search-event-filters"))
        let event = eventRows.firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 20))
        XCTAssertTrue(eventRows.allElementsBoundByIndex.allSatisfy { $0.label.contains("产羔") })
        reveal(event, in: app)
        event.tap()
        XCTAssertTrue(app.navigationBars["产羔详情"].waitForExistence(timeout: 15))
        back(app)
        XCTAssertEqual(search.value as? String, "QA-OLD-001")
        XCTAssertTrue(eventCategory.isSelected)
        XCTAssertTrue(event.waitForExistence(timeout: 15))
        XCTAssertTrue(eventRows.allElementsBoundByIndex.allSatisfy { $0.label.contains("产羔") })
        filters.tap()
        XCTAssertTrue(app.navigationBars["筛选事件"].waitForExistence(timeout: 10))
        XCTAssertTrue(scope.label.contains("产羔"), "The selected event type must survive detail navigation")
        XCTAssertEqual(dateRange.value as? String, "1", "The date restriction must survive detail navigation")
        capture(app, "legacy-search-filters-retained")
        app.navigationBars["筛选事件"].buttons["完成"].tap()
        XCTAssertTrue(event.waitForExistence(timeout: 15))
    }

    @MainActor func testEquivalentNormalizedQueryRetainsSettledResults() {
        let app = launch(query: "QA-001")
        let search = focusSearch(in: app)
        let sheep = app.buttons["farm-search-sheep-QA-001"]
        XCTAssertTrue(sheep.waitForExistence(timeout: 30))
        // Observe a settled search before changing the raw text so an earlier
        // source-load task cannot make a missing normalized-query task pass.
        XCTAssertFalse(sheep.waitForNonExistence(timeout: 2))
        search.typeText(" ")
        XCTAssertEqual(search.value as? String, "QA-001 ")
        XCTAssertFalse(sheep.waitForNonExistence(timeout: 2),
                       "An equivalent normalized query must not clear settled results")
        search.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(search.value as? String, "QA-001")
        XCTAssertFalse(sheep.waitForNonExistence(timeout: 2))
        capture(app, "equivalent-search-query-retains-results")
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

