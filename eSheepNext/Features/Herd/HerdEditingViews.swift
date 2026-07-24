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
                Button(pen.isActive ? "停用圈舍" : "重新启用圈舍", role: pen.isActive ? .destructive : nil) {
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
    let account: AccountProfile
    let farm: FarmRecord
    let sheep: SheepRecord
    private let commandService = FarmCommandService()
    @State private var earTag: String
    @State private var breed: String
    @State private var sex: SheepSex
    @State private var hasBirthDate: Bool
    @State private var birthAt: Date
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
                    ForEach(SheepSex.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Section("出生信息") {
                Toggle("记录出生日期", isOn: $hasBirthDate)
                if hasBirthDate { DatePicker("出生日期", selection: $birthAt, in: ...Date.now, displayedComponents: .date) }
            }
            Section("备注") { TextField("可选", text: $note, axis: .vertical).lineLimit(2...5) }
        }
        .navigationTitle("编辑羊只档案")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            try commandService.execute(
                .updateSheepProfile(sheepID: sheep.id, earTag: earTag, breed: breed, sex: sex, birthAt: hasBirthDate ? birthAt : nil, note: note),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch { errorMessage = error.localizedDescription }
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
                Text(title)
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
    var body: some View { Form { Section("替代记录") { Picker("类型", selection: $kind) { ForEach(RemovalKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }; TextField("离场原因", text: $reason); if record.removalBatchID != nil { if record.kind == .sold { LabeledContent("同批总售卖金额", value: record.batchTotalAmountText ?? "未填写") }; Text("同批离场只有一笔总额，不能在单羊修正中改写。").font(.footnote).foregroundStyle(.secondary) } else { TextField("售卖金额（可选）", text: $amount).keyboardType(.decimalPad) }; DatePicker("发生时间", selection: $occurredAt); TextField("备注", text: $note) }; Section("修正原因") { TextField("必填", text: $correctionReason, axis: .vertical) } }.navigationTitle("修正离场").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) } }.recordErrorAlert($errorMessage) }
    private func save() { do { try FarmCommandService().execute(.correctRemoval(originalID: record.id, kind: kind, reason: reason, amountText: record.removalBatchID == nil ? amount : nil, occurredAt: occurredAt, note: note, correctionReason: correctionReason), in: .init(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription } }
}
