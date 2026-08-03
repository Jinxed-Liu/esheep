import Foundation
import CloudKit
import CryptoKit
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class CloudRebuildTests: XCTestCase {
    func testVerifiedReplacementPreservesPendingOutboxAndReplacesOnlyFarmCache() async throws {
        let container = try AppSchema.makeContainer(name: "rebuild-test", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let otherFarmID = UUID()
        let ownerID = UUID()
        let farm = FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存")
        context.insert(farm)
        context.insert(FarmRecord(id: otherFarmID, ownerAccountID: ownerID, name: "其他牧场"))
        context.insert(PenRecord(farmID: farmID, name: "应被替换"))
        context.insert(PenRecord(farmID: otherFarmID, name: "必须保留"))
        let pendingID = UUID()
        context.insert(OutboxItem(farmID: farmID, accountID: ownerID, operationID: pendingID))
        try context.save()

        let operation = try makeOperation(farmID: farmID, command: .createPen(name: "云端圈舍", note: "已确认"), entityType: .pen)
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation])
        let result = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(using: bundle)

        let verify = ModelContext(container)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.map(\.name), ["云端圈舍"])
        XCTAssertEqual(try verify.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == otherFarmID }.map(\.name), ["必须保留"])
        XCTAssertEqual(try verify.fetch(FetchDescriptor<OutboxItem>()).filter { $0.operationID == pendingID }.count, 1)
        XCTAssertEqual(result.preservedOutboxCount, 1)
        XCTAssertEqual(result.appliedOperationCount, 1)
    }

    func testReplacementRemovesLocalPedigreeRowsMissingFromAuthoritativeBundle() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-purges-missing-pedigree-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let otherFarmID = UUID()
        let ownerID = UUID()
        let localDonor = SemenDonorRecord(
            farmID: farmID,
            name: "仅本机供体",
            breed: "杜泊"
        )
        let otherFarmDonor = SemenDonorRecord(
            farmID: otherFarmID,
            name: "其他牧场供体",
            breed: "杜泊"
        )
        let localPedigreeChange = PedigreeChangeRecord(
            farmID: farmID,
            sheepID: UUID(),
            beforeDamID: nil,
            afterDamID: nil,
            beforeSireID: nil,
            afterSireID: nil,
            beforeSemenDonorID: nil,
            afterSemenDonorID: localDonor.id,
            beforeDamSourceRawValue: nil,
            afterDamSourceRawValue: nil,
            beforeSireSourceRawValue: nil,
            afterSireSourceRawValue: PaternalIdentitySource.semenDonor.rawValue,
            reason: "仅存在于旧缓存",
            changedByAccountID: ownerID,
            sheepRevision: 2
        )
        let otherFarmPedigreeChange = PedigreeChangeRecord(
            farmID: otherFarmID,
            sheepID: UUID(),
            beforeDamID: nil,
            afterDamID: nil,
            beforeSireID: nil,
            afterSireID: nil,
            beforeSemenDonorID: nil,
            afterSemenDonorID: otherFarmDonor.id,
            beforeDamSourceRawValue: nil,
            afterDamSourceRawValue: nil,
            beforeSireSourceRawValue: nil,
            afterSireSourceRawValue: PaternalIdentitySource.semenDonor.rawValue,
            reason: "其他牧场必须保留",
            changedByAccountID: ownerID,
            sheepRevision: 2
        )
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        context.insert(FarmRecord(id: otherFarmID, ownerAccountID: ownerID, name: "其他牧场"))
        context.insert(localDonor)
        context.insert(otherFarmDonor)
        context.insert(localPedigreeChange)
        context.insert(otherFarmPedigreeChange)
        try context.save()

        let operation = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "云端圈舍", note: ""),
            entityType: .pen
        )
        _ = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(
            using: makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation])
        )

        let verify = ModelContext(container)
        let donors = try verify.fetch(FetchDescriptor<SemenDonorRecord>())
        let pedigreeChanges = try verify.fetch(FetchDescriptor<PedigreeChangeRecord>())
        XCTAssertTrue(donors.filter { $0.farmID == farmID }.isEmpty)
        XCTAssertTrue(pedigreeChanges.filter { $0.farmID == farmID }.isEmpty)
        XCTAssertEqual(donors.filter { $0.farmID == otherFarmID }.map(\.id), [otherFarmDonor.id])
        XCTAssertEqual(
            pedigreeChanges.filter { $0.farmID == otherFarmID }.map(\.id),
            [otherFarmPedigreeChange.id]
        )
    }

    func testReplacementConfirmsPendingOperationAlreadyPresentInAuthoritativeBundle() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-confirm-crash-window-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        let authoritative = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "已上云圈舍", note: ""),
            entityType: .pen
        )
        let local = DomainOperation(
            id: authoritative.operationID,
            farmID: farmID,
            accountID: authoritative.modifiedByAccountID,
            kind: .createPen,
            occurredAt: authoritative.modifiedAt,
            summary: "保存成功但回执未落盘",
            entityType: authoritative.entityType,
            entityID: authoritative.entityID,
            baseRevision: authoritative.baseRevision,
            resultingRevision: authoritative.revision,
            payload: authoritative.payload
        )
        local.schemaVersion = authoritative.schemaVersion
        local.modifiedByDeviceID = authoritative.modifiedByDeviceID
        local.capabilityCertificate = authoritative.capabilityCertificate
        local.operationSignature = authoritative.operationSignature
        let outbox = OutboxItem(
            farmID: farmID,
            accountID: authoritative.modifiedByAccountID,
            operationID: authoritative.operationID,
            entityType: authoritative.entityType,
            entityID: authoritative.entityID,
            baseRevision: authoritative.baseRevision,
            payloadDigest: authoritative.payloadDigest
        )
        context.insert(local)
        context.insert(outbox)
        try context.save()

        let result = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(
            using: makeBundle(farmID: farmID, ownerID: ownerID, operations: [authoritative])
        )

        let verify = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(try verify.fetch(FetchDescriptor<OutboxItem>()).first).status, .confirmed)
        XCTAssertEqual(result.preservedOutboxCount, 0)
        XCTAssertTrue(try verify.fetch(FetchDescriptor<SyncConflictRecord>()).isEmpty)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.count, 1)
    }

    func testReplacementBlocksConflictingPendingOperationWithoutLoopingFullRebuild() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-block-pending-conflict-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let penID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        let authoritative = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "云端权威圈舍", note: ""),
            entityType: .pen,
            entityID: penID
        )
        let pendingPayload = try FarmCommandCloudPayloadEncoder.encode(
            .updatePen(penID: penID, name: "本机冲突名称", note: "")
        )
        let pending = DomainOperation(
            farmID: farmID,
            accountID: ownerID,
            kind: .updatePen,
            summary: "本机未确认更新",
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            baseRevision: 0,
            resultingRevision: 1,
            payload: pendingPayload
        )
        let outbox = OutboxItem(
            farmID: farmID,
            accountID: ownerID,
            operationID: pending.id,
            entityType: pending.entityType,
            entityID: penID,
            baseRevision: pending.baseRevision,
            payloadDigest: pending.payloadDigest
        )
        context.insert(pending)
        context.insert(outbox)
        try context.save()

        let result = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(
            using: makeBundle(farmID: farmID, ownerID: ownerID, operations: [authoritative])
        )

        let verify = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(try verify.fetch(FetchDescriptor<PenRecord>()).first).name, "云端权威圈舍")
        XCTAssertEqual(try XCTUnwrap(try verify.fetch(FetchDescriptor<OutboxItem>()).first).status, .blockedConflict)
        XCTAssertEqual(result.preservedOutboxCount, 1)
        let conflict = try XCTUnwrap(try verify.fetch(FetchDescriptor<SyncConflictRecord>()).first)
        XCTAssertEqual(conflict.reasonCode, "rebuildPendingBaseRevisionMismatch")
        XCTAssertEqual(conflict.statusRawValue, SyncConflictStatus.unresolved.rawValue)

        _ = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(
            using: makeBundle(farmID: farmID, ownerID: ownerID, operations: [authoritative])
        )
        let verifyAgain = ModelContext(container)
        XCTAssertEqual(
            try verifyAgain.fetch(FetchDescriptor<SyncConflictRecord>()).filter {
                $0.reasonCode == "rebuildPendingBaseRevisionMismatch"
            }.count,
            1,
            "blocked Outbox 的未解决冲突证据必须跨重复重建保留"
        )
    }

    func testReplacementReplaysPendingRevisionChainBeforeWallClockOrder() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-pending-revision-order-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let penID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        let authoritative = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "云端圈舍", note: ""),
            entityType: .pen,
            entityID: penID
        )
        let laterWallClock = Date(timeIntervalSince1970: 1_800_000_100)
        let earlierWallClock = laterWallClock.addingTimeInterval(-60)
        let revisionTwoPayload = try FarmCommandCloudPayloadEncoder.encode(
            .updatePen(penID: penID, name: "本机 rev2", note: "")
        )
        let revisionTwo = DomainOperation(
            farmID: farmID,
            accountID: ownerID,
            kind: .updatePen,
            occurredAt: laterWallClock,
            summary: "本机 rev2",
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            baseRevision: 1,
            resultingRevision: 2,
            payload: revisionTwoPayload
        )
        let revisionThreePayload = try FarmCommandCloudPayloadEncoder.encode(
            .updatePen(penID: penID, name: "本机 rev3", note: "最终" )
        )
        let revisionThree = DomainOperation(
            farmID: farmID,
            accountID: ownerID,
            kind: .updatePen,
            occurredAt: earlierWallClock,
            summary: "本机 rev3（设备时钟回拨）",
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            baseRevision: 2,
            resultingRevision: 3,
            payload: revisionThreePayload
        )
        for operation in [revisionTwo, revisionThree] {
            context.insert(operation)
            context.insert(OutboxItem(
                farmID: farmID,
                accountID: ownerID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: penID,
                baseRevision: operation.baseRevision,
                payloadDigest: operation.payloadDigest
            ))
        }
        try context.save()

        _ = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(
            using: makeBundle(farmID: farmID, ownerID: ownerID, operations: [authoritative])
        )

        let verify = ModelContext(container)
        let pen = try XCTUnwrap(try verify.fetch(FetchDescriptor<PenRecord>()).first { $0.id == penID })
        XCTAssertEqual(pen.revision, 3)
        XCTAssertEqual(pen.name, "本机 rev3")
        XCTAssertEqual(pen.note, "最终")
        XCTAssertTrue(try verify.fetch(FetchDescriptor<SyncConflictRecord>()).isEmpty)
        XCTAssertEqual(
            Set(try verify.fetch(FetchDescriptor<OutboxItem>()).map(\.status)),
            Set([.pending])
        )
    }

    func testReplacementPreservesUnsyncedLocalPhotoAndUploadTransfer() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-preserve-local-photo-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let assetID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        let localPhoto = PhotoAssetRecord(
            id: assetID,
            farmID: farmID,
            sheepID: nil,
            legacySourceKey: "local:\(assetID.uuidString.lowercased())",
            originalEarTag: "",
            relativePath: "CloudAssets/local-unsynced.jpg",
            sha256: "local-photo-digest",
            mimeType: "image/jpeg"
        )
        localPhoto.isCloudAuthoritative = false
        let upload = CloudAssetTransfer(
            farmID: farmID,
            assetID: assetID,
            localRelativePath: localPhoto.relativePath,
            payloadDigest: localPhoto.sha256,
            byteCount: 1_024,
            direction: .upload
        )
        context.insert(localPhoto)
        context.insert(upload)
        try context.save()
        let operation = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "云端圈舍", note: ""),
            entityType: .pen
        )

        _ = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(
            using: makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation])
        )

        let verify = ModelContext(container)
        let restoredPhoto = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<PhotoAssetRecord>()).first { $0.id == assetID }
        )
        XCTAssertEqual(restoredPhoto.relativePath, "CloudAssets/local-unsynced.jpg")
        XCTAssertFalse(restoredPhoto.isCloudAuthoritative)
        let retainedTransfer = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<CloudAssetTransfer>()).first { $0.assetID == assetID }
        )
        XCTAssertEqual(retainedTransfer.direction, .upload)
        XCTAssertEqual(retainedTransfer.status, .pending)
    }

    func testReplacementPreservesPendingMetadataEditOnCloudPhoto() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-preserve-photo-metadata-edit-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let assetID = UUID()
        let sessionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600)
        let cloudCapturedAt = createdAt.addingTimeInterval(60)
        let localCapturedAt = createdAt.addingTimeInterval(120)
        let fileData = Data("cloud-photo".utf8)
        let digest = CloudPayloadDigest.hex(for: fileData)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let workspace = support.appending(
            path: "CloudRebuild/\(sessionID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        let assetDirectory = workspace.appending(path: "Assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        try fileData.write(to: assetDirectory.appending(path: "cloud-photo.jpg"), options: .atomic)
        defer { try? FileManager.default.removeItem(at: workspace) }

        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        let local = PhotoAssetRecord(
            id: assetID,
            farmID: farmID,
            sheepID: nil,
            legacySourceKey: "cloud:asset_\(assetID.uuidString.lowercased())",
            originalEarTag: "",
            relativePath: "CloudAssets/local-edited-photo.jpg",
            sha256: digest,
            mimeType: "image/jpeg"
        )
        local.sourceSHA256 = digest
        local.cloudPixelWidth = 1_024
        local.cloudPixelHeight = 768
        local.capturedAt = localCapturedAt
        local.cloudRecordName = "asset_\(assetID.uuidString.lowercased())"
        local.isCloudAuthoritative = true
        local.createdAt = createdAt
        let upload = CloudAssetTransfer(
            farmID: farmID,
            assetID: assetID,
            localRelativePath: local.relativePath,
            payloadDigest: digest,
            byteCount: Int64(fileData.count),
            direction: .upload,
            sourceDigest: digest
        )
        context.insert(local)
        context.insert(upload)
        try context.save()

        let cloudEnvelope = FarmAssetEnvelope(
            farmID: farmID,
            assetID: assetID,
            entityID: nil,
            sourceDigest: digest,
            payloadDigest: digest,
            mimeType: "image/jpeg",
            pixelWidth: 1_024,
            pixelHeight: 768,
            capturedAt: cloudCapturedAt,
            byteCount: Int64(fileData.count),
            createdAt: createdAt,
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            capabilityCertificate: "test",
            signature: Data()
        )
        let cloudAsset = CloudRebuildAssetSnapshot(
            envelope: cloudEnvelope,
            relativePath: "Assets/cloud-photo.jpg",
            cloudRecordName: "asset_\(assetID.uuidString.lowercased())"
        )
        let operation = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "云端圈舍", note: ""),
            entityType: .pen
        )

        _ = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(
            using: makeBundle(
                sessionID: sessionID,
                farmID: farmID,
                ownerID: ownerID,
                operations: [operation],
                assets: [cloudAsset]
            )
        )

        let verify = ModelContext(container)
        let restored = try XCTUnwrap(try verify.fetch(FetchDescriptor<PhotoAssetRecord>()).first { $0.id == assetID })
        XCTAssertEqual(restored.capturedAt, localCapturedAt)
        XCTAssertEqual(restored.relativePath, "CloudAssets/local-edited-photo.jpg")
        XCTAssertFalse(restored.isCloudAuthoritative)
        let retained = try XCTUnwrap(try verify.fetch(FetchDescriptor<CloudAssetTransfer>()).first { $0.assetID == assetID })
        XCTAssertEqual(retained.status, .pending)
    }

    func testRepeatedReplacementPreservesOnePendingMetadataEditForSameCloudPhotoID() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-repeat-photo-metadata-edit-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let assetID = UUID()
        let sessionIDs = [UUID(), UUID()]
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600)
        let cloudCapturedAt = createdAt.addingTimeInterval(60)
        let localCapturedAt = createdAt.addingTimeInterval(120)
        let fileData = Data("cloud-photo-repeat".utf8)
        let digest = CloudPayloadDigest.hex(for: fileData)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let workspaces = try sessionIDs.map { sessionID in
            let workspace = support.appending(
                path: "CloudRebuild/\(sessionID.uuidString.lowercased())",
                directoryHint: .isDirectory
            )
            let assetDirectory = workspace.appending(path: "Assets", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            try fileData.write(to: assetDirectory.appending(path: "cloud-photo.jpg"), options: .atomic)
            return workspace
        }
        defer {
            for workspace in workspaces {
                try? FileManager.default.removeItem(at: workspace)
            }
        }

        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        let local = PhotoAssetRecord(
            id: assetID,
            farmID: farmID,
            sheepID: nil,
            legacySourceKey: "cloud:asset_\(assetID.uuidString.lowercased())",
            originalEarTag: "",
            relativePath: "CloudAssets/local-edited-photo-repeat.jpg",
            sha256: digest,
            mimeType: "image/jpeg"
        )
        local.sourceSHA256 = digest
        local.cloudPixelWidth = 1_024
        local.cloudPixelHeight = 768
        local.capturedAt = localCapturedAt
        local.cloudRecordName = "asset_\(assetID.uuidString.lowercased())"
        local.isCloudAuthoritative = true
        local.createdAt = createdAt
        let upload = CloudAssetTransfer(
            farmID: farmID,
            assetID: assetID,
            localRelativePath: local.relativePath,
            payloadDigest: digest,
            byteCount: Int64(fileData.count),
            direction: .upload,
            sourceDigest: digest
        )
        context.insert(local)
        context.insert(upload)
        try context.save()

        let cloudEnvelope = FarmAssetEnvelope(
            farmID: farmID,
            assetID: assetID,
            entityID: nil,
            sourceDigest: digest,
            payloadDigest: digest,
            mimeType: "image/jpeg",
            pixelWidth: 1_024,
            pixelHeight: 768,
            capturedAt: cloudCapturedAt,
            byteCount: Int64(fileData.count),
            createdAt: createdAt,
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            capabilityCertificate: "test",
            signature: Data()
        )
        let cloudAsset = CloudRebuildAssetSnapshot(
            envelope: cloudEnvelope,
            relativePath: "Assets/cloud-photo.jpg",
            cloudRecordName: "asset_\(assetID.uuidString.lowercased())"
        )
        let operation = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "云端圈舍", note: ""),
            entityType: .pen
        )
        let persistence = FarmPersistenceActor(container: container)

        for sessionID in sessionIDs {
            _ = try await persistence.replaceConfirmedFarmCache(
                using: makeBundle(
                    sessionID: sessionID,
                    farmID: farmID,
                    ownerID: ownerID,
                    operations: [operation],
                    assets: [cloudAsset]
                )
            )

            let verify = ModelContext(container)
            let farmPhotos = try verify.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == farmID }
            XCTAssertEqual(farmPhotos.count, 1)
            let restored = try XCTUnwrap(farmPhotos.first)
            XCTAssertEqual(restored.id, assetID)
            XCTAssertEqual(restored.capturedAt, localCapturedAt)
            XCTAssertEqual(restored.relativePath, "CloudAssets/local-edited-photo-repeat.jpg")
            XCTAssertFalse(restored.isCloudAuthoritative)

            let transfers = try verify.fetch(FetchDescriptor<CloudAssetTransfer>()).filter {
                $0.farmID == farmID && $0.direction == .upload
            }
            XCTAssertEqual(transfers.count, 1)
            let retained = try XCTUnwrap(transfers.first)
            XCTAssertEqual(retained.assetID, assetID)
            XCTAssertEqual(retained.status, .pending)
        }
    }

    func testFailedReplacementRollsBackOldWorkingCache() async throws {
        let container = try AppSchema.makeContainer(name: "rollback-test", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        let oldPen = PenRecord(farmID: farmID, name: "旧圈舍")
        context.insert(oldPen)
        try context.save()

        let missingSheepWeight = try makeOperation(
            farmID: farmID,
            command: .recordWeight(sheepID: UUID(), kilogramsText: "42", occurredAt: .now, note: "无效引用"),
            entityType: .weight
        )
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [missingSheepWeight])

        do {
            _ = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(using: bundle)
            XCTFail("缺失引用必须使 staging 提交失败")
        } catch {
            let verify = ModelContext(container)
            let pens = try verify.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }
            XCTAssertEqual(pens.count, 1)
            XCTAssertEqual(pens.first?.id, oldPen.id)
            XCTAssertEqual(pens.first?.name, "旧圈舍")
        }
    }

    func testFailedRetryKeepsPhotoFilesFromPreviouslyCommittedAttempt() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-retry-photo-files-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let sessionID = UUID()
        let assetID = UUID()
        let penID = UUID()
        let fileData = Data("committed-cloud-photo".utf8)
        let digest = CloudPayloadDigest.hex(for: fileData)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let workspace = support.appending(
            path: "CloudRebuild/\(sessionID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        let stagingAssets = workspace.appending(path: "Assets", directoryHint: .isDirectory)
        let farmAssetRoot = support.appending(
            path: "eSheepNext/CloudAssets/\(farmID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: stagingAssets, withIntermediateDirectories: true)
        try fileData.write(to: stagingAssets.appending(path: "photo.jpg"), options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: farmAssetRoot)
        }

        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "恢复中牧场"))
        try context.save()

        let asset = CloudRebuildAssetSnapshot(
            envelope: FarmAssetEnvelope(
                farmID: farmID,
                assetID: assetID,
                entityID: nil,
                sourceDigest: digest,
                payloadDigest: digest,
                mimeType: "image/jpeg",
                pixelWidth: 1_024,
                pixelHeight: 768,
                capturedAt: Date(timeIntervalSince1970: 1_735_689_660),
                byteCount: Int64(fileData.count),
                createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                modifiedByAccountID: ownerID,
                modifiedByDeviceID: UUID(),
                capabilityCertificate: "test",
                signature: Data()
            ),
            relativePath: "Assets/photo.jpg",
            cloudRecordName: "asset_\(assetID.uuidString.lowercased())"
        )
        let firstOperation = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "已提交圈舍", note: ""),
            entityType: .pen,
            entityID: penID
        )
        let persistence = FarmPersistenceActor(container: container)
        _ = try await persistence.replaceConfirmedFarmCache(
            using: makeBundle(
                sessionID: sessionID,
                farmID: farmID,
                ownerID: ownerID,
                operations: [firstOperation],
                assets: [asset]
            )
        )

        let committedContext = ModelContext(container)
        let committedPhoto = try XCTUnwrap(
            try committedContext.fetch(FetchDescriptor<PhotoAssetRecord>()).first { $0.id == assetID }
        )
        let committedRelativePath = committedPhoto.relativePath
        let committedFile = PhotoTransferActor.localAssetURL(
            for: committedRelativePath,
            applicationSupportDirectory: support
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedFile.path))
        XCTAssertEqual(try Data(contentsOf: committedFile), fileData)

        // Simulate a crash after the first cache save but before the rebuild
        // session was marked completed. The retry reaches asset copying, then
        // fails replay because its update has no create operation in this
        // attempted bundle.
        let invalidRetryOperation = try makeOperation(
            farmID: farmID,
            command: .updatePen(penID: penID, name: "不能单独重放", note: ""),
            entityType: .pen,
            entityID: penID
        )
        do {
            _ = try await persistence.replaceConfirmedFarmCache(
                using: makeBundle(
                    sessionID: sessionID,
                    farmID: farmID,
                    ownerID: ownerID,
                    operations: [invalidRetryOperation],
                    assets: [asset]
                )
            )
            XCTFail("缺少 createPen 的重试必须在复制照片后回滚")
        } catch {
            let verify = ModelContext(container)
            let retained = try XCTUnwrap(
                try verify.fetch(FetchDescriptor<PhotoAssetRecord>()).first { $0.id == assetID }
            )
            XCTAssertEqual(retained.relativePath, committedRelativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: committedFile.path))
            XCTAssertEqual(try Data(contentsOf: committedFile), fileData)
        }
    }

    func testRepeatedReplacementProducesSameDigestAndNoDuplicateEntity() async throws {
        let container = try AppSchema.makeContainer(name: "idempotent-rebuild", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "测试"))
        try context.save()
        let operation = try makeOperation(farmID: farmID, command: .createPen(name: "稳定圈舍", note: ""), entityType: .pen)
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation])
        let persistence = FarmPersistenceActor(container: container)

        let first = try await persistence.replaceConfirmedFarmCache(using: bundle)
        let second = try await persistence.replaceConfirmedFarmCache(using: bundle)

        XCTAssertEqual(first.entityDigest, second.entityDigest)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.count, 1)
    }

    func testLocationReplayIgnoresRetainedConfirmedOperationRevision() async throws {
        let container = try AppSchema.makeContainer(name: "rebuild-location-revision", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let deviceID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))

        let command = FarmCommand.updateFarmLocation(
            displayName: "吉昊羊场",
            latitude: 45.345_681,
            longitude: 122.985_357,
            addressSnapshot: "内蒙古自治区通辽市",
            timeZoneIdentifier: "Asia/Shanghai",
            source: .mapSearch,
            horizontalAccuracyMeters: 8
        )
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let retainedAudit = DomainOperation(
            farmID: farmID,
            accountID: ownerID,
            kind: .updateFarmLocation,
            summary: "旧库已确认的位置更新",
            entityType: CloudEntityType.farm.rawValue,
            entityID: farmID,
            baseRevision: 1,
            resultingRevision: 2,
            payload: payload
        )
        context.insert(retainedAudit)
        try context.save()

        let authoritative = CloudOperationEnvelope(
            farmID: farmID,
            entityID: farmID,
            entityType: CloudEntityType.farm.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 1_735_689_600),
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: deviceID,
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [authoritative])

        let result = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(using: bundle)

        let verify = ModelContext(container)
        let rebuiltFarm = try XCTUnwrap(try verify.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }))
        XCTAssertEqual(rebuiltFarm.locationDisplayName, "吉昊羊场")
        XCTAssertEqual(try XCTUnwrap(rebuiltFarm.latitude), 45.345_681, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(rebuiltFarm.longitude), 122.985_357, accuracy: 0.000_001)
        XCTAssertEqual(result.appliedOperationCount, 1)
        XCTAssertEqual(
            try verify.fetch(FetchDescriptor<DomainOperation>()).filter { $0.id == retainedAudit.id }.count,
            1,
            "已确认审计操作必须保留，不能靠删历史规避 revision 冲突"
        )
    }

    func testAppSchemaAlwaysUsesExplicitNonCloudKitConfiguration() throws {
        XCTAssertNoThrow(try AppSchema.makeContainer(name: "schema-contract", isStoredInMemoryOnly: true))
    }

    func testDiskStagingStoreCanBeRebuiltAndVerifiedRepeatedly() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let operation = try makeOperation(farmID: farmID, command: .createPen(name: "staging 圈舍", note: ""), entityType: .pen)
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation])
        let workspace = FileManager.default.temporaryDirectory.appending(path: "CloudRebuildTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let first = try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)
        try CloudRebuildStagingBuilder.verify(bundle: bundle, workspace: workspace)
        let second = try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)
        try CloudRebuildStagingBuilder.verify(bundle: bundle, workspace: workspace)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.operationCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appending(path: "SwiftData/staging.store").path))
    }

    func testDiskStagingPreCutoffTombstoneDoesNotReleaseVersion2SheepSnapshotAuthority() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let cutoff = Date(timeIntervalSince1970: 1_784_733_565)
        let initialPenID = UUID()
        let historicalPenID = UUID()
        let sheepID = UUID()
        let transferID = UUID()

        func bootstrap(
            _ source: CloudOperationEnvelope,
            slot: String
        ) throws -> CloudOperationEnvelope {
            let snapshot = BootstrapEntityEnvelopeV1(
                entityType: source.entityType,
                entityID: source.entityID,
                sourceRevision: source.revision,
                sourcePayload: source.payload
            )
            var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
            wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(snapshot)
            wrapper.integers["baselineVersion"] = 2
            wrapper.strings["baselineSlot"] = slot
            wrapper.dates["baselineCutoffAt"] = cutoff
            let payload = try JSONEncoder.cloud.encode(wrapper)
            return CloudOperationEnvelope(
                farmID: farmID,
                entityID: source.entityID,
                entityType: source.entityType,
                schemaVersion: source.schemaVersion,
                revision: source.revision,
                baseRevision: source.baseRevision,
                operationID: UUID(),
                modifiedAt: cutoff.addingTimeInterval(-600),
                modifiedByAccountID: source.modifiedByAccountID,
                modifiedByDeviceID: source.modifiedByDeviceID,
                payload: payload,
                payloadDigest: CloudPayloadDigest.hex(for: payload),
                capabilityCertificate: source.capabilityCertificate,
                operationSignature: source.operationSignature,
                deletedAt: source.deletedAt
            )
        }

        let initialPen = try bootstrap(
            makeOperation(
                farmID: farmID,
                command: .createPen(name: "初始圈", note: ""),
                entityType: .pen,
                entityID: initialPenID
            ),
            slot: "10"
        )
        let historicalPen = try bootstrap(
            makeOperation(
                farmID: farmID,
                command: .createPen(name: "历史圈", note: ""),
                entityType: .pen,
                entityID: historicalPenID
            ),
            slot: "10"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var sheepPayload = try decoder.decode(
            FarmCommandCloudPayload.self,
            from: FarmCommandCloudPayloadEncoder.encode(.addSheep(
                earTag: "LEGACY-REMOVED",
                breed: "湖羊",
                sex: .ewe,
                penID: initialPenID,
                occurredAt: cutoff.addingTimeInterval(-86_400 * 30),
                birthAt: nil,
                note: ""
            ))
        )
        sheepPayload.strings["legacyStatusRawValue"] = SheepStatus.removed.rawValue
        sheepPayload.integers["legacyStatusSnapshotIsAuthoritative"] = 1
        sheepPayload.integers["legacyPenSnapshotIsAuthoritative"] = 1
        sheepPayload.optionalIdentifiers["legacyCurrentPenID"] = nil
        sheepPayload.optionalDates["legacyRemovedAt"] = cutoff.addingTimeInterval(-86_400)
        let encodedSheepPayload = try JSONEncoder.cloud.encode(sheepPayload)
        let sheepSource = CloudOperationEnvelope(
            farmID: farmID,
            entityID: sheepID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: cutoff.addingTimeInterval(-600),
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            payload: encodedSheepPayload,
            payloadDigest: CloudPayloadDigest.hex(for: encodedSheepPayload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        let sheep = try bootstrap(sheepSource, slot: "20")
        let transfer = try bootstrap(
            makeOperation(
                farmID: farmID,
                command: .transferSheep(
                    sheepID: sheepID,
                    toPenID: historicalPenID,
                    occurredAt: cutoff.addingTimeInterval(-86_400 * 10),
                    note: "迁移前历史转群"
                ),
                entityType: .transfer,
                entityID: transferID
            ),
            slot: "30"
        )
        let tombstone = replacingTiming(
            in: try makeOperation(
                farmID: farmID,
                command: .tombstoneEntity(
                    entityType: .transfer,
                    entityID: transferID,
                    reason: "迁移前已删除"
                ),
                entityType: .transfer,
                entityID: transferID
            ),
            modifiedAt: cutoff.addingTimeInterval(-60),
            deletedAt: cutoff.addingTimeInterval(-60)
        )
        let operations = CloudRebuildActor.sortedOperations([
            initialPen,
            historicalPen,
            sheep,
            transfer,
            tombstone,
        ])
        let bundle = makeBundle(
            farmID: farmID,
            ownerID: ownerID,
            operations: operations,
            bootstrap: CloudRebuildBootstrapSnapshot(
                digest: "test-v2",
                entityCount: 4,
                photoCount: 0,
                version: 2,
                cutoffAt: cutoff
            ),
            scope: .sharedDatabase
        )
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "CloudRebuildTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        _ = try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)

        let staging = try AppSchema.makeContainer(
            name: "pre-cutoff-tombstone-snapshot-authority",
            url: workspace.appending(path: "SwiftData/staging.store")
        )
        let recovered = try XCTUnwrap(
            try ModelContext(staging).fetch(FetchDescriptor<SheepRecord>())
                .first { $0.id == sheepID }
        )
        XCTAssertEqual(recovered.status, .removed)
        XCTAssertNil(recovered.currentPenID)
        XCTAssertEqual(recovered.legacyStatusSnapshotIsAuthoritative, true)
        XCTAssertEqual(recovered.legacyPenSnapshotIsAuthoritative, true)
    }

    func testDiskStagingAcknowledgesCorrectionOnlyWhenSourceAndResultAreAuthoritativelyDeleted() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let originalID = UUID()
        let replacementID = UUID()
        let correctionAt = Date(timeIntervalSince1970: 1_753_347_340)
        let originalTombstoneAt = correctionAt.addingTimeInterval(-60)
        let replacementTombstoneAt = correctionAt.addingTimeInterval(120)
        let correction = replacingTiming(
            in: try makeOperation(
                farmID: farmID,
                command: .correctRemoval(
                    originalID: originalID,
                    kind: .sold,
                    reason: "测试",
                    amountText: "100",
                    occurredAt: correctionAt,
                    note: "",
                    correctionReason: "更正"
                ),
                entityType: .removal,
                entityID: replacementID
            ),
            modifiedAt: correctionAt
        )
        let originalTombstone = replacingTiming(
            in: try makeOperation(
                farmID: farmID,
                command: .tombstoneEntity(
                    entityType: .removal,
                    entityID: originalID,
                    reason: "删除原记录"
                ),
                entityType: .removal,
                entityID: originalID
            ),
            modifiedAt: originalTombstoneAt,
            deletedAt: originalTombstoneAt
        )
        let replacementTombstone = replacingTiming(
            in: try makeOperation(
                farmID: farmID,
                command: .tombstoneEntity(
                    entityType: .removal,
                    entityID: replacementID,
                    reason: "删除修正记录"
                ),
                entityType: .removal,
                entityID: replacementID
            ),
            modifiedAt: replacementTombstoneAt,
            deletedAt: replacementTombstoneAt
        )
        let bundle = makeBundle(
            farmID: farmID,
            ownerID: ownerID,
            operations: [correction, originalTombstone, replacementTombstone]
        )
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "CloudRebuildTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        _ = try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)
        try CloudRebuildStagingBuilder.verify(bundle: bundle, workspace: workspace)

        let staging = try AppSchema.makeContainer(
            name: "superseded-correction-verify",
            url: workspace.appending(path: "SwiftData/staging.store")
        )
        let context = ModelContext(staging)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<CloudOperationReceipt>())
                .filter { $0.farmID == farmID }
                .count,
            3
        )
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<RemovalRecord>())
                .filter { $0.farmID == farmID && $0.deletedAt == nil }
                .isEmpty
        )
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<SecurityIncidentRecord>())
                .contains {
                    $0.farmID == farmID &&
                        $0.incidentType == "supersededMissingReplayDependency"
                }
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<DomainOperation>())
                .filter { $0.farmID == farmID }
                .count,
            3,
            "已验证的非基线云端操作必须在干净安装上恢复为本地审计历史"
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<TombstoneRecord>())
                .filter { $0.farmID == farmID }
                .count,
            3,
            "修正来源和结果均被删除时，仍须保留修正操作对应的删除证据"
        )
    }

    func testCleanInstallReplacementRestoresRemoteDomainOperationAudit() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-audit-history-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        context.insert(FarmRecord(
            id: farmID,
            ownerAccountID: ownerID,
            name: "恢复中"
        ))
        try context.save()
        let operation = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "云端圈舍", note: ""),
            entityType: .pen
        )

        _ = try await FarmPersistenceActor(container: container)
            .replaceConfirmedFarmCache(
                using: makeBundle(
                    farmID: farmID,
                    ownerID: ownerID,
                    operations: [operation]
                )
            )

        let verify = ModelContext(container)
        let audit = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<DomainOperation>())
                .first { $0.id == operation.operationID }
        )
        XCTAssertEqual(audit.kindRawValue, DomainOperationKind.createPen.rawValue)
        XCTAssertEqual(audit.summary, "新建圈舍：云端圈舍")
        XCTAssertEqual(audit.payloadDigest, operation.payloadDigest)
        XCTAssertEqual(audit.modifiedByDeviceID, operation.modifiedByDeviceID)
        XCTAssertEqual(audit.operationSignature, operation.operationSignature)
        XCTAssertTrue(
            try verify.fetch(FetchDescriptor<OutboxItem>())
                .filter { $0.farmID == farmID }
                .isEmpty,
            "远端审计投影不能制造待上传 Outbox"
        )
    }

    func testDiskStagingRejectsMissingCorrectionWithoutLaterResultTombstone() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let originalID = UUID()
        let replacementID = UUID()
        let correctionAt = Date(timeIntervalSince1970: 1_753_347_340)
        let correction = replacingTiming(
            in: try makeOperation(
                farmID: farmID,
                command: .correctRemoval(
                    originalID: originalID,
                    kind: .sold,
                    reason: "测试",
                    amountText: nil,
                    occurredAt: correctionAt,
                    note: "",
                    correctionReason: "更正"
                ),
                entityType: .removal,
                entityID: replacementID
            ),
            modifiedAt: correctionAt
        )
        let originalTombstone = replacingTiming(
            in: try makeOperation(
                farmID: farmID,
                command: .tombstoneEntity(
                    entityType: .removal,
                    entityID: originalID,
                    reason: "删除原记录"
                ),
                entityType: .removal,
                entityID: originalID
            ),
            modifiedAt: correctionAt.addingTimeInterval(-60),
            deletedAt: correctionAt.addingTimeInterval(-60)
        )
        let bundle = makeBundle(
            farmID: farmID,
            ownerID: ownerID,
            operations: [correction, originalTombstone]
        )
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "CloudRebuildTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        XCTAssertThrowsError(
            try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)
        ) { error in
            guard case CloudRebuildError.stagingValidation(let detail) = error else {
                return XCTFail("预期 fail-closed stagingValidation，实际为 \(error)")
            }
            XCTAssertTrue(detail.contains(correction.operationID.uuidString.lowercased()))
        }
    }

    func testCompletedCacheSwitchRetryRequiresNewestVerifiedBundle() async throws {
        let container = try AppSchema.makeContainer(
            name: "completed-cache-switch-gate-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let farmID = UUID()
        let ownerID = UUID()
        let sessionID = UUID()
        let relativePath = "CloudRebuildTests/\(sessionID.uuidString.lowercased())"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let workspace = support.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let operation = try makeOperation(
            farmID: farmID,
            command: .createPen(name: "已校验圈舍", note: ""),
            entityType: .pen
        )
        let bundle = makeBundle(
            sessionID: sessionID,
            farmID: farmID,
            ownerID: ownerID,
            operations: [operation]
        )
        let staging = try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bundle).write(
            to: workspace.appending(path: "bundle.json"),
            options: .atomic
        )

        let context = ModelContext(container)
        let completed = CloudRebuildSessionRecord(
            id: sessionID,
            farmID: farmID,
            databaseScope: .privateDatabase,
            reason: .manualVerification,
            stagingRelativePath: relativePath
        )
        completed.statusRawValue = CloudRebuildStatus.completed.rawValue
        completed.pageCount = bundle.pageCount
        completed.fetchedRecordCount = bundle.recordCount
        completed.fetchedOperationCount = bundle.operations.count
        completed.fetchedAssetCount = bundle.assets.count
        completed.downloadedAssetCount = bundle.assets.count
        completed.appliedOperationCount = bundle.operations.count
        completed.preservedOutboxCount = 0
        completed.highestRevision = operation.revision
        completed.entityDigest = staging.entityDigest
        completed.progress = 1
        completed.completedAt = .now
        context.insert(completed)
        try context.save()

        let actor = CloudRebuildActor(
            modelContainer: container,
            persistence: FarmPersistenceActor(container: container),
            containerIdentifier: nil
        )
        let verified = try await actor.verifiedCompletedCacheSwitch(
            farmID: farmID,
            scope: .privateDatabase
        )
        XCTAssertEqual(verified?.sessionID, sessionID)
        let wrongScope = try await actor.verifiedCompletedCacheSwitch(
            farmID: farmID,
            scope: .sharedDatabase
        )
        XCTAssertNil(wrongScope)

        let newer = CloudRebuildSessionRecord(
            farmID: farmID,
            databaseScope: .privateDatabase,
            reason: .accountRecovery,
            stagingRelativePath: "CloudRebuildTests/newer"
        )
        newer.createdAt = completed.createdAt.addingTimeInterval(1)
        newer.updatedAt = newer.createdAt
        newer.statusRawValue = CloudRebuildStatus.failed.rawValue
        context.insert(newer)
        try context.save()

        let superseded = try await actor.verifiedCompletedCacheSwitch(
            farmID: farmID,
            scope: .privateDatabase
        )
        XCTAssertNil(superseded)
    }

    func testRemoteExactLookupSeesPendingInsertAndKeepsTransferSemantics() throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-pending-exact-lookup-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let sheepID = UUID()
        let initialPenID = UUID()
        let destinationPenID = UUID()
        let enteredAt = Date(timeIntervalSince1970: 1_735_689_600)
        let transferredAt = enteredAt.addingTimeInterval(3_600)
        let addSheep = try makeOperation(
            farmID: farmID,
            command: .addSheep(
                earTag: "PENDING-001",
                breed: "湖羊",
                sex: .ewe,
                penID: initialPenID,
                occurredAt: enteredAt,
                birthAt: nil,
                note: ""
            ),
            entityType: .sheep,
            entityID: sheepID
        )
        let transfer = try makeOperation(
            farmID: farmID,
            command: .transferSheep(
                sheepID: sheepID,
                toPenID: destinationPenID,
                occurredAt: transferredAt,
                note: "测试 pending lookup"
            ),
            entityType: .transfer
        )
        let normalizedDuplicate = try makeOperation(
            farmID: farmID,
            command: .addSheep(
                earTag: " pending-001 ",
                breed: "湖羊",
                sex: .ewe,
                penID: initialPenID,
                occurredAt: enteredAt,
                birthAt: nil,
                note: ""
            ),
            entityType: .sheep
        )
        let service = RemoteDomainApplyService(replayAssumesEmptyBusinessStore: true)

        XCTAssertEqual(try service.apply(addSheep, context: context), .applied(rebuildHistoryFrom: enteredAt))
        XCTAssertEqual(try service.apply(normalizedDuplicate, context: context), .conflict(localRevision: 0))
        XCTAssertEqual(try service.apply(transfer, context: context), .applied(rebuildHistoryFrom: transferredAt))
        XCTAssertEqual(try service.apply(transfer, context: context), .duplicate)

        XCTAssertEqual(try context.fetch(FetchDescriptor<SheepRecord>()).count, 1)
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>())
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(transfers.first?.sheepID, sheepID)
        XCTAssertEqual(transfers.first?.fromPenID, initialPenID)
        XCTAssertEqual(transfers.first?.toPenID, destinationPenID)
    }

    func testBootstrapEvidenceAllowsPhotosAddedAfterMigration() throws {
        let farmID = UUID()
        let payload = Data("云端牧场".utf8)
        let snapshot = BootstrapEntityEnvelopeV1(
            entityType: CloudEntityType.farm.rawValue,
            entityID: farmID,
            sourceRevision: 1,
            sourcePayload: payload
        )
        let digestLine = "\(snapshot.entityType):\(snapshot.entityID.uuidString.lowercased()):\(snapshot.sourcePayloadDigest)"
        let digest = CloudPayloadDigest.hex(for: Data(digestLine.utf8))

        XCTAssertNoThrow(try CloudRebuildActor.validateBootstrapEvidence(
            snapshots: [snapshot],
            verifiedAssetCount: 8,
            expectedDigest: digest,
            expectedEntityCount: 1,
            expectedPhotoCount: 7
        ))
        XCTAssertThrowsError(try CloudRebuildActor.validateBootstrapEvidence(
            snapshots: [snapshot],
            verifiedAssetCount: 6,
            expectedDigest: digest,
            expectedEntityCount: 1,
            expectedPhotoCount: 7
        ))
    }

    func testTrustedPreCutoffLocationIsSilentlyExcludedFromVersionTwoBundle() throws {
        let privateKey = P256.Signing.PrivateKey()
        let modifiedAt = Date(timeIntervalSince1970: 1_735_689_600)
        let envelope = try makeSignedOperation(
            command: .updateFarmLocation(
                displayName: "吉昊羊场",
                latitude: 45.345_681,
                longitude: 122.985_357,
                addressSnapshot: nil,
                timeZoneIdentifier: "Asia/Shanghai",
                source: .mapSearch,
                horizontalAccuracyMeters: nil
            ),
            entityType: .farm,
            modifiedAt: modifiedAt,
            privateKey: privateKey
        )
        // Deliberately omit editFarmLocation. Because the signed operation is
        // covered by the v2 baseline, it must be excluded without an issue.
        let claims = makeClaims(
            for: envelope,
            capabilities: [.readFarm, .recordProduction],
            authorizationDate: modifiedAt
        )

        let admitted = try CloudRebuildActor.validatedOperationForRebuild(
            envelope: envelope,
            claims: claims,
            devicePublicKeyX963: privateKey.publicKey.x963Representation,
            authorizationDate: modifiedAt,
            expectedBootstrapVersion: 2,
            cutoffAt: modifiedAt.addingTimeInterval(1)
        )

        XCTAssertNil(admitted)
    }

    func testPreCutoffTombstoneCannotBypassRequiredCapability() throws {
        let privateKey = P256.Signing.PrivateKey()
        let modifiedAt = Date(timeIntervalSince1970: 1_735_689_600)
        let targetID = UUID()
        let envelope = try makeSignedOperation(
            command: .tombstoneEntity(entityType: .sheep, entityID: targetID, reason: "误建档"),
            entityType: .sheep,
            entityID: targetID,
            modifiedAt: modifiedAt,
            privateKey: privateKey
        )
        let deniedClaims = makeClaims(
            for: envelope,
            capabilities: [.readFarm, .recordProduction],
            authorizationDate: modifiedAt
        )

        XCTAssertThrowsError(try CloudRebuildActor.validatedOperationForRebuild(
            envelope: envelope,
            claims: deniedClaims,
            devicePublicKeyX963: privateKey.publicKey.x963Representation,
            authorizationDate: modifiedAt,
            expectedBootstrapVersion: 2,
            cutoffAt: modifiedAt.addingTimeInterval(1)
        )) { error in
            XCTAssertEqual(error as? CloudContractError, .capabilityDenied)
        }

        let authorizedClaims = makeClaims(
            for: envelope,
            capabilities: [.readFarm, .deleteProtectedFacts],
            authorizationDate: modifiedAt
        )
        XCTAssertEqual(try CloudRebuildActor.validatedOperationForRebuild(
            envelope: envelope,
            claims: authorizedClaims,
            devicePublicKeyX963: privateKey.publicKey.x963Representation,
            authorizationDate: modifiedAt,
            expectedBootstrapVersion: 2,
            cutoffAt: modifiedAt.addingTimeInterval(1)
        ), envelope)
    }

    func testRejectedLegacyTombstoneCanBeQuarantinedByValidatedRemoteWinner() throws {
        let fixture = try makeSupersededTombstoneFixture()

        XCTAssertNoThrow(try CloudRebuildActor.validateSupersedingTombstoneAuthority(
            rejectedOperation: fixture.rejected,
            tombstone: fixture.tombstone,
            authoritativeOperation: fixture.authoritative,
            tombstoneCertificate: fixture.authoritative.capabilityCertificate,
            tombstoneSignature: fixture.authoritative.operationSignature,
            authoritativeRecordCertificate: fixture.authoritative.capabilityCertificate,
            authoritativeRecordSignature: fixture.authoritative.operationSignature
        ))
    }

    func testRejectedLegacyTombstoneCannotUseMismatchedTombstoneCredentials() throws {
        let fixture = try makeSupersededTombstoneFixture()

        XCTAssertThrowsError(try CloudRebuildActor.validateSupersedingTombstoneAuthority(
            rejectedOperation: fixture.rejected,
            tombstone: fixture.tombstone,
            authoritativeOperation: fixture.authoritative,
            tombstoneCertificate: fixture.authoritative.capabilityCertificate,
            tombstoneSignature: Data("different-signature".utf8),
            authoritativeRecordCertificate: fixture.authoritative.capabilityCertificate,
            authoritativeRecordSignature: fixture.authoritative.operationSignature
        ))
    }

    func testRejectedLegacyTombstoneCannotCrossEntityBoundary() throws {
        let fixture = try makeSupersededTombstoneFixture()
        let wrongEntity = FarmTombstoneEnvelope(
            tombstoneID: fixture.tombstone.tombstoneID,
            farmID: fixture.tombstone.farmID,
            entityType: fixture.tombstone.entityType,
            entityID: UUID(),
            revision: fixture.tombstone.revision,
            deletedAt: fixture.tombstone.deletedAt,
            deletedByAccountID: fixture.tombstone.deletedByAccountID,
            reason: fixture.tombstone.reason,
            operationID: fixture.tombstone.operationID,
            restoresTombstoneID: nil
        )

        XCTAssertThrowsError(try CloudRebuildActor.validateSupersedingTombstoneAuthority(
            rejectedOperation: fixture.rejected,
            tombstone: wrongEntity,
            authoritativeOperation: fixture.authoritative,
            tombstoneCertificate: fixture.authoritative.capabilityCertificate,
            tombstoneSignature: fixture.authoritative.operationSignature,
            authoritativeRecordCertificate: fixture.authoritative.capabilityCertificate,
            authoritativeRecordSignature: fixture.authoritative.operationSignature
        ))
    }

    func testTamperedPreCutoffSignatureCannotUseBaselineExclusion() throws {
        let signingKey = P256.Signing.PrivateKey()
        let differentKey = P256.Signing.PrivateKey()
        let modifiedAt = Date(timeIntervalSince1970: 1_735_689_600)
        let unsigned = try makeUnsignedOperation(
            command: .updateFarmLocation(
                displayName: "吉昊羊场",
                latitude: 45.345_681,
                longitude: 122.985_357,
                addressSnapshot: nil,
                timeZoneIdentifier: "Asia/Shanghai",
                source: .mapSearch,
                horizontalAccuracyMeters: nil
            ),
            entityType: .farm,
            modifiedAt: modifiedAt
        )
        let tampered = replacingSignature(
            in: unsigned,
            with: try differentKey.signature(for: unsigned.canonicalSigningData).rawRepresentation
        )
        let claims = makeClaims(
            for: tampered,
            capabilities: [.readFarm, .recordProduction],
            authorizationDate: modifiedAt
        )

        XCTAssertThrowsError(try CloudRebuildActor.validatedOperationForRebuild(
            envelope: tampered,
            claims: claims,
            devicePublicKeyX963: signingKey.publicKey.x963Representation,
            authorizationDate: modifiedAt,
            expectedBootstrapVersion: 2,
            cutoffAt: modifiedAt.addingTimeInterval(1)
        )) { error in
            XCTAssertEqual(error as? CloudContractError, .invalidDeviceSignature)
        }
    }

    func testPostCutoffLocationStillRequiresLocationCapability() throws {
        let privateKey = P256.Signing.PrivateKey()
        let cutoff = Date(timeIntervalSince1970: 1_735_689_600)
        let modifiedAt = cutoff.addingTimeInterval(1)
        let envelope = try makeSignedOperation(
            command: .updateFarmLocation(
                displayName: "基线后位置",
                latitude: 45.4,
                longitude: 123.0,
                addressSnapshot: nil,
                timeZoneIdentifier: "Asia/Shanghai",
                source: .mapSearch,
                horizontalAccuracyMeters: nil
            ),
            entityType: .farm,
            modifiedAt: modifiedAt,
            privateKey: privateKey
        )
        let claims = makeClaims(
            for: envelope,
            capabilities: [.readFarm, .recordProduction],
            authorizationDate: modifiedAt
        )

        XCTAssertThrowsError(try CloudRebuildActor.validatedOperationForRebuild(
            envelope: envelope,
            claims: claims,
            devicePublicKeyX963: privateKey.publicKey.x963Representation,
            authorizationDate: modifiedAt,
            expectedBootstrapVersion: 2,
            cutoffAt: cutoff
        )) { error in
            XCTAssertEqual(error as? CloudContractError, .capabilityDenied)
        }
    }

    func testBootstrapSnapshotPersistsVersionAndExactMillisecondCutoff() throws {
        let cutoff = Date(timeIntervalSince1970: 1_735_689_600.789)
        let snapshot = CloudRebuildBootstrapSnapshot(
            digest: "v2-digest",
            entityCount: 21_387,
            photoCount: 7,
            version: 2,
            cutoffAt: cutoff
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CloudRebuildBootstrapSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.digest, "v2-digest")
        XCTAssertEqual(decoded.normalizedVersion, 2)
        XCTAssertEqual(decoded.cutoffAtMilliseconds, 1_735_689_600_789)
        XCTAssertEqual(decoded.cutoffAt, Date(timeIntervalSince1970: 1_735_689_600.789))
    }

    func testLegacyBootstrapSnapshotDecodesAsVersionOneWithoutCutoff() throws {
        let legacy = Data(#"{"digest":"legacy-v1","entityCount":123,"photoCount":7}"#.utf8)
        let decoded = try JSONDecoder().decode(CloudRebuildBootstrapSnapshot.self, from: legacy)

        XCTAssertEqual(decoded.normalizedVersion, 1)
        XCTAssertNil(decoded.cutoffAtMilliseconds)
    }

    func testRootSnapshotPersistsExactMillisecondIdentity() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 1_735_689_600.789)
        let snapshot = CloudRebuildRootSnapshot(
            farmID: farmID,
            name: "权威牧场",
            ownerAccountID: ownerID,
            modifiedAt: modifiedAt
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CloudRebuildRootSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.modifiedAtMilliseconds, 1_735_689_600_789)
        XCTAssertNoThrow(try CloudRebuildActor.validateCurrentRootIdentity(snapshot, expected: decoded))
    }

    func testCommitRootIdentityGateRequiresSameNameAndMillisecond() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 1_735_689_600.789)
        let expected = CloudRebuildRootSnapshot(
            farmID: farmID,
            name: "权威牧场",
            ownerAccountID: ownerID,
            modifiedAt: modifiedAt
        )

        XCTAssertNoThrow(try CloudRebuildActor.validateCurrentRootIdentity(expected, expected: expected))

        let renamed = CloudRebuildRootSnapshot(
            farmID: farmID,
            name: "已更新牧场",
            ownerAccountID: ownerID,
            modifiedAt: modifiedAt
        )
        XCTAssertThrowsError(try CloudRebuildActor.validateCurrentRootIdentity(renamed, expected: expected)) { error in
            XCTAssertEqual(error as? CloudRebuildError, .authoritativeRootChanged)
        }

        let newer = CloudRebuildRootSnapshot(
            farmID: farmID,
            name: "权威牧场",
            ownerAccountID: ownerID,
            modifiedAt: modifiedAt.addingTimeInterval(0.001)
        )
        XCTAssertThrowsError(try CloudRebuildActor.validateCurrentRootIdentity(newer, expected: expected)) { error in
            XCTAssertEqual(error as? CloudRebuildError, .authoritativeRootChanged)
        }
    }

    func testLegacyWholeBundleDecodesButCannotPassExactRootGate() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let bundle = makeBundle(
            farmID: farmID,
            ownerID: ownerID,
            operations: [],
            bootstrap: CloudRebuildBootstrapSnapshot(
                digest: "legacy-v1",
                entityCount: 123,
                photoCount: 7
            )
        )
        let encoded = try JSONEncoder().encode(bundle)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "authorityProofVersion")
        var root = try XCTUnwrap(object["root"] as? [String: Any])
        root.removeValue(forKey: "modifiedAtMilliseconds")
        object["root"] = root
        var bootstrap = try XCTUnwrap(object["bootstrap"] as? [String: Any])
        bootstrap.removeValue(forKey: "version")
        bootstrap.removeValue(forKey: "cutoffAtMilliseconds")
        object["bootstrap"] = bootstrap

        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(CloudRebuildBundle.self, from: legacyData)

        XCTAssertNil(decoded.root.modifiedAtMilliseconds)
        XCTAssertNil(decoded.authorityProofVersion)
        XCTAssertFalse(CloudRebuildActor.hasCurrentAuthorityProof(decoded))
        XCTAssertEqual(decoded.bootstrap?.normalizedVersion, 1)
        XCTAssertNil(decoded.bootstrap?.cutoffAtMilliseconds)
        let current = CloudRebuildRootSnapshot(
            farmID: decoded.root.farmID,
            name: decoded.root.name,
            ownerAccountID: decoded.root.ownerAccountID,
            modifiedAt: decoded.root.modifiedAt
        )
        XCTAssertThrowsError(try CloudRebuildActor.validateCurrentRootIdentity(current, expected: decoded.root)) { error in
            XCTAssertEqual(error as? CloudRebuildError, .authoritativeRootChanged)
        }
    }

    func testCommitRootGateRequiresSameReadyVersionDigestAndCutoff() throws {
        let farmID = UUID()
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        let cutoff = Date(timeIntervalSince1970: 1_735_689_600.789)
        let expected = CloudRebuildBootstrapSnapshot(
            digest: "authoritative-v2",
            entityCount: 21_387,
            photoCount: 7,
            version: 2,
            cutoffAt: cutoff
        )

        func makeRoot(
            state: String = "ready",
            digest: String = "authoritative-v2",
            version: Int = 2,
            cutoffAt: Date? = nil
        ) -> CKRecord {
            let record = CKRecord(
                recordType: CloudRecordType.farmRoot.rawValue,
                recordID: CKRecord.ID(recordName: "root_\(farmID.uuidString.lowercased())", zoneID: zoneID)
            )
            record[CloudRecordField.bootstrapState] = state as CKRecordValue
            record[CloudRecordField.bootstrapDigest] = digest as CKRecordValue
            record[CloudRecordField.bootstrapVersion] = version as CKRecordValue
            record[CloudRecordField.bootstrapCutoffAt] = (cutoffAt ?? cutoff) as CKRecordValue
            record[CloudRecordField.bootstrapEntityCount] = 21_387 as CKRecordValue
            record[CloudRecordField.bootstrapPhotoCount] = 7 as CKRecordValue
            return record
        }

        func assertBaselineChanged(_ record: CKRecord, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(
                try CloudRebuildActor.validateCurrentBootstrapRoot(record, expected: expected),
                file: file,
                line: line
            ) { error in
                XCTAssertEqual(error as? CloudRebuildError, .authoritativeBaselineChanged, file: file, line: line)
            }
        }

        XCTAssertNoThrow(try CloudRebuildActor.validateCurrentBootstrapRoot(makeRoot(), expected: expected))
        assertBaselineChanged(makeRoot(state: "updating"))
        assertBaselineChanged(makeRoot(digest: "stale-v1"))
        assertBaselineChanged(makeRoot(version: 1))
        assertBaselineChanged(makeRoot(cutoffAt: cutoff.addingTimeInterval(1)))
        XCTAssertThrowsError(try CloudRebuildActor.validateCurrentBootstrapRoot(makeRoot(), expected: nil)) { error in
            XCTAssertEqual(error as? CloudRebuildError, .authoritativeBaselineChanged)
        }
        let ordinaryRoot = CKRecord(
            recordType: CloudRecordType.farmRoot.rawValue,
            recordID: CKRecord.ID(recordName: "ordinary_root", zoneID: zoneID)
        )
        XCTAssertNoThrow(try CloudRebuildActor.validateCurrentBootstrapRoot(ordinaryRoot, expected: nil))

        let entityCountOnlyRoot = CKRecord(
            recordType: CloudRecordType.farmRoot.rawValue,
            recordID: CKRecord.ID(recordName: "entity_count_only_root", zoneID: zoneID)
        )
        entityCountOnlyRoot[CloudRecordField.bootstrapEntityCount] = 0 as CKRecordValue
        XCTAssertThrowsError(try CloudRebuildActor.validateCurrentBootstrapRoot(entityCountOnlyRoot, expected: nil)) { error in
            XCTAssertEqual(error as? CloudRebuildError, .authoritativeBaselineChanged)
        }

        let photoCountOnlyRoot = CKRecord(
            recordType: CloudRecordType.farmRoot.rawValue,
            recordID: CKRecord.ID(recordName: "photo_count_only_root", zoneID: zoneID)
        )
        photoCountOnlyRoot[CloudRecordField.bootstrapPhotoCount] = 0 as CKRecordValue
        XCTAssertThrowsError(try CloudRebuildActor.validateCurrentBootstrapRoot(photoCountOnlyRoot, expected: nil)) { error in
            XCTAssertEqual(error as? CloudRebuildError, .authoritativeBaselineChanged)
        }
    }

    func testOnlyLatestRunningBuildSessionMayAdvance() {
        XCTAssertTrue(CloudRebuildActor.canAdvanceBuildSession(status: .validating, isLatest: true))
        XCTAssertFalse(CloudRebuildActor.canAdvanceBuildSession(status: .validating, isLatest: false))
        XCTAssertFalse(CloudRebuildActor.canAdvanceBuildSession(status: .cancelled, isLatest: true))
        XCTAssertFalse(CloudRebuildActor.canAdvanceBuildSession(status: .readyToCommit, isLatest: true))
        XCTAssertFalse(CloudRebuildActor.canAdvanceBuildSession(status: .committing, isLatest: true))
    }

    func testOperationOrderingIsTransitiveAndIndependentOfCloudKitInputOrder() throws {
        let farmID = UUID()
        let sharedEntityID = UUID()
        func revised(
            _ value: CloudOperationEnvelope,
            revision: Int,
            time: TimeInterval
        ) -> CloudOperationEnvelope {
            CloudOperationEnvelope(
                farmID: value.farmID,
                entityID: value.entityID,
                entityType: value.entityType,
                schemaVersion: value.schemaVersion,
                revision: revision,
                baseRevision: max(0, revision - 1),
                operationID: value.operationID,
                modifiedAt: Date(timeIntervalSince1970: time),
                modifiedByAccountID: value.modifiedByAccountID,
                modifiedByDeviceID: value.modifiedByDeviceID,
                payload: value.payload,
                payloadDigest: value.payloadDigest,
                capabilityCertificate: value.capabilityCertificate,
                operationSignature: value.operationSignature,
                deletedAt: nil
            )
        }
        func operation(entityID: UUID, revision: Int, time: TimeInterval) throws -> CloudOperationEnvelope {
            let value = try makeOperation(
                farmID: farmID,
                command: .createPen(name: "圈舍-\(revision)-\(time)", note: ""),
                entityType: .pen,
                entityID: entityID
            )
            return revised(value, revision: revision, time: time)
        }
        let a = try operation(entityID: sharedEntityID, revision: 1, time: 3)
        let b = try operation(entityID: sharedEntityID, revision: 2, time: 1)
        let c = try operation(entityID: UUID(), revision: 1, time: 2)
        let expected = CloudRebuildActor.sortedOperations([a, b, c]).map(\.operationID)
        let permutations = [
            [a, b, c], [a, c, b], [b, a, c],
            [b, c, a], [c, a, b], [c, b, a],
        ]
        for values in permutations {
            XCTAssertEqual(CloudRebuildActor.sortedOperations(values).map(\.operationID), expected)
        }
        XCTAssertLessThan(try XCTUnwrap(expected.firstIndex(of: a.operationID)), try XCTUnwrap(expected.firstIndex(of: b.operationID)))

        let donorID = UUID()
        let linked = try makeOperation(
            farmID: farmID,
            command: .care(.upsertSemenDonor(.init(
                id: donorID,
                name: "关联供体",
                breed: "杜泊",
                linkedRamID: UUID()
            ))),
            entityType: .semenDonor,
            entityID: donorID
        )
        let unlinked = try makeOperation(
            farmID: farmID,
            command: .care(.upsertSemenDonor(.init(
                id: donorID,
                name: "解除关联",
                breed: "杜泊",
                linkedRamID: nil,
                expectedRevision: 1
            ))),
            entityType: .semenDonor,
            entityID: donorID
        )
        let donorChain = CloudRebuildActor.sortedOperations([
            revised(unlinked, revision: 2, time: 1),
            revised(linked, revision: 1, time: 2),
        ])
        XCTAssertEqual(donorChain.map(\.revision), [1, 2], "普通实体不能因后续操作 rank 下降而反转 revision 链")
    }

    func testCreatingReplacementSessionSupersedesRunningAndReadySessionsForSameFarm() async throws {
        let container = try AppSchema.makeContainer(
            name: "rebuild-session-supersession-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let otherFarmID = UUID()
        let running = CloudRebuildSessionRecord(
            farmID: farmID,
            databaseScope: .privateDatabase,
            reason: .reinstallRecovery,
            stagingRelativePath: "CloudRebuild/running"
        )
        running.statusRawValue = CloudRebuildStatus.validating.rawValue
        let ready = CloudRebuildSessionRecord(
            farmID: farmID,
            databaseScope: .privateDatabase,
            reason: .manualVerification,
            stagingRelativePath: "CloudRebuild/ready"
        )
        ready.statusRawValue = CloudRebuildStatus.readyToCommit.rawValue
        let unrelated = CloudRebuildSessionRecord(
            farmID: otherFarmID,
            databaseScope: .privateDatabase,
            reason: .manualVerification,
            stagingRelativePath: "CloudRebuild/unrelated"
        )
        unrelated.statusRawValue = CloudRebuildStatus.validating.rawValue
        context.insert(running)
        context.insert(ready)
        context.insert(unrelated)
        try context.save()

        let replacementID = UUID()
        let actor = CloudRebuildActor(
            modelContainer: container,
            persistence: FarmPersistenceActor(container: container),
            containerIdentifier: nil
        )
        try await actor.createSession(
            id: replacementID,
            farmID: farmID,
            scope: .privateDatabase,
            reason: .accountRecovery,
            relativePath: "CloudRebuild/replacement"
        )

        let verify = ModelContext(container)
        let sessions = try verify.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
        XCTAssertEqual(sessions.first(where: { $0.id == running.id })?.status, .cancelled)
        XCTAssertEqual(sessions.first(where: { $0.id == running.id })?.lastErrorCode, "superseded")
        XCTAssertEqual(sessions.first(where: { $0.id == ready.id })?.status, .cancelled)
        XCTAssertEqual(sessions.first(where: { $0.id == unrelated.id })?.status, .validating)
        XCTAssertEqual(sessions.first(where: { $0.id == replacementID })?.status, .preparing)
    }

    func testLiveSyncDoesNotIngestRecordsWhileFarmCacheIsRebuilding() async throws {
        let container = try AppSchema.makeContainer(name: "locked-live-ingest", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let placeholder = FarmRecord(id: farmID, ownerAccountID: ownerID, name: "正在从 iCloud 恢复的牧场")
        context.insert(placeholder)
        context.insert(CloudFarmBinding(farmID: farmID, ownerAccountID: ownerID, state: .rebuildingCache))
        try context.save()
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        let root = CloudRecordMapper().rootRecord(farmID: farmID, farmName: "不应提前写入", ownerAccountID: ownerID, zoneID: zoneID)

        try await FarmPersistenceActor(container: container).ingest([root], scope: .privateDatabase)

        let verify = ModelContext(container)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID })?.name, "正在从 iCloud 恢复的牧场")
        XCTAssertTrue(try verify.fetch(FetchDescriptor<SecurityIncidentRecord>()).isEmpty)
    }

    func testRecoveredBootstrapRestoresLocalCloudAdmissionMetadata() async throws {
        let container = try AppSchema.makeContainer(name: "recovered-bootstrap", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "恢复中"))
        try context.save()
        let operation = try makeOperation(farmID: farmID, command: .createPen(name: "云端圈舍", note: ""), entityType: .pen)
        let bootstrap = CloudRebuildBootstrapSnapshot(digest: "verified-digest", entityCount: 123, photoCount: 7)
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation], bootstrap: bootstrap)

        _ = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(using: bundle)

        let verify = ModelContext(container)
        let commit = try XCTUnwrap(try verify.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.farmID == farmID }))
        XCTAssertEqual(commit.cloudState, .synced)
        XCTAssertEqual(commit.baselineDigest, bootstrap.digest)
        XCTAssertEqual(commit.baselineEntityCount, bootstrap.entityCount)
        XCTAssertEqual(commit.baselinePhotoCount, bootstrap.photoCount)
    }

    private func makeOperation(
        farmID: UUID,
        command: FarmCommand,
        entityType: CloudEntityType,
        entityID: UUID = UUID()
    ) throws -> CloudOperationEnvelope {
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        return CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: entityType.rawValue,
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
    }

    private func makeSignedOperation(
        command: FarmCommand,
        entityType: CloudEntityType,
        entityID: UUID = UUID(),
        modifiedAt: Date,
        privateKey: P256.Signing.PrivateKey
    ) throws -> CloudOperationEnvelope {
        let unsigned = try makeUnsignedOperation(
            command: command,
            entityType: entityType,
            entityID: entityID,
            modifiedAt: modifiedAt
        )
        return replacingSignature(
            in: unsigned,
            with: try privateKey.signature(for: unsigned.canonicalSigningData).rawRepresentation
        )
    }

    private func makeSupersededTombstoneFixture() throws -> (
        rejected: CloudOperationEnvelope,
        authoritative: CloudOperationEnvelope,
        tombstone: FarmTombstoneEnvelope
    ) {
        let farmID = UUID()
        let entityID = UUID()
        let accountID = UUID()
        let deviceID = UUID()
        let payload = try FarmCommandCloudPayloadEncoder.encode(
            .tombstoneEntity(entityType: .note, entityID: entityID, reason: "录入错误")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            FarmCommandCloudPayload.self,
            from: payload
        )
        let deletedAt = try XCTUnwrap(decoded.dates["deletedAt"])
        let authoritative = CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: CloudEntityType.note.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: deletedAt,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: deviceID,
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "current-delete-capability",
            operationSignature: Data("authoritative-signature".utf8),
            deletedAt: deletedAt
        )
        let rejected = CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: CloudEntityType.note.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: deletedAt.addingTimeInterval(-10),
            modifiedByAccountID: accountID,
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "legacy-without-delete-capability",
            operationSignature: Data("legacy-signature".utf8),
            deletedAt: deletedAt
        )
        let tombstone = FarmTombstoneEnvelope(
            tombstoneID: UUID(),
            farmID: farmID,
            entityType: authoritative.entityType,
            entityID: entityID,
            revision: authoritative.revision,
            deletedAt: deletedAt,
            deletedByAccountID: accountID,
            reason: "录入错误",
            operationID: authoritative.operationID,
            restoresTombstoneID: nil
        )
        return (rejected, authoritative, tombstone)
    }

    private func makeUnsignedOperation(
        command: FarmCommand,
        entityType: CloudEntityType,
        entityID: UUID = UUID(),
        modifiedAt: Date
    ) throws -> CloudOperationEnvelope {
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let resolvedFarmID = entityType == .farm ? entityID : UUID()
        return CloudOperationEnvelope(
            farmID: resolvedFarmID,
            entityID: entityID,
            entityType: entityType.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
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
    }

    private func replacingSignature(
        in envelope: CloudOperationEnvelope,
        with signature: Data
    ) -> CloudOperationEnvelope {
        CloudOperationEnvelope(
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
    }

    private func replacingTiming(
        in envelope: CloudOperationEnvelope,
        modifiedAt: Date,
        deletedAt: Date? = nil
    ) -> CloudOperationEnvelope {
        CloudOperationEnvelope(
            farmID: envelope.farmID,
            entityID: envelope.entityID,
            entityType: envelope.entityType,
            schemaVersion: envelope.schemaVersion,
            revision: envelope.revision,
            baseRevision: envelope.baseRevision,
            operationID: envelope.operationID,
            modifiedAt: modifiedAt,
            modifiedByAccountID: envelope.modifiedByAccountID,
            modifiedByDeviceID: envelope.modifiedByDeviceID,
            payload: envelope.payload,
            payloadDigest: envelope.payloadDigest,
            capabilityCertificate: envelope.capabilityCertificate,
            operationSignature: envelope.operationSignature,
            deletedAt: deletedAt
        )
    }

    func testPrivateOwnerMembershipSnapshotBootstrapsHistoricalDeviceTrust() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let historicalDeviceID = UUID()
        let issuedAt = Date(timeIntervalSince1970: 1_767_225_600)
        let authorityKey = P256.Signing.PrivateKey()
        let historicalKey = P256.Signing.PrivateKey()
        let envelope = FarmMembershipSnapshotEnvelope(
            farmID: farmID,
            generation: 3,
            issuedAt: issuedAt,
            members: [
                .init(
                    membershipID: "owner-membership",
                    accountID: ownerID,
                    role: .owner,
                    status: "active",
                    shareParticipantRecordName: nil
                ),
            ],
            devices: [
                .init(
                    deviceID: historicalDeviceID,
                    accountID: ownerID,
                    publicKeyJWK: try jwkJSON(
                        for: historicalKey.publicKey
                    )
                ),
            ],
            revokedCertificates: []
        )
        let payload = try JSONEncoder.cloud.encode(envelope)
        let digest = CloudPayloadDigest.hex(for: payload)
        let claims = CapabilityCertificateClaims(
            certificateID: "owner-certificate",
            accountID: ownerID,
            farmID: farmID,
            deviceID: historicalDeviceID,
            role: .owner,
            capabilities: [.readFarm, .manageMembers],
            iat: Int(issuedAt.timeIntervalSince1970) - 60,
            exp: Int(issuedAt.timeIntervalSince1970) + 3_600,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )
        let certificate = try makeCapabilityCertificate(
            claims: claims,
            signingKey: authorityKey
        )
        let signingData = MembershipSnapshotActor.signingData(
            farmID: farmID,
            generation: envelope.generation,
            issuedAt: issuedAt,
            payloadDigest: digest,
            accountID: ownerID,
            deviceID: historicalDeviceID
        )
        let zoneID = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(farmID),
            ownerName: CKCurrentUserDefaultName
        )
        let record = CKRecord(
            recordType: CloudRecordType.farmMembershipSnapshot.rawValue,
            recordID: .init(
                recordName: "membership_snapshot",
                zoneID: zoneID
            )
        )
        record[CloudRecordField.farmID] =
            farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.generation] =
            envelope.generation as CKRecordValue
        record[CloudRecordField.issuedAt] = issuedAt as CKRecordValue
        record[CloudRecordField.payload] = payload as CKRecordValue
        record[CloudRecordField.payloadDigest] = digest as CKRecordValue
        record[CloudRecordField.modifiedByAccountID] =
            ownerID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.modifiedByDeviceID] =
            historicalDeviceID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.capabilityCertificate] =
            certificate as CKRecordValue
        record[CloudRecordField.signature] = try historicalKey
            .signature(for: signingData).rawRepresentation as CKRecordValue

        let binding = CloudFarmBindingSnapshot(
            farmID: farmID,
            ownerAccountID: ownerID,
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            databaseScope: .privateDatabase,
            shareRecordName: nil,
            state: .rebuildingCache,
            lastErrorCode: nil
        )
        let root = CloudRebuildRootSnapshot(
            farmID: farmID,
            name: "吉昊羊场",
            ownerAccountID: ownerID,
            modifiedAt: issuedAt
        )
        let localTrust = CloudTrustSnapshot(
            capabilityPublicKeyPEM:
                authorityKey.publicKey.pemRepresentation,
            devicePublicKeys: [:],
            revokedCertificateIDs: []
        )

        let restored = try CloudRebuildActor.privateOwnerBootstrapTrust(
            records: [record],
            binding: binding,
            root: root,
            localTrust: localTrust
        )
        XCTAssertEqual(
            restored.devicePublicKeys[historicalDeviceID],
            historicalKey.publicKey.x963Representation
        )

        let sharedBinding = CloudFarmBindingSnapshot(
            farmID: farmID,
            ownerAccountID: ownerID,
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            databaseScope: .sharedDatabase,
            shareRecordName: nil,
            state: .rebuildingCache,
            lastErrorCode: nil
        )
        let sharedTrust = try CloudRebuildActor
            .privateOwnerBootstrapTrust(
                records: [record],
                binding: sharedBinding,
                root: root,
                localTrust: localTrust
            )
        XCTAssertNil(sharedTrust.devicePublicKeys[historicalDeviceID])
    }

    func testPrivateOwnerTrustRejectsTamperedMembershipSignature() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let deviceID = UUID()
        let issuedAt = Date(timeIntervalSince1970: 1_767_225_600)
        let authorityKey = P256.Signing.PrivateKey()
        let deviceKey = P256.Signing.PrivateKey()
        let envelope = FarmMembershipSnapshotEnvelope(
            farmID: farmID,
            generation: 1,
            issuedAt: issuedAt,
            members: [
                .init(
                    membershipID: "owner-membership",
                    accountID: ownerID,
                    role: .owner,
                    status: "active",
                    shareParticipantRecordName: nil
                ),
            ],
            devices: [
                .init(
                    deviceID: deviceID,
                    accountID: ownerID,
                    publicKeyJWK: try jwkJSON(for: deviceKey.publicKey)
                ),
            ],
            revokedCertificates: []
        )
        let payload = try JSONEncoder.cloud.encode(envelope)
        let claims = CapabilityCertificateClaims(
            certificateID: "owner-certificate",
            accountID: ownerID,
            farmID: farmID,
            deviceID: deviceID,
            role: .owner,
            capabilities: [.manageMembers],
            iat: Int(issuedAt.timeIntervalSince1970) - 60,
            exp: Int(issuedAt.timeIntervalSince1970) + 3_600,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )
        let zoneID = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(farmID),
            ownerName: CKCurrentUserDefaultName
        )
        let record = CKRecord(
            recordType: CloudRecordType.farmMembershipSnapshot.rawValue,
            recordID: .init(
                recordName: "membership_snapshot",
                zoneID: zoneID
            )
        )
        record[CloudRecordField.farmID] =
            farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.generation] = 1 as CKRecordValue
        record[CloudRecordField.issuedAt] = issuedAt as CKRecordValue
        record[CloudRecordField.payload] = payload as CKRecordValue
        record[CloudRecordField.payloadDigest] =
            CloudPayloadDigest.hex(for: payload) as CKRecordValue
        record[CloudRecordField.modifiedByAccountID] =
            ownerID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.modifiedByDeviceID] =
            deviceID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.capabilityCertificate] =
            try makeCapabilityCertificate(
                claims: claims,
                signingKey: authorityKey
            ) as CKRecordValue
        record[CloudRecordField.signature] =
            Data(repeating: 0, count: 64) as CKRecordValue

        XCTAssertThrowsError(
            try CloudRebuildActor.privateOwnerBootstrapTrust(
                records: [record],
                binding: CloudFarmBindingSnapshot(
                    farmID: farmID,
                    ownerAccountID: ownerID,
                    zoneName: zoneID.zoneName,
                    zoneOwnerName: zoneID.ownerName,
                    databaseScope: .privateDatabase,
                    shareRecordName: nil,
                    state: .rebuildingCache,
                    lastErrorCode: nil
                ),
                root: CloudRebuildRootSnapshot(
                    farmID: farmID,
                    name: "吉昊羊场",
                    ownerAccountID: ownerID,
                    modifiedAt: issuedAt
                ),
                localTrust: CloudTrustSnapshot(
                    capabilityPublicKeyPEM:
                        authorityKey.publicKey.pemRepresentation,
                    devicePublicKeys: [:],
                    revokedCertificateIDs: []
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudContractError,
                .invalidDeviceSignature
            )
        }
    }

    func testMembershipSnapshotEnvelopeAdditivelyCarriesHistoricalOwnerDevices() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let currentDeviceID = UUID()
        let historicalDeviceID = UUID()
        let currentKey = P256.Signing.PrivateKey()
        let historicalKey = P256.Signing.PrivateKey()
        let snapshot = WorkerFarmSecuritySnapshot(
            farmID: farmID,
            generation: 4,
            issuedAt: 1_775_000_000,
            members: [
                .init(
                    membershipID: "owner-membership",
                    accountID: ownerID,
                    displayName: "场主",
                    role: .owner,
                    status: "active",
                    shareParticipantRecordName: nil
                ),
            ],
            devices: [
                .init(
                    deviceID: currentDeviceID,
                    accountID: ownerID,
                    publicKeyJWK: try jwkJSON(for: currentKey.publicKey)
                ),
            ],
            revokedCertificates: []
        )
        let historical = FarmMembershipSnapshotEnvelope.Device(
            deviceID: historicalDeviceID,
            accountID: ownerID,
            publicKeyJWK: try jwkJSON(for: historicalKey.publicKey)
        )

        let envelope = try MembershipSnapshotActor.envelope(
            from: snapshot,
            additionalDevices: [historical]
        )

        XCTAssertEqual(envelope.generation, 4)
        XCTAssertEqual(Set(envelope.devices.map(\.deviceID)), [
            currentDeviceID,
            historicalDeviceID,
        ])
    }

    func testMembershipSnapshotEnvelopeRejectsHistoricalDeviceKeyReplacement() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let deviceID = UUID()
        let originalKey = P256.Signing.PrivateKey()
        let replacementKey = P256.Signing.PrivateKey()
        let snapshot = WorkerFarmSecuritySnapshot(
            farmID: farmID,
            generation: 4,
            issuedAt: 1_775_000_000,
            members: [
                .init(
                    membershipID: "owner-membership",
                    accountID: ownerID,
                    displayName: "场主",
                    role: .owner,
                    status: "active",
                    shareParticipantRecordName: nil
                ),
            ],
            devices: [
                .init(
                    deviceID: deviceID,
                    accountID: ownerID,
                    publicKeyJWK: try jwkJSON(for: originalKey.publicKey)
                ),
            ],
            revokedCertificates: []
        )
        let replacement = FarmMembershipSnapshotEnvelope.Device(
            deviceID: deviceID,
            accountID: ownerID,
            publicKeyJWK: try jwkJSON(for: replacementKey.publicKey)
        )

        XCTAssertThrowsError(
            try MembershipSnapshotActor.envelope(
                from: snapshot,
                additionalDevices: [replacement]
            )
        ) { error in
            XCTAssertEqual(error as? CloudContractError, .invalidDeviceSignature)
        }
    }

    func testFetchCheckpointRecordArchiveRoundTripsCloudRecordAndAssetPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cloud-rebuild-record-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetURL = root.appending(path: "photo.jpg")
        try Data("photo".utf8).write(to: assetURL)
        let zoneID = CKRecordZone.ID(
            zoneName: "farm-zone",
            ownerName: CKCurrentUserDefaultName
        )
        let record = CKRecord(
            recordType: CloudRecordType.farmAsset.rawValue,
            recordID: .init(recordName: "asset_test", zoneID: zoneID)
        )
        record[CloudRecordField.farmID] = UUID().uuidString as CKRecordValue
        record[CloudRecordField.asset] = CKAsset(fileURL: assetURL)

        let archive = try CloudRebuildFetchCheckpointStore.encodeRecords([record])
        let decoded = try CloudRebuildFetchCheckpointStore.decodeRecords(archive)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].recordID, record.recordID)
        XCTAssertEqual(
            (decoded[0][CloudRecordField.asset] as? CKAsset)?.fileURL,
            assetURL
        )
    }

    private func makeClaims(
        for envelope: CloudOperationEnvelope,
        capabilities: [FarmCapability],
        authorizationDate: Date
    ) -> CapabilityCertificateClaims {
        CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: envelope.modifiedByAccountID,
            farmID: envelope.farmID,
            deviceID: envelope.modifiedByDeviceID,
            role: .owner,
            capabilities: capabilities,
            iat: Int(authorizationDate.timeIntervalSince1970) - 10,
            exp: Int(authorizationDate.timeIntervalSince1970) + 300,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )
    }

    private func makeBundle(
        sessionID: UUID = UUID(),
        farmID: UUID,
        ownerID: UUID,
        operations: [CloudOperationEnvelope],
        assets: [CloudRebuildAssetSnapshot] = [],
        bootstrap: CloudRebuildBootstrapSnapshot? = nil,
        scope: CloudDatabaseScope = .privateDatabase,
        authorityProofVersion: Int? = CloudRebuildActor.currentAuthorityProofVersion
    ) -> CloudRebuildBundle {
        let operationSourceProofs: [CloudRebuildOperationSourceProof]? =
            authorityProofVersion == CloudRebuildActor.currentAuthorityProofVersion
            ? operations.map { operation in
                let zoneID = CKRecordZone.ID(
                    zoneName: CloudZoneName.forFarm(farmID),
                    ownerName: CKCurrentUserDefaultName
                )
                return try! CloudRebuildOperationSourceProof(
                    record: CloudRecordMapper().operationRecord(from: operation, zoneID: zoneID),
                    envelope: operation
                )
            }
            : nil
        return CloudRebuildBundle(
            sessionID: sessionID,
            farmID: farmID,
            scope: scope,
            root: CloudRebuildRootSnapshot(farmID: farmID, name: "云端牧场", ownerAccountID: ownerID, modifiedAt: .now),
            authorityProofVersion: authorityProofVersion,
            operationSourceProofs: operationSourceProofs,
            bootstrap: bootstrap,
            operations: operations,
            assets: assets,
            membershipSnapshot: nil,
            deletedRecordNames: [],
            pageCount: 2,
            recordCount: operations.count + assets.count + 1,
            createdAt: .now
        )
    }

    private func makeCapabilityCertificate(
        claims: CapabilityCertificateClaims,
        signingKey: P256.Signing.PrivateKey
    ) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: [
            "alg": "ES256",
            "kid": "private-owner-bootstrap-test",
            "typ": "esheep-capability+jwt",
        ], options: [.sortedKeys])
        let payload = try JSONEncoder().encode(claims)
        let encodedHeader = base64URL(header)
        let encodedPayload = base64URL(payload)
        let signedText = "\(encodedHeader).\(encodedPayload)"
        let signature = try signingKey.signature(
            for: Data(signedText.utf8)
        ).rawRepresentation
        return "\(signedText).\(base64URL(signature))"
    }

    private func jwkJSON(
        for publicKey: P256.Signing.PublicKey
    ) throws -> String {
        let representation = publicKey.x963Representation
        let coordinates = representation.dropFirst()
        let object = [
            "alg": "ES256",
            "crv": "P-256",
            "kty": "EC",
            "use": "sig",
            "x": base64URL(Data(coordinates.prefix(32))),
            "y": base64URL(Data(coordinates.dropFirst(32).prefix(32))),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
