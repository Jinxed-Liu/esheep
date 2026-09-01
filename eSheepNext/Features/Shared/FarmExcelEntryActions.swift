import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct FarmExcelEntryActions: View {
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let sheetNames: Set<String>

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var templateDocument: FarmInterchangeDocument?
    @State private var preview: FarmExcelPreview?
    @State private var message: String?

    var body: some View {
        Menu {
            Button("下载本页 Excel 模板", systemImage: "arrow.down.doc") { exportTemplate() }
            Button("导入本页 Excel", systemImage: "arrow.up.doc") { isImporting = true }
        } label: {
            Label("Excel", systemImage: "tablecells")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("Excel 模板与导入")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.officeOpenXMLSpreadsheet]) { result in
            importWorkbook(result)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: templateDocument,
            contentType: .officeOpenXMLSpreadsheet,
            defaultFilename: fileName
        ) { result in
            if case .failure(let error) = result { message = "模板导出失败：\(error.localizedDescription)" }
        }
        .sheet(item: $preview) { preview in
            NavigationStack {
                FarmExcelPagePreviewView(preview: preview, onCommit: { commit(preview) })
            }
        }
        .alert("Excel 导入", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(message ?? ""))
        }
    }

    private var fileName: String {
        let label = sheetNames.sorted().joined(separator: "_")
        return "eSheepPlus_\(label)_录入模板_v\(FarmExcelImportService.templateVersion).xlsx"
    }

    private func exportTemplate() {
        do {
            templateDocument = FarmInterchangeDocument(data: try FarmExcelImportService.templateData(sheetNames: sheetNames))
            isExporting = true
        } catch { message = error.localizedDescription }
    }

    private func importWorkbook(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try SecureImportFileLoader.load(from: url)
            preview = try FarmExcelImportService.preview(data: data, farm: farm, context: modelContext, allowedSheetNames: sheetNames)
        } catch { message = "预检失败：\(error.localizedDescription)" }
    }

    @discardableResult
    private func commit(_ preview: FarmExcelPreview) -> Bool {
        do {
            let count = try FarmExcelImportService.commit(preview, account: account, farm: farm, context: modelContext)
            self.preview = nil
            if preview.removalBatchSummaries.isEmpty {
                message = "已导入 \(count) 条记录。"
            } else {
                message = "已导入 \(count) 条羊只记录；同批出售只保留一笔总售卖金额。"
            }
            return true
        } catch {
            message = "整批未写入：\(error.localizedDescription)"
            return false
        }
    }
}

private struct FarmExcelPagePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: FarmExcelPreview
    let onCommit: () -> Bool
    @State private var isCommitting = false

    var body: some View {
        List {
            Section("核对结果") {
                LabeledContent("Excel 数据行", value: "\(preview.rows.count) 行")
                LabeledContent("待写入记录", value: "\(preview.expandedRecordCount) 条")
                LabeledContent("阻断错误", value: "\(preview.errorCount) 条")
                LabeledContent("提醒", value: "\(preview.warningCount) 条")
            }
            if isCommitting {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在写入并校准羊群历史…")
                    }
                }
            }
            ForEach(preview.summaries) { item in
                LabeledContent(item.name, value: "\(item.rowCount) 条")
            }
            if !preview.removalBatchSummaries.isEmpty {
                Section {
                    ForEach(preview.removalBatchSummaries) { batch in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("第 \(batch.rowNumber) 行 · \(batch.kind)")
                                Spacer()
                                Text("\(batch.sheepCount) 只")
                                    .foregroundStyle(.secondary)
                            }
                            if let total = batch.totalAmountText {
                                LabeledContent("总售卖金额", value: total)
                                    .font(.subheadline)
                            } else {
                                Text("不涉及售卖金额")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("离场批次")
                } footer: {
                    Text("每个出售批次只有一笔总售卖金额，不拆分或推算单羊价格。")
                }
            }
            if !preview.issues.isEmpty {
                Section("需要处理") {
                    ForEach(preview.issues) { issue in
                        Label("\(issue.sheet) 第 \(issue.row) 行 · \(issue.field)：\(issue.message)", systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(issue.severity == .error ? .red : .secondary)
                    }
                }
            }
        }
        .navigationTitle("Excel 导入预检")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .disabled(isCommitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: beginCommit) {
                    if isCommitting {
                        ProgressView()
                    } else {
                        Text("确认导入")
                    }
                }
                .disabled(!preview.canCommit || isCommitting)
            }
        }
        .interactiveDismissDisabled(isCommitting)
    }

    private func beginCommit() {
        guard !isCommitting else { return }
        isCommitting = true
        Task { @MainActor in
            // 先让进度状态完成一帧渲染，再进入受事务保护的同步写入。
            await Task.yield()
            if !onCommit() {
                isCommitting = false
            }
        }
    }
}

extension View {
    func farmExcelImport(account: AccountProfile, farm: FarmRecord, sheets: Set<String>) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FarmExcelEntryActions(account: account, farm: farm, sheetNames: sheets)
            }
        }
    }
}
