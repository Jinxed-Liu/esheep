import AppIntents
import SwiftUI
import WidgetKit

struct WidgetFarmEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "牧场")
    static let defaultQuery = WidgetFarmQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct WidgetFarmQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WidgetFarmEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WidgetFarmEntity] {
        FarmWidgetSnapshotStore.load().farms.map { .init(id: $0.farmID, name: $0.name) }
    }
}
struct WidgetProfileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "小组件配置")
    static let defaultQuery = WidgetProfileQuery()
    let id: UUID
    let name: String
    let detail: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(detail)") }
}
struct WidgetProfileQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WidgetProfileEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [WidgetProfileEntity] {
        let farms = FarmWidgetSnapshotStore.load().farms
        return FarmWidgetProfileStore.load().compactMap { profile in
            guard let farm = farms.first(where: { $0.farmID == profile.farmID }) else { return nil }
            return .init(id: profile.id, name: profile.name, detail: "\(farm.name) · \(profile.kind.title)")
        }
    }
}
struct SelectFarmWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "小组件设置"
    static let description = IntentDescription("先在 App 的小组件设置中新建配置，再在这里选择。配置独立保存圈舍、批次、周期与配色。")
    @Parameter(title: "牧场（未选择配置时使用）") var farm: WidgetFarmEntity?
    @Parameter(title: "使用配置") var profile: WidgetProfileEntity?
}

private struct FarmWidgetEntry: TimelineEntry {
    let date: Date
    let farm: FarmWidgetSnapshot.Farm?
    let generatedAt: Date
    let card: FarmWidgetCard
    let isStale: Bool
    var url: URL? {
        guard let farm else { return nil }
        let query = card.profileID.map { "?profile=\($0.uuidString)" } ?? ""
        return URL(string: "esheep://farm/\(farm.farmID.uuidString)/widget/\(card.kind.rawValue)\(query)")
    }
}
private struct FarmWidgetProvider: AppIntentTimelineProvider {
    let kind: FarmWidgetKind
    func placeholder(in context: Context) -> FarmWidgetEntry { preview() }
    func snapshot(for configuration: SelectFarmWidgetIntent, in context: Context) async -> FarmWidgetEntry {
        context.isPreview ? preview() : entry(for: configuration)
    }
    func timeline(for configuration: SelectFarmWidgetIntent, in context: Context) async -> Timeline<FarmWidgetEntry> {
        let first = entry(for: configuration)
        // Explicit expiry entry prevents an old 'today' result from silently
        // staying current across midnight when the app has not run.
        let expires = FarmWidgetSelection.expiry(generatedAt: first.generatedAt,
                                                 timeZoneIdentifier: first.farm?.timeZoneIdentifier ?? "Asia/Shanghai")
        var entries = [first]
        if expires > first.date {
            entries.append(.init(date: expires, farm: first.farm, generatedAt: first.generatedAt, card: first.card, isStale: true))
        }
        return Timeline(entries: entries, policy: .after(.now.addingTimeInterval(15 * 60)))
    }
    private func entry(for configuration: SelectFarmWidgetIntent) -> FarmWidgetEntry {
        let snapshot = FarmWidgetSnapshotStore.load()
        let selected = FarmWidgetSelection.resolve(snapshot: snapshot, profiles: FarmWidgetProfileStore.load(),
                                                   kind: kind, profileID: configuration.profile?.id, farmID: configuration.farm?.id)
        let expires = FarmWidgetSelection.expiry(generatedAt: snapshot.generatedAt,
                                                 timeZoneIdentifier: selected.farm?.timeZoneIdentifier ?? "Asia/Shanghai")
        return .init(date: .now, farm: selected.farm, generatedAt: snapshot.generatedAt, card: selected.card, isStale: .now >= expires)
    }
    private func preview() -> FarmWidgetEntry {
        var card = FarmWidgetCard(kind: kind, palette: kind.defaultPalette, title: kind.title,
                                  subtitle: "当前在场", value: "1,286", unit: "只", note: "示例数据")
        card.rows = [.init(label: "在用圈舍", value: "24 个"), .init(label: "投喂记录", value: "8 条")]
        switch kind {
        case .journal: card.subtitle = "今日投喂记录"; card.value = "8"; card.unit = "条"
        case .breeding: card.subtitle = "未来 7 天预产提醒"; card.value = "6"; card.unit = "条"
        case .pregnancy, .weaning, .alerts: card.subtitle = "待关注提醒"; card.value = "7"; card.unit = "项"
        case .feeding: card.title = "03 舍"; card.subtitle = "已有投喂量"; card.value = "2"; card.unit = "/ 3 顿"; card.progress = 2.0 / 3
        case .coverage: card.title = "03 舍 · 近 7 天"; card.subtitle = "当前名单 · 已称重"; card.value = "86"; card.unit = "/ 100 只"; card.progress = 0.86
        case .gain: card.title = "秋季育肥批次"; card.subtitle = "期间平均日增重"; card.value = "280"; card.unit = "g/天"
        case .sync: card.subtitle = "本机待同步指令"; card.value = "2"; card.unit = "项"
        default: break
        }
        if kind == .gain || kind == .coverage { card.rows = [.init(label: "可计算 / 期间对象", value: "72 / 100 只"), .init(label: "当前名单已称重", value: "86 / 100 只")] }
        if kind == .feeding { card.rows = [.init(label: "早 · 实投", value: "120 kg"), .init(label: "中 · 实投", value: "116 kg"), .init(label: "晚 · 目标", value: "120 kg")] }
        if [.breeding, .pregnancy, .weaning, .alerts].contains(kind) { card.rows = [.init(label: "今日到期", value: "4 项"), .init(label: "已逾期", value: "2 项")] }
        return .init(date: .now, farm: nil, generatedAt: .now, card: card, isStale: false)
    }
}
private struct FarmWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FarmWidgetEntry
    var body: some View {
        FarmWidgetCardView(card: entry.card, farmName: entry.farm?.name ?? "示例牧场", generatedAt: entry.generatedAt,
                           timeZoneIdentifier: entry.farm?.timeZoneIdentifier ?? "Asia/Shanghai",
                           medium: family == .systemMedium, stale: entry.isStale)
            .containerBackground(for: .widget) { FarmWidgetBackground(palette: entry.card.palette) }
            .widgetURL(entry.url)
    }
}
struct FarmConfiguredWidget: Widget {
    let category: FarmWidgetKind
    init() { category = .overview }
    init(category: FarmWidgetKind) { self.category = category }
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: category == .overview ? "FarmOverviewWidget" : "FarmWidget.\(category.rawValue)",
                               intent: SelectFarmWidgetIntent.self, provider: FarmWidgetProvider(kind: category)) { entry in
            FarmWidgetView(entry: entry)
        }
        .configurationDisplayName(category.title)
        .description(category.detail)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
@main
struct ESheepNextWidgetBundle: WidgetBundle {
    var body: some Widget {
        FarmConfiguredWidget(category: .overview)
        FarmConfiguredWidget(category: .journal)
        FarmConfiguredWidget(category: .duty)
        FarmConfiguredWidget(category: .breeding)
        FarmConfiguredWidget(category: .pregnancy)
        FarmConfiguredWidget(category: .weaning)
        FarmConfiguredWidget(category: .feeding)
        FarmConfiguredWidget(category: .coverage)
        FarmConfiguredWidget(category: .gain)
        FarmConfiguredWidget(category: .alerts)
        FarmConfiguredWidget(category: .sync)
    }
}
