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
    case conflictingOperationCopies
    case malformedRemoteOperation
    case remoteOperationApplyFailed(
        operationID: UUID,
        entityID: UUID,
        baseRevision: Int,
        resultingRevision: Int,
        detail: String
    )

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
        case .conflictingOperationCopies:
            "同一操作标识存在内容不一致的本地副本，已停止自动上传。"
        case .malformedRemoteOperation:
            "Supabase 返回的操作无法写入本地历史。"
        case .remoteOperationApplyFailed(
            let operationID,
            let entityID,
            let baseRevision,
            let resultingRevision,
            let detail
        ):
            "Supabase 操作 \(operationID.uuidString.lowercased()) 无法应用到实体 " +
                "\(entityID.uuidString.lowercased())（\(baseRevision)→" +
                "\(resultingRevision)）：\(detail)"
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
        let outboxIDs: [UUID: [UUID]]
    }

    private let container: ModelContainer
    private let transport: any FarmRemoteTransport
    private let deviceIdentity: DeviceIdentityActor
    private let shouldSuspendNetwork: @Sendable () -> Bool

    init(
        container: ModelContainer,
        transport: any FarmRemoteTransport,
        deviceIdentity: DeviceIdentityActor = .shared,
        shouldSuspendNetwork: @escaping @Sendable () -> Bool = { false }
    ) {
        self.container = container
        self.transport = transport
        self.deviceIdentity = deviceIdentity
        self.shouldSuspendNetwork = shouldSuspendNetwork
    }

    func synchronize(
        farmID: UUID,
        maxOutboxItems: Int = 25
    ) async throws -> FarmRemoteSyncResult {
        try checkNetworkAvailability()
        try await repairLocalDeliveryFacts(farmID: farmID)
        try checkNetworkAvailability()
        let binding = try bindingSnapshot(farmID: farmID)
        let prepared = try await preparePendingBatch(
            farmID: farmID,
            generation: binding.generation,
            limit: min(max(1, maxOutboxItems), 25)
        )

        var uploadedCount = 0
        var conflictCount = 0
        if !prepared.operations.isEmpty {
            try checkNetworkAvailability()
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

        try checkNetworkAvailability()
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

    private func checkNetworkAvailability() throws {
        if Task.isCancelled || shouldSuspendNetwork() {
            throw CancellationError()
        }
    }

    private func repairLocalDeliveryFacts(farmID: UUID) async throws {
        let container = self.container
        try await MainActor.run {
            let context = ModelContext(container)
            let service = FarmCommandService()
            _ = try service.repairMissingCompositeChildDeliveryOperations(
                farmID: farmID,
                context: context
            )
            let blocked = try context.fetch(FetchDescriptor<OutboxItem>()).first {
                $0.farmID == farmID &&
                    $0.deliveryProvider == .supabase &&
                    $0.status == .blockedConflict
            }
            guard let blocked,
                  let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: {
                    $0.id == farmID && $0.deletedAt == nil
                  }) else {
                return
            }
            _ = try service.repairBlockedLegacyPhotoFilenameTombstones(
                in: FarmContext(
                    accountID: blocked.accountID,
                    farmID: farmID,
                    role: farm.role
                ),
                context: context
            )
        }
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

        var selectedOperationIDs: [UUID] = []
        var selectedByOperationID: [UUID: [OutboxItem]] = [:]
        for item in eligible {
            if selectedByOperationID[item.operationID] != nil {
                selectedByOperationID[item.operationID, default: []].append(item)
            } else if selectedOperationIDs.count < limit {
                selectedOperationIDs.append(item.operationID)
                selectedByOperationID[item.operationID] = [item]
            }
        }
        guard !selectedOperationIDs.isEmpty else {
            return PreparedBatch(operations: [], outboxIDs: [:])
        }

        let operationIDs = Set(selectedOperationIDs)
        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            operationIDs.contains($0.id)
        }
        var operationsByID: [UUID: DomainOperation] = [:]
        var conflictingOperationIDs = Set<UUID>()
        for operation in operations {
            if let existing = operationsByID[operation.id] {
                if !Self.haveSameImmutableContent(existing, operation) {
                    conflictingOperationIDs.insert(operation.id)
                } else if operation.createdAt < existing.createdAt {
                    operationsByID[operation.id] = operation
                }
            } else {
                operationsByID[operation.id] = operation
            }
        }
        let tombstoneDeletedAtByOperationID = Self.tombstoneDeletedAtByOperationID(
            try context.fetch(FetchDescriptor<TombstoneRecord>()),
            farmID: farmID,
            operationIDs: operationIDs
        )
        let identity = try await deviceIdentity.identity()
        var pending: [FarmRemotePendingOperation] = []
        var outboxIDs: [UUID: [UUID]] = [:]

        for operationID in selectedOperationIDs {
            guard let items = selectedByOperationID[operationID] else { continue }
            guard !conflictingOperationIDs.contains(operationID) else {
                for item in items {
                    item.statusRawValue = OutboxStatus.blockedConflict.rawValue
                    item.errorMessage = FarmRemoteSyncError.conflictingOperationCopies.localizedDescription
                }
                continue
            }
            guard let operation = operationsByID[operationID] else {
                for item in items {
                    item.statusRawValue = OutboxStatus.blockedConflict.rawValue
                    item.errorMessage = FarmRemoteSyncError.operationMissing.localizedDescription
                }
                continue
            }
            guard let entityID = operation.entityID else {
                for item in items {
                    item.statusRawValue = OutboxStatus.blockedConflict.rawValue
                    item.errorMessage = FarmRemoteSyncError.operationEntityMissing.localizedDescription
                }
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
                deletedAt: tombstoneDeletedAtByOperationID[operation.id]
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
            for item in items {
                item.capabilityCertificate = envelope.capabilityCertificate
                item.operationSignature = signature
                item.statusRawValue = OutboxStatus.uploading.rawValue
                item.lastAttemptAt = now
                item.attemptCount += 1
                item.errorMessage = nil
            }
            pending.append(FarmRemotePendingOperation(
                envelope: envelope,
                clientSequence: clientSequence
            ))
            outboxIDs[operation.id] = items.map(\.id)
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
        let itemIDs = Set(prepared.outboxIDs.values.flatMap { $0 })
        let items = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            itemIDs.contains($0.id)
        }
        var receiptByOperationID: [UUID: FarmRemoteOperationReceipt] = [:]
        for receipt in result.receipts {
            if let existing = receiptByOperationID[receipt.operationID] {
                if receipt.revision > existing.revision ||
                    (receipt.revision == existing.revision &&
                        receipt.serverReceivedAt > existing.serverReceivedAt) {
                    receiptByOperationID[receipt.operationID] = receipt
                }
            } else {
                receiptByOperationID[receipt.operationID] = receipt
            }
        }
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
        try unblockProfileUpdatesAfterCreatedSheep(
            farmID: farmID,
            receipts: result.receipts,
            context: context
        )
        if let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>()).first(where: {
            $0.farmID == farmID && $0.provider == .supabase
        }) {
            binding.lastSuccessfulSyncAt = .now
            binding.lastErrorCode = result.conflictCode
            binding.updatedAt = .now
        }
        try context.save()
    }

    private func unblockProfileUpdatesAfterCreatedSheep(
        farmID: UUID,
        receipts: [FarmRemoteOperationReceipt],
        context: ModelContext
    ) throws {
        let receiptIDs = Set(receipts.map(\.operationID))
        guard !receiptIDs.isEmpty else { return }
        let createdSheepIDs = Set<UUID>(try context.fetch(FetchDescriptor<DomainOperation>()).compactMap {
            guard $0.farmID == farmID,
                  receiptIDs.contains($0.id),
                  $0.kindRawValue == DomainOperationKind.addSheep.rawValue else {
                return nil
            }
            return $0.entityID
        })
        guard !createdSheepIDs.isEmpty else { return }
        let blockedItems = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farmID &&
                $0.deliveryProvider == .supabase &&
                $0.status == .blockedConflict &&
                $0.errorMessage == "base_revision_mismatch" &&
                $0.entityID.map(createdSheepIDs.contains) == true
        }
        let blockedOperationIDs = Set<UUID>(blockedItems.map(\.operationID))
        let profileOperationIDs = Set<UUID>(try context.fetch(FetchDescriptor<DomainOperation>()).compactMap {
            guard blockedOperationIDs.contains($0.id),
                  $0.kindRawValue == DomainOperationKind.updateSheepProfile.rawValue else {
                return nil
            }
            return $0.id
        })
        for item in blockedItems where profileOperationIDs.contains(item.operationID) {
            item.statusRawValue = OutboxStatus.pending.rawValue
            item.errorMessage = nil
            item.nextRetryAt = nil
        }
    }

    private func markPreparedBatchRetryable(
        _ prepared: PreparedBatch,
        error: Error
    ) throws {
        let context = ModelContext(container)
        let itemIDs = Set(prepared.outboxIDs.values.flatMap { $0 })
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

    static func tombstoneDeletedAtByOperationID(
        _ tombstones: [TombstoneRecord],
        farmID: UUID,
        operationIDs: Set<UUID>
    ) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for tombstone in tombstones where tombstone.farmID == farmID {
            guard let operationID = tombstone.operationID,
                  operationIDs.contains(operationID) else {
                continue
            }
            if let existing = result[operationID] {
                result[operationID] = min(existing, tombstone.deletedAt)
            } else {
                result[operationID] = tombstone.deletedAt
            }
        }
        return result
    }

    private static func haveSameImmutableContent(
        _ lhs: DomainOperation,
        _ rhs: DomainOperation
    ) -> Bool {
        lhs.farmID == rhs.farmID &&
            lhs.accountID == rhs.accountID &&
            lhs.kindRawValue == rhs.kindRawValue &&
            lhs.occurredAt == rhs.occurredAt &&
            lhs.schemaVersion == rhs.schemaVersion &&
            lhs.entityType == rhs.entityType &&
            lhs.entityID == rhs.entityID &&
            lhs.baseRevision == rhs.baseRevision &&
            lhs.resultingRevision == rhs.resultingRevision &&
            lhs.payloadDigest == rhs.payloadDigest &&
            lhs.payload == rhs.payload
    }

    private func pullUntilCurrent(
        farmID: UUID,
        generation: Int,
        startingCursor: Int
    ) async throws -> (operationCount: Int, conflictCount: Int, cursorRevision: Int) {
        var cursor = startingCursor
        var operationCount = 0
        var conflictCount = 0
        var pageLimit = 200

        while true {
            try Task.checkCancellation()
            let page = try await transport.pullOperations(
                farmID: farmID,
                authorityGeneration: generation,
                after: cursor,
                limit: pageLimit
            )
            guard !page.operations.isEmpty else {
                cursor = max(cursor, page.cursorRevision)
                try markSuccessfulNoOpPull(
                    farmID: farmID,
                    generation: generation,
                    cursorRevision: cursor
                )
                return (operationCount, conflictCount, cursor)
            }
            let applied: Int
            do {
                applied = try applyPulledPage(
                    page.operations,
                    farmID: farmID,
                    cursorRevision: page.cursorRevision
                )
            } catch {
                guard pageLimit > 1 else { throw error }
                pageLimit = max(1, pageLimit / 2)
                continue
            }
            operationCount += page.operations.count
            conflictCount += applied
            cursor = page.cursorRevision
            guard page.hasMore else {
                return (operationCount, conflictCount, cursor)
            }
            pageLimit = min(200, pageLimit * 2)
        }
    }

    private func markSuccessfulNoOpPull(
        farmID: UUID,
        generation: Int,
        cursorRevision: Int
    ) throws {
        let context = ModelContext(container)
        guard let binding = try context.fetch(
            FetchDescriptor<FarmRemoteBinding>()
        ).first(where: {
            $0.farmID == farmID &&
                $0.provider == .supabase &&
                $0.state == .active &&
                $0.authorityGeneration == generation
        }) else {
            throw FarmRemoteSyncError.bindingMissing
        }
        binding.lastPulledRevision = max(
            binding.lastPulledRevision,
            cursorRevision
        )
        binding.lastSuccessfulSyncAt = .now
        binding.lastErrorCode = nil
        binding.updatedAt = .now
        try context.save()
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
            let outcome: RemoteApplyOutcome
            do {
                outcome = try service.apply(envelope, context: context)
            } catch {
                throw FarmRemoteSyncError.remoteOperationApplyFailed(
                    operationID: envelope.operationID,
                    entityID: envelope.entityID,
                    baseRevision: envelope.baseRevision,
                    resultingRevision: envelope.revision,
                    detail: error.localizedDescription
                )
            }
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

            try supersedeBlockedDeletionOperations(
                confirmedBy: envelope,
                context: context
            )

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

    private func supersedeBlockedDeletionOperations(
        confirmedBy envelope: CloudOperationEnvelope,
        context: ModelContext
    ) throws {
        let payload = try Self.decodeCloudPayload(envelope.payload)
        guard payload.kind == DomainOperationKind.tombstoneEntity,
              payload.strings["entityType"] == envelope.entityType,
              payload.identifiers["entityID"] == envelope.entityID else {
            return
        }
        let blockedItems = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == envelope.farmID &&
                $0.deliveryProvider == .supabase &&
                $0.status == .blockedConflict &&
                $0.entityID == envelope.entityID &&
                $0.entityType == envelope.entityType
        }
        guard !blockedItems.isEmpty else { return }
        let operationIDs = Set<UUID>(blockedItems.map(\.operationID))
        let deletionOperationIDs = Set<UUID>(try context.fetch(FetchDescriptor<DomainOperation>()).compactMap {
            guard operationIDs.contains($0.id),
                  $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
                  let localPayload = try? Self.decodeCloudPayload($0.payload),
                  localPayload.strings["entityType"] == envelope.entityType,
                  localPayload.identifiers["entityID"] == envelope.entityID else {
                return nil
            }
            return $0.id
        })
        for item in blockedItems where deletionOperationIDs.contains(item.operationID) {
            item.statusRawValue = item.operationID == envelope.operationID
                ? OutboxStatus.confirmed.rawValue
                : OutboxStatus.supersededRemoteAuthority.rawValue
            item.errorMessage = item.operationID == envelope.operationID
                ? nil
                : "superseded_by_remote_operation:\(envelope.operationID.uuidString.lowercased())"
            item.nextRetryAt = nil
        }
    }

    nonisolated private static func decodeCloudPayload(
        _ data: Data
    ) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }

    nonisolated static func retryDelay(attemptCount: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [5, 15, 30, 60, 120, 300]
        return schedule[min(max(0, attemptCount - 1), schedule.count - 1)]
    }
}
