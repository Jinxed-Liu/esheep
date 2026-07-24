import SwiftData
import SwiftUI

struct SheepRecordHistoryScreen: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let sheepID: UUID

    @State private var snapshot: SheepRecordHistorySnapshot?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var editingWeight: SheepHistoryWeight?
    @State private var editingTransfer: SheepHistoryTransfer?
    @State private var editingRemoval: SheepHistoryRemoval?
    @State private var pendingDelete: HistoryDeletionTarget?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if isLoading, snapshot == nil {
                    ProgressView("正在读取生产记录")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                }
                if let snapshot {
                    weightCard(snapshot.weights)
                    transferCard(snapshot.transfers, snapshot: snapshot)
                    removalCard(snapshot.removals)
                    if !snapshot.tombstones.isEmpty { tombstoneCard(snapshot.tombstones) }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("生产记录管理")
        .task(id: sheepID) { await reload() }
        .sheet(item: $editingWeight, onDismiss: { Task { await reload() } }) { record in
            NavigationStack { SnapshotCorrectWeightView(account: account, farm: farm, record: record) }
        }
        .sheet(item: $editingTransfer, onDismiss: { Task { await reload() } }) { record in
            NavigationStack {
                SnapshotCorrectTransferView(
                    account: account,
                    farm: farm,
                    record: record,
                    pens: snapshot?.pens ?? []
                )
            }
        }
        .sheet(item: $editingRemoval, onDismiss: { Task { await reload() } }) { record in
            NavigationStack { SnapshotCorrectRemovalView(account: account, farm: farm, record: record) }
        }
        .confirmationDialog(
            "确认撤销记录",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("撤销并保留审计", role: .destructive) { deletePending() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("撤销后会重新计算羊只历史状态，可在本页恢复。")
        }
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView("正在更新历史记录")
                    .padding()
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .recordErrorAlert($errorMessage)
    }

    private func weightCard(_ records: [SheepHistoryWeight]) -> some View {
        historyCard(title: "称重") {
            if records.isEmpty {
                emptyRow("暂无称重记录")
            } else {
                ForEach(records) { record in
                    historyRow(title: "\(record.kilogramsText) 千克", date: record.occurredAt, note: record.note) {
                        Button("修正") { editingWeight = record }
                        Button("撤销", role: .destructive) {
                            pendingDelete = .init(type: .weight, id: record.id, title: "称重")
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func transferCard(_ records: [SheepHistoryTransfer], snapshot: SheepRecordHistorySnapshot) -> some View {
        historyCard(title: "转群") {
            if records.isEmpty {
                emptyRow("暂无转群记录")
            } else {
                ForEach(records) { record in
                    historyRow(
                        title: snapshot.penName(record.fromPenID) + " → " + snapshot.penName(record.toPenID),
                        date: record.occurredAt,
                        note: record.note
                    ) {
                        Button("修正") { editingTransfer = record }
                        Button("撤销", role: .destructive) {
                            pendingDelete = .init(type: .transfer, id: record.id, title: "转群")
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func removalCard(_ records: [SheepHistoryRemoval]) -> some View {
        historyCard(title: "离场") {
            if records.isEmpty {
                emptyRow("暂无离场记录")
            } else {
                ForEach(records) { record in
                    historyRow(
                        title: removalTitle(record),
                        date: record.occurredAt,
                        note: record.note
                    ) {
                        Button("修正") { editingRemoval = record }
                        Button("撤销并恢复在场") {
                            execute(.restoreSheep(removalID: record.id))
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private func removalTitle(_ record: SheepHistoryRemoval) -> String {
        let base = record.kind.displayName + " · " + record.reason
        guard record.removalBatchID != nil, record.kind == .sold,
              let total = record.batchTotalAmountText else { return base }
        return base + " · 同批总额 " + total
    }

    private func tombstoneCard(_ records: [SheepHistoryTombstone]) -> some View {
        historyCard(title: "可恢复记录") {
            ForEach(records) { record in
                Button {
                    execute(.restoreTombstonedEntity(tombstoneID: record.id))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("恢复\(displayName(record.entityType))")
                        Text(record.reason).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func historyCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            content().padding(.horizontal, 16)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
    }

    private func historyRow<MenuContent: View>(
        title: String,
        date: Date,
        note: String,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .font(.footnote).foregroundStyle(.secondary)
                if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            Menu(content: menu) { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("记录操作")
        }
        .padding(.vertical, 12)
    }

    private func reload() async {
        isLoading = true
        let reader = SheepRecordHistoryActor(container: modelContext.container)
        do {
            snapshot = try await reader.load(farmID: farm.id, sheepID: sheepID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deletePending() {
        guard let target = pendingDelete else { return }
        pendingDelete = nil
        execute(.tombstoneEntity(entityType: target.type, entityID: target.id, reason: "用户撤销\(target.title)记录"))
    }

    private func execute(_ command: FarmCommand) {
        guard !isWorking else { return }
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
        isWorking = true
        do {
            try FarmCommandService().execute(command, in: farmContext, context: modelContext)
            Task {
                await reload()
                isWorking = false
            }
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }

    private func displayName(_ raw: String) -> String {
        switch CloudEntityType(rawValue: raw) {
        case .weight: "称重记录"
        case .transfer: "转群记录"
        case .removal: "离场记录"
        case .photoAsset: "照片"
        default: "记录"
        }
    }
}

private struct HistoryDeletionTarget {
    let type: CloudEntityType
    let id: UUID
    let title: String
}

private struct SnapshotCorrectWeightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let record: SheepHistoryWeight
    @State private var kilograms: String
    @State private var occurredAt: Date
    @State private var note: String
    @State private var reason = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, record: SheepHistoryWeight) {
        self.account = account; self.farm = farm; self.record = record
        _kilograms = State(initialValue: record.kilogramsText)
        _occurredAt = State(initialValue: record.occurredAt)
        _note = State(initialValue: record.note)
    }

    var body: some View {
        Form {
            Section("替代记录") {
                TextField("体重（千克）", text: $kilograms).keyboardType(.decimalPad)
                DatePicker("发生时间", selection: $occurredAt)
                TextField("备注", text: $note)
            }
            Section("修正原因") { TextField("必填", text: $reason, axis: .vertical) }
        }
        .navigationTitle("修正称重")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(isSaving) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        let command = FarmCommand.correctWeight(originalID: record.id, kilogramsText: kilograms, occurredAt: occurredAt, note: note, reason: reason)
        execute(command)
    }

    private func execute(_ command: FarmCommand) {
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
        isSaving = true
        do { try FarmCommandService().execute(command, in: farmContext, context: modelContext); dismiss() }
        catch { errorMessage = error.localizedDescription; isSaving = false }
    }
}

private struct SnapshotCorrectTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let record: SheepHistoryTransfer
    let pens: [SheepHistoryPen]
    @State private var toPenID: UUID?
    @State private var occurredAt: Date
    @State private var note: String
    @State private var reason = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, record: SheepHistoryTransfer, pens: [SheepHistoryPen]) {
        self.account = account; self.farm = farm; self.record = record; self.pens = pens
        _toPenID = State(initialValue: record.toPenID)
        _occurredAt = State(initialValue: record.occurredAt)
        _note = State(initialValue: record.note)
    }

    var body: some View {
        Form {
            Section("替代记录") {
                Picker("目标圈舍", selection: $toPenID) {
                    Text("未分圈").tag(UUID?.none)
                    ForEach(pens.filter(\.isActive)) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                DatePicker("发生时间", selection: $occurredAt)
                TextField("备注", text: $note)
            }
            Section("修正原因") { TextField("必填", text: $reason, axis: .vertical) }
        }
        .navigationTitle("修正转群")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(isSaving) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        let command = FarmCommand.correctTransfer(originalID: record.id, toPenID: toPenID, occurredAt: occurredAt, note: note, reason: reason)
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
        isSaving = true
        do { try FarmCommandService().execute(command, in: farmContext, context: modelContext); dismiss() }
        catch { errorMessage = error.localizedDescription; isSaving = false }
    }
}

private struct SnapshotCorrectRemovalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    let record: SheepHistoryRemoval
    @State private var kind: RemovalKind
    @State private var reason: String
    @State private var amount: String
    @State private var occurredAt: Date
    @State private var note: String
    @State private var correctionReason = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, record: SheepHistoryRemoval) {
        self.account = account; self.farm = farm; self.record = record
        _kind = State(initialValue: record.kind)
        _reason = State(initialValue: record.reason)
        _amount = State(initialValue: record.amountText ?? "")
        _occurredAt = State(initialValue: record.occurredAt)
        _note = State(initialValue: record.note)
    }

    var body: some View {
        Form {
            Section("替代记录") {
                Picker("类型", selection: $kind) { ForEach(RemovalKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                TextField("离场原因", text: $reason)
                if record.removalBatchID != nil {
                    if record.kind == .sold {
                        LabeledContent("同批总售卖金额", value: record.batchTotalAmountText ?? "未填写")
                    }
                    Text("同批离场只有一笔总额，不能在单羊修正中改写。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("售卖金额（可选）", text: $amount).keyboardType(.decimalPad)
                }
                DatePicker("发生时间", selection: $occurredAt)
                TextField("备注", text: $note)
            }
            Section("修正原因") { TextField("必填", text: $correctionReason, axis: .vertical) }
        }
        .navigationTitle("修正离场")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(isSaving) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        let command = FarmCommand.correctRemoval(
            originalID: record.id,
            kind: kind,
            reason: reason,
            amountText: record.removalBatchID == nil ? amount : nil,
            occurredAt: occurredAt,
            note: note,
            correctionReason: correctionReason
        )
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
        isSaving = true
        do { try FarmCommandService().execute(command, in: farmContext, context: modelContext); dismiss() }
        catch { errorMessage = error.localizedDescription; isSaving = false }
    }
}
