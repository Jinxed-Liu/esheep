import Charts
import ESMotion
import SwiftData
import SwiftUI

struct FarmAnalysisCenterView: View {
    @Environment(\.modelContext) private var modelContext

    let farm: FarmRecord
    let assistantTransition: Namespace.ID
    let assistantTransitionID: MotionTransitionID
    let assistantTransitionSpec: MotionTransitionSpec
    let onAskAssistant: () -> Void
    @State private var deepAnalytics = FarmDeepAnalyticsStore()

    init(
        farm: FarmRecord,
        assistantTransition: Namespace.ID,
        assistantTransitionID: MotionTransitionID,
        assistantTransitionSpec: MotionTransitionSpec,
        onAskAssistant: @escaping () -> Void
    ) {
        self.farm = farm
        self.assistantTransition = assistantTransition
        self.assistantTransitionID = assistantTransitionID
        self.assistantTransitionSpec = assistantTransitionSpec
        self.onAskAssistant = onAskAssistant
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                analysisHero

                VStack(alignment: .leading, spacing: 12) {
                    Text("牧场快照")
                        .font(.headline)
                    HStack(spacing: 0) {
                        DashboardMetric(title: "在场羊只", value: metricText(\.activeSheepCount), unit: "只")
                        Divider().frame(height: 46)
                        DashboardMetric(title: "有羊圈舍", value: metricText(\.activePenCount), unit: "个")
                        Divider().frame(height: 46)
                        DashboardMetric(title: "本月投喂", value: metricText(\.currentMonthFeedCount), unit: "次")
                    }
                    .padding(.vertical, 12)
                    .background(.background, in: .rect(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.38), lineWidth: 0.5) }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("深度分析")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 12)], spacing: 12) {
                        AnalysisDestination(title: "增重", detail: "体重与 ADG 趋势", symbol: "chart.line.uptrend.xyaxis", tint: .blue) {
                            WeightGainAnalysisView(farm: farm, dataStore: deepAnalytics)
                        }
                        AnalysisDestination(title: "羔羊", detail: "产羔与断奶质量", symbol: "figure.and.child.holdinghands", tint: .orange) {
                            LambAnalysisView(farm: farm, dataStore: deepAnalytics)
                        }
                        AnalysisDestination(title: "繁殖", detail: "胎均与繁殖节律", symbol: "heart.text.square", tint: .pink) {
                            ReproductionAnalysisView(farm: farm, dataStore: deepAnalytics)
                        }
                        AnalysisDestination(title: "采食", detail: "羊天与采食区间", symbol: "chart.bar.xaxis", tint: .green) {
                            FarmAnalyticsView(farm: farm)
                        }
                    }
                }

                assistantPrompt
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

    private var analysisHero: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.brand)
                .frame(width: 38, height: 38)
                .background(AppTheme.brand.opacity(0.10), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("今天的牧场")
                    .font(.title3.bold())
                Text(latestActivityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var latestActivityText: String {
        if deepAnalytics.isLoading, deepAnalytics.payload == nil { return "正在后台准备分析数据…" }
        if let errorMessage = deepAnalytics.errorMessage { return "分析数据暂时无法读取：\(errorMessage)" }
        guard let latestActivityDate = deepAnalytics.payload?.latestActivityDate else { return "还没有可用于分析的生产记录" }
        return "最近记录于 \(latestActivityDate.formatted(.relative(presentation: .named)))"
    }

    private func metricText(_ keyPath: KeyPath<FarmDeepAnalyticsPayload, Int>) -> String {
        deepAnalytics.payload.map { String($0[keyPath: keyPath]) } ?? "—"
    }

    private var assistantPrompt: some View {
        Button(action: onAskAssistant) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.brand)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.brand.opacity(0.10), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("与 AI 助手聊天")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("让 AI 助手结合当前牧场记录分析、回答或生成操作草案")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.brand)
            }
            .padding(16)
            .background(.background, in: .rect(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(AppTheme.brand.opacity(0.16), lineWidth: 1) }
            .contentShape(.rect(cornerRadius: 22))
            .motionTransitionSource(
                id: assistantTransitionID,
                in: assistantTransition,
                spec: assistantTransitionSpec,
                background: AppTheme.pageBackground
            )
        }
        .buttonStyle(MotionSurfaceButtonStyle())
        .accessibilityHint("打开全屏 AI 助手")
    }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WeightGainAnalysisView: View {
    @Environment(\.modelContext) private var modelContext

    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    @State private var scope = WeightSampleScope.all
    @State private var selectedPenID: UUID?
    @State private var selectedBatchID: UUID?
    @State private var regressionKind = WeightRegressionKind.linear
    @State private var analytics = FarmAnalyticsViewModel()

    private var cutoff: Date {
        dataStore.payload?.weightCutoff ?? .now
    }
    private var cohort: WeightCohort { analytics.weightCohort ?? WeightCohort(sheepIDs: [], latestAverageWeight: nil, latestAverageADG: nil, weightTrend: [], adgTrend: [], scatter: []) }
    private var eligiblePenIDs: Set<UUID> {
        dataStore.payload?.eligibleWeightPenIDs ?? []
    }
    private var farmPens: [FarmAnalyticsSnapshot.Pen] {
        guard let snapshot = dataStore.payload?.snapshot else { return [] }
        return snapshot.pens.filter { eligiblePenIDs.contains($0.id) }
    }
    private var farmBatches: [FarmAnalyticsBatchSnapshot] { dataStore.payload?.batches ?? [] }
    private var visibleBatchIDs: [UUID] { farmBatches.map(\.id).sorted { $0.uuidString < $1.uuidString } }
    private var regression: [WeightRegressionPoint] { WeightGainAnalyticsEngine.trendline(for: cohort.scatter, kind: regressionKind) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("按样本范围、圈舍或生产批次查看增重表现")
                    .analysisPageSubtitle()
                AnalysisFilterBar {
                    Picker("样本范围", selection: $scope) {
                        ForEach(WeightSampleScope.allCases, id: \.self) { Text(scopeName($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .analysisFilterChip()
                    Picker("圈舍", selection: $selectedPenID) {
                        Text("全场").tag(UUID?.none)
                        ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .analysisFilterChip()
                    Picker("批次", selection: $selectedBatchID) {
                        Text("不按批次").tag(UUID?.none)
                        ForEach(farmBatches, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .analysisFilterChip()
                }
                if dataStore.errorMessage != nil, analytics.snapshot == nil {
                    AnalysisNotice(text: "分析数据读取失败：\(dataStore.errorMessage ?? "未知错误")")
                } else if analytics.isCalculating && analytics.weightCohort == nil || dataStore.isLoading && analytics.snapshot == nil {
                    AnalysisLoading(title: "正在计算增重数据")
                } else {
                    MetricGrid {
                        AnalysisMetric(title: "有效羊只", value: "\(cohort.sheepIDs.count)", unit: "只", tint: .blue)
                        AnalysisMetric(title: "最新均重", value: cohort.latestAverageWeight.map(number) ?? "—", unit: "千克", tint: .teal)
                        AnalysisMetric(title: "首末 ADG", value: cohort.latestAverageADG.map(number) ?? "—", unit: "千克/天", tint: .orange)
                    }
                    if analytics.isCalculating { ProgressView("正在更新分析").font(.footnote) }
                    if !cohort.weightTrend.isEmpty {
                        AnalysisCard(title: "平均体重趋势", caption: "每个记录日期的样本平均体重") {
                            Chart(cohort.weightTrend) { point in
                                AreaMark(x: .value("日期", point.date), y: .value("体重", point.value))
                                    .foregroundStyle(AppTheme.brand.opacity(0.16))
                                LineMark(x: .value("日期", point.date), y: .value("体重", point.value))
                                    .foregroundStyle(AppTheme.brand)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                                PointMark(x: .value("日期", point.date), y: .value("体重", point.value))
                                    .foregroundStyle(AppTheme.brand)
                            }
                            .frame(height: 164)
                        }
                    }
                    if !cohort.adgTrend.isEmpty {
                        AnalysisCard(title: "区间 ADG 趋势", caption: "相邻两次有效体重的平均日增重") {
                            Chart(cohort.adgTrend) { point in
                                LineMark(x: .value("日期", point.date), y: .value("ADG", point.value))
                                    .foregroundStyle(.orange)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                                PointMark(x: .value("日期", point.date), y: .value("ADG", point.value))
                                    .foregroundStyle(.orange)
                            }
                            .frame(height: 164)
                        }
                    }
                    if !cohort.scatter.isEmpty {
                        AnalysisCard(title: "体重与 ADG", caption: "前次体重与区间日增重的关系") {
                            Picker("趋势线", selection: $regressionKind) {
                                ForEach(WeightRegressionKind.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Chart {
                                ForEach(cohort.scatter) { point in
                                    PointMark(x: .value("前次体重", point.baselineWeight), y: .value("ADG", point.adg))
                                        .foregroundStyle(AppTheme.brand.opacity(0.65))
                                }
                                ForEach(regression) { point in
                                    LineMark(x: .value("前次体重", point.x), y: .value("ADG", point.y))
                                        .foregroundStyle(.orange)
                                        .lineStyle(StrokeStyle(lineWidth: 2, dash: regressionKind == .linear ? [8, 5] : []))
                                }
                            }
                            .frame(height: 164)
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
        .navigationTitle("增重分析")
        .task(id: dataStore.revision) { await applySharedSnapshot() }
        .refreshable {
            await dataStore.load(container: modelContext.container, farmID: farm.id, force: true)
        }
        .onChange(of: scope) { _, _ in calculateWeight() }
        .onChange(of: selectedPenID) { _, _ in calculateWeight() }
        .onChange(of: selectedBatchID) { _, _ in calculateWeight() }
        .onChange(of: visibleBatchIDs) { _, validIDs in
            if let selectedBatchID, !validIDs.contains(selectedBatchID) {
                self.selectedBatchID = nil
            }
        }
        .onChange(of: eligiblePenIDs) { _, validIDs in
            if let selectedPenID, !validIDs.contains(selectedPenID) {
                self.selectedPenID = nil
            }
        }
    }

    private func applySharedSnapshot() async {
        await dataStore.load(container: modelContext.container, farmID: farm.id)
        guard !Task.isCancelled, let payload = dataStore.payload else { return }
        analytics.replaceSnapshot(payload.snapshot)
        if let selectedPenID, !payload.eligibleWeightPenIDs.contains(selectedPenID) {
            self.selectedPenID = nil
        }
        if let selectedBatchID, !payload.batches.contains(where: { $0.id == selectedBatchID }) {
            self.selectedBatchID = nil
        }
        calculateWeight()
    }

    private func calculateWeight() {
        let batchID = selectedBatchID.flatMap { selected in
            farmBatches.contains(where: { $0.id == selected }) ? selected : nil
        }
        analytics.calculateWeight(penID: selectedPenID, batchID: batchID, snapshotDate: cutoff, scope: scope)
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
                    ForEach(LambAnalysisSection.allCases) { Text($0.rawValue).tag($0) }
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
                    AnalysisNotice(text: "分析数据读取失败：\(errorMessage)")
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
        if result.incompleteLambingCount > 0 { AnalysisNotice(text: "有 \(result.incompleteLambingCount) 胎缺少胎次、死胎数或逐只羔羊明细，未纳入对应指标。") }
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
                    Text(month.month).font(.subheadline.weight(.semibold))
                    Text("\(month.totalDams) 胎 · \(month.totalLambs) 羔 · 公/母 \(month.maleLambs)/\(month.femaleLambs) · 死胎 \(month.birthDead)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            AnalysisSexSummary(
                male: "初生 \(sampleValue(month.maleWeightAverage, count: month.maleWeightCount, unit: "kg")) · ADG \(sampleValue(month.maleADGAverage, count: month.maleADGCount, unit: "g/d"))",
                female: "初生 \(sampleValue(month.femaleWeightAverage, count: month.femaleWeightCount, unit: "kg")) · ADG \(sampleValue(month.femaleADGAverage, count: month.femaleADGCount, unit: "g/d"))"
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
                    Text(month.month).font(.subheadline.weight(.semibold))
                    Text("\(month.totalCount) 条 · 公/母 \(month.maleCount)/\(month.femaleCount) · 异常 \(month.abnormalCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            AnalysisSexSummary(
                male: "断奶 \(sampleValue(month.maleAverageWeight, count: month.maleWeightCount, unit: "kg")) · ADG \(sampleValue(month.maleAverageADG, count: month.maleADGCount, unit: "g/d"))",
                female: "断奶 \(sampleValue(month.femaleAverageWeight, count: month.femaleWeightCount, unit: "kg")) · ADG \(sampleValue(month.femaleAverageADG, count: month.femaleADGCount, unit: "g/d"))"
            )
        }
        .contentShape(.rect)
    }
}

private struct AnalysisSexSummary: View {
    let male: String
    let female: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(male, systemImage: "m.circle.fill").foregroundStyle(.blue)
            Label(female, systemImage: "f.circle.fill").foregroundStyle(.pink)
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
                Text(facts.sex)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(facts.sex == "公" ? .blue : facts.sex == "母" ? .pink : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.fill.quaternary, in: .capsule)
                Spacer()
                Text(facts.status).font(.caption).foregroundStyle(.secondary)
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
                        DetailFact(label: "日增重起点", value: gainBaselineText)
                        DetailFact(label: "计算间隔", value: facts.weaningGain.map { "\($0.intervalDays) 天" } ?? "未计算")
                    }
                    GridRow {
                        DetailFact(label: "母羊", value: facts.dam ?? "未记录")
                        DetailFact(label: "父羊/冻精", value: facts.sire ?? "未记录")
                    }
                    GridRow {
                        DetailFact(label: "胎次", value: facts.parity.map { "第 \($0) 胎" } ?? "未记录")
                        DetailFact(label: "同胎数", value: facts.litterSize.map { "\($0) 只" } ?? "未记录")
                    }
                    GridRow {
                        DetailFact(label: "品种", value: nonempty(facts.breed))
                        DetailFact(label: "当前圈舍", value: nonempty(facts.pen))
                    }
                    GridRow {
                        DetailFact(label: "断奶日龄", value: facts.weaningAge.map { "\($0) 天" } ?? "未记录")
                        DetailFact(label: "最近体重", value: latestWeightText)
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
    private var latestWeightText: String {
        guard let latest = facts.latestWeight else { return "未记录" }
        return "\(number(latest.kilograms))kg · \(dateText(latest.occurredAt))"
    }
    private var gainBaselineText: String {
        guard let baseline = facts.weaningGain?.baseline else { return "未记录" }
        return "\(number(baseline.kilograms))kg · \(dateText(baseline.occurredAt))"
    }
}

private struct CompactLambMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DetailFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote).lineLimit(2).minimumScaleFactor(0.8)
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
                Text("从胎均、繁殖间隔到品种维度查看繁殖效率")
                    .analysisPageSubtitle()
                AnalysisFilterBar {
                    ReproductionFilterChip(symbol: "calendar", title: dateRangeText) {
                        presentedSheet = .filters
                    }
                    .disabled(analytics.snapshot == nil)
                    ReproductionFilterChip(symbol: "house", title: selectedPenText) {
                        presentedSheet = .filters
                    }
                    .disabled(analytics.snapshot == nil)
                    ReproductionFilterChip(symbol: "pawprint", title: filter.breed ?? "全部品种") {
                        presentedSheet = .filters
                    }
                    .disabled(analytics.snapshot == nil)
                }
                if let result = analytics.reproductionResult {
                    Text("截止 \(filter.endDate.formatted(date: .abbreviated, time: .omitted)) 固定查询母羊群 · \(result.cohortCount) 只")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if result.incompleteLambingCount > 0 {
                        AnalysisNotice(text: "有 \(result.incompleteLambingCount) 胎缺少胎次、死胎数或逐只羔羊明细，仅不纳入需要这些字段的指标；胎间距和产后天数仍按产羔日期计算。")
                    }
                    MetricGrid {
                        AnalysisMetric(title: "平均每胎", value: number(result.overview.averageTotal), unit: "羔", tint: .pink)
                        AnalysisMetric(title: "死亡率", value: percent(result.overview.mortalityRate), unit: nil, tint: .red)
                        AnalysisMetric(title: "平均初生重", value: number(result.overview.averageBirthWeight), unit: "千克", tint: .orange)
                    }
                    Picker("分析维度", selection: $selectedSection) {
                        ForEach(ReproductionAnalysisSection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    selectedSectionContent(result)
                    AnalysisCard(title: "月度产羔") {
                        if result.monthly.isEmpty { AnalysisEmpty(text: "当前筛选范围没有完整的繁殖记录") }
                        ForEach(result.monthly) { item in
                            AnalysisRow(title: item.month, detail: "\(item.lambings) 胎 · \(item.total) 羔", trailing: "公/母 \(item.male)/\(item.female)")
                            if item.id != result.monthly.last?.id { Divider() }
                        }
                    }
                } else if let errorMessage = dataStore.errorMessage, analytics.snapshot == nil {
                    AnalysisNotice(text: "分析数据读取失败：\(errorMessage)")
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
                    AnalysisRow(title: item.month, detail: "合格 \(percent(item.qualified / 100))", trailing: "不合格 \(percent(item.unqualified / 100))")
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
                    AnalysisRow(title: row.breed, detail: "\(row.sheepCount) 只 · \(row.lambingCount) 胎", trailing: "胎均 \(number(row.averageLambs))")
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

    private var selectedPenText: String {
        switch filter.penScope {
        case .all:
            return "全部羊舍"
        case .pen(let penID):
            return penNames[penID] ?? "历史羊舍"
        case .unassigned:
            return "未分圈"
        }
    }
}

private struct ReproductionFilterChip: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
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

private struct AnalysisDestination<Destination: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.10), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.38), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
    }
}

private struct AnalysisCard<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.38), lineWidth: 0.5) }
    }
}

private struct MetricGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 0) { content() }
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
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value).font(.headline).foregroundStyle(tint)
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

private struct AnalysisRow: View {
    let title: String
    let detail: String
    let trailing: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(trailing).font(.footnote.weight(.medium)).foregroundStyle(AppTheme.brand).multilineTextAlignment(.trailing)
        }
    }
}

private struct AnalysisNotice: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 16))
    }
}

private struct AnalysisLoading: View {
    let title: String
    var body: some View {
        ProgressView(title)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(.background, in: .rect(cornerRadius: 18))
    }
}

private struct AnalysisEmpty: View {
    let text: String
    var body: some View { Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
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
