import Foundation
import SwiftData

struct FarmCareBackupPayload: Codable, Sendable, Equatable {
    struct Catalog: Codable, Sendable, Equatable { let id: UUID; let legacySourceKey: String; let legacyCatalogID: String; let kindRawValue: String; let name: String; let category: String; let unit: String; let defaultDoseText: String?; let defaultRoute: String; let reminderIntervalDays: Int?; let note: String; let isActive: Bool; let createdAt: Date }
    struct InventoryLot: Codable, Sendable, Equatable { let id: UUID; let catalogName: String; let catalogItemID: UUID?; let legacySourceKey: String?; let batchNumber: String; let supplier: String; let receivedAt: Date?; let unit: String; let kindRawValue: String; let expiresAt: Date?; let startingQuantityText: String; let createdAt: Date; let isActive: Bool; let deletedAt: Date? }
    struct InventoryTransaction: Codable, Sendable, Equatable { let id: UUID; let inventoryLotID: UUID; let kindRawValue: String; let quantityText: String; let occurredAt: Date; let sourceRecordID: UUID?; let note: String; let createdAt: Date; let deletedAt: Date? }
    struct Health: Codable, Sendable, Equatable { let id: UUID; let sheepID: UUID?; let penID: UUID?; let kindRawValue: String; let itemNameSnapshot: String; let occurredAt: Date; let note: String; let inventoryLotID: UUID?; let catalogItemID: UUID?; let batchID: UUID?; let quantityText: String?; let unit: String; let route: String; let legacySourceKey: String?; let createdAt: Date; let deletedAt: Date? }
    struct HealthSubject: Codable, Sendable, Equatable { let id: UUID; let healthRecordID: UUID; let sheepID: UUID; let createdAt: Date }
    struct Semen: Codable, Sendable, Equatable { let id: UUID; let code: String; let breed: String; let source: String; let batchNumber: String; let quantityText: String; let legacySourceKey: String?; let createdAt: Date; let updatedAt: Date; let deletedAt: Date? }
    struct SemenTransaction: Codable, Sendable, Equatable { let id: UUID; let semenID: UUID; let kindRawValue: String; let quantityText: String; let occurredAt: Date; let sourceRecordID: UUID?; let note: String; let createdAt: Date; let deletedAt: Date? }
    struct Reproduction: Codable, Sendable, Equatable { let id: UUID; let eweID: UUID; let kindRawValue: String; let occurredAt: Date; let sireID: UUID?; let semenID: UUID?; let batchID: UUID?; let semenNameSnapshot: String?; let result: String; let lambCount: Int; let parity: Int?; let birthDeadCount: Int?; let note: String; let legacySourceKey: String?; let createdAt: Date; let deletedAt: Date? }
    struct Offspring: Codable, Sendable, Equatable { let id: UUID; let lambingRecordID: UUID; let sheepID: UUID?; let legacyEarTag: String; let sexRawValue: String; let birthWeightText: String; let isStillborn: Bool; let createdAt: Date }
    struct Batch: Codable, Sendable, Equatable { let id: UUID; let kindRawValue: String; let occurredAt: Date; let note: String; let createdAt: Date; let deletedAt: Date? }
    struct Rule: Codable, Sendable, Equatable { let id: UUID; let pregnancyCheckDays: Int; let gestationDays: Int; let createdAt: Date; let updatedAt: Date; let revision: Int }
    struct Reminder: Codable, Sendable, Equatable { let id: UUID; let kindRawValue: String; let sourceEntityType: String; let sourceEntityID: UUID; let sheepID: UUID?; let inventoryLotID: UUID?; let dueAt: Date; let title: String; let statusRawValue: String; let createdAt: Date; let completedAt: Date?; let deletedAt: Date?; let revision: Int }

    let catalogs: [Catalog]
    let inventoryLots: [InventoryLot]
    let inventoryTransactions: [InventoryTransaction]
    let health: [Health]
    let healthSubjects: [HealthSubject]
    let semen: [Semen]
    let semenTransactions: [SemenTransaction]
    let reproduction: [Reproduction]
    let offspring: [Offspring]
    let batches: [Batch]
    let rules: [Rule]
    let reminders: [Reminder]

    var entityCount: Int {
        catalogs.count + inventoryLots.count + inventoryTransactions.count + health.count + healthSubjects.count + semen.count + semenTransactions.count + reproduction.count + offspring.count + batches.count + rules.count + reminders.count
    }

