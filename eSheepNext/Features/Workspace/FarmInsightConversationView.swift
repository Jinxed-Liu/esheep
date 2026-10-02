import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum InsightAudioPlaybackSource: Equatable {
    case pending
    case sentMessage(UUID)
}

enum InsightChatInitialAction: Hashable {
    case camera, photos, files, voice
}

struct FarmInsightConversationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query private var attachments: [InsightAttachmentRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let initialPrompt: String?
    let conversationID: UUID?
    let boundScope: InsightConversationScope
    let initialAction: InsightChatInitialAction?
    let onNewConversation: (() -> Void)?

    @State private var controller: InsightConversationController
    @State private var audioRecorder = InsightAudioRecorder()
    @State private var audioPlayer = InsightAudioPreviewPlayer()
    @State private var composerDraft: InsightComposerDraft
    @State private var inputOrigin = InsightInputOrigin.text
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var storedAudioByMessageID: [UUID: StoredInsightAudio] = [:]
    @State private var audioPlaybackSource: InsightAudioPlaybackSource?
    @State private var isPhotoLibraryPresented = false
    @State private var isCameraPresented = false
    @State private var isImportFilePresented = false
    @State private var isAnalysisFilePresented = false
    @State private var isAnalysisSettingsPresented = false
    @State private var isAssistantSettingsPresented = false
    @State private var isDetailsPresented = false
    @State private var isRenamePresented = false
    @State private var isDeletePresented = false
    @State private var isNewChatPresented = false
    @State private var renamedTitle = ""
    @State private var selectingDocument: PendingInsightDocument?
    @State private var processingDocumentNames: [String] = []
    @State private var isProcessingPhotos = false
    @State private var isSubmitting = false
    @State private var isRestoringDraft = false
    @State private var pendingRestoreMessageID: UUID?
    @State private var storedDocumentsByMessageID: [UUID: [InsightStoredDocumentPreview]] = [:]
    @State private var inspectedDocument: InsightStoredDocumentPreview?
    @State private var focusBeforePicker = false
    @State private var focusBeforeSettings = false
    @State private var focusBeforeContext = false
    @State private var didHandleInitialAction = false
    @State private var isChatVisible = false
    @State private var isConversationSearchPresented = false
    @State private var isContextUsagePresented = false
    @State private var searchResultTargetID: UUID?
    @State private var selectedDraft: InsightActionDraftRecord?
    @State private var isMicrophonePressed = false
    @State private var didActivateMicrophoneLongPress = false
    @FocusState private var isComposerFocused: Bool
    private let conversationBottomID = "insight-conversation-bottom"

    init(account: AccountProfile, farm: FarmRecord, initialPrompt: String? = nil) {
        self.init(
            account: account, farm: farm,
            controller: InsightSessionCoordinator.shared.controller(account: account, farm: farm, conversationID: nil),
            initialPrompt: initialPrompt
        )
    }

    init(
        account: AccountProfile,
        farm: FarmRecord,
        controller: InsightConversationController,
        conversationID: UUID? = nil,
        draftID: UUID? = nil,
        searchTargetMessageID: UUID? = nil,
        initialPrompt: String? = nil,
        initialAction: InsightChatInitialAction? = nil,
        onNewConversation: (() -> Void)? = nil
    ) {
        self.account = account
        self.farm = farm
        self.initialPrompt = initialPrompt
        self.conversationID = conversationID ?? controller.currentConversationID
        self.boundScope = controller.conversationScope
        self.initialAction = initialAction
        self.onNewConversation = onNewConversation
        _controller = State(initialValue: controller)
        let draft = InsightSessionCoordinator.shared.draft(
            scope: controller.conversationScope,
            conversationID: conversationID ?? controller.currentConversationID
        )
        if let initialPrompt, draft.text.isEmpty { draft.text = initialPrompt }
        _composerDraft = State(initialValue: draft)
        _searchResultTargetID = State(initialValue: searchTargetMessageID)
    }

    private var input: String {
        get { composerDraft.text }
        nonmutating set { composerDraft.text = newValue }
    }
    private var pendingImages: [PendingInsightImage] {
        get { composerDraft.images }
        nonmutating set { composerDraft.images = newValue }
    }
    private var pendingAudio: PendingInsightAudio? {
        get { composerDraft.audio }
        nonmutating set { composerDraft.audio = newValue }
    }
    private var pendingDocuments: [PendingInsightDocument] {
        get { composerDraft.documents }
        nonmutating set { composerDraft.documents = newValue }
    }
    private var inputBinding: Binding<String> {
        Binding(get: { input }, set: { input = $0 })
    }
    private var imagesBinding: Binding<[PendingInsightImage]> {
        Binding(get: { pendingImages }, set: { pendingImages = $0 })
    }
    private var submissionMode: InsightSubmissionMode {
        InsightSubmissionMode(rawValue: composerDraft.modeRawValue) ?? .conversation
    }
    private var draftScope: InsightSessionScope {
        .init(accountID: boundScope.accountID, farmID: boundScope.farmID)
    }

    private var conversationLayout: some View {
        conversationScroll
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { assistantIdentity }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        Button(action: newChat) {
                            Image(systemName: "square.and.pencil").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting || isRestoringDraft)
                        .accessibilityLabel("新建聊天")
                        assistantMenu.frame(width: 44, height: 44)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 4) {
                    if let reason = controller.pausedReason, controller.activeGoalStatus == nil {
                        HStack(spacing: 8) {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("继续") { controller.resumePausedConversation() }
                                .frame(minHeight: 44)
                        }
                        .padding(.horizontal, 20)
                    }
                    composer
                }
            }
    }

    private var conversationLifecycle: some View {
        conversationLayout
            .task(id: farm.id) {
                guard isControllerBoundToFarm else {
                    controller.errorMessage = "牧场已切换，请重新进入 AI 助手。"
                    return
                }
                if case .loading = controller.availability {
                    await InsightSessionCoordinator.shared.connect(
                        controller, to: modelContext, preferredConversationID: conversationID
                    )
                }
                do {
                    try await InsightSessionCoordinator.shared.draftStore.restore(
                        scope: draftScope, conversationID: controller.currentConversationID
                    )
                } catch { controller.errorMessage = "恢复本机草稿失败：\(error.localizedDescription)" }
                controller.submissionMode = submissionMode
                if initialPrompt != nil { isComposerFocused = true }
                handleInitialAction()
#if DEBUG
                if case .ready = controller.availability,
                   let prompt = InsightAcceptanceLaunchRequest.takePrompt() {
                    await controller.send(text: prompt)
                }
#endif
            }
            .task(id: storedAudioRevision) {
                await loadStoredAudio()
            }
            .task(id: storedDocumentRevision) {
                await loadStoredDocuments()
            }
            .onChange(of: photoItems) { _, items in
                loadPhotos(items)
            }
            .onChange(of: audioRecorder.errorMessage) { _, error in
                if let error { controller.errorMessage = error }
            }
            .task(id: composerDraft.revision) {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    try Task.checkCancellation()
                    try await InsightSessionCoordinator.shared.draftStore.save(
                        scope: draftScope, conversationID: controller.currentConversationID
                    )
                } catch is CancellationError { } catch {
                    controller.errorMessage = "保存本机草稿失败：\(error.localizedDescription)"
                }
            }
            .onChange(of: composerDraft.modeRawValue) { _, _ in
                controller.submissionMode = submissionMode
            }
            .onAppear { isChatVisible = true }
            .onDisappear {
                isChatVisible = false
                if audioRecorder.isRecording { finishSpeechRecording() }
                audioPlayer.stop()
                persistDraft()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    if audioRecorder.isRecording { finishSpeechRecording() }
                    audioPlayer.stop()
                    persistDraft()
                }
            }
            .onChange(of: isPhotoLibraryPresented) { _, presented in
                if !presented { restorePickerFocus() }
            }
            .onChange(of: isCameraPresented) { _, presented in
                if !presented { restorePickerFocus() }
            }
            .onChange(of: isImportFilePresented) { _, presented in
                if !presented { restorePickerFocus() }
            }
            .onChange(of: isAnalysisFilePresented) { _, presented in
                if !presented { restorePickerFocus() }
            }
            .onChange(of: selectingDocument?.id) { _, id in
                if id == nil { restorePickerFocus() }
            }
    }

    private var conversationSheets: some View {
        conversationLifecycle
            .navigationDestination(isPresented: $isNewChatPresented) {
                // Break the recursive opaque body type of the standalone
                // new-chat destination. List-owned chats use their callback.
                AnyView(FarmInsightConversationView(account: account, farm: farm))
            }
            .photosPicker(
                isPresented: $isPhotoLibraryPresented,
                selection: $photoItems,
                maxSelectionCount: max(1, 4 - pendingImages.count),
                matching: .images
            )
            .sheet(isPresented: $isConversationSearchPresented) {
                InsightConversationSearchView(
                    messages: displayMessages,
                    drafts: controller.drafts
                ) { messageID in
                    searchResultTargetID = messageID
                    isConversationSearchPresented = false
                }
            }
            .sheet(item: $selectingDocument) { document in
                InsightDocumentSelectionSheet(document: document, onSelect: { selected in
                    if let index = pendingDocuments.firstIndex(where: { $0.id == selected.id }) {
                        pendingDocuments[index] = selected
                    }
                    selectingDocument = nil
                    restorePickerFocus()
                }, onCancel: {
                    selectingDocument = nil
                    restorePickerFocus()
                })
            }
            .sheet(item: $inspectedDocument) { document in
                InsightStoredDocumentView(document: document)
            }
            .sheet(isPresented: $isAssistantSettingsPresented) {
                NavigationStack {
                    InsightAssistantSettingsView(account: account, farm: farm)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { isAssistantSettingsPresented = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $isDetailsPresented) {
                NavigationStack {
                    Form {
                        LabeledContent("聊天", value: conversationTitle)
                        LabeledContent("牧场", value: farm.name)
                        LabeledContent("模型", value: controller.modelDisplayName)
                        Text("此聊天只读取和操作当前牧场。业务操作继续使用操作卡确认，已执行记录不会随聊天删除。")
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("聊天详情")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isDetailsPresented = false }
                        }
                    }
                }
            }
    }

    private var conversationActions: some View {
        conversationSheets
            .alert("重命名聊天", isPresented: $isRenamePresented) {
                TextField("聊天名称", text: $renamedTitle)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if let id = controller.currentConversationID {
                        controller.renameConversation(id: id, title: renamedTitle)
                    }
                }
            }
            .confirmationDialog("删除这个聊天？", isPresented: $isDeletePresented, titleVisibility: .visible) {
                Button("删除聊天", role: .destructive) {
                    if let conversation = currentConversation {
                        InsightSessionCoordinator.shared.delete(conversation, using: controller)
                        if conversation.deletedAt != nil { dismiss() }
                    }
                }
            } message: {
                Text("将停止相关任务并核对回执；已经执行的牧场业务记录会保留。")
            }
            .confirmationDialog(
                "替换当前未发送草稿？",
                isPresented: Binding(
                    get: { pendingRestoreMessageID != nil },
                    set: { if !$0 { pendingRestoreMessageID = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let messageID = pendingRestoreMessageID {
                    Button("替换并恢复原输入") {
                        pendingRestoreMessageID = nil
                        restoreDraft(messageID: messageID)
                    }
                }
                Button("保留当前草稿", role: .cancel) { pendingRestoreMessageID = nil }
            } message: {
                Text("这会替换当前文字和附件。原消息及操作卡会保留，恢复后由你决定是否发送。")
            }
    }

    private var conversationAttachments: some View {
        conversationActions
            .sheet(item: $selectedDraft) { draft in
                let presentation = controller.presentation(for: draft)
                InsightDraftConfirmationView(
                    draft: draft,
                    farmName: farm.name,
                    initialPayloadText: presentation.editablePayloadText,
                    initialPayloadError: presentation.editablePayloadError,
                    onConfirm: {
                        let approved = controller.confirmationSnapshots(for: draft)
                        selectedDraft = nil
                        Task { await controller.execute(draft, confirmedSnapshots: approved) }
                    }
                )
            }
            .sheet(item: $controller.pendingGeneratedFile) { file in
                InsightGeneratedFileExportView(file: file) { fileID in
                    guard controller.conversationScope == boundScope else { return }
                    controller.recordExportSaved(fileID: fileID)
                }
            }
            .sheet(isPresented: $isCameraPresented) {
                InsightCameraPicker(onImage: { image in
                    isCameraPresented = false
                    guard let data = image.jpegData(compressionQuality: 0.95) else { return }
                    optimizeAndAppend(data)
                }, onCancel: {
                    isCameraPresented = false
                    restorePickerFocus()
                })
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $isImportFilePresented,
                allowedContentTypes: [
                    .officeOpenXMLSpreadsheet,
                    .commaSeparatedText,
                    .json,
                ],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await controller.prepareImport(from: url) }
                case .failure(let error):
                    controller.errorMessage = "选择导入文件失败：\(error.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $isAnalysisFilePresented,
                allowedContentTypes: analysisDocumentTypes,
                allowsMultipleSelection: true
            ) { result in
                restorePickerFocus()
                switch result {
                case .success(let urls): loadDocuments(urls)
                case .failure(let error): controller.errorMessage = "选择分析文件失败：\(error.localizedDescription)"
                }
            }
    }

    var body: some View {
        conversationAttachments
            .alert(
                "AI 助手",
                isPresented: Binding(
                    get: { controller.errorMessage != nil },
                    set: { if !$0 { controller.errorMessage = nil } }
                ),
                actions: {
                    Button("好", role: .cancel) {}
                },
                message: {
                    Text(LocalizedStringKey(controller.errorMessage ?? ""))
                }
            )
            .confirmationDialog(
                "允许向 AI 服务发送扩展牧场数据？",
                isPresented: Binding(
                    get: { controller.pendingExtendedDataDisclosure != nil },
                    set: {
                        if !$0, controller.pendingExtendedDataDisclosure != nil {
                            controller.resolveExtendedDataDisclosure(granted: false)
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("仅允许这一次") {
                    controller.resolveExtendedDataDisclosure(granted: true)
                }
                Button("拒绝", role: .cancel) {
                    controller.resolveExtendedDataDisclosure(granted: false)
                }
            } message: {
                Text(controller.pendingExtendedDataDisclosure?.message ?? "")
            }
    }

    private var conversationScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    conversationMetadata
                    availabilityBanner
                    if !displayMessages.isEmpty {
                        ForEach(Array(displayMessages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowTimestamp(at: index, in: displayMessages) {
                                InsightConversationTimestamp(date: message.createdAt)
                            }
                            InsightConversationMessageRow(
                                message: message,
                                farmName: farm.name,
                                attachments: messageAttachments(for: message.id),
                                storedAudio: storedAudioByMessageID[message.id],
                                isPlayingAudio: audioPlayer.isPlaying
                                    && audioPlaybackSource == .sentMessage(message.id),
                                drafts: messageDrafts(for: message.id),
                                endsRoleGroup: endsRoleGroup(at: index, in: displayMessages),
                                canExecute: controller.canExecute,
                                executionCount: controller.executionCount,
                                draftPresentation: controller.presentation,
                                onToggleAudio: { toggleStoredAudioPlayback(messageID: message.id) },
                                onReview: review,
                                onReject: reject
                            )
                            InsightRuntimeDisclosure(
                                records: controller.runtimeRecords(for: message.id),
                                showReasoning: controller.showReasoning
                            )
                            if let documents = storedDocumentsByMessageID[message.id], !documents.isEmpty {
                                ForEach(documents) { document in
                                    Button {
                                        inspectedDocument = document
                                    } label: {
                                        Label(document.fileName, systemImage: "doc.text")
                                            .font(.caption)
                                            .frame(minHeight: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("查看\(document.fileName)的已发送内容与引用")
                                }
                            }
                            if let plan = controller.plan(for: message.id) {
                                InsightPlanCard(plan: plan, onEdit: { editPlan(plan) },
                                    onContinue: { controller.continuePlan(plan) },
                                    onDismiss: { controller.dismissPlan(plan) })
                            }
                            if let goal = controller.goal(for: message.id) {
                                InsightGoalCard(goal: goal,
                                    awaitingFileName: controller.pendingExportFileName(for: goal.id),
                                    onPause: { controller.pauseGoal(goal) },
                                    onResume: { controller.resumeGoal(goal) },
                                    onStop: { controller.stopGoal(goal) })
                            }
                            if message.role == .assistant,
                               message.status == .failed || message.status == .cancelled || message.status == .pending,
                               controller.canRestoreDraft(for: message.id) {
                                Button("恢复到输入框", systemImage: "arrow.uturn.backward") {
                                    requestDraftRecovery(messageID: message.id)
                                }
                                .frame(minHeight: 44)
                                .disabled(isSubmitting || isRestoringDraft || controller.isGenerating)
                            }
                        }
                    }
                    if controller.isGenerating {
                        InsightAssistantTypingIndicator()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(conversationBottomID)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
            .contentShape(.rect)
            .scrollEdgeEffectHidden(false, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .simultaneousGesture(
                TapGesture().onEnded {
                    isComposerFocused = false
                }
            )
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollToRequestedMessageOrBottom(proxy, animated: false)
            }
            .onChange(of: scrollRevision) { _, _ in
                scrollToRequestedMessageOrBottom(proxy, animated: true)
            }
            .onChange(of: searchResultTargetID) { _, messageID in
                guard let messageID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(messageID, anchor: .center)
                }
                searchResultTargetID = nil
            }
        }
    }

    private var currentConversation: InsightConversationRecord? {
        controller.conversations.first { $0.id == controller.currentConversationID }
    }

    private var conversationTitle: String { currentConversation?.title ?? "新聊天" }

    private var assistantIdentity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(conversationTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(farm.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: 200, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var assistantMenu: some View {
        Menu {
            Button("重命名", systemImage: "pencil") {
                renamedTitle = conversationTitle
                isRenamePresented = true
            }.disabled(currentConversation == nil)
            Button("聊天详情", systemImage: "info.circle") { isDetailsPresented = true }
            Button("搜索聊天", systemImage: "magnifyingglass") {
                isComposerFocused = false
                isConversationSearchPresented = true
            }
            Button("上下文用量", systemImage: "chart.pie") {
                focusBeforeContext = isComposerFocused
                isContextUsagePresented = true
            }
            Button("AI 设置", systemImage: "gearshape") { isAssistantSettingsPresented = true }
            Menu("建议问题", systemImage: "sparkles") {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { selectSuggestion(suggestion) }
                }
            }
            Button("导入牧场数据", systemImage: "square.and.arrow.down") {
                focusBeforePicker = isComposerFocused
                isImportFilePresented = true
            }
            Button("删除聊天", systemImage: "trash", role: .destructive) { isDeletePresented = true }
                .disabled(currentConversation == nil)
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || isRestoringDraft)
        .accessibilityLabel("聊天更多选项")
    }

    private var composer: some View {
        InsightComposerView(
            text: inputBinding,
            isFocused: $isComposerFocused,
            audioRecorder: audioRecorder,
            pendingAudio: pendingAudio,
            isPlayingAudio: audioPlayer.isPlaying && audioPlaybackSource == .pending,
            isGenerating: controller.isGenerating,
            isSubmitting: isSubmitting || isRestoringDraft,
            isEnabled: isReady,
            hasAttachments: !pendingImages.isEmpty || !pendingDocuments.isEmpty || isProcessingPhotos || !processingDocumentNames.isEmpty,
            attachmentsReady: attachmentsReady,
            modeTitle: submissionMode == .conversation ? nil : submissionMode.title,
            isPlanSelected: submissionMode == .plan,
            isGoalSelected: submissionMode == .goal,
            onCamera: { presentInput(.camera) },
            onPhotos: { presentInput(.photos) },
            onFiles: { presentInput(.files) },
            onPlan: { selectMode(.plan) },
            onGoal: { selectMode(.goal) },
            onRemoveMode: { selectMode(.conversation) },
            onSettings: {
                controller.reloadAnalysisPreference()
                focusBeforeSettings = isComposerFocused
                isAnalysisSettingsPresented = true
            },
            onMicrophonePressChanged: microphonePressChanged,
            onMicrophoneLongPress: activateMicrophoneLongPress,
            onMicrophone: toggleSpeechForAccessibility,
            onToggleAudioPlayback: toggleAudioPlayback,
            onDiscardAudio: discardPendingAudio,
            onSend: send,
            onStop: controller.stopGenerating,
            attachments: { composerAttachments },
            context: { contextUsageButton }
        )
        .popover(isPresented: $isAnalysisSettingsPresented) {
            InsightAnalysisSettingsPopover(
                effortIndex: Binding(
                    get: { controller.analysisEffort.sliderValue },
                    set: { controller.analysisEffort = .from(sliderValue: $0) }
                ),
                thinkingEnabled: Binding(get: { controller.thinkingEnabled }, set: { controller.thinkingEnabled = $0 }),
                showReasoning: Binding(get: { controller.showReasoning }, set: { controller.showReasoning = $0 }),
                modelName: controller.modelDisplayName
            )
            .presentationCompactAdaptation(.popover)
            .presentationBackground(.clear)
        }
        .onChange(of: isAnalysisSettingsPresented) { _, presented in
            if !presented && focusBeforeSettings { isComposerFocused = true }
        }
        .popover(isPresented: $isContextUsagePresented) {
            InsightContextUsageDetail(usage: controller.contextWindowUsage)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isContextUsagePresented) { _, presented in
            if !presented && focusBeforeContext { isComposerFocused = true }
        }
        .onChange(of: isAssistantSettingsPresented) { _, presented in
            guard !presented else { return }
            let configuration = InsightAnalysisPreference.load(for: account.effectiveAccountID)
            controller.analysisEffort = configuration.effort
            controller.thinkingEnabled = configuration.thinkingEnabled
            controller.showReasoning = configuration.showReasoning
            Task { await controller.refreshCredential() }
        }
    }

    private var contextUsageButton: some View {
        Button {
            focusBeforeContext = isComposerFocused
            isContextUsagePresented.toggle()
        } label: {
            InsightContextUsageRing(usage: controller.contextWindowUsage)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("上下文窗口已使用约 \(controller.contextWindowUsage.percentage)%")
    }

    private var attachmentsReady: Bool {
        !isProcessingPhotos && processingDocumentNames.isEmpty && pendingDocuments.allSatisfy(\.isReadyToSend)
    }

    private var composerAttachments: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !pendingImages.isEmpty {
                InsightPendingInputPreview(pendingImages: imagesBinding)
            }
            if isProcessingPhotos {
                Label("正在处理照片", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(processingDocumentNames.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在解析 \(name)").font(.caption).lineLimit(1)
                }
                .frame(minHeight: 44)
            }
            ForEach(pendingDocuments) { document in
                HStack(spacing: 4) {
                    Button {
                        focusBeforePicker = isComposerFocused
                        selectingDocument = document
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.fileName).font(.caption.weight(.medium)).lineLimit(1)
                                Text(document.isReadyToSend ? "已选内容 · 可发送" : "请选择要发送的页、工作表或范围")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(document.fileName)，\(document.isReadyToSend ? "可发送，修改选区" : "需选择发送范围")")
                    Button {
                        pendingDocuments.removeAll { $0.id == document.id }
                    } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除\(document.fileName)")
                }
                .padding(.leading, 10)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
            }
        }
        .disabled(isSubmitting || isRestoringDraft)
    }

    private var analysisDocumentTypes: [UTType] {
        ["pdf", "docx", "txt", "md", "xlsx", "csv", "json"].compactMap { UTType(filenameExtension: $0) }
    }

    private func selectMode(_ mode: InsightSubmissionMode) {
        composerDraft.modeRawValue = (submissionMode == mode ? InsightSubmissionMode.conversation : mode).rawValue
        controller.submissionMode = submissionMode
    }

    private func presentInput(_ action: InsightChatInitialAction) {
        guard !isSubmitting, !isRestoringDraft else { return }
        if action != .voice, audioRecorder.isRecording {
            isMicrophonePressed = false
            finishSpeechRecording()
        }
        focusBeforePicker = isComposerFocused
        switch action {
        case .camera, .photos:
            guard pendingImages.count < 4 else {
                controller.errorMessage = "每条消息最多选择 4 张图片。"
                return
            }
            if action == .camera { isCameraPresented = true }
            else { isPhotoLibraryPresented = true }
        case .files:
            guard pendingDocuments.count < 3 else {
                controller.errorMessage = "每条消息最多选择 3 份分析文档。"
                return
            }
            isAnalysisFilePresented = true
        case .voice:
            toggleSpeechForAccessibility()
        }
    }

    private func handleInitialAction() {
        guard !didHandleInitialAction else { return }
        didHandleInitialAction = true
        if let initialAction { presentInput(initialAction) }
    }

    private func restorePickerFocus() {
        if focusBeforePicker { isComposerFocused = true }
    }

    private func loadDocuments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard pendingDocuments.count + processingDocumentNames.count + urls.count <= 3 else {
            controller.errorMessage = "每条消息最多选择 3 份分析文档，请重新选择。"
            return
        }
        processingDocumentNames.append(contentsOf: urls.map(\.lastPathComponent))
        Task { @MainActor in
            for url in urls {
                do {
                    let document = try await InsightDocumentAnalysis.load(from: url)
                    guard pendingDocuments.reduce(document.byteCount, { $0 + $1.byteCount }) <= InsightDocumentAnalysis.maximumTotalBytes else {
                        throw InsightDocumentError.totalFilesTooLarge
                    }
                    pendingDocuments.append(document)
                } catch {
                    controller.errorMessage = "解析 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
                }
                if let index = processingDocumentNames.firstIndex(of: url.lastPathComponent) {
                    processingDocumentNames.remove(at: index)
                }
            }
            if selectingDocument == nil {
                selectingDocument = pendingDocuments.first { !$0.isReadyToSend }
            }
        }
    }

    private func editPlan(_ plan: InsightPlan) {
        guard controller.revisePlan(plan) else { return }
        let request = "请修改这个方案：\(plan.title)\n\(plan.analysis)\n需要调整："
        input = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? request : input + "\n\n" + request
        composerDraft.modeRawValue = InsightSubmissionMode.plan.rawValue
        controller.submissionMode = .plan
        isComposerFocused = true
    }

    private func newChat() {
        if audioRecorder.isRecording { finishSpeechRecording() }
        audioPlayer.stop()
        persistDraft()
        if let onNewConversation { onNewConversation() }
        else { isNewChatPresented = true }
    }

    private func persistDraft() {
        let scope = draftScope
        let id = controller.currentConversationID
        Task { @MainActor in
            do { try await InsightSessionCoordinator.shared.draftStore.save(scope: scope, conversationID: id) }
            catch { controller.errorMessage = "保存本机草稿失败：\(error.localizedDescription)" }
        }
    }

    private func requestDraftRecovery(messageID: UUID) {
        guard !isSubmitting, !isRestoringDraft, !controller.isGenerating else { return }
        guard !isProcessingPhotos, processingDocumentNames.isEmpty, !audioRecorder.isRecording else {
            controller.errorMessage = "请先结束录音并等待附件处理完成，再恢复输入。"
            return
        }
        if composerDraft.hasContent {
            pendingRestoreMessageID = messageID
        } else {
            restoreDraft(messageID: messageID)
        }
    }

    private func restoreDraft(messageID: UUID) {
        let targetDraft = composerDraft
        let expectedRevision = targetDraft.revision
        isRestoringDraft = true
        Task { @MainActor in
            defer { isRestoringDraft = false }
            do {
                let recovered = try await controller.restoreDraft(for: messageID)
                guard isControllerBoundToFarm, targetDraft.revision == expectedRevision else {
                    controller.errorMessage = "草稿已经改变，恢复内容尚未替换当前输入，请重新选择恢复。"
                    return
                }
                guard !recovered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !recovered.images.isEmpty || !recovered.documents.isEmpty || recovered.audio != nil else {
                    controller.errorMessage = recovered.warning ?? "这条消息没有可恢复的输入。"
                    return
                }
                guard recovered.images.count <= 4, recovered.documents.count <= 3 else {
                    controller.errorMessage = "原附件超过当前单条消息限制，请重新选择要发送的内容。"
                    return
                }
                audioPlayer.stop()
                targetDraft.text = recovered.text
                targetDraft.images = recovered.images
                targetDraft.documents = recovered.documents
                targetDraft.audio = recovered.audio
                targetDraft.modeRawValue = recovered.mode.rawValue
                controller.submissionMode = recovered.mode
                inputOrigin = recovered.audio == nil ? .text : .voiceAudio
                isComposerFocused = true
                if let warning = recovered.warning { controller.errorMessage = warning }
            } catch {
                controller.errorMessage = "恢复输入失败：\(error.localizedDescription)"
            }
        }
    }

    private var conversationMetadata: some View {
        VStack(spacing: 5) {
            Label("当前牧场：\(farm.name)", systemImage: "building.2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("本对话只读取和操作该牧场的数据")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("个人空间已加密", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 7)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var availabilityBanner: some View {
        if !isControllerBoundToFarm {
            InsightAvailabilityNotice(
                title: "牧场已切换",
                detail: "旧牧场会话已停止，请返回后重新进入当前牧场的 AI 助手。",
                action: nil
            )
        } else {
            switch controller.availability {
            case .loading:
                HStack(spacing: 7) {
                    ProgressView()
                    Text("正在检查 AI 助手配置")
                }
                .frame(maxWidth: .infinity)
                .font(.caption)
                .foregroundStyle(.secondary)
            case .ready:
                EmptyView()
            case .missingCredential:
                InsightAvailabilityNotice(
                    title: "配置 MiMo API Key",
                    detail: "请前往账户头像中的“AI 助手”设置。eSheep 不内置公共 Key。",
                    action: nil
                )
            case .unavailable(let message):
                InsightAvailabilityNotice(
                    title: "AI 助手暂不可用",
                    detail: message,
                    action: nil
                )
            }
        }
    }

    private var suggestions: [String] {
        [
            "当前牧场有多少只在场羊？",
            "查找耳号 001 的羊并总结档案",
            "明天上午 8 点提醒我检查饮水",
            "下周一安排一次羊群盘点日历事件",
        ]
    }

    private var displayMessages: [InsightMessageRecord] {
        controller.visibleMessages
    }

    private var isReady: Bool {
        if case .ready = controller.availability {
            return isControllerBoundToFarm && controller.canUseAssistant
        }
        return false
    }

    private var isControllerBoundToFarm: Bool {
        boundScope == controller.conversationScope && boundScope == InsightConversationScope(
            accountID: account.effectiveAccountID,
            farmID: farm.id
        )
    }

    private func send() {
        guard !isSubmitting, !isRestoringDraft else { return }
        guard attachmentsReady else {
            controller.errorMessage = "附件尚未准备好，请等待解析完成并选择要发送的内容。"
            return
        }
        guard isReady else {
            controller.errorMessage = "请先前往账户头像中的“AI 助手”设置，完成数据说明同意和服务连接。"
            return
        }
        let submitted = input
        let images = pendingImages
        let audio = pendingAudio
        let documents = pendingDocuments
        let origin = audio == nil ? inputOrigin : .voiceAudio
        let submittedDraft = composerDraft
        let submittedDraftID = submittedDraft.draftID
        let submittedRevision = submittedDraft.revision
        let submittedScope = boundScope
        let wasNewConversation = controller.currentConversationID == nil
        controller.submissionMode = submissionMode
        audioPlayer.stop()
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            guard await controller.send(
                text: submitted, images: images, audio: audio,
                documents: documents, origin: origin
            ) else { return }
            guard isControllerBoundToFarm, controller.conversationScope == submittedScope else { return }
            if wasNewConversation, let id = controller.currentConversationID {
                InsightSessionCoordinator.shared.completeDraft(
                    scope: submittedScope, draftID: submittedDraftID,
                    conversationID: id, controller: controller,
                    expectedDraftRevision: submittedRevision
                )
                composerDraft = InsightSessionCoordinator.shared.draft(scope: submittedScope, conversationID: id)
            } else if submittedDraft.revision == submittedRevision {
                submittedDraft.clear()
            }
            photoItems = []
            inputOrigin = .text
        }
    }

    private func selectSuggestion(_ prompt: String) {
        input = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? prompt : input + "\n\n" + prompt
        inputOrigin = .text
        isComposerFocused = true
    }

    private func microphonePressChanged(_ isPressing: Bool) {
        isMicrophonePressed = isPressing
        guard !isPressing,
              didActivateMicrophoneLongPress,
              audioRecorder.isRecording else {
            return
        }
        finishSpeechRecording()
    }

    private func activateMicrophoneLongPress() {
        guard !isSubmitting, !isRestoringDraft, isReady,
              pendingAudio == nil,
              !controller.isGenerating else {
            return
        }
        didActivateMicrophoneLongPress = true
        isComposerFocused = false
        audioPlayer.stop()
        Task {
            guard isChatVisible, scenePhase == .active else { return }
            await audioRecorder.start()
            guard isChatVisible, scenePhase == .active else {
                audioRecorder.discard()
                didActivateMicrophoneLongPress = false
                return
            }
            guard audioRecorder.isRecording else {
                didActivateMicrophoneLongPress = false
                return
            }
            if !isMicrophonePressed {
                finishSpeechRecording()
            }
        }
    }

    private func toggleSpeechForAccessibility() {
        if audioRecorder.isRecording {
            isMicrophonePressed = false
            finishSpeechRecording()
        } else {
            isMicrophonePressed = true
            activateMicrophoneLongPress()
        }
    }

    private func finishSpeechRecording() {
        withAnimation(.snappy(duration: 0.3, extraBounce: 0.04)) {
            do {
                pendingAudio = try audioRecorder.finish()
                if pendingAudio != nil {
                    inputOrigin = .voiceAudio
                }
            } catch {
                controller.errorMessage = error.localizedDescription
            }
        }
        didActivateMicrophoneLongPress = false
    }

    private func toggleAudioPlayback() {
        guard let pendingAudio else { return }
        if audioPlaybackSource != .pending {
            audioPlayer.stop()
            audioPlaybackSource = .pending
        }
        audioPlayer.toggle(pendingAudio)
    }

    private func toggleStoredAudioPlayback(messageID: UUID) {
        guard let audio = storedAudioByMessageID[messageID] else { return }
        let source = InsightAudioPlaybackSource.sentMessage(messageID)
        if audioPlaybackSource != source {
            audioPlayer.stop()
            audioPlaybackSource = source
        }
        audioPlayer.toggle(audio.pendingAudio)
    }

    private func discardPendingAudio() {
        audioPlayer.stop()
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.03)) {
            pendingAudio = nil
            inputOrigin = .text
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isProcessingPhotos = true
        Task { @MainActor in
            defer { photoItems = []; isProcessingPhotos = false }
            for item in items.prefix(max(0, 4 - pendingImages.count)) {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw InsightMediaError.invalidImage
                    }
                    optimizeAndAppend(data)
                } catch {
                    controller.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func optimizeAndAppend(_ data: Data) {
        do {
            guard pendingImages.count < 4 else {
                controller.errorMessage = "每条消息最多选择 4 张图片。"
                return
            }
            let image = try InsightImageOptimizer.optimize(data)
            guard !pendingImages.contains(where: { $0.digest == image.digest }) else { return }
            pendingImages.append(image)
            inputOrigin = .image
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }

    private func messageAttachments(for messageID: UUID) -> [InsightAttachmentRecord] {
        let scope = controller.conversationScope
        return attachments
            .filter { scope.contains($0) && $0.messageID == messageID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func messageDrafts(for messageID: UUID) -> [InsightActionDraftRecord] {
        controller.drafts(forMessageID: messageID)
    }

    private var storedAudioRevision: String {
        let audioMessageIDs = controller.messages
            .filter { $0.toolName == "audio_input" || $0.toolName == "audio_document_input" }
            .map(\.id.uuidString)
            .joined(separator: ",")
        return "\(controller.currentConversationID?.uuidString ?? "none"):\(audioMessageIDs)"
    }

    private var storedDocumentRevision: String {
        let ids = displayMessages.filter { $0.role == .user }.map(\.id.uuidString).joined(separator: ",")
        return "\(controller.currentConversationID?.uuidString ?? "none"):\(ids)"
    }

    private func loadStoredDocuments() async {
        guard let conversationID = controller.currentConversationID else {
            storedDocumentsByMessageID = [:]
            return
        }
        var loaded: [UUID: [InsightStoredDocumentPreview]] = [:]
        for message in displayMessages where message.role == .user {
            guard !Task.isCancelled else { return }
            if let documents = try? await InsightLocalDocumentStore.shared.previews(
                messageID: message.id, conversationID: conversationID,
                accountID: boundScope.accountID, farmID: boundScope.farmID
            ), !documents.isEmpty {
                loaded[message.id] = documents
            }
        }
        guard !Task.isCancelled, controller.currentConversationID == conversationID else { return }
        storedDocumentsByMessageID = loaded
    }

    private func loadStoredAudio() async {
        guard let conversationID = controller.currentConversationID else {
            storedAudioByMessageID = [:]
            return
        }
        let audioMessages = controller.messages.filter { $0.toolName == "audio_input" || $0.toolName == "audio_document_input" }
        var loaded: [UUID: StoredInsightAudio] = [:]
        for message in audioMessages {
            if let audio = try? await controller.storedAudio(
                messageID: message.id,
                conversationID: conversationID
            ) {
                loaded[message.id] = audio
            }
        }
        guard !Task.isCancelled else { return }
        storedAudioByMessageID = loaded
    }

    private func review(_ draft: InsightActionDraftRecord) {
        if draft.risk == .high {
            let approved = controller.confirmationSnapshots(for: draft)
            Task { await controller.execute(draft, confirmedSnapshots: approved) }
        } else {
            selectedDraft = draft
        }
    }

    private func reject(_ draft: InsightActionDraftRecord) {
        controller.reject(draft)
    }

    private func shouldShowTimestamp(
        at index: Int,
        in messages: [InsightMessageRecord]
    ) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index > messages.startIndex else { return true }
        let message = messages[index]
        let previous = messages[index - 1]
        return !Calendar.current.isDate(message.createdAt, inSameDayAs: previous.createdAt) ||
            message.createdAt.timeIntervalSince(previous.createdAt) >= 15 * 60
    }

    private func endsRoleGroup(
        at index: Int,
        in messages: [InsightMessageRecord]
    ) -> Bool {
        guard messages.indices.contains(index) else { return true }
        let nextIndex = index + 1
        guard messages.indices.contains(nextIndex) else { return true }
        let message = messages[index]
        let next = messages[nextIndex]
        return message.role != next.role ||
            next.createdAt.timeIntervalSince(message.createdAt) >= 5 * 60
    }

    private var scrollRevision: String {
        let last = displayMessages.last
        return [
            String(displayMessages.count),
            last?.id.uuidString ?? "",
            String(last?.text.count ?? 0),
            String(last?.updatedAt.timeIntervalSinceReferenceDate ?? 0),
            String(pendingImages.count),
            pendingAudio == nil ? "0" : "1",
            controller.isGenerating ? "1" : "0",
        ].joined(separator: ":")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(conversationBottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(conversationBottomID, anchor: .bottom)
        }
    }

    private func scrollToRequestedMessageOrBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if let messageID = searchResultTargetID {
            guard displayMessages.contains(where: { $0.id == messageID }) else { return }
            proxy.scrollTo(messageID, anchor: .center)
            searchResultTargetID = nil
        } else {
            scrollToBottom(proxy, animated: animated)
        }
    }
}

private struct InsightGeneratedFileExportView: View {
    @Environment(\.dismiss) private var dismiss

    let file: InsightGeneratedFile
    let onSaved: (UUID) -> Void

    @State private var isExporting = false
    @State private var message: String?
    @State private var didReportSave = false

    private var contentType: UTType {
        switch file.kind {
        case .xlsx:
            .officeOpenXMLSpreadsheet
        case .json:
            .json
        case .csv:
            .commaSeparatedText
        }
    }

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("文件已生成", systemImage: "doc.badge.arrow.up")
            } description: {
                Text("\(file.fileName)\n\(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))")
            } actions: {
                Button("选择保存位置", systemImage: "square.and.arrow.up") {
                    isExporting = true
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("导出文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                isExporting = true
            }
            .fileExporter(
                isPresented: $isExporting,
                document: FarmInterchangeDocument(data: file.data),
                contentType: contentType,
                defaultFilename: file.fileName
            ) { result in
                switch result {
                case .success:
                    message = "文件已保存。"
                    if !didReportSave {
                        didReportSave = true
                        onSaved(file.id)
                    }
                case .failure(let error):
                    if let cancellation = error as? CocoaError, cancellation.code == .userCancelled {
                        message = nil
                    } else {
                        message = "保存失败：\(error.localizedDescription)"
                    }
                }
            }
            .alert("导出文件", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("完成", role: .cancel) {
                    if message == "文件已保存。" {
                        dismiss()
                    }
                }
            } message: {
                Text(LocalizedStringKey(message ?? ""))
            }
        }
    }
}

private struct InsightAvailabilityNotice: View {
    let title: String
    let detail: String
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 5) {
            Label(LocalizedStringKey(title), systemImage: action == nil ? "exclamationmark.circle" : "key.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(detail))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let action {
                Button("打开设置", action: action)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.brand)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

struct InsightContextUsageRing: View {
    let usage: InsightContextWindowUsage
    var diameter: CGFloat = 29

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: ringWidth)
            Circle()
                .trim(from: 0, to: max(0.008, usage.fraction))
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: ringWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
            Text("\(usage.percentage)")
                .font(.system(
                    size: diameter >= 48 ? 13 : 8,
                    weight: .semibold,
                    design: .rounded
                ))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.7)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(.circle)
    }

    private var ringWidth: CGFloat {
        diameter >= 48 ? 5 : 3
    }

    private var tint: Color {
        if usage.fraction >= 0.95 {
            return .red
        }
        if usage.fraction >= 0.8 {
            return .orange
        }
        return AppTheme.brand
    }
}

struct InsightContextUsageDetail: View {
    let usage: InsightContextWindowUsage

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                InsightContextUsageRing(usage: usage, diameter: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text("约 \(tokenText(usage.estimatedTokens)) / \(tokenText(usage.limitTokens))")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("已使用 \(usage.percentage)%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(width: 260)
        .accessibilityElement(children: .contain)
    }

    private func tokenText(_ tokens: Int) -> String {
        guard tokens >= 1_024 else { return "\(tokens)" }
        let value = Double(tokens) / 1_024
        if value >= 100 || value.rounded() == value {
            return "\(Int(value.rounded()))K"
        }
        return String(format: "%.1fK", value)
    }
}

private struct InsightConversationSearchView: View {
    @Environment(\.dismiss) private var dismiss

    let messages: [InsightMessageRecord]
    let drafts: [InsightActionDraftRecord]
    let onSelect: (UUID) -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if normalizedQuery.isEmpty {
                    ContentUnavailableView(
                        "搜索当前对话",
                        systemImage: "text.magnifyingglass",
                        description: Text("输入消息、耳号或操作草案中的关键词")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: normalizedQuery)
                } else {
                    List(results, id: \.id) { message in
                        Button {
                            onSelect(message.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(roleTitle(for: message), systemImage: roleSymbol(for: message))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(
                                        message.createdAt,
                                        format: .dateTime.month().day().hour().minute()
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                                Text(searchPreview(for: message))
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("搜索当前对话")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "消息、耳号或操作草案"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [InsightMessageRecord] {
        guard !normalizedQuery.isEmpty else { return [] }
        return messages.filter { message in
            guard message.toolName != InsightContextCompressor.compressionToolName else {
                return false
            }
            return message.text.localizedStandardContains(normalizedQuery) ||
                draftsForMessage(message.id).contains {
                    $0.title.localizedStandardContains(normalizedQuery) ||
                        $0.summary.localizedStandardContains(normalizedQuery)
                }
        }
    }

    private func draftsForMessage(_ messageID: UUID) -> [InsightActionDraftRecord] {
        drafts.filter { $0.messageID == messageID }
    }

    private func searchPreview(for message: InsightMessageRecord) -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return draftsForMessage(message.id)
            .map { "\($0.title)：\($0.summary)" }
            .joined(separator: "\n")
    }

    private func roleTitle(for message: InsightMessageRecord) -> String {
        switch message.role {
        case .user: "你"
        case .assistant: "AI 助手"
        case .system: "系统"
        case .tool: "工具"
        }
    }

    private func roleSymbol(for message: InsightMessageRecord) -> String {
        switch message.role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .system: "gearshape.fill"
        case .tool: "wrench.and.screwdriver.fill"
        }
    }
}

private struct InsightMessageBubble: View {
    let message: InsightMessageRecord
    let attachments: [InsightAttachmentRecord]
    let storedAudio: StoredInsightAudio?
    let isPlayingAudio: Bool
    let endsRoleGroup: Bool
    let onToggleAudio: () -> Void

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 0) {
                if isUser { Spacer(minLength: 52) }
                VStack(alignment: .leading, spacing: 8) {
                    if !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(attachments, id: \.id) { attachment in
                                    if let data = attachment.imageData {
                                        DownsampledDataImage(
                                            data: data,
                                            digest: attachment.digest,
                                            targetSize: CGSize(width: 150, height: 120)
                                        ) {
                                            Rectangle()
                                                .fill(.fill.tertiary)
                                                .overlay { ProgressView().controlSize(.small) }
                                        }
                                            .frame(width: 150, height: 120)
                                            .clipShape(.rect(cornerRadius: 13))
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    if isVoiceMessage {
                        voiceMessage
                    }
                    if !message.text.isEmpty && message.text != "语音消息" {
                        InsightMarkdownView(
                            message.text,
                            foregroundColor: isUser ? .white : .primary,
                            tableBackgroundColor: isUser
                                ? .white.opacity(0.12)
                                : Color(uiColor: .systemBackground).opacity(0.68),
                            tableAccentColor: isUser ? .white : AppTheme.brand,
                            expandsHorizontally: !isUser
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleColor, in: bubbleShape)
                if !isUser { Spacer(minLength: 52) }
            }

            if let statusText {
                Group {
                    if message.status == .failed {
                        Label(LocalizedStringKey(statusText), systemImage: "exclamationmark.circle")
                    } else {
                        Text(LocalizedStringKey(statusText))
                    }
                }
                .font(.caption2)
                .foregroundStyle(message.status == .failed ? .red : .secondary)
                .padding(.horizontal, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var isUser: Bool {
        message.role == .user
    }

    private var isVoiceMessage: Bool {
        message.toolName == "audio_input" || message.toolName == "audio_document_input"
    }

    @ViewBuilder
    private var voiceMessage: some View {
        if let storedAudio {
            HStack(spacing: 9) {
                Button(action: onToggleAudio) {
                    Image(systemName: isPlayingAudio ? "pause.fill" : "play.fill")
                        .font(.caption.bold())
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.18), in: .circle)
                }
                .buttonStyle(.plain)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(isPlayingAudio ? "暂停已发送语音" : "播放已发送语音")

                InsightAudioWaveform(
                    samples: storedAudio.waveformSamples,
                    color: .white,
                    inactiveOpacity: 0.38
                )
                .frame(minWidth: 104, maxWidth: 176)

                Text(formatDuration(storedAudio.duration))
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
        } else {
            Label("语音未在本机保留", systemImage: "waveform.slash")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityLabel("这条语音没有本机副本")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var bubbleColor: Color {
        isUser ? Color(uiColor: .systemBlue) : Color(uiColor: .secondarySystemFill)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 19,
            bottomLeadingRadius: !isUser && endsRoleGroup ? 5 : 19,
            bottomTrailingRadius: isUser && endsRoleGroup ? 5 : 19,
            topTrailingRadius: 19,
            style: .continuous
        )
    }

    private var statusText: String? {
        switch message.status {
        case .pending:
            isUser ? "正在发送…" : nil
        case .streaming:
            nil
        case .completed:
            isUser ? "已发送" : nil
        case .failed:
            isUser ? "发送未完成" : "内部处理未完成"
        case .cancelled:
            "已停止"
        }
    }
}

private struct InsightConversationMessageRow: View {
    let message: InsightMessageRecord
    let farmName: String
    let attachments: [InsightAttachmentRecord]
    let storedAudio: StoredInsightAudio?
    let isPlayingAudio: Bool
    let drafts: [InsightActionDraftRecord]
    let endsRoleGroup: Bool
    let canExecute: (InsightActionDraftRecord) -> Bool
    let executionCount: (InsightActionDraftRecord) -> Int
    let draftPresentation: (InsightActionDraftRecord) -> InsightActionDraftPresentation
    let onToggleAudio: () -> Void
    let onReview: (InsightActionDraftRecord) -> Void
    let onReject: (InsightActionDraftRecord) -> Void

    var body: some View {
        if message.toolName == InsightContextCompressor.compressionToolName {
            InsightContextCompressionNotice()
            .id(message.id)
        } else {
            if message.role != .assistant || message.status != .streaming || !message.text.isEmpty || !attachments.isEmpty {
                InsightMessageBubble(
                    message: message,
                    attachments: attachments,
                    storedAudio: storedAudio,
                    isPlayingAudio: isPlayingAudio,
                    endsRoleGroup: endsRoleGroup,
                    onToggleAudio: onToggleAudio
                )
                .id(message.id)
            } else {
                Color.clear.frame(height: 0).id(message.id)
            }
            ForEach(drafts, id: \.id) { draft in
                InsightActionDraftCard(
                    draft: draft,
                    farmName: farmName,
                    isOriginDevice: canExecute(draft),
                    executionCount: executionCount(draft),
                    presentation: draftPresentation(draft),
                    onReview: { onReview(draft) },
                    onReject: { onReject(draft) }
                )
                .id(draft.id)
            }
        }
    }

}

private struct InsightContextCompressionNotice: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("上下文已自动压缩")
                    .font(.subheadline.weight(.semibold))
                Text("会话达到约 512K，已压缩较早内容并保留最近对话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct InsightConversationTimestamp: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.month().day().weekday(.abbreviated).hour().minute())
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

private struct InsightAssistantTypingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("AI 助手正在处理…")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemFill), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("AI 助手正在处理")
    }
}

private struct InsightActionDraftCard: View {
    let draft: InsightActionDraftRecord
    let farmName: String
    let isOriginDevice: Bool
    let executionCount: Int
    let presentation: InsightActionDraftPresentation
    let onReview: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("操作草案", systemImage: deviceSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.brand)
                Spacer()
                Text(LocalizedStringKey(statusText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(LocalizedStringKey(draft.title))
                .font(.headline)
            Text(LocalizedStringKey(draft.summary))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label(farmName, systemImage: "building.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let importPayload = presentation.importPayload {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(importPayload.sections.prefix(6), id: \.self) { section in
                        Label(section, systemImage: "checkmark.circle")
                    }
                    LabeledContent(
                        "文件大小",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(importPayload.byteCount),
                            countStyle: .file
                        )
                    )
                    if importPayload.warningCount > 0 {
                        Label(
                            "\(importPayload.warningCount) 条提醒，执行前已重新校验",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let occurredAt = presentation.occurredAt {
                LabeledContent("发生日期") {
                    Text(
                        occurredAt,
                        format: .dateTime.year().month().day().hour().minute()
                    )
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if draft.risk == .high, draft.status == .proposed {
                Label("执行前需要 Face ID / Touch ID", systemImage: "faceid")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = draft.errorMessage {
                Text(LocalizedStringKey(error))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if draft.status == .executed,
               draft.toolName != "draft_reminder", draft.toolName != "draft_calendar_event" {
                InsightDraftCloudSaveStatus(draft: draft)
            }
            if draft.status == .proposed {
                HStack {
                    Button(LocalizedStringKey(primaryActionTitle), action: onReview)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isOriginDevice)
                    Button("拒绝", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(15)
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
    }

    private var primaryActionTitle: String {
        guard draft.risk == .high else { return "检查并确认" }
        return executionCount > 1 ? "执行同批 \(executionCount) 条" : "执行操作"
    }

    private var deviceSymbol: String {
        draft.toolName == "draft_reminder" || draft.toolName == "draft_calendar_event"
            ? "iphone.gen3"
            : "doc.badge.gearshape"
    }

    private var statusText: String {
        switch draft.status {
        case .proposed: "待确认"
        case .approved: "已批准"
        case .executed: "本机已执行"
        case .rejected: "已拒绝"
        case .stale: "已过期"
        case .failed: "执行失败"
        }
    }
}

/// Observe only this card's requests, including the linked weaning transfer.
/// Superseded originals retain evidence but do not count twice after recovery.
private struct InsightDraftCloudSaveStatus: View {
    @Query private var intents: [ESheepCloudPendingIntent]
    private let isWeaning: Bool

    init(draft: InsightActionDraftRecord) {
        let sourceID = draft.id
        let transferID = WeaningWorkflow.transferSourceRequestID(for: sourceID)
        let farmID = draft.farmID
        let accountID = draft.accountID
        isWeaning = draft.toolName == "draft_record_weaning"
        _intents = Query(filter: #Predicate<ESheepCloudPendingIntent> {
            $0.farmID == farmID && $0.accountID == accountID &&
                ($0.sourceRequestID == sourceID || $0.sourceRequestID == transferID) &&
                $0.lifecycleRawValue != "supersededLocally"
        })
    }

    var body: some View {
        if !intents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(intents) { intent in
                    let name = intent.commandKind == "weaning.record" ? "断奶" :
                        (intent.commandKind == "transfer.record" ? "调舍" : "记录")
                    Text("\(name)：\(status(intent))")
                        .foregroundStyle(intent.lifecycle == .rejected ? Color.red : Color.secondary)
                }
                if isWeaning && !intents.contains(where: { $0.commandKind == "transfer.record" }) {
                    Text("调舍：尚未找到云端确认记录").foregroundStyle(.orange)
                }
                if intents.contains(where: { $0.lifecycle == .rejected || $0.lifecycle == .needsConfirmation }) {
                    Text("请到 eSheep+ 云查看具体失败原因和核对信息。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private func status(_ intent: ESheepCloudPendingIntent) -> String {
        switch intent.lifecycle {
        case .accepted: "云端已确认"
        case .rejected: "云端未保存，本机内容已保留"
        case .needsConfirmation: "存在冲突，需要确认"
        default: "本机已保存，等待云端确认"
        }
    }
}

private struct InsightPendingInputPreview: View {
    @Binding var pendingImages: [PendingInsightImage]

    var body: some View {
        HStack {
            Spacer(minLength: 52)
            VStack(alignment: .leading, spacing: 10) {
                if !pendingImages.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(pendingImages) { pending in
                                ZStack(alignment: .topTrailing) {
                                    DownsampledDataImage(
                                        data: pending.data,
                                        digest: pending.digest,
                                        targetSize: CGSize(width: 70, height: 62)
                                    ) {
                                        Rectangle()
                                            .fill(.fill.tertiary)
                                            .overlay { ProgressView().controlSize(.small) }
                                    }
                                    .frame(width: 70, height: 62)
                                    .clipShape(.rect(cornerRadius: 10))
                                    Button {
                                        pendingImages.removeAll { $0.id == pending.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.65))
                                            .frame(width: 44, height: 44)
                                    }
                                    .offset(x: 5, y: -5)
                                }
                            }
                        }
                        .padding(.horizontal, 3)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(12)
            .background(.fill.tertiary, in: .rect(cornerRadius: 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InsightAudioWaveform: View {
    let samples: [Float]
    let color: Color
    let inactiveOpacity: Double

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(displayedSamples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(color.opacity(sample <= 0.08 ? inactiveOpacity : 1))
                    .frame(width: 2, height: max(3, CGFloat(sample) * 22))
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }

    private var displayedSamples: [Float] {
        let maximumCount = 36
        guard !samples.isEmpty else {
            return Array(repeating: 0.08, count: maximumCount)
        }
        if samples.count <= maximumCount {
            return Array(repeating: 0.08, count: maximumCount - samples.count) + samples
        }
        let stride = Double(samples.count - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { index in
            samples[Int((Double(index) * stride).rounded())]
        }
    }
}

private struct InsightDraftConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: InsightActionDraftRecord
    let farmName: String
    let onConfirm: () -> Void
    @State private var payloadText: String
    @State private var payloadError: String?

    init(
        draft: InsightActionDraftRecord,
        farmName: String,
        initialPayloadText: String?,
        initialPayloadError: String?,
        onConfirm: @escaping () -> Void
    ) {
        self.draft = draft
        self.farmName = farmName
        self.onConfirm = onConfirm
        _payloadText = State(initialValue: initialPayloadText ?? "")
        _payloadError = State(initialValue: initialPayloadError)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("将要执行") {
                    LabeledContent("牧场", value: farmName)
                    LabeledContent("操作", value: draft.title)
                    Text(LocalizedStringKey(draft.summary))
                    LabeledContent("所需权限", value: draft.requiredCapabilityRawValue)
                }
                Section {
                    TextEditor(text: $payloadText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("可编辑字段")
                } footer: {
                    Text("这里修改的是真实结构化草案。确认前 App 会重新解析，并再次校验命令类型、牧场归属、权限、revision 和风险。")
                }
                Section("影响与风险") {
                    Text(draft.risk == .high
                         ? "该操作会修改关键历史或库存等权威事实，执行前需要设备生物认证。"
                         : "确认后才会写入；模型本身不能直接执行。")
                }
            }
            .navigationTitle("检查操作草案")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认执行", action: confirm)
                        .disabled(
                            payloadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .alert("草案字段无效", isPresented: Binding(
                get: { payloadError != nil },
                set: { if !$0 { payloadError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(payloadError ?? ""))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func confirm() {
        do {
            try InsightToolRegistry().updateDraftPayload(payloadText, for: draft)
            onConfirm()
        } catch {
            payloadError = error.localizedDescription
        }
    }
}

private struct InsightCameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
