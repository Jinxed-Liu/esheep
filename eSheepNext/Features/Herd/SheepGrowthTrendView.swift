import Charts
import SwiftUI

enum SheepGrowthRange: String, CaseIterable, Identifiable {
    case quarter = "近三个月", half = "近半年", all = "全部", custom = "自定义"
    var id: String { rawValue }
}

struct SheepGrowthTrendView: View {
    let detail: SheepDetailSnapshot
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var range: SheepGrowthRange = .half
    @State private var selectedDate: Date?
    @State private var customStart = Date.now.addingTimeInterval(-180 * 86_400)
    @State private var customEnd = Date.now
    @State private var showsIntervals = false
    @State private var selectedMarkerID: String?
    @State private var showsExplanation = false

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: detail.timeZoneIdentifier) ?? .current
        return value
    }
    private var bounds: ClosedRange<Date> {
        let end = min(detail.factsReadAt, range == .custom ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd))!.addingTimeInterval(-0.001) : detail.factsReadAt)
        let start: Date = switch range {
        case .quarter: calendar.startOfDay(for: calendar.date(byAdding: .month, value: -3, to: end)!)
        case .half: calendar.startOfDay(for: calendar.date(byAdding: .month, value: -6, to: end)!)
        case .all: detail.canonicalWeights.first?.occurredAt ?? end
        case .custom: calendar.startOfDay(for: customStart)
        }
        return min(start, end)...end
    }
    private var points: [SheepDetailWeightSnapshot] { detail.canonicalWeights.filter { !(range == .custom && customStart > customEnd) && bounds.contains($0.occurredAt) } }
    private var intervals: [SheepDetailWeightGainSnapshot] {
        detail.weightGainIntervals.filter { !(range == .custom && customStart > customEnd) && bounds.contains($0.startDate) && bounds.contains($0.endDate) }
    }
    private var selected: SheepDetailWeightGainSnapshot? {
        guard let selectedDate else { return intervals.last }
        return intervals.min { abs($0.endDate.timeIntervalSince(selectedDate)) < abs($1.endDate.timeIntervalSince(selectedDate)) }
    }
    private var domain: ClosedRange<Date> {
        let lower = bounds.lowerBound
        return lower...max(bounds.upperBound, lower.addingTimeInterval(86_400))
    }
    private var markers: [SheepDetailTimelineEntry] { detail.timeline.filter { ($0.title == "转群" || $0.title == "用途变更") && bounds.contains($0.date) } }
    private var totalDays: Int { intervals.reduce(0) { $0 + $1.intervalDays } }
    private var meanGrams: Double? {
        totalDays > 0 ? intervals.reduce(0) { $0 + $1.totalGainKilograms } / Double(totalDays) * 1000 : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("体重与区间日增重").font(.headline)
            Picker("查看范围", selection: $range) {
                ForEach(SheepGrowthRange.allCases) { Text(verbatim: $0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            if range == .custom {
                DatePicker("开始日期", selection: $customStart, in: ...detail.factsReadAt, displayedComponents: .date)
                DatePicker("结束日期", selection: $customEnd, in: ...detail.factsReadAt, displayedComponents: .date)
                if customStart > customEnd { Text("开始日期晚于结束日期，请调整。").foregroundStyle(.orange) }
            }
            if points.isEmpty {
                ContentUnavailableView("此范围无体重记录", systemImage: "chart.xyaxis.line")
                if range != .all { Button("查看全部") { range = .all } }
            } else {
                weightChart
                if intervals.isEmpty {
                    Text("缺少另一日期的有效体重，所选范围暂不能计算日增重。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    gainChart
                    if let selected { intervalEvidence(selected) }
                    if let meanGrams {
                        LabeledContent("范围平均日增重", value: "\(meanGrams.formatted(.number.precision(.fractionLength(0)))) 克/天")
                    }
                    DisclosureGroup("全部区间（\(intervals.count)）", isExpanded: $showsIntervals) {
                        ForEach(intervals.reversed()) { interval in
                            Button { selectedDate = interval.endDate } label: { intervalEvidence(interval, showsSources: true) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if let marker = markers.first(where: { $0.id.uuidString == selectedMarkerID }) {
                    Text(verbatim: marker.title + " · " + marker.detail).font(.footnote).foregroundStyle(.secondary)
                }
                if !markers.isEmpty {
                    DisclosureGroup("期间生产事件") {
                        ForEach(markers) { entry in
                            Button { selectedDate = entry.date; selectedMarkerID = entry.id.uuidString } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: entry.title + " · " + entry.detail)
                                    Text(entry.date, format: .dateTime.year().month().day()).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            Button { showsExplanation = true } label: {
                HStack {
                    Text("图表说明")
                    Spacer()
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sheep-growth-explanation")
        }
        .onChange(of: range) { selectedDate = nil; selectedMarkerID = nil }
        .sheet(isPresented: $showsExplanation) {
            NavigationStack {
                SheepGrowthExplanationView(bounds: bounds, selected: selected, totalDays: totalDays, showsMean: meanGrams != nil)
            }
        }
        .environment(\.timeZone, calendar.timeZone)
        .accessibilityIdentifier("sheep-growth-trends")
    }

    private var weightChart: some View {
        Chart {
            ForEach(markers) { marker in
                RuleMark(x: .value("生产事件", marker.date)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [2, 4]))
            }
            ForEach(points) { point in
                LineMark(x: .value("称重日期", point.occurredAt), y: .value("体重（千克）", point.kilograms))
                    .interpolationMethod(.linear)
                PointMark(x: .value("称重日期", point.occurredAt), y: .value("体重（千克）", point.kilograms))
                    .symbolSize(selected.map { $0.startDate == point.occurredAt || $0.endDate == point.occurredAt } == true ? 70 : 25)
            }
            if let selected { RuleMark(x: .value("区间结束", selected.endDate)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4, 3])) }
        }
        .chartXScale(domain: domain).chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selectedDate)
        .chartGesture { proxy in SpatialTapGesture().onEnded { event in
            selectedMarkerID = nil
            proxy.selectXValue(at: event.location.x)
        } }
        .chartYAxis { sharedYAxis }.chartYAxisLabel("千克")
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 235 : 165)
        .accessibilityLabel("实测体重折线图，\(points.count) 个有效日期")
    }

    private var gainChart: some View {
        Chart {
            ForEach(markers) { marker in
                RuleMark(x: .value("生产事件", marker.date)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [2, 4]))
            }
            RuleMark(y: .value("零增重", 0)).foregroundStyle(.secondary)
            ForEach(intervals) { interval in
                LineMark(x: .value("区间结束日期", interval.endDate), y: .value("区间日增重（克/天）", interval.kilogramsPerDay * 1000))
                    .interpolationMethod(.linear).foregroundStyle(.orange)
                PointMark(x: .value("区间结束日期", interval.endDate), y: .value("区间日增重（克/天）", interval.kilogramsPerDay * 1000))
                    .symbolSize(selected?.id == interval.id ? 70 : 25).foregroundStyle(.orange)
            }
            if let selected { RuleMark(x: .value("区间结束", selected.endDate)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4, 3])) }
        }
        .chartXScale(domain: domain).chartXSelection(value: $selectedDate)
        .chartGesture { proxy in SpatialTapGesture().onEnded { event in
            selectedMarkerID = nil
            proxy.selectXValue(at: event.location.x)
        } }
        .chartYAxis { sharedYAxis }.chartYAxisLabel("克/天")
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 215 : 145)
        .accessibilityLabel("区间日增重折线图，\(intervals.count) 个真实区间，保留零和负增重")
    }

    private var sharedYAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(number, format: .number.precision(.fractionLength(0)))
                        .lineLimit(1).minimumScaleFactor(0.6).frame(width: 52, alignment: .leading)
                }
            }
        }
    }

    private func intervalEvidence(_ value: SheepDetailWeightGainSnapshot, showsSources: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value.startDate, format: .dateTime.year().month().day()) → \(value.endDate, format: .dateTime.year().month().day()) · \(value.intervalDays) 天")
                .font(.subheadline)
            Text(verbatim: "\(WeightPrecision.displayText(value.startKilogramsText)) → \(WeightPrecision.displayText(value.endKilogramsText)) 千克 · 增重 \(value.totalGainKilograms.formatted(.number.precision(.fractionLength(2)))) 千克")
            Text("区间日增重 \((value.kilogramsPerDay * 1000).formatted(.number.precision(.fractionLength(0)))) 克/天")
                .font(.headline).monospacedDigit()
            if showsSources {
                Text(verbatim: "来源：\(value.startSource.displayName) → \(value.endSource.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

private struct SheepGrowthExplanationView: View {
    @Environment(\.dismiss) private var dismiss
    let bounds: ClosedRange<Date>
    let selected: SheepDetailWeightGainSnapshot?
    let totalDays: Int
    let showsMean: Bool

    var body: some View {
        List {
            Section("统计日期") {
                Text("\(bounds.lowerBound, format: .dateTime.year().month().day())—\(bounds.upperBound, format: .dateTime.year().month().day())")
            }
            if let selected {
                Section("所选区间来源") {
                    Text("\(selected.startDate, format: .dateTime.year().month().day()) → \(selected.endDate, format: .dateTime.year().month().day())")
                    Text(verbatim: "\(selected.startSource.displayName) → \(selected.endSource.displayName)")
                }
            }
            if showsMean {
                Section("平均日增重") {
                    Text("按有效区间总增重除以总观察天数计算，各区间按真实天数计入。")
                    LabeledContent("本范围有效观察", value: "\(totalDays) 天")
                }
            }
            Section("曲线与圈舍口径") {
                Text("日增重点代表两次称重之间的平均表现。连线只表示趋势，不代表每天均有测量。")
                Text("跨舍区间不归因为某一圈舍的独立贡献。")
            }
        }
        .navigationTitle("图表说明")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }
}
