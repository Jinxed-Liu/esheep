import Foundation
import SwiftData

enum FarmOperationalAlertRuntimeNotification {
    static let refreshRequested = Notification.Name("FarmOperationalAlertRefreshRequested")
    private static let farmIDKey = "farmID"

    static func post(farmID: UUID) {
        NotificationCenter.default.post(
            name: refreshRequested,
            object: nil,
            userInfo: [farmIDKey: farmID]
        )
    }

    static func farmID(from notification: Notification) -> UUID? {
        notification.userInfo?[farmIDKey] as? UUID
    }
}

enum FarmOperationalAlertKind: String, Codable, CaseIterable, Sendable, Hashable {
    case weaningDueSoon
    case weaningOverdue
    case pregnancyCheckDueSoon
    case pregnancyCheckOverdue
    case invalidPen
    case tmrNotFed
    case tmrLow
    case tmrHigh

    var displayName: String {
        switch self {
        case .weaningDueSoon: "断奶即将到期"
        case .weaningOverdue: "超龄未断奶"
        case .pregnancyCheckDueSoon: "孕检即将到期"
        case .pregnancyCheckOverdue: "逾期未孕检"
        case .invalidPen: "圈舍异常"
        case .tmrNotFed: "TMR 未投喂"
        case .tmrLow: "TMR 投喂偏低"
        case .tmrHigh: "TMR 投喂偏高"
        }
    }

    var symbol: String {
        switch self {
        case .weaningDueSoon, .weaningOverdue: "leaf.circle.fill"
        case .pregnancyCheckDueSoon, .pregnancyCheckOverdue: "heart.text.square"
        case .invalidPen: "building.2.crop.circle"
        case .tmrNotFed: "fork.knife.circle"
        case .tmrLow: "arrow.down.circle"
        case .tmrHigh: "arrow.up.circle"
        }
    }

    var isDueSoon: Bool {
        self == .weaningDueSoon || self == .pregnancyCheckDueSoon
    }

    var isTMR: Bool {
        self == .tmrNotFed || self == .tmrLow || self == .tmrHigh
    }
}

struct FarmOperationalAlert: Identifiable, Sendable, Hashable {
    let id: UUID
    let farmID: UUID
    let kind: FarmOperationalAlertKind
    let subjectID: UUID
    let sourceEntityID: UUID?
    let conditionFingerprint: String
    let title: String
    let detail: String
    let dueAt: Date
    let earTag: String
    // TMR alerts keep their typed values so the UI can compose localized text
    // instead of treating a number-filled Chinese String as a localization key.
    let tmrMeal: TMRMealPeriod?
    let tmrTargetText: String?
    let tmrActualText: String?
    let tmrDifferenceText: String?

    init(
        id: UUID,
        farmID: UUID,
        kind: FarmOperationalAlertKind,
        subjectID: UUID,
        sourceEntityID: UUID?,
        conditionFingerprint: String,
        title: String,
        detail: String,
        dueAt: Date,
        earTag: String,
        tmrMeal: TMRMealPeriod? = nil,
        tmrTargetText: String? = nil,
        tmrActualText: String? = nil,
        tmrDifferenceText: String? = nil
    ) {
        self.id = id
        self.farmID = farmID
        self.kind = kind
        self.subjectID = subjectID
        self.sourceEntityID = sourceEntityID
        self.conditionFingerprint = conditionFingerprint
        self.title = title
        self.detail = detail
        self.dueAt = dueAt
        self.earTag = earTag
        self.tmrMeal = tmrMeal
        self.tmrTargetText = tmrTargetText
        self.tmrActualText = tmrActualText
        self.tmrDifferenceText = tmrDifferenceText
    }

    func daysOverdue(now: Date, timeZoneIdentifier: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let dueDay = calendar.startOfDay(for: dueAt)
        let today = calendar.startOfDay(for: now)
        return max(0, calendar.dateComponents([.day], from: dueDay, to: today).day ?? 0)
    }

    func daysUntilDue(now: Date, timeZoneIdentifier: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueAt)
        return max(0, calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0)
    }
}

