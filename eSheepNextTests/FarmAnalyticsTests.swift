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
        let payloadObject = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let legacyOffspring = try XCTUnwrap((payloadObject["lambingOffspring"] as? [[String: Any]])?.first)
        XCTAssertNil(legacyOffspring["isStillborn"], "旧产羔载荷不包含新增可选字段时仍须可解码")
        XCTAssertNil(legacyOffspring["deletedByLambingRevocation"])
        let envelope = CloudOperationEnvelope(farmID: farmID, entityID: targetID, entityType: CloudEntityType.reproduction.rawValue, schemaVersion: 2, revision: 1, baseRevision: 0, operationID: UUID(), modifiedAt: .now, modifiedByAccountID: UUID(), modifiedByDeviceID: UUID(), payload: payload, payloadDigest: CloudPayloadDigest.hex(for: payload), capabilityCertificate: "test", operationSignature: Data(), deletedAt: nil)

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .duplicate)
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
        XCTAssertEqual(cohort.weightTrend.map(\.value), [3, 20])
        XCTAssertEqual(try XCTUnwrap(cohort.weightTrend.last?.value), 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cohort.latestAverageADG), 17.0 / 9.0, accuracy: 0.001)
    }

    func testWeightAnalysisUsesWeaningAndBirthWithoutStandaloneWeightRecords() throws {
        let farmID = UUID()
        let lambID = UUID()
        let birthAt = makeDate(year: 2026, month: 4, day: 1)
        let weaningAt = makeDate(year: 2026, month: 5, day: 1)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: lambID, earTag: "L-WEAN", breed: "湖羊", purpose: "断奶羔羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: birthAt, enteredAt: birthAt, removedAt: nil)
            ],
            pens: [],
            weights: [],
            weanings: [
                .init(id: UUID(), sheepID: lambID, occurredAt: weaningAt, weanWeight: 18.2, birthAt: birthAt, birthWeight: 3.2, damID: nil, litterSize: 1)
            ],
            lambings: [], removals: [], transfers: [], batchMemberships: [], feeds: []
        )

        let cohort = WeightGainAnalyticsEngine.cohort(snapshot: snapshot, snapshotDate: weaningAt)

        XCTAssertEqual(cohort.weightTrend.map(\.value), [3.2, 18.2])
        XCTAssertEqual(try XCTUnwrap(cohort.latestAverageWeight), 18.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cohort.latestAverageADG), 0.5, accuracy: 0.001)
    }

    func testLambMonthlySexAveragesUseValidSamplesAndBirthCohort() throws {
        let farmID = UUID(); let eweID = UUID(); let ramLambID = UUID(); let eweLambID = UUID()
        let birthAt = makeDate(year: 2026, month: 2, day: 1)
        let weaningAt = makeDate(year: 2026, month: 2, day: 11)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: eweID, earTag: "E001", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: birthAt, removedAt: nil),
                .init(id: ramLambID, earTag: "L-M", breed: "湖羊", purpose: "断奶羔羊", sex: .ram, status: .active, initialPenID: nil, currentPenID: nil, birthAt: birthAt, enteredAt: birthAt, removedAt: nil),
                .init(id: eweLambID, earTag: "L-F", breed: "湖羊", purpose: "断奶羔羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: birthAt, enteredAt: birthAt, removedAt: nil)
            ],
            pens: [], weights: [],
            weanings: [
                .init(id: UUID(), sheepID: ramLambID, occurredAt: weaningAt, weanWeight: 13, birthAt: birthAt, birthWeight: 3, damID: eweID, litterSize: 2),
                .init(id: UUID(), sheepID: eweLambID, occurredAt: weaningAt, weanWeight: 10.5, birthAt: birthAt, birthWeight: 2.5, damID: eweID, litterSize: 2)
            ],
            lambings: [
                .init(id: UUID(), eweID: eweID, occurredAt: birthAt, total: 2, parity: 2, birthDeadCount: 0, offspring: [
                    .init(id: UUID(), sheepID: ramLambID, earTag: "L-M", sex: .male, birthWeight: 3),
                    .init(id: UUID(), sheepID: eweLambID, earTag: "L-F", sex: .female, birthWeight: 2.5)
                ])
            ],
            removals: [], transfers: [], batchMemberships: [], feeds: []
        )

        let result = LambAnalyticsEngine.calculate(snapshot: snapshot, selectedYear: "2026")
        let lambMonth = try XCTUnwrap(result.lambStats.months.first)
        XCTAssertEqual(lambMonth.maleLambs, 1)
        XCTAssertEqual(lambMonth.femaleLambs, 1)
        XCTAssertEqual(lambMonth.maleWeightAverage, 3, accuracy: 0.001)
        XCTAssertEqual(lambMonth.femaleWeightAverage, 2.5, accuracy: 0.001)
        XCTAssertEqual(lambMonth.maleADGAverage, 1_000, accuracy: 0.001)
        XCTAssertEqual(lambMonth.femaleADGAverage, 800, accuracy: 0.001)

        let weanMonth = try XCTUnwrap(result.weaning.months.first)
        XCTAssertEqual(weanMonth.maleAverageWeight, 13, accuracy: 0.001)
        XCTAssertEqual(weanMonth.femaleAverageWeight, 10.5, accuracy: 0.001)
        XCTAssertEqual(weanMonth.maleAverageADG, 1_000, accuracy: 0.001)
        XCTAssertEqual(weanMonth.femaleAverageADG, 800, accuracy: 0.001)
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

    func testBatchWeightAnalysisKeepsOnlyFactsInsideHistoricalMembershipInterval() throws {
        let farmID = UUID()
        let sheepID = UUID()
        let batchID = UUID()
        let beforeJoin = makeDate(year: 2026, month: 3, day: 1)
        let joinedAt = makeDate(year: 2026, month: 3, day: 2)
        let firstInBatch = makeDate(year: 2026, month: 3, day: 3)
        let secondInBatch = makeDate(year: 2026, month: 3, day: 4)
        let leftAt = makeDate(year: 2026, month: 3, day: 5)
        let afterLeaving = makeDate(year: 2026, month: 3, day: 6)
        let snapshotDate = makeDate(year: 2026, month: 3, day: 7)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: sheepID, earTag: "B001", breed: "湖羊", purpose: "留养", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: beforeJoin, removedAt: nil)
            ],
            pens: [],
            weights: [
                .init(id: UUID(), sheepID: sheepID, kilograms: 10, occurredAt: beforeJoin),
                .init(id: UUID(), sheepID: sheepID, kilograms: 20, occurredAt: firstInBatch),
                .init(id: UUID(), sheepID: sheepID, kilograms: 22, occurredAt: secondInBatch),
                .init(id: UUID(), sheepID: sheepID, kilograms: 30, occurredAt: afterLeaving)
            ],
            weanings: [], lambings: [], removals: [], transfers: [],
            batchMemberships: [.init(batchID: batchID, sheepID: sheepID, joinedAt: joinedAt, leftAt: leftAt)],
            feeds: []
        )

        let cohort = WeightGainAnalyticsEngine.cohort(snapshot: snapshot, batchID: batchID, snapshotDate: snapshotDate)

        XCTAssertEqual(cohort.sheepIDs, [sheepID])
        XCTAssertEqual(cohort.weightTrend.map(\.value), [20, 22])
        XCTAssertEqual(try XCTUnwrap(cohort.latestAverageWeight), 22, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cohort.latestAverageADG), 2, accuracy: 0.001)
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }
}
