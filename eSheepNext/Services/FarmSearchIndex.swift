import Foundation
import SwiftData

enum SearchText {
    private static let locale = Locale(identifier: "zh_Hans_CN")

    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }
}

enum FarmSearchCategory: String, CaseIterable, Identifiable, Sendable {
    case all, sheep, pens, events
    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .sheep: String(localized: "羊只")
        case .pens: String(localized: "羊舍")
        case .events: String(localized: "事件")
        }
    }
}

struct FarmSearchSheepEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let earTag: String
    let breed: String
    let statusName: String
    let penName: String?
    let avatarPhoto: SheepPhotoReference?
    let sex: SheepSex
    let legacyEarTag: String?
    let normalizedEarTag: String
    let normalizedBreed: String
    let normalizedLegacyEarTag: String
    let normalizedPenName: String

    init(id: UUID, earTag: String, breed: String, statusName: String, penName: String?,
         avatarPhoto: SheepPhotoReference? = nil, sex: SheepSex = .unknown, legacyEarTag: String? = nil) {
        self.id = id
        self.earTag = earTag
        self.breed = breed
        self.statusName = statusName
        self.penName = penName
        self.avatarPhoto = avatarPhoto
        self.sex = sex
        self.legacyEarTag = legacyEarTag
        normalizedEarTag = SearchText.normalized(earTag)
        normalizedBreed = SearchText.normalized(breed)
        normalizedLegacyEarTag = SearchText.normalized(legacyEarTag ?? "")
        normalizedPenName = SearchText.normalized(penName ?? "")
    }
}

struct FarmSearchPenEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let normalizedName: String
    let eweCount: Int
    let ramCount: Int
    let unknownCount: Int
    var sheepCount: Int { eweCount + ramCount + unknownCount }

    init(id: UUID, name: String, eweCount: Int = 0, ramCount: Int = 0, unknownCount: Int = 0) {
        self.id = id
        self.name = name
        normalizedName = SearchText.normalized(name)
        self.eweCount = eweCount
        self.ramCount = ramCount
        self.unknownCount = unknownCount
    }
}

struct FarmSearchEventEntry: Identifiable, Equatable, Sendable {
    let event: FarmEventSnapshot
    let normalizedTitle: String
    let normalizedSubject: String
    let normalizedNote: String
    let searchableText: String
    var id: FarmEventRowIdentity { event.rowIdentity }

    init(event: FarmEventSnapshot, relatedEarTags: [String] = [], penNames: [String] = [], timeZone: TimeZone = .current, occurredOn: String? = nil) {
        self.event = event
        normalizedTitle = SearchText.normalized(event.title)
        normalizedSubject = SearchText.normalized(event.subject)
        normalizedNote = SearchText.normalized(event.note)
        let dateText: String
        if let occurredOn { dateText = occurredOn }
        else {
            let date = DateFormatter()
            date.calendar = Calendar(identifier: .gregorian)
            date.locale = Locale(identifier: "en_US_POSIX")
            date.timeZone = timeZone
            date.dateFormat = "yyyy-MM-dd"
            dateText = date.string(from: event.occurredAt)
        }
        let scopeNames = FarmEventExportScope.allCases
            .filter { $0 != .all && $0.includes(event) }.map(\.displayName)
        var terms = [event.universalSearchableText, event.category.displayName, dateText]
        terms += relatedEarTags + penNames + scopeNames
        if event.entityType == .transfer { terms += ["调舍", "转舍", "调群"] }
        if event.entityType == .weight { terms += ["体重"] }
        if event.entityType == .feed { terms += ["饲喂"] }
        searchableText = SearchText.normalized(terms.joined(separator: " "))
    }
}

struct FarmSearchSource: Equatable, Sendable {
    let sheep: [FarmSearchSheepEntry]
    let pens: [FarmSearchPenEntry]
    var events: [FarmSearchEventEntry] = []
    var timeZoneIdentifier: String = TimeZone.current.identifier
    static let empty = FarmSearchSource(sheep: [], pens: [])
}

struct FarmSearchResultSet: Equatable, Sendable {
    let sheep: [FarmSearchSheepEntry]
    let pens: [FarmSearchPenEntry]
    let totalSheepCount: Int
    let totalPenCount: Int
    var events: [FarmSearchEventEntry] = []
    var totalEventCount: Int = 0
    var preferredCategory: FarmSearchCategory = .sheep

