import CryptoKit
import Foundation
import SwiftData

/// Per-transaction lookup cache used by a snapshot replay.  The original
/// reducer fetched an entire SwiftData table for every event; at production
/// scale that turns a linear event stream into repeated full-table scans.  The
/// cache is deliberately scoped to one ModelContext and is never shared with
/// live account work or another farm generation.
final class ESheepCloudProjectionReplayContext {
    private let bulkReplay: Bool

    init(bulkReplay: Bool = true) { self.bulkReplay = bulkReplay }

    private struct FarmKey: Hashable {
        let farmID: UUID
        let generation: Int
    }

    private struct StreamKey: Hashable {
        let farmID: UUID
        let generation: Int
        let type: String
        let id: UUID
    }

    private struct AvatarKey: Hashable {
        let farmID: UUID
        let sheepID: UUID
    }

    private var farmStates: [FarmKey: ESheepCloudFarmState]?
    private var streams: [StreamKey: ESheepCloudStreamState]?
    private var pendingIntents: [UUID: ESheepCloudPendingIntent]?
    private var receiptsByID: [UUID: ESheepCloudEventReceipt]?
    private var receiptsByCommandID: [UUID: [ESheepCloudEventReceipt]]?
    private var attentionItems: [UUID: ESheepCloudAttentionItem]?
    private var assetStates: [UUID: ESheepCloudAssetState]?
    private var farms: [UUID: FarmRecord]?
    private var pens: [UUID: PenRecord]?
    private var sheep: [UUID: SheepRecord]?
    private var reproductions: [UUID: ReproductionRecord]?
    private var photoAssets: [UUID: PhotoAssetRecord]?
    private var avatarSelections: [AvatarKey: [SheepAvatarRecord]]?
    private var registeredInsertedObjects = Set<ObjectIdentifier>()
    let historyRepairIndex = ESheepCloudBusinessRepairIndex()

