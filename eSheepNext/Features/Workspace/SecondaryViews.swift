import ESMotion
import SwiftData
import SwiftUI

struct FarmInsightsView: View {
    let account: AccountProfile
    let farm: FarmRecord
    @Binding var assistantFarmID: UUID?
    @Namespace private var assistantTransition

    var body: some View {
        Group {
            if farmContext.capabilities.allows(.viewAnalytics) {
                FarmAnalysisCenterView(
                    farm: farm,
                    assistantTransition: assistantTransition,
                    assistantTransitionID: assistantTransitionID,
                    assistantTransitionSpec: assistantTransitionSpec
                ) {
                    presentAssistant()
                }
            } else {
                ContentUnavailableView {
                    Label("无法查看牧场分析", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("当前牧场角色没有分析权限，但仍可使用 AI 助手查询获准读取的数据。")
                } actions: {
                    Button("与 AI 助手聊天", action: presentAssistant)
                        .buttonStyle(.borderedProminent)
                        .motionTransitionSource(
                            id: assistantTransitionID,
                            in: assistantTransition,
                            spec: assistantTransitionSpec,
                            background: AppTheme.pageBackground
                        )
                }
            }
        }
        .navigationTitle("洞察")
        .navigationDestination(isPresented: assistantPresentation) {
            FarmInsightConversationView(account: account, farm: farm)
                .id(farm.id)
                .motionTransitionDestination(
                    id: assistantTransitionID,
                    in: assistantTransition,
                    spec: assistantTransitionSpec
                )
        }
    }

    private var assistantTransitionID: MotionTransitionID {
        MotionTransitionID("farm-assistant-\(farm.id.uuidString)")
    }

    private var assistantTransitionSpec: MotionTransitionSpec {
        MotionTransitionSpec(
            preset: .card,
            cornerRadius: 22
        )
    }

    private func presentAssistant() {
        guard assistantFarmID != farm.id else { return }
        assistantFarmID = farm.id
    }

    private var assistantPresentation: Binding<Bool> {
        Binding(
            get: {
                assistantFarmID == farm.id
            },
            set: { isPresented in
                if isPresented {
                    assistantFarmID = farm.id
                } else if assistantFarmID == farm.id {
                    assistantFarmID = nil
                }
            }
        )
    }

    private var farmContext: FarmContext {
        FarmContext(
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            role: farm.role
        )
    }
}

struct FarmSearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session

    let account: AccountProfile
    let farm: FarmRecord
    @Binding var query: String

