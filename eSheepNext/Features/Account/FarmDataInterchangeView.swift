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
    @State private var isImportingExcelTemplate = false
    @State private var excelPreview: FarmExcelPreview?
    @State private var isExportingExcelTemplate = false
    @State private var excelTemplateDocument: FarmInterchangeDocument?
    @State private var isExporting = false
    @State private var exportDocument: FarmInterchangeDocument?
    @State private var message: String?
    @State private var isExportingBackup = false
    @State private var backupDocument: FarmInterchangeDocument?
    @State private var isRestoringBackup = false
    @State private var backupPreview: FarmBackupPreview?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil } }

    var body: some View {
        List {
            Section("Excel 全功能录入") {
                Button("下载全功能 Excel 模板") { exportExcelTemplate() }
                Button("选择填好的 Excel 模板") { isImportingExcelTemplate = true }
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
                Text("模板覆盖圈舍、羊只、称重、断奶、转群、离场、生产批次、饲喂、健康库存、繁殖冻精、配种方案、备注和提醒规则。先核对整份文件，确认后才原子写入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let excelPreview {
                Section("Excel 预检") {
                    LabeledContent("待写入", value: "\(excelPreview.rows.count) 条")
                    LabeledContent("阻断错误", value: "\(excelPreview.errorCount) 条")
                    LabeledContent("提醒", value: "\(excelPreview.warningCount) 条")
                    ForEach(excelPreview.summaries) { item in
                        LabeledContent(item.name, value: "\(item.rowCount) 条")
                    }
                    ForEach(excelPreview.issues.prefix(40)) { issue in
                        Label("\(issue.sheet) 第 \(issue.row) 行 · \(issue.field)：\(issue.message)", systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(issue.severity == .error ? .red : .secondary)
                    }
                    Button("确认并原子导入 \(excelPreview.rows.count) 条") { commitExcel(excelPreview) }
                        .disabled(!excelPreview.canCommit)
                }
            }
            Section("旧版羊只档案导入") {
                Button("选择旧版 XLSX、CSV 或 JSON") { isImporting = true }
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
                Text("兼容旧的单表羊只档案文件；新录入建议使用上方全功能模板。")
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
            Section("完整本地备份") {
                Button("导出版本化 JSON 备份", action: exportBackup)
                    .disabled(!CapabilitySet(role: farm.role).allows(.exportFarm))
                Button("选择备份并校验") { isRestoringBackup = true }
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
                Text("备份包含牧场、圈舍、羊只、称重、转群、离场、撤销记录和必要审计；XLSX/CSV 仍只用于人工查看。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let backupPreview {
                Section("恢复预览") {
                    LabeledContent("来源牧场", value: backupPreview.envelope.payload.farm.name)
                    LabeledContent("导出时间") { Text(backupPreview.envelope.payload.exportedAt, format: .dateTime.year().month().day().hour().minute()) }
                    Text(backupPreview.summary).font(.footnote).foregroundStyle(.secondary)
                    Button("恢复到当前空牧场") { restoreBackup(backupPreview) }
                }
            }
        }
        .navigationTitle("导入与导出")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.officeOpenXMLSpreadsheet, .commaSeparatedText, .json]) { result in
            importFile(result)
        }
        .fileImporter(isPresented: $isImportingExcelTemplate, allowedContentTypes: [.officeOpenXMLSpreadsheet]) { result in
            importExcelTemplate(result)
        }
        .fileExporter(isPresented: $isExportingExcelTemplate, document: excelTemplateDocument, contentType: .officeOpenXMLSpreadsheet, defaultFilename: "eSheepNext全功能录入模板_v\(FarmExcelImportService.templateVersion).xlsx") { result in
            if case .failure(let error) = result { message = "模板导出失败：\(error.localizedDescription)" }
            else { message = "全功能 Excel 模板已导出。填写后回到此页执行预检。" }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .officeOpenXMLSpreadsheet, defaultFilename: fileName()) { result in
            if case .failure(let error) = result { message = "导出失败：\(error.localizedDescription)" }
            else { message = "已生成真实 XLSX 工作簿。" }
        }
        .fileExporter(isPresented: $isExportingBackup, document: backupDocument, contentType: .json, defaultFilename: backupFileName()) { result in
            if case .failure(let error) = result { message = "备份导出失败：\(error.localizedDescription)" }
            else { message = "完整本地备份已导出。" }
        }
        .fileImporter(isPresented: $isRestoringBackup, allowedContentTypes: [.json]) { result in
            previewBackup(result)
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

    private func exportExcelTemplate() {
        do {
            excelTemplateDocument = FarmInterchangeDocument(data: try FarmExcelImportService.templateData())
            isExportingExcelTemplate = true
        } catch { message = "模板生成失败：\(error.localizedDescription)" }
    }

    private func importExcelTemplate(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try SecureImportFileLoader.load(from: url)
            excelPreview = try FarmExcelImportService.preview(data: data, farm: farm, context: modelContext)
        } catch { message = "Excel 预检失败：\(error.localizedDescription)" }
    }

    private func commitExcel(_ preview: FarmExcelPreview) {
        do {
            let count = try FarmExcelImportService.commit(preview, account: account, farm: farm, context: modelContext)
            excelPreview = nil
            message = "已原子导入 \(count) 条录入数据，并生成对应审计和待同步记录。"
        } catch { message = "整批未写入：\(error.localizedDescription)" }
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

    private func exportBackup() {
        do {
            backupDocument = FarmInterchangeDocument(data: try FarmLocalBackupService.export(farmID: farm.id, context: modelContext))
            isExportingBackup = true
        } catch { message = "备份导出失败：\(error.localizedDescription)" }
    }

    private func previewBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try SecureImportFileLoader.load(from: url)
            backupPreview = try FarmLocalBackupService.preview(data: data)
        } catch { message = "备份校验失败：\(error.localizedDescription)" }
    }

    private func restoreBackup(_ preview: FarmBackupPreview) {
        do {
            let result = try FarmLocalBackupService.restore(preview, into: farm, account: account, context: modelContext)
            backupPreview = nil
            message = result.alreadyRestored ? "该备份已经恢复过，没有重复写入。" : "已恢复 \(result.restoredCount) 条本地业务记录。"
        } catch { message = "恢复失败：\(error.localizedDescription)" }
    }

    private func backupFileName() -> String {
        let safe = farm.name.replacingOccurrences(of: "/", with: "-")
        return "eSheep完整备份_\(safe)_\(Date.now.formatted(.iso8601.year().month().day())).json"
    }
}
