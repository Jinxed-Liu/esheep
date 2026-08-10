import Foundation
import SwiftData

struct FeedingOverviewSnapshot: Sendable, Hashable {
    let todayFeedCount: Int
    let todayKilograms: Double
    let pendingTroughCount: Int

    static let empty = FeedingOverviewSnapshot(
        todayFeedCount: 0,
        todayKilograms: 0,
        pendingTroughCount: 0
    )
}

private struct FeedLocationSnapshotKey: Hashable {
    let penID: UUID
    let feederName: String

    init(penID: UUID, feederName: String) {
        self.penID = penID
        self.feederName = feederName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// Prepares the feeding landing-page counters away from the main actor. In
/// particular, pending trough checks are reduced to one pass over feeds and
/// observations instead of scanning every observation once per feeder.
actor FeedingOverviewSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        farmID: UUID,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> FeedingOverviewSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let startOfToday = calendar.startOfDay(for: now)

        let feeds = try context.fetch(FetchDescriptor<FeedRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\FeedRecord.occurredAt, order: .reverse)]
        ))
        let lines = try context.fetch(FetchDescriptor<FeedRecordLine>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let observations = try context.fetch(FetchDescriptor<FeedTroughObservationRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\FeedTroughObservationRecord.observedAt, order: .reverse)]
        ))
        try Task.checkCancellation()

        let todayFeeds = feeds.filter { $0.occurredAt >= startOfToday }
        let todayFeedIDs = Set(todayFeeds.map(\.id))
        let todayKilograms = lines.lazy
            .filter { todayFeedIDs.contains($0.feedRecordID) }
            .reduce(0) { $0 + NSDecimalNumber(decimal: $1.kilograms).doubleValue }

        var latestFreeChoiceFeedByLocation: [FeedLocationSnapshotKey: Date] = [:]
        for feed in feeds where feed.mode == .freeChoice {
            let key = FeedLocationSnapshotKey(penID: feed.penID, feederName: feed.feederName)
            if latestFreeChoiceFeedByLocation[key] == nil {
                latestFreeChoiceFeedByLocation[key] = feed.occurredAt
            }
        }
        var latestObservationByLocation: [FeedLocationSnapshotKey: Date] = [:]
        for observation in observations {
            let key = FeedLocationSnapshotKey(
                penID: observation.penID,
                feederName: observation.feederName
            )
            if latestObservationByLocation[key] == nil {
                latestObservationByLocation[key] = observation.observedAt
            }
        }
        let pendingTroughCount = latestFreeChoiceFeedByLocation.count { key, feedDate in
            latestObservationByLocation[key].map { $0 < feedDate } ?? true
        }

        try Task.checkCancellation()
        return FeedingOverviewSnapshot(
            todayFeedCount: todayFeeds.count,
            todayKilograms: todayKilograms,
            pendingTroughCount: pendingTroughCount
        )
    }
}

struct FeedHistoryFeedSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let penName: String
    let modeName: String
    let mealName: String
    let lineCount: Int
    let kilogramsText: String
    let feederName: String
    let scaleFactorText: String?
    let excludedSheepCount: Int
    let occurredAt: Date
}

struct FeedHistoryTroughSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let penName: String
    let feederName: String
    let actualRemainingKilogramsText: String
    let discardedKilogramsText: String
    let measurementMethodName: String
    let observedAt: Date
}

struct FeedHistoryScreenSnapshot: Sendable, Hashable {
    let feeds: [FeedHistoryFeedSnapshot]
    let troughs: [FeedHistoryTroughSnapshot]

    static let empty = FeedHistoryScreenSnapshot(feeds: [], troughs: [])
}

/// Builds immutable history rows in linear time on a private actor. This avoids
/// an O(feed count x line count) scan during every SwiftUI body evaluation.
actor FeedHistorySnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID) throws -> FeedHistoryScreenSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let feeds = try context.fetch(FetchDescriptor<FeedRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\FeedRecord.occurredAt, order: .reverse)]
        ))
        let lines = try context.fetch(FetchDescriptor<FeedRecordLine>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let troughs = try context.fetch(FetchDescriptor<FeedTroughObservationRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\FeedTroughObservationRecord.observedAt, order: .reverse)]
        ))
        try Task.checkCancellation()

        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        var lineCountByFeedID: [UUID: Int] = [:]
        var kilogramsByFeedID: [UUID: Decimal] = [:]
        for line in lines {
            lineCountByFeedID[line.feedRecordID, default: 0] += 1
            kilogramsByFeedID[line.feedRecordID, default: 0] += line.kilograms
        }
        let feedRows = feeds.map { feed in
            FeedHistoryFeedSnapshot(
                id: feed.id,
                penName: penNames[feed.penID] ?? "已删除圈舍",
                modeName: feed.mode.displayName,
                mealName: feed.mealName,
                lineCount: lineCountByFeedID[feed.id, default: 0],
                kilogramsText: kilogramsByFeedID[feed.id, default: 0].stableText,
                feederName: feed.feederName,
                scaleFactorText: feed.scaleFactorText,
                excludedSheepCount: feed.excludedSheepIDs.count,
                occurredAt: feed.occurredAt
            )
        }
        let troughRows = troughs.map { trough in
            FeedHistoryTroughSnapshot(
                id: trough.id,
                penName: penNames[trough.penID] ?? "已删除圈舍",
                feederName: trough.feederName,
                actualRemainingKilogramsText: trough.actualRemainingKilogramsText,
                discardedKilogramsText: trough.discardedKilogramsText ?? "0",
                measurementMethodName: trough.measurementMethod.displayName,
                observedAt: trough.observedAt
            )
        }
        try Task.checkCancellation()
        return FeedHistoryScreenSnapshot(feeds: feedRows, troughs: troughRows)
    }
}
