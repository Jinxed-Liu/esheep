import SwiftData
import SwiftUI

private struct HealthCatalogEditorDestination: Identifiable {
    let id: UUID
}

struct CareManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FarmNotificationService.self) private var notifications
    @Query(sort: \CareReminderRecord.dueAt) private var reminders: [CareReminderRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var summary = CareManagementSummarySnapshot.empty
    @State private var summaryRefreshRevision = 0

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _reminders = Query(
            filter: #Predicate<CareReminderRecord> { $0.farmID == farmID },
            sort: \CareReminderRecord.dueAt
        )
    }

    private var reminderRevisionSignature: [String] { reminders.map { "\($0.id.uuidString):\($0.revision):\($0.dueAt.timeIntervalSinceReferenceDate):\($0.deletedAt?.timeIntervalSinceReferenceDate ?? 0)" }.sorted() }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                SettingsCard(title: "健康管理") {
                    SettingsNavigationRow(title: "药品与疫苗目录", subtitle: "维护常用名称、剂量和单位", systemImage: "books.vertical.fill", iconColor: .blue) {
                        HealthCatalogManagementView(account: account, farm: farm)
                    }
                    SettingsCardDivider()
                    SettingsNavigationRow(title: "药品与疫苗库存", subtitle: "查看批次、余量和有效期", systemImage: "shippingbox.fill", iconColor: .teal) {
                        CareInventoryView(account: account, farm: farm)
                    }
                }

                SettingsCard(title: "繁殖管理") {
                    SettingsNavigationRow(title: "配种方案", subtitle: "维护可复用的繁殖流程", systemImage: "list.number", iconColor: .indigo) {
                        BreedingProgramListView(account: account, farm: farm)
                    }
                    SettingsCardDivider()
                    SettingsNavigationRow(title: "冻精库存", subtitle: "维护冻精与公羊来源", systemImage: "snowflake", iconColor: .cyan) {
                        CareSemenView(account: account, farm: farm)
                    }
                    SettingsCardDivider()
                    SettingsNavigationRow(title: "全场系谱检查", subtitle: "发现重复、缺失或冲突关系", systemImage: "point.3.connected.trianglepath.dotted", iconColor: .orange) {
                        PedigreeCheckView(account: account, farm: farm)
                    }
                }

                SettingsCard(title: "提醒与历史") {
                    SettingsNavigationRow(title: "待办与异常", subtitle: "查看到期待办和业务异常", systemImage: "exclamationmark.bubble.fill", iconColor: .orange) {
                        FarmOperationalAlertCenterView(account: account, farm: farm)
                    }
                    SettingsCardDivider()
                    SettingsNavigationRow(title: "提醒与异常规则", subtitle: "设置断奶、孕检和每日汇总", systemImage: "calendar.badge.clock", iconColor: .blue) {
                        CareRulesView(account: account, farm: farm)
                    }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "健康记录",
                        subtitle: "\(summary.healthRecordCount) 条有效记录",
                        systemImage: "clock.arrow.circlepath",
                        iconColor: .red
                    ) { HealthHistoryView(account: account, farm: farm) }
                    SettingsCardDivider()
                    SettingsNavigationRow(
                        title: "繁殖记录",
                        subtitle: "\(summary.reproductionRecordCount) 条有效记录",
                        systemImage: "clock.badge.checkmark.fill",
                        iconColor: .pink
                    ) { ReproductionHistoryView(account: account, farm: farm) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("健康与繁殖管理")
        .task(id: summaryRefreshRevision) { await loadSummary() }
        .task { await notifications.rescheduleCareReminders(reminders, farmID: farm.id) }
        .onChange(of: reminderRevisionSignature) { _, _ in
            Task { await notifications.rescheduleCareReminders(reminders, farmID: farm.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: FarmOperationalAlertRuntimeNotification.refreshRequested)) { notification in
            guard FarmOperationalAlertRuntimeNotification.farmID(from: notification) == farm.id else { return }
            summaryRefreshRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudRuntimeNotification.syncWake)) { notification in
            guard CloudRuntimeNotification.farmID(from: notification) == farm.id else { return }
            summaryRefreshRevision &+= 1
        }
    }

    @MainActor
    private func loadSummary() async {
        do {
            let loaded = try await CareManagementSummarySnapshotActor(container: modelContext.container)
                .load(farmID: farm.id)
            try Task.checkCancellation()
            summary = loaded
        } catch is CancellationError {
            return
        } catch {
            // Preserve the last valid counts until the next local/cloud refresh.
        }
    }
}

