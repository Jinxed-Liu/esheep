import PhotosUI
import SwiftUI
import UIKit

struct SheepSharePosterEditor: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: SheepSharePosterSnapshot
    let image: UIImage?
    @Binding var style: SheepSharePosterStyle
    @Binding var template: SheepSharePosterTemplate
    @Binding var customization: SheepSharePosterCustomization

    @State private var selectedID = "earTag"
    @State private var dragOrigin: CGPoint?
    @State private var savedTemplates: [SheepSharePosterSavedTemplate] = []
    @State private var templateName = ""
    @State private var isNamingTemplate = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var imageTargetID: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var history: [SheepSharePosterCustomization] = []

    private var elements: [SheepPosterElement] {
        customization.elements(from: SheepSharePosterLayout.elements(snapshot: snapshot, style: style, template: template))
    }
    private var selected: SheepPosterElement? { elements.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let previewWidth = min(geometry.size.width - 40, max(150, geometry.size.height * 0.42 * 360 / 640))
                VStack(spacing: 12) {
                    templateActions.padding(.horizontal, 20)
                    canvas(width: previewWidth)
                        .frame(maxWidth: .infinity)
                    elementPicker.padding(.horizontal, 20)
                    ScrollView {
                        VStack(spacing: 16) {
                            Text("点选元素后拖动，或在下方精确调整。修改只用于海报，不改变羊只档案。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let selected { inspector(selected) }
                            backgroundInspector
                            if let statusMessage {
                                Text(LocalizedStringKey(statusMessage))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                    .accessibilityIdentifier("sheepPoster.editor.inspector")
                }
                .padding(.top, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("自定义海报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("撤销", systemImage: "arrow.uturn.backward") { undo() }
                        .disabled(history.isEmpty)
                        .accessibilityIdentifier("sheepPoster.editor.undo")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("sheepPoster.editor.done")
                }
            }
            .task { loadTemplates() }
            .onChange(of: style) { _, _ in selectedID = "earTag"; history.removeAll() }
            .onChange(of: photoSelection) { _, item in
                let target = imageTargetID
                Task { await loadImage(item, for: target) }
            }
            .modifier(SheepPosterTemplateNamePrompt(
                isPresented: $isNamingTemplate, name: $templateName, onSave: saveTemplate
            ))
            .alert("海报", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("完成", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var templateActions: some View {
        HStack {
            Menu {
                if savedTemplates.isEmpty {
                    Text("尚未保存模板")
                }
                ForEach(savedTemplates) { saved in
                    Button(saved.name) { applyTemplate(saved) }
                        .accessibilityIdentifier("sheepPoster.editor.apply.\(saved.name)")
                }
                if !savedTemplates.isEmpty {
                    Menu("删除已保存模板") {
                        ForEach(savedTemplates) { saved in
                            Button(saved.name, role: .destructive) { deleteTemplate(saved) }
                        }
                    }
                }
            } label: {
                Label("我的模板", systemImage: "square.stack")
            }
            .accessibilityIdentifier("sheepPoster.editor.templates")
            Spacer()
            Button("保存模板", systemImage: "square.and.arrow.down") {
                templateName = ""
                isNamingTemplate = true
            }
            .accessibilityIdentifier("sheepPoster.editor.saveTemplate")
        }
        .font(.subheadline.weight(.medium))
    }

    private func canvas(width: CGFloat) -> some View {
        let scale = width / 360
        return SheepSharePosterView(snapshot: snapshot, image: image, template: template, style: style,
                                    customization: customization, selectedID: selectedID, interactionScale: scale,
                                    onSelect: { selectedID = $0 }, onMove: moveElement)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: width, height: width * 640 / 360, alignment: .topLeading)
            .clipped()
            // Clipping drawing alone does not bound the scaled poster's hit area.
            // Keep its interactive layers from covering inspector controls below.
            .contentShape(.rect)
            .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sheepPoster.editor.canvas")
            #if DEBUG
            .accessibilityValue(DevelopmentPosterAcceptance.state(snapshot: snapshot, image: image, style: style,
                template: template, customization: customization, selectedID: selectedID,
                savedTemplateNames: savedTemplates.map(\.name)))
            #endif
    }

    private var elementPicker: some View {
        HStack {
            Menu {
                ForEach(elements.reversed()) { element in
                    Button {
                        selectedID = element.id
                    } label: {
                        Label(LocalizedStringKey(element.title),
                              systemImage: element.isHidden ? "eye.slash" : (element.id == selectedID ? "checkmark.circle" : "circle"))
                    }
                    .accessibilityIdentifier("sheepPoster.editor.select.\(element.id)")
                }
            } label: {
                Label(selected.map { String(localized: String.LocalizationValue($0.title)) } ?? String(localized: "选择元素"),
                      systemImage: "square.on.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("sheepPoster.editor.elements")
            Menu {
                Button("添加文字", systemImage: "textformat") { addElement(.text) }
                Button("添加线条", systemImage: "line.diagonal") { addElement(.rule) }
                Button("添加笔触", systemImage: "paintbrush.pointed") { addElement(.brush) }
                Button("添加图片", systemImage: "photo") { addElement(.image) }
            } label: {
                Label("添加", systemImage: "plus")
            }
            .accessibilityIdentifier("sheepPoster.editor.add")
        }
        .font(.subheadline.weight(.medium))
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 12))
    }

    private func inspector(_ element: SheepPosterElement) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("显示此元素", isOn: Binding(
                get: { !element.isHidden },
                set: { value in remember(); update { $0.isHidden = !value } }
            ))
            .accessibilityIdentifier("sheepPoster.editor.visible")
            if element.kind == .text {
                TextField("文字内容", text: Binding(
                    get: { selected?.text ?? "" },
                    set: { value in remember(); update { $0.text = value } }
                ), axis: .vertical)
                .accessibilityIdentifier("sheepPoster.editor.text")
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                Text("字体").font(.subheadline.weight(.medium))
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(SheepPosterFont.allCases) { font in
                            Button {
                                remember()
                                update { $0.font = font }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(LocalizedStringKey(font.title))
                                        .font(.caption)
                                    Text(verbatim: "牧场 Aa123")
                                        .font(font.font(size: 22, text: "牧场 Aa123"))
                                }
                                .foregroundStyle(.primary)
                                .padding(12)
                                .background((element.font == font ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05)),
                                            in: .rect(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(element.font == font ? Color.accentColor : .clear, lineWidth: 1.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sheepPoster.editor.font.\(font.rawValue)")
                            .accessibilityLabel(LocalizedStringKey(font.title))
                            .accessibilityAddTraits(element.font == font ? .isSelected : [])
                        }
                    }
                }
                slider("字号", value: number(\.fontSize, fallback: element.fontSize), range: 4...160)
                slider("字间距", value: number(\.tracking, fallback: element.tracking), range: -5...20)
                Toggle("文字居中", isOn: Binding(get: { selected?.centered ?? false },
                                               set: { value in remember(); update { $0.centered = value } }))
            }
            if element.kind.isImage {
                PhotosPicker(selection: Binding(get: { photoSelection }, set: { value in
                    imageTargetID = element.id
                    photoSelection = value
                }), matching: .images) {
                    Label("更换图片", systemImage: "photo.on.rectangle")
                }
                if element.kind == .photo || element.kind == .photoBackdrop {
                    slider("照片缩放", value: number(\.photoZoom, fallback: element.photoZoom), range: 1...3)
                    slider("照片内水平位置", value: number(\.photoX, fallback: element.photoX), range: -240...240)
                    slider("照片内垂直位置", value: number(\.photoY, fallback: element.photoY), range: -320...320)
                }
            } else {
                SheepPosterColorControl(title: "颜色", identifier: "sheepPoster.editor.color", selection: Binding(
                    get: { selected?.color.color ?? .white },
                    set: { color in remember(); update { $0.color = colorComponents(color) } }
                ))
            }
            slider("水平位置", value: number(\.x, fallback: element.x), range: -180...360)
            slider("垂直位置", value: number(\.y, fallback: element.y), range: -160...640)
            slider("宽度", value: number(\.width, fallback: element.width), range: 1...720)
            slider("高度", value: number(\.height, fallback: element.height), range: 0.5...960)
            slider("旋转", value: number(\.rotation, fallback: element.rotation), range: -180...180)
            slider("不透明度", value: number(\.opacity, fallback: element.opacity), range: 0...1)
            HStack {
                Button("移到顶层") {
                    remember(); update { $0.layerOrder = (elements.map(\.order).max() ?? 10) + 1 }
                }
                .accessibilityIdentifier("sheepPoster.editor.front")
                Spacer()
                Button("移到底层") {
                    remember(); update { $0.layerOrder = (elements.map(\.order).min() ?? 0) - 1 }
                }
                .accessibilityIdentifier("sheepPoster.editor.back")
            }
            Divider()
            HStack {
                Button("恢复此元素") {
                    remember()
                    customization.overrides.removeValue(forKey: element.id)
                    if element.id == "photo" || element.id == "photo.backdrop" {
                        customization.photoData = nil
                    }
                }
                Spacer()
                Button("移除", role: .destructive) {
                    remember()
                    if customization.additions.contains(where: { $0.id == element.id }) {
                        customization.additions.removeAll { $0.id == element.id }
                        customization.overrides.removeValue(forKey: element.id)
                        selectedID = "earTag"
                    } else { update { $0.isHidden = true } }
                }
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 14))
    }

    private var backgroundInspector: some View {
        VStack(spacing: 16) {
            SheepPosterColorControl(title: "画布底色", identifier: "sheepPoster.editor.background", selection: Binding(
                get: { customization.background?.color ?? (style == .breeding && template.theme == .light ? Color(red: 0.86, green: 0.94, blue: 1) : .black) },
                set: { remember(); customization.background = colorComponents($0) }
            ))
            Text("若底色被照片遮住，可在元素菜单中隐藏“照片背景”。")
                .font(.caption).foregroundStyle(.secondary)
            Button("恢复整张默认设计") {
                remember()
                customization = .init()
                selectedID = "earTag"
            }
            .accessibilityIdentifier("sheepPoster.editor.reset")
        }
        .font(.subheadline)
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 14))
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in if editing { remember() } })
                .accessibilityLabel(LocalizedStringKey(title))
                .accessibilityIdentifier("sheepPoster.editor.slider.\(title)")
        }
    }

    private func number(_ path: WritableKeyPath<SheepPosterElementOverride, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { customization.overrides[selectedID]?[keyPath: path] ?? fallback },
                set: { value in update { $0[keyPath: path] = value } })
    }
    private func update(_ mutation: (inout SheepPosterElementOverride) -> Void) {
        var value = customization.overrides[selectedID] ?? .init()
        mutation(&value)
        customization.overrides[selectedID] = value
    }
    private func remember() {
        if history.last != customization { history.append(customization) }
        if history.count > 30 { history.removeFirst() }
    }
    private func undo() {
        guard let previous = history.popLast() else { return }
        customization = previous
    }
    private func moveElement(_ id: String, _ translation: CGSize, _ ended: Bool) {
        guard let element = elements.first(where: { $0.id == id }) else { return }
        if dragOrigin == nil {
            remember()
            dragOrigin = CGPoint(x: element.x, y: element.y)
        }
        selectedID = id
        if let origin = dragOrigin {
            update {
                $0.x = min(360, max(-element.width + 12, origin.x + translation.width))
                $0.y = min(628, max(-element.height + 12, origin.y + translation.height))
            }
        }
        if ended { dragOrigin = nil }
    }
    private func colorComponents(_ color: Color) -> SheepPosterColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return .init(red: red, green: green, blue: blue)
    }
    private func addElement(_ kind: SheepPosterElementKind) {
        remember()
        let id = "custom.\(UUID().uuidString)"
        let title = kind == .text ? "自定义文字" : (kind == .image ? "自定义图片" : "自定义装饰")
        customization.additions.append(.init(id: id, title: title, kind: kind,
                                             text: kind == .text ? String(localized: "请输入文字") : "",
                                             x: 35, y: 330, width: kind == .image ? 80 : 260,
                                             height: kind == .text ? 45 : (kind == .image ? 80 : 5),
                                             font: .handwriting, fontSize: 30,
                                             order: (elements.map(\.order).max() ?? 10) + 1))
        selectedID = id
    }
    private func loadTemplates() {
        do { savedTemplates = try SheepSharePosterTemplateStore.load() }
        catch { errorMessage = String(localized: "读取模板失败，原文件已保留。") }
        #if DEBUG
        DevelopmentPosterAcceptance.recordTemplateEvent("load")
        #endif
    }
    private func saveTemplate(_ enteredName: String) {
        let name = String(enteredName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        #if DEBUG
        DevelopmentPosterAcceptance.recordTemplateEvent("save-requested", inputName: name)
        #endif
        guard !name.isEmpty else { return }
        do {
            var latest = try SheepSharePosterTemplateStore.load()
            latest.append(.init(id: UUID(), name: name, style: style.rawValue, template: template.rawValue,
                                customization: customization.reusable, updatedAt: .now))
            try SheepSharePosterTemplateStore.save(latest)
            savedTemplates = latest
            statusMessage = "模板已保存，可在“我的模板”中使用。"
            #if DEBUG
            DevelopmentPosterAcceptance.recordTemplateEvent("save-completed", inputName: name)
            #endif
        } catch {
            errorMessage = String(localized: "保存模板失败，请重试。")
            #if DEBUG
            DevelopmentPosterAcceptance.recordTemplateEvent("save-failed", inputName: name, error: error)
            #endif
        }
    }
    private func applyTemplate(_ saved: SheepSharePosterSavedTemplate) {
        guard let savedStyle = SheepSharePosterStyle(rawValue: saved.style),
              let savedTemplate = SheepSharePosterTemplate(rawValue: saved.template) else {
            errorMessage = String(localized: "此模板版本暂不支持。")
            return
        }
        style = savedStyle
        template = savedTemplate
        customization = saved.customization.reusable
        history.removeAll()
        selectedID = "earTag"
        statusMessage = "已套用模板，羊只资料来自当前羊只。"
    }
    private func deleteTemplate(_ saved: SheepSharePosterSavedTemplate) {
        do {
            var latest = try SheepSharePosterTemplateStore.load()
            latest.removeAll { $0.id == saved.id }
            try SheepSharePosterTemplateStore.save(latest)
            savedTemplates = latest
        } catch { errorMessage = String(localized: "删除模板失败，请重试。") }
    }
    @MainActor private func loadImage(_ selection: PhotosPickerItem?, for id: String?) async {
        guard let selection, let id else { return }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self),
                  let original = UIImage(data: data) else {
                errorMessage = String(localized: "无法读取这张图片。")
                return
            }
            let scale = min(1, 1920 / max(original.size.width, original.size.height))
            let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                original.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let png = resized.pngData() else { return }
            remember()
            if id == "photo" || id == "photo.backdrop" {
                customization.photoData = png
            } else {
                var value = customization.overrides[id] ?? .init()
                value.imageData = png
                customization.overrides[id] = value
            }
        } catch { errorMessage = String(localized: "读取图片失败，请重试。") }
        photoSelection = nil
    }
}

