import XCTest

final class SheepSharePermissionsUITests: XCTestCase {
    @MainActor
    func testAdministratorCanSharePosterWithoutFullArchiveExport() {
        verifySharing(role: "administrator", canExportArchive: false)
    }

    @MainActor
    func testWorkerCanSharePosterWithoutFullArchiveExport() {
        verifySharing(role: "worker", canExportArchive: false)
    }

    @MainActor
    func testOwnerCanSharePosterAndExportFullArchive() {
        verifySharing(role: "owner", canExportArchive: true)
    }

    @MainActor
    private func verifySharing(role: String, canExportArchive: Bool) {
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
        XCTAssertTrue(menu.isEnabled, "Members must be able to open the poster sharing menu.")
        menu.tap()
        let poster = app.buttons["分享羊只海报"]
        XCTAssertTrue(poster.waitForExistence(timeout: 10))
        XCTAssertTrue(poster.isEnabled)
        XCTAssertEqual(app.buttons["导出完整档案 XLSX"].isEnabled, canExportArchive)
        poster.tap()

        let preview = app.buttons["预览并分享"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        let share = app.buttons["sheepPoster.sharePoster"]
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        XCTAssertTrue(share.isEnabled)
        share.tap()
        XCTAssertTrue(app.buttons["拷贝"].waitForExistence(timeout: 15),
                      "The generated poster must reach the system share sheet.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "sheep-poster-system-share-" + role
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
