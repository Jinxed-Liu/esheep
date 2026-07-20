import SwiftData
import XCTest
@testable import eSheepNext

final class FarmEventHistoryTests: XCTestCase {
    func testTimelineIncludesFarmEventsAndSortsByOccurredAtDescending() async throws {
        let container = try AppSchema.makeContainer(name: "event-history-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let otherFarmID = UUID()
        let sheep = SheepRecord(farmID: farmID, earTag: "E001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: Date(timeIntervalSince1970: 100))
        let olderWeight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "45.2", occurredAt: Date(timeIntervalSince1970: 200))
        let newerNote = NoteRecord(farmID: farmID, sheepID: sheep.id, text: "观察采食", occurredAt: Date(timeIntervalSince1970: 300))
        let deletedNote = NoteRecord(farmID: farmID, sheepID: sheep.id, text: "已撤销", occurredAt: Date(timeIntervalSince1970: 400))
        deletedNote.deletedAt = .now
        let otherFarmNote = NoteRecord(farmID: otherFarmID, sheepID: nil, text: "其他牧场", occurredAt: Date(timeIntervalSince1970: 500))
        context.insert(sheep)
        context.insert(olderWeight)
        context.insert(newerNote)
        context.insert(deletedNote)
        context.insert(otherFarmNote)
        try context.save()

        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)

        XCTAssertEqual(events.map(\.entityType), [.note, .weight, .sheep])
        XCTAssertEqual(events.map(\.occurredAt), events.map(\.occurredAt).sorted(by: >))
        XCTAssertEqual(events.first?.subject, "E001")
        XCTAssertFalse(events.contains { $0.detail.contains("其他牧场") || $0.detail.contains("已撤销") })
    }

    func testWeaningEventContainsLambAndPedigreeExportFields() async throws {
        let container = try AppSchema.makeContainer(name: "event-weaning-export-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "羔羊一舍")
        let dam = SheepRecord(farmID: farmID, earTag: "D001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now)
        let sire = SheepRecord(farmID: farmID, earTag: "S001", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: pen.id, enteredAt: .now)
        let birthAt = Date(timeIntervalSince1970: 1_735_689_600)
        let lamb = SheepRecord(
            farmID: farmID,
            earTag: "L001",
            breed: "湖羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: birthAt,
            birthAt: birthAt,
            damID: dam.id,
            sireID: sire.id
        )
        let weaning = WeaningRecord(
            farmID: farmID,
            sheepID: lamb.id,
            occurredAt: birthAt.addingTimeInterval(60 * 86_400),
            weanWeightText: "25.5",
            birthAt: birthAt,
            birthWeightText: "3.2",
            averageDailyGainText: "0.372",
            damID: dam.id,
            litterSize: 3,
            note: "留种观察"
        )
        context.insert(pen)
        context.insert(dam)
        context.insert(sire)
        context.insert(lamb)
        context.insert(weaning)
        try context.save()

        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        let event = try XCTUnwrap(events.first { $0.id == weaning.id })
        let fields = Dictionary(uniqueKeysWithValues: event.fields.map { ($0.label, $0.value) })

        XCTAssertEqual(event.entityType, .weaning)
        XCTAssertEqual(event.subject, "L001")
        XCTAssertEqual(fields["耳号"], "L001")
        XCTAssertEqual(fields["当前圈舍"], "羔羊一舍")
        XCTAssertEqual(fields["断奶重kg"], "25.5")
        XCTAssertEqual(fields["出生重kg"], "3.2")
        XCTAssertEqual(fields["日增重kg/天"], "0.372")
        XCTAssertEqual(fields["母本"], "D001")
        XCTAssertEqual(fields["父本来源"], "S001")
        XCTAssertEqual(fields["胎只数"], "3")
    }

    @MainActor
    func testDeletingFeedEventTombstonesParentAndLinesAndCreatesAuditOutbox() throws {
        let container = try AppSchema.makeContainer(name: "event-feed-delete-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()
        let feed = FeedRecord(farmID: farmID, penID: UUID(), mode: .limited, occurredAt: .now)
        let line = FeedRecordLine(farmID: farmID, feedRecordID: feed.id, ingredientID: UUID(), kilogramsText: "12", ingredientNameSnapshot: "玉米")
        context.insert(feed)
        context.insert(line)
        try context.save()

        try FarmCommandService().execute(
            .tombstoneEntity(entityType: .feed, entityID: feed.id, reason: "录入错误"),
            in: FarmContext(accountID: accountID, farmID: farmID, role: .owner),
            context: context
        )

        XCTAssertNotNil(feed.deletedAt)
        XCTAssertNotNil(line.deletedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.entityID == feed.id }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.entityID == feed.id && $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).count, 1)
    }

    @MainActor
    func testDeletingInventoryReceiptCannotCreateNegativeBalance() throws {
        let container = try AppSchema.makeContainer(name: "event-inventory-delete-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let lot = InventoryLotRecord(farmID: farmID, catalogName: "疫苗", kind: .vaccination, startingQuantityText: "10")
        let receipt = InventoryTransactionRecord(farmID: farmID, inventoryLotID: lot.id, kind: .receipt, quantityText: "10", occurredAt: .now)
        let consumption = InventoryTransactionRecord(farmID: farmID, inventoryLotID: lot.id, kind: .consumption, quantityText: "8", occurredAt: .now)
        context.insert(lot)
        context.insert(receipt)
        context.insert(consumption)
        try context.save()

        XCTAssertThrowsError(
            try FarmCommandService().execute(
                .tombstoneEntity(entityType: .inventoryTransaction, entityID: receipt.id, reason: "误入库"),
                in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
                context: context
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.insufficientInventory.localizedDescription)
        }
        XCTAssertNil(receipt.deletedAt)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TombstoneRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutboxItem>()).isEmpty)
    }

    @MainActor
    func testDeletingSheepCreationIsRejectedWhenProductionFactsExist() throws {
        let container = try AppSchema.makeContainer(name: "event-sheep-delete-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let sheep = SheepRecord(farmID: farmID, earTag: "E002", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        let weight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "40", occurredAt: .now)
        context.insert(sheep)
        context.insert(weight)
        try context.save()

        XCTAssertThrowsError(
            try FarmCommandService().execute(
                .tombstoneEntity(entityType: .sheep, entityID: sheep.id, reason: "误建档"),
                in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
                context: context
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.protectedSheepReferences.localizedDescription)
        }
        XCTAssertNil(sheep.deletedAt)
        XCTAssertNil(weight.deletedAt)
    }
}
