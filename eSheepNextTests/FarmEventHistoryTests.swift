import SwiftData
import XCTest
@testable import eSheepNext

final class FarmEventHistoryTests: XCTestCase {
    func testEventEditCapabilitiesDistinguishFactsFromLedgers() {
        func event(_ entityType: CloudEntityType) -> FarmEventSnapshot {
            FarmEventSnapshot(
                id: UUID(),
                entityType: entityType,
                category: .herd,
                occurredAt: .now,
                recordedAt: .now,
                title: "测试",
                subject: "A001",
                detail: "",
                note: "",
                fields: []
            )
        }

        XCTAssertEqual(event(.sheep).editCapability, .recordProduction)
        XCTAssertEqual(event(.weight).editCapability, .editHistoricalFacts)
        XCTAssertEqual(event(.transfer).editCapability, .editHistoricalFacts)
        XCTAssertEqual(event(.removal).editCapability, .editHistoricalFacts)
        XCTAssertEqual(event(.health).editCapability, .editHistoricalFacts)
        XCTAssertEqual(event(.reproduction).editCapability, .editHistoricalFacts)
        XCTAssertNil(event(.feed).editCapability)
        XCTAssertNil(event(.inventoryTransaction).editCapability)
        XCTAssertNil(event(.semenTransaction).editCapability)
    }

