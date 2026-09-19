import Foundation

enum PenEweConcern: Int, CaseIterable, Identifiable, Sendable {
    case postpartum, zeroParity, firstSingle, threeSingles
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .postpartum: "距上次产羔超过250天"
        case .zeroParity: "零胎且本舍累计超过200天"
        case .firstSingle: "当前首胎且产单羔"
        case .threeSingles: "最近连续三胎单羔"
        }
    }
    var advice: String {
        switch self {
        case .postpartum: "复核配种、妊检及产羔漏记情况。"
        case .zeroParity: "复核首次繁殖进展及胎次档案。"
        case .firstSingle: "持续观察后续胎表现。"
        case .threeSingles: "复核持续繁殖表现及历史记录。"
        }
    }
}

struct PenEweResidence: Identifiable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let isOngoing: Bool
    var days: Int { max(0, FarmAnalyticsDate.days(from: start, to: end)) }
}

struct PenEweAssessment: Identifiable, Sendable {
    let id: UUID
    let earTag: String
    let parity: Int?
    let lambings: [FarmAnalyticsSnapshot.Lambing]
    let residence: [PenEweResidence]
    let postpartumDays: Int?
    let concerns: Set<PenEweConcern>
    let issues: [String]
    let hasUnresolvedConcern: Bool
    var residenceDays: Int { residence.reduce(0) { $0 + $1.days } }
    var blocksRating: Bool { concerns.isEmpty && hasUnresolvedConcern }
}

struct PenReproductionSummary: Identifiable, Sendable {
    let penID: UUID?
    let name: String
    let ewes: [PenEweAssessment]
    let rows: [PenEweConcern: [PenEweAssessment]]
    var id: String { penID?.uuidString ?? "unassigned" }
    var attentionCount: Int { ewes.count { !$0.concerns.isEmpty } }
    var attentionRate: Double { ewes.isEmpty ? 0 : Double(attentionCount) / Double(ewes.count) }
    var pending: [PenEweAssessment] { ewes.filter { !$0.issues.isEmpty } }
    var rating: String {
        guard !ewes.isEmpty else { return "暂无可评价母羊" }
        guard !ewes.contains(where: \.blocksRating) else { return "数据不足，暂不评级" }
        return Self.grade(attention: attentionCount, total: ewes.count)
    }
    static func grade(attention: Int, total: Int) -> String {
        guard total > 0 else { return "暂无可评价母羊" }
        // Compare integer counts, before display rounding.
        if attention * 10 < total { return "优" }
        if attention * 5 < total { return "良" }
        if attention * 10 < total * 3 { return "中" }
        return "差"
    }
    var mainConcerns: [PenEweConcern] {
        let maximum = rows.values.map(\.count).max() ?? 0
        return maximum == 0 ? [] : PenEweConcern.allCases.filter { rows[$0]?.count == maximum }
    }
}

