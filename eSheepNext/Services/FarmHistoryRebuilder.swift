import Foundation
import SwiftData

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

    /// The common entry path changes one sheep and normally occurs today. Replaying
    /// the entire farm timeline on the main actor made a single removal feel like a
    /// stalled save. Rebuild only the affected projection and today's aggregate;
    /// historical corrections still use the full replay above.
    func rebuildAffectedSheep(
        farmID: UUID,
        sheepIDs: Set<UUID>,
        context: ModelContext,
        from changedAt: Date?,
        through endDate: Date = .now
    ) throws {
        guard !sheepIDs.isEmpty else { return }
        guard let changedAt,
              calendar.startOfDay(for: changedAt) >= calendar.startOfDay(for: endDate) else {
            try rebuild(farmID: farmID, context: context, from: changedAt, through: endDate)
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

    private func rebuildProjection(
        for item: SheepRecord,
        at endDate: Date,
        transfers: [TransferRecord],
        removals: [RemovalRecord]
    ) {
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
/// removal received *after* that cache switch is a new immutable cloud fact and
/// must take authority from the legacy snapshot. Older builds persisted the new
/// fact and its CloudKit receipt but forgot this handoff, leaving the dashboard
/// on the pre-sync sheep count. Repair that narrow post-rebuild window before
/// CKSyncEngine starts so already-received operations become visible without a
/// re-upload or another full cloud rebuild.
enum PostRecoveryHistoryProjectionRepair {
    @discardableResult
    static func repair(container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        let activeFarmIDs = Set(try context.fetch(FetchDescriptor<CloudFarmBinding>())
            .filter { $0.state == .active }
            .map(\.farmID))
        guard !activeFarmIDs.isEmpty else { return 0 }

        let completedSessions = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter {
                activeFarmIDs.contains($0.farmID) &&
                    $0.status == .completed &&
                    $0.completedAt != nil
            }
        var latestCutoffByFarmID: [UUID: Date] = [:]
        for session in completedSessions {
            guard let completedAt = session.completedAt else { continue }
            latestCutoffByFarmID[session.farmID] = max(
                latestCutoffByFarmID[session.farmID] ?? .distantPast,
                completedAt
            )
        }
        guard !latestCutoffByFarmID.isEmpty else { return 0 }

        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>())
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>())
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
        let transfersByID = Dictionary(uniqueKeysWithValues: transfers.map { ($0.id, $0) })
        let removalsByID = Dictionary(uniqueKeysWithValues: removals.map { ($0.id, $0) })
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
                    if let transfer = transfersByID[tombstone.entityID] {
                        affectedPenSheepIDs.insert(transfer.sheepID)
                        changedDates.append(transfer.occurredAt)
                    }
                case .removal:
                    if let removal = removalsByID[tombstone.entityID] {
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

private struct DailyPenCountKey: Hashable {
    let penID: UUID
    let purpose: String
}
