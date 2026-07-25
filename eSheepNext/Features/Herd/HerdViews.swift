import PhotosUI
import Charts
import SwiftData
import SwiftUI
import UIKit

struct HerdManagementView: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord

    @State private var isAddingSheep = false
    @State private var isExportingSheep = false
    @State private var exportDocument: InHerdSheepExportDocument?
    @State private var exportKind = HerdExportKind.present
    @State private var exportedSheepCount = 0
    @State private var exportMessage: String?
    @State private var query = ""
    @State private var sexFilter: SheepSex?
    @State private var statusFilter: SheepStatus? = .active
    @State private var penFilter: UUID?
    @State private var sortOrder = HerdSortOrder.earTag
    @State private var visibleLimit = 100
    @State private var selection = Set<UUID>()
    @State private var isBatchTransferring = false
    @State private var sourceSheep: [HerdSheepRow] = []
    @State private var filteredSheep: [HerdSheepRow] = []
    @State private var penOptions: [HerdPenOption] = []
    @State private var presentSheepCount = 0
    @State private var removedSheepCount = 0
    @State private var hasBuiltSheepSnapshot = false
    @State private var sheepSourceRevision = 0

    private var penNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: penOptions.map { ($0.id, $0.name) })
    }

    var body: some View {
        let displayedSheep = filteredSheep
        let visibleSheep = displayedSheep.prefix(visibleLimit)
        List(selection: $selection) {
            if !hasBuiltSheepSnapshot {
                ProgressView("正在整理羊只")
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if displayedSheep.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(visibleSheep, id: \.id) { sheep in
                    NavigationLink {
                        SheepDetailEntryView(
                            account: account,
                            farm: farm,
                            sheepID: sheep.id,
                            penName: sheep.currentPenID.flatMap { penNames[$0] }
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sheep.earTag).font(.headline)
                            Text([sheep.breed, sheep.sex.displayName, sheep.currentPenDisplayName(sheep.currentPenID.flatMap { penNames[$0] }), sheep.status.displayName].joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(sheep.id)
                }
                if visibleSheep.count < displayedSheep.count {
                    Button("继续加载（剩余 \(displayedSheep.count - visibleSheep.count) 只）") { visibleLimit += 100 }
                }
            }
        }
        .navigationTitle("羊只")
        .searchable(text: $query, prompt: "耳号或品种")
        .onAppear(perform: reloadSheepSource)
        .task(id: HerdSearchRequest(
            query: SearchText.normalized(query),
            sexFilter: sexFilter,
            statusFilter: statusFilter,
            penFilter: penFilter,
            sortOrder: sortOrder,
            sourceRevision: sheepSourceRevision
        )) {
            await rebuildSheepSnapshot()
        }
        .onChange(of: query) { _, _ in visibleLimit = 100 }
        .onChange(of: sexFilter) { _, _ in visibleLimit = 100; selection.removeAll() }
        .onChange(of: statusFilter) { _, _ in visibleLimit = 100; selection.removeAll() }
        .onChange(of: penFilter) { _, _ in visibleLimit = 100; selection.removeAll() }
        .onChange(of: sortOrder) { _, _ in visibleLimit = 100 }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("性别", selection: $sexFilter) {
                        Text("全部性别").tag(SheepSex?.none)
                        ForEach(SheepSex.allCases, id: \.self) { Text($0.displayName).tag(SheepSex?.some($0)) }
                    }
                    Picker("状态", selection: $statusFilter) {
                        Text("全部状态").tag(SheepStatus?.none)
                        ForEach(SheepStatus.allCases, id: \.self) { Text($0.displayName).tag(SheepStatus?.some($0)) }
                    }
                    Picker("圈舍", selection: $penFilter) {
                        Text("全部圈舍").tag(UUID?.none)
                        ForEach(penOptions) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Divider()
                    Picker("排序", selection: $sortOrder) {
                        ForEach(HerdSortOrder.allCases) { Text($0.title).tag($0) }
                    }
                    if sexFilter != nil || statusFilter != nil || penFilter != nil {
                        Button("清除筛选") { sexFilter = nil; statusFilter = nil; penFilter = nil }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel("筛选与排序")
            }
            if !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("批量转群（\(selection.count)）") { isBatchTransferring = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("导出在群羊只 CSV", systemImage: "checkmark.circle") { exportSheep(.present) }
                        .disabled(presentSheepCount == 0)
                    Button("导出离群羊只 CSV", systemImage: "arrowshape.turn.up.right.circle") { exportSheep(.removed) }
                        .disabled(removedSheepCount == 0)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出羊只 CSV")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAddingSheep = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建羊只")
            }
        }
        .sheet(isPresented: $isAddingSheep, onDismiss: reloadSheepSource) {
            NavigationStack { AddSheepView(account: account, farm: farm) }
        }
        .sheet(isPresented: $isBatchTransferring) {
            NavigationStack {
                BatchTransferSheepView(account: account, farm: farm, sheepIDs: selection) { count in
                    selection.removeAll()
                    reloadSheepSource()
                    exportMessage = "已为 \(count) 只羊生成转群记录。"
                }
            }
        }
        .fileExporter(
            isPresented: $isExportingSheep,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportKind.fileName(farmName: farm.name)
        ) { result in
            switch result {
            case .success:
                exportMessage = "已导出 \(exportedSheepCount) 只\(exportKind.displayName)羊只。文件为 UTF-8 CSV，可直接用 Excel 打开。"
            case .failure(let error):
                exportMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        .alert("导出羊只", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private func exportSheep(_ kind: HerdExportKind) {
        let farmID = farm.id
        do {
            let sheep = try modelContext.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }))
            switch kind {
            case .present:
                let exportedSheep = sheep.filter(\.isCurrentlyPresent)
                let pens = try modelContext.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.deletedAt == nil
                }))
                exportDocument = InHerdSheepExportDocument(
                    data: InHerdSheepExport.csvData(farmID: farmID, sheep: exportedSheep, pens: pens)
                )
                exportedSheepCount = exportedSheep.count
            case .removed:
                let exportedSheep = sheep.filter { !$0.isCurrentlyPresent && !$0.isHistoricalArchive }
                let removals = try modelContext.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.deletedAt == nil
                }))
                exportDocument = InHerdSheepExportDocument(
                    data: RemovedSheepExport.csvData(farmID: farmID, sheep: exportedSheep, removals: removals)
                )
                exportedSheepCount = exportedSheep.count
            }
            exportKind = kind
            isExportingSheep = true
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func reloadSheepSource() {
        let farmID = farm.id
        do {
            let sheep = try modelContext.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }))
            let pens = try modelContext.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }))
            sourceSheep = sheep.map(HerdSheepRow.init)
            penOptions = pens.map { HerdPenOption(id: $0.id, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            presentSheepCount = sourceSheep.lazy.filter(\.isCurrentlyPresent).count
            removedSheepCount = sheep.lazy.filter { !$0.isCurrentlyPresent && !$0.isHistoricalArchive }.count
            hasBuiltSheepSnapshot = false
            sheepSourceRevision &+= 1
        } catch {
            sourceSheep = []
            filteredSheep = []
            penOptions = []
            presentSheepCount = 0
            removedSheepCount = 0
            hasBuiltSheepSnapshot = true
            exportMessage = "读取羊只档案失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func rebuildSheepSnapshot() async {
        let request = HerdSearchRequest(
            query: SearchText.normalized(query),
            sexFilter: sexFilter,
            statusFilter: statusFilter,
            penFilter: penFilter,
            sortOrder: sortOrder,
            sourceRevision: sheepSourceRevision
        )
        do {
            if !request.query.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
            }
            let source = sourceSheep
            let updatedRows = await Task.detached(priority: .userInitiated) {
                HerdSearch.filter(source, request: request)
            }.value
            try Task.checkCancellation()
            filteredSheep = updatedRows
            hasBuiltSheepSnapshot = true
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }
}

