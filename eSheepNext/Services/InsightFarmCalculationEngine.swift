import Foundation
import SwiftData

/// A bounded, deterministic data-frame style calculator for the agent harness.
/// Natural-language meaning stays with the model; this engine only executes a
/// typed source -> filter -> window -> transform -> group -> reduce plan over
/// local farm facts. Adding a new question does not add a phrase detector.
struct InsightFarmCalculationEngine {
    static let toolName = "calculate_farm_data"
    static let persistedEvidenceToolName = "calculate_farm_data_evidence"

    struct GroundedOutput: Equatable {
        let calculationID: String
        let contractVersion: String
        let canonicalArgumentsJSON: String
        let timeZoneIdentifier: String
        let resultUnit: String
        let observationCount: Int
        let isComplete: Bool

        init?(toolOutput: String) {
            guard let data = toolOutput.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["evidence_kind"] as? String == "farm_calculation",
                  let calculationID = object["calculation_id"] as? String,
                  let contractVersion = object["contract_version"] as? String,
                  contractVersion == FarmFactContract.version,
                  let canonicalArguments = object["canonical_arguments"] as? [String: Any],
                  let canonicalData = try? JSONSerialization.data(
                    withJSONObject: canonicalArguments,
                    options: [.sortedKeys]
                  ),
                  let timeZoneIdentifier = object["time_zone"] as? String,
                  let resultUnit = object["result_unit"] as? String,
                  let observationCount = object["observation_count"] as? Int,
                  let isComplete = object["is_complete"] as? Bool else {
                return nil
            }
            self.calculationID = calculationID
            self.contractVersion = contractVersion
            self.canonicalArgumentsJSON = String(decoding: canonicalData, as: UTF8.self)
            self.timeZoneIdentifier = timeZoneIdentifier
            self.resultUnit = resultUnit
            self.observationCount = observationCount
            self.isComplete = isComplete
        }
    }

    static func canonicalArguments(in toolOutput: String) -> [String: Any]? {
        guard let data = toolOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["evidence_kind"] as? String == "farm_calculation",
              object["contract_version"] as? String == FarmFactContract.version else {
            return nil
        }
        return object["canonical_arguments"] as? [String: Any]
    }

    private enum SamplePolicy: String {
        case recordedOnly = "recorded_only"
        case canonicalTimeline = "canonical_timeline"
    }

    private enum Cohort: String {
        case allProfiles = "all_profiles"
        case currentInHerd = "current_in_herd"
        case removed
    }

    private enum PenMembership: String {
        case atCutoff = "at_cutoff"
        case atMeasurement = "at_measurement"
    }

    private enum Partition: String {
        case sheep
        case none
    }

    private enum Window: String {
        case none
        case adjacent
        case firstToLast = "first_to_last"
    }

    private enum Transform: String {
        case value
        case difference
        case elapsedDays = "elapsed_days"
        case differencePerDay = "difference_per_day"
    }

    private enum AnalysisScope: String {
        /// Return exactly the grouping requested by the plan. This is for a
        /// user who explicitly narrowed the question to one view.
        case focused
        /// Return the complete business view for a cohort rate: overall,
        /// actual adjacent weighing intervals, production batches, and the
        /// sheep lifecycle outcome at the cutoff.
        case complete
    }

    private enum Group: String {
        case none
        case weighingInterval = "weighing_interval"
        case intervalEndDay = "interval_end_day"
        case intervalEndMonth = "interval_end_month"
        case productionBatch = "production_batch"
        case lifecycleStatus = "lifecycle_status"
        case sheep
        case pen
    }

    private enum Reduction: String {
        case records
        case count
        case sum
        case average
        case minimum
        case maximum
    }

    private enum Selection: String {
        case all
        case latest
    }

    private struct Request {
        let samplePolicy: SamplePolicy
        let cohort: Cohort
        let penMembership: PenMembership
        let penName: String
        let penNames: [String]
        let batchID: UUID?
        let earTag: String
        let breed: String
        let sex: String
        let dateFrom: Date?
        let dateTo: Date?
        let asOf: Date
        let hasExplicitAsOf: Bool
        let partition: Partition
        let window: Window
        let transform: Transform
        let analysisScope: AnalysisScope
        let group: Group
        let reduction: Reduction
        let selection: Selection
        let limit: Int
        let calendar: Calendar
        let timeZoneIdentifier: String
        let canonicalArguments: [String: Any]
    }

    private struct Observation {
        let sheepID: UUID
        let earTag: String
        let penName: String
        let productionBatch: String
        let batchAttributionQuality: BatchAttributionQuality
        let lifecycleStatus: String
        let startAt: Date?
        let endAt: Date
        let startValue: Double?
        let endValue: Double
        let elapsedDays: Int?
        let value: Double
    }

    private struct Audit {
        var stateBasis = Set<String>()
        var unknownStateCount = 0
        var projectionMismatchCount = 0
        var excludedNonContinuousPenIntervals = 0
        var excludedNonPositiveDayIntervals = 0
    }

    private enum BatchAttributionQuality: String {
        case assigned
        case unassigned
        case crossBatch = "cross_batch"
        case overlapping
        case missingDefinition = "missing_definition"
    }

    private struct BatchAttribution {
        let label: String
        let quality: BatchAttributionQuality
    }

    private struct RenderedGroups {
        let values: [[String: Any]]
        let totalCount: Int
        let isComplete: Bool
    }

