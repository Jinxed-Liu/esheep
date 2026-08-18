import Foundation
import SwiftData

enum TMRCommandApplyError: LocalizedError, Equatable {
    case formulaNotFound
    case planNotFound
    case batchNotFound
    case runNotFound
    case completionNotFound
    case ingredientNotFound
    case ingredientBatchNotFound
    case penNotFound
    case revisionConflict(current: Int)
    case duplicateIdentifier
    case duplicateIngredient
    case duplicateBatchCode
    case formulaNeedsReview
    case formulaIngredientsMismatch
    case planOverlap
    case planFormulaMismatch
    case planPenMismatch
    case planMealMismatch
    case mealAlreadyCompleted
    case batchUnavailable
    case batchHasFeedingHistory
    case nonzeroBalanceRequiresWriteOff
    case reasonRequired
    case invalidDateRange
    case invalidCutoff
    case invalidTolerance
    case invalidActualHeadCount

    var errorDescription: String? {
        switch self {
        case .formulaNotFound: "未找到可用的 TMR 配方。"
        case .planNotFound: "未找到可用的 TMR 投喂计划。"
        case .batchNotFound: "未找到可用的 TMR 批次。"
        case .runNotFound: "未找到可修正的 TMR 投喂记录。"
        case .completionNotFound: "未找到已完成的 TMR 顿次。"
        case .ingredientNotFound: "TMR 配方引用的原料不存在或已停用。"
        case .ingredientBatchNotFound: "实际装料引用的原料库存批次不存在、已停用或品种不符。"
        case .penNotFound: "TMR 计划或投喂引用的圈舍不存在。"
        case .revisionConflict: "数据已在其他设备或页面更新，请刷新后重试。"
        case .duplicateIdentifier: "本次 TMR 操作包含重复标识，已停止保存。"
        case .duplicateIngredient: "同一种原料在配方或本锅中只能出现一次；多个库存批次请放在同一原料下。"
        case .duplicateBatchCode: "TMR 批次号已存在，请使用新的批次号。"
        case .formulaNeedsReview: "该历史配方缺少参考羊数，请确认后再建立按羊数缩放计划。"
        case .formulaIngredientsMismatch: "本锅原料必须与所选 TMR 配方的原料组成一致。"
        case .planOverlap: "所选圈舍和日期已有重叠的 TMR 监控计划。"
        case .planFormulaMismatch: "所选计划与本锅 TMR 配方不一致。"
        case .planPenMismatch: "所选圈舍不属于该 TMR 投喂计划。"
        case .planMealMismatch: "所选顿次不属于该 TMR 投喂计划。"
        case .mealAlreadyCompleted: "该顿已手工完成；请先重新打开本顿，再追加投料。"
        case .batchUnavailable: "该 TMR 批次已结清或删除，不能继续使用。"
        case .batchHasFeedingHistory: "该锅已有投喂记录，不能删除生产事实；可以结清或报废余额。"
        case .nonzeroBalanceRequiresWriteOff: "批次仍有余额，请选择报废剩余量或先调整至 0。"
        case .reasonRequired: "该操作必须填写原因或备注。"
        case .invalidDateRange: "TMR 计划的生效日期范围无效。"
        case .invalidCutoff: "顿次截止时间必须位于当天，且早、中、晚顺序正确。"
        case .invalidTolerance: "TMR 偏差阈值必须在 0% 到 100% 之间。"
        case .invalidActualHeadCount: "投喂圈舍的实际羊数快照必须大于 0。"
        }
    }
}

enum TMRStockLedgerIdentity {
    static func consumptionID(loadLineID: UUID) -> UUID {
        StableCloudUUID.derived(namespace: loadLineID, name: "tmr-production-consumption")
    }

    static func reversalID(consumptionID: UUID) -> UUID {
        StableCloudUUID.derived(namespace: consumptionID, name: "tmr-production-reversal")
    }
}

enum TMRCommandHandler {
    struct Result: Sendable {
        let entityType: CloudEntityType
        let entityID: UUID
        let baseRevision: Int
        let resultingRevision: Int
        let payloadCommand: TMRCommand
    }

