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

    func testRemovedExportUsesLatestRemovalAndSortsByRemovalTimeDescending() throws {
        let farmID = UUID()
        let otherFarmID = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 2, day: 1)))
        let later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 3, day: 2)))

        let earlierSheep = SheepRecord(farmID: farmID, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: earlier)
        earlierSheep.statusRawValue = SheepStatus.removed.rawValue
        earlierSheep.removedAt = earlier
        let laterSheep = SheepRecord(farmID: farmID, earTag: "B001", breed: "杜泊", sex: .ram, penID: nil, enteredAt: earlier)
        laterSheep.statusRawValue = SheepStatus.deceased.rawValue
        laterSheep.removedAt = later
        let present = SheepRecord(farmID: farmID, earTag: "P001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: earlier)
        let archived = SheepRecord(farmID: farmID, earTag: "H001", isHistoricalArchive: true, breed: "未知", sex: .unknown, penID: nil, enteredAt: earlier)
        let otherFarmSheep = SheepRecord(farmID: otherFarmID, earTag: "X001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: earlier)
        otherFarmSheep.statusRawValue = SheepStatus.removed.rawValue

        let oldCorrectedRecord = RemovalRecord(farmID: farmID, sheepID: laterSheep.id, kind: .sold, reason: "旧原因", occurredAt: earlier)
        oldCorrectedRecord.deletedAt = .now
        let latestRecord = RemovalRecord(farmID: farmID, sheepID: laterSheep.id, kind: .deceased, reason: "疾病,死亡", amountText: nil, occurredAt: later, note: "重点\"记录")
        let earlierRecord = RemovalRecord(farmID: farmID, sheepID: earlierSheep.id, kind: .sold, reason: "出售", amountText: "1200", occurredAt: earlier)

        let data = RemovedSheepExport.csvData(
            farmID: farmID,
            sheep: [earlierSheep, present, archived, otherFarmSheep, laterSheep],
            removals: [earlierRecord, oldCorrectedRecord, latestRecord]
        )
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let csv = try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8))
        let laterRange = try XCTUnwrap(csv.range(of: "\"B001\",\"2025-03-02\",\"死亡\",\"疾病,死亡\""))
        let earlierRange = try XCTUnwrap(csv.range(of: "\"A001\",\"2025-02-01\",\"出售\",\"出售\",\"1200\""))

        XCTAssertLessThan(laterRange.lowerBound, earlierRange.lowerBound)
        XCTAssertTrue(csv.contains("\"重点\"\"记录\""))
        XCTAssertFalse(csv.contains("旧原因"))
        XCTAssertFalse(csv.contains("P001"))
        XCTAssertFalse(csv.contains("H001"))
        XCTAssertFalse(csv.contains("X001"))
    }

    func testRemovedFileNameIncludesCSVExtension() {
        XCTAssertEqual(
            RemovedSheepExport.fileName(farmName: "北/场:一", date: Date(timeIntervalSince1970: 1_735_689_600)),
            "离群羊只_北-场-一_20250101.csv"
        )
    }
}
