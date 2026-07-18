import SwiftUI

struct FarmWorkspaceView: View {
    @Environment(AppSession.self) private var session
    @State private var searchQuery = ""

    let account: AccountProfile
    let farms: [FarmRecord]

    private var activeFarm: FarmRecord? {
        farms.first(where: { $0.id == session.selectedFarmID }) ?? farms.first
    }

    var body: some View {
        @Bindable var session = session

        if let activeFarm {
            TabView(selection: $session.selectedTab) {
                Tab("首页", systemImage: "house", value: .home) {
                    NavigationStack {
                        FarmHomeView(account: account, farm: activeFarm)
                            .navigationTitle("首页")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                FarmNavigationToolbar(account: account, farms: farms, activeFarm: activeFarm)
                            }
                    }
                }
                Tab("助手", systemImage: "sparkles", value: .assistant) {
                    NavigationStack {
                        AssistantStartView(farm: activeFarm)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                FarmNavigationToolbar(account: account, farms: farms, activeFarm: activeFarm)
                            }
                    }
                }
                Tab("录入", systemImage: "square.and.pencil", value: .records) {
                    NavigationStack {
                        FarmRecordsView(account: account, farm: activeFarm)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                FarmNavigationToolbar(account: account, farms: farms, activeFarm: activeFarm)
                            }
                    }
                }
                Tab("投喂", systemImage: "leaf", value: .feeding) {
                    NavigationStack {
                        FeedingStartView(account: account, farm: activeFarm)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                FarmNavigationToolbar(account: account, farms: farms, activeFarm: activeFarm)
                            }
                    }
                }
                Tab(value: .search, role: .search) {
                    searchNavigationStack(for: activeFarm, query: $searchQuery)
                }
            }
            .tabViewSearchActivation(.searchTabSelection)
            .tabBarMinimizeBehavior(.onScrollDown)
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

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            FarmSwitcher(farms: farms, activeFarm: activeFarm)
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                FarmSettingsView(account: account, farm: activeFarm)
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .accessibilityLabel("账户与牧场设置")
        }
    }
}

private struct FarmSwitcher: View {
    @Environment(AppSession.self) private var session

    let farms: [FarmRecord]
    let activeFarm: FarmRecord

    var body: some View {
        Menu {
            ForEach(farms, id: \.id) { farm in
                Button {
                    try? session.switchFarm(to: farm.id, availableFarms: farms)
                } label: {
                    if farm.id == activeFarm.id {
                        Label(farm.name, systemImage: "checkmark")
                    } else {
                        Text(farm.name)
                    }
                }
            }

            Divider()

            Button("新建牧场", systemImage: "plus") {
                session.isCreateFarmPresented = true
            }
        } label: {
            HStack(spacing: 6) {
                Text(activeFarm.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel("切换牧场，当前为\(activeFarm.name)")
    }
}
