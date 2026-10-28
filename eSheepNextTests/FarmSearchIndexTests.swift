import SwiftData
import XCTest
@testable import eSheepNext

final class FarmSearchIndexTests: XCTestCase {
    func testEmptyQueryDoesNotReturnTheWholeFarm() {
        let source = FarmSearchSource(
            sheep: [sheep("A001", breed: "湖羊", 1)],
            pens: [pen("育肥一舍", 2)]
        )

        let result = FarmSearchEngine.search(query: "   ", source: source)

        XCTAssertEqual(result, .empty)
    }

    func testSearchNormalizesAndRanksEarTagBeforeBreed() {
        let source = FarmSearchSource(
            sheep: [
                sheep("B001", breed: "A01品种", 1),
                sheep("XA01", breed: "湖羊", 2),
                sheep("A010", breed: "湖羊", 3),
                sheep("A01", breed: "湖羊", 4)
            ],
            pens: []
        )

        let result = FarmSearchEngine.search(query: " a01 ", source: source)

        XCTAssertEqual(result.sheep.map(\.earTag), ["A01", "A010", "XA01", "B001"])
    }

    func testSearchSupportsCanonicalAndWidthInsensitiveText() {
        let source = FarmSearchSource(
            sheep: [sheep("Ｅ\u{301}０１", breed: "测试", 1)],
            pens: [pen("育肥１舍", 2)]
        )

        XCTAssertEqual(
            FarmSearchEngine.search(query: "é01", source: source).sheep.map(\.earTag),
            ["Ｅ\u{301}０１"]
        )
        XCTAssertEqual(
            FarmSearchEngine.search(query: "1舍", source: source).pens.map(\.name),
            ["育肥１舍"]
        )
    }

    func testSearchCapsRenderedRowsButPreservesTotalCounts() {
        let source = FarmSearchSource(
            sheep: (1...1_000).map { sheep("A\($0)", breed: "湖羊", $0) },
            pens: (1...100).map { pen("A圈舍\($0)", 2_000 + $0) }
        )

        let result = FarmSearchEngine.search(query: "A", source: source, limit: 20)

        XCTAssertEqual(result.sheep.count, 20)
        XCTAssertEqual(result.totalSheepCount, 1_000)
        XCTAssertTrue(result.hasMoreSheep)
        XCTAssertEqual(result.pens.count, 20)
        XCTAssertEqual(result.totalPenCount, 100)
        XCTAssertTrue(result.hasMorePens)
    }

    func testSearchFindsLateBestMatchesAndUsesIDsForNaturalOrderTies() {
        let source = FarmSearchSource(
            sheep: [
                sheep("B1", breed: "A01品种", 9),
                sheep("XA01", breed: "湖羊", 8),
                sheep("A010", breed: "湖羊", 7),
                sheep("A01", breed: "湖羊", 4),
                sheep("A01", breed: "湖羊", 3)
            ],
            pens: [pen("XA01", 8), pen("A010", 7), pen("A01", 4), pen("A01", 3)]
        )

        for values in [source, FarmSearchSource(sheep: Array(source.sheep.reversed()), pens: Array(source.pens.reversed()))] {
            let result = FarmSearchEngine.search(query: "A01", source: values, limit: 2)
            XCTAssertEqual(result.sheep.map(\.id), [uuid(3), uuid(4)])
            XCTAssertEqual(result.pens.map(\.id), [uuid(3), uuid(4)])
            XCTAssertEqual(result.totalSheepCount, 5)
            XCTAssertEqual(result.totalPenCount, 4)
        }
    }

    func testZeroAndNegativeLimitsStillCountMatches() {
        let source = FarmSearchSource(
            sheep: [sheep("A1", breed: "湖羊", 1), sheep("B1", breed: "湖羊", 2)],
            pens: [pen("A圈舍", 3)]
        )
        for limit in [-1, 0] {
            let result = FarmSearchEngine.search(query: "A", source: source, limit: limit)
            XCTAssertTrue(result.sheep.isEmpty)
            XCTAssertTrue(result.pens.isEmpty)
            XCTAssertEqual(result.totalSheepCount, 1)
            XCTAssertEqual(result.totalPenCount, 1)
        }
        XCTAssertEqual(FarmSearchEngine.search(query: "A", source: source, limit: Int.max).sheep.count, 1)
    }

