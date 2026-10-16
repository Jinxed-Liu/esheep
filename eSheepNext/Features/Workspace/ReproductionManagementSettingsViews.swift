import SwiftData
import SwiftUI

struct ReproductionScopeSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel
    let initial: ReproductionManagementResult
    // Intentional editor snapshots. The save service detects concurrent changes.
    @State private var draft: ReproductionManagementSettings
    @State private var sourceSettings: ReproductionManagementSettings?
    @State private var selected: Set<UUID>
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, dataStore: FarmDeepAnalyticsStore,
         model: ReproductionManagementModel, initial: ReproductionManagementResult) {
        self.account = account; self.farm = farm; self.dataStore = dataStore; self.model = model; self.initial = initial
        _draft = State(initialValue: initial.settings)
        _sourceSettings = State(initialValue: initial.sourceSettings)
        _selected = State(initialValue: Set(initial.settings.selectedPenIDs))
    }
    private var canManage: Bool { CapabilitySet(role: farm.role).allows(.manageCatalogs) }
    private var pens: [ReproductionManagementPen] { model.result?.occupiedPens ?? initial.occupiedPens }

    var body: some View {
        Form {
            Section {
                Text("仅显示当前有在群羊只的启用圈舍。按用途批量勾选，也可以逐舍选择。")
                Text("清空的羊舍自动隐藏并保留原选择，重新有羊后恢复参与；新增羊舍需要另行勾选。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !canManage { Label("只有牧场主或管理员可以修改设置。", systemImage: "lock") }
            }
            ForEach(ReproductionPenUsage.allCases.filter { usage in pens.contains { draft.usage(for: $0.id) == usage } }) { usage in
                let group = pens.filter { draft.usage(for: $0.id) == usage }
                    Section {
                        Button(selected.isSuperset(of: Set(group.map(\.id))) ? "取消本组选择" : "选择本组有羊圈舍") {
                            let ids = Set(group.map(\.id))
                            if selected.isSuperset(of: ids) { selected.subtract(ids) } else { selected.formUnion(ids) }
                        }.disabled(!canManage)
                        ForEach(group) { pen in
                            VStack(alignment: .leading, spacing: 6) {
                                ReproductionSelectionRow(isSelected: selected.contains(pen.id), action: {
                                    if selected.contains(pen.id) { selected.remove(pen.id) } else { selected.insert(pen.id) }
                                }) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: pen.name)
                                        Text("在群 \(pen.sheepCount) 只 · 母羊 \(pen.eweCount) 只")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                }.accessibilityIdentifier("reproduction-select-pen-\(pen.name)")
                                Picker("羊舍用途", selection: Binding(get: { draft.usage(for: pen.id) }, set: { draft.setUsage($0, for: pen.id) })) {
                                    ForEach(ReproductionPenUsage.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                                }.pickerStyle(.menu)
                            }.disabled(!canManage)
                        }
                    } header: { Text(verbatim: usage.rawValue) }
            }
            if pens.isEmpty { ContentUnavailableView("暂无有羊圈舍", systemImage: "house", description: Text("空舍不显示在选择列表中。")) }
            if let result = model.result, !result.inactiveOccupiedPens.isEmpty {
                Section("已停用且仍有羊") {
                    ForEach(result.inactiveOccupiedPens) { pen in
                        Text("\(pen.name) · \(pen.sheepCount) 只，需先处理圈舍异常。")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("羊舍用途与参与范围").navigationBarTitleDisplayMode(.inline)
        .toolbar { if canManage { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).accessibilityIdentifier("reproduction-save-scope") } } }
        .recordErrorAlert($errorMessage)
        .accessibilityIdentifier("reproduction-scope-settings")
        .reproductionData(farm: farm, dataStore: dataStore, model: model)
    }

    private func save() {
        do {
            draft.selectedPenIDs = Array(selected)
            draft.scopeConfigured = true
            try ReproductionManagementSettingsService.save(draft, expected: sourceSettings,
                accountID: account.effectiveAccountID, farm: farm, context: context)
            Task { await dataStore.load(container: context.container, farmID: farm.id, force: true) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ReproductionReadinessSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel
    let initial: ReproductionManagementResult
    @State private var confirmed: Set<UUID>
    @State private var sourceSettings: ReproductionManagementSettings?
    @State private var searchText = ""
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, dataStore: FarmDeepAnalyticsStore,
         model: ReproductionManagementModel, initial: ReproductionManagementResult) {
        self.account = account; self.farm = farm; self.dataStore = dataStore; self.model = model; self.initial = initial
        _confirmed = State(initialValue: Set(initial.settings.youthBreedingConfirmedSheepIDs))
        _sourceSettings = State(initialValue: initial.sourceSettings)
    }
    private var canManage: Bool { CapabilitySet(role: farm.role).allows(.manageCatalogs) }
    private var candidates: [ReproductionManagementEwe] {
        (model.result?.ewes ?? initial.ewes).filter {
            $0.isConfirmedMaiden && (searchText.isEmpty || $0.earTag.localizedCaseInsensitiveContains(searchText))
        }
    }
    var body: some View {
        List {
            Section {
                Text("青年母羊＝未产羔＋超过参配月龄＋人工确认可参配。")
                Text("勾选表示你已人工复核参配条件。系统只按月龄筛选，不能代替人工确认。青孕羊是青年母羊中经检胎确认怀孕的羊。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !initial.settings.scopeConfigured { Text("请先设置参与分析的羊舍。").foregroundStyle(.orange) }
            }
            Section("未产羔母羊 · \(candidates.count) 只") {
                ForEach(candidates) { ewe in
                    ReproductionSelectionRow(isSelected: confirmed.contains(ewe.id), action: {
                        if confirmed.contains(ewe.id) { confirmed.remove(ewe.id) } else { confirmed.insert(ewe.id) }
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: ewe.earTag).font(.headline)
                            Text(verbatim: "\(ewe.penName) · \(ewe.ageMonths.map { "\($0)月龄" } ?? "月龄待核实") · \(ewe.pregnancy.rawValue)")
                                .font(.footnote).foregroundStyle(.secondary)
                            if !ewe.isCheckEligible {
                                Text(ewe.ageMonths == nil ? "缺少出生日期，暂不能确认参配。" : "尚未超过参配月龄，暂不能确认。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .disabled(!canManage || !ewe.isCheckEligible && !confirmed.contains(ewe.id))
                    .accessibilityIdentifier("reproduction-readiness-\(ewe.earTag)")
                }
                if candidates.isEmpty { Text("当前范围没有可核对的未产羔母羊。") }
            }
        }
        .navigationTitle("青年母羊参配确认").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索母羊耳号")
        .toolbar { if canManage { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).accessibilityIdentifier("reproduction-save-readiness") } } }
        .recordErrorAlert($errorMessage)
        .reproductionData(farm: farm, dataStore: dataStore, model: model)
    }
    private func save() {
        do {
            var settings = sourceSettings ?? .init()
            settings.youthBreedingConfirmedSheepIDs = Array(confirmed)
            try ReproductionManagementSettingsService.save(settings, expected: sourceSettings,
                accountID: account.effectiveAccountID, farm: farm, context: context)
            Task { await dataStore.load(container: context.container, farmID: farm.id, force: true) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ReproductionSelectionRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(isSelected ? AppTheme.brand : Color.secondary)
                content().foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "已勾选" : "未勾选")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ReproductionRuleSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel
    let initial: ReproductionManagementResult
    @State private var minimumAgeMonths: Int
    @State private var sourceSettings: ReproductionManagementSettings?
    @State private var postpartumEnabled: Bool
    @State private var postpartumReminder: String
    @State private var postpartumWarning: String
    @State private var youngEnabled: Bool
    @State private var youngReminder: String
    @State private var youngWarning: String
    @State private var errorMessage: String?

    init(account: AccountProfile, farm: FarmRecord, dataStore: FarmDeepAnalyticsStore,
         model: ReproductionManagementModel, initial: ReproductionManagementResult) {
        self.account = account; self.farm = farm; self.dataStore = dataStore; self.model = model; self.initial = initial
        let settings = initial.settings
        _sourceSettings = State(initialValue: initial.sourceSettings)
        _minimumAgeMonths = State(initialValue: settings.minimumAgeMonths)
        _postpartumEnabled = State(initialValue: settings.hasPostpartumRule)
        _postpartumReminder = State(initialValue: settings.postpartumReminderDays.map(String.init) ?? "")
        _postpartumWarning = State(initialValue: settings.postpartumWarningDays.map(String.init) ?? "")
        _youngEnabled = State(initialValue: settings.hasMaidenRule)
        _youngReminder = State(initialValue: settings.maidenReminderMonths.map(String.init) ?? "")
        _youngWarning = State(initialValue: settings.maidenWarningMonths.map(String.init) ?? "")
    }
    private var canManage: Bool { CapabilitySet(role: farm.role).allows(.manageCatalogs) }
    var body: some View {
        Form {
            Section {
                Stepper("参配与检胎统计月龄：超过 \(minimumAgeMonths) 月龄", value: $minimumAgeMonths, in: 1...120)
            } header: { Text("青年母羊判定") } footer: {
                Text("未产羔母羊须超过此月龄并经人工确认，才归为青年母羊。未确认者单列待确认参配；头胎是1胎，经产是≥2胎。")
            }
            Section {
                Toggle("启用产后未检胎规则", isOn: $postpartumEnabled)
                if postpartumEnabled {
                    numberField("提醒天数", text: $postpartumReminder)
                    numberField("警告天数", text: $postpartumWarning)
                }
            } header: { Text("产后未检胎") } footer: {
                Text("首次由你填写，警告须大于提醒。大于210天仅是统计分组，不自动触发警告。")
            }
            Section {
                Toggle("启用青年母羊未检胎规则", isOn: $youngEnabled)
                if youngEnabled {
                    numberField("提醒月龄", text: $youngReminder)
                    numberField("警告月龄", text: $youngWarning)
                }
            } header: { Text("青年母羊超月龄未检胎") } footer: {
                Text("只对已人工确认可参配的青年母羊生效。提醒月龄不得早于参配月龄，警告须大于提醒。")
            }
            Section {
                if let rule = model.result?.careRule, rule.operationalRulesConfigured {
                    LabeledContent("配种后检胎", value: "\(rule.pregnancyCheckDays) 天")
                    LabeledContent("提前预警", value: "\(rule.warningLeadDays) 天")
                } else { Text("配种后检胎规则尚未启用。") }
                NavigationLink("配种后检胎与每日汇总设置") { FarmOperationalAlertRulesView(account: account, farm: farm) }
            } header: { Text("现有提醒设置") } footer: {
                Text("通知沿用已有开关与汇总时间。未检胎不等于空怀；复检和结果不清分别列出。")
            }
            if !canManage { Section { Label("只有牧场主或管理员可以修改规则。", systemImage: "lock") } }
        }
        .disabled(!canManage)
        .navigationTitle("繁殖提醒规则").navigationBarTitleDisplayMode(.inline)
        .toolbar { if canManage { ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).accessibilityIdentifier("reproduction-save-rules") } } }
        .recordErrorAlert($errorMessage)
        .reproductionData(farm: farm, dataStore: dataStore, model: model)
    }
    private func numberField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer()
            TextField("请填写", text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                .frame(maxWidth: 120).accessibilityLabel(Text(verbatim: title))
        }
    }
    private func positiveInteger(_ text: String, label: String) throws -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            throw FarmCommandError.invalidNumber(label)
        }
        return value
    }
    private func save() {
        do {
            var settings = sourceSettings ?? .init()
            settings.minimumAgeMonths = minimumAgeMonths
            settings.postpartumReminderDays = postpartumEnabled ? try positiveInteger(postpartumReminder, label: "产后提醒天数") : nil
            settings.postpartumWarningDays = postpartumEnabled ? try positiveInteger(postpartumWarning, label: "产后警告天数") : nil
            settings.maidenReminderMonths = youngEnabled ? try positiveInteger(youngReminder, label: "青年母羊提醒月龄") : nil
            settings.maidenWarningMonths = youngEnabled ? try positiveInteger(youngWarning, label: "青年母羊警告月龄") : nil
            try ReproductionManagementSettingsService.save(settings, expected: sourceSettings,
                accountID: account.effectiveAccountID, farm: farm, context: context)
            Task { await dataStore.load(container: context.container, farmID: farm.id, force: true) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
