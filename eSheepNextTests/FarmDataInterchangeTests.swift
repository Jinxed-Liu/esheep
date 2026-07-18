import XCTest
import SwiftData
@testable import eSheepNext

@MainActor
final class FarmDataInterchangeTests: XCTestCase {
    func testXLSXIsRealOOXMLAndRoundTripsThroughPreview() throws {
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "产羔圈")
        let sheep = SheepRecord(farmID: farmID, earTag: "A-001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: date("2026-07-01"), birthAt: date("2025-12-01"), note: "健康")

        let data = try FarmDataInterchange.xlsxData(farmID: farmID, sheep: [sheep], pens: [pen])
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4b])
        XCTAssertNotNil(data.range(of: Data("[Content_Types].xml".utf8)))

        let preview = try FarmDataInterchange.preview(data: data, fileExtension: "xlsx")
        XCTAssertEqual(preview.fileKind, .xlsx)
        XCTAssertEqual(preview.acceptedRows.count, 1)
        XCTAssertEqual(preview.acceptedRows.first?.earTag, "A-001")
        XCTAssertEqual(preview.acceptedRows.first?.penName, "产羔圈")
        XCTAssertEqual(preview.errorCount, 0)
    }

    func testCSVPreviewReportsExistingAndInFileDuplicates() throws {
        let csv = """
        耳号,品种,性别,圈舍,入场日期,出生日期,备注
        A001,湖羊,母羊,一号圈,2026-01-01,2025-01-01,
        A001,湖羊,母羊,一号圈,2026-01-02,,重复
        B001,杜泊,公羊,二号圈,2026-01-03,,
        """
        let preview = try FarmDataInterchange.preview(data: Data(csv.utf8), fileExtension: "csv", existingEarTags: ["A001"])

        XCTAssertEqual(preview.rows.count, 3)
        XCTAssertEqual(preview.duplicateRowNumbers, [2, 3])
        XCTAssertEqual(preview.acceptedRows.map(\.earTag), ["B001"])
    }

    func testInvalidDateIsRejectedBeforeCommit() throws {
        let csv = "耳号,品种,性别,圈舍,入场日期,出生日期,备注\nA001,湖羊,母羊,,2026/01/01,,\n"
        let preview = try FarmDataInterchange.preview(data: Data(csv.utf8), fileExtension: "csv")
        XCTAssertEqual(preview.acceptedRows.count, 0)
        XCTAssertEqual(preview.errorCount, 1)
    }

    func testExcelSerialDatesAreAccepted() throws {
        let csv = "耳号,品种,性别,圈舍,入场日期,出生日期,备注\nA001,湖羊,母羊,,46113,45700,\n"
        let preview = try FarmDataInterchange.preview(data: Data(csv.utf8), fileExtension: "csv")
        XCTAssertEqual(preview.acceptedRows.count, 1)
        XCTAssertEqual(preview.errorCount, 0)
    }

    func testWidgetSnapshotISO8601EncodingRequiresMatchingDecoder() throws {
        let snapshot = FarmWidgetSnapshot(version: 1, generatedAt: date("2026-07-18"), selectedFarmID: nil, farms: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(FarmWidgetSnapshot.self, from: encoder.encode(snapshot)), snapshot)
    }

    func testImportCommitUsesCommandPipelineAndSecondPreviewIsIdempotent() throws {
        let container = try AppSchema.makeContainer(name: "data-import-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "import-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "测试场")
        context.insert(account); context.insert(farm); try context.save()
        let csv = "耳号,品种,性别,圈舍,入场日期,出生日期,备注\nA001,湖羊,母羊,一号圈,2026-01-01,2025-01-01,导入\n"
        let preview = try FarmDataInterchange.preview(data: Data(csv.utf8), fileExtension: "csv")

        let result = try FarmImportCommitService.commit(preview, account: account, farm: farm, context: context)

        XCTAssertEqual(result, FarmImportCommitResult(importedCount: 1, skippedCount: 0))
        XCTAssertEqual(try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farm.id }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farm.id }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farm.id }.count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == farm.id }.count, 2)

        let second = try FarmDataInterchange.preview(data: Data(csv.utf8), fileExtension: "csv", existingEarTags: ["A001"])
        XCTAssertTrue(second.acceptedRows.isEmpty)
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}
