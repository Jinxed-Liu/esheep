import Foundation
import SwiftData

enum SheepSex: String, CaseIterable, Codable, Sendable {
    case ewe
    case ram
    case unknown

    var displayName: String {
        switch self {
        case .ewe: "母羊"
        case .ram: "公羊"
        case .unknown: "未知"
        }
    }
}

enum SheepStatus: String, CaseIterable, Codable, Sendable {
    case active
    case removed
    case deceased

    var displayName: String {
        switch self {
        case .active: "在场"
        case .removed: "离场"
        case .deceased: "死亡"
        }
    }
}

enum FeedMode: String, CaseIterable, Codable, Sendable {
    case limited
    case freeChoice

    var displayName: String {
        switch self {
        case .limited: "限量投喂"
        case .freeChoice: "自由采食"
        }
    }
}

enum HealthRecordKind: String, CaseIterable, Codable, Sendable {
    case treatment
    case vaccination

    var displayName: String {
        switch self {
        case .treatment: "治疗"
        case .vaccination: "疫苗"
        }
    }
}

enum ReproductionRecordKind: String, CaseIterable, Codable, Sendable {
    case breeding
    case pregnancyCheck
    case lambing
    case abortion

    var displayName: String {
        switch self {
        case .breeding: "配种"
        case .pregnancyCheck: "孕检"
        case .lambing: "产羔"
        case .abortion: "流产"
        }
    }
}

enum RemovalKind: String, CaseIterable, Codable, Sendable {
    case sold
    case culled
    case deceased
    case transferredOut

    var displayName: String {
        switch self {
        case .sold: "出售"
        case .culled: "淘汰"
        case .deceased: "死亡"
        case .transferredOut: "转出"
        }
    }

    var resultingStatus: SheepStatus {
        self == .deceased ? .deceased : .removed
    }
}

enum ProductionBatchStatus: String, CaseIterable, Codable, Sendable {
    case active
    case completed
    case needsReview
}

enum ProductionBatchSource: String, CaseIterable, Codable, Sendable {
    case manual
    case historicalMigration
    case historicalInference
}

enum InventoryTransactionKind: String, CaseIterable, Codable, Sendable {
    case receipt
    case consumption
    case adjustment
}

@Model
final class PenRecord {
    var id: UUID
    var farmID: UUID
    var name: String
    var note: String
    var isActive: Bool
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, name: String, note: String = "", createdAt: Date = .now) {
        self.id = id
        self.farmID = farmID
        self.name = name
        self.note = note
        self.isActive = true
        self.revision = 1
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

@Model
final class SheepRecord {
    var id: UUID
    var farmID: UUID
    var earTag: String
    var legacyEarTag: String?
    var legacySourceKey: String?
    var isHistoricalArchive: Bool
    /// 旧版羊只表中的当前状态、当前圈舍是物化快照；试迁时不得被残缺历史反向覆盖。
    var legacyStatusSnapshotIsAuthoritative: Bool?
    var legacyPenSnapshotIsAuthoritative: Bool?
    var breed: String
    var purpose: String
    var sexRawValue: String
    var statusRawValue: String
    var currentPenID: UUID?
    var initialPenID: UUID?
    var damID: UUID?
    var sireID: UUID?
    var enteredAt: Date
    var birthAt: Date?
    var removedAt: Date?
    var note: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        earTag: String,
        legacyEarTag: String? = nil,
        legacySourceKey: String? = nil,
        isHistoricalArchive: Bool = false,
        breed: String,
        purpose: String = "未分类",
        sex: SheepSex,
        penID: UUID?,
        enteredAt: Date,
        birthAt: Date? = nil,
        damID: UUID? = nil,
        sireID: UUID? = nil,
        note: String = ""
    ) {
        self.id = id
        self.farmID = farmID
        self.earTag = earTag
        self.legacyEarTag = legacyEarTag
        self.legacySourceKey = legacySourceKey
        self.isHistoricalArchive = isHistoricalArchive
        self.legacyStatusSnapshotIsAuthoritative = false
        self.legacyPenSnapshotIsAuthoritative = false
        self.breed = breed
        self.purpose = purpose
        self.sexRawValue = sex.rawValue
        self.statusRawValue = SheepStatus.active.rawValue
        self.currentPenID = penID
        self.initialPenID = penID
        self.damID = damID
        self.sireID = sireID
        self.enteredAt = enteredAt
        self.birthAt = birthAt
        self.removedAt = nil
        self.note = note
        self.revision = 1
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sex: SheepSex { SheepSex(rawValue: sexRawValue) ?? .unknown }
    var status: SheepStatus { SheepStatus(rawValue: statusRawValue) ?? .active }

    /// `currentPenID` 只描述当前在场位置；离场、死亡和历史归档羊不属于任何当前圈舍。
    var isCurrentlyPresent: Bool { status == .active && !isHistoricalArchive }

    func currentPenDisplayName(_ penName: String?) -> String {
        isCurrentlyPresent ? (penName ?? "未分圈") : "已离群"
    }
}

@Model
final class WeightRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID
    var kilogramsText: String
    var occurredAt: Date
    var recordedAt: Date
    var note: String
    var revision: Int
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, sheepID: UUID, kilogramsText: String, occurredAt: Date, note: String = "") {
        self.id = id
        self.farmID = farmID
        self.sheepID = sheepID
        self.kilogramsText = kilogramsText
        self.occurredAt = occurredAt
        self.recordedAt = .now
        self.note = note
        self.revision = 1
    }

    var kilograms: Decimal { Decimal.stable(kilogramsText) ?? 0 }
}

