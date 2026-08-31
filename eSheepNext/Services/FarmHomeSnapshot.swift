import Foundation
import SwiftData

struct FarmHomeSnapshot: Sendable, Equatable {
    let activeSheepCount: Int
    let occupiedPenCount: Int
    let todayFeedCount: Int
    let activeHealthRecordCount: Int
    let pendingOutboxCount: Int
    let conflictOutboxCount: Int

    static let empty = FarmHomeSnapshot(
        activeSheepCount: 0,
        occupiedPenCount: 0,
        todayFeedCount: 0,
        activeHealthRecordCount: 0,
        pendingOutboxCount: 0,
        conflictOutboxCount: 0
    )
}

/// Reads only the counters needed by the home screen off the SwiftUI render
/// path. The home view used to keep several live, farm-wide @Query collections;
/// opening the tab therefore faulted and sorted historical feed/health data on
/// the main actor even though the screen only displayed summary counts.
actor FarmHomeSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        farmID: UUID,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> FarmHomeSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let startOfToday = calendar.startOfDay(for: now)
        let todayFeedCount = try context.fetchCount(FetchDescriptor<FeedRecord>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.deletedAt == nil &&
                $0.occurredAt >= startOfToday
        }))
        let activeHealthRecordCount = try context.fetchCount(FetchDescriptor<HealthRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let pending = OutboxStatus.pending.rawValue
        let uploading = OutboxStatus.uploading.rawValue
        let awaitingConfirmation = OutboxStatus.awaitingConfirmation.rawValue
        let retryable = OutboxStatus.retryableFailure.rawValue
        let pendingOutboxCount = try context.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID &&
                ($0.statusRawValue == pending ||
                    $0.statusRawValue == uploading ||
                    $0.statusRawValue == awaitingConfirmation ||
                    $0.statusRawValue == retryable)
        }))
        let blocked = OutboxStatus.blockedConflict.rawValue
        let rejected = OutboxStatus.rejectedPermission.rawValue
        let conflictOutboxCount = try context.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID &&
                ($0.statusRawValue == blocked || $0.statusRawValue == rejected)
        }))
        try Task.checkCancellation()

        let activeSheep = sheep.filter(\.isCurrentlyPresent)
        let occupiedPenIDs = Set(activeSheep.compactMap(\.currentPenID))
        return FarmHomeSnapshot(
            activeSheepCount: activeSheep.count,
            occupiedPenCount: pens.count { occupiedPenIDs.contains($0.id) },
            todayFeedCount: todayFeedCount,
            activeHealthRecordCount: activeHealthRecordCount,
            pendingOutboxCount: pendingOutboxCount,
            conflictOutboxCount: conflictOutboxCount
        )
    }
}

struct TodayFeedRowSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let penName: String
    let occurredAt: Date
    let mealName: String
    let mode: FeedMode
    let ingredientCount: Int
    let note: String
}

/// Keeps the home metric destination from faulting every historical feed,
/// feed line and pen into a live SwiftUI query just to render today's rows.
actor TodayFeedSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        farmID: UUID,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> [TodayFeedRowSnapshot] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let startOfToday = calendar.startOfDay(for: now)
        let feeds = try context.fetch(FetchDescriptor<FeedRecord>(
            predicate: #Predicate {
                $0.farmID == farmID &&
                    $0.deletedAt == nil &&
                    $0.occurredAt >= startOfToday
            },
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        ))
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        try Task.checkCancellation()

        var lineCountByFeedID: [UUID: Int] = [:]
        lineCountByFeedID.reserveCapacity(feeds.count)
        for feed in feeds {
            let feedID = feed.id
            lineCountByFeedID[feedID] = try context.fetchCount(FetchDescriptor<FeedRecordLine>(predicate: #Predicate {
                $0.farmID == farmID &&
                    $0.feedRecordID == feedID &&
                    $0.deletedAt == nil
            }))
        }
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        return feeds.map { feed in
            let meal = feed.mealName.trimmingCharacters(in: .whitespacesAndNewlines)
            return TodayFeedRowSnapshot(
                id: feed.id,
                penName: penNames[feed.penID] ?? "已删除圈舍",
                occurredAt: feed.occurredAt,
                mealName: meal,
                mode: feed.mode,
                ingredientCount: lineCountByFeedID[feed.id, default: 0],
                note: feed.note
            )
        }
    }
}
