import Foundation
import SwiftData

struct CareApplyResult: Sendable {
    let entityType: CloudEntityType
    let entityID: UUID
    let baseRevision: Int
    let resultingRevision: Int
}

enum FarmCareCommandHandler {
    static func isApplied(_ command: CareCommand, farmID: UUID, context: ModelContext) throws -> Bool {
        switch command {
        case .upsertHealthCatalog(let id, let kind, let name, let category, let unit, let dose, let route, let interval, let note, let active):
            return try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).contains { $0.id == id && $0.farmID == farmID && $0.kindRawValue == kind && $0.name == name.trimmed && $0.category == category.trimmed && $0.unit == unit.trimmed && $0.defaultDoseText == dose?.trimmed.nilIfEmpty && $0.defaultRoute == route.trimmed && $0.reminderIntervalDays == interval && $0.note == note.trimmed && $0.isActive == active }
        case .recordHealth(let draft), .correctHealth(_, let draft, _):
            return try context.fetch(FetchDescriptor<HealthRecord>()).contains { $0.id == draft.id && $0.farmID == farmID }
        case .receiveInventory(let id, _, _, _, _, _, _, _, _, _, _):
            return try context.fetch(FetchDescriptor<InventoryLotRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .adjustInventory(let id, _, _, _, _):
            return try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .setInventoryLotActive(let lotID, let active):
            return try context.fetch(FetchDescriptor<InventoryLotRecord>()).contains { $0.id == lotID && $0.farmID == farmID && $0.isActive == active }
        case .adjustSemen(let id, _, _, _, _):
            return try context.fetch(FetchDescriptor<SemenTransactionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .recordReproductionBatch(let draft), .correctReproduction(_, let draft, _):
            return try context.fetch(FetchDescriptor<CareBatchRecord>()).contains { $0.id == draft.id && $0.farmID == farmID }
        case .recordLambing(let draft):
            return try context.fetch(FetchDescriptor<ReproductionRecord>()).contains { $0.id == draft.id && $0.farmID == farmID }
        case .updateRules(let id, let checkDays, let gestationDays):
            return try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).contains { $0.id == id && $0.farmID == farmID && $0.pregnancyCheckDays == checkDays && $0.gestationDays == gestationDays }
        case .setReminderStatus(let reminderID, let status):
            return try context.fetch(FetchDescriptor<CareReminderRecord>()).contains { $0.id == reminderID && $0.farmID == farmID && $0.statusRawValue == status.rawValue }
        }
    }

