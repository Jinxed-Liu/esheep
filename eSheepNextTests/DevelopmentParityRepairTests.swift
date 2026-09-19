import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class DevelopmentParityRepairTests: XCTestCase {
    func testRepairPlanPreservesPositiveParityAndDoesNotInventLambings() {
        let farm = UUID(), now = Date()
        let sheep = (0..<4).map { SheepRecord(farmID: farm, earTag: "E\($0)", breed: "", sex: .ewe, penID: nil, enteredAt: now.addingTimeInterval(-1000)) }
        let facts = [
            ReproductionRecord(farmID: farm, eweID: sheep[0].id, kind: .lambing, occurredAt: now.addingTimeInterval(-100), parity: 0),
            ReproductionRecord(farmID: farm, eweID: sheep[1].id, kind: .parityBaseline, occurredAt: now.addingTimeInterval(-100), parity: 4),
            ReproductionRecord(farmID: farm, eweID: sheep[3].id, kind: .parityBaseline, occurredAt: now.addingTimeInterval(-100), parity: 0)
        ]
        let plan = DevelopmentParityRepair.plan(sheep: sheep, records: facts, at: now)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.first { $0.sheepID == sheep[0].id }?.newParity, 1)
        XCTAssertEqual(plan.first { $0.sheepID == sheep[2].id }?.newParity, 0)
        XCTAssertFalse(plan.contains { $0.sheepID == sheep[1].id || $0.sheepID == sheep[3].id })
        XCTAssertEqual(facts[0].parity, 0)
    }

    func testParityCorrectionPreservesImportedEmptyBreedAndHistoryAndIsIdempotent() throws {
        let container = try AppSchema.makeContainer(name: "parity-repair-\(UUID())", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "parity-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "胎次测试")
        let now = Date()
        let ewe = SheepRecord(farmID: farm.id, earTag: "E1", breed: "", sex: .ewe, penID: nil, enteredAt: now.addingTimeInterval(-1000))
        let birth = ReproductionRecord(farmID: farm.id, eweID: ewe.id, kind: .lambing, occurredAt: now.addingTimeInterval(-100), lambCount: 2, parity: 0)
        context.insert(account); context.insert(farm); context.insert(ewe); context.insert(birth)
        try context.save()
        try FarmCommandService().execute(.updateSheepProfile(sheepID: ewe.id, earTag: ewe.earTag, breed: ewe.breed, sex: .ewe, birthAt: nil, currentParity: 1, parityRecordedAt: now, note: ewe.note), in: FarmContext(accountID: account.id, farmID: farm.id, role: .owner), context: context)
        let records = try context.fetch(FetchDescriptor<ReproductionRecord>())
        XCTAssertEqual(ewe.breed, "")
        XCTAssertEqual(birth.parity, 0)
        XCTAssertEqual(birth.lambCount, 2)
        XCTAssertEqual(records.filter { $0.kind == .lambing }.count, 1)
        XCTAssertEqual(LambingEntrySemantics.currentParity(eweID: ewe.id, farmID: farm.id, before: now.addingTimeInterval(1), records: records), 1)
        XCTAssertTrue(DevelopmentParityRepair.plan(sheep: [ewe], records: records, at: now.addingTimeInterval(1)).isEmpty)

        let commandID = UUID(), eventID = UUID(), deviceID = UUID()
        let candidate = DevelopmentParityRepair.Candidate(sheepID: ewe.id, earTag: ewe.earTag,
            revision: 1, oldParity: 0, newParity: 1, lambingCount: 1)
        let canonical = ReproductionRecord(id: StableCloudUUID.derived(namespace: eventID, name: "esheep-cloud-profile-parity"),
            farmID: farm.id, eweID: ewe.id, kind: .parityBaseline, occurredAt: now, parity: 1)
        context.insert(canonical)
        XCTAssertThrowsError(try DevelopmentParityRepair.reconcileConfirmedBaselines(candidates: [candidate],
            commandIDs: [commandID], farmID: farm.id, accountID: account.id, context: context))
        let intent = ESheepCloudPendingIntent(commandID: commandID, farmID: farm.id, farmGeneration: 1,
            accountID: account.id, deviceID: deviceID, deviceSequence: 1, sourceRequestID: commandID,
            commandKind: "sheep.patchProfile", commandEnvelopeData: Data(), commandDigest: "",
            affectedStreamsData: Data(), affectedFieldsData: Data(), prerequisiteCommandIDsData: Data(),
            requiredAssetIDsData: Data(), lifecycle: .accepted, createdAt: now, occurredAt: now)
        intent.serverResultData = Data("accepted-fixture".utf8)
        context.insert(intent)
        context.insert(ESheepCloudEventReceipt(eventID: eventID, farmID: farm.id, farmGeneration: 1,
            eventSequence: 1, commandID: commandID, eventDigest: "test", appliedProjectionDigest: "test"))
        try context.save()
        XCTAssertEqual(try DevelopmentParityRepair.reconcileConfirmedBaselines(candidates: [candidate],
            commandIDs: [commandID], farmID: farm.id, accountID: account.id, context: context), 1)
        XCTAssertEqual(try DevelopmentParityRepair.reconcileConfirmedBaselines(candidates: [candidate],
            commandIDs: [commandID], farmID: farm.id, accountID: account.id, context: context), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReproductionRecord>()).count, 2)
        XCTAssertEqual(birth.parity, 0)
    }
}
