import Foundation
import SwiftData

struct FarmHistoryDeletion: Sendable {
    let entityType: CloudEntityType
    let entityID: UUID
}

enum FarmHistoryTimeline {
    private static func transferOccursBefore(_ lhs: TransferRecord, _ rhs: TransferRecord) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func removalOccursBefore(_ lhs: RemovalRecord, _ rhs: RemovalRecord) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func pen(
        for sheep: SheepRecord,
        at instant: Date,
        transfers: [TransferRecord]
    ) -> UUID? {
        guard sheep.enteredAt <= instant else { return nil }
        let latest = transfers
            .filter { $0.sheepID == sheep.id && $0.deletedAt == nil && $0.occurredAt <= instant }
            .max(by: transferOccursBefore)
        return latest?.toPenID ?? sheep.initialPenID
    }

    static func removal(for sheepID: UUID, at instant: Date, removals: [RemovalRecord]) -> RemovalRecord? {
        removals
            .filter { $0.sheepID == sheepID && $0.deletedAt == nil && $0.occurredAt <= instant }
            .min(by: removalOccursBefore)
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
    private let dailyReplayObserver: ((Date) -> Void)?

    init(
        calendar: Calendar = .current,
        dailyReplayObserver: ((Date) -> Void)? = nil
    ) {
        self.calendar = calendar
        self.dailyReplayObserver = dailyReplayObserver
    }

    func rebuild(farmID: UUID, context: ModelContext, from changedAt: Date? = nil, through endDate: Date = .now) throws {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let batches = try context.fetch(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let transfersBySheepID = Dictionary(grouping: transfers, by: \.sheepID)
        let removalsBySheepID = Dictionary(grouping: removals, by: \.sheepID)
        let membershipsByBatchID = Dictionary(grouping: memberships, by: \.batchID)

        for item in sheep {
            rebuildProjection(
                for: item,
                at: endDate,
                transfers: transfersBySheepID[item.id] ?? [],
                removals: removalsBySheepID[item.id] ?? []
            )
        }

        // 批次生命周期与羊只是否离场无关。只有用户明确将成员脱离批次，成员关系才结束；
        // 最后一位成员的手工脱离时间就是批次归档时间。
        for batch in batches where batch.sourceRawValue == ProductionBatchSource.manual.rawValue {
            ProductionBatchLifecycle.reconcile(
                batch: batch,
                members: membershipsByBatchID[batch.id] ?? []
            )
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

    /// The common entry path changes one sheep. Replaying the entire farm timeline
    /// on the main actor made a single historical deletion look like a frozen app.
    /// Rebuild the affected projection and adjust only that sheep's contribution to
    /// historical aggregates when the exact deleted fact is known.
    func rebuildAffectedSheep(
        farmID: UUID,
        sheepIDs: Set<UUID>,
        context: ModelContext,
        from changedAt: Date?,
        through endDate: Date = .now,
        deletion: FarmHistoryDeletion? = nil
    ) throws {
        guard !sheepIDs.isEmpty else { return }
        guard let changedAt else {
            try rebuild(farmID: farmID, context: context, from: changedAt, through: endDate)
            return
        }
        let changedDay = calendar.startOfDay(for: changedAt)
        let endDay = calendar.startOfDay(for: endDate)
        if changedDay < endDay {
            guard let deletion,
                  try rebuildHistoricalDeletion(
                    farmID: farmID,
                    sheepIDs: sheepIDs,
                    deletion: deletion,
                    context: context,
                    from: changedAt,
                    through: endDate
                  ) else {
                try rebuild(farmID: farmID, context: context, from: changedAt, through: endDate)
                return
            }
            return
        }

        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let affectedSheep = sheep.filter { sheepIDs.contains($0.id) }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).filter { sheepIDs.contains($0.sheepID) }
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).filter { sheepIDs.contains($0.sheepID) }
        let transfersBySheepID = Dictionary(grouping: transfers, by: \.sheepID)
        let removalsBySheepID = Dictionary(grouping: removals, by: \.sheepID)

        for item in affectedSheep {
            rebuildProjection(
                for: item,
                at: endDate,
                transfers: transfersBySheepID[item.id] ?? [],
                removals: removalsBySheepID[item.id] ?? []
            )
        }

        let day = calendar.startOfDay(for: endDate)
        let existing = try context.fetch(FetchDescriptor<DailyPenCountRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.date == day
        }))
        let knownKeys = Set(existing.map { DailyPenCountKey(penID: $0.penID, purpose: $0.purpose) })
        try rebuildCurrentDaySnapshot(
            farmID: farmID,
            sheep: sheep,
            at: endDate,
            knownPenPurposeKeys: knownKeys,
            context: context
        )
    }

