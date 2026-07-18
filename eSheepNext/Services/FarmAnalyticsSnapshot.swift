import Foundation
import Observation

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
    }

    struct Pen: Sendable, Hashable { let id: UUID; let name: String }
    struct Weight: Sendable, Hashable { let id: UUID; let sheepID: UUID; let kilograms: Double; let occurredAt: Date }
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
    struct Offspring: Sendable, Hashable { let id: UUID; let sheepID: UUID?; let earTag: String; let sex: LambSex?; let birthWeight: Double? }
    struct Removal: Sendable, Hashable { let sheepID: UUID; let kind: RemovalKind; let occurredAt: Date }
    struct Transfer: Sendable, Hashable { let id: UUID; let sheepID: UUID; let toPenID: UUID?; let occurredAt: Date; let recordedAt: Date }
    struct BatchMembership: Sendable, Hashable { let batchID: UUID; let sheepID: UUID; let joinedAt: Date; let leftAt: Date? }
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
        feedLines: [FeedRecordLine]
    ) -> Self {
        let farmSheep = sheep.filter { $0.farmID == farmID && $0.deletedAt == nil }.map {
            Sheep(id: $0.id, earTag: $0.earTag, breed: $0.breed, purpose: $0.purpose, sex: $0.sex, status: $0.status, initialPenID: $0.initialPenID, currentPenID: $0.currentPenID, birthAt: $0.birthAt, enteredAt: $0.enteredAt, removedAt: $0.removedAt)
        }
        let offspringByLambing = Dictionary(grouping: offspring.filter { $0.farmID == farmID }, by: \.lambingRecordID)
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
            pens: pens.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Pen(id: $0.id, name: $0.name) },
            weights: weights.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Weight(id: $0.id, sheepID: $0.sheepID, kilograms: NSDecimalNumber(decimal: $0.kilograms).doubleValue, occurredAt: $0.occurredAt) },
            weanings: weanings.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Weaning(id: $0.id, sheepID: $0.sheepID, occurredAt: $0.occurredAt, weanWeight: NSDecimalNumber(decimal: $0.weanWeight).doubleValue, birthAt: $0.birthAt, birthWeight: $0.birthWeightText.flatMap(Decimal.stable).map { NSDecimalNumber(decimal: $0).doubleValue }, damID: $0.damID, litterSize: $0.litterSize) },
            lambings: lambings,
            removals: removals.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Removal(sheepID: $0.sheepID, kind: $0.kind, occurredAt: $0.occurredAt) },
            transfers: transfers.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { Transfer(id: $0.id, sheepID: $0.sheepID, toPenID: $0.toPenID, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt) },
            batchMemberships: memberships.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { BatchMembership(batchID: $0.batchID, sheepID: $0.sheepID, joinedAt: $0.joinedAt, leftAt: $0.leftAt) },
            feeds: feedLines.filter { $0.farmID == farmID }.compactMap { line in
                guard let feed = feedByID[line.feedRecordID] else { return nil }
                return Feed(penID: feed.penID, ingredientName: line.ingredientNameSnapshot, kilograms: NSDecimalNumber(decimal: line.kilograms).doubleValue, mode: feed.mode, occurredAt: feed.occurredAt)
            }
        )
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
        let completeLambings = snapshot.lambings.filter { $0.hasCompleteAnalyticsData && (selectedYear == nil || FarmAnalyticsDate.year($0.occurredAt) == selectedYear) }
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
                guard let weight = child.birthWeight, weight > 0 else { continue }
                if child.sex == .male { stats.maleLambs += 1; stats.maleWeightCount += 1; stats.maleWeightAverage += weight }
                else if child.sex == .female { stats.femaleLambs += 1; stats.femaleWeightCount += 1; stats.femaleWeightAverage += weight }
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
            for tag in tagsByMonth[month] ?? [] { if let counts = removalsByTag[tag] { stats.disappeared += counts.disappeared; stats.culled += counts.culled; stats.sold += counts.sold } }
            stats.inHerd = (tagsByMonth[month] ?? []).intersection(activeTags).count
            months[month] = stats
        }
        let sortedMonths = months.values.sorted { $0.month > $1.month }
        let totalLambs = sortedMonths.reduce(0) { $0 + $1.totalLambs }
        let totalDead = sortedMonths.reduce(0) { $0 + $1.birthDead }
        let totalCull = sortedMonths.reduce(0) { $0 + $1.culled + $1.disappeared }
        let weaning = calculateWeaning(snapshot: snapshot, sheepByID: sheepByID, selectedYear: selectedYear, selectedMonth: selectedWeaningMonth)
        return FarmLambAnalyticsResult(lambStats: LambStats(months: sortedMonths, totalLambs: totalLambs, mortalityRate: totalLambs > 0 ? Double(totalDead) / Double(totalLambs) : 0, deathCullRate: totalLambs > totalDead ? Double(totalCull) / Double(totalLambs - totalDead) : 0), weaning: weaning, incompleteLambingCount: snapshot.lambings.count - completeLambings.count)
    }

    private static func calculateWeaning(snapshot: FarmAnalyticsSnapshot, sheepByID: [UUID: FarmAnalyticsSnapshot.Sheep], selectedYear: String?, selectedMonth: String) -> LambWeaningAnalysis {
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
            let ageDays = record.birthAt.map { FarmAnalyticsDate.days(from: $0, to: record.occurredAt) } ?? 0
            let validAge = ageDays > 0
            if validAge { stats.ageCount += 1; stats.ageDays += ageDays; if sex == .male { stats.maleAgeCount += 1; stats.maleAgeDays += ageDays }; if sex == .female { stats.femaleAgeCount += 1; stats.femaleAgeDays += ageDays } }
            let validBirthWeight = record.birthWeight.map { $0 > 0 && $0 < record.weanWeight } ?? false
            if validAge && validWeight, let birthWeight = record.birthWeight, validBirthWeight {
                let adg = (record.weanWeight - birthWeight) / Double(ageDays) * 1000
                stats.adgCount += 1; stats.adgSum += adg
                if sex == .male { stats.maleADGCount += 1; stats.maleADGSum += adg }
                if sex == .female { stats.femaleADGCount += 1; stats.femaleADGSum += adg }
            }
            if sex == nil || !validWeight || !validAge || !validBirthWeight { stats.abnormalCount += 1 }
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
struct FarmReproductionAnalyticsResult: Sendable { let overview: ReproductionOverview; let monthly: [ReproductionMonth]; let maleCount: Int; let femaleCount: Int; let intervalPoints: [ReproductionHistoryPoint]; let postpartumPoints: [ReproductionHistoryPoint]; let qualifiedRates: [ReproductionQualifiedRate]; let breedRows: [BreedPerformance]; let incompleteLambingCount: Int }

enum ReproductionAnalyticsEngine {
    static func calculate(snapshot: FarmAnalyticsSnapshot, selectedYear: String?, referenceDate: Date = .now) -> FarmReproductionAnalyticsResult {
        let allComplete = snapshot.lambings.filter(\.hasCompleteAnalyticsData)
        let records = allComplete.filter { selectedYear == nil || FarmAnalyticsDate.year($0.occurredAt) == selectedYear }
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
        let byDam = Dictionary(grouping: allComplete, by: \.eweID).mapValues { $0.map(\.occurredAt).sorted() }
        let intervals = byDam.mapValues { dates in zip(dates, dates.dropFirst()).compactMap { first, second in let days = FarmAnalyticsDate.days(from: first, to: second); return days > 0 && days < 1000 ? (second, days) : nil } }
        let breedingEwes = snapshot.sheep.filter { $0.sex == .ewe && ["后备母羊", "繁殖母羊"].contains($0.purpose) }
        let removalByID = Dictionary(grouping: snapshot.removals, by: \.sheepID).compactMapValues { $0.map(\.occurredAt).min() }
        let earliest = allComplete.map(\.occurredAt).min()
        let historyDates = makeHistoryDates(from: earliest, to: referenceDate, selectedYear: selectedYear)
        let intervalPoints = historyDates.compactMap { date -> ReproductionHistoryPoint? in
            let values = breedingEwes.compactMap { ewe -> Int? in
                guard ewe.birthAt.map({ $0 <= date }) ?? true, removalByID[ewe.id].map({ $0 > date }) ?? true else { return nil }
                return latestInterval(for: ewe.id, on: date, intervals: intervals)
            }
            guard !values.isEmpty else { return nil }
            return ReproductionHistoryPoint(date: date, average: Double(values.reduce(0, +)) / Double(values.count), count: values.count)
        }
        let postpartumPoints = historyDates.compactMap { date -> ReproductionHistoryPoint? in
            let values = breedingEwes.compactMap { ewe -> Int? in
                guard ewe.birthAt.map({ $0 <= date }) ?? true, removalByID[ewe.id].map({ $0 > date }) ?? true, let birth = byDam[ewe.id]?.last(where: { $0 <= date }) else { return nil }
                let days = FarmAnalyticsDate.days(from: birth, to: date)
                return (0..<1000).contains(days) ? days : nil
            }
            guard !values.isEmpty else { return nil }
            return ReproductionHistoryPoint(date: date, average: Double(values.reduce(0, +)) / Double(values.count), count: values.count)
        }
        let qualifiedRates = qualifiedRates(from: intervalPoints, breedingEwes: breedingEwes, removals: removalByID, intervals: intervals)
        let sheepByBreed = Dictionary(grouping: snapshot.sheep.filter { !$0.breed.isEmpty && $0.breed.lowercased() != "nan" }, by: \.breed)
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
        return FarmReproductionAnalyticsResult(overview: overview, monthly: monthly, maleCount: male, femaleCount: female, intervalPoints: intervalPoints, postpartumPoints: postpartumPoints, qualifiedRates: qualifiedRates, breedRows: breedRows, incompleteLambingCount: snapshot.lambings.count - allComplete.count)
    }

    private static func makeHistoryDates(from start: Date?, to end: Date, selectedYear: String?) -> [Date] {
        guard let start else { return [] }
        let days = FarmAnalyticsDate.days(from: start, to: end)
        let step = days > 500 ? max(1, days / 300) : 1
        var dates: [Date] = []; var date = FarmAnalyticsDate.day(start)
        while date <= end { if selectedYear == nil || FarmAnalyticsDate.year(date) == selectedYear { dates.append(date) }; guard let next = FarmAnalyticsDate.calendar.date(byAdding: .day, value: step, to: date) else { break }; date = next }
        return dates
    }

    private static func latestInterval(for eweID: UUID, on date: Date, intervals: [UUID: [(Date, Int)]]) -> Int? { intervals[eweID]?.last(where: { $0.0 <= date })?.1 }

    private static func qualifiedRates(from points: [ReproductionHistoryPoint], breedingEwes: [FarmAnalyticsSnapshot.Sheep], removals: [UUID: Date], intervals: [UUID: [(Date, Int)]]) -> [ReproductionQualifiedRate] {
        let monthlyPoints = Dictionary(grouping: points, by: { FarmAnalyticsDate.month($0.date) }).compactMapValues { $0.min { abs(FarmAnalyticsDate.calendar.component(.day, from: $0.date) - 15) < abs(FarmAnalyticsDate.calendar.component(.day, from: $1.date) - 15) } }
        return monthlyPoints.keys.sorted().compactMap { month in
            guard let point = monthlyPoints[month] else { return nil }
            var qualified = 0; var unqualified = 0
            for ewe in breedingEwes where ewe.birthAt.map({ $0 <= point.date }) ?? true {
                guard removals[ewe.id].map({ $0 > point.date }) ?? true, let days = latestInterval(for: ewe.id, on: point.date, intervals: intervals) else { continue }
                if (150...240).contains(days) { qualified += 1 } else { unqualified += 1 }
            }
            let total = qualified + unqualified
            return total > 0 ? ReproductionQualifiedRate(month: month, qualified: Double(qualified) * 100 / Double(total), unqualified: Double(unqualified) * 100 / Double(total)) : nil
        }
    }
}

enum WeightSampleScope: String, CaseIterable, Sendable { case all; case inHerdOnly; case removedOnly }
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

enum WeightGainAnalyticsEngine {
    static func cohort(snapshot: FarmAnalyticsSnapshot, sheepIDs: Set<UUID>? = nil, snapshotDate: Date? = nil, scope: WeightSampleScope = .all) -> WeightCohort {
        let limit = snapshotDate ?? Date.distantFuture
        let removed = Set(snapshot.removals.filter { $0.occurredAt <= limit }.map(\.sheepID))
        let eligible = snapshot.sheep.filter { sheep in
            guard sheepIDs.map({ $0.contains(sheep.id) }) ?? true else { return false }
            switch scope { case .all: return true; case .inHerdOnly: return !removed.contains(sheep.id); case .removedOnly: return removed.contains(sheep.id) }
        }.map(\.id)
        let pointMap = timelines(snapshot: snapshot, sheepIDs: Set(eligible), limit: limit)
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
        let candidates = Set(snapshot.batchMemberships.filter { $0.batchID == batchID && $0.joinedAt <= snapshotDate && ($0.leftAt.map { $0 >= snapshotDate } ?? true) }.map(\.sheepID))
        return cohort(snapshot: snapshot, sheepIDs: candidates, snapshotDate: snapshotDate, scope: scope)
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

    private struct Point { let date: Date; let weight: Double; let source: Int }
    private static func timelines(snapshot: FarmAnalyticsSnapshot, sheepIDs: Set<UUID>, limit: Date) -> [UUID: [Point]] {
        var raw: [UUID: [Point]] = [:]
        for weight in snapshot.weights where sheepIDs.contains(weight.sheepID) && weight.occurredAt <= limit { raw[weight.sheepID, default: []].append(Point(date: FarmAnalyticsDate.day(weight.occurredAt), weight: weight.kilograms, source: 0)) }
        for weaning in snapshot.weanings where sheepIDs.contains(weaning.sheepID) && weaning.occurredAt <= limit { raw[weaning.sheepID, default: []].append(Point(date: FarmAnalyticsDate.day(weaning.occurredAt), weight: weaning.weanWeight, source: 1)) }
        return raw.mapValues { points in Dictionary(grouping: points, by: \.date).compactMap { date, sameDay in sameDay.sorted { $0.source < $1.source }.first.map { Point(date: date, weight: $0.weight, source: $0.source) } }.sorted { $0.date < $1.date } }
    }
    private static func pen(at date: Date, sheep: FarmAnalyticsSnapshot.Sheep, transfers: [FarmAnalyticsSnapshot.Transfer]) -> UUID? {
        let last = transfers.filter { $0.sheepID == sheep.id && $0.occurredAt <= date }.sorted { $0.occurredAt == $1.occurredAt ? $0.recordedAt < $1.recordedAt : $0.occurredAt < $1.occurredAt }.last
        return last?.toPenID ?? sheep.initialPenID
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

    func calculateReproduction(selectedYear: String?) {
        guard let snapshot else { return }
        let revision = UUID()
        reproductionRevision = revision
        isCalculating = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ReproductionAnalyticsEngine.calculate(snapshot: snapshot, selectedYear: selectedYear)
            }.value
            guard let self, self.reproductionRevision == revision else { return }
            self.reproductionResult = result
            self.isCalculating = false
        }
    }
}
