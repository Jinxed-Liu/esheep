import Foundation
import SwiftData

enum TMRFormulaQuantityBasis: String, Codable, CaseIterable, Sendable, Hashable {
    case wholeGroupDaily
    case perHeadDaily

    var displayName: String {
        switch self {
        case .wholeGroupDaily: "整群每日量"
        case .perHeadDaily: "每只每日量"
        }
    }
}

enum TMRFormulaScaleMode: String, Codable, CaseIterable, Sendable, Hashable {
    case scaledByHeadCount
    case fixedWholeAmount

    var displayName: String {
        switch self {
        case .scaledByHeadCount: "按羊数缩放"
        case .fixedWholeAmount: "固定配方总量"
        }
    }
}

enum TMRMealPeriod: String, Codable, CaseIterable, Sendable, Hashable {
    case morning
    case noon
    case evening
    case allDaySummary

    static let actualMeals: [TMRMealPeriod] = [.morning, .noon, .evening]

    var displayName: String {
        switch self {
        case .morning: "早"
        case .noon: "中"
        case .evening: "晚"
        case .allDaySummary: "全天汇总"
        }
    }

    var sortOrder: Int {
        switch self {
        case .morning: 0
        case .noon: 1
        case .evening: 2
        case .allDaySummary: 3
        }
    }
}

enum TMRPlanScheduleKind: String, Codable, CaseIterable, Sendable, Hashable {
    case oneTime
    case continuous

    var displayName: String {
        switch self {
        case .oneTime: "仅本次"
        case .continuous: "持续计划"
        }
    }
}

enum TMRMonitoringGranularity: String, Codable, CaseIterable, Sendable, Hashable {
    case perMeal
    case dailySummary

    var displayName: String {
        switch self {
        case .perMeal: "分顿监控"
        case .dailySummary: "全天汇总"
        }
    }
}

enum TMRPenAllocationMode: String, Codable, CaseIterable, Sendable, Hashable {
    case dynamicHeadCount
    case fixedShare

    var displayName: String {
        switch self {
        case .dynamicHeadCount: "按有效羊数动态分配"
        case .fixedShare: "固定分配比例"
        }
    }
}

enum TMRBatchStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case available
    case exhausted
    case closed

    var displayName: String {
        switch self {
        case .available: "可用"
        case .exhausted: "已用完"
        case .closed: "已结清"
        }
    }
}

enum TMRBatchMovementKind: String, Codable, CaseIterable, Sendable, Hashable {
    case production
    case feeding
    case waste
    case adjustment
    case reversal

    var displayName: String {
        switch self {
        case .production: "生产入账"
        case .feeding: "投喂出账"
        case .waste: "报废"
        case .adjustment: "调整"
        case .reversal: "冲回"
        }
    }
}

enum TMRDeviationStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case inProgress
    case notFed
    case normal
    case low
    case high
    case unplanned

    var displayName: String {
        switch self {
        case .inProgress: "进行中"
        case .notFed: "未投喂"
        case .normal: "正常"
        case .low: "偏低"
        case .high: "偏高"
        case .unplanned: "计划外投喂"
        }
    }
}

struct TMRFormulaComponentSnapshot: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let ingredientID: UUID
    let ingredientName: String
    let quantityText: String
    let unit: String
    let pricePerKilogramText: String?
    let nutrientSnapshotJSON: String
    let dryMatterText: String?

    init(
        id: UUID = UUID(),
        ingredientID: UUID,
        ingredientName: String,
        quantityText: String,
        unit: String = "千克",
        pricePerKilogramText: String? = nil,
        nutrientSnapshotJSON: String = "{}",
        dryMatterText: String? = nil
    ) {
        self.id = id
        self.ingredientID = ingredientID
        self.ingredientName = ingredientName
        self.quantityText = quantityText
        self.unit = unit
        self.pricePerKilogramText = pricePerKilogramText
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
        self.dryMatterText = dryMatterText
    }

    var quantity: Decimal { Decimal.stable(quantityText) ?? 0 }
}

