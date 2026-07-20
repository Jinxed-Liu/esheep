import Foundation
import SwiftData

enum FarmHistoryTimeline {
    static func pen(
        for sheep: SheepRecord,
        at instant: Date,
        transfers: [TransferRecord]
    ) -> UUID? {
        guard sheep.enteredAt <= instant else { return nil }
        let relevant = transfers
            .filter { $0.sheepID == sheep.id && $0.deletedAt == nil && $0.occurredAt <= instant }
            .sorted { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        return relevant.last?.toPenID ?? sheep.initialPenID
    }

    static func removal(for sheepID: UUID, at instant: Date, removals: [RemovalRecord]) -> RemovalRecord? {
        removals
            .filter { $0.sheepID == sheepID && $0.deletedAt == nil && $0.occurredAt <= instant }
            .sorted { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }
}

/// `DailyPenCountRecord` is stored as a change-point snapshot rather than a
/// duplicated row for every untouched calendar day.  Callers that need an
/// end-of-day value must carry the latest snapshot forward.
enum DailyPenCountTimeline {
    static func count(
        for penID: UUID,
        purpose: String,
        at instant: Date,
        records: [DailyPenCountRecord],
        calendar: Calendar = .current
    ) -> Int {
        let day = calendar.startOfDay(for: instant)
        return records
            .filter {
                $0.penID == penID
                    && $0.purpose == purpose
                    && $0.date <= day
            }
            .max { lhs, rhs in lhs.date < rhs.date }?
            .count ?? 0
    }
}

final class FarmHistoryRebuilder {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func rebuild(farmID: UUID, context: ModelContext, from changedAt: Date? = nil, through endDate: Date = .now) throws {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let batches = try context.fetch(FetchDescriptor<ProductionBatchRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }

        for item in sheep {
            let removal = FarmHistoryTimeline.removal(for: item.id, at: endDate, removals: removals)
            let reconstructedStatus = removal?.kind.resultingStatus ?? .active
            let projectedStatus: SheepStatus
            if item.isHistoricalArchive {
                projectedStatus = .removed
            } else if item.legacyStatusSnapshotIsAuthoritative == true {
                projectedStatus = item.status
            } else {
                projectedStatus = reconstructedStatus
            }
            let reconstructedPen = reconstructedStatus == .active
                ? FarmHistoryTimeline.pen(for: item, at: endDate, transfers: transfers)
                : nil
            let projectedPen: UUID?
            if projectedStatus != .active || item.isHistoricalArchive {
                projectedPen = nil
            } else if item.legacyPenSnapshotIsAuthoritative == true {
                projectedPen = item.currentPenID
            } else {
                projectedPen = reconstructedPen
            }
            let projectedRemovedAt: Date?
            if item.isHistoricalArchive {
                projectedRemovedAt = item.removedAt
            } else if item.legacyStatusSnapshotIsAuthoritative == true {
                projectedRemovedAt = projectedStatus == .active ? nil : (removal?.occurredAt ?? item.removedAt)
            } else {
                projectedRemovedAt = removal?.occurredAt
            }

            if item.status != projectedStatus || item.currentPenID != projectedPen || item.removedAt != projectedRemovedAt {
                item.statusRawValue = projectedStatus.rawValue
                item.currentPenID = projectedPen
                item.removedAt = projectedRemovedAt
                item.updatedAt = .now
                item.revision += 1
            }

            // Keep the persisted projection safe even when a future data path
            // changes status separately from currentPenID.
            if !item.isCurrentlyPresent, item.currentPenID != nil {
                item.currentPenID = nil
                item.updatedAt = .now
                item.revision += 1
            }

        }

        // 批次生命周期与羊只是否离场无关。只有用户明确将成员脱离批次，成员关系才结束；
        // 最后一位成员的手工脱离时间就是批次归档时间。
        for batch in batches where batch.sourceRawValue == ProductionBatchSource.manual.rawValue {
            try ProductionBatchLifecycle.reconcile(batchID: batch.id, farmID: farmID, context: context)
        }

        // `.distantPast` is a storage sentinel for an unknown legacy entry
        // time, not a real farm event. Starting a day-by-day rebuild from it
        // would create centuries of derived records and leave migration
        // spinning indefinitely. A full rebuild still clears old derived
        // snapshots, but begins replay at the oldest *known* fact.
        let effectiveChangedAt = changedAt.flatMap { isKnownTimelineDate($0) ? $0 : nil }
        let knownTimelineDates = sheep.map(\.enteredAt).filter(isKnownTimelineDate)
            + transfers.map(\.occurredAt).filter(isKnownTimelineDate)
            + removals.map(\.occurredAt).filter(isKnownTimelineDate)
        let firstRelevantDate = effectiveChangedAt ?? knownTimelineDates.min() ?? endDate
        let knownDailyPenKeys = try rebuildDailyPenCounts(
            farmID: farmID,
            sheep: sheep,
            transfers: transfers,
            removals: removals,
            from: firstRelevantDate,
            through: endDate,
            clearsUnprovableEarlierHistory: changedAt == nil || effectiveChangedAt == nil,
            context: context
        )
        try rebuildCurrentDaySnapshot(
            farmID: farmID,
            sheep: sheep,
            at: endDate,
            knownPenPurposeKeys: knownDailyPenKeys,
            context: context
        )
    }

    private func rebuildCurrentDaySnapshot(
        farmID: UUID,
        sheep: [SheepRecord],
        at instant: Date,
        knownPenPurposeKeys: Set<DailyPenCountKey>,
        context: ModelContext
    ) throws {
        let day = calendar.startOfDay(for: instant)
        let existing = try context.fetch(FetchDescriptor<DailyPenCountRecord>())
            .filter { $0.farmID == farmID && $0.date == day }
        for item in existing { context.delete(item) }

        var counts: [DailyPenCountKey: Int] = [:]
        for item in sheep where item.isCurrentlyPresent {
            guard let penID = item.currentPenID else { continue }
            counts[DailyPenCountKey(penID: penID, purpose: item.purpose), default: 0] += 1
        }

        // The current-day snapshot is authoritative for legacy imports whose
        // saved status or pen is newer than their incomplete event timeline.
        // Write zeroes for known historical keys too, so a carried-forward
        // query cannot resurrect an animal removed earlier today.
        let snapshotKeys = knownPenPurposeKeys.union(counts.keys)
        for key in snapshotKeys {
            let count = counts[key, default: 0]
            context.insert(DailyPenCountRecord(farmID: farmID, penID: key.penID, purpose: key.purpose, date: day, count: count))
        }
    }

    private func rebuildDailyPenCounts(
        farmID: UUID,
        sheep: [SheepRecord],
        transfers: [TransferRecord],
        removals: [RemovalRecord],
        from start: Date,
        through end: Date,
        clearsUnprovableEarlierHistory: Bool,
        context: ModelContext
    ) throws -> Set<DailyPenCountKey> {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard startDay <= endDay else { return [] }

        let existing = try context.fetch(FetchDescriptor<DailyPenCountRecord>())
            .filter {
                $0.farmID == farmID
                    && $0.date <= endDay
                    && (clearsUnprovableEarlierHistory || $0.date >= startDay)
            }
        for item in existing { context.delete(item) }

        // A full historical rebuild used to write a row for every active pen,
        // every day. The user's real export expanded to 214,860 derived rows,
        // making the SwiftData save look like a never-ending migration. Store
        // only end-of-day changes, then carry the latest snapshot forward when
        // reading a historical count. This keeps the same history while making
        // rebuild cost proportional to real entry/transfer/removal facts.
        let orderedSheep = sheep.sorted { $0.enteredAt < $1.enteredAt }
        let orderedTransfers = transfers.sorted { lhs, rhs in
            lhs.occurredAt == rhs.occurredAt ? lhs.recordedAt < rhs.recordedAt : lhs.occurredAt < rhs.occurredAt
        }
        let orderedRemovals = removals.sorted { lhs, rhs in
            lhs.occurredAt == rhs.occurredAt ? lhs.recordedAt < rhs.recordedAt : lhs.occurredAt < rhs.occurredAt
        }
        let sheepByID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        var latestTransfer: [UUID: TransferRecord] = [:]
        var activePens: [UUID: UUID] = [:]
        var activeCounts: [DailyPenCountKey: Int] = [:]
        var knownKeys = Set<DailyPenCountKey>()
        var removedSheep = Set<UUID>()
        var sheepIndex = 0
        var transferIndex = 0
        var removalIndex = 0
        var day = startDay

        func replaceActivePen(
            for sheepID: UUID,
            with newPenID: UUID?,
            changedKeys: inout Set<DailyPenCountKey>
        ) {
            guard let sheep = sheepByID[sheepID] else { return }
            let oldPenID = activePens[sheepID]
            guard oldPenID != newPenID else { return }

            if let oldPenID {
                let oldKey = DailyPenCountKey(penID: oldPenID, purpose: sheep.purpose)
                activeCounts[oldKey, default: 0] -= 1
                knownKeys.insert(oldKey)
                changedKeys.insert(oldKey)
            }
            if let newPenID {
                let newKey = DailyPenCountKey(penID: newPenID, purpose: sheep.purpose)
                activeCounts[newKey, default: 0] += 1
                knownKeys.insert(newKey)
                changedKeys.insert(newKey)
                activePens[sheepID] = newPenID
            } else {
                activePens.removeValue(forKey: sheepID)
            }
        }

        while day <= endDay {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let snapshotInstant = nextDay.addingTimeInterval(-0.001)
            var changedKeys = Set<DailyPenCountKey>()

            while transferIndex < orderedTransfers.count, orderedTransfers[transferIndex].occurredAt <= snapshotInstant {
                let transfer = orderedTransfers[transferIndex]
                latestTransfer[transfer.sheepID] = transfer
                if activePens[transfer.sheepID] != nil {
                    replaceActivePen(for: transfer.sheepID, with: transfer.toPenID, changedKeys: &changedKeys)
                }
                transferIndex += 1
            }
            while removalIndex < orderedRemovals.count, orderedRemovals[removalIndex].occurredAt <= snapshotInstant {
                let removal = orderedRemovals[removalIndex]
                removedSheep.insert(removal.sheepID)
                replaceActivePen(for: removal.sheepID, with: nil, changedKeys: &changedKeys)
                removalIndex += 1
            }
            while sheepIndex < orderedSheep.count, orderedSheep[sheepIndex].enteredAt <= snapshotInstant {
                let item = orderedSheep[sheepIndex]
                if !removedSheep.contains(item.id), let penID = latestTransfer[item.id]?.toPenID ?? item.initialPenID {
                    replaceActivePen(for: item.id, with: penID, changedKeys: &changedKeys)
                }
                sheepIndex += 1
            }

            for key in changedKeys {
                let count = activeCounts[key, default: 0]
                context.insert(DailyPenCountRecord(farmID: farmID, penID: key.penID, purpose: key.purpose, date: day, count: count))
            }
            day = nextDay
        }

        return knownKeys
    }

    private func isKnownTimelineDate(_ date: Date) -> Bool {
        date > .distantPast
    }
}

private struct DailyPenCountKey: Hashable {
    let penID: UUID
    let purpose: String
}
