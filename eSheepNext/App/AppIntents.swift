import AppIntents

struct OpenESheepIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 eSheep+"
    static let description = IntentDescription("打开 eSheep+ 并继续使用当前牧场。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppNavigationRequest.enqueue(.home)
        return .result()
    }
}

struct RecordWeightIntent: AppIntent {
    static let title: LocalizedStringResource = "进入称重"
    static let description = IntentDescription("打开 eSheep+ 的称重录入入口。录入前仍会检查当前牧场和角色权限。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppNavigationRequest.enqueue(.recordWeight)
        return .result()
    }
}

struct RecordFeedIntent: AppIntent {
    static let title: LocalizedStringResource = "进入投喂"
    static let description = IntentDescription("打开 eSheep+ 的投喂录入入口。录入前仍会检查当前牧场和角色权限。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppNavigationRequest.enqueue(.recordFeed)
        return .result()
    }
}

struct ESheepShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenESheepIntent(), phrases: ["打开\(.applicationName)"], shortTitle: "打开牧场", systemImageName: "house")
        AppShortcut(intent: RecordWeightIntent(), phrases: ["在\(.applicationName)记录称重"], shortTitle: "称重", systemImageName: "scalemass")
        AppShortcut(intent: RecordFeedIntent(), phrases: ["在\(.applicationName)记录投喂"], shortTitle: "投喂", systemImageName: "leaf")
    }
}
