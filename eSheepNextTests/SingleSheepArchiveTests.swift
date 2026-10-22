import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

/// Content acceptance, independent of the system share/save panels. All stores
/// and identities are synthetic; no account, network or production store is used.
@MainActor
final class SingleSheepArchiveTests: XCTestCase {
    func testSavedArchiveContainsHistoricalFactsForEveryRoleWithoutScopeLeaks() async throws {
        for role in FarmRole.allCases {
            let f = try Fixture(role: role)
            let sheets = try await savedWorkbook(f, name: "historical-\(role.rawValue)")
            XCTAssertEqual(sheets.map(\.name), [
                "体重增重区间", "单羊档案", "系谱关系", "直接后代", "时间线",
                "体重记录", "健康记录", "转群记录", "繁殖记录", "断奶记录",
                "离场记录", "备注记录", "用途记录"
            ])
            let profile = try table("单羊档案", in: sheets)
            XCTAssertEqual(profile[0], ["单羊档案", "SYN-001", "", ""])
            XCTAssertEqual(try field("品种", in: profile), "虚构湖羊")
            XCTAssertEqual(try field("状态", in: profile), "离场")
            XCTAssertEqual(try field("当前圈舍", in: profile), "已离群")
            XCTAssertEqual(try field("出生日期", in: profile), "2023-01-01 00:30")
            XCTAssertEqual(try field("牧场时区", in: profile), "Asia/Shanghai")
            XCTAssertEqual(try field("母本", in: profile), "SYN-DAM")
            XCTAssertEqual(try field("父本", in: profile), "SYN-SIRE")
            XCTAssertEqual(try field("备注", in: profile), "虚构档案 & <完整>\n保留换行")
            XCTAssertEqual(try table("系谱关系", in: sheets).count, 3)
            let children = try table("直接后代", in: sheets)
            XCTAssertEqual(children.count, 2)
            XCTAssertEqual(children[1][0], "SYN-CHILD")

            let timeline = try table("时间线", in: sheets)
            XCTAssertTrue(timeline.contains(["初生重", "2023-01-01 00:30", "3.50 千克", ""]))
            XCTAssertTrue(timeline.contains(["断奶重", "2023-03-01 08:00", "12.25 千克", ""]))
            XCTAssertTrue(timeline.contains(["治疗", "2023-04-01 08:00", "历史群体治疗", "旧圈舍成员快照"]))
            XCTAssertEqual(timeline.dropFirst().filter { $0[0] == "初生重" }.count, 1)
            XCTAssertEqual(timeline.dropFirst().filter { $0[0] == "称重" }.count, 2)
            XCTAssertEqual(timeline.dropFirst().map { $0[1] }, timeline.dropFirst().map { $0[1] }.sorted())

            let expectedCounts = ["体重记录": 4, "健康记录": 2, "转群记录": 2,
                                  "繁殖记录": 5, "断奶记录": 1, "离场记录": 1,
                                  "备注记录": 1, "用途记录": 1]
            for (name, count) in expectedCounts {
                let rows = try table(name, in: sheets)
                XCTAssertEqual(rows.count - 1, count, "\(role): \(name)")
                if let expectedIDs = f.expectedRecordIDs[name] {
                    XCTAssertEqual(Set(rows.dropFirst().map { $0[0] }), expectedIDs, name)
                }
                for row in rows.dropFirst() {
                    XCTAssertEqual(row.count, rows[0].count, name)
                    XCTAssertEqual(row[1], f.farm.id.uuidString, name)
                    XCTAssertEqual(row[2], f.sheep.id.uuidString, name)
                    XCTAssertEqual(row[3], "SYN-001", name)
                }
            }
            let weights = try dictionaries("体重记录", in: sheets)
            XCTAssertEqual(weights.map { $0["体重kg"]! }, ["3.50", "12.25", "30.25", "31.75"])
            XCTAssertEqual(weights.map { $0["发生时间"]! }, ["2023-01-01 00:30", "2023-03-01 08:00", "2023-06-01 09:00", "2023-06-01 16:00"])
            XCTAssertEqual(weights.suffix(2).map { $0["备注"]! }, ["上午称重", "下午称重"])
            let gains = try dictionaries("体重增重区间", in: sheets)
            XCTAssertEqual(gains.count, 2, "Same-day measurements must not create a zero-day gain interval")
            XCTAssertEqual(gains.map { $0["天数"]! }, ["59", "92"])
            XCTAssertEqual(gains.map { $0["结束体重kg"]! }, ["12.25", "31.75"])
            let transfers = try dictionaries("转群记录", in: sheets)
            XCTAssertEqual(transfers[0]["转出圈舍"], "虚构旧圈")
            XCTAssertEqual(transfers[0]["转入圈舍"], "虚构新圈")
            XCTAssertEqual(transfers[1]["转出圈舍ID"], f.newPen.id.uuidString)
            XCTAssertEqual(transfers[1]["转入圈舍ID"], "")
            XCTAssertEqual(transfers.map { $0["发生时间"]! }, ["2023-05-01 08:00", "2024-08-01 08:00"])
            let health = try dictionaries("健康记录", in: sheets)
            XCTAssertEqual(health.map { $0["发生时间"]! }, ["2023-02-01 08:00", "2023-04-01 08:00"])
            let historical = try XCTUnwrap(health.first { $0["项目"] == "历史群体治疗" })
            XCTAssertEqual(historical["剂量"], "2.5")
            XCTAssertEqual(historical["单位"], "mL")
            XCTAssertEqual(historical["给药途径"], "口服")
            XCTAssertEqual(historical["原记录羊只ID"], "")
            let reproduction = try dictionaries("繁殖记录", in: sheets)
            XCTAssertEqual(reproduction.map { $0["类型"]! }, ["胎次确认", "配种", "孕检", "产羔", "流产"])
            XCTAssertEqual(reproduction.map { $0["发生时间"]! }, ["2024-01-01 08:00", "2024-01-31 08:00", "2024-03-01 08:00", "2024-03-31 08:00", "2024-04-30 08:00"])
            let lambing = try XCTUnwrap(reproduction.first { $0["类型"] == "产羔" })
            XCTAssertEqual(lambing["母羊ID"], f.sheep.id.uuidString)
            XCTAssertEqual(lambing["胎次"], "2")
            XCTAssertEqual(lambing["产羔数"], "3")
            XCTAssertEqual(lambing["死羔数"], "1")
            XCTAssertEqual(try dictionaries("离场记录", in: sheets)[0]["原因"], "虚构历史出售")
            XCTAssertEqual(try dictionaries("备注记录", in: sheets)[0]["备注"], "历史随访 & <正常>")
            XCTAssertEqual(try dictionaries("用途记录", in: sheets)[0]["备注"], "虚构用途变更")
            for (name, expectedDate) in ["断奶记录": "2023-03-01 08:00", "离场记录": "2024-09-01 08:00",
                                         "备注记录": "2024-02-01 08:00", "用途记录": "2023-12-01 08:00"] {
                XCTAssertEqual(try dictionaries(name, in: sheets)[0]["发生时间"], expectedDate, name)
            }
            assertNoForbiddenCells(sheets)
        }
    }

