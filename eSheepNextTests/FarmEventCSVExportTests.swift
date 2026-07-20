import XCTest
@testable import eSheepNext

final class FarmEventCSVExportTests: XCTestCase {
    func testWeaningExportIncludesBothBoundaryDaysAndSortsByOccurrenceDescending() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = try date(year: 2026, month: 1, day: 1, calendar: calendar)
        let end = try date(year: 2026, month: 1, day: 31, calendar: calendar)
        let newer = event(
            id: "00000000-0000-0000-0000-000000000002",
            type: .weaning,
            occurredAt: try date(year: 2026, month: 1, day: 31, hour: 23, minute: 59, calendar: calendar),
            subject: "L-NEW",
            note: "重点\"观察,正常"
        )
        let older = event(
            id: "00000000-0000-0000-0000-000000000001",
            type: .weaning,
            occurredAt: start,
            subject: "L-OLD"
        )
        let otherType = event(
            id: "00000000-0000-0000-0000-000000000003",
            type: .weight,
            occurredAt: try date(year: 2026, month: 1, day: 20, calendar: calendar),
            subject: "WEIGHT"
        )
        let outside = event(
            id: "00000000-0000-0000-0000-000000000004",
            type: .weaning,
            occurredAt: try date(year: 2026, month: 2, day: 1, calendar: calendar),
            subject: "OUTSIDE"
        )

        let matched = FarmEventCSVExport.matchingEvents(
            [older, outside, otherType, newer],
            scope: .weaning,
            range: .days(from: start, through: end),
            calendar: calendar
        )

        XCTAssertEqual(matched.map(\.id), [newer.id, older.id])

        let data = FarmEventCSVExport.csvData(
            events: [older, outside, otherType, newer],
            scope: .weaning,
            range: .days(from: start, through: end),
            calendar: calendar
        )
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let csv = try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8))
        let newerRange = try XCTUnwrap(csv.range(of: "L-NEW"))
        let olderRange = try XCTUnwrap(csv.range(of: "L-OLD"))
        XCTAssertLessThan(newerRange.lowerBound, olderRange.lowerBound)
        XCTAssertTrue(csv.contains("\"重点\"\"观察,正常\""))
        XCTAssertTrue(csv.contains("\"断奶重kg\""))
        XCTAssertFalse(csv.contains("WEIGHT"))
        XCTAssertFalse(csv.contains("OUTSIDE"))
    }

    func testDateRangeMayBeSelectedInEitherOrderAndFileNameIsSafeCSV() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let first = try date(year: 2026, month: 3, day: 2, calendar: calendar)
        let second = try date(year: 2026, month: 2, day: 1, calendar: calendar)
        let exportedAt = try date(year: 2026, month: 7, day: 21, calendar: calendar)

        XCTAssertEqual(
            FarmEventCSVExport.fileName(
                farmName: "北/场:一",
                scope: .weaning,
                range: .days(from: first, through: second),
                exportedAt: exportedAt,
                calendar: calendar
            ),
            "断奶羔羊_北-场-一_20260201-20260302_20260721.csv"
        )
    }

    func testInventoryScopeIncludesMedicineAndSemenTransactions() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(FarmEventExportScope.inventory.includes(event(type: .inventoryTransaction, occurredAt: now)))
        XCTAssertTrue(FarmEventExportScope.inventory.includes(event(type: .semenTransaction, occurredAt: now)))
        XCTAssertFalse(FarmEventExportScope.inventory.includes(event(type: .health, occurredAt: now)))
    }

    private func event(
        id: String = UUID().uuidString,
        type: CloudEntityType,
        occurredAt: Date,
        subject: String = "对象",
        note: String = ""
    ) -> FarmEventSnapshot {
        FarmEventSnapshot(
            id: UUID(uuidString: id) ?? UUID(),
            entityType: type,
            category: type == .weight || type == .weaning ? .herd : .inventory,
            occurredAt: occurredAt,
            recordedAt: occurredAt,
            title: type == .weaning ? "断奶" : "记录",
            subject: subject,
            detail: "明细",
            note: note,
            fields: [.init(label: "断奶重kg", value: "25.5")]
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
