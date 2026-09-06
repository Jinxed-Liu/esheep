import Foundation
import Observation
import SwiftData

struct ESheepCloudLocalCycleSnapshot: Sendable {
    let farmGeneration: Int
    let lastAppliedEventSequence: Int64
    let cloudHead: Int64
    let readyCommands: [ESheepCloudCommandEnvelopeV2]
    let commandsAwaitingStatus: [UUID]
    let readyAttentionResolutions: [ESheepCloudAttentionResolutionV2]
    let attentionResolutionsAwaitingStatus: [UUID]
    let pendingCount: Int
    let attentionCount: Int
    let rejectedCount: Int
    let integrityState: ESheepCloudIntegrityState
    let activityState: ESheepCloudFarmActivityState
    let lastSafeSaveAt: Date?
    /// Asset transfers are part of the save contract even though they do not
    /// create business commands. These counters keep a queued or failed
    /// photo from being reported as fully saved.
    let pendingAssetCount: Int
    let failedAssetCount: Int

    init(
        farmGeneration: Int,
        lastAppliedEventSequence: Int64,
        cloudHead: Int64,
        readyCommands: [ESheepCloudCommandEnvelopeV2],
        commandsAwaitingStatus: [UUID],
        readyAttentionResolutions: [ESheepCloudAttentionResolutionV2],
        attentionResolutionsAwaitingStatus: [UUID],
        pendingCount: Int,
        attentionCount: Int,
        rejectedCount: Int,
        integrityState: ESheepCloudIntegrityState,
        activityState: ESheepCloudFarmActivityState,
        lastSafeSaveAt: Date?,
        pendingAssetCount: Int = 0,
        failedAssetCount: Int = 0
    ) {
        self.farmGeneration = farmGeneration
        self.lastAppliedEventSequence = lastAppliedEventSequence
        self.cloudHead = cloudHead
        self.readyCommands = readyCommands
        self.commandsAwaitingStatus = commandsAwaitingStatus
        self.readyAttentionResolutions = readyAttentionResolutions
        self.attentionResolutionsAwaitingStatus = attentionResolutionsAwaitingStatus
        self.pendingCount = pendingCount
        self.attentionCount = attentionCount
        self.rejectedCount = rejectedCount
        self.integrityState = integrityState
        self.activityState = activityState
        self.lastSafeSaveAt = lastSafeSaveAt
        self.pendingAssetCount = pendingAssetCount
        self.failedAssetCount = failedAssetCount
    }
}

struct ESheepCloudSyncCycleReport: Sendable, Equatable {
    let pulledEventCount: Int
    let submittedCommandCount: Int
    let queriedCommandCount: Int
    let pendingCount: Int
    let attentionCount: Int
    let safelySavedAt: Date?
}

enum ESheepCloudCoreError: LocalizedError {
    case farmStateMissing
    case farmGenerationChanged
    case applicationUpdateRequired
    case reauthenticationRequired
    case deviceIdentityChanged
    case cloudWriteFrozen(traceID: String?)
    case resultMissing(UUID)
    case attentionMissing
    case attentionNoLongerOpen
    case attentionAlreadyResolving

    var errorDescription: String? {
        switch self {
        case .farmStateMissing:
            "这座牧场尚未准备好使用 eSheep+ 云。"
        case .farmGenerationChanged:
            "牧场云端身份已经更新，需要重新接收完整资料。"
        case .applicationUpdateRequired:
            "需要更新 eSheep+ 后才能继续使用这座云端牧场。"
        case .reauthenticationRequired:
            "账号登录已经失效，请重新登录。"
        case .deviceIdentityChanged:
            "当前设备安全身份已经变化，请重新登录后再试。"
        case .cloudWriteFrozen:
            "eSheep+ 云正在保护这座牧场的数据，当前只能查看。"
        case .resultMissing:
            "eSheep+ 云尚未确认这项内容，将使用原编号安全重试。"
        case .attentionMissing:
            "这项需要确认的内容已经不存在，请刷新后再试。"
        case .attentionNoLongerOpen:
            "这项内容已经处理完成。"
        case .attentionAlreadyResolving:
            "这项内容正在按刚才的选择处理，请稍后查看。"
        }
    }
}

@MainActor
@Observable
final class ESheepCloudViewState {
    enum Presentation: Sendable, Equatable {
        case safelySaved
        case saving(Int)
        case offline(Int)
        case failed(ESheepCloudSyncFailure.Kind)
        case needsConfirmation(Int)
        case reauthenticationRequired
        case partiallyUnsaved
        case checking
        case preparing
    }

    private(set) var presentation: Presentation = .preparing
    private(set) var lastSafeSaveAt: Date?
    private(set) var pendingCount = 0
    private(set) var attentionCount = 0
    private(set) var lastErrorMessage: String?
    private(set) var failure: ESheepCloudSyncFailure?

    var statusTitle: String {
        switch presentation {
        case .safelySaved: "已安全保存"
        case .saving(let count): "正在保存 \(count) 项"
        case .offline: "离线，联网后自动保存"
        case .failed(.serviceUnavailable): "云端保存服务暂不可用"
        case .failed: "部分内容尚未保存，请查看原因"
        case .needsConfirmation(let count): "\(count) 项需要你确认"
        case .reauthenticationRequired: "需要重新登录"
        case .partiallyUnsaved: "部分内容尚未保存，请稍后再试"
        case .checking: "正在检查牧场资料是否完整"
        case .preparing: "正在准备牧场资料"
        }
    }

    func update(
        from snapshot: ESheepCloudLocalCycleSnapshot,
        transportError: Error? = nil,
        authenticationRequired: Bool = false,
        cycleCompleted: Bool = false
    ) {
        pendingCount = snapshot.pendingCount
        attentionCount = snapshot.attentionCount
        lastSafeSaveAt = snapshot.lastSafeSaveAt
        if let transportError {
            failure = ESheepCloudSyncFailure.classify(transportError)
        } else if cycleCompleted {
            failure = nil
        }
        lastErrorMessage = failure?.localizedDescription
        if authenticationRequired || failure?.kind == .authentication {
            presentation = .reauthenticationRequired
        } else if snapshot.attentionCount > 0 {
            presentation = .needsConfirmation(snapshot.attentionCount)
        } else if snapshot.activityState == .accessRevoked {
            presentation = .reauthenticationRequired
        } else if snapshot.activityState == .integrityHold ||
                    snapshot.rejectedCount > 0 ||
                    snapshot.integrityState == .failed ||
                    snapshot.failedAssetCount > 0 {
            presentation = .partiallyUnsaved
        } else if snapshot.activityState == .preparing {
            presentation = .preparing
        } else if let failure {
            presentation = failure.kind == .network
                ? .offline(snapshot.pendingCount) : .failed(failure.kind)
        } else if snapshot.pendingAssetCount > 0 {
            presentation = .saving(snapshot.pendingAssetCount)
        } else if snapshot.pendingCount > 0 {
            presentation = .saving(snapshot.pendingCount)
        } else if snapshot.activityState == .active,
                  snapshot.integrityState == .passed,
                  snapshot.lastAppliedEventSequence >= snapshot.cloudHead,
                  snapshot.lastSafeSaveAt != nil {
            presentation = .safelySaved
        } else {
            presentation = .checking
        }
    }
}

