import CryptoKit
import Foundation
import Supabase

/// The only V2 client component that knows which database and object-storage
/// SDK backs eSheep+ Cloud. No SDK type crosses this adapter boundary.
actor ESheepCloudInfrastructureGateway: ESheepCloudGateway, ESheepCloudAssetTransferTransport {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    /// PostgreSQL's `encode(bytea, 'base64')` inserts line breaks into long
    /// values.  Normalize only whitespace so malformed non-Base64 characters
    /// are still rejected by Foundation's strict decoder.
    static func decodeLineWrappedBase64(_ value: String) -> Data? {
        let normalized = value.filter { !$0.isWhitespace }
        return Data(base64Encoded: normalized)
    }

    func openInitialSync(
        farmID: UUID,
        farmGeneration: Int?
    ) async throws -> ESheepCloudInitialSyncTicketV2 {
        let wire: OpenInitialSyncWire = try await client.rpc(
            "esheep_cloud_open_initial_sync_v2",
            params: OpenInitialSyncParameters(
                p_farm_id: farmID,
                p_farm_generation: farmGeneration
            )
        ).execute().value
        let manifest = try wire.manifest.domainValue()
        guard wire.snapshotID == wire.manifest.snapshotID,
              wire.farmID == wire.manifest.farmID,
              wire.farmGeneration == wire.manifest.farmGeneration,
              wire.boundaryEventSequence == wire.manifest.boundaryEventSequence,
              wire.schemaVersion == ESheepCloudProtocolV2.schemaVersion,
              let profileData = Self.decodeLineWrappedBase64(wire.farmProfileBase64),
              Self.sha256(profileData) == manifest.farmProfileDigest,
              let memberRole = FarmRole(rawValue: wire.memberRole),
              wire.membershipStatus == "active" else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        let profile = try ESheepCloudCanonicalCodec.decode(
            ESheepCloudFarmProfileV2.self,
            from: profileData
        )
        guard profile.farmID == wire.farmID else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        return ESheepCloudInitialSyncTicketV2(
            manifest: manifest,
            farmProfile: profile,
            memberAccountID: wire.memberAccountID,
            memberRole: memberRole,
            membershipStatus: wire.membershipStatus,
            expiresAt: try ESheepCloudWireDate.parse(wire.expiresAt)
        )
    }

    func downloadSnapshotChunk(
        snapshotID: UUID,
        chunkIndex: Int,
        byteOffset: Int64
    ) async throws -> Data {
        let wire: SnapshotChunkWire = try await client.rpc(
            "esheep_cloud_download_snapshot_chunk_v2",
            params: SnapshotChunkParameters(
                p_snapshot_id: snapshotID,
                p_chunk_index: chunkIndex
            )
        ).execute().value
        guard wire.snapshotID == snapshotID,
              wire.chunkIndex == chunkIndex,
              let data = Self.decodeLineWrappedBase64(wire.contentBase64),
              data.count == wire.byteCount,
              Self.sha256(data) == wire.contentSHA256,
              byteOffset >= 0,
              byteOffset <= Int64(data.count) else {
            throw ESheepCloudInfrastructureError.invalidSnapshotChunk
        }
        return Data(data.dropFirst(Int(byteOffset)))
    }

    func pullEvents(
        farmID: UUID,
        farmGeneration: Int,
        after eventSequence: Int64,
        limit: Int
    ) async throws -> ESheepCloudEventPageV2 {
        let wire: EventPageWire = try await client.rpc(
            "esheep_cloud_pull_events_v2",
            params: PullEventsParameters(
                p_farm_id: farmID,
                p_farm_generation: farmGeneration,
                p_after_event_sequence: max(0, eventSequence),
                p_limit: min(1_000, max(1, limit))
            )
        ).execute().value
        let events = try wire.events.map { try $0.domainValue() }
        guard wire.cloudHead >= 0,
              events.allSatisfy({
                  $0.farmID == farmID &&
                      $0.farmGeneration == farmGeneration &&
                      $0.eventSequence > max(0, eventSequence) &&
                      $0.eventSequence <= wire.cloudHead
              }),
              zip(events, events.dropFirst()).allSatisfy({
                  $0.eventSequence < $1.eventSequence
              }),
              (wire.hasMore == ((events.last?.eventSequence ?? max(0, eventSequence)) < wire.cloudHead)) else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        for event in events { try event.validateDigest() }
        return ESheepCloudEventPageV2(
            events: events,
            cloudHead: wire.cloudHead,
            hasMore: wire.hasMore
        )
    }

    func submitCommands(
        _ commands: [ESheepCloudSignedCommandV2]
    ) async throws -> [UUID: ESheepCloudCommandResultV2] {
        guard !commands.isEmpty else { return [:] }
        for signed in commands {
            try signed.command.validateDigest()
            guard !signed.deviceSignature.isEmpty else {
                throw ESheepCloudContractError.missingDeviceIdentity
            }
        }
        let grouped = Dictionary(grouping: commands) {
            FarmGenerationKey(
                farmID: $0.command.farmID,
                generation: $0.command.farmGeneration
            )
        }
        var combined: [UUID: ESheepCloudCommandResultV2] = [:]
        for (key, group) in grouped {
            guard group.count <= 25 else {
                throw ESheepCloudInfrastructureError.commandBatchTooLarge
            }
            let response: SubmitResponseWire = try await client.functions.invoke(
                "esheep-cloud-v2-writes",
                options: FunctionInvokeOptions(body: WriteSubmitRequest(
                    action: "submit_commands",
                    farm_id: key.farmID,
                    farm_generation: key.generation,
                    commands: try group.map(Self.commandWire(from:))
                ))
            )
            let hydrated = try await hydrate(
                response.results,
                farmID: key.farmID,
                farmGeneration: key.generation
            )
            combined.merge(hydrated) { _, newest in newest }
        }
        return combined
    }

    func queryCommandStatus(
        farmID: UUID,
        commandIDs: [UUID]
    ) async throws -> [UUID: ESheepCloudCommandResultV2] {
        guard !commandIDs.isEmpty else { return [:] }
        let status = try await fetchStatusWire(farmID: farmID)
        let response: QueryCommandStatusResponseWire = try await client.rpc(
            "esheep_cloud_query_command_status_v2",
            params: QueryCommandStatusParameters(
                p_farm_id: farmID,
                p_command_ids: commandIDs
            )
        ).execute().value
        return try await hydrate(
            response.results.map(\.result),
            farmID: farmID,
            farmGeneration: status.farmGeneration
        )
    }

    func resolveAttention(
        farmID: UUID,
        resolution: ESheepCloudAttentionResolutionV2
    ) async throws -> ESheepCloudCommandResultV2 {
        let wire: CommandResultWire = try await client.functions.invoke(
            "esheep-cloud-v2-writes",
            options: FunctionInvokeOptions(body: WriteResolveAttentionRequest(
                action: "resolve_attention",
                farm_id: farmID,
                farm_generation: resolution.farmGeneration,
                attention_id: resolution.attentionID,
                resolution_command_id: resolution.resolutionCommandID,
                choice: resolution.choice.signingValue,
                expected_cloud_value_digest: resolution.expectedCloudValueDigest,
                account_id: resolution.accountID,
                device_id: resolution.deviceID,
                device_sequence: resolution.deviceSequence,
                device_signature_base64: resolution.deviceSignature.base64EncodedString()
            ))
        )
        let values = try await hydrate(
            [wire],
            farmID: farmID,
            farmGeneration: resolution.farmGeneration
        )
        guard let value = values[resolution.resolutionCommandID] else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        return value
    }

    func prepareAssetTransfer(
        _ request: ESheepCloudAssetTransferRequestV2
    ) async throws -> ESheepCloudAssetTransferTicketV2 {
        let wire: AssetTransferWire = try await client.rpc(
            "esheep_cloud_prepare_asset_transfer_v2",
            params: PrepareAssetTransferParameters(
                p_farm_id: request.farmID,
                p_farm_generation: request.farmGeneration,
                p_asset_id: request.assetID,
                p_sheep_id: request.sheepID,
                p_content_sha256: request.contentSHA256,
                p_variant_sha256: request.variantSHA256,
                p_metadata: request.metadata,
                p_metadata_digest: request.metadataDigest,
                p_variant: request.variant.rawValue,
                p_direction: request.direction.rawValue,
                p_byte_count: max(0, request.byteCount)
            )
        ).execute().value
        guard wire.assetID == request.assetID,
              wire.variant == request.variant.rawValue else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        let storage = client.storage.from("esheep-cloud-assets")
        let url: URL
        let authorizationToken: String?
        let expiresAt: Date
        switch request.direction {
        case .upload:
            if wire.alreadyVerified {
                url = try await storage.createSignedURL(
                    path: wire.objectKey,
                    expiresIn: 10 * 60
                )
                authorizationToken = nil
                expiresAt = .now.addingTimeInterval(10 * 60)
            } else {
                let signed = try await storage.createSignedUploadURL(
                    path: wire.objectKey,
                    options: .init(upsert: true)
                )
                url = signed.signedURL
                authorizationToken = signed.token
                expiresAt = .now.addingTimeInterval(2 * 60 * 60)
            }
        case .download:
            url = try await storage.createSignedURL(
                path: wire.objectKey,
                expiresIn: 10 * 60
            )
            authorizationToken = nil
            expiresAt = .now.addingTimeInterval(10 * 60)
        }
        return ESheepCloudAssetTransferTicketV2(
            assetID: wire.assetID,
            variant: request.variant,
            objectKey: wire.objectKey,
            signedURL: url,
            authorizationToken: authorizationToken,
            isAlreadyVerified: wire.alreadyVerified,
            byteOffset: max(0, request.byteOffset),
            expiresAt: expiresAt
        )
    }

    func createResumableUpload(
        ticket: ESheepCloudAssetTransferTicketV2,
        descriptor: ESheepCloudResumableUploadDescriptorV2
    ) async throws -> ESheepCloudResumableUploadSessionV2 {
        guard let token = ticket.authorizationToken,
              descriptor.byteCount >= 0,
              descriptor.variantSHA256.isInfrastructureSHA256,
              let endpoint = Self.resumableUploadEndpoint(from: ticket.signedURL) else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        var objectMetadata = descriptor.metadata
        objectMetadata["sha256"] = descriptor.variantSHA256
        let metadataData = try JSONSerialization.data(
            withJSONObject: objectMetadata,
            options: [.sortedKeys]
        )
        guard let metadataJSON = String(data: metadataData, encoding: .utf8) else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        let uploadMetadata: [String: String] = [
            "bucketName": "esheep-cloud-assets",
            "objectName": descriptor.objectKey,
            "contentType": descriptor.contentType,
            "cacheControl": "31536000",
            "metadata": metadataJSON,
        ]
        let header = uploadMetadata.keys.sorted().map { key in
            let encoded = Data(uploadMetadata[key, default: ""].utf8).base64EncodedString()
            return "\(key) \(encoded)"
        }.joined(separator: ",")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        request.setValue(String(descriptor.byteCount), forHTTPHeaderField: "Upload-Length")
        request.setValue(header, forHTTPHeaderField: "Upload-Metadata")
        request.setValue(token, forHTTPHeaderField: "x-signature")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try Self.requireSuccess(response, allowed: [201])
        guard let location = http.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location, relativeTo: endpoint)?.absoluteURL else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        return .init(
            url: sessionURL,
            expiresAt: .now.addingTimeInterval(23 * 60 * 60),
            byteOffset: 0
        )
    }

    func resumableUploadOffset(
        sessionURL: URL,
        authorizationToken: String
    ) async throws -> Int64 {
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "HEAD"
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        request.setValue(authorizationToken, forHTTPHeaderField: "x-signature")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try Self.requireSuccess(response, allowed: [200, 204])
        guard let raw = http.value(forHTTPHeaderField: "Upload-Offset"),
              let offset = Int64(raw), offset >= 0 else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        return offset
    }

    func uploadResumableChunk(
        _ data: Data,
        sessionURL: URL,
        authorizationToken: String,
        byteOffset: Int64
    ) async throws -> Int64 {
        guard !data.isEmpty,
              data.count <= ESheepCloudAssetCoordinator.resumableChunkByteCount,
              byteOffset >= 0 else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PATCH"
        request.httpBody = data
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        request.setValue(String(byteOffset), forHTTPHeaderField: "Upload-Offset")
        request.setValue(
            "application/offset+octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(authorizationToken, forHTTPHeaderField: "x-signature")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try Self.requireSuccess(response, allowed: [204])
        guard let raw = http.value(forHTTPHeaderField: "Upload-Offset"),
              let offset = Int64(raw), offset >= byteOffset else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        return offset
    }

    func confirmAssetUpload(
        farmID: UUID,
        farmGeneration: Int,
        assetID: UUID,
        variant: ESheepCloudAssetVariantV2
    ) async throws {
        let wire: ConfirmAssetWire = try await client.functions.invoke(
            "esheep-cloud-v2-writes",
            options: FunctionInvokeOptions(body: WriteConfirmAssetRequest(
                action: "confirm_asset",
                farm_id: farmID,
                farm_generation: farmGeneration,
                asset_id: assetID,
                variant: variant.rawValue
            ))
        )
        guard wire.assetID == assetID,
              wire.variant == variant.rawValue,
              wire.verified else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
    }

    func downloadAsset(
        ticket: ESheepCloudAssetTransferTicketV2,
        destinationURL: URL
    ) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: ticket.signedURL
        )
        _ = try Self.requireSuccess(response, allowed: Array(200..<300))
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    func fetchCloudStatus(farmID: UUID) async throws -> ESheepCloudStatusV2 {
        let wire = try await fetchStatusWire(farmID: farmID)
        return ESheepCloudStatusV2(
            farmID: wire.farmID,
            farmGeneration: wire.farmGeneration,
            cloudHead: wire.cloudHead,
            latestSnapshotID: wire.latestSnapshotID,
            v2Ready: wire.v2Ready,
            writeFrozen: wire.writeFrozen,
            writeFreezeTraceID: wire.writeFreezeTraceID?.uuidString.lowercased(),
            attentionItems: try wire.attentionItems.map { try $0.domainValue() },
            serverTime: try ESheepCloudWireDate.parse(wire.serverTime)
        )
    }

    private func fetchStatusWire(farmID: UUID) async throws -> StatusWire {
        let wire: StatusWire = try await client.rpc(
            "esheep_cloud_fetch_status_v2",
            params: FetchStatusParameters(p_farm_id: farmID)
        ).execute().value
        // The RPC is the authority boundary.  Never let a malformed or
        // mis-routed response for another farm enter the local actor state.
        guard wire.farmID == farmID,
              wire.farmGeneration >= 0,
              wire.cloudHead >= 0 else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        return wire
    }

    private func hydrate(
        _ wires: [CommandResultWire],
        farmID: UUID,
        farmGeneration: Int
    ) async throws -> [UUID: ESheepCloudCommandResultV2] {
        // A retry can come back as `duplicate` whose original result was the
        // durable `needs_confirmation` outcome.  Fetch the attention index for
        // that shape too; otherwise the client would receive a duplicate
        // result with an empty detail and could never show the user what needs
        // a decision.
        let status = wires.contains(where: {
            $0.type == "needs_confirmation" ||
                $0.original?.type == "needs_confirmation"
        })
            ? try await fetchStatusWire(farmID: farmID)
            : nil
        let requestedSequences = Set(
            wires.flatMap(\.effectiveEventSequences) +
                wires.flatMap { $0.original?.effectiveEventSequences ?? [] }
        )
        var eventBySequence: [Int64: ESheepCloudEventEnvelopeV2] = [:]
        for sequence in requestedSequences {
            let page = try await pullEvents(
                farmID: farmID,
                farmGeneration: farmGeneration,
                after: max(0, sequence - 1),
                limit: 1
            )
            if let event = page.events.first(where: { $0.eventSequence == sequence }) {
                eventBySequence[sequence] = event
            }
        }
        let attentionByID = Dictionary(uniqueKeysWithValues:
            try (status?.attentionItems ?? []).map {
                let value = try $0.domainValue()
                return (value.id, value)
            }
        )
        func events(for sequences: [Int64]) throws -> [ESheepCloudEventEnvelopeV2] {
            let ordered = sequences.sorted()
            let values = ordered.compactMap { eventBySequence[$0] }
            guard values.count == ordered.count else {
                throw ESheepCloudInfrastructureError.malformedResponse
            }
            return values
        }

        var result: [UUID: ESheepCloudCommandResultV2] = [:]
        for wire in wires {
            guard let commandID = wire.commandID else {
                throw ESheepCloudInfrastructureError.malformedResponse
            }
            switch wire.type {
            case "accepted":
                let events = try events(for: wire.effectiveEventSequences)
                result[commandID] = .accepted(
                    events: events,
                    cloudHead: wire.cloudHead ?? 0
                )
            case "duplicate":
                guard let original = wire.original else {
                    throw ESheepCloudInfrastructureError.malformedResponse
                }
                let events = try events(for: original.effectiveEventSequences)
                result[commandID] = .duplicate(original: ESheepCloudOriginalResultV2(
                    commandID: commandID,
                    events: events,
                    attention: original.attentionID.flatMap { attentionByID[$0] },
                    rejection: try original.reason.map { try Self.rejection(from: $0) },
                    cloudHead: original.cloudHead ?? wire.cloudHead ?? 0
                ))
            case "needs_confirmation":
                let items = attentionByID.values
                    .filter { $0.commandID == commandID }
                    .sorted { $0.id.uuidString < $1.id.uuidString }
                guard !items.isEmpty else {
                    throw ESheepCloudInfrastructureError.malformedResponse
                }
                let events = try events(for: wire.effectiveEventSequences)
                result[commandID] = .needsConfirmation(
                    items: items,
                    acceptedEvents: events,
                    cloudHead: wire.cloudHead ?? status?.cloudHead ?? 0
                )
            case "rejected":
                result[commandID] = .rejected(
                    try wire.reason.map { try Self.rejection(from: $0) } ??
                        .malformedCommand(explanation: "eSheep+ 云没有返回可识别的拒绝原因。")
                )
            default:
                throw ESheepCloudInfrastructureError.malformedResponse
            }
        }
        return result
    }

    private static func commandWire(
        from signed: ESheepCloudSignedCommandV2
    ) throws -> SignedCommandWire {
        SignedCommandWire(
            unsigned_command_base64: try signed.command.canonicalUnsignedData.base64EncodedString(),
            content_digest: signed.command.contentDigest,
            device_signature_base64: signed.deviceSignature.base64EncodedString()
        )
    }

    private static func rejection(
        from wire: CommandRejectionWire
    ) throws -> ESheepCloudRejectionReasonV2 {
        switch wire.code {
        case "authentication_required": .authenticationRequired
        case "permission_denied": .permissionDenied
        case "application_update_required": .applicationUpdateRequired
        case "farm_generation_changed": .farmGenerationChanged
        case "farm_temporarily_read_only": .integrityHold(traceID: wire.traceID ?? "")
        case "asset_not_ready":
            if let assetID = wire.assetID {
                .resourceUnavailable(assetID: assetID)
            } else {
                throw ESheepCloudInfrastructureError.malformedResponse
            }
        case "prerequisite_not_ready":
            if let commandID = wire.commandID {
                .prerequisiteRejected(commandID: commandID)
            } else {
                throw ESheepCloudInfrastructureError.malformedResponse
            }
        case "malformed_command", "command_id_digest_mismatch":
            .malformedCommand(explanation: wire.message)
        default:
            .businessRule(
                code: wire.code,
                explanation: wire.message,
                allowedActions: wire.allowedActions ?? []
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct FarmGenerationKey: Hashable {
        let farmID: UUID
        let generation: Int
    }

    private static func resumableUploadEndpoint(from signedURL: URL) -> URL? {
        guard var components = URLComponents(
            url: signedURL,
            resolvingAgainstBaseURL: false
        ), let range = components.path.range(of: "/storage/v1/") else {
            return nil
        }
        components.path = String(components.path[..<range.upperBound]) + "upload/resumable"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func requireSuccess(
        _ response: URLResponse,
        allowed: [Int]
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        guard allowed.contains(http.statusCode) else {
            throw ESheepCloudInfrastructureError.transferFailed(http.statusCode)
        }
        return http
    }
}

private enum ESheepCloudInfrastructureError: LocalizedError {
    case malformedResponse
    case invalidSnapshotChunk
    case commandBatchTooLarge
    case transferFailed(Int)

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "eSheep+ 云返回的资料不完整，已停止应用。"
        case .invalidSnapshotChunk:
            "部分牧场资料没有接收完整。"
        case .commandBatchTooLarge:
            "这次等待保存的内容过多，将分批继续保存。"
        case .transferFailed:
            "照片暂时没有保存完成，将从已确认的位置继续。"
        }
    }
}

private enum ESheepCloudWireDate {
    static func parse(_ value: String) throws -> Date {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        throw ESheepCloudInfrastructureError.malformedResponse
    }
}

private struct OpenInitialSyncParameters: Encodable, Sendable {
    let p_farm_id: UUID
    let p_farm_generation: Int?
}

private struct SnapshotChunkParameters: Encodable, Sendable {
    let p_snapshot_id: UUID
    let p_chunk_index: Int
}

private struct PullEventsParameters: Encodable, Sendable {
    let p_farm_id: UUID
    let p_farm_generation: Int
    let p_after_event_sequence: Int64
    let p_limit: Int
}

private struct WriteSubmitRequest: Encodable, Sendable {
    let action: String
    let farm_id: UUID
    let farm_generation: Int
    let commands: [SignedCommandWire]
}

private struct QueryCommandStatusParameters: Encodable, Sendable {
    let p_farm_id: UUID
    let p_command_ids: [UUID]
}

private struct FetchStatusParameters: Encodable, Sendable {
    let p_farm_id: UUID
}

private struct WriteResolveAttentionRequest: Encodable, Sendable {
    let action: String
    let farm_id: UUID
    let farm_generation: Int
    let attention_id: UUID
    let resolution_command_id: UUID
    let choice: String
    let expected_cloud_value_digest: String
    let account_id: UUID
    let device_id: UUID
    let device_sequence: Int64
    let device_signature_base64: String
}

private struct WriteConfirmAssetRequest: Encodable, Sendable {
    let action: String
    let farm_id: UUID
    let farm_generation: Int
    let asset_id: UUID
    let variant: String
}

private struct PrepareAssetTransferParameters: Encodable, Sendable {
    let p_farm_id: UUID
    let p_farm_generation: Int
    let p_asset_id: UUID
    let p_sheep_id: UUID?
    let p_content_sha256: String
    let p_variant_sha256: String
    let p_metadata: [String: String]
    let p_metadata_digest: String
    let p_variant: String
    let p_direction: String
    let p_byte_count: Int64
}

private struct ConfirmAssetWire: Decodable, Sendable {
    let assetID: UUID
    let variant: String
    let verified: Bool

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case variant, verified
    }
}