    /// A tombstoned transfer/removal changes one sheep's historical contribution,
    /// while every other sheep and every other aggregate row stays authoritative.
    /// Keeping the deleted record in SwiftData lets us reconstruct the pre-delete
    /// timeline and apply its exact delta without deleting and recreating the
    /// farm's complete daily history inside the UI transaction.
    private func rebuildHistoricalDeletion(
        farmID: UUID,
        sheepIDs: Set<UUID>,
        deletion: FarmHistoryDeletion,
        context: ModelContext,
        from changedAt: Date,
        through endDate: Date
    ) throws -> Bool {
        guard sheepIDs.count == 1,
              deletion.entityType == .sheep
                || deletion.entityType == .transfer
                || deletion.entityType == .removal else {
            return false
        }

        let allFarmSheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        guard let sheepID = sheepIDs.first,
              let historicalSheep = allFarmSheep.first(where: { $0.id == sheepID }) else {
            return false
        }
        let activeFarmSheep = allFarmSheep.filter { $0.deletedAt == nil }

        let allTransfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        let allRemovals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        let currentTransfers = allTransfers.filter { $0.deletedAt == nil }
        let currentRemovals = allRemovals.filter { $0.deletedAt == nil }

        var previousTransfers = currentTransfers
        var previousRemovals = currentRemovals
        let previousSheep: SheepRecord?
        switch deletion.entityType {
        case .sheep:
            guard historicalSheep.id == deletion.entityID,
                  historicalSheep.deletedAt != nil else { return false }
            previousSheep = historicalSheep
        case .transfer:
            guard let deletedTransfer = allTransfers.first(where: {
                $0.id == deletion.entityID && $0.deletedAt != nil
            }) else { return false }
            previousTransfers.append(deletedTransfer)
            previousSheep = historicalSheep
        case .removal:
            guard let deletedRemoval = allRemovals.first(where: {
                $0.id == deletion.entityID && $0.deletedAt != nil
            }) else { return false }
            previousRemovals.append(deletedRemoval)
            previousSheep = historicalSheep
        default:
            return false
        }

        if historicalSheep.deletedAt == nil {
            rebuildProjection(
                for: historicalSheep,
                at: endDate,
                transfers: currentTransfers,
                removals: currentRemovals
            )
        }

        let currentSheep = historicalSheep.deletedAt == nil ? historicalSheep : nil
        try adjustDailyPenCounts(
            farmID: farmID,
            previousSheep: previousSheep,
            currentSheep: currentSheep,
            previousTransfers: previousTransfers,
            currentTransfers: currentTransfers,
            previousRemovals: previousRemovals,
            currentRemovals: currentRemovals,
            from: changedAt,
            through: endDate,
            context: context
        )

        let currentDay = calendar.startOfDay(for: endDate)
        let existingCurrentDay = try context.fetch(FetchDescriptor<DailyPenCountRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.date == currentDay
        }))
        let knownKeys = Set(existingCurrentDay.map {
            DailyPenCountKey(penID: $0.penID, purpose: $0.purpose)
        })
        try rebuildCurrentDaySnapshot(
            farmID: farmID,
            sheep: activeFarmSheep,
            at: endDate,
            knownPenPurposeKeys: knownKeys,
            context: context
        )
        return true
    }

    private func adjustDailyPenCounts(
        farmID: UUID,
        previousSheep: SheepRecord?,
        currentSheep: SheepRecord?,
        previousTransfers: [TransferRecord],
        currentTransfers: [TransferRecord],
        previousRemovals: [RemovalRecord],
        currentRemovals: [RemovalRecord],
        from changedAt: Date,
        through endDate: Date,
        context: ModelContext
    ) throws {
        let startDay = calendar.startOfDay(for: changedAt)
        let endDay = calendar.startOfDay(for: endDate)
        guard startDay <= endDay else { return }

        var relevantDays = Set([startDay, endDay])
        let eventDates = previousTransfers.map(\.occurredAt)
            + currentTransfers.map(\.occurredAt)
            + previousRemovals.map(\.occurredAt)
            + currentRemovals.map(\.occurredAt)
            + [previousSheep?.enteredAt, currentSheep?.enteredAt].compactMap { $0 }
        for date in eventDates {
            let day = calendar.startOfDay(for: date)
            if day >= startDay && day <= endDay {
                relevantDays.insert(day)
            }
        }

        var deltaChanges: [DailyPenCountKey: [Date: Int]] = [:]
        var priorDelta = [DailyPenCountKey: Int]()
        for day in relevantDays.sorted() {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let instant = nextDay.addingTimeInterval(-0.001)
            let previousKey = dailyKey(
                for: previousSheep,
                at: instant,
                transfers: previousTransfers,
                removals: previousRemovals
            )
            let currentKey = dailyKey(
                for: currentSheep,
                at: instant,
                transfers: currentTransfers,
                removals: currentRemovals
            )
            var currentDelta = [DailyPenCountKey: Int]()
            if let previousKey { currentDelta[previousKey, default: 0] -= 1 }
            if let currentKey { currentDelta[currentKey, default: 0] += 1 }
            let keys = Set(priorDelta.keys).union(currentDelta.keys)
            for key in keys where priorDelta[key, default: 0] != currentDelta[key, default: 0] {
                deltaChanges[key, default: [:]][day] = currentDelta[key, default: 0]
            }
            priorDelta = currentDelta
        }

        for (key, changes) in deltaChanges {
            let penID = key.penID
            let purpose = key.purpose
            let records = try context.fetch(FetchDescriptor<DailyPenCountRecord>(predicate: #Predicate {
                $0.farmID == farmID
                    && $0.penID == penID
                    && $0.purpose == purpose
                    && $0.date <= endDay
            }))
            let orderedOriginal = records.sorted { $0.date < $1.date }
            let originalCount: (Date) -> Int = { date in
                orderedOriginal.last(where: { $0.date <= date })?.count ?? 0
            }
            let orderedChanges = changes.sorted { $0.key < $1.key }
            let delta: (Date) -> Int = { date in
                orderedChanges.last(where: { $0.key <= date })?.value ?? 0
            }

            for record in records where record.date >= startDay {
                record.count = max(0, record.count + delta(record.date))
                record.rebuiltAt = .now
            }
            let existingDates = Set(records.map(\.date))
            for (date, value) in orderedChanges where !existingDates.contains(date) {
                context.insert(DailyPenCountRecord(
                    farmID: farmID,
                    penID: key.penID,
                    purpose: key.purpose,
                    date: date,
                    count: max(0, originalCount(date) + value)
                ))
            }
        }
    }

    private func dailyKey(
        for sheep: SheepRecord?,
        at instant: Date,
        transfers: [TransferRecord],
        removals: [RemovalRecord]
    ) -> DailyPenCountKey? {
        guard let sheep, sheep.enteredAt <= instant else {
            return nil
        }
        let removal = removals
            .filter { $0.sheepID == sheep.id && $0.occurredAt <= instant }
            .min { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard removal == nil else { return nil }
        let latestTransfer = transfers
            .filter { $0.sheepID == sheep.id && $0.occurredAt <= instant }
            .max { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard let penID = latestTransfer?.toPenID ?? sheep.initialPenID else { return nil }
        return DailyPenCountKey(penID: penID, purpose: sheep.purpose)
    }

    private func rebuildProjection(
        for item: SheepRecord,
        at endDate: Date,
        transfers: [TransferRecord],
        removals: [RemovalRecord]
    ) {
        let fact = FarmSheepStateResolver.current(
            item,
            at: endDate,
            transfers: transfers,
            removals: removals
        )
        guard let projectedStatus = fact.status else { return }
        let projectedPen = fact.penID
        let projectedRemovedAt = fact.removedAt

        if item.status != projectedStatus || item.currentPenID != projectedPen || item.removedAt != projectedRemovedAt {
            item.statusRawValue = projectedStatus.rawValue
            item.currentPenID = projectedPen
            item.removedAt = projectedRemovedAt
            item.updatedAt = .now
            item.revision += 1
        }

        if !item.isCurrentlyPresent, item.currentPenID != nil {
            item.currentPenID = nil
            item.updatedAt = .now
            item.revision += 1
        }
    }

    private func rebuildCurrentDaySnapshot(
        farmID: UUID,
        sheep: [SheepRecord],
        at instant: Date,
        knownPenPurposeKeys: Set<DailyPenCountKey>,
        context: ModelContext
    ) throws {
        let day = calendar.startOfDay(for: instant)
        let existing = try context.fetch(FetchDescriptor<DailyPenCountRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.date == day
        }))
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

        let existing: [DailyPenCountRecord]
        if clearsUnprovableEarlierHistory {
            existing = try context.fetch(FetchDescriptor<DailyPenCountRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.date <= endDay
            }))
        } else {
            existing = try context.fetch(FetchDescriptor<DailyPenCountRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.date >= startDay && $0.date <= endDay
            }))
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
        // The local store can contain duplicate legacy rows after a recovery.
        // Select the newest materialized row deterministically instead of
        // trapping while building the lookup.  The event arrays remain fully
        // preserved and are still replayed below.
        let sheepByID = Dictionary(grouping: sheep, by: \.id).compactMapValues { records in
            records.max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
                return lhs.createdAt < rhs.createdAt
            }
        }
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

        func nextPendingEventDate() -> Date? {
            [
                sheepIndex < orderedSheep.count ? orderedSheep[sheepIndex].enteredAt : nil,
                transferIndex < orderedTransfers.count ? orderedTransfers[transferIndex].occurredAt : nil,
                removalIndex < orderedRemovals.count ? orderedRemovals[removalIndex].occurredAt : nil,
            ]
            .compactMap { $0 }
            .min()
        }

        while day <= endDay {
            dailyReplayObserver?(day)
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

            guard let nextEventDate = nextPendingEventDate() else { break }
            day = max(nextDay, calendar.startOfDay(for: nextEventDate))
        }

        return knownKeys
    }

    private func isKnownTimelineDate(_ date: Date) -> Bool {
        date > .distantPast
    }
}