enum TMRFormulaSnapshotCodec {
    static func encode(_ components: [TMRFormulaComponentSnapshot]) -> String {
        guard let data = try? JSONEncoder().encode(components),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decode(_ text: String) -> [TMRFormulaComponentSnapshot] {
        guard let data = text.data(using: .utf8),
              let components = try? JSONDecoder().decode([TMRFormulaComponentSnapshot].self, from: data) else {
            return []
        }
        return components
    }
}

@Model
final class TMRFormulaProfileRecord {
    var id: UUID
    var farmID: UUID
    var recipeID: UUID
    var quantityBasisRawValue: String
    var referenceHeadCount: Int?
    var defaultScaleModeRawValue: String
    var morningShareText: String
    var noonShareText: String
    var eveningShareText: String
    var formulaRevision: Int
    var needsReview: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        recipeID: UUID,
        quantityBasis: TMRFormulaQuantityBasis,
        referenceHeadCount: Int? = nil,
        defaultScaleMode: TMRFormulaScaleMode = .scaledByHeadCount,
        morningShareText: String = "0.4",
        noonShareText: String = "0.35",
        eveningShareText: String = "0.25",
        formulaRevision: Int = 1,
        needsReview: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.recipeID = recipeID
        self.quantityBasisRawValue = quantityBasis.rawValue
        self.referenceHeadCount = referenceHeadCount
        self.defaultScaleModeRawValue = defaultScaleMode.rawValue
        self.morningShareText = morningShareText
        self.noonShareText = noonShareText
        self.eveningShareText = eveningShareText
        self.formulaRevision = formulaRevision
        self.needsReview = needsReview
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
    }

    var quantityBasis: TMRFormulaQuantityBasis {
        TMRFormulaQuantityBasis(rawValue: quantityBasisRawValue) ?? .wholeGroupDaily
    }

    var defaultScaleMode: TMRFormulaScaleMode {
        TMRFormulaScaleMode(rawValue: defaultScaleModeRawValue) ?? .scaledByHeadCount
    }

    func share(for meal: TMRMealPeriod) -> Decimal {
        switch meal {
        case .morning: Decimal.stable(morningShareText) ?? 0
        case .noon: Decimal.stable(noonShareText) ?? 0
        case .evening: Decimal.stable(eveningShareText) ?? 0
        case .allDaySummary: 1
        }
    }
}

