import SwiftData
import SwiftUI

struct FarmRecordsView: View {
    @Environment(AppSession.self) private var session
    let account: AccountProfile
    let farm: FarmRecord
    @State private var presentedEntry: PendingRecordEntry?
    @State private var careReminderDestination: PendingCareReminderDestination?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                SettingsCard(title: "日常记录") {
                    SettingsNavigationRow(
                        title: "称重",
                        subtitle: "记录羊只体重和发生时间",
                        systemImage: "scalemass.fill",
                        iconColor: .blue
                    ) { WeightEntryView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "治疗或疫苗",
                        subtitle: "按羊只、多选或圈舍记录健康事件",
                        systemImage: "cross.case.fill",
                        iconColor: .red
                    ) { HealthBatchEntryView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "备注",
                        subtitle: "补充羊只、圈舍或牧场事件说明",
                        systemImage: "note.text",
                        iconColor: .gray
                    ) { NoteEntryView(account: account, farm: farm) }
                }

                SettingsCard(title: "羊只流转") {
                    SettingsNavigationRow(
                        title: "新建羊只",
                        subtitle: "建立档案并记录入场信息",
                        systemImage: "plus",
                        iconColor: .green
                    ) { AddSheepView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "转群",
                        subtitle: "将羊只调入目标圈舍",
                        systemImage: "arrow.left.arrow.right",
                        iconColor: .indigo
                    ) { TransferEntryView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "断奶",
                        subtitle: "记录断奶重并完成断奶后调舍",
                        systemImage: "leaf.circle.fill",
                        iconColor: .mint
                    ) { WeaningEntryView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "出售、淘汰或死亡",
                        subtitle: "记录羊只离场及相关金额",
                        systemImage: "person.crop.circle.badge.minus",
                        iconColor: .orange
                    ) { RemovalEntryView(account: account, farm: farm) }
                }

                SettingsCard(title: "繁殖记录") {
                    SettingsNavigationRow(
                        title: "配种或孕检",
                        subtitle: "记录配种、孕检和繁殖状态",
                        systemImage: "heart.text.square.fill",
                        iconColor: .pink
                    ) { ReproductionBatchEntryView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "产羔",
                        subtitle: "记录产羔事实并建立羔羊档案",
                        systemImage: "plus.circle.fill",
                        iconColor: .purple
                    ) { CareLambingEntryView(account: account, farm: farm) }
                }

