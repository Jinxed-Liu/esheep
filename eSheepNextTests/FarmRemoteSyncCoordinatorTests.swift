import SwiftData
import XCTest
@testable import eSheepNext

final class FarmRemoteSyncCoordinatorTests: XCTestCase {
    @MainActor
    func testSuspendedNetworkStopsBeforeTransportWork() async throws {
        let container = try AppSchema.makeContainer(
            name: "remote-suspended-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let transport = ICloudFarmTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in
                XCTFail("A suspended coordinator must not push")
                return []
            },
            pullOperations: { _, _, revision, _ in
                XCTFail("A suspended coordinator must not pull")
                return FarmRemotePullPage(
                    operations: [],
                    cursorRevision: revision,
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
            },
            members: { _ in [] },
            deactivate: { _, _, _ in }
        ))
        let coordinator = FarmRemoteSyncCoordinator(
            container: container,
            transport: transport,
            shouldSuspendNetwork: { true }
        )

        do {
            _ = try await coordinator.synchronize(farmID: UUID())
            XCTFail("Expected the Development network gate to cancel sync")
        } catch is CancellationError {
            // Expected: no local delivery state or transport request is touched.
        }
    }

    @MainActor
    func testSuccessfulEmptyPullClearsStaleBindingError() async throws {
        let container = try AppSchema.makeContainer(
            name: "remote-no-op-pull-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let binding = FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        )
        binding.lastPulledRevision = 492
        binding.lastErrorCode = "NSURLError:-1200"
        context.insert(binding)
        try context.save()

        let transport = ICloudFarmTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in [] },
            pullOperations: { _, _, revision, _ in
                FarmRemotePullPage(
                    operations: [],
                    cursorRevision: revision,
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
            },
            members: { _ in [] },
            deactivate: { _, _, _ in }
        ))
        let result = try await FarmRemoteSyncCoordinator(
            container: container,
            transport: transport
        ).synchronize(farmID: farmID)

        XCTAssertEqual(result.cursorRevision, 492)
        XCTAssertEqual(result.downloadedOperationCount, 0)
        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FarmRemoteBinding>()).first
        )
        XCTAssertNil(stored.lastErrorCode)
        XCTAssertNotNil(stored.lastSuccessfulSyncAt)
    }

    func testDuplicateTombstonesForOneOperationAreReducedWithoutTrapping() {
        let farmID = UUID()
        let operationID = UUID()
        let entityID = UUID()
        let accountID = UUID()
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let first = TombstoneRecord(
            farmID: farmID,
            entityType: CloudEntityType.removal.rawValue,
            entityID: entityID,
            deletedByAccountID: accountID,
            reason: "重复删除事实",
            operationID: operationID
        )
        first.deletedAt = later
        let duplicate = TombstoneRecord(
            farmID: farmID,
            entityType: CloudEntityType.removal.rawValue,
            entityID: entityID,
            deletedByAccountID: accountID,
            reason: "重复删除事实",
            operationID: operationID
        )
        duplicate.deletedAt = earlier
        let anotherFarm = TombstoneRecord(
            farmID: UUID(),
            entityType: CloudEntityType.removal.rawValue,
            entityID: entityID,
            deletedByAccountID: accountID,
            reason: "其他牧场",
            operationID: operationID
        )

        let result = FarmRemoteSyncCoordinator.tombstoneDeletedAtByOperationID(
            [first, duplicate, anotherFarm],
            farmID: farmID,
            operationIDs: [operationID]
        )

        XCTAssertEqual(result, [operationID: earlier])
    }

    @MainActor
    func testAcceptingRemoteUpdatePenSupersedesBlockedOutbox() throws {
        let container = try AppSchema.makeContainer(
            name: "accept-remote-update-pen-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let penID = UUID()
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: ownerID,
            name: "冲突测试牧场"
        )
        let pen = PenRecord(
            id: penID,
            farmID: farmID,
            name: "本机名称",
            note: "本机版本"
        )
        pen.revision = 2
        let localPayload = try FarmCommandCloudPayloadEncoder.encode(
            .updatePen(penID: penID, name: "本机名称", note: "本机版本")
        )
        let remotePayload = try FarmCommandCloudPayloadEncoder.encode(
            .updatePen(penID: penID, name: "远端名称", note: "远端版本")
        )
        let conflict = SyncConflictRecord(
            farmID: farmID,
            entityID: penID,
            entityType: CloudEntityType.pen.rawValue,
            localRevision: 2,
            remoteRevision: 2,
            localPayload: localPayload,
            remotePayload: remotePayload,
            reasonCode: "baseRevisionConflict"
        )
        let blockedOperationID = UUID()
        let blocked = OutboxItem(
            farmID: farmID,
            accountID: ownerID,
            operationID: blockedOperationID,
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            baseRevision: 1,
            payloadDigest: CloudPayloadDigest.hex(for: localPayload),
            deliveryProvider: .supabase,
            authorityGeneration: 1
        )
        blocked.statusRawValue = OutboxStatus.blockedConflict.rawValue
        context.insert(farm)
        context.insert(pen)
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .supabase,
            authorityGeneration: 1
        ))
        context.insert(conflict)
        context.insert(blocked)
        try context.save()

        let resolutionID = try FarmCommandService().resolveConflict(
            conflictID: conflict.id,
            decision: .acceptRemote,
            note: "采用远端圈舍版本",
            in: FarmContext(
                accountID: ownerID,
                farmID: farmID,
                role: .owner
            ),
            context: context
        )

        XCTAssertEqual(pen.name, "远端名称")
        XCTAssertEqual(pen.note, "远端版本")
        XCTAssertEqual(pen.revision, 3)
        XCTAssertEqual(conflict.statusRawValue, SyncConflictStatus.acceptedRemote.rawValue)
        XCTAssertEqual(conflict.resolutionOperationID, resolutionID)
        XCTAssertEqual(blocked.status, .supersededRemoteAuthority)
        XCTAssertNil(blocked.nextRetryAt)
        XCTAssertTrue(blocked.errorMessage?.contains(
            resolutionID.uuidString.lowercased()
        ) == true)
        let resolutionOutbox = try context.fetch(FetchDescriptor<OutboxItem>())
            .filter { $0.operationID == resolutionID }
        XCTAssertEqual(resolutionOutbox.count, 1)
        XCTAssertEqual(resolutionOutbox.first?.deliveryProvider, .supabase)
        XCTAssertEqual(resolutionOutbox.first?.authorityGeneration, 1)
    }

    @MainActor
    func testResolvedConflictProjectionReconciliationIsIdempotent() throws {
        let container = try AppSchema.makeContainer(
            name: "reconcile-resolved-conflict-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let penID = UUID()
        let conflictID = UUID()
        let localPayload = try FarmCommandCloudPayloadEncoder.encode(
            .updatePen(penID: penID, name: "本机名称", note: "本机版本")
        )
        let remotePayload = try FarmCommandCloudPayloadEncoder.encode(
            .updatePen(penID: penID, name: "远端名称", note: "远端版本")
        )
        let conflict = SyncConflictRecord(
            id: conflictID,
            farmID: farmID,
            entityID: penID,
            entityType: CloudEntityType.pen.rawValue,
            localRevision: 2,
            remoteRevision: 2,
            localPayload: localPayload,
            remotePayload: remotePayload,
            reasonCode: "baseRevisionConflict"
        )
        let blocked = OutboxItem(
            farmID: farmID,
            accountID: ownerID,
            operationID: UUID(),
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            baseRevision: 1,
            payloadDigest: CloudPayloadDigest.hex(for: localPayload),
            deliveryProvider: .supabase,
            authorityGeneration: 1
        )
        blocked.statusRawValue = OutboxStatus.blockedConflict.rawValue
        var resolutionPayload = FarmCommandCloudPayload(kind: .resolveConflict)
        resolutionPayload.identifiers = [
            "conflictID": conflictID,
            "entityID": penID
        ]
        resolutionPayload.strings = [
            "entityType": CloudEntityType.pen.rawValue,
            "decision": SyncConflictStatus.acceptedRemote.rawValue,
            "note": "远端场主已解决"
        ]
        resolutionPayload.integers = [
            "localRevision": 2,
            "remoteRevision": 2,
            "resolvedRevision": 3
        ]
        resolutionPayload.dataValues = ["resolvedPayload": remotePayload]
        let resolutionID = UUID()
        let resolution = DomainOperation(
            id: resolutionID,
            farmID: farmID,
            accountID: ownerID,
            kind: .resolveConflict,
            summary: "解决同步冲突",
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            baseRevision: 2,
            resultingRevision: 3,
            payload: try JSONEncoder.cloud.encode(resolutionPayload)
        )
        context.insert(conflict)
        context.insert(blocked)
        context.insert(resolution)
        try context.save()

        XCTAssertEqual(
            try RemoteDomainApplyService.reconcileResolvedConflictProjections(
                farmID: farmID,
                context: context
            ),
            1
        )
        XCTAssertEqual(conflict.statusRawValue, SyncConflictStatus.ownerResolved.rawValue)
        XCTAssertEqual(conflict.resolutionOperationID, resolutionID)
        XCTAssertEqual(blocked.status, .supersededRemoteAuthority)
        XCTAssertEqual(
            try RemoteDomainApplyService.reconcileResolvedConflictProjections(
                farmID: farmID,
                context: context
            ),
            0
        )
    }

    @MainActor
    func testProviderNeutralEnvelopeRebuildsTheSameBusinessProjection() throws {
        let first = try AppSchema.makeContainer(
            name: "provider-contract-first-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let second = try AppSchema.makeContainer(
            name: "provider-contract-second-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let farmID = UUID()
        let sheepID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let command = FarmCommand.addSheep(
            earTag: "CONTRACT-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            occurredAt: occurredAt,
            birthAt: Date(timeIntervalSince1970: 1_650_000_000),
            currentParity: 3,
            note: "provider-neutral"
        )
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: sheepID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        for container in [first, second] {
            let context = ModelContext(container)
            XCTAssertEqual(
                try RemoteDomainApplyService().apply(envelope, context: context),
                .applied(rebuildHistoryFrom: occurredAt)
            )
            try context.save()
        }

        XCTAssertEqual(
            try projectionSummary(container: first, farmID: farmID),
            try projectionSummary(container: second, farmID: farmID)
        )
    }

    @MainActor
    private func projectionSummary(
        container: ModelContainer,
        farmID: UUID
    ) throws -> [String] {
        let context = ModelContext(container)
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farmID
        }
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>()).filter {
            $0.farmID == farmID
        }
        return sheep.map {
            "sheep|\($0.id.uuidString)|\($0.earTag)|\($0.sex.rawValue)|\($0.revision)"
        }.sorted() + reproduction.map {
            "reproduction|\($0.id.uuidString)|\($0.kind.rawValue)|\($0.parity ?? -1)"
        }.sorted()
    }
}
