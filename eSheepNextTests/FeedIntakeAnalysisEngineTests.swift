import XCTest
@testable import eSheepNext

final class FeedIntakeAnalysisEngineTests: XCTestCase {
    private let penA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let penB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let cornID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let mealID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    func testWholeDaySheepDaysUseSnapshotAndExplicitExclusion() throws {
        let sheep1 = sheep(tag: "A01", penID: penA, enteredAt: date(0))
        let sheep2 = sheep(tag: "A02", penID: penA, enteredAt: date(0))
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [sheep1, sheep2],
            counts: [count(penID: penA, date: date(1), value: 2)],
            feeds: [limitedFeed(at: date(1, 8), kilograms: 20, excluded: [sheep2.id])]
        )

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.sheepDays, 1, accuracy: 0.000_001)
        XCTAssertEqual(pen.freshKilograms, 20, accuracy: 0.000_001)
        XCTAssertEqual(pen.nutrition.freshKilogramsPerSheepDay ?? 0, 20, accuracy: 0.000_001)
        XCTAssertFalse(pen.evidence.contains(.conflict))
    }

    func testSnapshotWinsCountMismatchAndSurfacesConflict() throws {
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [sheep(tag: "A01", penID: penA, enteredAt: date(0))],
            counts: [count(penID: penA, date: date(1), value: 2)],
            feeds: [limitedFeed(at: date(1, 8), kilograms: 20)]
        )

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.sheepDays, 2, accuracy: 0.000_001)
        XCTAssertTrue(pen.evidence.contains(.conflict))
        XCTAssertTrue(pen.conflicts.first?.contains("快照人数2与事件人数1") == true)
        XCTAssertNil(pen.growth.nutritionPotentialADGKg)
    }

    func testLegacyFeedHeadCountSnapshotRemainsUsableWithoutIdentityTimeline() throws {
        let feed = FeedAnalysisFeedSnapshot(
            penID: penA,
            mode: .limited,
            occurredAt: date(1, 8),
            lines: [line(id: cornID, name: "玉米", kilograms: 20)],
            historicalHeadCountSnapshot: 10
        )
        let input = makeInput(start: date(1), end: date(2), sheep: [], feeds: [feed])

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.sheepDays, 10, accuracy: 0.000_001)
        XCTAssertEqual(pen.nutrition.freshKilogramsPerSheepDay ?? 0, 2, accuracy: 0.000_001)
        XCTAssertTrue(pen.evidence.contains(.historicalHeadCount))
    }

    func testHalfDayTransferUsesExactTimeWithEndOfDaySnapshots() throws {
        let animal = sheep(tag: "T01", penID: penA, enteredAt: date(0))
        let transfer = FeedAnalysisTransferSnapshot(
            id: UUID(),
            sheepID: animal.id,
            fromPenID: penA,
            toPenID: penB,
            occurredAt: date(1, 12),
            recordedAt: date(1, 12)
        )
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [animal],
            transfers: [transfer],
            counts: [
                count(penID: penA, date: date(1), value: 0),
                count(penID: penB, date: date(1), value: 1),
            ],
            feeds: [
                limitedFeed(penID: penA, at: date(1, 8), kilograms: 5),
                limitedFeed(penID: penB, at: date(1, 16), kilograms: 5),
            ]
        )

        let result = FeedIntakeAnalysisEngine.calculate(input: input)
        XCTAssertEqual(try XCTUnwrap(result.pens.first { $0.id == penA }).sheepDays, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.pens.first { $0.id == penB }).sheepDays, 0.5, accuracy: 0.000_001)
    }

    func testHalfDayEntryAndRemovalUseEventFallback() throws {
        let arriving = sheep(tag: "I01", penID: penA, enteredAt: date(1, 12))
        let leaving = sheep(tag: "O01", penID: penB, enteredAt: date(0), removedAt: date(1, 12))
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [arriving, leaving],
            feeds: [
                limitedFeed(penID: penA, at: date(1, 16), kilograms: 5),
                limitedFeed(penID: penB, at: date(1, 8), kilograms: 5),
            ]
        )

        let result = FeedIntakeAnalysisEngine.calculate(input: input)
        XCTAssertEqual(try XCTUnwrap(result.pens.first { $0.id == penA }).sheepDays, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.pens.first { $0.id == penB }).sheepDays, 0.5, accuracy: 0.000_001)
    }

    func testLimitedMealsMergeAndMixtureRemainderIsSubtractedOnceByRatio() throws {
        let firstID = UUID()
        let first = FeedAnalysisFeedSnapshot(
            id: firstID,
            penID: penA,
            mode: .limited,
            occurredAt: date(1, 8),
            feederName: "一号槽",
            lines: [line(id: cornID, name: "玉米", kilograms: 8), line(id: mealID, name: "豆粕", kilograms: 2)]
        )
        let second = FeedAnalysisFeedSnapshot(
            penID: penA,
            mode: .limited,
            occurredAt: date(1, 17),
            feederName: "一号槽",
            lines: [line(id: cornID, name: "玉米", kilograms: 4), line(id: mealID, name: "豆粕", kilograms: 1)]
        )
        let observation = FeedAnalysisTroughSnapshot(
            id: UUID(),
            penID: penA,
            relatedFeedRecordID: firstID,
            feederName: "一号槽",
            observedAt: date(1, 20),
            actualRemainingKilograms: 3,
            discardedKilograms: 1,
            measurementMethod: .weighed,
            composition: []
        )
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [sheep(tag: "A01", penID: penA, enteredAt: date(0))],
            feeds: [first, second],
            troughs: [observation]
        )

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.freshKilograms, 12, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(pen.ingredients.first { $0.ingredientID == cornID }).freshKilograms, 9.6, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(pen.ingredients.first { $0.ingredientID == mealID }).freshKilograms, 2.4, accuracy: 0.000_001)
        XCTAssertTrue(pen.evidence.contains(.measured))
        XCTAssertFalse(pen.evidence.contains(.estimated))
    }

    func testFreeChoiceCombinesTopUpsAndMultipleTanksWithoutDuplicatingSheepDays() throws {
        let animal = sheep(tag: "A01", penID: penA, enteredAt: date(0))
        let feeds = [
            freeFeed(tank: "A罐", at: date(1, 6), kilograms: 10),
            freeFeed(tank: "A罐", at: date(1, 12), kilograms: 2),
            freeFeed(tank: "B罐", at: date(1, 10), kilograms: 6),
        ]
        let troughs = [
            trough(tank: "A罐", at: date(1), remaining: 5),
            trough(tank: "A罐", at: date(2), remaining: 4),
            trough(tank: "B罐", at: date(1), remaining: 0),
            trough(tank: "B罐", at: date(2), remaining: 1),
        ]
        let input = makeInput(start: date(1), end: date(2), sheep: [animal], feeds: feeds, troughs: troughs)

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.freshKilograms, 18, accuracy: 0.000_001)
        XCTAssertEqual(pen.sheepDays, 1, accuracy: 0.000_001)
        XCTAssertEqual(pen.completeIntervalCount, 2)
        XCTAssertEqual(pen.incompleteIntervalCount, 0)
    }

    func testFreeChoiceClearingAffectsNextOpeningAndIsNotDeductedTwice() throws {
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [sheep(tag: "A01", penID: penA, enteredAt: date(0))],
            feeds: [freeFeed(tank: "草槽", at: date(1, 12), kilograms: 10)],
            troughs: [
                trough(tank: "草槽", at: date(1), remaining: 5, discarded: 2),
                trough(tank: "草槽", at: date(2), remaining: 4, discarded: 1),
            ]
        )

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.freshKilograms, 9, accuracy: 0.000_001)
    }

    func testFreeChoiceFinalUnclosedIntervalIsNotCounted() throws {
        let input = makeInput(
            start: date(1),
            end: date(3),
            sheep: [sheep(tag: "A01", penID: penA, enteredAt: date(0))],
            feeds: [
                freeFeed(tank: "草槽", at: date(1, 12), kilograms: 10),
                freeFeed(tank: "草槽", at: date(2, 12), kilograms: 8),
            ],
            troughs: [
                trough(tank: "草槽", at: date(1), remaining: 0),
                trough(tank: "草槽", at: date(2), remaining: 4),
            ]
        )

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.freshKilograms, 6, accuracy: 0.000_001)
        XCTAssertEqual(pen.incompleteIntervalCount, 1)
        XCTAssertTrue(pen.evidence.contains(.measured))
    }

    func testSingleTroughBoundaryDoesNotTurnOpenIntervalIntoLegacyEstimate() throws {
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [sheep(tag: "A01", penID: penA, enteredAt: date(0))],
            feeds: [freeFeed(tank: "草槽", at: date(1, 12), kilograms: 10)],
            troughs: [trough(tank: "草槽", at: date(1), remaining: 0)]
        )

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.freshKilograms, 0, accuracy: 0.000_001)
        XCTAssertEqual(pen.incompleteIntervalCount, 1)
        XCTAssertFalse(pen.evidence.contains(.estimated))
    }

    func testFreeChoiceNegativeConsumptionProducesConflictInsteadOfZero() throws {
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [sheep(tag: "A01", penID: penA, enteredAt: date(0))],
            feeds: [freeFeed(tank: "草槽", at: date(1, 12), kilograms: 2)],
            troughs: [
                trough(tank: "草槽", at: date(1), remaining: 0),
                trough(tank: "草槽", at: date(2), remaining: 5),
            ]
        )

        let pen = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first)
        XCTAssertEqual(pen.freshKilograms, 0, accuracy: 0.000_001)
        XCTAssertTrue(pen.evidence.contains(.conflict))
        XCTAssertEqual(pen.conflicts.count, 1)
    }

    func testNutritionUsesFreshWeightToDryMatterAndMcalToMJWithCoverage() throws {
        let feed = FeedAnalysisFeedSnapshot(
            penID: penA,
            mode: .limited,
            occurredAt: date(1, 8),
            lines: [
                FeedAnalysisLineSnapshot(
                    ingredientID: cornID,
                    ingredientName: "青贮",
                    freshKilograms: 10,
                    nutrients: FeedNutrients(dryMatter: 40, crudeProtein: 10, ndf: 50, adf: 30, me: 2)
                ),
                FeedAnalysisLineSnapshot(
                    ingredientID: mealID,
                    ingredientName: "精料",
                    freshKilograms: 5,
                    nutrients: FeedNutrients(dryMatter: 80, crudeProtein: 20, ndf: 20, adf: 10, me: 3)
                ),
            ]
        )
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [sheep(tag: "A01", penID: penA, enteredAt: date(0))],
            feeds: [feed]
        )

        let nutrition = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first).nutrition
        XCTAssertEqual(nutrition.summary.dryMatterKilograms ?? 0, 8, accuracy: 0.000_001)
        XCTAssertEqual(nutrition.summary.meMJ ?? 0, 83.68, accuracy: 0.000_001)
        XCTAssertEqual(nutrition.crudeProteinGramsPerSheepDay ?? 0, 1_200, accuracy: 0.000_001)
        XCTAssertEqual(nutrition.ndfGramsPerSheepDay ?? 0, 2_800, accuracy: 0.000_001)
        XCTAssertTrue(nutrition.mpEstimated)
        XCTAssertEqual(nutrition.summary.coverage[.crudeProtein]?.coverage, 1)
    }

    func testMissingNutritionStaysMissingAndListsIngredient() throws {
        let feed = FeedAnalysisFeedSnapshot(
            penID: penA,
            mode: .limited,
            occurredAt: date(1, 8),
            lines: [
                FeedAnalysisLineSnapshot(ingredientName: "有CP", freshKilograms: 5, nutrients: FeedNutrients(dryMatter: 100, crudeProtein: 15, me: 3)),
                FeedAnalysisLineSnapshot(ingredientName: "缺CP", freshKilograms: 5, nutrients: FeedNutrients(dryMatter: 100, me: 3)),
            ]
        )
        let input = makeInput(start: date(1), end: date(2), sheep: [sheep(tag: "A01", penID: penA, enteredAt: date(0))], feeds: [feed])

        let nutrition = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first).nutrition
        XCTAssertNil(nutrition.crudeProteinGramsPerSheepDay)
        XCTAssertNil(nutrition.metabolizableProteinGramsPerSheepDay)
        XCTAssertEqual(nutrition.summary.coverage[.crudeProtein]?.missingIngredientNames, ["缺CP"])
    }

    func testFatteningStageProducesNutritionPotentialObservedAndCalibratedADG() throws {
        let animal = sheep(tag: "F01", purpose: "育肥羊", penID: penA, enteredAt: date(0))
        let feed = highQualityFeed(at: date(1, 8), kilograms: 2.5)
        let weights = [
            FeedAnalysisWeightSnapshot(id: UUID(), sheepID: animal.id, kilograms: 36, occurredAt: date(-20)),
            FeedAnalysisWeightSnapshot(id: UUID(), sheepID: animal.id, kilograms: 40, occurredAt: date(-6)),
        ]
        let input = makeInput(start: date(1), end: date(2), sheep: [animal], feeds: [feed], weights: weights)

        let growth = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first).growth
        XCTAssertEqual(growth.stage, .fattening)
        XCTAssertNotNil(growth.nutritionPotentialADGKg)
        XCTAssertEqual(growth.observedADGKg ?? 0, 4.0 / 14.0, accuracy: 0.000_001)
        XCTAssertNotNil(growth.calibratedExpectedADGKg)
        XCTAssertNil(growth.blockedReason)
    }

    func testBreedingStageShowsMaintenanceGapWithoutGrowthPrediction() throws {
        let animal = sheep(tag: "E01", purpose: "繁殖母羊", penID: penA, enteredAt: date(0), sex: .ewe)
        let input = makeInput(
            start: date(1),
            end: date(2),
            sheep: [animal],
            feeds: [highQualityFeed(at: date(1, 8), kilograms: 2.5)],
            weights: [FeedAnalysisWeightSnapshot(id: UUID(), sheepID: animal.id, kilograms: 55, occurredAt: date(-5))]
        )

        let growth = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: input).pens.first).growth
        XCTAssertEqual(growth.stage, .breedingEwe)
        XCTAssertNotNil(growth.maintenanceMEGap)
        XCTAssertNil(growth.nutritionPotentialADGKg)
        XCTAssertNil(growth.calibratedExpectedADGKg)
        XCTAssertNil(growth.blockedReason)
    }

    func testMixedStageAndInsufficientWeightCoverageStopPrediction() throws {
        let fattening = sheep(tag: "F01", purpose: "育肥羊", penID: penA, enteredAt: date(0))
        let ewe = sheep(tag: "E01", purpose: "繁殖母羊", penID: penA, enteredAt: date(0), sex: .ewe)
        let mixed = makeInput(start: date(1), end: date(2), sheep: [fattening, ewe], feeds: [highQualityFeed(at: date(1, 8), kilograms: 5)])
        let mixedGrowth = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: mixed).pens.first).growth
        XCTAssertTrue(mixedGrowth.blockedReason?.contains("80%") == true)

        let four = (1...4).map { sheep(tag: "F0\($0)", purpose: "育肥羊", penID: penA, enteredAt: date(0)) }
        let insufficient = makeInput(
            start: date(1),
            end: date(2),
            sheep: four,
            feeds: [highQualityFeed(at: date(1, 8), kilograms: 10)],
            weights: [FeedAnalysisWeightSnapshot(id: UUID(), sheepID: four[0].id, kilograms: 40, occurredAt: date(-5))]
        )
        let insufficientGrowth = try XCTUnwrap(FeedIntakeAnalysisEngine.calculate(input: insufficient).pens.first).growth
        XCTAssertTrue(insufficientGrowth.blockedReason?.contains("体重覆盖不足") == true)
        XCTAssertNil(insufficientGrowth.nutritionPotentialADGKg)
    }

    func testAnalysisFormattingNeverExceedsThreeDecimalPlaces() {
        let values = [1.0 / 3.0, 1_234.567_891, 0.000_49, 10.500_01]
        for value in values {
            for digits in 0...3 {
                let text = FeedAnalysisNumberFormatter.text(value, maximumFractionDigits: digits)
                let fractional = text.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
                XCTAssertLessThanOrEqual(fractional, min(3, digits), "\(text) 小数位过多")
                XCTAssertFalse(text.hasSuffix(".0"))
            }
        }
        XCTAssertEqual(FeedAnalysisNumberFormatter.perHead(1.2), "1.2")
        XCTAssertEqual(FeedAnalysisNumberFormatter.percent(0.85678), "85.7%")
    }

    func testSourceRevisionChangesForQuantityNutrientTroughAndWeightFacts() {
        let animal = sheep(tag: "F01", purpose: "育肥羊", penID: penA, enteredAt: date(0))
        let base = makeInput(start: date(1), end: date(2), sheep: [animal], feeds: [limitedFeed(at: date(1, 8), kilograms: 10)])
        let changedQuantity = makeInput(start: date(1), end: date(2), sheep: [animal], feeds: [limitedFeed(at: date(1, 8), kilograms: 11)])
        let changedNutrition = makeInput(
            start: date(1), end: date(2), sheep: [animal],
            feeds: [FeedAnalysisFeedSnapshot(
                penID: penA,
                mode: .limited,
                occurredAt: date(1, 8),
                lines: [FeedAnalysisLineSnapshot(ingredientName: "玉米", freshKilograms: 10, nutrients: FeedNutrients(dryMatter: 90, crudeProtein: 12, me: 3))]
            )]
        )
        let changedTrough = makeInput(
            start: date(1), end: date(2), sheep: [animal], feeds: [limitedFeed(at: date(1, 8), kilograms: 10)],
            troughs: [trough(tank: "未指定料罐", at: date(1, 20), remaining: 2)]
        )
        let changedWeight = makeInput(
            start: date(1), end: date(2), sheep: [animal], feeds: [limitedFeed(at: date(1, 8), kilograms: 10)],
            weights: [FeedAnalysisWeightSnapshot(id: UUID(), sheepID: animal.id, kilograms: 40, occurredAt: date(-5))]
        )

        let baseRevision = FeedIntakeAnalysisEngine.calculate(input: base).sourceRevision
        XCTAssertNotEqual(baseRevision, FeedIntakeAnalysisEngine.calculate(input: changedQuantity).sourceRevision)
        XCTAssertNotEqual(baseRevision, FeedIntakeAnalysisEngine.calculate(input: changedNutrition).sourceRevision)
        XCTAssertNotEqual(baseRevision, FeedIntakeAnalysisEngine.calculate(input: changedTrough).sourceRevision)
        XCTAssertNotEqual(baseRevision, FeedIntakeAnalysisEngine.calculate(input: changedWeight).sourceRevision)
    }

    private func makeInput(
        start: Date,
        end: Date,
        sheep: [FeedAnalysisSheepSnapshot],
        transfers: [FeedAnalysisTransferSnapshot] = [],
        removals: [FeedAnalysisRemovalSnapshot] = [],
        counts: [FeedAnalysisDailyPenCountSnapshot] = [],
        feeds: [FeedAnalysisFeedSnapshot],
        troughs: [FeedAnalysisTroughSnapshot] = [],
        weights: [FeedAnalysisWeightSnapshot] = []
    ) -> FeedIntakeAnalysisInput {
        FeedIntakeAnalysisInput(
            start: start,
            end: end,
            calendar: calendar,
            pens: [FeedAnalysisPenSnapshot(id: penA, name: "一圈"), FeedAnalysisPenSnapshot(id: penB, name: "二圈")],
            sheep: sheep,
            transfers: transfers,
            removals: removals,
            dailyPenCounts: counts,
            feeds: feeds,
            troughObservations: troughs,
            weights: weights
        )
    }

    private func sheep(
        tag: String,
        purpose: String = "育肥羊",
        penID: UUID,
        enteredAt: Date,
        removedAt: Date? = nil,
        sex: SheepSex = .ram
    ) -> FeedAnalysisSheepSnapshot {
        FeedAnalysisSheepSnapshot(
            id: UUID(),
            earTag: tag,
            purpose: purpose,
            sex: sex,
            initialPenID: penID,
            enteredAt: enteredAt,
            removedAt: removedAt
        )
    }

    private func count(penID: UUID, date: Date, value: Int, purpose: String = "育肥羊") -> FeedAnalysisDailyPenCountSnapshot {
        FeedAnalysisDailyPenCountSnapshot(id: UUID(), penID: penID, purpose: purpose, date: date, count: value, rebuiltAt: date)
    }

    private func line(id: UUID, name: String, kilograms: Double) -> FeedAnalysisLineSnapshot {
        FeedAnalysisLineSnapshot(
            ingredientID: id,
            ingredientName: name,
            freshKilograms: kilograms,
            pricePerKilogram: 2,
            nutrients: FeedNutrients(dryMatter: 88, crudeProtein: 12, ndf: 30, adf: 15, me: 3, rdp: 7, rup: 5, adip: 0.5)
        )
    }

    private func limitedFeed(
        penID: UUID? = nil,
        at date: Date,
        kilograms: Double,
        excluded: Set<UUID> = []
    ) -> FeedAnalysisFeedSnapshot {
        FeedAnalysisFeedSnapshot(
            penID: penID ?? penA,
            mode: .limited,
            occurredAt: date,
            lines: [line(id: cornID, name: "玉米", kilograms: kilograms)],
            excludedSheepIDs: excluded
        )
    }

    private func highQualityFeed(at date: Date, kilograms: Double) -> FeedAnalysisFeedSnapshot {
        FeedAnalysisFeedSnapshot(
            penID: penA,
            mode: .limited,
            occurredAt: date,
            lines: [FeedAnalysisLineSnapshot(
                ingredientID: cornID,
                ingredientName: "全价料",
                freshKilograms: kilograms,
                nutrients: FeedNutrients(dryMatter: 100, crudeProtein: 18, ndf: 30, adf: 15, me: 3, rdp: 11, rup: 7, adip: 0.5)
            )]
        )
    }

    private func freeFeed(tank: String, at date: Date, kilograms: Double) -> FeedAnalysisFeedSnapshot {
        FeedAnalysisFeedSnapshot(
            penID: penA,
            mode: .freeChoice,
            occurredAt: date,
            feederName: tank,
            lines: [line(id: cornID, name: "玉米", kilograms: kilograms)]
        )
    }

    private func trough(
        tank: String,
        at date: Date,
        remaining: Double,
        discarded: Double = 0
    ) -> FeedAnalysisTroughSnapshot {
        let composition: [FeedTroughCompositionComponent] = remaining > 0 ? [
            FeedTroughCompositionComponent(
                ingredientID: cornID,
                ingredientNameSnapshot: "玉米",
                kilogramsText: String(remaining),
                nutrientSnapshotJSON: FeedNutritionCodec.encode(FeedNutrients(dryMatter: 88, crudeProtein: 12, ndf: 30, adf: 15, me: 3, rdp: 7, rup: 5, adip: 0.5))
            )
        ] : []
        return FeedAnalysisTroughSnapshot(
            id: UUID(),
            penID: penA,
            relatedFeedRecordID: nil,
            feederName: tank,
            observedAt: date,
            actualRemainingKilograms: remaining,
            discardedKilograms: discarded,
            measurementMethod: .weighed,
            composition: composition
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 8,
            day: 1 + day,
            hour: hour
        ))!
    }
}
