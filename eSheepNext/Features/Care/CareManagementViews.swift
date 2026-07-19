import SwiftData
import SwiftUI

private enum CareSheetDestination: Identifiable {
    case health
    case reproduction
    case lambing
    case catalog

    var id: String {
        switch self { case .health: "health"; case .reproduction: "reproduction"; case .lambing: "lambing"; case .catalog: "catalog" }
    }
}

private struct HealthCatalogEditorDestination: Identifiable {
    let id: UUID
}

struct CareManagementView: View {
    @Environment(AppSession.self) private var session
    @Environment(FarmNotificationService.self) private var notifications
    @Query(sort: \CareReminderRecord.dueAt) private var reminders: [CareReminderRecord]
    @Query(sort: \HealthRecord.occurredAt, order: .reverse) private var health: [HealthRecord]
    @Query(sort: \ReproductionRecord.occurredAt, order: .reverse) private var reproduction: [ReproductionRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var sheet: CareSheetDestination?

    private var pending: [CareReminderRecord] { reminders.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .pending } }
    private var reminderRevisionSignature: [String] { reminders.filter { $0.farmID == farm.id }.map { "\($0.id.uuidString):\($0.revision):\($0.dueAt.timeIntervalSinceReferenceDate):\($0.deletedAt?.timeIntervalSinceReferenceDate ?? 0)" }.sorted() }

    var body: some View {
        List {
            if !pending.isEmpty {
                Section("今日与即将到期") {
                    NavigationLink { CareReminderCenterView(account: account, farm: farm, focusedReminderID: session.pendingCareReminderID) } label: {
                        Label("待办提醒", systemImage: "bell.badge")
                        Spacer()
                        Text("\(pending.count)").foregroundStyle(.secondary)
                    }
                    ForEach(pending.prefix(3), id: \.id) { CareReminderRow(reminder: $0) }
                }
            }
            Section("快捷录入") {
                Button { sheet = .health } label: { Label("治疗或疫苗", systemImage: "cross.case") }
                Button { sheet = .reproduction } label: { Label("批量配种或孕检", systemImage: "heart.text.square") }
                Button { sheet = .lambing } label: { Label("产羔并建立羔羊档案", systemImage: "pawprint") }
            }
            Section("管理") {
                NavigationLink { HealthCatalogManagementView(account: account, farm: farm) } label: { Label("药品与疫苗目录", systemImage: "books.vertical") }
                NavigationLink { CareInventoryView(account: account, farm: farm) } label: { Label("药品与疫苗库存", systemImage: "shippingbox") }
                NavigationLink { CareSemenView(account: account, farm: farm) } label: { Label("冻精库存", systemImage: "snowflake") }
                NavigationLink { CareRulesView(account: account, farm: farm) } label: { Label("提醒规则", systemImage: "calendar.badge.clock") }
            }
            Section("历史") {
                NavigationLink { HealthHistoryView(account: account, farm: farm) } label: { LabeledContent("健康记录", value: "\(health.count { $0.farmID == farm.id && $0.deletedAt == nil })") }
                NavigationLink { ReproductionHistoryView(account: account, farm: farm) } label: { LabeledContent("繁殖记录", value: "\(reproduction.count { $0.farmID == farm.id && $0.deletedAt == nil })") }
            }
        }
        .navigationTitle("健康与繁殖")
        .sheet(item: $sheet) { destination in
            NavigationStack {
                switch destination {
                case .health: HealthBatchEntryView(account: account, farm: farm)
                case .reproduction: ReproductionBatchEntryView(account: account, farm: farm)
                case .lambing: CareLambingEntryView(account: account, farm: farm)
                case .catalog: HealthCatalogEditorView(account: account, farm: farm)
                }
            }
        }
        .task { await notifications.rescheduleCareReminders(reminders, farmID: farm.id) }
        .onChange(of: reminderRevisionSignature) { _, _ in
            Task { await notifications.rescheduleCareReminders(reminders, farmID: farm.id) }
        }
    }
}

private struct CareReminderRow: View {
    let reminder: CareReminderRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reminder.title)
            Text(reminder.dueAt, format: .dateTime.year().month().day().hour().minute())
                .font(.footnote)
                .foregroundStyle(reminder.dueAt < .now ? .red : .secondary)
        }
    }
}

