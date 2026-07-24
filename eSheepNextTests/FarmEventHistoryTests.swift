import SwiftData
import XCTest
@testable import eSheepNext

final class FarmEventHistoryTests: XCTestCase {
    func testEventEditCapabilitiesDistinguishFactsFromLedgers() {
        func event(_ entityType: CloudEntityType) -> FarmEventSnapshot {
            FarmEventSnapshot(
                id: UUID(),
                entityType: entityType,
                category: .herd,
                occurredAt: .now,
                recordedAt: .now,
                title: "测试",
                subject: "A001",
                detail: "",
                note: "",
                fields: []
            )
        }

        XCTAssertEqual(event(.sheep).editCapability, .recordProduction)
        XCTAssertEqual(event(.weight).editCapability, .editHistoricalFacts)
        XCTAssertEqual(event(.transfer).editCapability, .editHistoricalFacts)
        XCTAssertEqual(event(.removal).editCapability, .editHistoricalFacts)
        XCTAssertEqual(event(.health).editCapability, .editHistoricalFacts)
        XCTAssertEqual(event(.reproduction).editCapability, .editHistoricalFacts)
        XCTAssertNil(event(.feed).editCapability)
        XCTAssertNil(event(.inventoryTransaction).editCapability)
        XCTAssertNil(event(.semenTransaction).editCapability)
    }

    @MainActor
    func testAdministratorCanCorrectHistoryButCannotDeleteIt() throws {
        let container = try AppSchema.makeContainer(name: "event-edit-permission-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let sheep = SheepRecord(farmID: farmID, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        let weight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "40", occurredAt: .now)
        context.insert(sheep)
        context.insert(weight)
        try context.save()

        let service = FarmCommandService()
        let farmContext = FarmContext(accountID: UUID(), farmID: farmID, role: .administrator)
        try service.execute(
            .correctWeight(
                originalID: weight.id,
                kilogramsText: "41.5",
                occurredAt: weight.occurredAt,
                note: "复称",
                reason: "录入错误"
            ),
            in: farmContext,
            context: context
        )

        XCTAssertNotNil(weight.deletedAt)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<WeightRecord>()).first(where: { $0.deletedAt == nil })?.kilogramsText,
            "41.5"
        )
        XCTAssertThrowsError(
            try service.execute(
                .tombstoneEntity(entityType: .weight, entityID: weight.id, reason: "删除"),
                in: farmContext,
                context: context
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, FarmPermissionError.denied(.deleteProtectedFacts).localizedDescription)
        }
    }

    func testSearchMatchesNormalizedEventContentAndKeepsCurrentOrder() {
        let first = FarmEventSnapshot(
            id: UUID(),
            entityType: .removal,
            category: .herd,
            occurredAt: Date(timeIntervalSince1970: 200),
            recordedAt: Date(timeIntervalSince1970: 200),
            title: "出售",
            subject: "A-001",
            detail: "客户自提",
            note: "Café 批次",
            fields: [.init(label: "圈舍", value: "东一圈")]
        )
        let second = FarmEventSnapshot(
            id: UUID(),
            entityType: .note,
            category: .note,
            occurredAt: Date(timeIntervalSince1970: 100),
            recordedAt: Date(timeIntervalSince1970: 100),
            title: "备注",
            subject: "B-002",
            detail: "观察采食",
            note: "",
            fields: []
        )

        XCTAssertEqual(
            FarmEventSearch.filter([first, second], query: "  a-001  ", category: nil, scope: .all).map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            FarmEventSearch.filter([first, second], query: "CAFE", category: nil, scope: .all).map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            FarmEventSearch.filter([first, second], query: "", category: nil, scope: .all).map(\.id),
            [first.id, second.id]
        )
        XCTAssertTrue(FarmEventSearch.filter([first, second], query: "A-001", category: .note, scope: .all).isEmpty)
    }

    func testEventRowIdentityIncludesEntityType() {
        let sharedID = UUID()
        let weight = FarmEventSnapshot(
            id: sharedID,
            entityType: .weight,
            category: .herd,
            occurredAt: .now,
            recordedAt: .now,
            title: "称重",
            subject: "A-001",
            detail: "42 千克",
            note: "",
            fields: []
        )
        let note = FarmEventSnapshot(
            id: sharedID,
            entityType: .note,
            category: .note,
            occurredAt: .now,
            recordedAt: .now,
            title: "备注",
            subject: "A-001",
            detail: "观察采食",
            note: "",
            fields: []
        )

        XCTAssertNotEqual(weight.rowIdentity, note.rowIdentity)
    }

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

    func testRemovalBatchHistoryUsesOneBatchTotalWithoutPerSheepAmount() async throws {
        let container = try AppSchema.makeContainer(name: "event-removal-batch-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let batchID = UUID()
        let first = SheepRecord(farmID: farmID, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        let second = SheepRecord(farmID: farmID, earTag: "A002", breed: "杜泊", sex: .ram, penID: nil, enteredAt: .now)
        let occurredAt = Date(timeIntervalSince1970: 300)
        context.insert(first)
        context.insert(second)
        context.insert(RemovalRecord(
            farmID: farmID,
            sheepID: first.id,
            kind: .sold,
            reason: "整批出售",
            removalBatchID: batchID,
            batchTotalAmountText: "2500",
            occurredAt: occurredAt
        ))
        context.insert(RemovalRecord(
            farmID: farmID,
            sheepID: second.id,
            kind: .sold,
            reason: "整批出售",
            removalBatchID: batchID,
            batchTotalAmountText: "2500",
            occurredAt: occurredAt
        ))
        try context.save()

        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        let removals = events.filter { $0.entityType == .removal }

        XCTAssertEqual(removals.count, 2)
        for event in removals {
            let fields = Dictionary(uniqueKeysWithValues: event.fields.map { ($0.label, $0.value) })
            XCTAssertEqual(fields["同批离场数量"], "2 只")
            XCTAssertEqual(fields["同批总售卖金额"], "2500")
            XCTAssertNil(fields["售卖金额"])
        }
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
    func testDeletingNonTimelineEventDoesNotReplayDailyHerdHistory() throws {
        let container = try AppSchema.makeContainer(name: "event-delete-no-history-replay-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "一号圈")
        let enteredAt = Date.now.addingTimeInterval(-86_400)
        let sheep = SheepRecord(farmID: farmID, earTag: "P001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: enteredAt)
        let weight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "42", occurredAt: .now)
        let marker = DailyPenCountRecord(
            farmID: farmID,
            penID: pen.id,
            purpose: sheep.purpose,
            date: Calendar.current.startOfDay(for: enteredAt),
            count: 1
        )
        context.insert(pen)
        context.insert(sheep)
        context.insert(weight)
        context.insert(marker)
        try context.save()

        try FarmCommandService().execute(
            .tombstoneEntity(entityType: .weight, entityID: weight.id, reason: "录入错误"),
            in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
            context: context
        )

        let daily = try context.fetch(FetchDescriptor<DailyPenCountRecord>()).filter { $0.farmID == farmID }
        XCTAssertEqual(daily.map(\.id), [marker.id])
        XCTAssertNotNil(weight.deletedAt)
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