    func testRamArchiveIncludesItsBreedingButNotTheEwesOtherEvents() async throws {
        let f = try Fixture(role: .worker)
        let reader = SheepDetailSnapshotActor(container: f.container)
        let data = try await reader.singleSheepXLSXData(farmID: f.farm.id, sheepID: f.sire.id, penName: nil)
        let sheets = try saveAndRead(data, name: "ram-breeding")
        let rows = try dictionaries("繁殖记录", in: sheets)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["类型"], "配种")
        XCTAssertEqual(rows[0]["羊只ID"], f.sire.id.uuidString)
        XCTAssertEqual(rows[0]["母羊ID"], f.sheep.id.uuidString)
        XCTAssertEqual(rows[0]["公羊ID"], f.sire.id.uuidString)
        XCTAssertEqual(try table("时间线", in: sheets).dropFirst().filter { $0[0] == "配种" }.count, 1)
        XCTAssertFalse(try table("时间线", in: sheets).contains { $0[0] == "产羔" || $0[0] == "治疗" })
        assertNoForbiddenCells(sheets)
    }

    func testHistoricalHealthUsesSubjectLinksNotCurrentPenOrForeignMembership() async throws {
        let f = try Fixture(role: .worker)
        let target = SheepRecord(farmID: f.farm.id, earTag: "SYN-MEMBERSHIP", breed: "虚构", sex: .ewe,
                                 penID: f.newPen.id, enteredAt: f.sheep.enteredAt)
        f.context.insert(target)
        // Membership in the old pen's treatment remains valid after moving.
        f.context.insert(HealthSubjectLink(farmID: f.farm.id, healthRecordID: f.linkedHealth.id, sheepID: target.id))
        let foreignLinkOnly = HealthRecord(farmID: f.farm.id, sheepID: nil, penID: f.oldPen.id, kind: .treatment,
                                           itemNameSnapshot: "FORBIDDEN foreign membership", occurredAt: f.sheep.enteredAt)
        f.context.insert(foreignLinkOnly)
        f.context.insert(HealthSubjectLink(farmID: f.otherFarm.id, healthRecordID: foreignLinkOnly.id, sheepID: target.id))
        // A malformed link cannot override another sheep's explicit ownership.
        let otherSheepHealth = HealthRecord(farmID: f.farm.id, sheepID: f.sheep.id, penID: nil, kind: .treatment,
                                            itemNameSnapshot: "FORBIDDEN conflicting membership", occurredAt: f.sheep.enteredAt)
        f.context.insert(otherSheepHealth)
        f.context.insert(HealthSubjectLink(farmID: f.farm.id, healthRecordID: otherSheepHealth.id, sheepID: target.id))
        try f.context.save()
        let data = try await SheepDetailSnapshotActor(container: f.container)
            .singleSheepXLSXData(farmID: f.farm.id, sheepID: target.id, penName: "FORBIDDEN stale UI pen")
        let sheets = try saveAndRead(data, name: "historical-membership")
        let rows = try dictionaries("健康记录", in: sheets)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["项目"], "历史群体治疗")
        XCTAssertEqual(try field("当前圈舍", in: table("单羊档案", in: sheets)), "虚构新圈")
        assertNoForbiddenCells(sheets)
    }

    func testArchiveRejectsDeletedMissingAndWrongFarmSubjects() async throws {
        let f = try Fixture(role: .administrator)
        let reader = SheepDetailSnapshotActor(container: f.container)
        let invalid: [(UUID, UUID)] = [(f.otherFarm.id, f.sheep.id), (f.farm.id, UUID()), (f.farm.id, f.deletedSheep.id)]
        for (farmID, sheepID) in invalid {
            do {
                _ = try await reader.singleSheepXLSXData(farmID: farmID, sheepID: sheepID, penName: nil)
                XCTFail("An unavailable or out-of-farm sheep must not generate an archive")
            } catch SheepDetailSnapshotError.sheepNotFound {
                // Expected, including soft-deleted subjects.
            }
        }
    }

    func testCodecScopesMixedInputsBeforeComputingProfileAndExcludesDeletedDonors() throws {
        let f = try Fixture(role: .owner)
        let donor = SemenDonorRecord(farmID: f.farm.id, name: "FORBIDDEN deleted donor", breed: "FORBIDDEN")
        donor.deletedAt = Fixture.date("2024-01-01T00:00:00Z")
        f.sheep.semenDonorID = donor.id
        f.sheep.semenDonorNameSnapshot = "合法历史供体快照"
        let data = try FarmDataInterchange.singleSheepXLSXData(
            sheep: f.sheep, penName: nil,
            weights: f.context.fetch(FetchDescriptor<WeightRecord>()),
            health: f.context.fetch(FetchDescriptor<HealthRecord>()),
            healthRecordIDs: [f.linkedHealth.id],
            reproduction: f.context.fetch(FetchDescriptor<ReproductionRecord>()),
            transfers: f.context.fetch(FetchDescriptor<TransferRecord>()),
            allSheep: f.context.fetch(FetchDescriptor<SheepRecord>()), semenDonors: [donor]
        )
        let sheets = try saveAndRead(data, name: "mixed-inputs")
        assertNoForbiddenCells(sheets)
        XCTAssertEqual(try field("冻精供体", in: table("单羊档案", in: sheets)), "合法历史供体快照")
        XCTAssertNotEqual(try field("已完成产羔胎次", in: table("单羊档案", in: sheets)), "999")
        XCTAssertEqual(try dictionaries("健康记录", in: sheets).count, 2)
        XCTAssertEqual(try dictionaries("繁殖记录", in: sheets).count, 5)
    }

    func testDatesUseFarmTimeZoneAndPreserveBothSidesOfDSTOverlap() async throws {
        let f = try Fixture(role: .owner)
        f.farm.timeZoneIdentifier = "America/New_York"
        let target = SheepRecord(farmID: f.farm.id, earTag: "SYN-DST", breed: "虚构", sex: .ewe, penID: nil,
                                 enteredAt: Fixture.date("2024-11-03T03:30:00Z"))
        f.context.insert(target)
        for instant in ["2024-11-03T05:30:00Z", "2024-11-03T06:30:00Z"] {
            f.context.insert(WeightRecord(farmID: f.farm.id, sheepID: target.id, kilogramsText: "40", occurredAt: Fixture.date(instant), note: instant))
        }
        try f.context.save()
        let data = try await SheepDetailSnapshotActor(container: f.container)
            .singleSheepXLSXData(farmID: f.farm.id, sheepID: target.id, penName: nil)
        let sheets = try saveAndRead(data, name: "dst-overlap")
        XCTAssertEqual(try field("入场时间", in: table("单羊档案", in: sheets)), "2024-11-02 23:30")
        XCTAssertEqual(try field("牧场时区", in: table("单羊档案", in: sheets)), "America/New_York")
        let rows = try dictionaries("体重记录", in: sheets)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0["发生时间"]! }, ["2024-11-03 01:30", "2024-11-03 01:30"])
        XCTAssertEqual(Set(rows.map { $0["记录ID"]! }).count, 2)
        XCTAssertEqual(rows.map { $0["备注"]! }, ["2024-11-03T05:30:00Z", "2024-11-03T06:30:00Z"])
    }

    func testArchiveDoesNotTruncateOldHistoryAndPreservesLiteralCells() async throws {
        let f = try Fixture(role: .worker)
        let note = "=HYPERLINK(\"https://example.invalid\",\"literal\") & <not markup>\n第二行"
        let target = SheepRecord(farmID: f.farm.id, earTag: "SYN-LONG", breed: "虚构", sex: .unknown, penID: nil,
                                 enteredAt: Fixture.date("2020-01-01T00:00:00Z"), note: note)
        f.context.insert(target)
        for index in 0..<150 {
            f.context.insert(WeightRecord(farmID: f.farm.id, sheepID: target.id, kilogramsText: "\(index + 1)",
                                         occurredAt: target.enteredAt.addingTimeInterval(Double(index) * 86_400), note: "history-\(index)"))
        }
        try f.context.save()
        let data = try await SheepDetailSnapshotActor(container: f.container)
            .singleSheepXLSXData(farmID: f.farm.id, sheepID: target.id, penName: nil)
        let sheets = try saveAndRead(data, name: "long-history")
        let rows = try dictionaries("体重记录", in: sheets)
        XCTAssertEqual(rows.count, 150)
        XCTAssertEqual(rows.first?["备注"], "history-0")
        XCTAssertEqual(rows.last?["备注"], "history-149")
        XCTAssertEqual(try field("备注", in: table("单羊档案", in: sheets)), note)
        for name in ["健康记录", "转群记录", "繁殖记录", "断奶记录", "离场记录", "备注记录", "用途记录"] {
            XCTAssertEqual(try table(name, in: sheets).count, 1, name)
        }
        XCTAssertNil(data.range(of: Data("<f>".utf8)), "User text must stay literal")
    }

    func testSingleSheepReadPermissionDoesNotGrantWholeFarmExport() {
        for role in FarmRole.allCases {
            let capabilities = CapabilitySet(role: role)
            XCTAssertTrue(capabilities.allows(.readFarm))
            XCTAssertEqual(capabilities.allows(.exportFarm), role == .owner)
            let policy = SettingsVisibilityPolicy(role: role, cloudEnabled: true, subscriptionEnabled: false, unresolvedConflictCount: 0)
            XCTAssertEqual(policy.shows(.exportData), role == .owner)
        }
        for grant: Set<FarmCapability> in [[], [.readFarm], [.exportEvents], [.viewAnalytics]] {
            XCTAssertFalse(CapabilitySet(role: .worker, grantedWorkerCapabilities: grant).allows(.exportFarm))
        }
        // An explicit pre-existing exportFarm grant remains distinct from readFarm.
        XCTAssertTrue(CapabilitySet(role: .worker, grantedWorkerCapabilities: [.exportFarm]).allows(.exportFarm))
    }

    private func savedWorkbook(_ f: Fixture, name: String) async throws -> [XLSXSheet] {
        let data = try await SheepDetailSnapshotActor(container: f.container)
            .singleSheepXLSXData(farmID: f.farm.id, sheepID: f.sheep.id, penName: f.newPen.name)
        return try saveAndRead(data, name: name)
    }

    private func saveAndRead(_ data: Data, name: String) throws -> [XLSXSheet] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name + ".xlsx")
        try data.write(to: file, options: .atomic)
        let reopened = try Data(contentsOf: file)
        XCTAssertEqual(reopened, data)
        XCTAssertEqual(Array(reopened.prefix(2)), [0x50, 0x4b])
        let attachment = XCTAttachment(data: reopened, uniformTypeIdentifier: "org.openxmlformats.spreadsheetml.sheet")
        attachment.name = name + ".xlsx"
        attachment.lifetime = .keepAlways
        add(attachment)
        let sheets = try XLSXCodec.decodeSheets(reopened)
        XCTAssertFalse(sheets.isEmpty)
        return sheets
    }

    private func table(_ name: String, in sheets: [XLSXSheet]) throws -> [[String]] {
        try XCTUnwrap(sheets.first { $0.name == name }, "Missing sheet: \(name)").rows
    }

    private func field(_ name: String, in rows: [[String]]) throws -> String {
        try XCTUnwrap(rows.first { $0.first == name }, "Missing field: \(name)")[1]
    }

    private func dictionaries(_ name: String, in sheets: [XLSXSheet]) throws -> [[String: String]] {
        let rows = try table(name, in: sheets)
        let header = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(header).count, header.count, "Headers must be unique")
        return rows.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
    }

    private func assertNoForbiddenCells(_ sheets: [XLSXSheet], file: StaticString = #filePath, line: UInt = #line) {
        for sheet in sheets {
            for row in sheet.rows {
                XCTAssertFalse(row.contains { $0.contains("FORBIDDEN") }, "Leaked row in \(sheet.name): \(row)", file: file, line: line)
            }
        }
    }

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let farm: FarmRecord
        let otherFarm: FarmRecord
        let sheep: SheepRecord
        let sire: SheepRecord
        let deletedSheep: SheepRecord
        let oldPen: PenRecord
        let newPen: PenRecord
        let linkedHealth: HealthRecord
        let expectedRecordIDs: [String: Set<String>]

        init(role: FarmRole) throws {
            container = try AppSchema.makeContainer(name: "synthetic-single-archive-\(UUID())", isStoredInMemoryOnly: true)
            context = ModelContext(container)
            context.autosaveEnabled = false
            farm = FarmRecord(ownerAccountID: UUID(), name: "虚构甲场", role: role)
            otherFarm = FarmRecord(ownerAccountID: UUID(), name: "FORBIDDEN 乙场")
            let thirdFarm = FarmRecord(ownerAccountID: UUID(), name: "FORBIDDEN 丙场", role: .worker)
            oldPen = PenRecord(farmID: farm.id, name: "虚构旧圈")
            oldPen.isActive = false
            newPen = PenRecord(farmID: farm.id, name: "虚构新圈")
            let dam = SheepRecord(farmID: farm.id, earTag: "SYN-DAM", isHistoricalArchive: true, breed: "虚构湖羊", sex: .ewe, penID: nil, enteredAt: Self.date("2020-01-01T00:00:00Z"))
            dam.statusRawValue = SheepStatus.deceased.rawValue
            sire = SheepRecord(farmID: farm.id, earTag: "SYN-SIRE", isHistoricalArchive: true, breed: "虚构湖羊", sex: .ram, penID: nil, enteredAt: dam.enteredAt)
            sire.statusRawValue = SheepStatus.removed.rawValue
            sheep = SheepRecord(farmID: farm.id, earTag: "SYN-001", isHistoricalArchive: true, breed: "虚构湖羊", sex: .ewe, penID: nil,
                                enteredAt: Self.date("2022-12-31T16:30:00Z"), birthAt: Self.date("2022-12-31T16:30:00Z"),
                                damID: dam.id, sireID: sire.id, note: "虚构档案 & <完整>\n保留换行")
            sheep.statusRawValue = SheepStatus.removed.rawValue
            sheep.removedAt = Self.date("2024-09-01T00:00:00Z")
            deletedSheep = SheepRecord(farmID: farm.id, earTag: "FORBIDDEN deleted sheep", breed: "FORBIDDEN", sex: .ewe, penID: nil, enteredAt: sheep.enteredAt, damID: sheep.id)
            deletedSheep.deletedAt = sheep.removedAt
            let other = SheepRecord(farmID: farm.id, earTag: "FORBIDDEN other sheep", breed: "FORBIDDEN", sex: .ewe, penID: newPen.id, enteredAt: sheep.enteredAt)
            let sameTag = SheepRecord(farmID: otherFarm.id, earTag: "SYN-001", breed: "FORBIDDEN same tag", sex: .ewe, penID: nil, enteredAt: sheep.enteredAt, damID: sheep.id)
            let child = SheepRecord(farmID: farm.id, earTag: "SYN-CHILD", isHistoricalArchive: true, breed: "虚构湖羊", sex: .ram, penID: nil, enteredAt: Self.date("2024-05-01T00:00:00Z"), damID: sheep.id)
            child.statusRawValue = SheepStatus.removed.rawValue
            for item in [farm, otherFarm, thirdFarm] { context.insert(item) }
            for item in [oldPen, newPen] { context.insert(item) }
            for item in [sheep, dam, sire, deletedSheep, other, sameTag, child] { context.insert(item) }
            for (date, weight, note) in [("2023-06-01T01:00:00Z", "30.25", "上午称重"), ("2023-06-01T08:00:00Z", "31.75", "下午称重")] {
                context.insert(WeightRecord(farmID: farm.id, sheepID: sheep.id, kilogramsText: weight, occurredAt: Self.date(date), note: note))
            }
            let validWeaning = WeaningRecord(farmID: farm.id, sheepID: sheep.id, occurredAt: Self.date("2023-03-01T00:00:00Z"), weanWeightText: "12.25", birthAt: sheep.birthAt, birthWeightText: "3.5", note: "虚构断奶")
            context.insert(validWeaning)
            let birth = ReproductionRecord(farmID: farm.id, eweID: dam.id, kind: .lambing, occurredAt: sheep.enteredAt)
            context.insert(birth)
            context.insert(LambingOffspringRecord(farmID: farm.id, lambingRecordID: birth.id, sheepID: sheep.id, legacyEarTag: sheep.earTag, sexRawValue: LambSex.female.rawValue, birthWeightText: "3.5"))
            let firstTransfer = TransferRecord(farmID: farm.id, sheepID: sheep.id, fromPenID: oldPen.id, toPenID: newPen.id, occurredAt: Self.date("2023-05-01T00:00:00Z"), note: "虚构转群一")
            let secondTransfer = TransferRecord(farmID: farm.id, sheepID: sheep.id, fromPenID: newPen.id, toPenID: nil, occurredAt: Self.date("2024-08-01T00:00:00Z"), note: "虚构转群二")
            context.insert(firstTransfer); context.insert(secondTransfer)
            let direct = HealthRecord(farmID: farm.id, sheepID: sheep.id, penID: nil, kind: .vaccination, itemNameSnapshot: "虚构疫苗", occurredAt: Self.date("2023-02-01T00:00:00Z"))
            context.insert(direct)
            linkedHealth = HealthRecord(farmID: farm.id, sheepID: nil, penID: oldPen.id, kind: .treatment, itemNameSnapshot: "历史群体治疗", occurredAt: Self.date("2023-04-01T00:00:00Z"), note: "旧圈舍成员快照", quantityText: "2.5", unit: "mL", route: "口服")
            context.insert(linkedHealth)
            // Duplicate/direct links must not duplicate rows. No inference from current pen.
            for health in [direct, linkedHealth, linkedHealth] {
                context.insert(HealthSubjectLink(farmID: farm.id, healthRecordID: health.id, sheepID: sheep.id))
            }
            context.insert(HealthSubjectLink(farmID: farm.id, healthRecordID: UUID(), sheepID: sheep.id))
            context.insert(HealthRecord(farmID: farm.id, sheepID: nil, penID: newPen.id, kind: .treatment, itemNameSnapshot: "FORBIDDEN unlinked pen treatment", occurredAt: sheep.enteredAt))
            var reproductionIDs = Set<String>()
            for (index, kind) in ReproductionRecordKind.allCases.enumerated() {
                let record = ReproductionRecord(farmID: farm.id, eweID: sheep.id, kind: kind,
                    occurredAt: Self.date("2024-01-01T00:00:00Z").addingTimeInterval(Double(index) * 30 * 86_400),
                    sireID: sire.id, result: kind == .pregnancyCheck ? "阳性" : "", lambCount: kind == .lambing ? 3 : 0,
                    parity: kind == .parityBaseline ? 1 : (kind == .lambing ? 2 : nil), birthDeadCount: kind == .lambing ? 1 : nil, note: "虚构繁殖-\(kind.rawValue)")
                context.insert(record)
                reproductionIDs.insert(record.id.uuidString)
            }
            let validRemoval = RemovalRecord(farmID: farm.id, sheepID: sheep.id, kind: .sold, reason: "虚构历史出售", occurredAt: sheep.removedAt!)
            let validNote = NoteRecord(farmID: farm.id, sheepID: sheep.id, text: "历史随访 & <正常>", occurredAt: Self.date("2024-02-01T00:00:00Z"))
            context.insert(validRemoval); context.insert(validNote)
            let purpose = FarmCommand.care(.setSheepPurpose(sheepID: sheep.id, purpose: .breedingEwe, reason: "虚构用途变更", expectedRevision: 1))
            let payload = try FarmCommandCloudPayloadEncoder.encode(purpose)
            let purposeOperation = DomainOperation(farmID: farm.id, accountID: farm.ownerAccountID, kind: .care, occurredAt: Self.date("2023-12-01T00:00:00Z"), summary: "用途变更", entityID: sheep.id, payload: payload)
            context.insert(purposeOperation)
            expectedRecordIDs = [
                "健康记录": [direct.id.uuidString, linkedHealth.id.uuidString],
                "转群记录": [firstTransfer.id.uuidString, secondTransfer.id.uuidString],
                "繁殖记录": reproductionIDs, "断奶记录": [validWeaning.id.uuidString],
                "离场记录": [validRemoval.id.uuidString], "备注记录": [validNote.id.uuidString],
                "用途记录": [purposeOperation.id.uuidString]
            ]

            // Adversarial combinations: another sheep; same sheep UUID under a
            // foreign farm; a second foreign farm; and tombstoned target records.
            let scopes: [(UUID, UUID, Bool)] = [(farm.id, other.id, false), (otherFarm.id, sheep.id, false),
                                               (thirdFarm.id, sheep.id, false), (farm.id, sheep.id, true)]
            for (farmID, sheepID, deleted) in scopes {
                let when = Self.date("2024-07-01T00:00:00Z")
                let weight = WeightRecord(farmID: farmID, sheepID: sheepID, kilogramsText: "999", occurredAt: when, note: "FORBIDDEN weight")
                let transfer = TransferRecord(farmID: farmID, sheepID: sheepID, fromPenID: oldPen.id, toPenID: newPen.id, occurredAt: when, note: "FORBIDDEN transfer")
                let reproduction = ReproductionRecord(farmID: farmID, eweID: sheepID, kind: .lambing, occurredAt: when, sireID: sire.id, lambCount: 999, parity: 999, note: "FORBIDDEN reproduction")
                let health = HealthRecord(farmID: farmID, sheepID: sheepID, penID: nil, kind: .treatment, itemNameSnapshot: "FORBIDDEN health", occurredAt: when)
                let weaning = WeaningRecord(farmID: farmID, sheepID: sheepID, occurredAt: when, weanWeightText: "999", note: "FORBIDDEN weaning")
                let removal = RemovalRecord(farmID: farmID, sheepID: sheepID, kind: .sold, reason: "FORBIDDEN removal", occurredAt: when)
                let note = NoteRecord(farmID: farmID, sheepID: sheepID, text: "FORBIDDEN note", occurredAt: when)
                let offspring = LambingOffspringRecord(farmID: farmID, lambingRecordID: birth.id, sheepID: sheepID, legacyEarTag: "FORBIDDEN", sexRawValue: LambSex.female.rawValue, birthWeightText: "999")
                if deleted {
                    weight.deletedAt = when; transfer.deletedAt = when; reproduction.deletedAt = when
                    health.deletedAt = when; weaning.deletedAt = when; removal.deletedAt = when
                    note.deletedAt = when; offspring.deletedAt = when
                }
                context.insert(weight); context.insert(transfer); context.insert(reproduction); context.insert(health)
                context.insert(weaning); context.insert(removal); context.insert(note); context.insert(offspring)
                // A link in the target farm must not pull in a foreign health row.
                if farmID != farm.id || deleted {
                    context.insert(HealthSubjectLink(farmID: farm.id, healthRecordID: health.id, sheepID: sheep.id))
                }
            }
            let revoked = LambingOffspringRecord(farmID: farm.id, lambingRecordID: birth.id, sheepID: sheep.id, legacyEarTag: "FORBIDDEN revoked", sexRawValue: LambSex.female.rawValue, birthWeightText: "999")
            revoked.deletedByLambingRevocation = true
            context.insert(revoked)
            try context.save()
        }

        static func date(_ iso8601: String) -> Date {
            ISO8601DateFormatter().date(from: iso8601)!
        }
    }
}
