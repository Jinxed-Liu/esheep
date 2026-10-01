import Charts
import ESMotion
import SwiftData
import SwiftUI

struct FarmAnalysisCenterView: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let assistantTransition: Namespace.ID
    let assistantTransitionID: MotionTransitionID
    let assistantTransitionSpec: MotionTransitionSpec
    let onAskAssistant: (String?) -> Void
    @State private var deepAnalytics = FarmDeepAnalyticsStore()

    init(
        account: AccountProfile,
        farm: FarmRecord,
        assistantTransition: Namespace.ID,
        assistantTransitionID: MotionTransitionID,
        assistantTransitionSpec: MotionTransitionSpec,
        onAskAssistant: @escaping (String?) -> Void
    ) {
        self.account = account
        self.farm = farm
        self.assistantTransition = assistantTransition
        self.assistantTransitionID = assistantTransitionID
        self.assistantTransitionSpec = assistantTransitionSpec
        self.onAskAssistant = onAskAssistant
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                assistantPrompt
                analysisDestinations
                analysisErrorStatus
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .task(id: farm.id) {
            await deepAnalytics.load(container: modelContext.container, farmID: farm.id)
        }
        .refreshable {
            await deepAnalytics.load(container: modelContext.container, farmID: farm.id, force: true)
        }
    }

    private var analysisDestinations: some View {
        SettingsCard(title: "生产分析") {
            SettingsNavigationRow(
                title: "增重分析", subtitle: "体重变化、日增重与生长趋势",
                systemImage: "chart.line.uptrend.xyaxis", iconColor: .blue
            ) {
                WeightGainAnalysisView(account: account, farm: farm, dataStore: deepAnalytics)
            }
            .accessibilityIdentifier("analysis-weight-entry")
            SettingsCardDivider()
            SettingsNavigationRow(
                title: "羔羊分析", subtitle: "产羔数量、初生重与断奶表现",
                systemImage: "figure.and.child.holdinghands", iconColor: .orange
            ) {
                LambAnalysisView(farm: farm, dataStore: deepAnalytics)
            }
            .accessibilityIdentifier("analysis-lamb-entry")
            SettingsCardDivider()
            SettingsNavigationRow(
                title: "繁殖分析", subtitle: "胎均产羔、胎间距与母羊表现",
                systemImage: "heart.text.square", iconColor: .pink
            ) {
                ReproductionAnalysisView(farm: farm, dataStore: deepAnalytics)
            }
            .accessibilityIdentifier("analysis-reproduction-entry")
            SettingsCardDivider()
            SettingsNavigationRow(
                title: "采食分析", subtitle: "圈舍采食量与营养摄入",
                systemImage: "chart.bar.xaxis", iconColor: .green
            ) {
                FarmAnalyticsView(farm: farm)
            }
            .accessibilityIdentifier("analysis-intake-entry")
        }
    }

    @ViewBuilder
    private var analysisErrorStatus: some View {
        if let errorMessage = deepAnalytics.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text("分析数据暂时无法读取：\(errorMessage)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重新加载") {
                    Task {
                        await deepAnalytics.load(container: modelContext.container, farmID: farm.id, force: true)
                    }
                }
                .disabled(deepAnalytics.isLoading)
            }
            .padding(.horizontal, 12)
        }
    }

    private var assistantPrompt: some View {
        Button { onAskAssistant(nil) } label: {
            FarmAssistantBanner(cornerRadius: assistantTransitionSpec.cornerRadius)
                .contentShape(.rect(cornerRadius: assistantTransitionSpec.cornerRadius))
                .motionTransitionSource(
                    id: assistantTransitionID,
                    in: assistantTransition,
                    spec: assistantTransitionSpec,
                    background: AppTheme.pageBackground
                )
        }
        .buttonStyle(MotionSurfaceButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("analysis-assistant-entry")
        .accessibilityLabel("询问 AI 助手")
        .accessibilityHint("打开 AI 助手对话")
    }
}

private struct FarmAssistantBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let cornerRadius: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.24, blue: 0.48),
                    Color(red: 0.14, green: 0.40, blue: 0.70),
                    Color(red: 0.24, green: 0.60, blue: 0.84),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            assistantVisual
                .offset(x: -4, y: 0)

            assistantCopy
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize ? 180 : 126,
            alignment: .leading
        )
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
    }

    private var assistantCopy: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                Text("AI 辅助分析")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.72))

            HStack(spacing: 7) {
                Text("牧场洞察")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.78))
            }

            HStack(spacing: 7) {
                Text("记录")
                Circle()
                    .fill(.white.opacity(0.42))
                    .frame(width: 3, height: 3)
                Text("趋势")
                Circle()
                    .fill(.white.opacity(0.42))
                    .frame(width: 3, height: 3)
                Text("分析")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.11), in: .capsule)
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.15), lineWidth: 0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 92)
    }

    private var assistantVisual: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 98, height: 98)

            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 1)
                .frame(width: 82, height: 82)

            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: 58, height: 58)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                }
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white)
                }

            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .offset(x: 36, y: 8)

            Image(systemName: "bubble.left.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.64))
                .offset(x: -35, y: -21)
        }
        .frame(width: 102, height: 102)
        .accessibilityHidden(true)
    }
}

private enum WeightGainAnalysisTab: String, CaseIterable, Identifiable {
    case overview = "全场概览"
    case batch = "批次分析"
    case pen = "圈舍分析"

    var id: Self { self }
}

private enum WeightGainSelectionSheet: String, Identifiable {
    case batch
    case pens

    var id: String { rawValue }
}

