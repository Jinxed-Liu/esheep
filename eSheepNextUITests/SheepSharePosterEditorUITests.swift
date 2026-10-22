import UIKit
import XCTest

/// Real production screens and native controls, backed only by the existing
/// local-only fixture. Diagnostic values observe state; they cannot edit it.
@MainActor
final class SheepSharePosterEditorUITests: XCTestCase {
    private let prefix = "sheepPoster.editor."
    private var app = XCUIApplication()

    func testMagazineTextFontGeometryLayersUndoAndReset() throws {
        try verifyEditing(style: "杂志封面")
    }

    func testBreedingTextFontGeometryLayersUndoAndReset() throws {
        try verifyEditing(style: "种羊展示卡")
    }

    func testMinimalTextFontGeometryLayersUndoAndReset() throws {
        try verifyEditing(style: "极简摄影")
    }

    func testCanvasDragUsesPreviewScaleAndCanBeUndone() throws {
        launch()
        openPoster(tag: "QA-001", style: "杂志封面")
        openEditor()
        let baseline = try state()
        let before = try element("earTag", in: baseline)
        let canvas = app.descendants(matching: .any)[prefix + "canvas"].firstMatch
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = start.withOffset(CGVector(dx: 12, dy: 16))
        start.press(forDuration: 0.1, thenDragTo: end)
        let after = try element("earTag")
        let scale = canvas.frame.width / 360
        XCTAssertEqual(try XCTUnwrap(after["x"] as? Double) - XCTUnwrap(before["x"] as? Double),
                       Double(12 / scale), accuracy: 5)
        XCTAssertEqual(try XCTUnwrap(after["y"] as? Double) - XCTUnwrap(before["y"] as? Double),
                       Double(16 / scale), accuracy: 5)
        tap("undo")
        assertCustomization(try state(), equals: baseline)
    }

    func testPhotoCropUndoAndReset() throws {
        launch()
        openPoster(tag: "QA-001", style: "种羊展示卡")
        openEditor()
        select("photo")
        let baseline = try state()
        XCTAssertNotEqual(baseline["photoDigest"] as? String, "missing")
        try changeSlider("照片缩放", position: 0.65, field: "photoZoom")
        let zoomed = try state()
        try changeSlider("照片内水平位置", position: 0.7, field: "photoX")
        try changeSlider("照片内垂直位置", position: 0.3, field: "photoY")
        capture("photo-crop")
        tap("undo")
        tap("undo")
        assertCustomization(try state(), equals: zoomed)
        tap("undo")
        assertCustomization(try state(), equals: baseline)
        try changeSlider("照片缩放", position: 0.75, field: "photoZoom")
        tapInspectorButton("reset")
        assertCustomization(try state(), equals: baseline)
    }

