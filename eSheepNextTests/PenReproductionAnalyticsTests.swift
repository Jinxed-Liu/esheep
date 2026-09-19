import XCTest
@testable import eSheepNext

final class PenReproductionAnalyticsTests: XCTestCase {
    private let farmID = UUID()
    private let penID = UUID()
    private let otherPen = UUID()
    private func day(_ offset: Int) -> Date {
        let start = FarmAnalyticsDate.calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        return FarmAnalyticsDate.calendar.date(byAdding: .day, value: offset, to: start)!
    }
    private func ewe(_ tag: String = "E1", entered: Int = 0, purpose: String = "繁殖母羊", removed: Int? = nil) -> FarmAnalyticsSnapshot.Sheep {
        .init(id: UUID(), earTag: tag, breed: "湖羊", purpose: purpose, sex: .ewe,
              status: removed == nil ? .active : .removed, initialPenID: penID, currentPenID: penID,
              birthAt: nil, enteredAt: day(entered), removedAt: removed.map(day))
    }
    private func birth(_ ewe: FarmAnalyticsSnapshot.Sheep, _ at: Int, _ parity: Int?, _ total: Int) -> FarmAnalyticsSnapshot.Lambing {
        .init(id: UUID(), eweID: ewe.id, occurredAt: day(at), total: total, parity: parity, birthDeadCount: nil, offspring: [])
    }
    private func baseline(_ ewe: FarmAnalyticsSnapshot.Sheep, _ value: Int, _ at: Int = 0) -> FarmAnalyticsSnapshot.ParityEvidence {
        .init(id: UUID(), eweID: ewe.id, occurredAt: day(at), parity: value, updatedAt: day(at), createdAt: day(at))
    }
    private func transfer(_ ewe: FarmAnalyticsSnapshot.Sheep, _ at: Int, _ to: UUID?) -> FarmAnalyticsSnapshot.Transfer {
        .init(id: UUID(), sheepID: ewe.id, toPenID: to, occurredAt: day(at), recordedAt: day(at + 1))
    }
    private func snapshot(_ sheep: [FarmAnalyticsSnapshot.Sheep], births: [FarmAnalyticsSnapshot.Lambing] = [],
                          baselines: [FarmAnalyticsSnapshot.ParityEvidence] = [], transfers: [FarmAnalyticsSnapshot.Transfer] = [], recordedEntry: Bool = true) -> FarmAnalyticsSnapshot {
        .init(farmID: farmID, sheep: sheep, pens: [.init(id: penID, name: "一舍"), .init(id: otherPen, name: "二舍")],
              weights: [], weanings: [], lambings: births, removals: [], transfers: (recordedEntry ? sheep.compactMap { ewe in
                  ewe.initialPenID.map { pen in FarmAnalyticsSnapshot.Transfer(id: UUID(), sheepID: ewe.id, toPenID: pen, occurredAt: ewe.enteredAt, recordedAt: ewe.enteredAt, note: "购买入场") }
              } : []) + transfers,
              batchMemberships: [], feeds: [], parityEvidence: baselines)
    }
    private func result(_ snapshot: FarmAnalyticsSnapshot, at: Int = 600, pen: UUID? = nil) throws -> PenReproductionSummary {
        try XCTUnwrap(PenReproductionAnalyticsEngine.calculate(snapshot: snapshot, asOf: day(at))
            .first { $0.penID == (pen ?? penID) })
    }

    func testPostpartumBoundaryUsesLatestBirthAndIgnoresFuture() throws {
        let a = ewe("250"), b = ewe("251")
        let s = snapshot([a, b], births: [birth(a, 350, 2, 2), birth(b, 349, 2, 2), birth(b, 601, 3, 2)])
        let r = try result(s)
        XCTAssertEqual(r.rows[.postpartum]?.map(\.earTag), ["251"])
        XCTAssertEqual(r.ewes.first { $0.id == b.id }?.postpartumDays, 251)
    }