enum PenReproductionAnalyticsEngine {
    static func calculate(snapshot: FarmAnalyticsSnapshot, asOf date: Date, breed: String? = nil) throws -> [PenReproductionSummary] {
        let day = FarmAnalyticsDate.day(date)
        let end = FarmAnalyticsDate.calendar.date(byAdding: .day, value: 1, to: day)!
        let lambings = Dictionary(grouping: snapshot.lambings.filter { $0.occurredAt < end }, by: \.eweID)
        let parity = Dictionary(grouping: snapshot.parityEvidence.filter { $0.occurredAt < end }, by: \.eweID)
        let purposes = Dictionary(grouping: snapshot.purposeFacts, by: \.sheepID)
        let weanings = Dictionary(grouping: snapshot.weanings, by: \.sheepID)
        let transfers = Dictionary(grouping: snapshot.transfers.filter { $0.occurredAt < end }, by: \.sheepID)
        let removals = Dictionary(grouping: snapshot.removals, by: \.sheepID).mapValues { $0.map(\.occurredAt).min()! }
        var groups: [String: [PenEweAssessment]] = [:]
        let enabledPens = snapshot.pens.filter(\.isActive)
        let names = Dictionary(uniqueKeysWithValues: enabledPens.map { ($0.id.uuidString, $0.name) })
        let ids = Dictionary(uniqueKeysWithValues: enabledPens.map { ($0.id.uuidString, $0.id) })
        for ewe in snapshot.sheep {
            try Task.checkCancellation()
            guard ewe.enteredAt < end, ewe.birthAt.map({ $0 < end }) ?? true else { continue }
            let removal = [ewe.removedAt, removals[ewe.id]].compactMap { $0 }.min()
            // A dated exit proves historical presence before that exit. Without
            // it, use the same current-presence rule as the herd/home screens:
            // active historical archives are not living in-herd animals.
            guard removal.map({ $0 >= end }) ?? ewe.isCurrentlyPresent else { continue }
            let history = (transfers[ewe.id] ?? []).sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let penID = history.last?.toPenID ?? (history.isEmpty ? ewe.initialPenID : nil)
            guard let key = penID?.uuidString, ids[key] != nil else { continue }
            guard ewe.sex == .ewe, ewe.purpose == SheepPurpose.breedingEwe.rawValue,
                  breed == nil || ewe.breed == breed else { continue }
            let births = (lambings[ewe.id] ?? []).sorted {
                $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt < $1.occurredAt
            }
            let evidence = (parity[ewe.id] ?? []).sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            // Production snapshots contain lambing and baseline evidence. The fallback also
            // supports older snapshots; no parity and no births means zero by farm policy.
            let lastEvidence = evidence.last
            let latestBirth = births.last
            let currentParity: Int?
            if let latestBirth, lastEvidence == nil || latestBirth.occurredAt > lastEvidence!.occurredAt {
                currentParity = latestBirth.parity.flatMap { $0 > 0 ? $0 : nil }
            } else {
                currentParity = lastEvidence?.parity ?? (births.isEmpty ? 0 : nil)
            }
            var issues: [String] = []
            var unresolved = false
            var concerns: Set<PenEweConcern> = []
            let postpartum = latestBirth.map { FarmAnalyticsDate.days(from: $0.occurredAt, to: day) }
            let missingLatestBirth = currentParity.map { value in
                guard let latestBirth else { return value > 0 }
                return latestBirth.parity.map { $0 > 0 && value > $0 } ?? false
            } ?? false
            if missingLatestBirth && !births.isEmpty {
                issues.append("已有胎次，但缺少对应的最近产羔记录")
                // A newer missing birth can only shorten a known postpartum interval.
                unresolved = postpartum.map { $0 > 250 } ?? true
            } else if let postpartum, postpartum > 250 { concerns.insert(.postpartum) }
            if currentParity == nil {
                issues.append("缺少可确认的当前胎次")
                unresolved = true
            }
            if currentParity == 0 && !births.isEmpty {
                issues.append("零胎确认与产羔记录冲突")
                unresolved = true
            }

            let periods = residencePeriods(history: history, penID: penID, until: day,
                purposeFacts: purposes[ewe.id] ?? [], weanings: weanings[ewe.id] ?? [], birthAt: ewe.birthAt)
            let residenceDays = periods.reduce(0) { $0 + $1.days }
            if currentParity == 0 && births.isEmpty && residenceDays > 200 {
                concerns.insert(.zeroParity)
            }
            if currentParity == 1 && !births.isEmpty {
                // An explicit current-parity correction can confirm a legacy birth
                // whose stored parity was zero or missing, without rewriting it.
                if births.count == 1, let first = births.first,
                   first.parity == nil || first.parity == 0 || first.parity == 1, first.total > 0 {
                    if first.total == 1 { concerns.insert(.firstSingle) }
                } else {
                    issues.append("首胎产羔记录缺失或与当前胎次冲突")
                    unresolved = true
                }
            }
            if let currentParity, currentParity >= 3, !births.isEmpty {
                let lastThree = Array(births.suffix(3))
                let expected = [currentParity - 2, currentParity - 1, currentParity]
                let consecutive = lastThree.count == 3 && lastThree.map(\.parity) == expected.map(Optional.some)
                let distinctDates = Set(lastThree.map { FarmAnalyticsDate.day($0.occurredAt) }).count == 3
                if consecutive && distinctDates && lastThree.allSatisfy({ $0.total > 0 }) {
                    if lastThree.allSatisfy({ $0.total == 1 }) { concerns.insert(.threeSingles) }
                } else {
                    issues.append("最近三胎记录缺失、胎次不连续或产羔数无效")
                    // A confirmed multiple birth within the last three parity numbers
                    // disproves the streak even if another birth is missing.
                    let knownMultiple = lastThree.contains {
                        $0.parity.map { expected.contains($0) } == true && $0.total > 1
                    }
                    if !knownMultiple { unresolved = true }
                }
            }
            if let currentParity, let latestBirth, let recorded = latestBirth.parity, recorded > currentParity {
                issues.append("当前胎次低于最近产羔胎次")
                unresolved = true
            }
            groups[key, default: []].append(.init(id: ewe.id, earTag: ewe.earTag, parity: currentParity,
                lambings: births, residence: periods, postpartumDays: postpartum, concerns: concerns,
                issues: Array(Set(issues)).sorted(), hasUnresolvedConcern: unresolved))
        }
        // Every listed pen must contain at least one ewe in the selected cohort.
        return try groups.keys.sorted().map { key in
            try Task.checkCancellation()
            let ewes = (groups[key] ?? []).sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
            let rows = Dictionary(uniqueKeysWithValues: PenEweConcern.allCases.map { concern in
                (concern, ewes.filter { $0.concerns.contains(concern) }.sorted {
                    switch concern {
                    case .postpartum:
                        if $0.postpartumDays != $1.postpartumDays { return ($0.postpartumDays ?? 0) > ($1.postpartumDays ?? 0) }
                    case .zeroParity:
                        if $0.residenceDays != $1.residenceDays { return $0.residenceDays > $1.residenceDays }
                    case .firstSingle, .threeSingles:
                        let a = $0.lambings.last?.occurredAt ?? .distantPast
                        let b = $1.lambings.last?.occurredAt ?? .distantPast
                        if a != b { return a > b }
                    }
                    return $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending
                })
            })
            return PenReproductionSummary(penID: ids[key], name: names[key]!, ewes: ewes, rows: rows)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Only dated transfers establish residence. Profile creation, birth and
    /// initialPenID are never substituted for an entry event.
    static func residencePeriods(history: [FarmAnalyticsSnapshot.Transfer], penID: UUID?, until day: Date,
                                 purposeFacts: [SheepPurposeTimelineFact],
                                 weanings: [FarmAnalyticsSnapshot.Weaning], birthAt: Date? = nil) -> [PenEweResidence] {
        let facts = purposeFacts.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        func isLamb(_ value: String?) -> Bool {
            guard let value else { return false }
            let purpose = SheepPurpose.classify(storedValue: value)
            return purpose == .sucklingLamb || purpose == .weanedLamb
        }
        func excluded(_ transfer: FarmAnalyticsSnapshot.Transfer) -> Bool {
            if let birthAt, FarmAnalyticsDate.day(transfer.occurredAt) <= FarmAnalyticsDate.day(birthAt) { return true }
            let purpose = facts.last(where: { $0.occurredAt <= transfer.occurredAt })?.purpose.rawValue
                ?? facts.first?.previousPurpose
            if isLamb(purpose) { return true }
            let note = transfer.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["新生羔羊", "哺乳羔羊", "羔羊断奶", "断奶羔羊"].contains(where: note.contains) { return true }
            // Transfers before/on a recorded weaning belong to the lamb stage,
            // unless an explicit adult-purpose fact already establishes otherwise.
            if purpose == nil, let weaning = weanings.map(\.occurredAt).max(),
               FarmAnalyticsDate.day(transfer.occurredAt) <= FarmAnalyticsDate.day(weaning) { return true }
            return false
        }
        var periods: [PenEweResidence] = []
        var residentPen: UUID?
        var start: Date?
        var startID = ""
        func close(at end: Date, ongoing: Bool) {
            guard residentPen == penID, let start else { return }
            // If a sheep re-enters either lamb stage, stop counting until a
            // subsequent eligible transfer establishes a fresh residence.
            let stageEnd = facts.first { $0.occurredAt > start && $0.occurredAt <= end && isLamb($0.purpose.rawValue) }?.occurredAt
            let finish = stageEnd ?? end
            periods.append(.init(id: startID, start: start, end: max(start, finish), isOngoing: ongoing && stageEnd == nil))
        }
        for transfer in history {
            let eligible = !excluded(transfer)
            let interrupted = start.map { start in facts.contains {
                $0.occurredAt > start && $0.occurredAt <= transfer.occurredAt && isLamb($0.purpose.rawValue)
            } } ?? false
            if transfer.toPenID == residentPen, start != nil, eligible, !interrupted { continue }
            close(at: min(transfer.occurredAt, day), ongoing: false)
            residentPen = transfer.toPenID
            start = eligible ? transfer.occurredAt : nil
            startID = transfer.id.uuidString
        }
        close(at: day, ongoing: true)
        return periods
    }

}