/// Serial background boundary for SwiftData. Contexts and managed models never
/// leave this actor; the UI receives immutable cycle summaries only.
actor ESheepCloudLocalStore {
    private let container: ModelContainer
    private let historyRebuilder = FarmHistoryRebuilder()

    init(container: ModelContainer) {
        self.container = container
    }

    func beginAttentionResolution(
        attentionID: UUID,
        choice: ESheepCloudAttentionResolutionChoiceV2,
        farmID: UUID,
        accountID: UUID,
        deviceID: UUID,
        now: Date = .now
    ) throws -> ESheepCloudAttentionResolutionV2 {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let state = try activeFarmState(farmID: farmID, context: context) else {
            throw ESheepCloudCoreError.farmStateMissing
        }
        var attentionQuery = FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
            $0.id == attentionID && $0.farmID == farmID
        })
        attentionQuery.fetchLimit = 1
        guard let item = try context.fetch(attentionQuery).first else {
            throw ESheepCloudCoreError.attentionMissing
        }
        if item.state == .resolving {
            guard item.resolutionRawValue == choice.rawValue,
                  item.resolverAccountID == accountID,
                  item.resolverDeviceID == deviceID else {
                throw ESheepCloudCoreError.attentionAlreadyResolving
            }
            return try pendingResolution(from: item)
        }
        guard item.state == .open,
              item.farmGeneration == state.farmGeneration else {
            throw ESheepCloudCoreError.attentionNoLongerOpen
        }

        let cloudValue = try ESheepCloudCanonicalCodec.decode(
            ESheepCloudValueV2.self,
            from: item.cloudValueData
        )
        let resolutionCommandID = UUID()
        let deviceSequence = try FarmStorageRouter.takeNextOperationSequence(
            farmID: farmID,
            operationID: resolutionCommandID,
            context: context
        )
        item.state = .resolving
        item.resolutionRawValue = choice.rawValue
        item.resolutionCommandID = resolutionCommandID
        item.resolutionExpectedCloudValueDigest = cloudValue.digest
        item.resolverAccountID = accountID
        item.resolverDeviceID = deviceID
        item.resolutionDeviceSequence = deviceSequence
        item.resolutionAttemptCount = 0
        item.resolutionAwaitingStatus = false
        item.resolutionNextRetryAt = nil
        item.resolutionLastErrorMessage = nil
        item.resolutionStartedAt = now
        try context.save()
        return try pendingResolution(from: item)
    }

    func markAttentionResolutionAttempted(
        commandID: UUID,
        now: Date = .now
    ) throws {
        let context = ModelContext(container)
        guard let item = try attentionItem(
            resolutionCommandID: commandID,
            context: context
        ), item.state == .resolving else {
            throw ESheepCloudCoreError.attentionNoLongerOpen
        }
        item.resolutionAttemptCount += 1
        item.resolutionAwaitingStatus = false
        item.resolutionNextRetryAt = nil
        item.resolutionLastErrorMessage = nil
        item.updatedAt = now
        try context.save()
    }

    func markAttentionResolutionTransportUncertain(
        commandID: UUID,
        message: String,
        failure: ESheepCloudSyncFailure? = nil,
        now: Date = .now
    ) throws {
        let context = ModelContext(container)
        guard let item = try attentionItem(
            resolutionCommandID: commandID,
            context: context
        ), item.state == .resolving else { return }
        item.resolutionAwaitingStatus = true
        item.resolutionLastErrorMessage = message
        item.resolutionNextRetryAt = retryDate(
            attemptCount: max(1, item.resolutionAttemptCount),
            now: now, failure: failure
        )
        try context.save()
    }

    func markAttentionResolutionStatusQueryFailed(
        commandIDs: [UUID],
        message: String,
        failure: ESheepCloudSyncFailure? = nil,
        now: Date = .now
    ) throws {
        let context = ModelContext(container)
        let idSet = Set(commandIDs)
        for item in try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
            $0.stateRawValue == "resolving"
        }))
            where item.state == .resolving &&
                item.resolutionCommandID.map(idSet.contains) == true {
            item.resolutionLastErrorMessage = message
            item.resolutionNextRetryAt = retryDate(
                attemptCount: max(1, item.resolutionAttemptCount),
                now: now, failure: failure
            )
        }
        try context.save()
    }

    func markUnknownAttentionResolutionsReadyToRetry(
        _ commandIDs: [UUID]
    ) throws {
        let context = ModelContext(container)
        let idSet = Set(commandIDs)
        for item in try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
            $0.stateRawValue == "resolving"
        }))
            where item.state == .resolving &&
                item.resolutionCommandID.map(idSet.contains) == true {
            item.resolutionAwaitingStatus = false
            item.resolutionNextRetryAt = nil
            item.resolutionLastErrorMessage = nil
        }
        try context.save()
    }

    func prepareCycle(
        farmID: UUID,
        accountID: UUID,
        now: Date = .now,
        commandLimit: Int = 25,
        forceRetry: Bool = false
    ) throws -> ESheepCloudLocalCycleSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard try activeFarmState(farmID: farmID, context: context) != nil else {
            throw ESheepCloudCoreError.farmStateMissing
        }
        do {
            if forceRetry {
                for intent in try intents(farmID: farmID, context: context)
                    where intent.accountID == accountID && !intent.lifecycle.isTerminal && intent.nextRetryAt != nil {
                    intent.nextRetryAt = nil
                }
                let resolving = try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
                    $0.farmID == farmID && $0.resolverAccountID == accountID && $0.stateRawValue == "resolving"
                }))
                for item in resolving where item.resolutionNextRetryAt != nil { item.resolutionNextRetryAt = nil }
            }
            for intent in try intents(farmID: farmID, context: context)
                where intent.lifecycle == .sending {
                // A process can die after bytes left the phone. Never generate a
                // replacement command; query the immutable command ID first.
                intent.lifecycle = .awaitingResult
            }
            try ESheepCloudIntentWriter.refreshReadiness(
                farmID: farmID,
                now: now,
                context: context
            )
            try context.save()
            return try snapshot(
                farmID: farmID,
                accountID: accountID,
                now: now,
                commandLimit: commandLimit,
                context: context
            )
        } catch {
            context.rollback()
            try? markLocalIntegrityFailure(
                farmID: farmID,
                traceID: UUID().uuidString.lowercased()
            )
            throw error
        }
    }

    func applyCloudStatus(
        _ status: ESheepCloudStatusV2,
        accountID: UUID,
        contextDate: Date = .now
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let state = try activeFarmState(farmID: status.farmID, context: context) else {
            throw ESheepCloudCoreError.farmStateMissing
        }
        guard state.farmGeneration == status.farmGeneration else {
            throw ESheepCloudCoreError.farmGenerationChanged
        }
        guard status.v2Ready else {
            throw ESheepCloudCoreError.applicationUpdateRequired
        }
        if status.cloudHead > state.cloudEventHead { state.cloudEventHead = status.cloudHead }
        if status.writeFrozen {
            state.activityState = .integrityHold
            state.integrityFailureTraceID = status.writeFreezeTraceID
            state.lastSafeSaveAt = nil
        }
        try upsertAttentionItemsFromStatus(
            status.attentionItems,
            farmID: status.farmID,
            generation: status.farmGeneration,
            accountID: accountID,
            context: context
        )
        if context.hasChanges {
            state.updatedAt = contextDate
            try context.save()
        }
        if status.writeFrozen {
            throw ESheepCloudCoreError.cloudWriteFrozen(
                traceID: status.writeFreezeTraceID
            )
        }
    }

    @discardableResult
    func applyEventPage(
        _ page: ESheepCloudEventPageV2,
        farmID: UUID,
        farmGeneration: Int
    ) throws -> Int {
        let phase = ESheepCloudDiagnostics.Phase(page.events.isEmpty ? "empty-page" : "incremental-page")
        defer { phase.end(items: page.events.count, fullTableReads: page.events.isEmpty ? 0 : -1) }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let state = try activeFarmState(farmID: farmID, context: context),
              state.farmGeneration == farmGeneration else {
            throw ESheepCloudCoreError.farmGenerationChanged
        }
        // An empty response is the normal steady-state case. Do not construct
        // replay indexes or materialize any business/receipt table here.
        if page.events.isEmpty {
            guard !page.hasMore, page.cloudHead >= state.lastAppliedEventSequence else {
                throw ESheepCloudProjectionError.streamDigestMismatch
            }
            if page.cloudHead > state.cloudEventHead {
                state.cloudEventHead = page.cloudHead
                try context.save()
            }
            return 0
        }
        var earliestHistoryChange: Date?
        let replayContext = ESheepCloudProjectionReplayContext(bulkReplay: false)
        let domainApplyService = RemoteDomainApplyService()
        do {
            for event in page.events {
                let outcome = try ESheepCloudEventReducer.apply(
                    event,
                    context: context,
                    savesChanges: false,
                    replayContext: replayContext,
                    domainApplyService: domainApplyService
                )
                if let changedAt = outcome.historyChangedAt {
                    earliestHistoryChange = min(
                        earliestHistoryChange ?? changedAt,
                        changedAt
                    )
                }
            }
            replayContext.registerInsertedModels(in: context)
            domainApplyService.rebuildPendingReplayIndex(in: context)
            state.cloudEventHead = max(state.cloudEventHead, page.cloudHead)
            try finalizeAcceptedIntents(farmID: farmID, context: context)
            if let earliestHistoryChange {
                try historyRebuilder.rebuild(
                    farmID: farmID,
                    context: context,
                    from: earliestHistoryChange
                )
            }
            try context.save()
            return page.events.count
        } catch {
            let traceID = UUID().uuidString.lowercased()
            try ESheepCloudEventReducer.markIntegrityFailure(
                farmID: farmID,
                farmGeneration: farmGeneration,
                traceID: traceID,
                context: context
            )
            throw error
        }
    }

    func markSending(
        commandIDs: [UUID],
        attemptedAt: Date = .now
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let idSet = Set(commandIDs)
        let selected = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            commandIDs.contains($0.id)
        }))
        guard selected.count == idSet.count,
              selected.allSatisfy({ $0.lifecycle == .ready }) else {
            throw ESheepCloudContractError.malformedPayload
        }
        for intent in selected {
            intent.lifecycle = .sending
            intent.firstAttemptAt = intent.firstAttemptAt ?? attemptedAt
            intent.lastAttemptAt = attemptedAt
            intent.attemptCount += 1
            intent.nextRetryAt = nil
            intent.lastTransportMessage = nil
        }
        try context.save()
    }

    func markTransportUncertain(
        commandIDs: [UUID],
        message: String,
        failure: ESheepCloudSyncFailure? = nil,
        now: Date = .now
    ) throws {
        let context = ModelContext(container)
        let idSet = Set(commandIDs)
        for intent in try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            commandIDs.contains($0.id)
        }))
            where idSet.contains(intent.id) && (intent.lifecycle == .sending ||
                (intent.lifecycle == .awaitingResult && intent.acceptedEventSequence == nil)) {
            intent.lifecycle = .awaitingResult
            intent.lastTransportMessage = message
            intent.nextRetryAt = retryDate(attemptCount: intent.attemptCount, now: now, failure: failure)
        }
        try context.save()
    }

    func markStatusQueryFailed(
        commandIDs: [UUID],
        message: String,
        failure: ESheepCloudSyncFailure? = nil,
        now: Date = .now
    ) throws {
        let context = ModelContext(container)
        let idSet = Set(commandIDs)
        for intent in try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            commandIDs.contains($0.id)
        }))
            where idSet.contains(intent.id) && intent.lifecycle == .awaitingResult {
            intent.lastTransportMessage = message
            intent.nextRetryAt = retryDate(
                attemptCount: max(1, intent.attemptCount),
                now: now, failure: failure
            )
        }
        try context.save()
    }

    /// A missing status row proves the server has not durably accepted this
    /// command ID. The same immutable bytes may therefore be submitted again.
    func markUnknownCommandsReadyToRetry(_ commandIDs: [UUID]) throws {
        let context = ModelContext(container)
        let idSet = Set(commandIDs)
        for intent in try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            commandIDs.contains($0.id)
        }))
            where idSet.contains(intent.id) && intent.lifecycle == .awaitingResult {
            intent.lifecycle = .ready
            intent.nextRetryAt = nil
            intent.lastTransportMessage = nil
        }
        try context.save()
    }

    func recordCommandResults(
        _ results: [UUID: ESheepCloudCommandResultV2],
        farmID: UUID,
        farmGeneration: Int
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let state = try activeFarmState(farmID: farmID, context: context),
              state.farmGeneration == farmGeneration else {
            throw ESheepCloudCoreError.farmGenerationChanged
        }
        for (commandID, result) in results {
            guard let intent = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
                $0.id == commandID && $0.farmID == farmID
            })).first else {
                // Results for commands authored elsewhere are delivered via
                // events; they are not local pending intents.
                continue
            }
            let acknowledgedEvents: [ESheepCloudEventEnvelopeV2]
            let acknowledgedHead: Int64
            switch result {
            case .accepted(let events, let head):
                acknowledgedEvents = events; acknowledgedHead = head
            case .duplicate(let original):
                guard original.commandID == commandID else { throw ESheepCloudContractError.malformedPayload }
                acknowledgedEvents = original.events; acknowledgedHead = original.cloudHead
            case .needsConfirmation(_, let events, let head):
                acknowledgedEvents = events; acknowledgedHead = head
            case .rejected:
                acknowledgedEvents = []; acknowledgedHead = 0
            }
            let originalCommandDigest = intent.commandDigest.lowercased()
            guard acknowledgedEvents.allSatisfy({
                $0.commandID == commandID && $0.farmID == farmID && $0.farmGeneration == farmGeneration &&
                $0.eventSequence <= acknowledgedHead && $0.sourceCommandDigest.lowercased() == originalCommandDigest
            }) else { throw ESheepCloudContractError.malformedPayload }
            intent.serverResultData = try ESheepCloudCanonicalCodec.encode(result)
            switch result {
            case .accepted(let events, let cloudHead):
                state.cloudEventHead = max(state.cloudEventHead, cloudHead)
                intent.acceptedEventSequence = events.map(\.eventSequence).max()
                intent.lifecycle = events.isEmpty ? .accepted : .awaitingResult

            case .duplicate(let original):
                state.cloudEventHead = max(state.cloudEventHead, original.cloudHead)
                if let attention = original.attention {
                    try ESheepCloudEventReducer.recordAttentionItems(
                        [attention],
                        result: result,
                        farmID: farmID,
                        farmGeneration: farmGeneration,
                        context: context
                    )
                } else if original.rejection != nil {
                    intent.lifecycle = .rejected
                } else {
                    intent.acceptedEventSequence = original.events.map(\.eventSequence).max()
                    intent.lifecycle = original.events.isEmpty ? .accepted : .awaitingResult
                }

            case .needsConfirmation(let items, let acceptedEvents, let cloudHead):
                state.cloudEventHead = max(state.cloudEventHead, cloudHead)
                intent.acceptedEventSequence = acceptedEvents.map(\.eventSequence).max()
                try ESheepCloudEventReducer.recordAttentionItems(
                    items,
                    result: result,
                    farmID: farmID,
                    farmGeneration: farmGeneration,
                    context: context
                )

            case .rejected(let reason):
                switch reason {
                case .resourceUnavailable, .prerequisiteRejected:
                    // These are transient dependency races, not business
                    // rejections. Preserve the immutable command and retry it
                    // with the same ID after the server-side prerequisite is
                    // observable.
                    intent.lifecycle = .waitingForDependency
                    intent.nextRetryAt = Date.now.addingTimeInterval(5)
                case .authenticationRequired, .farmGenerationChanged,
                     .integrityHold:
                    intent.lifecycle = .waitingForNetwork
                    intent.nextRetryAt = Date.now.addingTimeInterval(30)
                case .permissionDenied, .applicationUpdateRequired,
                     .businessRule, .malformedCommand:
                    intent.lifecycle = .rejected
                }
            }
            // Commit each acknowledged command independently. A later malformed
            // item or interrupted batch cannot erase already persisted results.
            try context.save()
        }
        try finalizeAcceptedIntents(farmID: farmID, context: context)
        try context.save()
    }

    func recordAttentionResolutionResults(
        _ results: [UUID: ESheepCloudCommandResultV2],
        now: Date = .now
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for (commandID, result) in results {
            guard let item = try attentionItem(
                resolutionCommandID: commandID,
                context: context
            ), item.state == .resolving else { continue }
            item.resolutionServerResultData = try ESheepCloudCanonicalCodec.encode(result)
            item.resolutionAwaitingStatus = false
            item.resolutionNextRetryAt = nil
            item.resolutionLastErrorMessage = nil
            switch result {
            case .accepted, .duplicate:
                // The decision is only complete after its authoritative event
                // is pulled and reduced. Keep the visible item in "resolving".
                break

            case .needsConfirmation:
                throw ESheepCloudContractError.malformedPayload

            case .rejected(let reason):
                switch reason {
                case .businessRule(let code, let explanation, _):
                    item.resolutionLastErrorMessage = explanation
                    switch code {
                    case "attention_already_resolved", "attention_no_longer_needed":
                        item.state = .obsolete
                        item.resolutionAwaitingStatus = false
                    case "attention_busy":
                        item.resolutionNextRetryAt = now.addingTimeInterval(5)
                    default:
                        resetPendingResolution(item, preserving: explanation)
                    }
                case .authenticationRequired:
                    item.resolutionLastErrorMessage = "账号登录已经失效，请重新登录。"
                    item.resolutionNextRetryAt = now.addingTimeInterval(30)
                case .farmGenerationChanged:
                    item.resolutionLastErrorMessage = "牧场云端身份已经更新。"
                    item.resolutionNextRetryAt = now.addingTimeInterval(30)
                case .integrityHold:
                    item.resolutionLastErrorMessage = "eSheep+ 云正在保护这座牧场的数据。"
                    item.resolutionNextRetryAt = now.addingTimeInterval(30)
                case .resourceUnavailable, .prerequisiteRejected:
                    item.resolutionNextRetryAt = now.addingTimeInterval(5)
                case .permissionDenied, .applicationUpdateRequired,
                     .malformedCommand:
                    resetPendingResolution(item, preserving: reason.localizedMessage)
                }
            }
        }
        try context.save()
    }

    func finishCycle(
        farmID: UUID,
        accountID: UUID,
        now: Date = .now
    ) throws -> ESheepCloudLocalCycleSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let state = try activeFarmState(farmID: farmID, context: context) else {
            throw ESheepCloudCoreError.farmStateMissing
        }
        do {
            try finalizeAcceptedIntents(farmID: farmID, context: context)
            try ESheepCloudIntentWriter.refreshReadiness(
                farmID: farmID,
                now: now,
                context: context
            )
            var value = try snapshot(
                farmID: farmID,
                accountID: accountID,
                now: now,
                commandLimit: 25,
                context: context
            )
            let safelyCaughtUp = value.lastAppliedEventSequence >= value.cloudHead
            // An open attention item is part of `pendingCount`, but is not a
            // task the engine may silently complete.  Comparing the two
            // counts used to make `pendingCount == attentionCount` look like
            // an idle cycle and stamped `lastSafeSaveAt` while a user still
            // had to choose between two values.  Safe save is a business
            // promise: every pending intent and every attention item must be
            // gone, not merely absent from the transport queues.
            let noImmediateWork = value.readyCommands.isEmpty &&
                value.commandsAwaitingStatus.isEmpty &&
                value.readyAttentionResolutions.isEmpty &&
                value.attentionResolutionsAwaitingStatus.isEmpty &&
                value.pendingCount == 0 &&
                value.attentionCount == 0 &&
                value.pendingAssetCount == 0 &&
                value.failedAssetCount == 0
            if safelyCaughtUp,
               noImmediateWork,
               value.rejectedCount == 0,
               value.integrityState == .passed {
                if state.lastSafeSaveAt == nil ||
                    state.lastVerifiedEventSequence != state.lastAppliedEventSequence {
                    state.lastSafeSaveAt = now
                }
                if state.lastVerifiedEventSequence != state.lastAppliedEventSequence {
                    state.lastVerifiedEventSequence = state.lastAppliedEventSequence
                }
                if context.hasChanges { try context.save() }
                value = try snapshot(
                    farmID: farmID,
                    accountID: accountID,
                    now: now,
                    commandLimit: 25,
                    context: context
                )
            } else if state.lastSafeSaveAt != nil {
                state.lastSafeSaveAt = nil
                try context.save()
            }
            return value
        } catch {
            context.rollback()
            try? markLocalIntegrityFailure(
                farmID: farmID,
                traceID: UUID().uuidString.lowercased()
            )
            throw error
        }
    }

    private func markLocalIntegrityFailure(
        farmID: UUID,
        traceID: String
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let state = try activeFarmState(farmID: farmID, context: context) else {
            return
        }
        state.activityState = .integrityHold
        state.integrityState = .failed
        state.integrityFailureTraceID = traceID
        state.lastSafeSaveAt = nil
        try context.save()
    }

    private func snapshot(
        farmID: UUID,
        accountID: UUID,
        now: Date,
        commandLimit: Int,
        context: ModelContext
    ) throws -> ESheepCloudLocalCycleSnapshot {
        guard let state = try activeFarmState(farmID: farmID, context: context) else {
            throw ESheepCloudCoreError.farmStateMissing
        }
        let farmIntents = try intents(farmID: farmID, context: context)
        let readyModels = farmIntents
            .filter {
                $0.accountID == accountID &&
                $0.farmGeneration == state.farmGeneration &&
                $0.lifecycle == .ready
            }
            .sorted {
                if $0.deviceSequence != $1.deviceSequence {
                    return $0.deviceSequence < $1.deviceSequence
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(max(1, min(25, commandLimit)))
        let ready = try readyModels.map {
            let envelope = try ESheepCloudCanonicalCodec.decode(
                ESheepCloudCommandEnvelopeV2.self,
                from: $0.commandEnvelopeData
            )
            try envelope.validateDigest()
            guard envelope.commandID == $0.id,
                  envelope.contentDigest == $0.commandDigest,
                  envelope.accountID == accountID,
                  envelope.farmGeneration == state.farmGeneration else {
                throw ESheepCloudContractError.invalidCommandDigest
            }
            return envelope
        }
        let awaiting = farmIntents
            .filter {
                $0.accountID == accountID &&
                $0.farmGeneration == state.farmGeneration &&
                $0.lifecycle == .awaitingResult &&
                ($0.nextRetryAt == nil || $0.nextRetryAt! <= now)
            }
            .sorted { $0.deviceSequence < $1.deviceSequence }
            .prefix(25)
            .map(\.id)
        let generation = state.farmGeneration
        let farmAttention = try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation &&
                ($0.stateRawValue == "open" || $0.stateRawValue == "resolving")
        }))
        let openAttention = farmAttention.filter { $0.state == .open }
        let resolvingAttention = farmAttention.filter {
            $0.state == .resolving && $0.resolverAccountID == accountID
        }
        let readyResolutions = try resolvingAttention
            .filter {
                !$0.resolutionAwaitingStatus &&
                ($0.resolutionNextRetryAt == nil || $0.resolutionNextRetryAt! <= now)
            }
            .sorted {
                ($0.resolutionDeviceSequence ?? .max) <
                    ($1.resolutionDeviceSequence ?? .max)
            }
            .prefix(max(1, min(25, commandLimit)))
            .map(pendingResolution(from:))
        let awaitingResolutions = resolvingAttention
            .filter {
                $0.resolutionAwaitingStatus &&
                ($0.resolutionNextRetryAt == nil || $0.resolutionNextRetryAt! <= now)
            }
            .compactMap(\.resolutionCommandID)
        let accountIntents = farmIntents.filter { $0.accountID == accountID }
        let assetStates = try context.fetch(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        }))
        let pendingAssetCount = assetStates.count { asset in
            [asset.thumbnailStateRawValue, asset.avatarStateRawValue, asset.originalStateRawValue]
                .contains { rawValue in
                    guard let transferState = ESheepCloudAssetTransferState(rawValue: rawValue) else {
                        // Unknown transfer states fail closed and stay visible
                        // as unfinished work instead of being silently ignored.
                        return true
                    }
                    return transferState == .localOnly ||
                        transferState == .queued ||
                        transferState == .transferring ||
                        transferState == .failed
                }
        }
        let failedAssetCount = assetStates.reduce(into: 0) { total, asset in
            let states = [asset.thumbnailStateRawValue, asset.avatarStateRawValue, asset.originalStateRawValue]
            if states.contains(where: { $0 == ESheepCloudAssetTransferState.failed.rawValue }) {
                total += 1
            }
        }
        let pending = accountIntents.filter {
            !$0.lifecycle.isTerminal && $0.lifecycle != .needsConfirmation
        }.count + openAttention.count + resolvingAttention.count
        return ESheepCloudLocalCycleSnapshot(
            farmGeneration: state.farmGeneration,
            lastAppliedEventSequence: state.lastAppliedEventSequence,
            cloudHead: state.cloudEventHead,
            readyCommands: ready,
            commandsAwaitingStatus: Array(awaiting),
            readyAttentionResolutions: Array(readyResolutions),
            attentionResolutionsAwaitingStatus: awaitingResolutions,
            pendingCount: pending,
            attentionCount: openAttention.count,
            rejectedCount: accountIntents.filter { $0.lifecycle == .rejected }.count,
            integrityState: state.integrityState,
            activityState: state.activityState,
            lastSafeSaveAt: state.lastSafeSaveAt,
            pendingAssetCount: pendingAssetCount,
            failedAssetCount: failedAssetCount
        )
    }

    private func finalizeAcceptedIntents(
        farmID: UUID,
        context: ModelContext
    ) throws {
        guard let state = try activeFarmState(farmID: farmID, context: context) else {
            return
        }
        for intent in try intents(farmID: farmID, context: context) {
            guard intent.lifecycle == .awaitingResult,
                  let accepted = intent.acceptedEventSequence,
                  accepted <= state.lastAppliedEventSequence else { continue }
            let commandID = intent.id
            var descriptor = FetchDescriptor<ESheepCloudEventReceipt>(predicate: #Predicate {
                $0.farmID == farmID && $0.commandID == commandID
            })
            descriptor.fetchLimit = 1
            if try context.fetch(descriptor).isEmpty {
                let generation = state.farmGeneration
                let anchors = try context.fetch(FetchDescriptor<ESheepCloudCheckpointState>(predicate: #Predicate {
                    $0.farmID == farmID && $0.farmGeneration == generation
                }))
                guard intent.serverResultData != nil,
                      anchors.contains(where: { $0.stateRawValue == "active" &&
                          $0.accountID == intent.accountID && $0.boundaryEventSequence >= accepted }) else { continue }
            }
            intent.lifecycle = .accepted
        }
    }

    private func upsertAttentionItemsFromStatus(
        _ values: [ESheepCloudAttentionPayloadV2],
        farmID: UUID,
        generation: Int,
        accountID: UUID,
        context: ModelContext
    ) throws {
        _ = accountID
        for value in values {
            let placeholder = ESheepCloudCommandResultV2.needsConfirmation(
                items: [value],
                acceptedEvents: [],
                cloudHead: 0
            )
            try ESheepCloudEventReducer.recordAttentionItems(
                [value],
                result: placeholder,
                farmID: farmID,
                farmGeneration: generation,
                requiresLocalIntent: false,
                context: context
            )
        }
        let remoteIDs = Set(values.map(\.id))
        let remoteCommandIDs = Set(values.map(\.commandID))
        let attentionQuery = FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation &&
                ($0.stateRawValue == "open" || $0.stateRawValue == "resolving")
        })
        for item in try context.fetch(attentionQuery) where !remoteIDs.contains(item.id) {
            item.state = .obsolete
            item.resolutionAwaitingStatus = false
            item.resolutionNextRetryAt = nil
            if !remoteCommandIDs.contains(item.commandID) {
                let commandID = item.commandID
                var intentQuery = FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
                    $0.id == commandID && $0.lifecycleRawValue == "needsConfirmation"
                })
                intentQuery.fetchLimit = 1
                if let source = try context.fetch(intentQuery).first {
                    source.lifecycle = .supersededLocally
                }
            }
        }
    }

    private func activeFarmState(
        farmID: UUID,
        context: ModelContext
    ) throws -> ESheepCloudFarmState? {
        var query = FetchDescriptor<ESheepCloudFarmState>(
            predicate: #Predicate { $0.farmID == farmID && $0.activityStateRawValue != "accessRevoked" },
            sortBy: [SortDescriptor(\.farmGeneration, order: .reverse)])
        query.fetchLimit = 1
        return try context.fetch(query).first
    }

    private func intents(
        farmID: UUID,
        context: ModelContext
    ) throws -> [ESheepCloudPendingIntent] {
        try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && $0.lifecycleRawValue != "accepted" && $0.lifecycleRawValue != "supersededLocally"
        }))
    }

    private func pendingResolution(
        from item: ESheepCloudAttentionItem
    ) throws -> ESheepCloudAttentionResolutionV2 {
        guard item.state == .resolving,
              let commandID = item.resolutionCommandID,
              let choiceRawValue = item.resolutionRawValue,
              let choice = ESheepCloudAttentionResolutionChoiceV2(rawValue: choiceRawValue),
              let expectedDigest = item.resolutionExpectedCloudValueDigest,
              expectedDigest.isSHA256Hex,
              let accountID = item.resolverAccountID,
              let deviceID = item.resolverDeviceID,
              let deviceSequence = item.resolutionDeviceSequence,
              deviceSequence > 0 else {
            throw ESheepCloudContractError.malformedPayload
        }
        return ESheepCloudAttentionResolutionV2(
            attentionID: item.id,
            resolutionCommandID: commandID,
            choice: choice,
            expectedCloudValueDigest: expectedDigest,
            farmGeneration: item.farmGeneration,
            accountID: accountID,
            deviceID: deviceID,
            deviceSequence: deviceSequence,
            deviceSignature: Data()
        )
    }

    private func attentionItem(
        resolutionCommandID: UUID,
        context: ModelContext
    ) throws -> ESheepCloudAttentionItem? {
        try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
            $0.resolutionCommandID == resolutionCommandID
        })).first
    }

    private func resetPendingResolution(
        _ item: ESheepCloudAttentionItem,
        preserving message: String?
    ) {
        item.state = .open
        item.resolutionRawValue = nil
        item.resolutionCommandID = nil
        item.resolutionExpectedCloudValueDigest = nil
        item.resolverAccountID = nil
        item.resolverDeviceID = nil
        item.resolutionDeviceSequence = nil
        item.resolutionAttemptCount = 0
        item.resolutionAwaitingStatus = false
        item.resolutionNextRetryAt = nil
        item.resolutionStartedAt = nil
        item.resolutionLastErrorMessage = message
    }

    private func retryDate(attemptCount: Int, now: Date, failure: ESheepCloudSyncFailure? = nil) -> Date {
        if let failure { return now.addingTimeInterval(failure.retryDelay(attempt: attemptCount)) }
        let exponent = min(9, max(0, attemptCount - 1))
        let base = pow(2.0, Double(exponent)) * 2.0
        let jitter = Double.random(in: 0.8...1.2)
        return now.addingTimeInterval(min(300, base * jitter))
    }
}

