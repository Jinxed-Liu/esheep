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
    case abortion
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
    let relatedBreedingRecordID: UUID?

    init(id: UUID = UUID(), eweID: UUID, result: String = "", relatedBreedingRecordID: UUID? = nil) {
        self.id = id
        self.eweID = eweID
        self.result = result
        self.relatedBreedingRecordID = relatedBreedingRecordID
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
    /// Kept under its legacy payload name for backward cloud compatibility.
    /// The value is only a true birth weight when `weightOccurredAt` is within
    /// the birth-weight window; later values become ordinary WeightRecords.
    let birthWeightText: String
    let weightOccurredAt: Date?
    let createSheepRecord: Bool
    let isStillborn: Bool

    init(
        id: UUID = UUID(),
        sheepID: UUID = UUID(),
        earTag: String,
        sex: SheepSex,
        birthWeightText: String = "",
        weightOccurredAt: Date? = nil,
        createSheepRecord: Bool = true,
        isStillborn: Bool = false
    ) {
        self.id = id
        self.sheepID = sheepID
        self.earTag = earTag
        self.sex = sex
        self.birthWeightText = birthWeightText
        self.weightOccurredAt = weightOccurredAt
        self.createSheepRecord = createSheepRecord
        self.isStillborn = isStillborn
    }
}

struct CareLambingDraft: Codable, Sendable, Equatable {
    let id: UUID
    let eweID: UUID
    let occurredAt: Date
    let sireID: UUID?
    let semenID: UUID?
    let relatedBreedingRecordID: UUID?
    let parity: Int
    let birthDeadCount: Int
    let offspring: [CareLambDraft]
    let penID: UUID?
    let note: String

    init(id: UUID = UUID(), eweID: UUID, occurredAt: Date, sireID: UUID?, semenID: UUID?, relatedBreedingRecordID: UUID? = nil, parity: Int, birthDeadCount: Int, offspring: [CareLambDraft], penID: UUID?, note: String) {
        self.id = id
        self.eweID = eweID
        self.occurredAt = occurredAt
        self.sireID = sireID
        self.semenID = semenID
        self.relatedBreedingRecordID = relatedBreedingRecordID
        self.parity = parity
        self.birthDeadCount = birthDeadCount
        self.offspring = offspring
        self.penID = penID
        self.note = note
    }
}

struct CarePedigreeUpdateDraft: Codable, Sendable, Equatable {
    let id: UUID
    let sheepID: UUID
    let damID: UUID?
    let sireID: UUID?
    let semenDonorID: UUID?
    let reason: String
    let expectedRevision: Int

    init(id: UUID = UUID(), sheepID: UUID, damID: UUID?, sireID: UUID?, semenDonorID: UUID?, reason: String, expectedRevision: Int) {
        self.id = id
        self.sheepID = sheepID
        self.damID = damID
        self.sireID = sireID
        self.semenDonorID = semenDonorID
        self.reason = reason
        self.expectedRevision = expectedRevision
    }
}

struct CareSemenDonorDraft: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let registrationNumber: String
    let breed: String
    let linkedRamID: UUID?
    let note: String
    let status: SemenDonorStatus
    let expectedRevision: Int

    init(id: UUID = UUID(), name: String, registrationNumber: String = "", breed: String, linkedRamID: UUID? = nil, note: String = "", status: SemenDonorStatus = .active, expectedRevision: Int = 0) {
        self.id = id
        self.name = name
        self.registrationNumber = registrationNumber
        self.breed = breed
        self.linkedRamID = linkedRamID
        self.note = note
        self.status = status
        self.expectedRevision = expectedRevision
    }
}

struct CarePedigreeAuditSnapshot: Codable, Sendable, Equatable {
    let id: UUID
    let sheepID: UUID
    let beforeDamID: UUID?
    let afterDamID: UUID?
    let beforeSireID: UUID?
    let afterSireID: UUID?
    let beforeSemenDonorID: UUID?
    let afterSemenDonorID: UUID?
    let beforeDamSourceRawValue: String?
    let afterDamSourceRawValue: String?
    let beforeSireSourceRawValue: String?
    let afterSireSourceRawValue: String?
    let reason: String
    let changedByAccountID: UUID
    let sheepRevision: Int
    let occurredAt: Date
}

