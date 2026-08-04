import Foundation

struct WeaningGainSample: Identifiable, Sendable, Hashable {
    let id: UUID
    let sheepID: UUID
    let kilograms: Double
    let occurredAt: Date

    var kilogramsText: String {
        let formatted = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            kilograms
        )
        return Decimal.stable(formatted)?.stableText ?? formatted
    }
}

struct WeaningGainResult: Sendable, Hashable {
    let baseline: WeaningGainSample
    let intervalDays: Int
    let kilogramsPerDay: Double

    var gramsPerDay: Double { kilogramsPerDay * 1_000 }

    var kilogramsPerDayText: String {
        let formatted = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            kilogramsPerDay
        )
        return Decimal.stable(formatted)?.stableText ?? formatted
    }
}

enum WeaningGainSemantics {
    static func samples(from records: [WeightRecord], farmID: UUID) -> [WeaningGainSample] {
        records.compactMap { record in
            guard record.farmID == farmID,
                  record.deletedAt == nil else { return nil }
            return WeaningGainSample(
                id: record.id,
                sheepID: record.sheepID,
                kilograms: NSDecimalNumber(decimal: record.kilograms).doubleValue,
                occurredAt: record.occurredAt
            )
        }
    }

    static func earliestBaseline(
        sheepID: UUID,
        birthAt: Date?,
        weaningAt: Date,
        samples: [WeaningGainSample]
    ) -> WeaningGainSample? {
        samples
            .filter { sample in
                sample.sheepID == sheepID &&
                    sample.kilograms.isFinite &&
                    sample.kilograms > 0 &&
                    sample.occurredAt < weaningAt &&
                    (birthAt.map { sample.occurredAt >= $0 } ?? true)
            }
            .min { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    static func calculate(
        sheepID: UUID,
        birthAt: Date?,
        weaningAt: Date,
        weaningWeight: Double,
        samples: [WeaningGainSample]
    ) -> WeaningGainResult? {
        guard weaningWeight.isFinite,
              weaningWeight > 0,
              let baseline = earliestBaseline(
                  sheepID: sheepID,
                  birthAt: birthAt,
                  weaningAt: weaningAt,
                  samples: samples
              ) else { return nil }
        let intervalDays = FarmAnalyticsDate.days(from: baseline.occurredAt, to: weaningAt)
        guard intervalDays > 0, weaningWeight > baseline.kilograms else { return nil }
        return WeaningGainResult(
            baseline: baseline,
            intervalDays: intervalDays,
            kilogramsPerDay: (weaningWeight - baseline.kilograms) / Double(intervalDays)
        )
    }
}
