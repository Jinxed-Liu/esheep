import CloudKit
import CoreImage
import CryptoKit
import SwiftData
import UIKit
import XCTest
@testable import eSheepNext

private actor CloudSyncHardDeadlineTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class CloudSyncHardDeadlineTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

@MainActor
final class CloudCollaborationTests: XCTestCase {
    func testCloudSyncHardDeadlineReturnsWithoutWaitingForUncooperativeTask() async throws {
        let gate = CloudSyncHardDeadlineTestGate()
        let cancellations = CloudSyncHardDeadlineTestCounter()
        let task = Task<Void, any Error> {
            await gate.wait()
        }
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            try await CloudSyncHardDeadline.wait(
                for: task,
                timeout: .milliseconds(50),
                onCancellation: cancellations.increment
            )
            XCTFail("不响应取消的同步任务必须触发硬超时")
        } catch let error as CloudSyncHardDeadlineError {
            XCTAssertEqual(error, .timedOut)
        }

        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(cancellations.value, 1)
        XCTAssertTrue(task.isCancelled)
        await gate.open()
        _ = await task.result
    }

    func testCloudSyncHardDeadlineDoesNotCancelCompletedTask() async throws {
        let cancellations = CloudSyncHardDeadlineTestCounter()
        let task = Task<Void, any Error> {}

        try await CloudSyncHardDeadline.wait(
            for: task,
            timeout: .milliseconds(50),
            onCancellation: cancellations.increment
        )
        try await Task.sleep(for: .milliseconds(75))

        XCTAssertEqual(cancellations.value, 0)
        XCTAssertFalse(task.isCancelled)
    }

    func testCompletedMigrationCardSeparatesFrozenBaselineFromCurrentSyncState() {
        let snapshot = MigrationUploadCardSnapshot(
            cloudState: .synced,
            baselineEntityCount: 21_251,
            confirmedBaselineCount: 21_251,
            baselinePhotoCount: 7,
            confirmedOperationCount: 21_270,
            pendingCount: 0,
            uploadingCount: 0,
            blockedCount: 0,
            rejectedCount: 0,
            activePhotoCount: 7,
            cloudPhotoAssetCount: 8,
            retainedHistoricalPhotoAssetCount: 1
        )

        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.progressCompletedCount, 21_251)
        XCTAssertEqual(snapshot.confirmedAfterBaselineCount, 19)
        XCTAssertEqual(snapshot.currentOutstandingCount, 0)
        XCTAssertEqual(snapshot.currentBlockedCount, 0)
        XCTAssertEqual(snapshot.activePhotoCount, 7)
        XCTAssertEqual(snapshot.cloudPhotoAssetCount, 8)
        XCTAssertEqual(snapshot.retainedHistoricalPhotoAssetCount, 1)
    }

    func testCloudRecordMapperRoundTripsOperationEnvelope() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = Data("{\"value\":1}".utf8)
        let unsigned = makeEnvelope(payload: payload, signature: Data())
        let signature = try privateKey.signature(for: unsigned.canonicalSigningData).rawRepresentation
        let envelope = makeEnvelope(payload: payload, signature: signature)
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(envelope.farmID), ownerName: CKCurrentUserDefaultName)

        let mapper = CloudRecordMapper()
        let record = mapper.operationRecord(from: envelope, zoneID: zoneID)
        let decoded = try mapper.operationEnvelope(from: record)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(record.recordID.recordName, "op_\(envelope.operationID.uuidString.lowercased())")

        let entityRecord = mapper.entityRecord(from: envelope, zoneID: zoneID)
        XCTAssertEqual(try mapper.operationEnvelope(from: entityRecord), envelope)
        XCTAssertEqual(entityRecord.recordType, CloudRecordType.farmEntity.rawValue)
        XCTAssertEqual(entityRecord.recordID.recordName, "entity_\(envelope.entityID.uuidString.lowercased())")
    }

    func testPhotoAssetSignatureV2AuthenticatesMetadataAtCloudKitMillisecondPrecision() {
        let farmID = UUID()
        let assetID = UUID()
        let accountID = UUID()
        let deviceID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600.123_1)
        func envelope(capturedAt: Date?, createdAt: Date) -> FarmAssetEnvelope {
            FarmAssetEnvelope(
                farmID: farmID,
                assetID: assetID,
                entityID: nil,
                sourceDigest: "source",
                payloadDigest: "payload",
                mimeType: "image/jpeg",
                pixelWidth: 1_024,
                pixelHeight: 768,
                capturedAt: capturedAt,
                byteCount: 42,
                createdAt: createdAt,
                modifiedByAccountID: accountID,
                modifiedByDeviceID: deviceID,
                capabilityCertificate: "test",
                signature: Data()
            )
        }
        let original = envelope(capturedAt: createdAt, createdAt: createdAt)
        let metadataChanged = envelope(
            capturedAt: createdAt.addingTimeInterval(60),
            createdAt: createdAt
        )
        XCTAssertEqual(original.canonicalSigningData, metadataChanged.canonicalSigningData)
        XCTAssertNotEqual(original.canonicalSigningDataV2, metadataChanged.canonicalSigningDataV2)

        let sameCloudKitMillisecond = envelope(
            capturedAt: createdAt.addingTimeInterval(0.000_1),
            createdAt: createdAt.addingTimeInterval(0.000_1)
        )
        XCTAssertEqual(original.canonicalSigningDataV2, sameCloudKitMillisecond.canonicalSigningDataV2)
    }

    func testPhotoAssetSignatureVerifierAcceptsV2AndNarrowLegacyFallback() throws {
        let privateKey = P256.Signing.PrivateKey()
        let farmID = UUID()
        let assetID = UUID()
        let accountID = UUID()
        let deviceID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600.123)
        func envelope(signature: Data, capturedAt: Date? = nil) -> FarmAssetEnvelope {
            FarmAssetEnvelope(
                farmID: farmID,
                assetID: assetID,
                entityID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
                sourceDigest: "source",
                payloadDigest: "payload",
                mimeType: "image/jpeg",
                pixelWidth: 1_024,
                pixelHeight: 768,
                capturedAt: capturedAt,
                byteCount: 42,
                createdAt: createdAt,
                modifiedByAccountID: accountID,
                modifiedByDeviceID: deviceID,
                capabilityCertificate: "test",
                signature: signature
            )
        }

        let unsigned = envelope(signature: Data())
        let v2 = envelope(signature: try privateKey.signature(for: unsigned.canonicalSigningDataV2).rawRepresentation)
        XCTAssertEqual(
            try FarmAssetSignatureVerifier.verify(
                envelope: v2,
                declaredVersion: 2,
                publicKeyX963: privateKey.publicKey.x963Representation
            ),
            .v2
        )

        let legacy = envelope(signature: try privateKey.signature(for: unsigned.canonicalSigningData).rawRepresentation)
        XCTAssertEqual(
            try FarmAssetSignatureVerifier.verify(
                envelope: legacy,
                declaredVersion: nil,
                publicKeyX963: privateKey.publicKey.x963Representation
            ),
            .legacyV1
        )
        XCTAssertEqual(
            try FarmAssetSignatureVerifier.verify(
                envelope: legacy,
                declaredVersion: 2,
                publicKeyX963: privateKey.publicKey.x963Representation
            ),
            .legacyV1,
            "旧客户端 changedKeys 更新会遗留 v2 marker，但完整 v1 签名仍必须独立成立"
        )

        let tamperedMetadata = envelope(
            signature: v2.signature,
            capturedAt: createdAt.addingTimeInterval(60)
        )
        XCTAssertThrowsError(try FarmAssetSignatureVerifier.verify(
            envelope: tamperedMetadata,
            declaredVersion: 2,
            publicKeyX963: privateKey.publicKey.x963Representation
        ))
    }

    func testPhotoAssetSignatureVersionParserRejectsExplicitInvalidValues() throws {
        let mapper = CloudRecordMapper()
        XCTAssertNil(
            try mapper.assetSignatureVersion(
                from: CKRecord(recordType: CloudRecordType.farmAsset.rawValue)
            )
        )

        for invalidValue: any CKRecordValue in [3 as CKRecordValue, 1.5 as CKRecordValue, "2" as CKRecordValue, true as CKRecordValue] {
            let record = CKRecord(recordType: CloudRecordType.farmAsset.rawValue)
            record[CloudRecordField.assetSignatureVersion] = invalidValue
            XCTAssertThrowsError(try mapper.assetSignatureVersion(from: record))
        }

        let record = CKRecord(recordType: CloudRecordType.farmAsset.rawValue)
        record[CloudRecordField.assetSignatureVersion] = 1 as CKRecordValue
        XCTAssertEqual(try mapper.assetSignatureVersion(from: record), 1)
        let v2Record = CKRecord(recordType: CloudRecordType.farmAsset.rawValue)
        v2Record[CloudRecordField.assetSignatureVersion] = 2 as CKRecordValue
        XCTAssertEqual(try mapper.assetSignatureVersion(from: v2Record), 2)
    }

    func testPhotoAssetAuthorizationUsesOnlyServerTimestamps() throws {
        let creation = Date(timeIntervalSince1970: 100)
        let modification = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(
            try CloudRecordMapper.assetAuthorizationDate(
                modificationDate: modification,
                creationDate: creation
            ),
            modification
        )
        XCTAssertEqual(
            try CloudRecordMapper.assetAuthorizationDate(
                modificationDate: nil,
                creationDate: creation
            ),
            creation
        )
        XCTAssertThrowsError(try CloudRecordMapper.assetAuthorizationDate(
            modificationDate: nil,
            creationDate: nil
        ))
    }

    func testLegacyPhotoLiveIngestRequeuesExistingUploadForV2Resign() {
        let farmID = UUID()
        let assetID = UUID()
        let asset = PhotoAssetRecord(
            id: assetID,
            farmID: farmID,
            sheepID: UUID(),
            legacySourceKey: "cloud:asset_\(assetID.uuidString.lowercased())",
            originalEarTag: "",
            relativePath: "FarmAssets/photo.jpg",
            sha256: "payload-v2",
            mimeType: "image/jpeg"
        )
        asset.isCloudAuthoritative = true
        let upload = CloudAssetTransfer(
            farmID: farmID,
            assetID: assetID,
            localRelativePath: "old.jpg",
            payloadDigest: "old-payload",
            byteCount: 1,
            direction: .upload,
            sourceDigest: "old-source"
        )
        upload.statusRawValue = CloudAssetTransferStatus.completed.rawValue
        upload.transferredByteCount = 1

        XCTAssertFalse(FarmPersistenceActor.prepareLegacyAssetForV2Resign(
            asset,
            recordName: "asset_\(assetID.uuidString.lowercased())",
            sourceDigest: "source-v2",
            payloadDigest: "payload-v2",
            byteCount: 42,
            uploadTransfers: [upload]
        ))
        XCTAssertFalse(asset.isCloudAuthoritative)
        XCTAssertEqual(upload.status, .pending)
        XCTAssertEqual(upload.transferredByteCount, 0)
        XCTAssertEqual(upload.localRelativePath, asset.relativePath)
        XCTAssertEqual(upload.payloadDigest, "payload-v2")
        XCTAssertEqual(upload.sourceDigest, "source-v2")
        XCTAssertNil(upload.nextRetryAt)

        XCTAssertTrue(FarmPersistenceActor.prepareLegacyAssetForV2Resign(
            asset,
            recordName: "asset_\(assetID.uuidString.lowercased())",
            sourceDigest: "source-v2",
            payloadDigest: "payload-v2",
            byteCount: 42,
            uploadTransfers: []
        ))
    }

    func testZoneWideShareUsesSystemRecordNameWithoutPublicAccessRequests() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(UUID()), ownerName: CKCurrentUserDefaultName)
        let share = CKShare(recordZoneID: zoneID)
        CloudShareInvitationPolicy.configureNewShare(share, farmName: "河湾牧场")
        XCTAssertEqual(share.recordID.zoneID, zoneID)
        XCTAssertEqual(share.recordID.recordName, CKRecordNameZoneWideShare)
        XCTAssertEqual(share.publicPermission, .none)
        XCTAssertFalse(share.allowsAccessRequests)
        XCTAssertEqual(share[CKShare.SystemFieldKey.title] as? String, "河湾牧场")
    }

    func testShareRecoveryOnlyRecreatesARecordCloudKitReportsMissing() {
        let missingRecord = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.unknownItem.rawValue
        )
        let networkFailure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.networkFailure.rawValue
        )
        let unrelatedError = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoSuchFile.rawValue
        )

        XCTAssertTrue(CloudShareRecoveryPolicy.shouldRecreate(after: missingRecord))
        XCTAssertFalse(CloudShareRecoveryPolicy.shouldRecreate(after: networkFailure))
        XCTAssertFalse(CloudShareRecoveryPolicy.shouldRecreate(after: unrelatedError))
    }

    func testTombstoneRecordUsesStableEntityRecordName() throws {
        let farmID = UUID()
        let entityID = UUID()
        let operationID = UUID()
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        let envelope = FarmTombstoneEnvelope(
            tombstoneID: UUID(),
            farmID: farmID,
            entityType: CloudEntityType.note.rawValue,
            entityID: entityID,
            revision: 2,
            deletedAt: .now,
            deletedByAccountID: UUID(),
            reason: "测试删除",
            operationID: operationID,
            restoresTombstoneID: nil
        )
        let mapper = CloudRecordMapper()
        let record = mapper.tombstoneRecord(envelope: envelope, certificate: "certificate", signature: Data([1, 2, 3]), zoneID: zoneID)
        XCTAssertEqual(record.recordID.recordName, mapper.tombstoneRecordName(for: entityID))
        XCTAssertEqual(record[CloudRecordField.operationID] as? String, operationID.uuidString.lowercased())
        XCTAssertNotNil(record[CloudRecordField.payload] as? Data)
    }

    func testOperationSecurityRejectsRoleWithoutCatalogCapability() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = Data("{}".utf8)
        var envelope = makeEnvelope(payload: payload, signature: Data(), entityType: CloudEntityType.feedIngredient.rawValue)
        let signature = try privateKey.signature(for: envelope.canonicalSigningData).rawRepresentation
        envelope = makeEnvelope(payload: payload, signature: signature, entityType: CloudEntityType.feedIngredient.rawValue)
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: envelope.modifiedByAccountID,
            farmID: envelope.farmID,
            deviceID: envelope.modifiedByDeviceID,
            role: .worker,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(envelope.modifiedAt.timeIntervalSince1970) - 10,
            exp: Int(envelope.modifiedAt.timeIntervalSince1970) + 300,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )

        XCTAssertThrowsError(try CloudOperationSecurity.validate(envelope: envelope, claims: claims, devicePublicKeyX963: privateKey.publicKey.x963Representation)) { error in
            XCTAssertEqual(error as? CloudContractError, .capabilityDenied)
        }
    }

    func testOperationSecurityAcceptsMatchingSignedProductionOperation() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = Data("{}".utf8)
        var envelope = makeEnvelope(payload: payload, signature: Data())
        envelope = makeEnvelope(payload: payload, signature: try privateKey.signature(for: envelope.canonicalSigningData).rawRepresentation)
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: envelope.modifiedByAccountID,
            farmID: envelope.farmID,
            deviceID: envelope.modifiedByDeviceID,
            role: .worker,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(envelope.modifiedAt.timeIntervalSince1970) - 10,
            exp: Int(envelope.modifiedAt.timeIntervalSince1970) + 300,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )

        XCTAssertNoThrow(try CloudOperationSecurity.validate(envelope: envelope, claims: claims, devicePublicKeyX963: privateKey.publicKey.x963Representation))
    }

    func testOperationSecurityUsesCloudWriteTimeForMigratedHistory() throws {
        let privateKey = P256.Signing.PrivateKey()
        let historicalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cloudWriteDate = historicalDate.addingTimeInterval(86_400)
        let payload = Data("{}".utf8)
        var envelope = makeEnvelope(payload: payload, signature: Data(), modifiedAt: historicalDate)
        envelope = makeEnvelope(
            payload: payload,
            signature: try privateKey.signature(for: envelope.canonicalSigningData).rawRepresentation,
            modifiedAt: historicalDate
        )
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: envelope.modifiedByAccountID,
            farmID: envelope.farmID,
            deviceID: envelope.modifiedByDeviceID,
            role: .worker,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(cloudWriteDate.timeIntervalSince1970) - 10,
            exp: Int(cloudWriteDate.timeIntervalSince1970) + 300,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )

        XCTAssertNoThrow(try CloudOperationSecurity.validate(
            envelope: envelope,
            claims: claims,
            devicePublicKeyX963: privateKey.publicKey.x963Representation,
            authorizationDate: cloudWriteDate
        ))
    }

    func testExistingIdenticalCloudRecordIsIdempotentSuccess() throws {
        let mapper = CloudRecordMapper()
        let envelope = makeEnvelope(payload: Data("{\"value\":1}".utf8), signature: Data([1]))
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(envelope.farmID), ownerName: CKCurrentUserDefaultName)
        let client = mapper.operationRecord(from: envelope, zoneID: zoneID)
        let server = mapper.operationRecord(from: envelope, zoneID: zoneID)

        XCTAssertTrue(CloudRecordIdempotency.equivalent(client: client, server: server))
        server[CloudRecordField.payloadDigest] = "different" as CKRecordValue
        XCTAssertFalse(CloudRecordIdempotency.equivalent(client: client, server: server))
    }

    func testEntityProjectionUpdateReusesFetchedServerRecordAndClearsDeletion() throws {
        let mapper = CloudRecordMapper()
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(UUID()), ownerName: CKCurrentUserDefaultName)
        let create = makeEnvelope(
            payload: Data("{\"value\":1}".utf8),
            signature: Data([1]),
            revision: 1,
            baseRevision: 0,
            operationID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            deletedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let server = mapper.entityRecord(from: create, zoneID: zoneID)
        let update = makeEnvelope(
            payload: Data("{\"value\":2}".utf8),
            signature: Data([2]),
            revision: 2,
            baseRevision: 1,
            operationID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            deletedAt: nil
        )

        let prepared = mapper.entityRecord(
            from: update,
            zoneID: zoneID,
            existingRecord: server,
            existingRecordIsVerifiedAncestor: true
        )

        XCTAssertTrue(prepared === server, "更新必须保留服务器 CKRecord 的 system fields/changeTag")
        XCTAssertEqual(try mapper.operationEnvelope(from: prepared), update)
        XCTAssertNil(prepared[CloudRecordField.deletedAt])
    }

    func testEntityProjectionDoesNotReuseDivergedServerRevision() throws {
        let mapper = CloudRecordMapper()
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(UUID()), ownerName: CKCurrentUserDefaultName)
        let remote = makeEnvelope(
            payload: Data("{\"remote\":true}".utf8),
            signature: Data([1]),
            revision: 2,
            baseRevision: 1,
            operationID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let server = mapper.entityRecord(from: remote, zoneID: zoneID)
        let local = makeEnvelope(
            payload: Data("{\"local\":true}".utf8),
            signature: Data([2]),
            revision: 2,
            baseRevision: 1,
            operationID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )

        let prepared = mapper.entityRecord(from: local, zoneID: zoneID, existingRecord: server)

        XCTAssertFalse(prepared === server, "分叉版本不得带着服务器 changeTag 静默覆盖")
        XCTAssertFalse(CloudEntityProjectionPolicy.canRetry(client: prepared, against: server))
        XCTAssertEqual(try mapper.operationEnvelope(from: server), remote)
    }

    func testEntityProjectionRaceAtBaseRevisionIsRetryable() {
        let mapper = CloudRecordMapper()
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(UUID()), ownerName: CKCurrentUserDefaultName)
        let serverEnvelope = makeEnvelope(
            payload: Data("{\"value\":1}".utf8),
            signature: Data([1]),
            revision: 1,
            baseRevision: 0
        )
        let localEnvelope = makeEnvelope(
            payload: Data("{\"value\":2}".utf8),
            signature: Data([2]),
            revision: 2,
            baseRevision: 1,
            operationID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        let server = mapper.entityRecord(from: serverEnvelope, zoneID: zoneID)
        let client = mapper.entityRecord(from: localEnvelope, zoneID: zoneID)

        XCTAssertTrue(CloudEntityProjectionPolicy.canRetry(
            client: client,
            against: server,
            ancestorIsVerified: true
        ))
    }

    func testEntityProjectionCanFastForwardOnlyThroughConfirmedLocalLineage() {
        let mapper = CloudRecordMapper()
        let farmID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let accountID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let entityID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let bootstrapID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let bridgeID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let candidateID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let bootstrapPayload = Data("{\"value\":1}".utf8)
        let bridgePayload = Data("{\"value\":2}".utf8)
        let candidatePayload = Data("{\"value\":3}".utf8)
        let bootstrap = DomainOperation(
            id: bootstrapID,
            farmID: farmID,
            accountID: accountID,
            kind: .bootstrapEntity,
            summary: "基线",
            entityType: CloudEntityType.weight.rawValue,
            entityID: entityID,
            baseRevision: 0,
            resultingRevision: 1,
            payload: bootstrapPayload
        )
        let bridge = DomainOperation(
            id: bridgeID,
            farmID: farmID,
            accountID: accountID,
            kind: .care,
            summary: "中间修改",
            entityType: CloudEntityType.weight.rawValue,
            entityID: entityID,
            baseRevision: 1,
            resultingRevision: 2,
            payload: bridgePayload
        )
        let candidate = DomainOperation(
            id: candidateID,
            farmID: farmID,
            accountID: accountID,
            kind: .care,
            summary: "最新修改",
            entityType: CloudEntityType.weight.rawValue,
            entityID: entityID,
            baseRevision: 2,
            resultingRevision: 3,
            payload: candidatePayload
        )
        let serverEnvelope = makeEnvelope(
            payload: bootstrapPayload,
            signature: Data([1]),
            revision: 1,
            baseRevision: 0,
            operationID: bootstrapID
        )
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        let server = mapper.entityRecord(from: serverEnvelope, zoneID: zoneID)
        let history = [bootstrap, bridge, candidate]

        XCTAssertFalse(CloudEntityProjectionLineage.isVerifiedAncestor(
            server: server,
            candidate: candidate,
            history: history,
            confirmedOperationRecordNames: []
        ))
        XCTAssertTrue(CloudEntityProjectionLineage.isVerifiedAncestor(
            server: server,
            candidate: candidate,
            history: history,
            confirmedOperationRecordNames: [mapper.recordName(for: bridgeID)]
        ))

        server[CloudRecordField.operationID] = UUID().uuidString.lowercased() as CKRecordValue
        XCTAssertFalse(CloudEntityProjectionLineage.isVerifiedAncestor(
            server: server,
            candidate: candidate,
            history: history,
            confirmedOperationRecordNames: [mapper.recordName(for: bridgeID)]
        ))
    }

    func testUpdatedEntityRequiresServerFetchButCreateDoesNot() async throws {
        let container = try AppSchema.makeContainer(
            name: "entity-server-fetch-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()
        let entityID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "测试牧场"))
        context.insert(CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        let create = DomainOperation(
            farmID: farmID,
            accountID: accountID,
            kind: .addSheep,
            summary: "建档",
            entityType: CloudEntityType.sheep.rawValue,
            entityID: entityID,
            baseRevision: 0,
            resultingRevision: 1
        )
        let createOutbox = OutboxItem(
            farmID: farmID,
            accountID: accountID,
            operationID: create.id,
            entityType: create.entityType,
            entityID: entityID,
            baseRevision: 0,
            payloadDigest: create.payloadDigest
        )
        context.insert(create)
        context.insert(createOutbox)
        try context.save()
        let mapper = CloudRecordMapper()
        let recordID = CKRecord.ID(
            recordName: mapper.entityRecordName(for: entityID),
            zoneID: CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        )
        let persistence = FarmPersistenceActor(container: container)
        let createRequiresFetch = try await persistence.entityRecordRequiresServerFetch(
            recordID,
            scope: .privateDatabase
        )
        XCTAssertFalse(createRequiresFetch)

        let update = DomainOperation(
            farmID: farmID,
            accountID: accountID,
            kind: .updateSheepProfile,
            summary: "更新",
            entityType: CloudEntityType.sheep.rawValue,
            entityID: entityID,
            baseRevision: 1,
            resultingRevision: 2
        )
        context.insert(update)
        context.insert(OutboxItem(
            farmID: farmID,
            accountID: accountID,
            operationID: update.id,
            entityType: update.entityType,
            entityID: entityID,
            baseRevision: 1,
            payloadDigest: update.payloadDigest
        ))
        try context.save()

        let updateRequiresFetch = try await persistence.entityRecordRequiresServerFetch(
            recordID,
            scope: .privateDatabase
        )
        XCTAssertTrue(updateRequiresFetch)
    }

    func testMigrationUploadProgressWatchdogStopsOnlyAfterConsecutiveNoProgress() {
        var watchdog = MigrationUploadProgressWatchdog(maximumConsecutiveNoProgressPasses: 3)

        XCTAssertFalse(watchdog.observe(scheduledRecordCount: 10, unconfirmedBefore: 100, unconfirmedAfter: 100))
        XCTAssertFalse(watchdog.observe(scheduledRecordCount: 10, unconfirmedBefore: 100, unconfirmedAfter: 101))
        XCTAssertTrue(watchdog.observe(scheduledRecordCount: 10, unconfirmedBefore: 101, unconfirmedAfter: 101))
        XCTAssertEqual(watchdog.consecutiveNoProgressPasses, 3)

        watchdog.reset()
        XCTAssertFalse(watchdog.observe(scheduledRecordCount: 10, unconfirmedBefore: 101, unconfirmedAfter: 90))
        XCTAssertEqual(watchdog.consecutiveNoProgressPasses, 0)
        XCTAssertFalse(watchdog.observe(scheduledRecordCount: 0, unconfirmedBefore: 90, unconfirmedAfter: 90))
        XCTAssertEqual(watchdog.consecutiveNoProgressPasses, 0)
    }

    func testPendingRecordIDsFiltersRetryTimeBeforeBatchLimit() async throws {
        let container = try AppSchema.makeContainer(
            name: "retry-eligibility-before-limit-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()
        context.insert(CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            databaseScope: .privateDatabase,
            state: .active
        ))

        let future = OutboxItem(farmID: farmID, accountID: accountID, operationID: UUID())
        future.statusRawValue = OutboxStatus.retryableFailure.rawValue
        future.createdAt = .now.addingTimeInterval(-120)
        future.nextRetryAt = .now.addingTimeInterval(3_600)
        let due = OutboxItem(farmID: farmID, accountID: accountID, operationID: UUID())
        due.statusRawValue = OutboxStatus.retryableFailure.rawValue
        due.createdAt = .now.addingTimeInterval(-60)
        due.nextRetryAt = .now.addingTimeInterval(-1)
        context.insert(future)
        context.insert(due)
        try context.save()

        let records = try await FarmPersistenceActor(container: container).pendingRecordIDs(
            maxOutboxItems: 1,
            farmID: farmID
        )
        let mapper = CloudRecordMapper()

        XCTAssertEqual(records.map { $0.0.recordName }, [mapper.recordName(for: due.operationID)])
    }

    func testPendingRecordIDsRestrictsAcceleratedBatchToMigrationFarm() async throws {
        let container = try AppSchema.makeContainer(
            name: "migration-farm-scoped-batch-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let migrationFarmID = UUID()
        let unrelatedFarmID = UUID()
        context.insert(CloudFarmBinding(
            farmID: migrationFarmID,
            ownerAccountID: accountID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(CloudFarmBinding(
            farmID: unrelatedFarmID,
            ownerAccountID: accountID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        let unrelated = OutboxItem(farmID: unrelatedFarmID, accountID: accountID, operationID: UUID())
        unrelated.createdAt = .now.addingTimeInterval(-120)
        let migration = OutboxItem(farmID: migrationFarmID, accountID: accountID, operationID: UUID())
        migration.createdAt = .now.addingTimeInterval(-60)
        context.insert(unrelated)
        context.insert(migration)
        try context.save()

        let records = try await FarmPersistenceActor(container: container).pendingRecordIDs(
            maxOutboxItems: 1,
            farmID: migrationFarmID
        )
        let mapper = CloudRecordMapper()

        XCTAssertEqual(records.map { $0.0.recordName }, [mapper.recordName(for: migration.operationID)])
        XCTAssertFalse(records.contains { $0.0.recordName == mapper.recordName(for: unrelated.operationID) })
    }

    func testCloudKitPendingRecordIDsNeverConsumeSupabaseOutbox() async throws {
        let container = try AppSchema.makeContainer(
            name: "provider-isolated-outbox-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        context.insert(CloudFarmBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        let iCloud = OutboxItem(
            farmID: farmID,
            accountID: accountID,
            operationID: UUID(),
            deliveryProvider: .iCloud
        )
        let supabase = OutboxItem(
            farmID: farmID,
            accountID: accountID,
            operationID: UUID(),
            deliveryProvider: .supabase,
            authorityGeneration: 1
        )
        context.insert(iCloud)
        context.insert(supabase)
        try context.save()

        let records = try await FarmPersistenceActor(container: container).pendingRecordIDs(
            maxOutboxItems: 2,
            farmID: farmID
        )
        let mapper = CloudRecordMapper()

        XCTAssertEqual(records.map { $0.0.recordName }, [mapper.recordName(for: iCloud.operationID)])
        XCTAssertFalse(records.contains {
            $0.0.recordName == mapper.recordName(for: supabase.operationID)
        })
    }

    func testBatchErrorDeferralDoesNotMutateAnotherFarm() async throws {
        let container = try AppSchema.makeContainer(
            name: "migration-farm-scoped-deferral-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let migrationFarmID = UUID()
        let unrelatedFarmID = UUID()
        let migration = OutboxItem(farmID: migrationFarmID, accountID: accountID, operationID: UUID())
        migration.statusRawValue = OutboxStatus.uploading.rawValue
        let unrelated = OutboxItem(farmID: unrelatedFarmID, accountID: accountID, operationID: UUID())
        unrelated.statusRawValue = OutboxStatus.awaitingConfirmation.rawValue
        context.insert(migration)
        context.insert(unrelated)
        try context.save()

        try await FarmPersistenceActor(container: container).deferUnresolvedUploadsAfterBatchError(
            NSError(domain: "test", code: 1),
            farmID: migrationFarmID
        )
        let refreshed = ModelContext(container)
        let values = try refreshed.fetch(FetchDescriptor<OutboxItem>())

        XCTAssertEqual(values.first(where: { $0.id == migration.id })?.status, .retryableFailure)
        XCTAssertEqual(values.first(where: { $0.id == unrelated.id })?.status, .awaitingConfirmation)
    }

    func testLegacyProjectionInsertCollisionIsRequeuedWithoutReopeningRealVersionConflict() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()
        let legacy = OutboxItem(farmID: farmID, accountID: accountID, operationID: UUID())
        legacy.statusRawValue = OutboxStatus.blockedConflict.rawValue
        legacy.errorMessage = "云端已有不同内容，已停止自动重试。record to insert already exists"
        let genuine = OutboxItem(farmID: farmID, accountID: accountID, operationID: UUID())
        genuine.statusRawValue = OutboxStatus.blockedConflict.rawValue
        genuine.errorMessage = "云端实体版本 2 与本地操作基线 1 不一致，已停止自动覆盖。"
        let lagging = OutboxItem(farmID: farmID, accountID: accountID, operationID: UUID())
        lagging.statusRawValue = OutboxStatus.blockedConflict.rawValue
        lagging.errorMessage = "云端实体版本 1 与本地操作基线 2 不一致，已停止自动覆盖。"
        let unverified = OutboxItem(farmID: farmID, accountID: accountID, operationID: UUID())
        unverified.statusRawValue = OutboxStatus.blockedConflict.rawValue
        unverified.errorMessage = "云端已有不同内容：实体版本 1 与本地操作基线 2 不属于同一已确认操作链。"
        context.insert(legacy)
        context.insert(genuine)
        context.insert(lagging)
        context.insert(unverified)
        try context.save()

        let count = try await FarmPersistenceActor(container: container).requeueBlockedConflicts(farmID: farmID)
        let refreshed = ModelContext(container)
        let values = try refreshed.fetch(FetchDescriptor<OutboxItem>())

        XCTAssertEqual(count, 2)
        XCTAssertEqual(values.first(where: { $0.id == legacy.id })?.status, .pending)
        XCTAssertEqual(values.first(where: { $0.id == genuine.id })?.status, .blockedConflict)
        XCTAssertEqual(values.first(where: { $0.id == lagging.id })?.status, .pending)
        XCTAssertEqual(values.first(where: { $0.id == unverified.id })?.status, .blockedConflict)
    }

    func testCommandPipelineStoresFullPayloadAndStableTarget() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()

        try FarmCommandService().execute(.createPen(name: "北一舍", note: "育肥"), in: FarmContext(accountID: accountID, farmID: farmID, role: .owner), context: context)

        let operation = try XCTUnwrap(context.fetch(FetchDescriptor<DomainOperation>()).first)
        let outbox = try XCTUnwrap(context.fetch(FetchDescriptor<OutboxItem>()).first)
        let pen = try XCTUnwrap(context.fetch(FetchDescriptor<PenRecord>()).first)
        let payload = try JSONDecoder.cloud.decode(FarmCommandCloudPayload.self, from: operation.payload)
        XCTAssertEqual(payload.strings["name"], "北一舍")
        XCTAssertEqual(operation.entityID, pen.id)
        XCTAssertEqual(operation.entityType, CloudEntityType.pen.rawValue)
        XCTAssertEqual(outbox.entityID, pen.id)
        XCTAssertEqual(outbox.payloadDigest, operation.payloadDigest)
    }

    func testRemoteApplyIsIdempotent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let targetID = UUID()
        let command = FarmCommand.createPen(name: "南一舍", note: "隔离")
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: targetID,
            entityType: CloudEntityType.pen.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        let service = RemoteDomainApplyService()
        XCTAssertEqual(try service.apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try service.apply(envelope, context: context), .duplicate)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PenRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PenRecord>()).first?.id, targetID)
    }

    func testRemoteFarmLocationCommandUpdatesTheExistingFarm() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let farm = FarmRecord(id: farmID, ownerAccountID: UUID(), name: "云端位置测试场")
        context.insert(farm)
        try context.save()

        let command = FarmCommand.updateFarmLocation(
            displayName: "西山牧场",
            latitude: 40.010_125,
            longitude: 116.289_321,
            addressSnapshot: "北京市海淀区",
            timeZoneIdentifier: "Asia/Shanghai",
            source: .mapSearch,
            horizontalAccuracyMeters: nil
        )
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let modifiedAt = Date(timeIntervalSince1970: 1_741_000_000)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: farmID,
            entityType: CloudEntityType.farm.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: modifiedAt,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(farm.locationSnapshot?.displayName, "西山牧场")
        XCTAssertEqual(farm.locationSnapshot?.latitude, 40.010_125)
        XCTAssertEqual(farm.locationSnapshot?.longitude, 116.289_321)
        XCTAssertEqual(farm.locationSnapshot?.source, .mapSearch)
        XCTAssertEqual(farm.locationUpdatedAt, modifiedAt)
    }

    func testRemoteBreedingProgramApplyIsIdempotentAndKeepsOrderedSteps() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let programID = UUID()
        let steps = [
            BreedingProgramStepDraft(id: UUID(), dayOffset: 0, action: "放栓"),
            BreedingProgramStepDraft(id: UUID(), dayOffset: 12, action: "撤栓并配种")
        ]
        let payload = try FarmCommandCloudPayloadEncoder.encode(
            .createBreedingProgram(name: "同期发情", createdAt: Date(timeIntervalSince1970: 1_741_000_000), steps: steps)
        )
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: programID,
            entityType: CloudEntityType.breedingProgram.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        let service = RemoteDomainApplyService()
        XCTAssertEqual(try service.apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try service.apply(envelope, context: context), .duplicate)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BreedingProgramRecord>()).first?.id, programID)
        let storedSteps = try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(storedSteps.map(\.id), steps.map(\.id))
        XCTAssertEqual(storedSteps.map(\.action), ["放栓", "撤栓并配种"])
        XCTAssertTrue(storedSteps.allSatisfy { $0.programID == programID })
    }

    func testStableDerivedUUIDDoesNotChange() {
        let namespace = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(StableCloudUUID.derived(namespace: namespace, name: "inventory-receipt"), StableCloudUUID.derived(namespace: namespace, name: "inventory-receipt"))
        XCTAssertNotEqual(StableCloudUUID.derived(namespace: namespace, name: "inventory-receipt"), StableCloudUUID.derived(namespace: namespace, name: "inventory-consumption"))
    }

    func testRemoteDuplicateEarTagBecomesConflict() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        context.insert(SheepRecord(farmID: farmID, earTag: "A-100", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now))
        try context.save()
        let payload = try FarmCommandCloudPayloadEncoder.encode(.addSheep(earTag: " a-100 ", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: .now, birthAt: nil, note: ""))
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: UUID(),
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .conflict(localRevision: 0))
        XCTAssertEqual(try context.fetch(FetchDescriptor<SheepRecord>()).count, 1)
    }

    func testRecoveryOperationReplaysCheckpointPayload() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let entityID = UUID()
        let sourcePayload = try FarmCommandCloudPayloadEncoder.encode(.createPen(name: "恢复舍", note: "checkpoint"))
        var recoveryPayload = FarmCommandCloudPayload(kind: .recoverEntity)
        recoveryPayload.identifiers = ["checkpointID": UUID(), "entityID": entityID]
        recoveryPayload.strings = ["entityType": CloudEntityType.pen.rawValue, "sourcePayloadDigest": CloudPayloadDigest.hex(for: sourcePayload)]
        recoveryPayload.integers = ["sourceRevision": 1]
        recoveryPayload.dataValues = ["resolvedPayload": sourcePayload]
        let encoded = try JSONEncoder.cloud.encode(recoveryPayload)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: CloudEntityType.pen.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: encoded,
            payloadDigest: CloudPayloadDigest.hex(for: encoded),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<PenRecord>()).first(where: { $0.id == entityID }))
        XCTAssertEqual(restored.name, "恢复舍")
    }

    func testInitialCheckpointResumeRequiresAnUnchangedRecoveryBoundary() {
        let watermark = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(FarmCheckpointResumePolicy.isCompatible(
            checkpointReason: FarmCheckpointReason.initialCloudSetup.rawValue,
            requestedReason: .initialCloudSetup,
            checkpointWatermark: watermark,
            currentWatermark: watermark,
            checkpointEntityCount: 100,
            currentEntityCount: 100,
            checkpointAssetCount: 7,
            currentAssetCount: 7,
            checkpointSecurityGeneration: 2,
            currentSecurityGeneration: 2
        ))
        XCTAssertFalse(FarmCheckpointResumePolicy.isCompatible(
            checkpointReason: FarmCheckpointReason.initialCloudSetup.rawValue,
            requestedReason: .initialCloudSetup,
            checkpointWatermark: watermark,
            currentWatermark: watermark.addingTimeInterval(1),
            checkpointEntityCount: 100,
            currentEntityCount: 100,
            checkpointAssetCount: 7,
            currentAssetCount: 7,
            checkpointSecurityGeneration: 2,
            currentSecurityGeneration: 2
        ))
        XCTAssertFalse(FarmCheckpointResumePolicy.isCompatible(
            checkpointReason: FarmCheckpointReason.initialCloudSetup.rawValue,
            requestedReason: .initialCloudSetup,
            checkpointWatermark: watermark,
            currentWatermark: watermark,
            checkpointEntityCount: 100,
            currentEntityCount: 100,
            checkpointAssetCount: 7,
            currentAssetCount: 8,
            checkpointSecurityGeneration: 2,
            currentSecurityGeneration: 2
        ))
    }

    func testCheckpointCreationRegistrySharesOneTaskPerFarm() async throws {
        let farmID = UUID()
        let expectedCheckpointID = UUID()
        let gate = CloudSyncHardDeadlineTestGate()
        let executions = CloudSyncHardDeadlineTestCounter()
        var registry = FarmCheckpointCreationTaskRegistry()

        let first = registry.acquire(farmID: farmID) {
            executions.increment()
            await gate.wait()
            return expectedCheckpointID
        }
        let second = registry.acquire(farmID: farmID) {
            executions.increment()
            return UUID()
        }

        XCTAssertTrue(first.startedNewTask)
        XCTAssertFalse(second.startedNewTask)
        XCTAssertTrue(registry.contains(farmID: farmID))
        await gate.open()
        let firstResult = try await first.task.value
        let secondResult = try await second.task.value
        XCTAssertEqual(firstResult, expectedCheckpointID)
        XCTAssertEqual(secondResult, expectedCheckpointID)
        XCTAssertEqual(executions.value, 1)

        registry.release(second, farmID: farmID)
        XCTAssertTrue(registry.contains(farmID: farmID))
        registry.release(first, farmID: farmID)
        XCTAssertFalse(registry.contains(farmID: farmID))
    }

    func testAutomaticCheckpointWaitsForLatestUnfinishedCheckpoint() async throws {
        let container = try AppSchema.makeContainer(
            name: "unfinished-checkpoint-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let createdAt = Date.now.addingTimeInterval(-3_600)
        let checkpoint = FarmCheckpointRecord(
            farmID: farmID,
            reasonRawValue: FarmCheckpointReason.operationThreshold.rawValue,
            operationWatermark: createdAt.addingTimeInterval(-3_600),
            manifestDigest: "digest",
            encryptedRelativePath: "interrupted.checkpoint",
            byteCount: 1,
            entityCount: 1,
            assetCount: 0,
            securityGeneration: 1
        )
        checkpoint.createdAt = createdAt
        context.insert(checkpoint)
        for index in 0..<100 {
            context.insert(CloudOperationReceipt(
                farmID: farmID,
                operationID: UUID(),
                recordName: "op_\(index)",
                serverChangeTag: nil,
                databaseScope: .privateDatabase,
                confirmedAt: createdAt.addingTimeInterval(60)
            ))
        }
        try context.save()

        let reason = try await FarmCheckpointActor(modelContainer: container).shouldCreateAutomaticCheckpoint(farmID: farmID)

        XCTAssertNil(reason)
    }

    func testOperationThresholdCountsReceiptsConfirmedAfterCheckpointCreation() async throws {
        let container = try AppSchema.makeContainer(
            name: "checkpoint-confirmation-boundary-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let createdAt = Date.now.addingTimeInterval(-3_600)
        let checkpoint = FarmCheckpointRecord(
            farmID: farmID,
            reasonRawValue: FarmCheckpointReason.scheduled.rawValue,
            operationWatermark: createdAt.addingTimeInterval(7_200),
            manifestDigest: "digest",
            encryptedRelativePath: "verified.checkpoint",
            byteCount: 1,
            entityCount: 1,
            assetCount: 0,
            securityGeneration: 1
        )
        checkpoint.createdAt = createdAt
        checkpoint.cloudRecordName = "checkpoint_\(checkpoint.id.uuidString.lowercased())"
        checkpoint.verifiedAt = createdAt.addingTimeInterval(1)
        context.insert(checkpoint)
        for index in 0..<100 {
            context.insert(CloudOperationReceipt(
                farmID: farmID,
                operationID: UUID(),
                recordName: "op_\(index)",
                serverChangeTag: nil,
                databaseScope: .privateDatabase,
                confirmedAt: createdAt.addingTimeInterval(60)
            ))
        }
        try context.save()

        let reason = try await FarmCheckpointActor(modelContainer: container).shouldCreateAutomaticCheckpoint(farmID: farmID)

        XCTAssertEqual(reason, .operationThreshold)
    }

    func testInterruptedCheckpointCleanupRemovesNewerUnverifiedRowsButPreservesVerified() async throws {
        let container = try AppSchema.makeContainer(
            name: "interrupted-checkpoint-cleanup-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "checkpoint-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let verifiedURL = directory.appending(path: "verified.checkpoint")
        let interruptedURL = directory.appending(path: "interrupted.checkpoint")
        try Data([1]).write(to: verifiedURL)
        try Data([2]).write(to: interruptedURL)
        let verifiedCreatedAt = Date.now.addingTimeInterval(-120)
        let verified = FarmCheckpointRecord(
            farmID: farmID,
            reasonRawValue: FarmCheckpointReason.scheduled.rawValue,
            operationWatermark: verifiedCreatedAt,
            manifestDigest: "verified",
            encryptedRelativePath: verifiedURL.path,
            byteCount: 1,
            entityCount: 1,
            assetCount: 0,
            securityGeneration: 1
        )
        verified.createdAt = verifiedCreatedAt
        verified.cloudRecordName = "checkpoint_\(verified.id.uuidString.lowercased())"
        verified.verifiedAt = verifiedCreatedAt.addingTimeInterval(1)
        let interrupted = FarmCheckpointRecord(
            farmID: farmID,
            reasonRawValue: FarmCheckpointReason.operationThreshold.rawValue,
            operationWatermark: verifiedCreatedAt,
            manifestDigest: "interrupted",
            encryptedRelativePath: interruptedURL.path,
            byteCount: 1,
            entityCount: 1,
            assetCount: 0,
            securityGeneration: 1
        )
        interrupted.createdAt = verifiedCreatedAt.addingTimeInterval(60)
        context.insert(verified)
        context.insert(interrupted)
        try context.save()

        let removed = try await FarmCheckpointActor(modelContainer: container).cleanupInterruptedCheckpoints(farmID: farmID)
        let remaining = try ModelContext(container).fetch(FetchDescriptor<FarmCheckpointRecord>())

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: verifiedURL.path))
        XCTAssertEqual(remaining.map(\.id), [verified.id])
    }

    func testCheckpointPruningKeepsRetainedAndNewerInterruptedRecoveryPoints() {
        let verifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(FarmCheckpointPrunePolicy.shouldRemove(
            isVerified: true,
            isRetained: true,
            createdAt: verifiedAt,
            latestVerifiedAt: verifiedAt
        ))
        XCTAssertTrue(FarmCheckpointPrunePolicy.shouldRemove(
            isVerified: true,
            isRetained: false,
            createdAt: verifiedAt.addingTimeInterval(-1),
            latestVerifiedAt: verifiedAt
        ))
        XCTAssertTrue(FarmCheckpointPrunePolicy.shouldRemove(
            isVerified: false,
            isRetained: false,
            createdAt: verifiedAt.addingTimeInterval(-1),
            latestVerifiedAt: verifiedAt
        ))
        XCTAssertFalse(FarmCheckpointPrunePolicy.shouldRemove(
            isVerified: false,
            isRetained: false,
            createdAt: verifiedAt.addingTimeInterval(1),
            latestVerifiedAt: verifiedAt
        ))
    }

    func testCheckpointKeepsAndReplaysFullPedigreeOperationHistory() throws {
        let sourceContainer = try AppSchema.makeContainer(name: "checkpoint-source-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let source = ModelContext(sourceContainer)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "恢复测试")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "恢复测试牧场")
        source.insert(account); source.insert(farm); try source.save()
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner)
        let commands = FarmCommandService()
        try commands.execute(.addSheep(earTag: "E001", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: .now, birthAt: nil, note: ""), in: farmContext, context: source)
        try commands.execute(.addSheep(earTag: "BR001", breed: "杜泊", sex: .ram, penID: nil, occurredAt: .now, birthAt: nil, note: ""), in: farmContext, context: source)
        try commands.execute(.addSheep(earTag: "L001", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: .now, birthAt: nil, note: ""), in: farmContext, context: source)
        let sourceSheep = try source.fetch(FetchDescriptor<SheepRecord>())
        let dam = try XCTUnwrap(sourceSheep.first { $0.earTag == "E001" })
        let ram = try XCTUnwrap(sourceSheep.first { $0.earTag == "BR001" })
        let child = try XCTUnwrap(sourceSheep.first { $0.earTag == "L001" })
        try commands.execute(.care(.setBreedingRam(sheepID: ram.id, isBreedingRam: true, expectedRevision: ram.revision)), in: farmContext, context: source)
        try commands.execute(.care(.updateSheepPedigree(.init(sheepID: child.id, damID: dam.id, sireID: ram.id, semenDonorID: nil, reason: "恢复点系谱", expectedRevision: child.revision))), in: farmContext, context: source)

        let operations = try source.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farm.id && $0.entityID != nil }
        let snapshots = try FarmCheckpointOperationHistory.snapshots(operations: operations, farmID: farm.id, context: source)
        XCTAssertEqual(snapshots.filter { $0.entityID == child.id }.count, 2, "恢复点必须同时保留建档与后续系谱命令")
        XCTAssertEqual(snapshots.filter { $0.entityID == ram.id }.count, 2, "恢复点必须同时保留建档与种公羊资格命令")

        let checkpointID = UUID()
        let manifest = FarmCheckpointManifest(schemaVersion: 2, checkpointID: checkpointID, farmID: farm.id, createdAt: .now, operationWatermark: .now, securityGeneration: 1, entities: snapshots, tombstones: [], assets: [], entityCounts: [:], entityDigests: [:])
        let envelopes = FarmCheckpointOperationHistory.sourceEnvelopes(snapshots: snapshots, manifest: manifest, accountID: account.effectiveAccountID)
        let targetContainer = try AppSchema.makeContainer(name: "checkpoint-target-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let target = ModelContext(targetContainer)
        target.insert(FarmRecord(id: farm.id, ownerAccountID: account.effectiveAccountID, name: farm.name)); try target.save()
        for envelope in CloudRebuildActor.sortedOperations(envelopes) {
            guard case .conflict = try RemoteDomainApplyService().apply(envelope, context: target) else { continue }
            XCTFail("恢复点完整历史不应产生冲突：\(envelope.operationID)")
        }

        let restored = try target.fetch(FetchDescriptor<SheepRecord>())
        let restoredRam = try XCTUnwrap(restored.first { $0.id == ram.id })
        let restoredChild = try XCTUnwrap(restored.first { $0.id == child.id })
        XCTAssertTrue(restoredRam.isBreedingRam)
        XCTAssertEqual(restoredChild.damID, dam.id)
        XCTAssertEqual(restoredChild.sireID, ram.id)
        XCTAssertEqual(try target.fetch(FetchDescriptor<PedigreeChangeRecord>()).filter { $0.sheepID == child.id }.count, 1)

        let nestedRecovery = try envelopes.map {
            try wrapRecovery(
                wrapRecovery($0, checkpointID: checkpointID, level: 1),
                checkpointID: checkpointID,
                level: 2
            )
        }
        XCTAssertNoThrow(try CloudRebuildBundleValidator.validateReferences(operations: nestedRecovery, assets: []))
        let nestedContainer = try AppSchema.makeContainer(name: "checkpoint-nested-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let nestedTarget = ModelContext(nestedContainer)
        nestedTarget.insert(FarmRecord(id: farm.id, ownerAccountID: account.effectiveAccountID, name: farm.name)); try nestedTarget.save()
        for envelope in CloudRebuildActor.sortedOperations(Array(nestedRecovery.reversed())) {
            guard case .conflict = try RemoteDomainApplyService().apply(envelope, context: nestedTarget) else { continue }
            XCTFail("嵌套恢复操作不应产生冲突：\(envelope.operationID)")
        }
        let nestedSheep = try nestedTarget.fetch(FetchDescriptor<SheepRecord>())
        XCTAssertTrue(try XCTUnwrap(nestedSheep.first { $0.id == ram.id }).isBreedingRam)
        XCTAssertEqual(try XCTUnwrap(nestedSheep.first { $0.id == child.id }).sireID, ram.id)
    }

    func testPhotoOptimizationCapsLongestEdgeAndProducesVerifiableDigest() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1000))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        }
        let sourceURL = FileManager.default.temporaryDirectory.appending(path: "photo-source-\(UUID().uuidString).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let optimized = try PhotoTransferActor.optimize(sourceURL: sourceURL, farmID: UUID(), assetID: UUID())
        defer { try? FileManager.default.removeItem(at: optimized.fileURL) }
        XCTAssertEqual(max(optimized.cloudWidth, optimized.cloudHeight), 2560)
        XCTAssertGreaterThan(max(optimized.sourceWidth, optimized.sourceHeight), 2560)
        XCTAssertEqual(optimized.sourceWidth / optimized.sourceHeight, 3)
        XCTAssertFalse(optimized.sourceDigest.isEmpty)
        XCTAssertFalse(optimized.payloadDigest.isEmpty)
        XCTAssertGreaterThan(optimized.byteCount, 0)
    }

    func testPhotoTransferResolvesFormalMigrationAssetsFromLegacySupportRoot() {
        let support = URL(fileURLWithPath: "/tmp/test-application-support", isDirectory: true)
        let migrated = PhotoTransferActor.localAssetURL(
            for: "MigrationAssets/farm/session/photo.bin",
            applicationSupportDirectory: support
        )
        let captured = PhotoTransferActor.localAssetURL(
            for: "CloudAssets/farm/photo.heic",
            applicationSupportDirectory: support
        )

        XCTAssertEqual(migrated.path, "/tmp/test-application-support/MigrationAssets/farm/session/photo.bin")
        XCTAssertEqual(captured.path, "/tmp/test-application-support/eSheepNext/CloudAssets/farm/photo.heic")
    }

    func testPhotoTransferRequeuesOnlyInterruptedInFlightStatesAfterRelaunch() {
        XCTAssertTrue(PhotoTransferInterruptionPolicy.shouldRequeue(status: .uploading))
        XCTAssertTrue(PhotoTransferInterruptionPolicy.shouldRequeue(status: .downloading))
        XCTAssertFalse(PhotoTransferInterruptionPolicy.shouldRequeue(status: .pending))
        XCTAssertFalse(PhotoTransferInterruptionPolicy.shouldRequeue(status: .failed))
        XCTAssertFalse(PhotoTransferInterruptionPolicy.shouldRequeue(status: .completed))
    }

    func testCertificateIsValidatedAtOperationTimeNotDownloadTime() {
        let issued = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: UUID(),
            farmID: UUID(),
            deviceID: UUID(),
            role: .worker,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(issued.timeIntervalSince1970),
            exp: Int(issued.addingTimeInterval(604_800).timeIntervalSince1970),
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )
        XCTAssertTrue(claims.isValid(at: issued.addingTimeInterval(60)))
        XCTAssertFalse(claims.isValid(at: issued.addingTimeInterval(604_801)))
    }

    func testProximityInvitationPayloadRoundTripsWithoutLosingJoinURL() throws {
        let payload = ProximityFarmInvitationPayload(
            farmName: "河湾牧场",
            role: .worker,
            url: try XCTUnwrap(URL(string: "https://www.icloud.com/share/example")),
            inviteCode: "AB12CD34",
            expiresAt: Date(timeIntervalSince1970: 1_700_086_400)
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(
            ProximityFarmInvitationPayload.self,
            from: encoded
        )

        XCTAssertEqual(decoded, payload)
    }

    func testRedeemedCodeCanReturnItsCloudShareURL() throws {
        let data = Data("""
        {
          "inviteID": "invite-1",
          "farmID": "33333333-3333-5333-8333-333333333333",
          "role": "worker",
          "membershipStatus": "pendingShareConfirmation",
          "shareURL": "https://www.icloud.com/share/example"
        }
        """.utf8)

        let response = try JSONDecoder().decode(
            WorkerRedeemResponse.self,
            from: data
        )

        XCTAssertEqual(
            response.shareURL?.absoluteString,
            "https://www.icloud.com/share/example"
        )
    }

    func testSharedFarmStaysHiddenUntilBindingMembershipAndRootAreReady() {
        let accountID = UUID()
        XCTAssertFalse(SharedFarmAdmissionPolicy.isLocallyOwnedForDisplay(
            farmOwnerAccountID: accountID,
            activeAccountID: accountID,
            bindingScope: .sharedDatabase
        ), "共享绑定必须优先于接纳阶段误写的临时 owner 字段")
        XCTAssertFalse(SharedFarmAdmissionPolicy.isReadyForDisplay(
            bindingScope: .sharedDatabase,
            bindingState: .active,
            farmName: SharedFarmAdmissionPolicy.pendingFarmName,
            membershipStatus: .active
        ))
        XCTAssertFalse(SharedFarmAdmissionPolicy.isReadyForDisplay(
            bindingScope: .sharedDatabase,
            bindingState: .requiresAccountReview,
            farmName: "吉昊羊场",
            membershipStatus: .active
        ))
        XCTAssertTrue(SharedFarmAdmissionPolicy.isPendingAdmission(
            bindingScope: .sharedDatabase,
            bindingState: .rebuildingCache,
            farmName: SharedFarmAdmissionPolicy.pendingFarmName,
            membershipStatus: .active
        ))
        XCTAssertTrue(SharedFarmAdmissionPolicy.isReadyForDisplay(
            bindingScope: .sharedDatabase,
            bindingState: .active,
            farmName: "吉昊羊场",
            membershipStatus: .active
        ))
    }

    func testSystemShareInvitationMessageContainsLinkAndInviteCode() throws {
        let package = FarmInvitationPackage(
            inviteID: "invite-1",
            farmID: UUID(),
            farmName: "河湾牧场",
            role: .worker,
            url: try XCTUnwrap(URL(string: "https://www.icloud.com/share/example")),
            inviteCode: "AB12CD34",
            shareParticipantID: nil,
            expiresAt: Date(timeIntervalSince1970: 1_700_086_400)
        )

        XCTAssertFalse(package.usesOneTimeURL)
        XCTAssertTrue(package.message.contains(package.url.absoluteString))
        XCTAssertTrue(package.message.contains(package.inviteCode))
        XCTAssertTrue(package.message.contains("输入邀请码"))
        XCTAssertTrue(package.message.contains("批准加入"))
    }

    func testSystemShareInvitationDeepLinkRoundTripsCodeAndPrivateShareURL() throws {
        let shareURL = try XCTUnwrap(URL(string: "https://www.icloud.com/share/example"))
        let package = FarmInvitationPackage(
            inviteID: "invite-1",
            farmID: UUID(),
            farmName: "河湾牧场",
            role: .worker,
            url: shareURL,
            inviteCode: "AB12CD34",
            shareParticipantID: nil,
            expiresAt: Date(timeIntervalSince1970: 1_700_086_400)
        )

        let pending = try XCTUnwrap(PendingFarmInvitation(url: package.joinURL))

        XCTAssertEqual(pending.code, package.inviteCode)
        XCTAssertEqual(pending.shareURL, shareURL)
    }

    func testInvitationQRCodeGeneratorCreatesAReadableSizedImage() throws {
        let invitationURL = "esheep://invite?code=AB12CD34&share=https%3A%2F%2Fwww.icloud.com%2Fshare%2Fexample"
        let image = try XCTUnwrap(
            FarmInvitationQRCodeGenerator.image(
                for: invitationURL,
                dimension: 900
            )
        )

        XCTAssertGreaterThanOrEqual(image.size.width, 800)
        XCTAssertEqual(image.size.width, image.size.height)
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let input = CIImage(cgImage: try XCTUnwrap(image.cgImage))
        let feature = try XCTUnwrap(
            detector.features(in: input).compactMap { $0 as? CIQRCodeFeature }.first
        )
        XCTAssertEqual(feature.messageString, invitationURL)
    }

    func testOneTimeInvitationParticipantIsPreparedOnMainActor() throws {
        try XCTSkipIf(
            CloudOneTimeInvitationRuntimePolicy.requiresSystemSharingFallback,
            "iOS 27 Beta traps inside CloudKit; the system-sharing fallback is covered separately"
        )
        XCTAssertTrue(Thread.isMainThread)
        let share = CKShare(
            recordZoneID: CKRecordZone.ID(
                zoneName: "test-one-time-invitation",
                ownerName: CKCurrentUserDefaultName
            )
        )

        let participant = CloudOneTimeInvitationBuilder.prepareParticipant(on: share)

        XCTAssertFalse(participant.participantID.isEmpty)
        XCTAssertEqual(participant.permission, .readWrite)
        XCTAssertTrue(
            share.participants.contains(where: {
                $0.participantID == participant.participantID
            })
        )
    }

    func testIOS27UsesSystemSharingFallbackForCloudKitTrap() {
        XCTAssertFalse(
            CloudOneTimeInvitationRuntimePolicy.requiresSystemSharingFallback(
                for: OperatingSystemVersion(
                    majorVersion: 26,
                    minorVersion: 1,
                    patchVersion: 0
                )
            )
        )
        XCTAssertTrue(
            CloudOneTimeInvitationRuntimePolicy.requiresSystemSharingFallback(
                for: OperatingSystemVersion(
                    majorVersion: 27,
                    minorVersion: 0,
                    patchVersion: 0
                )
            )
        )
        XCTAssertFalse(
            CloudOneTimeInvitationRuntimePolicy.requiresSystemSharingFallback(
                for: OperatingSystemVersion(
                    majorVersion: 28,
                    minorVersion: 0,
                    patchVersion: 0
                )
            )
        )
    }

    private func makeEnvelope(
        payload: Data,
        signature: Data,
        entityType: String = CloudEntityType.weight.rawValue,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        revision: Int = 1,
        baseRevision: Int = 0,
        operationID: UUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        deletedAt: Date? = nil
    ) -> CloudOperationEnvelope {
        CloudOperationEnvelope(
            farmID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            entityID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            entityType: entityType,
            schemaVersion: 2,
            revision: revision,
            baseRevision: baseRevision,
            operationID: operationID,
            modifiedAt: modifiedAt,
            modifiedByAccountID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            modifiedByDeviceID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test-certificate",
            operationSignature: signature,
            deletedAt: deletedAt
        )
    }

    private func wrapRecovery(_ source: CloudOperationEnvelope, checkpointID: UUID, level: Int) throws -> CloudOperationEnvelope {
        var payload = FarmCommandCloudPayload(kind: .recoverEntity)
        payload.identifiers = ["checkpointID": checkpointID, "entityID": source.entityID]
        payload.strings = ["entityType": source.entityType, "sourcePayloadDigest": source.payloadDigest]
        payload.integers = ["sourceRevision": source.revision]
        payload.dataValues = ["resolvedPayload": source.payload]
        let encoded = try JSONEncoder.cloud.encode(payload)
        return CloudOperationEnvelope(
            farmID: source.farmID,
            entityID: source.entityID,
            entityType: source.entityType,
            schemaVersion: 2,
            revision: source.revision + 1,
            baseRevision: source.revision,
            operationID: StableCloudUUID.derived(namespace: checkpointID, name: "nested-\(level)-\(source.operationID.uuidString.lowercased())"),
            modifiedAt: source.modifiedAt,
            modifiedByAccountID: source.modifiedByAccountID,
            modifiedByDeviceID: source.modifiedByDeviceID,
            payload: encoded,
            payloadDigest: CloudPayloadDigest.hex(for: encoded),
            capabilityCertificate: source.capabilityCertificate,
            operationSignature: source.operationSignature,
            deletedAt: source.deletedAt
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            FarmRecord.self,
            PenRecord.self,
            SheepRecord.self,
            WeightRecord.self,
            WeaningRecord.self,
            BreedingProgramRecord.self,
            BreedingProgramStepRecord.self,
            TransferRecord.self,
            RemovalRecord.self,
            ProductionBatchRecord.self,
            BatchMembershipRecord.self,
            DailyPenCountRecord.self,
            FeedIngredientRecord.self,
            FeedRecipeRecord.self,
            FeedRecipeComponentRecord.self,
            FeedRecord.self,
            FeedRecordLine.self,
            InventoryLotRecord.self,
            InventoryTransactionRecord.self,
            HealthRecord.self,
            ReproductionRecord.self,
            SemenRecord.self,
            NoteRecord.self,
            DomainOperation.self,
            OutboxItem.self,
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
}

private extension JSONDecoder {
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
