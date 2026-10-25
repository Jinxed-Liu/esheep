import Foundation

struct ReproductionManagementPen: Identifiable, Sendable {
    let id: UUID
    let name: String
    let usage: ReproductionPenUsage
    let isActive: Bool
    let sheepCount: Int
    let eweCount: Int
    let isSelected: Bool
}

struct ReproductionManagementEwe: Identifiable, Sendable {
    let id: UUID
    let earTag: String
    let breed: String
    let penID: UUID
    let penName: String
    let parity: Int?
    let lastLambingAt: Date?
    let postpartumDays: Int?
    let ageMonths: Int?
    let isConfirmedMaiden: Bool
    let category: ReproductionEweCategory
    let isCheckEligible: Bool
    let stageID: String
    let stageTitle: String
    let stageOrder: Int
    let pregnancy: ReproductionPregnancyState
    let checkAt: Date?
    let checkResult: String?
    let historicalCheckAt: Date?
    let relatedBreedingID: UUID?
    let issues: [String]
    let concerns: [ReproductionManagementConcern]
    let evidenceFingerprint: String

    var severity: ReproductionConcernSeverity? { concerns.map(\.severity).max() }
    var isYoungPregnant: Bool { category == .young && pregnancy == .pregnant }
}

struct ReproductionManagementStage: Identifiable, Sendable {
    let id: String
    let title: String
    let order: Int
    let ewes: [ReproductionManagementEwe]
    var eligibleCount: Int { ewes.count(where: \.isCheckEligible) }
    func count(_ state: ReproductionPregnancyState) -> Int {
        ewes.count { $0.isCheckEligible && $0.pregnancy == state }
    }
}

struct ReproductionManagementResult: Sendable {
    let farmID: UUID
    let asOf: Date
    let timeZoneIdentifier: String
    let settings: ReproductionManagementSettings
    let sourceSettings: ReproductionManagementSettings?
    let careRule: ReproductionCareRuleSnapshot?
    let occupiedPens: [ReproductionManagementPen]
    let inactiveOccupiedPens: [ReproductionManagementPen]
    let ewes: [ReproductionManagementEwe]

    var effectivePenCount: Int { occupiedPens.count(where: \.isSelected) }
    var eligibleCount: Int { ewes.count(where: \.isCheckEligible) }
    var attention: [ReproductionManagementEwe] {
        ewes.filter { !$0.concerns.isEmpty }.sorted {
            if $0.severity != $1.severity { return ($0.severity ?? .review) > ($1.severity ?? .review) }
            return $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending
        }
    }
    var remindersConfigured: Bool {
        settings.hasThresholdRules || careRule?.operationalRulesConfigured == true
    }
    func count(_ state: ReproductionPregnancyState) -> Int {
        ewes.count { $0.isCheckEligible && $0.pregnancy == state }
    }
    func stages(penID: UUID? = nil) -> [ReproductionManagementStage] {
        let rows = ewes.filter { penID == nil || $0.penID == penID }
        let groups = Dictionary(grouping: rows, by: \.stageID)
        var result = ReproductionPostpartumBand.allCases.map { band in
            ReproductionManagementStage(id: "postpartum-\(band.rawValue)", title: "产后 \(band.title)",
                order: band.rawValue, ewes: groups["postpartum-\(band.rawValue)"] ?? [])
        }
        result += groups.filter { !$0.key.hasPrefix("postpartum-") }.map { key, group in
            ReproductionManagementStage(id: key, title: group[0].stageTitle, order: group[0].stageOrder, ewes: group)
        }
        return result.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }

    /// One reproductive alert per ewe, with all causes retained. The same
    /// adapter is used by the analytics page and the operational digest.
    func operationalAlerts(deferrals: [FarmOperationalAlertEngine.Deferral] = []) -> [FarmOperationalAlert] {
        attention.compactMap { ewe in
            guard let severity = ewe.severity else { return nil }
            let kind: FarmOperationalAlertKind = switch severity {
            case .review: .reproductionReview
            case .reminder: .reproductionReminder
            case .warning: .reproductionWarning
            }
            let fingerprint = StableCloudUUID.derived(namespace: farmID, name: ewe.evidenceFingerprint).uuidString.lowercased()
            let due = ewe.concerns.filter { $0.severity == severity }.map(\.dueAt).min() ?? asOf
            let alert = FarmOperationalAlertEngine.makeAlert(farmID: farmID, kind: kind, subjectID: ewe.id,
                sourceEntityID: ewe.relatedBreedingID, fingerprint: fingerprint,
                title: "\(ewe.earTag) · \(kind.displayName)", detail: ewe.concerns.map(\.detail).joined(separator: "；"),
                dueAt: due, earTag: ewe.earTag)
            let isDeferred = deferrals.contains {
                $0.alertID == alert.id && $0.conditionFingerprint == fingerprint &&
                $0.deferredUntil > asOf && $0.deferredUntil > $0.deferredAt &&
                $0.deferredUntil.timeIntervalSince($0.deferredAt) <= 8 * 86_400
            }
            return isDeferred ? nil : alert
        }
    }
}