private enum HerdExportKind {
    case present
    case removed

    var displayName: String {
        switch self {
        case .present: "在群"
        case .removed: "离群"
        }
    }

    func fileName(farmName: String) -> String {
        switch self {
        case .present: InHerdSheepExport.fileName(farmName: farmName)
        case .removed: RemovedSheepExport.fileName(farmName: farmName)
        }
    }
}

private struct HerdSheepRow: Identifiable, Sendable {
    let id: UUID
    let earTag: String
    let breed: String
    let sex: SheepSex
    let status: SheepStatus
    let currentPenID: UUID?
    let enteredAt: Date
    let isCurrentlyPresent: Bool
    let searchableText: String

    init(_ sheep: SheepRecord) {
        id = sheep.id
        earTag = sheep.earTag
        breed = sheep.breed
        sex = sheep.sex
        status = sheep.status
        currentPenID = sheep.currentPenID
        enteredAt = sheep.enteredAt
        isCurrentlyPresent = sheep.isCurrentlyPresent
        searchableText = SearchText.normalized(sheep.earTag + "\u{0}" + sheep.breed)
    }

    func currentPenDisplayName(_ penName: String?) -> String {
        isCurrentlyPresent ? (penName ?? "未分圈") : "已离群"
    }
}

private struct HerdPenOption: Identifiable {
    let id: UUID
    let name: String
}

