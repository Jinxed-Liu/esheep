import Foundation
import SwiftData

enum ESheepCloudDeviceIdentityStore {
    static func deviceID(accountID: UUID) throws -> UUID {
        let scope = DeviceIdentityActor.currentAccountScope() ?? accountID
        let account = DeviceIdentityActor.storageAccountName(
            base: "device-id",
            accountID: scope
        )
        if let data = try SecureAccountStore.data(account: account),
           let text = String(data: data, encoding: .utf8),
           let existing = UUID(uuidString: text) {
            return existing
        }
        let created = UUID()
        try SecureAccountStore.save(
            Data(created.uuidString.lowercased().utf8),
            account: account
        )
        return created
    }
}

enum ESheepCloudIntentWriter {
    @discardableResult
    static func stage(
        draft: ESheepCloudCommandDraftV2,
        commandID: UUID,
        sourceRequestID: UUID,
        bundleID: UUID? = nil,
        farmID: UUID,
        farmGeneration: Int,
        accountID: UUID,
        deviceID: UUID,
        deviceSequence: Int64,
        createdAt: Date = .now,
        prerequisiteCommandIDs: [UUID] = [],
        context: ModelContext
    ) throws -> ESheepCloudPendingIntent {
        guard try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
            .first(where: { $0.id == commandID }) == nil else {
            throw ESheepCloudIntentWriterError.duplicateCommandID
        }

        let farmState = try currentFarmState(
            farmID: farmID,
            farmGeneration: farmGeneration,
            context: context
        )
        guard farmState.activityState == .active else {
            throw ESheepCloudIntentWriterError.farmNotWritable
        }
        guard farmState.integrityState != .failed,
              farmState.activityState != .integrityHold else {
            throw ESheepCloudIntentWriterError.integrityHold
        }

        // Reserve before signing. Keychain shares the device identity lifetime;
        // a transaction rollback may leave a gap, but can never reuse a number.
        let deviceSequence = try ESheepCloudSequenceWatermark.reserve(
            farmID: farmID, deviceID: deviceID, operationID: commandID,
            proposed: deviceSequence, context: context)

        let dependencies = Array(Set(prerequisiteCommandIDs))
            .sorted { $0.uuidString < $1.uuidString }
        try validateDependencies(
            commandID: commandID,
            prerequisiteCommandIDs: dependencies,
            farmID: farmID,
            farmGeneration: farmGeneration,
            accountID: accountID,
            context: context
        )

        let observations = try fieldObservations(
            streams: draft.affectedStreams,
            fieldKeys: draft.affectedFieldKeys,
            farmID: farmID,
            farmGeneration: farmGeneration,
            context: context
        )
        let envelope = try ESheepCloudCommandEnvelopeV2(
            commandID: commandID,
            sourceRequestID: sourceRequestID,
            bundleID: bundleID,
            farmID: farmID,
            farmGeneration: farmGeneration,
            accountID: accountID,
            deviceID: deviceID,
            deviceSequence: deviceSequence,
            createdAt: createdAt,
            occurredAt: draft.occurredAt,
            payload: draft.payload,
            affectedStreams: draft.affectedStreams,
            affectedFields: observations,
            fieldChanges: draft.fieldChanges,
            prerequisiteCommandIDs: dependencies,
            requiredAssetIDs: draft.requiredAssetIDs
        )

        if draft.affectedStreams.count == 1,
           draft.affectedStreams[0].type == "sheepAvatar" {
            try supersedeUnsentAvatarIntents(
                stream: draft.affectedStreams[0],
                farmID: farmID,
                farmGeneration: farmGeneration,
                accountID: accountID,
                exceptCommandID: commandID,
                context: context
            )
        }

        let lifecycle = try initialLifecycle(
            dependencies: dependencies,
            requiredAssetIDs: draft.requiredAssetIDs,
            commandKind: draft.kind,
            farmID: farmID,
            farmGeneration: farmGeneration,
            context: context
        )
        let intent = ESheepCloudPendingIntent(
            commandID: commandID,
            farmID: farmID,
            farmGeneration: farmGeneration,
            accountID: accountID,
            deviceID: deviceID,
            deviceSequence: deviceSequence,
            sourceRequestID: sourceRequestID,
            bundleID: bundleID,
            commandKind: draft.kind,
            commandEnvelopeData: try ESheepCloudCanonicalCodec.encode(envelope),
            commandDigest: envelope.contentDigest,
            affectedStreamsData: try ESheepCloudCanonicalCodec.encode(envelope.affectedStreams),
            affectedFieldsData: try ESheepCloudCanonicalCodec.encode(envelope.affectedFields),
            prerequisiteCommandIDsData: try ESheepCloudCanonicalCodec.encode(dependencies),
            requiredAssetIDsData: try ESheepCloudCanonicalCodec.encode(draft.requiredAssetIDs),
            lifecycle: lifecycle,
            createdAt: createdAt,
            occurredAt: draft.occurredAt
        )
        context.insert(intent)
        farmState.updatedAt = .now
        farmState.lastSafeSaveAt = nil
        return intent
    }