private struct WeightGainAnalysisView: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    @State private var tab = WeightGainAnalysisTab.overview
    @State private var mode = WeightGainAnalysisMode.period
    @State private var selectedPenIDs: Set<UUID> = []
    @State private var selectedBatchID: UUID?
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var endDate = Calendar.current.startOfDay(for: .now)
    @State private var selectionSheet: WeightGainSelectionSheet?
    @State private var analytics = WeightGainAnalysisViewModel()

    private var farmPens: [FarmAnalyticsSnapshot.Pen] {
        (dataStore.payload?.snapshot.pens ?? []).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var farmBatches: [FarmAnalyticsBatchSnapshot] {
        dataStore.payload?.batches ?? []
    }

    /// 批次筛选只展示曾与该批次成员发生过真实关联的圈舍。
    /// 关联来源包括成员当前/初始圈舍和已记录调群事件的原舍、目标舍；
    /// 不用全场圈舍列表制造与当前批次无关的选择项。
    private var selectablePens: [FarmAnalyticsSnapshot.Pen] {
        guard tab == .batch, let batchID = selectedBatchID,
              let snapshot = dataStore.payload?.snapshot else {
            return farmPens
        }
        let sheepIDs = Set(snapshot.batchMemberships.filter { $0.batchID == batchID }.map(\.sheepID))
        guard !sheepIDs.isEmpty else { return [] }
        var relatedPenIDs = Set(snapshot.sheep.filter { sheepIDs.contains($0.id) }.compactMap(\.initialPenID))
        relatedPenIDs.formUnion(snapshot.sheep.filter { sheepIDs.contains($0.id) }.compactMap(\.currentPenID))
        for transfer in snapshot.transfers where sheepIDs.contains(transfer.sheepID) {
            if let fromPenID = transfer.fromPenID { relatedPenIDs.insert(fromPenID) }
            if let toPenID = transfer.toPenID { relatedPenIDs.insert(toPenID) }
        }
        return farmPens.filter { relatedPenIDs.contains($0.id) }
    }

    private var conditionText: String {
        let object: String
        switch tab {
        case .overview:
            object = "全场"
        case .batch:
            let batchName = farmBatches.first(where: { $0.id == selectedBatchID })?.name ?? "请选择批次"
            if !selectedPenIDs.isEmpty {
                if population == .trackedCohort {
                    let anchorTitle = "期末"
                    let count = analytics.result.map { "的 \($0.cohortMembers.count) 只羊" } ?? "名单"
                    object = "\(batchName) · \(anchorTitle)在 \(penNames(selectedPenIDs)) \(count)"
                } else {
                    object = "\(batchName) · \(penNames(selectedPenIDs))"
                }
            } else {
                object = "\(batchName) · 全部圈舍"
            }
        case .pen:
            let penName = selectedPenIDs.isEmpty ? "请选择圈舍" : penNames(selectedPenIDs)
            if let selectedBatchID,
               let batchName = farmBatches.first(where: { $0.id == selectedBatchID })?.name {
                if population == .trackedCohort {
                    let anchorTitle = "期末"
                    let count = analytics.result.map { "的 \($0.cohortMembers.count) 只羊" } ?? "名单"
                    object = "\(batchName) · \(anchorTitle)在 \(penName) \(count)"
                } else {
                    object = "\(batchName) · \(penName)"
                }
            } else {
                if population == .trackedCohort {
                    let anchorTitle = "期末"
                    let count = analytics.result.map { "的 \($0.cohortMembers.count) 只羊" } ?? "名单"
                    object = "\(anchorTitle)在 \(penName) \(count) · 全部批次"
                } else {
                    object = "\(penName) · 全部批次"
                }
            }
        }
        let populationTitle = population == .trackedCohort ? "期末圈舍羊群" : population.rawValue
        return "\(object) · \(populationTitle) · \(weightDate(startDate))–\(weightDate(endDate))"
    }

    private var population: WeightGainAnalysisPopulation {
        tab != .overview && !selectedPenIDs.isEmpty ? .trackedCohort : .wholeObject
    }

    private func penNames(_ ids: Set<UUID>) -> String {
        let names = farmPens.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? "请选择圈舍" : names.joined(separator: "、")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("按批次、圈舍和日期查看增重表现")
                    .analysisPageSubtitle()

                Picker("分析范围", selection: $tab) {
                    ForEach(WeightGainAnalysisTab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                filterCard

                if let error = dataStore.errorMessage, analytics.snapshot != nil {
                    AnalysisNotice(content: Text("刷新未完成，当前显示上次读取的数据：\(error)"))
                }

                if let errorMessage = dataStore.errorMessage, analytics.snapshot == nil {
                    AnalysisNotice(content: Text("分析数据读取失败：\(errorMessage)"))
                } else if (dataStore.isLoading && analytics.snapshot == nil) || (analytics.isCalculating && analytics.result == nil) {
                    AnalysisLoading(title: "正在计算增重数据")
                } else {
                    analysisContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("增重分析")
        .task(id: dataStore.revision) { await applySharedSnapshot() }
        .refreshable {
            await dataStore.load(container: modelContext.container, farmID: farm.id, force: true)
        }
        .sheet(item: $selectionSheet) { sheet in
            switch sheet {
            case .batch:
                WeightGainBatchSelectionSheet(
                    batches: farmBatches,
                    selection: $selectedBatchID
                )
            case .pens:
                WeightGainPenSelectionSheet(
                    pens: selectablePens,
                    selection: $selectedPenIDs,
                    allowsEmpty: tab == .batch
                )
            }
        }
        .onChange(of: tab) { _, _ in
            selectedPenIDs = selectedPenIDs.intersection(Set(selectablePens.map(\.id)))
            calculate()
        }
        .onChange(of: mode) { _, _ in calculate() }
        .onChange(of: startDate) { _, _ in calculate() }
        .onChange(of: endDate) { _, _ in calculate() }
        .onChange(of: selectedPenIDs) { _, _ in calculate() }
        .onChange(of: selectedBatchID) { _, _ in
            selectedPenIDs = selectedPenIDs.intersection(Set(selectablePens.map(\.id)))
            calculate()
        }
    }

    private var filterCard: some View {
        AnalysisCard(title: "分析条件", caption: conditionText) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 12) {
                    DatePicker(
                        mode == .paired ? "分析起点" : "开始日期",
                        selection: $startDate,
                        in: ...endDate,
                        displayedComponents: .date
                    )
                    DatePicker(
                        mode == .paired ? "分析终点" : "结束日期",
                        selection: $endDate,
                        in: startDate...FarmAnalyticsDate.day(.now),
                        displayedComponents: .date
                    )
                }

                Picker("计算方式", selection: $mode) {
                    ForEach(WeightGainAnalysisMode.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .paired {
                    Text("范围内自动取每只羊最早、最晚的有效称重。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let latest = dataStore.payload?.weightCutoff {
                    Text("最近称重：\(weightDate(latest))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if tab == .batch {
                    filterSelectionRow(
                        title: "生产批次",
                        subtitle: selectedBatchName == nil ? "请选择" : "当前批次",
                        value: selectedBatchName ?? "未选择",
                        systemImage: "square.stack.3d.up",
                        tint: .blue
                    ) {
                        selectionSheet = .batch
                    }
                    filterSelectionRow(
                        title: "关联圈舍",
                        subtitle: selectedBatchID == nil ? "先选批次" : "可多选 · 历史关联圈舍",
                        value: selectedPenSummary(allowsEmpty: true),
                        systemImage: "rectangle.3.group",
                        tint: .teal,
                        isDisabled: selectedBatchID == nil
                    ) {
                        selectionSheet = .pens
                    }
                    Text(selectedPenIDs.isEmpty ? "整批表现 · 圈舍显示分析结束日归属" : "圈舍以分析结束日期为准 · 转群前后称重连续配对")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if tab == .pen {
                    filterSelectionRow(
                        title: "圈舍",
                        subtitle: "可多选",
                        value: selectedPenSummary(allowsEmpty: false),
                        systemImage: "rectangle.3.group",
                        tint: .teal
                    ) {
                        selectionSheet = .pens
                    }
                    filterSelectionRow(
                        title: "生产批次",
                        subtitle: selectedBatchName == nil ? "可选" : "当前批次",
                        value: selectedBatchName ?? "全部批次",
                        systemImage: "square.stack.3d.up",
                        tint: .blue
                    ) {
                        selectionSheet = .batch
                    }
                    Text("圈舍以分析结束日期为准 · 转群前后称重连续配对")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectedBatchName: String? {
        guard let selectedBatchID else { return nil }
        return farmBatches.first(where: { $0.id == selectedBatchID }).map {
            $0.name.isEmpty ? "未命名生产批次" : $0.name
        }
    }

    private func selectedPenSummary(allowsEmpty: Bool) -> String {
        if selectedPenIDs.isEmpty {
            return allowsEmpty ? "全部关联圈舍" : "请选择圈舍"
        }
        if selectedPenIDs.count == 1 { return penNames(selectedPenIDs) }
        return "已选 \(selectedPenIDs.count) 个圈舍"
    }

    private func filterSelectionRow(
        title: String,
        subtitle: String,
        value: String,
        systemImage: String,
        tint: Color,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isDisabled ? Color.secondary.opacity(0.55) : tint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var analysisContent: some View {
        if tab == .overview {
            overviewContent
        } else if let result = analytics.result {
            detailContent(result)
        } else {
            AnalysisNotice(content: Text(tab == .batch ? "请选择生产批次" : "请选择圈舍"))
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        if let overview = analytics.overview {
            let all = overview.all
            MetricGrid {
                AnalysisMetric(title: "期间对象", value: "\(all.objectCount)", unit: "只", tint: .blue)
                AnalysisMetric(title: "期间称重", value: "\(all.weighedCount)", unit: "只", tint: .teal)
                AnalysisMetric(title: "可计算增重", value: "\(all.calculableCount)", unit: "只", tint: .orange)
            }

            AnalysisCard(title: "群体表现", caption: "逐羊计算 · 等权汇总") {
                if overview.groups.isEmpty {
                    AnalysisEmpty(text: "当前日期范围内还没有可识别的生产群体")
                } else {
                    ForEach(overview.groups) { group in
                        if case .batch(let batchID) = group.scope {
                            Button {
                                selectedBatchID = batchID
                                selectedPenIDs.removeAll()
                                tab = .batch
                            } label: {
                                groupRow(group)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                tab = .pen
                            } label: {
                                AnalysisRow(title: Text(group.title),
                                    detail: Text("期间涉及 \(group.result.objectCount)只 · 按圈舍继续查看"),
                                    trailing: Text("选择圈舍"))
                            }
                            .buttonStyle(.plain)
                        }
                        if group.id != overview.groups.last?.id {
                            Divider()
                        }
                    }
                }
            }

            AnalysisCard(title: "需要关注", caption: "下降和缺口") {
                if all.downwardCount == 0 && all.missingPairCount == 0 {
                    AnalysisEmpty(text: "当前范围内没有体重下降或配对缺口")
                } else {
                    if all.downwardCount > 0 {
                        AnalysisRow(
                            title: Text("本期净下降"),
                            detail: Text("期间日增重 < 0"),
                            trailing: Text("\(all.downwardCount)只")
                        )
                    }
                    if all.missingPairCount > 0 {
                        AnalysisRow(
                            title: Text("缺少有效区间"),
                            detail: Text("对象数 − 可计算数"),
                            trailing: Text("\(all.missingPairCount)只")
                        )
                    }
                    NavigationLink {
                        WeightGainEvidenceList(account: account, farm: farm, result: all, onlyCurrentDeclines: true)
                    } label: {
                        AnalysisActionButton(
                            title: "当前在场下降 \(all.currentDownwardCount)只",
                            systemImage: "list.bullet",
                            tint: .red
                        )
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        WeightGainEvidenceList(account: account, farm: farm, result: all, showExclusions: true)
                    } label: {
                        AnalysisActionButton(
                            title: "未纳入原因 \(all.exclusions.count)只",
                            systemImage: "list.bullet.clipboard",
                            tint: .orange
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            AnalysisLoading(title: "正在整理群体表现")
        }
    }

    private func groupRow(_ group: WeightGainOverviewGroup) -> some View {
        let result = group.result
        return AnalysisRow(
            title: Text(group.title),
            detail: Text("\(group.subtitle) · 可计算 \(result.calculableCount)/\(result.objectCount)只 · 下降 \(result.downwardCount)只"),
            trailing: Text(result.averageDailyGainGrams.map(weightRate) ?? "—")
        )
    }

    @ViewBuilder
    private func detailContent(_ result: WeightGainAnalysisResult) -> some View {
        MetricGrid {
            AnalysisMetric(title: "平均日增重", value: result.averageDailyGainGrams.map(weightRateValue) ?? "—", unit: "克/天", tint: .orange)
            AnalysisMetric(title: mode == .paired ? "有效配对" : "可计算增重", value: "\(result.calculableCount)", unit: "只", tint: .blue)
            AnalysisMetric(title: "体重下降", value: "\(result.downwardCount)", unit: "只", tint: .red)
        }

        if result.population == .trackedCohort {
            AnalysisCard(
                title: "期末名单与圈舍历史",
                caption: "\(result.cohortMembers.count)只名单 · \(result.transferSheepCount)只调群"
            ) {
                if result.cohortMembers.isEmpty {
                    Text("该时点没有符合条件的羊只")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    AnalysisMetric(title: "固定名单", value: "\(result.cohortMembers.count)", unit: "只", tint: .blue)
                    AnalysisMetric(title: "跨舍区间", value: "\(result.crossPenIntervalCount)", unit: "段", tint: .teal)
                    AnalysisMetric(title: "调群羊只", value: "\(result.transferSheepCount)", unit: "只", tint: .orange)
                }
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14))

                if let anchorDate = result.cohortAnchorDate {
                    Label(
                        "基准 \(weightGainEvidenceDate(anchorDate, timeZoneIdentifier: result.analysisTimeZoneIdentifier)) · \(result.analysisTimeZoneIdentifier)",
                        systemImage: "calendar"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    NavigationLink {
                        WeightGainCohortEvidenceList(result: result)
                    } label: {
                        AnalysisActionButton(title: "名单证据 \(result.cohortMembers.count)", systemImage: "person.3", tint: .blue)
                    }
                    .buttonStyle(.plain)
                    if !result.transferEvents.isEmpty {
                        NavigationLink {
                            WeightGainTransferEvidenceList(result: result)
                        } label: {
                            AnalysisActionButton(title: "调群事件 \(result.transferEvents.count)", systemImage: "arrow.left.arrow.right", tint: .orange)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if !result.transferEvents.isEmpty {
            AnalysisCard(title: "圈舍历史", caption: "\(result.transferSheepCount)只转群 · 增重连续计算") {
                AnalysisRow(
                    title: Text("转群前后称重配对"),
                    detail: Text("圈舍显示分析结束日归属"),
                    trailing: Text("\(result.crossPenIntervalCount)段")
                )
                if !result.unassignedIntervals.isEmpty {
                    NavigationLink {
                        WeightGainUnassignedIntervalList(result: result)
                    } label: {
                        AnalysisActionButton(
                            title: "未归属区间证据 \(result.unassignedIntervals.count)",
                            systemImage: "rectangle.and.text.magnifyingglass",
                            tint: .teal
                        )
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink {
                    WeightGainTransferEvidenceList(result: result)
                } label: {
                    AnalysisActionButton(
                        title: "相关调群事件 \(result.transferEvents.count)",
                        systemImage: "arrow.left.arrow.right",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
            }
        }

        if mode == .paired {
            AnalysisCard(title: "同羊两次称重", caption: "\(result.calculableCount)只有效配对") {
                HStack(spacing: 0) {
                    AnalysisMetric(
                        title: "起点均重",
                        value: result.averageStartWeight.map(weightKilograms) ?? "—",
                        unit: nil,
                        tint: .blue
                    )
                    AnalysisMetric(
                        title: "终点均重",
                        value: result.averageEndWeight.map(weightKilograms) ?? "—",
                        unit: nil,
                        tint: .teal
                    )
                    AnalysisMetric(
                        title: "平均增重",
                        value: result.averageGainKilograms.map(weightKilogramsSigned) ?? "—",
                        unit: nil,
                        tint: .orange
                    )
                }
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14))
                if let actualStartDate = result.actualStartDate, let actualEndDate = result.actualEndDate {
                    Text("\(weightDate(actualStartDate)) 至 \(weightDate(actualEndDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            AnalysisCard(title: "期间表现", caption: "\(result.intervalCount)个有效区间") {
                HStack(spacing: 0) {
                    AnalysisMetric(
                        title: "观察区间",
                        value: "\(result.intervalCount)",
                        unit: "段",
                        tint: .blue
                    )
                    AnalysisMetric(
                        title: "在场下降",
                        value: "\(result.currentDownwardCount)",
                        unit: "只",
                        tint: .red
                    )
                }
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14))
                Text("\(weightDate(startDate)) 至 \(weightDate(endDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !result.rows.isEmpty {
            AnalysisCard(title: "日增重分布", caption: "\(result.rows.count)只 · g/天") {
                WeightGainDistributionView(rows: result.rows)
            }
        }

        AnalysisCard(title: "个体明细", caption: "对象 \(result.objectCount) · 称重 \(result.weighedCount) · 可计算 \(result.calculableCount)") {
            if result.rows.isEmpty {
                AnalysisEmpty(text: "当前条件下没有形成有效增重区间")
            } else {
                NavigationLink {
                    WeightGainEvidenceList(account: account, farm: farm, result: result)
                } label: {
                    AnalysisActionButton(
                        title: "个体计算依据 \(result.rows.count)只",
                        systemImage: "list.bullet",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                NavigationLink {
                    WeightGainEvidenceList(account: account, farm: farm, result: result, onlyCurrentDeclines: true)
                } label: {
                    AnalysisActionButton(
                        title: "当前在场下降 \(result.currentDownwardCount)只",
                        systemImage: "arrow.down.right",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
            }
        }

        AnalysisCard(title: "未纳入原因", caption: "缺口单列") {
            if result.exclusions.isEmpty {
                AnalysisEmpty(text: "没有被排除的对象")
            } else {
                NavigationLink {
                    WeightGainEvidenceList(account: account, farm: farm, result: result, showExclusions: true)
                } label: {
                    AnalysisActionButton(
                        title: "未纳入原因 \(result.exclusions.count)只",
                        systemImage: "list.bullet.clipboard",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
            }
        }

        if let snapshot = analytics.snapshot, result.filter.scope != .farm {
            AnalysisCard(title: "固定样本体重趋势", caption: "全程同羊") {
                WeightGainFixedTrendView(snapshot: snapshot, filter: result.filter)
                    .id("\(conditionText)-\(dataStore.revision)")
            }
        }

        ShareLink(item: result.csvReport(scopeName: conditionText)) {
            Label("分享本次结果与全部区间（CSV 文本）", systemImage: "square.and.arrow.up")
        }
    }

    private func applySharedSnapshot() async {
        await dataStore.load(container: modelContext.container, farmID: farm.id)
        guard !Task.isCancelled, let payload = dataStore.payload else { return }
        analytics.replaceSnapshot(payload.snapshot)
        selectedPenIDs = selectedPenIDs.intersection(Set(farmPens.map(\.id)))
        if let selectedBatchID, !farmBatches.contains(where: { $0.id == selectedBatchID }) {
            self.selectedBatchID = nil
        }
        selectedPenIDs = selectedPenIDs.intersection(Set(selectablePens.map(\.id)))
        calculate()
    }

    private func calculate() {
        guard analytics.snapshot != nil else { return }
        let normalizedStart = FarmAnalyticsDate.day(min(startDate, endDate))
        let normalizedEnd = min(FarmAnalyticsDate.day(max(startDate, endDate)), FarmAnalyticsDate.day(.now))
        if startDate != normalizedStart { startDate = normalizedStart }
        if endDate != normalizedEnd { endDate = normalizedEnd }

        let scope: WeightGainAnalysisScope?
        switch tab {
        case .overview:
            scope = .farm
        case .batch:
            if let selectedBatchID {
                if selectedPenIDs.count > 1 {
                    scope = .batchAndPens(batchID: selectedBatchID, penIDs: selectedPenIDs)
                } else if let penID = selectedPenIDs.first {
                    scope = .batchAndPen(batchID: selectedBatchID, penID: penID)
                } else {
                    scope = .batch(selectedBatchID)
                }
            } else {
                scope = nil
            }
        case .pen:
            if !selectedPenIDs.isEmpty {
                if selectedPenIDs.count > 1 {
                    scope = selectedBatchID.map { .batchAndPens(batchID: $0, penIDs: selectedPenIDs) } ?? .pens(selectedPenIDs)
                } else if let penID = selectedPenIDs.first {
                    scope = selectedBatchID.map { .batchAndPen(batchID: $0, penID: penID) } ?? .pen(penID)
                } else {
                    scope = nil
                }
            } else {
                scope = nil
            }
        }
        guard let scope else {
            analytics.clearCalculation()
            return
        }
        analytics.calculate(
            filter: WeightGainAnalysisFilter(
                scope: scope,
                mode: mode,
                startDate: normalizedStart,
                endDate: normalizedEnd,
                population: population,
                cohortAnchor: .analysisEnd
            ),
            batches: farmBatches
        )
    }
}

private struct WeightGainBatchSelectionSheet: View {
    let batches: [FarmAnalyticsBatchSnapshot]
    @Binding var selection: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var draftSelection: UUID?
    @State private var search = ""

    init(batches: [FarmAnalyticsBatchSnapshot], selection: Binding<UUID?>) {
        self.batches = batches
        self._selection = selection
        self._draftSelection = State(initialValue: selection.wrappedValue)
    }

    private var filteredBatches: [FarmAnalyticsBatchSnapshot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return batches }
        return batches.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        draftSelection = nil
                    } label: {
                        selectionRow(
                            title: "全部批次",
                            subtitle: "不限制批次",
                            isSelected: draftSelection == nil,
                            tint: .blue
                        )
                    }
                    .buttonStyle(.plain)
                }

                Section("选择一个生产批次") {
                    if filteredBatches.isEmpty {
                        ContentUnavailableView("没有匹配的批次", systemImage: "square.stack.3d.up.slash")
                    } else {
                        ForEach(filteredBatches, id: \.id) { batch in
                            Button {
                                draftSelection = batch.id
                            } label: {
                                selectionRow(
                                    title: batch.name.isEmpty ? "未命名生产批次" : batch.name,
                                    subtitle: "单选",
                                    isSelected: draftSelection == batch.id,
                                    tint: .blue
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "搜索批次名称")
            .navigationTitle("选择生产批次")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        selection = draftSelection
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func selectionRow(title: String, subtitle: String, isSelected: Bool, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .contentShape(.rect)
    }
}

private struct WeightGainPenSelectionSheet: View {
    let pens: [FarmAnalyticsSnapshot.Pen]
    @Binding var selection: Set<UUID>
    let allowsEmpty: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draftSelection: Set<UUID>
    @State private var search = ""

    init(pens: [FarmAnalyticsSnapshot.Pen], selection: Binding<Set<UUID>>, allowsEmpty: Bool) {
        self.pens = pens
        self._selection = selection
        self.allowsEmpty = allowsEmpty
        self._draftSelection = State(initialValue: selection.wrappedValue)
    }

    private var filteredPens: [FarmAnalyticsSnapshot.Pen] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return pens }
        return pens.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if allowsEmpty {
                    Section {
                        Button {
                            draftSelection.removeAll()
                        } label: {
                            penRow(
                                title: "全部关联圈舍",
                                subtitle: "整批表现",
                                isSelected: draftSelection.isEmpty
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section(allowsEmpty ? "关联圈舍" : "选择圈舍") {
                    if filteredPens.isEmpty {
                        ContentUnavailableView(
                            allowsEmpty ? "该批次没有可识别的关联圈舍" : "没有匹配的圈舍",
                            systemImage: "rectangle.3.group.slash"
                        )
                    } else {
                        ForEach(filteredPens, id: \.id) { pen in
                            Button {
                                if draftSelection.contains(pen.id) {
                                    draftSelection.remove(pen.id)
                                } else {
                                    draftSelection.insert(pen.id)
                                }
                            } label: {
                                penRow(
                                    title: pen.name,
                                    subtitle: allowsEmpty ? "历史关联" : "在舍阶段",
                                    isSelected: draftSelection.contains(pen.id)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "搜索圈舍名称")
            .navigationTitle(allowsEmpty ? "选择关联圈舍" : "选择圈舍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        selection = draftSelection
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func penRow(title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.teal : Color.secondary.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .contentShape(.rect)
    }
}

private enum LambAnalysisSection: String, CaseIterable, Identifiable {
    case lambing = "产羔分析"
    case weaning = "断奶分析"
    var id: Self { self }
}

private struct LambAnalysisView: View {
    @Environment(\.modelContext) private var modelContext

    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    @State private var selectedYear = "全部"
    @State private var section = LambAnalysisSection.lambing
    @State private var analytics = FarmAnalyticsViewModel()
    @State private var detailIndex: LambSnapshotIndex?
    @State private var detailIndexRevision = UUID()

    private var years: [String] { guard let snapshot = analytics.snapshot else { return [] }; return Array(Set(snapshot.lambings.map { FarmAnalyticsDate.year($0.occurredAt) } + snapshot.weanings.map { FarmAnalyticsDate.year($0.occurredAt) })).sorted(by: >) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("聚焦每胎结构、断奶质量和缺失数据")
                    .analysisPageSubtitle()
                Picker("分析内容", selection: $section) {
                    ForEach(LambAnalysisSection.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                AnalysisFilterBar {
                    Picker("年份", selection: $selectedYear) { Text("全部").tag("全部"); ForEach(years, id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.menu)
                        .analysisFilterChip()
                }
                if let result = analytics.lambResult {
                    if section == .lambing {
                        lambingContent(result)
                    } else {
                        weaningContent(result)
                    }
                } else if let errorMessage = dataStore.errorMessage, analytics.snapshot == nil {
                    AnalysisNotice(content: Text("分析数据读取失败：\(errorMessage)"))
                } else {
                    AnalysisLoading(title: "正在计算羔羊数据")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("羔羊分析")
        .task(id: dataStore.revision) { await applySharedSnapshot() }
        .refreshable {
            await dataStore.load(container: modelContext.container, farmID: farm.id, force: true)
        }
        .onChange(of: selectedYear) { _, _ in calculateLambs() }
    }

    private func applySharedSnapshot() async {
        await dataStore.load(container: modelContext.container, farmID: farm.id)
        guard !Task.isCancelled, let snapshot = dataStore.payload?.snapshot else { return }
        analytics.replaceSnapshot(snapshot)
        detailIndex = nil
        let revision = UUID()
        detailIndexRevision = revision
        let index = await Task.detached(priority: .userInitiated) {
            LambSnapshotIndex(snapshot: snapshot)
        }.value
        guard !Task.isCancelled, detailIndexRevision == revision else { return }
        detailIndex = index
        calculateLambs()
    }
    private func calculateLambs() { analytics.calculateLambs(selectedYear: selectedYear == "全部" ? nil : selectedYear, selectedWeaningMonth: "全部") }

    @ViewBuilder
    private func lambingContent(_ result: FarmLambAnalyticsResult) -> some View {
        if result.incompleteLambingCount > 0 {
            AnalysisNotice(content: Text("有 \(result.incompleteLambingCount) 胎缺少胎次、死胎数或逐只羔羊明细，未纳入对应指标。"))
        }
        MetricGrid {
            AnalysisMetric(title: "产羔总数", value: "\(result.lambStats.totalLambs)", unit: "只", tint: .orange)
            AnalysisMetric(title: "出生死亡率", value: percent(result.lambStats.mortalityRate), unit: nil, tint: .red)
            AnalysisMetric(title: "死淘/消失率", value: percent(result.lambStats.deathCullRate), unit: nil, tint: .brown)
        }
        AnalysisCard(title: "月度产羔", caption: "点击月份查看逐只羔羊、血缘与生长数据") {
            if result.lambStats.months.isEmpty { AnalysisEmpty(text: "当前筛选范围没有完整的产羔记录") }
            if let snapshot = analytics.snapshot, let detailIndex {
                ForEach(result.lambStats.months) { month in
                    NavigationLink {
                        LambingMonthDetailView(month: month, snapshot: snapshot, index: detailIndex)
                    } label: {
                        LambingMonthRow(month: month)
                    }
                    .buttonStyle(.plain)
                    if month.id != result.lambStats.months.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private func weaningContent(_ result: FarmLambAnalyticsResult) -> some View {
        MetricGrid {
            AnalysisMetric(title: "断奶记录", value: "\(result.weaning.total)", unit: "条", tint: .teal)
            AnalysisMetric(title: "异常记录", value: "\(result.weaning.abnormalCount)", unit: "条", tint: .red)
            AnalysisMetric(title: "平均 ADG", value: sampleNumber(result.weaning.averageADG, count: result.weaning.months.reduce(0) { $0 + $1.adgCount }), unit: "克/天", tint: .orange)
        }
        AnalysisCard(title: "月度断奶", caption: "按断奶发生月份统计，点击查看逐只记录") {
            if result.weaning.months.isEmpty { AnalysisEmpty(text: "当前筛选范围没有断奶记录") }
            if let snapshot = analytics.snapshot, let detailIndex {
                ForEach(result.weaning.months) { month in
                    NavigationLink {
                        WeaningMonthDetailView(month: month, snapshot: snapshot, index: detailIndex)
                    } label: {
                        WeaningMonthRow(month: month)
                    }
                    .buttonStyle(.plain)
                    if month.id != result.weaning.months.last?.id { Divider() }
                }
            }
        }
    }
}

private struct LambingMonthRow: View {
    let month: LambMonthStats

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(month.month)).font(.subheadline.weight(.semibold))
                    Text("\(month.totalDams) 胎 · \(month.totalLambs) 羔 · 公/母 \(month.maleLambs)/\(month.femaleLambs) · 死胎 \(month.birthDead)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            AnalysisSexSummary(
                male: Text("初生 \(sampleValue(month.maleWeightAverage, count: month.maleWeightCount, unit: "kg")) · ADG \(sampleValue(month.maleADGAverage, count: month.maleADGCount, unit: "g/d"))"),
                female: Text("初生 \(sampleValue(month.femaleWeightAverage, count: month.femaleWeightCount, unit: "kg")) · ADG \(sampleValue(month.femaleADGAverage, count: month.femaleADGCount, unit: "g/d"))")
            )
        }
        .contentShape(.rect)
    }
}

private struct WeaningMonthRow: View {
    let month: WeanMonthStats

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(month.month)).font(.subheadline.weight(.semibold))
                    Text("\(month.totalCount) 条 · 公/母 \(month.maleCount)/\(month.femaleCount) · 异常 \(month.abnormalCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            AnalysisSexSummary(
                male: Text("断奶 \(sampleValue(month.maleAverageWeight, count: month.maleWeightCount, unit: "kg")) · ADG \(sampleValue(month.maleAverageADG, count: month.maleADGCount, unit: "g/d"))"),
                female: Text("断奶 \(sampleValue(month.femaleAverageWeight, count: month.femaleWeightCount, unit: "kg")) · ADG \(sampleValue(month.femaleAverageADG, count: month.femaleADGCount, unit: "g/d"))")
            )
        }
        .contentShape(.rect)
    }
}

private struct AnalysisSexSummary: View {
    let male: Text
    let female: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { male } icon: { Image(systemName: "m.circle.fill") }
                .foregroundStyle(.blue)
            Label { female } icon: { Image(systemName: "f.circle.fill") }
                .foregroundStyle(.pink)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct LambSnapshotIndex: Sendable {
    let sheepByID: [UUID: FarmAnalyticsSnapshot.Sheep]
    let penNameByID: [UUID: String]
    let latestWeaningBySheepID: [UUID: FarmAnalyticsSnapshot.Weaning]
    let latestWeightBySheepID: [UUID: SheepWeightSample]
    let lambingBySheepID: [UUID: FarmAnalyticsSnapshot.Lambing]
    let gainSamplesBySheepID: [UUID: [WeaningGainSample]]

    init(snapshot: FarmAnalyticsSnapshot) {
        sheepByID = Dictionary(uniqueKeysWithValues: snapshot.sheep.map { ($0.id, $0) })
        penNameByID = Dictionary(uniqueKeysWithValues: snapshot.pens.map { ($0.id, $0.name) })
        latestWeaningBySheepID = Dictionary(grouping: snapshot.weanings, by: \.sheepID).compactMapValues { records in
            records.max { $0.occurredAt < $1.occurredAt }
        }
        let canonicalWeights = SheepWeightSampleBuilder.dailyCanonical(snapshot.weightSamples)
        latestWeightBySheepID = Dictionary(grouping: canonicalWeights, by: \.sheepID).compactMapValues { records in
            records.max { $0.occurredAt < $1.occurredAt }
        }
        gainSamplesBySheepID = Dictionary(grouping: snapshot.weights.map {
            WeaningGainSample(id: $0.id, sheepID: $0.sheepID, kilograms: $0.kilograms, occurredAt: $0.occurredAt)
        }, by: \.sheepID)
        var lambingLookup: [UUID: FarmAnalyticsSnapshot.Lambing] = [:]
        for lambing in snapshot.lambings {
            for sheepID in lambing.offspring.compactMap(\.sheepID) { lambingLookup[sheepID] = lambing }
        }
        lambingBySheepID = lambingLookup
    }

    func gain(for weaning: FarmAnalyticsSnapshot.Weaning, birthAt: Date?) -> WeaningGainResult? {
        WeaningGainSemantics.calculate(
            sheepID: weaning.sheepID,
            birthAt: birthAt,
            weaningAt: weaning.occurredAt,
            weaningWeight: weaning.weanWeight,
            samples: gainSamplesBySheepID[weaning.sheepID] ?? []
        )
    }
}

private struct LambRawIndex {
    struct LambingMetadata {
        let sireID: UUID?
        let semenName: String?
        let note: String
    }

    let lambingByID: [UUID: LambingMetadata]
    let stillbornOffspringIDs: Set<UUID>
    let weaningNoteByID: [UUID: String]

    init(reproduction: [ReproductionRecord], offspring: [LambingOffspringRecord], weanings: [WeaningRecord]) {
        lambingByID = Dictionary(uniqueKeysWithValues: reproduction.map {
            ($0.id, LambingMetadata(sireID: $0.sireID, semenName: $0.semenNameSnapshot, note: $0.note))
        })
        stillbornOffspringIDs = Set(offspring.lazy.filter(\.isStillborn).map(\.id))
        weaningNoteByID = Dictionary(uniqueKeysWithValues: weanings.map { ($0.id, $0.note) })
    }
}

private struct LambingMonthDetailView: View {
    @Query private var reproduction: [ReproductionRecord]
    @Query private var offspringRecords: [LambingOffspringRecord]
    @Query private var weaningRecords: [WeaningRecord]

    let month: LambMonthStats
    private let lambings: [FarmAnalyticsSnapshot.Lambing]
    private let index: LambSnapshotIndex

    init(month: LambMonthStats, snapshot: FarmAnalyticsSnapshot, index: LambSnapshotIndex) {
        self.month = month
        lambings = snapshot.lambings
            .filter { $0.hasCompleteAnalyticsData && FarmAnalyticsDate.month($0.occurredAt) == month.month }
            .sorted { $0.occurredAt < $1.occurredAt }
        self.index = index
        let farmID = snapshot.farmID
        _reproduction = Query(filter: #Predicate<ReproductionRecord> { $0.farmID == farmID && $0.deletedAt == nil })
        _offspringRecords = Query(filter: #Predicate<LambingOffspringRecord> { $0.farmID == farmID })
        _weaningRecords = Query(filter: #Predicate<WeaningRecord> { $0.farmID == farmID && $0.deletedAt == nil })
    }

    var body: some View {
        let rawIndex = LambRawIndex(reproduction: reproduction, offspring: offspringRecords, weanings: weaningRecords)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                MetricGrid {
                    AnalysisMetric(title: "产羔胎次", value: "\(month.totalDams)", unit: "胎", tint: .orange)
                    AnalysisMetric(title: "羔羊", value: "\(month.totalLambs)", unit: "只", tint: .teal)
                    AnalysisMetric(title: "死胎", value: "\(month.birthDead)", unit: "只", tint: .red)
                }
                AnalysisCard(title: "公母平均", caption: "括号内为有效样本数") {
                    LambingMonthRow(month: month)
                }
                ForEach(lambings, id: \.id) { lambing in
                    AnalysisCard(title: lambing.occurredAt.formatted(date: .abbreviated, time: .omitted), caption: lambingCaption(lambing)) {
                        ForEach(lambing.offspring, id: \.id) { child in
                            LambIndividualDetailCard(facts: facts(child: child, lambing: lambing, rawIndex: rawIndex))
                            if child.id != lambing.offspring.last?.id { Divider() }
                        }
                        if let note = rawIndex.lambingByID[lambing.id]?.note, !note.isEmpty {
                            DetailFact(label: "本胎备注", value: note)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("\(month.month) 产羔")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func lambingCaption(_ lambing: FarmAnalyticsSnapshot.Lambing) -> String {
        let dam = index.sheepByID[lambing.eweID]?.earTag ?? "未知母羊"
        return "母羊 \(dam) · 第 \(lambing.parity ?? 0) 胎 · \(lambing.total) 羔"
    }

    private func facts(child: FarmAnalyticsSnapshot.Offspring, lambing: FarmAnalyticsSnapshot.Lambing, rawIndex: LambRawIndex) -> LambDetailFacts {
        let sheep = child.sheepID.flatMap { index.sheepByID[$0] }
        let weaning = child.sheepID.flatMap { index.latestWeaningBySheepID[$0] }
        let latestWeight = child.sheepID.flatMap { index.latestWeightBySheepID[$0] }
        let metadata = rawIndex.lambingByID[lambing.id]
        let sire = metadata?.sireID.flatMap { index.sheepByID[$0]?.earTag } ?? metadata?.semenName
        let pen = sheep?.currentPenID.flatMap { index.penNameByID[$0] }
        let isStillborn = rawIndex.stillbornOffspringIDs.contains(child.id)
        let effectiveBirthAt = weaning?.birthAt ?? sheep?.birthAt ?? lambing.occurredAt
        return LambDetailFacts(
            id: child.id,
            earTag: child.earTag.isEmpty ? "未记录耳号" : child.earTag,
            sex: child.sex == .male ? "公" : child.sex == .female ? "母" : "未知",
            status: isStillborn ? "死胎" : (sheep?.status.displayName ?? "未建档"),
            birthDate: lambing.occurredAt,
            birthWeight: child.birthWeight,
            dam: index.sheepByID[lambing.eweID]?.earTag,
            sire: sire,
            parity: lambing.parity,
            litterSize: lambing.total,
            breed: sheep?.breed,
            pen: pen,
            weaning: weaning,
            weaningGain: weaning.flatMap { index.gain(for: $0, birthAt: effectiveBirthAt) },
            latestWeight: latestWeight,
            fallbackBirthAt: effectiveBirthAt,
            note: weaning.flatMap { rawIndex.weaningNoteByID[$0.id] }
        )
    }
}

private struct WeaningMonthDetailView: View {
    @Query private var reproduction: [ReproductionRecord]
    @Query private var weaningRecords: [WeaningRecord]

    let month: WeanMonthStats
    private let records: [FarmAnalyticsSnapshot.Weaning]
    private let index: LambSnapshotIndex

    init(month: WeanMonthStats, snapshot: FarmAnalyticsSnapshot, index: LambSnapshotIndex) {
        self.month = month
        records = snapshot.weanings.filter { FarmAnalyticsDate.month($0.occurredAt) == month.month }.sorted { $0.occurredAt < $1.occurredAt }
        self.index = index
        let farmID = snapshot.farmID
        _reproduction = Query(filter: #Predicate<ReproductionRecord> { $0.farmID == farmID && $0.deletedAt == nil })
        _weaningRecords = Query(filter: #Predicate<WeaningRecord> { $0.farmID == farmID && $0.deletedAt == nil })
    }

    var body: some View {
        let rawIndex = LambRawIndex(reproduction: reproduction, offspring: [], weanings: weaningRecords)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                MetricGrid {
                    AnalysisMetric(title: "断奶记录", value: "\(month.totalCount)", unit: "条", tint: .teal)
                    AnalysisMetric(title: "平均断奶重", value: sampleNumber(month.averageWeight, count: month.weightCount), unit: "千克", tint: .blue)
                    AnalysisMetric(title: "平均 ADG", value: sampleNumber(month.averageADG, count: month.adgCount), unit: "克/天", tint: .orange)
                }
                AnalysisCard(title: "公母平均", caption: "括号内为有效样本数") {
                    WeaningMonthRow(month: month)
                }
                ForEach(records, id: \.id) { record in
                    LambIndividualDetailCard(facts: facts(weaning: record, rawIndex: rawIndex))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("\(month.month) 断奶")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func facts(weaning: FarmAnalyticsSnapshot.Weaning, rawIndex: LambRawIndex) -> LambDetailFacts {
        let sheep = index.sheepByID[weaning.sheepID]
        let lambing = index.lambingBySheepID[weaning.sheepID]
        let child = lambing?.offspring.first { $0.sheepID == weaning.sheepID }
        let latestWeight = index.latestWeightBySheepID[weaning.sheepID]
        let metadata = lambing.flatMap { rawIndex.lambingByID[$0.id] }
        let sire = metadata?.sireID.flatMap { index.sheepByID[$0]?.earTag } ?? metadata?.semenName
        let pen = sheep?.currentPenID.flatMap { index.penNameByID[$0] }
        let effectiveBirthAt = weaning.birthAt ?? sheep?.birthAt ?? lambing?.occurredAt
        return LambDetailFacts(
            id: weaning.id,
            earTag: sheep?.earTag ?? child?.earTag ?? "未记录耳号",
            sex: sheep?.sex == .ram ? "公" : sheep?.sex == .ewe ? "母" : child?.sex == .male ? "公" : child?.sex == .female ? "母" : "未知",
            status: sheep?.status.displayName ?? "未建档",
            birthDate: weaning.birthAt ?? sheep?.birthAt ?? lambing?.occurredAt,
            birthWeight: weaning.birthWeight ?? child?.birthWeight,
            dam: weaning.damID.flatMap { index.sheepByID[$0]?.earTag } ?? lambing.flatMap { index.sheepByID[$0.eweID]?.earTag },
            sire: sire,
            parity: lambing?.parity,
            litterSize: weaning.litterSize ?? lambing?.total,
            breed: sheep?.breed,
            pen: pen,
            weaning: weaning,
            weaningGain: index.gain(for: weaning, birthAt: effectiveBirthAt),
            latestWeight: latestWeight,
            fallbackBirthAt: effectiveBirthAt,
            note: rawIndex.weaningNoteByID[weaning.id]
        )
    }
}

private struct LambDetailFacts: Identifiable {
    let id: UUID
    let earTag: String
    let sex: String
    let status: String
    let birthDate: Date?
    let birthWeight: Double?
    let dam: String?
    let sire: String?
    let parity: Int?
    let litterSize: Int?
    let breed: String?
    let pen: String?
    let weaning: FarmAnalyticsSnapshot.Weaning?
    let weaningGain: WeaningGainResult?
    let latestWeight: SheepWeightSample?
    let fallbackBirthAt: Date?
    let note: String?

    var weaningAge: Int? {
        guard let start = weaning?.birthAt ?? fallbackBirthAt, let end = weaning?.occurredAt else { return nil }
        let days = FarmAnalyticsDate.days(from: start, to: end)
        return days > 0 ? days : nil
    }

    var adg: Double? {
        weaningGain?.gramsPerDay
    }
}

private struct LambIndividualDetailCard: View {
    let facts: LambDetailFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(facts.earTag).font(.headline)
                Text(LocalizedStringKey(facts.sex))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(facts.sex == "公" ? .blue : facts.sex == "母" ? .pink : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.fill.quaternary, in: .capsule)
                Spacer()
                Text(LocalizedStringKey(facts.status)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                CompactLambMetric(title: "初生重", value: shortWeightText(facts.birthWeight))
                Divider().frame(height: 28)
                CompactLambMetric(title: "断奶重", value: shortWeightText(facts.weaning?.weanWeight))
                Divider().frame(height: 28)
                CompactLambMetric(title: "日增重", value: facts.adg.map { "\(number($0))g" } ?? "—")
            }
            DisclosureGroup("更多信息") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        DetailFact(label: "出生日期", value: dateText(facts.birthDate))
                        DetailFact(label: "断奶日期", value: dateText(facts.weaning?.occurredAt))
                    }
                    GridRow {
                        DetailFact(label: "日增重起点", value: gainBaselineTextView)
                        DetailFact(
                            label: "计算间隔",
                            value: facts.weaningGain.map { Text("\($0.intervalDays) 天") } ?? Text("未计算")
                        )
                    }
                    GridRow {
                        DetailFact(label: "母羊", value: Text(verbatim: facts.dam ?? "未记录"))
                        DetailFact(label: "父羊/冻精", value: Text(verbatim: facts.sire ?? "未记录"))
                    }
                    GridRow {
                        DetailFact(
                            label: "胎次",
                            value: facts.parity.map { Text("第 \($0) 胎") } ?? Text("未记录")
                        )
                        DetailFact(
                            label: "同胎数",
                            value: facts.litterSize.map { Text("\($0) 只") } ?? Text("未记录")
                        )
                    }
                    GridRow {
                        DetailFact(label: "品种", value: Text(verbatim: nonempty(facts.breed)))
                        DetailFact(label: "当前圈舍", value: Text(verbatim: nonempty(facts.pen)))
                    }
                    GridRow {
                        DetailFact(
                            label: "断奶日龄",
                            value: facts.weaningAge.map { Text("\($0) 天") } ?? Text("未记录")
                        )
                        DetailFact(label: "最近体重", value: latestWeightTextView)
                    }
                }
                .padding(.top, 8)
                if let note = facts.note, !note.isEmpty { DetailFact(label: "断奶备注", value: note).padding(.top, 8) }
            }
            .font(.footnote)
        }
        .padding(15)
        .background(.background, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.38), lineWidth: 0.5) }
    }

    private func dateText(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .omitted) ?? "未记录" }
    private func weightText(_ value: Double?) -> String { value.map { "\(number($0)) 千克" } ?? "未记录" }
    private func shortWeightText(_ value: Double?) -> String { value.map { "\(number($0))kg" } ?? "—" }
    private func nonempty(_ value: String?) -> String { guard let value, !value.isEmpty else { return "未记录" }; return value }
    private var latestWeightTextView: Text {
        guard let latest = facts.latestWeight else { return Text("未记录") }
        return Text("\(number(latest.kilograms))kg · \(dateText(latest.occurredAt))")
    }
    private var gainBaselineTextView: Text {
        guard let baseline = facts.weaningGain?.baseline else { return Text("未记录") }
        return Text("\(number(baseline.kilograms))kg · \(dateText(baseline.occurredAt))")
    }
}

private struct CompactLambMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(LocalizedStringKey(title)).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DetailFact: View {
    let label: LocalizedStringKey
    let value: Text

    init(label: LocalizedStringKey, value: String) {
        self.label = label
        self.value = Text(verbatim: value)
    }

    init(label: LocalizedStringKey, value: Text) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            value.font(.footnote).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ReproductionAnalysisSection: String, CaseIterable, Identifiable {
    case interval = "胎间距"
    case postpartum = "产后天数"
    case breed = "品种分析"

    var id: Self { self }
}

private enum ReproductionAnalysisSheet: Identifiable {
    case filters

    var id: String { "reproduction-filters" }
}

private struct ReproductionAnalysisView: View {
    @Environment(\.modelContext) private var modelContext

    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    @State private var filter = ReproductionAnalyticsFilter.recentYear()
    @State private var selectedSection = ReproductionAnalysisSection.interval
    @State private var presentedSheet: ReproductionAnalysisSheet?
    @State private var analytics = FarmAnalyticsViewModel()

    private var penNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: (analytics.snapshot?.pens ?? []).map { ($0.id, $0.name) })
    }

    private var earliestLambingDate: Date {
        analytics.snapshot?.lambings.map(\.occurredAt).min().map(FarmAnalyticsDate.day)
            ?? FarmAnalyticsDate.calendar.date(byAdding: .year, value: -1, to: FarmAnalyticsDate.day(.now))
            ?? FarmAnalyticsDate.day(.now)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                #if DEBUG
                NavigationLink {
                    PenReproductionAnalysisView(farm: farm, dataStore: dataStore)
                } label: {
                    Label("羊舍母羊分析 · 四项名单与总体评价", systemImage: "house.and.flag")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(AppTheme.brand.opacity(0.08), in: .rect(cornerRadius: 16))
                }
                #endif
                Text("从胎均、繁殖间隔到品种维度查看繁殖效率")
                    .analysisPageSubtitle()
                AnalysisFilterBar {
                    ReproductionFilterChip(symbol: "calendar", title: Text(verbatim: dateRangeText)) {
                        presentedSheet = .filters
                    }
                    .disabled(analytics.snapshot == nil)
                    ReproductionFilterChip(symbol: "house", title: selectedPenView) {
                        presentedSheet = .filters
                    }
                    .disabled(analytics.snapshot == nil)
                    ReproductionFilterChip(symbol: "pawprint", title: filter.breed.map { Text(verbatim: $0) } ?? Text("全部品种")) {
                        presentedSheet = .filters
                    }
                    .disabled(analytics.snapshot == nil)
                }
                if let result = analytics.reproductionResult {
                    Text("截止 \(filter.endDate.formatted(date: .abbreviated, time: .omitted)) 固定查询母羊群 · \(result.cohortCount) 只")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if result.incompleteLambingCount > 0 {
                    AnalysisNotice(content: Text("有 \(result.incompleteLambingCount) 胎缺少胎次、死胎数或逐只羔羊明细，仅不纳入需要这些字段的指标；胎间距和产后天数仍按产羔日期计算。"))
                    }
                    MetricGrid {
                        AnalysisMetric(title: "平均每胎", value: number(result.overview.averageTotal), unit: "羔", tint: .pink)
                        AnalysisMetric(title: "死亡率", value: percent(result.overview.mortalityRate), unit: nil, tint: .red)
                        AnalysisMetric(title: "平均初生重", value: number(result.overview.averageBirthWeight), unit: "千克", tint: .orange)
                    }
                    Picker("分析维度", selection: $selectedSection) {
                        ForEach(ReproductionAnalysisSection.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    selectedSectionContent(result)
                    AnalysisCard(title: "月度产羔") {
                        if result.monthly.isEmpty { AnalysisEmpty(text: "当前筛选范围没有完整的繁殖记录") }
                        ForEach(result.monthly) { item in
                            AnalysisRow(
                                title: Text(verbatim: item.month),
                                detail: Text("\(item.lambings) 胎 · \(item.total) 羔"),
                                trailing: Text("公/母 \(item.male)/\(item.female)")
                            )
                            if item.id != result.monthly.last?.id { Divider() }
                        }
                    }
                } else if let errorMessage = dataStore.errorMessage, analytics.snapshot == nil {
                    AnalysisNotice(content: Text("分析数据读取失败：\(errorMessage)"))
                } else {
                    AnalysisLoading(title: "正在计算繁殖数据")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("繁殖表现")
        .task(id: dataStore.revision) { await applySharedSnapshot() }
        .refreshable {
            await dataStore.load(container: modelContext.container, farmID: farm.id, force: true)
        }
        .onChange(of: filter) { _, _ in calculateReproduction() }
        .sheet(item: $presentedSheet) { _ in
            if let snapshot = analytics.snapshot {
                ReproductionFilterSheet(
                    snapshot: snapshot,
                    penNames: penNames,
                    earliestDate: earliestLambingDate,
                    initialFilter: filter
                ) { appliedFilter in
                    filter = appliedFilter
                }
            } else {
                ProgressView("正在准备筛选数据")
                    .presentationDetents([.medium])
            }
        }
    }

    private func applySharedSnapshot() async {
        await dataStore.load(container: modelContext.container, farmID: farm.id)
        guard !Task.isCancelled, let snapshot = dataStore.payload?.snapshot else { return }
        analytics.replaceSnapshot(snapshot)
        calculateReproduction()
    }

    private func calculateReproduction() { analytics.calculateReproduction(filter: filter) }

    @ViewBuilder
    private func selectedSectionContent(_ result: FarmReproductionAnalyticsResult) -> some View {
        switch selectedSection {
        case .interval:
            AnalysisCard(title: "胎间距趋势", caption: "固定截止日羊舍母羊群；绿色区域为 150–240 天目标区间") {
                ReproductionHistoryChart(
                    points: result.intervalPoints,
                    tint: .blue,
                    targetRange: 150...240,
                    yAxisMinimum: 150,
                    emptyText: "当前切片没有母羊具备两次有效产羔日期"
                )
            }
            AnalysisCard(title: "胎间距合格率", caption: "每月取接近月中的群体截面，150–240 天为合格") {
                if result.qualifiedRates.isEmpty { AnalysisEmpty(text: "当前切片的胎间距数据不足") }
                ForEach(result.qualifiedRates) { item in
                    AnalysisRow(
                        title: Text(verbatim: item.month),
                        detail: Text("合格 \(percent(item.qualified / 100))"),
                        trailing: Text("不合格 \(percent(item.unqualified / 100))")
                    )
                    if item.id != result.qualifiedRates.last?.id { Divider() }
                }
            }
        case .postpartum:
            AnalysisCard(title: "产后天数趋势", caption: "固定截止日羊舍母羊群；按各日距最近一次产羔计算") {
                ReproductionHistoryChart(
                    points: result.postpartumPoints,
                    tint: .orange,
                    targetRange: nil,
                    yAxisMinimum: 0,
                    emptyText: "当前切片没有具备产羔日期的母羊"
                )
            }
        case .breed:
            AnalysisCard(title: "品种分析", caption: "按当前品种主档，对比所选日期与羊舍切片内的繁殖表现") {
                if result.breedRows.isEmpty { AnalysisEmpty(text: "当前切片的品种样本不足") }
                ForEach(result.breedRows) { row in
                    AnalysisRow(
                        title: Text(verbatim: row.breed),
                        detail: Text("\(row.sheepCount) 只 · \(row.lambingCount) 胎"),
                        trailing: Text("胎均 \(number(row.averageLambs))")
                    )
                    if row.id != result.breedRows.last?.id { Divider() }
                }
            }
        }
    }

    private var dateRangeText: String {
        let start = filter.startDate.formatted(.dateTime.year().month().day())
        let end = filter.endDate.formatted(.dateTime.year().month().day())
        return "\(start)–\(end)"
    }

    private var selectedPenView: Text {
        switch filter.penScope {
        case .all:
            return Text("全部羊舍")
        case .pen(let penID):
            return Text(verbatim: penNames[penID] ?? "历史羊舍")
        case .unassigned:
            return Text("未分圈")
        }
    }
}

private struct ReproductionFilterChip: View {
    let symbol: String
    let title: Text
    let action: () -> Void

    init(symbol: String, title: Text, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.action = action
    }

    init(symbol: String, title: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(symbol: symbol, title: Text(title), action: action)
    }

    var body: some View {
        Button(action: action) {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

private struct ReproductionHistoryChart: View {
    let points: [ReproductionHistoryPoint]
    let tint: Color
    let targetRange: ClosedRange<Double>?
    let yAxisMinimum: Double
    let emptyText: String

    var body: some View {
        if points.isEmpty {
            AnalysisEmpty(text: emptyText)
        } else {
            Chart {
                if let targetRange, let first = points.first, let last = points.last {
                    RectangleMark(
                        xStart: .value("开始", first.date),
                        xEnd: .value("结束", last.date),
                        yStart: .value("下限", targetRange.lowerBound),
                        yEnd: .value("上限", targetRange.upperBound)
                    )
                    .foregroundStyle(.green.opacity(0.09))
                }
                ForEach(points) { point in
                    AreaMark(
                        x: .value("日期", point.date),
                        yStart: .value("纵轴下限", yAxisMinimum),
                        yEnd: .value("天数", point.average)
                    )
                    .foregroundStyle(tint.opacity(0.10))
                    LineMark(
                        x: .value("日期", point.date),
                        y: .value("天数", point.average)
                    )
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
            }
            .chartYScale(domain: yAxisMinimum...yAxisMaximum)
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .chartYAxisLabel("天")
            .frame(height: 164)
            .accessibilityLabel("繁殖节律趋势")
            .accessibilityValue(latestSummary)
            if let latest = points.last {
                HStack(spacing: 8) {
                    Label("最新 \(dayNumber(latest.average)) 天", systemImage: "waveform.path.ecg")
                        .foregroundStyle(tint)
                    Spacer(minLength: 8)
                    Text("\(latest.count) 只母羊")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote.weight(.medium))
            }
        }
    }

    private var latestSummary: String {
        guard let latest = points.last else { return emptyText }
        return "最新平均 \(dayNumber(latest.average)) 天，\(latest.count) 只母羊参与"
    }

    private var yAxisMaximum: Double {
        let highestValue = max(points.map(\.average).max() ?? yAxisMinimum, targetRange?.upperBound ?? yAxisMinimum)
        let paddedValue = max(highestValue * 1.05, yAxisMinimum + 50)
        return ceil(paddedValue / 50) * 50
    }
}

private struct ReproductionFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    let snapshot: FarmAnalyticsSnapshot
    let penNames: [UUID: String]
    let earliestDate: Date
    let onApply: (ReproductionAnalyticsFilter) -> Void

    @State private var draft: ReproductionAnalyticsFilter
    @State private var options: ReproductionFilterOptions

    init(
        snapshot: FarmAnalyticsSnapshot,
        penNames: [UUID: String],
        earliestDate: Date,
        initialFilter: ReproductionAnalyticsFilter,
        onApply: @escaping (ReproductionAnalyticsFilter) -> Void
    ) {
        self.snapshot = snapshot
        self.penNames = penNames
        self.earliestDate = FarmAnalyticsDate.day(earliestDate)
        self.onApply = onApply
        _draft = State(initialValue: initialFilter)
        _options = State(initialValue: ReproductionAnalyticsEngine.filterOptions(snapshot: snapshot, asOf: initialFilter.endDate))
    }

    private var today: Date { FarmAnalyticsDate.day(.now) }
    private var lowerBound: Date { min(earliestDate, today) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "开始日期",
                        selection: $draft.startDate,
                        in: lowerBound...min(draft.endDate, today),
                        displayedComponents: .date
                    )
                    DatePicker(
                        "结束日期",
                        selection: $draft.endDate,
                        in: max(lowerBound, draft.startDate)...today,
                        displayedComponents: .date
                    )
                } header: {
                    Text("日期范围")
                } footer: {
                    Text("开始日和结束日均包含整天；区间之前的产羔日期仍会用于建立胎间距和产后天数的前序依据。")
                }

                Section {
                    Picker("羊舍", selection: $draft.penScope) {
                        Text("全部羊舍").tag(ReproductionPenScope.all)
                        ForEach(options.penIDs, id: \.self) { penID in
                            Text(penNames[penID] ?? "历史羊舍").tag(ReproductionPenScope.pen(penID))
                        }
                        if options.includesUnassigned {
                            Text("未分圈").tag(ReproductionPenScope.unassigned)
                        }
                    }
                    Picker("品种", selection: $draft.breed) {
                        Text("全部品种").tag(String?.none)
                        ForEach(options.breeds, id: \.self) { breed in
                            Text(breed).tag(String?.some(breed))
                        }
                    }
                } header: {
                    Text("母羊切片")
                } footer: {
                    Text("羊舍按查询结束日结束时的位置固定母羊群，不随图表历史日期切换；品种按当前羊只主档筛选。")
                }

                Section {
                    Button("恢复近一年与全部切片", systemImage: "arrow.counterclockwise") {
                        draft = .recentYear()
                        refreshOptions()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("繁殖筛选")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: draft.endDate) { _, _ in refreshOptions() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply() }
                }
            }
        }
    }

    private func refreshOptions() {
        options = ReproductionAnalyticsEngine.filterOptions(snapshot: snapshot, asOf: draft.endDate)
        switch draft.penScope {
        case .all:
            break
        case .pen(let penID):
            if !options.penIDs.contains(penID) { draft.penScope = .all }
        case .unassigned:
            if !options.includesUnassigned { draft.penScope = .all }
        }
        if let breed = draft.breed, !options.breeds.contains(breed) {
            draft.breed = nil
        }
    }

    private func apply() {
        let start = FarmAnalyticsDate.day(min(draft.startDate, draft.endDate))
        let end = FarmAnalyticsDate.day(min(today, max(draft.startDate, draft.endDate)))
        draft.startDate = start
        draft.endDate = end
        refreshOptions()
        onApply(draft)
        dismiss()
    }
}

private struct AnalysisCard<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.subheadline.weight(.semibold))
                if let caption { Text(LocalizedStringKey(caption)).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.38), lineWidth: 0.5) }
    }
}

private struct MetricGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .background(.background, in: .rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.38), lineWidth: 0.5) }
    }
}

private struct AnalysisMetric: View {
    let title: String
    let value: String
    let unit: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value).font(.headline).foregroundStyle(tint)
                if let unit { Text(LocalizedStringKey(unit)).font(.caption2).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

private struct AnalysisActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 12)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.22), lineWidth: 0.8) }
    }
}

private struct AnalysisRow: View {
    let title: Text
    let detail: Text
    let trailing: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                title.font(.subheadline.weight(.semibold))
                detail.font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing.font(.footnote.weight(.medium)).foregroundStyle(AppTheme.brand).multilineTextAlignment(.trailing)
        }
    }
}

private struct AnalysisNotice: View {
    let content: Text

    init(text: LocalizedStringKey) {
        content = Text(text)
    }

    init(content: Text) {
        self.content = content
    }

    var body: some View {
        Label { content } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 16))
    }
}

private struct AnalysisLoading: View {
    let title: LocalizedStringKey
    var body: some View {
        ProgressView(title)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(.background, in: .rect(cornerRadius: 18))
    }
}

private struct AnalysisEmpty: View {
    let text: String
    var body: some View { Text(LocalizedStringKey(text)).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
}

private struct AnalysisFilterBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) { content() }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 0, for: .scrollContent)
    }
}

private extension View {
    func analysisPageSubtitle() -> some View {
        font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func analysisFilterChip() -> some View {
        controlSize(.small)
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 3)
            .background(.fill.quaternary, in: .capsule)
    }
}

private func scopeName(_ scope: WeightSampleScope) -> String { switch scope { case .all: "全部样本"; case .inHerdOnly: "仅在群"; case .removedOnly: "仅离场" } }
private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
private func dayNumber(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
private func sampleNumber(_ value: Double, count: Int) -> String { count > 0 ? "\(number(value))（\(count)）" : "—" }
private func sampleValue(_ value: Double, count: Int, unit: String) -> String { count > 0 ? "\(number(value))\(unit)" : "—" }
private func percent(_ value: Double) -> String { "\(number(value * 100))%" }
private func weightDate(_ date: Date) -> String { date.formatted(date: .numeric, time: .omitted) }
private func weightRateValue(_ value: Double) -> String {
    let sign = value > 0 ? "+" : value < 0 ? "−" : ""
    return "\(sign)\(abs(value).formatted(.number.precision(.fractionLength(0...1))))"
}
private func weightRate(_ value: Double) -> String { "\(weightRateValue(value)) g/天" }
private func weightKilograms(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(1...2))))kg" }
private func weightKilogramsSigned(_ value: Double) -> String {
    let sign = value > 0 ? "+" : value < 0 ? "−" : ""
    return "\(sign)\(abs(value).formatted(.number.precision(.fractionLength(1...2))))kg"
}
