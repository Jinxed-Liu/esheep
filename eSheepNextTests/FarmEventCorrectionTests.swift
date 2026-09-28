import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FarmEventCorrectionTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let context: ModelContext
        let farm: FarmRecord
        let sheep: SheepRecord
        let admin: FarmContext
        let service = FarmCommandService()
    }
    private func fixture() throws -> Fixture {
        let context = ModelContext(try AppSchema.makeContainer(name: "event-correction-\(UUID())", isStoredInMemoryOnly: true))
        let account = AccountProfile(appleUserIdentifier: "events-\(UUID())", displayName: "管理员")
        let farm = FarmRecord(ownerAccountID: account.id, name: "测试场")
        let sheep = SheepRecord(farmID: farm.id, earTag: "E001", breed: "湖羊", purpose: SheepPurpose.sucklingLamb.rawValue, sex: .ewe, penID: nil, enteredAt: Date.now.addingTimeInterval(-86400 * 10), birthAt: Date.now.addingTimeInterval(-86400 * 12))
        context.insert(account); context.insert(farm); context.insert(sheep); try context.save()
        return Fixture(context: context, farm: farm, sheep: sheep, admin: .init(accountID: account.id, farmID: farm.id, role: .administrator))
    }

    func testNoteCorrectionIsAuditedAndWorkerIsDenied() throws {
        let f = try fixture()
        let note = NoteRecord(farmID: f.farm.id, sheepID: f.sheep.id, text: "原备注", occurredAt: .now)
        f.context.insert(note); try f.context.save()
        let draft = FarmEventCorrectionDraft(kind: .note, entityID: note.id, sourceEventID: note.id, occurredAt: Date(timeIntervalSince1970: 1800000000), text: "修正备注", value: "")
        XCTAssertThrowsError(try f.service.execute(.correctEvent(draft), in: .init(accountID: f.admin.accountID, farmID: f.farm.id, role: .worker), context: f.context))
        try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context)
        XCTAssertEqual(note.text, "修正备注")
        XCTAssertEqual(note.revision, 2)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.kindRawValue == DomainOperationKind.correctEvent.rawValue }.count, 1)
        let encoded = try FarmCommandCloudPayloadEncoder.encode(.correctEvent(draft))
        let payload = try JSONDecoder.cloud.decode(FarmCommandCloudPayload.self, from: encoded)
        XCTAssertEqual(try FarmEventCorrectionDraft.decode(payload), draft)
        let cloud = try ESheepCloudCommandFactoryV2.make(command: .correctEvent(draft), farmID: f.farm.id, primaryEntityType: "note", primaryEntityID: note.id)
        XCTAssertEqual(cloud.kind, "event.correct")
        let wire = try ESheepCloudCanonicalCodec.encode(cloud.payload)
        XCTAssertEqual(try ESheepCloudCanonicalCodec.decode(ESheepCloudCommandPayloadV2.self, from: wire), cloud.payload)
    }

    func testInventoryEditRejectsNegativeBalanceAndKeepsOriginalReceipt() throws {
        let f = try fixture()
        let lotID = UUID()
        let receipt = InventoryTransactionRecord(farmID: f.farm.id, inventoryLotID: lotID, kind: .receipt, quantityText: "10", occurredAt: .now)
        let used = InventoryTransactionRecord(farmID: f.farm.id, inventoryLotID: lotID, kind: .consumption, quantityText: "8", occurredAt: .now)
        f.context.insert(receipt); f.context.insert(used); try f.context.save()
        var draft = FarmEventCorrectionDraft(kind: .inventory, entityID: receipt.id, sourceEventID: receipt.id, occurredAt: .now, text: "实物复核", value: "5")
        XCTAssertThrowsError(try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context))
        XCTAssertEqual(receipt.quantityText, "10")
        draft.value = "12"
        try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context)
        XCTAssertEqual(receipt.quantityText, "12")
        XCTAssertEqual(used.quantityText, "8")
        XCTAssertNil(used.deletedAt)
    }

    func testWeaningCorrectionUpdatesWeightAndLifecycleHistory() throws {
        let f = try fixture()
        let record = WeaningRecord(farmID: f.farm.id, sheepID: f.sheep.id, occurredAt: .now, weanWeightText: "20", birthAt: f.sheep.birthAt)
        f.context.insert(record); try f.context.save()
        let date = Date.now.addingTimeInterval(-86400)
        try f.service.execute(.correctEvent(.init(kind: .weaning, entityID: record.id, sourceEventID: record.id, occurredAt: date, text: "复核", value: "22.5")), in: f.admin, context: f.context)
        XCTAssertEqual(record.weanWeight, Decimal(string: "22.5"))
        XCTAssertEqual(record.occurredAt, date)
        XCTAssertEqual(f.sheep.purpose, SheepPurpose.weanedLamb.rawValue)
    }

    func testPurposeCorrectionAndWithdrawalPreserveOriginalAudit() throws {
        let f = try fixture()
        try f.service.execute(.care(.setSheepPurpose(sheepID: f.sheep.id, purpose: .weanedLamb, reason: "原用途", expectedRevision: f.sheep.revision)), in: f.admin, context: f.context)
        let originals = try f.context.fetch(FetchDescriptor<DomainOperation>())
        let fact = try XCTUnwrap(SheepPurposeTimeline.facts(from: originals).first)
        var draft = FarmEventCorrectionDraft(kind: .purpose, entityID: f.sheep.id, sourceEventID: fact.id, occurredAt: fact.occurredAt, text: "更正原因", value: SheepPurpose.sucklingLamb.rawValue)
        try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context)
        var operations = try f.context.fetch(FetchDescriptor<DomainOperation>())
        XCTAssertEqual(SheepPurposeTimeline.facts(from: operations).first?.purpose, .sucklingLamb)
        XCTAssertEqual(f.sheep.purpose, SheepPurpose.sucklingLamb.rawValue)
        draft.withdraw = true
        try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context)
        operations = try f.context.fetch(FetchDescriptor<DomainOperation>())
        XCTAssertTrue(SheepPurposeTimeline.facts(from: operations).isEmpty)
        XCTAssertTrue(operations.contains { $0.id == fact.id })
        XCTAssertEqual(f.sheep.purpose, SheepPurpose.sucklingLamb.rawValue)
    }

    func testParityCorrectionAndWithdrawalDoNotDeleteSheep() throws {
        let f = try fixture()
        let record = ReproductionRecord(farmID: f.farm.id, eweID: f.sheep.id, kind: .parityBaseline, occurredAt: .now, parity: 2, note: "原确认")
        f.context.insert(record); try f.context.save()
        var draft = FarmEventCorrectionDraft(kind: .parity, entityID: record.id, sourceEventID: record.id, occurredAt: .now, text: "复核", value: "3")
        try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context)
        XCTAssertEqual(record.parity, 3)
        draft.withdraw = true
        try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context)
        XCTAssertNotNil(record.deletedAt)
        XCTAssertNil(f.sheep.deletedAt)
    }

    func testDirectFeedCorrectionPreservesQuantityAndMovesLedgerTime() throws {
        let f = try fixture()
        let record = FeedRecord(farmID: f.farm.id, penID: UUID(), mode: .limited, occurredAt: .now, note: "原备注")
        let consumption = FeedStockTransactionRecord(farmID: f.farm.id, ingredientBatchID: UUID(), kind: .consumption, quantityText: "5", occurredAt: record.occurredAt, sourceRecordID: record.id)
        f.context.insert(record); f.context.insert(consumption); try f.context.save()
        let date = Date.now.addingTimeInterval(-3600)
        try f.service.execute(.correctEvent(.init(kind: .feed, entityID: record.id, sourceEventID: record.id, occurredAt: date, text: "修正投喂时间", value: "")), in: f.admin, context: f.context)
        XCTAssertEqual(record.occurredAt, date)
        XCTAssertEqual(consumption.occurredAt, date)
        XCTAssertEqual(consumption.quantityText, "5")
    }
    func testSemenCorrectionRejectsInsufficientBalance() throws {
        let f = try fixture()
        let semen = SemenRecord(farmID: f.farm.id, code: "S001", breed: "湖羊")
        let receipt = SemenTransactionRecord(farmID: f.farm.id, semenID: semen.id, kind: .receipt, quantityText: "10", occurredAt: .now)
        let used = SemenTransactionRecord(farmID: f.farm.id, semenID: semen.id, kind: .consumption, quantityText: "8", occurredAt: .now)
        f.context.insert(semen); f.context.insert(receipt); f.context.insert(used); try f.context.save()
        var draft = FarmEventCorrectionDraft(kind: .semen, entityID: receipt.id, sourceEventID: receipt.id, occurredAt: receipt.occurredAt, text: "复核", value: "5")
        XCTAssertThrowsError(try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context))
        XCTAssertEqual(receipt.quantityText, "10")
        draft.value = "12"
        try f.service.execute(.correctEvent(draft), in: f.admin, context: f.context)
        XCTAssertEqual(try FarmCareCommandHandler.semenBalance(semen, context: f.context), 4)
    }

    func testBatchDepartureEditAndWithdrawalKeepSheep() throws {
        let f = try fixture()
        let batch = ProductionBatchRecord(farmID: f.farm.id, name: "观察", purpose: "育肥", startedAt: f.sheep.enteredAt)
        let member = BatchMembershipRecord(farmID: f.farm.id, batchID: batch.id, sheepID: f.sheep.id, joinedAt: f.sheep.enteredAt)
        member.leftAt = .now; member.leaveReason = "原原因"
        f.context.insert(batch); f.context.insert(member); try f.context.save()
        let date = Date.now.addingTimeInterval(-3600)
        try f.service.execute(.correctEvent(.init(kind: .departure, entityID: member.id, sourceEventID: member.id, occurredAt: date, text: "复核原因", value: "")), in: f.admin, context: f.context)
        XCTAssertEqual(member.leftAt, date)
        XCTAssertEqual(batch.endedAt, date)
        try f.service.execute(.restoreBatchMembership(membershipID: member.id, restoredAt: .now, reason: "撤回误移出"), in: f.admin, context: f.context)
        XCTAssertNil(member.leftAt)
        XCTAssertEqual(batch.status, .active)
        XCTAssertNil(f.sheep.deletedAt)
    }

    func testBirthWithdrawalClearsBirthDateAndPreservesSheep() async throws {
        let f = try fixture()
        let events = try await FarmEventHistoryActor(container: f.context.container).load(farmID: f.farm.id)
        let birth = try XCTUnwrap(events.first { $0.title == "出生" })
        let command = try FarmEventDeletionCommandResolver.command(for: birth, reason: "录入错误", farmID: f.farm.id, context: f.context)
        try f.service.execute(command, in: f.admin, context: f.context)
        XCTAssertNil(f.sheep.birthAt)
        XCTAssertNil(f.sheep.deletedAt)
    }

    func testRemoteCorrectionUsesSameRecordAndDoesNotTouchOtherFarm() throws {
        let f = try fixture()
        let note = NoteRecord(farmID: f.farm.id, sheepID: f.sheep.id, text: "原备注", occurredAt: .now)
        f.context.insert(note); try f.context.save()
        let command = FarmCommand.correctEvent(.init(kind: .note, entityID: note.id, sourceEventID: note.id, occurredAt: Date(timeIntervalSince1970: 1800000000), text: "另一设备修正", value: ""))
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let envelope = CloudOperationEnvelope(farmID: f.farm.id, entityID: note.id, entityType: CloudEntityType.note.rawValue, schemaVersion: 2, revision: 2, baseRevision: 1, operationID: UUID(), modifiedAt: .now, modifiedByAccountID: f.admin.accountID, modifiedByDeviceID: UUID(), payload: payload, payloadDigest: CloudPayloadDigest.hex(for: payload), capabilityCertificate: "test", operationSignature: Data(), deletedAt: nil)
        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: f.context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(note.text, "另一设备修正")
        XCTAssertThrowsError(try FarmEventCorrection.validate(.init(kind: .note, entityID: note.id, sourceEventID: note.id, occurredAt: .now, text: "跨牧场", value: ""), farmID: UUID(), context: f.context))
    }

}

private extension JSONDecoder {
    static var cloud: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
