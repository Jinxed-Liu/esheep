import Foundation
import SwiftData

enum FarmStorageMode: String, Codable, CaseIterable, Sendable {
    case localOnly
    /// Read-only compatibility marker for stores created before the old provider was
    /// removed. Startup cleanup deletes farms carrying this raw value before
    /// any storage route can use it.
    case retiredAppleCloud = "iCloud"
    /// Current eSheep+ Cloud protocol. The legacy provider value remains
    /// decodable only so V1 farms can be migrated and audited safely.
    case eSheepCloud
    case supabase

    var deliveryProvider: FarmRemoteProvider? {
        switch self {
        case .localOnly: nil
        case .retiredAppleCloud: nil
        case .eSheepCloud: .eSheepCloud
        case .supabase: .supabase
        }
    }
}

enum FarmRemoteProvider: String, Codable, CaseIterable, Sendable {
    /// Legacy persisted value used only to identify records for deletion.
    case retiredAppleCloud = "iCloud"
    case eSheepCloud
    case supabase
}

enum FarmStorageTransitionState: String, Codable, Sendable {
    case idle
    case preparing
    case uploadingBaseline
    case rebuildingStagingStore
    case verifying
    case committingAuthority
    case drainingOperations
    case archivingSource
    case readOnlyMigration
    case failed

    var isMigrating: Bool {
        ![.idle, .readOnlyMigration, .failed].contains(self)
    }
}

enum FarmRemoteBindingState: String, Codable, Sendable {
    case preparing
    case active
    case readOnly
    case archived
    case accessRevoked
    case failed
}

enum FarmRemoteRestoreState: String, Codable, CaseIterable, Sendable {
    case discovering
    case downloadingCheckpoint
    case rebuildingStaging
    case downloadingAssets
    case promoting
    case catchingUp
    case completed
    case failed

    var isTerminal: Bool {
        self == .completed
    }

    var displayName: String {
        switch self {
        case .discovering: "正在发现云端牧场"
        case .downloadingCheckpoint: "正在下载检查点"
        case .rebuildingStaging: "正在重建临时数据库"
        case .downloadingAssets: "正在下载照片"
        case .promoting: "正在切换本地数据库"
        case .catchingUp: "正在补拉最新操作"
        case .completed: "云端牧场恢复完成"
        case .failed: "云端牧场恢复失败"
        }
    }
}

@Model
final class FarmStorageProfile {
    var id: UUID
    var farmID: UUID
    var modeRawValue: String
    var transitionStateRawValue: String
    var authorityGeneration: Int
    var migrationID: UUID?
    var sourceModeRawValue: String?
    var targetModeRawValue: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        mode: FarmStorageMode,
        transitionState: FarmStorageTransitionState = .idle,
        authorityGeneration: Int = 0,
        migrationID: UUID? = nil
    ) {
        self.id = id
        self.farmID = farmID
        self.modeRawValue = mode.rawValue
        self.transitionStateRawValue = transitionState.rawValue
        self.authorityGeneration = max(0, authorityGeneration)
        self.migrationID = migrationID
        self.createdAt = .now
        self.updatedAt = .now
    }

    var mode: FarmStorageMode {
        FarmStorageMode(rawValue: modeRawValue) ?? .localOnly
    }

    var transitionState: FarmStorageTransitionState {
        FarmStorageTransitionState(rawValue: transitionStateRawValue) ?? .failed
    }

    var sourceMode: FarmStorageMode? {
        sourceModeRawValue.flatMap(FarmStorageMode.init(rawValue:))
    }

    var targetMode: FarmStorageMode? {
        targetModeRawValue.flatMap(FarmStorageMode.init(rawValue:))
    }
}

@Model
final class FarmRemoteBinding {
    var id: UUID
    var farmID: UUID
    var ownerAccountID: UUID
    var providerRawValue: String
    var stateRawValue: String
    var authorityGeneration: Int
    var remoteFarmID: String?
    var remoteLocatorData: Data?
    var lastPulledRevision: Int
    var lastSuccessfulSyncAt: Date?
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        ownerAccountID: UUID,
        provider: FarmRemoteProvider,
        state: FarmRemoteBindingState = .preparing,
        authorityGeneration: Int = 0,
        remoteFarmID: String? = nil,
        remoteLocatorData: Data? = nil
    ) {
        self.id = id
        self.farmID = farmID
        self.ownerAccountID = ownerAccountID
        self.providerRawValue = provider.rawValue
        self.stateRawValue = state.rawValue
        self.authorityGeneration = max(0, authorityGeneration)
        self.remoteFarmID = remoteFarmID
        self.remoteLocatorData = remoteLocatorData
        self.lastPulledRevision = 0
        self.createdAt = .now
        self.updatedAt = .now
    }

    var provider: FarmRemoteProvider {
        FarmRemoteProvider(rawValue: providerRawValue) ?? .retiredAppleCloud
    }

    var state: FarmRemoteBindingState {
        FarmRemoteBindingState(rawValue: stateRawValue) ?? .failed
    }
}

