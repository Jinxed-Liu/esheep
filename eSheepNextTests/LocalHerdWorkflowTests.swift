import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class LocalHerdWorkflowTests: XCTestCase {
    func testPenAndSheepProfileUpdatesStayInsideCommandPipeline() throws {
        let fixture = try makeFixture()
        let secondPen = PenRecord(farmID: fixture.farm.id, name: "二号圈")
        fixture.context.insert(secondPen)
        let sheep = SheepRecord(farmID: fixture.farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: secondPen.id, enteredAt: .now)
        let conflictingSheep = SheepRecord(farmID: fixture.farm.id, earTag: "B001", breed: "杜泊", sex: .ram, penID: nil, enteredAt: .now)
        fixture.context.insert(sheep)
        fixture.context.insert(conflictingSheep)
        try fixture.context.save()

        XCTAssertThrowsError(try fixture.service.execute(.setPenActive(penID: secondPen.id, isActive: false), in: fixture.farmContext, context: fixture.context))
        try fixture.service.execute(.updatePen(penID: secondPen.id, name: "后备母羊圈", note: "东侧"), in: fixture.farmContext, context: fixture.context)
        XCTAssertThrowsError(try fixture.service.execute(.updateSheepProfile(sheepID: sheep.id, earTag: " b001 ", breed: "湖羊", sex: .ewe, birthAt: nil, note: ""), in: fixture.farmContext, context: fixture.context))
        try fixture.service.execute(.updateSheepProfile(sheepID: sheep.id, earTag: "A-001", breed: "湖羊改良", sex: .ewe, birthAt: Date(timeIntervalSince1970: 1_700_000_000), note: "重点观察"), in: fixture.farmContext, context: fixture.context)

        XCTAssertEqual(secondPen.name, "后备母羊圈")
        XCTAssertEqual(sheep.earTag, "A-001")
        XCTAssertEqual(sheep.breed, "湖羊改良")
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).contains { $0.kindRawValue == DomainOperationKind.updateSheepProfile.rawValue })
    }

    func testCorrectionsTombstoneOriginalsAndRebuildCurrentState() throws {
        let fixture = try makeFixture()
        let penA = PenRecord(farmID: fixture.farm.id, name: "A圈")
        let penB = PenRecord(farmID: fixture.farm.id, name: "B圈")
        let penC = PenRecord(farmID: fixture.farm.id, name: "C圈")
        [penA, penB, penC].forEach(fixture.context.insert)
        let enteredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sheep = SheepRecord(farmID: fixture.farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: penA.id, enteredAt: enteredAt)
        fixture.context.insert(sheep)
        try fixture.context.save()

        try fixture.service.execute(.recordWeight(sheepID: sheep.id, kilogramsText: "40", occurredAt: enteredAt.addingTimeInterval(100), note: "原值"), in: fixture.farmContext, context: fixture.context)
        let originalWeight = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<WeightRecord>()).first { $0.deletedAt == nil })
        try fixture.service.execute(.correctWeight(originalID: originalWeight.id, kilogramsText: "41.5", occurredAt: originalWeight.occurredAt, note: "复称", reason: "录入错误"), in: fixture.farmContext, context: fixture.context)

        try fixture.service.execute(.transferSheep(sheepID: sheep.id, toPenID: penB.id, occurredAt: enteredAt.addingTimeInterval(200), note: "原转群"), in: fixture.farmContext, context: fixture.context)
        let originalTransfer = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<TransferRecord>()).first { $0.deletedAt == nil })
        try fixture.service.execute(.correctTransfer(originalID: originalTransfer.id, toPenID: penC.id, occurredAt: originalTransfer.occurredAt, note: "改到C圈", reason: "圈舍选错"), in: fixture.farmContext, context: fixture.context)

        try fixture.service.execute(.removeSheep(sheepID: sheep.id, kind: .sold, reason: "出售", amountText: "1000", occurredAt: enteredAt.addingTimeInterval(300), note: ""), in: fixture.farmContext, context: fixture.context)
        let originalRemoval = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<RemovalRecord>()).first { $0.deletedAt == nil })
        try fixture.service.execute(.correctRemoval(originalID: originalRemoval.id, kind: .culled, reason: "淘汰", amountText: nil, occurredAt: originalRemoval.occurredAt, note: "", correctionReason: "类型选错"), in: fixture.farmContext, context: fixture.context)

        let activeWeight = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<WeightRecord>()).first { $0.deletedAt == nil })
        let activeTransfer = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<TransferRecord>()).first { $0.deletedAt == nil })
        let activeRemoval = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<RemovalRecord>()).first { $0.deletedAt == nil })
        XCTAssertEqual(activeWeight.kilogramsText, "41.5")
        XCTAssertEqual(activeTransfer.toPenID, penC.id)
        XCTAssertEqual(activeRemoval.kind, .culled)
        XCTAssertEqual(sheep.currentPenID, nil)
        XCTAssertEqual(sheep.status, .removed)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.reason.hasPrefix("修正：") }.count, 3)

        try fixture.service.execute(.restoreSheep(removalID: activeRemoval.id), in: fixture.farmContext, context: fixture.context)
        XCTAssertEqual(sheep.status, .active)
        XCTAssertEqual(sheep.currentPenID, penC.id)
    }

    func testHistorySnapshotLoadsOneSheepAsOneBackgroundUpdate() async throws {
        let fixture = try makeFixture()
        let pen = PenRecord(farmID: fixture.farm.id, name: "当前圈")
        let sheep = SheepRecord(farmID: fixture.farm.id, earTag: "H001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now)
        let otherSheep = SheepRecord(farmID: fixture.farm.id, earTag: "H002", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now)
        let activeWeight = WeightRecord(farmID: fixture.farm.id, sheepID: sheep.id, kilogramsText: "42", occurredAt: .now)
        let deletedWeight = WeightRecord(farmID: fixture.farm.id, sheepID: sheep.id, kilogramsText: "41", occurredAt: .now.addingTimeInterval(-60))
        deletedWeight.deletedAt = .now
        let unrelatedWeight = WeightRecord(farmID: fixture.farm.id, sheepID: otherSheep.id, kilogramsText: "80", occurredAt: .now)
        let tombstone = TombstoneRecord(
            farmID: fixture.farm.id,
            entityType: CloudEntityType.weight.rawValue,
            entityID: deletedWeight.id,
            deletedByAccountID: fixture.account.id,
            reason: "用户撤销称重记录",
            revision: 1
        )
        fixture.context.insert(pen)
        fixture.context.insert(sheep)
        fixture.context.insert(otherSheep)
        fixture.context.insert(activeWeight)
        fixture.context.insert(deletedWeight)
        fixture.context.insert(unrelatedWeight)
        fixture.context.insert(tombstone)
        try fixture.context.save()

        let snapshot = try await SheepRecordHistoryActor(container: fixture.container).load(
            farmID: fixture.farm.id,
            sheepID: sheep.id
        )

        XCTAssertEqual(snapshot.weights.map(\.id), [activeWeight.id])
        XCTAssertEqual(snapshot.tombstones.map(\.id), [tombstone.id])
        XCTAssertEqual(snapshot.penName(pen.id), pen.name)
    }

    func testBackupValidatesInStagingAndRestoresIdempotently() throws {
        let source = try makeFixture()
        let pen = PenRecord(farmID: source.farm.id, name: "一号圈")
        let sheep = SheepRecord(farmID: source.farm.id, earTag: "B001", breed: "杜泊", sex: .ram, penID: pen.id, enteredAt: .now)
        source.context.insert(pen); source.context.insert(sheep)
        try source.service.execute(.recordWeight(sheepID: sheep.id, kilogramsText: "55", occurredAt: .now, note: "备份样本"), in: source.farmContext, context: source.context)
        let data = try FarmLocalBackupService.export(farmID: source.farm.id, context: source.context)
        let preview = try FarmLocalBackupService.preview(data: data)
        XCTAssertEqual(preview.envelope.payload.sheep.count, 1)

        let destination = try makeFixture(farmName: "空牧场")
        let first = try FarmLocalBackupService.restore(preview, into: destination.farm, account: destination.account, context: destination.context)
        let second = try FarmLocalBackupService.restore(preview, into: destination.farm, account: destination.account, context: destination.context)
        XCTAssertFalse(first.alreadyRestored)
        XCTAssertTrue(second.alreadyRestored)
        XCTAssertEqual(try destination.context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == destination.farm.id }.count, 1)
        XCTAssertEqual(destination.farm.name, source.farm.name)

        let nonemptyDestination = try makeFixture(farmName: "非空牧场")
        nonemptyDestination.context.insert(PenRecord(farmID: nonemptyDestination.farm.id, name: "已有圈舍"))
        try nonemptyDestination.context.save()
        XCTAssertThrowsError(try FarmLocalBackupService.restore(preview, into: nonemptyDestination.farm, account: nonemptyDestination.account, context: nonemptyDestination.context))
        XCTAssertEqual(try nonemptyDestination.context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == nonemptyDestination.farm.id }.count, 0)

        var decoded = try JSONDecoder.iso8601.decode(FarmBackupEnvelopeV1.self, from: data)
        decoded = .init(schemaVersion: decoded.schemaVersion, payload: decoded.payload, checksum: "bad-checksum")
        let invalid = try JSONEncoder.iso8601.encode(decoded)
        XCTAssertThrowsError(try FarmLocalBackupService.preview(data: invalid))
    }

    private func makeFixture(farmName: String = "本地流程牧场") throws -> Fixture {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试账户")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: farmName)
        context.insert(account); context.insert(farm); try context.save()
        return Fixture(container: container, context: context, account: account, farm: farm, service: FarmCommandService())
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let account: AccountProfile
        let farm: FarmRecord
        let service: FarmCommandService
        var farmContext: FarmContext { .init(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role) }
    }
}

private extension JSONDecoder { static var iso8601: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value } }
private extension JSONEncoder { static var iso8601: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]; return value } }
