import ESMotion
import SwiftData
import SwiftUI

struct FarmHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \FeedRecord.occurredAt, order: .reverse) private var feedRecords: [FeedRecord]
    @Query(sort: \HealthRecord.occurredAt, order: .reverse) private var healthRecords: [HealthRecord]
    @Query(sort: \CareReminderRecord.dueAt) private var careReminders: [CareReminderRecord]

    let account: AccountProfile
    let farm: FarmRecord
    @Binding var isWeatherDetailPresented: Bool
    @Binding var isMetricDetailPresented: Bool
    @State private var pendingOutboxCount = 0
    @State private var selectedMetric: HomeMetricDestination?
    @State private var isEventExportPresented = false
    @Namespace private var metricTransition

    init(
        account: AccountProfile,
        farm: FarmRecord,
        isWeatherDetailPresented: Binding<Bool>,
        isMetricDetailPresented: Binding<Bool>
    ) {
        self.account = account
        self.farm = farm
        _isWeatherDetailPresented = isWeatherDetailPresented
        _isMetricDetailPresented = isMetricDetailPresented
        let farmID = farm.id
        _sheep = Query(
            filter: #Predicate<SheepRecord> {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sort: \.earTag
        )
        _pens = Query(
            filter: #Predicate<PenRecord> {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sort: \.name
        )
        _feedRecords = Query(
            filter: #Predicate<FeedRecord> {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sort: \.occurredAt,
            order: .reverse
        )
        _healthRecords = Query(
            filter: #Predicate<HealthRecord> { $0.farmID == farmID },
            sort: \.occurredAt,
            order: .reverse
        )
        _careReminders = Query(
            filter: #Predicate<CareReminderRecord> { $0.farmID == farmID },
            sort: \.dueAt
        )
    }

    private var farmSheep: [SheepRecord] { sheep.filter(\.isCurrentlyPresent) }
    private var farmPens: [PenRecord] { CurrentFarmOccupancy.occupiedPens(farmID: farm.id, sheep: sheep, pens: pens) }
    private var canExport: Bool { CapabilitySet(role: farm.role).allows(.exportFarm) }
    private var todayFeedCount: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return feedRecords.count { $0.occurredAt >= start }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                metrics
                shortcuts
                careReminderStatus
                productionStatus
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .navigationDestination(item: $selectedMetric) { destination in
            metricDestination(destination)
                .motionTransitionDestination(
                    id: MotionTransitionID(destination.id),
                    in: metricTransition,
                    spec: metricTransitionSpec
                )
                .toolbarVisibility(.hidden, for: .tabBar)
        }
        .onChange(of: selectedMetric) { _, destination in
            isMetricDetailPresented = destination != nil
        }
        .onDisappear {
            if selectedMetric == nil {
                isMetricDetailPresented = false
            }
        }
        .sheet(isPresented: $isEventExportPresented) {
            FarmEventExportLauncher(farmID: farm.id, farmName: farm.name)
                .presentationDetents([.large])
        }
        .task(id: farm.id) {
            let farmID = farm.id
            let pending = OutboxStatus.pending.rawValue
            let retryable = OutboxStatus.retryableFailure.rawValue
            let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate {
                $0.farmID == farmID && ($0.statusRawValue == pending || $0.statusRawValue == retryable)
            })
            pendingOutboxCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        }
    }

    private var hero: some View {
        FarmWeatherHero(
            farm: farm,
            syncSymbol: pendingOutboxCount == 0 ? "checkmark.icloud" : "arrow.triangle.2.circlepath.icloud",
            syncText: CloudFeatureConfiguration.isEnabled
                ? (pendingOutboxCount == 0 ? "本地记录已排队处理" : "有 \(pendingOutboxCount) 条本地记录等待同步")
                : "业务数据已保存在本机",
            isDetailPresented: $isWeatherDetailPresented
        )
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metricButton(.sheep, value: farmSheep.count)
            metricButton(.pens, value: farmPens.count)
            metricButton(.feeding, value: todayFeedCount)
        }
    }

    private func metricButton(_ destination: HomeMetricDestination, value: Int) -> some View {
        Button {
            selectedMetric = destination
        } label: {
            HomeMetric(title: destination.title, value: "\(value)", symbol: destination.symbol)
                .contentShape(.rect(cornerRadius: 20))
                .motionTransitionSource(
                    id: MotionTransitionID(destination.id),
                    in: metricTransition,
                    spec: metricTransitionSpec,
                    background: AppTheme.pageBackground
                )
        }
        .buttonStyle(MotionSurfaceButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(destination.title)，\(value)")
        .accessibilityHint("打开完整页面")
    }

    private var metricTransitionSpec: MotionTransitionSpec {
        MotionTransitionSpec(
            preset: .listItem,
            cornerRadius: 20
        )
    }

    @ViewBuilder
    private func metricDestination(_ destination: HomeMetricDestination) -> some View {
        switch destination {
        case .sheep:
            HerdManagementView(account: account, farm: farm)
                .navigationTitle("在场羊只")
        case .pens:
            PenManagementView(account: account, farm: farm)
                .navigationTitle("有羊圈舍")
        case .feeding:
            TodayFeedDetailView(farm: farm)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷操作").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                HomeShortcut(title: "新建羊只", symbol: "plus.circle") { session.requestRecordEntry(.addSheep) }
                HomeShortcut(title: "称重", symbol: "scalemass") { session.requestRecordEntry(.weight) }
                HomeShortcut(title: "转群", symbol: "arrow.left.arrow.right") { session.requestRecordEntry(.transfer) }
                HomeShortcut(title: "离场", symbol: "person.crop.circle.badge.minus") { session.requestRecordEntry(.removal) }
                HomeShortcut(title: "投喂", symbol: "leaf") { session.selectedTab = .feeding }
                HomeShortcut(title: "记录导出", symbol: "square.and.arrow.up") {
                    isEventExportPresented = true
                }
                .disabled(!canExport)
                .opacity(canExport ? 1 : 0.5)
                .accessibilityHint(canExport ? "选择记录类型和发生时间范围" : "当前牧场角色没有导出权限")
            }
        }
    }

    private var productionStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("生产状态").font(.headline)
            NavigationLink { HerdManagementView(account: account, farm: farm) } label: {
                StatusRow(title: "羊只档案", detail: "查看羊只档案、体重与时间线", symbol: "list.bullet")
            }
            NavigationLink { PenManagementView(account: account, farm: farm) } label: {
                StatusRow(title: "圈舍管理", detail: "当前 \(farmPens.count) 个圈舍有在场羊", symbol: "building.2")
            }
            let activeHealthRecordCount = healthRecords.count { $0.deletedAt == nil }
            if activeHealthRecordCount > 0 {
                StatusRow(title: "健康记录", detail: "已有 \(activeHealthRecordCount) 条记录", symbol: "cross.case")
            }
        }
    }

    private var careReminderStatus: some View {
        let start = Calendar.current.startOfDay(for: .now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? .distantFuture
        let end = Calendar.current.date(byAdding: .day, value: 8, to: start) ?? .distantFuture
        let pending = careReminders.filter { $0.deletedAt == nil && $0.status == .pending && $0.dueAt < end }
        let overdue = pending.count { $0.dueAt < start }
        let today = pending.count { $0.dueAt >= start && $0.dueAt < tomorrow }
        return VStack(alignment: .leading, spacing: 10) {
            Text("关键提醒").font(.headline)
            NavigationLink { CareReminderCenterView(account: account, farm: farm, focusedReminderID: nil) } label: {
                StatusRow(title: "今日、逾期与未来七日", detail: "逾期 \(overdue) · 今日 \(today) · 七日内 \(pending.count)", symbol: overdue > 0 ? "bell.badge.fill" : "bell")
            }
        }
    }
}