struct FarmScheduledReminderSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let kind: CareReminderKind
    let title: String
    let dueAt: Date
    let sheepID: UUID?
}

struct FarmOperationalAlertRuleSnapshot: Sendable, Hashable {
    let id: UUID
    let pregnancyCheckDays: Int
    let gestationDays: Int
    let weaningAgeDays: Int?
    let warningLeadDays: Int
    let operationalAlertsConfiguredAt: Date?
    let digestEnabled: Bool
    let digestMinuteOfDay: Int

    var isConfigured: Bool {
        operationalAlertsConfiguredAt != nil && weaningAgeDays != nil
    }
}

struct FarmOperationalAlertSnapshot: Sendable, Hashable {
    let farmID: UUID
    let timeZoneIdentifier: String
    let generatedAt: Date
    let rule: FarmOperationalAlertRuleSnapshot?
    let operationalAlerts: [FarmOperationalAlert]
    let overdueReminders: [FarmScheduledReminderSnapshot]
    let missingBirthDateCount: Int
    var tmrMonitoringConfigured: Bool = false

    var isConfigured: Bool { rule?.isConfigured == true || tmrMonitoringConfigured }
    var totalPendingCount: Int { operationalAlerts.count + overdueReminders.count }
}

enum FarmOperationalAlertDeferralPlan {
    static let allowedDayCounts = [1, 3, 7]

    static func deferredUntil(
        days: Int,
        now: Date,
        timeZoneIdentifier: String,
        minuteOfDay: Int
    ) -> Date? {
        guard allowedDayCounts.contains(days),
              (0...1_439).contains(minuteOfDay),
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let day = calendar.date(
            byAdding: .day,
            value: days,
            to: calendar.startOfDay(for: now)
        ) else { return nil }
        return calendar.date(
            bySettingHour: minuteOfDay / 60,
            minute: minuteOfDay % 60,
            second: 0,
            of: day
        )
    }
}

enum FarmOperationalAlertEngine {
    struct Sheep: Sendable, Hashable {
        let id: UUID
        let earTag: String
        let purpose: String
        let sex: SheepSex
        let status: SheepStatus
        let isHistoricalArchive: Bool
        let currentPenID: UUID?
        let birthAt: Date?
        let enteredAt: Date
        let createdAt: Date
        let revision: Int

        var isCurrentlyPresent: Bool {
            status == .active && !isHistoricalArchive
        }
    }

    struct Pen: Sendable, Hashable {
        let id: UUID
        let isActive: Bool
        let revision: Int
        let isDeleted: Bool
    }

    struct Weaning: Sendable, Hashable {
        let id: UUID
        let sheepID: UUID
        let revision: Int
        let isDeleted: Bool
    }

    struct Reproduction: Sendable, Hashable {
        let id: UUID
        let eweID: UUID
        let kind: ReproductionRecordKind
        let occurredAt: Date
        let revision: Int
        let isDeleted: Bool
    }

    struct LambingOffspring: Sendable, Hashable {
        let id: UUID
        let lambingRecordID: UUID
        let sheepID: UUID?
        let isStillborn: Bool
        let revision: Int
        let isDeleted: Bool
    }

    struct Deferral: Sendable, Hashable {
        let alertID: UUID
        let conditionFingerprint: String
        let deferredAt: Date
        let deferredUntil: Date
    }

