import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FeedRebuildTests: XCTestCase {
    func testPlusSystemLibraryContainsExpectedTemplatesAndCategories() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "eSheepNext/Resources/FeedIngredientTemplates.json")
        let templates = try FeedTemplateLibrary.load(from: sourceURL)

        XCTAssertEqual(templates.count, 760)
        XCTAssertEqual(Set(templates.map(\.category)).count, 11)
        XCTAssertNotNil(templates.first { $0.name.localizedStandardContains("玉米") })
        XCTAssertTrue(templates.allSatisfy { !$0.id.isEmpty && !$0.code.isEmpty })
    }

    func testNutritionUsesDryMatterWeightedValuesAndConvertsEnergyToMJ() {
        let summary = FeedRecipeNutritionSummary.calculate(components: [
            FeedNutritionComponent(ingredientName: "低干物质青贮", freshKilograms: 10, pricePerKilogram: 1, nutrients: FeedNutrients(dryMatter: 40, crudeProtein: 10, me: 2)),
            FeedNutritionComponent(ingredientName: "高干物质精料", freshKilograms: 5, pricePerKilogram: 3, nutrients: FeedNutrients(dryMatter: 80, crudeProtein: 20, me: 3))
        ])

        XCTAssertEqual(summary.asFedKilograms, 15, accuracy: 0.0001)
        XCTAssertEqual(summary.dryMatterKilograms ?? 0, 8, accuracy: 0.0001)
        XCTAssertEqual(summary.nutrients.crudeProtein ?? 0, 15, accuracy: 0.0001)
        XCTAssertEqual(summary.nutrients.meMJPerKgDM ?? 0, 2.5 * 4.184, accuracy: 0.0001)
        XCTAssertEqual(summary.meMJ ?? 0, 8 * 2.5 * 4.184, accuracy: 0.0001)
        XCTAssertEqual(summary.cost ?? 0, 25, accuracy: 0.0001)
    }

    func testNutritionCoverageDoesNotTreatMissingIngredientAsZero() {
        let summary = FeedRecipeNutritionSummary.calculate(components: [
            FeedNutritionComponent(ingredientName: "有 CP", freshKilograms: 10, nutrients: FeedNutrients(dryMatter: 50, crudeProtein: 12)),
            FeedNutritionComponent(ingredientName: "缺 CP", freshKilograms: 10, nutrients: FeedNutrients(dryMatter: 50))
        ])

        XCTAssertNil(summary.nutrients.crudeProtein)
        XCTAssertLessThan(summary.coverage[.crudeProtein]?.coverage ?? 1, 1)
        XCTAssertEqual(summary.coverage[.crudeProtein]?.missingIngredientNames, ["缺 CP"])
    }

    func testMixtureUsesRatiosForNutrientsAndPrice() throws {
        let result = try FeedMixtureCalculator.calculate(components: [
            FeedMixtureComponent(ingredientName: "玉米", sharePercent: 70, nutrients: FeedNutrients(dryMatter: 88, crudeProtein: 9, me: 3.2), pricePerKilogram: 2.4),
            FeedMixtureComponent(ingredientName: "豆粕", sharePercent: 30, nutrients: FeedNutrients(dryMatter: 90, crudeProtein: 46, me: 2.9), pricePerKilogram: 4.2)
        ])

        XCTAssertEqual(result.nutrients.dryMatter ?? 0, 88.6, accuracy: 0.0001)
        XCTAssertEqual(result.nutrients.crudeProtein ?? 0, 20.1, accuracy: 0.0001)
        XCTAssertEqual(result.pricePerKilogram ?? 0, 2.94, accuracy: 0.0001)
        XCTAssertThrowsError(try FeedMixtureCalculator.calculate(components: [
            FeedMixtureComponent(ingredientName: "玉米", sharePercent: 60, nutrients: .empty),
            FeedMixtureComponent(ingredientName: "豆粕", sharePercent: 30, nutrients: .empty)
        ]))
    }

    func testBulkPhysicalCountCanRemainUnresolvedWithoutChangingKilogramBalance() throws {
        let fixture = try makeFixture(initialKilograms: "100")
        let service = FarmCommandService()

        try service.execute(
            .countFeedStock(countID: UUID(), batchID: fixture.batch.id, actualKilogramsText: nil, method: .notMeasured, occurredAt: .now, note: "散装玉米仓暂未过磅"),
            in: fixture.farmContext,
            context: fixture.context
        )

        let count = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<FeedStockCountRecord>()).first)
        XCTAssertNil(count.actualKilogramsText)
        XCTAssertNil(count.differenceText)
        XCTAssertNil(count.adjustmentTransactionID)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.batch, context: fixture.context)), 100)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).isEmpty)
    }

    func testConfirmedPhysicalCountCreatesAuditableDifferenceAdjustment() throws {
        let fixture = try makeFixture(initialKilograms: "100")
        try fixture.service.execute(
            .countFeedStock(countID: UUID(), batchID: fixture.batch.id, actualKilogramsText: "93.5", method: .weighed, occurredAt: .now, note: "过磅盘库"),
            in: fixture.farmContext,
            context: fixture.context
        )

        let count = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<FeedStockCountRecord>()).first)
        XCTAssertEqual(count.method, .weighed)
        XCTAssertEqual(count.differenceText, "-6.5")
        let adjustmentID = try XCTUnwrap(count.adjustmentTransactionID)
        let adjustment = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).first { $0.id == adjustmentID })
        XCTAssertEqual(adjustment.kind, .adjustment)
        XCTAssertEqual(adjustment.quantityText, "-6.5")
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.batch, context: fixture.context)), Decimal(string: "93.5"))
    }

    func testFeedConsumptionRollsBackOnInsufficientStockAndDeleteRestoresIt() throws {
        let fixture = try makeFixture(initialKilograms: "10")
        try fixture.service.execute(
            .recordFeedV2(FeedEntryDraft(penID: fixture.pen.id, mode: .limited, occurredAt: .now, lines: [FeedLineDraft(ingredientID: fixture.ingredient.id, ingredientBatchID: fixture.batch.id, kilogramsText: "7")])),
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.batch, context: fixture.context)), 3)

        XCTAssertThrowsError(try fixture.service.execute(
            .recordFeedV2(FeedEntryDraft(penID: fixture.pen.id, mode: .limited, occurredAt: .now, lines: [FeedLineDraft(ingredientID: fixture.ingredient.id, ingredientBatchID: fixture.batch.id, kilogramsText: "4")])),
            in: fixture.farmContext,
            context: fixture.context
        ))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<FeedRecord>()).count, 1)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.batch, context: fixture.context)), 3)

        let feed = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<FeedRecord>()).first)
        try fixture.service.execute(.tombstoneEntity(entityType: .feed, entityID: feed.id, reason: "测试删除"), in: fixture.farmContext, context: fixture.context)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.batch, context: fixture.context)), 10)
    }

    func testFeedPersistsExplicitExcludedSheepIdentifiersAndHeadCountSnapshot() throws {
        let fixture = try makeFixture(initialKilograms: "10")
        try fixture.service.execute(
            .recordFeedV2(FeedEntryDraft(
                penID: fixture.pen.id,
                mode: .limited,
                occurredAt: .now,
                actualHeadCountSnapshot: 0,
                excludedSheepIDs: [fixture.sheep.id],
                lines: [FeedLineDraft(
                    ingredientID: fixture.ingredient.id,
                    ingredientBatchID: fixture.batch.id,
                    kilogramsText: "2"
                )]
            )),
            in: fixture.farmContext,
            context: fixture.context
        )

        let feed = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<FeedRecord>()).first)
        XCTAssertEqual(feed.actualHeadCountSnapshot, 0)
        XCTAssertEqual(feed.excludedSheepIDs, [fixture.sheep.id])
        let operation = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).first {
            $0.kindRawValue == DomainOperationKind.recordFeedV2.rawValue
        })
        let payload = try cloudPayload(from: operation.payload)
        XCTAssertEqual(
            FeedExcludedSheepCodec.decode(payload.optionalStrings["excludedSheepIDsJSON"] ?? nil),
            [fixture.sheep.id]
        )
    }

    func testTroughObservationWritesAuditPayloadAndRemoteReplayIsIdempotent() throws {
        let fixture = try makeFixture(initialKilograms: "20")
        try fixture.service.execute(
            .recordFeedV2(FeedEntryDraft(
                penID: fixture.pen.id,
                mode: .limited,
                occurredAt: Date.now.addingTimeInterval(-3_600),
                feederName: "一号槽",
                lines: [FeedLineDraft(
                    ingredientID: fixture.ingredient.id,
                    ingredientBatchID: fixture.batch.id,
                    kilogramsText: "8"
                )]
            )),
            in: fixture.farmContext,
            context: fixture.context
        )
        let feed = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<FeedRecord>()).first)
        let observationID = UUID()
        let composition = FeedTroughCompositionCodec.encode([
            FeedTroughCompositionComponent(
                ingredientID: fixture.ingredient.id,
                ingredientBatchID: fixture.batch.id,
                ingredientNameSnapshot: fixture.ingredient.name,
                kilogramsText: "2",
                nutrientSnapshotJSON: fixture.ingredient.nutrientSnapshotJSON,
                dryMatterTextSnapshot: fixture.ingredient.dryMatterText
            )
        ])

        try fixture.service.execute(
            .recordFeedTroughObservation(FeedTroughObservationDraft(
                id: observationID,
                penID: fixture.pen.id,
                relatedFeedRecordID: feed.id,
                feederName: "一号槽",
                observedAt: Date.now.addingTimeInterval(-1_800),
                actualRemainingKilogramsText: "2",
                discardedKilogramsText: "0.5",
                measurementMethod: .weighed,
                compositionSnapshotJSON: composition,
                note: "晨间盘槽"
            )),
            in: fixture.farmContext,
            context: fixture.context
        )

        let local = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).first)
        XCTAssertEqual(local.id, observationID)
        XCTAssertEqual(local.actualRemainingKilogramsText, "2")
        XCTAssertEqual(local.discardedKilogramsText, "0.5")
        XCTAssertEqual(local.measurementMethod, .weighed)
        XCTAssertEqual(local.composition.count, 1)

        let operation = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).first {
            $0.kindRawValue == DomainOperationKind.recordFeedTroughObservation.rawValue
        })
        let payload = try cloudPayload(from: operation.payload)
        XCTAssertEqual(payload.kind, DomainOperationKind.recordFeedTroughObservation)
        XCTAssertEqual(payload.identifiers["penID"], fixture.pen.id)
        XCTAssertEqual(payload.optionalIdentifiers["relatedFeedRecordID"] ?? nil, feed.id)
        XCTAssertEqual(payload.strings["actualRemainingKilogramsText"], "2")
        XCTAssertEqual(payload.strings["measurementMethod"], FeedTroughMeasurementMethod.weighed.rawValue)

        let target = try AppSchema.makeContainer(name: "feed-trough-remote-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let targetContext = ModelContext(target)
        targetContext.insert(PenRecord(id: fixture.pen.id, farmID: fixture.farmContext.farmID, name: "育肥一圈"))
        targetContext.insert(FeedRecord(
            id: feed.id,
            farmID: fixture.farmContext.farmID,
            penID: fixture.pen.id,
            mode: .limited,
            occurredAt: feed.occurredAt,
            feederName: "一号槽"
        ))
        try targetContext.save()
        let envelope = CloudOperationEnvelope(
            farmID: fixture.farmContext.farmID,
            entityID: observationID,
            entityType: CloudEntityType.feedTroughObservation.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: operation.id,
            modifiedAt: operation.createdAt,
            modifiedByAccountID: fixture.farmContext.accountID,
            modifiedByDeviceID: UUID(),
            payload: operation.payload,
            payloadDigest: CloudPayloadDigest.hex(for: operation.payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        XCTAssertEqual(
            try RemoteDomainApplyService().apply(envelope, context: targetContext),
            .applied(rebuildHistoryFrom: nil)
        )
        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: targetContext), .duplicate)
        XCTAssertEqual(try targetContext.fetchCount(FetchDescriptor<FeedTroughObservationRecord>()), 1)
    }

    func testTroughObservationDeleteAndRestoreKeepAuditableFact() throws {
        let fixture = try makeFixture(initialKilograms: "10")
        let observationID = UUID()
        try fixture.service.execute(
            .recordFeedTroughObservation(FeedTroughObservationDraft(
                id: observationID,
                penID: fixture.pen.id,
                feederName: "散料槽",
                observedAt: .now,
                actualRemainingKilogramsText: "3.5",
                measurementMethod: .volumeEstimate
            )),
            in: fixture.farmContext,
            context: fixture.context
        )
        try fixture.service.execute(
            .tombstoneEntity(entityType: .feedTroughObservation, entityID: observationID, reason: "录入有误"),
            in: fixture.farmContext,
            context: fixture.context
        )
        let record = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).first)
        XCTAssertNotNil(record.deletedAt)
        let tombstone = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<TombstoneRecord>()).first {
            $0.entityID == observationID && $0.restoredAt == nil
        })
        try fixture.service.execute(
            .restoreTombstonedEntity(tombstoneID: tombstone.id),
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertNil(record.deletedAt)
        XCTAssertNotNil(tombstone.restoredAt)
    }

    func testNewFeedRejectsPenWithNoSheepOnOccurredDayWithoutChangingStock() throws {
        let fixture = try makeFixture(initialKilograms: "10")
        let emptyPen = PenRecord(farmID: fixture.farmContext.farmID, name: "空圈舍")
        fixture.context.insert(emptyPen)
        try fixture.context.save()

        XCTAssertThrowsError(try fixture.service.execute(
            .recordFeedV2(FeedEntryDraft(penID: emptyPen.id, mode: .limited, occurredAt: .now, lines: [FeedLineDraft(ingredientID: fixture.ingredient.id, ingredientBatchID: fixture.batch.id, kilogramsText: "3")])),
            in: fixture.farmContext,
            context: fixture.context
        )) { error in
            guard case FarmCommandError.feedPenHasNoSheepOnDate = error else {
                return XCTFail("应阻止投喂发生日没有羊只的圈舍，实际错误：\(error)")
            }
        }
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<FeedRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).isEmpty)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.batch, context: fixture.context)), 10)
    }

    func testFeedPenEligibilityUsesOccurredDayInsteadOfCurrentPen() throws {
        let fixture = try makeFixture(initialKilograms: "10")
        let currentPen = PenRecord(farmID: fixture.farmContext.farmID, name: "当前圈舍")
        let calendar = Calendar.current
        let transferDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -30, to: Date.now)!)
        let transfer = TransferRecord(farmID: fixture.farmContext.farmID, sheepID: fixture.sheep.id, fromPenID: fixture.pen.id, toPenID: currentPen.id, occurredAt: calendar.date(byAdding: .hour, value: 12, to: transferDay)!)
        fixture.sheep.currentPenID = currentPen.id
        fixture.context.insert(currentPen)
        fixture.context.insert(transfer)
        try fixture.context.save()

        let beforeTransfer = FeedPenEligibility.headCounts(on: calendar.date(byAdding: .day, value: -1, to: transferDay)!, sheep: [fixture.sheep], transfers: [transfer], removals: [])
        XCTAssertEqual(beforeTransfer[fixture.pen.id], 1)
        XCTAssertNil(beforeTransfer[currentPen.id])

        let transferDate = FeedPenEligibility.headCounts(on: transferDay, sheep: [fixture.sheep], transfers: [transfer], removals: [])
        XCTAssertNil(transferDate[fixture.pen.id])
        XCTAssertEqual(transferDate[currentPen.id], 1)
    }

    func testTodayFeedPensUseAuthoritativeCurrentPenSnapshot() throws {
        let fixture = try makeFixture(initialKilograms: "10")
        let currentPen = PenRecord(farmID: fixture.farmContext.farmID, name: "当前实际圈舍")
        fixture.sheep.currentPenID = currentPen.id
        fixture.sheep.legacyPenSnapshotIsAuthoritative = true
        fixture.context.insert(currentPen)
        try fixture.context.save()

        let today = FeedPenEligibility.headCounts(on: .now, sheep: [fixture.sheep], transfers: [], removals: [])
        XCTAssertNil(today[fixture.pen.id])
        XCTAssertEqual(today[currentPen.id], 1)

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date.now)!
        let historical = FeedPenEligibility.headCounts(on: yesterday, sheep: [fixture.sheep], transfers: [], removals: [])
        XCTAssertEqual(historical[fixture.pen.id], 1)
        XCTAssertNil(historical[currentPen.id])
    }

    func testFeedExclusionRecommendsOnlyUnweanedLambsWithinOneAndHalfMonths() throws {
        let fixture = try makeFixture(initialKilograms: "10")
        let calendar = Calendar.current
        let feedDate = Date.now
        fixture.sheep.birthAt = calendar.date(byAdding: .day, value: -30, to: feedDate)

        let older = SheepRecord(
            farmID: fixture.farmContext.farmID,
            earTag: "F046",
            breed: "杜泊",
            sex: .ewe,
            penID: fixture.pen.id,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000),
            birthAt: calendar.date(byAdding: .day, value: -46, to: feedDate)
        )
        let weaned = SheepRecord(
            farmID: fixture.farmContext.farmID,
            earTag: "F020",
            breed: "杜泊",
            sex: .ewe,
            penID: fixture.pen.id,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000),
            birthAt: calendar.date(byAdding: .day, value: -20, to: feedDate)
        )
        let weaning = WeaningRecord(
            farmID: fixture.farmContext.farmID,
            sheepID: weaned.id,
            occurredAt: calendar.date(byAdding: .day, value: -1, to: feedDate)!,
            weanWeightText: "12"
        )

        let recommendations = FeedExclusionRecommendation.nursingLambIDs(
            on: feedDate,
            sheep: [fixture.sheep, older, weaned],
            weanings: [weaning]
        )
        XCTAssertEqual(recommendations, Set([fixture.sheep.id]))
    }

    func testMixedFeedAllocationKeepsEnteredIngredientTotalsExact() throws {
        let corn = UUID()
        let meal = UUID()
        let penA = UUID()
        let penB = UUID()
        let penMixtures = FeedMixtureAllocator.mixtureByPen(
            totalKilograms: 120,
            weightedHeadCounts: [(penA, 1), (penB, 2)]
        )
        XCTAssertEqual(penMixtures[penA], 40)
        XCTAssertEqual(penMixtures[penB], 80)

        let allocation = FeedMixtureAllocator.ingredientsByPen(
            components: [(corn, 100), (meal, 20)],
            penMixtures: [(penA, 40), (penB, 80)]
        )
        XCTAssertEqual(NSDecimalNumber(decimal: allocation[penA]?[corn] ?? 0).doubleValue, 100.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual((allocation[penA]?[corn] ?? 0) + (allocation[penB]?[corn] ?? 0), 100)
        XCTAssertEqual((allocation[penA]?[meal] ?? 0) + (allocation[penB]?[meal] ?? 0), 20)
        XCTAssertEqual(allocation.values.reduce(Decimal.zero) { partial, lines in partial + lines.values.reduce(0, +) }, 120)
    }

    func testMultiPenFeedBatchRollsBackAllPensWhenCombinedStockIsInsufficient() throws {
        let fixture = try makeFixture(initialKilograms: "10")
        let secondPen = PenRecord(farmID: fixture.farmContext.farmID, name: "育肥二圈")
        let secondSheep = SheepRecord(farmID: fixture.farmContext.farmID, earTag: "F002", breed: "杜泊", sex: .ewe, penID: secondPen.id, enteredAt: Date(timeIntervalSince1970: 1_700_000_000))
        fixture.context.insert(secondPen)
        fixture.context.insert(secondSheep)
        try fixture.context.save()

        let commands: [FarmCommand] = [fixture.pen.id, secondPen.id].map { penID in
            .recordFeedV2(FeedEntryDraft(
                penID: penID,
                mode: .limited,
                occurredAt: .now,
                lines: [FeedLineDraft(ingredientID: fixture.ingredient.id, ingredientBatchID: fixture.batch.id, kilogramsText: "6")]
            ))
        }
        XCTAssertThrowsError(try fixture.service.executeBatch(commands, in: fixture.farmContext, context: fixture.context))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<FeedRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).isEmpty)
        XCTAssertEqual(try XCTUnwrap(try FeedStockLedger.balance(for: fixture.batch, context: fixture.context)), 10)
    }

    private func cloudPayload(from data: Data) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }

    private struct Fixture {
        let context: ModelContext
        let farmContext: FarmContext
        let service: FarmCommandService
        let batch: FeedIngredientBatchRecord
        let ingredient: FeedIngredientRecord
        let pen: PenRecord
        let sheep: SheepRecord
    }

    private func makeFixture(initialKilograms: String) throws -> Fixture {
        let container = try AppSchema.makeContainer(name: "feed-rebuild-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "feed-test-\(UUID().uuidString)", displayName: "投喂测试")
        let farm = FarmRecord(ownerAccountID: account.id, name: "投喂测试场")
        let pen = PenRecord(farmID: farm.id, name: "育肥一圈")
        let sheep = SheepRecord(farmID: farm.id, earTag: "F001", breed: "杜泊", sex: .ewe, penID: pen.id, enteredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let ingredient = FeedIngredientRecord(farmID: farm.id, name: "散装玉米", unit: "千克", category: "能量饲料", nutrientSnapshotJSON: FeedNutritionCodec.encode(FeedNutrients(dryMatter: 86, crudeProtein: 9, me: 2.8)), kind: .custom)
        let batch = FeedIngredientBatchRecord(farmID: farm.id, ingredientID: ingredient.id, batchName: "散装仓", pricePerKilogramText: "2", stockWeightConfirmed: true, initialKilogramsText: initialKilograms, remainingKilogramsText: initialKilograms, note: "", isActive: true)
        context.insert(account)
        context.insert(farm)
        context.insert(pen)
        context.insert(sheep)
        context.insert(ingredient)
        context.insert(batch)
        try context.save()
        return Fixture(context: context, farmContext: FarmContext(accountID: account.id, farmID: farm.id, role: .owner), service: FarmCommandService(), batch: batch, ingredient: ingredient, pen: pen, sheep: sheep)
    }
}