    @MainActor
    static func capture(farmID: UUID, context: ModelContext) throws -> Self {
        .init(
            catalogs: try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, legacySourceKey: $0.legacySourceKey, legacyCatalogID: $0.legacyCatalogID, kindRawValue: $0.kindRawValue, name: $0.name, category: $0.category, unit: $0.unit, defaultDoseText: $0.defaultDoseText, defaultRoute: $0.defaultRoute, reminderIntervalDays: $0.reminderIntervalDays, note: $0.note, isActive: $0.isActive, createdAt: $0.createdAt) },
            inventoryLots: try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, catalogName: $0.catalogName, catalogItemID: $0.catalogItemID, legacySourceKey: $0.legacySourceKey, batchNumber: $0.batchNumber, supplier: $0.supplier, receivedAt: $0.receivedAt, unit: $0.unit, kindRawValue: $0.kindRawValue, expiresAt: $0.expiresAt, startingQuantityText: $0.startingQuantityText, createdAt: $0.createdAt, isActive: $0.isActive, deletedAt: $0.deletedAt) },
            inventoryTransactions: try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, inventoryLotID: $0.inventoryLotID, kindRawValue: $0.kindRawValue, quantityText: $0.quantityText, occurredAt: $0.occurredAt, sourceRecordID: $0.sourceRecordID, note: $0.note, createdAt: $0.createdAt, deletedAt: $0.deletedAt) },
            health: try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, sheepID: $0.sheepID, penID: $0.penID, kindRawValue: $0.kindRawValue, itemNameSnapshot: $0.itemNameSnapshot, occurredAt: $0.occurredAt, note: $0.note, inventoryLotID: $0.inventoryLotID, catalogItemID: $0.catalogItemID, batchID: $0.batchID, quantityText: $0.quantityText, unit: $0.unit, route: $0.route, legacySourceKey: $0.legacySourceKey, createdAt: $0.createdAt, deletedAt: $0.deletedAt) },
            healthSubjects: try context.fetch(FetchDescriptor<HealthSubjectLink>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, healthRecordID: $0.healthRecordID, sheepID: $0.sheepID, createdAt: $0.createdAt) },
            semen: try context.fetch(FetchDescriptor<SemenRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, code: $0.code, breed: $0.breed, source: $0.source, batchNumber: $0.batchNumber, quantityText: $0.quantityText, legacySourceKey: $0.legacySourceKey, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt) },
            semenTransactions: try context.fetch(FetchDescriptor<SemenTransactionRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, semenID: $0.semenID, kindRawValue: $0.kindRawValue, quantityText: $0.quantityText, occurredAt: $0.occurredAt, sourceRecordID: $0.sourceRecordID, note: $0.note, createdAt: $0.createdAt, deletedAt: $0.deletedAt) },
            reproduction: try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, eweID: $0.eweID, kindRawValue: $0.kindRawValue, occurredAt: $0.occurredAt, sireID: $0.sireID, semenID: $0.semenID, batchID: $0.batchID, semenNameSnapshot: $0.semenNameSnapshot, result: $0.result, lambCount: $0.lambCount, parity: $0.parity, birthDeadCount: $0.birthDeadCount, note: $0.note, legacySourceKey: $0.legacySourceKey, createdAt: $0.createdAt, deletedAt: $0.deletedAt) },
            offspring: try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, lambingRecordID: $0.lambingRecordID, sheepID: $0.sheepID, legacyEarTag: $0.legacyEarTag, sexRawValue: $0.sexRawValue, birthWeightText: $0.birthWeightText, isStillborn: $0.isStillborn, createdAt: $0.createdAt) },
            batches: try context.fetch(FetchDescriptor<CareBatchRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, kindRawValue: $0.kindRawValue, occurredAt: $0.occurredAt, note: $0.note, createdAt: $0.createdAt, deletedAt: $0.deletedAt) },
            rules: try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, pregnancyCheckDays: $0.pregnancyCheckDays, gestationDays: $0.gestationDays, createdAt: $0.createdAt, updatedAt: $0.updatedAt, revision: $0.revision) },
            reminders: try context.fetch(FetchDescriptor<CareReminderRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, kindRawValue: $0.kindRawValue, sourceEntityType: $0.sourceEntityType, sourceEntityID: $0.sourceEntityID, sheepID: $0.sheepID, inventoryLotID: $0.inventoryLotID, dueAt: $0.dueAt, title: $0.title, statusRawValue: $0.statusRawValue, createdAt: $0.createdAt, completedAt: $0.completedAt, deletedAt: $0.deletedAt, revision: $0.revision) }
        )
    }

    func validate(penIDs: Set<UUID>, sheepIDs: Set<UUID>) throws {
        try requireUnique(catalogs.map(\.id), "健康目录")
        try requireUnique(inventoryLots.map(\.id), "库存批次")
        try requireUnique(inventoryTransactions.map(\.id), "库存流水")
        try requireUnique(health.map(\.id), "健康记录")
        try requireUnique(healthSubjects.map(\.id), "健康对象")
        try requireUnique(semen.map(\.id), "冻精")
        try requireUnique(semenTransactions.map(\.id), "冻精流水")
        try requireUnique(reproduction.map(\.id), "繁殖记录")
        try requireUnique(offspring.map(\.id), "羔羊明细")
        try requireUnique(batches.map(\.id), "健康繁殖批次")
        try requireUnique(rules.map(\.id), "提醒规则")
        try requireUnique(reminders.map(\.id), "提醒")
        let catalogIDs = Set(catalogs.map(\.id)); let lotIDs = Set(inventoryLots.map(\.id)); let healthIDs = Set(health.map(\.id)); let semenIDs = Set(semen.map(\.id)); let reproductionIDs = Set(reproduction.map(\.id)); let batchIDs = Set(batches.map(\.id))
        for value in inventoryLots { if let id = value.catalogItemID, !catalogIDs.contains(id) { throw FarmLocalBackupError.missingReference("inventoryLot.catalogItemID") } }
        for value in inventoryTransactions where !lotIDs.contains(value.inventoryLotID) { throw FarmLocalBackupError.missingReference("inventoryTransaction.inventoryLotID") }
        for value in health { if let id = value.sheepID, !sheepIDs.contains(id) { throw FarmLocalBackupError.missingReference("health.sheepID") }; if let id = value.penID, !penIDs.contains(id) { throw FarmLocalBackupError.missingReference("health.penID") }; if let id = value.inventoryLotID, !lotIDs.contains(id) { throw FarmLocalBackupError.missingReference("health.inventoryLotID") }; if let id = value.catalogItemID, !catalogIDs.contains(id) { throw FarmLocalBackupError.missingReference("health.catalogItemID") }; if let id = value.batchID, !batchIDs.contains(id) { throw FarmLocalBackupError.missingReference("health.batchID") } }
        for value in healthSubjects where !healthIDs.contains(value.healthRecordID) || !sheepIDs.contains(value.sheepID) { throw FarmLocalBackupError.missingReference("healthSubject") }
        for value in semenTransactions where !semenIDs.contains(value.semenID) { throw FarmLocalBackupError.missingReference("semenTransaction.semenID") }
        for value in reproduction { guard sheepIDs.contains(value.eweID) else { throw FarmLocalBackupError.missingReference("reproduction.eweID") }; if let id = value.sireID, !sheepIDs.contains(id) { throw FarmLocalBackupError.missingReference("reproduction.sireID") }; if let id = value.semenID, !semenIDs.contains(id) { throw FarmLocalBackupError.missingReference("reproduction.semenID") }; if let id = value.batchID, !batchIDs.contains(id) { throw FarmLocalBackupError.missingReference("reproduction.batchID") } }
        for value in offspring { guard reproductionIDs.contains(value.lambingRecordID) else { throw FarmLocalBackupError.missingReference("offspring.lambingRecordID") }; if let id = value.sheepID, !sheepIDs.contains(id) { throw FarmLocalBackupError.missingReference("offspring.sheepID") } }
        for value in reminders { if let id = value.sheepID, !sheepIDs.contains(id) { throw FarmLocalBackupError.missingReference("reminder.sheepID") }; if let id = value.inventoryLotID, !lotIDs.contains(id) { throw FarmLocalBackupError.missingReference("reminder.inventoryLotID") } }
    }

    @MainActor
    func insert(farmID: UUID, context: ModelContext) {
        for value in catalogs { let record = HealthCatalogItemRecord(id: value.id, farmID: farmID, legacySourceKey: value.legacySourceKey, legacyCatalogID: value.legacyCatalogID, kindRawValue: value.kindRawValue, name: value.name, category: value.category, unit: value.unit, defaultDoseText: value.defaultDoseText, defaultRoute: value.defaultRoute, reminderIntervalDays: value.reminderIntervalDays, note: value.note, isActive: value.isActive); record.createdAt = value.createdAt; context.insert(record) }
        for value in inventoryLots { let record = InventoryLotRecord(id: value.id, farmID: farmID, catalogName: value.catalogName, catalogItemID: value.catalogItemID, kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment, expiresAt: value.expiresAt, startingQuantityText: value.startingQuantityText, legacySourceKey: value.legacySourceKey, batchNumber: value.batchNumber, supplier: value.supplier, receivedAt: value.receivedAt, unit: value.unit); record.createdAt = value.createdAt; record.isActive = value.isActive; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in inventoryTransactions { let record = InventoryTransactionRecord(id: value.id, farmID: farmID, inventoryLotID: value.inventoryLotID, kind: InventoryTransactionKind(rawValue: value.kindRawValue) ?? .adjustment, quantityText: value.quantityText, occurredAt: value.occurredAt, sourceRecordID: value.sourceRecordID, note: value.note); record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in health { let record = HealthRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, penID: value.penID, kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment, itemNameSnapshot: value.itemNameSnapshot, occurredAt: value.occurredAt, note: value.note, inventoryLotID: value.inventoryLotID, catalogItemID: value.catalogItemID, batchID: value.batchID, quantityText: value.quantityText, unit: value.unit, route: value.route, legacySourceKey: value.legacySourceKey); record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in healthSubjects { let record = HealthSubjectLink(id: value.id, farmID: farmID, healthRecordID: value.healthRecordID, sheepID: value.sheepID); record.createdAt = value.createdAt; context.insert(record) }
        for value in semen { let record = SemenRecord(id: value.id, farmID: farmID, code: value.code, breed: value.breed, source: value.source, batchNumber: value.batchNumber, quantityText: value.quantityText, legacySourceKey: value.legacySourceKey); record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in semenTransactions { let record = SemenTransactionRecord(id: value.id, farmID: farmID, semenID: value.semenID, kind: SemenTransactionKind(rawValue: value.kindRawValue) ?? .adjustment, quantityText: value.quantityText, occurredAt: value.occurredAt, sourceRecordID: value.sourceRecordID, note: value.note); record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in reproduction { let record = ReproductionRecord(id: value.id, farmID: farmID, eweID: value.eweID, kind: ReproductionRecordKind(rawValue: value.kindRawValue) ?? .breeding, occurredAt: value.occurredAt, sireID: value.sireID, semenID: value.semenID, batchID: value.batchID, semenNameSnapshot: value.semenNameSnapshot, result: value.result, lambCount: value.lambCount, parity: value.parity, birthDeadCount: value.birthDeadCount, note: value.note, legacySourceKey: value.legacySourceKey); record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in offspring { let record = LambingOffspringRecord(id: value.id, farmID: farmID, lambingRecordID: value.lambingRecordID, sheepID: value.sheepID, legacyEarTag: value.legacyEarTag, sexRawValue: value.sexRawValue, birthWeightText: value.birthWeightText, isStillborn: value.isStillborn); record.createdAt = value.createdAt; context.insert(record) }
        for value in batches { let record = CareBatchRecord(id: value.id, farmID: farmID, kind: CareBatchKind(rawValue: value.kindRawValue) ?? .health, occurredAt: value.occurredAt, note: value.note); record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in rules { let record = FarmCareRuleRecord(id: value.id, farmID: farmID, pregnancyCheckDays: value.pregnancyCheckDays, gestationDays: value.gestationDays); record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.revision = value.revision; context.insert(record) }
        for value in reminders { let record = CareReminderRecord(id: value.id, farmID: farmID, kind: CareReminderKind(rawValue: value.kindRawValue) ?? .booster, sourceEntityType: value.sourceEntityType, sourceEntityID: value.sourceEntityID, sheepID: value.sheepID, inventoryLotID: value.inventoryLotID, dueAt: value.dueAt, title: value.title); record.statusRawValue = value.statusRawValue; record.createdAt = value.createdAt; record.completedAt = value.completedAt; record.deletedAt = value.deletedAt; record.revision = value.revision; context.insert(record) }
    }

    private func requireUnique(_ ids: [UUID], _ type: String) throws {
        guard Set(ids).count == ids.count else { throw FarmLocalBackupError.duplicateIdentifier(type) }
    }
}
