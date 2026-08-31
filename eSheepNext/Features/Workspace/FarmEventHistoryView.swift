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
    /// Sheep profiles that are factual participants in this event. Spotlight
    /// uses IDs rather than matching the rendered subject text so batch health
    /// records and similarly named animals remain correctly isolated.
    let relatedSheepIDs: [UUID]
    let occurredAt: Date
    let recordedAt: Date
    let title: String
    let subject: String
    let detail: String
    let note: String
    let fields: [FarmEventField]
    /// 从档案字段投影出的生命周期事实没有可独立删除的底层实体。
    let isDerived: Bool
    let searchableText: String

    init(
        id: UUID,
        entityType: CloudEntityType,
        category: FarmEventCategory,
        relatedSheepIDs: [UUID] = [],
        occurredAt: Date,
        recordedAt: Date,
        title: String,
        subject: String,
        detail: String,
        note: String,
        fields: [FarmEventField],
        isDerived: Bool = false
    ) {
        self.id = id
        self.entityType = entityType
        self.category = category
        self.relatedSheepIDs = Array(Set(relatedSheepIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.title = title
        self.subject = subject
        self.detail = detail
        self.note = note
        self.fields = fields
        self.isDerived = isDerived
        searchableText = FarmEventSearch.normalized(
            ([title, subject, detail, note] + fields.flatMap { [$0.label, $0.value] })
                .joined(separator: " ")
        )
    }
}

struct FarmEventField: Sendable, Identifiable {
    let label: String
    let value: String

    var id: String { label + "\u{0}" + value }
}

struct FarmEventRowIdentity: Hashable, Sendable {
    let entityType: String
    let entityID: UUID
}

extension FarmEventSnapshot {
    var rowIdentity: FarmEventRowIdentity {
        FarmEventRowIdentity(entityType: entityType.rawValue, entityID: id)
    }

    var editCapability: FarmCapability? {
        guard !isDerived else { return nil }
        return switch entityType {
        case .sheep:
            .recordProduction
        case .weight, .transfer, .removal, .health, .reproduction:
            .editHistoricalFacts
        case .feed where title == "TMR 投喂":
            .editHistoricalFacts
        default:
            nil
        }
    }

    var isRestorableBatchDeparture: Bool {
        entityType == .batchMembership && title == "移出批次"
    }
}

enum FarmEventSearch {
    static func normalized(_ value: String) -> String {
        SearchText.normalized(value)
    }

    static func filter(
        _ events: [FarmEventSnapshot],
        query: String,
        category: FarmEventCategory?,
        scope: FarmEventExportScope
    ) -> [FarmEventSnapshot] {
        let normalizedQuery = normalized(query)
        return events.filter { event in
            (category == nil || event.category == category) &&
                scope.includes(event) &&
                (normalizedQuery.isEmpty || event.searchableText.contains(normalizedQuery))
        }
    }
}

actor FarmEventHistoryActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID) throws -> [FarmEventSnapshot] {
        let context = ModelContext(container)
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let sheepByID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        let sheepName = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0.earTag) })
        let penName = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let lotName = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<InventoryLotRecord>(predicate: #Predicate {
                $0.farmID == farmID
            }))
            .map { ($0.id, $0.catalogName + ($0.batchNumber.isEmpty ? "" : " · " + $0.batchNumber)) })
        let semenName = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SemenRecord>(predicate: #Predicate {
                $0.farmID == farmID
            }))
            .map { ($0.id, $0.code + ($0.batchNumber.isEmpty ? "" : " · " + $0.batchNumber)) })
        let subjectLinks = try context.fetch(FetchDescriptor<HealthSubjectLink>(predicate: #Predicate {
            $0.farmID == farmID
        }))
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
                relatedSheepIDs: [record.id],
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

        events.append(contentsOf: sheep.compactMap { record in
            guard record.deletedAt == nil,
                  !record.isHistoricalArchive,
                  let birthAt = record.birthAt else { return nil }
            let initialPen = record.initialPenID.flatMap { penName[$0] } ?? "未分圈"
            let dam = record.damID.flatMap { sheepName[$0] } ?? "未关联"
            let sire = record.sireID.flatMap { sheepName[$0] }
                ?? record.semenDonorNameSnapshot
                ?? "未关联"
            return FarmEventSnapshot(
                id: StableCloudUUID.derived(namespace: record.id, name: "farm-event-birth"),
                entityType: .sheep,
                category: .herd,
                relatedSheepIDs: [record.id],
                occurredAt: birthAt,
                recordedAt: record.createdAt,
                title: "出生",
                subject: record.earTag,
                detail: "\(record.sex.displayName) · \(record.breed)",
                note: "",
                fields: [
                    .init(label: "耳号", value: record.earTag),
                    .init(label: "性别", value: record.sex.displayName),
                    .init(label: "品种", value: record.breed),
                    .init(label: "出生日期", value: dateFormatter.string(from: birthAt)),
                    .init(label: "初始圈舍", value: initialPen),
                    .init(label: "母本", value: dam),
                    .init(label: "父本来源", value: sire),
                    .init(label: "羊只档案ID", value: record.id.uuidString.lowercased())
                ],
                isDerived: true
            )
        })

        let weights = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let gainSamplesBySheepID = Dictionary(
            grouping: WeaningGainSemantics.samples(from: weights, farmID: farmID),
            by: \.sheepID
        )
        events.append(contentsOf: weights.map { record in
            return FarmEventSnapshot(
                id: record.id, entityType: .weight, category: .herd,
                relatedSheepIDs: [record.sheepID],
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: "称重", subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: "\(record.kilogramsText) 千克", note: record.note,
                fields: [.init(label: "体重", value: "\(record.kilogramsText) 千克")]
            )
        })

        let weanings = try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        events.append(contentsOf: weanings.map { record in
            let child = sheepByID[record.sheepID]
            let birthAt = record.birthAt ?? child?.birthAt
            let dam = record.damID.flatMap { sheepName[$0] }
                ?? child?.damID.flatMap { sheepName[$0] }
                ?? record.legacyDamEarTag
                ?? "未关联"
            let sire = child?.sireID.flatMap { sheepName[$0] }
                ?? child?.semenDonorNameSnapshot
                ?? "未关联"
            let currentPen = child?.currentPenID.flatMap { penName[$0] } ?? "未分圈"
            let gainSamples = gainSamplesBySheepID[record.sheepID] ?? []
            let gainBaseline = WeaningGainSemantics.earliestBaseline(
                sheepID: record.sheepID,
                birthAt: birthAt,
                weaningAt: record.occurredAt,
                samples: gainSamples
            )
            let gain = WeaningGainSemantics.calculate(
                sheepID: record.sheepID,
                birthAt: birthAt,
                weaningAt: record.occurredAt,
                weaningWeight: NSDecimalNumber(decimal: record.weanWeight).doubleValue,
                samples: gainSamples
            )
            return FarmEventSnapshot(
                id: record.id, entityType: .weaning, category: .herd,
                relatedSheepIDs: [record.sheepID],
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: "断奶", subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: "断奶重 \(record.weanWeightText) 千克", note: record.note,
                fields: [
                    .init(label: "耳号", value: child?.earTag ?? "未知羊只"),
                    .init(label: "性别", value: child?.sex.displayName ?? "未知"),
                    .init(label: "品种", value: child?.breed ?? ""),
                    .init(label: "状态", value: child?.status.displayName ?? "未知"),
                    .init(label: "当前圈舍", value: currentPen),
                    .init(label: "出生日期", value: birthAt.map(dateFormatter.string(from:)) ?? ""),
                    .init(label: "断奶重kg", value: record.weanWeightText),
                    .init(label: "出生重kg", value: record.birthWeightText ?? ""),
                    .init(label: "日增重起算体重kg", value: gainBaseline?.kilogramsText ?? ""),
                    .init(label: "日增重起算日期", value: gainBaseline.map { dateFormatter.string(from: $0.occurredAt) } ?? ""),
                    .init(label: "日增重计算天数", value: gain.map { String($0.intervalDays) } ?? ""),
                    .init(label: "日增重kg/天", value: gain?.kilogramsPerDayText ?? ""),
                    .init(label: "母本", value: dam),
                    .init(label: "父本来源", value: sire),
                    .init(label: "胎只数", value: record.litterSize.map { String($0) } ?? "")
                ]
            )
        })

        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        events.append(contentsOf: transfers.map { record in
            let from = record.fromPenID.flatMap { penName[$0] } ?? "未分圈"
            let to = record.toPenID.flatMap { penName[$0] } ?? "未分圈"
            return FarmEventSnapshot(
                id: record.id, entityType: .transfer, category: .herd,
                relatedSheepIDs: [record.sheepID],
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: "转群", subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: "\(from) → \(to)", note: record.note,
                fields: [.init(label: "原圈舍", value: from), .init(label: "目标圈舍", value: to)]
            )
        })

        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let removalBatchCounts = Dictionary(grouping: removals.compactMap { record in
            record.removalBatchID.map { ($0, record.id) }
        }, by: \.0).mapValues(\.count)
        events.append(contentsOf: removals.map { record in
            var fields = [
                FarmEventField(label: "类型", value: record.kind.displayName),
                FarmEventField(label: "原因", value: record.reason)
            ]
            if let batchID = record.removalBatchID {
                fields.append(.init(label: "同批离场数量", value: "\(removalBatchCounts[batchID] ?? 1) 只"))
                if record.kind == .sold {
                    fields.append(.init(label: "同批总售卖金额", value: record.batchTotalAmountText ?? "未填写"))
                }
            } else {
                fields.append(.init(label: "售卖金额", value: record.amountText ?? "未填写"))
            }
            return FarmEventSnapshot(
                id: record.id, entityType: .removal, category: .herd,
                relatedSheepIDs: [record.sheepID],
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: record.kind.displayName, subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: record.reason, note: record.note,
                fields: fields
            )
        })

        let productionBatches = try context.fetch(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).filter {
            $0.sourceRawValue == ProductionBatchSource.manual.rawValue
        }
        let productionBatchByID = Dictionary(uniqueKeysWithValues: productionBatches.map { ($0.id, $0) })
        let batchMemberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        events.append(contentsOf: batchMemberships.compactMap { record in
            guard let leftAt = record.leftAt,
                  let batch = productionBatchByID[record.batchID] else {
                return nil
            }
            let trimmedReason = record.leaveReason?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedReason = (trimmedReason?.isEmpty == false ? trimmedReason : nil)
                ?? "手工移出批次"
            return FarmEventSnapshot(
                id: record.id,
                entityType: .batchMembership,
                category: .herd,
                relatedSheepIDs: [record.sheepID],
                occurredAt: leftAt,
                recordedAt: record.updatedAt,
                title: "移出批次",
                subject: sheepName[record.sheepID] ?? "未知羊只",
                detail: "\(batch.name) · \(normalizedReason)",
                note: "",
                fields: [
                    .init(label: "生产批次", value: batch.name),
                    .init(label: "生产目的", value: batch.purpose),
                    .init(label: "加入时间", value: record.joinedAt.formatted(date: .numeric, time: .shortened)),
                    .init(label: "移出时间", value: leftAt.formatted(date: .numeric, time: .shortened)),
                    .init(label: "移出原因", value: normalizedReason)
                ]
            )
        })

        let feedLines = try context.fetch(FetchDescriptor<FeedRecordLine>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let feedLinesByRecordID = Dictionary(grouping: feedLines, by: \.feedRecordID)
        let feeds = try context.fetch(FetchDescriptor<FeedRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let tmrAllocations = try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let tmrAllocationByFeedID = Dictionary(grouping: tmrAllocations, by: \.feedRecordID)
            .compactMapValues { values in
                values.max {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            }
        let tmrRunIDs = Set(tmrAllocations.map(\.runID))
        let currentFarmID = farmID
        let tmrRuns = try context.fetch(FetchDescriptor<TMRFeedingRunRecord>(predicate: #Predicate {
            $0.farmID == currentFarmID && $0.deletedAt == nil
        })).filter { tmrRunIDs.contains($0.id) }
        let tmrRunByID = Dictionary(uniqueKeysWithValues: tmrRuns.map { ($0.id, $0) })
        events.append(contentsOf: feeds.map { record in
            let location = penName[record.penID] ?? "未知圈舍"
            let meal = record.mealName.isEmpty ? record.mode.displayName : record.mealName
            let tmrAllocation = tmrAllocationByFeedID[record.id]
            let tmrRun = tmrAllocation.flatMap { tmrRunByID[$0.runID] }
            let lines = (feedLinesByRecordID[record.id] ?? [])
                .sorted { $0.ingredientNameSnapshot.localizedStandardCompare($1.ingredientNameSnapshot) == .orderedAscending }
                .map {
                    let unit = ($0.unitSnapshot?.isEmpty == false ? $0.unitSnapshot : nil) ?? "千克"
                    return "\($0.ingredientNameSnapshot) \($0.kilogramsText) \(unit)"
                }
                .joined(separator: "；")
            var fields = [
                FarmEventField(label: "圈舍", value: location),
                .init(label: "来源", value: tmrRun == nil ? "直接投喂" : "TMR 投喂"),
                .init(label: "方式", value: record.mode.displayName),
                .init(label: "顿次", value: record.mealName.isEmpty ? "未填写" : record.mealName),
                .init(label: "原料明细", value: lines),
                .init(label: "剩料kg", value: record.remainingKilogramsText ?? ""),
                .init(label: "废弃kg", value: record.discardedKilogramsText ?? "")
            ]
            if let tmrRun, let tmrAllocation {
                fields.append(.init(label: "TMR批次", value: tmrRun.batchCodeSnapshot))
                fields.append(.init(label: "TMR配方", value: "\(tmrRun.formulaNameSnapshot) v\(tmrRun.formulaRevision)"))
                fields.append(.init(label: "实际TMR kg", value: tmrAllocation.actualKilogramsText))
                fields.append(.init(label: "目标TMR kg", value: tmrAllocation.targetKilogramsTextSnapshot ?? ""))
            } else {
                fields.append(.init(label: "旧位置备注", value: record.feederName.isEmpty ? "无" : record.feederName))
            }
            return FarmEventSnapshot(
                id: record.id, entityType: .feed, category: .feeding,
                occurredAt: record.occurredAt, recordedAt: record.recordedAt,
                title: tmrRun == nil ? "直接投喂" : "TMR 投喂",
                subject: location, detail: meal, note: record.note,
                fields: fields
            )
        })

        let health = try context.fetch(FetchDescriptor<HealthRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        events.append(contentsOf: health.map { record in
            let linkedIDs = subjectIDsByHealthID[record.id] ?? []
            let relatedSheepIDs = linkedIDs + [record.sheepID].compactMap { $0 }
            let linkedNames = linkedIDs.compactMap { sheepName[$0] }
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
                relatedSheepIDs: relatedSheepIDs,
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

        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        events.append(contentsOf: reproduction.map { record in
            var detail = record.result
            if record.kind == .lambing { detail = "产羔 \(record.lambCount) 只" }
            if detail.isEmpty { detail = record.semenNameSnapshot ?? record.sireID.flatMap { sheepName[$0] } ?? "已录入" }
            return FarmEventSnapshot(
                id: record.id, entityType: .reproduction, category: .reproduction,
                relatedSheepIDs: [record.eweID] + [record.sireID].compactMap { $0 },
                occurredAt: record.occurredAt, recordedAt: record.createdAt,
                title: record.kind.displayName, subject: sheepName[record.eweID] ?? "未知母羊",
                detail: detail, note: record.note,
                fields: [
                    .init(label: "母羊", value: sheepName[record.eweID] ?? "未知母羊"),
                    .init(label: "公羊", value: record.sireID.flatMap { sheepName[$0] } ?? "未关联"),
                    .init(label: "冻精", value: record.semenNameSnapshot ?? "未使用"),
                    .init(label: "冻精供体", value: record.semenDonorNameSnapshot ?? ""),
                    .init(label: "胎次", value: record.parity.map { String($0) } ?? ""),
                    .init(label: "产羔数", value: record.kind == .lambing ? String(record.lambCount) : ""),
                    .init(label: "死胎数", value: record.birthDeadCount.map { String($0) } ?? ""),
                    .init(label: "结果", value: record.result.isEmpty ? "未填写" : record.result)
                ]
            )
        })

        let notes = try context.fetch(FetchDescriptor<NoteRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        events.append(contentsOf: notes.map { record in
            let target = record.sheepID.flatMap { sheepName[$0] } ?? record.penID.flatMap { penName[$0] } ?? "未关联对象"
            return FarmEventSnapshot(
                id: record.id, entityType: .note, category: .note,
                relatedSheepIDs: [record.sheepID].compactMap { $0 },
                occurredAt: record.occurredAt, recordedAt: record.createdAt,
                title: "备注", subject: target, detail: record.text, note: "",
                fields: [.init(label: "内容", value: record.text)]
            )
        })

        let inventoryTransactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).filter {
            $0.kind != .consumption && !$0.note.hasPrefix("删除健康记录反向恢复库存：")
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

        let semenTransactions = try context.fetch(FetchDescriptor<SemenTransactionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).filter {
            $0.kind != .consumption && !$0.note.hasPrefix("撤销繁殖记录反向恢复冻精：")
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
    @State private var visibleEvents = [FarmEventSnapshot]()
    @State private var listSnapshotRevision = 0
    @State private var eventSourceRevision = 0
    @State private var category: FarmEventCategory?
    @State private var recordScope = FarmEventExportScope.all
    @State private var query = ""
    @State private var pendingEditor: FarmEventEditDestination?
    @State private var pendingDeletion: FarmEventSnapshot?
    @State private var isPresentingExport = false
    @State private var isLoading = true
    @State private var isFiltering = false
    @State private var errorMessage: String?

    private var canDelete: Bool {
        CapabilitySet(role: farm.role).allows(.deleteProtectedFacts)
    }

    private var canExport: Bool {
        CapabilitySet(role: farm.role).allows(.exportFarm)
    }

    private func canEdit(_ event: FarmEventSnapshot) -> Bool {
        guard !isParityConfirmation(event) else { return false }
        guard let capability = event.editCapability else { return false }
        return CapabilitySet(role: farm.role).allows(capability)
    }

    private func canDelete(_ event: FarmEventSnapshot) -> Bool {
        canDelete &&
            !event.isDerived &&
            !event.isRestorableBatchDeparture &&
            !isParityConfirmation(event)
    }

    private func canRestoreBatchDeparture(_ event: FarmEventSnapshot) -> Bool {
        event.isRestorableBatchDeparture &&
            CapabilitySet(role: farm.role).allows(.recordProduction)
    }

    private func isParityConfirmation(_ event: FarmEventSnapshot) -> Bool {
        event.entityType == .reproduction && event.title == ReproductionRecordKind.parityBaseline.displayName
    }

    private var hasActiveSearchOrFilter: Bool {
        !FarmEventSearch.normalized(query).isEmpty || category != nil || recordScope != .all
    }

    var body: some View {
        List {
            if (isLoading || isFiltering) && visibleEvents.isEmpty {
                ProgressView("正在整理事件记录")
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if visibleEvents.isEmpty {
                ContentUnavailableView(
                    hasActiveSearchOrFilter ? "没有匹配的事件" : "暂无事件记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("生产录入完成后会按发生时间倒序显示在这里。")
                )
                .frame(maxWidth: .infinity, minHeight: 360)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(visibleEvents, id: \.rowIdentity) { event in
                    FarmEventHistoryRowLink(
                        event: event,
                        farmName: farm.name,
                        canExport: canExport,
                        canEdit: canEdit(event),
                        canDelete: canDelete(event),
                        canRestoreBatchDeparture: canRestoreBatchDeparture(event),
                        requestEditing: { beginEditing(event) },
                        requestDeletion: { pendingDeletion = event },
                        restoreBatchDeparture: { try restoreBatchDeparture(event) }
                    )
                    .listRowInsets(.init(top: 7, leading: 16, bottom: 7, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canDelete(event) {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                pendingDeletion = event
                            }
                        }
                        if canEdit(event) {
                            Button("编辑", systemImage: "pencil") {
                                beginEditing(event)
                            }
                            .tint(AppTheme.brand)
                        }
                    }
                }
            }
        }
        .id(listSnapshotRevision)
        .navigationTitle("事件记录")
        .searchable(
            text: $query,
            prompt: "搜索耳号、圈舍、项目或备注"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("业务分类") {
                        Button("全部分类", systemImage: category == nil ? "checkmark" : "clock") {
                            category = nil
                            recordScope = .all
                        }
                        ForEach(FarmEventCategory.allCases) { item in
                            Button(LocalizedStringKey(item.displayName), systemImage: category == item ? "checkmark" : item.symbol) {
                                category = item
                                recordScope = .all
                            }
                        }
                    }
                    Section("记录类型") {
                        ForEach(FarmEventExportScope.allCases.dropFirst()) { item in
                            Button(LocalizedStringKey(item.displayName), systemImage: recordScope == item ? "checkmark" : item.symbol) {
                                recordScope = item
                                category = nil
                            }
                        }
                    }
                } label: {
                    Image(systemName: category == nil && recordScope == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("筛选事件")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(events.isEmpty || !canExport)
                .accessibilityLabel("导出事件记录")
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
        .task(id: FarmEventFilterRequest(
            query: FarmEventSearch.normalized(query),
            category: category,
            scope: recordScope,
            sourceRevision: eventSourceRevision
        )) {
            await updateVisibleEvents()
        }
        .refreshable { await reload() }
        .sheet(item: $pendingEditor, onDismiss: {
            Task { await reloadAfterMutation() }
        }) { destination in
            FarmEventEditSheet(account: account, farm: farm, destination: destination)
        }
        .sheet(item: $pendingDeletion, onDismiss: {
            Task { await reloadAfterMutation() }
        }) { event in
            FarmEventDeletionSheet(account: account, farm: farm, event: event)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $isPresentingExport) {
            FarmEventExportSheet(farmName: farm.name, events: events, initialScope: recordScope)
        }
        .recordErrorAlert($errorMessage)
    }

    @MainActor
    private func reloadAfterMutation() async {
        await Task.yield()
        await reload(showsProgress: false, replacesListSnapshot: true)
    }

    @MainActor
    private func reload(
        showsProgress: Bool = true,
        replacesListSnapshot: Bool = false
    ) async {
        if showsProgress { isLoading = true }
        defer { isLoading = false }
        do {
            let updatedEvents = try await FarmEventHistoryActor(container: modelContext.container).load(farmID: farm.id)
            if replacesListSnapshot {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    // Recreate the List instead of coalescing sheet dismissal with a row-level diff.
                    events = updatedEvents
                    listSnapshotRevision &+= 1
                    eventSourceRevision &+= 1
                }
            } else {
                events = updatedEvents
                eventSourceRevision &+= 1
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "读取事件记录失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func updateVisibleEvents() async {
        let request = FarmEventFilterRequest(
            query: FarmEventSearch.normalized(query),
            category: category,
            scope: recordScope,
            sourceRevision: eventSourceRevision
        )
        isFiltering = true
        do {
            if !request.query.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
            }
            let eventSnapshot = events
            let updatedEvents = await Task.detached(priority: .userInitiated) {
                FarmEventSearch.filter(
                    eventSnapshot,
                    query: request.query,
                    category: request.category,
                    scope: request.scope
                )
            }.value
            try Task.checkCancellation()
            visibleEvents = updatedEvents
            isFiltering = false
        } catch is CancellationError {
            return
        } catch {
            isFiltering = false
        }
    }

    @MainActor
    private func beginEditing(_ event: FarmEventSnapshot) {
        let entityID = event.id
        let farmID = farm.id
        do {
            switch event.entityType {
            case .sheep:
                guard let record = try modelContext.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
                })).first else { throw FarmEventEditError.recordUnavailable }
                pendingEditor = .sheep(record)
            case .weight:
                guard let record = try modelContext.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
                    $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
                })).first else { throw FarmEventEditError.recordUnavailable }
                pendingEditor = .weight(record)
            case .transfer:
                guard let record = try modelContext.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
                    $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
                })).first else { throw FarmEventEditError.recordUnavailable }
                pendingEditor = .transfer(record)
            case .removal:
                guard let record = try modelContext.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                    $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
                })).first else { throw FarmEventEditError.recordUnavailable }
                pendingEditor = .removal(record)
            case .health:
                guard let record = try modelContext.fetch(FetchDescriptor<HealthRecord>(predicate: #Predicate {
                    $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
                })).first else { throw FarmEventEditError.recordUnavailable }
                pendingEditor = .health(record)
            case .reproduction:
                guard let record = try modelContext.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                    $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
                })).first else { throw FarmEventEditError.recordUnavailable }
                guard record.kind != .parityBaseline else { throw FarmEventEditError.unsupported }
                pendingEditor = .reproduction(record)
            case .feed where event.title == "TMR 投喂":
                let allocations = try modelContext.fetch(FetchDescriptor<TMRFeedingAllocationRecord>(predicate: #Predicate {
                    $0.feedRecordID == entityID && $0.farmID == farmID && $0.deletedAt == nil
                }))
                guard let allocation = allocations.first else { throw FarmEventEditError.recordUnavailable }
                let runID = allocation.runID
                guard let run = try modelContext.fetch(FetchDescriptor<TMRFeedingRunRecord>(predicate: #Predicate {
                    $0.id == runID && $0.farmID == farmID && $0.deletedAt == nil
                })).first
                else { throw FarmEventEditError.recordUnavailable }
                pendingEditor = .tmrFeedingRun(runID: run.id)
            default:
                throw FarmEventEditError.unsupported
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func restoreBatchDeparture(_ event: FarmEventSnapshot) throws {
        guard event.isRestorableBatchDeparture else {
            throw FarmEventEditError.unsupported
        }
        try FarmCommandService().execute(
            .restoreBatchMembership(
                membershipID: event.id,
                restoredAt: .now,
                reason: "用户从事件记录撤回误移出批次"
            ),
            in: FarmContext(
                accountID: account.effectiveAccountID,
                farmID: farm.id,
                role: farm.role
            ),
            context: modelContext
        )
        Task { await reloadAfterMutation() }
    }
}