/// A completed cloud rebuild intentionally preserves legacy snapshot authority
/// because the imported event timeline can be incomplete. Any transfer or
/// removal received *after* that authority switch is a new immutable remote fact
/// and must take authority from the legacy snapshot. Older builds persisted the
/// new fact and its receipt but forgot this handoff, leaving the dashboard on the
/// pre-sync sheep count. Repair that narrow post-recovery window before cloud
/// collaboration starts so already-received operations become visible without a
/// re-upload or another full cloud rebuild.
enum PostRecoveryHistoryProjectionRepair {
    @discardableResult
    static func repair(container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        let activeCloudFarmIDs = Set(try context.fetch(FetchDescriptor<CloudFarmBinding>())
            .filter { $0.state == .active }
            .map(\.farmID))
        let activeRemoteBindings = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .filter { $0.state == .active }
        let activeFarmIDs = activeCloudFarmIDs.union(activeRemoteBindings.map(\.farmID))
        guard !activeFarmIDs.isEmpty else { return 0 }

        let completedSessions = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter {
                activeFarmIDs.contains($0.farmID) &&
                    $0.status == .completed &&
                    $0.completedAt != nil
            }
        let completedRemoteRestores = try context.fetch(FetchDescriptor<FarmRemoteRestoreRecord>())
            .filter {
                activeFarmIDs.contains($0.farmID) &&
                    $0.state == .completed &&
                    $0.completedAt != nil
            }
        let baselineMigrationFarmIDs = Set(try context.fetch(FetchDescriptor<FarmBaselineMigrationRecord>())
            .map(\.farmID))
        var latestCutoffByFarmID: [UUID: Date] = [:]
        func registerCutoff(_ cutoff: Date, farmID: UUID) {
            latestCutoffByFarmID[farmID] = max(
                latestCutoffByFarmID[farmID] ?? .distantPast,
                cutoff
            )
        }
        for session in completedSessions {
            guard let completedAt = session.completedAt else { continue }
            registerCutoff(completedAt, farmID: session.farmID)
        }
        for restore in completedRemoteRestores {
            guard let completedAt = restore.completedAt else { continue }
            registerCutoff(completedAt, farmID: restore.farmID)
        }
        for binding in activeRemoteBindings where baselineMigrationFarmIDs.contains(binding.farmID) {
            registerCutoff(binding.createdAt, farmID: binding.farmID)
        }
        guard !latestCutoffByFarmID.isEmpty else { return 0 }

        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>())
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>())
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
        // `id` is the cloud operation identity, but older imports/recovery
        // paths did not enforce uniqueness in the local SwiftData store.  A
        // duplicate row must not be allowed to crash startup (the previous
        // `uniqueKeysWithValues` initializer traps with SIGTRAP).  Keep every
        // row under the key so a tombstone can still invalidate all affected
        // projections, including a malformed duplicate that points at a
        // different sheep.
        let transfersByID = Dictionary(grouping: transfers, by: \.id)
        let removalsByID = Dictionary(grouping: removals, by: \.id)
        var repairedSheepCount = 0

        for (farmID, cutoff) in latestCutoffByFarmID {
            var affectedStatusSheepIDs = Set<UUID>()
            var affectedPenSheepIDs = Set<UUID>()
            var changedDates: [Date] = []

            for transfer in transfers where transfer.farmID == farmID {
                guard transfer.recordedAt > cutoff || transfer.deletedAt.map({ $0 > cutoff }) == true else {
                    continue
                }
                affectedPenSheepIDs.insert(transfer.sheepID)
                changedDates.append(transfer.occurredAt)
            }
            for removal in removals where removal.farmID == farmID {
                guard removal.recordedAt > cutoff || removal.deletedAt.map({ $0 > cutoff }) == true else {
                    continue
                }
                affectedStatusSheepIDs.insert(removal.sheepID)
                changedDates.append(removal.occurredAt)
            }
            for tombstone in tombstones where tombstone.farmID == farmID {
                guard tombstone.deletedAt > cutoff || tombstone.restoredAt.map({ $0 > cutoff }) == true else {
                    continue
                }
                switch CloudEntityType(rawValue: tombstone.entityType) {
                case .transfer:
                    for transfer in transfersByID[tombstone.entityID] ?? [] where transfer.farmID == farmID {
                        affectedPenSheepIDs.insert(transfer.sheepID)
                        changedDates.append(transfer.occurredAt)
                    }
                case .removal:
                    for removal in removalsByID[tombstone.entityID] ?? [] where removal.farmID == farmID {
                        affectedStatusSheepIDs.insert(removal.sheepID)
                        changedDates.append(removal.occurredAt)
                    }
                default:
                    break
                }
            }

            let affectedSheepIDs = affectedStatusSheepIDs.union(affectedPenSheepIDs)
            guard !affectedSheepIDs.isEmpty else { continue }
            var changedSheepIDs = Set<UUID>()
            for item in sheep where item.farmID == farmID && affectedSheepIDs.contains(item.id) {
                guard item.legacyStatusSnapshotIsAuthoritative == true ||
                        item.legacyPenSnapshotIsAuthoritative == true else {
                    continue
                }
                item.legacyStatusSnapshotIsAuthoritative = false
                item.legacyPenSnapshotIsAuthoritative = false
                changedSheepIDs.insert(item.id)
                repairedSheepCount += 1
            }
            guard !changedSheepIDs.isEmpty else { continue }
            try FarmHistoryRebuilder().rebuildAffectedSheep(
                farmID: farmID,
                sheepIDs: changedSheepIDs,
                context: context,
                from: changedDates.min() ?? cutoff
            )
        }

        if repairedSheepCount > 0 {
            try context.save()
        }
        return repairedSheepCount
    }
}

