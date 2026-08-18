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
    let avatarPhoto: SheepPhotoReference?
    let normalizedEarTag: String
    let normalizedBreed: String

    init(
        id: UUID,
        earTag: String,
        breed: String,
        statusName: String,
        penName: String?,
        avatarPhoto: SheepPhotoReference? = nil
    ) {
        self.id = id
        self.earTag = earTag
        self.breed = breed
        self.statusName = statusName
        self.penName = penName
        self.avatarPhoto = avatarPhoto
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
            sheep: topSheepMatches(sheepMatches, limit: boundedLimit),
            pens: topPenMatches(penMatches, limit: boundedLimit),
            totalSheepCount: sheepMatches.count,
            totalPenCount: penMatches.count
        )
    }

    /// Keep only the rows that can be rendered. A full sort of every matching
    /// sheep was unnecessary once the result limit was capped at 50 and made
    /// typing in a large farm search O(n log n) on every debounced query.
    private static func topSheepMatches(
        _ matches: [(FarmSearchSheepEntry, Int)],
        limit: Int
    ) -> [FarmSearchSheepEntry] {
        guard limit > 0 else { return [] }
        var top: [(FarmSearchSheepEntry, Int)] = []
        top.reserveCapacity(min(limit, matches.count))
        for match in matches {
            let insertionIndex = top.firstIndex { compareSheepMatches(match, $0) } ?? top.endIndex
            guard insertionIndex < limit else { continue }
            top.insert(match, at: insertionIndex)
            if top.count > limit { top.removeLast() }
        }
        return top.map(\.0)
    }

    private static func topPenMatches(
        _ matches: [(FarmSearchPenEntry, Int)],
        limit: Int
    ) -> [FarmSearchPenEntry] {
        guard limit > 0 else { return [] }
        var top: [(FarmSearchPenEntry, Int)] = []
        top.reserveCapacity(min(limit, matches.count))
        for match in matches {
            let insertionIndex = top.firstIndex { comparePenMatches(match, $0) } ?? top.endIndex
            guard insertionIndex < limit else { continue }
            top.insert(match, at: insertionIndex)
            if top.count > limit { top.removeLast() }
        }
        return top.map(\.0)
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
        let avatarPhotos = try SheepAvatarSelectionStore.references(
            farmID: farmID,
            context: context
        )

        return FarmSearchSource(
            sheep: sheep.map {
                FarmSearchSheepEntry(
                    id: $0.id,
                    earTag: $0.earTag,
                    breed: $0.breed,
                    statusName: $0.status.displayName,
                    penName: $0.currentPenID.flatMap { penNames[$0] },
                    avatarPhoto: avatarPhotos[$0.id]
                )
            },
            pens: pens.map { FarmSearchPenEntry(id: $0.id, name: $0.name) }
        )
    }
}
