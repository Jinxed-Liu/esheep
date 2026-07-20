import SwiftData
import SwiftUI

enum FarmEventCategory: String, CaseIterable, Identifiable, Sendable {
    case herd
    case feeding
    case health
    case reproduction
    case inventory
    case note

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .herd: "羊群"
        case .feeding: "投喂"
        case .health: "健康"
        case .reproduction: "繁殖"
        case .inventory: "库存"
        case .note: "备注"
        }
    }

    var symbol: String {
        switch self {
        case .herd: "list.bullet.rectangle"
        case .feeding: "leaf"
        case .health: "cross.case"
        case .reproduction: "heart.text.clipboard"
        case .inventory: "shippingbox"
        case .note: "note.text"
        }
    }
}

struct FarmEventSnapshot: Identifiable, Sendable {
    let id: UUID
    let entityType: CloudEntityType
    let category: FarmEventCategory
    let occurredAt: Date
    let recordedAt: Date
    let title: String
    let subject: String
    let detail: String
    let note: String
    let fields: [FarmEventField]

    var searchableText: String {
        ([title, subject, detail, note] + fields.flatMap { [$0.label, $0.value] })
            .joined(separator: " ")
            .localizedLowercase
    }
}

struct FarmEventField: Sendable, Identifiable {
    let label: String
    let value: String

    var id: String { label + "\u{0}" + value }
}

