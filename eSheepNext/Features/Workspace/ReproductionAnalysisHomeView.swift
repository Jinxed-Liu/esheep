import Combine
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class ReproductionManagementModel {
    private(set) var result: ReproductionManagementResult?
    private(set) var isCalculating = false
    private(set) var error: String?
    private var revision: UUID?
    private var calculation: Task<Void, Never>?

    func calculate(snapshot: FarmAnalyticsSnapshot, revision: UUID) async {
        if self.revision == revision {
            await calculation?.value
            return
        }
        self.revision = revision
        calculation?.cancel()
        isCalculating = true
        error = nil
        calculation = Task {
            let work = Task.detached(priority: .userInitiated) {
                try ReproductionManagementEngine.calculate(snapshot: snapshot)
            }
            do {
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard self.revision == revision else { return }
                result = value
                isCalculating = false
            } catch {
                guard self.revision == revision else { return }
                isCalculating = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
        await calculation?.value
    }
}

private struct ReproductionDataRefresh: ViewModifier {
    @Environment(\.modelContext) private var context
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel

    func body(content: Content) -> some View {
        content
            .task(id: dataStore.revision) {
                await dataStore.load(container: context.container, farmID: farm.id)
                guard !Task.isCancelled, let snapshot = dataStore.payload?.snapshot else { return }
                await model.calculate(snapshot: snapshot, revision: dataStore.revision)
            }
            .refreshable { await dataStore.load(container: context.container, farmID: farm.id, force: true) }
            .environment(\.timeZone, TimeZone(identifier: farm.timeZoneIdentifier) ?? .current)
    }
}

extension View {
    func reproductionData(farm: FarmRecord, dataStore: FarmDeepAnalyticsStore, model: ReproductionManagementModel) -> some View {
        modifier(ReproductionDataRefresh(farm: farm, dataStore: dataStore, model: model))
    }
}

struct ReproductionAnalysisHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    @State private var model = ReproductionManagementModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                summary
                currentNavigation
                historyNavigation
                settingsNavigation
                ReproductionDataStatusView(model: model, dataStore: dataStore)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .safeAreaPadding(.bottom, 32)
        }
        .background(AppTheme.pageBackground)
        .navigationTitle("繁殖分析")
        .accessibilityIdentifier("reproduction-home")
        .reproductionData(farm: farm, dataStore: dataStore, model: model)
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).debounce(for: .milliseconds(350), scheduler: RunLoop.main)) { _ in
            Task { await dataStore.load(container: context.container, farmID: farm.id, force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: FarmOperationalAlertRuntimeNotification.refreshRequested)) { notification in
            guard FarmOperationalAlertRuntimeNotification.farmID(from: notification) == farm.id else { return }
            Task { await dataStore.load(container: context.container, farmID: farm.id, force: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await dataStore.load(container: context.container, farmID: farm.id, force: true) } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: farm.name).font(.headline)
            if let result = model.result {
                Text("统计于 \(result.asOf.formatted(date: .abbreviated, time: .shortened)) · 参与羊舍 \(result.effectivePenCount) 个")
                    .font(.footnote).foregroundStyle(.secondary)
                if !result.settings.scopeConfigured {
                    NavigationLink("先设置羊舍用途与参与范围") { scopeSettings(result) }
                        .font(.subheadline.weight(.medium))
                }
            } else { ProgressView("正在读取繁殖资料") }
        }
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            summaryTile("范围内母羊", symbol: "pawprint", value: model.result?.ewes.count, filter: .all, tint: .blue)
            summaryTile("检胎已孕", symbol: "heart.fill", value: model.result?.count(.pregnant), filter: .pregnancy(.pregnant), tint: .pink)
            summaryTile("未检胎", symbol: "heart.text.square", value: model.result?.count(.unexamined), filter: .pregnancy(.unexamined), tint: .orange)
            summaryTile("需处理", symbol: "exclamationmark.triangle", value: model.result?.attention.count, filter: .attention, tint: .red,
                requiresRules: true)
        }
    }

    private func summaryTile(_ title: String, symbol: String, value: Int?, filter: ReproductionEweFilter, tint: Color, requiresRules: Bool = false) -> some View {
        let ready = model.result?.settings.scopeConfigured == true && (!requiresRules || model.result?.remindersConfigured == true)
        return NavigationLink {
            ReproductionEweListView(account: account, farm: farm, dataStore: dataStore, model: model, title: title, filter: filter)
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                Label(LocalizedStringKey(title), systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: value == nil ? "—" : ready ? String(value!) : "待设置")
                        .font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                    if ready { Text("只").font(.footnote).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reproduction-summary-\(filter.identifier)")
    }

    private var currentNavigation: some View {
        SettingsCard(title: "当前管理") {
            SettingsNavigationRow(title: "羊舍繁殖概览", subtitle: "按用途查看羊舍、母羊与检胎状态", systemImage: "house", iconColor: .blue) {
                ReproductionPenOverviewView(account: account, farm: farm, dataStore: dataStore, model: model)
            }.accessibilityIdentifier("reproduction-pens-entry")
            SettingsCardDivider()
            SettingsNavigationRow(title: "繁殖阶段与检胎", subtitle: "产后分组、青年母羊、头胎与经产母羊", systemImage: "chart.bar.xaxis", iconColor: .pink) {
                ReproductionStagesView(account: account, farm: farm, dataStore: dataStore, model: model)
            }.accessibilityIdentifier("reproduction-stages-entry")
            SettingsCardDivider()
            SettingsNavigationRow(title: "提醒与警告", subtitle: "未检胎、待复检及繁殖资料待核实", systemImage: "exclamationmark.triangle", iconColor: .orange) {
                ReproductionEweListView(account: account, farm: farm, dataStore: dataStore, model: model, title: "提醒与警告", filter: .attention)
            }.accessibilityIdentifier("reproduction-alerts-entry")
        }
    }

    private var historyNavigation: some View {
        SettingsCard(title: "历史表现") {
            SettingsNavigationRow(title: "繁殖节律", subtitle: "胎间距、合格率与产后天数趋势", systemImage: "chart.line.uptrend.xyaxis", iconColor: .blue) {
                ReproductionHistoryAnalysisView(farm: farm, dataStore: dataStore, mode: .rhythm)
            }.accessibilityIdentifier("reproduction-rhythm-entry")
            SettingsCardDivider()
            SettingsNavigationRow(title: "产羔与品种表现", subtitle: "胎均产羔、初生重与月度品种对比", systemImage: "figure.and.child.holdinghands", iconColor: .pink) {
                ReproductionHistoryAnalysisView(farm: farm, dataStore: dataStore, mode: .production)
            }.accessibilityIdentifier("reproduction-production-entry")
            SettingsCardDivider()
            SettingsNavigationRow(title: "母羊表现与关注名单", subtitle: "产后久留、零胎久留、单羔与总体评价", systemImage: "list.bullet.clipboard", iconColor: .purple) {
                PenReproductionAnalysisView(farm: farm, dataStore: dataStore)
            }.accessibilityIdentifier("reproduction-performance-entry")
        }
    }

    private var settingsNavigation: some View {
        SettingsCard(title: "管理设置") {
            SettingsNavigationRow(title: "羊舍用途与参与范围", subtitle: "只列有羊圈舍，按用途或单舍勾选", systemImage: "checklist", iconColor: .green) {
                if let result = model.result { scopeSettings(result) }
            }.accessibilityIdentifier("reproduction-scope-entry").disabled(model.result == nil)
            SettingsCardDivider()
            SettingsNavigationRow(title: "青年母羊参配确认", subtitle: "达到参配月龄后，由人工确认可参配", systemImage: "checkmark.person", iconColor: .teal) {
                if let result = model.result {
                    ReproductionReadinessSettingsView(account: account, farm: farm, dataStore: dataStore, model: model, initial: result)
                }
            }.accessibilityIdentifier("reproduction-readiness-entry").disabled(model.result == nil)
            SettingsCardDivider()
            SettingsNavigationRow(title: "繁殖提醒规则", subtitle: "设置参配月龄、检胎提醒与警告门槛", systemImage: "slider.horizontal.3", iconColor: .orange) {
                if let result = model.result {
                    ReproductionRuleSettingsView(account: account, farm: farm, dataStore: dataStore, model: model, initial: result)
                }
            }.accessibilityIdentifier("reproduction-rules-entry").disabled(model.result == nil)
        }
    }

    private func scopeSettings(_ result: ReproductionManagementResult) -> some View {
        ReproductionScopeSettingsView(account: account, farm: farm, dataStore: dataStore, model: model, initial: result)
    }
}

struct ReproductionDataStatusView: View {
    let model: ReproductionManagementModel
    let dataStore: FarmDeepAnalyticsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let error = dataStore.errorMessage ?? model.error {
                Label("读取失败：\(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                if model.result != nil { Text("当前保留上次读取的结果，下拉可重试。") }
            } else if model.isCalculating || dataStore.isLoading {
                ProgressView("正在更新繁殖统计")
            }
            Text("依据本机已加载资料；云端资料更新后重新计算。")
            if let status = dataStore.payload?.reproductionSyncStatus { Text(verbatim: status) }
        }
        .font(.footnote).foregroundStyle(.secondary)
    }
}