/// Sequence metadata is stored outside the immutable V3 operation and Outbox
/// entities. Development V3 has already reached physical devices, so changing
/// those entity hashes in place would make their existing stores unrecognizable.
@Model
final class FarmOperationSequenceCounter {
    var id: UUID
    var farmID: UUID
    var nextSequence: Int64

    init(
        id: UUID = UUID(),
        farmID: UUID,
        nextSequence: Int64 = 1
    ) {
        self.id = id
        self.farmID = farmID
        self.nextSequence = max(1, nextSequence)
    }
}

@Model
final class FarmOperationSequenceRecord {
    var id: UUID
    var farmID: UUID
    var operationID: UUID
    var clientSequence: Int64

    init(
        id: UUID = UUID(),
        farmID: UUID,
        operationID: UUID,
        clientSequence: Int64
    ) {
        self.id = id
        self.farmID = farmID
        self.operationID = operationID
        self.clientSequence = max(1, clientSequence)
    }
}

/// Durable, provider-neutral progress for a local-to-cloud baseline migration.
///
/// The baseline package is written before any remote request. Progress is then
/// advanced only after the corresponding remote acknowledgement has been
/// persisted, which makes a killed app resume the exact same package and
/// operation IDs instead of regenerating a second baseline.
@Model
final class FarmBaselineMigrationRecord {
    var id: UUID
    var farmID: UUID
    var migrationID: UUID
    var frozenOperationSequence: Int64
    var packageRelativePath: String
    var packageDigest: String
    var confirmedBatchCount: Int
    var confirmedOperationCount: Int
    var uploadedAssetCount: Int
    var serverRevision: Int
    var checkpointID: UUID?
    var operationCount: Int
    var entityCount: Int
    var tombstoneCount: Int
    var assetCount: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        migrationID: UUID,
        frozenOperationSequence: Int64,
        packageRelativePath: String,
        packageDigest: String,
        confirmedBatchCount: Int = 0,
        confirmedOperationCount: Int = 0,
        uploadedAssetCount: Int = 0,
        serverRevision: Int = 0,
        checkpointID: UUID? = nil,
        operationCount: Int,
        entityCount: Int,
        tombstoneCount: Int,
        assetCount: Int,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.migrationID = migrationID
        self.frozenOperationSequence = max(0, frozenOperationSequence)
        self.packageRelativePath = packageRelativePath
        self.packageDigest = packageDigest
        self.confirmedBatchCount = max(0, confirmedBatchCount)
        self.confirmedOperationCount = max(0, confirmedOperationCount)
        self.uploadedAssetCount = max(0, uploadedAssetCount)
        self.serverRevision = max(0, serverRevision)
        self.checkpointID = checkpointID
        self.operationCount = max(0, operationCount)
        self.entityCount = max(0, entityCount)
        self.tombstoneCount = max(0, tombstoneCount)
        self.assetCount = max(0, assetCount)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Durable second-device restore state.
///
/// The record exists before a checkpoint request and remains non-completed
/// until the staging store, assets, authoritative cache and cursor have all
/// passed verification. RootView excludes farms with a non-completed record,
/// so resumable promotion can never expose a half-restored farm.
@Model
final class FarmRemoteRestoreRecord {
    var id: UUID
    var accountID: UUID
    /// The immutable owner encoded by the remote registry and checkpoint.
    /// This can differ from `accountID` for invited members.
    var ownerAccountID: UUID?
    /// Durable membership identity required to resume a member restore after
    /// process termination without falling back to owner semantics.
    var memberRoleRawValue: String?
    var serverMembershipID: String?
    var farmID: UUID
    var authorityGeneration: Int
    var stateRawValue: String
    var checkpointID: UUID?
    var checkpointMigrationID: UUID?
    var checkpointRelativePath: String?
    var checkpointDigest: String?
    var checkpointRevision: Int
    var targetCursorRevision: Int
    var currentCursorRevision: Int
    var totalEntityCount: Int
    var restoredEntityCount: Int
    var totalAssetCount: Int
    var downloadedAssetCount: Int
    var promotedAssetCount: Int
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        accountID: UUID,
        farmID: UUID,
        authorityGeneration: Int,
        ownerAccountID: UUID? = nil,
        memberRole: FarmRole? = nil,
        serverMembershipID: String? = nil,
        state: FarmRemoteRestoreState = .discovering,
        targetCursorRevision: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.ownerAccountID = ownerAccountID
        self.memberRoleRawValue = memberRole?.rawValue
        self.serverMembershipID = serverMembershipID
        self.farmID = farmID
        self.authorityGeneration = max(0, authorityGeneration)
        self.stateRawValue = state.rawValue
        self.checkpointRevision = 0
        self.targetCursorRevision = max(0, targetCursorRevision)
        self.currentCursorRevision = 0
        self.totalEntityCount = 0
        self.restoredEntityCount = 0
        self.totalAssetCount = 0
        self.downloadedAssetCount = 0
        self.promotedAssetCount = 0
        self.createdAt = .now
        self.updatedAt = .now
    }

