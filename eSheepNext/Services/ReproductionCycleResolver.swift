import Foundation

/// Review scope only: this never manufactures a zero-parity fact for a lamb.
enum ReproductionReviewPolicy {
    static func isPreBreedingLamb(
        purpose: String, birthAt: Date?, removedAt: Date?, hasReproductionFacts: Bool,
        asOf: Date, timeZoneIdentifier: String, minimumAgeMonths: Int = 10
    ) -> Bool {
        let classification = SheepPurpose.classify(storedValue: purpose)
        guard classification == .sucklingLamb || classification == .weanedLamb,
              !hasReproductionFacts, let birthAt,
              let timeZone = TimeZone(identifier: timeZoneIdentifier), minimumAgeMonths > 0 else { return false }
        // A deceased/removed lamb must not become an adult review item as time passes.
        let observation = removedAt.map { min($0, asOf) } ?? asOf
        guard birthAt <= observation else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let maturity = calendar.date(byAdding: .month, value: minimumAgeMonths,
                                           to: calendar.startOfDay(for: birthAt)) else { return false }
        return calendar.startOfDay(for: observation) <= maturity
    }
}

enum BreedingIntent: String, Codable, CaseIterable, Sendable, Identifiable {
    case newRound, supplement
    var id: String { rawValue }
    var title: String { self == .newRound ? "新一轮配种" : "本轮补配" }
}

struct ReproductionFactAssociation: Sendable, Hashable {
    let recordID: UUID
    let cycleID: UUID?
    let roundID: UUID?
    let inferred: Bool
    let reason: String
}

struct ReproductionCycleHistory: Identifiable, Sendable, Hashable {
    let id: UUID
    let endedAt: Date
    let outcome: ReproductionRecordKind
    let targetParity: Int?
    let recordIDs: [UUID]
}

/// A projection of dated facts. Reading this value never writes associations.
struct ReproductionStateSnapshot: Sendable, Hashable {
    let eweID: UUID
    let asOf: Date
    let cycleID: UUID
    let completedParity: Int?
    let targetParity: Int?
    let lastLambingAt: Date?
    let breedingRoundID: UUID?
    let breeding: FarmAnalyticsSnapshot.ReproductionFact?
    let check: FarmAnalyticsSnapshot.ReproductionFact?
    let pregnancy: ReproductionPregnancyState
    let issues: [String]
    let associations: [ReproductionFactAssociation]
    let history: [ReproductionCycleHistory]

    var displayState: String {
        pregnancy == .unexamined && breeding != nil ? "已配待检" : pregnancy.rawValue
    }
    var parityText: String { completedParity.map { "已完成产羔 \($0) 胎" } ?? "胎次待核实" }
    var targetParityText: String { targetParity.map { "本轮目标第 \($0) 胎" } ?? "本轮胎次待核实" }
    func association(for id: UUID) -> ReproductionFactAssociation? { associations.first { $0.recordID == id } }

    func expectedLambingAt(days: Int, calendar: Calendar) -> Date? {
        guard pregnancy == .pregnant, issues.isEmpty, let breeding else { return nil }
        return calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: breeding.occurredAt))
    }
}

enum ReproductionCycleResolver {
    typealias Fact = FarmAnalyticsSnapshot.ReproductionFact

    static func states(snapshot: FarmAnalyticsSnapshot) -> [UUID: ReproductionStateSnapshot] {
        var facts = snapshot.reproductionFacts
        var ids = Set(facts.map(\.id))
        for birth in snapshot.lambings where ids.insert(birth.id).inserted {
            facts.append(Fact(id: birth.id, eweID: birth.eweID, kind: .lambing, occurredAt: birth.occurredAt, parity: birth.parity))
        }
        var positions = Dictionary(uniqueKeysWithValues: facts.enumerated().map { ($0.element.id, $0.offset) })
        for evidence in snapshot.parityEvidence {
            if let index = positions[evidence.id] { facts[index].parity = evidence.parity }
            else {
                positions[evidence.id] = facts.count
                facts.append(Fact(id: evidence.id, eweID: evidence.eweID, kind: .parityBaseline, occurredAt: evidence.occurredAt, parity: evidence.parity))
            }
        }
        let groups = Dictionary(grouping: facts, by: \.eweID)
        return Dictionary(uniqueKeysWithValues: snapshot.sheep.filter { $0.sex == .ewe }.map {
            ($0.id, resolve(eweID: $0.id, facts: groups[$0.id] ?? [], asOf: snapshot.factsReadAt))
        })
    }

