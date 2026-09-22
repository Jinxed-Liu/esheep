import Foundation
import SwiftData

/// All production calculations happen in the app's background snapshot pipeline.
/// The extension only decodes these compact, read-only results.
enum FarmWidgetSnapshotBuilder {
    static func enrich(
        _ base: FarmWidgetSnapshot.Farm, farm: FarmRecord, context: ModelContext,
        container: ModelContainer, now: Date = .now, isolation: isolated (any Actor)? = #isolation
    ) async throws -> FarmWidgetSnapshot.Farm {
        let farmID = farm.id
        let timeZoneID = farm.timeZoneIdentifier
        let canAnalyze = CapabilitySet(role: farm.role).allows(.viewAnalytics)
        var result = base
        result.timeZoneIdentifier = timeZoneID
        let profiles = FarmWidgetProfileStore.load().filter { $0.farmID == farmID }
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate { $0.farmID == farmID && $0.deletedAt == nil }))
        var scopes = pens.filter(\.isActive).map { FarmWidgetSnapshot.ScopeOption(id: $0.id, name: $0.name, kind: .pen) }
        let analytics: FarmDeepAnalyticsPayload?
        if profiles.contains(where: { $0.kind.needsWeightScope }), canAnalyze {
            analytics = try await FarmDeepAnalyticsSnapshotActor(container: container).load(farmID: farmID, now: now)
        } else { analytics = nil }
        // Batch names are lightweight; analytics is loaded only for configured weight cards.
        let batches = try context.fetch(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate { $0.farmID == farmID && $0.deletedAt == nil }))
        scopes += batches.map { .init(id: $0.id, name: $0.name, kind: .batch) }
        result.widgetScopes = scopes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let reminders = try context.fetch(FetchDescriptor<CareReminderRecord>(predicate: #Predicate { $0.farmID == farmID && $0.deletedAt == nil }))
        let alerts = try await FarmOperationalAlertSnapshotActor(container: container).load(farmID: farmID, now: now)
        let feeding = profiles.contains(where: { $0.kind == .feeding })
            ? try TMRMonitoringEngine.load(farmID: farmID, localDay: now, now: now, context: context) : nil
        var cards = FarmWidgetKind.allCases.map { kind in
            defaultCard(kind: kind, farm: base, reminders: reminders, alerts: alerts, timeZoneID: timeZoneID, now: now)
        }
        for profile in profiles {
            try Task.checkCancellation()
            var card = defaultCard(kind: profile.kind, farm: base, reminders: reminders, alerts: alerts, timeZoneID: timeZoneID, now: now)
            if profile.kind.needsScope {
                if let scopeID = profile.scopeID,
                   let scope = scopes.first(where: { $0.id == scopeID && $0.kind == profile.scope }),
                   profile.kind != .feeding || profile.scope == .pen {
                    if profile.kind.needsWeightScope {
                        if let analytics, canAnalyze {
                            card = weightCard(profile: profile, scopeName: scope.name, snapshot: analytics.snapshot, now: now)
                        } else {
                            card = .waiting(kind: profile.kind, message: "当前角色无权查看生产分析")
                        }
                    } else if let feeding {
                        card = feedingCard(profile: profile, name: scope.name, snapshot: feeding)
                    }
                } else {
                    card = .waiting(kind: profile.kind, message: "请在小组件设置中选择有效的圈舍或批次")
                }
            }
            card.profileID = profile.id
            card.profileRevision = profile.revision
            card.palette = profile.palette
            cards.append(card)
        }
        result.cards = cards
        return result
    }

    static func defaultCard(
        kind: FarmWidgetKind, farm: FarmWidgetSnapshot.Farm, reminders: [CareReminderRecord],
        alerts: FarmOperationalAlertSnapshot, timeZoneID: String, now: Date
    ) -> FarmWidgetCard {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var card = FarmWidgetCard(kind: kind, palette: kind.defaultPalette, title: kind.title,
                                  subtitle: "当前在场", value: "\(farm.activeSheepCount)", unit: "只", note: "今日投喂按记录条数统计")
        card.rows = [.init(label: "在用圈舍", value: "\(farm.activePenCount) 个"), .init(label: "今日投喂", value: "\(farm.todayFeedCount) 条")]
        switch kind {
        case .overview, .duty:
            card.note = farm.pendingOperationCount > 0 ? "\(farm.pendingOperationCount) 项指令待同步" : "本机数据快照"
        case .journal:
            card.subtitle = "今日投喂记录"
            card.value = "\(farm.todayFeedCount)"; card.unit = "条"
            card.rows = [.init(label: "当前在场", value: "\(farm.activeSheepCount) 只"), .init(label: "在用圈舍", value: "\(farm.activePenCount) 个")]
        case .breeding:
            let end = calendar.date(byAdding: .day, value: 7, to: today)!
            let due = reminders.filter { $0.kind == .expectedLambing && $0.status == .pending && $0.dueAt >= today && $0.dueAt < end }
            card.subtitle = "未来 7 天预产提醒"; card.value = "\(due.count)"; card.unit = "条"
            card.upcomingDates = due.map(\.dueAt).sorted()
            card.note = "预产日期为估算 · 按提醒条数"
            card.rows = [.init(label: "今日预产提醒", value: "\(due.count { $0.dueAt < tomorrow }) 条"),
                         .init(label: "涉及母羊", value: "\(Set(due.compactMap(\.sheepID)).count) 只")]
        case .pregnancy, .weaning:
            guard alerts.rule?.isConfigured == true else { return .waiting(kind: kind, message: "请先配置待办与异常规则") }
            let soon: FarmOperationalAlertKind = kind == .pregnancy ? .pregnancyCheckDueSoon : .weaningDueSoon
            let overdue: FarmOperationalAlertKind = kind == .pregnancy ? .pregnancyCheckOverdue : .weaningOverdue
            let soonCount = alerts.operationalAlerts.count { $0.kind == soon }
            let lateCount = alerts.operationalAlerts.count { $0.kind == overdue }
            card.subtitle = "到期与逾期提醒"; card.value = "\(soonCount + lateCount)"; card.unit = "项"
            card.rows = [.init(label: "即将到期", value: "\(soonCount) 项"), .init(label: "已逾期", value: "\(lateCount) 项")]
            card.note = "沿用牧场已配置的提醒规则"
        case .alerts:
            guard alerts.isConfigured else { return .waiting(kind: kind, message: "请先配置待办与异常规则") }
            card.subtitle = "待办与异常"; card.value = "\(alerts.totalPendingCount)"; card.unit = "项"
            card.rows = [.init(label: "生产异常", value: "\(alerts.operationalAlerts.count) 项"), .init(label: "逾期提醒", value: "\(alerts.overdueReminders.count) 项")]
            card.note = "按提醒条数 · 非去重羊只数"
        case .sync:
            card.subtitle = "本机待同步指令"; card.value = "\(farm.pendingOperationCount)"; card.unit = "项"
            card.rows = [.init(label: "数据来源", value: "本机快照"), .init(label: "云端状态", value: "进入 App 查看")]
            card.note = "不包含照片传输 · 非云端确认"
        case .coverage, .gain, .feeding:
            return .waiting(kind: kind, message: "在 App 小组件设置中新建配置，再长按桌面小组件选择")
        }
        return card
    }

    static func weightCard(profile: FarmWidgetProfile, scopeName: String, snapshot: FarmAnalyticsSnapshot, now: Date, gainResult: WeightGainAnalysisResult? = nil) -> FarmWidgetCard {
        let range = profile.dateRange(now: now, timeZoneIdentifier: snapshot.timeZoneIdentifier)
        guard profile.scopeID != nil else { return .waiting(kind: profile.kind) }
        let coverage = currentCoverage(profile: profile, snapshot: snapshot, now: now)
        var card = FarmWidgetCard(kind: profile.kind, palette: profile.palette, title: scopeName,
                                 subtitle: profile.kind == .coverage ? "当前在场羊只 · 已称重" : "期间平均日增重",
                                 value: "", unit: "", note: "")
        card.rangeStart = range.start; card.rangeEnd = range.end
        if profile.kind == .coverage {
            card.value = "\(coverage.weighed)"; card.unit = "/ \(coverage.total) 只"
            card.progress = coverage.total > 0 ? Double(coverage.weighed) / Double(coverage.total) : nil
            card.rows = [.init(label: "尚未称重", value: "\(coverage.total - coverage.weighed) 只"), .init(label: "当前在场", value: "\(coverage.total) 只")]
            card.note = "当前名单 · 期间有效称重去重"
        } else {
            let filter = weightFilter(profile: profile, snapshot: snapshot, now: now)
            let gain = gainResult ?? WeightGainAnalyticsEngine.calculate(snapshot: snapshot, filter: filter)
            card.value = gain.averageDailyGainGrams.map { String(format: "%.0f", $0) } ?? "—"
            card.unit = gain.averageDailyGainGrams == nil ? "" : "g/天"
            card.rows = [.init(label: "可计算 / 期间对象", value: "\(gain.calculableCount) / \(gain.objectCount) 只"),
                         .init(label: "当前名单已称重", value: "\(coverage.weighed) / \(coverage.total) 只")]
            card.note = gain.averageDailyGainGrams == nil ? "有效称重不足，不以 0 代替" : (profile.scope == .pen ? "连续在舍区间 · 逐羊等权平均" : "批次期间表现 · 逐羊等权平均")
        }
        return card
    }

    static func weightFilter(profile: FarmWidgetProfile, snapshot: FarmAnalyticsSnapshot, now: Date) -> WeightGainAnalysisFilter {
        let range = profile.dateRange(now: now, timeZoneIdentifier: snapshot.timeZoneIdentifier)
        return .init(scope: profile.scope == .pen ? .pen(profile.scopeID!) : .batch(profile.scopeID!),
                     startDate: range.start, endDate: range.end,
                     population: profile.scope == .pen ? .inPen : .wholeObject)
    }

    static func currentCoverage(profile: FarmWidgetProfile, snapshot: FarmAnalyticsSnapshot, now: Date) -> (total: Int, weighed: Int) {
        let members = coverageMembers(profile: profile, snapshot: snapshot, now: now)
        return (members.current.count, members.weighed.count)
    }

    static func coverageMembers(profile: FarmWidgetProfile, snapshot: FarmAnalyticsSnapshot, now: Date) -> (current: Set<UUID>, weighed: Set<UUID>) {
        let range = profile.dateRange(now: now, timeZoneIdentifier: snapshot.timeZoneIdentifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .gmt
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: range.end)!
        let members = Set(snapshot.batchMemberships.filter {
            $0.batchID == profile.scopeID && $0.joinedAt <= now && ($0.leftAt == nil || $0.leftAt! > now)
        }.map(\.sheepID))
        let current = Set(snapshot.sheep.filter {
            $0.isCurrentlyPresent && (profile.scope == .pen ? $0.currentPenID == profile.scopeID : members.contains($0.id))
        }.map(\.id))
        let weighed = Set(snapshot.weightSamples.filter {
            current.contains($0.sheepID) && $0.kilograms.isFinite && $0.kilograms > 0 &&
            $0.occurredAt >= range.start && $0.occurredAt < endExclusive && $0.occurredAt <= now
        }.map(\.sheepID))
        return (current, weighed)
    }

    static func feedingCard(profile: FarmWidgetProfile, name: String, snapshot: TMRMonitoringSnapshot) -> FarmWidgetCard {
        let rows = snapshot.rows.filter { $0.penID == profile.scopeID && $0.planID != nil }
        guard !rows.isEmpty else { return .waiting(kind: .feeding, message: "\(name) 今天没有有效饲喂计划") }
        // A meal can contain multiple formula rows; count each scheduled meal only once.
        let meals = Dictionary(grouping: rows, by: \.meal)
        let recorded = meals.values.count { $0.allSatisfy { $0.actualKilograms > 0 } }
        let unit = meals.keys.contains(.allDaySummary) ? "项" : "顿"
        var card = FarmWidgetCard(kind: .feeding, palette: profile.palette, title: name, subtitle: "计划中已有投喂量的项目",
                                 value: "\(recorded)", unit: "/ \(meals.count) \(unit)", note: "记录覆盖不代表投喂达标")
        card.progress = Double(recorded) / Double(meals.count)
        card.rows = meals.keys.sorted { $0.sortOrder < $1.sortOrder }.map { meal in
            let entries = meals[meal]!
            let actual = entries.reduce(Decimal.zero) { $0 + $1.actualKilograms }
            let target = entries.reduce(Decimal.zero) { $0 + ($1.targetKilograms ?? 0) }
            return .init(label: meal.displayName + " · 实投/目标", value: "\(actual.stableText)/\(target.stableText) kg")
        }
        return card
    }
}
