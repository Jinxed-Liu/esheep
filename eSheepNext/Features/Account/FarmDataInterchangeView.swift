import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct FarmDataInterchangeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sheep: [SheepRecord]
    @Query private var pens: [PenRecord]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var isImporting = false
    @State private var preview: FarmImportPreview?
    @State private var isExporting = false
    @State private var exportDocument: FarmInterchangeDocument?
    @State private var message: String?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil } }

    var body: some View {
        List {
            Section("导入") {
                Button("选择 XLSX、CSV 或 JSON") { isImporting = true }
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
                Text("先在本机安全复制并校验，展示重复项和错误；确认后才通过牧场命令管道分批写入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let preview {
                Section("导入预览") {
                    LabeledContent("可导入", value: "\(preview.acceptedRows.count) 条")
                    LabeledContent("重复", value: "\(preview.duplicateRowNumbers.count) 条")
                    LabeledContent("错误", value: "\(preview.errorCount) 条")
                    ForEach(preview.issues.prefix(20)) { issue in
                        Label("第 \(issue.rowNumber) 行 · \(issue.message)", systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(issue.severity == .error ? .red : .secondary)
                    }
                    Button("确认导入 \(preview.acceptedRows.count) 条") { commit(preview) }
                        .disabled(preview.acceptedRows.isEmpty)
                }
            }
            Section("导出") {
                Button("导出真实 XLSX 工作簿") { exportXLSX() }
                    .disabled(farmSheep.isEmpty || !CapabilitySet(role: farm.role).allows(.exportFarm))
                Text("生成标准 OOXML .xlsx 文件，不会把 CSV 改名伪装成 Excel。受邀牧场按当前导出权限裁剪。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("导入与导出")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.officeOpenXMLSpreadsheet, .commaSeparatedText, .json]) { result in
            importFile(result)
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .officeOpenXMLSpreadsheet, defaultFilename: fileName()) { result in
            if case .failure(let error) = result { message = "导出失败：\(error.localizedDescription)" }
            else { message = "已生成真实 XLSX 工作簿。" }
        }
        .alert("数据交换", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("完成", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try SecureImportFileLoader.load(from: url)
            preview = try FarmDataInterchange.preview(data: data, fileExtension: url.pathExtension, existingEarTags: Set(farmSheep.map(\.earTag)))
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }

    private func commit(_ preview: FarmImportPreview) {
        do {
            let result = try FarmImportCommitService.commit(preview, account: account, farm: farm, context: modelContext)
            self.preview = nil
            message = "已导入 \(result.importedCount) 条，跳过 \(result.skippedCount) 条。离线时操作会留在待同步队列。"
        } catch { message = "写入失败：\(error.localizedDescription)" }
    }

    private func exportXLSX() {
        do {
            exportDocument = FarmInterchangeDocument(data: try FarmDataInterchange.xlsxData(farmID: farm.id, sheep: sheep, pens: pens))
            isExporting = true
        } catch { message = "导出失败：\(error.localizedDescription)" }
    }

    private func fileName() -> String {
        let safe = farm.name.replacingOccurrences(of: "/", with: "-")
        return "牧场档案_\(safe)_\(Date.now.formatted(.iso8601.year().month().day())).xlsx"
    }
}