private struct SignedCommandWire: Encodable, Sendable {
    let unsigned_command_base64: String
    let content_digest: String
    let device_signature_base64: String
}

private struct SubmitResponseWire: Decodable, Sendable {
    let results: [CommandResultWire]
}

private struct QueryCommandStatusResponseWire: Decodable, Sendable {
    let results: [QueryCommandStatusRowWire]
}

private struct QueryCommandStatusRowWire: Decodable, Sendable {
    let commandID: UUID
    let result: CommandResultWire

    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case result
    }
}

private struct CommandResultWire: Decodable, Sendable {
    let type: String
    let commandID: UUID?
    let eventSequence: Int64?
    let eventID: UUID?
    let mergedEventSequence: Int64?
    let eventSequences: [Int64]?
    let mergedEventSequences: [Int64]?
    let cloudHead: Int64?
    let attentionID: UUID?
    let original: OriginalCommandResultWire?
    let reason: CommandRejectionWire?

    var effectiveEventSequences: [Int64] {
        let values = eventSequences ?? mergedEventSequences ?? original?.effectiveEventSequences ??
            [eventSequence ?? mergedEventSequence].compactMap { $0 }
        return Array(Set(values)).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case type
        case commandID = "command_id"
        case eventSequence = "event_sequence"
        case eventID = "event_id"
        case mergedEventSequence = "merged_event_sequence"
        case eventSequences = "event_sequences"
        case mergedEventSequences = "merged_event_sequences"
        case cloudHead = "cloud_head"
        case attentionID = "attention_id"
        case original
        case reason
    }
}