    static func validate(_ command: CareCommand, farmID: UUID, context: ModelContext) throws {
        switch command {
        case .upsertHealthCatalog(_, let kindRawValue, let name, _, let unit, let dose, _, let interval, _, _):
            guard HealthRecordKind(rawValue: kindRawValue) != nil else { throw FarmCommandError.missingRequiredValue("健康目录类型") }
            try require(name, "目录名称")
            try require(unit, "计量单位")
            if let dose, !dose.isEmpty { _ = try positive(dose, "默认剂量") }
            if let interval { guard (1...3650).contains(interval) else { throw FarmCommandError.invalidNumber("复免间隔") } }

        case .recordHealth(let draft):
            try validateHealth(draft, farmID: farmID, inventoryCreditSourceID: nil, context: context)

        case .correctHealth(let originalID, let replacement, let reason):
            guard let original = try context.fetch(FetchDescriptor<HealthRecord>()).first(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try require(reason, "修正原因")
            try validateHealth(replacement, farmID: farmID, inventoryCreditSourceID: original.id, context: context)

        case .receiveInventory(_, let catalogName, let catalogItemID, let kindRawValue, _, _, let unit, _, let quantityText, _, _):
            try require(catalogName, "库存名称")
            try require(unit, "库存单位")
            guard HealthRecordKind(rawValue: kindRawValue) != nil else { throw FarmCommandError.missingRequiredValue("库存类型") }
            _ = try positive(quantityText, "入库数量")
            if let catalogItemID {
                guard try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).contains(where: { $0.id == catalogItemID && $0.farmID == farmID }) else { throw FarmCommandError.missingRequiredValue("健康目录") }
            }

        case .adjustInventory(_, let lotID, let deltaText, _, _):
            let lot = try inventoryLot(lotID, farmID: farmID, context: context, requiresActive: false)
            guard let delta = Decimal.stable(deltaText), delta != 0 else { throw FarmCommandError.invalidNumber("调整数量") }
            guard try inventoryBalance(lot, context: context) + delta >= 0 else { throw FarmCommandError.insufficientInventory }

        case .setInventoryLotActive(let lotID, _):
            _ = try inventoryLot(lotID, farmID: farmID, context: context, requiresActive: false)

        case .adjustSemen(_, let semenID, let deltaText, _, _):
            let semen = try semen(semenID, farmID: farmID, context: context)
            guard let delta = Decimal.stable(deltaText), delta != 0 else { throw FarmCommandError.invalidNumber("调整数量") }
            guard try semenBalance(semen, context: context) + delta >= 0 else { throw FarmCommandError.insufficientInventory }

        case .recordReproductionBatch(let draft):
            try validateReproductionBatch(draft, farmID: farmID, semenCreditSourceID: nil, context: context)

        case .recordLambing(let draft):
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            guard let ewe = sheep.first(where: { $0.id == draft.eweID && $0.farmID == farmID && $0.deletedAt == nil }), ewe.sex == .ewe else { throw FarmCommandError.reproductionSubjectMustBeEwe }
            guard draft.parity > 0, draft.birthDeadCount >= 0, draft.birthDeadCount == draft.offspring.count(where: \.isStillborn), !draft.offspring.isEmpty, draft.offspring.allSatisfy({ !$0.isStillborn || !$0.createSheepRecord }) else { throw FarmCommandError.invalidReproductionRecord }
            if let sireID = draft.sireID, !sheep.contains(where: { $0.id == sireID && $0.farmID == farmID && $0.deletedAt == nil && $0.sex == .ram }) { throw FarmCommandError.reproductionSireMustBeRam }
            let existingTags = Set(sheep.filter { $0.farmID == farmID }.map { EarTag.normalized($0.earTag) })
            let newTags = draft.offspring.filter(\.createSheepRecord).map { EarTag.normalized($0.earTag) }
            guard newTags.allSatisfy({ !$0.isEmpty }), Set(newTags).count == newTags.count, existingTags.isDisjoint(with: newTags) else { throw FarmCommandError.duplicateEarTag }
            for lamb in draft.offspring { _ = try positive(lamb.birthWeightText, "初生重") }

        case .correctReproduction(let originalID, let replacement, let reason):
            guard try context.fetch(FetchDescriptor<ReproductionRecord>()).contains(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try require(reason, "修正原因")
            try validateReproductionBatch(replacement, farmID: farmID, semenCreditSourceID: originalID, context: context)

        case .updateRules(_, let checkDays, let gestationDays):
            guard (1...365).contains(checkDays), (100...220).contains(gestationDays) else { throw FarmCommandError.invalidNumber("提醒间隔") }

        case .setReminderStatus(let reminderID, _):
            guard try context.fetch(FetchDescriptor<CareReminderRecord>()).contains(where: { $0.id == reminderID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
        }
    }

    static func apply(_ command: CareCommand, farmID: UUID, accountID: UUID, context: ModelContext, modifiedAt: Date = .now) throws -> CareApplyResult {
        switch command {
        case .upsertHealthCatalog(let id, let kindRawValue, let name, let category, let unit, let dose, let route, let interval, let note, let isActive):
            let records = try context.fetch(FetchDescriptor<HealthCatalogItemRecord>())
            if let record = records.first(where: { $0.id == id && $0.farmID == farmID }) {
                record.kindRawValue = kindRawValue; record.name = name.trimmed; record.category = category.trimmed
                record.unit = unit.trimmed; record.defaultDoseText = dose?.trimmed.nilIfEmpty; record.defaultRoute = route.trimmed
                record.reminderIntervalDays = interval; record.note = note.trimmed; record.isActive = isActive
                return CareApplyResult(entityType: .healthCatalogItem, entityID: id, baseRevision: 1, resultingRevision: 2)
            }
            context.insert(HealthCatalogItemRecord(id: id, farmID: farmID, legacySourceKey: "", legacyCatalogID: "", kindRawValue: kindRawValue, name: name.trimmed, category: category.trimmed, unit: unit.trimmed, defaultDoseText: dose?.trimmed.nilIfEmpty, defaultRoute: route.trimmed, reminderIntervalDays: interval, note: note.trimmed, isActive: isActive))
            return CareApplyResult(entityType: .healthCatalogItem, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .recordHealth(let draft):
            return try applyHealth(draft, farmID: farmID, context: context)

        case .correctHealth(let originalID, let replacement, let reason):
            guard let original = try context.fetch(FetchDescriptor<HealthRecord>()).first(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try DomainEntityDeletionService.setDeletedAt(modifiedAt, type: .health, id: original.id, farmID: farmID, context: context)
            context.insert(TombstoneRecord(farmID: farmID, entityType: CloudEntityType.health.rawValue, entityID: originalID, deletedByAccountID: accountID, reason: "修正：\(reason.trimmed)"))
            let result = try applyHealth(replacement, farmID: farmID, context: context)
            return CareApplyResult(entityType: result.entityType, entityID: result.entityID, baseRevision: 1, resultingRevision: 2)

        case .receiveInventory(let id, let catalogName, let catalogItemID, let kindRawValue, let batchNumber, let supplier, let unit, let expiresAt, let quantityText, let occurredAt, let note):
            let quantity = Decimal.stable(quantityText) ?? 0
            let lot = InventoryLotRecord(id: id, farmID: farmID, catalogName: catalogName.trimmed, catalogItemID: catalogItemID, kind: HealthRecordKind(rawValue: kindRawValue) ?? .treatment, expiresAt: expiresAt, startingQuantityText: quantity.stableText, batchNumber: batchNumber.trimmed, supplier: supplier.trimmed, receivedAt: occurredAt, unit: unit.trimmed)
            context.insert(lot)
            context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: id, name: "inventory-receipt"), farmID: farmID, inventoryLotID: id, kind: .receipt, quantityText: quantity.stableText, occurredAt: occurredAt, sourceRecordID: id, note: note.trimmed))
            refreshInventoryExpiryReminder(for: lot, context: context)
            return .init(entityType: .inventoryLot, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .adjustInventory(let id, let lotID, let deltaText, let occurredAt, let note):
            if try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).contains(where: { $0.id == id && $0.farmID == farmID }) { return .init(entityType: .inventoryTransaction, entityID: id, baseRevision: 0, resultingRevision: 1) }
            context.insert(InventoryTransactionRecord(id: id, farmID: farmID, inventoryLotID: lotID, kind: .adjustment, quantityText: Decimal.stable(deltaText)!.stableText, occurredAt: occurredAt, note: note.trimmed))
            return .init(entityType: .inventoryTransaction, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .setInventoryLotActive(let lotID, let isActive):
            let lot = try inventoryLot(lotID, farmID: farmID, context: context, requiresActive: false)
            lot.isActive = isActive
            return .init(entityType: .inventoryLot, entityID: lotID, baseRevision: 1, resultingRevision: 2)

        case .adjustSemen(let id, let semenID, let deltaText, let occurredAt, let note):
            if try context.fetch(FetchDescriptor<SemenTransactionRecord>()).contains(where: { $0.id == id && $0.farmID == farmID }) { return .init(entityType: .semenTransaction, entityID: id, baseRevision: 0, resultingRevision: 1) }
            context.insert(SemenTransactionRecord(id: id, farmID: farmID, semenID: semenID, kind: .adjustment, quantityText: Decimal.stable(deltaText)!.stableText, occurredAt: occurredAt, note: note.trimmed))
            return .init(entityType: .semenTransaction, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .recordReproductionBatch(let draft):
            if try context.fetch(FetchDescriptor<CareBatchRecord>()).contains(where: { $0.id == draft.id && $0.farmID == farmID }) { return .init(entityType: .careBatch, entityID: draft.id, baseRevision: 0, resultingRevision: 1) }
            let batchKind: CareBatchKind
            switch draft.kind { case .breeding: batchKind = .breeding; case .pregnancyCheck: batchKind = .pregnancyCheck; case .abortion: batchKind = .abortion; case .lambing: throw FarmCommandError.invalidReproductionRecord }
            context.insert(CareBatchRecord(id: draft.id, farmID: farmID, kind: batchKind, occurredAt: draft.occurredAt, note: draft.note.trimmed))
            let semenRecord = try draft.semenID.map { try semen($0, farmID: farmID, context: context) }
            let semenPerEwe = draft.semenID == nil ? nil : (Decimal.stable(draft.semenUnitsPerEweText ?? "1") ?? 1)
            for subject in draft.subjects {
                let recordID = StableCloudUUID.derived(namespace: draft.id, name: subject.id.uuidString.lowercased())
                context.insert(ReproductionRecord(id: recordID, farmID: farmID, eweID: subject.eweID, kind: draft.kind, occurredAt: draft.occurredAt, sireID: draft.sireID, semenID: draft.semenID, batchID: draft.id, semenNameSnapshot: semenRecord?.code, result: subject.result.trimmed, note: draft.note.trimmed))
                if let reminderAt = draft.reminderAt, draft.kind != .abortion {
                    let reminderKind: CareReminderKind = draft.kind == .breeding ? .pregnancyCheck : .expectedLambing
                    insertReminder(farmID: farmID, kind: reminderKind, sourceType: CloudEntityType.reproduction.rawValue, sourceID: recordID, sheepID: subject.eweID, dueAt: reminderAt, title: "\(subject.result.isEmpty ? "母羊" : subject.result) · \(reminderKind.displayName)", context: context)
                }
                if let semenID = draft.semenID, let semenPerEwe {
                    context.insert(SemenTransactionRecord(id: StableCloudUUID.derived(namespace: recordID, name: "semen-consumption"), farmID: farmID, semenID: semenID, kind: .consumption, quantityText: semenPerEwe.stableText, occurredAt: draft.occurredAt, sourceRecordID: recordID, note: "配种批次 \(draft.id.uuidString.lowercased())"))
                }
                if draft.kind == .abortion {
                    deleteExpectedLambingReminders(eweID: subject.eweID, farmID: farmID, at: modifiedAt, context: context)
                }
            }
            return .init(entityType: .careBatch, entityID: draft.id, baseRevision: 0, resultingRevision: 1)

        case .recordLambing(let draft):
            if try context.fetch(FetchDescriptor<ReproductionRecord>()).contains(where: { $0.id == draft.id && $0.farmID == farmID }) { return .init(entityType: .reproduction, entityID: draft.id, baseRevision: 0, resultingRevision: 1) }
            let semenRecord = try draft.semenID.map { try semen($0, farmID: farmID, context: context) }
            let reproduction = ReproductionRecord(id: draft.id, farmID: farmID, eweID: draft.eweID, kind: .lambing, occurredAt: draft.occurredAt, sireID: draft.sireID, semenID: draft.semenID, semenNameSnapshot: semenRecord?.code, lambCount: draft.offspring.count, parity: draft.parity, birthDeadCount: draft.birthDeadCount, note: draft.note.trimmed)
            context.insert(reproduction)
            let ewe = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.id == draft.eweID && $0.farmID == farmID })
            for lamb in draft.offspring {
                if lamb.createSheepRecord {
                    context.insert(SheepRecord(id: lamb.sheepID, farmID: farmID, earTag: lamb.earTag.trimmed, breed: ewe?.breed ?? "未知", sex: lamb.sex, penID: draft.penID, enteredAt: draft.occurredAt, birthAt: draft.occurredAt, damID: draft.eweID, sireID: draft.sireID, note: "由产羔记录自动建档"))
                    if let weight = Decimal.stable(lamb.birthWeightText) {
                        context.insert(WeightRecord(id: StableCloudUUID.derived(namespace: lamb.sheepID, name: "birth-weight"), farmID: farmID, sheepID: lamb.sheepID, kilogramsText: weight.stableText, occurredAt: draft.occurredAt, note: "初生重"))
                    }
                }
                context.insert(LambingOffspringRecord(id: lamb.id, farmID: farmID, lambingRecordID: draft.id, sheepID: lamb.createSheepRecord ? lamb.sheepID : nil, legacyEarTag: lamb.earTag.trimmed, sexRawValue: lamb.sex.rawValue, birthWeightText: Decimal.stable(lamb.birthWeightText)!.stableText, isStillborn: lamb.isStillborn))
            }
            deleteExpectedLambingReminders(eweID: draft.eweID, farmID: farmID, at: modifiedAt, context: context)
            return .init(entityType: .reproduction, entityID: draft.id, baseRevision: 0, resultingRevision: 1)

        case .correctReproduction(let originalID, let replacement, let reason):
            guard let original = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try DomainEntityDeletionService.setDeletedAt(modifiedAt, type: .reproduction, id: original.id, farmID: farmID, context: context)
            context.insert(TombstoneRecord(farmID: farmID, entityType: CloudEntityType.reproduction.rawValue, entityID: originalID, deletedByAccountID: accountID, reason: "修正：\(reason.trimmed)"))
            let result = try apply(.recordReproductionBatch(replacement), farmID: farmID, accountID: accountID, context: context, modifiedAt: modifiedAt)
            return .init(entityType: result.entityType, entityID: result.entityID, baseRevision: 1, resultingRevision: 2)

        case .updateRules(let id, let pregnancyCheckDays, let gestationDays):
            let rules = try context.fetch(FetchDescriptor<FarmCareRuleRecord>())
            if let record = rules.first(where: { $0.farmID == farmID }) {
                let base = record.revision
                record.pregnancyCheckDays = pregnancyCheckDays; record.gestationDays = gestationDays; record.updatedAt = modifiedAt; record.revision += 1
                return .init(entityType: .careRule, entityID: record.id, baseRevision: base, resultingRevision: record.revision)
            }
            context.insert(FarmCareRuleRecord(id: id, farmID: farmID, pregnancyCheckDays: pregnancyCheckDays, gestationDays: gestationDays))
            return .init(entityType: .careRule, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .setReminderStatus(let reminderID, let status):
            guard let reminder = try context.fetch(FetchDescriptor<CareReminderRecord>()).first(where: { $0.id == reminderID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            let base = reminder.revision
            reminder.statusRawValue = status.rawValue; reminder.completedAt = status == .completed ? modifiedAt : nil; reminder.revision += 1
            return .init(entityType: .careReminder, entityID: reminderID, baseRevision: base, resultingRevision: reminder.revision)
        }
    }

    static func refreshInventoryExpiryReminder(for lot: InventoryLotRecord, context: ModelContext) {
        guard let dueAt = lot.expiresAt else { return }
        insertReminder(farmID: lot.farmID, kind: .inventoryExpiry, sourceType: CloudEntityType.inventoryLot.rawValue, sourceID: lot.id, inventoryLotID: lot.id, dueAt: dueAt, title: "\(lot.catalogName)即将到期", context: context)
    }

    static func inventoryBalance(_ lot: InventoryLotRecord, context: ModelContext) throws -> Decimal {
        try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).filter { $0.farmID == lot.farmID && $0.inventoryLotID == lot.id && $0.deletedAt == nil }.reduce(0) { partial, transaction in
            switch transaction.kind { case .receipt, .adjustment: partial + transaction.quantity; case .consumption: partial - transaction.quantity }
        }
    }

    static func semenBalance(_ semen: SemenRecord, context: ModelContext) throws -> Decimal {
        let initial = Decimal.stable(semen.quantityText) ?? 0
        return try context.fetch(FetchDescriptor<SemenTransactionRecord>()).filter { $0.farmID == semen.farmID && $0.semenID == semen.id && $0.deletedAt == nil }.reduce(initial) { partial, transaction in
            switch transaction.kind { case .receipt, .adjustment: partial + transaction.quantity; case .consumption: partial - transaction.quantity }
        }
    }

    private static func applyHealth(_ draft: CareHealthDraft, farmID: UUID, context: ModelContext) throws -> CareApplyResult {
        if try context.fetch(FetchDescriptor<HealthRecord>()).contains(where: { $0.id == draft.id && $0.farmID == farmID }) { return .init(entityType: .health, entityID: draft.id, baseRevision: 0, resultingRevision: 1) }
        let subjects = try healthSubjects(draft, farmID: farmID, context: context)
        context.insert(CareBatchRecord(id: draft.batchID, farmID: farmID, kind: .health, occurredAt: draft.occurredAt, note: draft.note.trimmed))
        let record = HealthRecord(id: draft.id, farmID: farmID, sheepID: subjects.count == 1 ? subjects[0].id : nil, penID: draft.penID, kind: draft.kind, itemNameSnapshot: draft.itemName.trimmed, occurredAt: draft.occurredAt, note: draft.note.trimmed, inventoryLotID: draft.inventoryLotID, catalogItemID: draft.catalogItemID, batchID: draft.batchID, quantityText: draft.dosePerSubjectText?.trimmed.nilIfEmpty, unit: draft.unit.trimmed, route: draft.route.trimmed)
        context.insert(record)
        for sheep in subjects { context.insert(HealthSubjectLink(id: StableCloudUUID.derived(namespace: draft.id, name: sheep.id.uuidString.lowercased()), farmID: farmID, healthRecordID: draft.id, sheepID: sheep.id)) }
        if let lotID = draft.inventoryLotID, let dose = Decimal.stable(draft.dosePerSubjectText ?? "") {
            context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: draft.id, name: "inventory-consumption"), farmID: farmID, inventoryLotID: lotID, kind: .consumption, quantityText: (dose * Decimal(subjects.count)).stableText, occurredAt: draft.occurredAt, sourceRecordID: draft.id, note: draft.itemName.trimmed))
        }
        if let dueAt = draft.reminderAt {
            for sheep in subjects { insertReminder(farmID: farmID, kind: .booster, sourceType: CloudEntityType.health.rawValue, sourceID: draft.id, sheepID: sheep.id, dueAt: dueAt, title: "\(sheep.earTag) · \(draft.itemName)复免", context: context) }
        }
        return .init(entityType: .health, entityID: draft.id, baseRevision: 0, resultingRevision: 1)
    }

    private static func healthSubjects(_ draft: CareHealthDraft, farmID: UUID, context: ModelContext) throws -> [SheepRecord] {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        if !draft.subjectIDs.isEmpty {
            let ids = Set(draft.subjectIDs)
            guard ids.count == draft.subjectIDs.count else { throw FarmCommandError.invalidReproductionRecord }
            let selected = sheep.filter { ids.contains($0.id) }
            guard selected.count == ids.count else { throw FarmCommandError.sheepNotFound }
            return selected.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
        }
        guard let penID = draft.penID else { throw FarmCommandError.missingRequiredValue("健康记录对象") }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let selected = sheep.filter { record in
            record.enteredAt <= draft.occurredAt && (record.removedAt == nil || record.removedAt! > draft.occurredAt) && FarmHistoryTimeline.pen(for: record, at: draft.occurredAt, transfers: transfers) == penID
        }
        guard !selected.isEmpty else { throw FarmCommandError.missingRequiredValue("圈舍历史羊只") }
        return selected.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
    }

    private static func inventoryLot(_ id: UUID, farmID: UUID, context: ModelContext, requiresActive: Bool = true) throws -> InventoryLotRecord {
        guard let lot = try context.fetch(FetchDescriptor<InventoryLotRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil && (!requiresActive || $0.isActive) }) else { throw FarmCommandError.inventoryLotNotFound }
        return lot
    }

