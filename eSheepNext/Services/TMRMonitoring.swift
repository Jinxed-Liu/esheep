import Foundation
import SwiftData

struct TMRMonitoringRow: Identifiable, Sendable, Hashable {
    let id: UUID
    let farmID: UUID
    let localDay: Date
    let planID: UUID?
    let planRevision: Int?
    let formulaID: UUID
    let formulaRevision: Int
    let formulaName: String
    let penID: UUID
    let penName: String
    let meal: TMRMealPeriod
    let cutoffAt: Date
    let targetKilograms: Decimal?
    let actualKilograms: Decimal
    let differenceKilograms: Decimal?
    let differencePercent: Decimal?
    let status: TMRDeviationStatus
    let batchIDs: [UUID]
    let batchCodes: [String]
    let runIDs: [UUID]
    let isCompleted: Bool
    let completionID: UUID?
    let monitoringEnabled: Bool
    let fingerprint: String
    let isAcknowledged: Bool
}

struct TMRMonitoringSnapshot: Sendable, Hashable {
    let farmID: UUID
    let localDay: Date
    let timeZoneIdentifier: String
    let generatedAt: Date
    let monitoringConfigured: Bool
    let rows: [TMRMonitoringRow]

    var exceptionRows: [TMRMonitoringRow] {
        rows.filter { [.notFed, .low, .high, .unplanned].contains($0.status) }
    }
}

struct TMRMonitoringFilter: Sendable, Hashable {
    var formulaID: UUID?
    var planID: UUID?
    var penID: UUID?

    init(formulaID: UUID? = nil, planID: UUID? = nil, penID: UUID? = nil) {
        self.formulaID = formulaID
        self.planID = planID
        self.penID = penID
    }
}

enum TMRMonitoringAlertAdapter {
    static func alerts(from snapshot: TMRMonitoringSnapshot) -> [FarmOperationalAlert] {
        snapshot.rows.compactMap { row in
            guard row.monitoringEnabled, !row.isAcknowledged else { return nil }
            let kind: FarmOperationalAlertKind
            switch row.status {
            case .notFed: kind = .tmrNotFed
            case .low: kind = .tmrLow
            case .high: kind = .tmrHigh
            case .inProgress, .normal, .unplanned: return nil
            }
            let target = row.targetKilograms?.stableText ?? "--"
            let difference = row.differenceKilograms?.stableText ?? "--"
            let detail: String
            switch row.status {
            case .notFed:
                detail = "\(row.meal.displayName)顿目标 \(target) kg，截止后仍无有效投喂记录。"
            case .low, .high:
                detail = "\(row.meal.displayName)顿目标 \(target) kg，实际 \(row.actualKilograms.stableText) kg，差值 \(difference) kg。"
            default:
                return nil
            }
            let name = [
                kind.rawValue,
                row.planID?.uuidString.lowercased() ?? "none",
                row.penID.uuidString.lowercased(),
                String(Int(row.localDay.timeIntervalSince1970)),
                row.meal.rawValue,
                row.fingerprint
            ].joined(separator: ":")
            return FarmOperationalAlert(
                id: StableCloudUUID.derived(namespace: snapshot.farmID, name: name),
                farmID: snapshot.farmID,
                kind: kind,
                subjectID: row.penID,
                sourceEntityID: row.planID,
                conditionFingerprint: row.fingerprint,
                title: "\(row.penName) · \(kind.displayName)",
                detail: detail,
                dueAt: row.status == .high ? snapshot.generatedAt : row.cutoffAt,
                earTag: row.penName
            )
        }
    }
}

actor TMRMonitoringReadActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        farmID: UUID,
        localDay: Date,
        filter: TMRMonitoringFilter = .init(),
        now: Date = .now
    ) throws -> TMRMonitoringSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let result = try TMRMonitoringEngine.load(
            farmID: farmID,
            localDay: localDay,
            filter: filter,
            now: now,
            context: context
        )
        try Task.checkCancellation()
        return result
    }
}