private struct OriginalCommandResultWire: Decodable, Sendable {
    let type: String
    let eventSequence: Int64?
    let eventID: UUID?
    let eventSequences: [Int64]?
    let cloudHead: Int64?
    let attentionID: UUID?
    let reason: CommandRejectionWire?

    var effectiveEventSequences: [Int64] {
        let values = eventSequences ?? [eventSequence].compactMap { $0 }
        return Array(Set(values)).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case type
        case eventSequence = "event_sequence"
        case eventID = "event_id"
        case eventSequences = "event_sequences"
        case cloudHead = "cloud_head"
        case attentionID = "attention_id"
        case reason
    }
}

private struct CommandRejectionWire: Decodable, Sendable {
    let code: String
    let message: String
    let allowedActions: [String]?
    let traceID: String?
    let commandID: UUID?
    let assetID: UUID?

    enum CodingKeys: String, CodingKey {
        case code, message
        case allowedActions = "allowed_actions"
        case traceID = "trace_id"
        case commandID = "command_id"
        case assetID = "asset_id"
    }
}

private struct EventPageWire: Decodable, Sendable {
    let events: [EventWire]
    let cloudHead: Int64
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case events
        case cloudHead = "cloud_head"
        case hasMore = "has_more"
    }
}

private struct EventWire: Decodable, Sendable {
    let protocolVersion: Int
    let schemaVersion: Int
    let farmID: UUID
    let farmGeneration: Int
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
        case protocolVersion = "protocol_version"
        case schemaVersion = "schema_version"
        case farmID = "farm_id"
        case farmGeneration = "farm_generation"
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

