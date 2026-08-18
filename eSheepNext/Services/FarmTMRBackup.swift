import Foundation
import SwiftData

/// TMR 的完整投影快照。原料、原料库存、配方目录、圈舍及 FeedRecord
/// 由既有投喂备份/云基线负责；这里保存 TMR 自身的关系、成品账和监控事实。
struct FarmTMRBackupPayload: Codable, Sendable, Equatable {
    struct FormulaProfile: Codable, Sendable, Equatable {
        let id: UUID
        let recipeID: UUID
        let quantityBasisRawValue: String
        let referenceHeadCount: Int?
        let defaultScaleModeRawValue: String
        let morningShareText: String
        let noonShareText: String
        let eveningShareText: String
        let formulaRevision: Int
        let needsReview: Bool
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct Plan: Codable, Sendable, Equatable {
        let id: UUID
        let formulaID: UUID
        let formulaRevision: Int
        let formulaNameSnapshot: String
        let quantityBasisRawValue: String
        let referenceHeadCountSnapshot: Int?
        let formulaDailyTotalKilogramsText: String
        let componentSnapshotJSON: String
        let scheduleKindRawValue: String
        let effectiveStartDate: Date
        let effectiveEndDate: Date?
        let scaleModeRawValue: String
        let allocationModeRawValue: String
        let granularityRawValue: String
        let morningShareText: String
        let noonShareText: String
        let eveningShareText: String
        let tolerancePercentText: String
        let morningCutoffMinute: Int
        let noonCutoffMinute: Int
        let eveningCutoffMinute: Int
        let allDayCutoffMinute: Int
        let monitoringEnabled: Bool
        let note: String
        let revision: Int
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct PlanPen: Codable, Sendable, Equatable {
        let id: UUID
        let planID: UUID
        let penID: UUID
        let penNameSnapshot: String
        let fixedShareText: String?
        let sortOrder: Int
        let revision: Int
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct Batch: Codable, Sendable, Equatable {
        let id: UUID
        let batchCode: String
        let formulaID: UUID
        let formulaRevision: Int
        let formulaNameSnapshot: String
        let quantityBasisRawValue: String
        let referenceHeadCountSnapshot: Int?
        let componentSnapshotJSON: String
        let sourcePlanID: UUID?
        let sourcePlanRevision: Int?
        let sourcePlanDate: Date?
        let sourcePlanMealsJSON: String?
        let producedAt: Date
        let producedKilogramsText: String
        let statusRawValue: String
        let note: String
        let revision: Int
        let createdAt: Date
        let updatedAt: Date
        let closedAt: Date?
        let deletedAt: Date?
    }

    struct BatchIngredient: Codable, Sendable, Equatable {
        let id: UUID
        let batchID: UUID
        let ingredientID: UUID
        let ingredientNameSnapshot: String
        let plannedKilogramsText: String
        let actualKilogramsText: String
        let unitSnapshot: String
        let pricePerKilogramTextSnapshot: String?
        let nutrientSnapshotJSON: String
        let dryMatterTextSnapshot: String?
        let sortOrder: Int
        let createdAt: Date
        let deletedAt: Date?
    }

    struct LoadLine: Codable, Sendable, Equatable {
        let id: UUID
        let batchID: UUID
        let batchIngredientID: UUID
        let ingredientID: UUID
        let ingredientBatchID: UUID
        let ingredientBatchNameSnapshot: String
        let actualKilogramsText: String
        let sortOrder: Int
        let createdAt: Date
        let deletedAt: Date?
    }

    struct Movement: Codable, Sendable, Equatable {
        let id: UUID
        let batchID: UUID
        let kindRawValue: String
        let deltaKilogramsText: String
        let occurredAt: Date
        let sourceRecordID: UUID?
        let sourceMovementID: UUID?
        let note: String
        let createdAt: Date
        let deletedAt: Date?
    }

    struct FeedingRun: Codable, Sendable, Equatable {
        let id: UUID
        let batchID: UUID
        let batchCodeSnapshot: String
        let formulaID: UUID
        let formulaRevision: Int
        let formulaNameSnapshot: String
        let mealRawValue: String
        let occurredAt: Date
        let note: String
        let batchRevisionBefore: Int
        let batchRevisionAfter: Int
        let revision: Int
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct FeedingAllocation: Codable, Sendable, Equatable {
        let id: UUID
        let runID: UUID
        let batchID: UUID
        let feedRecordID: UUID
        let planID: UUID?
        let planRevision: Int?
        let penID: UUID
        let penNameSnapshot: String
        let actualHeadCountSnapshot: Int
        let actualKilogramsText: String
        let targetKilogramsTextSnapshot: String?
        let createdAt: Date
        let deletedAt: Date?
    }

    struct MealCompletion: Codable, Sendable, Equatable {
        let id: UUID
        let planID: UUID
        let planRevision: Int
        let penID: UUID
        let localDay: Date
        let mealRawValue: String
        let completedAt: Date
        let note: String
        let revision: Int
        let createdAt: Date
        let deletedAt: Date?
    }

    struct DeviationAcknowledgement: Codable, Sendable, Equatable {
        let id: UUID
        let planID: UUID
        let planRevision: Int
        let penID: UUID
        let localDay: Date
        let mealRawValue: String
        let fingerprint: String
        let note: String
        let acknowledgedAt: Date
        let acknowledgedByAccountID: String
        let revision: Int
        let createdAt: Date
        let deletedAt: Date?
    }

    struct MonitoringRule: Codable, Sendable, Equatable {
        let id: UUID
        let tolerancePercentText: String
        let morningCutoffMinute: Int
        let noonCutoffMinute: Int
        let eveningCutoffMinute: Int
        let allDayCutoffMinute: Int
        let monitoringEnabledAt: Date?
        let revision: Int
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    let formulaProfiles: [FormulaProfile]
    let plans: [Plan]
    let planPens: [PlanPen]
    let batches: [Batch]
    let batchIngredients: [BatchIngredient]
    let loadLines: [LoadLine]
    let movements: [Movement]
    let feedingRuns: [FeedingRun]
    let feedingAllocations: [FeedingAllocation]
    let mealCompletions: [MealCompletion]
    let deviationAcknowledgements: [DeviationAcknowledgement]
    let monitoringRules: [MonitoringRule]

    var entityCount: Int {
        formulaProfiles.count + plans.count + planPens.count + batches.count +
            batchIngredients.count + loadLines.count + movements.count + feedingRuns.count +
            feedingAllocations.count + mealCompletions.count +
            deviationAcknowledgements.count + monitoringRules.count
    }

    var isEmpty: Bool { entityCount == 0 }

    @MainActor
    static func capture(farmID: UUID, context: ModelContext) throws -> Self {
        let profiles = try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let plans = try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let planIDs = Set(plans.map(\.id))
        let batches = try context.fetch(FetchDescriptor<TMRBatchRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let batchIDs = Set(batches.map(\.id))
        let runs = try context.fetch(FetchDescriptor<TMRFeedingRunRecord>())
            .filter { $0.farmID == farmID && batchIDs.contains($0.batchID) && $0.deletedAt == nil }
        let runIDs = Set(runs.map(\.id))

        return .init(
            formulaProfiles: profiles.map {
                .init(id: $0.id, recipeID: $0.recipeID, quantityBasisRawValue: $0.quantityBasisRawValue, referenceHeadCount: $0.referenceHeadCount, defaultScaleModeRawValue: $0.defaultScaleModeRawValue, morningShareText: $0.morningShareText, noonShareText: $0.noonShareText, eveningShareText: $0.eveningShareText, formulaRevision: $0.formulaRevision, needsReview: $0.needsReview, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            },
            plans: plans.map {
                .init(id: $0.id, formulaID: $0.formulaID, formulaRevision: $0.formulaRevision, formulaNameSnapshot: $0.formulaNameSnapshot, quantityBasisRawValue: $0.quantityBasisRawValue, referenceHeadCountSnapshot: $0.referenceHeadCountSnapshot, formulaDailyTotalKilogramsText: $0.formulaDailyTotalKilogramsText, componentSnapshotJSON: $0.componentSnapshotJSON, scheduleKindRawValue: $0.scheduleKindRawValue, effectiveStartDate: $0.effectiveStartDate, effectiveEndDate: $0.effectiveEndDate, scaleModeRawValue: $0.scaleModeRawValue, allocationModeRawValue: $0.allocationModeRawValue, granularityRawValue: $0.granularityRawValue, morningShareText: $0.morningShareText, noonShareText: $0.noonShareText, eveningShareText: $0.eveningShareText, tolerancePercentText: $0.tolerancePercentText, morningCutoffMinute: $0.morningCutoffMinute, noonCutoffMinute: $0.noonCutoffMinute, eveningCutoffMinute: $0.eveningCutoffMinute, allDayCutoffMinute: $0.allDayCutoffMinute, monitoringEnabled: $0.monitoringEnabled, note: $0.note, revision: $0.revision, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            },
            planPens: try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>()).filter {
                $0.farmID == farmID && planIDs.contains($0.planID)
            }.map {
                .init(id: $0.id, planID: $0.planID, penID: $0.penID, penNameSnapshot: $0.penNameSnapshot, fixedShareText: $0.fixedShareText, sortOrder: $0.sortOrder, revision: $0.revision, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            },
            batches: batches.map {
                .init(id: $0.id, batchCode: $0.batchCode, formulaID: $0.formulaID, formulaRevision: $0.formulaRevision, formulaNameSnapshot: $0.formulaNameSnapshot, quantityBasisRawValue: $0.quantityBasisRawValue, referenceHeadCountSnapshot: $0.referenceHeadCountSnapshot, componentSnapshotJSON: $0.componentSnapshotJSON, sourcePlanID: $0.sourcePlanID, sourcePlanRevision: $0.sourcePlanRevision, sourcePlanDate: $0.sourcePlanDate, sourcePlanMealsJSON: $0.sourcePlanMealsJSON, producedAt: $0.producedAt, producedKilogramsText: $0.producedKilogramsText, statusRawValue: $0.statusRawValue, note: $0.note, revision: $0.revision, createdAt: $0.createdAt, updatedAt: $0.updatedAt, closedAt: $0.closedAt, deletedAt: $0.deletedAt)
            },
            batchIngredients: try context.fetch(FetchDescriptor<TMRBatchIngredientRecord>()).filter {
                $0.farmID == farmID && batchIDs.contains($0.batchID)
            }.map {
                .init(id: $0.id, batchID: $0.batchID, ingredientID: $0.ingredientID, ingredientNameSnapshot: $0.ingredientNameSnapshot, plannedKilogramsText: $0.plannedKilogramsText, actualKilogramsText: $0.actualKilogramsText, unitSnapshot: $0.unitSnapshot, pricePerKilogramTextSnapshot: $0.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: $0.nutrientSnapshotJSON, dryMatterTextSnapshot: $0.dryMatterTextSnapshot, sortOrder: $0.sortOrder, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            loadLines: try context.fetch(FetchDescriptor<TMRBatchLoadLineRecord>()).filter {
                $0.farmID == farmID && batchIDs.contains($0.batchID)
            }.map {
                .init(id: $0.id, batchID: $0.batchID, batchIngredientID: $0.batchIngredientID, ingredientID: $0.ingredientID, ingredientBatchID: $0.ingredientBatchID, ingredientBatchNameSnapshot: $0.ingredientBatchNameSnapshot, actualKilogramsText: $0.actualKilogramsText, sortOrder: $0.sortOrder, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            movements: try context.fetch(FetchDescriptor<TMRBatchMovementRecord>()).filter {
                $0.farmID == farmID && batchIDs.contains($0.batchID)
            }.map {
                .init(id: $0.id, batchID: $0.batchID, kindRawValue: $0.kindRawValue, deltaKilogramsText: $0.deltaKilogramsText, occurredAt: $0.occurredAt, sourceRecordID: $0.sourceRecordID, sourceMovementID: $0.sourceMovementID, note: $0.note, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            feedingRuns: runs.map {
                .init(id: $0.id, batchID: $0.batchID, batchCodeSnapshot: $0.batchCodeSnapshot, formulaID: $0.formulaID, formulaRevision: $0.formulaRevision, formulaNameSnapshot: $0.formulaNameSnapshot, mealRawValue: $0.mealRawValue, occurredAt: $0.occurredAt, note: $0.note, batchRevisionBefore: $0.batchRevisionBefore, batchRevisionAfter: $0.batchRevisionAfter, revision: $0.revision, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            },
            feedingAllocations: try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>()).filter {
                $0.farmID == farmID && runIDs.contains($0.runID)
            }.map {
                .init(id: $0.id, runID: $0.runID, batchID: $0.batchID, feedRecordID: $0.feedRecordID, planID: $0.planID, planRevision: $0.planRevision, penID: $0.penID, penNameSnapshot: $0.penNameSnapshot, actualHeadCountSnapshot: $0.actualHeadCountSnapshot, actualKilogramsText: $0.actualKilogramsText, targetKilogramsTextSnapshot: $0.targetKilogramsTextSnapshot, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            mealCompletions: try context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).filter {
                $0.farmID == farmID && planIDs.contains($0.planID)
            }.map {
                .init(id: $0.id, planID: $0.planID, planRevision: $0.planRevision, penID: $0.penID, localDay: $0.localDay, mealRawValue: $0.mealRawValue, completedAt: $0.completedAt, note: $0.note, revision: $0.revision, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            deviationAcknowledgements: try context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>()).filter {
                $0.farmID == farmID && planIDs.contains($0.planID)
            }.map {
                .init(id: $0.id, planID: $0.planID, planRevision: $0.planRevision, penID: $0.penID, localDay: $0.localDay, mealRawValue: $0.mealRawValue, fingerprint: $0.fingerprint, note: $0.note, acknowledgedAt: $0.acknowledgedAt, acknowledgedByAccountID: $0.acknowledgedByAccountID, revision: $0.revision, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            monitoringRules: try context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>()).filter {
                $0.farmID == farmID
            }.map {
                .init(id: $0.id, tolerancePercentText: $0.tolerancePercentText, morningCutoffMinute: $0.morningCutoffMinute, noonCutoffMinute: $0.noonCutoffMinute, eveningCutoffMinute: $0.eveningCutoffMinute, allDayCutoffMinute: $0.allDayCutoffMinute, monitoringEnabledAt: $0.monitoringEnabledAt, revision: $0.revision, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            }
        )
    }

    func validate(
        recipeIDs: Set<UUID>,
        ingredientIDs: Set<UUID>,
        ingredientBatchIDs: Set<UUID>,
        feedRecordIDs: Set<UUID>,
        penIDs: Set<UUID>
    ) throws {
        try requireUnique(formulaProfiles.map(\.id), "TMR 配方")
        try requireUnique(plans.map(\.id), "TMR 计划")
        try requireUnique(planPens.map(\.id), "TMR 计划圈舍")
        try requireUnique(batches.map(\.id), "TMR 批次")
        try requireUnique(batchIngredients.map(\.id), "TMR 批次原料")
        try requireUnique(loadLines.map(\.id), "TMR 装料行")
        try requireUnique(movements.map(\.id), "TMR 成品流水")
        try requireUnique(feedingRuns.map(\.id), "TMR 投喂运行")
        try requireUnique(feedingAllocations.map(\.id), "TMR 圈舍分配")
        try requireUnique(mealCompletions.map(\.id), "TMR 顿次完成")
        try requireUnique(deviationAcknowledgements.map(\.id), "TMR 偏差确认")
        try requireUnique(monitoringRules.map(\.id), "TMR 监控规则")

        let formulaIDs = Set(formulaProfiles.map(\.recipeID))
        let planIDs = Set(plans.map(\.id))
        let batchIDs = Set(batches.map(\.id))
        let batchIngredientIDs = Set(batchIngredients.map(\.id))
        let runIDs = Set(feedingRuns.map(\.id))
        for value in formulaProfiles where !recipeIDs.contains(value.recipeID) {
            throw FarmLocalBackupError.missingReference("tmrFormula.recipeID")
        }
        for value in plans where !formulaIDs.contains(value.formulaID) {
            throw FarmLocalBackupError.missingReference("tmrPlan.formulaID")
        }
        for value in planPens {
            guard planIDs.contains(value.planID), penIDs.contains(value.penID) else {
                throw FarmLocalBackupError.missingReference("tmrPlanPen")
            }
        }
        for value in batches where !formulaIDs.contains(value.formulaID) {
            throw FarmLocalBackupError.missingReference("tmrBatch.formulaID")
        }
        for value in batchIngredients {
            guard batchIDs.contains(value.batchID), ingredientIDs.contains(value.ingredientID) else {
                throw FarmLocalBackupError.missingReference("tmrBatchIngredient")
            }
            guard Decimal.stable(value.actualKilogramsText).map({ $0 > 0 }) == true,
                  Decimal.stable(value.plannedKilogramsText).map({ $0 >= 0 }) == true else {
                throw FarmLocalBackupError.invalidProjection("tmrBatchIngredient.quantity")
            }
        }
        for value in loadLines {
            guard batchIDs.contains(value.batchID), batchIngredientIDs.contains(value.batchIngredientID),
                  ingredientIDs.contains(value.ingredientID), ingredientBatchIDs.contains(value.ingredientBatchID) else {
                throw FarmLocalBackupError.missingReference("tmrLoadLine")
            }
            guard Decimal.stable(value.actualKilogramsText).map({ $0 > 0 }) == true else {
                throw FarmLocalBackupError.invalidProjection("tmrLoadLine.quantity")
            }
        }
        for value in movements {
            guard batchIDs.contains(value.batchID),
                  TMRBatchMovementKind(rawValue: value.kindRawValue) != nil,
                  Decimal.stable(value.deltaKilogramsText) != nil else {
                throw FarmLocalBackupError.invalidProjection("tmrMovement")
            }
        }
        for value in feedingRuns {
            guard batchIDs.contains(value.batchID), formulaIDs.contains(value.formulaID),
                  TMRMealPeriod(rawValue: value.mealRawValue) != nil else {
                throw FarmLocalBackupError.missingReference("tmrFeedingRun")
            }
        }
        for value in feedingAllocations {
            guard runIDs.contains(value.runID), batchIDs.contains(value.batchID),
                  feedRecordIDs.contains(value.feedRecordID), penIDs.contains(value.penID),
                  value.actualHeadCountSnapshot > 0,
                  Decimal.stable(value.actualKilogramsText).map({ $0 > 0 }) == true else {
                throw FarmLocalBackupError.missingReference("tmrFeedingAllocation")
            }
            if let planID = value.planID, !planIDs.contains(planID) {
                throw FarmLocalBackupError.missingReference("tmrFeedingAllocation.planID")
            }
        }
        for value in mealCompletions {
            guard planIDs.contains(value.planID), penIDs.contains(value.penID),
                  TMRMealPeriod(rawValue: value.mealRawValue) != nil else {
                throw FarmLocalBackupError.missingReference("tmrMealCompletion")
            }
        }
        for value in deviationAcknowledgements {
            guard planIDs.contains(value.planID), penIDs.contains(value.penID),
                  TMRMealPeriod(rawValue: value.mealRawValue) != nil,
                  !value.fingerprint.isEmpty, !value.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FarmLocalBackupError.missingReference("tmrDeviationAcknowledgement")
            }
        }
        for value in monitoringRules {
            guard Decimal.stable(value.tolerancePercentText).map({ $0 >= 0 && $0 <= 100 }) == true,
                  value.morningCutoffMinute >= 0, value.morningCutoffMinute < 1_440,
                  value.noonCutoffMinute >= value.morningCutoffMinute,
                  value.eveningCutoffMinute >= value.noonCutoffMinute,
                  value.allDayCutoffMinute >= 0, value.allDayCutoffMinute < 1_440 else {
                throw FarmLocalBackupError.invalidProjection("tmrMonitoringRule")
            }
        }
        for batch in batches {
            guard let produced = Decimal.stable(batch.producedKilogramsText), produced > 0 else {
                throw FarmLocalBackupError.invalidProjection("tmrBatch.producedKilograms")
            }
            if let sourcePlanID = batch.sourcePlanID {
                guard planIDs.contains(sourcePlanID), batch.sourcePlanRevision != nil,
                      batch.sourcePlanDate != nil, let mealsJSON = batch.sourcePlanMealsJSON,
                      let data = mealsJSON.data(using: .utf8),
                      let rawValues = try? JSONDecoder().decode([String].self, from: data),
                      !rawValues.isEmpty,
                      rawValues.allSatisfy({ TMRMealPeriod(rawValue: $0) != nil }) else {
                    throw FarmLocalBackupError.invalidProjection("tmrBatch.sourcePlan")
                }
            } else if batch.sourcePlanRevision != nil || batch.sourcePlanDate != nil || batch.sourcePlanMealsJSON != nil {
                throw FarmLocalBackupError.invalidProjection("tmrBatch.sourcePlan")
            }
            let actual = batchIngredients
                .filter { $0.batchID == batch.id && $0.deletedAt == nil }
                .compactMap { Decimal.stable($0.actualKilogramsText) }
                .reduce(0, +)
            guard TMRDecimal.rounded(actual) == TMRDecimal.rounded(produced) else {
                throw FarmLocalBackupError.invalidProjection("tmrBatch.productionTotal")
            }
            let balance = movements
                .filter { $0.batchID == batch.id && $0.deletedAt == nil }
                .compactMap { Decimal.stable($0.deltaKilogramsText) }
                .reduce(0, +)
            guard balance >= 0 else {
                throw FarmLocalBackupError.invalidProjection("tmrBatch.balance")
            }
        }
    }

    func insert(farmID: UUID, context: ModelContext) {
        for value in formulaProfiles {
            let record = TMRFormulaProfileRecord(id: value.id, farmID: farmID, recipeID: value.recipeID, quantityBasis: TMRFormulaQuantityBasis(rawValue: value.quantityBasisRawValue) ?? .wholeGroupDaily, referenceHeadCount: value.referenceHeadCount, defaultScaleMode: TMRFormulaScaleMode(rawValue: value.defaultScaleModeRawValue) ?? .scaledByHeadCount, morningShareText: value.morningShareText, noonShareText: value.noonShareText, eveningShareText: value.eveningShareText, formulaRevision: value.formulaRevision, needsReview: value.needsReview, createdAt: value.createdAt)
            record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in plans {
            let record = TMRFeedingPlanRecord(id: value.id, farmID: farmID, formulaID: value.formulaID, formulaRevision: value.formulaRevision, formulaNameSnapshot: value.formulaNameSnapshot, quantityBasis: TMRFormulaQuantityBasis(rawValue: value.quantityBasisRawValue) ?? .wholeGroupDaily, referenceHeadCountSnapshot: value.referenceHeadCountSnapshot, formulaDailyTotalKilogramsText: value.formulaDailyTotalKilogramsText, componentSnapshotJSON: value.componentSnapshotJSON, scheduleKind: TMRPlanScheduleKind(rawValue: value.scheduleKindRawValue) ?? .continuous, effectiveStartDate: value.effectiveStartDate, effectiveEndDate: value.effectiveEndDate, scaleMode: TMRFormulaScaleMode(rawValue: value.scaleModeRawValue) ?? .scaledByHeadCount, allocationMode: TMRPenAllocationMode(rawValue: value.allocationModeRawValue) ?? .dynamicHeadCount, granularity: TMRMonitoringGranularity(rawValue: value.granularityRawValue) ?? .perMeal, morningShareText: value.morningShareText, noonShareText: value.noonShareText, eveningShareText: value.eveningShareText, tolerancePercentText: value.tolerancePercentText, morningCutoffMinute: value.morningCutoffMinute, noonCutoffMinute: value.noonCutoffMinute, eveningCutoffMinute: value.eveningCutoffMinute, allDayCutoffMinute: value.allDayCutoffMinute, monitoringEnabled: value.monitoringEnabled, note: value.note, revision: value.revision, createdAt: value.createdAt)
            record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in planPens {
            let record = TMRFeedingPlanPenRecord(id: value.id, farmID: farmID, planID: value.planID, penID: value.penID, penNameSnapshot: value.penNameSnapshot, fixedShareText: value.fixedShareText, sortOrder: value.sortOrder, revision: value.revision, createdAt: value.createdAt)
            record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in batches {
            let record = TMRBatchRecord(id: value.id, farmID: farmID, batchCode: value.batchCode, formulaID: value.formulaID, formulaRevision: value.formulaRevision, formulaNameSnapshot: value.formulaNameSnapshot, quantityBasis: TMRFormulaQuantityBasis(rawValue: value.quantityBasisRawValue) ?? .wholeGroupDaily, referenceHeadCountSnapshot: value.referenceHeadCountSnapshot, componentSnapshotJSON: value.componentSnapshotJSON, sourcePlanID: value.sourcePlanID, sourcePlanRevision: value.sourcePlanRevision, sourcePlanDate: value.sourcePlanDate, sourcePlanMealsJSON: value.sourcePlanMealsJSON, producedAt: value.producedAt, producedKilogramsText: value.producedKilogramsText, status: TMRBatchStatus(rawValue: value.statusRawValue) ?? .available, note: value.note, revision: value.revision, createdAt: value.createdAt)
            record.updatedAt = value.updatedAt; record.closedAt = value.closedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in batchIngredients {
            let record = TMRBatchIngredientRecord(id: value.id, farmID: farmID, batchID: value.batchID, ingredientID: value.ingredientID, ingredientNameSnapshot: value.ingredientNameSnapshot, plannedKilogramsText: value.plannedKilogramsText, actualKilogramsText: value.actualKilogramsText, unitSnapshot: value.unitSnapshot, pricePerKilogramTextSnapshot: value.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: value.nutrientSnapshotJSON, dryMatterTextSnapshot: value.dryMatterTextSnapshot, sortOrder: value.sortOrder, createdAt: value.createdAt)
            record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in loadLines {
            let record = TMRBatchLoadLineRecord(id: value.id, farmID: farmID, batchID: value.batchID, batchIngredientID: value.batchIngredientID, ingredientID: value.ingredientID, ingredientBatchID: value.ingredientBatchID, ingredientBatchNameSnapshot: value.ingredientBatchNameSnapshot, actualKilogramsText: value.actualKilogramsText, sortOrder: value.sortOrder, createdAt: value.createdAt)
            record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in movements {
            let record = TMRBatchMovementRecord(id: value.id, farmID: farmID, batchID: value.batchID, kind: TMRBatchMovementKind(rawValue: value.kindRawValue) ?? .adjustment, deltaKilogramsText: value.deltaKilogramsText, occurredAt: value.occurredAt, sourceRecordID: value.sourceRecordID, sourceMovementID: value.sourceMovementID, note: value.note, createdAt: value.createdAt)
            record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in feedingRuns {
            let record = TMRFeedingRunRecord(id: value.id, farmID: farmID, batchID: value.batchID, batchCodeSnapshot: value.batchCodeSnapshot, formulaID: value.formulaID, formulaRevision: value.formulaRevision, formulaNameSnapshot: value.formulaNameSnapshot, meal: TMRMealPeriod(rawValue: value.mealRawValue) ?? .morning, occurredAt: value.occurredAt, note: value.note, batchRevisionBefore: value.batchRevisionBefore, batchRevisionAfter: value.batchRevisionAfter, revision: value.revision, createdAt: value.createdAt)
            record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in feedingAllocations {
            let record = TMRFeedingAllocationRecord(id: value.id, farmID: farmID, runID: value.runID, batchID: value.batchID, feedRecordID: value.feedRecordID, planID: value.planID, planRevision: value.planRevision, penID: value.penID, penNameSnapshot: value.penNameSnapshot, actualHeadCountSnapshot: value.actualHeadCountSnapshot, actualKilogramsText: value.actualKilogramsText, targetKilogramsTextSnapshot: value.targetKilogramsTextSnapshot, createdAt: value.createdAt)
            record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in mealCompletions {
            let record = TMRMealCompletionRecord(id: value.id, farmID: farmID, planID: value.planID, planRevision: value.planRevision, penID: value.penID, localDay: value.localDay, meal: TMRMealPeriod(rawValue: value.mealRawValue) ?? .morning, completedAt: value.completedAt, note: value.note, revision: value.revision, createdAt: value.createdAt)
            record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in deviationAcknowledgements {
            let record = TMRDeviationAcknowledgementRecord(id: value.id, farmID: farmID, planID: value.planID, planRevision: value.planRevision, penID: value.penID, localDay: value.localDay, meal: TMRMealPeriod(rawValue: value.mealRawValue) ?? .morning, fingerprint: value.fingerprint, note: value.note, acknowledgedAt: value.acknowledgedAt, acknowledgedByAccountID: value.acknowledgedByAccountID, revision: value.revision, createdAt: value.createdAt)
            record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in monitoringRules {
            let record = TMRMonitoringRuleRecord(id: value.id, farmID: farmID, tolerancePercentText: value.tolerancePercentText, morningCutoffMinute: value.morningCutoffMinute, noonCutoffMinute: value.noonCutoffMinute, eveningCutoffMinute: value.eveningCutoffMinute, allDayCutoffMinute: value.allDayCutoffMinute, monitoringEnabledAt: value.monitoringEnabledAt, revision: value.revision, createdAt: value.createdAt)
            record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
    }

    private func requireUnique(_ ids: [UUID], _ type: String) throws {
        guard Set(ids).count == ids.count else {
            throw FarmLocalBackupError.duplicateIdentifier(type)
        }
    }
}
