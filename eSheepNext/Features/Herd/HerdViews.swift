import ESMotion
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct HerdManagementView: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord

    @Query private var labelCatalog: [SheepLabelRecord]
    @Query private var labelAssignments: [SheepLabelAssignmentRecord]
    @State private var selectedLabelIDs = Set<UUID>()
    @State private var matchAllLabels = false
    @State private var unlabelledOnly = false
    @State private var isEditingLabels = false
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
    @State private var purposeBatchRequest: SheepPurposeBatchRequest?
    @State private var sourceSheep: [HerdSheepRow] = []
    @State private var filteredSheep: [HerdSheepRow] = []
    @State private var penOptions: [HerdPenOption] = []
    @State private var presentSheepCount = 0
    @State private var removedSheepCount = 0
    @State private var sheepLoadError: String?
    @State private var hasBuiltSheepSnapshot = false
    @State private var sheepSourceLoadRevision = 0
    @State private var sheepSourceRevision = 0

    private var penNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: penOptions.map { ($0.id, $0.name) })
    }

    var body: some View {
        let assignments = Dictionary(uniqueKeysWithValues: labelAssignments.filter { $0.farmID == farm.id }.map { ($0.sheepID, $0) })
        let labels = labelCatalog.filter { $0.farmID == farm.id }.map(\.value)
        let displayedSheep = filteredSheep.filter { SheepLabelRules.matches(ids: assignments[$0.id]?.labelIDs ?? [], selected: selectedLabelIDs, all: matchAllLabels, unlabelled: unlabelledOnly) }
        let visibleSheep = displayedSheep.prefix(visibleLimit)
        List(selection: $selection) {
            SheepLabelFilterEntry(
                labels: labels,
                selectedIDs: $selectedLabelIDs,
                matchAll: $matchAllLabels,
                unlabelledOnly: $unlabelledOnly
            )
            .selectionDisabled()
            if let sheepLoadError {
                Text(sheepLoadError).foregroundStyle(.orange)
                Button("重新读取") { sheepSourceLoadRevision &+= 1 }
            }
            if !hasBuiltSheepSnapshot {
                ProgressView("正在整理羊只")
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if displayedSheep.isEmpty {
                ContentUnavailableView {
                    Label(sheepLoadError != nil ? "羊只档案暂不可用" : sourceSheep.isEmpty ? "尚无羊只档案" : query.isEmpty ? "没有符合条件的羊只" : "未找到匹配结果", systemImage: "magnifyingglass")
                } actions: {
                    if sourceSheep.isEmpty && sheepLoadError == nil {
                        Button("新建羊只") { isAddingSheep = true }.disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
                    } else {
                        if !query.isEmpty { Button("清空搜索") { query = "" } }
                        Button("清除筛选") { sexFilter = nil; statusFilter = nil; penFilter = nil; selectedLabelIDs.removeAll(); unlabelledOnly = false }
                    }
                }
            } else {
                ForEach(visibleSheep, id: \.id) { sheep in
                    NavigationLink {
                        SheepDetailEntryView(
                            account: account,
                            farm: farm,
                            sheepID: sheep.id
                        )
                    } label: {
                        HStack(spacing: 12) {
                            SheepAvatarView(photo: sheep.avatarPhoto, size: 48, sex: sheep.sex)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sheep.earTag).font(.headline)
                                if let state = sheep.reproductionState { Text(verbatim: state).font(.caption).foregroundStyle(.secondary) }
                                SheepLabelChips(labels: labels.filter { assignments[sheep.id]?.labelIDs.contains($0.id) == true }, primaryID: assignments[sheep.id]?.primaryLabelID)
                                HStack(spacing: 4) {
                                    if !sheep.breed.isEmpty {
                                        Text(verbatim: sheep.breed)
                                    }
                                    Text(LocalizedStringKey(sheep.sex.displayName))
                                    Text(" · ")
                                    Text(verbatim: sheep.currentPenDisplayName(sheep.currentPenID.flatMap { penNames[$0] }))
                                    Text(" · ")
                                    Text(LocalizedStringKey(sheep.status.displayName))
                                }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
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
        .sheet(isPresented: $isEditingLabels) { NavigationStack { SheepLabelsEditor(account: account, farm: farm, sheepIDs: selection) } }
        .onChange(of: selectedLabelIDs) { selection.removeAll(); visibleLimit = 100 }
        .onChange(of: matchAllLabels) { selection.removeAll(); visibleLimit = 100 }
        .onChange(of: unlabelledOnly) { selection.removeAll(); visibleLimit = 100 }
        .searchable(text: $query, prompt: "搜索羊只耳号或品种")
        .task(id: HerdSourceLoadRequest(farmID: farm.id, revision: sheepSourceLoadRevision)) {
            await reloadSheepSource()
        }
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
        .onChange(of: query) { _, _ in visibleLimit = 100; selection.removeAll() }
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
                        ForEach(SheepSex.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag(SheepSex?.some($0)) }
                    }
                    Picker("状态", selection: $statusFilter) {
                        Text("全部状态").tag(SheepStatus?.none)
                        ForEach(SheepStatus.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag(SheepStatus?.some($0)) }
                    }
                    Picker("圈舍", selection: $penFilter) {
                        Text("全部圈舍").tag(UUID?.none)
                        ForEach(penOptions) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel("筛选羊只")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Divider()
                    Picker("排序", selection: $sortOrder) {
                        ForEach(HerdSortOrder.allCases) { Text($0.title).tag($0) }
                    }
                    if sexFilter != nil || statusFilter != nil || penFilter != nil || !selectedLabelIDs.isEmpty || unlabelledOnly {
                        Button("清除筛选") { sexFilter = nil; statusFilter = nil; penFilter = nil; selectedLabelIDs.removeAll(); unlabelledOnly = false }
                    }
                    Divider()
                    NavigationLink {
                        SheepPurposeManagementView(account: account, farm: farm)
                    } label: {
                        Label("羊只用途管理", systemImage: "tag")
                    }
                    Menu("导出羊只", systemImage: "square.and.arrow.up") {
                        Button("导出在群羊只 CSV", systemImage: "checkmark.circle") { exportSheep(.present) }
                            .disabled(presentSheepCount == 0)
                        Button("导出离群羊只 CSV", systemImage: "arrowshape.turn.up.right.circle") { exportSheep(.removed) }
                            .disabled(removedSheepCount == 0)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("列表操作、筛选与排序")
            }
            if !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("批量标签", systemImage: "tag") { isEditingLabels = true }
                        .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
                        .accessibilityHint("为选中的 \(selection.count) 只羊添加、移除或设置主标签")
                }
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button("批量转群", systemImage: "arrow.left.arrow.right") {
                            isBatchTransferring = true
                        }
                        Button("批量修改用途", systemImage: "tag") {
                            purposeBatchRequest = SheepPurposeBatchRequest(
                                sheepIDs: selection,
                                sourceLabel: "羊只列表多选"
                            )
                        }
                    } label: {
                        Label("批量操作（\(selection.count)）", systemImage: "ellipsis.circle")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAddingSheep = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建羊只")
            }
        }
        .sheet(isPresented: $isAddingSheep, onDismiss: { sheepSourceLoadRevision &+= 1 }) {
            NavigationStack { AddSheepView(account: account, farm: farm) }
        }
        .sheet(isPresented: $isBatchTransferring, onDismiss: { sheepSourceLoadRevision &+= 1 }) {
            NavigationStack {
                BatchTransferSheepView(account: account, farm: farm, sheepIDs: selection) { count in
                    selection.removeAll()
                    exportMessage = "已为 \(count) 只羊生成转群记录。"
                }
            }
        }
        .sheet(item: $purposeBatchRequest, onDismiss: {
            selection.removeAll()
            sheepSourceLoadRevision &+= 1
        }) { request in
            NavigationStack {
                SheepPurposeBatchEditorEntryView(
                    account: account,
                    farm: farm,
                    request: request
                )
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
            Text(LocalizedStringKey(exportMessage ?? ""))
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
                    data: InHerdSheepExport.csvData(farmID: farmID, sheep: exportedSheep, pens: pens, reproduction: try modelContext.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate { $0.farmID == farmID && $0.deletedAt == nil })))
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

    @MainActor
    private func reloadSheepSource() async {
        hasBuiltSheepSnapshot = false
        do {
            let snapshot = try await HerdSnapshotActor(container: modelContext.container)
                .load(farmID: farm.id)
            try Task.checkCancellation()
            sheepLoadError = nil
            sourceSheep = snapshot.sheep
            penOptions = snapshot.penOptions
            presentSheepCount = snapshot.presentSheepCount
            removedSheepCount = snapshot.removedSheepCount
            if let penFilter, !snapshot.occupiedPenIDs.contains(penFilter) {
                self.penFilter = nil
            }
            sheepSourceRevision &+= 1
        } catch {
            sheepLoadError = "读取羊只档案失败：\(error.localizedDescription)"
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
    let avatarPhoto: SheepPhotoReference?
    let reproductionState: String?

    init(_ sheep: SheepRecord, avatarPhoto: SheepPhotoReference?, reproductionState: String? = nil) {
        id = sheep.id
        earTag = sheep.earTag
        breed = sheep.breed
        sex = sheep.sex
        status = sheep.status
        currentPenID = sheep.currentPenID
        enteredAt = sheep.enteredAt
        isCurrentlyPresent = sheep.isCurrentlyPresent
        searchableText = SearchText.normalized(sheep.earTag + "\u{0}" + sheep.breed)
        self.avatarPhoto = avatarPhoto
        self.reproductionState = reproductionState
    }

    func currentPenDisplayName(_ penName: String?) -> String {
        isCurrentlyPresent ? (penName ?? "未分圈") : "已离群"
    }
}

private struct HerdPenOption: Identifiable, Sendable {
    let id: UUID
    let name: String
}

private struct HerdSourceLoadRequest: Equatable, Sendable {
    let farmID: UUID
    let revision: Int
}

private struct HerdSourceSnapshot: Sendable {
    let sheep: [HerdSheepRow]
    let penOptions: [HerdPenOption]
    let occupiedPenIDs: Set<UUID>
    let presentSheepCount: Int
    let removedSheepCount: Int
}

/// Builds the immutable herd source away from the main actor. This includes
/// the avatar projection, which is a second farm-wide read that used to run
/// synchronously every time the herd page appeared.
private actor HerdSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID) throws -> HerdSourceSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let avatarPhotos = try SheepAvatarSelectionStore.references(
            farmID: farmID,
            context: context
        )
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate { $0.farmID == farmID && $0.deletedAt == nil }))
        let states = ReproductionReminderValidity.states(records: reproduction, eweIDs: sheep.filter { $0.sex == .ewe }.map(\.id), now: .now)
        let rows = sheep.map { HerdSheepRow($0, avatarPhoto: avatarPhotos[$0.id], reproductionState: states[$0.id]?.displayState) }
        let occupiedPenIDs = Set(rows.lazy.compactMap { item in
            item.isCurrentlyPresent ? item.currentPenID : nil
        })
        let penOptions = pens
            .filter { occupiedPenIDs.contains($0.id) }
            .map { HerdPenOption(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try Task.checkCancellation()
        return HerdSourceSnapshot(
            sheep: rows,
            penOptions: penOptions,
            occupiedPenIDs: occupiedPenIDs,
            presentSheepCount: rows.count(where: \.isCurrentlyPresent),
            removedSheepCount: sheep.count { !$0.isCurrentlyPresent && !$0.isHistoricalArchive }
        )
    }
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
    @State private var selectedIDs: Set<UUID>
    @State private var candidates: [SheepEarTagSearchCandidate] = []
    @State private var entrySession = ProductionEntrySession()
    let completion: (Int) -> Void
    private let commandService = FarmCommandService()
    @State private var targetPenID: UUID?
    @State private var occurredAt = Date.now
    @State private var note = "批量转群"
    @State private var errorMessage: String?

    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }

    init(account: AccountProfile, farm: FarmRecord, sheepIDs: Set<UUID>, completion: @escaping (Int) -> Void) {
        self.account = account; self.farm = farm; self.completion = completion
        _selectedIDs = State(initialValue: sheepIDs)
    }

    private var productionFields: [ProductionDraftField] {
        [ProductionDraftField("selectedIDs", $selectedIDs, reset: { [] }),
         ProductionDraftField("targetPenID", $targetPenID, reset: { nil }),
         ProductionDraftField("occurredAt", $occurredAt, carry: true),
         ProductionDraftField("note", $note, reset: { "" })]
    }

    var body: some View {
        Form {
            ProductionEntryFeedback(session: entrySession)
            Section("转群对象") {
                SheepEarTagMultiSearchField(candidates: candidates, selection: $selectedIDs)
                Text("本次 \(selectedIDs.count) 只羊将整批保存；任一条失败时不保存本批。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("目标") {
                Picker("目标圈舍", selection: $targetPenID) {
                    Text("未分圈").tag(UUID?.none)
                    ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                DatePicker("发生时间", selection: $occurredAt); ProductionTimeModeControl(session: entrySession)
                TextField("备注", text: $note)
            }
        }
        .navigationTitle("批量转群")
        .productionEntry(entrySession, form: "BatchTransferSheepView", account: account, farm: farm, fields: productionFields, save: save)
        .task(id: farm.id) {
            do { candidates = try await SheepEarTagCandidateSnapshotActor(container: modelContext.container).load(farmID: farm.id, scope: .active) }
            catch { errorMessage = error.localizedDescription }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
            guard !selectedIDs.isEmpty else { errorMessage = "请先选择转群羊只。"; return }
            let count = selectedIDs.count
            let commands = selectedIDs.sorted { $0.uuidString < $1.uuidString }.map {
                FarmCommand.transferSheep(sheepID: $0, toPenID: targetPenID, occurredAt: occurredAt, note: note)
            }
            try entrySession.executeBatch(commands, in: farmContext, context: modelContext)
            entrySession.complete()
            if !entrySession.continuesAfterSave { completion(count) }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SheepDetailEntryView: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let sheepID: UUID

    @State private var screenSnapshot: SheepDetailScreenSnapshot?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if let screenSnapshot {
                SheepDetailView(account: account, farm: farm, screen: screenSnapshot)
            } else if isLoading {
                ProgressView("正在读取羊只档案")
            } else {
                ContentUnavailableView(
                    "羊只档案不存在",
                    systemImage: "exclamationmark.triangle",
                    description: loadError.map(Text.init)
                )
            }
        }
        .task(id: sheepID) {
            await loadScreen()
        }
    }

    @MainActor
    private func loadScreen() async {
        isLoading = true
        do {
            let loaded = try await SheepDetailSnapshotActor(
                container: modelContext.container
            ).loadScreen(farmID: farm.id, sheepID: sheepID)
            try Task.checkCancellation()
            screenSnapshot = loaded
            loadError = loaded == nil ? "该羊只可能已删除或不属于当前牧场。" : nil
        } catch is CancellationError {
            return
        } catch {
            screenSnapshot = nil
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

private struct SheepReproductionEvidenceRoute: Hashable {
    let eweID: UUID
}

struct SheepDetailView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let account: AccountProfile
    let farm: FarmRecord
    @State private var subject: SheepDetailSubjectSnapshot
    @State private var penName: String?
    @State private var avatarPhoto: SheepPhotoReference?

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isProcessingPhoto = false
    @State private var photoMessage: String?
    @State private var exportDocument: FarmInterchangeDocument?
    @State private var isExporting = false
    @State private var isPreparingExport = false
    @State private var quickEntry: PendingRecordEntry?
    @State private var presentedShareDestination: SheepDetailShareDestination?
    @State private var detailSnapshot: SheepDetailSnapshot?
    @State private var isLoadingDetail = true
    @State private var detailLoadError: String?
    @State private var editingSheep: SheepRecord?
    @State private var editingPhotoTime: PhotoTimeDraft?
    @State private var previewingPhoto: SheepPhotoPreviewItem?
    @State private var pendingPhotoDeletion: PhotoDeletionDraft?
    @State private var hasAppeared = false
    @State private var showsProfileDetails = false
    @State private var showsPhotoTimeline = false
    private let commandService = FarmCommandService()

    init(account: AccountProfile, farm: FarmRecord, screen: SheepDetailScreenSnapshot) {
        self.account = account
        self.farm = farm
        _subject = State(initialValue: screen.entry.subject)
        _penName = State(initialValue: screen.entry.penName)
        _avatarPhoto = State(initialValue: screen.entry.avatarPhoto)
        _detailSnapshot = State(initialValue: screen.detail)
        _isLoadingDetail = State(initialValue: false)
        _detailLoadError = State(initialValue: screen.detailLoadErrorDescription)
    }

    @ViewBuilder
    private var quickEntryButtons: some View {
        if subject.sex == .ewe {
            quickEntryButton(.reproduction, identifier: "sheep-record-reproduction")
            quickEntryButton(.lambing, identifier: "sheep-record-lambing")
        }
        quickEntryButton(.weight, identifier: "sheep-record-weight")
        quickEntryButton(.health, identifier: "sheep-record-health")
    }

    private func quickEntryButton(_ action: HomeQuickAction, identifier: String) -> some View {
        HomeShortcut(title: action.title, symbol: action.symbol) {
            quickEntry = action.entry
        }
        .accessibilityIdentifier(identifier)
    }

    private var sheepPhotos: [SheepDetailPhotoSnapshot] { detailSnapshot?.photos ?? [] }

    private var bannerPhotos: [SheepPhotoReference] {
        var seen = Set<UUID>()
        return ([avatarPhoto].compactMap { $0 } + sheepPhotos.map {
            SheepPhotoReference(id: $0.id, digest: $0.sha256)
        }).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        List {
            Section {
                SheepProfileBanner(
                    sheep: subject,
                    penName: penName,
                    photos: bannerPhotos,
                    photoCount: bannerPhotos.count,
                    canEdit: canEditPhotos,
                    isProcessing: isProcessingPhoto,
                    onPreview: previewBannerPhoto,
                    onCamera: openCamera
                )
                .listRowInsets(.init())
                .listRowBackground(Color.clear)
            }
            productionStatusSection
            latestWeightSummary
            if let detailSnapshot, subject.purpose == SheepPurpose.fattening.rawValue || subject.purpose == SheepPurpose.weanedLamb.rawValue {
                Section { SheepGrowthTrendView(detail: detailSnapshot) }
            }
            if subject.isCurrentlyPresent && CapabilitySet(role: farm.role).allows(.recordProduction) {
                Section("常用操作") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 260 : 150))], spacing: 12) {
                        quickEntryButtons
                        Menu {
                            Button("转群") { quickEntry = .transfer }
                            Button("断奶") { quickEntry = .weaning }
                            Button("离场") { quickEntry = .removal }
                            Button("备注") { quickEntry = .note }
                        } label: {
                            HomeShortcutLabel(title: "更多记录", symbol: "ellipsis")
                        }
                        .buttonStyle(MotionSurfaceButtonStyle())
                        .accessibilityLabel("更多记录")
                        .accessibilityIdentifier("sheep-record-more")
                    }
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
                }
            }
            SheepLabelDetailSection(account: account, farm: farm, sheepID: subject.id)
            if let entries = detailSnapshot?.timeline, !entries.isEmpty {
                Section("最近事件") {
                    ForEach(Array(entries.sorted { $0.date > $1.date }.prefix(3)), id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey(entry.title)).font(.subheadline.weight(.medium))
                            Text(entry.detail).font(.footnote).foregroundStyle(.secondary)
                            Text(entry.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        List { timelineSection }
                            .navigationTitle("全部记录")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent("查看全部记录", value: "\(entries.count) 条")
                    }
                    .accessibilityIdentifier("sheep-all-events")
                }
            }
            if let detailLoadError {
                Section {
                    ContentUnavailableView(
                        "读取生产记录失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(LocalizedStringKey(detailLoadError))
                    )
                    Button("重新读取") { Task { await reloadDetailSnapshot() } }
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsProfileDetails) {
                    LabeledContent("耳号", value: subject.earTag)
                    LabeledContent("品种") { Text(verbatim: subject.breed) }
                    LabeledContent("性别") { Text(LocalizedStringKey(subject.sex.displayName)) }
                    if subject.sex == .ewe {
                        LabeledContent("当前胎次") { Text(LocalizedStringKey(currentParityDisplayName)) }
                    }
                    LabeledContent("状态") { Text(LocalizedStringKey(subject.status.displayName)) }
                    LabeledContent("用途") { Text(verbatim: subject.purpose) }
                    LabeledContent("当前圈舍") { Text(verbatim: subject.currentPenDisplayName(penName)) }
                    LabeledContent("入场时间") { Text(subject.enteredAt, format: .dateTime.year().month().day()) }
                    NavigationLink {
                        SheepPurposeEditorEntryView(
                            account: account,
                            farm: farm,
                            sheepID: subject.id
                        )
                    } label: {
                        Label("更改羊只用途", systemImage: "tag")
                    }
                    .disabled(!CapabilitySet(role: farm.role).allows(.editHistoricalFacts))
                    if !subject.note.isEmpty {
                        LabeledContent("备注") { Text(subject.note) }
                    }
                } label: {
                    Label("详细档案", systemImage: "doc.text")
                }
                .accessibilityIdentifier("sheep-profile-details")
            }
            purposeTimelineSection
            Section("系谱") {
                NavigationLink {
                    SheepPedigreeView(account: account, farm: farm, sheepID: subject.id)
                } label: {
                    Label("父母、祖先、同胞与后代", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            analyticsSection
            Section {
                DisclosureGroup(isExpanded: $showsPhotoTimeline) {
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
                                PhotoTimelineRow(
                                    photo: photo,
                                    canEdit: canEditPhotos,
                                    onPreview: { previewPhoto(photo) },
                                    onEdit: { editPhotoTime(photo) }
                                )

                                Menu {
                                    if avatarPhoto?.id == photo.id {
                                        Button("取消头像", systemImage: "person.crop.circle.badge.minus") {
                                            setAvatar(photoAssetID: nil)
                                        }
                                        .disabled(!canEditPhotos)
                                    } else {
                                        Button("设为头像", systemImage: "person.crop.circle.badge.checkmark") {
                                            setAvatar(photoAssetID: photo.id)
                                        }
                                        .disabled(!canEditPhotos)
                                    }
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
                } label: {
                    Label("照片（\(sheepPhotos.count)）", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("sheep-photo-timeline")
            }
            Section("记录管理") {
                NavigationLink {
                    SheepRecordHistoryScreen(account: account, farm: farm, sheepID: subject.id)
                } label: {
                    Label("修正、撤销与恢复", systemImage: CompatibilitySymbol.name("clock.arrow.trianglehead.counterclockwise.rotate.90", fallback: "clock.arrow.circlepath"))
                }
            }
        }
        .navigationTitle(subject.earTag)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { prepareProfileEditing() }
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("分享羊只海报", systemImage: "photo.on.rectangle.angled") {
                        presentedShareDestination = .poster
                    }
                    Button("导出完整档案 XLSX", systemImage: "tablecells") {
                        exportSingleSheep()
                    }
                } label: {
                    if isPreparingExport {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .accessibilityLabel("分享或导出羊只档案")
                .disabled(isPreparingExport || !farmContext.capabilities.allows(.readFarm))
            }
        }
        .sheet(item: $quickEntry, onDismiss: { Task { await reloadDetailSnapshot() } }) { entry in
            NavigationStack {
                ProductionEntryDestination(entry: entry, account: account, farm: farm)
                    .environment(\.productionEntryPrefill, ProductionEntryPrefill(sheepID: subject.id))
            }
        }
        .sheet(item: $presentedShareDestination) { destination in
            switch destination {
            case .poster:
                NavigationStack {
                    SheepSharePosterSelectionView(
                        farmID: farm.id,
                        farmName: farm.name,
                        sheepID: subject.id
                    )
                }
            }
        }
        .sheet(item: $editingSheep, onDismiss: {
            Task { await reloadEntryAndDetail() }
        }) { editingSheep in
            NavigationStack {
                EditSheepProfileView(account: account, farm: farm, sheep: editingSheep)
            }
        }
        .sheet(item: $editingPhotoTime) { draft in
            NavigationStack {
                PhotoTimeEditor(initialDate: draft.capturedAt) { date in
                    updatePhotoTime(assetID: draft.assetID, capturedAt: date)
                }
            }
        }
        .fullScreenCover(item: $previewingPhoto) { item in
            SheepPhotoViewer(item: item, earTag: subject.earTag)
        }
        .sheet(isPresented: $isCameraPresented) {
            SheepCameraPicker(
                onCapture: { image in
                    isCameraPresented = false
                    addCapturedPhoto(image)
                },
                onCancel: { isCameraPresented = false }
            )
            .ignoresSafeArea()
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
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .officeOpenXMLSpreadsheet, defaultFilename: "羊只档案_\(subject.earTag).xlsx") { result in
            switch result {
            case .success: photoMessage = "已导出包含基础资料和完整时间线的 XLSX 工作簿。"
            case .failure(let error): photoMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            addPhoto(item, setAsAvatar: false)
        }
        .navigationDestination(for: SheepReproductionEvidenceRoute.self) { route in
            ReproductionEvidenceView(account: account, farm: farm, eweID: route.eweID)
        }
        .onAppear {
            if hasAppeared {
                Task { await reloadEntryAndDetail() }
            } else {
                hasAppeared = true
            }
        }
        .alert("照片", isPresented: Binding(get: { photoMessage != nil }, set: { if !$0 { photoMessage = nil } })) {
            Button("完成", role: .cancel) {}
        } message: { Text(LocalizedStringKey(photoMessage ?? "")) }
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

    private func previewPhoto(_ photo: SheepDetailPhotoSnapshot) {
        previewBannerPhoto(selectedPhotoID: photo.id)
    }

    private func previewBannerPhoto(selectedPhotoID: UUID?) {
        let dates = Dictionary(sheepPhotos.map { ($0.id, $0.displayedAt) }, uniquingKeysWith: { first, _ in first })
        previewingPhoto = SheepPhotoPreviewItem(
            photos: bannerPhotos.map { .init(reference: $0, displayedAt: dates[$0.id]) },
            selectedPhotoID: selectedPhotoID
        )
    }

    private func requestPhotoDeletion(_ photo: SheepDetailPhotoSnapshot) {
        pendingPhotoDeletion = PhotoDeletionDraft(assetID: photo.id, capturedAt: photo.displayedAt)
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            photoMessage = "当前设备无法使用相机，请从照片时间线选择“从照片库添加”。"
            return
        }
        isCameraPresented = true
    }

    @ViewBuilder
    private var productionStatusSection: some View {
        if let detail = detailSnapshot {
            Section("生产信息") {
                LabeledContent("当前用途", value: subject.purpose)
                if !subject.isCurrentlyPresent {
                    if let removedAt = subject.removedAt { LabeledContent("离群日期") { Text(removedAt, format: .dateTime.year().month().day()) } }
                }
                if let birth = subject.birthAt, birth <= detail.factsReadAt {
                    let months = Calendar.farm(identifier: detail.timeZoneIdentifier).dateComponents([.month], from: birth, to: detail.factsReadAt).month ?? 0
                    LabeledContent("月龄", value: "\(months) 个月")
                    if subject.sex == .ewe, detail.reproductionState?.completedParity == 0 {
                        let confirmed = detail.managementSettings.youthBreedingConfirmedSheepIDs.contains(subject.id)
                        let maturityDate = Calendar.farm(identifier: detail.timeZoneIdentifier).date(byAdding: .month, value: detail.managementSettings.minimumAgeMonths, to: birth) ?? detail.factsReadAt
                        LabeledContent("参配确认", value: detail.factsReadAt <= maturityDate ? "未超过参配月龄" : confirmed ? "已人工确认" : "待人工确认")
                    }
                }
                if subject.sex == .ram {
                    LabeledContent("已记录配种", value: "\(detail.recordedBreedingCount) 条")
                    LabeledContent("已关联后代", value: "\(detail.recordedOffspringCount) 只")
                    NavigationLink("查看后代与系谱") { SheepPedigreeView(account: account, farm: farm, sheepID: subject.id) }
                }
                if subject.purpose == SheepPurpose.sucklingLamb.rawValue || subject.purpose == SheepPurpose.weanedLamb.rawValue {
                    if let birth = subject.birthAt {
                        let days = Calendar.farm(identifier: detail.timeZoneIdentifier).dateComponents([.day], from: Calendar.farm(identifier: detail.timeZoneIdentifier).startOfDay(for: birth), to: Calendar.farm(identifier: detail.timeZoneIdentifier).startOfDay(for: detail.factsReadAt)).day ?? 0
                        LabeledContent("日龄", value: "\(days) 天")
                    }
                    LabeledContent("断奶事实", value: detail.weanedAt == nil ? "未记录断奶" : "已记录断奶")
                }
                if let weanedAt = detail.weanedAt { LabeledContent("断奶日期") { Text(weanedAt, format: .dateTime.year().month().day()) } }
                if detail.isPreBreedingLamb {
                    LabeledContent("繁殖管理", value: "羔羊，未进入繁殖管理")
                    Text("尚无自身繁殖记录，不因缺少胎次资料列入繁殖待核实。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let cycle = detail.reproductionState {
                    LabeledContent("本轮繁殖状态", value: cycle.displayState)
                    LabeledContent("已完成产羔胎次", value: cycle.completedParity.map { "\($0) 胎" } ?? "待核实")
                    LabeledContent("本轮目标胎次", value: cycle.targetParity.map { "第 \($0) 胎" } ?? "待核实")
                    if let check = cycle.check {
                        LabeledContent("本轮检胎日期") { Text(check.occurredAt, format: .dateTime.year().month().day()) }
                        LabeledContent("检胎原始结果", value: check.result)
                    }
                    if let breeding = cycle.breeding { LabeledContent("本轮配种日期") { Text(breeding.occurredAt, format: .dateTime.year().month().day()) } }
                    if let last = cycle.lastLambingAt {
                        let days = Calendar.farm(identifier: detail.timeZoneIdentifier).dateComponents([.day], from: Calendar.farm(identifier: detail.timeZoneIdentifier).startOfDay(for: last), to: Calendar.farm(identifier: detail.timeZoneIdentifier).startOfDay(for: detail.factsReadAt)).day ?? 0
                        LabeledContent("距上次产羔", value: "\(days) 天")
                    }
                    if let expected = cycle.expectedLambingAt(days: detail.gestationDays, calendar: Calendar.farm(identifier: detail.timeZoneIdentifier)) {
                        LabeledContent("预计产羔（估算）") { Text(expected, format: .dateTime.year().month().day()) }
                    }
                    ForEach(cycle.issues, id: \.self) { Text(verbatim: $0).font(.footnote).foregroundStyle(.orange) }
                    if cycle.pregnancy == .recheck { Label("待复检", systemImage: "heart.text.square").foregroundStyle(.orange) }
                    NavigationLink(cycle.issues.isEmpty ? "本轮依据与繁殖历史" : "繁殖资料待核实",
                        value: SheepReproductionEvidenceRoute(eweID: subject.id))
                }
                if subject.purpose == SheepPurpose.fattening.rawValue {
                    if let start = detail.fatteningStartedAt {
                        LabeledContent("本次育肥开始") { Text(start, format: .dateTime.year().month().day()) }
                        let intervals = detail.weightGainIntervals.filter { $0.startDate >= start }
                        let days = intervals.reduce(0) { $0 + $1.intervalDays }
                        if days > 0 {
                            let gain = intervals.reduce(0.0) { $0 + $1.totalGainKilograms } / Double(days) * 1000
                            LabeledContent("本次育肥期日增重", value: "\(gain.formatted(.number.precision(.fractionLength(0)))) 克/天")
                        }
                    } else { Text("缺少可确认的育肥开始记录，暂不能计算育肥期表现。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var latestWeightSummary: some View {
        Section {
            if let latest = detailSnapshot?.canonicalWeights.last {
                NavigationLink {
                    List {
                        if let detailSnapshot { Section { SheepGrowthTrendView(detail: detailSnapshot) } }
                        rawWeightHistorySection
                    }
                        .navigationTitle("体重与增重")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("最近实测体重").font(.subheadline).foregroundStyle(.secondary)
                        Text("\(WeightPrecision.displayText(latest.kilogramsText)) 千克")
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        if let interval = detailSnapshot?.weightGainIntervals.last {
                            Text("最近区间日增重 \((interval.kilogramsPerDay * 1000).formatted(.number.precision(.fractionLength(0)))) 克/天")
                                .font(.subheadline).monospacedDigit()
                            Text("\(interval.startDate, format: .dateTime.month().day())—\(interval.endDate, format: .dateTime.month().day()) · \(interval.intervalDays) 天")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let detailSnapshot {
                            let days = Calendar.farm(identifier: detailSnapshot.timeZoneIdentifier).dateComponents([.day], from: Calendar.farm(identifier: detailSnapshot.timeZoneIdentifier).startOfDay(for: latest.occurredAt), to: Calendar.farm(identifier: detailSnapshot.timeZoneIdentifier).startOfDay(for: detailSnapshot.factsReadAt)).day ?? 0
                            Text("距上次称重 \(days) 天").font(.caption).foregroundStyle(.secondary)
                            if let threshold = detailSnapshot.managementSettings.weighingReminderDays, days >= threshold {
                                Label("待称重", systemImage: "scalemass").foregroundStyle(.orange)
                            }
                            if (detailSnapshot.weightGainIntervals.last?.kilogramsPerDay ?? 0) < 0 {
                                Label("最近区间体重下降，点击核对记录", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Text(latest.occurredAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("sheep-weight-history")
            } else {
                LabeledContent("最近体重", value: detailLoadError != nil ? "暂不可用" : isLoadingDetail ? "正在读取" : "未记录")
            }
        }
    }

    @ViewBuilder
    private var rawWeightHistorySection: some View {
        let records = detailSnapshot?.weights ?? []
        if !records.isEmpty {
            Section {
                DisclosureGroup("原始称重记录（全部 \(records.count) 条）") {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(WeightPrecision.displayText(record.kilogramsText)) 千克")
                                .monospacedDigit()
                            Text(record.occurredAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: "来源：" + record.source.displayName)
                                .font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                }
            } footer: {
                Text("保留全部原始测量，包括同日重称；不受上方图表范围筛选影响。图表计算采用每日有效体重点。")
            }
        }
    }

    @ViewBuilder
    private var analyticsSection: some View {
        if let reproductionInsight = detailSnapshot?.reproductionInsight, !reproductionInsight.details.isEmpty {
            Section(LocalizedStringKey(reproductionInsight.title)) {
                Text(LocalizedStringKey(reproductionInsight.summary))
                ForEach(reproductionInsight.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var purposeTimelineSection: some View {
        let entries = detailSnapshot?.purposeTimeline ?? []
        Section {
            if isLoadingDetail, detailSnapshot == nil {
                ProgressView("正在读取用途时间线")
            } else if entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: subject.purpose)
                        .font(.subheadline.weight(.medium))
                    Text("现有用途来自历史档案；此前没有可追溯的用途变更记录。今后每次修改都会保留时间、前后用途和原因。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: entry.transitionText)
                            .font(.subheadline.weight(.medium))
                        Text(entry.occurredAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if !entry.reason.isEmpty {
                            Text(verbatim: entry.reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("用途时间线")
        } footer: {
            Text("档案中的“用途”是当前投影；这里保存每次明确变更的历史事实。")
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
                        Text(LocalizedStringKey(entry.title)).font(.subheadline.weight(.medium))
                        if !entry.detail.isEmpty { Text(LocalizedStringKey(entry.detail)).font(.footnote).foregroundStyle(.secondary) }
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
            let updatedDetail = try await SheepDetailSnapshotActor(container: modelContext.container).load(
                farmID: farm.id,
                sheepID: subject.id,
                subject: subject
            )
            try Task.checkCancellation()
            detailSnapshot = updatedDetail
            detailLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            detailLoadError = error.localizedDescription
        }
    }

    @MainActor
    private func reloadEntryAndDetail() async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            let actor = SheepDetailSnapshotActor(container: modelContext.container)
            guard let updatedEntry = try await actor.loadEntry(
                farmID: farm.id,
                sheepID: subject.id
            ) else {
                detailLoadError = "羊只档案不存在。"
                return
            }
            try Task.checkCancellation()
            let updatedDetail = try await actor.load(
                farmID: farm.id,
                sheepID: updatedEntry.subject.id,
                subject: updatedEntry.subject
            )
            try Task.checkCancellation()
            subject = updatedEntry.subject
            penName = updatedEntry.penName
            avatarPhoto = updatedEntry.avatarPhoto
            detailSnapshot = updatedDetail
            detailLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            detailLoadError = error.localizedDescription
        }
    }

    @MainActor
    private func prepareProfileEditing() {
        do {
            let sheepID = subject.id
            let farmID = farm.id
            guard let record = try modelContext.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
            })).first else {
                detailLoadError = "羊只档案不存在。"
                return
            }
            editingSheep = record
        } catch {
            detailLoadError = error.localizedDescription
        }
    }

    private func addPhoto(_ item: PhotosPickerItem, setAsAvatar: Bool) {
        guard !isProcessingPhoto else { return }
        isProcessingPhoto = true
        Task {
            defer {
                isProcessingPhoto = false
                selectedPhoto = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoTransferError.sourceUnreadable }
                try await persistPhoto(data, setAsAvatar: setAsAvatar)
            } catch {
                await collaboration.synchronizeNow()
                photoMessage = error.localizedDescription
            }
        }
    }

    private func addCapturedPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            photoMessage = PhotoTransferError.imageEncodeFailed.localizedDescription
            return
        }
        guard !isProcessingPhoto else { return }
        isProcessingPhoto = true
        Task {
            defer { isProcessingPhoto = false }
            do {
                try await persistPhoto(data, setAsAvatar: true)
            } catch {
                await collaboration.synchronizeNow()
                photoMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func persistPhoto(_ data: Data, setAsAvatar: Bool) async throws {
        let preflightContext = ModelContext(modelContext.container)
        let automaticAvatarPlan = try SheepAvatarSelectionStore.photoAdditionPlan(
            sheepID: subject.id,
            farmID: farm.id,
            context: preflightContext
        )
        let assetID = try await collaboration.photoTransfers.enqueue(
            data: data,
            farmID: farm.id,
            entityID: subject.id
        )
        var automaticallySelectedPhotoAssetID: UUID?
        do {
            // `enqueue` commits through PhotoTransferActor's context. Use a
            // fresh context so avatar validation observes the committed photo
            // instead of a stale view-context snapshot.
            let commandContext = ModelContext(modelContext.container)
            let automaticPhotoAssetID = try SheepAvatarSelectionStore.automaticSelectionAfterAdding(
                photoAssetID: assetID,
                plan: automaticAvatarPlan,
                sheepID: subject.id,
                farmID: farm.id,
                context: commandContext
            )
            let avatarAssetID = setAsAvatar ? assetID : automaticPhotoAssetID
            automaticallySelectedPhotoAssetID = setAsAvatar ? nil : automaticPhotoAssetID
            if let avatarAssetID {
                try commandService.setSheepAvatar(
                    sheepID: subject.id,
                    photoAssetID: avatarAssetID,
                    in: farmContext,
                    context: commandContext
                )
            }
        } catch {
            // The photo itself has already been committed. Never hide it from
            // the timeline merely because the separate avatar command failed.
            await reloadEntryAndDetail()
            throw error
        }

        // Local bytes and profile selection are authoritative for immediate
        // display. Do not make the banner wait for a cloud round trip.
        await reloadEntryAndDetail()
        await collaboration.synchronizeNow()
        await reloadEntryAndDetail()
        photoMessage = collaboration.lastErrorMessage ?? (setAsAvatar
            ? "已拍摄并设为羊只头像，照片已进入云端同步队列。"
            : automaticallySelectedPhotoAssetID == assetID
                ? "照片已保存；当前唯一照片已自动设为羊只头像。"
                : automaticallySelectedPhotoAssetID != nil
                    ? "照片已保存；原唯一照片继续作为羊只头像。"
                : "照片已压缩保存并进入云端同步队列。")
    }

    private func setAvatar(photoAssetID: UUID?) {
        do {
            try commandService.setSheepAvatar(
                sheepID: subject.id,
                photoAssetID: photoAssetID,
                in: farmContext,
                context: modelContext
            )
            photoMessage = photoAssetID == nil ? "已恢复系统默认头像。" : "已设为羊只头像。"
            Task {
                await reloadEntryAndDetail()
                await collaboration.synchronizeNow()
            }
        } catch {
            photoMessage = "头像更新失败：\(error.localizedDescription)"
        }
    }

    private var farmContext: FarmContext {
        FarmContext(
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            role: farm.role
        )
    }

    private func exportSingleSheep() {
        guard !isPreparingExport, farmContext.capabilities.allows(.readFarm) else { return }
        isPreparingExport = true
        Task {
            defer { isPreparingExport = false }
            do {
                let data = try await SheepDetailSnapshotActor(container: modelContext.container).singleSheepXLSXData(
                    farmID: farm.id,
                    sheepID: subject.id,
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

    private var currentParityDisplayName: String {
        guard let parity = detailSnapshot?.currentParity else { return "未确认" }
        return parity == 0 ? "0（尚未产羔）" : "第 \(parity) 胎"
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
                await reloadEntryAndDetail()
                await collaboration.synchronizeNow()
            }
        } catch {
            photoMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}

private struct SheepProfileBanner: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var displayedPhotoID: UUID?
    let sheep: SheepDetailSubjectSnapshot
    let penName: String?
    let photos: [SheepPhotoReference]
    let photoCount: Int
    let canEdit: Bool
    let isProcessing: Bool
    let onPreview: (UUID?) -> Void
    let onCamera: () -> Void

    private var hasPhotos: Bool { !photos.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(LocalizedStringKey(sheep.status.displayName))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(hasPhotos ? Color.black.opacity(0.38) : AppTheme.brand.opacity(0.12), in: .capsule)
                Spacer(minLength: 0)
                if canEdit {
                    Button(action: onCamera) {
                        Group {
                            if isProcessing { ProgressView() }
                            else { Image(systemName: "camera") }
                        }
                        .frame(width: 44, height: 44)
                        .background(hasPhotos ? Color.black.opacity(0.38) : AppTheme.brand.opacity(0.12), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                    .accessibilityLabel("拍摄并设置羊只头像")
                }
            }
            Spacer(minLength: hasPhotos ? 64 : 28)
            VStack(alignment: .leading, spacing: 9) {
                Text(verbatim: sheep.earTag)
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.rounded)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(sheep.breed.isEmpty ? "未填写品种" : sheep.breed) · \(sheep.sex.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(hasPhotos ? Color.white.opacity(0.88) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(hasPhotos ? Color.white.opacity(0.22) : Color.primary.opacity(0.10))
                    .frame(height: 0.5)
                    .padding(.vertical, 3)
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                layout {
                    Label(sheep.currentPenDisplayName(penName), systemImage: "square.grid.2x2")
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hasPhotos {
                        Button { onPreview(displayedPhotoID) } label: {
                            Label("查看照片（\(photoCount)）", systemImage: "photo.stack")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(Color.white.opacity(0.16), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sheep-banner-photos")
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: hasPhotos ? 300 : 230, alignment: .leading)
        .foregroundStyle(hasPhotos ? Color.white : Color.primary)
        .background {
            GeometryReader { proxy in
                if hasPhotos {
                    Button { onPreview(displayedPhotoID) } label: {
                        SheepBannerPhotoView(photos: photos, sex: sheep.sex, onPhotoLoaded: { displayedPhotoID = $0 })
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .overlay {
                                LinearGradient(
                                    stops: [
                                        .init(color: .black.opacity(0.28), location: 0),
                                        .init(color: .black.opacity(0.06), location: 0.28),
                                        .init(color: .black.opacity(0.68), location: 0.62),
                                        .init(color: .black.opacity(0.90), location: 1),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看羊只照片，共 \(photoCount) 张")
                } else {
                    LinearGradient(
                        colors: [AppTheme.brand.opacity(0.14), Color(uiColor: .secondarySystemGroupedBackground)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "sheep")
                            .font(.system(size: 110, weight: .light))
                            .foregroundStyle(AppTheme.brand.opacity(0.09))
                            .padding(.top, 50)
                            .padding(.trailing, 20)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }
}

private struct SheepCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

private struct PhotoTimelineRow: View {
    let photo: SheepDetailPhotoSnapshot
    let canEdit: Bool
    let onPreview: () -> Void
    let onEdit: () -> Void

    private var displayedDate: Date { photo.displayedAt }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPreview) {
                CloudPhotoThumbnail(
                    assetID: photo.id,
                    digest: photo.sha256,
                    width: 82,
                    height: 82,
                    cornerRadius: 14
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看羊只照片大图")

            Group {
                if canEdit {
                    Button(action: onEdit) {
                        metadata
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("修改照片时间")
                } else {
                    metadata
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
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
        .foregroundStyle(.primary)
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
    @Environment(\.displayScale) private var displayScale
    let assetID: UUID
    let digest: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    @State private var thumbnail: ImageThumbnail?
    @State private var didFail = false

    init(assetID: UUID, digest: String, width: CGFloat = 104, height: CGFloat = 104, cornerRadius: CGFloat = 16) {
        self.assetID = assetID
        self.digest = digest
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(
                    decorative: thumbnail.cgImage,
                    scale: thumbnail.scale,
                    orientation: .up
                )
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Image(systemName: "sheep")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.brand)
            } else {
                ProgressView()
            }
        }
        .frame(width: width, height: height)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: cornerRadius))
        .task(id: PhotoLoadKey(
            assetID: assetID,
            digest: digest,
            width: width,
            height: height,
            displayScale: displayScale
        )) {
            thumbnail = nil
            didFail = false
            guard let data = try? await collaboration.loadPhotoData(assetID: assetID),
                  !Task.isCancelled else {
                didFail = !Task.isCancelled
                return
            }
            let loaded = await ImageThumbnailPipeline.shared.thumbnail(
                data: data,
                digest: digest,
                targetSize: CGSize(width: width, height: height),
                scale: displayScale
            )
            guard !Task.isCancelled else { return }
            thumbnail = loaded
            didFail = loaded == nil
        }
    }

    private struct PhotoLoadKey: Hashable {
        let assetID: UUID
        let digest: String
        let width: CGFloat
        let height: CGFloat
        let displayScale: CGFloat
    }
}

struct PenManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudCollaborationStore.self) private var collaboration

    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAddingPen = false
    @State private var displayScope: PenDisplayScope
    @State private var rows: [PenManagementRowSnapshot] = []
    @State private var loadRevision = 0
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var loadError: String?

    init(account: AccountProfile, farm: FarmRecord, initialScope: PenDisplayScope = .all) {
        self.account = account
        self.farm = farm
        _displayScope = State(initialValue: initialScope)
    }

    private var displayedPens: [PenManagementRowSnapshot] { rows.filter(displayScope.includes) }

    var body: some View {
        List {
            if isLoading && rows.isEmpty {
                ProgressView("正在整理圈舍")
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(displayedPens) { pen in
                    NavigationLink {
                        PenDetailEntryView(
                            account: account,
                            farm: farm,
                            penID: pen.id
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pen.name).font(.headline)
                            Text(pen.statusText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if hasLoaded && !isLoading && displayedPens.isEmpty {
                if let loadError {
                    ContentUnavailableView(
                        "无法读取圈舍",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else {
                    ContentUnavailableView(
                        "暂无符合条件的羊舍",
                        systemImage: "building.2",
                        description: Text("可切换显示范围，或点击“新建羊舍”。空舍可继续使用，停用不会删除历史。")
                    )
                }
            }
        }
        .navigationTitle("羊舍管理")
        .task(id: PenManagementLoadRequest(
            farmID: farm.id,
            revision: loadRevision,
            syncCompletedAt: collaboration.lastSuccessfulSyncAt
        )) {
            await reloadPens()
        }
        .onAppear {
            guard hasLoaded else { return }
            loadRevision &+= 1
        }
        .refreshable {
            await reloadPens()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("显示范围", selection: $displayScope) {
                        ForEach(PenDisplayScope.allCases) { scope in
                            Text(LocalizedStringKey(scope.title)).tag(scope)
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel("圈舍显示范围")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建羊舍", systemImage: "plus") { isAddingPen = true }
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("add-pen")
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
            }
        }
        .sheet(isPresented: $isAddingPen, onDismiss: { loadRevision &+= 1 }) {
            NavigationStack {
                AddPenView(account: account, farm: farm, onCreated: { displayScope = .all })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: FarmOperationalAlertRuntimeNotification.refreshRequested)) { notification in
            guard FarmOperationalAlertRuntimeNotification.farmID(from: notification) == farm.id else { return }
            loadRevision &+= 1
        }
        .farmExcelImport(account: account, farm: farm, sheets: ["圈舍"])
    }

    @MainActor
    private func reloadPens() async {
        if rows.isEmpty { isLoading = true }
        do {
            let loaded = try await PenManagementSnapshotActor(
                container: modelContext.container
            ).loadList(farmID: farm.id)
            try Task.checkCancellation()
            if rows != loaded {
                rows = loaded
            }
            loadError = nil
            hasLoaded = true
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
            hasLoaded = true
            isLoading = false
        }
    }
}

private struct PenManagementLoadRequest: Hashable, Sendable {
    let farmID: UUID
    let revision: Int
    let syncCompletedAt: Date?
}

struct PenDetailEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudCollaborationStore.self) private var collaboration

    let account: AccountProfile
    let farm: FarmRecord
    let penID: UUID

    @State private var snapshot: PenDetailSnapshot?
    @State private var herdInsight: FarmInsight?
    @State private var loadRevision = 0
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var editingPen: PenRecord?
    @State private var actionError: String?

    var body: some View {
        Group {
            if let snapshot {
                PenDetailView(
                    account: account,
                    farm: farm,
                    snapshot: snapshot,
                    herdInsight: herdInsight ?? PenHerdInsightBuilder.insight(
                        penName: snapshot.pen.name,
                        members: snapshot.analysisMembers
                    ),
                    onEdit: prepareEditing
                )
            } else if isLoading {
                ProgressView("正在读取圈舍")
            } else {
                ContentUnavailableView(
                    "圈舍不存在",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError ?? "该圈舍可能已删除或不属于当前牧场。")
                )
            }
        }
        .task(id: PenDetailLoadRequest(
            farmID: farm.id,
            penID: penID,
            revision: loadRevision,
            syncCompletedAt: collaboration.lastSuccessfulSyncAt
        )) {
            await reloadDetail()
        }
        .refreshable {
            await reloadDetail()
        }
        .sheet(item: $editingPen, onDismiss: {
            let id = penID
            let farmID = farm.id
            if let pen = try? modelContext.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
                $0.id == id && $0.farmID == farmID
            })).first, pen.deletedAt != nil { dismiss() }
            else { loadRevision &+= 1 }
        }) { editingPen in
            NavigationStack {
                EditPenView(account: account, farm: farm, pen: editingPen)
            }
        }
        .alert("无法编辑圈舍", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @MainActor
    private func reloadDetail() async {
        if snapshot == nil { isLoading = true }
        do {
            let loaded = try await PenManagementSnapshotActor(
                container: modelContext.container
            ).loadDetail(farmID: farm.id, penID: penID)
            try Task.checkCancellation()
            guard let loaded else {
                snapshot = nil
                herdInsight = nil
                loadError = "该圈舍可能已删除或不属于当前牧场。"
                hasLoaded = true
                isLoading = false
                return
            }
            let fallback = PenHerdInsightBuilder.insight(
                penName: loaded.pen.name,
                members: loaded.analysisMembers
            )
            let insight = (try? await PenAnalyticsReadActor(
                container: modelContext.container
            ).insight(
                farmID: farm.id,
                penName: loaded.pen.name,
                members: loaded.analysisMembers
            )) ?? fallback
            try Task.checkCancellation()
            if snapshot != loaded {
                snapshot = loaded
            }
            if herdInsight != insight {
                herdInsight = insight
            }
            loadError = nil
            hasLoaded = true
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
            hasLoaded = true
            isLoading = false
        }
    }

    @MainActor
    private func prepareEditing() {
        var descriptor = FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.id == penID && $0.deletedAt == nil
        })
        descriptor.fetchLimit = 1
        do {
            guard let pen = try modelContext.fetch(descriptor).first,
                  pen.farmID == farm.id else {
                actionError = "该圈舍已不存在或不属于当前牧场。"
                return
            }
            editingPen = pen
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct PenDetailLoadRequest: Hashable, Sendable {
    let farmID: UUID
    let penID: UUID
    let revision: Int
    let syncCompletedAt: Date?
}

private struct PenDetailView: View {
    let account: AccountProfile
    let farm: FarmRecord
    let snapshot: PenDetailSnapshot
    let herdInsight: FarmInsight
    let onEdit: () -> Void

    var body: some View {
        List {
            Section("羊舍状态") {
                Text(snapshot.pen.statusText)
            }
            if !snapshot.pen.note.isEmpty {
                Section("说明") { Text(snapshot.pen.note) }
            }
            Section(LocalizedStringKey(herdInsight.title)) {
                Text(LocalizedStringKey(herdInsight.summary))
                ForEach(herdInsight.details, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("当前羊只") {
                if snapshot.sheep.isEmpty {
                    Text("当前没有在场羊只").foregroundStyle(.secondary)
                }
                ForEach(snapshot.sheep) { item in
                    NavigationLink {
                        SheepDetailEntryView(
                            account: account,
                            farm: farm,
                            sheepID: item.id
                        )
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.earTag)
                            if let state = item.reproductionState { Text(verbatim: state).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle(snapshot.pen.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑", action: onEdit)
                    .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
            }
        }
    }
}

struct AddSheepView: View {
    @State private var entrySession = ProductionEntrySession()
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
    @State private var currentParityText = ""
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }

    private var productionFields: [ProductionDraftField] {
        [
            ProductionDraftField("earTag", $earTag),
            ProductionDraftField("breed", $breed, carry: true),
            ProductionDraftField("sex", $sex, carry: true),
            ProductionDraftField("penID", $penID, reset: { nil }),
            ProductionDraftField("occurredAt", $occurredAt, carry: true),
            ProductionDraftField("birthAt", $birthAt, reset: { nil }),
            ProductionDraftField("currentParityText", $currentParityText),
            ProductionDraftField("note", $note)
        ]
    }

    var body: some View {
        Form {
            ProductionEntryFeedback(session: entrySession)
            Section("基础信息") {
                TextField("耳号", text: $earTag)
                TextField("品种", text: $breed)
                Picker("性别", selection: $sex) { ForEach(SheepSex.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }
            }
            if sex == .ewe {
                Section {
                    ProductionValueField(title: "当前胎次", text: $currentParityText, unit: "胎", keyboard: .numberPad)
                } header: {
                    Text("繁殖信息")
                } footer: {
                    Text("留空按 0 胎保存；只有当前胎次明确为 0 的青年母羊，下一次产羔才会记为第 1 胎。")
                }
            }
            Section("发生时间") {
                DatePicker("入场时间", selection: $occurredAt); ProductionTimeModeControl(session: entrySession)
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
        .productionEntry(entrySession, form: "AddSheepView", account: account, farm: farm, fields: productionFields, save: save)
        .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(LocalizedStringKey(errorMessage ?? "")) }
        .farmExcelImport(account: account, farm: farm, sheets: ["新建羊只"])
    }

    private func save() {
        do {
            let parityText = currentParityText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard parityText.isEmpty || (Int(parityText).map { $0 >= 0 } == true) else {
                errorMessage = "当前胎次必须是大于或等于 0 的整数。"
                return
            }
            try entrySession.execute(.addSheep(earTag: earTag, breed: breed, sex: sex, penID: penID, occurredAt: occurredAt, birthAt: birthAt, currentParity: sex == .ewe ? (Int(parityText) ?? 0) : nil, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            entrySession.complete()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AddPenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    var onCreated: () -> Void = {}
    private let commandService = FarmCommandService()
    @State private var name = ""
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("羊舍名称", text: $name)
            TextField("说明", text: $note, axis: .vertical).lineLimit(2...4)
            Text("新建羊舍默认为启用空舍。同一牧场的羊舍名称不能重复，已停用羊舍也保留名称。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("保存后由本机接收。云端牧场的确认结果可在首页保存状态中查看，无需重复新建。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("新建羊舍")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(PenManagementPolicy.normalizedName(name).isEmpty)
            }
        }
        .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(LocalizedStringKey(errorMessage ?? "")) }
        .farmExcelImport(account: account, farm: farm, sheets: ["圈舍"])
    }

    private func save() {
        do {
            try commandService.execute(.createPen(name: name, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            onCreated()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
