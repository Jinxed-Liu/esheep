import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RemovalEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()

    @State private var sheepID: UUID?
    @State private var kind = RemovalKind.sold
    @State private var reason = ""
    @State private var amount = ""
    @State private var occurredAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    private var activeSheep: [SheepRecord] {
        sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .active }
    }

    var body: some View {
        Form {
            SheepPicker(sheep: activeSheep, selection: $sheepID)
            Picker("类型", selection: $kind) {
                ForEach(RemovalKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("原因", text: $reason)
            if kind == .sold || kind == .culled {
                TextField("金额（可选）", text: $amount).keyboardType(.decimalPad)
            }
            DatePicker("发生时间", selection: $occurredAt)
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("离场记录")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        guard let sheepID else { errorMessage = "请选择羊只。"; return }
        do {
            try commandService.execute(.removeSheep(sheepID: sheepID, kind: kind, reason: reason, amountText: amount, occurredAt: occurredAt, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ProductionBatchListView: View {
    @Query(sort: \ProductionBatchRecord.startedAt, order: .reverse) private var batches: [ProductionBatchRecord]

    let account: AccountProfile
    let farm: FarmRecord
    @State private var isCreating = false

    private var farmBatches: [ProductionBatchRecord] {
        batches.filter { $0.farmID == farm.id && $0.deletedAt == nil }
    }

    var body: some View {
        List {
            ForEach(farmBatches, id: \.id) { batch in
                NavigationLink { ProductionBatchDetailView(account: account, farm: farm, batch: batch) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(batch.name).font(.headline)
                        Text("\(batch.purpose) · \(batch.status == .active ? "进行中" : "已结束")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(batch.startedAt, format: .dateTime.year().month().day())
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .overlay {
            if farmBatches.isEmpty {
                ContentUnavailableView("还没有生产批次", systemImage: "square.3.layers.3d", description: Text("批次用于追踪育肥、实验或其他生产阶段。"))
            }
        }
        .navigationTitle("生产批次")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $isCreating) {
            NavigationStack { CreateProductionBatchView(account: account, farm: farm) }
        }
    }
}

private struct CreateProductionBatchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()

    @State private var name = ""
    @State private var purpose = "育肥"
    @State private var startedAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("批次名称", text: $name)
            TextField("生产目的", text: $purpose)
            DatePicker("起始时间", selection: $startedAt)
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("新建生产批次")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            try commandService.execute(.createBatch(name: name, purpose: purpose, startedAt: startedAt, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ProductionBatchDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BatchMembershipRecord.joinedAt, order: .reverse) private var memberships: [BatchMembershipRecord]
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let batch: ProductionBatchRecord
    private let commandService = FarmCommandService()
    @State private var sheepID: UUID?
    @State private var joinedAt = Date.now
    @State private var errorMessage: String?

    private var activeMemberships: [BatchMembershipRecord] {
        memberships.filter { $0.farmID == farm.id && $0.batchID == batch.id && $0.deletedAt == nil && $0.leftAt == nil }
    }
    private var memberIDs: Set<UUID> { Set(activeMemberships.map(\.sheepID)) }
    private var candidateSheep: [SheepRecord] {
        sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .active && !memberIDs.contains($0.id) }
    }
    private var sheepNames: [UUID: String] { Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0.earTag) }) }

    var body: some View {
        List {
            Section("当前成员") {
                ForEach(activeMemberships, id: \.id) { membership in
                    HStack {
                        Text(sheepNames[membership.sheepID] ?? "已删除羊只")
                        Spacer()
                        Button("离开批次", role: .destructive) { leave(membership) }
                    }
                }
                if activeMemberships.isEmpty { Text("尚未加入羊只").foregroundStyle(.secondary) }
            }
            if batch.status == .active {
                Section("加入批次") {
                    Picker("羊只", selection: $sheepID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(candidateSheep, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) }
                    }
                    DatePicker("加入时间", selection: $joinedAt)
                    Button("加入批次", action: add).disabled(sheepID == nil)
                }
            }
        }
        .navigationTitle(batch.name)
        .recordErrorAlert($errorMessage)
    }

    private func add() {
        guard let sheepID else { return }
        do {
            try commandService.execute(.assignSheepToBatch(batchID: batch.id, sheepID: sheepID, joinedAt: joinedAt), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            self.sheepID = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func leave(_ membership: BatchMembershipRecord) {
        do {
            try commandService.execute(.leaveBatch(batchID: batch.id, sheepID: membership.sheepID, leftAt: .now, reason: "手动离开"), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
        } catch { errorMessage = error.localizedDescription }
    }
}

struct LegacyMigrationCheckView: View {
    @State private var isImporting = false
    @State private var report: LegacyMigrationReport?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("此检查只读取旧版导出包并生成迁移前报告，不会修改旧版数据，也不会写入当前牧场。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("选择旧版 JSON 迁移包") { isImporting = true }
            }
            if let report {
                Section("迁移检查") {
                    LabeledContent("Schema", value: report.schemaVersion ?? "未标注")
                    LabeledContent("羊只", value: "\(report.counts.sheep)")
                    LabeledContent("圈舍", value: "\(report.counts.pens)")
                    LabeledContent("转群／离场", value: "\(report.counts.transfers)／\(report.counts.removals)")
                    LabeledContent("投喂／健康", value: "\(report.counts.feedRecords)／\(report.counts.healthRecords)")
                    LabeledContent("生产批次／成员", value: "\(report.counts.batches)／\(report.counts.batchMemberships)")
                }
                if !report.fatalIssues.isEmpty {
                    Section("阻断问题") { ForEach(report.fatalIssues, id: \.self) { Text($0).foregroundStyle(.red) } }
                }
                if !report.warnings.isEmpty {
                    Section("需要确认") { ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(.orange) } }
                }
            }
        }
        .navigationTitle("旧版迁移检查")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                defer { url.stopAccessingSecurityScopedResource() }
                report = try LegacyMigrationInspector.inspect(Data(contentsOf: url))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("无法读取迁移包", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

struct InventoryManagementView: View {
    @Query(sort: \InventoryLotRecord.createdAt, order: .reverse) private var lots: [InventoryLotRecord]
    @Query private var transactions: [InventoryTransactionRecord]

    let account: AccountProfile
    let farm: FarmRecord
    @State private var isReceiving = false

    private var farmLots: [InventoryLotRecord] {
        lots.filter { $0.farmID == farm.id && $0.isActive }
    }

    var body: some View {
        List {
            ForEach(farmLots, id: \.id) { lot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(lot.catalogName).font(.headline)
                    Text("余量：\(balance(for: lot).stableText) · \(lot.kindRawValue == HealthRecordKind.vaccination.rawValue ? "疫苗" : "药品")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let expiresAt = lot.expiresAt {
                        Text("有效期至 \(expiresAt, format: .dateTime.year().month().day())")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .overlay {
            if farmLots.isEmpty {
                ContentUnavailableView("还没有库存批次", systemImage: "shippingbox", description: Text("入库后，治疗和疫苗记录可从对应批次扣减。"))
            }
        }
        .navigationTitle("药品与疫苗库存")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { isReceiving = true } label: { Image(systemName: "plus") } }
        }
        .sheet(isPresented: $isReceiving) {
            NavigationStack { ReceiveInventoryView(account: account, farm: farm) }
        }
    }

    private func balance(for lot: InventoryLotRecord) -> Decimal {
        transactions
            .filter { $0.farmID == farm.id && $0.inventoryLotID == lot.id && $0.deletedAt == nil }
            .reduce(Decimal.zero) { result, transaction in
                switch transaction.kind {
                case .receipt, .adjustment: result + transaction.quantity
                case .consumption: result - transaction.quantity
                }
            }
    }
}

private struct ReceiveInventoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()

    @State private var catalogName = ""
    @State private var kind = HealthRecordKind.treatment
    @State private var quantity = ""
    @State private var expiresAt = Date.now
    @State private var hasExpiry = false
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("药品或疫苗名称", text: $catalogName)
            Picker("类型", selection: $kind) { ForEach(HealthRecordKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            TextField("数量", text: $quantity).keyboardType(.decimalPad)
            Toggle("记录有效期", isOn: $hasExpiry)
            if hasExpiry { DatePicker("有效期", selection: $expiresAt, displayedComponents: .date) }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
        }
        .navigationTitle("入库")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            try commandService.execute(.receiveInventory(catalogName: catalogName, kind: kind, expiresAt: hasExpiry ? expiresAt : nil, quantityText: quantity, occurredAt: .now, note: note), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SemenLibraryView: View {
    @Query(sort: \SemenRecord.code) private var records: [SemenRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var isAdding = false

    private var farmRecords: [SemenRecord] { records.filter { $0.farmID == farm.id && $0.deletedAt == nil } }

    var body: some View {
        List {
            ForEach(farmRecords, id: \.id) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.code).font(.headline)
                    Text("\(record.breed) · 库存 \(record.quantityText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !record.source.isEmpty || !record.batchNumber.isEmpty {
                        Text([record.source, record.batchNumber].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .overlay {
            if farmRecords.isEmpty {
                ContentUnavailableView("还没有冻精记录", systemImage: "snowflake", description: Text("冻精编号会用于配种记录和父本追溯。"))
            }
        }
        .navigationTitle("冻精管理")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { isAdding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $isAdding) {
            NavigationStack { AddSemenView(account: account, farm: farm) }
        }
    }
}

private struct AddSemenView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()

    @State private var code = ""
    @State private var breed = ""
    @State private var source = ""
    @State private var batchNumber = ""
    @State private var quantity = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("冻精编号", text: $code)
            TextField("品种", text: $breed)
            TextField("来源（可选）", text: $source)
            TextField("批号（可选）", text: $batchNumber)
            TextField("库存数量", text: $quantity).keyboardType(.decimalPad)
        }
        .navigationTitle("新增冻精")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .recordErrorAlert($errorMessage)
    }

    private func save() {
        do {
            try commandService.execute(.addSemen(code: code, breed: breed, source: source, batchNumber: batchNumber, quantityText: quantity), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