private enum HerdSortOrder: String, CaseIterable, Identifiable, Sendable {
    case earTag, newestEntry, breed
    var id: String { rawValue }
    var title: String {
        switch self { case .earTag: "耳号"; case .newestEntry: "最近入场"; case .breed: "品种" }
    }
}

private struct HerdSearchRequest: Equatable, Sendable {
    let query: String
    let sexFilter: SheepSex?
    let statusFilter: SheepStatus?
    let penFilter: UUID?
    let sortOrder: HerdSortOrder
    let sourceRevision: Int
}

private enum HerdSearch {
    static func filter(
        _ source: [HerdSheepRow],
        request: HerdSearchRequest
    ) -> [HerdSheepRow] {
        source.filter {
            (request.query.isEmpty || $0.searchableText.contains(request.query)) &&
                (request.sexFilter == nil || $0.sex == request.sexFilter) &&
                (request.statusFilter == nil || (
                    request.statusFilter == .active
                        ? $0.isCurrentlyPresent
                        : $0.status == request.statusFilter
                )) &&
                (request.penFilter == nil || $0.currentPenID == request.penFilter)
        }
        .sorted {
            if $0.isCurrentlyPresent != $1.isCurrentlyPresent {
                return $0.isCurrentlyPresent
            }
            switch request.sortOrder {
            case .earTag:
                return $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending
            case .newestEntry:
                return $0.enteredAt == $1.enteredAt
                    ? $0.earTag < $1.earTag
                    : $0.enteredAt > $1.enteredAt
            case .breed:
                return $0.breed == $1.breed
                    ? $0.earTag < $1.earTag
                    : $0.breed.localizedStandardCompare($1.breed) == .orderedAscending
            }
        }
    }
}

private struct BatchTransferSheepView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let sheepIDs: Set<UUID>
    let completion: (Int) -> Void
    private let commandService = FarmCommandService()
    @State private var targetPenID: UUID?
    @State private var occurredAt = Date.now
    @State private var note = "批量转群"
    @State private var errorMessage: String?

    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }

    var body: some View {
        Form {
            Section("影响摘要") { Text("将为 \(sheepIDs.count) 只羊分别创建可同步、可追溯的转群记录。") }
            Section("目标") {
                Picker("目标圈舍", selection: $targetPenID) {
                    Text("未分圈").tag(UUID?.none)
                    ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                DatePicker("发生时间", selection: $occurredAt)
                TextField("备注", text: $note)
            }
        }
        .navigationTitle("批量转群")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("确认保存", action: save).disabled(sheepIDs.isEmpty) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
            for sheepID in sheepIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                try commandService.execute(.transferSheep(sheepID: sheepID, toPenID: targetPenID, occurredAt: occurredAt, note: note), in: farmContext, context: modelContext)
            }
            completion(sheepIDs.count)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SheepDetailEntryView: View {
    @Query private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let penName: String?

    init(account: AccountProfile, farm: FarmRecord, sheepID: UUID, penName: String?) {
        self.account = account
        self.farm = farm
        self.penName = penName
        let farmID = farm.id
        _sheep = Query(filter: #Predicate<SheepRecord> {
            $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
        })
    }

    var body: some View {
        if let sheep = sheep.first {
            SheepDetailView(account: account, farm: farm, sheep: sheep, penName: penName)
        } else {
            ContentUnavailableView("羊只档案不存在", systemImage: "exclamationmark.triangle")
        }
    }
}