    func farmState(
        farmID: UUID,
        generation: Int,
        context: ModelContext
    ) throws -> ESheepCloudFarmState? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate { $0.farmID == farmID && $0.farmGeneration == generation })).first
        }

        try loadFarmStatesIfNeeded(context: context)
        return farmStates?[FarmKey(farmID: farmID, generation: generation)]
    }

    func streamState(
        stream: ESheepCloudStreamReferenceV2,
        farmID: UUID,
        generation: Int,
        context: ModelContext
    ) throws -> ESheepCloudStreamState? {
        if !bulkReplay {
            let streamType = stream.type, streamID = stream.id
            return try context.fetch(FetchDescriptor<ESheepCloudStreamState>(predicate: #Predicate { $0.farmID == farmID && $0.farmGeneration == generation && $0.streamType == streamType && $0.streamID == streamID })).first
        }

        try loadStreamsIfNeeded(context: context)
        return streams?[StreamKey(
            farmID: farmID,
            generation: generation,
            type: stream.type,
            id: stream.id
        )]
    }

    func pendingIntent(
        commandID: UUID,
        context: ModelContext
    ) throws -> ESheepCloudPendingIntent? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate { $0.id == commandID })).first
        }

        try loadPendingIntentsIfNeeded(context: context)
        return pendingIntents?[commandID]
    }

    func eventReceipt(
        eventID: UUID,
        context: ModelContext
    ) throws -> ESheepCloudEventReceipt? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>(predicate: #Predicate { $0.id == eventID })).first
        }

        try loadReceiptsIfNeeded(context: context)
        return receiptsByID?[eventID]
    }

    func eventReceipts(
        commandID: UUID,
        context: ModelContext
    ) throws -> [ESheepCloudEventReceipt] {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>(predicate: #Predicate { $0.commandID == commandID }))
        }

        try loadReceiptsIfNeeded(context: context)
        return receiptsByCommandID?[commandID] ?? []
    }

    func attentionItem(
        id: UUID,
        context: ModelContext
    ) throws -> ESheepCloudAttentionItem? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate { $0.id == id })).first
        }

        try loadAttentionItemsIfNeeded(context: context)
        return attentionItems?[id]
    }

    func assetState(
        assetID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> ESheepCloudAssetState? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate { $0.id == assetID && $0.farmID == farmID })).first
        }

        try loadAssetStatesIfNeeded(context: context)
        guard let asset = assetStates?[assetID], asset.farmID == farmID else {
            return nil
        }
        return asset
    }

    func farm(id: UUID, context: ModelContext) throws -> FarmRecord? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate { $0.id == id })).first
        }

        try loadFarmsIfNeeded(context: context)
        return farms?[id]
    }

    func pen(id: UUID, context: ModelContext) throws -> PenRecord? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate { $0.id == id })).first
        }

        try loadPensIfNeeded(context: context)
        return pens?[id]
    }

    func sheep(id: UUID, context: ModelContext) throws -> SheepRecord? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.id == id })).first
        }

        try loadSheepIfNeeded(context: context)
        return sheep?[id]
    }

    func reproduction(id: UUID, context: ModelContext) throws -> ReproductionRecord? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate { $0.id == id })).first
        }

        try loadReproductionsIfNeeded(context: context)
        return reproductions?[id]
    }

    func photoAsset(id: UUID, context: ModelContext) throws -> PhotoAssetRecord? {
        if !bulkReplay {
            return try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate { $0.id == id })).first
        }

        try loadPhotoAssetsIfNeeded(context: context)
        return photoAssets?[id]
    }

    func applyAvatarSelection(
        _ update: SheepAvatarPhotoUpdate,
        sheepID: UUID,
        farmID: UUID,
        updatedAt: Date,
        context: ModelContext
    ) throws {
        if bulkReplay {
            try loadAvatarSelectionsIfNeeded(context: context)
        } else {
            let matches = try context.fetch(FetchDescriptor<SheepAvatarRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID
            }))
            avatarSelections = [AvatarKey(farmID: farmID, sheepID: sheepID): matches]
        }
        let key = AvatarKey(farmID: farmID, sheepID: sheepID)
        var selections = avatarSelections?[key] ?? []
        if let selection = selections.max(by: { $0.updatedAt < $1.updatedAt }) {
            selection.photoAssetID = update.photoAssetID
            selection.updatedAt = updatedAt
            let duplicateIDs = Set(selections.filter { $0.id != selection.id }.map(\.id))
            if !duplicateIDs.isEmpty {
                for duplicate in selections where duplicateIDs.contains(duplicate.id) {
                    context.delete(duplicate)
                }
                selections.removeAll { duplicateIDs.contains($0.id) }
            }
        } else {
            let selection = SheepAvatarRecord(
                farmID: farmID,
                sheepID: sheepID,
                photoAssetID: update.photoAssetID,
                updatedAt: updatedAt
            )
            context.insert(selection)
            register(selection)
            selections = [selection]
        }
        avatarSelections?[key] = selections
    }

    /// Eagerly materialize every lookup table used by a bulk replay. Keeping
    /// this explicit makes the query contract visible: each model category is
    /// fetched at most once per transaction, before the event loop begins.
    func preload(in context: ModelContext) throws {
        guard bulkReplay else { return }
        try loadFarmStatesIfNeeded(context: context)
        try loadStreamsIfNeeded(context: context)
        try loadPendingIntentsIfNeeded(context: context)
        try loadReceiptsIfNeeded(context: context)
        try loadAttentionItemsIfNeeded(context: context)
        try loadAssetStatesIfNeeded(context: context)
        try loadFarmsIfNeeded(context: context)
        try loadPensIfNeeded(context: context)
        try loadSheepIfNeeded(context: context)
        try loadReproductionsIfNeeded(context: context)
        try loadPhotoAssetsIfNeeded(context: context)
        try loadAvatarSelectionsIfNeeded(context: context)
        registerInsertedModels(in: context)
    }

    /// Register models created by a domain handler since the previous
    /// checkpoint. This is called at chunk boundaries, not per event, so the
    /// inserted-model list cannot reintroduce an O(events²) scan.
    func registerInsertedModels(in context: ModelContext) {
        let inserted = context.insertedModelsArray
        // SwiftData does not promise insertion order for this collection.
        // An array-position cursor can miss a new object after reordering.
        for model in inserted {
            let objectID = ObjectIdentifier(model as AnyObject)
            guard registeredInsertedObjects.insert(objectID).inserted else {
                continue
            }
            register(model)
        }
    }

    func register(_ model: any PersistentModel) {
        historyRepairIndex.register(model)
        switch model {
        case let value as ESheepCloudFarmState:
            farmStates?[FarmKey(farmID: value.farmID, generation: value.farmGeneration)] = value
        case let value as ESheepCloudStreamState:
            streams?[StreamKey(
                farmID: value.farmID,
                generation: value.farmGeneration,
                type: value.streamType,
                id: value.streamID
            )] = value
        case let value as ESheepCloudPendingIntent:
            pendingIntents?[value.id] = value
        case let value as ESheepCloudEventReceipt:
            receiptsByID?[value.id] = value
            receiptsByCommandID?[value.commandID, default: []].append(value)
        case let value as ESheepCloudAttentionItem:
            attentionItems?[value.id] = value
        case let value as ESheepCloudAssetState:
            assetStates?[value.id] = value
        case let value as FarmRecord:
            farms?[value.id] = value
        case let value as PenRecord:
            pens?[value.id] = value
        case let value as SheepRecord:
            sheep?[value.id] = value
        case let value as ReproductionRecord:
            reproductions?[value.id] = value
        case let value as PhotoAssetRecord:
            photoAssets?[value.id] = value
        case let value as SheepAvatarRecord:
            let key = AvatarKey(farmID: value.farmID, sheepID: value.sheepID)
            var values = avatarSelections?[key] ?? []
            if !values.contains(where: { $0.id == value.id }) {
                values.append(value)
            }
            avatarSelections?[key] = values
        default:
            break
        }
    }

    private func loadFarmStatesIfNeeded(context: ModelContext) throws {
        guard farmStates == nil else { return }
        farmStates = [:]
        for value in try context.fetch(FetchDescriptor<ESheepCloudFarmState>()) {
            farmStates?[FarmKey(farmID: value.farmID, generation: value.farmGeneration)] = value
        }
    }

    private func loadStreamsIfNeeded(context: ModelContext) throws {
        guard streams == nil else { return }
        streams = [:]
        for value in try context.fetch(FetchDescriptor<ESheepCloudStreamState>()) {
            streams?[StreamKey(
                farmID: value.farmID,
                generation: value.farmGeneration,
                type: value.streamType,
                id: value.streamID
            )] = value
        }
    }

    private func loadPendingIntentsIfNeeded(context: ModelContext) throws {
        guard pendingIntents == nil else { return }
        pendingIntents = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
                .map { ($0.id, $0) }
        )
    }

    private func loadReceiptsIfNeeded(context: ModelContext) throws {
        guard receiptsByID == nil else { return }
        let values = try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>())
        receiptsByID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        receiptsByCommandID = Dictionary(grouping: values, by: \.commandID)
    }

    private func loadAttentionItemsIfNeeded(context: ModelContext) throws {
        guard attentionItems == nil else { return }
        attentionItems = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>())
                .map { ($0.id, $0) }
        )
    }

    private func loadAssetStatesIfNeeded(context: ModelContext) throws {
        guard assetStates == nil else { return }
        assetStates = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
                .map { ($0.id, $0) }
        )
    }

    private func loadFarmsIfNeeded(context: ModelContext) throws {
        guard farms == nil else { return }
        farms = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<FarmRecord>())
                .map { ($0.id, $0) }
        )
    }

    private func loadPensIfNeeded(context: ModelContext) throws {
        guard pens == nil else { return }
        pens = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<PenRecord>())
                .map { ($0.id, $0) }
        )
    }

    private func loadSheepIfNeeded(context: ModelContext) throws {
        guard sheep == nil else { return }
        sheep = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<SheepRecord>())
                .map { ($0.id, $0) }
        )
    }

    private func loadReproductionsIfNeeded(context: ModelContext) throws {
        guard reproductions == nil else { return }
        reproductions = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<ReproductionRecord>())
                .map { ($0.id, $0) }
        )
    }

    private func loadPhotoAssetsIfNeeded(context: ModelContext) throws {
        guard photoAssets == nil else { return }
        photoAssets = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                .map { ($0.id, $0) }
        )
    }

    private func loadAvatarSelectionsIfNeeded(context: ModelContext) throws {
        guard avatarSelections == nil else { return }
        avatarSelections = Dictionary(
            grouping: try context.fetch(FetchDescriptor<SheepAvatarRecord>()),
            by: { AvatarKey(farmID: $0.farmID, sheepID: $0.sheepID) }
        )
    }
}

enum ESheepCloudProjectionError: LocalizedError, Equatable {
    case farmStateMissing
    case farmIdentityMismatch
    case eventSequenceGap(expected: Int64, received: Int64)
    case duplicateEventMismatch
    case commandDigestMismatch
    case streamDigestMismatch
    case invalidFieldValue(String)
    case unsupportedStream(String)
    case unsupportedEvent

    var errorDescription: String? {
        switch self {
        case .farmStateMissing:
            "这座牧场尚未准备好接收 eSheep+ 云资料。"
        case .farmIdentityMismatch:
            "接收到的资料不属于当前牧场，已停止应用。"
        case .eventSequenceGap:
            "部分牧场资料没有按顺序接收完整。"
        case .duplicateEventMismatch, .commandDigestMismatch,
             .streamDigestMismatch:
            "接收到的牧场资料完整性检查未通过。"
        case .invalidFieldValue(let field):
            "云端返回的\(field)内容无法安全应用。"
        case .unsupportedStream, .unsupportedEvent:
            "这部分牧场资料需要新版 eSheep+ 才能读取。"
        }
    }
}

struct ESheepCloudEventApplyOutcome: Sendable, Equatable {
    let eventSequence: Int64
    let wasAlreadyApplied: Bool
    let historyChangedAt: Date?
}

