import CloudKit
import Foundation
import SwiftData

enum CloudRebuildError: LocalizedError, Equatable {
    case featureDisabled
    case bindingMissing
    case sessionMissing
    case sessionNotReady
    case sessionNotResumable
    case lowerMembershipGeneration(cloud: Int, worker: Int)
    case blockingIssues(Int)
    case operationReplayConflict(stage: String, operationID: UUID, baseRevision: Int, localRevision: Int)
    case noAuthoritativeOperations
    case farmMismatch
    case commitInProgress
    case authoritativeRootChanged
    case authoritativeBaselineChanged
    case stagingValidation(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .featureDisabled: "当前构建没有启用 Development 云协作。"
        case .bindingMissing: "当前牧场没有可用于重建的 CloudKit 绑定。"
        case .sessionMissing: "找不到云缓存重建会话。"
        case .sessionNotReady: "重建结果尚未通过校验，不能切换本地缓存。"
        case .sessionNotResumable: "该重建会话不能继续执行。"
        case .lowerMembershipGeneration(let cloud, let worker): "云端成员快照 generation 为 \(cloud)，低于身份服务的 \(worker)。"
        case .blockingIssues(let count): "重建存在 \(count) 个阻断问题。"
        case .operationReplayConflict(let stage, let operationID, let baseRevision, let localRevision):
            "重建重放\(stage)时发生 revision 冲突：operation \(operationID.uuidString.lowercased())，base \(baseRevision)，local \(localRevision)。"
        case .noAuthoritativeOperations: "云端 Zone 中没有可验证的权威业务操作。"
        case .farmMismatch: "重建记录与目标牧场不一致。"
        case .commitInProgress: "当前牧场正在切换已校验缓存，不能同时建立或取消重建会话。"
        case .authoritativeRootChanged: "云端牧场根记录在 staging 完成后已更新，必须重新执行全量重建。"
        case .authoritativeBaselineChanged: "云端迁移基线在 staging 完成后已更新，必须重新执行全量重建。"
        case .stagingValidation(let detail): "staging 牧场校验失败：\(detail)"
        case .cancelled: "重建已取消。"
        }
    }
}

struct CloudRebuildRootSnapshot: Codable, Sendable, Equatable {
    let farmID: UUID
    let name: String
    let ownerAccountID: UUID
    let modifiedAt: Date
    /// ISO-8601 encoding used by older bundles drops fractional seconds. New
    /// bundles retain the exact CloudKit root identity at millisecond precision.
    let modifiedAtMilliseconds: Int64?

    init(
        farmID: UUID,
        name: String,
        ownerAccountID: UUID,
        modifiedAt: Date
    ) {
        self.farmID = farmID
        self.name = name
        self.ownerAccountID = ownerAccountID
        self.modifiedAt = modifiedAt
        self.modifiedAtMilliseconds = Self.milliseconds(modifiedAt)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

struct CloudRebuildBootstrapSnapshot: Codable, Sendable, Equatable {
    let digest: String
    let entityCount: Int
    let photoCount: Int
    /// Optional for decoding version-1 staging bundles created before the
    /// baseline identity was persisted. A missing value means baseline v1.
    let version: Int?
    /// Store the cutoff as integer milliseconds so JSON round-tripping cannot
    /// lose sub-second precision through ISO-8601 date encoding.
    let cutoffAtMilliseconds: Int64?

    init(
        digest: String,
        entityCount: Int,
        photoCount: Int,
        version: Int? = nil,
        cutoffAt: Date? = nil
    ) {
        self.digest = digest
        self.entityCount = entityCount
        self.photoCount = photoCount
        self.version = version
        self.cutoffAtMilliseconds = Self.milliseconds(cutoffAt)
    }

    var normalizedVersion: Int { version ?? 1 }

    var cutoffAt: Date? {
        cutoffAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }

    static func milliseconds(_ date: Date?) -> Int64? {
        date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
    }
}

struct CloudRebuildAssetSnapshot: Codable, Sendable, Equatable {
    let envelope: FarmAssetEnvelope
    let relativePath: String
    let cloudRecordName: String
}

struct CloudRebuildMembershipSnapshot: Codable, Sendable, Equatable {
    let farmID: UUID
    let generation: Int
    let issuedAt: Date
    let payload: Data
    let signedByAccountID: UUID
    let signedByDeviceID: UUID
    let capabilityCertificate: String
    let signature: Data
    let cloudRecordName: String
}

struct CloudRebuildOperationSourceProof: Codable, Sendable, Equatable {
    let recordName: String
    let farmID: UUID
    let operationID: UUID
    let envelopeDigest: String
    let serverChangeTag: String?
    let serverModifiedAtMilliseconds: Int64?

    init(record: CKRecord, envelope: CloudOperationEnvelope) throws {
        recordName = record.recordID.recordName
        farmID = envelope.farmID
        operationID = envelope.operationID
        envelopeDigest = try Self.digest(envelope)
        serverChangeTag = record.recordChangeTag
        serverModifiedAtMilliseconds = record.modificationDate.map {
            Int64(($0.timeIntervalSince1970 * 1_000).rounded())
        }
    }

    func exactlyMatches(record: CKRecord, envelope: CloudOperationEnvelope) throws -> Bool {
        guard record.recordType == CloudRecordType.farmOperation.rawValue,
              record.recordID.recordName == recordName,
              envelope.farmID == farmID,
              envelope.operationID == operationID,
              record.recordChangeTag == serverChangeTag,
              record.modificationDate.map({
                  Int64(($0.timeIntervalSince1970 * 1_000).rounded())
              }) == serverModifiedAtMilliseconds else {
            return false
        }
        // A non-nil CloudKit change tag identifies the exact immutable record
        // version already hashed and validated in the completed rebuild. Local
        // test records have no server tag, so retain the digest fallback.
        if serverChangeTag != nil {
            return true
        }
        return try Self.digest(envelope) == envelopeDigest
    }

    static func digest(_ envelope: CloudOperationEnvelope) throws -> String {
        CloudPayloadDigest.hex(for: try JSONEncoder.cloud.encode(envelope))
    }
}

struct CloudRebuildBundle: Codable, Sendable, Equatable {
    let sessionID: UUID
    let farmID: UUID
    let scope: CloudDatabaseScope
    let root: CloudRebuildRootSnapshot
    /// Version 1 proves every retained envelope was sourced from an immutable
    /// FarmOperation record and any FarmEntity projection was byte-for-byte
    /// equivalent. Older completed bundles remain readable for an engine-only
    /// upgrade, but may never perform a new cache commit.
    let authorityProofVersion: Int?
    /// Exact immutable records observed by the authoritative query, including
    /// trusted pre-cutoff operations intentionally absorbed by a v2 baseline.
    /// The nil-state CKSyncEngine catch-up uses this proof to distinguish old
    /// history from records created after the rebuild snapshot.
    let operationSourceProofs: [CloudRebuildOperationSourceProof]?
    let bootstrap: CloudRebuildBootstrapSnapshot?
    let operations: [CloudOperationEnvelope]
    let assets: [CloudRebuildAssetSnapshot]
    let membershipSnapshot: CloudRebuildMembershipSnapshot?
    let deletedRecordNames: [String]
    let pageCount: Int
    let recordCount: Int
    let createdAt: Date

    init(
        sessionID: UUID,
        farmID: UUID,
        scope: CloudDatabaseScope,
        root: CloudRebuildRootSnapshot,
        authorityProofVersion: Int? = nil,
        operationSourceProofs: [CloudRebuildOperationSourceProof]? = nil,
        bootstrap: CloudRebuildBootstrapSnapshot?,
        operations: [CloudOperationEnvelope],
        assets: [CloudRebuildAssetSnapshot],
        membershipSnapshot: CloudRebuildMembershipSnapshot?,
        deletedRecordNames: [String],
        pageCount: Int,
        recordCount: Int,
        createdAt: Date
    ) {
        self.sessionID = sessionID
        self.farmID = farmID
        self.scope = scope
        self.root = root
        self.authorityProofVersion = authorityProofVersion
        self.operationSourceProofs = operationSourceProofs
        self.bootstrap = bootstrap
        self.operations = operations
        self.assets = assets
        self.membershipSnapshot = membershipSnapshot
        self.deletedRecordNames = deletedRecordNames
        self.pageCount = pageCount
        self.recordCount = recordCount
        self.createdAt = createdAt
    }
}

enum LegacyBootstrapProjectionRepair {
    static let incidentType = "legacyBootstrapProjectionRepairV2"
}

struct CloudRebuildLocalProjectionRepair: Sendable {
    let bundle: CloudRebuildBundle
    let workspace: URL
}

actor CloudRebuildActor {
    static let currentAuthorityProofVersion = 2
    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private let persistence: FarmPersistenceActor
    private let worker: IdentityWorkerClient
    private let mapper = CloudRecordMapper()
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTaskTokens: [UUID: UUID] = [:]
    /// Prevents a second session from superseding a commit while the actor is
    /// re-entrant across the persistence await.
    private var committingFarmIDs = Set<UUID>()

    init(
        modelContainer: ModelContainer,
        persistence: FarmPersistenceActor,
        containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String,
        worker: IdentityWorkerClient = .shared
    ) {
        self.modelContainer = modelContainer
        self.persistence = persistence
        self.cloudContainer = containerIdentifier.flatMap { $0.isEmpty ? nil : CKContainer(identifier: $0) } ?? .default()
        self.worker = worker
    }

    @discardableResult
    func rebuild(farmID: UUID, scope: CloudDatabaseScope, reason: CloudRebuildReason) async throws -> UUID {
        guard CloudFeatureConfiguration.isEnabled else { throw CloudRebuildError.featureDisabled }
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID),
              binding.databaseScope == scope,
              Self.canBeginRebuild(from: binding) else {
            throw CloudRebuildError.bindingMissing
        }
        let sessionID = UUID()
        let relativePath = "CloudRebuild/\(sessionID.uuidString.lowercased())"
        let locked = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: farmID,
            expectedState: binding.state,
            expectedLastErrorCode: binding.lastErrorCode,
            newState: .rebuildingCache,
            newLastErrorCode: nil
        )
        guard locked else { throw CloudRebuildError.bindingMissing }
        do {
            try createSession(id: sessionID, farmID: farmID, scope: scope, reason: reason, relativePath: relativePath)
        } catch {
            _ = try? await persistence.transitionRecoveryBindingIfUnchanged(
                farmID: farmID,
                expectedState: .rebuildingCache,
                expectedLastErrorCode: nil,
                newState: binding.state,
                newLastErrorCode: binding.lastErrorCode
            )
            throw error
        }
        startBuild(sessionID: sessionID, binding: binding)
        return sessionID
    }

    static func canBeginRebuild(from binding: CloudFarmBindingSnapshot) -> Bool {
        if binding.state == .active { return true }
        guard binding.state == .rebuildingCache else { return false }
        switch binding.lastErrorCode {
        case nil,
             "baselineIdentityMismatch",
             "deviceTrustRefreshRequired",
             "immutableOperationHardDelete",
             "liveOperationGap",
             "engineResetPending",
             "engineResetFailed",
             "recoveryValidationFailed",
             "rebuildValidationFailed",
             "rebuildCommitFailed",
             "rebuildCommitRequiresFreshRebuild",
             "rebuildCancelled":
            return true
        default:
            return false
        }
    }