private struct CareReminderRow: View {
    let reminder: CareReminderRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(reminder.title))
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
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \HealthCatalogItemRecord.name) private var catalogs: [HealthCatalogItemRecord]
    @Query private var lots: [InventoryLotRecord]
    @Query private var reminders: [CareReminderRecord]
    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var sheepCandidates: [SheepEarTagSearchCandidate] = []
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
    @State private var sheepIDsByPenAtOccurrence: [UUID: Set<UUID>] = [:]

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _pens = Query(
            filter: #Predicate<PenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \PenRecord.name
        )
        _catalogs = Query(
            filter: #Predicate<HealthCatalogItemRecord> { $0.farmID == farmID },
            sort: \HealthCatalogItemRecord.name
        )
        _lots = Query(filter: #Predicate<InventoryLotRecord> { $0.farmID == farmID && $0.deletedAt == nil })
        _reminders = Query(filter: #Predicate<CareReminderRecord> { $0.farmID == farmID })
    }

    private var eligiblePenIDs: Set<UUID> { Set(sheepIDsByPenAtOccurrence.keys) }
    private var farmPens: [PenRecord] {
        pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && eligiblePenIDs.contains($0.id) }
    }
    private var matchingCatalogs: [HealthCatalogItemRecord] { catalogs.filter { $0.farmID == farm.id && $0.isActive && catalogMatches($0, kind: kind) } }
    private var matchingLots: [InventoryLotRecord] { lots.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive && $0.kindRawValue == kind.rawValue } }
    var body: some View {
        Form {
            Picker("类型", selection: $kind) { ForEach(HealthRecordKind.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }
            Picker("对象", selection: $mode) { ForEach(HealthSubjectMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }.pickerStyle(.segmented)
            Section("实际对象") {
                if mode == .pen {
                    Picker("圈舍", selection: $penID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(farmPens, id: \.id) { pen in
                            Text("\(pen.name)（\(sheepIDsByPenAtOccurrence[pen.id, default: []].count)只）")
                                .tag(UUID?.some(pen.id))
                        }
                    }
                    if farmPens.isEmpty {
                        Text("该发生时间没有可选的有羊圈舍。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text("保存时按发生时间展开该圈舍的历史在场羊只，之后转群不会改变本记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    SheepEarTagMultiSearchField(
                        candidates: sheepCandidates,
                        selection: $selectedIDs,
                        maximumSelectionCount: mode == .single ? 1 : nil,
                        prompt: mode == .single ? "输入耳号搜索" : "输入耳号搜索并添加",
                        emptySelectionText: mode == .single ? "尚未确认羊只" : "尚未添加羊只"
                    )
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
        .farmExcelImport(account: account, farm: farm, sheets: ["健康记录"])
        .task(id: farm.id) { await loadSheepCandidates() }
        .onChange(of: mode) { _, _ in selectedIDs.removeAll(); penID = nil }
        .onChange(of: kind) { _, _ in catalogID = nil; inventoryLotID = nil }
        .onChange(of: catalogID) { _, id in applyCatalog(id) }
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

    private func applyCatalog(_ id: UUID?) {
        guard let item = matchingCatalogs.first(where: { $0.id == id }) else { return }
        itemName = item.name; unit = item.unit; dose = item.defaultDoseText ?? ""; route = item.defaultRoute
        if let days = item.reminderIntervalDays, let date = Calendar.current.date(byAdding: .day, value: days, to: occurredAt) { hasReminder = true; reminderAt = date }
    }

    @MainActor
    private func loadSheepCandidates() async {
        do {
            sheepCandidates = try await SheepEarTagCandidateSnapshotActor(container: modelContext.container)
                .load(farmID: farm.id, scope: .active)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "读取健康记录羊只失败：\(error.localizedDescription)"
        }
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
        .farmExcelImport(account: account, farm: farm, sheets: ["健康目录"])
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
            Picker("类型", selection: $kind) { ForEach(HealthRecordKind.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }
            TextField("名称", text: $name); TextField("类别", text: $category); TextField("单位", text: $unit)
            TextField("默认剂量", text: $dose).keyboardType(.decimalPad); TextField("默认给药途径", text: $route)
            TextField("默认复免间隔（天）", text: $reminderDays).keyboardType(.numberPad)
            TextField("备注", text: $note, axis: .vertical); Toggle("启用", isOn: $isActive)
        }
        .navigationTitle("健康目录")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["健康目录"])
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
                    VStack(alignment: .leading) { Text(lot.catalogName); Text(lot.isActive ? LocalizedStringKey("使用中") : LocalizedStringKey("已停用")).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("药品与疫苗库存")
        .toolbar { Button { receiving = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $receiving) { NavigationStack { InventoryReceiveCareView(account: account, farm: farm) } }
        .farmExcelImport(account: account, farm: farm, sheets: ["库存入库", "库存调整"])
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
        Form { Picker("目录", selection: $catalogID) { Text("手工填写").tag(UUID?.none); ForEach(farmCatalogs, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }; TextField("名称", text: $name); Picker("类型", selection: $kind) { ForEach(HealthRecordKind.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) } }; TextField("批号", text: $batchNumber); TextField("供应商", text: $supplier); TextField("单位", text: $unit); TextField("数量", text: $quantity).keyboardType(.decimalPad); Toggle("记录有效期", isOn: $hasExpiry); if hasExpiry { DatePicker("有效期", selection: $expiry, displayedComponents: .date) }; TextField("备注", text: $note) }
            .navigationTitle("库存入库").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
            .farmExcelImport(account: account, farm: farm, sheets: ["库存入库"])
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
            Section { Button(lot.isActive ? LocalizedStringKey("停用批次") : LocalizedStringKey("重新启用")) { setActive(!lot.isActive) } }
        }.navigationTitle("库存详情").recordErrorAlert($errorMessage)
            .farmExcelImport(account: account, farm: farm, sheets: ["库存调整"])
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
    @Query(sort: \ReproductionRecord.occurredAt, order: .reverse) private var reproduction: [ReproductionRecord]
    @Query private var rules: [FarmCareRuleRecord]
    @Query private var reminders: [CareReminderRecord]
    let account: AccountProfile; let farm: FarmRecord
    private let service = FarmCommandService()
    @State private var kind = ReproductionRecordKind.breeding; @State private var selected = Set<UUID>(); @State private var results: [UUID: String] = [:]; @State private var relatedBreedings: [UUID: UUID] = [:]; @State private var sireID: UUID?; @State private var semenID: UUID?; @State private var semenUnits = "1"; @State private var occurredAt = Date.now; @State private var reminderAt = Date.now; @State private var note = ""; @State private var errorMessage: String?

    init(
        account: AccountProfile,
        farm: FarmRecord,
        initialKind: ReproductionRecordKind = .breeding,
        initialEweID: UUID? = nil,
        initialRelatedBreedingID: UUID? = nil
    ) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _sheep = Query(
            filter: #Predicate<SheepRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SheepRecord.earTag
        )
        _semen = Query(
            filter: #Predicate<SemenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SemenRecord.code
        )
        _reproduction = Query(
            filter: #Predicate<ReproductionRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \ReproductionRecord.occurredAt,
            order: .reverse
        )
        _rules = Query(filter: #Predicate<FarmCareRuleRecord> { $0.farmID == farmID })
        _reminders = Query(filter: #Predicate<CareReminderRecord> { $0.farmID == farmID })
        _kind = State(initialValue: initialKind)
        _selected = State(initialValue: initialEweID.map { Set([$0]) } ?? Set())
        if let initialEweID, let initialRelatedBreedingID {
            _relatedBreedings = State(initialValue: [initialEweID: initialRelatedBreedingID])
        }
    }
    private var ewes: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.sex == .ewe } }
    private var breedingRams: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.sex == .ram && $0.isBreedingRam } }
    private var farmSemen: [SemenRecord] { semen.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var eweCandidates: [SheepEarTagSearchCandidate] { ewes.map { .init(sheep: $0) } }
    private var ramCandidates: [SheepEarTagSearchCandidate] { breedingRams.map { .init(sheep: $0) } }
    private var selectedEwes: [SheepRecord] { ewes.filter { selected.contains($0.id) } }
    private var rule: FarmCareRuleRecord? { rules.first { $0.farmID == farm.id } }
    var body: some View {
        Form {
            Picker("类型", selection: $kind) { Text("配种").tag(ReproductionRecordKind.breeding); Text("孕检").tag(ReproductionRecordKind.pregnancyCheck); Text("流产").tag(ReproductionRecordKind.abortion) }
            Section("母羊（可多选）") {
                SheepEarTagMultiSearchField(
                    candidates: eweCandidates,
                    selection: $selected,
                    showsSelectedCandidates: false,
                    prompt: "输入母羊耳号搜索并添加",
                    accessibilityName: "母羊耳号"
                )
                ForEach(selectedEwes, id: \.id) { ewe in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ewe.earTag)
                            HStack(spacing: 0) {
                                Text(LocalizedStringKey(ewe.sex.displayName))
                                Text(" · ")
                                Text(verbatim: ewe.breed)
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            remove(ewe.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除母羊耳号 \(ewe.earTag)")
                    }
                    if selected.contains(ewe.id), kind != .breeding {
                        TextField("\(ewe.earTag)结果", text: Binding(get: { results[ewe.id, default: ""] }, set: { results[ewe.id] = $0 }))
                        Picker("关联配种", selection: breedingBinding(for: ewe.id)) {
                            Text("保持未关联").tag(UUID?.none)
                            ForEach(openBreedings(for: ewe.id), id: \.id) { record in
                                Text(breedingLabel(record)).tag(UUID?.some(record.id))
                            }
                        }
                        if let relatedID = relatedBreedings[ewe.id], let related = reproduction.first(where: { $0.id == relatedID }) {
                            LabeledContent("父本来源", value: related.paternalSource.displayName)
                            LabeledContent("预计产羔", value: expectedLambingDate(for: related).formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
            if kind == .breeding {
                Section("父本来源") {
                    SheepEarTagSingleSearchField(
                        candidates: ramCandidates,
                        selection: $sireID,
                        prompt: "输入种公羊耳号搜索",
                        emptySelectionText: "不使用本交",
                        accessibilityName: "种公羊耳号"
                    )
                    Picker("冻精", selection: $semenID) { Text("不使用冻精").tag(UUID?.none); ForEach(farmSemen, id: \.id) { Text($0.code).tag(UUID?.some($0.id)) } }
                    if semenID != nil { TextField("每只用量", text: $semenUnits).keyboardType(.decimalPad) }
                    Text("本场种公羊与冻精必须二选一；普通公羊不会出现在此处。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            DatePicker("发生时间", selection: $occurredAt); if kind != .abortion { DatePicker(kind == .breeding ? "孕检提醒" : "预产提醒", selection: $reminderAt) }; TextField("备注", text: $note, axis: .vertical)
        }
        .navigationTitle("批量配种或孕检").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["繁殖记录"])
        .onAppear { updateReminder() }
        .onChange(of: kind) { _, _ in sireID = nil; semenID = nil; relatedBreedings.removeAll(); updateReminder() }
        .onChange(of: occurredAt) { _, _ in updateReminder() }
        .onChange(of: sireID) { _, value in if value != nil { semenID = nil } }
        .onChange(of: semenID) { _, value in if value != nil { sireID = nil } }
    }
    private func remove(_ id: UUID) {
        selected.remove(id)
        results.removeValue(forKey: id)
        relatedBreedings.removeValue(forKey: id)
    }
    private func breedingBinding(for eweID: UUID) -> Binding<UUID?> { Binding(get: { relatedBreedings[eweID] }, set: { value in if let value { relatedBreedings[eweID] = value } else { relatedBreedings.removeValue(forKey: eweID) } }) }
    private func openBreedings(for eweID: UUID) -> [ReproductionRecord] { reproduction.filter { record in record.farmID == farm.id && record.eweID == eweID && record.kind == .breeding && record.deletedAt == nil && record.occurredAt <= occurredAt && !reproduction.contains { closure in closure.farmID == farm.id && closure.relatedBreedingRecordID == record.id && closure.deletedAt == nil && (closure.kind == .lambing || closure.kind == .abortion) } } }
    private func breedingLabel(_ record: ReproductionRecord) -> String { "\(record.occurredAt.formatted(date: .abbreviated, time: .omitted)) · \(record.paternalSource.displayName)" }
    private func expectedLambingDate(for record: ReproductionRecord) -> Date { Calendar.current.date(byAdding: .day, value: rule?.gestationDays ?? 150, to: record.occurredAt) ?? record.occurredAt }
    private func updateReminder() { let days = kind == .breeding ? (rule?.pregnancyCheckDays ?? 45) : (rule?.gestationDays ?? 150); reminderAt = Calendar.current.date(byAdding: .day, value: days, to: occurredAt) ?? occurredAt }
    private func save() { let subjects = selected.map { CareReproductionSubjectDraft(eweID: $0, result: results[$0] ?? "", relatedBreedingRecordID: kind == .breeding ? nil : relatedBreedings[$0]) }; let draft = CareReproductionBatchDraft(id: UUID(), kind: kind, subjects: subjects, occurredAt: occurredAt, sireID: kind == .breeding ? sireID : nil, semenID: kind == .breeding ? semenID : nil, semenUnitsPerEweText: kind == .breeding && semenID != nil ? semenUnits : nil, note: note, reminderAt: kind == .abortion ? nil : reminderAt); do { try service.execute(.care(.recordReproductionBatch(draft)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); let refreshed = (try? modelContext.fetch(FetchDescriptor<CareReminderRecord>())) ?? reminders; Task { await notifications.rescheduleCareReminders(refreshed, farmID: farm.id) }; dismiss() } catch { errorMessage = error.localizedDescription } }
}

private struct LambFormRow: Identifiable {
    let id: UUID
    let sheepID: UUID
    var earTag: String
    var breed: String
    var breedWasEdited: Bool
    var sex: SheepSex
    var weight: String
    var weightOccurredAt: Date?
    var createRecord: Bool
    var isStillborn: Bool

    init(id: UUID = UUID(), sheepID: UUID = UUID(), earTag: String = "", breed: String = "", breedWasEdited: Bool = false, sex: SheepSex = .ram, weight: String = "", weightOccurredAt: Date? = nil, createRecord: Bool = true, isStillborn: Bool = false) {
        self.id = id
        self.sheepID = sheepID
        self.earTag = earTag
        self.breed = breed
        self.breedWasEdited = breedWasEdited
        self.sex = sex
        self.weight = weight
        self.weightOccurredAt = weightOccurredAt
        self.createRecord = createRecord
        self.isStillborn = isStillborn
    }
}

private enum LambingFormLimits {
    static let maximumLambCount = 100
}

private func parityDisplayName(_ parity: Int) -> String {
    parity == 0 ? "0 胎" : "第 \(parity) 胎"
}

private func lambingPaternalBreed(
    relatedBreeding: ReproductionRecord?,
    selectedSireID: UUID?,
    selectedSemenID: UUID?,
    sheep: [SheepRecord],
    semen: [SemenRecord],
    donors: [SemenDonorRecord]
) -> String? {
    func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    if let relatedBreeding {
        if let breed = normalized(relatedBreeding.semenDonorBreedSnapshot) {
            return breed
        }
        if let sireID = relatedBreeding.sireID,
           let breed = normalized(sheep.first(where: { $0.id == sireID })?.breed) {
            return breed
        }
        if let semenID = relatedBreeding.semenID,
           let breed = normalized(semen.first(where: { $0.id == semenID })?.breed) {
            return breed
        }
        return nil
    }
    if let selectedSireID {
        return normalized(sheep.first(where: { $0.id == selectedSireID })?.breed)
    }
    if let selectedSemenID {
        guard let semenRecord = semen.first(where: { $0.id == selectedSemenID }) else {
            return nil
        }
        if let donorID = semenRecord.donorID,
           let donor = donors.first(where: { $0.id == donorID && $0.deletedAt == nil }) {
            if let breed = normalized(donor.breed) {
                return breed
            }
            if let linkedRamID = donor.linkedRamID,
               let breed = normalized(sheep.first(where: { $0.id == linkedRamID })?.breed) {
                return breed
            }
        }
        return normalized(semenRecord.breed)
    }
    return nil
}

private struct LambCountSection: View {
    @Binding var countText: String
    let deadCount: Int

    var body: some View {
        Section {
            TextField("产羔总数", text: $countText)
                .keyboardType(.numberPad)
            LabeledContent("死胎数", value: "\(deadCount)")
        } header: {
            Text("羔羊数量")
        } footer: {
            Text("填写总数后会自动生成对应数量的羔羊区块；减少总数会移除末尾的羔羊明细。")
        }
    }
}

private struct LambFormSection: View {
    @Binding var row: LambFormRow
    let number: Int
    let lambingAt: Date
    let canRemove: Bool
    let remove: () -> Void

    private var recordsWeight: Binding<Bool> {
        Binding(
            get: { row.weightOccurredAt != nil },
            set: { enabled in
                if enabled {
                    row.weightOccurredAt = lambingAt
                } else {
                    row.weight = ""
                    row.weightOccurredAt = nil
                }
            }
        )
    }

    private var weightDate: Binding<Date> {
        Binding(
            get: { row.weightOccurredAt ?? lambingAt },
            set: { row.weightOccurredAt = $0 }
        )
    }

    private var weightKind: LambRecordedWeightKind? {
        row.weightOccurredAt.map {
            LambingEntrySemantics.weightKind(lambingAt: lambingAt, weighedAt: $0)
        }
    }

    private var editableBreed: Binding<String> {
        Binding(
            get: { row.breed },
            set: { value in
                row.breed = value
                row.breedWasEdited = true
            }
        )
    }

    var body: some View {
        Section {
            TextField("耳号", text: $row.earTag)
            TextField("品种（可修改）", text: editableBreed)
            Picker("性别", selection: $row.sex) {
                Text("公").tag(SheepSex.ram)
                Text("母").tag(SheepSex.ewe)
            }
            Toggle("死胎", isOn: $row.isStillborn)
                .onChange(of: row.isStillborn) { _, isStillborn in
                    if isStillborn { row.createRecord = false }
                }
            Toggle("建立羊只档案", isOn: $row.createRecord)
                .disabled(row.isStillborn)
            Toggle("记录体重", isOn: recordsWeight)
            if row.weightOccurredAt != nil {
                TextField("体重（kg）", text: $row.weight)
                    .keyboardType(.decimalPad)
                DatePicker("称重日期与时间", selection: weightDate, in: lambingAt...Date.now)
                if let weightKind {
                    LabeledContent("记录类型", value: weightKind.displayName)
                }
            }
            if canRemove {
                Button("删除这只羔羊", role: .destructive, action: remove)
            }
        } header: {
            Text("羔羊 \(number)")
        } footer: {
            Text("品种为系统建议，可直接修改；保存时以填写内容为准。")
            if weightKind == .routine {
                Text(row.createRecord ? LocalizedStringKey("已超过出生 24 小时，将按实际时间保存为普通称重。") : LocalizedStringKey("普通称重必须建立羊只档案后才能保存。"))
            }
        }
    }
}

struct CareLambingEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \SemenRecord.code) private var semen: [SemenRecord]
    @Query(sort: \SemenDonorRecord.name) private var semenDonors: [SemenDonorRecord]
    @Query(sort: \ReproductionRecord.occurredAt, order: .reverse) private var reproduction: [ReproductionRecord]
    @Query private var rules: [FarmCareRuleRecord]

    let account: AccountProfile
    let farm: FarmRecord
    private let service = FarmCommandService()

    @State private var eweID: UUID?
    @State private var sireID: UUID?
    @State private var semenID: UUID?
    @State private var relatedBreedingID: UUID?
    @State private var penID: UUID?
    @State private var occurredAt = Date.now
    @State private var rows = [LambFormRow()]
    @State private var lambCountText = "1"
    @State private var note = ""
    @State private var candidates: [PedigreeSireCandidate] = []
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _sheep = Query(
            filter: #Predicate<SheepRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SheepRecord.earTag
        )
        _pens = Query(
            filter: #Predicate<PenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \PenRecord.name
        )
        _semen = Query(
            filter: #Predicate<SemenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SemenRecord.code
        )
        _semenDonors = Query(
            filter: #Predicate<SemenDonorRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SemenDonorRecord.name
        )
        _reproduction = Query(
            filter: #Predicate<ReproductionRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \ReproductionRecord.occurredAt,
            order: .reverse
        )
        _rules = Query(filter: #Predicate<FarmCareRuleRecord> { $0.farmID == farmID })
    }

    private var ewes: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.sex == .ewe } }
    private var breedingRams: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.sex == .ram && $0.isBreedingRam } }
    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var farmSemen: [SemenRecord] { semen.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var gestationDays: Int { rules.first { $0.farmID == farm.id }?.gestationDays ?? 150 }
    private var eweCandidates: [SheepEarTagSearchCandidate] { ewes.map { .init(sheep: $0) } }
    private var ramCandidates: [SheepEarTagSearchCandidate] { breedingRams.map { .init(sheep: $0) } }
    private var openBreedings: [ReproductionRecord] { guard let eweID else { return [] }; return reproduction.filter { record in record.farmID == farm.id && record.eweID == eweID && record.kind == .breeding && record.deletedAt == nil && record.occurredAt <= occurredAt && !reproduction.contains { closure in closure.farmID == farm.id && closure.relatedBreedingRecordID == record.id && closure.deletedAt == nil && (closure.kind == .lambing || closure.kind == .abortion) } } }
    private var relatedBreeding: ReproductionRecord? { relatedBreedingID.flatMap { id in openBreedings.first { $0.id == id } } }
    private var sireCandidateBreedSuggestion: String? {
        guard relatedBreedingID == nil, sireID == nil, semenID == nil else { return nil }
        return LambingEntrySemantics.soleSireCandidateBreedForSuggestion(
            candidateBreeds: candidates.map(\.breed)
        )
    }
    private var suggestedLambBreed: String {
        let confirmedPaternalBreed = lambingPaternalBreed(
            relatedBreeding: relatedBreeding,
            selectedSireID: sireID,
            selectedSemenID: semenID,
            sheep: sheep,
            semen: semen,
            donors: semenDonors
        )
        return LambingEntrySemantics.suggestedLambBreed(
            paternalBreed: confirmedPaternalBreed ?? sireCandidateBreedSuggestion,
            maternalBreed: eweID.flatMap { id in sheep.first(where: { $0.id == id })?.breed }
        )
    }
    private var recordedCurrentParity: Int {
        guard let eweID else { return 0 }
        return LambingEntrySemantics.currentParity(eweID: eweID, farmID: farm.id, before: occurredAt, records: reproduction)
    }
    private var nextParity: Int { recordedCurrentParity + 1 }

    var body: some View {
        Form {
            Section("产羔母羊") {
                SheepEarTagSingleSearchField(
                    candidates: eweCandidates,
                    selection: $eweID,
                    prompt: "输入母羊耳号搜索",
                    emptySelectionText: "尚未确认产羔母羊",
                    accessibilityName: "母羊耳号"
                )
            }
            Section("产羔事实") {
                DatePicker("产羔时间", selection: $occurredAt, in: ...Date.now)
                Picker("羔羊圈舍", selection: $penID) {
                    Text("未分圈").tag(UUID?.none)
                    ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            Section("母羊胎次") {
                if eweID == nil {
                    Text("确认母羊后计算本次胎次。")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("产羔前当前胎次", value: parityDisplayName(recordedCurrentParity))
                    LabeledContent("本次产羔胎次", value: parityDisplayName(recordedCurrentParity + 1))
                }
            }
            LambCountSection(countText: $lambCountText, deadCount: rows.count(where: \.isStillborn))
            Section("繁殖链") {
                Picker("关联配种", selection: $relatedBreedingID) { Text("保持未关联").tag(UUID?.none); ForEach(openBreedings, id: \.id) { Text("\($0.occurredAt.formatted(date: .abbreviated, time: .omitted)) · \($0.paternalSource.displayName)").tag(UUID?.some($0.id)) } }
                if let relatedBreeding {
                    LabeledContent("父本来源", value: relatedBreeding.paternalSource.displayName)
                    LabeledContent("原预计产羔", value: (Calendar.current.date(byAdding: .day, value: gestationDays, to: relatedBreeding.occurredAt) ?? relatedBreeding.occurredAt).formatted(date: .abbreviated, time: .omitted))
                }
            }
            if relatedBreedingID == nil {
                Section("父本来源") {
                    SheepEarTagSingleSearchField(
                        candidates: ramCandidates,
                        selection: $sireID,
                        prompt: "输入种公羊耳号搜索",
                        emptySelectionText: "未知或使用冻精",
                        accessibilityName: "种公羊耳号"
                    )
                    Picker("冻精", selection: $semenID) { Text("未关联").tag(UUID?.none); ForEach(farmSemen, id: \.id) { Text($0.code).tag(UUID?.some($0.id)) } }
                }
                if !candidates.isEmpty {
                    Section("历史同舍种公羊候选") {
                        Text("以产羔时间向前推 \(gestationDays) 天，仅检查当时同舍且在场的种公羊。候选不会自动确权。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(candidates) { candidate in
                            Button { sireID = candidate.ramID; semenID = nil } label: {
                                HStack { VStack(alignment: .leading) { Text(candidate.earTag); Text("排序分 \(candidate.rankingScore, format: .number.precision(.fractionLength(2)))").font(.caption).foregroundStyle(.secondary) }; Spacer(); if sireID == candidate.ramID { Image(systemName: "checkmark.circle.fill") } }
                            }
                        }
                        if sireCandidateBreedSuggestion != nil {
                            Text("唯一候选的品种已用于羔羊品种建议；父本仍未确认。点击候选后，保存时才会写入系谱。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            ForEach($rows) { $row in
                LambFormSection(
                    row: $row,
                    number: (rows.firstIndex { $0.id == row.id } ?? 0) + 1,
                    lambingAt: occurredAt,
                    canRemove: rows.count > 1,
                    remove: { removeLamb(row.id) }
                )
            }
            Section {
                Button("增加一只羔羊", action: appendLamb)
                    .disabled(rows.count >= LambingFormLimits.maximumLambCount)
            }
            Section("备注") { TextField("备注", text: $note, axis: .vertical) }
        }
            .navigationTitle("产羔记录").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
            .farmExcelImport(account: account, farm: farm, sheets: ["产羔"])
            .onAppear(perform: refreshCandidates)
            .onChange(of: eweID) { _, _ in
                relatedBreedingID = nil
                resetAndRefreshCandidates()
                applyBreedSuggestion()
            }
            .onChange(of: occurredAt) { oldValue, newValue in
                for index in rows.indices {
                    guard let weighedAt = rows[index].weightOccurredAt else { continue }
                    if weighedAt == oldValue || weighedAt < newValue {
                        rows[index].weightOccurredAt = newValue
                    }
                }
                relatedBreedingID = nil
                resetAndRefreshCandidates()
                applyBreedSuggestion()
            }
            .onChange(of: lambCountText) { _, value in resizeRows(to: value) }
            .onChange(of: relatedBreedingID) { _, value in
                if value != nil { sireID = nil; semenID = nil }
                applyBreedSuggestion()
            }
            .onChange(of: sireID) { _, value in
                if value != nil { semenID = nil }
                applyBreedSuggestion()
            }
            .onChange(of: semenID) { _, value in
                if value != nil { sireID = nil }
                applyBreedSuggestion()
            }
    }
    private func appendLamb() {
        guard rows.count < LambingFormLimits.maximumLambCount else { return }
        rows.append(LambFormRow(breed: suggestedLambBreed))
        lambCountText = "\(rows.count)"
    }
    private func removeLamb(_ id: UUID) {
        rows.removeAll { $0.id == id }
        lambCountText = "\(rows.count)"
    }
    private func resizeRows(to text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(normalized), (1...LambingFormLimits.maximumLambCount).contains(count) else { return }
        if count > rows.count {
            rows.append(contentsOf: (rows.count..<count).map { _ in LambFormRow(breed: suggestedLambBreed) })
        } else if count < rows.count {
            rows.removeLast(rows.count - count)
        }
    }
    private func applyBreedSuggestion() {
        let suggestion = suggestedLambBreed
        for index in rows.indices {
            rows[index].breed = LambingEntrySemantics.breedAfterApplyingSuggestion(
                currentBreed: rows[index].breed,
                suggestedBreed: suggestion,
                userOverrodeSuggestion: rows[index].breedWasEdited
            )
        }
    }
    private func resetAndRefreshCandidates() {
        sireID = nil
        semenID = nil
        refreshCandidates()
    }
    private func refreshCandidates() {
        guard let eweID else {
            candidates = []
            return
        }
        do {
            candidates = try PedigreeAnalysis.sireCandidates(
                eweID: eweID,
                lambingAt: occurredAt,
                gestationDays: gestationDays,
                farmID: farm.id,
                context: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    private func save() {
        guard let eweID else { errorMessage = "请先搜索并确认产羔母羊。"; return }
        let normalizedCount = lambCountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intendedCount = Int(normalizedCount),
              (1...LambingFormLimits.maximumLambCount).contains(intendedCount),
              intendedCount == rows.count else {
            errorMessage = "产羔总数必须是 1 到 \(LambingFormLimits.maximumLambCount) 的整数。"
            return
        }
        let offspring = rows.map {
            CareLambDraft(
                id: $0.id,
                sheepID: $0.sheepID,
                earTag: $0.earTag,
                breed: $0.breed,
                sex: $0.sex,
                birthWeightText: $0.weight,
                weightOccurredAt: $0.weightOccurredAt,
                createSheepRecord: $0.isStillborn ? false : $0.createRecord,
                isStillborn: $0.isStillborn
            )
        }
        let draft = CareLambingDraft(id: UUID(), eweID: eweID, occurredAt: occurredAt, sireID: relatedBreedingID == nil ? sireID : nil, semenID: relatedBreedingID == nil ? semenID : nil, relatedBreedingRecordID: relatedBreedingID, parity: nextParity, birthDeadCount: offspring.count(where: \.isStillborn), offspring: offspring, penID: penID, note: note)
        do {
            try service.execute(.care(.recordLambing(draft)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct CareSemenView: View {
    @Query(sort: \SemenRecord.code) private var semen: [SemenRecord]
    @Query(sort: \SemenDonorRecord.name) private var donors: [SemenDonorRecord]
    let account: AccountProfile; let farm: FarmRecord
    private var donorByID: [UUID: SemenDonorRecord] { Dictionary(uniqueKeysWithValues: donors.filter { $0.farmID == farm.id }.map { ($0.id, $0) }) }
    var body: some View { List { Section("管理") { NavigationLink { SemenLibraryView(account: account, farm: farm) } label: { Label("新增冻精批次", systemImage: "plus") }; NavigationLink { SemenDonorManagementView(account: account, farm: farm) } label: { Label("冻精供体档案", systemImage: "person.crop.circle") } }; Section("冻精批次") { ForEach(semen.filter { $0.farmID == farm.id && $0.deletedAt == nil }, id: \.id) { record in NavigationLink { CareSemenDetailView(account: account, farm: farm, semen: record) } label: { VStack(alignment: .leading, spacing: 3) { Text(record.code); Text(record.donorID.flatMap { donorByID[$0]?.name } ?? "未关联供体").font(.caption).foregroundStyle(.secondary) } } } } }.navigationTitle("冻精库存").farmExcelImport(account: account, farm: farm, sheets: ["冻精入库", "冻精调整", "冻精供体"]) }
}

private struct CareSemenDetailView: View {
    @Environment(\.modelContext) private var modelContext; @Query private var transactions: [SemenTransactionRecord]
    @Query(sort: \SemenDonorRecord.name) private var donors: [SemenDonorRecord]
    let account: AccountProfile; let farm: FarmRecord; let semen: SemenRecord; private let service = FarmCommandService()
    @State private var delta = ""; @State private var note = ""; @State private var donorID: UUID?; @State private var errorMessage: String?
    private var balance: Decimal { let initial = Decimal.stable(semen.quantityText) ?? 0; return transactions.filter { $0.farmID == farm.id && $0.semenID == semen.id && $0.deletedAt == nil }.reduce(initial) { partial, value in switch value.kind { case .receipt, .adjustment: partial + value.quantity; case .consumption: partial - value.quantity } } }
    private var farmDonors: [SemenDonorRecord] { donors.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .active } }
    var body: some View { Form { Section("批次") { LabeledContent("编号", value: semen.code); LabeledContent("余量", value: balance.stableText) }; Section("供体") { Picker("冻精供体", selection: $donorID) { Text("未关联").tag(UUID?.none); ForEach(farmDonors, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) } }; Button("保存供体关联", action: saveDonor).disabled(!CapabilitySet(role: farm.role).allows(.manageCatalogs)) }; Section("库存调整") { TextField("增减数量", text: $delta).keyboardType(.numbersAndPunctuation); TextField("原因", text: $note); Button("保存调整", action: save) } }.navigationTitle("冻精详情").recordErrorAlert($errorMessage).farmExcelImport(account: account, farm: farm, sheets: ["冻精调整", "冻精供体"]).onAppear { donorID = semen.donorID } }
    private func save() { do { try service.execute(.care(.adjustSemen(id: UUID(), semenID: semen.id, quantityDeltaText: delta, occurredAt: .now, note: note)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); delta = ""; note = "" } catch { errorMessage = error.localizedDescription } }
    private func saveDonor() { do { try service.execute(.care(.setSemenDonor(semenID: semen.id, donorID: donorID, expectedRevision: semen.revision)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
}

struct CareRulesView: View {
    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        FarmOperationalAlertRulesView(account: account, farm: farm)
    }
}

struct HealthHistoryView: View {
    @Query private var health: [HealthRecord]
    @Query private var links: [HealthSubjectLink]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var kind: HealthRecordKind?
    @State private var query = ""
    @State private var normalizedNames = [UUID: String]()

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _health = Query(
            filter: #Predicate<HealthRecord> { $0.farmID == farmID },
            sort: \HealthRecord.occurredAt,
            order: .reverse
        )
        _links = Query(filter: #Predicate<HealthSubjectLink> { $0.farmID == farmID })
    }

    private var sourceRevision: [HealthHistorySourceRevision] {
        health.map {
            HealthHistorySourceRevision(
                id: $0.id,
                itemName: $0.itemNameSnapshot,
                kindRawValue: $0.kindRawValue,
                deletedAt: $0.deletedAt
            )
        }
    }

    var body: some View {
        let normalizedQuery = SearchText.normalized(query)
        let filteredRecords = health.filter {
            (kind == nil || $0.kind == kind) &&
                (normalizedQuery.isEmpty || normalizedNames[$0.id, default: ""].contains(normalizedQuery))
        }
        let linkedSubjectCounts = Dictionary(grouping: links, by: \.healthRecordID)
            .mapValues { $0.count }

        List {
            Section {
                Picker("类型", selection: $kind) {
                    Text("全部").tag(HealthRecordKind?.none)
                    ForEach(HealthRecordKind.allCases, id: \.self) {
                        Text(LocalizedStringKey($0.displayName)).tag(HealthRecordKind?.some($0))
                    }
                }
            }
            ForEach(filteredRecords, id: \.id) { record in
                NavigationLink {
                    HealthRecordDetailView(account: account, farm: farm, record: record)
                } label: {
                    VStack(alignment: .leading) {
                        Text(record.itemNameSnapshot)
                        Text(
                            "\(max(record.sheepID == nil ? 0 : 1, linkedSubjectCounts[record.id, default: 0])) 只 · \(record.occurredAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        if record.deletedAt != nil {
                            Text("已撤销")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("健康历史")
        .searchable(text: $query, prompt: "药品、疫苗或项目")
        .onChange(of: sourceRevision, initial: true) { _, _ in
            normalizedNames = Dictionary(
                uniqueKeysWithValues: health.map {
                    ($0.id, SearchText.normalized($0.itemNameSnapshot))
                }
            )
        }
    }
}

private struct HealthHistorySourceRevision: Equatable {
    let id: UUID
    let itemName: String
    let kindRawValue: String
    let deletedAt: Date?
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

struct HealthCorrectionView: View {
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
    private var filtered: [ReproductionRecord] { records.filter { $0.farmID == farm.id && $0.kind != .parityBaseline && (kind == nil || $0.kind == kind) } }
    var body: some View { List { Section { Picker("类型", selection: $kind) { Text("全部").tag(ReproductionRecordKind?.none); ForEach(ReproductionRecordKind.allCases.filter { $0 != .parityBaseline }, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag(ReproductionRecordKind?.some($0)) } } }; ForEach(filtered, id: \.id) { record in NavigationLink { ReproductionRecordDetailView(account: account, farm: farm, record: record) } label: { VStack(alignment: .leading) { Text("\(earTag(record.eweID)) · \(record.kind.displayName)"); Text(record.occurredAt, format: .dateTime.year().month().day()).font(.footnote).foregroundStyle(.secondary); if record.deletedAt != nil { Text("已撤销").font(.caption).foregroundStyle(.red) } } } } }.navigationTitle("繁殖历史") }
    private func earTag(_ id: UUID) -> String { sheep.first(where: { $0.id == id })?.earTag ?? "未知母羊" }
}

private struct ReproductionRecordDetailView: View {
    @Environment(\.modelContext) private var modelContext; @Query private var sheep: [SheepRecord]; @Query private var tombstones: [TombstoneRecord]
    let account: AccountProfile; let farm: FarmRecord; let record: ReproductionRecord; private let service = FarmCommandService(); @State private var errorMessage: String?; @State private var correction: ReproductionCorrectionDestination?; @State private var showRevokePrompt = false; @State private var revokeReason = ""
    private var eweName: String { sheep.first(where: { $0.id == record.eweID })?.earTag ?? "未知母羊" }
    var body: some View {
        List {
            Section("事实") { LabeledContent("母羊", value: eweName); LabeledContent("类型", value: record.kind.displayName); LabeledContent("发生时间", value: record.occurredAt.formatted()); LabeledContent("父本来源", value: record.paternalSource.displayName); if let sireID = record.sireID { LabeledContent("种公羊", value: sheep.first(where: { $0.id == sireID })?.earTag ?? sireID.uuidString) }; if let semen = record.semenNameSnapshot { LabeledContent("冻精", value: semen) }; if let donor = record.semenDonorNameSnapshot { LabeledContent("供体快照", value: donor) }; if let related = record.relatedBreedingRecordID { LabeledContent("关联配种", value: related.uuidString) }; if !record.result.isEmpty { LabeledContent("结果", value: record.result) }; if record.kind == .lambing { LabeledContent("产羔总数", value: "\(record.lambCount)"); LabeledContent("死胎", value: "\(record.birthDeadCount ?? 0)") }; if !record.note.isEmpty { Text(record.note) } }
            Section { if record.kind == .parityBaseline { Text("胎次请在母羊档案中确认；这里保留事实但不允许直接改写。") } else if record.deletedAt == nil { Button("修正记录") { correction = .init(id: record.id) }; Button("撤销记录", role: .destructive) { if record.kind == .lambing { revokeReason = ""; showRevokePrompt = true } else { revoke() } } } else if record.kind == .lambing { Button("安全恢复产羔") { restoreLambing() } } else if let tombstone = tombstones.first(where: { $0.farmID == farm.id && $0.entityID == record.id && $0.restoredAt == nil && !$0.reason.hasPrefix("修正：") }) { Button("恢复记录") { restore(tombstone.id) } } }
        }.navigationTitle("繁殖记录详情").recordErrorAlert($errorMessage).sheet(item: $correction) { _ in NavigationStack { if record.kind == .lambing { LambingCorrectionView(account: account, farm: farm, record: record) } else { ReproductionCorrectionView(account: account, farm: farm, record: record) } } }.alert("撤销产羔记录", isPresented: $showRevokePrompt) { TextField("撤销原因（必填）", text: $revokeReason); Button("撤销", role: .destructive, action: revoke); Button("取消", role: .cancel) {} } message: { Text("不会删除羔羊档案及其后续记录，只补偿本次产羔自动建立且未被人工修正的关系与称重记录。") }
    }
    private func revoke() { do { let command: FarmCommand = record.kind == .lambing ? .care(.revokeLambing(recordID: record.id, reason: revokeReason)) : .tombstoneEntity(entityType: .reproduction, entityID: record.id, reason: "用户撤销繁殖记录"); try service.execute(command, in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
    private func restore(_ id: UUID) { do { try service.execute(.restoreTombstonedEntity(tombstoneID: id), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
    private func restoreLambing() { do { try service.execute(.care(.restoreLambing(recordID: record.id)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext) } catch { errorMessage = error.localizedDescription } }
}

private struct ReproductionCorrectionDestination: Identifiable { let id: UUID }

struct ReproductionCorrectionView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var modelContext
    @Query private var sheep: [SheepRecord]; @Query private var semen: [SemenRecord]; @Query private var reminders: [CareReminderRecord]; @Query private var semenTransactions: [SemenTransactionRecord]
    let account: AccountProfile; let farm: FarmRecord; let record: ReproductionRecord; private let service = FarmCommandService()
    @State private var occurredAt = Date.now; @State private var sireID: UUID?; @State private var semenID: UUID?; @State private var semenUnits = "1"; @State private var result = ""; @State private var note = ""; @State private var reason = ""; @State private var hasReminder = false; @State private var reminderAt = Date.now; @State private var errorMessage: String?
    private var rams: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.sex == .ram && $0.isBreedingRam } }
    private var farmSemen: [SemenRecord] { semen.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var ramCandidates: [SheepEarTagSearchCandidate] { rams.map { .init(sheep: $0) } }
    var body: some View {
        Form {
            Section("修正后的事实") {
                LabeledContent("类型", value: record.kind.displayName)
                DatePicker("发生时间", selection: $occurredAt)
                TextField("结果", text: $result)
                if record.kind == .breeding {
                    SheepEarTagSingleSearchField(
                        candidates: ramCandidates,
                        selection: $sireID,
                        prompt: "输入种公羊耳号搜索",
                        emptySelectionText: "不使用本交",
                        accessibilityName: "种公羊耳号"
                    )
                    Picker("冻精", selection: $semenID) { Text("不使用冻精").tag(UUID?.none); ForEach(farmSemen, id: \.id) { Text($0.code).tag(UUID?.some($0.id)) } }
                    if semenID != nil { TextField("冻精用量", text: $semenUnits).keyboardType(.decimalPad) }
                }
                TextField("备注", text: $note, axis: .vertical)
            }
            if record.kind != .abortion { Section("提醒") { Toggle("保留关联提醒", isOn: $hasReminder); if hasReminder { DatePicker("提醒日期", selection: $reminderAt) } } }
            Section("审计") { TextField("修正原因", text: $reason, axis: .vertical) }
        }
        .navigationTitle("修正繁殖记录").toolbar { EntrySaveToolbar(action: save) }.recordErrorAlert($errorMessage)
        .onAppear { occurredAt = record.occurredAt; sireID = record.sireID; semenID = record.semenID; result = record.result; note = record.note; semenUnits = semenTransactions.first(where: { $0.farmID == farm.id && $0.sourceRecordID == record.id && $0.kind == .consumption && $0.deletedAt == nil })?.quantityText ?? "1"; if let reminder = reminders.first(where: { $0.farmID == farm.id && $0.sourceEntityID == record.id && $0.deletedAt == nil }) { hasReminder = true; reminderAt = reminder.dueAt } }
        .onChange(of: sireID) { _, value in if value != nil { semenID = nil } }
        .onChange(of: semenID) { _, value in if value != nil { sireID = nil } }
    }
    private func save() {
        let draft = CareReproductionBatchDraft(id: UUID(), kind: record.kind, subjects: [.init(eweID: record.eweID, result: result)], occurredAt: occurredAt, sireID: record.kind == .breeding ? sireID : nil, semenID: record.kind == .breeding ? semenID : nil, semenUnitsPerEweText: record.kind == .breeding && semenID != nil ? semenUnits : nil, note: note, reminderAt: record.kind == .abortion || !hasReminder ? nil : reminderAt)
        do { try service.execute(.care(.correctReproduction(originalID: record.id, replacement: draft, reason: reason)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext); dismiss() } catch { errorMessage = error.localizedDescription }
    }
}

private enum LambingPaternalMode: String, CaseIterable, Identifiable {
    case unknown
    case breedingRam
    case semen
    var id: String { rawValue }
    var title: String { switch self { case .unknown: "未知"; case .breedingRam: "本场种公羊"; case .semen: "冻精" } }
}

struct LambingCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \SemenRecord.code) private var semen: [SemenRecord]
    @Query(sort: \SemenDonorRecord.name) private var semenDonors: [SemenDonorRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \ReproductionRecord.occurredAt, order: .reverse) private var reproduction: [ReproductionRecord]
    @Query private var offspringRecords: [LambingOffspringRecord]
    @Query private var weightRecords: [WeightRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let record: ReproductionRecord
    private let service = FarmCommandService()

    @State private var occurredAt = Date.now
    @State private var relatedBreedingID: UUID?
    @State private var paternalMode = LambingPaternalMode.unknown
    @State private var sireID: UUID?
    @State private var semenID: UUID?
    @State private var penID: UUID?
    @State private var rows: [LambFormRow] = []
    @State private var lambCountText = ""
    @State private var note = ""
    @State private var reason = ""
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, record: ReproductionRecord) {
        self.account = account
        self.farm = farm
        self.record = record
        let farmID = farm.id
        _sheep = Query(
            filter: #Predicate<SheepRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SheepRecord.earTag
        )
        _semen = Query(
            filter: #Predicate<SemenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SemenRecord.code
        )
        _semenDonors = Query(
            filter: #Predicate<SemenDonorRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \SemenDonorRecord.name
        )
        _pens = Query(
            filter: #Predicate<PenRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \PenRecord.name
        )
        _reproduction = Query(
            filter: #Predicate<ReproductionRecord> { $0.farmID == farmID && $0.deletedAt == nil },
            sort: \ReproductionRecord.occurredAt,
            order: .reverse
        )
        _offspringRecords = Query(filter: #Predicate<LambingOffspringRecord> { $0.farmID == farmID })
        _weightRecords = Query(filter: #Predicate<WeightRecord> { $0.farmID == farmID && $0.deletedAt == nil })
    }

    private var breedingRams: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.sex == .ram && $0.isBreedingRam } }
    private var farmSemen: [SemenRecord] { semen.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var ramCandidates: [SheepEarTagSearchCandidate] { breedingRams.map { .init(sheep: $0) } }
    private var eligibleBreedings: [ReproductionRecord] { reproduction.filter { breeding in
        breeding.farmID == farm.id && breeding.eweID == record.eweID && breeding.kind == .breeding && breeding.deletedAt == nil && breeding.occurredAt <= occurredAt && !reproduction.contains { closure in
            closure.id != record.id && closure.farmID == farm.id && closure.relatedBreedingRecordID == breeding.id && closure.deletedAt == nil && (closure.kind == .lambing || closure.kind == .abortion)
        }
    } }
    private var linkedBreeding: ReproductionRecord? { relatedBreedingID.flatMap { id in eligibleBreedings.first { $0.id == id } } }
    private var suggestedLambBreed: String {
        LambingEntrySemantics.suggestedLambBreed(
            paternalBreed: lambingPaternalBreed(
                relatedBreeding: linkedBreeding,
                selectedSireID: paternalMode == .breedingRam ? sireID : nil,
                selectedSemenID: paternalMode == .semen ? semenID : nil,
                sheep: sheep,
                semen: semen,
                donors: semenDonors
            ),
            maternalBreed: sheep.first(where: { $0.id == record.eweID })?.breed
        )
    }
    private var priorParity: Int {
        LambingEntrySemantics.priorParityForLambing(
            eweID: record.eweID,
            farmID: farm.id,
            at: occurredAt,
            existingRecordID: record.id,
            records: reproduction
        )
    }
    private var correctedParity: Int { priorParity + 1 }

    var body: some View {
        Form {
            Section("产羔事实") {
                DatePicker("产羔时间", selection: $occurredAt, in: ...Date.now)
                LabeledContent("产羔前胎次", value: parityDisplayName(priorParity))
                LabeledContent("本次产羔胎次", value: parityDisplayName(correctedParity))
                Picker("羔羊圈舍", selection: $penID) {
                    Text("未分圈").tag(UUID?.none)
                    ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            LambCountSection(countText: $lambCountText, deadCount: rows.count(where: \.isStillborn))
            Section("繁殖链") {
                Picker("关联配种", selection: $relatedBreedingID) {
                    Text("保持未关联").tag(UUID?.none)
                    ForEach(eligibleBreedings, id: \.id) { Text("\($0.occurredAt.formatted(date: .abbreviated, time: .omitted)) · \($0.paternalSource.displayName)").tag(UUID?.some($0.id)) }
                }
                if let linkedBreeding { LabeledContent("父本来源", value: linkedBreeding.paternalSource.displayName) }
            }
            if relatedBreedingID == nil {
                Section("父本来源") {
                    Picker("类型", selection: $paternalMode) { ForEach(LambingPaternalMode.allCases) { Text($0.title).tag($0) } }
                    if paternalMode == .breedingRam {
                        SheepEarTagSingleSearchField(
                            candidates: ramCandidates,
                            selection: $sireID,
                            prompt: "输入种公羊耳号搜索",
                            emptySelectionText: "尚未确认种公羊",
                            accessibilityName: "种公羊耳号"
                        )
                    } else if paternalMode == .semen {
                        Picker("冻精", selection: $semenID) { Text("请选择").tag(UUID?.none); ForEach(farmSemen, id: \.id) { Text($0.code).tag(UUID?.some($0.id)) } }
                    }
                }
            }
            ForEach($rows) { $row in
                LambFormSection(
                    row: $row,
                    number: (rows.firstIndex { $0.id == row.id } ?? 0) + 1,
                    lambingAt: occurredAt,
                    canRemove: rows.count > 1,
                    remove: { removeLamb(row.id) }
                )
            }
            Section {
                Button("补录一只羔羊", action: appendLamb)
                    .disabled(rows.count >= LambingFormLimits.maximumLambCount)
            }
            Section("备注") { TextField("备注", text: $note, axis: .vertical) }
            Section("审计") {
                TextField("修正原因（必填）", text: $reason, axis: .vertical)
                Text("移除已建档羔羊不会删除其档案；若系谱已人工修改或存在冲突，保存会被阻断。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("修正产羔记录")
        .toolbar { EntrySaveToolbar(action: save) }
        .recordErrorAlert($errorMessage)
        .onAppear(perform: load)
        .onChange(of: occurredAt) { oldValue, newValue in
            for index in rows.indices {
                guard let weighedAt = rows[index].weightOccurredAt else { continue }
                if weighedAt == oldValue || weighedAt < newValue {
                    rows[index].weightOccurredAt = newValue
                }
            }
            applyBreedSuggestion()
        }
        .onChange(of: lambCountText) { _, value in resizeRows(to: value) }
        .onChange(of: relatedBreedingID) { _, value in
            if value != nil { paternalMode = .unknown; sireID = nil; semenID = nil }
            applyBreedSuggestion()
        }
        .onChange(of: paternalMode) { _, value in
            if value != .breedingRam { sireID = nil }
            if value != .semen { semenID = nil }
            applyBreedSuggestion()
        }
        .onChange(of: sireID) { _, _ in applyBreedSuggestion() }
        .onChange(of: semenID) { _, _ in applyBreedSuggestion() }
    }

    private func load() {
        occurredAt = record.occurredAt
        relatedBreedingID = record.relatedBreedingRecordID
        sireID = record.sireID
        semenID = record.semenID
        paternalMode = record.semenID != nil ? .semen : (record.sireID != nil ? .breedingRam : .unknown)
        note = record.note
        rows = offspringRecords
            .filter { $0.farmID == farm.id && $0.lambingRecordID == record.id && $0.deletedAt == nil }
            .map { detail in
                let child = detail.sheepID.flatMap { sheepID in
                    sheep.first { $0.id == sheepID }
                }
                let linkedWeight = detail.autoBirthWeightRecordID.flatMap { weightID in
                    weightRecords.first { $0.id == weightID && $0.farmID == farm.id && $0.deletedAt == nil }
                }
                let legacyBirthWeight = Decimal.stable(detail.birthWeightText).flatMap { $0 > 0 ? $0.stableText : nil }
                return LambFormRow(
                    id: detail.id,
                    sheepID: detail.sheepID ?? UUID(),
                    earTag: detail.legacyEarTag,
                    breed: child?.breed ?? suggestedLambBreed,
                    breedWasEdited: child != nil,
                    sex: SheepSex(rawValue: detail.sexRawValue) ?? .unknown,
                    weight: linkedWeight?.kilogramsText ?? legacyBirthWeight ?? "",
                    weightOccurredAt: linkedWeight?.occurredAt ?? (legacyBirthWeight == nil ? nil : record.occurredAt),
                    createRecord: detail.sheepID != nil,
                    isStillborn: detail.isStillborn
                )
            }
        let initialCount = max(rows.count, record.lambCount, 1)
        if initialCount > rows.count {
            rows.append(contentsOf: (rows.count..<initialCount).map { _ in LambFormRow(breed: suggestedLambBreed) })
        }
        lambCountText = "\(rows.count)"
    }

    private func appendLamb() {
        guard rows.count < LambingFormLimits.maximumLambCount else { return }
        rows.append(LambFormRow(breed: suggestedLambBreed))
        lambCountText = "\(rows.count)"
    }

    private func removeLamb(_ id: UUID) {
        rows.removeAll { $0.id == id }
        lambCountText = "\(rows.count)"
    }

    private func resizeRows(to text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(normalized), (1...LambingFormLimits.maximumLambCount).contains(count) else { return }
        if count > rows.count {
            rows.append(contentsOf: (rows.count..<count).map { _ in LambFormRow(breed: suggestedLambBreed) })
        } else if count < rows.count {
            rows.removeLast(rows.count - count)
        }
    }

    private func applyBreedSuggestion() {
        let suggestion = suggestedLambBreed
        for index in rows.indices {
            rows[index].breed = LambingEntrySemantics.breedAfterApplyingSuggestion(
                currentBreed: rows[index].breed,
                suggestedBreed: suggestion,
                userOverrodeSuggestion: rows[index].breedWasEdited
            )
        }
    }

    private func save() {
        let normalizedCount = lambCountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intendedCount = Int(normalizedCount),
              (1...LambingFormLimits.maximumLambCount).contains(intendedCount),
              intendedCount == rows.count else {
            errorMessage = "产羔总数必须是 1 到 \(LambingFormLimits.maximumLambCount) 的整数。"
            return
        }
        let lambs = rows.map {
            CareLambDraft(
                id: $0.id,
                sheepID: $0.sheepID,
                earTag: $0.earTag,
                breed: $0.breed,
                sex: $0.sex,
                birthWeightText: $0.weight,
                weightOccurredAt: $0.weightOccurredAt,
                createSheepRecord: $0.isStillborn ? false : $0.createRecord,
                isStillborn: $0.isStillborn
            )
        }
        let draft = CareLambingDraft(
            id: record.id,
            eweID: record.eweID,
            occurredAt: occurredAt,
            sireID: relatedBreedingID == nil && paternalMode == .breedingRam ? sireID : nil,
            semenID: relatedBreedingID == nil && paternalMode == .semen ? semenID : nil,
            relatedBreedingRecordID: relatedBreedingID,
            parity: correctedParity,
            birthDeadCount: lambs.count(where: \.isStillborn),
            offspring: lambs,
            penID: penID,
            note: note
        )
        do {
            try service.execute(.care(.correctLambing(originalID: record.id, replacement: draft, reason: reason)), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: modelContext)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private func catalogMatches(_ item: HealthCatalogItemRecord, kind: HealthRecordKind) -> Bool {
    let raw = item.kindRawValue.lowercased()
    return kind == .vaccination ? ["vaccination", "vaccine"].contains(raw) : ["treatment", "medicine", "disease"].contains(raw)
}

private func catalogHealthKind(_ item: HealthCatalogItemRecord) -> HealthRecordKind {
    ["vaccination", "vaccine"].contains(item.kindRawValue.lowercased()) ? .vaccination : .treatment
}