enum ReproductionEweFilter: Hashable {
    case all, attention, youngPregnant
    case youngPregnantInPen(UUID?)
    case pregnancy(ReproductionPregnancyState)
    case category(ReproductionEweCategory, penID: UUID? = nil)
    case pen(UUID)
    case stage(String, penID: UUID? = nil)
    var identifier: String {
        switch self {
        case .all: "all"
        case .attention: "attention"
        case .youngPregnant: "young-pregnant"
        case .youngPregnantInPen: "young-pregnant"
        case .pregnancy(let state): state.id
        case .category(let category, _): category.id
        case .pen(let id): id.uuidString
        case .stage(let id, _): id
        }
    }
    func matches(_ ewe: ReproductionManagementEwe) -> Bool {
        switch self {
        case .all: true
        case .attention: !ewe.concerns.isEmpty
        case .youngPregnant: ewe.isYoungPregnant
        case .youngPregnantInPen(let penID): ewe.isYoungPregnant && (penID == nil || ewe.penID == penID)
        case .pregnancy(let state): ewe.isCheckEligible && ewe.pregnancy == state
        case .category(let category, let penID): ewe.category == category && (penID == nil || ewe.penID == penID)
        case .pen(let id): ewe.penID == id
        case .stage(let id, let penID): ewe.stageID == id && (penID == nil || ewe.penID == penID)
        }
    }
}

