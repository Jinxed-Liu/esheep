import SwiftData
import SwiftUI

struct SheepLabelFilterEntry: View {
    let labels: [SheepLabelValue]
    @Binding var selectedIDs: Set<UUID>
    @Binding var matchAll: Bool
    @Binding var unlabelledOnly: Bool
    @State private var showingFilter = false

    private var hasFilter: Bool { unlabelledOnly || !selectedIDs.isEmpty }
    private var filterSummary: String {
        if unlabelledOnly { return "无自定义标签" }
        let names = SheepLabelRules.ordered(labels).filter { selectedIDs.contains($0.id) }.map(\.name)
        return (matchAll ? "同时包含：" : "包含任一：") + names.joined(separator: "、")
    }

    var body: some View {
        Button { showingFilter = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label("标签筛选", systemImage: "line.3.horizontal.decrease.circle")
                    if hasFilter {
                        Text(filterSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("herd-label-filter")
        .sheet(isPresented: $showingFilter) {
            NavigationStack {
                SheepLabelFilterView(
                    labels: labels,
                    selectedIDs: $selectedIDs,
                    matchAll: $matchAll,
                    unlabelledOnly: $unlabelledOnly
                )
            }
        }
    }

}

private struct SheepLabelFilterView: View {
    @Environment(\.dismiss) private var dismiss
    let labels: [SheepLabelValue]
    @Binding var selectedIDs: Set<UUID>
    @Binding var matchAll: Bool
    @Binding var unlabelledOnly: Bool
    @State private var query = ""

    var body: some View {
        List {
            Section {
                Toggle("无自定义标签", isOn: Binding(
                    get: { unlabelledOnly },
                    set: { enabled in
                        unlabelledOnly = enabled
                        if enabled { selectedIDs.removeAll() }
                    }
                ))
                Toggle("同时包含全部所选标签", isOn: $matchAll)
                    .disabled(unlabelledOnly)
            } footer: {
                Text("默认匹配任一所选标签，并与当前性别、圈舍和状态筛选一起生效。")
            }
            Section("选择标签") {
                ForEach(SheepLabelRules.ordered(labels).filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { label in
                    Toggle(isOn: Binding(
                        get: { selectedIDs.contains(label.id) },
                        set: { enabled in
                            if enabled {
                                unlabelledOnly = false
                                selectedIDs.insert(label.id)
                            } else {
                                selectedIDs.remove(label.id)
                            }
                        }
                    )) {
                        SheepLabelChips(labels: [label])
                    }
                }
                if labels.isEmpty {
                    Text("尚未创建标签，可从工作台的“羊只标签”新建。")
                        .foregroundStyle(.secondary)
                } else if !query.isEmpty && !labels.contains(where: { $0.name.localizedStandardContains(query) }) {
                    Text("没有匹配的标签").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("标签筛选")
        .searchable(text: $query, prompt: "搜索标签名称")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("清除") { selectedIDs.removeAll(); unlabelledOnly = false; matchAll = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }
}

struct SheepLabelIcon: View {
    let color: SheepLabelColor
    var width: CGFloat = 30
    var body: some View {
        Image("EarTag-\(color.rawValue)").resizable().scaledToFit().frame(width: width, height: width * 8 / 11).accessibilityHidden(true)
    }
}

struct SheepLabelChips: View {
    let labels: [SheepLabelValue]
    var primaryID: UUID?
    var limit: Int = 2
    var body: some View {
        let ordered = SheepLabelRules.ordered(labels, primaryID: primaryID)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(ordered.prefix(limit))) { label in chip(label) }
                if ordered.count > limit { Text("＋\(ordered.count - limit)").font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(ordered.prefix(limit))) { label in chip(label) }
                if ordered.count > limit { Text("＋\(ordered.count - limit)").font(.caption) }
            }
        }
    }
    private func chip(_ label: SheepLabelValue) -> some View {
        HStack(spacing: 3) {
            SheepLabelIcon(color: label.color, width: 23)
            Text(verbatim: label.name).lineLimit(1)
            if !label.isActive { Text("已停用") }
        }.font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.quaternary.opacity(0.4), in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

struct SheepLabelDetailSection: View {
    @Query private var catalog: [SheepLabelRecord]
    @Query private var assignments: [SheepLabelAssignmentRecord]
    @Query private var changes: [SheepLabelChangeRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let sheepID: UUID
    @State private var editing = false
    init(account: AccountProfile, farm: FarmRecord, sheepID: UUID) {
        self.account = account; self.farm = farm; self.sheepID = sheepID
        let id = farm.id
        _catalog = Query(filter: #Predicate<SheepLabelRecord> { $0.farmID == id })
        _assignments = Query(filter: #Predicate<SheepLabelAssignmentRecord> { $0.farmID == id && $0.sheepID == sheepID })
        _changes = Query(filter: #Predicate<SheepLabelChangeRecord> { $0.farmID == id && $0.sheepID == sheepID }, sort: \SheepLabelChangeRecord.occurredAt, order: .reverse)
    }
    var body: some View {
        Section("标签") {
            let a = assignments.first
            let labels = catalog.map(\.value).filter { a?.labelIDs.contains($0.id) == true }
            if labels.isEmpty { Text("尚无自定义标签").foregroundStyle(.secondary) }
            ForEach(SheepLabelRules.ordered(labels, primaryID: a?.primaryLabelID)) { label in
                HStack {
                    SheepLabelChips(labels: [label])
                    Spacer()
                    if label.id == a?.primaryLabelID { Text("主标签").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button(labels.isEmpty ? "添加标签" : "编辑标签", systemImage: "tag") { editing = true }
                .disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
            if !changes.isEmpty {
                DisclosureGroup("标签变更记录（\(changes.count)）") {
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: change.detail)
                            Text(change.occurredAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text("操作账号：\(change.accountID.uuidString)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.sheet(isPresented: $editing) {
            NavigationStack { SheepLabelsEditor(account: account, farm: farm, sheepIDs: [sheepID]) }
        }
    }
}

struct SheepLabelsEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var catalog: [SheepLabelRecord]
    @Query private var sheep: [SheepRecord]
    @Query private var assignments: [SheepLabelAssignmentRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let sheepIDs: Set<UUID>
    @State private var query = ""
    @State private var selected = Set<UUID>()
    @State private var initial = Set<UUID>()
    @State private var primaryID: UUID?
    @State private var operation = "add"
    @State private var applicableOnly = false
    @State private var message: String?
    @State private var failedIDs = Set<UUID>()
    @State private var hasSubmitted = false
    @State private var originalPrimaryID: UUID?
    @State private var isCreatingLabel = false
    private let initialOperation: String?
    private let initialSelectedIDs: Set<UUID>
    init(
        account: AccountProfile,
        farm: FarmRecord,
        sheepIDs: Set<UUID>,
        initialOperation: String? = nil,
        initialSelectedIDs: Set<UUID> = []
    ) {
        self.account = account; self.farm = farm; self.sheepIDs = sheepIDs
        self.initialOperation = initialOperation
        self.initialSelectedIDs = initialSelectedIDs
        let id = farm.id
        _catalog = Query(filter: #Predicate<SheepLabelRecord> { $0.farmID == id }, sort: \SheepLabelRecord.sortOrder)
        _sheep = Query(filter: #Predicate<SheepRecord> { $0.farmID == id && $0.deletedAt == nil })
        _assignments = Query(filter: #Predicate<SheepLabelAssignmentRecord> { $0.farmID == id })
        _operation = State(initialValue: initialOperation ?? "add")
        _selected = State(initialValue: initialSelectedIDs)
    }
    private var targets: [SheepRecord] { sheep.filter { sheepIDs.contains($0.id) && (!hasSubmitted || failedIDs.contains($0.id)) } }
    private var isScopedRemoval: Bool { initialOperation == "remove" }
    private var isSingle: Bool { sheepIDs.count == 1 && !isScopedRemoval }
    private var values: [SheepLabelValue] { catalog.map(\.value) }
    private func eligible(_ label: SheepLabelValue, _ sheep: SheepRecord) -> Bool { operation == "remove" || (label.isActive && label.color.allows(sheep.sex)) }
    private var hasIncompatible: Bool { !isSingle && values.contains { label in selected.contains(label.id) && targets.contains { !eligible(label, $0) } } }
    var body: some View {
        Form {
            if !isSingle {
                Section("操作范围：\(targets.count) 只") {
                    if isScopedRemoval {
                        Label("停用此标签", systemImage: "tag.slash")
                        Text("只从所选羊只上移除这个标签，牧场其他羊只不受影响。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("操作", selection: $operation) {
                            Text("添加标签").tag("add"); Text("移除标签").tag("remove"); Text("设为主标签").tag("primary")
                        }.onChange(of: operation) { selected.removeAll(); applicableOnly = false }
                    }
                }
            }
            Section("选择标签") {
                TextField("搜索标签名称", text: $query)
                ForEach(values.filter {
                    (query.isEmpty || $0.name.localizedStandardContains(query)) &&
                    (!isScopedRemoval || initialSelectedIDs.contains($0.id))
                }) { label in
                    let allowed = !isSingle || targets.first.map { label.isActive && label.color.allows($0.sex) } == true
                    Toggle(isOn: Binding(get: { selected.contains(label.id) }, set: { on in
                        if on { if operation == "primary" { selected = [label.id] } else { selected.insert(label.id) } } else { selected.remove(label.id) }
                    })) {
                        VStack(alignment: .leading) {
                            SheepLabelChips(labels: [label])
                            Text(label.color.restriction).font(.caption).foregroundStyle(.secondary)
                            if !isSingle && selected.contains(label.id) {
                                let count = targets.filter { eligible(label, $0) }.count
                                Text("可处理 \(count) 只 · 不适用 \(targets.count - count) 只").font(.caption)
                            }
                        }
                    }.disabled(!allowed && !selected.contains(label.id))
                }
                if catalog.isEmpty {
                    Text(CapabilitySet(role: farm.role).allows(.manageCatalogs) ? "先新建一个标签，再选择要添加的标签。" : "牧场尚未创建标签，请联系管理员创建。")
                        .foregroundStyle(.secondary)
                }
                if CapabilitySet(role: farm.role).allows(.manageCatalogs) {
                    Button("新建标签", systemImage: "plus") { isCreatingLabel = true }
                        .disabled(hasSubmitted)
                }
            }
            if isSingle {
                Section("优先展示") {
                    Picker("主标签", selection: $primaryID) {
                        Text("按牧场顺序选择").tag(UUID?.none)
                        ForEach(values.filter { selected.contains($0.id) && $0.isActive }) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                    }
                }
            }
            if hasIncompatible {
                Section {
                    Toggle("仅应用到符合条件的羊只", isOn: $applicableOnly)
                    Text("黄色仅公羊、绿色仅母羊；不适用的羊只不会添加该标签。已停用标签只能移除。").font(.footnote)
                }
            }
            if let message { Section { Text(verbatim: message) } }
        }
        .navigationTitle(isScopedRemoval ? "停用标签" : isSingle ? "编辑标签" : "批量标签")
        .sheet(isPresented: $isCreatingLabel) {
            NavigationStack {
                SheepLabelCatalogEditor(
                    account: account,
                    farm: farm,
                    initial: SheepLabelDraft(sortOrder: (catalog.map(\.sortOrder).max() ?? -1) + 1)
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(hasSubmitted ? "重试失败项" : "提交", action: save)
                    .disabled((hasIncompatible && !applicableOnly) || (hasSubmitted && failedIDs.isEmpty) || (!isSingle && selected.isEmpty))
            }
        }
        .onAppear {
            if isSingle, !hasSubmitted, let a = assignments.first(where: { sheepIDs.contains($0.sheepID) }) {
                selected = a.labelIDs; initial = a.labelIDs; primaryID = a.primaryLabelID; originalPrimaryID = primaryID
            }
        }
    }
    private func save() {
        var succeeded = 0; var failed = Set<UUID>(); var errors: [String] = []; var skipped = 0
        for sheep in targets {
            let a = assignments.first { $0.sheepID == sheep.id }
            let chosen = values.filter { selected.contains($0.id) }
            let allowed = chosen.filter { eligible($0, sheep) }.map(\.id)
            if !isSingle && allowed.isEmpty { skipped += 1; continue }
            var d = SheepLabelsEditDraft(sheepID: sheep.id)
            d.addIDs = isSingle ? Array(selected.subtracting(initial)) : operation == "remove" ? [] : allowed
            d.removeIDs = isSingle ? Array(initial.subtracting(selected)) : operation == "remove" ? Array(selected) : []
            d.setsPrimary = isSingle ? primaryID != originalPrimaryID : operation == "primary"
            d.primaryLabelID = isSingle ? primaryID : allowed.first
            d.expectedRevision = a?.revision ?? 0
            do {
                try FarmCommandService().execute(.care(.sheepLabels(.editLabels(d))), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: context)
                succeeded += 1
            } catch { failed.insert(sheep.id); errors.append("\(sheep.earTag)：\(error.localizedDescription)") }
        }
        failedIDs = failed; hasSubmitted = true
        message = "已提交 \(succeeded) 只，失败 \(failed.count) 只，跳过 \(skipped) 只。云端牧场以同步中心回执为准。" + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
    }
}

struct SheepLabelManagementView: View {
    @Environment(\.modelContext) private var context
    @Query private var catalog: [SheepLabelRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var query = ""
    @State private var draft: SheepLabelDraft?
    @State private var presentCounts: [UUID: Int] = [:]
    @State private var isLoadingCounts = true
    @State private var countLoadError: String?
    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account; self.farm = farm; let id = farm.id
        _catalog = Query(filter: #Predicate<SheepLabelRecord> { $0.farmID == id }, sort: \SheepLabelRecord.sortOrder)
    }
    var body: some View {
        List {
            Section { TextField("搜索标签名称", text: $query) }
            ForEach(catalog.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { label in
                NavigationLink {
                    SheepLabelMembersView(account: account, farm: farm, label: label.value)
                } label: {
                    HStack {
                        SheepLabelChips(labels: [label.value]); Spacer()
                        if isLoadingCounts {
                            ProgressView().controlSize(.small)
                        } else if countLoadError != nil {
                            Text("暂不可用").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(presentCounts[label.id, default: 0]) 只在群").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityHint("向左轻扫可编辑标签")
                .contextMenu {
                    Button("编辑标签") { draft = makeDraft(label) }.disabled(!canManage)
                    Button("彻底删除标签", role: .destructive) { draft = makeDraft(label) }.disabled(!canManage)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canManage {
                        Button("编辑", systemImage: "pencil") {
                            draft = makeDraft(label)
                        }
                        .tint(.blue)
                    }
                }
            }
            if catalog.isEmpty { ContentUnavailableView("尚无自定义标签", systemImage: "tag", description: Text("创建标签后，可在羊只详情或多选时添加。")) }
            if let countLoadError {
                Section {
                    Text("关联数量读取失败：\(countLoadError)").font(.footnote).foregroundStyle(.secondary)
                    Button("重新读取数量") { Task { await reloadPresentCounts() } }
                }
            }
        }.navigationTitle("标签管理")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("新建", systemImage: "plus") { draft = SheepLabelDraft(sortOrder: (catalog.map(\.sortOrder).max() ?? -1) + 1) }.disabled(!canManage) } }
            .sheet(item: $draft) { draft in
                NavigationStack { SheepLabelCatalogEditor(account: account, farm: farm, initial: draft) }
            }
            .task(id: farm.id) { await reloadPresentCounts() }
    }
    private var canManage: Bool { CapabilitySet(role: farm.role).allows(.manageCatalogs) }
    private func makeDraft(_ r: SheepLabelRecord) -> SheepLabelDraft { .init(id: r.id, name: r.name, color: r.value.color, note: r.note, sortOrder: r.sortOrder, isActive: r.isActive, expectedRevision: r.revision) }

    @MainActor
    private func reloadPresentCounts() async {
        isLoadingCounts = true
        countLoadError = nil
        do {
            let counts = try await SheepLabelManagementSnapshotActor(container: context.container).load(farmID: farm.id)
            try Task.checkCancellation()
            presentCounts = counts
        } catch is CancellationError {
            return
        } catch {
            presentCounts = [:]
            countLoadError = error.localizedDescription
        }
        isLoadingCounts = false
    }
}

private actor SheepLabelManagementSnapshotActor {
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID) throws -> [UUID: Int] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let presentIDs = Set(sheep.lazy.filter(\.isCurrentlyPresent).map(\.id))
        let assignments = try context.fetch(FetchDescriptor<SheepLabelAssignmentRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        var counts: [UUID: Int] = [:]
        for assignment in assignments where presentIDs.contains(assignment.sheepID) {
            for labelID in assignment.labelIDs {
                counts[labelID, default: 0] += 1
            }
        }
        try Task.checkCancellation()
        return counts
    }
}

private struct SheepLabelColorSelector: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: SheepLabelColor

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 5),
            spacing: 10
        ) {
            ForEach(SheepLabelColor.allCases) { color in
                Button { selection = color } label: {
                    VStack(spacing: 6) {
                        SheepLabelIcon(color: color, width: 32)
                        Text(color.title)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .padding(.vertical, 4)
                    .background(selection == color ? Color.accentColor.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selection == color ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selection == color ? 2 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selection == color {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                                .padding(3)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(color.title)，\(color.restriction)")
                .accessibilityAddTraits(selection == color ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SheepLabelCatalogEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let account: AccountProfile
    let farm: FarmRecord
    @State private var draft: SheepLabelDraft
    @State private var error: String?
    @State private var submitted = false
    @State private var confirmingDeletion = false
    init(account: AccountProfile, farm: FarmRecord, initial: SheepLabelDraft) { self.account = account; self.farm = farm; _draft = State(initialValue: initial) }
    var body: some View {
        Form {
            Section("标签") {
                TextField("名称", text: $draft.name)
                TextField("说明（可选）", text: $draft.note, axis: .vertical)
                    .lineLimit(1...3)
            }
            Section {
                SheepLabelColorSelector(selection: $draft.color)
            } header: {
                Text("颜色")
            } footer: {
                Text("\(draft.color.title) · \(draft.color.restriction)")
            }
            Section("管理") {
                Stepper("展示顺序：\(draft.sortOrder)", value: $draft.sortOrder, in: 0...9999)
                Toggle("启用", isOn: $draft.isActive)
            }
            if draft.expectedRevision > 0 {
                Section {
                    Button("彻底删除标签", role: .destructive) {
                        confirmingDeletion = true
                    }
                    Text("会从标签目录和所有羊只关联中永久移除，不能恢复。历史记录仍会保留当时的名称和颜色。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if draft.expectedRevision == 0 {
                Section {
                    DisclosureGroup("参考名称") {
                        ForEach(["重点观察", "留种候选", "资料待核对", "饲喂试验 A 组"], id: \.self) { name in Button(name) { draft.name = name } }
                    }
                }
            }
            if let error { Section { Text(verbatim: error) } }
        }.disabled(submitted).navigationTitle(draft.expectedRevision == 0 ? "新建标签" : "编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .alert("彻底删除“\(draft.name)”？", isPresented: $confirmingDeletion) {
                Button("取消", role: .cancel) { }
                Button("彻底删除", role: .destructive) { deleteLabel() }
            } message: {
                Text("这个标签会从标签目录和所有羊只上永久移除，之后无法恢复。")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("提交") {
                    do {
                        try FarmCommandService().execute(.care(.sheepLabels(.saveLabel(draft))), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: context)
                        submitted = true; error = "已提交，云端牧场以同步中心回执为准。"
                    } catch { self.error = error.localizedDescription }
                }.disabled(submitted || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
    }

    private func deleteLabel() {
        do {
            try FarmCommandService().execute(
                .care(.sheepLabels(.deleteLabel(.init(id: draft.id, expectedRevision: draft.expectedRevision)))),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: context
            )
            submitted = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SheepLabelMembersView: View {
    @Environment(\.modelContext) private var context
    let account: AccountProfile
    let farm: FarmRecord
    let label: SheepLabelValue
    @State private var present = true
    @State private var members: [SheepLabelMemberRow] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedMemberIDs = Set<UUID>()
    @State private var isRemovingLabel = false
    init(account: AccountProfile, farm: FarmRecord, label: SheepLabelValue) {
        self.account = account; self.farm = farm; self.label = label
    }
    var body: some View {
        List(selection: $selectedMemberIDs) {
            Picker("范围", selection: $present) { Text("在群").tag(true); Text("离群").tag(false) }.pickerStyle(.segmented)
            if isLoading {
                ProgressView("正在读取关联羊只")
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .listRowSeparator(.hidden)
            } else if let loadError {
                Section {
                    Text("读取关联羊只失败：\(loadError)").foregroundStyle(.secondary)
                    Button("重新读取") { Task { await reloadMembers() } }
                }
            } else if members.filter({ $0.isCurrentlyPresent == present }).isEmpty {
                ContentUnavailableView(
                    present ? "当前没有在群羊只" : "当前没有离群羊只",
                    systemImage: "tag",
                    description: Text("这个标签暂时没有符合范围的羊只。")
                )
            } else {
                ForEach(members.filter { $0.isCurrentlyPresent == present }) { member in
                    NavigationLink(member.earTag) {
                        SheepDetailEntryView(account: account, farm: farm, sheepID: member.id)
                    }
                    .tag(member.id)
                }
            }
        }.navigationTitle(label.name)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("停用此标签", systemImage: "tag.slash") {
                        isRemovingLabel = true
                    }
                    .disabled(selectedMemberIDs.isEmpty || !CapabilitySet(role: farm.role).allows(.recordProduction))
                }
            }
            .sheet(isPresented: $isRemovingLabel, onDismiss: {
                selectedMemberIDs.removeAll()
                Task { await reloadMembers() }
            }) {
                NavigationStack {
                    SheepLabelsEditor(
                        account: account,
                        farm: farm,
                        sheepIDs: selectedMemberIDs,
                        initialOperation: "remove",
                        initialSelectedIDs: [label.id]
                    )
                }
            }
            .task(id: label.id) { await reloadMembers() }
    }

    @MainActor
    private func reloadMembers() async {
        isLoading = true
        loadError = nil
        do {
            let loaded = try await SheepLabelMembersSnapshotActor(container: context.container)
                .load(farmID: farm.id, labelID: label.id)
            try Task.checkCancellation()
            members = loaded
        } catch is CancellationError {
            return
        } catch {
            members = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

private struct SheepLabelMemberRow: Identifiable, Sendable {
    let id: UUID
    let earTag: String
    let isCurrentlyPresent: Bool
}

private actor SheepLabelMembersSnapshotActor {
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID, labelID: UUID) throws -> [SheepLabelMemberRow] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let assignments = try context.fetch(FetchDescriptor<SheepLabelAssignmentRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let memberIDs = Set(assignments.filter { $0.labelIDs.contains(labelID) }.map(\.sheepID))
        guard !memberIDs.isEmpty else { return [] }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        return sheep
            .filter { memberIDs.contains($0.id) }
            .map { SheepLabelMemberRow(id: $0.id, earTag: $0.earTag, isCurrentlyPresent: $0.isCurrentlyPresent) }
            .sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
    }
}
