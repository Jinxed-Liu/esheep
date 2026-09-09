import Foundation
import SwiftData

/// A purpose change is an immutable business fact projected from the same
/// operation ledger that synchronizes the current `SheepRecord.purpose` value.
/// The sheep row remains the fast current-state projection; this value keeps
/// the historical meaning of every explicit change.
struct SheepPurposeTimelineFact: Identifiable, Sendable, Hashable {
    let id: UUID
    let sheepID: UUID
    let previousPurpose: String?
    let purpose: SheepPurpose
    let reason: String
    let occurredAt: Date
    let recordedAt: Date
    let changedByAccountID: UUID
    let resultingRevision: Int

    var transitionText: String {
        "\(Self.normalized(previousPurpose) ?? "历史用途（未记录）") → \(purpose.displayName)"
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SheepPurposeTimeline {
    static let previousPurposeField = "previousSheepPurpose"
    static let changedAtField = "sheepPurposeChangedAt"

    static func previousPurpose(from payload: Data) throws -> String? {
        let decoded = try cloudDecoder.decode(FarmCommandCloudPayload.self, from: payload)
        return decoded.optionalStrings[previousPurposeField] ?? nil
    }

    static func facts(from operations: [DomainOperation]) -> [SheepPurposeTimelineFact] {
        let decoded = operations.compactMap(decode)
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.id.uuidString < $1.id.uuidString
            }

        var lastPurposeBySheepID = [UUID: String]()
        return decoded.map { value in
            let previous = normalized(value.previousPurpose)
                ?? lastPurposeBySheepID[value.sheepID]
            lastPurposeBySheepID[value.sheepID] = value.purpose.rawValue
            return SheepPurposeTimelineFact(
                id: value.id,
                sheepID: value.sheepID,
                previousPurpose: previous,
                purpose: value.purpose,
                reason: value.reason,
                occurredAt: value.occurredAt,
                recordedAt: value.recordedAt,
                changedByAccountID: value.changedByAccountID,
                resultingRevision: value.resultingRevision
            )
        }
    }

    private static func decode(
        _ operation: DomainOperation
    ) -> SheepPurposeTimelineFact? {
        guard operation.kindRawValue == DomainOperationKind.care.rawValue,
              let payload = try? cloudDecoder.decode(
                FarmCommandCloudPayload.self,
                from: operation.payload
              ),
              case .setSheepPurpose(let sheepID, let purpose, let reason, _) = payload.careCommand,
              operation.entityID == sheepID else {
            return nil
        }
        return SheepPurposeTimelineFact(
            id: operation.id,
            sheepID: sheepID,
            previousPurpose: payload.optionalStrings[previousPurposeField] ?? nil,
            purpose: purpose,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
            occurredAt: payload.dates[changedAtField] ?? operation.occurredAt,
            recordedAt: operation.createdAt,
            changedByAccountID: operation.accountID,
            resultingRevision: operation.resultingRevision
        )
    }

    private static var cloudDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Lifecycle is a projection of dated facts, not an extra user command. Rebuilds
/// and deletions use the same rules as newly recorded weaning facts.
enum SheepLifecyclePurpose {
    struct Change {
        let sheepID: UUID
        let occurredAt: Date
        let recordedAt: Date
        let id: UUID
        let purpose: String
        let explicit: Bool
    }
    struct Timeline {
        let initial: String
        let changes: [Change]
        func value(at date: Date) -> String {
            changes.last(where: { $0.occurredAt <= date })?.purpose ?? initial
        }
    }

    static func timelines(farmID: UUID, sheep: [SheepRecord], context: ModelContext) throws -> [UUID: Timeline] {
        // Include revoked weaning records to recover the pre-weaning baseline.
        let weanings = try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate { $0.farmID == farmID }))
        let operations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID && $0.kindRawValue == "care"
        }))
        let weaningsBySheep = Dictionary(grouping: weanings, by: \.sheepID)
        let explicitBySheep = Dictionary(grouping: SheepPurposeTimeline.facts(from: operations), by: \.sheepID)
        var result = [UUID: Timeline]()
        for item in sheep {
            let records = weaningsBySheep[item.id] ?? []
            let explicit = explicitBySheep[item.id] ?? []
            let current: SheepPurpose? = item.isBreedingRam ? .breedingRam : SheepPurpose.classify(storedValue: item.purpose)
            let lifecycleManaged = current == .sucklingLamb || current == .weanedLamb || current == .unclassified
            // Preserve imported adult purposes when no dated explicit change can
            // establish when that purpose began.
            guard !explicit.isEmpty || lifecycleManaged else { continue }
            let bornHere = item.damProvenance == .lambing
            guard bornHere || !records.isEmpty || !explicit.isEmpty else { continue }
            let previous = explicit.first?.previousPurpose
            let initial = bornHere ? SheepPurpose.sucklingLamb.rawValue
                : (previous ?? (!records.isEmpty ? SheepPurpose.sucklingLamb.rawValue : item.purpose))
            var changes = records.filter { $0.deletedAt == nil }.map {
                Change(sheepID: item.id, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt,
                       id: $0.id, purpose: SheepPurpose.weanedLamb.rawValue, explicit: false)
            }
            changes += explicit.map {
                Change(sheepID: item.id, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt,
                       id: $0.id, purpose: $0.purpose.rawValue, explicit: true)
            }
            changes.sort {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.explicit != $1.explicit { return !$0.explicit }
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            var purpose = initial
            let effectiveChanges = changes.filter { change in
                let classification = SheepPurpose.classify(storedValue: purpose)
                guard change.explicit || classification == .sucklingLamb || classification == .weanedLamb ||
                        classification == .unclassified else { return false }
                purpose = change.purpose
                return true
            }
            result[item.id] = Timeline(initial: initial, changes: effectiveChanges)
        }
        return result
    }

    static func project(_ sheep: SheepRecord, timeline: Timeline?, at date: Date) {
        guard let timeline else { return }
        sheep.purpose = timeline.value(at: date)
        sheep.isBreedingRam = sheep.sex == .ram && SheepPurpose.classify(storedValue: sheep.purpose) == .breedingRam
    }
}