    func testZeroParityStrictBoundaryAndMissingBothDefaultsToZero() throws {
        let a = ewe("200", entered: 400), b = ewe("201", entered: 399), c = ewe("unknown"), d = ewe("imported")
        let r = try result(snapshot([a, b, c, d], baselines: [baseline(a, 0, 400), baseline(b, 0, 399), baseline(d, 4)]))
        XCTAssertEqual(Set(r.rows[.zeroParity]?.map(\.earTag) ?? []), ["201", "unknown"])
        XCTAssertTrue(r.pending.isEmpty)
        XCTAssertEqual(r.ewes.first { $0.id == d.id }?.parity, 4)
        XCTAssertEqual(r.rating, "差")
    }

    func testConfirmedFirstParityUsesLegacyZeroParityBirthWithoutRewritingIt() throws {
        let a = ewe("single"), b = ewe("multiple")
        let r = try result(snapshot([a, b], births: [birth(a, 550, 0, 1), birth(b, 550, 0, 2)],
                                    baselines: [baseline(a, 1, 590), baseline(b, 1, 590)]))
        XCTAssertEqual(r.rows[.firstSingle]?.map(\.earTag), ["single"])
        XCTAssertTrue(r.pending.isEmpty)
        XCTAssertEqual(r.ewes.first?.lambings.first?.parity, 0)
    }

    func testResidenceExcludesLambTransfersAndStartsAtLaterMove() throws {
        let a = ewe()
        var newborn = transfer(a, 0, penID); newborn.note = "新生羔羊"
        var weaned = transfer(a, 100, otherPen); weaned.note = "断奶羔羊转群"
        let grown = transfer(a, 350, penID)
        let r = try result(snapshot([a], transfers: [newborn, weaned, grown], recordedEntry: false))
        XCTAssertEqual(r.ewes.first?.residenceDays, 250)
        XCTAssertEqual(r.ewes.first?.residence.first?.start, day(350))
        let absent = try result(snapshot([a], recordedEntry: false))
        XCTAssertEqual(absent.ewes.first?.residenceDays, 0)
        XCTAssertTrue(absent.rows[.zeroParity]?.isEmpty == true)
        XCTAssertTrue(absent.pending.isEmpty)
    }

    func testBirthAndWeaningFactsExcludeUnlabelledEarlyTransfers() {
        let a = ewe()
        let history = [transfer(a, 0, penID), transfer(a, 100, otherPen), transfer(a, 350, penID)]
        let weaning = FarmAnalyticsSnapshot.Weaning(id: UUID(), sheepID: a.id, occurredAt: day(100),
            weanWeight: 20, birthAt: day(0), birthWeight: nil, damID: nil, litterSize: nil)
        let periods = PenReproductionAnalyticsEngine.residencePeriods(history: history, penID: penID,
            until: day(600), purposeFacts: [], weanings: [weaning], birthAt: day(0))
        XCTAssertEqual(periods.map(\.start), [day(350)])
        XCTAssertEqual(periods.map(\.days), [250])
        XCTAssertTrue(PenReproductionAnalyticsEngine.residencePeriods(history: [history[0]], penID: penID,
            until: day(600), purposeFacts: [], weanings: [], birthAt: day(0)).isEmpty)
    }

    func testPurposeHistoryExcludesWeanedStageUntilSubsequentTransfer() throws {
        let a = ewe()
        var s = snapshot([a], transfers: [transfer(a, 0, penID), transfer(a, 150, otherPen),
                                         transfer(a, 300, penID), transfer(a, 450, otherPen), transfer(a, 500, penID)], recordedEntry: false)
        s.purposeFacts = [
            .init(id: UUID(), sheepID: a.id, previousPurpose: "哺乳羔羊", purpose: .weanedLamb,
                  reason: "", occurredAt: day(100), recordedAt: day(100), changedByAccountID: UUID(), resultingRevision: 2),
            .init(id: UUID(), sheepID: a.id, previousPurpose: "断奶羔羊", purpose: .breedingEwe,
                  reason: "", occurredAt: day(200), recordedAt: day(200), changedByAccountID: UUID(), resultingRevision: 3)
        ]
        let r = try result(s)
        XCTAssertEqual(r.ewes.first?.residence.map(\.days), [150, 100])
        XCTAssertEqual(r.ewes.first?.residenceDays, 250)
    }