    /// Called inside the original local transaction, before any envelope can
    /// be signed or sent. Never rewrites a previously attempted command.
    static func bindWeaningBundles(commandIDs: [UUID], context: ModelContext) throws {
        guard commandIDs.count > 1 else { return }
        let rows = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            commandIDs.contains($0.id)
        }))
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for index in 0..<(commandIDs.count - 1) {
            guard let first = byID[commandIDs[index]], let second = byID[commandIDs[index + 1]],
                  first.commandKind == "weaning.record", second.commandKind == "transfer.record" else { continue }
            let a = try ESheepCloudCanonicalCodec.decode(ESheepCloudCommandEnvelopeV2.self, from: first.commandEnvelopeData)
            let b = try ESheepCloudCanonicalCodec.decode(ESheepCloudCommandEnvelopeV2.self, from: second.commandEnvelopeData)
            guard case .fact(.recordWeaning(let sheepID, _, let date, _, _, _, _, _, _)) = a.payload,
                  case .fact(.transferSheep(let transferredID, _, let transferredAt, let note)) = b.payload,
                  sheepID == transferredID, date == transferredAt, note == "随断奶事件调舍" else { continue }
            guard first.attemptCount == 0, second.attemptCount == 0,
                  first.bundleID == nil, second.bundleID == nil,
                  a.farmID == b.farmID, a.farmGeneration == b.farmGeneration,
                  a.accountID == b.accountID, a.deviceID == b.deviceID else {
                throw ESheepCloudContractError.malformedPayload
            }
            let bundleID = UUID()
            for (row, old) in [(first, a), (second, b)] {
                let envelope = try ESheepCloudCommandEnvelopeV2(
                    commandID: old.commandID, sourceRequestID: old.sourceRequestID, bundleID: bundleID,
                    farmID: old.farmID, farmGeneration: old.farmGeneration, accountID: old.accountID,
                    deviceID: old.deviceID, deviceSequence: old.deviceSequence, createdAt: old.createdAt,
                    occurredAt: old.occurredAt, payload: old.payload, affectedStreams: old.affectedStreams,
                    affectedFields: old.affectedFields, fieldChanges: old.fieldChanges,
                    prerequisiteCommandIDs: old.prerequisiteCommandIDs, requiredAssetIDs: old.requiredAssetIDs)
                row.bundleID = bundleID
                row.commandEnvelopeData = try ESheepCloudCanonicalCodec.encode(envelope)
                row.commandDigest = envelope.contentDigest
            }
        }
    }

    static func refreshReadiness(
        farmID: UUID,
        now: Date = .now,
        context: ModelContext
    ) throws {
        let terminal = [ESheepCloudIntentLifecycle.accepted.rawValue,
                        ESheepCloudIntentLifecycle.rejected.rawValue, ESheepCloudIntentLifecycle.supersededLocally.rawValue]
        let intents = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && !terminal.contains($0.lifecycleRawValue)
        }))
        guard !intents.isEmpty else { return }
        var dependencyIDs = Set<UUID>(), assetIDs = Set<UUID>()
        for intent in intents {
            dependencyIDs.formUnion(try ESheepCloudCanonicalCodec.decode([UUID].self, from: intent.prerequisiteCommandIDsData))
            assetIDs.formUnion(try ESheepCloudCanonicalCodec.decode([UUID].self, from: intent.requiredAssetIDsData))
        }
        let dependencies = Array(dependencyIDs), requiredAssets = Array(assetIDs)
        let dependencyRows = dependencies.isEmpty ? [] : try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && dependencies.contains($0.id)
        }))
        var byID = [UUID: ESheepCloudPendingIntent]()
        for intent in dependencyRows {
            guard byID.updateValue(intent, forKey: intent.id) == nil else { throw ESheepCloudContractError.malformedPayload }
        }
        let assets = requiredAssets.isEmpty ? [] : try context.fetch(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate {
            $0.farmID == farmID && requiredAssets.contains($0.id)
        }))
        var assetByID = [UUID: ESheepCloudAssetState]()
        for asset in assets {
            guard assetByID.updateValue(asset, forKey: asset.id) == nil else { throw ESheepCloudContractError.malformedPayload }
        }

        for intent in intents where
            intent.lifecycle != .needsConfirmation &&
            intent.lifecycle != .sending &&
            intent.lifecycle != .awaitingResult {
            if let nextRetryAt = intent.nextRetryAt, nextRetryAt > now {
                intent.lifecycle = .waitingForNetwork
                continue
            }
            let dependencies = try ESheepCloudCanonicalCodec.decode(
                [UUID].self,
                from: intent.prerequisiteCommandIDsData
            )
            let requiredAssets = try ESheepCloudCanonicalCodec.decode(
                [UUID].self,
                from: intent.requiredAssetIDsData
            )
            guard Set(dependencies).count == dependencies.count,
                  Set(requiredAssets).count == requiredAssets.count else {
                throw ESheepCloudContractError.malformedPayload
            }
            if dependencies.contains(where: { dependencyID in
                guard let dependency = byID[dependencyID] else { return true }
                return dependency.farmGeneration != intent.farmGeneration ||
                    dependency.accountID != intent.accountID ||
                    dependency.lifecycle != .accepted
            }) {
                intent.lifecycle = .waitingForDependency
                continue
            }
            if requiredAssets.contains(where: { assetID in
                guard let asset = assetByID[assetID] else { return true }
                return asset.farmGeneration != intent.farmGeneration ||
                    !assetIsReady(asset, commandKind: intent.commandKind)
            }) {
                intent.lifecycle = .waitingForDependency
                continue
            }
            intent.lifecycle = .ready
        }
    }

    private static func currentFarmState(
        farmID: UUID,
        farmGeneration: Int,
        context: ModelContext
    ) throws -> ESheepCloudFarmState {
        guard let state = try context.fetch(FetchDescriptor<ESheepCloudFarmState>())
            .first(where: {
                $0.farmID == farmID && $0.farmGeneration == farmGeneration
            }) else {
            throw ESheepCloudIntentWriterError.farmStateMissing
        }
        return state
    }

    private static func fieldObservations(
        streams: [ESheepCloudStreamReferenceV2],
        fieldKeys: [String],
        farmID: UUID,
        farmGeneration: Int,
        context: ModelContext
    ) throws -> [ESheepCloudFieldObservationV2] {
        guard !fieldKeys.isEmpty else { return [] }
        guard streams.count == 1,
              Set(fieldKeys).count == fieldKeys.count else {
            throw ESheepCloudContractError.malformedPayload
        }
        let streamType = streams[0].type, streamID = streams[0].id
        let states = try context.fetch(FetchDescriptor<ESheepCloudStreamState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == farmGeneration &&
                $0.streamType == streamType && $0.streamID == streamID
        }))
        var stateByStream = [StreamKey: ESheepCloudStreamState]()
        for state in states {
            let key = StreamKey(type: state.streamType, id: state.streamID)
            guard stateByStream.updateValue(state, forKey: key) == nil else {
                throw ESheepCloudContractError.malformedPayload
            }
        }
        let nullDigest = ESheepCloudValueV2.null.digest

        return try streams.flatMap { stream in
            let state = stateByStream[StreamKey(type: stream.type, id: stream.id)]
            let entries = try ESheepCloudCanonicalCodec.decode(
                [ESheepCloudFieldVersionEntryV2].self,
                from: state?.fieldVersionsData ?? Data("[]".utf8)
            )
            guard Set(entries.map(\.field)).count == entries.count,
                  entries.allSatisfy({ entry in
                      entry.version >= 0 &&
                          entry.valueDigest.range(
                              of: "^[0-9a-f]{64}$",
                              options: .regularExpression
                          ) != nil &&
                          (entry.value == nil || entry.value?.digest == entry.valueDigest)
                  }) else {
                throw ESheepCloudContractError.malformedPayload
            }
            let versions = Dictionary(uniqueKeysWithValues: entries.map { ($0.field, $0) })
            return fieldKeys.map { field in
                ESheepCloudFieldObservationV2(
                    stream: stream,
                    field: field,
                    observedVersion: versions[field]?.version ?? 0,
                    baseValueDigest: versions[field]?.valueDigest ?? nullDigest
                )
            }
        }
    }

    private static func validateDependencies(
        commandID: UUID,
        prerequisiteCommandIDs: [UUID],
        farmID: UUID,
        farmGeneration: Int,
        accountID: UUID,
        context: ModelContext
    ) throws {
        guard !prerequisiteCommandIDs.contains(commandID) else {
            throw ESheepCloudIntentWriterError.dependencyCycle
        }
        let existing = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
            .filter {
                $0.farmID == farmID &&
                    $0.farmGeneration == farmGeneration &&
                    $0.accountID == accountID
            }
        var byID = [UUID: ESheepCloudPendingIntent]()
        for intent in existing {
            guard byID.updateValue(intent, forKey: intent.id) == nil else {
                throw ESheepCloudIntentWriterError.invalidDependency
            }
        }

        guard prerequisiteCommandIDs.allSatisfy({ byID[$0] != nil }) else {
            throw ESheepCloudIntentWriterError.invalidDependency
        }

        func reachesNewCommand(_ currentID: UUID, visited: inout Set<UUID>) throws -> Bool {
            guard visited.insert(currentID).inserted,
                  let current = byID[currentID] else {
                return false
            }
            let next = try ESheepCloudCanonicalCodec.decode(
                [UUID].self,
                from: current.prerequisiteCommandIDsData
            )
            guard Set(next).count == next.count,
                  next.allSatisfy({ byID[$0] != nil || $0 == commandID }) else {
                throw ESheepCloudIntentWriterError.invalidDependency
            }
            if next.contains(commandID) { return true }
            for dependency in next {
                if try reachesNewCommand(dependency, visited: &visited) {
                    return true
                }
            }
            return false
        }

        for dependency in prerequisiteCommandIDs {
            var visited = Set<UUID>()
            if try reachesNewCommand(dependency, visited: &visited) {
                throw ESheepCloudIntentWriterError.dependencyCycle
            }
        }
    }

    private static func initialLifecycle(
        dependencies: [UUID],
        requiredAssetIDs: [UUID],
        commandKind: String,
        farmID: UUID,
        farmGeneration: Int,
        context: ModelContext
    ) throws -> ESheepCloudIntentLifecycle {
        if !dependencies.isEmpty { return .waitingForDependency }
        guard !requiredAssetIDs.isEmpty else { return .ready }
        let assets = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .filter {
                $0.farmID == farmID && $0.farmGeneration == farmGeneration &&
                    requiredAssetIDs.contains($0.id)
            }
        let verified = Set(assets.compactMap { asset -> UUID? in
            assetIsReady(asset, commandKind: commandKind) ? asset.id : nil
        })
        return Set(requiredAssetIDs).isSubset(of: verified) ? .ready : .waitingForDependency
    }

    private static func assetIsReady(
        _ asset: ESheepCloudAssetState,
        commandKind: String
    ) -> Bool {
        let thumbnailReady = asset.thumbnailStateRawValue ==
            ESheepCloudAssetTransferState.verified.rawValue
        let avatarReady = asset.avatarStateRawValue ==
            ESheepCloudAssetTransferState.verified.rawValue
        let originalReady = asset.originalStateRawValue ==
            ESheepCloudAssetTransferState.verified.rawValue
        if commandKind == "photoAsset.register" {
            return thumbnailReady && avatarReady && originalReady
        }
        return avatarReady || originalReady
    }

    private static func supersedeUnsentAvatarIntents(
        stream: ESheepCloudStreamReferenceV2,
        farmID: UUID,
        farmGeneration: Int,
        accountID: UUID,
        exceptCommandID: UUID,
        context: ModelContext
    ) throws {
        let intents = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
        for intent in intents where
            intent.farmID == farmID &&
            intent.farmGeneration == farmGeneration &&
            intent.accountID == accountID &&
            intent.id != exceptCommandID &&
            intent.commandKind.hasPrefix("sheepAvatar.") &&
            intent.attemptCount == 0 &&
            [.ready, .waitingForNetwork, .waitingForDependency].contains(intent.lifecycle) {
            let streams = try ESheepCloudCanonicalCodec.decode(
                [ESheepCloudStreamReferenceV2].self,
                from: intent.affectedStreamsData
            )
            guard streams == [stream] else { continue }
            intent.lifecycle = .supersededLocally
        }
    }

    private struct StreamKey: Hashable {
        let type: String
        let id: UUID
    }
}