/// Deterministic V2 projection reducer. Event receipt, canonical stream state,
/// business projection and the farm head are saved in one ModelContext commit.
/// It never creates a V1 outbox row or a client-authored baseline.
enum ESheepCloudEventReducer {
    static func apply(
        _ event: ESheepCloudEventEnvelopeV2,
        context: ModelContext,
        savesChanges: Bool = true,
        replayContext: ESheepCloudProjectionReplayContext? = nil,
        domainApplyService: RemoteDomainApplyService? = nil
    ) throws -> ESheepCloudEventApplyOutcome {
        try event.validateDigest()
        guard let farmState = try farmState(
            farmID: event.farmID,
            generation: event.farmGeneration,
            context: context,
            replayContext: replayContext
        ) else {
            throw ESheepCloudProjectionError.farmStateMissing
        }
        guard farmState.farmID == event.farmID,
              farmState.farmGeneration == event.farmGeneration else {
            throw ESheepCloudProjectionError.farmIdentityMismatch
        }

        if let receipt = try eventReceipt(
            eventID: event.eventID,
            context: context,
            replayContext: replayContext
        ) {
            guard receipt.farmID == event.farmID,
                  receipt.farmGeneration == event.farmGeneration,
                  receipt.eventSequence == event.eventSequence,
                  receipt.commandID == event.commandID,
                  receipt.eventDigest == event.eventDigest,
                  receipt.appliedProjectionDigest == event.afterDigest else {
                throw ESheepCloudProjectionError.duplicateEventMismatch
            }
            return ESheepCloudEventApplyOutcome(
                eventSequence: event.eventSequence,
                wasAlreadyApplied: true,
                historyChangedAt: nil
            )
        }

        if event.eventSequence <= farmState.lastAppliedEventSequence {
            let farmID = event.farmID, generation = event.farmGeneration
            let anchors = try context.fetch(FetchDescriptor<ESheepCloudCheckpointState>(predicate: #Predicate {
                $0.farmID == farmID && $0.farmGeneration == generation
            }))
            if let anchor = anchors.first(where: { ["active", "verified"].contains($0.stateRawValue) &&
                $0.boundaryEventSequence >= event.eventSequence }) {
                if event.eventSequence == anchor.boundaryEventSequence,
                   event.eventDigest != anchor.boundaryEventDigest {
                    throw ESheepCloudProjectionError.duplicateEventMismatch
                }
                // The independently verified projection already covers this
                // prefix. This is not a command acceptance receipt: unresolved
                // local commands must still be queried by their original ID.
                return ESheepCloudEventApplyOutcome(eventSequence: event.eventSequence,
                    wasAlreadyApplied: true, historyChangedAt: nil)
            }
        }

        let expected = farmState.lastAppliedEventSequence + 1
        guard event.eventSequence == expected else {
            throw ESheepCloudProjectionError.eventSequenceGap(
                expected: expected,
                received: event.eventSequence
            )
        }

        let localIntent = try pendingIntent(
            commandID: event.commandID,
            context: context,
            replayContext: replayContext
        )
        if let localIntent {
            // A receipt is only safe to apply to the intent that created it.
            // Matching the digest alone is insufficient: a stale or damaged
            // local row could otherwise let an event from another farm,
            // generation, account, or device advance this store.
            guard localIntent.farmID == event.farmID,
                  localIntent.farmGeneration == event.farmGeneration,
                  localIntent.accountID == event.actorAccountID,
                  localIntent.deviceID == event.sourceDeviceID,
                  localIntent.commandDigest == event.sourceCommandDigest else {
                throw ESheepCloudProjectionError.commandDigestMismatch
            }
        }

        let historyChangedAt: Date?
        switch event.payload {
        case .fieldsPatched(let stream, let changes):
            guard stream == event.stream else {
                throw ESheepCloudProjectionError.farmIdentityMismatch
            }
            try applyFieldChanges(
                changes,
                event: event,
                context: context,
                replayContext: replayContext
            )
            // Descriptive edits (ear tag, note, breed, pedigree display) do
            // not change occupancy history. Only count-affecting profile
            // fields need the daily projection rebuilt.
            historyChangedAt = stream.type == "sheepProfile" &&
                changes.contains(where: { ["purpose", "isHistoricalArchive"].contains($0.field) })
                ? event.occurredAt : nil

        case .businessCommandApplied(let commandKind, let payload):
            guard commandKind == payload.kind else {
                throw ESheepCloudContractError.malformedPayload
            }
            if case .photo(let photo) = payload {
                try applyPhoto(
                    photo,
                    event: event,
                    context: context,
                    replayContext: replayContext
                )
                historyChangedAt = nil
            } else {
                // The originating device has already committed its optimistic
                // business projection in the same ModelContext transaction as
                // the pending intent. Re-applying that event would duplicate
                // facts or increment a scalar revision twice. A device that
                // did not author the command uses the shared domain adapter;
                // it replays the exact typed payload into an empty store.
                // A multi-stream command emits one event per affected lane.
                // The first event replays the typed business payload; later
                // lane events carry the same payload but must not append the
                // fact or mutate the business projection a second time.
                let commandAlreadyApplied = try eventReceipt(
                    commandID: event.commandID, farmID: event.farmID,
                    farmGeneration: event.farmGeneration, context: context,
                    replayContext: replayContext) != nil
                let purposeHistory = commandAlreadyApplied ? nil : try ESheepCloudPurposeHistory.capture(
                    payload: payload, commandID: event.commandID, farmID: event.farmID,
                    context: context, replayContext: replayContext)
                if localIntent == nil && !commandAlreadyApplied {
                    let outcome = try ESheepCloudV2DomainAdapter.apply(
                        event: event,
                        context: context,
                        domainApplyService: domainApplyService,
                        replayContext: replayContext
                    )
                    switch outcome {
                    case .applied(let rebuildHistoryFrom):
                        historyChangedAt = rebuildHistoryFrom
                    case .duplicate:
                        historyChangedAt = nil
                    case .conflict:
                        // A V2 event was accepted by the authority, so a
                        // local legacy-revision conflict indicates divergent
                        // projection state rather than a business choice.
                        throw ESheepCloudProjectionError.streamDigestMismatch
                    }
                } else {
                    historyChangedAt = nil
                }
                if let purposeHistory {
                    try ESheepCloudPurposeHistory.record(command: purposeHistory.command,
                        commandID: event.commandID, farmID: event.farmID,
                        accountID: event.actorAccountID, deviceID: event.sourceDeviceID,
                        occurredAt: event.occurredAt, recordedAt: event.receivedAt,
                        previousPurpose: purposeHistory.previousPurpose, context: context)
                }
            }
            try advanceNonFieldStream(
                event: event,
                commandKind: commandKind,
                context: context,
                replayContext: replayContext
            )

        case .attentionResolved(let attentionID, let field, let choice, let chosenValue):
            try applyFieldValue(
                chosenValue,
                stream: event.stream,
                field: field,
                farmID: event.farmID,
                changedAt: event.receivedAt,
                stableFactID: event.eventID,
                context: context,
                replayContext: replayContext
            )
            try resolveLocalAttention(
                attentionID: attentionID,
                event: event,
                choice: choice,
                context: context,
                replayContext: replayContext
            )
            try advanceResolvedFieldStream(
                event: event,
                field: field,
                value: chosenValue,
                context: context,
                replayContext: replayContext
            )
            historyChangedAt = event.stream.type == "sheepProfile" &&
                ["purpose", "isHistoricalArchive"].contains(field) ? event.occurredAt : nil

        case .factAppended, .relationshipChanged, .stateTransitioned,
             .assetChanged:
            // These legacy draft event shapes are intentionally not accepted
            // by the V2 runtime because they do not carry enough typed data to
            // rebuild an empty device deterministically.
            throw ESheepCloudProjectionError.unsupportedEvent
        }

