import SwiftData
import SwiftUI
import UIKit

struct FarmInsightConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var conversations: [InsightConversationRecord]
    @Query private var messages: [InsightMessageRecord]
    let account: AccountProfile
    let farm: FarmRecord
    let initialPrompt: String?
    @State private var search = ""
    @State private var showSearch = false
    @State private var showSettings = false
    @AppStorage private var currentDeviceOnly: Bool
    @State private var destination: InsightChatDestination?
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var didApplyInitialPrompt = false
    @State private var isAnalysisSettingsPresented = false
    @State private var isContextUsagePresented = false
    @State private var focusBeforeSettings = false
    @State private var composerAudioRecorder = InsightAudioRecorder()
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var draftSaveError: String?
    @FocusState private var composerFocused: Bool
    private let coordinator = InsightSessionCoordinator.shared

    init(account: AccountProfile, farm: FarmRecord, initialPrompt: String? = nil) {
        self.account = account
        self.farm = farm
        self.initialPrompt = initialPrompt
        let accountID = account.effectiveAccountID
        let farmID = farm.id
        _currentDeviceOnly = AppStorage(wrappedValue: false,
            "insights.list.current-device-only.\(accountID.uuidString).\(farmID.uuidString)")
        _conversations = Query(filter: #Predicate<InsightConversationRecord> {
            $0.accountID == accountID && $0.farmID == farmID && $0.deletedAt == nil
        }, sort: [SortDescriptor(\.updatedAt, order: .reverse)])
        _messages = Query(filter: #Predicate<InsightMessageRecord> {
            $0.accountID == accountID && $0.farmID == farmID
        }, sort: [SortDescriptor(\.createdAt)])
    }

    private var scope: InsightConversationScope { .init(accountID: account.effectiveAccountID, farmID: farm.id) }
    private var sessionScope: InsightSessionScope { .init(accountID: account.effectiveAccountID, farmID: farm.id) }
    private var draft: InsightComposerDraft { coordinator.draft(scope: scope, conversationID: nil) }
    private var draftController: InsightConversationController {
        coordinator.controller(account: account, farm: farm, conversationID: nil, draftID: draft.draftID)
    }
    private var currentDeviceConversationIDs: Set<UUID> {
        Set(coordinator.requestQueue.entries.values.filter { $0.scope == sessionScope }.compactMap(\.conversationID))
    }
    private var normalizedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchMatches: [UUID: InsightMessageRecord] {
        guard !normalizedSearch.isEmpty else { return [:] }
        var matches: [UUID: InsightMessageRecord] = [:]
        for message in messages where (message.role == .user || message.role == .assistant) && message.toolName == nil {
            if matches[message.conversationID] == nil, message.text.localizedStandardContains(normalizedSearch) {
                matches[message.conversationID] = message
            }
        }
        return matches
    }
    private var lastAssistantMessages: [UUID: InsightMessageRecord] {
        var last: [UUID: InsightMessageRecord] = [:]
        for message in messages where message.role == .assistant && message.toolName == nil { last[message.conversationID] = message }
        return last
    }

    var body: some View {
#if DEBUG
        let _ = traceBodyChanges()
#endif
        @Bindable var draft = draft
        let matches = searchMatches
        let lastMessages = lastAssistantMessages
        let deviceIDs = currentDeviceConversationIDs
        let filteredConversations = conversations.filter {
            (!currentDeviceOnly || deviceIDs.contains($0.id)) &&
                (normalizedSearch.isEmpty || $0.title.localizedStandardContains(normalizedSearch) || matches[$0.id] != nil)
        }
        InsightConversationListContent(
            conversations: filteredConversations,
            matches: matches,
            lastMessages: lastMessages,
            normalizedSearch: normalizedSearch,
            scope: scope,
            coordinator: coordinator,
            currentDeviceOnly: $currentDeviceOnly,
            onOpen: open,
            onNewConversation: { openDraft() },
            onDelete: delete
        )
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationTitle("聊天")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            InsightConversationListToolbar(
                farmName: farm.name,
                showSettings: $showSettings,
                showSearch: $showSearch,
                composerFocused: $composerFocused
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let draftSaveError {
                    Text(draftSaveError).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                }
                if !showSearch { listComposer }
            }
        }
        .navigationDestination(item: $destination) { route in
            FarmInsightConversationView(account: account, farm: farm, controller: route.controller,
                conversationID: route.conversationID, draftID: route.draftID,
                searchTargetMessageID: route.messageID, initialAction: route.initialAction,
                onNewConversation: { openDraft() })
                .id(route.id)
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await draftController.refreshCredential() } }) {
            InsightAssistantSettingsView(account: account, farm: farm)
        }
        .task(id: draft.draftID) {
            do { try await coordinator.draftStore.restore(scope: sessionScope, conversationID: nil) }
            catch { errorMessage = "草稿恢复失败，现有聊天仍可查看。" }
            if !didApplyInitialPrompt {
                didApplyInitialPrompt = true
                if let initialPrompt, !draft.hasContent { draft.text = initialPrompt }
            }
            await coordinator.connect(draftController, to: modelContext)
        }
        .onChange(of: draft.revision) { _, _ in saveDraft() }
        .onDisappear { saveDraft(immediately: true) }
        .alert("暂时无法完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

#if DEBUG
    private func traceBodyChanges() {
        guard ProcessInfo.processInfo.arguments.contains("--design-acceptance"),
              InsightListRenderDiagnostic.remaining > 0 else { return }
        InsightListRenderDiagnostic.remaining -= 1
        Self._printChanges()
    }
#endif

    private var listComposer: some View {
        @Bindable var draft = draft
        let controller = draftController
        let mode = InsightSubmissionMode(rawValue: draft.modeRawValue) ?? .conversation
        return InsightComposerView(
            text: $draft.text, isFocused: $composerFocused,
            audioRecorder: composerAudioRecorder, pendingAudio: nil, isPlayingAudio: false,
            isGenerating: controller.isGenerating, isSubmitting: isSubmitting,
            isEnabled: isReady && !isSubmitting, isListEntry: true, hasAttachments: hasDraftAttachments,
            attachmentsReady: draft.documents.allSatisfy(\.isReadyToSend),
            modeTitle: mode == .conversation ? nil : mode.title,
            isPlanSelected: mode == .plan, isGoalSelected: mode == .goal,
            onCamera: { openDraft(action: .camera) }, onPhotos: { openDraft(action: .photos) },
            onFiles: { openDraft(action: .files) }, onPlan: { toggleMode(.plan) }, onGoal: { toggleMode(.goal) },
            onRemoveMode: { draft.modeRawValue = InsightSubmissionMode.conversation.rawValue },
            onSettings: {
                controller.reloadAnalysisPreference()
                focusBeforeSettings = composerFocused
                isAnalysisSettingsPresented = true
            },
            onMicrophonePressChanged: { _ in }, onMicrophoneLongPress: {},
            onMicrophone: { openDraft(action: .voice) }, onToggleAudioPlayback: {}, onDiscardAudio: {},
            onSend: send, onStop: controller.stopGenerating,
            attachments: { draftAttachmentSummary }, context: { contextUsageButton }
        )
        .popover(isPresented: $isAnalysisSettingsPresented) {
            InsightAnalysisSettingsPopover(
                effortIndex: Binding(get: { controller.analysisEffort.sliderValue }, set: { controller.analysisEffort = .from(sliderValue: $0) }),
                thinkingEnabled: Binding(get: { controller.thinkingEnabled }, set: { controller.thinkingEnabled = $0 }),
                showReasoning: Binding(get: { controller.showReasoning }, set: { controller.showReasoning = $0 }),
                modelName: controller.modelDisplayName
            )
            .presentationCompactAdaptation(.popover)
            .presentationBackground(.clear)
        }
        .onChange(of: isAnalysisSettingsPresented) { _, presented in
            if !presented && focusBeforeSettings { composerFocused = true }
        }
    }

    private var hasDraftAttachments: Bool { !draft.images.isEmpty || !draft.documents.isEmpty || draft.audio != nil }

    private var draftAttachmentSummary: some View {
        Button { openDraft() } label: {
            VStack(alignment: .leading, spacing: 4) {
                if !draft.images.isEmpty { Label("\(draft.images.count) 张照片", systemImage: "photo.on.rectangle") }
                ForEach(draft.documents) { document in Label(document.fileName, systemImage: "doc.text").lineLimit(1) }
                if let audio = draft.audio { Label("语音 \(Int(audio.duration)) 秒", systemImage: "waveform") }
                Text("查看或编辑附件").foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.fill.tertiary, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    private var contextUsageButton: some View {
        Button { isContextUsagePresented.toggle() } label: {
            InsightContextUsageRing(usage: draftController.contextWindowUsage).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("上下文窗口已使用约 \(draftController.contextWindowUsage.percentage)%")
        .popover(isPresented: $isContextUsagePresented) {
            InsightContextUsageDetail(usage: draftController.contextWindowUsage).presentationCompactAdaptation(.popover)
        }
    }

    private var isReady: Bool { if case .ready = draftController.availability { true } else { false } }

    private func open(_ conversation: InsightConversationRecord, messageID: UUID?) {
        let controller = coordinator.controller(account: account, farm: farm, conversationID: conversation.id)
        Task {
            await coordinator.connect(controller, to: modelContext, preferredConversationID: conversation.id)
            guard coordinator.requestQueue.activeScope == sessionScope, scope.contains(conversation) else { return }
            composerFocused = false
            destination = .init(id: conversation.id, controller: controller, conversationID: conversation.id, draftID: nil, messageID: messageID, initialAction: nil)
        }
    }

    private func openDraft(action: InsightChatInitialAction? = nil) {
        composerFocused = false
        destination = .init(id: draft.draftID, controller: draftController, conversationID: nil,
            draftID: draft.draftID, messageID: nil, initialAction: action)
    }

    private func send() {
        let submittedDraft = draft
        let controller = draftController
        guard !isSubmitting, !controller.isGenerating, isReady, submittedDraft.hasContent,
              coordinator.allowsWork(scope: scope) else { return }
        isSubmitting = true
        let draftID = submittedDraft.draftID
        let draftRevision = submittedDraft.revision
        let text = submittedDraft.text
        let images = submittedDraft.images
        let audio = submittedDraft.audio
        let documents = submittedDraft.documents
        let submittedScope = scope
        let submittedSessionScope = sessionScope
        controller.submissionMode = InsightSubmissionMode(rawValue: submittedDraft.modeRawValue) ?? .conversation
        Task {
            defer { isSubmitting = false }
            guard await controller.send(text: text, images: images, audio: audio, documents: documents),
                  let id = controller.currentConversationID else {
                errorMessage = controller.errorMessage
                return
            }
            coordinator.completeDraft(scope: submittedScope, draftID: draftID, conversationID: id, controller: controller,
                expectedDraftRevision: draftRevision)
            guard coordinator.requestQueue.activeScope == submittedSessionScope, scope == submittedScope else { return }
            composerFocused = false
            destination = .init(id: id, controller: controller, conversationID: id, draftID: nil, messageID: nil, initialAction: nil)
        }
    }

    private func toggleMode(_ mode: InsightSubmissionMode) {
        draft.modeRawValue = draft.modeRawValue == mode.rawValue ? InsightSubmissionMode.conversation.rawValue : mode.rawValue
    }

    private func saveDraft(immediately: Bool = false) {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                try await coordinator.draftStore.save(scope: sessionScope, conversationID: nil)
                draftSaveError = nil
            } catch is CancellationError {
                return
            } catch {
                draftSaveError = "草稿尚未保存，当前内容仍保留在本机页面。"
            }
        }
    }
    private func delete(_ conversation: InsightConversationRecord) {
        coordinator.delete(conversation, using: draftController)
        if let error = draftController.errorMessage { errorMessage = error }
    }
}

#if DEBUG
@MainActor
private enum InsightListRenderDiagnostic {
    static var remaining = 40
}
#endif

private struct InsightChatDestination: Identifiable, Hashable {
    let id: UUID
    let controller: InsightConversationController
    let conversationID: UUID?
    let draftID: UUID?
    let messageID: UUID?
    let initialAction: InsightChatInitialAction?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct InsightConversationListRow: View {
    let title: String
    let excerpt: String?
    let state: InsightSessionRunState?
    let goalStatus: InsightGoalStatus?
    let lastMessage: InsightMessageRecord?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).foregroundStyle(.primary).lineLimit(1)
                if let excerpt { Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if state == .running { ProgressView().controlSize(.small).accessibilityLabel("处理中") }
            else if state == .queued { Text("排队").font(.caption).foregroundStyle(.secondary) }
            else if state == .paused { Text("已暂停").font(.caption).foregroundStyle(.secondary) }
            else if let goalStatus { Text(goalStatus.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            else if lastMessage?.status == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityLabel("回复失败") }
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

@MainActor
private struct InsightConversationListContent: View {
    let conversations: [InsightConversationRecord]
    let matches: [UUID: InsightMessageRecord]
    let lastMessages: [UUID: InsightMessageRecord]
    let normalizedSearch: String
    let scope: InsightConversationScope
    let coordinator: InsightSessionCoordinator
    @Binding var currentDeviceOnly: Bool
    let onOpen: (InsightConversationRecord, UUID?) -> Void
    let onNewConversation: () -> Void
    let onDelete: (InsightConversationRecord) -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    filterButton("全部", selected: !currentDeviceOnly) { currentDeviceOnly = false }
                    filterButton(UIDevice.current.userInterfaceIdiom == .pad ? "此 iPad" : "此 iPhone", selected: currentDeviceOnly) { currentDeviceOnly = true }
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(conversations, id: \.id) { conversation in
                    let match: InsightMessageRecord? = matches[conversation.id]
                    let state: InsightSessionRunState? = coordinator.state(scope: scope, conversationID: conversation.id)
                    let goalStatus: InsightGoalStatus? = coordinator.cachedController(scope: scope, conversationID: conversation.id)?.activeGoalStatus
                    InsightConversationListButton(
                        title: conversation.title,
                        excerpt: normalizedSearch.isEmpty ? nil : match?.text,
                        state: state,
                        goalStatus: goalStatus,
                        lastMessage: lastMessages[conversation.id],
                        onOpen: { onOpen(conversation, match?.id) },
                        onDelete: { onDelete(conversation) }
                    )
                }
                if conversations.isEmpty && !normalizedSearch.isEmpty {
                    ContentUnavailableView.search(text: normalizedSearch)
                        .listRowSeparator(.hidden)
                }
            } header: {
                HStack {
                    Text(normalizedSearch.isEmpty ? "最近" : "搜索结果").textCase(nil)
                    Spacer()
                    Button(action: onNewConversation) {
                        Image(systemName: "square.and.pencil").font(.body)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("新聊天")
                }
            }
        }
    }

    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 15).frame(minHeight: 38)
                .background(selected ? Color.primary.opacity(0.08) : Color.clear, in: .capsule)
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }
}

@MainActor
private struct InsightConversationListButton: View {
    let title: String
    let excerpt: String?
    let state: InsightSessionRunState?
    let goalStatus: InsightGoalStatus?
    let lastMessage: InsightMessageRecord?
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            InsightConversationListRow(
                title: title,
                excerpt: excerpt,
                state: state,
                goalStatus: goalStatus,
                lastMessage: lastMessage
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Color(uiColor: .systemBackground))
        .contextMenu {
            Button("删除聊天", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

@MainActor
private struct InsightConversationListToolbar: ToolbarContent {
    let farmName: String
    @Binding var showSettings: Bool
    @Binding var showSearch: Bool
    @FocusState.Binding var composerFocused: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Text(farmName)
                Button("AI 设置", systemImage: "gearshape") { showSettings = true }
            } label: { Image(systemName: "line.3.horizontal") }
            .accessibilityLabel("聊天菜单")
        }
        ToolbarItem(placement: .principal) {
            Menu {
                Label("MiMo · 本机执行", systemImage: "checkmark")
            } label: {
                HStack(spacing: 5) {
                    Text("MiMo").font(.headline)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("当前服务 MiMo")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { composerFocused = false; showSearch = true } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel("搜索当前牧场聊天")
        }
    }
}
