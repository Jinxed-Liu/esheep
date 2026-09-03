import CryptoKit
import Foundation
import SwiftData

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
@MainActor
enum ESheepCloudEventReducer {
    static func apply(
        _ event: ESheepCloudEventEnvelopeV2,
        context: ModelContext,
        savesChanges: Bool = true
    ) throws -> ESheepCloudEventApplyOutcome {
        try event.validateDigest()
        guard let farmState = try farmState(
            farmID: event.farmID,
            generation: event.farmGeneration,
            context: context
        ) else {
            throw ESheepCloudProjectionError.farmStateMissing
        }
        guard farmState.farmID == event.farmID,
              farmState.farmGeneration == event.farmGeneration else {
            throw ESheepCloudProjectionError.farmIdentityMismatch
        }

        if let receipt = try eventReceipt(eventID: event.eventID, context: context) {
            guard receipt.farmID == event.farmID,
                  receipt.farmGeneration == event.farmGeneration,
                  receipt.eventSequence == event.eventSequence,
                  receipt.commandID == event.commandID,
                  receipt.eventDigest == event.eventDigest else {
                throw ESheepCloudProjectionError.duplicateEventMismatch
            }
            return ESheepCloudEventApplyOutcome(
                eventSequence: event.eventSequence,
                wasAlreadyApplied: true,
                historyChangedAt: nil
            )
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
            context: context
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
                context: context
            )
            historyChangedAt = stream.type == "sheepProfile" ? event.occurredAt : nil

        case .businessCommandApplied(let commandKind, let payload):
            guard commandKind == payload.kind else {
                throw ESheepCloudContractError.malformedPayload
            }
            if case .photo(let photo) = payload {
                try applyPhoto(
                    photo,
                    event: event,
                    context: context
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
                let commandAlreadyApplied: Bool
                if localIntent == nil {
                    commandAlreadyApplied = try eventReceipt(
                        commandID: event.commandID,
                        farmID: event.farmID,
                        farmGeneration: event.farmGeneration,
                        context: context
                    ) != nil
                } else {
                    commandAlreadyApplied = false
                }
                if localIntent == nil && !commandAlreadyApplied {
                    let outcome = try ESheepCloudV2DomainAdapter.apply(
                        event: event,
                        context: context
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
            }
            try advanceNonFieldStream(
                event: event,
                commandKind: commandKind,
                context: context
            )

        case .attentionResolved(let attentionID, let field, let choice, let chosenValue):
            try applyFieldValue(
                chosenValue,
                stream: event.stream,
                field: field,
                farmID: event.farmID,
                changedAt: event.receivedAt,
                stableFactID: event.eventID,
                context: context
            )
            try resolveLocalAttention(
                attentionID: attentionID,
                event: event,
                choice: choice,
                context: context
            )
            try advanceResolvedFieldStream(
                event: event,
                field: field,
                value: chosenValue,
                context: context
            )
            historyChangedAt = event.stream.type == "sheepProfile" ? event.occurredAt : nil

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
        context.insert(ESheepCloudEventReceipt(
            eventID: event.eventID,
            farmID: event.farmID,
            farmGeneration: event.farmGeneration,
            eventSequence: event.eventSequence,
            commandID: event.commandID,
            eventDigest: event.eventDigest,
            appliedProjectionDigest: event.afterDigest
        ))
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
        context: ModelContext
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
            context: context
        )
        if !state.contentDigest.isEmpty,
           state.contentDigest != event.beforeDigest {
            throw ESheepCloudProjectionError.streamDigestMismatch
        }
        var canonical = try decodeCanonicalState(state.canonicalStateData)
        var versions = try decodeFieldVersions(state.fieldVersionsData)

        for change in changes.sorted(by: { $0.field < $1.field }) {
            guard change.value.digest == change.valueDigest else {
                throw ESheepCloudProjectionError.invalidFieldValue(change.field)
            }
            let currentVersion = versions[change.field]?.version ?? 0
            guard change.fieldVersion == currentVersion + 1 else {
                throw ESheepCloudProjectionError.streamDigestMismatch
            }
            canonical[change.field] = change.value
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
                context: context
            )
        }
        let canonicalData = try ESheepCloudCanonicalCodec.encode(canonical)
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
        state.updatedAt = .now
    }

    private static func advanceNonFieldStream(
        event: ESheepCloudEventEnvelopeV2,
        commandKind: String,
        context: ModelContext
    ) throws {
        let state = try streamState(
            stream: event.stream,
            farmID: event.farmID,
            farmGeneration: event.farmGeneration,
            context: context
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
        state.updatedAt = .now
    }

    private static func advanceResolvedFieldStream(
        event: ESheepCloudEventEnvelopeV2,
        field: String,
        value: ESheepCloudValueV2,
        context: ModelContext
    ) throws {
        let state = try streamState(
            stream: event.stream,
            farmID: event.farmID,
            farmGeneration: event.farmGeneration,
            context: context
        )
        guard state.contentDigest.isEmpty || state.contentDigest == event.beforeDigest else {
            throw ESheepCloudProjectionError.streamDigestMismatch
        }
        var canonical = try decodeCanonicalState(state.canonicalStateData)
        var versions = try decodeFieldVersions(state.fieldVersionsData)
        let old = versions[field]
        let fieldChanged = event.beforeDigest != event.afterDigest
        if fieldChanged {
            canonical[field] = value
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
        let canonicalData = try ESheepCloudCanonicalCodec.encode(canonical)
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
        state.updatedAt = .now
    }

    private static func applyPhoto(
        _ payload: ESheepCloudPhotoCommandV2,
        event: ESheepCloudEventEnvelopeV2,
        context: ModelContext
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
            let existing = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                .first { $0.id == assetID && $0.farmID == event.farmID }
            let record: PhotoAssetRecord
            if let existing {
                guard existing.sha256 == contentSHA256,
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
                context: context
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
            asset.updatedAt = .now

        case .moveToRecycleBin(let assetID, _):
            guard assetID == event.stream.id,
                  let record = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                    .first(where: { $0.id == assetID && $0.farmID == event.farmID }),
                  let asset = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
                    .first(where: { $0.id == assetID && $0.farmID == event.farmID }) else {
                throw ESheepCloudProjectionError.invalidFieldValue("照片")
            }
            record.deletedAt = event.receivedAt
            asset.originalStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
            asset.thumbnailStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
            asset.avatarStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
            asset.recycleExpiresAt = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: 30, to: event.receivedAt)
            asset.updatedAt = .now

        case .restore(let assetID):
            guard assetID == event.stream.id,
                  let record = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                    .first(where: { $0.id == assetID && $0.farmID == event.farmID }),
                  let asset = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
                    .first(where: { $0.id == assetID && $0.farmID == event.farmID }) else {
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
            asset.updatedAt = .now
        }
    }

    private static func applyFieldValue(
        _ value: ESheepCloudValueV2,
        stream: ESheepCloudStreamReferenceV2,
        field: String,
        farmID: UUID,
        changedAt: Date,
        stableFactID: UUID,
        context: ModelContext
    ) throws {
        switch stream.type {
        case "farm":
            guard stream.id == farmID,
                  let farm = try context.fetch(FetchDescriptor<FarmRecord>())
                    .first(where: { $0.id == farmID && $0.deletedAt == nil }) else {
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
            guard let pen = try context.fetch(FetchDescriptor<PenRecord>())
                .first(where: { $0.id == stream.id && $0.farmID == farmID && $0.deletedAt == nil }) else {
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
            guard let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                .first(where: { $0.id == stream.id && $0.farmID == farmID && $0.deletedAt == nil }) else {
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
            case "currentParity":
                if case .integer(let parity) = value {
                    guard parity >= 0, sheep.sex == .ewe else {
                        throw ESheepCloudProjectionError.invalidFieldValue(field)
                    }
                    let recordID = StableCloudUUID.derived(
                        namespace: stableFactID,
                        name: "esheep-cloud-profile-parity"
                    )
                    if try context.fetch(FetchDescriptor<ReproductionRecord>())
                        .first(where: { $0.id == recordID }) == nil {
                        context.insert(ReproductionRecord(
                            id: recordID,
                            farmID: farmID,
                            eweID: sheep.id,
                            kind: .parityBaseline,
                            occurredAt: changedAt,
                            parity: parity,
                            note: "档案确认当前胎次"
                        ))
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
                context: context
            )

        default:
            throw ESheepCloudProjectionError.unsupportedStream(stream.type)
        }
    }

    private static func resolveLocalAttention(
        attentionID: UUID,
        event: ESheepCloudEventEnvelopeV2,
        choice: ESheepCloudAttentionResolutionChoiceV2,
        context: ModelContext
    ) throws {
        guard let item = try attentionItem(id: attentionID, context: context) else {
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
        if let source = try pendingIntent(commandID: item.commandID, context: context) {
            source.lifecycle = .accepted
        }
    }

    private static func streamState(
        stream: ESheepCloudStreamReferenceV2,
        farmID: UUID,
        farmGeneration: Int,
        context: ModelContext
    ) throws -> ESheepCloudStreamState {
        let matches = try context.fetch(FetchDescriptor<ESheepCloudStreamState>())
            .filter {
                $0.farmID == farmID &&
                $0.farmGeneration == farmGeneration &&
                $0.streamType == stream.type &&
                $0.streamID == stream.id
            }
        guard matches.count <= 1 else {
            throw ESheepCloudProjectionError.duplicateEventMismatch
        }
        if let existing = matches.first { return existing }
        let created = ESheepCloudStreamState(
            farmID: farmID,
            farmGeneration: farmGeneration,
            streamType: stream.type,
            streamID: stream.id
        )
        context.insert(created)
        return created
    }

    private static func assetState(
        assetID: UUID,
        farmID: UUID,
        farmGeneration: Int,
        sheepID: UUID?,
        contentSHA256: String,
        byteCount: Int64,
        context: ModelContext
    ) throws -> ESheepCloudAssetState {
        let matches = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .filter { $0.id == assetID && $0.farmID == farmID }
        guard matches.count <= 1 else {
            throw ESheepCloudProjectionError.duplicateEventMismatch
        }
        if let existing = matches.first {
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
        return created
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
        context: ModelContext
    ) throws -> ESheepCloudFarmState? {
        try context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first {
            $0.farmID == farmID && $0.farmGeneration == generation
        }
    }

    private static func pendingIntent(
        commandID: UUID,
        context: ModelContext
    ) throws -> ESheepCloudPendingIntent? {
        try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
            .first { $0.id == commandID }
    }

    private static func eventReceipt(
        eventID: UUID,
        context: ModelContext
    ) throws -> ESheepCloudEventReceipt? {
        try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>())
            .first { $0.id == eventID }
    }

    private static func eventReceipt(
        commandID: UUID,
        farmID: UUID,
        farmGeneration: Int,
        context: ModelContext
    ) throws -> ESheepCloudEventReceipt? {
        let matches = try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>())
            .filter { $0.commandID == commandID }
        guard matches.allSatisfy({
            $0.farmID == farmID && $0.farmGeneration == farmGeneration
        }) else {
            throw ESheepCloudProjectionError.duplicateEventMismatch
        }
        return matches.first
    }

    private static func attentionItem(
        id: UUID,
        context: ModelContext
    ) throws -> ESheepCloudAttentionItem? {
        try context.fetch(FetchDescriptor<ESheepCloudAttentionItem>())
            .first { $0.id == id }
    }

    private static func receiptChainDigest(
        previous: String,
        eventDigest: String
    ) -> String {
        SHA256.hash(data: Data("\(previous)\n\(eventDigest)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
