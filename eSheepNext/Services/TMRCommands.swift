import Foundation
import SwiftData

struct TMRFormulaComponentDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let ingredientID: UUID
    let quantityText: String

    init(id: UUID = UUID(), ingredientID: UUID, quantityText: String) {
        self.id = id
        self.ingredientID = ingredientID
        self.quantityText = quantityText
    }
}

struct TMRFormulaDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let expectedRevision: Int
    let name: String
    let stage: FeedRecipeStage
    let quantityBasis: TMRFormulaQuantityBasis
    let referenceHeadCount: Int?
    let defaultScaleMode: TMRFormulaScaleMode
    let morningShareText: String
    let noonShareText: String
    let eveningShareText: String
    let components: [TMRFormulaComponentDraft]
    let note: String

    init(
        id: UUID = UUID(),
        expectedRevision: Int = 0,
        name: String,
        stage: FeedRecipeStage = .custom,
        quantityBasis: TMRFormulaQuantityBasis,
        referenceHeadCount: Int? = nil,
        defaultScaleMode: TMRFormulaScaleMode = .scaledByHeadCount,
        morningShareText: String = "0.4",
        noonShareText: String = "0.35",
        eveningShareText: String = "0.25",
        components: [TMRFormulaComponentDraft],
        note: String = ""
    ) {
        self.id = id
        self.expectedRevision = expectedRevision
        self.name = name
        self.stage = stage
        self.quantityBasis = quantityBasis
        self.referenceHeadCount = referenceHeadCount
        self.defaultScaleMode = defaultScaleMode
        self.morningShareText = morningShareText
        self.noonShareText = noonShareText
        self.eveningShareText = eveningShareText
        self.components = components
        self.note = note
    }
}

struct TMRMonitoringRuleDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let expectedRevision: Int
    let tolerancePercentText: String
    let morningCutoffMinute: Int
    let noonCutoffMinute: Int
    let eveningCutoffMinute: Int
    let allDayCutoffMinute: Int
    let confirmsMonitoring: Bool

    init(
        id: UUID = UUID(),
        expectedRevision: Int = 0,
        tolerancePercentText: String = "5",
        morningCutoffMinute: Int = 9 * 60,
        noonCutoffMinute: Int = 14 * 60,
        eveningCutoffMinute: Int = 20 * 60,
        allDayCutoffMinute: Int = 22 * 60,
        confirmsMonitoring: Bool
    ) {
        self.id = id
        self.expectedRevision = expectedRevision
        self.tolerancePercentText = tolerancePercentText
        self.morningCutoffMinute = morningCutoffMinute
        self.noonCutoffMinute = noonCutoffMinute
        self.eveningCutoffMinute = eveningCutoffMinute
        self.allDayCutoffMinute = allDayCutoffMinute
        self.confirmsMonitoring = confirmsMonitoring
    }
}

struct TMRPlanPenDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let penID: UUID
    let fixedShareText: String?

    init(id: UUID = UUID(), penID: UUID, fixedShareText: String? = nil) {
        self.id = id
        self.penID = penID
        self.fixedShareText = fixedShareText
    }
}

struct TMRFeedingPlanDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let supersedesPlanID: UUID?
    let formulaID: UUID
    let expectedFormulaRevision: Int
    let scheduleKind: TMRPlanScheduleKind
    let effectiveStartDate: Date
    let effectiveEndDate: Date?
    let scaleMode: TMRFormulaScaleMode
    let allocationMode: TMRPenAllocationMode
    let granularity: TMRMonitoringGranularity
    let morningShareText: String
    let noonShareText: String
    let eveningShareText: String
    let tolerancePercentText: String
    let morningCutoffMinute: Int
    let noonCutoffMinute: Int
    let eveningCutoffMinute: Int
    let allDayCutoffMinute: Int
    let monitoringEnabled: Bool
    let pens: [TMRPlanPenDraft]
    let note: String

    init(
        id: UUID = UUID(),
        supersedesPlanID: UUID? = nil,
        formulaID: UUID,
        expectedFormulaRevision: Int,
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
        pens: [TMRPlanPenDraft],
        note: String = ""
    ) {
        self.id = id
        self.supersedesPlanID = supersedesPlanID
        self.formulaID = formulaID
        self.expectedFormulaRevision = expectedFormulaRevision
        self.scheduleKind = scheduleKind
        self.effectiveStartDate = effectiveStartDate
        self.effectiveEndDate = effectiveEndDate
        self.scaleMode = scaleMode
        self.allocationMode = allocationMode
        self.granularity = granularity
        self.morningShareText = morningShareText
        self.noonShareText = noonShareText
        self.eveningShareText = eveningShareText
        self.tolerancePercentText = tolerancePercentText
        self.morningCutoffMinute = morningCutoffMinute
        self.noonCutoffMinute = noonCutoffMinute
        self.eveningCutoffMinute = eveningCutoffMinute
        self.allDayCutoffMinute = allDayCutoffMinute
        self.monitoringEnabled = monitoringEnabled
        self.pens = pens
        self.note = note
    }
}

