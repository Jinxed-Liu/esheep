import CryptoKit
import Foundation
import SwiftData

enum FeedIntakeEvidence: String, Codable, Sendable, Hashable {
    case measured = "实测"
    case estimated = "估算"
    case historicalHeadCount = "历史人数估算"
    case inferredNutrition = "营养推算"
    case conflict = "数据冲突"
    case incomplete = "区间未闭合"
}

enum FeedAnalysisStage: String, Codable, Sendable, Hashable {
    case lactatingLamb = "哺乳羔羊"
    case weanedLamb = "断奶羔羊"
    case growing = "育成羊"
    case replacement = "后备生长羊"
    case fattening = "育肥羊"
    case breedingEwe = "繁殖母羊"
    case breedingRam = "种公羊"
    case unknown = "未分类"

    var supportsGrowthPrediction: Bool {
        switch self {
        case .weanedLamb, .growing, .replacement, .fattening: true
        case .lactatingLamb, .breedingEwe, .breedingRam, .unknown: false
        }
    }

    static func classify(purpose: String, sex: SheepSex, isBreedingRam: Bool = false) -> FeedAnalysisStage {
        let value = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("哺乳") { return .lactatingLamb }
        if value.contains("断奶") && value.contains("羔") { return .weanedLamb }
        if value.contains("后备") { return .replacement }
        if value.contains("育成") { return .growing }
        if value.contains("育肥") { return .fattening }
        if value.contains("种公") || (sex == .ram && isBreedingRam) { return .breedingRam }
        if value.contains("繁殖") && (value.contains("母") || sex == .ewe) { return .breedingEwe }
        return .unknown
    }
}

struct FeedAnalysisPenSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
}

struct FeedAnalysisSheepSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let earTag: String
    let purpose: String
    let sex: SheepSex
    let isBreedingRam: Bool
    let initialPenID: UUID?
    let enteredAt: Date
    let removedAt: Date?

    init(
        id: UUID,
        earTag: String,
        purpose: String,
        sex: SheepSex,
        isBreedingRam: Bool = false,
        initialPenID: UUID?,
        enteredAt: Date,
        removedAt: Date? = nil
    ) {
        self.id = id
        self.earTag = earTag
        self.purpose = purpose
        self.sex = sex
        self.isBreedingRam = isBreedingRam
        self.initialPenID = initialPenID
        self.enteredAt = enteredAt
        self.removedAt = removedAt
    }

    var stage: FeedAnalysisStage {
        FeedAnalysisStage.classify(purpose: purpose, sex: sex, isBreedingRam: isBreedingRam)
    }
}

struct FeedAnalysisTransferSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let sheepID: UUID
    let fromPenID: UUID?
    let toPenID: UUID?
    let occurredAt: Date
    let recordedAt: Date
}

struct FeedAnalysisRemovalSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let sheepID: UUID
    let occurredAt: Date
    let recordedAt: Date
}

struct FeedAnalysisDailyPenCountSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let penID: UUID
    let purpose: String
    let date: Date
    let count: Int
    let rebuiltAt: Date
}

struct FeedAnalysisLineSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let ingredientID: UUID?
    let ingredientBatchID: UUID?
    let ingredientName: String
    let freshKilograms: Double
    let pricePerKilogram: Double?
    let nutrients: FeedNutrients

    init(
        id: UUID = UUID(),
        ingredientID: UUID? = nil,
        ingredientBatchID: UUID? = nil,
        ingredientName: String,
        freshKilograms: Double,
        pricePerKilogram: Double? = nil,
        nutrients: FeedNutrients
    ) {
        self.id = id
        self.ingredientID = ingredientID
        self.ingredientBatchID = ingredientBatchID
        self.ingredientName = ingredientName
        self.freshKilograms = freshKilograms
        self.pricePerKilogram = pricePerKilogram
        self.nutrients = nutrients
    }
}

struct FeedAnalysisFeedSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let penID: UUID
    let mode: FeedMode
    let occurredAt: Date
    let feederName: String
    let lines: [FeedAnalysisLineSnapshot]
    let excludedSheepIDs: Set<UUID>
    let historicalHeadCountSnapshot: Int?
    let legacyRemainingKilograms: Double?
    let legacyDiscardedKilograms: Double?
    let legacyRemainingComposition: [FeedTroughCompositionComponent]

    init(
        id: UUID = UUID(),
        penID: UUID,
        mode: FeedMode,
        occurredAt: Date,
        feederName: String = "",
        lines: [FeedAnalysisLineSnapshot],
        excludedSheepIDs: Set<UUID> = [],
        historicalHeadCountSnapshot: Int? = nil,
        legacyRemainingKilograms: Double? = nil,
        legacyDiscardedKilograms: Double? = nil,
        legacyRemainingComposition: [FeedTroughCompositionComponent] = []
    ) {
        self.id = id
        self.penID = penID
        self.mode = mode
        self.occurredAt = occurredAt
        self.feederName = feederName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lines = lines
        self.excludedSheepIDs = excludedSheepIDs
        self.historicalHeadCountSnapshot = historicalHeadCountSnapshot
        self.legacyRemainingKilograms = legacyRemainingKilograms
        self.legacyDiscardedKilograms = legacyDiscardedKilograms
        self.legacyRemainingComposition = legacyRemainingComposition
    }
}

struct FeedAnalysisTroughSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let penID: UUID
    let relatedFeedRecordID: UUID?
    let feederName: String
    let observedAt: Date
    let actualRemainingKilograms: Double
    let discardedKilograms: Double
    let measurementMethod: FeedTroughMeasurementMethod
    let composition: [FeedTroughCompositionComponent]
}

struct FeedAnalysisWeightSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let sheepID: UUID
    let kilograms: Double
    let occurredAt: Date
}

struct FeedIntakeAnalysisInput: Sendable {
    let start: Date
    let end: Date
    let calendar: Calendar
    let pens: [FeedAnalysisPenSnapshot]
    let sheep: [FeedAnalysisSheepSnapshot]
    let transfers: [FeedAnalysisTransferSnapshot]
    let removals: [FeedAnalysisRemovalSnapshot]
    let dailyPenCounts: [FeedAnalysisDailyPenCountSnapshot]
    let feeds: [FeedAnalysisFeedSnapshot]
    let troughObservations: [FeedAnalysisTroughSnapshot]
    let weights: [FeedAnalysisWeightSnapshot]

    init(
        start: Date,
        end: Date,
        calendar: Calendar = .current,
        pens: [FeedAnalysisPenSnapshot],
        sheep: [FeedAnalysisSheepSnapshot],
        transfers: [FeedAnalysisTransferSnapshot] = [],
        removals: [FeedAnalysisRemovalSnapshot] = [],
        dailyPenCounts: [FeedAnalysisDailyPenCountSnapshot] = [],
        feeds: [FeedAnalysisFeedSnapshot],
        troughObservations: [FeedAnalysisTroughSnapshot] = [],
        weights: [FeedAnalysisWeightSnapshot] = []
    ) {
        self.start = start
        self.end = end
        self.calendar = calendar
        self.pens = pens
        self.sheep = sheep
        self.transfers = transfers
        self.removals = removals
        self.dailyPenCounts = dailyPenCounts
        self.feeds = feeds
        self.troughObservations = troughObservations
        self.weights = weights
    }
}

struct FeedAnalysisIngredientResult: Sendable, Hashable, Identifiable {
    let id: String
    let ingredientID: UUID?
    let ingredientBatchID: UUID?
    let name: String
    let freshKilograms: Double
    let freshKilogramsPerSheepDay: Double?
    let nutrition: FeedRecipeNutritionSummary
}

struct FeedAnalysisNutritionResult: Sendable, Hashable {
    let summary: FeedRecipeNutritionSummary
    let freshKilogramsPerSheepDay: Double?
    let dryMatterKilogramsPerSheepDay: Double?
    let meMJPerSheepDay: Double?
    let crudeProteinGramsPerSheepDay: Double?
    let metabolizableProteinGramsPerSheepDay: Double?
    let ndfGramsPerSheepDay: Double?
    let adfGramsPerSheepDay: Double?
    let mpEstimated: Bool
    let mpBlockedReason: String?
}

