import Foundation

/// Shared by the app and WidgetKit. Configuration is local presentation state,
/// never a second source of truth for farm records.
enum FarmWidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case overview, journal, duty, breeding, pregnancy, weaning, feeding, coverage, gain, alerts, sync
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "晨雾牧场"
        case .journal: "牧场手账"
        case .duty: "数字值班台"
        case .breeding: "繁育日历"
        case .pregnancy: "孕检提醒"
        case .weaning: "断奶提醒"
        case .feeding: "饲喂安排"
        case .coverage: "称重覆盖"
        case .gain: "增重表现"
        case .alerts: "牧场待办"
        case .sync: "同步状态"
        }
    }
    var symbol: String {
        switch self {
        case .overview, .duty: "building.2.crop.circle"
        case .journal: "book.closed"
        case .breeding: "calendar.badge.clock"
        case .pregnancy: "heart.text.square"
        case .weaning: "leaf"
        case .feeding: "fork.knife"
        case .coverage: "scalemass"
        case .gain: "chart.xyaxis.line"
        case .alerts: "checklist"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
    var detail: String {
        switch self {
        case .overview: "当前在场羊只、在用圈舍和今日投喂记录。"
        case .journal: "以今日投喂记录为主角的牧场手账。"
        case .duty: "集中查看存栏、投喂记录与待同步操作。"
        case .breeding: "未来 7 天的预产提醒，预产日期为估算。"
        case .pregnancy: "查看即将到期和逾期的孕检提醒。"
        case .weaning: "查看即将到期和超龄未断奶提醒。"
        case .feeding: "指定圈舍今日各顿的目标与实际投喂量。"
        case .coverage: "指定圈舍或批次当前在场羊只的称重覆盖情况。"
        case .gain: "指定圈舍或批次的期间日增重与有效样本。"
        case .alerts: "生产待办与异常，按提醒条数统计。"
        case .sync: "待同步操作数量，不将本地快照误报为云端确认。"
        }
    }
    var needsWeightScope: Bool { self == .coverage || self == .gain }
    var needsScope: Bool { needsWeightScope || self == .feeding }
    var defaultPalette: FarmWidgetPalette {
        switch self {
        case .journal: .paper
        case .duty, .coverage, .gain, .sync: .blue
        case .breeding, .pregnancy: .rose
        case .alerts: .amber
        default: .sage
        }
    }
}

enum FarmWidgetPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case sage, paper, blue, rose, amber
    case emerald, coral, twilight, lemon
    var id: String { rawValue }
    var title: String {
        switch self { case .sage: "晨雾绿"; case .paper: "暖纸色"; case .blue: "雾蓝色"; case .rose: "柔粉色"; case .amber: "麦穗金"
        case .emerald: "翡翠原野"; case .coral: "珊瑚日历"; case .twilight: "暮光生长"; case .lemon: "柠檬饲喂"
        }
    }
    static let colorful: [Self] = [.emerald, .coral, .twilight, .lemon]
    var isColorful: Bool { Self.colorful.contains(self) }
    var suggestedKind: FarmWidgetKind {
        switch self {
        case .coral: .breeding
        case .twilight: .gain
        case .lemon: .feeding
        default: .overview
        }
    }
}

enum FarmWidgetScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case pen, batch
    var id: String { rawValue }
    var title: String { self == .pen ? "圈舍" : "批次" }
}

enum FarmWidgetPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case week, month, custom
    var id: String { rawValue }
    var title: String { switch self { case .week: "近 7 天"; case .month: "近 30 天"; case .custom: "固定日期范围" } }
}

struct FarmWidgetProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var farmID: UUID
    var name: String
    var kind: FarmWidgetKind
    var palette: FarmWidgetPalette
    var scope: FarmWidgetScope = .pen
    var scopeID: UUID?
    var period: FarmWidgetPeriod = .week
    var startDate: Date = .now
    var endDate: Date = .now
    // A changed profile must not display a result from an earlier configuration.
    var revision = UUID()

    func dateRange(now: Date, timeZoneIdentifier: String) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let today = calendar.startOfDay(for: now)
        if period == .custom {
            return (calendar.startOfDay(for: min(startDate, endDate)), calendar.startOfDay(for: max(startDate, endDate)))
        }
        return (calendar.date(byAdding: .day, value: period == .week ? -6 : -29, to: today)!, today)
    }
}

struct FarmWidgetCard: Codable, Equatable, Identifiable, Sendable {
    struct Row: Codable, Equatable, Identifiable, Sendable {
        var id: String { label }
        let label: String
        let value: String
    }
    var id: String { profileID?.uuidString ?? kind.rawValue }
    var profileID: UUID?
    var profileRevision: UUID?
    var kind: FarmWidgetKind
    var palette: FarmWidgetPalette
    var title: String
    var subtitle: String
    var value: String
    var unit: String
    var note: String
    var rows: [Row] = []
    var progress: Double?
    var unavailable = false
    var rangeStart: Date?
    var rangeEnd: Date?
    var upcomingDates: [Date]?

    static func waiting(kind: FarmWidgetKind, message: String = "打开 App 配置小组件") -> Self {
        Self(kind: kind, palette: kind.defaultPalette, title: kind.title, subtitle: "尚未就绪", value: "—", unit: "", note: message, unavailable: true)
    }
}

enum FarmWidgetProfileStore {
    static let changeNotification = Notification.Name("FarmWidgetProfilesDidChange")
    private static let key = "farm-widget-profiles-v1"
    static func load() -> [FarmWidgetProfile] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([FarmWidgetProfile].self, from: data)) ?? []
    }
    static func save(_ profiles: [FarmWidgetProfile]) throws {
        guard let defaults else { throw CocoaError(.fileWriteNoPermission) }
        defaults.set(try JSONEncoder().encode(profiles), forKey: key)
        NotificationCenter.default.post(name: changeNotification, object: nil)
    }
    private static var defaults: UserDefaults? {
        AppGroupConfiguration.identifier.flatMap(UserDefaults.init(suiteName:))
    }
}

/// Resolve against the currently authorized farm snapshot; never silently switch scope.
enum FarmWidgetSelection {
    static func resolve(snapshot: FarmWidgetSnapshot, profiles: [FarmWidgetProfile], kind: FarmWidgetKind,
                        profileID: UUID?, farmID: UUID?) -> (farm: FarmWidgetSnapshot.Farm?, card: FarmWidgetCard) {
        let selected = profileID.flatMap { id in profiles.first { $0.id == id } }
        let requested = selected?.farmID ?? farmID ?? snapshot.selectedFarmID
        let farm = snapshot.farms.first { $0.farmID == requested }
        guard let farm else { return (nil, .waiting(kind: kind, message: "请打开 App 登录并选择可访问的牧场")) }
        if profileID != nil && selected == nil {
            return (farm, .waiting(kind: kind, message: "配置已删除，请长按小组件重新选择"))
        }
        if let selected {
            guard selected.kind == kind else { return (farm, .waiting(kind: kind, message: "请选择「\(kind.title)」类型的配置")) }
            let card = farm.cards?.first { $0.profileID == selected.id && $0.profileRevision == selected.revision }
                ?? .waiting(kind: kind, message: "配置已更新，打开 App 生成最新快照")
            return (farm, card)
        }
        return (farm, farm.cards?.first { $0.kind == kind && $0.profileID == nil } ?? .waiting(kind: kind))
    }

    static func expiry(generatedAt: Date, timeZoneIdentifier: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: generatedAt))!
        return min(generatedAt.addingTimeInterval(3600), midnight)
    }
}