    @MainActor
    func testAdministratorCanCorrectHistoryButCannotDeleteIt() throws {
        let container = try AppSchema.makeContainer(name: "event-edit-permission-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let sheep = SheepRecord(farmID: farmID, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        let weight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "40", occurredAt: .now)
        context.insert(sheep)
        context.insert(weight)
        try context.save()

        let service = FarmCommandService()
        let farmContext = FarmContext(accountID: UUID(), farmID: farmID, role: .administrator)
        try service.execute(
            .correctWeight(
                originalID: weight.id,
                kilogramsText: "41.5",
                occurredAt: weight.occurredAt,
                note: "复称",
                reason: "录入错误"
            ),
            in: farmContext,
            context: context
        )

        XCTAssertNotNil(weight.deletedAt)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<WeightRecord>()).first(where: { $0.deletedAt == nil })?.kilogramsText,
            "41.5"
        )
        XCTAssertThrowsError(
            try service.execute(
                .tombstoneEntity(entityType: .weight, entityID: weight.id, reason: "删除"),
                in: farmContext,
                context: context
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, FarmPermissionError.denied(.deleteProtectedFacts).localizedDescription)
        }
    }

    func testSearchMatchesNormalizedEventContentAndKeepsCurrentOrder() {
        let first = FarmEventSnapshot(
            id: UUID(),
            entityType: .removal,
            category: .herd,
            occurredAt: Date(timeIntervalSince1970: 200),
            recordedAt: Date(timeIntervalSince1970: 200),
            title: "出售",
            subject: "A-001",
            detail: "客户自提",
            note: "Café 批次",
            fields: [.init(label: "圈舍", value: "东一圈")]
        )
        let second = FarmEventSnapshot(
            id: UUID(),
            entityType: .note,
            category: .note,
            occurredAt: Date(timeIntervalSince1970: 100),
            recordedAt: Date(timeIntervalSince1970: 100),
            title: "备注",
            subject: "B-002",
            detail: "观察采食",
            note: "",
            fields: []
        )

        XCTAssertEqual(
            FarmEventSearch.filter([first, second], query: "  a-001  ", category: nil, scope: .all).map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            FarmEventSearch.filter([first, second], query: "CAFE", category: nil, scope: .all).map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            FarmEventSearch.filter([first, second], query: "", category: nil, scope: .all).map(\.id),
            [first.id, second.id]
        )
        XCTAssertTrue(FarmEventSearch.filter([first, second], query: "A-001", category: .note, scope: .all).isEmpty)
    }

    func testEventRowIdentityIncludesEntityType() {
        let sharedID = UUID()
        let weight = FarmEventSnapshot(
            id: sharedID,
            entityType: .weight,
            category: .herd,
            occurredAt: .now,
            recordedAt: .now,
            title: "称重",
            subject: "A-001",
            detail: "42 千克",
            note: "",
            fields: []
        )
        let note = FarmEventSnapshot(
            id: sharedID,
            entityType: .note,
            category: .note,
            occurredAt: .now,
            recordedAt: .now,
            title: "备注",
            subject: "A-001",
            detail: "观察采食",
            note: "",
            fields: []
        )

        XCTAssertNotEqual(weight.rowIdentity, note.rowIdentity)
    }

    func testTimelineIncludesFarmEventsAndSortsByOccurredAtDescending() async throws {
        let container = try AppSchema.makeContainer(name: "event-history-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let otherFarmID = UUID()
        let sheep = SheepRecord(farmID: farmID, earTag: "E001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: Date(timeIntervalSince1970: 100))
        let olderWeight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "45.2", occurredAt: Date(timeIntervalSince1970: 200))
        let newerNote = NoteRecord(farmID: farmID, sheepID: sheep.id, text: "观察采食", occurredAt: Date(timeIntervalSince1970: 300))
        let deletedNote = NoteRecord(farmID: farmID, sheepID: sheep.id, text: "已撤销", occurredAt: Date(timeIntervalSince1970: 400))
        deletedNote.deletedAt = .now
        let otherFarmNote = NoteRecord(farmID: otherFarmID, sheepID: nil, text: "其他牧场", occurredAt: Date(timeIntervalSince1970: 500))
        context.insert(sheep)
        context.insert(olderWeight)
        context.insert(newerNote)
        context.insert(deletedNote)
        context.insert(otherFarmNote)
        try context.save()

        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)

        XCTAssertEqual(events.map(\.entityType), [.note, .weight, .sheep])
        XCTAssertEqual(events.map(\.occurredAt), events.map(\.occurredAt).sorted(by: >))
        XCTAssertEqual(events.first?.subject, "E001")
        XCTAssertTrue(events.allSatisfy { $0.relatedSheepIDs == [sheep.id] })
        XCTAssertFalse(events.contains { $0.detail.contains("其他牧场") || $0.detail.contains("已撤销") })
    }

    func testHealthAndReproductionEventsRetainEveryRelatedSheepID() async throws {
        let container = try AppSchema.makeContainer(
            name: "event-related-sheep-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ewe = SheepRecord(
            farmID: farmID,
            earTag: "E001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let ram = SheepRecord(
            farmID: farmID,
            earTag: "R001",
            breed: "杜泊",
            isBreedingRam: true,
            sex: .ram,
            penID: nil,
            enteredAt: .now
        )
        let health = HealthRecord(
            farmID: farmID,
            sheepID: nil,
            penID: nil,
            kind: .vaccination,
            itemNameSnapshot: "三联四防",
            occurredAt: .now
        )
        let reproduction = ReproductionRecord(
            farmID: farmID,
            eweID: ewe.id,
            kind: .breeding,
            occurredAt: .now,
            sireID: ram.id
        )
        context.insert(ewe)
        context.insert(ram)
        context.insert(health)
        context.insert(reproduction)
        context.insert(HealthSubjectLink(
            farmID: farmID,
            healthRecordID: health.id,
            sheepID: ewe.id
        ))
        context.insert(HealthSubjectLink(
            farmID: farmID,
            healthRecordID: health.id,
            sheepID: ram.id
        ))
        try context.save()

        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        let healthEvent = try XCTUnwrap(events.first { $0.id == health.id })
        let reproductionEvent = try XCTUnwrap(events.first { $0.id == reproduction.id })

        XCTAssertEqual(Set(healthEvent.relatedSheepIDs), Set([ewe.id, ram.id]))
        XCTAssertEqual(Set(reproductionEvent.relatedSheepIDs), Set([ewe.id, ram.id]))
    }

    func testBatchDepartureAppearsAsRestorableEventUntilMembershipIsRestored() async throws {
        let container = try AppSchema.makeContainer(
            name: "event-batch-departure-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "B001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: Date(timeIntervalSince1970: 100)
        )
        let batch = ProductionBatchRecord(
            farmID: farmID,
            name: "春季育肥一批",
            purpose: "育肥",
            source: .manual,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        let membership = BatchMembershipRecord(
            farmID: farmID,
            batchID: batch.id,
            sheepID: sheep.id,
            joinedAt: batch.startedAt
        )
        let leftAt = Date(timeIntervalSince1970: 300)
        membership.leftAt = leftAt
        membership.leaveReason = "误触移出"
        membership.updatedAt = Date(timeIntervalSince1970: 301)
        context.insert(sheep)
        context.insert(batch)
        context.insert(membership)
        try context.save()

        var events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        let departure = try XCTUnwrap(events.first {
            $0.entityType == .batchMembership && $0.id == membership.id
        })
        let fields = Dictionary(uniqueKeysWithValues: departure.fields.map { ($0.label, $0.value) })
        XCTAssertEqual(departure.title, "移出批次")
        XCTAssertEqual(departure.subject, "B001")
        XCTAssertEqual(departure.occurredAt, leftAt)
        XCTAssertEqual(departure.relatedSheepIDs, [sheep.id])
        XCTAssertTrue(departure.isRestorableBatchDeparture)
        XCTAssertEqual(fields["生产批次"], "春季育肥一批")
        XCTAssertEqual(fields["移出原因"], "误触移出")

        membership.leftAt = nil
        membership.leaveReason = nil
        membership.updatedAt = Date(timeIntervalSince1970: 400)
        try context.save()

        events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        XCTAssertFalse(events.contains { $0.entityType == .batchMembership && $0.id == membership.id })
    }

    func testTimelineAndExportIncludeIndependentBirthRecord() async throws {
        let container = try AppSchema.makeContainer(name: "event-birth-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "产房")
        let dam = SheepRecord(farmID: farmID, earTag: "D001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: Date(timeIntervalSince1970: 10))
        let sire = SheepRecord(farmID: farmID, earTag: "S001", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: pen.id, enteredAt: Date(timeIntervalSince1970: 10))
        let birthAt = Date(timeIntervalSince1970: 100)
        let lamb = SheepRecord(
            farmID: farmID,
            earTag: "L001",
            breed: "湖羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: birthAt,
            birthAt: birthAt,
            damID: dam.id,
            sireID: sire.id
        )
        context.insert(pen)
        context.insert(dam)
        context.insert(sire)
        context.insert(lamb)
        try context.save()

        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        let birth = try XCTUnwrap(events.first { $0.title == "出生" && $0.subject == "L001" })
        let fields = Dictionary(uniqueKeysWithValues: birth.fields.map { ($0.label, $0.value) })

        XCTAssertEqual(birth.occurredAt, birthAt)
        XCTAssertTrue(birth.isDerived)
        XCTAssertEqual(birth.relatedSheepIDs, [lamb.id])
        XCTAssertNil(birth.editCapability)
        XCTAssertEqual(fields["初始圈舍"], "产房")
        XCTAssertEqual(fields["母本"], "D001")
        XCTAssertEqual(fields["父本来源"], "S001")
        XCTAssertTrue(FarmEventExportScope.birth.includes(birth))

        let csv = try XCTUnwrap(String(
            data: FarmEventCSVExport.csvData(events: events, scope: .birth, range: .all).dropFirst(3),
            encoding: .utf8
        ))
        XCTAssertTrue(csv.contains("\"出生\""))
        XCTAssertTrue(csv.contains("\"L001\""))
        XCTAssertTrue(csv.contains("\"出生日期\""))
        XCTAssertFalse(csv.contains("\"新建羊只\""))
    }

    func testRemovalBatchHistoryUsesOneBatchTotalWithoutPerSheepAmount() async throws {
        let container = try AppSchema.makeContainer(name: "event-removal-batch-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let batchID = UUID()
        let first = SheepRecord(farmID: farmID, earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        let second = SheepRecord(farmID: farmID, earTag: "A002", breed: "杜泊", sex: .ram, penID: nil, enteredAt: .now)
        let occurredAt = Date(timeIntervalSince1970: 300)
        context.insert(first)
        context.insert(second)
        context.insert(RemovalRecord(
            farmID: farmID,
            sheepID: first.id,
            kind: .sold,
            reason: "整批出售",
            removalBatchID: batchID,
            batchTotalAmountText: "2500",
            occurredAt: occurredAt
        ))
        context.insert(RemovalRecord(
            farmID: farmID,
            sheepID: second.id,
            kind: .sold,
            reason: "整批出售",
            removalBatchID: batchID,
            batchTotalAmountText: "2500",
            occurredAt: occurredAt
        ))
        try context.save()

        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        let removals = events.filter { $0.entityType == .removal }

        XCTAssertEqual(removals.count, 2)
        for event in removals {
            let fields = Dictionary(uniqueKeysWithValues: event.fields.map { ($0.label, $0.value) })
            XCTAssertEqual(fields["同批离场数量"], "2 只")
            XCTAssertEqual(fields["同批总售卖金额"], "2500")
            XCTAssertNil(fields["售卖金额"])
        }
    }

    func testWeaningEventContainsLambAndPedigreeExportFields() async throws {
        let container = try AppSchema.makeContainer(name: "event-weaning-export-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "羔羊一舍")
        let dam = SheepRecord(farmID: farmID, earTag: "D001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now)
        let sire = SheepRecord(farmID: farmID, earTag: "S001", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: pen.id, enteredAt: .now)
        let birthAt = Date(timeIntervalSince1970: 1_735_689_600)
        let lamb = SheepRecord(
            farmID: farmID,
            earTag: "L001",
            breed: "湖羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: birthAt,
            birthAt: birthAt,
            damID: dam.id,
            sireID: sire.id
        )
        let weaning = WeaningRecord(
            farmID: farmID,
            sheepID: lamb.id,
            occurredAt: birthAt.addingTimeInterval(60 * 86_400),
            weanWeightText: "25.5",
            birthAt: birthAt,
            birthWeightText: "3.2",
            averageDailyGainText: "0.372",
            damID: dam.id,
            litterSize: 3,
            note: "留种观察"
        )
        let gainBaseline = WeightRecord(
            farmID: farmID,
            sheepID: lamb.id,
            kilogramsText: "5.5",
            occurredAt: birthAt.addingTimeInterval(10 * 86_400),
            note: "出生后首次称重"
        )
        context.insert(pen)
        context.insert(dam)
        context.insert(sire)
        context.insert(lamb)
        context.insert(gainBaseline)
        context.insert(weaning)
        try context.save()

        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        let event = try XCTUnwrap(events.first { $0.id == weaning.id })
        let fields = Dictionary(uniqueKeysWithValues: event.fields.map { ($0.label, $0.value) })

        XCTAssertEqual(event.entityType, .weaning)
        XCTAssertEqual(event.subject, "L001")
        XCTAssertEqual(fields["耳号"], "L001")
        XCTAssertEqual(fields["当前圈舍"], "羔羊一舍")
        XCTAssertEqual(fields["断奶重kg"], "25.5")
        XCTAssertEqual(fields["出生重kg"], "3.2")
        XCTAssertEqual(fields["日增重起算体重kg"], "5.5")
        XCTAssertEqual(fields["日增重起算日期"], "2025-01-11")
        XCTAssertEqual(fields["日增重计算天数"], "50")
        XCTAssertEqual(fields["日增重kg/天"], "0.4")
        XCTAssertEqual(fields["母本"], "D001")
        XCTAssertEqual(fields["父本来源"], "S001")
        XCTAssertEqual(fields["胎只数"], "3")
    }

    @MainActor
    func testDeletingFeedEventTombstonesParentAndLinesAndCreatesAuditOutbox() throws {
        let container = try AppSchema.makeContainer(name: "event-feed-delete-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()
        let feed = FeedRecord(farmID: farmID, penID: UUID(), mode: .limited, occurredAt: .now)
        let line = FeedRecordLine(farmID: farmID, feedRecordID: feed.id, ingredientID: UUID(), kilogramsText: "12", ingredientNameSnapshot: "玉米")
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .supabase,
            authorityGeneration: 1
        ))
        context.insert(FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        ))
        context.insert(feed)
        context.insert(line)
        try context.save()

        try FarmCommandService().execute(
            .tombstoneEntity(entityType: .feed, entityID: feed.id, reason: "录入错误"),
            in: FarmContext(accountID: accountID, farmID: farmID, role: .owner),
            context: context
        )

        XCTAssertNotNil(feed.deletedAt)
        XCTAssertNotNil(line.deletedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.entityID == feed.id }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.entityID == feed.id && $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).count, 1)
    }

    @MainActor
    func testDeletingNonTimelineEventDoesNotReplayDailyHerdHistory() throws {
        let container = try AppSchema.makeContainer(name: "event-delete-no-history-replay-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "一号圈")
        let enteredAt = Date.now.addingTimeInterval(-86_400)
        let sheep = SheepRecord(farmID: farmID, earTag: "P001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: enteredAt)
        let weight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "42", occurredAt: .now)
        let marker = DailyPenCountRecord(
            farmID: farmID,
            penID: pen.id,
            purpose: sheep.purpose,
            date: Calendar.current.startOfDay(for: enteredAt),
            count: 1
        )
        context.insert(pen)
        context.insert(sheep)
        context.insert(weight)
        context.insert(marker)
        try context.save()

        try FarmCommandService().execute(
            .tombstoneEntity(entityType: .weight, entityID: weight.id, reason: "录入错误"),
            in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
            context: context
        )

        let daily = try context.fetch(FetchDescriptor<DailyPenCountRecord>()).filter { $0.farmID == farmID }
        XCTAssertEqual(daily.map(\.id), [marker.id])
        XCTAssertNotNil(weight.deletedAt)
    }

    @MainActor
    func testDeletingHistoricalRemovalAdjustsOnlyAffectedDailyCounts() throws {
        let container = try AppSchema.makeContainer(name: "event-removal-delete-incremental-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let entryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let removalDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "一号圈")
        let removedSheep = SheepRecord(
            farmID: farmID,
            earTag: "R001",
            breed: "湖羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: entryDay
        )
        let unaffectedSheep = SheepRecord(
            farmID: farmID,
            earTag: "R002",
            breed: "湖羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: entryDay
        )
        let removal = RemovalRecord(
            farmID: farmID,
            sheepID: removedSheep.id,
            kind: .sold,
            reason: "误录离场",
            occurredAt: removalDay
        )
        context.insert(pen)
        context.insert(removedSheep)
        context.insert(unaffectedSheep)
        context.insert(removal)
        try FarmHistoryRebuilder(calendar: calendar).rebuild(
            farmID: farmID,
            context: context,
            from: entryDay,
            through: today
        )
        try context.save()

        var replayedDays = [Date]()
        let service = FarmCommandService(historyRebuilder: FarmHistoryRebuilder(
            calendar: calendar,
            dailyReplayObserver: { replayedDays.append($0) }
        ))
        try service.execute(
            .tombstoneEntity(entityType: .removal, entityID: removal.id, reason: "误录离场"),
            in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
            context: context
        )

        let daily = try context.fetch(FetchDescriptor<DailyPenCountRecord>()).filter { $0.farmID == farmID }
        XCTAssertTrue(replayedDays.isEmpty)
        XCTAssertEqual(
            DailyPenCountTimeline.count(
                for: pen.id,
                purpose: removedSheep.purpose,
                at: removalDay,
                records: daily,
                calendar: calendar
            ),
            2
        )
        XCTAssertEqual(
            DailyPenCountTimeline.count(
                for: pen.id,
                purpose: removedSheep.purpose,
                at: today,
                records: daily,
                calendar: calendar
            ),
            2
        )
        XCTAssertEqual(removedSheep.status, .active)
        XCTAssertEqual(removedSheep.currentPenID, pen.id)
        XCTAssertNil(unaffectedSheep.deletedAt)
    }

    @MainActor
    func testOriginatingDeviceDeletingMigratedRemovalReleasesLegacySnapshotAuthority() throws {
        let container = try AppSchema.makeContainer(
            name: "event-migrated-removal-delete-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let entryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let removalDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let farmID = UUID()
        let pen = PenRecord(farmID: farmID, name: "迁移前圈舍")
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "U41018",
            breed: "湖羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: entryDay
        )
        sheep.statusRawValue = SheepStatus.deceased.rawValue
        sheep.currentPenID = nil
        sheep.removedAt = removalDay
        sheep.legacyStatusSnapshotIsAuthoritative = true
        sheep.legacyPenSnapshotIsAuthoritative = true
        let removal = RemovalRecord(
            farmID: farmID,
            sheepID: sheep.id,
            kind: .deceased,
            reason: "误录死亡",
            occurredAt: removalDay
        )
        context.insert(pen)
        context.insert(sheep)
        context.insert(removal)
        try FarmHistoryRebuilder(calendar: calendar).rebuild(
            farmID: farmID,
            context: context,
            from: entryDay,
            through: today
        )
        try context.save()

        XCTAssertEqual(sheep.status, .deceased)
        XCTAssertEqual(sheep.legacyStatusSnapshotIsAuthoritative, true)

        try FarmCommandService().execute(
            .tombstoneEntity(entityType: .removal, entityID: removal.id, reason: "录入错误"),
            in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
            context: context
        )

        XCTAssertNotNil(removal.deletedAt)
        XCTAssertEqual(sheep.status, .active)
        XCTAssertEqual(sheep.currentPenID, pen.id)
        XCTAssertNil(sheep.removedAt)
        XCTAssertEqual(sheep.legacyStatusSnapshotIsAuthoritative, false)
        XCTAssertEqual(sheep.legacyPenSnapshotIsAuthoritative, false)
    }

    @MainActor
    func testDeletingHistoricalTransferPreservesLaterTimelineWithoutFullReplay() throws {
        let container = try AppSchema.makeContainer(name: "event-transfer-delete-incremental-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let entryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: today))
        let firstTransferDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let secondTransferDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let farmID = UUID()
        let firstPen = PenRecord(farmID: farmID, name: "一号圈")
        let secondPen = PenRecord(farmID: farmID, name: "二号圈")
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "T001",
            breed: "湖羊",
            sex: .ewe,
            penID: firstPen.id,
            enteredAt: entryDay
        )
        let deletedTransfer = TransferRecord(
            farmID: farmID,
            sheepID: sheep.id,
            fromPenID: firstPen.id,
            toPenID: secondPen.id,
            occurredAt: firstTransferDay
        )
        let laterTransfer = TransferRecord(
            farmID: farmID,
            sheepID: sheep.id,
            fromPenID: secondPen.id,
            toPenID: firstPen.id,
            occurredAt: secondTransferDay
        )
        context.insert(firstPen)
        context.insert(secondPen)
        context.insert(sheep)
        context.insert(deletedTransfer)
        context.insert(laterTransfer)
        try FarmHistoryRebuilder(calendar: calendar).rebuild(
            farmID: farmID,
            context: context,
            from: entryDay,
            through: today
        )
        try context.save()

        var replayedDays = [Date]()
        let service = FarmCommandService(historyRebuilder: FarmHistoryRebuilder(
            calendar: calendar,
            dailyReplayObserver: { replayedDays.append($0) }
        ))
        try service.execute(
            .tombstoneEntity(entityType: .transfer, entityID: deletedTransfer.id, reason: "误录调栏"),
            in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
            context: context
        )

        let daily = try context.fetch(FetchDescriptor<DailyPenCountRecord>()).filter { $0.farmID == farmID }
        XCTAssertTrue(replayedDays.isEmpty)
        XCTAssertEqual(
            DailyPenCountTimeline.count(
                for: firstPen.id,
                purpose: sheep.purpose,
                at: firstTransferDay,
                records: daily,
                calendar: calendar
            ),
            1
        )
        XCTAssertEqual(
            DailyPenCountTimeline.count(
                for: secondPen.id,
                purpose: sheep.purpose,
                at: firstTransferDay,
                records: daily,
                calendar: calendar
            ),
            0
        )
        XCTAssertEqual(sheep.currentPenID, firstPen.id)
        XCTAssertNil(laterTransfer.deletedAt)
    }

    @MainActor
    func testDeletingInventoryReceiptCannotCreateNegativeBalance() throws {
        let container = try AppSchema.makeContainer(name: "event-inventory-delete-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let lot = InventoryLotRecord(farmID: farmID, catalogName: "疫苗", kind: .vaccination, startingQuantityText: "10")
        let receipt = InventoryTransactionRecord(farmID: farmID, inventoryLotID: lot.id, kind: .receipt, quantityText: "10", occurredAt: .now)
        let consumption = InventoryTransactionRecord(farmID: farmID, inventoryLotID: lot.id, kind: .consumption, quantityText: "8", occurredAt: .now)
        context.insert(lot)
        context.insert(receipt)
        context.insert(consumption)
        try context.save()

        XCTAssertThrowsError(
            try FarmCommandService().execute(
                .tombstoneEntity(entityType: .inventoryTransaction, entityID: receipt.id, reason: "误入库"),
                in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
                context: context
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.insufficientInventory.localizedDescription)
        }
        XCTAssertNil(receipt.deletedAt)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TombstoneRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutboxItem>()).isEmpty)
    }

    @MainActor
    func testDeletingSheepCreationIsRejectedWhenProductionFactsExist() throws {
        let container = try AppSchema.makeContainer(name: "event-sheep-delete-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let sheep = SheepRecord(farmID: farmID, earTag: "E002", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        let weight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "40", occurredAt: .now)
        context.insert(sheep)
        context.insert(weight)
        try context.save()

        XCTAssertThrowsError(
            try FarmCommandService().execute(
                .tombstoneEntity(entityType: .sheep, entityID: sheep.id, reason: "误建档"),
                in: FarmContext(accountID: UUID(), farmID: farmID, role: .owner),
                context: context
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.protectedSheepReferences.localizedDescription)
        }
        XCTAssertNil(sheep.deletedAt)
        XCTAssertNil(weight.deletedAt)
    }

    @MainActor
    func testHistoryDeletionRoutesLambingThroughSafeRevokeCommand() throws {
        let container = try AppSchema.makeContainer(name: "event-lambing-delete-route-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let record = ReproductionRecord(
            farmID: farmID,
            eweID: UUID(),
            kind: .lambing,
            occurredAt: .now,
            lambCount: 1,
            parity: 1,
            birthDeadCount: 0
        )
        context.insert(record)
        try context.save()
        let event = FarmEventSnapshot(
            id: record.id,
            entityType: .reproduction,
            category: .reproduction,
            occurredAt: record.occurredAt,
            recordedAt: record.createdAt,
            title: record.kind.displayName,
            subject: "E001",
            detail: "产羔 1 只",
            note: "",
            fields: []
        )

        let command = try FarmEventDeletionCommandResolver.command(
            for: event,
            reason: "重复录入",
            farmID: farmID,
            context: context
        )

        guard case .care(.revokeLambing(let recordID, let reason)) = command else {
            return XCTFail("产羔事件必须走安全撤销命令")
        }
        XCTAssertEqual(recordID, record.id)
        XCTAssertEqual(reason, "事件记录删除：重复录入")
    }

    @MainActor
    func testHistoryDeletionKeepsOrdinaryFactsOnTombstoneCommand() throws {
        let container = try AppSchema.makeContainer(name: "event-weight-delete-route-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let eventID = UUID()
        let event = FarmEventSnapshot(
            id: eventID,
            entityType: .weight,
            category: .herd,
            occurredAt: .now,
            recordedAt: .now,
            title: "称重",
            subject: "E001",
            detail: "42 kg",
            note: "",
            fields: []
        )

        let command = try FarmEventDeletionCommandResolver.command(
            for: event,
            reason: "录入错误",
            farmID: farmID,
            context: context
        )

        guard case .tombstoneEntity(let entityType, let entityID, let reason) = command else {
            return XCTFail("普通历史事实必须继续走 tombstone 命令")
        }
        XCTAssertEqual(entityType, .weight)
        XCTAssertEqual(entityID, eventID)
        XCTAssertEqual(reason, "事件记录删除：录入错误")
    }
}