enum ESheepCloudIntentWriterError: LocalizedError, Equatable {
    case farmStateMissing
    case farmNotWritable
    case integrityHold
    case duplicateCommandID
    case dependencyCycle
    case invalidDependency

    var errorDescription: String? {
        switch self {
        case .farmStateMissing: "这座牧场尚未准备好使用 eSheep+ 云。"
        case .farmNotWritable: "这座牧场当前只能查看，暂不能保存新内容。"
        case .integrityHold: "eSheep+ 云正在保护这座牧场的数据，请稍后再试。"
        case .duplicateCommandID: "这项操作已经保存，无需重复提交。"
        case .dependencyCycle: "这组操作的先后关系无效，无法安全保存。"
        case .invalidDependency: "这组操作引用了不属于当前账号或牧场版本的前置内容。"
        }
    }
}

/// Stored beside device identity, so reinstalling a database cannot reset the
/// sequence of an existing device. Only a validated status initializes it.
enum ESheepCloudSequenceWatermark {
    private static let lock = NSLock()
    private static func key(farmID: UUID, deviceID: UUID) -> String {
        "esheep-v2-sequence-\(farmID.uuidString.lowercased())-\(deviceID.uuidString.lowercased())"
    }
    static func reconcile(farmID: UUID, deviceID: UUID, floor: Int64) throws {
        try lock.withLock {
            let account = key(farmID: farmID, deviceID: deviceID)
            let current = try SecureAccountStore.data(account: account)
                .flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int64.init) ?? 0
            try SecureAccountStore.save(Data(String(max(current, floor)).utf8), account: account)
        }
    }
    static func reserve(farmID: UUID, deviceID: UUID, operationID: UUID, proposed: Int64, context: ModelContext) throws -> Int64 {
        let reserved = try lock.withLock {
            let account = key(farmID: farmID, deviceID: deviceID)
            guard let data = try SecureAccountStore.data(account: account),
                  let text = String(data: data, encoding: .utf8), let current = Int64(text),
                  current >= 0, current < Int64.max - 1, proposed > 0, proposed < Int64.max - 1 else {
                throw SequenceError.requiresCloudStatus
            }
            let next = max(proposed, current + 1)
            try SecureAccountStore.save(Data(String(next).utf8), account: account)
            return next
        }
        if let record = try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.operationID == operationID
        })).first { record.clientSequence = reserved }
        if let counter = try context.fetch(FetchDescriptor<FarmOperationSequenceCounter>(predicate: #Predicate {
            $0.farmID == farmID
        })).first { counter.nextSequence = max(counter.nextSequence, reserved + 1) }
        return reserved
    }
    enum SequenceError: LocalizedError {
        case requiresCloudStatus
        var errorDescription: String? { "请先连接 eSheep+ 云完成这台设备的保存准备，再录入内容。" }
    }
}
