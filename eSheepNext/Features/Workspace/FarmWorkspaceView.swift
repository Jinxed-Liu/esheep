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
        @Bindable var session = session

        if let activeFarm {
            TabView(selection: $session.selectedTab) {
                Tab("首页", systemImage: "house", value: .home) {
                    NavigationStack {
                        FarmHomeView(
                            account: account,
                            farm: activeFarm,
                            isWeatherDetailPresented: $isWeatherDetailPresented,
                            isMetricDetailPresented: $isMetricDetailPresented,
                            sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
                        )
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                FarmNavigationToolbar(
                                    account: account,
                                    farms: farms,
                                    activeFarm: activeFarm,
                                    sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
                                )
                            }
                    }
                    .toolbarVisibility(
                        isWeatherDetailPresented ? .hidden : .visible,
                        for: .navigationBar
                    )
                    .toolbarVisibility(
                        isWeatherDetailPresented || isMetricDetailPresented ? .hidden : .visible,
                        for: .tabBar
                    )
                }
                Tab("洞察", systemImage: "sparkles", value: .assistant) {
                    NavigationStack {
                        FarmInsightsView(
                            account: account,
                            farm: activeFarm,
                            assistantFarmID: $assistantFarmID
                        )
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                FarmNavigationToolbar(
                                    account: account,
                                    farms: farms,
                                    activeFarm: activeFarm,
                                    sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
                                )
                            }
                    }
                    .toolbarVisibility(
                        assistantFarmID == activeFarm.id ? .hidden : .visible,
                        for: .tabBar
                    )
                }
                Tab("录入", systemImage: "square.and.pencil", value: .records) {
                    NavigationStack {
                        FarmRecordsView(account: account, farm: activeFarm)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                FarmNavigationToolbar(
                                    account: account,
                                    farms: farms,
                                    activeFarm: activeFarm,
                                    sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
                                )
                            }
                    }
                }
                Tab("投喂", systemImage: "leaf", value: .feeding) {
                    NavigationStack {
                        FeedingStartView(account: account, farm: activeFarm)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                FarmNavigationToolbar(
                                    account: account,
                                    farms: farms,
                                    activeFarm: activeFarm,
                                    sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
                                )
                            }
                    }
                }
                Tab(value: .search, role: .search) {
                    searchNavigationStack(for: activeFarm, query: $searchQuery)
                }
            }
            .tabViewSearchActivation(.searchTabSelection)
            .tabBarMinimizeBehavior(.onScrollDown)
            .scrollEdgeEffectHidden(assistantFarmID != activeFarm.id, for: .top)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                AccountAccessWorkspaceBanner(
                    authenticationMethod: account.authenticationMethod
                )
            }
            .onChange(of: activeFarm.id) { previousFarmID, currentFarmID in
                guard previousFarmID != currentFarmID else { return }
                assistantFarmID = nil
            }
            .onChange(of: session.pendingSearchQuery, initial: true) { _, pendingQuery in
                guard let pendingQuery else { return }
                searchQuery = pendingQuery
                session.pendingSearchQuery = nil
            }
        }
    }

    private func searchNavigationStack(for farm: FarmRecord, query: Binding<String>) -> some View {
        NavigationStack {
            FarmSearchView(account: account, farm: farm, query: query)
        }
    }
}

private struct FarmNavigationToolbar: ToolbarContent {
    let account: AccountProfile
    let farms: [FarmRecord]
    let activeFarm: FarmRecord
    let sharedFarmAdmissionStatus: SharedFarmAdmissionStatus?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            FarmSwitcher(
                farms: farms,
                activeFarm: activeFarm,
                sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                FarmSettingsView(account: account, farm: activeFarm)
            } label: {
                FarmToolbarAccountAvatar(account: account)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("账户与牧场设置")
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

private struct FarmToolbarAccountAvatar: View {
    let account: AccountProfile

    var body: some View {
        AccountAvatarView(account: account, size: 38)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
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