struct FeedGrowthSupportResult: Sendable, Hashable {
    let stage: FeedAnalysisStage?
    let dominantStageRatio: Double?
    let averageWeightKilograms: Double?
    let weightCoverage: Double
    let weightSampleCount: Int
    let requiredWeightSampleCount: Int
    let maintenanceMEPerDay: Double?
    let maintenanceMPGramsPerDay: Double?
    let maintenanceMEGap: Double?
    let maintenanceMPGapGrams: Double?
    let nutritionPotentialADGKg: Double?
    let observedADGKg: Double?
    let observedSampleCount: Int
    let calibratedExpectedADGKg: Double?
    let limitingFactor: String?
    let blockedReason: String?
    let modelDescription: String
}

struct FeedAnalysisDailyTrend: Sendable, Hashable, Identifiable {
    var id: Date { date }
    let date: Date
    let freshKilograms: Double
    let sheepDays: Double
    let dmiKilogramsPerSheepDay: Double?
    let meMJPerSheepDay: Double?
    let evidence: Set<FeedIntakeEvidence>
}

struct FeedIntakePenResult: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let freshKilograms: Double
    let sheepDays: Double
    let ingredients: [FeedAnalysisIngredientResult]
    let nutrition: FeedAnalysisNutritionResult
    let growth: FeedGrowthSupportResult
    let dailyTrend: [FeedAnalysisDailyTrend]
    let evidence: Set<FeedIntakeEvidence>
    let conflicts: [String]
    let completeIntervalCount: Int
    let incompleteIntervalCount: Int
}

struct FeedIntakeFarmOverview: Sendable, Hashable {
    let totalFreshKilograms: Double
    let feedingSheepDays: Double
    let effectivePenCount: Int
    let recordCompleteness: Double
    let measuredRatio: Double
    let estimatedRatio: Double
    let conflictCount: Int
}

struct FeedIntakeAnalysisResult: Sendable, Hashable {
    let start: Date
    let end: Date
    let sourceRevision: String
    let overview: FeedIntakeFarmOverview
    let pens: [FeedIntakePenResult]
}

struct FeedIntakeAnalysisScreenSnapshot: Sendable, Hashable {
    let eligiblePens: [FeedAnalysisPenSnapshot]
    let validSelectedPenIDs: Set<UUID>
    let result: FeedIntakeAnalysisResult
    let todayFeedCount: Int
    let todayKilograms: Double
}

/// Loads and transforms every large SwiftData collection required by the feed
/// analysis away from the main actor. The returned value is immutable so a
/// SwiftUI render never has to rebuild presence indexes or nutrition inputs.
actor FeedIntakeAnalysisSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        farmID: UUID,
        start: Date,
        end: Date,
        selectedPenIDs: Set<UUID>,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> FeedIntakeAnalysisScreenSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
        let feedStart = min(start, today)
        let feedEnd = max(end, tomorrow)
        let weightStart = calendar.date(byAdding: .day, value: -60, to: end) ?? start

        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }, sortBy: [SortDescriptor(\PenRecord.name)]))
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt < end
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt < end
        }))
        let dailyPenCounts = try context.fetch(FetchDescriptor<DailyPenCountRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.date < end
        }))
        try Task.checkCancellation()
        let feeds = try context.fetch(FetchDescriptor<FeedRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil &&
                $0.occurredAt >= feedStart && $0.occurredAt < feedEnd
        }))
        let lines = try context.fetch(FetchDescriptor<FeedRecordLine>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let troughObservations = try context.fetch(FetchDescriptor<FeedTroughObservationRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil &&
                $0.observedAt >= start && $0.observedAt < end
        }))
        let weights = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil &&
                $0.occurredAt >= weightStart && $0.occurredAt < end
        }))
        try Task.checkCancellation()

        let occupancy = FarmPenOccupancyIndex.make(
            farmID: farmID,
            sheep: sheep,
            transfers: transfers,
            removals: removals,
            dailyPenCounts: dailyPenCounts
        )
        let eligiblePenIDs = occupancy.occupiedPenIDsDuringWholeDays(
            from: start,
            to: end,
            calendar: calendar
        )
        let eligiblePens = pens
            .filter { eligiblePenIDs.contains($0.id) }
            .map { FeedAnalysisPenSnapshot(id: $0.id, name: $0.name) }
        let validSelectedPenIDs = selectedPenIDs.intersection(eligiblePenIDs)
        let input = FeedIntakeAnalysisSnapshotFactory.make(
            farmID: farmID,
            start: start,
            end: end,
            calendar: calendar,
            selectedPenIDs: validSelectedPenIDs,
            pens: pens.filter { eligiblePenIDs.contains($0.id) },
            sheep: sheep,
            transfers: transfers,
            removals: removals,
            dailyPenCounts: dailyPenCounts,
            feeds: feeds,
            lines: lines,
            troughObservations: troughObservations,
            weights: weights
        )
        try Task.checkCancellation()
        let result = FeedIntakeAnalysisEngine.calculate(input: input)

        let todayFeeds = feeds.filter { $0.occurredAt >= today && $0.occurredAt < tomorrow }
        let todayFeedIDs = Set(todayFeeds.map(\.id))
        let todayKilograms = lines.lazy
            .filter { todayFeedIDs.contains($0.feedRecordID) }
            .reduce(0) { $0 + NSDecimalNumber(decimal: $1.kilograms).doubleValue }
        try Task.checkCancellation()
        return FeedIntakeAnalysisScreenSnapshot(
            eligiblePens: eligiblePens,
            validSelectedPenIDs: validSelectedPenIDs,
            result: result,
            todayFeedCount: todayFeeds.count,
            todayKilograms: todayKilograms
        )
    }
}

enum FeedAnalysisNumberFormatter {
    static func integer(_ value: Double?) -> String { text(value, maximumFractionDigits: 0) }
    static func percent(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return "\(text(ratio * 100, maximumFractionDigits: 1))%"
    }
    static func total(_ value: Double?) -> String { text(value, maximumFractionDigits: 2) }
    static func perHead(_ value: Double?) -> String { text(value, maximumFractionDigits: 3) }

    static func text(_ value: Double?, maximumFractionDigits: Int = 3) -> String {
        guard let value, value.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = min(3, max(0, maximumFractionDigits))
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }
}

