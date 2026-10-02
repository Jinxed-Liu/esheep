import Foundation

/// These levels control the App's analysis workflow. MiMo currently treats
/// every enabled native reasoning effort identically.
enum InsightAnalysisEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }
    var sliderValue: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 1)
    }
    static func from(sliderValue: Double) -> Self {
        Self.allCases[min(2, max(0, Int(sliderValue.rounded())))]
    }
}

struct InsightRunConfiguration: Codable, Equatable, Sendable {
    var effort: InsightAnalysisEffort
    var thinkingEnabled: Bool
    var showReasoning: Bool

    init(
        effort: InsightAnalysisEffort = .medium,
        thinkingEnabled: Bool = true,
        showReasoning: Bool = true
    ) {
        self.effort = effort
        self.thinkingEnabled = thinkingEnabled
        self.showReasoning = showReasoning
    }

    var maximumToolRoundTrips: Int {
        switch effort { case .low: 4; case .medium: 8; case .high: 12 }
    }
    var maximumModelRequests: Int {
        switch effort { case .low: 8; case .medium: 16; case .high: 24 }
    }
    var maximumOutputTokens: Int {
        switch effort { case .low: 32_768; case .medium: 65_536; case .high: 98_304 }
    }
    var maximumActiveSeconds: Double {
        switch effort { case .low: 120; case .medium: 240; case .high: 600 }
    }
    var additionalReviewCount: Int {
        switch effort { case .low: 0; case .medium: 1; case .high: 2 }
    }
    var maximumOutputTokensPerRequest: Int { 8_192 }
}

enum InsightAnalysisPreference {
    static func load(for accountID: UUID, defaults: UserDefaults = .standard) -> InsightRunConfiguration {
        guard let data = defaults.data(forKey: key(for: accountID)),
              let configuration = try? JSONDecoder().decode(InsightRunConfiguration.self, from: data) else {
            return InsightRunConfiguration()
        }
        return configuration
    }

    static func save(
        _ configuration: InsightRunConfiguration,
        for accountID: UUID,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key(for: accountID))
    }

    static func remove(for accountID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: accountID))
    }

    private static func key(for accountID: UUID) -> String {
        "insights.analysis-configuration.\(accountID.uuidString.lowercased())"
    }
}

enum InsightHarnessPhase: String, Codable, Sendable {
    case preparing, thinking, querying, reviewing, answering
}

struct InsightRunBudgetSnapshot: Codable, Equatable, Sendable {
    let modelRequests: Int
    let toolRoundTrips: Int
    let outputTokens: Int
    let inputTokens: Int
    let reasoningTokens: Int
    let activeSeconds: Double
    let outputIsEstimated: Bool
}

struct InsightRunPause: Error, LocalizedError, Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case modelRequests, toolRoundTrips, outputTokens, activeTime
    }
    let reason: Reason
    let snapshot: InsightRunBudgetSnapshot

    var errorDescription: String? {
        "本次分析已达到预算，已暂停。尚未完成校验的内容不会作为结论展示。"
    }
}

enum InsightHarnessEvent: Sendable, Equatable {
    case phase(InsightHarnessPhase)
    case reasoningDelta(String)
    case reasoningRecorded(MiMoReasoningRecord)
    case toolStarted(callID: String, name: String)
    case toolFinished(callID: String, name: String, succeeded: Bool)
    case candidateReview(index: Int, isAdditional: Bool)
    case checkpoint([MiMoFunctionExchange])
    case usage(InsightTokenUsage)
    case budgetUpdated(InsightRunBudgetSnapshot)
    case paused(InsightRunPause)
}

/// One object is shared by the agent, mandatory reviewer, optional reviewers,
/// repairs and transport retries. Waiting for the user's authorization pauses
/// the active clock without replenishing any request or token allowance.
@MainActor
final class InsightRunBudget {
    let configuration: InsightRunConfiguration
    private(set) var modelRequests = 0
    private(set) var toolRoundTrips = 0
    private(set) var outputTokens = 0
    private(set) var inputTokens = 0
    private(set) var reasoningTokens = 0
    private var outputIsEstimated = false
    private let clock = ContinuousClock()
    private var activeStartedAt: ContinuousClock.Instant?
    private var accumulatedActiveSeconds: Double = 0

    init(
        configuration: InsightRunConfiguration = InsightRunConfiguration(),
        initialSnapshot snapshot: InsightRunBudgetSnapshot? = nil
    ) {
        self.configuration = configuration
        if let snapshot {
            modelRequests = snapshot.modelRequests
            toolRoundTrips = snapshot.toolRoundTrips
            outputTokens = snapshot.outputTokens
            inputTokens = snapshot.inputTokens
            reasoningTokens = snapshot.reasoningTokens
            accumulatedActiveSeconds = snapshot.activeSeconds
            outputIsEstimated = snapshot.outputIsEstimated
        }
        activeStartedAt = clock.now
    }

    var snapshot: InsightRunBudgetSnapshot {
        InsightRunBudgetSnapshot(
            modelRequests: modelRequests,
            toolRoundTrips: toolRoundTrips,
            outputTokens: outputTokens,
            inputTokens: inputTokens,
            reasoningTokens: reasoningTokens,
            activeSeconds: activeSeconds,
            outputIsEstimated: outputIsEstimated
        )
    }