struct ReproductionEweListView: View {
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel
    let title: String
    let filter: ReproductionEweFilter
    @State private var searchText = ""
    @State private var pregnancy: ReproductionPregnancyState?
    @State private var category: ReproductionEweCategory?

    private var rows: [ReproductionManagementEwe] {
        let candidates = filter == .attention ? model.result?.attention : model.result?.ewes
        return (candidates ?? []).filter { ewe in
            filter.matches(ewe) && (pregnancy == nil || ewe.isCheckEligible && ewe.pregnancy == pregnancy) &&
            (category == nil || ewe.category == category) &&
            (searchText.isEmpty || ewe.earTag.localizedCaseInsensitiveContains(searchText) || ewe.penName.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        List {
            Section {
                ReproductionDataStatusView(model: model, dataStore: dataStore)
                if model.result?.settings.scopeConfigured != true { Text("请先设置参与分析的羊舍。") }
                if filter == .attention {
                    Text("同一只羊合并显示全部原因，按最高严重程度排序。暂缓提醒不改变这里的业务事实。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("打开提醒与异常，可暂缓提醒") { FarmOperationalAlertCenterView(account: account, farm: farm) }
                }
            }
            Section("母羊 · \(rows.count) 只") {
                ForEach(rows) { ewe in
                    NavigationLink {
                        ReproductionEweEvidenceView(account: account, farm: farm, dataStore: dataStore, model: model, sheepID: ewe.id)
                    } label: { ReproductionEweRow(ewe: ewe) }
                    .accessibilityIdentifier("reproduction-ewe-\(ewe.earTag)")
                }
                if rows.isEmpty && model.result != nil {
                    ContentUnavailableView("暂无符合条件的母羊", systemImage: "line.3.horizontal.decrease", description: Text("可调整筛选或核对参与羊舍。"))
                }
            }
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索耳号或羊舍")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("检胎状态", selection: $pregnancy) {
                        Text("全部检胎状态").tag(ReproductionPregnancyState?.none)
                        ForEach(ReproductionPregnancyState.allCases) { Text(verbatim: $0.rawValue).tag(Optional($0)) }
                    }
                    Picker("母羊类别", selection: $category) {
                        Text("全部母羊类别").tag(ReproductionEweCategory?.none)
                        ForEach(ReproductionEweCategory.allCases) { Text(verbatim: $0.rawValue).tag(Optional($0)) }
                    }
                } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                .accessibilityIdentifier("reproduction-ewe-filters")
            }
        }
        .reproductionData(farm: farm, dataStore: dataStore, model: model)
    }
}

