import SwiftData
import SwiftUI

struct EditPenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let pen: PenRecord
    private let commandService = FarmCommandService()
    @State private var name: String
    @State private var note: String
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, pen: PenRecord) {
        self.account = account
        self.farm = farm
        self.pen = pen
        _name = State(initialValue: pen.name)
        _note = State(initialValue: pen.note)
    }

    var body: some View {
        Form {
            Section("圈舍资料") {
                TextField("圈舍名称", text: $name)
                TextField("说明", text: $note, axis: .vertical).lineLimit(2...5)
            }
            Section("状态") {
                LabeledContent("当前状态", value: pen.isActive ? "启用" : "已停用")
                Button(pen.isActive ? LocalizedStringKey("停用圈舍") : LocalizedStringKey("重新启用圈舍"), role: pen.isActive ? .destructive : nil) {
                    setActive(!pen.isActive)
                }
            }
        }
        .navigationTitle("编辑圈舍")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        execute(.updatePen(penID: pen.id, name: name, note: note), dismissOnSuccess: true)
    }

    private func setActive(_ value: Bool) {
        execute(.setPenActive(penID: pen.id, isActive: value), dismissOnSuccess: true)
    }

    private func execute(_ command: FarmCommand, dismissOnSuccess: Bool) {
        do {
            try commandService.execute(command, in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            if dismissOnSuccess { dismiss() }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct EditSheepProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReproductionRecord.occurredAt, order: .reverse) private var reproduction: [ReproductionRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let sheep: SheepRecord
    private let commandService = FarmCommandService()
    @State private var earTag: String
    @State private var breed: String
    @State private var sex: SheepSex
    @State private var hasBirthDate: Bool
    @State private var birthAt: Date
    @State private var currentParityText = ""
    @State private var originalCurrentParity: Int?
    @State private var note: String
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, sheep: SheepRecord) {
        self.account = account
        self.farm = farm
        self.sheep = sheep
        _earTag = State(initialValue: sheep.earTag)
        _breed = State(initialValue: sheep.breed)
        _sex = State(initialValue: sheep.sex)
        _hasBirthDate = State(initialValue: sheep.birthAt != nil)
        _birthAt = State(initialValue: sheep.birthAt ?? sheep.enteredAt)
        _note = State(initialValue: sheep.note)
    }

    var body: some View {
        Form {
            Section("基础信息") {
                TextField("耳号", text: $earTag)
                TextField("品种", text: $breed)
                Picker("性别", selection: $sex) {
                    ForEach(SheepSex.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
            }
            Section("出生信息") {
                Toggle("记录出生日期", isOn: $hasBirthDate)
                if hasBirthDate { DatePicker("出生日期", selection: $birthAt, in: ...Date.now, displayedComponents: .date) }
            }
            if sex == .ewe {
                Section {
                    TextField("当前胎次", text: $currentParityText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("繁殖信息")
                } footer: {
                    Text("留空按 0 胎保存。修改后会保留一条带时间的胎次确认事实，不会改写已有产羔记录。")
                }
            }
            Section("备注") { TextField("可选", text: $note, axis: .vertical).lineLimit(2...5) }
        }
        .navigationTitle("编辑羊只档案")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
        .onAppear(perform: loadCurrentParity)
    }

    private func loadCurrentParity() {
        let value = LambingEntrySemantics.currentParity(eweID: sheep.id, farmID: farm.id, before: .distantFuture, records: reproduction)
        originalCurrentParity = value
        currentParityText = String(value)
    }

    private func save() {
        do {
            let parityText = currentParityText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard parityText.isEmpty || (Int(parityText).map { $0 >= 0 } == true) else {
                errorMessage = "当前胎次必须是大于或等于 0 的整数。"
                return
            }
            let enteredParity = sex == .ewe ? (Int(parityText) ?? 0) : nil
            let changedParity = enteredParity != originalCurrentParity ? enteredParity : nil
            try commandService.execute(
                .updateSheepProfile(sheepID: sheep.id, earTag: earTag, breed: breed, sex: sex, birthAt: hasBirthDate ? birthAt : nil, currentParity: changedParity, parityRecordedAt: changedParity == nil ? nil : .now, note: note),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SheepPurposeEditorEntryView: View {
    @Query private var sheep: [SheepRecord]
    let account: AccountProfile
    let farm: FarmRecord

    init(account: AccountProfile, farm: FarmRecord, sheepID: UUID) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _sheep = Query(filter: #Predicate<SheepRecord> {
            $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
        })
    }

    var body: some View {
        if let record = sheep.first {
            SheepPurposeEditorView(account: account, farm: farm, sheep: record)
        } else {
            ContentUnavailableView("羊只档案不存在", systemImage: "exclamationmark.triangle")
        }
    }
}

struct SheepPurposeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let sheep: SheepRecord

    @State private var selectedPurpose: SheepPurpose?
    @State private var reason = ""
    @State private var errorMessage: String?
    private let commandService = FarmCommandService()

    init(account: AccountProfile, farm: FarmRecord, sheep: SheepRecord) {
        self.account = account
        self.farm = farm
        self.sheep = sheep
        let initial = sheep.isBreedingRam && sheep.sex == .ram
            ? SheepPurpose.breedingRam
            : SheepPurpose(rawValue: sheep.purpose.trimmingCharacters(in: .whitespacesAndNewlines))
        _selectedPurpose = State(initialValue: initial)
    }

    private var canEdit: Bool {
        CapabilitySet(role: farm.role).allows(.editHistoricalFacts)
    }

    private var normalizedStoredPurpose: String {
        let value = sheep.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? SheepPurpose.unclassified.rawValue : value
    }

    private var isUnchanged: Bool {
        guard let selectedPurpose else { return true }
        return normalizedStoredPurpose == selectedPurpose.rawValue &&
            sheep.isBreedingRam == (selectedPurpose == .breedingRam)
    }

    private var validationMessage: String? {
        guard canEdit else { return "当前账号没有修改羊只用途的权限。" }
        guard let selectedPurpose else { return "请选择一个标准用途。" }
        guard selectedPurpose.isAllowed(for: sheep.sex) else { return "所选用途与羊只性别不匹配。" }
        guard !isUnchanged else { return "当前用途没有变化。" }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请填写用途变更原因。"
        }
        return nil
    }

    var body: some View {
        Form {
            Section("当前档案") {
                LabeledContent("耳号", value: sheep.earTag)
                LabeledContent("性别", value: sheep.sex.displayName)
                LabeledContent("已有用途", value: normalizedStoredPurpose)
                if sheep.isBreedingRam {
                    LabeledContent("父本资格", value: "已确认种公羊")
                }
            }

            Section {
                Picker("新用途", selection: $selectedPurpose) {
                    if SheepPurpose(rawValue: normalizedStoredPurpose) == nil,
                       !sheep.isBreedingRam {
                        Text("保留现有用途 · \(normalizedStoredPurpose)")
                            .tag(SheepPurpose?.none)
                    }
                    ForEach(SheepPurpose.choices(for: sheep.sex)) { purpose in
                        Text(purpose.displayName).tag(SheepPurpose?.some(purpose))
                    }
                }
            } header: {
                Text("生产用途")
            } footer: {
                Text("已有用途不会自动改动。只有明确选择新用途并保存后才会写入；选择种公羊会同时建立父本资格，改为其他用途会取消该资格。")
            }

            Section("变更原因") {
                TextField("例如：现场核对生产分群后确认（必填）", text: $reason, axis: .vertical)
            }

            if let validationMessage, !isUnchanged || selectedPurpose == nil {
                Section("无法保存") {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("羊只用途")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EntrySaveToolbar(action: save, isDisabled: validationMessage != nil)
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        if let validationMessage {
            errorMessage = validationMessage
            return
        }
        guard let selectedPurpose else { return }
        do {
            try commandService.execute(
                .care(.setSheepPurpose(
                    sheepID: sheep.id,
                    purpose: selectedPurpose,
                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    expectedRevision: sheep.revision
                )),
                in: FarmContext(
                    accountID: account.effectiveAccountID,
                    farmID: farm.id,
                    role: farm.role
                ),
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SheepPurposeManagementView: View {
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var batchRequest: SheepPurposeBatchRequest?

    private var records: [SheepRecord] {
        let normalized = SearchText.normalized(query)
        return sheep.filter {
            $0.farmID == farm.id &&
                $0.deletedAt == nil &&
                (normalized.isEmpty ||
                    SearchText.normalized($0.earTag).contains(normalized) ||
                    SearchText.normalized($0.purpose).contains(normalized))
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Text("这里是羊只用途的唯一人工修改入口。可以逐只修改、列表多选，或按舍整批修改；现有用途只有确认保存后才会改变。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    SheepPurposePenBatchSelectionView(account: account, farm: farm)
                } label: {
                    Label("按舍批量修改", systemImage: "square.grid.3x3")
                }
            }
            Section("羊只档案 · \(records.count)") {
                ForEach(records, id: \.id) { record in
                    NavigationLink {
                        SheepPurposeEditorView(account: account, farm: farm, sheep: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.earTag)
                            Text(record.isBreedingRam ? SheepPurpose.breedingRam.displayName : record.purpose)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(record.id)
                }
            }
        }
        .navigationTitle("羊只用途管理")
        .searchable(text: $query, prompt: "耳号或用途")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            if !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("批量修改用途（\(selection.count)）", systemImage: "tag") {
                        batchRequest = SheepPurposeBatchRequest(
                            sheepIDs: selection,
                            sourceLabel: "用途列表多选"
                        )
                    }
                }
            }
        }
        .sheet(item: $batchRequest, onDismiss: { selection.removeAll() }) { request in
            NavigationStack {
                SheepPurposeBatchEditorEntryView(
                    account: account,
                    farm: farm,
                    request: request
                )
            }
        }
        .onChange(of: records.map(\.id)) { _, availableIDs in
            selection.formIntersection(Set(availableIDs))
        }
    }
}

struct SheepPurposeBatchRequest: Identifiable {
    let id = UUID()
    let sheepIDs: Set<UUID>
    let sourceLabel: String
}

private struct SheepPurposePenGroup: Identifiable {
    let penID: UUID?
    let name: String
    let sheep: [SheepRecord]

    var id: String { penID?.uuidString ?? "unassigned" }
}

struct SheepPurposePenBatchSelectionView: View {
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord

    private var groups: [SheepPurposePenGroup] {
        let currentSheep = sheep.filter {
            $0.farmID == farm.id &&
                $0.deletedAt == nil &&
                $0.isCurrentlyPresent
        }
        let penNames = Dictionary(uniqueKeysWithValues: pens.filter {
            $0.farmID == farm.id && $0.deletedAt == nil
        }.map { ($0.id, $0.name) })
        return Dictionary(grouping: currentSheep, by: \.currentPenID)
            .map { penID, records in
                SheepPurposePenGroup(
                    penID: penID,
                    name: penID.flatMap { penNames[$0] } ?? (penID == nil ? "未分圈" : "未知圈舍"),
                    sheep: records.sorted {
                        $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.penID == nil { return false }
                if rhs.penID == nil { return true }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        List(groups) { group in
            NavigationLink {
                SheepPurposeBatchEditorEntryView(
                    account: account,
                    farm: farm,
                    request: SheepPurposeBatchRequest(
                        sheepIDs: Set(group.sheep.map(\.id)),
                        sourceLabel: "圈舍：\(group.name)"
                    )
                )
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                    Text("当前在场 \(group.sheep.count) 只")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("按舍修改用途")
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("没有可用圈舍羊只", systemImage: "square.grid.3x3")
            }
        }
    }
}

struct SheepPurposeBatchEditorEntryView: View {
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let request: SheepPurposeBatchRequest

    init(account: AccountProfile, farm: FarmRecord, request: SheepPurposeBatchRequest) {
        self.account = account
        self.farm = farm
        self.request = request
        let farmID = farm.id
        _sheep = Query(filter: #Predicate<SheepRecord> {
            $0.farmID == farmID && $0.deletedAt == nil
        }, sort: \SheepRecord.earTag)
    }

    var body: some View {
        SheepPurposeBatchEditorView(
            account: account,
            farm: farm,
            sourceLabel: request.sourceLabel,
            requestedCount: request.sheepIDs.count,
            sheep: sheep.filter { request.sheepIDs.contains($0.id) }
        )
    }
}

struct SheepPurposeBatchEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let sourceLabel: String
    let requestedCount: Int
    let sheep: [SheepRecord]

    @State private var selectedPurpose: SheepPurpose?
    @State private var reason = ""
    @State private var showsConfirmation = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    private let commandService = FarmCommandService()

    private var canEdit: Bool {
        CapabilitySet(role: farm.role).allows(.editHistoricalFacts)
    }

    private var missingCount: Int {
        max(0, requestedCount - sheep.count)
    }

    private var invalidSheep: [SheepRecord] {
        guard let selectedPurpose else { return [] }
        return sheep.filter { !selectedPurpose.isAllowed(for: $0.sex) }
    }

    private var unchangedSheep: [SheepRecord] {
        guard let selectedPurpose else { return [] }
        return sheep.filter {
            selectedPurpose.isAllowed(for: $0.sex) &&
                $0.purpose.trimmingCharacters(in: .whitespacesAndNewlines) == selectedPurpose.rawValue &&
                $0.isBreedingRam == (selectedPurpose == .breedingRam)
        }
    }

    private var changedSheep: [SheepRecord] {
        guard let selectedPurpose else { return [] }
        let unchangedIDs = Set(unchangedSheep.map(\.id))
        return sheep.filter {
            selectedPurpose.isAllowed(for: $0.sex) && !unchangedIDs.contains($0.id)
        }
    }

    private var validationMessage: String? {
        guard canEdit else { return "当前账号没有修改羊只用途的权限。" }
        guard !sheep.isEmpty else { return "没有可修改的羊只。" }
        guard missingCount == 0 else { return "有 \(missingCount) 只羊的档案已经不存在或发生变化，请返回后重新选择。" }
        guard let selectedPurpose else { return "请选择目标用途。" }
        guard invalidSheep.isEmpty else {
            return "有 \(invalidSheep.count) 只羊的性别不允许设置为\(selectedPurpose.displayName)，整批不能保存。"
        }
        guard !changedSheep.isEmpty else { return "所选羊只已经全部是该用途和资格状态。" }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请填写批量用途变更原因。"
        }
        return nil
    }

    private var previewSheep: ArraySlice<SheepRecord> {
        sheep.prefix(100)
    }

    var body: some View {
        Form {
            Section("批量范围") {
                LabeledContent("选择来源", value: sourceLabel)
                LabeledContent("已选羊只", value: "\(requestedCount) 只")
                if missingCount > 0 {
                    LabeledContent("档案已变化", value: "\(missingCount) 只")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker("目标用途", selection: $selectedPurpose) {
                    Text("请选择").tag(SheepPurpose?.none)
                    ForEach(SheepPurpose.allCases) { purpose in
                        Text(purpose.displayName).tag(SheepPurpose?.some(purpose))
                    }
                }
            } header: {
                Text("目标用途")
            } footer: {
                Text("种公羊只允许公羊；后备母羊和繁殖母羊只允许母羊。批次中只要有一只不合法，整批都不会写入。")
            }

            if selectedPurpose != nil {
                Section("写入预览") {
                    LabeledContent("将修改", value: "\(changedSheep.count) 只")
                    LabeledContent("用途未变，自动跳过", value: "\(unchangedSheep.count) 只")
                    if !invalidSheep.isEmpty {
                        LabeledContent("不合法，阻止整批", value: "\(invalidSheep.count) 只")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("变更原因") {
                TextField("例如：按舍核对生产阶段后统一调整（必填）", text: $reason, axis: .vertical)
            }

            if let validationMessage {
                Section("无法保存") {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("羊只明细") {
                ForEach(previewSheep, id: \.id) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.earTag)
                            Text(record.purpose)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if invalidSheep.contains(where: { $0.id == record.id }) {
                            Label("不合法", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if unchangedSheep.contains(where: { $0.id == record.id }) {
                            Text("跳过")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if sheep.count > previewSheep.count {
                    Text("另有 \(sheep.count - previewSheep.count) 只，将按相同规则处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("批量修改用途")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存 \(changedSheep.count) 只") {
                    showsConfirmation = true
                }
                .disabled(validationMessage != nil || isSaving)
            }
        }
        .alert("确认批量修改用途？", isPresented: $showsConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认修改 \(changedSheep.count) 只") {
                Task { await save() }
            }
        } message: {
            Text("目标用途：\(selectedPurpose?.displayName ?? "未选择")。所有变更会在一个本地事务中提交；任一羊只校验失败，整批回滚。")
        }
        .recordErrorAlert($errorMessage)
    }

    @MainActor
    private func save() async {
        if let validationMessage {
            errorMessage = validationMessage
            return
        }
        guard let selectedPurpose else { return }
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = changedSheep
        isSaving = true
        await Task.yield()
        defer { isSaving = false }

        do {
            let commands = records.map { record in
                FarmCommand.care(.setSheepPurpose(
                    sheepID: record.id,
                    purpose: selectedPurpose,
                    reason: "\(normalizedReason)；批量范围：\(sourceLabel)，共 \(records.count) 只",
                    expectedRevision: record.revision
                ))
            }
            try commandService.executeBatch(
                commands,
                in: FarmContext(
                    accountID: account.effectiveAccountID,
                    farmID: farm.id,
                    role: farm.role
                ),
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SheepRecordHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var weights: [WeightRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var removals: [RemovalRecord]
    @Query private var photos: [PhotoAssetRecord]
    @Query private var tombstones: [TombstoneRecord]
    @Query private var pens: [PenRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let sheep: SheepRecord
    private let commandService = FarmCommandService()
    @State private var editingWeight: WeightRecord?
    @State private var editingTransfer: TransferRecord?
    @State private var editingRemoval: RemovalRecord?
    @State private var pendingDelete: RecordDeletionTarget?
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, sheep: SheepRecord) {
        self.account = account
        self.farm = farm
        self.sheep = sheep
        let farmID = farm.id
        let sheepID = sheep.id
        _weights = Query(
            filter: #Predicate<WeightRecord> { $0.farmID == farmID && $0.sheepID == sheepID },
            sort: \WeightRecord.occurredAt,
            order: .reverse
        )
        _transfers = Query(
            filter: #Predicate<TransferRecord> { $0.farmID == farmID && $0.sheepID == sheepID },
            sort: \TransferRecord.occurredAt,
            order: .reverse
        )
        _removals = Query(
            filter: #Predicate<RemovalRecord> { $0.farmID == farmID && $0.sheepID == sheepID },
            sort: \RemovalRecord.occurredAt,
            order: .reverse
        )
        _photos = Query(
            filter: #Predicate<PhotoAssetRecord> { $0.farmID == farmID && $0.sheepID == sheepID },
            sort: \PhotoAssetRecord.createdAt,
            order: .reverse
        )
        _tombstones = Query(
            filter: #Predicate<TombstoneRecord> { $0.farmID == farmID && $0.restoredAt == nil },
            sort: \TombstoneRecord.deletedAt,
            order: .reverse
        )
        _pens = Query(
            filter: #Predicate<PenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \PenRecord.name
        )
    }

    private var farmWeights: [WeightRecord] { weights.filter { $0.deletedAt == nil } }
    private var farmTransfers: [TransferRecord] { transfers.filter { $0.deletedAt == nil } }
    private var farmRemovals: [RemovalRecord] { removals.filter { $0.deletedAt == nil } }
    private var restorableTombstones: [TombstoneRecord] {
        var ids = Set<UUID>()
        ids.formUnion(weights.map(\.id))
        ids.formUnion(transfers.map(\.id))
        ids.formUnion(removals.map(\.id))
        ids.formUnion(photos.map(\.id))
        return tombstones.filter { ids.contains($0.entityID) && !$0.reason.hasPrefix("修正：") }
    }

    var body: some View {
        let displayedWeights = farmWeights
        let displayedTransfers = farmTransfers
        let displayedRemovals = farmRemovals
        let displayedTombstones = restorableTombstones
        List {
            weightSection(displayedWeights)
            transferSection(displayedTransfers)
            removalSection(displayedRemovals)
            restorableSection(displayedTombstones)
        }
        .navigationTitle("生产记录管理")
        .sheet(item: $editingWeight) { record in NavigationStack { CorrectWeightView(account: account, farm: farm, record: record) } }
        .sheet(item: $editingTransfer) { record in NavigationStack { CorrectTransferView(account: account, farm: farm, record: record) } }
        .sheet(item: $editingRemoval) { record in NavigationStack { CorrectRemovalView(account: account, farm: farm, record: record) } }
        .confirmationDialog("确认撤销记录", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("撤销并保留审计", role: .destructive) { deletePending() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { Text("撤销后会重新计算羊只历史状态，可在本页恢复。") }
        .recordErrorAlert($errorMessage)
    }

    @ViewBuilder private func weightSection(_ records: [WeightRecord]) -> some View {
        Section("称重") {
            if records.isEmpty { Text("暂无称重记录").foregroundStyle(.secondary) }
            ForEach(records, id: \.id) { record in
                historyRow(title: "\(record.kilogramsText) 千克", date: record.occurredAt, note: record.note) {
                    Button("修正") { editingWeight = record }
                    Button("撤销", role: .destructive) { pendingDelete = .init(type: .weight, id: record.id, title: "称重") }
                }
            }
        }
    }

    @ViewBuilder private func transferSection(_ records: [TransferRecord]) -> some View {
        Section("转群") {
            if records.isEmpty { Text("暂无转群记录").foregroundStyle(.secondary) }
            ForEach(records, id: \.id) { record in
                historyRow(title: penName(record.fromPenID) + " → " + penName(record.toPenID), date: record.occurredAt, note: record.note) {
                    Button("修正") { editingTransfer = record }
                    Button("撤销", role: .destructive) { pendingDelete = .init(type: .transfer, id: record.id, title: "转群") }
                }
            }
        }
    }

    @ViewBuilder private func removalSection(_ records: [RemovalRecord]) -> some View {
        Section("离场") {
            if records.isEmpty { Text("暂无离场记录").foregroundStyle(.secondary) }
            ForEach(records, id: \.id) { record in
                historyRow(title: removalTitle(record), date: record.occurredAt, note: record.note) {
                    Button("修正") { editingRemoval = record }
                    Button("撤销并恢复在场") { restoreRemoval(record) }
                }
            }
        }
    }

    private func removalTitle(_ record: RemovalRecord) -> String {
        let base = record.kind.displayName + " · " + record.reason
        guard record.removalBatchID != nil, record.kind == .sold,
              let total = record.batchTotalAmountText else { return base }
        return base + " · 同批总额 " + total
    }

    @ViewBuilder private func restorableSection(_ records: [TombstoneRecord]) -> some View {
        if !records.isEmpty {
            Section("可恢复记录") {
                ForEach(records, id: \.id) { tombstone in restoreButton(tombstone) }
            }
        }
    }

    private func restoreButton(_ tombstone: TombstoneRecord) -> some View {
        Button { restore(tombstone) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("恢复\(displayName(tombstone.entityType))")
                Text(tombstone.reason).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func historyRow<MenuContent: View>(title: String, date: Date, note: String, @ViewBuilder menu: () -> MenuContent) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                Text(date, format: .dateTime.year().month().day().hour().minute()).font(.footnote).foregroundStyle(.secondary)
                if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            Menu(content: menu) { Image(systemName: "ellipsis.circle") }.accessibilityLabel("记录操作")
        }
    }

    private func execute(_ command: FarmCommand) {
        do {
            try commandService.execute(command, in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
        } catch { errorMessage = error.localizedDescription }
    }

    private func deletePending() {
        guard let target = pendingDelete else { return }
        pendingDelete = nil
        execute(.tombstoneEntity(entityType: target.type, entityID: target.id, reason: "用户撤销\(target.title)记录"))
    }

    private func restoreRemoval(_ record: RemovalRecord) { execute(.restoreSheep(removalID: record.id)) }
    private func restore(_ tombstone: TombstoneRecord) { execute(.restoreTombstonedEntity(tombstoneID: tombstone.id)) }
    private func penName(_ id: UUID?) -> String { id.flatMap { id in pens.first { $0.id == id }?.name } ?? "未分圈" }
    private func displayName(_ raw: String) -> String { switch CloudEntityType(rawValue: raw) { case .weight: "称重记录"; case .transfer: "转群记录"; case .removal: "离场记录"; case .photoAsset: "照片"; default: "记录" } }
}

private struct RecordDeletionTarget {
    let type: CloudEntityType
    let id: UUID
    let title: String
}

struct CorrectWeightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile; let farm: FarmRecord; let record: WeightRecord
    @State private var kilograms: String; @State private var occurredAt: Date; @State private var note: String; @State private var reason = ""; @State private var errorMessage: String?
    init(account: AccountProfile, farm: FarmRecord, record: WeightRecord) { self.account = account; self.farm = farm; self.record = record; _kilograms = State(initialValue: record.kilogramsText); _occurredAt = State(initialValue: record.occurredAt); _note = State(initialValue: record.note) }
    var body: some View { correctionForm(title: "修正称重", fields: { TextField("体重（千克）", text: $kilograms).keyboardType(.decimalPad); DatePicker("发生时间", selection: $occurredAt); TextField("备注", text: $note) }, save: { .correctWeight(originalID: record.id, kilogramsText: kilograms, occurredAt: occurredAt, note: note, reason: reason) }) }
    private func correctionForm<Fields: View>(title: String, @ViewBuilder fields: () -> Fields, save: @escaping () -> FarmCommand) -> some View { Form { Section("替代记录") { fields() }; Section("修正原因") { TextField("必填", text: $reason, axis: .vertical) } }.navigationTitle(title).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { execute(save()) } } }.recordErrorAlert($errorMessage) }
    private func execute(_ command: FarmCommand) { do { try FarmCommandService().execute(command, in: .init(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription } }
}

struct CorrectTransferView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var modelContext; @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    let account: AccountProfile; let farm: FarmRecord; let record: TransferRecord
    @State private var toPenID: UUID?; @State private var occurredAt: Date; @State private var note: String; @State private var reason = ""; @State private var errorMessage: String?
    init(account: AccountProfile, farm: FarmRecord, record: TransferRecord) { self.account = account; self.farm = farm; self.record = record; _toPenID = State(initialValue: record.toPenID); _occurredAt = State(initialValue: record.occurredAt); _note = State(initialValue: record.note) }
    var body: some View { Form { Section("替代记录") { Picker("目标圈舍", selection: $toPenID) { Text("未分圈").tag(UUID?.none); ForEach(pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive }, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }; DatePicker("发生时间", selection: $occurredAt); TextField("备注", text: $note) }; Section("修正原因") { TextField("必填", text: $reason, axis: .vertical) } }.navigationTitle("修正转群").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) } }.recordErrorAlert($errorMessage) }
    private func save() { do { try FarmCommandService().execute(.correctTransfer(originalID: record.id, toPenID: toPenID, occurredAt: occurredAt, note: note, reason: reason), in: .init(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription } }
}

struct CorrectRemovalView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var modelContext
    let account: AccountProfile; let farm: FarmRecord; let record: RemovalRecord
    @State private var kind: RemovalKind; @State private var reason: String; @State private var amount: String; @State private var occurredAt: Date; @State private var note: String; @State private var correctionReason = ""; @State private var errorMessage: String?
    init(account: AccountProfile, farm: FarmRecord, record: RemovalRecord) { self.account = account; self.farm = farm; self.record = record; _kind = State(initialValue: record.kind); _reason = State(initialValue: record.reason); _amount = State(initialValue: record.amountText ?? ""); _occurredAt = State(initialValue: record.occurredAt); _note = State(initialValue: record.note) }
    var body: some View { Form { Section("替代记录") { Picker("类型", selection: $kind) { ForEach(RemovalKind.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }; TextField("离场原因", text: $reason); if record.removalBatchID != nil { if record.kind == .sold { LabeledContent("同批总售卖金额", value: record.batchTotalAmountText ?? "未填写") }; Text("同批离场只有一笔总额，不能在单羊修正中改写。").font(.footnote).foregroundStyle(.secondary) } else { TextField("售卖金额（可选）", text: $amount).keyboardType(.decimalPad) }; DatePicker("发生时间", selection: $occurredAt); TextField("备注", text: $note) }; Section("修正原因") { TextField("必填", text: $correctionReason, axis: .vertical) } }.navigationTitle("修正离场").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) } }.recordErrorAlert($errorMessage) }
    private func save() { do { try FarmCommandService().execute(.correctRemoval(originalID: record.id, kind: kind, reason: reason, amountText: record.removalBatchID == nil ? amount : nil, occurredAt: occurredAt, note: note, correctionReason: correctionReason), in: .init(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription } }
}