private enum HomeMetricDestination: String, Hashable, Identifiable {
    case sheep
    case pens
    case feeding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sheep: "在场羊只"
        case .pens: "有羊圈舍"
        case .feeding: "今日投喂"
        }
    }

    var symbol: String {
        switch self {
        case .sheep: "tag.fill"
        case .pens: "building.2"
        case .feeding: "leaf"
        }
    }
}

private struct HomeMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(AppTheme.brand)
            Text(value).font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity)
    }
}

private struct TodayFeedDetailView: View {
    @Query(sort: \FeedRecord.occurredAt, order: .reverse) private var feedRecords: [FeedRecord]
    @Query private var feedLines: [FeedRecordLine]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]

    let farm: FarmRecord

    private var todayFeedRecords: [FeedRecord] {
        let start = Calendar.current.startOfDay(for: .now)
        return feedRecords.filter {
            $0.farmID == farm.id && $0.deletedAt == nil && $0.occurredAt >= start
        }
    }

    private var penNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: pens.lazy.filter { $0.farmID == farm.id }.map { ($0.id, $0.name) })
    }

    var body: some View {
        List {
            ForEach(todayFeedRecords, id: \.id) { feed in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(penNames[feed.penID] ?? "已删除圈舍")
                            .font(.headline)
                        Spacer()
                        Text(feed.occurredAt, format: .dateTime.hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(feedSummary(feed))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !feed.note.isEmpty {
                        Text(feed.note)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .overlay {
            if todayFeedRecords.isEmpty {
                ContentUnavailableView(
                    "今日暂无投喂",
                    systemImage: "leaf",
                    description: Text("今天记录的投喂会显示在这里。")
                )
            }
        }
        .navigationTitle("今日投喂")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func feedSummary(_ feed: FeedRecord) -> String {
        let lineCount = feedLines.lazy.filter {
            $0.farmID == farm.id && $0.feedRecordID == feed.id && $0.deletedAt == nil
        }.count
        let meal = feed.mealName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = meal.isEmpty ? feed.mode.displayName : meal
        return "\(prefix) · \(lineCount) 种原料"
    }
}

private struct HomeShortcut: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol)
                Text(title)
                Spacer()
            }
            .padding(14)
            .background(.background, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(AppTheme.brand).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 16))
    }
}