struct ReproductionEweRow: View {
    let ewe: ReproductionManagementEwe
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: ewe.earTag).font(.headline)
                Spacer()
                if let severity = ewe.severity {
                    Text(verbatim: severity.title).font(.caption.weight(.semibold)).foregroundStyle(reproductionSeverityColor(severity))
                }
            }
            Text(verbatim: "\(ewe.penName) · \(ewe.category.rawValue)\(ewe.isYoungPregnant ? " · 青孕羊" : "")")
                .font(.subheadline)
            Text(verbatim: [ewe.parity.map { "当前\($0)胎" } ?? "胎次待核实",
                ewe.postpartumDays.map { "产后\($0)天" } ?? ewe.ageMonths.map { "\($0)月龄" } ?? "月龄待核实",
                ewe.pregnancy.rawValue].joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
            if let checkAt = ewe.checkAt {
                Text("最近检胎 \(checkAt.formatted(date: .abbreviated, time: .omitted)) · \(ewe.checkResult ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !ewe.concerns.isEmpty {
                Text(verbatim: ewe.concerns.map(\.detail).joined(separator: "；"))
                    .font(.footnote).foregroundStyle(reproductionSeverityColor(ewe.severity ?? .review))
            }
        }
        .padding(.vertical, 4)
    }
}

func reproductionSeverityColor(_ severity: ReproductionConcernSeverity) -> Color {
    switch severity {
    case .review: .secondary
    case .reminder: .orange
    case .warning: .red
    }
}

struct ReproductionStagesView: View {
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel
    var penID: UUID?
    var title = "繁殖阶段与检胎"

    private var ewes: [ReproductionManagementEwe] { (model.result?.ewes ?? []).filter { penID == nil || $0.penID == penID } }