    static func facts(records: [ReproductionRecord]) -> [Fact] {
        records.filter { $0.deletedAt == nil }.map {
            Fact(id: $0.id, eweID: $0.eweID, kind: $0.kind, occurredAt: $0.occurredAt,
                 result: $0.result, relatedBreedingRecordID: $0.relatedBreedingRecordID,
                 revision: $0.revision, parity: $0.parity, reproductionCycleID: $0.reproductionCycleID,
                 breedingRoundID: $0.breedingRoundID, breedingIntentRawValue: $0.breedingIntentRawValue)
        }
    }

    static func resolve(eweID: UUID, snapshot: FarmAnalyticsSnapshot) -> ReproductionStateSnapshot {
        var facts = snapshot.reproductionFacts.filter { $0.eweID == eweID }
        var ids = Set(facts.map(\.id))
        for birth in snapshot.lambings where birth.eweID == eweID && ids.insert(birth.id).inserted {
            facts.append(Fact(id: birth.id, eweID: eweID, kind: .lambing, occurredAt: birth.occurredAt, parity: birth.parity))
        }
        for evidence in snapshot.parityEvidence where evidence.eweID == eweID {
            if let index = facts.firstIndex(where: { $0.id == evidence.id }) { facts[index].parity = evidence.parity }
            else { facts.append(Fact(id: evidence.id, eweID: eweID, kind: .parityBaseline, occurredAt: evidence.occurredAt, parity: evidence.parity)) }
        }
        return resolve(eweID: eweID, facts: facts, asOf: snapshot.factsReadAt)
    }