@Model
final class WeaningRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID
    var occurredAt: Date
    var weanWeightText: String
    var birthAt: Date?
    var birthWeightText: String?
    var averageDailyGainText: String?
    var damID: UUID?
    var legacyDamEarTag: String?
    var litterSize: Int?
    var note: String
    var legacySourceKey: String?
    var recordedAt: Date
    var revision: Int
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        sheepID: UUID,
        occurredAt: Date,
        weanWeightText: String,
        birthAt: Date? = nil,
        birthWeightText: String? = nil,
        averageDailyGainText: String? = nil,
        damID: UUID? = nil,
        legacyDamEarTag: String? = nil,
        litterSize: Int? = nil,
        note: String = "",
        legacySourceKey: String? = nil
    ) {
        self.id = id
        self.farmID = farmID
        self.sheepID = sheepID
        self.occurredAt = occurredAt
        self.weanWeightText = weanWeightText
        self.birthAt = birthAt
        self.birthWeightText = birthWeightText
        self.averageDailyGainText = averageDailyGainText
        self.damID = damID
        self.legacyDamEarTag = legacyDamEarTag
        self.litterSize = litterSize
        self.note = note
        self.legacySourceKey = legacySourceKey
        self.recordedAt = .now
        self.revision = 1
    }

    var weanWeight: Decimal { Decimal.stable(weanWeightText) ?? 0 }
}

@Model
final class BreedingProgramRecord {
    var id: UUID
    var farmID: UUID
    var name: String
    var createdAt: Date
    var legacySourceKey: String?
    var revision: Int
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        name: String,
        createdAt: Date = .now,
        legacySourceKey: String? = nil
    ) {
        self.id = id
        self.farmID = farmID
        self.name = name
        self.createdAt = createdAt
        self.legacySourceKey = legacySourceKey
        self.revision = 1
    }
}

@Model
final class BreedingProgramStepRecord {
    var id: UUID
    var farmID: UUID
    var programID: UUID
    var dayOffset: Int
    var action: String
    var sortOrder: Int
    var legacySourceKey: String?
    var createdAt: Date
    var revision: Int
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        programID: UUID,
        dayOffset: Int,
        action: String,
        sortOrder: Int,
        legacySourceKey: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.programID = programID
        self.dayOffset = dayOffset
        self.action = action
        self.sortOrder = sortOrder
        self.legacySourceKey = legacySourceKey
        self.createdAt = createdAt
        self.revision = 1
    }
}

@Model
final class TransferRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID
    var fromPenID: UUID?
    var toPenID: UUID?
    var occurredAt: Date
    var recordedAt: Date
    var note: String
    var revision: Int
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, sheepID: UUID, fromPenID: UUID?, toPenID: UUID?, occurredAt: Date, note: String = "") {
        self.id = id
        self.farmID = farmID
        self.sheepID = sheepID
        self.fromPenID = fromPenID
        self.toPenID = toPenID
        self.occurredAt = occurredAt
        self.recordedAt = .now
        self.note = note
        self.revision = 1
    }
}

@Model
final class RemovalRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID
    var kindRawValue: String
    var reason: String
    var amountText: String?
    var occurredAt: Date
    var recordedAt: Date
    var note: String
    var revision: Int
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, sheepID: UUID, kind: RemovalKind, reason: String, amountText: String? = nil, occurredAt: Date, note: String = "") {
        self.id = id
        self.farmID = farmID
        self.sheepID = sheepID
        self.kindRawValue = kind.rawValue
        self.reason = reason
        self.amountText = amountText
        self.occurredAt = occurredAt
        self.recordedAt = .now
        self.note = note
        self.revision = 1
        self.deletedAt = nil
    }

    var kind: RemovalKind { RemovalKind(rawValue: kindRawValue) ?? .culled }
}