    @MainActor
    func testIndexLoadsSelectedAvatarAndLeavesUnselectedSheepOnDefault() async throws {
        let container = try AppSchema.makeContainer(
            name: "search-avatar-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let selectedSheep = SheepRecord(
            farmID: farmID,
            earTag: "A001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let defaultSheep = SheepRecord(
            farmID: farmID,
            earTag: "A002",
            breed: "湖羊",
            sex: .ram,
            penID: nil,
            enteredAt: .now
        )
        let photo = PhotoAssetRecord(
            farmID: farmID,
            sheepID: selectedSheep.id,
            legacySourceKey: "test:search-avatar",
            originalEarTag: selectedSheep.earTag,
            relativePath: "Assets/search-avatar.jpg",
            sha256: "search-avatar-digest"
        )
        context.insert(selectedSheep)
        context.insert(defaultSheep)
        context.insert(photo)
        context.insert(SheepAvatarRecord(
            farmID: farmID,
            sheepID: selectedSheep.id,
            photoAssetID: photo.id
        ))
        try context.save()

        let source = try await FarmSearchIndexActor(container: container).load(farmID: farmID)
        let selectedEntry = try XCTUnwrap(source.sheep.first { $0.id == selectedSheep.id })
        let defaultEntry = try XCTUnwrap(source.sheep.first { $0.id == defaultSheep.id })

        XCTAssertEqual(
            selectedEntry.avatarPhoto,
            SheepPhotoReference(id: photo.id, digest: photo.sha256)
        )
        XCTAssertNil(defaultEntry.avatarPhoto)
    }