    static func validateAndApply(
        _ command: TMRCommand,
        farmID: UUID,
        accountID: UUID,
        context: ModelContext,
        modifiedAt: Date = .now
    ) throws -> Result {
        switch command {
        case .saveFormula(let draft):
            return try saveFormula(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .saveMonitoringRule(let draft):
            return try saveMonitoringRule(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .saveFeedingPlan(let draft):
            return try saveFeedingPlan(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .produceBatch(let draft):
            return try produceBatch(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .recordFeeding(let draft):
            return try recordFeeding(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .correctFeedingRun(let draft):
            return try correctFeedingRun(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .reverseFeedingRun(let draft):
            return try reverseFeedingRun(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .completeMeal(let draft):
            return try completeMeal(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .reopenMeal(let draft):
            return try reopenMeal(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .adjustBatch(let draft):
            return try adjustBatch(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .closeBatch(let draft):
            return try closeBatch(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .deleteUnusedBatch(let draft):
            return try deleteUnusedBatch(draft, farmID: farmID, context: context, modifiedAt: modifiedAt)
        case .acknowledgeDeviation(let draft):
            return try acknowledgeDeviation(
                draft,
                farmID: farmID,
                accountID: accountID,
                context: context,
                modifiedAt: modifiedAt
            )
        }
    }

    private static func saveFormula(
        _ draft: TMRFormulaDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FarmCommandError.missingRequiredValue("TMR 配方名称") }
        guard !draft.components.isEmpty else { throw TMRDomainError.emptyFormula }
        guard Set(draft.components.map(\.id)).count == draft.components.count else {
            throw TMRCommandApplyError.duplicateIdentifier
        }
        guard Set(draft.components.map(\.ingredientID)).count == draft.components.count else {
            throw TMRCommandApplyError.duplicateIngredient
        }
        _ = try TMRMealShares(
            morning: try positiveOrZero(draft.morningShareText),
            noon: try positiveOrZero(draft.noonShareText),
            evening: try positiveOrZero(draft.eveningShareText)
        )
        if draft.quantityBasis == .wholeGroupDaily {
            guard let referenceHeadCount = draft.referenceHeadCount, referenceHeadCount > 0 else {
                throw TMRDomainError.invalidReferenceHeadCount
            }
        } else if let referenceHeadCount = draft.referenceHeadCount, referenceHeadCount <= 0 {
            throw TMRDomainError.invalidReferenceHeadCount
        }

        let ingredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>())
        let ingredientByID = Dictionary(uniqueKeysWithValues: ingredients
            .filter { $0.farmID == farmID && $0.deletedAt == nil && $0.isActive }
            .map { ($0.id, $0) })
        for component in draft.components {
            guard ingredientByID[component.ingredientID] != nil else {
                throw TMRCommandApplyError.ingredientNotFound
            }
            guard let quantity = Decimal.stable(component.quantityText), quantity > 0 else {
                throw TMRDomainError.nonPositiveQuantity
            }
        }

        let recipes = try context.fetch(FetchDescriptor<FeedRecipeRecord>())
        let profiles = try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>())
        let existingRecipe = recipes.first { $0.id == draft.id && $0.farmID == farmID && $0.deletedAt == nil }
        let existingProfile = profiles.first { $0.recipeID == draft.id && $0.farmID == farmID && $0.deletedAt == nil }
        let baseRevision = existingProfile?.formulaRevision ?? 0
        guard draft.expectedRevision == baseRevision else {
            throw TMRCommandApplyError.revisionConflict(current: baseRevision)
        }
        if existingRecipe == nil, existingProfile != nil { throw TMRCommandApplyError.formulaNotFound }

        let recipe: FeedRecipeRecord
        if let existingRecipe {
            recipe = existingRecipe
        } else {
            recipe = FeedRecipeRecord(id: draft.id, farmID: farmID, name: name)
            context.insert(recipe)
        }
        recipe.name = name
        recipe.stageRawValue = draft.stage.rawValue
        recipe.headCount = draft.referenceHeadCount
        recipe.targetPenID = nil
        recipe.targetPenName = nil
        recipe.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.isActive = true
        recipe.updatedAt = modifiedAt
        recipe.deletedAt = nil

        let currentComponents = try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>())
            .filter { $0.farmID == farmID && $0.recipeID == draft.id && $0.deletedAt == nil }
        let incomingIDs = Set(draft.components.map(\.id))
        for component in currentComponents where !incomingIDs.contains(component.id) {
            component.deletedAt = modifiedAt
            component.updatedAt = modifiedAt
        }
        for component in draft.components {
            let ingredient = ingredientByID[component.ingredientID]!
            let record: FeedRecipeComponentRecord
            if let current = currentComponents.first(where: { $0.id == component.id }) {
                record = current
            } else {
                record = FeedRecipeComponentRecord(
                    id: component.id,
                    farmID: farmID,
                    recipeID: recipe.id,
                    ingredientID: component.ingredientID,
                    kilogramsText: normalized(component.quantityText)
                )
                context.insert(record)
            }
            record.ingredientID = component.ingredientID
            record.ingredientBatchID = nil
            record.kilogramsText = normalized(component.quantityText)
            record.pricePerKilogramText = nil
            record.nutrientSnapshotJSON = ingredient.nutrientSnapshotJSON
            record.updatedAt = modifiedAt
            record.deletedAt = nil
        }

        let profile: TMRFormulaProfileRecord
        if let existingProfile {
            profile = existingProfile
        } else {
            profile = TMRFormulaProfileRecord(
                id: draft.id,
                farmID: farmID,
                recipeID: draft.id,
                quantityBasis: draft.quantityBasis,
                createdAt: modifiedAt
            )
            context.insert(profile)
        }
        profile.quantityBasisRawValue = draft.quantityBasis.rawValue
        profile.referenceHeadCount = draft.referenceHeadCount
        profile.defaultScaleModeRawValue = draft.defaultScaleMode.rawValue
        profile.morningShareText = normalized(draft.morningShareText)
        profile.noonShareText = normalized(draft.noonShareText)
        profile.eveningShareText = normalized(draft.eveningShareText)
        profile.formulaRevision = baseRevision + 1
        profile.needsReview = false
        profile.updatedAt = modifiedAt
        profile.deletedAt = nil

        return Result(
            entityType: .tmrFormula,
            entityID: profile.id,
            baseRevision: baseRevision,
            resultingRevision: profile.formulaRevision,
            payloadCommand: .saveFormula(draft)
        )
    }

    private static func saveMonitoringRule(
        _ draft: TMRMonitoringRuleDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        let tolerance = try tolerance(draft.tolerancePercentText)
        try validateCutoffs(
            morning: draft.morningCutoffMinute,
            noon: draft.noonCutoffMinute,
            evening: draft.eveningCutoffMinute,
            allDay: draft.allDayCutoffMinute
        )
        let rules = try context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let existing = rules.first { $0.id == draft.id }
        if existing == nil, !rules.isEmpty { throw TMRCommandApplyError.duplicateIdentifier }
        let baseRevision = existing?.revision ?? 0
        guard draft.expectedRevision == baseRevision else {
            throw TMRCommandApplyError.revisionConflict(current: baseRevision)
        }
        let rule: TMRMonitoringRuleRecord
        if let existing {
            rule = existing
        } else {
            rule = TMRMonitoringRuleRecord(id: draft.id, farmID: farmID, createdAt: modifiedAt)
            context.insert(rule)
        }
        rule.tolerancePercentText = tolerance.stableText
        rule.morningCutoffMinute = draft.morningCutoffMinute
        rule.noonCutoffMinute = draft.noonCutoffMinute
        rule.eveningCutoffMinute = draft.eveningCutoffMinute
        rule.allDayCutoffMinute = draft.allDayCutoffMinute
        rule.monitoringEnabledAt = draft.confirmsMonitoring ? (rule.monitoringEnabledAt ?? modifiedAt) : nil
        rule.revision = baseRevision + 1
        rule.updatedAt = modifiedAt
        rule.deletedAt = nil
        return Result(
            entityType: .tmrMonitoringRule,
            entityID: rule.id,
            baseRevision: baseRevision,
            resultingRevision: rule.revision,
            payloadCommand: .saveMonitoringRule(draft)
        )
    }

    private static func saveFeedingPlan(
        _ draft: TMRFeedingPlanDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).first(where: {
            $0.id == draft.id && $0.farmID == farmID
        }) == nil else { throw TMRCommandApplyError.duplicateIdentifier }
        let (recipe, profile, snapshot) = try formulaSnapshot(
            formulaID: draft.formulaID,
            expectedRevision: draft.expectedFormulaRevision,
            farmID: farmID,
            context: context
        )
        if draft.scaleMode == .scaledByHeadCount,
           profile.quantityBasis == .wholeGroupDaily,
           (profile.needsReview || (profile.referenceHeadCount ?? 0) <= 0) {
            throw TMRCommandApplyError.formulaNeedsReview
        }
        guard !draft.pens.isEmpty else { throw TMRDomainError.emptyPens }
        guard Set(draft.pens.map(\.id)).count == draft.pens.count,
              Set(draft.pens.map(\.penID)).count == draft.pens.count else {
            throw TMRCommandApplyError.duplicateIdentifier
        }
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
        let penByID = Dictionary(uniqueKeysWithValues: pens
            .filter { $0.farmID == farmID && $0.deletedAt == nil && $0.isActive }
            .map { ($0.id, $0) })
        guard draft.pens.allSatisfy({ penByID[$0.penID] != nil }) else {
            throw TMRCommandApplyError.penNotFound
        }
        let shares = try TMRMealShares(
            morning: try positiveOrZero(draft.morningShareText),
            noon: try positiveOrZero(draft.noonShareText),
            evening: try positiveOrZero(draft.eveningShareText)
        )
        if draft.granularity == .perMeal, shares.enabledMeals.isEmpty {
            throw TMRDomainError.invalidMealShares
        }
        if draft.allocationMode == .fixedShare {
            let values = try draft.pens.map { pen -> Decimal in
                guard let text = pen.fixedShareText else { throw TMRDomainError.invalidFixedShares }
                return try positiveOrZero(text)
            }
            guard values.reduce(0, +) == 1 else { throw TMRDomainError.invalidFixedShares }
        }
        _ = try tolerance(draft.tolerancePercentText)
        try validateCutoffs(
            morning: draft.morningCutoffMinute,
            noon: draft.noonCutoffMinute,
            evening: draft.eveningCutoffMinute,
            allDay: draft.allDayCutoffMinute
        )

        let timeZone = try farmTimeZone(farmID: farmID, context: context)
        let start = TMRLocalDay.start(of: draft.effectiveStartDate, timeZone: timeZone)
        let end: Date?
        if draft.scheduleKind == .oneTime {
            end = start
        } else if let draftEnd = draft.effectiveEndDate {
            end = TMRLocalDay.start(of: draftEnd, timeZone: timeZone)
        } else {
            end = nil
        }
        if let end, end < start { throw TMRCommandApplyError.invalidDateRange }

        if let oldID = draft.supersedesPlanID {
            guard let old = try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).first(where: {
                $0.id == oldID && $0.farmID == farmID && $0.deletedAt == nil
            }) else { throw TMRCommandApplyError.planNotFound }
            old.effectiveEndDate = start.addingTimeInterval(-1)
            old.revision += 1
            old.updatedAt = modifiedAt
        }

        try validateNoPlanOverlap(
            draft: draft,
            normalizedStart: start,
            normalizedEnd: end,
            enabledMeals: shares.enabledMeals,
            farmID: farmID,
            context: context
        )
        let formulaDailyTotal = try TMRCalculator.formulaDailyTotal(snapshot)
        let plan = TMRFeedingPlanRecord(
            id: draft.id,
            farmID: farmID,
            formulaID: recipe.id,
            formulaRevision: profile.formulaRevision,
            formulaNameSnapshot: recipe.name,
            quantityBasis: profile.quantityBasis,
            referenceHeadCountSnapshot: profile.referenceHeadCount,
            formulaDailyTotalKilogramsText: formulaDailyTotal.stableText,
            componentSnapshotJSON: TMRFormulaSnapshotCodec.encode(snapshot),
            scheduleKind: draft.scheduleKind,
            effectiveStartDate: start,
            effectiveEndDate: end,
            scaleMode: draft.scaleMode,
            allocationMode: draft.allocationMode,
            granularity: draft.granularity,
            morningShareText: normalized(draft.morningShareText),
            noonShareText: normalized(draft.noonShareText),
            eveningShareText: normalized(draft.eveningShareText),
            tolerancePercentText: normalized(draft.tolerancePercentText),
            morningCutoffMinute: draft.morningCutoffMinute,
            noonCutoffMinute: draft.noonCutoffMinute,
            eveningCutoffMinute: draft.eveningCutoffMinute,
            allDayCutoffMinute: draft.allDayCutoffMinute,
            monitoringEnabled: draft.monitoringEnabled,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: modifiedAt
        )
        context.insert(plan)
        for (index, penDraft) in draft.pens.enumerated() {
            let pen = penByID[penDraft.penID]!
            context.insert(TMRFeedingPlanPenRecord(
                id: penDraft.id,
                farmID: farmID,
                planID: plan.id,
                penID: pen.id,
                penNameSnapshot: pen.name,
                fixedShareText: penDraft.fixedShareText.map(normalized),
                sortOrder: index,
                createdAt: modifiedAt
            ))
        }
        return Result(
            entityType: .tmrFeedingPlan,
            entityID: plan.id,
            baseRevision: 0,
            resultingRevision: 1,
            payloadCommand: .saveFeedingPlan(draft)
        )
    }

    private static func produceBatch(
        _ draft: TMRBatchProductionDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard try context.fetch(FetchDescriptor<TMRBatchRecord>()).first(where: {
            $0.id == draft.id && $0.farmID == farmID
        }) == nil else { throw TMRCommandApplyError.duplicateIdentifier }
        let resolvedFormulaID: UUID
        let resolvedFormulaRevision: Int
        let resolvedFormulaName: String
        let resolvedQuantityBasis: TMRFormulaQuantityBasis
        let resolvedReferenceHeadCount: Int?
        let snapshot: [TMRFormulaComponentSnapshot]
        let normalizedSourcePlanDate: Date?
        let normalizedSourceMeals: [TMRMealPeriod]?
        if let sourcePlanID = draft.sourcePlanID {
            guard let sourcePlanRevision = draft.sourcePlanRevision,
                  let sourcePlanDate = draft.sourcePlanDate,
                  let sourceMeals = draft.sourceMeals,
                  !sourceMeals.isEmpty,
                  Set(sourceMeals).count == sourceMeals.count,
                  let plan = try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).first(where: {
                      $0.id == sourcePlanID && $0.farmID == farmID && $0.deletedAt == nil
                  }) else {
                throw TMRCommandApplyError.planNotFound
            }
            try assertRevision(sourcePlanRevision, current: plan.revision)
            guard plan.formulaID == draft.formulaID,
                  plan.formulaRevision == draft.expectedFormulaRevision else {
                throw TMRCommandApplyError.planFormulaMismatch
            }
            let timeZone = try farmTimeZone(farmID: farmID, context: context)
            let localDay = TMRLocalDay.start(of: sourcePlanDate, timeZone: timeZone)
            guard plan.effectiveStartDate <= localDay,
                  localDay <= (plan.effectiveEndDate ?? .distantFuture) else {
                throw TMRCommandApplyError.invalidDateRange
            }
            if plan.granularity == .dailySummary {
                guard sourceMeals == [TMRMealPeriod.allDaySummary] else {
                    throw TMRCommandApplyError.planMealMismatch
                }
            } else {
                guard sourceMeals.allSatisfy({
                    TMRMealPeriod.actualMeals.contains($0) && plan.share(for: $0) > 0
                }) else {
                    throw TMRCommandApplyError.planMealMismatch
                }
            }
            resolvedFormulaID = plan.formulaID
            resolvedFormulaRevision = plan.formulaRevision
            resolvedFormulaName = plan.formulaNameSnapshot
            resolvedQuantityBasis = plan.quantityBasis
            resolvedReferenceHeadCount = plan.referenceHeadCountSnapshot
            snapshot = plan.componentSnapshot
            normalizedSourcePlanDate = localDay
            normalizedSourceMeals = sourceMeals.sorted { $0.sortOrder < $1.sortOrder }
        } else {
            guard draft.sourcePlanRevision == nil,
                  draft.sourcePlanDate == nil,
                  draft.sourceMeals == nil else {
                throw TMRCommandApplyError.planNotFound
            }
            let (recipe, profile, currentSnapshot) = try formulaSnapshot(
                formulaID: draft.formulaID,
                expectedRevision: draft.expectedFormulaRevision,
                farmID: farmID,
                context: context
            )
            resolvedFormulaID = recipe.id
            resolvedFormulaRevision = profile.formulaRevision
            resolvedFormulaName = recipe.name
            resolvedQuantityBasis = profile.quantityBasis
            resolvedReferenceHeadCount = profile.referenceHeadCount
            snapshot = currentSnapshot
            normalizedSourcePlanDate = nil
            normalizedSourceMeals = nil
        }
        guard !draft.ingredients.isEmpty else { throw TMRDomainError.emptyFormula }
        guard Set(draft.ingredients.map(\.id)).count == draft.ingredients.count else {
            throw TMRCommandApplyError.duplicateIdentifier
        }
        guard Set(draft.ingredients.map(\.ingredientID)).count == draft.ingredients.count else {
            throw TMRCommandApplyError.duplicateIngredient
        }
        guard Set(draft.ingredients.map(\.ingredientID)) == Set(snapshot.map(\.ingredientID)) else {
            throw TMRCommandApplyError.formulaIngredientsMismatch
        }
        let allLoadIDs = draft.ingredients.flatMap(\.loadLines).map(\.id)
        guard Set(allLoadIDs).count == allLoadIDs.count else {
            throw TMRCommandApplyError.duplicateIdentifier
        }

        let ingredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>())
        let ingredientByID = Dictionary(uniqueKeysWithValues: ingredients
            .filter { $0.farmID == farmID && $0.deletedAt == nil && $0.isActive }
            .map { ($0.id, $0) })
        let stockBatches = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
        let stockByID = Dictionary(uniqueKeysWithValues: stockBatches
            .filter { $0.farmID == farmID && $0.deletedAt == nil && $0.isActive }
            .map { ($0.id, $0) })
        let stockTransactions = try context.fetch(FetchDescriptor<FeedStockTransactionRecord>())
        var requestedByStockBatch: [UUID: Decimal] = [:]
        var actualByIngredient: [UUID: Decimal] = [:]
        for ingredientDraft in draft.ingredients {
            guard ingredientByID[ingredientDraft.ingredientID] != nil else {
                throw TMRCommandApplyError.ingredientNotFound
            }
            guard let planned = Decimal.stable(ingredientDraft.plannedKilogramsText), planned > 0 else {
                throw TMRDomainError.nonPositiveQuantity
            }
            guard !ingredientDraft.loadLines.isEmpty else { throw TMRDomainError.nonPositiveQuantity }
            for load in ingredientDraft.loadLines {
                guard let stock = stockByID[load.ingredientBatchID],
                      stock.ingredientID == ingredientDraft.ingredientID else {
                    throw TMRCommandApplyError.ingredientBatchNotFound
                }
                guard let actual = Decimal.stable(load.actualKilogramsText), actual > 0 else {
                    throw TMRDomainError.nonPositiveQuantity
                }
                requestedByStockBatch[stock.id, default: 0] += actual
                actualByIngredient[ingredientDraft.ingredientID, default: 0] += actual
            }
        }
        for (stockID, requested) in requestedByStockBatch {
            guard let stock = stockByID[stockID],
                  let available = FeedStockLedger.balance(for: stock, transactions: stockTransactions) else {
                throw FeedStockLedgerError.baselineMissing(stockID)
            }
            guard available >= requested else {
                throw FeedStockLedgerError.insufficient(batchID: stockID, available: available, requested: requested)
            }
        }

        let produced = actualByIngredient.values.reduce(0, +)
        guard produced > 0 else { throw TMRDomainError.nonPositiveQuantity }
        let code = try resolvedBatchCode(
            requested: draft.batchCode,
            producedAt: draft.producedAt,
            farmID: farmID,
            context: context
        )
        let resolvedDraft = TMRBatchProductionDraft(
            id: draft.id,
            formulaID: draft.formulaID,
            expectedFormulaRevision: draft.expectedFormulaRevision,
            sourcePlanID: draft.sourcePlanID,
            sourcePlanRevision: draft.sourcePlanRevision,
            sourcePlanDate: normalizedSourcePlanDate,
            sourceMeals: normalizedSourceMeals,
            batchCode: code,
            producedAt: draft.producedAt,
            ingredients: draft.ingredients,
            note: draft.note
        )
        let batch = TMRBatchRecord(
            id: draft.id,
            farmID: farmID,
            batchCode: code,
            formulaID: resolvedFormulaID,
            formulaRevision: resolvedFormulaRevision,
            formulaNameSnapshot: resolvedFormulaName,
            quantityBasis: resolvedQuantityBasis,
            referenceHeadCountSnapshot: resolvedReferenceHeadCount,
            componentSnapshotJSON: TMRFormulaSnapshotCodec.encode(snapshot),
            sourcePlanID: draft.sourcePlanID,
            sourcePlanRevision: draft.sourcePlanRevision,
            sourcePlanDate: normalizedSourcePlanDate,
            sourcePlanMealsJSON: try normalizedSourceMeals.map {
                let data = try JSONEncoder().encode($0.map(\.rawValue))
                guard let text = String(data: data, encoding: .utf8) else {
                    throw TMRCommandApplyError.planMealMismatch
                }
                return text
            },
            producedAt: draft.producedAt,
            producedKilogramsText: TMRDecimal.rounded(produced).stableText,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: modifiedAt
        )
        context.insert(batch)

        let formulaComponentByIngredient = Dictionary(uniqueKeysWithValues: snapshot.map {
            ($0.ingredientID, $0)
        })
        for (ingredientIndex, ingredientDraft) in draft.ingredients.enumerated() {
            let ingredient = ingredientByID[ingredientDraft.ingredientID]!
            guard let formulaComponent = formulaComponentByIngredient[ingredient.id] else {
                throw TMRCommandApplyError.formulaIngredientsMismatch
            }
            let actual = actualByIngredient[ingredient.id] ?? 0
            let weightedPrice = weightedPriceForLoads(ingredientDraft.loadLines, stockByID: stockByID)
            let batchIngredient = TMRBatchIngredientRecord(
                id: ingredientDraft.id,
                farmID: farmID,
                batchID: batch.id,
                ingredientID: ingredient.id,
                ingredientNameSnapshot: formulaComponent.ingredientName,
                plannedKilogramsText: normalized(ingredientDraft.plannedKilogramsText),
                actualKilogramsText: TMRDecimal.rounded(actual).stableText,
                unitSnapshot: formulaComponent.unit,
                pricePerKilogramTextSnapshot: weightedPrice?.stableText,
                nutrientSnapshotJSON: formulaComponent.nutrientSnapshotJSON,
                dryMatterTextSnapshot: formulaComponent.dryMatterText,
                sortOrder: ingredientIndex,
                createdAt: modifiedAt
            )
            context.insert(batchIngredient)
            for (loadIndex, loadDraft) in ingredientDraft.loadLines.enumerated() {
                let stock = stockByID[loadDraft.ingredientBatchID]!
                let quantity = normalized(loadDraft.actualKilogramsText)
                context.insert(TMRBatchLoadLineRecord(
                    id: loadDraft.id,
                    farmID: farmID,
                    batchID: batch.id,
                    batchIngredientID: batchIngredient.id,
                    ingredientID: ingredient.id,
                    ingredientBatchID: stock.id,
                    ingredientBatchNameSnapshot: stock.batchName,
                    actualKilogramsText: quantity,
                    sortOrder: loadIndex,
                    createdAt: modifiedAt
                ))
                context.insert(FeedStockTransactionRecord(
                    id: TMRStockLedgerIdentity.consumptionID(loadLineID: loadDraft.id),
                    farmID: farmID,
                    ingredientBatchID: stock.id,
                    kind: .consumption,
                    quantityText: quantity,
                    occurredAt: draft.producedAt,
                    sourceRecordID: batch.id,
                    sourceLineID: loadDraft.id,
                    note: "制作 TMR \(code) 扣减"
                ))
            }
        }
        context.insert(TMRBatchMovementRecord(
            id: StableCloudUUID.derived(namespace: batch.id, name: "tmr-production-movement"),
            farmID: farmID,
            batchID: batch.id,
            kind: .production,
            deltaKilogramsText: batch.producedKilogramsText,
            occurredAt: draft.producedAt,
            sourceRecordID: batch.id,
            note: "制作入账",
            createdAt: modifiedAt
        ))
        return Result(
            entityType: .tmrBatch,
            entityID: batch.id,
            baseRevision: 0,
            resultingRevision: 1,
            payloadCommand: .produceBatch(resolvedDraft)
        )
    }

    private static func recordFeeding(
        _ draft: TMRFeedingRunDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        let batch = try activeBatch(draft.batchID, farmID: farmID, context: context)
        try assertRevision(draft.expectedBatchRevision, current: batch.revision)
        guard batch.status != .closed else { throw TMRCommandApplyError.batchUnavailable }
        guard try context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).first(where: {
            $0.id == draft.id && $0.farmID == farmID
        }) == nil else { throw TMRCommandApplyError.duplicateIdentifier }
        let completionsToReopen = try validateFeedingAllocations(
            draft.allocations,
            batch: batch,
            meal: draft.meal,
            occurredAt: draft.occurredAt,
            excludingRunID: nil,
            reopenCompletions: draft.reopenCompletions ?? [],
            farmID: farmID,
            context: context
        )
        let requested = try totalActual(draft.allocations)
        let available = try batchBalance(batch.id, farmID: farmID, context: context)
        try TMRCalculator.validateWithdrawal(available: available, requested: requested)
        for completion in completionsToReopen {
            guard let reopenDraft = draft.reopenCompletions?.first(where: {
                $0.completionID == completion.id
            }) else { throw TMRCommandApplyError.completionNotFound }
            markCompletionReopened(completion, reason: reopenDraft.reason, modifiedAt: modifiedAt)
        }
        try insertFeedingRun(
            id: draft.id,
            batch: batch,
            expectedBatchRevision: draft.expectedBatchRevision,
            occurredAt: draft.occurredAt,
            meal: draft.meal,
            allocations: draft.allocations,
            note: draft.note,
            farmID: farmID,
            context: context,
            modifiedAt: modifiedAt
        )
        updateBatch(batch, balanceAfterDelta: available - requested, modifiedAt: modifiedAt)
        return Result(
            entityType: .tmrBatch,
            entityID: batch.id,
            baseRevision: draft.expectedBatchRevision,
            resultingRevision: batch.revision,
            payloadCommand: .recordFeeding(draft)
        )
    }

    private static func correctFeedingRun(
        _ draft: TMRFeedingCorrectionDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard !draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TMRCommandApplyError.reasonRequired
        }
        let batch = try activeBatch(draft.batchID, farmID: farmID, context: context)
        try assertRevision(draft.expectedBatchRevision, current: batch.revision)
        guard batch.status != .closed else { throw TMRCommandApplyError.batchUnavailable }
        let original = try activeRun(draft.originalRunID, batchID: batch.id, farmID: farmID, context: context)
        guard try context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).first(where: {
            $0.id == draft.id && $0.farmID == farmID
        }) == nil else { throw TMRCommandApplyError.duplicateIdentifier }
        let oldActual = try activeAllocations(runID: original.id, farmID: farmID, context: context)
            .reduce(Decimal.zero) { $0 + $1.actualKilograms }
        _ = try validateFeedingAllocations(
            draft.allocations,
            batch: batch,
            meal: draft.meal,
            occurredAt: draft.occurredAt,
            excludingRunID: original.id,
            allowCompletedMeal: true,
            farmID: farmID,
            context: context
        )
        let replacementActual = try totalActual(draft.allocations)
        let currentBalance = try batchBalance(batch.id, farmID: farmID, context: context)
        let availableAfterReversal = currentBalance + oldActual
        try TMRCalculator.validateWithdrawal(available: availableAfterReversal, requested: replacementActual)
        try retireRun(
            original,
            reason: draft.reason,
            reversalID: StableCloudUUID.derived(namespace: draft.id, name: "tmr-correction-reversal"),
            farmID: farmID,
            context: context,
            modifiedAt: modifiedAt
        )
        try insertFeedingRun(
            id: draft.id,
            batch: batch,
            expectedBatchRevision: draft.expectedBatchRevision,
            occurredAt: draft.occurredAt,
            meal: draft.meal,
            allocations: draft.allocations,
            note: draft.note,
            farmID: farmID,
            context: context,
            modifiedAt: modifiedAt
        )
        updateBatch(batch, balanceAfterDelta: availableAfterReversal - replacementActual, modifiedAt: modifiedAt)
        return Result(
            entityType: .tmrBatch,
            entityID: batch.id,
            baseRevision: draft.expectedBatchRevision,
            resultingRevision: batch.revision,
            payloadCommand: .correctFeedingRun(draft)
        )
    }