    /// Admission polling may resume transient work, but a deterministic
    /// validation failure must not create an endless full-download loop.
    static func canAutomaticallyResumeSharedAdmission(
        from binding: CloudFarmBindingSnapshot
    ) -> Bool {
        guard canBeginRebuild(from: binding) else { return false }
        switch binding.lastErrorCode {
        case "rebuildValidationFailed",
             "rebuildCommitRequiresFreshRebuild":
            return false
        default:
            return true
        }
    }

    func rebuildAndCommit(farmID: UUID, scope: CloudDatabaseScope, reason: CloudRebuildReason) async throws -> CloudRebuildResult {
        let sessionID = try await rebuild(farmID: farmID, scope: scope, reason: reason)
        if let task = activeTasks[sessionID] { await task.value }
        return try await uncancelledCommit(sessionID: sessionID, allowsPreparedRetry: false)
    }

    /// Reuses a fully built staging store when only the final cache switch
    /// failed. A transient or inherited cancellation at the CloudKit root
    /// check must not discard a completed full download and replay.
    func rebuildOrRetryPreparedCommit(
        farmID: UUID,
        scope: CloudDatabaseScope,
        reason: CloudRebuildReason
    ) async throws -> CloudRebuildResult {
        if let binding = try await persistence.bindingSnapshot(farmID: farmID),
           binding.databaseScope == scope,
           Self.canRetryPreparedCommit(from: binding),
           let sessionID = try retryablePreparedSessionID(farmID: farmID, scope: scope) {
            return try await uncancelledCommit(sessionID: sessionID, allowsPreparedRetry: true)
        }
        if let result = try await replayReusableDownloadedBundle(
            farmID: farmID,
            scope: scope
        ) {
            return result
        }
        return try await rebuildAndCommit(farmID: farmID, scope: scope, reason: reason)
    }

    func hasReusableDownloadedReplay(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) throws -> Bool {
        try reusableDownloadedSessionID(farmID: farmID, scope: scope) != nil
    }

    static func canRetryPreparedCommit(from binding: CloudFarmBindingSnapshot) -> Bool {
        guard binding.state == .rebuildingCache else { return false }
        switch binding.lastErrorCode {
        case nil, "engineResetPending", "rebuildCommitFailed":
            return true
        default:
            return false
        }
    }

    /// Returns durable proof that the newest rebuild for this farm/scope
    /// already switched the authoritative cache and only engine activation is
    /// left. Re-verify the local bundle and staging store so a stale error
    /// string or an older completed session cannot skip a required rebuild.
    func verifiedCompletedCacheSwitch(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) throws -> CloudRebuildResult? {
        guard !committingFarmIDs.contains(farmID) else { return nil }
        let context = ModelContext(modelContainer)
        guard let latest = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter({ $0.farmID == farmID })
            .max(by: {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }),
              latest.databaseScope == scope,
              latest.status == .completed,
              latest.completedAt != nil,
              activeTasks[latest.id] == nil else {
            return nil
        }
        let bundle = try loadBundle(sessionID: latest.id)
        guard Self.hasCurrentAuthorityProof(bundle),
              bundle.sessionID == latest.id,
              bundle.farmID == farmID,
              bundle.scope == scope,
              bundle.recordCount == latest.fetchedRecordCount,
              bundle.pageCount == latest.pageCount,
              bundle.operations.count == latest.fetchedOperationCount,
              bundle.assets.count == latest.downloadedAssetCount else {
            return nil
        }
        try CloudRebuildBundleValidator.validate(bundle)
        guard latest.entityDigest == Self.entityDigest(bundle.operations) else {
            return nil
        }
        try CloudRebuildStagingBuilder.verify(
            bundle: bundle,
            workspace: try workspaceURL(sessionID: latest.id)
        )
        return CloudRebuildResult(
            sessionID: latest.id,
            farmID: farmID,
            fetchedRecordCount: latest.fetchedRecordCount,
            fetchedOperationCount: latest.fetchedOperationCount,
            fetchedAssetCount: latest.fetchedAssetCount,
            appliedOperationCount: latest.appliedOperationCount,
            preservedOutboxCount: latest.preservedOutboxCount,
            highestRevision: latest.highestRevision,
            entityDigest: latest.entityDigest,
            completedAt: latest.completedAt!
        )
    }

    /// Installs the device-key set from a completed private-owner rebuild
    /// before CKSyncEngine starts its nil-token catch-up. The bundle is
    /// revalidated and its membership signature is checked again through the
    /// private-owner CloudKit trust anchor; a copied or edited local bundle
    /// therefore cannot seed device trust.
    func persistPrivateOwnerTrustFromCompletedSwitch(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) async throws {
        guard scope == .privateDatabase,
              try verifiedCompletedCacheSwitch(
                farmID: farmID,
                scope: scope
              ) != nil else {
            return
        }
        let context = ModelContext(modelContainer)
        guard let latest = try context.fetch(
            FetchDescriptor<CloudRebuildSessionRecord>()
        )
            .filter({ $0.farmID == farmID })
            .max(by: {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }) else {
            throw CloudRebuildError.sessionMissing
        }
        let bundle = try loadBundle(sessionID: latest.id)
        guard let membership = bundle.membershipSnapshot,
              membership.farmID == farmID,
              bundle.scope == .privateDatabase,
              let binding = try await persistence.bindingSnapshot(
                farmID: farmID
              ),
              binding.databaseScope == .privateDatabase else {
            return
        }

        let zoneID = CKRecordZone.ID(
            zoneName: binding.zoneName,
            ownerName: binding.zoneOwnerName
        )
        let record = CKRecord(
            recordType:
                CloudRecordType.farmMembershipSnapshot.rawValue,
            recordID: .init(
                recordName: membership.cloudRecordName,
                zoneID: zoneID
            )
        )
        record[CloudRecordField.farmID] =
            membership.farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.generation] =
            membership.generation as CKRecordValue
        record[CloudRecordField.issuedAt] =
            membership.issuedAt as CKRecordValue
        record[CloudRecordField.payload] =
            membership.payload as CKRecordValue
        record[CloudRecordField.payloadDigest] =
            CloudPayloadDigest.hex(
                for: membership.payload
            ) as CKRecordValue
        record[CloudRecordField.modifiedByAccountID] =
            membership.signedByAccountID.uuidString
                .lowercased() as CKRecordValue
        record[CloudRecordField.modifiedByDeviceID] =
            membership.signedByDeviceID.uuidString
                .lowercased() as CKRecordValue
        record[CloudRecordField.capabilityCertificate] =
            membership.capabilityCertificate as CKRecordValue
        record[CloudRecordField.signature] =
            membership.signature as CKRecordValue