struct SheepDetailView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let sheep: SheepRecord
    let penName: String?
    private let detailSubject: SheepDetailSubjectSnapshot

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isProcessingPhoto = false
    @State private var photoMessage: String?
    @State private var exportDocument: FarmInterchangeDocument?
    @State private var isExporting = false
    @State private var isPreparingExport = false
    @State private var detailSnapshot: SheepDetailSnapshot?
    @State private var isLoadingDetail = true
    @State private var detailLoadError: String?
    @State private var isEditingProfile = false
    @State private var editingPhotoTime: PhotoTimeDraft?
    @State private var pendingPhotoDeletion: PhotoDeletionDraft?
    private let commandService = FarmCommandService()

    init(account: AccountProfile, farm: FarmRecord, sheep: SheepRecord, penName: String?) {
        self.account = account
        self.farm = farm
        self.sheep = sheep
        self.penName = penName
        detailSubject = SheepDetailSubjectSnapshot(
            id: sheep.id,
            earTag: sheep.earTag,
            breed: sheep.breed,
            purpose: sheep.purpose,
            sex: sheep.sex,
            status: sheep.status,
            initialPenID: sheep.initialPenID,
            currentPenID: sheep.currentPenID,
            birthAt: sheep.birthAt,
            enteredAt: sheep.enteredAt,
            removedAt: sheep.removedAt
        )
    }

    private var sheepPhotos: [SheepDetailPhotoSnapshot] { detailSnapshot?.photos ?? [] }

    var body: some View {
        List {
            Section {
                SheepProfileBanner(
                    sheep: sheep,
                    penName: penName,
                    photo: sheepPhotos.first,
                    photoCount: sheepPhotos.count
                )
            }
            if let detailLoadError {
                Section {
                    ContentUnavailableView(
                        "读取生产记录失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(detailLoadError)
                    )
                    Button("重新读取") { Task { await reloadDetailSnapshot() } }
                }
            }

            Section("档案") {
                LabeledContent("耳号", value: sheep.earTag)
                LabeledContent("品种", value: sheep.breed)
                LabeledContent("性别", value: sheep.sex.displayName)
                LabeledContent("状态", value: sheep.status.displayName)
                LabeledContent("当前圈舍", value: sheep.currentPenDisplayName(penName))
                LabeledContent("入场时间") { Text(sheep.enteredAt, format: .dateTime.year().month().day()) }
            }
            if !sheep.note.isEmpty {
                Section("备注") { Text(sheep.note) }
            }
            Section("系谱") {
                NavigationLink {
                    AnyView(SheepPedigreeView(account: account, farm: farm, sheepID: sheep.id))
                } label: {
                    Label("父母、祖先、同胞与后代", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            weightChartSection
            analyticsSection
            Section("照片时间线") {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("从照片库添加", systemImage: "photo.badge.plus")
                }
                .disabled(isProcessingPhoto || !FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role).capabilities.allows(.recordProduction))
                if isProcessingPhoto { ProgressView("正在处理照片") }
                if sheepPhotos.isEmpty {
                    ContentUnavailableView(
                        "尚未添加照片",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("添加后会按拍摄时间形成这只羊的影像时间线。")
                    )
                } else {
                    ForEach(sheepPhotos, id: \.id) { photo in
                        HStack(spacing: 12) {
                            Button {
                                editPhotoTime(photo)
                            } label: {
                                PhotoTimelineRow(photo: photo)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canEditPhotos)

                            Menu {
                                Button("修改照片时间", systemImage: "calendar.badge.clock") {
                                    editPhotoTime(photo)
                                }
                                .disabled(!canEditPhotos)
                                Button("删除照片", systemImage: "trash", role: .destructive) {
                                    requestPhotoDeletion(photo)
                                }
                                .disabled(!canDeletePhotos)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("照片操作")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                requestPhotoDeletion(photo)
                            }
                            .disabled(!canDeletePhotos)
                        }
                    }
                }
            }
            timelineSection
            Section("记录管理") {
                NavigationLink {
                    SheepRecordHistoryScreen(account: account, farm: farm, sheepID: sheep.id)
                } label: {
                    Label("修正、撤销与恢复", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
            }
        }
        .navigationTitle(sheep.earTag)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { isEditingProfile = true }
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { exportSingleSheep() } label: {
                    if isPreparingExport {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                    .accessibilityLabel("导出单羊完整档案 XLSX")
                    .disabled(isPreparingExport || !CapabilitySet(role: farm.role).allows(.exportFarm))
            }
        }
        .sheet(isPresented: $isEditingProfile, onDismiss: { Task { await reloadDetailSnapshot() } }) {
            NavigationStack { EditSheepProfileView(account: account, farm: farm, sheep: sheep) }
        }
        .sheet(item: $editingPhotoTime) { draft in
            NavigationStack {
                PhotoTimeEditor(initialDate: draft.capturedAt) { date in
                    updatePhotoTime(assetID: draft.assetID, capturedAt: date)
                }
            }
        }
        .confirmationDialog(
            "删除这张照片？",
            isPresented: Binding(
                get: { pendingPhotoDeletion != nil },
                set: { if !$0 { pendingPhotoDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除照片", role: .destructive) { deletePendingPhoto() }
            Button("取消", role: .cancel) { pendingPhotoDeletion = nil }
        } message: {
            Text("照片会从当前档案和时间线中移除，并保留审计记录，可在“修正、撤销与恢复”中恢复。")
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .officeOpenXMLSpreadsheet, defaultFilename: "羊只档案_\(sheep.earTag).xlsx") { result in
            switch result {
            case .success: photoMessage = "已导出包含基础资料和完整时间线的 XLSX 工作簿。"
            case .failure(let error): photoMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            addPhoto(item)
        }
        .task(id: sheep.id) { await reloadDetailSnapshot() }
        .alert("照片", isPresented: Binding(get: { photoMessage != nil }, set: { if !$0 { photoMessage = nil } })) {
            Button("完成", role: .cancel) {}
        } message: { Text(photoMessage ?? "") }
    }

    private var canEditPhotos: Bool {
        FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
            .capabilities.allows(.recordProduction)
    }

    private var canDeletePhotos: Bool {
        FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
            .capabilities.allows(.deleteProtectedFacts)
    }

    private func editPhotoTime(_ photo: SheepDetailPhotoSnapshot) {
        editingPhotoTime = PhotoTimeDraft(assetID: photo.id, capturedAt: photo.displayedAt)
    }

    private func requestPhotoDeletion(_ photo: SheepDetailPhotoSnapshot) {
        pendingPhotoDeletion = PhotoDeletionDraft(assetID: photo.id, capturedAt: photo.displayedAt)
    }

    @ViewBuilder
    private var weightChartSection: some View {
        let records = Array((detailSnapshot?.weights ?? []).reversed())
        if let latest = records.last {
            Section("体重") {
                LabeledContent("最近体重", value: "\(latest.kilogramsText) 千克")
                if records.count >= 2 {
                    Chart(records, id: \.id) { record in
                        LineMark(x: .value("日期", record.occurredAt), y: .value("体重", record.kilograms))
                        PointMark(x: .value("日期", record.occurredAt), y: .value("体重", record.kilograms))
                    }
                    .frame(height: 160)
                    .accessibilityLabel("\(sheep.earTag)体重变化曲线，共\(records.count)个体重数据点")
                }
            }
        }
    }

    @ViewBuilder
    private var analyticsSection: some View {
        if let lifecycleInsight = detailSnapshot?.lifecycleInsight {
            Section(lifecycleInsight.title) {
                Text(lifecycleInsight.summary)
                ForEach(lifecycleInsight.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
        } else if isLoadingDetail {
            Section { ProgressView("正在计算羊只分析") }
        }
        if let reproductionInsight = detailSnapshot?.reproductionInsight, !reproductionInsight.details.isEmpty {
            Section(reproductionInsight.title) {
                Text(reproductionInsight.summary)
                ForEach(reproductionInsight.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        let entries = detailSnapshot?.timeline ?? []
        Section("时间线") {
            if isLoadingDetail, detailSnapshot == nil {
                ProgressView("正在读取时间线")
            } else if entries.isEmpty {
                Text("暂无历史记录").foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.subheadline.weight(.medium))
                        if !entry.detail.isEmpty { Text(entry.detail).font(.footnote).foregroundStyle(.secondary) }
                        Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func reloadDetailSnapshot() async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            detailSnapshot = try await SheepDetailSnapshotActor(container: modelContext.container).load(
                farmID: farm.id,
                sheepID: sheep.id,
                subject: detailSubject
            )
            detailLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            detailLoadError = error.localizedDescription
        }
    }

    private func addPhoto(_ item: PhotosPickerItem) {
        guard !isProcessingPhoto else { return }
        isProcessingPhoto = true
        Task {
            defer {
                isProcessingPhoto = false
                selectedPhoto = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoTransferError.sourceUnreadable }
                _ = try await collaboration.photoTransfers.enqueue(data: data, farmID: farm.id, entityID: sheep.id)
                await collaboration.synchronizeNow()
                await reloadDetailSnapshot()
                photoMessage = collaboration.lastErrorMessage ?? "照片已压缩保存并进入云端同步队列。"
            } catch {
                photoMessage = error.localizedDescription
            }
        }
    }

    private func exportSingleSheep() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        Task {
            defer { isPreparingExport = false }
            do {
                let data = try await SheepDetailSnapshotActor(container: modelContext.container).singleSheepXLSXData(
                    farmID: farm.id,
                    sheepID: sheep.id,
                    penName: penName
                )
                exportDocument = FarmInterchangeDocument(data: data)
                isExporting = true
            } catch {
                photoMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func updatePhotoTime(assetID: UUID, capturedAt: Date) {
        Task {
            do {
                try await collaboration.photoTransfers.updateCapturedAt(assetID: assetID, capturedAt: capturedAt)
                await collaboration.synchronizeNow()
                await reloadDetailSnapshot()
                photoMessage = collaboration.lastErrorMessage ?? "照片时间已更新并进入云端同步队列。"
            } catch {
                photoMessage = error.localizedDescription
            }
        }
    }

    private func deletePendingPhoto() {
        guard let draft = pendingPhotoDeletion else { return }
        pendingPhotoDeletion = nil
        do {
            try commandService.execute(
                .tombstoneEntity(
                    entityType: .photoAsset,
                    entityID: draft.assetID,
                    reason: "用户删除羊只照片（拍摄时间：\(draft.capturedAt.formatted(date: .numeric, time: .shortened))）"
                ),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            photoMessage = "照片已删除，可在记录管理中恢复。"
            Task {
                await reloadDetailSnapshot()
                await collaboration.synchronizeNow()
            }
        } catch {
            photoMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}

private struct SheepProfileBanner: View {
    let sheep: SheepRecord
    let penName: String?
    let photo: SheepDetailPhotoSnapshot?
    let photoCount: Int

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let photo {
                    CloudPhotoThumbnail(
                        assetID: photo.id,
                        digest: photo.sha256,
                        width: 112,
                        height: 96,
                        cornerRadius: 12
                    )
                } else {
                    Image(systemName: "sheep")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(AppTheme.brand)
                        .frame(width: 112, height: 96)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                }
            }
            .accessibilityLabel(photo == nil ? "暂无羊只照片" : "最新羊只照片")

            VStack(alignment: .leading, spacing: 6) {
                Text(sheep.earTag)
                    .font(.title2.bold())
                    .lineLimit(1)

                Text([sheep.breed.isEmpty ? "未填写品种" : sheep.breed, sheep.sex.displayName, sheep.status.displayName].joined(separator: " · "))
                    .lineLimit(1)
                Label(sheep.currentPenDisplayName(penName), systemImage: "square.grid.2x2")
                Label("\(photoCount) 张照片", systemImage: "photo.stack")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PhotoTimelineRow: View {
    let photo: SheepDetailPhotoSnapshot

    private var displayedDate: Date { photo.displayedAt }

    var body: some View {
        HStack(spacing: 12) {
            CloudPhotoThumbnail(assetID: photo.id, digest: photo.sha256, width: 82, height: 82, cornerRadius: 14)

            VStack(alignment: .leading, spacing: 6) {
                Label("羊只照片", systemImage: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                Text(displayedDate, format: .dateTime.year().month().day())
                    .font(.subheadline)
                Text(displayedDate, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if photo.capturedAt == nil {
                    Text("未记录拍摄时间，当前显示添加时间")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

private struct PhotoTimeDraft: Identifiable {
    let assetID: UUID
    let capturedAt: Date
    var id: UUID { assetID }
}

private struct PhotoDeletionDraft {
    let assetID: UUID
    let capturedAt: Date
}

private struct PhotoTimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    let initialDate: Date
    let onSave: (Date) -> Void
    @State private var capturedAt: Date

    init(initialDate: Date, onSave: @escaping (Date) -> Void) {
        self.initialDate = initialDate
        self.onSave = onSave
        _capturedAt = State(initialValue: initialDate)
    }

    var body: some View {
        Form {
            Section("照片时间") {
                DatePicker(
                    "拍摄时间",
                    selection: $capturedAt,
                    in: ...Date.now,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
            Section {
                Text("该时间会用于照片时间线、羊只总时间线和顶部档案照片排序。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("修改照片时间")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave(capturedAt)
                    dismiss()
                }
            }
        }
    }
}

private struct CloudPhotoThumbnail: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    let assetID: UUID
    let digest: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    @State private var image: UIImage?

    init(assetID: UUID, digest: String, width: CGFloat = 104, height: CGFloat = 104, cornerRadius: CGFloat = 16) {
        self.assetID = assetID
        self.digest = digest
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .task(id: digest) {
            if let data = try? await collaboration.photoTransfers.localFileData(assetID: assetID) {
                image = UIImage(data: data)
            }
        }
    }
}

struct PenManagementView: View {
    @Query private var pens: [PenRecord]
    @Query private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAddingPen = false
    @State private var displayScope = PenDisplayScope.occupied

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _pens = Query(
            filter: #Predicate<PenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \PenRecord.name
        )
        _sheep = Query(
            filter: #Predicate<SheepRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SheepRecord.earTag
        )
    }

    private var currentSheepByPen: [UUID: [SheepRecord]] {
        Dictionary(
            grouping: sheep.filter { $0.isCurrentlyPresent && $0.currentPenID != nil },
            by: { $0.currentPenID! }
        )
    }

    private func farmPens(sheepByPen: [UUID: [SheepRecord]]) -> [PenRecord] {
        switch displayScope {
        case .occupied:
            pens.filter { sheepByPen[$0.id]?.isEmpty == false }
        case .clearedArchive:
            pens.filter { sheepByPen[$0.id]?.isEmpty != false }
        case .all:
            pens
        }
    }

    var body: some View {
        let sheepByPen = currentSheepByPen
        let displayedPens = farmPens(sheepByPen: sheepByPen)
        List {
            ForEach(displayedPens, id: \.id) { pen in
                NavigationLink {
                    PenDetailView(account: account, farm: farm, pen: pen, sheep: sheepByPen[pen.id] ?? [])
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pen.name).font(.headline)
                        let currentCount = sheepByPen[pen.id]?.count ?? 0
                        Text(currentCount == 0 ? "已清圈 · 已归档" : "当前羊只 \(currentCount) 只")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if displayedPens.isEmpty {
                ContentUnavailableView(
                    displayScope.emptyTitle,
                    systemImage: "building.2",
                    description: Text(displayScope.emptyDescription)
                )
            }
        }
        .navigationTitle("圈舍")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("显示范围", selection: $displayScope) {
                        ForEach(PenDisplayScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel("圈舍显示范围")
            }
            ToolbarItem(placement: .topBarTrailing) { Button { isAddingPen = true } label: { Image(systemName: "plus") } }
        }
        .sheet(isPresented: $isAddingPen) { NavigationStack { AddPenView(account: account, farm: farm) } }
        .farmExcelImport(account: account, farm: farm, sheets: ["圈舍"])
    }
}

private enum PenDisplayScope: String, CaseIterable, Identifiable {
    case occupied
    case clearedArchive
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .occupied: "有羊圈舍"
        case .clearedArchive: "已清圈归档"
        case .all: "全部圈舍"
        }
    }

    var emptyTitle: String {
        switch self {
        case .occupied: "当前没有圈舍存有在场羊"
        case .clearedArchive: "没有已清圈的归档圈舍"
        case .all: "还没有圈舍"
        }
    }

    var emptyDescription: String {
        switch self {
        case .occupied: "空圈舍会自动进入已清圈归档。"
        case .clearedArchive: "最后一只在场羊离开后，圈舍会自动归档到这里。"
        case .all: "圈舍是羊只、投喂和历史分析的核心单位。"
        }
    }
}

struct PenDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let pen: PenRecord
    let sheep: [SheepRecord]
    @State private var isEditing = false
    @State private var herdInsight: FarmInsight

    private let analysisMembers: [PenHerdMemberSnapshot]

    init(account: AccountProfile, farm: FarmRecord, pen: PenRecord, sheep: [SheepRecord]) {
        self.account = account
        self.farm = farm
        self.pen = pen
        self.sheep = sheep
        let members = sheep.map { PenHerdMemberSnapshot(id: $0.id, purpose: $0.purpose) }
        analysisMembers = members
        _herdInsight = State(initialValue: PenHerdInsightBuilder.insight(penName: pen.name, members: members))
    }

    var body: some View {
        List {
            if !pen.note.isEmpty { Section("说明") { Text(pen.note) } }
            Section(herdInsight.title) {
                Text(herdInsight.summary)
                ForEach(herdInsight.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("当前羊只") {
                if sheep.isEmpty { Text("当前没有在场羊只").foregroundStyle(.secondary) }
                ForEach(sheep, id: \.id) { item in
                    NavigationLink {
                        SheepDetailEntryView(
                            account: account,
                            farm: farm,
                            sheepID: item.id,
                            penName: pen.name
                        )
                    } label: {
                        Text(item.earTag)
                    }
                }
            }
        }
        .navigationTitle(pen.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { isEditing = true }
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
            }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack { EditPenView(account: account, farm: farm, pen: pen) }
        }
        .task(id: pen.id) {
            let reader = PenAnalyticsReadActor(container: modelContext.container)
            if let insight = try? await reader.insight(
                farmID: farm.id,
                penName: pen.name,
                members: analysisMembers
            ) {
                herdInsight = insight
            }
        }
    }
}

struct AddSheepView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]

    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()

    @State private var earTag = ""
    @State private var breed = "湖羊"
    @State private var sex = SheepSex.ewe
    @State private var penID: UUID?
    @State private var occurredAt = Date.now
    @State private var birthAt: Date?
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }

    var body: some View {
        Form {
            Section("基础信息") {
                TextField("耳号", text: $earTag)
                TextField("品种", text: $breed)
                Picker("性别", selection: $sex) { ForEach(SheepSex.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            }
            Section("发生时间") {
                DatePicker("入场时间", selection: $occurredAt)
                Toggle("记录出生日期", isOn: Binding(get: { birthAt != nil }, set: { birthAt = $0 ? occurredAt : nil }))
                if let birthAt { DatePicker("出生日期", selection: Binding(get: { birthAt }, set: { self.birthAt = $0 }), displayedComponents: .date) }
            }
            Section("圈舍") {
                Picker("当前圈舍", selection: $penID) {
                    Text("暂不分圈").tag(UUID?.none)
                    ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            Section("备注") { TextField("可选", text: $note, axis: .vertical).lineLimit(2...4) }
        }
        .navigationTitle("新建羊只")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
        }
        .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .farmExcelImport(account: account, farm: farm, sheets: ["新建羊只"])
    }

    private func save() {
        do {
            try commandService.execute(.addSheep(earTag: earTag, breed: breed, sex: sex, penID: penID, occurredAt: occurredAt, birthAt: birthAt, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AddPenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var name = ""
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("圈舍名称", text: $name)
            TextField("说明", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("新建圈舍")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
        }
        .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .farmExcelImport(account: account, farm: farm, sheets: ["圈舍"])
    }

    private func save() {
        do {
            try commandService.execute(.createPen(name: name, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