    private static func semen(_ id: UUID, farmID: UUID, context: ModelContext) throws -> SemenRecord {
        guard let record = try context.fetch(FetchDescriptor<SemenRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.missingRequiredValue("冻精批次") }
        return record
    }

    private static func validateHealth(_ draft: CareHealthDraft, farmID: UUID, inventoryCreditSourceID: UUID?, context: ModelContext) throws {
        let subjects = try healthSubjects(draft, farmID: farmID, context: context)
        try require(draft.itemName, "药品或疫苗名称")
        guard let lotID = draft.inventoryLotID else { return }
        let dose = try positive(draft.dosePerSubjectText ?? "", "每只剂量")
        let lot = try inventoryLot(lotID, farmID: farmID, context: context)
        var available = try inventoryBalance(lot, context: context)
        if let sourceID = inventoryCreditSourceID {
            let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>())
            available += transactions
                .filter { $0.farmID == farmID && $0.inventoryLotID == lotID && $0.sourceRecordID == sourceID && $0.kind == .consumption && $0.deletedAt == nil }
                .reduce(0) { $0 + $1.quantity }
        }
        guard available >= dose * Decimal(subjects.count) else { throw FarmCommandError.insufficientInventory }
    }

    private static func validateReproductionBatch(_ draft: CareReproductionBatchDraft, farmID: UUID, semenCreditSourceID: UUID?, context: ModelContext) throws {
        guard [.breeding, .pregnancyCheck, .abortion].contains(draft.kind), !draft.subjects.isEmpty else { throw FarmCommandError.invalidReproductionRecord }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        let eweIDs = Set(draft.subjects.map(\.eweID))
        guard eweIDs.count == draft.subjects.count,
              draft.subjects.allSatisfy({ subject in sheep.contains { $0.id == subject.eweID && $0.farmID == farmID && $0.deletedAt == nil && $0.sex == .ewe } }) else { throw FarmCommandError.reproductionSubjectMustBeEwe }
        if draft.kind != .breeding, draft.sireID != nil || draft.semenID != nil { throw FarmCommandError.pregnancyCheckCannotSetPaternity }
        if let sireID = draft.sireID, !sheep.contains(where: { $0.id == sireID && $0.farmID == farmID && $0.deletedAt == nil && $0.sex == .ram }) { throw FarmCommandError.reproductionSireMustBeRam }
        if draft.kind == .breeding, draft.sireID == nil, draft.semenID == nil { throw FarmCommandError.invalidReproductionRecord }
        if let semenID = draft.semenID {
            let record = try semen(semenID, farmID: farmID, context: context)
            let perEwe = try positive(draft.semenUnitsPerEweText ?? "1", "每只冻精用量")
            var available = try semenBalance(record, context: context)
            if let sourceID = semenCreditSourceID {
                available += try context.fetch(FetchDescriptor<SemenTransactionRecord>())
                    .filter { $0.farmID == farmID && $0.semenID == semenID && $0.sourceRecordID == sourceID && $0.kind == .consumption && $0.deletedAt == nil }
                    .reduce(0) { $0 + $1.quantity }
            }
            guard available >= perEwe * Decimal(draft.subjects.count) else { throw FarmCommandError.insufficientInventory }
        }
    }

    private static func insertReminder(farmID: UUID, kind: CareReminderKind, sourceType: String, sourceID: UUID, sheepID: UUID? = nil, inventoryLotID: UUID? = nil, dueAt: Date, title: String, context: ModelContext) {
        let discriminator = [kind.rawValue, sheepID?.uuidString.lowercased() ?? "", inventoryLotID?.uuidString.lowercased() ?? ""].joined(separator: ":")
        let id = StableCloudUUID.derived(namespace: sourceID, name: discriminator)
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>())) ?? []
        if let existing = reminders.first(where: { $0.id == id && $0.farmID == farmID }) {
            existing.dueAt = dueAt; existing.title = title; existing.statusRawValue = CareReminderStatus.pending.rawValue; existing.deletedAt = nil; existing.revision += 1
        } else {
            context.insert(CareReminderRecord(id: id, farmID: farmID, kind: kind, sourceEntityType: sourceType, sourceEntityID: sourceID, sheepID: sheepID, inventoryLotID: inventoryLotID, dueAt: dueAt, title: title))
        }
    }

    private static func deleteReminders(sourceID: UUID, farmID: UUID, at: Date, context: ModelContext) {
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>())) ?? []
        for reminder in reminders where reminder.farmID == farmID && reminder.sourceEntityID == sourceID && reminder.deletedAt == nil { reminder.deletedAt = at; reminder.revision += 1 }
    }

    private static func deleteExpectedLambingReminders(eweID: UUID, farmID: UUID, at: Date, context: ModelContext) {
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>())) ?? []
        for reminder in reminders where reminder.farmID == farmID && reminder.sheepID == eweID && reminder.kind == .expectedLambing && reminder.deletedAt == nil { reminder.statusRawValue = CareReminderStatus.completed.rawValue; reminder.completedAt = at; reminder.revision += 1 }
    }

    private static func require(_ value: String, _ label: String) throws {
        guard !value.trimmed.isEmpty else { throw FarmCommandError.missingRequiredValue(label) }
    }

    private static func positive(_ value: String, _ label: String) throws -> Decimal {
        guard let number = Decimal.stable(value.trimmed), number > 0 else { throw FarmCommandError.invalidNumber(label) }
        return number
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
