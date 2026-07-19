import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class CareWorkflowTests: XCTestCase {
    func testBatchHealthCreatesStableSubjectsAndOneAuditableConsumption() throws {
        let fixture = try makeFixture()
        let pen = PenRecord(farmID: fixture.farm.id, name: "一号圈")
        let first = SheepRecord(farmID: fixture.farm.id, earTag: "E001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now.addingTimeInterval(-3_600))
        let second = SheepRecord(farmID: fixture.farm.id, earTag: "E002", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now.addingTimeInterval(-3_600))
        fixture.context.insert(pen); fixture.context.insert(first); fixture.context.insert(second)
        let lot = try receiveInventory(fixture, quantity: "20")
        let recordID = UUID()

        try fixture.service.execute(.care(.recordHealth(.init(id: recordID, batchID: UUID(), subjectIDs: [], penID: pen.id, catalogItemID: nil, kind: .vaccination, itemName: "三联四防", occurredAt: .now, note: "整圈免疫", inventoryLotID: lot.id, dosePerSubjectText: "2", unit: "毫升", route: "肌注", reminderAt: .now.addingTimeInterval(86_400)))), in: fixture.ownerContext, context: fixture.context)

        let links = try fixture.context.fetch(FetchDescriptor<HealthSubjectLink>()).filter { $0.healthRecordID == recordID }
        XCTAssertEqual(Set(links.map(\.sheepID)), Set([first.id, second.id]))
        let consumption = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<InventoryTransactionRecord>()).first { $0.sourceRecordID == recordID && $0.kind == .consumption })
        XCTAssertEqual(consumption.quantityText, "4")
        XCTAssertEqual(try FarmCareCommandHandler.inventoryBalance(lot, context: fixture.context), 16)

        first.currentPenID = nil
        XCTAssertEqual(Set(links.map(\.sheepID)), Set([first.id, second.id]), "转群不能改变健康事实的实际对象快照")
    }

    func testInsufficientInventoryRejectsWholeBatchWithoutPartialFacts() throws {
        let fixture = try makeFixture()
        let sheep = try insertEwe(fixture, earTag: "E001")
        let lot = try receiveInventory(fixture, quantity: "1")
        let draft = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: [sheep.id], penID: nil, catalogItemID: nil, kind: .treatment, itemName: "青霉素", occurredAt: .now, note: "", inventoryLotID: lot.id, dosePerSubjectText: "2", unit: "毫升", route: "肌注", reminderAt: nil)

        XCTAssertThrowsError(try fixture.service.execute(.care(.recordHealth(draft)), in: fixture.ownerContext, context: fixture.context))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<HealthSubjectLink>()).isEmpty)
        XCTAssertEqual(try FarmCareCommandHandler.inventoryBalance(lot, context: fixture.context), 1)
    }

    func testHealthCorrectionReversesOldInventoryAndRebuildsReminder() throws {
        let fixture = try makeFixture()
        let sheep = try insertEwe(fixture, earTag: "E001")
        let lot = try receiveInventory(fixture, quantity: "10")
        let oldID = UUID()
        let oldReminder = Date.now.addingTimeInterval(86_400)
        try fixture.service.execute(.care(.recordHealth(.init(id: oldID, batchID: UUID(), subjectIDs: [sheep.id], penID: nil, catalogItemID: nil, kind: .vaccination, itemName: "疫苗", occurredAt: .now, note: "", inventoryLotID: lot.id, dosePerSubjectText: "4", unit: "毫升", route: "肌注", reminderAt: oldReminder))), in: fixture.ownerContext, context: fixture.context)

        let replacementID = UUID()
        let newReminder = Date.now.addingTimeInterval(172_800)
        let replacement = CareHealthDraft(id: replacementID, batchID: UUID(), subjectIDs: [sheep.id], penID: nil, catalogItemID: nil, kind: .vaccination, itemName: "疫苗", occurredAt: .now, note: "剂量修正", inventoryLotID: lot.id, dosePerSubjectText: "2", unit: "毫升", route: "肌注", reminderAt: newReminder)
        try fixture.service.execute(.care(.correctHealth(originalID: oldID, replacement: replacement, reason: "剂量录错")), in: fixture.ownerContext, context: fixture.context)

        XCTAssertNotNil(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).first { $0.id == oldID }?.deletedAt)
        XCTAssertEqual(try FarmCareCommandHandler.inventoryBalance(lot, context: fixture.context), 8)
        let reminders = try fixture.context.fetch(FetchDescriptor<CareReminderRecord>())
        XCTAssertTrue(reminders.contains { $0.sourceEntityID == oldID && $0.deletedAt != nil })
        XCTAssertTrue(reminders.contains { $0.sourceEntityID == replacementID && $0.deletedAt == nil && $0.dueAt == newReminder })
    }

    func testBatchBreedingCreatesPerEweFactsAndPerFactSemenLedger() throws {
        let fixture = try makeFixture()
        let first = try insertEwe(fixture, earTag: "E001")
        let second = try insertEwe(fixture, earTag: "E002")
        let semen = SemenRecord(farmID: fixture.farm.id, code: "DORPER-01", breed: "杜泊", quantityText: "3")
        fixture.context.insert(semen)
        let batchID = UUID()
        let subjects = [CareReproductionSubjectDraft(eweID: first.id), CareReproductionSubjectDraft(eweID: second.id)]
        try fixture.service.execute(.care(.recordReproductionBatch(.init(id: batchID, kind: .breeding, subjects: subjects, occurredAt: .now, sireID: nil, semenID: semen.id, semenUnitsPerEweText: "1", note: "人工授精", reminderAt: .now.addingTimeInterval(45 * 86_400)))), in: fixture.ownerContext, context: fixture.context)

        let facts = try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.batchID == batchID }
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(Set(facts.map(\.eweID)), Set([first.id, second.id]))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<SemenTransactionRecord>()).filter { $0.kind == .consumption }.count, 2)
        XCTAssertEqual(try FarmCareCommandHandler.semenBalance(semen, context: fixture.context), 1)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<CareReminderRecord>()).filter { $0.kind == .pregnancyCheck }.count, 2)

        let corrected = try XCTUnwrap(facts.first)
        let replacement = CareReproductionBatchDraft(id: UUID(), kind: .breeding, subjects: [.init(eweID: corrected.eweID)], occurredAt: .now, sireID: nil, semenID: semen.id, semenUnitsPerEweText: "1", note: "修正", reminderAt: .now.addingTimeInterval(46 * 86_400))
        try fixture.service.execute(.care(.correctReproduction(originalID: corrected.id, replacement: replacement, reason: "日期录错")), in: fixture.ownerContext, context: fixture.context)
        XCTAssertNotNil(corrected.deletedAt)
        XCTAssertEqual(try FarmCareCommandHandler.semenBalance(semen, context: fixture.context), 1)
    }

    func testLambingCreatesPedigreeAndDuplicateEarTagRollsBack() throws {
        let fixture = try makeFixture()
        let ewe = try insertEwe(fixture, earTag: "E001")
        let ram = SheepRecord(farmID: fixture.farm.id, earTag: "R001", breed: "杜泊", sex: .ram, penID: nil, enteredAt: .now)
        fixture.context.insert(ram)
        let lambingID = UUID()
        try fixture.service.execute(.care(.recordLambing(.init(id: lambingID, eweID: ewe.id, occurredAt: .now, sireID: ram.id, semenID: nil, parity: 2, birthDeadCount: 0, offspring: [.init(earTag: "L001", sex: .ewe, birthWeightText: "3.2")], penID: nil, note: "顺产"))), in: fixture.ownerContext, context: fixture.context)

        let lamb = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<SheepRecord>()).first { $0.earTag == "L001" })
        XCTAssertEqual(lamb.damID, ewe.id)
        XCTAssertEqual(lamb.sireID, ram.id)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.lambingRecordID == lambingID }.count, 1)

        let before = try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).count
        let duplicate = CareLambingDraft(id: UUID(), eweID: ewe.id, occurredAt: .now, sireID: ram.id, semenID: nil, parity: 3, birthDeadCount: 0, offspring: [.init(earTag: "L001", sex: .ram, birthWeightText: "3")], penID: nil, note: "")
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(duplicate)), in: fixture.ownerContext, context: fixture.context))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).count, before)

        let invalidDeadCount = CareLambingDraft(id: UUID(), eweID: ewe.id, occurredAt: .now, sireID: ram.id, semenID: nil, parity: 3, birthDeadCount: 0, offspring: [.init(earTag: "", sex: .ram, birthWeightText: "2.5", createSheepRecord: false, isStillborn: true)], penID: nil, note: "")
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(invalidDeadCount)), in: fixture.ownerContext, context: fixture.context))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).count, before)
    }

    func testWorkerCanRecordButCannotMaintainCatalogAndCareBackupRestores() throws {
        let source = try makeFixture()
        let ewe = try insertEwe(source, earTag: "E001")
        let record = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: [ewe.id], penID: nil, catalogItemID: nil, kind: .treatment, itemName: "观察", occurredAt: .now, note: "", inventoryLotID: nil, dosePerSubjectText: nil, unit: "", route: "", reminderAt: nil)
        try source.service.execute(.care(.recordHealth(record)), in: source.workerContext, context: source.context)
        XCTAssertThrowsError(try source.service.execute(.care(.upsertHealthCatalog(id: UUID(), kindRawValue: HealthRecordKind.treatment.rawValue, name: "药品", category: "抗菌", unit: "毫升", defaultDoseText: "1", defaultRoute: "肌注", reminderIntervalDays: nil, note: "", isActive: true)), in: source.workerContext, context: source.context))

        let data = try FarmLocalBackupService.export(farmID: source.farm.id, context: source.context)
        let preview = try FarmLocalBackupService.preview(data: data)
        XCTAssertEqual(preview.envelope.payload.care?.health.count, 1)
        let destination = try makeFixture()
        _ = try FarmLocalBackupService.restore(preview, into: destination.farm, account: destination.account, context: destination.context)
        XCTAssertEqual(try destination.context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == destination.farm.id }.count, 1)
        XCTAssertEqual(try destination.context.fetch(FetchDescriptor<HealthSubjectLink>()).filter { $0.farmID == destination.farm.id }.count, 1)
    }

    func testRemoteCareReplayIsIdempotent() throws {
        let fixture = try makeFixture()
        let ewe = try insertEwe(fixture, earTag: "E001")
        let draft = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: [ewe.id], penID: nil, catalogItemID: nil, kind: .treatment, itemName: "远端健康事实", occurredAt: .now, note: "", inventoryLotID: nil, dosePerSubjectText: nil, unit: "", route: "", reminderAt: nil)
        let payload = try FarmCommandCloudPayloadEncoder.encode(.care(.recordHealth(draft)))
        let envelope = CloudOperationEnvelope(farmID: fixture.farm.id, entityID: draft.id, entityType: CloudEntityType.health.rawValue, schemaVersion: 2, revision: 1, baseRevision: 0, operationID: UUID(), modifiedAt: .now, modifiedByAccountID: fixture.account.effectiveAccountID, modifiedByDeviceID: UUID(), payload: payload, payloadDigest: CloudPayloadDigest.hex(for: payload), capabilityCertificate: "test", operationSignature: Data(), deletedAt: nil)

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: fixture.context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: fixture.context), .duplicate)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.id == draft.id }.count, 1)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<HealthSubjectLink>()).filter { $0.healthRecordID == draft.id }.count, 1)
    }

    func testCareCommandsRejectCrossFarmSubjects() throws {
        let fixture = try makeFixture()
        let otherFarm = FarmRecord(ownerAccountID: fixture.account.effectiveAccountID, name: "其他牧场")
        let otherSheep = SheepRecord(farmID: otherFarm.id, earTag: "X001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        fixture.context.insert(otherFarm); fixture.context.insert(otherSheep); try fixture.context.save()
        let draft = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: [otherSheep.id], penID: nil, catalogItemID: nil, kind: .treatment, itemName: "跨场记录", occurredAt: .now, note: "", inventoryLotID: nil, dosePerSubjectText: nil, unit: "", route: "", reminderAt: nil)
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordHealth(draft)), in: fixture.ownerContext, context: fixture.context))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).isEmpty)
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试账户")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "健康繁殖测试牧场")
        context.insert(account); context.insert(farm); try context.save()
        return .init(container: container, context: context, account: account, farm: farm, service: FarmCommandService())
    }

    private func insertEwe(_ fixture: Fixture, earTag: String) throws -> SheepRecord {
        let sheep = SheepRecord(farmID: fixture.farm.id, earTag: earTag, breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now.addingTimeInterval(-3_600))
        fixture.context.insert(sheep); try fixture.context.save(); return sheep
    }

    private func receiveInventory(_ fixture: Fixture, quantity: String) throws -> InventoryLotRecord {
        try fixture.service.execute(.care(.receiveInventory(id: UUID(), catalogName: "样品", catalogItemID: nil, kindRawValue: HealthRecordKind.vaccination.rawValue, batchNumber: "B-001", supplier: "测试供应商", unit: "毫升", expiresAt: .now.addingTimeInterval(30 * 86_400), quantityText: quantity, occurredAt: .now, note: "入库")), in: fixture.ownerContext, context: fixture.context)
        return try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<InventoryLotRecord>()).first { $0.farmID == fixture.farm.id })
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let account: AccountProfile
        let farm: FarmRecord
        let service: FarmCommandService
        var ownerContext: FarmContext { .init(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner) }
        var workerContext: FarmContext { .init(accountID: account.effectiveAccountID, farmID: farm.id, role: .worker) }
    }
}