@Model
final class TMRFeedingPlanRecord {
    var id: UUID
    var farmID: UUID
    var formulaID: UUID
    var formulaRevision: Int
    var formulaNameSnapshot: String
    var quantityBasisRawValue: String
    var referenceHeadCountSnapshot: Int?
    var formulaDailyTotalKilogramsText: String
    var componentSnapshotJSON: String
    var scheduleKindRawValue: String
    var effectiveStartDate: Date
    var effectiveEndDate: Date?
    var scaleModeRawValue: String
    var allocationModeRawValue: String
    var granularityRawValue: String
    var morningShareText: String
    var noonShareText: String
    var eveningShareText: String
    var tolerancePercentText: String
    var morningCutoffMinute: Int
    var noonCutoffMinute: Int
    var eveningCutoffMinute: Int
    var allDayCutoffMinute: Int
    var monitoringEnabled: Bool
    var note: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        formulaID: UUID,
        formulaRevision: Int,
        formulaNameSnapshot: String,
        quantityBasis: TMRFormulaQuantityBasis,
        referenceHeadCountSnapshot: Int?,
        formulaDailyTotalKilogramsText: String,
        componentSnapshotJSON: String,
        scheduleKind: TMRPlanScheduleKind,
        effectiveStartDate: Date,
        effectiveEndDate: Date? = nil,
        scaleMode: TMRFormulaScaleMode,
        allocationMode: TMRPenAllocationMode,
        granularity: TMRMonitoringGranularity,
        morningShareText: String,
        noonShareText: String,
        eveningShareText: String,
        tolerancePercentText: String,
        morningCutoffMinute: Int,
        noonCutoffMinute: Int,
        eveningCutoffMinute: Int,
        allDayCutoffMinute: Int,
        monitoringEnabled: Bool,
        note: String = "",
        revision: Int = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.formulaID = formulaID
        self.formulaRevision = formulaRevision
        self.formulaNameSnapshot = formulaNameSnapshot
        self.quantityBasisRawValue = quantityBasis.rawValue
        self.referenceHeadCountSnapshot = referenceHeadCountSnapshot
        self.formulaDailyTotalKilogramsText = formulaDailyTotalKilogramsText
        self.componentSnapshotJSON = componentSnapshotJSON
        self.scheduleKindRawValue = scheduleKind.rawValue
        self.effectiveStartDate = effectiveStartDate
        self.effectiveEndDate = effectiveEndDate
        self.scaleModeRawValue = scaleMode.rawValue
        self.allocationModeRawValue = allocationMode.rawValue
        self.granularityRawValue = granularity.rawValue
        self.morningShareText = morningShareText
        self.noonShareText = noonShareText
        self.eveningShareText = eveningShareText
        self.tolerancePercentText = tolerancePercentText
        self.morningCutoffMinute = morningCutoffMinute
        self.noonCutoffMinute = noonCutoffMinute
        self.eveningCutoffMinute = eveningCutoffMinute
        self.allDayCutoffMinute = allDayCutoffMinute
        self.monitoringEnabled = monitoringEnabled
        self.note = note
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
    }

    var quantityBasis: TMRFormulaQuantityBasis {
        TMRFormulaQuantityBasis(rawValue: quantityBasisRawValue) ?? .wholeGroupDaily
    }

    var scheduleKind: TMRPlanScheduleKind {
        TMRPlanScheduleKind(rawValue: scheduleKindRawValue) ?? .continuous
    }

    var scaleMode: TMRFormulaScaleMode {
        TMRFormulaScaleMode(rawValue: scaleModeRawValue) ?? .scaledByHeadCount
    }

    var allocationMode: TMRPenAllocationMode {
        TMRPenAllocationMode(rawValue: allocationModeRawValue) ?? .dynamicHeadCount
    }

    var granularity: TMRMonitoringGranularity {
        TMRMonitoringGranularity(rawValue: granularityRawValue) ?? .perMeal
    }

    var formulaDailyTotalKilograms: Decimal {
        Decimal.stable(formulaDailyTotalKilogramsText) ?? 0
    }

    var tolerancePercent: Decimal { Decimal.stable(tolerancePercentText) ?? 0 }
    var componentSnapshot: [TMRFormulaComponentSnapshot] {
        TMRFormulaSnapshotCodec.decode(componentSnapshotJSON)
    }

    func share(for meal: TMRMealPeriod) -> Decimal {
        switch meal {
        case .morning: Decimal.stable(morningShareText) ?? 0
        case .noon: Decimal.stable(noonShareText) ?? 0
        case .evening: Decimal.stable(eveningShareText) ?? 0
        case .allDaySummary: 1
        }
    }

    func cutoffMinute(for meal: TMRMealPeriod) -> Int {
        switch meal {
        case .morning: morningCutoffMinute
        case .noon: noonCutoffMinute
        case .evening: eveningCutoffMinute
        case .allDaySummary: allDayCutoffMinute
        }
    }
}

@Model
final class TMRFeedingPlanPenRecord {
    var id: UUID
    var farmID: UUID
    var planID: UUID
    var penID: UUID
    var penNameSnapshot: String
    var fixedShareText: String?
    var sortOrder: Int
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        planID: UUID,
        penID: UUID,
        penNameSnapshot: String,
        fixedShareText: String? = nil,
        sortOrder: Int = 0,
        revision: Int = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.planID = planID
        self.penID = penID
        self.penNameSnapshot = penNameSnapshot
        self.fixedShareText = fixedShareText
        self.sortOrder = sortOrder
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
    }

    var fixedShare: Decimal? { fixedShareText.flatMap(Decimal.stable) }
}