/// One serial engine per farm. Correctness comes from server transactions,
/// immutable IDs and event receipts, not from depending on upload-before-pull.
actor ESheepCloudCore {
    private let farmID: UUID
    private let accountID: UUID
    private let gateway: any ESheepCloudGateway
    private let localStore: ESheepCloudLocalStore
    private let checkpointMaintenance: ESheepCloudCheckpointMaintenance
    private var maintainedCompletedReceive = false
    private let checkpointBusinessHistory: ESheepCloudCheckpointBusinessHistory
    private var restoredBusinessHistory = false
    private var businessHistoryRetryAfter: Date?
    private let assetCoordinator: ESheepCloudAssetCoordinator?
    private let deviceIdentity: DeviceIdentityActor
    private let viewState: ESheepCloudViewState
    private var activeCycle: Task<ESheepCloudSyncCycleReport, Error>?
    private var wakePending = false
    private var wakeForceRetry = false
    private var lastReport: ESheepCloudSyncCycleReport?
    private var lastFailure: ESheepCloudSyncFailure?
    private var nextCycleAt: Date?
    private var consecutiveFailures = 0

    @MainActor
    init(
        farmID: UUID,
        accountID: UUID,
        container: ModelContainer,
        gateway: any ESheepCloudGateway,
        assetTransport: (any ESheepCloudAssetTransferTransport)? = nil,
        deviceIdentity: DeviceIdentityActor = .shared,
        viewState: ESheepCloudViewState
    ) {
        self.farmID = farmID
        self.accountID = accountID
        self.gateway = gateway
        self.localStore = ESheepCloudLocalStore(container: container)
        self.checkpointBusinessHistory = ESheepCloudCheckpointBusinessHistory(container: container)
        self.checkpointMaintenance = ESheepCloudCheckpointMaintenance(container: container,
            support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        self.assetCoordinator = assetTransport.map {
            ESheepCloudAssetCoordinator(
                container: container,
                gateway: gateway,
                transport: $0
            )
        }
        self.deviceIdentity = deviceIdentity
        self.viewState = viewState
    }

    @discardableResult
    func resolveAttention(
        id: UUID,
        choice: ESheepCloudAttentionResolutionChoiceV2
    ) async throws -> ESheepCloudSyncCycleReport {
        let identity = try await deviceIdentity.identity()
        _ = try await localStore.beginAttentionResolution(
            attentionID: id,
            choice: choice,
            farmID: farmID,
            accountID: accountID,
            deviceID: identity.deviceID
        )
        return try await synchronize()
    }

    func synchronize(maxCommands: Int = 25, force: Bool = false) async throws -> ESheepCloudSyncCycleReport {
        // Reentrant callers join one task; they must never "prepare" another
        // cycle and change sending intents while the first request is in flight.
        if let activeCycle {
            wakePending = true
            wakeForceRetry = wakeForceRetry || force
            return try await activeCycle.value
        }
        if !force, let nextCycleAt, nextCycleAt > .now, let lastFailure {
            throw lastFailure
        }
        let task = Task {
            var result = try await self.runCycle(maxCommands: maxCommands, forceRetry: force)
            // All notifications arriving during a request collapse into one
            // follow-up cycle, so a just-entered command is not missed.
            if self.wakePending {
                let retry = self.wakeForceRetry
                self.wakePending = false
                self.wakeForceRetry = false
                let next = try await self.runCycle(maxCommands: maxCommands, forceRetry: retry)
                result = ESheepCloudSyncCycleReport(pulledEventCount: result.pulledEventCount + next.pulledEventCount,
                    submittedCommandCount: result.submittedCommandCount + next.submittedCommandCount,
                    queriedCommandCount: result.queriedCommandCount + next.queriedCommandCount,
                    pendingCount: next.pendingCount, attentionCount: next.attentionCount, safelySavedAt: next.safelySavedAt)
            }
            return result
        }
        activeCycle = task
        defer { activeCycle = nil }
        do {
            let value = try await task.value
            lastReport = value
            lastFailure = nil
            nextCycleAt = nil
            consecutiveFailures = 0
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = ESheepCloudSyncFailure.classify(error)
            consecutiveFailures += 1
            nextCycleAt = Date.now.addingTimeInterval(failure.retryDelay(attempt: consecutiveFailures))
            lastFailure = failure
            throw failure
        }
    }

    private func runCycle(maxCommands: Int, forceRetry: Bool) async throws -> ESheepCloudSyncCycleReport {
        let phase = ESheepCloudDiagnostics.Phase("sync-cycle")
        defer { phase.end() }
        var snapshot = try await localStore.prepareCycle(
            farmID: farmID,
            accountID: accountID,
            commandLimit: maxCommands, forceRetry: forceRetry
        )
        await viewState.update(from: snapshot)
        do {
            let identity = try await deviceIdentity.identity()
            let status = try await gateway.fetchCloudStatus(farmID: farmID)
            try await localStore.applyCloudStatus(status, accountID: accountID)
            guard status.farmGeneration == snapshot.farmGeneration else {
                throw ESheepCloudCoreError.farmGenerationChanged
            }

            var pulled = try await pullUntilCaughtUp(
                generation: snapshot.farmGeneration,
                after: snapshot.lastAppliedEventSequence
            )
            // Resource verification precedes command readiness. Thumbnail and
            // avatar bytes are prioritized, while an independent failure here
            // cannot block receiving unrelated farm events or business
            // commands. The asset coordinator has already persisted the
            // failed variant and its retry backoff before throwing.
            var assetTransferError: Error?
            do {
                _ = try await assetCoordinator?.processReadyUploads(farmID: farmID)
            } catch {
                assetTransferError = error
            }
            snapshot = try await localStore.prepareCycle(
                farmID: farmID,
                accountID: accountID,
                commandLimit: maxCommands
            )

            var queried = 0
            let intentStatusIDs = snapshot.commandsAwaitingStatus
            let resolutionStatusIDs = snapshot.attentionResolutionsAwaitingStatus
            let statusIDs = Array(Set(intentStatusIDs + resolutionStatusIDs))
            if !statusIDs.isEmpty {
                let statuses: [UUID: ESheepCloudCommandResultV2]
                do {
                    statuses = try await gateway.queryCommandStatus(
                        farmID: farmID,
                        commandIDs: statusIDs
                    )
                } catch {
                    try await localStore.markStatusQueryFailed(
                        commandIDs: intentStatusIDs,
                        message: ESheepCloudSyncFailure.classify(error).localizedDescription,
                        failure: ESheepCloudSyncFailure.classify(error)
                    )
                    try await localStore.markAttentionResolutionStatusQueryFailed(
                        commandIDs: resolutionStatusIDs,
                        message: ESheepCloudSyncFailure.classify(error).localizedDescription,
                        failure: ESheepCloudSyncFailure.classify(error)
                    )
                    throw error
                }
                queried = statusIDs.count
                if !statuses.isEmpty {
                    try await localStore.recordCommandResults(
                        statuses,
                        farmID: farmID,
                        farmGeneration: snapshot.farmGeneration
                    )
                    try await localStore.recordAttentionResolutionResults(statuses)
                    if let controlError = controlPlaneError(in: statuses.values) {
                        throw controlError
                    }
                }
                let missingIntentIDs = intentStatusIDs.filter { statuses[$0] == nil }
                if !missingIntentIDs.isEmpty {
                    try await localStore.markUnknownCommandsReadyToRetry(missingIntentIDs)
                }
                let missingResolutionIDs = resolutionStatusIDs.filter { statuses[$0] == nil }
                if !missingResolutionIDs.isEmpty {
                    try await localStore.markUnknownAttentionResolutionsReadyToRetry(
                        missingResolutionIDs
                    )
                }
            }

            snapshot = try await localStore.prepareCycle(
                farmID: farmID,
                accountID: accountID,
                commandLimit: maxCommands
            )
            var submitted = 0
            for unsignedResolution in snapshot.readyAttentionResolutions {
                guard unsignedResolution.deviceID == identity.deviceID else {
                    throw ESheepCloudCoreError.deviceIdentityChanged
                }
                let resolution = ESheepCloudAttentionResolutionV2(
                    attentionID: unsignedResolution.attentionID,
                    resolutionCommandID: unsignedResolution.resolutionCommandID,
                    choice: unsignedResolution.choice,
                    expectedCloudValueDigest: unsignedResolution.expectedCloudValueDigest,
                    farmGeneration: unsignedResolution.farmGeneration,
                    accountID: unsignedResolution.accountID,
                    deviceID: unsignedResolution.deviceID,
                    deviceSequence: unsignedResolution.deviceSequence,
                    deviceSignature: try await deviceIdentity.sign(
                        unsignedResolution.canonicalSigningData
                    )
                )
                try await localStore.markAttentionResolutionAttempted(
                    commandID: resolution.resolutionCommandID
                )
                let result: ESheepCloudCommandResultV2
                do {
                    result = try await gateway.resolveAttention(
                        farmID: farmID,
                        resolution: resolution
                    )
                    try await localStore.recordAttentionResolutionResults([
                        resolution.resolutionCommandID: result,
                    ])
                } catch {
                    try await localStore.markAttentionResolutionTransportUncertain(
                        commandID: resolution.resolutionCommandID,
                        message: ESheepCloudSyncFailure.classify(error).localizedDescription,
                        failure: ESheepCloudSyncFailure.classify(error)
                    )
                    throw error
                }
                if let controlError = controlPlaneError(
                    in: [resolution.resolutionCommandID: result].values
                ) {
                    throw controlError
                }
                submitted += 1
            }

            snapshot = try await localStore.prepareCycle(
                farmID: farmID,
                accountID: accountID,
                commandLimit: maxCommands
            )
            if !snapshot.readyCommands.isEmpty {
                guard snapshot.readyCommands.allSatisfy({ $0.deviceID == identity.deviceID }) else {
                    throw ESheepCloudCoreError.deviceIdentityChanged
                }
                let commands = try await sign(snapshot.readyCommands)
                let ids = commands.map { $0.command.commandID }
                try await localStore.markSending(commandIDs: ids)
                let results: [UUID: ESheepCloudCommandResultV2]
                do {
                    results = try await gateway.submitCommands(commands)
                    guard Set(results.keys).isSubset(of: Set(ids)) else {
                        throw ESheepCloudContractError.malformedPayload
                    }
                    try await localStore.recordCommandResults(
                        results,
                        farmID: farmID,
                        farmGeneration: snapshot.farmGeneration
                    )
                } catch {
                    try await localStore.markTransportUncertain(
                        commandIDs: ids,
                        message: ESheepCloudSyncFailure.classify(error).localizedDescription,
                        failure: ESheepCloudSyncFailure.classify(error)
                    )
                    throw error
                }
                if let controlError = controlPlaneError(in: results.values) {
                    throw controlError
                }
                let missing = ids.filter { results[$0] == nil }
                if !missing.isEmpty {
                    try await localStore.markTransportUncertain(
                        commandIDs: missing,
                        message: ESheepCloudCoreError.resultMissing(missing[0]).localizedDescription
                    )
                }
                submitted += ids.count
            }

            snapshot = try await localStore.prepareCycle(
                farmID: farmID,
                accountID: accountID,
                commandLimit: maxCommands
            )
            pulled += try await pullUntilCaughtUp(
                generation: snapshot.farmGeneration,
                after: snapshot.lastAppliedEventSequence
            )
            let finished = try await localStore.finishCycle(
                farmID: farmID,
                accountID: accountID
            )
            if !restoredBusinessHistory, finished.pendingCount == 0, finished.attentionCount == 0,
               finished.integrityState == .passed,
               forceRetry || (businessHistoryRetryAfter.map({ $0 <= .now }) ?? true),
               let transport = gateway as? any ESheepCloudCheckpointGateway {
                let history = try await checkpointBusinessHistory.restore(farmID: farmID,
                    accountID: accountID, generation: snapshot.farmGeneration,
                    gateway: gateway, transport: transport)
                restoredBusinessHistory = history.verified
                businessHistoryRetryAfter = history.verified ? nil : Date.now.addingTimeInterval(900)
            }
            if !maintainedCompletedReceive, finished.pendingCount == 0,
               finished.attentionCount == 0, finished.integrityState == .passed,
               !UserDefaults.standard.bool(forKey: "ESheepCloudDisableCheckpointCleanup") {
                _ = try? await checkpointMaintenance.removeCompletedReceiveFiles(farmID: farmID, accountID: accountID)
                maintainedCompletedReceive = true
            }
            await viewState.update(
                from: finished,
                transportError: assetTransferError,
                cycleCompleted: true
            )
            return report(
                from: finished,
                pulled: pulled,
                submitted: submitted,
                queried: queried
            )
        } catch {
            let latest = (try? await localStore.finishCycle(
                farmID: farmID,
                accountID: accountID
            )) ?? snapshot
            let authenticationRequired = isAuthenticationFailure(error)
            await viewState.update(
                from: latest,
                transportError: error,
                authenticationRequired: authenticationRequired
            )
            throw error
        }
    }

    private func pullUntilCaughtUp(
        generation: Int,
        after initialSequence: Int64
    ) async throws -> Int {
        var after = initialSequence
        var count = 0
        while true {
            try Task.checkCancellation()
            let page = try await gateway.pullEvents(
                farmID: farmID,
                farmGeneration: generation,
                after: after,
                limit: 500
            )
            guard page.cloudHead >= after else {
                throw ESheepCloudProjectionError.streamDigestMismatch
            }
            if page.events.isEmpty {
                guard !page.hasMore else {
                    throw ESheepCloudProjectionError.eventSequenceGap(
                        expected: after + 1,
                        received: after
                    )
                }
                _ = try await localStore.applyEventPage(
                    page,
                    farmID: farmID,
                    farmGeneration: generation
                )
                break
            }
            count += try await localStore.applyEventPage(
                page,
                farmID: farmID,
                farmGeneration: generation
            )
            guard let last = page.events.last?.eventSequence, last > after else {
                throw ESheepCloudProjectionError.streamDigestMismatch
            }
            after = last
            if !page.hasMore { break }
        }
        return count
    }

    private func sign(
        _ commands: [ESheepCloudCommandEnvelopeV2]
    ) async throws -> [ESheepCloudSignedCommandV2] {
        var result: [ESheepCloudSignedCommandV2] = []
        result.reserveCapacity(commands.count)
        for command in commands {
            try command.validateDigest()
            result.append(ESheepCloudSignedCommandV2(
                command: command,
                deviceSignature: try await deviceIdentity.sign(command.canonicalSigningData)
            ))
        }
        return result
    }

    private func report(
        from value: ESheepCloudLocalCycleSnapshot,
        pulled: Int,
        submitted: Int,
        queried: Int
    ) -> ESheepCloudSyncCycleReport {
        ESheepCloudSyncCycleReport(
            pulledEventCount: pulled,
            submittedCommandCount: submitted,
            queriedCommandCount: queried,
            pendingCount: value.pendingCount,
            attentionCount: value.attentionCount,
            safelySavedAt: value.lastSafeSaveAt
        )
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("jwt") || text.contains("authentication") || text.contains("登录")
    }

    private func controlPlaneError(
        in results: Dictionary<UUID, ESheepCloudCommandResultV2>.Values
    ) -> Error? {
        for result in results {
            guard case .rejected(let reason) = result else { continue }
            switch reason {
            case .authenticationRequired:
                return ESheepCloudCoreError.reauthenticationRequired
            case .applicationUpdateRequired:
                return ESheepCloudCoreError.applicationUpdateRequired
            case .farmGenerationChanged:
                return ESheepCloudCoreError.farmGenerationChanged
            case .integrityHold(let traceID):
                return ESheepCloudCoreError.cloudWriteFrozen(traceID: traceID)
            case .permissionDenied, .prerequisiteRejected,
                 .resourceUnavailable, .businessRule, .malformedCommand:
                continue
            }
        }
        return nil
    }
}

private extension String {
    var isSHA256Hex: Bool {
        range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

private extension ESheepCloudRejectionReasonV2 {
    var localizedMessage: String {
        switch self {
        case .authenticationRequired:
            "账号登录已经失效，请重新登录。"
        case .permissionDenied:
            "当前账号没有处理这项内容的权限。"
        case .applicationUpdateRequired:
            "需要更新 eSheep+ 后才能继续处理。"
        case .farmGenerationChanged:
            "牧场云端身份已经更新，需要重新接收完整资料。"
        case .prerequisiteRejected:
            "前一步操作尚未完成。"
        case .resourceUnavailable:
            "相关照片仍在安全保存中。"
        case .businessRule(_, let explanation, _):
            explanation
        case .integrityHold:
            "eSheep+ 云正在保护这座牧场的数据。"
        case .malformedCommand(let explanation):
            explanation
        }
    }
}
