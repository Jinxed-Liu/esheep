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
        // Moving a wide element beyond the canvas can expand its AX union frame.
        // Measure the initially contained layout before performing the gesture.
        let scale = canvas.frame.width / 360
        let sex = try element("sex", in: baseline)
        let tapX = try XCTUnwrap(sex["x"] as? Double) + XCTUnwrap(sex["width"] as? Double) / 2
        let tapY = try XCTUnwrap(sex["y"] as? Double) + XCTUnwrap(sex["height"] as? Double) / 2
        canvas.coordinate(withNormalizedOffset: CGVector(dx: tapX / 360, dy: tapY / 640)).tap()
        XCTAssertEqual(try state()["selectedID"] as? String, "sex", "Tap selection must still work")
        let x = try XCTUnwrap(before["x"] as? Double) + XCTUnwrap(before["width"] as? Double) / 2
        let y = try XCTUnwrap(before["y"] as? Double) + XCTUnwrap(before["height"] as? Double) / 2
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: x / 360, dy: y / 640))
        let end = start.withOffset(CGVector(dx: 24, dy: 24))
        // The default velocity sent only a down/move/up in 40 ms. Give the
        // native recognizer an actual continuous drag, including its final frame.
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertEqual(try state()["selectedID"] as? String, "earTag", app.debugDescription)
        let after = try element("earTag")
        XCTAssertEqual(try XCTUnwrap(after["x"] as? Double) - XCTUnwrap(before["x"] as? Double),
                       Double(24 / scale), accuracy: 5, app.debugDescription)
        XCTAssertEqual(try XCTUnwrap(after["y"] as? Double) - XCTUnwrap(before["y"] as? Double),
                       Double(24 / scale), accuracy: 5)
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
        let colorPicker = app.buttons[prefix + "color"]
        reveal(colorPicker)
        // The whole accessible row owns a sheet containing UIKit's native picker.
        colorPicker.tap()
        let picker = app.descendants(matching: .any)["sheepPoster.nativeColorPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        let slidersTab = picker.buttons.matching(NSPredicate(format: "label IN %@", ["滑块", "Sliders"])).firstMatch
        XCTAssertTrue(slidersTab.waitForExistence(timeout: 10), app.debugDescription)
        slidersTab.tap()
        // Native RGB controls; do not depend on a particular localized field name.
        let sliders = picker.sliders
        XCTAssertTrue(sliders.firstMatch.waitForExistence(timeout: 5))
        sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 0.2)
        let close = app.buttons[prefix + "color.done"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
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
        // This flow edits five fields, saves, and verifies two real relaunches.
        // Measured CI execution reached the first relaunch at the six-minute cap.
        executionTimeAllowance = 600
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
        let selection = app.scrollViews["sheepPoster.selection"]
        // Opening the editor scrolled the gallery. Restore the entire thumbnail
        // before comparing pixels, rather than capturing its clipped viewport.
        for _ in 0..<8 {
            if thumbnail.frame.minY >= selection.frame.minY { break }
            selection.swipeDown()
        }
        XCTAssertGreaterThanOrEqual(thumbnail.frame.minY, selection.frame.minY)
        XCTAssertLessThan(thumbnail.frame.maxY, app.buttons["sheepPoster.previewAndShare"].frame.minY)
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
        // UIActivityViewController exposes application activities as collection cells.
        let save = app.cells["Save regression PNG"]
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
        // The complete edit/reset/reopen flow reached its final assertion at
        // 358 seconds on CI. Leave bounded time for evidence and app teardown.
        executionTimeAllowance = 480
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
        addTeardownBlock { @MainActor [self] in
            // hasSucceeded is false until the run finishes, including teardown.
            // Only collect failure evidence when an assertion actually failed.
            if (testRun?.totalFailureCount ?? 0) > 0 {
                capture("failure-before-termination")
                let hierarchy = XCTAttachment(string: application.debugDescription)
                hierarchy.name = "failure-accessibility-hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
                let canvas = application.descendants(matching: .any)[prefix + "canvas"].firstMatch
                if canvas.exists, let value = try? jsonValue(canvas),
                   let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
                   let json = String(data: data, encoding: .utf8) {
                    let stateAttachment = XCTAttachment(string: json)
                    stateAttachment.name = "failure-editor-state"
                    stateAttachment.lifetime = .keepAlways
                    add(stateAttachment)
                }
            }
            application.terminate()
        }
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
        let scroll = app.scrollViews["sheepPoster.selection"]
        let preview = app.buttons["sheepPoster.previewAndShare"]
        // A partially clipped button can be reported hittable while its center
        // is covered by the fixed preview action. Keep the entire target above it.
        for _ in 0..<8 {
            if button.isHittable && button.frame.maxY < preview.frame.minY - 8 { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(button.isHittable)
        XCTAssertLessThan(button.frame.maxY, preview.frame.minY - 8)
        button.tap()
        XCTAssertTrue(app.buttons[prefix + "elements"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func tap(_ id: String) {
        let button = app.buttons[prefix + id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), id)
        button.tap()
    }

    private func select(_ id: String) {
        guard let current = try? state(), let elements = current["elements"] as? [[String: Any]],
              let targetIndex = elements.firstIndex(where: { $0["id"] as? String == id }) else {
            XCTFail("Missing element: " + id); return
        }
        if current["selectedID"] as? String == id { return }
        tap("elements")
        let item = app.buttons[prefix + "select." + id]
        let indices = Dictionary(uniqueKeysWithValues: elements.enumerated().compactMap { index, element in
            (element["id"] as? String).map { (prefix + "select." + $0, index) }
        })
        for _ in 0..<8 {
            if item.exists && item.isHittable { break }
            // Cache one accessibility snapshot: querying each live element's
            // frame inside a sort can consume the entire test timeout.
            guard let snapshot = try? app.snapshot() else {
                XCTFail("Could not snapshot the element menu"); return
            }
            let screen = snapshot.frame.insetBy(dx: 8, dy: 60)
            let visible = menuRows(in: snapshot).filter {
                !$0.frame.isEmpty && screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }.sorted { $0.frame.midY < $1.frame.midY }
            guard let first = visible.first, let last = visible.last,
                  let firstIndex = indices[first.identifier], let lastIndex = indices[last.identifier],
                  firstIndex != lastIndex, last.frame.midY > first.frame.midY + 80 else {
                XCTFail("No scrollable element menu: " + app.debugDescription); return
            }
            // A native menu opening upwards can reverse its visual order.
            // Infer direction from the visible IDs instead of always swiping up.
            let increasingDownwards = lastIndex > firstIndex
            let targetBeforeMiddle = Double(targetIndex) < Double(firstIndex + lastIndex) / 2
            let swipeDown = targetBeforeMiddle == increasingDownwards
            let top = CGPoint(x: first.frame.midX, y: first.frame.midY + 8)
            let bottom = CGPoint(x: last.frame.midX, y: last.frame.midY - 8)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = swipeDown ? top : bottom
            let end = swipeDown ? bottom : top
            origin.withOffset(CGVector(dx: start.x - snapshot.frame.minX, dy: start.y - snapshot.frame.minY))
                .press(forDuration: 0.05,
                       thenDragTo: origin.withOffset(CGVector(dx: end.x - snapshot.frame.minX,
                                                              dy: end.y - snapshot.frame.minY)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(item.isHittable, id + "\n" + app.debugDescription); item.tap()
        XCTAssertEqual((try? state())?["selectedID"] as? String, id)
    }

    private func menuRows(in snapshot: any XCUIElementSnapshot) -> [(identifier: String, frame: CGRect)] {
        if snapshot.elementType == .button && snapshot.identifier.hasPrefix(prefix + "select.") {
            return [(snapshot.identifier, snapshot.frame)]
        }
        return snapshot.children.flatMap { menuRows(in: $0) }
    }

    private func addText() {
        tap("add")
        app.buttons["添加文字"].tap()
    }

    private func applyTemplate(_ name: String) {
        tap("templates")
        tap("apply." + name)
    }

    private func replaceText(_ text: String) throws {
        let field = app.descendants(matching: .any)[prefix + "text"].firstMatch
        reveal(field, upwards: false)
        let selectedID = try XCTUnwrap(try state()["selectedID"] as? String)
        field.tap()
        // A tap can place the cursor at the beginning. Use native selection,
        // rather than assuming that repeated backspace deletes the old value.
        field.press(forDuration: 1.1)
        let selectAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["全选", "Select All"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
        selectAll.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        // An empty UIKit field can report its placeholder as its AX value even
        // when hierarchy text omits that value. Wait for the actual bound text.
        let canvas = app.descendants(matching: .any)[prefix + "canvas"].firstMatch
        let cleared = NSPredicate { object, _ in
            guard let canvas = object as? XCUIElement, let json = canvas.value as? String,
                  let state = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let elements = state["elements"] as? [[String: Any]],
                  let selected = elements.first(where: { $0["id"] as? String == selectedID }) else { return false }
            return selected["text"] as? String == ""
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: canvas)],
                                     timeout: 5), .completed, app.debugDescription)
        XCTAssertEqual(try element(selectedID)["text"] as? String, "")
        field.typeText(text)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", text), object: field)], timeout: 5), .completed,
            app.debugDescription)
        // Leave the editor and reopen to dismiss the keyboard via production UI.
        tap("done"); openEditor()
        select(selectedID)
        XCTAssertEqual(try element(selectedID)["text"] as? String, text)
    }

    private func changeSlider(_ title: String, position: CGFloat, field: String) throws {
        let initial = try state()
        let id = try XCTUnwrap(initial["selectedID"] as? String)
        let before = try element(id, in: initial)[field] as? Double
        let slider = app.sliders[prefix + "slider." + title]
        reveal(slider)
        // A 15-point rotation adjustment at .slow (250 pt/s) still emits only
        // a 60 ms movement. Keep the requested endpoints, but give the native
        // slider half a second of actual movement even for a short adjustment.
        let frame = slider.frame
        let inset = min(frame.height / 2, frame.width / 2)
        let track = frame.width - 2 * inset
        let initialPosition = slider.normalizedSliderPosition
        let origin = slider.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: inset + track * initialPosition,
                                               dy: frame.height / 2))
        let end = origin.withOffset(CGVector(dx: inset + track * position, dy: frame.height / 2))
        let distance = abs(track * (position - initialPosition))
        let velocity = XCUIGestureVelocity(rawValue: max(distance / 0.5, 1))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0.2)
        let after = try element(id)[field] as? Double
        XCTAssertNotEqual(before, after, title)
    }

    private func reveal(_ element: XCUIElement, upwards: Bool = true) {
        let inspector = app.scrollViews[prefix + "inspector"]
        // The viewport does not move while its contents scroll. Resolve its
        // coordinates once, avoiding repeated remote AX queries per touch event.
        let inspectorFrame = inspector.frame
        let appFrame = app.frame
        let viewport = inspectorFrame.intersection(appFrame.insetBy(dx: 0, dy: 44)).insetBy(dx: 0, dy: 8)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = inspectorFrame.minX + inspectorFrame.width * 0.02 - appFrame.minX
        let top = origin.withOffset(CGVector(dx: x, dy: inspectorFrame.minY + inspectorFrame.height * 0.2 - appFrame.minY))
        let bottom = origin.withOffset(CGVector(dx: x, dy: inspectorFrame.minY + inspectorFrame.height * 0.8 - appFrame.minY))
        for _ in 0..<24 {
            // The scroll view's AX frame can extend underneath the home indicator.
            let frame = element.frame
            if frame.minY >= viewport.minY && frame.maxY <= viewport.maxY && element.isHittable { return }
            let moveUp = frame.isEmpty ? upwards : frame.midY > viewport.midY
            // Short, controlled drags prevent momentum from skipping the target.
            // The outer padding avoids changing sliders while trying to scroll.
            (moveUp ? bottom : top)
                .press(forDuration: 0.05, thenDragTo: moveUp ? top : bottom,
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Could not reveal \(element.description)\n\(app.debugDescription)")
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