enum FeedIntakeAnalysisEngine {
    static func calculate(input: FeedIntakeAnalysisInput) -> FeedIntakeAnalysisResult {
        guard input.start < input.end else {
            return emptyResult(input: input)
        }
        let presence = PresenceIndex(input: input)
        let feeds = input.feeds.filter { $0.occurredAt >= input.start && $0.occurredAt < input.end }
        var slices = limitedSlices(input: input, feeds: feeds.filter { $0.mode == .limited })
        let freeResult = freeChoiceSlices(input: input, feeds: feeds.filter { $0.mode == .freeChoice })
        slices.append(contentsOf: freeResult.slices)

        let penIDs = Set(slices.map(\.penID)).union(freeResult.incompletePenIDs)
        let penNames = Dictionary(uniqueKeysWithValues: input.pens.map { ($0.id, $0.name) })
        var penResults: [FeedIntakePenResult] = []
        for penID in penIDs {
            let penSlices = slices.filter { $0.penID == penID }
            let result = penResult(
                penID: penID,
                name: penNames[penID] ?? "未知圈舍",
                slices: penSlices,
                extraIncompleteCount: freeResult.incompleteCountByPen[penID, default: 0],
                input: input,
                presence: presence
            )
            penResults.append(result)
        }
        penResults.sort { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let complete = penResults.reduce(0) { $0 + $1.completeIntervalCount }
        let incomplete = penResults.reduce(0) { $0 + $1.incompleteIntervalCount }
        let measuredKg = slices.filter { $0.evidence.contains(.measured) && !$0.evidence.contains(.estimated) }
            .reduce(0) { $0 + $1.components.reduce(0) { $0 + max(0, $1.freshKilograms) } }
        let estimatedKg = slices.filter { $0.evidence.contains(.estimated) }
            .reduce(0) { $0 + $1.components.reduce(0) { $0 + max(0, $1.freshKilograms) } }
        let classifiedKg = measuredKg + estimatedKg
        let overview = FeedIntakeFarmOverview(
            totalFreshKilograms: penResults.reduce(0) { $0 + $1.freshKilograms },
            feedingSheepDays: penResults.reduce(0) { $0 + $1.sheepDays },
            effectivePenCount: penResults.filter { $0.freshKilograms > 0 }.count,
            recordCompleteness: complete + incomplete > 0 ? Double(complete) / Double(complete + incomplete) : 0,
            measuredRatio: classifiedKg > 0 ? measuredKg / classifiedKg : 0,
            estimatedRatio: classifiedKg > 0 ? estimatedKg / classifiedKg : 0,
            conflictCount: penResults.reduce(0) { $0 + $1.conflicts.count }
        )
        return FeedIntakeAnalysisResult(
            start: input.start,
            end: input.end,
            sourceRevision: sourceRevision(input: input),
            overview: overview,
            pens: penResults
        )
    }

    private struct IntakeComponent: Sendable, Hashable {
        let ingredientID: UUID?
        let ingredientBatchID: UUID?
        let name: String
        var freshKilograms: Double
        let pricePerKilogram: Double?
        let nutrients: FeedNutrients

        init(
            ingredientID: UUID?,
            ingredientBatchID: UUID?,
            name: String,
            freshKilograms: Double,
            pricePerKilogram: Double?,
            nutrients: FeedNutrients
        ) {
            self.ingredientID = ingredientID
            self.ingredientBatchID = ingredientBatchID
            self.name = name
            self.freshKilograms = freshKilograms
            self.pricePerKilogram = pricePerKilogram
            self.nutrients = nutrients
        }

        init(_ line: FeedAnalysisLineSnapshot) {
            ingredientID = line.ingredientID
            ingredientBatchID = line.ingredientBatchID
            name = line.ingredientName
            freshKilograms = line.freshKilograms
            pricePerKilogram = line.pricePerKilogram
            nutrients = line.nutrients
        }
    }

    private struct IntakeSlice: Sendable, Hashable {
        let penID: UUID
        let start: Date
        let end: Date
        let reportDate: Date
        var components: [IntakeComponent]
        let excludedSheepIDs: Set<UUID>
        let historicalHeadCount: Int?
        var evidence: Set<FeedIntakeEvidence>
        var conflicts: [String]
    }

    private struct FreeChoiceSliceResult {
        var slices: [IntakeSlice] = []
        var incompleteCountByPen: [UUID: Int] = [:]
        var incompletePenIDs = Set<UUID>()
    }

    private static func limitedSlices(
        input: FeedIntakeAnalysisInput,
        feeds: [FeedAnalysisFeedSnapshot]
    ) -> [IntakeSlice] {
        let calendar = input.calendar
        let observations = input.troughObservations.filter {
            $0.observedAt >= input.start && $0.observedAt < input.end
        }
        let grouped = Dictionary(grouping: feeds) { feed in
            LimitedKey(penID: feed.penID, day: calendar.startOfDay(for: feed.occurredAt))
        }
        let orderedKeys = grouped.keys.sorted { lhs, rhs in
            lhs.day == rhs.day ? lhs.penID.uuidString < rhs.penID.uuidString : lhs.day < rhs.day
        }
        var result: [IntakeSlice] = []
        for key in orderedKeys {
            guard let dayFeeds = grouped[key], !dayFeeds.isEmpty else { continue }
            let nextDay = calendar.date(byAdding: .day, value: 1, to: key.day) ?? input.end
            var components = dayFeeds.flatMap { $0.lines.map(IntakeComponent.init) }
            let feedIDs = Set(dayFeeds.map(\.id))
            var matchedObservations = observations.filter {
                $0.penID == key.penID &&
                    $0.observedAt >= key.day && $0.observedAt < nextDay &&
                    ($0.relatedFeedRecordID.map(feedIDs.contains) ?? false)
            }
            if matchedObservations.isEmpty {
                let feederNames = Set(dayFeeds.map { normalizedFeeder($0.feederName) })
                matchedObservations = observations.filter {
                    $0.penID == key.penID &&
                        $0.relatedFeedRecordID == nil &&
                        $0.observedAt >= key.day && $0.observedAt < nextDay &&
                        feederNames.contains(normalizedFeeder($0.feederName))
                }
                if matchedObservations.count > 1, let latest = matchedObservations.max(by: { $0.observedAt < $1.observedAt }) {
                    matchedObservations = [latest]
                }
            }

            var evidence = Set<FeedIntakeEvidence>()
            var conflicts: [String] = []
            var remainders: [(quantity: Double, composition: [FeedTroughCompositionComponent])] = []
            if !matchedObservations.isEmpty {
                evidence.insert(.measured)
                for observation in matchedObservations {
                    if observation.measurementMethod.isEstimated {
                        evidence.insert(.estimated)
                    }
                    remainders.append((observation.actualRemainingKilograms, observation.composition))
                }
            } else {
                let legacy = dayFeeds.compactMap { feed -> (Double, [FeedTroughCompositionComponent])? in
                    guard let remaining = feed.legacyRemainingKilograms else { return nil }
                    return (remaining, feed.legacyRemainingComposition)
                }
                if legacy.isEmpty {
                    evidence.insert(.estimated)
                } else {
                    evidence.insert(.estimated)
                    remainders = legacy
                }
            }

            for remainder in remainders {
                let totalAvailable = components.reduce(0) { $0 + $1.freshKilograms }
                if remainder.quantity > totalAvailable + 0.000_001 {
                    conflicts.append("\(dateText(key.day, calendar: calendar)) 盘槽剩余量大于投料量")
                    evidence.insert(.conflict)
                    continue
                }
                let residualComponents = componentsForRemainder(
                    quantity: remainder.quantity,
                    explicit: remainder.composition,
                    available: components
                )
                if !subtract(residualComponents, from: &components) {
                    conflicts.append("\(dateText(key.day, calendar: calendar)) 剩料组成与投料组成不一致")
                    evidence.insert(.conflict)
                }
            }
            if evidence.contains(.conflict) { components = [] }
            result.append(IntakeSlice(
                penID: key.penID,
                start: max(input.start, key.day),
                end: min(input.end, nextDay),
                reportDate: key.day,
                components: mergeComponents(components),
                excludedSheepIDs: dayFeeds.reduce(into: Set<UUID>()) { $0.formUnion($1.excludedSheepIDs) },
                historicalHeadCount: dayFeeds.compactMap(\.historicalHeadCountSnapshot).max(),
                evidence: evidence,
                conflicts: conflicts
            ))
        }
        return result
    }

    private static func freeChoiceSlices(
        input: FeedIntakeAnalysisInput,
        feeds: [FeedAnalysisFeedSnapshot]
    ) -> FreeChoiceSliceResult {
        var result = FreeChoiceSliceResult()
        let freeFeedIDs = Set(feeds.map(\.id))
        let observations = input.troughObservations.filter {
            $0.observedAt <= input.end && ($0.relatedFeedRecordID.map(freeFeedIDs.contains) ?? true)
        }
        let keys = Set(feeds.map { FreeChoiceKey(penID: $0.penID, feeder: normalizedFeeder($0.feederName)) })
            .union(observations.map { FreeChoiceKey(penID: $0.penID, feeder: normalizedFeeder($0.feederName)) })

        for key in keys {
            let groupFeeds = feeds.filter {
                $0.penID == key.penID && normalizedFeeder($0.feederName) == key.feeder
            }.sorted { $0.occurredAt < $1.occurredAt }
            let groupObservations = observations.filter {
                $0.penID == key.penID && normalizedFeeder($0.feederName) == key.feeder
            }.sorted { lhs, rhs in
                lhs.observedAt == rhs.observedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.observedAt < rhs.observedAt
            }

            if groupObservations.count >= 2 {
                for (opening, closing) in zip(groupObservations, groupObservations.dropFirst()) {
                    guard opening.observedAt >= input.start,
                          opening.observedAt < closing.observedAt,
                          closing.observedAt <= input.end else { continue }
                    let intervalFeeds = groupFeeds.filter {
                        $0.occurredAt > opening.observedAt && $0.occurredAt <= closing.observedAt
                    }
                    let openingAvailable = max(0, opening.actualRemainingKilograms - opening.discardedKilograms)
                    var components = openingComponents(
                        observation: opening,
                        remainingAfterDiscard: openingAvailable
                    )
                    components.append(contentsOf: intervalFeeds.flatMap { $0.lines.map(IntakeComponent.init) })
                    let totalAvailable = components.reduce(0) { $0 + $1.freshKilograms }
                    var evidence: Set<FeedIntakeEvidence> = [.measured]
                    if opening.measurementMethod.isEstimated || closing.measurementMethod.isEstimated {
                        evidence.insert(.estimated)
                    }
                    var conflicts: [String] = []
                    if closing.actualRemainingKilograms > totalAvailable + 0.000_001 {
                        evidence.insert(.conflict)
                        conflicts.append("\(key.feeder) 闭合区间出现负消耗")
                        components = []
                    } else {
                        let closingComponents = componentsForRemainder(
                            quantity: closing.actualRemainingKilograms,
                            explicit: closing.composition,
                            available: components
                        )
                        if !subtract(closingComponents, from: &components) {
                            evidence.insert(.conflict)
                            conflicts.append("\(key.feeder) 盘槽组成超过区间可用量")
                            components = []
                        }
                    }
                    result.slices.append(IntakeSlice(
                        penID: key.penID,
                        start: opening.observedAt,
                        end: closing.observedAt,
                        reportDate: input.calendar.startOfDay(for: closing.observedAt.addingTimeInterval(-0.001)),
                        components: mergeComponents(components),
                        excludedSheepIDs: intervalFeeds.reduce(into: Set<UUID>()) { $0.formUnion($1.excludedSheepIDs) },
                        historicalHeadCount: intervalFeeds.compactMap(\.historicalHeadCountSnapshot).max(),
                        evidence: evidence,
                        conflicts: conflicts
                    ))
                }
                if let last = groupObservations.last, last.observedAt < input.end,
                   groupFeeds.contains(where: { $0.occurredAt > last.observedAt }) {
                    result.incompleteCountByPen[key.penID, default: 0] += 1
                    result.incompletePenIDs.insert(key.penID)
                }
            } else if groupObservations.isEmpty && !groupFeeds.isEmpty {
                // Compatibility path for old free-choice records: additions are
                // retained as estimates. Once a trough timeline exists, its
                // final unclosed interval is never estimated.
                let byDay = Dictionary(grouping: groupFeeds) { input.calendar.startOfDay(for: $0.occurredAt) }
                for (day, dayFeeds) in byDay {
                    let nextDay = input.calendar.date(byAdding: .day, value: 1, to: day) ?? input.end
                    result.slices.append(IntakeSlice(
                        penID: key.penID,
                        start: max(day, input.start),
                        end: min(nextDay, input.end),
                        reportDate: day,
                        components: mergeComponents(dayFeeds.flatMap { $0.lines.map(IntakeComponent.init) }),
                        excludedSheepIDs: dayFeeds.reduce(into: Set<UUID>()) { $0.formUnion($1.excludedSheepIDs) },
                        historicalHeadCount: dayFeeds.compactMap(\.historicalHeadCountSnapshot).max(),
                        evidence: [.estimated],
                        conflicts: []
                    ))
                }
            } else if groupObservations.count == 1,
                      let boundary = groupObservations.first,
                      groupFeeds.contains(where: { $0.occurredAt > boundary.observedAt && $0.occurredAt < input.end }) {
                result.incompleteCountByPen[key.penID, default: 0] += 1
                result.incompletePenIDs.insert(key.penID)
            }
        }
        return result
    }

    private static func penResult(
        penID: UUID,
        name: String,
        slices: [IntakeSlice],
        extraIncompleteCount: Int,
        input: FeedIntakeAnalysisInput,
        presence: PresenceIndex
    ) -> FeedIntakePenResult {
        let usable = slices.filter { !$0.evidence.contains(.conflict) && $0.start < $0.end }
        let mergedIntervals = mergeIntervals(usable.map { ($0.start, $0.end) })
        var sheepDays = 0.0
        var sheepDayEvidence = Set<FeedIntakeEvidence>()
        var sheepDayConflicts: [String] = []
        var purposeDays: [FeedAnalysisStage: Double] = [:]
        for interval in mergedIntervals {
            let overlapping = usable.filter { $0.start < interval.end && $0.end > interval.start }
            let excluded = overlapping.reduce(into: Set<UUID>()) { $0.formUnion($1.excludedSheepIDs) }
            let calculation = presence.sheepDays(
                in: penID,
                from: interval.start,
                to: interval.end,
                excluding: excluded
            )
            if calculation.total > 0 {
                sheepDays += calculation.total
            } else if let historicalHeadCount = overlapping.compactMap(\.historicalHeadCount).max() {
                sheepDays += Double(historicalHeadCount) * interval.end.timeIntervalSince(interval.start) / 86_400
                sheepDayEvidence.insert(.historicalHeadCount)
            }
            sheepDayEvidence.formUnion(calculation.evidence)
            sheepDayConflicts.append(contentsOf: calculation.conflicts)
            for (stage, value) in calculation.stageDays { purposeDays[stage, default: 0] += value }
        }

        let components = mergeComponents(usable.flatMap(\.components))
        let fresh = components.reduce(0) { $0 + $1.freshKilograms }
        let summary = nutritionSummary(components)
        let mp = mpSupply(summary: summary)
        let divisor = sheepDays > 0 ? sheepDays : nil
        let nutrition = FeedAnalysisNutritionResult(
            summary: summary,
            freshKilogramsPerSheepDay: divisor.map { fresh / $0 },
            dryMatterKilogramsPerSheepDay: divisor.flatMap { divisor in summary.dryMatterKilograms.map { $0 / divisor } },
            meMJPerSheepDay: divisor.flatMap { divisor in summary.meMJ.map { $0 / divisor } },
            crudeProteinGramsPerSheepDay: divisor.flatMap { divisor in summary.crudeProteinKilograms.map { $0 * 1_000 / divisor } },
            metabolizableProteinGramsPerSheepDay: divisor.flatMap { divisor in mp.grams.map { $0 / divisor } },
            ndfGramsPerSheepDay: divisor.flatMap { divisor in summary.ndfKilograms.map { $0 * 1_000 / divisor } },
            adfGramsPerSheepDay: divisor.flatMap { divisor in summary.adfKilograms.map { $0 * 1_000 / divisor } },
            mpEstimated: mp.estimated,
            mpBlockedReason: mp.blockedReason
        )

        let ingredients = Dictionary(grouping: components) { component in
            "\(component.ingredientID?.uuidString ?? "unknown")|\(component.ingredientBatchID?.uuidString ?? "none")|\(component.name)"
        }.map { key, values in
            let merged = mergeComponents(values)
            let total = merged.reduce(0) { $0 + $1.freshKilograms }
            return FeedAnalysisIngredientResult(
                id: key,
                ingredientID: values.first?.ingredientID,
                ingredientBatchID: values.first?.ingredientBatchID,
                name: values.first?.name ?? "未知原料",
                freshKilograms: total,
                freshKilogramsPerSheepDay: divisor.map { total / $0 },
                nutrition: nutritionSummary(merged)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let growth = growthResult(
            penID: penID,
            stageDays: purposeDays,
            nutrition: nutrition,
            input: input,
            presence: presence,
            hasSheepDayConflict: !sheepDayConflicts.isEmpty
        )
        let daily = dailyTrend(
            penID: penID,
            slices: usable,
            input: input,
            presence: presence
        )
        let evidence = slices.reduce(into: sheepDayEvidence) { $0.formUnion($1.evidence) }
        let conflicts = Array(Set(slices.flatMap(\.conflicts) + sheepDayConflicts)).sorted()
        return FeedIntakePenResult(
            id: penID,
            name: name,
            freshKilograms: fresh,
            sheepDays: sheepDays,
            ingredients: ingredients,
            nutrition: nutrition,
            growth: growth,
            dailyTrend: daily,
            evidence: evidence,
            conflicts: conflicts,
            completeIntervalCount: slices.filter { !$0.evidence.contains(.conflict) }.count,
            incompleteIntervalCount: extraIncompleteCount + slices.filter { $0.evidence.contains(.conflict) }.count
        )
    }

    private static func dailyTrend(
        penID: UUID,
        slices: [IntakeSlice],
        input: FeedIntakeAnalysisInput,
        presence: PresenceIndex
    ) -> [FeedAnalysisDailyTrend] {
        let grouped = Dictionary(grouping: slices, by: \.reportDate)
        return grouped.keys.sorted().map { day in
            let values = grouped[day] ?? []
            let components = mergeComponents(values.flatMap(\.components))
            let fresh = components.reduce(0) { $0 + $1.freshKilograms }
            let summary = nutritionSummary(components)
            let intervals = mergeIntervals(values.map { ($0.start, $0.end) })
            var days = 0.0
            for interval in intervals {
                let excluded = values.filter { $0.start < interval.end && $0.end > interval.start }
                    .reduce(into: Set<UUID>()) { $0.formUnion($1.excludedSheepIDs) }
                let calculation = presence.sheepDays(in: penID, from: interval.start, to: interval.end, excluding: excluded)
                if calculation.total > 0 {
                    days += calculation.total
                } else if let historicalHeadCount = values.compactMap(\.historicalHeadCount).max() {
                    days += Double(historicalHeadCount) * interval.end.timeIntervalSince(interval.start) / 86_400
                }
            }
            return FeedAnalysisDailyTrend(
                date: day,
                freshKilograms: fresh,
                sheepDays: days,
                dmiKilogramsPerSheepDay: days > 0 ? summary.dryMatterKilograms.map { $0 / days } : nil,
                meMJPerSheepDay: days > 0 ? summary.meMJ.map { $0 / days } : nil,
                evidence: values.reduce(into: Set<FeedIntakeEvidence>()) { $0.formUnion($1.evidence) }
            )
        }
    }

    private struct MPSupply {
        let grams: Double?
        let estimated: Bool
        let blockedReason: String?
    }

    private static func mpSupply(summary: FeedRecipeNutritionSummary) -> MPSupply {
        guard let dm = summary.dryMatterKilograms,
              let cp = summary.crudeProteinKilograms,
              let meMJ = summary.meMJ else {
            return MPSupply(grams: nil, estimated: false, blockedReason: "干物质、粗蛋白或ME覆盖不足")
        }
        let cpG = cp * 1_000
        let hasFractions = summary.coverage[.rdp]?.isComplete == true &&
            summary.coverage[.rup]?.isComplete == true &&
            summary.coverage[.adip]?.isComplete == true
        let rdpG: Double
        let rupG: Double
        let adipG: Double
        let estimated: Bool
        if hasFractions,
           let rdp = summary.nutrients.rdp,
           let rup = summary.nutrients.rup,
           let adip = summary.nutrients.adip {
            rdpG = dm * rdp * 10
            rupG = dm * rup * 10
            adipG = dm * adip * 10
            estimated = false
        } else {
            rdpG = cpG * 0.65
            rupG = cpG * 0.35
            adipG = 0
            estimated = true
        }
        let digestibleRUP = max(0, rupG - adipG) * 0.80
        let microbialMP = min(rdpG * 0.64, max(0, meMJ) * 6.4)
        return MPSupply(grams: digestibleRUP + microbialMP, estimated: estimated, blockedReason: nil)
    }

    private static func growthResult(
        penID: UUID,
        stageDays: [FeedAnalysisStage: Double],
        nutrition: FeedAnalysisNutritionResult,
        input: FeedIntakeAnalysisInput,
        presence: PresenceIndex,
        hasSheepDayConflict: Bool
    ) -> FeedGrowthSupportResult {
        let totalStageDays = stageDays.values.reduce(0, +)
        let dominant = stageDays.max { $0.value < $1.value }
        let ratio = dominant.map { totalStageDays > 0 ? $0.value / totalStageDays : 0 }
        let stage = dominant?.key
        let endInstant = input.end.addingTimeInterval(-0.001)
        let stageSheep = presence.sheep(in: penID, at: endInstant).filter { item in
            stage.map { item.stage == $0 } ?? false
        }
        let lookback = input.calendar.date(byAdding: .day, value: -60, to: input.end) ?? input.start
        let recentWeights = input.weights.filter {
            $0.occurredAt >= lookback && $0.occurredAt < input.end && $0.kilograms > 0
        }
        let latestBySheep = Dictionary(grouping: recentWeights, by: \.sheepID).compactMapValues {
            $0.max { $0.occurredAt < $1.occurredAt }
        }
        let weightValues = stageSheep.compactMap { latestBySheep[$0.id]?.kilograms }
        let required = max(Int(ceil(Double(stageSheep.count) * 0.5)), min(3, stageSheep.count))
        let coverage = stageSheep.isEmpty ? 0 : Double(weightValues.count) / Double(stageSheep.count)
        let averageWeight = weightValues.isEmpty ? nil : weightValues.reduce(0, +) / Double(weightValues.count)
        let observed = observedADG(sheepIDs: Set(stageSheep.map(\.id)), weights: recentWeights)

        func blocked(_ reason: String, model: String) -> FeedGrowthSupportResult {
            FeedGrowthSupportResult(
                stage: stage,
                dominantStageRatio: ratio,
                averageWeightKilograms: averageWeight,
                weightCoverage: coverage,
                weightSampleCount: weightValues.count,
                requiredWeightSampleCount: required,
                maintenanceMEPerDay: nil,
                maintenanceMPGramsPerDay: nil,
                maintenanceMEGap: nil,
                maintenanceMPGapGrams: nil,
                nutritionPotentialADGKg: nil,
                observedADGKg: observed.value,
                observedSampleCount: observed.count,
                calibratedExpectedADGKg: nil,
                limitingFactor: nil,
                blockedReason: reason,
                modelDescription: model
            )
        }

        guard !hasSheepDayConflict else { return blocked("羊天快照与事件时间线冲突", model: "ME + MP") }
        guard let stage, let ratio, ratio >= 0.80 else {
            return blocked("混群圈舍没有达到80%的单一生长阶段", model: "ME + MP")
        }
        if stage == .lactatingLamb {
            return blocked("哺乳羔羊无法从圈舍饲料中分离母乳贡献", model: "不单独预测")
        }
        guard stage != .unknown else { return blocked("生产阶段未分类", model: "ME + MP") }
        guard weightValues.count >= required, coverage >= 0.5, let averageWeight else {
            return blocked("结束日前60天体重覆盖不足", model: "ME + MP")
        }
        guard let me = nutrition.meMJPerSheepDay,
              let mp = nutrition.metabolizableProteinGramsPerSheepDay else {
            return blocked(nutrition.mpBlockedReason ?? "ME或MP覆盖不足", model: "ME + MP")
        }
        let metabolicWeight = pow(averageWeight, 0.75)
        let maintenanceME = 0.42 * metabolicWeight
        let maintenanceMP = 3.8 * metabolicWeight
        let meGap = me - maintenanceME
        let mpGap = mp - maintenanceMP

        if stage == .breedingEwe || stage == .breedingRam {
            return FeedGrowthSupportResult(
                stage: stage,
                dominantStageRatio: ratio,
                averageWeightKilograms: averageWeight,
                weightCoverage: coverage,
                weightSampleCount: weightValues.count,
                requiredWeightSampleCount: required,
                maintenanceMEPerDay: maintenanceME,
                maintenanceMPGramsPerDay: maintenanceMP,
                maintenanceMEGap: meGap,
                maintenanceMPGapGrams: mpGap,
                nutritionPotentialADGKg: nil,
                observedADGKg: observed.value,
                observedSampleCount: observed.count,
                calibratedExpectedADGKg: nil,
                limitingFactor: min(meGap, mpGap) < 0 ? (meGap <= mpGap ? "维持能量不足" : "维持代谢蛋白不足") : "满足维持需求",
                blockedReason: nil,
                modelDescription: "维持需要与营养差额"
            )
        }
        guard stage.supportsGrowthPrediction else { return blocked("该阶段不使用生长预测模型", model: "ME + MP") }

        let gainMEPerKg = min(max(12.8 + max(0, averageWeight - 25) * 0.065, 14), 17.5)
        let gainMPPerKg = min(max(250 + max(0, averageWeight - 30) * 1.2, 250), 295)
        let physiologicalMax = averageWeight < 28 ? 0.48 : 0.60
        let energyPotential = max(0, meGap / gainMEPerKg)
        let proteinPotential = max(0, mpGap / gainMPPerKg)
        let potential = min(energyPotential, proteinPotential, physiologicalMax)
        let calibrated = observed.value.map {
            min(physiologicalMax, max(0, $0) * 0.65 + potential * 0.35)
        } ?? potential
        let limiting: String
        if nutrition.mpEstimated {
            limiting = energyPotential <= proteinPotential ? "能量限制（MP为估算模型）" : "代谢蛋白限制（MP为估算模型）"
        } else {
            limiting = energyPotential <= proteinPotential ? "能量限制" : "代谢蛋白限制"
        }
        return FeedGrowthSupportResult(
            stage: stage,
            dominantStageRatio: ratio,
            averageWeightKilograms: averageWeight,
            weightCoverage: coverage,
            weightSampleCount: weightValues.count,
            requiredWeightSampleCount: required,
            maintenanceMEPerDay: maintenanceME,
            maintenanceMPGramsPerDay: maintenanceMP,
            maintenanceMEGap: meGap,
            maintenanceMPGapGrams: mpGap,
            nutritionPotentialADGKg: potential,
            observedADGKg: observed.value,
            observedSampleCount: observed.count,
            calibratedExpectedADGKg: calibrated,
            limitingFactor: limiting,
            blockedReason: nil,
            modelDescription: nutrition.mpEstimated ? "ME + MP（仅CP时采用Plus兼容估算）" : "ME + MP"
        )
    }

    private static func observedADG(
        sheepIDs: Set<UUID>,
        weights: [FeedAnalysisWeightSnapshot]
    ) -> (value: Double?, count: Int) {
        let values = Dictionary(grouping: weights.filter { sheepIDs.contains($0.sheepID) }, by: \.sheepID)
            .compactMap { _, records -> Double? in
                let ordered = records.sorted { $0.occurredAt < $1.occurredAt }
                guard let first = ordered.first, let last = ordered.last else { return nil }
                let days = last.occurredAt.timeIntervalSince(first.occurredAt) / 86_400
                guard days >= 7 else { return nil }
                let value = (last.kilograms - first.kilograms) / days
                return value >= 0.05 && value <= 0.85 ? value : nil
            }
        return (values.isEmpty ? nil : values.reduce(0, +) / Double(values.count), values.count)
    }

    private struct SheepDayCalculation {
        let total: Double
        let stageDays: [FeedAnalysisStage: Double]
        let evidence: Set<FeedIntakeEvidence>
        let conflicts: [String]
    }

    private struct PresenceIndex {
        let input: FeedIntakeAnalysisInput
        let sheepByID: [UUID: FeedAnalysisSheepSnapshot]
        let transfersBySheep: [UUID: [FeedAnalysisTransferSnapshot]]
        let removalBySheep: [UUID: Date]
        let snapshotPurposesByPen: [UUID: Set<String>]

        init(input: FeedIntakeAnalysisInput) {
            self.input = input
            sheepByID = Dictionary(uniqueKeysWithValues: input.sheep.map { ($0.id, $0) })
            transfersBySheep = Dictionary(grouping: input.transfers, by: \.sheepID).mapValues {
                $0.sorted {
                    if $0.occurredAt == $1.occurredAt {
                        if $0.recordedAt == $1.recordedAt { return $0.id.uuidString < $1.id.uuidString }
                        return $0.recordedAt < $1.recordedAt
                    }
                    return $0.occurredAt < $1.occurredAt
                }
            }
            var removalDates: [UUID: Date] = [:]
            for value in input.removals {
                if removalDates[value.sheepID].map({ value.occurredAt < $0 }) ?? true {
                    removalDates[value.sheepID] = value.occurredAt
                }
            }
            removalBySheep = removalDates
            snapshotPurposesByPen = Dictionary(grouping: input.dailyPenCounts, by: \.penID)
                .mapValues { Set($0.map(\.purpose)) }
        }

        func sheep(in penID: UUID, at date: Date) -> [FeedAnalysisSheepSnapshot] {
            input.sheep.filter { item in
                isPresent(item, at: date) && pen(for: item, at: date) == penID
            }
        }

        func sheepDays(
            in penID: UUID,
            from start: Date,
            to end: Date,
            excluding excluded: Set<UUID>
        ) -> SheepDayCalculation {
            guard start < end else {
                return SheepDayCalculation(total: 0, stageDays: [:], evidence: [], conflicts: [])
            }
            var day = input.calendar.startOfDay(for: start)
            var total = 0.0
            var stageDays: [FeedAnalysisStage: Double] = [:]
            var evidence = Set<FeedIntakeEvidence>()
            var conflicts: [String] = []
            while day < end {
                let nextDay = input.calendar.date(byAdding: .day, value: 1, to: day) ?? end
                let segmentStart = max(day, start)
                let segmentEnd = min(nextDay, end)
                guard segmentStart < segmentEnd else { day = nextDay; continue }
                let exact = identitySheepDays(in: penID, from: segmentStart, to: segmentEnd, excluding: excluded)
                let snapshot = snapshotCount(in: penID, on: day)
                if let snapshot {
                    // DailyPenCountRecord is an end-of-day change point. Anchor
                    // the absolute count there, then let precise entry/transfer/
                    // removal events describe the intra-day fractions.
                    let endOfDay = nextDay.addingTimeInterval(-0.001)
                    let endOfDaySheep = sheep(in: penID, at: endOfDay)
                    let identityEnd = endOfDaySheep.filter { !excluded.contains($0.id) }.count
                    let excludedEnd = endOfDaySheep.filter { excluded.contains($0.id) }.count
                    let authoritativeEnd = max(0, snapshot - excludedEnd)
                    if identityEnd == authoritativeEnd {
                        total += exact.total
                        mergeStageDays(exact.stageDays, into: &stageDays)
                    } else {
                        let duration = segmentEnd.timeIntervalSince(segmentStart) / 86_400
                        let anchored = exact.total + Double(authoritativeEnd - identityEnd) * duration
                        total += max(0, anchored)
                        mergeStageDays(exact.stageDays, into: &stageDays)
                        evidence.insert(.conflict)
                        evidence.insert(.historicalHeadCount)
                        conflicts.append("\(dateText(day, calendar: input.calendar)) 快照人数\(authoritativeEnd)与事件人数\(identityEnd)不一致")
                    }
                } else if exact.hasIdentityEvidence {
                    total += exact.total
                    mergeStageDays(exact.stageDays, into: &stageDays)
                } else {
                    evidence.insert(.historicalHeadCount)
                }
                day = nextDay
            }
            return SheepDayCalculation(total: total, stageDays: stageDays, evidence: evidence, conflicts: conflicts)
        }

        private func identitySheepDays(
            in penID: UUID,
            from start: Date,
            to end: Date,
            excluding excluded: Set<UUID>
        ) -> (total: Double, stageDays: [FeedAnalysisStage: Double], hasIdentityEvidence: Bool) {
            var total = 0.0
            var stageDays: [FeedAnalysisStage: Double] = [:]
            var hasEvidence = false
            for item in input.sheep where !excluded.contains(item.id) {
                var boundaries = [start, end]
                if item.enteredAt > start && item.enteredAt < end { boundaries.append(item.enteredAt) }
                if let removed = effectiveRemoval(for: item), removed > start && removed < end { boundaries.append(removed) }
                boundaries.append(contentsOf: (transfersBySheep[item.id] ?? []).compactMap {
                    $0.occurredAt > start && $0.occurredAt < end ? $0.occurredAt : nil
                })
                let ordered = Array(Set(boundaries)).sorted()
                for (segmentStart, segmentEnd) in zip(ordered, ordered.dropFirst()) {
                    guard segmentStart < segmentEnd,
                          isPresent(item, at: segmentStart),
                          pen(for: item, at: segmentStart) == penID else { continue }
                    let days = segmentEnd.timeIntervalSince(segmentStart) / 86_400
                    total += days
                    stageDays[item.stage, default: 0] += days
                    hasEvidence = true
                }
            }
            return (total, stageDays, hasEvidence)
        }

        private func snapshotCount(in penID: UUID, on day: Date) -> Int? {
            guard let purposes = snapshotPurposesByPen[penID], !purposes.isEmpty else { return nil }
            var found = false
            var total = 0
            for purpose in purposes {
                if let value = input.dailyPenCounts.filter({
                    $0.penID == penID && $0.purpose == purpose && $0.date <= day
                }).max(by: { $0.date < $1.date }) {
                    found = true
                    total += value.count
                }
            }
            return found ? total : nil
        }

        private func effectiveRemoval(for item: FeedAnalysisSheepSnapshot) -> Date? {
            [item.removedAt, removalBySheep[item.id]].compactMap { $0 }.min()
        }

        private func isPresent(_ item: FeedAnalysisSheepSnapshot, at date: Date) -> Bool {
            item.enteredAt <= date && (effectiveRemoval(for: item).map { $0 > date } ?? true)
        }

        private func pen(for item: FeedAnalysisSheepSnapshot, at date: Date) -> UUID? {
            let latest = (transfersBySheep[item.id] ?? []).last { $0.occurredAt <= date }
            return latest?.toPenID ?? item.initialPenID
        }
    }

    private struct LimitedKey: Hashable {
        let penID: UUID
        let day: Date
    }

    private struct FreeChoiceKey: Hashable {
        let penID: UUID
        let feeder: String
    }

    private static func nutritionSummary(_ components: [IntakeComponent]) -> FeedRecipeNutritionSummary {
        FeedRecipeNutritionSummary.calculate(components: components.map {
            FeedNutritionComponent(
                ingredientID: $0.ingredientID,
                ingredientName: $0.name,
                freshKilograms: max(0, $0.freshKilograms),
                pricePerKilogram: $0.pricePerKilogram,
                nutrients: $0.nutrients
            )
        })
    }

    private static func openingComponents(
        observation: FeedAnalysisTroughSnapshot,
        remainingAfterDiscard: Double
    ) -> [IntakeComponent] {
        if !observation.composition.isEmpty, observation.actualRemainingKilograms > 0 {
            let factor = remainingAfterDiscard / observation.actualRemainingKilograms
            return observation.composition.map {
                IntakeComponent(
                    ingredientID: $0.ingredientID,
                    ingredientBatchID: $0.ingredientBatchID,
                    name: $0.ingredientNameSnapshot,
                    freshKilograms: max(0, NSDecimalNumber(decimal: $0.kilograms).doubleValue * factor),
                    pricePerKilogram: nil,
                    nutrients: nutrients(from: $0)
                )
            }
        }
        guard remainingAfterDiscard > 0 else { return [] }
        return [IntakeComponent(
            ingredientID: nil,
            ingredientBatchID: nil,
            name: "未记录料槽原料组成",
            freshKilograms: remainingAfterDiscard,
            pricePerKilogram: nil,
            nutrients: .empty
        )]
    }

    private static func componentsForRemainder(
        quantity: Double,
        explicit: [FeedTroughCompositionComponent],
        available: [IntakeComponent]
    ) -> [IntakeComponent] {
        if !explicit.isEmpty {
            return explicit.map {
                IntakeComponent(
                    ingredientID: $0.ingredientID,
                    ingredientBatchID: $0.ingredientBatchID,
                    name: $0.ingredientNameSnapshot,
                    freshKilograms: NSDecimalNumber(decimal: $0.kilograms).doubleValue,
                    pricePerKilogram: nil,
                    nutrients: nutrients(from: $0)
                )
            }
        }
        let total = available.reduce(0) { $0 + max(0, $1.freshKilograms) }
        guard quantity > 0, total > 0 else { return [] }
        return available.map {
            var value = $0
            value.freshKilograms = quantity * max(0, $0.freshKilograms) / total
            return value
        }
    }

    private static func nutrients(from component: FeedTroughCompositionComponent) -> FeedNutrients {
        var value = FeedNutritionCodec.decode(component.nutrientSnapshotJSON)
        if value.dryMatter == nil,
           let text = component.dryMatterTextSnapshot,
           let dryMatter = Double(text) {
            value.dryMatter = dryMatter
        }
        return value
    }

    private static func subtract(_ residual: [IntakeComponent], from available: inout [IntakeComponent]) -> Bool {
        for item in residual where item.freshKilograms > 0 {
            var remaining = item.freshKilograms
            let matchingIndices = available.indices.filter { index in
                if let batchID = item.ingredientBatchID {
                    return available[index].ingredientBatchID == batchID
                }
                if let ingredientID = item.ingredientID {
                    return available[index].ingredientID == ingredientID
                }
                return available[index].name == item.name
            }
            for index in matchingIndices where remaining > 0 {
                let deduction = min(remaining, max(0, available[index].freshKilograms))
                available[index].freshKilograms -= deduction
                remaining -= deduction
            }
            if remaining > 0.000_001 { return false }
        }
        available.removeAll { $0.freshKilograms <= 0.000_001 }
        return true
    }

    private static func mergeComponents(_ values: [IntakeComponent]) -> [IntakeComponent] {
        var grouped: [String: [IntakeComponent]] = [:]
        for value in values where value.freshKilograms > 0.000_001 {
            let ingredient = value.ingredientID?.uuidString ?? "unknown"
            let batch = value.ingredientBatchID?.uuidString ?? "none"
            let nutrition = FeedNutritionCodec.encode(value.nutrients)
            let price = value.pricePerKilogram.map { String($0) } ?? "nil"
            let key = "\(ingredient)|\(batch)|\(value.name)|\(nutrition)|\(price)"
            grouped[key, default: []].append(value)
        }
        return grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            var result = first
            result.freshKilograms = group.reduce(0) { $0 + $1.freshKilograms }
            return result
        }
    }

    private static func mergeIntervals(_ values: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        let ordered = values.filter { $0.start < $0.end }.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return [] }
        var result: [(start: Date, end: Date)] = []
        for value in ordered.dropFirst() {
            if value.start <= current.end {
                current.end = max(current.end, value.end)
            } else {
                result.append(current)
                current = value
            }
        }
        result.append(current)
        return result
    }

    private static func mergeStageDays(
        _ source: [FeedAnalysisStage: Double],
        into destination: inout [FeedAnalysisStage: Double]
    ) {
        for (key, value) in source { destination[key, default: 0] += value }
    }

    private static func normalizedFeeder(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "圈舍整体" : trimmed.lowercased()
    }

    private static func dateText(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func sourceRevision(input: FeedIntakeAnalysisInput) -> String {
        var values = [
            "range|\(input.start.timeIntervalSince1970)|\(input.end.timeIntervalSince1970)"
        ]
        values += input.pens.map { "pen|\($0.id)|\($0.name)" }
        values += input.sheep.map {
            "sheep|\($0.id)|\($0.purpose)|\($0.initialPenID?.uuidString ?? "")|\($0.enteredAt.timeIntervalSince1970)|\($0.removedAt?.timeIntervalSince1970 ?? -1)"
        }
        values += input.transfers.map {
            "transfer|\($0.id)|\($0.sheepID)|\($0.fromPenID?.uuidString ?? "")|\($0.toPenID?.uuidString ?? "")|\($0.occurredAt.timeIntervalSince1970)|\($0.recordedAt.timeIntervalSince1970)"
        }
        values += input.removals.map {
            "removal|\($0.id)|\($0.sheepID)|\($0.occurredAt.timeIntervalSince1970)|\($0.recordedAt.timeIntervalSince1970)"
        }
        values += input.dailyPenCounts.map {
            "count|\($0.id)|\($0.penID)|\($0.purpose)|\($0.date.timeIntervalSince1970)|\($0.count)|\($0.rebuiltAt.timeIntervalSince1970)"
        }
        values += input.feeds.map { feed in
            let lines = feed.lines.map {
                "\($0.id)|\($0.ingredientID?.uuidString ?? "")|\($0.ingredientBatchID?.uuidString ?? "")|\($0.freshKilograms)|\(FeedNutritionCodec.encode($0.nutrients))"
            }.sorted().joined(separator: ";")
            let excluded = feed.excludedSheepIDs.map(\.uuidString).sorted().joined(separator: ",")
            return "feed|\(feed.id)|\(feed.penID)|\(feed.mode.rawValue)|\(feed.occurredAt.timeIntervalSince1970)|\(feed.feederName)|\(feed.legacyRemainingKilograms ?? -1)|\(excluded)|\(lines)"
        }
        values += input.troughObservations.map {
            "trough|\($0.id)|\($0.penID)|\($0.relatedFeedRecordID?.uuidString ?? "")|\($0.feederName)|\($0.observedAt.timeIntervalSince1970)|\($0.actualRemainingKilograms)|\($0.discardedKilograms)|\($0.measurementMethod.rawValue)|\(FeedTroughCompositionCodec.encode($0.composition))"
        }
        values += input.weights.map {
            "weight|\($0.id)|\($0.sheepID)|\($0.kilograms)|\($0.occurredAt.timeIntervalSince1970)"
        }
        let data = Data(values.sorted().joined(separator: "\n").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func emptyResult(input: FeedIntakeAnalysisInput) -> FeedIntakeAnalysisResult {
        FeedIntakeAnalysisResult(
            start: input.start,
            end: input.end,
            sourceRevision: sourceRevision(input: input),
            overview: FeedIntakeFarmOverview(
                totalFreshKilograms: 0,
                feedingSheepDays: 0,
                effectivePenCount: 0,
                recordCompleteness: 0,
                measuredRatio: 0,
                estimatedRatio: 0,
                conflictCount: 0
            ),
            pens: []
        )
    }
}

enum FeedIntakeAnalysisSnapshotFactory {
    static func make(
        farmID: UUID,
        start: Date,
        end: Date,
        calendar: Calendar = .current,
        selectedPenIDs: Set<UUID> = [],
        pens: [PenRecord],
        sheep: [SheepRecord],
        transfers: [TransferRecord],
        removals: [RemovalRecord],
        dailyPenCounts: [DailyPenCountRecord],
        feeds: [FeedRecord],
        lines: [FeedRecordLine],
        troughObservations: [FeedTroughObservationRecord],
        weights: [WeightRecord]
    ) -> FeedIntakeAnalysisInput {
        let farmPens = pens.filter {
            $0.farmID == farmID && $0.deletedAt == nil &&
                (selectedPenIDs.isEmpty || selectedPenIDs.contains($0.id))
        }
        let penIDs = Set(farmPens.map(\.id))
        let farmSheep = sheep.filter { $0.farmID == farmID && $0.deletedAt == nil }
        let farmFeeds = feeds.filter {
            $0.farmID == farmID && $0.deletedAt == nil &&
                (selectedPenIDs.isEmpty || penIDs.contains($0.penID))
        }
        let feedByID = Dictionary(uniqueKeysWithValues: farmFeeds.map { ($0.id, $0) })
        let linesByFeed = Dictionary(grouping: lines.filter {
            $0.farmID == farmID && $0.deletedAt == nil && feedByID[$0.feedRecordID] != nil
        }, by: \.feedRecordID)

        let feedSnapshots = farmFeeds.map { feed -> FeedAnalysisFeedSnapshot in
            let feedLines = (linesByFeed[feed.id] ?? []).map(lineSnapshot)
            return FeedAnalysisFeedSnapshot(
                id: feed.id,
                penID: feed.penID,
                mode: feed.mode,
                occurredAt: feed.occurredAt,
                feederName: feed.feederName,
                lines: feedLines,
                excludedSheepIDs: Set(feed.excludedSheepIDs),
                historicalHeadCountSnapshot: feed.actualHeadCountSnapshot,
                legacyRemainingKilograms: feed.remainingKilogramsText.flatMap(Double.init),
                legacyDiscardedKilograms: feed.discardedKilogramsText.flatMap(Double.init),
                legacyRemainingComposition: legacyComposition(feed: feed, lines: feedLines)
            )
        }

        return FeedIntakeAnalysisInput(
            start: start,
            end: end,
            calendar: calendar,
            pens: farmPens.map { FeedAnalysisPenSnapshot(id: $0.id, name: $0.name) },
            sheep: farmSheep.map {
                FeedAnalysisSheepSnapshot(
                    id: $0.id,
                    earTag: $0.earTag,
                    purpose: $0.purpose,
                    sex: $0.sex,
                    isBreedingRam: $0.isBreedingRam,
                    initialPenID: $0.initialPenID,
                    enteredAt: $0.enteredAt,
                    removedAt: $0.removedAt
                )
            },
            transfers: transfers.filter { $0.farmID == farmID && $0.deletedAt == nil }.map {
                FeedAnalysisTransferSnapshot(
                    id: $0.id,
                    sheepID: $0.sheepID,
                    fromPenID: $0.fromPenID,
                    toPenID: $0.toPenID,
                    occurredAt: $0.occurredAt,
                    recordedAt: $0.recordedAt
                )
            },
            removals: removals.filter { $0.farmID == farmID && $0.deletedAt == nil }.map {
                FeedAnalysisRemovalSnapshot(
                    id: $0.id,
                    sheepID: $0.sheepID,
                    occurredAt: $0.occurredAt,
                    recordedAt: $0.recordedAt
                )
            },
            dailyPenCounts: dailyPenCounts.filter {
                $0.farmID == farmID && (selectedPenIDs.isEmpty || penIDs.contains($0.penID))
            }.map {
                FeedAnalysisDailyPenCountSnapshot(
                    id: $0.id,
                    penID: $0.penID,
                    purpose: $0.purpose,
                    date: $0.date,
                    count: $0.count,
                    rebuiltAt: $0.rebuiltAt
                )
            },
            feeds: feedSnapshots,
            troughObservations: troughObservations.filter {
                $0.farmID == farmID && $0.deletedAt == nil &&
                    (selectedPenIDs.isEmpty || penIDs.contains($0.penID))
            }.map {
                FeedAnalysisTroughSnapshot(
                    id: $0.id,
                    penID: $0.penID,
                    relatedFeedRecordID: $0.relatedFeedRecordID,
                    feederName: $0.feederName,
                    observedAt: $0.observedAt,
                    actualRemainingKilograms: NSDecimalNumber(decimal: $0.actualRemainingKilograms).doubleValue,
                    discardedKilograms: NSDecimalNumber(decimal: $0.discardedKilograms).doubleValue,
                    measurementMethod: $0.measurementMethod,
                    composition: $0.composition
                )
            },
            weights: weights.filter {
                $0.farmID == farmID && $0.deletedAt == nil
            }.map {
                FeedAnalysisWeightSnapshot(
                    id: $0.id,
                    sheepID: $0.sheepID,
                    kilograms: NSDecimalNumber(decimal: $0.kilograms).doubleValue,
                    occurredAt: $0.occurredAt
                )
            }
        )
    }

    private static func lineSnapshot(_ line: FeedRecordLine) -> FeedAnalysisLineSnapshot {
        var nutrients = FeedNutritionCodec.decode(line.nutrientSnapshotJSON)
        if nutrients.dryMatter == nil,
           let text = line.dryMatterTextSnapshot,
           let dryMatter = Double(text) {
            nutrients.dryMatter = dryMatter
        }
        return FeedAnalysisLineSnapshot(
            id: line.id,
            ingredientID: line.ingredientID,
            ingredientBatchID: line.ingredientBatchID,
            ingredientName: line.ingredientNameSnapshot,
            freshKilograms: NSDecimalNumber(decimal: line.kilograms).doubleValue,
            pricePerKilogram: line.pricePerKilogramTextSnapshot.flatMap(Double.init),
            nutrients: nutrients
        )
    }

    private static func legacyComposition(
        feed: FeedRecord,
        lines: [FeedAnalysisLineSnapshot]
    ) -> [FeedTroughCompositionComponent] {
        let decoded = FeedTroughCompositionCodec.decode(feed.remainingCompositionJSON)
        if !decoded.isEmpty { return decoded }
        guard let json = feed.remainingCompositionJSON,
              let data = json.data(using: .utf8),
              let percentages = try? JSONDecoder().decode([String: Double].self, from: data),
              !percentages.isEmpty,
              let remainingText = feed.remainingKilogramsText,
              let remaining = Double(remainingText),
              remaining > 0 else { return [] }
        let totalPercent = percentages.values.filter { $0 > 0 }.reduce(0, +)
        guard totalPercent > 0 else { return [] }
        return percentages.compactMap { name, percent in
            guard percent > 0 else { return nil }
            let line = lines.first {
                $0.ingredientName.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current) ==
                    name.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
            }
            return FeedTroughCompositionComponent(
                ingredientID: line?.ingredientID,
                ingredientBatchID: line?.ingredientBatchID,
                ingredientNameSnapshot: name,
                kilogramsText: String(remaining * percent / totalPercent),
                nutrientSnapshotJSON: line.map { FeedNutritionCodec.encode($0.nutrients) } ?? "{}",
                dryMatterTextSnapshot: line?.nutrients.dryMatter.map { String($0) }
            )
        }
    }
}