@Model
final class TMRBatchRecord {
    var id: UUID
    var farmID: UUID
    var batchCode: String
    var formulaID: UUID
    var formulaRevision: Int
    var formulaNameSnapshot: String
    var quantityBasisRawValue: String
    var referenceHeadCountSnapshot: Int?
    var componentSnapshotJSON: String
    var sourcePlanID: UUID?
    var sourcePlanRevision: Int?
    var sourcePlanDate: Date?
    var sourcePlanMealsJSON: String?
    var producedAt: Date
    var producedKilogramsText: String
    var statusRawValue: String
    var note: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        batchCode: String,
        formulaID: UUID,
        formulaRevision: Int,
        formulaNameSnapshot: String,
        quantityBasis: TMRFormulaQuantityBasis,
        referenceHeadCountSnapshot: Int?,
        componentSnapshotJSON: String,
        sourcePlanID: UUID? = nil,
        sourcePlanRevision: Int? = nil,
        sourcePlanDate: Date? = nil,
        sourcePlanMealsJSON: String? = nil,
        producedAt: Date,
        producedKilogramsText: String,
        status: TMRBatchStatus = .available,
        note: String = "",
        revision: Int = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.batchCode = batchCode
        self.formulaID = formulaID
        self.formulaRevision = formulaRevision
        self.formulaNameSnapshot = formulaNameSnapshot
        self.quantityBasisRawValue = quantityBasis.rawValue
        self.referenceHeadCountSnapshot = referenceHeadCountSnapshot
        self.componentSnapshotJSON = componentSnapshotJSON
        self.sourcePlanID = sourcePlanID
        self.sourcePlanRevision = sourcePlanRevision
        self.sourcePlanDate = sourcePlanDate
        self.sourcePlanMealsJSON = sourcePlanMealsJSON
        self.producedAt = producedAt
        self.producedKilogramsText = producedKilogramsText
        self.statusRawValue = status.rawValue
        self.note = note
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.closedAt = nil
        self.deletedAt = nil
    }

    var status: TMRBatchStatus { TMRBatchStatus(rawValue: statusRawValue) ?? .available }
    var producedKilograms: Decimal { Decimal.stable(producedKilogramsText) ?? 0 }
    var componentSnapshot: [TMRFormulaComponentSnapshot] {
        TMRFormulaSnapshotCodec.decode(componentSnapshotJSON)
    }
    var sourcePlanMeals: [TMRMealPeriod] {
        guard let sourcePlanMealsJSON,
              let data = sourcePlanMealsJSON.data(using: .utf8),
              let rawValues = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return rawValues.compactMap(TMRMealPeriod.init(rawValue:))
    }
}

@Model
final class TMRBatchIngredientRecord {
    var id: UUID
    var farmID: UUID
    var batchID: UUID
    var ingredientID: UUID
    var ingredientNameSnapshot: String
    var plannedKilogramsText: String
    var actualKilogramsText: String
    var unitSnapshot: String
    var pricePerKilogramTextSnapshot: String?
    var nutrientSnapshotJSON: String
    var dryMatterTextSnapshot: String?
    var sortOrder: Int
    var createdAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        batchID: UUID,
        ingredientID: UUID,
        ingredientNameSnapshot: String,
        plannedKilogramsText: String,
        actualKilogramsText: String,
        unitSnapshot: String = "千克",
        pricePerKilogramTextSnapshot: String? = nil,
        nutrientSnapshotJSON: String = "{}",
        dryMatterTextSnapshot: String? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.batchID = batchID
        self.ingredientID = ingredientID
        self.ingredientNameSnapshot = ingredientNameSnapshot
        self.plannedKilogramsText = plannedKilogramsText
        self.actualKilogramsText = actualKilogramsText
        self.unitSnapshot = unitSnapshot
        self.pricePerKilogramTextSnapshot = pricePerKilogramTextSnapshot
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
        self.dryMatterTextSnapshot = dryMatterTextSnapshot
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.deletedAt = nil
    }

    var plannedKilograms: Decimal { Decimal.stable(plannedKilogramsText) ?? 0 }
    var actualKilograms: Decimal { Decimal.stable(actualKilogramsText) ?? 0 }
}