                SettingsCard(title: "管理与查阅") {
                    SettingsNavigationRow(
                        title: "生产批次",
                        subtitle: "管理育肥、实验等生产批次",
                        systemImage: "square.3.layers.3d",
                        iconColor: .purple
                    ) { ProductionBatchListView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "健康与繁殖管理",
                        subtitle: "维护目录、库存、方案、提醒与历史",
                        systemImage: "heart.text.square",
                        iconColor: .pink
                    ) { CareManagementView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "事件记录与导出",
                        subtitle: "查看、筛选和导出牧场历史",
                        systemImage: "clock.arrow.circlepath",
                        iconColor: .blue
                    ) { FarmEventHistoryView(account: account, farm: farm) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("录入")
        .sheet(item: $presentedEntry) { entry in
            NavigationStack {
                switch entry {
                case .addSheep: AddSheepView(account: account, farm: farm)
                case .weight: WeightEntryView(account: account, farm: farm)
                case .transfer: TransferEntryView(account: account, farm: farm)
                case .removal: RemovalEntryView(account: account, farm: farm)
                case .feed: EmptyView()
                }
            }
        }
        .onAppear {
            presentIntentEntryIfNeeded()
            presentCareReminderIfNeeded()
        }
        .onChange(of: session.pendingRecordEntry) { _, _ in
            presentIntentEntryIfNeeded()
        }
        .navigationDestination(item: $careReminderDestination) { destination in
            CareReminderCenterView(account: account, farm: farm, focusedReminderID: destination.id)
        }
        .onChange(of: session.pendingCareReminderID) { _, _ in
            presentCareReminderIfNeeded()
        }
    }

    private func presentIntentEntryIfNeeded() {
        guard let entry = session.pendingRecordEntry, entry != .feed else { return }
        session.pendingRecordEntry = nil
        presentedEntry = entry
    }

    private func presentCareReminderIfNeeded() {
        guard let reminderID = session.pendingCareReminderID else { return }
        session.pendingCareReminderID = nil
        careReminderDestination = PendingCareReminderDestination(id: reminderID)
    }
}

private struct PendingCareReminderDestination: Identifiable, Hashable {
    let id: UUID
}

struct WeightEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepCandidates: [SheepEarTagSearchCandidate] = []
    @State private var sheepID: UUID?
    @State private var kilograms = ""
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("称重羊只") {
                SheepEarTagSingleSearchField(
                    candidates: sheepCandidates,
                    selection: $sheepID,
                    emptySelectionText: "尚未确认称重羊只"
                )
            }
            TextField("体重（千克）", text: $kilograms).keyboardType(.decimalPad)
            DatePicker("称重时间", selection: $occurredAt)
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("称重")
        .toolbar { EntrySaveToolbar(action: save) }
        .task(id: farm.id) { await loadSheepCandidates() }
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["称重"])
    }

    private func save() {
        guard let sheepID else { errorMessage = "请先搜索并确认称重羊只。"; return }
        do {
            try commandService.execute(.recordWeight(sheepID: sheepID, kilogramsText: kilograms, occurredAt: occurredAt, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func loadSheepCandidates() async {
        do {
            sheepCandidates = try await SheepEarTagCandidateSnapshotActor(container: modelContext.container)
                .load(farmID: farm.id, scope: .active)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "读取称重羊只失败：\(error.localizedDescription)"
        }
    }
}

struct WeaningEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepCandidates: [SheepEarTagSearchCandidate] = []
    @State private var penOptions: [WeaningPenOption] = []
    @State private var gainSamples: [WeaningGainSample] = []
    @State private var sheepID: UUID?
    @State private var targetPenID: UUID?
    @State private var weanWeight = ""
    @State private var occurredAt = Date.now
    @State private var birthAt = Date.now
    @State private var includesBirthDate = false
    @State private var note = ""
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, initialSheepID: UUID? = nil) {
        self.account = account
        self.farm = farm
        _sheepID = State(initialValue: initialSheepID)
    }

    private var selectedSheep: SheepEarTagSearchCandidate? { sheepCandidates.first { $0.id == sheepID } }
    private var effectiveBirthAt: Date? { selectedSheep?.birthAt ?? (includesBirthDate ? birthAt : nil) }
    private var parsedWeanWeight: Double? {
        Decimal.stable(weanWeight.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { NSDecimalNumber(decimal: $0).doubleValue }
    }
    private var gainBaseline: WeaningGainSample? {
        guard let sheepID else { return nil }
        return WeaningGainSemantics.earliestBaseline(
            sheepID: sheepID,
            birthAt: effectiveBirthAt,
            weaningAt: occurredAt,
            samples: gainSamples
        )
    }
    private var gainResult: WeaningGainResult? {
        guard let sheepID, let parsedWeanWeight else { return nil }
        return WeaningGainSemantics.calculate(
            sheepID: sheepID,
            birthAt: effectiveBirthAt,
            weaningAt: occurredAt,
            weaningWeight: parsedWeanWeight,
            samples: gainSamples
        )
    }
    private var weaningDateRange: ClosedRange<Date> {
        let upper = Date.now
        let lower = selectedSheep?.birthAt.map { min($0, upper) } ?? Date.distantPast
        return lower...upper
    }

    var body: some View {
        Form {
            Section("断奶羊只") {
                SheepEarTagSingleSearchField(
                    candidates: sheepCandidates,
                    selection: $sheepID,
                    emptySelectionText: "尚未确认断奶羊只"
                )
            }
            Section("断奶信息") {
                TextField("断奶重（千克）", text: $weanWeight).keyboardType(.decimalPad)
            }
            Section("断奶后调舍") {
                Picker("转入圈舍", selection: $targetPenID) {
                    Text("请选择目标圈舍").tag(UUID?.none)
                    ForEach(penOptions) { pen in
                        Text(pen.name).tag(UUID?.some(pen.id))
                    }
                }
            }
            Section("时间") {
                DatePicker("断奶时间", selection: $occurredAt, in: weaningDateRange)
                if let profileBirthAt = selectedSheep?.birthAt {
                    LabeledContent("出生日期", value: profileBirthAt.formatted(date: .abbreviated, time: .omitted))
                } else {
                    Toggle("补充出生日期", isOn: $includesBirthDate)
                    if includesBirthDate {
                        DatePicker("出生日期", selection: $birthAt, in: ...occurredAt, displayedComponents: .date)
                    }
                }
            }
            Section {
                if let baseline = gainBaseline {
                    LabeledContent("起算体重", value: "\(weightText(baseline.kilograms)) 千克")
                    LabeledContent("起算日期", value: baseline.occurredAt.formatted(date: .abbreviated, time: .omitted))
                    if let gainResult {
                        LabeledContent("计算间隔", value: "\(gainResult.intervalDays) 天")
                        LabeledContent("断奶日增重", value: "\(gainText(gainResult.gramsPerDay)) 克/天")
                    } else {
                        Text(calculationUnavailableMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(calculationUnavailableMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("自动日增重")
            } footer: {
                Text("以出生后、断奶前最早一条实际称重为起点；没有有效称重时不计算，也不会用初生重字段代替。")
            }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("断奶记录")
        .toolbar { EntrySaveToolbar(action: save) }
        .task(id: farm.id) { await loadReferenceData() }
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["断奶"])
        .onChange(of: sheepID) { _, _ in
            targetPenID = nil
            includesBirthDate = false
            birthAt = min(occurredAt, Date.now)
            if let profileBirthAt = selectedSheep?.birthAt, occurredAt < profileBirthAt {
                occurredAt = min(profileBirthAt, Date.now)
            }
        }
        .onChange(of: occurredAt) { _, newValue in
            if birthAt > newValue { birthAt = newValue }
        }
    }

    private func save() {
        guard let sheepID else { errorMessage = "请先搜索并确认断奶羊只。"; return }
        guard let targetPenID else { errorMessage = "请选择断奶后调入的圈舍。"; return }
        do {
            try commandService.executeBatch(
                WeaningWorkflow.commands(
                    sheepID: sheepID,
                    weanWeightText: weanWeight,
                    occurredAt: occurredAt,
                    birthAt: effectiveBirthAt,
                    toPenID: targetPenID,
                    note: note
                ),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private var calculationUnavailableMessage: String {
        guard sheepID != nil else { return "确认断奶羊只后，将查找其最早的有效称重。" }
        guard parsedWeanWeight.map({ $0 > 0 }) == true else { return "填写断奶重后才能计算日增重。" }
        guard let gainBaseline else { return "没有出生后且早于断奶时间的实际称重，暂不计算日增重。" }
        let days = FarmAnalyticsDate.days(from: gainBaseline.occurredAt, to: occurredAt)
        guard days > 0 else { return "起算称重与断奶在同一天，无法按日计算。" }
        return "断奶重未高于起算体重，该条记录不计入日增重。"
    }

    private func weightText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    private func gainText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    @MainActor
    private func loadReferenceData() async {
        do {
            // Copy the immutable, Sendable inputs while still on the main
            // actor. Referencing the SwiftData context or model from an
            // `async let` initializer would send those non-Sendable values
            // across the actor boundary under Swift 6 strict concurrency.
            let container = modelContext.container
            let farmID = farm.id
            async let candidateLoad = SheepEarTagCandidateSnapshotActor(container: container)
                .load(farmID: farmID, scope: .active)
            async let referenceLoad = WeaningEntryReferenceSnapshotActor(container: container)
                .load(farmID: farmID)
            let (candidates, reference) = try await (candidateLoad, referenceLoad)
            try Task.checkCancellation()
            sheepCandidates = candidates
            penOptions = reference.pens
            gainSamples = reference.gainSamples
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "读取断奶羊只失败：\(error.localizedDescription)"
        }
    }
}

struct BreedingProgramListView: View {
    @Query(sort: \BreedingProgramRecord.createdAt, order: .reverse) private var programs: [BreedingProgramRecord]
    @Query(sort: \BreedingProgramStepRecord.sortOrder) private var steps: [BreedingProgramStepRecord]
    let account: AccountProfile
    let farm: FarmRecord

    private var farmPrograms: [BreedingProgramRecord] {
        programs.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    var body: some View {
        List {
            if farmPrograms.isEmpty {
                ContentUnavailableView("暂无配种方案", systemImage: "list.number", description: Text("将同期发情、放栓、打针和配种等步骤保存为可复用方案。"))
            } else {
                ForEach(farmPrograms, id: \.id) { program in
                    NavigationLink { BreedingProgramDetailView(program: program, steps: steps.filter { $0.farmID == farm.id && $0.programID == program.id && $0.deletedAt == nil }) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(program.name)
                            Text("\(steps.filter { $0.farmID == farm.id && $0.programID == program.id && $0.deletedAt == nil }.count) 个步骤")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("配种方案")
        .toolbar {
            NavigationLink { BreedingProgramEntryView(account: account, farm: farm) } label: { Image(systemName: "plus") }
        }
        .farmExcelImport(account: account, farm: farm, sheets: ["配种方案"])
    }
}

struct BreedingProgramDetailView: View {
    let program: BreedingProgramRecord
    let steps: [BreedingProgramStepRecord]

    var body: some View {
        List {
            Section("方案") {
                LabeledContent("名称", value: program.name)
                LabeledContent("创建日期", value: program.createdAt.formatted(date: .abbreviated, time: .omitted))
            }
            Section("步骤") {
                ForEach(steps.sorted { $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder }, id: \.id) { step in
                    LabeledContent("第 \(step.dayOffset) 天", value: step.action)
                }
            }
        }
        .navigationTitle("方案详情")
    }
}

struct BreedingProgramEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var name = ""
    @State private var createdAt = Date.now
    @State private var steps = [BreedingProgramStepDraft(dayOffset: 0, action: "配种")]
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("方案") {
                TextField("方案名称", text: $name)
                DatePicker("创建日期", selection: $createdAt, displayedComponents: .date)
            }
            Section("步骤") {
                ForEach($steps) { $step in
                    Stepper("第 \(step.dayOffset) 天", value: $step.dayOffset, in: 0...365)
                    TextField("操作", text: $step.action)
                }
                .onDelete { steps.remove(atOffsets: $0) }
                Button { steps.append(BreedingProgramStepDraft(dayOffset: (steps.last?.dayOffset ?? 0) + 1, action: "")) } label: {
                    Label("添加步骤", systemImage: "plus")
                }
            }
        }
        .navigationTitle("新建配种方案")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["配种方案"])
    }

    private func save() {
        do {
            try commandService.execute(
                .createBreedingProgram(name: name, createdAt: createdAt, steps: steps),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct TransferEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepCandidates: [SheepEarTagSearchCandidate] = []
    @State private var sheepID: UUID?
    @State private var penID: UUID?
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, initialSheepID: UUID? = nil) {
        self.account = account
        self.farm = farm
        _sheepID = State(initialValue: initialSheepID)
    }

    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    var body: some View {
        Form {
            Section("转群羊只") {
                SheepEarTagSingleSearchField(
                    candidates: sheepCandidates,
                    selection: $sheepID,
                    emptySelectionText: "尚未确认转群羊只"
                )
            }
            Section("目标圈舍") {
                Picker("转入", selection: $penID) {
                    Text("离开圈舍").tag(UUID?.none)
                    ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            DatePicker("转群时间", selection: $occurredAt)
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("转群")
        .toolbar { EntrySaveToolbar(action: save) }
        .task(id: farm.id) { await loadSheepCandidates() }
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["转群"])
    }

    private func save() {
        guard let sheepID else { errorMessage = "请先搜索并确认转群羊只。"; return }
        do {
            try commandService.execute(.transferSheep(sheepID: sheepID, toPenID: penID, occurredAt: occurredAt, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func loadSheepCandidates() async {
        do {
            sheepCandidates = try await SheepEarTagCandidateSnapshotActor(container: modelContext.container)
                .load(farmID: farm.id, scope: .active)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "读取转群羊只失败：\(error.localizedDescription)"
        }
    }
}

struct NoteEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepCandidates: [SheepEarTagSearchCandidate] = []
    @State private var sheepID: UUID?
    @State private var penID: UUID?
    @State private var text = ""
    @State private var occurredAt = Date.now
    @State private var errorMessage: String?
    @State private var sheepIDsByPenAtOccurrence: [UUID: Set<UUID>] = [:]

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _pens = Query(
            filter: #Predicate<PenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \PenRecord.name
        )
    }

    private var eligiblePenIDs: Set<UUID> { Set(sheepIDsByPenAtOccurrence.keys) }
    private var farmPens: [PenRecord] {
        pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && eligiblePenIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section("羊只（可选）") {
                SheepEarTagSingleSearchField(
                    candidates: sheepCandidates,
                    selection: $sheepID,
                    emptySelectionText: "未关联羊只"
                )
            }
            Picker("圈舍", selection: $penID) {
                Text("不指定").tag(UUID?.none)
                ForEach(farmPens, id: \.id) { pen in
                    Text("\(pen.name)（\(sheepIDsByPenAtOccurrence[pen.id, default: []].count)只）")
                        .tag(UUID?.some(pen.id))
                }
            }
            DatePicker("发生时间", selection: $occurredAt)
            TextField("备注内容", text: $text, axis: .vertical).lineLimit(4...8)
        }
        .navigationTitle("备注")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["备注"])
        .task(id: farm.id) { await loadSheepCandidates() }
        .task(id: occurredAt) { await refreshPenOccupancy() }
        .onChange(of: eligiblePenIDs) { _, validIDs in
            if let penID, !validIDs.contains(penID) { self.penID = nil }
        }
    }

    @MainActor
    private func refreshPenOccupancy() async {
        do {
            let resolved = try await FarmPenOccupancyReadActor(container: modelContext.container)
                .sheepIDsByPen(farmID: farm.id, at: occurredAt)
            try Task.checkCancellation()
            sheepIDsByPenAtOccurrence = resolved
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "读取该时间的圈舍存栏失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try commandService.execute(.addNote(sheepID: sheepID, penID: penID, text: text, occurredAt: occurredAt), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func loadSheepCandidates() async {
        do {
            sheepCandidates = try await SheepEarTagCandidateSnapshotActor(container: modelContext.container)
                .load(farmID: farm.id, scope: .allNonDeleted)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "读取备注关联羊只失败：\(error.localizedDescription)"
        }
    }
}

struct EntrySaveToolbar: ToolbarContent {
    let action: () -> Void
    let isSaving: Bool
    @State private var isPerformingAction = false

    init(action: @escaping () -> Void, isSaving: Bool = false) {
        self.action = action
        self.isSaving = isSaving
    }

    private var showsProgress: Bool {
        isSaving || isPerformingAction
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { DismissButton() }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: performAction) {
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Text("保存")
                }
            }
            .disabled(showsProgress)
            .accessibilityLabel(showsProgress ? "正在保存" : "保存")
        }
    }

    private func performAction() {
        guard !showsProgress else { return }
        isPerformingAction = true
        Task { @MainActor in
            await Task.yield()
            action()
            isPerformingAction = false
        }
    }
}

struct DismissButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("取消") { dismiss() } }
}

extension View {
    func recordErrorAlert(_ errorMessage: Binding<String?>) -> some View {
        alert("无法保存", isPresented: Binding(get: { errorMessage.wrappedValue != nil }, set: { if !$0 { errorMessage.wrappedValue = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(errorMessage.wrappedValue ?? "") }
    }
}