    var activeSeconds: Double {
        accumulatedActiveSeconds + (activeStartedAt.map { seconds($0.duration(to: clock.now)) } ?? 0)
    }

    func pauseActiveClock() {
        guard let start = activeStartedAt else { return }
        accumulatedActiveSeconds += seconds(start.duration(to: clock.now))
        activeStartedAt = nil
    }

    func resumeActiveClock() {
        guard activeStartedAt == nil else { return }
        activeStartedAt = clock.now
    }

    func checkActiveTime() throws {
        if activeSeconds >= configuration.maximumActiveSeconds {
            throw InsightRunPause(reason: .activeTime, snapshot: snapshot)
        }
    }

    func beginToolRoundTrip() throws {
        try checkActiveTime()
        guard toolRoundTrips < configuration.maximumToolRoundTrips else {
            throw InsightRunPause(reason: .toolRoundTrips, snapshot: snapshot)
        }
        toolRoundTrips += 1
    }

    /// Wrap the real provider stream so every attempt, including failed or
    /// retried requests, consumes the shared allowance and deadline.
    func stream(
        client: any MiMoResponding,
        request: MiMoConversationRequest,
        credential: MiMoCredential,
        onEvent: @escaping @MainActor (InsightHarnessEvent) -> Void = { _ in }
    ) throws -> AsyncThrowingStream<InsightModelEvent, Error> {
        try checkActiveTime()
        guard modelRequests < configuration.maximumModelRequests else {
            throw InsightRunPause(reason: .modelRequests, snapshot: snapshot)
        }
        let remaining = configuration.maximumOutputTokens - outputTokens
        guard remaining >= 128 else {
            throw InsightRunPause(reason: .outputTokens, snapshot: snapshot)
        }
        modelRequests += 1
        onEvent(.budgetUpdated(snapshot))
        let boundedRequest = request.withMaximumOutputTokens(min(
            min(request.maximumOutputTokens, configuration.maximumOutputTokensPerRequest), remaining
        ))

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var generatedText = ""
                var generatedReasoning = ""
                var generatedArguments = ""
                var recordedReasoning: [String: String] = [:]
                var reportedUsage: InsightTokenUsage?
                var didCharge = false

                @MainActor func estimatedOutputTokens() -> Int {
                    let visible = generatedText + generatedArguments
                    let reasoning = recordedReasoning.values.joined(separator: "\n")
                    let deltaTokens = generatedReasoning.isEmpty ? 0
                        : InsightContextCompressor.estimatedTokens(for: generatedReasoning)
                    let recordTokens = reasoning.isEmpty ? 0
                        : InsightContextCompressor.estimatedTokens(for: reasoning)
                    return (visible.isEmpty ? 0 : InsightContextCompressor.estimatedTokens(for: visible))
                        + max(deltaTokens, recordTokens)
                }

                @MainActor func charge() {
                    guard !didCharge else { return }
                    didCharge = true
                    if let reportedUsage {
                        outputTokens += max(0, reportedUsage.outputTokens)
                        inputTokens += max(0, reportedUsage.inputTokens)
                        reasoningTokens += max(0, reportedUsage.reasoningTokens)
                        onEvent(.usage(reportedUsage))
                    } else {
                        // A disconnected stream may omit final usage. Account
                        // conservatively for received content and mark the
                        // total as estimated, rather than inventing usage.
                        outputTokens += estimatedOutputTokens()
                        outputIsEstimated = true
                    }
                    onEvent(.budgetUpdated(snapshot))
                }

                let deadlineTask = Task { @MainActor in
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .milliseconds(250))
                            try checkActiveTime()
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        // Charge before releasing the consumer; otherwise a
                        // persisted pause could race the provider cancellation
                        // and omit content already received in this request.
                        charge()
                        if let pause = error as? InsightRunPause {
                            continuation.finish(throwing: InsightRunPause(reason: pause.reason, snapshot: snapshot))
                        } else {
                            continuation.finish(throwing: error)
                        }
                    }
                }
                defer { deadlineTask.cancel() }
                do {
                    for try await event in client.stream(request: boundedRequest, credential: credential) {
                        try Task.checkCancellation()
                        try checkActiveTime()
                        switch event {
                        case .textDelta(let delta): generatedText += delta
                        case .reasoningDelta(let delta): generatedReasoning += delta
                        case .functionCall(let call): generatedArguments += call.argumentsJSON
                        case .completed(_, let usage):
                            if let usage { reportedUsage = usage }
                        case .usage(let usage): reportedUsage = usage
                        case .reasoningRecorded(let record): recordedReasoning[record.id] = record.text
                        case .responseStarted: break
                        }
                        if reportedUsage == nil {
                            let observed = estimatedOutputTokens()
                            if outputTokens + observed >= configuration.maximumOutputTokens {
                                throw InsightRunPause(reason: .outputTokens, snapshot: snapshot)
                            }
                        }
                        continuation.yield(event)
                    }
                    charge()
                    try checkActiveTime()
                    guard outputTokens <= configuration.maximumOutputTokens else {
                        throw InsightRunPause(reason: .outputTokens, snapshot: snapshot)
                    }
                    continuation.finish()
                } catch {
                    charge()
                    if let pause = error as? InsightRunPause {
                        continuation.finish(throwing: InsightRunPause(reason: pause.reason, snapshot: snapshot))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