@Model
final class TMRBatchLoadLineRecord {
    var id: UUID
    var farmID: UUID
    var batchID: UUID
    var batchIngredientID: UUID
    var ingredientID: UUID
    var ingredientBatchID: UUID
    var ingredientBatchNameSnapshot: String
    var actualKilogramsText: String
    var sortOrder: Int
    var createdAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        batchID: UUID,
        batchIngredientID: UUID,
        ingredientID: UUID,
        ingredientBatchID: UUID,
        ingredientBatchNameSnapshot: String,
        actualKilogramsText: String,
        sortOrder: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.batchID = batchID
        self.batchIngredientID = batchIngredientID
        self.ingredientID = ingredientID
        self.ingredientBatchID = ingredientBatchID
        self.ingredientBatchNameSnapshot = ingredientBatchNameSnapshot
        self.actualKilogramsText = actualKilogramsText
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.deletedAt = nil
    }

    var actualKilograms: Decimal { Decimal.stable(actualKilogramsText) ?? 0 }
}

@Model
final class TMRBatchMovementRecord {
    var id: UUID
    var farmID: UUID
    var batchID: UUID
    var kindRawValue: String
    var deltaKilogramsText: String
    var occurredAt: Date
    var sourceRecordID: UUID?
    var sourceMovementID: UUID?
    var note: String
    var createdAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        batchID: UUID,
        kind: TMRBatchMovementKind,
        deltaKilogramsText: String,
        occurredAt: Date,
        sourceRecordID: UUID? = nil,
        sourceMovementID: UUID? = nil,
        note: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.batchID = batchID
        self.kindRawValue = kind.rawValue
        self.deltaKilogramsText = deltaKilogramsText
        self.occurredAt = occurredAt
        self.sourceRecordID = sourceRecordID
        self.sourceMovementID = sourceMovementID
        self.note = note
        self.createdAt = createdAt
        self.deletedAt = nil
    }

    var kind: TMRBatchMovementKind {
        TMRBatchMovementKind(rawValue: kindRawValue) ?? .adjustment
    }
    var deltaKilograms: Decimal { Decimal.stable(deltaKilogramsText) ?? 0 }
}

@Model
final class TMRFeedingRunRecord {
    var id: UUID
    var farmID: UUID
    var batchID: UUID
    var batchCodeSnapshot: String
    var formulaID: UUID
    var formulaRevision: Int
    var formulaNameSnapshot: String
    var mealRawValue: String
    var occurredAt: Date
    var note: String
    var batchRevisionBefore: Int
    var batchRevisionAfter: Int
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        batchID: UUID,
        batchCodeSnapshot: String,
        formulaID: UUID,
        formulaRevision: Int,
        formulaNameSnapshot: String,
        meal: TMRMealPeriod,
        occurredAt: Date,
        note: String = "",
        batchRevisionBefore: Int,
        batchRevisionAfter: Int,
        revision: Int = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.batchID = batchID
        self.batchCodeSnapshot = batchCodeSnapshot
        self.formulaID = formulaID
        self.formulaRevision = formulaRevision
        self.formulaNameSnapshot = formulaNameSnapshot
        self.mealRawValue = meal.rawValue
        self.occurredAt = occurredAt
        self.note = note
        self.batchRevisionBefore = batchRevisionBefore
        self.batchRevisionAfter = batchRevisionAfter
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
    }

    var meal: TMRMealPeriod { TMRMealPeriod(rawValue: mealRawValue) ?? .morning }
}

@Model
final class TMRFeedingAllocationRecord {
    var id: UUID
    var farmID: UUID
    var runID: UUID
    var batchID: UUID
    var feedRecordID: UUID
    var planID: UUID?
    var planRevision: Int?
    var penID: UUID
    var penNameSnapshot: String
    var actualHeadCountSnapshot: Int
    var actualKilogramsText: String
    var targetKilogramsTextSnapshot: String?
    var createdAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        runID: UUID,
        batchID: UUID,
        feedRecordID: UUID,
        planID: UUID? = nil,
        planRevision: Int? = nil,
        penID: UUID,
        penNameSnapshot: String,
        actualHeadCountSnapshot: Int,
        actualKilogramsText: String,
        targetKilogramsTextSnapshot: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.runID = runID
        self.batchID = batchID
        self.feedRecordID = feedRecordID
        self.planID = planID
        self.planRevision = planRevision
        self.penID = penID
        self.penNameSnapshot = penNameSnapshot
        self.actualHeadCountSnapshot = actualHeadCountSnapshot
        self.actualKilogramsText = actualKilogramsText
        self.targetKilogramsTextSnapshot = targetKilogramsTextSnapshot
        self.createdAt = createdAt
        self.deletedAt = nil
    }

    var actualKilograms: Decimal { Decimal.stable(actualKilogramsText) ?? 0 }
    var targetKilogramsSnapshot: Decimal? {
        targetKilogramsTextSnapshot.flatMap(Decimal.stable)
    }
}

