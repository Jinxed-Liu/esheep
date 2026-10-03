import SwiftUI

/// The input and controls share one surface. Attachments remain part of the draft.
struct InsightComposerView<Attachments: View, Context: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var inputFontSize: CGFloat = 18
    @Namespace private var composerCoordinateSpace
    @State private var isAddMenuPresented = false
    @State private var addMenuSessionID: UUID?
    @State private var pendingAddMenuAction: InsightComposerMenuAction?
    @State private var addMenuFrame = CGRect.zero
    @State private var focusBeforeAddMenu = false
    @State private var isComposerVisible = false
    @State private var didActivateVoiceHold = false
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let audioRecorder: InsightAudioRecorder
    let pendingAudio: PendingInsightAudio?
    let isPlayingAudio: Bool
    let isGenerating: Bool
    let isSubmitting: Bool
    let isEnabled: Bool
    let isAudioEnabled: Bool
    var isListEntry: Bool = false
    var placeholder = "信息"
    var analysisEffort: InsightAnalysisEffort = .medium
    let hasAttachments: Bool
    let attachmentsReady: Bool
    let modeTitle: String?
    let isPlanSelected: Bool
    let isGoalSelected: Bool
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    let onPlan: () -> Void
    let onGoal: () -> Void
    let onRemoveMode: () -> Void
    let onSettings: () -> Void
    let onMicrophonePressChanged: (Bool) -> Void
    let onMicrophoneLongPress: () -> Void
    let onMicrophone: () -> Void
    let onToggleAudioPlayback: () -> Void
    let onDiscardAudio: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let attachments: () -> Attachments
    let context: () -> Context
    var onAnalysisGaugeFrameChange: (CGRect) -> Void = { _ in }
    var blocksAttachmentMenu = false
    var onContextUsageFrameChange: (CGRect) -> Void = { _ in }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasContent: Bool { hasText || hasAttachments || pendingAudio != nil }
    private var showsAudioBar: Bool { audioRecorder.isRecording || pendingAudio != nil }
    private var expanded: Bool {
        isFocused.wrappedValue || hasContent || audioRecorder.isRecording || modeTitle != nil
    }
    private var canSend: Bool {
        isEnabled && !isSubmitting && !audioRecorder.isRecording && attachmentsReady && (hasText || hasAttachments || pendingAudio != nil)
    }
    private var mainActionEnabled: Bool {
        if audioRecorder.isRecording { return isEnabled && !isSubmitting && attachmentsReady }
        return isGenerating || (hasContent ? canSend : (isAudioEnabled && !isListEntry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            if expanded && !showsAudioBar {
                if hasAttachments { attachments() }
            }
            // Keep the editable field in the same structural position as the
            // surface expands, so a focus change does not replace its identity.
            HStack(spacing: 0) {
                if !expanded && !showsAudioBar { addMenu }
                ZStack {
                    // Retain the original editor and its first responder while
                    // recording. Its text and attachments remain in the draft.
                    textInput.padding(.horizontal, expanded ? 12 : 0)
                        .frame(height: showsAudioBar ? 24 : nil)
                        .opacity(showsAudioBar ? 0 : 1)
                        .allowsHitTesting(!showsAudioBar)
                        .accessibilityHidden(showsAudioBar)
                    if showsAudioBar { audioBar }
                }
                if !expanded && !showsAudioBar {
                    microphoneButton
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }
            .frame(minHeight: showsAudioBar ? 48 : (expanded ? 24 : 48))
            if expanded && !showsAudioBar { toolRow }
        }
        .padding(.horizontal, 2)
        .padding(.top, expanded && !showsAudioBar ? 14 : 0)
        .padding(.bottom, expanded && !showsAudioBar ? 8 : 0)
        .frame(maxWidth: 680)
        .overlay(alignment: .bottomTrailing) {
            // A held recording gesture must survive the layout expanding.
            mainButton
                .padding(.trailing, 2)
                .padding(.bottom, expanded && !showsAudioBar ? 8 : 2)
        }
        .modifier(InsightComposerSurface(cornerRadius: expanded && !showsAudioBar ? 28 : 25, opaque: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insight.composer.surface")
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 8 : (expanded || showsAudioBar ? 12 : 38))
        .padding(.top, 6)
        .padding(.bottom, isFocused.wrappedValue ? 8 : 10)
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: composerCoordinateSpace)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: expanded)
        .background {
            let sessionID = addMenuSessionID
            InsightComposerMenuPresentation(
                isPresented: $isAddMenuPresented,
                sourceFrame: addMenuFrame,
                isBlocked: blocksAttachmentMenu || isSubmitting || showsAudioBar,
                allowsReopen: pendingAddMenuAction == nil,
                content: { attachmentPanel },
                onDismissed: { allowsAction in
                    completeAddMenuDismissal(sessionID: sessionID, allowsAction: allowsAction)
                }
            )
        }
        .onChange(of: blocksAttachmentMenu || isSubmitting || showsAudioBar) { _, blocked in
            if blocked {
                pendingAddMenuAction = nil
                addMenuSessionID = nil
                isAddMenuPresented = false
            }
        }
        .onChange(of: audioRecorder.isRecording) { _, recording in
            if !recording { didActivateVoiceHold = false }
        }
        .onAppear { isComposerVisible = true }
        .onDisappear {
            isComposerVisible = false
            pendingAddMenuAction = nil
            addMenuSessionID = nil
            isAddMenuPresented = false
        }
    }

    private var textInput: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(.system(size: inputFontSize))
            .lineSpacing(3)
            .lineLimit(1...6)
            .focused(isFocused)
            .textFieldStyle(.plain)
            .disabled(isSubmitting)
            // A multiline composer keeps Return for newlines. Sending uses
            // the separate arrow button, matching the mobile chat layout.
            .submitLabel(.return)
            .frame(minHeight: 24)
            .accessibilityIdentifier("insight.composer.text")
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            addMenu.padding(.trailing, 4)
            if !dynamicTypeSize.isAccessibilitySize {
                context().frame(width: 44, height: 44)
                    .onGeometryChange(for: CGRect.self) { [space = composerCoordinateSpace] geometry in
                        geometry.frame(in: .named(space))
                    } action: { frame in
                        onContextUsageFrameChange(frame)
                    }
            }
            modeButton
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button(action: onSettings) {
                    InsightAnalysisGauge(effort: analysisEffort)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("思考与分析设置")
                .accessibilityValue("\(analysisEffort.title)分析强度")
                .accessibilityHint("选择下一次请求的分析强度")
                .accessibilityIdentifier("insight.reasoning.settings")
                .onGeometryChange(for: CGRect.self) { [space = composerCoordinateSpace] geometry in
                    geometry.frame(in: .named(space))
                } action: { frame in
                    onAnalysisGaugeFrameChange(frame)
                }
                microphoneButton
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var modeButton: some View {
        if let modeTitle {
            Button(action: onRemoveMode) {
                HStack(spacing: 8) {
                    if isPlanSelected {
                        InsightComposerPlanGlyph()
                            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 20, height: 20)
                            .offset(x: -17.0 / 6)
                    } else {
                        Image(systemName: "scope")
                            .font(.system(size: 16.7, weight: .semibold)).frame(width: 20, height: 20)
                    }
                    Image(systemName: "xmark")
                        .resizable().scaledToFit().frame(width: 6.7, height: 6.7)
                }
                .foregroundStyle(Color.primary.opacity(0.595))
                .frame(width: 58, height: 30)
                .background(Color.primary.opacity(0.08), in: .capsule)
                .frame(width: 58, height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel("移除\(modeTitle)，下次发送使用普通对话")
            .accessibilityIdentifier("insight.composer.mode")
            .padding(.leading, 2)
        }
    }

    private var addMenu: some View {
        Button {
            guard addMenuSessionID == nil, !blocksAttachmentMenu else { return }
            focusBeforeAddMenu = isFocused.wrappedValue
            addMenuSessionID = UUID()
            isAddMenuPresented = true
        } label: {
            Image(systemName: "plus").resizable().scaledToFit()
                .frame(width: 17, height: 17)
                .offset(y: -1.0 / 3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || blocksAttachmentMenu || (addMenuSessionID != nil && !isAddMenuPresented))
        .accessibilityLabel("添加附件或选择方案与目标模式")
        .accessibilityIdentifier("insight.attachment.menu")
        .onGeometryChange(for: CGRect.self) { [space = composerCoordinateSpace] geometry in
            geometry.frame(in: .named(space))
        } action: { frame in
            addMenuFrame = frame
        }
    }

    private var attachmentPanel: some View {
        VStack(spacing: 0) {
            attachmentAction(.camera, title: "相机", symbol: "camera")
            attachmentAction(.photos, title: "照片", symbol: "photo.on.rectangle")
            attachmentAction(.files, title: "文件", symbol: "paperclip")
            Divider().padding(.vertical, 8)
            attachmentAction(.plan, title: "方案模式", symbol: "checklist.unchecked", selected: isPlanSelected)
            attachmentAction(.goal, title: "追求目标", symbol: "scope", selected: isGoalSelected)
        }
        .padding(16)
        .frame(width: 280)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insight.attachment.panel")
        .accessibilityAction(.escape) { isAddMenuPresented = false }
    }

    private func attachmentAction(_ action: InsightComposerMenuAction, title: String,
                                  symbol: String, selected: Bool = false) -> some View {
        Button {
            guard pendingAddMenuAction == nil else { return }
            pendingAddMenuAction = action
            isAddMenuPresented = false
        } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol).resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(selected ? Color.blue : Color.primary)
                    .frame(width: 44, height: 44)
                    .background(selected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.05), in: .circle)
                Text(title).font(.title3).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("insight.attachment.\(action.rawValue)")
    }

    private func completeAddMenuDismissal(sessionID: UUID?, allowsAction: Bool) {
        guard let sessionID, sessionID == addMenuSessionID else { return }
        let action = pendingAddMenuAction
        pendingAddMenuAction = nil
        addMenuSessionID = nil
        isAddMenuPresented = false
        guard allowsAction, isComposerVisible, !blocksAttachmentMenu, !isSubmitting else { return }
        if focusBeforeAddMenu { isFocused.wrappedValue = true }
        switch action {
        case .camera: onCamera()
        case .photos: onPhotos()
        case .files: onFiles()
        case .plan: onPlan()
        case .goal: onGoal()
        case nil: break
        }
    }

    private var microphoneButton: some View {
        Button(action: onMicrophone) {
            InsightComposerMicrophoneGlyph(isRecording: audioRecorder.isRecording)
                .frame(width: 20.7, height: 20.7)
                .foregroundStyle(audioRecorder.isRecording ? Color.red : Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isAudioEnabled || isGenerating || isSubmitting || pendingAudio != nil)
        .accessibilityLabel(audioRecorder.isRecording ? "结束录音" : "开始录音")
        .accessibilityIdentifier("insight.audio.record")
    }

    @ViewBuilder
    private var mainButton: some View {
        if (!hasContent || (audioRecorder.isRecording && didActivateVoiceHold)) && !isGenerating && !isListEntry {
            mainActionButton(isVoiceAction: true)
                .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 80, pressing: { pressed in
                    if pressed { didActivateVoiceHold = false }
                    if (!hasContent || didActivateVoiceHold) && !isGenerating && (!audioRecorder.isRecording || didActivateVoiceHold) {
                        onMicrophonePressChanged(pressed)
                    }
                }, perform: {
                    if !hasContent && !isGenerating {
                        didActivateVoiceHold = true
                        onMicrophoneLongPress()
                    }
                })
        } else {
            // A send press must never compete with the voice recognizer.
            mainActionButton(isVoiceAction: false)
        }
    }

    private func mainActionButton(isVoiceAction: Bool) -> some View {
        Button {
            if isGenerating { onStop() }
            else if audioRecorder.isRecording {
                // Releasing the initial hold ends recording through the
                // original press callback; only a separate tap sends it.
                if !isVoiceAction || !didActivateVoiceHold { onSend() }
            }
            else if hasContent { if !isVoiceAction && canSend { onSend() } }
            else if !isListEntry { onMicrophone() }
        } label: {
            ZStack {
                Circle().fill(Color(uiColor: mainActionEnabled ? .label : .systemGray5))
                Image(systemName: isGenerating ? "stop.fill" : (showsAudioBar || hasContent || isListEntry ? "arrow.up" : "waveform"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(uiColor: mainActionEnabled ? .systemBackground : .secondaryLabel))
            }
                .frame(width: 34, height: 34)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!mainActionEnabled)
        .accessibilityLabel(isGenerating ? "停止生成" : (audioRecorder.isRecording ? "结束录音并发送" : (hasContent || isListEntry ? "发送" : "语音输入")))
        .accessibilityIdentifier(isGenerating ? "insight.composer.stop" : "insight.composer.send")
    }

    private var audioBar: some View {
        HStack(spacing: 4) {
            Button(action: onDiscardAudio) {
                audioControlIcon("xmark", size: 14)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel(audioRecorder.isRecording ? "取消本次录音" : "移除语音并恢复输入")
            .accessibilityIdentifier("insight.audio.cancel")

            InsightComposerWaveform(
                samples: audioRecorder.isRecording ? audioRecorder.waveformSamples : (pendingAudio?.waveformSamples ?? []),
                color: .primary.opacity(0.52),
                isLive: audioRecorder.isRecording,
                lastSampleAt: audioRecorder.waveformUpdatedAt,
                sampleInterval: InsightAudioRecorder.waveformSampleInterval
            )
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("insight.audio.waveform")

            Button(action: audioRecorder.isRecording ? onMicrophone : onToggleAudioPlayback) {
                audioControlIcon(audioRecorder.isRecording ? "stop.fill" : (isPlayingAudio ? "pause.fill" : "play.fill"), size: 11)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel(audioRecorder.isRecording ? "结束录音，保留待发送语音" : (isPlayingAudio ? "暂停回听" : "播放语音"))
            .accessibilityIdentifier(audioRecorder.isRecording ? "insight.audio.stop" : "insight.audio.playback")

            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .frame(height: 48)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(audioRecorder.isRecording ? "正在录音" : "待发送语音")
        .accessibilityValue(duration(audioRecorder.isRecording ? audioRecorder.duration : (pendingAudio?.duration ?? 0)))
        .accessibilityIdentifier("insight.audio.bar")
    }

    private func audioControlIcon(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(0.06), in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private enum InsightComposerMenuAction: String {
    case camera, photos, files, plan, goal
}

private struct InsightComposerPlanGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Centre the reference's 55 x 49px ink at 3x in the 20pt canvas.
        let origin = CGPoint(x: rect.midX - 55.0 / 6, y: rect.midY - 49.0 / 6)
        var path = Path()
        for y in [11.0 / 3, 38.0 / 3] {
            // A 2pt centred stroke gives a 22px outer ring and 10px hole.
            path.addEllipse(in: CGRect(x: origin.x + 1, y: origin.y + y - 8.0 / 3,
                                       width: 16.0 / 3, height: 16.0 / 3))
        }
        for (y, endX) in [(11.0 / 3, 52.0 / 3), (38.0 / 3, 51.0 / 3)] {
            path.move(to: CGPoint(x: origin.x + 31.0 / 3, y: origin.y + y))
            path.addLine(to: CGPoint(x: origin.x + endX, y: origin.y + y))
        }
        return path
    }
}

private struct InsightComposerMicrophoneGlyph: View {
    let isRecording: Bool

    var body: some View {
        GeometryReader { geometry in
            // Keep the measured 48 x 62px ink centred in the existing canvas.
            let origin = CGPoint(x: geometry.size.width / 2 - 8,
                                 y: geometry.size.height / 2 - 31.0 / 3)
            ZStack(alignment: .topLeading) {
                InsightComposerMicrophoneSupport()
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Path { path in
                    path.move(to: CGPoint(x: origin.x + 24.5 / 3, y: origin.y + 50.0 / 3))
                    path.addLine(to: CGPoint(x: origin.x + 24.5 / 3, y: origin.y + 59.5 / 3))
                }
                .stroke(style: StrokeStyle(lineWidth: 5.0 / 3, lineCap: .round))
                Group {
                    if isRecording {
                        Capsule().fill()
                    } else {
                        Capsule().strokeBorder(lineWidth: 2)
                    }
                }
                .frame(width: 29.0 / 3, height: 41.0 / 3)
                .position(x: origin.x + 24.5 / 3, y: origin.y + 20.5 / 3)
            }
        }
    }
}

private struct InsightComposerMicrophoneSupport: Shape {
    func path(in rect: CGRect) -> Path {
        let origin = CGPoint(x: rect.midX - 8, y: rect.midY - 31.0 / 3)
        var path = Path()
        path.addArc(center: CGPoint(x: origin.x + 24.5 / 3, y: origin.y + 27.7 / 3),
                    radius: 22.0 / 3, startAngle: .degrees(162), endAngle: .degrees(18),
                    clockwise: true)
        return path
    }
}

private struct InsightComposerSurface: ViewModifier {
    let cornerRadius: CGFloat
    let opaque: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if opaque {
            content.background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: cornerRadius))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

private struct InsightComposerWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let samples: [Float]
    let color: Color
    var isLive = false
    var lastSampleAt: Date?
    var sampleInterval: TimeInterval = 0.1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isLive || reduceMotion)) { timeline in
            Canvas { context, size in
                let step: CGFloat = 5.5
                let elapsed = lastSampleAt.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
                let phase = isLive && !reduceMotion ? min(1, elapsed / max(0.01, sampleInterval)) : 0
                let offset = CGFloat(phase) * step
                let visibleCount = Int(ceil(size.width / step)) + 1
                for age in 0..<visibleCount {
                    let sampleIndex = samples.count - 1 - age
                    guard sampleIndex >= 0 else { break }
                    let sample = max(0, min(1, samples[sampleIndex]))
                    let height = max(2.5, CGFloat(sample) * 27)
                    let x = size.width - step / 2 - CGFloat(age) * step - offset
                    let rect = CGRect(x: x - 1.4, y: (size.height - height) / 2, width: 2.8, height: height)
                    // Silence stays a dot. Each real sample retains its own
                    // fixed time slot as newer samples enter from the right.
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.4),
                        with: .color(color.opacity(height <= 2.5 ? 0.42 : 1))
                    )
                }
            }
        }
        .frame(height: 28)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLive ? "实时语音波形" : "录音波形")
    }
}