    func testResidenceSumsSeparateStaysAndIgnoresSamePenDuplicates() throws {
        let a = ewe()
        let s = snapshot([a], baselines: [baseline(a, 0)], transfers: [
            transfer(a, 50, penID), transfer(a, 120, otherPen), transfer(a, 519, penID), transfer(a, 560, penID)
        ])
        let r = try result(s)
        XCTAssertEqual(r.rows[.zeroParity]?.first?.residenceDays, 201)
        XCTAssertEqual(r.ewes.first?.residence.map(\.days), [120, 81])
        XCTAssertEqual(try result(s, at: 599).rows[.zeroParity]?.count, 0)
        XCTAssertEqual(try result(s, at: 200, pen: otherPen).ewes.count, 1)
    }

    func testOnlyCurrentFirstParityAndBirthTotalNotSurvivors() throws {
        let a = ewe("first"), b = ewe("second"), c = ewe("twin")
        let r = try result(snapshot([a, b, c], births: [birth(a, 550, 1, 1), birth(b, 200, 1, 1), birth(b, 550, 2, 1), birth(c, 550, 1, 2)]))
        XCTAssertEqual(r.rows[.firstSingle]?.map(\.earTag), ["first"])
        XCTAssertTrue(r.pending.isEmpty, "Offspring detail, sex and weights are unnecessary for these rules")
    }

    func testLatestThreeRequireConsecutiveParityAndMostRecentSingle() throws {
        let a = ewe("yes"), b = ewe("improved"), c = ewe("gap")
        let r = try result(snapshot([a, b, c], births: [
            birth(a, 100, 1, 2), birth(a, 250, 2, 1), birth(a, 400, 3, 1), birth(a, 550, 4, 1),
            birth(b, 100, 1, 1), birth(b, 250, 2, 1), birth(b, 400, 3, 1), birth(b, 550, 4, 2),
            birth(c, 100, 1, 1), birth(c, 400, 3, 1), birth(c, 550, 4, 1)
        ]))
        XCTAssertEqual(r.rows[.threeSingles]?.map(\.earTag), ["yes"])
        XCTAssertEqual(r.pending.map(\.earTag), ["gap"])
        XCTAssertEqual(r.rating, "数据不足，暂不评级")
    }

    func testOverlappingListsCountSheepOnceAndKnownHitDoesNotBlockGrade() throws {
        let a = ewe()
        let r = try result(snapshot([a], births: [birth(a, 100, 1, 1)]))
        XCTAssertEqual(r.rows[.firstSingle]?.count, 1)
        XCTAssertEqual(r.rows[.postpartum]?.count, 1)
        XCTAssertEqual(r.attentionCount, 1)
        XCTAssertEqual(r.attentionRate, 1)
        XCTAssertEqual(r.rating, "差")
        let incomplete = try result(snapshot([a], births: [birth(a, 100, nil, 1)]))
        XCTAssertEqual(incomplete.pending.count, 1)
        XCTAssertEqual(incomplete.rating, "差", "Unknown extra hits cannot change an already-confirmed union member")
    }

    func testRatingBoundariesUseUnroundedRatioAndEmptyHasNoGrade() {
        for (count, grade) in [(0, "优"), (9, "优"), (10, "良"), (19, "良"), (20, "中"), (29, "中"), (30, "差"), (100, "差")] {
            XCTAssertEqual(PenReproductionSummary.grade(attention: count, total: 100), grade)
        }
        XCTAssertEqual(PenReproductionSummary.grade(attention: 1, total: 11), "优")
        XCTAssertEqual(PenReproductionSummary.grade(attention: 0, total: 0), "暂无可评价母羊")
    }

