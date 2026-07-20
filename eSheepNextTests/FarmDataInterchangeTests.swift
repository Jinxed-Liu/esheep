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

    func testSingleSheepWorkbookContainsTimelineFacts() throws {
        let farmID = UUID()
        let sheep = SheepRecord(farmID: farmID, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2026-01-01"))
        let weight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "42.5", occurredAt: date("2026-07-01"), note: "月度称重")
        let health = HealthRecord(farmID: farmID, sheepID: sheep.id, penID: nil, kind: .vaccination, itemNameSnapshot: "羊三联", occurredAt: date("2026-06-01"), note: "加强针")

        let data = try FarmDataInterchange.singleSheepXLSXData(sheep: sheep, penName: nil, weights: [weight], health: [health], reproduction: [], transfers: [])

        XCTAssertNotNil(data.range(of: Data("xl/worksheets/sheet1.xml".utf8)))
        XCTAssertNotNil(data.range(of: Data("42.5".utf8)))
        XCTAssertNotNil(data.range(of: Data("羊三联".utf8)))
    }

    func testFullExcelTemplateContainsAllEntrySheetsAndRoundTrips() throws {
        let data = try FarmExcelImportService.templateData()
        let sheets = try XLSXCodec.decodeSheets(data)

        XCTAssertEqual(sheets.first?.name, "填写说明")
        XCTAssertTrue(sheets.contains { $0.name == "新建羊只" })
        XCTAssertTrue(sheets.contains { $0.name == "健康记录" })
        XCTAssertTrue(sheets.contains { $0.name == "产羔" })
        XCTAssertTrue(sheets.contains { $0.name == "投喂" })
        XCTAssertTrue(sheets.contains { $0.name == "提醒规则" })
        XCTAssertNotNil(data.range(of: Data("xl/styles.xml".utf8)))
    }

    func testPageExcelTemplateContainsOnlyInstructionsAndRequestedEntrySheet() throws {
        let data = try FarmExcelImportService.templateData(sheetNames: ["称重"])
        let sheets = try XLSXCodec.decodeSheets(data)

        XCTAssertEqual(sheets.map(\.name), ["填写说明", "称重"])
        XCTAssertFalse(sheets.contains { $0.name == "新建羊只" })
        XCTAssertFalse(sheets.contains { $0.name == "转群" })
    }

    func testPageExcelPreviewIgnoresOtherEntrySheetsAndOnlyCommitsCurrentPage() throws {
        let container = try AppSchema.makeContainer(name: "excel-page-scope-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-page-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        let sheep = SheepRecord(farmID: farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2026-01-01"))
        context.insert(owner); context.insert(farm); context.insert(sheep); try context.save()
        let workbook = try XLSXCodec.encode(sheets: [
            .init(name: "称重", rows: [
                ["导入键", "耳号", "体重kg", "发生日期", "备注"],
                ["weight-1", "A001", "36.5", "2026-07-20", "本页导入"]
            ]),
            .init(name: "备注", rows: [
                ["导入键", "耳号", "圈舍", "内容", "发生日期"],
                ["note-1", "A001", "", "不应从称重页写入", "2026-07-20"]
            ])
        ])

        let preview = try FarmExcelImportService.preview(
            data: workbook,
            farm: farm,
            context: context,
            allowedSheetNames: ["称重"]
        )

        XCTAssertTrue(preview.canCommit)
        XCTAssertEqual(preview.rows.map(\.sheet), ["称重"])
        XCTAssertTrue(preview.issues.contains { $0.sheet == "备注" && $0.severity == .warning })
        XCTAssertEqual(try FarmExcelImportService.commit(preview, account: owner, farm: farm, context: context), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farm.id }.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == farm.id }.isEmpty)
    }

    func testNewSheepOnlyRejectsEarTagsAlreadyInCurrentFarmOrSameWorkbook() throws {
        let container = try AppSchema.makeContainer(name: "excel-new-sheep-check-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "当前场")
        let otherFarm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "其他场")
        context.insert(owner); context.insert(farm); context.insert(otherFarm)
        context.insert(SheepRecord(farmID: farm.id, earTag: "CURRENT-01", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2026-01-01")))
        context.insert(SheepRecord(farmID: otherFarm.id, earTag: "OTHER-01", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2026-01-01")))
        try context.save()
        let workbook = try XLSXCodec.encode(sheets: [.init(name: "新建羊只", rows: [
            ["导入键", "耳号", "品种", "性别", "圈舍", "入场日期", "出生日期", "备注"],
            ["n1", "CURRENT-01", "湖羊", "母羊", "", "2026-07-19", "", ""],
            ["n2", "OTHER-01", "湖羊", "母羊", "", "2026-07-19", "", ""],
            ["n3", "NEW-01", "湖羊", "母羊", "", "2026-07-19", "", ""],
            ["n4", "NEW-01", "湖羊", "公羊", "", "2026-07-19", "", ""]
        ])])

        let preview = try FarmExcelImportService.preview(data: workbook, farm: farm, context: context)

        XCTAssertTrue(preview.issues.contains { $0.row == 2 && $0.field == "耳号" && $0.severity == .error })
        XCTAssertFalse(preview.issues.contains { $0.row == 3 && $0.field == "耳号" })
        XCTAssertTrue(preview.issues.contains { $0.row == 5 && $0.field == "耳号" && $0.severity == .error })
    }

    func testWorkbookCanCreateSheepThenRecordWeightInOneAtomicCommit() throws {
        let container = try AppSchema.makeContainer(name: "excel-atomic-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-atomic-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        context.insert(owner); context.insert(farm); try context.save()
        let workbook = try XLSXCodec.encode(sheets: [
            .init(name: "新建羊只", rows: [
                ["导入键", "耳号", "品种", "性别", "圈舍", "入场日期", "出生日期", "备注"],
                ["new-1", "N001", "湖羊", "母羊", "", "2026-07-01", "", ""]
            ]),
            .init(name: "称重", rows: [
                ["导入键", "耳号", "体重kg", "发生日期", "备注"],
                ["weight-1", "N001", "31.5", "2026-07-19", "导入称重"]
            ])
        ])
        let preview = try FarmExcelImportService.preview(data: workbook, farm: farm, context: context)
        XCTAssertTrue(preview.canCommit, preview.issues.map(\.message).joined(separator: "\n"))

        let imported = try FarmExcelImportService.commit(preview, account: owner, farm: farm, context: context)

        XCTAssertEqual(imported, 2)
        let created = try XCTUnwrap(context.fetch(FetchDescriptor<SheepRecord>()).first { $0.farmID == farm.id && $0.earTag == "N001" })
        XCTAssertEqual(try context.fetch(FetchDescriptor<WeightRecord>()).first { $0.sheepID == created.id }?.kilogramsText, "31.5")
        XCTAssertEqual(try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farm.id }.count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == farm.id }.count, 2)
    }

    func testCommandBatchRollsBackEveryPendingWriteWhenLaterCommandFails() throws {
        let container = try AppSchema.makeContainer(name: "excel-rollback-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-rollback-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        context.insert(owner); context.insert(farm); try context.save()
        let farmContext = FarmContext(accountID: owner.effectiveAccountID, farmID: farm.id, role: farm.role)

        XCTAssertThrowsError(try FarmCommandService().executeBatch([
            .createPen(name: "不应保留", note: ""),
            .recordWeight(sheepID: UUID(), kilogramsText: "30", occurredAt: date("2026-07-19"), note: "")
        ], in: farmContext, context: context))

        XCTAssertFalse(try context.fetch(FetchDescriptor<PenRecord>()).contains { $0.farmID == farm.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<DomainOperation>()).contains { $0.farmID == farm.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<OutboxItem>()).contains { $0.farmID == farm.id })
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}