    var body: some View {
        List {
            Section {
                ReproductionDataStatusView(model: model, dataStore: dataStore)
                if let result = model.result {
                    Text("母羊 \(ewes.count) 只 · 检胎统计范围 \(ewes.count(where: \.isCheckEligible)) 只")
                    Text("青年母羊须超过 \(result.settings.minimumAgeMonths) 月龄并经人工确认可参配；头胎为1胎，经产为≥2胎。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("母羊类别") {
                ForEach(ReproductionEweCategory.allCases) { category in
                    NavigationLink {
                        eweList(category.rawValue, filter: .category(category, penID: penID))
                    } label: { countRow(category.rawValue, count: ewes.count { $0.category == category }) }
                }
                NavigationLink {
                    // Pen detail needs the intersection, so use an explicit current-pen filter in its list below.
                    ReproductionYoungPregnantListView(account: account, farm: farm, dataStore: dataStore, model: model, penID: penID)
                } label: { countRow("其中青孕羊", count: ewes.count(where: \.isYoungPregnant)) }
            }
            if let result = model.result {
                Section {
                    ForEach(result.stages(penID: penID).filter { $0.id.hasPrefix("postpartum-") }) { stage in
                        stageLink(stage)
                    }
                } header: { Text("产后分组") } footer: {
                    Text("产羔当天计0天；210天归入181–210天，211天起统一归入大于210天。名单保留实际天数。")
                }
                let others = result.stages(penID: penID).filter { !$0.id.hasPrefix("postpartum-") }
                if !others.isEmpty {
                    Section("月龄与资料分组") { ForEach(others) { stageLink($0) } }
                }
            }
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("reproduction-stages")
        .reproductionData(farm: farm, dataStore: dataStore, model: model)
    }

    private func stageLink(_ stage: ReproductionManagementStage) -> some View {
        NavigationLink {
            eweList(stage.title, filter: .stage(stage.id, penID: penID))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                countRow(stage.title, count: stage.ewes.count)
                if stage.eligibleCount > 0 {
                    Text(verbatim: "已孕 \(stage.count(.pregnant)) · 空怀 \(stage.count(.open)) · 未检 \(stage.count(.unexamined)) · 复检 \(stage.count(.recheck)) · 待核实 \(stage.count(.uncertain))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 3)
        }
        .accessibilityIdentifier("reproduction-stage-\(stage.id)")
    }
    private func countRow(_ title: String, count: Int) -> some View {
        HStack { Text(verbatim: title); Spacer(); Text("\(count) 只").monospacedDigit().foregroundStyle(.secondary) }
    }
    private func eweList(_ title: String, filter: ReproductionEweFilter) -> some View {
        ReproductionEweListView(account: account, farm: farm, dataStore: dataStore, model: model, title: title, filter: filter)
    }
}

private struct ReproductionYoungPregnantListView: View {
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel
    let penID: UUID?
    var body: some View {
        ReproductionEweListView(account: account, farm: farm, dataStore: dataStore, model: model, title: "青孕羊", filter: .youngPregnantInPen(penID))
    }
}

struct ReproductionPenOverviewView: View {
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel
    var body: some View {
        List {
            Section { ReproductionDataStatusView(model: model, dataStore: dataStore) }
            if let result = model.result {
                ForEach(ReproductionPenUsage.allCases.filter { usage in result.occupiedPens.contains { $0.isSelected && $0.usage == usage } }) { usage in
                    let pens = result.occupiedPens.filter { $0.isSelected && $0.usage == usage }
                        Section(usage.rawValue) {
                            ForEach(pens) { pen in
                                NavigationLink {
                                    ReproductionStagesView(account: account, farm: farm, dataStore: dataStore, model: model, penID: pen.id, title: pen.name)
                                } label: { penRow(pen, result: result) }
                                .accessibilityIdentifier("reproduction-pen-\(pen.id)")
                            }
                        }
                }
                if result.effectivePenCount == 0 {
                    ContentUnavailableView("暂无参与统计的有羊圈舍", systemImage: "house", description: Text("请先勾选参与羊舍；空舍会自动隐藏。"))
                }
                if !result.inactiveOccupiedPens.isEmpty {
                    Section("圈舍异常") {
                        ForEach(result.inactiveOccupiedPens) { pen in
                            Label("\(pen.name)已停用，仍有\(pen.sheepCount)只羊，未计入繁殖范围。", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("羊舍繁殖概览").navigationBarTitleDisplayMode(.inline)
        .reproductionData(farm: farm, dataStore: dataStore, model: model)
    }
    private func penRow(_ pen: ReproductionManagementPen, result: ReproductionManagementResult) -> some View {
        let ewes = result.ewes.filter { $0.penID == pen.id }
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: pen.name).font(.headline)
            Text("在群 \(pen.sheepCount) 只 · 母羊 \(pen.eweCount) 只")
            Text("青年 \(ewes.count { $0.category == .young }) · 头胎 \(ewes.count { $0.category == .firstParity }) · 经产 \(ewes.count { $0.category == .multiparous }) · 青孕 \(ewes.count(where: \.isYoungPregnant))")
                .font(.footnote).foregroundStyle(.secondary)
            Text("检胎已孕 \(ewes.count { $0.isCheckEligible && $0.pregnancy == .pregnant }) · 未检胎 \(ewes.count { $0.isCheckEligible && $0.pregnancy == .unexamined }) · 需处理 \(ewes.count { !$0.concerns.isEmpty })")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

struct ReproductionEweEvidenceView: View {
    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    let model: ReproductionManagementModel
    let sheepID: UUID
    var body: some View {
        List {
            if let ewe = model.result?.ewes.first(where: { $0.id == sheepID }) {
                Section("繁殖状态") {
                    ReproductionEweRow(ewe: ewe)
                    if let birth = ewe.lastLambingAt { LabeledContent("最近产羔", value: birth.formatted(date: .abbreviated, time: .omitted)) }
                    if let postpartum = ewe.postpartumDays {
                        LabeledContent("实际产后天数", value: "\(postpartum) 天")
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("实际产后天数")
                            .accessibilityIdentifier("reproduction-actual-postpartum")
                            .accessibilityValue("\(postpartum) 天")
                    }
                    LabeledContent("统计分组", value: ewe.stageTitle)
                    if !ewe.isCheckEligible { Text("尚未达到检胎统计月龄；已有检查结果保留供核对，不计入检胎覆盖率。").font(.footnote) }
                }
                Section("检胎依据") {
                    LabeledContent("本轮状态", value: ewe.pregnancy.rawValue)
                    if let check = ewe.checkAt {
                        LabeledContent("最近有效检胎", value: check.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("原始结果", value: ewe.checkResult ?? "")
                    } else if let historical = ewe.historicalCheckAt {
                        Text("历史检胎于 \(historical.formatted(date: .abbreviated, time: .omitted))，不能代表本轮状态。")
                    } else { Text("本轮没有检胎记录，不能据此判断空怀。") }
                }
                Section("操作") {
                    NavigationLink("查看羊只详情与完整历史") { SheepDetailEntryView(account: account, farm: farm, sheepID: ewe.id) }
                    if CapabilitySet(role: farm.role).allows(.recordProduction) {
                        NavigationLink("记录检胎结果") {
                            ReproductionBatchEntryView(account: account, farm: farm, initialKind: .pregnancyCheck,
                                initialEweID: ewe.id, initialRelatedBreedingID: ewe.relatedBreedingID)
                        }
                    }
                    if ewe.isConfirmedMaiden, let result = model.result {
                        NavigationLink("青年母羊参配确认") {
                            ReproductionReadinessSettingsView(account: account, farm: farm, dataStore: dataStore, model: model, initial: result)
                        }
                    }
                }
            } else {
                ContentUnavailableView("该羊已不在当前分析范围", systemImage: "arrow.triangle.2.circlepath", description: Text("可能已转舍、离场或参与范围已更新。"))
            }
        }
        .navigationTitle("母羊繁殖依据").navigationBarTitleDisplayMode(.inline)
        .reproductionData(farm: farm, dataStore: dataStore, model: model)
    }
}