    func domainValue() throws -> ESheepCloudEventEnvelopeV2 {
        try ESheepCloudEventBodyIntegrityV2.validate(
            canonicalJSON: eventBodyCanonical,
            expectedDigest: eventBodyDigest
        )
        guard let bodyData = eventBodyCanonical.data(using: .utf8) else {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        let eventBody: EventBodyWire
        do {
            eventBody = try ESheepCloudCanonicalCodec.decode(
                EventBodyWire.self,
                from: bodyData
            )
        } catch {
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        let stream = ESheepCloudStreamReferenceV2(type: streamType, id: streamID)
        let payload: ESheepCloudEventPayloadV2
        switch eventKind {
        case ESheepCloudEventKindV2.fieldPatch:
            guard let changes = eventBody.changes, !changes.isEmpty else {
                throw ESheepCloudInfrastructureError.malformedResponse
            }
            payload = .fieldsPatched(stream: stream, changes: changes.map(\.domainValue))
        case ESheepCloudEventKindV2.attentionResolved:
            guard let attentionID = eventBody.attentionID,
                  let field = eventBody.field,
                  let choice = eventBody.choice,
                  let chosenValue = eventBody.chosenValue else {
                throw ESheepCloudInfrastructureError.malformedResponse
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
                  commandPayload.kind == commandKind else {
                throw ESheepCloudInfrastructureError.malformedResponse
            }
            payload = .businessCommandApplied(
                commandKind: commandKind,
                payload: commandPayload
            )
        default:
            // Do not downgrade an unknown authority event to a generic
            // business command; replay must fail closed until this app knows
            // the event's reducer semantics.
            throw ESheepCloudInfrastructureError.malformedResponse
        }
        return ESheepCloudEventEnvelopeV2(
            protocolVersion: protocolVersion,
            schemaVersion: schemaVersion,
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
    }
}

private struct EventBodyWire: Decodable, Sendable {
    let commandKind: String?
    let commandPayload: ESheepCloudCommandPayloadV2?
    let affectedStreams: [ESheepCloudStreamReferenceV2]?
    let changes: [AppliedFieldChangeWire]?
    let attentionID: UUID?
    let field: String?
    let choice: ESheepCloudAttentionResolutionChoiceV2?
    let chosenValue: ESheepCloudValueV2?

    enum CodingKeys: String, CodingKey {
        case commandKind = "command_kind"
        case commandPayload = "command_payload"
        case affectedStreams = "affected_streams"
        case changes
        case attentionID = "attention_id"
        case field
        case choice
        case chosenValue = "chosen_value"
    }
}

private struct AppliedFieldChangeWire: Decodable, Sendable {
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
        ESheepCloudAppliedFieldChangeV2(
            field: field,
            value: value,
            valueDigest: valueDigest,
            fieldVersion: fieldVersion
        )
    }
}

private struct StatusWire: Decodable, Sendable {
    let farmID: UUID
    let farmGeneration: Int
    let cloudHead: Int64
    let latestSnapshotID: UUID?
    let v2Ready: Bool
    let writeFrozen: Bool
    let writeFreezeTraceID: UUID?
    let attentionItems: [AttentionWire]
    let serverTime: String

    enum CodingKeys: String, CodingKey {
        case farmID = "farm_id"
        case farmGeneration = "farm_generation"
        case cloudHead = "cloud_head"
        case latestSnapshotID = "latest_snapshot_id"
        case v2Ready = "v2_ready"
        case writeFrozen = "write_frozen"
        case writeFreezeTraceID = "write_freeze_trace_id"
        case attentionItems = "attention_items"
        case serverTime = "server_time"
    }
}

private struct AttentionWire: Decodable, Sendable {
    let attentionID: UUID
    let commandID: UUID
    let streamType: String
    let streamID: UUID
    let recordType: String
    let recordID: UUID
    let recordDisplayName: String
    let fieldKey: String
    let fieldDisplayName: String
    let baseValueDigest: String
    let deviceValue: ESheepCloudValueV2
    let cloudValue: ESheepCloudValueV2
    let deviceAccountID: UUID
    let deviceAccountDisplayName: String?
    let deviceID: UUID
    let deviceDisplayName: String?
    let deviceOccurredAt: String
    let cloudAccountID: UUID?
    let cloudAccountDisplayName: String?
    let cloudDeviceID: UUID?
    let cloudDeviceDisplayName: String?
    let cloudReceivedAt: String?
    let explanation: String

    enum CodingKeys: String, CodingKey {
        case attentionID = "attention_id"
        case commandID = "command_id"
        case streamType = "stream_type"
        case streamID = "stream_id"
        case recordType = "record_type"
        case recordID = "record_id"
        case recordDisplayName = "record_display_name"
        case fieldKey = "field_key"
        case fieldDisplayName = "field_display_name"
        case baseValueDigest = "base_value_digest"
        case deviceValue = "device_value"
        case cloudValue = "cloud_value"
        case deviceAccountID = "device_account_id"
        case deviceAccountDisplayName = "device_account_display_name"
        case deviceID = "device_id"
        case deviceDisplayName = "device_display_name"
        case deviceOccurredAt = "device_occurred_at"
        case cloudAccountID = "cloud_account_id"
        case cloudAccountDisplayName = "cloud_account_display_name"
        case cloudDeviceID = "cloud_device_id"
        case cloudDeviceDisplayName = "cloud_device_display_name"
        case cloudReceivedAt = "cloud_received_at"
        case explanation
    }

    func domainValue() throws -> ESheepCloudAttentionPayloadV2 {
        ESheepCloudAttentionPayloadV2(
            id: attentionID,
            commandID: commandID,
            stream: .init(type: streamType, id: streamID),
            recordType: recordType,
            recordID: recordID,
            recordDisplayName: recordDisplayName,
            field: fieldKey,
            fieldDisplayName: fieldDisplayName,
            deviceValue: deviceValue,
            cloudValue: cloudValue,
            baseValueDigest: baseValueDigest,
            deviceAccountID: deviceAccountID,
            deviceAccountDisplayName: deviceAccountDisplayName,
            deviceID: deviceID,
            deviceDisplayName: deviceDisplayName,
            deviceOccurredAt: try ESheepCloudWireDate.parse(deviceOccurredAt),
            cloudAccountID: cloudAccountID,
            cloudAccountDisplayName: cloudAccountDisplayName,
            cloudDeviceID: cloudDeviceID,
            cloudDeviceDisplayName: cloudDeviceDisplayName,
            cloudReceivedAt: try cloudReceivedAt.map(ESheepCloudWireDate.parse),
            explanation: explanation
        )
    }
}

private struct OpenInitialSyncWire: Decodable, Sendable {
    let snapshotID: UUID
    let farmID: UUID
    let farmGeneration: Int
    let boundaryEventSequence: Int64
    let schemaVersion: Int
    let manifest: SnapshotManifestWire
    let totalDigest: String
    let totalByteCount: Int64
    let chunkCount: Int
    let farmProfileBase64: String
    let memberAccountID: UUID
    let memberRole: String
    let membershipStatus: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case farmID = "farm_id"
        case farmGeneration = "farm_generation"
        case boundaryEventSequence = "boundary_event_sequence"
        case schemaVersion = "schema_version"
        case manifest
        case totalDigest = "total_digest"
        case totalByteCount = "total_byte_count"
        case chunkCount = "chunk_count"
        case farmProfileBase64 = "farm_profile_base64"
        case memberAccountID = "member_account_id"
        case memberRole = "member_role"
        case membershipStatus = "membership_status"
        case expiresAt = "expires_at"
    }
}

private struct SnapshotManifestWire: Decodable, Sendable {
    let snapshotID: UUID
    let farmID: UUID
    let farmGeneration: Int
    let schemaVersion: Int
    let boundaryEventSequence: Int64
    let eventHeadAtCreation: Int64
    let recordCounts: [String: Int]
    let chunks: [SnapshotChunkDescriptorWire]
    let businessHistoryStartedAt: String?
    let businessHistoryEndedAt: String?
    let relationshipDigest: String
    let fieldVersionDigest: String
    let farmProfileDigest: String
    let assets: [AssetManifestWire]
    let totalDigest: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case farmID = "farm_id"
        case farmGeneration = "farm_generation"
        case schemaVersion = "schema_version"
        case boundaryEventSequence = "boundary_event_sequence"
        case eventHeadAtCreation = "event_head_at_creation"
        case recordCounts = "record_counts"
        case chunks
        case businessHistoryStartedAt = "business_history_started_at"
        case businessHistoryEndedAt = "business_history_ended_at"
        case relationshipDigest = "relationship_digest"
        case fieldVersionDigest = "field_version_digest"
        case farmProfileDigest = "farm_profile_digest"
        case assets
        case totalDigest = "total_digest"
        case createdAt = "created_at"
    }

    func domainValue() throws -> ESheepCloudSnapshotManifestV2 {
        ESheepCloudSnapshotManifestV2(
            snapshotID: snapshotID,
            farmID: farmID,
            farmGeneration: farmGeneration,
            schemaVersion: schemaVersion,
            boundaryEventSequence: boundaryEventSequence,
            eventHeadAtCreation: eventHeadAtCreation,
            recordCounts: recordCounts.keys.sorted().map {
                .init(recordType: $0, count: recordCounts[$0] ?? 0)
            },
            chunks: chunks.map(\.domainValue),
            businessHistoryStartedAt: try businessHistoryStartedAt.map(ESheepCloudWireDate.parse),
            businessHistoryEndedAt: try businessHistoryEndedAt.map(ESheepCloudWireDate.parse),
            relationshipDigest: relationshipDigest,
            fieldVersionDigest: fieldVersionDigest,
            farmProfileDigest: farmProfileDigest,
            assets: assets.map(\.domainValue),
            totalDigest: totalDigest,
            createdAt: try ESheepCloudWireDate.parse(createdAt)
        )
    }
}

private struct SnapshotChunkDescriptorWire: Decodable, Sendable {
    let index: Int
    let byteCount: Int64
    let contentSHA256: String