private struct FarmEventFilterRequest: Equatable, Sendable {
    let query: String
    let category: FarmEventCategory?
    let scope: FarmEventExportScope
    let sourceRevision: Int
}

private struct FarmEventHistoryRowLink: View {
    let event: FarmEventSnapshot
    let farmName: String
    let canExport: Bool
    let canEdit: Bool
    let canDelete: Bool
    let canRestoreBatchDeparture: Bool
    let requestEditing: () -> Void
    let requestDeletion: () -> Void
    let restoreBatchDeparture: () throws -> Void

    var body: some View {
        NavigationLink {
            FarmEventDetailView(
                event: event,
                farmName: farmName,
                canExport: canExport,
                canEdit: canEdit,
                canRestoreBatchDeparture: canRestoreBatchDeparture,
                requestEditing: requestEditing,
                performBatchDepartureRestore: restoreBatchDeparture
            )
        } label: {
            FarmEventRow(event: event)
                .contentShape(.rect)
        }
        .contextMenu {
            if canEdit {
                Button("编辑事件", systemImage: "pencil", action: requestEditing)
            }
            if canDelete {
                Button("删除事件", systemImage: "trash", role: .destructive, action: requestDeletion)
            }
        }
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
                Text(LocalizedStringKey(event.title)).font(.subheadline.weight(.semibold))
                Text(LocalizedStringKey(event.subject)).font(.subheadline)
                if !event.detail.isEmpty {
                    Text(LocalizedStringKey(event.detail)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
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
    @Environment(\.dismiss) private var dismiss

    let event: FarmEventSnapshot
    let farmName: String
    let canExport: Bool
    let canEdit: Bool
    let canRestoreBatchDeparture: Bool
    let requestEditing: () -> Void
    let performBatchDepartureRestore: () throws -> Void

    @State private var document: FarmEventCSVExportDocument?
    @State private var isExporting = false
    @State private var isConfirmingBatchRestore = false
    @State private var isRestoringBatchDeparture = false
    @State private var message: String?
    @State private var errorMessage: String?

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
            if canRestoreBatchDeparture {
                Section("可恢复操作") {
                    Button("撤回移出批次", systemImage: "arrow.uturn.backward") {
                        isConfirmingBatchRestore = true
                    }
                    .disabled(isRestoringBatchDeparture)
                    Text("恢复后会保留原加入时间；移出事件将从当前事实时间线消失，但移出和撤回的审计操作都会保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("事件详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑", systemImage: "pencil", action: requestEditing)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("导出", systemImage: "square.and.arrow.up", action: prepareExport)
                    .disabled(!canExport)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .commaSeparatedText,
            defaultFilename: FarmEventCSVExport.fileName(
                farmName: farmName,
                scope: FarmEventExportScope.scope(for: event),
                range: .days(from: event.occurredAt, through: event.occurredAt)
            )
        ) { result in
            switch result {
            case .success: message = "该条记录已导出为 CSV。"
            case .failure(let error): message = "导出失败：\(error.localizedDescription)"
            }
        }
        .alert("记录导出", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(message ?? ""))
        }
        .alert("撤回移出批次？", isPresented: $isConfirmingBatchRestore) {
            Button("恢复到原批次") { restoreBatchDeparture() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将恢复这只羊在原生产批次中的成员关系和原加入时间。")
        }
        .recordErrorAlert($errorMessage)
    }

    private func prepareExport() {
        document = FarmEventCSVExportDocument(
            data: FarmEventCSVExport.csvData(events: [event], scope: .all, range: .all)
        )
        isExporting = true
    }

    @MainActor
    private func restoreBatchDeparture() {
        guard !isRestoringBatchDeparture else { return }
        isRestoringBatchDeparture = true
        Task { @MainActor in
            await Task.yield()
            do {
                try performBatchDepartureRestore()
                dismiss()
            } catch {
                isRestoringBatchDeparture = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum FarmEventEditDestination: Identifiable {
    case sheep(SheepRecord)
    case weight(WeightRecord)
    case transfer(TransferRecord)
    case removal(RemovalRecord)
    case health(HealthRecord)
    case reproduction(ReproductionRecord)
    case tmrFeedingRun(runID: UUID)

    var id: FarmEventRowIdentity {
        switch self {
        case .sheep(let record):
            FarmEventRowIdentity(entityType: CloudEntityType.sheep.rawValue, entityID: record.id)
        case .weight(let record):
            FarmEventRowIdentity(entityType: CloudEntityType.weight.rawValue, entityID: record.id)
        case .transfer(let record):
            FarmEventRowIdentity(entityType: CloudEntityType.transfer.rawValue, entityID: record.id)
        case .removal(let record):
            FarmEventRowIdentity(entityType: CloudEntityType.removal.rawValue, entityID: record.id)
        case .health(let record):
            FarmEventRowIdentity(entityType: CloudEntityType.health.rawValue, entityID: record.id)
        case .reproduction(let record):
            FarmEventRowIdentity(entityType: CloudEntityType.reproduction.rawValue, entityID: record.id)
        case .tmrFeedingRun(let runID):
            FarmEventRowIdentity(entityType: CloudEntityType.tmrFeedingRun.rawValue, entityID: runID)
        }
    }
}

private enum FarmEventEditError: LocalizedError {
    case recordUnavailable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .recordUnavailable:
            "这条事件已被修正、删除或同步更新，请刷新后重试。"
        case .unsupported:
            "这类事件是账本或派生事实，不能直接改写；请从对应业务入口执行修正。"
        }
    }
}

private struct FarmEventEditSheet: View {
    let account: AccountProfile
    let farm: FarmRecord
    let destination: FarmEventEditDestination

    var body: some View {
        NavigationStack {
            switch destination {
            case .sheep(let record):
                EditSheepProfileView(account: account, farm: farm, sheep: record)
            case .weight(let record):
                CorrectWeightView(account: account, farm: farm, record: record)
            case .transfer(let record):
                CorrectTransferView(account: account, farm: farm, record: record)
            case .removal(let record):
                CorrectRemovalView(account: account, farm: farm, record: record)
            case .health(let record):
                HealthCorrectionView(account: account, farm: farm, record: record)
            case .reproduction(let record):
                if record.kind == .lambing {
                    LambingCorrectionView(account: account, farm: farm, record: record)
                } else {
                    ReproductionCorrectionView(account: account, farm: farm, record: record)
                }
            case .tmrFeedingRun(let runID):
                TMRFeedingCorrectionView(account: account, farm: farm, runID: runID)
            }
        }
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
                    if event.entityType == .feed && event.title == "TMR 投喂" {
                        Text("删除会撤销所属的整次出锅投喂；若该次包含多个圈舍，将一起撤销并恢复 TMR 批次余额，原料库存不会变化。审计记录不会被抹除。")
                    } else {
                        Text("删除会撤销底层权威事实并同步重算关联历史；健康、繁殖事件还会反冲库存并重建提醒。审计记录不会被抹除。")
                    }
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
            .interactiveDismissDisabled(isDeleting)
            .recordErrorAlert($errorMessage)
        }
    }

    @MainActor
    private func delete() {
        guard !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            // Let SwiftUI render the progress state before entering the
            // authoritative synchronous write pipeline.
            await Task.yield()
            do {
                let command = try FarmEventDeletionCommandResolver.command(
                    for: event,
                    reason: reason,
                    farmID: farm.id,
                    context: modelContext
                )
                try FarmCommandService().execute(
                    command,
                    in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role),
                    context: modelContext
                )
                dismiss()
            } catch {
                isDeleting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

enum FarmEventDeletionCommandResolver {
    @MainActor
    static func command(
        for event: FarmEventSnapshot,
        reason: String,
        farmID: UUID,
        context: ModelContext
    ) throws -> FarmCommand {
        let normalizedReason = "事件记录删除：" + reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if event.entityType == .feed {
            let feedRecordID = event.id
            let allocation = try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.feedRecordID == feedRecordID
            })).first
            if let allocation {
                let runID = allocation.runID
                guard allocation.deletedAt == nil,
                      let run = try context.fetch(FetchDescriptor<TMRFeedingRunRecord>(predicate: #Predicate {
                          $0.id == runID && $0.farmID == farmID && $0.deletedAt == nil
                      })).first else {
                    throw TMRCommandApplyError.runNotFound
                }
                let batchID = run.batchID
                guard let batch = try context.fetch(FetchDescriptor<TMRBatchRecord>(predicate: #Predicate {
                    $0.id == batchID && $0.farmID == farmID && $0.deletedAt == nil
                })).first else {
                    throw TMRCommandApplyError.runNotFound
                }
                return .tmr(.reverseFeedingRun(TMRFeedingReversalDraft(
                    runID: run.id,
                    batchID: batch.id,
                    expectedBatchRevision: batch.revision,
                    reason: normalizedReason
                )))
            }
        }
        guard event.entityType == .reproduction else {
            return .tombstoneEntity(
                entityType: event.entityType,
                entityID: event.id,
                reason: normalizedReason
            )
        }

        let entityID = event.id
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
        })).first
        if reproduction?.kind == .parityBaseline {
            throw FarmCommandError.parityBaselineManagedInProfile
        }
        guard reproduction?.kind == .lambing else {
            return .tombstoneEntity(
                entityType: event.entityType,
                entityID: event.id,
                reason: normalizedReason
            )
        }

        return .care(.revokeLambing(recordID: event.id, reason: normalizedReason))
    }
}
