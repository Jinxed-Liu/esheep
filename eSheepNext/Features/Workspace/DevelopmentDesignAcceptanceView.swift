#if DEBUG
import ESMotion
import SwiftData
import SwiftUI

/// Explicit development launch only; separate persistent store and no remote runtime.
struct DevelopmentDesignAcceptanceView: View {
    @State private var fixture: DesignAcceptanceFixture?
    @State private var failure: String?
    @State private var preferences = AppPreferences()
    @State private var notifications = FarmNotificationService()
    @State private var subscription = SubscriptionService()
    @State private var motion = MotionEngine()

    var body: some View {
        Group {
            if let fixture {
                MotionHost(engine: motion) {
                    acceptanceContent(fixture)
                        .environment(fixture.session)
                        .environment(fixture.collaboration)
                        .environment(preferences)
                        .environment(notifications)
                        .environment(subscription)
                        .modelContainer(fixture.container)
                        .tint(AppTheme.brand)
                        .modifier(DesignAcceptanceAppearance())
                }
            } else if let failure { Text(failure) }
            else { ProgressView("正在准备隔离测试牧场") }
        }
        .task {
            guard fixture == nil else { return }
            do {
                let prepared = try DesignAcceptanceFixture()
                if ProcessInfo.processInfo.arguments.contains("--design-insight-ready") {
                    try await prepared.prepareInsightReady()
                }
                try Task.checkCancellation()
                fixture = prepared
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func acceptanceContent(_ fixture: DesignAcceptanceFixture) -> some View {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--design-account-crop"), let image = UIImage(named: "MiMoAssistantAvatar") {
            AccountAvatarCropEditor(account: fixture.account, draft: AccountAvatarDraft(image: image))
        } else if arguments.contains("--design-account-avatar") {
            NavigationStack { AccountAvatarSettingsView(account: fixture.account) }
        } else if arguments.contains("--design-account-settings") {
            NavigationStack { SettingsHomeView(account: fixture.account, farm: fixture.farm) }
        } else {
            FarmWorkspaceView(account: fixture.account, farms: [fixture.farm], sharedFarmAdmissionStatus: nil)
        }
    }
}

/// Per-launch visual checks affect only the isolated development workspace.
private struct DesignAcceptanceAppearance: ViewModifier {
    @Environment(\.dynamicTypeSize) private var systemTypeSize
    private let arguments = ProcessInfo.processInfo.arguments

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(arguments.contains("--design-dark") ? .dark : nil)
            .dynamicTypeSize(arguments.contains("--design-large-text") ? .accessibility3 : systemTypeSize)
    }
}

@MainActor
private final class DesignAcceptanceFixture {
    let container: ModelContainer
    let account: AccountProfile
    let farm: FarmRecord
    let session: AppSession
    let collaboration: CloudCollaborationStore

    init() throws {
        let insightReady = ProcessInfo.processInfo.arguments.contains("--design-insight-ready")
        let workspaceDirectory = URL.applicationSupportDirectory.appending(path: "DesignAcceptance", directoryHint: .isDirectory)
        let directory = insightReady
            ? workspaceDirectory.appending(path: "InsightReady", directoryHint: .isDirectory)
            : workspaceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try AppSchema.makeContainer(name: insightReady ? "DesignInsightReadyAcceptance" : "DesignAcceptance",
            url: directory.appending(path: "acceptance.store"))
        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<AccountProfile>()).first,
           let existingFarm = try context.fetch(FetchDescriptor<FarmRecord>()).first {
            account = existing
            farm = existingFarm
        } else {
            account = AccountProfile(appleUserIdentifier: "design-acceptance-local", displayName: "设计验收")
            farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "设计验收 · 本机测试场", role: .administrator)
            context.insert(account)
            context.insert(farm)
            context.insert(FarmStorageProfile(farmID: farm.id, mode: .localOnly))
            let pen = PenRecord(farmID: farm.id, name: "繁殖母羊一舍")
            context.insert(pen)
            try context.save()
            for index in 1...12 {
                try FarmCommandService().execute(.addSheep(earTag: String(format: "QA-%03d", index), breed: "湖羊", sex: .ewe, penID: pen.id, occurredAt: Date.now.addingTimeInterval(-200 * 86400), birthAt: Date.now.addingTimeInterval(-400 * 86400), currentParity: 0, note: "隔离验收数据"), in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: .administrator), context: context)
            }
        }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--design-role"), args.indices.contains(index + 1), let role = FarmRole(rawValue: args[index + 1]) {
            farm.roleRawValue = role.rawValue
            try context.save()
        }
        session = AppSession(activeAccountProfileID: account.id, persistedLocalSessionAccountID: nil, persistActiveAccountProfileID: { _ in }, clearActiveAccountProfileID: {})
        session.selectedFarmID = farm.id
        collaboration = CloudCollaborationStore(container: container, allowsRemoteConnections: false)
    }

    /// Exercises consent, credential loading, and history without validating a
    /// credential or sending a model request. The account belongs to this store.
    func prepareInsightReady() async throws {
        guard account.appleSubjectHash == AppleIdentityHash.value(for: "design-acceptance-local"),
              account.serverAccountID == nil, farm.ownerAccountID == account.id else {
            throw InsightSecurityError.accountMismatch
        }
        let accountID = account.effectiveAccountID
        let farmID = farm.id
        try AIPrivacyConsentStore.saveCurrentConsent(for: accountID)
        _ = try await MiMoCredentialVault.shared.save(
            apiKey: "sk-design-acceptance-fixture-not-a-real-key", for: accountID
        )
        try Task.checkCancellation()

        let context = container.mainContext
        var descriptor = FetchDescriptor<InsightConversationRecord>(predicate: #Predicate {
            $0.accountID == accountID && $0.farmID == farmID && $0.deletedAt == nil
        })
        descriptor.fetchLimit = 1
        if try context.fetch(descriptor).isEmpty {
            for index in 1...2 {
                let createdAt = Date.now.addingTimeInterval(-Double(index) * 60)
                let conversation = InsightConversationRecord(
                    accountID: accountID, farmID: farmID,
                    title: "入口回归历史聊天 \(index)", createdAt: createdAt
                )
                context.insert(conversation)
                context.insert(InsightMessageRecord(
                    conversationID: conversation.id, accountID: accountID, farmID: farmID,
                    role: .assistant, text: "这是第 \(index) 条本机隔离验收聊天记录。",
                    createdAt: createdAt, status: .completed,
                    provider: "local", model: "design-acceptance"
                ))
            }
            try context.save()
        }
        InsightSessionCoordinator.shared.activate(scope: InsightConversationScope(accountID: accountID, farmID: farmID))
    }
}
#endif