    func execute(
        arguments: [String: Any],
        farmID: UUID,
        context: ModelContext,
        now: Date = .now
    ) throws -> String {
        try Task.checkCancellation()
        let farmTimeZone = try farmTimeZone(farmID: farmID, context: context)
        let request = try parse(
            arguments,
            now: now,
            timeZone: farmTimeZone.value,
            timeZoneIdentifier: farmTimeZone.identifier
        )
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        let weights = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let needsCanonicalSources = request.samplePolicy == .canonicalTimeline
        let weanings: [WeaningRecord] = needsCanonicalSources
            ? try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            })) : []
        let reproduction: [ReproductionRecord] = needsCanonicalSources
            ? try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            })) : []
        let offspring: [LambingOffspringRecord] = needsCanonicalSources
            ? try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
                $0.farmID == farmID
            })) : []
        try Task.checkCancellation()
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let productionBatches = try context.fetch(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let batchMemberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        if let batchID = request.batchID,
           !productionBatches.contains(where: { $0.id == batchID }) {
            throw InsightToolError.invalidArguments("batch_id not found in current farm")
        }
        let transfersBySheep = Dictionary(grouping: transfers, by: \.sheepID)
        let removalsBySheep = Dictionary(grouping: removals, by: \.sheepID)
        let membershipsBySheep = Dictionary(grouping: batchMemberships, by: \.sheepID)
        let penByID = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0) })
        let batchLabels = batchLabels(for: productionBatches)
        var resolvedPenIDs = Set<UUID>()
        let selectedPens = try request.penNames.compactMap { name -> PenRecord? in
            guard let pen = try resolvePen(named: name, from: pens), resolvedPenIDs.insert(pen.id).inserted else { return nil }
            return pen
        }
        let selectedPenIDs = Set(selectedPens.map(\.id))
        let usesAppWeightGainEngine = request.samplePolicy == .canonicalTimeline &&
            request.penMembership == .atCutoff && request.partition == .sheep &&
            request.window == .adjacent && request.transform == .differencePerDay

        var audit = Audit()
        var stateFactsBySheep = [UUID: FarmSheepStateFact]()
        var eligibleSheep = [SheepRecord]()
        eligibleSheep.reserveCapacity(sheep.count)
        for item in sheep where !item.isHistoricalArchive {
            try Task.checkCancellation()
            let cutoff: FarmFactContract.StateCutoff = request.hasExplicitAsOf
                ? .historical(request.asOf)
                : .current(request.asOf)
            let fact = FarmSheepStateResolver.resolve(
                item,
                cutoff: cutoff,
                transfers: transfersBySheep[item.id] ?? [],
                removals: removalsBySheep[item.id] ?? []
            )
            audit.stateBasis.insert(fact.basis.rawValue)
            if !fact.isKnown { audit.unknownStateCount += 1 }
            if !fact.projectionMatchesStoredState { audit.projectionMismatchCount += 1 }
            stateFactsBySheep[item.id] = fact

            let cohortMatches: Bool
            switch request.cohort {
            case .allProfiles:
                cohortMatches = fact.isIncluded && item.enteredAt <= request.asOf
            case .currentInHerd:
                cohortMatches = fact.isPresent
            case .removed:
                cohortMatches = fact.isIncluded && fact.isKnown && fact.status != .active
            }
            guard cohortMatches,
                  textMatches(item.earTag, filter: request.earTag),
                  textMatches(item.breed, filter: request.breed),
                  request.sex.isEmpty || item.sex.rawValue == request.sex else {
                continue
            }
            if !usesAppWeightGainEngine, !selectedPenIDs.isEmpty, request.penMembership == .atCutoff,
               !(fact.penID.map(selectedPenIDs.contains) ?? false) {
                continue
            }
            eligibleSheep.append(item)
        }

        var snapshot = FarmAnalyticsSnapshot.make(
            farmID: farmID,
            sheep: usesAppWeightGainEngine ? eligibleSheep : sheep,
            pens: pens,
            weights: weights.filter { $0.occurredAt <= request.asOf },
            weanings: weanings.filter { $0.occurredAt <= request.asOf },
            reproduction: reproduction.filter { $0.occurredAt <= request.asOf },
            offspring: offspring,
            removals: removals,
            transfers: transfers,
            memberships: batchMemberships,
            feeds: [],
            feedLines: [],
            timeZoneIdentifier: request.timeZoneIdentifier,
            factsReadAt: min(now, request.asOf)
        )
        if usesAppWeightGainEngine {
            snapshot = clippingWeightSources(snapshot, from: request.dateFrom, through: request.asOf)
        }
        let nativeResult: WeightGainAnalysisResult?
        if usesAppWeightGainEngine {
            let scope: WeightGainAnalysisScope
            if let batchID = request.batchID {
                scope = selectedPenIDs.isEmpty ? .batch(batchID)
                    : .batchAndPens(batchID: batchID, penIDs: selectedPenIDs)
            } else {
                scope = selectedPenIDs.isEmpty ? .farm : .pens(selectedPenIDs)
            }
            try Task.checkCancellation()
            nativeResult = WeightGainAnalyticsEngine.calculate(
                snapshot: snapshot,
                filter: WeightGainAnalysisFilter(
                    scope: scope,
                    mode: .period,
                    startDate: request.dateFrom ?? snapshot.weightSamples.map(\.occurredAt).min() ?? request.asOf,
                    endDate: min(request.dateTo ?? request.asOf, request.asOf),
                    sampleScope: .all
                )
            )
        } else {
            nativeResult = nil
        }
        try Task.checkCancellation()
        let rawSamples: [SheepWeightSample]
        switch request.samplePolicy {
        case .recordedOnly:
            rawSamples = snapshot.weights.map {
                SheepWeightSample(
                    id: $0.id,
                    sheepID: $0.sheepID,
                    kilograms: $0.kilograms,
                    occurredAt: $0.occurredAt,
                    source: .weighing
                )
            }
        case .canonicalTimeline:
            rawSamples = SheepWeightSampleBuilder.dailyCanonical(
                snapshot.weightSamples,
                calendar: request.calendar
            )
        }

        let eligibleIDs = Set(eligibleSheep.map(\.id))
        let candidateSamples = rawSamples.filter { sample in
            guard eligibleIDs.contains(sample.sheepID),
                  sample.occurredAt <= request.asOf,
                  request.dateFrom.map({ sample.occurredAt >= $0 }) ?? true,
                  request.dateTo.map({ sample.occurredAt <= $0 }) ?? true else {
                return false
            }
            return true
        }
        let samplesBySheep = Dictionary(grouping: candidateSamples, by: \.sheepID)
            .mapValues { values in
                values.sorted {
                    if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            }
        var observations: [Observation] = []
        var insufficientProfiles = 0
        var relevantProfiles = 0
        var qualifiedSampleIDs = Set<UUID>()
        if let nativeResult {
            let rowsBySheep = Dictionary(uniqueKeysWithValues: nativeResult.rows.map { ($0.sheepID, $0) })
            relevantProfiles = nativeResult.objectCount
            insufficientProfiles = nativeResult.missingPairCount
            for interval in nativeResult.intervals {
                try Task.checkCancellation()
                guard let row = rowsBySheep[interval.sheepID] else { continue }
                let batch = batchAttribution(
                    sheepID: interval.sheepID,
                    startAt: interval.startDate,
                    endAt: interval.endDate,
                    memberships: membershipsBySheep[interval.sheepID] ?? [],
                    labelsByID: batchLabels
                )
                observations.append(Observation(
                    sheepID: interval.sheepID,
                    earTag: row.earTag,
                    penName: row.analysisEndPenName ?? "未分圈",
                    productionBatch: batch.label,
                    batchAttributionQuality: batch.quality,
                    lifecycleStatus: lifecycleStatus(for: stateFactsBySheep[interval.sheepID]),
                    startAt: interval.startDate,
                    endAt: interval.endDate,
                    startValue: interval.startWeight,
                    endValue: interval.endWeight,
                    elapsedDays: interval.intervalDays,
                    value: interval.gramsPerDay / 1_000
                ))
                qualifiedSampleIDs.insert(interval.startSample.id)
                qualifiedSampleIDs.insert(interval.endSample.id)
            }
        } else {
            for profile in eligibleSheep.sorted(by: { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }) {
                try Task.checkCancellation()
                let samples = samplesBySheep[profile.id] ?? []
                let profileTransfers = transfersBySheep[profile.id] ?? []
                let hasRelevantMeasurement: Bool
                if !selectedPenIDs.isEmpty, request.penMembership == .atMeasurement {
                    hasRelevantMeasurement = samples.contains { sample in
                        FarmHistoryTimeline.pen(
                            for: profile,
                            at: sample.occurredAt,
                            transfers: profileTransfers
                        ).map(selectedPenIDs.contains) ?? false
                    }
                } else {
                    hasRelevantMeasurement = true
                }
                if hasRelevantMeasurement { relevantProfiles += 1 }

                let intervals: [(SheepWeightSample?, SheepWeightSample)]
                switch request.window {
                case .none:
                    intervals = samples.map { (nil, $0) }
                case .adjacent:
                    intervals = Array(zip(samples, samples.dropFirst())).map { ($0.0, $0.1) }
                case .firstToLast:
                    if let first = samples.first, let last = samples.last, first.id != last.id {
                        intervals = [(first, last)]
                    } else {
                        intervals = []
                    }
                }
                let observationCountBeforeProfile = observations.count
                for (start, end) in intervals {
                    let startPenID = start.map {
                        FarmHistoryTimeline.pen(
                            for: profile,
                            at: $0.occurredAt,
                            transfers: profileTransfers
                        )
                    } ?? nil
                    let endPenID = FarmHistoryTimeline.pen(
                        for: profile,
                        at: end.occurredAt,
                        transfers: profileTransfers
                    )
                    if !selectedPenIDs.isEmpty, request.penMembership == .atMeasurement {
                        let isQualified: Bool
                        if let start {
                            isQualified = intervalIsContinuouslyInPens(
                                selectedPenIDs,
                                startAt: start.occurredAt,
                                endAt: end.occurredAt,
                                startPenID: startPenID,
                                endPenID: endPenID,
                                transfers: profileTransfers
                            )
                        } else {
                            isQualified = endPenID.map(selectedPenIDs.contains) ?? false
                        }
                        guard isQualified else {
                            if (startPenID.map(selectedPenIDs.contains) ?? false) || (endPenID.map(selectedPenIDs.contains) ?? false) {
                                audit.excludedNonContinuousPenIntervals += 1
                            }
                            continue
                        }
                    }
                    let startDay = start.map { request.calendar.startOfDay(for: $0.occurredAt) }
                    let endDay = request.calendar.startOfDay(for: end.occurredAt)
                    let elapsedDays = startDay.flatMap {
                        request.calendar.dateComponents([.day], from: $0, to: endDay).day
                    }
                    let value: Double
                    switch request.transform {
                    case .value:
                        value = end.kilograms
                    case .difference:
                        guard let start else { continue }
                        value = end.kilograms - start.kilograms
                    case .elapsedDays:
                        guard let elapsedDays else { continue }
                        value = Double(elapsedDays)
                    case .differencePerDay:
                        guard let start, let elapsedDays, elapsedDays > 0 else {
                            audit.excludedNonPositiveDayIntervals += 1
                            continue
                        }
                        value = (end.kilograms - start.kilograms) / Double(elapsedDays)
                    }
                    guard value.isFinite else { continue }
                    let batch = batchAttribution(
                        sheepID: profile.id,
                        startAt: start?.occurredAt,
                        endAt: end.occurredAt,
                        memberships: membershipsBySheep[profile.id] ?? [],
                        labelsByID: batchLabels
                    )
                    let lifecycle = lifecycleStatus(
                        for: stateFactsBySheep[profile.id]
                    )
                    observations.append(Observation(
                        sheepID: profile.id,
                        earTag: profile.earTag,
                        penName: (request.penMembership == .atCutoff ? stateFactsBySheep[profile.id]?.penID : endPenID)
                            .flatMap { penByID[$0]?.name } ?? "未分圈",
                        productionBatch: batch.label,
                        batchAttributionQuality: batch.quality,
                        lifecycleStatus: lifecycle,
                        startAt: start?.occurredAt,
                        endAt: end.occurredAt,
                        startValue: start?.kilograms,
                        endValue: end.kilograms,
                        elapsedDays: elapsedDays,
                        value: value
                    ))
                    if let start { qualifiedSampleIDs.insert(start.id) }
                    qualifiedSampleIDs.insert(end.id)
                }
                if request.window != .none,
                   hasRelevantMeasurement,
                   observations.count == observationCountBeforeProfile {
                    insufficientProfiles += 1
                }
            }
        }

        let primaryGroups = renderGroups(
            observations,
            group: request.group,
            reduction: request.reduction,
            selection: request.selection,
            limit: request.limit,
            calendar: request.calendar,
            sheepWeightedRate: usesAppWeightGainEngine
        )
        var analysisSections: [[String: Any]]
        if request.analysisScope == .complete {
            analysisSections = [
                analysisSection(
                    title: "总体口径",
                    dimension: .none,
                    observations: observations,
                    reduction: request.reduction,
                    limit: request.limit,
                    calendar: request.calendar,
                    sheepWeightedRate: usesAppWeightGainEngine
                ),
                analysisSection(
                    title: "不同称重区间",
                    dimension: .weighingInterval,
                    observations: observations,
                    reduction: request.reduction,
                    limit: request.limit,
                    calendar: request.calendar,
                    sheepWeightedRate: usesAppWeightGainEngine
                ),
                analysisSection(
                    title: "生产批次",
                    dimension: .productionBatch,
                    observations: observations,
                    reduction: request.reduction,
                    limit: request.limit,
                    calendar: request.calendar,
                    sheepWeightedRate: usesAppWeightGainEngine
                ),
                analysisSection(
                    title: "生命周期",
                    dimension: .lifecycleStatus,
                    observations: observations,
                    reduction: request.reduction,
                    limit: request.limit,
                    calendar: request.calendar,
                    sheepWeightedRate: usesAppWeightGainEngine
                ),
            ]
        } else {
            analysisSections = []
        }
        if request.analysisScope == .complete, usesAppWeightGainEngine, selectedPens.count > 1 {
            var penSection = analysisSection(
                title: "期末圈舍", dimension: .pen, observations: observations,
                reduction: request.reduction, limit: request.limit, calendar: request.calendar,
                sheepWeightedRate: true
            )
            let populated = penSection["groups"] as? [[String: Any]] ?? []
            let byName = Dictionary(uniqueKeysWithValues: populated.compactMap { group -> (String, [String: Any])? in
                guard let name = group["key"] as? String else { return nil }
                return (name, group)
            })
            let penGroups = selectedPens.map { pen -> [String: Any] in
                byName[pen.name] ?? ["key": pen.name, "sample_count": 0, "sheep_count": 0, "value": NSNull()]
            }
            penSection["groups"] = Array(penGroups.prefix(request.limit))
            penSection["group_count"] = penGroups.count
            penSection["is_complete"] = penGroups.count <= request.limit
            analysisSections.append(penSection)
        }
        let analysisSectionsComplete = analysisSections.allSatisfy {
            ($0["is_complete"] as? Bool) == true
        }
        let groupsComplete = primaryGroups.isComplete && analysisSectionsComplete
        let recordsComplete = request.reduction != .records || observations.count <= request.limit
        let factsComplete = audit.unknownStateCount == 0 && audit.projectionMismatchCount == 0
        let samplesComplete = request.window == .none || insufficientProfiles == 0
        let isComplete = groupsComplete && recordsComplete && factsComplete && samplesComplete
        let resultUnit = unit(transform: request.transform, reduction: request.reduction)
        let batchQualityCounts = Dictionary(
            grouping: observations,
            by: \.batchAttributionQuality
        ).mapValues(\.count)
        let analyzedProfileCount = Set(observations.map(\.sheepID)).count
        var object: [String: Any] = [
            "evidence_kind": "farm_calculation",
            "calculation_id": UUID().uuidString.lowercased(),
            "contract_version": FarmFactContract.version,
            "farm_id": farmID.uuidString.lowercased(),
            "executed_at": Self.iso8601(now),
            "as_of": Self.iso8601(request.asOf),
            "time_zone": request.timeZoneIdentifier,
            "state_cutoff_basis": request.hasExplicitAsOf
                ? FarmFactContract.StateCutoff.historical(request.asOf).evidenceName
                : FarmFactContract.StateCutoff.current(request.asOf).evidenceName,
            "state_basis": audit.stateBasis.sorted(),
            "unknown_state_count": audit.unknownStateCount,
            "projection_mismatch_count": audit.projectionMismatchCount,
            "data_origin": "device_swiftdata",
            "source_description": sourceDescription(policy: request.samplePolicy),
            "operator_pipeline": [
                "filter", request.partition.rawValue, request.window.rawValue,
                request.transform.rawValue, request.analysisScope.rawValue,
                request.group.rawValue, request.reduction.rawValue, request.selection.rawValue,
            ],
            "formula": formula(transform: request.transform),
            "result_unit": resultUnit,
            "input_profile_count": sheep.filter { !$0.isHistoricalArchive }.count,
            "eligible_profile_count": eligibleSheep.count,
            "relevant_profile_count": relevantProfiles,
            "analyzed_profile_count": analyzedProfileCount,
            "input_sample_count": rawSamples.count,
            "pre_window_sample_count": candidateSamples.count,
            "filtered_sample_count": qualifiedSampleIDs.count,
            "observation_count": observations.count,
            "excluded_insufficient_sample_profiles": insufficientProfiles,
            "excluded_non_continuous_pen_intervals": audit.excludedNonContinuousPenIntervals,
            "excluded_non_positive_day_intervals": audit.excludedNonPositiveDayIntervals,
            "batch_attribution_counts": Dictionary(uniqueKeysWithValues: batchQualityCounts.map {
                ($0.key.rawValue, $0.value)
            }),
            "lifecycle_unknown_observation_count": observations.count {
                $0.lifecycleStatus == "状态未知" || $0.lifecycleStatus == "已离场（类型未知）"
            },
            "group_count": primaryGroups.totalCount,
            "is_complete": isComplete,
            "completeness": isComplete ? "complete" : "limited_or_unknown",
            "canonical_arguments": request.canonicalArguments,
            "groups": primaryGroups.values,
        ]
        if request.analysisScope == .complete {
            let dimensions = [Group.none, .weighingInterval, .productionBatch, .lifecycleStatus] +
                (usesAppWeightGainEngine && selectedPens.count > 1 ? [.pen] : [])
            object["analysis_contract"] = [
                "kind": "multidimensional_adjacent_rate_analysis",
                "aggregation_basis": usesAppWeightGainEngine
                    ? "与 App 增重分析共用引擎：先按羊汇总有效相邻区间总增重除以总观察天数，再逐羊等权平均；区间等权和汇总观察天数口径另列。"
                    : "每个有效相邻称重区间先独立计算变化率；总体同时给出区间等权、羊只等权和总增重除以总观察天数三种口径。",
                "required_dimensions": dimensions.map(\.rawValue),
                "required_answer_sections": [
                    "总体结论", "称重区间", "生产批次", "生命周期", "数据完整性",
                ],
                "lifecycle_basis": "截至 as_of 的 App 统一状态事实；离场羊按出售、死亡、淘汰、转出分开。",
                "batch_basis": "完整区间连续属于同一且唯一的生产批次时才归入该批次；退出重入、跨批次、重叠或未分批次单列。",
                "pen_basis": usesAppWeightGainEngine
                    ? "按分析结束日牧场时区日末还原期末圈舍并确定羊群；同羊跨舍有效称重连续配对，不能解释为单个圈舍独立造成的增重。"
                    : "先建立羊只完整称重时间线，再验证相邻区间两端和区间内连续圈舍归属；不会删除中间样本后伪造相邻区间。",
            ]
            object["analysis_sections"] = analysisSections
        }
        if let nativeResult {
            object["analysis_engine"] = "WeightGainAnalyticsEngine"
            object["eligible_profile_count"] = nativeResult.objectCount
            object["weighed_profile_count"] = nativeResult.weighedCount
            object["downward_profile_count"] = nativeResult.downwardCount
            object["cross_pen_interval_count"] = nativeResult.crossPenIntervalCount
            object["cross_pen_sheep_count"] = nativeResult.crossPenSheepCount
            object["transfer_sheep_count"] = nativeResult.transferSheepCount
            object["transfer_event_count"] = nativeResult.transferEvents.count
            object["pen_basis"] = "按分析结束日的期末圈舍确定羊群，同羊跨舍连续计算。"
            object["pen_history_basis"] = "调群按发生时间还原，包含末次称重后至分析截止的调群；截止后的调群不影响结果。"
            object["exclusion_counts"] = Dictionary(grouping: nativeResult.exclusions, by: { $0.reason.rawValue }).mapValues(\.count)
            object["excluded_native_intervals"] = nativeResult.unassignedIntervals.count
            let transferEvents = nativeResult.transferEvents.prefix(request.limit).map { event -> [String: Any] in
                ["ear_tag": event.earTag, "occurred_at": Self.iso8601(event.occurredAt),
                 "from_pen": event.fromPenName ?? "未分圈", "to_pen": event.toPenName ?? "未分圈"]
            }
            object["transfer_events"] = transferEvents
            object["transfer_events_truncated"] = nativeResult.transferEvents.count > transferEvents.count
            return try boundedAnalysisJSON(object)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 64 * 1_024 else { throw InsightToolError.resultTooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    /// Keep the full-cohort totals when detailed dimensions exceed the tool's
    /// byte budget. Every shortened list is explicitly marked as truncated.
    private func boundedAnalysisJSON(_ original: [String: Any]) throws -> String {
        var object = original
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        while data.count > 64 * 1_024 {
            var sections = object["analysis_sections"] as? [[String: Any]] ?? []
            let largest = sections.indices.filter { sections[$0]["dimension"] as? String != Group.pen.rawValue }.max {
                (sections[$0]["groups"] as? [[String: Any]] ?? []).count <
                    (sections[$1]["groups"] as? [[String: Any]] ?? []).count
            }
            if let largest, let groups = sections[largest]["groups"] as? [[String: Any]], groups.count > 1 {
                sections[largest]["groups"] = Array(groups.prefix(max(1, groups.count / 2)))
                sections[largest]["is_complete"] = false
                object["analysis_sections"] = sections
            } else if let groups = object["groups"] as? [[String: Any]], groups.count > 1 {
                object["groups"] = Array(groups.prefix(max(1, groups.count / 2)))
            } else if let events = object["transfer_events"] as? [[String: Any]], !events.isEmpty {
                object["transfer_events"] = Array(events.prefix(events.count / 2))
                object["transfer_events_truncated"] = true
            } else if var groups = object["groups"] as? [[String: Any]],
                      let records = groups.first?["records"] as? [[String: Any]], records.count > 1 {
                groups[0]["records"] = Array(records.prefix(max(1, records.count / 2)))
                object["groups"] = groups
            } else {
                throw InsightToolError.resultTooLarge
            }
            object["is_complete"] = false
            object["completeness"] = "limited_or_unknown"
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func parse(
        _ values: [String: Any],
        now: Date,
        timeZone: TimeZone,
        timeZoneIdentifier: String
    ) throws -> Request {
        guard string(values, "source") == "weight_samples" else {
            throw InsightToolError.invalidArguments("source")
        }
        guard let samplePolicy = SamplePolicy(rawValue: string(values, "sample_policy")),
              let cohort = Cohort(rawValue: string(values, "cohort")),
              let penMembership = PenMembership(rawValue: string(values, "pen_membership")),
              let partition = Partition(rawValue: string(values, "partition_by")),
              let window = Window(rawValue: string(values, "window")),
              let transform = Transform(rawValue: string(values, "transform")),
              let analysisScope = AnalysisScope(rawValue: string(values, "analysis_scope")),
              let group = Group(rawValue: string(values, "group_by")),
              let reduction = Reduction(rawValue: string(values, "reduce")),
              let selection = Selection(rawValue: string(values, "selection")) else {
            throw InsightToolError.invalidArguments("calculation plan")
        }
        let sex = string(values, "sex")
        guard ["", SheepSex.ewe.rawValue, SheepSex.ram.rawValue, SheepSex.unknown.rawValue].contains(sex) else {
            throw InsightToolError.invalidArguments("sex")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dateFrom = try optionalDate(string(values, "date_from"), calendar: calendar)
        var dateTo = try optionalDate(string(values, "date_to"), calendar: calendar, endOfDay: true)
        let asOfText = string(values, "as_of")
        if let end = dateTo, calendar.isDate(end, inSameDayAs: now), end > now, asOfText.isEmpty {
            dateTo = now
        }
        let explicitAsOf = try optionalDate(asOfText, calendar: calendar, endOfDay: true)
        let usesAppWeightGainEngine = samplePolicy == .canonicalTimeline &&
            penMembership == .atCutoff && partition == .sheep &&
            window == .adjacent && transform == .differencePerDay
        let asOf = usesAppWeightGainEngine
            ? min(explicitAsOf ?? now, dateTo ?? now, now)
            : explicitAsOf ?? min(dateTo ?? now, now)
        if usesAppWeightGainEngine, let end = dateTo, end > asOf {
            dateTo = asOf
        }
        let penName = string(values, "pen_name")
        let batchID: UUID?
        if let raw = values["batch_id"] {
            guard let text = raw as? String else { throw InsightToolError.invalidArguments("batch_id") }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                batchID = nil
            } else {
                guard let id = UUID(uuidString: text) else { throw InsightToolError.invalidArguments("batch_id") }
                batchID = id
            }
        } else {
            batchID = nil
        }
        if batchID != nil, !usesAppWeightGainEngine {
            throw InsightToolError.invalidArguments(
                "batch_id requires canonical_timeline + at_cutoff + sheep + adjacent + difference_per_day"
            )
        }
        var penNames: [String] = []
        if let raw = values["pen_names"] {
            guard let names = raw as? [String], names.count <= 50 else {
                throw InsightToolError.invalidArguments("pen_names")
            }
            penNames = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard penNames.allSatisfy({ !$0.isEmpty }) else { throw InsightToolError.invalidArguments("pen_names") }
        }
        if !penName.isEmpty { penNames.insert(penName, at: 0) }
        var seenNames = Set<String>()
        penNames = penNames.filter { seenNames.insert(normalized($0)).inserted }
        if let dateFrom, let dateTo, dateTo < dateFrom {
            throw InsightToolError.invalidArguments("date range")
        }
        guard dateFrom.map({ $0 <= asOf }) ?? true,
              dateTo.map({ $0 <= asOf }) ?? true else {
            throw InsightToolError.invalidArguments("date range")
        }
        if window == .none && [.difference, .elapsedDays, .differencePerDay].contains(transform) {
            throw InsightToolError.invalidArguments("transform requires a non-none window")
        }
        if partition == .none && window != .none {
            throw InsightToolError.invalidArguments("windowed calculations require partition_by=sheep")
        }
        if selection == .latest && ![.intervalEndDay, .intervalEndMonth].contains(group) {
            throw InsightToolError.invalidArguments("selection=latest requires a date group")
        }
        if reduction == .records && group != .none {
            throw InsightToolError.invalidArguments("reduce=records requires group_by=none")
        }
        if analysisScope == .complete {
            guard cohort == .allProfiles,
                  partition == .sheep,
                  window == .adjacent,
                  transform == .differencePerDay,
                  group == .none,
                  reduction == .average,
                  selection == .all else {
                throw InsightToolError.invalidArguments(
                    "analysis_scope=complete requires all_profiles + sheep + adjacent + difference_per_day + none + average + all"
                )
            }
        }
        let limit: Int
        if let number = values["limit"] as? NSNumber {
            limit = number.intValue
        } else {
            throw InsightToolError.invalidArguments("limit")
        }
        guard (1...100).contains(limit) else { throw InsightToolError.invalidArguments("limit") }
        let canonicalArguments: [String: Any] = [
            "source": "weight_samples",
            "sample_policy": samplePolicy.rawValue,
            "cohort": cohort.rawValue,
            "pen_membership": penMembership.rawValue,
            "pen_name": penName,
            "pen_names": penNames,
            "batch_id": batchID?.uuidString.lowercased() ?? "",
            "ear_tag": string(values, "ear_tag"),
            "breed": string(values, "breed"),
            "sex": sex,
            "date_from": dateFrom.map(Self.iso8601) ?? "",
            "date_to": dateTo.map(Self.iso8601) ?? "",
            "as_of": asOfText.isEmpty && dateTo == nil ? "" : Self.iso8601(asOf),
            "partition_by": partition.rawValue,
            "window": window.rawValue,
            "transform": transform.rawValue,
            "analysis_scope": analysisScope.rawValue,
            "group_by": group.rawValue,
            "reduce": reduction.rawValue,
            "selection": selection.rawValue,
            "limit": limit,
        ]
        return Request(
            samplePolicy: samplePolicy,
            cohort: cohort,
            penMembership: penMembership,
            penName: penName,
            penNames: penNames,
            batchID: batchID,
            earTag: string(values, "ear_tag"),
            breed: string(values, "breed"),
            sex: sex,
            dateFrom: dateFrom,
            dateTo: dateTo,
            asOf: asOf,
            hasExplicitAsOf: !asOfText.isEmpty || dateTo != nil,
            partition: partition,
            window: window,
            transform: transform,
            analysisScope: analysisScope,
            group: group,
            reduction: reduction,
            selection: selection,
            limit: limit,
            calendar: calendar,
            timeZoneIdentifier: timeZoneIdentifier,
            canonicalArguments: canonicalArguments
        )
    }

    private func farmTimeZone(
        farmID: UUID,
        context: ModelContext
    ) throws -> (value: TimeZone, identifier: String) {
        let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first {
            $0.id == farmID && $0.deletedAt == nil
        }
        guard let farm else {
            throw InsightToolError.farmFactsUnavailable("当前牧场记录不存在，无法确定数据边界和时区。")
        }
        guard let timeZone = TimeZone(identifier: farm.timeZoneIdentifier) else {
            throw InsightToolError.farmFactsUnavailable("牧场时区无效，不能可靠划分日期和月份。")
        }
        return (timeZone, farm.timeZoneIdentifier)
    }

    /// App date filters cover whole days. The calculation tool also accepts
    /// exact instants, so clip every weight source before daily canonicalization
    /// rather than letting the App's day normalization broaden an ISO boundary.
    private func clippingWeightSources(
        _ snapshot: FarmAnalyticsSnapshot, from start: Date?, through cutoff: Date
    ) -> FarmAnalyticsSnapshot {
        func includes(_ date: Date) -> Bool {
            date <= cutoff && (start.map { date >= $0 } ?? true)
        }
        return FarmAnalyticsSnapshot(
            farmID: snapshot.farmID, sheep: snapshot.sheep, pens: snapshot.pens,
            weights: snapshot.weights.filter { includes($0.occurredAt) },
            weanings: snapshot.weanings.filter { includes($0.occurredAt) }.map { record in
                FarmAnalyticsSnapshot.Weaning(
                    id: record.id, sheepID: record.sheepID, occurredAt: record.occurredAt,
                    weanWeight: record.weanWeight,
                    birthAt: record.birthAt.flatMap { includes($0) ? $0 : nil },
                    birthWeight: record.birthWeight, damID: record.damID, litterSize: record.litterSize
                )
            },
            lambings: snapshot.lambings.filter { includes($0.occurredAt) },
            removals: snapshot.removals, transfers: snapshot.transfers,
            batchMemberships: snapshot.batchMemberships, feeds: snapshot.feeds,
            timeZoneIdentifier: snapshot.timeZoneIdentifier, factsReadAt: snapshot.factsReadAt,
            parityEvidence: snapshot.parityEvidence, purposeFacts: snapshot.purposeFacts
        )
    }

    private func resolvePen(named name: String, from pens: [PenRecord]) throws -> PenRecord? {
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        let exact = pens.filter { normalized($0.name) == key }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw InsightToolError.invalidArguments("pen_name is ambiguous") }
        let partial = pens.filter { normalized($0.name).contains(key) }
        guard partial.count == 1 else {
            throw InsightToolError.invalidArguments(partial.isEmpty ? "pen_name not found" : "pen_name is ambiguous")
        }
        return partial[0]
    }

    private func renderGroups(
        _ observations: [Observation],
        group: Group,
        reduction: Reduction,
        selection: Selection,
        limit: Int,
        calendar: Calendar,
        sheepWeightedRate: Bool = false
    ) -> RenderedGroups {
        let grouped = Dictionary(grouping: observations) { observation in
            groupKey(for: observation, group: group, calendar: calendar)
        }
        var values = grouped.map { key, observations in
            reducedGroup(
                key: key,
                values: observations,
                reduction: reduction,
                recordLimit: limit,
                sheepWeightedRate: sheepWeightedRate
            )
        }.sorted { lhs, rhs in
            let lhsKey = lhs["key"] as? String ?? ""
            let rhsKey = rhs["key"] as? String ?? ""
            return lhsKey.localizedStandardCompare(rhsKey) == .orderedAscending
        }
        if selection == .latest, let latest = values.last {
            values = [latest]
        }
        let totalCount = values.count
        if values.count > limit {
            values = Array(values.prefix(limit))
        }
        return RenderedGroups(
            values: values,
            totalCount: totalCount,
            isComplete: totalCount <= limit
        )
    }

    private func analysisSection(
        title: String,
        dimension: Group,
        observations: [Observation],
        reduction: Reduction,
        limit: Int,
        calendar: Calendar,
        sheepWeightedRate: Bool = false
    ) -> [String: Any] {
        let rendered = renderGroups(
            observations,
            group: dimension,
            reduction: reduction,
            selection: .all,
            limit: limit,
            calendar: calendar,
            sheepWeightedRate: sheepWeightedRate
        )
        return [
            "title": title,
            "dimension": dimension.rawValue,
            "group_count": rendered.totalCount,
            "is_complete": rendered.isComplete,
            "groups": rendered.values,
        ]
    }

    private func groupKey(
        for observation: Observation,
        group: Group,
        calendar: Calendar
    ) -> String {
        switch group {
        case .none:
            return "all"
        case .weighingInterval:
            if let startAt = observation.startAt {
                let start = dateText(startAt, format: "yyyy-MM-dd", calendar: calendar)
                let end = dateText(observation.endAt, format: "yyyy-MM-dd", calendar: calendar)
                let days = observation.elapsedDays.map { "（\($0)天）" } ?? ""
                return "\(start) → \(end)\(days)"
            }
            return "无起点区间"
        case .intervalEndDay:
            return dateText(observation.endAt, format: "yyyy-MM-dd", calendar: calendar)
        case .intervalEndMonth:
            return dateText(observation.endAt, format: "yyyy-MM", calendar: calendar)
        case .productionBatch:
            return observation.productionBatch
        case .lifecycleStatus:
            return observation.lifecycleStatus
        case .sheep:
            return observation.earTag
        case .pen:
            return observation.penName
        }
    }

    private func reducedGroup(
        key: String,
        values: [Observation],
        reduction: Reduction,
        recordLimit: Int,
        sheepWeightedRate: Bool = false
    ) -> [String: Any] {
        let numbers = values.map(\.value)
        let result: Double
        switch reduction {
        case .records:
            result = numbers.first ?? 0
        case .count:
            result = Double(numbers.count)
        case .sum:
            result = numbers.reduce(0, +)
        case .average:
            result = numbers.isEmpty ? 0 : numbers.reduce(0, +) / Double(numbers.count)
        case .minimum:
            result = numbers.min() ?? 0
        case .maximum:
            result = numbers.max() ?? 0
        }
        let average = numbers.isEmpty ? 0 : numbers.reduce(0, +) / Double(numbers.count)
        let orderedNumbers = numbers.sorted()
        let median: Double
        if orderedNumbers.isEmpty {
            median = 0
        } else if orderedNumbers.count.isMultiple(of: 2) {
            let upper = orderedNumbers.count / 2
            median = (orderedNumbers[upper - 1] + orderedNumbers[upper]) / 2
        } else {
            median = orderedNumbers[orderedNumbers.count / 2]
        }
        let elapsedDays = values.compactMap(\.elapsedDays).filter { $0 > 0 }
        let elapsedAverage = elapsedDays.isEmpty
            ? 0
            : Double(elapsedDays.reduce(0, +)) / Double(elapsedDays.count)
        var object: [String: Any] = [
            "key": key,
            "value": result,
            "average": average,
            "minimum": numbers.min() ?? 0,
            "maximum": numbers.max() ?? 0,
            "median": median,
            "sample_count": values.count,
            "sheep_count": Set(values.map(\.sheepID)).count,
            "positive_count": numbers.count { $0 > 0 },
            "zero_count": numbers.count { abs($0) <= 0.000_000_001 },
            "negative_count": numbers.count { $0 < 0 },
        ]
        if !elapsedDays.isEmpty {
            object["elapsed_days_average"] = elapsedAverage
            object["elapsed_days_minimum"] = elapsedDays.min() ?? 0
            object["elapsed_days_maximum"] = elapsedDays.max() ?? 0
            object["total_observation_days"] = elapsedDays.reduce(0, +)
        }
        let rateInputs = values.compactMap { observation -> (UUID, Double, Int)? in
            guard let startValue = observation.startValue,
                  let days = observation.elapsedDays,
                  days > 0 else { return nil }
            return (observation.sheepID, observation.endValue - startValue, days)
        }
        if !rateInputs.isEmpty {
            let totalChange = rateInputs.reduce(0) { $0 + $1.1 }
            let totalDays = rateInputs.reduce(0) { $0 + $1.2 }
            object["total_weight_change"] = totalChange
            object["pooled_daily_rate"] = totalDays > 0 ? totalChange / Double(totalDays) : 0
            let bySheep = Dictionary(grouping: rateInputs, by: { $0.0 })
            let perSheepRates = bySheep.values.compactMap { rows -> Double? in
                let sheepDays = rows.reduce(0) { $0 + $1.2 }
                guard sheepDays > 0 else { return nil }
                return rows.reduce(0) { $0 + $1.1 } / Double(sheepDays)
            }
            object["sheep_weighted_daily_rate"] = perSheepRates.isEmpty
                ? 0
                : perSheepRates.reduce(0, +) / Double(perSheepRates.count)
            object["interval_weighted_daily_rate"] = average
            if sheepWeightedRate && reduction == .average {
                object["value"] = object["sheep_weighted_daily_rate"]
                object["average"] = object["sheep_weighted_daily_rate"]
            }
        }
        if let minimum = values.map(\.endAt).min(), let maximum = values.map(\.endAt).max() {
            object["first_interval_end"] = Self.iso8601(minimum)
            object["last_interval_end"] = Self.iso8601(maximum)
        }
        if let minimum = values.compactMap(\.startAt).min() {
            object["first_interval_start"] = Self.iso8601(minimum)
        }
        if reduction == .records {
            let orderedValues = values.sorted {
                if $0.endAt != $1.endAt { return $0.endAt < $1.endAt }
                if $0.earTag != $1.earTag {
                    return $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending
                }
                return $0.sheepID.uuidString < $1.sheepID.uuidString
            }
            object["records"] = orderedValues.prefix(recordLimit).map { observation in
                var row: [String: Any] = [
                    "ear_tag": observation.earTag,
                    "pen": observation.penName,
                    "production_batch": observation.productionBatch,
                    "lifecycle_status": observation.lifecycleStatus,
                    "end_at": Self.iso8601(observation.endAt),
                    "end_value": observation.endValue,
                    "value": observation.value,
                ]
                if let startAt = observation.startAt { row["start_at"] = Self.iso8601(startAt) }
                if let startValue = observation.startValue { row["start_value"] = startValue }
                if let elapsedDays = observation.elapsedDays { row["elapsed_days"] = elapsedDays }
                return row
            }
        }
        return object
    }

    private func intervalIsContinuouslyInPens(
        _ penIDs: Set<UUID>,
        startAt: Date,
        endAt: Date,
        startPenID: UUID?,
        endPenID: UUID?,
        transfers: [TransferRecord]
    ) -> Bool {
        guard startPenID.map(penIDs.contains) ?? false,
              endPenID.map(penIDs.contains) ?? false else { return false }
        return !transfers.contains { transfer in
            transfer.occurredAt > startAt &&
                transfer.occurredAt <= endAt &&
                !(transfer.toPenID.map(penIDs.contains) ?? false)
        }
    }

    private func batchLabels(for batches: [ProductionBatchRecord]) -> [UUID: String] {
        let normalizedNames = batches.map { batch in
            let name = batch.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (batch, name.isEmpty ? "未命名生产批次" : name)
        }
        let nameCounts = Dictionary(grouping: normalizedNames, by: { $0.1 })
            .mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: normalizedNames.map { batch, name in
            let label: String
            if nameCounts[name, default: 0] > 1 {
                label = "\(name)（ID \(batch.id.uuidString.lowercased().prefix(8))）"
            } else {
                label = name
            }
            return (batch.id, label)
        })
    }

    private func batchAttribution(
        sheepID: UUID,
        startAt: Date?,
        endAt: Date,
        memberships: [BatchMembershipRecord],
        labelsByID: [UUID: String]
    ) -> BatchAttribution {
        let relevantMemberships = memberships.filter { $0.sheepID == sheepID }
        let endIDs = activeBatchIDs(at: endAt, memberships: relevantMemberships)
        let startIDs = startAt.map {
            activeBatchIDs(at: $0, memberships: relevantMemberships)
        } ?? endIDs
        let intervalStart = startAt ?? endAt
        let intervalMemberships = relevantMemberships.filter {
            $0.joinedAt <= endAt && ($0.leftAt.map { $0 >= intervalStart } ?? true)
        }

        // Endpoint membership alone would falsely assign an interval when a
        // sheep left and rejoined the same batch between its two weighings.
        let hasOverlap = intervalMemberships.indices.contains { index in
            intervalMemberships.indices.contains { other in
                guard other > index else { return false }
                let lhs = intervalMemberships[index]
                let rhs = intervalMemberships[other]
                return max(lhs.joinedAt, rhs.joinedAt, intervalStart) <=
                    min(lhs.leftAt ?? endAt, rhs.leftAt ?? endAt, endAt)
            }
        }
        if hasOverlap {
            return BatchAttribution(label: "生产批次归属重叠", quality: .overlapping)
        }

        guard startIDs == endIDs else {
            return BatchAttribution(label: "跨生产批次区间", quality: .crossBatch)
        }
        guard !endIDs.isEmpty else {
            return intervalMemberships.isEmpty
                ? BatchAttribution(label: "未分生产批次", quality: .unassigned)
                : BatchAttribution(label: "跨生产批次区间", quality: .crossBatch)
        }
        guard endIDs.count == 1, let batchID = endIDs.first else {
            return BatchAttribution(label: "生产批次归属重叠", quality: .overlapping)
        }
        guard intervalMemberships.count == 1,
              let membership = intervalMemberships.first,
              membership.batchID == batchID,
              membership.joinedAt <= intervalStart,
              membership.leftAt.map({ $0 >= endAt }) ?? true else {
            return BatchAttribution(label: "跨生产批次区间", quality: .crossBatch)
        }
        guard let label = labelsByID[batchID] else {
            return BatchAttribution(label: "生产批次定义缺失", quality: .missingDefinition)
        }
        return BatchAttribution(label: label, quality: .assigned)
    }

    private func activeBatchIDs(
        at date: Date,
        memberships: [BatchMembershipRecord]
    ) -> Set<UUID> {
        Set(memberships.lazy.filter { membership in
            membership.joinedAt <= date &&
                (membership.leftAt.map { date <= $0 } ?? true)
        }.map(\.batchID))
    }

    private func lifecycleStatus(for fact: FarmSheepStateFact?) -> String {
        guard let fact, fact.isIncluded, fact.isKnown else { return "状态未知" }
        if fact.status == .active { return "当前在群" }
        if let removalKind = fact.removalKind { return removalKind.displayName }
        if fact.status == .deceased { return RemovalKind.deceased.displayName }
        return "已离场（类型未知）"
    }

    private func sourceDescription(policy: SamplePolicy) -> String {
        switch policy {
        case .recordedOnly:
            "WeightRecord 常规称重"
        case .canonicalTimeline:
            "按羊只和牧场日去重的统一体重时间线（常规称重优先，其次断奶重与初生重）"
        }
    }

    private func formula(transform: Transform) -> String {
        switch transform {
        case .value: "end_value"
        case .difference: "end_value - start_value"
        case .elapsedDays: "farm_calendar_days(start_at, end_at)"
        case .differencePerDay: "(end_value - start_value) / farm_calendar_days(start_at, end_at)"
        }
    }

    private func unit(transform: Transform, reduction: Reduction) -> String {
        if reduction == .count { return "count" }
        return switch transform {
        case .value, .difference: "kg"
        case .elapsedDays: "day"
        case .differencePerDay: "kg/day"
        }
    }

    private func string(_ values: [String: Any], _ key: String) -> String {
        (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func optionalDate(_ value: String, calendar: Calendar, endOfDay: Bool = false) throws -> Date? {
        guard !value.isEmpty else { return nil }
        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let day = formatter.date(from: value), formatter.string(from: day) == value,
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                throw InsightToolError.invalidArguments("date")
            }
            return endOfDay ? next.addingTimeInterval(-0.001) : day
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw InsightToolError.invalidArguments("ISO 8601 date")
        }
        return date
    }

    private func textMatches(_ value: String, filter: String) -> Bool {
        let filter = normalized(filter)
        return filter.isEmpty || normalized(value).contains(filter)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func dateText(_ date: Date, format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
