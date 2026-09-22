import ESMotion
import SwiftData
import SwiftUI

struct FarmEventEntryLink: View {
    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        NavigationLink {
            FarmEventHistoryView(account: account, farm: farm)
        } label: {
            StatusRow(title: "事件记录", detail: "查阅、筛选和导出牧场历史", symbol: "clock.arrow.circlepath")
        }
        .buttonStyle(MotionSurfaceButtonStyle())
        .accessibilityIdentifier("farm-event-history-entry")
    }
}

struct FarmWorkbenchView: View {
    @Environment(AppSession.self) private var session
    let account: AccountProfile
    let farm: FarmRecord
    let farms: [FarmRecord]
    let sharedFarmAdmissionStatus: SharedFarmAdmissionStatus?
    @State private var presentedEntry: PendingRecordEntry?
    @State private var reminderID: UUID?

    private let productionActions: [HomeQuickAction] = [.addSheep, .weight, .health, .note, .transfer, .weaning, .removal, .reproduction, .lambing]
    private let feedingActions: [HomeQuickAction] = [.tmrFeeding, .feed, .trough, .tmrProduction]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        FarmEventEntryLink(account: account, farm: farm)
                        management.id(WorkbenchSection.management)
                        actionCard("生产记录", actions: productionActions).id(WorkbenchSection.records)
                        feeding.id(WorkbenchSection.feeding)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .background(AppTheme.pageBackground)
                .onChange(of: session.workbenchSection) { _, section in
                    if session.pendingRecordEntry == nil { proxy.scrollTo(section, anchor: .top) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { FarmNavigationToolbar(account: account, farms: farms, activeFarm: farm, sharedFarmAdmissionStatus: sharedFarmAdmissionStatus) }
            .sheet(item: $presentedEntry) { entry in
                NavigationStack { ProductionEntryDestination(entry: entry, account: account, farm: farm) }
            }
            .navigationDestination(isPresented: Binding(get: { reminderID != nil }, set: { if !$0 { reminderID = nil } })) {
                CareReminderCenterView(account: account, farm: farm, focusedReminderID: reminderID)
            }
            .onAppear(perform: consumeNavigation)
            .onChange(of: session.pendingRecordEntry) { _, _ in consumeNavigation() }
            .onChange(of: session.pendingCareReminderID) { _, _ in consumeNavigation() }
        }
    }

    private var management: some View {
        SettingsCard(title: "管理") {
            SettingsNavigationRow(title: "羊只标签", subtitle: "新建标签、设置颜色、查看关联羊只", systemImage: "tag", iconColor: .orange) {
                SheepLabelManagementView(account: account, farm: farm)
            }
            .accessibilityIdentifier("workbench-sheep-labels")
            SettingsCardDivider()
            SettingsNavigationRow(title: "生产批次", subtitle: "育肥、实验等批次", systemImage: "square.3.layers.3d", iconColor: .purple) {
                ProductionBatchListView(account: account, farm: farm)
            }
            SettingsCardDivider()
            SettingsNavigationRow(title: "健康与繁殖管理", subtitle: "目录、库存、方案与提醒", systemImage: "heart.text.square", iconColor: .pink) {
                CareManagementView(account: account, farm: farm)
            }
            SettingsCardDivider()
            SettingsNavigationRow(title: "原料库与库存", systemImage: "shippingbox", iconColor: .orange) {
                IngredientLibraryView(account: account, farm: farm)
            }
            SettingsCardDivider()
            SettingsNavigationRow(title: "TMR 配方", systemImage: "list.bullet.clipboard", iconColor: .green) {
                TMRFormulaLibraryView(account: account, farm: farm)
            }
            SettingsCardDivider()
            SettingsNavigationRow(title: "TMR 投喂计划", systemImage: "calendar", iconColor: .blue) {
                TMRFeedingPlanLibraryView(account: account, farm: farm)
            }
            SettingsCardDivider()
            SettingsNavigationRow(title: "TMR 批次", systemImage: "list.bullet.rectangle", iconColor: .teal) {
                TMRBatchLibraryView(account: account, farm: farm)
            }
        }
    }

    private func actionCard(_ title: String, actions: [HomeQuickAction]) -> some View {
        SettingsCard(title: title) { actionRows(actions) }
    }

    private func actionRows(_ actions: [HomeQuickAction]) -> some View {
        ForEach(actions) { action in
            if let entry = action.entry {
                SettingsActionRow(title: action.title, systemImage: action.symbol, iconColor: action.workbenchIconColor) {
                    presentedEntry = entry
                }
                if action != actions.last { SettingsCardDivider() }
            }
        }
    }

    private var feeding: some View {
        SettingsCard(title: "投喂") {
            actionRows(feedingActions)
            SettingsCardDivider()
            WorkbenchPendingTroughRow(account: account, farm: farm)
            SettingsCardDivider()
            SettingsNavigationRow(title: "TMR 执行情况", systemImage: "chart.bar.doc.horizontal", iconColor: .indigo) {
                TMRMonitoringView(account: account, farm: farm)
            }
            SettingsCardDivider()
            SettingsNavigationRow(title: "投喂与盘槽历史", systemImage: "clock.arrow.circlepath", iconColor: .gray) {
                FeedHistoryView(account: account, farm: farm)
            }
            SettingsCardDivider()
            SettingsNavigationRow(title: "采食营养分析", systemImage: "chart.bar.xaxis", iconColor: .purple) {
                FarmAnalyticsView(farm: farm)
            }
        }
    }

    private func consumeNavigation() {
        if let entry = session.pendingRecordEntry {
            session.pendingRecordEntry = nil
            presentedEntry = entry
        }
        if let pending = session.pendingCareReminderID {
            session.pendingCareReminderID = nil
            reminderID = pending
        }
    }
}

private extension HomeQuickAction {
    var workbenchIconColor: Color {
        switch self {
        case .addSheep, .feed: .green
        case .weight, .exportEvents: .blue
        case .health: .red
        case .note: .gray
        case .transfer: .indigo
        case .weaning, .tmrFeeding: .teal
        case .removal, .trough: .orange
        case .reproduction: .pink
        case .lambing: .purple
        case .tmrProduction: .brown
        }
    }
}

private struct WorkbenchPendingTroughRow: View {
    @Environment(\.modelContext) private var context
    let account: AccountProfile
    let farm: FarmRecord
    @State private var count: Int?
    @State private var failure = false
    @State private var revision = 0

    var body: some View {
        SettingsNavigationRow(
            title: "待盘槽",
            subtitle: failure ? "暂时无法读取，点击重新查看" : count.map { "\($0) 项待处理" } ?? "正在读取",
            systemImage: "checklist", iconColor: .orange
        ) {
            PendingTroughListView(account: account, farm: farm)
        }
        .task(id: revision) {
            do {
                let snapshot = try await FeedingOverviewSnapshotActor(container: context.container).load(farmID: farm.id)
                try Task.checkCancellation()
                count = snapshot.pendingTroughCount
                failure = false
            } catch is CancellationError { }
            catch { failure = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in revision &+= 1 }
    }
}
