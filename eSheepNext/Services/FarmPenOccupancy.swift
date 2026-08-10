import Foundation
import SwiftData

actor FarmPenOccupancyReadActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func sheepIDsByPen(farmID: UUID, at instant: Date) throws -> [UUID: Set<UUID>] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt <= instant
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        return FarmPenOccupancyIndex.make(
            farmID: farmID,
            sheep: sheep,
            transfers: transfers,
            removals: removals
        ).sheepIDsByPen(at: instant)
    }
}

struct FeedPenEligibleSheepSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let earTag: String
}

struct FeedPenEligibilityReadSnapshot: Sendable, Hashable {
    let sheepByPen: [UUID: [FeedPenEligibleSheepSnapshot]]
    let recommendedExcludedSheepIDs: Set<UUID>
}

actor FeedPenEligibilityReadActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID, on date: Date, calendar: Calendar = .current) throws -> FeedPenEligibilityReadSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let weanings = try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        let resolved = FeedPenEligibility.sheepByPen(
            on: date,
            sheep: sheep,
            transfers: transfers,
            removals: removals,
            calendar: calendar
        ).mapValues { values in
            values.map { FeedPenEligibleSheepSnapshot(id: $0.id, earTag: $0.earTag) }
        }
        let recommended = FeedExclusionRecommendation.nursingLambIDs(
            on: date,
            sheep: sheep,
            weanings: weanings,
            calendar: calendar
        )
        try Task.checkCancellation()
        return FeedPenEligibilityReadSnapshot(
            sheepByPen: resolved,
            recommendedExcludedSheepIDs: recommended
        )
    }
}

struct FarmPenOccupancySheepSnapshot: Sendable, Hashable {
    let id: UUID
    let initialPenID: UUID?
    let enteredAt: Date
    let removedAt: Date?
    let isCurrentlyPresent: Bool
}

struct FarmPenOccupancyTransferSnapshot: Sendable, Hashable {
    let id: UUID
    let sheepID: UUID
    let toPenID: UUID?
    let occurredAt: Date
    let recordedAt: Date
}

struct FarmPenOccupancyRemovalSnapshot: Sendable, Hashable {
    let id: UUID
    let sheepID: UUID
    let occurredAt: Date
    let recordedAt: Date
}

struct FarmPenOccupancyDailyCountSnapshot: Sendable, Hashable {
    let id: UUID
    let penID: UUID
    let purpose: String
    let date: Date
    let count: Int
    let rebuiltAt: Date
}

/// Resolves which pens have sheep at an exact fact time or during a historical interval.
///
/// Identity facts use half-open intervals: a sheep belongs to its destination at the exact
/// transfer time and no longer belongs to a pen at the exact removal time. Whole-day analysis
/// may additionally use positive `DailyPenCountRecord` change points as legacy evidence.
struct FarmPenOccupancyIndex: Sendable {
    private struct DailyKey: Hashable {
        let penID: UUID
        let purpose: String
        let day: Date
    }

    private struct PenPurposeKey: Hashable {
        let penID: UUID
        let purpose: String
    }

    private let sheep: [FarmPenOccupancySheepSnapshot]
    private let transfersBySheep: [UUID: [FarmPenOccupancyTransferSnapshot]]
    private let removalBySheep: [UUID: Date]
    private let dailyCounts: [FarmPenOccupancyDailyCountSnapshot]

