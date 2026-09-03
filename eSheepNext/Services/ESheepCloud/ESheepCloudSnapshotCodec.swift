import Foundation

enum ESheepCloudSnapshotRecordV2: Sendable, Equatable {
    case stream(ESheepCloudSnapshotStreamV2)
    case event(ESheepCloudEventEnvelopeV2)
    case asset(ESheepCloudSnapshotAssetV2)
}

struct ESheepCloudSnapshotStreamV2: Sendable, Equatable {
    let stream: ESheepCloudStreamReferenceV2
    let streamVersion: Int64
    let fieldVersions: [ESheepCloudFieldVersionEntryV2]
    let contentDigest: String
    let lastEventSequence: Int64
}

struct ESheepCloudSnapshotAssetV2: Sendable, Equatable {
    let assetID: UUID
    let sheepID: UUID?
    let contentSHA256: String
    let thumbnailSHA256: String?
    let avatarSHA256: String?
    let originalSHA256: String?
    let metadata: [String: String]
    let metadataDigest: String
    let thumbnailState: String
    let avatarState: String
    let originalState: String
    let thumbnailByteCount: Int64
    let avatarByteCount: Int64
    let originalByteCount: Int64
}

enum ESheepCloudSnapshotCodec {
    static func decode(
        _ data: Data,
        farmID: UUID,
        farmGeneration: Int
    ) throws -> [ESheepCloudSnapshotRecordV2] {
        let decoder = ESheepCloudCanonicalCodec.decoder()
        return try decoder.decode([SnapshotRecordWire].self, from: data).map {
            try $0.domainValue(farmID: farmID, farmGeneration: farmGeneration)
        }
    }
}

private enum SnapshotRecordWire: Decodable {
    case stream(StreamWire)
    case event(EventWire)
    case asset(AssetWire)

    private enum CodingKeys: String, CodingKey {
        case recordKind = "record_kind"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .recordKind) {
        case "stream": self = .stream(try StreamWire(from: decoder))
        case "event": self = .event(try EventWire(from: decoder))
        case "asset": self = .asset(try AssetWire(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .recordKind,
                in: container,
                debugDescription: "Unknown eSheep+ Cloud snapshot record."
            )
        }
    }

    func domainValue(
        farmID: UUID,
        farmGeneration: Int
    ) throws -> ESheepCloudSnapshotRecordV2 {
        switch self {
        case .stream(let value): .stream(try value.domainValue())
        case .event(let value):
            .event(try value.domainValue(
                farmID: farmID,
                farmGeneration: farmGeneration
            ))
        case .asset(let value): .asset(try value.domainValue())
        }
    }
}

private struct StreamWire: Decodable {
    let streamType: String
    let streamID: UUID
    let streamVersion: Int64
    let fieldVersions: [String: FieldVersionWire]
    let contentDigest: String
    let lastEventSequence: Int64

    enum CodingKeys: String, CodingKey {
        case streamType = "stream_type"
        case streamID = "stream_id"
        case streamVersion = "stream_version"
        case fieldVersions = "field_versions"
        case contentDigest = "content_digest"
        case lastEventSequence = "last_event_sequence"
    }

    func domainValue() throws -> ESheepCloudSnapshotStreamV2 {
        guard streamVersion >= 0,
              lastEventSequence >= 0,
              contentDigest.isSHA256Hex else {
            throw ESheepCloudContractError.malformedPayload
        }
        return ESheepCloudSnapshotStreamV2(
            stream: .init(type: streamType, id: streamID),
            streamVersion: streamVersion,
            fieldVersions: try fieldVersions.keys.sorted().map {
                try fieldVersions[$0]!.domainValue(field: $0)
            },
            contentDigest: contentDigest,
            lastEventSequence: lastEventSequence
        )
    }
}

private struct FieldVersionWire: Decodable {
    let version: Int64
    let valueDigest: String
    let value: ESheepCloudValueV2?
    let accountID: UUID?
    let deviceID: UUID?
    let deviceSequence: Int64?
    let occurredAt: String?
    let receivedAt: String?

    enum CodingKeys: String, CodingKey {
        case version, value
        case valueDigest = "value_digest"
        case accountID = "account_id"
        case deviceID = "device_id"
        case deviceSequence = "device_sequence"
        case occurredAt = "occurred_at"
        case receivedAt = "received_at"
    }

    func domainValue(field: String) throws -> ESheepCloudFieldVersionEntryV2 {
        guard version > 0,
              valueDigest.isSHA256Hex,
              deviceSequence.map({ $0 > 0 }) ?? true else {
            throw ESheepCloudContractError.malformedPayload
        }
        if let value, value.digest != valueDigest {
            throw ESheepCloudContractError.malformedPayload
        }
        return ESheepCloudFieldVersionEntryV2(
            field: field,
            version: version,
            valueDigest: valueDigest,
            value: value,
            accountID: accountID,
            deviceID: deviceID,
            deviceSequence: deviceSequence,
            occurredAt: try occurredAt.map(ESheepCloudSnapshotWireDate.parse),
            receivedAt: try receivedAt.map(ESheepCloudSnapshotWireDate.parse)
        )
    }
}

