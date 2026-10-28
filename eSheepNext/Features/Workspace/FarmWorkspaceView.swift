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
                Tab("工作台", systemImage: "square.grid.2x2", value: .workbench) {
                    FarmWorkbenchView(account: account, farm: activeFarm, farms: farms, sharedFarmAdmissionStatus: sharedFarmAdmissionStatus)
                }
                Tab("分析", systemImage: "sparkles", value: .analysis) {
                    NavigationStack {
                        FarmInsightsView(account: account, farm: activeFarm, assistantFarmID: $assistantFarmID)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { FarmNavigationToolbar(account: account, farms: farms, activeFarm: activeFarm, sharedFarmAdmissionStatus: sharedFarmAdmissionStatus) }
                    }
                    .toolbarVisibility(assistantFarmID == activeFarm.id ? .hidden : .visible, for: .tabBar)
                }
                Tab(value: .search, role: .search) {
                    searchNavigationStack(for: activeFarm, query: $searchQuery)
                }
            }
            .tabViewSearchActivation(.searchTabSelection)
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

    private func searchNavigationStack(for farm: FarmRecord, query: Binding<String>) -> some View {
        NavigationStack {
            FarmSearchView(account: account, farm: farm, query: query)
        }
        // Let the search tab's container place its field for the current bar
        // axis, without adding search fields to the other workspace tabs.
        .searchable(text: query, prompt: "搜索羊只、羊舍、事件")
    }
}

struct FarmNavigationToolbar: ToolbarContent {
    let account: AccountProfile
    let farms: [FarmRecord]
    let activeFarm: FarmRecord
    let sharedFarmAdmissionStatus: SharedFarmAdmissionStatus?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            farmSwitcher
                .farmVerticalToolbarContent { accountLink }
        }
        .sharedBackgroundVisibility(.hidden)
        .farmVerticalPreferred()
        ToolbarItem(placement: .topBarTrailing) {
            accountLink
                .farmVerticalToolbarContent { farmSwitcher }
        }
        .sharedBackgroundVisibility(.hidden)
        .farmVerticalPreferred()
    }

    private var farmSwitcher: some View {
        FarmSwitcher(farms: farms, activeFarm: activeFarm,
                     sharedFarmAdmissionStatus: sharedFarmAdmissionStatus)
    }

    private var accountLink: some View {
        NavigationLink {
            FarmSettingsView(account: account, farm: activeFarm)
        } label: {
            FarmToolbarAccountAvatar(account: account)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("账户与牧场设置")
    }
}

private extension View {
    @ViewBuilder
    func farmVerticalToolbarContent<VerticalContent: View>(@ViewBuilder _ content: () -> VerticalContent) -> some View {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            FarmToolbarAxisContent(horizontal: self, vertical: content())
        } else {
            self
        }
#else
        self
#endif
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct FarmToolbarAxisContent<HorizontalContent: View, VerticalContent: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let horizontal: HorizontalContent
    let vertical: VerticalContent

    var body: some View {
        if verticalEdge == nil {
            horizontal
        } else {
            vertical
        }
    }
}
#endif

private extension ToolbarContent {
    @ToolbarContentBuilder
    func farmVerticalPreferred() -> some ToolbarContent {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            self.axisBehavior(.verticalPreferred)
        } else {
            self
        }
#else
        self
#endif
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
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            AdaptiveFarmSwitcher(name: activeFarm.name, isJoining: sharedFarmAdmissionStatus != nil,
                                 menuLabel: menuLabel) { menuItems }
        } else {
            FarmSwitcherControl(name: activeFarm.name, isJoining: sharedFarmAdmissionStatus != nil,
                                menuLabel: menuLabel) { menuItems }
        }
#else
        FarmSwitcherControl(name: activeFarm.name, isJoining: sharedFarmAdmissionStatus != nil,
                            menuLabel: menuLabel) { menuItems }
#endif
    }

    private var menuLabel: String {
        sharedFarmAdmissionStatus == nil
            ? "切换牧场，当前为\(activeFarm.name)"
            : "切换牧场，当前为\(activeFarm.name)，正在加入共享牧场"
    }

    @ViewBuilder
    private var menuItems: some View {
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
    }

    @ViewBuilder
    private func farmNameText(_ name: String) -> some View {
        Text(verbatim: name)
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct AdaptiveFarmSwitcher<MenuContent: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let name: String
    let isJoining: Bool
    let menuLabel: String
    @ViewBuilder var menuContent: () -> MenuContent

    var body: some View {
        FarmSwitcherControl(name: name, isJoining: isJoining, menuLabel: menuLabel,
                            isVertical: verticalEdge != nil, menuContent: menuContent)
    }
}
#endif

private struct FarmSwitcherControl<MenuContent: View>: View {
    let name: String
    let isJoining: Bool
    let menuLabel: String
    var isVertical = false
    @ViewBuilder var menuContent: () -> MenuContent
    @State private var nameHeight: CGFloat = 72

    var body: some View {
        if isVertical {
            VStack(spacing: 0) {
                // The scroll viewport is bounded, even for very long names.
                // Keep it outside the Menu label so a drag scrolls the name.
                ScrollView(.vertical) {
                    Text(verbatim: name)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { nameHeight = $0 }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.center, for: .alignment)
                .frame(height: min(104, max(76, nameHeight)))
                .padding(.horizontal, 4)
                .padding(.top, 12)
                .accessibilityIdentifier("farm.switcher.name")

                Menu(content: menuContent) {
                    Group {
                        if isJoining {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(menuLabel)
                .accessibilityIdentifier("farm.switcher.menu")
            }
            .frame(width: 44)
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            Menu(content: menuContent) {
                HStack(spacing: 6) {
                    Text(verbatim: name).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    if isJoining { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(menuLabel)
        }
    }
}
