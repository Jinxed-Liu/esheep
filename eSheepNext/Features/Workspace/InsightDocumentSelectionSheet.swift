import SwiftUI

/// The document is a one-time seed for an explicit selection draft. Cancel never
/// changes its caller's draft, and only a fully validated selection is returned.
struct InsightDocumentSelectionSheet: View {
    let document: PendingInsightDocument
    let onSelect: (PendingInsightDocument) -> Void
    let onCancel: () -> Void
    @State private var selectedSections: Set<String>
    @State private var rangeStarts: [String: Int]
    @State private var rangeEnds: [String: Int]
    @State private var acknowledgesPartialContent: Bool
    @State private var submissionError: String?

    init(document: PendingInsightDocument, onSelect: @escaping (PendingInsightDocument) -> Void, onCancel: @escaping () -> Void) {
        self.document = document
        self.onSelect = onSelect
        self.onCancel = onCancel
        _selectedSections = State(initialValue: Set(document.selection.map(\.sectionID)))
        _rangeStarts = State(initialValue: Dictionary(document.selection.map { ($0.sectionID, $0.firstBlock) }, uniquingKeysWith: min))
        _rangeEnds = State(initialValue: Dictionary(document.selection.map { ($0.sectionID, $0.lastBlock) }, uniquingKeysWith: max))
        _acknowledgesPartialContent = State(initialValue: document.acknowledgesPartialContent)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(document.fileName).font(.headline)
                    Text(verbatim: "已解析 \(document.sections.filter(\.isReadable).count) / \(document.sections.count) 个页面或文本区域。请选择本次发送范围。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !document.issues.isEmpty {
                    Section {
                        ForEach(document.issues) { issue in
                            Label { Text(issue.message) } icon: { Image(systemName: "exclamationmark.triangle") }
                                .font(.subheadline)
                        }
                    } header: { Text(verbatim: "解析缺口") }
                }
                Section {
                    ForEach(document.sections) { section in
                        sectionRow(section)
                    }
                } header: { Text(verbatim: "选择页、工作表或文本范围") }
                Section {
                    Toggle(isOn: $acknowledgesPartialContent) {
                        Text(verbatim: "我确认本次只发送已选内容，解析缺口不会补充为全文。")
                    }
                    Text(verbatim: "文件分析不会导入牧场数据。内容将随本次消息提交给当前已授权的 AI 服务，原文件和引用范围仅加密保存在本机。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error = selectionError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if let submissionError {
                        Text(submissionError).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(Text(verbatim: "选择文件内容"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Text(verbatim: "取消") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) { Text(verbatim: "添加选定内容") }
                        .disabled(selectedDocument == nil)
                }
            }
        }
    }

    private func sectionRow(_ section: InsightDocumentSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { selectedSections.contains(section.id) },
                set: { selected in
                    if selected { selectedSections.insert(section.id) }
                    else { selectedSections.remove(section.id) }
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).font(.headline)
                    Text(verbatim: section.isReadable ? "可选择范围 1–\(section.totalBlockCount)" : "无法读取，请重新导出或完成 OCR 后重选")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!section.isReadable)
            if selectedSections.contains(section.id), section.totalBlockCount > 1 {
                HStack {
                    Text(verbatim: "从")
                    TextField("", value: bound(section, isStart: true), format: .number)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(verbatim: "开始行或段落"))
                    Text(verbatim: "到")
                    TextField("", value: bound(section, isStart: false), format: .number)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(verbatim: "结束行或段落"))
                }
            }
            DisclosureGroup {
                ForEach(Array(section.blocks.prefix(3))) { block in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.citation).font(.caption).foregroundStyle(.secondary)
                        Text(String(block.text.prefix(500))).font(.caption).lineLimit(5).textSelection(.enabled)
                    }
                }
                Text(verbatim: "以上仅预览前三条文字，每条最多 500 字；发送内容由所选范围决定，超过容量会要求缩小范围。")
                    .font(.caption2).foregroundStyle(.secondary)
            } label: {
                Text(verbatim: "预览文字与引用")
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private func bound(_ section: InsightDocumentSection, isStart: Bool) -> Binding<Int> {
        Binding(
            get: { isStart ? rangeStarts[section.id] ?? 1 : rangeEnds[section.id] ?? section.totalBlockCount },
            set: { value in
                if isStart { rangeStarts[section.id] = value }
                else { rangeEnds[section.id] = value }
            }
        )
    }

    private var ranges: [InsightDocumentRange] {
        document.sections.filter { selectedSections.contains($0.id) }.map {
            .init(sectionID: $0.id, firstBlock: rangeStarts[$0.id] ?? 1, lastBlock: rangeEnds[$0.id] ?? $0.totalBlockCount)
        }
    }

    private var selectedDocument: PendingInsightDocument? {
        try? document.selecting(ranges, acknowledgesPartialContent: acknowledgesPartialContent)
    }

    private var selectionError: String? {
        guard !ranges.isEmpty else { return "请选择至少一个可读取区域；扫描页需先完成 OCR。" }
        do {
            _ = try document.selecting(ranges, acknowledgesPartialContent: acknowledgesPartialContent)
            return nil
        } catch { return error.localizedDescription }
    }

    private func confirm() {
        do { onSelect(try document.selecting(ranges, acknowledgesPartialContent: acknowledgesPartialContent)) }
        catch { submissionError = error.localizedDescription }
    }
}
