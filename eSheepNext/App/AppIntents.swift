import AppIntents

struct FarmIntentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "牧场")
    static let defaultQuery = FarmIntentEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct FarmIntentEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [FarmIntentEntity] {
        let identifiers = Set(identifiers)
        return FarmWidgetSnapshotStore.load().farms.compactMap {
            identifiers.contains($0.farmID) ? FarmIntentEntity(id: $0.farmID, name: $0.name) : nil
        }
    }

    func suggestedEntities() async throws -> [FarmIntentEntity] {
        FarmWidgetSnapshotStore.load().farms.map { FarmIntentEntity(id: $0.farmID, name: $0.name) }
    }
}

struct PenIntentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "圈舍")
    static let defaultQuery = PenIntentEntityQuery()

    let id: String
    let farmID: UUID
    let penID: UUID
    let name: String
    let farmName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(farmName)")
    }
}

struct PenIntentEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PenIntentEntity] {
        let identifiers = Set(identifiers)
        return allEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PenIntentEntity] { allEntities() }

    private func allEntities() -> [PenIntentEntity] {
        FarmWidgetSnapshotStore.load().farms.flatMap { farm in
            farm.pens.map {
                PenIntentEntity(id: $0.id, farmID: farm.farmID, penID: $0.penID, name: $0.name, farmName: farm.name)
            }
        }
    }
}

struct OpenESheepIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 eSheep+"
    static let description = IntentDescription("打开 eSheep+ 并继续使用当前牧场。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppNavigationRequest.enqueue(.home)
        return .result()
    }
}

struct SearchSheepIntent: AppIntent {
    static let title: LocalizedStringResource = "搜索羊只"
    static let description = IntentDescription("在指定牧场中按耳号或品种搜索羊只。")
    static let openAppWhenRun = true

    @Parameter(title: "牧场") var farm: FarmIntentEntity
    @Parameter(title: "耳号或品种") var query: String

    func perform() async throws -> some IntentResult {
        FarmSystemNavigationStore.enqueue(.init(farmID: farm.id, kind: .searchSheep, entityID: nil, query: query))
        return .result(dialog: "正在打开\(farm.name)的羊只搜索。")
    }
}

struct OpenPenIntent: AppIntent {
    static let title: LocalizedStringResource = "打开圈舍"
    static let description = IntentDescription("打开指定牧场的圈舍。")
    static let openAppWhenRun = true

    @Parameter(title: "圈舍") var pen: PenIntentEntity

    func perform() async throws -> some IntentResult {
        FarmSystemNavigationStore.enqueue(.init(farmID: pen.farmID, kind: .openPen, entityID: pen.penID, query: pen.name))
        return .result(dialog: "正在打开\(pen.farmName)的\(pen.name)。")
    }
}

struct TodayFarmTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "查看今日任务"
    static let description = IntentDescription("查看指定牧场今日生产摘要与待同步操作。")
    static let openAppWhenRun = true

    @Parameter(title: "牧场") var farm: FarmIntentEntity

    func perform() async throws -> some IntentResult {
        let snapshot = FarmWidgetSnapshotStore.load().farms.first { $0.farmID == farm.id }
        FarmSystemNavigationStore.enqueue(.init(farmID: farm.id, kind: .home, entityID: nil, query: nil))
        guard let snapshot else { return .result(dialog: "正在打开\(farm.name)。") }
        return .result(dialog: "\(farm.name)今天已投喂\(snapshot.todayFeedCount)次，有\(snapshot.pendingOperationCount)项待同步。")
    }
}

struct RecordWeightIntent: AppIntent {
    static let title: LocalizedStringResource = "进入称重"
    static let description = IntentDescription("打开 eSheep+ 的称重录入入口。录入前仍会检查当前牧场和角色权限。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        if let farmID = FarmWidgetSnapshotStore.load().selectedFarmID {
            FarmSystemNavigationStore.enqueue(.init(farmID: farmID, kind: .recordWeight, entityID: nil, query: nil))
        } else {
            AppNavigationRequest.enqueue(.recordWeight)
        }
        return .result()
    }
}

struct RecordFeedIntent: AppIntent {
    static let title: LocalizedStringResource = "进入投喂"
    static let description = IntentDescription("打开 eSheep+ 的投喂录入入口。录入前仍会检查当前牧场和角色权限。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        if let farmID = FarmWidgetSnapshotStore.load().selectedFarmID {
            FarmSystemNavigationStore.enqueue(.init(farmID: farmID, kind: .recordFeed, entityID: nil, query: nil))
        } else {
            AppNavigationRequest.enqueue(.recordFeed)
        }
        return .result()
    }
}

struct ESheepShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenESheepIntent(), phrases: ["打开\(.applicationName)"], shortTitle: "打开牧场", systemImageName: "house")
        AppShortcut(intent: SearchSheepIntent(), phrases: ["在\(.applicationName)搜索羊只"], shortTitle: "搜索羊只", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenPenIntent(), phrases: ["在\(.applicationName)打开圈舍"], shortTitle: "打开圈舍", systemImageName: "building.2")
        AppShortcut(intent: TodayFarmTasksIntent(), phrases: ["查看\(.applicationName)今日任务"], shortTitle: "今日任务", systemImageName: "checklist")
        AppShortcut(intent: RecordWeightIntent(), phrases: ["在\(.applicationName)记录称重"], shortTitle: "称重", systemImageName: "scalemass")
        AppShortcut(intent: RecordFeedIntent(), phrases: ["在\(.applicationName)记录投喂"], shortTitle: "投喂", systemImageName: "leaf")
    }
}