@Model
final class ProductionBatchRecord {
    var id: UUID
    var farmID: UUID
    var name: String
    var purpose: String
    var sourceRawValue: String
    var statusRawValue: String
    var startedAt: Date
    var endedAt: Date?
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, name: String, purpose: String, source: ProductionBatchSource = .manual, startedAt: Date, note: String = "") {
        self.id = id
        self.farmID = farmID
        self.name = name
        self.purpose = purpose
        self.sourceRawValue = source.rawValue
        self.statusRawValue = ProductionBatchStatus.active.rawValue
        self.startedAt = startedAt
        self.endedAt = nil
        self.note = note
        self.createdAt = .now
        self.updatedAt = .now
        self.deletedAt = nil
    }

    var status: ProductionBatchStatus { ProductionBatchStatus(rawValue: statusRawValue) ?? .active }
}

@Model
final class BatchMembershipRecord {
    var id: UUID
    var farmID: UUID
    var batchID: UUID
    var sheepID: UUID
    var joinedAt: Date
    var leftAt: Date?
    var leaveReason: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, batchID: UUID, sheepID: UUID, joinedAt: Date) {
        self.id = id
        self.farmID = farmID
        self.batchID = batchID
        self.sheepID = sheepID
        self.joinedAt = joinedAt
        self.leftAt = nil
        self.leaveReason = nil
        self.createdAt = .now
        self.updatedAt = .now
        self.deletedAt = nil
    }
}

@Model
final class DailyPenCountRecord {
    var id: UUID
    var farmID: UUID
    var penID: UUID
    var purpose: String
    var date: Date
    var count: Int
    var rebuiltAt: Date

    init(id: UUID = UUID(), farmID: UUID, penID: UUID, purpose: String, date: Date, count: Int, rebuiltAt: Date = .now) {
        self.id = id
        self.farmID = farmID
        self.penID = penID
        self.purpose = purpose
        self.date = date
        self.count = count
        self.rebuiltAt = rebuiltAt
    }
}