    func testHistoricalCohortRemovalPurposeBreedAndEmptyPens() throws {
        let a = ewe("removed", removed: 500), b = ewe("replacement", purpose: "后备母羊")
        let s = snapshot([a, b], baselines: [baseline(a, 0), baseline(b, 0)])
        XCTAssertEqual(try result(s, at: 499).ewes.count, 1)
        XCTAssertTrue(try PenReproductionAnalyticsEngine.calculate(snapshot: s, asOf: day(500)).isEmpty)
        XCTAssertTrue(try PenReproductionAnalyticsEngine.calculate(snapshot: s, asOf: day(600)).isEmpty)
        XCTAssertTrue(try PenReproductionAnalyticsEngine.calculate(snapshot: s, asOf: day(400), breed: "杜泊").allSatisfy { $0.ewes.isEmpty })
    }

    func testBaselineCorrectionAndHistoricalCutoff() throws {
        let a = ewe()
        let s = snapshot([a], births: [birth(a, 100, 1, 1)], baselines: [baseline(a, 0), baseline(a, 4, 500)])
        XCTAssertEqual(try result(s, at: 200).rows[.firstSingle]?.count, 1)
        XCTAssertEqual(try result(s).rows[.firstSingle]?.count, 0)
        XCTAssertEqual(try result(s).ewes.first?.parity, 4)
    }

    func testLateTransferBackfillAndBirthRevocationRecompute() throws {
        let a = ewe()
        let base = snapshot([a], births: [birth(a, 550, 1, 1)], baselines: [baseline(a, 0)])
        XCTAssertEqual(try result(base).rows[.firstSingle]?.count, 1)
        let changed = snapshot([a], baselines: [baseline(a, 0)], transfers: [transfer(a, 300, otherPen)])
        XCTAssertFalse(try PenReproductionAnalyticsEngine.calculate(snapshot: changed, asOf: day(600)).contains { $0.penID == penID })
        XCTAssertEqual(try result(changed, pen: otherPen).rows[.zeroParity]?.count, 1)
    }

    func testSameDayTransferDoesNotDoubleCount() throws {
        let a = ewe()
        let morning = transfer(a, 120, otherPen)
        let afternoon = FarmAnalyticsSnapshot.Transfer(id: UUID(), sheepID: a.id, toPenID: penID,
            occurredAt: day(120).addingTimeInterval(3600), recordedAt: day(121))
        let r = try result(snapshot([a], baselines: [baseline(a, 0)], transfers: [morning, afternoon]))
        XCTAssertEqual(r.ewes.first?.residenceDays, 600)
    }

    func testTenThousandEwesKeepDeterministicCounts() throws {
        let flock = (0..<10_000).map { ewe("E\($0)") }
        let s = snapshot(flock, baselines: flock.map { baseline($0, 0) })
        let start = Date()
        let r = try result(s)
        XCTAssertEqual(r.attentionCount, 10_000)
        XCTAssertEqual(r.rows[.zeroParity]?.count, 10_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "Indexed calculation should not repeatedly scan the full flock")
    }

    func testMissingLatestBirthDoesNotTreatOlderBirthAsCurrentPostpartum() throws {
        let a = ewe()
        let r = try result(snapshot([a], births: [birth(a, 100, 1, 1)], baselines: [baseline(a, 2, 500)]))
        XCTAssertEqual(r.rows[.postpartum]?.count, 0)
        XCTAssertEqual(r.rating, "数据不足，暂不评级")
    }

    func testKnownMultipleInRecentParitiesDisprovesStreakDespiteGap() throws {
        let a = ewe()
        let r = try result(snapshot([a], births: [birth(a, 100, 1, 1), birth(a, 550, 3, 2)]))
        XCTAssertEqual(r.pending.count, 1)
        XCTAssertEqual(r.rows[.threeSingles]?.count, 0)
        XCTAssertEqual(r.rating, "优")
    }

