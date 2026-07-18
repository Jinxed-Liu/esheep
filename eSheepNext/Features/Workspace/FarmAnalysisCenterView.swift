import Charts
import SwiftData
import SwiftUI

struct FarmAnalysisCenterView: View {
    let farm: FarmRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("牧场分析", systemImage: "chart.xyaxis.line")
                            .font(.headline)
                            .foregroundStyle(AppTheme.brand)
                        Text("把称重、产羔、繁殖和采食记录整理为可行动的生产指标。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("生产表现").font(.headline)
                AnalysisDestination(title: "增重分析", detail: "体重、ADG 与回归趋势", symbol: "chart.line.uptrend.xyaxis", tint: .blue) {
                    WeightGainAnalysisView(farm: farm)
                }
                AnalysisDestination(title: "羔羊分析", detail: "产羔、断奶与异常记录", symbol: "figure.and.child.holdinghands", tint: .orange) {
                    LambAnalysisView(farm: farm)
                }
                AnalysisDestination(title: "繁殖表现", detail: "胎均、间隔与品种表现", symbol: "heart.text.square", tint: .pink) {
                    ReproductionAnalysisView(farm: farm)
                }
                Text("饲喂表现").font(.headline).padding(.top, 4)
                AnalysisDestination(title: "采食分析", detail: "真实羊天与自由采食区间", symbol: "chart.bar.xaxis", tint: .green) {
                    FarmAnalyticsView(farm: farm)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("牧场分析")
    }
}

private struct WeightGainAnalysisView: View {
    @Query(sort: \WeightRecord.occurredAt) private var weights: [WeightRecord]
    @Query private var sheep: [SheepRecord]
    @Query private var pens: [PenRecord]
    @Query private var weanings: [WeaningRecord]
    @Query private var reproduction: [ReproductionRecord]
    @Query private var offspring: [LambingOffspringRecord]
    @Query private var removals: [RemovalRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var memberships: [BatchMembershipRecord]
    @Query private var batches: [ProductionBatchRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var feedLines: [FeedRecordLine]

    let farm: FarmRecord
    @State private var scope = WeightSampleScope.all
    @State private var selectedPenID: UUID?
    @State private var selectedBatchID: UUID?
    @State private var regressionKind = WeightRegressionKind.linear
    @State private var analytics = FarmAnalyticsViewModel()

    private func makeSnapshot() -> FarmAnalyticsSnapshot {
        FarmAnalyticsSnapshot.make(farmID: farm.id, sheep: sheep, pens: pens, weights: weights, weanings: weanings, reproduction: reproduction, offspring: offspring, removals: removals, transfers: transfers, memberships: memberships, feeds: feeds, feedLines: feedLines)
    }

    private var cutoff: Date {
        guard let snapshot = analytics.snapshot else { return .now }
        return (snapshot.weights.map(\.occurredAt) + snapshot.weanings.map(\.occurredAt)).max() ?? .now
    }
    private var cohort: WeightCohort { analytics.weightCohort ?? WeightCohort(sheepIDs: [], latestAverageWeight: nil, latestAverageADG: nil, weightTrend: [], adgTrend: [], scatter: []) }
    private var farmPens: [FarmAnalyticsSnapshot.Pen] { analytics.snapshot?.pens ?? [] }
    private var farmBatches: [ProductionBatchRecord] { batches.filter { $0.farmID == farm.id && $0.deletedAt == nil } }
    private var regression: [WeightRegressionPoint] { WeightGainAnalyticsEngine.trendline(for: cohort.scatter, kind: regressionKind) }
    private var sourceRevision: [Int] { [sheep.count, pens.count, weights.count, weanings.count, reproduction.count, offspring.count, removals.count, transfers.count, memberships.count, feeds.count, feedLines.count] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnalysisIntro(title: "增重分析", detail: "按样本范围、圈舍或生产批次查看增重表现", symbol: "chart.line.uptrend.xyaxis", tint: .blue)
                AnalysisCard(title: "样本筛选") {
                    Picker("样本范围", selection: $scope) {
                        ForEach(WeightSampleScope.allCases, id: \.self) { Text(scopeName($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Picker("圈舍", selection: $selectedPenID) {
                        Text("全场").tag(UUID?.none)
                        ForEach(farmPens, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                    Picker("批次", selection: $selectedBatchID) {
                        Text("不按批次").tag(UUID?.none)
                        ForEach(farmBatches, id: \.id) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                }
                if analytics.isCalculating && analytics.weightCohort == nil {
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
                            .frame(height: 190)
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
                            .frame(height: 180)
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
                            .frame(height: 190)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("增重分析")
        .onAppear(perform: reloadAnalytics)
        .onChange(of: sourceRevision) { _, _ in reloadAnalytics() }
        .onChange(of: scope) { _, _ in calculateWeight() }
        .onChange(of: selectedPenID) { _, _ in calculateWeight() }
        .onChange(of: selectedBatchID) { _, _ in calculateWeight() }
    }

    private func reloadAnalytics() { analytics.replaceSnapshot(makeSnapshot()); calculateWeight() }
    private func calculateWeight() { analytics.calculateWeight(penID: selectedPenID, batchID: selectedBatchID, snapshotDate: cutoff, scope: scope) }
}

private struct LambAnalysisView: View {
    @Query private var sheep: [SheepRecord]
    @Query private var pens: [PenRecord]
    @Query private var weights: [WeightRecord]
    @Query(sort: \WeaningRecord.occurredAt) private var weanings: [WeaningRecord]
    @Query(sort: \ReproductionRecord.occurredAt) private var reproduction: [ReproductionRecord]
    @Query private var offspring: [LambingOffspringRecord]
    @Query private var removals: [RemovalRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var memberships: [BatchMembershipRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var feedLines: [FeedRecordLine]

    let farm: FarmRecord
    @State private var selectedYear = "全部"
    @State private var selectedMonth = "全部"
    @State private var analytics = FarmAnalyticsViewModel()

    private func makeSnapshot() -> FarmAnalyticsSnapshot { FarmAnalyticsSnapshot.make(farmID: farm.id, sheep: sheep, pens: pens, weights: weights, weanings: weanings, reproduction: reproduction, offspring: offspring, removals: removals, transfers: transfers, memberships: memberships, feeds: feeds, feedLines: feedLines) }
    private var years: [String] { guard let snapshot = analytics.snapshot else { return [] }; return Array(Set(snapshot.lambings.map { FarmAnalyticsDate.year($0.occurredAt) } + snapshot.weanings.map { FarmAnalyticsDate.year($0.occurredAt) })).sorted(by: >) }
    private var sourceRevision: [Int] { [sheep.count, pens.count, weights.count, weanings.count, reproduction.count, offspring.count, removals.count, transfers.count, memberships.count, feeds.count, feedLines.count] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnalysisIntro(title: "羔羊分析", detail: "聚焦每胎结构、断奶质量和缺失数据", symbol: "figure.and.child.holdinghands", tint: .orange)
                AnalysisCard(title: "筛选") {
                    Picker("年份", selection: $selectedYear) { Text("全部").tag("全部"); ForEach(years, id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.menu)
                    Picker("断奶月份", selection: $selectedMonth) { Text("全部").tag("全部"); ForEach((1...12).map { String(format: "%02d", $0) }, id: \.self) { Text("\($0) 月").tag($0) } }
                        .pickerStyle(.menu)
                }
                if let result = analytics.lambResult {
                    if result.incompleteLambingCount > 0 { AnalysisNotice(text: "有 \(result.incompleteLambingCount) 胎缺少胎次、死胎数或逐只羔羊明细，未纳入对应指标。") }
                    MetricGrid {
                        AnalysisMetric(title: "产羔总数", value: "\(result.lambStats.totalLambs)", unit: "只", tint: .orange)
                        AnalysisMetric(title: "出生死亡率", value: percent(result.lambStats.mortalityRate), unit: nil, tint: .red)
                        AnalysisMetric(title: "死淘/消失率", value: percent(result.lambStats.deathCullRate), unit: nil, tint: .brown)
                    }
                    AnalysisCard(title: "月度产羔") {
                        if result.lambStats.months.isEmpty { AnalysisEmpty(text: "当前筛选范围没有完整的产羔记录") }
                        ForEach(result.lambStats.months) { month in
                            AnalysisRow(title: month.month, detail: "\(month.totalDams) 胎 · \(month.totalLambs) 羔 · 公/母 \(month.maleLambs)/\(month.femaleLambs)", trailing: "死胎 \(month.birthDead)")
                            if month.id != result.lambStats.months.last?.id { Divider() }
                        }
                    }
                    AnalysisCard(title: "断奶表现", caption: "仅统计可用的断奶原始记录") {
                        MetricGrid {
                            AnalysisMetric(title: "断奶记录", value: "\(result.weaning.total)", unit: "条", tint: .teal)
                            AnalysisMetric(title: "异常记录", value: "\(result.weaning.abnormalCount)", unit: "条", tint: .red)
                            AnalysisMetric(title: "平均 ADG", value: number(result.weaning.averageADG), unit: "克/天", tint: .orange)
                        }
                        ForEach(result.weaning.months) { month in
                            AnalysisRow(title: month.month, detail: "\(month.totalCount) 条断奶记录 · 均重 \(number(month.averageWeight)) 千克", trailing: "ADG \(number(month.averageADG))")
                            if month.id != result.weaning.months.last?.id { Divider() }
                        }
                    }
                } else {
                    AnalysisLoading(title: "正在计算羔羊数据")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("羔羊分析")
        .onAppear(perform: reloadAnalytics)
        .onChange(of: sourceRevision) { _, _ in reloadAnalytics() }
        .onChange(of: selectedYear) { _, _ in calculateLambs() }
        .onChange(of: selectedMonth) { _, _ in calculateLambs() }
    }

    private func reloadAnalytics() { analytics.replaceSnapshot(makeSnapshot()); calculateLambs() }
    private func calculateLambs() { analytics.calculateLambs(selectedYear: selectedYear == "全部" ? nil : selectedYear, selectedWeaningMonth: selectedMonth) }
}

private struct ReproductionAnalysisView: View {
    @Query private var sheep: [SheepRecord]
    @Query private var pens: [PenRecord]
    @Query private var weights: [WeightRecord]
    @Query private var weanings: [WeaningRecord]
    @Query(sort: \ReproductionRecord.occurredAt) private var reproduction: [ReproductionRecord]
    @Query private var offspring: [LambingOffspringRecord]
    @Query private var removals: [RemovalRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var memberships: [BatchMembershipRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var feedLines: [FeedRecordLine]

    let farm: FarmRecord
    @State private var selectedYear = "全部"
    @State private var analytics = FarmAnalyticsViewModel()

    private func makeSnapshot() -> FarmAnalyticsSnapshot { FarmAnalyticsSnapshot.make(farmID: farm.id, sheep: sheep, pens: pens, weights: weights, weanings: weanings, reproduction: reproduction, offspring: offspring, removals: removals, transfers: transfers, memberships: memberships, feeds: feeds, feedLines: feedLines) }
    private var years: [String] { guard let snapshot = analytics.snapshot else { return [] }; return Array(Set(snapshot.lambings.map { FarmAnalyticsDate.year($0.occurredAt) })).sorted(by: >) }
    private var sourceRevision: [Int] { [sheep.count, pens.count, weights.count, weanings.count, reproduction.count, offspring.count, removals.count, transfers.count, memberships.count, feeds.count, feedLines.count] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnalysisIntro(title: "繁殖表现", detail: "从胎均、繁殖间隔到品种维度查看繁殖效率", symbol: "heart.text.square", tint: .pink)
                AnalysisCard(title: "筛选") {
                    Picker("年份", selection: $selectedYear) { Text("全部").tag("全部"); ForEach(years, id: \.self) { Text($0).tag($0) } }
                        .pickerStyle(.menu)
                }
                if let result = analytics.reproductionResult {
                    if result.incompleteLambingCount > 0 { AnalysisNotice(text: "有 \(result.incompleteLambingCount) 胎缺少完整原始字段，未纳入繁殖性能计算。") }
                    MetricGrid {
                        AnalysisMetric(title: "平均每胎", value: number(result.overview.averageTotal), unit: "羔", tint: .pink)
                        AnalysisMetric(title: "死亡率", value: percent(result.overview.mortalityRate), unit: nil, tint: .red)
                        AnalysisMetric(title: "平均初生重", value: number(result.overview.averageBirthWeight), unit: "千克", tint: .orange)
                    }
                    AnalysisCard(title: "月度产羔") {
                        if result.monthly.isEmpty { AnalysisEmpty(text: "当前筛选范围没有完整的繁殖记录") }
                        ForEach(result.monthly) { item in
                            AnalysisRow(title: item.month, detail: "\(item.lambings) 胎 · \(item.total) 羔", trailing: "公/母 \(item.male)/\(item.female)")
                            if item.id != result.monthly.last?.id { Divider() }
                        }
                    }
                    AnalysisCard(title: "繁殖节律", caption: "合格区间按 Plus 口径计算") {
                        if result.qualifiedRates.isEmpty { AnalysisEmpty(text: "繁殖间隔数据不足") }
                        ForEach(result.qualifiedRates) { item in
                            AnalysisRow(title: item.month, detail: "合格 \(percent(item.qualified / 100))", trailing: "不合格 \(percent(item.unqualified / 100))")
                            if item.id != result.qualifiedRates.last?.id { Divider() }
                        }
                    }
                    AnalysisCard(title: "品种表现") {
                        if result.breedRows.isEmpty { AnalysisEmpty(text: "品种样本不足") }
                        ForEach(result.breedRows) { row in
                            AnalysisRow(title: row.breed, detail: "\(row.sheepCount) 只 · \(row.lambingCount) 胎", trailing: "胎均 \(number(row.averageLambs))")
                            if row.id != result.breedRows.last?.id { Divider() }
                        }
                    }
                } else {
                    AnalysisLoading(title: "正在计算繁殖数据")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationTitle("繁殖表现")
        .onAppear(perform: reloadAnalytics)
        .onChange(of: sourceRevision) { _, _ in reloadAnalytics() }
        .onChange(of: selectedYear) { _, _ in calculateReproduction() }
    }

    private func reloadAnalytics() { analytics.replaceSnapshot(makeSnapshot()); calculateReproduction() }
    private func calculateReproduction() { analytics.calculateReproduction(selectedYear: selectedYear == "全部" ? nil : selectedYear) }
}

private struct AnalysisDestination<Destination: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.background, in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

private struct AnalysisIntro: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.bold())
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AnalysisCard<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if let caption { Text(caption).font(.footnote).foregroundStyle(.secondary) }
                }
                content()
            }
        }
    }
}

private struct MetricGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) { content() }
    }
}

private struct AnalysisMetric: View {
    let title: String
    let value: String
    let unit: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold()).foregroundStyle(tint)
                if let unit { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
            .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(12)
        .background(.background.opacity(0.74), in: .rect(cornerRadius: 16))
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
    var body: some View { GlassCard { ProgressView(title).frame(maxWidth: .infinity, minHeight: 100) } }
}

private struct AnalysisEmpty: View {
    let text: String
    var body: some View { Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
}

private func scopeName(_ scope: WeightSampleScope) -> String { switch scope { case .all: "全部样本"; case .inHerdOnly: "仅在群"; case .removedOnly: "仅离场" } }
private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
private func percent(_ value: Double) -> String { "\(number(value * 100))%" }
