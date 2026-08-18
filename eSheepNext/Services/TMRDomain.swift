import Foundation

enum TMRDomainError: LocalizedError, Equatable {
    case emptyFormula
    case nonPositiveQuantity
    case invalidReferenceHeadCount
    case invalidTargetHeadCount
    case invalidMealShares
    case emptyPens
    case duplicatePen
    case invalidPenHeadCount
    case invalidFixedShares
    case incompatibleAllDayAndMealRecords
    case insufficientBatchBalance(available: Decimal, requested: Decimal)

    var errorDescription: String? {
        switch self {
        case .emptyFormula: "TMR 配方至少需要一种原料。"
        case .nonPositiveQuantity: "用量必须大于 0。"
        case .invalidReferenceHeadCount: "整群配方按羊数缩放前，必须填写大于 0 的参考羊数。"
        case .invalidTargetHeadCount: "目标圈舍的有效羊数必须大于 0。"
        case .invalidMealShares: "启用的早、中、晚顿次比例合计必须为 100%。"
        case .emptyPens: "至少选择一个圈舍。"
        case .duplicatePen: "同一个圈舍不能重复选择。"
        case .invalidPenHeadCount: "按羊数分配时，每个圈舍的有效羊数不能小于 0，且合计必须大于 0。"
        case .invalidFixedShares: "固定圈舍分配比例合计必须为 100%。"
        case .incompatibleAllDayAndMealRecords: "同一计划、日期和圈舍不能同时记录全天汇总与早、中、晚投喂。"
        case .insufficientBatchBalance(let available, let requested):
            "TMR 批次余额不足：可用 \(available.stableText) kg，需要 \(requested.stableText) kg。"
        }
    }
}

struct TMRMealShares: Equatable, Sendable {
    let morning: Decimal
    let noon: Decimal
    let evening: Decimal

    init(morning: Decimal, noon: Decimal, evening: Decimal) throws {
        guard morning >= 0, noon >= 0, evening >= 0,
              morning + noon + evening == 1 else {
            throw TMRDomainError.invalidMealShares
        }
        self.morning = morning
        self.noon = noon
        self.evening = evening
    }

    var enabledMeals: [TMRMealPeriod] {
        TMRMealPeriod.actualMeals.filter { share(for: $0) > 0 }
    }

    func share(for meal: TMRMealPeriod) -> Decimal {
        switch meal {
        case .morning: morning
        case .noon: noon
        case .evening: evening
        case .allDaySummary: 1
        }
    }
}

struct TMRPenAllocationInput: Equatable, Sendable, Identifiable {
    let id: UUID
    let headCount: Int
    let fixedShare: Decimal?

    init(id: UUID, headCount: Int, fixedShare: Decimal? = nil) {
        self.id = id
        self.headCount = headCount
        self.fixedShare = fixedShare
    }
}

struct TMRPenAllocationResult: Equatable, Sendable, Identifiable {
    let id: UUID
    let share: Decimal
    let kilograms: Decimal
}

struct TMRDeviationEvaluation: Equatable, Sendable {
    let status: TMRDeviationStatus
    let targetKilograms: Decimal?
    let actualKilograms: Decimal
    let differenceKilograms: Decimal?
    let differencePercent: Decimal?
}

enum TMRDecimal {
    static let weightScale: Int = 3

    static func rounded(_ value: Decimal, scale: Int = weightScale) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }

    static func percentText(fromFraction fraction: Decimal) -> String {
        rounded(fraction * 100, scale: 2).stableText
    }
}

enum TMRCalculator {
    static func formulaDailyTotal(_ components: [TMRFormulaComponentSnapshot]) throws -> Decimal {
        guard !components.isEmpty else { throw TMRDomainError.emptyFormula }
        guard components.allSatisfy({ $0.quantity > 0 }) else {
            throw TMRDomainError.nonPositiveQuantity
        }
        return TMRDecimal.rounded(components.reduce(Decimal.zero) { $0 + $1.quantity })
    }

