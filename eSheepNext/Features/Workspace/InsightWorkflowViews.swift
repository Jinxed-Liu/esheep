import SwiftUI

struct InsightRuntimeDisclosure: View {
    let records: [InsightRuntimeRecord]
    let showReasoning: Bool
    @State private var expanded = false

    private var visibleRecords: [InsightRuntimeRecord] {
        records.filter { showReasoning || $0.kind != .reasoning }
    }

    var body: some View {
        if !visibleRecords.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleRecords) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: symbol(record))
                                Text(record.title).font(.caption.weight(.semibold))
                                Spacer(minLength: 0)
                                Text(stateTitle(record.state)).font(.caption2)
                            }
                            .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                            if !record.detail.isEmpty {
                                Text(record.detail)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Label(title, systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
            .background(.fill.tertiary, in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("insight.runtime.disclosure")
        }
    }

    private var title: String {
        if visibleRecords.contains(where: { $0.state == .running && $0.kind == .reasoning }) {
            return "思考中 · 查看实际过程"
        }
        return visibleRecords.contains(where: { $0.kind == .reasoning }) ? "模型思考与工具过程" : "工具过程"
    }

    private func symbol(_ record: InsightRuntimeRecord) -> String {
        if record.state == .failed { return "exclamationmark.circle" }
        if record.state == .cancelled { return "stop.circle" }
        switch record.kind {
        case .reasoning: return "sparkles"
        case .tool: return record.state == .completed ? "checkmark.circle" : "wrench.and.screwdriver"
        case .status: return "info.circle"
        }
    }

    private func stateTitle(_ state: InsightRuntimeRecord.State) -> String {
        switch state {
        case .running: "进行中"
        case .completed: "已完成"
        case .failed: "未完成"
        case .cancelled: "已中断"
        }
    }
}

struct InsightPlanCard: View {
    let plan: InsightPlan
    let onEdit: () -> Void
    let onContinue: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("方案 · 第 \(plan.version) 版", systemImage: "list.bullet.clipboard")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(plan.status.title).font(.caption).foregroundStyle(.secondary)
            }
            Text(plan.title).font(.headline)
            Text(plan.analysis).font(.subheadline).textSelection(.enabled)
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).").monospacedDigit()
                    Text(step)
                }
                .font(.subheadline)
            }
            DisclosureGroup {
                ForEach(Array(plan.completionCriteria.enumerated()), id: \.offset) { _, criterion in
                    Text("• \(criterion)").frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                Text("完成标准").frame(minHeight: 44)
            }
            .font(.caption)
            if !plan.missingInformation.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("需要补充").font(.caption.weight(.semibold))
                    ForEach(Array(plan.missingInformation.enumerated()), id: \.offset) { _, missing in
                        Text("• \(missing)").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Text("方案只做查询与分析。按方案继续会启动目标，业务操作仍逐张确认。")
                .font(.caption).foregroundStyle(.secondary)
            if plan.status == .ready || plan.status == .needsInformation {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        editButton
                        Spacer(minLength: 4)
                        dismissButton
                        continueButton
                    }
                    VStack(alignment: .leading) {
                        continueButton
                        HStack { editButton; dismissButton }
                    }
                }
            }
        }
        .padding(16)
        .background(.fill.tertiary, in: .rect(cornerRadius: 18))
        .accessibilityIdentifier("insight.plan.card")
    }

    private var editButton: some View {
        Button("修改方案", action: onEdit).frame(minHeight: 44)
    }
    private var dismissButton: some View {
        Button("结束", action: onDismiss).frame(minHeight: 44)
    }
    private var continueButton: some View {
        Button("按方案继续", action: onContinue)
            .buttonStyle(.borderedProminent)
            .disabled(plan.status != .ready)
            .frame(minHeight: 44)
    }
}

struct InsightGoalCard: View {
    let goal: InsightGoal
    var awaitingFileName: String? = nil
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("追求目标", systemImage: "scope").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(goal.status.title).font(.caption).foregroundStyle(.secondary)
            }
            Text(goal.title).font(.headline)
            Text("已完成 \(min(goal.currentStep, goal.steps.count)) / \(goal.steps.count) 个步骤")
                .font(.caption).foregroundStyle(.secondary)
            if let step = goal.currentStepDescription {
                Text(step).font(.subheadline)
            }
            if let error = goal.lastError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let awaitingFileName {
                Text("请完成“\(awaitingFileName)”的保存。选择或关闭保存面板都不表示已保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if goal.status == .awaitingConfirmation {
                Text("请查看下方原有操作卡并确认或拒绝；目标不会替你批准。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if goal.status == .awaitingCloud {
                Text("本机步骤已提交，正在等待云端回执。不要重复执行原操作。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if goal.status == .needsInformation {
                Text("请在输入框补充必要条件后继续。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(goal.steps.enumerated()), id: \.offset) { index, step in
                        Label(step, systemImage: index < goal.currentStep ? "checkmark.circle" : "circle")
                            .font(.caption)
                    }
                    Divider()
                    ForEach(Array(goal.completionCriteria.enumerated()), id: \.offset) { _, criterion in
                        Text("• \(criterion)").font(.caption)
                    }
                }
            } label: {
                Text("步骤与完成标准").frame(minHeight: 44)
            }
            .font(.caption)
            if !goal.status.isTerminal {
                HStack {
                    if awaitingFileName != nil {
                        Button("保存文件", action: onResume).frame(minHeight: 44)
                    } else if goal.status == .running || goal.status == .queued {
                        Button("暂停", action: onPause).frame(minHeight: 44)
                    } else if goal.status == .paused || goal.status == .failed {
                        Button("继续", action: onResume).frame(minHeight: 44)
                    }
                    Spacer(minLength: 0)
                    Button("结束目标", role: .destructive, action: onStop).frame(minHeight: 44)
                }
            }
            Text("只在 App 前台继续；返回列表可以继续分析。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.fill.tertiary, in: .rect(cornerRadius: 18))
        .accessibilityIdentifier("insight.goal.card")
    }
}

struct InsightStoredDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    let document: InsightStoredDocumentPreview

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(document.fileName).font(.headline)
                    Text("以下是这条消息实际发送的内容与来源引用；未选内容没有发送。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(document.sections) { section in
                    Section(section.title) {
                        ForEach(section.blocks) { block in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(block.citation).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(block.text).font(.body).textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if !document.issues.isEmpty {
                    Section("解析缺口") {
                        ForEach(document.issues) { issue in
                            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("已发送的文件内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
