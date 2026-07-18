import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FarmAnalyticsTests: XCTestCase {
    func testLambingCommandStoresOffspringAndCloudPayload() throws {
        let container = try AppSchema.makeContainer(name: "lambing-command-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "lambing-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "产羔测试场")
        let ewe = SheepRecord(farmID: farm.id, earTag: "E001", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, penID: nil, enteredAt: .now)
        context.insert(account); context.insert(farm); context.insert(ewe)
        try context.save()

        let offspring = [
            LambingOffspringDraft(earTag: "L001", sex: .male, birthWeightText: "3.2"),
            LambingOffspringDraft(earTag: "L002", sex: .female, birthWeightText: "3.0")
        ]
        try FarmCommandService().execute(.recordReproduction(eweID: ewe.id, kind: .lambing, occurredAt: .now, sireID: nil, semenName: nil, result: "", lambCount: 2, parity: 1, birthDeadCount: 0, offspring: offspring, note: ""), in: FarmContext(accountID: account.id, farmID: farm.id, role: .owner), context: context)

        let lambing = try XCTUnwrap(context.fetch(FetchDescriptor<ReproductionRecord>()).first)
        let details = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.lambingRecordID == lambing.id }
        XCTAssertEqual(details.count, 2)
        XCTAssertEqual(Set(details.map(\.legacyEarTag)), ["L001", "L002"])
        let operation = try XCTUnwrap(context.fetch(FetchDescriptor<DomainOperation>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(FarmCommandCloudPayload.self, from: operation.payload)
        XCTAssertEqual(payload.lambingOffspring.count, 2)
        XCTAssertEqual(payload.integers["parity"], 1)
        XCTAssertEqual(payload.integers["birthDeadCount"], 0)
    }

    func testRemoteLambingReplayCreatesOffspringAtomically() throws {
        let container = try AppSchema.makeContainer(name: "remote-lambing-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID(); let eweID = UUID(); let targetID = UUID()
        context.insert(SheepRecord(id: eweID, farmID: farmID, earTag: "E100", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, penID: nil, enteredAt: .now))
        try context.save()
        let command = FarmCommand.recordReproduction(eweID: eweID, kind: .lambing, occurredAt: .now, sireID: nil, semenName: nil, result: "", lambCount: 1, parity: 2, birthDeadCount: 0, offspring: [LambingOffspringDraft(earTag: "L100", sex: .female, birthWeightText: "3.1")], note: "云端重放")
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let envelope = CloudOperationEnvelope(farmID: farmID, entityID: targetID, entityType: CloudEntityType.reproduction.rawValue, schemaVersion: 2, revision: 1, baseRevision: 0, operationID: UUID(), modifiedAt: .now, modifiedByAccountID: UUID(), modifiedByDeviceID: UUID(), payload: payload, payloadDigest: CloudPayloadDigest.hex(for: payload), capabilityCertificate: "test", operationSignature: Data(), deletedAt: nil)

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.id == targetID }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.lambingRecordID == targetID }.count, 1)
    }

    func testPlusCompatibleLambAndWeightRules() {
        let farmID = UUID(); let eweID = UUID(); let lambID = UUID()
        let dayOne = makeDate(year: 2026, month: 1, day: 1)
        let dayTen = makeDate(year: 2026, month: 1, day: 10)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: eweID, earTag: "E001", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: makeDate(year: 2024, month: 1, day: 1), enteredAt: dayOne, removedAt: nil),
                .init(id: lambID, earTag: "L001", breed: "湖羊", purpose: "断奶羔羊", sex: .ram, status: .active, initialPenID: nil, currentPenID: nil, birthAt: dayOne, enteredAt: dayOne, removedAt: nil)
            ],
            pens: [],
            weights: [.init(id: UUID(), sheepID: lambID, kilograms: 20, occurredAt: dayTen)],
            weanings: [.init(id: UUID(), sheepID: lambID, occurredAt: dayTen, weanWeight: 19, birthAt: dayOne, birthWeight: 3, damID: eweID, litterSize: 1)],
            lambings: [.init(id: UUID(), eweID: eweID, occurredAt: dayOne, total: 1, parity: 1, birthDeadCount: 0, offspring: [.init(id: UUID(), sheepID: lambID, earTag: "L001", sex: .male, birthWeight: 3)])],
            removals: [], transfers: [], batchMemberships: [], feeds: []
        )
        let lambResult = LambAnalyticsEngine.calculate(snapshot: snapshot, selectedYear: "2026")
        XCTAssertEqual(lambResult.lambStats.totalLambs, 1)
        XCTAssertEqual(lambResult.lambStats.months.first?.maleLambs, 1)
        XCTAssertEqual(lambResult.weaning.months.first?.averageADG ?? 0, 1_777.777_777, accuracy: 0.001)

        let cohort = WeightGainAnalyticsEngine.cohort(snapshot: snapshot, snapshotDate: dayTen)
        XCTAssertEqual(try XCTUnwrap(cohort.weightTrend.last?.value), 20, accuracy: 0.001)
    }

    func testPlusCompatibleLinearRegression() {
        let sheepID = UUID()
        let points = [
            WeightScatterPoint(sheepID: sheepID, date: .now, baselineWeight: 10, adg: 0.1),
            WeightScatterPoint(sheepID: sheepID, date: .now, baselineWeight: 20, adg: 0.2),
            WeightScatterPoint(sheepID: sheepID, date: .now, baselineWeight: 30, adg: 0.3)
        ]
        let regression = WeightGainAnalyticsEngine.trendline(for: points, kind: .linear)
        XCTAssertEqual(regression.count, 25)
        XCTAssertEqual(try XCTUnwrap(regression.first?.y), 0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(regression.last?.y), 0.3, accuracy: 0.001)
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }
}
