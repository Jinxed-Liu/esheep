import SwiftData
import SwiftUI

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
            Button("编辑标签") { editing = true }.disabled(!CapabilitySet(role: farm.role).allows(.recordProduction))
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
    init(account: AccountProfile, farm: FarmRecord, sheepIDs: Set<UUID>) {
        self.account = account; self.farm = farm; self.sheepIDs = sheepIDs
        let id = farm.id
        _catalog = Query(filter: #Predicate<SheepLabelRecord> { $0.farmID == id }, sort: \SheepLabelRecord.sortOrder)
        _sheep = Query(filter: #Predicate<SheepRecord> { $0.farmID == id && $0.deletedAt == nil })
        _assignments = Query(filter: #Predicate<SheepLabelAssignmentRecord> { $0.farmID == id })
    }
    private var targets: [SheepRecord] { sheep.filter { sheepIDs.contains($0.id) && (!hasSubmitted || failedIDs.contains($0.id)) } }
    private var isSingle: Bool { sheepIDs.count == 1 }
    private var values: [SheepLabelValue] { catalog.map(\.value) }
    private func eligible(_ label: SheepLabelValue, _ sheep: SheepRecord) -> Bool { operation == "remove" || (label.isActive && label.color.allows(sheep.sex)) }
    private var hasIncompatible: Bool { !isSingle && values.contains { label in selected.contains(label.id) && targets.contains { !eligible(label, $0) } } }
    var body: some View {
        Form {
            if !isSingle {
                Section("操作范围：\(targets.count) 只") {
                    Picker("操作", selection: $operation) {
                        Text("添加标签").tag("add"); Text("移除标签").tag("remove"); Text("设为主标签").tag("primary")
                    }.onChange(of: operation) { selected.removeAll(); applicableOnly = false }
                }
            }
            Section("选择标签") {
                TextField("搜索标签名称", text: $query)
                ForEach(values.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { label in
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
                if catalog.isEmpty { Text("牧场尚未创建标签，请在标签管理中创建。") }
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
        .navigationTitle(isSingle ? "编辑标签" : "批量标签")
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
    @Query private var assignments: [SheepLabelAssignmentRecord]
    @Query private var sheep: [SheepRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @State private var query = ""
    @State private var draft: SheepLabelDraft?
    @State private var editing = false
    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account; self.farm = farm; let id = farm.id
        _catalog = Query(filter: #Predicate<SheepLabelRecord> { $0.farmID == id }, sort: \SheepLabelRecord.sortOrder)
        _assignments = Query(filter: #Predicate<SheepLabelAssignmentRecord> { $0.farmID == id })
        _sheep = Query(filter: #Predicate<SheepRecord> { $0.farmID == id && $0.deletedAt == nil })
    }
    var body: some View {
        List {
            Section { TextField("搜索标签名称", text: $query) }
            ForEach(catalog.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { label in
                let ids = Set(assignments.filter { $0.labelIDs.contains(label.id) }.map(\.sheepID))
                NavigationLink {
                    SheepLabelMembersView(account: account, farm: farm, label: label.value)
                } label: {
                    HStack {
                        SheepLabelChips(labels: [label.value]); Spacer()
                        Text("\(sheep.filter { ids.contains($0.id) && $0.isCurrentlyPresent }.count) 只在群").font(.caption).foregroundStyle(.secondary)
                    }
                }.contextMenu {
                    Button("编辑标签") { draft = makeDraft(label); editing = true }.disabled(!canManage)
                }
                if canManage { Button("编辑 \(label.name)") { draft = makeDraft(label); editing = true }.font(.caption) }
            }
            if catalog.isEmpty { ContentUnavailableView("尚无自定义标签", systemImage: "tag", description: Text("创建标签后，可在羊只详情或多选时添加。")) }
        }.navigationTitle("标签管理")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("新建", systemImage: "plus") { draft = SheepLabelDraft(sortOrder: (catalog.map(\.sortOrder).max() ?? -1) + 1); editing = true }.disabled(!canManage) } }
            .sheet(isPresented: $editing) { if let draft { NavigationStack { SheepLabelCatalogEditor(account: account, farm: farm, initial: draft) } } }
    }
    private var canManage: Bool { CapabilitySet(role: farm.role).allows(.manageCatalogs) }
    private func makeDraft(_ r: SheepLabelRecord) -> SheepLabelDraft { .init(id: r.id, name: r.name, color: r.value.color, note: r.note, sortOrder: r.sortOrder, isActive: r.isActive, expectedRevision: r.revision) }
}

private struct SheepLabelCatalogEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let account: AccountProfile
    let farm: FarmRecord
    @State private var draft: SheepLabelDraft
    @State private var error: String?
    @State private var submitted = false
    init(account: AccountProfile, farm: FarmRecord, initial: SheepLabelDraft) { self.account = account; self.farm = farm; _draft = State(initialValue: initial) }
    var body: some View {
        Form {
            Section("标签") {
                TextField("名称", text: $draft.name)
                Picker("颜色", selection: $draft.color) {
                    ForEach(SheepLabelColor.allCases) { color in HStack { SheepLabelIcon(color: color); Text(color.title) }.tag(color) }
                }
                Text(draft.color.restriction).foregroundStyle(.secondary)
                TextField("说明（可选）", text: $draft.note, axis: .vertical)
                Stepper("展示顺序：\(draft.sortOrder)", value: $draft.sortOrder, in: 0...9999)
                Toggle("启用", isOn: $draft.isActive)
            }
            if draft.expectedRevision == 0 {
                Section("名称示例") {
                    ForEach(["重点观察", "留种候选", "资料待核对", "饲喂试验 A 组"], id: \.self) { name in Button(name) { draft.name = name } }
                }
            }
            if let error { Section { Text(verbatim: error) } }
        }.disabled(submitted).navigationTitle(draft.expectedRevision == 0 ? "新建标签" : "编辑标签")
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
}

private struct SheepLabelMembersView: View {
    @Query private var sheep: [SheepRecord]
    @Query private var assignments: [SheepLabelAssignmentRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let label: SheepLabelValue
    @State private var present = true
    init(account: AccountProfile, farm: FarmRecord, label: SheepLabelValue) {
        self.account = account; self.farm = farm; self.label = label; let id = farm.id
        _sheep = Query(filter: #Predicate<SheepRecord> { $0.farmID == id && $0.deletedAt == nil })
        _assignments = Query(filter: #Predicate<SheepLabelAssignmentRecord> { $0.farmID == id })
    }
    var body: some View {
        let ids = Set(assignments.filter { $0.labelIDs.contains(label.id) }.map(\.sheepID))
        List {
            Picker("范围", selection: $present) { Text("在群").tag(true); Text("离群").tag(false) }.pickerStyle(.segmented)
            ForEach(sheep.filter { ids.contains($0.id) && $0.isCurrentlyPresent == present }) { sheep in
                NavigationLink(sheep.earTag) { SheepDetailEntryView(account: account, farm: farm, sheepID: sheep.id) }
            }
        }.navigationTitle(label.name)
    }
}