    enum CodingKeys: String, CodingKey {
        case index
        case byteCount = "byte_count"
        case contentSHA256 = "content_sha256"
    }

    var domainValue: ESheepCloudSnapshotChunkDescriptorV2 {
        .init(index: index, byteCount: byteCount, contentSHA256: contentSHA256)
    }
}

private struct AssetManifestWire: Decodable, Sendable {
    let assetID: UUID
    let sheepID: UUID?
    let contentSHA256: String
    let thumbnailSHA256: String?
    let avatarSHA256: String?
    let originalSHA256: String
    let thumbnailByteCount: Int64
    let avatarByteCount: Int64
    let originalByteCount: Int64
    let isCurrentAvatar: Bool

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case sheepID = "sheep_id"
        case contentSHA256 = "content_sha256"
        case thumbnailSHA256 = "thumbnail_sha256"
        case avatarSHA256 = "avatar_sha256"
        case originalSHA256 = "original_sha256"
        case thumbnailByteCount = "thumbnail_byte_count"
        case avatarByteCount = "avatar_byte_count"
        case originalByteCount = "original_byte_count"
        case isCurrentAvatar = "is_current_avatar"
    }

    var domainValue: ESheepCloudAssetManifestEntryV2 {
        .init(
            assetID: assetID,
            sheepID: sheepID,
            contentSHA256: contentSHA256,
            thumbnailSHA256: thumbnailSHA256,
            avatarSHA256: avatarSHA256,
            originalSHA256: originalSHA256,
            thumbnailByteCount: thumbnailByteCount,
            avatarByteCount: avatarByteCount,
            originalByteCount: originalByteCount,
            isCurrentAvatar: isCurrentAvatar
        )
    }
}

private struct SnapshotChunkWire: Decodable, Sendable {
    let snapshotID: UUID
    let chunkIndex: Int
    let contentBase64: String
    let contentSHA256: String
    let byteCount: Int

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case chunkIndex = "chunk_index"
        case contentBase64 = "content_base64"
        case contentSHA256 = "content_sha256"
        case byteCount = "byte_count"
    }
}

private struct AssetTransferWire: Decodable, Sendable {
    let assetID: UUID
    let variant: String
    let objectKey: String
    let alreadyVerified: Bool

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case variant
        case objectKey = "object_key"
        case alreadyVerified = "already_verified"
    }
}

private extension String {
    var isInfrastructureSHA256: Bool {
        range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}