enum TMRMonitoringEngine {
    static func load(
        farmID: UUID,
        localDay requestedDay: Date,
        filter: TMRMonitoringFilter = .init(),
        now: Date = .now,
        context: ModelContext
    ) throws -> TMRMonitoringSnapshot {
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: {
            $0.id == farmID && $0.deletedAt == nil
        }), let timeZone = TimeZone(identifier: farm.timeZoneIdentifier) else {
            throw FarmCommandError.missingRequiredValue("当前牧场及牧场时区")
        }
        let localDay = TMRLocalDay.start(of: requestedDay, timeZone: timeZone)
        let rule = try context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>()).first {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let monitoringConfigured = rule?.monitoringEnabledAt != nil
        let plans = try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>())
            .filter {
                $0.farmID == farmID && $0.deletedAt == nil &&
                    $0.effectiveStartDate <= localDay &&
                    localDay <= ($0.effectiveEndDate ?? .distantFuture) &&
                    (filter.formulaID == nil || $0.formulaID == filter.formulaID) &&
                    (filter.planID == nil || $0.id == filter.planID)
            }
        let planIDs = Set(plans.map(\.id))
        let planPens = try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>())
            .filter {
                $0.farmID == farmID && $0.deletedAt == nil && planIDs.contains($0.planID) &&
                    (filter.penID == nil || $0.penID == filter.penID)
            }
        let allPlanPens = try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil && planIDs.contains($0.planID) }
        let runs = try context.fetch(FetchDescriptor<TMRFeedingRunRecord>())
            .filter {
                $0.farmID == farmID && $0.deletedAt == nil &&
                    TMRLocalDay.contains($0.occurredAt, localDay: localDay, timeZone: timeZone)
            }
        let runByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        let allocations = try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>())
            .filter {
                $0.farmID == farmID && $0.deletedAt == nil && runByID[$0.runID] != nil &&
                    (filter.penID == nil || $0.penID == filter.penID)
            }
        let completions = try context.fetch(FetchDescriptor<TMRMealCompletionRecord>())
            .filter {
                $0.farmID == farmID && $0.deletedAt == nil &&
                    TMRLocalDay.start(of: $0.localDay, timeZone: timeZone) == localDay
            }
        let acknowledgements = try context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>())
            .filter {
                $0.farmID == farmID && $0.deletedAt == nil &&
                    TMRLocalDay.start(of: $0.localDay, timeZone: timeZone) == localDay
            }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>())
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>())
        let occupancy = FarmPenOccupancyIndex.make(
            farmID: farmID,
            sheep: sheep,
            transfers: transfers,
            removals: removals
        )

        var rows: [TMRMonitoringRow] = []
        for plan in plans {
            let selectedPens = planPens.filter { $0.planID == plan.id }.sorted { $0.sortOrder < $1.sortOrder }
            let everyPen = allPlanPens.filter { $0.planID == plan.id }.sorted { $0.sortOrder < $1.sortOrder }
            let meals = plan.granularity == .dailySummary
                ? [TMRMealPeriod.allDaySummary]
                : TMRMealPeriod.actualMeals.filter { plan.share(for: $0) > 0 }
            for meal in meals {
                let cutoffAt = TMRLocalDay.cutoff(
                    for: localDay,
                    minuteOfDay: plan.cutoffMinute(for: meal),
                    timeZone: timeZone
                )
                let headCounts = occupancy.sheepIDsByPen(at: cutoffAt).mapValues(\.count)
                let targets = try targetsByPen(plan: plan, planPens: everyPen, headCounts: headCounts)
                for planPen in selectedPens {
                    let matchingAllocations = allocations.filter {
                        $0.planID == plan.id && $0.penID == planPen.penID && runByID[$0.runID]?.meal == meal
                    }
                    rows.append(makePlannedRow(
                        farmID: farmID,
                        localDay: localDay,
                        plan: plan,
                        planPen: planPen,
                        meal: meal,
                        cutoffAt: cutoffAt,
                        dailyPenTarget: targets[planPen.penID],
                        allocations: matchingAllocations,
                        runByID: runByID,
                        completions: completions,
                        acknowledgements: acknowledgements,
                        monitoringConfigured: monitoringConfigured,
                        now: now
                    ))
                }
            }
        }

        let activePlanIDs = Set(plans.map(\.id))
        let unplannedGroups = Dictionary(grouping: allocations.filter {
            guard let run = runByID[$0.runID] else { return false }
            guard filter.formulaID == nil || run.formulaID == filter.formulaID else { return false }
            guard filter.planID == nil else { return false }
            return $0.planID.map { !activePlanIDs.contains($0) } ?? true
        }) { allocation in
            let run = runByID[allocation.runID]!
            return UnplannedKey(
                formulaID: run.formulaID,
                formulaRevision: run.formulaRevision,
                formulaName: run.formulaNameSnapshot,
                penID: allocation.penID,
                penName: allocation.penNameSnapshot,
                meal: run.meal
            )
        }
        for (key, values) in unplannedGroups {
            let relatedRuns = uniqueRuns(for: values, runByID: runByID)
            let actual = TMRDecimal.rounded(values.reduce(0) { $0 + $1.actualKilograms })
            let fingerprint = fingerprint(
                planID: nil,
                planRevision: nil,
                localDay: localDay,
                penID: key.penID,
                meal: key.meal,
                target: nil,
                runs: relatedRuns,
                completion: nil
            )
            rows.append(TMRMonitoringRow(
                id: StableCloudUUID.derived(
                    namespace: farmID,
                    name: "tmr-monitor:unplanned:\(Int(localDay.timeIntervalSince1970)):\(key.formulaID.uuidString.lowercased()):\(key.penID.uuidString.lowercased()):\(key.meal.rawValue)"
                ),
                farmID: farmID,
                localDay: localDay,
                planID: nil,
                planRevision: nil,
                formulaID: key.formulaID,
                formulaRevision: key.formulaRevision,
                formulaName: key.formulaName,
                penID: key.penID,
                penName: key.penName,
                meal: key.meal,
                cutoffAt: now,
                targetKilograms: nil,
                actualKilograms: actual,
                differenceKilograms: nil,
                differencePercent: nil,
                status: .unplanned,
                batchIDs: relatedRuns.map(\.batchID).uniqued(),
                batchCodes: relatedRuns.map(\.batchCodeSnapshot).uniqued(),
                runIDs: relatedRuns.map(\.id),
                isCompleted: false,
                completionID: nil,
                monitoringEnabled: false,
                fingerprint: fingerprint,
                isAcknowledged: false
            ))
        }

        rows.sort(by: rowOrder)
        return TMRMonitoringSnapshot(
            farmID: farmID,
            localDay: localDay,
            timeZoneIdentifier: farm.timeZoneIdentifier,
            generatedAt: now,
            monitoringConfigured: monitoringConfigured,
            rows: rows
        )
    }

    private struct UnplannedKey: Hashable {
        let formulaID: UUID
        let formulaRevision: Int
        let formulaName: String
        let penID: UUID
        let penName: String
        let meal: TMRMealPeriod
    }

    private static func targetsByPen(
        plan: TMRFeedingPlanRecord,
        planPens: [TMRFeedingPlanPenRecord],
        headCounts: [UUID: Int]
    ) throws -> [UUID: Decimal] {
        guard !planPens.isEmpty else { return [:] }
        let totalHeadCount = planPens.reduce(0) { $0 + headCounts[$1.penID, default: 0] }
        let groupTarget: Decimal
        do {
            groupTarget = try TMRCalculator.targetGroupDailyTotal(
                formulaDailyTotal: plan.formulaDailyTotalKilograms,
                basis: plan.quantityBasis,
                scaleMode: plan.scaleMode,
                referenceHeadCount: plan.referenceHeadCountSnapshot,
                targetHeadCount: totalHeadCount
            )
        } catch TMRDomainError.invalidTargetHeadCount {
            return [:]
        }
        let inputs = planPens.map {
            TMRPenAllocationInput(
                id: $0.penID,
                headCount: headCounts[$0.penID, default: 0],
                fixedShare: $0.fixedShare
            )
        }
        do {
            return Dictionary(uniqueKeysWithValues: try TMRCalculator.allocateToPens(
                totalKilograms: groupTarget,
                inputs: inputs,
                mode: plan.allocationMode
            ).map { ($0.id, $0.kilograms) })
        } catch TMRDomainError.invalidPenHeadCount {
            return [:]
        }
    }

    private static func makePlannedRow(
        farmID: UUID,
        localDay: Date,
        plan: TMRFeedingPlanRecord,
        planPen: TMRFeedingPlanPenRecord,
        meal: TMRMealPeriod,
        cutoffAt: Date,
        dailyPenTarget: Decimal?,
        allocations: [TMRFeedingAllocationRecord],
        runByID: [UUID: TMRFeedingRunRecord],
        completions: [TMRMealCompletionRecord],
        acknowledgements: [TMRDeviationAcknowledgementRecord],
        monitoringConfigured: Bool,
        now: Date
    ) -> TMRMonitoringRow {
        let target = dailyPenTarget.map { TMRDecimal.rounded($0 * plan.share(for: meal)) }
        let actual = TMRDecimal.rounded(allocations.reduce(0) { $0 + $1.actualKilograms })
        let completion = completions.first {
            $0.planID == plan.id && $0.penID == planPen.penID && $0.meal == meal
        }
        let evaluation = TMRCalculator.evaluateDeviation(
            targetKilograms: target,
            actualKilograms: actual,
            tolerancePercent: plan.tolerancePercent,
            isCompleted: completion != nil,
            cutoffReached: now >= cutoffAt
        )
        let relatedRuns = uniqueRuns(for: allocations, runByID: runByID)
        let fingerprint = fingerprint(
            planID: plan.id,
            planRevision: plan.revision,
            localDay: localDay,
            penID: planPen.penID,
            meal: meal,
            target: target,
            runs: relatedRuns,
            completion: completion
        )
        let acknowledged = acknowledgements.contains {
            $0.planID == plan.id && $0.planRevision == plan.revision &&
                $0.penID == planPen.penID && $0.meal == meal && $0.fingerprint == fingerprint
        }
        return TMRMonitoringRow(
            id: StableCloudUUID.derived(
                namespace: plan.id,
                name: "tmr-monitor:\(Int(localDay.timeIntervalSince1970)):\(planPen.penID.uuidString.lowercased()):\(meal.rawValue)"
            ),
            farmID: farmID,
            localDay: localDay,
            planID: plan.id,
            planRevision: plan.revision,
            formulaID: plan.formulaID,
            formulaRevision: plan.formulaRevision,
            formulaName: plan.formulaNameSnapshot,
            penID: planPen.penID,
            penName: planPen.penNameSnapshot,
            meal: meal,
            cutoffAt: cutoffAt,
            targetKilograms: evaluation.targetKilograms,
            actualKilograms: evaluation.actualKilograms,
            differenceKilograms: evaluation.differenceKilograms,
            differencePercent: evaluation.differencePercent,
            status: evaluation.status,
            batchIDs: relatedRuns.map(\.batchID).uniqued(),
            batchCodes: relatedRuns.map(\.batchCodeSnapshot).uniqued(),
            runIDs: relatedRuns.map(\.id),
            isCompleted: completion != nil,
            completionID: completion?.id,
            monitoringEnabled: monitoringConfigured && plan.monitoringEnabled,
            fingerprint: fingerprint,
            isAcknowledged: acknowledged
        )
    }

    private static func uniqueRuns(
        for allocations: [TMRFeedingAllocationRecord],
        runByID: [UUID: TMRFeedingRunRecord]
    ) -> [TMRFeedingRunRecord] {
        let ids = Set(allocations.map(\.runID))
        return ids.compactMap { runByID[$0] }.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func fingerprint(
        planID: UUID?,
        planRevision: Int?,
        localDay: Date,
        penID: UUID,
        meal: TMRMealPeriod,
        target: Decimal?,
        runs: [TMRFeedingRunRecord],
        completion: TMRMealCompletionRecord?
    ) -> String {
        let facts = runs.map {
            "\($0.id.uuidString.lowercased()):\($0.revision):\($0.batchRevisionAfter)"
        }.joined(separator: ",")
        let completionFact = completion.map {
            "\($0.id.uuidString.lowercased()):\($0.revision):\($0.completedAt.timeIntervalSince1970)"
        } ?? "open"
        let value = [
            planID?.uuidString.lowercased() ?? "unplanned",
            String(planRevision ?? 0),
            String(Int(localDay.timeIntervalSince1970)),
            penID.uuidString.lowercased(),
            meal.rawValue,
            target?.stableText ?? "none",
            facts,
            completionFact
        ].joined(separator: "|")
        return CloudPayloadDigest.hex(for: Data(value.utf8))
    }

    private static func rowOrder(_ lhs: TMRMonitoringRow, _ rhs: TMRMonitoringRow) -> Bool {
        if lhs.penName != rhs.penName { return lhs.penName.localizedStandardCompare(rhs.penName) == .orderedAscending }
        if lhs.meal.sortOrder != rhs.meal.sortOrder { return lhs.meal.sortOrder < rhs.meal.sortOrder }
        if lhs.formulaName != rhs.formulaName { return lhs.formulaName.localizedStandardCompare(rhs.formulaName) == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
