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
        if arguments.contains("--design-insight-voice-waveform") {
            DesignAcceptanceVoiceWaveformView()
        } else if arguments.contains("--design-account-crop"), let image = UIImage(named: "MiMoAssistantAvatar") {
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

/// A known clock and levels drive the production composer. This page never
/// requests microphone access, creates a real recording, or calls a provider.
private struct DesignAcceptanceVoiceWaveformView: View {
    @State private var recorder = InsightAudioRecorder()
    @State private var text = "录音前的原始草稿"
    @State private var pendingAudio: PendingInsightAudio?
    @State private var isPlaying = false
    @State private var sampleCount = 0
    @State private var sendCount = 0
    @FocusState private var isFocused: Bool
    private let origin = Date(timeIntervalSince1970: 1_000)

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("仅时间序列视觉样本，非麦克风实录；不上传、不自动发送。")
                    .font(.callout)
                    .accessibilityIdentifier("design.audio.fixture.notice")
                HStack {
                    Button("开始时间样本", action: begin)
                        .accessibilityIdentifier("design.audio.fixture.begin")
                        .disabled(recorder.isRecording || pendingAudio != nil)
                    Button("推进 1 秒", action: advance)
                        .accessibilityIdentifier("design.audio.fixture.advance")
                        .disabled(!recorder.isRecording)
                }
                Button("查看录音起点（1 秒）") { begin(initialSamples: 10) }
                    .accessibilityIdentifier("design.audio.fixture.begin-origin")
                    .disabled(recorder.isRecording || pendingAudio != nil)
                Text("样本数 \(recorder.isRecording ? recorder.waveformSampleCount : sampleCount)，发送次数 \(sendCount)")
                    .monospacedDigit()
                    .accessibilityIdentifier("design.audio.fixture.state")
                Spacer()
            }
            .padding()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InsightComposerView(
                    text: $text, isFocused: $isFocused,
                    audioRecorder: recorder, pendingAudio: pendingAudio,
                    isPlayingAudio: isPlaying, isGenerating: false, isSubmitting: false,
                    isEnabled: true, isAudioEnabled: true,
                    hasAttachments: false, attachmentsReady: true,
                    modeTitle: nil, isPlanSelected: false, isGoalSelected: false,
                    onCamera: {}, onPhotos: {}, onFiles: {}, onPlan: {}, onGoal: {},
                    onRemoveMode: {}, onSettings: {},
                    onMicrophonePressChanged: { _ in }, onMicrophoneLongPress: begin,
                    onMicrophone: { recorder.isRecording ? stop() : begin() },
                    onToggleAudioPlayback: { isPlaying.toggle() },
                    onDiscardAudio: discard, onSend: { sendCount += 1 }, onStop: {},
                    attachments: { EmptyView() }, context: { EmptyView() }
                )
            }
            .navigationTitle("波形时间序列样本")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { recorder.endWaveformDesignPreview() }
        }
    }

    private func begin() {
        begin(initialSamples: 60)
    }

    private func begin(initialSamples: Int) {
        pendingAudio = nil
        isPlaying = false
        sampleCount = 0
        recorder.beginWaveformDesignPreview(at: origin)
        // A retained peak at 4.1s has a fixed sample index. The next ten silent
        // samples make its leftward movement visible in the second screenshot.
        let peakIndex = min(40, initialSamples - 4)
        for index in 0..<initialSamples {
            let level: Float
            if index == peakIndex { level = 1 }
            else if abs(index - peakIndex) == 1 { level = 0.65 }
            else if abs(index - peakIndex) == 2 { level = 0.35 }
            else { level = index.isMultiple(of: 7) ? 0.15 : 0 }
            append(level)
        }
    }

    private func advance() {
        guard recorder.isRecording else { return }
        for _ in 0..<10 { append(0) }
    }

    private func append(_ level: Float) {
        sampleCount += 1
        recorder.appendWaveformDesignPreview(
            level: level, at: origin.addingTimeInterval(Double(sampleCount) * 0.1)
        )
    }

    private func stop() {
        guard recorder.isRecording else { return }
        // This pending value is only a visual fixture. It does not claim to
        // exercise AVAudioRecorder.finish(), decoding, playback, or upload.
        pendingAudio = PendingInsightAudio(
            data: Data(), mimeType: "audio/mp4", duration: recorder.duration,
            waveformSamples: recorder.waveformSamples
        )
        recorder.endWaveformDesignPreview()
        isPlaying = false
    }

    private func discard() {
        recorder.endWaveformDesignPreview()
        pendingAudio = nil
        isPlaying = false
        sampleCount = 0
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
        let args = ProcessInfo.processInfo.arguments
        let insightReady = args.contains("--design-insight-ready")
        let offlineSend = insightReady && args.contains("--design-insight-offline-send")
        let workspaceDirectory = URL.applicationSupportDirectory.appending(path: "DesignAcceptance", directoryHint: .isDirectory)
        var directory = insightReady
            ? workspaceDirectory.appending(path: offlineSend ? "InsightOfflineSend" : "InsightReady", directoryHint: .isDirectory)
            : workspaceDirectory
        if insightReady, let index = args.firstIndex(of: "--design-fixture-id") {
            guard args.indices.contains(index + 1), let fixtureID = UUID(uuidString: args[index + 1]) else {
                throw MiMoClientError.invalidRequest
            }
            // A test can keep its namespace across relaunches without loading
            // another test's persistent account, history, or encrypted drafts.
            directory = directory.appending(path: fixtureID.uuidString, directoryHint: .isDirectory)
        }
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
        if let index = args.firstIndex(of: "--design-role"), args.indices.contains(index + 1), let role = FarmRole(rawValue: args[index + 1]) {
            farm.roleRawValue = role.rawValue
            try context.save()
        }
        session = AppSession(activeAccountProfileID: account.id, persistedLocalSessionAccountID: nil, persistActiveAccountProfileID: { _ in }, clearActiveAccountProfileID: {})
        session.selectedFarmID = farm.id
        collaboration = CloudCollaborationStore(container: container, allowsRemoteConnections: false)
        InsightSessionCoordinator.shared.activate(scope: InsightConversationScope(
            accountID: account.effectiveAccountID, farmID: farm.id
        ))
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
            // XCTest launch argument transport does not preserve a raw newline.
            // Decode the expectation only; the editor must still type Return.
            guard let index = arguments.firstIndex(of: "--design-insight-expected-message-base64"),
                  arguments.indices.contains(index + 1),
                  let data = Data(base64Encoded: arguments[index + 1]),
                  let expectedInput = String(data: data, encoding: .utf8),
                  expectedInput.contains("\n") else {
                throw MiMoClientError.invalidRequest
            }
            let waitsForExplicitCompletion = arguments.contains("--design-insight-edge-swipe-response")
            if waitsForExplicitCompletion {
                await DesignAcceptanceReplyGate.shared.reset()
            }
            let client: any MiMoResponding
            if arguments.contains("--design-insight-long-response") {
                client = DesignAcceptanceLongMiMoResponder(expectedInput: expectedInput)
            } else {
                client = DesignAcceptanceMiMoResponder(
                    expectedInput: expectedInput,
                    showsProgress: arguments.contains("--design-insight-slow-response") ||
                        waitsForExplicitCompletion,
                    waitsForExplicitCompletion: waitsForExplicitCompletion
                )
            }
            try InsightSessionCoordinator.shared.configureDesignAcceptanceClient(
                client, account: account, farm: farm
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

/// Holds only the explicit offline navigation sample across XCTest's idle wait.
/// The real stream still responds to cancellation while completion is pending.
actor DesignAcceptanceReplyGate {
    static let shared = DesignAcceptanceReplyGate()
    private var isReleased = false

    func reset() {
        isReleased = false
    }

    func release() {
        isReleased = true
    }

    func waitForRelease() async throws {
        while !isReleased {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }
}

/// The real conversation controller and persistence run unchanged. Only the
/// external model boundary is replaced, and unexpected input fails the test.
private struct DesignAcceptanceMiMoResponder: MiMoResponding {
    let expectedInput: String
    var showsProgress = false
    var waitsForExplicitCompletion = false
    private static let responseText = "离线发送验收：已收到两行输入。"
    private static let reviewToolName = "review_grounded_farm_answer"

    func stream(
        request: MiMoConversationRequest,
        credential: MiMoCredential
    ) -> AsyncThrowingStream<InsightModelEvent, Error> {
        AsyncThrowingStream { continuation in
            guard credential.apiKey == "sk-design-acceptance-fixture-not-a-real-key" else {
                continuation.finish(throwing: MiMoClientError.invalidRequest)
                return
            }
            if request.tools.map(\.name) == [Self.reviewToolName] {
                let expectedReviewPayload = """
                用户问题：
                当前用户消息：\(expectedInput)

                待展示答案：
                \(Self.responseText)

                本轮已执行工具及结果：
                （没有工具证据）

                本轮成功工具名称：
                """ + "\n"
                guard request.functionExchanges.isEmpty, request.messages.count == 1,
                      request.messages[0].role == .user,
                      request.messages[0].text == expectedReviewPayload else {
                    continuation.finish(throwing: MiMoClientError.invalidRequest)
                    return
                }
                continuation.yield(.responseStarted(id: "design-offline-review"))
                continuation.yield(.functionCall(.init(
                    callID: "design-offline-review", name: Self.reviewToolName,
                    argumentsJSON: #"{"verdict":"accept","claim_scope":"general","evidence_sufficient":false,"issue":"","corrective_instruction":""}"#
                )))
                continuation.yield(.completed(responseID: "design-offline-review", usage: nil))
                continuation.finish()
                return
            }
            guard !request.tools.contains(where: { $0.name == Self.reviewToolName }),
                  request.messages.last(where: { $0.role == .user })?.text == expectedInput else {
                continuation.finish(throwing: MiMoClientError.invalidRequest)
                return
            }
            if showsProgress {
                // The navigation sample waits for an explicit model-boundary
                // release; other visual samples retain their short delay.
                let task = Task {
                    do {
                        continuation.yield(.responseStarted(id: "design-offline-send"))
                        if waitsForExplicitCompletion {
                            try await DesignAcceptanceReplyGate.shared.waitForRelease()
                        } else {
                            try await Task.sleep(for: .seconds(6))
                        }
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(Self.responseText))
                        continuation.yield(.completed(responseID: "design-offline-send", usage: nil))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
                return
            }
            continuation.yield(.responseStarted(id: "design-offline-send"))
            continuation.yield(.textDelta(Self.responseText))
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

/// Reproduces an empty running message becoming a large, reviewed Markdown
/// response on the same screen. The native read tool uses only the fixture
/// store; the external model and reviewer remain explicit offline boundaries.
private struct DesignAcceptanceLongMiMoResponder: MiMoResponding {
    let expectedInput: String
    private static let reviewToolName = "review_grounded_farm_answer"
    private static let toolCall = InsightFunctionCall(
        callID: "design-long-pens", name: "get_farm_entities",
        argumentsJSON: #"{"category":"pens","query":"繁殖母羊一舍","limit":50}"#
    )
    private static let responseText = """
    # 隔离长回复验收

    本次回复来自本机隔离演示，用于检查原页的过程更新、完整正文、表格布局和输入框安全区。当前页面需要在回复完成后直接展示答案。

    ## 本次实际查询

    已通过 App 的只读圈舍查询找到“繁殖母羊一舍”。以下表格记录界面验收范围；各行说明显示行为，没有羊只体重或日增重结论。

    | 验收内容 | 观察范围 |
    | --- | --- |
    | 对象名称 | 繁殖母羊一舍 |
    | 本机查询 | 调用只读圈舍工具 |
    | 运行过程 | 当前会话的公开状态 |
    | 答案复核 | 离线演示审核边界 |
    | 长段落 | 自动换行后的正文高度 |
    | 表格 | 标题、单元格和横向适配 |
    | 页面底部 | 正文与输入框的位置 |
    | 会话持久化 | 保存后的同一条助手消息 |

    ## 正文与过程

    查询、整理答复和复核属于不同阶段。运行时可以查看实际发生的处理步骤，复核通过后才展示这段完整正文。过程说明应保持简洁，让当前步骤和已读取的对象名称容易辨认。

    这是一条较长的 Markdown 回复。正文包含多个段落和表格，使内容高度明显大于刚发送时的空助手消息。保持当前会话打开，能够检查内容增长后是否立即进入可阅读的布局。

    ## 滚动与输入区

    用户阅读回复时，需要能看清最后一段文字。底部输入区域使用自己的安全区，正文不会被输入控件遮盖，页面也不依赖重新打开会话来完成位置更新。

    如果内容超过屏幕高度，可以正常向上阅读前面的段落。当前回复仍属于同一条助手消息，圈舍查询记录和对应正文保留在同一个消息组内。

    ## 验收边界

    这次隔离样本覆盖真实控制器、原生只读工具、答案复核流程、本机消息保存及 SwiftUI 渲染。它用于界面回归；真实牧场的日增重计算仍需要使用实际称重记录和计算证据进行单独验证。

    | 演示范围 | 查询边界 | 模型边界 | 复核边界 | 存储边界 | 展示边界 |
    | --- | --- | --- | --- | --- | --- |
    | 本机隔离测试 | 原生只读工具 | 离线演示回复 | 离线独立复核 | 本机消息记录 | 当前会话正文 |
    | 界面检查 | 圈舍名称 | 多段 Markdown | 完整候选答案 | 原消息对象 | 横向表格滚动 |

    原页长回复验收完成。
    """

    func stream(request: MiMoConversationRequest, credential: MiMoCredential) -> AsyncThrowingStream<InsightModelEvent, Error> {
        AsyncThrowingStream { continuation in
            guard credential.apiKey == "sk-design-acceptance-fixture-not-a-real-key" else {
                continuation.finish(throwing: MiMoClientError.invalidRequest)
                return
            }
            let isReview = request.tools.map(\.name) == [Self.reviewToolName]
            if isReview {
                guard request.functionExchanges.isEmpty, request.messages.count == 1,
                      request.messages[0].role == .user,
                      request.messages[0].text.contains(expectedInput),
                      request.messages[0].text.contains(Self.responseText),
                      request.messages[0].text.contains(Self.toolCall.name),
                      request.messages[0].text.contains("繁殖母羊一舍") else {
                    continuation.finish(throwing: MiMoClientError.invalidRequest)
                    return
                }
            } else {
                guard !request.tools.contains(where: { $0.name == Self.reviewToolName }),
                      request.messages.last(where: { $0.role == .user })?.text == expectedInput else {
                    continuation.finish(throwing: MiMoClientError.invalidRequest)
                    return
                }
                if request.functionExchanges.isEmpty {
                    continuation.yield(.responseStarted(id: "design-long-tool"))
                    continuation.yield(.functionCall(Self.toolCall))
                    continuation.yield(.completed(responseID: "design-long-tool", usage: nil))
                    continuation.finish()
                    return
                }
                guard request.functionExchanges.count == 1,
                      request.functionExchanges[0].call == Self.toolCall,
                      request.functionExchanges[0].succeeded,
                      request.functionExchanges[0].output.contains("繁殖母羊一舍") else {
                    continuation.finish(throwing: MiMoClientError.invalidRequest)
                    return
                }
            }
            let task = Task {
                do {
                    let id = isReview ? "design-long-review" : "design-long-answer"
                    continuation.yield(.responseStarted(id: id))
                    // Delays exercise real progress and review phases. No
                    // simulated reasoning or unreviewed answer is displayed.
                    try await Task.sleep(for: .seconds(isReview ? 3 : 6))
                    try Task.checkCancellation()
                    if isReview {
                        continuation.yield(.functionCall(.init(
                            callID: id, name: Self.reviewToolName,
                            argumentsJSON: #"{"verdict":"accept","claim_scope":"farm_specific","evidence_sufficient":true,"issue":"","corrective_instruction":""}"#
                        )))
                    } else {
                        continuation.yield(.textDelta(Self.responseText))
                    }
                    continuation.yield(.completed(responseID: id, usage: nil))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func validate(credential: MiMoCredential) async throws {
        guard credential.apiKey == "sk-design-acceptance-fixture-not-a-real-key" else {
            throw MiMoClientError.authenticationFailed
        }
    }
}
#endif
