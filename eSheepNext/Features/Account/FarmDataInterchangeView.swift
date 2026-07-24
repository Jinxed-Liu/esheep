import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum FarmDataTask: Equatable {
    case importData
    case exportData
    case localBackup

    var title: String {
        switch self {
        case .importData: "导入数据"
        case .exportData: "导出牧场数据"
        case .localBackup: "本地备份与恢复"
        }
    }
}

struct FarmDataInterchangeView: View {
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse) private var conflicts: [SyncConflictRecord]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var storageSnapshot: AppStorageSnapshot?
    @State private var isClearingTemporaryData = false
    @State private var storageMessage: String?

    private var unresolvedConflictCount: Int {
        conflicts.count {
            $0.farmID == farm.id
                && ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue
                    || $0.statusRawValue == SyncConflictStatus.quarantined.rawValue)
        }
    }

    private var policy: SettingsVisibilityPolicy {
        SettingsVisibilityPolicy(
            role: farm.role,
            cloudEnabled: CloudFeatureConfiguration.isEnabled,
            subscriptionEnabled: SubscriptionFeatureConfiguration.isEnabled,
            unresolvedConflictCount: unresolvedConflictCount
        )
    }

    var body: some View {
        List {
            Section("设备存储") {
                if let storageSnapshot {
                    LabeledContent("牧场资料", value: formatted(storageSnapshot.protectedDataBytes))
                    LabeledContent("导出与文档", value: formatted(storageSnapshot.documentBytes))
                    LabeledContent("临时文件", value: formatted(storageSnapshot.temporaryBytes))
                    LabeledContent("合计", value: formatted(storageSnapshot.totalBytes))
                        .fontWeight(.semibold)
                } else {
                    ProgressView("正在计算占用空间")
                }

                Button(isClearingTemporaryData ? "正在清理…" : "清理临时文件") {
                    clearTemporaryData()
                }
                .disabled(isClearingTemporaryData || storageSnapshot == nil)

                Text("清理只会移除可重新生成的临时文件，不会删除牧场记录、照片、备份或未同步操作。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("牧场数据") {
                if policy.shows(.importData) {
                    NavigationLink {
                        FarmDataTaskView(account: account, farm: farm, task: .importData)
                    } label: {
                        SettingsRowLabel(
                            title: "导入数据",
                            subtitle: "全功能 Excel 与旧版档案",
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }

                if policy.shows(.exportData) {
                    NavigationLink {
                        FarmDataTaskView(account: account, farm: farm, task: .exportData)
                    } label: {
                        SettingsRowLabel(
                            title: "导出牧场数据",
                            subtitle: "生成可查看的 Excel 工作簿",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }

                if policy.shows(.localBackup) {
                    NavigationLink {
                        FarmDataTaskView(account: account, farm: farm, task: .localBackup)
                    } label: {
                        SettingsRowLabel(
                            title: "本地备份与恢复",
                            subtitle: "导出备份或恢复到当前牧场",
                            systemImage: "externaldrive"
                        )
                    }
                }

                if policy.shows(.cloudRecovery) {
                    NavigationLink {
                        CloudRecoveryCenterView(account: account, farm: farm)
                    } label: {
                        SettingsRowLabel(
                            title: "云端恢复",
                            subtitle: "恢复包与恢复点",
                            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                        )
                    }
                }

                if policy.shows(.dataConflicts) {
                    NavigationLink {
                        CloudConflictCenterView(account: account, farm: farm)
                    } label: {
                        SettingsRowLabel(
                            title: "数据异常处理",
                            subtitle: "\(unresolvedConflictCount) 条记录需要选择保留版本",
                            systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                        )
                    }
                }
            }
        }
        .navigationTitle("数据与存储")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            storageSnapshot = await AppStorageUsageService.shared.snapshot()
        }
        .alert("数据与存储", isPresented: Binding(
            get: { storageMessage != nil },
            set: { if !$0 { storageMessage = nil } }
        )) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(storageMessage ?? "")
        }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func clearTemporaryData() {
        guard !isClearingTemporaryData else { return }
        isClearingTemporaryData = true
        Task {
            let before = storageSnapshot?.temporaryBytes ?? 0
            let updated = await AppStorageUsageService.shared.clearTemporaryData()
            storageSnapshot = updated
            isClearingTemporaryData = false
            let released = max(before - updated.temporaryBytes, 0)
            storageMessage = released > 0
                ? "已释放 \(formatted(released)) 临时空间。"
                : "当前没有需要清理的临时文件。"
        }
    }
}

private struct FarmDataTaskView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sheep: [SheepRecord]
    @Query private var pens: [PenRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let task: FarmDataTask

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
            if task == .importData {
                Section("全功能 Excel") {
                    Button("下载录入模板") { exportExcelTemplate() }
                    Button("选择填好的 Excel 文件") { isImportingExcelTemplate = true }
                    Text("适用于圈舍、羊只、称重、繁殖、饲喂、健康和提醒等完整生产数据。确认前不会写入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let excelPreview {
                    Section("导入检查") {
                        LabeledContent("待写入", value: "\(excelPreview.rows.count) 条")
                        LabeledContent("需要修正", value: "\(excelPreview.errorCount) 条")
                        LabeledContent("提醒", value: "\(excelPreview.warningCount) 条")
                        ForEach(excelPreview.summaries) { item in
                            LabeledContent(item.name, value: "\(item.rowCount) 条")
                        }
                        ForEach(excelPreview.issues.prefix(40)) { issue in
                            Label("\(issue.sheet) 第 \(issue.row) 行 · \(issue.field)：\(issue.message)", systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(issue.severity == .error ? .red : .secondary)
                        }
                        Button("确认导入 \(excelPreview.rows.count) 条") { commitExcel(excelPreview) }
                            .disabled(!excelPreview.canCommit)
                    }
                }

                Section("旧版羊只档案") {
                    Button("选择 XLSX、CSV 或 JSON 文件") { isImporting = true }
                    Text("用于导入旧版单表羊只档案。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let preview {
                    Section("导入检查") {
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
            }

            if task == .exportData {
                Section {
                    if farmSheep.isEmpty {
                        ContentUnavailableView(
                            "暂无可导出数据",
                            systemImage: "doc",
                            description: Text("录入羊只数据后即可导出。")
                        )
                    } else {
                        Button("导出 Excel 工作簿") { exportXLSX() }
                        Text("导出的文件可用于归档和人工查看。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if task == .localBackup {
                Section("本地备份") {
                    if CapabilitySet(role: farm.role).allows(.exportFarm) {
                        Button("导出完整备份", action: exportBackup)
                    }
                    if CapabilitySet(role: farm.role).allows(.recordProduction) {
                        Button("选择备份并检查") { isRestoringBackup = true }
                    }
                    Text("完整备份用于恢复业务记录；Excel 文件仅用于查看，不可替代备份。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let backupPreview {
                    Section("恢复检查") {
                        LabeledContent("来源牧场", value: backupPreview.envelope.payload.farm.name)
                        LabeledContent("备份时间") { Text(backupPreview.envelope.payload.exportedAt, format: .dateTime.year().month().day().hour().minute()) }
                        Text(backupPreview.summary).font(.footnote).foregroundStyle(.secondary)
                        Button("恢复到当前空牧场") { restoreBackup(backupPreview) }
                    }
                }
            }
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
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
