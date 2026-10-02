import SwiftUI

/// The input and controls share one surface. Attachments remain part of the draft.
struct InsightComposerView<Attachments: View, Context: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var inputFontSize: CGFloat = 18
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

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasContent: Bool { hasText || hasAttachments || pendingAudio != nil }
    private var expanded: Bool {
        isFocused.wrappedValue || hasContent || audioRecorder.isRecording || isGenerating || modeTitle != nil
    }
    private var canSend: Bool {
        isEnabled && !isSubmitting && !audioRecorder.isRecording && attachmentsReady && (hasText || hasAttachments || pendingAudio != nil)
    }
    private var mainActionEnabled: Bool {
        isGenerating || audioRecorder.isRecording || (hasContent ? canSend : (isAudioEnabled && !isListEntry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            if expanded {
                if let modeTitle {
                    HStack(spacing: 5) {
                        Image(systemName: isPlanSelected ? "list.bullet.clipboard" : "scope")
                        Text(modeTitle).font(.caption.weight(.medium))
                        Button(action: onRemoveMode) {
                            Image(systemName: "xmark").font(.caption.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                        .accessibilityLabel("移除\(modeTitle)，下次发送使用普通对话")
                    }
                    .padding(.leading, 10)
                    .background(.fill.tertiary, in: .capsule)
                    .fixedSize(horizontal: true, vertical: false)
                }
                if hasAttachments { attachments() }
                if let pendingAudio, !audioRecorder.isRecording {
                    audioPreview(pendingAudio)
                }
            }
            // Keep the editable field in the same structural position as the
            // surface expands, so a focus change does not replace its identity.
            HStack(spacing: 0) {
                if !expanded { addMenu }
                if audioRecorder.isRecording {
                    recordingPreview
                } else {
                    textInput.padding(.horizontal, expanded ? 6 : 0)
                }
                if !expanded {
                    microphoneButton
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }
            .frame(minHeight: expanded ? 24 : 48)
            if expanded { toolRow }
        }
        .padding(.horizontal, expanded ? 8 : 4)
        .padding(.top, expanded ? 14 : 0)
        .padding(.bottom, expanded ? 8 : 0)
        .frame(maxWidth: 680)
        .overlay(alignment: .bottomTrailing) {
            // A held recording gesture must survive the layout expanding.
            mainButton
                .padding(.trailing, expanded ? 8 : 4)
                .padding(.bottom, expanded ? 8 : 2)
        }
        .modifier(InsightComposerSurface(cornerRadius: expanded ? 28 : 25, opaque: reduceTransparency))
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 8 : (expanded ? 12 : 36))
        .padding(.top, 6)
        .padding(.bottom, isFocused.wrappedValue ? 8 : 10)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: expanded)
    }

    private var textInput: some View {
        TextField("信息", text: $text, axis: .vertical)
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
            addMenu
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 21))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("思考与分析设置")
            .accessibilityIdentifier("insight.reasoning.settings")
            Spacer(minLength: 0)
            if !dynamicTypeSize.isAccessibilitySize {
                context().frame(width: 44, height: 44)
            }
            microphoneButton
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .frame(height: 44)
    }

    private var addMenu: some View {
        Menu {
            Button("相机", systemImage: "camera", action: onCamera)
            Button("照片", systemImage: "photo.on.rectangle", action: onPhotos)
            Button("文件", systemImage: "doc", action: onFiles)
            Button(action: onPlan) {
                Label("方案模式", systemImage: isPlanSelected ? "checkmark" : "list.bullet.clipboard")
            }
            Button(action: onGoal) {
                Label("追求目标", systemImage: isGoalSelected ? "checkmark" : "scope")
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 24, weight: .regular))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .accessibilityLabel("添加附件或选择方案与目标模式")
        .accessibilityIdentifier("insight.attachment.menu")
    }

    private var microphoneButton: some View {
        Button(action: onMicrophone) {
            Image(systemName: audioRecorder.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 21))
                .foregroundStyle(audioRecorder.isRecording ? Color.red : Color.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!isAudioEnabled || isGenerating || isSubmitting || pendingAudio != nil)
        .accessibilityLabel(audioRecorder.isRecording ? "结束录音" : "开始录音")
        .accessibilityIdentifier("insight.audio.record")
    }

    private var mainButton: some View {
        Button {
            if isGenerating { onStop() }
            else if audioRecorder.isRecording { onMicrophone() }
            else if hasContent { if canSend { onSend() } }
            else if !isListEntry { onMicrophone() }
        } label: {
            ZStack {
                Circle().fill(Color(uiColor: mainActionEnabled ? .label : .systemGray5))
                Image(systemName: isGenerating || audioRecorder.isRecording ? "stop.fill" : (hasContent || isListEntry ? "arrow.up" : "waveform"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(uiColor: mainActionEnabled ? .systemBackground : .secondaryLabel))
            }
                .frame(width: 34, height: 34)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!mainActionEnabled)
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 80, pressing: { pressed in
            if !hasContent && !isGenerating && !isListEntry { onMicrophonePressChanged(pressed) }
        }, perform: {
            if !hasContent && !isGenerating && !isListEntry { onMicrophoneLongPress() }
        })
        .accessibilityLabel(isGenerating ? "停止生成" : (audioRecorder.isRecording ? "结束录音" : (hasContent || isListEntry ? "发送" : "语音输入")))
        .accessibilityIdentifier(isGenerating ? "insight.composer.stop" : "insight.composer.send")
    }

    private var recordingPreview: some View {
        HStack(spacing: 10) {
            InsightComposerWaveform(samples: audioRecorder.waveformSamples, color: .red)
            Spacer(minLength: 0)
            Text(duration(audioRecorder.duration)).monospacedDigit().foregroundStyle(.red)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在录音，\(duration(audioRecorder.duration))")
    }

    private func audioPreview(_ audio: PendingInsightAudio) -> some View {
        HStack(spacing: 4) {
            Button(action: onToggleAudioPlayback) {
                Image(systemName: isPlayingAudio ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlayingAudio ? "暂停回听" : "播放语音")
            InsightComposerWaveform(samples: audio.waveformSamples, color: .secondary)
            Spacer(minLength: 0)
            Text(duration(audio.duration)).font(.caption.monospacedDigit())
            Button(action: onDiscardAudio) {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel("移除语音")
        }
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
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
    let samples: [Float]
    let color: Color
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { index in
                let sample = samples.isEmpty ? Float(0.08) : samples[min(samples.count - 1, index * samples.count / 24)]
                Capsule().fill(color.opacity(sample <= 0.08 ? 0.35 : 1))
                    .frame(width: 2, height: max(3, CGFloat(sample) * 24))
            }
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }
}

struct InsightAnalysisSettingsPopover: View {
    @Binding var effortIndex: Double
    @Binding var thinkingEnabled: Bool
    @Binding var showReasoning: Bool
    let modelName: String

    var body: some View {
        VStack(spacing: 14) {
            Text(modelName).font(.headline).lineLimit(2)
            VStack(spacing: 0) {
                InsightDiscreteEffortSlider(value: $effortIndex)
                HStack {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        Button { effortIndex = Double(index) } label: {
                            VStack(spacing: 4) {
                                Circle().fill(.blue).frame(width: 5, height: 5)
                                Text(label).font(.caption.weight(Int(effortIndex.rounded()) == index ? .semibold : .regular))
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(label)分析强度")
                        .accessibilityAddTraits(Int(effortIndex.rounded()) == index ? .isSelected : [])
                    }
                }
            }
            Text("下一次发送生效。调整分析步骤与预算，必要校验始终保留。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("高级设置") {
                Toggle("开启模型思考", isOn: $thinkingEnabled)
                Toggle("显示模型返回的思考", isOn: $showReasoning)
                Text("过程记录仅保存在本机，不加入聊天正文或同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        .padding(18)
        .frame(width: 300)
    }

    private var labels: [String] { ["低", "中", "高"] }
}

private struct InsightDiscreteEffortSlider: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var value: Double

    var body: some View {
        GeometryReader { geometry in
            let usableWidth = max(1, geometry.size.width - 44)
            ZStack(alignment: .leading) {
                Capsule().fill(.blue)
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(.white.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .position(x: 22 + usableWidth * CGFloat(index) / 2, y: 22)
                }
                Circle().fill(.white)
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .offset(x: 5 + usableWidth * CGFloat(min(2, max(0, value.rounded()))) / 2)
            }
            .contentShape(.capsule)
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let proposed = Double((gesture.location.x - 22) / usableWidth * 2)
                value = min(2, max(0, proposed.rounded()))
            })
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: value)
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("分析强度")
        .accessibilityValue(["低", "中", "高"][Int(min(2, max(0, value.rounded())))])
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(2, value + 1)
            case .decrement: value = max(0, value - 1)
            @unknown default: break
            }
        }
    }
}