    func testKnownResidenceIsEnoughEvenWhenInitialPenIsUnknown() throws {
        let a = FarmAnalyticsSnapshot.Sheep(id: UUID(), earTag: "late-entry", breed: "湖羊", purpose: "繁殖母羊",
            sex: .ewe, status: .active, initialPenID: nil, currentPenID: penID, birthAt: nil, enteredAt: day(0), removedAt: nil)
        let r = try result(snapshot([a], baselines: [baseline(a, 0)], transfers: [transfer(a, 399, penID)]))
        XCTAssertEqual(r.rows[.zeroParity]?.first?.residenceDays, 201)
        XCTAssertEqual(r.rating, "差")
    }

    func testSameDayDuplicateLambingsCannotProveThreeConsecutiveBirths() throws {
        let a = ewe()
        let second = FarmAnalyticsSnapshot.Lambing(id: UUID(), eweID: a.id, occurredAt: day(550).addingTimeInterval(3600),
            total: 1, parity: 3, birthDeadCount: 0, offspring: [])
        let r = try result(snapshot([a], births: [birth(a, 100, 1, 1), birth(a, 550, 2, 1), second]))
        XCTAssertEqual(r.rows[.threeSingles]?.count, 0)
        XCTAssertEqual(r.rating, "数据不足，暂不评级")
    }

    func testActiveHistoricalArchiveWithoutPresenceEvidenceIsExcluded() throws {
        let present = ewe("present")
        var archived = ewe("archive-active")
        archived.isHistoricalArchive = true
        let removed = FarmAnalyticsSnapshot.Sheep(id: UUID(), earTag: "removed-undated", breed: "湖羊", purpose: "繁殖母羊",
            sex: .ewe, status: .removed, initialPenID: penID, currentPenID: penID, birthAt: nil, enteredAt: day(0), removedAt: nil)
        let dead = FarmAnalyticsSnapshot.Sheep(id: UUID(), earTag: "dead-undated", breed: "湖羊", purpose: "繁殖母羊",
            sex: .ewe, status: .deceased, initialPenID: penID, currentPenID: penID, birthAt: nil, enteredAt: day(0), removedAt: nil)
        let all = [present, archived, removed, dead]
        let r = try result(snapshot(all, baselines: all.map { baseline($0, 0) }))
        XCTAssertEqual(r.ewes.map(\.earTag), ["present"])
        XCTAssertEqual(r.rows[.zeroParity]?.map(\.earTag), ["present"])
        XCTAssertEqual(r.attentionCount, 1)
        XCTAssertTrue(r.pending.isEmpty)
    }

    func testArchivedLaterStillBelongsToProvenHistoricalCutoffCohort() throws {
        var archivedLater = ewe("left-later", removed: 601)
        archivedLater.isHistoricalArchive = true
        let leftOnCutoff = ewe("left-on-cutoff", removed: 600)
        let enteredTomorrow = ewe("arrives-tomorrow", entered: 601)
        let all = [archivedLater, leftOnCutoff, enteredTomorrow]
        let s = snapshot(all, baselines: all.map { baseline($0, 0) }, transfers: [transfer(archivedLater, 600, otherPen)])
        XCTAssertFalse(try PenReproductionAnalyticsEngine.calculate(snapshot: s, asOf: day(600)).contains { $0.penID == penID })
        XCTAssertEqual(try result(s, at: 600, pen: otherPen).ewes.map(\.earTag), ["left-later"])
        XCTAssertFalse(try PenReproductionAnalyticsEngine.calculate(snapshot: s, asOf: day(601)).contains { $0.penID == otherPen })
        XCTAssertEqual(try result(s, at: 599).ewes.count, 2)
    }

