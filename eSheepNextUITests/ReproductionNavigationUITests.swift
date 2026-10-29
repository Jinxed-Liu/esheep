import XCTest

final class ReproductionNavigationUITests: XCTestCase {
    @MainActor
    private func launch(search: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-reproduction",
            search ? "--design-search" : "--design-workspace",
            "--design-role", "administrator", "--design-fixture-id", UUID().uuidString,
            "--design-search-query", "QA-001", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.frame.insetBy(dx: 0, dy: 80)
        for _ in 0..<8 {
            if element.isHittable && viewport.contains(element.frame) { return }
            if element.exists && element.frame.midY < viewport.minY { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func back(_ app: XCUIApplication, to parentTitles: [String]) {
        let nativeBack = app.navigationBars.buttons.matching(
            NSPredicate(format: "label IN %@", parentTitles + ["返回", "Back"])).firstMatch
        if nativeBack.exists && nativeBack.isHittable {
            nativeBack.tap()
        } else {
            let sideBack = app.buttons["BackButton"].firstMatch
            XCTAssertTrue(sideBack.waitForExistence(timeout: 5))
            XCTAssertTrue(sideBack.isHittable)
            sideBack.tap()
        }
    }

    @MainActor
    private func exerciseHistory(_ app: XCUIApplication) {
        let evidence = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@",
            "本轮依据与繁殖历史", "繁殖资料待核实")).firstMatch
        for attempt in 0..<3 {
            XCTAssertTrue(app.navigationBars["QA-001"].waitForExistence(timeout: 20))
            reveal(evidence, in: app)
            evidence.tap()
            let history = app.navigationBars["繁殖依据与历史"]
            XCTAssertTrue(history.waitForExistence(timeout: 15), "Attempt \(attempt): history must be the immediate destination")
            XCTAssertTrue(history.isHittable, "History must be visible, not underneath another sheep detail")
            let record = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "产羔")).firstMatch
            reveal(record, in: app)
            record.tap()
            XCTAssertTrue(app.navigationBars["产羔详情"].waitForExistence(timeout: 15))
            back(app, to: ["繁殖依据与历史"])
            XCTAssertTrue(history.waitForExistence(timeout: 15))
            XCTAssertTrue(history.isHittable)
            back(app, to: ["QA-001"])
            XCTAssertTrue(app.navigationBars["QA-001"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.navigationBars["QA-001"].isHittable)
        }
    }

    @MainActor
    func testHomeHerdProfileHistoryReturnsWithoutDuplicateDetails() {
        let app = launch(search: false)
        let herd = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "在场羊只")).firstMatch
        XCTAssertTrue(herd.waitForExistence(timeout: 60))
        herd.tap()
        XCTAssertTrue(app.navigationBars["羊只"].waitForExistence(timeout: 20))
        let sheep = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "QA-001")).firstMatch
        XCTAssertTrue(sheep.waitForExistence(timeout: 20))
        sheep.tap()
        exerciseHistory(app)
        back(app, to: ["羊只", "在场羊只"])
        XCTAssertTrue(app.navigationBars["羊只"].waitForExistence(timeout: 15), "A single back must return to the herd list")
        back(app, to: ["首页", "设计验收 · 本机测试场"])
        XCTAssertTrue(herd.waitForExistence(timeout: 15))
        XCTAssertTrue(herd.isHittable)
    }

    @MainActor
    func testSearchProfileHistoryReturnsWithoutDuplicateDetails() {
        let app = launch(search: true)
        let sheep = app.buttons["farm-search-sheep-QA-001"]
        XCTAssertTrue(sheep.waitForExistence(timeout: 60))
        sheep.tap()
        exerciseHistory(app)
        back(app, to: ["搜索"])
        XCTAssertTrue(sheep.waitForExistence(timeout: 15), "A single back must return to search results")
        XCTAssertTrue(sheep.isHittable)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "QA-001")
    }
}

