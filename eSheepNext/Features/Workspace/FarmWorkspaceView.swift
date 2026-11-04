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
            homeRoot(for: farm)
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

    @ViewBuilder
    private func homeRoot(for farm: FarmRecord) -> some View {
        if #available(iOS 18, *) {
            FarmHomeView(
                account: account, farm: farm,
                isWeatherDetailPresented: $isWeatherDetailPresented,
                isMetricDetailPresented: $isMetricDetailPresented,
                sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
            )
        } else {
            LegacyFarmHomeEntry(
                account: account, farm: farm,
                weatherPresented: $isWeatherDetailPresented,
                metricPresented: $isMetricDetailPresented,
                admissionStatus: sharedFarmAdmissionStatus
            ).equatable()
        }
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
        // Let the search tab's container place its field for the current bar
        // axis, without adding search fields to the other workspace tabs.
        .searchable(text: query, prompt: "搜索羊只、羊舍、事件")
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
                    .sharedBackgroundVisibility(.hidden)
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
            farmSwitcher
                .farmVerticalToolbarContent { accountLink }
        }
        .farmVerticalPreferred()
    }

    private var accountToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            accountLink
                .farmVerticalToolbarContent { farmSwitcher }
        }
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
                .farmSwitcherScrollAlignment()
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
            .compatibilityGlass(in: .capsule, interactive: true)
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
                .compatibilityGlass(in: .capsule, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(menuLabel)
        }
    }
}

private extension View {
    @ViewBuilder
    func farmSwitcherScrollAlignment() -> some View {
        if #available(iOS 18, *) {
            defaultScrollAnchor(.center, for: .alignment)
        } else {
            self
        }
    }
}

/// Prevent parent navigation layout from reinstalling identical home queries on
/// iOS 17. The child's State, Query, and model observations still update normally.
private struct LegacyFarmHomeEntry: View, Equatable {
    let account: AccountProfile
    let farm: FarmRecord
    let weatherPresented: Binding<Bool>
    let metricPresented: Binding<Bool>
    let admissionStatus: SharedFarmAdmissionStatus?
    private let accountIdentity: ObjectIdentifier
    private let farmIdentity: ObjectIdentifier
    private let farmID: UUID
    private let weatherValue: Bool
    private let metricValue: Bool

    init(account: AccountProfile, farm: FarmRecord, weatherPresented: Binding<Bool>,
         metricPresented: Binding<Bool>, admissionStatus: SharedFarmAdmissionStatus?) {
        self.account = account
        self.farm = farm
        self.weatherPresented = weatherPresented
        self.metricPresented = metricPresented
        self.admissionStatus = admissionStatus
        accountIdentity = ObjectIdentifier(account)
        farmIdentity = ObjectIdentifier(farm)
        farmID = farm.id
        weatherValue = weatherPresented.wrappedValue
        metricValue = metricPresented.wrappedValue
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountIdentity == rhs.accountIdentity && lhs.farmIdentity == rhs.farmIdentity &&
            lhs.farmID == rhs.farmID && lhs.admissionStatus == rhs.admissionStatus &&
            lhs.weatherValue == rhs.weatherValue && lhs.metricValue == rhs.metricValue
    }

    var body: some View {
        FarmHomeView(account: account, farm: farm,
                     isWeatherDetailPresented: weatherPresented,
                     isMetricDetailPresented: metricPresented,
                     sharedFarmAdmissionStatus: admissionStatus)
    }
}