    static func evaluate(
        farmID: UUID,
        timeZoneIdentifier: String,
        now: Date,
        rule: FarmOperationalAlertRuleSnapshot?,
        sheep: [Sheep],
        pens: [Pen],
        weanings: [Weaning],
        reproduction: [Reproduction],
        lambingOffspring: [LambingOffspring] = [],
        reminders: [FarmScheduledReminderSnapshot],
        deferrals: [Deferral]
    ) -> FarmOperationalAlertSnapshot {
        let activeSheep = sheep.filter(\.isCurrentlyPresent)
        let missingBirthDateCount = activeSheep.count { $0.birthAt == nil }
        let overdueReminders = reminders
            .filter { $0.dueAt <= now }
            .sorted(by: reminderOrder)

        guard let rule,
              rule.isConfigured,
              let weaningAgeDays = rule.weaningAgeDays,
              let operationalAlertsConfiguredAt = rule.operationalAlertsConfiguredAt else {
            return FarmOperationalAlertSnapshot(
                farmID: farmID,
                timeZoneIdentifier: timeZoneIdentifier,
                generatedAt: now,
                rule: rule,
                operationalAlerts: [],
                overdueReminders: overdueReminders,
                missingBirthDateCount: missingBirthDateCount
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let today = calendar.startOfDay(for: now)
        let warningLeadDays = min(max(rule.warningLeadDays, 0), 30)
        let weanedSheepIDs = Set(weanings.lazy.filter { !$0.isDeleted }.map(\.sheepID))
        let weaningFactsBySheep = Dictionary(grouping: weanings, by: \.sheepID)
        let pensByID = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0) })
        let validPenIDs = Set(pens.lazy.filter { $0.isActive && !$0.isDeleted }.map(\.id))
        let activeEwesByID = Dictionary(uniqueKeysWithValues: activeSheep.lazy
            .filter { $0.sex == .ewe }
            .map { ($0.id, $0) })
        let reproductionByEwe = Dictionary(grouping: reproduction, by: \.eweID)
        let validLambingRecordIDs = Set(reproduction.lazy
            .filter { !$0.isDeleted && $0.kind == .lambing }
            .map(\.id))
        var effectiveLambingOffspringBySheep: [UUID: [LambingOffspring]] = [:]
        for offspring in lambingOffspring where
            !offspring.isDeleted &&
            !offspring.isStillborn &&
            validLambingRecordIDs.contains(offspring.lambingRecordID) {
            guard let sheepID = offspring.sheepID else { continue }
            effectiveLambingOffspringBySheep[sheepID, default: []].append(offspring)
        }
        var alerts: [FarmOperationalAlert] = []
        alerts.reserveCapacity(activeSheep.count / 2)

        for item in activeSheep {
            if let birthAt = item.birthAt,
               !weanedSheepIDs.contains(item.id) {
                let birthDay = calendar.startOfDay(for: birthAt)
                if let dueAt = calendar.date(byAdding: .day, value: weaningAgeDays, to: birthDay),
                   let warningAt = calendar.date(byAdding: .day, value: -warningLeadDays, to: dueAt),
                   let eligibilitySignature = weaningEligibilitySignature(
                       for: item,
                       dueAt: dueAt,
                       configuredAt: operationalAlertsConfiguredAt,
                       calendar: calendar,
                       effectiveLambingOffspring: effectiveLambingOffspringBySheep[item.id] ?? []
                   ),
                   warningAt <= today {
                    let isOverdue = dueAt <= today
                    let kind: FarmOperationalAlertKind = isOverdue ? .weaningOverdue : .weaningDueSoon
                    let phase = isOverdue ? "overdue" : "due-soon"
                    let weaningFactSignature = factSignature(weaningFactsBySheep[item.id] ?? [])
                    let fingerprint = "\(Int(birthDay.timeIntervalSince1970)):\(weaningAgeDays):\(warningLeadDays):\(phase):\(eligibilitySignature):\(weaningFactSignature)"
                    alerts.append(makeAlert(
                        farmID: farmID,
                        kind: kind,
                        subjectID: item.id,
                        sourceEntityID: nil,
                        fingerprint: fingerprint,
                        title: isOverdue
                            ? "\(item.earTag) · 超龄未断奶"
                            : "\(item.earTag) · 断奶即将到期",
                        detail: isOverdue
                            ? "已达到 \(weaningAgeDays) 日龄，尚无有效断奶记录。"
                            : "将在 \(calendar.dateComponents([.day], from: today, to: dueAt).day ?? 0) 天后达到 \(weaningAgeDays) 日龄，尚无有效断奶记录。",
                        dueAt: dueAt,
                        earTag: item.earTag
                    ))
                }
            }

            if item.currentPenID.map({ !validPenIDs.contains($0) }) ?? true {
                let penPart = item.currentPenID?.uuidString.lowercased() ?? "none"
                let penCondition: String
                if let penID = item.currentPenID, let pen = pensByID[penID] {
                    penCondition = "\(pen.revision):\(pen.isActive):\(pen.isDeleted)"
                } else {
                    penCondition = "missing"
                }
                let fingerprint = "\(penPart):\(penCondition):\(item.revision)"
                alerts.append(makeAlert(
                    farmID: farmID,
                    kind: .invalidPen,
                    subjectID: item.id,
                    sourceEntityID: item.currentPenID,
                    fingerprint: fingerprint,
                    title: "\(item.earTag) · 未分有效圈舍",
                    detail: item.currentPenID == nil
                        ? "当前在场羊只尚未分圈。"
                        : "当前圈舍已停用、删除或引用失效。",
                    dueAt: today,
                    earTag: item.earTag
                ))
            }
        }

