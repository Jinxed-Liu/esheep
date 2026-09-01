import Foundation

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