    static let empty = FarmSearchResultSet(sheep: [], pens: [], totalSheepCount: 0, totalPenCount: 0)
    var isEmpty: Bool { totalSheepCount + totalPenCount + totalEventCount == 0 }
    var hasMoreSheep: Bool { totalSheepCount > sheep.count }
    var hasMorePens: Bool { totalPenCount > pens.count }
    var hasMoreEvents: Bool { totalEventCount > events.count }
    var orderedCategories: [FarmSearchCategory] {
        [preferredCategory] + [.sheep, .pens, .events].filter { $0 != preferredCategory }
    }
    func count(for category: FarmSearchCategory) -> Int {
        switch category {
        case .all: totalSheepCount + totalPenCount + totalEventCount
        case .sheep: totalSheepCount
        case .pens: totalPenCount
        case .events: totalEventCount
        }
    }
}

enum FarmSearchEngine {
    static let defaultLimit = 50

    static func search(query: String, source: FarmSearchSource, limit: Int = defaultLimit,
                       eventScope: FarmEventExportScope = .all,
                       eventRange: FarmEventExportRange = .all) -> FarmSearchResultSet {
        let query = SearchText.normalized(query)
        guard !query.isEmpty else { return .empty }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var sheepMatches = BoundedSearchMatches<(FarmSearchSheepEntry, Int)>(limit: limit, candidateCount: source.sheep.count)
        var totalSheepCount = 0
        var exactSheep = false
        for entry in source.sheep {
            if Task.isCancelled { return .empty }
            guard let rank = sheepMatchRank(entry, terms: terms) else { continue }
            totalSheepCount += 1
            exactSheep = exactSheep || entry.normalizedEarTag == query || entry.normalizedLegacyEarTag == query
            sheepMatches.insert((entry, rank), by: compareSheepMatches)
        }
        var penMatches = BoundedSearchMatches<(FarmSearchPenEntry, Int)>(limit: limit, candidateCount: source.pens.count)
        var totalPenCount = 0
        for entry in source.pens {
            if Task.isCancelled { return .empty }
            guard terms.allSatisfy({ entry.normalizedName.contains($0) }) else { continue }
            let rank = entry.normalizedName == query ? 0 : (entry.normalizedName.hasPrefix(query) ? 1 : 2)
            totalPenCount += 1
            penMatches.insert((entry, rank), by: comparePenMatches)
        }
        var eventMatches = BoundedSearchMatches<(FarmSearchEventEntry, Int)>(limit: limit, candidateCount: source.events.count)
        var totalEventCount = 0
        let interval: Range<Date>?
        if case .days(let from, let through) = eventRange {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: source.timeZoneIdentifier) ?? .current
            let start = calendar.startOfDay(for: min(from, through))
            let end = calendar.startOfDay(for: max(from, through))
            interval = calendar.date(byAdding: .day, value: 1, to: end).map { start..<$0 }
        } else { interval = nil }
        for entry in source.events {
            if Task.isCancelled { return .empty }
            guard eventScope.includes(entry.event),
                  interval.map({ $0.contains(entry.event.occurredAt) }) ?? true,
                  terms.allSatisfy({ entry.searchableText.contains($0) }) else { continue }
            let rank = entry.normalizedTitle == query || entry.normalizedSubject == query ? 0 : 1
            totalEventCount += 1
            eventMatches.insert((entry, rank), by: compareEventMatches)
        }
        return FarmSearchResultSet(
            sheep: sheepMatches.values.map(\.0), pens: penMatches.values.map(\.0),
            totalSheepCount: totalSheepCount, totalPenCount: totalPenCount,
            events: eventMatches.values.map(\.0), totalEventCount: totalEventCount,
            preferredCategory: exactSheep ? .sheep : (totalPenCount > 0 ? .pens : (totalSheepCount > 0 ? .sheep : .events))
        )
    }

    private static func sheepMatchRank(_ entry: FarmSearchSheepEntry, terms: [String]) -> Int? {
        let ranks = terms.compactMap { term -> Int? in
            if entry.normalizedEarTag == term { return 0 }
            if entry.normalizedEarTag.hasPrefix(term) { return 1 }
            if entry.normalizedEarTag.contains(term) { return 2 }
            if entry.normalizedLegacyEarTag.contains(term) { return 3 }
            if entry.normalizedBreed.hasPrefix(term) { return 4 }
            if entry.normalizedBreed.contains(term) { return 5 }
            if entry.normalizedPenName.contains(term) { return 6 }
            return nil
        }
        return ranks.count == terms.count ? ranks.reduce(0, +) : nil
    }

    private static func compareSheepMatches(_ lhs: (FarmSearchSheepEntry, Int), _ rhs: (FarmSearchSheepEntry, Int)) -> Bool {
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        let order = lhs.0.earTag.localizedStandardCompare(rhs.0.earTag)
        return order == .orderedSame ? lhs.0.id.uuidString < rhs.0.id.uuidString : order == .orderedAscending
    }

    private static func comparePenMatches(_ lhs: (FarmSearchPenEntry, Int), _ rhs: (FarmSearchPenEntry, Int)) -> Bool {
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        let order = lhs.0.name.localizedStandardCompare(rhs.0.name)
        return order == .orderedSame ? lhs.0.id.uuidString < rhs.0.id.uuidString : order == .orderedAscending
    }

    private static func compareEventMatches(_ lhs: (FarmSearchEventEntry, Int), _ rhs: (FarmSearchEventEntry, Int)) -> Bool {
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        if lhs.0.event.occurredAt != rhs.0.event.occurredAt { return lhs.0.event.occurredAt > rhs.0.event.occurredAt }
        if lhs.0.event.recordedAt != rhs.0.event.recordedAt { return lhs.0.event.recordedAt > rhs.0.event.recordedAt }
        if lhs.0.id.entityType != rhs.0.id.entityType { return lhs.0.id.entityType < rhs.0.id.entityType }
        return lhs.0.event.id.uuidString < rhs.0.event.id.uuidString
    }
}

