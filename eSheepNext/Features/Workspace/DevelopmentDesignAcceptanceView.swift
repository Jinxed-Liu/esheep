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
        let offlineSend = insightReady && ProcessInfo.processInfo.arguments.contains("--design-insight-offline-send")
        let workspaceDirectory = URL.applicationSupportDirectory.appending(path: "DesignAcceptance", directoryHint: .isDirectory)
        let directory = insightReady
            ? workspaceDirectory.appending(path: offlineSend ? "InsightOfflineSend" : "InsightReady", directoryHint: .isDirectory)
            : workspaceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeName = offlineSend ? "DesignInsightOfflineSendAcceptance" : (insightReady ? "DesignInsightReadyAcceptance" : "DesignAcceptance")
        container = try AppSchema.makeContainer(name: storeName,
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

    /// Exercises consent, credential loading, and history in the isolated store.
    /// Sending is available only with an explicitly installed offline responder.
    func prepareInsightReady() async throws {
        guard account.appleSubjectHash == AppleIdentityHash.value(for: "design-acceptance-local"),
              account.serverAccountID == nil, farm.ownerAccountID == account.id else {
            throw InsightSecurityError.accountMismatch
        }
        let accountID = account.effectiveAccountID
        let farmID = farm.id
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--design-insight-offline-send") {
            guard let index = arguments.firstIndex(of: "--design-insight-expected-message"),
                  arguments.indices.contains(index + 1), arguments[index + 1].contains("\n") else {
                throw MiMoClientError.invalidRequest
            }
            try InsightSessionCoordinator.shared.configureDesignAcceptanceClient(
                DesignAcceptanceMiMoResponder(expectedInput: arguments[index + 1]),
                account: account, farm: farm
            )
        }
        try AIPrivacyConsentStore.saveCurrentConsent(for: accountID)
        _ = try await MiMoCredentialVault.shared.save(
            apiKey: "sk-design-acceptance-fixture-not-a-real-key", for: accountID
        )
        try Task.checkCancellation()

        let context = container.mainContext
        let descriptor = FetchDescriptor<InsightConversationRecord>(predicate: #Predicate {
            $0.accountID == accountID && $0.farmID == farmID && $0.deletedAt == nil
        })
        let existingTitles = Set(try context.fetch(descriptor).map(\.title))
        for index in 1...2 {
            if !existingTitles.contains("入口回归历史聊天 \(index)") {
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
        }
        try context.save()
        InsightSessionCoordinator.shared.activate(scope: InsightConversationScope(accountID: accountID, farmID: farmID))
    }
}

/// The real conversation controller and persistence run unchanged. Only the
/// external model boundary is replaced, and unexpected input fails the test.
private struct DesignAcceptanceMiMoResponder: MiMoResponding {
    let expectedInput: String

    func stream(
        request: MiMoConversationRequest,
        credential: MiMoCredential
    ) -> AsyncThrowingStream<InsightModelEvent, Error> {
        AsyncThrowingStream { continuation in
            guard credential.apiKey == "sk-design-acceptance-fixture-not-a-real-key",
                  request.messages.last(where: { $0.role == .user })?.text == expectedInput else {
                continuation.finish(throwing: MiMoClientError.invalidRequest)
                return
            }
            continuation.yield(.responseStarted(id: "design-offline-send"))
            continuation.yield(.textDelta("离线发送验收：已收到两行输入。"))
            continuation.yield(.completed(responseID: "design-offline-send", usage: nil))
            continuation.finish()
        }
    }

    func validate(credential: MiMoCredential) async throws {
        guard credential.apiKey == "sk-design-acceptance-fixture-not-a-real-key" else {
            throw MiMoClientError.authenticationFailed
        }
    }
}
#endif
