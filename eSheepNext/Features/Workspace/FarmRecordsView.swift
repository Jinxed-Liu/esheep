import SwiftData
import SwiftUI

struct FarmRecordsView: View {
    @Environment(AppSession.self) private var session
    let account: AccountProfile
    let farm: FarmRecord
    @State private var presentedEntry: PendingRecordEntry?
    @State private var careReminderDestination: PendingCareReminderDestination?

    var body: some View {
        List {
            Section("事件") {
                NavigationLink {
                    FarmEventHistoryView(account: account, farm: farm)
                } label: {
                    Label("事件记录与导出", systemImage: "clock.arrow.circlepath")
                }
            }
            Section("业务录入") {
                NavigationLink {
                    HerdRecordCenterView(account: account, farm: farm)
                } label: {
                    Label("羊群与圈舍", systemImage: "list.bullet.rectangle")
                }
                NavigationLink {
                    CareManagementView(account: account, farm: farm)
                } label: {
                    Label("健康与繁殖", systemImage: "cross.case.fill")
                }
            }
            Section("补充") {
                NavigationLink { NoteEntryView(account: account, farm: farm) } label: { Label("备注", systemImage: "note.text") }
                NavigationLink { MigrationWorkspaceView() } label: { Label("从 eSheep+ 导入", systemImage: "square.and.arrow.down") }
            }
        }
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

private struct HerdRecordCenterView: View {
    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        List {
            Section("快捷录入") {
                NavigationLink { AddSheepView(account: account, farm: farm) } label: {
                    Label("新建羊只", systemImage: "plus.circle")
                }
                NavigationLink { WeightEntryView(account: account, farm: farm) } label: {
                    Label("称重", systemImage: "scalemass")
                }
                NavigationLink { WeaningEntryView(account: account, farm: farm) } label: {
                    Label("断奶", systemImage: "arrow.down.to.line.compact")
                }
                NavigationLink { TransferEntryView(account: account, farm: farm) } label: {
                    Label("转群", systemImage: "arrow.left.arrow.right")
                }
                NavigationLink { RemovalEntryView(account: account, farm: farm) } label: {
                    Label("出售、淘汰或死亡", systemImage: "person.crop.circle.badge.minus")
                }
            }
            Section("档案与管理") {
                NavigationLink { ProductionBatchListView(account: account, farm: farm) } label: {
                    Label("生产批次", systemImage: "square.3.layers.3d")
                }
                NavigationLink { HerdManagementView(account: account, farm: farm) } label: {
                    Label("羊只档案", systemImage: "list.bullet")
                }
                NavigationLink { PenManagementView(account: account, farm: farm) } label: {
                    Label("圈舍管理", systemImage: "building.2")
                }
            }
        }
        .navigationTitle("羊群与圈舍")
    }
}

struct WeightEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepID: UUID?
    @State private var kilograms = ""
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .active } }
    private var sheepCandidates: [SheepEarTagSearchCandidate] { farmSheep.map { .init(sheep: $0) } }

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
}

struct WeaningEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepID: UUID?
    @State private var damID: UUID?
    @State private var weanWeight = ""
    @State private var birthWeight = ""
    @State private var averageDailyGain = ""
    @State private var occurredAt = Date.now
    @State private var birthAt = Date.now
    @State private var includesBirthDate = false
    @State private var litterSize = 1
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .active } }
    private var ewes: [SheepRecord] { farmSheep.filter { $0.sex == .ewe } }
    private var sheepCandidates: [SheepEarTagSearchCandidate] { farmSheep.map { .init(sheep: $0) } }
    private var damCandidates: [SheepEarTagSearchCandidate] { ewes.map { .init(sheep: $0) } }

    var body: some View {
        Form {
            Section("断奶羊只") {
                SheepEarTagSingleSearchField(
                    candidates: sheepCandidates,
                    selection: $sheepID,
                    emptySelectionText: "尚未确认断奶羊只"
                )
            }
            Section("母本（可选）") {
                SheepEarTagSingleSearchField(
                    candidates: damCandidates,
                    selection: $damID,
                    prompt: "输入母本耳号搜索",
                    emptySelectionText: "未关联母本",
                    accessibilityName: "母本耳号"
                )
            }
            Section("断奶指标") {
                TextField("断奶重（千克）", text: $weanWeight).keyboardType(.decimalPad)
                TextField("出生重（可选，千克）", text: $birthWeight).keyboardType(.decimalPad)
                TextField("日增重（可选，千克/天）", text: $averageDailyGain).keyboardType(.decimalPad)
                Stepper("胎只数：\(litterSize)", value: $litterSize, in: 1...10)
            }
            Section("时间") {
                DatePicker("断奶时间", selection: $occurredAt)
                Toggle("补充出生日期", isOn: $includesBirthDate)
                if includesBirthDate { DatePicker("出生日期", selection: $birthAt, in: ...occurredAt, displayedComponents: .date) }
            }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("断奶记录")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["断奶"])
    }

    private func save() {
        guard let sheepID else { errorMessage = "请先搜索并确认断奶羊只。"; return }
        do {
            try commandService.execute(
                .recordWeaning(
                    sheepID: sheepID,
                    weanWeightText: weanWeight,
                    occurredAt: occurredAt,
                    birthAt: includesBirthDate ? birthAt : nil,
                    birthWeightText: birthWeight,
                    averageDailyGainText: averageDailyGain,
                    damID: damID,
                    litterSize: litterSize,
                    note: note
                ),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
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
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepID: UUID?
    @State private var penID: UUID?
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .active } }
    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var sheepCandidates: [SheepEarTagSearchCandidate] { farmSheep.map { .init(sheep: $0) } }

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
}

struct NoteEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepID: UUID?
    @State private var penID: UUID?
    @State private var text = ""
    @State private var occurredAt = Date.now
    @State private var errorMessage: String?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var sheepCandidates: [SheepEarTagSearchCandidate] { farmSheep.map { .init(sheep: $0) } }

    var body: some View {
        Form {
            Section("羊只（可选）") {
                SheepEarTagSingleSearchField(
                    candidates: sheepCandidates,
                    selection: $sheepID,
                    emptySelectionText: "未关联羊只"
                )
            }
            Picker("圈舍", selection: $penID) { Text("不指定").tag(UUID?.none); ForEach(pens.filter { $0.farmID == farm.id && $0.deletedAt == nil }, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
            DatePicker("发生时间", selection: $occurredAt)
            TextField("备注内容", text: $text, axis: .vertical).lineLimit(4...8)
        }
        .navigationTitle("备注")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["备注"])
    }

    private func save() {
        do {
            try commandService.execute(.addNote(sheepID: sheepID, penID: penID, text: text, occurredAt: occurredAt), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
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
