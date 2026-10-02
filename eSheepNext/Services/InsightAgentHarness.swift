import Foundation

/// Native iOS agent loop inspired by the open Codex harness. The model provider,
/// product UI, tools and approval policy remain application-owned; this type owns
/// the repeatable turn -> tool -> observation -> continuation lifecycle.
@MainActor
struct InsightAgentHarness {
    struct ToolObservation: Sendable, Equatable {
        let output: String
        let succeeded: Bool
    }

    struct Result: Sendable, Equatable {
        let text: String
        let exchanges: [MiMoFunctionExchange]
        let successfulToolNames: Set<String>
        let reasoningRecords: [MiMoReasoningRecord]

        init(
            text: String,
            exchanges: [MiMoFunctionExchange],
            successfulToolNames: Set<String>,
            reasoningRecords: [MiMoReasoningRecord] = []
        ) {
            self.text = text
            self.exchanges = exchanges
            self.successfulToolNames = successfulToolNames
            self.reasoningRecords = reasoningRecords
        }
    }

    enum CandidateDecision: Sendable, Equatable {
        case accept
        case retry(String)
    }

    private let client: any MiMoResponding
    private let maximumToolRoundTrips: Int
    private let maximumCandidateRepairs: Int
    private let maximumTransportRecoveries: Int

    init(
        client: any MiMoResponding,
        maximumToolRoundTrips: Int = 8,
        maximumCandidateRepairs: Int = 3,
        maximumTransportRecoveries: Int = 2
    ) {
        self.client = client
        self.maximumToolRoundTrips = maximumToolRoundTrips
        self.maximumCandidateRepairs = max(1, maximumCandidateRepairs)
        self.maximumTransportRecoveries = max(0, maximumTransportRecoveries)
    }