@Model
final class FeedIngredientRecord {
    var id: UUID
    var farmID: UUID
    var name: String
    var category: String
    var legacySourceKey: String?
    var nutrientSnapshotJSON: String
    var unit: String
    var dryMatterText: String?
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, name: String, unit: String = "千克", dryMatterText: String? = nil, category: String = "", legacySourceKey: String? = nil, nutrientSnapshotJSON: String = "{}") {
        self.id = id
        self.farmID = farmID
        self.name = name
        self.category = category
        self.legacySourceKey = legacySourceKey
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
        self.unit = unit
        self.dryMatterText = dryMatterText
        self.isActive = true
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@Model
final class FeedRecipeRecord {
    var id: UUID
    var farmID: UUID
    var name: String
    var targetPenName: String?
    var stageRawValue: String
    var headCount: Int?
    var legacySourceKey: String?
    var note: String
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, name: String, note: String = "", targetPenName: String? = nil, stageRawValue: String = "", headCount: Int? = nil, legacySourceKey: String? = nil) {
        self.id = id
        self.farmID = farmID
        self.name = name
        self.targetPenName = targetPenName
        self.stageRawValue = stageRawValue
        self.headCount = headCount
        self.legacySourceKey = legacySourceKey
        self.note = note
        self.isActive = true
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@Model
final class FeedRecipeComponentRecord {
    var id: UUID
    var farmID: UUID
    var recipeID: UUID
    var ingredientID: UUID
    var kilogramsText: String
    var legacyBatchID: String?
    var pricePerKilogramText: String?
    var nutrientSnapshotJSON: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, recipeID: UUID, ingredientID: UUID, kilogramsText: String, legacyBatchID: String? = nil, pricePerKilogramText: String? = nil, nutrientSnapshotJSON: String = "{}") {
        self.id = id
        self.farmID = farmID
        self.recipeID = recipeID
        self.ingredientID = ingredientID
        self.kilogramsText = kilogramsText
        self.legacyBatchID = legacyBatchID
        self.pricePerKilogramText = pricePerKilogramText
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@Model
final class FeedRecord {
    var id: UUID
    var farmID: UUID
    var penID: UUID
    var recipeID: UUID?
    var modeRawValue: String
    var occurredAt: Date
    var recordedAt: Date
    var note: String
    var mealName: String
    var feederName: String
    var remainingKilogramsText: String?
    var discardedKilogramsText: String?
    var legacySourceKey: String?
    var revision: Int
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, penID: UUID, recipeID: UUID? = nil, mode: FeedMode, occurredAt: Date, note: String = "", mealName: String = "", feederName: String = "", remainingKilogramsText: String? = nil, discardedKilogramsText: String? = nil, legacySourceKey: String? = nil) {
        self.id = id
        self.farmID = farmID
        self.penID = penID
        self.recipeID = recipeID
        self.modeRawValue = mode.rawValue
        self.occurredAt = occurredAt
        self.recordedAt = .now
        self.note = note
        self.mealName = mealName
        self.feederName = feederName
        self.remainingKilogramsText = remainingKilogramsText
        self.discardedKilogramsText = discardedKilogramsText
        self.legacySourceKey = legacySourceKey
        self.revision = 1
    }

    var mode: FeedMode { FeedMode(rawValue: modeRawValue) ?? .limited }
}

@Model
final class FeedRecordLine {
    var id: UUID
    var farmID: UUID
    var feedRecordID: UUID
    var ingredientID: UUID
    var kilogramsText: String
    var ingredientNameSnapshot: String
    var ingredientBatchID: UUID?
    var ingredientBatchNameSnapshot: String?
    var pricePerKilogramTextSnapshot: String?
    var nutrientSnapshotJSON: String?
    var unitSnapshot: String?
    var dryMatterTextSnapshot: String?
    var createdAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        feedRecordID: UUID,
        ingredientID: UUID,
        kilogramsText: String,
        ingredientNameSnapshot: String,
        ingredientBatchID: UUID? = nil,
        ingredientBatchNameSnapshot: String? = nil,
        pricePerKilogramTextSnapshot: String? = nil,
        nutrientSnapshotJSON: String? = nil,
        unitSnapshot: String? = nil,
        dryMatterTextSnapshot: String? = nil
    ) {
        self.id = id
        self.farmID = farmID
        self.feedRecordID = feedRecordID
        self.ingredientID = ingredientID
        self.kilogramsText = kilogramsText
        self.ingredientNameSnapshot = ingredientNameSnapshot
        self.ingredientBatchID = ingredientBatchID
        self.ingredientBatchNameSnapshot = ingredientBatchNameSnapshot
        self.pricePerKilogramTextSnapshot = pricePerKilogramTextSnapshot
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
        self.unitSnapshot = unitSnapshot
        self.dryMatterTextSnapshot = dryMatterTextSnapshot
        self.createdAt = .now
    }

    var kilograms: Decimal { Decimal.stable(kilogramsText) ?? 0 }
}

@Model
final class InventoryLotRecord {
    var id: UUID
    var farmID: UUID
    var catalogName: String
    var catalogItemID: UUID? = nil
    var legacySourceKey: String?
    var batchNumber: String
    var supplier: String
    var receivedAt: Date?
    var unit: String
    var kindRawValue: String
    var expiresAt: Date?
    var startingQuantityText: String
    var createdAt: Date
    var isActive: Bool
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, catalogName: String, catalogItemID: UUID? = nil, kind: HealthRecordKind, expiresAt: Date? = nil, startingQuantityText: String, legacySourceKey: String? = nil, batchNumber: String = "", supplier: String = "", receivedAt: Date? = nil, unit: String = "") {
        self.id = id
        self.farmID = farmID
        self.catalogName = catalogName
        self.catalogItemID = catalogItemID
        self.legacySourceKey = legacySourceKey
        self.batchNumber = batchNumber
        self.supplier = supplier
        self.receivedAt = receivedAt
        self.unit = unit
        self.kindRawValue = kind.rawValue
        self.expiresAt = expiresAt
        self.startingQuantityText = startingQuantityText
        self.createdAt = .now
        self.isActive = true
    }
}

@Model
final class InventoryTransactionRecord {
    var id: UUID
    var farmID: UUID
    var inventoryLotID: UUID
    var kindRawValue: String
    var quantityText: String
    var occurredAt: Date
    var sourceRecordID: UUID?
    var note: String
    var createdAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, inventoryLotID: UUID, kind: InventoryTransactionKind, quantityText: String, occurredAt: Date, sourceRecordID: UUID? = nil, note: String = "") {
        self.id = id
        self.farmID = farmID
        self.inventoryLotID = inventoryLotID
        self.kindRawValue = kind.rawValue
        self.quantityText = quantityText
        self.occurredAt = occurredAt
        self.sourceRecordID = sourceRecordID
        self.note = note
        self.createdAt = .now
        self.deletedAt = nil
    }

    var kind: InventoryTransactionKind { InventoryTransactionKind(rawValue: kindRawValue) ?? .adjustment }
    var quantity: Decimal { Decimal.stable(quantityText) ?? 0 }
}

