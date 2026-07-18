import XCTest
@testable import eSheepNext

@MainActor
final class InHerdSheepExportTests: XCTestCase {
    func testExportIncludesOnlyCurrentlyPresentSheepAndEscapesExcelFields() throws {
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "繁殖,一舍")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let birthAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 3)))
        let enteredAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 31)))
        let present = SheepRecord(
            farmID: farmID,
            earTag: "A\"001",
            breed: "湖,羊",
            purpose: "繁殖",
            sex: .ewe,
            penID: pen.id,
            enteredAt: enteredAt,
            birthAt: birthAt,
            note: "重点\"留种"
        )
        let unassignedPresent = SheepRecord(
            farmID: farmID,
            earTag: "B001",
            breed: "杜泊",
            sex: .ram,
            penID: nil,
            enteredAt: enteredAt
        )
        let removed = SheepRecord(farmID: farmID, earTag: "R001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now)
        removed.statusRawValue = SheepStatus.removed.rawValue
        removed.currentPenID = pen.id // 即使旧数据留下圈舍，也不能作为在群羊导出。
        let archived = SheepRecord(farmID: farmID, earTag: "H001", isHistoricalArchive: true, breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)

        let data = InHerdSheepExport.csvData(farmID: farmID, sheep: [removed, archived, unassignedPresent, present], pens: [pen])
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let csv = try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8))

        XCTAssertTrue(csv.contains("\"耳号\",\"圈舍\",\"出生日期\",\"入场日期\",\"品种\",\"性别\",\"用途\",\"状态\",\"备注\""))
        XCTAssertTrue(csv.contains("\"A\"\"001\",\"繁殖,一舍\",\"2025-01-03\",\"2025-01-31\",\"湖,羊\",\"母羊\",\"繁殖\",\"在场\",\"重点\"\"留种\""))
        XCTAssertTrue(csv.contains("\"B001\",\"未分圈\""))
        XCTAssertFalse(csv.contains("R001"))
        XCTAssertFalse(csv.contains("H001"))
    }

    func testFileNameRemovesCharactersNotAcceptedByFilesApp() {
        XCTAssertEqual(
            InHerdSheepExport.fileName(farmName: "北/场:一", date: Date(timeIntervalSince1970: 1_735_689_600)),
            "在群羊只_北-场-一_20250101.csv"
        )
    }
}
