import Foundation
import SwiftData

struct FarmRemoteSyncResult: Sendable, Equatable {
    let uploadedOperationCount: Int
    let downloadedOperationCount: Int
    let conflictCount: Int
    let cursorRevision: Int
}

enum FarmRemoteSyncError: LocalizedError {
    case bindingMissing
    case bindingNotActive
    case operationMissing
    case operationEntityMissing
    case malformedRemoteOperation

    var errorDescription: String? {
        switch self {
        case .bindingMissing:
            "当前牧场缺少 Supabase 远端绑定。"
        case .bindingNotActive:
            "当前牧场的 Supabase 权威尚未激活。"
        case .operationMissing:
            "Outbox 对应的本地操作不存在。"
        case .operationEntityMissing:
            "Outbox 对应操作缺少实体标识。"
        case .malformedRemoteOperation:
            "Supabase 返回的操作无法写入本地历史。"
        }
    }
}

/// Durable Supabase operation synchronization. Realtime is deliberately kept
/// outside this actor and only calls `synchronize`; the persisted cursor and
/// idempotent operation IDs are the recovery mechanism after disconnects and
/// process termination.
actor FarmRemoteSyncCoordinator {
    private struct BindingSnapshot: Sendable {
        let generation: Int
        let cursorRevision: Int
    }

    private struct PreparedBatch: Sendable {
        let operations: [FarmRemotePendingOperation]
        let outboxIDs: [UUID: UUID]
    }

    private let container: ModelContainer
    private let transport: any FarmRemoteTransport
    private let deviceIdentity: DeviceIdentityActor

    init(
        container: ModelContainer,
        transport: any FarmRemoteTransport,
        deviceIdentity: DeviceIdentityActor = .shared
    ) {
        self.container = container
        self.transport = transport
        self.deviceIdentity = deviceIdentity
    }

    func synchronize(
        farmID: UUID,
        maxOutboxItems: Int = 25
    ) async throws -> FarmRemoteSyncResult {
        let binding = try bindingSnapshot(farmID: farmID)
        let prepared = try await preparePendingBatch(
            farmID: farmID,
            generation: binding.generation,
            limit: min(max(1, maxOutboxItems), 25)
        )

        var uploadedCount = 0
        var conflictCount = 0
        if !prepared.operations.isEmpty {
            do {
                let push = try await transport.pushPendingOperations(
                    prepared.operations,
                    authorityGeneration: binding.generation
                )
                uploadedCount = push.receipts.count
                if push.conflictOperationID != nil {
                    conflictCount += 1
                }
                try finalizePush(
                    farmID: farmID,
                    prepared: prepared,
                    result: push
                )
            } catch {
                try markPreparedBatchRetryable(prepared, error: error)
                throw error
            }
        }

        let pull = try await pullUntilCurrent(
            farmID: farmID,
            generation: binding.generation,
            startingCursor: binding.cursorRevision
        )
        conflictCount += pull.conflictCount
        return FarmRemoteSyncResult(
            uploadedOperationCount: uploadedCount,
            downloadedOperationCount: pull.operationCount,
            conflictCount: conflictCount,
            cursorRevision: pull.cursorRevision
        )
    }

    private func bindingSnapshot(farmID: UUID) throws -> BindingSnapshot {
        let context = ModelContext(container)
        guard let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>()).first(where: {
            $0.farmID == farmID && $0.provider == .supabase
        }) else {
            throw FarmRemoteSyncError.bindingMissing
        }
        guard binding.state == .active else {
            throw FarmRemoteSyncError.bindingNotActive
        }
        return BindingSnapshot(
            generation: binding.authorityGeneration,
            cursorRevision: binding.lastPulledRevision
        )
    }

    private func preparePendingBatch(
        farmID: UUID,
        generation: Int,
        limit: Int
    ) async throws -> PreparedBatch {
        let context = ModelContext(container)
        let now = Date.now
        let provider = FarmRemoteProvider.supabase.rawValue
        var sequenceByOperationID = try FarmStorageRouter.operationSequences(
            farmID: farmID,
            context: context
        )
        let eligible = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farmID &&
                $0.deliveryProviderRawValue == provider &&
                $0.authorityGeneration == generation &&
                [.pending, .uploading, .awaitingConfirmation, .retryableFailure].contains($0.status) &&
                ($0.nextRetryAt == nil || $0.nextRetryAt! <= now)
        }.sorted {
            let lhs = sequenceByOperationID[$0.operationID] ?? 0
            let rhs = sequenceByOperationID[$1.operationID] ?? 0
            if lhs != rhs {
                return lhs < rhs
            }
            return $0.createdAt < $1.createdAt
        }

        let selected = Array(eligible.prefix(limit))
        guard !selected.isEmpty else {
            return PreparedBatch(operations: [], outboxIDs: [:])
        }

        let operationIDs = Set(selected.map(\.operationID))
        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            operationIDs.contains($0.id)
        }
        let operationsByID = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0) })
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
        let tombstoneByOperationID = Dictionary(
            uniqueKeysWithValues: tombstones.compactMap { value in
                value.operationID.map { ($0, value) }
            }
        )
        let identity = try await deviceIdentity.identity()
        var pending: [FarmRemotePendingOperation] = []
        var outboxIDs: [UUID: UUID] = [:]

        for item in selected {
            guard let operation = operationsByID[item.operationID] else {
                item.statusRawValue = OutboxStatus.blockedConflict.rawValue
                item.errorMessage = FarmRemoteSyncError.operationMissing.localizedDescription
                continue
            }
            guard let entityID = operation.entityID else {
                item.statusRawValue = OutboxStatus.blockedConflict.rawValue
                item.errorMessage = FarmRemoteSyncError.operationEntityMissing.localizedDescription
                continue
            }
            let clientSequence: Int64
            if let existing = sequenceByOperationID[operation.id] {
                clientSequence = existing
            } else {
                clientSequence = try FarmStorageRouter.takeNextOperationSequence(
                    farmID: farmID,
                    operationID: operation.id,
                    context: context
                )
                sequenceByOperationID[operation.id] = clientSequence
            }

            var envelope = CloudOperationEnvelope(
                farmID: operation.farmID,
                entityID: entityID,
                entityType: operation.entityType,
                schemaVersion: operation.schemaVersion,
                revision: operation.resultingRevision,
                baseRevision: operation.baseRevision,
                operationID: operation.id,
                modifiedAt: operation.occurredAt,
                modifiedByAccountID: operation.accountID,
                modifiedByDeviceID: identity.deviceID,
                payload: operation.payload,
                payloadDigest: operation.payloadDigest,
                capabilityCertificate: "supabase-authenticated-member",
                operationSignature: Data(),
                deletedAt: tombstoneByOperationID[operation.id]?.deletedAt
            )
            let signature = try await deviceIdentity.sign(envelope.canonicalSigningData)
            envelope = CloudOperationEnvelope(
                farmID: envelope.farmID,
                entityID: envelope.entityID,
                entityType: envelope.entityType,
                schemaVersion: envelope.schemaVersion,
                revision: envelope.revision,
                baseRevision: envelope.baseRevision,
                operationID: envelope.operationID,
                modifiedAt: envelope.modifiedAt,
                modifiedByAccountID: envelope.modifiedByAccountID,
                modifiedByDeviceID: envelope.modifiedByDeviceID,
                payload: envelope.payload,
                payloadDigest: envelope.payloadDigest,
                capabilityCertificate: envelope.capabilityCertificate,
                operationSignature: signature,
                deletedAt: envelope.deletedAt
            )
            operation.modifiedByDeviceID = identity.deviceID
            operation.capabilityCertificate = envelope.capabilityCertificate
            operation.operationSignature = signature
            item.capabilityCertificate = envelope.capabilityCertificate
            item.operationSignature = signature
            item.statusRawValue = OutboxStatus.uploading.rawValue
            item.lastAttemptAt = now
            item.attemptCount += 1
            item.errorMessage = nil
            pending.append(FarmRemotePendingOperation(
                envelope: envelope,
                clientSequence: clientSequence
            ))
            outboxIDs[operation.id] = item.id
        }
        try context.save()
        return PreparedBatch(operations: pending, outboxIDs: outboxIDs)
    }

    private func finalizePush(
        farmID: UUID,
        prepared: PreparedBatch,
        result: FarmRemoteOperationPushResult
    ) throws {
        let context = ModelContext(container)
        let itemIDs = Set(prepared.outboxIDs.values)
        let items = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            itemIDs.contains($0.id)
        }
        let receiptByOperationID = Dictionary(
            uniqueKeysWithValues: result.receipts.map { ($0.operationID, $0) }
        )
        for item in items {
            if let receipt = receiptByOperationID[item.operationID] {
                item.statusRawValue = OutboxStatus.confirmed.rawValue
                item.remoteReceiptData = try JSONEncoder.cloud.encode(receipt)
                item.errorMessage = nil
                item.nextRetryAt = nil
            } else if item.operationID == result.conflictOperationID {
                item.statusRawValue = OutboxStatus.blockedConflict.rawValue
                item.errorMessage = result.conflictCode ?? "base_revision_mismatch"
                item.nextRetryAt = nil
            }
        }
        if let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>()).first(where: {
            $0.farmID == farmID && $0.provider == .supabase
        }) {
            binding.lastSuccessfulSyncAt = .now
            binding.lastErrorCode = result.conflictCode
            binding.updatedAt = .now
        }
        try context.save()
    }

    private func markPreparedBatchRetryable(
        _ prepared: PreparedBatch,
        error: Error
    ) throws {
        let context = ModelContext(container)
        let itemIDs = Set(prepared.outboxIDs.values)
        let items = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            itemIDs.contains($0.id)
        }
        for item in items where item.status == .uploading {
            item.statusRawValue = OutboxStatus.retryableFailure.rawValue
            item.errorMessage = error.localizedDescription
            item.nextRetryAt = .now.addingTimeInterval(Self.retryDelay(
                attemptCount: item.attemptCount
            ))
        }
        try context.save()
    }

    private func pullUntilCurrent(
        farmID: UUID,
        generation: Int,
        startingCursor: Int
    ) async throws -> (operationCount: Int, conflictCount: Int, cursorRevision: Int) {
        var cursor = startingCursor
        var operationCount = 0
        var conflictCount = 0
        var hasMore = true

        while hasMore {
            try Task.checkCancellation()
            let page = try await transport.pullOperations(
                farmID: farmID,
                authorityGeneration: generation,
                after: cursor,
                limit: 200
            )
            let applied = try applyPulledPage(
                page.operations,
                farmID: farmID,
                cursorRevision: page.cursorRevision
            )
            operationCount += page.operations.count
            conflictCount += applied
            cursor = page.cursorRevision
            hasMore = page.hasMore
        }
        return (operationCount, conflictCount, cursor)
    }

    private func applyPulledPage(
        _ envelopes: [CloudOperationEnvelope],
        farmID: UUID,
        cursorRevision: Int
    ) throws -> Int {
        let context = ModelContext(container)
        let service = RemoteDomainApplyService()
        var conflictCount = 0
        var rebuildFrom: Date?
        let existingOperationIDs = Set(
            try context.fetch(FetchDescriptor<DomainOperation>())
                .filter { $0.farmID == farmID }
                .map(\.id)
        )

        for envelope in envelopes {
            guard envelope.farmID == farmID else {
                throw FarmRemoteSyncError.malformedRemoteOperation
            }
            let outcome = try service.apply(envelope, context: context)
            switch outcome {
            case .applied(let changedAt):
                if let changedAt {
                    rebuildFrom = min(rebuildFrom ?? changedAt, changedAt)
                }
            case .duplicate:
                break
            case .conflict(let localRevision):
                conflictCount += 1
                let local = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
                    $0.farmID == farmID &&
                        $0.entityID == envelope.entityID &&
                        $0.resultingRevision == localRevision
                }.max(by: { $0.createdAt < $1.createdAt })
                let conflict = SyncConflictRecord(
                    farmID: farmID,
                    entityID: envelope.entityID,
                    entityType: envelope.entityType,
                    localRevision: localRevision,
                    remoteRevision: envelope.revision,
                    localPayload: local?.payload ?? Data(),
                    remotePayload: envelope.payload,
                    remoteAccountID: envelope.modifiedByAccountID,
                    remoteDeviceID: envelope.modifiedByDeviceID,
                    reasonCode: "supabaseBaseRevisionMismatch"
                )
                conflict.remoteEnvelopeData = try JSONEncoder.cloud.encode(envelope)
                context.insert(conflict)
            }

            if !existingOperationIDs.contains(envelope.operationID) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let payload = try decoder.decode(
                    FarmCommandCloudPayload.self,
                    from: envelope.payload
                )
                let operation = DomainOperation(
                    id: envelope.operationID,
                    farmID: envelope.farmID,
                    accountID: envelope.modifiedByAccountID,
                    kind: payload.kind,
                    occurredAt: envelope.modifiedAt,
                    summary: "Supabase 同步：\(payload.kind.rawValue)",
                    entityType: envelope.entityType,
                    entityID: envelope.entityID,
                    baseRevision: envelope.baseRevision,
                    resultingRevision: envelope.revision,
                    payload: envelope.payload
                )
                operation.modifiedByDeviceID = envelope.modifiedByDeviceID
                operation.capabilityCertificate = envelope.capabilityCertificate
                operation.operationSignature = envelope.operationSignature
                context.insert(operation)
            }
        }

        if let rebuildFrom {
            try FarmHistoryRebuilder().rebuild(
                farmID: farmID,
                context: context,
                from: rebuildFrom
            )
        }
        guard let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>()).first(where: {
            $0.farmID == farmID && $0.provider == .supabase
        }) else {
            throw FarmRemoteSyncError.bindingMissing
        }
        binding.lastPulledRevision = cursorRevision
        binding.lastSuccessfulSyncAt = .now
        binding.lastErrorCode = nil
        binding.updatedAt = .now
        try context.save()
        return conflictCount
    }

    nonisolated static func retryDelay(attemptCount: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [5, 15, 30, 60, 120, 300]
        return schedule[min(max(0, attemptCount - 1), schedule.count - 1)]
    }
}
