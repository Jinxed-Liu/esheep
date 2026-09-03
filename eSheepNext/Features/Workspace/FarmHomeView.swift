import ESMotion
import SwiftData
import SwiftUI

struct FarmHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Environment(FarmNotificationService.self) private var notifications
    @Query private var storageProfiles: [FarmStorageProfile]
    @Query private var cloudFarmStates: [ESheepCloudFarmState]
    @Query private var cloudIntents: [ESheepCloudPendingIntent]
    @Query private var cloudAttentionItems: [ESheepCloudAttentionItem]

    let account: AccountProfile
    let farm: FarmRecord
    @Binding var isWeatherDetailPresented: Bool
    @Binding var isMetricDetailPresented: Bool
    let sharedFarmAdmissionStatus: SharedFarmAdmissionStatus?
    @State private var selectedMetric: HomeMetricDestination?
    @State private var isEventExportPresented = false
    @State private var operationalAlertState: FarmOperationalAlertLoadState = .loading
    @State private var operationalAlertRefreshRevision = 0
    @State private var homeSnapshot = FarmHomeSnapshot.empty
    @State private var homeSnapshotRefreshRevision = 0
    @State private var isOperationalAlertCenterPresented = false
    @Namespace private var metricTransition

    init(
        account: AccountProfile,
        farm: FarmRecord,
        isWeatherDetailPresented: Binding<Bool>,
        isMetricDetailPresented: Binding<Bool>,
        sharedFarmAdmissionStatus: SharedFarmAdmissionStatus?
    ) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _storageProfiles = Query(
            filter: #Predicate<FarmStorageProfile> { $0.farmID == farmID }
        )
        _cloudFarmStates = Query(
            filter: #Predicate<ESheepCloudFarmState> { $0.farmID == farmID }
        )
        _cloudIntents = Query(
            filter: #Predicate<ESheepCloudPendingIntent> { $0.farmID == farmID }
        )
        _cloudAttentionItems = Query(
            filter: #Predicate<ESheepCloudAttentionItem> { $0.farmID == farmID }
        )
        _isWeatherDetailPresented = isWeatherDetailPresented
        _isMetricDetailPresented = isMetricDetailPresented
        self.sharedFarmAdmissionStatus = sharedFarmAdmissionStatus
    }

    private var canExport: Bool { CapabilitySet(role: farm.role).allows(.exportFarm) }
    private var canManageAlertRules: Bool { CapabilitySet(role: farm.role).allows(.manageCatalogs) }
    private var usesESheepCloudV2: Bool {
        storageProfiles.first(where: { $0.farmID == farm.id })?.mode == .eSheepCloud
    }
    private var activeCloudState: ESheepCloudFarmState? {
        cloudFarmStates
            .filter { $0.farmID == farm.id }
            .max { $0.farmGeneration < $1.farmGeneration }
    }
    private var activeCloudGeneration: Int? {
        activeCloudState?.farmGeneration
    }
    private var cloudAttentionCount: Int {
        guard let activeCloudGeneration else { return 0 }
        return cloudAttentionItems.count {
            $0.farmID == farm.id &&
                $0.farmGeneration == activeCloudGeneration &&
                ($0.state == .open || $0.state == .resolving)
        }
    }
    private var cloudWaitingCount: Int {
        guard let activeCloudGeneration else { return 0 }
        return cloudIntents.count {
            $0.farmID == farm.id &&
                $0.farmGeneration == activeCloudGeneration &&
                $0.accountID == account.effectiveAccountID &&
                !$0.lifecycle.isTerminal &&
                $0.lifecycle != .needsConfirmation
        }
    }
    private var cloudIsSafelySaved: Bool {
        guard let state = activeCloudState else { return false }
        return state.activityState == .active &&
            state.integrityState == .passed &&
            state.lastAppliedEventSequence >= state.cloudEventHead &&
            state.lastSafeSaveAt != nil &&
            cloudWaitingCount == 0
    }
    private var cloudNeedsAttentionFromService: Bool {
        guard let state = activeCloudState else { return false }
        return state.activityState == .integrityHold ||
            state.activityState == .accessRevoked ||
            state.integrityState == .failed
    }
    private var homeSnapshotTaskID: String {
        "\(farm.id.uuidString.lowercased()):\(homeSnapshotRefreshRevision)"
    }
    private var operationalAlertTaskID: String {
        "\(farm.id.uuidString.lowercased()):\(operationalAlertRefreshRevision)"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                metrics
                operationalAlertCard
                shortcuts
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
        .navigationDestination(isPresented: $isOperationalAlertCenterPresented) {
            FarmOperationalAlertCenterView(account: account, farm: farm)
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
        .task(id: homeSnapshotTaskID) {
            await loadHomeSnapshot()
        }
        .task(id: operationalAlertTaskID) {
            await loadOperationalAlerts()
        }
        .onReceive(NotificationCenter.default.publisher(for: FarmOperationalAlertRuntimeNotification.refreshRequested)) { notification in
            guard FarmOperationalAlertRuntimeNotification.farmID(from: notification) == farm.id else { return }
            homeSnapshotRefreshRevision &+= 1
            operationalAlertRefreshRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudRuntimeNotification.syncWake)) { notification in
            guard CloudRuntimeNotification.farmID(from: notification) == farm.id else { return }
            homeSnapshotRefreshRevision &+= 1
            operationalAlertRefreshRevision &+= 1
        }
        .onChange(of: session.pendingOperationalAlertsRequestID, initial: true) { _, requestID in
            guard requestID != nil else { return }
            session.pendingOperationalAlertsRequestID = nil
            isOperationalAlertCenterPresented = true
        }
    }

    private var hero: some View {
        FarmWeatherHero(
            farm: farm,
            syncSymbol: homeSyncSymbol,
            syncAccessibilityLabel: homeSyncAccessibilityLabel,
            isDetailPresented: $isWeatherDetailPresented
        )
    }

    private var homeSyncSymbol: String {
        if sharedFarmAdmissionStatus != nil {
            return "person.2.badge.gearshape"
        }
        if usesESheepCloudV2 {
            if cloudAttentionCount > 0 {
                return "exclamationmark.bubble.fill"
            }
            if cloudNeedsAttentionFromService {
                return "exclamationmark.triangle.fill"
            }
            return cloudIsSafelySaved
                ? "checkmark.circle.fill"
                : "arrow.triangle.2.circlepath"
        }
        if homeSnapshot.conflictOutboxCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        return homeSnapshot.pendingOutboxCount == 0
            ? "checkmark.circle.fill"
            : "arrow.triangle.2.circlepath"
    }

    private var homeSyncAccessibilityLabel: LocalizedStringKey {
        if let sharedFarmAdmissionStatus {
            return "正在加入共享牧场 · \(sharedFarmAdmissionStatus.detailText)"
        }
        if usesESheepCloudV2 {
            if cloudAttentionCount > 0 {
                return "有 \(cloudAttentionCount) 项内容需要你确认"
            }
            if cloudNeedsAttentionFromService {
                return "部分内容尚未保存，请稍后再试"
            }
            if cloudIsSafelySaved {
                return "业务数据已安全保存"
            }
            return cloudWaitingCount > 0
                ? "有 \(cloudWaitingCount) 项内容等待保存"
                : "正在检查牧场资料是否完整"
        }
        if homeSnapshot.conflictOutboxCount > 0 {
            return "有 \(homeSnapshot.conflictOutboxCount) 条数据异常等待处理"
        }
        return homeSnapshot.pendingOutboxCount == 0
            ? "业务数据已保存"
            : "有 \(homeSnapshot.pendingOutboxCount) 条本地记录等待保存"
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metricButton(.sheep, value: homeSnapshot.activeSheepCount)
            metricButton(.pens, value: homeSnapshot.occupiedPenCount)
            metricButton(.feeding, value: homeSnapshot.todayFeedCount)
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

    private var operationalAlertCard: some View {
        FarmOperationalAlertHomeCard(
            state: operationalAlertState,
            canManageRules: canManageAlertRules,
            onOpen: { isOperationalAlertCenterPresented = true },
            onRetry: { operationalAlertRefreshRevision &+= 1 }
        )
    }

    private var productionStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("生产状态").font(.headline)
            NavigationLink { HerdManagementView(account: account, farm: farm) } label: {
                StatusRow(title: "羊只档案", detail: "查看羊只档案、体重与时间线", symbol: "list.bullet")
            }
            NavigationLink { PenManagementView(account: account, farm: farm) } label: {
                StatusRow(
                    title: "圈舍管理",
                    detail: "当前 \(homeSnapshot.occupiedPenCount) 个圈舍有在场羊",
                    symbol: "building.2"
                )
            }
            if homeSnapshot.activeHealthRecordCount > 0 {
                StatusRow(title: "健康记录", detail: "已有 \(homeSnapshot.activeHealthRecordCount) 条记录", symbol: "cross.case")
            }
        }
    }

    @MainActor
    private func loadHomeSnapshot() async {
        do {
            let snapshot = try await FarmHomeSnapshotActor(container: modelContext.container)
                .load(farmID: farm.id)
            try Task.checkCancellation()
            homeSnapshot = snapshot
        } catch is CancellationError {
            return
        } catch {
            // Keep the last valid counters visible. A retry is triggered by
            // the next local command or cloud-sync notification.
        }
    }

    @MainActor
    private func loadOperationalAlerts() async {
        let isInitialLoad: Bool
        if case .loaded = operationalAlertState {
            // Keep the last valid snapshot visible while a refresh is running.
            isInitialLoad = false
        } else {
            operationalAlertState = .loading
            isInitialLoad = true
        }
        do {
            // The alert snapshot spans several historical record types. Let
            // navigation and the lightweight home counters settle first.
            if isInitialLoad {
                try await Task.sleep(for: .milliseconds(1_200))
            }
            let actor = FarmOperationalAlertSnapshotActor(container: modelContext.container)
            let snapshot = try await actor.load(farmID: farm.id)
            try Task.checkCancellation()
            operationalAlertState = .loaded(snapshot)
            await notifications.rescheduleOperationalAlertDigest(snapshot)
        } catch is CancellationError {
            return
        } catch {
            operationalAlertState = .failed(error.localizedDescription)
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
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity)
    }
}

