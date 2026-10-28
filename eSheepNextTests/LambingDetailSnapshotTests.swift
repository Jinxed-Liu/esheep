import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class LambingDetailSnapshotTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try AppSchema.makeContainer(name: "lambing-detail-\(UUID())", isStoredInMemoryOnly: true)
    }

    func testExplicitLitterLinksPreserveBirthAndCurrentFactsSeparately() async throws {
        let container = try container(), context = ModelContext(container)
        let farmID = UUID(), born = Date(timeIntervalSince1970: 1_000_000)
        let pen = PenRecord(farmID: farmID, name: "当前羔羊舍")
        let damID = UUID()
        let event = ReproductionRecord(farmID: farmID, eweID: damID, kind: .lambing,
            occurredAt: born, lambCount: 5, parity: 3, birthDeadCount: 1)
        let live = SheepRecord(farmID: farmID, earTag: "NEW", breed: "湖羊", sex: .ewe,
            penID: pen.id, enteredAt: born, birthAt: born, damID: damID)
        let deceased = SheepRecord(farmID: farmID, earTag: "DEAD", breed: "湖羊", sex: .ram,
            penID: pen.id, enteredAt: born, birthAt: born, damID: damID)
        deceased.statusRawValue = SheepStatus.deceased.rawValue
        let removal = RemovalRecord(farmID: farmID, sheepID: deceased.id, kind: .deceased,
            reason: "病亡", occurredAt: born.addingTimeInterval(10 * 86_400))
        let birthWeight = WeightRecord(farmID: farmID, sheepID: live.id, kilogramsText: "3.4",
            occurredAt: born.addingTimeInterval(86_400))
        let laterWeight = WeightRecord(farmID: farmID, sheepID: deceased.id, kilogramsText: "4.1",
            occurredAt: born.addingTimeInterval(86_401))
        context.insert(pen); context.insert(event); context.insert(live); context.insert(deceased)
        context.insert(removal); context.insert(birthWeight); context.insert(laterWeight)
        for link in [
            LambingOffspringRecord(farmID: farmID, lambingRecordID: event.id, sheepID: live.id,
                legacyEarTag: "OLD", sexRawValue: LambSex.female.rawValue, birthWeightText: "3.4",
                autoBirthWeightRecordID: birthWeight.id),
            LambingOffspringRecord(farmID: farmID, lambingRecordID: event.id, sheepID: deceased.id,
                legacyEarTag: "DEAD", sexRawValue: SheepSex.ram.rawValue, birthWeightText: "4.1",
                autoBirthWeightRecordID: laterWeight.id),
            LambingOffspringRecord(farmID: farmID, lambingRecordID: event.id, sheepID: nil,
                legacyEarTag: "UNLINKED", sexRawValue: "unknown", birthWeightText: ""),
            LambingOffspringRecord(farmID: farmID, lambingRecordID: event.id, sheepID: nil,
                legacyEarTag: "", sexRawValue: "unknown", birthWeightText: "0", isStillborn: true)
        ] { context.insert(link) }
        // A same-dam, same-day profile and another event's child are not proof
        // of belonging to this litter.
        context.insert(SheepRecord(farmID: farmID, earTag: "UNRELATED", breed: "湖羊", sex: .ewe,
            penID: pen.id, enteredAt: born, birthAt: born, damID: damID))
        context.insert(LambingOffspringRecord(farmID: farmID, lambingRecordID: UUID(), sheepID: nil,
            legacyEarTag: "OTHER-LITTER", sexRawValue: "unknown", birthWeightText: ""))
        try context.save()
        let loaded = try await LambingDetailSnapshotActor(container: container).load(farmID: farmID, recordID: event.id)
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.children.count, 4)
        XCTAssertEqual(snapshot.missingCount, 1)
        XCTAssertFalse(snapshot.countMismatch)
        let current = try XCTUnwrap(snapshot.children.first { $0.earTag == "NEW" })
        XCTAssertEqual(current.recordedEarTag, "OLD")
        XCTAssertEqual(current.sheepID, live.id)
        XCTAssertEqual(current.birthWeight, "3.4")
        XCTAssertEqual(current.currentPen, pen.name)
        let dead = try XCTUnwrap(snapshot.children.first { $0.earTag == "DEAD" })
        XCTAssertFalse(dead.isStillborn)
        XCTAssertEqual(dead.sheepID, deceased.id)
        XCTAssertEqual(dead.currentState, "死亡")
        XCTAssertEqual(dead.removedAt, removal.occurredAt)
        XCTAssertNil(dead.currentPen)
        XCTAssertNil(dead.birthWeight)
        XCTAssertEqual(dead.laterWeight, "4.1")
        let unknown = try XCTUnwrap(snapshot.children.first { $0.earTag == "UNLINKED" })
        XCTAssertNil(unknown.sheepID)
        XCTAssertEqual(unknown.currentState, "未建档")
        let stillborn = try XCTUnwrap(snapshot.children.first { $0.isStillborn })
        XCTAssertEqual(stillborn.earTag, "未编号羔羊")
        XCTAssertNil(stillborn.sheepID)
        XCTAssertNil(stillborn.birthWeight)
    }

    func testMissingDeletedAndOtherFarmProfilesNeverBecomeNavigationTargets() async throws {
        let container = try container(), context = ModelContext(container)
        let farmID = UUID(), born = Date.now
        let event = ReproductionRecord(farmID: farmID, eweID: UUID(), kind: .lambing,
            occurredAt: born, lambCount: 3)
        context.insert(event)
        let foreign = SheepRecord(farmID: UUID(), earTag: "PRIVATE", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: born)
        let deleted = SheepRecord(farmID: farmID, earTag: "DELETED", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: born)
        deleted.deletedAt = born
        context.insert(foreign); context.insert(deleted)
        for (id, tag) in [(foreign.id, "FOREIGN-LINK"), (deleted.id, "DELETED"), (UUID(), "MISSING")] {
            context.insert(LambingOffspringRecord(farmID: farmID, lambingRecordID: event.id, sheepID: id,
                legacyEarTag: tag, sexRawValue: "unknown", birthWeightText: ""))
        }
        // A foreign-farm offspring record with the same event ID is also excluded.
        context.insert(LambingOffspringRecord(farmID: UUID(), lambingRecordID: event.id, sheepID: foreign.id,
            legacyEarTag: "PRIVATE", sexRawValue: "unknown", birthWeightText: ""))
        try context.save()
        let result = try await LambingDetailSnapshotActor(container: container).load(farmID: farmID, recordID: event.id)
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.children.count, 3)
        XCTAssertTrue(snapshot.children.allSatisfy { $0.sheepID == nil })
        XCTAssertFalse(snapshot.children.contains { $0.earTag == "PRIVATE" })
    }

    func testRevocationPreservesOnlyItsOwnHiddenChildrenAndDoesNotReviveRemovedWeight() async throws {
        let container = try container(), context = ModelContext(container)
        let farmID = UUID(), born = Date.now
        let event = ReproductionRecord(farmID: farmID, eweID: UUID(), kind: .lambing,
            occurredAt: born, lambCount: 1)
        event.deletedAt = born
        let child = SheepRecord(farmID: farmID, earTag: "LAMB", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: born)
        let weight = WeightRecord(farmID: farmID, sheepID: child.id, kilogramsText: "3.2", occurredAt: born)
        weight.deletedAt = born
        let revoked = LambingOffspringRecord(farmID: farmID, lambingRecordID: event.id, sheepID: child.id,
            legacyEarTag: "LAMB", sexRawValue: "unknown", birthWeightText: "3.2", autoBirthWeightRecordID: weight.id)
        revoked.deletedAt = born; revoked.deletedByLambingRevocation = true
        let corrected = LambingOffspringRecord(farmID: farmID, lambingRecordID: event.id, sheepID: nil,
            legacyEarTag: "REMOVED-BY-CORRECTION", sexRawValue: "unknown", birthWeightText: "")
        corrected.deletedAt = born
        context.insert(event); context.insert(child); context.insert(weight); context.insert(revoked); context.insert(corrected)
        try context.save()
        let result = try await LambingDetailSnapshotActor(container: container).load(farmID: farmID, recordID: event.id)
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.children.map(\.earTag), ["LAMB"])
        XCTAssertNil(snapshot.children.first?.birthWeight)
    }

    func testIncompleteOutcomeDetailsAreNotAutomaticallyCalledAConflict() async throws {
        let container = try container(), context = ModelContext(container)
        let farmID = UUID()
        let event = ReproductionRecord(farmID: farmID, eweID: UUID(), kind: .lambing,
            occurredAt: .now, lambCount: 3, birthDeadCount: 1)
        let child = LambingOffspringRecord(farmID: farmID, lambingRecordID: event.id, sheepID: nil,
            legacyEarTag: "LIVE", sexRawValue: "unknown", birthWeightText: "")
        context.insert(event); context.insert(child); try context.save()
        let reader = LambingDetailSnapshotActor(container: container)
        let incomplete = try await reader.load(farmID: farmID, recordID: event.id)
        XCTAssertEqual(incomplete?.missingCount, 2)
        XCTAssertEqual(incomplete?.countMismatch, false)
        event.birthDeadCount = 3; try context.save()
        let conflict = try await reader.load(farmID: farmID, recordID: event.id)
        XCTAssertEqual(conflict?.countMismatch, true)
    }
}