actor FarmEventHistoryActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID) throws -> [FarmEventSnapshot] {
        let context = ModelContext(container)
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }
        let sheepName = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0.earTag) })
        let penName = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        let lotName = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<InventoryLotRecord>())
            .filter { $0.farmID == farmID }
            .map { ($0.id, $0.catalogName + ($0.batchNumber.isEmpty ? "" : " · " + $0.batchNumber)) })
        let semenName = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SemenRecord>())
            .filter { $0.farmID == farmID }
            .map { ($0.id, $0.code + ($0.batchNumber.isEmpty ? "" : " · " + $0.batchNumber)) })
        let subjectLinks = try context.fetch(FetchDescriptor<HealthSubjectLink>()).filter { $0.farmID == farmID }
        let subjectIDsByHealthID = Dictionary(grouping: subjectLinks, by: \.healthRecordID)
            .mapValues { $0.map(\.sheepID) }

        var events = [FarmEventSnapshot]()
        events.reserveCapacity(sheep.count * 2)

        events.append(contentsOf: sheep.compactMap { record in
            guard record.deletedAt == nil, !record.isHistoricalArchive else { return nil }
            let location = record.initialPenID.flatMap { penName[$0] } ?? "未分圈"
            return FarmEventSnapshot(
                id: record.id,
                entityType: .sheep,
                category: .herd,
                occurredAt: record.enteredAt,
                recordedAt: record.createdAt,
                title: "新建羊只",
                subject: record.earTag,
                detail: "\(record.sex.displayName) · \(record.breed) · \(location)",
                note: record.note,
                fields: [
                    .init(label: "耳号", value: record.earTag),
                    .init(label: "性别", value: record.sex.displayName),
                    .init(label: "品种", value: record.breed),
                    .init(label: "入场圈舍", value: location)
                ]
            )
        })

        let weights = try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        events.append(contentsOf: weights.map { record in
            FarmEventSnapshot(
                id: record.id, entityType: .weight, category: .herd,
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: "称重", subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: "\(record.kilogramsText) 千克", note: record.note,
                fields: [.init(label: "体重", value: "\(record.kilogramsText) 千克")]
            )
        })

        let weanings = try context.fetch(FetchDescriptor<WeaningRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        events.append(contentsOf: weanings.map { record in
            FarmEventSnapshot(
                id: record.id, entityType: .weaning, category: .herd,
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: "断奶", subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: "断奶重 \(record.weanWeightText) 千克", note: record.note,
                fields: [
                    .init(label: "断奶重", value: "\(record.weanWeightText) 千克"),
                    .init(label: "母本", value: record.damID.flatMap { sheepName[$0] } ?? record.legacyDamEarTag ?? "未关联")
                ]
            )
        })

        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        events.append(contentsOf: transfers.map { record in
            let from = record.fromPenID.flatMap { penName[$0] } ?? "未分圈"
            let to = record.toPenID.flatMap { penName[$0] } ?? "未分圈"
            return FarmEventSnapshot(
                id: record.id, entityType: .transfer, category: .herd,
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: "转群", subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: "\(from) → \(to)", note: record.note,
                fields: [.init(label: "原圈舍", value: from), .init(label: "目标圈舍", value: to)]
            )
        })

        let removals = try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        events.append(contentsOf: removals.map { record in
            FarmEventSnapshot(
                id: record.id, entityType: .removal, category: .herd,
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: record.kind.displayName, subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: record.reason, note: record.note,
                fields: [
                    .init(label: "类型", value: record.kind.displayName),
                    .init(label: "原因", value: record.reason),
                    .init(label: "金额", value: record.amountText ?? "未填写")
                ]
            )
        })

        let feeds = try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        events.append(contentsOf: feeds.map { record in
            let location = penName[record.penID] ?? "未知圈舍"
            let meal = record.mealName.isEmpty ? record.mode.displayName : record.mealName
            return FarmEventSnapshot(
                id: record.id, entityType: .feed, category: .feeding,
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: "投喂", subject: location, detail: meal, note: record.note,
                fields: [
                    .init(label: "圈舍", value: location),
                    .init(label: "方式", value: record.mode.displayName),
                    .init(label: "班次", value: record.mealName.isEmpty ? "未填写" : record.mealName),
                    .init(label: "饲喂员", value: record.feederName.isEmpty ? "未填写" : record.feederName)
                ]
            )
        })

        let health = try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        events.append(contentsOf: health.map { record in
            let linkedNames = (subjectIDsByHealthID[record.id] ?? []).compactMap { sheepName[$0] }
            let subject: String
            if !linkedNames.isEmpty {
                subject = linkedNames.count == 1 ? linkedNames[0] : "\(linkedNames.count) 只羊"
            } else if let sheepID = record.sheepID {
                subject = sheepName[sheepID] ?? "未知羊只"
            } else if let penID = record.penID {
                subject = penName[penID] ?? "未知圈舍"
            } else {
                subject = "未关联对象"
            }
            return FarmEventSnapshot(
                id: record.id, entityType: .health, category: .health,
                occurredAt: record.occurredAt, recordedAt: record.createdAt,
                title: record.kind.displayName, subject: subject,
                detail: record.itemNameSnapshot, note: record.note,
                fields: [
                    .init(label: "项目", value: record.itemNameSnapshot),
                    .init(label: "对象", value: linkedNames.isEmpty ? subject : linkedNames.joined(separator: "、")),
                    .init(label: "剂量", value: [record.quantityText ?? "", record.unit].filter { !$0.isEmpty }.joined(separator: " ")),
                    .init(label: "途径", value: record.route.isEmpty ? "未填写" : record.route)
                ]
            )
        })

        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        events.append(contentsOf: reproduction.map { record in
            var detail = record.result
            if record.kind == .lambing { detail = "产羔 \(record.lambCount) 只" }
            if detail.isEmpty { detail = record.semenNameSnapshot ?? record.sireID.flatMap { sheepName[$0] } ?? "已录入" }
            return FarmEventSnapshot(
                id: record.id, entityType: .reproduction, category: .reproduction,
                occurredAt: record.occurredAt, recordedAt: record.createdAt,
                title: record.kind.displayName, subject: sheepName[record.eweID] ?? "未知母羊",
                detail: detail, note: record.note,
                fields: [
                    .init(label: "母羊", value: sheepName[record.eweID] ?? "未知母羊"),
                    .init(label: "公羊", value: record.sireID.flatMap { sheepName[$0] } ?? "未关联"),
                    .init(label: "冻精", value: record.semenNameSnapshot ?? "未使用"),
                    .init(label: "结果", value: record.result.isEmpty ? "未填写" : record.result)
                ]
            )
        })

        let notes = try context.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        events.append(contentsOf: notes.map { record in
            let target = record.sheepID.flatMap { sheepName[$0] } ?? record.penID.flatMap { penName[$0] } ?? "未关联对象"
            return FarmEventSnapshot(
                id: record.id, entityType: .note, category: .note,
                occurredAt: record.occurredAt, recordedAt: record.createdAt,
                title: "备注", subject: target, detail: record.text, note: "",
                fields: [.init(label: "内容", value: record.text)]
            )
        })

        let inventoryTransactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.kind != .consumption && !$0.note.hasPrefix("删除健康记录反向恢复库存：")
        }
        events.append(contentsOf: inventoryTransactions.map { record in
            let kind = record.kind == .receipt ? "药品疫苗入库" : "药品疫苗盘点"
            return FarmEventSnapshot(
                id: record.id, entityType: .inventoryTransaction, category: .inventory,
                occurredAt: record.occurredAt, recordedAt: record.createdAt,
                title: kind, subject: lotName[record.inventoryLotID] ?? "未知批次",
                detail: signedQuantity(record.quantityText, kind: record.kind), note: record.note,
                fields: [.init(label: "数量变化", value: signedQuantity(record.quantityText, kind: record.kind))]
            )
        })

        let semenTransactions = try context.fetch(FetchDescriptor<SemenTransactionRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.kind != .consumption && !$0.note.hasPrefix("撤销繁殖记录反向恢复冻精：")
        }
        events.append(contentsOf: semenTransactions.map { record in
            let kind = record.kind == .receipt ? "冻精入库" : "冻精盘点"
            return FarmEventSnapshot(
                id: record.id, entityType: .semenTransaction, category: .inventory,
                occurredAt: record.occurredAt, recordedAt: record.createdAt,
                title: kind, subject: semenName[record.semenID] ?? "未知冻精批次",
                detail: signedQuantity(record.quantityText, kind: record.kind), note: record.note,
                fields: [.init(label: "数量变化", value: signedQuantity(record.quantityText, kind: record.kind))]
            )
        })

        return events.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    private func signedQuantity(_ text: String, kind: InventoryTransactionKind) -> String {
        kind == .receipt && !text.hasPrefix("-") ? "+\(text)" : text
    }

    private func signedQuantity(_ text: String, kind: SemenTransactionKind) -> String {
        kind == .receipt && !text.hasPrefix("-") ? "+\(text)" : text
    }
}

