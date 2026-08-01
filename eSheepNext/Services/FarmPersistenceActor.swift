import CloudKit
import Foundation
import SwiftData

struct PendingCloudOperation: Sendable {
    let envelope: CloudOperationEnvelope
    let databaseScope: CloudDatabaseScope
}

enum SharedFarmAdmissionPolicy {
    static let pendingFarmName = "待加入的共享牧场"

    static func isLocallyOwnedForDisplay(
        farmOwnerAccountID: UUID,
        activeAccountID: UUID,
        bindingScope: CloudDatabaseScope?
    ) -> Bool {
        farmOwnerAccountID == activeAccountID &&
            bindingScope != .sharedDatabase
    }

    static func isReadyForDisplay(
        bindingScope: CloudDatabaseScope,
        bindingState: CloudFarmBindingState,
        farmName: String,
        membershipStatus: FarmMembershipStatus
    ) -> Bool {
        bindingScope == .sharedDatabase &&
            bindingState == .active &&
            farmName != pendingFarmName &&
            membershipStatus == .active
    }

    static func isPendingAdmission(
        bindingScope: CloudDatabaseScope,
        bindingState: CloudFarmBindingState,
        farmName: String,
        membershipStatus: FarmMembershipStatus?
    ) -> Bool {
        guard bindingScope == .sharedDatabase,
              bindingState != .accessRevoked else {
            return false
        }
        guard let membershipStatus else { return true }
        return !isReadyForDisplay(
            bindingScope: bindingScope,
            bindingState: bindingState,
            farmName: farmName,
            membershipStatus: membershipStatus
        )
    }
}

struct CloudFarmBindingSnapshot: Sendable {
    let farmID: UUID
    let ownerAccountID: UUID
    let zoneName: String
    let zoneOwnerName: String
    let databaseScope: CloudDatabaseScope
    let shareRecordName: String?
    let state: CloudFarmBindingState
    let lastErrorCode: String?
}

struct CloudRecoveryRootExpectation: Sendable {
    let binding: CloudFarmBindingSnapshot
    let baseline: OwnerFarmRecoveryBaselineIdentity
}

struct CloudTrustSnapshot: Sendable {
    let capabilityPublicKeyPEM: String?
    let devicePublicKeys: [UUID: Data]
    let revokedCertificateIDs: Set<String>
}

struct FarmCacheReplacementResult: Sendable, Equatable {
    let appliedOperationCount: Int
    let preservedOutboxCount: Int
    let highestRevision: Int
    let entityDigest: String
}

private struct LocalPhotoAssetSnapshot {
    let id: UUID
    let farmID: UUID
    let sheepID: UUID?
    let legacySourceKey: String
    let originalEarTag: String
    let relativePath: String
    let sha256: String
    let mimeType: String
    let sourceSHA256: String
    let sourcePixelWidth: Int
    let sourcePixelHeight: Int
    let cloudPixelWidth: Int
    let cloudPixelHeight: Int
    let capturedAt: Date?
    let cloudRecordName: String?
    let wasCloudAuthoritative: Bool
    let recoveryRecordName: String?
    let recoveryBackedUpAt: Date?
    let createdAt: Date

    init(_ asset: PhotoAssetRecord) {
        id = asset.id
        farmID = asset.farmID
        sheepID = asset.sheepID
        legacySourceKey = asset.legacySourceKey
        originalEarTag = asset.originalEarTag
        relativePath = asset.relativePath
        sha256 = asset.sha256
        mimeType = asset.mimeType
        sourceSHA256 = asset.sourceSHA256
        sourcePixelWidth = asset.sourcePixelWidth
        sourcePixelHeight = asset.sourcePixelHeight
        cloudPixelWidth = asset.cloudPixelWidth
        cloudPixelHeight = asset.cloudPixelHeight
        capturedAt = asset.capturedAt
        cloudRecordName = asset.cloudRecordName
        wasCloudAuthoritative = asset.isCloudAuthoritative
        recoveryRecordName = asset.recoveryRecordName
        recoveryBackedUpAt = asset.recoveryBackedUpAt
        createdAt = asset.createdAt
    }
}