    func run(
        model: String,
        instructions: String,
        messages: [MiMoInputMessage],
        tools: [InsightToolDefinition],
        credential: MiMoCredential,
        initialExchanges: [MiMoFunctionExchange] = [],
        execute: (InsightFunctionCall) async -> ToolObservation,
        reviewCandidate: (
            _ text: String,
            _ exchanges: [MiMoFunctionExchange],
            _ successfulToolNames: Set<String>
        ) async throws -> CandidateDecision,
        resolveRejectedCandidate: (
            _ text: String,
            _ issue: String,
            _ exchanges: [MiMoFunctionExchange],
            _ successfulToolNames: Set<String>
        ) -> String,
        configuration: InsightRunConfiguration? = nil,
        budget: InsightRunBudget? = nil,
        onEvent: @escaping @MainActor (InsightHarnessEvent) -> Void = { _ in },
        onCheckpoint: @MainActor ([MiMoFunctionExchange]) async throws -> Void = { _ in }
    ) async throws -> Result {
        // A local typed planner may seed an authoritative observation before
        // the model turn. Keeping it in the same exchange format means the
        // model still sees normal tool evidence, while the caller can remove
        // the ambiguous tools for that turn and prevent a raw-record detour.
        var exchanges = initialExchanges
        var successfulToolNames = Set(initialExchanges.filter(\.succeeded).map { $0.call.name })
        var requestInstructions = instructions
        let runConfiguration = budget?.configuration ?? configuration ?? InsightRunConfiguration()
        let runBudget = budget ?? InsightRunBudget(configuration: runConfiguration)
        let toolRoundLimit = configuration == nil && budget == nil
            ? maximumToolRoundTrips : runConfiguration.maximumToolRoundTrips
        let extraReviews = configuration == nil && budget == nil
            ? 0 : runConfiguration.additionalReviewCount
        var maximumOutputTokens = runConfiguration.maximumOutputTokensPerRequest
        var didRetryOutputLimit = false
        var candidateRepairCount = 0
        var allReasoningRecords: [MiMoReasoningRecord] = []
        var reviewIndex = 0

        onEvent(.phase(.preparing))
        while true {
            try Task.checkCancellation()
            try runBudget.checkActiveTime()
            var functionCalls: [InsightFunctionCall] = []
            var roundText = ""
            var roundReasoning: [MiMoReasoningRecord] = []
            var responseID: String?
            var transportRecoveryCount = 0

            while true {
                functionCalls.removeAll(keepingCapacity: true)
                roundText = ""
                roundReasoning.removeAll(keepingCapacity: true)
                responseID = nil
                let request = MiMoConversationRequest(
                    model: model,
                    instructions: requestInstructions,
                    messages: messages,
                    functionExchanges: exchanges,
                    tools: runBudget.toolRoundTrips < toolRoundLimit ? tools : [],
                    maximumOutputTokens: maximumOutputTokens,
                    thinkingEnabled: runConfiguration.thinkingEnabled
                )
                do {
                    onEvent(.phase(.preparing))
                    for try await event in try runBudget.stream(
                        client: client,
                        request: request,
                        credential: credential,
                        onEvent: onEvent
                    ) {
                        try Task.checkCancellation()
                        switch event {
                        case .responseStarted(let id):
                            responseID = id
                        case .textDelta(let delta):
                            // Text emitted beside tool calls is provisional. It
                            // becomes user-visible only after the model finishes.
                            roundText += delta
                            onEvent(.phase(.answering))
                        case .reasoningDelta(let delta):
                            onEvent(.phase(.thinking))
                            onEvent(.reasoningDelta(delta))
                        case .reasoningRecorded(let record):
                            if let index = roundReasoning.firstIndex(where: { $0.id == record.id }) {
                                roundReasoning[index] = record
                            } else {
                                roundReasoning.append(record)
                            }
                            onEvent(.reasoningRecorded(record))
                        case .functionCall(let call):
                            functionCalls.append(call)
                        case .completed, .usage:
                            break
                        }
                    }
                    break
                } catch let error as MiMoClientError
                    where error.isOutputLimitIncomplete && !didRetryOutputLimit {
                    didRetryOutputLimit = true
                    maximumOutputTokens = runConfiguration.maximumOutputTokensPerRequest
                    requestInstructions = instructions + """


                    输出长度纠正：上一轮因输出长度上限而中断。请重新生成精简但完整的工具调用或最终答案，不要续写残缺内容。
                    """
                } catch let error as MiMoClientError
                    where error.isAutomaticallyRecoverable &&
                        transportRecoveryCount < maximumTransportRecoveries {
                    transportRecoveryCount += 1
                    try await Task.sleep(
                        for: .milliseconds(Int64(250 * transportRecoveryCount))
                    )
                } catch let pause as InsightRunPause {
                    onEvent(.paused(pause))
                    throw pause
                }
            }

            for record in roundReasoning {
                if let index = allReasoningRecords.firstIndex(where: { $0.id == record.id }) {
                    allReasoningRecords[index] = record
                } else {
                    allReasoningRecords.append(record)
                }
            }

            if functionCalls.isEmpty {
                var decision: CandidateDecision = .accept
                do {
                    // Every level performs the baseline review. Higher App
                    // levels make additional real review calls using the same
                    // closure and shared budget, never a simulated progress row.
                    for index in 0...extraReviews {
                        try runBudget.checkActiveTime()
                        reviewIndex += 1
                        onEvent(.phase(.reviewing))
                        onEvent(.candidateReview(index: reviewIndex, isAdditional: index > 0))
                        decision = try await reviewCandidate(roundText, exchanges, successfulToolNames)
                        if case .retry = decision { break }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let pause as InsightRunPause {
                    onEvent(.paused(pause))
                    throw pause
                } catch {
                    decision = .retry(
                        "内部语义复核没有返回有效结果：\(error.localizedDescription)"
                    )
                }
                switch decision {
                case .accept:
                    try runBudget.checkActiveTime()
                    return Result(
                        text: roundText,
                        exchanges: exchanges,
                        successfulToolNames: successfulToolNames,
                        reasoningRecords: allReasoningRecords
                    )
                case .retry(let correctiveInstruction):
                    guard candidateRepairCount < maximumCandidateRepairs else {
                        return Result(
                            text: resolveRejectedCandidate(
                                roundText,
                                correctiveInstruction,
                                exchanges,
                                successfulToolNames
                            ),
                            exchanges: exchanges,
                            successfulToolNames: successfulToolNames,
                            reasoningRecords: allReasoningRecords
                        )
                    }
                    candidateRepairCount += 1
                    requestInstructions = instructions + """


                    Harness 复核纠正：\(correctiveInstruction)
                    请继续使用已有工具证据；若证据不足或计算口径不对，调用合适工具补齐后再给出完整答案。
                    """
                    continue
                }
            }

            guard runBudget.toolRoundTrips < toolRoundLimit else {
                let pause = InsightRunPause(reason: .toolRoundTrips, snapshot: runBudget.snapshot)
                onEvent(.paused(pause))
                throw pause
            }
            try runBudget.beginToolRoundTrip()
            onEvent(.budgetUpdated(runBudget.snapshot))
            onEvent(.phase(.querying))
            let turnID = responseID ?? UUID().uuidString

            for call in functionCalls {
                try runBudget.checkActiveTime()
                onEvent(.toolStarted(callID: call.callID, name: call.name))
                let observation = await execute(call)
                try Task.checkCancellation()
                onEvent(.toolFinished(callID: call.callID, name: call.name, succeeded: observation.succeeded))
                if observation.succeeded {
                    successfulToolNames.insert(call.name)
                }
                exchanges.append(MiMoFunctionExchange(
                    call: call,
                    output: observation.output,
                    reasoningRecords: roundReasoning,
                    assistantTurnID: turnID,
                    assistantText: roundText,
                    succeeded: observation.succeeded
                ))
                onEvent(.checkpoint(exchanges))
                try await onCheckpoint(exchanges)
            }
        }

    }
}

struct InsightGroundedAnswerReview: Sendable, Equatable {
    let isAccepted: Bool
    let claimScope: String
    let evidenceSufficient: Bool
    let issue: String
    let correctiveInstruction: String
}

/// Deterministic presentation contract emitted by a successful calculation.
/// The model still understands the question and writes the analysis, while the
/// harness prevents it from silently collapsing a required multidimensional
/// result back into one convenient average.
enum InsightCalculationAnswerContract {
    private struct GroupAnchor {
        let label: String
        let sampleCount: Int
        let sheepCount: Int
        let value: Double
    }

    private struct CompleteAnalysisEvidence {
        let requiredSections: Set<String>
        let groupAnchors: [GroupAnchor]
    }

    static func correctiveInstruction(
        candidate: String,
        exchanges: [MiMoFunctionExchange]
    ) -> String? {
        var completeEvidence: CompleteAnalysisEvidence?
        for exchange in exchanges.reversed()
            where exchange.call.name == InsightFarmCalculationEngine.toolName {
            guard let data = exchange.output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["evidence_kind"] as? String == "farm_calculation",
                  let contract = object["analysis_contract"] as? [String: Any],
                  contract["kind"] as? String == "multidimensional_adjacent_rate_analysis",
                  let sections = contract["required_answer_sections"] as? [String] else {
                continue
            }
            completeEvidence = CompleteAnalysisEvidence(
                requiredSections: Set(sections),
                groupAnchors: groupAnchors(from: object)
            )
            break
        }
        guard let completeEvidence, !completeEvidence.requiredSections.isEmpty else { return nil }

        let missing = completeEvidence.requiredSections
            .filter { !candidate.localizedCaseInsensitiveContains($0) }
            .sorted()
        if !missing.isEmpty {
            return "完整变化率分析尚缺少以下必需部分：\(missing.joined(separator: "、"))。请使用已有 analysis_sections 证据逐节补齐，不能只报一个总体平均值。"
        }

        let lines = candidate
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let mismatches = completeEvidence.groupAnchors.compactMap { anchor -> String? in
            let matchingLines = lines.filter {
                $0.localizedCaseInsensitiveContains(anchor.label)
            }
            guard !matchingLines.isEmpty else {
                return "缺少分组“\(anchor.label)”"
            }
            guard matchingLines.contains(where: { lineMatches($0, anchor: anchor) }) else {
                return "“\(anchor.label)”应为样本 \(anchor.sampleCount)、羊只 \(anchor.sheepCount)、平均值 \(decimal(anchor.value))"
            }
            return nil
        }
        guard !mismatches.isEmpty else { return nil }
        let shown = mismatches.prefix(10).joined(separator: "；")
        let suffix = mismatches.count > 10 ? "；其余分组也必须逐项照录" : ""
        return "完整变化率分析与工具证据仍有逐项不一致：\(shown)\(suffix)。请逐行使用 analysis_sections 中的原始分组名称、sample_count、sheep_count 和 value；不得改名、漏项或凭空改数。"
    }

    private static func groupAnchors(from object: [String: Any]) -> [GroupAnchor] {
        guard let sections = object["analysis_sections"] as? [[String: Any]] else {
            return []
        }
        return sections.flatMap { section -> [GroupAnchor] in
            let dimension = section["dimension"] as? String ?? ""
            guard dimension != "none",
                  let groups = section["groups"] as? [[String: Any]] else {
                return []
            }
            return groups.compactMap { group in
                guard let key = group["key"] as? String,
                      let sampleCount = group["sample_count"] as? Int,
                      let sheepCount = group["sheep_count"] as? Int,
                      let value = group["value"] as? NSNumber else {
                    return nil
                }
                let label: String
                if dimension == "weighing_interval",
                   let suffix = key.range(of: "（") {
                    label = String(key[..<suffix.lowerBound])
                } else {
                    label = key
                }
                return GroupAnchor(
                    label: label,
                    sampleCount: sampleCount,
                    sheepCount: sheepCount,
                    value: value.doubleValue
                )
            }
        }
    }

    private static func lineMatches(_ line: String, anchor: GroupAnchor) -> Bool {
        let sampleOccurrences = standaloneOccurrences(of: anchor.sampleCount, in: line)
        let sheepOccurrences = standaloneOccurrences(of: anchor.sheepCount, in: line)
        let countsMatch: Bool
        if anchor.sampleCount == anchor.sheepCount {
            countsMatch = sampleOccurrences >= 2
        } else {
            countsMatch = sampleOccurrences >= 1 && sheepOccurrences >= 1
        }
        guard countsMatch else { return false }
        return decimalVariants(anchor.value).contains { line.contains($0) }
    }

    private static func standaloneOccurrences(of value: Int, in text: String) -> Int {
        let pattern = "(?<![0-9])\(value)(?![0-9])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return expression.numberOfMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
    }

    private static func decimalVariants(_ value: Double) -> Set<String> {
        Set([
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value),
            String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value),
        ])
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// A model-based semantic guard. It judges the relationship between the user's
/// natural-language request, the agent's tool plan/results, and the proposed
/// answer. It does not encode a list of farm metrics or user phrasings.
@MainActor
enum InsightGroundedAnswerReviewer {
    private static let toolName = "review_grounded_farm_answer"
    private static let workflowEvaluationInstruction = """
    当前还必须复核完整的方案或目标工作流 JSON，不能只复核 analysis 文本。逐项核对 steps、criteria、completionCriteria、missingInformation、stepCompleted、completed、remaining，以及当前步骤和目标完成条件；检查步骤的对象、范围、先后依赖、剩余事项和完成标志是否与实际工具证据一致，不能让分析正文正确掩盖完成字段不实。
    stepCompleted=true 或 completed=true 声称的是当前工作流已经完成的事实，claim_scope 必须是 farm_specific；只有成功工具的实际结果直接足以证明当前步骤或全部目标完成条件时，evidence_sufficient 才能为 true。失败工具、空结果、不相关查询、仅生成操作草案、等待用户确认或等待云端写入都不是完成证据。写入类步骤必须有实际云端回执或权威状态确认，不能把草案、计划或预期结果冒充已落地事实。
    若完成声明仍缺云端回执、必要字段、步骤证据或任一完成条件，必须 verdict=retry，给出具体缺口和内部纠正要求；不能通过 general 或 clarification 放行 true 完成标志。尚未完成的方案可以明确列出 missingInformation 或 remaining，但不得同时声称相关步骤或目标已经完成。所有字段都必须真实覆盖当前工作流，不能漏掉待办事项来制造完成。
    """

    static func review(
        question: String,
        candidate: String,
        exchanges: [MiMoFunctionExchange],
        successfulToolNames: Set<String>,
        model: String,
        credential: MiMoCredential,
        client: any MiMoResponding,
        workflowEvaluation: Bool = false,
        budget: InsightRunBudget? = nil,
        onEvent: @escaping @MainActor (InsightHarnessEvent) -> Void = { _ in }
    ) async throws -> InsightGroundedAnswerReview {
        let evidence = compactEvidence(exchanges)
        let groundedToolNames = workflowEvaluation
            ? successfulToolNames.intersection(Set(exchanges.filter(\.succeeded).map { $0.call.name }))
            : successfulToolNames
        let payload = """
        用户问题：
        \(question)

        待展示答案：
        \(candidate)

        本轮已执行工具及结果：
        \(evidence.text)

        本轮成功工具名称：
        \(groundedToolNames.sorted().joined(separator: ", "))
        """
        let definition = InsightToolDefinition(
            name: toolName,
            description: "提交问题、工具计划/结果与待展示答案的一致性复核。必须且只能调用一次。",
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "verdict": .object([
                        "type": .string("string"),
                        "enum": .array([.string("accept"), .string("retry")]),
                        "description": .string("答案是否真正回答了用户所问的指标、对象、范围和时间"),
                    ]),
                    "claim_scope": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("general"),
                            .string("farm_specific"),
                            .string("clarification"),
                        ]),
                        "description": .string("待展示答案是否声称当前牧场事实、仅为通用知识，或只询问必要缺失字段"),
                    ]),
                    "evidence_sufficient": .object([
                        "type": .string("boolean"),
                        "description": .string("本轮成功工具结果是否直接足以支持待展示答案中的全部当前牧场事实"),
                    ]),
                    "issue": .object([
                        "type": .string("string"),
                        "description": .string("accept 时传空字符串；retry 时简述具体不一致"),
                    ]),
                    "corrective_instruction": .object([
                        "type": .string("string"),
                        "description": .string("accept 时传空字符串；retry 时说明需要补什么证据或重做什么计算"),
                    ]),
                ]),
                "required": .array([
                    .string("verdict"), .string("claim_scope"), .string("evidence_sufficient"),
                    .string("issue"), .string("corrective_instruction"),
                ]),
                "additionalProperties": .bool(false),
            ]
        )
        let request = MiMoConversationRequest(
            model: model,
            instructions: """
            你是 agent harness 的最终语义复核器，不负责重新回答问题。
            比较最近对话、当前用户消息、每个工具的调用参数、工具结果和待展示答案。先按自然语言语义判断答案是否声称当前牧场、具体羊只、圈舍、日期、数量、状态、记录或计算结果；这类事实必须有本轮成功工具结果直接支持，不能因为句子没有出现“查询”“耳号”等固定词就放行。工具报错、空结果和不相关结果都不能证明结论。普通闲聊或通用养殖知识若没有声称当前牧场事实，可以在无工具证据时通过。若确实缺少用户才能提供的必要字段，可以通过一个只询问该字段的明确问题；不能用泛泛的“请重试”代替内部修复。
            必须如实填写 claim_scope；只要答案包含当前牧场或具体记录事实就用 farm_specific。farm_specific 只有在本轮成功工具结果能直接支持全部结论时 evidence_sufficient 才能为 true。检查答案是否回答了用户实际询问的量，而不是只返回相关原始记录；对象、圈舍、耳号、日期、单位、分组、公式和完整性必须一致。若计算证据包含 analysis_contract，必须检查候选答案是否真实覆盖其 required_dimensions 和 required_answer_sections：总体、真实相邻称重区间、生产批次、生命周期以及数据完整性，且清楚说明样本/羊只数与统计口径；一个跨期首末平均值或一个最新区间都不能冒充完整群体分析。不能因为主题相关就通过，也不能凭常识补足工具没有证明的数字。若证据或计算不足，verdict=retry，并给出可执行的内部纠正说明，让 agent 补查、重算或重写；不要要求用户重新发送同一个问题。若完全一致，verdict=accept。必须调用 review_grounded_farm_answer 一次，不输出其他文字。
            """ + (workflowEvaluation ? "\n\n" + workflowEvaluationInstruction : ""),
            messages: [MiMoInputMessage(role: .user, text: payload)],
            tools: [definition],
            maximumOutputTokens: 2_048,
            thinkingEnabled: false
        )
        let reviewBudget = budget ?? InsightRunBudget()
        var calls: [InsightFunctionCall] = []
        var transportRecoveryCount = 0
        while true {
            calls.removeAll(keepingCapacity: true)
            do {
                for try await event in try reviewBudget.stream(
                    client: client,
                    request: request,
                    credential: credential,
                    onEvent: onEvent
                ) {
                    try Task.checkCancellation()
                    if case .functionCall(let call) = event, call.name == toolName {
                        calls.append(call)
                    }
                }
                break
            } catch let error as MiMoClientError
                where error.isAutomaticallyRecoverable && transportRecoveryCount < 2 {
                transportRecoveryCount += 1
                try await Task.sleep(
                    for: .milliseconds(Int64(250 * transportRecoveryCount))
                )
            }
        }
        guard calls.count == 1,
              let data = calls[0].argumentsJSON.data(using: .utf8),
              let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = values["verdict"] as? String,
              ["accept", "retry"].contains(verdict),
              let claimScope = values["claim_scope"] as? String,
              ["general", "farm_specific", "clarification"].contains(claimScope),
              let evidenceSufficient = values["evidence_sufficient"] as? Bool,
              let issue = values["issue"] as? String,
              let correctiveInstruction = values["corrective_instruction"] as? String else {
            throw MiMoClientError.invalidResponse
        }
        let farmClaimIsGrounded = claimScope != "farm_specific" ||
            (evidenceSufficient && !groundedToolNames.isEmpty)
        let workflowClaim: [String: Any]? = workflowEvaluation
            ? candidate.data(using: .utf8).flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            } : nil
        let assertsWorkflowCompletion = workflowClaim?["stepCompleted"] as? Bool == true
            || workflowClaim?["completed"] as? Bool == true
        let workflowClaimIsGrounded = !assertsWorkflowCompletion ||
            (claimScope == "farm_specific" && evidenceSufficient && !groundedToolNames.isEmpty && evidence.isComplete)
        let isAccepted = verdict == "accept" && farmClaimIsGrounded && workflowClaimIsGrounded
        let missingWorkflowGrounding = assertsWorkflowCompletion && !workflowClaimIsGrounded
        return InsightGroundedAnswerReview(
            isAccepted: isAccepted,
            claimScope: claimScope,
            evidenceSufficient: evidenceSufficient,
            issue: isAccepted || !issue.isEmpty
                ? issue
                : missingWorkflowGrounding
                    ? "工作流声称已完成，但复核未确认足以证明完成条件的实际成功工具证据。"
                    : "答案声称了当前牧场事实，但本轮没有足以支持该结论的成功工具证据。",
            correctiveInstruction: isAccepted || !correctiveInstruction.isEmpty
                ? correctiveInstruction
                : missingWorkflowGrounding
                    ? "核对当前步骤及完成条件；缺少实际完成证据时将 stepCompleted/completed 改为 false 并如实列出 remaining 或缺失信息，不能冒充完成。"
                    : "根据当前问题调用合适的本地工具取得直接证据，再重新作答。"
        )
    }

    private struct ReviewEvidence {
        let text: String
        let isComplete: Bool
    }

    private static func compactEvidence(_ exchanges: [MiMoFunctionExchange]) -> ReviewEvidence {
        let maximumTotalCharacters = 160_000
        var remaining = maximumTotalCharacters
        var blocks: [(index: Int, text: String)] = []
        var omittedCount = 0
        // Prefer recent evidence, preserve the original order, and include
        // complete tool packets only. Slicing JSON would lose scope, count or
        // receipt fields while making an incomplete packet appear complete.
        for (index, exchange) in exchanges.enumerated().reversed() {
            let block = """
            [\(index + 1)] tool=\(exchange.call.name)
            succeeded=\(exchange.succeeded)
            arguments=\(exchange.call.argumentsJSON)
            output=\(exchange.output)
            """
            guard block.count <= remaining else {
                omittedCount += 1
                continue
            }
            blocks.append((index, block))
            remaining -= block.count
        }
        var text = blocks.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n\n")
        if omittedCount > 0 {
            text = "[复核材料不完整：因材料预算略去 \(omittedCount) 个完整工具证据包，未截断包内 JSON。以下是选取的证据摘要，不能证明未覆盖的事实或全部工作流完成条件。]\n\n" + text
        } else if text.isEmpty {
            text = "（没有工具证据）"
        }
        return ReviewEvidence(text: text, isComplete: omittedCount == 0)
    }
}
