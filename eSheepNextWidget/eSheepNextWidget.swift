import AppIntents
import SwiftUI
import WidgetKit

private struct WidgetSnapshot: Codable {
    struct Farm: Codable, Identifiable {
        let farmID: UUID
        let name: String
        let activeSheepCount: Int
        let activePenCount: Int
        let todayFeedCount: Int
        let pendingOperationCount: Int

        var id: UUID { farmID }
    }

    let version: Int
    let generatedAt: Date
    let selectedFarmID: UUID?
    let farms: [Farm]
}

private enum WidgetSnapshotStore {
    static func load() -> WidgetSnapshot? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String,
              let defaults = UserDefaults(suiteName: group),
              let data = defaults.data(forKey: "farm-widget-snapshot-v1") else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

struct WidgetFarmEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "牧场")
    static let defaultQuery = WidgetFarmQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WidgetFarmQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WidgetFarmEntity] {
        let identifiers = Set(identifiers)
        return (WidgetSnapshotStore.load()?.farms ?? []).compactMap {
            identifiers.contains($0.farmID) ? WidgetFarmEntity(id: $0.farmID, name: $0.name) : nil
        }
    }

    func suggestedEntities() async throws -> [WidgetFarmEntity] {
        (WidgetSnapshotStore.load()?.farms ?? []).map { WidgetFarmEntity(id: $0.farmID, name: $0.name) }
    }
}

struct SelectFarmWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "选择牧场"
    static let description = IntentDescription("选择要在小组件中显示的牧场。")

    @Parameter(title: "牧场") var farm: WidgetFarmEntity?
}

private struct FarmWidgetEntry: TimelineEntry {
    let date: Date
    let farm: WidgetSnapshot.Farm?
    let isStale: Bool
}

private struct FarmWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FarmWidgetEntry {
        FarmWidgetEntry(date: .now, farm: nil, isStale: false)
    }

    func snapshot(for configuration: SelectFarmWidgetIntent, in context: Context) async -> FarmWidgetEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectFarmWidgetIntent, in context: Context) async -> Timeline<FarmWidgetEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .after(.now.addingTimeInterval(15 * 60)))
    }

    private func entry(for configuration: SelectFarmWidgetIntent) -> FarmWidgetEntry {
        guard let snapshot = WidgetSnapshotStore.load() else {
            return FarmWidgetEntry(date: .now, farm: nil, isStale: true)
        }
        let requestedID = configuration.farm?.id ?? snapshot.selectedFarmID
        let farm = snapshot.farms.first(where: { $0.farmID == requestedID }) ?? snapshot.farms.first
        return FarmWidgetEntry(
            date: .now,
            farm: farm,
            isStale: Date.now.timeIntervalSince(snapshot.generatedAt) > 60 * 60
        )
    }
}

private struct FarmWidgetView: View {
    let entry: FarmWidgetEntry

    var body: some View {
        if let farm = entry.farm {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(farm.name).font(.headline).lineLimit(1)
                    Spacer()
                    if entry.isStale { Image(systemName: "clock.badge.exclamationmark") }
                }
                HStack {
                    metric("羊只", farm.activeSheepCount)
                    metric("圈舍", farm.activePenCount)
                    metric("投喂", farm.todayFeedCount)
                }
                if farm.pendingOperationCount > 0 {
                    Label("\(farm.pendingOperationCount) 项待同步", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .widgetURL(URL(string: "esheep://farm/\(farm.farmID.uuidString.lowercased())/home"))
        } else {
            ContentUnavailableView("选择牧场", systemImage: "building.2", description: Text("打开 eSheep+ 后配置小组件。"))
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FarmOverviewWidget: Widget {
    let kind = "FarmOverviewWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectFarmWidgetIntent.self, provider: FarmWidgetProvider()) { entry in
            FarmWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("牧场概览")
        .description("查看所选牧场的羊只、圈舍、今日投喂和待同步数量。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ESheepNextWidgetBundle: WidgetBundle {
    var body: some Widget { FarmOverviewWidget() }
}