    static func resolve(eweID: UUID, facts input: [Fact], asOf: Date) -> ReproductionStateSnapshot {
        let facts = input.filter { $0.eweID == eweID && $0.occurredAt <= asOf }.sorted {
            $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt < $1.occurredAt
        }
        let closures = facts.filter { $0.kind == .lambing || $0.kind == .abortion }
        let boundary = closures.last
        let births = facts.filter { $0.kind == .lambing }
        let lastBirth = births.last
        let parityFacts = facts.filter { ($0.kind == .parityBaseline || $0.kind == .lambing) && ($0.parity ?? -1) >= 0 }
        let latestParity = parityFacts.last
        let parity = latestParity?.parity
        var issues: [String] = []
        if parity == nil { issues.append("缺少可确认的胎次，不能判定为未产羔") }
        if let latestParity, parityFacts.contains(where: { $0.occurredAt == latestParity.occurredAt && $0.parity != latestParity.parity }) {
            issues.append("同一时间的胎次事实冲突")
        }
        let missingBirth = (parity ?? 0) > 0 && (lastBirth == nil || (latestParity?.parity ?? 0) > (lastBirth?.parity ?? 0))
        if missingBirth { issues.append("已产羔，缺少对应的最近产羔日期") }
        if let parity, let birthParity = lastBirth?.parity, parity < birthParity || parity == 0 && lastBirth != nil {
            issues.append("胎次确认与产羔记录冲突")
        }
        // Keep the boundary timestamp visible for review; IDs never establish temporal order.
        let parityConflict = issues.contains("同一时间的胎次事实冲突") || issues.contains("胎次确认与产羔记录冲突")
        let cycleAnchor = !parityConflict && missingBirth && (latestParity?.occurredAt ?? .distantPast) > (boundary?.occurredAt ?? .distantPast) ? latestParity : boundary
        // A parity confirmation can narrow the reliable time window, but cannot
        // manufacture a closure or change an existing cycle identity.
        let cycleID = boundary?.id ?? eweID
        let cycleFacts = facts.filter { fact in
            fact.kind != .parityBaseline && (cycleAnchor.map { fact.occurredAt >= $0.occurredAt && fact.id != $0.id } ?? true)
        }
        if let boundary, cycleFacts.contains(where: { $0.occurredAt == boundary.occurredAt }) {
            issues.append("繁殖事件同时发生，先后关系待核实")
        }
        var associations: [ReproductionFactAssociation] = []
        var roundByRecord: [UUID: UUID] = [:]
        var roundRoots: [UUID: Fact] = [:]
        var latestRound: UUID?
        let breedings = cycleFacts.filter { $0.kind == .breeding }
        for item in breedings {
            var reason = "按本轮事实时间线确定归属"
            var roundID: UUID?
            if let explicitCycle = item.reproductionCycleID, explicitCycle != cycleID {
                reason = "明确周期与产羔／流产时间线冲突"
            } else if item.breedingIntentRawValue == BreedingIntent.supplement.rawValue {
                if let related = item.relatedBreedingRecordID, let root = roundByRecord[related],
                   let prior = breedings.first(where: { $0.id == related }) ?? roundRoots[related], prior.occurredAt < item.occurredAt {
                    roundID = root
                    reason = "明确关联本轮补配"
                } else { reason = "补配缺少有效的本轮配种关联" }
            } else if item.breedingIntentRawValue == BreedingIntent.newRound.rawValue {
                roundID = item.breedingRoundID ?? item.id
                reason = "明确开始新一轮配种"
            } else if breedings.count == 1 || breedings.contains(where: { $0.breedingIntentRawValue == BreedingIntent.supplement.rawValue && $0.relatedBreedingRecordID == item.id }) {
                roundID = item.breedingRoundID ?? item.id
            } else { reason = "多条历史配种未区分补配与重新配种" }
            if let explicitRound = item.breedingRoundID, explicitRound != roundID {
                roundID = nil; reason = "明确轮次与配种关联冲突"
            }
            if let roundID {
                roundByRecord[item.id] = roundID
                roundByRecord[roundID] = roundID
                if roundRoots[roundID] == nil { roundRoots[roundID] = item }
                latestRound = roundID
            } else { issues.append(reason) }
            associations.append(.init(recordID: item.id, cycleID: roundID == nil ? nil : cycleID,
                roundID: roundID, inferred: item.reproductionCycleID == nil, reason: reason))
        }
        if Set(breedings.map(\.occurredAt)).count != breedings.count { issues.append("同一时间存在多条配种，先后关系待核实") }
        let breeding = latestRound.flatMap { roundRoots[$0] }
        let checks = cycleFacts.filter { $0.kind == .pregnancyCheck }
        if missingBirth, checks.isEmpty, facts.contains(where: { $0.kind == .pregnancyCheck }) {
            issues.append("胎次或最近产羔日期不足，孕检归属待核实")
        }
        var effectiveChecks: [Fact] = []
        for item in checks {
            var reason = "按本轮胎次及唯一时间线推导"
            var valid = true
            var roundID: UUID?
            if let cycle = item.reproductionCycleID, cycle != cycleID { valid = false; reason = "孕检关联周期已经结束或与日期冲突" }
            if let linked = item.relatedBreedingRecordID {
                if let root = roundByRecord[linked], let linkedFact = breedings.first(where: { $0.id == linked }) ?? roundRoots[linked], linkedFact.occurredAt < item.occurredAt {
                    roundID = root
                } else { valid = false; reason = "孕检关联配种不属于该时间点的有效周期" }
            } else if let explicitRound = item.breedingRoundID {
                roundID = explicitRound
                if roundRoots[explicitRound].map({ $0.occurredAt < item.occurredAt }) != true { valid = false; reason = "孕检轮次不存在或晚于检查时间" }
            } else {
                let prior = breedings.filter { $0.occurredAt < item.occurredAt }
                let roots = Set(prior.compactMap { roundByRecord[$0.id] })
                if roots.count == 1 && prior.allSatisfy({ roundByRecord[$0.id] != nil }) { roundID = roots.first }
                else if !prior.isEmpty { valid = false; reason = "孕检可对应多个配种轮次，归属待核实" }
                else if !breedings.isEmpty { valid = false; reason = "孕检与配种先后关系待核实" }
            }
            if let explicitRound = item.breedingRoundID, explicitRound != roundID { valid = false; reason = "孕检轮次与明确关联配种冲突" }
            if parity == nil || (missingBirth && latestParity.map { item.occurredAt <= $0.occurredAt } == true) {
                valid = false; reason = "胎次或最近产羔日期不足，孕检归属待核实"
            }
            if boundary?.occurredAt == item.occurredAt { valid = false; reason = "孕检与周期结束同时发生，先后待核实" }
            if valid && (roundID == latestRound || latestRound == nil) { effectiveChecks.append(item) }
            if !valid { issues.append(reason) }
            associations.append(.init(recordID: item.id, cycleID: valid ? cycleID : nil,
                roundID: valid ? roundID : nil, inferred: item.reproductionCycleID == nil, reason: reason))
        }
        // A later breeding fact cannot silently erase a confirmed pregnancy.
        for breeding in breedings {
            if let previousCheck = checks.last(where: { $0.occurredAt < breeding.occurredAt }),
               ReproductionPregnancyState.classify(previousCheck.result) == .pregnant {
                issues.append("已孕后存在配种记录，须核实妊娠结果及轮次")
            }
        }
        let check = effectiveChecks.last
        var state = check.map { ReproductionPregnancyState.classify($0.result) } ?? .unexamined
        if let check {
            let sameTime = effectiveChecks.filter { $0.occurredAt == check.occurredAt }
            if Set(sameTime.map { ReproductionPregnancyState.classify($0.result) }).count > 1 { issues.append("同一时间的孕检结果冲突") }
            if state == .uncertain { issues.append("检胎结果无法确认：\(check.result.isEmpty ? "未填写" : check.result)") }
        }
        // Missing birth date alone is a data issue, but a later, uniquely attributable
        // check can still be a fact. All temporal/association conflicts block status.
        let blocking = issues.filter { $0 != "已产羔，缺少对应的最近产羔日期" }
        if !blocking.isEmpty { state = .uncertain }
        var previous: Date?
        var previousClosureID: UUID?
        let history = closures.map { closure in
            let ids = facts.filter { fact in
                fact.kind != .parityBaseline && fact.occurredAt <= closure.occurredAt &&
                (previous.map { fact.occurredAt > $0 } ?? true)
            }.map(\.id)
            let id = previousClosureID ?? eweID
            previous = closure.occurredAt
            previousClosureID = closure.id
            return ReproductionCycleHistory(id: id, endedAt: closure.occurredAt, outcome: closure.kind,
                targetParity: closure.kind == .lambing ? closure.parity : nil, recordIDs: ids)
        }
        return ReproductionStateSnapshot(eweID: eweID, asOf: asOf, cycleID: cycleID,
            completedParity: parityConflict ? nil : parity, targetParity: parityConflict ? nil : parity.map { $0 + 1 },
            lastLambingAt: missingBirth ? nil : lastBirth?.occurredAt,
            breedingRoundID: latestRound, breeding: breeding, check: check, pregnancy: state,
            issues: Array(Set(issues)).sorted(), associations: associations, history: history)
    }
}

extension Calendar {
    static func farm(identifier: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: identifier) ?? .current
        return value
    }
}