enum ReproductionManagementEngine {
    static func calculate(snapshot: FarmAnalyticsSnapshot) throws -> ReproductionManagementResult {
        guard snapshot.reproductionSettingsIssue == nil else { throw ReproductionSettingsError.unreadable }
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) else {
            throw FarmCommandError.invalidFarmTimeZone
        }
        calendar.timeZone = timeZone
        let now = snapshot.factsReadAt
        let today = calendar.startOfDay(for: now)
        let settings = try (snapshot.reproductionSettings ?? .init()).validated()
        let selected = Set(settings.scopeConfigured ? settings.selectedPenIDs : [])
        let confirmedYouth = Set(settings.youthBreedingConfirmedSheepIDs)
        let present = snapshot.sheep.filter { $0.isCurrentlyPresent && $0.enteredAt <= now }
        let presentByPen = Dictionary(grouping: present.compactMap { item in item.currentPenID.map { ($0, item) } }, by: \.0)
        let pens = snapshot.pens.compactMap { pen -> ReproductionManagementPen? in
            let members = presentByPen[pen.id] ?? []
            guard !members.isEmpty else { return nil }
            return .init(id: pen.id, name: pen.name, usage: settings.usage(for: pen.id), isActive: pen.isActive,
                sheepCount: members.count, eweCount: members.count { $0.1.sex == .ewe }, isSelected: selected.contains(pen.id))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let activePens = pens.filter(\.isActive)
        let penNames = Dictionary(uniqueKeysWithValues: activePens.filter(\.isSelected).map { ($0.id, $0.name) })
        let factsByEwe = Dictionary(grouping: snapshot.reproductionFacts.filter { $0.occurredAt <= now }, by: \.eweID)
        let birthsByEwe = Dictionary(grouping: snapshot.lambings.filter { $0.occurredAt <= now }, by: \.eweID)
        let parityByEwe = Dictionary(grouping: snapshot.parityEvidence.filter { $0.occurredAt <= now }, by: \.eweID)
        let cycleStates = ReproductionCycleResolver.states(snapshot: snapshot)
        var rows: [ReproductionManagementEwe] = []
        for ewe in present where ewe.sex == .ewe {
            try Task.checkCancellation()
            guard let penID = ewe.currentPenID, let penName = penNames[penID] else { continue }
            let facts = (factsByEwe[ewe.id] ?? []).sorted(by: factOrder)
            let births = (birthsByEwe[ewe.id] ?? []).sorted { $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt < $1.occurredAt }
            let evidence = (parityByEwe[ewe.id] ?? []).sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let lastBirth = births.last
            let lastParity = evidence.last
            let cycleState = cycleStates[ewe.id]!
            let preBreedingLamb = ReproductionReviewPolicy.isPreBreedingLamb(purpose: ewe.purpose,
                birthAt: ewe.birthAt, removedAt: ewe.removedAt,
                hasReproductionFacts: !facts.isEmpty || !births.isEmpty || !evidence.isEmpty,
                asOf: now, timeZoneIdentifier: snapshot.timeZoneIdentifier,
                minimumAgeMonths: settings.minimumAgeMonths)
            let parity = cycleState.completedParity
            var issues: [String] = []
            if parity == nil { issues.append("缺少可确认的胎次，不能判定为未产羔") }
            let hasConflict = parity == 0 && lastBirth != nil ||
                (parity != nil && lastBirth?.parity != nil && lastBirth!.parity! > parity!)
            if hasConflict { issues.append("胎次确认与产羔记录冲突") }
            let missingBirth = parity.map { value in
                guard value > 0 else { return false }
                guard let lastBirth else { return true }
                return lastBirth.parity.map { value > $0 } ?? (lastParity.map { $0.occurredAt > lastBirth.occurredAt } ?? false)
            } ?? false
            if missingBirth { issues.append("已产羔，缺少对应的最近产羔日期") }
            if births.count > 1, let latest = births.last,
               births.dropLast().last.map({ calendar.isDate($0.occurredAt, inSameDayAs: latest.occurredAt) }) == true {
                issues.append("同日存在多条产羔记录，最近产羔待核实")
            }
            let hasReliableBirth = lastBirth != nil && !missingBirth && !hasConflict && !issues.contains("同日存在多条产羔记录，最近产羔待核实")
            let postpartum = hasReliableBirth ? lastBirth.map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0.occurredAt), to: today).day ?? 0 } : nil
            let validBirthAt = ewe.birthAt.flatMap { $0 <= now ? calendar.startOfDay(for: $0) : nil }
            if validBirthAt == nil { issues.append(ewe.birthAt == nil ? "缺少出生日期，月龄无法计算" : "出生日期晚于统计时间") }
            let months = validBirthAt.map { calendar.dateComponents([.month], from: $0, to: today).month ?? 0 }
            let maturityAt = validBirthAt.flatMap { calendar.date(byAdding: .month, value: settings.minimumAgeMonths, to: $0) }
            let overAge = maturityAt.map { today > $0 } ?? false
            let maiden = parity == 0 && births.isEmpty && !hasConflict
            let category: ReproductionEweCategory
            if preBreedingLamb { category = .immature }
            else if hasConflict || parity == nil { category = .uncertain }
            else if parity == 1 { category = .firstParity }
            else if let parity, parity >= 2 { category = .multiparous }
            else if maiden && overAge { category = confirmedYouth.contains(ewe.id) ? .young : .pendingReadiness }
            else if maiden && months != nil { category = .immature }
            else { category = .uncertain }
            let eligible = postpartum != nil || overAge
            let stage: (id: String, title: String, order: Int)
            if preBreedingLamb, let months {
                stage = ("pre-breeding-lamb", "羔羊 · \(months) 月龄", 100 + months * 3)
            } else if let postpartum, let band = ReproductionPostpartumBand.containing(postpartum) {
                stage = ("postpartum-\(band.rawValue)", "产后 \(band.title)", band.rawValue)
            } else if maiden, let months {
                stage = ("maiden-\(months)-\(category.rawValue)", "\(category.rawValue) · \(months) 月龄", 100 + months * 3 + (category == .young ? 2 : overAge ? 1 : 0))
            } else if missingBirth, let months {
                stage = ("missing-birth-\(months)", "缺产羔日期 · \(months) 月龄", 500 + months)
            } else {
                stage = ("unresolved", "繁殖资料待核实", 1_000)
            }
            let pregnancy = (state: cycleState.pregnancy, check: cycleState.check, breeding: cycleState.breeding)
            issues.append(contentsOf: cycleState.issues)
            var concerns: [ReproductionManagementConcern] = []
            if pregnancy.state == .unexamined {
                if eligible, let postpartum, let reminder = settings.postpartumReminderDays,
                   let warning = settings.postpartumWarningDays, postpartum >= reminder, let lastBirth {
                    let severe = postpartum >= warning
                    concerns.append(.init(kind: .postpartum, severity: severe ? .warning : .reminder,
                        detail: "产后 \(postpartum) 天，本轮未检胎（\(severe ? "警告" : "提醒")门槛 \(severe ? warning : reminder) 天）",
                        dueAt: calendar.date(byAdding: .day, value: severe ? warning : reminder, to: calendar.startOfDay(for: lastBirth.occurredAt))!))
                }
                if category == .young, let birth = validBirthAt, let reminder = settings.maidenReminderMonths,
                   let warning = settings.maidenWarningMonths,
                   let reminderAt = calendar.date(byAdding: .month, value: reminder, to: birth), today >= reminderAt,
                   let warningAt = calendar.date(byAdding: .month, value: warning, to: birth) {
                    let severe = today >= warningAt
                    let effectiveReminderAt = reminder == settings.minimumAgeMonths
                        ? calendar.date(byAdding: .day, value: 1, to: reminderAt)! : reminderAt
                    concerns.append(.init(kind: .maiden, severity: severe ? .warning : .reminder,
                        detail: "青年母羊已达到 \(severe ? warning : reminder) 月龄，本轮未检胎",
                        dueAt: severe ? warningAt : effectiveReminderAt))
                }
                if let breeding = pregnancy.breeding, let rule = snapshot.reproductionCareRule,
                   rule.operationalRulesConfigured,
                   let due = calendar.date(byAdding: .day, value: rule.pregnancyCheckDays, to: calendar.startOfDay(for: breeding.occurredAt)),
                   let warningAt = calendar.date(byAdding: .day, value: -rule.warningLeadDays, to: due), today >= warningAt {
                    let severe = today >= due
                    concerns.append(.init(kind: .breeding, severity: severe ? .warning : .reminder,
                        detail: severe ? "配种后达到 \(rule.pregnancyCheckDays) 天，本轮未检胎" : "配种后孕检即将到期，本轮未检胎",
                        dueAt: due))
                }
            }
            if category == .pendingReadiness {
                concerns.append(.init(kind: .review, severity: .review, detail: "已达参配月龄，尚未人工确认可参配", dueAt: today))
            }
            if eligible && pregnancy.state == .recheck, let checkAt = pregnancy.check?.occurredAt {
                concerns.append(.init(kind: .recheck, severity: .review, detail: "最近检胎要求复检，请核对后续检查", dueAt: calendar.startOfDay(for: checkAt)))
            }
            if preBreedingLamb { issues.removeAll { $0 == "缺少可确认的胎次，不能判定为未产羔" } }
            issues = Array(Set(issues)).sorted()
            if !issues.isEmpty {
                concerns.append(.init(kind: .review, severity: .review, detail: issues.joined(separator: "；"), dueAt: today))
            }
            let factFingerprint = facts.map {
                "\($0.id):\($0.revision):\($0.occurredAt.timeIntervalSince1970):\($0.result)"
            }.joined(separator: "|")
            let concernFingerprint = concerns.map { concern in
                let dueAt: TimeInterval = concern.kind == .review ? 0 : concern.dueAt.timeIntervalSince1970
                return "\(concern.kind.rawValue):\(concern.severity.rawValue):\(dueAt)"
            }.joined(separator: "|")
            var fingerprint = factFingerprint
            fingerprint += "|parity:\(parity.map { String($0) } ?? "unknown")|birth:\(ewe.birthAt?.timeIntervalSince1970 ?? -1)|pen:\(penID)|"
            fingerprint += "category:\(category.rawValue)|age:\(settings.minimumAgeMonths)|post:\(settings.postpartumReminderDays ?? -1):\(settings.postpartumWarningDays ?? -1)|young:\(settings.maidenReminderMonths ?? -1):\(settings.maidenWarningMonths ?? -1)|"
            fingerprint += "breeding:\(snapshot.reproductionCareRule?.pregnancyCheckDays ?? -1):\(snapshot.reproductionCareRule?.warningLeadDays ?? -1)|"
            fingerprint += concernFingerprint
            fingerprint += issues.joined(separator: "|")
            rows.append(.init(id: ewe.id, earTag: ewe.earTag, breed: ewe.breed, penID: penID, penName: penName,
                parity: parity, lastLambingAt: hasReliableBirth ? lastBirth?.occurredAt : nil, postpartumDays: postpartum,
                ageMonths: months, isConfirmedMaiden: maiden, category: category, isCheckEligible: eligible,
                stageID: stage.id, stageTitle: stage.title, stageOrder: stage.order,
                pregnancy: pregnancy.state, checkAt: pregnancy.check?.occurredAt, checkResult: pregnancy.check?.result,
                historicalCheckAt: facts.last(where: { $0.kind == .pregnancyCheck })?.occurredAt,
                relatedBreedingID: pregnancy.breeding?.id, issues: issues, concerns: concerns, evidenceFingerprint: fingerprint))
        }
        rows.sort { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
        return .init(farmID: snapshot.farmID, asOf: now, timeZoneIdentifier: snapshot.timeZoneIdentifier,
            settings: settings, sourceSettings: snapshot.reproductionSettings, careRule: snapshot.reproductionCareRule, occupiedPens: activePens,
            inactiveOccupiedPens: pens.filter { !$0.isActive }, ewes: rows)
    }

    private static func factOrder(_ lhs: FarmAnalyticsSnapshot.ReproductionFact, _ rhs: FarmAnalyticsSnapshot.ReproductionFact) -> Bool {
        lhs.occurredAt == rhs.occurredAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.occurredAt < rhs.occurredAt
    }

}
