import Foundation
import Observation
import SwiftData

struct FarmAnalyticsSnapshot: Sendable {
    struct Sheep: Sendable, Hashable {
        let id: UUID
        let earTag: String
        let breed: String
        let purpose: String
        let sex: SheepSex
        let status: SheepStatus
        let initialPenID: UUID?
        let currentPenID: UUID?
        let birthAt: Date?
        let enteredAt: Date
        let removedAt: Date?
        var isHistoricalArchive: Bool = false

        var isCurrentlyPresent: Bool { status == .active && !isHistoricalArchive }
    }

    struct Pen: Sendable, Hashable {
        let id: UUID
        let name: String
        var isActive: Bool = true
    }
    struct Weight: Sendable, Hashable {
        let id: UUID
        let sheepID: UUID
        let kilograms: Double
        let occurredAt: Date
        let recordedAt: Date

        init(id: UUID, sheepID: UUID, kilograms: Double, occurredAt: Date, recordedAt: Date = .distantPast) {
            self.id = id
            self.sheepID = sheepID
            self.kilograms = kilograms
            self.occurredAt = occurredAt
            self.recordedAt = recordedAt
        }
    }
    struct Weaning: Sendable, Hashable { let id: UUID; let sheepID: UUID; let occurredAt: Date; let weanWeight: Double; let birthAt: Date?; let birthWeight: Double?; let damID: UUID?; let litterSize: Int? }
    struct Lambing: Sendable, Hashable {
        let id: UUID
        let eweID: UUID
        let occurredAt: Date
        let total: Int
        let parity: Int?
        let birthDeadCount: Int?
        let offspring: [Offspring]

        var hasCompleteAnalyticsData: Bool {
            parity != nil && birthDeadCount != nil && offspring.count == total
        }
    }
    struct ParityEvidence: Sendable, Hashable {
        let id: UUID
        let eweID: UUID
        let occurredAt: Date
        let parity: Int
        let updatedAt: Date
        let createdAt: Date
    }
    struct Offspring: Sendable, Hashable { let id: UUID; let sheepID: UUID?; let earTag: String; let sex: LambSex?; let birthWeight: Double? }
    struct Removal: Sendable, Hashable { let sheepID: UUID; let kind: RemovalKind; let occurredAt: Date }
    struct Transfer: Sendable, Hashable {
        let id: UUID
        let sheepID: UUID
        let fromPenID: UUID?
        let toPenID: UUID?
        let occurredAt: Date
        let recordedAt: Date
        var note: String = ""

        init(
            id: UUID,
            sheepID: UUID,
            toPenID: UUID?,
            occurredAt: Date,
            recordedAt: Date,
            note: String = "",
            fromPenID: UUID? = nil
        ) {
            self.id = id
            self.sheepID = sheepID
            self.fromPenID = fromPenID
            self.toPenID = toPenID
            self.occurredAt = occurredAt
            self.recordedAt = recordedAt
            self.note = note
        }

        init(
            id: UUID,
            sheepID: UUID,
            fromPenID: UUID?,
            toPenID: UUID?,
            occurredAt: Date,
            recordedAt: Date,
            note: String = ""
        ) {
            self.init(id: id, sheepID: sheepID, toPenID: toPenID, occurredAt: occurredAt, recordedAt: recordedAt, note: note, fromPenID: fromPenID)
        }
    }
    struct BatchMembership: Sendable, Hashable {
        let id: UUID
        let batchID: UUID
        let sheepID: UUID
        let joinedAt: Date
        let leftAt: Date?

        init(id: UUID = UUID(), batchID: UUID, sheepID: UUID, joinedAt: Date, leftAt: Date?) {
            self.id = id
            self.batchID = batchID
            self.sheepID = sheepID
            self.joinedAt = joinedAt
            self.leftAt = leftAt
        }

        /// 批次归属按事实发生时间判断。脱离批次只影响其后的事实，
        /// 不会从批次分析中抹掉加入后、脱离前已经发生的数据。
        func contains(eventAt date: Date) -> Bool {
            joinedAt <= date && (leftAt.map { date <= $0 } ?? true)
        }
    }
    struct Feed: Sendable, Hashable { let penID: UUID; let ingredientName: String; let kilograms: Double; let mode: FeedMode; let occurredAt: Date }

    let farmID: UUID
    let sheep: [Sheep]
    let pens: [Pen]
    let weights: [Weight]
    let weanings: [Weaning]
    let lambings: [Lambing]
    let removals: [Removal]
    let transfers: [Transfer]
    let batchMemberships: [BatchMembership]
    let feeds: [Feed]
    var timeZoneIdentifier: String = "Asia/Shanghai"
    var factsReadAt: Date = .now
    var parityEvidence: [ParityEvidence] = []
    var purposeFacts: [SheepPurposeTimelineFact] = []

    static func make(
        farmID: UUID,
        sheep: [SheepRecord],
        pens: [PenRecord],
        weights: [WeightRecord],
        weanings: [WeaningRecord],
        reproduction: [ReproductionRecord],
        offspring: [LambingOffspringRecord],
        removals: [RemovalRecord],
        transfers: [TransferRecord],
        memberships: [BatchMembershipRecord],
        feeds: [FeedRecord],
        feedLines: [FeedRecordLine],
        timeZoneIdentifier: String = "Asia/Shanghai",
        factsReadAt: Date = .now
    ) -> Self {
        let farmSheep = sheep.filter { $0.farmID == farmID && $0.deletedAt == nil }.map {
            Sheep(id: $0.id, earTag: $0.earTag, breed: $0.breed, purpose: $0.purpose, sex: $0.sex, status: $0.status, initialPenID: $0.initialPenID, currentPenID: $0.currentPenID, birthAt: $0.birthAt, enteredAt: $0.enteredAt, removedAt: $0.removedAt, isHistoricalArchive: $0.isHistoricalArchive)
        }
        let offspringByLambing = Dictionary(grouping: offspring.filter {
            $0.farmID == farmID && $0.deletedAt == nil && !$0.deletedByLambingRevocation
        }, by: \.lambingRecordID)
        let lambings = reproduction.filter { $0.farmID == farmID && $0.deletedAt == nil && $0.kind == .lambing }.map { record in
            Lambing(
                id: record.id,
                eweID: record.eweID,
                occurredAt: record.occurredAt,
                total: record.lambCount,
                parity: record.parity,
                birthDeadCount: record.birthDeadCount,
                offspring: (offspringByLambing[record.id] ?? []).map {
                    Offspring(id: $0.id, sheepID: $0.sheepID, earTag: $0.legacyEarTag, sex: LambSex(rawValue: $0.sexRawValue), birthWeight: Decimal.stable($0.birthWeightText).map { NSDecimalNumber(decimal: $0).doubleValue })
                }
            )
        }
        let feedByID = Dictionary(uniqueKeysWithValues: feeds.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { ($0.id, $0) })
        return Self(
            farmID: farmID,
            sheep: farmSheep,
            pens: pens.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Pen(id: $0.id, name: $0.name, isActive: $0.isActive) },
            weights: weights.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Weight(id: $0.id, sheepID: $0.sheepID, kilograms: NSDecimalNumber(decimal: $0.kilograms).doubleValue, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt) },
            weanings: weanings.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Weaning(id: $0.id, sheepID: $0.sheepID, occurredAt: $0.occurredAt, weanWeight: NSDecimalNumber(decimal: $0.weanWeight).doubleValue, birthAt: $0.birthAt, birthWeight: $0.birthWeightText.flatMap(Decimal.stable).map { NSDecimalNumber(decimal: $0).doubleValue }, damID: $0.damID, litterSize: $0.litterSize) },
            lambings: lambings,
            removals: removals.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Removal(sheepID: $0.sheepID, kind: $0.kind, occurredAt: $0.occurredAt) },
            transfers: transfers.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Transfer(id: $0.id, sheepID: $0.sheepID, toPenID: $0.toPenID, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt, note: $0.note, fromPenID: $0.fromPenID) },
            batchMemberships: memberships.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { BatchMembership(id: $0.id, batchID: $0.batchID, sheepID: $0.sheepID, joinedAt: $0.joinedAt, leftAt: $0.leftAt) },
            feeds: feedLines.filter { $0.farmID == farmID }.compactMap { line in
                guard let feed = feedByID[line.feedRecordID] else { return nil }
                return Feed(penID: feed.penID, ingredientName: line.ingredientNameSnapshot, kilograms: NSDecimalNumber(decimal: line.kilograms).doubleValue, mode: feed.mode, occurredAt: feed.occurredAt)
            },
            timeZoneIdentifier: timeZoneIdentifier,
            factsReadAt: factsReadAt,
            parityEvidence: reproduction.filter {
                $0.farmID == farmID && $0.deletedAt == nil &&
                ($0.kind == .parityBaseline || $0.kind == .lambing) && ($0.parity ?? -1) >= 0
            }.map {
                ParityEvidence(id: $0.id, eweID: $0.eweID, occurredAt: $0.occurredAt,
                               parity: $0.parity!, updatedAt: $0.updatedAt, createdAt: $0.createdAt)
            }
        )
    }
}

struct FarmAnalyticsBatchSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
}

struct FarmDeepAnalyticsPayload: Sendable {
    let snapshot: FarmAnalyticsSnapshot
    let batches: [FarmAnalyticsBatchSnapshot]
    let eligibleWeightPenIDs: Set<UUID>
    let weightCutoff: Date
    let activeSheepCount: Int
    let activePenCount: Int
    let currentMonthFeedCount: Int
    let latestActivityDate: Date?
}