struct TMRBatchLoadDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let ingredientBatchID: UUID
    let actualKilogramsText: String

    init(id: UUID = UUID(), ingredientBatchID: UUID, actualKilogramsText: String) {
        self.id = id
        self.ingredientBatchID = ingredientBatchID
        self.actualKilogramsText = actualKilogramsText
    }
}

struct TMRBatchIngredientDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let ingredientID: UUID
    let plannedKilogramsText: String
    let loadLines: [TMRBatchLoadDraft]

    init(
        id: UUID = UUID(),
        ingredientID: UUID,
        plannedKilogramsText: String,
        loadLines: [TMRBatchLoadDraft]
    ) {
        self.id = id
        self.ingredientID = ingredientID
        self.plannedKilogramsText = plannedKilogramsText
        self.loadLines = loadLines
    }
}

struct TMRBatchProductionDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let formulaID: UUID
    let expectedFormulaRevision: Int
    let sourcePlanID: UUID?
    let sourcePlanRevision: Int?
    let sourcePlanDate: Date?
    let sourceMeals: [TMRMealPeriod]?
    let batchCode: String?
    let producedAt: Date
    let ingredients: [TMRBatchIngredientDraft]
    let note: String

    init(
        id: UUID = UUID(),
        formulaID: UUID,
        expectedFormulaRevision: Int,
        sourcePlanID: UUID? = nil,
        sourcePlanRevision: Int? = nil,
        sourcePlanDate: Date? = nil,
        sourceMeals: [TMRMealPeriod]? = nil,
        batchCode: String? = nil,
        producedAt: Date,
        ingredients: [TMRBatchIngredientDraft],
        note: String = ""
    ) {
        self.id = id
        self.formulaID = formulaID
        self.expectedFormulaRevision = expectedFormulaRevision
        self.sourcePlanID = sourcePlanID
        self.sourcePlanRevision = sourcePlanRevision
        self.sourcePlanDate = sourcePlanDate
        self.sourceMeals = sourceMeals
        self.batchCode = batchCode
        self.producedAt = producedAt
        self.ingredients = ingredients
        self.note = note
    }
}

struct TMRFeedingAllocationDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let feedRecordID: UUID
    let penID: UUID
    let planID: UUID?
    let planRevision: Int?
    let actualHeadCountSnapshot: Int
    let actualKilogramsText: String
    let targetKilogramsTextSnapshot: String?

    init(
        id: UUID = UUID(),
        feedRecordID: UUID = UUID(),
        penID: UUID,
        planID: UUID? = nil,
        planRevision: Int? = nil,
        actualHeadCountSnapshot: Int,
        actualKilogramsText: String,
        targetKilogramsTextSnapshot: String? = nil
    ) {
        self.id = id
        self.feedRecordID = feedRecordID
        self.penID = penID
        self.planID = planID
        self.planRevision = planRevision
        self.actualHeadCountSnapshot = actualHeadCountSnapshot
        self.actualKilogramsText = actualKilogramsText
        self.targetKilogramsTextSnapshot = targetKilogramsTextSnapshot
    }
}

struct TMRFeedingRunDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let batchID: UUID
    let expectedBatchRevision: Int
    let occurredAt: Date
    let meal: TMRMealPeriod
    let allocations: [TMRFeedingAllocationDraft]
    let reopenCompletions: [TMRMealReopenDraft]?
    let note: String

    init(
        id: UUID = UUID(),
        batchID: UUID,
        expectedBatchRevision: Int,
        occurredAt: Date,
        meal: TMRMealPeriod,
        allocations: [TMRFeedingAllocationDraft],
        reopenCompletions: [TMRMealReopenDraft]? = nil,
        note: String = ""
    ) {
        self.id = id
        self.batchID = batchID
        self.expectedBatchRevision = expectedBatchRevision
        self.occurredAt = occurredAt
        self.meal = meal
        self.allocations = allocations
        self.reopenCompletions = reopenCompletions
        self.note = note
    }
}

struct TMRFeedingCorrectionDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let originalRunID: UUID
    let batchID: UUID
    let expectedBatchRevision: Int
    let occurredAt: Date
    let meal: TMRMealPeriod
    let allocations: [TMRFeedingAllocationDraft]
    let reason: String
    let note: String

    init(
        id: UUID = UUID(),
        originalRunID: UUID,
        batchID: UUID,
        expectedBatchRevision: Int,
        occurredAt: Date,
        meal: TMRMealPeriod,
        allocations: [TMRFeedingAllocationDraft],
        reason: String,
        note: String = ""
    ) {
        self.id = id
        self.originalRunID = originalRunID
        self.batchID = batchID
        self.expectedBatchRevision = expectedBatchRevision
        self.occurredAt = occurredAt
        self.meal = meal
        self.allocations = allocations
        self.reason = reason
        self.note = note
    }
}

struct TMRFeedingReversalDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let runID: UUID
    let batchID: UUID
    let expectedBatchRevision: Int
    let reason: String

    init(
        id: UUID = UUID(),
        runID: UUID,
        batchID: UUID,
        expectedBatchRevision: Int,
        reason: String
    ) {
        self.id = id
        self.runID = runID
        self.batchID = batchID
        self.expectedBatchRevision = expectedBatchRevision
        self.reason = reason
    }
}

struct TMRMealCompletionDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let planID: UUID
    let expectedPlanRevision: Int
    let penID: UUID
    let localDay: Date
    let meal: TMRMealPeriod
    let completedAt: Date
    let note: String

    init(
        id: UUID = UUID(),
        planID: UUID,
        expectedPlanRevision: Int,
        penID: UUID,
        localDay: Date,
        meal: TMRMealPeriod,
        completedAt: Date = .now,
        note: String = ""
    ) {
        self.id = id
        self.planID = planID
        self.expectedPlanRevision = expectedPlanRevision
        self.penID = penID
        self.localDay = localDay
        self.meal = meal
        self.completedAt = completedAt
        self.note = note
    }
}

struct TMRMealReopenDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let completionID: UUID
    let reason: String

    init(id: UUID = UUID(), completionID: UUID, reason: String) {
        self.id = id
        self.completionID = completionID
        self.reason = reason
    }
}

struct TMRBatchAdjustmentDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let batchID: UUID
    let expectedBatchRevision: Int
    let deltaKilogramsText: String
    let occurredAt: Date
    let reason: String

    init(
        id: UUID = UUID(),
        batchID: UUID,
        expectedBatchRevision: Int,
        deltaKilogramsText: String,
        occurredAt: Date = .now,
        reason: String
    ) {
        self.id = id
        self.batchID = batchID
        self.expectedBatchRevision = expectedBatchRevision
        self.deltaKilogramsText = deltaKilogramsText
        self.occurredAt = occurredAt
        self.reason = reason
    }
}

struct TMRBatchCloseDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let batchID: UUID
    let expectedBatchRevision: Int
    let wasteRemaining: Bool
    let closedAt: Date
    let reason: String

    init(
        id: UUID = UUID(),
        batchID: UUID,
        expectedBatchRevision: Int,
        wasteRemaining: Bool,
        closedAt: Date = .now,
        reason: String
    ) {
        self.id = id
        self.batchID = batchID
        self.expectedBatchRevision = expectedBatchRevision
        self.wasteRemaining = wasteRemaining
        self.closedAt = closedAt
        self.reason = reason
    }
}

struct TMRBatchDeletionDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let batchID: UUID
    let expectedBatchRevision: Int
    let deletedAt: Date
    let reason: String

    init(
        id: UUID = UUID(),
        batchID: UUID,
        expectedBatchRevision: Int,
        deletedAt: Date = .now,
        reason: String
    ) {
        self.id = id
        self.batchID = batchID
        self.expectedBatchRevision = expectedBatchRevision
        self.deletedAt = deletedAt
        self.reason = reason
    }
}

struct TMRDeviationAcknowledgementDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let planID: UUID
    let planRevision: Int
    let penID: UUID
    let localDay: Date
    let meal: TMRMealPeriod
    let fingerprint: String
    let note: String
    let acknowledgedAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID,
        planRevision: Int,
        penID: UUID,
        localDay: Date,
        meal: TMRMealPeriod,
        fingerprint: String,
        note: String,
        acknowledgedAt: Date = .now
    ) {
        self.id = id
        self.planID = planID
        self.planRevision = planRevision
        self.penID = penID
        self.localDay = localDay
        self.meal = meal
        self.fingerprint = fingerprint
        self.note = note
        self.acknowledgedAt = acknowledgedAt
    }
}