        for (eweID, ewe) in activeEwesByID {
            let allFacts = reproductionByEwe[eweID] ?? []
            let facts = allFacts.filter { !$0.isDeleted }.sorted(by: reproductionOrder)
            guard let latestBreeding = facts.last(where: { $0.kind == .breeding }) else { continue }
            let laterFacts = facts.filter { $0.occurredAt >= latestBreeding.occurredAt && $0.id != latestBreeding.id }
            guard !laterFacts.contains(where: {
                $0.kind == .pregnancyCheck || $0.kind == .abortion || $0.kind == .lambing
            }) else { continue }
            let breedingDay = calendar.startOfDay(for: latestBreeding.occurredAt)
            guard let dueAt = calendar.date(byAdding: .day, value: rule.pregnancyCheckDays, to: breedingDay),
                  let warningAt = calendar.date(byAdding: .day, value: -warningLeadDays, to: dueAt),
                  warningAt <= today else { continue }
            let isOverdue = dueAt <= today
            let kind: FarmOperationalAlertKind = isOverdue ? .pregnancyCheckOverdue : .pregnancyCheckDueSoon
            let phase = isOverdue ? "overdue" : "due-soon"
            let cycleFacts = allFacts.filter {
                $0.occurredAt >= latestBreeding.occurredAt || $0.id == latestBreeding.id
            }
            let fingerprint = "\(latestBreeding.id.uuidString.lowercased()):\(Int(breedingDay.timeIntervalSince1970)):\(rule.pregnancyCheckDays):\(warningLeadDays):\(phase):\(factSignature(cycleFacts))"
            alerts.append(makeAlert(
                farmID: farmID,
                kind: kind,
                subjectID: eweID,
                sourceEntityID: latestBreeding.id,
                fingerprint: fingerprint,
                title: isOverdue
                    ? "\(ewe.earTag) · 配种后逾期未孕检"
                    : "\(ewe.earTag) · 孕检即将到期",
                detail: isOverdue
                    ? "配种后已达到 \(rule.pregnancyCheckDays) 天，尚无后续孕检、流产或产羔记录。"
                    : "还有 \(calendar.dateComponents([.day], from: today, to: dueAt).day ?? 0) 天到孕检期限，尚无后续孕检、流产或产羔记录。",
                dueAt: dueAt,
                earTag: ewe.earTag
            ))
        }

        let activeDeferrals = Dictionary(
            grouping: deferrals.filter {
                $0.deferredUntil > now &&
                    $0.deferredUntil > $0.deferredAt &&
                    $0.deferredUntil.timeIntervalSince($0.deferredAt) <= 8 * 86_400
            },
            by: \.alertID
        )
        alerts.removeAll { alert in
            activeDeferrals[alert.id]?.contains {
                $0.conditionFingerprint == alert.conditionFingerprint
            } == true
        }
        alerts.sort(by: alertOrder)