    init(
        sheep: [FarmPenOccupancySheepSnapshot],
        transfers: [FarmPenOccupancyTransferSnapshot] = [],
        removals: [FarmPenOccupancyRemovalSnapshot] = [],
        dailyCounts: [FarmPenOccupancyDailyCountSnapshot] = []
    ) {
        self.sheep = sheep
        transfersBySheep = Dictionary(grouping: transfers, by: \FarmPenOccupancyTransferSnapshot.sheepID)
            .mapValues { values in
                values.sorted { lhs, rhs in
                    if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                    if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
        var earliestRemoval: [UUID: Date] = [:]
        for removal in removals {
            if earliestRemoval[removal.sheepID].map({ removal.occurredAt < $0 }) ?? true {
                earliestRemoval[removal.sheepID] = removal.occurredAt
            }
        }
        removalBySheep = earliestRemoval
        self.dailyCounts = dailyCounts
    }

    static func make(
        farmID: UUID,
        sheep: [SheepRecord],
        transfers: [TransferRecord],
        removals: [RemovalRecord],
        dailyPenCounts: [DailyPenCountRecord] = []
    ) -> FarmPenOccupancyIndex {
        FarmPenOccupancyIndex(
            sheep: sheep.compactMap { item in
                guard item.farmID == farmID, item.deletedAt == nil else { return nil }
                return FarmPenOccupancySheepSnapshot(
                    id: item.id,
                    initialPenID: item.initialPenID,
                    enteredAt: item.enteredAt,
                    removedAt: item.removedAt,
                    isCurrentlyPresent: item.isCurrentlyPresent
                )
            },
            transfers: transfers.compactMap { item in
                guard item.farmID == farmID, item.deletedAt == nil else { return nil }
                return FarmPenOccupancyTransferSnapshot(
                    id: item.id,
                    sheepID: item.sheepID,
                    toPenID: item.toPenID,
                    occurredAt: item.occurredAt,
                    recordedAt: item.recordedAt
                )
            },
            removals: removals.compactMap { item in
                guard item.farmID == farmID, item.deletedAt == nil else { return nil }
                return FarmPenOccupancyRemovalSnapshot(
                    id: item.id,
                    sheepID: item.sheepID,
                    occurredAt: item.occurredAt,
                    recordedAt: item.recordedAt
                )
            },
            dailyCounts: dailyPenCounts.compactMap { item in
                guard item.farmID == farmID else { return nil }
                return FarmPenOccupancyDailyCountSnapshot(
                    id: item.id,
                    penID: item.penID,
                    purpose: item.purpose,
                    date: item.date,
                    count: item.count,
                    rebuiltAt: item.rebuiltAt
                )
            }
        )
    }

    func sheepIDsByPen(at instant: Date) -> [UUID: Set<UUID>] {
        var result: [UUID: Set<UUID>] = [:]
        for item in sheep where isPresent(item, at: instant) {
            guard let penID = pen(for: item, at: instant) else { continue }
            result[penID, default: []].insert(item.id)
        }
        return result
    }

    func sheepIDs(in penID: UUID, at instant: Date) -> Set<UUID> {
        sheepIDsByPen(at: instant)[penID, default: []]
    }

    func occupiedPenIDs(at instant: Date) -> Set<UUID> {
        Set(sheepIDsByPen(at: instant).keys)
    }

    /// Returns every pen with a positive-duration occupancy segment in `[start, end)`.
    func occupiedPenIDs(from start: Date, to end: Date) -> Set<UUID> {
        guard start < end else { return [] }
        var result = Set<UUID>()
        for item in sheep where hasProvablePresence(item) {
            let removal = effectiveRemoval(for: item) ?? .distantFuture
            let segmentStart = max(start, item.enteredAt)
            let segmentEnd = min(end, removal)
            guard segmentStart < segmentEnd else { continue }

            let transfers = transfersBySheep[item.id] ?? []
            var currentPen = transfers.last(where: { $0.occurredAt <= segmentStart })?.toPenID ?? item.initialPenID
            var currentStart = segmentStart
            let groupedTransfers = Dictionary(
                grouping: transfers.filter { $0.occurredAt > segmentStart && $0.occurredAt < segmentEnd },
                by: \FarmPenOccupancyTransferSnapshot.occurredAt
            )
            for transferTime in groupedTransfers.keys.sorted() {
                if transferTime > currentStart, let currentPen { result.insert(currentPen) }
                currentPen = groupedTransfers[transferTime]?.last?.toPenID
                currentStart = transferTime
            }
            if segmentEnd > currentStart, let currentPen { result.insert(currentPen) }
        }
        return result
    }

    /// Whole-day analytics can recover legacy occupied pens from authoritative count change points.
    func occupiedPenIDsDuringWholeDays(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) -> Set<UUID> {
        var result = occupiedPenIDs(from: start, to: end)
        guard start < end, !dailyCounts.isEmpty else { return result }
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard startDay < endDay else { return result }

        var latestByKeyAndDay: [DailyKey: FarmPenOccupancyDailyCountSnapshot] = [:]
        for item in dailyCounts {
            let key = DailyKey(penID: item.penID, purpose: item.purpose, day: calendar.startOfDay(for: item.date))
            if let existing = latestByKeyAndDay[key] {
                if dailyCountOccursBefore(existing, item) {
                    latestByKeyAndDay[key] = item
                }
            } else {
                latestByKeyAndDay[key] = item
            }
        }
        let grouped = Dictionary(grouping: latestByKeyAndDay) { entry in
            PenPurposeKey(penID: entry.key.penID, purpose: entry.key.purpose)
        }
        for (key, entries) in grouped {
            let ordered = entries.sorted { lhs, rhs in lhs.key.day < rhs.key.day }
            if ordered.last(where: { $0.key.day <= startDay })?.value.count ?? 0 > 0 {
                result.insert(key.penID)
                continue
            }
            if ordered.contains(where: { $0.key.day > startDay && $0.key.day < endDay && $0.value.count > 0 }) {
                result.insert(key.penID)
            }
        }
        return result
    }

    private func hasProvablePresence(_ item: FarmPenOccupancySheepSnapshot) -> Bool {
        item.isCurrentlyPresent || effectiveRemoval(for: item) != nil
    }

    private func isPresent(_ item: FarmPenOccupancySheepSnapshot, at instant: Date) -> Bool {
        guard hasProvablePresence(item), item.enteredAt <= instant else { return false }
        return effectiveRemoval(for: item).map { $0 > instant } ?? true
    }

    private func effectiveRemoval(for item: FarmPenOccupancySheepSnapshot) -> Date? {
        [item.removedAt, removalBySheep[item.id]].compactMap { $0 }.min()
    }

    private func pen(for item: FarmPenOccupancySheepSnapshot, at instant: Date) -> UUID? {
        transfersBySheep[item.id]?.last(where: { $0.occurredAt <= instant })?.toPenID ?? item.initialPenID
    }

    private func dailyCountOccursBefore(
        _ lhs: FarmPenOccupancyDailyCountSnapshot,
        _ rhs: FarmPenOccupancyDailyCountSnapshot
    ) -> Bool {
        if lhs.rebuiltAt != rhs.rebuiltAt { return lhs.rebuiltAt < rhs.rebuiltAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