private struct TodayFeedDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let farm: FarmRecord
    @State private var rows: [TodayFeedRowSnapshot] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        List {
            ForEach(rows) { feed in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(feed.penName)
                            .font(.headline)
                        Spacer()
                        Text(feed.occurredAt, format: .dateTime.hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if feed.mealName.isEmpty {
                        HStack(spacing: 0) {
                            Text(LocalizedStringKey(feed.mode.displayName))
                            Text(" · \(feed.ingredientCount) 种原料")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("\(feed.mealName) · \(feed.ingredientCount) 种原料")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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
            if isLoading {
                ProgressView("正在整理今日投喂")
            } else if let loadError {
                ContentUnavailableView("读取失败", systemImage: "exclamationmark.triangle", description: Text(LocalizedStringKey(loadError)))
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "今日暂无投喂",
                    systemImage: "leaf",
                    description: Text("今天记录的投喂会显示在这里。")
                )
            }
        }
        .navigationTitle("今日投喂")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: farm.id) { await loadRows() }
    }

    @MainActor
    private func loadRows() async {
        isLoading = true
        loadError = nil
        do {
            let updatedRows = try await TodayFeedSnapshotActor(container: modelContext.container)
                .load(farmID: farm.id)
            try Task.checkCancellation()
            rows = updatedRows
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            isLoading = false
        }
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
                Text(LocalizedStringKey(title))
                Spacer()
            }
            .padding(14)
            .background(.background, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct StatusRow: View {
    let title: String
    let detail: LocalizedStringKey
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(AppTheme.brand).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 16))
    }
}