        return FarmOperationalAlertSnapshot(
            farmID: farmID,
            timeZoneIdentifier: timeZoneIdentifier,
            generatedAt: now,
            rule: rule,
            operationalAlerts: alerts,
            overdueReminders: overdueReminders,
            missingBirthDateCount: missingBirthDateCount
        )
    }

    private static func makeAlert(
        farmID: UUID,
        kind: FarmOperationalAlertKind,
        subjectID: UUID,
        sourceEntityID: UUID?,
        fingerprint: String,
        title: String,
        detail: String,
        dueAt: Date,
        earTag: String
    ) -> FarmOperationalAlert {
        let name = [
            "operational-alert",
            kind.rawValue,
            subjectID.uuidString.lowercased(),
            sourceEntityID?.uuidString.lowercased() ?? "none",
            fingerprint,
        ].joined(separator: ":")
        return FarmOperationalAlert(
            id: StableCloudUUID.derived(namespace: farmID, name: name),
            farmID: farmID,
            kind: kind,
            subjectID: subjectID,
            sourceEntityID: sourceEntityID,
            conditionFingerprint: fingerprint,
            title: title,
            detail: detail,
            dueAt: dueAt,
            earTag: earTag
        )
    }

    private static func alertOrder(_ lhs: FarmOperationalAlert, _ rhs: FarmOperationalAlert) -> Bool {
        if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.earTag != rhs.earTag { return lhs.earTag < rhs.earTag }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func reminderOrder(_ lhs: FarmScheduledReminderSnapshot, _ rhs: FarmScheduledReminderSnapshot) -> Bool {
        if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func reproductionOrder(_ lhs: Reproduction, _ rhs: Reproduction) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// 断奶提醒只面向当前仍处于哺乳阶段的羔羊。历史产羔关系只能补足“未分类”羔羊，
    /// 不能覆盖已经明确进入后备、繁殖、育肥等生产阶段的当前事实。
    private static func weaningEligibilitySignature(
        for sheep: Sheep,
        dueAt: Date,
        configuredAt: Date,
        calendar: Calendar,
        effectiveLambingOffspring: [LambingOffspring]
    ) -> String? {
        let purpose = sheep.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        if purpose == "哺乳羔羊" {
            return "purpose:suckling:\(sheep.revision)"
        }

        guard purpose.isEmpty || purpose == "未分类" else { return nil }

        if !effectiveLambingOffspring.isEmpty {
            return "lambing:\(factSignature(effectiveLambingOffspring)):\(sheep.revision)"
        }

        // 首次启用规则时，只承接尚未到断奶日的未分类年轻羊；不追溯缺少数字化
        // 断奶事实的历史成羊。启用后新建的未分类羊仍可正常进入提醒周期。
        let configuredDay = calendar.startOfDay(for: configuredAt)
        if sheep.createdAt >= configuredAt || dueAt >= configuredDay {
            return "unclassified-current:\(sheep.revision)"
        }
        return nil
    }

    private static func factSignature(_ facts: [Weaning]) -> String {
        guard !facts.isEmpty else { return "none" }
        return facts.map {
            "\($0.id.uuidString.lowercased()):\($0.revision):\($0.isDeleted)"
        }.sorted().joined(separator: ",")
    }

    private static func factSignature(_ facts: [Reproduction]) -> String {
        guard !facts.isEmpty else { return "none" }
        return facts.map {
            "\($0.id.uuidString.lowercased()):\($0.revision):\($0.isDeleted)"
        }.sorted().joined(separator: ",")
    }

    private static func factSignature(_ facts: [LambingOffspring]) -> String {
        guard !facts.isEmpty else { return "none" }
        return facts.map {
            "\($0.id.uuidString.lowercased()):\($0.lambingRecordID.uuidString.lowercased()):\($0.revision):\($0.isStillborn):\($0.isDeleted)"
        }.sorted().joined(separator: ",")
    }
}

actor FarmOperationalAlertSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func availableFarmIDs() throws -> [UUID] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate {
            $0.deletedAt == nil
        })).map(\.id)
    }

    func load(farmID: UUID, now: Date = .now) throws -> FarmOperationalAlertSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate {
            $0.id == farmID && $0.deletedAt == nil
        })).first else {
            throw FarmCommandError.missingRequiredValue("当前牧场")
        }
        guard TimeZone(identifier: farm.timeZoneIdentifier) != nil else {
            throw FarmCommandError.missingRequiredValue("牧场时区")
        }
        let ruleRecord = try context.fetch(FetchDescriptor<FarmCareRuleRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).first
        let rule = ruleRecord.map {
            FarmOperationalAlertRuleSnapshot(
                id: $0.id,
                pregnancyCheckDays: $0.pregnancyCheckDays,
                gestationDays: $0.gestationDays,
                weaningAgeDays: $0.weaningAgeDays,
                warningLeadDays: $0.warningLeadDays,
                operationalAlertsConfiguredAt: $0.operationalAlertsConfiguredAt,
                digestEnabled: $0.alertDigestEnabled,
                digestMinuteOfDay: $0.alertDigestMinuteOfDay
            )
        }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).map {
            FarmOperationalAlertEngine.Sheep(
                id: $0.id,
                earTag: $0.earTag,
                purpose: $0.purpose,
                sex: $0.sex,
                status: $0.status,
                isHistoricalArchive: $0.isHistoricalArchive,
                currentPenID: $0.currentPenID,
                birthAt: $0.birthAt,
                enteredAt: $0.enteredAt,
                createdAt: $0.createdAt,
                revision: $0.revision
            )
        }
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).map {
            FarmOperationalAlertEngine.Pen(
                id: $0.id,
                isActive: $0.isActive,
                revision: $0.revision,
                isDeleted: $0.deletedAt != nil
            )
        }
        let weanings = try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).map {
            FarmOperationalAlertEngine.Weaning(
                id: $0.id,
                sheepID: $0.sheepID,
                revision: $0.revision,
                isDeleted: $0.deletedAt != nil
            )
        }
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).map {
            FarmOperationalAlertEngine.Reproduction(
                id: $0.id,
                eweID: $0.eweID,
                kind: $0.kind,
                occurredAt: $0.occurredAt,
                revision: $0.revision,
                isDeleted: $0.deletedAt != nil
            )
        }
        let lambingOffspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).map {
            FarmOperationalAlertEngine.LambingOffspring(
                id: $0.id,
                lambingRecordID: $0.lambingRecordID,
                sheepID: $0.sheepID,
                isStillborn: $0.isStillborn,
                revision: $0.revision,
                isDeleted: $0.deletedAt != nil
            )
        }
        let reminders = try context.fetch(FetchDescriptor<CareReminderRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).compactMap { record -> FarmScheduledReminderSnapshot? in
            guard record.status == .pending else { return nil }
            return FarmScheduledReminderSnapshot(
                id: record.id,
                kind: record.kind,
                title: record.title,
                dueAt: record.dueAt,
                sheepID: record.sheepID
            )
        }
        let deferrals = try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).map {
            FarmOperationalAlertEngine.Deferral(
                alertID: $0.alertID,
                conditionFingerprint: $0.conditionFingerprint,
                deferredAt: $0.updatedAt,
                deferredUntil: $0.deferredUntil
            )
        }
        try Task.checkCancellation()
        let base = FarmOperationalAlertEngine.evaluate(
            farmID: farmID,
            timeZoneIdentifier: farm.timeZoneIdentifier,
            now: now,
            rule: rule,
            sheep: sheep,
            pens: pens,
            weanings: weanings,
            reproduction: reproduction,
            lambingOffspring: lambingOffspring,
            reminders: reminders,
            deferrals: deferrals
        )
        let tmrSnapshot = try TMRMonitoringEngine.load(
            farmID: farmID,
            localDay: now,
            now: now,
            context: context
        )
        let combinedAlerts = (base.operationalAlerts + TMRMonitoringAlertAdapter.alerts(from: tmrSnapshot))
            .sorted {
                if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
                if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.id.uuidString < $1.id.uuidString
            }
        return FarmOperationalAlertSnapshot(
            farmID: base.farmID,
            timeZoneIdentifier: base.timeZoneIdentifier,
            generatedAt: base.generatedAt,
            rule: base.rule,
            operationalAlerts: combinedAlerts,
            overdueReminders: base.overdueReminders,
            missingBirthDateCount: base.missingBirthDateCount,
            tmrMonitoringConfigured: tmrSnapshot.monitoringConfigured
        )
    }
}