/// Repairs projections written by receivers that persisted an immutable remote
/// operation receipt even though applying that operation had conflicted.  The
/// repair is deliberately evidence-bound: it never invents an operation, never
/// changes an entity beyond the newest accepted receipt, and only bridges a
/// missing removal revision when a matching, unrestored tombstone proves the
/// intervening revision.
enum RemoteProjectionReceiptRepair {
    @discardableResult
    static func repair(container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        let activeFarmIDs = Set(try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .filter { $0.provider == .supabase && $0.state == .active }
            .map(\.farmID))
        var repairedCount = 0
        for farmID in activeFarmIDs {
            repairedCount += try repair(farmID: farmID, context: context)
        }
        return repairedCount
    }

    @discardableResult
    static func repair(farmID: UUID, context: ModelContext) throws -> Int {
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == farmID }

        var operationByID: [UUID: DomainOperation] = [:]
        var newestRelevantByEntityID: [UUID: DomainOperation] = [:]
        for operation in operations {
            operationByID[operation.id] = operation
            guard let entityID = operation.entityID,
                  operation.kindRawValue == DomainOperationKind.removeSheep.rawValue ||
                    operation.kindRawValue == DomainOperationKind.updateSheepProfile.rawValue else {
                continue
            }
            if let current = newestRelevantByEntityID[entityID],
               current.resultingRevision > operation.resultingRevision ||
                (current.resultingRevision == operation.resultingRevision &&
                    current.createdAt >= operation.createdAt) {
                continue
            }
            newestRelevantByEntityID[entityID] = operation
        }

        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
            .filter { $0.farmID == farmID }
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>())
            .filter { $0.farmID == farmID }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == farmID }
        let removalsByID = Dictionary(grouping: removals, by: \.id)
        let sheepByID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        let service = RemoteDomainApplyService()
        var repairedCount = 0
        var rebuildFrom: Date?

        do {
            let unresolvedConflicts = try context.fetch(FetchDescriptor<SyncConflictRecord>())
                .filter {
                    $0.farmID == farmID &&
                        $0.statusRawValue == SyncConflictStatus.unresolved.rawValue
                }
            var retriedOperationIDs = Set<UUID>()
            let cloudDecoder = JSONDecoder()
            cloudDecoder.dateDecodingStrategy = .iso8601
            for conflict in unresolvedConflicts {
                guard let data = conflict.remoteEnvelopeData,
                      let envelope = try? cloudDecoder.decode(
                        CloudOperationEnvelope.self,
                        from: data
                      ),
                      envelope.farmID == farmID,
                      envelope.entityID == conflict.entityID,
                      envelope.entityType == conflict.entityType,
                      envelope.payload == conflict.remotePayload,
                      envelope.payloadDigest == CloudPayloadDigest.hex(for: envelope.payload),
                      operationByID[envelope.operationID] == nil,
                      retriedOperationIDs.insert(envelope.operationID).inserted,
                      let payload = try? decodePayload(envelope.payload) else {
                    continue
                }
                guard case .applied(let changedAt) = try service.apply(
                    envelope,
                    context: context
                ) else {
                    continue
                }
                let receipt = DomainOperation(
                    id: envelope.operationID,
                    farmID: envelope.farmID,
                    accountID: envelope.modifiedByAccountID,
                    kind: payload.kind,
                    occurredAt: envelope.modifiedAt,
                    summary: "Supabase 同步自愈：\(payload.kind.rawValue)",
                    entityType: envelope.entityType,
                    entityID: envelope.entityID,
                    baseRevision: envelope.baseRevision,
                    resultingRevision: envelope.revision,
                    payload: envelope.payload
                )
                receipt.modifiedByDeviceID = envelope.modifiedByDeviceID
                receipt.capabilityCertificate = envelope.capabilityCertificate
                receipt.operationSignature = envelope.operationSignature
                context.insert(receipt)
                operationByID[receipt.id] = receipt
                if let changedAt {
                    rebuildFrom = min(rebuildFrom ?? changedAt, changedAt)
                }
                repairedCount += 1
                repairedCount += resolveMatchingConflicts(
                    operationID: envelope.operationID,
                    farmID: farmID,
                    entityID: envelope.entityID,
                    context: context
                )
            }

            for operation in newestRelevantByEntityID.values {
                guard operation.payloadDigest == CloudPayloadDigest.hex(for: operation.payload),
                      operation.resultingRevision == operation.baseRevision + 1,
                      let envelope = envelope(from: operation),
                      let payload = try? decodePayload(operation.payload) else {
                    continue
                }
                let entityID = operation.entityID!
                let hasLaterEntityOperation = operations.contains {
                    $0.entityID == entityID &&
                        $0.resultingRevision > operation.resultingRevision
                }
                guard !hasLaterEntityOperation else { continue }

                switch payload.kind {
                case .removeSheep:
                    guard operation.entityType == CloudEntityType.removal.rawValue,
                          payload.identifiers["sheepID"] != nil,
                          let removal = removalsByID[entityID]?.first,
                          removal.sheepID == payload.identifiers["sheepID"] else {
                        continue
                    }

                    if removal.deletedAt != nil && removal.revision < operation.baseRevision {
                        guard hasValidTombstoneBridge(
                            entityID: entityID,
                            targetBaseRevision: operation.baseRevision,
                            tombstones: tombstones,
                            operationByID: operationByID
                        ) else {
                            continue
                        }
                        removal.revision = operation.baseRevision
                    }

                    if removal.deletedAt != nil {
                        guard removal.revision == operation.baseRevision else { continue }
                        guard case .applied(let changedAt) = try service.apply(envelope, context: context) else {
                            continue
                        }
                        rebuildFrom = min(rebuildFrom ?? changedAt ?? removal.occurredAt, changedAt ?? removal.occurredAt)
                        repairedCount += 1
                    } else if removal.revision == operation.resultingRevision {
                        if !removalMatches(removal, payload: payload) {
                            _ = try ConflictDomainMergeService.apply(
                                payload: operation.payload,
                                entityType: operation.entityType,
                                entityID: entityID,
                                farmID: farmID,
                                revision: operation.resultingRevision,
                                context: context
                            )
                            removal.deletedAt = nil
                            repairedCount += 1
                        }
                        if let projectedSheep = sheepByID[removal.sheepID],
                           projectedSheep.status == .active ||
                            projectedSheep.removedAt != removal.occurredAt ||
                            projectedSheep.currentPenID != nil {
                            rebuildFrom = min(rebuildFrom ?? removal.occurredAt, removal.occurredAt)
                            repairedCount += 1
                        }
                    }

                    repairedCount += resolveMatchingConflicts(
                        operationID: operation.id,
                        farmID: farmID,
                        entityID: entityID,
                        context: context
                    )

                case .updateSheepProfile:
                    guard operation.entityType == CloudEntityType.sheep.rawValue,
                          payload.identifiers["sheepID"] == entityID,
                          let record = sheepByID[entityID],
                          record.revision == operation.baseRevision ||
                            record.revision == operation.resultingRevision else {
                        continue
                    }
                    if sheepProfileMatches(record, payload: payload) {
                        repairedCount += resolveMatchingConflicts(
                            operationID: operation.id,
                            farmID: farmID,
                            entityID: entityID,
                            context: context
                        )
                        continue
                    }
                    guard case .applied = try service.apply(envelope, context: context) else {
                        continue
                    }
                    repairedCount += 1
                    repairedCount += resolveMatchingConflicts(
                        operationID: operation.id,
                        farmID: farmID,
                        entityID: entityID,
                        context: context
                    )

                default:
                    continue
                }
            }

            if let rebuildFrom {
                try FarmHistoryRebuilder().rebuild(
                    farmID: farmID,
                    context: context,
                    from: rebuildFrom
                )
            }
            if context.hasChanges { try context.save() }
            return repairedCount
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func envelope(from operation: DomainOperation) -> CloudOperationEnvelope? {
        guard let entityID = operation.entityID,
              let deviceID = operation.modifiedByDeviceID,
              let signature = operation.operationSignature else {
            return nil
        }
        return CloudOperationEnvelope(
            farmID: operation.farmID,
            entityID: entityID,
            entityType: operation.entityType,
            schemaVersion: operation.schemaVersion,
            revision: operation.resultingRevision,
            baseRevision: operation.baseRevision,
            operationID: operation.id,
            modifiedAt: operation.occurredAt,
            modifiedByAccountID: operation.accountID,
            modifiedByDeviceID: deviceID,
            payload: operation.payload,
            payloadDigest: operation.payloadDigest,
            capabilityCertificate: operation.capabilityCertificate,
            operationSignature: signature,
            deletedAt: nil
        )
    }

    private static func decodePayload(_ data: Data) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }

    private static func hasValidTombstoneBridge(
        entityID: UUID,
        targetBaseRevision: Int,
        tombstones: [TombstoneRecord],
        operationByID: [UUID: DomainOperation]
    ) -> Bool {
        tombstones.contains { tombstone in
            guard tombstone.entityType == CloudEntityType.removal.rawValue,
                  tombstone.entityID == entityID,
                  tombstone.revision == targetBaseRevision,
                  tombstone.restoredAt == nil,
                  let operationID = tombstone.operationID,
                  let operation = operationByID[operationID],
                  operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
                  operation.entityType == CloudEntityType.removal.rawValue,
                  operation.entityID == entityID,
                  operation.baseRevision + 1 == targetBaseRevision,
                  operation.resultingRevision == targetBaseRevision,
                  operation.payloadDigest == CloudPayloadDigest.hex(for: operation.payload),
                  operation.modifiedByDeviceID != nil,
                  operation.operationSignature != nil,
                  let payload = try? decodePayload(operation.payload) else {
                return false
            }
            return payload.kind == .tombstoneEntity &&
                payload.strings["entityType"] == CloudEntityType.removal.rawValue &&
                payload.identifiers["entityID"] == entityID
        }
    }

    private static func removalMatches(
        _ removal: RemovalRecord,
        payload: FarmCommandCloudPayload
    ) -> Bool {
        removal.sheepID == payload.identifiers["sheepID"] &&
            removal.kindRawValue == payload.strings["kind"] &&
            removal.reason == payload.strings["reason"] &&
            removal.amountText == (payload.optionalStrings["amountText"] ?? nil) &&
            removal.removalBatchID == (payload.optionalIdentifiers["removalBatchID"] ?? nil) &&
            removal.batchTotalAmountText == (payload.optionalStrings["batchTotalAmountText"] ?? nil) &&
            removal.occurredAt == payload.dates["occurredAt"] &&
            removal.note == (payload.strings["note"] ?? "")
    }

    private static func sheepProfileMatches(
        _ sheep: SheepRecord,
        payload: FarmCommandCloudPayload
    ) -> Bool {
        sheep.earTag == payload.strings["earTag"] &&
            sheep.breed == payload.strings["breed"] &&
            sheep.sexRawValue == payload.strings["sex"] &&
            sheep.birthAt == (payload.optionalDates["birthAt"] ?? nil) &&
            sheep.note == (payload.strings["note"] ?? "")
    }

    private static func resolveMatchingConflicts(
        operationID: UUID,
        farmID: UUID,
        entityID: UUID,
        context: ModelContext
    ) -> Int {
        let conflicts = ((try? context.fetch(FetchDescriptor<SyncConflictRecord>())) ?? [])
            .filter {
                $0.farmID == farmID &&
                    $0.entityID == entityID &&
                    $0.statusRawValue == SyncConflictStatus.unresolved.rawValue
            }
        var resolved = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for conflict in conflicts {
            guard let data = conflict.remoteEnvelopeData,
                  let envelope = try? decoder.decode(CloudOperationEnvelope.self, from: data),
                  envelope.operationID == operationID else {
                continue
            }
            conflict.statusRawValue = SyncConflictStatus.acceptedRemote.rawValue
            conflict.resolvedAt = .now
            conflict.resolutionNote = "已依据经验证的云端操作回执自动恢复本地投影。"
            conflict.resolutionOperationID = operationID
            conflict.resolutionFailureReason = nil
            resolved += 1
        }
        return resolved
    }
}

private struct DailyPenCountKey: Hashable {
    let penID: UUID
    let purpose: String
}