    private static func reverseFeedingRun(
        _ draft: TMRFeedingReversalDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard !draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TMRCommandApplyError.reasonRequired
        }
        let batch = try activeBatch(draft.batchID, farmID: farmID, context: context)
        try assertRevision(draft.expectedBatchRevision, current: batch.revision)
        guard batch.status != .closed else { throw TMRCommandApplyError.batchUnavailable }
        let run = try activeRun(draft.runID, batchID: batch.id, farmID: farmID, context: context)
        let reversed = try activeAllocations(runID: run.id, farmID: farmID, context: context)
            .reduce(Decimal.zero) { $0 + $1.actualKilograms }
        let currentBalance = try batchBalance(batch.id, farmID: farmID, context: context)
        try retireRun(
            run,
            reason: draft.reason,
            reversalID: draft.id,
            farmID: farmID,
            context: context,
            modifiedAt: modifiedAt
        )
        updateBatch(batch, balanceAfterDelta: currentBalance + reversed, modifiedAt: modifiedAt)
        return Result(
            entityType: .tmrBatch,
            entityID: batch.id,
            baseRevision: draft.expectedBatchRevision,
            resultingRevision: batch.revision,
            payloadCommand: .reverseFeedingRun(draft)
        )
    }

    private static func completeMeal(
        _ draft: TMRMealCompletionDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        let plan = try activePlan(draft.planID, farmID: farmID, context: context)
        try assertRevision(draft.expectedPlanRevision, current: plan.revision)
        try assertPlanPenAndMeal(plan: plan, penID: draft.penID, meal: draft.meal, farmID: farmID, context: context)
        let timeZone = try farmTimeZone(farmID: farmID, context: context)
        let day = TMRLocalDay.start(of: draft.localDay, timeZone: timeZone)
        let completions = try context.fetch(FetchDescriptor<TMRMealCompletionRecord>())
        guard !completions.contains(where: {
            $0.farmID == farmID && $0.planID == plan.id && $0.penID == draft.penID &&
                $0.localDay == day && $0.meal == draft.meal && $0.deletedAt == nil
        }) else { throw TMRCommandApplyError.mealAlreadyCompleted }
        let record = TMRMealCompletionRecord(
            id: draft.id,
            farmID: farmID,
            planID: plan.id,
            planRevision: plan.revision,
            penID: draft.penID,
            localDay: day,
            meal: draft.meal,
            completedAt: draft.completedAt,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: modifiedAt
        )
        context.insert(record)
        return Result(
            entityType: .tmrMealCompletion,
            entityID: record.id,
            baseRevision: 0,
            resultingRevision: 1,
            payloadCommand: .completeMeal(draft)
        )
    }

    private static func reopenMeal(
        _ draft: TMRMealReopenDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard !draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TMRCommandApplyError.reasonRequired
        }
        guard let completion = try context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).first(where: {
            $0.id == draft.completionID && $0.farmID == farmID && $0.deletedAt == nil
        }) else { throw TMRCommandApplyError.completionNotFound }
        let base = completion.revision
        markCompletionReopened(completion, reason: draft.reason, modifiedAt: modifiedAt)
        return Result(
            entityType: .tmrMealCompletion,
            entityID: completion.id,
            baseRevision: base,
            resultingRevision: completion.revision,
            payloadCommand: .reopenMeal(draft)
        )
    }

    private static func adjustBatch(
        _ draft: TMRBatchAdjustmentDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard !draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TMRCommandApplyError.reasonRequired
        }
        let batch = try activeBatch(draft.batchID, farmID: farmID, context: context)
        try assertRevision(draft.expectedBatchRevision, current: batch.revision)
        guard batch.status != .closed else { throw TMRCommandApplyError.batchUnavailable }
        guard let delta = Decimal.stable(draft.deltaKilogramsText), delta != 0 else {
            throw FeedStockLedgerError.invalidQuantity
        }
        let currentBalance = try batchBalance(batch.id, farmID: farmID, context: context)
        let nextBalance = currentBalance + delta
        guard nextBalance >= 0 else {
            throw TMRDomainError.insufficientBatchBalance(available: currentBalance, requested: -delta)
        }
        context.insert(TMRBatchMovementRecord(
            id: draft.id,
            farmID: farmID,
            batchID: batch.id,
            kind: .adjustment,
            deltaKilogramsText: TMRDecimal.rounded(delta).stableText,
            occurredAt: draft.occurredAt,
            sourceRecordID: batch.id,
            note: draft.reason.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: modifiedAt
        ))
        updateBatch(batch, balanceAfterDelta: nextBalance, modifiedAt: modifiedAt)
        return Result(
            entityType: .tmrBatch,
            entityID: batch.id,
            baseRevision: draft.expectedBatchRevision,
            resultingRevision: batch.revision,
            payloadCommand: .adjustBatch(draft)
        )
    }

    private static func closeBatch(
        _ draft: TMRBatchCloseDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard !draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TMRCommandApplyError.reasonRequired
        }
        let batch = try activeBatch(draft.batchID, farmID: farmID, context: context)
        try assertRevision(draft.expectedBatchRevision, current: batch.revision)
        guard batch.status != .closed else { throw TMRCommandApplyError.batchUnavailable }
        let balance = try batchBalance(batch.id, farmID: farmID, context: context)
        if balance > 0, !draft.wasteRemaining {
            throw TMRCommandApplyError.nonzeroBalanceRequiresWriteOff
        }
        if balance > 0 {
            context.insert(TMRBatchMovementRecord(
                id: draft.id,
                farmID: farmID,
                batchID: batch.id,
                kind: .waste,
                deltaKilogramsText: (-balance).stableText,
                occurredAt: draft.closedAt,
                sourceRecordID: batch.id,
                note: draft.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                createdAt: modifiedAt
            ))
        }
        batch.statusRawValue = TMRBatchStatus.closed.rawValue
        batch.closedAt = draft.closedAt
        batch.revision += 1
        batch.updatedAt = modifiedAt
        return Result(
            entityType: .tmrBatch,
            entityID: batch.id,
            baseRevision: draft.expectedBatchRevision,
            resultingRevision: batch.revision,
            payloadCommand: .closeBatch(draft)
        )
    }

    private static func deleteUnusedBatch(
        _ draft: TMRBatchDeletionDraft,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard !draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TMRCommandApplyError.reasonRequired
        }
        let batch = try activeBatch(draft.batchID, farmID: farmID, context: context)
        try assertRevision(draft.expectedBatchRevision, current: batch.revision)
        let runs = try context.fetch(FetchDescriptor<TMRFeedingRunRecord>())
        guard !runs.contains(where: { $0.farmID == farmID && $0.batchID == batch.id && $0.deletedAt == nil }) else {
            throw TMRCommandApplyError.batchHasFeedingHistory
        }
        let rawConsumptions = try context.fetch(FetchDescriptor<FeedStockTransactionRecord>())
            .filter {
                $0.farmID == farmID && $0.sourceRecordID == batch.id &&
                    $0.kind == .consumption && $0.deletedAt == nil
            }
        for consumption in rawConsumptions {
            let reversalID = TMRStockLedgerIdentity.reversalID(consumptionID: consumption.id)
            if try context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).contains(where: { $0.id == reversalID }) {
                continue
            }
            context.insert(FeedStockTransactionRecord(
                id: reversalID,
                farmID: farmID,
                ingredientBatchID: consumption.ingredientBatchID,
                kind: .reversal,
                quantityText: consumption.quantityText,
                occurredAt: draft.deletedAt,
                sourceRecordID: batch.id,
                sourceLineID: consumption.sourceLineID,
                note: "删除未使用 TMR 批次冲回：\(draft.reason.trimmingCharacters(in: .whitespacesAndNewlines))"
            ))
        }
        for value in try context.fetch(FetchDescriptor<TMRBatchIngredientRecord>())
            where value.farmID == farmID && value.batchID == batch.id && value.deletedAt == nil {
            value.deletedAt = draft.deletedAt
        }
        for value in try context.fetch(FetchDescriptor<TMRBatchLoadLineRecord>())
            where value.farmID == farmID && value.batchID == batch.id && value.deletedAt == nil {
            value.deletedAt = draft.deletedAt
        }
        for value in try context.fetch(FetchDescriptor<TMRBatchMovementRecord>())
            where value.farmID == farmID && value.batchID == batch.id && value.deletedAt == nil {
            value.deletedAt = draft.deletedAt
        }
        batch.deletedAt = draft.deletedAt
        batch.revision += 1
        batch.updatedAt = modifiedAt
        return Result(
            entityType: .tmrBatch,
            entityID: batch.id,
            baseRevision: draft.expectedBatchRevision,
            resultingRevision: batch.revision,
            payloadCommand: .deleteUnusedBatch(draft)
        )
    }

    private static func acknowledgeDeviation(
        _ draft: TMRDeviationAcknowledgementDraft,
        farmID: UUID,
        accountID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> Result {
        guard !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TMRCommandApplyError.reasonRequired
        }
        guard !draft.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FarmCommandError.missingRequiredValue("偏差指纹")
        }
        let plan = try activePlan(draft.planID, farmID: farmID, context: context)
        try assertRevision(draft.planRevision, current: plan.revision)
        try assertPlanPenAndMeal(plan: plan, penID: draft.penID, meal: draft.meal, farmID: farmID, context: context)
        guard try context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>()).first(where: {
            $0.id == draft.id && $0.farmID == farmID
        }) == nil else { throw TMRCommandApplyError.duplicateIdentifier }
        let timeZone = try farmTimeZone(farmID: farmID, context: context)
        let record = TMRDeviationAcknowledgementRecord(
            id: draft.id,
            farmID: farmID,
            planID: plan.id,
            planRevision: plan.revision,
            penID: draft.penID,
            localDay: TMRLocalDay.start(of: draft.localDay, timeZone: timeZone),
            meal: draft.meal,
            fingerprint: draft.fingerprint,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
            acknowledgedAt: draft.acknowledgedAt,
            acknowledgedByAccountID: accountID.uuidString.lowercased(),
            createdAt: modifiedAt
        )
        context.insert(record)
        return Result(
            entityType: .tmrDeviationAcknowledgement,
            entityID: record.id,
            baseRevision: 0,
            resultingRevision: 1,
            payloadCommand: .acknowledgeDeviation(draft)
        )
    }

    private static func formulaSnapshot(
        formulaID: UUID,
        expectedRevision: Int,
        farmID: UUID,
        context: ModelContext
    ) throws -> (FeedRecipeRecord, TMRFormulaProfileRecord, [TMRFormulaComponentSnapshot]) {
        guard let recipe = try context.fetch(FetchDescriptor<FeedRecipeRecord>()).first(where: {
            $0.id == formulaID && $0.farmID == farmID && $0.deletedAt == nil && $0.isActive
        }), let profile = try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>()).first(where: {
            $0.recipeID == formulaID && $0.farmID == farmID && $0.deletedAt == nil
        }) else { throw TMRCommandApplyError.formulaNotFound }
        try assertRevision(expectedRevision, current: profile.formulaRevision)
        let ingredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>())
        let ingredientByID = Dictionary(uniqueKeysWithValues: ingredients
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
            .map { ($0.id, $0) })
        let components = try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>())
            .filter { $0.farmID == farmID && $0.recipeID == formulaID && $0.deletedAt == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard !components.isEmpty else { throw TMRDomainError.emptyFormula }
        let snapshots = try components.map { component -> TMRFormulaComponentSnapshot in
            guard let ingredient = ingredientByID[component.ingredientID] else {
                throw TMRCommandApplyError.ingredientNotFound
            }
            return TMRFormulaComponentSnapshot(
                id: component.id,
                ingredientID: ingredient.id,
                ingredientName: ingredient.name,
                quantityText: normalized(component.kilogramsText),
                unit: ingredient.unit,
                pricePerKilogramText: component.pricePerKilogramText,
                nutrientSnapshotJSON: component.nutrientSnapshotJSON.isEmpty
                    ? ingredient.nutrientSnapshotJSON
                    : component.nutrientSnapshotJSON,
                dryMatterText: ingredient.dryMatterText
            )
        }
        _ = try TMRCalculator.formulaDailyTotal(snapshots)
        return (recipe, profile, snapshots)
    }

    private static func validateNoPlanOverlap(
        draft: TMRFeedingPlanDraft,
        normalizedStart: Date,
        normalizedEnd: Date?,
        enabledMeals: [TMRMealPeriod],
        farmID: UUID,
        context: ModelContext
    ) throws {
        let existingPlans = try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>())
            .filter {
                $0.farmID == farmID && $0.deletedAt == nil &&
                    $0.id != draft.supersedesPlanID && $0.id != draft.id
            }
        let existingPens = try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let incomingPenIDs = Set(draft.pens.map(\.penID))
        let incomingMeals = draft.granularity == .dailySummary
            ? Set([TMRMealPeriod.allDaySummary])
            : Set(enabledMeals)
        for plan in existingPlans {
            let planEnd = plan.effectiveEndDate ?? .distantFuture
            let incomingEnd = normalizedEnd ?? .distantFuture
            guard plan.effectiveStartDate <= incomingEnd, normalizedStart <= planEnd else { continue }
            let planPenIDs = Set(existingPens.filter { $0.planID == plan.id }.map(\.penID))
            guard !incomingPenIDs.isDisjoint(with: planPenIDs) else { continue }
            let existingMeals: Set<TMRMealPeriod>
            if plan.granularity == .dailySummary {
                existingMeals = [.allDaySummary]
            } else {
                existingMeals = Set(TMRMealPeriod.actualMeals.filter { plan.share(for: $0) > 0 })
            }
            if existingMeals.contains(.allDaySummary) || incomingMeals.contains(.allDaySummary) ||
                !incomingMeals.isDisjoint(with: existingMeals) {
                throw TMRCommandApplyError.planOverlap
            }
        }
    }

    private static func validateFeedingAllocations(
        _ allocations: [TMRFeedingAllocationDraft],
        batch: TMRBatchRecord,
        meal: TMRMealPeriod,
        occurredAt: Date,
        excludingRunID: UUID?,
        reopenCompletions: [TMRMealReopenDraft] = [],
        allowCompletedMeal: Bool = false,
        farmID: UUID,
        context: ModelContext
    ) throws -> [TMRMealCompletionRecord] {
        guard !allocations.isEmpty else { throw TMRDomainError.emptyPens }
        guard Set(allocations.map(\.id)).count == allocations.count,
              Set(allocations.map(\.feedRecordID)).count == allocations.count,
              Set(allocations.map(\.penID)).count == allocations.count else {
            throw TMRCommandApplyError.duplicateIdentifier
        }
        guard Set(reopenCompletions.map(\.id)).count == reopenCompletions.count,
              Set(reopenCompletions.map(\.completionID)).count == reopenCompletions.count else {
            throw TMRCommandApplyError.duplicateIdentifier
        }
        guard reopenCompletions.allSatisfy({
            !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw TMRCommandApplyError.reasonRequired }
        let requestedReopenIDs = Set(reopenCompletions.map(\.completionID))
        var completionsToReopen: [TMRMealCompletionRecord] = []
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
        let penIDs = Set(pens.filter { $0.farmID == farmID && $0.deletedAt == nil }.map(\.id))
        let timeZone = try farmTimeZone(farmID: farmID, context: context)
        let localDay = TMRLocalDay.start(of: occurredAt, timeZone: timeZone)
        let activeCompletions = try context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).filter {
            $0.farmID == farmID && $0.localDay == localDay && $0.meal == meal && $0.deletedAt == nil
        }
        for allocation in allocations {
            guard penIDs.contains(allocation.penID) else { throw TMRCommandApplyError.penNotFound }
            guard allocation.actualHeadCountSnapshot > 0 else {
                throw TMRCommandApplyError.invalidActualHeadCount
            }
            guard let actual = Decimal.stable(allocation.actualKilogramsText), actual > 0 else {
                throw TMRDomainError.nonPositiveQuantity
            }
            if let target = allocation.targetKilogramsTextSnapshot {
                _ = try positiveOrZero(target)
            }
            let existingPenAllocations = try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>())
                .filter {
                    $0.farmID == farmID && $0.penID == allocation.penID && $0.deletedAt == nil
                }
            let existingRunIDs = Set(existingPenAllocations.map(\.runID))
            let existingMeals = try context.fetch(FetchDescriptor<TMRFeedingRunRecord>())
                .filter {
                    $0.farmID == farmID && existingRunIDs.contains($0.id) &&
                        $0.formulaID == batch.formulaID && $0.id != excludingRunID && $0.deletedAt == nil &&
                        TMRLocalDay.start(of: $0.occurredAt, timeZone: timeZone) == localDay
                }
                .map(\.meal)
            try TMRMealConflictPolicy.validate(existingMeals: existingMeals, adding: meal)
            guard let planID = allocation.planID else { continue }
            let plan = try activePlan(planID, farmID: farmID, context: context)
            if let expectedPlanRevision = allocation.planRevision {
                try assertRevision(expectedPlanRevision, current: plan.revision)
            }
            guard plan.formulaID == batch.formulaID else { throw TMRCommandApplyError.planFormulaMismatch }
            try assertPlanPenAndMeal(plan: plan, penID: allocation.penID, meal: meal, farmID: farmID, context: context)
            guard localDay >= plan.effectiveStartDate,
                  localDay <= (plan.effectiveEndDate ?? .distantFuture) else {
                throw TMRCommandApplyError.planNotFound
            }
            if let completion = activeCompletions.first(where: {
                $0.farmID == farmID && $0.planID == plan.id && $0.penID == allocation.penID &&
                    $0.localDay == localDay && $0.meal == meal && $0.deletedAt == nil
            }) {
                if allowCompletedMeal {
                    // Correcting an existing fact must preserve the completed state.
                } else if requestedReopenIDs.contains(completion.id) {
                    completionsToReopen.append(completion)
                } else {
                    throw TMRCommandApplyError.mealAlreadyCompleted
                }
            }
        }
        guard Set(completionsToReopen.map(\.id)) == requestedReopenIDs else {
            throw TMRCommandApplyError.completionNotFound
        }
        return completionsToReopen
    }

    private static func markCompletionReopened(
        _ completion: TMRMealCompletionRecord,
        reason: String,
        modifiedAt: Date
    ) {
        completion.deletedAt = modifiedAt
        completion.revision += 1
        completion.note = [
            completion.note,
            "重新打开：\(reason.trimmingCharacters(in: .whitespacesAndNewlines))"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "；")
    }

    private static func assertPlanPenAndMeal(
        plan: TMRFeedingPlanRecord,
        penID: UUID,
        meal: TMRMealPeriod,
        farmID: UUID,
        context: ModelContext
    ) throws {
        guard try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>()).contains(where: {
            $0.farmID == farmID && $0.planID == plan.id && $0.penID == penID && $0.deletedAt == nil
        }) else { throw TMRCommandApplyError.planPenMismatch }
        switch plan.granularity {
        case .dailySummary:
            guard meal == .allDaySummary else { throw TMRCommandApplyError.planMealMismatch }
        case .perMeal:
            guard meal != .allDaySummary, plan.share(for: meal) > 0 else {
                throw TMRCommandApplyError.planMealMismatch
            }
        }
    }

    private static func insertFeedingRun(
        id: UUID,
        batch: TMRBatchRecord,
        expectedBatchRevision: Int,
        occurredAt: Date,
        meal: TMRMealPeriod,
        allocations: [TMRFeedingAllocationDraft],
        note: String,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws {
        let batchIngredients = try context.fetch(FetchDescriptor<TMRBatchIngredientRecord>())
            .filter { $0.farmID == farmID && $0.batchID == batch.id && $0.deletedAt == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard !batchIngredients.isEmpty else { throw TMRDomainError.emptyFormula }
        let run = TMRFeedingRunRecord(
            id: id,
            farmID: farmID,
            batchID: batch.id,
            batchCodeSnapshot: batch.batchCode,
            formulaID: batch.formulaID,
            formulaRevision: batch.formulaRevision,
            formulaNameSnapshot: batch.formulaNameSnapshot,
            meal: meal,
            occurredAt: occurredAt,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            batchRevisionBefore: expectedBatchRevision,
            batchRevisionAfter: expectedBatchRevision + 1,
            createdAt: modifiedAt
        )
        context.insert(run)
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
        let penByID = Dictionary(uniqueKeysWithValues: pens
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
            .map { ($0.id, $0) })
        for allocationDraft in allocations {
            let feed = FeedRecord(
                id: allocationDraft.feedRecordID,
                farmID: farmID,
                penID: allocationDraft.penID,
                recipeID: batch.formulaID,
                mode: .limited,
                occurredAt: occurredAt,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                mealName: meal.displayName,
                feederName: "",
                recipeHeadCountSnapshot: batch.referenceHeadCountSnapshot,
                actualHeadCountSnapshot: allocationDraft.actualHeadCountSnapshot
            )
            context.insert(feed)
            let actual = Decimal.stable(allocationDraft.actualKilogramsText) ?? 0
            let lineAmounts = try TMRCalculator.proportionalAmounts(
                totalKilograms: actual,
                componentQuantities: batchIngredients.map(\.actualKilograms)
            )
            for index in batchIngredients.indices {
                let ingredient = batchIngredients[index]
                let lineID = StableCloudUUID.derived(
                    namespace: feed.id,
                    name: "tmr-feed-line:\(ingredient.ingredientID.uuidString.lowercased())"
                )
                context.insert(FeedRecordLine(
                    id: lineID,
                    farmID: farmID,
                    feedRecordID: feed.id,
                    ingredientID: ingredient.ingredientID,
                    kilogramsText: lineAmounts[index].stableText,
                    stockQuantityText: nil,
                    ingredientNameSnapshot: ingredient.ingredientNameSnapshot,
                    ingredientBatchID: nil,
                    ingredientBatchNameSnapshot: nil,
                    pricePerKilogramTextSnapshot: ingredient.pricePerKilogramTextSnapshot,
                    nutrientSnapshotJSON: ingredient.nutrientSnapshotJSON,
                    unitSnapshot: ingredient.unitSnapshot,
                    dryMatterTextSnapshot: ingredient.dryMatterTextSnapshot
                ))
            }
            context.insert(TMRFeedingAllocationRecord(
                id: allocationDraft.id,
                farmID: farmID,
                runID: run.id,
                batchID: batch.id,
                feedRecordID: feed.id,
                planID: allocationDraft.planID,
                planRevision: allocationDraft.planRevision,
                penID: allocationDraft.penID,
                penNameSnapshot: penByID[allocationDraft.penID]?.name ?? "历史圈舍",
                actualHeadCountSnapshot: allocationDraft.actualHeadCountSnapshot,
                actualKilogramsText: normalized(allocationDraft.actualKilogramsText),
                targetKilogramsTextSnapshot: allocationDraft.targetKilogramsTextSnapshot.map(normalized),
                createdAt: modifiedAt
            ))
        }
        let total = try totalActual(allocations)
        context.insert(TMRBatchMovementRecord(
            id: StableCloudUUID.derived(namespace: run.id, name: "tmr-feeding-movement"),
            farmID: farmID,
            batchID: batch.id,
            kind: .feeding,
            deltaKilogramsText: (-total).stableText,
            occurredAt: occurredAt,
            sourceRecordID: run.id,
            note: "\(meal.displayName)投喂",
            createdAt: modifiedAt
        ))
    }

    private static func retireRun(
        _ run: TMRFeedingRunRecord,
        reason: String,
        reversalID: UUID,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws {
        let allocations = try activeAllocations(runID: run.id, farmID: farmID, context: context)
        let reversed = allocations.reduce(Decimal.zero) { $0 + $1.actualKilograms }
        for allocation in allocations {
            allocation.deletedAt = modifiedAt
            if let feed = try context.fetch(FetchDescriptor<FeedRecord>()).first(where: {
                $0.id == allocation.feedRecordID && $0.farmID == farmID && $0.deletedAt == nil
            }) {
                feed.deletedAt = modifiedAt
                feed.revision += 1
                for line in try context.fetch(FetchDescriptor<FeedRecordLine>())
                    where line.farmID == farmID && line.feedRecordID == feed.id && line.deletedAt == nil {
                    line.deletedAt = modifiedAt
                }
            }
        }
        run.deletedAt = modifiedAt
        run.revision += 1
        run.updatedAt = modifiedAt
        context.insert(TMRBatchMovementRecord(
            id: reversalID,
            farmID: farmID,
            batchID: run.batchID,
            kind: .reversal,
            deltaKilogramsText: reversed.stableText,
            occurredAt: modifiedAt,
            sourceRecordID: run.id,
            sourceMovementID: StableCloudUUID.derived(namespace: run.id, name: "tmr-feeding-movement"),
            note: reason.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: modifiedAt
        ))
    }

    private static func activeAllocations(
        runID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> [TMRFeedingAllocationRecord] {
        try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>())
            .filter { $0.farmID == farmID && $0.runID == runID && $0.deletedAt == nil }
    }

    private static func activeRun(
        _ id: UUID,
        batchID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> TMRFeedingRunRecord {
        guard let run = try context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID && $0.batchID == batchID && $0.deletedAt == nil
        }) else { throw TMRCommandApplyError.runNotFound }
        return run
    }

    private static func activeBatch(
        _ id: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> TMRBatchRecord {
        guard let batch = try context.fetch(FetchDescriptor<TMRBatchRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID && $0.deletedAt == nil
        }) else { throw TMRCommandApplyError.batchNotFound }
        return batch
    }

    private static func activePlan(
        _ id: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> TMRFeedingPlanRecord {
        guard let plan = try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID && $0.deletedAt == nil
        }) else { throw TMRCommandApplyError.planNotFound }
        return plan
    }

    private static func batchBalance(
        _ batchID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> Decimal {
        let movements = try context.fetch(FetchDescriptor<TMRBatchMovementRecord>())
            .filter { $0.farmID == farmID && $0.batchID == batchID }
        return TMRCalculator.batchBalance(movements: movements)
    }

    private static func updateBatch(
        _ batch: TMRBatchRecord,
        balanceAfterDelta: Decimal,
        modifiedAt: Date
    ) {
        batch.statusRawValue = balanceAfterDelta == 0
            ? TMRBatchStatus.exhausted.rawValue
            : TMRBatchStatus.available.rawValue
        batch.revision += 1
        batch.updatedAt = modifiedAt
    }

    private static func totalActual(_ allocations: [TMRFeedingAllocationDraft]) throws -> Decimal {
        let values = try allocations.map { allocation -> Decimal in
            guard let value = Decimal.stable(allocation.actualKilogramsText), value > 0 else {
                throw TMRDomainError.nonPositiveQuantity
            }
            return value
        }
        return TMRDecimal.rounded(values.reduce(0, +))
    }

    private static func weightedPriceForLoads(
        _ loads: [TMRBatchLoadDraft],
        stockByID: [UUID: FeedIngredientBatchRecord]
    ) -> Decimal? {
        var cost = Decimal.zero
        var weight = Decimal.zero
        for load in loads {
            guard let batch = stockByID[load.ingredientBatchID],
                  let kilograms = Decimal.stable(load.actualKilogramsText),
                  let price = Decimal.stable(batch.pricePerKilogramText) else { continue }
            cost += kilograms * price
            weight += kilograms
        }
        guard weight > 0 else { return nil }
        return TMRDecimal.rounded(cost / weight, scale: 4)
    }

    private static func resolvedBatchCode(
        requested: String?,
        producedAt: Date,
        farmID: UUID,
        context: ModelContext
    ) throws -> String {
        let existing = try context.fetch(FetchDescriptor<TMRBatchRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        if let requested {
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw FarmCommandError.missingRequiredValue("TMR 批次号") }
            guard !existing.contains(where: { $0.batchCode.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw TMRCommandApplyError.duplicateBatchCode
            }
            return trimmed
        }
        let timeZone = try farmTimeZone(farmID: farmID, context: context)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        let prefix = "TMR-\(formatter.string(from: producedAt))-"
        let sequence = existing.compactMap { record -> Int? in
            guard record.batchCode.hasPrefix(prefix) else { return nil }
            return Int(record.batchCode.dropFirst(prefix.count))
        }.max().map { $0 + 1 } ?? 1
        return prefix + String(format: "%03d", sequence)
    }

    private static func farmTimeZone(farmID: UUID, context: ModelContext) throws -> TimeZone {
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: {
            $0.id == farmID && $0.deletedAt == nil
        }) else { throw FarmCommandError.missingRequiredValue("当前牧场") }
        return TimeZone(identifier: farm.timeZoneIdentifier) ?? TimeZone(identifier: "Asia/Shanghai")!
    }

    private static func validateCutoffs(morning: Int, noon: Int, evening: Int, allDay: Int) throws {
        guard (0...1_439).contains(morning), (0...1_439).contains(noon),
              (0...1_439).contains(evening), (0...1_439).contains(allDay),
              morning < noon, noon < evening, evening <= allDay else {
            throw TMRCommandApplyError.invalidCutoff
        }
    }

    private static func tolerance(_ text: String) throws -> Decimal {
        guard let value = Decimal.stable(text), value >= 0, value <= 100 else {
            throw TMRCommandApplyError.invalidTolerance
        }
        return value
    }

    private static func positiveOrZero(_ text: String) throws -> Decimal {
        guard let value = Decimal.stable(text), value >= 0 else {
            throw TMRDomainError.nonPositiveQuantity
        }
        return value
    }

    private static func normalized(_ text: String) -> String {
        (Decimal.stable(text) ?? 0).stableText
    }

    private static func assertRevision(_ expected: Int, current: Int) throws {
        guard expected == current else { throw TMRCommandApplyError.revisionConflict(current: current) }
    }
}