struct InsightAnalysisFocusedSelector: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Binding var effortIndex: Double
    @Binding var thinkingEnabled: Bool
    @Binding var showReasoning: Bool
    let modelName: String
    let onDismiss: () -> Void
    var isExpanded = true
    @State private var showsAdvanced = false
    @State private var selectionFeedback = 0

    private var selectedEffort: InsightAnalysisEffort {
        .from(sliderValue: effortIndex)
    }

    var body: some View {
        VStack(spacing: 20) {
            Button { showsAdvanced = true } label: {
                HStack(spacing: 5) {
                    Text(modelName).fontWeight(.semibold)
                    Text(selectedEffort.title)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.title3)
                .lineLimit(2)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .opacity(isExpanded ? 1 : 0)
            .accessibilityHidden(!isExpanded)
            .accessibilityLabel("\(modelName)，\(selectedEffort.title)分析强度，高级设置")
            .accessibilityIdentifier("insight.analysis.advanced")

            InsightDiscreteEffortSlider(effort: selectedEffort, onSelect: selectEffort)
                .padding(12)
                .modifier(InsightAnalysisSelectorSurface(opaque: reduceTransparency))
        }
        // Give the presentation its own accessibility container. A plain
        // stack's identifier can otherwise be inherited by its descendants,
        // obscuring the adjustable track's identity and current value.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insight.analysis.selector")
        .accessibilityAction(.escape, onDismiss)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sheet(isPresented: $showsAdvanced) {
            NavigationStack {
                Form {
                    Section("分析强度") {
                        Picker("下一次请求", selection: Binding(
                            get: { effortIndex },
                            set: { selectEffort(.from(sliderValue: $0)) }
                        )) {
                            ForEach(InsightAnalysisEffort.allCases) { effort in
                                Text(effort.title).tag(effort.sliderValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("调整分析步骤和复核投入，下一次发送生效。必要校验始终保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Toggle("开启模型思考", isOn: $thinkingEnabled)
                        Toggle("显示思考步骤", isOn: $showReasoning)
                    } footer: {
                        Text("显示思考状态与实际查询、计算和复核步骤；过程记录只保存在本机。")
                    }
                }
                .navigationTitle("分析设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsAdvanced = false }
                    }
                }
            }
        }
    }

    private func selectEffort(_ effort: InsightAnalysisEffort) {
        guard effort != selectedEffort else { return }
        effortIndex = effort.sliderValue
        // Only an explicit selection changes this trigger. Restoring the
        // preference or receiving a programmatic binding update stays silent.
        selectionFeedback += 1
    }
}

/// The slider and dial share the actual analysis-policy catalogue. The lower
/// endpoint means the low policy; model thinking has its own separate switch.
private enum InsightAnalysisEffortScale {
    static let levels = InsightAnalysisEffort.allCases
    private static var lastIndex: Int { levels.count - 1 }

    static func clamped(_ progress: Double) -> Double {
        min(1, max(0, progress))
    }

    static func progress(for effort: InsightAnalysisEffort) -> Double {
        Double(levels.firstIndex(of: effort) ?? 0) / Double(max(1, lastIndex))
    }

    static func effort(at progress: Double) -> InsightAnalysisEffort {
        levels[Int((clamped(progress) * Double(lastIndex)).rounded())]
    }

    static func adjacent(to effort: InsightAnalysisEffort, offset: Int) -> InsightAnalysisEffort {
        let index = levels.firstIndex(of: effort) ?? 0
        return levels[min(lastIndex, max(0, index + offset))]
    }
}

private struct InsightAnalysisGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let effort: InsightAnalysisEffort

    var body: some View {
        let progress = InsightAnalysisEffortScale.progress(for: effort)
        ZStack {
            InsightAnalysisGaugeArc()
                .stroke(.primary.opacity(0.25), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            InsightAnalysisGaugeArc()
                .trim(from: 0, to: progress)
                .stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            // At the first stop the blue arc has zero length. Keep its round
            // endpoint visible without changing the policy's actual progress.
            Circle().fill(.blue).frame(width: 2, height: 2)
                .offset(x: -11 / sqrt(2.0), y: 11 / sqrt(2.0))
            InsightAnalysisGaugeNeedle()
                .stroke(.primary, style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                .rotationEffect(.degrees(-135 + 270 * progress))
            Circle().strokeBorder(.primary, lineWidth: 2)
                .frame(width: 20.0 / 3, height: 20.0 / 3)
        }
        // The measured reference has a 24 x 20.67pt blue outline. A circular
        // radius-11, 2pt-stroke, 270-degree arc spans 24 x 20.78pt. Its axis
        // is optically centred against the full microphone and action circle.
        .frame(width: 26, height: 26)
        .offset(y: 1.5)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: progress)
        .accessibilityHidden(true)
    }
}

private struct InsightAnalysisGaugeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) * 11 / 26,
                    startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
        return path
    }
}

