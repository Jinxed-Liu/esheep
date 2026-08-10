import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

final class FarmPenOccupancyTests: XCTestCase {
    private let originPenID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let destinationPenID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private let sheepID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!

    func testExactTransferBoundaryUsesDestinationPen() {
        let transferAt = date(12)
        let index = makeIndex(transferAt: transferAt)

        XCTAssertEqual(index.occupiedPenIDs(at: date(11)), [originPenID])
        XCTAssertEqual(index.occupiedPenIDs(at: transferAt), [destinationPenID])
        XCTAssertEqual(index.sheepIDs(in: originPenID, at: transferAt), [])
        XCTAssertEqual(index.sheepIDs(in: destinationPenID, at: transferAt), [sheepID])
    }

    func testRangeIncludesEveryPenWithPositiveDurationOccupancy() {
        let index = makeIndex(transferAt: date(12))

        XCTAssertEqual(index.occupiedPenIDs(from: date(0), to: date(24)), [originPenID, destinationPenID])
        XCTAssertEqual(index.occupiedPenIDs(from: date(12), to: date(24)), [destinationPenID])
        XCTAssertEqual(index.occupiedPenIDs(from: date(0), to: date(12)), [originPenID])
    }

    func testRemovalAndEntryUseHalfOpenBoundaries() {
        let removalAt = date(18)
        let departing = FarmPenOccupancySheepSnapshot(
            id: sheepID,
            initialPenID: originPenID,
            enteredAt: date(0),
            removedAt: removalAt,
            isCurrentlyPresent: false
        )
        let enteringID = UUID()
        let entering = FarmPenOccupancySheepSnapshot(
            id: enteringID,
            initialPenID: destinationPenID,
            enteredAt: date(24),
            removedAt: nil,
            isCurrentlyPresent: true
        )
        let index = FarmPenOccupancyIndex(sheep: [departing, entering])

        XCTAssertEqual(index.occupiedPenIDs(at: removalAt), [])
        XCTAssertEqual(index.occupiedPenIDs(from: date(17), to: removalAt), [originPenID])
        XCTAssertEqual(index.occupiedPenIDs(from: removalAt, to: date(24)), [])
        XCTAssertEqual(index.occupiedPenIDs(from: date(0), to: date(24)), [originPenID])
        XCTAssertEqual(index.occupiedPenIDs(at: date(24)), [destinationPenID])
    }

    func testUndatedDepartedSheepDoesNotFabricateHistoricalOccupancy() {
        let unknownDeparture = FarmPenOccupancySheepSnapshot(
            id: sheepID,
            initialPenID: originPenID,
            enteredAt: date(0),
            removedAt: nil,
            isCurrentlyPresent: false
        )
        let index = FarmPenOccupancyIndex(sheep: [unknownDeparture])

        XCTAssertTrue(index.occupiedPenIDs(at: date(12)).isEmpty)
        XCTAssertTrue(index.occupiedPenIDs(from: date(0), to: date(24)).isEmpty)
    }

    func testRemovalFactClosesPresenceWhenProjectionDateIsMissing() {
        let removalAt = date(18)
        let sheep = FarmPenOccupancySheepSnapshot(
            id: sheepID,
            initialPenID: originPenID,
            enteredAt: date(0),
            removedAt: nil,
            isCurrentlyPresent: false
        )
        let removal = FarmPenOccupancyRemovalSnapshot(
            id: UUID(),
            sheepID: sheepID,
            occurredAt: removalAt,
            recordedAt: removalAt
        )
        let index = FarmPenOccupancyIndex(sheep: [sheep], removals: [removal])

        XCTAssertEqual(index.occupiedPenIDs(at: date(17)), [originPenID])
        XCTAssertTrue(index.occupiedPenIDs(at: removalAt).isEmpty)
    }

    func testWholeDayRangeCarriesForwardPositiveDailyCountAndUsesLatestRebuild() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day0 = calendar.startOfDay(for: date(0))
        let day1 = calendar.date(byAdding: .day, value: 1, to: day0)!
        let day2 = calendar.date(byAdding: .day, value: 2, to: day0)!
        let day3 = calendar.date(byAdding: .day, value: 3, to: day0)!
        let legacyPenID = UUID()
        let counts = [
            FarmPenOccupancyDailyCountSnapshot(id: UUID(), penID: legacyPenID, purpose: "育肥", date: day0, count: 4, rebuiltAt: date(1)),
            FarmPenOccupancyDailyCountSnapshot(id: UUID(), penID: legacyPenID, purpose: "育肥", date: day2, count: 3, rebuiltAt: date(2)),
            FarmPenOccupancyDailyCountSnapshot(id: UUID(), penID: legacyPenID, purpose: "育肥", date: day2, count: 0, rebuiltAt: date(3)),
        ]
        let index = FarmPenOccupancyIndex(sheep: [], dailyCounts: counts)

