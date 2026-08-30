import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum FarmDataTask: Equatable {
    case importData
    case exportData
    case localBackup

    var title: LocalizedStringKey {
        switch self {
        case .importData: "导入数据"
        case .exportData: "导出牧场数据"
        case .localBackup: "完整备份与恢复"
        }
    }
}

private enum FarmDataTaskMessage {
    case importFailed(String)
    case templateExportFailed(String)
    case templateExported
    case templateGenerationFailed(String)
    case excelPreviewFailed(String)
    case excelImported(Int)
    case excelImportFailed(String)
    case imported(imported: Int, skipped: Int)
    case writeFailed(String)
    case exportFailed(String)
    case exported
    case backupExportFailed(String)
    case backupExported
    case backupPending(Int)
    case backupValidationFailed(String)
    case restored(entityCount: Int, photoCount: Int)
    case restoreFailed(String)

    @ViewBuilder
    var text: some View {
        switch self {
        case .importFailed(let error):
            Text("导入失败：\(error)")
        case .templateExportFailed(let error):
            Text("模板导出失败：\(error)")
        case .templateExported:
            Text("全功能 Excel 模板已导出。填写后回到此页执行预检。")
        case .templateGenerationFailed(let error):
            Text("模板生成失败：\(error)")
        case .excelPreviewFailed(let error):
            Text("Excel 预检失败：\(error)")
        case .excelImported(let count):
            Text("已原子导入 \(count) 条录入数据，并生成对应审计和待同步记录。")
        case .excelImportFailed(let error):
            Text("整批未写入：\(error)")
        case .imported(let imported, let skipped):
            Text("已导入 \(imported) 条，跳过 \(skipped) 条。离线时操作会留在待同步队列。")
        case .writeFailed(let error):
            Text("写入失败：\(error)")
        case .exportFailed(let error):
            Text("导出失败：\(error)")
        case .exported:
            Text("已生成真实 XLSX 工作簿。")
        case .backupExportFailed(let error):
            Text("备份导出失败：\(error)")
        case .backupExported:
            Text("完整备份已导出。请把文件保存到另一台设备或独立存储位置。")
        case .backupPending(let count):
            Text("仍有 \(count) 条记录等待上传。请联网同步完成后再导出完整备份。")
        case .backupValidationFailed(let error):
            Text("备份校验失败：\(error)")
        case .restored(let entityCount, let photoCount):
            Text("已恢复为新的仅本机牧场：\(entityCount) 条业务记录、\(photoCount) 张照片。")
        case .restoreFailed(let error):
            Text("恢复失败：\(error)")
        }
    }
}

