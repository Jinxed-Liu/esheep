import CloudKit
import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class SameAccountSyncSafetyTests: XCTestCase {
    func testRemoteRemovalOverridesLegacySnapshotAuthority() throws {
        let container = try AppSchema.makeContainer(
            name: "same-account-remote-removal-projection-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "7079",
            breed: "湖羊",
            sex: .ewe,
            penID: UUID(),
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        sheep.legacyStatusSnapshotIsAuthoritative = true
        sheep.legacyPenSnapshotIsAuthoritative = true
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "同账号增量牧场"))
        context.insert(sheep)
        try context.save()

        let occurredAt = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = try FarmCommandCloudPayloadEncoder.encode(.removeSheep(
            sheepID: sheep.id,
            kind: .deceased,
            reason: "梭菌致死",
            amountText: nil,
            occurredAt: occurredAt,
            note: ""
        ))
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: UUID(),
            entityType: CloudEntityType.removal.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: occurredAt.addingTimeInterval(10),
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "verified-before-apply",
            operationSignature: Data(),
            deletedAt: nil
        )

        XCTAssertEqual(
            try RemoteDomainApplyService().apply(envelope, context: context),
            .applied(rebuildHistoryFrom: occurredAt)
        )
        try FarmHistoryRebuilder().rebuildAffectedSheep(
            farmID: farmID,
            sheepIDs: [sheep.id],
            context: context,
            from: occurredAt
        )
        try context.save()

        XCTAssertEqual(sheep.status, .deceased)
        XCTAssertEqual(sheep.removedAt, occurredAt)
        XCTAssertNil(sheep.currentPenID)
        XCTAssertEqual(sheep.legacyStatusSnapshotIsAuthoritative, false)
        XCTAssertEqual(sheep.legacyPenSnapshotIsAuthoritative, false)
    }

    func testStartupRepairAppliesAlreadyReceivedPostRebuildRemovalOnly() throws {
        let container = try AppSchema.makeContainer(
            name: "same-account-post-rebuild-projection-repair-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let cutoff = Date(timeIntervalSince1970: 1_750_100_000)
        let changedSheep = SheepRecord(
            farmID: farmID,
            earTag: "7079",
            breed: "湖羊",
            sex: .ewe,
            penID: UUID(),
            enteredAt: cutoff.addingTimeInterval(-86_400 * 30)
        )
        changedSheep.legacyStatusSnapshotIsAuthoritative = true
        changedSheep.legacyPenSnapshotIsAuthoritative = true
        let legacyOnlySheep = SheepRecord(
            farmID: farmID,
            earTag: "LEGACY",
            breed: "湖羊",
            sex: .ewe,
            penID: UUID(),
            enteredAt: cutoff.addingTimeInterval(-86_400 * 30)
        )
        legacyOnlySheep.legacyStatusSnapshotIsAuthoritative = true
        legacyOnlySheep.legacyPenSnapshotIsAuthoritative = true
        let receivedRemoval = RemovalRecord(
            farmID: farmID,
            sheepID: changedSheep.id,
            kind: .deceased,
            reason: "梭菌致死",
            occurredAt: cutoff.addingTimeInterval(-86_400)
        )
        receivedRemoval.recordedAt = cutoff.addingTimeInterval(10)
        let preRebuildRemoval = RemovalRecord(
            farmID: farmID,
            sheepID: legacyOnlySheep.id,
            kind: .culled,
            reason: "旧版残缺历史",
            occurredAt: cutoff.addingTimeInterval(-86_400 * 10)
        )
        preRebuildRemoval.recordedAt = cutoff.addingTimeInterval(-10)
        let session = CloudRebuildSessionRecord(
            farmID: farmID,
            databaseScope: .privateDatabase,
            reason: .reinstallRecovery,
            stagingRelativePath: "test"
        )
        session.statusRawValue = CloudRebuildStatus.completed.rawValue
        session.completedAt = cutoff
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "修复牧场"))
        context.insert(CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(changedSheep)
        context.insert(legacyOnlySheep)
        context.insert(receivedRemoval)
        context.insert(preRebuildRemoval)
        context.insert(session)
        try context.save()

        XCTAssertEqual(
            try PostRecoveryHistoryProjectionRepair.repair(container: container),
            1
        )

        let verify = ModelContext(container)
        let repaired = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<SheepRecord>()).first { $0.id == changedSheep.id }
        )
        let preserved = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<SheepRecord>()).first { $0.id == legacyOnlySheep.id }
        )
        XCTAssertEqual(repaired.status, .deceased)
        XCTAssertEqual(repaired.legacyStatusSnapshotIsAuthoritative, false)
        XCTAssertEqual(repaired.legacyPenSnapshotIsAuthoritative, false)
        XCTAssertEqual(preserved.status, .active)
        XCTAssertEqual(preserved.legacyStatusSnapshotIsAuthoritative, true)
        XCTAssertEqual(preserved.legacyPenSnapshotIsAuthoritative, true)
    }

    func testCloudZoneFetcherRetriesTransientNetworkFailureButNotPermissionFailure() {
        let network = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.networkFailure.rawValue
        )
        XCTAssertEqual(
            CloudZoneChangeFetcher.retryDelay(for: network, attempt: 1),
            1
        )
        XCTAssertEqual(
            CloudZoneChangeFetcher.retryDelay(for: network, attempt: 5),
            16
        )

        let permission = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.permissionFailure.rawValue
        )
        XCTAssertNil(
            CloudZoneChangeFetcher.retryDelay(for: permission, attempt: 1)
        )
    }

    func testCompletedCacheSwitchRetriesOnlyEngineActivation() {
        let farmID = UUID()
        let ownerID = UUID()
        let binding = CloudFarmBindingSnapshot(
            farmID: farmID,
            ownerAccountID: ownerID,
            zoneName: CloudZoneName.forFarm(farmID),
            zoneOwnerName: CKCurrentUserDefaultName,
            databaseScope: .privateDatabase,
            shareRecordName: nil,
            state: .rebuildingCache,
            lastErrorCode: "engineResetFailed"
        )

        XCTAssertTrue(CloudCollaborationStore.shouldRetryCompletedRebuildEngineReset(
            binding,
            hasVerifiedCompletedCacheSwitch: true
        ))
        XCTAssertFalse(CloudCollaborationStore.shouldRetryCompletedRebuildEngineReset(
            binding,
            hasVerifiedCompletedCacheSwitch: false
        ))

        let unmarked = CloudFarmBindingSnapshot(
            farmID: farmID,
            ownerAccountID: ownerID,
            zoneName: CloudZoneName.forFarm(farmID),
            zoneOwnerName: CKCurrentUserDefaultName,
            databaseScope: .privateDatabase,
            shareRecordName: nil,
            state: .rebuildingCache,
            lastErrorCode: nil
        )
        XCTAssertFalse(CloudCollaborationStore.shouldRetryCompletedRebuildEngineReset(
            unmarked,
            hasVerifiedCompletedCacheSwitch: true
        ), "没有 durable engine-reset marker 时不能跳过权威重建")
    }

    func testOtherRebuildLocksCannotSkipAuthoritativeRebuild() {
        let farmID = UUID()
        let binding = CloudFarmBindingSnapshot(
            farmID: farmID,
            ownerAccountID: UUID(),
            zoneName: CloudZoneName.forFarm(farmID),
            zoneOwnerName: CKCurrentUserDefaultName,
            databaseScope: .privateDatabase,
            shareRecordName: nil,
            state: .rebuildingCache,
            lastErrorCode: "rebuildValidationFailed"
        )

        XCTAssertFalse(CloudCollaborationStore.shouldRetryCompletedRebuildEngineReset(
            binding,
            hasVerifiedCompletedCacheSwitch: true
        ))
    }

    func testStrongLockUsesFreshRebuildAndResetClaimBlocksCompetingRebuild() {
        let farmID = UUID()
        let ownerID = UUID()
        func binding(_ code: String) -> CloudFarmBindingSnapshot {
            CloudFarmBindingSnapshot(
                farmID: farmID,
                ownerAccountID: ownerID,
                zoneName: CloudZoneName.forFarm(farmID),
                zoneOwnerName: CKCurrentUserDefaultName,
                databaseScope: .privateDatabase,
                shareRecordName: nil,
                state: .rebuildingCache,
                lastErrorCode: code
            )
        }

        let strongLock = binding("immutableOperationHardDelete")
        XCTAssertTrue(CloudRebuildActor.canBeginRebuild(from: strongLock))
        XCTAssertFalse(CloudRebuildActor.canRetryPreparedCommit(from: strongLock))

        let claimedReset = binding("engineResetInProgress")
        XCTAssertFalse(CloudRebuildActor.canBeginRebuild(from: claimedReset))
        XCTAssertFalse(CloudRebuildActor.canRetryPreparedCommit(from: claimedReset))
        XCTAssertTrue(CloudSyncActor.isAllowedRecoveryEngineResetCode(claimedReset.lastErrorCode))
        XCTAssertFalse(CloudCollaborationStore.shouldRetryCompletedRebuildEngineReset(
            claimedReset,
            hasVerifiedCompletedCacheSwitch: false
        ), "engine reset 崩溃重试仍必须保留当前来源证明的 completed bundle")
        XCTAssertFalse(CloudSyncActor.isAllowedRecoveryEngineResetCode(nil))

        let requiresFresh = binding("rebuildCommitRequiresFreshRebuild")
        XCTAssertTrue(CloudRebuildActor.canBeginRebuild(from: requiresFresh))
        XCTAssertFalse(CloudRebuildActor.canRetryPreparedCommit(from: requiresFresh))
    }

    func testCrashLeftUnverifiedEngineResetClaimTransitionsToFreshRebuild() async throws {
        let fixture = try makePersistenceFixture()
        let context = ModelContext(fixture.container)
        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == fixture.farmID }
        )
        stored.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
        stored.lastErrorCode = "engineResetInProgress"
        try context.save()

        let sync = CloudSyncActor(
            containerIdentifier: "",
            persistence: FarmPersistenceActor(container: fixture.container)
        )
        let transitionedToFreshRebuild = try await sync.prepareFreshRebuildAfterUnverifiedResetClaim(
            scope: .privateDatabase,
            farmID: fixture.farmID
        )
        XCTAssertTrue(transitionedToFreshRebuild)

        let verify = ModelContext(fixture.container)
        let transitioned = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == fixture.farmID }
        )
        XCTAssertEqual(transitioned.state, .rebuildingCache)
        XCTAssertEqual(transitioned.lastErrorCode, "rebuildCommitRequiresFreshRebuild")
        let snapshot = try await FarmPersistenceActor(container: fixture.container)
            .bindingSnapshot(farmID: fixture.farmID)
        XCTAssertTrue(CloudRebuildActor.canBeginRebuild(from: try XCTUnwrap(snapshot)))
    }

    func testLiveIngestUsesOnlyImmutableOperationsAndReplaysInverseRevisionOrder() async throws {
        let container = try AppSchema.makeContainer(
            name: "same-account-live-operation-order-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let deviceID = UUID()
        let penID = UUID()
        let deviceKey = P256.Signing.PrivateKey()
        let certificateKey = P256.Signing.PrivateKey()
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: ownerID,
            farmID: farmID,
            deviceID: deviceID,
            role: .owner,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(modifiedAt.timeIntervalSince1970) - 10,
            exp: Int(modifiedAt.timeIntervalSince1970) + 600,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )
        let certificate = try makeCapabilityCertificate(claims: claims, signingKey: certificateKey)
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "同账号乱序验证"))
        context.insert(CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        let device = DeviceIdentityRecord(
            id: deviceID,
            accountID: ownerID,
            publicKeyX963: deviceKey.publicKey.x963Representation,
            usesSecureEnclave: false
        )
        device.isRegistered = true
        context.insert(device)
        try context.save()

        let revisionOne = try makeSignedLiveOperation(
            farmID: farmID,
            entityID: penID,
            revision: 1,
            baseRevision: 0,
            command: .createPen(name: "初始圈舍", note: ""),
            modifiedAt: modifiedAt,
            ownerID: ownerID,
            deviceID: deviceID,
            certificate: certificate,
            deviceKey: deviceKey
        )
        let revisionTwo = try makeSignedLiveOperation(
            farmID: farmID,
            entityID: penID,
            revision: 2,
            baseRevision: 1,
            command: .updatePen(penID: penID, name: "云端新名称", note: "已同步"),
            modifiedAt: modifiedAt.addingTimeInterval(1),
            ownerID: ownerID,
            deviceID: deviceID,
            certificate: certificate,
            deviceKey: deviceKey
        )
        let mapper = CloudRecordMapper()
        let zoneID = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(farmID),
            ownerName: CKCurrentUserDefaultName
        )
        let revisionOneRecord = mapper.operationRecord(from: revisionOne, zoneID: zoneID)
        let revisionTwoRecord = mapper.operationRecord(from: revisionTwo, zoneID: zoneID)
        let projection = mapper.entityRecord(from: revisionTwo, zoneID: zoneID)
        let persistence = FarmPersistenceActor(
            container: container,
            capabilitySigningPublicKeyPEMOverride: certificateKey.publicKey.pemRepresentation
        )

        let affected = try await persistence.ingest(
            [
                revisionTwoRecord,
                projection,
                revisionOneRecord,
            ],
            scope: .privateDatabase
        )

        XCTAssertTrue(affected.isEmpty)
        let verify = ModelContext(container)
        let pen = try XCTUnwrap(try verify.fetch(FetchDescriptor<PenRecord>()).first { $0.id == penID })
        XCTAssertEqual(pen.revision, 2)
        XCTAssertEqual(pen.name, "云端新名称")
        XCTAssertEqual(pen.note, "已同步")
        XCTAssertEqual(
            try verify.fetch(FetchDescriptor<CloudOperationReceipt>()).filter { $0.farmID == farmID }.count,
            2,
            "FarmEntity 投影不能制造第三张不可变操作回执"
        )
        XCTAssertTrue(try verify.fetch(FetchDescriptor<SyncConflictRecord>()).isEmpty)
        let binding = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == farmID }
        )
        XCTAssertEqual(binding.state, .active)

        let recoveryLockContext = ModelContext(container)
        let recoveryBinding = try XCTUnwrap(
            try recoveryLockContext.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == farmID }
        )
        recoveryBinding.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
        recoveryBinding.lastErrorCode = "engineResetInProgress"
        try recoveryLockContext.save()
        let recoverySources = try Dictionary(uniqueKeysWithValues: [
            CloudRebuildOperationSourceProof(record: revisionOneRecord, envelope: revisionOne),
            CloudRebuildOperationSourceProof(record: revisionTwoRecord, envelope: revisionTwo),
        ].map { ($0.recordName, $0) })

        let recoveryAffected = try await persistence.ingest(
            [revisionTwoRecord, projection, revisionOneRecord],
            scope: .privateDatabase,
            recoveryFarmID: farmID,
            recoveryOperationSources: recoverySources
        )

        XCTAssertTrue(recoveryAffected.isEmpty)
        let recoveryVerify = ModelContext(container)
        XCTAssertTrue(try recoveryVerify.fetch(FetchDescriptor<SyncConflictRecord>()).isEmpty)
        let reactivatedForGapTest = try XCTUnwrap(
            try recoveryVerify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == farmID }
        )
        reactivatedForGapTest.stateRawValue = CloudFarmBindingState.active.rawValue
        reactivatedForGapTest.lastErrorCode = nil
        try recoveryVerify.save()

        let missingPenID = UUID()
        let revisionWithMissingBase = try makeSignedLiveOperation(
            farmID: farmID,
            entityID: missingPenID,
            revision: 2,
            baseRevision: 1,
            command: .updatePen(penID: missingPenID, name: "缺少 rev1", note: ""),
            modifiedAt: modifiedAt.addingTimeInterval(2),
            ownerID: ownerID,
            deviceID: deviceID,
            certificate: certificate,
            deviceKey: deviceKey
        )
        let gapFarmIDs = try await persistence.ingest(
            [mapper.operationRecord(from: revisionWithMissingBase, zoneID: zoneID)],
            scope: .privateDatabase
        )

        XCTAssertEqual(gapFarmIDs, Set([farmID]))
        let gapVerify = ModelContext(container)
        let lockedBinding = try XCTUnwrap(
            try gapVerify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == farmID }
        )
        XCTAssertEqual(lockedBinding.state, .rebuildingCache)
        XCTAssertEqual(lockedBinding.lastErrorCode, "liveOperationGap")
        XCTAssertFalse(
            try gapVerify.fetch(FetchDescriptor<SyncConflictRecord>()).contains {
                $0.entityID == missingPenID
            },
            "缺少较早 revision 是恢复缺口，不得伪造成可人工合并的业务冲突"
        )
    }

    func testCommitFailureClassificationRejectsStaleOrInvalidStaging() {
        XCTAssertTrue(CloudRebuildActor.commitFailureRequiresFreshRebuild(
            CloudRebuildError.authoritativeRootChanged,
            reusableStagingVerified: true
        ))
        XCTAssertTrue(CloudRebuildActor.commitFailureRequiresFreshRebuild(
            CocoaError(.fileNoSuchFile),
            reusableStagingVerified: false
        ))
        XCTAssertTrue(CloudRebuildActor.commitFailureRequiresFreshRebuild(
            RemoteDomainApplyError.invalidPayload("pendingOutbox"),
            reusableStagingVerified: true
        ))
        XCTAssertFalse(CloudRebuildActor.commitFailureRequiresFreshRebuild(
            CocoaError(.fileWriteOutOfSpace),
            reusableStagingVerified: true
        ))
    }

    func testCapabilityRefreshPreservesRecoveryEngineClaim() async throws {
        let container = try AppSchema.makeContainer(
            name: "capability-preserves-recovery-claim-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let farm = FarmRecord(id: farmID, ownerAccountID: ownerID, name: "恢复中牧场")
        let binding = CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .rebuildingCache
        )
        binding.lastErrorCode = "engineResetInProgress"
        context.insert(farm)
        context.insert(binding)
        try context.save()

        let now = Int(Date.now.timeIntervalSince1970)
        try await FarmPersistenceActor(container: container).saveCapability(
            WorkerCapabilityResponse(
                certificateID: UUID().uuidString,
                certificate: "test-certificate",
                role: .owner,
                capabilities: [.readFarm],
                issuedAt: now,
                expiresAt: now + 86_400
            ),
            accountID: ownerID,
            farmID: farmID,
            deviceID: UUID()
        )

        let verify = ModelContext(container)
        let stored = try XCTUnwrap(try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first)
        XCTAssertEqual(stored.state, .rebuildingCache)
        XCTAssertEqual(stored.lastErrorCode, "engineResetInProgress")
    }

    func testRecoveryFailureCASPreservesStrongerSecurityReason() async throws {
        let container = try AppSchema.makeContainer(
            name: "recovery-reset-cas-strong-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let binding = CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: UUID(),
            state: .rebuildingCache
        )
        binding.lastErrorCode = "immutableOperationHardDelete"
        context.insert(binding)
        try context.save()

        let changed = try await FarmPersistenceActor(container: container)
            .recordRecoveryEngineFailureIfUnchanged(
                farmID: farmID,
                expectedLastErrorCode: "engineResetPending",
                failureCode: "engineResetFailed"
            )

        XCTAssertFalse(changed)
        let verify = ModelContext(container)
        let stored = try XCTUnwrap(try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first)
        XCTAssertEqual(stored.state, .rebuildingCache)
        XCTAssertEqual(stored.lastErrorCode, "immutableOperationHardDelete")
    }

    func testRecoveryFailureCASNeverDowngradesActiveBinding() async throws {
        let container = try AppSchema.makeContainer(
            name: "recovery-reset-cas-active-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let binding = CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: UUID(),
            state: .active
        )
        binding.lastErrorCode = "engineResetPending"
        context.insert(binding)
        try context.save()

        let changed = try await FarmPersistenceActor(container: container)
            .recordRecoveryEngineFailureIfUnchanged(
                farmID: farmID,
                expectedLastErrorCode: "engineResetPending",
                failureCode: "engineResetFailed"
            )

        XCTAssertFalse(changed)
        let verify = ModelContext(container)
        let stored = try XCTUnwrap(try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first)
        XCTAssertEqual(stored.state, .active)
        XCTAssertEqual(stored.lastErrorCode, "engineResetPending")
    }

    func testRecoveryActivationCannotClearConcurrentStrongLock() async throws {
        let container = try AppSchema.makeContainer(
            name: "recovery-activation-cas-strong-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let cutoff = Date(timeIntervalSince1970: 1_735_689_600.789)
        let farm = FarmRecord(id: farmID, ownerAccountID: ownerID, name: "权威牧场")
        let binding = CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .rebuildingCache
        )
        binding.lastErrorCode = "engineResetPending"
        let commit = MigrationCommitRecord(
            sessionID: UUID(),
            sourceChecksum: "same-account-recovery",
            farmID: farmID,
            ownerAccountID: ownerID,
            recordCountsJSON: "{}",
            assetsRelativeDirectory: ""
        )
        commit.baselineDigest = "verified-v2-digest"
        commit.baselineEntityCount = 1
        commit.baselinePhotoCount = 0
        commit.cloudState = .synced
        var bootstrap = FarmCommandCloudPayload(kind: .bootstrapEntity)
        bootstrap.integers["baselineVersion"] = 2
        bootstrap.dates["baselineCutoffAt"] = cutoff
        let operation = DomainOperation(
            farmID: farmID,
            accountID: ownerID,
            kind: .bootstrapEntity,
            summary: "v2 recovery identity",
            entityType: CloudEntityType.farm.rawValue,
            entityID: farmID,
            payload: try JSONEncoder.cloud.encode(bootstrap)
        )
        context.insert(farm)
        context.insert(binding)
        context.insert(commit)
        context.insert(operation)
        try context.save()

        let persistence = FarmPersistenceActor(container: container)
        let expected = try await persistence.recoveryRootExpectation(
            farmID: farmID,
            scope: .privateDatabase,
            expectedLastErrorCode: "engineResetPending"
        )
        let installedStrongLock = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: farmID,
            expectedState: .rebuildingCache,
            expectedLastErrorCode: "engineResetPending",
            newState: .rebuildingCache,
            newLastErrorCode: "immutableOperationHardDelete"
        )
        XCTAssertTrue(installedStrongLock)

        do {
            _ = try await persistence.recoveryRootExpectation(
                farmID: farmID,
                scope: .privateDatabase,
                expectedLastErrorCode: "engineResetPending"
            )
            XCTFail("强安全锁在 expectation 读取前出现时也不得被旧恢复任务接纳")
        } catch {
            XCTAssertTrue(error is CloudSyncError)
        }

        do {
            try await persistence.activateAfterRecoveryCatchUp(
                farmID: farmID,
                expected: expected
            )
            XCTFail("并发安全锁写入后不得激活牧场")
        } catch {
            // Expected: the binding no longer matches the recovery snapshot.
        }

        let verify = ModelContext(container)
        let stored = try XCTUnwrap(try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first)
        XCTAssertEqual(stored.state, .rebuildingCache)
        XCTAssertEqual(stored.lastErrorCode, "immutableOperationHardDelete")
    }

    func testSuccessfulCommandSavePostsSyncWakeForFarm() throws {
        let fixture = try makeCommandFixture()
        let notifications = NotificationCollector()
        let token = NotificationCenter.default.addObserver(
            forName: CloudRuntimeNotification.syncWake,
            object: nil,
            queue: nil
        ) { notification in
            if let farmID = CloudRuntimeNotification.farmID(from: notification) {
                notifications.append(farmID)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try fixture.service.execute(
            .createPen(name: "增量同步圈舍", note: "成功保存后唤醒同步"),
            in: fixture.farmContext,
            context: fixture.context
        )

        XCTAssertEqual(notifications.count(for: fixture.farm.id), 1)
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == fixture.farm.id }.count,
            1
        )
    }

    func testFailedBatchRollsBackAndDoesNotPostSyncWake() throws {
        let fixture = try makeCommandFixture()
        let notifications = NotificationCollector()
        let token = NotificationCenter.default.addObserver(
            forName: CloudRuntimeNotification.syncWake,
            object: nil,
            queue: nil
        ) { notification in
            if let farmID = CloudRuntimeNotification.farmID(from: notification) {
                notifications.append(farmID)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertThrowsError(try fixture.service.executeBatch(
            [
                .createPen(name: "必须回滚", note: "第一条已暂存"),
                .createPen(name: "   ", note: "第二条校验失败")
            ],
            in: fixture.farmContext,
            context: fixture.context
        ))

        XCTAssertEqual(notifications.count(for: fixture.farm.id), 0)
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == fixture.farm.id }.count,
            0
        )
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == fixture.farm.id }.count,
            0
        )
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.farmID == fixture.farm.id }.count,
            0
        )
    }

    func testHardDeletedOperationInActiveZoneLocksBindingAndReturnsFarmID() async throws {
        let fixture = try makePersistenceFixture()
        let persistence = FarmPersistenceActor(container: fixture.container)
        let zoneID = CKRecordZone.ID(
            zoneName: fixture.binding.zoneName,
            ownerName: fixture.binding.zoneOwnerName
        )
        let deletion = makeDeletion(
            operationID: UUID(),
            zoneID: zoneID,
            recordType: CloudRecordType.farmOperation.rawValue
        )

        let affectedFarmIDs = try await persistence.recordUnexpectedDeletions([deletion])

        XCTAssertEqual(affectedFarmIDs, Set([fixture.farmID]))
        let verify = ModelContext(fixture.container)
        let binding = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == fixture.farmID }
        )
        XCTAssertEqual(binding.state, .rebuildingCache)
        XCTAssertEqual(binding.lastErrorCode, "immutableOperationHardDelete")
        XCTAssertTrue(
            try verify.fetch(FetchDescriptor<SecurityIncidentRecord>()).contains {
                $0.farmID == fixture.farmID && $0.incidentType == "immutableOperationHardDelete"
            }
        )
    }

    func testNilStateRecoveryIgnoresOnlyHistoricalOperationDeletionOutsideCurrentProof() async throws {
        let fixture = try makePersistenceFixture()
        let context = ModelContext(fixture.container)
        let binding = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == fixture.farmID }
        )
        binding.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
        binding.lastErrorCode = "engineResetInProgress"
        try context.save()
        let persistence = FarmPersistenceActor(container: fixture.container)
        let mapper = CloudRecordMapper()
        let provenOperationID = UUID()
        let historicalOperationID = UUID()
        let zoneID = CKRecordZone.ID(
            zoneName: fixture.binding.zoneName,
            ownerName: fixture.binding.zoneOwnerName
        )
        let historicalDeletion = makeDeletion(
            operationID: historicalOperationID,
            zoneID: zoneID,
            recordType: CloudRecordType.farmOperation.rawValue
        )
        let proof = Set([mapper.recordName(for: provenOperationID)])

        let affected = try await persistence.recordUnexpectedDeletions(
            [historicalDeletion],
            recoveryFarmID: fixture.farmID,
            recoveryAuthoritativeOperationRecordNames: proof
        )

        XCTAssertTrue(affected.isEmpty)
        let historicalVerify = ModelContext(fixture.container)
        let stillRecovering = try XCTUnwrap(
            try historicalVerify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == fixture.farmID }
        )
        XCTAssertEqual(stillRecovering.lastErrorCode, "engineResetInProgress")
        XCTAssertTrue(
            try historicalVerify.fetch(FetchDescriptor<SecurityIncidentRecord>()).contains {
                $0.farmID == fixture.farmID &&
                    $0.incidentType == "historicalOperationDeletionExcludedByRebuildProof"
            }
        )

        let provenDeletion = makeDeletion(
            operationID: provenOperationID,
            zoneID: zoneID,
            recordType: CloudRecordType.farmOperation.rawValue
        )
        do {
            _ = try await persistence.recordUnexpectedDeletions(
                [provenDeletion],
                recoveryFarmID: fixture.farmID,
                recoveryAuthoritativeOperationRecordNames: proof
            )
            XCTFail("当前来源证明中的不可变操作被删除时必须让恢复失败")
        } catch {
            XCTAssertTrue(error is CloudSyncError)
        }
        let currentVerify = ModelContext(fixture.container)
        let hardDeleteLock = try XCTUnwrap(
            try currentVerify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == fixture.farmID }
        )
        XCTAssertEqual(hardDeleteLock.lastErrorCode, "immutableOperationHardDelete")
    }

    func testHardDeletedOperationOutsideActiveZoneDoesNotLockBinding() async throws {
        let fixture = try makePersistenceFixture()
        let persistence = FarmPersistenceActor(container: fixture.container)
        let otherZoneID = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(UUID()),
            ownerName: fixture.binding.zoneOwnerName
        )
        let deletion = makeDeletion(
            operationID: UUID(),
            zoneID: otherZoneID,
            recordType: CloudRecordType.farmOperation.rawValue
        )

        let affectedFarmIDs = try await persistence.recordUnexpectedDeletions([deletion])

        XCTAssertTrue(affectedFarmIDs.isEmpty)
        let verify = ModelContext(fixture.container)
        let binding = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == fixture.farmID }
        )
        XCTAssertEqual(binding.state, .active)
        XCTAssertNil(binding.lastErrorCode)
        XCTAssertFalse(
            try verify.fetch(FetchDescriptor<SecurityIncidentRecord>()).contains {
                $0.farmID == fixture.farmID && $0.incidentType == "immutableOperationHardDelete"
            }
        )
    }

    func testSecuritySnapshotInstallsSecondSameAccountDeviceWithoutUnlockingRebuildAndRejectsKeyRotation() async throws {
        let container = try AppSchema.makeContainer(
            name: "same-account-security-snapshot-device-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let ownerDeviceID = UUID()
        let secondDeviceID = UUID()
        let ownerKey = P256.Signing.PrivateKey()
        let secondDeviceKey = P256.Signing.PrivateKey()
        let replacementKey = P256.Signing.PrivateKey()
        let account = AccountProfile(
            id: ownerID,
            appleUserIdentifier: UUID().uuidString,
            displayName: "同账号牧场主"
        )
        let farm = FarmRecord(id: farmID, ownerAccountID: ownerID, name: "恢复中的同账号牧场")
        let binding = CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .rebuildingCache
        )
        binding.lastErrorCode = "engineResetInProgress"
        let ownerDevice = DeviceIdentityRecord(
            id: ownerDeviceID,
            accountID: ownerID,
            publicKeyX963: ownerKey.publicKey.x963Representation,
            usesSecureEnclave: false
        )
        ownerDevice.isRegistered = true
        context.insert(account)
        context.insert(farm)
        context.insert(binding)
        context.insert(ownerDevice)
        try context.save()

        let ownerMember = WorkerFarmSecuritySnapshot.Member(
            membershipID: "owner-membership",
            accountID: ownerID,
            displayName: "同账号牧场主",
            role: .owner,
            status: "active",
            shareParticipantRecordName: nil
        )
        let ownerDeviceJWK = try jwkJSON(for: ownerKey.publicKey)
        let secondDeviceJWK = try jwkJSON(for: secondDeviceKey.publicKey)
        let persistence = FarmPersistenceActor(container: container)
        let originalSnapshot = WorkerFarmSecuritySnapshot(
            farmID: farmID,
            generation: 8,
            issuedAt: Int(Date.now.timeIntervalSince1970),
            members: [ownerMember],
            devices: [
                .init(deviceID: ownerDeviceID, accountID: ownerID, publicKeyJWK: ownerDeviceJWK),
                .init(deviceID: secondDeviceID, accountID: ownerID, publicKeyJWK: secondDeviceJWK),
            ],
            revokedCertificates: []
        )

        try await persistence.saveSecuritySnapshot(originalSnapshot)

        let installedContext = ModelContext(container)
        let installedDevices = try installedContext.fetch(FetchDescriptor<DeviceIdentityRecord>())
            .filter { $0.accountID == ownerID }
        XCTAssertEqual(installedDevices.count, 2)
        let installedSecondDevice = try XCTUnwrap(installedDevices.first { $0.id == secondDeviceID })
        XCTAssertEqual(installedSecondDevice.publicKeyX963, secondDeviceKey.publicKey.x963Representation)
        XCTAssertTrue(installedSecondDevice.isRegistered)
        let lockedAfterInstall = try XCTUnwrap(
            try installedContext.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == farmID }
        )
        XCTAssertEqual(lockedAfterInstall.state, .rebuildingCache)
        XCTAssertEqual(lockedAfterInstall.lastErrorCode, "engineResetInProgress")

        let replacedKeySnapshot = WorkerFarmSecuritySnapshot(
            farmID: farmID,
            generation: 9,
            issuedAt: originalSnapshot.issuedAt + 1,
            members: [ownerMember],
            devices: [
                .init(deviceID: ownerDeviceID, accountID: ownerID, publicKeyJWK: ownerDeviceJWK),
                .init(
                    deviceID: secondDeviceID,
                    accountID: ownerID,
                    publicKeyJWK: try jwkJSON(for: replacementKey.publicKey)
                ),
            ],
            revokedCertificates: []
        )
        do {
            try await persistence.saveSecuritySnapshot(replacedKeySnapshot)
            XCTFail("同一 deviceID 不得通过安全快照静默更换公钥")
        } catch {
            XCTAssertEqual(error as? CloudContractError, .invalidDeviceSignature)
        }

        let rejectedContext = ModelContext(container)
        let retainedSecondDevice = try XCTUnwrap(
            try rejectedContext.fetch(FetchDescriptor<DeviceIdentityRecord>()).first { $0.id == secondDeviceID }
        )
        XCTAssertEqual(retainedSecondDevice.accountID, ownerID)
        XCTAssertEqual(retainedSecondDevice.publicKeyX963, secondDeviceKey.publicKey.x963Representation)
        XCTAssertEqual(
            try rejectedContext.fetch(FetchDescriptor<DeviceIdentityRecord>()).filter { $0.id == secondDeviceID }.count,
            1
        )
        let lockedAfterRejection = try XCTUnwrap(
            try rejectedContext.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == farmID }
        )
        XCTAssertEqual(lockedAfterRejection.state, .rebuildingCache)
        XCTAssertEqual(lockedAfterRejection.lastErrorCode, "engineResetInProgress")
    }

    func testSameGenerationMembershipAllowsOnlyStrictlyNewerAdditiveDeviceUpdate() async throws {
        let container = try AppSchema.makeContainer(
            name: "same-generation-membership-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let persistence = FarmPersistenceActor(container: container)
        let farmID = UUID()
        let ownerID = UUID()
        let ownerDeviceID = UUID()
        let secondDeviceID = UUID()
        let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let owner = FarmMembershipSnapshotEnvelope.Member(
            membershipID: "owner-membership",
            accountID: ownerID,
            role: .owner,
            status: "active",
            shareParticipantRecordName: nil
        )
        let ownerDevice = FarmMembershipSnapshotEnvelope.Device(
            deviceID: ownerDeviceID,
            accountID: ownerID,
            publicKeyJWK: "owner-key-v1"
        )
        let secondDevice = FarmMembershipSnapshotEnvelope.Device(
            deviceID: secondDeviceID,
            accountID: ownerID,
            publicKeyJWK: "second-device-key"
        )
        let original = FarmMembershipSnapshotEnvelope(
            farmID: farmID,
            generation: 7,
            issuedAt: issuedAt,
            members: [owner],
            devices: [ownerDevice],
            revokedCertificates: []
        )
        try await persistence.saveMembershipSnapshotRecord(
            try membershipValue(envelope: original, signedByAccountID: ownerID, signedByDeviceID: ownerDeviceID)
        )

        let notStrictlyNewer = FarmMembershipSnapshotEnvelope(
            farmID: farmID,
            generation: 7,
            issuedAt: issuedAt,
            members: [owner],
            devices: [ownerDevice, secondDevice],
            revokedCertificates: []
        )
        await assertMembershipRollback {
            try await persistence.saveMembershipSnapshotRecord(
                try membershipValue(
                    envelope: notStrictlyNewer,
                    signedByAccountID: ownerID,
                    signedByDeviceID: ownerDeviceID
                )
            )
        }

        let additiveUpdate = FarmMembershipSnapshotEnvelope(
            farmID: farmID,
            generation: 7,
            issuedAt: issuedAt.addingTimeInterval(1),
            members: [owner],
            devices: [ownerDevice, secondDevice],
            revokedCertificates: []
        )
        try await persistence.saveMembershipSnapshotRecord(
            try membershipValue(
                envelope: additiveUpdate,
                signedByAccountID: ownerID,
                signedByDeviceID: ownerDeviceID
            )
        )

        let changedKey = FarmMembershipSnapshotEnvelope(
            farmID: farmID,
            generation: 7,
            issuedAt: issuedAt.addingTimeInterval(2),
            members: [owner],
            devices: [
                .init(deviceID: ownerDeviceID, accountID: ownerID, publicKeyJWK: "owner-key-replaced"),
                secondDevice
            ],
            revokedCertificates: []
        )
        await assertMembershipRollback {
            try await persistence.saveMembershipSnapshotRecord(
                try membershipValue(envelope: changedKey, signedByAccountID: ownerID, signedByDeviceID: ownerDeviceID)
            )
        }

        let removedMember = FarmMembershipSnapshotEnvelope(
            farmID: farmID,
            generation: 7,
            issuedAt: issuedAt.addingTimeInterval(3),
            members: [],
            devices: [ownerDevice, secondDevice],
            revokedCertificates: []
        )
        await assertMembershipRollback {
            try await persistence.saveMembershipSnapshotRecord(
                try membershipValue(envelope: removedMember, signedByAccountID: ownerID, signedByDeviceID: ownerDeviceID)
            )
        }

        let verify = ModelContext(container)
        let stored = try XCTUnwrap(try verify.fetch(FetchDescriptor<FarmMembershipSnapshotRecord>()).first)
        let storedEnvelope = try membershipDecoder.decode(FarmMembershipSnapshotEnvelope.self, from: stored.payload)
        XCTAssertEqual(storedEnvelope, additiveUpdate)
    }

    private func makeSignedLiveOperation(
        farmID: UUID,
        entityID: UUID,
        revision: Int,
        baseRevision: Int,
        command: FarmCommand,
        modifiedAt: Date,
        ownerID: UUID,
        deviceID: UUID,
        certificate: String,
        deviceKey: P256.Signing.PrivateKey
    ) throws -> CloudOperationEnvelope {
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let unsigned = CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: CloudEntityType.pen.rawValue,
            schemaVersion: 2,
            revision: revision,
            baseRevision: baseRevision,
            operationID: UUID(),
            modifiedAt: modifiedAt,
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: deviceID,
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: certificate,
            operationSignature: Data(),
            deletedAt: nil
        )
        return CloudOperationEnvelope(
            farmID: unsigned.farmID,
            entityID: unsigned.entityID,
            entityType: unsigned.entityType,
            schemaVersion: unsigned.schemaVersion,
            revision: unsigned.revision,
            baseRevision: unsigned.baseRevision,
            operationID: unsigned.operationID,
            modifiedAt: unsigned.modifiedAt,
            modifiedByAccountID: unsigned.modifiedByAccountID,
            modifiedByDeviceID: unsigned.modifiedByDeviceID,
            payload: unsigned.payload,
            payloadDigest: unsigned.payloadDigest,
            capabilityCertificate: unsigned.capabilityCertificate,
            operationSignature: try deviceKey.signature(for: unsigned.canonicalSigningData).rawRepresentation,
            deletedAt: unsigned.deletedAt
        )
    }

    private func makeCapabilityCertificate(
        claims: CapabilityCertificateClaims,
        signingKey: P256.Signing.PrivateKey
    ) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: [
            "alg": "ES256",
            "kid": "same-account-test",
            "typ": "esheep-capability+jwt",
        ], options: [.sortedKeys])
        let payload = try JSONEncoder().encode(claims)
        let encodedHeader = base64URL(header)
        let encodedPayload = base64URL(payload)
        let signedText = "\(encodedHeader).\(encodedPayload)"
        let signature = try signingKey.signature(for: Data(signedText.utf8)).rawRepresentation
        return "\(signedText).\(base64URL(signature))"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeCommandFixture() throws -> CommandFixture {
        let container = try AppSchema.makeContainer(
            name: "same-account-command-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "同账号测试")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "同账号牧场")
        context.insert(account)
        context.insert(farm)
        try context.save()
        return CommandFixture(
            context: context,
            account: account,
            farm: farm,
            service: FarmCommandService()
        )
    }

    private func makePersistenceFixture() throws -> PersistenceFixture {
        let container = try AppSchema.makeContainer(
            name: "same-account-persistence-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let binding = CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        )
        context.insert(binding)
        try context.save()
        return PersistenceFixture(container: container, farmID: farmID, binding: binding)
    }

    private func membershipValue(
        envelope: FarmMembershipSnapshotEnvelope,
        signedByAccountID: UUID,
        signedByDeviceID: UUID
    ) throws -> MembershipSnapshotRecordValue {
        MembershipSnapshotRecordValue(
            id: UUID(),
            farmID: envelope.farmID,
            generation: envelope.generation,
            issuedAt: envelope.issuedAt,
            payload: try membershipEncoder.encode(envelope),
            signedByAccountID: signedByAccountID,
            signedByDeviceID: signedByDeviceID,
            capabilityCertificate: "test-certificate",
            signature: Data("test-signature".utf8),
            cloudRecordName: nil,
            validatedAt: nil
        )
    }

    private func jwkJSON(for publicKey: P256.Signing.PublicKey) throws -> String {
        let representation = publicKey.x963Representation
        XCTAssertEqual(representation.count, 65)
        XCTAssertEqual(representation.first, 0x04)
        let coordinates = representation.dropFirst()
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let object = [
            "kty": "EC",
            "crv": "P-256",
            "x": base64URL(Data(coordinates.prefix(32))),
            "y": base64URL(Data(coordinates.dropFirst(32).prefix(32))),
            "use": "sig",
            "alg": "ES256",
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func assertMembershipRollback(
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("同 generation 的非严格增量变更必须被拒绝", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CloudContractError, .membershipSnapshotRollback, file: file, line: line)
        }
    }

    private var membershipEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var membershipDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct CommandFixture {
    let context: ModelContext
    let account: AccountProfile
    let farm: FarmRecord
    let service: FarmCommandService

    var farmContext: FarmContext {
        FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
    }
}

private struct PersistenceFixture {
    let container: ModelContainer
    let farmID: UUID
    let binding: CloudFarmBinding
}

private final class NotificationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var farmIDs: [UUID] = []

    func append(_ farmID: UUID) {
        lock.lock()
        farmIDs.append(farmID)
        lock.unlock()
    }

    func count(for farmID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return farmIDs.count { $0 == farmID }
    }
}

private struct RecordZoneDeletionLayout {
    let recordID: CKRecord.ID
    let recordType: CKRecord.RecordType
}

/// CloudKit exposes fetched deletions as a value with read-only fields and no
/// public initializer. Keep this ABI adapter test-only and fail immediately if
/// a future SDK changes the value layout.
private func makeDeletion(
    operationID: UUID,
    zoneID: CKRecordZone.ID,
    recordType: CKRecord.RecordType
) -> CKDatabase.RecordZoneChange.Deletion {
    precondition(MemoryLayout<RecordZoneDeletionLayout>.size == MemoryLayout<CKDatabase.RecordZoneChange.Deletion>.size)
    precondition(MemoryLayout<RecordZoneDeletionLayout>.alignment == MemoryLayout<CKDatabase.RecordZoneChange.Deletion>.alignment)
    let recordID = CKRecord.ID(
        recordName: CloudRecordMapper().recordName(for: operationID),
        zoneID: zoneID
    )
    return unsafeBitCast(
        RecordZoneDeletionLayout(recordID: recordID, recordType: recordType),
        to: CKDatabase.RecordZoneChange.Deletion.self
    )
}