        XCTAssertEqual(
            index.occupiedPenIDsDuringWholeDays(from: day1, to: day2, calendar: calendar),
            [legacyPenID]
        )
        XCTAssertTrue(
            index.occupiedPenIDsDuringWholeDays(from: day2, to: day3, calendar: calendar).isEmpty
        )
    }

    private func makeIndex(transferAt: Date) -> FarmPenOccupancyIndex {
        FarmPenOccupancyIndex(
            sheep: [
                FarmPenOccupancySheepSnapshot(
                    id: sheepID,
                    initialPenID: originPenID,
                    enteredAt: date(0),
                    removedAt: nil,
                    isCurrentlyPresent: true
                )
            ],
            transfers: [
                FarmPenOccupancyTransferSnapshot(
                    id: UUID(),
                    sheepID: sheepID,
                    toPenID: destinationPenID,
                    occurredAt: transferAt,
                    recordedAt: transferAt
                )
            ]
        )
    }

    private func date(_ hour: TimeInterval) -> Date {
        Date(timeIntervalSince1970: hour * 3_600)
    }
}

@MainActor
final class FarmPenOccupancyCommandTests: XCTestCase {
    func testPenSubjectCommandsRejectEmptyPenWithoutWritingFacts() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(try fixture.service.execute(
            .recordFeedTroughObservation(FeedTroughObservationDraft(
                penID: fixture.emptyPen.id,
                feederName: "一号料槽",
                observedAt: .now,
                actualRemainingKilogramsText: "2",
                measurementMethod: .weighed
            )),
            in: fixture.farmContext,
            context: fixture.context
        )) { error in
            guard case FarmCommandError.penHasNoSheepAtTime = error else {
                return XCTFail("预期空舍时间点校验，实际错误：\(error)")
            }
        }
        XCTAssertThrowsError(try fixture.service.execute(
            .addNote(sheepID: nil, penID: fixture.emptyPen.id, text: "空舍备注", occurredAt: .now),
            in: fixture.farmContext,
            context: fixture.context
        )) { error in
            guard case FarmCommandError.penHasNoSheepAtTime = error else {
                return XCTFail("预期空舍时间点校验，实际错误：\(error)")
            }
        }
        let healthDraft = CareHealthDraft(
            id: UUID(),
            batchID: UUID(),
            subjectIDs: [],
            penID: fixture.emptyPen.id,
            catalogItemID: nil,
            kind: .treatment,
            itemName: "观察",
            occurredAt: .now,
            note: "",
            inventoryLotID: nil,
            dosePerSubjectText: nil,
            unit: "",
            route: "",
            reminderAt: nil
        )
        XCTAssertThrowsError(try fixture.service.execute(
            .care(.recordHealth(healthDraft)),
            in: fixture.farmContext,
            context: fixture.context
        )) { error in
            guard case FarmCommandError.penHasNoSheepAtTime = error else {
                return XCTFail("预期健康记录空舍时间点校验，实际错误：\(error)")
            }
        }

        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<NoteRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).isEmpty)
    }

    private struct Fixture {
        let context: ModelContext
        let farmContext: FarmContext
        let service: FarmCommandService
        let emptyPen: PenRecord
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(
            name: "pen-occupancy-command-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "pen-occupancy-\(UUID().uuidString)", displayName: "圈舍测试")
        let farm = FarmRecord(ownerAccountID: account.id, name: "圈舍测试场")
        let occupiedPen = PenRecord(farmID: farm.id, name: "有羊圈舍")
        let emptyPen = PenRecord(farmID: farm.id, name: "空圈舍")
        let sheep = SheepRecord(
            farmID: farm.id,
            earTag: "P001",
            breed: "杜泊",
            sex: .ewe,
            penID: occupiedPen.id,
            enteredAt: Date.now.addingTimeInterval(-86_400)
        )
        context.insert(account)
        context.insert(farm)
        context.insert(occupiedPen)
        context.insert(emptyPen)
        context.insert(sheep)
        try context.save()
        return Fixture(
            context: context,
            farmContext: FarmContext(accountID: account.id, farmID: farm.id, role: .owner),
            service: FarmCommandService(),
            emptyPen: emptyPen
        )
    }
}