actor FarmSearchIndexActor {
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    func load(farmID: UUID) async throws -> FarmSearchSource {
        let context = ModelContext(container)
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }, sortBy: [SortDescriptor(\.name)]))
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }, sortBy: [SortDescriptor(\.earTag)]))
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        let sheepTags = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, [$0.earTag, $0.legacyEarTag ?? ""]) })
        let occupants = Dictionary(grouping: sheep.filter { $0.status == .active && !$0.isHistoricalArchive }, by: \.currentPenID)
        let avatarPhotos = try SheepAvatarSelectionStore.references(farmID: farmID, context: context)
        let farms = try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate { $0.id == farmID }))
        let timeZone = farms.first.flatMap { TimeZone(identifier: $0.timeZoneIdentifier) } ?? .current
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        // All event kinds come from the same factual projection used by event history.
        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        try Task.checkCancellation()
        return FarmSearchSource(
            sheep: sheep.map {
                FarmSearchSheepEntry(id: $0.id, earTag: $0.earTag, breed: $0.breed,
                    statusName: $0.isHistoricalArchive ? "历史档案" : $0.status.displayName,
                    penName: $0.status == .active && !$0.isHistoricalArchive ? $0.currentPenID.flatMap { penNames[$0] } : nil,
                    avatarPhoto: avatarPhotos[$0.id], sex: $0.sex, legacyEarTag: $0.legacyEarTag)
            },
            pens: pens.map { pen in
                let members = occupants[pen.id] ?? []
                return FarmSearchPenEntry(id: pen.id, name: pen.name,
                    eweCount: members.filter { $0.sex == .ewe }.count,
                    ramCount: members.filter { $0.sex == .ram }.count,
                    unknownCount: members.filter { $0.sex == .unknown }.count)
            },
            events: events.map { event in
                FarmSearchEventEntry(event: event,
                    relatedEarTags: event.relatedSheepIDs.flatMap { sheepTags[$0] ?? [] },
                    penNames: event.relatedPenIDs.compactMap { penNames[$0] }, timeZone: timeZone,
                    occurredOn: dateFormatter.string(from: event.occurredAt))
            },
            timeZoneIdentifier: timeZone.identifier
        )
    }
}