        farmState.lastAppliedEventSequence = event.eventSequence
        farmState.cloudEventHead = max(farmState.cloudEventHead, event.eventSequence)
        farmState.projectionDigest = receiptChainDigest(
            previous: farmState.projectionDigest,
            eventDigest: event.eventDigest
        )
        farmState.updatedAt = .now
        let receipt = ESheepCloudEventReceipt(
            eventID: event.eventID,
            farmID: event.farmID,
            farmGeneration: event.farmGeneration,
            eventSequence: event.eventSequence,
            commandID: event.commandID,
            eventDigest: event.eventDigest,
            appliedProjectionDigest: event.afterDigest
        )
        context.insert(receipt)
        replayContext?.register(receipt)
        // Most V2 domain routes register new models at the insertion site.
        // Care/TMR handlers are older graph writers that still call
        // `context.insert` internally, so publish their pending suffix before
        // the next event can reference a child projection. Avoiding this scan
        // for ordinary field/fact events is important: SwiftData's
        // `insertedModelsArray` grows with the transaction and reading it for
        // all 34,842 events would itself recreate an event-sized copy cost.
        if Self.requiresPendingDomainIndexRefresh(event) {
            replayContext?.registerInsertedModels(in: context)
            domainApplyService?.rebuildPendingReplayIndex(in: context)
        }
        if savesChanges {
            try context.save()
        }
        return ESheepCloudEventApplyOutcome(
            eventSequence: event.eventSequence,
            wasAlreadyApplied: false,
            historyChangedAt: historyChangedAt
        )
    }

    /// Stores every decision item returned for a command and rebases only its
    /// affected field to the current cloud value. The user's proposed value is
    /// retained in the attention row and never discarded or guessed.
    static func recordAttentionItems(
        _ items: [ESheepCloudAttentionPayloadV2],
        result: ESheepCloudCommandResultV2,
        farmID: UUID,
        farmGeneration: Int,
        requiresLocalIntent: Bool = true,
        context: ModelContext
    ) throws {
        guard !items.isEmpty,
              items.allSatisfy({
                  $0.stream.id == $0.recordID || !$0.recordType.isEmpty
              }) else {
            throw ESheepCloudContractError.malformedPayload
        }
        let resultData = try ESheepCloudCanonicalCodec.encode(result)
        let commandIDs = Set(items.map(\.commandID))
        guard commandIDs.count == 1, let commandID = commandIDs.first else {
            throw ESheepCloudContractError.malformedPayload
        }
        let intent = try pendingIntent(commandID: commandID, context: context)
        if requiresLocalIntent {
            guard let intent,
                  intent.farmID == farmID,
                  intent.farmGeneration == farmGeneration else {
                throw ESheepCloudContractError.malformedPayload
            }
        } else if let intent,
                  (intent.farmID != farmID || intent.farmGeneration != farmGeneration) {
            throw ESheepCloudContractError.malformedPayload
        }

        for item in items {
            guard item.deviceValue.digest != item.cloudValue.digest else {
                throw ESheepCloudContractError.malformedPayload
            }
            let existing = try attentionItem(id: item.id, context: context)
            if let existing {
                let deviceValueData = try ESheepCloudCanonicalCodec.encode(item.deviceValue)
                guard existing.commandID == item.commandID,
                      existing.streamType == item.stream.type,
                      existing.streamID == item.stream.id,
                      existing.fieldKey == item.field,
                      existing.baseValueDigest == item.baseValueDigest,
                      existing.deviceValueData == deviceValueData else {
                    throw ESheepCloudProjectionError.duplicateEventMismatch
                }
                existing.recordDisplayName = item.recordDisplayName
                existing.fieldDisplayName = item.fieldDisplayName
                existing.cloudValueData = try ESheepCloudCanonicalCodec.encode(item.cloudValue)
                existing.deviceAccountDisplayName = item.deviceAccountDisplayName
                existing.deviceDisplayName = item.deviceDisplayName
                existing.cloudAccountID = item.cloudAccountID
                existing.cloudAccountDisplayName = item.cloudAccountDisplayName
                existing.cloudDeviceID = item.cloudDeviceID
                existing.cloudDeviceDisplayName = item.cloudDeviceDisplayName
                existing.cloudReceivedAt = item.cloudReceivedAt
                existing.explanation = item.explanation
                existing.updatedAt = .now
            } else {
                context.insert(ESheepCloudAttentionItem(
                    id: item.id,
                    farmID: farmID,
                    farmGeneration: farmGeneration,
                    commandID: item.commandID,
                    streamType: item.stream.type,
                    streamID: item.stream.id,
                    recordType: item.recordType,
                    recordID: item.recordID,
                    recordDisplayName: item.recordDisplayName,
                    fieldKey: item.field,
                    fieldDisplayName: item.fieldDisplayName,
                    deviceValueData: try ESheepCloudCanonicalCodec.encode(item.deviceValue),
                    cloudValueData: try ESheepCloudCanonicalCodec.encode(item.cloudValue),
                    baseValueDigest: item.baseValueDigest,
                    deviceAccountID: item.deviceAccountID,
                    deviceAccountDisplayName: item.deviceAccountDisplayName,
                    deviceID: item.deviceID,
                    deviceDisplayName: item.deviceDisplayName,
                    deviceOccurredAt: item.deviceOccurredAt,
                    cloudAccountID: item.cloudAccountID,
                    cloudAccountDisplayName: item.cloudAccountDisplayName,
                    cloudDeviceID: item.cloudDeviceID,
                    cloudDeviceDisplayName: item.cloudDeviceDisplayName,
                    cloudReceivedAt: item.cloudReceivedAt,
                    explanation: item.explanation
                ))
            }
            try applyFieldValue(
                item.cloudValue,
                stream: item.stream,
                field: item.field,
                farmID: farmID,
                changedAt: item.cloudReceivedAt ?? .now,
                stableFactID: item.id,
                context: context
            )
        }
        if let intent {
            intent.lifecycle = .needsConfirmation
            intent.attentionItemID = items.first?.id
            intent.serverResultData = resultData
        }
        try context.save()
    }

    static func markIntegrityFailure(
        farmID: UUID,
        farmGeneration: Int,
        traceID: String,
        context: ModelContext
    ) throws {
        context.rollback()
        guard let state = try farmState(
            farmID: farmID,
            generation: farmGeneration,
            context: context
        ) else { return }
        state.activityState = .integrityHold
        state.integrityState = .failed
        state.integrityFailureTraceID = traceID
        state.lastSafeSaveAt = nil
        try context.save()
    }

    private static func applyFieldChanges(
        _ changes: [ESheepCloudAppliedFieldChangeV2],
        event: ESheepCloudEventEnvelopeV2,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws {
        guard !changes.isEmpty,
              Set(changes.map(\.field)).count == changes.count,
              Set(changes.map(\.field)) == Set(event.affectedFields) else {
            throw ESheepCloudContractError.malformedPayload
        }
        let state = try streamState(
            stream: event.stream,
            farmID: event.farmID,
            farmGeneration: event.farmGeneration,
            creationEventID: event.eventID,
            creationDate: event.receivedAt,
            context: context,
            replayContext: replayContext
        )
        if !state.contentDigest.isEmpty,
           state.contentDigest != event.beforeDigest {
            throw ESheepCloudProjectionError.streamDigestMismatch
        }
        var versions = try decodeFieldVersions(state.fieldVersionsData)

        for change in changes.sorted(by: { $0.field < $1.field }) {
            guard change.value.digest == change.valueDigest else {
                throw ESheepCloudProjectionError.invalidFieldValue(change.field)
            }
            let currentVersion = versions[change.field]?.version ?? 0
            guard change.fieldVersion == currentVersion + 1 else {
                throw ESheepCloudProjectionError.streamDigestMismatch
            }
            versions[change.field] = ESheepCloudFieldVersionEntryV2(
                field: change.field,
                version: change.fieldVersion,
                valueDigest: change.valueDigest,
                value: change.value,
                accountID: event.actorAccountID,
                deviceID: event.sourceDeviceID,
                deviceSequence: event.sourceDeviceSequence,
                occurredAt: event.occurredAt,
                receivedAt: event.receivedAt
            )
            try applyFieldValue(
                change.value,
                stream: event.stream,
                field: change.field,
                farmID: event.farmID,
                changedAt: event.occurredAt,
                stableFactID: event.eventID,
                context: context,
                replayContext: replayContext
            )
        }
        let canonicalData = try canonicalFieldStateData(
            previous: state.canonicalStateData,
            updates: Dictionary(uniqueKeysWithValues: changes.map { ($0.field, $0.value) }),
            event: event
        )
        guard sha256Hex(canonicalData) == event.afterDigest else {
            throw ESheepCloudProjectionError.streamDigestMismatch
        }
        state.canonicalStateData = canonicalData
        state.fieldVersionsData = try ESheepCloudCanonicalCodec.encode(
            versions.values.sorted { $0.field < $1.field }
        )
        state.streamVersion += 1
        state.contentDigest = event.afterDigest
        state.lastEventSequence = event.eventSequence
        state.updatedAt = event.receivedAt
    }

    private static func advanceNonFieldStream(
        event: ESheepCloudEventEnvelopeV2,
        commandKind: String,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws {
        let state = try streamState(
            stream: event.stream,
            farmID: event.farmID,
            farmGeneration: event.farmGeneration,
            creationEventID: event.eventID,
            creationDate: event.receivedAt,
            context: context,
            replayContext: replayContext
        )
        if !state.contentDigest.isEmpty,
           state.contentDigest != event.beforeDigest {
            throw ESheepCloudProjectionError.streamDigestMismatch
        }
        let canonicalData = try ESheepCloudCanonicalCodec.encode(
            ESheepCloudNonFieldStreamStateV2(
                eventCount: state.streamVersion + 1,
                lastCommandDigest: event.sourceCommandDigest,
                lastCommandID: event.commandID.uuidString.lowercased(),
                lastCommandKind: commandKind
            )
        )
        guard sha256Hex(canonicalData) == event.afterDigest else {
            throw ESheepCloudProjectionError.streamDigestMismatch
        }
        state.canonicalStateData = canonicalData
        state.streamVersion += 1
        state.contentDigest = event.afterDigest
        state.lastEventSequence = event.eventSequence
        state.updatedAt = event.receivedAt
    }

    private static func advanceResolvedFieldStream(
        event: ESheepCloudEventEnvelopeV2,
        field: String,
        value: ESheepCloudValueV2,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws {
        let state = try streamState(
            stream: event.stream,
            farmID: event.farmID,
            farmGeneration: event.farmGeneration,
            creationEventID: event.eventID,
            creationDate: event.receivedAt,
            context: context,
            replayContext: replayContext
        )
        guard state.contentDigest.isEmpty || state.contentDigest == event.beforeDigest else {
            throw ESheepCloudProjectionError.streamDigestMismatch
        }
        let canonical = try decodeCanonicalState(state.canonicalStateData)
        var versions = try decodeFieldVersions(state.fieldVersionsData)
        let old = versions[field]
        let fieldChanged = event.beforeDigest != event.afterDigest
        if fieldChanged {
            versions[field] = ESheepCloudFieldVersionEntryV2(
                field: field,
                version: (old?.version ?? 0) + 1,
                valueDigest: value.digest,
                value: value,
                accountID: event.actorAccountID,
                deviceID: event.sourceDeviceID,
                deviceSequence: event.sourceDeviceSequence,
                occurredAt: event.occurredAt,
                receivedAt: event.receivedAt
            )
        } else {
            // Keeping the cloud value is still an auditable event, but it did
            // not author a new field version. Preserve the original device,
            // sequence and timestamps so a later same-device command cannot
            // be ordered against metadata manufactured by the resolver.
            guard canonical[field] == value,
                  old?.valueDigest == value.digest,
                  old?.value == value else {
                throw ESheepCloudProjectionError.streamDigestMismatch
            }
        }
        let canonicalData = fieldChanged
            ? try canonicalFieldStateData(
                previous: state.canonicalStateData,
                updates: [field: value], event: event
            )
            : state.canonicalStateData
        guard sha256Hex(canonicalData) == event.afterDigest else {
            throw ESheepCloudProjectionError.streamDigestMismatch
        }
        state.canonicalStateData = canonicalData
        state.fieldVersionsData = try ESheepCloudCanonicalCodec.encode(
            versions.values.sorted { $0.field < $1.field }
        )
        if fieldChanged { state.streamVersion += 1 }
        state.contentDigest = event.afterDigest
        state.lastEventSequence = event.eventSequence
        state.updatedAt = event.receivedAt
    }

    private static func applyPhoto(
        _ payload: ESheepCloudPhotoCommandV2,
        event: ESheepCloudEventEnvelopeV2,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws {
        switch payload {
        case .register(
            let assetID,
            let sheepID,
            let capturedAt,
            let mimeType,
            let contentSHA256,
            let metadata,
            let metadataDigest,
            let thumbnailSHA256,
            let avatarSHA256,
            let originalSHA256,
            let thumbnailByteCount,
            let avatarByteCount,
            let originalByteCount
        ):
            let sourceSHA256 = metadata["sourceSHA256"] ?? ""
            let sourcePixelWidth = Int(metadata["sourcePixelWidth"] ?? "")
            let sourcePixelHeight = Int(metadata["sourcePixelHeight"] ?? "")
            let cloudPixelWidth = Int(metadata["cloudPixelWidth"] ?? "")
            let cloudPixelHeight = Int(metadata["cloudPixelHeight"] ?? "")
            let metadataCapturedAt = metadata["capturedAtMillis"].flatMap(Int64.init)
            let payloadCapturedAt = capturedAt.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            }
            let capturedAtMatches = if metadata["capturedAtMillis"] == nil {
                capturedAt == nil
            } else {
                metadataCapturedAt != nil && metadataCapturedAt == payloadCapturedAt
            }
            guard assetID == event.stream.id,
                  contentSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  thumbnailSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  avatarSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  originalSHA256 == contentSHA256,
                  sourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  metadata["mimeType"] == mimeType,
                  sourcePixelWidth.map({ $0 > 0 }) == true,
                  sourcePixelHeight.map({ $0 > 0 }) == true,
                  cloudPixelWidth.map({ $0 > 0 }) == true,
                  cloudPixelHeight.map({ $0 > 0 }) == true,
                  capturedAtMatches,
                  thumbnailByteCount > 0,
                  avatarByteCount > 0,
                  originalByteCount > 0,
                  try ESheepCloudCanonicalCodec.digest(metadata) == metadataDigest else {
                throw ESheepCloudContractError.malformedPayload
            }
            let existing: PhotoAssetRecord?
            if let replayContext {
                existing = try replayContext.photoAsset(id: assetID, context: context)
            } else {
                existing = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                    .first { $0.id == assetID && $0.farmID == event.farmID }
            }
            let record: PhotoAssetRecord
            if let existing {
                guard existing.sha256 == contentSHA256,
                      existing.farmID == event.farmID,
                      existing.sheepID == sheepID else {
                    throw ESheepCloudProjectionError.duplicateEventMismatch
                }
                record = existing
            } else {
                record = PhotoAssetRecord(
                    id: assetID,
                    farmID: event.farmID,
                    sheepID: sheepID,
                    legacySourceKey: "esheep-cloud:\(assetID.uuidString.lowercased())",
                    originalEarTag: "",
                    relativePath: "",
                    sha256: contentSHA256,
                    mimeType: mimeType
                )
                context.insert(record)
                replayContext?.register(record)
            }
            record.capturedAt = capturedAt
            record.mimeType = mimeType
            record.sourceSHA256 = sourceSHA256
            record.sourcePixelWidth = sourcePixelWidth ?? 0
            record.sourcePixelHeight = sourcePixelHeight ?? 0
            record.cloudPixelWidth = cloudPixelWidth ?? 0
            record.cloudPixelHeight = cloudPixelHeight ?? 0
            record.isCloudAuthoritative = true
            record.deletedAt = nil
            let asset = try assetState(
                assetID: assetID,
                farmID: event.farmID,
                farmGeneration: event.farmGeneration,
                sheepID: sheepID,
                contentSHA256: contentSHA256,
                byteCount: originalByteCount,
                context: context,
                replayContext: replayContext
            )
            asset.metadataDigest = metadataDigest
            asset.metadataData = try ESheepCloudCanonicalCodec.encode(metadata)
            asset.thumbnailSHA256 = thumbnailSHA256
            asset.avatarSHA256 = avatarSHA256
            asset.originalSHA256 = originalSHA256
            asset.thumbnailByteCount = thumbnailByteCount
            asset.avatarByteCount = avatarByteCount
            asset.originalByteCount = originalByteCount
            asset.thumbnailStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
            asset.avatarStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
            asset.originalStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
            asset.verifiedRemoteByteCount = thumbnailByteCount + avatarByteCount + originalByteCount
            asset.lastVerifiedAt = event.receivedAt
            asset.updatedAt = event.receivedAt

        case .moveToRecycleBin(let assetID, _):
            let record: PhotoAssetRecord?
            let asset: ESheepCloudAssetState?
            if let replayContext {
                record = try replayContext.photoAsset(id: assetID, context: context)
                asset = try replayContext.assetState(
                    assetID: assetID,
                    farmID: event.farmID,
                    context: context
                )
            } else {
                record = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                    .first(where: { $0.id == assetID && $0.farmID == event.farmID })
                asset = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
                    .first(where: { $0.id == assetID && $0.farmID == event.farmID })
            }
            guard assetID == event.stream.id,
                  let record,
                  record.farmID == event.farmID,
                  let asset else {
                throw ESheepCloudProjectionError.invalidFieldValue("照片")
            }
            record.deletedAt = event.receivedAt
            asset.originalStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
            asset.thumbnailStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
            asset.avatarStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
            asset.recycleExpiresAt = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: 30, to: event.receivedAt)
            asset.updatedAt = event.receivedAt

        case .restore(let assetID):
            let record: PhotoAssetRecord?
            let asset: ESheepCloudAssetState?
            if let replayContext {
                record = try replayContext.photoAsset(id: assetID, context: context)
                asset = try replayContext.assetState(
                    assetID: assetID,
                    farmID: event.farmID,
                    context: context
                )
            } else {
                record = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                    .first(where: { $0.id == assetID && $0.farmID == event.farmID })
                asset = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
                    .first(where: { $0.id == assetID && $0.farmID == event.farmID })
            }
            guard assetID == event.stream.id,
                  let record,
                  record.farmID == event.farmID,
                  let asset else {
                throw ESheepCloudProjectionError.invalidFieldValue("照片")
            }
            record.deletedAt = nil
            asset.originalStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
            // Restoring a photo re-enables every derived rendition.  If
            // only the original is marked verified, a restored asset can
            // remain invisible in thumbnails/avatars and the next upload
            // cycle may incorrectly treat those variants as missing.
            asset.thumbnailStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
            asset.avatarStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
            asset.recycleExpiresAt = nil
            asset.updatedAt = event.receivedAt
        }
    }

    private static func applyFieldValue(
        _ value: ESheepCloudValueV2,
        stream: ESheepCloudStreamReferenceV2,
        field: String,
        farmID: UUID,
        changedAt: Date,
        stableFactID: UUID,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws {
        switch stream.type {
        case "farm":
            let farm: FarmRecord?
            if let replayContext {
                farm = try replayContext.farm(id: farmID, context: context)
            } else {
                farm = try context.fetch(FetchDescriptor<FarmRecord>())
                    .first(where: { $0.id == farmID && $0.deletedAt == nil })
            }
            guard stream.id == farmID,
                  let farm,
                  farm.id == farmID,
                  farm.deletedAt == nil else {
                throw ESheepCloudProjectionError.invalidFieldValue("牧场")
            }
            switch field {
            case "displayName": farm.locationDisplayName = try string(value, field: field)
            case "latitude": farm.latitude = try decimalDouble(value, field: field)
            case "longitude": farm.longitude = try decimalDouble(value, field: field)
            case "addressSnapshot": farm.addressSnapshot = try optionalString(value, field: field)
            case "timeZoneIdentifier":
                let identifier = try string(value, field: field)
                guard TimeZone(identifier: identifier) != nil else {
                    throw ESheepCloudProjectionError.invalidFieldValue(field)
                }
                farm.timeZoneIdentifier = identifier
            case "locationSource":
                let raw = try string(value, field: field)
                guard FarmLocationSource(rawValue: raw) != nil else {
                    throw ESheepCloudProjectionError.invalidFieldValue(field)
                }
                farm.locationSourceRawValue = raw
            case "horizontalAccuracyMeters":
                farm.horizontalAccuracyMeters = try optionalDecimalDouble(value, field: field)
            default: throw ESheepCloudProjectionError.unsupportedStream("farm.\(field)")
            }
            farm.locationUpdatedAt = changedAt
            farm.updatedAt = changedAt

        case "pen":
            let pen: PenRecord?
            if let replayContext {
                pen = try replayContext.pen(id: stream.id, context: context)
            } else {
                pen = try context.fetch(FetchDescriptor<PenRecord>())
                    .first(where: { $0.id == stream.id && $0.farmID == farmID && $0.deletedAt == nil })
            }
            guard let pen,
                  pen.farmID == farmID,
                  pen.deletedAt == nil else {
                throw ESheepCloudProjectionError.invalidFieldValue("圈舍")
            }
            switch field {
            case "name": pen.name = try string(value, field: field)
            case "note": pen.note = try string(value, field: field)
            case "isActive": pen.isActive = try boolean(value, field: field)
            default: throw ESheepCloudProjectionError.unsupportedStream("pen.\(field)")
            }
            pen.updatedAt = changedAt

        case "sheepProfile":
            let sheep: SheepRecord?
            if let replayContext {
                sheep = try replayContext.sheep(id: stream.id, context: context)
            } else {
                sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                    .first(where: { $0.id == stream.id && $0.farmID == farmID && $0.deletedAt == nil })
            }
            guard let sheep,
                  sheep.farmID == farmID,
                  sheep.deletedAt == nil else {
                throw ESheepCloudProjectionError.invalidFieldValue("羊只")
            }
            switch field {
            case "earTag": sheep.earTag = try string(value, field: field)
            case "breed": sheep.breed = try string(value, field: field)
            case "sex":
                let raw = try string(value, field: field)
                guard SheepSex(rawValue: raw) != nil else {
                    throw ESheepCloudProjectionError.invalidFieldValue(field)
                }
                sheep.sexRawValue = raw
                if sheep.sex != .ram { sheep.isBreedingRam = false }
            case "birthAt": sheep.birthAt = try optionalDate(value, field: field)
            case "note": sheep.note = try string(value, field: field)
            case "purpose": sheep.purpose = try string(value, field: field)
            case "isBreedingRam": sheep.isBreedingRam = try boolean(value, field: field)
            case "isHistoricalArchive": sheep.isHistoricalArchive = try boolean(value, field: field)
            case "currentParity":
                if case .integer(let parity) = value {
                    guard parity >= 0, sheep.sex == .ewe else {
                        throw ESheepCloudProjectionError.invalidFieldValue(field)
                    }
                    let recordID = StableCloudUUID.derived(
                        namespace: stableFactID,
                        name: "esheep-cloud-profile-parity"
                    )
                    let existing: ReproductionRecord?
                    if let replayContext {
                        existing = try replayContext.reproduction(id: recordID, context: context)
                    } else {
                        existing = try context.fetch(FetchDescriptor<ReproductionRecord>())
                            .first(where: { $0.id == recordID })
                    }
                    if existing == nil {
                        let record = ReproductionRecord(
                            id: recordID,
                            farmID: farmID,
                            eweID: sheep.id,
                            kind: .parityBaseline,
                            occurredAt: changedAt,
                            parity: parity,
                            note: "档案确认当前胎次"
                        )
                        context.insert(record)
                        replayContext?.register(record)
                    }
                } else if value != .null {
                    throw ESheepCloudProjectionError.invalidFieldValue(field)
                }
            case "parityRecordedAt":
                guard value == .null || (try? date(value, field: field)) != nil else {
                    throw ESheepCloudProjectionError.invalidFieldValue(field)
                }
            default: throw ESheepCloudProjectionError.unsupportedStream("sheepProfile.\(field)")
            }
            sheep.updatedAt = changedAt

        case "sheepAvatar":
            guard field == "avatar" else {
                throw ESheepCloudProjectionError.unsupportedStream("sheepAvatar.\(field)")
            }
            let photoID: UUID?
            switch value {
            case .identifier(let id): photoID = id
            case .null: photoID = nil
            default: throw ESheepCloudProjectionError.invalidFieldValue(field)
            }
            try SheepAvatarSelectionStore.apply(
                SheepAvatarPhotoUpdate(photoAssetID: photoID),
                sheepID: stream.id,
                farmID: farmID,
                updatedAt: changedAt,
                context: context,
                replayContext: replayContext
            )

        default:
            throw ESheepCloudProjectionError.unsupportedStream(stream.type)
        }
    }

    private static func resolveLocalAttention(
        attentionID: UUID,
        event: ESheepCloudEventEnvelopeV2,
        choice: ESheepCloudAttentionResolutionChoiceV2,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws {
        guard let item = try attentionItem(
            id: attentionID,
            context: context,
            replayContext: replayContext
        ) else {
            // A second device can resolve an item before this device fetched
            // its detail. The event still remains authoritative and complete.
            return
        }
        item.state = .resolved
        item.resolutionEventID = event.eventID
        item.resolutionCommandID = event.commandID
        item.resolutionRawValue = choice.rawValue
        item.resolutionAwaitingStatus = false
        item.resolutionNextRetryAt = nil
        item.resolutionLastErrorMessage = nil
        item.resolvedAt = event.receivedAt
        item.updatedAt = .now
        if let source = try pendingIntent(
            commandID: item.commandID,
            context: context,
            replayContext: replayContext
        ) {
            source.lifecycle = .accepted
        }
    }

    private static func streamState(
        stream: ESheepCloudStreamReferenceV2,
        farmID: UUID,
        farmGeneration: Int,
        creationEventID: UUID,
        creationDate: Date,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws -> ESheepCloudStreamState {
        if let replayContext,
           let existing = try replayContext.streamState(
               stream: stream,
               farmID: farmID,
               generation: farmGeneration,
               context: context
           ) {
            return existing
        }
        if replayContext == nil {
            let streamType = stream.type, streamID = stream.id
            let matches = try context.fetch(FetchDescriptor<ESheepCloudStreamState>(predicate: #Predicate {
                    $0.farmID == farmID &&
                    $0.farmGeneration == farmGeneration &&
                    $0.streamType == streamType &&
                    $0.streamID == streamID
                }))
            guard matches.count <= 1 else {
                throw ESheepCloudProjectionError.duplicateEventMismatch
            }
            if let existing = matches.first { return existing }
        }
        let created = ESheepCloudStreamState(
            id: creationEventID,
            farmID: farmID,
            farmGeneration: farmGeneration,
            streamType: stream.type,
            streamID: stream.id
        )
        created.createdAt = creationDate
        created.updatedAt = creationDate
        context.insert(created)
        replayContext?.register(created)
        return created
    }

    private static func assetState(
        assetID: UUID,
        farmID: UUID,
        farmGeneration: Int,
        sheepID: UUID?,
        contentSHA256: String,
        byteCount: Int64,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws -> ESheepCloudAssetState {
        let existing: ESheepCloudAssetState?
        if let replayContext {
            existing = try replayContext.assetState(
                assetID: assetID,
                farmID: farmID,
                context: context
            )
        } else {
            let matches = try context.fetch(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate {
                $0.id == assetID && $0.farmID == farmID
            }))
            guard matches.count <= 1 else {
                throw ESheepCloudProjectionError.duplicateEventMismatch
            }
            existing = matches.first
        }
        if let existing {
            guard existing.farmGeneration == farmGeneration,
                  existing.contentSHA256 == contentSHA256 else {
                throw ESheepCloudProjectionError.duplicateEventMismatch
            }
            return existing
        }
        let created = ESheepCloudAssetState(
            assetID: assetID,
            farmID: farmID,
            farmGeneration: farmGeneration,
            sheepID: sheepID,
            contentSHA256: contentSHA256,
            metadataDigest: "",
            originalByteCount: byteCount
        )
        context.insert(created)
        replayContext?.register(created)
        return created
    }

    /// A typed UUID round-trip uppercases its text. JSON stream digests bind
    /// the original spelling, so retain the authenticated wire value while
    /// separately checking it represents the exact typed business change.
    static func canonicalFieldStateData(
        previous: Data,
        updates: [String: ESheepCloudValueV2],
        event: ESheepCloudEventEnvelopeV2
    ) throws -> Data {
        var state: [String: Any] = [:]
        if !previous.isEmpty {
            guard let decoded = try JSONSerialization.jsonObject(with: previous) as? [String: Any] else {
                throw ESheepCloudContractError.malformedPayload
            }
            state = decoded
        }
        var wireValues: [String: Any] = [:]
        if let body = event.eventBodyCanonical {
            try ESheepCloudEventBodyIntegrityV2.validate(
                canonicalJSON: body, expectedDigest: event.eventBodyDigest
            )
            guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
                throw ESheepCloudContractError.malformedPayload
            }
            if let changes = object["changes"] as? [[String: Any]] {
                for change in changes {
                    guard let field = change["field"] as? String,
                          let value = change["value"], wireValues[field] == nil else {
                        throw ESheepCloudContractError.malformedPayload
                    }
                    wireValues[field] = value
                }
            } else if let field = object["field"] as? String,
                      let value = object["chosen_value"] {
                wireValues[field] = value
            }
            guard Set(wireValues.keys) == Set(updates.keys) else {
                throw ESheepCloudContractError.malformedPayload
            }
        }
        for (field, value) in updates {
            let raw = try wireValues[field] ?? JSONSerialization.jsonObject(
                with: ESheepCloudCanonicalCodec.encode(value)
            )
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes])
            guard try ESheepCloudCanonicalCodec.decode(ESheepCloudValueV2.self, from: data) == value else {
                throw ESheepCloudContractError.malformedPayload
            }
            state[field] = raw
        }
        return try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func decodeCanonicalState(
        _ data: Data
    ) throws -> [String: ESheepCloudValueV2] {
        if data.isEmpty { return [:] }
        return try ESheepCloudCanonicalCodec.decode(
            [String: ESheepCloudValueV2].self,
            from: data
        )
    }

    private static func decodeFieldVersions(
        _ data: Data
    ) throws -> [String: ESheepCloudFieldVersionEntryV2] {
        let values = data.isEmpty ? [] : try ESheepCloudCanonicalCodec.decode(
            [ESheepCloudFieldVersionEntryV2].self,
            from: data
        )
        guard Set(values.map(\.field)).count == values.count else {
            throw ESheepCloudProjectionError.duplicateEventMismatch
        }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.field, $0) })
    }

    private static func farmState(
        farmID: UUID,
        generation: Int,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws -> ESheepCloudFarmState? {
        if let replayContext {
            return try replayContext.farmState(
                farmID: farmID,
                generation: generation,
                context: context
            )
        }
        return try context.fetch(FetchDescriptor<ESheepCloudFarmState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        })).first
    }

    private static func pendingIntent(
        commandID: UUID,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws -> ESheepCloudPendingIntent? {
        if let replayContext {
            return try replayContext.pendingIntent(
                commandID: commandID,
                context: context
            )
        }
        return try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.id == commandID
        })).first
    }

    private static func eventReceipt(
        eventID: UUID,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws -> ESheepCloudEventReceipt? {
        if let replayContext {
            return try replayContext.eventReceipt(
                eventID: eventID,
                context: context
            )
        }
        return try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>(predicate: #Predicate {
            $0.id == eventID
        })).first
    }

    private static func eventReceipt(
        commandID: UUID,
        farmID: UUID,
        farmGeneration: Int,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws -> ESheepCloudEventReceipt? {
        if let replayContext {
            let matches = try replayContext.eventReceipts(
                commandID: commandID,
                context: context
            )
            guard matches.allSatisfy({
                $0.farmID == farmID && $0.farmGeneration == farmGeneration
            }) else {
                throw ESheepCloudProjectionError.duplicateEventMismatch
            }
            return matches.first
        }
        let matches = try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>(predicate: #Predicate {
            $0.commandID == commandID
        }))
        guard matches.allSatisfy({
            $0.farmID == farmID && $0.farmGeneration == farmGeneration
        }) else {
            throw ESheepCloudProjectionError.duplicateEventMismatch
        }
        return matches.first
    }

    private static func attentionItem(
        id: UUID,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext? = nil
    ) throws -> ESheepCloudAttentionItem? {
        if let replayContext {
            return try replayContext.attentionItem(id: id, context: context)
        }
        return try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>(predicate: #Predicate {
            $0.id == id
        })).first
    }

    private static func receiptChainDigest(
        previous: String,
        eventDigest: String
    ) -> String {
        SHA256.hash(data: Data("\(previous)\n\(eventDigest)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func requiresPendingDomainIndexRefresh(
        _ event: ESheepCloudEventEnvelopeV2
    ) -> Bool {
        guard case .businessCommandApplied(_, let payload) = event.payload else {
            return false
        }
        if case .care(let command) = payload {
            switch command {
            case .setSheepPurpose, .setBreedingRam, .updateSheepPedigree,
                 .restorePedigreeAudit:
                // These mutate already-indexed sheep, or append audit rows
                // registered directly by the domain writer. Scanning every pending
                // object here costs O(events * store size) during atomic
                // activation while contributing no cache entries.
                return false
            default:
                break
            }
        }
        // The protocol payload exposes the stable wire strings (for example
        // `care.health.recordBatch` and `tmr.produceTMRBatch`), while the
        // legacy domain writer owns the corresponding enum cases. Prefixes
        // cover the complete care/TMR command families, including any future
        // operation added under those namespaces.
        return payload.kind.hasPrefix("care.") || payload.kind.hasPrefix("tmr.")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func string(
        _ value: ESheepCloudValueV2,
        field: String
    ) throws -> String {
        guard case .string(let result) = value else {
            throw ESheepCloudProjectionError.invalidFieldValue(field)
        }
        return result
    }

    private static func optionalString(
        _ value: ESheepCloudValueV2,
        field: String
    ) throws -> String? {
        if value == .null { return nil }
        return try string(value, field: field)
    }

    private static func boolean(
        _ value: ESheepCloudValueV2,
        field: String
    ) throws -> Bool {
        guard case .boolean(let result) = value else {
            throw ESheepCloudProjectionError.invalidFieldValue(field)
        }
        return result
    }

    private static func decimalDouble(
        _ value: ESheepCloudValueV2,
        field: String
    ) throws -> Double {
        guard case .decimal(let text) = value,
              let result = Double(text), result.isFinite else {
            throw ESheepCloudProjectionError.invalidFieldValue(field)
        }
        return result
    }

    private static func optionalDecimalDouble(
        _ value: ESheepCloudValueV2,
        field: String
    ) throws -> Double? {
        if value == .null { return nil }
        return try decimalDouble(value, field: field)
    }

    private static func date(
        _ value: ESheepCloudValueV2,
        field: String
    ) throws -> Date {
        guard case .date(let result) = value else {
            throw ESheepCloudProjectionError.invalidFieldValue(field)
        }
        return result
    }

    private static func optionalDate(
        _ value: ESheepCloudValueV2,
        field: String
    ) throws -> Date? {
        if value == .null { return nil }
        return try date(value, field: field)
    }
}
