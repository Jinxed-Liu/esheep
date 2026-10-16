import Foundation

enum ReproductionPenUsage: String, CaseIterable, Codable, Sendable, Identifiable {
    case breeding = "繁殖母羊"
    case replacement = "后备母羊"
    case lambing = "产羔／哺乳"
    case lamb = "羔羊"
    case fattening = "育肥"
    case ram = "种公羊"
    case isolation = "隔离"
    case mixed = "综合"
    case unspecified = "未设置"

    var id: String { rawValue }
}

/// Farm-shared settings, carried by the existing audited care-rule command.
/// Pen selection is explicit: selecting a group never opts future pens in.
struct ReproductionManagementSettings: Codable, Equatable, Sendable {
    var penUsages: [String: ReproductionPenUsage] = [:]
    var selectedPenIDs: [UUID] = []
    var youthBreedingConfirmedSheepIDs: [UUID] = []
    var scopeConfigured = false
    var minimumAgeMonths = 10
    var postpartumReminderDays: Int?
    var postpartumWarningDays: Int?
    var maidenReminderMonths: Int?
    var maidenWarningMonths: Int?

    var hasPostpartumRule: Bool { postpartumReminderDays != nil && postpartumWarningDays != nil }
    var hasMaidenRule: Bool { maidenReminderMonths != nil && maidenWarningMonths != nil }
    var hasThresholdRules: Bool { hasPostpartumRule || hasMaidenRule }

    func usage(for penID: UUID) -> ReproductionPenUsage {
        penUsages[penID.uuidString.lowercased()] ?? .unspecified
    }

    mutating func setUsage(_ usage: ReproductionPenUsage, for penID: UUID) {
        penUsages[penID.uuidString.lowercased()] = usage
    }

    func validated() throws -> Self {
        guard (1...120).contains(minimumAgeMonths),
              Set(selectedPenIDs).count == selectedPenIDs.count,
              Set(youthBreedingConfirmedSheepIDs).count == youthBreedingConfirmedSheepIDs.count,
              Set(penUsages.keys.map { $0.lowercased() }).count == penUsages.count,
              penUsages.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw FarmCommandError.invalidNumber("繁殖分析范围或统计月龄")
        }
        switch (postpartumReminderDays, postpartumWarningDays) {
        case (nil, nil): break
        case let (reminder?, warning?) where (1...5_000).contains(reminder) && reminder < warning && warning <= 5_000: break
        default: throw FarmCommandError.invalidNumber("产后提醒与警告天数，警告须大于提醒")
        }
        switch (maidenReminderMonths, maidenWarningMonths) {
        case (nil, nil): break
        case let (reminder?, warning?) where minimumAgeMonths <= reminder && reminder < warning && warning <= 120: break
        default: throw FarmCommandError.invalidNumber("未产羔月龄规则，提醒不得早于统计月龄且警告须大于提醒")
        }
        var result = self
        result.selectedPenIDs.sort { $0.uuidString < $1.uuidString }
        result.youthBreedingConfirmedSheepIDs.sort { $0.uuidString < $1.uuidString }
        result.penUsages = Dictionary(uniqueKeysWithValues: penUsages.map { ($0.key.lowercased(), $0.value) })
        return result
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(validated()), as: UTF8.self)
    }

    static func decode(_ json: String?) throws -> Self? {
        guard let json else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8)).validated()
    }

    func remappingIDs(_ transform: (UUID) -> UUID) -> Self {
        var result = self
        result.selectedPenIDs = selectedPenIDs.map(transform)
        result.youthBreedingConfirmedSheepIDs = youthBreedingConfirmedSheepIDs.map(transform)
        result.penUsages = Dictionary(uniqueKeysWithValues: penUsages.compactMap { key, usage in
            UUID(uuidString: key).map { (transform($0).uuidString.lowercased(), usage) }
        })
        return result
    }
}

enum ReproductionEweCategory: String, CaseIterable, Sendable, Identifiable {
    case young = "青年母羊"
    case firstParity = "头胎母羊"
    case multiparous = "经产母羊"
    case pendingReadiness = "待确认参配"
    case immature = "未达参配月龄"
    case uncertain = "胎次待核实"
    var id: String { rawValue }
}

enum ReproductionPostpartumBand: Int, CaseIterable, Sendable, Identifiable {
    case days0To30, days31To60, days61To90, days91To120
    case days121To150, days151To180, days181To210, over210

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .days0To30: "0–30 天"
        case .days31To60: "31–60 天"
        case .days61To90: "61–90 天"
        case .days91To120: "91–120 天"
        case .days121To150: "121–150 天"
        case .days151To180: "151–180 天"
        case .days181To210: "181–210 天"
        case .over210: "大于 210 天"
        }
    }

    static func containing(_ days: Int) -> Self? {
        guard days >= 0 else { return nil }
        if days == 0 { return .days0To30 }
        return Self(rawValue: min((days - 1) / 30, 7))
    }
}

enum ReproductionPregnancyState: String, CaseIterable, Sendable, Identifiable {
    case pregnant = "检胎已孕"
    case open = "检胎空怀"
    case recheck = "待复检"
    case unexamined = "本轮未检胎"
    case uncertain = "结果待核实"

    var id: String { rawValue }

    /// Exact known values only. Unknown source text is retained for review.
    static func classify(_ result: String) -> Self {
        switch result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "已孕", "怀孕", "孕", "妊娠", "阳性", "pregnant", "positive": .pregnant
        case "空怀", "未孕", "未怀孕", "阴性", "不孕", "open", "negative": .open
        case "复检", "待复检", "疑似", "疑似怀孕", "待定", "recheck": .recheck
        default: .uncertain
        }
    }
}

enum ReproductionConcernSeverity: Int, Sendable, Comparable {
    case review, reminder, warning
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var title: String {
        switch self {
        case .review: "待核实"
        case .reminder: "提醒"
        case .warning: "警告"
        }
    }
}

struct ReproductionManagementConcern: Sendable, Hashable {
    enum Kind: String, Sendable { case postpartum, maiden, breeding, review, recheck }
    let kind: Kind
    let severity: ReproductionConcernSeverity
    let detail: String
    let dueAt: Date
}

struct ReproductionCareRuleSnapshot: Sendable {
    let id: UUID
    let revision: Int
    let pregnancyCheckDays: Int
    let warningLeadDays: Int
    let operationalRulesConfigured: Bool
}
