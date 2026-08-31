import Foundation

/// Versioned business contract shared by farm-fact readers. A successful
/// calculation is not sufficient evidence unless it also names the semantic
/// contract and the state basis used to produce it.
enum FarmFactContract {
    static let version = "farm-facts-v1"

    enum StateCutoff: Equatable, Sendable {
        case current(Date)
        case historical(Date)

        var instant: Date {
            switch self {
            case .current(let instant), .historical(let instant): instant
            }
        }

        var evidenceName: String {
            switch self {
            case .current: "current_projection_policy"
            case .historical: "historical_event_timeline"
            }
        }
    }

    enum SheepStateBasis: String, Sendable {
        case currentHistoricalArchive = "current_historical_archive"
        case currentLegacySnapshot = "current_legacy_snapshot"
        case currentEventProjection = "current_event_projection"
        case historicalRemovalEvent = "historical_removal_event"
        case historicalMaterializedRemoval = "historical_materialized_removal"
        case historicalCurrentSurvivor = "historical_current_survivor"
        case historicalBeforeKnownRemoval = "historical_before_known_removal"
        case insufficientHistoricalEvidence = "insufficient_historical_evidence"
        case outsideRequestedLifetime = "outside_requested_lifetime"
    }
}

/// One resolved sheep-state fact. Current state follows the same authority
/// rules used to materialize SheepRecord.status/currentPenID. Historical state
/// is returned only when the event ledger or a dated materialized fact proves
/// it; missing history is `unknown` and is never silently treated as active.
struct FarmSheepStateFact {
    let status: SheepStatus?
    let removalKind: RemovalKind?
    let penID: UUID?
    let removedAt: Date?
    let basis: FarmFactContract.SheepStateBasis
    let isIncluded: Bool
    let isKnown: Bool
    let presenceProjectionMatchesStoredState: Bool
    let statusProjectionMatchesStoredState: Bool
    let penProjectionMatchesStoredState: Bool

    var projectionMatchesStoredState: Bool {
        presenceProjectionMatchesStoredState &&
            statusProjectionMatchesStoredState &&
            penProjectionMatchesStoredState
    }

    var isPresent: Bool {
        isIncluded && isKnown && status == .active
    }
}

enum FarmSheepStateResolver {
    static func resolve(
        _ sheep: SheepRecord,
        cutoff: FarmFactContract.StateCutoff,
        transfers: [TransferRecord],
        removals: [RemovalRecord]
    ) -> FarmSheepStateFact {
        switch cutoff {
        case .current(let instant):
            current(sheep, at: instant, transfers: transfers, removals: removals)
        case .historical(let instant):
            historical(sheep, at: instant, transfers: transfers, removals: removals)
        }
    }

    /// Canonical current projection policy. Keep this in one place: migration
    /// snapshots remain authoritative until a new native status event unlocks
    /// them; otherwise the event ledger owns the projection.
    static func current(
        _ sheep: SheepRecord,
        at instant: Date,
        transfers: [TransferRecord],
        removals: [RemovalRecord]
    ) -> FarmSheepStateFact {
        let removal = FarmHistoryTimeline.removal(
            for: sheep.id,
            at: instant,
            removals: removals
        )
        let reconstructedStatus = removal?.kind.resultingStatus ?? .active
        let status: SheepStatus
        let basis: FarmFactContract.SheepStateBasis
        if sheep.isHistoricalArchive {
            status = .removed
            basis = .currentHistoricalArchive
        } else if sheep.legacyStatusSnapshotIsAuthoritative == true {
            status = sheep.status
            basis = .currentLegacySnapshot
        } else {
            status = reconstructedStatus
            basis = .currentEventProjection
        }

        let reconstructedPen = reconstructedStatus == .active
            ? FarmHistoryTimeline.pen(for: sheep, at: instant, transfers: transfers)
            : nil
        let penID: UUID?
        if status != .active || sheep.isHistoricalArchive {
            penID = nil
        } else if sheep.legacyPenSnapshotIsAuthoritative == true {
            penID = sheep.currentPenID
        } else {
            penID = reconstructedPen
        }

        let removedAt: Date?
        if sheep.isHistoricalArchive {
            removedAt = sheep.removedAt
        } else if sheep.legacyStatusSnapshotIsAuthoritative == true {
            removedAt = status == .active ? nil : (removal?.occurredAt ?? sheep.removedAt)
        } else {
            removedAt = removal?.occurredAt
        }

        return FarmSheepStateFact(
            status: status,
            removalKind: removal?.kind,
            penID: penID,
            removedAt: removedAt,
            basis: basis,
            isIncluded: !sheep.isHistoricalArchive,
            isKnown: true,
            presenceProjectionMatchesStoredState: sheep.isCurrentlyPresent == (
                !sheep.isHistoricalArchive && status == .active
            ),
            // Historical archives are excluded by an independent first-class
            // flag throughout the App. Their legacy status text must not make a
            // current-herd count unavailable while the rebuilder normalizes it.
            statusProjectionMatchesStoredState: sheep.isHistoricalArchive || sheep.status == status,
            penProjectionMatchesStoredState: sheep.isHistoricalArchive || sheep.currentPenID == penID
        )
    }