struct FarmDataInterchangeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse) private var conflicts: [SyncConflictRecord]
    @Query private var storageProfiles: [FarmStorageProfile]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var storageSnapshot: AppStorageSnapshot?
    @State private var isClearingTemporaryData = false
    @State private var isCleaningRebuilds = false
    @State private var isReviewingRebuildCleanup = false
    @State private var localInventory: LocalStorageInventory?
    @State private var storageMessage: StorageMessage?

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm

        let farmID = farm.id
        _conflicts = Query(
            filter: #Predicate<SyncConflictRecord> { $0.farmID == farmID },
            sort: \.detectedAt,
            order: .reverse
        )
        _storageProfiles = Query(
            filter: #Predicate<FarmStorageProfile> { $0.farmID == farmID }
        )
    }

    private enum StorageMessage {
        case released(String)
        case nothingToClean
        case inventoryFailed(String)
        case cleaned(String, String)
        case cleanupFailed(String)

        @ViewBuilder
        var text: some View {
            switch self {
            case .released(let amount):
                Text("已释放 \(amount) 临时空间。")
            case .nothingToClean:
                Text("当前没有需要清理的临时文件。")
            case .inventoryFailed(let error):
                Text("存储盘点失败：\(error)")
            case .cleaned(let amount, let path):
                Text("已释放 \(amount)。小型诊断归档：\(path)")
            case .cleanupFailed(let error):
                Text("未清理：\(error)")
            }
        }
    }

    private var unresolvedConflictCount: Int {
        conflicts.count {
            $0.statusRawValue == SyncConflictStatus.unresolved.rawValue
                || $0.statusRawValue == SyncConflictStatus.quarantined.rawValue
        }
    }

    private var policy: SettingsVisibilityPolicy {
        SettingsVisibilityPolicy(
            role: farm.role,
            cloudEnabled: SupabaseAccountConfiguration.isConfigured,
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

                Button(isClearingTemporaryData ? LocalizedStringKey("正在清理…") : LocalizedStringKey("清理临时文件")) {
                    clearTemporaryData()
                }
                .disabled(isClearingTemporaryData || storageSnapshot == nil)

                Text("清理只会移除可重新生成的临时文件，不会删除牧场记录、照片、备份或未同步操作。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG && ESHEEP_INTERNAL_ACCEPTANCE_UI
            if let localInventory,
               !localInventory.cleanupCandidates.isEmpty {
                Section("可重建旧副本") {
                    LabeledContent(
                        "旧重建与迁移工作区",
                        value: formatted(localInventory.candidateBytes)
                    )
                    LabeledContent(
                        "候选目录",
                        value: localInventory.cleanupCandidates.count.formatted()
                    )
                    Button(
                        isCleaningRebuilds
                            ? "正在生成诊断归档并清理…"
                            : "检查旧副本并清理",
                        role: .destructive
                    ) {
                        isReviewingRebuildCleanup = true
                    }
                    .disabled(isCleaningRebuilds)

                    Text("先保留状态、牧场、错误、文件清单和 SHA-256 诊断归档，再移除可重建目录。SwiftData、WAL/SHM、照片、备份、Outbox 与云端回执不在候选范围。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #endif

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
                            title: "完整备份与恢复",
                            subtitle: "业务记录、历史与照片",
                            systemImage: "externaldrive"
                        )
                    }
                }

                if policy.shows(.dataConflicts) {
                    NavigationLink {
                        FarmConflictCenterView(account: account, farm: farm)
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
            await refreshStorage()
        }
        .sheet(isPresented: $isReviewingRebuildCleanup) {
            if let localInventory {
                LocalStorageCleanupReviewView(
                    candidates: localInventory.cleanupCandidates,
                    totalBytes: localInventory.candidateBytes
                ) {
                    isReviewingRebuildCleanup = false
                    cleanRebuildableCopies(
                        localInventory.cleanupCandidates
                    )
                }
            }
        }
        .alert("数据与存储", isPresented: Binding(
            get: { storageMessage != nil },
            set: { if !$0 { storageMessage = nil } }
        )) {
            Button("完成", role: .cancel) {}
        } message: {
            if let storageMessage {
                storageMessage.text
            }
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
                ? .released(formatted(released))
                : .nothingToClean
        }
    }

    private func refreshStorage() async {
        let updatedSnapshot = await AppStorageUsageService.shared.snapshot()
        if storageSnapshot != updatedSnapshot {
            storageSnapshot = updatedSnapshot
        }
        do {
            let updatedInventory = try LocalStorageInventoryService().inventory(
                context: modelContext
            )
            if localInventory != updatedInventory {
                localInventory = updatedInventory
            }
        } catch {
            storageMessage = .inventoryFailed(error.localizedDescription)
        }
    }

    private func cleanRebuildableCopies(
        _ candidates: [StorageCleanupCandidate]
    ) {
        guard !isCleaningRebuilds else { return }
        isCleaningRebuilds = true
        Task { @MainActor in
            defer { isCleaningRebuilds = false }
            do {
                let receipt = try LocalStorageInventoryService().clean(
                    candidates: candidates,
                    externalBackupConfirmed: true,
                    context: modelContext
                )
                await refreshStorage()
                storageMessage = .cleaned(
                    formatted(receipt.reclaimedByteCount),
                    receipt.diagnosticRelativePath
                )
            } catch {
                storageMessage = .cleanupFailed(error.localizedDescription)
            }
        }
    }
}

private struct LocalStorageCleanupReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let candidates: [StorageCleanupCandidate]
    let totalBytes: Int64
    let confirm: () -> Void

    @State private var isConfirming = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(
                        "预计释放",
                        value: ByteCountFormatter.string(
                            fromByteCount: totalBytes,
                            countStyle: .file
                        )
                    )
                    Text("只有在 Mac 上的完整 App 容器备份已经验证可读时才继续。删除后，原目录只能从该外部备份恢复。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(candidates) { candidate in
                    Section(LocalizedStringKey(candidate.kind.displayName)) {
                        LabeledContent("状态", value: candidate.status)
                        LabeledContent(
                            "大小",
                            value: ByteCountFormatter.string(
                                fromByteCount: candidate.byteCount,
                                countStyle: .file
                            )
                        )
                        Text(candidate.relativePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let error = candidate.errorMessage,
                           !error.isEmpty {
                            Text(LocalizedStringKey(error))
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button("外部备份已验证，继续", role: .destructive) {
                        isConfirming = true
                    }
                }
            }
            .navigationTitle("检查清理范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .confirmationDialog(
                "确认清理这些旧副本？",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("生成诊断归档并清理", role: .destructive) {
                    confirm()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("不会删除业务库、WAL/SHM、照片、eSheep 云迁移备份、Outbox、Tombstone、回执或 Keychain。")
            }
        }
    }
}

private struct FarmDataTaskView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query private var sheep: [SheepRecord]
    @Query private var pens: [PenRecord]
    @Query private var storageProfiles: [FarmStorageProfile]
    @Query private var outboxItems: [OutboxItem]

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
    @State private var message: FarmDataTaskMessage?
    @State private var isExportingBackup = false
    @State private var backupDocument: FarmInterchangeDocument?
    @State private var isRestoringBackup = false
    @State private var backupPreview: FarmPortableBackupPreview?
    @State private var isPreparingBackup = false

    init(account: AccountProfile, farm: FarmRecord, task: FarmDataTask) {
        self.account = account
        self.farm = farm
        self.task = task

        let farmID = farm.id
        _sheep = Query(
            filter: #Predicate<SheepRecord> {
                $0.farmID == farmID && $0.deletedAt == nil
            }
        )
        _pens = Query(
            filter: #Predicate<PenRecord> {
                $0.farmID == farmID && $0.deletedAt == nil
            }
        )
        _storageProfiles = Query(
            filter: #Predicate<FarmStorageProfile> { $0.farmID == farmID }
        )
        _outboxItems = Query(
            filter: #Predicate<OutboxItem> { $0.farmID == farmID }
        )
    }

    private var farmSheep: [SheepRecord] { sheep }

    private var storageProfile: FarmStorageProfile? {
        storageProfiles.first
    }

    private var storageMode: FarmStorageMode {
        storageProfile?.mode ?? .localOnly
    }

    private var pendingCloudOperationCount: Int {
        guard let provider = storageMode.deliveryProvider else { return 0 }
        return outboxItems.count {
            $0.deliveryProvider == provider &&
                !$0.status.isTerminalDelivery
        }
    }

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
                        LabeledContent("待写入") {
                            Text("\(excelPreview.rows.count) 条")
                        }
                        LabeledContent("需要修正") {
                            Text("\(excelPreview.errorCount) 条")
                        }
                        LabeledContent("提醒") {
                            Text("\(excelPreview.warningCount) 条")
                        }
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
                        LabeledContent("可导入") {
                            Text("\(preview.acceptedRows.count) 条")
                        }
                        LabeledContent("重复") {
                            Text("\(preview.duplicateRowNumbers.count) 条")
                        }
                        LabeledContent("错误") {
                            Text("\(preview.errorCount) 条")
                        }
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
                Section("完整备份") {
                    if CapabilitySet(role: farm.role).allows(.exportFarm) {
                        Button(
                            isPreparingBackup ? "正在同步并生成备份…" : "导出完整备份",
                            action: exportBackup
                        )
                        .disabled(isPreparingBackup)
                    }
                    if CapabilitySet(role: farm.role).allows(.recordProduction) {
                        Button("选择备份并检查") { isRestoringBackup = true }
                    }
                    Text("备份包含生产记录、历史、删除记录、TMR 和照片。eSheep 云牧场会先同步；仍有待上传记录时不会生成“已同步”备份。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let backupPreview {
                    Section("恢复检查") {
                        LabeledContent("来源牧场", value: backupPreview.legacyPreview.envelope.payload.farm.name)
                        LabeledContent("备份时间") { Text(backupPreview.legacyPreview.envelope.payload.exportedAt, format: .dateTime.year().month().day().hour().minute()) }
                        backupSummary(backupPreview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("文件恢复只会建立新的仅本机牧场，不会覆盖当前 eSheep 云牧场。恢复完成并核对后，可再从云存储页面显式迁移。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("恢复为新的仅本机牧场") { restoreBackup(backupPreview) }
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
            if case .failure(let error) = result { message = .templateExportFailed(error.localizedDescription) }
            else { message = .templateExported }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .officeOpenXMLSpreadsheet, defaultFilename: fileName()) { result in
            if case .failure(let error) = result { message = .exportFailed(error.localizedDescription) }
            else { message = .exported }
        }
        .fileExporter(isPresented: $isExportingBackup, document: backupDocument, contentType: .eSheepPortableBackup, defaultFilename: backupFileName()) { result in
            if case .failure(let error) = result { message = .backupExportFailed(error.localizedDescription) }
            else { message = .backupExported }
        }
        // `.data` keeps backups selectable when an older app version or a
        // third-party Files provider did not preserve our custom type metadata.
        // The selected bytes still have to pass the portable-backup preview,
        // schema, checksum and reference validation before restore is enabled.
        .fileImporter(isPresented: $isRestoringBackup, allowedContentTypes: [.eSheepPortableBackup, .json, .data]) { result in
            previewBackup(result)
        }
        .alert("数据交换", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("完成", role: .cancel) {}
        } message: {
            if let message {
                message.text
            }
        }
    }

    private func backupSummary(_ preview: FarmPortableBackupPreview) -> Text {
        switch preview.sourceStorageMode {
        case .localOnly:
            return Text("来源：仅本机 · 业务记录 \(preview.entityCount) · 照片 \(preview.photoCount)")
        case .retiredAppleCloud:
            return Text("来源：已停用的旧云备份 · 业务记录 \(preview.entityCount) · 照片 \(preview.photoCount)")
        case .supabase:
            return Text("来源：eSheep 云 · 业务记录 \(preview.entityCount) · 照片 \(preview.photoCount)")
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try SecureImportFileLoader.load(from: url)
            preview = try FarmDataInterchange.preview(data: data, fileExtension: url.pathExtension, existingEarTags: Set(farmSheep.map(\.earTag)))
        } catch { message = .importFailed(error.localizedDescription) }
    }

    private func exportExcelTemplate() {
        do {
            excelTemplateDocument = FarmInterchangeDocument(data: try FarmExcelImportService.templateData())
            isExportingExcelTemplate = true
        } catch { message = .templateGenerationFailed(error.localizedDescription) }
    }

    private func importExcelTemplate(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try SecureImportFileLoader.load(from: url)
            excelPreview = try FarmExcelImportService.preview(data: data, farm: farm, context: modelContext)
        } catch { message = .excelPreviewFailed(error.localizedDescription) }
    }

    private func commitExcel(_ preview: FarmExcelPreview) {
        do {
            let count = try FarmExcelImportService.commit(preview, account: account, farm: farm, context: modelContext)
            excelPreview = nil
            message = .excelImported(count)
        } catch { message = .excelImportFailed(error.localizedDescription) }
    }

    private func commit(_ preview: FarmImportPreview) {
        do {
            let result = try FarmImportCommitService.commit(preview, account: account, farm: farm, context: modelContext)
            self.preview = nil
            message = .imported(imported: result.importedCount, skipped: result.skippedCount)
        } catch { message = .writeFailed(error.localizedDescription) }
    }

    private func exportXLSX() {
        do {
            exportDocument = FarmInterchangeDocument(data: try FarmDataInterchange.xlsxData(farmID: farm.id, sheep: sheep, pens: pens))
            isExporting = true
        } catch { message = .exportFailed(error.localizedDescription) }
    }

    private func fileName() -> String {
        let safe = farm.name.replacingOccurrences(of: "/", with: "-")
        return "牧场档案_\(safe)_\(Date.now.formatted(.iso8601.year().month().day())).xlsx"
    }

    private func exportBackup() {
        guard !isPreparingBackup else { return }
        isPreparingBackup = true
        Task { @MainActor in
            defer { isPreparingBackup = false }
            guard storageMode != .retiredAppleCloud else {
                message = .backupExportFailed("旧云端牧场已停用且正在删除，不能再生成云端一致性备份。")
                return
            }
            if storageMode == .supabase {
                await collaboration.synchronizeNow()
                guard pendingCloudOperationCount == 0 else {
                    message = .backupPending(pendingCloudOperationCount)
                    return
                }
            }
            do {
                let data = try FarmPortableBackupService.export(
                    farmID: farm.id,
                    sourceStorageMode: storageMode,
                    sourceAuthorityGeneration: storageProfile?.authorityGeneration ?? 0,
                    sourceWasFullySynchronized: storageMode == .localOnly || pendingCloudOperationCount == 0,
                    context: modelContext
                )
                backupDocument = FarmInterchangeDocument(data: data)
                isExportingBackup = true
            } catch {
                message = .backupExportFailed(error.localizedDescription)
            }
        }
    }

    private func previewBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try SecureImportFileLoader.load(
                from: url,
                maximumBytes: 512 * 1_024 * 1_024
            )
            backupPreview = try FarmPortableBackupService.preview(data: data)
        } catch { message = .backupValidationFailed(error.localizedDescription) }
    }

    private func restoreBackup(_ preview: FarmPortableBackupPreview) {
        do {
            let result = try FarmPortableBackupService.restoreAsNewLocalFarm(
                preview,
                account: account,
                context: modelContext
            )
            backupPreview = nil
            let farms = try modelContext.fetch(FetchDescriptor<FarmRecord>())
            try session.switchFarm(to: result.farmID, availableFarms: farms)
            message = .restored(
                entityCount: result.restoredEntityCount,
                photoCount: result.restoredPhotoCount
            )
        } catch { message = .restoreFailed(error.localizedDescription) }
    }

    private func backupFileName() -> String {
        let safe = farm.name.replacingOccurrences(of: "/", with: "-")
        return "eSheep完整备份_\(safe)_\(Date.now.formatted(.iso8601.year().month().day())).esheep-backup"
    }
}
