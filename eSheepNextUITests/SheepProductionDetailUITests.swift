import XCTest

final class SheepProductionDetailUITests: XCTestCase {
    @MainActor
    func testLinkedGrowthAndReproductionHistoryRemainAccessible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--design-acceptance", "--design-reproduction", "--design-sheep-detail", "--design-fixture-id", UUID().uuidString,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let ewe = app.buttons["detail-fixture-QA-010"]
        XCTAssertTrue(ewe.waitForExistence(timeout: 30)); ewe.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "本轮繁殖状态")).firstMatch.waitForExistence(timeout: 20))
        let chart = app.descendants(matching: .any)["sheep-growth-trends"].firstMatch
        for _ in 0..<6 { if chart.isHittable { break }; app.swipeUp(velocity: .slow) }
        XCTAssertTrue(chart.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "sheep-detail-linked-growth-local-fixture"; attachment.lifetime = .keepAlways; add(attachment)
        let gainChart = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "区间日增重折线图")).firstMatch
        for _ in 0..<4 { if gainChart.isHittable { break }; app.swipeUp(velocity: .slow) }
        XCTAssertTrue(gainChart.isHittable)
        gainChart.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).tap()
        let selectedEvidence = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "千克 · 增重", "区间日增重")).firstMatch
        XCTAssertTrue(selectedEvidence.exists)
        XCTAssertFalse(selectedEvidence.label.contains("区间日增重 250 克/天"))
        let all = app.buttons["查看范围"].firstMatch
        if all.isHittable { all.tap(); app.buttons["全部"].firstMatch.tap() }
        app.swipeUp(velocity: .slow)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "范围平均日增重")).firstMatch.exists)
    }
}