    @State private var source = FarmSearchSource.empty
    @State private var results = FarmSearchResultSet.empty
    @State private var sourceRevision = 0
    @State private var isLoadingSource = false
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if SearchText.normalized(query).isEmpty {
                ContentUnavailableView {
                    Label("搜索牧场", systemImage: "magnifyingglass")
                } description: {
                    Text(isLoadingSource ? "正在准备当前牧场的搜索索引…" : "输入耳号、品种或圈舍名称开始搜索。")
                }
                .frame(maxWidth: .infinity, minHeight: 360)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if isSearching && results.isEmpty {
                ProgressView("正在搜索")
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !results.sheep.isEmpty {
                Section("羊只") {
                    ForEach(results.sheep) { item in
                        NavigationLink {
                            FarmSearchSheepDestination(
                                account: account,
                                farm: farm,
                                sheepID: item.id,
                                penName: item.penName
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.earTag).font(.headline)
                                Text("\(item.breed) · \(item.statusName)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if results.hasMoreSheep {
                        searchLimitHint(visible: results.sheep.count, total: results.totalSheepCount)
                    }
                }
            }
            if !results.pens.isEmpty {
                Section("圈舍") {
                    ForEach(results.pens) { pen in
                        NavigationLink {
                            FarmSearchPenDestination(
                                account: account,
                                farm: farm,
                                penID: pen.id
                            )
                        } label: {
                            Text(pen.name)
                        }
                    }
                    if results.hasMorePens {
                        searchLimitHint(visible: results.pens.count, total: results.totalPenCount)
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "耳号、品种或圈舍"
        )
        .task(id: farm.id) {
            await reloadSource()
        }
        .task(id: FarmSearchRequest(query: query, sourceRevision: sourceRevision)) {
            await updateResults()
        }
        .refreshable {
            await reloadSource()
        }
        .navigationDestination(isPresented: Binding(
            get: { session.pendingSheepID != nil },
            set: { if !$0 { session.pendingSheepID = nil } }
        )) {
            if let sheepID = session.pendingSheepID {
                FarmSearchSheepDestination(
                    account: account,
                    farm: farm,
                    sheepID: sheepID,
                    penName: source.sheep.first(where: { $0.id == sheepID })?.penName
                )
            } else {
                ContentUnavailableView("羊只不存在", systemImage: "questionmark.folder", description: Text("该羊只可能已删除或不属于当前牧场。"))
            }
        }
        .recordErrorAlert($errorMessage)
    }

    @MainActor
    private func reloadSource() async {
        isLoadingSource = source == .empty
        do {
            let updatedSource = try await FarmSearchIndexActor(
                container: modelContext.container
            ).load(farmID: farm.id)
            try Task.checkCancellation()
            source = updatedSource
            sourceRevision &+= 1
            isLoadingSource = false
        } catch is CancellationError {
            return
        } catch {
            isLoadingSource = false
            errorMessage = "准备搜索数据失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func updateResults() async {
        let submittedQuery = query
        guard !SearchText.normalized(submittedQuery).isEmpty else {
            results = .empty
            isSearching = false
            return
        }

        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(120))
            let sourceSnapshot = source
            let updatedResults = await Task.detached(priority: .userInitiated) {
                FarmSearchEngine.search(query: submittedQuery, source: sourceSnapshot)
            }.value
            try Task.checkCancellation()
            results = updatedResults
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            isSearching = false
            errorMessage = "搜索失败：\(error.localizedDescription)"
        }
    }
}

private struct FarmSearchRequest: Equatable {
    let query: String
    let sourceRevision: Int
}

private struct FarmSearchSheepDestination: View {
    @Query private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let penName: String?

    init(account: AccountProfile, farm: FarmRecord, sheepID: UUID, penName: String?) {
        self.account = account
        self.farm = farm
        self.penName = penName
        let farmID = farm.id
        _sheep = Query(filter: #Predicate<SheepRecord> {
            $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
        })
    }

    var body: some View {
        if let sheep = sheep.first {
            SheepDetailView(account: account, farm: farm, sheep: sheep, penName: penName)
        } else {
            ContentUnavailableView(
                "羊只不存在",
                systemImage: "questionmark.folder",
                description: Text("该羊只可能已删除或不属于当前牧场。")
            )
        }
    }
}

private struct FarmSearchPenDestination: View {
    @Query private var pens: [PenRecord]
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]

    let account: AccountProfile
    let farm: FarmRecord

    init(account: AccountProfile, farm: FarmRecord, penID: UUID) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _pens = Query(filter: #Predicate<PenRecord> {
            $0.id == penID && $0.farmID == farmID && $0.deletedAt == nil
        })
        _sheep = Query(
            filter: #Predicate<SheepRecord> {
                $0.farmID == farmID && $0.currentPenID == penID && $0.deletedAt == nil
            },
            sort: \.earTag
        )
    }

    var body: some View {
        if let pen = pens.first {
            PenDetailView(
                account: account,
                farm: farm,
                pen: pen,
                sheep: sheep.filter { $0.status == .active }
            )
        } else {
            ContentUnavailableView(
                "圈舍不存在",
                systemImage: "questionmark.folder",
                description: Text("该圈舍可能已删除或不属于当前牧场。")
            )
        }
    }
}

private func searchLimitHint(visible: Int, total: Int) -> some View {
    Text("显示前 \(visible) 条，共 \(total) 条匹配；继续输入可缩小范围。")
        .font(.footnote)
        .foregroundStyle(.secondary)
}

struct FarmSettingsView: View {
    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        SettingsHomeView(account: account, farm: farm)
    }
}

@MainActor
struct AccountDisplayNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let account: AccountProfile

    @State private var displayName: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(account: AccountProfile) {
        self.account = account
        _displayName = State(initialValue: account.displayName)
    }

    private var normalizedName: String {
        displayName.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving && !normalizedName.isEmpty && normalizedName.count <= 40 && normalizedName != account.displayName
    }

    var body: some View {
        Form {
            Section("账户名称") {
                TextField("显示名称", text: $displayName)
                    .textContentType(.name)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                    .onSubmit { if canSave { save() } }
                Text("名称会同步到你的 eSheep+ 账户，并显示给同一牧场的协作成员。最多 40 个字符。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("修改名称")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("保存", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .alert("无法修改名称", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .onAppear { isNameFocused = true }
    }

    private func save() {
        let submittedName = normalizedName
        guard !submittedName.isEmpty, submittedName.count <= 40 else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let response = try await IdentityWorkerClient.shared.updateAccountDisplayName(submittedName)
                guard response.accountID == account.effectiveAccountID else {
                    throw IdentityWorkerError.server(code: "account_mismatch", message: "当前登录会话与本机账户不一致，请退出后重新登录。")
                }
                account.displayName = response.displayName
                account.updatedAt = .now
                try modelContext.save()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
