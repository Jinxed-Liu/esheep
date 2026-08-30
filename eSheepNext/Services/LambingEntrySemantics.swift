import Foundation

enum LambRecordedWeightKind: Sendable, Equatable {
    case birth
    case routine

    var displayName: String {
        switch self {
        case .birth: "初生重"
        case .routine: "普通称重"
        }
    }
}

enum LambingEntrySemantics {
    /// ICAR sheep performance recording guidance treats a weight measured
    /// within 24 hours of birth as birth weight. Later measurements remain
    /// ordinary weighing facts at their actual measurement time.
    static let birthWeightWindow: TimeInterval = 24 * 60 * 60

    /// Builds the editable default shown for a lamb's breed. When both parent
    /// breeds are known, the product rule is `父本品种-母本品种串`.
    /// A single known parent remains a useful fallback for legacy/unknown-
    /// paternity records, while a completely unknown pairing stays explicit.
    static func suggestedLambBreed(
        paternalBreed: String?,
        maternalBreed: String?
    ) -> String {
        let paternal = normalizedBreed(paternalBreed)
        let maternal = normalizedBreed(maternalBreed)

        switch (paternal, maternal) {
        case let (paternal?, maternal?):
            return "\(paternal)-\(maternal)串"
        case let (paternal?, nil):
            return paternal
        case let (nil, maternal?):
            return maternal
        case (nil, nil):
            return "未知"
        }
    }

    static func breedAfterApplyingSuggestion(
        currentBreed: String,
        suggestedBreed: String,
        userOverrodeSuggestion: Bool
    ) -> String {
        userOverrodeSuggestion ? currentBreed : suggestedBreed
    }

    private static func normalizedBreed(_ breed: String?) -> String? {
        guard let breed else { return nil }
        let normalized = breed.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func entryParityBaselineID(sheepID: UUID) -> UUID {
        StableCloudUUID.derived(namespace: sheepID, name: "parity-at-entry")
    }

    static func parityCorrectionID(sheepID: UUID, sheepRevision: Int) -> UUID {
        StableCloudUUID.derived(namespace: sheepID, name: "parity-correction-\(sheepRevision)")
    }

    static func currentParity(
        eweID: UUID,
        farmID: UUID,
        before eventAt: Date,
        excluding recordID: UUID? = nil,
        records: [ReproductionRecord]
    ) -> Int {
        recordedParity(
            eweID: eweID,
            farmID: farmID,
            before: eventAt,
            excluding: recordID,
            records: records
        ) ?? 0
    }

    private static func recordedParity(
        eweID: UUID,
        farmID: UUID,
        before eventAt: Date,
        excluding recordID: UUID?,
        records: [ReproductionRecord]
    ) -> Int? {
        records
            .filter {
                $0.id != recordID &&
                    $0.farmID == farmID &&
                    $0.eweID == eweID &&
                    $0.deletedAt == nil &&
                    $0.parity.map { $0 >= 0 } == true &&
                    (($0.kind == .lambing && $0.occurredAt < eventAt) ||
                        ($0.kind == .parityBaseline && $0.occurredAt <= eventAt))
            }
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.createdAt > $1.createdAt
            }
            .first?
            .parity
    }

    static func priorParityForLambing(
        eweID: UUID,
        farmID: UUID,
        at eventAt: Date,
        existingRecordID: UUID?,
        records: [ReproductionRecord]
    ) -> Int {
        if let current = recordedParity(
            eweID: eweID,
            farmID: farmID,
            before: eventAt,
            excluding: existingRecordID,
            records: records
        ) {
            return current
        }
        guard let existingRecordID,
              let existing = records.first(where: {
                  $0.id == existingRecordID &&
                      $0.farmID == farmID &&
                      $0.eweID == eweID &&
                      $0.kind == .lambing &&
                      $0.parity.map { $0 > 0 } == true
              }),
              let parity = existing.parity else {
            return 0
        }
        // Legacy adult ewes can have their first in-app lambing recorded as a
        // later parity without a separate entry baseline. During correction,
        // the immutable original parity is sufficient to recover the prior one.
        return parity - 1
    }

    static func weightKind(lambingAt: Date, weighedAt: Date) -> LambRecordedWeightKind {
        let interval = weighedAt.timeIntervalSince(lambingAt)
        return interval >= 0 && interval <= birthWeightWindow ? .birth : .routine
    }
}
