import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class PenManagementSnapshotActorTests: XCTestCase {
    func testListAndDetailIncludeOnlyCurrentPresentSheepForTargetFarm() async throws {
        let container = try AppSchema.makeContainer(
            name: "pen-management-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let otherFarmID = UUID()
        let penA = PenRecord(farmID: farmID, name: "A圈", note: "繁殖")
        let penB = PenRecord(farmID: farmID, name: "B圈")
        let emptyPen = PenRecord(farmID: farmID, name: "C圈")
        emptyPen.isActive = false
        let deletedPen = PenRecord(farmID: farmID, name: "已删除")
        deletedPen.deletedAt = .now
        let otherFarmPen = PenRecord(farmID: otherFarmID, name: "外场")

        let a10 = SheepRecord(
            farmID: farmID,
            earTag: "A10",
            breed: "湖羊",
            purpose: "繁殖母羊",
            sex: .ewe,
            penID: penA.id,
            enteredAt: .now
        )
        let a2 = SheepRecord(
            farmID: farmID,
            earTag: "A2",
            breed: "杜泊",
            purpose: "种公羊",
            sex: .ram,
            penID: penA.id,
            enteredAt: .now
        )
        let b1 = SheepRecord(
            farmID: farmID,
            earTag: "B1",
            breed: "湖羊",
            sex: .ewe,
            penID: penB.id,
            enteredAt: .now
        )
        let removed = SheepRecord(
            farmID: farmID,
            earTag: "REMOVED",
            breed: "湖羊",
            sex: .ewe,
            penID: penA.id,
            enteredAt: .now
        )
        removed.statusRawValue = SheepStatus.removed.rawValue
        let historical = SheepRecord(
            farmID: farmID,
            earTag: "HISTORY",
            isHistoricalArchive: true,
            breed: "湖羊",
            sex: .ewe,
            penID: penA.id,
            enteredAt: .now
        )
        let deleted = SheepRecord(
            farmID: farmID,
            earTag: "DELETED",
            breed: "湖羊",
            sex: .ewe,
            penID: penA.id,
            enteredAt: .now
        )
        deleted.deletedAt = .now
        let unassigned = SheepRecord(
            farmID: farmID,
            earTag: "UNASSIGNED",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let otherFarmSheep = SheepRecord(
            farmID: otherFarmID,
            earTag: "OTHER",
            breed: "湖羊",
            sex: .ewe,
            penID: penA.id,
            enteredAt: .now
        )

        [penA, penB, emptyPen, deletedPen, otherFarmPen].forEach(context.insert)
        [a10, a2, b1, removed, historical, deleted, unassigned, otherFarmSheep]
            .forEach(context.insert)
        try context.save()

        let reader = PenManagementSnapshotActor(container: container)
        let rows = try await reader.loadList(farmID: farmID)

        XCTAssertEqual(rows.map(\.name), ["A圈", "B圈", "C圈"])
        XCTAssertEqual(rows.map(\.currentSheepCount), [2, 1, 0])
        XCTAssertEqual(rows.map(\.isActive), [true, true, false])

        let loadedDetail = try await reader.loadDetail(farmID: farmID, penID: penA.id)
        let detail = try XCTUnwrap(loadedDetail)
        XCTAssertEqual(detail.pen.name, "A圈")
        XCTAssertEqual(detail.pen.currentSheepCount, 2)
        XCTAssertEqual(detail.sheep.map(\.earTag), ["A2", "A10"])
        XCTAssertEqual(detail.sheep.map(\.purpose), ["种公羊", "繁殖母羊"])
        XCTAssertEqual(detail.analysisMembers.map(\.id), detail.sheep.map(\.id))
    }

    func testDetailRejectsDeletedAndCrossFarmPens() async throws {
        let container = try AppSchema.makeContainer(
            name: "pen-boundary-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let otherFarmID = UUID()
        let deletedPen = PenRecord(farmID: farmID, name: "已删除")
        deletedPen.deletedAt = .now
        let otherFarmPen = PenRecord(farmID: otherFarmID, name: "外场")
        context.insert(deletedPen)
        context.insert(otherFarmPen)
        try context.save()

        let reader = PenManagementSnapshotActor(container: container)
        let deleted = try await reader.loadDetail(farmID: farmID, penID: deletedPen.id)
        let crossFarm = try await reader.loadDetail(farmID: farmID, penID: otherFarmPen.id)

        XCTAssertNil(deleted)
        XCTAssertNil(crossFarm)
    }
}