enum TMRCommand: Codable, Hashable, Sendable {
    case saveFormula(TMRFormulaDraft)
    case saveMonitoringRule(TMRMonitoringRuleDraft)
    case saveFeedingPlan(TMRFeedingPlanDraft)
    case produceBatch(TMRBatchProductionDraft)
    case recordFeeding(TMRFeedingRunDraft)
    case correctFeedingRun(TMRFeedingCorrectionDraft)
    case reverseFeedingRun(TMRFeedingReversalDraft)
    case completeMeal(TMRMealCompletionDraft)
    case reopenMeal(TMRMealReopenDraft)
    case adjustBatch(TMRBatchAdjustmentDraft)
    case closeBatch(TMRBatchCloseDraft)
    case deleteUnusedBatch(TMRBatchDeletionDraft)
    case acknowledgeDeviation(TMRDeviationAcknowledgementDraft)

    var requiredCapability: FarmCapability {
        switch self {
        case .saveFormula, .saveMonitoringRule, .saveFeedingPlan, .adjustBatch, .closeBatch:
            .manageCatalogs
        case .correctFeedingRun, .reverseFeedingRun, .reopenMeal:
            .editHistoricalFacts
        case .deleteUnusedBatch:
            .deleteProtectedFacts
        case .produceBatch, .recordFeeding, .completeMeal, .acknowledgeDeviation:
            .recordProduction
        }
    }

    var operationKind: DomainOperationKind {
        switch self {
        case .saveFormula: .saveTMRFormula
        case .saveMonitoringRule: .saveTMRMonitoringRule
        case .saveFeedingPlan: .saveTMRFeedingPlan
        case .produceBatch: .produceTMRBatch
        case .recordFeeding: .recordTMRFeeding
        case .correctFeedingRun: .correctTMRFeedingRun
        case .reverseFeedingRun: .reverseTMRFeedingRun
        case .completeMeal: .completeTMRMeal
        case .reopenMeal: .reopenTMRMeal
        case .adjustBatch: .adjustTMRBatch
        case .closeBatch: .closeTMRBatch
        case .deleteUnusedBatch: .deleteUnusedTMRBatch
        case .acknowledgeDeviation: .acknowledgeTMRDeviation
        }
    }

    var summary: String {
        switch self {
        case .saveFormula(let draft): "保存 TMR 配方：\(draft.name)"
        case .saveMonitoringRule: "保存 TMR 监控设置"
        case .saveFeedingPlan: "保存 TMR 投喂计划"
        case .produceBatch: "制作一锅 TMR"
        case .recordFeeding: "记录 TMR 投喂"
        case .correctFeedingRun: "修正 TMR 投喂"
        case .reverseFeedingRun: "删除 TMR 投喂并冲回成品余额"
        case .completeMeal: "完成 TMR 顿次"
        case .reopenMeal: "重新打开 TMR 顿次"
        case .adjustBatch: "调整 TMR 批次余额"
        case .closeBatch: "结清 TMR 批次"
        case .deleteUnusedBatch: "删除未使用的 TMR 批次"
        case .acknowledgeDeviation: "确认 TMR 投喂偏差"
        }
    }
}

extension FarmCommandService {
    func saveTMRFormula(_ draft: TMRFormulaDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.saveFormula(draft)), in: farm, context: context)
    }

    func saveTMRMonitoringRule(_ draft: TMRMonitoringRuleDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.saveMonitoringRule(draft)), in: farm, context: context)
    }

    func saveTMRFeedingPlan(_ draft: TMRFeedingPlanDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.saveFeedingPlan(draft)), in: farm, context: context)
    }

    func produceTMRBatch(_ draft: TMRBatchProductionDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.produceBatch(draft)), in: farm, context: context)
    }

    func recordTMRFeeding(_ draft: TMRFeedingRunDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.recordFeeding(draft)), in: farm, context: context)
    }

    func correctTMRFeedingRun(_ draft: TMRFeedingCorrectionDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.correctFeedingRun(draft)), in: farm, context: context)
    }

    func reverseTMRFeedingRun(_ draft: TMRFeedingReversalDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.reverseFeedingRun(draft)), in: farm, context: context)
    }

    func completeTMRMeal(_ draft: TMRMealCompletionDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.completeMeal(draft)), in: farm, context: context)
    }

    func reopenTMRMeal(_ draft: TMRMealReopenDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.reopenMeal(draft)), in: farm, context: context)
    }

    func adjustTMRBatch(_ draft: TMRBatchAdjustmentDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.adjustBatch(draft)), in: farm, context: context)
    }

    func closeTMRBatch(_ draft: TMRBatchCloseDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.closeBatch(draft)), in: farm, context: context)
    }

    func deleteUnusedTMRBatch(_ draft: TMRBatchDeletionDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.deleteUnusedBatch(draft)), in: farm, context: context)
    }

    func acknowledgeTMRDeviation(_ draft: TMRDeviationAcknowledgementDraft, in farm: FarmContext, context: ModelContext) throws {
        try execute(.tmr(.acknowledgeDeviation(draft)), in: farm, context: context)
    }
}
