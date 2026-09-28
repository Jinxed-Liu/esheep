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
        context.insert(ReproductionRecord(id: LambingEntrySemantics.entryParityBaselineID(sheepID: ewe.id), farmID: farm.id, eweID: ewe.id, kind: .parityBaseline, occurredAt: ewe.enteredAt, parity: 0, note: "测试胎次基准"))
        try context.save()

        let offspring = [
            LambingOffspringDraft(earTag: "L001", sex: .male, birthWeightText: "3.2"),
            LambingOffspringDraft(earTag: "L002", sex: .female, birthWeightText: "3.0")
        ]
        try FarmCommandService().execute(.recordReproduction(eweID: ewe.id, kind: .lambing, occurredAt: .now, sireID: nil, semenName: nil, result: "", lambCount: 2, parity: 1, birthDeadCount: 0, offspring: offspring, note: ""), in: FarmContext(accountID: account.id, farmID: farm.id, role: .owner), context: context)

        let lambing = try XCTUnwrap(context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.kind == .lambing })
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
        let dayTwo = makeDate(year: 2026, month: 1, day: 2)
        let dayTen = makeDate(year: 2026, month: 1, day: 10)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: eweID, earTag: "E001", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: makeDate(year: 2024, month: 1, day: 1), enteredAt: dayOne, removedAt: nil),
                .init(id: lambID, earTag: "L001", breed: "湖羊", purpose: "断奶羔羊", sex: .ram, status: .active, initialPenID: nil, currentPenID: nil, birthAt: dayOne, enteredAt: dayOne, removedAt: nil)
            ],
            pens: [],
            weights: [
                .init(id: UUID(), sheepID: lambID, kilograms: 4, occurredAt: dayTwo),
                .init(id: UUID(), sheepID: lambID, kilograms: 20, occurredAt: dayTen)
            ],
            weanings: [.init(id: UUID(), sheepID: lambID, occurredAt: dayTen, weanWeight: 19, birthAt: dayOne, birthWeight: 3, damID: eweID, litterSize: 1)],
            lambings: [.init(id: UUID(), eweID: eweID, occurredAt: dayOne, total: 1, parity: 1, birthDeadCount: 0, offspring: [.init(id: UUID(), sheepID: lambID, earTag: "L001", sex: .male, birthWeight: 3)])],
            removals: [], transfers: [], batchMemberships: [], feeds: []
        )
        let lambResult = LambAnalyticsEngine.calculate(snapshot: snapshot, selectedYear: "2026")
        XCTAssertEqual(lambResult.lambStats.totalLambs, 1)
        XCTAssertEqual(lambResult.lambStats.months.first?.maleLambs, 1)
        XCTAssertEqual(lambResult.weaning.months.first?.averageADG ?? 0, 1_875, accuracy: 0.001)

        let cohort = WeightGainAnalyticsEngine.cohort(snapshot: snapshot, snapshotDate: dayTen)
        XCTAssertEqual(cohort.weightTrend.map(\.value), [3, 4, 20])
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
        let baselineAt = makeDate(year: 2026, month: 2, day: 2)
        let weaningAt = makeDate(year: 2026, month: 2, day: 11)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: eweID, earTag: "E001", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: birthAt, removedAt: nil),
                .init(id: ramLambID, earTag: "L-M", breed: "湖羊", purpose: "断奶羔羊", sex: .ram, status: .active, initialPenID: nil, currentPenID: nil, birthAt: birthAt, enteredAt: birthAt, removedAt: nil),
                .init(id: eweLambID, earTag: "L-F", breed: "湖羊", purpose: "断奶羔羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: birthAt, enteredAt: birthAt, removedAt: nil)
            ],
            pens: [],
            weights: [
                .init(id: UUID(), sheepID: ramLambID, kilograms: 4, occurredAt: baselineAt),
                .init(id: UUID(), sheepID: eweLambID, kilograms: 3.3, occurredAt: baselineAt)
            ],
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

    func testWeaningGainUsesEarliestActualPostBirthWeightBeforeWeaning() throws {
        let sheepID = UUID()
        let birthAt = makeDate(year: 2026, month: 3, day: 1)
        let baselineAt = makeDate(year: 2026, month: 3, day: 3)
        let laterAt = makeDate(year: 2026, month: 3, day: 10)
        let weaningAt = makeDate(year: 2026, month: 3, day: 20)
        let baselineID = UUID()
        let samples = [
            WeaningGainSample(id: UUID(), sheepID: sheepID, kilograms: 2.8, occurredAt: makeDate(year: 2026, month: 2, day: 28)),
            WeaningGainSample(id: baselineID, sheepID: sheepID, kilograms: 4.2, occurredAt: baselineAt),
            WeaningGainSample(id: UUID(), sheepID: sheepID, kilograms: 7, occurredAt: laterAt),
            WeaningGainSample(id: UUID(), sheepID: sheepID, kilograms: 21, occurredAt: weaningAt),
            WeaningGainSample(id: UUID(), sheepID: sheepID, kilograms: 22, occurredAt: makeDate(year: 2026, month: 3, day: 21))
        ]

        let result = try XCTUnwrap(WeaningGainSemantics.calculate(
            sheepID: sheepID,
            birthAt: birthAt,
            weaningAt: weaningAt,
            weaningWeight: 20,
            samples: samples
        ))

        XCTAssertEqual(result.baseline.id, baselineID)
        XCTAssertEqual(result.baseline.kilograms, 4.2, accuracy: 0.001)
        XCTAssertEqual(result.intervalDays, 17)
        XCTAssertEqual(result.gramsPerDay, (20 - 4.2) / 17 * 1_000, accuracy: 0.001)
    }

    func testWeaningAnalyticsDoesNotFabricateADGWithoutActualWeight() throws {
        let farmID = UUID()
        let lambID = UUID()
        let birthAt = makeDate(year: 2026, month: 4, day: 1)
        let weaningAt = makeDate(year: 2026, month: 6, day: 1)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: lambID, earTag: "L-NO-WEIGHT", breed: "湖羊", purpose: "断奶羔羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: birthAt, enteredAt: birthAt, removedAt: nil)
            ],
            pens: [],
            weights: [],
            weanings: [
                .init(id: UUID(), sheepID: lambID, occurredAt: weaningAt, weanWeight: 20, birthAt: birthAt, birthWeight: 3.2, damID: nil, litterSize: 1)
            ],
            lambings: [], removals: [], transfers: [], batchMemberships: [], feeds: []
        )

        let month = try XCTUnwrap(LambAnalyticsEngine.calculate(snapshot: snapshot, selectedYear: "2026").weaning.months.first)

        XCTAssertEqual(month.adgCount, 0)
        XCTAssertEqual(month.abnormalCount, 1)
    }

    func testReproductionSlicesUseFixedEndDatePenCohortAndPriorLambings() throws {
        let farmID = UUID()
        let penA = UUID()
        let penB = UUID()
        let movedEweID = UUID()
        let stayedEweID = UUID()
        let enteredAt = makeDate(year: 2024, month: 1, day: 1)
        let firstLambing = makeDate(year: 2025, month: 1, day: 1)
        let movedSecondLambing = makeDate(year: 2025, month: 7, day: 1)
        let stayedSecondLambing = makeDate(year: 2025, month: 8, day: 1)
        let movedAt = makeDate(year: 2025, month: 12, day: 20)
        let rangeEnd = makeDate(year: 2026, month: 1, day: 10)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: movedEweID, earTag: "E-MOVED", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, status: .active, initialPenID: penA, currentPenID: penB, birthAt: makeDate(year: 2023, month: 1, day: 1), enteredAt: enteredAt, removedAt: nil),
                .init(id: stayedEweID, earTag: "E-STAYED", breed: "杜泊", purpose: "繁殖母羊", sex: .ewe, status: .active, initialPenID: penA, currentPenID: penA, birthAt: makeDate(year: 2023, month: 1, day: 1), enteredAt: enteredAt, removedAt: nil)
            ],
            pens: [
                .init(id: penA, name: "一号舍"),
                .init(id: penB, name: "二号舍")
            ],
            weights: [],
            weanings: [],
            lambings: [
                .init(id: UUID(), eweID: movedEweID, occurredAt: firstLambing, total: 1, parity: nil, birthDeadCount: nil, offspring: []),
                .init(id: UUID(), eweID: movedEweID, occurredAt: movedSecondLambing, total: 1, parity: nil, birthDeadCount: nil, offspring: []),
                .init(id: UUID(), eweID: stayedEweID, occurredAt: firstLambing, total: 1, parity: nil, birthDeadCount: nil, offspring: []),
                .init(id: UUID(), eweID: stayedEweID, occurredAt: stayedSecondLambing, total: 1, parity: nil, birthDeadCount: nil, offspring: [])
            ],
            removals: [],
            transfers: [
                .init(id: UUID(), sheepID: movedEweID, toPenID: penB, occurredAt: movedAt, recordedAt: movedAt)
            ],
            batchMemberships: [],
            feeds: []
        )
        let filter = ReproductionAnalyticsFilter(
            startDate: movedSecondLambing,
            endDate: rangeEnd,
            penScope: .pen(penB),
            breed: "湖羊"
        )

        let result = ReproductionAnalyticsEngine.calculate(snapshot: snapshot, filter: filter)

        XCTAssertEqual(result.cohortCount, 1)
        XCTAssertEqual(result.intervalPoints.first?.date, movedSecondLambing)
        XCTAssertEqual(result.intervalPoints.first?.average, Double(FarmAnalyticsDate.days(from: firstLambing, to: movedSecondLambing)))
        XCTAssertEqual(result.intervalPoints.last?.count, 1)
        XCTAssertEqual(result.postpartumPoints.last?.average, Double(FarmAnalyticsDate.days(from: movedSecondLambing, to: rangeEnd)))
        XCTAssertEqual(result.incompleteLambingCount, 1, "节律图应使用产羔日期，但缺字段记录仍须在依赖完整字段的指标中提示")

        let beforeTransfer = ReproductionAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(
                startDate: movedSecondLambing,
                endDate: makeDate(year: 2025, month: 12, day: 1),
                penScope: .pen(penB),
                breed: "湖羊"
            )
        )
        XCTAssertEqual(beforeTransfer.cohortCount, 0, "羊舍切片必须按查询结束日，而不是当前圈舍字段")

        let wrongBreed = ReproductionAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(startDate: movedSecondLambing, endDate: rangeEnd, penScope: .pen(penB), breed: "杜泊")
        )
        XCTAssertEqual(wrongBreed.cohortCount, 0)
    }

    func testReproductionFilterOptionsRespectRemovalAndUnassignedAtCutoff() {
        let farmID = UUID()
        let assignedPenID = UUID()
        let activeAssignedID = UUID()
        let activeUnassignedID = UUID()
        let removedID = UUID()
        let cutoff = makeDate(year: 2026, month: 3, day: 1)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: activeAssignedID, earTag: "E-A", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, status: .active, initialPenID: assignedPenID, currentPenID: assignedPenID, birthAt: nil, enteredAt: makeDate(year: 2025, month: 1, day: 1), removedAt: nil),
                .init(id: activeUnassignedID, earTag: "E-U", breed: "杜泊", purpose: "后备母羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: makeDate(year: 2025, month: 1, day: 1), removedAt: nil),
                .init(id: removedID, earTag: "E-R", breed: "萨福克", purpose: "繁殖母羊", sex: .ewe, status: .removed, initialPenID: UUID(), currentPenID: nil, birthAt: nil, enteredAt: makeDate(year: 2025, month: 1, day: 1), removedAt: makeDate(year: 2026, month: 2, day: 1))
            ],
            pens: [.init(id: assignedPenID, name: "繁殖舍")],
            weights: [], weanings: [], lambings: [],
            removals: [.init(sheepID: removedID, kind: .sold, occurredAt: makeDate(year: 2026, month: 2, day: 1))],
            transfers: [], batchMemberships: [], feeds: []
        )

        let options = ReproductionAnalyticsEngine.filterOptions(snapshot: snapshot, asOf: cutoff)

        XCTAssertEqual(options.penIDs, [assignedPenID])
        XCTAssertTrue(options.includesUnassigned)
        XCTAssertEqual(options.breeds, ["杜泊", "湖羊"])
    }

    func testReproductionCohortIncludesEveryInHerdEweAndExcludesUndatedLegacyRemoval() throws {
        let farmID = UUID()
        let activeEweID = UUID()
        let undatedRemovedEweID = UUID()
        let firstLambing = makeDate(year: 2025, month: 1, day: 1)
        let secondLambing = makeDate(year: 2025, month: 8, day: 1)
        let cutoff = makeDate(year: 2026, month: 1, day: 1)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: activeEweID, earTag: "E-ACTIVE", breed: "湖羊", purpose: "育肥羊", sex: .ewe, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: makeDate(year: 2024, month: 1, day: 1), removedAt: nil),
                .init(id: undatedRemovedEweID, earTag: "E-REMOVED", breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, status: .removed, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: makeDate(year: 2024, month: 1, day: 1), removedAt: nil)
            ],
            pens: [],
            weights: [],
            weanings: [],
            lambings: [
                .init(id: UUID(), eweID: activeEweID, occurredAt: firstLambing, total: 1, parity: nil, birthDeadCount: nil, offspring: []),
                .init(id: UUID(), eweID: activeEweID, occurredAt: secondLambing, total: 1, parity: nil, birthDeadCount: nil, offspring: []),
                .init(id: UUID(), eweID: undatedRemovedEweID, occurredAt: firstLambing, total: 1, parity: nil, birthDeadCount: nil, offspring: []),
                .init(id: UUID(), eweID: undatedRemovedEweID, occurredAt: secondLambing, total: 1, parity: nil, birthDeadCount: nil, offspring: [])
            ],
            removals: [],
            transfers: [],
            batchMemberships: [],
            feeds: []
        )

        let result = ReproductionAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(startDate: firstLambing, endDate: cutoff)
        )

        XCTAssertEqual(result.cohortCount, 1, "当前母羊群应包含所有用途的在群母羊，并排除缺少离场日期的旧离场状态")
        XCTAssertEqual(result.intervalPoints.last?.count, 1)
        XCTAssertEqual(result.intervalPoints.last?.average, Double(FarmAnalyticsDate.days(from: firstLambing, to: secondLambing)))
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

    func testWeightGainPeriodAnalysisAveragesPerSheepInsteadOfPerInterval() throws {
        let farmID = UUID()
        let firstSheepID = UUID()
        let secondSheepID = UUID()
        let dayOne = makeDate(year: 2026, month: 6, day: 1)
        let dayTwo = makeDate(year: 2026, month: 6, day: 2)
        let dayThree = makeDate(year: 2026, month: 6, day: 3)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: firstSheepID, earTag: "G-001", breed: "湖羊", purpose: "育肥羊", sex: .ram, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: dayOne, removedAt: nil),
                .init(id: secondSheepID, earTag: "G-002", breed: "湖羊", purpose: "育肥羊", sex: .ram, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: dayOne, removedAt: nil)
            ],
            pens: [],
            weights: [
                .init(id: UUID(), sheepID: firstSheepID, kilograms: 10, occurredAt: dayOne),
                .init(id: UUID(), sheepID: firstSheepID, kilograms: 16, occurredAt: dayTwo),
                .init(id: UUID(), sheepID: firstSheepID, kilograms: 22, occurredAt: dayThree),
                .init(id: UUID(), sheepID: secondSheepID, kilograms: 10, occurredAt: dayOne),
                .init(id: UUID(), sheepID: secondSheepID, kilograms: 12, occurredAt: dayThree)
            ],
            weanings: [], lambings: [], removals: [], transfers: [], batchMemberships: [], feeds: []
        )

        let result = WeightGainAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(startDate: dayOne, endDate: dayThree)
        )

        XCTAssertEqual(result.objectCount, 2)
        XCTAssertEqual(result.weighedCount, 2)
        XCTAssertEqual(result.calculableCount, 2)
        XCTAssertEqual(result.intervalCount, 3)
        XCTAssertEqual(try XCTUnwrap(result.averageDailyGainGrams), 3_500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.rows.first(where: { $0.sheepID == firstSheepID })?.gramsPerDay), 6_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.rows.first(where: { $0.sheepID == secondSheepID })?.gramsPerDay), 1_000, accuracy: 0.001)
    }

    func testWeightGainPairedAnalysisRequiresTheSameSheepAtBothDates() throws {
        let farmID = UUID()
        let pairedID = UUID()
        let missingEndID = UUID()
        let start = makeDate(year: 2026, month: 7, day: 1)
        let end = makeDate(year: 2026, month: 7, day: 4)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: pairedID, earTag: "P-001", breed: "湖羊", purpose: "育肥羊", sex: .ram, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: start, removedAt: nil),
                .init(id: missingEndID, earTag: "P-002", breed: "湖羊", purpose: "育肥羊", sex: .ram, status: .active, initialPenID: nil, currentPenID: nil, birthAt: nil, enteredAt: start, removedAt: nil)
            ],
            pens: [],
            weights: [
                .init(id: UUID(), sheepID: pairedID, kilograms: 30, occurredAt: start),
                .init(id: UUID(), sheepID: pairedID, kilograms: 36, occurredAt: end),
                .init(id: UUID(), sheepID: missingEndID, kilograms: 30, occurredAt: start)
            ],
            weanings: [], lambings: [], removals: [], transfers: [], batchMemberships: [], feeds: []
        )

        let result = WeightGainAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(mode: .paired, startDate: start, endDate: end)
        )

        XCTAssertEqual(result.objectCount, 2)
        XCTAssertEqual(result.calculableCount, 1)
        XCTAssertEqual(result.pairedCount, 1)
        XCTAssertEqual(try XCTUnwrap(result.averageDailyGainGrams), 2_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.exclusions.first(where: { $0.sheepID == missingEndID }))?.reason, .missingPair)
    }

    func testWeightGainPairedAnalysisUsesTheNearestActualSamplesInsideDateWindow() throws {
        let sheep = UUID()
        let startBoundary = makeDate(year: 2026, month: 7, day: 1)
        let firstActual = startBoundary.addingTimeInterval(2 * 86400 + 9 * 3600)
        let endBoundary = makeDate(year: 2026, month: 7, day: 10)
        let lastActual = endBoundary.addingTimeInterval(-2 * 86400 + 11 * 3600)
        let snapshot = gainFixture(ids: [sheep], start: startBoundary,
            weights: [(sheep, 30, firstActual), (sheep, 34, lastActual)])

        let result = WeightGainAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(mode: .paired, startDate: startBoundary, endDate: endBoundary)
        )

        XCTAssertEqual(result.calculableCount, 1)
        XCTAssertEqual(result.intervals.first?.startDate, firstActual)
        XCTAssertEqual(result.intervals.first?.endDate, lastActual)
        XCTAssertEqual(result.actualStartDate, firstActual)
        XCTAssertEqual(result.actualEndDate, lastActual)
        XCTAssertEqual(try XCTUnwrap(result.averageDailyGainGrams), 800, accuracy: 0.001)
    }

    func testWeightGainPenAnalysisRejectsIntervalsCrossingAStableTransfer() throws {
        let farmID = UUID()
        let sheepID = UUID()
        let penA = UUID()
        let penB = UUID()
        let start = makeDate(year: 2026, month: 8, day: 1)
        let transfer = makeDate(year: 2026, month: 8, day: 2)
        let end = makeDate(year: 2026, month: 8, day: 3)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [
                .init(id: sheepID, earTag: "PEN-001", breed: "湖羊", purpose: "育肥羊", sex: .ram, status: .active, initialPenID: penA, currentPenID: penB, birthAt: nil, enteredAt: start, removedAt: nil)
            ],
            pens: [.init(id: penA, name: "一号舍"), .init(id: penB, name: "二号舍")],
            weights: [
                .init(id: UUID(), sheepID: sheepID, kilograms: 10, occurredAt: start),
                .init(id: UUID(), sheepID: sheepID, kilograms: 15, occurredAt: end)
            ],
            weanings: [], lambings: [], removals: [],
            transfers: [.init(id: UUID(), sheepID: sheepID, toPenID: penB, occurredAt: transfer, recordedAt: transfer)],
            batchMemberships: [], feeds: []
        )

        let result = WeightGainAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(scope: .pen(penA), startDate: start, endDate: end)
        )

        XCTAssertEqual(result.objectCount, 1)
        XCTAssertEqual(result.weighedCount, 1, "只有发生在所选圈舍期间的称重点属于该圈舍样本")
        XCTAssertEqual(result.calculableCount, 0)
        XCTAssertEqual(result.exclusions.first?.reason, .outOfScope)
    }

    func testWeightGainUsesActualTimeForBatchEntryAndPreservesEvidence() throws {
        let sheep = UUID(), batch = UUID()
        let start = makeDate(year: 2026, month: 8, day: 1)
        let end = makeDate(year: 2026, month: 8, day: 3)
        let first = start.addingTimeInterval(10 * 3600)
        let last = end.addingTimeInterval(11 * 3600)
        let snapshot = gainFixture(ids: [sheep], start: start,
            weights: [(sheep, 30, first), (sheep, 31, last)],
            memberships: [.init(batchID: batch, sheepID: sheep, joinedAt: start.addingTimeInterval(9 * 3600), leftAt: nil)])
        let result = WeightGainAnalyticsEngine.calculate(snapshot: snapshot,
            filter: .init(scope: .batch(batch), mode: .paired, startDate: start, endDate: end))
        XCTAssertEqual(result.calculableCount, 1)
        XCTAssertEqual(result.weighedCount, 1)
        XCTAssertEqual(result.intervals.first?.startDate, first)
        XCTAssertEqual(result.intervals.first?.endDate, last)
        XCTAssertEqual(result.intervals.first?.startSample.id, snapshot.weights.first?.id)
        XCTAssertEqual(try XCTUnwrap(result.averageDailyGainGrams), 500, accuracy: 0.001)
        let report = result.csvReport(scopeName: "批次,一")
        XCTAssertTrue(report.contains("\"批次,一\""))
        XCTAssertTrue(report.contains(snapshot.weights[0].id.uuidString))
        XCTAssertTrue(report.contains("\"有效区间\""))
    }

    func testWeightGainRejectsOverlappingBatchesAndRejoinedIntervals() {
        let sheep = UUID(), batch = UUID()
        let start = makeDate(year: 2026, month: 8, day: 1)
        let middle = start.addingTimeInterval(86400)
        let end = start.addingTimeInterval(3 * 86400)
        let cases: [[FarmAnalyticsSnapshot.BatchMembership]] = [
            [.init(batchID: batch, sheepID: sheep, joinedAt: start, leftAt: nil),
             .init(batchID: UUID(), sheepID: sheep, joinedAt: middle, leftAt: end)],
            [.init(batchID: batch, sheepID: sheep, joinedAt: start, leftAt: middle),
             .init(batchID: batch, sheepID: sheep, joinedAt: middle.addingTimeInterval(3600), leftAt: nil)]
        ]
        for memberships in cases {
            let snapshot = gainFixture(ids: [sheep], start: start,
                weights: [(sheep, 30, start), (sheep, 36, end)], memberships: memberships)
            let result = WeightGainAnalyticsEngine.calculate(snapshot: snapshot,
                filter: .init(scope: .batch(batch), startDate: start, endDate: end))
            XCTAssertEqual(result.calculableCount, 0)
            XCTAssertEqual(result.exclusions.first?.reason, .outOfScope)
        }
    }

    func testWeightGainSumsOnlyValidIntervalsAcrossPenAbsence() throws {
        let sheep = UUID(), pen = UUID()
        let start = makeDate(year: 2026, month: 8, day: 1)
        let days = (0...5).map { start.addingTimeInterval(Double($0) * 86400) }
        let snapshot = gainFixture(ids: [sheep], start: start, pen: pen,
            weights: [(sheep, 30, days[0]), (sheep, 31, days[1]), (sheep, 50, days[4]), (sheep, 52, days[5])],
            transfers: [
                .init(id: UUID(), sheepID: sheep, toPenID: nil, occurredAt: days[2], recordedAt: days[2]),
                .init(id: UUID(), sheepID: sheep, toPenID: pen, occurredAt: days[3], recordedAt: days[3])
            ])
        let result = WeightGainAnalyticsEngine.calculate(snapshot: snapshot,
            filter: .init(scope: .pen(pen), startDate: start, endDate: days[5]))
        let row = try XCTUnwrap(result.rows.first)
        XCTAssertEqual(row.intervalCount, 2)
        XCTAssertEqual(row.intervalDays, 2)
        XCTAssertEqual(row.totalGainKilograms, 3, accuracy: 0.001)
        XCTAssertEqual(row.gramsPerDay, 1500, accuracy: 0.001)
        let paired = WeightGainAnalyticsEngine.calculate(snapshot: snapshot,
            filter: .init(scope: .pen(pen), mode: .paired, startDate: start, endDate: days[5]))
        XCTAssertEqual(paired.calculableCount, 0)
    }

    func testWeightGainBatchCanSpanPensAndCombinedScopeKeepsTransferBoundaries() throws {
        let batch = UUID()
        let penA = UUID()
        let penB = UUID()
        let movedSheep = UUID()
        let stableSheep = UUID()
        let start = makeDate(year: 2026, month: 8, day: 1)
        let middle = makeDate(year: 2026, month: 8, day: 5)
        let transfer = makeDate(year: 2026, month: 8, day: 6)
        let end = makeDate(year: 2026, month: 8, day: 10)
        let memberships = [movedSheep, stableSheep].map {
            FarmAnalyticsSnapshot.BatchMembership(batchID: batch, sheepID: $0, joinedAt: start, leftAt: nil)
        }
        let snapshot = FarmAnalyticsSnapshot(
            farmID: UUID(),
            sheep: [
                .init(id: movedSheep, earTag: "M-001", breed: "湖羊", purpose: "育肥羊", sex: .ram,
                    status: .active, initialPenID: penA, currentPenID: penB, birthAt: nil, enteredAt: start, removedAt: nil),
                .init(id: stableSheep, earTag: "S-001", breed: "湖羊", purpose: "育肥羊", sex: .ram,
                    status: .active, initialPenID: penB, currentPenID: penB, birthAt: nil, enteredAt: start, removedAt: nil)
            ],
            pens: [.init(id: penA, name: "一号舍"), .init(id: penB, name: "二号舍")],
            weights: [
                .init(id: UUID(), sheepID: movedSheep, kilograms: 30, occurredAt: start),
                .init(id: UUID(), sheepID: movedSheep, kilograms: 32, occurredAt: middle),
                .init(id: UUID(), sheepID: movedSheep, kilograms: 35, occurredAt: end),
                .init(id: UUID(), sheepID: stableSheep, kilograms: 40, occurredAt: start),
                .init(id: UUID(), sheepID: stableSheep, kilograms: 42, occurredAt: middle),
                .init(id: UUID(), sheepID: stableSheep, kilograms: 45, occurredAt: end)
            ],
            weanings: [], lambings: [], removals: [],
            transfers: [.init(id: UUID(), sheepID: movedSheep, toPenID: penB, occurredAt: transfer, recordedAt: transfer)],
            batchMemberships: memberships, feeds: []
        )

        let batchResult = WeightGainAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(scope: .batch(batch), startDate: start, endDate: end)
        )
        XCTAssertEqual(batchResult.objectCount, 2)
        XCTAssertEqual(batchResult.calculableCount, 2)
        XCTAssertEqual(batchResult.intervals.count, 4)

        let penAResult = WeightGainAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(scope: .batchAndPen(batchID: batch, penID: penA), startDate: start, endDate: end)
        )
        XCTAssertEqual(penAResult.objectCount, 1)
        XCTAssertEqual(penAResult.rows.first?.earTag, "M-001")
        XCTAssertEqual(penAResult.rows.first?.intervalCount, 1)
        XCTAssertEqual(try XCTUnwrap(penAResult.rows.first?.totalGainKilograms), 2, accuracy: 0.001)

        let penBResult = WeightGainAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(scope: .batchAndPen(batchID: batch, penID: penB), startDate: start, endDate: end)
        )
        XCTAssertEqual(penBResult.objectCount, 2)
        XCTAssertEqual(Set(penBResult.rows.map(\.earTag)), ["S-001"])
        XCTAssertFalse(penBResult.rows.contains { $0.earTag == "M-001" }, "调入后只有一个有效称重点时不能制造圈舍日增重")
        XCTAssertEqual(try XCTUnwrap(penBResult.rows.first(where: { $0.earTag == "S-001" })?.totalGainKilograms), 5, accuracy: 0.001)
    }

    func testFixedWeightTrendUsesIntersectionForEveryPointAndRetainsZeroAndNegative() throws {
        let first = UUID(), second = UUID(), batch = UUID()
        let start = makeDate(year: 2026, month: 8, day: 1)
        let middle = start.addingTimeInterval(86400), end = start.addingTimeInterval(2 * 86400)
        let snapshot = gainFixture(ids: [first, second], start: start,
            weights: [(first, 30, start), (first, 30, middle), (first, 28, end),
                      (second, 80, start), (second, 90, end)],
            memberships: [first, second].map { .init(batchID: batch, sheepID: $0, joinedAt: start, leftAt: nil) })
        let filter = WeightGainAnalysisFilter(scope: .batch(batch), startDate: start, endDate: end)
        let trend = WeightGainAnalyticsEngine.fixedTrend(snapshot: snapshot, filter: filter, dates: [start, middle, end])
        XCTAssertEqual(trend.sheepIDs, [first])
        XCTAssertEqual(trend.points.map(\.kilograms), [30, 30, 28])
        XCTAssertEqual(trend.excludedCount, 1)
        let result = WeightGainAnalyticsEngine.calculate(snapshot: snapshot, filter: filter)
        XCTAssertEqual(result.intervals.count, 3)
        XCTAssertEqual(result.downwardCount, 1)
        XCTAssertTrue(result.intervals.contains { $0.gramsPerDay == 0 })
        let farmTrend = WeightGainAnalyticsEngine.fixedTrend(snapshot: snapshot,
            filter: .init(startDate: start, endDate: end), dates: [start, end])
        XCTAssertTrue(farmTrend.points.isEmpty)
    }

    func testWeightGainKeepsEndDayEntrantsAndDoesNotBridgeOutsidePeriod() {
        let sheep = UUID()
        let day = makeDate(year: 2026, month: 8, day: 2)
        let entered = day.addingTimeInterval(9 * 3600)
        let snapshot = gainFixture(ids: [sheep], start: entered,
            weights: [(sheep, 30, day.addingTimeInterval(-86400)), (sheep, 32, day.addingTimeInterval(10 * 3600))])
        let result = WeightGainAnalyticsEngine.calculate(snapshot: snapshot, filter: .init(startDate: day, endDate: day))
        XCTAssertEqual(result.objectCount, 1)
        XCTAssertEqual(result.weighedCount, 1)
        XCTAssertEqual(result.calculableCount, 0)
    }

    func testWeightGainPreservesHistoricalDeparturesButExcludesOldDeparturesFromNewPeriod() {
        let sheep = UUID()
        let start = makeDate(year: 2026, month: 8, day: 1)
        let end = start.addingTimeInterval(2 * 86400)
        let snapshot = gainFixture(ids: [sheep], start: start,
            weights: [(sheep, 30, start), (sheep, 28, end)], removedAt: end.addingTimeInterval(3600), status: .removed)
        let historical = WeightGainAnalyticsEngine.calculate(snapshot: snapshot, filter: .init(startDate: start, endDate: end))
        XCTAssertEqual(historical.calculableCount, 1)
        XCTAssertEqual(historical.downwardCount, 1)
        XCTAssertEqual(historical.currentDownwardCount, 0)
        let later = WeightGainAnalyticsEngine.calculate(snapshot: snapshot,
            filter: .init(startDate: end.addingTimeInterval(86400), endDate: end.addingTimeInterval(2 * 86400)))
        XCTAssertEqual(later.objectCount, 0)
        XCTAssertNil(later.averageDailyGainGrams)
    }

    func testWeightGainTrackedCohortAnchorsAtEndAndKeepsCrossPenIntervals() throws {
        let batch = UUID(), penA = UUID(), penB = UUID()
        let moved = UUID(), enteredLater = UUID()
        let start = makeDate(year: 2026, month: 9, day: 1)
        let transfer = makeDate(year: 2026, month: 9, day: 5)
        let enteredLaterAt = makeDate(year: 2026, month: 9, day: 6)
        let end = makeDate(year: 2026, month: 9, day: 10)
        let snapshot = FarmAnalyticsSnapshot(
            farmID: UUID(),
            sheep: [
                .init(id: moved, earTag: "MOVED", breed: "湖羊", purpose: "育肥羊", sex: .ram, status: .active, initialPenID: penA, currentPenID: penB, birthAt: nil, enteredAt: start, removedAt: nil),
                .init(id: enteredLater, earTag: "LATER", breed: "湖羊", purpose: "育肥羊", sex: .ram, status: .active, initialPenID: penB, currentPenID: penB, birthAt: nil, enteredAt: enteredLaterAt, removedAt: nil)
            ],
            pens: [.init(id: penA, name: "A舍"), .init(id: penB, name: "B舍")],
            weights: [
                .init(id: UUID(), sheepID: moved, kilograms: 30, occurredAt: start),
                .init(id: UUID(), sheepID: moved, kilograms: 36, occurredAt: end),
                .init(id: UUID(), sheepID: enteredLater, kilograms: 20, occurredAt: enteredLaterAt),
                .init(id: UUID(), sheepID: enteredLater, kilograms: 24, occurredAt: end)
            ],
            weanings: [], lambings: [], removals: [],
            transfers: [.init(id: UUID(), sheepID: moved, fromPenID: penA, toPenID: penB, occurredAt: transfer, recordedAt: transfer)],
            batchMemberships: [
                .init(batchID: batch, sheepID: moved, joinedAt: start, leftAt: nil),
                .init(batchID: batch, sheepID: enteredLater, joinedAt: enteredLaterAt, leftAt: nil)
            ],
            feeds: []
        )
        let result = WeightGainAnalyticsEngine.calculate(
            snapshot: snapshot,
            filter: .init(
                scope: .batchAndPen(batchID: batch, penID: penB),
                startDate: start,
                endDate: end,
                population: .trackedCohort,
                cohortAnchor: .analysisEnd
            )
        )
        XCTAssertEqual(result.objectCount, 2)
        XCTAssertEqual(Set(result.cohortMembers.map { $0.earTag }), Set(["MOVED", "LATER"]))
        XCTAssertEqual(result.calculableCount, 2)
        XCTAssertEqual(result.crossPenIntervalCount, 1)
        XCTAssertEqual(result.intervals.first(where: { $0.sheepID == moved })?.crossedTransfers.count, 1)
        XCTAssertEqual(result.transferEvents.count, 1)
        let report = result.csvReport(scopeName: "第八批 · B舍")
        XCTAssertTrue(report.contains("固定名单"))
        XCTAssertTrue(report.contains("调群事件"))
        XCTAssertTrue(report.contains("Asia/Shanghai"))
    }

    func testWeightGainMultiplePensUnionDeduplicatesAndIntersectsBatch() {
        let batch = UUID(), penA = UUID(), penB = UUID(), outsideBatch = UUID()
        let first = UUID(), second = UUID(), third = UUID()
        let start = makeDate(year: 2026, month: 9, day: 1)
        let end = makeDate(year: 2026, month: 9, day: 3)
        let snapshot = gainFixture(ids: [first, second, third], start: start,
            pen: penA,
            weights: [
                (first, 20, start), (first, 22, end),
                (second, 20, start), (second, 22, end),
                (third, 20, start), (third, 22, end)
            ],
            memberships: [
                .init(batchID: batch, sheepID: first, joinedAt: start, leftAt: nil),
                .init(batchID: batch, sheepID: second, joinedAt: start, leftAt: nil),
                .init(batchID: outsideBatch, sheepID: third, joinedAt: start, leftAt: nil)
            ])
        var adjusted = snapshot
        adjusted = FarmAnalyticsSnapshot(
            farmID: snapshot.farmID,
            sheep: snapshot.sheep.map { sheep in
                if sheep.id == second {
                    return .init(id: sheep.id, earTag: sheep.earTag, breed: sheep.breed, purpose: sheep.purpose, sex: sheep.sex, status: sheep.status, initialPenID: penB, currentPenID: penB, birthAt: sheep.birthAt, enteredAt: sheep.enteredAt, removedAt: sheep.removedAt)
                }
                return sheep
            },
            pens: [.init(id: penA, name: "A舍"), .init(id: penB, name: "B舍")],
            weights: snapshot.weights,
            weanings: snapshot.weanings,
            lambings: snapshot.lambings,
            removals: snapshot.removals,
            transfers: [.init(id: UUID(), sheepID: second, fromPenID: penA, toPenID: penB, occurredAt: start.addingTimeInterval(3600), recordedAt: start.addingTimeInterval(3600))],
            batchMemberships: snapshot.batchMemberships,
            feeds: snapshot.feeds
        )
        let result = WeightGainAnalyticsEngine.calculate(
            snapshot: adjusted,
            filter: .init(scope: .batchAndPens(batchID: batch, penIDs: [penA, penB]), startDate: start, endDate: end, population: .trackedCohort)
        )
        XCTAssertEqual(result.objectCount, 2)
        XCTAssertEqual(Set(result.cohortMembers.map { $0.sheepID }), Set([first, second]))
    }

    func testWeightGainTrackedAndInPenUseDifferentCrossPenSemantics() {
        let batch = UUID(), penA = UUID(), penB = UUID(), sheep = UUID()
        let start = makeDate(year: 2026, month: 9, day: 1)
        let transfer = makeDate(year: 2026, month: 9, day: 2)
        let end = makeDate(year: 2026, month: 9, day: 4)
        let snapshot = gainFixture(ids: [sheep], start: start, pen: penA,
            weights: [(sheep, 20, start), (sheep, 24, end)],
            transfers: [.init(id: UUID(), sheepID: sheep, fromPenID: penA, toPenID: penB, occurredAt: transfer, recordedAt: transfer)],
            memberships: [.init(batchID: batch, sheepID: sheep, joinedAt: start, leftAt: nil)])
        let tracked = WeightGainAnalyticsEngine.calculate(snapshot: snapshot,
            filter: .init(scope: .batchAndPen(batchID: batch, penID: penB), startDate: start, endDate: end, population: .trackedCohort))
        let inPen = WeightGainAnalyticsEngine.calculate(snapshot: snapshot,
            filter: .init(scope: .batchAndPen(batchID: batch, penID: penB), startDate: start, endDate: end, population: .inPen))
        XCTAssertEqual(tracked.calculableCount, 1)
        XCTAssertEqual(tracked.crossPenIntervalCount, 1)
        XCTAssertEqual(inPen.calculableCount, 0)
        XCTAssertEqual(try? XCTUnwrap(inPen.exclusions.first?.reason), .outOfScope)
    }

    func testWeightGainEndAnchoredTrackingExcludesHistoricalBatchDeparture() {
        let batch = UUID(), first = UUID(), second = UUID()
        let start = makeDate(year: 2026, month: 9, day: 1)
        let end = makeDate(year: 2026, month: 9, day: 10)
        let left = makeDate(year: 2026, month: 9, day: 6)
        let snapshot = gainFixture(ids: [first, second], start: start,
            weights: [(first, 20, start), (first, 24, left), (second, 20, start), (second, 24, end)],
            memberships: [
                .init(batchID: batch, sheepID: first, joinedAt: start, leftAt: left),
                .init(batchID: batch, sheepID: second, joinedAt: start, leftAt: nil)
            ])
        let whole = WeightGainAnalyticsEngine.calculate(snapshot: snapshot, filter: .init(scope: .batch(batch), startDate: start, endDate: end))
        let tracked = WeightGainAnalyticsEngine.calculate(snapshot: snapshot, filter: .init(scope: .batch(batch), startDate: start, endDate: end, population: .trackedCohort))
        XCTAssertEqual(whole.objectCount, 2)
        XCTAssertEqual(tracked.objectCount, 1)
        XCTAssertEqual(tracked.rows.first?.sheepID, second)
    }

    func testWeightGainInPenReportsSameTimeTransferConflict() {
        let penA = UUID(), penB = UUID(), sheep = UUID()
        let start = makeDate(year: 2026, month: 9, day: 1)
        let end = makeDate(year: 2026, month: 9, day: 2)
        let snapshot = gainFixture(ids: [sheep], start: start, pen: penA,
            weights: [(sheep, 20, start), (sheep, 24, end)],
            transfers: [.init(id: UUID(), sheepID: sheep, fromPenID: penA, toPenID: penB, occurredAt: end, recordedAt: end)])
        let result = WeightGainAnalyticsEngine.calculate(snapshot: snapshot,
            filter: .init(scope: .pen(penA), startDate: start, endDate: end, population: .inPen))
        XCTAssertEqual(result.calculableCount, 0)
        XCTAssertEqual(try? XCTUnwrap(result.exclusions.first?.reason), .conflictingEventTime)
    }

    private func gainFixture(
        ids: [UUID], start: Date, pen: UUID? = nil,
        weights: [(UUID, Double, Date)],
        transfers: [FarmAnalyticsSnapshot.Transfer] = [],
        memberships: [FarmAnalyticsSnapshot.BatchMembership] = [],
        removedAt: Date? = nil, status: SheepStatus = .active
    ) -> FarmAnalyticsSnapshot {
        // These fixtures use local calendar dates; keep the farm in the same zone.
        FarmAnalyticsSnapshot(farmID: UUID(), sheep: ids.enumerated().map { index, id in
            .init(id: id, earTag: "T-\(index)", breed: "湖羊", purpose: "育肥羊", sex: .ram,
                status: status, initialPenID: pen, currentPenID: pen, birthAt: nil, enteredAt: start, removedAt: removedAt)
        }, pens: [], weights: weights.map { .init(id: UUID(), sheepID: $0.0, kilograms: $0.1, occurredAt: $0.2) },
        weanings: [], lambings: [], removals: [], transfers: transfers, batchMemberships: memberships, feeds: [],
        timeZoneIdentifier: TimeZone.current.identifier)
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }
}