private struct SheepPosterTemplateNamePrompt: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var name: String
    let onSave: (String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.alert("保存为我的模板", isPresented: $isPresented) {
                TextField("模板名称", text: $name)
                    .accessibilityIdentifier("sheepPoster.editor.templateName")
                Button("保存") { onSave(name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) {}
            } message: {
                Text("保存排版和新增文字；下次使用时，耳号、照片和羊只资料自动更新。模板保存在这台设备上。")
            }
        } else {
            content.background {
                SheepPosterLegacyTemplateNamePrompt(isPresented: $isPresented, name: $name, onSave: onSave)
            }
        }
    }
}

/// iOS 17 dismisses the SwiftUI text-entry alert without invoking its save
/// action after the initially disabled action becomes enabled. Keep the same
/// system alert, but connect its native text field and UIAlertAction directly.
/// Newer systems continue using the original SwiftUI alert above.
private struct SheepPosterLegacyTemplateNamePrompt: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var name: String
    let onSave: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> AnchorController {
        let controller = AnchorController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.onAppear = { [weak controller, weak coordinator = context.coordinator] in
            guard let controller else { return }
            coordinator?.refresh(from: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: AnchorController, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async { [weak controller, weak coordinator = context.coordinator] in
            guard let controller else { return }
            coordinator?.refresh(from: controller)
        }
    }

    static func dismantleUIViewController(_ controller: AnchorController, coordinator: Coordinator) {
        controller.onAppear = nil
        coordinator.dismiss(animated: false)
    }

    final class AnchorController: UIViewController {
        var onAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SheepPosterLegacyTemplateNamePrompt
        private var prompt: UIAlertController?
        private var saveAction: UIAlertAction?

        init(parent: SheepPosterLegacyTemplateNamePrompt) { self.parent = parent }

        func refresh(from controller: UIViewController) {
            guard parent.isPresented else { dismiss(animated: true); return }
            guard prompt == nil, controller.viewIfLoaded?.window != nil,
                  controller.presentedViewController == nil else { return }
            let alert = UIAlertController(
                title: String(localized: "保存为我的模板"),
                message: String(localized: "保存排版和新增文字；下次使用时，耳号、照片和羊只资料自动更新。模板保存在这台设备上。"),
                preferredStyle: .alert
            )
            prompt = alert
            alert.addTextField { [weak self] field in
                field.placeholder = String(localized: "模板名称")
                field.accessibilityIdentifier = "sheepPoster.editor.templateName"
                field.text = self?.parent.name
                field.addTarget(self, action: #selector(Coordinator.nameChanged(_:)), for: .editingChanged)
            }
            let save = UIAlertAction(title: String(localized: "保存"), style: .default) { [weak self, weak alert] _ in
                guard let self, let alert else { return }
                // Read the text from the control that the user actually edited,
                // before dismissal can tear down the alert's text-field binding.
                let enteredName = alert.textFields?.first?.text ?? ""
                guard !enteredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let onSave = self.parent.onSave
                self.prompt = nil
                self.saveAction = nil
                self.parent.name = enteredName
                self.parent.isPresented = false
                // UIKit owns the alert's dismissal. Commit from the native
                // action itself, without depending on a second dismissal callback.
                onSave(enteredName)
            }
            save.isEnabled = !parent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            saveAction = save
            alert.addAction(save)
            alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel) { [weak self] _ in
                self?.prompt = nil
                self?.saveAction = nil
                self?.parent.isPresented = false
            })
            controller.present(alert, animated: true)
        }

        @objc private func nameChanged(_ field: UITextField) {
            let value = field.text ?? ""
            parent.name = value
            saveAction?.isEnabled = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        func dismiss(animated: Bool) {
            let alert = prompt
            prompt = nil
            saveAction = nil
            alert?.dismiss(animated: animated)
        }
    }
}

/// Own the nested presentation in SwiftUI instead of asking an embedded color
/// well to locate a presenter through the gallery and editor sheets.
private struct SheepPosterColorControl: View {
    let title: LocalizedStringKey
    let identifier: String
    @Binding var selection: Color
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Circle().fill(selection)
                    .overlay { Circle().strokeBorder(.secondary, lineWidth: 1) }
                    .frame(width: 28, height: 28)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                SheepPosterNativeColorPicker(selection: $selection, isPresented: $isPresented)
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isPresented = false }
                                .accessibilityIdentifier(identifier + ".done")
                        }
                    }
            }
        }
    }
}

private struct SheepPosterNativeColorPicker: UIViewControllerRepresentable {
    @Binding var selection: Color
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let controller = UIColorPickerViewController()
        controller.supportsAlpha = false
        controller.selectedColor = UIColor(selection)
        controller.delegate = context.coordinator
        controller.view.accessibilityIdentifier = "sheepPoster.nativeColorPicker"
        return controller
    }

    func updateUIViewController(_ controller: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
        let color = UIColor(selection)
        if !controller.selectedColor.isEqual(color) { controller.selectedColor = color }
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: SheepPosterNativeColorPicker
        init(parent: SheepPosterNativeColorPicker) { self.parent = parent }

        func colorPickerViewController(_ viewController: UIColorPickerViewController,
                                       didSelect color: UIColor, continuously: Bool) {
            parent.selection = Color(uiColor: color)
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            parent.isPresented = false
        }
    }
}
