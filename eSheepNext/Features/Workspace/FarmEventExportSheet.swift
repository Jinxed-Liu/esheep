import SwiftData
import SwiftUI

/// 首页只在用户明确点击导出时读取事件快照，避免让首页长期维护全部历史记录查询。
struct FarmEventExportLauncher: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let farmID: UUID
    let farmName: String

    @State private var state = FarmEventExportLoadState.loading
    @State private var reloadGeneration = 0

    var body: some View {
        Group {
            switch state {
            case .loading:
                NavigationStack {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在整理可导出的记录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("记录导出")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { closeToolbar }
                }
            case .loaded(let events):
                FarmEventExportSheet(farmName: farmName, events: events)
            case .failed(let message):
                NavigationStack {
                    ContentUnavailableView {
                        Label("无法读取记录", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(LocalizedStringKey(message))
                    } actions: {
                        Button("重试") { reloadGeneration += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                    .navigationTitle("记录导出")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { closeToolbar }
                }
            }
        }
        .task(id: reloadGeneration) { await load() }
    }

    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
        }
    }

    @MainActor
    private func load() async {
        state = .loading
        do {
            let events = try await FarmEventHistoryActor(container: modelContext.container).load(farmID: farmID)
            guard !Task.isCancelled else { return }
            state = .loaded(events)
        } catch is CancellationError {
            return
        } catch {
            state = .failed("整理事件记录失败：\(error.localizedDescription)")
        }
    }
}

private enum FarmEventExportLoadState {
    case loading
    case loaded([FarmEventSnapshot])
    case failed(String)
}

struct FarmEventExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let farmName: String
    let events: [FarmEventSnapshot]

    @State private var scope: FarmEventExportScope
    @State private var usesDateRange = false
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var document: FarmEventCSVExportDocument?
    @State private var exportFileName = "事件记录.csv"
    @State private var exportedCount = 0
    @State private var isExporting = false
    @State private var message: String?

    init(
        farmName: String,
        events: [FarmEventSnapshot],
        initialScope: FarmEventExportScope = .all,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.farmName = farmName
        self.events = events
        _scope = State(initialValue: initialScope)
        _endDate = State(initialValue: now)
        _startDate = State(initialValue: calendar.date(byAdding: .month, value: -1, to: now) ?? now)
    }

    private var selectedRange: FarmEventExportRange {
        usesDateRange ? .days(from: startDate, through: endDate) : .all
    }

    private var matchingCount: Int {
        FarmEventCSVExport.matchingEventCount(events, scope: scope, range: selectedRange)
    }

    var body: some View {
        let previewCount = matchingCount
        NavigationStack {
            Form {
                Section("记录类型") {
                    Picker("导出内容", selection: $scope) {
                        ForEach(FarmEventExportScope.allCases) { item in
                            Label(LocalizedStringKey(item.displayName), systemImage: item.symbol).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Toggle("限定发生时间", isOn: $usesDateRange)
                    if usesDateRange {
                        DatePicker("开始日期", selection: $startDate, in: ...endDate, displayedComponents: .date)
                        DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                } header: {
                    Text("时间范围")
                } footer: {
                    Text("开始日和结束日均包含整天；筛选依据业务发生时间，不使用录入时间。")
                }

                Section("导出预览") {
                    LabeledContent("记录类型", value: scope.displayName)
                    LabeledContent("符合条件", value: "\(previewCount) 条")
                    LabeledContent("排序", value: "发生时间倒序")
                    Button("导出 \(previewCount) 条 CSV", systemImage: "square.and.arrow.up") {
                        prepareExport()
                    }
                    .disabled(previewCount == 0)
                }

                Section {
                    Text("文件为带 UTF-8 BOM 的标准 CSV，并保留各记录自己的结构化字段。可直接用 Excel 打开，但不是 XLSX 工作簿。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导出事件记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $isExporting,
                document: document,
                contentType: .commaSeparatedText,
                defaultFilename: exportFileName
            ) { result in
                switch result {
                case .success:
                    message = "已按发生时间倒序导出 \(exportedCount) 条\(scope.displayName)。"
                case .failure(let error):
                    message = "导出失败：\(error.localizedDescription)"
                }
            }
            .alert("记录导出", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("完成", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(message ?? ""))
            }
        }
    }

    private func prepareExport() {
        let range = selectedRange
        let matchingEvents = FarmEventCSVExport.matchingEvents(events, scope: scope, range: range)
        guard !matchingEvents.isEmpty else {
            message = "当前类型和时间范围内没有可导出的记录。"
            return
        }
        document = FarmEventCSVExportDocument(
            data: FarmEventCSVExport.csvData(events: matchingEvents, scope: .all, range: .all)
        )
        exportFileName = FarmEventCSVExport.fileName(farmName: farmName, scope: scope, range: range)
        exportedCount = matchingEvents.count
        isExporting = true
    }
}
