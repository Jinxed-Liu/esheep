import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum InsightAudioPlaybackSource: Equatable {
    case pending
    case sentMessage(UUID)
}

struct FarmInsightConversationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var attachments: [InsightAttachmentRecord]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var controller: InsightConversationController
    @State private var audioRecorder = InsightAudioRecorder()
    @State private var audioPlayer = InsightAudioPreviewPlayer()
    @State private var input = ""
    @State private var inputOrigin = InsightInputOrigin.text
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pendingImages: [PendingInsightImage] = []
    @State private var pendingAudio: PendingInsightAudio?
    @State private var storedAudioByMessageID: [UUID: StoredInsightAudio] = [:]
    @State private var audioPlaybackSource: InsightAudioPlaybackSource?
    @State private var isPhotoLibraryPresented = false
    @State private var isCameraPresented = false
    @State private var isImportFilePresented = false
    @State private var isHistoryPresented = false
    @State private var isConversationSearchPresented = false
    @State private var isContextUsagePresented = false
    @State private var searchResultTargetID: UUID?
    @State private var selectedDraft: InsightActionDraftRecord?
    @State private var isMicrophonePressed = false
    @State private var didActivateMicrophoneLongPress = false
    @FocusState private var isComposerFocused: Bool
    private let conversationBottomID = "insight-conversation-bottom"

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        _controller = State(initialValue: InsightConversationController(account: account, farm: farm))
    }

    var body: some View {
        conversationScroll
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("AI 助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    assistantIdentity
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isComposerFocused = false
                        isConversationSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索当前对话")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    assistantMenu
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InsightComposerBar(
                    text: $input,
                    isFocused: $isComposerFocused,
                    audioRecorder: audioRecorder,
                    isKeyboardPresented: isComposerFocused,
                    isGenerating: controller.isGenerating,
                    isEnabled: isReady,
                    hasPendingImages: !pendingImages.isEmpty,
                    pendingAudio: pendingAudio,
                    isPlayingAudio: audioPlayer.isPlaying && audioPlaybackSource == .pending,
                    onPhotoLibrary: {
                        guard pendingImages.count < 4 else {
                            controller.errorMessage = "每条消息最多选择 4 张图片。"
                            return
                        }
                        isComposerFocused = false
                        isPhotoLibraryPresented = true
                    },
                    onCamera: { isCameraPresented = true },
                    onImportData: { isImportFilePresented = true },
                    onMicrophonePressChanged: microphonePressChanged,
                    onMicrophoneLongPress: activateMicrophoneLongPress,
                    onMicrophoneAccessibilityAction: toggleSpeechForAccessibility,
                    onToggleAudioPlayback: toggleAudioPlayback,
                    onDiscardAudio: discardPendingAudio,
                    suggestions: suggestions,
                    onSuggestion: selectSuggestion,
                    onSend: send,
                    onStop: controller.stopGenerating
                )
            }
            .task(id: farm.id) {
                guard isControllerBoundToFarm else {
                    controller.errorMessage = "牧场已切换，请重新进入 AI 助手。"
                    return
                }
                await controller.connect(to: modelContext)
            }
            .task(id: storedAudioRevision) {
                await loadStoredAudio()
            }
            .onChange(of: photoItems) { _, items in
                loadPhotos(items)
            }
            .onChange(of: audioRecorder.errorMessage) { _, error in
                if let error { controller.errorMessage = error }
            }
            .onDisappear {
                controller.stopGenerating()
                audioRecorder.discard()
                audioPlayer.stop()
            }
            .photosPicker(
                isPresented: $isPhotoLibraryPresented,
                selection: $photoItems,
                maxSelectionCount: max(1, 4 - pendingImages.count),
                matching: .images
            )
            .sheet(isPresented: $isHistoryPresented) {
                InsightConversationHistoryView(controller: controller)
            }
            .sheet(isPresented: $isConversationSearchPresented) {
                InsightConversationSearchView(
                    messages: controller.messages,
                    drafts: controller.drafts
                ) { messageID in
                    searchResultTargetID = messageID
                    isConversationSearchPresented = false
                }
            }
            .sheet(item: $selectedDraft) { draft in
                let presentation = controller.presentation(for: draft)
                InsightDraftConfirmationView(
                    draft: draft,
                    farmName: farm.name,
                    initialPayloadText: presentation.editablePayloadText,
                    initialPayloadError: presentation.editablePayloadError,
                    onConfirm: {
                        selectedDraft = nil
                        Task { await controller.execute(draft) }
                    }
                )
            }
            .sheet(item: $controller.pendingGeneratedFile) { file in
                InsightGeneratedFileExportView(file: file)
            }
            .sheet(isPresented: $isCameraPresented) {
                InsightCameraPicker { image in
                    isCameraPresented = false
                    guard let data = image.jpegData(compressionQuality: 0.95) else { return }
                    optimizeAndAppend(data)
                }
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
            .alert(
                "AI 助手",
                isPresented: Binding(
                    get: { controller.errorMessage != nil },
                    set: { if !$0 { controller.errorMessage = nil } }
                ),
                actions: {
                    if controller.messages.last?.status == .failed {
                        Button("重试") { controller.retryLastMessage() }
                    }
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
                    if !controller.messages.isEmpty {
                        ForEach(Array(controller.messages.enumerated()), id: \.element.id) { index, message in
                            if shouldShowTimestamp(at: index, in: controller.messages) {
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
                                endsRoleGroup: endsRoleGroup(at: index, in: controller.messages),
                                canExecute: controller.canExecute,
                                executionCount: controller.executionCount,
                                draftPresentation: controller.presentation,
                                onToggleAudio: { toggleStoredAudioPlayback(messageID: message.id) },
                                onReview: review,
                                onReject: reject
                            )
                        }
                    }
                    if !pendingImages.isEmpty {
                        InsightPendingInputPreview(
                            pendingImages: $pendingImages
                        )
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
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: scrollRevision) { _, _ in
                scrollToBottom(proxy, animated: true)
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

    private var assistantIdentity: some View {
        let usage = controller.contextWindowUsage
        return HStack(spacing: 8) {
            Image("MiMoAssistantAvatar")
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(.circle)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.82), lineWidth: 1)
                }
                .shadow(color: AppTheme.brand.opacity(0.12), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 0) {
                Text("AI 助手")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(farm.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                isContextUsagePresented.toggle()
            } label: {
                InsightContextUsageRing(usage: usage)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "上下文窗口已使用约 \(usage.percentage)%"
            )
            .popover(isPresented: $isContextUsagePresented) {
                InsightContextUsageDetail(
                    usage: usage
                )
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var assistantMenu: some View {
        Menu {
            Button("新会话", systemImage: "square.and.pencil") {
                controller.startNewConversation()
            }
            Button("历史会话", systemImage: "clock.arrow.circlepath") {
                isHistoryPresented = true
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("AI 助手菜单")
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

    private var isReady: Bool {
        if case .ready = controller.availability {
            return isControllerBoundToFarm && controller.canUseAssistant
        }
        return false
    }

    private var isControllerBoundToFarm: Bool {
        controller.conversationScope == InsightConversationScope(
            accountID: account.effectiveAccountID,
            farmID: farm.id
        )
    }

    private func send() {
        guard isReady else {
            controller.errorMessage = "请先前往账户头像中的“AI 助手”设置，配置并保存 MiMo API Key。"
            return
        }
        let submitted = input
        let images = pendingImages
        audioPlayer.stop()
        controller.send(
            text: submitted,
            images: images,
            audio: pendingAudio,
            origin: inputOrigin
        )
        input = ""
        pendingImages = []
        pendingAudio = nil
        photoItems = []
        inputOrigin = .text
    }

    private func selectSuggestion(_ prompt: String) {
        input = prompt
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
        guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pendingImages.isEmpty,
              pendingAudio == nil,
              !controller.isGenerating else {
            return
        }
        didActivateMicrophoneLongPress = true
        audioPlayer.stop()
        Task {
            await audioRecorder.start()
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
        Task { @MainActor in
            defer { photoItems = [] }
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
            .filter { $0.toolName == "audio_input" }
            .map(\.id.uuidString)
            .joined(separator: ",")
        return "\(controller.currentConversationID?.uuidString ?? "none"):\(audioMessageIDs)"
    }

    private func loadStoredAudio() async {
        guard let conversationID = controller.currentConversationID else {
            storedAudioByMessageID = [:]
            return
        }
        let audioMessages = controller.messages.filter { $0.toolName == "audio_input" }
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
            Task { await controller.execute(draft) }
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
        let last = controller.messages.last
        return [
            String(controller.messages.count),
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
}

private struct InsightGeneratedFileExportView: View {
    @Environment(\.dismiss) private var dismiss

    let file: InsightGeneratedFile

    @State private var isExporting = false
    @State private var message: String?

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
                case .failure(let error):
                    message = "保存失败：\(error.localizedDescription)"
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

private struct InsightContextUsageRing: View {
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

private struct InsightContextUsageDetail: View {
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
        message.toolName == "audio_input"
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
            "发送失败"
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
            InsightMessageBubble(
                message: message,
                attachments: attachments,
                storedAudio: storedAudio,
                isPlayingAudio: isPlayingAudio,
                endsRoleGroup: endsRoleGroup,
                onToggleAudio: onToggleAudio
            )
                .id(message.id)
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
            Text("AI 助手正在输入…")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemFill), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("AI 助手正在输入")
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
        case .executed: "已执行"
        case .rejected: "已拒绝"
        case .stale: "已过期"
        case .failed: "执行失败"
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

private struct InsightComposerBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let audioRecorder: InsightAudioRecorder
    let isKeyboardPresented: Bool
    let isGenerating: Bool
    let isEnabled: Bool
    let hasPendingImages: Bool
    let pendingAudio: PendingInsightAudio?
    let isPlayingAudio: Bool
    let onPhotoLibrary: () -> Void
    let onCamera: () -> Void
    let onImportData: () -> Void
    let onMicrophonePressChanged: (Bool) -> Void
    let onMicrophoneLongPress: () -> Void
    let onMicrophoneAccessibilityAction: () -> Void
    let onToggleAudioPlayback: () -> Void
    let onDiscardAudio: () -> Void
    let suggestions: [String]
    let onSuggestion: (String) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if !audioRecorder.isRecording {
                    leadingControl
                        .glassEffectID("composer-leading", in: glassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                        .transition(.blurReplace.combined(with: .scale(0.9)))
                        .zIndex(2)
                }

                InsightComposerField(
                    text: $text,
                    isFocused: isFocused,
                    audioRecorder: audioRecorder,
                    isGenerating: isGenerating,
                    isEnabled: isEnabled,
                    hasPendingImages: hasPendingImages,
                    pendingAudio: pendingAudio,
                    isPlayingAudio: isPlayingAudio,
                    onMicrophonePressChanged: onMicrophonePressChanged,
                    onMicrophoneLongPress: onMicrophoneLongPress,
                    onMicrophoneAccessibilityAction: onMicrophoneAccessibilityAction,
                    onToggleAudioPlayback: onToggleAudioPlayback,
                    onSend: onSend,
                    onStop: onStop
                )
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("composer-field", in: glassNamespace)
                .glassEffectTransition(.matchedGeometry)
            }
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.04), value: composerMode)
        .padding(.horizontal, 27)
        .padding(.top, 6)
        .padding(.bottom, isKeyboardPresented ? 8 : -6)
    }

    @ViewBuilder
    private var leadingControl: some View {
        if pendingAudio != nil {
            Button {
                onDiscardAudio()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.medium))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .accessibilityLabel("取消语音")
            .accessibilityIdentifier("insight.audio.discard")
        } else {
            Menu {
                Button {
                    onPhotoLibrary()
                } label: {
                    Label("从相册选择", systemImage: "photo.on.rectangle")
                }
                Button("拍照", systemImage: "camera", action: onCamera)
                Button("导入数据文件", systemImage: "square.and.arrow.down", action: onImportData)
                Menu("建议问题", systemImage: "sparkles") {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            onSuggestion(suggestion)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .disabled(isGenerating)
            .accessibilityLabel("添加附件或选择建议问题")
            .accessibilityIdentifier("insight.attachment.menu")
        }
    }

    private var composerMode: InsightComposerMode {
        if audioRecorder.isRecording {
            return .recording
        }
        if pendingAudio != nil {
            return .audioPreview
        }
        return .text
    }
}

private enum InsightComposerMode: Hashable {
    case text
    case recording
    case audioPreview
}

private struct InsightComposerField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let audioRecorder: InsightAudioRecorder
    let isGenerating: Bool
    let isEnabled: Bool
    let hasPendingImages: Bool
    let pendingAudio: PendingInsightAudio?
    let isPlayingAudio: Bool
    let onMicrophonePressChanged: (Bool) -> Void
    let onMicrophoneLongPress: () -> Void
    let onMicrophoneAccessibilityAction: () -> Void
    let onToggleAudioPlayback: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        ZStack {
            if audioRecorder.isRecording {
                recordingContent
                    .transition(.blurReplace)
            } else if let pendingAudio {
                audioPreview(pendingAudio)
                    .transition(.blurReplace)
            } else {
                textComposer
                    .transition(.blurReplace)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .animation(.snappy(duration: 0.3, extraBounce: 0.04), value: composerMode)
        .overlay(alignment: .trailing) {
            if shouldCaptureMicrophonePress {
                Color.clear
                    .frame(width: 50, height: 44)
                    .contentShape(.rect)
                    .onLongPressGesture(
                        minimumDuration: 0.15,
                        maximumDistance: 80,
                        pressing: onMicrophonePressChanged,
                        perform: onMicrophoneLongPress
                    )
                    .accessibilityElement()
                    .accessibilityLabel(audioRecorder.isRecording ? "松开结束录音" : "按住录音")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        onMicrophoneAccessibilityAction()
                    }
            }
        }
    }

    private var textComposer: some View {
        HStack(spacing: 8) {
            TextField("信息", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .textFieldStyle(.plain)
                .frame(minWidth: 160, maxWidth: .infinity)
                .disabled(isGenerating)

            if isGenerating {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.red)
                .frame(width: 34, height: 34)
                .accessibilityLabel("停止生成")
            } else if hasSendableContent {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(AppTheme.brand)
                .frame(width: 34, height: 34)
                .disabled(!isEnabled)
                .accessibilityLabel("发送")
            } else {
                Image(systemName: "waveform")
                    .font(.body.weight(.medium))
                    .foregroundStyle(isEnabled ? .secondary : .tertiary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }
        }
    }

    private var recordingContent: some View {
        HStack(spacing: 12) {
            InsightAudioWaveform(
                samples: audioRecorder.waveformSamples,
                color: .red,
                inactiveOpacity: 0.28
            )
            .frame(maxWidth: .infinity)

            Text(formatDuration(audioRecorder.duration))
                .font(.body.monospacedDigit())
                .foregroundStyle(.red)

            ZStack {
                Circle()
                    .fill(.red.opacity(0.14))
                RoundedRectangle(cornerRadius: 3)
                    .fill(.red)
                    .frame(width: 14, height: 14)
            }
            .frame(width: 38, height: 38)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在录音，\(formatDuration(audioRecorder.duration))，松开结束")
    }

    private func audioPreview(_ audio: PendingInsightAudio) -> some View {
        HStack(spacing: 10) {
            Button(action: onToggleAudioPlayback) {
                Image(systemName: isPlayingAudio ? "pause.fill" : "play.fill")
                    .font(.caption.bold())
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .frame(width: 34, height: 34)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(isPlayingAudio ? "暂停语音" : "播放语音")

            InsightAudioWaveform(
                samples: audio.waveformSamples,
                color: .secondary,
                inactiveOpacity: 0.52
            )
            .frame(maxWidth: .infinity)

            Text("+ \(formatDuration(audio.duration))")
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.fill.tertiary, in: .capsule)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.green)
            .frame(width: 38, height: 38)
            .disabled(!isEnabled)
            .accessibilityLabel("发送语音")
        }
    }

    private var hasSendableContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasPendingImages
    }

    private var shouldCaptureMicrophonePress: Bool {
        audioRecorder.isRecording || (
            !isGenerating &&
                pendingAudio == nil &&
                !hasSendableContent
        )
    }

    private var composerMode: InsightComposerMode {
        if audioRecorder.isRecording {
            return .recording
        }
        if pendingAudio != nil {
            return .audioPreview
        }
        return .text
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
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

private struct InsightConversationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let controller: InsightConversationController

    var body: some View {
        NavigationStack {
            List {
                Section("当前牧场：\(controller.boundFarmName)") {
                    if controller.conversations.isEmpty {
                        ContentUnavailableView("暂无历史会话", systemImage: "bubble.left.and.bubble.right")
                    } else {
                        ForEach(controller.conversations, id: \.id) { conversation in
                            Button {
                                controller.selectConversation(conversation.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizedStringKey(conversation.title))
                                        .foregroundStyle(.primary)
                                    Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                controller.deleteConversation(controller.conversations[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
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

        init(onImage: @escaping (UIImage) -> Void) {
            self.onImage = onImage
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                picker.dismiss(animated: true)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
