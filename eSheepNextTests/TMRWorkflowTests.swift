import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class TMRWorkflowTests: XCTestCase {
    func testFormulaScalingPenAllocationAndMealTargetsUseExactDecimalMath() throws {
        XCTAssertEqual(
            try TMRCalculator.targetGroupDailyTotal(
                formulaDailyTotal: 100,
                basis: .wholeGroupDaily,
                scaleMode: .scaledByHeadCount,
                referenceHeadCount: 100,
                targetHeadCount: 120
            ),
            120
        )
        XCTAssertEqual(
            try TMRCalculator.targetGroupDailyTotal(
                formulaDailyTotal: 100,
                basis: .wholeGroupDaily,
                scaleMode: .fixedWholeAmount,
                referenceHeadCount: 100,
                targetHeadCount: 120
            ),
            100
        )
        XCTAssertEqual(
            try TMRCalculator.targetGroupDailyTotal(
                formulaDailyTotal: 1,
                basis: .perHeadDaily,
                scaleMode: .fixedWholeAmount,
                referenceHeadCount: nil,
                targetHeadCount: 120
            ),
            120,
            "每只口径始终按目标羊数计算，不能被固定整群开关改写"
        )

        let firstPenID = UUID()
        let secondPenID = UUID()
        let allocations = try TMRCalculator.allocateToPens(
            totalKilograms: 120,
            inputs: [
                TMRPenAllocationInput(id: firstPenID, headCount: 70),
                TMRPenAllocationInput(id: secondPenID, headCount: 50)
            ],
            mode: .dynamicHeadCount
        )
        XCTAssertEqual(allocations.map(\.kilograms), [70, 50])
        XCTAssertEqual(allocations.reduce(0) { $0 + $1.kilograms }, 120)
        let fixedAllocations = try TMRCalculator.allocateToPens(
            totalKilograms: 120,
            inputs: [
                TMRPenAllocationInput(id: firstPenID, headCount: 70, fixedShare: Decimal(string: "0.6")),
                TMRPenAllocationInput(id: secondPenID, headCount: 50, fixedShare: Decimal(string: "0.4"))
            ],
            mode: .fixedShare
        )
        XCTAssertEqual(fixedAllocations.map(\.kilograms), [72, 48])
        XCTAssertEqual(fixedAllocations.reduce(0) { $0 + $1.kilograms }, 120)

        let shares = try TMRMealShares(morning: Decimal(string: "0.4")!, noon: Decimal(string: "0.35")!, evening: Decimal(string: "0.25")!)
        XCTAssertEqual(TMRCalculator.mealTarget(dailyTarget: 120, meal: .morning, shares: shares), 48)
        XCTAssertEqual(TMRCalculator.mealTarget(dailyTarget: 120, meal: .noon, shares: shares), 42)
        XCTAssertEqual(TMRCalculator.mealTarget(dailyTarget: 120, meal: .evening, shares: shares), 30)
    }

    func testDeviationDoesNotReportLowBeforeCompletionOrCutoff() {
        XCTAssertEqual(
            TMRCalculator.evaluateDeviation(
                targetKilograms: 48,
                actualKilograms: 20,
                tolerancePercent: 5,
                isCompleted: false,
                cutoffReached: false
            ).status,
            .inProgress
        )
        XCTAssertEqual(
            TMRCalculator.evaluateDeviation(
                targetKilograms: 48,
                actualKilograms: 20,
                tolerancePercent: 5,
                isCompleted: false,
                cutoffReached: true
            ).status,
            .low
        )
        XCTAssertEqual(
            TMRCalculator.evaluateDeviation(
                targetKilograms: 48,
                actualKilograms: 55,
                tolerancePercent: 5,
                isCompleted: false,
                cutoffReached: false
            ).status,
            .high
        )
    }

    func testAllDaySummaryCannotMixWithActualMeals() throws {
        XCTAssertNoThrow(try TMRMealConflictPolicy.validate(existingMeals: [.morning], adding: .noon))
        XCTAssertThrowsError(try TMRMealConflictPolicy.validate(existingMeals: [.morning], adding: .allDaySummary)) { error in
            XCTAssertEqual(error as? TMRDomainError, .incompatibleAllDayAndMealRecords)
        }
        XCTAssertThrowsError(try TMRMealConflictPolicy.validate(existingMeals: [.allDaySummary], adding: .evening)) { error in
            XCTAssertEqual(error as? TMRDomainError, .incompatibleAllDayAndMealRecords)
        }
    }

    func testAllDayFeedingBlocksMealRecordsUntilTheWholeRunIsReversed() throws {
        let fixture = try makeFixture()
        let formulaID = try saveFormula(in: fixture)
        let batchID = try produceBatch(formulaID: formulaID, in: fixture)
        let allDayRunID = UUID()
        try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                id: allDayRunID,
                batchID: batchID,
                expectedBatchRevision: 1,
                occurredAt: fixture.occurredAt,
                meal: .allDaySummary,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: fixture.firstPen.id,
                        actualHeadCountSnapshot: 70,
                        actualKilogramsText: "40"
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )

        XCTAssertThrowsError(try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 2,
                occurredAt: fixture.occurredAt.addingTimeInterval(60),
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: fixture.firstPen.id,
                        actualHeadCountSnapshot: 70,
                        actualKilogramsText: "20"
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? TMRDomainError, .incompatibleAllDayAndMealRecords)
        }
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 80)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).filter { $0.deletedAt == nil }.count, 1)

        try fixture.service.execute(
            .tmr(.reverseFeedingRun(TMRFeedingReversalDraft(
                runID: allDayRunID,
                batchID: batchID,
                expectedBatchRevision: 2,
                reason: "改为分顿录入"
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 3,
                occurredAt: fixture.occurredAt.addingTimeInterval(60),
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: fixture.firstPen.id,
                        actualHeadCountSnapshot: 70,
                        actualKilogramsText: "20"
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 100)
    }

    func testProductionAndSplitFeedingMaintainSeparateRawAndTMRLedgers() throws {
        let fixture = try makeFixture()
        let formulaID = try saveFormula(in: fixture)
        let batchID = try produceBatch(formulaID: formulaID, in: fixture)

        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.cornBatch, context: fixture.context)), 28)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.silageBatch, context: fixture.context)), 52)
        XCTAssertEqual(try rawStockTransactions(in: fixture).count, 2)
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 120)

        let morningRunID = UUID()
        try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                id: morningRunID,
                batchID: batchID,
                expectedBatchRevision: 1,
                occurredAt: fixture.occurredAt,
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: fixture.firstPen.id,
                        actualHeadCountSnapshot: 70,
                        actualKilogramsText: "28"
                    ),
                    TMRFeedingAllocationDraft(
                        penID: fixture.secondPen.id,
                        actualHeadCountSnapshot: 50,
                        actualKilogramsText: "20"
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 72)
        XCTAssertEqual(try rawStockTransactions(in: fixture).count, 2, "从成品批次投喂不能再次扣原料库存")

        let noonRunID = UUID()
        try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                id: noonRunID,
                batchID: batchID,
                expectedBatchRevision: 2,
                occurredAt: fixture.occurredAt.addingTimeInterval(4 * 3_600),
                meal: .noon,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: fixture.firstPen.id,
                        actualHeadCountSnapshot: 70,
                        actualKilogramsText: "25"
                    ),
                    TMRFeedingAllocationDraft(
                        penID: fixture.secondPen.id,
                        actualHeadCountSnapshot: 50,
                        actualKilogramsText: "17"
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 30)
        XCTAssertEqual(try rawStockTransactions(in: fixture).count, 2)

        let projectedLines = try fixture.context.fetch(FetchDescriptor<FeedRecordLine>())
            .filter { $0.deletedAt == nil }
        XCTAssertEqual(projectedLines.count, 8)
        XCTAssertTrue(projectedLines.allSatisfy { $0.ingredientBatchID == nil && $0.stockQuantityText == nil })

        try fixture.service.execute(
            .tmr(.reverseFeedingRun(TMRFeedingReversalDraft(
                runID: noonRunID,
                batchID: batchID,
                expectedBatchRevision: 3,
                reason: "撤销误录的中顿"
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 72)
        XCTAssertEqual(try rawStockTransactions(in: fixture).count, 2, "删除 TMR 投喂只能冲回成品余额")
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).filter { $0.deletedAt == nil }.map(\.id),
            [morningRunID]
        )
    }

    func testEventHistoryDeletionReversesWholeTMRRunAndRestoresOnlyFinishedGoods() throws {
        let fixture = try makeFixture()
        let formulaID = try saveFormula(in: fixture)
        let batchID = try produceBatch(formulaID: formulaID, in: fixture)
        let runID = UUID()
        let firstFeedID = UUID()

        try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                id: runID,
                batchID: batchID,
                expectedBatchRevision: 1,
                occurredAt: fixture.occurredAt,
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(
                        feedRecordID: firstFeedID,
                        penID: fixture.firstPen.id,
                        actualHeadCountSnapshot: 70,
                        actualKilogramsText: "28"
                    ),
                    TMRFeedingAllocationDraft(
                        penID: fixture.secondPen.id,
                        actualHeadCountSnapshot: 50,
                        actualKilogramsText: "20"
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 72)
        let rawTransactionCount = try rawStockTransactions(in: fixture).count

        let event = FarmEventSnapshot(
            id: firstFeedID,
            entityType: .feed,
            category: .feeding,
            occurredAt: fixture.occurredAt,
            recordedAt: fixture.occurredAt,
            title: "TMR 投喂",
            subject: fixture.firstPen.name,
            detail: "28 kg",
            note: "",
            fields: []
        )
        let command = try FarmEventDeletionCommandResolver.command(
            for: event,
            reason: "重复录入",
            farmID: fixture.farmContext.farmID,
            context: fixture.context
        )
        try fixture.service.execute(command, in: fixture.farmContext, context: fixture.context)

        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 120)
        XCTAssertEqual(try rawStockTransactions(in: fixture).count, rawTransactionCount)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>()).allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<FeedRecord>()).allSatisfy { $0.deletedAt != nil })
    }

    func testStaleBatchRevisionRejectsWholeMultiPenRunWithoutPartialFacts() throws {
        let fixture = try makeFixture()
        let formulaID = try saveFormula(in: fixture)
        let batchID = try produceBatch(formulaID: formulaID, in: fixture)

        XCTAssertThrowsError(try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 0,
                occurredAt: fixture.occurredAt,
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(penID: fixture.firstPen.id, actualHeadCountSnapshot: 70, actualKilogramsText: "20"),
                    TMRFeedingAllocationDraft(penID: fixture.secondPen.id, actualHeadCountSnapshot: 50, actualKilogramsText: "20")
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? TMRCommandApplyError, .revisionConflict(current: 1))
        }
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<FeedRecord>()).isEmpty)
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 120)
    }

    func testBatchProducedFromPlanKeepsPlanFormulaSnapshotAndSelectedMealsAfterFormulaRevision() throws {
        let fixture = try makeFixture()
        fixture.corn.nutrientSnapshotJSON = FeedNutritionCodec.encode(FeedNutrients(dryMatter: 90, crudeProtein: 10))
        fixture.corn.dryMatterText = "90"
        let formulaID = try saveFormula(in: fixture)
        let planID = UUID()
        let day = TMRLocalDay.start(
            of: fixture.occurredAt,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        try fixture.service.execute(
            .tmr(.saveFeedingPlan(TMRFeedingPlanDraft(
                id: planID,
                formulaID: formulaID,
                expectedFormulaRevision: 1,
                scheduleKind: .oneTime,
                effectiveStartDate: day,
                scaleMode: .fixedWholeAmount,
                allocationMode: .fixedShare,
                granularity: .perMeal,
                morningShareText: "0.4",
                noonShareText: "0.35",
                eveningShareText: "0.25",
                tolerancePercentText: "5",
                morningCutoffMinute: 540,
                noonCutoffMinute: 840,
                eveningCutoffMinute: 1_200,
                allDayCutoffMinute: 1_320,
                monitoringEnabled: true,
                pens: [TMRPlanPenDraft(penID: fixture.firstPen.id, fixedShareText: "1")]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )

        let oldComponents = try fixture.context.fetch(FetchDescriptor<FeedRecipeComponentRecord>())
            .filter { $0.recipeID == formulaID && $0.deletedAt == nil }
        let cornComponent = try XCTUnwrap(oldComponents.first { $0.ingredientID == fixture.corn.id })
        let silageComponent = try XCTUnwrap(oldComponents.first { $0.ingredientID == fixture.silage.id })
        fixture.corn.name = "新版玉米"
        fixture.corn.nutrientSnapshotJSON = FeedNutritionCodec.encode(FeedNutrients(dryMatter: 80, crudeProtein: 20))
        fixture.corn.dryMatterText = "80"
        try fixture.service.execute(
            .tmr(.saveFormula(TMRFormulaDraft(
                id: formulaID,
                expectedRevision: 1,
                name: "育肥 TMR 新版",
                quantityBasis: .wholeGroupDaily,
                referenceHeadCount: 100,
                components: [
                    TMRFormulaComponentDraft(id: cornComponent.id, ingredientID: fixture.corn.id, quantityText: "60"),
                    TMRFormulaComponentDraft(id: silageComponent.id, ingredientID: fixture.silage.id, quantityText: "60")
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )

        let batchID = UUID()
        try fixture.service.execute(
            .tmr(.produceBatch(TMRBatchProductionDraft(
                id: batchID,
                formulaID: formulaID,
                expectedFormulaRevision: 1,
                sourcePlanID: planID,
                sourcePlanRevision: 1,
                sourcePlanDate: day,
                sourceMeals: [.morning, .noon],
                producedAt: fixture.occurredAt,
                ingredients: [
                    TMRBatchIngredientDraft(
                        ingredientID: fixture.corn.id,
                        plannedKilogramsText: "54",
                        loadLines: [TMRBatchLoadDraft(ingredientBatchID: fixture.cornBatch.id, actualKilogramsText: "54")]
                    ),
                    TMRBatchIngredientDraft(
                        ingredientID: fixture.silage.id,
                        plannedKilogramsText: "36",
                        loadLines: [TMRBatchLoadDraft(ingredientBatchID: fixture.silageBatch.id, actualKilogramsText: "36")]
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )

        let batch = try XCTUnwrap(
            try fixture.context.fetch(FetchDescriptor<TMRBatchRecord>()).first { $0.id == batchID }
        )
        XCTAssertEqual(batch.formulaRevision, 1)
        XCTAssertEqual(batch.formulaNameSnapshot, "育肥 TMR")
        XCTAssertEqual(batch.sourcePlanID, planID)
        XCTAssertEqual(batch.sourcePlanRevision, 1)
        XCTAssertEqual(batch.sourcePlanDate, day)
        XCTAssertEqual(batch.sourcePlanMeals, [.morning, .noon])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: batch.componentSnapshot.map { ($0.ingredientID, $0.quantity) }),
            [fixture.corn.id: 72, fixture.silage.id: 48]
        )
        XCTAssertEqual(batch.producedKilograms, 90)
        let producedCorn = try XCTUnwrap(
            try fixture.context.fetch(FetchDescriptor<TMRBatchIngredientRecord>()).first {
                $0.batchID == batchID && $0.ingredientID == fixture.corn.id
            }
        )
        XCTAssertEqual(producedCorn.ingredientNameSnapshot, "玉米")
        XCTAssertEqual(producedCorn.dryMatterTextSnapshot, "90")
        XCTAssertEqual(FeedNutritionCodec.decode(producedCorn.nutrientSnapshotJSON).crudeProtein, 10)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.cornBatch, context: fixture.context)), 46)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.silageBatch, context: fixture.context)), 64)
    }

    func testDeletingUnusedBatchRestoresRawStockAndUsedBatchCannotBeDeleted() throws {
        let unused = try makeFixture()
        let unusedFormulaID = try saveFormula(in: unused)
        let unusedBatchID = try produceBatch(formulaID: unusedFormulaID, in: unused)
        try unused.service.execute(
            .tmr(.deleteUnusedBatch(TMRBatchDeletionDraft(
                batchID: unusedBatchID,
                expectedBatchRevision: 1,
                reason: "本锅装料错误"
            ))),
            in: unused.farmContext,
            context: unused.context
        )
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: unused.cornBatch, context: unused.context)), 100)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: unused.silageBatch, context: unused.context)), 100)
        XCTAssertNotNil(try unused.context.fetch(FetchDescriptor<TMRBatchRecord>()).first { $0.id == unusedBatchID }?.deletedAt)

        let used = try makeFixture()
        let usedFormulaID = try saveFormula(in: used)
        let usedBatchID = try produceBatch(formulaID: usedFormulaID, in: used)
        try used.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: usedBatchID,
                expectedBatchRevision: 1,
                occurredAt: used.occurredAt,
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(penID: used.firstPen.id, actualHeadCountSnapshot: 70, actualKilogramsText: "10")
                ]
            ))),
            in: used.farmContext,
            context: used.context
        )
        XCTAssertThrowsError(try used.service.execute(
            .tmr(.deleteUnusedBatch(TMRBatchDeletionDraft(
                batchID: usedBatchID,
                expectedBatchRevision: 2,
                reason: "尝试删除已使用批次"
            ))),
            in: used.farmContext,
            context: used.context
        )) { error in
            XCTAssertEqual(error as? TMRCommandApplyError, .batchHasFeedingHistory)
        }
        XCTAssertEqual(try balance(batchID: usedBatchID, in: used.context), 110)
        XCTAssertNil(try used.context.fetch(FetchDescriptor<TMRBatchRecord>()).first { $0.id == usedBatchID }?.deletedAt)
    }

    func testMonitoringAggregatesRepeatedMealRunsAndAcknowledgesOnlyCurrentFingerprint() throws {
        let fixture = try makeFixture(includesSheep: true)
        let formulaID = try saveFormula(in: fixture)
        let batchID = try produceBatch(formulaID: formulaID, in: fixture)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = TMRLocalDay.start(of: fixture.occurredAt, timeZone: timeZone)
        let planID = UUID()

        try fixture.service.execute(
            .tmr(.saveMonitoringRule(TMRMonitoringRuleDraft(confirmsMonitoring: true))),
            in: fixture.farmContext,
            context: fixture.context
        )
        try fixture.service.execute(
            .tmr(.saveFeedingPlan(TMRFeedingPlanDraft(
                id: planID,
                formulaID: formulaID,
                expectedFormulaRevision: 1,
                scheduleKind: .continuous,
                effectiveStartDate: day,
                scaleMode: .fixedWholeAmount,
                allocationMode: .fixedShare,
                granularity: .perMeal,
                morningShareText: "0.4",
                noonShareText: "0.35",
                eveningShareText: "0.25",
                tolerancePercentText: "5",
                morningCutoffMinute: 540,
                noonCutoffMinute: 840,
                eveningCutoffMinute: 1_200,
                allDayCutoffMinute: 1_320,
                monitoringEnabled: true,
                pens: [
                    TMRPlanPenDraft(penID: fixture.firstPen.id, fixedShareText: "0.5"),
                    TMRPlanPenDraft(penID: fixture.secondPen.id, fixedShareText: "0.5")
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )

        let firstRunTime = TMRLocalDay.cutoff(for: day, minuteOfDay: 480, timeZone: timeZone)
        for (index, kilograms) in ["10", "14"].enumerated() {
            try fixture.service.execute(
                .tmr(.recordFeeding(TMRFeedingRunDraft(
                    batchID: batchID,
                    expectedBatchRevision: index + 1,
                    occurredAt: firstRunTime.addingTimeInterval(Double(index * 300)),
                    meal: .morning,
                    allocations: [
                        TMRFeedingAllocationDraft(
                            penID: fixture.firstPen.id,
                            planID: planID,
                            planRevision: 1,
                            actualHeadCountSnapshot: 1,
                            actualKilogramsText: kilograms
                        )
                    ]
                ))),
                in: fixture.farmContext,
                context: fixture.context
            )
        }

        let now = TMRLocalDay.cutoff(for: day, minuteOfDay: 541, timeZone: timeZone)
        let snapshot = try TMRMonitoringEngine.load(
            farmID: fixture.farmContext.farmID,
            localDay: day,
            now: now,
            context: fixture.context
        )
        let firstMorning = try XCTUnwrap(snapshot.rows.first {
            $0.penID == fixture.firstPen.id && $0.meal == .morning
        })
        XCTAssertEqual(firstMorning.targetKilograms, 24)
        XCTAssertEqual(firstMorning.actualKilograms, 24)
        XCTAssertEqual(firstMorning.status, .normal)
        XCTAssertEqual(firstMorning.runIDs.count, 2, "同一顿多次追加必须累计，不能只取最后一条")

        let secondMorning = try XCTUnwrap(snapshot.rows.first {
            $0.penID == fixture.secondPen.id && $0.meal == .morning
        })
        XCTAssertEqual(secondMorning.targetKilograms, 24)
        XCTAssertEqual(secondMorning.actualKilograms, 0)
        XCTAssertEqual(secondMorning.status, .notFed)
        XCTAssertFalse(secondMorning.isAcknowledged)
        let alerts = TMRMonitoringAlertAdapter.alerts(from: snapshot)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.kind, .tmrNotFed)
        XCTAssertEqual(alerts.first?.subjectID, fixture.secondPen.id)

        try fixture.service.execute(
            .tmr(.acknowledgeDeviation(TMRDeviationAcknowledgementDraft(
                planID: planID,
                planRevision: 1,
                penID: fixture.secondPen.id,
                localDay: day,
                meal: .morning,
                fingerprint: secondMorning.fingerprint,
                note: "设备维修，已人工确认"
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        let acknowledged = try TMRMonitoringEngine.load(
            farmID: fixture.farmContext.farmID,
            localDay: day,
            now: now,
            context: fixture.context
        )
        XCTAssertTrue(try XCTUnwrap(acknowledged.rows.first {
            $0.penID == fixture.secondPen.id && $0.meal == .morning
        }).isAcknowledged)
        XCTAssertTrue(TMRMonitoringAlertAdapter.alerts(from: acknowledged).isEmpty)

        try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 3,
                occurredAt: now,
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: fixture.secondPen.id,
                        planID: planID,
                        planRevision: 1,
                        actualHeadCountSnapshot: 1,
                        actualKilogramsText: "24"
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        let supplemented = try TMRMonitoringEngine.load(
            farmID: fixture.farmContext.farmID,
            localDay: day,
            now: now,
            context: fixture.context
        )
        let supplementedSecondMorning = try XCTUnwrap(supplemented.rows.first {
            $0.penID == fixture.secondPen.id && $0.meal == .morning
        })
        XCTAssertEqual(supplementedSecondMorning.status, .normal)
        XCTAssertFalse(supplementedSecondMorning.isAcknowledged, "数据变化后旧指纹确认不能沿用")
        XCTAssertTrue(TMRMonitoringAlertAdapter.alerts(from: supplemented).isEmpty, "补录达标后旧漏喂提醒必须自动消失")
    }

    func testAppendingToCompletedMealRequiresConfirmationAndReopensAtomicallyWithFeeding() throws {
        let fixture = try makeFixture()
        let formulaID = try saveFormula(in: fixture)
        let batchID = try produceBatch(formulaID: formulaID, in: fixture)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = TMRLocalDay.start(of: fixture.occurredAt, timeZone: timeZone)
        let planID = UUID()
        try fixture.service.execute(
            .tmr(.saveFeedingPlan(TMRFeedingPlanDraft(
                id: planID,
                formulaID: formulaID,
                expectedFormulaRevision: 1,
                scheduleKind: .continuous,
                effectiveStartDate: day,
                scaleMode: .fixedWholeAmount,
                allocationMode: .fixedShare,
                granularity: .perMeal,
                morningShareText: "0.4",
                noonShareText: "0.35",
                eveningShareText: "0.25",
                tolerancePercentText: "5",
                morningCutoffMinute: 540,
                noonCutoffMinute: 840,
                eveningCutoffMinute: 1_200,
                allDayCutoffMinute: 1_320,
                monitoringEnabled: true,
                pens: [TMRPlanPenDraft(penID: fixture.firstPen.id, fixedShareText: "1")]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )

        let completionID = UUID()
        try fixture.service.execute(
            .tmr(.completeMeal(TMRMealCompletionDraft(
                id: completionID,
                planID: planID,
                expectedPlanRevision: 1,
                penID: fixture.firstPen.id,
                localDay: day,
                meal: .morning,
                completedAt: fixture.occurredAt
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        let allocation = TMRFeedingAllocationDraft(
            penID: fixture.firstPen.id,
            planID: planID,
            planRevision: 1,
            actualHeadCountSnapshot: 70,
            actualKilogramsText: "10",
            targetKilogramsTextSnapshot: "48"
        )

        XCTAssertThrowsError(try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 1,
                occurredAt: fixture.occurredAt,
                meal: .morning,
                allocations: [allocation]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? TMRCommandApplyError, .mealAlreadyCompleted)
        }
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).isEmpty)
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 120)

        try fixture.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 1,
                occurredAt: fixture.occurredAt,
                meal: .morning,
                allocations: [allocation],
                reopenCompletions: [
                    TMRMealReopenDraft(
                        completionID: completionID,
                        reason: "确认追加本顿投料"
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )

        let completion = try XCTUnwrap(
            try fixture.context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).first { $0.id == completionID }
        )
        XCTAssertNotNil(completion.deletedAt)
        XCTAssertEqual(completion.revision, 2)
        XCTAssertTrue(completion.note.contains("确认追加本顿投料"))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<TMRFeedingRunRecord>()), 1)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FeedRecord>()), 1)
        XCTAssertEqual(try balance(batchID: batchID, in: fixture.context), 110)

        let operations = try fixture.context.fetch(FetchDescriptor<DomainOperation>())
        XCTAssertEqual(operations.filter { $0.kindRawValue == DomainOperationKind.recordTMRFeeding.rawValue }.count, 1)
        XCTAssertTrue(operations.allSatisfy { $0.kindRawValue != DomainOperationKind.reopenTMRMeal.rawValue })
    }

    func testTMRCloudPayloadRoundTripAndRemoteReplayAreIdempotent() throws {
        let source = try makeFixture()
        let formulaID = try saveFormula(in: source)
        let batchID = try produceBatch(formulaID: formulaID, in: source)
        try source.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 1,
                occurredAt: source.occurredAt,
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: source.firstPen.id,
                        actualHeadCountSnapshot: 10,
                        actualKilogramsText: "10"
                    )
                ]
            ))),
            in: source.farmContext,
            context: source.context
        )

        let operations = try source.context.fetch(FetchDescriptor<DomainOperation>())
        let formulaOperation = try XCTUnwrap(operations.first { $0.kindRawValue == DomainOperationKind.saveTMRFormula.rawValue })
        let productionOperation = try XCTUnwrap(operations.first { $0.kindRawValue == DomainOperationKind.produceTMRBatch.rawValue })
        let feedingOperation = try XCTUnwrap(operations.first { $0.kindRawValue == DomainOperationKind.recordTMRFeeding.rawValue })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedPayload = try decoder.decode(FarmCommandCloudPayload.self, from: feedingOperation.payload)
        guard case .recordFeeding(let decodedDraft) = decodedPayload.tmrCommand else {
            return XCTFail("TMR 云载荷未能解码为投喂命令")
        }
        XCTAssertEqual(decodedDraft.batchID, batchID)
        XCTAssertEqual(decodedDraft.allocations.count, 1)

        let targetContainer = try AppSchema.makeContainer(name: "tmr-remote-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let target = ModelContext(targetContainer)
        target.insert(FarmRecord(id: source.farmContext.farmID, ownerAccountID: source.farmContext.accountID, name: "远端恢复场"))
        target.insert(PenRecord(id: source.firstPen.id, farmID: source.farmContext.farmID, name: source.firstPen.name))
        target.insert(PenRecord(id: source.secondPen.id, farmID: source.farmContext.farmID, name: source.secondPen.name))
        target.insert(FeedIngredientRecord(id: source.corn.id, farmID: source.farmContext.farmID, name: source.corn.name, unit: "千克", nutrientSnapshotJSON: "{}", kind: .custom))
        target.insert(FeedIngredientRecord(id: source.silage.id, farmID: source.farmContext.farmID, name: source.silage.name, unit: "千克", nutrientSnapshotJSON: "{}", kind: .custom))
        target.insert(FeedIngredientBatchRecord(id: source.cornBatch.id, farmID: source.farmContext.farmID, ingredientID: source.corn.id, batchName: source.cornBatch.batchName, pricePerKilogramText: "2", stockWeightConfirmed: true, initialKilogramsText: "100", remainingKilogramsText: "100", note: "", isActive: true))
        target.insert(FeedIngredientBatchRecord(id: source.silageBatch.id, farmID: source.farmContext.farmID, ingredientID: source.silage.id, batchName: source.silageBatch.batchName, pricePerKilogramText: "1", stockWeightConfirmed: true, initialKilogramsText: "100", remainingKilogramsText: "100", note: "", isActive: true))
        try target.save()

        let remote = RemoteDomainApplyService()
        XCTAssertEqual(try remote.apply(envelope(formulaOperation), context: target), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try remote.apply(envelope(productionOperation), context: target), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try remote.apply(envelope(feedingOperation), context: target), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try remote.apply(envelope(feedingOperation), context: target), .duplicate)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<TMRFeedingRunRecord>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<FeedRecord>()), 1)
        let targetMovements = try target.fetch(FetchDescriptor<TMRBatchMovementRecord>()).filter { $0.batchID == batchID }
        XCTAssertEqual(TMRCalculator.batchBalance(movements: targetMovements), 110)
        let targetCornBatch = try XCTUnwrap(try target.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first { $0.id == source.cornBatch.id })
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: targetCornBatch, context: target)), 28)
    }

    func testTMRCloudBaselineRoundTripRestoresRelationsAndLedgersWithoutDoubleDeduction() throws {
        let source = try makeFixture()
        let formulaID = try saveFormula(in: source)
        let batchID = try produceBatch(formulaID: formulaID, in: source)
        try source.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 1,
                occurredAt: source.occurredAt,
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: source.firstPen.id,
                        actualHeadCountSnapshot: 70,
                        actualKilogramsText: "10"
                    )
                ]
            ))),
            in: source.farmContext,
            context: source.context
        )
        let sourceFarm = try XCTUnwrap(
            try source.context.fetch(FetchDescriptor<FarmRecord>())
                .first { $0.id == source.farmContext.farmID }
        )
        let snapshots = try FarmBaselineSnapshotService().makeProviderNeutralSnapshots(
            farm: sourceFarm,
            context: source.context
        )
        let tmrSnapshot = try XCTUnwrap(snapshots.first { $0.entityType == .tmrBaseline })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedTMRPayload = try decoder.decode(FarmCommandCloudPayload.self, from: tmrSnapshot.sourcePayload)
        XCTAssertEqual(decodedTMRPayload.kind, .restoreTMRBaseline)
        XCTAssertTrue(TMRCloudDataProtocol.isSupported(by: decodedTMRPayload))

        let operations = try snapshots.map {
            try baselineEnvelope(
                from: $0,
                farmID: source.farmContext.farmID,
                ownerID: source.farmContext.accountID
            )
        }
        let tmrOperation = try XCTUnwrap(operations.first { $0.entityType == CloudEntityType.tmrBaseline.rawValue })

        let targetContainer = try AppSchema.makeContainer(
            name: "tmr-cloud-baseline-target-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let target = ModelContext(targetContainer)
        let replay = RemoteDomainApplyService(replayAssumesEmptyBusinessStore: true)
        for operation in operations {
            _ = try replay.apply(operation, context: target)
        }
        try target.save()

        let restoredBatch = try XCTUnwrap(
            try target.fetch(FetchDescriptor<TMRBatchRecord>()).first { $0.id == batchID }
        )
        XCTAssertEqual(restoredBatch.revision, 2)
        XCTAssertEqual(try balance(batchID: batchID, in: target), 110)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<TMRFeedingRunRecord>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<TMRFeedingAllocationRecord>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<FeedRecord>()), 1)

        let restoredCornBatch = try XCTUnwrap(
            try target.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
                .first { $0.id == source.cornBatch.id }
        )
        let restoredSilageBatch = try XCTUnwrap(
            try target.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
                .first { $0.id == source.silageBatch.id }
        )
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: restoredCornBatch, context: target)), 28)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: restoredSilageBatch, context: target)), 52)
        XCTAssertEqual(
            try target.fetch(FetchDescriptor<FeedStockTransactionRecord>())
                .filter { $0.deletedAt == nil }.count,
            2,
            "云端重建不能重复生成 TMR 原料扣减流水"
        )
        XCTAssertEqual(try replay.apply(tmrOperation, context: target), .duplicate)
    }

    func testCompleteLocalBackupRestoresTMRRelationsAndBothLedgersWithoutDoubleDeduction() throws {
        let source = try makeFixture()
        let formulaID = try saveFormula(in: source)
        let batchID = try produceBatch(formulaID: formulaID, in: source)
        try source.service.execute(
            .tmr(.recordFeeding(TMRFeedingRunDraft(
                batchID: batchID,
                expectedBatchRevision: 1,
                occurredAt: source.occurredAt,
                meal: .morning,
                allocations: [
                    TMRFeedingAllocationDraft(
                        penID: source.firstPen.id,
                        actualHeadCountSnapshot: 70,
                        actualKilogramsText: "10"
                    )
                ]
            ))),
            in: source.farmContext,
            context: source.context
        )
        let data = try FarmLocalBackupService.export(
            farmID: source.farmContext.farmID,
            context: source.context
        )
        let preview = try FarmLocalBackupService.preview(data: data)
        XCTAssertNotNil(preview.envelope.payload.feeding?.tmr)

        let targetContainer = try AppSchema.makeContainer(
            name: "tmr-backup-target-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let target = ModelContext(targetContainer)
        let account = AccountProfile(
            appleUserIdentifier: "tmr-backup-\(UUID().uuidString)",
            displayName: "TMR 备份恢复"
        )
        let farm = FarmRecord(ownerAccountID: account.id, name: "空牧场")
        target.insert(account)
        target.insert(farm)
        try target.save()

        _ = try FarmLocalBackupService.restore(
            preview,
            into: farm,
            account: account,
            context: target
        )

        let restoredBatch = try XCTUnwrap(
            try target.fetch(FetchDescriptor<TMRBatchRecord>()).first { $0.id == batchID }
        )
        XCTAssertEqual(restoredBatch.revision, 2)
        XCTAssertEqual(try balance(batchID: batchID, in: target), 110)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<TMRFeedingRunRecord>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<TMRFeedingAllocationRecord>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<FeedRecord>()), 1)

        let restoredCornBatch = try XCTUnwrap(
            try target.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
                .first { $0.id == source.cornBatch.id }
        )
        let restoredSilageBatch = try XCTUnwrap(
            try target.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
                .first { $0.id == source.silageBatch.id }
        )
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: restoredCornBatch, context: target)), 28)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: restoredSilageBatch, context: target)), 52)
        XCTAssertEqual(
            try target.fetch(FetchDescriptor<FeedStockTransactionRecord>())
                .filter { $0.deletedAt == nil }.count,
            2,
            "恢复 TMR 事实时不能再次生成原料扣减流水"
        )
    }

    private struct Fixture {
        let context: ModelContext
        let farmContext: FarmContext
        let service: FarmCommandService
        let corn: FeedIngredientRecord
        let silage: FeedIngredientRecord
        let cornBatch: FeedIngredientBatchRecord
        let silageBatch: FeedIngredientBatchRecord
        let firstPen: PenRecord
        let secondPen: PenRecord
        let occurredAt: Date
    }

    private func makeFixture(includesSheep: Bool = false) throws -> Fixture {
        let container = try AppSchema.makeContainer(name: "tmr-workflow-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "tmr-test-\(UUID().uuidString)", displayName: "TMR 测试")
        let farm = FarmRecord(ownerAccountID: account.id, name: "TMR 测试场")
        let storageProfile = FarmStorageProfile(farmID: farm.id, mode: .localOnly)
        let firstPen = PenRecord(farmID: farm.id, name: "一舍")
        let secondPen = PenRecord(farmID: farm.id, name: "二舍")
        let corn = FeedIngredientRecord(farmID: farm.id, name: "玉米", unit: "千克", category: "能量饲料", nutrientSnapshotJSON: "{}", kind: .custom)
        let silage = FeedIngredientRecord(farmID: farm.id, name: "青贮", unit: "千克", category: "粗饲料", nutrientSnapshotJSON: "{}", kind: .custom)
        let cornBatch = FeedIngredientBatchRecord(farmID: farm.id, ingredientID: corn.id, batchName: "玉米仓", pricePerKilogramText: "2", stockWeightConfirmed: true, initialKilogramsText: "100", remainingKilogramsText: "100", note: "", isActive: true)
        let silageBatch = FeedIngredientBatchRecord(farmID: farm.id, ingredientID: silage.id, batchName: "青贮批次", pricePerKilogramText: "1", stockWeightConfirmed: true, initialKilogramsText: "100", remainingKilogramsText: "100", note: "", isActive: true)
        context.insert(account)
        context.insert(farm)
        context.insert(storageProfile)
        context.insert(firstPen)
        context.insert(secondPen)
        context.insert(corn)
        context.insert(silage)
        context.insert(cornBatch)
        context.insert(silageBatch)
        if includesSheep {
            context.insert(SheepRecord(
                farmID: farm.id,
                earTag: "TMR-001",
                breed: "杜泊",
                sex: .ewe,
                penID: firstPen.id,
                enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
            ))
            context.insert(SheepRecord(
                farmID: farm.id,
                earTag: "TMR-002",
                breed: "杜泊",
                sex: .ewe,
                penID: secondPen.id,
                enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
            ))
        }
        try context.save()
        return Fixture(
            context: context,
            farmContext: FarmContext(accountID: account.id, farmID: farm.id, role: .owner),
            service: FarmCommandService(),
            corn: corn,
            silage: silage,
            cornBatch: cornBatch,
            silageBatch: silageBatch,
            firstPen: firstPen,
            secondPen: secondPen,
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    private func saveFormula(in fixture: Fixture) throws -> UUID {
        let id = UUID()
        try fixture.service.execute(
            .tmr(.saveFormula(TMRFormulaDraft(
                id: id,
                name: "育肥 TMR",
                quantityBasis: .wholeGroupDaily,
                referenceHeadCount: 100,
                components: [
                    TMRFormulaComponentDraft(ingredientID: fixture.corn.id, quantityText: "72"),
                    TMRFormulaComponentDraft(ingredientID: fixture.silage.id, quantityText: "48")
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        let components = try fixture.context.fetch(FetchDescriptor<FeedRecipeComponentRecord>())
            .filter { $0.recipeID == id && $0.deletedAt == nil }
        XCTAssertTrue(components.allSatisfy { $0.ingredientBatchID == nil })
        return id
    }

    private func produceBatch(formulaID: UUID, in fixture: Fixture) throws -> UUID {
        let id = UUID()
        try fixture.service.execute(
            .tmr(.produceBatch(TMRBatchProductionDraft(
                id: id,
                formulaID: formulaID,
                expectedFormulaRevision: 1,
                producedAt: fixture.occurredAt,
                ingredients: [
                    TMRBatchIngredientDraft(
                        ingredientID: fixture.corn.id,
                        plannedKilogramsText: "72",
                        loadLines: [TMRBatchLoadDraft(ingredientBatchID: fixture.cornBatch.id, actualKilogramsText: "72")]
                    ),
                    TMRBatchIngredientDraft(
                        ingredientID: fixture.silage.id,
                        plannedKilogramsText: "48",
                        loadLines: [TMRBatchLoadDraft(ingredientBatchID: fixture.silageBatch.id, actualKilogramsText: "48")]
                    )
                ]
            ))),
            in: fixture.farmContext,
            context: fixture.context
        )
        return id
    }

    private func rawStockTransactions(in fixture: Fixture) throws -> [FeedStockTransactionRecord] {
        try fixture.context.fetch(FetchDescriptor<FeedStockTransactionRecord>())
            .filter { $0.deletedAt == nil }
    }

    private func balance(batchID: UUID, in context: ModelContext) throws -> Decimal {
        let movements = try context.fetch(FetchDescriptor<TMRBatchMovementRecord>())
            .filter { $0.batchID == batchID }
        return TMRCalculator.batchBalance(movements: movements)
    }

    private func envelope(_ operation: DomainOperation) -> CloudOperationEnvelope {
        CloudOperationEnvelope(
            farmID: operation.farmID,
            entityID: operation.entityID ?? UUID(),
            entityType: operation.entityType,
            schemaVersion: operation.schemaVersion,
            revision: operation.resultingRevision,
            baseRevision: operation.baseRevision,
            operationID: operation.id,
            modifiedAt: operation.createdAt,
            modifiedByAccountID: operation.accountID,
            modifiedByDeviceID: operation.modifiedByDeviceID ?? UUID(),
            payload: operation.payload,
            payloadDigest: operation.payloadDigest,
            capabilityCertificate: operation.capabilityCertificate,
            operationSignature: operation.operationSignature ?? Data(),
            deletedAt: nil
        )
    }

    private func baselineEnvelope(
        from snapshot: FarmBootstrapEntitySnapshot,
        farmID: UUID,
        ownerID: UUID
    ) throws -> CloudOperationEnvelope {
        let source = BootstrapEntityEnvelopeV1(
            entityType: snapshot.entityType.rawValue,
            entityID: snapshot.entityID,
            sourceRevision: snapshot.sourceRevision,
            sourcePayload: snapshot.sourcePayload
        )
        let cutoff = Date(timeIntervalSince1970: 1_790_000_000)
        var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
        wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(source)
        wrapper.integers["baselineVersion"] = 2
        wrapper.strings["baselineSlot"] = String(snapshot.replayOrder)
        wrapper.dates["baselineCutoffAt"] = cutoff
        let payload = try JSONEncoder.cloud.encode(wrapper)
        return CloudOperationEnvelope(
            farmID: farmID,
            entityID: snapshot.entityID,
            entityType: snapshot.entityType.rawValue,
            schemaVersion: 2,
            revision: snapshot.sourceRevision,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: cutoff,
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
    }
}