private struct EventWire: Decodable {
    let eventSequence: Int64
    let eventID: UUID
    let commandID: UUID
    let sourceCommandDigest: String
    let streamType: String
    let streamID: UUID
    let eventKind: String
    let eventBodyCanonical: String
    let eventBodyDigest: String
    let affectedFields: [String]
    let beforeDigest: String
    let afterDigest: String
    let actorAccountID: UUID
    let sourceDeviceID: UUID
    let sourceDeviceSequence: Int64
    let occurredAtMillis: Int64
    let receivedAtMillis: Int64
    let eventDigest: String

    enum CodingKeys: String, CodingKey {
        case eventSequence = "event_sequence"
        case eventID = "event_id"
        case commandID = "command_id"
        case sourceCommandDigest = "source_command_digest"
        case streamType = "stream_type"
        case streamID = "stream_id"
        case eventKind = "event_kind"
        case eventBodyCanonical = "event_body_canonical"
        case eventBodyDigest = "event_body_digest"
        case affectedFields = "affected_fields"
        case beforeDigest = "before_digest"
        case afterDigest = "after_digest"
        case actorAccountID = "actor_account_id"
        case sourceDeviceID = "source_device_id"
        case sourceDeviceSequence = "source_device_sequence"
        case occurredAtMillis = "occurred_at_millis"
        case receivedAtMillis = "received_at_millis"
        case eventDigest = "event_digest"
    }

    func domainValue(
        farmID: UUID,
        farmGeneration: Int
    ) throws -> ESheepCloudEventEnvelopeV2 {
        try ESheepCloudEventBodyIntegrityV2.validate(
            canonicalJSON: eventBodyCanonical,
            expectedDigest: eventBodyDigest
        )
        guard let bodyData = eventBodyCanonical.data(using: .utf8) else {
            throw ESheepCloudContractError.malformedPayload
        }
        let eventBody: EventBodyWire
        do {
            eventBody = try ESheepCloudCanonicalCodec.decode(
                EventBodyWire.self,
                from: bodyData
            )
        } catch {
            throw ESheepCloudContractError.malformedPayload
        }
        let stream = ESheepCloudStreamReferenceV2(type: streamType, id: streamID)
        let payload: ESheepCloudEventPayloadV2
        switch eventKind {
        case ESheepCloudEventKindV2.fieldPatch:
            guard let changes = eventBody.changes, !changes.isEmpty else {
                throw ESheepCloudContractError.malformedPayload
            }
            payload = .fieldsPatched(
                stream: stream,
                changes: changes.map(\.domainValue)
            )
        case ESheepCloudEventKindV2.attentionResolved:
            guard let attentionID = eventBody.attentionID,
                  let field = eventBody.field,
                  let choice = eventBody.choice,
                  let chosenValue = eventBody.chosenValue else {
                throw ESheepCloudContractError.malformedPayload
            }
            payload = .attentionResolved(
                attentionID: attentionID,
                field: field,
                choice: choice,
                chosenValue: chosenValue
            )
        case let kind where ESheepCloudEventKindV2.businessMergeModes.contains(kind):
            guard let commandKind = eventBody.commandKind,
                  let commandPayload = eventBody.commandPayload,
                  commandKind == commandPayload.kind else {
                throw ESheepCloudContractError.malformedPayload
            }
            payload = .businessCommandApplied(
                commandKind: commandKind,
                payload: commandPayload
            )
        default:
            // Never interpret an unknown event as a generic command.  A
            // client that cannot name the event cannot safely replay it.
            throw ESheepCloudContractError.malformedPayload
        }
        let value = ESheepCloudEventEnvelopeV2(
            protocolVersion: ESheepCloudProtocolV2.protocolVersion,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            farmID: farmID,
            farmGeneration: farmGeneration,
            eventSequence: eventSequence,
            eventID: eventID,
            commandID: commandID,
            sourceCommandDigest: sourceCommandDigest,
            stream: stream,
            payload: payload,
            affectedFields: affectedFields,
            eventBodyDigest: eventBodyDigest,
            beforeDigest: beforeDigest,
            afterDigest: afterDigest,
            actorAccountID: actorAccountID,
            sourceDeviceID: sourceDeviceID,
            sourceDeviceSequence: sourceDeviceSequence,
            occurredAt: Date(timeIntervalSince1970: Double(occurredAtMillis) / 1_000),
            receivedAt: Date(timeIntervalSince1970: Double(receivedAtMillis) / 1_000),
            eventDigest: eventDigest
        )
        try value.validateDigest()
        return value
    }
}

private struct EventBodyWire: Decodable {
    let commandKind: String?
    let commandPayload: ESheepCloudCommandPayloadV2?
    let changes: [AppliedFieldChangeWire]?
    let attentionID: UUID?
    let field: String?
    let choice: ESheepCloudAttentionResolutionChoiceV2?
    let chosenValue: ESheepCloudValueV2?

