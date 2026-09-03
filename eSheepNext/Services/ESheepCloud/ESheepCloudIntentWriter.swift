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

    static func refreshReadiness(
        farmID: UUID,
        now: Date = .now,
        context: ModelContext
    ) throws {
        let allFarmIntents = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
            .filter { $0.farmID == farmID }
        let intents = allFarmIntents.filter { !$0.lifecycle.isTerminal }
        // Dependency decisions must include terminal rows. Treating a missing
        // rejected prerequisite as if it were accepted lets a dependent
        // pedigree/state-machine command jump the DAG after a failure.
        var byID = [UUID: ESheepCloudPendingIntent]()
        for intent in allFarmIntents {
            guard byID.updateValue(intent, forKey: intent.id) == nil else {
                throw ESheepCloudContractError.malformedPayload
            }
        }
        let assets = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .filter { $0.farmID == farmID }
        var assetByID = [UUID: ESheepCloudAssetState]()
        for asset in assets {
            guard assetByID.updateValue(asset, forKey: asset.id) == nil else {
                throw ESheepCloudContractError.malformedPayload
            }
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
        let states = try context.fetch(FetchDescriptor<ESheepCloudStreamState>())
            .filter {
                $0.farmID == farmID && $0.farmGeneration == farmGeneration
            }
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