actor FarmPersistenceActor {
    private struct ValidatedLiveOperation {
        let record: CKRecord
        let envelope: CloudOperationEnvelope
        let receiptIdentity: OperationReceiptIdentity
    }

    private let container: ModelContainer
    private let mapper = CloudRecordMapper()
    private let capabilitySigningPublicKeyPEMOverride: String?
    private var recoveredBaselineCache: [UUID: MigrationCloudBaselineSnapshot] = [:]

    init(container: ModelContainer, capabilitySigningPublicKeyPEMOverride: String? = nil) {
        self.container = container
        self.capabilitySigningPublicKeyPEMOverride = capabilitySigningPublicKeyPEMOverride
    }

    private var capabilitySigningPublicKeyPEM: String? {
        capabilitySigningPublicKeyPEMOverride ??
            (Bundle.main.object(forInfoDictionaryKey: "CAPABILITY_SIGNING_PUBLIC_KEY_PEM") as? String)
    }

    func cloudTrustSnapshot(farmID: UUID) throws -> CloudTrustSnapshot {
        let context = ModelContext(container)
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        let revoked = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
            .filter { $0.farmID == farmID }
        return CloudTrustSnapshot(
            capabilityPublicKeyPEM: capabilitySigningPublicKeyPEM,
            devicePublicKeys: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.publicKeyX963) }),
            revokedCertificateIDs: Set(revoked.map(\.serverCertificateID))
        )
    }

    /// Records a recovery-engine failure only when the binding is still the
    /// exact rebuild lock observed at the start of that attempt. A delegate
    /// may install a stronger security reason while CloudKit is fetching; an
    /// older attempt must never overwrite it or downgrade an active binding.
    @discardableResult
    func recordRecoveryEngineFailureIfUnchanged(
        farmID: UUID,
        expectedLastErrorCode: String?,
        failureCode: String
    ) throws -> Bool {
        try transitionRecoveryBindingIfUnchanged(
            farmID: farmID,
            expectedState: .rebuildingCache,
            expectedLastErrorCode: expectedLastErrorCode,
            newState: .rebuildingCache,
            newLastErrorCode: failureCode
        )
    }

    /// Compare-and-swap for every rebuild/recovery state transition. Security
    /// callbacks may change either the state or its reason while another actor
    /// is suspended; only the exact observer is allowed to finish its phase.
    @discardableResult
    func transitionRecoveryBindingIfUnchanged(
        farmID: UUID,
        expectedState: CloudFarmBindingState,
        expectedLastErrorCode: String?,
        newState: CloudFarmBindingState,
        newLastErrorCode: String?
    ) throws -> Bool {
        let context = ModelContext(container)
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farmID }) else {
            throw CloudSyncError.farmBindingMissing
        }
        guard binding.state == expectedState,
              binding.lastErrorCode == expectedLastErrorCode else {
            return false
        }
        binding.stateRawValue = newState.rawValue
        binding.lastErrorCode = newLastErrorCode
        binding.updatedAt = .now
        try context.save()
        return true
    }

    /// Activates only the farm that remained locked throughout a successful
    /// recovery-engine fetch. A concurrent account or access change wins and
    /// leaves the binding fail-closed.
    func recoveryRootExpectation(
        farmID: UUID,
        scope: CloudDatabaseScope,
        expectedLastErrorCode: String
    ) throws -> CloudRecoveryRootExpectation {
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>()).filter {
                $0.farmID == farmID &&
                $0.databaseScope == scope &&
                $0.state == .rebuildingCache &&
                $0.lastErrorCode == expectedLastErrorCode
        }
        guard bindings.count == 1, let binding = bindings.first,
              binding.zoneName == CloudZoneName.forFarm(farmID) else {
            throw CloudSyncError.farmBindingMissing
        }
        let farms = try context.fetch(FetchDescriptor<FarmRecord>()).filter {
            $0.id == farmID &&
                $0.ownerAccountID == binding.ownerAccountID &&
                $0.deletedAt == nil
        }
        guard farms.count == 1,
              let baseline = try OwnerFarmRecoveryCoordinator.localRecoveryIdentity(
                  farmID: farmID,
                  ownerAccountID: binding.ownerAccountID,
                  scope: scope,
                  context: context
              ) else {
            throw CloudSyncError.recoveryCatchUpFailed("本机缺少可与云端根记录逐项核对的 v2 基线身份。")
        }
        return CloudRecoveryRootExpectation(
            binding: CloudFarmBindingSnapshot(
                farmID: binding.farmID,
                ownerAccountID: binding.ownerAccountID,
                zoneName: binding.zoneName,
                zoneOwnerName: binding.zoneOwnerName,
                databaseScope: binding.databaseScope,
                shareRecordName: binding.shareRecordName,
                state: binding.state,
                lastErrorCode: binding.lastErrorCode
            ),
            baseline: baseline
        )
    }

    func activateAfterRecoveryCatchUp(
        farmID: UUID,
        expected: CloudRecoveryRootExpectation
    ) throws {
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>()).filter { $0.farmID == farmID }
        guard bindings.count == 1, let binding = bindings.first else {
            throw CloudSyncError.farmBindingMissing
        }
        guard binding.state == .rebuildingCache,
              binding.farmID == expected.binding.farmID,
              binding.ownerAccountID == expected.binding.ownerAccountID,
              binding.databaseScope == expected.binding.databaseScope,
              binding.zoneName == expected.binding.zoneName,
              binding.zoneOwnerName == expected.binding.zoneOwnerName,
              binding.lastErrorCode == expected.binding.lastErrorCode,
              try OwnerFarmRecoveryCoordinator.localRecoveryIdentity(
                  farmID: farmID,
                  ownerAccountID: binding.ownerAccountID,
                  scope: binding.databaseScope,
                  context: context
              ) == expected.baseline else {
            throw CloudSyncError.inactiveFarm
        }
        binding.stateRawValue = CloudFarmBindingState.active.rawValue
        binding.lastErrorCode = nil
        binding.updatedAt = .now
        try context.save()
    }

    func captureDiagnosticSnapshot(farmID: UUID, workerHealth: String, cloudAccount: String) throws {
        let context = ModelContext(container)
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farmID }) else {
            throw CloudSyncError.farmBindingMissing
        }
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == farmID }
        let assets = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        var entityParts: [String] = []
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "pen:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "sheep:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "weight:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<WeaningRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "weaning:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<BreedingProgramRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "breedingProgram:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "breedingProgramStep:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "transfer:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "feed:\($0.id):\($0.revision)" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "health:\($0.id):\(CloudDateText.string(from: $0.occurredAt))" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "reproduction:\($0.id):\(CloudDateText.string(from: $0.occurredAt))" })
        entityParts.append(contentsOf: try context.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "note:\($0.id):\($0.revision)" })
        let entityDigest = CloudPayloadDigest.hex(for: Data(entityParts.sorted().joined(separator: "\n").utf8))
        let assetDigest = CloudPayloadDigest.hex(for: Data(assets.map { "\($0.id):\($0.sha256)" }.sorted().joined(separator: "\n").utf8))
        context.insert(CloudSyncDiagnosticSnapshotRecord(
            farmID: farmID,
            workerHealth: workerHealth,
            cloudAccount: cloudAccount,
            zoneName: binding.zoneName,
            databaseScope: binding.databaseScope,
            engineStateModifiedAt: CloudEngineStateDiskStore.modifiedAt(scope: binding.databaseScope),
            pendingOutboxCount: outbox.filter { $0.status == .pending || $0.status == .retryableFailure }.count,
            uploadingOutboxCount: outbox.filter { $0.status == .uploading || $0.status == .awaitingConfirmation }.count,
            blockedOutboxCount: outbox.filter { $0.status == .blockedConflict || $0.status == .rejectedPermission }.count,
            membershipGeneration: binding.securityGeneration,
            authoritativeEntityCount: entityParts.count,
            assetCount: assets.count,
            entityDigest: entityDigest,
            assetDigest: assetDigest
        ))
        try context.save()
    }

    func replaceConfirmedFarmCache(using bundle: CloudRebuildBundle) throws -> FarmCacheReplacementResult {
        try CloudRebuildBundleValidator.validate(bundle)
        let context = ModelContext(container)
        var createdAssetRoot: URL?
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == bundle.farmID }) else {
            throw CloudRebuildError.farmMismatch
        }
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == bundle.farmID }
        let pendingOutbox = outbox.filter { !$0.status.isTerminalDelivery }
        let pendingIDs = Set(pendingOutbox.map(\.operationID))
        let pendingOutboxByOperationID = Dictionary(grouping: pendingOutbox, by: \.operationID)
        let authoritativeByOperationID = Dictionary(uniqueKeysWithValues: bundle.operations.map { ($0.operationID, $0) })
        let retainedUploadTransfers = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).filter {
            $0.farmID == bundle.farmID && $0.direction == .upload
        }
        let incompleteUploadAssetIDs = Set(retainedUploadTransfers.compactMap { transfer -> UUID? in
            transfer.status == .completed ? nil : transfer.assetID
        })
        let localPhotoSnapshots = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter {
                $0.farmID == bundle.farmID &&
                    $0.deletedAt == nil &&
                    (!$0.isCloudAuthoritative || incompleteUploadAssetIDs.contains($0.id))
            }
            .map(LocalPhotoAssetSnapshot.init)
        let pendingOperationPairs = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == bundle.farmID && pendingIDs.contains($0.id) }
            .compactMap { operation -> (operation: DomainOperation, envelope: CloudOperationEnvelope)? in
                guard let envelope = Self.recoveredPendingEnvelope(operation) else { return nil }
                return (operation, envelope)
            }
        let pendingOperationByID = Dictionary(
            uniqueKeysWithValues: pendingOperationPairs.map { ($0.envelope.operationID, $0) }
        )
        let orderedPendingOperations = CloudRebuildActor.sortedOperations(
            pendingOperationPairs.map(\.envelope)
        ).compactMap { pendingOperationByID[$0.operationID] }

        do {
            try purgeConfirmedBusinessCache(farmID: bundle.farmID, context: context)
            farm.name = bundle.root.name
            farm.ownerAccountID = bundle.root.ownerAccountID
            farm.updatedAt = bundle.root.modifiedAt

            // Insert verified assets before replaying tombstones so a deleted
            // cloud photo cannot be resurrected by the cache replacement.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let stagingRoot = support.appending(path: "CloudRebuild/\(bundle.sessionID.uuidString.lowercased())", directoryHint: .isDirectory)
            // A process can crash after the cache save but before the rebuild
            // session is marked completed. A retry must never reuse that
            // already-active directory: if the retry later rolls back, its
            // cleanup would otherwise delete files referenced by the prior
            // committed cache. Give every replacement attempt its own root so
            // failure cleanup is confined to files created by this attempt.
            let assetRootRelativePath = "CloudAssets/\(bundle.farmID.uuidString.lowercased())/\(bundle.sessionID.uuidString.lowercased())/\(UUID().uuidString.lowercased())"
            let assetRoot = support.appending(
                path: "eSheepNext/\(assetRootRelativePath)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
            createdAssetRoot = assetRoot
            for snapshot in bundle.assets {
                let source = stagingRoot.appending(path: snapshot.relativePath)
                let fileName = source.lastPathComponent
                let destination = assetRoot.appending(path: fileName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                let relativePath = "\(assetRootRelativePath)/\(fileName)"
                let photo = PhotoAssetRecord(
                    id: snapshot.envelope.assetID,
                    farmID: bundle.farmID,
                    sheepID: snapshot.envelope.entityID,
                    legacySourceKey: "cloud:\(snapshot.cloudRecordName)",
                    originalEarTag: "",
                    relativePath: relativePath,
                    sha256: snapshot.envelope.payloadDigest,
                    mimeType: snapshot.envelope.mimeType
                )
                photo.sourceSHA256 = snapshot.envelope.sourceDigest
                photo.cloudPixelWidth = snapshot.envelope.pixelWidth
                photo.cloudPixelHeight = snapshot.envelope.pixelHeight
                photo.capturedAt = snapshot.envelope.capturedAt
                photo.createdAt = snapshot.envelope.createdAt
                photo.cloudRecordName = snapshot.cloudRecordName
                photo.isCloudAuthoritative = true
                context.insert(photo)
            }

            // purgeConfirmedBusinessCache has made this farm's business cache
            // empty; keep replay lookups in memory without changing live sync.
            let service = RemoteDomainApplyService(replayAssumesEmptyBusinessStore: true)
            let authoritativeReplay = try RemoteDomainReplayExecutor.replay(
                bundle.operations,
                farmID: bundle.farmID,
                scope: bundle.scope,
                context: context,
                service: service,
                mapper: mapper,
                conflictStage: "云端权威操作",
                baselineCutoffAt: bundle.bootstrap?.cutoffAt
            )
            var earliestHistoryChange = authoritativeReplay.earliestHistoryChange

            for pending in orderedPendingOperations {
                let operation = pending.operation
                let envelope = pending.envelope
                let entityID = envelope.entityID
                let operationOutbox = pendingOutboxByOperationID[operation.id] ?? []
                if let authoritative = authoritativeByOperationID[operation.id] {
                    if Self.pendingOperation(operation, exactlyMatches: authoritative) {
                        var foundMismatchedOutbox = false
                        for item in operationOutbox {
                            if Self.outboxItem(item, exactlyMatches: operation) {
                                item.statusRawValue = OutboxStatus.confirmed.rawValue
                                item.errorMessage = nil
                                item.nextRetryAt = nil
                                item.cloudRecordName = mapper.recordName(for: operation.id)
                            } else {
                                foundMismatchedOutbox = true
                                Self.blockRecoveredPendingOutbox(
                                    [item],
                                    detail: "本机 Outbox 与已上云的同 operationID 操作内容不一致。"
                                )
                            }
                        }
                        if foundMismatchedOutbox {
                            try Self.insertRecoveredPendingConflict(
                                operation: operation,
                                remote: authoritative,
                                reasonCode: "rebuildOutboxIdentityMismatch",
                                context: context
                            )
                        } else {
                            try Self.removeResolvedRecoveredConflicts(
                                for: operation,
                                context: context
                            )
                        }
                    } else {
                        Self.blockRecoveredPendingOutbox(
                            operationOutbox,
                            detail: "本机操作与云端同 operationID 的不可变内容不一致。"
                        )
                        try Self.insertRecoveredPendingConflict(
                            operation: operation,
                            remote: authoritative,
                            reasonCode: "rebuildOperationIdentityMismatch",
                            status: .quarantined,
                            context: context
                        )
                    }
                    continue
                }
                guard !operationOutbox.isEmpty,
                      operationOutbox.allSatisfy(Self.isReplayableRecoveredOutbox) else {
                    continue
                }
                do {
                    switch try service.apply(envelope, context: context) {
                    case .applied(let changedAt):
                        if let changedAt { earliestHistoryChange = min(earliestHistoryChange ?? changedAt, changedAt) }
                    case .duplicate:
                        break
                    case .conflict(let remoteRevision):
                        let remote = bundle.operations
                            .filter { $0.entityID == entityID }
                            .max(by: { $0.revision < $1.revision })
                        Self.blockRecoveredPendingOutbox(
                            operationOutbox,
                            detail: "云端权威版本 \(remoteRevision) 与本机操作基线 \(operation.baseRevision) 不一致，已停止自动覆盖。"
                        )
                        try Self.insertRecoveredPendingConflict(
                            operation: operation,
                            remote: remote,
                            fallbackRemoteRevision: remoteRevision,
                            reasonCode: "rebuildPendingBaseRevisionMismatch",
                            context: context
                        )
                    }
                } catch {
                    let remote = bundle.operations
                        .filter { $0.entityID == entityID }
                        .max(by: { $0.revision < $1.revision })
                    Self.blockRecoveredPendingOutbox(
                        operationOutbox,
                        detail: "本机未确认操作无法在权威缓存上安全重放：\(error.localizedDescription)"
                    )
                    try Self.insertRecoveredPendingConflict(
                        operation: operation,
                        remote: remote,
                        reasonCode: "rebuildPendingReplayRejected",
                        context: context
                    )
                }
            }

            try Self.restoreLocalPhotoAssets(
                localPhotoSnapshots,
                authoritativeAssets: bundle.assets,
                retainedUploadTransfers: retainedUploadTransfers,
                context: context
            )

            if let snapshot = bundle.membershipSnapshot {
                context.insert(FarmMembershipSnapshotRecord(
                    farmID: snapshot.farmID,
                    generation: snapshot.generation,
                    issuedAt: snapshot.issuedAt,
                    payload: snapshot.payload,
                    signedByAccountID: snapshot.signedByAccountID,
                    signedByDeviceID: snapshot.signedByDeviceID,
                    capabilityCertificate: snapshot.capabilityCertificate,
                    signature: snapshot.signature
                ))
            }
            if let bootstrap = bundle.bootstrap {
                let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>())
                let commit: MigrationCommitRecord
                if let existing = commits.first(where: { $0.farmID == bundle.farmID }) {
                    commit = existing
                } else {
                    commit = MigrationCommitRecord(
                        sessionID: bundle.sessionID,
                        sourceChecksum: "cloud-recovered:\(bootstrap.digest)",
                        farmID: bundle.farmID,
                        ownerAccountID: bundle.root.ownerAccountID,
                        recordCountsJSON: "{\"cloudRecovered\":true,\"entityCount\":\(bootstrap.entityCount)}",
                        assetsRelativeDirectory: "",
                        committedAt: bundle.root.modifiedAt
                    )
                    context.insert(commit)
                }
                commit.baselineDigest = bootstrap.digest
                commit.baselineEntityCount = bootstrap.entityCount
                commit.baselinePhotoCount = bootstrap.photoCount
                commit.cloudState = .synced
                commit.cloudSyncedAt = .now
                commit.cloudLastError = nil
                farm.isLocalOnlyMigration = false
            }
            try FarmHistoryRebuilder().rebuild(farmID: bundle.farmID, context: context, from: earliestHistoryChange ?? .distantPast)
            try context.save()
            return FarmCacheReplacementResult(
                appliedOperationCount: authoritativeReplay.appliedOperationCount,
                preservedOutboxCount: pendingOutbox.filter { !$0.status.isTerminalDelivery }.count,
                highestRevision: bundle.operations.map(\.revision).max() ?? 0,
                entityDigest: Self.entityDigest(bundle.operations)
            )
        } catch {
            context.rollback()
            if let createdAssetRoot {
                try? FileManager.default.removeItem(at: createdAssetRoot)
            }
            throw error
        }
    }

    /// Repairs projections created by the legacy v2-bootstrap replay bug
    /// without discarding a CKSyncEngine token that has already completed its
    /// authoritative catch-up. This path is deliberately narrower than a
    /// normal cache rebuild and refuses to run if any post-bundle operation,
    /// changed cloud asset, pending command, or membership change exists.
    func repairLegacyBootstrapProjectionIfUnchanged(
        using bundle: CloudRebuildBundle,
        stagingWorkspace: URL
    ) throws -> Bool {
        try CloudRebuildBundleValidator.validate(bundle)
        guard bundle.scope == .sharedDatabase,
              bundle.bootstrap?.normalizedVersion == 2,
              CloudEngineStateDiskStore.load(scope: bundle.scope) != nil else {
            return false
        }
        let expectedWorkspace = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(
                path: "CloudRebuild/\(bundle.sessionID.uuidString.lowercased())",
                directoryHint: .isDirectory
            )
            .standardizedFileURL
        guard stagingWorkspace.standardizedFileURL == expectedWorkspace else {
            throw CloudRebuildError.stagingValidation("本地投影修复的 staging 路径不匹配。")
        }

        let context = ModelContext(container)
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>())
            .first(where: {
                $0.farmID == bundle.farmID &&
                    $0.databaseScope == bundle.scope &&
                    $0.state == .active
            }),
              binding.lastErrorCode == nil,
              let farm = try context.fetch(FetchDescriptor<FarmRecord>())
                .first(where: { $0.id == bundle.farmID && $0.deletedAt == nil }),
              farm.ownerAccountID == bundle.root.ownerAccountID,
              farm.name == bundle.root.name else {
            return false
        }
        if try context.fetch(FetchDescriptor<SecurityIncidentRecord>())
            .contains(where: {
                $0.farmID == bundle.farmID &&
                    $0.incidentType == LegacyBootstrapProjectionRepair.incidentType
            }) {
            return false
        }

        let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>())
            .filter {
                $0.farmID == bundle.farmID &&
                    $0.databaseScopeRawValue == bundle.scope.rawValue
            }
        let authoritativeOperationIDs = Set(bundle.operations.map(\.operationID))
        guard receipts.count == bundle.operations.count,
              Set(receipts.map(\.operationID)) == authoritativeOperationIDs else {
            return false
        }
        let pendingOutbox = try context.fetch(FetchDescriptor<OutboxItem>())
            .filter { $0.farmID == bundle.farmID && !$0.status.isTerminalDelivery }
        guard pendingOutbox.isEmpty else { return false }

        let currentAssetIdentity = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter {
                $0.farmID == bundle.farmID &&
                    $0.isCloudAuthoritative
            }
            .map {
                [
                    $0.id.uuidString.lowercased(),
                    $0.sha256,
                    $0.sourceSHA256,
                    $0.cloudRecordName ?? "",
                ].joined(separator: ":")
            }
            .sorted()
        let bundleAssetIdentity = bundle.assets.map {
            [
                $0.envelope.assetID.uuidString.lowercased(),
                $0.envelope.payloadDigest,
                $0.envelope.sourceDigest,
                $0.cloudRecordName,
            ].joined(separator: ":")
        }.sorted()
        guard currentAssetIdentity == bundleAssetIdentity else { return false }

        let membershipRecords = try context.fetch(
            FetchDescriptor<FarmMembershipSnapshotRecord>()
        ).filter { $0.farmID == bundle.farmID }
        switch bundle.membershipSnapshot {
        case .none:
            guard membershipRecords.isEmpty else { return false }
        case .some(let expected):
            guard membershipRecords.count == 1,
                  let current = membershipRecords.first,
                  current.generation == expected.generation,
                  current.payloadDigest == CloudPayloadDigest.hex(for: expected.payload),
                  current.signedByAccountID == expected.signedByAccountID,
                  current.signedByDeviceID == expected.signedByDeviceID else {
                return false
            }
        }

        let stagingStoreURL = stagingWorkspace
            .appending(path: "SwiftData", directoryHint: .isDirectory)
            .appending(path: "staging.store")
        let stagingContainer = try AppSchema.makeContainer(
            name: "LegacyBootstrapProjectionRepair",
            url: stagingStoreURL
        )
        let stagingContext = ModelContext(stagingContainer)
        let expectedProjectionDigest = try Self.sheepProjectionDigest(
            farmID: bundle.farmID,
            context: stagingContext
        )
        let currentProjectionDigest = try Self.sheepProjectionDigest(
            farmID: bundle.farmID,
            context: context
        )
        if currentProjectionDigest == expectedProjectionDigest {
            context.insert(SecurityIncidentRecord(
                farmID: bundle.farmID,
                incidentType: LegacyBootstrapProjectionRepair.incidentType,
                recordName: bundle.sessionID.uuidString.lowercased(),
                detail: "已核对 v2 基线历史重放投影，无需修改。"
            ))
            try context.save()
            return false
        }

        let expectedSheep = try stagingContext.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == bundle.farmID }
        let currentSheep = try context.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == bundle.farmID }
        let expectedGroups = Dictionary(grouping: expectedSheep, by: \.id)
        guard expectedGroups.values.allSatisfy({ $0.count == 1 }) else {
            throw CloudRebuildError.stagingValidation(
                "已校验 staging 中存在重复羊只标识，拒绝执行投影修复。"
            )
        }
        let expectedByID = expectedGroups.compactMapValues(\.first)
        guard currentSheep.count == expectedSheep.count,
              Set(currentSheep.map(\.id)) == Set(expectedByID.keys) else {
            throw CloudRebuildError.stagingValidation(
                "本地羊只集合与已校验 staging 不一致，拒绝执行投影修复。"
            )
        }
        for sheep in currentSheep {
            guard let expected = expectedByID[sheep.id] else {
                throw CloudRebuildError.stagingValidation(
                    "本地羊只 \(sheep.id.uuidString.lowercased()) 缺少 staging 投影。"
                )
            }
            // These are cache projections, not new domain mutations. Keep
            // revision/updatedAt unchanged so the local repair cannot create
            // an Outbox write or masquerade as a farm command.
            sheep.statusRawValue = expected.statusRawValue
            sheep.initialPenID = expected.initialPenID
            sheep.currentPenID = expected.currentPenID
            sheep.removedAt = expected.removedAt
            sheep.legacyStatusSnapshotIsAuthoritative =
                expected.legacyStatusSnapshotIsAuthoritative
            sheep.legacyPenSnapshotIsAuthoritative =
                expected.legacyPenSnapshotIsAuthoritative
        }
        try FarmHistoryRebuilder().rebuild(
            farmID: bundle.farmID,
            context: context,
            from: .distantPast
        )
        let repairedProjectionDigest = try Self.sheepProjectionDigest(
            farmID: bundle.farmID,
            context: context
        )
        guard repairedProjectionDigest == expectedProjectionDigest else {
            throw CloudRebuildError.stagingValidation("本地投影修复后仍与已校验 staging 不一致。")
        }
        context.insert(SecurityIncidentRecord(
            farmID: bundle.farmID,
            incidentType: LegacyBootstrapProjectionRepair.incidentType,
            recordName: bundle.sessionID.uuidString.lowercased(),
            detail: "已从同一已验证 staging 原子修复迁移基线羊只投影；未重放云端操作，未重置已完成追赶的 CKSyncEngine 状态。"
        ))
        try context.save()
        return true
    }

    private static func sheepProjectionDigest(
        farmID: UUID,
        context: ModelContext
    ) throws -> String {
        let lines = try context.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == farmID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { sheep in
                [
                    sheep.id.uuidString.lowercased(),
                    sheep.statusRawValue,
                    sheep.initialPenID?.uuidString.lowercased() ?? "",
                    sheep.currentPenID?.uuidString.lowercased() ?? "",
                    sheep.removedAt.map {
                        String(CloudRebuildRootSnapshot.milliseconds($0))
                    } ?? "",
                    sheep.legacyStatusSnapshotIsAuthoritative == true ? "1" : "0",
                    sheep.legacyPenSnapshotIsAuthoritative == true ? "1" : "0",
                ].joined(separator: ":")
            }
        return CloudPayloadDigest.hex(for: Data(lines.joined(separator: "\n").utf8))
    }

    private static func restoreLocalPhotoAssets(
        _ snapshots: [LocalPhotoAssetSnapshot],
        authoritativeAssets: [CloudRebuildAssetSnapshot],
        retainedUploadTransfers: [CloudAssetTransfer],
        context: ModelContext
    ) throws {
        let authoritativeByID = Dictionary(uniqueKeysWithValues: authoritativeAssets.map { ($0.envelope.assetID, $0) })
        for snapshot in snapshots {
            var restoredID = snapshot.id
            if let authoritative = authoritativeByID[snapshot.id] {
                let matchingTransfers = retainedUploadTransfers.filter { $0.assetID == snapshot.id }
                if Self.localPhotoSnapshot(
                    snapshot,
                    exactlyMatches: authoritative.envelope,
                    uploadTransfers: matchingTransfers
                ) {
                    for transfer in matchingTransfers {
                        transfer.statusRawValue = CloudAssetTransferStatus.completed.rawValue
                        transfer.transferredByteCount = transfer.byteCount
                        transfer.lastErrorCode = nil
                        transfer.nextRetryAt = nil
                        transfer.remoteRecordName = authoritative.cloudRecordName
                        transfer.updatedAt = .now
                    }
                    continue
                }
                let hasCloudLineage = snapshot.wasCloudAuthoritative ||
                    snapshot.cloudRecordName != nil ||
                    snapshot.legacySourceKey.hasPrefix("cloud:")
                if hasCloudLineage,
                   authoritative.envelope.payloadDigest == snapshot.sha256,
                   let cloudRow = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: {
                       $0.id == snapshot.id && $0.farmID == snapshot.farmID
                   }) {
                    // This is a local metadata edit of an existing cloud
                    // photo (for example capturedAt). Overlay the local row
                    // and keep its upload pending instead of accepting stale
                    // cloud metadata as confirmation.
                    Self.applyLocalPhotoSnapshot(snapshot, id: snapshot.id, to: cloudRow)
                    cloudRow.cloudRecordName = authoritative.cloudRecordName
                    for transfer in matchingTransfers {
                        transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
                        transfer.transferredByteCount = 0
                        transfer.lastErrorCode = nil
                        transfer.nextRetryAt = nil
                        transfer.remoteRecordName = nil
                        transfer.localRelativePath = snapshot.relativePath
                        transfer.updatedAt = .now
                    }
                    continue
                }
                // Preserve both immutable assets. The cloud ID keeps its
                // authoritative record; the unsynced local file receives a
                // fresh identity and remains queued for upload.
                restoredID = UUID()
                for transfer in retainedUploadTransfers where transfer.assetID == snapshot.id {
                    transfer.assetID = restoredID
                    transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
                    transfer.transferredByteCount = 0
                    transfer.lastErrorCode = nil
                    transfer.nextRetryAt = nil
                    transfer.remoteRecordName = nil
                    transfer.updatedAt = .now
                }
                context.insert(SecurityIncidentRecord(
                    farmID: snapshot.farmID,
                    incidentType: "rebuildLocalAssetIdentityCollision",
                    recordName: authoritative.cloudRecordName,
                    detail: "云端与本机未上传照片使用同一 assetID 但摘要不同；本机照片已换用新 ID 保留。"
                ))
            }

            let restored = PhotoAssetRecord(
                id: restoredID,
                farmID: snapshot.farmID,
                sheepID: snapshot.sheepID,
                legacySourceKey: snapshot.legacySourceKey,
                originalEarTag: snapshot.originalEarTag,
                relativePath: snapshot.relativePath,
                sha256: snapshot.sha256,
                mimeType: snapshot.mimeType
            )
            Self.applyLocalPhotoSnapshot(snapshot, id: restoredID, to: restored)
            context.insert(restored)
        }
    }

    private static func localPhotoSnapshot(
        _ snapshot: LocalPhotoAssetSnapshot,
        exactlyMatches envelope: FarmAssetEnvelope,
        uploadTransfers: [CloudAssetTransfer]
    ) -> Bool {
        let byteCountMatches = uploadTransfers.isEmpty || uploadTransfers.contains { $0.byteCount == envelope.byteCount }
        return snapshot.farmID == envelope.farmID &&
            snapshot.id == envelope.assetID &&
            snapshot.sheepID == envelope.entityID &&
            snapshot.sourceSHA256 == envelope.sourceDigest &&
            snapshot.sha256 == envelope.payloadDigest &&
            snapshot.mimeType == envelope.mimeType &&
            snapshot.cloudPixelWidth == envelope.pixelWidth &&
            snapshot.cloudPixelHeight == envelope.pixelHeight &&
            CloudRebuildRootSnapshot.milliseconds(snapshot.capturedAt ?? .distantPast) ==
                CloudRebuildRootSnapshot.milliseconds(envelope.capturedAt ?? .distantPast) &&
            CloudRebuildRootSnapshot.milliseconds(snapshot.createdAt) ==
                CloudRebuildRootSnapshot.milliseconds(envelope.createdAt) &&
            byteCountMatches
    }

    private static func applyLocalPhotoSnapshot(
        _ snapshot: LocalPhotoAssetSnapshot,
        id: UUID,
        to asset: PhotoAssetRecord
    ) {
        asset.id = id
        asset.farmID = snapshot.farmID
        asset.sheepID = snapshot.sheepID
        asset.legacySourceKey = snapshot.legacySourceKey
        asset.originalEarTag = snapshot.originalEarTag
        asset.relativePath = snapshot.relativePath
        asset.sha256 = snapshot.sha256
        asset.mimeType = snapshot.mimeType
        asset.sourceSHA256 = snapshot.sourceSHA256
        asset.sourcePixelWidth = snapshot.sourcePixelWidth
        asset.sourcePixelHeight = snapshot.sourcePixelHeight
        asset.cloudPixelWidth = snapshot.cloudPixelWidth
        asset.cloudPixelHeight = snapshot.cloudPixelHeight
        asset.capturedAt = snapshot.capturedAt
        asset.cloudRecordName = snapshot.cloudRecordName
        asset.recoveryRecordName = snapshot.recoveryRecordName
        asset.isCloudAuthoritative = false
        asset.recoveryBackedUpAt = snapshot.recoveryBackedUpAt
        asset.createdAt = snapshot.createdAt
        asset.deletedAt = nil
    }

    private static func recoveredPendingEnvelope(_ operation: DomainOperation) -> CloudOperationEnvelope? {
        guard let entityID = operation.entityID else { return nil }
        return CloudOperationEnvelope(
            farmID: operation.farmID,
            entityID: entityID,
            entityType: operation.entityType,
            schemaVersion: operation.schemaVersion,
            revision: operation.resultingRevision,
            baseRevision: operation.baseRevision,
            operationID: operation.id,
            modifiedAt: operation.occurredAt,
            modifiedByAccountID: operation.accountID,
            modifiedByDeviceID: operation.modifiedByDeviceID ?? StableCloudUUID.derived(
                namespace: operation.id,
                name: "missing-pending-device"
            ),
            payload: operation.payload,
            payloadDigest: operation.payloadDigest,
            capabilityCertificate: operation.capabilityCertificate,
            operationSignature: operation.operationSignature ?? Data(),
            deletedAt: nil
        )
    }

    private static func pendingOperation(
        _ operation: DomainOperation,
        exactlyMatches authoritative: CloudOperationEnvelope
    ) -> Bool {
        operation.id == authoritative.operationID &&
            operation.farmID == authoritative.farmID &&
            operation.accountID == authoritative.modifiedByAccountID &&
            operation.entityID == authoritative.entityID &&
            operation.entityType == authoritative.entityType &&
            operation.schemaVersion == authoritative.schemaVersion &&
            operation.baseRevision == authoritative.baseRevision &&
            operation.resultingRevision == authoritative.revision &&
            operation.payload == authoritative.payload &&
            operation.payloadDigest == authoritative.payloadDigest &&
            CloudPayloadDigest.hex(for: operation.payload) == operation.payloadDigest &&
            operation.modifiedByDeviceID == authoritative.modifiedByDeviceID &&
            operation.capabilityCertificate == authoritative.capabilityCertificate &&
            operation.operationSignature == authoritative.operationSignature
    }

    private static func outboxItem(
        _ item: OutboxItem,
        exactlyMatches operation: DomainOperation
    ) -> Bool {
        item.operationID == operation.id &&
            item.farmID == operation.farmID &&
            item.accountID == operation.accountID &&
            item.entityType == operation.entityType &&
            item.entityID == operation.entityID &&
            item.baseRevision == operation.baseRevision &&
            item.payloadDigest == operation.payloadDigest
    }

    private static func isReplayableRecoveredOutbox(_ item: OutboxItem) -> Bool {
        switch item.status {
        case .pending, .uploading, .awaitingConfirmation, .retryableFailure:
            return true
        case .confirmed, .rejectedPermission, .blockedConflict, .notRequiredLocalOnly,
             .supersededRemoteAuthority:
            return false
        }
    }

    private static func blockRecoveredPendingOutbox(
        _ items: [OutboxItem],
        detail: String
    ) {
        for item in items {
            item.statusRawValue = OutboxStatus.blockedConflict.rawValue
            item.errorMessage = detail
            item.nextRetryAt = nil
            item.cloudRecordName = nil
        }
    }

    private static func removeResolvedRecoveredConflicts(
        for operation: DomainOperation,
        context: ModelContext
    ) throws {
        guard let entityID = operation.entityID else { return }
        for conflict in try context.fetch(FetchDescriptor<SyncConflictRecord>()) where
            conflict.farmID == operation.farmID &&
            conflict.entityID == entityID &&
            conflict.entityType == operation.entityType &&
            conflict.localPayloadDigest == operation.payloadDigest &&
            (conflict.statusRawValue == SyncConflictStatus.unresolved.rawValue ||
                conflict.statusRawValue == SyncConflictStatus.quarantined.rawValue) {
            context.delete(conflict)
        }
    }

    private static func insertRecoveredPendingConflict(
        operation: DomainOperation,
        remote: CloudOperationEnvelope?,
        fallbackRemoteRevision: Int? = nil,
        reasonCode: String,
        status: SyncConflictStatus = .unresolved,
        context: ModelContext
    ) throws {
        guard let entityID = operation.entityID else { return }
        let conflict = SyncConflictRecord(
            farmID: operation.farmID,
            entityID: entityID,
            entityType: operation.entityType,
            localRevision: operation.resultingRevision,
            remoteRevision: remote?.revision ?? fallbackRemoteRevision ?? operation.baseRevision,
            localPayload: operation.payload,
            remotePayload: remote?.payload ?? Data(),
            remoteAccountID: remote?.modifiedByAccountID,
            remoteDeviceID: remote?.modifiedByDeviceID,
            reasonCode: reasonCode,
            status: status
        )
        if let remote {
            conflict.remoteEnvelopeData = try JSONEncoder.cloud.encode(remote)
        }
        context.insert(conflict)
    }

    func pendingRecordIDs(
        maxOutboxItems: Int = 25,
        farmID restrictedFarmID: UUID? = nil
    ) throws -> [(CKRecord.ID, CloudDatabaseScope)] {
        let context = ModelContext(container)
        let pending = OutboxStatus.pending.rawValue
        let uploading = OutboxStatus.uploading.rawValue
        let awaiting = OutboxStatus.awaitingConfirmation.rawValue
        let iCloudProvider = FarmRemoteProvider.iCloud.rawValue
        var primaryDescriptor: FetchDescriptor<OutboxItem>
        if let restrictedFarmID {
            primaryDescriptor = FetchDescriptor<OutboxItem>(
                predicate: #Predicate {
                    $0.farmID == restrictedFarmID &&
                        ($0.statusRawValue == pending || $0.statusRawValue == uploading || $0.statusRawValue == awaiting)
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        } else {
            primaryDescriptor = FetchDescriptor<OutboxItem>(
                predicate: #Predicate {
                    $0.statusRawValue == pending || $0.statusRawValue == uploading || $0.statusRawValue == awaiting
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        }
        var outbox = Array(try context.fetch(primaryDescriptor).lazy.filter {
            $0.deliveryProviderRawValue == nil || $0.deliveryProviderRawValue == iCloudProvider
        }.prefix(max(1, maxOutboxItems)))
        if outbox.count < maxOutboxItems {
            let retryable = OutboxStatus.retryableFailure.rawValue
            let retryDescriptor: FetchDescriptor<OutboxItem>
            if let restrictedFarmID {
                retryDescriptor = FetchDescriptor<OutboxItem>(
                    predicate: #Predicate {
                        $0.farmID == restrictedFarmID &&
                            $0.statusRawValue == retryable
                    },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
            } else {
                retryDescriptor = FetchDescriptor<OutboxItem>(
                    predicate: #Predicate { $0.statusRawValue == retryable },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
            }
            // Eligibility must be evaluated before applying the batch limit.
            // Otherwise an older rate-limited prefix can hide later rows whose
            // retry time has already arrived and make the migration tail look
            // empty even though immediately schedulable work exists.
            let eligibleRetryable = try context.fetch(retryDescriptor).filter {
                ($0.deliveryProviderRawValue == nil || $0.deliveryProviderRawValue == iCloudProvider) &&
                    ($0.nextRetryAt == nil || $0.nextRetryAt! <= .now)
            }
            outbox.append(contentsOf: eligibleRetryable.prefix(maxOutboxItems - outbox.count))
        }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let operationIDs = Set(outbox.map(\.operationID))
        var operations: [DomainOperation] = []
        operations.reserveCapacity(operationIDs.count)
        for operationID in operationIDs {
            if let operation = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
                $0.id == operationID
            })).first {
                operations.append(operation)
            }
        }
        let operationByID = Dictionary(uniqueKeysWithValues: operations.map { ($0.id, $0) })
        let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>())
        var bindingValues: [UUID: (zoneName: String, ownerName: String, scope: CloudDatabaseScope)] = [:]
        for binding in bindings where binding.state == .active {
            bindingValues[binding.farmID] = (binding.zoneName, binding.zoneOwnerName, binding.databaseScope)
        }
        var result: [(CKRecord.ID, CloudDatabaseScope)] = []
        var seen = Set<String>()
        for item in outbox {
            guard let binding = bindingValues[item.farmID] else { continue }
            let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.ownerName)
            let operation = operationByID[item.operationID]
            let requiredNames: Set<String>
            if let operation {
                requiredNames = requiredReceiptNames(for: operation, in: operations)
            } else {
                requiredNames = [mapper.recordName(for: item.operationID)]
            }
            let confirmedNames = Set(receipts.lazy.filter {
                $0.farmID == item.farmID &&
                    $0.operationID == item.operationID &&
                    $0.databaseScopeRawValue == binding.scope.rawValue &&
                    $0.zoneName == binding.zoneName &&
                    $0.zoneOwnerName == binding.ownerName
            }.map(\.recordName))
            let recordNames = requiredNames.subtracting(confirmedNames).sorted()
            for recordName in recordNames {
                let key = "\(binding.scope.rawValue)|\(zoneID.zoneName)|\(recordName)"
                if seen.insert(key).inserted {
                    result.append((CKRecord.ID(recordName: recordName, zoneID: zoneID), binding.scope))
                }
            }
        }
        return result
    }

    func refreshedBootstrapEntityRecordNames(farmID: UUID) throws -> Set<String> {
        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let operations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        var operationByID: [UUID: DomainOperation] = [:]
        var duplicateOperationIDs = Set<UUID>()
        for operation in operations {
            if operationByID.updateValue(operation, forKey: operation.id) != nil {
                duplicateOperationIDs.insert(operation.id)
            }
        }

        let refreshedEntityIDs = Set(operations.compactMap { operation -> UUID? in
            guard !duplicateOperationIDs.contains(operation.id),
                  Self.isRefreshedBootstrap(operation) else { return nil }
            return operation.entityID
        })
        let protectedEntityIDs = Set(outbox.compactMap { item -> UUID? in
            guard !item.status.isTerminalDelivery else { return nil }
            guard !duplicateOperationIDs.contains(item.operationID),
                  let operation = operationByID[item.operationID] else {
                // An unconfirmed projection whose operation is missing or
                // ambiguous is not safe to classify as obsolete.
                return item.entityID
            }
            guard !Self.isRefreshedBootstrap(operation) else { return nil }
            return operation.entityID
        })
        return Set(refreshedEntityIDs.subtracting(protectedEntityIDs).map(mapper.entityRecordName(for:)))
    }

    /// Returns only mutable entity projections that can be proven to belong to
    /// a local tombstone operation in the same farm. The CloudSync actor adds
    /// the active zone proof before removing serialized CKSyncEngine changes.
    func legacyTombstoneEntityRecordNames(farmID: UUID) throws -> Set<String> {
        let context = ModelContext(container)
        let iCloud = FarmRemoteProvider.iCloud.rawValue
        let items = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID
        })).filter {
            $0.deliveryProviderRawValue == nil || $0.deliveryProviderRawValue == iCloud
        }
        let operationIDs = Set(items.map(\.operationID))
        let operations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID
        })).filter {
            operationIDs.contains($0.id) &&
                $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue
        }
        var operationIdentityByID: [UUID: (entityID: UUID, entityType: String, payloadDigest: String)] = [:]
        var duplicateOperationIDs = Set<UUID>()
        for operation in operations {
            guard let entityID = operation.entityID else { continue }
            if operationIdentityByID.updateValue(
                (entityID, operation.entityType, operation.payloadDigest),
                forKey: operation.id
            ) != nil {
                duplicateOperationIDs.insert(operation.id)
            }
        }
        var recordNames = Set<String>()
        for item in items {
            guard !duplicateOperationIDs.contains(item.operationID),
                  let identity = operationIdentityByID[item.operationID],
                  item.entityID == identity.entityID,
                  item.entityType == identity.entityType,
                  item.payloadDigest == identity.payloadDigest else {
                continue
            }
            recordNames.insert(mapper.entityRecordName(for: identity.entityID))
        }
        return recordNames
    }

    /// Initial migration projections have no server record yet and must not
    /// pay for a lookup per entity. Updates, however, need the existing
    /// CKRecord system fields so CloudKit treats the save as an optimistic
    /// modification instead of another insert.
    func entityRecordRequiresServerFetch(
        _ recordID: CKRecord.ID,
        scope: CloudDatabaseScope
    ) throws -> Bool {
        guard let entityID = mapper.entityID(from: recordID) else { return false }
        let context = ModelContext(container)
        guard let binding = try activeBinding(matching: recordID.zoneID, scope: scope, context: context) else {
            return false
        }
        let farmID = binding.farmID
        let confirmed = OutboxStatus.confirmed.rawValue
        let candidates = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.entityID == entityID && $0.statusRawValue != confirmed
        })).filter { !$0.status.isTerminalDelivery }
        let candidateIDs = Set(candidates.map(\.operationID))
        let operation = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID && $0.entityID == entityID
        }))
            .filter { candidateIDs.contains($0.id) }
            .max(by: {
                if $0.resultingRevision != $1.resultingRevision { return $0.resultingRevision < $1.resultingRevision }
                return $0.createdAt < $1.createdAt
            })
        return (operation?.baseRevision ?? 0) > 0
    }

    private func activeBinding(
        matching zoneID: CKRecordZone.ID,
        scope: CloudDatabaseScope,
        context: ModelContext
    ) throws -> CloudFarmBinding? {
        let zoneName = zoneID.zoneName
        let ownerName = zoneID.ownerName
        let scopeRawValue = scope.rawValue
        let active = CloudFarmBindingState.active.rawValue
        var descriptor = FetchDescriptor<CloudFarmBinding>(predicate: #Predicate {
            $0.zoneName == zoneName &&
                $0.zoneOwnerName == ownerName &&
                $0.databaseScopeRawValue == scopeRawValue &&
                $0.stateRawValue == active
        })
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func bindingSnapshot(farmID: UUID) throws -> CloudFarmBindingSnapshot? {
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        guard let binding = bindings.first(where: { $0.farmID == farmID }) else { return nil }
        return CloudFarmBindingSnapshot(
            farmID: binding.farmID,
            ownerAccountID: binding.ownerAccountID,
            zoneName: binding.zoneName,
            zoneOwnerName: binding.zoneOwnerName,
            databaseScope: binding.databaseScope,
            shareRecordName: binding.shareRecordName,
            state: binding.state,
            lastErrorCode: binding.lastErrorCode
        )
    }

    func uniqueActiveBindingSnapshot(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) throws -> CloudFarmBindingSnapshot? {
        let context = ModelContext(container)
        let active = CloudFarmBindingState.active.rawValue
        let scopeRawValue = scope.rawValue
        var descriptor = FetchDescriptor<CloudFarmBinding>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.stateRawValue == active &&
                $0.databaseScopeRawValue == scopeRawValue
        })
        descriptor.fetchLimit = 2
        let bindings = try context.fetch(descriptor)
        guard bindings.count == 1, let binding = bindings.first else { return nil }
        return CloudFarmBindingSnapshot(
            farmID: binding.farmID,
            ownerAccountID: binding.ownerAccountID,
            zoneName: binding.zoneName,
            zoneOwnerName: binding.zoneOwnerName,
            databaseScope: binding.databaseScope,
            shareRecordName: binding.shareRecordName,
            state: binding.state,
            lastErrorCode: binding.lastErrorCode
        )
    }

    func isCloudPreparationReady(farmID: UUID) throws -> Bool {
        let context = ModelContext(container)
        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farmID }
        guard operations.allSatisfy({
            $0.schemaVersion >= 2 &&
            $0.entityID != nil &&
            !$0.payload.isEmpty &&
            CloudPayloadDigest.hex(for: $0.payload) == $0.payloadDigest
        }) else { return false }
        let targets = Set(operations.compactMap(\.entityID))
        var requiredTargets = Set<UUID>()
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<WeaningRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<BreedingProgramRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<FeedRecipeRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<SemenRecord>()).filter { $0.farmID == farmID }.map(\.id))
        requiredTargets.formUnion(try context.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == farmID }.map(\.id))
        return requiredTargets.isSubset(of: targets)
    }

    func migrationCloudBaseline(farmID: UUID) throws -> MigrationCloudBaselineSnapshot? {
        let context = ModelContext(container)
        guard let commit = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: {
            $0.farmID == farmID &&
                !$0.baselineDigest.isEmpty &&
                $0.baselineEntityCount > 0 &&
                $0.cloudStateRawValue != MigrationCloudState.localCommitted.rawValue
        }) else { return nil }
        var version = 1
        var cutoffAt: Date?
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for operation in try context.fetch(FetchDescriptor<DomainOperation>()).filter({ $0.farmID == farmID }) {
            guard let payload = try? decoder.decode(FarmCommandCloudPayload.self, from: operation.payload),
                  payload.kind == .bootstrapEntity else { continue }
            let candidateVersion = payload.integers["baselineVersion"] ?? 1
            guard candidateVersion >= version else { continue }
            let candidateCutoff = payload.dates["baselineCutoffAt"]
            if candidateVersion > version {
                version = candidateVersion
                cutoffAt = candidateCutoff
            } else if let candidateCutoff {
                cutoffAt = max(cutoffAt ?? candidateCutoff, candidateCutoff)
            }
        }
        if version < 2 || cutoffAt == nil {
            if let cached = recoveredBaselineCache[farmID],
               cached.digest == commit.baselineDigest,
               cached.entityCount == commit.baselineEntityCount,
               cached.photoCount == commit.baselinePhotoCount {
                return cached
            }
            if let (_, bundle) = try RecoveredBaselineReuploadRepairService.completedRecoveryBundle(
                commit: commit,
                context: context
            ), let bootstrap = bundle.bootstrap,
               bootstrap.digest == commit.baselineDigest,
               bootstrap.entityCount == commit.baselineEntityCount,
               bootstrap.photoCount == commit.baselinePhotoCount,
               bootstrap.normalizedVersion >= 2,
               let recoveredCutoff = bootstrap.cutoffAt {
                let recovered = MigrationCloudBaselineSnapshot(
                    digest: commit.baselineDigest,
                    entityCount: commit.baselineEntityCount,
                    photoCount: commit.baselinePhotoCount,
                    version: bootstrap.normalizedVersion,
                    cutoffAt: recoveredCutoff
                )
                recoveredBaselineCache[farmID] = recovered
                return recovered
            }
        }
        return MigrationCloudBaselineSnapshot(
            digest: commit.baselineDigest,
            entityCount: commit.baselineEntityCount,
            photoCount: commit.baselinePhotoCount,
            version: version,
            cutoffAt: cutoffAt
        )
    }

    /// Restores only evidence that can be derived exactly from the immutable
    /// baseline operation. A confirmed row without a matching receipt is
    /// safely requeued so CloudKit can prove the immutable record again.
    @discardableResult
    func repairMigrationCloudReadyEvidence(farmID: UUID) throws -> Int {
        _ = try backfillLegacyReceiptZoneIdentity(farmID: farmID)
        let context = ModelContext(container)
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).filter {
            $0.farmID == farmID &&
                !$0.baselineDigest.isEmpty &&
                $0.baselineEntityCount > 0 &&
                $0.cloudStateRawValue != MigrationCloudState.localCommitted.rawValue
        }
        guard commits.count == 1, let commit = commits.first else {
            throw MigrationCloudReadyEvidenceError.baselineMissing
        }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>()).filter {
            $0.farmID == farmID &&
                $0.ownerAccountID == commit.ownerAccountID &&
                $0.state == .active &&
                $0.databaseScope == .privateDatabase
        }
        guard bindings.count == 1, let binding = bindings.first else {
            throw MigrationCloudReadyEvidenceError.bindingMismatch
        }
        let required = try MigrationBaselineV2EvidenceContract.requiredOperations(
            commit: commit,
            farmID: farmID,
            context: context
        )
        let repaired = try MigrationBaselineV2EvidenceContract.repairOutboxes(
            required: required,
            commit: commit,
            databaseScope: binding.databaseScope,
            zoneName: binding.zoneName,
            zoneOwnerName: binding.zoneOwnerName,
            context: context
        )
        if repaired > 0 { try context.save() }
        return repaired
    }

    /// A CloudKit root may become ready only when every operation selected by
    /// the current v2 baseline has an exact confirmed Outbox row and a matching
    /// durable receipt in the active private database. Photos use the same
    /// fail-closed rule against their immutable payload digest.
    func verifiedMigrationCloudBaselineForReady(farmID: UUID) throws -> MigrationCloudBaselineSnapshot? {
        _ = try backfillLegacyReceiptZoneIdentity(farmID: farmID)
        let context = ModelContext(container)
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).filter {
            $0.farmID == farmID &&
                !$0.baselineDigest.isEmpty &&
                $0.baselineEntityCount > 0 &&
                $0.cloudStateRawValue != MigrationCloudState.localCommitted.rawValue
        }
        guard commits.count == 1, let commit = commits.first else { return nil }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>()).filter {
            $0.farmID == farmID &&
                $0.ownerAccountID == commit.ownerAccountID &&
                $0.state == .active &&
                $0.databaseScope == .privateDatabase
        }
        guard bindings.count == 1, let binding = bindings.first else {
            throw MigrationCloudReadyEvidenceError.bindingMismatch
        }
        let required = try MigrationBaselineV2EvidenceContract.requiredOperations(
            commit: commit,
            farmID: farmID,
            context: context
        )
        let outboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == farmID }
        let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>()).filter { $0.farmID == farmID }
        let outboxesByOperationID = Dictionary(grouping: outboxes, by: \.operationID)
        let receiptsByOperationID = Dictionary(grouping: receipts, by: \.operationID)
        for operation in required.operations {
            let matching = outboxesByOperationID[operation.id] ?? []
            let expectedRecordName = mapper.recordName(for: operation.id)
            guard matching.count == 1,
                  let item = matching.first,
                  item.accountID == operation.accountID,
                  item.entityType == operation.entityType,
                  item.entityID == operation.entityID,
                  item.baseRevision == operation.baseRevision,
                  item.payloadDigest == operation.payloadDigest,
                  item.status == .confirmed,
                  item.cloudRecordName == expectedRecordName else {
                throw MigrationCloudReadyEvidenceError.outboxMismatch
            }
            guard (receiptsByOperationID[operation.id] ?? []).contains(where: {
                $0.operationID == operation.id &&
                    $0.databaseScopeRawValue == binding.databaseScopeRawValue &&
                    $0.recordName == expectedRecordName &&
                    $0.zoneName == binding.zoneName &&
                    $0.zoneOwnerName == binding.zoneOwnerName
            }) else {
                throw MigrationCloudReadyEvidenceError.receiptMissing
            }
        }

        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        guard photos.count == commit.baselinePhotoCount else {
            throw MigrationCloudReadyEvidenceError.photoMismatch
        }
        let uploads = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).filter {
            $0.farmID == farmID && $0.direction == .upload
        }
        for photo in photos {
            guard !photo.sha256.isEmpty,
                  uploads.contains(where: {
                      $0.assetID == photo.id &&
                          $0.payloadDigest == photo.sha256 &&
                          $0.status == .completed
                  }) else {
                throw MigrationCloudReadyEvidenceError.photoMismatch
            }
        }

        return MigrationCloudBaselineSnapshot(
            digest: commit.baselineDigest,
            entityCount: commit.baselineEntityCount,
            photoCount: commit.baselinePhotoCount,
            version: required.version,
            cutoffAt: required.cutoffAt
        )
    }

    /// 云端准入必须在服务层执行：Development 只接收已完成本地对账
    /// 并生成完整云端基线的正式迁移牧场。
    func requireCloudAdmission(farmID: UUID, environment: AppEnvironment) throws {
        let context = ModelContext(container)
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        guard let farm = farms.first(where: { $0.id == farmID }) else {
            throw CloudSyncError.inactiveFarm
        }
        let migrationCommit = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: {
            $0.farmID == farmID &&
            $0.status == .completed &&
            !$0.baselineDigest.isEmpty &&
            $0.baselineEntityCount > 0 &&
            $0.cloudState != .failed
        })
        let request = CloudAdmissionRequest(
            environment: environment,
            role: farm.role,
            membershipIsActive: farm.membershipStatusRawValue == "active",
            isDeleted: farm.deletedAt != nil,
            isLocalOnlyMigration: farm.isLocalOnlyMigration,
            hasVerifiedMigrationCommit: migrationCommit != nil,
            hasCompleteMigrationBaseline: migrationCommit?.cloudState != .localCommitted
        )
        do {
            try CloudAdmissionPolicy.validate(request)
        } catch let denial as CloudAdmissionDenial {
            switch denial {
            case .verifiedMigrationRequired:
                throw CloudSyncError.verifiedMigrationRequired
            case .localOnlyMigration:
                throw CloudSyncError.localOnlyMigration
            case .ownerRequired:
                throw CloudSyncError.ownerRequired
            case .deletedFarm, .inactiveMembership:
                throw CloudSyncError.inactiveFarm
            }
        }
    }

    func stageAcceptedSharedFarm(farmID: UUID, temporaryOwnerAccountID: UUID) throws {
        let context = ModelContext(container)
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        guard !farms.contains(where: { $0.id == farmID }) else { return }
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: temporaryOwnerAccountID,
            name: SharedFarmAdmissionPolicy.pendingFarmName,
            role: .worker
        )
        farm.membershipStatusRawValue = FarmMembershipStatus.pendingOwnerConfirmation.rawValue
        context.insert(farm)
        try context.save()
    }

    func sharedFarmBootstrapIsComplete(
        farmID: UUID,
        accountID: UUID
    ) throws -> Bool {
        let context = ModelContext(container)
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: {
            $0.farmID == farmID
        }),
              let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: {
                  $0.id == farmID && $0.deletedAt == nil
              }),
              let membership = try context.fetch(FetchDescriptor<FarmMembershipBinding>()).first(where: {
                  $0.farmID == farmID && $0.accountID == accountID
              }) else {
            return false
        }
        return SharedFarmAdmissionPolicy.isReadyForDisplay(
            bindingScope: binding.databaseScope,
            bindingState: binding.state,
            farmName: farm.name,
            membershipStatus: membership.status
        )
    }

    func stageDiscoveredOwnerFarm(farmID: UUID, ownerAccountID: UUID, shareRecordName: String?) throws {
        let context = ModelContext(container)
        var farms = try context.fetch(FetchDescriptor<FarmRecord>())
        if !farms.contains(where: { $0.id == farmID }) {
            let farm = FarmRecord(id: farmID, ownerAccountID: ownerAccountID, name: "正在从 iCloud 恢复的牧场", role: .owner)
            farm.membershipStatusRawValue = FarmMembershipStatus.active.rawValue
            context.insert(farm)
            farms.append(farm)
        }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let binding: CloudFarmBinding
        if let existing = bindings.first(where: { $0.farmID == farmID }) {
            binding = existing
        } else {
            binding = CloudFarmBinding(
                farmID: farmID,
                ownerAccountID: ownerAccountID,
                databaseScope: .privateDatabase,
                state: .active
            )
            context.insert(binding)
        }
        binding.shareRecordName = shareRecordName
        binding.updatedAt = .now
        try context.save()
    }

    func record(
        for recordID: CKRecord.ID,
        scope: CloudDatabaseScope,
        device: DeviceIdentityActor,
        existingEntityRecord: CKRecord? = nil
    ) async -> CKRecord? {
        do {
            let context = ModelContext(container)
            guard let binding = try activeBinding(
                matching: recordID.zoneID,
                scope: scope,
                context: context
            ) else { return nil }
            let farmID = binding.farmID
            let operationID: UUID?
            if let direct = mapper.operationID(from: recordID) {
                operationID = direct
            } else if let entityID = mapper.entityID(from: recordID) {
                let confirmed = OutboxStatus.confirmed.rawValue
                let candidates = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
                    $0.farmID == farmID && $0.entityID == entityID && $0.statusRawValue != confirmed
                })).filter { !$0.status.isTerminalDelivery }
                let candidateIDs = Set(candidates.map(\.operationID))
                operationID = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
                    $0.farmID == farmID && $0.entityID == entityID
                }))
                    .filter { candidateIDs.contains($0.id) }
                    .max(by: {
                        if $0.resultingRevision != $1.resultingRevision { return $0.resultingRevision < $1.resultingRevision }
                        return $0.createdAt < $1.createdAt
                    })?.id
            } else if let entityID = mapper.tombstoneEntityID(from: recordID) {
                let tombstoneKind = DomainOperationKind.tombstoneEntity.rawValue
                operationID = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
                    $0.farmID == farmID && $0.entityID == entityID && $0.kindRawValue == tombstoneKind
                }))
                    .max(by: { $0.createdAt < $1.createdAt })?.id
            } else {
                operationID = nil
            }
            guard let operationID else { return nil }
            guard let operation = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
                      $0.id == operationID && $0.farmID == farmID
                  })).first,
                  let item = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
                      $0.operationID == operationID && $0.farmID == farmID
                  })).first,
                  let entityID = operation.entityID else { return nil }
            // Baseline v2 refreshes are an immutable operation stream. Older
            // builds may have left mutable entity projections serialized in
            // CKSyncEngine. Never reconstruct those stale projections, even if
            // automatic syncing races the explicit state cleanup at launch.
            if mapper.entityID(from: recordID) != nil,
               Self.isRefreshedBootstrap(operation) {
                return nil
            }
            var existingEntityRecordIsVerifiedAncestor = false
            if mapper.entityID(from: recordID) != nil, let existingEntityRecord {
                existingEntityRecordIsVerifiedAncestor = try projectionIsVerifiedAncestor(
                    existingEntityRecord,
                    of: operation,
                    scope: scope,
                    context: context
                )
            }
            let currentOperationID = operation.id
            let tombstone = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
                $0.operationID == currentOperationID
            })).first

            // A Tombstone and its immutable Operation are one signed deletion
            // fact. Once the first sibling record has assigned an authorization
            // tuple, every retry must reuse it byte-for-byte. Re-signing each
            // requested record can otherwise leave CloudKit with an Operation
            // and Tombstone that point at the same ID but cannot prove each
            // other.
            if operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
               operation.modifiedByDeviceID != nil,
               operation.operationSignature != nil,
               !operation.capabilityCertificate.isEmpty,
               let tombstone {
                do {
                    let envelope = try validatedStoredTombstoneRetryEnvelope(
                        operation: operation,
                        tombstone: tombstone,
                        item: item,
                        context: context
                    )
                    item.statusRawValue = OutboxStatus.uploading.rawValue
                    item.errorMessage = nil
                    item.lastAttemptAt = .now
                    item.attemptCount += 1
                    try context.save()
                    if mapper.operationID(from: recordID) == operation.id {
                        return mapper.operationRecord(from: envelope, zoneID: recordID.zoneID)
                    }
                    if mapper.tombstoneEntityID(from: recordID) == entityID {
                        let value = FarmTombstoneEnvelope(
                            tombstoneID: tombstone.id,
                            farmID: tombstone.farmID,
                            entityType: tombstone.entityType,
                            entityID: tombstone.entityID,
                            revision: tombstone.revision,
                            deletedAt: tombstone.deletedAt,
                            deletedByAccountID: tombstone.deletedByAccountID,
                            reason: tombstone.reason,
                            operationID: operation.id,
                            restoresTombstoneID: nil
                        )
                        return mapper.tombstoneRecord(
                            envelope: value,
                            certificate: envelope.capabilityCertificate,
                            signature: envelope.operationSignature,
                            zoneID: recordID.zoneID
                        )
                    }
                    // Deletions no longer deliver a mutable Entity projection.
                    return nil
                } catch {
                    item.statusRawValue = OutboxStatus.blockedConflict.rawValue
                    item.errorMessage = "Tombstone 原始签名授权无法安全复用：\(error.localizedDescription)"
                    item.nextRetryAt = nil
                    try context.save()
                    return nil
                }
            }
            let identity = try await device.identity()
            let certificates = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
            guard let certificate = certificates
                .filter({
                    $0.farmID == operation.farmID &&
                    $0.accountID == operation.accountID &&
                    $0.deviceID == identity.deviceID &&
                    $0.isUsable
                })
                .max(by: { $0.expiresAt < $1.expiresAt }) else {
                item.statusRawValue = OutboxStatus.rejectedPermission.rawValue
                item.errorMessage = "没有当前牧场可用的能力证书。"
                try context.save()
                return nil
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
                capabilityCertificate: certificate.certificateJWS,
                operationSignature: Data(),
                deletedAt: tombstone?.deletedAt
            )
            let signature = try await device.sign(envelope.canonicalSigningData)
            let bindingValidationContext = ModelContext(container)
            guard let currentBinding = try activeBinding(
                matching: recordID.zoneID,
                scope: scope,
                context: bindingValidationContext
            ), currentBinding.farmID == operation.farmID else {
                return nil
            }
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
            operation.capabilityCertificate = certificate.certificateJWS
            operation.operationSignature = signature
            item.operationSignature = signature
            item.capabilityCertificate = certificate.certificateJWS
            item.statusRawValue = OutboxStatus.uploading.rawValue
            item.lastAttemptAt = .now
            item.attemptCount += 1
            try context.save()
            if mapper.entityID(from: recordID) != nil {
                return mapper.entityRecord(
                    from: envelope,
                    zoneID: recordID.zoneID,
                    existingRecord: existingEntityRecord,
                    existingRecordIsVerifiedAncestor: existingEntityRecordIsVerifiedAncestor
                )
            }
            if recordID.recordName.hasPrefix("tombstone_"), let tombstone, let operationID = tombstone.operationID {
                let value = FarmTombstoneEnvelope(
                    tombstoneID: tombstone.id,
                    farmID: tombstone.farmID,
                    entityType: tombstone.entityType,
                    entityID: tombstone.entityID,
                    revision: tombstone.revision,
                    deletedAt: tombstone.deletedAt,
                    deletedByAccountID: tombstone.deletedByAccountID,
                    reason: tombstone.reason,
                    operationID: operationID,
                    restoresTombstoneID: nil
                )
                return mapper.tombstoneRecord(envelope: value, certificate: certificate.certificateJWS, signature: signature, zoneID: recordID.zoneID)
            }
            return mapper.operationRecord(from: envelope, zoneID: recordID.zoneID)
        } catch {
            return nil
        }
    }

    private func hasConfirmedTombstoneReceipt(
        farmID: UUID,
        operationID: UUID,
        entityID: UUID,
        scope: CloudDatabaseScope,
        zoneID: CKRecordZone.ID,
        context: ModelContext
    ) throws -> Bool {
        let recordName = mapper.tombstoneRecordName(for: entityID)
        let scopeRawValue = scope.rawValue
        let zoneName = zoneID.zoneName
        let zoneOwnerName = zoneID.ownerName
        var descriptor = FetchDescriptor<CloudOperationReceipt>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.operationID == operationID &&
                $0.recordName == recordName &&
                $0.databaseScopeRawValue == scopeRawValue &&
                $0.zoneName == zoneName &&
                $0.zoneOwnerName == zoneOwnerName
        })
        descriptor.fetchLimit = 2
        return try context.fetch(descriptor).count == 1
    }

    private func validatedStoredTombstoneRetryEnvelope(
        operation: DomainOperation,
        tombstone: TombstoneRecord,
        item: OutboxItem,
        context: ModelContext
    ) throws -> CloudOperationEnvelope {
        guard let publicKey = capabilitySigningPublicKeyPEM, !publicKey.isEmpty,
              operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
              let entityID = operation.entityID,
              let deviceID = operation.modifiedByDeviceID,
              let signature = operation.operationSignature,
              !operation.capabilityCertificate.isEmpty,
              item.operationID == operation.id,
              item.farmID == operation.farmID,
              item.entityID == entityID,
              item.payloadDigest == operation.payloadDigest,
              item.operationSignature == signature,
              item.capabilityCertificate == operation.capabilityCertificate,
              tombstone.operationID == operation.id,
              tombstone.farmID == operation.farmID,
              tombstone.entityID == entityID,
              tombstone.entityType == operation.entityType,
              tombstone.revision == operation.resultingRevision,
              tombstone.deletedByAccountID == operation.accountID else {
            throw CloudContractError.malformedRecord
        }
        let envelope = CloudOperationEnvelope(
            farmID: operation.farmID,
            entityID: entityID,
            entityType: operation.entityType,
            schemaVersion: operation.schemaVersion,
            revision: operation.resultingRevision,
            baseRevision: operation.baseRevision,
            operationID: operation.id,
            modifiedAt: operation.occurredAt,
            modifiedByAccountID: operation.accountID,
            modifiedByDeviceID: deviceID,
            payload: operation.payload,
            payloadDigest: operation.payloadDigest,
            capabilityCertificate: operation.capabilityCertificate,
            operationSignature: signature,
            deletedAt: tombstone.deletedAt
        )
        let claims = try CapabilityCertificateVerifier.verify(
            envelope.capabilityCertificate,
            publicKeyPEM: publicKey
        )
        guard claims.isCurrentlyValid else { throw CloudContractError.expiredCertificate }
        let revoked = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        guard !revoked.contains(where: {
            $0.farmID == envelope.farmID && $0.serverCertificateID == claims.certificateID
        }) else {
            throw CloudContractError.invalidCertificate
        }
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        guard let device = devices.first(where: {
            $0.id == claims.deviceID && $0.accountID == claims.accountID
        }) else {
            throw CloudContractError.invalidDeviceSignature
        }
        try CloudOperationSecurity.validate(
            envelope: envelope,
            claims: claims,
            devicePublicKeyX963: device.publicKeyX963,
            authorizationDate: .now
        )
        return envelope
    }

    private func projectionIsVerifiedAncestor(
        _ server: CKRecord,
        of candidate: DomainOperation,
        scope: CloudDatabaseScope,
        context: ModelContext
    ) throws -> Bool {
        guard let entityID = candidate.entityID else { return false }
        let farmID = candidate.farmID
        let history = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID && $0.entityID == entityID
        }))
        var confirmedOperationRecordNames = Set<String>()
        let scopeRawValue = scope.rawValue
        let zoneName = server.recordID.zoneID.zoneName
        let zoneOwnerName = server.recordID.zoneID.ownerName
        for operation in history {
            let operationID = operation.id
            let recordName = mapper.recordName(for: operationID)
            var descriptor = FetchDescriptor<CloudOperationReceipt>(predicate: #Predicate {
                $0.farmID == farmID &&
                    $0.operationID == operationID &&
                    $0.recordName == recordName &&
                    $0.databaseScopeRawValue == scopeRawValue &&
                    $0.zoneName == zoneName &&
                    $0.zoneOwnerName == zoneOwnerName
            })
            descriptor.fetchLimit = 1
            if try !context.fetch(descriptor).isEmpty {
                confirmedOperationRecordNames.insert(recordName)
            }
        }
        return CloudEntityProjectionLineage.isVerifiedAncestor(
            server: server,
            candidate: candidate,
            history: history,
            confirmedOperationRecordNames: confirmedOperationRecordNames,
            mapper: mapper
        )
    }

    func confirmSavedRecords(_ records: [CKRecord], scope: CloudDatabaseScope) throws {
        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        var receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>())
        var affectedOperations: [(farmID: UUID, operationID: UUID, zoneName: String, zoneOwnerName: String)] = []
        for record in records {
            guard let target = try validatedSentRecordTarget(
                record,
                scope: scope,
                outbox: outbox,
                operations: operations,
                context: context
            ) else { continue }
            let operationID = target.operation.id
            let item = target.item
            if !affectedOperations.contains(where: {
                $0.farmID == item.farmID && $0.operationID == operationID
            }) {
                affectedOperations.append((
                    item.farmID,
                    operationID,
                    record.recordID.zoneID.zoneName,
                    record.recordID.zoneID.ownerName
                ))
            }
            if !receipts.contains(where: {
                $0.farmID == item.farmID &&
                    $0.operationID == operationID &&
                    $0.recordName == record.recordID.recordName &&
                    $0.databaseScopeRawValue == scope.rawValue &&
                    $0.zoneName == record.recordID.zoneID.zoneName &&
                    $0.zoneOwnerName == record.recordID.zoneID.ownerName
            }) {
                let receipt = CloudOperationReceipt(
                    farmID: item.farmID,
                    operationID: operationID,
                    recordName: record.recordID.recordName,
                    serverChangeTag: record.recordChangeTag,
                    databaseScope: scope,
                    zoneName: record.recordID.zoneID.zoneName,
                    zoneOwnerName: record.recordID.zoneID.ownerName
                )
                context.insert(receipt)
                receipts.append(receipt)
            }
        }
        for affected in affectedOperations {
            let farmID = affected.farmID
            let operationID = affected.operationID
            guard let item = outbox.first(where: {
                $0.farmID == farmID && $0.operationID == operationID
            }), let operation = operations.first(where: {
                $0.farmID == farmID && $0.id == operationID
            }) else { continue }
            let scopeRawValue = scope.rawValue
            let zoneName = affected.zoneName
            let zoneOwnerName = affected.zoneOwnerName
            let requiredNames = requiredReceiptNames(for: operation, in: operations)
            let confirmedNames = Set(receipts.filter {
                    $0.farmID == farmID &&
                    $0.operationID == operationID &&
                    $0.databaseScopeRawValue == scopeRawValue &&
                    $0.zoneName == zoneName &&
                    $0.zoneOwnerName == zoneOwnerName
            }.map(\.recordName))
            if requiredNames.isSubset(of: confirmedNames) {
                item.statusRawValue = OutboxStatus.confirmed.rawValue
                item.errorMessage = nil
                item.cloudRecordName = mapper.recordName(for: operationID)
            } else {
                item.statusRawValue = OutboxStatus.awaitingConfirmation.rawValue
            }
        }
        try context.save()
    }

    private func requiredReceiptNames(
        for operation: DomainOperation,
        in operations: [DomainOperation]
    ) -> Set<String> {
        CloudDeliveryReceiptContract.requiredRecordNames(
            for: operation,
            latestOperationForEntity: latestOperation(for: operation, in: operations),
            mapper: mapper
        )
    }

    private func latestOperation(
        for operation: DomainOperation,
        in operations: [DomainOperation]
    ) -> DomainOperation? {
        guard let entityID = operation.entityID else { return nil }
        return operations
            .filter { $0.farmID == operation.farmID && $0.entityID == entityID }
            .max(by: {
                if $0.resultingRevision != $1.resultingRevision {
                    return $0.resultingRevision < $1.resultingRevision
                }
                return $0.createdAt < $1.createdAt
            })
    }

    private func validatedSentRecordTarget(
        _ record: CKRecord,
        scope: CloudDatabaseScope,
        outbox: [OutboxItem],
        operations: [DomainOperation],
        context: ModelContext
    ) throws -> (item: OutboxItem, operation: DomainOperation)? {
        guard let binding = try activeBinding(
            matching: record.recordID.zoneID,
            scope: scope,
            context: context
        ) else { return nil }
        let operationID = mapper.operationID(from: record.recordID) ??
            ((record[CloudRecordField.operationID] as? String).flatMap(UUID.init(uuidString:)))
        guard let operationID else { return nil }
        let matchingItems = outbox.filter {
            $0.operationID == operationID && $0.farmID == binding.farmID
        }
        let matchingOperations = operations.filter {
            $0.id == operationID && $0.farmID == binding.farmID
        }
        guard matchingItems.count == 1,
              matchingOperations.count == 1,
              let item = matchingItems.first,
              let operation = matchingOperations.first else { return nil }
        let expectedRecordNames = CloudDeliveryReceiptContract.acceptedRecordNames(
            for: operation,
            latestOperationForEntity: latestOperation(for: operation, in: operations),
            mapper: mapper
        )
        guard expectedRecordNames.contains(record.recordID.recordName) else { return nil }
        return (item, operation)
    }

    /// Adds the current zone identity to receipts written by the immediately
    /// preceding schema, but only when the local store itself provides a full
    /// proof chain. Receipts older than the current binding identity timestamp,
    /// rebuild receipts without a server change tag, ambiguous operations, and
    /// incomplete outbox rows remain zone-less and must be confirmed again.
    @discardableResult
    func backfillLegacyReceiptZoneIdentity(farmID: UUID) throws -> Int {
        let context = ModelContext(container)
        let active = CloudFarmBindingState.active.rawValue
        var bindingDescriptor = FetchDescriptor<CloudFarmBinding>(predicate: #Predicate {
            $0.farmID == farmID && $0.stateRawValue == active
        })
        bindingDescriptor.fetchLimit = 2
        let bindings = try context.fetch(bindingDescriptor)
        guard bindings.count == 1,
              let binding = bindings.first,
              binding.databaseScope == .privateDatabase,
              binding.zoneName == CloudZoneName.forFarm(farmID),
              binding.zoneOwnerName == CKCurrentUserDefaultName else { return 0 }
        let farms = try context.fetch(FetchDescriptor<FarmRecord>()).filter {
            $0.id == farmID && $0.deletedAt == nil
        }
        guard farms.count == 1,
              farms[0].ownerAccountID == binding.ownerAccountID else { return 0 }

        let confirmed = OutboxStatus.confirmed.rawValue
        let items = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == confirmed
        }))
        var itemByOperationID: [UUID: OutboxItem] = [:]
        var ambiguousItemIDs = Set<UUID>()
        for item in items {
            if itemByOperationID.updateValue(item, forKey: item.operationID) != nil {
                ambiguousItemIDs.insert(item.operationID)
            }
        }

        let operations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        var operationByID: [UUID: DomainOperation] = [:]
        var ambiguousOperationIDs = Set<UUID>()
        for operation in operations {
            if operationByID.updateValue(operation, forKey: operation.id) != nil {
                ambiguousOperationIDs.insert(operation.id)
            }
        }

        let scopeRawValue = binding.databaseScopeRawValue
        // `updatedAt` is also touched by non-identity sync maintenance while a
        // long upload is running. `createdAt` is the safe lower bound here:
        // deleting/recreating the binding necessarily creates a later value.
        let identityEstablishedAt = binding.createdAt
        let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>(predicate: #Predicate {
            $0.farmID == farmID && $0.databaseScopeRawValue == scopeRawValue
        }))
        var updated = 0
        for receipt in receipts {
            guard receipt.zoneName == nil,
                  receipt.zoneOwnerName == nil,
                  receipt.confirmedAt >= identityEstablishedAt,
                  receipt.serverChangeTag?.isEmpty == false,
                  !ambiguousItemIDs.contains(receipt.operationID),
                  !ambiguousOperationIDs.contains(receipt.operationID),
                  let item = itemByOperationID[receipt.operationID],
                  let operation = operationByID[receipt.operationID],
                  receipt.recordName == mapper.recordName(for: operation.id),
                  item.cloudRecordName == receipt.recordName,
                  item.payloadDigest == operation.payloadDigest,
                  CloudPayloadDigest.hex(for: operation.payload) == operation.payloadDigest else { continue }
            receipt.zoneName = binding.zoneName
            receipt.zoneOwnerName = binding.zoneOwnerName
            updated += 1
        }
        if updated > 0 { try context.save() }
        return updated
    }

    /// Baseline v2 only requires the immutable operation record. A previous
    /// build could save that record successfully and then mark the same Outbox
    /// row blocked when its obsolete mutable projection conflicted. Reconcile
    /// those rows from durable operation receipts without reopening any real
    /// operation-record conflict.
    @discardableResult
    func reconcileRefreshedBootstrapOutbox(farmID: UUID) throws -> Int {
        let context = ModelContext(container)
        let active = CloudFarmBindingState.active.rawValue
        var bindingDescriptor = FetchDescriptor<CloudFarmBinding>(predicate: #Predicate {
            $0.farmID == farmID && $0.stateRawValue == active
        })
        bindingDescriptor.fetchLimit = 2
        let bindings = try context.fetch(bindingDescriptor)
        guard bindings.count == 1, let binding = bindings.first else { return 0 }
        let bindingScope = binding.databaseScopeRawValue
        let bindingZoneName = binding.zoneName
        let bindingZoneOwnerName = binding.zoneOwnerName
        let confirmed = OutboxStatus.confirmed.rawValue
        let candidates = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue != confirmed
        })).filter { !$0.status.isTerminalDelivery }
        guard !candidates.isEmpty else { return 0 }

        let candidateOperationIDs = Set(candidates.map(\.operationID))
        let operations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        var operationByID: [UUID: DomainOperation] = [:]
        var duplicateOperationIDs = Set<UUID>()
        for operation in operations where candidateOperationIDs.contains(operation.id) {
            if operationByID.updateValue(operation, forKey: operation.id) != nil {
                duplicateOperationIDs.insert(operation.id)
            }
        }
        let refreshedOperationIDs = Set(candidates.compactMap { item -> UUID? in
            guard !duplicateOperationIDs.contains(item.operationID),
                  let operation = operationByID[item.operationID],
                  item.payloadDigest == operation.payloadDigest,
                  CloudPayloadDigest.hex(for: operation.payload) == operation.payloadDigest,
                  Self.isRefreshedBootstrap(operation) else { return nil }
            return operation.id
        })
        guard !refreshedOperationIDs.isEmpty else { return 0 }

        let confirmedOperationIDs = Set<UUID>(try context.fetch(FetchDescriptor<CloudOperationReceipt>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.databaseScopeRawValue == bindingScope &&
                $0.zoneName == bindingZoneName &&
                $0.zoneOwnerName == bindingZoneOwnerName
        })).compactMap { receipt -> UUID? in
            guard receipt.farmID == farmID,
                  refreshedOperationIDs.contains(receipt.operationID),
                  receipt.recordName == mapper.recordName(for: receipt.operationID) else { return nil }
            return receipt.operationID
        })

        var reconciled = 0
        let blocked = OutboxStatus.blockedConflict.rawValue
        for item in candidates where refreshedOperationIDs.contains(item.operationID) {
            guard let operation = operationByID[item.operationID],
                  item.payloadDigest == operation.payloadDigest else { continue }
            if confirmedOperationIDs.contains(item.operationID) {
                item.statusRawValue = confirmed
                item.errorMessage = nil
                item.nextRetryAt = nil
                item.cloudRecordName = mapper.recordName(for: item.operationID)
                reconciled += 1
            } else if item.statusRawValue == blocked,
                      item.errorMessage?.hasPrefix("云端已有不同内容：实体版本") == true {
                // The stale entity projection is now suppressed at both the
                // CKSyncEngine state and record-construction boundaries. If
                // its immutable operation did not save in the old batch,
                // retry exactly that operation. Any genuine operation-record
                // conflict receives a different error and remains blocked.
                item.statusRawValue = OutboxStatus.pending.rawValue
                item.errorMessage = nil
                item.nextRetryAt = nil
                reconciled += 1
            }
        }
        if reconciled > 0 { try context.save() }
        return reconciled
    }

    private static func isRefreshedBootstrap(_ operation: DomainOperation) -> Bool {
        guard operation.kindRawValue == DomainOperationKind.bootstrapEntity.rawValue else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(FarmCommandCloudPayload.self, from: operation.payload) else { return false }
        return payload.kind == .bootstrapEntity && (payload.integers["baselineVersion"] ?? 1) >= 2
    }

    func markFailedRecords(
        _ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
        scope: CloudDatabaseScope
    ) throws {
        let idempotentServerRecords = failures.compactMap { failure -> CKRecord? in
            guard failure.error.code == .serverRecordChanged,
                  let serverRecord = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                  CloudRecordIdempotency.equivalent(client: failure.record, server: serverRecord) else {
                return nil
            }
            return serverRecord
        }
        if !idempotentServerRecords.isEmpty {
            try confirmSavedRecords(idempotentServerRecords, scope: scope)
        }

        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        for failure in failures {
            if failure.error.code == .serverRecordChanged,
               let serverRecord = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
               CloudRecordIdempotency.equivalent(client: failure.record, server: serverRecord) {
                continue
            }
            guard let target = try validatedSentRecordTarget(
                failure.record,
                scope: scope,
                outbox: outbox,
                operations: operations,
                context: context
            ) else { continue }
            let operation = target.operation
            let item = target.item
            if operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
               failure.record.recordType == CloudRecordType.farmEntity.rawValue {
                // FarmEntity is only a mutable convenience projection for a
                // deletion. Whether it collided, arrived late, or already
                // existed cannot invalidate the immutable Operation +
                // Tombstone authority chain.
                item.statusRawValue = OutboxStatus.awaitingConfirmation.rawValue
                item.errorMessage = nil
                item.nextRetryAt = nil
                continue
            }
            let classification: CloudErrorClassifier.Result
            if failure.error.code == .serverRecordChanged,
               let serverRecord = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
               failure.record.recordType == CloudRecordType.farmEntity.rawValue,
               serverRecord.recordType == CloudRecordType.farmEntity.rawValue {
                if try projectionIsVerifiedAncestor(
                    serverRecord,
                    of: operation,
                    scope: scope,
                    context: context
                ) {
                    classification = CloudErrorClassifier.Result(
                        status: .retryableFailure,
                        message: "云端实体在发送期间发生变化，已重新排队。",
                        retryAt: .now.addingTimeInterval(1)
                    )
                } else {
                    let revisions = CloudEntityProjectionPolicy.revisions(client: failure.record, server: serverRecord)
                    classification = CloudErrorClassifier.Result(
                        status: .blockedConflict,
                        message: "云端已有不同内容：实体版本 \(revisions.remote.map(String.init) ?? "未知") 与本地操作基线 \(revisions.base.map(String.init) ?? "未知") 不属于同一已确认操作链，已停止自动覆盖。",
                        retryAt: nil
                    )
                }
            } else {
                classification = CloudErrorClassifier.classify(failure.error)
            }
            item.statusRawValue = classification.status.rawValue
            item.errorMessage = classification.message
            item.nextRetryAt = classification.retryAt
        }
        try context.save()
    }

    func deferUnresolvedUploadsAfterBatchError(_ error: Error, farmID restrictedFarmID: UUID? = nil) throws {
        let context = ModelContext(container)
        let uploading = OutboxStatus.uploading.rawValue
        let awaiting = OutboxStatus.awaitingConfirmation.rawValue
        let descriptor: FetchDescriptor<OutboxItem>
        if let restrictedFarmID {
            descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate {
                $0.farmID == restrictedFarmID &&
                    ($0.statusRawValue == uploading || $0.statusRawValue == awaiting)
            })
        } else {
            descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate {
                $0.statusRawValue == uploading || $0.statusRawValue == awaiting
            })
        }
        let items = try context.fetch(descriptor)
        for item in items {
            item.statusRawValue = OutboxStatus.retryableFailure.rawValue
            item.errorMessage = "CloudKit 批次未全部完成，已保留并等待重试：\(error.localizedDescription)"
            item.nextRetryAt = .now.addingTimeInterval(15)
        }
        if !items.isEmpty { try context.save() }
    }

    @discardableResult
    func ingest(
        _ records: [CKRecord],
        scope: CloudDatabaseScope,
        recoveryFarmID: UUID? = nil,
        recoveryOperationSources: [String: CloudRebuildOperationSourceProof]? = nil
    ) async throws -> Set<UUID> {
        let eligibilityContext = ModelContext(container)
        let acceptedRecords = try recordsEligibleForLiveIngest(
            records,
            scope: scope,
            recoveryFarmID: recoveryFarmID,
            context: eligibilityContext
        )
        guard !acceptedRecords.isEmpty else { return [] }

        // Persist a verifiable trust snapshot before evaluating operations in
        // the same CloudKit event. Unknown snapshot signers are still resolved
        // through the identity service preflight in CloudSyncActor; a snapshot
        // can never introduce its own signing key.
        let validator = MembershipSnapshotActor(modelContainer: container, persistence: self)
        var rejectedRecoveryMembership = false
        for record in acceptedRecords where record.recordType == CloudRecordType.farmMembershipSnapshot.rawValue {
            do {
                _ = try await validator.validate(record)
            } catch {
                if CloudZoneName.farmID(from: record.recordID.zoneID.zoneName) == recoveryFarmID {
                    rejectedRecoveryMembership = true
                }
                let incidentContext = ModelContext(container)
                incidentContext.insert(SecurityIncidentRecord(
                    farmID: CloudZoneName.farmID(from: record.recordID.zoneID.zoneName),
                    incidentType: error is CloudContractError && (error as? CloudContractError) == .membershipSnapshotRollback ? "membershipSnapshotRollback" : "invalidMembershipSnapshot",
                    recordName: record.recordID.recordName,
                    detail: error.localizedDescription
                ))
                try incidentContext.save()
            }
        }
        if rejectedRecoveryMembership {
            throw CloudSyncError.recoveryCatchUpFailed("云端成员快照未通过验证，牧场继续保持锁定。")
        }

        // Membership validation writes through its own context. Start a fresh
        // one so newly trusted device keys and revocations are visible below.
        let context = ModelContext(container)
        let rejectedRecoveryRoot = try ingestFarmRoots(
            acceptedRecords,
            scope: scope,
            recoveryFarmID: recoveryFarmID,
            context: context
        )
        let rejectedRecoveryAsset = try ingestFarmAssets(
            acceptedRecords,
            recoveryFarmID: recoveryFarmID,
            context: context
        )
        let existingReceipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>())
        var receivedReceipts = Set(existingReceipts.compactMap(Self.receiptIdentity))
        var scheduledReceipts = receivedReceipts
        var rejectedRecoveryOperation = false
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        let revokedCertificates = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        let certificatePublicKey = capabilitySigningPublicKeyPEM
        var historyRebuilds: [UUID: Date] = [:]
        var validatedByOperationID: [UUID: ValidatedLiveOperation] = [:]
        var rejectedDuplicateOperationIDs = Set<UUID>()

        // FarmOperation is the immutable authority. FarmEntity is only a
        // mutable read projection and must never advance the local cache or
        // manufacture an immutable-operation receipt.
        for record in acceptedRecords where record.recordType == CloudRecordType.farmOperation.rawValue {
            do {
                let envelope = try mapper.operationEnvelope(from: record)
                guard CloudZoneName.farmID(from: record.recordID.zoneID.zoneName) == envelope.farmID,
                      record.recordID.recordName == mapper.recordName(for: envelope.operationID) else {
                    throw CloudContractError.malformedRecord
                }
                guard CloudPayloadDigest.hex(for: envelope.payload) == envelope.payloadDigest else {
                    throw CloudContractError.invalidPayloadDigest
                }
                if envelope.farmID == recoveryFarmID,
                   let provenSource = recoveryOperationSources?[record.recordID.recordName] {
                    guard try provenSource.exactlyMatches(record: record, envelope: envelope) else {
                        throw CloudContractError.malformedRecord
                    }
                    // The exact immutable source was already replayed by the
                    // verified cache switch. Reapplying the entire history to
                    // its final state would be both quadratic and would turn
                    // older revisions into false conflicts.
                    continue
                }
                let receiptIdentity = OperationReceiptIdentity(
                    farmID: envelope.farmID,
                    operationID: envelope.operationID,
                    recordName: record.recordID.recordName,
                    scopeRawValue: scope.rawValue,
                    zoneName: record.recordID.zoneID.zoneName,
                    zoneOwnerName: record.recordID.zoneID.ownerName
                )
                if scheduledReceipts.contains(receiptIdentity) { continue }
                guard let certificatePublicKey, !certificatePublicKey.isEmpty else {
                    try quarantine(envelope: envelope, recordName: record.recordID.recordName, reason: "capabilityPublicKeyMissing", context: context)
                    if envelope.farmID == recoveryFarmID {
                        rejectedRecoveryOperation = true
                    }
                    continue
                }
                let claims = try CapabilityCertificateVerifier.verify(envelope.capabilityCertificate, publicKeyPEM: certificatePublicKey)
                if revokedCertificates.contains(where: { $0.farmID == envelope.farmID && $0.serverCertificateID == claims.certificateID }) {
                    try quarantine(envelope: envelope, recordName: record.recordID.recordName, reason: "capabilityRevoked", context: context)
                    if envelope.farmID == recoveryFarmID {
                        rejectedRecoveryOperation = true
                    }
                    continue
                }
                guard let device = devices.first(where: { $0.id == claims.deviceID && $0.accountID == claims.accountID }) else {
                    try quarantine(envelope: envelope, recordName: record.recordID.recordName, reason: "devicePublicKeyMissing", context: context)
                    if envelope.farmID == recoveryFarmID {
                        rejectedRecoveryOperation = true
                    }
                    continue
                }
                try CloudOperationSecurity.validate(
                    envelope: envelope,
                    claims: claims,
                    devicePublicKeyX963: device.publicKeyX963,
                    authorizationDate: record.modificationDate ?? record.creationDate
                )
                let candidate = ValidatedLiveOperation(
                    record: record,
                    envelope: envelope,
                    receiptIdentity: receiptIdentity
                )
                if let existing = validatedByOperationID[envelope.operationID],
                   existing.envelope != envelope {
                    validatedByOperationID[envelope.operationID] = nil
                    rejectedDuplicateOperationIDs.insert(envelope.operationID)
                    if envelope.farmID == recoveryFarmID { rejectedRecoveryOperation = true }
                    context.insert(SecurityIncidentRecord(
                        farmID: envelope.farmID,
                        incidentType: "duplicateImmutableOperationMismatch",
                        recordName: record.recordID.recordName,
                        accountID: envelope.modifiedByAccountID,
                        deviceID: envelope.modifiedByDeviceID,
                        detail: "同一 operationID 在一个云端批次中出现不可变内容不一致，已拒绝应用。"
                    ))
                } else if !rejectedDuplicateOperationIDs.contains(envelope.operationID) {
                    validatedByOperationID[envelope.operationID] = candidate
                    scheduledReceipts.insert(receiptIdentity)
                }
            } catch {
                let mappedEnvelope = try? mapper.operationEnvelope(from: record)
                let mappedFarmID = mappedEnvelope?.farmID ?? CloudZoneName.farmID(from: record.recordID.zoneID.zoneName)
                if mappedFarmID == recoveryFarmID {
                    rejectedRecoveryOperation = true
                }
                context.insert(SecurityIncidentRecord(
                    farmID: mappedEnvelope?.farmID,
                    incidentType: (error as? CloudContractError) == .expiredCertificate
                        ? "cloudAuthorizationExpired"
                        : "malformedCloudOperation",
                    recordName: record.recordID.recordName,
                    accountID: mappedEnvelope?.modifiedByAccountID,
                    deviceID: mappedEnvelope?.modifiedByDeviceID,
                    detail: error.localizedDescription
                ))
            }
        }

        let sortedEnvelopes = CloudRebuildActor.sortedOperations(
            validatedByOperationID.values.map(\.envelope)
        )
        var pending = sortedEnvelopes.compactMap { validatedByOperationID[$0.operationID] }
        let service = RemoteDomainApplyService()

        // A CKSyncEngine callback does not promise operation order. Apply all
        // verified immutable records in deterministic replay order, and retry
        // dependency gaps after other records in the same batch make progress.
        while !pending.isEmpty {
            var deferred: [ValidatedLiveOperation] = []
            var madeProgress = false
            for candidate in pending {
                let envelope = candidate.envelope
                do {
                    let outcome = try service.apply(envelope, context: context)
                    switch outcome {
                    case .applied(let changedAt):
                        madeProgress = true
                        if let changedAt {
                            historyRebuilds[envelope.farmID] = min(
                                historyRebuilds[envelope.farmID] ?? changedAt,
                                changedAt
                            )
                        }
                    case .duplicate:
                        madeProgress = true
                    case .conflict(let localRevision):
                        if localRevision < envelope.baseRevision {
                            deferred.append(candidate)
                            continue
                        }
                        try insertLiveConflict(
                            envelope: envelope,
                            localRevision: localRevision,
                            context: context
                        )
                        if envelope.farmID == recoveryFarmID {
                            rejectedRecoveryOperation = true
                        }
                        continue
                    }
                    _ = try RemoteDomainAuditProjection.insertIfNeeded(
                        envelope,
                        context: context
                    )
                    context.insert(CloudOperationReceipt(
                        farmID: envelope.farmID,
                        operationID: envelope.operationID,
                        recordName: candidate.record.recordID.recordName,
                        serverChangeTag: candidate.record.recordChangeTag,
                        databaseScope: scope,
                        zoneName: candidate.record.recordID.zoneID.zoneName,
                        zoneOwnerName: candidate.record.recordID.zoneID.ownerName
                    ))
                    receivedReceipts.insert(candidate.receiptIdentity)
                } catch let error as RemoteDomainApplyError {
                    if case .missingReference = error {
                        deferred.append(candidate)
                        continue
                    }
                    if envelope.farmID == recoveryFarmID { rejectedRecoveryOperation = true }
                    context.insert(SecurityIncidentRecord(
                        farmID: envelope.farmID,
                        incidentType: "malformedCloudOperation",
                        recordName: candidate.record.recordID.recordName,
                        accountID: envelope.modifiedByAccountID,
                        deviceID: envelope.modifiedByDeviceID,
                        detail: error.localizedDescription
                    ))
                } catch {
                    if envelope.farmID == recoveryFarmID { rejectedRecoveryOperation = true }
                    context.insert(SecurityIncidentRecord(
                        farmID: envelope.farmID,
                        incidentType: "malformedCloudOperation",
                        recordName: candidate.record.recordID.recordName,
                        accountID: envelope.modifiedByAccountID,
                        deviceID: envelope.modifiedByDeviceID,
                        detail: error.localizedDescription
                    ))
                }
            }
            pending = deferred
            if !madeProgress { break }
        }

        let recoveryRequiredFarmIDs = try lockFarmsForLiveOperationGaps(
            pending,
            recoveryFarmID: recoveryFarmID,
            context: context
        )
        if recoveryFarmID.map(recoveryRequiredFarmIDs.contains) == true {
            rejectedRecoveryOperation = true
        }
        for (farmID, changedAt) in historyRebuilds {
            try FarmHistoryRebuilder().rebuild(farmID: farmID, context: context, from: changedAt)
        }
        try context.save()
        if rejectedRecoveryRoot || rejectedRecoveryAsset || rejectedRecoveryOperation {
            throw CloudSyncError.recoveryCatchUpFailed("云端增量中存在未能验证或应用的记录，牧场继续保持锁定。")
        }
        return recoveryRequiredFarmIDs
    }

    private func insertLiveConflict(
        envelope: CloudOperationEnvelope,
        localRevision: Int,
        context: ModelContext
    ) throws {
        let alreadyRecorded = try context.fetch(FetchDescriptor<SyncConflictRecord>()).contains {
            $0.farmID == envelope.farmID &&
                $0.entityID == envelope.entityID &&
                $0.remoteRevision == envelope.revision &&
                $0.remotePayloadDigest == envelope.payloadDigest &&
                ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue ||
                    $0.statusRawValue == SyncConflictStatus.quarantined.rawValue)
        }
        guard !alreadyRecorded else { return }
        let localPayload = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == envelope.farmID && $0.entityID == envelope.entityID }
            .max(by: { $0.resultingRevision < $1.resultingRevision })?.payload ?? Data()
        let conflict = SyncConflictRecord(
            farmID: envelope.farmID,
            entityID: envelope.entityID,
            entityType: envelope.entityType,
            localRevision: localRevision,
            remoteRevision: envelope.revision,
            localPayload: localPayload,
            remotePayload: envelope.payload,
            remoteAccountID: envelope.modifiedByAccountID,
            remoteDeviceID: envelope.modifiedByDeviceID,
            reasonCode: "baseRevisionMismatch"
        )
        conflict.remoteEnvelopeData = try JSONEncoder.cloud.encode(envelope)
        context.insert(conflict)
    }

    private func lockFarmsForLiveOperationGaps(
        _ gaps: [ValidatedLiveOperation],
        recoveryFarmID: UUID?,
        context: ModelContext
    ) throws -> Set<UUID> {
        guard !gaps.isEmpty else { return [] }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        var affectedFarmIDs = Set<UUID>()
        var recordedOperationIDs = Set<UUID>()
        for gap in gaps {
            let envelope = gap.envelope
            guard let binding = bindings.first(where: {
                $0.farmID == envelope.farmID &&
                    $0.zoneName == gap.record.recordID.zoneID.zoneName &&
                    $0.zoneOwnerName == gap.record.recordID.zoneID.ownerName &&
                    ($0.state == .active || ($0.farmID == recoveryFarmID && $0.state == .rebuildingCache))
            }) else { continue }
            binding.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
            binding.lastErrorCode = "liveOperationGap"
            binding.updatedAt = .now
            affectedFarmIDs.insert(envelope.farmID)
            guard recordedOperationIDs.insert(envelope.operationID).inserted else { continue }
            context.insert(SecurityIncidentRecord(
                farmID: envelope.farmID,
                incidentType: "liveOperationGap",
                recordName: gap.record.recordID.recordName,
                accountID: envelope.modifiedByAccountID,
                deviceID: envelope.modifiedByDeviceID,
                detail: "云端操作 revision \(envelope.revision) 缺少可验证的基线 revision \(envelope.baseRevision)，已锁定缓存并要求完整重建。"
            ))
        }
        return affectedFarmIDs
    }

    /// Finds records whose capability is signed by the configured authority
    /// but whose signing device key is not yet present locally. The record's
    /// farm must match exactly one eligible binding for its CloudKit zone
    /// before it can trigger an identity-service refresh.
    func farmIDsRequiringDeviceTrustRefresh(
        for records: [CKRecord],
        scope: CloudDatabaseScope,
        recoveryFarmID: UUID? = nil,
        recoveryOperationRecordNames: Set<String> = []
    ) throws -> Set<UUID> {
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>()).filter {
            $0.databaseScope == scope &&
                ($0.state == .active || ($0.farmID == recoveryFarmID && $0.state == .rebuildingCache))
        }
        let groupedBindings = Dictionary(grouping: bindings) {
            LiveIngestZone(name: $0.zoneName, ownerName: $0.zoneOwnerName)
        }
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        let revoked = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        guard let publicKeyPEM = capabilitySigningPublicKeyPEM,
              !publicKeyPEM.isEmpty else { return [] }

        var farmIDs = Set<UUID>()
        for record in records {
            if record.recordType == CloudRecordType.farmOperation.rawValue,
               recoveryOperationRecordNames.contains(record.recordID.recordName) {
                // The completed rebuild already validated this exact immutable
                // source. The later ingest proof checks its CloudKit version;
                // trust preflight only needs to inspect records added since.
                continue
            }
            let zone = LiveIngestZone(
                name: record.recordID.zoneID.zoneName,
                ownerName: record.recordID.zoneID.ownerName
            )
            guard let matches = groupedBindings[zone], matches.count == 1,
                  let binding = matches.first else { continue }

            let identity: (farmID: UUID, accountID: UUID, deviceID: UUID, certificate: String)?
            switch record.recordType {
            case CloudRecordType.farmOperation.rawValue:
                if let envelope = try? mapper.operationEnvelope(from: record) {
                    identity = (
                        envelope.farmID,
                        envelope.modifiedByAccountID,
                        envelope.modifiedByDeviceID,
                        envelope.capabilityCertificate
                    )
                } else {
                    identity = nil
                }
            case CloudRecordType.farmAsset.rawValue, CloudRecordType.farmMembershipSnapshot.rawValue:
                if let farmText = record[CloudRecordField.farmID] as? String,
                   let farmID = UUID(uuidString: farmText),
                   let accountText = record[CloudRecordField.modifiedByAccountID] as? String,
                   let accountID = UUID(uuidString: accountText),
                   let deviceText = record[CloudRecordField.modifiedByDeviceID] as? String,
                   let deviceID = UUID(uuidString: deviceText),
                   let certificate = record[CloudRecordField.capabilityCertificate] as? String {
                    identity = (farmID, accountID, deviceID, certificate)
                } else {
                    identity = nil
                }
            default:
                identity = nil
            }
            guard let identity,
                  identity.farmID == binding.farmID,
                  let claims = try? CapabilityCertificateVerifier.verify(
                      identity.certificate,
                      publicKeyPEM: publicKeyPEM
                  ),
                  claims.farmID == identity.farmID,
                  claims.accountID == identity.accountID,
                  claims.deviceID == identity.deviceID,
                  claims.isValid(at: record.modificationDate ?? record.creationDate ?? .now),
                  !revoked.contains(where: {
                      $0.farmID == identity.farmID &&
                          $0.serverCertificateID == claims.certificateID
                  }),
                  !devices.contains(where: {
                      $0.id == identity.deviceID && $0.accountID == identity.accountID
                  }) else { continue }
            farmIDs.insert(identity.farmID)
        }
        return farmIDs
    }

    func lockForDeviceTrustRecovery(farmIDs: Set<UUID>, detail: String) throws {
        guard !farmIDs.isEmpty else { return }
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        for binding in bindings where farmIDs.contains(binding.farmID) && binding.state != .accessRevoked {
            binding.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
            binding.lastErrorCode = "deviceTrustRefreshRequired"
            binding.updatedAt = .now
            context.insert(SecurityIncidentRecord(
                farmID: binding.farmID,
                incidentType: "deviceTrustRefreshRequired",
                detail: detail
            ))
        }
        try context.save()
    }

    private struct LiveIngestZone: Hashable {
        let name: String
        let ownerName: String
    }

    private struct OperationReceiptIdentity: Hashable {
        let farmID: UUID
        let operationID: UUID
        let recordName: String
        let scopeRawValue: String
        let zoneName: String
        let zoneOwnerName: String
    }

    private static func receiptIdentity(_ receipt: CloudOperationReceipt) -> OperationReceiptIdentity? {
        guard let zoneName = receipt.zoneName,
              let zoneOwnerName = receipt.zoneOwnerName else { return nil }
        return OperationReceiptIdentity(
            farmID: receipt.farmID,
            operationID: receipt.operationID,
            recordName: receipt.recordName,
            scopeRawValue: receipt.databaseScopeRawValue,
            zoneName: zoneName,
            zoneOwnerName: zoneOwnerName
        )
    }

    /// Reloads and re-verifies the newest completed bundle, including every
    /// immutable source observed before v2 canonicalization. The nil-state
    /// CKSyncEngine catch-up can then skip exact history, apply only records
    /// created after the snapshot, and reject mutations of proven sources.
    func provenOperationSourcesForRecovery(
        farmID: UUID,
        scope: CloudDatabaseScope
    ) throws -> [String: CloudRebuildOperationSourceProof] {
        let context = ModelContext(container)
        guard try context.fetch(FetchDescriptor<CloudFarmBinding>()).contains(where: {
            $0.farmID == farmID &&
                $0.databaseScope == scope &&
                $0.state == .rebuildingCache
        }) else {
            throw CloudSyncError.farmBindingMissing
        }
        guard let session = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter({ $0.farmID == farmID && $0.databaseScope == scope })
            .max(by: {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }),
              session.status == .completed,
              session.completedAt != nil else {
            throw CloudSyncError.recoveryCatchUpFailed("缺少已完成重建的不可变来源证明。")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let workspace = support.appending(path: session.stagingRelativePath, directoryHint: .isDirectory)
        let data = try Data(contentsOf: workspace.appending(path: "bundle.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(CloudRebuildBundle.self, from: data)
        guard CloudRebuildActor.hasCurrentAuthorityProof(bundle),
              bundle.sessionID == session.id,
              bundle.farmID == farmID,
              bundle.scope == scope,
              bundle.recordCount == session.fetchedRecordCount,
              bundle.pageCount == session.pageCount,
              bundle.operations.count == session.fetchedOperationCount,
              bundle.assets.count == session.downloadedAssetCount,
              session.entityDigest == CloudRebuildActor.entityDigest(bundle.operations),
              let proofs = bundle.operationSourceProofs else {
            throw CloudSyncError.recoveryCatchUpFailed("已完成重建的不可变来源证明不完整。")
        }
        try CloudRebuildBundleValidator.validate(bundle)
        try CloudRebuildStagingBuilder.verify(bundle: bundle, workspace: workspace)
        return Dictionary(uniqueKeysWithValues: proofs.map { ($0.recordName, $0) })
    }

    private func recordsEligibleForLiveIngest(
        _ records: [CKRecord],
        scope: CloudDatabaseScope,
        recoveryFarmID: UUID?,
        context: ModelContext
    ) throws -> [CKRecord] {
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let eligibleZoneList: [LiveIngestZone] = bindings.compactMap { binding in
            let isActive = binding.state == .active
            let isAuthorizedRecovery = binding.farmID == recoveryFarmID && binding.state == .rebuildingCache
            guard binding.databaseScope == scope, isActive || isAuthorizedRecovery else { return nil }
            return LiveIngestZone(name: binding.zoneName, ownerName: binding.zoneOwnerName)
        }
        let eligibleZones = Set(eligibleZoneList)
        return records.filter { record in
            eligibleZones.contains(LiveIngestZone(
                name: record.recordID.zoneID.zoneName,
                ownerName: record.recordID.zoneID.ownerName
            ))
        }
    }

    private func ingestFarmAssets(
        _ records: [CKRecord],
        recoveryFarmID: UUID?,
        context: ModelContext
    ) throws -> Bool {
        var rejectedRecoveryRecord = false
        let existing = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
        let transfers = try context.fetch(FetchDescriptor<CloudAssetTransfer>())
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        let revokedCertificates = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        let certificatePublicKey = capabilitySigningPublicKeyPEM
        for record in records where record.recordType == CloudRecordType.farmAsset.rawValue {
            guard let farmText = record[CloudRecordField.farmID] as? String,
                  let farmID = UUID(uuidString: farmText),
                  let assetID = mapper.assetID(from: record.recordID),
                  let digest = record[CloudRecordField.payloadDigest] as? String,
                  let accountText = record[CloudRecordField.modifiedByAccountID] as? String,
                  let accountID = UUID(uuidString: accountText),
                  let deviceText = record[CloudRecordField.modifiedByDeviceID] as? String,
                  let deviceID = UUID(uuidString: deviceText),
                  let certificate = record[CloudRecordField.capabilityCertificate] as? String,
                  let signature = record[CloudRecordField.signature] as? Data else {
                if CloudZoneName.farmID(from: record.recordID.zoneID.zoneName) == recoveryFarmID {
                    rejectedRecoveryRecord = true
                }
                context.insert(SecurityIncidentRecord(farmID: nil, incidentType: "malformedFarmAsset", recordName: record.recordID.recordName, detail: "照片记录缺少牧场、资产或校验字段。"))
                continue
            }
            let sourceDigest = record[CloudRecordField.sourceDigest] as? String ?? ""
            let mimeType = record[CloudRecordField.mimeType] as? String ?? "image/jpeg"
            let byteCount = (record[CloudRecordField.byteCount] as? NSNumber)?.int64Value ?? 0
            let linkedID = (record["linkedEntityID"] as? String).flatMap(UUID.init(uuidString:))
            let envelope = FarmAssetEnvelope(
                farmID: farmID,
                assetID: assetID,
                entityID: linkedID,
                sourceDigest: sourceDigest,
                payloadDigest: digest,
                mimeType: mimeType,
                pixelWidth: (record[CloudRecordField.pixelWidth] as? NSNumber)?.intValue ?? 0,
                pixelHeight: (record[CloudRecordField.pixelHeight] as? NSNumber)?.intValue ?? 0,
                capturedAt: record[CloudRecordField.capturedAt] as? Date,
                byteCount: byteCount,
                createdAt: record[CloudRecordField.modifiedAt] as? Date ?? .distantPast,
                modifiedByAccountID: accountID,
                modifiedByDeviceID: deviceID,
                capabilityCertificate: certificate,
                signature: signature
            )
            let authorizationDate: Date
            let signatureFormat: FarmAssetSignatureFormat
            do {
                authorizationDate = try mapper.assetAuthorizationDate(from: record)
                guard let certificatePublicKey, !certificatePublicKey.isEmpty else { throw CloudContractError.invalidCertificate }
                let claims = try CapabilityCertificateVerifier.verify(certificate, publicKeyPEM: certificatePublicKey)
                guard claims.farmID == farmID, claims.accountID == accountID, claims.deviceID == deviceID,
                      claims.capabilities.contains(.recordProduction), claims.isValid(at: authorizationDate),
                      !revokedCertificates.contains(where: { $0.farmID == farmID && $0.serverCertificateID == claims.certificateID }),
                      let device = devices.first(where: { $0.id == deviceID && $0.accountID == accountID }) else {
                    throw CloudContractError.capabilityDenied
                }
                signatureFormat = try FarmAssetSignatureVerifier.verify(
                    envelope: envelope,
                    declaredVersion: try mapper.assetSignatureVersion(from: record),
                    publicKeyX963: device.publicKeyX963
                )
            } catch {
                if farmID == recoveryFarmID {
                    rejectedRecoveryRecord = true
                }
                context.insert(SecurityIncidentRecord(farmID: farmID, incidentType: "invalidFarmAssetSignature", recordName: record.recordID.recordName, accountID: accountID, deviceID: deviceID, detail: error.localizedDescription))
                continue
            }
            let asset: PhotoAssetRecord
            let existingAsset = existing.first(where: { $0.id == assetID })
            if let value = existingAsset {
                asset = value
            } else {
                asset = PhotoAssetRecord(id: assetID, farmID: farmID, sheepID: linkedID, legacySourceKey: "cloud:\(record.recordID.recordName)", originalEarTag: "", relativePath: "", sha256: digest, mimeType: mimeType)
                context.insert(asset)
            }
            if signatureFormat == .legacyV1 {
                let payloadChanged = asset.sha256 != digest
                let trustedCapturedAt = existingAsset?.capturedAt
                let trustedCreatedAt = existingAsset?.createdAt ?? record.creationDate ?? authorizationDate
                asset.farmID = farmID
                asset.sheepID = linkedID
                asset.sourceSHA256 = sourceDigest
                asset.sha256 = digest
                asset.mimeType = mimeType
                asset.cloudPixelWidth = envelope.pixelWidth
                asset.cloudPixelHeight = envelope.pixelHeight
                // Legacy signatures do not cover either date. Keep metadata
                // already held locally; on a new device use only CloudKit's
                // server-authored creation time and leave capturedAt unknown.
                asset.capturedAt = trustedCapturedAt
                asset.createdAt = trustedCreatedAt
                asset.cloudRecordName = record.recordID.recordName
                asset.isCloudAuthoritative = false
                if payloadChanged {
                    asset.relativePath = ""
                    for transfer in transfers where transfer.assetID == assetID && transfer.direction == .download {
                        transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
                        transfer.payloadDigest = digest
                        transfer.byteCount = byteCount
                        transfer.transferredByteCount = 0
                        transfer.lastErrorCode = nil
                        transfer.nextRetryAt = nil
                        transfer.remoteRecordName = record.recordID.recordName
                        transfer.updatedAt = .now
                    }
                }
                if asset.relativePath.isEmpty && !transfers.contains(where: {
                    $0.assetID == assetID && $0.direction == .download && $0.status != .failed
                }) {
                    context.insert(CloudAssetTransfer(
                        farmID: farmID,
                        assetID: assetID,
                        localRelativePath: "",
                        payloadDigest: digest,
                        byteCount: byteCount,
                        direction: .download,
                        sourceDigest: sourceDigest
                    ))
                }
                let uploadTransfers = transfers.filter {
                    $0.farmID == farmID && $0.assetID == assetID && $0.direction == .upload
                }
                if Self.prepareLegacyAssetForV2Resign(
                    asset,
                    recordName: record.recordID.recordName,
                    sourceDigest: sourceDigest,
                    payloadDigest: digest,
                    byteCount: byteCount,
                    uploadTransfers: uploadTransfers
                ) {
                    context.insert(CloudAssetTransfer(
                        farmID: farmID,
                        assetID: assetID,
                        localRelativePath: asset.relativePath,
                        payloadDigest: digest,
                        byteCount: byteCount,
                        direction: .upload,
                        sourceDigest: sourceDigest
                    ))
                }
                continue
            }
            asset.sourceSHA256 = sourceDigest
            let incompleteUploads = transfers.filter {
                $0.farmID == farmID &&
                    $0.assetID == assetID &&
                    $0.direction == .upload &&
                    $0.status != .completed
            }
            if !incompleteUploads.isEmpty,
               !Self.photoAsset(asset, exactlyMatches: envelope, uploadTransfers: incompleteUploads) {
                // A recovery reset may fetch the old cloud metadata while a
                // local capturedAt edit is still waiting to upload. Preserve
                // that local envelope; otherwise the subsequent upload would
                // write the stale value back and permanently lose the edit.
                asset.cloudRecordName = record.recordID.recordName
                asset.isCloudAuthoritative = false
                for transfer in incompleteUploads where transfer.status == .uploading {
                    transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
                    transfer.transferredByteCount = 0
                    transfer.lastErrorCode = nil
                    transfer.nextRetryAt = nil
                    transfer.updatedAt = .now
                }
                continue
            }

            let payloadChanged = asset.sha256 != digest
            asset.farmID = farmID
            asset.sheepID = linkedID
            asset.sourceSHA256 = sourceDigest
            asset.sha256 = digest
            asset.mimeType = mimeType
            asset.cloudPixelWidth = envelope.pixelWidth
            asset.cloudPixelHeight = envelope.pixelHeight
            asset.capturedAt = envelope.capturedAt
            asset.createdAt = envelope.createdAt
            asset.cloudRecordName = record.recordID.recordName
            asset.isCloudAuthoritative = true
            for transfer in incompleteUploads {
                transfer.statusRawValue = CloudAssetTransferStatus.completed.rawValue
                transfer.transferredByteCount = transfer.byteCount
                transfer.lastErrorCode = nil
                transfer.nextRetryAt = nil
                transfer.remoteRecordName = record.recordID.recordName
                transfer.updatedAt = .now
            }
            if payloadChanged {
                asset.relativePath = ""
                for transfer in transfers where transfer.assetID == assetID && transfer.direction == .download {
                    transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
                    transfer.payloadDigest = digest
                    transfer.byteCount = byteCount
                    transfer.transferredByteCount = 0
                    transfer.lastErrorCode = nil
                    transfer.nextRetryAt = nil
                    transfer.remoteRecordName = record.recordID.recordName
                    transfer.updatedAt = .now
                }
            }
            if asset.relativePath.isEmpty && !transfers.contains(where: { $0.assetID == assetID && $0.direction == .download && $0.status != .failed }) {
                context.insert(CloudAssetTransfer(farmID: farmID, assetID: assetID, localRelativePath: "", payloadDigest: digest, byteCount: byteCount, direction: .download, sourceDigest: sourceDigest))
            }
        }
        return rejectedRecoveryRecord
    }

    private static func photoAsset(
        _ asset: PhotoAssetRecord,
        exactlyMatches envelope: FarmAssetEnvelope,
        uploadTransfers: [CloudAssetTransfer]
    ) -> Bool {
        let transferMatches = uploadTransfers.contains {
            $0.payloadDigest == envelope.payloadDigest &&
                $0.byteCount == envelope.byteCount &&
                ($0.sourceDigest.isEmpty || $0.sourceDigest == envelope.sourceDigest)
        }
        return asset.farmID == envelope.farmID &&
            asset.id == envelope.assetID &&
            asset.sheepID == envelope.entityID &&
            asset.sourceSHA256 == envelope.sourceDigest &&
            asset.sha256 == envelope.payloadDigest &&
            asset.mimeType == envelope.mimeType &&
            asset.cloudPixelWidth == envelope.pixelWidth &&
            asset.cloudPixelHeight == envelope.pixelHeight &&
            CloudRebuildRootSnapshot.milliseconds(asset.capturedAt ?? .distantPast) ==
                CloudRebuildRootSnapshot.milliseconds(envelope.capturedAt ?? .distantPast) &&
            CloudRebuildRootSnapshot.milliseconds(asset.createdAt) ==
                CloudRebuildRootSnapshot.milliseconds(envelope.createdAt) &&
            transferMatches
    }

    /// Returns true when the caller must insert a new upload transfer.
    @discardableResult
    static func prepareLegacyAssetForV2Resign(
        _ asset: PhotoAssetRecord,
        recordName: String,
        sourceDigest: String,
        payloadDigest: String,
        byteCount: Int64,
        uploadTransfers: [CloudAssetTransfer]
    ) -> Bool {
        asset.cloudRecordName = recordName
        asset.isCloudAuthoritative = false
        for transfer in uploadTransfers {
            transfer.localRelativePath = asset.relativePath
            transfer.payloadDigest = payloadDigest
            transfer.byteCount = byteCount
            transfer.sourceDigest = sourceDigest
            transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
            transfer.transferredByteCount = 0
            transfer.lastErrorCode = "旧版照片签名已验证，等待当前设备重签 v2。"
            transfer.nextRetryAt = nil
            transfer.remoteRecordName = recordName
            transfer.updatedAt = .now
        }
        return uploadTransfers.isEmpty
    }

    private func ingestFarmRoots(
        _ records: [CKRecord],
        scope: CloudDatabaseScope,
        recoveryFarmID: UUID?,
        context: ModelContext
    ) throws -> Bool {
        var rejectedRecoveryRecord = false
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        let accounts = try context.fetch(FetchDescriptor<AccountProfile>())
        let localAccountID = accounts.first?.effectiveAccountID
        let memberships = try context.fetch(FetchDescriptor<FarmMembershipBinding>())
        for record in records where record.recordType == CloudRecordType.farmRoot.rawValue {
            do {
                let root = try mapper.farmRootValue(from: record)
                if let farm = farms.first(where: { $0.id == root.farmID }) {
                    if farm.name == SharedFarmAdmissionPolicy.pendingFarmName {
                        farm.name = root.name
                        farm.ownerAccountID = root.ownerAccountID
                        farm.updatedAt = root.modifiedAt
                        continue
                    }
                    if farm.name != root.name || farm.ownerAccountID != root.ownerAccountID {
                        if root.farmID == recoveryFarmID {
                            rejectedRecoveryRecord = true
                        }
                        context.insert(SecurityIncidentRecord(
                            farmID: root.farmID,
                            incidentType: "unsignedFarmRootModification",
                            recordName: record.recordID.recordName,
                            detail: "检测到未通过签名操作修改牧场根记录，未覆盖本地牧场资料。"
                        ))
                    }
                    continue
                }
                let role = localAccountID.flatMap { accountID in
                    memberships.first(where: { $0.farmID == root.farmID && $0.accountID == accountID })?.role
                } ?? (scope == .privateDatabase ? .owner : .worker)
                context.insert(FarmRecord(
                    id: root.farmID,
                    ownerAccountID: root.ownerAccountID,
                    name: root.name,
                    role: role,
                    createdAt: root.modifiedAt,
                    updatedAt: root.modifiedAt
                ))
            } catch {
                if CloudZoneName.farmID(from: record.recordID.zoneID.zoneName) == recoveryFarmID {
                    rejectedRecoveryRecord = true
                }
                context.insert(SecurityIncidentRecord(
                    farmID: CloudZoneName.farmID(from: record.recordID.zoneID.zoneName),
                    incidentType: "malformedFarmRoot",
                    recordName: record.recordID.recordName,
                    detail: error.localizedDescription
                ))
            }
        }
        return rejectedRecoveryRecord
    }

    private func quarantine(envelope: CloudOperationEnvelope, recordName: String, reason: String, context: ModelContext) throws {
        let conflict = SyncConflictRecord(
            farmID: envelope.farmID,
            entityID: envelope.entityID,
            entityType: envelope.entityType,
            localRevision: 0,
            remoteRevision: envelope.revision,
            localPayload: Data(),
            remotePayload: envelope.payload,
            remoteAccountID: envelope.modifiedByAccountID,
            remoteDeviceID: envelope.modifiedByDeviceID,
            reasonCode: reason,
            status: .quarantined
        )
        conflict.remoteEnvelopeData = try JSONEncoder.cloud.encode(envelope)
        context.insert(conflict)
        context.insert(SecurityIncidentRecord(
            farmID: envelope.farmID,
            incidentType: reason,
            recordName: recordName,
            accountID: envelope.modifiedByAccountID,
            deviceID: envelope.modifiedByDeviceID,
            detail: "云端操作已隔离，未覆盖本地数据。"
        ))
    }

    func recordUnexpectedDeletions(
        _ deletions: [CKDatabase.RecordZoneChange.Deletion],
        recoveryFarmID: UUID? = nil,
        recoveryAuthoritativeOperationRecordNames: Set<String>? = nil
    ) throws -> Set<UUID> {
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let activeZoneList: [LiveIngestZone] = bindings.compactMap { binding in
            let isActive = binding.state == .active
            let isAuthorizedRecovery = binding.farmID == recoveryFarmID && binding.state == .rebuildingCache
            guard isActive || isAuthorizedRecovery else { return nil }
            return LiveIngestZone(name: binding.zoneName, ownerName: binding.zoneOwnerName)
        }
        let activeZones = Set(activeZoneList)
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
        let assets = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
        let transfers = try context.fetch(FetchDescriptor<CloudAssetTransfer>())
        var rejectedRecoveryDeletion = false
        var authoritativeRecoveryFarmIDs = Set<UUID>()

        for deletion in deletions where
            deletion.recordType == CloudRecordType.farmOperation.rawValue &&
            activeZones.contains(LiveIngestZone(
                name: deletion.recordID.zoneID.zoneName,
                ownerName: deletion.recordID.zoneID.ownerName
            )) {
            let zone = LiveIngestZone(
                name: deletion.recordID.zoneID.zoneName,
                ownerName: deletion.recordID.zoneID.ownerName
            )
            let matchingBindings = bindings.filter {
                $0.zoneName == zone.name &&
                    $0.zoneOwnerName == zone.ownerName &&
                    ($0.state == .active || ($0.farmID == recoveryFarmID && $0.state == .rebuildingCache))
            }
            guard mapper.operationID(from: deletion.recordID) != nil,
                  matchingBindings.count == 1,
                  let binding = matchingBindings.first else { continue }
            if binding.farmID == recoveryFarmID,
               let recoveryAuthoritativeOperationRecordNames,
               !recoveryAuthoritativeOperationRecordNames.contains(deletion.recordID.recordName) {
                context.insert(SecurityIncidentRecord(
                    farmID: binding.farmID,
                    incidentType: "historicalOperationDeletionExcludedByRebuildProof",
                    recordName: deletion.recordID.recordName,
                    detail: "该不可变操作删除不在本次已验证重建来源中，视为权威基线之前的历史清理记录。"
                ))
                continue
            }
            binding.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
            binding.lastErrorCode = "immutableOperationHardDelete"
            binding.updatedAt = .now
            authoritativeRecoveryFarmIDs.insert(binding.farmID)
            context.insert(SecurityIncidentRecord(
                farmID: binding.farmID,
                incidentType: "immutableOperationHardDelete",
                recordName: deletion.recordID.recordName,
                detail: "检测到不可变云端操作被硬删除，已锁定本地缓存并要求按 ready 根记录完整重建。"
            ))
            if binding.farmID == recoveryFarmID {
                rejectedRecoveryDeletion = true
            }
        }

        for deletion in deletions where
            activeZones.contains(LiveIngestZone(name: deletion.recordID.zoneID.zoneName, ownerName: deletion.recordID.zoneID.ownerName)) &&
            (deletion.recordType == CloudRecordType.farmEntity.rawValue || deletion.recordType == CloudRecordType.farmAsset.rawValue) {
            var farmID = CloudZoneName.farmID(from: deletion.recordID.zoneID.zoneName)
            var entityID: UUID?
            if deletion.recordType == CloudRecordType.farmEntity.rawValue,
               let deletedEntityID = mapper.entityID(from: deletion.recordID) {
                entityID = deletedEntityID
                farmID = operations.first(where: { $0.entityID == deletedEntityID })?.farmID ?? farmID
            } else if let assetID = mapper.assetID(from: deletion.recordID) {
                entityID = assetID
                farmID = assets.first(where: { $0.id == assetID })?.farmID ?? farmID
            }
            if let farmID, let entityID, tombstones.contains(where: { $0.farmID == farmID && $0.entityID == entityID && $0.restoredAt == nil }) {
                continue
            }
            context.insert(SecurityIncidentRecord(
                farmID: farmID,
                incidentType: "unexpectedHardDelete",
                recordName: deletion.recordID.recordName,
                detail: "检测到没有合法 Tombstone 的 CloudKit 实体硬删除，未删除本地数据。"
            ))
            if farmID == recoveryFarmID {
                rejectedRecoveryDeletion = true
            }
            if deletion.recordType == CloudRecordType.farmAsset.rawValue,
               let farmID, let assetID = entityID,
               let asset = assets.first(where: { $0.id == assetID && $0.recoveryRecordName != nil }),
               !transfers.contains(where: { $0.assetID == assetID && $0.direction == .recoveryRestore && $0.status != .completed }) {
                context.insert(CloudAssetTransfer(farmID: farmID, assetID: assetID, localRelativePath: asset.relativePath, payloadDigest: asset.sha256, byteCount: 0, direction: .recoveryRestore, sourceDigest: asset.sourceSHA256))
            }
        }
        try context.save()
        if rejectedRecoveryDeletion {
            throw CloudSyncError.recoveryCatchUpFailed("云端增量中存在没有合法 Tombstone 的硬删除，牧场继续保持锁定。")
        }
        return authoritativeRecoveryFarmIDs
    }

    func saveEngineState(_ serialization: CKSyncEngine.State.Serialization, scope: CloudDatabaseScope) throws {
        let encoded = try JSONEncoder().encode(serialization)
        try CloudEngineStateDiskStore.save(encoded, scope: scope)
        let context = ModelContext(container)
        let states = try context.fetch(FetchDescriptor<CloudZoneState>())
        let state = states.first(where: { $0.databaseScopeRawValue == scope.rawValue }) ?? CloudZoneState(databaseScope: scope)
        if state.modelContext == nil { context.insert(state) }
        state.serializedState = encoded
        state.updatedAt = .now
        try context.save()
    }

    func revokeSharedAccess(farmID: UUID) throws {
        let context = ModelContext(container)
        if let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farmID }) {
            binding.stateRawValue = CloudFarmBindingState.accessRevoked.rawValue
            binding.updatedAt = .now
        }
        for item in try context.fetch(FetchDescriptor<OutboxItem>())
        where item.farmID == farmID && !item.status.isTerminalDelivery {
            item.statusRawValue = OutboxStatus.rejectedPermission.rawValue
            item.errorMessage = "牧场共享访问已经撤销，未确认操作保留在本机只读导出区。"
        }
        for certificate in try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        where certificate.farmID == farmID && certificate.revokedAt == nil {
            certificate.revokedAt = .now
        }
        try purgeFarmCache(farmID: farmID, context: context)
        try context.save()
    }

    /// Removes one explicitly authorized obsolete local migration only after
    /// proving that its exact formal replacement is the active owner cloud farm
    /// created from the same verified source. The explicit IDs keep this
    /// destructive repair from widening to unrelated same-name farms.
    func purgeSupersededLocalMigrationFarm(
        obsoleteFarmID: UUID,
        replacementFarmID: UUID,
        ownerAccountID: UUID
    ) throws -> Bool {
        let context = ModelContext(container)
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>())
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        guard obsoleteFarmID != replacementFarmID,
              let replacementFarm = farms.first(where: {
                  $0.id == replacementFarmID &&
                      $0.ownerAccountID == ownerAccountID &&
                      !$0.isLocalOnlyMigration &&
                      $0.deletedAt == nil
              }),
              let replacementCommit = commits.first(where: {
                  $0.farmID == replacementFarmID &&
                      $0.ownerAccountID == ownerAccountID &&
                      $0.statusRawValue == MigrationCommitStatus.completed.rawValue &&
                      $0.cloudStateRawValue == MigrationCloudState.synced.rawValue &&
                      !$0.sourceChecksum.isEmpty
              }),
              bindings.contains(where: {
                  $0.farmID == replacementFarmID &&
                      $0.ownerAccountID == ownerAccountID &&
                      $0.databaseScope == .privateDatabase &&
                      $0.state == .active
              }) else { return false }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let obsoleteAssetDirectory = support.appending(
            path: "MigrationAssets/\(obsoleteFarmID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        guard let legacyFarm = farms.first(where: {
            $0.id == obsoleteFarmID && $0.isLocalOnlyMigration && $0.deletedAt == nil
        }), let legacyCommit = commits.first(where: {
            $0.farmID == obsoleteFarmID &&
                $0.statusRawValue == MigrationCommitStatus.completed.rawValue &&
                $0.cloudStateRawValue == MigrationCloudState.localCommitted.rawValue &&
                !$0.sourceChecksum.isEmpty
        }) else {
            if FileManager.default.fileExists(atPath: obsoleteAssetDirectory.path) {
                try FileManager.default.removeItem(at: obsoleteAssetDirectory)
            }
            return false
        }
        guard legacyFarm.name == replacementFarm.name,
              legacyCommit.sourceChecksum == replacementCommit.sourceChecksum,
              !bindings.contains(where: {
                  $0.farmID == obsoleteFarmID && $0.state == .active
              }) else { return false }

            let farmID = obsoleteFarmID
            try purgeFarmCache(farmID: farmID, context: context)
            for value in try context.fetch(FetchDescriptor<SemenDonorRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<PedigreeChangeRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<DomainOperation>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<OutboxItem>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<TombstoneRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<CloudOperationReceipt>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<SyncConflictRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<CloudAssetTransfer>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<FarmMembershipSnapshotRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<MigrationAuditRecord>()) where value.sessionID == legacyCommit.sessionID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<MigrationCommitRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<CapabilityCertificateRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<CloudFarmBinding>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<CloudRebuildIssueRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<CloudSyncDiagnosticSnapshotRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<FarmCheckpointRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<FarmRecoveryAssetRecord>()) where value.farmID == farmID { context.delete(value) }
            for value in try context.fetch(FetchDescriptor<SecurityIncidentRecord>()) where value.farmID == farmID { context.delete(value) }
        try context.save()
        if FileManager.default.fileExists(atPath: obsoleteAssetDirectory.path) {
            try FileManager.default.removeItem(at: obsoleteAssetDirectory)
        }
        return true
    }

    private func purgeFarmCache(farmID: UUID, context: ModelContext) throws {
        for value in try context.fetch(FetchDescriptor<PenRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SheepRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<WeightRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<TransferRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<DailyPenCountRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedIngredientRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecordLine>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<InventoryTransactionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<ReproductionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SemenRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SemenDonorRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<PedigreeChangeRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<NoteRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<PhotoAssetRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthSubjectLink>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<LambingOffspringRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<CareBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SemenTransactionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmCareRuleRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<CareReminderRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmActivity>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmMembershipBinding>()) where value.farmID == farmID { context.delete(value) }
        if let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) { context.delete(farm) }
    }

    private func purgeConfirmedBusinessCache(farmID: UUID, context: ModelContext) throws {
        for value in try context.fetch(FetchDescriptor<PenRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SheepRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<WeightRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<TransferRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<DailyPenCountRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedIngredientRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedRecordLine>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<InventoryTransactionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<ReproductionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SemenRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SemenDonorRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<PedigreeChangeRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<NoteRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<PhotoAssetRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthSubjectLink>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<LambingOffspringRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<CareBatchRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SemenTransactionRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmCareRuleRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<CareReminderRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmActivity>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<TombstoneRecord>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<CloudOperationReceipt>()) where value.farmID == farmID { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<SyncConflictRecord>()) where value.farmID == farmID {
            // Unresolved/quarantined evidence belongs to retained local
            // Outbox work. Removing it would leave blocked operations without
            // any user-review path after an otherwise successful rebuild.
            if value.statusRawValue != SyncConflictStatus.unresolved.rawValue &&
                value.statusRawValue != SyncConflictStatus.quarantined.rawValue &&
                value.reasonCode != "tombstoneSupersededRemoteAuthority" {
                context.delete(value)
            }
        }
        for value in try context.fetch(FetchDescriptor<CloudAssetTransfer>()) where value.farmID == farmID && value.direction == .download { context.delete(value) }
        for value in try context.fetch(FetchDescriptor<FarmMembershipSnapshotRecord>()) where value.farmID == farmID { context.delete(value) }
    }

    private static func entityDigest(_ operations: [CloudOperationEnvelope]) -> String {
        let text = operations.sorted { $0.operationID.uuidString < $1.operationID.uuidString }.map {
            "\($0.operationID.uuidString.lowercased()):\($0.revision):\($0.payloadDigest)"
        }.joined(separator: "\n")
        return CloudPayloadDigest.hex(for: Data(text.utf8))
    }

    func upsertBinding(farmID: UUID, ownerAccountID: UUID, scope: CloudDatabaseScope, shareRecordName: String?, zoneOwnerName: String = CKCurrentUserDefaultName, state: CloudFarmBindingState) throws {
        let context = ModelContext(container)
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let existingBinding = bindings.first(where: { $0.farmID == farmID })
        guard existingBinding?.state != .rebuildingCache else {
            throw CloudSyncError.inactiveFarm
        }
        let binding = existingBinding ?? CloudFarmBinding(farmID: farmID, ownerAccountID: ownerAccountID, databaseScope: scope)
        let bindingIdentityChanged = existingBinding.map {
            $0.databaseScopeRawValue != scope.rawValue ||
                $0.zoneOwnerName != zoneOwnerName ||
                $0.zoneName != CloudZoneName.forFarm(farmID)
        } ?? true
        if binding.modelContext == nil { context.insert(binding) }
        binding.databaseScopeRawValue = scope.rawValue
        binding.zoneName = CloudZoneName.forFarm(farmID)
        binding.zoneOwnerName = zoneOwnerName
        binding.shareRecordName = shareRecordName
        binding.stateRawValue = state.rawValue
        binding.updatedAt = .now
        if bindingIdentityChanged {
            try requeueConfirmedOutboxWithoutMatchingReceipt(
                farmID: farmID,
                scope: scope,
                zoneName: binding.zoneName,
                zoneOwnerName: binding.zoneOwnerName,
                context: context
            )
        }
        if scope == .privateDatabase,
           let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) {
            farm.ownerAccountID = ownerAccountID
            farm.roleRawValue = FarmRole.owner.rawValue
            farm.membershipStatusRawValue = FarmMembershipStatus.active.rawValue
            farm.updatedAt = .now
            let scopeRawValue = scope.rawValue
            let currentZoneName = binding.zoneName
            let currentZoneOwnerName = binding.zoneOwnerName
            let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>()).filter {
                $0.farmID == farmID &&
                    $0.databaseScopeRawValue == scopeRawValue &&
                    $0.zoneName == currentZoneName &&
                    $0.zoneOwnerName == currentZoneOwnerName
            }
            let confirmed = Set(receipts.map(\.operationID))
            for operation in try context.fetch(FetchDescriptor<DomainOperation>())
            where operation.farmID == farmID && !confirmed.contains(operation.id) {
                operation.accountID = ownerAccountID
            }
        }
        try context.save()
    }

    private func requeueConfirmedOutboxWithoutMatchingReceipt(
        farmID: UUID,
        scope: CloudDatabaseScope,
        zoneName: String,
        zoneOwnerName: String,
        context: ModelContext
    ) throws {
        let confirmed = OutboxStatus.confirmed.rawValue
        let items = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == confirmed
        }))
        guard !items.isEmpty else { return }

        let operations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let scopeRawValue = scope.rawValue
        let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.databaseScopeRawValue == scopeRawValue &&
                $0.zoneName == zoneName &&
                $0.zoneOwnerName == zoneOwnerName
        }))
        for item in items {
            let matchingOperations = operations.filter { $0.id == item.operationID }
            guard matchingOperations.count == 1, let operation = matchingOperations.first else {
                item.statusRawValue = OutboxStatus.pending.rawValue
                item.errorMessage = nil
                item.nextRetryAt = nil
                item.cloudRecordName = nil
                continue
            }
            let confirmedNames = Set(receipts.filter {
                $0.operationID == item.operationID
            }.map(\.recordName))
            guard !requiredReceiptNames(for: operation, in: operations).isSubset(of: confirmedNames) else {
                continue
            }
            item.statusRawValue = OutboxStatus.pending.rawValue
            item.errorMessage = nil
            item.nextRetryAt = nil
            item.cloudRecordName = nil
        }
    }

    func saveCapability(_ response: WorkerCapabilityResponse, accountID: UUID, farmID: UUID, deviceID: UUID) throws {
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        for certificate in existing where certificate.farmID == farmID && certificate.accountID == accountID && certificate.revokedAt == nil {
            certificate.revokedAt = .now
        }
        let capabilitiesData = try JSONEncoder().encode(response.capabilities)
        context.insert(CapabilityCertificateRecord(
            serverCertificateID: response.certificateID,
            accountID: accountID,
            farmID: farmID,
            deviceID: deviceID,
            role: response.role,
            capabilitiesJSON: String(decoding: capabilitiesData, as: UTF8.self),
            certificateJWS: response.certificate,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(response.issuedAt)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAt))
        ))
        if let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farmID }) {
            // Capability refresh can run concurrently with cache recovery.
            // It may update credentials, but only the recovery CAS may remove
            // a rebuilding lock or its engine-reset claim.
            if binding.state != .rebuildingCache {
                if binding.databaseScope == .privateDatabase && response.role == .owner {
                    binding.stateRawValue = CloudFarmBindingState.active.rawValue
                } else {
                    binding.stateRawValue = CloudFarmBindingState.requiresAccountReview.rawValue
                }
            }
            binding.updatedAt = .now
        }
        if let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) {
            farm.roleRawValue = response.role.rawValue
            farm.membershipStatusRawValue = response.role == .owner ? FarmMembershipStatus.active.rawValue : FarmMembershipStatus.pendingOwnerConfirmation.rawValue
            farm.updatedAt = .now
        }
        // A provisioning attempt may ask CKSyncEngine for a record just before
        // the first capability is persisted. Only that explicit, locally
        // generated rejection is recoverable here; genuine CloudKit permission
        // failures remain blocked for user review.
        for item in try context.fetch(FetchDescriptor<OutboxItem>())
        where item.farmID == farmID &&
              item.status == .rejectedPermission &&
              item.errorMessage == "没有当前牧场可用的能力证书。" {
            item.statusRawValue = OutboxStatus.pending.rawValue
            item.errorMessage = nil
            item.nextRetryAt = nil
        }
        try Self.activateSharedFarmIfFullyVerified(farmID: farmID, accountID: accountID, context: context)
        try context.save()
    }

    func hasUsableCapability(
        accountID: UUID,
        farmID: UUID,
        deviceID: UUID,
        minimumRemaining: TimeInterval = 3_600
    ) throws -> Bool {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<CapabilityCertificateRecord>()).contains {
            $0.accountID == accountID &&
            $0.farmID == farmID &&
            $0.deviceID == deviceID &&
            $0.revokedAt == nil &&
            $0.remainingTime > minimumRemaining
        }
    }

    @discardableResult
    func requeueBlockedConflicts(farmID: UUID) throws -> Int {
        let context = ModelContext(container)
        let blocked = OutboxStatus.blockedConflict.rawValue
        let items = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == blocked
        })).filter {
            // New builds prefix a real payload conflict explicitly. Only
            // legacy ambiguous failures and the old mutable-projection insert
            // bug are eligible for one-time recheck. If the server revision is
            // genuinely incompatible, the new failure handler replaces this
            // transport text with an explicit operation-lineage conflict and
            // it will not be requeued again.
            CloudBlockedConflictRecovery.isEligible($0.errorMessage)
        }
        for item in items {
            item.statusRawValue = OutboxStatus.pending.rawValue
            item.errorMessage = nil
            item.nextRetryAt = nil
        }
        if !items.isEmpty { try context.save() }
        return items.count
    }

    func tombstoneConflictCandidates(farmID: UUID) throws -> [CloudTombstoneConflictCandidate] {
        let context = ModelContext(container)
        let active = CloudFarmBindingState.active.rawValue
        var bindingDescriptor = FetchDescriptor<CloudFarmBinding>(predicate: #Predicate {
            $0.farmID == farmID && $0.stateRawValue == active
        })
        bindingDescriptor.fetchLimit = 2
        let bindings = try context.fetch(bindingDescriptor)
        guard bindings.count == 1, let binding = bindings.first else {
            throw CloudSyncError.farmBindingMissing
        }

        let blocked = OutboxStatus.blockedConflict.rawValue
        let iCloud = FarmRemoteProvider.iCloud.rawValue
        let items = try context.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == blocked
        })).filter {
            $0.deliveryProviderRawValue == nil || $0.deliveryProviderRawValue == iCloud
        }
        let allOperations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let allTombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let tombstoneOperationIDs = Set(allOperations.filter {
            $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue
        }.map(\.id))
        let expectedCandidateCount = items.count {
            tombstoneOperationIDs.contains($0.operationID)
        }

        var result: [CloudTombstoneConflictCandidate] = []
        for item in items {
            let matchingOperations = allOperations.filter { $0.id == item.operationID }
            guard matchingOperations.count == 1,
                  let operation = matchingOperations.first,
                  operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
                  let entityID = operation.entityID,
                  operation.entityID == item.entityID,
                  operation.entityType == item.entityType,
                  operation.payloadDigest == item.payloadDigest,
                  operation.baseRevision == item.baseRevision,
                  let deviceID = operation.modifiedByDeviceID,
                  let signature = operation.operationSignature else {
                continue
            }
            let matchingTombstones = allTombstones.filter {
                $0.operationID == operation.id &&
                    $0.entityID == entityID &&
                    $0.entityType == operation.entityType
            }
            guard matchingTombstones.count == 1, let tombstone = matchingTombstones.first else {
                continue
            }
            let localOperation = CloudOperationEnvelope(
                farmID: operation.farmID,
                entityID: entityID,
                entityType: operation.entityType,
                schemaVersion: operation.schemaVersion,
                revision: operation.resultingRevision,
                baseRevision: operation.baseRevision,
                operationID: operation.id,
                modifiedAt: operation.occurredAt,
                modifiedByAccountID: operation.accountID,
                modifiedByDeviceID: deviceID,
                payload: operation.payload,
                payloadDigest: operation.payloadDigest,
                capabilityCertificate: operation.capabilityCertificate,
                operationSignature: signature,
                deletedAt: tombstone.deletedAt
            )
            let localTombstone = FarmTombstoneEnvelope(
                tombstoneID: tombstone.id,
                farmID: tombstone.farmID,
                entityType: tombstone.entityType,
                entityID: tombstone.entityID,
                revision: tombstone.revision,
                deletedAt: tombstone.deletedAt,
                deletedByAccountID: tombstone.deletedByAccountID,
                reason: tombstone.reason,
                operationID: operation.id,
                restoresTombstoneID: tombstone.restoredByOperationID
            )
            result.append(CloudTombstoneConflictCandidate(
                outboxID: item.id,
                farmID: farmID,
                scope: binding.databaseScope,
                zoneName: binding.zoneName,
                zoneOwnerName: binding.zoneOwnerName,
                localOperation: localOperation,
                localTombstone: localTombstone
            ))
        }
        guard result.count == expectedCandidateCount else {
            throw CloudSyncError.recoveryCatchUpFailed(
                "本机 Tombstone 阻塞项缺少唯一 Operation、Tombstone、签名或 Outbox 证据，已停止自动修复。"
            )
        }
        return result.sorted { $0.localOperation.modifiedAt < $1.localOperation.modifiedAt }
    }

    /// A cleanly restored device has no Outbox rows, but can still retain two
    /// local Tombstone projections for the same entity/revision after an old
    /// client raced two deletion facts. Limit projection repair to that exact
    /// duplicate shape; different revisions can represent legitimate history.
    func tombstoneAuthorityProjectionCandidates(
        farmID: UUID
    ) throws -> [CloudTombstoneConflictCandidate] {
        let context = ModelContext(container)
        let active = CloudFarmBindingState.active.rawValue
        var bindingDescriptor = FetchDescriptor<CloudFarmBinding>(predicate: #Predicate {
            $0.farmID == farmID && $0.stateRawValue == active
        })
        bindingDescriptor.fetchLimit = 2
        let bindings = try context.fetch(bindingDescriptor)
        guard bindings.count == 1, let binding = bindings.first else {
            throw CloudSyncError.farmBindingMissing
        }
        let operations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).filter { $0.restoredAt == nil }
        let grouped = Dictionary(grouping: tombstones) {
            "\($0.entityID.uuidString.lowercased())|\($0.revision)"
        }
        let duplicates: [TombstoneRecord] = grouped.values
            .filter { group in
                group.count > 1 && Set(group.map(\.operationID)).count > 1
            }
            .flatMap { $0 }

        var result: [CloudTombstoneConflictCandidate] = []
        for tombstone in duplicates {
            let matching = operations.filter {
                $0.id == tombstone.operationID &&
                    $0.entityID == tombstone.entityID &&
                    $0.entityType == tombstone.entityType &&
                    $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue
            }
            guard matching.count == 1, let operation = matching.first,
                  let deviceID = operation.modifiedByDeviceID,
                  let signature = operation.operationSignature,
                  !operation.capabilityCertificate.isEmpty else {
                throw CloudSyncError.recoveryCatchUpFailed(
                    "重复 Tombstone 投影缺少唯一、已签名的本地 Operation，已停止自动核对。"
                )
            }
            let localOperation = CloudOperationEnvelope(
                farmID: operation.farmID,
                entityID: tombstone.entityID,
                entityType: operation.entityType,
                schemaVersion: operation.schemaVersion,
                revision: operation.resultingRevision,
                baseRevision: operation.baseRevision,
                operationID: operation.id,
                modifiedAt: operation.occurredAt,
                modifiedByAccountID: operation.accountID,
                modifiedByDeviceID: deviceID,
                payload: operation.payload,
                payloadDigest: operation.payloadDigest,
                capabilityCertificate: operation.capabilityCertificate,
                operationSignature: signature,
                deletedAt: tombstone.deletedAt
            )
            let localTombstone = FarmTombstoneEnvelope(
                tombstoneID: tombstone.id,
                farmID: tombstone.farmID,
                entityType: tombstone.entityType,
                entityID: tombstone.entityID,
                revision: tombstone.revision,
                deletedAt: tombstone.deletedAt,
                deletedByAccountID: tombstone.deletedByAccountID,
                reason: tombstone.reason,
                operationID: operation.id,
                restoresTombstoneID: tombstone.restoredByOperationID
            )
            result.append(CloudTombstoneConflictCandidate(
                outboxID: nil,
                farmID: farmID,
                scope: binding.databaseScope,
                zoneName: binding.zoneName,
                zoneOwnerName: binding.zoneOwnerName,
                localOperation: localOperation,
                localTombstone: localTombstone
            ))
        }
        return result.sorted {
            if $0.localOperation.entityID != $1.localOperation.entityID {
                return $0.localOperation.entityID.uuidString < $1.localOperation.entityID.uuidString
            }
            return $0.localOperation.modifiedAt < $1.localOperation.modifiedAt
        }
    }

    func applyTombstoneReconciliation(
        candidate: CloudTombstoneConflictCandidate,
        evidence: CloudTombstoneRemoteEvidence
    ) async throws -> CloudTombstoneReconciliationItem {
        let decision = CloudTombstoneEvidenceEvaluator.evaluate(
            candidate: candidate,
            evidence: evidence,
            mapper: mapper
        )
        switch decision {
        case .unresolved(let detail):
            return CloudTombstoneReconciliationItem(
                operationID: candidate.localOperation.operationID,
                entityID: candidate.localOperation.entityID,
                outcome: .unresolvedDivergence,
                detail: detail
            )

        case .equivalent(let operationRecord, let tombstoneRecord):
            let envelope = try validatedTombstoneOperationRecord(
                operationRecord,
                candidate: candidate
            )
            guard CloudTombstoneEvidenceEvaluator.operationsHaveSameImmutableFact(
                envelope,
                candidate.localOperation
            ) else {
                return CloudTombstoneReconciliationItem(
                    operationID: candidate.localOperation.operationID,
                    entityID: candidate.localOperation.entityID,
                    outcome: .unresolvedDivergence,
                    detail: "云端操作通过签名验证，但不可变内容与本机不同。"
                )
            }
            try adoptValidatedRemoteOperationAuthorization(
                envelope,
                candidate: candidate
            )
            if candidate.outboxID == nil {
                try normalizeTombstoneAuthorityProjection(
                    candidate: candidate,
                    authoritativeEnvelope: envelope,
                    tombstoneRecord: tombstoneRecord
                )
                return CloudTombstoneReconciliationItem(
                    operationID: candidate.localOperation.operationID,
                    entityID: candidate.localOperation.entityID,
                    outcome: .equivalentConfirmed,
                    detail: "本地 Tombstone 投影已与通过验证的 CloudKit 权威保持一致。"
                )
            }
            try confirmSavedRecords([operationRecord, tombstoneRecord], scope: candidate.scope)
            return CloudTombstoneReconciliationItem(
                operationID: candidate.localOperation.operationID,
                entityID: candidate.localOperation.entityID,
                outcome: .equivalentConfirmed,
                detail: "Operation 与 Tombstone 均已由 CloudKit 证实，Entity 投影不再阻塞交付。"
            )

        case .retryOperation(let tombstoneRecord):
            try validateTombstoneEnvelopeAuthorization(
                candidate.localOperation,
                authorizationDate: tombstoneRecord.modificationDate ?? tombstoneRecord.creationDate
            )
            // The missing immutable Operation must be retried byte-for-byte
            // with its original authorization. If that authorization has
            // expired, keep the conflict unresolved instead of re-signing an
            // operation that the existing Tombstone no longer proves.
            try validateTombstoneEnvelopeAuthorization(
                candidate.localOperation,
                authorizationDate: .now
            )
            try confirmSavedRecords([tombstoneRecord], scope: candidate.scope)
            return CloudTombstoneReconciliationItem(
                operationID: candidate.localOperation.operationID,
                entityID: candidate.localOperation.entityID,
                outcome: .operationRetryNeeded,
                detail: "Tombstone 已确认；只保留缺失的不可变 Operation 待重传。"
            )

        case .superseded(let operationRecord, let tombstoneRecord, let envelope):
            let validated = try validatedTombstoneOperationRecord(
                operationRecord,
                candidate: candidate,
                expectedOperationID: envelope.operationID
            )
            guard validated == envelope else {
                return CloudTombstoneReconciliationItem(
                    operationID: candidate.localOperation.operationID,
                    entityID: candidate.localOperation.entityID,
                    outcome: .unresolvedDivergence,
                    detail: "云端权威操作在安全验证前后内容不一致。"
                )
            }
            if candidate.outboxID == nil {
                try normalizeTombstoneAuthorityProjection(
                    candidate: candidate,
                    authoritativeEnvelope: validated,
                    tombstoneRecord: tombstoneRecord
                )
                return CloudTombstoneReconciliationItem(
                    operationID: candidate.localOperation.operationID,
                    entityID: candidate.localOperation.entityID,
                    outcome: .supersededByRemote,
                    detail: "本地重复 Tombstone 已采用同实体、同 revision 的已验证 CloudKit 权威；历史 Operation 保持不变。"
                )
            }
            try markTombstoneOperationSuperseded(
                candidate: candidate,
                authoritativeEnvelope: validated,
                operationRecord: operationRecord,
                tombstoneRecord: tombstoneRecord
            )
            return CloudTombstoneReconciliationItem(
                operationID: candidate.localOperation.operationID,
                entityID: candidate.localOperation.entityID,
                outcome: .supersededByRemote,
                detail: "已采用同一实体、同一 revision 的已验证云端删除事实；本机操作保留为审计证据。"
            )
        }
    }

    func validateTombstoneCredentialRepairAuthority(
        _ record: CKRecord,
        candidate: CloudTombstoneConflictCandidate,
        expectedOperationID: UUID
    ) throws {
        _ = try validatedTombstoneOperationRecord(
            record,
            candidate: candidate,
            expectedOperationID: expectedOperationID
        )
    }

    private func adoptValidatedRemoteOperationAuthorization(
        _ envelope: CloudOperationEnvelope,
        candidate: CloudTombstoneConflictCandidate
    ) throws {
        let context = ModelContext(container)
        let operationID = candidate.localOperation.operationID
        let farmID = candidate.farmID
        var operationDescriptor = FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.id == operationID && $0.farmID == farmID
        })
        operationDescriptor.fetchLimit = 2
        var outboxDescriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.operationID == operationID && $0.farmID == farmID
        })
        outboxDescriptor.fetchLimit = 2
        let operations = try context.fetch(operationDescriptor)
        let items = try context.fetch(outboxDescriptor)
        guard operations.count == 1, let operation = operations.first,
              let entityID = operation.entityID else {
            throw CloudContractError.malformedRecord
        }
        if let expectedOutboxID = candidate.outboxID,
           (items.count != 1 || items.first?.id != expectedOutboxID) {
            throw CloudContractError.malformedRecord
        }
        let local = CloudOperationEnvelope(
            farmID: operation.farmID,
            entityID: entityID,
            entityType: operation.entityType,
            schemaVersion: operation.schemaVersion,
            revision: operation.resultingRevision,
            baseRevision: operation.baseRevision,
            operationID: operation.id,
            modifiedAt: operation.occurredAt,
            modifiedByAccountID: operation.accountID,
            modifiedByDeviceID: operation.modifiedByDeviceID ?? envelope.modifiedByDeviceID,
            payload: operation.payload,
            payloadDigest: operation.payloadDigest,
            capabilityCertificate: operation.capabilityCertificate,
            operationSignature: operation.operationSignature ?? Data(),
            deletedAt: candidate.localTombstone.deletedAt
        )
        guard CloudTombstoneEvidenceEvaluator.operationsHaveSameImmutableFact(envelope, local) else {
            throw CloudContractError.malformedRecord
        }
        operation.modifiedByDeviceID = envelope.modifiedByDeviceID
        operation.capabilityCertificate = envelope.capabilityCertificate
        operation.operationSignature = envelope.operationSignature
        for item in items {
            item.capabilityCertificate = envelope.capabilityCertificate
            item.operationSignature = envelope.operationSignature
            item.errorMessage = nil
        }
        try context.save()
    }

    private func normalizeTombstoneAuthorityProjection(
        candidate: CloudTombstoneConflictCandidate,
        authoritativeEnvelope: CloudOperationEnvelope,
        tombstoneRecord: CKRecord
    ) throws {
        let context = ModelContext(container)
        let tombstoneID = candidate.localTombstone.tombstoneID
        let farmID = candidate.farmID
        var descriptor = FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
            $0.id == tombstoneID && $0.farmID == farmID
        })
        descriptor.fetchLimit = 2
        let records = try context.fetch(descriptor)
        guard records.count == 1, let local = records.first else {
            throw CloudContractError.malformedRecord
        }
        let remote = try mapper.tombstoneEnvelope(from: tombstoneRecord)
        guard remote.farmID == candidate.farmID,
              remote.entityID == candidate.localOperation.entityID,
              remote.entityType == candidate.localOperation.entityType,
              remote.revision == candidate.localOperation.revision,
              remote.operationID == authoritativeEnvelope.operationID else {
            throw CloudContractError.malformedRecord
        }
        local.operationID = authoritativeEnvelope.operationID
        local.revision = remote.revision
        local.deletedAt = remote.deletedAt
        local.deletedByAccountID = remote.deletedByAccountID
        local.reason = remote.reason
        try context.save()
    }

    private func validatedTombstoneOperationRecord(
        _ record: CKRecord,
        candidate: CloudTombstoneConflictCandidate,
        expectedOperationID: UUID? = nil
    ) throws -> CloudOperationEnvelope {
        let context = ModelContext(container)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard record.recordType == CloudRecordType.farmOperation.rawValue,
              record.recordID.zoneID == candidate.zoneID,
              let binding = try activeBinding(
                matching: record.recordID.zoneID,
                scope: candidate.scope,
                context: context
              ),
              binding.farmID == candidate.farmID else {
            throw CloudContractError.malformedRecord
        }
        let envelope = try mapper.operationEnvelope(from: record)
        guard envelope.farmID == candidate.farmID,
              envelope.operationID == (expectedOperationID ?? candidate.localOperation.operationID),
              record.recordID.recordName == mapper.recordName(for: envelope.operationID),
              CloudZoneName.farmID(from: record.recordID.zoneID.zoneName) == envelope.farmID,
              let payload = try? decoder.decode(FarmCommandCloudPayload.self, from: envelope.payload),
              payload.kind == .tombstoneEntity else {
            throw CloudContractError.malformedRecord
        }
        try validateTombstoneEnvelopeAuthorization(
            envelope,
            authorizationDate: record.modificationDate ?? record.creationDate
        )
        return envelope
    }

    private func validateTombstoneEnvelopeAuthorization(
        _ envelope: CloudOperationEnvelope,
        authorizationDate: Date?
    ) throws {
        let context = ModelContext(container)
        guard let publicKey = capabilitySigningPublicKeyPEM, !publicKey.isEmpty else {
            throw CloudContractError.invalidCertificate
        }
        let claims = try CapabilityCertificateVerifier.verify(
            envelope.capabilityCertificate,
            publicKeyPEM: publicKey
        )
        let revoked = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        guard !revoked.contains(where: {
            $0.farmID == envelope.farmID && $0.serverCertificateID == claims.certificateID
        }) else {
            throw CloudContractError.invalidCertificate
        }
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        guard let device = devices.first(where: {
            $0.id == claims.deviceID && $0.accountID == claims.accountID
        }) else {
            throw CloudContractError.invalidDeviceSignature
        }
        try CloudOperationSecurity.validate(
            envelope: envelope,
            claims: claims,
            devicePublicKeyX963: device.publicKeyX963,
            authorizationDate: authorizationDate
        )
    }

    private func markTombstoneOperationSuperseded(
        candidate: CloudTombstoneConflictCandidate,
        authoritativeEnvelope: CloudOperationEnvelope,
        operationRecord: CKRecord,
        tombstoneRecord: CKRecord
    ) throws {
        let context = ModelContext(container)
        guard let candidateOutboxID = candidate.outboxID else {
            throw CloudContractError.malformedRecord
        }
        let candidateFarmID = candidate.farmID
        var itemDescriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.id == candidateOutboxID && $0.farmID == candidateFarmID
        })
        itemDescriptor.fetchLimit = 2
        let items = try context.fetch(itemDescriptor)
        guard items.count == 1, let item = items.first,
              item.operationID == candidate.localOperation.operationID else {
            throw CloudContractError.malformedRecord
        }

        _ = try RemoteDomainAuditProjection.insertIfNeeded(authoritativeEnvelope, context: context)
        let authoritativeTombstone = try mapper.tombstoneEnvelope(from: tombstoneRecord)
        let localOperationID = candidate.localOperation.operationID
        let localTombstones = try context.fetch(FetchDescriptor<TombstoneRecord>()).filter {
            $0.farmID == candidate.farmID &&
                $0.operationID == localOperationID &&
                $0.entityID == candidate.localOperation.entityID
        }
        guard localTombstones.count == 1, let localTombstone = localTombstones.first else {
            throw CloudContractError.malformedRecord
        }
        // Preserve a single business Tombstone for this entity, but point its
        // authority and semantic fields at the verified remote deletion. The
        // original local operation remains in history, conflict evidence and
        // the Outbox receipt archive.
        localTombstone.operationID = authoritativeEnvelope.operationID
        localTombstone.revision = authoritativeTombstone.revision
        localTombstone.deletedAt = authoritativeTombstone.deletedAt
        localTombstone.deletedByAccountID = authoritativeTombstone.deletedByAccountID
        localTombstone.reason = authoritativeTombstone.reason
        let receiptExists = try context.fetch(FetchDescriptor<CloudOperationReceipt>()).contains {
            $0.farmID == candidate.farmID &&
                $0.operationID == authoritativeEnvelope.operationID &&
                $0.recordName == operationRecord.recordID.recordName &&
                $0.databaseScopeRawValue == candidate.scope.rawValue &&
                $0.zoneName == candidate.zoneName &&
                $0.zoneOwnerName == candidate.zoneOwnerName
        }
        if !receiptExists {
            context.insert(CloudOperationReceipt(
                farmID: candidate.farmID,
                operationID: authoritativeEnvelope.operationID,
                recordName: operationRecord.recordID.recordName,
                serverChangeTag: operationRecord.recordChangeTag,
                databaseScope: candidate.scope,
                zoneName: candidate.zoneName,
                zoneOwnerName: candidate.zoneOwnerName
            ))
        }
        let tombstoneReceiptExists = try context.fetch(FetchDescriptor<CloudOperationReceipt>()).contains {
            $0.farmID == candidate.farmID &&
                $0.operationID == authoritativeEnvelope.operationID &&
                $0.recordName == tombstoneRecord.recordID.recordName &&
                $0.databaseScopeRawValue == candidate.scope.rawValue &&
                $0.zoneName == candidate.zoneName &&
                $0.zoneOwnerName == candidate.zoneOwnerName
        }
        if !tombstoneReceiptExists {
            context.insert(CloudOperationReceipt(
                farmID: candidate.farmID,
                operationID: authoritativeEnvelope.operationID,
                recordName: tombstoneRecord.recordID.recordName,
                serverChangeTag: tombstoneRecord.recordChangeTag,
                databaseScope: candidate.scope,
                zoneName: candidate.zoneName,
                zoneOwnerName: candidate.zoneOwnerName
            ))
        }

        let reasonCode = "tombstoneSupersededRemoteAuthority"
        let conflicts = try context.fetch(FetchDescriptor<SyncConflictRecord>()).filter {
            $0.farmID == candidate.farmID &&
                $0.entityID == candidate.localOperation.entityID &&
                $0.reasonCode == reasonCode &&
                $0.localPayloadDigest == candidate.localOperation.payloadDigest &&
                $0.remotePayloadDigest == authoritativeEnvelope.payloadDigest
        }
        let conflict: SyncConflictRecord
        if let existing = conflicts.first {
            conflict = existing
        } else {
            conflict = SyncConflictRecord(
                farmID: candidate.farmID,
                entityID: candidate.localOperation.entityID,
                entityType: candidate.localOperation.entityType,
                localRevision: candidate.localOperation.revision,
                remoteRevision: authoritativeEnvelope.revision,
                localPayload: candidate.localOperation.payload,
                remotePayload: authoritativeEnvelope.payload,
                remoteAccountID: authoritativeEnvelope.modifiedByAccountID,
                remoteDeviceID: authoritativeEnvelope.modifiedByDeviceID,
                reasonCode: reasonCode,
                status: .acceptedRemote
            )
            context.insert(conflict)
        }
        conflict.statusRawValue = SyncConflictStatus.acceptedRemote.rawValue
        conflict.resolvedAt = conflict.resolvedAt ?? .now
        conflict.resolutionNote = "CloudKit 已存在另一条通过签名验证的同 revision 删除事实；本机操作保留但停止交付。"
        conflict.remoteEnvelopeData = try JSONEncoder.cloud.encode(authoritativeEnvelope)
        conflict.remoteAccountID = authoritativeEnvelope.modifiedByAccountID
        conflict.remoteDeviceID = authoritativeEnvelope.modifiedByDeviceID

        item.statusRawValue = OutboxStatus.supersededRemoteAuthority.rawValue
        item.errorMessage = nil
        item.nextRetryAt = nil
        item.cloudRecordName = operationRecord.recordID.recordName
        item.remoteReceiptData = try JSONEncoder.cloud.encode(CloudTombstoneSupersessionReceipt(
            localOperationID: candidate.localOperation.operationID,
            authoritativeOperation: authoritativeEnvelope,
            operationRecordName: operationRecord.recordID.recordName,
            tombstoneRecordName: tombstoneRecord.recordID.recordName,
            zoneName: candidate.zoneName,
            zoneOwnerName: candidate.zoneOwnerName,
            databaseScope: candidate.scope,
            reconciledAt: .now
        ))
        try FarmHistoryRebuilder().rebuild(farmID: candidate.farmID, context: context, from: .distantPast)
        try context.save()
    }

    @discardableResult
    func purgeLegacyCertificateTimestampIncidents() throws -> Int {
        let context = ModelContext(container)
        let legacyType = "malformedCloudOperation"
        let legacyDetail = CloudContractError.expiredCertificate.localizedDescription
        let incidents = try context.fetch(FetchDescriptor<SecurityIncidentRecord>()).filter {
            $0.incidentType == legacyType && $0.detail == legacyDetail
        }
        for incident in incidents { context.delete(incident) }
        if !incidents.isEmpty { try context.save() }
        return incidents.count
    }

    func saveSecuritySnapshot(_ snapshot: WorkerFarmSecuritySnapshot) throws {
        let context = ModelContext(container)
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        let validatedDevices = try snapshot.devices.map { device -> (WorkerFarmSecuritySnapshot.Device, Data) in
            guard let publicKey = Self.x963PublicKey(fromJWKJSON: device.publicKeyJWK) else {
                throw CloudContractError.invalidDeviceSignature
            }
            if let existing = devices.first(where: { $0.id == device.deviceID }),
               (existing.accountID != device.accountID || existing.publicKeyX963 != publicKey) {
                // Device IDs are immutable identities. A rotated key must be
                // registered under a new device ID instead of replacing a
                // trusted key during recovery.
                throw CloudContractError.invalidDeviceSignature
            }
            return (device, publicKey)
        }
        let memberships = try context.fetch(FetchDescriptor<FarmMembershipBinding>())
        for member in snapshot.members {
            let status: FarmMembershipStatus = switch member.status {
            case "active": .active
            case "pending": .pendingOwnerConfirmation
            case "revoked": .revoked
            default: .pendingInvite
            }
            if let existing = memberships.first(where: { $0.serverMembershipID == member.membershipID }) {
                existing.displayName = member.displayName
                existing.roleRawValue = member.role.rawValue
                existing.statusRawValue = status.rawValue
                existing.shareParticipantRecordName = member.shareParticipantRecordName
                existing.updatedAt = .now
            } else {
                let binding = FarmMembershipBinding(
                    serverMembershipID: member.membershipID,
                    farmID: snapshot.farmID,
                    accountID: member.accountID,
                    displayName: member.displayName,
                    role: member.role,
                    status: status
                )
                binding.shareParticipantRecordName = member.shareParticipantRecordName
                context.insert(binding)
            }
        }
        if let owner = snapshot.members.first(where: { $0.role == .owner }),
           let cloudBinding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == snapshot.farmID }) {
            cloudBinding.ownerAccountID = owner.accountID
            cloudBinding.securityGeneration = max(cloudBinding.securityGeneration, snapshot.generation)
            cloudBinding.updatedAt = .now
        }
        if let localAccountID = try context.fetch(FetchDescriptor<AccountProfile>()).first?.effectiveAccountID,
           let localMember = snapshot.members.first(where: { $0.accountID == localAccountID }),
           let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == snapshot.farmID }) {
            farm.roleRawValue = localMember.role.rawValue
            farm.membershipStatusRawValue = localMember.status
            farm.updatedAt = .now
        }
        for (device, publicKey) in validatedDevices {
            if let existing = devices.first(where: { $0.id == device.deviceID }) {
                existing.publicKeyX963 = publicKey
                existing.isRegistered = true
                existing.lastRegisteredAt = .now
            } else {
                let record = DeviceIdentityRecord(id: device.deviceID, accountID: device.accountID, publicKeyX963: publicKey, usesSecureEnclave: false)
                record.isRegistered = true
                record.lastRegisteredAt = .now
                context.insert(record)
            }
        }
        let revoked = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        let localCertificates = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        for item in snapshot.revokedCertificates {
            let revokedAt = Date(timeIntervalSince1970: TimeInterval(item.revokedAt))
            if !revoked.contains(where: { $0.serverCertificateID == item.certificateID }) {
                context.insert(RevokedCapabilityCertificateRecord(
                    serverCertificateID: item.certificateID,
                    farmID: snapshot.farmID,
                    revokedAt: revokedAt
                ))
            }
            if let local = localCertificates.first(where: { $0.serverCertificateID == item.certificateID }) {
                local.revokedAt = revokedAt
            }
        }
        try context.save()
    }

    func lockAllCloudFarmsForAccountReview() throws {
        let context = ModelContext(container)
        for binding in try context.fetch(FetchDescriptor<CloudFarmBinding>()) where binding.state != .accessRevoked {
            binding.stateRawValue = CloudFarmBindingState.requiresAccountReview.rawValue
            binding.lastErrorCode = "cloudAccountChanged"
            binding.updatedAt = .now
        }
        for item in try context.fetch(FetchDescriptor<OutboxItem>()) where item.status == .uploading || item.status == .awaitingConfirmation {
            item.statusRawValue = OutboxStatus.pending.rawValue
            item.errorMessage = "iCloud 账号发生变化，等待重新验证。"
        }
        try context.save()
    }

    func saveMembershipSnapshotRecord(_ value: MembershipSnapshotRecordValue) throws {
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<FarmMembershipSnapshotRecord>()).filter { $0.farmID == value.farmID }
        guard existing.allSatisfy({ $0.generation <= value.generation }) else {
            throw CloudContractError.membershipSnapshotRollback
        }
        if let same = existing.first(where: { $0.generation == value.generation }) {
            guard value.issuedAt >= same.issuedAt else {
                throw CloudContractError.membershipSnapshotRollback
            }
            if value.payload != same.payload {
                guard value.issuedAt > same.issuedAt,
                      let oldEnvelope = try? JSONDecoder.membershipPersistence.decode(
                          FarmMembershipSnapshotEnvelope.self,
                          from: same.payload
                      ),
                      let newEnvelope = try? JSONDecoder.membershipPersistence.decode(
                          FarmMembershipSnapshotEnvelope.self,
                          from: value.payload
                      ),
                      oldEnvelope.farmID == newEnvelope.farmID,
                      oldEnvelope.generation == newEnvelope.generation,
                      oldEnvelope.members.count == newEnvelope.members.count,
                      oldEnvelope.members.allSatisfy(newEnvelope.members.contains),
                      oldEnvelope.devices.allSatisfy(newEnvelope.devices.contains),
                      oldEnvelope.revokedCertificates.allSatisfy(newEnvelope.revokedCertificates.contains) else {
                    throw CloudContractError.membershipSnapshotRollback
                }
                // CloudBase 0.3.x historically did not bump generation for a
                // newly registered device. Accept only an owner-signed,
                // strictly newer, additive trust update at the same generation;
                // membership changes, key replacement, and revocation rollback
                // remain forbidden.
                same.issuedAt = value.issuedAt
                same.payload = value.payload
                same.payloadDigest = CloudPayloadDigest.hex(for: value.payload)
                same.signedByAccountID = value.signedByAccountID
                same.signedByDeviceID = value.signedByDeviceID
                same.capabilityCertificate = value.capabilityCertificate
                same.signature = value.signature
            }
            same.cloudRecordName = value.cloudRecordName ?? same.cloudRecordName
            same.validatedAt = value.validatedAt ?? same.validatedAt
            if let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == value.farmID }) {
                binding.securityGeneration = max(binding.securityGeneration, value.generation)
                binding.lastMembershipSnapshotAt = max(binding.lastMembershipSnapshotAt ?? .distantPast, value.issuedAt)
                binding.updatedAt = .now
            }
            if let accountID = try context.fetch(FetchDescriptor<AccountProfile>()).first?.effectiveAccountID {
                try Self.activateSharedFarmIfFullyVerified(farmID: value.farmID, accountID: accountID, context: context)
            }
            try context.save()
            return
        }
        for old in existing where old.generation < value.generation { context.delete(old) }
        let record = FarmMembershipSnapshotRecord(
            id: value.id,
            farmID: value.farmID,
            generation: value.generation,
            issuedAt: value.issuedAt,
            payload: value.payload,
            signedByAccountID: value.signedByAccountID,
            signedByDeviceID: value.signedByDeviceID,
            capabilityCertificate: value.capabilityCertificate,
            signature: value.signature
        )
        record.cloudRecordName = value.cloudRecordName
        record.validatedAt = value.validatedAt
        context.insert(record)
        if let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == value.farmID }) {
            binding.securityGeneration = value.generation
            binding.lastMembershipSnapshotAt = value.issuedAt
            binding.updatedAt = .now
        }
        if let accountID = try context.fetch(FetchDescriptor<AccountProfile>()).first?.effectiveAccountID {
            try Self.activateSharedFarmIfFullyVerified(farmID: value.farmID, accountID: accountID, context: context)
        }
        try context.save()
    }

    /// Persists keys and revocations only after MembershipSnapshotActor has
    /// authenticated the snapshot with an already trusted owner device.
    func saveValidatedMembershipSnapshotRecord(
        _ value: MembershipSnapshotRecordValue,
        envelope: FarmMembershipSnapshotEnvelope
    ) throws {
        guard envelope.farmID == value.farmID,
              envelope.generation == value.generation else {
            throw CloudContractError.malformedRecord
        }

        let validationContext = ModelContext(container)
        let existingDevices = try validationContext.fetch(FetchDescriptor<DeviceIdentityRecord>())
        for device in envelope.devices {
            guard let publicKey = Self.x963PublicKey(fromJWKJSON: device.publicKeyJWK) else {
                throw CloudContractError.invalidDeviceSignature
            }
            if let existing = existingDevices.first(where: { $0.id == device.deviceID }),
               (existing.accountID != device.accountID || existing.publicKeyX963 != publicKey) {
                // A stable device identifier may never silently change owner
                // or key through a membership snapshot.
                throw CloudContractError.invalidDeviceSignature
            }
        }

        try saveMembershipSnapshotRecord(value)

        let context = ModelContext(container)
        let devices = try context.fetch(FetchDescriptor<DeviceIdentityRecord>())
        for device in envelope.devices {
            guard let publicKey = Self.x963PublicKey(fromJWKJSON: device.publicKeyJWK) else {
                throw CloudContractError.invalidDeviceSignature
            }
            if let existing = devices.first(where: { $0.id == device.deviceID }) {
                existing.isRegistered = true
                existing.lastRegisteredAt = .now
            } else {
                let record = DeviceIdentityRecord(
                    id: device.deviceID,
                    accountID: device.accountID,
                    publicKeyX963: publicKey,
                    usesSecureEnclave: false
                )
                record.isRegistered = true
                record.lastRegisteredAt = .now
                context.insert(record)
            }
        }
        let revoked = try context.fetch(FetchDescriptor<RevokedCapabilityCertificateRecord>())
        let certificates = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        for item in envelope.revokedCertificates {
            let revokedAt = Date(timeIntervalSince1970: TimeInterval(item.revokedAt))
            if !revoked.contains(where: {
                $0.farmID == envelope.farmID &&
                    $0.serverCertificateID == item.certificateID
            }) {
                context.insert(RevokedCapabilityCertificateRecord(
                    serverCertificateID: item.certificateID,
                    farmID: envelope.farmID,
                    revokedAt: revokedAt
                ))
            }
            if let certificate = certificates.first(where: {
                $0.farmID == envelope.farmID &&
                    $0.serverCertificateID == item.certificateID
            }) {
                certificate.revokedAt = revokedAt
            }
        }
        try context.save()
    }

    private static func activateSharedFarmIfFullyVerified(farmID: UUID, accountID: UUID, context: ModelContext) throws {
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: {
            $0.farmID == farmID &&
                $0.databaseScope == .sharedDatabase &&
                $0.state != .accessRevoked &&
                $0.state != .rebuildingCache
        }) else { return }
        let snapshots = try context.fetch(FetchDescriptor<FarmMembershipSnapshotRecord>())
            .filter { $0.farmID == farmID && $0.validatedAt != nil }
        guard let latest = snapshots.max(by: { $0.generation < $1.generation }),
              let envelope = try? JSONDecoder.membershipPersistence.decode(FarmMembershipSnapshotEnvelope.self, from: latest.payload),
              envelope.generation == latest.generation,
              latest.generation >= binding.securityGeneration,
              envelope.members.contains(where: { $0.accountID == accountID && $0.status == "active" }) else {
            binding.stateRawValue = CloudFarmBindingState.requiresAccountReview.rawValue
            return
        }
        let certificates = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
        guard let certificate = certificates.first(where: {
            $0.farmID == farmID && $0.accountID == accountID && $0.isUsable
        }), envelope.devices.contains(where: { $0.accountID == accountID && $0.deviceID == certificate.deviceID }) else {
            binding.stateRawValue = CloudFarmBindingState.requiresAccountReview.rawValue
            return
        }
        binding.securityGeneration = latest.generation
        binding.stateRawValue = CloudFarmBindingState.active.rawValue
        binding.lastErrorCode = nil
        binding.updatedAt = .now
        if let member = envelope.members.first(where: { $0.accountID == accountID }),
           let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }) {
            farm.roleRawValue = member.role.rawValue
            farm.membershipStatusRawValue = FarmMembershipStatus.active.rawValue
            farm.updatedAt = .now
        }
    }

    func recordSecurityIncident(farmID: UUID?, type: String, recordName: String? = nil, detail: String) throws {
        let context = ModelContext(container)
        context.insert(SecurityIncidentRecord(
            farmID: farmID,
            incidentType: type,
            recordName: recordName,
            detail: detail
        ))
        try context.save()
    }

    private static func x963PublicKey(fromJWKJSON json: String) -> Data? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let x = object["x"].flatMap(Data.init(base64URLText:)),
              let y = object["y"].flatMap(Data.init(base64URLText:)),
              x.count == 32, y.count == 32 else { return nil }
        return Data([0x04]) + x + y
    }

}