    static func perHeadDailyTotal(
        formulaDailyTotal: Decimal,
        basis: TMRFormulaQuantityBasis,
        referenceHeadCount: Int?
    ) throws -> Decimal {
        guard formulaDailyTotal > 0 else { throw TMRDomainError.nonPositiveQuantity }
        switch basis {
        case .perHeadDaily:
            return TMRDecimal.rounded(formulaDailyTotal)
        case .wholeGroupDaily:
            guard let referenceHeadCount, referenceHeadCount > 0 else {
                throw TMRDomainError.invalidReferenceHeadCount
            }
            return TMRDecimal.rounded(formulaDailyTotal / Decimal(referenceHeadCount))
        }
    }

    static func wholeGroupDailyTotal(
        formulaDailyTotal: Decimal,
        basis: TMRFormulaQuantityBasis,
        referenceHeadCount: Int?
    ) throws -> Decimal {
        guard formulaDailyTotal > 0 else { throw TMRDomainError.nonPositiveQuantity }
        switch basis {
        case .wholeGroupDaily:
            return TMRDecimal.rounded(formulaDailyTotal)
        case .perHeadDaily:
            guard let referenceHeadCount, referenceHeadCount > 0 else {
                throw TMRDomainError.invalidReferenceHeadCount
            }
            return TMRDecimal.rounded(formulaDailyTotal * Decimal(referenceHeadCount))
        }
    }

    static func targetGroupDailyTotal(
        formulaDailyTotal: Decimal,
        basis: TMRFormulaQuantityBasis,
        scaleMode: TMRFormulaScaleMode,
        referenceHeadCount: Int?,
        targetHeadCount: Int
    ) throws -> Decimal {
        guard formulaDailyTotal > 0 else { throw TMRDomainError.nonPositiveQuantity }
        guard targetHeadCount > 0 else { throw TMRDomainError.invalidTargetHeadCount }

        switch basis {
        case .perHeadDaily:
            return TMRDecimal.rounded(formulaDailyTotal * Decimal(targetHeadCount))
        case .wholeGroupDaily:
            if scaleMode == .fixedWholeAmount {
                return TMRDecimal.rounded(formulaDailyTotal)
            }
            guard let referenceHeadCount, referenceHeadCount > 0 else {
                throw TMRDomainError.invalidReferenceHeadCount
            }
            return TMRDecimal.rounded(
                formulaDailyTotal * Decimal(targetHeadCount) / Decimal(referenceHeadCount)
            )
        }
    }

    static func allocateToPens(
        totalKilograms: Decimal,
        inputs: [TMRPenAllocationInput],
        mode: TMRPenAllocationMode
    ) throws -> [TMRPenAllocationResult] {
        guard totalKilograms >= 0 else { throw TMRDomainError.nonPositiveQuantity }
        guard !inputs.isEmpty else { throw TMRDomainError.emptyPens }
        guard Set(inputs.map(\.id)).count == inputs.count else { throw TMRDomainError.duplicatePen }

        let shares: [Decimal]
        switch mode {
        case .dynamicHeadCount:
            guard inputs.allSatisfy({ $0.headCount >= 0 }) else {
                throw TMRDomainError.invalidPenHeadCount
            }
            let totalHeadCount = inputs.reduce(0) { $0 + $1.headCount }
            guard totalHeadCount > 0 else { throw TMRDomainError.invalidPenHeadCount }
            shares = inputs.map { Decimal($0.headCount) / Decimal(totalHeadCount) }
        case .fixedShare:
            let values = inputs.map { $0.fixedShare ?? -1 }
            guard values.allSatisfy({ $0 >= 0 }), values.reduce(0, +) == 1 else {
                throw TMRDomainError.invalidFixedShares
            }
            shares = values
        }

        var assigned = Decimal.zero
        return inputs.indices.map { index in
            let kilograms: Decimal
            if index == inputs.indices.last {
                kilograms = TMRDecimal.rounded(totalKilograms - assigned)
            } else {
                kilograms = TMRDecimal.rounded(totalKilograms * shares[index])
                assigned += kilograms
            }
            return TMRPenAllocationResult(
                id: inputs[index].id,
                share: TMRDecimal.rounded(shares[index], scale: 6),
                kilograms: kilograms
            )
        }
    }

