import SwiftData
import SwiftUI

struct FarmHomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    @Query(sort: \PenRecord.name) private var pens: [PenRecord]
    @Query(sort: \FeedRecord.occurredAt, order: .reverse) private var feedRecords: [FeedRecord]
    @Query(sort: \HealthRecord.occurredAt, order: .reverse) private var healthRecords: [HealthRecord]
    @Query(sort: \OutboxItem.createdAt, order: .reverse) private var outboxItems: [OutboxItem]

    let account: AccountProfile
    let farm: FarmRecord
    @State private var testGenerationProgress: TestFarmGenerationProgress?
    @State private var testGenerationError: String?

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.status == .active } }
    private var farmPens: [PenRecord] { pens.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive } }
    private var todayFeedCount: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return feedRecords.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.occurredAt >= start }.count
    }
    private var pendingOutboxCount: Int { outboxItems.filter { $0.farmID == farm.id && $0.statusRawValue == "pending" }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                #if DEBUG
                if farmSheep.isEmpty && farmPens.isEmpty && !farm.isDevelopmentTestFarm && !farm.isLocalOnlyMigration {
                    localTestDataCard
                }
                #endif
                metrics
                shortcuts
                productionStatus
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .alert("无法生成测试数据", isPresented: Binding(
            get: { testGenerationError != nil },
            set: { if !$0 { testGenerationError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(testGenerationError ?? "")
        }
    }

    #if DEBUG
    private var localTestDataCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("建立本机验收数据", systemImage: "hammer")
                    .font(.headline)
                Text("不需要先迁移生产数据或启用 CloudKit。系统将在当前测试牧场生成 100 只羊、10 个圈舍、500 条生产事件和 50 张测试图片。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let progress = testGenerationProgress {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                        Text(progress.stage)
                    } currentValueLabel: {
                        Text("\(progress.completed)/\(progress.total)")
                    }
                } else {
                    Button("生成测试数据") {
                        generateLocalTestData()
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func generateLocalTestData() {
        testGenerationProgress = .init(completed: 0, total: 660, stage: "正在准备")
        Task {
            do {
                _ = try await collaboration.testFarmGenerator.generate(
                    farmID: farm.id,
                    accountID: account.effectiveAccountID
                ) { progress in
                    await MainActor.run { testGenerationProgress = progress }
                }
                testGenerationProgress = nil
            } catch {
                testGenerationProgress = nil
                testGenerationError = error.localizedDescription
            }
        }
    }
    #endif

    private var hero: some View {
        FarmWeatherHero(
            farm: farm,
            syncSymbol: pendingOutboxCount == 0 ? "checkmark.icloud" : "arrow.triangle.2.circlepath.icloud",
            syncText: pendingOutboxCount == 0 ? "本地记录已排队处理" : "有 \(pendingOutboxCount) 条本地记录等待同步"
        )
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            HomeMetric(title: "在场羊只", value: "\(farmSheep.count)", symbol: "pawprint.fill")
            HomeMetric(title: "启用圈舍", value: "\(farmPens.count)", symbol: "building.2")
            HomeMetric(title: "今日投喂", value: "\(todayFeedCount)", symbol: "leaf")
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷操作").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                HomeShortcut(title: "新建羊只", symbol: "plus.circle") { session.selectedTab = .records }
                HomeShortcut(title: "称重", symbol: "scalemass") { session.selectedTab = .records }
                HomeShortcut(title: "转群", symbol: "arrow.left.arrow.right") { session.selectedTab = .records }
                HomeShortcut(title: "投喂", symbol: "leaf") { session.selectedTab = .feeding }
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
                StatusRow(title: "圈舍管理", detail: "当前 \(farmPens.count) 个启用圈舍", symbol: "building.2")
            }
            NavigationLink { FarmAnalysisCenterView(farm: farm) } label: {
                StatusRow(title: "牧场分析", detail: "增重、羔羊、繁殖与采食", symbol: "chart.bar.xaxis")
            }
            if healthRecords.contains(where: { $0.farmID == farm.id && $0.deletedAt == nil }) {
                StatusRow(title: "健康记录", detail: "已有 \(healthRecords.filter { $0.farmID == farm.id && $0.deletedAt == nil }.count) 条记录", symbol: "cross.case")
            }
        }
    }
}

private struct HomeMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(AppTheme.brand)
                Text(value).font(.title3.bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
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
