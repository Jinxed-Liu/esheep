import Foundation
import SwiftData

enum SemenTransactionKind: String, Codable, CaseIterable, Sendable {
    case receipt
    case consumption
    case adjustment
}

enum CareReminderKind: String, Codable, CaseIterable, Sendable {
    case booster
    case pregnancyCheck
    case expectedLambing
    case inventoryExpiry

    var displayName: String {
        switch self {
        case .booster: "复免"
        case .pregnancyCheck: "孕检"
        case .expectedLambing: "预产"
        case .inventoryExpiry: "库存到期"
        }
    }
}

enum CareReminderStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case completed
    case dismissed
}

enum CareBatchKind: String, Codable, Sendable {
    case health
    case breeding
    case pregnancyCheck
}

struct CareHealthDraft: Codable, Sendable, Equatable {
    let id: UUID
    let batchID: UUID
    let subjectIDs: [UUID]
    let penID: UUID?
    let catalogItemID: UUID?
    let kind: HealthRecordKind
    let itemName: String
    let occurredAt: Date
    let note: String
    let inventoryLotID: UUID?
    let dosePerSubjectText: String?
    let unit: String
    let route: String
    let reminderAt: Date?
}

struct CareReproductionSubjectDraft: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let eweID: UUID
    let result: String

    init(id: UUID = UUID(), eweID: UUID, result: String = "") {
        self.id = id
        self.eweID = eweID
        self.result = result
    }
}

struct CareReproductionBatchDraft: Codable, Sendable, Equatable {
    let id: UUID
    let kind: ReproductionRecordKind
    let subjects: [CareReproductionSubjectDraft]
    let occurredAt: Date
    let sireID: UUID?
    let semenID: UUID?
    let semenUnitsPerEweText: String?
    let note: String
    let reminderAt: Date?
}

struct CareLambDraft: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let sheepID: UUID
    let earTag: String
    let sex: SheepSex
    let birthWeightText: String
    let createSheepRecord: Bool

    init(id: UUID = UUID(), sheepID: UUID = UUID(), earTag: String, sex: SheepSex, birthWeightText: String, createSheepRecord: Bool = true) {
        self.id = id
        self.sheepID = sheepID
        self.earTag = earTag
        self.sex = sex
        self.birthWeightText = birthWeightText
        self.createSheepRecord = createSheepRecord
    }
}

struct CareLambingDraft: Codable, Sendable, Equatable {
    let id: UUID
    let eweID: UUID
    let occurredAt: Date
    let sireID: UUID?
    let semenID: UUID?
    let parity: Int
    let birthDeadCount: Int
    let offspring: [CareLambDraft]
    let penID: UUID?
    let note: String
}

enum CareCommand: Codable, Sendable, Equatable {
    case upsertHealthCatalog(id: UUID, kindRawValue: String, name: String, category: String, unit: String, defaultDoseText: String?, defaultRoute: String, reminderIntervalDays: Int?, note: String, isActive: Bool)
    case recordHealth(CareHealthDraft)
    case correctHealth(originalID: UUID, replacement: CareHealthDraft, reason: String)
    case adjustInventory(id: UUID, lotID: UUID, quantityDeltaText: String, occurredAt: Date, note: String)
    case setInventoryLotActive(lotID: UUID, isActive: Bool)
    case adjustSemen(id: UUID, semenID: UUID, quantityDeltaText: String, occurredAt: Date, note: String)
    case recordReproductionBatch(CareReproductionBatchDraft)
    case recordLambing(CareLambingDraft)
    case correctReproduction(originalID: UUID, replacement: CareReproductionBatchDraft, reason: String)
    case updateRules(id: UUID, pregnancyCheckDays: Int, gestationDays: Int)
    case setReminderStatus(reminderID: UUID, status: CareReminderStatus)

    var primaryID: UUID {
        switch self {
        case .upsertHealthCatalog(let id, _, _, _, _, _, _, _, _, _): id
        case .recordHealth(let draft): draft.id
        case .correctHealth(_, let replacement, _): replacement.id
        case .adjustInventory(let id, _, _, _, _): id
        case .setInventoryLotActive(let lotID, _): lotID
        case .adjustSemen(let id, _, _, _, _): id
        case .recordReproductionBatch(let draft): draft.id
        case .recordLambing(let draft): draft.id
        case .correctReproduction(_, let replacement, _): replacement.id
        case .updateRules(let id, _, _): id
        case .setReminderStatus(let reminderID, _): reminderID
        }
    }

