import SwiftUI

struct SharedFarmAdmissionStatus: Equatable {
    let detailText: String
}

struct FarmWorkspaceView: View {
    @Environment(AppSession.self) private var session
    @State private var searchQuery = ""
    @State private var isWeatherDetailPresented = false
    @State private var isMetricDetailPresented = false
    @State private var assistantFarmID: UUID?

    let account: AccountProfile
    let farms: [FarmRecord]
    let sharedFarmAdmissionStatus: SharedFarmAdmissionStatus?

    private var activeFarm: FarmRecord? {
        farms.first(where: { $0.id == session.selectedFarmID }) ?? farms.first
    }

    var body: some View {
        if let activeFarm {
            workspaceTabs(for: activeFarm)
            .id(activeFarm.id)
            .safeAreaInset(edge: .top, spacing: 0) {
                AccountAccessWorkspaceBanner(
                    authenticationMethod: account.authenticationMethod
                )
            }
#if DEBUG
            .onAppear {
                guard InsightAcceptanceLaunchRequest.prompt != nil else { return }
                session.selectedTab = .assistant
                assistantFarmID = activeFarm.id
            }
#endif
            .onChange(of: activeFarm.id) { previousFarmID, currentFarmID in
                guard previousFarmID != currentFarmID else { return }
                assistantFarmID = nil
                searchQuery = ""
                isWeatherDetailPresented = false
                isMetricDetailPresented = false
                session.resetWorkspaceNavigation()
            }
            .onChange(of: session.pendingSearchQuery, initial: true) { _, pendingQuery in
                guard let pendingQuery else { return }
                searchQuery = pendingQuery
                session.pendingSearchQuery = nil
            }
        }
    }

    @ViewBuilder
    private func workspaceTabs(for farm: FarmRecord) -> some View {
        @Bindable var session = session

        if #available(iOS 18, *) {
            TabView(selection: $session.selectedTab) {
                Tab("首页", systemImage: "house", value: .home) {
                    homeNavigationStack(for: farm)
                }
                Tab("工作台", systemImage: "square.grid.2x2", value: .workbench) {
                    workbench(for: farm)
                }
                Tab("分析", systemImage: "sparkles", value: .analysis) {
                    analysisNavigationStack(for: farm)
                }
                Tab(value: .search, role: .search) {
                    searchNavigationStack(for: farm, query: $searchQuery)
                }
            }
            .modifier(FarmWorkspaceSearchActivation())
        } else {
            TabView(selection: $session.selectedTab) {
                homeNavigationStack(for: farm)
                    .tabItem { Label("首页", systemImage: "house") }
                    .tag(AppTab.home)
                workbench(for: farm)
                    .tabItem { Label("工作台", systemImage: "square.grid.2x2") }
                    .tag(AppTab.workbench)
                analysisNavigationStack(for: farm)
                    .tabItem { Label("分析", systemImage: "sparkles") }
                    .tag(AppTab.analysis)
                searchNavigationStack(for: farm, query: $searchQuery)
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)
            }
        }
    }

    private func homeNavigationStack(for farm: FarmRecord) -> some View {
        NavigationStack {
            FarmHomeView(
                account: account,
                farm: farm,
                isWeatherDetailPresented: $isWeatherDetailPresented,
                isMetricDetailPresented: $isMetricDetailPresented,
                sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
            )
            .navigationBarTitleDisplayMode(.inline)
            .modifier(FarmNavigationToolbarModifier(
                account: account,
                farms: farms,
                activeFarm: farm,
                sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
            ))
        }
        .compatibilityToolbarVisibility(isWeatherDetailPresented ? .hidden : .visible, for: .navigationBar)
        .compatibilityToolbarVisibility(isWeatherDetailPresented || isMetricDetailPresented ? .hidden : .visible, for: .tabBar)
    }

    private func workbench(for farm: FarmRecord) -> some View {
        FarmWorkbenchView(account: account, farm: farm, farms: farms, sharedFarmAdmissionStatus: sharedFarmAdmissionStatus)
    }

    private func analysisNavigationStack(for farm: FarmRecord) -> some View {
        NavigationStack {
            FarmInsightsView(account: account, farm: farm, assistantFarmID: $assistantFarmID)
                .navigationBarTitleDisplayMode(.inline)
                .modifier(FarmNavigationToolbarModifier(account: account, farms: farms, activeFarm: farm, sharedFarmAdmissionStatus: sharedFarmAdmissionStatus))
        }
        .compatibilityToolbarVisibility(assistantFarmID == farm.id ? .hidden : .visible, for: .tabBar)
    }

    private func searchNavigationStack(for farm: FarmRecord, query: Binding<String>) -> some View {
        NavigationStack {
            FarmSearchView(account: account, farm: farm, query: query)
        }
    }
}

private struct FarmWorkspaceSearchActivation: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabViewSearchActivation(.searchTabSelection)
        } else {
            content
        }
    }
}

struct FarmNavigationToolbarModifier: ViewModifier {
    let account: AccountProfile
    let farms: [FarmRecord]
    let activeFarm: FarmRecord
    let sharedFarmAdmissionStatus: SharedFarmAdmissionStatus?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbar {
                farmSwitcherItem
                accountToolbarItem
                    .sharedBackgroundVisibility(.hidden)
            }
        } else {
            content.toolbar {
                farmSwitcherItem
                accountToolbarItem
            }
        }
    }

    private var farmSwitcherItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            FarmSwitcher(
                farms: farms,
                activeFarm: activeFarm,
                sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
            )
        }
    }

    private var accountToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                FarmSettingsView(account: account, farm: activeFarm)
            } label: {
                FarmToolbarAccountAvatar(account: account)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("账户与牧场设置")
        }
    }
}

private struct FarmToolbarAccountAvatar: View {
    let account: AccountProfile

    var body: some View {
        AccountAvatarView(account: account, size: 38)
            .frame(width: 44, height: 44)
            .compatibilityGlass(in: .circle, interactive: true)
            .contentShape(.circle)
    }
}

private struct FarmSwitcher: View {
    @Environment(AppSession.self) private var session

    let farms: [FarmRecord]
    let activeFarm: FarmRecord
    let sharedFarmAdmissionStatus: SharedFarmAdmissionStatus?

    var body: some View {
        Menu {
            if let sharedFarmAdmissionStatus {
                Section("共享牧场") {
                    Label(
                        "正在加入 · \(sharedFarmAdmissionStatus.detailText)",
                        systemImage: "person.2.badge.gearshape"
                    )
                }
            }

            ForEach(farms, id: \.id) { farm in
                Button {
                    try? session.switchFarm(to: farm.id, availableFarms: farms)
                } label: {
                    if farm.id == activeFarm.id {
                        Label {
                            farmNameText(farm.name)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        farmNameText(farm.name)
                    }
                }
            }

            Divider()

            Button("新建牧场", systemImage: "plus") {
                session.isCreateFarmPresented = true
            }

            Button("加入牧场", systemImage: "person.badge.plus") {
                session.isJoinFarmPresented = true
            }
        } label: {
            HStack(spacing: 6) {
                farmNameText(activeFarm.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                if sharedFarmAdmissionStatus != nil {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .accessibilityLabel(
            sharedFarmAdmissionStatus == nil
                ? "切换牧场，当前为\(activeFarm.name)"
                : "切换牧场，当前为\(activeFarm.name)，正在加入共享牧场"
        )
    }

    @ViewBuilder
    private func farmNameText(_ name: String) -> some View {
        Text(verbatim: name)
    }
}