    enum CodingKeys: String, CodingKey {
        case commandKind = "command_kind"
        case commandPayload = "command_payload"
        case changes
        case attentionID = "attention_id"
        case field
        case choice
        case chosenValue = "chosen_value"
    }
}

private struct AppliedFieldChangeWire: Decodable {
    let field: String
    let value: ESheepCloudValueV2
    let valueDigest: String
    let fieldVersion: Int64

    enum CodingKeys: String, CodingKey {
        case field, value
        case valueDigest = "value_digest"
        case fieldVersion = "field_version"
    }

    var domainValue: ESheepCloudAppliedFieldChangeV2 {
        .init(
            field: field,
            value: value,
            valueDigest: valueDigest,
            fieldVersion: fieldVersion
        )
    }
}

/// Storage uses snake-case state names while the app ledger uses explicit
/// transfer states.  Convert at the Infrastructure/domain boundary instead of
/// leaking database spellings into SwiftData (where `missing` would otherwise
/// be treated as an unknown state and could be silently counted as complete).
enum ESheepCloudAssetWireStateV2: String {
    case missing
    case transferring
    case verified
    case failed
    case recycleBin = "recycle_bin"
    case deleted

    var localRawValue: String {
        switch self {
        case .missing: ESheepCloudAssetTransferState.unavailable.rawValue
        case .transferring: ESheepCloudAssetTransferState.transferring.rawValue
        case .verified: ESheepCloudAssetTransferState.verified.rawValue
        case .failed: ESheepCloudAssetTransferState.failed.rawValue
        case .recycleBin: ESheepCloudAssetTransferState.recycleBin.rawValue
        case .deleted: ESheepCloudAssetTransferState.deleted.rawValue
        }
    }
}

private struct AssetWire: Decodable {
    let assetID: UUID
    let sheepID: UUID?
    let contentSHA256: String
    let thumbnailSHA256: String?
    let avatarSHA256: String?
    let originalSHA256: String?
    let metadata: [String: String]
    let metadataDigest: String
    let thumbnailState: String
    let avatarState: String
    let originalState: String
    let thumbnailByteCount: Int64
    let avatarByteCount: Int64
    let originalByteCount: Int64

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case sheepID = "sheep_id"
        case contentSHA256 = "content_sha256"
        case thumbnailSHA256 = "thumbnail_sha256"
        case avatarSHA256 = "avatar_sha256"
        case originalSHA256 = "original_sha256"
        case metadata
        case metadataDigest = "metadata_digest"
        case thumbnailState = "thumbnail_state"
        case avatarState = "avatar_state"
        case originalState = "original_state"
        case thumbnailByteCount = "thumbnail_byte_count"
        case avatarByteCount = "avatar_byte_count"
        case originalByteCount = "original_byte_count"
    }

    func domainValue() throws -> ESheepCloudSnapshotAssetV2 {
        guard let thumbnailState = ESheepCloudAssetWireStateV2(rawValue: thumbnailState),
              let avatarState = ESheepCloudAssetWireStateV2(rawValue: avatarState),
              let originalState = ESheepCloudAssetWireStateV2(rawValue: originalState),
              contentSHA256.isSHA256Hex,
              thumbnailSHA256.map(\.isSHA256Hex) ?? true,
              avatarSHA256.map(\.isSHA256Hex) ?? true,
              originalSHA256.map(\.isSHA256Hex) ?? true,
              metadataDigest.isSHA256Hex,
              thumbnailByteCount >= 0,
              avatarByteCount >= 0,
              originalByteCount >= 0,
              (thumbnailState != .verified || (thumbnailSHA256 != nil && thumbnailByteCount > 0)),
              (avatarState != .verified || (avatarSHA256 != nil && avatarByteCount > 0)),
              (originalState != .verified || (originalSHA256 != nil && originalByteCount > 0)) else {
            throw ESheepCloudContractError.malformedPayload
        }
        guard try ESheepCloudCanonicalCodec.digest(metadata) == metadataDigest else {
            throw ESheepCloudContractError.malformedPayload
        }
        return .init(
            assetID: assetID,
            sheepID: sheepID,
            contentSHA256: contentSHA256,
            thumbnailSHA256: thumbnailSHA256,
            avatarSHA256: avatarSHA256,
            originalSHA256: originalSHA256,
            metadata: metadata,
            metadataDigest: metadataDigest,
            thumbnailState: thumbnailState.localRawValue,
            avatarState: avatarState.localRawValue,
            originalState: originalState.localRawValue,
            thumbnailByteCount: thumbnailByteCount,
            avatarByteCount: avatarByteCount,
            originalByteCount: originalByteCount
        )
    }
}

private enum ESheepCloudSnapshotWireDate {
    static func parse(_ value: String) throws -> Date {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        throw ESheepCloudContractError.malformedPayload
    }
}

private extension String {
    var isSHA256Hex: Bool {
        range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}
