import Charts
import SwiftUI

func weightGainEvidenceDate(_ date: Date, timeZoneIdentifier: String) -> String {
    var style = Date.FormatStyle(date: .numeric, time: .shortened)
    style.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    return date.formatted(style)
}

struct WeightGainEvidenceList: View {
    let account: AccountProfile
    let farm: FarmRecord
    let result: WeightGainAnalysisResult
    var onlyCurrentDeclines = false
    var showExclusions = false
    @State private var search = ""

    private var rows: [WeightGainAnalysisRow] {
        result.rows.filter {
            (!onlyCurrentDeclines || ($0.isCurrentlyPresent && $0.isDown)) &&
                (search.isEmpty || $0.earTag.localizedStandardContains(search))
        }
    }

    var body: some View {
        List {
            if showExclusions {
                Section("未纳入 \(result.exclusions.count) 只") {
                    ForEach(result.exclusions.filter { search.isEmpty || $0.earTag.localizedStandardContains(search) }) { item in
                        NavigationLink {
                            SheepDetailEntryView(account: account, farm: farm, sheepID: item.sheepID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.earTag)
                                Text(item.reason.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Section("共 \(rows.count) 只 · g/天") {
                    ForEach(rows) { row in
                        NavigationLink {
                            WeightGainIndividualEvidence(account: account, farm: farm, row: row,
                                intervals: result.intervals.filter { $0.sheepID == row.sheepID },
                                timeZoneIdentifier: result.analysisTimeZoneIdentifier)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.earTag)
                                    Text("期末圈舍：\(row.analysisEndPenName ?? "未分舍")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("\(row.intervalCount) 个区间 · \(row.intervalDays) 个观察日")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !row.penHistory.isEmpty {
                                        Text("期间转群 \(row.penHistory.count) 次 · 查看圈舍历史")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Text(row.gramsPerDay, format: .number.precision(.fractionLength(1)))
                                    .monospacedDigit().foregroundStyle(row.isDown ? .red : .primary)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "搜索耳号")
        .navigationTitle(showExclusions ? "未纳入原因" : onlyCurrentDeclines ? "当前在场下降" : "增重个体明细")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WeightGainIndividualEvidence: View {
    let account: AccountProfile
    let farm: FarmRecord
    let row: WeightGainAnalysisRow
    let intervals: [WeightGainAnalysisInterval]
    let timeZoneIdentifier: String

    var body: some View {
        List {
            Section("本次分析") {
                LabeledContent("分析结束圈舍", value: row.analysisEndPenName ?? "未分舍")
                Text(verbatim: weightGainEvidenceDate(row.analysisEndDate, timeZoneIdentifier: timeZoneIdentifier))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("日增重", value: "\(row.gramsPerDay.formatted(.number.precision(.fractionLength(1)))) g/天")
                LabeledContent("有效区间总增重", value: "\(row.totalGainKilograms.formatted(.number.precision(.fractionLength(2)))) kg")
                LabeledContent("有效观察天数", value: "\(row.intervalDays) 天")
                Text("日增重 = 总增重 ÷ 观察天数")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("圈舍历史") {
                LabeledContent("起始圈舍", value: row.penHistoryStartPenName ?? "未分舍")
                Text(verbatim: weightGainEvidenceDate(row.penHistoryStartDate, timeZoneIdentifier: timeZoneIdentifier))
                    .font(.caption).foregroundStyle(.secondary)
                if row.penHistory.isEmpty {
                    Text("分析期间没有转群记录")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(row.penHistory) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(event.fromPenName ?? "未分舍") → \(event.toPenName ?? "未分舍")")
                        Text(verbatim: weightGainEvidenceDate(event.occurredAt, timeZoneIdentifier: timeZoneIdentifier))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(intervals) { interval in
                Section("\(interval.intervalDays) 天 · \(interval.gramsPerDay.formatted(.number.precision(.fractionLength(1)))) g/天") {
                    sampleRow("起点", sample: interval.startSample)
                    sampleRow("终点", sample: interval.endSample)
                    Text("(\(interval.endWeight.formatted()) − \(interval.startWeight.formatted())) × 1000 ÷ \(interval.intervalDays)")
                        .font(.callout).monospacedDigit()
                    if !interval.crossedTransfers.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("期间调群 · 增重连续", systemImage: "arrow.left.arrow.right")
                                .font(.caption.weight(.semibold))
                            ForEach(interval.crossedTransfers) { event in
                                Text(verbatim: "\(weightGainEvidenceDate(event.occurredAt, timeZoneIdentifier: timeZoneIdentifier)) · \(event.fromPenName ?? "未分舍") → \(event.toPenName ?? "未分舍")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink("查看羊只档案与全部原始记录") {
                    SheepDetailEntryView(account: account, farm: farm, sheepID: row.sheepID)
                }
            }
        }
        .navigationTitle(row.earTag)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sampleRow(_ title: String, sample: SheepWeightSample) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title)：\(sample.kilogramsText) kg · \(sample.source.displayName)")
            Text(verbatim: weightGainEvidenceDate(sample.occurredAt, timeZoneIdentifier: timeZoneIdentifier))
            if sample.recordedAt != .distantPast {
                Text("录入：\(weightGainEvidenceDate(sample.recordedAt, timeZoneIdentifier: timeZoneIdentifier))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("查看来源记录") {
                Text("记录 ID：\(sample.id.uuidString)")
                    .font(.caption2)
                    .textSelection(.enabled)
            }
            .font(.caption)
        }
        .font(.subheadline)
    }
}

struct WeightGainCohortEvidenceList: View {
    let result: WeightGainAnalysisResult
    @State private var search = ""

    private var members: [WeightGainCohortMember] {
        result.cohortMembers.filter { search.isEmpty || $0.earTag.localizedStandardContains(search) }
    }

    var body: some View {
        List {
            Section("固定名单 · \(members.count) 只") {
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(member.earTag).font(.headline)
                            Spacer()
                            Text(member.anchorPenName ?? "未分舍")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("基准：\(weightGainEvidenceDate(member.anchorDate, timeZoneIdentifier: result.analysisTimeZoneIdentifier))")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("查看历史身份标识") {
                            Text("羊只 ID：\(member.sheepID.uuidString)")
                                .font(.caption2).textSelection(.enabled)
                            if let membershipID = member.batchMembershipID {
                                Text("批次成员记录：\(membershipID.uuidString)")
                                    .font(.caption2).textSelection(.enabled)
                            }
                            if let transferID = member.anchorTransferID {
                                Text("基准调群事件：\(transferID.uuidString)")
                                    .font(.caption2).textSelection(.enabled)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "搜索耳号")
        .navigationTitle("固定名单证据")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WeightGainTransferEvidenceList: View {
    let result: WeightGainAnalysisResult

    var body: some View {
        List {
            Section("分析期间调群事件 · \(result.transferEvents.count) 条") {
                ForEach(result.transferEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(event.earTag) · \(event.fromPenName ?? "未分配") → \(event.toPenName ?? "未分配")")
                            .font(.headline)
                        Text("发生：\(weightGainEvidenceDate(event.occurredAt, timeZoneIdentifier: result.analysisTimeZoneIdentifier))")
                        Text("录入：\(weightGainEvidenceDate(event.recordedAt, timeZoneIdentifier: result.analysisTimeZoneIdentifier))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("备注：\(event.note)").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("查看事件标识") {
                            Text("事件 ID：\(event.id.uuidString)")
                                .font(.caption2).textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("调群证据")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WeightGainUnassignedIntervalList: View {
    let result: WeightGainAnalysisResult

    var body: some View {
        List {
            Section("跨舍未归属区间 · \(result.unassignedIntervals.count) 段") {
                ForEach(result.unassignedIntervals) { interval in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(interval.startSample.kilogramsText) kg → \(interval.endSample.kilogramsText) kg")
                            .font(.headline)
                        Text("\(interval.startDate.formatted(date: .numeric, time: .shortened)) 至 \(interval.endDate.formatted(date: .numeric, time: .shortened)) · \(interval.intervalDays) 天")
                            .font(.caption)
                        Text("跨舍 · 不计单舍")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("原因：\(interval.exclusionReason?.title ?? "无法归属单舍")")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("查看圈舍与调群证据") {
                            VStack(alignment: .leading, spacing: 4) {
                                if let startPenID = interval.startPenID {
                                    Text("起始圈舍记录：\(startPenID.uuidString)")
                                }
                                if let endPenID = interval.endPenID {
                                    Text("结束圈舍记录：\(endPenID.uuidString)")
                                }
                                if !interval.crossedTransfers.isEmpty {
                                    Text("调群事件记录：\(interval.crossedTransfers.map { $0.id.uuidString }.joined(separator: ", "))")
                                }
                            }
                            .font(.caption2)
                            .textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("未归属区间")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WeightGainDistributionView: View {
    let rows: [WeightGainAnalysisRow]

    private var bins: [(label: String, count: Int)] {
        let limits: [Double] = [0, 100, 200, 300, 400]
        var result = [("负增重", rows.count { $0.gramsPerDay < 0 }), ("零增重", rows.count { $0.gramsPerDay == 0 })]
        for index in 0..<(limits.count - 1) {
            let lower = limits[index], upper = limits[index + 1]
            result.append((index == 0 ? "0～100" : "\(Int(lower))～\(Int(upper))", rows.count {
                $0.gramsPerDay > 0 && $0.gramsPerDay >= lower && $0.gramsPerDay < upper
            }))
        }
        result.append(("≥400", rows.count { $0.gramsPerDay >= 400 }))
        return result
    }

    var body: some View {
        Chart(bins, id: \.label) { bin in
            BarMark(x: .value("只数", bin.count), y: .value("g/天", bin.label))
                .annotation(position: .trailing) { Text("\(bin.count)").font(.caption) }
                .foregroundStyle(bin.label == "负增重" ? Color.red : Color.teal)
        }
        .frame(height: 230)
        .accessibilityLabel("全部 \(rows.count) 只羊的日增重分布")
    }
}

struct WeightGainFixedTrendView: View {
    let snapshot: FarmAnalyticsSnapshot
    let filter: WeightGainAnalysisFilter
    @State private var selectedDays: Set<Date> = []
    @State private var result: WeightGainFixedTrend?
    @State private var isSelecting = false
    @State private var availableDays: [Date] = []
    @State private var hasConfiguredSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                isSelecting = true
            } label: {
                Label(
                    selectedDays.isEmpty ? "选择固定样本称重日" : "调整固定样本称重日（已选 \(selectedDays.count) 天）",
                    systemImage: "calendar.badge.clock"
                )
            }
            Text("辅助趋势 · 每个点使用同一组参测羊")
                .font(.caption).foregroundStyle(.secondary)
            if let result, !result.points.isEmpty {
                Text("固定样本 \(result.sheepIDs.count) 只 · 未进入固定样本 \(result.excludedCount) 只")
                    .font(.subheadline)
                Chart(result.points) { point in
                    LineMark(x: .value("称重日", point.date), y: .value("均重 kg", point.kilograms))
                    PointMark(x: .value("称重日", point.date), y: .value("均重 kg", point.kilograms))
                }
                .chartYAxisLabel("kg")
                .frame(height: 190)
                ForEach(result.points) { point in
                    LabeledContent(point.date.formatted(date: .abbreviated, time: .omitted),
                        value: "\(point.kilograms.formatted(.number.precision(.fractionLength(2)))) kg")
                        .font(.caption)
                }
            } else if selectedDays.count >= 2 {
                Text(result == nil ? "正在计算固定样本…" : "所选日期没有全程同羊样本。可减少称重日，或返回两次称重对比查看配对缺口。")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isSelecting) {
            NavigationStack {
                List(availableDays, id: \.self) { day in
                    Toggle(day.formatted(date: .abbreviated, time: .omitted), isOn: Binding(
                        get: { selectedDays.contains(day) },
                        set: { if $0 { selectedDays.insert(day) } else { selectedDays.remove(day) } }
                    ))
                }
                .overlay { if availableDays.isEmpty { ContentUnavailableView("期间没有称重日", systemImage: "calendar") } }
                .navigationTitle("固定样本称重日")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { isSelecting = false } } }
            }
        }
        .task(id: selectedDays) {
            result = nil
            let days = selectedDays
            let computed = await Task.detached(priority: .userInitiated) {
                WeightGainAnalyticsEngine.fixedTrend(snapshot: snapshot, filter: filter, dates: days)
            }.value
            guard !Task.isCancelled else { return }
            result = computed
        }
        .task {
            let days = await Task.detached(priority: .userInitiated) {
                WeightGainAnalyticsEngine.observationDays(snapshot: snapshot, filter: filter)
            }.value
            guard !Task.isCancelled else { return }
            availableDays = days
            if !hasConfiguredSelection, selectedDays.isEmpty, days.count >= 2 {
                selectedDays = [days[0], days[days.count - 1]]
                hasConfiguredSelection = true
            }
        }
    }
}