private struct InsightAnalysisGaugeNeedle: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let scale = min(rect.width, rect.height) / 26
        var path = Path()
        // Begin at the ring edge, leaving its measured central hole clear.
        path.move(to: CGPoint(x: center.x, y: center.y - (10.0 / 3) * scale))
        path.addLine(to: CGPoint(x: center.x, y: center.y - 7.3 * scale))
        return path
    }
}

private struct InsightDiscreteEffortSlider: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let effort: InsightAnalysisEffort
    let onSelect: (InsightAnalysisEffort) -> Void
    @State private var dragProgress: Double?
    @State private var dragStartProgress: Double?
    @GestureState private var isDragging = false

    private var displayedProgress: Double {
        dragProgress ?? InsightAnalysisEffortScale.progress(for: effort)
    }

    var body: some View {
        GeometryReader { geometry in
            let usableWidth = max(1, geometry.size.width - 48)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.025)).accessibilityHidden(true)
                Capsule().fill(.blue)
                    .frame(width: 48 + usableWidth * CGFloat(displayedProgress))
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    ForEach(Array(InsightAnalysisEffortScale.levels.enumerated()), id: \.element.id) { index, level in
                        if index > 0 { Spacer(minLength: 0) }
                        Button { onSelect(level) } label: {
                            Circle().fill(InsightAnalysisEffortScale.progress(for: level) <= displayedProgress
                                          ? Color.white.opacity(0.32) : Color.primary.opacity(0.20))
                                .frame(width: 10, height: 10)
                                .frame(width: 44, height: 48)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(level.title)分析强度")
                        .accessibilityIdentifier("insight.analysis.level.\(level.rawValue)")
                        .accessibilityAddTraits(effort == level ? .isSelected : [])
                    }
                }
                // The 40pt thumb sits 4pt inside the 48pt blue cap. Keep
                // actual buttons in the layout so their hit frames stay valid.
                .padding(.horizontal, 2)
                Circle().fill(.white)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .offset(x: 4 + usableWidth * CGFloat(displayedProgress))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(.capsule)
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged { gesture in
                    if dragStartProgress == nil {
                        let selectedProgress = InsightAnalysisEffortScale.progress(for: effort)
                        let thumbCenter = 24 + usableWidth * CGFloat(selectedProgress)
                        // A thumb grab retains its offset; the first drag event
                        // must not jump the thumb centre underneath the finger.
                        dragStartProgress = abs(gesture.startLocation.x - thumbCenter) <= 24
                            ? selectedProgress : Double((gesture.startLocation.x - 24) / usableWidth)
                    }
                    let progress = InsightAnalysisEffortScale.clamped(
                        (dragStartProgress ?? 0) + Double(gesture.translation.width / usableWidth)
                    )
                    dragProgress = progress
                    onSelect(InsightAnalysisEffortScale.effort(at: progress))
                }
                .onEnded { gesture in
                    if let dragStartProgress {
                        let progress = dragStartProgress + Double(gesture.translation.width / usableWidth)
                        onSelect(InsightAnalysisEffortScale.effort(at: progress))
                    }
                    finishDrag()
                }
            )
            .animation(reduceMotion || dragProgress != nil ? nil : .snappy(duration: 0.18), value: displayedProgress)
        }
        .frame(height: 48)
        .onChange(of: isDragging) { _, dragging in
            if !dragging { finishDrag() }
        }
        .focusable()
        .onKeyPress(.leftArrow) { onSelect(InsightAnalysisEffortScale.adjacent(to: effort, offset: -1)); return .handled }
        .onKeyPress(.rightArrow) { onSelect(InsightAnalysisEffortScale.adjacent(to: effort, offset: 1)); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("分析强度")
        .accessibilityValue(effort.title)
        .accessibilityHint("上下滑动调整下一次请求的分析投入")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect(InsightAnalysisEffortScale.adjacent(to: effort, offset: 1))
            case .decrement: onSelect(InsightAnalysisEffortScale.adjacent(to: effort, offset: -1))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("insight.analysis.slider")
    }

    private func finishDrag() {
        dragStartProgress = nil
        dragProgress = nil
    }
}

private struct InsightAnalysisSelectorSurface: ViewModifier {
    let opaque: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if opaque {
            content.background(Color(uiColor: .secondarySystemBackground), in: .capsule)
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: .capsule)
        }
    }
}
