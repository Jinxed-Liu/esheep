import Combine
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class PenReproductionAnalysisModel {
    private(set) var summaries: [PenReproductionSummary] = []
    private(set) var breeds: [String] = []
    private(set) var isCalculating = false
    private(set) var error: String?
    private var generation = UUID()

    func calculate(snapshot: FarmAnalyticsSnapshot, date: Date, breed: String?) async {
        let request = UUID()
        generation = request
        isCalculating = true
        error = nil
        let work = Task.detached(priority: .userInitiated) {
            let breeds = Array(Set(snapshot.sheep.filter {
                $0.sex == .ewe && $0.purpose == SheepPurpose.breedingEwe.rawValue && !$0.breed.isEmpty
            }.map(\.breed))).sorted()
            let summaries = try PenReproductionAnalyticsEngine.calculate(snapshot: snapshot, asOf: date, breed: breed)
            return (summaries, breeds)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard request == generation else { return }
            summaries = result.0
            breeds = result.1
            isCalculating = false
        } catch {
            guard request == generation else { return }
            isCalculating = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}

private struct PenReproductionRequest: Hashable {
    let revision: UUID
    let date: Date
    let breed: String
}

struct PenReproductionAnalysisView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    let farm: FarmRecord
    let dataStore: FarmDeepAnalyticsStore
    @State private var date = FarmAnalyticsDate.day(.now)
    @State private var breed = ""
    @State private var model = PenReproductionAnalysisModel()
    @State private var reload = 0
    @State private var selectedPenID: String?

    var body: some View {
        List {
            Section("分析条件") {
                DatePicker("截止日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                Picker("品种", selection: $breed) {
                    Text("全部品种").tag("")
                    ForEach(model.breeds, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                Text("仅统计当前启用、且截止日当天有符合所选品种的在群在场繁殖母羊的圈舍。截止日已离场、死亡或无在群依据的历史档案不计入；用途、品种使用当前主档。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = dataStore.errorMessage ?? model.error {
                Section { Text("分析读取失败：\(error)").foregroundStyle(.red) }
            }
            if model.isCalculating || dataStore.isLoading {
                ProgressView("正在计算羊舍母羊分析")
            }
            if model.summaries.isEmpty {
                if !model.isCalculating && !dataStore.isLoading {
                    ContentUnavailableView("暂无符合条件的圈舍", systemImage: "house", description: Text("仅显示当前启用且截止日有符合筛选条件的繁殖母羊的圈舍。"))
                }
            } else {
                Section("各舍概览") {
                    ForEach(model.summaries) { summary in
                        Button {
                            selectedPenID = summary.id
                        } label: {
                            HStack {
                                PenReproductionOverviewRow(summary: summary)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isCalculating || dataStore.isLoading)
                        .accessibilityIdentifier("pen-reproduction-open-\(summary.id)")
                    }
                }
            }
            Section {
                DisclosureGroup("统计口径") { PenReproductionRulesView() }
            } footer: {
                Text("结果依据本机已加载的农场记录。云端同步或本地记录更新后重新计算；可下拉刷新。")
            }
        }
        .navigationTitle("羊舍母羊分析")
        .tint(AppTheme.brand)
        .navigationDestination(item: $selectedPenID) { key in
            PenReproductionDetailView(farm: farm, penKey: key,
                                      dataStore: dataStore, date: date, breed: breed)
        }
        .task(id: reload) {
            await dataStore.load(container: modelContext.container, farmID: farm.id, force: true)
        }
        .task(id: PenReproductionRequest(revision: dataStore.revision, date: date, breed: breed)) {
            guard let snapshot = dataStore.payload?.snapshot else { return }
            await model.calculate(snapshot: snapshot, date: date, breed: breed.isEmpty ? nil : breed)
        }
        .refreshable { await dataStore.load(container: modelContext.container, farmID: farm.id, force: true) }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)) { _ in reload &+= 1 }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload &+= 1 } }
    }
}

private struct PenReproductionOverviewRow: View {
    let summary: PenReproductionSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: summary.name).font(.headline)
                Spacer()
                Text(verbatim: summary.rating).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.brand)
            }
            Text("繁殖母羊 \(summary.ewes.count) 只 · 关注 \(summary.attentionCount) 只（\(penEwePercent(summary.attentionRate))）")
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                Text("产后超时 \(summary.rows[.postpartum]?.count ?? 0) 只 · 零胎久留 \(summary.rows[.zeroParity]?.count ?? 0) 只")
                Text("首胎单羔 \(summary.rows[.firstSingle]?.count ?? 0) 只 · 连续三胎单羔 \(summary.rows[.threeSingles]?.count ?? 0) 只")
            }
            .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            if !summary.pending.isEmpty {
                Text("\(summary.pending.count) 只母羊有待核实记录").font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct PenReproductionDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let farm: FarmRecord
    let penKey: String
    @State private var model = PenReproductionAnalysisModel()
    @State private var selectedSheepID: UUID?
    let dataStore: FarmDeepAnalyticsStore
    let date: Date
    let breed: String

    var body: some View {
        ZStack {
            if let summary = model.summaries.first(where: { $0.id == penKey }) {
                List {
                    if model.isCalculating || dataStore.isLoading {
                        ProgressView("正在更新羊舍分析")
                    }
                    if let error = dataStore.errorMessage ?? model.error {
                        Section { Text("刷新失败，以下为上次已加载结果：\(error)").foregroundStyle(.orange) }
                    }
                    Section("总体评价") {
                        Text("品种：\(breed.isEmpty ? "全部品种" : breed) · 仅评价当前筛选范围")
                            .font(.footnote).foregroundStyle(.secondary)
                        PenReproductionOverviewRow(summary: summary)
                        Text("截至 \(date.formatted(date: .abbreviated, time: .omitted))，四项名单去重后关注 \(summary.attentionCount) 只，占本舍分析母羊的 \(penEwePercent(summary.attentionRate))。")
                        if !summary.mainConcerns.isEmpty {
                            Text("主要关注：\(summary.mainConcerns.map(\.title).joined(separator: "、"))。")
                        } else if summary.pending.isEmpty && !summary.ewes.isEmpty {
                            Text("当前记录未命中四项关注条件。")
                        }
                        Text("四项分别计数，允许重叠；评级按羊只去重。小样本羊舍请结合实际只数查看。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(PenEweConcern.allCases) { concern in
                        let rows = summary.rows[concern] ?? []
                        Section {
                            if rows.isEmpty { Text("暂无已确认符合条件的母羊").foregroundStyle(.secondary) }
                            ForEach(rows) { ewe in
                                PenEweEvidenceRow(ewe: ewe, concern: concern) { selectedSheepID = $0 }
                            }
                        } header: {
                            Text("\(concern.rawValue + 1). \(concern.title) · \(rows.count) 只（\(penEwePercent(summary.ewes.isEmpty ? 0 : Double(rows.count) / Double(summary.ewes.count)))）")
                        } footer: { Text(verbatim: concern.advice) }
                    }
                    if !summary.pending.isEmpty {
                        Section("待核实记录 · \(summary.pending.count) 只") {
                            ForEach(summary.pending) { ewe in
                                VStack(alignment: .leading, spacing: 6) {
                                    PenEweDetailLink(ewe: ewe) { selectedSheepID = $0 }
                                    Text(verbatim: ewe.issues.joined(separator: "；"))
                                        .font(.footnote).foregroundStyle(.orange)
                                    if ewe.blocksRating { Text("可能改变关注数，暂不评级").font(.caption) }
                                }
                            }
                        }
                    }
                    Section { PenReproductionRulesView() }
                }
                .navigationTitle(summary.name)
                .refreshable { await refresh() }
                .accessibilityIdentifier("pen-reproduction-detail")
            } else if model.isCalculating || dataStore.isLoading {
                ProgressView("正在读取羊舍分析")
            } else {
                ContentUnavailableView("羊舍分析暂不可用", systemImage: "house", description: Text(model.error ?? "数据已更新，请返回重新选择羊舍。"))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedSheepID) { id in
            PenEweSheepDestination(farm: farm, sheepID: id)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        // Re-entering from an edited sheep must refresh even when the overview's
        // task is suspended further down the navigation stack.
        await dataStore.load(container: modelContext.container, farmID: farm.id, force: true)
        guard !Task.isCancelled, dataStore.errorMessage == nil, let snapshot = dataStore.payload?.snapshot else { return }
        await model.calculate(snapshot: snapshot, date: date, breed: breed.isEmpty ? nil : breed)
    }
}

private struct PenEweEvidenceRow: View {
    let ewe: PenEweAssessment
    let concern: PenEweConcern
    let onOpenSheep: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PenEweDetailLink(ewe: ewe, onOpenSheep: onOpenSheep)
            switch concern {
            case .postpartum, .firstSingle:
                if let birth = ewe.lambings.last {
                    Text("最近产羔 \(birth.occurredAt.formatted(date: .abbreviated, time: .omitted)) · \(birth.total) 羔")
                    Text("产后 \(ewe.postpartumDays ?? 0) 天")
                }
            case .zeroParity:
                Text("本舍累计 \(ewe.residenceDays) 天")
                DisclosureGroup("查看各段在舍时间") {
                    ForEach(ewe.residence) { period in
                        Text("\(period.start.formatted(date: .abbreviated, time: .omitted)) — \(period.end.formatted(date: .abbreviated, time: .omitted)) · \(period.days) 天\(period.isOngoing ? "（截至查询日）" : "")")
                            .font(.caption)
                    }
                }
            case .threeSingles:
                ForEach(Array(ewe.lambings.suffix(3)), id: \.id) { birth in
                    Text("第\(birth.parity ?? 0)胎 · \(birth.occurredAt.formatted(date: .abbreviated, time: .omitted)) · \(birth.total) 羔")
                }
            }
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }
}

private struct PenEweDetailLink: View {
    let ewe: PenEweAssessment
    let onOpenSheep: (UUID) -> Void
    var body: some View {
        Button {
            onOpenSheep(ewe.id)
        } label: {
            HStack {
                Text(verbatim: ewe.earTag).font(.headline)
                Spacer()
                Text(ewe.parity.map { "当前\($0)胎" } ?? "胎次待核实").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pen-reproduction-sheep-\(ewe.id)")
    }
}

private struct PenEweSheepDestination: View {
    @Environment(AppSession.self) private var session
    @Query private var accounts: [AccountProfile]
    let farm: FarmRecord
    let sheepID: UUID
    var body: some View {
        if let account = accounts.first(where: { $0.id == session.activeAccountProfileID }) {
            SheepDetailEntryView(account: account, farm: farm, sheepID: sheepID)
        } else {
            ContentUnavailableView("请先登录当前账户", systemImage: "person.crop.circle")
        }
    }
}

private struct PenReproductionRulesView: View {
    var body: some View {
        DisclosureGroup("统计口径与评级规则") {
            VStack(alignment: .leading, spacing: 8) {
                Text("① 距最近产羔严格大于250天；② 明确零胎、无产羔记录且本舍历史累计严格大于200天；③ 当前仅1胎且首胎总产羔数为1；④ 最近连续三胎各产1只，无缺胎。单羔按出生总数判断，包含死胎。")
                Text("哺乳及断奶羔羊阶段不计时，从后续有效转群记录起算；转出再转回累计各段日期差，不以出生或建档日期代替。无产羔且无胎次记录按零胎；已有胎次以记录为准。")
                Text("关注比例＝四项命中母羊去重数÷本舍分析繁殖母羊数。优＜10%；良10%至＜20%；中20%至＜30%；差≥30%。评级使用未四舍五入的比例。")
                Text("上述为初版农场管理规则。缺失证据仍可能改变去重关注数时暂不评级；已确认命中的母羊仍保留名单。评价仅提供复核方向，不自动建议淘汰。")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private func penEwePercent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(1)))
}
