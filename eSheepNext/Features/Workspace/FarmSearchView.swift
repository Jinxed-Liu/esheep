import Combine
import SwiftData
import SwiftUI

struct FarmSearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    let account: AccountProfile
    let farm: FarmRecord
    @Binding var query: String

    @ScaledMetric(relativeTo: .body) private var searchBarClearance = 72

    @State private var source = FarmSearchSource.empty
    @State private var results = FarmSearchResultSet.empty
    @State private var sourceRevision = 0
    @State private var reloadRevision = 0
    @State private var isLoadingSource = true
    @State private var isSearching = false
    @State private var sourceFailure: String?
    @State private var lastLoadedAt: Date?
    @State private var category = FarmSearchCategory.all
    @State private var rowLimit = FarmSearchEngine.defaultLimit
    @State private var eventScope = FarmEventExportScope.all
    @State private var usesDateRange = false
    @State private var startDate = Date.now
    @State private var endDate = Date.now
    @State private var showsEventFilters = false
    @State private var recentQueries: [String] = []

    private var normalizedQuery: String { SearchText.normalized(query) }
    private var eventRange: FarmEventExportRange { usesDateRange ? .days(from: startDate, through: endDate) : .all }
    private var recentKey: String { "farm-search-recent.\(account.id).\(farm.id)" }
    private var visibleCategories: [FarmSearchCategory] {
        category == .all ? results.orderedCategories.filter { results.count(for: $0) > 0 } : [category]
    }
    private var request: FarmSearchRequest {
        .init(query: normalizedQuery, sourceRevision: sourceRevision, limit: rowLimit,
              scope: eventScope, range: eventRange)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let sourceFailure {
                    Section {
                        Label(lastLoadedAt == nil ? "搜索暂不可用" : "搜索数据更新失败", systemImage: "exclamationmark.triangle")
                        Text(verbatim: sourceFailure).font(.footnote).foregroundStyle(.secondary)
                        if let lastLoadedAt { Text("当前数据读取于 \(lastLoadedAt.formatted())").font(.caption) }
                        Button("重试") { reloadRevision &+= 1 }
                    }
                }
                if normalizedQuery.isEmpty {
                    discoverySections
                } else {
                    Section {
                        categoryBar
                            .listRowInsets(EdgeInsets())
                            .id("farm-search-top")
                    }
                    .compatibilityListSectionMargins(.horizontal, 0)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    if category == .events {
                        Section { eventFilterBar }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
    
                    if (isLoadingSource || isSearching) && results.isEmpty {
                        ProgressView("正在搜索").frame(maxWidth: .infinity, minHeight: 180)
                            .listRowBackground(Color.clear)
                    } else if results.count(for: category) == 0 && sourceFailure == nil {
                        ContentUnavailableView("没有匹配结果", systemImage: "magnifyingglass",
                            description: Text("请更换关键词、切换分类或清除事件筛选。"))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(visibleCategories) { section in
                        resultSection(section)
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .listSectionSpacing(8)
            .contentMargins(.top, 4, for: .scrollContent)
            // The native search tab overlays its field above the keyboard. Keep a
            // scrollable tail so the last action can clear that floating field.
            .contentMargins(.bottom, searchBarClearance, for: .scrollContent)
            .accessibilityIdentifier("farm-search-results")
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                recentQueries = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
                reloadRevision &+= 1
            }
            .task(id: reloadRevision) { await reloadSource() }
            .task(id: request) { await updateResults() }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in reloadRevision &+= 1 }
            .onChange(of: query) { _, _ in
                results = .empty
                isSearching = !normalizedQuery.isEmpty
                rowLimit = FarmSearchEngine.defaultLimit
            }
            .onChange(of: category) { _, newCategory in
                proxy.scrollTo("farm-search-top", anchor: .top)
                rowLimit = FarmSearchEngine.defaultLimit
                if newCategory != .events { eventScope = .all; usesDateRange = false }
            }
            .onSubmit(of: .search) { rememberQuery() }
            .refreshable { await reloadSource() }
            .sheet(isPresented: $showsEventFilters) {
                FarmEventFilterSheet(scope: $eventScope, usesDateRange: $usesDateRange,
                    startDate: $startDate, endDate: $endDate)
                    .environment(\.timeZone, TimeZone(identifier: farm.timeZoneIdentifier) ?? .current)
            }
            .navigationDestination(isPresented: Binding(
                get: { session.pendingSheepID != nil },
                set: { if !$0 { session.pendingSheepID = nil } }
            )) {
                if let sheepID = session.pendingSheepID {
                    SheepDetailEntryView(account: account, farm: farm, sheepID: sheepID)
                }
            }
        }
    }

    @ViewBuilder private var discoverySections: some View {
        if !recentQueries.isEmpty {
            Section {
                ForEach(recentQueries, id: \.self) { term in
                    Button { query = term; category = .all } label: {
                        Label(term, systemImage: "clock.arrow.circlepath")
                    }
                }
                Button("清除最近搜索", role: .destructive) {
                    recentQueries = []; UserDefaults.standard.removeObject(forKey: recentKey)
                }
            } header: { Text("最近搜索") }
        }
        Section("试试搜索") {
            ForEach(["称重", "产羔", "转群", "投喂"], id: \.self) { term in
                Button { query = term; category = .all } label: {
                    Label(LocalizedStringKey(term), systemImage: "magnifyingglass")
                }
            }
        }
    }

    private var categoryBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(FarmSearchCategory.allCases) { item in
                        Button { category = item } label: {
                            Text("\(item.title) \(results.count(for: item))")
                                .font(.subheadline.weight(.medium))
                                .fixedSize()
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .foregroundStyle(category == item ? Color.white : Color.primary)
                                .background(category == item ? AppTheme.brand : Color(uiColor: .secondarySystemGroupedBackground), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .id(item)
                        .accessibilityIdentifier("farm-search-category-" + item.rawValue)
                        .accessibilityAddTraits(category == item ? .isSelected : [])
                    }
                }
                .padding(.vertical, 8)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("farm-search-category-bar")
            .onChange(of: category) { _, item in
                proxy.scrollTo(item, anchor: item == .all ? .leading : .center)
            }
        }
    }

    private var eventFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("筛选事件", systemImage: "line.3.horizontal.decrease") { showsEventFilters = true }
                .accessibilityIdentifier("farm-search-event-filters")
            if eventScope != .all {
                Button { eventScope = .all } label: { Label(eventScope.filterName, systemImage: "xmark.circle.fill") }
            }
            if usesDateRange {
                Button { usesDateRange = false } label: {
                    Label("\(startDate.formatted(date: .numeric, time: .omitted)) – \(endDate.formatted(date: .numeric, time: .omitted))", systemImage: "xmark.circle.fill")
                }
            }
        }
        .font(.footnote)
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func resultSection(_ section: FarmSearchCategory) -> some View {
        if results.count(for: section) > 0 {
            Section {
                switch section {
                case .sheep:
                    ForEach(Array(results.sheep.prefix(category == .all ? 3 : rowLimit))) { item in
                        NavigationLink {
                            SheepDetailEntryView(account: account, farm: farm, sheepID: item.id)
                                .onAppear { rememberQuery() }
                        } label: { FarmSearchSheepRow(item: item, query: normalizedQuery) }
                        .accessibilityIdentifier("farm-search-sheep-" + item.earTag)
                    }
                case .pens:
                    ForEach(Array(results.pens.prefix(category == .all ? 3 : rowLimit))) { item in
                        NavigationLink {
                            PenDetailEntryView(account: account, farm: farm, penID: item.id)
                                .onAppear { rememberQuery() }
                        } label: { FarmSearchPenRow(item: item) }
                        .accessibilityIdentifier("farm-search-pen-" + item.name)
                    }
                case .events:
                    ForEach(Array(results.events.prefix(category == .all ? 3 : rowLimit))) { item in
                        NavigationLink {
                            FarmSearchEventDestination(account: account, farm: farm, identity: item.id)
                                .onAppear { rememberQuery() }
                        } label: { FarmSearchEventRow(item: item, query: normalizedQuery) }
                        .accessibilityIdentifier("farm-search-event-" + item.event.id.uuidString)
                    }
                case .all: EmptyView()
                }
                if category == .all && results.count(for: section) > 3 {
                    Button { category = section } label: { Text("查看全部 \(results.count(for: section)) 条") }
                        .accessibilityIdentifier("farm-search-all-" + section.rawValue)
                } else if category != .all && results.count(for: section) > rowLimit {
                    Button("加载更多") { rowLimit += FarmSearchEngine.defaultLimit }
                }
            } header: { Text("\(section.title) · \(results.count(for: section))") }
        }
    }

    private func rememberQuery() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        recentQueries.removeAll { SearchText.normalized($0) == SearchText.normalized(term) }
        recentQueries.insert(term, at: 0)
        recentQueries = Array(recentQueries.prefix(8))
        UserDefaults.standard.set(recentQueries, forKey: recentKey)
    }

    @MainActor private func reloadSource() async {
        isLoadingSource = lastLoadedAt == nil
        do {
            let loaded = try await FarmSearchIndexActor(container: modelContext.container).load(farmID: farm.id)
            try Task.checkCancellation()
            source = loaded
            sourceFailure = nil
            lastLoadedAt = .now
            sourceRevision &+= 1
            isLoadingSource = false
        } catch is CancellationError { }
        catch { sourceFailure = error.localizedDescription; isLoadingSource = false }
    }

    @MainActor private func updateResults() async {
        let submitted = request
        guard !submitted.query.isEmpty else { results = .empty; isSearching = false; return }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(120))
            let snapshot = source
            let searchTask = Task.detached(priority: .userInitiated) {
                FarmSearchEngine.search(query: submitted.query, source: snapshot, limit: submitted.limit,
                    eventScope: submitted.scope, eventRange: submitted.range)
            }
            let updated = await withTaskCancellationHandler {
                await searchTask.value
            } onCancel: { searchTask.cancel() }
            try Task.checkCancellation()
            guard submitted == request else { return }
            results = updated
            isSearching = false
        } catch is CancellationError { }
        catch { isSearching = false }
    }
}