    static func mealTarget(dailyTarget: Decimal, meal: TMRMealPeriod, shares: TMRMealShares) -> Decimal {
        TMRDecimal.rounded(dailyTarget * shares.share(for: meal))
    }

    static func proportionalAmounts(
        totalKilograms: Decimal,
        componentQuantities: [Decimal]
    ) throws -> [Decimal] {
        guard totalKilograms > 0 else { throw TMRDomainError.nonPositiveQuantity }
        guard !componentQuantities.isEmpty else { throw TMRDomainError.emptyFormula }
        guard componentQuantities.allSatisfy({ $0 > 0 }) else {
            throw TMRDomainError.nonPositiveQuantity
        }
        let sourceTotal = componentQuantities.reduce(0, +)
        var assigned = Decimal.zero
        return componentQuantities.indices.map { index in
            if index == componentQuantities.indices.last {
                return TMRDecimal.rounded(totalKilograms - assigned)
            }
            let value = TMRDecimal.rounded(totalKilograms * componentQuantities[index] / sourceTotal)
            assigned += value
            return value
        }
    }

    static func batchBalance(movements: [TMRBatchMovementRecord]) -> Decimal {
        TMRDecimal.rounded(
            movements.lazy
                .filter { $0.deletedAt == nil }
                .reduce(Decimal.zero) { $0 + $1.deltaKilograms }
        )
    }

    static func validateWithdrawal(available: Decimal, requested: Decimal) throws {
        guard requested > 0 else { throw TMRDomainError.nonPositiveQuantity }
        guard requested <= available else {
            throw TMRDomainError.insufficientBatchBalance(available: available, requested: requested)
        }
    }

    static func evaluateDeviation(
        targetKilograms: Decimal?,
        actualKilograms: Decimal,
        tolerancePercent: Decimal,
        isCompleted: Bool,
        cutoffReached: Bool
    ) -> TMRDeviationEvaluation {
        guard let targetKilograms, targetKilograms > 0 else {
            return TMRDeviationEvaluation(
                status: actualKilograms > 0 ? .unplanned : .inProgress,
                targetKilograms: nil,
                actualKilograms: actualKilograms,
                differenceKilograms: nil,
                differencePercent: nil
            )
        }

        let difference = TMRDecimal.rounded(actualKilograms - targetKilograms)
        let percent = TMRDecimal.rounded(difference / targetKilograms * 100, scale: 2)
        let tolerance = max(0, tolerancePercent)

        let status: TMRDeviationStatus
        if percent > tolerance {
            status = .high
        } else if !isCompleted && !cutoffReached {
            status = .inProgress
        } else if actualKilograms == 0 {
            status = .notFed
        } else if percent < -tolerance {
            status = .low
        } else {
            status = .normal
        }

        return TMRDeviationEvaluation(
            status: status,
            targetKilograms: targetKilograms,
            actualKilograms: actualKilograms,
            differenceKilograms: difference,
            differencePercent: percent
        )
    }
}

enum TMRMealConflictPolicy {
    static func validate(existingMeals: [TMRMealPeriod], adding meal: TMRMealPeriod) throws {
        let hasAllDay = existingMeals.contains(.allDaySummary)
        let hasActualMeal = existingMeals.contains { $0 != .allDaySummary }
        if (meal == .allDaySummary && hasActualMeal) || (meal != .allDaySummary && hasAllDay) {
            throw TMRDomainError.incompatibleAllDayAndMealRecords
        }
    }
}

enum TMRLocalDay {
    static func start(of date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    static func cutoff(
        for date: Date,
        minuteOfDay: Int,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .minute, value: max(0, min(1_439, minuteOfDay)), to: start) ?? start
    }

    static func contains(_ date: Date, localDay: Date, timeZone: TimeZone) -> Bool {
        start(of: date, timeZone: timeZone) == start(of: localDay, timeZone: timeZone)
    }
}