struct FarmEventHistoryView: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord

    @State private var events = [FarmEventSnapshot]()
    @State private var category: FarmEventCategory?
    @State private var query = ""
    @State private var pendingDeletion: FarmEventSnapshot?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var canDelete: Bool {
        CapabilitySet(role: farm.role).allows(.deleteProtectedFacts)
    }

    private var visibleEvents: [FarmEventSnapshot] {
        events.filter { event in
            (category == nil || event.category == category) &&
                (query.isEmpty || event.searchableText.contains(query.localizedLowercase))
        }
    }

    var body: some View {
        List {
            if isLoading && events.isEmpty {
                HStack { Spacer(); ProgressView("正在整理事件记录"); Spacer() }
                    .listRowBackground(Color.clear)
            } else if visibleEvents.isEmpty {
                ContentUnavailableView(
                    query.isEmpty && category == nil ? "暂无事件记录" : "没有匹配的事件",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("生产录入完成后会按发生时间倒序显示在这里。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleEvents) { event in
                    NavigationLink {
                        FarmEventDetailView(event: event)
                    } label: {
                        FarmEventRow(event: event)
                    }
                    .listRowInsets(.init(top: 7, leading: 16, bottom: 7, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canDelete {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                pendingDeletion = event
                            }
                        }
                    }
                    .contextMenu {
                        if canDelete {
                            Button("删除事件", systemImage: "trash", role: .destructive) {
                                pendingDeletion = event
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("事件记录")
        .searchable(text: $query, prompt: "搜索耳号、圈舍、项目或备注")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全部事件", systemImage: category == nil ? "checkmark" : "clock") { category = nil }
                    ForEach(FarmEventCategory.allCases) { item in
                        Button(item.displayName, systemImage: category == item ? "checkmark" : item.symbol) { category = item }
                    }
                } label: {
                    Image(systemName: category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("筛选事件")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !canDelete {
                Text("当前角色可查看事件，但没有删除权威事实的权限。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .task(id: farm.id) { await reload() }
        .refreshable { await reload() }
        .sheet(item: $pendingDeletion, onDismiss: { Task { await reload() } }) { event in
            FarmEventDeletionSheet(account: account, farm: farm, event: event)
                .presentationDetents([.medium])
        }
        .recordErrorAlert($errorMessage)
    }

    @MainActor
    private func reload() async {
        isLoading = true
        do {
            events = try await FarmEventHistoryActor(container: modelContext.container).load(farmID: farm.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "读取事件记录失败：\(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct FarmEventRow: View {
    let event: FarmEventSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: event.category.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.brand)
                .frame(width: 30, height: 30)
                .background(AppTheme.brand.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.subheadline.weight(.semibold))
                Text(event.subject).font(.subheadline)
                if !event.detail.isEmpty {
                    Text(event.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FarmEventDetailView: View {
    let event: FarmEventSnapshot

    var body: some View {
        List {
            Section("事件") {
                LabeledContent("类型", value: event.title)
                LabeledContent("对象", value: event.subject)
                LabeledContent("发生时间") {
                    Text(event.occurredAt, format: .dateTime.year().month().day().hour().minute())
                }
                LabeledContent("录入时间") {
                    Text(event.recordedAt, format: .dateTime.year().month().day().hour().minute())
                }
            }
            if !event.fields.isEmpty {
                Section("内容") {
                    ForEach(event.fields) { field in
                        LabeledContent(field.label, value: field.value.isEmpty ? "未填写" : field.value)
                    }
                }
            }
            if !event.note.isEmpty {
                Section("备注") { Text(event.note) }
            }
        }
        .navigationTitle("事件详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FarmEventDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let farm: FarmRecord
    let event: FarmEventSnapshot

    @State private var reason = "录入错误"
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("将删除") {
                    LabeledContent(event.title, value: event.subject)
                    Text(event.occurredAt, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("请填写删除原因", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("删除原因")
                } footer: {
                    Text("删除会撤销底层权威事实并同步重算关联历史；健康、繁殖事件还会反冲库存并重建提醒。审计记录不会被抹除。")
                }
            }
            .navigationTitle("删除事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("删除", role: .destructive) { delete() }
                        .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDeleting)
                }
            }
            .disabled(isDeleting)
            .overlay { if isDeleting { ProgressView("正在同步删除") } }
            .recordErrorAlert($errorMessage)
        }
    }

    private func delete() {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try FarmCommandService().execute(
                .tombstoneEntity(
                    entityType: event.entityType,
                    entityID: event.id,
                    reason: "事件记录删除：" + reason.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                context: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