private struct FarmSearchRequest: Equatable, Sendable {
    let query: String
    let sourceRevision: Int
    let limit: Int
    let scope: FarmEventExportScope
    let range: FarmEventExportRange
}

private struct FarmSearchSheepRow: View {
    let item: FarmSearchSheepEntry
    let query: String
    var body: some View {
        HStack(spacing: 12) {
            SheepAvatarView(photo: item.avatarPhoto, size: 44, sex: item.sex)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.earTag).font(.headline)
                Text([String(localized: String.LocalizationValue(item.sex.displayName)), item.breed,
                      String(localized: String.LocalizationValue(item.statusName))].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
                if let pen = item.penName { Text(verbatim: pen).font(.footnote).foregroundStyle(.secondary) }
                if let old = item.legacyEarTag, !query.isEmpty, item.normalizedLegacyEarTag.contains(query), item.normalizedEarTag != query {
                    Text("旧耳号：\(old)").font(.caption).foregroundStyle(AppTheme.brand)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FarmSearchPenRow: View {
    let item: FarmSearchPenEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "house.lodge").foregroundStyle(AppTheme.brand).frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.name).font(.headline)
                Text("当前在舍 \(item.sheepCount) 只 · 母 \(item.eweCount) / 公 \(item.ramCount)")
                    .font(.footnote).foregroundStyle(.secondary)
                if item.unknownCount > 0 { Text("性别待确认 \(item.unknownCount) 只").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FarmSearchEventRow: View {
    let item: FarmSearchEventEntry
    let query: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: FarmEventExportScope.scope(for: item.event).symbol)
                .foregroundStyle(AppTheme.brand).frame(width: 32).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(item.event.title)).font(.headline)
                Text(verbatim: item.event.subject).font(.subheadline)
                Text(item.event.occurredAt, format: .dateTime.year().month().day())
                    .font(.caption).foregroundStyle(.secondary)
                if !item.event.detail.isEmpty { Text(verbatim: item.event.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                if !query.isEmpty, item.normalizedNote.contains(query) {
                    Text("备注：\(item.event.note)").font(.caption).foregroundStyle(AppTheme.brand).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