    var requiredCapability: FarmCapability {
        switch self {
        case .upsertHealthCatalog, .adjustInventory, .setInventoryLotActive, .adjustSemen, .updateRules:
            .manageCatalogs
        case .correctHealth, .correctReproduction:
            .editHistoricalFacts
        case .recordHealth, .recordReproductionBatch, .recordLambing, .setReminderStatus:
            .recordProduction
        }
    }

    var summary: String {
        switch self {
        case .upsertHealthCatalog: "维护健康目录"
        case .recordHealth: "记录批量健康事项"
        case .correctHealth: "修正健康记录"
        case .adjustInventory: "调整药品疫苗库存"
        case .setInventoryLotActive(_, let active): active ? "启用库存批次" : "停用库存批次"
        case .adjustSemen: "调整冻精库存"
        case .recordReproductionBatch(let draft): "批量记录\(draft.kind.displayName)"
        case .recordLambing: "记录产羔并建立羔羊档案"
        case .correctReproduction: "修正繁殖记录"
        case .updateRules: "更新健康繁殖提醒规则"
        case .setReminderStatus: "更新健康繁殖提醒"
        }
    }
}

@Model
final class CareBatchRecord {
    var id: UUID
    var farmID: UUID
    var kindRawValue: String
    var occurredAt: Date
    var note: String
    var createdAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, kind: CareBatchKind, occurredAt: Date, note: String = "") {
        self.id = id
        self.farmID = farmID
        self.kindRawValue = kind.rawValue
        self.occurredAt = occurredAt
        self.note = note
        self.createdAt = .now
    }
}

@Model
final class SemenTransactionRecord {
    var id: UUID
    var farmID: UUID
    var semenID: UUID
    var kindRawValue: String
    var quantityText: String
    var occurredAt: Date
    var sourceRecordID: UUID?
    var note: String
    var createdAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, semenID: UUID, kind: SemenTransactionKind, quantityText: String, occurredAt: Date, sourceRecordID: UUID? = nil, note: String = "") {
        self.id = id
        self.farmID = farmID
        self.semenID = semenID
        self.kindRawValue = kind.rawValue
        self.quantityText = quantityText
        self.occurredAt = occurredAt
        self.sourceRecordID = sourceRecordID
        self.note = note
        self.createdAt = .now
    }

    var kind: SemenTransactionKind { SemenTransactionKind(rawValue: kindRawValue) ?? .adjustment }
    var quantity: Decimal { Decimal.stable(quantityText) ?? 0 }
}

@Model
final class FarmCareRuleRecord {
    var id: UUID
    var farmID: UUID
    var pregnancyCheckDays: Int
    var gestationDays: Int
    var createdAt: Date
    var updatedAt: Date
    var revision: Int

    init(id: UUID = UUID(), farmID: UUID, pregnancyCheckDays: Int = 45, gestationDays: Int = 150) {
        self.id = id
        self.farmID = farmID
        self.pregnancyCheckDays = pregnancyCheckDays
        self.gestationDays = gestationDays
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 1
    }
}

@Model
final class CareReminderRecord {
    var id: UUID
    var farmID: UUID
    var kindRawValue: String
    var sourceEntityType: String
    var sourceEntityID: UUID
    var sheepID: UUID?
    var inventoryLotID: UUID?
    var dueAt: Date
    var title: String
    var statusRawValue: String
    var createdAt: Date
    var completedAt: Date?
    var deletedAt: Date?
    var revision: Int

    init(id: UUID = UUID(), farmID: UUID, kind: CareReminderKind, sourceEntityType: String, sourceEntityID: UUID, sheepID: UUID? = nil, inventoryLotID: UUID? = nil, dueAt: Date, title: String) {
        self.id = id
        self.farmID = farmID
        self.kindRawValue = kind.rawValue
        self.sourceEntityType = sourceEntityType
        self.sourceEntityID = sourceEntityID
        self.sheepID = sheepID
        self.inventoryLotID = inventoryLotID
        self.dueAt = dueAt
        self.title = title
        self.statusRawValue = CareReminderStatus.pending.rawValue
        self.createdAt = .now
        self.revision = 1
    }

    var kind: CareReminderKind { CareReminderKind(rawValue: kindRawValue) ?? .booster }
    var status: CareReminderStatus { CareReminderStatus(rawValue: statusRawValue) ?? .pending }
}
