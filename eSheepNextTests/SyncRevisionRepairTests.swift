import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class SyncRevisionRepairTests: XCTestCase {
    func testHomeSnapshotSeparatesDeliverableWorkFromConflicts() async throws {
        let fixture = try makeFixture()
        let statuses: [OutboxStatus] = [
            .pending,
            .uploading,
            .awaitingConfirmation,
            .retryableFailure,
            .blockedConflict,
            .rejectedPermission,
            .confirmed,
        ]
        for status in statuses {
            let entityID = UUID()
            _ = insertOperation(
                fixture: fixture,
                kind: .addNote,
                entityType: .note,
                entityID: entityID,
                baseRevision: 0,
                resultingRevision: 1,
                payload: Data("{}".utf8),
                status: status
            )
        }
        try fixture.context.save()

        let snapshot = try await FarmHomeSnapshotActor(
            container: fixture.container
        ).load(farmID: fixture.farm.id)
        XCTAssertEqual(snapshot.pendingOutboxCount, 4)
        XCTAssertEqual(snapshot.conflictOutboxCount, 2)
    }

    func testRecreatedRemovalReusesProjectionAndContinuesRevisionChain() throws {
        let fixture = try makeFixture()
        let removalID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_780_000_000)

        try fixture.service.execute(
            .removeSheep(
                sheepID: fixture.sheep.id,
                kind: .deceased,
                reason: "肺炎",
                amountText: nil,
                occurredAt: occurredAt,
                note: "首次记录",
                recordID: removalID
            ),
            in: fixture.farmContext,
            context: fixture.context
        )
        try fixture.service.execute(
            .restoreSheep(removalID: removalID),
            in: fixture.farmContext,
            context: fixture.context
        )
        try fixture.service.execute(
            .removeSheep(
                sheepID: fixture.sheep.id,
                kind: .deceased,
                reason: "肺炎",
                amountText: nil,
                occurredAt: occurredAt,
                note: "重新导入",
                recordID: removalID
            ),
            in: fixture.farmContext,
            context: fixture.context
        )

        let projections = try fixture.context.fetch(FetchDescriptor<RemovalRecord>()).filter {
            $0.id == removalID
        }
        let projection = try XCTUnwrap(projections.first)
        XCTAssertEqual(projections.count, 1)
        XCTAssertNil(projection.deletedAt)
        XCTAssertEqual(projection.revision, 3)
        XCTAssertEqual(projection.note, "重新导入")
        let operations = try fixture.context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.entityID == removalID
        }.sorted { $0.resultingRevision < $1.resultingRevision }
        XCTAssertEqual(operations.map(\.baseRevision), [0, 1, 2])
        XCTAssertEqual(operations.map(\.resultingRevision), [1, 2, 3])
    }

    func testBlockedRecreatedRemovalCreatesRevisionAwareRetryAndConsolidatesProjection() throws {
        let fixture = try makeFixture()
        let removalID = UUID()
        let payload = try FarmCommandCloudPayloadEncoder.encode(.removeSheep(
            sheepID: fixture.sheep.id,
            kind: .deceased,
            reason: "梭菌感染",
            amountText: nil,
            occurredAt: .now,
            note: "重新导入",
            recordID: removalID
        ))
        let stale = RemovalRecord(
            id: removalID,
            farmID: fixture.farm.id,
            sheepID: fixture.sheep.id,
            kind: .deceased,
            reason: "梭菌感染",
            occurredAt: .now,
            note: "旧投影"
        )
        stale.revision = 1
        stale.deletedAt = .now
        let active = RemovalRecord(
            id: removalID,
            farmID: fixture.farm.id,
            sheepID: fixture.sheep.id,
            kind: .deceased,
            reason: "梭菌感染",
            occurredAt: .now,
            note: "重新导入"
        )
        fixture.context.insert(stale)
        fixture.context.insert(active)
        _ = insertOperation(
            fixture: fixture,
            kind: .removeSheep,
            entityType: .removal,
            entityID: removalID,
            baseRevision: 0,
            resultingRevision: 1,
            payload: payload,
            status: .confirmed
        )
        _ = insertOperation(
            fixture: fixture,
            kind: .restoreSheep,
            entityType: .removal,
            entityID: removalID,
            baseRevision: 1,
            resultingRevision: 2,
            payload: try FarmCommandCloudPayloadEncoder.encode(.restoreSheep(removalID: removalID)),
            status: .confirmed
        )
        let blocked = insertOperation(
            fixture: fixture,
            kind: .removeSheep,
            entityType: .removal,
            entityID: removalID,
            baseRevision: 0,
            resultingRevision: 1,
            payload: payload,
            status: .blockedConflict
        )
        blocked.errorMessage = "base_revision_mismatch"
        try fixture.context.save()

        XCTAssertEqual(
            try fixture.service.repairBlockedRecreatedRemovalOperations(
                farmID: fixture.farm.id,
                context: fixture.context
            ),
            1
        )

        let projections = try fixture.context.fetch(FetchDescriptor<RemovalRecord>()).filter {
            $0.id == removalID
        }
        XCTAssertEqual(projections.count, 1)
        XCTAssertNil(projections.first?.deletedAt)
        XCTAssertEqual(projections.first?.revision, 3)
        XCTAssertEqual(blocked.status, .supersededRemoteAuthority)
        let retry = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<OutboxItem>()).first {
            $0.entityID == removalID && $0.status == .pending
        })
        XCTAssertEqual(retry.baseRevision, 2)
        let retryOperation = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).first {
            $0.id == retry.operationID
        })
        XCTAssertEqual(retryOperation.resultingRevision, 3)
    }

    func testMissingBatchMembershipProjectionBackfillsAndSupersedesCoveredChain() throws {
        let fixture = try makeFixture()
        let batch = ProductionBatchRecord(
            farmID: fixture.farm.id,
            name: "第八批实验羊",
            purpose: "试验",
            startedAt: .now
        )
        let membership = BatchMembershipRecord(
            id: UUID(),
            farmID: fixture.farm.id,
            batchID: batch.id,
            sheepID: fixture.sheep.id,
            joinedAt: .now
        )
        fixture.context.insert(batch)
        fixture.context.insert(membership)
        _ = insertOperation(
            fixture: fixture,
            kind: .createBatch,
            entityType: .productionBatch,
            entityID: batch.id,
            baseRevision: 0,
            resultingRevision: 1,
            payload: try FarmCommandCloudPayloadEncoder.encode(.createBatch(
                name: batch.name,
                purpose: batch.purpose,
                startedAt: batch.startedAt,
                sheepIDs: [fixture.sheep.id],
                note: ""
            )),
            status: .confirmed
        )
        let leave = insertOperation(
            fixture: fixture,
            kind: .leaveBatchMembership,
            entityType: .batchMembership,
            entityID: membership.id,
            baseRevision: 1,
            resultingRevision: 2,
            payload: try FarmCommandCloudPayloadEncoder.encode(.leaveBatch(
                batchID: batch.id,
                sheepID: fixture.sheep.id,
                leftAt: .now,
                reason: "误操作"
            )),
            status: .blockedConflict
        )
        leave.errorMessage = "base_revision_mismatch"
        let restore = insertOperation(
            fixture: fixture,
            kind: .restoreBatchMembership,
            entityType: .batchMembership,
            entityID: membership.id,
            baseRevision: 2,
            resultingRevision: 3,
            payload: try FarmCommandCloudPayloadEncoder.encode(.restoreBatchMembership(
                membershipID: membership.id,
                restoredAt: .now,
                reason: "撤回误操作"
            )),
            status: .blockedConflict
        )
        restore.errorMessage = "base_revision_mismatch"
        try fixture.context.save()

        XCTAssertEqual(
            try fixture.service.repairMissingProductionBatchMembershipDeliveryOperations(
                farmID: fixture.farm.id,
                context: fixture.context
            ),
            1
        )
        let projectionOutbox = try XCTUnwrap(
            try fixture.context.fetch(FetchDescriptor<OutboxItem>()).first {
                $0.entityID == membership.id && $0.status == .pending
            }
        )
        projectionOutbox.statusRawValue = OutboxStatus.confirmed.rawValue
        try fixture.context.save()

        XCTAssertEqual(
            try fixture.service.supersedeBlockedBatchMembershipChainsCoveredByConfirmedProjection(
                farmID: fixture.farm.id,
                context: fixture.context
            ),
            2
        )
        XCTAssertEqual(leave.status, .supersededRemoteAuthority)
        XCTAssertEqual(restore.status, .supersededRemoteAuthority)
    }

    func testBaselineSheepRevisionDriftRebasesOnlyWithoutAnotherAuthoritativeOperation() throws {
        let fixture = try makeFixture()
        fixture.sheep.revision = 3
        let payload = try FarmCommandCloudPayloadEncoder.encode(.updateSheepProfile(
            sheepID: fixture.sheep.id,
            earTag: fixture.sheep.earTag,
            breed: "湖羊",
            sex: .ewe,
            birthAt: nil,
            note: "本地档案"
        ))
        let blocked = insertOperation(
            fixture: fixture,
            kind: .updateSheepProfile,
            entityType: .sheep,
            entityID: fixture.sheep.id,
            baseRevision: 2,
            resultingRevision: 3,
            payload: payload,
            status: .blockedConflict
        )
        blocked.errorMessage = "base_revision_mismatch"
        try fixture.context.save()

        XCTAssertEqual(
            try fixture.service.repairBlockedBaselineSheepProfileRevisionDrift(
                farmID: fixture.farm.id,
                context: fixture.context
            ),
            1
        )
        XCTAssertEqual(fixture.sheep.revision, 2)
        XCTAssertEqual(blocked.status, .supersededRemoteAuthority)
        let retry = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<OutboxItem>()).first {
            $0.entityID == fixture.sheep.id && $0.status == .pending
        })
        XCTAssertEqual(retry.baseRevision, 1)
    }

    func testRemoteMembershipProjectionAlignsParentCreatedMembership() throws {
        let fixture = try makeFixture()
        let startedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let leftAt = startedAt.addingTimeInterval(86_400)
        let batch = ProductionBatchRecord(
            farmID: fixture.farm.id,
            name: "云端批次",
            purpose: "选育",
            startedAt: startedAt
        )
        let membershipID = StableCloudUUID.derived(
            namespace: batch.id,
            name: "batch-member-\(fixture.sheep.id.uuidString.lowercased())"
        )
        let membership = BatchMembershipRecord(
            id: membershipID,
            farmID: fixture.farm.id,
            batchID: batch.id,
            sheepID: fixture.sheep.id,
            joinedAt: startedAt
        )
        fixture.context.insert(batch)
        fixture.context.insert(membership)
        try fixture.context.save()

        let encoded = try FarmCommandCloudPayloadEncoder.encode(
            .assignSheepToBatch(
                batchID: batch.id,
                sheepID: fixture.sheep.id,
                joinedAt: startedAt
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var payload = try decoder.decode(
            FarmCommandCloudPayload.self,
            from: encoded
        )
        payload.optionalDates["leftAt"] = leftAt
        payload.optionalStrings["leaveReason"] = "阶段结束"
        let payloadData = try JSONEncoder.cloud.encode(payload)
        let envelope = CloudOperationEnvelope(
            farmID: fixture.farm.id,
            entityID: membershipID,
            entityType: CloudEntityType.batchMembership.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: leftAt,
            modifiedByAccountID: fixture.account.id,
            modifiedByDeviceID: UUID(),
            payload: payloadData,
            payloadDigest: CloudPayloadDigest.hex(for: payloadData),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        guard case .applied = try RemoteDomainApplyService().apply(
            envelope,
            context: fixture.context
        ) else {
            return XCTFail("Expected the membership snapshot to apply")
        }
        XCTAssertEqual(
            try XCTUnwrap(membership.leftAt).timeIntervalSince1970,
            leftAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(membership.leaveReason, "阶段结束")
        XCTAssertEqual(batch.status, .completed)
    }

    func testRemoteRecreatedRemovalClearsDeletedProjectionAtNextRevision() throws {
        let fixture = try makeFixture()
        let removalID = UUID()
        let removal = RemovalRecord(
            id: removalID,
            farmID: fixture.farm.id,
            sheepID: fixture.sheep.id,
            kind: .deceased,
            reason: "旧原因",
            occurredAt: .now,
            note: "旧记录"
        )
        removal.revision = 2
        removal.deletedAt = .now
        fixture.context.insert(removal)
        try fixture.context.save()
        let occurredAt = Date(timeIntervalSince1970: 1_788_000_000)
        let payload = try FarmCommandCloudPayloadEncoder.encode(.removeSheep(
            sheepID: fixture.sheep.id,
            kind: .deceased,
            reason: "新原因",
            amountText: nil,
            occurredAt: occurredAt,
            note: "再次记录",
            recordID: removalID
        ))
        let envelope = CloudOperationEnvelope(
            farmID: fixture.farm.id,
            entityID: removalID,
            entityType: CloudEntityType.removal.rawValue,
            schemaVersion: 2,
            revision: 3,
            baseRevision: 2,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: fixture.account.id,
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        let outcome = try RemoteDomainApplyService().apply(
            envelope,
            context: fixture.context
        )
        guard case .applied(let rebuildHistoryFrom) = outcome else {
            return XCTFail("Expected the recreated removal to apply, got \(outcome)")
        }
        XCTAssertEqual(
            try XCTUnwrap(rebuildHistoryFrom).timeIntervalSince1970,
            occurredAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertNil(removal.deletedAt)
        XCTAssertEqual(removal.revision, 3)
        XCTAssertEqual(removal.reason, "新原因")
        XCTAssertEqual(removal.note, "再次记录")
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(
            name: "sync-revision-repair-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(
            appleUserIdentifier: "sync-repair-\(UUID().uuidString)",
            displayName: "场主"
        )
        let farm = FarmRecord(ownerAccountID: account.id, name: "版本修复测试场")
        let sheep = SheepRecord(
            farmID: farm.id,
            earTag: "SYNC-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now.addingTimeInterval(-86_400)
        )
        context.insert(account)
        context.insert(farm)
        context.insert(sheep)
        context.insert(FarmStorageProfile(
            farmID: farm.id,
            mode: .supabase,
            authorityGeneration: 1
        ))
        context.insert(FarmRemoteBinding(
            farmID: farm.id,
            ownerAccountID: account.id,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: farm.id.uuidString.lowercased()
        ))
        try context.save()
        return Fixture(
            container: container,
            context: context,
            service: FarmCommandService(),
            account: account,
            farm: farm,
            sheep: sheep
        )
    }

    @discardableResult
    private func insertOperation(
        fixture: Fixture,
        kind: DomainOperationKind,
        entityType: CloudEntityType,
        entityID: UUID,
        baseRevision: Int,
        resultingRevision: Int,
        payload: Data,
        status: OutboxStatus
    ) -> OutboxItem {
        let operation = DomainOperation(
            farmID: fixture.farm.id,
            accountID: fixture.account.id,
            kind: kind,
            summary: "测试操作",
            entityType: entityType.rawValue,
            entityID: entityID,
            baseRevision: baseRevision,
            resultingRevision: resultingRevision,
            payload: payload
        )
        let outbox = OutboxItem(
            farmID: fixture.farm.id,
            accountID: fixture.account.id,
            operationID: operation.id,
            entityType: entityType.rawValue,
            entityID: entityID,
            baseRevision: baseRevision,
            payloadDigest: operation.payloadDigest,
            deliveryProvider: .supabase,
            authorityGeneration: 1
        )
        outbox.statusRawValue = status.rawValue
        fixture.context.insert(operation)
        fixture.context.insert(outbox)
        return outbox
    }
}

@MainActor
private struct Fixture {
    let container: ModelContainer
    let context: ModelContext
    let service: FarmCommandService
    let account: AccountProfile
    let farm: FarmRecord
    let sheep: SheepRecord

    var farmContext: FarmContext {
        FarmContext(accountID: account.id, farmID: farm.id, role: .owner)
    }
}
