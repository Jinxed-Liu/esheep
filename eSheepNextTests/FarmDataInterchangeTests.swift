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

    func testTemplateV5PreservesV3StableImportIdentity() {
        let farmID = UUID()
        let expected = StableCloudUUID.derived(
            namespace: farmID,
            name: "excel-v3:健康记录:stable-key"
        )

        XCTAssertEqual(FarmExcelImportService.templateVersion, 5)
        XCTAssertEqual(
            FarmExcelImportService.stableImportID(
                farmID: farmID,
                sheet: "健康记录",
                key: "STABLE-KEY"
            ),
            expected
        )
    }

    func testPageExcelTemplateContainsOnlyInstructionsAndRequestedEntrySheet() throws {
        let data = try FarmExcelImportService.templateData(sheetNames: ["称重"])
        let sheets = try XLSXCodec.decodeSheets(data)

        XCTAssertEqual(sheets.map(\.name), ["填写说明", "称重"])
        XCTAssertFalse(sheets.contains { $0.name == "新建羊只" })
        XCTAssertFalse(sheets.contains { $0.name == "转群" })
    }

    func testWeaningTemplateRequiresTransferAndDoesNotAskForDamOrLitterSize() throws {
        let data = try FarmExcelImportService.templateData(sheetNames: ["断奶"])
        let sheets = try XLSXCodec.decodeSheets(data)
        let weaning = try XCTUnwrap(sheets.first { $0.name == "断奶" })

        XCTAssertEqual(
            weaning.rows.first,
            ["导入键", "耳号", "断奶重kg", "转入圈舍", "发生日期", "出生日期", "备注"]
        )
        XCTAssertNotNil(data.range(of: Data("最早一条实际称重".utf8)))
        XCTAssertNotNil(data.range(of: Data("断奶不填写母本或胎只数".utf8)))
    }

    func testWeaningExcelImportRecordsFactAndRequiredTransferTogether() throws {
        let container = try AppSchema.makeContainer(
            name: "excel-weaning-workflow-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-weaning-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        let sourcePen = PenRecord(farmID: farm.id, name: "羔羊圈")
        let targetPen = PenRecord(farmID: farm.id, name: "育肥圈")
        let sheep = SheepRecord(
            farmID: farm.id,
            earTag: "L001",
            breed: "湖羊",
            sex: .ram,
            penID: sourcePen.id,
            enteredAt: date("2026-03-01"),
            birthAt: date("2026-03-01")
        )
        context.insert(owner)
        context.insert(farm)
        context.insert(sourcePen)
        context.insert(targetPen)
        context.insert(sheep)
        try context.save()
        let workbook = try XLSXCodec.encode(sheets: [.init(name: "断奶", rows: [
            ["导入键", "耳号", "断奶重kg", "转入圈舍", "发生日期", "出生日期", "备注"],
            ["wean-001", "L001", "22.5", "育肥圈", "2026-07-19", "2026-03-01", "正常断奶"],
        ])])

        let preview = try FarmExcelImportService.preview(
            data: workbook,
            farm: farm,
            context: context,
            allowedSheetNames: ["断奶"]
        )
        XCTAssertTrue(preview.canCommit, preview.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(
            try FarmExcelImportService.commit(preview, account: owner, farm: farm, context: context),
            1
        )

        let weaning = try XCTUnwrap(try context.fetch(FetchDescriptor<WeaningRecord>()).first)
        let transfer = try XCTUnwrap(try context.fetch(FetchDescriptor<TransferRecord>()).first)
        XCTAssertNil(weaning.damID)
        XCTAssertNil(weaning.litterSize)
        XCTAssertEqual(transfer.sheepID, sheep.id)
        XCTAssertEqual(transfer.fromPenID, sourcePen.id)
        XCTAssertEqual(transfer.toPenID, targetPen.id)
        XCTAssertEqual(sheep.currentPenID, targetPen.id)
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        XCTAssertEqual(Set(operations.compactMap { DomainOperationKind(rawValue: $0.kindRawValue) }), [.recordWeaning, .transferSheep])
    }

    func testRemovalExcelTemplateUsesOneBatchTotalInsteadOfPerSheepAmount() throws {
        let data = try FarmExcelImportService.templateData(sheetNames: ["离场"])
        let sheets = try XLSXCodec.decodeSheets(data)
        let removal = try XCTUnwrap(sheets.first { $0.name == "离场" })

        XCTAssertEqual(
            removal.rows.first,
            ["导入键", "羊只耳号列表", "类型", "原因", "总售卖金额", "发生日期", "备注"]
        )
        XCTAssertTrue(removal.rows.first?.contains("金额") == false)
        XCTAssertTrue(data.range(of: Data("不填写或推算单羊价格".utf8)) != nil)
    }

    func testRemovalExcelBatchImportsOneTotalWithoutPerSheepPrices() throws {
        let container = try AppSchema.makeContainer(name: "excel-removal-batch-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-removal-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        let first = SheepRecord(farmID: farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2026-01-01"))
        let second = SheepRecord(farmID: farm.id, earTag: "A002", breed: "杜泊", sex: .ram, penID: nil, enteredAt: date("2026-01-01"))
        context.insert(owner); context.insert(farm); context.insert(first); context.insert(second)
        try context.save()
        let workbook = try XLSXCodec.encode(sheets: [.init(name: "离场", rows: [
            ["导入键", "羊只耳号列表", "类型", "原因", "总售卖金额", "发生日期", "备注"],
            ["sale-2026-01", "A001; A002", "出售", "整批出售", "2500.00", "2026-07-21", "同车出栏"]
        ])])

        let preview = try FarmExcelImportService.preview(
            data: workbook,
            farm: farm,
            context: context,
            allowedSheetNames: ["离场"]
        )

        XCTAssertTrue(preview.canCommit, preview.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(preview.rows.count, 1)
        XCTAssertEqual(preview.expandedRecordCount, 2)
        XCTAssertEqual(preview.removalBatchSummaries.first?.sheepCount, 2)
        XCTAssertEqual(preview.removalBatchSummaries.first?.totalAmountText, "2500")
        XCTAssertEqual(try FarmExcelImportService.commit(preview, account: owner, farm: farm, context: context), 2)

        let removals = try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.farmID == farm.id && $0.deletedAt == nil }
        XCTAssertEqual(removals.count, 2)
        XCTAssertEqual(Set(removals.compactMap(\.removalBatchID)).count, 1)
        XCTAssertTrue(removals.allSatisfy { $0.removalBatchID != nil })
        XCTAssertTrue(removals.allSatisfy { $0.amountText == nil })
        XCTAssertTrue(removals.allSatisfy { $0.batchTotalAmountText == "2500" })
        XCTAssertEqual(Set(removals.map(\.sheepID)), [first.id, second.id])
        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farm.id }
        XCTAssertEqual(operations.count, 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payloads = try operations.map {
            try decoder.decode(FarmCommandCloudPayload.self, from: $0.payload)
        }
        let payloadBatchIDs = payloads.compactMap { payload in
            payload.optionalIdentifiers["removalBatchID"].flatMap { $0 }
        }
        XCTAssertEqual(Set(payloadBatchIDs).count, 1)
        XCTAssertTrue(payloads.allSatisfy { $0.optionalStrings["amountText"].flatMap { $0 } == nil })
        XCTAssertTrue(payloads.allSatisfy { $0.optionalStrings["batchTotalAmountText"].flatMap { $0 } == "2500" })
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == farm.id }.count, 2)
    }

    func testLegacySingleSheepRemovalHeadersRemainCompatibleAsOneSheepBatch() throws {
        let container = try AppSchema.makeContainer(name: "excel-removal-legacy-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-removal-legacy-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        let sheep = SheepRecord(farmID: farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2026-01-01"))
        context.insert(owner); context.insert(farm); context.insert(sheep); try context.save()
        let workbook = try XLSXCodec.encode(sheets: [.init(name: "离场", rows: [
            ["导入键", "耳号", "类型", "原因", "金额", "发生日期", "备注"],
            ["legacy-sale-1", "A001", "出售", "出售", "1200", "2026-07-21", "旧模板"]
        ])])

        let preview = try FarmExcelImportService.preview(
            data: workbook,
            farm: farm,
            context: context,
            allowedSheetNames: ["离场"]
        )

        XCTAssertTrue(preview.canCommit, preview.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(preview.rows.first?["羊只耳号列表"], "A001")
        XCTAssertEqual(preview.rows.first?["总售卖金额"], "1200")
        XCTAssertEqual(preview.removalBatchSummaries.first?.sheepCount, 1)
        XCTAssertEqual(try FarmExcelImportService.commit(preview, account: owner, farm: farm, context: context), 1)
        let removal = try XCTUnwrap(context.fetch(FetchDescriptor<RemovalRecord>()).first { $0.farmID == farm.id })
        XCTAssertNil(removal.amountText)
        XCTAssertNotNil(removal.removalBatchID)
        XCTAssertEqual(removal.batchTotalAmountText, "1200")
    }

    func testRemovalBatchRequiresOneTotalAndRejectsRepeatedEarTags() throws {
        let container = try AppSchema.makeContainer(name: "excel-removal-validation-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-removal-validation-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        context.insert(owner); context.insert(farm)
        context.insert(SheepRecord(farmID: farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2026-01-01")))
        context.insert(SheepRecord(farmID: farm.id, earTag: "A002", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2026-01-01")))
        try context.save()
        let workbook = try XLSXCodec.encode(sheets: [.init(name: "离场", rows: [
            ["导入键", "羊只耳号列表", "类型", "原因", "总售卖金额", "发生日期", "备注"],
            ["sale-no-total", "A001;A001", "出售", "出售", "", "2026-07-21", ""],
            ["death-with-total", "A002", "死亡", "疾病", "500", "2026-07-21", ""]
        ])])

        let preview = try FarmExcelImportService.preview(
            data: workbook,
            farm: farm,
            context: context,
            allowedSheetNames: ["离场"]
        )

        XCTAssertFalse(preview.canCommit)
        XCTAssertTrue(preview.issues.contains { $0.row == 2 && $0.field == "总售卖金额" && $0.severity == .error })
        XCTAssertTrue(preview.issues.contains { $0.row == 2 && $0.field == "羊只耳号列表" && $0.severity == .error })
        XCTAssertTrue(preview.issues.contains { $0.row == 3 && $0.field == "总售卖金额" && $0.severity == .error })
    }

    func testLargeRemovalBatchImportDoesNotRepeatWholeHerdHistoryWork() throws {
        let container = try AppSchema.makeContainer(name: "excel-removal-large-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-removal-large-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        let sheep = (0..<20).map { index in
            SheepRecord(
                farmID: farm.id,
                earTag: String(format: "SALE-%03d", index),
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now.addingTimeInterval(-86_400)
            )
        }
        context.insert(owner)
        context.insert(farm)
        sheep.forEach(context.insert)
        try context.save()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let row = FarmExcelRow(
            sheet: "离场",
            rowNumber: 2,
            values: [
                "导入键": "large-sale",
                "羊只耳号列表": sheep.map(\.earTag).joined(separator: ";"),
                "类型": "出售",
                "原因": "整批出售",
                "总售卖金额": "20000",
                "发生日期": formatter.string(from: .now.addingTimeInterval(-2 * 86_400)),
                "备注": "性能回归",
            ]
        )
        let preview = FarmExcelPreview(rows: [row], issues: [], summaries: [.init(name: "离场", rowCount: 1)])
        var historyRebuildCount = 0
        var rebuiltSheepIDs = Set<UUID>()
        let commandService = FarmCommandService(historyRebuildObserver: { sheepIDs, _ in
            historyRebuildCount += 1
            rebuiltSheepIDs.formUnion(sheepIDs)
        })

        let startedAt = Date.timeIntervalSinceReferenceDate
        let imported = try FarmExcelImportService.commit(
            preview,
            account: owner,
            farm: farm,
            context: context,
            commandService: commandService
        )
        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt
        print("LARGE_REMOVAL_IMPORT_SECONDS=\(elapsed)")

        XCTAssertEqual(imported, sheep.count)
        XCTAssertEqual(historyRebuildCount, 1)
        XCTAssertEqual(rebuiltSheepIDs, Set(sheep.map(\.id)))
        XCTAssertTrue(sheep.allSatisfy { $0.status == .removed && $0.removedAt != nil })
        XCTAssertEqual(try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.farmID == farm.id }.count, sheep.count)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farm.id }.count, sheep.count)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == farm.id }.count, sheep.count)
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

    func testCommandBatchFlushesRemovalProjectionBeforeLaterMembershipValidation() throws {
        let container = try AppSchema.makeContainer(name: "excel-history-flush-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "excel-history-flush-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.effectiveAccountID, name: "测试场")
        let enteredAt = Date.now.addingTimeInterval(-86_400)
        let sheep = SheepRecord(farmID: farm.id, earTag: "FLUSH-001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: enteredAt)
        context.insert(owner)
        context.insert(farm)
        context.insert(sheep)
        try context.save()
        let farmContext = FarmContext(accountID: owner.effectiveAccountID, farmID: farm.id, role: farm.role)

        XCTAssertThrowsError(try FarmCommandService().executeBatch([
            .removeSheep(sheepID: sheep.id, kind: .sold, reason: "出售", amountText: "1000", occurredAt: .now, note: ""),
            .createBatch(name: "不应创建", purpose: "育肥", startedAt: enteredAt, sheepIDs: [sheep.id], note: ""),
        ], in: farmContext, context: context)) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.sheepNotFound.localizedDescription)
        }

        XCTAssertEqual(sheep.status, .active)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RemovalRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ProductionBatchRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DomainOperation>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutboxItem>()).isEmpty)
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}