    func testNativeColorPickerAndVisibilityAreUndoable() throws {
        launch()
        openPoster(tag: "QA-001", style: "种羊展示卡")
        openEditor()
        let baseline = try state()
        reveal(app.descendants(matching: .any)[prefix + "color"].firstMatch)
        app.descendants(matching: .any)[prefix + "color"].firstMatch.tap()
        let slidersTab = app.buttons.matching(NSPredicate(format: "label IN %@", ["滑块", "Sliders"])).firstMatch
        XCTAssertTrue(slidersTab.waitForExistence(timeout: 10), app.debugDescription)
        slidersTab.tap()
        // Native RGB controls; do not depend on a particular localized field name.
        let sliders = app.sliders
        XCTAssertTrue(sliders.firstMatch.waitForExistence(timeout: 5))
        sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 0.2)
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "Close"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        let changed = try element("earTag")
        XCTAssertNotEqual(changed["color"] as? NSDictionary, try element("earTag", in: baseline)["color"] as? NSDictionary)
        capture("native-color-picker-result")
        // ColorPicker can issue more than one update. Undo until the original
        // state is reached; the editor intentionally records each native update.
        for _ in 0..<30 {
            if customization(try state()).isEqual(customization(baseline)) { break }
            tap("undo")
        }
        assertCustomization(try state(), equals: baseline)
        let visibility = app.switches[prefix + "visible"]
        reveal(visibility, upwards: false)
        visibility.tap()
        XCTAssertEqual(try element("earTag")["isHidden"] as? Bool, true)
        tap("undo")
        XCTAssertEqual(try element("earTag")["isHidden"] as? Bool, false)
    }

    func testSavedTemplateSurvivesRelaunchAndRebindsEveryCurrentSheepField() throws {
        launch()
        openPoster(tag: "QA-001", style: "种羊展示卡")
        openEditor()
        let originalA = try state()
        try replaceText("OLD-EAR-A")
        try changeSlider("水平位置", position: 0.46, field: "x")
        select("family.dam.earTag")
        try replaceText("OLD-DAM-A")
        select("metric.0.value")
        try replaceText("OLD-PARITY-A")
        select("lastLambing.value")
        try replaceText("OLD-DATE-A")
        select("photo")
        try changeSlider("照片缩放", position: 0.45, field: "photoZoom")
        addText()
        try replaceText("Reusable caption 112")
        let editedA = try state()
        tap("saveTemplate")
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Poster-112")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 10))
        // Save must not sanitize the currently edited sheep's poster in place.
        assertCustomization(try state(), equals: editedA)
        tap("done")
        openEditor()
        assertCustomization(try state(), equals: editedA)
        // Same UUID, actual process termination, actual local JSON store.
        app.terminate(); app.launch()
        openPoster(tag: "QA-002", style: "种羊展示卡")
        openEditor()
        let baselineB = try state()
        XCTAssertNotEqual(originalA["photoDigest"] as? String, baselineB["photoDigest"] as? String)
        XCTAssertNotEqual(try element("family.dam.earTag", in: originalA)["text"] as? String,
                          try element("family.dam.earTag", in: baselineB)["text"] as? String)
        XCTAssertNotEqual(try element("metric.2.value", in: originalA)["text"] as? String,
                          try element("metric.2.value", in: baselineB)["text"] as? String)
        applyTemplate("Poster-112")
        let applied = try state()
        XCTAssertEqual(applied["photoDigest"] as? String, baselineB["photoDigest"] as? String)
        XCTAssertEqual(try element("earTag", in: applied)["x"] as? Double,
                       try element("earTag", in: editedA)["x"] as? Double)
        XCTAssertEqual(try element("photo", in: applied)["photoZoom"] as? Double,
                       try element("photo", in: editedA)["photoZoom"] as? Double)
        let fields = try XCTUnwrap(baselineB["elements"] as? [[String: Any]])
        for field in fields where field["kind"] as? String == "text" {
            let id = try XCTUnwrap(field["id"] as? String)
            XCTAssertEqual(try element(id, in: applied)["text"] as? String, field["text"] as? String, id)
        }
        let captions = try XCTUnwrap(applied["elements"] as? [[String: Any]])
        XCTAssertTrue(captions.contains { $0["text"] as? String == "Reusable caption 112" })
        XCTAssertFalse(captions.contains { ($0["text"] as? String)?.hasPrefix("OLD-") == true })
        capture("template-applied-to-second-sheep")
        // Reopening the original sheep proves poster edits did not mutate its facts.
        app.terminate(); app.launch()
        openPoster(tag: "QA-001", style: "种羊展示卡")
        openEditor()
        let reopenedA = try state()
        XCTAssertEqual(try element("earTag", in: reopenedA)["text"] as? String, "QA-001")
        XCTAssertEqual(reopenedA["photoDigest"] as? String, originalA["photoDigest"] as? String)
        applyTemplate("Poster-112")
        XCTAssertEqual(try element("earTag")["text"] as? String, "QA-001")
    }

    func testCrossStyleTemplateApplicationKeepsTheSavedDesign() throws {
        launch()
        openPoster(tag: "QA-001", style: "极简摄影")
        openEditor()
        addText()
        try replaceText("Cross-style caption")
        let designed = try state()
        tap("saveTemplate")
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Minimal-112")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 10))
        app.terminate(); app.launch()
        openPoster(tag: "QA-002", style: "杂志封面")
        openEditor()
        applyTemplate("Minimal-112")
        let applied = try state()
        XCTAssertEqual(applied["style"] as? String, "minimal")
        XCTAssertEqual(applied["template"] as? String, designed["template"] as? String)
        assertCustomization(applied, equals: designed)
        tap("done")
        openEditor()
        assertCustomization(try state(), equals: designed)
    }

    func testEditedThumbnailPreviewAndSavedSharePNGAgree() throws {
        launch()
        openPoster(tag: "QA-002", style: "种羊展示卡")
        openEditor()
        try replaceText("EXPORT-112")
        try changeSlider("字号", position: 0.35, field: "fontSize")
        select("photo")
        try changeSlider("照片缩放", position: 0.3, field: "photoZoom")
        tap("done")
        let thumbnail = app.descendants(matching: .any)["sheepPoster.thumbnail"].firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
        // Capture real on-screen composition before asking the exporter to render.
        let screen = thumbnail.screenshot().image
        app.buttons["sheepPoster.previewAndShare"].tap()
        let preview = app.images["sheepPoster.previewImage"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        let evidence = try jsonValue(preview)
        let previewPNG = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(evidence["previewPNG"] as? String)))
        let image = try XCTUnwrap(UIImage(data: previewPNG))
        XCTAssertEqual(image.cgImage?.width, 1080)
        XCTAssertEqual(image.cgImage?.height, 1920)
        try assertVisuallyClose(screen, image)
        try assertVisuallyClose(preview.screenshot().image, image)
        app.buttons["sheepPoster.sharePoster"].tap()
        let save = app.buttons["Save regression PNG"]
        XCTAssertTrue(save.waitForExistence(timeout: 15), app.debugDescription)
        save.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let saved = try jsonValue(preview)
        XCTAssertNil(saved["error"])
        let exported = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(saved["exportedPNG"] as? String)))
        XCTAssertEqual(exported, previewPNG, "The actual activity must receive and save the preview bytes")
        let attachment = XCTAttachment(data: exported, uniformTypeIdentifier: "public.png")
        attachment.name = "shared-poster-read-back-from-disk"; attachment.lifetime = .keepAlways; add(attachment)
        capture("edited-preview-after-share")
    }

    private func verifyEditing(style: String) throws {
        launch()
        openPoster(tag: "QA-001", style: style)
        openEditor()
        let baseline = try state()
        try replaceText("回归海报 112")
        let font = app.buttons[prefix + "font.serif"]
        reveal(font)
        font.tap()
        XCTAssertEqual(try element("earTag")["font"] as? String, "serif")
        try changeSlider("字号", position: 0.4, field: "fontSize")
        try changeSlider("水平位置", position: 0.45, field: "x")
        try changeSlider("垂直位置", position: 0.3, field: "y")
        try changeSlider("旋转", position: 0.55, field: "rotation")
        let beforeLayer = try state()
        tapInspectorButton("front")
        let front = try state()
        XCTAssertEqual((front["elements"] as? [[String: Any]])?.last?["id"] as? String, "earTag")
        tapInspectorButton("back")
        XCTAssertEqual((try state()["elements"] as? [[String: Any]])?.first?["id"] as? String, "earTag")
        tap("undo"); assertCustomization(try state(), equals: front)
        tap("undo"); assertCustomization(try state(), equals: beforeLayer)
        addText()
        try replaceText("Keep this caption")
        let edited = try state()
        capture("edited-" + (edited["style"] as? String ?? "unknown"))
        tapInspectorButton("reset")
        assertCustomization(try state(), equals: baseline)
        tap("undo")
        assertCustomization(try state(), equals: edited)
        tap("done")
        openEditor()
        assertCustomization(try state(), equals: edited)
    }

    private func launch() {
        continueAfterFailure = false
        app.launchArguments = ["--design-acceptance", "--design-reproduction", "--design-sheep-detail",
            "--design-poster", "--design-fixture-id", UUID().uuidString,
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let application = app
        addTeardownBlock { @MainActor in application.terminate() }
    }

    private func openPoster(tag: String, style: String) {
        let sheep = app.buttons["detail-fixture-" + tag]
        XCTAssertTrue(sheep.waitForExistence(timeout: 30)); sheep.tap()
        let share = app.buttons["分享或导出羊只档案"]
        XCTAssertTrue(share.waitForExistence(timeout: 20)); share.tap()
        let poster = app.buttons["分享羊只海报"]
        XCTAssertTrue(poster.waitForExistence(timeout: 10)); poster.tap()
        let styles = app.segmentedControls["sheepPoster.style"]
        XCTAssertTrue(styles.waitForExistence(timeout: 20)); styles.buttons[style].tap()
    }

    private func openEditor() {
        let button = app.buttons["sheepPoster.customize"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if !button.isHittable { app.swipeUp() }
        button.tap()
        XCTAssertTrue(app.buttons[prefix + "elements"].waitForExistence(timeout: 10))
    }

    private func tap(_ id: String) {
        let button = app.buttons[prefix + id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), id)
        button.tap()
    }

    private func select(_ id: String) {
        tap("elements")
        let item = app.buttons[prefix + "select." + id]
        for _ in 0..<8 {
            if item.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(item.isHittable, id); item.tap()
    }

    private func addText() {
        tap("add")
        app.buttons["添加文字"].tap()
    }

    private func applyTemplate(_ name: String) {
        tap("templates"); tap("apply." + name)
    }

    private func replaceText(_ text: String) throws {
        let field = app.descendants(matching: .any)[prefix + "text"].firstMatch
        reveal(field, upwards: false)
        let selectedID = try XCTUnwrap(try state()["selectedID"] as? String)
        let old = try XCTUnwrap(field.value as? String)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
        XCTAssertEqual(field.value as? String, text)
        // Leave the editor and reopen to dismiss the keyboard via production UI.
        tap("done"); openEditor()
        select(selectedID)
    }

    private func changeSlider(_ title: String, position: CGFloat, field: String) throws {
        let id = try XCTUnwrap(try state()["selectedID"] as? String)
        let before = try element(id)[field] as? Double
        let slider = app.sliders[prefix + "slider." + title]
        reveal(slider)
        slider.adjust(toNormalizedSliderPosition: position)
        let after = try element(id)[field] as? Double
        XCTAssertNotEqual(before, after, title)
    }

    private func reveal(_ element: XCUIElement, upwards: Bool = true) {
        let inspector = app.scrollViews[prefix + "inspector"]
        for _ in 0..<14 {
            if element.isHittable { return }
            if upwards { inspector.swipeUp(velocity: .fast) } else { inspector.swipeDown(velocity: .fast) }
        }
        XCTAssertTrue(element.isHittable, element.description)
    }

    private func tapInspectorButton(_ id: String) {
        let button = app.buttons[prefix + id]
        reveal(button); button.tap()
    }

    private func state() throws -> [String: Any] {
        try jsonValue(app.descendants(matching: .any)[prefix + "canvas"].firstMatch)
    }

    private func jsonValue(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    private func element(_ id: String, in value: [String: Any]? = nil) throws -> [String: Any] {
        let current = try value ?? state()
        return try XCTUnwrap((current["elements"] as? [[String: Any]])?.first { $0["id"] as? String == id })
    }

    private func customization(_ state: [String: Any]) -> NSDictionary {
        state["customization"] as? NSDictionary ?? [:]
    }

    private func assertCustomization(_ actual: [String: Any], equals expected: [String: Any],
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(customization(actual), customization(expected), file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func assertVisuallyClose(_ actual: UIImage, _ expected: UIImage) throws {
        func pixels(_ image: UIImage) throws -> [UInt8] {
            let cgImage = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: 90 * 160 * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: 90, height: 160,
                bitsPerComponent: 8, bytesPerRow: 360, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 90, height: 160))
            return bytes
        }
        let lhs = try pixels(actual), rhs = try pixels(expected)
        var error = 0.0, samples = 0
        // Exclude rounded corners and permit resampling/antialiasing, while
        // detecting missing layers, old photos and incorrect crop/placement.
        for y in 5..<155 {
            for x in 5..<85 {
                for channel in 0..<3 {
                    let i = (y * 90 + x) * 4 + channel
                    error += Double(abs(Int(lhs[i]) - Int(rhs[i]))) / 255
                    samples += 1
                }
            }
        }
        XCTAssertLessThan(error / Double(samples), 0.05, "On-screen poster differs from exported pixels")
        for (name, image) in [("on-screen-poster", actual), ("exported-poster", expected)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