@Model
final class HealthRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID?
    var penID: UUID?
    var kindRawValue: String
    var itemNameSnapshot: String
    var occurredAt: Date
    var note: String
    var inventoryLotID: UUID?
    var catalogItemID: UUID? = nil
    var batchID: UUID? = nil
    var quantityText: String?
    var unit: String
    var route: String
    var legacySourceKey: String?
    var createdAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, sheepID: UUID?, penID: UUID?, kind: HealthRecordKind, itemNameSnapshot: String, occurredAt: Date, note: String = "", inventoryLotID: UUID? = nil, catalogItemID: UUID? = nil, batchID: UUID? = nil, quantityText: String? = nil, unit: String = "", route: String = "", legacySourceKey: String? = nil) {
        self.id = id
        self.farmID = farmID
        self.sheepID = sheepID
        self.penID = penID
        self.kindRawValue = kind.rawValue
        self.itemNameSnapshot = itemNameSnapshot
        self.occurredAt = occurredAt
        self.note = note
        self.inventoryLotID = inventoryLotID
        self.catalogItemID = catalogItemID
        self.batchID = batchID
        self.quantityText = quantityText
        self.unit = unit
        self.route = route
        self.legacySourceKey = legacySourceKey
        self.createdAt = .now
    }

    var kind: HealthRecordKind { HealthRecordKind(rawValue: kindRawValue) ?? .treatment }
}

@Model
final class ReproductionRecord {
    var id: UUID
    var farmID: UUID
    var eweID: UUID
    var kindRawValue: String
    var occurredAt: Date
    var sireID: UUID?
    var semenID: UUID? = nil
    var batchID: UUID? = nil
    var semenNameSnapshot: String?
    var result: String
    var lambCount: Int
    var parity: Int?
    var birthDeadCount: Int?
    var note: String
    var legacySourceKey: String?
    var createdAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, eweID: UUID, kind: ReproductionRecordKind, occurredAt: Date, sireID: UUID? = nil, semenID: UUID? = nil, batchID: UUID? = nil, semenNameSnapshot: String? = nil, result: String = "", lambCount: Int = 0, parity: Int? = nil, birthDeadCount: Int? = nil, note: String = "", legacySourceKey: String? = nil) {
        self.id = id
        self.farmID = farmID
        self.eweID = eweID
        self.kindRawValue = kind.rawValue
        self.occurredAt = occurredAt
        self.sireID = sireID
        self.semenID = semenID
        self.batchID = batchID
        self.semenNameSnapshot = semenNameSnapshot
        self.result = result
        self.lambCount = lambCount
        self.parity = parity
        self.birthDeadCount = birthDeadCount
        self.note = note
        self.legacySourceKey = legacySourceKey
        self.createdAt = .now
    }

    var kind: ReproductionRecordKind { ReproductionRecordKind(rawValue: kindRawValue) ?? .breeding }
}

@Model
final class SemenRecord {
    var id: UUID
    var farmID: UUID
    var code: String
    var breed: String
    var source: String
    var batchNumber: String
    var quantityText: String
    var legacySourceKey: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, code: String, breed: String, source: String = "", batchNumber: String = "", quantityText: String = "0", legacySourceKey: String? = nil) {
        self.id = id
        self.farmID = farmID
        self.code = code
        self.breed = breed
        self.source = source
        self.batchNumber = batchNumber
        self.quantityText = quantityText
        self.legacySourceKey = legacySourceKey
        self.createdAt = .now
        self.updatedAt = .now
        self.deletedAt = nil
    }
}

@Model
final class NoteRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID?
    var penID: UUID?
    var text: String
    var occurredAt: Date
    var createdAt: Date
    var deletedAt: Date?
    var revision: Int = 1

    init(id: UUID = UUID(), farmID: UUID, sheepID: UUID? = nil, penID: UUID? = nil, text: String, occurredAt: Date) {
        self.id = id
        self.farmID = farmID
        self.sheepID = sheepID
        self.penID = penID
        self.text = text
        self.occurredAt = occurredAt
        self.createdAt = .now
    }
}

extension Decimal {
    static func stable(_ text: String) -> Decimal? {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    var stableText: String {
        NSDecimalNumber(decimal: self).stringValue
    }
}