struct CareReminderCenterView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FarmNotificationService.self) private var notifications
    @Query(sort: \CareReminderRecord.dueAt) private var reminders: [CareReminderRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let focusedReminderID: UUID?
    private let commandService = FarmCommandService()

    private var visible: [CareReminderRecord] { reminders.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .pending } }

    var body: some View {
        List {
            ForEach(visible, id: \.id) { reminder in
                CareReminderRow(reminder: reminder)
                    .swipeActions {
                        Button("完成") { update(reminder, .completed) }.tint(.green)
                        Button("忽略") { update(reminder, .dismissed) }.tint(.gray)
                    }
                    .listRowBackground(reminder.id == focusedReminderID ? Color.accentColor.opacity(0.12) : nil)
            }
        }
        .overlay { if visible.isEmpty { ContentUnavailableView("没有待处理提醒", systemImage: "checkmark.circle") } }
        .navigationTitle("关键提醒")
    }

    private func update(_ reminder: CareReminderRecord, _ status: CareReminderStatus) {
        do {
            try commandService.execute(.care(.setReminderStatus(reminderID: reminder.id, status: status)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            Task { await notifications.rescheduleCareReminders(reminders, farmID: farm.id) }
        } catch {}
    }
}

private enum HealthSubjectMode: String, CaseIterable, Identifiable {
    case single = "单羊"
    case multiple = "多选"
    case pen = "按圈舍"
    var id: String { rawValue }
}

struct HealthBatchEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FarmNotificationService.self) private var notifications
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \HealthCatalogItemRecord.name) private var catalogs: [HealthCatalogItemRecord]
    @Query private var lots: [InventoryLotRecord]
    @Query private var reminders: [CareReminderRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var mode = HealthSubjectMode.single
    @State private var selectedIDs = Set<UUID>()
    @State private var penID: UUID?
    @State private var kind = HealthRecordKind.treatment
    @State private var catalogID: UUID?
    @State private var itemName = ""
    @State private var inventoryLotID: UUID?
    @State private var dose = ""
    @State private var unit = ""
    @State private var route = ""
    @State private var occurredAt = Date.now
    @State private var hasReminder = false
    @State private var reminderAt = Date.now
    @State private var note = ""
    @State private var errorMessage: String?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent } }
    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var matchingCatalogs: [HealthCatalogItemRecord] { catalogs.filter { $0.farmID == farm.id && $0.isActive && catalogMatches($0, kind: kind) } }
    private var matchingLots: [InventoryLotRecord] { lots.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive && $0.kindRawValue == kind.rawValue } }

    var body: some View {
        Form {
            Picker("类型", selection: $kind) { ForEach(HealthRecordKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            Picker("对象", selection: $mode) { ForEach(HealthSubjectMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Section("实际对象") {
                if mode == .pen {
                    Picker("圈舍", selection: $penID) { Text("请选择").tag(UUID?.none); ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                    Text("保存时按发生时间展开该圈舍的历史在场羊只，之后转群不会改变本记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(farmSheep, id: \.id) { record in
                        Button { toggle(record.id) } label: {
                            HStack { Text(record.earTag); Spacer(); if selectedIDs.contains(record.id) { Image(systemName: "checkmark.circle.fill") } }
                        }.buttonStyle(.plain)
                    }
                }
            }
            Section("药品或疫苗") {
                Picker("目录", selection: $catalogID) { Text("手工填写").tag(UUID?.none); ForEach(matchingCatalogs, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }
                TextField("名称", text: $itemName)
                Picker("库存批次", selection: $inventoryLotID) { Text("不扣库存").tag(UUID?.none); ForEach(matchingLots, id: \.id) { Text($0.catalogName).tag(UUID?.some($0.id)) } }
                TextField("每只剂量", text: $dose).keyboardType(.decimalPad)
                TextField("单位", text: $unit)
                TextField("给药途径", text: $route)
            }
            Section("时间与提醒") {
                DatePicker("发生时间", selection: $occurredAt)
                Toggle("创建复免提醒", isOn: $hasReminder)
                if hasReminder { DatePicker("提醒时间", selection: $reminderAt) }
            }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...5)
        }
        .navigationTitle("治疗或疫苗")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .onChange(of: mode) { _, _ in selectedIDs.removeAll(); penID = nil }
        .onChange(of: kind) { _, _ in catalogID = nil; inventoryLotID = nil }
        .onChange(of: catalogID) { _, id in applyCatalog(id) }
    }

    private func toggle(_ id: UUID) {
        if mode == .single { selectedIDs = [id] }
        else if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func applyCatalog(_ id: UUID?) {
        guard let item = matchingCatalogs.first(where: { $0.id == id }) else { return }
        itemName = item.name; unit = item.unit; dose = item.defaultDoseText ?? ""; route = item.defaultRoute
        if let days = item.reminderIntervalDays, let date = Calendar.current.date(byAdding: .day, value: days, to: occurredAt) { hasReminder = true; reminderAt = date }
    }

    private func save() {
        let draft = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: Array(selectedIDs), penID: mode == .pen ? penID : nil, catalogItemID: catalogID, kind: kind, itemName: itemName, occurredAt: occurredAt, note: note, inventoryLotID: inventoryLotID, dosePerSubjectText: dose.isEmpty ? nil : dose, unit: unit, route: route, reminderAt: hasReminder ? reminderAt : nil)
        do {
            try commandService.execute(.care(.recordHealth(draft)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            let refreshed = (try? modelContext.fetch(FetchDescriptor<CareReminderRecord>())) ?? reminders
            Task { await notifications.rescheduleCareReminders(refreshed, farmID: farm.id) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct HealthCatalogManagementView: View {
    @Query(sort: \HealthCatalogItemRecord.name) private var catalogs: [HealthCatalogItemRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var selectedItem: HealthCatalogEditorDestination?

    var body: some View {
        List {
            ForEach(catalogs.filter { $0.farmID == farm.id }, id: \.id) { item in
                Button { selectedItem = .init(id: item.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(item.name); if !item.isActive { Text("已停用").font(.caption).foregroundStyle(.secondary) } }
                        Text([item.unit, item.defaultDoseText, item.defaultRoute].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        }
        .overlay { if catalogs.allSatisfy({ $0.farmID != farm.id }) { ContentUnavailableView("还没有健康目录", systemImage: "books.vertical") } }
        .navigationTitle("药品与疫苗目录")
        .toolbar { Button { selectedItem = .init(id: UUID()) } label: { Image(systemName: "plus") } }
        .sheet(item: $selectedItem) { destination in NavigationStack { HealthCatalogEditorView(account: account, farm: farm, itemID: destination.id) } }
    }
}

struct HealthCatalogEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var catalogs: [HealthCatalogItemRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let itemID: UUID
    private let commandService = FarmCommandService()
    @State private var kind = HealthRecordKind.treatment
    @State private var name = ""
    @State private var category = ""
    @State private var unit = "毫升"
    @State private var dose = ""
    @State private var route = ""
    @State private var reminderDays = ""
    @State private var note = ""
    @State private var isActive = true
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, itemID: UUID = UUID()) { self.account = account; self.farm = farm; self.itemID = itemID }

    var body: some View {
        Form {
            Picker("类型", selection: $kind) { ForEach(HealthRecordKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            TextField("名称", text: $name); TextField("类别", text: $category); TextField("单位", text: $unit)
            TextField("默认剂量", text: $dose).keyboardType(.decimalPad); TextField("默认给药途径", text: $route)
            TextField("默认复免间隔（天）", text: $reminderDays).keyboardType(.numberPad)
            TextField("备注", text: $note, axis: .vertical); Toggle("启用", isOn: $isActive)
        }
        .navigationTitle("健康目录")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .onAppear {
            guard let item = catalogs.first(where: { $0.id == itemID && $0.farmID == farm.id }) else { return }
            kind = catalogHealthKind(item); name = item.name; category = item.category; unit = item.unit; dose = item.defaultDoseText ?? ""; route = item.defaultRoute; reminderDays = item.reminderIntervalDays.map(String.init) ?? ""; note = item.note; isActive = item.isActive
        }
    }

    private func save() {
        do {
            try commandService.execute(.care(.upsertHealthCatalog(id: itemID, kindRawValue: kind.rawValue, name: name, category: category, unit: unit, defaultDoseText: dose.isEmpty ? nil : dose, defaultRoute: route, reminderIntervalDays: Int(reminderDays), note: note, isActive: isActive)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct CareInventoryView: View {
    @Query(sort: \InventoryLotRecord.createdAt, order: .reverse) private var lots: [InventoryLotRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var receiving = false
    var body: some View {
        List {
            ForEach(lots.filter { $0.farmID == farm.id && $0.deletedAt == nil }, id: \.id) { lot in
                NavigationLink { CareInventoryLotDetailView(account: account, farm: farm, lot: lot) } label: {
                    VStack(alignment: .leading) { Text(lot.catalogName); Text(lot.isActive ? "使用中" : "已停用").font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("药品与疫苗库存")
        .toolbar { Button { receiving = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $receiving) { NavigationStack { InventoryReceiveCareView(account: account, farm: farm) } }
    }
}

private struct InventoryReceiveCareView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HealthCatalogItemRecord.name) private var catalogs: [HealthCatalogItemRecord]
    @State private var catalogID: UUID?; @State private var name = ""; @State private var kind = HealthRecordKind.treatment; @State private var batchNumber = ""; @State private var supplier = ""; @State private var unit = ""; @State private var quantity = ""; @State private var hasExpiry = false; @State private var expiry = Date.now; @State private var note = ""; @State private var errorMessage: String?
    let account: AccountProfile; let farm: FarmRecord; private let service = FarmCommandService()
    private var farmCatalogs: [HealthCatalogItemRecord] { catalogs.filter { $0.farmID == farm.id && $0.isActive } }
    var body: some View {
        Form { Picker("目录", selection: $catalogID) { Text("手工填写").tag(UUID?.none); ForEach(farmCatalogs, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }; TextField("名称", text: $name); Picker("类型", selection: $kind) { ForEach(HealthRecordKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }; TextField("批号", text: $batchNumber); TextField("供应商", text: $supplier); TextField("单位", text: $unit); TextField("数量", text: $quantity).keyboardType(.decimalPad); Toggle("记录有效期", isOn: $hasExpiry); if hasExpiry { DatePicker("有效期", selection: $expiry, displayedComponents: .date) }; TextField("备注", text: $note) }
            .navigationTitle("库存入库").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
            .onChange(of: catalogID) { _, id in guard let item = farmCatalogs.first(where: { $0.id == id }) else { return }; name = item.name; kind = catalogHealthKind(item); unit = item.unit }
    }
    private func save() { do { try service.execute(.care(.receiveInventory(id: UUID(), catalogName: name, catalogItemID: catalogID, kindRawValue: kind.rawValue, batchNumber: batchNumber, supplier: supplier, unit: unit, expiresAt: hasExpiry ? expiry : nil, quantityText: quantity, occurredAt: .now, note: note)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct CareInventoryLotDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [InventoryTransactionRecord]
    let account: AccountProfile; let farm: FarmRecord; let lot: InventoryLotRecord
    @State private var delta = ""; @State private var note = ""; @State private var errorMessage: String?
    private let service = FarmCommandService()
    private var farmTransactions: [InventoryTransactionRecord] { transactions.filter { $0.farmID == farm.id && $0.inventoryLotID == lot.id && $0.deletedAt == nil } }
    private var balance: Decimal { farmTransactions.reduce(0) { partial, value in switch value.kind { case .receipt, .adjustment: partial + value.quantity; case .consumption: partial - value.quantity } } }
    var body: some View {
        List {
            Section("批次") { LabeledContent("名称", value: lot.catalogName); LabeledContent("余量", value: balance.stableText); if let date = lot.expiresAt { LabeledContent("有效期", value: date.formatted(date: .abbreviated, time: .omitted)) } }
            Section("盘点调整") { TextField("增减数量，例如 -2 或 5", text: $delta).keyboardType(.numbersAndPunctuation); TextField("原因", text: $note); Button("保存调整", action: adjust) }
            Section("流水") { ForEach(farmTransactions.sorted { $0.occurredAt > $1.occurredAt }, id: \.id) { value in LabeledContent(value.note.isEmpty ? value.kindRawValue : value.note, value: value.quantityText) } }
            Section { Button(lot.isActive ? "停用批次" : "重新启用") { setActive(!lot.isActive) } }
        }.navigationTitle("库存详情").recordErrorAlert($errorMessage)
    }
    private func adjust() { do { try service.execute(.care(.adjustInventory(id: UUID(), lotID: lot.id, quantityDeltaText: delta, occurredAt: .now, note: note)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); delta = ""; note = "" } catch { errorMessage = error.localizedDescription } }
    private func setActive(_ active: Bool) { do { try service.execute(.care(.setInventoryLotActive(lotID: lot.id, isActive: active)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
}

struct ReproductionBatchEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FarmNotificationService.self) private var notifications
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \SemenRecord.code) private var semen: [SemenRecord]
    @Query private var rules: [FarmCareRuleRecord]
    @Query private var reminders: [CareReminderRecord]
    let account: AccountProfile; let farm: FarmRecord
    private let service = FarmCommandService()
    @State private var kind = ReproductionRecordKind.breeding; @State private var selected = Set<UUID>(); @State private var results: [UUID: String] = [:]; @State private var sireID: UUID?; @State private var semenID: UUID?; @State private var semenUnits = "1"; @State private var occurredAt = Date.now; @State private var reminderAt = Date.now; @State private var note = ""; @State private var errorMessage: String?
    private var ewes: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.sex == .ewe } }
    private var rams: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.sex == .ram } }
    private var farmSemen: [SemenRecord] { semen.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var rule: FarmCareRuleRecord? { rules.first { $0.farmID == farm.id } }
    var body: some View {
        Form {
            Picker("类型", selection: $kind) { Text("配种").tag(ReproductionRecordKind.breeding); Text("孕检").tag(ReproductionRecordKind.pregnancyCheck); Text("流产").tag(ReproductionRecordKind.abortion) }
            Section("母羊（可多选）") { ForEach(ewes, id: \.id) { ewe in Button { if selected.contains(ewe.id) { selected.remove(ewe.id) } else { selected.insert(ewe.id) } } label: { HStack { Text(ewe.earTag); Spacer(); if selected.contains(ewe.id) { Image(systemName: "checkmark.circle.fill") } } }.buttonStyle(.plain); if kind == .pregnancyCheck && selected.contains(ewe.id) { TextField("\(ewe.earTag)结果", text: Binding(get: { results[ewe.id, default: ""] }, set: { results[ewe.id] = $0 })) } } }
            if kind == .breeding { Section("父本来源") { Picker("本交公羊", selection: $sireID) { Text("不使用本交").tag(UUID?.none); ForEach(rams, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) } }; Picker("冻精", selection: $semenID) { Text("不使用冻精").tag(UUID?.none); ForEach(farmSemen, id: \.id) { Text($0.code).tag(UUID?.some($0.id)) } }; if semenID != nil { TextField("每只用量", text: $semenUnits).keyboardType(.decimalPad) } } }
            DatePicker("发生时间", selection: $occurredAt); if kind != .abortion { DatePicker(kind == .breeding ? "孕检提醒" : "预产提醒", selection: $reminderAt) }; TextField("备注", text: $note, axis: .vertical)
        }
        .navigationTitle("批量配种或孕检").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
        .onAppear { updateReminder() }.onChange(of: kind) { _, _ in sireID = nil; semenID = nil; updateReminder() }.onChange(of: occurredAt) { _, _ in updateReminder() }
    }
    private func updateReminder() { let days = kind == .breeding ? (rule?.pregnancyCheckDays ?? 45) : (rule?.gestationDays ?? 150); reminderAt = Calendar.current.date(byAdding: .day, value: days, to: occurredAt) ?? occurredAt }
    private func save() { let subjects = selected.map { CareReproductionSubjectDraft(eweID: $0, result: results[$0] ?? "") }; let draft = CareReproductionBatchDraft(id: UUID(), kind: kind, subjects: subjects, occurredAt: occurredAt, sireID: kind == .breeding ? sireID : nil, semenID: kind == .breeding ? semenID : nil, semenUnitsPerEweText: kind == .breeding && semenID != nil ? semenUnits : nil, note: note, reminderAt: kind == .abortion ? nil : reminderAt); do { try service.execute(.care(.recordReproductionBatch(draft)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); let refreshed = (try? modelContext.fetch(FetchDescriptor<CareReminderRecord>())) ?? reminders; Task { await notifications.rescheduleCareReminders(refreshed, farmID: farm.id) }; dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct LambFormRow: Identifiable { let id = UUID(); let sheepID = UUID(); var earTag = ""; var sex = SheepSex.ram; var birthWeight = ""; var createRecord = true; var isStillborn = false }

struct CareLambingEntryView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]; @Query(sort: \PenRecord.name) private var pens: [PenRecord]; @Query(sort: \SemenRecord.code) private var semen: [SemenRecord]
    let account: AccountProfile; let farm: FarmRecord; private let service = FarmCommandService()
    @State private var eweID: UUID?; @State private var sireID: UUID?; @State private var semenID: UUID?; @State private var penID: UUID?; @State private var occurredAt = Date.now; @State private var parity = 1; @State private var rows = [LambFormRow()]; @State private var note = ""; @State private var errorMessage: String?
    private var ewes: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.sex == .ewe } }; private var rams: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.sex == .ram } }; private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }; private var farmSemen: [SemenRecord] { semen.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    var body: some View {
        Form { Picker("母羊", selection: $eweID) { Text("请选择").tag(UUID?.none); ForEach(ewes, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) } }; Picker("公羊", selection: $sireID) { Text("未知或冻精").tag(UUID?.none); ForEach(rams, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) } }; Picker("冻精", selection: $semenID) { Text("未关联").tag(UUID?.none); ForEach(farmSemen, id: \.id) { Text($0.code).tag(UUID?.some($0.id)) } }; Picker("羔羊圈舍", selection: $penID) { Text("未分圈").tag(UUID?.none); ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }; DatePicker("产羔时间", selection: $occurredAt); Stepper("胎次：\(parity)", value: $parity, in: 1...20); LabeledContent("产羔总数", value: "\(rows.count)"); LabeledContent("死胎数", value: "\(rows.count(where: \.isStillborn))"); Section("逐只羔羊") { ForEach($rows) { $row in VStack { TextField("耳号", text: $row.earTag); Picker("性别", selection: $row.sex) { Text("公").tag(SheepSex.ram); Text("母").tag(SheepSex.ewe) }; TextField("初生重", text: $row.birthWeight).keyboardType(.decimalPad); Toggle("死胎", isOn: $row.isStillborn); Toggle("建立羊只档案", isOn: $row.createRecord).disabled(row.isStillborn) } }.onDelete { rows.remove(atOffsets: $0) }; Button("增加一只羔羊") { rows.append(LambFormRow()) } }; TextField("备注", text: $note, axis: .vertical) }
            .navigationTitle("产羔记录").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
    }
    private func save() { guard let eweID else { errorMessage = "请选择母羊。"; return }; let offspring = rows.map { CareLambDraft(id: $0.id, sheepID: $0.sheepID, earTag: $0.earTag, sex: $0.sex, birthWeightText: $0.birthWeight, createSheepRecord: $0.isStillborn ? false : $0.createRecord, isStillborn: $0.isStillborn) }; let draft = CareLambingDraft(id: UUID(), eweID: eweID, occurredAt: occurredAt, sireID: sireID, semenID: semenID, parity: parity, birthDeadCount: offspring.count(where: \.isStillborn), offspring: offspring, penID: penID, note: note); do { try service.execute(.care(.recordLambing(draft)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription } }
}

struct CareSemenView: View {
    @Query(sort: \SemenRecord.code) private var semen: [SemenRecord]
    let account: AccountProfile; let farm: FarmRecord
    var body: some View { List { NavigationLink { SemenLibraryView(account: account, farm: farm) } label: { Label("新增冻精批次", systemImage: "plus") }; ForEach(semen.filter { $0.farmID == farm.id && $0.deletedAt == nil }, id: \.id) { record in NavigationLink { CareSemenDetailView(account: account, farm: farm, semen: record) } label: { Text(record.code) } } }.navigationTitle("冻精库存") }
}

private struct CareSemenDetailView: View {
    @Environment(\.modelContext) private var modelContext; @Query private var transactions: [SemenTransactionRecord]
    let account: AccountProfile; let farm: FarmRecord; let semen: SemenRecord; private let service = FarmCommandService()
    @State private var delta = ""; @State private var note = ""; @State private var errorMessage: String?
    private var balance: Decimal { let initial = Decimal.stable(semen.quantityText) ?? 0; return transactions.filter { $0.farmID == farm.id && $0.semenID == semen.id && $0.deletedAt == nil }.reduce(initial) { partial, value in switch value.kind { case .receipt, .adjustment: partial + value.quantity; case .consumption: partial - value.quantity } } }
    var body: some View { Form { LabeledContent("编号", value: semen.code); LabeledContent("余量", value: balance.stableText); TextField("增减数量", text: $delta).keyboardType(.numbersAndPunctuation); TextField("原因", text: $note); Button("保存调整", action: save) }.navigationTitle("冻精详情").recordErrorAlert($errorMessage) }
    private func save() { do { try service.execute(.care(.adjustSemen(id: UUID(), semenID: semen.id, quantityDeltaText: delta, occurredAt: .now, note: note)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); delta = ""; note = "" } catch { errorMessage = error.localizedDescription } }
}

struct CareRulesView: View {
    @Environment(\.modelContext) private var modelContext; @Query private var rules: [FarmCareRuleRecord]
    let account: AccountProfile; let farm: FarmRecord; private let service = FarmCommandService()
    @State private var checkDays = 45; @State private var gestationDays = 150; @State private var errorMessage: String?
    var body: some View { Form { Stepper("配种后孕检：\(checkDays) 天", value: $checkDays, in: 1...365); Stepper("妊娠周期：\(gestationDays) 天", value: $gestationDays, in: 100...220); Button("保存规则", action: save) }.navigationTitle("提醒规则").onAppear { if let value = rules.first(where: { $0.farmID == farm.id }) { checkDays = value.pregnancyCheckDays; gestationDays = value.gestationDays } }.recordErrorAlert($errorMessage) }
    private func save() { do { try service.execute(.care(.updateRules(id: rules.first(where: { $0.farmID == farm.id })?.id ?? UUID(), pregnancyCheckDays: checkDays, gestationDays: gestationDays)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
}

struct HealthHistoryView: View {
    @Query(sort: \HealthRecord.occurredAt, order: .reverse) private var health: [HealthRecord]; @Query private var links: [HealthSubjectLink]; @Query private var sheep: [SheepRecord]
    let account: AccountProfile; let farm: FarmRecord; @State private var kind: HealthRecordKind?; @State private var query = ""
    private var filtered: [HealthRecord] { health.filter { $0.farmID == farm.id && (kind == nil || $0.kind == kind) && (query.isEmpty || $0.itemNameSnapshot.localizedCaseInsensitiveContains(query)) } }
    var body: some View { List { Section { Picker("类型", selection: $kind) { Text("全部").tag(HealthRecordKind?.none); ForEach(HealthRecordKind.allCases, id: \.self) { Text($0.displayName).tag(HealthRecordKind?.some($0)) } } }; ForEach(filtered, id: \.id) { record in NavigationLink { HealthRecordDetailView(account: account, farm: farm, record: record) } label: { VStack(alignment: .leading) { Text(record.itemNameSnapshot); Text("\(subjectCount(record)) 只 · \(record.occurredAt.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary); if record.deletedAt != nil { Text("已撤销").font(.caption).foregroundStyle(.red) } } } } }.navigationTitle("健康历史").searchable(text: $query, prompt: "药品、疫苗或项目") }
    private func subjectCount(_ record: HealthRecord) -> Int { max(record.sheepID == nil ? 0 : 1, links.count { $0.farmID == farm.id && $0.healthRecordID == record.id }) }
}

private struct HealthRecordDetailView: View {
    @Environment(\.modelContext) private var modelContext; @Query private var links: [HealthSubjectLink]; @Query private var sheep: [SheepRecord]; @Query private var tombstones: [TombstoneRecord]
    let account: AccountProfile; let farm: FarmRecord; let record: HealthRecord; private let service = FarmCommandService(); @State private var errorMessage: String?; @State private var correction: HealthCorrectionDestination?
    private var names: [String] { let ids = Set(links.filter { $0.farmID == farm.id && $0.healthRecordID == record.id }.map(\.sheepID)); return sheep.filter { ids.contains($0.id) }.map(\.earTag).sorted() }
    var body: some View { List { Section("事实") { LabeledContent("项目", value: record.itemNameSnapshot); LabeledContent("时间", value: record.occurredAt.formatted()); LabeledContent("对象", value: names.isEmpty ? "历史圈舍记录" : names.joined(separator: "、")); if let dose = record.quantityText { LabeledContent("每只剂量", value: "\(dose) \(record.unit)") }; if !record.route.isEmpty { LabeledContent("途径", value: record.route) }; Text(record.note) }; Section { if record.deletedAt == nil { Button("修正记录") { correction = .init(id: record.id) }; Button("撤销记录", role: .destructive, action: revoke) } else if let tombstone = tombstones.first(where: { $0.farmID == farm.id && $0.entityID == record.id && $0.restoredAt == nil && !$0.reason.hasPrefix("修正：") }) { Button("恢复记录") { restore(tombstone.id) } } } }.navigationTitle("健康记录详情").recordErrorAlert($errorMessage).sheet(item: $correction) { _ in NavigationStack { HealthCorrectionView(account: account, farm: farm, record: record) } } }
    private func revoke() { do { try service.execute(.tombstoneEntity(entityType: .health, entityID: record.id, reason: "用户撤销健康记录"), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
    private func restore(_ id: UUID) { do { try service.execute(.restoreTombstonedEntity(tombstoneID: id), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
}

private struct HealthCorrectionDestination: Identifiable { let id: UUID }

private struct HealthCorrectionView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var modelContext
    @Query private var links: [HealthSubjectLink]; @Query private var lots: [InventoryLotRecord]; @Query private var reminders: [CareReminderRecord]
    let account: AccountProfile; let farm: FarmRecord; let record: HealthRecord; private let service = FarmCommandService()
    @State private var itemName = ""; @State private var occurredAt = Date.now; @State private var inventoryLotID: UUID?; @State private var dose = ""; @State private var unit = ""; @State private var route = ""; @State private var note = ""; @State private var reason = ""; @State private var hasReminder = false; @State private var reminderAt = Date.now; @State private var errorMessage: String?
    private var availableLots: [InventoryLotRecord] { lots.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive && $0.kindRawValue == record.kindRawValue } }
    var body: some View {
        Form {
            Section("修正后的事实") { TextField("项目", text: $itemName); DatePicker("发生时间", selection: $occurredAt); Picker("库存批次", selection: $inventoryLotID) { Text("不扣库存").tag(UUID?.none); ForEach(availableLots, id: \.id) { Text($0.catalogName).tag(UUID?.some($0.id)) } }; TextField("每只剂量", text: $dose).keyboardType(.decimalPad); TextField("单位", text: $unit); TextField("给药途径", text: $route); TextField("备注", text: $note, axis: .vertical) }
            Section("提醒") { Toggle("保留复免提醒", isOn: $hasReminder); if hasReminder { DatePicker("提醒日期", selection: $reminderAt) } }
            Section("审计") { TextField("修正原因", text: $reason, axis: .vertical) }
        }
        .navigationTitle("修正健康记录").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
        .onAppear { itemName = record.itemNameSnapshot; occurredAt = record.occurredAt; inventoryLotID = record.inventoryLotID; dose = record.quantityText ?? ""; unit = record.unit; route = record.route; note = record.note; if let reminder = reminders.first(where: { $0.farmID == farm.id && $0.sourceEntityID == record.id && $0.deletedAt == nil }) { hasReminder = true; reminderAt = reminder.dueAt } }
    }
    private func save() {
        let subjectIDs = links.filter { $0.farmID == farm.id && $0.healthRecordID == record.id }.map(\.sheepID)
        let resolvedSubjects = subjectIDs.isEmpty ? record.sheepID.map { [$0] } ?? [] : subjectIDs
        let draft = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: resolvedSubjects, penID: resolvedSubjects.isEmpty ? record.penID : nil, catalogItemID: record.catalogItemID, kind: record.kind, itemName: itemName, occurredAt: occurredAt, note: note, inventoryLotID: inventoryLotID, dosePerSubjectText: dose.isEmpty ? nil : dose, unit: unit, route: route, reminderAt: hasReminder ? reminderAt : nil)
        do { try service.execute(.care(.correctHealth(originalID: record.id, replacement: draft, reason: reason)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription }
    }
}

struct ReproductionHistoryView: View {
    @Query(sort: \ReproductionRecord.occurredAt, order: .reverse) private var records: [ReproductionRecord]; @Query private var sheep: [SheepRecord]
    let account: AccountProfile; let farm: FarmRecord; @State private var kind: ReproductionRecordKind?
    private var filtered: [ReproductionRecord] { records.filter { $0.farmID == farm.id && (kind == nil || $0.kind == kind) } }
    var body: some View { List { Section { Picker("类型", selection: $kind) { Text("全部").tag(ReproductionRecordKind?.none); ForEach(ReproductionRecordKind.allCases, id: \.self) { Text($0.displayName).tag(ReproductionRecordKind?.some($0)) } } }; ForEach(filtered, id: \.id) { record in NavigationLink { ReproductionRecordDetailView(account: account, farm: farm, record: record) } label: { VStack(alignment: .leading) { Text("\(earTag(record.eweID)) · \(record.kind.displayName)"); Text(record.occurredAt, format: .dateTime.year().month().day()).font(.footnote).foregroundStyle(.secondary); if record.deletedAt != nil { Text("已撤销").font(.caption).foregroundStyle(.red) } } } } }.navigationTitle("繁殖历史") }
    private func earTag(_ id: UUID) -> String { sheep.first(where: { $0.id == id })?.earTag ?? "未知母羊" }
}

private struct ReproductionRecordDetailView: View {
    @Environment(\.modelContext) private var modelContext; @Query private var sheep: [SheepRecord]; @Query private var tombstones: [TombstoneRecord]
    let account: AccountProfile; let farm: FarmRecord; let record: ReproductionRecord; private let service = FarmCommandService(); @State private var errorMessage: String?; @State private var correction: ReproductionCorrectionDestination?
    private var eweName: String { sheep.first(where: { $0.id == record.eweID })?.earTag ?? "未知母羊" }
    var body: some View {
        List {
            Section("事实") { LabeledContent("母羊", value: eweName); LabeledContent("类型", value: record.kind.displayName); LabeledContent("发生时间", value: record.occurredAt.formatted()); if let sireID = record.sireID { LabeledContent("公羊", value: sheep.first(where: { $0.id == sireID })?.earTag ?? sireID.uuidString) }; if let semen = record.semenNameSnapshot { LabeledContent("冻精", value: semen) }; if !record.result.isEmpty { LabeledContent("结果", value: record.result) }; if record.kind == .lambing { LabeledContent("产羔总数", value: "\(record.lambCount)"); LabeledContent("死胎", value: "\(record.birthDeadCount ?? 0)") }; if !record.note.isEmpty { Text(record.note) } }
            Section { if record.deletedAt == nil { if record.kind != .lambing { Button("修正记录") { correction = .init(id: record.id) } }; Button("撤销记录", role: .destructive, action: revoke) } else if let tombstone = tombstones.first(where: { $0.farmID == farm.id && $0.entityID == record.id && $0.restoredAt == nil && !$0.reason.hasPrefix("修正：") }) { Button("恢复记录") { restore(tombstone.id) } } }
        }.navigationTitle("繁殖记录详情").recordErrorAlert($errorMessage).sheet(item: $correction) { _ in NavigationStack { ReproductionCorrectionView(account: account, farm: farm, record: record) } }
    }
    private func revoke() { do { try service.execute(.tombstoneEntity(entityType: .reproduction, entityID: record.id, reason: "用户撤销繁殖记录"), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
    private func restore(_ id: UUID) { do { try service.execute(.restoreTombstonedEntity(tombstoneID: id), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
}

private struct ReproductionCorrectionDestination: Identifiable { let id: UUID }

private struct ReproductionCorrectionView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var modelContext
    @Query private var sheep: [SheepRecord]; @Query private var semen: [SemenRecord]; @Query private var reminders: [CareReminderRecord]; @Query private var semenTransactions: [SemenTransactionRecord]
    let account: AccountProfile; let farm: FarmRecord; let record: ReproductionRecord; private let service = FarmCommandService()
    @State private var occurredAt = Date.now; @State private var sireID: UUID?; @State private var semenID: UUID?; @State private var semenUnits = "1"; @State private var result = ""; @State private var note = ""; @State private var reason = ""; @State private var hasReminder = false; @State private var reminderAt = Date.now; @State private var errorMessage: String?
    private var rams: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.sex == .ram } }
    private var farmSemen: [SemenRecord] { semen.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    var body: some View {
        Form {
            Section("修正后的事实") { LabeledContent("类型", value: record.kind.displayName); DatePicker("发生时间", selection: $occurredAt); TextField("结果", text: $result); if record.kind == .breeding { Picker("本交公羊", selection: $sireID) { Text("不使用本交").tag(UUID?.none); ForEach(rams, id: \.id) { Text($0.earTag).tag(UUID?.some($0.id)) } }; Picker("冻精", selection: $semenID) { Text("不使用冻精").tag(UUID?.none); ForEach(farmSemen, id: \.id) { Text($0.code).tag(UUID?.some($0.id)) } }; if semenID != nil { TextField("冻精用量", text: $semenUnits).keyboardType(.decimalPad) } }; TextField("备注", text: $note, axis: .vertical) }
            if record.kind != .abortion { Section("提醒") { Toggle("保留关联提醒", isOn: $hasReminder); if hasReminder { DatePicker("提醒日期", selection: $reminderAt) } } }
            Section("审计") { TextField("修正原因", text: $reason, axis: .vertical) }
        }
        .navigationTitle("修正繁殖记录").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
        .onAppear { occurredAt = record.occurredAt; sireID = record.sireID; semenID = record.semenID; result = record.result; note = record.note; semenUnits = semenTransactions.first(where: { $0.farmID == farm.id && $0.sourceRecordID == record.id && $0.kind == .consumption && $0.deletedAt == nil })?.quantityText ?? "1"; if let reminder = reminders.first(where: { $0.farmID == farm.id && $0.sourceEntityID == record.id && $0.deletedAt == nil }) { hasReminder = true; reminderAt = reminder.dueAt } }
    }
    private func save() {
        let draft = CareReproductionBatchDraft(id: UUID(), kind: record.kind, subjects: [.init(eweID: record.eweID, result: result)], occurredAt: occurredAt, sireID: record.kind == .breeding ? sireID : nil, semenID: record.kind == .breeding ? semenID : nil, semenUnitsPerEweText: record.kind == .breeding && semenID != nil ? semenUnits : nil, note: note, reminderAt: record.kind == .abortion || !hasReminder ? nil : reminderAt)
        do { try service.execute(.care(.correctReproduction(originalID: record.id, replacement: draft, reason: reason)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription }
    }
}

private func catalogMatches(_ item: HealthCatalogItemRecord, kind: HealthRecordKind) -> Bool {
    let raw = item.kindRawValue.lowercased()
    return kind == .vaccination ? ["vaccination", "vaccine"].contains(raw) : ["treatment", "medicine", "disease"].contains(raw)
}

private func catalogHealthKind(_ item: HealthCatalogItemRecord) -> HealthRecordKind {
    ["vaccination", "vaccine"].contains(item.kindRawValue.lowercased()) ? .vaccination : .treatment
}