    @MainActor
    func testSnapshotPreservesArchiveFlagFromRealModel() throws {
        let record = SheepRecord(farmID: farmID, earTag: "archived", isHistoricalArchive: true,
            breed: "湖羊", purpose: "繁殖母羊", sex: .ewe, penID: penID, enteredAt: day(0))
        let s = FarmAnalyticsSnapshot.make(farmID: farmID, sheep: [record], pens: [], weights: [], weanings: [],
            reproduction: [], offspring: [], removals: [], transfers: [], memberships: [], feeds: [], feedLines: [])
        XCTAssertTrue(try XCTUnwrap(s.sheep.first).isHistoricalArchive)
        XCTAssertFalse(try XCTUnwrap(s.sheep.first).isCurrentlyPresent)
        XCTAssertTrue(try PenReproductionAnalyticsEngine.calculate(snapshot: s, asOf: day(600)).isEmpty)
    }

    func testOnlyEnabledOccupiedPensAppear() throws {
        let a = ewe()
        let base = snapshot([a], baselines: [baseline(a, 0)])
        XCTAssertEqual(try PenReproductionAnalyticsEngine.calculate(snapshot: base, asOf: day(600)).map(\.penID), [penID])
        let disabled = FarmAnalyticsSnapshot(farmID: farmID, sheep: [a],
            pens: [.init(id: penID, name: "停用舍", isActive: false), .init(id: otherPen, name: "启用空舍")],
            weights: [], weanings: [], lambings: [], removals: [], transfers: [], batchMemberships: [], feeds: [])
        XCTAssertTrue(try PenReproductionAnalyticsEngine.calculate(snapshot: disabled, asOf: day(600)).isEmpty)
    }

    func testPensWithoutMatchingBreedingEwesAreExcluded() throws {
        let ram = FarmAnalyticsSnapshot.Sheep(id: UUID(), earTag: "ram", breed: "湖羊", purpose: "种公羊",
            sex: .ram, status: .active, initialPenID: penID, currentPenID: penID,
            birthAt: nil, enteredAt: day(0), removedAt: nil)
        let rows = try PenReproductionAnalyticsEngine.calculate(snapshot: snapshot([ram]), asOf: day(600), breed: "杜泊")
        XCTAssertTrue(rows.isEmpty)
        let replacement = ewe("replacement", purpose: "后备母羊")
        XCTAssertTrue(try PenReproductionAnalyticsEngine.calculate(snapshot: snapshot([replacement]), asOf: day(600)).isEmpty)
        let breeding = ewe("breeding")
        XCTAssertTrue(try PenReproductionAnalyticsEngine.calculate(snapshot: snapshot([breeding]), asOf: day(600), breed: "杜泊").isEmpty)
        let matching = try PenReproductionAnalyticsEngine.calculate(snapshot: snapshot([ram, replacement, breeding]), asOf: day(600), breed: "湖羊")
        XCTAssertEqual(matching.map(\.penID), [penID])
        XCTAssertEqual(matching.first?.ewes.map(\.earTag), ["breeding"])
    }

    func testPenWithOnlyRemovedOrFutureSheepIsEmptyAtCutoff() throws {
        let left = ewe("left", removed: 600), future = ewe("future", entered: 601)
        let s = snapshot([left, future])
        XCTAssertTrue(try PenReproductionAnalyticsEngine.calculate(snapshot: s, asOf: day(600)).isEmpty)
        XCTAssertEqual(try PenReproductionAnalyticsEngine.calculate(snapshot: s, asOf: day(599)).map(\.penID), [penID])
    }

    @MainActor
    func testSnapshotPreservesPenActivationState() throws {
        let pen = PenRecord(id: penID, farmID: farmID, name: "停用舍")
        pen.isActive = false
        let s = FarmAnalyticsSnapshot.make(farmID: farmID, sheep: [], pens: [pen], weights: [], weanings: [],
            reproduction: [], offspring: [], removals: [], transfers: [], memberships: [], feeds: [], feedLines: [])
        XCTAssertFalse(try XCTUnwrap(s.pens.first).isActive)
    }
}