    func testAllEventScopesParticipateAndKeepCompositeIdentity() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let events = FarmEventExportScope.shortcuts.filter { $0 != .all }.enumerated().map { index, scope in
            FarmSearchEventEntry(event: FarmEventSnapshot(id: uuid(index + 1), entityType: .note,
                category: .note, occurredAt: date, recordedAt: date,
                title: scope.displayName, subject: "SEARCH-MARKER", detail: "", note: "", fields: [], recordScope: scope))
        }
        let source = FarmSearchSource(sheep: [], pens: [], events: events)
        XCTAssertEqual(FarmSearchEngine.search(query: "search-marker", source: source).totalEventCount, events.count)
        for event in events {
            XCTAssertTrue(FarmSearchEngine.search(query: event.event.title, source: source).events.contains { $0.id == event.id })
        }
        let weight = FarmEventSnapshot(id: uuid(1), entityType: .weight, category: .herd,
            occurredAt: date, recordedAt: date, title: "称重", subject: "SEARCH-MARKER", detail: "", note: "", fields: [])
        let duplicateIDSource = FarmSearchSource(sheep: [], pens: [], events: [events[0], .init(event: weight)])
        XCTAssertEqual(Set(FarmSearchEngine.search(query: "SEARCH-MARKER", source: duplicateIDSource).events.map(\.id)).count, 2)
    }

    func testEventRankingTokensNotesAndPagination() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ number: Int, title: String, date: Date) -> FarmSearchEventEntry {
            .init(event: FarmEventSnapshot(id: uuid(number), entityType: .weight, category: .herd,
                occurredAt: date, recordedAt: date, title: title, subject: "A026", detail: "32 kg",
                note: "复称 Café", fields: []))
        }
        let source = FarmSearchSource(sheep: [], pens: [], events: [
            event(1, title: "称重", date: old), event(2, title: "称重", date: old.addingTimeInterval(100)),
            event(3, title: "批量称重", date: old.addingTimeInterval(200))])
        let ranked = FarmSearchEngine.search(query: "称重", source: source, limit: 1)
        XCTAssertEqual(ranked.events.map(\.event.id), [uuid(2)])
        XCTAssertEqual(ranked.totalEventCount, 3)
        XCTAssertTrue(ranked.hasMoreEvents)
        XCTAssertEqual(ranked.preferredCategory, .events)
        XCTAssertEqual(FarmSearchEngine.search(query: "a026 CAFE", source: source).totalEventCount, 3)
        XCTAssertEqual(FarmSearchEngine.search(query: "称重", source: source, limit: 3).events.map(\.event.id), [uuid(2), uuid(1), uuid(3)])
        XCTAssertEqual(FarmSearchEngine.search(query: "A026 不存在", source: source).totalEventCount, 0)
        for limit in [0, -1] {
            let result = FarmSearchEngine.search(query: "称重", source: source, limit: limit)
            XCTAssertEqual(result.totalEventCount, 3)
            XCTAssertTrue(result.events.isEmpty)
        }
    }

    func testEventFiltersIncludeWholeEndDayAndDoNotFilterSheep() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let events = [start, end.addingTimeInterval(-1), end].enumerated().map { index, date in
            FarmSearchEventEntry(event: FarmEventSnapshot(id: uuid(index + 1), entityType: .weight, category: .herd,
                occurredAt: date, recordedAt: date, title: "称重", subject: "A026", detail: "", note: "", fields: []))
        }
        let source = FarmSearchSource(sheep: [sheep("A026", breed: "湖羊", 10)], pens: [], events: events)
        let result = FarmSearchEngine.search(query: "A026", source: source, eventScope: .weight,
            eventRange: .days(from: start, through: start))
        XCTAssertEqual(Set(result.events.map(\.event.id)), [uuid(1), uuid(2)])
        XCTAssertEqual(result.totalSheepCount, 1)
        XCTAssertEqual(FarmSearchEngine.search(query: "A026", source: source, eventScope: .feed).totalEventCount, 0)
    }

    @MainActor
    func testFarmIsolationPenOccupancyLegacyTagsAndHistoricalLocations() async throws {
        let container = try AppSchema.makeContainer(name: "universal-search-\(UUID())", isStoredInMemoryOnly: true)
        let context = ModelContext(container), farmID = UUID(), otherFarmID = UUID()
        let oldPen = PenRecord(farmID: farmID, name: "原羊舍")
        let newPen = PenRecord(farmID: farmID, name: "当前六舍")
        let sheep = SheepRecord(farmID: farmID, earTag: "NEW-026", legacyEarTag: "OLD-026", breed: "湖羊", sex: .ewe,
            penID: oldPen.id, enteredAt: Date(timeIntervalSince1970: 100))
        sheep.currentPenID = newPen.id
        let departed = SheepRecord(farmID: farmID, earTag: "SOLD-001", breed: "湖羊", sex: .ram,
            penID: newPen.id, enteredAt: .now)
        departed.statusRawValue = SheepStatus.removed.rawValue
        let historical = SheepRecord(farmID: farmID, earTag: "ARCHIVE-001", isHistoricalArchive: true,
            breed: "湖羊", sex: .ewe, penID: newPen.id, enteredAt: .now)
        let deleted = SheepRecord(farmID: farmID, earTag: "DELETED", breed: "湖羊", sex: .ewe, penID: newPen.id, enteredAt: .now)
        deleted.deletedAt = .now
        let weight = WeightRecord(farmID: farmID, sheepID: sheep.id, kilogramsText: "32", occurredAt: .now)
        let transfer = TransferRecord(farmID: farmID, sheepID: sheep.id, fromPenID: oldPen.id, toPenID: newPen.id, occurredAt: .now)
        let note = NoteRecord(farmID: farmID, sheepID: sheep.id, penID: oldPen.id, text: "关联原羊舍", occurredAt: .now)
        let tombstone = NoteRecord(farmID: farmID, sheepID: sheep.id, text: "DELETED-NOTE", occurredAt: .now)
        tombstone.deletedAt = .now
        let foreign = NoteRecord(farmID: otherFarmID, sheepID: nil, text: "FOREIGN-NOTE", occurredAt: .now)
        context.insert(oldPen); context.insert(newPen); context.insert(sheep); context.insert(departed)
        context.insert(historical); context.insert(deleted); context.insert(weight); context.insert(transfer)
        context.insert(note); context.insert(tombstone); context.insert(foreign)
        try context.save()
        let source = try await FarmSearchIndexActor(container: container).load(farmID: farmID)
        let history = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        XCTAssertEqual(Set(source.events.map(\.id)), Set(history.map(\.rowIdentity)))
        XCTAssertFalse(source.sheep.contains { $0.id == deleted.id })
        XCTAssertEqual(source.sheep.first { $0.id == historical.id }?.statusName, "历史档案")
        XCTAssertEqual(source.pens.first { $0.id == newPen.id }?.sheepCount, 1)
        XCTAssertEqual(source.pens.first { $0.id == oldPen.id }?.sheepCount, 0)
        let penResult = FarmSearchEngine.search(query: "当前六舍", source: source)
        XCTAssertEqual(penResult.preferredCategory, .pens)
        XCTAssertEqual(penResult.sheep.map(\.id), [sheep.id])
        // Departure removes current occupancy, not the factual admission into this pen.
        XCTAssertEqual(Set(penResult.events.map(\.event.id)), [transfer.id, departed.id])
        XCTAssertFalse(penResult.events.contains { $0.event.id == weight.id })
        XCTAssertFalse(FarmSearchEngine.search(query: "原羊舍", source: source).events.contains { $0.event.id == weight.id })
        let legacy = FarmSearchEngine.search(query: "old-026", source: source)
        XCTAssertEqual(legacy.sheep.map(\.id), [sheep.id])
        XCTAssertTrue(legacy.events.contains { $0.event.id == weight.id })
        XCTAssertEqual(legacy.preferredCategory, .sheep)
        XCTAssertEqual(FarmSearchEngine.search(query: "SOLD-001", source: source).totalSheepCount, 1)
        XCTAssertEqual(FarmSearchEngine.search(query: "FOREIGN-NOTE", source: source).totalEventCount, 0)
        XCTAssertEqual(FarmSearchEngine.search(query: "DELETED-NOTE", source: source).totalEventCount, 0)
        weight.deletedAt = .now
        try context.save()
        let refreshed = try await FarmSearchIndexActor(container: container).load(farmID: farmID)
        XCTAssertFalse(refreshed.events.contains { $0.event.id == weight.id })
    }

    func testCurrentProfilePenIsNotAnEventLocation() {
        let event = FarmEventSnapshot(id: UUID(), entityType: .weaning, category: .herd,
            occurredAt: .now, recordedAt: .now, title: "断奶", subject: "A026", detail: "32 kg", note: "",
            fields: [.init(label: "当前圈舍", value: "新羊舍"), .init(label: "初始圈舍", value: "入场羊舍")])
        let source = FarmSearchSource(sheep: [], pens: [], events: [.init(event: event)])
        XCTAssertEqual(FarmSearchEngine.search(query: "新羊舍", source: source).totalEventCount, 0)
        XCTAssertEqual(FarmSearchEngine.search(query: "入场羊舍", source: source).totalEventCount, 0)
        XCTAssertEqual(FarmSearchEngine.search(query: "断奶", source: source).totalEventCount, 1)
    }

    private func sheep(
        _ earTag: String,
        breed: String,
        _ suffix: Int
    ) -> FarmSearchSheepEntry {
        FarmSearchSheepEntry(
            id: uuid(suffix),
            earTag: earTag,
            breed: breed,
            statusName: "在场",
            penName: nil
        )
    }

    private func pen(_ name: String, _ suffix: Int) -> FarmSearchPenEntry {
        FarmSearchPenEntry(id: uuid(suffix), name: name)
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