@Model
final class TMRMealCompletionRecord {
    var id: UUID
    var farmID: UUID
    var planID: UUID
    var planRevision: Int
    var penID: UUID
    var localDay: Date
    var mealRawValue: String
    var completedAt: Date
    var note: String
    var revision: Int
    var createdAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        planID: UUID,
        planRevision: Int,
        penID: UUID,
        localDay: Date,
        meal: TMRMealPeriod,
        completedAt: Date = .now,
        note: String = "",
        revision: Int = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.planID = planID
        self.planRevision = planRevision
        self.penID = penID
        self.localDay = localDay
        self.mealRawValue = meal.rawValue
        self.completedAt = completedAt
        self.note = note
        self.revision = revision
        self.createdAt = createdAt
        self.deletedAt = nil
    }

    var meal: TMRMealPeriod { TMRMealPeriod(rawValue: mealRawValue) ?? .morning }
}

@Model
final class TMRDeviationAcknowledgementRecord {
    var id: UUID
    var farmID: UUID
    var planID: UUID
    var planRevision: Int
    var penID: UUID
    var localDay: Date
    var mealRawValue: String
    var fingerprint: String
    var note: String
    var acknowledgedAt: Date
    var acknowledgedByAccountID: String
    var revision: Int
    var createdAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        planID: UUID,
        planRevision: Int,
        penID: UUID,
        localDay: Date,
        meal: TMRMealPeriod,
        fingerprint: String,
        note: String,
        acknowledgedAt: Date = .now,
        acknowledgedByAccountID: String,
        revision: Int = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.planID = planID
        self.planRevision = planRevision
        self.penID = penID
        self.localDay = localDay
        self.mealRawValue = meal.rawValue
        self.fingerprint = fingerprint
        self.note = note
        self.acknowledgedAt = acknowledgedAt
        self.acknowledgedByAccountID = acknowledgedByAccountID
        self.revision = revision
        self.createdAt = createdAt
        self.deletedAt = nil
    }

    var meal: TMRMealPeriod { TMRMealPeriod(rawValue: mealRawValue) ?? .morning }
}

@Model
final class TMRMonitoringRuleRecord {
    var id: UUID
    var farmID: UUID
    var tolerancePercentText: String
    var morningCutoffMinute: Int
    var noonCutoffMinute: Int
    var eveningCutoffMinute: Int
    var allDayCutoffMinute: Int
    var monitoringEnabledAt: Date?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        tolerancePercentText: String = "5",
        morningCutoffMinute: Int = 9 * 60,
        noonCutoffMinute: Int = 14 * 60,
        eveningCutoffMinute: Int = 20 * 60,
        allDayCutoffMinute: Int = 22 * 60,
        monitoringEnabledAt: Date? = nil,
        revision: Int = 1,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.tolerancePercentText = tolerancePercentText
        self.morningCutoffMinute = morningCutoffMinute
        self.noonCutoffMinute = noonCutoffMinute
        self.eveningCutoffMinute = eveningCutoffMinute
        self.allDayCutoffMinute = allDayCutoffMinute
        self.monitoringEnabledAt = monitoringEnabledAt
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
    }

    var tolerancePercent: Decimal { Decimal.stable(tolerancePercentText) ?? 0 }
    var isConfirmed: Bool { monitoringEnabledAt != nil }

    func cutoffMinute(for meal: TMRMealPeriod) -> Int {
        switch meal {
        case .morning: morningCutoffMinute
        case .noon: noonCutoffMinute
        case .evening: eveningCutoffMinute
        case .allDaySummary: allDayCutoffMinute
        }
    }
}