    static func historical(
        _ sheep: SheepRecord,
        at instant: Date,
        transfers: [TransferRecord],
        removals: [RemovalRecord]
    ) -> FarmSheepStateFact {
        guard sheep.enteredAt <= instant else {
            return FarmSheepStateFact(
                status: nil,
                removalKind: nil,
                penID: nil,
                removedAt: nil,
                basis: .outsideRequestedLifetime,
                isIncluded: false,
                isKnown: true,
                presenceProjectionMatchesStoredState: true,
                statusProjectionMatchesStoredState: true,
                penProjectionMatchesStoredState: true
            )
        }

        let activeRemovals = removals.filter { $0.deletedAt == nil && $0.sheepID == sheep.id }
        if let removal = FarmHistoryTimeline.removal(
            for: sheep.id,
            at: instant,
            removals: activeRemovals
        ) {
            return FarmSheepStateFact(
                status: removal.kind.resultingStatus,
                removalKind: removal.kind,
                penID: nil,
                removedAt: removal.occurredAt,
                basis: .historicalRemovalEvent,
                isIncluded: true,
                isKnown: true,
                presenceProjectionMatchesStoredState: true,
                statusProjectionMatchesStoredState: true,
                penProjectionMatchesStoredState: true
            )
        }

        if let removedAt = sheep.removedAt, removedAt <= instant, sheep.status != .active {
            return FarmSheepStateFact(
                status: sheep.status,
                removalKind: nil,
                penID: nil,
                removedAt: removedAt,
                basis: .historicalMaterializedRemoval,
                isIncluded: true,
                isKnown: true,
                presenceProjectionMatchesStoredState: true,
                statusProjectionMatchesStoredState: true,
                penProjectionMatchesStoredState: true
            )
        }

        let futureRemoval = activeRemovals
            .filter { $0.occurredAt > instant }
            .min(by: removalOccursBefore)
        let futureMaterializedRemoval = sheep.removedAt.flatMap { $0 > instant ? $0 : nil }
        if futureRemoval != nil || futureMaterializedRemoval != nil {
            return FarmSheepStateFact(
                status: .active,
                removalKind: nil,
                penID: FarmHistoryTimeline.pen(for: sheep, at: instant, transfers: transfers),
                removedAt: nil,
                basis: .historicalBeforeKnownRemoval,
                isIncluded: true,
                isKnown: true,
                presenceProjectionMatchesStoredState: true,
                statusProjectionMatchesStoredState: true,
                penProjectionMatchesStoredState: true
            )
        }

        if sheep.isCurrentlyPresent {
            return FarmSheepStateFact(
                status: .active,
                removalKind: nil,
                penID: FarmHistoryTimeline.pen(for: sheep, at: instant, transfers: transfers),
                removedAt: nil,
                basis: .historicalCurrentSurvivor,
                isIncluded: true,
                isKnown: true,
                presenceProjectionMatchesStoredState: true,
                statusProjectionMatchesStoredState: true,
                penProjectionMatchesStoredState: true
            )
        }

        // A current non-active snapshot without a dated removal does not prove
        // whether the sheep was present at an arbitrary historical cutoff.
        return FarmSheepStateFact(
            status: nil,
            removalKind: nil,
            penID: nil,
            removedAt: nil,
            basis: .insufficientHistoricalEvidence,
            isIncluded: true,
            isKnown: false,
            presenceProjectionMatchesStoredState: true,
            statusProjectionMatchesStoredState: true,
            penProjectionMatchesStoredState: true
        )
    }

    private static func removalOccursBefore(_ lhs: RemovalRecord, _ rhs: RemovalRecord) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