        let localTrust = try await persistence.cloudTrustSnapshot(
            farmID: farmID
        )
        _ = try Self.privateOwnerBootstrapTrust(
            records: [record],
            binding: binding,
            root: bundle.root,
            localTrust: localTrust
        )
        let envelope = try JSONDecoder.cloudRebuild.decode(
            FarmMembershipSnapshotEnvelope.self,
            from: membership.payload
        )
        try await persistence.saveValidatedMembershipSnapshotRecord(
            MembershipSnapshotRecordValue(
                id: UUID(),
                farmID: membership.farmID,
                generation: membership.generation,
                issuedAt: membership.issuedAt,
                payload: membership.payload,
                signedByAccountID: membership.signedByAccountID,
                signedByDeviceID: membership.signedByDeviceID,
                capabilityCertificate:
                    membership.capabilityCertificate,
                signature: membership.signature,
                cloudRecordName: membership.cloudRecordName,
                validatedAt: .now
            ),
            envelope: envelope
        )
    }

    /// Repairs the local audit projection of a verified completed cache switch
    /// without replaying or replacing the already active business cache.
    /// This is safe to run on every owner discovery because operationID and
    /// correction tombstones are both idempotent.
    @discardableResult
    func repairMissingDomainHistoryFromCompletedSwitch(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) async throws -> Int {
        guard try verifiedCompletedCacheSwitch(
            farmID: farmID,
            scope: scope
        ) != nil else {
            return 0
        }
        let context = ModelContext(modelContainer)
        guard let latest = try context.fetch(
            FetchDescriptor<CloudRebuildSessionRecord>()
        )
            .filter({ $0.farmID == farmID })
            .max(by: {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }) else {
            throw CloudRebuildError.sessionMissing
        }
        let bundle = try loadBundle(sessionID: latest.id)
        guard bundle.sessionID == latest.id,
              bundle.farmID == farmID,
              bundle.scope == scope else {
            throw CloudRebuildError.farmMismatch
        }
        try CloudRebuildBundleValidator.validate(bundle)
        let inserted = try RemoteDomainAuditProjection.restore(
            bundle.operations,
            context: context
        )
        var insertedTombstones = 0
        for envelope in bundle.operations {
            let payload = try JSONDecoder.cloudRebuild.decode(
                FarmCommandCloudPayload.self,
                from: envelope.payload
            )
            if try RemoteDomainAuditProjection
                .insertSupersededCorrectionTombstoneIfNeeded(
                    envelope: envelope,
                    payload: payload,
                    context: context
                ) {
                insertedTombstones += 1
            }
        }
        if inserted > 0 || insertedTombstones > 0 {
            try context.save()
        }
        return inserted
    }

    /// Builds a corrected staging projection from the newest completed local
    /// bundle. The caller still has to suspend the live CKSyncEngine and prove
    /// that no post-bundle operations or assets exist before switching it.
    func preparedLegacyBootstrapProjectionRepair(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) async throws -> CloudRebuildLocalProjectionRepair? {
        guard scope == .sharedDatabase,
              !committingFarmIDs.contains(farmID),
              let binding = try await persistence.bindingSnapshot(farmID: farmID),
              binding.state == .active,
              binding.databaseScope == scope else {
            return nil
        }
        let context = ModelContext(modelContainer)
        if try context.fetch(FetchDescriptor<SecurityIncidentRecord>())
            .contains(where: {
                $0.farmID == farmID &&
                    $0.incidentType == LegacyBootstrapProjectionRepair.incidentType
            }) {
            return nil
        }
        guard let latest = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter({ $0.farmID == farmID })
            .max(by: {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }),
              latest.databaseScope == scope,
              latest.status == .completed,
              latest.completedAt != nil,
              activeTasks[latest.id] == nil else {
            return nil
        }
        let bundle = try loadBundle(sessionID: latest.id)
        guard bundle.sessionID == latest.id,
              bundle.farmID == farmID,
              bundle.scope == scope,
              bundle.bootstrap?.normalizedVersion == 2,
              Self.hasCurrentAuthorityProof(bundle),
              bundle.recordCount == latest.fetchedRecordCount,
              bundle.pageCount == latest.pageCount,
              bundle.operations.count == latest.fetchedOperationCount,
              bundle.assets.count == latest.downloadedAssetCount,
              latest.entityDigest == Self.entityDigest(bundle.operations) else {
            return nil
        }
        try CloudRebuildBundleValidator.validate(bundle)
        let workspace = try workspaceURL(sessionID: latest.id)
        _ = try CloudRebuildStagingBuilder.build(
            bundle: bundle,
            workspace: workspace
        )
        try CloudRebuildStagingBuilder.verify(
            bundle: bundle,
            workspace: workspace
        )
        return CloudRebuildLocalProjectionRepair(
            bundle: bundle,
            workspace: workspace
        )
    }

    func cancel(sessionID: UUID) async throws {
        guard let session = try session(id: sessionID) else { throw CloudRebuildError.sessionMissing }
        guard !committingFarmIDs.contains(session.farmID), session.status != .committing else {
            throw CloudRebuildError.commitInProgress
        }
        guard try isLatestSession(sessionID, farmID: session.farmID) else {
            throw CloudRebuildError.sessionNotResumable
        }
        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = nil
        activeTaskTokens[sessionID] = nil
        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.cancelled.rawValue
            value.lastErrorCode = "cancelled"
            value.lastErrorMessage = CloudRebuildError.cancelled.localizedDescription
        }
        _ = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: session.farmID,
            expectedState: .rebuildingCache,
            expectedLastErrorCode: nil,
            newState: .active,
            newLastErrorCode: "rebuildCancelled"
        )
    }

    func resume(sessionID: UUID) async throws {
        guard let current = try session(id: sessionID) else { throw CloudRebuildError.sessionMissing }
        guard [.failed, .cancelled].contains(current.status) else { throw CloudRebuildError.sessionNotResumable }
        guard !committingFarmIDs.contains(current.farmID),
              try isLatestSession(sessionID, farmID: current.farmID) else {
            throw CloudRebuildError.sessionNotResumable
        }
        guard let binding = try await persistence.bindingSnapshot(farmID: current.farmID) else {
            throw CloudRebuildError.bindingMissing
        }
        let expectedBinding: (CloudFarmBindingState, String?)
        switch current.status {
        case .cancelled where binding.state == .active && binding.lastErrorCode == "rebuildCancelled":
            expectedBinding = (.active, "rebuildCancelled")
        case .failed where binding.state == .rebuildingCache &&
            (binding.lastErrorCode == "rebuildValidationFailed" ||
                binding.lastErrorCode == "rebuildCommitRequiresFreshRebuild"):
            expectedBinding = (.rebuildingCache, binding.lastErrorCode)
        default:
            throw CloudRebuildError.bindingMissing
        }
        let relocked = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: current.farmID,
            expectedState: expectedBinding.0,
            expectedLastErrorCode: expectedBinding.1,
            newState: .rebuildingCache,
            newLastErrorCode: nil
        )
        guard relocked else { throw CloudRebuildError.bindingMissing }
        do {
            try removeStagingContents(sessionID: sessionID)
            try updateSession(sessionID) { value in
                value.statusRawValue = CloudRebuildStatus.preparing.rawValue
                value.progress = 0
                value.pageCount = 0
                value.fetchedRecordCount = 0
                value.fetchedOperationCount = 0
                value.fetchedAssetCount = 0
                value.downloadedAssetCount = 0
                value.lastErrorCode = nil
                value.lastErrorMessage = nil
                value.retryAt = nil
            }
        } catch {
            _ = try? await persistence.transitionRecoveryBindingIfUnchanged(
                farmID: current.farmID,
                expectedState: .rebuildingCache,
                expectedLastErrorCode: nil,
                newState: expectedBinding.0,
                newLastErrorCode: expectedBinding.1
            )
            throw error
        }
        startBuild(sessionID: sessionID, binding: binding)
    }

    func commit(sessionID: UUID, allowsPreparedRetry: Bool = false) async throws -> CloudRebuildResult {
        guard let current = try session(id: sessionID) else { throw CloudRebuildError.sessionMissing }
        let isLatest = try isLatestSession(sessionID, farmID: current.farmID)
        let isPreparedRetry = allowsPreparedRetry && (
            (current.status == .failed && current.lastErrorCode == "commitFailed") ||
            current.status == .committing
        )
        guard isLatest, current.status == .readyToCommit || isPreparedRetry else {
            throw CloudRebuildError.sessionNotReady
        }
        guard let commitBinding = try await persistence.bindingSnapshot(farmID: current.farmID),
              commitBinding.state == .rebuildingCache,
              commitBinding.databaseScope == current.databaseScope,
              [nil, "engineResetPending", "rebuildCommitFailed"].contains(commitBinding.lastErrorCode) else {
            throw CloudRebuildError.bindingMissing
        }
        guard committingFarmIDs.insert(current.farmID).inserted else {
            throw CloudRebuildError.commitInProgress
        }
        defer { committingFarmIDs.remove(current.farmID) }
        try updateSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.committing.rawValue
            value.progress = 0.95
            value.lastErrorCode = nil
            value.lastErrorMessage = nil
        }
        var reusableStagingVerified = false
        do {
            let bundle = try loadBundle(sessionID: sessionID)
            guard bundle.sessionID == sessionID,
                  bundle.farmID == current.farmID,
                  bundle.scope == current.databaseScope else {
                throw CloudRebuildError.farmMismatch
            }
            guard Self.hasCurrentAuthorityProof(bundle) else {
                throw CloudRebuildError.stagingValidation(
                    "旧重建包没有不可变 FarmOperation 来源证明，必须重新获取云端权威快照。"
                )
            }
            guard bundle.recordCount == current.fetchedRecordCount,
                  bundle.pageCount == current.pageCount,
                  bundle.operations.count == current.fetchedOperationCount,
                  bundle.assets.count == current.downloadedAssetCount else {
                throw CloudRebuildError.stagingValidation("已完成 staging 与重建会话计数不一致。")
            }
            let blockingIssueCount = try issues(sessionID: sessionID).filter { $0.severity == .blocking }.count
            guard blockingIssueCount == 0 else {
                throw CloudRebuildError.blockingIssues(blockingIssueCount)
            }
            try CloudRebuildBundleValidator.validate(bundle)
            try CloudRebuildStagingBuilder.verify(bundle: bundle, workspace: workspaceURL(sessionID: sessionID))
            reusableStagingVerified = true
            try await validateAuthoritativeRootStillMatches(bundle: bundle)
            try requireCommitSession(sessionID, farmID: current.farmID)
            guard let lockedBinding = try await persistence.bindingSnapshot(farmID: current.farmID),
                  lockedBinding.state == .rebuildingCache,
                  lockedBinding.databaseScope == bundle.scope,
                  lockedBinding.ownerAccountID == commitBinding.ownerAccountID,
                  lockedBinding.zoneName == commitBinding.zoneName,
                  lockedBinding.zoneOwnerName == commitBinding.zoneOwnerName,
                  lockedBinding.lastErrorCode == commitBinding.lastErrorCode else {
                throw CloudRebuildError.bindingMissing
            }
            let commit = try await persistence.replaceConfirmedFarmCache(using: bundle)
            try CloudEngineStateDiskStore.remove(scope: bundle.scope)
            let markedForEngineReset = try await persistence.recordRecoveryEngineFailureIfUnchanged(
                farmID: current.farmID,
                expectedLastErrorCode: lockedBinding.lastErrorCode,
                failureCode: "engineResetPending"
            )
            guard markedForEngineReset else { throw CloudRebuildError.bindingMissing }
            let result = CloudRebuildResult(
                sessionID: sessionID,
                farmID: current.farmID,
                fetchedRecordCount: current.fetchedRecordCount,
                fetchedOperationCount: current.fetchedOperationCount,
                fetchedAssetCount: current.fetchedAssetCount,
                appliedOperationCount: commit.appliedOperationCount,
                preservedOutboxCount: commit.preservedOutboxCount,
                highestRevision: commit.highestRevision,
                entityDigest: commit.entityDigest,
                completedAt: .now
            )
            try updateSession(sessionID) { value in
                value.statusRawValue = CloudRebuildStatus.completed.rawValue
                value.progress = 1
                value.appliedOperationCount = commit.appliedOperationCount
                value.preservedOutboxCount = commit.preservedOutboxCount
                value.highestRevision = commit.highestRevision
                value.entityDigest = commit.entityDigest
                value.completedAt = result.completedAt
                value.lastErrorCode = nil
                value.lastErrorMessage = nil
            }
            // Keep the farm locked until the caller has also reset its
            // incremental engine. Unlocking here exposes a window where live
            // sync can reuse tokens from the cache that was just replaced.
            return result
        } catch {
            let requiresFreshRebuild = Self.commitFailureRequiresFreshRebuild(
                error,
                reusableStagingVerified: reusableStagingVerified
            )
            let sessionErrorCode = requiresFreshRebuild
                ? "commitRequiresFreshRebuild"
                : "commitFailed"
            let bindingErrorCode = requiresFreshRebuild
                ? "rebuildCommitRequiresFreshRebuild"
                : "rebuildCommitFailed"
            try? updateSession(sessionID) { value in
                value.statusRawValue = CloudRebuildStatus.failed.rawValue
                value.lastErrorCode = sessionErrorCode
                value.lastErrorMessage = error.localizedDescription
            }
            _ = try? await persistence.recordRecoveryEngineFailureIfUnchanged(
                farmID: current.farmID,
                expectedLastErrorCode: commitBinding.lastErrorCode,
                failureCode: bindingErrorCode
            )
            throw error
        }
    }

    static func commitFailureRequiresFreshRebuild(
        _ error: Error,
        reusableStagingVerified: Bool
    ) -> Bool {
        guard reusableStagingVerified else { return true }
        // Every CloudRebuildError represents changed authority, invalid
        // staging, identity mismatch, or another semantic failure. Reusing
        // that same bundle cannot repair it. Non-domain errors after a fully
        // verified staging pass (for example a transient CK/network or disk
        // switch failure) may safely retry the prepared commit.
        return error is CloudRebuildError ||
            error is CloudContractError ||
            error is RemoteDomainApplyError ||
            error is FarmCommandError
    }

    private func uncancelledCommit(
        sessionID: UUID,
        allowsPreparedRetry: Bool
    ) async throws -> CloudRebuildResult {
        // The rebuild is launched from a scene-scoped task. That caller may be
        // cancelled while the synchronous staging replay is still finishing.
        // Use a fresh unstructured task for the short, atomic finalization so
        // an old cancellation bit cannot immediately cancel CKRecord fetch.
        let task = Task {
            try await self.commit(
                sessionID: sessionID,
                allowsPreparedRetry: allowsPreparedRetry
            )
        }
        return try await task.value
    }

    private func retryablePreparedSessionID(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) throws -> UUID? {
        guard !committingFarmIDs.contains(farmID) else { return nil }
        let context = ModelContext(modelContainer)
        guard let latest = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter({ $0.farmID == farmID })
            .max(by: {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }),
              latest.databaseScope == scope,
              activeTasks[latest.id] == nil else {
            return nil
        }
        switch latest.status {
        case .readyToCommit, .committing:
            return latest.id
        case .failed where latest.lastErrorCode == "commitFailed":
            return latest.id
        default:
            return nil
        }
    }

    private func reusableDownloadedSessionID(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) throws -> UUID? {
        guard !committingFarmIDs.contains(farmID) else { return nil }
        let context = ModelContext(modelContainer)
        let candidates = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter {
                $0.farmID == farmID &&
                    $0.databaseScope == scope &&
                    $0.status == .failed &&
                    $0.lastErrorCode == "RemoteDomainApplyError" &&
                    activeTasks[$0.id] == nil
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
        for candidate in candidates {
            let bundleURL = try workspaceURL(sessionID: candidate.id).appending(path: "bundle.json")
            guard FileManager.default.fileExists(atPath: bundleURL.path) else { continue }
            let bundle: CloudRebuildBundle
            do {
                bundle = try loadBundle(sessionID: candidate.id)
            } catch {
                continue
            }
            guard bundle.sessionID == candidate.id,
                  bundle.farmID == farmID,
                  bundle.scope == scope,
                  Self.hasCurrentAuthorityProof(bundle),
                  bundle.recordCount == candidate.fetchedRecordCount,
                  bundle.pageCount == candidate.pageCount,
                  bundle.operations.count == candidate.fetchedOperationCount,
                  bundle.assets.count == candidate.downloadedAssetCount else {
                continue
            }
            do {
                try CloudRebuildBundleValidator.validate(bundle)
                for asset in bundle.assets {
                    let file = try workspaceURL(sessionID: candidate.id)
                        .appending(path: asset.relativePath)
                    guard FileManager.default.fileExists(atPath: file.path) else {
                        throw CloudRebuildError.stagingValidation("已下载照片不存在。")
                    }
                }
            } catch {
                continue
            }
            return candidate.id
        }
        return nil
    }

    private func replayReusableDownloadedBundle(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) async throws -> CloudRebuildResult? {
        guard let sessionID = try reusableDownloadedSessionID(
            farmID: farmID,
            scope: scope
        ) else {
            return nil
        }
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID),
              binding.state == .rebuildingCache,
              binding.databaseScope == scope,
              [nil, "rebuildValidationFailed"].contains(binding.lastErrorCode) else {
            return nil
        }
        let relocked = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: farmID,
            expectedState: .rebuildingCache,
            expectedLastErrorCode: binding.lastErrorCode,
            newState: .rebuildingCache,
            newLastErrorCode: nil
        )
        guard relocked else { return nil }

        do {
            try promoteDownloadedSessionForLocalReplay(sessionID, farmID: farmID)
            let bundle = try loadBundle(sessionID: sessionID)
            let workspace = try workspaceURL(sessionID: sessionID)
            _ = try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)
            let blocking = try issues(sessionID: sessionID)
                .filter { $0.severity == .blocking }
                .count
            guard blocking == 0 else {
                throw CloudRebuildError.blockingIssues(blocking)
            }
            try updateSession(sessionID) { value in
                value.statusRawValue = CloudRebuildStatus.readyToCommit.rawValue
                value.progress = 0.9
                value.fetchedOperationCount = bundle.operations.count
                value.fetchedAssetCount = bundle.assets.count
                value.downloadedAssetCount = bundle.assets.count
                value.highestRevision = bundle.operations.map(\.revision).max() ?? 0
                value.entityDigest = Self.entityDigest(bundle.operations)
                value.lastErrorCode = nil
                value.lastErrorMessage = nil
                value.retryAt = nil
            }
            return try await uncancelledCommit(
                sessionID: sessionID,
                allowsPreparedRetry: false
            )
        } catch {
            try? updateSession(sessionID) { value in
                value.statusRawValue = CloudRebuildStatus.failed.rawValue
                value.lastErrorCode = "localReplayFailed"
                value.lastErrorMessage = error.localizedDescription
                value.retryAt = nil
            }
            _ = try? await persistence.recordRecoveryEngineFailureIfUnchanged(
                farmID: farmID,
                expectedLastErrorCode: nil,
                failureCode: "rebuildValidationFailed"
            )
            throw error
        }
    }

    private func promoteDownloadedSessionForLocalReplay(
        _ sessionID: UUID,
        farmID: UUID
    ) throws {
        let context = ModelContext(modelContainer)
        let sessions = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter { $0.farmID == farmID }
        guard let candidate = sessions.first(where: { $0.id == sessionID }) else {
            throw CloudRebuildError.sessionMissing
        }
        guard !committingFarmIDs.contains(farmID) else {
            throw CloudRebuildError.commitInProgress
        }
        for session in sessions where session.id != sessionID {
            activeTasks[session.id]?.cancel()
            activeTasks[session.id] = nil
            activeTaskTokens[session.id] = nil
            if session.status.isRunning || session.status == .readyToCommit {
                session.statusRawValue = CloudRebuildStatus.cancelled.rawValue
                session.lastErrorCode = "supersededByDownloadedReplay"
                session.lastErrorMessage = "已改用完整下载包进行本地重放。"
                session.updatedAt = .now
            }
        }
        if let newest = sessions
            .filter({ $0.id != sessionID })
            .map(\.createdAt)
            .max(),
           candidate.createdAt <= newest {
            candidate.createdAt = newest.addingTimeInterval(0.001)
        }
        candidate.statusRawValue = CloudRebuildStatus.validating.rawValue
        candidate.progress = 0.72
        candidate.lastErrorCode = nil
        candidate.lastErrorMessage = nil
        candidate.retryAt = nil
        candidate.completedAt = nil
        candidate.updatedAt = .now
        try context.save()
    }

    private func startBuild(sessionID: UUID, binding: CloudFarmBindingSnapshot) {
        activeTasks[sessionID]?.cancel()
        let taskToken = UUID()
        activeTaskTokens[sessionID] = taskToken
        activeTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.build(sessionID: sessionID, binding: binding)
            } catch is CancellationError {
                try? await self.markCancelled(sessionID: sessionID, taskToken: taskToken)
            } catch {
                try? await self.markFailed(sessionID: sessionID, taskToken: taskToken, error: error)
            }
            await self.clearTask(sessionID: sessionID, taskToken: taskToken)
        }
    }

    private func build(sessionID: UUID, binding: CloudFarmBindingSnapshot) async throws {
        let workspace = try workspaceURL(sessionID: sessionID)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appending(path: "Assets", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try updateBuildSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.fetching.rawValue
            value.progress = 0.05
        }

        let database = binding.databaseScope == .privateDatabase ? cloudContainer.privateCloudDatabase : cloudContainer.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let fetcher = CloudZoneChangeFetcher(database: database)
        var records: [CKRecord] = []
        var deletions: [CKDatabase.RecordZoneChange.Deletion] = []
        var pageCount = 0
        for try await page in await fetcher.fetchAll(zoneID: zoneID) {
            try Task.checkCancellation()
            records.append(contentsOf: page.records)
            deletions.append(contentsOf: page.deletions)
            pageCount = page.index
            try updateBuildSession(sessionID) { value in
                value.pageCount = page.index
                value.fetchedRecordCount = records.count
                value.progress = min(0.45, 0.08 + Double(page.index) * 0.04)
            }
        }

        try requireCurrentBuildSession(sessionID)
        let parsed = try await parseAndValidate(
            sessionID: sessionID,
            binding: binding,
            records: records,
            deletions: deletions,
            pageCount: pageCount,
            workspace: workspace
        )
        try requireCurrentBuildSession(sessionID)
        try saveBundle(parsed, sessionID: sessionID)
        _ = try CloudRebuildStagingBuilder.build(bundle: parsed, workspace: workspace)
        try requireCurrentBuildSession(sessionID)
        let blocking = try issues(sessionID: sessionID).filter { $0.severity == .blocking }.count
        guard blocking == 0 else { throw CloudRebuildError.blockingIssues(blocking) }
        try updateBuildSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.readyToCommit.rawValue
            value.progress = 0.9
            value.fetchedOperationCount = parsed.operations.count
            value.fetchedAssetCount = parsed.assets.count
            value.downloadedAssetCount = parsed.assets.count
            value.highestRevision = parsed.operations.map(\.revision).max() ?? 0
            value.entityDigest = Self.entityDigest(parsed.operations)
        }
    }

    private func parseAndValidate(
        sessionID: UUID,
        binding: CloudFarmBindingSnapshot,
        records: [CKRecord],
        deletions: [CKDatabase.RecordZoneChange.Deletion],
        pageCount: Int,
        workspace: URL
    ) async throws -> CloudRebuildBundle {
        try updateBuildSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.downloadingAssets.rawValue
            value.progress = 0.5
        }
        guard let rootRecord = records.first(where: { $0.recordType == CloudRecordType.farmRoot.rawValue }) else {
            try addIssue(sessionID: sessionID, farmID: binding.farmID, code: "farmRootMissing", detail: "Zone 中缺少 FarmRoot。")
            throw CloudContractError.malformedRecord
        }
        let bootstrapState = rootRecord[CloudRecordField.bootstrapState] as? String
        if let bootstrapState, bootstrapState != "ready" {
            throw CloudRebuildError.stagingValidation("迁移牧场云端基线尚未完成。")
        }
        let expectedBootstrapDigest = rootRecord[CloudRecordField.bootstrapDigest] as? String
        let storedBootstrapVersion = Self.integer(rootRecord[CloudRecordField.bootstrapVersion])
        let expectedBootstrapVersion = storedBootstrapVersion > 0 ? storedBootstrapVersion : 1
        let expectedBootstrapCutoffAt = rootRecord[CloudRecordField.bootstrapCutoffAt] as? Date
        let bootstrapEntityCount = Self.integer(rootRecord[CloudRecordField.bootstrapEntityCount])
        let bootstrapPhotoCount = Self.integer(rootRecord[CloudRecordField.bootstrapPhotoCount])
        if bootstrapState == "ready" || expectedBootstrapVersion >= 2 {
            guard bootstrapState == "ready",
                  let expectedBootstrapDigest,
                  !expectedBootstrapDigest.isEmpty,
                  bootstrapEntityCount > 0,
                  bootstrapPhotoCount >= 0,
                  expectedBootstrapVersion < 2 || expectedBootstrapCutoffAt != nil else {
                throw CloudRebuildError.stagingValidation("迁移牧场云端基线证据不完整。")
            }
        }
        let expectedBootstrapEntityCount = expectedBootstrapDigest == nil ? nil : bootstrapEntityCount
        let expectedBootstrapPhotoCount = expectedBootstrapDigest == nil ? nil : bootstrapPhotoCount
        let rootValue = try mapper.farmRootValue(from: rootRecord)
        guard rootValue.farmID == binding.farmID else { throw CloudRebuildError.farmMismatch }
        let root = CloudRebuildRootSnapshot(farmID: rootValue.farmID, name: rootValue.name, ownerAccountID: rootValue.ownerAccountID, modifiedAt: rootValue.modifiedAt)

        // A newly installed device may only have its own local public key.
        // Refresh the farm trust set from the authenticated identity service
        // before validating records signed by the other phone. The rebuild
        // lock remains held while this snapshot is persisted.
        let workerSecurityGeneration: Int?
        if IdentityWorkerConfiguration.baseURL != nil {
            let workerSnapshot = try await worker.farmSecuritySnapshot(farmID: binding.farmID)
            guard workerSnapshot.farmID == binding.farmID else {
                throw CloudContractError.malformedRecord
            }
            try await persistence.saveSecuritySnapshot(workerSnapshot)
            workerSecurityGeneration = workerSnapshot.generation
        } else {
            workerSecurityGeneration = nil
        }
        let localTrust = try await persistence.cloudTrustSnapshot(
            farmID: binding.farmID
        )
        let trust = try Self.privateOwnerBootstrapTrust(
            records: records,
            binding: binding,
            root: root,
            localTrust: localTrust
        )
        var immutableOperations: [CloudOperationEnvelope] = []
        var operationSourceProofs: [CloudRebuildOperationSourceProof] = []
        for record in records where record.recordType == CloudRecordType.farmOperation.rawValue {
            do {
                let envelope = try mapper.operationEnvelope(from: record)
                guard envelope.farmID == binding.farmID,
                      record.recordID.recordName == mapper.recordName(for: envelope.operationID) else {
                    throw CloudRebuildError.farmMismatch
                }
                let validatedEnvelope = try Self.validatedOperationForRebuild(
                    envelope: envelope,
                    authorizationDate: record.modificationDate ?? record.creationDate,
                    trust: trust,
                    expectedBootstrapVersion: expectedBootstrapVersion,
                    cutoffAt: expectedBootstrapCutoffAt
                )
                operationSourceProofs.append(try CloudRebuildOperationSourceProof(
                    record: record,
                    envelope: envelope
                ))
                guard let validatedEnvelope else {
                    // A v2 baseline already contains this trusted pre-cutoff
                    // operation's final state. It is intentionally absent from
                    // the bundle and does not create an authorization warning.
                    continue
                }
                immutableOperations.append(validatedEnvelope)
            } catch {
                let rejectedEnvelope = try? mapper.operationEnvelope(from: record)
                try addIssue(
                    sessionID: sessionID,
                    farmID: binding.farmID,
                    code: "invalidOperation",
                    recordName: rejectedEnvelope.map { mapper.recordName(for: $0.operationID) } ?? record.recordID.recordName,
                    detail: "不可变云端操作未通过授权校验：\(error.localizedDescription)"
                )
                throw error
            }
        }

        var projections: [CloudOperationEnvelope] = []
        var rejectedProjectionIDs = Set<UUID>()
        for record in records where record.recordType == CloudRecordType.farmEntity.rawValue {
            do {
                let envelope = try mapper.operationEnvelope(from: record)
                guard envelope.farmID == binding.farmID else { throw CloudRebuildError.farmMismatch }
                guard let validatedEnvelope = try Self.validatedOperationForRebuild(
                    envelope: envelope,
                    authorizationDate: record.modificationDate ?? record.creationDate,
                    trust: trust,
                    expectedBootstrapVersion: expectedBootstrapVersion,
                    cutoffAt: expectedBootstrapCutoffAt
                ) else { continue }
                projections.append(validatedEnvelope)
            } catch {
                let rejectedEnvelope = try? mapper.operationEnvelope(from: record)
                if let operationID = rejectedEnvelope?.operationID,
                   !rejectedProjectionIDs.insert(operationID).inserted {
                    continue
                }
                try addIssue(
                    sessionID: sessionID,
                    farmID: binding.farmID,
                    severity: .warning,
                    code: "invalidEntityProjection",
                    recordName: record.recordID.recordName,
                    detail: "可变实体投影未通过校验，已忽略且不会作为重建权威：\(error.localizedDescription)"
                )
            }
        }
        let reconciledOperations: [CloudOperationEnvelope]
        do {
            reconciledOperations = try Self.reconcileAuthoritativeOperationSources(
                immutableOperations: immutableOperations,
                projections: projections,
                expectedBaselineVersion: expectedBootstrapVersion,
                cutoffAt: expectedBootstrapCutoffAt
            )
        } catch {
            try addIssue(
                sessionID: sessionID,
                farmID: binding.farmID,
                code: "operationProjectionMismatch",
                detail: error.localizedDescription
            )
            throw error
        }
        let canonicalOperations = try Self.canonicalizeBaselineOperations(
            reconciledOperations,
            expectedVersion: expectedBootstrapVersion,
            cutoffAt: expectedBootstrapCutoffAt
        )
        let operations = Self.sortedOperations(canonicalOperations)
        guard !operations.isEmpty else { throw CloudRebuildError.noAuthoritativeOperations }

        var assets: [CloudRebuildAssetSnapshot] = []
        for record in records where record.recordType == CloudRecordType.farmAsset.rawValue {
            do {
                let value = try Self.assetEnvelope(record: record, mapper: mapper)
                try Self.validate(
                    asset: value,
                    authorizationDate: try mapper.assetAuthorizationDate(from: record),
                    trust: trust,
                    signatureVersion: try mapper.assetSignatureVersion(from: record)
                )
                guard let ckAsset = record[CloudRecordField.asset] as? CKAsset, let sourceURL = ckAsset.fileURL else {
                    throw CloudContractError.malformedRecord
                }
                let extensionName = value.mimeType == "image/heic" ? "heic" : "jpg"
                let relativePath = "Assets/\(value.assetID.uuidString.lowercased()).\(extensionName)"
                let destination = workspace.appending(path: relativePath)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                let digest = CloudPayloadDigest.hex(for: try Data(contentsOf: destination, options: .mappedIfSafe))
                guard digest == value.payloadDigest else { throw CloudContractError.invalidPayloadDigest }
                assets.append(CloudRebuildAssetSnapshot(envelope: value, relativePath: relativePath, cloudRecordName: record.recordID.recordName))
            } catch {
                try addIssue(sessionID: sessionID, farmID: binding.farmID, code: "invalidAsset", recordName: record.recordID.recordName, detail: error.localizedDescription)
            }
        }

        try updateBuildSession(sessionID) { value in
            value.statusRawValue = CloudRebuildStatus.validating.rawValue
            value.progress = 0.72
            value.fetchedOperationCount = operations.count
            value.fetchedAssetCount = records.filter { $0.recordType == CloudRecordType.farmAsset.rawValue }.count
            value.downloadedAssetCount = assets.count
        }
        var bootstrap: CloudRebuildBootstrapSnapshot?
        if let expectedBootstrapDigest, let expectedBootstrapEntityCount, let expectedBootstrapPhotoCount {
            let snapshots = try operations.compactMap { operation -> BootstrapEntityEnvelopeV1? in
                let payload = try JSONDecoder.cloudRebuild.decode(FarmCommandCloudPayload.self, from: operation.payload)
                guard payload.kind == .bootstrapEntity else { return nil }
                guard let data = payload.dataValues["snapshot"] else { throw RemoteDomainApplyError.invalidPayload("snapshot") }
                let snapshot = try JSONDecoder.cloudRebuild.decode(BootstrapEntityEnvelopeV1.self, from: data)
                try snapshot.validate(for: operation)
                return snapshot
            }
            try Self.validateBootstrapEvidence(
                snapshots: snapshots,
                verifiedAssetCount: assets.count,
                expectedDigest: expectedBootstrapDigest,
                expectedEntityCount: expectedBootstrapEntityCount,
                expectedPhotoCount: expectedBootstrapPhotoCount
            )
            bootstrap = CloudRebuildBootstrapSnapshot(
                digest: expectedBootstrapDigest,
                entityCount: expectedBootstrapEntityCount,
                photoCount: expectedBootstrapPhotoCount,
                version: expectedBootstrapVersion,
                cutoffAt: expectedBootstrapCutoffAt
            )
        }
        let membership = try validateMembership(
            records: records,
            binding: binding,
            trust: trust,
            workerSecurityGeneration: workerSecurityGeneration
        )
        try requireCurrentBuildSession(sessionID)
        let bundle = CloudRebuildBundle(
            sessionID: sessionID,
            farmID: binding.farmID,
            scope: binding.databaseScope,
            root: root,
            authorityProofVersion: Self.currentAuthorityProofVersion,
            operationSourceProofs: operationSourceProofs,
            bootstrap: bootstrap,
            operations: operations,
            assets: assets,
            membershipSnapshot: membership,
            deletedRecordNames: deletions.map(\.recordID.recordName).sorted(),
            pageCount: pageCount,
            recordCount: records.count,
            createdAt: .now
        )
        try CloudRebuildBundleValidator.validate(bundle)
        return bundle
    }

    static func hasCurrentAuthorityProof(_ bundle: CloudRebuildBundle) -> Bool {
        bundle.authorityProofVersion == currentAuthorityProofVersion &&
            bundle.operationSourceProofs != nil
    }

    private func validateMembership(
        records: [CKRecord],
        binding: CloudFarmBindingSnapshot,
        trust: CloudTrustSnapshot,
        workerSecurityGeneration: Int?
    ) throws -> CloudRebuildMembershipSnapshot? {
        let candidates = records.filter { $0.recordType == CloudRecordType.farmMembershipSnapshot.rawValue }
        guard let record = candidates.max(by: { Self.integer($0[CloudRecordField.generation]) < Self.integer($1[CloudRecordField.generation]) }) else {
            return binding.databaseScope == .privateDatabase ? nil : try missingMembership()
        }
        let snapshot = try Self.membershipSnapshot(record: record, trust: trust)
        if let workerSecurityGeneration,
           snapshot.generation < workerSecurityGeneration {
            throw CloudRebuildError.lowerMembershipGeneration(
                cloud: snapshot.generation,
                worker: workerSecurityGeneration
            )
        }
        return snapshot
    }

    private func missingMembership() throws -> CloudRebuildMembershipSnapshot? {
        throw CloudContractError.malformedRecord
    }

    /// A clean installation no longer has the historical device keys that
    /// signed records in the owner's private CloudKit zone. For that one
    /// scope, the authenticated private zone and matching FarmRoot are the
    /// trust anchor: the latest owner membership snapshot may bootstrap its
    /// device-key set only after its authority certificate, payload digest,
    /// owner membership and signature all verify together.
    ///
    /// Shared zones deliberately cannot use this path. They still require an
    /// already trusted security snapshot from the identity service.
    static func privateOwnerBootstrapTrust(
        records: [CKRecord],
        binding: CloudFarmBindingSnapshot,
        root: CloudRebuildRootSnapshot,
        localTrust: CloudTrustSnapshot
    ) throws -> CloudTrustSnapshot {
        guard binding.databaseScope == .privateDatabase else {
            return localTrust
        }
        guard binding.zoneOwnerName == CKCurrentUserDefaultName,
              binding.farmID == root.farmID,
              binding.ownerAccountID == root.ownerAccountID else {
            throw CloudRebuildError.farmMismatch
        }
        let candidates = records.filter {
            $0.recordType == CloudRecordType.farmMembershipSnapshot.rawValue
        }
        guard let record = candidates.max(by: {
            integer($0[CloudRecordField.generation]) <
                integer($1[CloudRecordField.generation])
        }) else {
            return localTrust
        }
        guard let farmText = record[CloudRecordField.farmID] as? String,
              let farmID = UUID(uuidString: farmText),
              farmID == root.farmID,
              let issuedAt = record[CloudRecordField.issuedAt] as? Date,
              let payload = record[CloudRecordField.payload] as? Data,
              let digest = record[CloudRecordField.payloadDigest] as? String,
              digest == CloudPayloadDigest.hex(for: payload),
              let accountText = record[
                CloudRecordField.modifiedByAccountID
              ] as? String,
              let accountID = UUID(uuidString: accountText),
              accountID == root.ownerAccountID,
              let deviceText = record[
                CloudRecordField.modifiedByDeviceID
              ] as? String,
              let signingDeviceID = UUID(uuidString: deviceText),
              let certificate = record[
                CloudRecordField.capabilityCertificate
              ] as? String,
              let signature = record[CloudRecordField.signature] as? Data,
              let capabilityKey = localTrust.capabilityPublicKeyPEM,
              !capabilityKey.isEmpty else {
            throw CloudContractError.malformedRecord
        }

        let envelope = try JSONDecoder.cloudRebuild.decode(
            FarmMembershipSnapshotEnvelope.self,
            from: payload
        )
        let generation = integer(record[CloudRecordField.generation])
        guard envelope.farmID == farmID,
              envelope.generation == generation,
              abs(envelope.issuedAt.timeIntervalSince(issuedAt)) < 0.001,
              envelope.members.contains(where: {
                $0.accountID == root.ownerAccountID &&
                    $0.role == .owner &&
                    $0.status == "active"
              }) else {
            throw CloudContractError.malformedRecord
        }

        let claims = try CapabilityCertificateVerifier.verify(
            certificate,
            publicKeyPEM: capabilityKey
        )
        let revokedInSnapshot = Set(
            envelope.revokedCertificates.map(\.certificateID)
        )
        guard claims.role == .owner,
              claims.farmID == farmID,
              claims.accountID == accountID,
              claims.deviceID == signingDeviceID,
              claims.capabilities.contains(.manageMembers),
              claims.isValid(at: issuedAt),
              !localTrust.revokedCertificateIDs.contains(
                claims.certificateID
              ),
              !revokedInSnapshot.contains(claims.certificateID),
              let signingDevice = envelope.devices.first(where: {
                $0.deviceID == signingDeviceID &&
                    $0.accountID == accountID
              }),
              let signingKey =
                CloudDevicePublicKeyDecoder.x963Representation(
                    fromJWKJSON: signingDevice.publicKeyJWK
                ) else {
            throw CloudContractError.capabilityDenied
        }
        try DeviceSignatureVerifier.verify(
            signature: signature,
            data: MembershipSnapshotActor.signingData(
                farmID: farmID,
                generation: generation,
                issuedAt: issuedAt,
                payloadDigest: digest,
                accountID: accountID,
                deviceID: signingDeviceID
            ),
            publicKeyX963: signingKey
        )

        let activeAccountIDs = Set(
            envelope.members
                .filter { $0.status == "active" }
                .map(\.accountID)
        )
        var devicePublicKeys = localTrust.devicePublicKeys
        var snapshotDeviceOwners: [UUID: UUID] = [:]
        for device in envelope.devices {
            guard activeAccountIDs.contains(device.accountID),
                  snapshotDeviceOwners.updateValue(
                    device.accountID,
                    forKey: device.deviceID
                  ) == nil,
                  let key =
                    CloudDevicePublicKeyDecoder.x963Representation(
                        fromJWKJSON: device.publicKeyJWK
                    ) else {
                throw CloudContractError.invalidDeviceSignature
            }
            if let existing = devicePublicKeys[device.deviceID],
               existing != key {
                throw CloudContractError.invalidDeviceSignature
            }
            devicePublicKeys[device.deviceID] = key
        }
        return CloudTrustSnapshot(
            capabilityPublicKeyPEM: capabilityKey,
            devicePublicKeys: devicePublicKeys,
            revokedCertificateIDs:
                localTrust.revokedCertificateIDs.union(revokedInSnapshot)
        )
    }

    private static func validatedOperationForRebuild(
        envelope: CloudOperationEnvelope,
        authorizationDate: Date?,
        trust: CloudTrustSnapshot,
        expectedBootstrapVersion: Int,
        cutoffAt: Date?
    ) throws -> CloudOperationEnvelope? {
        guard let publicKey = trust.capabilityPublicKeyPEM, !publicKey.isEmpty else { throw CloudContractError.invalidCertificate }
        let claims = try CapabilityCertificateVerifier.verify(envelope.capabilityCertificate, publicKeyPEM: publicKey)
        guard !trust.revokedCertificateIDs.contains(claims.certificateID), let deviceKey = trust.devicePublicKeys[claims.deviceID] else {
            throw CloudContractError.capabilityDenied
        }
        return try validatedOperationForRebuild(
            envelope: envelope,
            claims: claims,
            devicePublicKeyX963: deviceKey,
            authorizationDate: authorizationDate,
            expectedBootstrapVersion: expectedBootstrapVersion,
            cutoffAt: cutoffAt
        )
    }

    /// Returns nil only for a cryptographically trusted ordinary operation
    /// whose final state is already represented by a version-2 baseline. A
    /// thrown error remains a quarantined warning at the record ingestion
    /// boundary; callers therefore cannot use the cutoff to bypass signature,
    /// scope, certificate-time, tombstone, restore, or post-cutoff checks.
    static func validatedOperationForRebuild(
        envelope: CloudOperationEnvelope,
        claims: CapabilityCertificateClaims,
        devicePublicKeyX963: Data,
        authorizationDate: Date? = nil,
        expectedBootstrapVersion: Int,
        cutoffAt: Date?
    ) throws -> CloudOperationEnvelope? {
        try CloudOperationSecurity.validateAuthenticityAndIntegrity(
            envelope: envelope,
            claims: claims,
            devicePublicKeyX963: devicePublicKeyX963,
            authorizationDate: authorizationDate
        )
        if isCoveredOrdinaryOperation(
            envelope,
            authorizationDate: authorizationDate,
            expectedBootstrapVersion: expectedBootstrapVersion,
            cutoffAt: cutoffAt
        ) {
            return nil
        }
        try CloudOperationSecurity.validateRequiredCapability(envelope: envelope, claims: claims)
        return envelope
    }

    private static func isCoveredOrdinaryOperation(
        _ envelope: CloudOperationEnvelope,
        authorizationDate: Date?,
        expectedBootstrapVersion: Int,
        cutoffAt: Date?
    ) -> Bool {
        guard expectedBootstrapVersion >= 2,
              let cutoffAt,
              let authorizationDate,
              authorizationDate <= cutoffAt,
              envelope.modifiedAt <= cutoffAt,
              envelope.deletedAt == nil,
              envelope.entityType == CloudEntityType.farm.rawValue,
              envelope.entityID == envelope.farmID,
              let payload = try? JSONDecoder.cloudRebuild.decode(FarmCommandCloudPayload.self, from: envelope.payload),
              payload.kind == .updateFarmLocation else {
            return false
        }
        return true
    }

    private static func validate(
        asset: FarmAssetEnvelope,
        authorizationDate: Date,
        trust: CloudTrustSnapshot,
        signatureVersion: Int?
    ) throws {
        guard let publicKey = trust.capabilityPublicKeyPEM, !publicKey.isEmpty else { throw CloudContractError.invalidCertificate }
        let claims = try CapabilityCertificateVerifier.verify(asset.capabilityCertificate, publicKeyPEM: publicKey)
        guard claims.farmID == asset.farmID,
              claims.accountID == asset.modifiedByAccountID,
              claims.deviceID == asset.modifiedByDeviceID,
              claims.capabilities.contains(.recordProduction),
              claims.isValid(at: authorizationDate),
              !trust.revokedCertificateIDs.contains(claims.certificateID),
              let key = trust.devicePublicKeys[claims.deviceID] else { throw CloudContractError.capabilityDenied }
        _ = try FarmAssetSignatureVerifier.verify(
            envelope: asset,
            declaredVersion: signatureVersion,
            publicKeyX963: key
        )
    }

    private static func assetEnvelope(record: CKRecord, mapper: CloudRecordMapper) throws -> FarmAssetEnvelope {
        guard let farmText = record[CloudRecordField.farmID] as? String,
              let farmID = UUID(uuidString: farmText),
              let assetID = mapper.assetID(from: record.recordID),
              let digest = record[CloudRecordField.payloadDigest] as? String,
              let accountText = record[CloudRecordField.modifiedByAccountID] as? String,
              let accountID = UUID(uuidString: accountText),
              let deviceText = record[CloudRecordField.modifiedByDeviceID] as? String,
              let deviceID = UUID(uuidString: deviceText),
              let certificate = record[CloudRecordField.capabilityCertificate] as? String,
              let signature = record[CloudRecordField.signature] as? Data else { throw CloudContractError.malformedRecord }
        return FarmAssetEnvelope(
            farmID: farmID,
            assetID: assetID,
            entityID: (record["linkedEntityID"] as? String).flatMap(UUID.init(uuidString:)),
            sourceDigest: record[CloudRecordField.sourceDigest] as? String ?? "",
            payloadDigest: digest,
            mimeType: record[CloudRecordField.mimeType] as? String ?? "image/jpeg",
            pixelWidth: (record[CloudRecordField.pixelWidth] as? NSNumber)?.intValue ?? 0,
            pixelHeight: (record[CloudRecordField.pixelHeight] as? NSNumber)?.intValue ?? 0,
            capturedAt: record[CloudRecordField.capturedAt] as? Date,
            byteCount: (record[CloudRecordField.byteCount] as? NSNumber)?.int64Value ?? 0,
            createdAt: record[CloudRecordField.modifiedAt] as? Date ?? .distantPast,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: deviceID,
            capabilityCertificate: certificate,
            signature: signature
        )
    }

    private static func membershipSnapshot(record: CKRecord, trust: CloudTrustSnapshot) throws -> CloudRebuildMembershipSnapshot {
        guard let farmText = record[CloudRecordField.farmID] as? String,
              let farmID = UUID(uuidString: farmText),
              integer(record[CloudRecordField.generation]) >= 0,
              let issuedAt = record[CloudRecordField.issuedAt] as? Date,
              let payload = record[CloudRecordField.payload] as? Data,
              let digest = record[CloudRecordField.payloadDigest] as? String,
              digest == CloudPayloadDigest.hex(for: payload),
              let accountText = record[CloudRecordField.modifiedByAccountID] as? String,
              let accountID = UUID(uuidString: accountText),
              let deviceText = record[CloudRecordField.modifiedByDeviceID] as? String,
              let deviceID = UUID(uuidString: deviceText),
              let certificate = record[CloudRecordField.capabilityCertificate] as? String,
              let signature = record[CloudRecordField.signature] as? Data,
              let publicKey = trust.capabilityPublicKeyPEM,
              let deviceKey = trust.devicePublicKeys[deviceID] else { throw CloudContractError.malformedRecord }
        let generation = integer(record[CloudRecordField.generation])
        let claims = try CapabilityCertificateVerifier.verify(certificate, publicKeyPEM: publicKey)
        guard claims.role == .owner, claims.farmID == farmID, claims.accountID == accountID, claims.deviceID == deviceID, claims.capabilities.contains(.manageMembers), !trust.revokedCertificateIDs.contains(claims.certificateID) else {
            throw CloudContractError.capabilityDenied
        }
        let signingData = MembershipSnapshotActor.signingData(farmID: farmID, generation: generation, issuedAt: issuedAt, payloadDigest: digest, accountID: accountID, deviceID: deviceID)
        try DeviceSignatureVerifier.verify(signature: signature, data: signingData, publicKeyX963: deviceKey)
        return CloudRebuildMembershipSnapshot(farmID: farmID, generation: generation, issuedAt: issuedAt, payload: payload, signedByAccountID: accountID, signedByDeviceID: deviceID, capabilityCertificate: certificate, signature: signature, cloudRecordName: record.recordID.recordName)
    }

    static func sortedOperations(_ operations: [CloudOperationEnvelope]) -> [CloudOperationEnvelope] {
        operations.sorted {
            let leftIsBootstrap = isBootstrapOperation($0)
            let rightIsBootstrap = isBootstrapOperation($1)
            if leftIsBootstrap != rightIsBootstrap { return leftIsBootstrap }
            let left = operationRank($0)
            let right = operationRank($1)
            if leftIsBootstrap {
                if left != right { return left < right }
                if $0.revision != $1.revision { return $0.revision < $1.revision }
            } else {
                // Ordinary operations carry per-entity revision chains. A
                // later command can legitimately have a lower dependency rank
                // (for example unlinking a semen donor), so revision must be
                // the global primary key for this whole group.
                if $0.revision != $1.revision { return $0.revision < $1.revision }
                if left != right { return left < right }
            }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            if $0.entityID != $1.entityID {
                return $0.entityID.uuidString < $1.entityID.uuidString
            }
            return $0.operationID.uuidString < $1.operationID.uuidString
        }
    }

    /// FarmOperation is append-only authority; FarmEntity is only a mutable
    /// projection used for efficient live reads. Rebuilds must never promote
    /// a projection when its immutable source is absent or differs. A stale
    /// projection that points at an existing immutable operation is therefore
    /// ignored instead of making the authoritative rebuild fail.
    static func reconcileAuthoritativeOperationSources(
        immutableOperations: [CloudOperationEnvelope],
        projections: [CloudOperationEnvelope],
        expectedBaselineVersion: Int,
        cutoffAt: Date?
    ) throws -> [CloudOperationEnvelope] {
        var byID: [UUID: CloudOperationEnvelope] = [:]
        for operation in immutableOperations {
            if let existing = byID[operation.operationID], existing != operation {
                throw CloudRebuildError.stagingValidation(
                    "同一 operationID 存在内容不一致的不可变操作。"
                )
            }
            byID[operation.operationID] = operation
        }
        for projection in projections {
            guard let immutable = byID[projection.operationID] else {
                // A version-2 root intentionally supersedes older ordinary
                // projections and interrupted baseline generations. The same
                // canonicalizer used for the final bundle must prove that a
                // projection is discarded before its missing immutable source
                // may be ignored. This narrowly permits the previously
                // authorized 521-baseline cleanup without promoting it again.
                if try canonicalizeBaselineOperations(
                    [projection],
                    expectedVersion: expectedBaselineVersion,
                    cutoffAt: cutoffAt
                ).isEmpty {
                    continue
                }
                throw CloudRebuildError.stagingValidation(
                    "实体投影缺少对应的不可变 FarmOperation。"
                )
            }
            // The projection record is mutable and older clients can leave
            // non-authoritative fields (notably modifiedAt) different from the
            // append-only source. The independently validated FarmOperation
            // remains the sole rebuild input.
            _ = immutable
        }
        return Array(byID.values)
    }

    private static func isBootstrapOperation(_ envelope: CloudOperationEnvelope) -> Bool {
        (try? JSONDecoder.cloudRebuild.decode(FarmCommandCloudPayload.self, from: envelope.payload).kind) == .bootstrapEntity
    }

    /// A refreshed baseline reuses unchanged version-1 snapshots and replaces
    /// only changed logical slots with version-2 snapshots. Operations already
    /// represented by the refreshed snapshot are omitted; tombstones remain so
    /// deleted records and assets stay deleted.
    static func canonicalizeBaselineOperations(
        _ operations: [CloudOperationEnvelope],
        expectedVersion: Int,
        cutoffAt: Date?
    ) throws -> [CloudOperationEnvelope] {
        guard expectedVersion >= 2, let cutoffAt else { return operations }

        struct LogicalEntity: Hashable {
            let entityType: String
            let entityID: UUID
        }
        struct LogicalSlot: Hashable {
            let entity: LogicalEntity
            let slot: String
        }
        struct Candidate {
            let envelope: CloudOperationEnvelope
            let version: Int
        }

        var candidates: [LogicalSlot: [Candidate]] = [:]
        var passthrough: [CloudOperationEnvelope] = []
        var deletedBeforeCutoff = Set<LogicalEntity>()

        for operation in operations {
            let payload = try JSONDecoder.cloudRebuild.decode(FarmCommandCloudPayload.self, from: operation.payload)
            if payload.kind == .bootstrapEntity {
                guard let snapshotData = payload.dataValues["snapshot"] else {
                    throw RemoteDomainApplyError.invalidPayload("snapshot")
                }
                let snapshot = try JSONDecoder.cloudRebuild.decode(BootstrapEntityEnvelopeV1.self, from: snapshotData)
                try snapshot.validate(for: operation)
                let version = payload.integers["baselineVersion"] ?? 1
                if version >= 2 {
                    guard let candidateCutoff = payload.dates["baselineCutoffAt"] else {
                        throw RemoteDomainApplyError.invalidPayload("baselineCutoffAt")
                    }
                    // Only the baseline generation named by the ready root is
                    // authoritative. A signed but interrupted later refresh
                    // must not be mixed into the root's entity count/digest.
                    guard CloudRebuildBootstrapSnapshot.milliseconds(candidateCutoff) ==
                            CloudRebuildBootstrapSnapshot.milliseconds(cutoffAt) else {
                        continue
                    }
                }
                let slot = payload.strings["baselineSlot"] ?? legacyBaselineSlot(snapshot)
                let key = LogicalSlot(
                    entity: LogicalEntity(entityType: snapshot.entityType, entityID: snapshot.entityID),
                    slot: slot
                )
                candidates[key, default: []].append(Candidate(
                    envelope: operation,
                    version: version
                ))
                continue
            }

            if operation.modifiedAt <= cutoffAt {
                if payload.kind == .tombstoneEntity,
                   let entityType = payload.strings["entityType"],
                   let entityID = payload.identifiers["entityID"] {
                    deletedBeforeCutoff.insert(LogicalEntity(entityType: entityType, entityID: entityID))
                    passthrough.append(operation)
                } else if payload.kind == .restoreTombstonedEntity {
                    // Retain recovery commands because their target is the
                    // tombstone identity rather than the restored entity ID.
                    passthrough.append(operation)
                }
                continue
            }
            passthrough.append(operation)
        }

        for (slot, values) in candidates {
            let usable = values.filter { $0.version <= expectedVersion }
            guard let selectedVersion = usable.map(\.version).max() else { continue }
            if deletedBeforeCutoff.contains(slot.entity), selectedVersion < expectedVersion {
                continue
            }
            passthrough.append(contentsOf: usable.filter { $0.version == selectedVersion }.map(\.envelope))
        }
        return passthrough
    }

    private static func legacyBaselineSlot(_ snapshot: BootstrapEntityEnvelopeV1) -> String {
        switch CloudEntityType(rawValue: snapshot.entityType) {
        case .farm:
            let payload = try? JSONDecoder.cloudRebuild.decode(FarmCommandCloudPayload.self, from: snapshot.sourcePayload)
            return payload?.kind == .updateFarmLocation ? "1" : "0"
        case .semenDonor:
            let payload = try? JSONDecoder.cloudRebuild.decode(FarmCommandCloudPayload.self, from: snapshot.sourcePayload)
            if case .upsertSemenDonor(let draft) = payload?.careCommand {
                return draft.linkedRamID == nil ? "5" : "25"
            }
            return "5"
        case .pen, .breedingProgram, .productionBatch, .feedIngredient, .feedRecipe, .inventoryLot, .semen, .careRule:
            return "10"
        case .sheep, .feedRecipeComponent:
            return "20"
        case .weight, .weaning, .transfer, .removal, .batchMembership, .feed, .health, .reproduction, .note:
            return "30"
        case .pedigreeChange:
            return "35"
        case .alertDeferral:
            return "40"
        default:
            return "revision-\(snapshot.sourceRevision)"
        }
    }

    private static func operationRank(_ envelope: CloudOperationEnvelope) -> Int {
        var encoded = envelope.payload
        var resolvedPayload: FarmCommandCloudPayload?
        for _ in 0..<16 {
            guard let payload = try? JSONDecoder.cloudRebuild.decode(FarmCommandCloudPayload.self, from: encoded) else { return 900 }
            switch payload.kind {
            case .bootstrapEntity:
                guard let snapshotData = payload.dataValues["snapshot"],
                      let snapshot = try? JSONDecoder.cloudRebuild.decode(BootstrapEntityEnvelopeV1.self, from: snapshotData) else { return 900 }
                encoded = snapshot.sourcePayload
            case .recoverEntity:
                guard let sourceData = payload.dataValues["resolvedPayload"] else { return 900 }
                encoded = sourceData
            default:
                resolvedPayload = payload
            }
            if resolvedPayload != nil { break }
        }
        guard let payload = resolvedPayload else { return 900 }
        return switch payload.kind {
        case .createFarm: 0
        case .updateFarmLocation: 5
        case .createPen, .addIngredient, .createRecipe, .receiveInventory, .addSemen, .createBatch, .createBreedingProgram, .saveFeedIngredient: 10
        case .saveFeedBatch: 11
        case .adjustFeedStock: 12
        case .countFeedStock: 13
        case .saveFeedRecipe: 14
        case .updatePen, .setPenActive, .addSheep, .updateSheepProfile, .addRecipeComponent: 20
        case .care:
            switch payload.careCommand {
            case .upsertSemenDonor(let draft): draft.linkedRamID == nil ? 5 : 25
            case .setSemenDonor: 12
            case .updateSheepPedigree: 25
            case .setBreedingRam: 20
            case .restorePedigreeAudit: 35
            case .updateRules, .updateOperationalAlertRules: 10
            case .deferOperationalAlert: 40
            default: 30
            }
        case .recordWeight, .correctWeight, .recordWeaning, .transferSheep, .correctTransfer, .removeSheep, .correctRemoval, .restoreSheep, .recordFeed, .recordFeedV2, .importHistoricalFeed, .recordHealth, .recordReproduction, .addNote, .addPhoto, .assignBatchMembership, .leaveBatchMembership: 30
        case .recordFeedTroughObservation: 31
        case .tombstoneEntity, .restoreTombstonedEntity, .resolveConflict, .recoverEntity, .bootstrapEntity: 40
        }
    }

    static func entityDigest(_ operations: [CloudOperationEnvelope]) -> String {
        let text = operations.sorted { $0.operationID.uuidString < $1.operationID.uuidString }.map {
            "\($0.operationID.uuidString.lowercased()):\($0.revision):\($0.payloadDigest)"
        }.joined(separator: "\n")
        return CloudPayloadDigest.hex(for: Data(text.utf8))
    }

    private static func integer(_ value: CKRecordValue?) -> Int {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue ?? -1
    }

    /// Final fail-closed comparison used immediately before replacing the
    /// local cache. A nil expected snapshot is only valid while the cloud root
    /// also has no migration-baseline fields.
    static func validateCurrentBootstrapRoot(
        _ rootRecord: CKRecord,
        expected: CloudRebuildBootstrapSnapshot?
    ) throws {
        let state = rootRecord[CloudRecordField.bootstrapState] as? String
        let digest = rootRecord[CloudRecordField.bootstrapDigest] as? String
        let storedVersion = Self.integer(rootRecord[CloudRecordField.bootstrapVersion])
        let cutoffMilliseconds = CloudRebuildBootstrapSnapshot.milliseconds(
            rootRecord[CloudRecordField.bootstrapCutoffAt] as? Date
        )
        let entityCount = Self.integer(rootRecord[CloudRecordField.bootstrapEntityCount])
        let photoCount = Self.integer(rootRecord[CloudRecordField.bootstrapPhotoCount])

        guard let expected else {
            let hasBaselineIdentity = state != nil ||
                digest != nil ||
                storedVersion > 0 ||
                cutoffMilliseconds != nil ||
                rootRecord[CloudRecordField.bootstrapEntityCount] != nil ||
                rootRecord[CloudRecordField.bootstrapPhotoCount] != nil
            guard !hasBaselineIdentity else {
                throw CloudRebuildError.authoritativeBaselineChanged
            }
            return
        }

        let currentVersion = storedVersion > 0 ? storedVersion : 1
        guard state == "ready",
              digest == expected.digest,
              currentVersion == expected.normalizedVersion,
              cutoffMilliseconds == expected.cutoffAtMilliseconds,
              entityCount == expected.entityCount,
              photoCount == expected.photoCount else {
            throw CloudRebuildError.authoritativeBaselineChanged
        }
    }

    /// Compares the mutable FarmRoot identity captured by staging with the
    /// record fetched immediately before commit. Legacy bundles have no exact
    /// millisecond identity and therefore fail closed, requiring a new rebuild.
    static func validateCurrentRootIdentity(
        _ current: CloudRebuildRootSnapshot,
        expected: CloudRebuildRootSnapshot
    ) throws {
        guard current.farmID == expected.farmID,
              current.ownerAccountID == expected.ownerAccountID else {
            throw CloudRebuildError.farmMismatch
        }
        guard let expectedMilliseconds = expected.modifiedAtMilliseconds,
              let currentMilliseconds = current.modifiedAtMilliseconds,
              current.name == expected.name,
              currentMilliseconds == expectedMilliseconds else {
            throw CloudRebuildError.authoritativeRootChanged
        }
    }

    static func canAdvanceBuildSession(status: CloudRebuildStatus, isLatest: Bool) -> Bool {
        guard isLatest else { return false }
        return switch status {
        case .preparing, .fetching, .downloadingAssets, .validating: true
        case .readyToCommit, .committing, .completed, .failed, .cancelled: false
        }
    }

    static func validateBootstrapEvidence(
        snapshots: [BootstrapEntityEnvelopeV1],
        verifiedAssetCount: Int,
        expectedDigest: String,
        expectedEntityCount: Int,
        expectedPhotoCount: Int
    ) throws {
        guard snapshots.count == expectedEntityCount else {
            throw CloudRebuildError.stagingValidation(
                "迁移云端基线实体数量不一致：期望 \(expectedEntityCount)，实际 \(snapshots.count)。"
            )
        }
        let digestLines = snapshots.map {
            "\($0.entityType):\($0.entityID.uuidString.lowercased()):\($0.sourcePayloadDigest)"
        }.sorted()
        let actualDigest = CloudPayloadDigest.hex(for: Data(digestLines.joined(separator: "\n").utf8))
        guard actualDigest == expectedDigest else {
            throw CloudRebuildError.stagingValidation("迁移云端基线摘要不一致。")
        }
        // The root stores the migration-time photo count. Valid photos added
        // after bootstrap are legitimate current records, so equality would
        // make every later reinstall fail as soon as a user adds a photo.
        guard verifiedAssetCount >= expectedPhotoCount else {
            throw CloudRebuildError.stagingValidation(
                "迁移云端基线照片不完整：至少需要 \(expectedPhotoCount) 张，实际通过校验 \(verifiedAssetCount) 张。"
            )
        }
    }

    private func validateAuthoritativeRootStillMatches(bundle: CloudRebuildBundle) async throws {
        guard let binding = try await persistence.bindingSnapshot(farmID: bundle.farmID),
              binding.databaseScope == bundle.scope else {
            throw CloudRebuildError.bindingMissing
        }
        let database = bundle.scope == .privateDatabase
            ? cloudContainer.privateCloudDatabase
            : cloudContainer.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let recordID = CKRecord.ID(
            recordName: "root_\(bundle.farmID.uuidString.lowercased())",
            zoneID: zoneID
        )
        let currentRoot = try await database.record(for: recordID)
        let currentValue = try mapper.farmRootValue(from: currentRoot)
        let currentSnapshot = CloudRebuildRootSnapshot(
            farmID: currentValue.farmID,
            name: currentValue.name,
            ownerAccountID: currentValue.ownerAccountID,
            modifiedAt: currentValue.modifiedAt
        )
        try Self.validateCurrentRootIdentity(currentSnapshot, expected: bundle.root)
        try Self.validateCurrentBootstrapRoot(currentRoot, expected: bundle.bootstrap)
    }

    func createSession(id: UUID, farmID: UUID, scope: CloudDatabaseScope, reason: CloudRebuildReason, relativePath: String) throws {
        guard !committingFarmIDs.contains(farmID) else {
            throw CloudRebuildError.commitInProgress
        }
        let context = ModelContext(modelContainer)
        let sameFarmSessions = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).filter {
            $0.farmID == farmID
        }
        for old in sameFarmSessions {
            // Cancel every retained in-memory task for this farm, even if an
            // earlier bug already changed its persisted status.
            activeTasks[old.id]?.cancel()
            activeTasks[old.id] = nil
            activeTaskTokens[old.id] = nil
            if old.status.isRunning || old.status == .readyToCommit {
                old.statusRawValue = CloudRebuildStatus.cancelled.rawValue
                old.lastErrorCode = "superseded"
                old.lastErrorMessage = "已由新的重建会话替代。"
                old.updatedAt = .now
            }
        }
        let replacement = CloudRebuildSessionRecord(
            id: id,
            farmID: farmID,
            databaseScope: scope,
            reason: reason,
            stagingRelativePath: relativePath
        )
        if let newestCreatedAt = sameFarmSessions.map(\.createdAt).max(), replacement.createdAt <= newestCreatedAt {
            replacement.createdAt = newestCreatedAt.addingTimeInterval(0.001)
            replacement.updatedAt = replacement.createdAt
        }
        context.insert(replacement)
        try context.save()
    }

    private func session(id: UUID) throws -> CloudRebuildSessionRecord? {
        try ModelContext(modelContainer).fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first { $0.id == id }
    }

    private func issues(sessionID: UUID) throws -> [CloudRebuildIssueRecord] {
        try ModelContext(modelContainer).fetch(FetchDescriptor<CloudRebuildIssueRecord>()).filter { $0.sessionID == sessionID }
    }

    private func updateSession(_ id: UUID, mutate: (CloudRebuildSessionRecord) -> Void) throws {
        let context = ModelContext(modelContainer)
        guard let value = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: { $0.id == id }) else { throw CloudRebuildError.sessionMissing }
        mutate(value)
        value.updatedAt = .now
        try context.save()
    }

    private func updateBuildSession(_ id: UUID, mutate: (CloudRebuildSessionRecord) -> Void) throws {
        let context = ModelContext(modelContainer)
        guard let value = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: { $0.id == id }) else {
            throw CloudRebuildError.sessionMissing
        }
        let isLatest = try isLatestSession(id, farmID: value.farmID, context: context)
        guard Self.canAdvanceBuildSession(status: value.status, isLatest: isLatest) else {
            throw CancellationError()
        }
        mutate(value)
        value.updatedAt = .now
        try context.save()
    }

    private func requireCurrentBuildSession(_ id: UUID) throws {
        let context = ModelContext(modelContainer)
        guard let value = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: { $0.id == id }) else {
            throw CloudRebuildError.sessionMissing
        }
        let isLatest = try isLatestSession(id, farmID: value.farmID, context: context)
        guard Self.canAdvanceBuildSession(status: value.status, isLatest: isLatest) else {
            throw CancellationError()
        }
    }

    private func requireCommitSession(_ id: UUID, farmID: UUID) throws {
        let context = ModelContext(modelContainer)
        guard let value = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: { $0.id == id }),
              value.farmID == farmID,
              value.status == .committing,
              try isLatestSession(id, farmID: farmID, context: context) else {
            throw CloudRebuildError.sessionNotReady
        }
    }

    private func isLatestSession(_ id: UUID, farmID: UUID) throws -> Bool {
        let context = ModelContext(modelContainer)
        return try isLatestSession(id, farmID: farmID, context: context)
    }

    private func isLatestSession(_ id: UUID, farmID: UUID, context: ModelContext) throws -> Bool {
        let latest = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter { $0.farmID == farmID }
            .max {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        return latest?.id == id
    }

    private func addIssue(
        sessionID: UUID,
        farmID: UUID,
        severity: CloudRebuildIssueSeverity = .blocking,
        code: String,
        recordName: String? = nil,
        detail: String
    ) throws {
        try requireCurrentBuildSession(sessionID)
        let context = ModelContext(modelContainer)
        context.insert(CloudRebuildIssueRecord(sessionID: sessionID, farmID: farmID, severity: severity, code: code, recordName: recordName, detail: detail))
        try context.save()
    }

    private func workspaceURL(sessionID: UUID) throws -> URL {
        let context = ModelContext(modelContainer)
        guard let value = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: { $0.id == sessionID }) else { throw CloudRebuildError.sessionMissing }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appending(path: value.stagingRelativePath, directoryHint: .isDirectory)
    }

    private func saveBundle(_ bundle: CloudRebuildBundle, sessionID: UUID) throws {
        let data = try JSONEncoder.cloudRebuild.encode(bundle)
        let url = try workspaceURL(sessionID: sessionID).appending(path: "bundle.json")
        try data.write(to: url, options: .atomic)
    }

    private func loadBundle(sessionID: UUID) throws -> CloudRebuildBundle {
        let data = try Data(contentsOf: workspaceURL(sessionID: sessionID).appending(path: "bundle.json"))
        return try JSONDecoder.cloudRebuild.decode(CloudRebuildBundle.self, from: data)
    }

    private func removeStagingContents(sessionID: UUID) throws {
        let url = try workspaceURL(sessionID: sessionID)
        try? FileManager.default.removeItem(at: url)
    }

    private func markCancelled(sessionID: UUID, taskToken: UUID) async throws {
        guard activeTaskTokens[sessionID] == taskToken else { return }
        guard let value = try session(id: sessionID) else { return }
        let isLatest = try isLatestSession(sessionID, farmID: value.farmID)
        guard Self.canAdvanceBuildSession(status: value.status, isLatest: isLatest) else {
            return
        }
        try updateSession(sessionID) { session in
            session.statusRawValue = CloudRebuildStatus.cancelled.rawValue
            session.lastErrorCode = "cancelled"
            session.lastErrorMessage = CloudRebuildError.cancelled.localizedDescription
        }
        _ = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: value.farmID,
            expectedState: .rebuildingCache,
            expectedLastErrorCode: nil,
            newState: .active,
            newLastErrorCode: "rebuildCancelled"
        )
    }

    private func markFailed(sessionID: UUID, taskToken: UUID, error: Error) async throws {
        guard activeTaskTokens[sessionID] == taskToken else { return }
        guard let value = try session(id: sessionID) else { return }
        let isLatest = try isLatestSession(sessionID, farmID: value.farmID)
        guard Self.canAdvanceBuildSession(status: value.status, isLatest: isLatest) else {
            return
        }
        try updateSession(sessionID) { session in
            session.statusRawValue = CloudRebuildStatus.failed.rawValue
            session.lastErrorCode = String(describing: type(of: error))
            session.lastErrorMessage = error.localizedDescription
            session.retryAt = .now.addingTimeInterval(60)
        }
        _ = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: value.farmID,
            expectedState: .rebuildingCache,
            expectedLastErrorCode: nil,
            newState: .rebuildingCache,
            newLastErrorCode: "rebuildValidationFailed"
        )
    }

    private func clearTask(sessionID: UUID, taskToken: UUID) {
        guard activeTaskTokens[sessionID] == taskToken else { return }
        activeTasks[sessionID] = nil
        activeTaskTokens[sessionID] = nil
    }
}

private extension JSONEncoder {
    static var cloudRebuild: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var cloudRebuild: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