/// Reads every table used by the deep-analysis cards on a private actor and
/// returns one immutable value snapshot. SwiftUI never observes or scans the
/// large SwiftData collections while a navigation transition is being built.
actor FarmDeepAnalyticsSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(farmID: UUID, now: Date = .now) throws -> FarmDeepAnalyticsPayload {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let farmTimeZoneIdentifier = (try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == farmID && $0.deletedAt == nil })?.timeZoneIdentifier)
            ?? "Asia/Shanghai"

        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let weights = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let weanings = try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let offspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let feeds = try context.fetch(FetchDescriptor<FeedRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        let feedLines = try context.fetch(FetchDescriptor<FeedRecordLine>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let batchRecords = try context.fetch(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()

        var snapshot = FarmAnalyticsSnapshot.make(
            farmID: farmID,
            sheep: sheep,
            pens: pens,
            weights: weights,
            weanings: weanings,
            reproduction: reproduction,
            offspring: offspring,
            removals: removals,
            transfers: transfers,
            memberships: memberships,
            feeds: feeds,
            feedLines: feedLines,
            timeZoneIdentifier: farmTimeZoneIdentifier,
            factsReadAt: now
        )
        snapshot.purposeFacts = SheepPurposeTimeline.facts(from: try context.fetch(
            FetchDescriptor<DomainOperation>(predicate: #Predicate {
                $0.farmID == farmID && $0.kindRawValue == "care"
            })
        ))
        // 增重分析使用统一体重事实：断奶重和有日期的初生重也属于可追溯称重点。
        // 只看 WeightRecord 会让页面截止日期早于实际可用的分析数据。
        let weightCutoff = snapshot.weightSamples.map(\.occurredAt).max() ?? now
        let occupancy = FarmPenOccupancyIndex.make(
            farmID: farmID,
            sheep: sheep,
            transfers: transfers,
            removals: removals
        )
        let eligibleWeightPenIDs = occupancy.occupiedPenIDs(at: weightCutoff)
        let activeSheep = sheep.filter(\.isCurrentlyPresent)
        let activePenIDs = Set(activeSheep.compactMap(\.currentPenID))
        let currentMonth = Calendar.current.dateInterval(of: .month, for: now)
        let latestActivityDate = [
            weights.map(\.occurredAt).max(),
            reproduction.map(\.occurredAt).max(),
            feeds.map(\.occurredAt).max(),
        ].compactMap { $0 }.max()
        let batches = batchRecords
            .filter { $0.sourceRawValue == ProductionBatchSource.manual.rawValue }
            .map { FarmAnalyticsBatchSnapshot(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        try Task.checkCancellation()
        return FarmDeepAnalyticsPayload(
            snapshot: snapshot,
            batches: batches,
            eligibleWeightPenIDs: eligibleWeightPenIDs,
            weightCutoff: weightCutoff,
            activeSheepCount: activeSheep.count,
            activePenCount: pens.count { activePenIDs.contains($0.id) },
            currentMonthFeedCount: feeds.count { currentMonth?.contains($0.occurredAt) == true },
            latestActivityDate: latestActivityDate
        )
    }
}

@MainActor
@Observable
final class FarmDeepAnalyticsStore {
    private(set) var payload: FarmDeepAnalyticsPayload?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var revision = UUID()

    private var loadedFarmID: UUID?
    private var loadRevision = UUID()

    func load(container: ModelContainer, farmID: UUID, force: Bool = false) async {
        if !force, loadedFarmID == farmID, payload != nil { return }
        let requestRevision = UUID()
        loadRevision = requestRevision
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await FarmDeepAnalyticsSnapshotActor(container: container).load(farmID: farmID)
            try Task.checkCancellation()
            guard loadRevision == requestRevision else { return }
            payload = loaded
            loadedFarmID = farmID
            revision = UUID()
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard loadRevision == requestRevision else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

enum FarmAnalyticsDate {
    static let calendar = Calendar.current

    static func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    static func month(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
    static func year(_ date: Date) -> String { String(calendar.component(.year, from: date)) }
    static func monthNumber(_ date: Date) -> String { String(format: "%02d", calendar.component(.month, from: date)) }
    static func days(from start: Date, to end: Date) -> Int { calendar.dateComponents([.day], from: day(start), to: day(end)).day ?? 0 }
}

enum SheepWeightSource: Int, Sendable, Hashable {
    case weighing = 0
    case weaning = 1
    case lambingBirth = 2
    case weaningBirth = 3

    var displayName: String {
        switch self {
        case .weighing: "称重"
        case .weaning: "断奶重"
        case .lambingBirth, .weaningBirth: "初生重"
        }
    }
}

struct SheepWeightSample: Identifiable, Sendable, Hashable {
    let id: UUID
    let sheepID: UUID
    let kilogramsText: String
    let kilograms: Double
    let occurredAt: Date
    let recordedAt: Date
    let source: SheepWeightSource

    init(
        id: UUID,
        sheepID: UUID,
        kilogramsText: String,
        kilograms: Double,
        occurredAt: Date,
        source: SheepWeightSource,
        recordedAt: Date = .distantPast
    ) {
        self.id = id
        self.sheepID = sheepID
        self.kilogramsText = kilogramsText
        self.kilograms = kilograms
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.source = source
    }

    init(id: UUID, sheepID: UUID, kilograms: Double, occurredAt: Date, source: SheepWeightSource, recordedAt: Date = .distantPast) {
        self.init(
            id: id,
            sheepID: sheepID,
            kilogramsText: Decimal(kilograms).stableText,
            kilograms: kilograms,
            occurredAt: occurredAt,
            source: source,
            recordedAt: recordedAt
        )
    }
}

enum SheepWeightSampleBuilder {
    private struct DayKey: Hashable {
        let sheepID: UUID
        let day: Date
    }

    /// 同一只羊同一天只保留一个统计点：常规称重优先，其次是断奶重、产羔初生重、断奶补录初生重。
    /// 同来源一天多次记录时采用当天最后一次，保证图表、最近体重和 ADG 使用同一口径。
    static func dailyCanonical(
        _ samples: [SheepWeightSample],
        calendar: Calendar = FarmAnalyticsDate.calendar
    ) -> [SheepWeightSample] {
        let valid = samples.filter { $0.kilograms > 0 && $0.kilograms.isFinite }
        let grouped = Dictionary(grouping: valid) {
            DayKey(sheepID: $0.sheepID, day: calendar.startOfDay(for: $0.occurredAt))
        }
        return grouped.values.compactMap { sameDay in
            sameDay.sorted(by: isPreferred).first
        }.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.sheepID != $1.sheepID { return $0.sheepID.uuidString < $1.sheepID.uuidString }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// 单羊档案保留同一天的多次真实称重，只合并同羊、同日、同体重的跨来源重复事实。
    /// 例如产羔自动生成的初生重与产羔明细是同一个事实，不应在曲线上出现两次。
    static func deduplicatingEquivalentFacts(_ samples: [SheepWeightSample]) -> [SheepWeightSample] {
        let valid = samples.filter { $0.kilograms > 0 && $0.kilograms.isFinite }
        var result: [SheepWeightSample] = []
        for sample in valid.sorted(by: isPreferred) {
            if sample.source != .weighing,
               result.contains(where: { existing in
                   existing.sheepID == sample.sheepID
                       && FarmAnalyticsDate.day(existing.occurredAt) == FarmAnalyticsDate.day(sample.occurredAt)
                       && abs(existing.kilograms - sample.kilograms) < 0.000_001
                       && existing.source.rawValue <= sample.source.rawValue
               }) {
                continue
            }
            result.append(sample)
        }
        return result.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.source.rawValue != $1.source.rawValue { return $0.source.rawValue < $1.source.rawValue }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func isPreferred(_ lhs: SheepWeightSample, _ rhs: SheepWeightSample) -> Bool {
        if lhs.source.rawValue != rhs.source.rawValue { return lhs.source.rawValue < rhs.source.rawValue }
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

extension FarmAnalyticsSnapshot {
    /// 统一体重事实读取层。底层事件仍保持各自模型，统计时将常规称重、断奶重和初生重视为同一只羊的体重样本。
    var weightSamples: [SheepWeightSample] {
        var samples = weights.map {
            SheepWeightSample(
                id: $0.id,
                sheepID: $0.sheepID,
                kilograms: $0.kilograms,
                occurredAt: $0.occurredAt,
                source: .weighing,
                recordedAt: $0.recordedAt
            )
        }
        for weaning in weanings {
            samples.append(SheepWeightSample(
                id: StableCloudUUID.derived(namespace: weaning.id, name: "weight-sample-weaning"),
                sheepID: weaning.sheepID,
                kilograms: weaning.weanWeight,
                occurredAt: weaning.occurredAt,
                source: .weaning
            ))
            if let birthAt = weaning.birthAt, let birthWeight = weaning.birthWeight {
                samples.append(SheepWeightSample(
                    id: StableCloudUUID.derived(namespace: weaning.id, name: "weight-sample-weaning-birth"),
                    sheepID: weaning.sheepID,
                    kilograms: birthWeight,
                    occurredAt: birthAt,
                    source: .weaningBirth
                ))
            }
        }
        for lambing in lambings {
            for offspring in lambing.offspring {
                guard let sheepID = offspring.sheepID, let birthWeight = offspring.birthWeight else { continue }
                samples.append(SheepWeightSample(
                    id: StableCloudUUID.derived(namespace: offspring.id, name: "weight-sample-lambing-birth"),
                    sheepID: sheepID,
                    kilograms: birthWeight,
                    occurredAt: lambing.occurredAt,
                    source: .lambingBirth
                ))
            }
        }
        return samples
    }
}

struct FarmLambAnalyticsResult: Sendable {
    let lambStats: LambStats
    let weaning: LambWeaningAnalysis
    let incompleteLambingCount: Int
}

struct LambMonthStats: Identifiable, Sendable {
    let month: String
    var firstParity = 0; var multiParity = 0; var totalDams = 0; var maleLambs = 0; var femaleLambs = 0; var totalLambs = 0; var birthDead = 0
    var avgPerLamb = 0.0; var deathRate = 0.0; var multiPct = 0.0; var disappeared = 0; var culled = 0; var sold = 0; var inHerd = 0
    var maleWeightAverage = 0.0; var maleWeightCount = 0; var femaleWeightAverage = 0.0; var femaleWeightCount = 0
    var maleADGAverage = 0.0; var maleADGCount = 0; var femaleADGAverage = 0.0; var femaleADGCount = 0
    var id: String { month }
}

struct LambStats: Sendable {
    var months: [LambMonthStats] = []
    var totalLambs = 0
    var mortalityRate = 0.0
    var deathCullRate = 0.0
}

struct WeanMonthStats: Identifiable, Sendable {
    let month: String
    var totalCount = 0; var abnormalCount = 0; var otherSexCount = 0; var ageCount = 0; var ageDays = 0; var weightCount = 0; var weightSum = 0.0; var adgCount = 0; var adgSum = 0.0
    var maleCount = 0; var maleAgeCount = 0; var maleAgeDays = 0; var maleWeightCount = 0; var maleWeightSum = 0.0; var maleADGCount = 0; var maleADGSum = 0.0
    var femaleCount = 0; var femaleAgeCount = 0; var femaleAgeDays = 0; var femaleWeightCount = 0; var femaleWeightSum = 0.0; var femaleADGCount = 0; var femaleADGSum = 0.0
    var id: String { month }
    var averageAge: Double { ageCount > 0 ? Double(ageDays) / Double(ageCount) : 0 }
    var averageWeight: Double { weightCount > 0 ? weightSum / Double(weightCount) : 0 }
    var averageADG: Double { adgCount > 0 ? adgSum / Double(adgCount) : 0 }
    var maleAverageWeight: Double { maleWeightCount > 0 ? maleWeightSum / Double(maleWeightCount) : 0 }
    var femaleAverageWeight: Double { femaleWeightCount > 0 ? femaleWeightSum / Double(femaleWeightCount) : 0 }
    var maleAverageADG: Double { maleADGCount > 0 ? maleADGSum / Double(maleADGCount) : 0 }
    var femaleAverageADG: Double { femaleADGCount > 0 ? femaleADGSum / Double(femaleADGCount) : 0 }
}

struct LambWeaningAnalysis: Sendable {
    let months: [WeanMonthStats]
    var total: Int { months.reduce(0) { $0 + $1.totalCount } }
    var abnormalCount: Int { months.reduce(0) { $0 + $1.abnormalCount } }
    var averageADG: Double {
        let count = months.reduce(0) { $0 + $1.adgCount }
        return count > 0 ? months.reduce(0) { $0 + $1.adgSum } / Double(count) : 0
    }
}

enum LambAnalyticsEngine {
    static func calculate(snapshot: FarmAnalyticsSnapshot, selectedYear: String?, selectedWeaningMonth: String = "全部") -> FarmLambAnalyticsResult {
        let sheepByID = Dictionary(uniqueKeysWithValues: snapshot.sheep.map { ($0.id, $0) })
        let gainSamplesBySheepID = Dictionary(grouping: snapshot.weights.map {
            WeaningGainSample(id: $0.id, sheepID: $0.sheepID, kilograms: $0.kilograms, occurredAt: $0.occurredAt)
        }, by: \.sheepID)
        let yearLambings = snapshot.lambings.filter { selectedYear == nil || FarmAnalyticsDate.year($0.occurredAt) == selectedYear }
        let completeLambings = yearLambings.filter(\.hasCompleteAnalyticsData)
        let weaningBySheepID = Dictionary(grouping: snapshot.weanings, by: \.sheepID).compactMapValues { records in
            records.max { $0.occurredAt < $1.occurredAt }
        }
        var months: [String: LambMonthStats] = [:]
        var tagsByMonth: [String: Set<String>] = [:]
        for lambing in completeLambings {
            let month = FarmAnalyticsDate.month(lambing.occurredAt)
            var stats = months[month] ?? LambMonthStats(month: month)
            if lambing.parity == 1 { stats.firstParity += 1 } else { stats.multiParity += 1 }
            stats.totalDams += 1; stats.totalLambs += lambing.total; stats.birthDead += lambing.birthDeadCount ?? 0
            if lambing.total >= 2 { stats.multiPct += Double(lambing.total) }
            for child in lambing.offspring {
                tagsByMonth[month, default: []].insert(EarTag.normalized(child.earTag))
                if child.sex == .male { stats.maleLambs += 1 }
                else if child.sex == .female { stats.femaleLambs += 1 }
                if let weight = child.birthWeight, weight > 0 {
                    if child.sex == .male { stats.maleWeightCount += 1; stats.maleWeightAverage += weight }
                    else if child.sex == .female { stats.femaleWeightCount += 1; stats.femaleWeightAverage += weight }
                }
                guard let sheepID = child.sheepID,
                      let weaning = weaningBySheepID[sheepID] else { continue }
                let birthAt = weaning.birthAt ?? sheepByID[sheepID]?.birthAt ?? lambing.occurredAt
                guard let gain = WeaningGainSemantics.calculate(
                    sheepID: sheepID,
                    birthAt: birthAt,
                    weaningAt: weaning.occurredAt,
                    weaningWeight: weaning.weanWeight,
                    samples: gainSamplesBySheepID[sheepID] ?? []
                ) else { continue }
                let adg = gain.gramsPerDay
                if child.sex == .male { stats.maleADGCount += 1; stats.maleADGAverage += adg }
                else if child.sex == .female { stats.femaleADGCount += 1; stats.femaleADGAverage += adg }
            }
            months[month] = stats
        }
        let activeTags = Set(snapshot.sheep.filter { $0.status == .active }.map { EarTag.normalized($0.earTag) })
        let tagBySheepID = Dictionary(uniqueKeysWithValues: snapshot.sheep.map { ($0.id, EarTag.normalized($0.earTag)) })
        var removalsByTag: [String: (disappeared: Int, culled: Int, sold: Int)] = [:]
        for removal in snapshot.removals {
            guard let tag = tagBySheepID[removal.sheepID] else { continue }
            var counts = removalsByTag[tag] ?? (0, 0, 0)
            switch removal.kind { case .sold: counts.sold += 1; case .culled, .deceased: counts.culled += 1; case .transferredOut: counts.disappeared += 1 }
            removalsByTag[tag] = counts
        }
        for month in months.keys {
            guard var stats = months[month] else { continue }
            stats.multiPct = stats.totalLambs > 0 ? stats.multiPct / Double(stats.totalLambs) * 100 : 0
            stats.avgPerLamb = stats.totalDams > 0 ? Double(stats.totalLambs) / Double(stats.totalDams) : 0
            stats.deathRate = stats.totalLambs > 0 ? Double(stats.birthDead) / Double(stats.totalLambs) : 0
            if stats.maleWeightCount > 0 { stats.maleWeightAverage /= Double(stats.maleWeightCount) }
            if stats.femaleWeightCount > 0 { stats.femaleWeightAverage /= Double(stats.femaleWeightCount) }
            if stats.maleADGCount > 0 { stats.maleADGAverage /= Double(stats.maleADGCount) }
            if stats.femaleADGCount > 0 { stats.femaleADGAverage /= Double(stats.femaleADGCount) }
            for tag in tagsByMonth[month] ?? [] { if let counts = removalsByTag[tag] { stats.disappeared += counts.disappeared; stats.culled += counts.culled; stats.sold += counts.sold } }
            stats.inHerd = (tagsByMonth[month] ?? []).intersection(activeTags).count
            months[month] = stats
        }
        let sortedMonths = months.values.sorted { $0.month > $1.month }
        let totalLambs = sortedMonths.reduce(0) { $0 + $1.totalLambs }
        let totalDead = sortedMonths.reduce(0) { $0 + $1.birthDead }
        let totalCull = sortedMonths.reduce(0) { $0 + $1.culled + $1.disappeared }
        let weaning = calculateWeaning(
            snapshot: snapshot,
            sheepByID: sheepByID,
            gainSamplesBySheepID: gainSamplesBySheepID,
            selectedYear: selectedYear,
            selectedMonth: selectedWeaningMonth
        )
        return FarmLambAnalyticsResult(lambStats: LambStats(months: sortedMonths, totalLambs: totalLambs, mortalityRate: totalLambs > 0 ? Double(totalDead) / Double(totalLambs) : 0, deathCullRate: totalLambs > totalDead ? Double(totalCull) / Double(totalLambs - totalDead) : 0), weaning: weaning, incompleteLambingCount: yearLambings.count - completeLambings.count)
    }

    private static func calculateWeaning(
        snapshot: FarmAnalyticsSnapshot,
        sheepByID: [UUID: FarmAnalyticsSnapshot.Sheep],
        gainSamplesBySheepID: [UUID: [WeaningGainSample]],
        selectedYear: String?,
        selectedMonth: String
    ) -> LambWeaningAnalysis {
        var rows: [String: WeanMonthStats] = [:]
        for record in snapshot.weanings where selectedYear == nil || FarmAnalyticsDate.year(record.occurredAt) == selectedYear {
            guard selectedMonth == "全部" || FarmAnalyticsDate.monthNumber(record.occurredAt) == selectedMonth else { continue }
            let month = FarmAnalyticsDate.month(record.occurredAt)
            var stats = rows[month] ?? WeanMonthStats(month: month)
            stats.totalCount += 1
            let sex: LambSex? = sheepByID[record.sheepID]?.sex == .ram ? .male : sheepByID[record.sheepID]?.sex == .ewe ? .female : nil
            if sex == .male { stats.maleCount += 1 } else if sex == .female { stats.femaleCount += 1 } else { stats.otherSexCount += 1 }
            let validWeight = record.weanWeight > 0
            if validWeight { stats.weightCount += 1; stats.weightSum += record.weanWeight; if sex == .male { stats.maleWeightCount += 1; stats.maleWeightSum += record.weanWeight }; if sex == .female { stats.femaleWeightCount += 1; stats.femaleWeightSum += record.weanWeight } }
            let birthAt = record.birthAt ?? sheepByID[record.sheepID]?.birthAt
            let ageDays = birthAt.map { FarmAnalyticsDate.days(from: $0, to: record.occurredAt) } ?? 0
            let validAge = ageDays > 0
            if validAge { stats.ageCount += 1; stats.ageDays += ageDays; if sex == .male { stats.maleAgeCount += 1; stats.maleAgeDays += ageDays }; if sex == .female { stats.femaleAgeCount += 1; stats.femaleAgeDays += ageDays } }
            let gain = WeaningGainSemantics.calculate(
                sheepID: record.sheepID,
                birthAt: birthAt,
                weaningAt: record.occurredAt,
                weaningWeight: record.weanWeight,
                samples: gainSamplesBySheepID[record.sheepID] ?? []
            )
            if validWeight, let gain {
                let adg = gain.gramsPerDay
                stats.adgCount += 1; stats.adgSum += adg
                if sex == .male { stats.maleADGCount += 1; stats.maleADGSum += adg }
                if sex == .female { stats.femaleADGCount += 1; stats.femaleADGSum += adg }
            }
            if sex == nil || !validWeight || !validAge || gain == nil { stats.abnormalCount += 1 }
            rows[month] = stats
        }
        return LambWeaningAnalysis(months: rows.values.sorted { $0.month < $1.month })
    }
}

struct ReproductionOverview: Sendable { let averageTotal: Double; let averageMale: Double; let averageFemale: Double; let mortalityRate: Double; let averageBirthWeight: Double }
struct ReproductionMonth: Identifiable, Sendable { let month: String; let lambings: Int; let total: Int; let male: Int; let female: Int; var id: String { month } }
struct ReproductionHistoryPoint: Identifiable, Sendable { let date: Date; let average: Double; let count: Int; var id: Date { date } }
struct ReproductionQualifiedRate: Identifiable, Sendable { let month: String; let qualified: Double; let unqualified: Double; var id: String { month } }
struct BreedPerformance: Identifiable, Sendable { let breed: String; let sheepCount: Int; let lambingCount: Int; let averageLambs: Double; var id: String { breed } }

enum ReproductionPenScope: Sendable, Hashable {
    case all
    case pen(UUID)
    case unassigned
}

struct ReproductionAnalyticsFilter: Sendable, Equatable {
    var startDate: Date
    var endDate: Date
    var penScope: ReproductionPenScope
    var breed: String?

    init(startDate: Date, endDate: Date, penScope: ReproductionPenScope = .all, breed: String? = nil) {
        self.startDate = startDate
        self.endDate = endDate
        self.penScope = penScope
        self.breed = breed
    }

    static func recentYear(referenceDate: Date = .now) -> Self {
        let endDate = FarmAnalyticsDate.day(referenceDate)
        let startDate = FarmAnalyticsDate.calendar.date(byAdding: .year, value: -1, to: endDate) ?? endDate
        return Self(startDate: startDate, endDate: endDate)
    }
}

struct ReproductionFilterOptions: Sendable {
    let penIDs: [UUID]
    let includesUnassigned: Bool
    let breeds: [String]
}

struct FarmReproductionAnalyticsResult: Sendable {
    let overview: ReproductionOverview
    let monthly: [ReproductionMonth]
    let maleCount: Int
    let femaleCount: Int
    let intervalPoints: [ReproductionHistoryPoint]
    let postpartumPoints: [ReproductionHistoryPoint]
    let qualifiedRates: [ReproductionQualifiedRate]
    let breedRows: [BreedPerformance]
    let incompleteLambingCount: Int
    let cohortCount: Int
}

enum ReproductionAnalyticsEngine {
    static func calculate(snapshot: FarmAnalyticsSnapshot, selectedYear: String?, referenceDate: Date = .now) -> FarmReproductionAnalyticsResult {
        let calendar = FarmAnalyticsDate.calendar
        let filter: ReproductionAnalyticsFilter
        if let selectedYear, let year = Int(selectedYear),
           let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
           let nextYear = calendar.date(byAdding: .year, value: 1, to: yearStart),
           let yearEnd = calendar.date(byAdding: .day, value: -1, to: nextYear) {
            let endDate = min(FarmAnalyticsDate.day(referenceDate), yearEnd)
            filter = ReproductionAnalyticsFilter(startDate: yearStart, endDate: max(yearStart, endDate))
        } else {
            let startDate = snapshot.lambings.map(\.occurredAt).min().map(FarmAnalyticsDate.day) ?? FarmAnalyticsDate.day(referenceDate)
            filter = ReproductionAnalyticsFilter(startDate: startDate, endDate: FarmAnalyticsDate.day(referenceDate))
        }
        return calculate(snapshot: snapshot, filter: filter)
    }

    static func calculate(snapshot: FarmAnalyticsSnapshot, filter: ReproductionAnalyticsFilter) -> FarmReproductionAnalyticsResult {
        let normalizedFilter = normalized(filter)
        let rangeStart = FarmAnalyticsDate.day(normalizedFilter.startDate)
        let rangeEnd = FarmAnalyticsDate.day(normalizedFilter.endDate)
        let rangeEndExclusive = dayAfter(rangeEnd)
        let cohort = cohortEwes(snapshot: snapshot, filter: normalizedFilter)
        let cohortIDs = Set(cohort.map(\.id))
        let cohortLambings = snapshot.lambings.filter {
            cohortIDs.contains($0.eweID) && $0.occurredAt >= rangeStart && $0.occurredAt < rangeEndExclusive
        }
        let records = cohortLambings.filter(\.hasCompleteAnalyticsData)
        let sheepByID = Dictionary(uniqueKeysWithValues: snapshot.sheep.map { ($0.id, $0) })
        let totalBorn = records.reduce(0) { $0 + $1.total }
        let totalDead = records.reduce(0) { $0 + ($1.birthDeadCount ?? 0) }
        let children = records.flatMap(\.offspring)
        let male = children.filter { $0.sex == .male }.count
        let female = children.filter { $0.sex == .female }.count
        let birthWeights = children.compactMap(\.birthWeight).filter { $0 > 0 }
        let overview = ReproductionOverview(averageTotal: records.isEmpty ? 0 : Double(totalBorn) / Double(records.count), averageMale: records.isEmpty ? 0 : Double(male) / Double(records.count), averageFemale: records.isEmpty ? 0 : Double(female) / Double(records.count), mortalityRate: totalBorn > 0 ? Double(totalDead) / Double(totalBorn) : 0, averageBirthWeight: birthWeights.isEmpty ? 0 : birthWeights.reduce(0, +) / Double(birthWeights.count))
        let monthly = Dictionary(grouping: records, by: { FarmAnalyticsDate.month($0.occurredAt) }).map { month, group in
            let lambs = group.flatMap(\.offspring)
            return ReproductionMonth(month: month, lambings: group.count, total: lambs.count, male: lambs.filter { $0.sex == .male }.count, female: lambs.filter { $0.sex == .female }.count)
        }.sorted { $0.month < $1.month }
        let byDam = Dictionary(grouping: snapshot.lambings.filter { cohortIDs.contains($0.eweID) }, by: \.eweID)
            .mapValues { $0.map(\.occurredAt).sorted() }
        let intervals = byDam.mapValues { dates in zip(dates, dates.dropFirst()).compactMap { first, second in let days = FarmAnalyticsDate.days(from: first, to: second); return days > 0 && days < 1000 ? (second, days) : nil } }
        let historyDates = makeHistoryDates(from: rangeStart, through: rangeEnd)
        let intervalPoints = historyDates.compactMap { date -> ReproductionHistoryPoint? in
            let cutoffExclusive = dayAfter(date)
            let values = cohort.compactMap { ewe -> Int? in
                guard ewe.enteredAt < cutoffExclusive, ewe.birthAt.map({ $0 < cutoffExclusive }) ?? true else { return nil }
                return latestInterval(for: ewe.id, before: cutoffExclusive, intervals: intervals)
            }
            guard !values.isEmpty else { return nil }
            return ReproductionHistoryPoint(date: date, average: Double(values.reduce(0, +)) / Double(values.count), count: values.count)
        }
        let postpartumPoints = historyDates.compactMap { date -> ReproductionHistoryPoint? in
            let cutoffExclusive = dayAfter(date)
            let values = cohort.compactMap { ewe -> Int? in
                guard ewe.enteredAt < cutoffExclusive,
                      ewe.birthAt.map({ $0 < cutoffExclusive }) ?? true,
                      let birth = byDam[ewe.id]?.last(where: { $0 < cutoffExclusive }) else { return nil }
                let days = FarmAnalyticsDate.days(from: birth, to: date)
                return (0..<1000).contains(days) ? days : nil
            }
            guard !values.isEmpty else { return nil }
            return ReproductionHistoryPoint(date: date, average: Double(values.reduce(0, +)) / Double(values.count), count: values.count)
        }
        let qualifiedRates = qualifiedRates(from: intervalPoints, breedingEwes: cohort, intervals: intervals)
        let sheepByBreed = Dictionary(grouping: cohort.filter { isValidBreed($0.breed) }, by: \.breed)
        var breedRows: [BreedPerformance] = []
        for (breed, group) in sheepByBreed {
            var lambingCount = 0
            var lambTotal = 0
            for lambing in records {
                guard sheepByID[lambing.eweID]?.breed == breed else { continue }
                lambingCount += 1
                lambTotal += lambing.offspring.count
            }
            let averageLambs = lambingCount > 0 ? Double(lambTotal) / Double(lambingCount) : 0
            breedRows.append(BreedPerformance(breed: breed, sheepCount: group.count, lambingCount: lambingCount, averageLambs: averageLambs))
        }
        breedRows.sort { $0.lambingCount == $1.lambingCount ? $0.sheepCount > $1.sheepCount : $0.lambingCount > $1.lambingCount }
        return FarmReproductionAnalyticsResult(
            overview: overview,
            monthly: monthly,
            maleCount: male,
            femaleCount: female,
            intervalPoints: intervalPoints,
            postpartumPoints: postpartumPoints,
            qualifiedRates: qualifiedRates,
            breedRows: breedRows,
            incompleteLambingCount: cohortLambings.count - records.count,
            cohortCount: cohort.count
        )
    }

    static func filterOptions(snapshot: FarmAnalyticsSnapshot, asOf endDate: Date) -> ReproductionFilterOptions {
        let cutoffExclusive = dayAfter(endDate)
        let ewes = baseEligibleEwes(snapshot: snapshot, cutoffExclusive: cutoffExclusive)
        let penIndex = HistoricalPenIndex(transfers: snapshot.transfers)
        let penIDs = Set(ewes.compactMap { penIndex.penID(for: $0, before: cutoffExclusive) })
        let includesUnassigned = ewes.contains { penIndex.penID(for: $0, before: cutoffExclusive) == nil }
        let breeds = Set(ewes.map(\.breed).filter(isValidBreed)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return ReproductionFilterOptions(
            penIDs: penIDs.sorted { $0.uuidString < $1.uuidString },
            includesUnassigned: includesUnassigned,
            breeds: breeds
        )
    }

    private static func normalized(_ filter: ReproductionAnalyticsFilter) -> ReproductionAnalyticsFilter {
        let start = FarmAnalyticsDate.day(min(filter.startDate, filter.endDate))
        let end = FarmAnalyticsDate.day(max(filter.startDate, filter.endDate))
        let breed = filter.breed?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReproductionAnalyticsFilter(
            startDate: start,
            endDate: end,
            penScope: filter.penScope,
            breed: breed.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func cohortEwes(snapshot: FarmAnalyticsSnapshot, filter: ReproductionAnalyticsFilter) -> [FarmAnalyticsSnapshot.Sheep] {
        let cutoffExclusive = dayAfter(filter.endDate)
        let penIndex = HistoricalPenIndex(transfers: snapshot.transfers)
        return baseEligibleEwes(snapshot: snapshot, cutoffExclusive: cutoffExclusive).filter { ewe in
            if let breed = filter.breed, ewe.breed != breed { return false }
            switch filter.penScope {
            case .all:
                return true
            case .pen(let penID):
                return penIndex.penID(for: ewe, before: cutoffExclusive) == penID
            case .unassigned:
                return penIndex.penID(for: ewe, before: cutoffExclusive) == nil
            }
        }
    }

    private static func baseEligibleEwes(snapshot: FarmAnalyticsSnapshot, cutoffExclusive: Date) -> [FarmAnalyticsSnapshot.Sheep] {
        let removalByID = Dictionary(grouping: snapshot.removals, by: \.sheepID)
            .compactMapValues { $0.map(\.occurredAt).min() }
        return snapshot.sheep.filter { ewe in
            guard ewe.sex == .ewe,
                  ewe.enteredAt < cutoffExclusive else { return false }
            let removalAt = [ewe.removedAt, removalByID[ewe.id]].compactMap { $0 }.min()
            if let removalAt {
                return removalAt >= cutoffExclusive
            }
            // Some legacy records preserve only the authoritative current status
            // and have no reconstructable removal date. They must not leak into a
            // current/end-date cohort merely because the dated event is missing.
            return ewe.status == .active
        }
    }

    private static func makeHistoryDates(from start: Date, through end: Date) -> [Date] {
        let first = FarmAnalyticsDate.day(start)
        let last = FarmAnalyticsDate.day(end)
        guard first <= last else { return [] }
        let days = max(0, FarmAnalyticsDate.days(from: first, to: last))
        let step = max(1, Int(ceil(Double(max(1, days)) / 299.0)))
        var dates: [Date] = []
        var date = first
        while date <= last {
            dates.append(date)
            guard let next = FarmAnalyticsDate.calendar.date(byAdding: .day, value: step, to: date) else { break }
            date = next
        }
        if dates.last != last { dates.append(last) }
        return dates
    }

    private static func latestInterval(for eweID: UUID, before cutoffExclusive: Date, intervals: [UUID: [(Date, Int)]]) -> Int? {
        intervals[eweID]?.last(where: { $0.0 < cutoffExclusive })?.1
    }

    private static func qualifiedRates(from points: [ReproductionHistoryPoint], breedingEwes: [FarmAnalyticsSnapshot.Sheep], intervals: [UUID: [(Date, Int)]]) -> [ReproductionQualifiedRate] {
        let monthlyPoints = Dictionary(grouping: points, by: { FarmAnalyticsDate.month($0.date) }).compactMapValues { $0.min { abs(FarmAnalyticsDate.calendar.component(.day, from: $0.date) - 15) < abs(FarmAnalyticsDate.calendar.component(.day, from: $1.date) - 15) } }
        return monthlyPoints.keys.sorted().compactMap { month in
            guard let point = monthlyPoints[month] else { return nil }
            var qualified = 0; var unqualified = 0
            let cutoffExclusive = dayAfter(point.date)
            for ewe in breedingEwes where ewe.enteredAt < cutoffExclusive && (ewe.birthAt.map({ $0 < cutoffExclusive }) ?? true) {
                guard let days = latestInterval(for: ewe.id, before: cutoffExclusive, intervals: intervals) else { continue }
                if (150...240).contains(days) { qualified += 1 } else { unqualified += 1 }
            }
            let total = qualified + unqualified
            return total > 0 ? ReproductionQualifiedRate(month: month, qualified: Double(qualified) * 100 / Double(total), unqualified: Double(unqualified) * 100 / Double(total)) : nil
        }
    }

    private static func isValidBreed(_ breed: String) -> Bool {
        let normalized = breed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized.lowercased() != "nan"
    }

    private static func dayAfter(_ date: Date) -> Date {
        FarmAnalyticsDate.calendar.date(byAdding: .day, value: 1, to: FarmAnalyticsDate.day(date)) ?? date
    }

    private struct HistoricalPenIndex {
        private let transfersBySheep: [UUID: [FarmAnalyticsSnapshot.Transfer]]

        init(transfers: [FarmAnalyticsSnapshot.Transfer]) {
            transfersBySheep = Dictionary(grouping: transfers, by: \.sheepID).mapValues { values in
                values.sorted {
                    if $0.occurredAt == $1.occurredAt {
                        if $0.recordedAt == $1.recordedAt { return $0.id.uuidString < $1.id.uuidString }
                        return $0.recordedAt < $1.recordedAt
                    }
                    return $0.occurredAt < $1.occurredAt
                }
            }
        }

        func penID(for ewe: FarmAnalyticsSnapshot.Sheep, before cutoffExclusive: Date) -> UUID? {
            guard let transfers = transfersBySheep[ewe.id], !transfers.isEmpty else { return ewe.initialPenID }
            var lower = 0
            var upper = transfers.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if transfers[middle].occurredAt < cutoffExclusive {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower > 0 ? transfers[lower - 1].toPenID : ewe.initialPenID
        }
    }
}

enum WeightSampleScope: String, CaseIterable, Sendable, Hashable { case all; case inHerdOnly; case removedOnly }
struct WeightTrendPoint: Identifiable, Sendable { let date: Date; let value: Double; var id: Date { date } }
struct WeightScatterPoint: Identifiable, Sendable { let sheepID: UUID; let date: Date; let baselineWeight: Double; let adg: Double; var id: String { "\(sheepID.uuidString)-\(date.timeIntervalSince1970)" } }
enum WeightRegressionKind: String, CaseIterable, Identifiable, Sendable {
    case none, linear, logarithmic, exponential, quadratic, cubic, quartic, quintic, sextic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "无"
        case .linear: "线性"
        case .logarithmic: "对数"
        case .exponential: "指数"
        case .quadratic: "二次"
        case .cubic: "三次"
        case .quartic: "四次"
        case .quintic: "五次"
        case .sextic: "六次"
        }
    }
    var minimumPointCount: Int {
        switch self {
        case .none: .max
        case .linear, .logarithmic, .exponential: 2
        case .quadratic: 3
        case .cubic: 4
        case .quartic: 5
        case .quintic: 6
        case .sextic: 7
        }
    }
    var polynomialDegree: Int {
        switch self {
        case .quadratic: 2
        case .cubic: 3
        case .quartic: 4
        case .quintic: 5
        case .sextic: 6
        case .none, .linear, .logarithmic, .exponential: 0
        }
    }
}
struct WeightRegressionPoint: Identifiable, Sendable { let x: Double; let y: Double; var id: String { "\(x)-\(y)" } }
struct WeightCohort: Sendable { let sheepIDs: [UUID]; let latestAverageWeight: Double?; let latestAverageADG: Double?; let weightTrend: [WeightTrendPoint]; let adgTrend: [WeightTrendPoint]; let scatter: [WeightScatterPoint] }

/// 增重分析只允许在明确的对象范围内计算。批次和圈舍可以组合成显式的
/// 期末名单交集；不选择圈舍时，批次分析覆盖该批次的期间称重。
enum WeightGainAnalysisScope: Hashable, Sendable {
    case farm
    case batch(UUID)
    case batchAndPen(batchID: UUID, penID: UUID)
    case batchAndPens(batchID: UUID, penIDs: Set<UUID>)
    case pen(UUID)
    case pens(Set<UUID>)
    case unassigned
}

enum WeightGainAnalysisPopulation: String, CaseIterable, Sendable, Hashable {
    case wholeObject = "整批期间表现"
    case trackedCohort = "跟踪这群羊"
    case inPen = "在舍期间表现"
}

enum WeightGainCohortAnchor: String, CaseIterable, Sendable, Hashable {
    case analysisEnd = "分析结束时"
    case analysisStart = "分析开始时"
    case custom = "自定义历史时点"
}

enum WeightGainAnalysisMode: String, CaseIterable, Sendable, Hashable {
    case period
    case paired

    var title: String {
        switch self {
        case .period: "期间表现"
        case .paired: "两次称重对比"
        }
    }
}

struct WeightGainAnalysisFilter: Sendable, Hashable {
    var scope: WeightGainAnalysisScope
    var mode: WeightGainAnalysisMode
    var startDate: Date
    var endDate: Date
    var sampleScope: WeightSampleScope
    var population: WeightGainAnalysisPopulation
    var cohortAnchor: WeightGainCohortAnchor
    var cohortDate: Date?

    init(
        scope: WeightGainAnalysisScope = .farm,
        mode: WeightGainAnalysisMode = .period,
        startDate: Date,
        endDate: Date,
        sampleScope: WeightSampleScope = .all,
        population: WeightGainAnalysisPopulation = .wholeObject,
        cohortAnchor: WeightGainCohortAnchor = .analysisEnd,
        cohortDate: Date? = nil
    ) {
        self.scope = scope
        self.mode = mode
        self.startDate = startDate
        self.endDate = endDate
        self.sampleScope = sampleScope
        self.population = population
        self.cohortAnchor = cohortAnchor
        self.cohortDate = cohortDate
    }

    var normalized: Self {
        let start = FarmAnalyticsDate.day(min(startDate, endDate))
        let end = FarmAnalyticsDate.day(max(startDate, endDate))
        let boundedCustomDate = cohortDate.map { min(max($0, start), end) }
        return Self(
            scope: scope,
            mode: mode,
            startDate: start,
            endDate: end,
            sampleScope: sampleScope,
            population: population,
            cohortAnchor: cohortAnchor,
            cohortDate: boundedCustomDate
        )
    }
}

enum WeightGainExclusionReason: String, Sendable, Hashable {
    case noSample = "期间没有有效称重点"
    case missingPair = "缺少第二次称重"
    case missingStart = "缺少起始称重"
    case missingEnd = "缺少结束称重"
    case outOfScope = "称重区间不连续属于所选对象"
    case conflictingEventTime = "称重时刻与调群事件冲突，无法确定圈舍归属"

    var title: String { rawValue }
}

struct WeightGainExclusion: Identifiable, Sendable, Hashable {
    let sheepID: UUID
    let earTag: String
    let reason: WeightGainExclusionReason

    var id: String { "\(sheepID.uuidString)-\(reason.rawValue)" }
}

struct WeightGainAnalysisRow: Identifiable, Sendable, Hashable {
    let sheepID: UUID
    let earTag: String
    let sex: SheepSex
    let purpose: String
    let status: SheepStatus
    let analysisEndDate: Date
    let analysisEndPenID: UUID?
    let analysisEndPenName: String?
    let penHistoryStartDate: Date
    let penHistoryStartPenName: String?
    let penHistory: [WeightGainTransferEvidence]
    let startDate: Date
    let endDate: Date
    let startWeight: Double
    let endWeight: Double
    let intervalDays: Int
    let intervalCount: Int
    let gramsPerDay: Double
    let totalGainKilograms: Double

    var id: UUID { sheepID }
    var isDown: Bool { gramsPerDay < 0 }
    var isCurrentlyPresent: Bool { status == .active }
}

struct WeightGainCohortMember: Identifiable, Sendable, Hashable {
    let sheepID: UUID
    let earTag: String
    let anchorDate: Date
    let anchorPenID: UUID?
    let anchorPenName: String?
    let batchID: UUID?
    let batchMembershipID: UUID?
    let anchorTransferID: UUID?

    var id: UUID { sheepID }
}

struct WeightGainTransferEvidence: Identifiable, Sendable, Hashable {
    let id: UUID
    let sheepID: UUID
    let earTag: String
    let occurredAt: Date
    let recordedAt: Date
    let fromPenID: UUID?
    let toPenID: UUID?
    let fromPenName: String?
    let toPenName: String?
    let note: String
}

struct WeightGainAnalysisInterval: Identifiable, Sendable, Hashable {
    let sheepID: UUID
    let startSample: SheepWeightSample
    let endSample: SheepWeightSample
    let startDate: Date
    let endDate: Date
    let startWeight: Double
    let endWeight: Double
    let intervalDays: Int
    let gramsPerDay: Double
    let crossedTransfers: [WeightGainTransferEvidence]
    let startPenID: UUID?
    let endPenID: UUID?
    let isCalculable: Bool
    let canBeAttributedToSinglePen: Bool
    let exclusionReason: WeightGainExclusionReason?

    init(
        sheepID: UUID,
        startSample: SheepWeightSample,
        endSample: SheepWeightSample,
        startDate: Date,
        endDate: Date,
        startWeight: Double,
        endWeight: Double,
        intervalDays: Int,
        gramsPerDay: Double,
        crossedTransfers: [WeightGainTransferEvidence] = [],
        startPenID: UUID? = nil,
        endPenID: UUID? = nil,
        isCalculable: Bool = true,
        canBeAttributedToSinglePen: Bool? = nil,
        exclusionReason: WeightGainExclusionReason? = nil
    ) {
        self.sheepID = sheepID
        self.startSample = startSample
        self.endSample = endSample
        self.startDate = startDate
        self.endDate = endDate
        self.startWeight = startWeight
        self.endWeight = endWeight
        self.intervalDays = intervalDays
        self.gramsPerDay = gramsPerDay
        self.crossedTransfers = crossedTransfers
        self.startPenID = startPenID
        self.endPenID = endPenID
        self.isCalculable = isCalculable
        self.canBeAttributedToSinglePen = canBeAttributedToSinglePen ??
            (startPenID != nil && startPenID == endPenID && crossedTransfers.isEmpty)
        self.exclusionReason = exclusionReason
    }

    var id: String { "\(sheepID.uuidString)-\(startDate.timeIntervalSince1970)-\(endDate.timeIntervalSince1970)" }
    var totalGainKilograms: Double { endWeight - startWeight }
}

struct WeightGainOverviewGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let scope: WeightGainAnalysisScope
    let result: WeightGainAnalysisResult
}

struct WeightGainAnalysisResult: Sendable {
    let filter: WeightGainAnalysisFilter
    let objectCount: Int
    let weighedCount: Int
    let calculableCount: Int
    let pairedCount: Int
    let downwardCount: Int
    let currentDownwardCount: Int
    let intervalCount: Int
    let averageDailyGainGrams: Double?
    let averageStartWeight: Double?
    let averageEndWeight: Double?
    let averageGainKilograms: Double?
    /// The actual observation bounds used by the result. These can differ from
    /// the user-selected filter dates because a date range is a boundary, not
    /// a requirement that a weighing happened at midnight on that date.
    let actualStartDate: Date?
    let actualEndDate: Date?
    let latestSampleDate: Date?
    let population: WeightGainAnalysisPopulation
    let cohortAnchorDate: Date?
    let cohortMembers: [WeightGainCohortMember]
    let transferEvents: [WeightGainTransferEvidence]
    let transferSheepCount: Int
    let crossPenIntervalCount: Int
    let crossPenSheepCount: Int
    let analysisTimeZoneIdentifier: String
    let factsReadAt: Date
    let unassignedIntervals: [WeightGainAnalysisInterval]
    let rows: [WeightGainAnalysisRow]
    let intervals: [WeightGainAnalysisInterval]
    let exclusions: [WeightGainExclusion]

    var missingPairCount: Int { max(objectCount - calculableCount, 0) }
}

struct WeightGainOverviewResult: Sendable {
    let all: WeightGainAnalysisResult
    let groups: [WeightGainOverviewGroup]
}

struct WeightGainFixedTrend: Sendable {
    struct Point: Identifiable, Sendable {
        let date: Date
        let kilograms: Double
        var id: Date { date }
    }
    let points: [Point]
    let sheepIDs: Set<UUID>
    let candidateCount: Int
    var excludedCount: Int { candidateCount - sheepIDs.count }
}

@MainActor
@Observable
final class WeightGainAnalysisViewModel {
    private(set) var snapshot: FarmAnalyticsSnapshot?
    private(set) var result: WeightGainAnalysisResult?
    private(set) var overview: WeightGainOverviewResult?
    private(set) var isCalculating = false

    private struct BatchCacheKey: Hashable {
        let id: UUID
        let name: String
    }

    private struct CacheKey: Hashable {
        let factsReadAt: Date
        let filter: WeightGainAnalysisFilter
        let batches: [BatchCacheKey]
    }

    private struct CachedCalculation {
        let result: WeightGainAnalysisResult
        let overview: WeightGainOverviewResult?
    }

    /// 分析页会在导航返回、切换子页或 SwiftUI 重建 destination 时重新创建
    /// ViewModel。结果以事实快照时间和完整筛选条件做键缓存，避免同一份事实
    /// 反复扫描；事实刷新后 factsReadAt 变化，旧结果自然不会混入新结果。
    private static var cache: [CacheKey: CachedCalculation] = [:]
    private static var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 12
    private var calculationRevision = UUID()
    private var calculatingKey: CacheKey?

    func replaceSnapshot(_ snapshot: FarmAnalyticsSnapshot) {
        calculationRevision = UUID()
        calculatingKey = nil
        self.snapshot = snapshot
        result = nil
        overview = nil
    }

    func clearCalculation() {
        calculationRevision = UUID()
        calculatingKey = nil
        result = nil
        overview = nil
        isCalculating = false
    }

    func calculate(filter: WeightGainAnalysisFilter, batches: [FarmAnalyticsBatchSnapshot]) {
        guard let snapshot else { return }
        let cacheKey = CacheKey(
            factsReadAt: snapshot.factsReadAt,
            filter: filter,
            batches: batches
                .map { BatchCacheKey(id: $0.id, name: $0.name) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        )
        if isCalculating, calculatingKey == cacheKey { return }
        if let cached = Self.cache[cacheKey] {
            // A different calculation may still be finishing in the detached
            // task. Invalidate it before applying the cached result so a quick
            // tab/filter switch cannot let the older result overwrite this one.
            calculationRevision = UUID()
            calculatingKey = nil
            result = cached.result
            overview = cached.overview
            isCalculating = false
            Self.touchCacheKey(cacheKey)
            return
        }
        let revision = UUID()
        calculationRevision = revision
        calculatingKey = cacheKey
        isCalculating = true
        if result?.filter != filter {
            result = nil
            overview = nil
        }
        Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                let all = WeightGainAnalyticsEngine.calculate(snapshot: snapshot, filter: filter)
                let overview: WeightGainOverviewResult?
                if filter.scope == .farm {
                    overview = WeightGainAnalyticsEngine.overview(snapshot: snapshot, batches: batches, filter: filter)
                } else {
                    overview = nil
                }
                return (all, overview)
            }.value
            guard let self, self.calculationRevision == revision else { return }
            self.result = computed.0
            self.overview = computed.1
            Self.cache[cacheKey] = CachedCalculation(result: computed.0, overview: computed.1)
            Self.touchCacheKey(cacheKey)
            while Self.cacheOrder.count > Self.cacheLimit {
                let expired = Self.cacheOrder.removeFirst()
                Self.cache.removeValue(forKey: expired)
            }
            self.calculatingKey = nil
            self.isCalculating = false
        }
    }

    private static func touchCacheKey(_ key: CacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}

enum WeightGainAnalyticsEngine {
    /// 一次分析只建立一份历史索引。旧实现会在每个称重区间反复扫描全部
    /// 羊只、批次成员和调群事件，数据量大时页面会明显等待。
    private struct PreparedIndex {
        let calendar: Calendar
        let sheepByID: [UUID: FarmAnalyticsSnapshot.Sheep]
        let transfersBySheep: [UUID: [FarmAnalyticsSnapshot.Transfer]]
        let membershipsBySheep: [UUID: [FarmAnalyticsSnapshot.BatchMembership]]
        let removalsBySheep: [UUID: [FarmAnalyticsSnapshot.Removal]]
        let canonicalSamples: [SheepWeightSample]
        let samplesBySheep: [UUID: [SheepWeightSample]]
        let penNames: [UUID: String]

        init(snapshot: FarmAnalyticsSnapshot) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
            self.calendar = calendar
            sheepByID = Dictionary(uniqueKeysWithValues: snapshot.sheep.map { ($0.id, $0) })
            transfersBySheep = Dictionary(grouping: snapshot.transfers, by: \.sheepID).mapValues {
                $0.sorted(by: WeightGainAnalyticsEngine.transferSort)
            }
            membershipsBySheep = Dictionary(grouping: snapshot.batchMemberships, by: \.sheepID).mapValues {
                $0.sorted { lhs, rhs in
                    if lhs.joinedAt != rhs.joinedAt { return lhs.joinedAt < rhs.joinedAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
            removalsBySheep = Dictionary(grouping: snapshot.removals, by: \.sheepID).mapValues {
                $0.sorted { lhs, rhs in
                    if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
            }
            canonicalSamples = SheepWeightSampleBuilder.dailyCanonical(snapshot.weightSamples, calendar: calendar)
            samplesBySheep = Dictionary(grouping: canonicalSamples, by: \.sheepID)
            penNames = Dictionary(uniqueKeysWithValues: snapshot.pens.map { ($0.id, $0.name) })
        }

        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }

        func penID(for sheep: FarmAnalyticsSnapshot.Sheep, at date: Date) -> UUID? {
            guard let transfers = transfersBySheep[sheep.id], !transfers.isEmpty else {
                return sheep.initialPenID
            }
            var lower = 0
            var upper = transfers.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if transfers[middle].occurredAt <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower > 0 ? transfers[lower - 1].toPenID : sheep.initialPenID
        }

        func removalDate(for sheep: FarmAnalyticsSnapshot.Sheep) -> Date? {
            [sheep.removedAt, removalsBySheep[sheep.id]?.map(\.occurredAt).min()]
                .compactMap { $0 }
                .min()
        }
    }

    static func observationDays(snapshot: FarmAnalyticsSnapshot, filter: WeightGainAnalysisFilter) -> [Date] {
        let filter = normalized(filter: filter, snapshot: snapshot)
        let index = PreparedIndex(snapshot: snapshot)
        let ids = Set(candidateSheep(snapshot: snapshot, filter: filter, index: index).map(\.id))
        return Set(index.canonicalSamples.compactMap { sample -> Date? in
            let day = index.day(sample.occurredAt)
            guard ids.contains(sample.sheepID), day >= filter.startDate, day <= filter.endDate,
                  sampleIsInScope(sheepID: sample.sheepID, occurredAt: sample.occurredAt,
                                  scope: filter.scope, snapshot: snapshot,
                                  population: filter.population,
                                  cohortIDs: ids,
                                  index: index) else { return nil }
            return day
        }).sorted()
    }

    /// Calendar days are explicit observation rounds, not inferred weighing tasks.
    /// Every point uses the intersection of sheep present in all selected rounds.
    static func fixedTrend(
        snapshot: FarmAnalyticsSnapshot,
        filter: WeightGainAnalysisFilter,
        dates: Set<Date>
    ) -> WeightGainFixedTrend {
        let filter = normalized(filter: filter, snapshot: snapshot)
        let index = PreparedIndex(snapshot: snapshot)
        let days = Set(dates.map { index.day($0) }).filter {
            $0 >= filter.startDate && $0 <= filter.endDate
        }.sorted()
        let candidates = candidateSheep(snapshot: snapshot, filter: filter, index: index)
        guard filter.scope != .farm, days.count >= 2 else {
            return .init(points: [], sheepIDs: [], candidateCount: candidates.count)
        }
        let timelines = index.samplesBySheep
        let cohortIDs = Set(candidates.map(\.id))
        var matched: [[SheepWeightSample]] = []
        var ids: Set<UUID> = []
        for sheep in candidates {
            let byDay = Dictionary(uniqueKeysWithValues: (timelines[sheep.id] ?? []).map {
                (index.day($0.occurredAt), $0)
            })
            let samples = days.compactMap { byDay[$0] }
            guard samples.count == days.count,
                  let first = samples.first, let last = samples.last,
                  intervalIsInScope(sheepID: sheep.id, startDate: first.occurredAt,
                                    endDate: last.occurredAt, scope: filter.scope, snapshot: snapshot,
                                    population: filter.population,
                                    cohortIDs: cohortIDs,
                                    index: index) else { continue }
            matched.append(samples)
            ids.insert(sheep.id)
        }
        let points: [WeightGainFixedTrend.Point] = matched.isEmpty ? [] : days.enumerated().map { index, day in
            .init(date: day, kilograms: matched.reduce(0) { $0 + $1[index].kilograms } / Double(matched.count))
        }
        return .init(points: points, sheepIDs: ids, candidateCount: candidates.count)
    }

    static func calculate(
        snapshot: FarmAnalyticsSnapshot,
        filter: WeightGainAnalysisFilter
    ) -> WeightGainAnalysisResult {
        return calculate(snapshot: snapshot, filter: filter, index: PreparedIndex(snapshot: snapshot))
    }

    private static func calculate(
        snapshot: FarmAnalyticsSnapshot,
        filter: WeightGainAnalysisFilter,
        index: PreparedIndex
    ) -> WeightGainAnalysisResult {
        let filter = normalized(filter: filter, snapshot: snapshot)
        let candidates = candidateSheep(snapshot: snapshot, filter: filter, index: index)
        let cohortIDs = Set(candidates.map(\.id))
        let samplesBySheep = index.samplesBySheep
        var intervalsBySheep: [UUID: [WeightGainAnalysisInterval]] = [:]
        var exclusions: [WeightGainExclusion] = []

        for sheep in candidates {
            let timeline = (samplesBySheep[sheep.id] ?? []).sorted { $0.occurredAt < $1.occurredAt }
            let rangeSamples = timeline.filter {
                let day = index.day($0.occurredAt)
                return day >= filter.startDate && day <= filter.endDate
            }
            let relevantSamples = timeline.filter {
                let day = index.day($0.occurredAt)
                return day >= filter.startDate && day <= filter.endDate && sampleIsInScope(
                    sheepID: sheep.id,
                    occurredAt: $0.occurredAt,
                    scope: filter.scope,
                    snapshot: snapshot,
                    population: filter.population,
                    cohortIDs: cohortIDs,
                    index: index
                )
            }
            let intervals: [WeightGainAnalysisInterval]
            switch filter.mode {
            case .period:
                intervals = periodIntervals(
                    timeline: timeline,
                    sheepID: sheep.id,
                    filter: filter,
                    snapshot: snapshot,
                    cohortIDs: cohortIDs,
                    index: index
                )
            case .paired:
                intervals = pairedIntervals(
                    timeline: timeline,
                    sheepID: sheep.id,
                    filter: filter,
                    snapshot: snapshot,
                    cohortIDs: cohortIDs,
                    index: index
                )
            }
            if intervals.isEmpty {
                exclusions.append(.init(
                    sheepID: sheep.id,
                    earTag: sheep.earTag,
                    reason: exclusionReason(
                        mode: filter.mode,
                        timeline: timeline,
                        rangeSamples: rangeSamples,
                        relevantSamples: relevantSamples,
                        filter: filter,
                        snapshot: snapshot,
                        sheepID: sheep.id,
                        index: index
                    )
                ))
            } else {
                intervalsBySheep[sheep.id] = intervals
            }
        }

        let unassignedIntervals = filter.population == .inPen && isPenScoped(filter.scope)
            ? candidates.flatMap { sheep in
                unassignedPenIntervals(
                    timeline: samplesBySheep[sheep.id] ?? [],
                    sheepID: sheep.id,
                    filter: filter,
                    snapshot: snapshot,
                    cohortIDs: cohortIDs,
                    index: index
                )
            }
            : []

        let rows = candidates.compactMap { sheep -> WeightGainAnalysisRow? in
            guard let intervals = intervalsBySheep[sheep.id], !intervals.isEmpty else { return nil }
            return aggregateRow(sheep: sheep, intervals: intervals, filter: filter, snapshot: snapshot, index: index)
        }
        let allScopedSamples = candidates.flatMap { sheep in
            (samplesBySheep[sheep.id] ?? []).filter {
                    let day = index.day($0.occurredAt)
                return day >= filter.startDate && day <= filter.endDate && sampleIsInScope(
                    sheepID: sheep.id,
                    occurredAt: $0.occurredAt,
                    scope: filter.scope,
                    snapshot: snapshot,
                    population: filter.population,
                    cohortIDs: cohortIDs,
                    index: index
                )
            }
        }
        let weightedRates = rows.map(\.gramsPerDay)
        let actualStartDate = intervalsBySheep.values.flatMap { $0 }.map(\.startDate).min()
        let actualEndDate = intervalsBySheep.values.flatMap { $0 }.map(\.endDate).max()
        let latestSampleDate = allScopedSamples.map(\.occurredAt).max().map { index.day($0) }
        let cohortMembers = filter.population == .trackedCohort ? cohortMembers(snapshot: snapshot, filter: filter, index: index) : []
        let transferEvents = transferEvents(
            snapshot: snapshot,
            sheepIDs: cohortIDs,
            startDate: filter.startDate,
            endDate: rangeEndExclusive(filter: filter, snapshot: snapshot),
            index: index
        )
        let intervals = intervalsBySheep.values.flatMap { $0 }
        let crossPenIntervals = intervals.filter { !$0.crossedTransfers.isEmpty } + unassignedIntervals
        return WeightGainAnalysisResult(
            filter: filter,
            objectCount: candidates.count,
            weighedCount: Set(allScopedSamples.map(\.sheepID)).count,
            calculableCount: rows.count,
            pairedCount: filter.mode == .paired ? rows.count : 0,
            downwardCount: rows.count { $0.isDown },
            currentDownwardCount: rows.count { $0.isCurrentlyPresent && $0.isDown },
            intervalCount: intervalsBySheep.values.reduce(0) { $0 + $1.count },
            averageDailyGainGrams: weightedRates.isEmpty ? nil : weightedRates.reduce(0, +) / Double(weightedRates.count),
            averageStartWeight: rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.startWeight } / Double(rows.count),
            averageEndWeight: rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.endWeight } / Double(rows.count),
            averageGainKilograms: rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.totalGainKilograms } / Double(rows.count),
            actualStartDate: actualStartDate,
            actualEndDate: actualEndDate,
            latestSampleDate: latestSampleDate,
            population: filter.population,
            cohortAnchorDate: filter.population == .trackedCohort ? cohortAnchorInstant(filter: filter, snapshot: snapshot) : nil,
            cohortMembers: cohortMembers,
            transferEvents: transferEvents,
            transferSheepCount: Set(transferEvents.map(\.sheepID)).count,
            crossPenIntervalCount: crossPenIntervals.count,
            crossPenSheepCount: Set(crossPenIntervals.map(\.sheepID)).count,
            analysisTimeZoneIdentifier: snapshot.timeZoneIdentifier,
            factsReadAt: snapshot.factsReadAt,
            unassignedIntervals: unassignedIntervals.sorted { $0.endDate < $1.endDate },
            rows: rows.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending },
            intervals: intervals.sorted { $0.endDate < $1.endDate },
            exclusions: exclusions.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
        )
    }

    static func overview(
        snapshot: FarmAnalyticsSnapshot,
        batches: [FarmAnalyticsBatchSnapshot],
        filter: WeightGainAnalysisFilter
    ) -> WeightGainOverviewResult {
        let normalized = normalized(filter: filter, snapshot: snapshot)
        let index = PreparedIndex(snapshot: snapshot)
        let all = calculate(snapshot: snapshot, filter: normalized, index: index)
        var groups: [WeightGainOverviewGroup] = []
        for batch in batches {
            let batchFilter = WeightGainAnalysisFilter(
                scope: .batch(batch.id),
                mode: normalized.mode,
                startDate: normalized.startDate,
                endDate: normalized.endDate,
                sampleScope: normalized.sampleScope
            )
            let result = calculate(snapshot: snapshot, filter: batchFilter, index: index)
            guard result.objectCount > 0 else { continue }
            groups.append(.init(
                id: batch.id.uuidString,
                title: batch.name.isEmpty ? "未命名生产批次" : batch.name,
                subtitle: "生产批次",
                scope: .batch(batch.id),
                result: result
            ))
        }
        let unassignedFilter = WeightGainAnalysisFilter(
            scope: .unassigned,
            mode: normalized.mode,
            startDate: normalized.startDate,
            endDate: normalized.endDate,
            sampleScope: normalized.sampleScope
        )
        let unassigned = calculate(snapshot: snapshot, filter: unassignedFilter, index: index)
        if unassigned.objectCount > 0 {
            groups.append(.init(
                id: "unassigned",
                title: "未分生产批次",
                subtitle: "可继续按圈舍查看",
                scope: .unassigned,
                result: unassigned
            ))
        }
        return WeightGainOverviewResult(all: all, groups: groups)
    }

    private static func candidateSheep(
        snapshot: FarmAnalyticsSnapshot,
        filter: WeightGainAnalysisFilter,
        index: PreparedIndex? = nil
    ) -> [FarmAnalyticsSnapshot.Sheep] {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        let removedIDs = Set(index.removalsBySheep.compactMap { sheepID, removals in
            removals.contains { $0.occurredAt <= rangeEndExclusive(filter: filter, snapshot: snapshot) } ? sheepID : nil
        })
        let trackedIDs = filter.population == .trackedCohort ? Set(cohortMembers(snapshot: snapshot, filter: filter, index: index).map(\.sheepID)) : nil
        return snapshot.sheep
            .filter { sheep in
                guard !sheep.isHistoricalArchive,
                      index.day(sheep.enteredAt) <= filter.endDate,
                      sheep.removedAt.map({ $0 >= filter.startDate }) ?? true else { return false }
                if let trackedIDs, !trackedIDs.contains(sheep.id) { return false }
                let inScope: Bool
                switch filter.scope {
                case .farm:
                    inScope = true
                case .batch(let batchID):
                    inScope = (index.membershipsBySheep[sheep.id] ?? []).contains {
                        $0.batchID == batchID && $0.sheepID == sheep.id &&
                            index.day($0.joinedAt) <= filter.endDate && ($0.leftAt.map { $0 >= filter.startDate } ?? true)
                    }
                case .batchAndPen(let batchID, let penID):
                    let batchRelevant = (index.membershipsBySheep[sheep.id] ?? []).contains {
                        $0.batchID == batchID && $0.sheepID == sheep.id &&
                            index.day($0.joinedAt) <= filter.endDate && ($0.leftAt.map { $0 >= filter.startDate } ?? true)
                    }
                    inScope = batchRelevant && penWasRelevant(
                        sheep: sheep,
                        penID: penID,
                        startDate: filter.startDate,
                        endDate: rangeEndExclusive(filter: filter, snapshot: snapshot),
                        transfers: snapshot.transfers,
                        index: index
                    )
                case .batchAndPens(let batchID, let penIDs):
                    let batchRelevant = (index.membershipsBySheep[sheep.id] ?? []).contains {
                        $0.batchID == batchID && $0.sheepID == sheep.id &&
                            index.day($0.joinedAt) <= filter.endDate && ($0.leftAt.map { $0 >= filter.startDate } ?? true)
                    }
                    inScope = batchRelevant && penWasRelevant(
                        sheep: sheep,
                        penIDs: penIDs,
                        startDate: filter.startDate,
                        endDate: rangeEndExclusive(filter: filter, snapshot: snapshot),
                        transfers: snapshot.transfers,
                        index: index
                    )
                case .unassigned:
                    let memberships = index.membershipsBySheep[sheep.id] ?? []
                    let end = rangeEndExclusive(filter: filter, snapshot: snapshot)
                    let boundaries = [max(filter.startDate, sheep.enteredAt), min(end, sheep.removedAt ?? end)] + memberships.compactMap {
                        $0.leftAt?.addingTimeInterval(0.001)
                    }
                    inScope = boundaries.contains { date in
                        date >= max(filter.startDate, sheep.enteredAt) && date <= min(end, sheep.removedAt ?? end) &&
                            !memberships.contains { $0.contains(eventAt: date) }
                    }
                case .pen(let penID):
                    inScope = penWasRelevant(
                        sheep: sheep,
                        penID: penID,
                        startDate: filter.startDate,
                        endDate: rangeEndExclusive(filter: filter, snapshot: snapshot),
                        transfers: snapshot.transfers,
                        index: index
                    )
                case .pens(let penIDs):
                    inScope = penWasRelevant(
                        sheep: sheep,
                        penIDs: penIDs,
                        startDate: filter.startDate,
                        endDate: rangeEndExclusive(filter: filter, snapshot: snapshot),
                        transfers: snapshot.transfers,
                        index: index
                    )
                }
                guard inScope else { return false }
                switch filter.sampleScope {
                case .all:
                    return true
                case .inHerdOnly:
                    return sheep.status == .active && !removedIDs.contains(sheep.id)
                case .removedOnly:
                    return sheep.status != .active || removedIDs.contains(sheep.id)
                }
            }
            .sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
    }

    private static func analysisCalendar(snapshot: FarmAnalyticsSnapshot) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
        return calendar
    }

    private static func normalized(filter: WeightGainAnalysisFilter, snapshot: FarmAnalyticsSnapshot) -> WeightGainAnalysisFilter {
        let calendar = analysisCalendar(snapshot: snapshot)
        let first = calendar.startOfDay(for: min(filter.startDate, filter.endDate))
        let last = calendar.startOfDay(for: max(filter.startDate, filter.endDate))
        let customDate = filter.cohortDate.map { calendar.startOfDay(for: min(max($0, first), last)) }
        // 普通圈舍分析按结束日的名单跟踪同羊称重，转群不会切断增重。
        // 显式的在舍绩效分析仍由 .inPen 保留连续居舍口径。
        let usesEndPenCohort = filter.population == .wholeObject && isPenScoped(filter.scope)
        return WeightGainAnalysisFilter(
            scope: filter.scope,
            mode: filter.mode,
            startDate: first,
            endDate: last,
            sampleScope: filter.sampleScope,
            population: usesEndPenCohort ? .trackedCohort : filter.population,
            cohortAnchor: usesEndPenCohort ? .analysisEnd : filter.cohortAnchor,
            cohortDate: customDate
        )
    }

    private static func day(_ date: Date, snapshot: FarmAnalyticsSnapshot) -> Date {
        analysisCalendar(snapshot: snapshot).startOfDay(for: date)
    }

    private static func rangeEndExclusive(filter: WeightGainAnalysisFilter, snapshot: FarmAnalyticsSnapshot) -> Date {
        let calendar = analysisCalendar(snapshot: snapshot)
        let start = calendar.startOfDay(for: filter.endDate)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001) ?? filter.endDate
        return calendar.isDate(start, inSameDayAs: snapshot.factsReadAt) ? min(snapshot.factsReadAt, endOfDay) : endOfDay
    }

    private static func cohortAnchorInstant(filter: WeightGainAnalysisFilter, snapshot: FarmAnalyticsSnapshot) -> Date {
        let calendar = analysisCalendar(snapshot: snapshot)
        switch filter.cohortAnchor {
        case .analysisStart:
            return calendar.startOfDay(for: filter.startDate)
        case .custom:
            return filter.cohortDate.map(calendar.startOfDay) ?? rangeEndExclusive(filter: filter, snapshot: snapshot)
        case .analysisEnd:
            return rangeEndExclusive(filter: filter, snapshot: snapshot)
        }
    }

    private static func isPresentAt(_ sheep: FarmAnalyticsSnapshot.Sheep, date: Date, snapshot: FarmAnalyticsSnapshot) -> Bool {
        guard sheep.enteredAt <= date else { return false }
        let removalAt = [sheep.removedAt, snapshot.removals.filter { $0.sheepID == sheep.id }.map(\.occurredAt).min()].compactMap { $0 }.min()
        return removalAt.map { date <= $0 } ?? true
    }

    private static func cohortMembers(
        snapshot: FarmAnalyticsSnapshot,
        filter: WeightGainAnalysisFilter,
        index: PreparedIndex? = nil
    ) -> [WeightGainCohortMember] {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        let anchor = cohortAnchorInstant(filter: filter, snapshot: snapshot)
        let transfersBySheep = index.transfersBySheep
        return snapshot.sheep.compactMap { sheep in
            guard !sheep.isHistoricalArchive,
                  sheep.enteredAt <= anchor,
                  index.removalDate(for: sheep).map({ anchor <= $0 }) ?? true else { return nil }
            let penID = index.penID(for: sheep, at: anchor)
            let selectedBatch: FarmAnalyticsSnapshot.BatchMembership?
            switch filter.scope {
            case .batch(let batchID), .batchAndPen(let batchID, _), .batchAndPens(let batchID, _):
                selectedBatch = (index.membershipsBySheep[sheep.id] ?? [])
                    .filter { $0.batchID == batchID && $0.contains(eventAt: anchor) }
                    .sorted { $0.joinedAt > $1.joinedAt }
                    .first
            default:
                selectedBatch = nil
            }
            let anchorBatch = (index.membershipsBySheep[sheep.id] ?? [])
                .filter { $0.contains(eventAt: anchor) }
                .sorted { $0.joinedAt > $1.joinedAt }
                .first
            let isInScope: Bool
            switch filter.scope {
            case .farm:
                isInScope = true
            case .batch, .batchAndPen, .batchAndPens:
                isInScope = selectedBatch != nil && penMatchesScope(penID: penID, scope: filter.scope)
            case .pen(let selectedPenID):
                isInScope = penID == selectedPenID
            case .pens(let selectedPenIDs):
                isInScope = penID.map(selectedPenIDs.contains) ?? false
            case .unassigned:
                isInScope = anchorBatch == nil
            }
            guard isInScope else { return nil }
            let anchorTransfer = transfersBySheep[sheep.id]?
                .filter { $0.occurredAt <= anchor && $0.toPenID == penID }
                .sorted { transferSort($0, $1) }
                .last
            return WeightGainCohortMember(
                sheepID: sheep.id,
                earTag: sheep.earTag,
                anchorDate: anchor,
                anchorPenID: penID,
                anchorPenName: penID.flatMap { index.penNames[$0] },
                batchID: selectedBatch?.batchID ?? anchorBatch?.batchID,
                batchMembershipID: selectedBatch?.id ?? anchorBatch?.id,
                anchorTransferID: anchorTransfer?.id
            )
        }
        .sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
    }

    private static func penMatchesScope(penID: UUID?, scope: WeightGainAnalysisScope) -> Bool {
        switch scope {
        case .batchAndPen(_, let selectedPenID): return penID == selectedPenID
        case .batchAndPens(_, let selectedPenIDs): return penID.map(selectedPenIDs.contains) ?? false
        default: return true
        }
    }

    private static func periodIntervals(
        timeline: [SheepWeightSample],
        sheepID: UUID,
        filter: WeightGainAnalysisFilter,
        snapshot: FarmAnalyticsSnapshot,
        cohortIDs: Set<UUID>,
        index: PreparedIndex? = nil
    ) -> [WeightGainAnalysisInterval] {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        return zip(timeline, timeline.dropFirst()).compactMap { (pair: (SheepWeightSample, SheepWeightSample)) -> WeightGainAnalysisInterval? in
            let start = pair.0
            let end = pair.1
            let startDate = index.day(start.occurredAt)
            let endDate = index.day(end.occurredAt)
            guard startDate >= filter.startDate, endDate <= filter.endDate else { return nil }
            guard !(filter.population == .inPen && hasTransferConflict(sheepID: sheepID, at: start.occurredAt, or: end.occurredAt, snapshot: snapshot, index: index)) else { return nil }
            guard let days = positiveDays(from: startDate, to: endDate, snapshot: snapshot, index: index),
                  intervalIsInScope(
                      sheepID: sheepID,
                      startDate: start.occurredAt,
                      endDate: end.occurredAt,
                      scope: filter.scope,
                      snapshot: snapshot,
                      population: filter.population,
                      cohortIDs: cohortIDs,
                      index: index
                  ) else { return nil }
            let crossedTransfers = transferEvidence(
                sheepID: sheepID,
                from: start.occurredAt,
                to: end.occurredAt,
                snapshot: snapshot,
                index: index
            )
            return WeightGainAnalysisInterval(
                sheepID: sheepID,
                startSample: start,
                endSample: end,
                startDate: start.occurredAt,
                endDate: end.occurredAt,
                startWeight: start.kilograms,
                endWeight: end.kilograms,
                intervalDays: days,
                gramsPerDay: (end.kilograms - start.kilograms) * 1_000 / Double(days),
                crossedTransfers: crossedTransfers,
                startPenID: index.sheepByID[sheepID].flatMap { index.penID(for: $0, at: start.occurredAt) },
                endPenID: index.sheepByID[sheepID].flatMap { index.penID(for: $0, at: end.occurredAt) }
            )
        }
    }

    private static func pairedIntervals(
        timeline: [SheepWeightSample],
        sheepID: UUID,
        filter: WeightGainAnalysisFilter,
        snapshot: FarmAnalyticsSnapshot,
        cohortIDs: Set<UUID>,
        index: PreparedIndex? = nil
    ) -> [WeightGainAnalysisInterval] {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        let candidates = timeline.filter {
            let day = index.day($0.occurredAt)
            return day >= filter.startDate && day <= filter.endDate &&
                sampleIsInScope(
                    sheepID: sheepID,
                    occurredAt: $0.occurredAt,
                    scope: filter.scope,
                    snapshot: snapshot,
                    population: filter.population,
                    cohortIDs: cohortIDs,
                    index: index
                )
        }
        guard candidates.count >= 2 else { return [] }
        var segments: [[SheepWeightSample]] = []
        if filter.population == .trackedCohort {
            var current: [SheepWeightSample] = []
            for sample in candidates {
                guard let previous = current.last else {
                    current = [sample]
                    continue
                }
                let continuous = intervalIsInScope(
                    sheepID: sheepID,
                    startDate: previous.occurredAt,
                    endDate: sample.occurredAt,
                    scope: filter.scope,
                    snapshot: snapshot,
                    population: filter.population,
                    cohortIDs: cohortIDs,
                    index: index
                )
                if continuous {
                    current.append(sample)
                } else {
                    if current.count >= 2 { segments.append(current) }
                    current = [sample]
                }
            }
            if current.count >= 2 { segments.append(current) }
        } else {
            segments = [candidates]
        }
        return segments.compactMap { segment in
            guard let start = segment.first, let end = segment.last, start.id != end.id,
                  let days = positiveDays(from: start.occurredAt, to: end.occurredAt, snapshot: snapshot, index: index),
                  intervalIsInScope(
                      sheepID: sheepID,
                      startDate: start.occurredAt,
                      endDate: end.occurredAt,
                    scope: filter.scope,
                    snapshot: snapshot,
                    population: filter.population,
                    cohortIDs: cohortIDs,
                    index: index
                  ),
                  !(filter.population == .inPen && hasTransferConflict(sheepID: sheepID, at: start.occurredAt, or: end.occurredAt, snapshot: snapshot, index: index)),
                  let sheep = index.sheepByID[sheepID] else { return nil }
            return WeightGainAnalysisInterval(
                sheepID: sheepID,
                startSample: start,
                endSample: end,
                startDate: start.occurredAt,
                endDate: end.occurredAt,
                startWeight: start.kilograms,
                endWeight: end.kilograms,
                intervalDays: days,
                gramsPerDay: (end.kilograms - start.kilograms) * 1_000 / Double(days),
                crossedTransfers: transferEvidence(sheepID: sheepID, from: start.occurredAt, to: end.occurredAt, snapshot: snapshot, index: index),
                startPenID: index.penID(for: sheep, at: start.occurredAt),
                endPenID: index.penID(for: sheep, at: end.occurredAt)
            )
        }
    }

    private static func isPenScoped(_ scope: WeightGainAnalysisScope) -> Bool {
        switch scope {
        case .pen, .pens, .batchAndPen, .batchAndPens:
            return true
        default:
            return false
        }
    }

    private static func unassignedPenIntervals(
        timeline: [SheepWeightSample],
        sheepID: UUID,
        filter: WeightGainAnalysisFilter,
        snapshot: FarmAnalyticsSnapshot,
        cohortIDs: Set<UUID>,
        index: PreparedIndex? = nil
    ) -> [WeightGainAnalysisInterval] {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        let ordered = timeline.sorted { $0.occurredAt < $1.occurredAt }
        return zip(ordered, ordered.dropFirst()).compactMap { (pair: (SheepWeightSample, SheepWeightSample)) -> WeightGainAnalysisInterval? in
            let start = pair.0
            let end = pair.1
            let startDay = index.day(start.occurredAt)
            let endDay = index.day(end.occurredAt)
            guard startDay >= filter.startDate, endDay <= filter.endDate,
                  let days = positiveDays(from: start.occurredAt, to: end.occurredAt, snapshot: snapshot, index: index),
                  intervalTouchesPenScope(sheepID: sheepID, start: start.occurredAt, end: end.occurredAt, scope: filter.scope, snapshot: snapshot, index: index),
                  (hasTransferConflict(sheepID: sheepID, at: start.occurredAt, or: end.occurredAt, snapshot: snapshot, index: index) ||
                   !intervalIsInScope(sheepID: sheepID, startDate: start.occurredAt, endDate: end.occurredAt, scope: filter.scope, snapshot: snapshot, population: .inPen, cohortIDs: cohortIDs, index: index)),
                  let sheep = index.sheepByID[sheepID] else { return nil }
            let conflict = hasTransferConflict(sheepID: sheepID, at: start.occurredAt, or: end.occurredAt, snapshot: snapshot, index: index)
            return WeightGainAnalysisInterval(
                sheepID: sheepID,
                startSample: start,
                endSample: end,
                startDate: start.occurredAt,
                endDate: end.occurredAt,
                startWeight: start.kilograms,
                endWeight: end.kilograms,
                intervalDays: days,
                gramsPerDay: (end.kilograms - start.kilograms) * 1_000 / Double(days),
                crossedTransfers: transferEvidence(sheepID: sheepID, from: start.occurredAt, to: end.occurredAt, snapshot: snapshot, index: index),
                startPenID: index.penID(for: sheep, at: start.occurredAt),
                endPenID: index.penID(for: sheep, at: end.occurredAt),
                isCalculable: false,
                canBeAttributedToSinglePen: false,
                exclusionReason: conflict ? .conflictingEventTime : .outOfScope
            )
        }
    }

    private static func intervalTouchesPenScope(
        sheepID: UUID,
        start: Date,
        end: Date,
        scope: WeightGainAnalysisScope,
        snapshot: FarmAnalyticsSnapshot,
        index: PreparedIndex? = nil
    ) -> Bool {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        guard let sheep = index.sheepByID[sheepID] else { return false }
        let selectedPenIDs: Set<UUID>
        switch scope {
        case .pen(let penID), .batchAndPen(_, let penID):
            selectedPenIDs = [penID]
        case .pens(let penIDs), .batchAndPens(_, let penIDs):
            selectedPenIDs = penIDs
        default:
            return false
        }
        guard !selectedPenIDs.isEmpty else { return false }
        if index.penID(for: sheep, at: start).map(selectedPenIDs.contains) == true ||
            index.penID(for: sheep, at: end).map(selectedPenIDs.contains) == true {
            return true
        }
        return (index.transfersBySheep[sheepID] ?? []).contains {
            $0.sheepID == sheepID && $0.occurredAt >= start && $0.occurredAt <= end &&
                ($0.fromPenID.map(selectedPenIDs.contains) == true || $0.toPenID.map(selectedPenIDs.contains) == true)
        }
    }

    private static func hasTransferConflict(
        sheepID: UUID,
        at first: Date,
        or second: Date,
        snapshot: FarmAnalyticsSnapshot,
        index: PreparedIndex? = nil
    ) -> Bool {
        let transfers = index?.transfersBySheep[sheepID] ?? snapshot.transfers.filter { $0.sheepID == sheepID }
        return transfers.contains {
            $0.sheepID == sheepID && ($0.occurredAt == first || $0.occurredAt == second)
        }
    }

    private static func transferEvidence(
        sheepID: UUID,
        from start: Date,
        to end: Date,
        snapshot: FarmAnalyticsSnapshot,
        includesStart: Bool = false,
        index: PreparedIndex? = nil
    ) -> [WeightGainTransferEvidence] {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        guard let sheep = index.sheepByID[sheepID] else { return [] }
        let transfers = index.transfersBySheep[sheepID] ?? []
        return transfers.enumerated().compactMap { offset, transfer in
                guard (transfer.occurredAt > start || (includesStart && transfer.occurredAt == start)),
                      transfer.occurredAt <= end else { return nil }
                // 旧转群记录可能没有原舍字段；用完整时间线还原前一圈舍。
                let fromPenID = transfer.fromPenID ?? (offset > 0 ? transfers[offset - 1].toPenID : sheep.initialPenID)
                return WeightGainTransferEvidence(
                    id: transfer.id,
                    sheepID: sheepID,
                    earTag: sheep.earTag,
                    occurredAt: transfer.occurredAt,
                    recordedAt: transfer.recordedAt,
                    fromPenID: fromPenID,
                    toPenID: transfer.toPenID,
                    fromPenName: fromPenID.map { index.penNames[$0] ?? "历史圈舍" },
                    toPenName: transfer.toPenID.map { index.penNames[$0] ?? "历史圈舍" },
                    note: transfer.note
                )
            }
    }

    private static func transferEvents(
        snapshot: FarmAnalyticsSnapshot,
        sheepIDs: Set<UUID>,
        startDate: Date,
        endDate: Date,
        index: PreparedIndex? = nil
    ) -> [WeightGainTransferEvidence] {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        return sheepIDs.flatMap {
                transferEvidence(sheepID: $0, from: startDate, to: endDate,
                                 snapshot: snapshot, includesStart: true, index: index)
            }
            .sorted { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func aggregateRow(
        sheep: FarmAnalyticsSnapshot.Sheep,
        intervals: [WeightGainAnalysisInterval],
        filter: WeightGainAnalysisFilter,
        snapshot: FarmAnalyticsSnapshot,
        index: PreparedIndex
    ) -> WeightGainAnalysisRow {
        let ordered = intervals.sorted { $0.startDate < $1.startDate }
        let totalDays = ordered.reduce(0) { $0 + $1.intervalDays }
        let totalGain = ordered.reduce(0.0) { $0 + $1.totalGainKilograms }
        let gramsPerDay = totalDays > 0 ? totalGain * 1_000 / Double(totalDays) : 0
        let analysisEnd = rangeEndExclusive(filter: filter, snapshot: snapshot)
        let analysisEndPenID = index.penID(for: sheep, at: analysisEnd)
        let historyStart = max(filter.startDate, sheep.enteredAt)
        let historyStartPenID = index.penID(for: sheep, at: historyStart)
        return WeightGainAnalysisRow(
            sheepID: sheep.id,
            earTag: sheep.earTag,
            sex: sheep.sex,
            purpose: sheep.purpose,
            status: sheep.status,
            analysisEndDate: analysisEnd,
            analysisEndPenID: analysisEndPenID,
            analysisEndPenName: analysisEndPenID.map { index.penNames[$0] ?? "历史圈舍" },
            penHistoryStartDate: historyStart,
            penHistoryStartPenName: historyStartPenID.map { index.penNames[$0] ?? "历史圈舍" },
            penHistory: transferEvidence(sheepID: sheep.id, from: historyStart, to: analysisEnd,
                                        snapshot: snapshot, includesStart: true, index: index),
            startDate: ordered.first?.startDate ?? .distantPast,
            endDate: ordered.last?.endDate ?? .distantPast,
            startWeight: ordered.first?.startWeight ?? 0,
            endWeight: ordered.last?.endWeight ?? 0,
            intervalDays: totalDays,
            intervalCount: ordered.count,
            gramsPerDay: gramsPerDay,
            totalGainKilograms: totalGain
        )
    }

    private static func exclusionReason(
        mode: WeightGainAnalysisMode,
        timeline: [SheepWeightSample],
        rangeSamples: [SheepWeightSample],
        relevantSamples: [SheepWeightSample],
        filter: WeightGainAnalysisFilter,
        snapshot: FarmAnalyticsSnapshot,
        sheepID: UUID,
        index: PreparedIndex? = nil
    ) -> WeightGainExclusionReason {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        guard !relevantSamples.isEmpty else { return .noSample }
        if filter.population == .inPen,
           zip(rangeSamples, rangeSamples.dropFirst()).contains(where: { hasTransferConflict(sheepID: sheepID, at: $0.0.occurredAt, or: $0.1.occurredAt, snapshot: snapshot, index: index) }) {
            return .conflictingEventTime
        }
        if mode == .paired {
            if relevantSamples.count < 2 { return .missingPair }
        } else if rangeSamples.count < 2 {
            return .missingPair
        }
        return intervalIsInScope(
            sheepID: sheepID,
            startDate: rangeSamples.first?.occurredAt ?? filter.startDate,
            endDate: rangeSamples.last?.occurredAt ?? filter.endDate,
            scope: filter.scope,
            snapshot: snapshot,
            index: index
        ) ? .missingPair : .outOfScope
    }

    private static func positiveDays(from start: Date, to end: Date, snapshot: FarmAnalyticsSnapshot, index: PreparedIndex? = nil) -> Int? {
        let calendar = index?.calendar ?? analysisCalendar(snapshot: snapshot)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return days > 0 ? days : nil
    }

    private static func sampleIsInScope(
        sheepID: UUID,
        occurredAt: Date,
        scope: WeightGainAnalysisScope,
        snapshot: FarmAnalyticsSnapshot,
        population: WeightGainAnalysisPopulation = .wholeObject,
        cohortIDs: Set<UUID> = [],
        index: PreparedIndex? = nil
    ) -> Bool {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        guard let sheep = index.sheepByID[sheepID],
              sheep.enteredAt <= occurredAt,
              sheep.removedAt.map({ $0 >= occurredAt }) ?? true else { return false }
        if population == .trackedCohort && !cohortIDs.contains(sheepID) { return false }
        if population == .trackedCohort {
            switch scope {
            case .batch(let batchID), .batchAndPen(let batchID, _), .batchAndPens(let batchID, _):
                return (index.membershipsBySheep[sheepID] ?? []).contains { $0.batchID == batchID && $0.contains(eventAt: occurredAt) }
            case .unassigned:
                return !(index.membershipsBySheep[sheepID] ?? []).contains { $0.contains(eventAt: occurredAt) }
            default:
                return true
            }
        }
        switch scope {
        case .farm:
            return true
        case .batch(let batchID):
            return (index.membershipsBySheep[sheepID] ?? []).contains {
                $0.batchID == batchID && $0.sheepID == sheepID && $0.contains(eventAt: occurredAt)
            }
        case .batchAndPen(let batchID, let penID):
            return (index.membershipsBySheep[sheepID] ?? []).contains {
                $0.batchID == batchID && $0.contains(eventAt: occurredAt)
            } && index.penID(for: sheep, at: occurredAt) == penID
        case .batchAndPens(let batchID, let penIDs):
            return (index.membershipsBySheep[sheepID] ?? []).contains {
                $0.batchID == batchID && $0.contains(eventAt: occurredAt)
            } && index.penID(for: sheep, at: occurredAt).map(penIDs.contains) == true
        case .unassigned:
            return !(index.membershipsBySheep[sheepID] ?? []).contains { $0.contains(eventAt: occurredAt) }
        case .pen(let penID):
            return index.penID(for: sheep, at: occurredAt) == penID
        case .pens(let penIDs):
            return index.penID(for: sheep, at: occurredAt).map(penIDs.contains) == true
        }
    }

    private static func intervalIsInScope(
        sheepID: UUID,
        startDate: Date,
        endDate: Date,
        scope: WeightGainAnalysisScope,
        snapshot: FarmAnalyticsSnapshot,
        population: WeightGainAnalysisPopulation = .wholeObject,
        cohortIDs: Set<UUID> = [],
        index: PreparedIndex? = nil
    ) -> Bool {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        guard let sheep = index.sheepByID[sheepID],
              sheep.enteredAt <= startDate,
              sheep.removedAt.map({ $0 >= endDate }) ?? true else { return false }
        if population == .trackedCohort && !cohortIDs.contains(sheepID) { return false }
        if population == .trackedCohort {
            switch scope {
            case .batch(let batchID), .batchAndPen(let batchID, _), .batchAndPens(let batchID, _):
                return batchIntervalIsContinuous(
                    sheepID: sheepID,
                    batchID: batchID,
                    startDate: startDate,
                    endDate: endDate,
                    memberships: index.membershipsBySheep[sheepID] ?? []
                )
            case .unassigned:
                return !(index.membershipsBySheep[sheepID] ?? []).contains {
                    $0.joinedAt <= endDate && ($0.leftAt.map { $0 >= startDate } ?? true)
                }
            default:
                return true
            }
        }
        switch scope {
        case .farm:
            return true
        case .batch(let batchID):
            return batchIntervalIsContinuous(
                sheepID: sheepID,
                batchID: batchID,
                startDate: startDate,
                endDate: endDate,
                memberships: index.membershipsBySheep[sheepID] ?? []
            )
        case .batchAndPen(let batchID, let penID):
            return batchIntervalIsContinuous(
                sheepID: sheepID,
                batchID: batchID,
                startDate: startDate,
                endDate: endDate,
                memberships: snapshot.batchMemberships
            ) && penIntervalIsContinuous(
                sheepID: sheepID,
                penID: penID,
                startDate: startDate,
                endDate: endDate,
                snapshot: snapshot,
                index: index
            )
        case .batchAndPens(let batchID, let penIDs):
            return batchIntervalIsContinuous(
                sheepID: sheepID,
                batchID: batchID,
                startDate: startDate,
                endDate: endDate,
                memberships: index.membershipsBySheep[sheepID] ?? []
            ) && penIntervalIsContinuous(
                sheepID: sheepID,
                penIDs: penIDs,
                startDate: startDate,
                endDate: endDate,
                snapshot: snapshot,
                index: index
            )
        case .unassigned:
            return !(index.membershipsBySheep[sheepID] ?? []).contains {
                $0.joinedAt <= endDate && ($0.leftAt.map { $0 >= startDate } ?? true)
            }
        case .pen(let penID):
            return penIntervalIsContinuous(
                sheepID: sheepID,
                penID: penID,
                startDate: startDate,
                endDate: endDate,
                snapshot: snapshot,
                index: index
            )
        case .pens(let penIDs):
            return penIntervalIsContinuous(
                sheepID: sheepID,
                penIDs: penIDs,
                startDate: startDate,
                endDate: endDate,
                snapshot: snapshot,
                index: index
            )
        }
    }

    private static func batchIntervalIsContinuous(
        sheepID: UUID,
        batchID: UUID,
        startDate: Date,
        endDate: Date,
        memberships: [FarmAnalyticsSnapshot.BatchMembership]
    ) -> Bool {
        let overlapping = memberships.filter {
            $0.sheepID == sheepID && $0.joinedAt <= endDate && ($0.leftAt.map { $0 >= startDate } ?? true)
        }
        return overlapping.count == 1 && overlapping.contains {
            $0.batchID == batchID && $0.joinedAt <= startDate && ($0.leftAt.map { $0 >= endDate } ?? true)
        }
    }

    private static func penIntervalIsContinuous(
        sheepID: UUID,
        penID: UUID,
        startDate: Date,
        endDate: Date,
        snapshot: FarmAnalyticsSnapshot,
        index: PreparedIndex? = nil
    ) -> Bool {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        guard let sheep = index.sheepByID[sheepID],
              index.penID(for: sheep, at: startDate) == penID,
              index.penID(for: sheep, at: endDate) == penID else { return false }
        return !(index.transfersBySheep[sheepID] ?? []).contains {
            $0.occurredAt > startDate && $0.occurredAt <= endDate && $0.toPenID != penID
        }
    }

    private static func penIntervalIsContinuous(
        sheepID: UUID,
        penIDs: Set<UUID>,
        startDate: Date,
        endDate: Date,
        snapshot: FarmAnalyticsSnapshot,
        index: PreparedIndex? = nil
    ) -> Bool {
        let index = index ?? PreparedIndex(snapshot: snapshot)
        guard !penIDs.isEmpty,
              let sheep = index.sheepByID[sheepID],
              let startPen = index.penID(for: sheep, at: startDate),
              let endPen = index.penID(for: sheep, at: endDate),
              penIDs.contains(startPen), penIDs.contains(endPen) else { return false }
        return !(index.transfersBySheep[sheepID] ?? []).contains {
            $0.occurredAt > startDate && $0.occurredAt <= endDate &&
                ($0.toPenID.map { !penIDs.contains($0) } ?? true)
        }
    }

    private static func penWasRelevant(
        sheep: FarmAnalyticsSnapshot.Sheep,
        penID: UUID,
        startDate: Date,
        endDate: Date,
        transfers: [FarmAnalyticsSnapshot.Transfer],
        index: PreparedIndex? = nil
    ) -> Bool {
        if let index {
            if index.penID(for: sheep, at: startDate) == penID ||
                index.penID(for: sheep, at: endDate) == penID {
                return true
            }
        } else if pen(at: startDate, sheep: sheep, transfers: transfers) == penID ||
                    pen(at: endDate, sheep: sheep, transfers: transfers) == penID {
            return true
        }
        let relevantTransfers = index?.transfersBySheep[sheep.id] ?? transfers.filter { $0.sheepID == sheep.id }
        return relevantTransfers.contains {
            $0.toPenID == penID &&
                $0.occurredAt >= startDate && $0.occurredAt <= endDate
        }
    }

    private static func penWasRelevant(
        sheep: FarmAnalyticsSnapshot.Sheep,
        penIDs: Set<UUID>,
        startDate: Date,
        endDate: Date,
        transfers: [FarmAnalyticsSnapshot.Transfer],
        index: PreparedIndex? = nil
    ) -> Bool {
        guard !penIDs.isEmpty else { return false }
        if let index {
            if let startPen = index.penID(for: sheep, at: startDate), penIDs.contains(startPen) { return true }
            if let endPen = index.penID(for: sheep, at: endDate), penIDs.contains(endPen) { return true }
        } else {
            if let startPen = pen(at: startDate, sheep: sheep, transfers: transfers), penIDs.contains(startPen) { return true }
            if let endPen = pen(at: endDate, sheep: sheep, transfers: transfers), penIDs.contains(endPen) { return true }
        }
        let relevantTransfers = index?.transfersBySheep[sheep.id] ?? transfers.filter { $0.sheepID == sheep.id }
        return relevantTransfers.contains {
            $0.toPenID.map(penIDs.contains) == true &&
                $0.occurredAt >= startDate && $0.occurredAt <= endDate
        }
    }

    static func cohort(snapshot: FarmAnalyticsSnapshot, sheepIDs: Set<UUID>? = nil, snapshotDate: Date? = nil, scope: WeightSampleScope = .all) -> WeightCohort {
        let limit = snapshotDate ?? Date.distantFuture
        let removed = Set(snapshot.removals.filter { $0.occurredAt <= limit }.map(\.sheepID))
        let eligible = snapshot.sheep.filter { sheep in
            guard sheepIDs.map({ $0.contains(sheep.id) }) ?? true else { return false }
            switch scope { case .all: return true; case .inHerdOnly: return !removed.contains(sheep.id); case .removedOnly: return removed.contains(sheep.id) }
        }.map(\.id)
        let pointMap = timelines(snapshot: snapshot, sheepIDs: Set(eligible), limit: limit)
        return cohort(eligible: eligible, pointMap: pointMap)
    }

    private static func cohort(eligible: [UUID], pointMap: [UUID: [Point]]) -> WeightCohort {
        var weightsByDate: [Date: [Double]] = [:]; var adgByDate: [Date: [Double]] = [:]; var latestWeights: [Double] = []; var latestADGs: [Double] = []; var scatter: [WeightScatterPoint] = []
        for (sheepID, points) in pointMap {
            guard let latest = points.last else { continue }
            latestWeights.append(latest.weight)
            for point in points { weightsByDate[point.date, default: []].append(point.weight) }
            for (previous, current) in zip(points, points.dropFirst()) {
                let days = FarmAnalyticsDate.days(from: previous.date, to: current.date)
                guard days > 0 else { continue }
                let adg = (current.weight - previous.weight) / Double(days)
                adgByDate[current.date, default: []].append(adg); scatter.append(WeightScatterPoint(sheepID: sheepID, date: current.date, baselineWeight: previous.weight, adg: adg))
            }
            if let first = points.first { let days = FarmAnalyticsDate.days(from: first.date, to: latest.date); if days > 0 { latestADGs.append((latest.weight - first.weight) / Double(days)) } }
        }
        func trend(_ values: [Date: [Double]]) -> [WeightTrendPoint] { values.compactMap { date, items in items.isEmpty ? nil : WeightTrendPoint(date: date, value: items.reduce(0, +) / Double(items.count)) }.sorted { $0.date < $1.date } }
        return WeightCohort(sheepIDs: eligible.sorted { $0.uuidString < $1.uuidString }, latestAverageWeight: latestWeights.isEmpty ? nil : latestWeights.reduce(0, +) / Double(latestWeights.count), latestAverageADG: latestADGs.isEmpty ? nil : latestADGs.reduce(0, +) / Double(latestADGs.count), weightTrend: trend(weightsByDate), adgTrend: trend(adgByDate), scatter: scatter)
    }

    static func cohort(snapshot: FarmAnalyticsSnapshot, penID: UUID, snapshotDate: Date, scope: WeightSampleScope = .all) -> WeightCohort {
        let candidates = Set(snapshot.sheep.filter { pen(at: snapshotDate, sheep: $0, transfers: snapshot.transfers) == penID }.map(\.id))
        return cohort(snapshot: snapshot, sheepIDs: candidates, snapshotDate: snapshotDate, scope: scope)
    }

    static func cohort(snapshot: FarmAnalyticsSnapshot, batchID: UUID, snapshotDate: Date, scope: WeightSampleScope = .all) -> WeightCohort {
        let memberships = snapshot.batchMemberships.filter { $0.batchID == batchID && $0.joinedAt <= snapshotDate }
        let membershipBySheep = Dictionary(grouping: memberships, by: \.sheepID)
        let removed = Set(snapshot.removals.filter { $0.occurredAt <= snapshotDate }.map(\.sheepID))
        let eligible = snapshot.sheep.compactMap { sheep -> UUID? in
            guard membershipBySheep[sheep.id] != nil else { return nil }
            switch scope {
            case .all: return sheep.id
            case .inHerdOnly: return removed.contains(sheep.id) ? nil : sheep.id
            case .removedOnly: return removed.contains(sheep.id) ? sheep.id : nil
            }
        }
        let pointMap = timelines(snapshot: snapshot, sheepIDs: Set(eligible), limit: snapshotDate) { sheepID, occurredAt in
            membershipBySheep[sheepID]?.contains(where: { $0.contains(eventAt: occurredAt) }) == true
        }
        return cohort(eligible: eligible, pointMap: pointMap)
    }

    static func trendline(for points: [WeightScatterPoint], kind: WeightRegressionKind) -> [WeightRegressionPoint] {
        guard points.count >= kind.minimumPointCount else { return [] }
        let sorted = points.sorted { $0.baselineWeight < $1.baselineWeight }
        guard let minimumX = sorted.first?.baselineWeight,
              let maximumX = sorted.last?.baselineWeight,
              maximumX > minimumX else { return [] }
        return stride(from: 0, through: 24, by: 1).compactMap { step in
            let x = minimumX + (maximumX - minimumX) * (Double(step) / 24)
            guard let y = trendlineY(for: x, points: sorted, kind: kind), y.isFinite else { return nil }
            return WeightRegressionPoint(x: x, y: y)
        }
    }

    private static func trendlineY(for x: Double, points: [WeightScatterPoint], kind: WeightRegressionKind) -> Double? {
        switch kind {
        case .none:
            nil
        case .linear:
            linearRegression(points: points).map { $0.slope * x + $0.intercept }
        case .logarithmic:
            logarithmicRegression(points: points).map { $0.slope * log(x) + $0.intercept }
        case .exponential:
            exponentialRegression(points: points).map { $0.a * exp($0.b * x) }
        case .quadratic, .cubic, .quartic, .quintic, .sextic:
            polynomialRegression(points: points, degree: kind.polynomialDegree).map { coefficients in
                coefficients.enumerated().reduce(0) { $0 + $1.element * pow(x, Double($1.offset)) }
            }
        }
    }

    private static func linearRegression(points: [WeightScatterPoint]) -> (slope: Double, intercept: Double)? {
        linearRegression(samples: points.map { ($0.baselineWeight, $0.adg) })
    }

    private static func logarithmicRegression(points: [WeightScatterPoint]) -> (slope: Double, intercept: Double)? {
        linearRegression(samples: points.compactMap { $0.baselineWeight > 0 ? (log($0.baselineWeight), $0.adg) : nil })
    }

    private static func exponentialRegression(points: [WeightScatterPoint]) -> (a: Double, b: Double)? {
        guard let model = linearRegression(samples: points.compactMap { $0.adg > 0 ? ($0.baselineWeight, log($0.adg)) : nil }) else { return nil }
        return (exp(model.intercept), model.slope)
    }

    private static func linearRegression(samples: [(Double, Double)]) -> (slope: Double, intercept: Double)? {
        let count = Double(samples.count)
        guard count >= 2 else { return nil }
        let sumX = samples.reduce(0) { $0 + $1.0 }
        let sumY = samples.reduce(0) { $0 + $1.1 }
        let sumXY = samples.reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = samples.reduce(0) { $0 + $1.0 * $1.0 }
        let denominator = count * sumXX - sumX * sumX
        guard abs(denominator) > 0.000001 else { return nil }
        let slope = (count * sumXY - sumX * sumY) / denominator
        return (slope, (sumY - slope * sumX) / count)
    }

    private static func polynomialRegression(points: [WeightScatterPoint], degree: Int) -> [Double]? {
        guard degree >= 2, points.count >= degree + 1 else { return nil }
        let order = degree + 1
        var matrix = Array(repeating: Array(repeating: 0.0, count: order + 1), count: order)
        for row in 0..<order {
            for column in 0..<order {
                matrix[row][column] = points.reduce(0) { $0 + pow($1.baselineWeight, Double(row + column)) }
            }
            matrix[row][order] = points.reduce(0) { $0 + $1.adg * pow($1.baselineWeight, Double(row)) }
        }
        return solveLinearSystem(matrix)
    }

    private static func solveLinearSystem(_ matrix: [[Double]]) -> [Double]? {
        guard !matrix.isEmpty else { return nil }
        var values = matrix
        let rowCount = values.count
        let columnCount = values[0].count
        guard values.allSatisfy({ $0.count == columnCount }), columnCount == rowCount + 1 else { return nil }
        for pivot in 0..<rowCount {
            var bestRow = pivot
            for row in pivot..<rowCount where abs(values[row][pivot]) > abs(values[bestRow][pivot]) { bestRow = row }
            guard abs(values[bestRow][pivot]) > 0.000001 else { return nil }
            if bestRow != pivot { values.swapAt(bestRow, pivot) }
            let pivotValue = values[pivot][pivot]
            for column in pivot..<columnCount { values[pivot][column] /= pivotValue }
            for row in 0..<rowCount where row != pivot {
                let factor = values[row][pivot]
                for column in pivot..<columnCount { values[row][column] -= factor * values[pivot][column] }
            }
        }
        return (0..<rowCount).map { values[$0][columnCount - 1] }
    }

    private struct Point { let date: Date; let weight: Double }
    private static func timelines(
        snapshot: FarmAnalyticsSnapshot,
        sheepIDs: Set<UUID>,
        limit: Date,
        includes: (UUID, Date) -> Bool = { _, _ in true }
    ) -> [UUID: [Point]] {
        let samples = SheepWeightSampleBuilder.dailyCanonical(snapshot.weightSamples.filter {
            sheepIDs.contains($0.sheepID) && $0.occurredAt <= limit && includes($0.sheepID, $0.occurredAt)
        })
        var raw: [UUID: [Point]] = [:]
        for sample in samples {
            raw[sample.sheepID, default: []].append(Point(
                date: FarmAnalyticsDate.day(sample.occurredAt),
                weight: sample.kilograms
            ))
        }
        return raw.mapValues { $0.sorted { $0.date < $1.date } }
    }
    private static func transferSort(_ lhs: FarmAnalyticsSnapshot.Transfer, _ rhs: FarmAnalyticsSnapshot.Transfer) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func pen(at date: Date, sheep: FarmAnalyticsSnapshot.Sheep, transfers: [FarmAnalyticsSnapshot.Transfer]) -> UUID? {
        let last = transfers.filter { $0.sheepID == sheep.id && $0.occurredAt <= date }.sorted(by: transferSort).last
        if let last { return last.toPenID }
        return sheep.initialPenID
    }
}

struct FarmInsight: Sendable, Equatable { let title: String; let summary: String; let details: [String] }

enum SheepAnalyticsEngine {
    static func lifecycle(sheepID: UUID, snapshot: FarmAnalyticsSnapshot, referenceDate: Date = .now) -> FarmInsight {
        guard let sheep = snapshot.sheep.first(where: { $0.id == sheepID }) else { return FarmInsight(title: "未找到", summary: "羊只不存在", details: []) }
        let points = WeightGainAnalyticsEngine.cohort(snapshot: snapshot, sheepIDs: [sheepID], snapshotDate: referenceDate).weightTrend
        let lambings = snapshot.lambings.filter { $0.eweID == sheepID }.sorted { $0.occurredAt > $1.occurredAt }
        var details = ["【基本信息】\(sheep.breed) \(sheep.sex.displayName) \(sheep.purpose)"]
        if let latest = points.last { details.append("【最新体重】\(String(format: "%.1f", latest.value))kg") }
        if let birth = sheep.birthAt { details.append("【日龄】\(FarmAnalyticsDate.days(from: birth, to: referenceDate))天") }
        if !lambings.isEmpty { details.append("【产羔历史】共\(lambings.count)胎 \(lambings.reduce(0) { $0 + $1.total })只") }
        return FarmInsight(title: "羊只全生命周期", summary: "\(sheep.earTag) \(sheep.breed)", details: details)
    }

    static func penHerd(penID: UUID, snapshot: FarmAnalyticsSnapshot, referenceDate: Date = .now) -> FarmInsight {
        let current = snapshot.sheep.filter { $0.status == .active && $0.currentPenID == penID }
        let name = snapshot.pens.first(where: { $0.id == penID })?.name ?? "圈舍"
        let purposeRows = Dictionary(grouping: current, by: \.purpose).sorted { $0.value.count > $1.value.count }.map { "\($0.key)：\($0.value.count)只" }
        let cohort = WeightGainAnalyticsEngine.cohort(snapshot: snapshot, penID: penID, snapshotDate: referenceDate)
        var details = ["在群 \(current.count) 只"] + purposeRows
        if let weight = cohort.latestAverageWeight { details.append("平均体重：\(String(format: "%.1f", weight))kg") }
        return FarmInsight(title: "圈舍分析", summary: "\(name) 在群\(current.count)只", details: details)
    }

    static func reproduction(sheepID: UUID, snapshot: FarmAnalyticsSnapshot) -> FarmInsight {
        guard let sheep = snapshot.sheep.first(where: { $0.id == sheepID }) else { return FarmInsight(title: "未找到", summary: "羊只不存在", details: []) }
        let lambings = snapshot.lambings.filter { $0.eweID == sheepID }.sorted { $0.occurredAt < $1.occurredAt }
        var details = lambings.map { "\(FarmAnalyticsDate.month($0.occurredAt)) 第\($0.parity.map(String.init) ?? "?")胎 \($0.total)只" }
        if lambings.count >= 2 { details.append(contentsOf: zip(lambings, lambings.dropFirst()).map { "胎间距：\(FarmAnalyticsDate.days(from: $0.occurredAt, to: $1.occurredAt))天" }) }
        return FarmInsight(title: "繁殖推演", summary: "\(sheep.earTag) 共\(lambings.count)胎", details: details)
    }

    static func herdSummary(snapshot: FarmAnalyticsSnapshot) -> FarmInsight {
        let active = snapshot.sheep.filter { $0.status == .active }
        let breeds = Dictionary(grouping: active, by: \.breed).sorted { $0.value.count > $1.value.count }.map { "\($0.key)：\($0.value.count)只" }
        return FarmInsight(title: "全场群体统计", summary: "在群 \(active.count) 只，\(Set(active.map(\.breed)).count) 个品种，\(Set(active.compactMap(\.currentPenID)).count) 个圈舍", details: breeds)
    }
}

@MainActor
@Observable
final class FarmAnalyticsViewModel {
    private(set) var snapshot: FarmAnalyticsSnapshot?
    private(set) var weightCohort: WeightCohort?
    private(set) var lambResult: FarmLambAnalyticsResult?
    private(set) var reproductionResult: FarmReproductionAnalyticsResult?
    private(set) var isCalculating = false

    private var weightRevision = UUID()
    private var lambRevision = UUID()
    private var reproductionRevision = UUID()

    func replaceSnapshot(_ snapshot: FarmAnalyticsSnapshot) {
        self.snapshot = snapshot
        weightCohort = nil
        lambResult = nil
        reproductionResult = nil
    }

    func calculateWeight(sheepIDs: Set<UUID>? = nil, penID: UUID? = nil, batchID: UUID? = nil, snapshotDate: Date, scope: WeightSampleScope) {
        guard let snapshot else { return }
        let revision = UUID()
        weightRevision = revision
        isCalculating = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                if let batchID { return WeightGainAnalyticsEngine.cohort(snapshot: snapshot, batchID: batchID, snapshotDate: snapshotDate, scope: scope) }
                if let penID { return WeightGainAnalyticsEngine.cohort(snapshot: snapshot, penID: penID, snapshotDate: snapshotDate, scope: scope) }
                return WeightGainAnalyticsEngine.cohort(snapshot: snapshot, sheepIDs: sheepIDs, snapshotDate: snapshotDate, scope: scope)
            }.value
            guard let self, self.weightRevision == revision else { return }
            self.weightCohort = result
            self.isCalculating = false
        }
    }

    func calculateLambs(selectedYear: String?, selectedWeaningMonth: String) {
        guard let snapshot else { return }
        let revision = UUID()
        lambRevision = revision
        isCalculating = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                LambAnalyticsEngine.calculate(snapshot: snapshot, selectedYear: selectedYear, selectedWeaningMonth: selectedWeaningMonth)
            }.value
            guard let self, self.lambRevision == revision else { return }
            self.lambResult = result
            self.isCalculating = false
        }
    }

    func calculateReproduction(filter: ReproductionAnalyticsFilter) {
        guard let snapshot else { return }
        let revision = UUID()
        reproductionRevision = revision
        isCalculating = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ReproductionAnalyticsEngine.calculate(snapshot: snapshot, filter: filter)
            }.value
            guard let self, self.reproductionRevision == revision else { return }
            self.reproductionResult = result
            self.isCalculating = false
        }
    }
}
