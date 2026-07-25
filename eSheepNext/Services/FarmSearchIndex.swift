import Foundation
import SwiftData

enum SearchText {
    private static let locale = Locale(identifier: "zh_Hans_CN")

    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
    }
}

struct FarmSearchSheepEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let earTag: String
    let breed: String
    let statusName: String
    let penName: String?
    let normalizedEarTag: String
    let normalizedBreed: String

    init(
        id: UUID,
        earTag: String,
        breed: String,
        statusName: String,
        penName: String?
    ) {
        self.id = id
        self.earTag = earTag
        self.breed = breed
        self.statusName = statusName
        self.penName = penName
        normalizedEarTag = SearchText.normalized(earTag)
        normalizedBreed = SearchText.normalized(breed)
    }
}

struct FarmSearchPenEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let normalizedName: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
        normalizedName = SearchText.normalized(name)
    }
}

struct FarmSearchSource: Equatable, Sendable {
    let sheep: [FarmSearchSheepEntry]
    let pens: [FarmSearchPenEntry]

    static let empty = FarmSearchSource(sheep: [], pens: [])
}

struct FarmSearchResultSet: Equatable, Sendable {
    let sheep: [FarmSearchSheepEntry]
    let pens: [FarmSearchPenEntry]
    let totalSheepCount: Int
    let totalPenCount: Int

    static let empty = FarmSearchResultSet(
        sheep: [],
        pens: [],
        totalSheepCount: 0,
        totalPenCount: 0
    )

    var isEmpty: Bool { sheep.isEmpty && pens.isEmpty }
    var hasMoreSheep: Bool { totalSheepCount > sheep.count }
    var hasMorePens: Bool { totalPenCount > pens.count }
}

enum FarmSearchEngine {
    static let defaultLimit = 50

    static func search(
        query: String,
        source: FarmSearchSource,
        limit: Int = defaultLimit
    ) -> FarmSearchResultSet {
        let normalizedQuery = SearchText.normalized(query)
        guard !normalizedQuery.isEmpty else { return .empty }

        let sheepMatches = source.sheep.compactMap { entry -> (FarmSearchSheepEntry, Int)? in
            if entry.normalizedEarTag == normalizedQuery { return (entry, 0) }
            if entry.normalizedEarTag.hasPrefix(normalizedQuery) { return (entry, 1) }
            if entry.normalizedEarTag.contains(normalizedQuery) { return (entry, 2) }
            if entry.normalizedBreed.hasPrefix(normalizedQuery) { return (entry, 3) }
            if entry.normalizedBreed.contains(normalizedQuery) { return (entry, 4) }
            return nil
        }
        let penMatches = source.pens.compactMap { entry -> (FarmSearchPenEntry, Int)? in
            if entry.normalizedName == normalizedQuery { return (entry, 0) }
            if entry.normalizedName.hasPrefix(normalizedQuery) { return (entry, 1) }
            if entry.normalizedName.contains(normalizedQuery) { return (entry, 2) }
            return nil
        }
        let boundedLimit = max(0, limit)

        return FarmSearchResultSet(
            sheep: sheepMatches
                .sorted(by: compareSheepMatches)
                .prefix(boundedLimit)
                .map(\.0),
            pens: penMatches
                .sorted(by: comparePenMatches)
                .prefix(boundedLimit)
                .map(\.0),
            totalSheepCount: sheepMatches.count,
            totalPenCount: penMatches.count
        )
    }

    private static func compareSheepMatches(
        _ lhs: (FarmSearchSheepEntry, Int),
        _ rhs: (FarmSearchSheepEntry, Int)
    ) -> Bool {
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        let order = lhs.0.earTag.localizedStandardCompare(rhs.0.earTag)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.0.id.uuidString < rhs.0.id.uuidString
    }

    private static func comparePenMatches(
        _ lhs: (FarmSearchPenEntry, Int),
        _ rhs: (FarmSearchPenEntry, Int)
    ) -> Bool {
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        let order = lhs.0.name.localizedStandardCompare(rhs.0.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.0.id.uuidString < rhs.0.id.uuidString
    }
}

actor FarmSearchIndexActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID) throws -> FarmSearchSource {
        let context = ModelContext(container)
        let pens = try context.fetch(FetchDescriptor<PenRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.name)]
        ))
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.earTag)]
        ))
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })

        return FarmSearchSource(
            sheep: sheep.map {
                FarmSearchSheepEntry(
                    id: $0.id,
                    earTag: $0.earTag,
                    breed: $0.breed,
                    statusName: $0.status.displayName,
                    penName: $0.currentPenID.flatMap { penNames[$0] }
                )
            },
            pens: pens.map { FarmSearchPenEntry(id: $0.id, name: $0.name) }
        )
    }
}