private extension Data {
    init?(base64URLText: String) {
        var normalized = base64URLText.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        self.init(base64Encoded: normalized)
    }
}

private extension JSONDecoder {
    static var membershipPersistence: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum CloudErrorClassifier {
    struct Result {
        let status: OutboxStatus
        let message: String
        let retryAt: Date?
    }

    static func classify(_ error: CKError) -> Result {
        switch error.code {
        case .notAuthenticated, .permissionFailure:
            return Result(status: .rejectedPermission, message: error.localizedDescription, retryAt: nil)
        case .serverRecordChanged:
            return Result(
                status: .blockedConflict,
                message: "云端已有不同内容，已停止自动重试。\(error.localizedDescription)",
                retryAt: nil
            )
        case .batchRequestFailed:
            return Result(status: .retryableFailure, message: error.localizedDescription, retryAt: .now.addingTimeInterval(5))
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            let delay = (error.userInfo[CKErrorRetryAfterKey] as? TimeInterval) ?? 30
            return Result(status: .retryableFailure, message: error.localizedDescription, retryAt: .now.addingTimeInterval(delay))
        default:
            return Result(status: .retryableFailure, message: error.localizedDescription, retryAt: .now.addingTimeInterval(60))
        }
    }
}

enum CloudRecordIdempotency {
    static func equivalent(client: CKRecord, server: CKRecord) -> Bool {
        guard client.recordID == server.recordID,
              client.recordType == server.recordType,
              let clientOperationID = client[CloudRecordField.operationID] as? String,
              clientOperationID == server[CloudRecordField.operationID] as? String else {
            return false
        }
        if let clientDigest = client[CloudRecordField.payloadDigest] as? String,
           let serverDigest = server[CloudRecordField.payloadDigest] as? String {
            return clientDigest == serverDigest
        }
        if let clientPayload = client[CloudRecordField.payload] as? Data,
           let serverPayload = server[CloudRecordField.payload] as? Data {
            return clientPayload == serverPayload
        }
        return false
    }
}

enum CloudEngineStateDiskStore {
    static func load(scope: CloudDatabaseScope) -> CKSyncEngine.State.Serialization? {
        let fileURL = url(scope: scope)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            let preservedURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: preservedURL)
            UserDefaults.standard.set(true, forKey: corruptionKey(scope: scope))
            return nil
        }
    }

    static func save(_ data: Data, scope: CloudDatabaseScope) throws {
        let fileURL = url(scope: scope)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func remove(scope: CloudDatabaseScope) throws {
        let fileURL = url(scope: scope)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        UserDefaults.standard.removeObject(forKey: corruptionKey(scope: scope))
    }

    static func wasCorrupted(scope: CloudDatabaseScope) -> Bool {
        UserDefaults.standard.bool(forKey: corruptionKey(scope: scope))
    }

    static func modifiedAt(scope: CloudDatabaseScope) -> Date? {
        let values = try? url(scope: scope).resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private static func url(scope: CloudDatabaseScope) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appending(path: "CloudSync", directoryHint: .isDirectory).appending(path: "\(scope.rawValue).json")
    }

    private static func corruptionKey(scope: CloudDatabaseScope) -> String {
        "CloudEngineStateDiskStore.corrupted.\(scope.rawValue)"
    }
}