enum CareCommand: Codable, Sendable, Equatable {
    case upsertHealthCatalog(id: UUID, kindRawValue: String, name: String, category: String, unit: String, defaultDoseText: String?, defaultRoute: String, reminderIntervalDays: Int?, note: String, isActive: Bool)
    case recordHealth(CareHealthDraft)
    case correctHealth(originalID: UUID, replacement: CareHealthDraft, reason: String)
    case receiveInventory(id: UUID, catalogName: String, catalogItemID: UUID?, kindRawValue: String, batchNumber: String, supplier: String, unit: String, expiresAt: Date?, quantityText: String, occurredAt: Date, note: String)
    case adjustInventory(id: UUID, lotID: UUID, quantityDeltaText: String, occurredAt: Date, note: String)
    case setInventoryLotActive(lotID: UUID, isActive: Bool)
    case adjustSemen(id: UUID, semenID: UUID, quantityDeltaText: String, occurredAt: Date, note: String)
    case upsertSemenDonor(CareSemenDonorDraft)
    case setSemenDonor(semenID: UUID, donorID: UUID?, expectedRevision: Int)
    case updateSheepPedigree(CarePedigreeUpdateDraft)
    case setBreedingRam(sheepID: UUID, isBreedingRam: Bool, expectedRevision: Int)
    case restorePedigreeAudit(CarePedigreeAuditSnapshot)
    case recordReproductionBatch(CareReproductionBatchDraft)
    case recordLambing(CareLambingDraft)
    case correctReproduction(originalID: UUID, replacement: CareReproductionBatchDraft, reason: String)
    case correctLambing(originalID: UUID, replacement: CareLambingDraft, reason: String)
    case revokeLambing(recordID: UUID, reason: String)
    case restoreLambing(recordID: UUID)
    case updateRules(id: UUID, pregnancyCheckDays: Int, gestationDays: Int)
    case setReminderStatus(reminderID: UUID, status: CareReminderStatus)

    var primaryID: UUID {
        switch self {
        case .upsertHealthCatalog(let id, _, _, _, _, _, _, _, _, _): id
        case .recordHealth(let draft): draft.id
        case .correctHealth(_, let replacement, _): replacement.id
        case .receiveInventory(let id, _, _, _, _, _, _, _, _, _, _): id
        case .adjustInventory(let id, _, _, _, _): id
        case .setInventoryLotActive(let lotID, _): lotID
        case .adjustSemen(let id, _, _, _, _): id
        case .upsertSemenDonor(let draft): draft.id
        case .setSemenDonor(let semenID, _, _): semenID
        case .updateSheepPedigree(let draft): draft.sheepID
        case .setBreedingRam(let sheepID, _, _): sheepID
        case .restorePedigreeAudit(let snapshot): snapshot.id
        case .recordReproductionBatch(let draft): draft.id
        case .recordLambing(let draft): draft.id
        case .correctReproduction(_, let replacement, _): replacement.id
        case .correctLambing(let originalID, _, _): originalID
        case .revokeLambing(let recordID, _), .restoreLambing(let recordID): recordID
        case .updateRules(let id, _, _): id
        case .setReminderStatus(let reminderID, _): reminderID
        }
    }

    var requiredCapability: FarmCapability {
        switch self {
        case .upsertHealthCatalog, .receiveInventory, .adjustInventory, .setInventoryLotActive, .adjustSemen, .upsertSemenDonor, .setSemenDonor, .updateRules:
            .manageCatalogs
        case .correctHealth, .correctReproduction, .updateSheepPedigree, .setBreedingRam, .restorePedigreeAudit, .correctLambing, .revokeLambing, .restoreLambing:
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
        case .receiveInventory: "药品疫苗入库"
        case .adjustInventory: "调整药品疫苗库存"
        case .setInventoryLotActive(_, let active): active ? "启用库存批次" : "停用库存批次"
        case .adjustSemen: "调整冻精库存"
        case .upsertSemenDonor: "维护冻精供体"
        case .setSemenDonor: "关联冻精供体"
        case .updateSheepPedigree: "确认羊只系谱"
        case .setBreedingRam(_, let active, _): active ? "标记种公羊" : "取消种公羊标记"
        case .restorePedigreeAudit: "恢复系谱审计"
        case .recordReproductionBatch(let draft): "批量记录\(draft.kind.displayName)"
        case .recordLambing: "记录产羔并建立羔羊档案"
        case .correctReproduction: "修正繁殖记录"
        case .correctLambing: "修正产羔记录"
        case .revokeLambing: "撤销产羔记录"
        case .restoreLambing: "恢复产羔记录"
        case .updateRules: "更新健康繁殖提醒规则"
        case .setReminderStatus: "更新健康繁殖提醒"
        }
    }

    var rebuildHistoryFrom: Date? {
        switch self {
        case .recordLambing(let draft): draft.occurredAt
        case .correctLambing(_, let draft, _): draft.occurredAt
        case .recordReproductionBatch(let draft), .correctReproduction(_, let draft, _): draft.occurredAt
        default: nil
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