    var state: FarmRemoteRestoreState {
        FarmRemoteRestoreState(rawValue: stateRawValue) ?? .failed
    }

    var memberRole: FarmRole? {
        memberRoleRawValue.flatMap(FarmRole.init(rawValue:))
    }

    func advance(to state: FarmRemoteRestoreState) {
        stateRawValue = state.rawValue
        lastErrorCode = nil
        updatedAt = .now
        if state == .completed {
            completedAt = .now
        }
    }
}

struct FarmStorageRoute: Equatable, Sendable {
    let mode: FarmStorageMode
    let transitionState: FarmStorageTransitionState
    let authorityGeneration: Int
    let migrationID: UUID?
    let targetMode: FarmStorageMode?

    var deliveryProvider: FarmRemoteProvider? {
        // A persisted pre-removal transition must never revive the retired
        // provider or use it as a migration source/target. Startup cleanup
        // removes that farm before normal app work begins; this guard keeps
        // the route fail-closed if any caller observes it earlier.
        guard mode != .retiredAppleCloud,
              targetMode != .retiredAppleCloud else {
            return nil
        }
        if transitionState.isMigrating {
            return targetMode?.deliveryProvider
        }
        return mode.deliveryProvider
    }

    var requiresOutbox: Bool {
        deliveryProvider != nil
    }

    /// Operations created after migration begins belong only to the target
    /// authority. They use the next generation even before the atomic switch,
    /// so the source provider can never accept them accidentally.
    var deliveryAuthorityGeneration: Int {
        switch transitionState {
        case .preparing, .uploadingBaseline, .rebuildingStagingStore, .verifying, .committingAuthority:
            targetMode == nil ? authorityGeneration : authorityGeneration + 1
        case .idle, .drainingOperations, .archivingSource, .readOnlyMigration, .failed:
            authorityGeneration
        }
    }
}

enum FarmStorageRouter {
    static func takeNextOperationSequence(
        farmID: UUID,
        operationID: UUID,
        context: ModelContext
    ) throws -> Int64 {
        if let existing = try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
            .first(where: { $0.farmID == farmID && $0.operationID == operationID }) {
            return existing.clientSequence
        }

        let counters = try context.fetch(FetchDescriptor<FarmOperationSequenceCounter>())
        let counter: FarmOperationSequenceCounter
        if let existing = counters.first(where: { $0.farmID == farmID }) {
            counter = existing
        } else {
            let highest = try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
                .lazy
                .filter { $0.farmID == farmID }
                .map(\.clientSequence)
                .max() ?? 0
            counter = FarmOperationSequenceCounter(
                farmID: farmID,
                nextSequence: highest + 1
            )
            context.insert(counter)
        }

        let sequence = max(1, counter.nextSequence)
        counter.nextSequence = sequence + 1
        context.insert(FarmOperationSequenceRecord(
            farmID: farmID,
            operationID: operationID,
            clientSequence: sequence
        ))
        return sequence
    }

    static func operationSequences(
        farmID: UUID,
        context: ModelContext
    ) throws -> [UUID: Int64] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
                .filter { $0.farmID == farmID }
                .map { ($0.operationID, $0.clientSequence) }
        )
    }

    /// Missing profiles are treated as local-only. Cloud delivery must always
    /// be opted into by a current storage profile and an active remote binding.
    static func route(farmID: UUID, context: ModelContext) throws -> FarmStorageRoute {
        if let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>()).first(where: {
            $0.farmID == farmID
        }) {
            return FarmStorageRoute(
                mode: profile.mode,
                transitionState: profile.transitionState,
                authorityGeneration: profile.authorityGeneration,
                migrationID: profile.migrationID,
                targetMode: profile.targetMode
            )
        }

        return FarmStorageRoute(
            mode: .localOnly,
            transitionState: .idle,
            authorityGeneration: 0,
            migrationID: nil,
            targetMode: nil
        )
    }
}
