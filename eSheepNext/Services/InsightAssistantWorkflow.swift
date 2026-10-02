import Foundation

enum InsightSubmissionMode: String, Codable, Sendable, CaseIterable {
    case conversation
    case plan
    case goal

    var title: String {
        switch self {
        case .conversation: "普通对话"
        case .plan: "方案模式"
        case .goal: "追求目标"
        }
    }
}

struct InsightRuntimeRecord: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case reasoning, tool, status }
    enum State: String, Codable, Sendable { case running, completed, failed, cancelled }
    var id = UUID()
    var title: String
    var detail: String
    var state: State
    var kind: Kind
    var callID: String?
    var createdAt = Date.now
}

enum InsightPlanStatus: String, Codable, Sendable {
    case ready, needsInformation, continued, dismissed
    var title: String {
        switch self {
        case .ready: "方案就绪"
        case .needsInformation: "需要补充信息"
        case .continued: "已转为目标"
        case .dismissed: "已结束方案"
        }
    }
}

struct InsightPlan: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var title: String
    var analysis: String
    var steps: [String]
    var completionCriteria: [String]
    var missingInformation: [String]
    var status: InsightPlanStatus
    var version = 1
    var parentPlanID: UUID?
    var createdAt = Date.now

    /// A model's structured proposal is a plan, never a business approval.
    /// Reject empty, excessive or ambiguous plans rather than inventing steps.
    static func decode(_ text: String) -> InsightPlan? {
        struct Proposal: Decodable {
            let title: String
            let analysis: String
            let steps: [String]
            let completionCriteria: [String]
            let missingInformation: [String]
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```json"), trimmed.hasSuffix("```") {
            json = String(trimmed.dropFirst(7).dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            json = trimmed
        }
        guard json.utf8.count <= 200_000,
              let data = json.data(using: .utf8),
              let proposal = try? JSONDecoder().decode(Proposal.self, from: data) else { return nil }
        let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let analysis = proposal.analysis.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = proposal.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let criteria = proposal.completionCriteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !title.isEmpty, title.count <= 200, !analysis.isEmpty,
              (1...12).contains(steps.count), steps.allSatisfy({ !$0.isEmpty && $0.count <= 2_000 }),
              (1...8).contains(criteria.count), criteria.allSatisfy({ !$0.isEmpty && $0.count <= 1_000 }),
              proposal.missingInformation.count <= 12,
              proposal.missingInformation.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1_000 }) else { return nil }
        return InsightPlan(
            title: title, analysis: analysis, steps: steps, completionCriteria: criteria,
            missingInformation: proposal.missingInformation,
            status: proposal.missingInformation.isEmpty ? .ready : .needsInformation
        )
    }

    static let outputInstruction = """
    当前是只读方案阶段。只允许查询、计算和分析，禁止生成操作草案或执行任何业务操作。
    最终输出一个完整 JSON 对象，不要加前后叙述：
    {"title":"方案名称","analysis":"完整的、有真实工具依据的分析，保留全部必要维度与数据缺口",\
    "steps":["可执行步骤，明确对象、日期和依赖"],"completionCriteria":["可核验的完成条件"],\
    "missingInformation":["尚缺的必要字段；没有则为空数组"]}
    步骤最多12项。计划中的写入只能写为未来需用户确认的步骤，不得声称已经发生。
    """
}

enum InsightGoalStatus: String, Codable, Sendable {
    case queued, running, needsInformation, awaitingConfirmation, awaitingCloud
    case paused, failed, completed, stopped

    var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "执行中"
        case .needsInformation: "需要补充信息"
        case .awaitingConfirmation: "等待操作确认"
        case .awaitingCloud: "等待云端确认"
        case .paused: "已暂停"
        case .failed: "执行遇到问题"
        case .completed: "已完成"
        case .stopped: "已停止"
        }
    }

    var isTerminal: Bool { self == .completed || self == .stopped }
}

struct InsightGoal: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var title: String
    var steps: [String]
    var completionCriteria: [String]
    var currentStep = 0
    var status: InsightGoalStatus = .queued
    var planID: UUID
    var planVersion: Int
    var rootMessageID: UUID
    var completedMessageIDs: [UUID] = []
    var pendingDraftIDs: [UUID] = []
    var activeStepMessageID: UUID?
    var lastError: String?
    var createdAt = Date.now

    var currentStepDescription: String? {
        steps.indices.contains(currentStep) ? steps[currentStep] : nil
    }

    /// Only a successfully checked step can advance this cursor. In particular
    /// generating an operation card, cancelling it, or a model turn completing
    /// does not satisfy a write step.
    mutating func recordVerifiedStep(messageID: UUID) {
        guard !status.isTerminal, currentStep < steps.count,
              activeStepMessageID == messageID,
              !completedMessageIDs.contains(messageID) else { return }
        completedMessageIDs.append(messageID)
        pendingDraftIDs.removeAll()
        activeStepMessageID = nil
        currentStep += 1
        status = .queued
        lastError = nil
    }
}

enum InsightWorkflowError: LocalizedError {
    case invalidPlan
    case stopped
    case missingCheckpoint
    case scopeChanged
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlan: "模型没有返回完整且可执行的方案，本次规划未启动目标。"
        case .stopped: "任务已经停止。"
        case .missingCheckpoint: "本机检查点不可用；原消息和操作回执仍保留，请重新核对目标。"
        case .scopeChanged: "账号、牧场或会话发生变化，任务已暂停。"
        case .persistenceFailed: "无法保存任务检查点，已暂停后续步骤。"
        }
    }
}

struct InsightGoalStepEvaluation: Decodable, Sendable {
    let analysis: String
    let stepCompleted: Bool
    let missingInformation: [String]

    static func decode(_ text: String) -> Self? {
        guard let data = text.data(using: .utf8), data.count <= 200_000,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.analysis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.missingInformation.count <= 12,
              value.missingInformation.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1_000 }),
              !(value.stepCompleted && !value.missingInformation.isEmpty) else { return nil }
        return value
    }
}

struct InsightGoalCompletionEvaluation: Decodable, Sendable {
    let analysis: String
    let completed: Bool
    let remaining: [String]

    static func decode(_ text: String) -> Self? {
        guard let data = text.data(using: .utf8), data.count <= 200_000,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.analysis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.remaining.count <= 12,
              value.remaining.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1_000 }),
              !(value.completed && !value.remaining.isEmpty) else { return nil }
        return value
    }
}
