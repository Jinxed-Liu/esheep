import XCTest

final class SheepSharePermissionsUITests: XCTestCase {
    @MainActor
    func testAdministratorCanSharePosterAndExportSheepArchive() {
        verifySharingAndExport(role: "administrator")
    }

    @MainActor
    func testWorkerCanSharePosterAndExportSheepArchive() {
        verifySharingAndExport(role: "worker")
    }

    @MainActor
    func testOwnerCanSharePosterAndExportSheepArchive() {
        verifySharingAndExport(role: "owner")
    }

    @MainActor
    private func verifySharingAndExport(role: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--design-acceptance", "--design-reproduction", "--design-sheep-detail",
            "--design-role", role, "--design-fixture-id", UUID().uuidString,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launch()
        defer { app.terminate() }
        let ewe = app.buttons["detail-fixture-QA-010"]
        XCTAssertTrue(ewe.waitForExistence(timeout: 30))
        ewe.tap()

        let menu = app.buttons["分享或导出羊只档案"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        XCTAssertTrue(menu.isEnabled, "Members must be able to open the sharing menu.")
        waitForNotificationBanner()
        menu.tap()
        let poster = app.buttons["分享羊只海报"]
        XCTAssertTrue(poster.waitForExistence(timeout: 10))
        XCTAssertTrue(poster.isEnabled)
        XCTAssertTrue(app.buttons["导出完整档案 XLSX"].isEnabled)
        waitForNotificationBanner()
        poster.tap()

        let preview = app.buttons["预览并分享"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        preview.tap()
        let share = app.buttons["sheepPoster.sharePoster"]
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        share.tap()
        let activity = app.navigationBars["UIActivityContentView"]
        XCTAssertTrue(activity.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, name: "sheep-poster-system-share-" + role)
        app.buttons["header.closeButton"].tap()
        app.navigationBars["杂志封面"].buttons["完成"].tap()
        app.navigationBars["选择海报模板"].buttons["取消"].tap()

        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        waitForNotificationBanner()
        menu.tap()
        let export = app.buttons["导出完整档案 XLSX"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        XCTAssertTrue(export.isEnabled)
        waitForNotificationBanner()
        export.tap()
        let fileName = app.textFields.matching(NSPredicate(
            format: "value CONTAINS %@", "羊只档案_QA-010"
        )).firstMatch
        let hasFile = fileName.waitForExistence(timeout: 20)
        capture(app, name: "sheep-xlsx-export-" + role)
        XCTAssertTrue(hasFile, app.debugDescription)
    }

    @MainActor
    private func waitForNotificationBanner() {
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any)["NotificationShortLookView"].firstMatch
        if banner.exists {
            XCTAssertTrue(banner.waitForNonExistence(timeout: 15))
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
