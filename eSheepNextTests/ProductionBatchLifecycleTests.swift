import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class ProductionBatchLifecycleTests: XCTestCase {
    func testOnlyManualBatchesAreVisibleAndSelectableForProductionAnalysis() {
        let farmID = UUID()
        let manual = ProductionBatchRecord(farmID: farmID, name: "人工批次", purpose: "育肥", source: .manual, startedAt: .now)
        let migrated = ProductionBatchRecord(farmID: farmID, name: "旧迁移批次", purpose: "育肥", source: .historicalMigration, startedAt: .now)
        let inferred = ProductionBatchRecord(farmID: farmID, name: "旧推断批次", purpose: "育肥", source: .historicalInference, startedAt: .now)
        let otherFarm = ProductionBatchRecord(farmID: UUID(), name: "其他牧场", purpose: "育肥", source: .manual, startedAt: .now)

        let batches = [manual, migrated, inferred, otherFarm]

        XCTAssertEqual(ProductionBatchVisibility.userManaged(farmID: farmID, batches: batches).map(\.id), [manual.id])
        XCTAssertEqual(ProductionBatchVisibility.validatedSelection(manual.id, farmID: farmID, batches: batches), manual.id)
        XCTAssertNil(ProductionBatchVisibility.validatedSelection(migrated.id, farmID: farmID, batches: batches))
        XCTAssertNil(ProductionBatchVisibility.validatedSelection(inferred.id, farmID: farmID, batches: batches))
    }

    func testCreateBatchAtomicallyCreatesSelectedMembershipsAtChosenStart() throws {
        let fixture = try makeFixture()
        let startedAt = fixture.enteredAt.addingTimeInterval(86_400)
        fixture.context.insert(FarmStorageProfile(
            farmID: fixture.farm.id,
            mode: .supabase,
            authorityGeneration: 1
        ))
        fixture.context.insert(FarmRemoteBinding(
            farmID: fixture.farm.id,
            ownerAccountID: fixture.account.id,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: fixture.farm.id.uuidString.lowercased()
        ))
        try fixture.context.save()

        try fixture.service.execute(
            .createBatch(name: "春季留养", purpose: "选育", startedAt: startedAt, sheepIDs: [fixture.first.id, fixture.second.id], note: "人工选择"),
            in: fixture.farmContext,
            context: fixture.context
        )

        let batch = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).first { $0.farmID == fixture.farm.id })
        let memberships = try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter { $0.batchID == batch.id }
        XCTAssertEqual(batch.sourceRawValue, ProductionBatchSource.manual.rawValue)
        XCTAssertEqual(Set(memberships.map(\.sheepID)), [fixture.first.id, fixture.second.id])
        XCTAssertTrue(memberships.allSatisfy { $0.joinedAt == startedAt && $0.leftAt == nil })
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.entityID == batch.id }.count, 1)
        let membershipIDs = Set(memberships.map(\.id))
        let membershipOperations = try fixture.context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.entityID.map(membershipIDs.contains) == true
        }
        XCTAssertEqual(membershipOperations.count, 2)
        XCTAssertTrue(membershipOperations.allSatisfy {
            $0.kindRawValue == DomainOperationKind.assignBatchMembership.rawValue &&
                $0.baseRevision == 0 &&
                $0.resultingRevision == 1
        })
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<OutboxItem>()).filter {
                $0.entityID == batch.id || $0.entityID.map(membershipIDs.contains) == true
            }.count,
            3
        )
    }

    func testInvalidMemberRollsBackWholeBatchCreation() throws {
        let fixture = try makeFixture()
        let otherFarmSheep = SheepRecord(farmID: UUID(), earTag: "X001", breed: "湖羊", purpose: "育肥", sex: .ram, penID: nil, enteredAt: fixture.enteredAt)
        fixture.context.insert(otherFarmSheep)
        try fixture.context.save()

        XCTAssertThrowsError(try fixture.service.execute(
            .createBatch(name: "无效批次", purpose: "育肥", startedAt: fixture.enteredAt.addingTimeInterval(86_400), sheepIDs: [fixture.first.id, otherFarmSheep.id], note: ""),
            in: fixture.farmContext,
            context: fixture.context
        ))

        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter { $0.farmID == fixture.farm.id }.isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter { $0.farmID == fixture.farm.id }.isEmpty)
    }

    func testBatchArchivesOnlyWhenLastMemberIsManuallyRemoved() throws {
        let fixture = try makeFixture()
        let startedAt = fixture.enteredAt.addingTimeInterval(86_400)
        try fixture.service.execute(
            .createBatch(name: "留养观察", purpose: "选育", startedAt: startedAt, sheepIDs: [fixture.first.id, fixture.second.id], note: ""),
            in: fixture.farmContext,
            context: fixture.context
        )
        let batch = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).first { $0.farmID == fixture.farm.id })
        let firstLeftAt = startedAt.addingTimeInterval(5 * 86_400)
        let lastLeftAt = startedAt.addingTimeInterval(8 * 86_400)

        try fixture.service.execute(.leaveBatch(batchID: batch.id, sheepID: fixture.first.id, leftAt: firstLeftAt, reason: "手工脱离"), in: fixture.farmContext, context: fixture.context)
        XCTAssertEqual(batch.status, .active)
        XCTAssertNil(batch.endedAt)
        XCTAssertTrue(fixture.first.isCurrentlyPresent)

        try fixture.service.execute(.leaveBatch(batchID: batch.id, sheepID: fixture.second.id, leftAt: lastLeftAt, reason: "手工脱离"), in: fixture.farmContext, context: fixture.context)
        XCTAssertEqual(batch.status, .completed)
        XCTAssertEqual(batch.endedAt, lastLeftAt)
        XCTAssertTrue(fixture.first.isCurrentlyPresent)
        XCTAssertTrue(fixture.second.isCurrentlyPresent)
    }

    func testRestoreBatchMembershipReopensOriginalBatchAndKeepsAuditTrail() throws {
        let fixture = try makeFixture()
        let startedAt = fixture.enteredAt.addingTimeInterval(86_400)
        try fixture.service.execute(
            .createBatch(
                name: "误操作恢复批次",
                purpose: "选育",
                startedAt: startedAt,
                sheepIDs: [fixture.first.id],
                note: ""
            ),
            in: fixture.farmContext,
            context: fixture.context
        )
        let batch = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).first {
            $0.farmID == fixture.farm.id
        })
        let membership = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>()).first {
            $0.batchID == batch.id
        })
        let leftAt = startedAt.addingTimeInterval(86_400)
        try fixture.service.execute(
            .leaveBatch(
                batchID: batch.id,
                sheepID: fixture.first.id,
                leftAt: leftAt,
                reason: "误触移出"
            ),
            in: fixture.farmContext,
            context: fixture.context
        )
        XCTAssertEqual(batch.status, .completed)
        XCTAssertEqual(batch.endedAt, leftAt)

        let restoredAt = leftAt.addingTimeInterval(60)
        try fixture.service.execute(
            .restoreBatchMembership(
                membershipID: membership.id,
                restoredAt: restoredAt,
                reason: "用户撤回误操作"
            ),
            in: fixture.farmContext,
            context: fixture.context
        )

        XCTAssertNil(membership.leftAt)
        XCTAssertNil(membership.leaveReason)
        XCTAssertEqual(batch.status, .active)
        XCTAssertNil(batch.endedAt)
        let membershipOperations = try fixture.context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.entityID == membership.id }
            .sorted { $0.resultingRevision < $1.resultingRevision }
        XCTAssertEqual(
            membershipOperations.map(\.kindRawValue),
            [
                DomainOperationKind.assignBatchMembership.rawValue,
                DomainOperationKind.leaveBatchMembership.rawValue,
                DomainOperationKind.restoreBatchMembership.rawValue,
            ]
        )
        XCTAssertEqual(membershipOperations.map(\.baseRevision), [0, 1, 2])
        XCTAssertEqual(membershipOperations.map(\.resultingRevision), [1, 2, 3])
        let restorePayload = try decodePayload(try XCTUnwrap(membershipOperations.last).payload)
        XCTAssertEqual(restorePayload.kind, .restoreBatchMembership)
        XCTAssertEqual(restorePayload.identifiers["membershipID"], membership.id)
        XCTAssertEqual(restorePayload.strings["reason"], "用户撤回误操作")
    }

    func testRemoteRestoreBatchMembershipReopensArchivedBatch() throws {
        let fixture = try makeFixture()
        let startedAt = fixture.enteredAt.addingTimeInterval(86_400)
        try fixture.service.execute(
            .createBatch(
                name: "远端恢复批次",
                purpose: "育肥",
                startedAt: startedAt,
                sheepIDs: [fixture.first.id],
                note: ""
            ),
            in: fixture.farmContext,
            context: fixture.context
        )
        let batch = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).first {
            $0.farmID == fixture.farm.id
        })
        let membership = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>()).first {
            $0.batchID == batch.id
        })
        let leftAt = startedAt.addingTimeInterval(86_400)
        try fixture.service.execute(
            .leaveBatch(batchID: batch.id, sheepID: fixture.first.id, leftAt: leftAt, reason: "误触移出"),
            in: fixture.farmContext,
            context: fixture.context
        )
        let restoredAt = leftAt.addingTimeInterval(120)
        let payloadData = try FarmCommandCloudPayloadEncoder.encode(
            .restoreBatchMembership(
                membershipID: membership.id,
                restoredAt: restoredAt,
                reason: "另一台设备撤回"
            )
        )
        let envelope = CloudOperationEnvelope(
            farmID: fixture.farm.id,
            entityID: membership.id,
            entityType: CloudEntityType.batchMembership.rawValue,
            schemaVersion: 2,
            revision: 3,
            baseRevision: 2,
            operationID: UUID(),
            modifiedAt: restoredAt,
            modifiedByAccountID: fixture.account.id,
            modifiedByDeviceID: UUID(),
            payload: payloadData,
            payloadDigest: CloudPayloadDigest.hex(for: payloadData),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        XCTAssertEqual(
            try RemoteDomainApplyService().apply(envelope, context: fixture.context),
            .applied(rebuildHistoryFrom: leftAt)
        )
        XCTAssertNil(membership.leftAt)
        XCTAssertNil(membership.leaveReason)
        XCTAssertEqual(batch.status, .active)
        XCTAssertNil(batch.endedAt)
    }

    func testLeavingFarmDoesNotDetachSheepFromProductionBatch() throws {
        let fixture = try makeFixture()
        let startedAt = fixture.enteredAt.addingTimeInterval(86_400)
        try fixture.service.execute(
            .createBatch(name: "持续批次", purpose: "选育", startedAt: startedAt, sheepIDs: [fixture.first.id], note: ""),
            in: fixture.farmContext,
            context: fixture.context
        )
        let batch = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).first { $0.farmID == fixture.farm.id })
        try fixture.service.execute(
            .removeSheep(sheepID: fixture.first.id, kind: .sold, reason: "出售", amountText: nil, occurredAt: startedAt.addingTimeInterval(10 * 86_400), note: ""),
            in: fixture.farmContext,
            context: fixture.context
        )

        let membership = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>()).first { $0.batchID == batch.id })
        XCTAssertNil(membership.leftAt)
        XCTAssertEqual(batch.status, .active)
        XCTAssertNil(batch.endedAt)
    }

    func testRemoteBootstrapRestoresHistoricalMembershipDepartureAndArchivesBatch() throws {
        let fixture = try makeFixture()
        let batch = ProductionBatchRecord(farmID: fixture.farm.id, name: "迁移批次", purpose: "选育", startedAt: fixture.enteredAt)
        fixture.context.insert(batch)
        try fixture.context.save()
        let membershipID = UUID()
        let leftAt = fixture.enteredAt.addingTimeInterval(12 * 86_400)
        var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(
            .assignSheepToBatch(batchID: batch.id, sheepID: fixture.first.id, joinedAt: fixture.enteredAt)
        ))
        payload.optionalDates["leftAt"] = leftAt
        payload.optionalStrings["leaveReason"] = "留养结束"
        let payloadData = try JSONEncoder.cloud.encode(payload)
        let envelope = CloudOperationEnvelope(
            farmID: fixture.farm.id,
            entityID: membershipID,
            entityType: CloudEntityType.batchMembership.rawValue,
            schemaVersion: 2,
            revision: 2,
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

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: fixture.context), .applied(rebuildHistoryFrom: fixture.enteredAt))
        let membership = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>()).first { $0.id == membershipID })
        XCTAssertEqual(membership.leftAt, leftAt)
        XCTAssertEqual(membership.leaveReason, "留养结束")
        XCTAssertEqual(batch.status, .completed)
        XCTAssertEqual(batch.endedAt, leftAt)
    }

    func testDeleteBatchRemovesMembershipsPreservesSheepAndAllowsNewBatch() throws {
        let fixture = try makeFixture()
        try fixture.service.execute(
            .createBatch(name: "待删除批次", purpose: "育肥", startedAt: fixture.enteredAt, sheepIDs: [fixture.first.id, fixture.second.id], note: ""),
            in: fixture.farmContext, context: fixture.context
        )
        try fixture.service.execute(
            .recordWeight(sheepID: fixture.first.id, kilogramsText: "40", occurredAt: fixture.enteredAt, note: "保留"),
            in: fixture.farmContext, context: fixture.context
        )
        let batch = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).first)
        let members = try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>())
        try fixture.service.execute(
            .leaveBatch(batchID: batch.id, sheepID: fixture.second.id, leftAt: fixture.enteredAt.addingTimeInterval(60), reason: "已移出"),
            in: fixture.farmContext, context: fixture.context
        )
        try fixture.service.deleteProductionBatch(batchID: batch.id, reason: "误建批次", in: fixture.farmContext, context: fixture.context)

        XCTAssertNotNil(batch.deletedAt)
        XCTAssertTrue(members.allSatisfy { $0.deletedAt != nil })
        XCTAssertEqual(members.first { $0.sheepID == fixture.second.id }?.leftAt, fixture.enteredAt.addingTimeInterval(60))
        XCTAssertNil(fixture.first.deletedAt)
        XCTAssertNil(fixture.second.deletedAt)
        XCTAssertTrue(fixture.first.isCurrentlyPresent)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<WeightRecord>()).allSatisfy { $0.deletedAt == nil })
        XCTAssertNil(ProductionBatchVisibility.validatedSelection(batch.id, farmID: fixture.farm.id, batches: [batch]))
        let tombstones = try fixture.context.fetch(FetchDescriptor<TombstoneRecord>())
        XCTAssertEqual(Set(tombstones.map(\.entityID)), Set(members.map(\.id) + [batch.id]))
        XCTAssertTrue(tombstones.allSatisfy { $0.reason == "误建批次" && $0.operationID != nil })
        let operations = try fixture.context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue }
        XCTAssertEqual(operations.count, 3)
        for operation in operations {
            let payload = try decodePayload(operation.payload)
            XCTAssertEqual(payload.kind, .tombstoneEntity)
        }
        try fixture.service.execute(
            .createBatch(name: "新批次", purpose: "育肥", startedAt: fixture.enteredAt.addingTimeInterval(120), sheepIDs: [fixture.first.id, fixture.second.id], note: ""),
            in: fixture.farmContext, context: fixture.context
        )
    }

    func testDeleteBatchAllowsAdministratorAndRejectsWorkerAndOtherFarm() throws {
        let fixture = try makeFixture()
        try fixture.service.execute(
            .createBatch(name: "受保护批次", purpose: "育肥", startedAt: fixture.enteredAt, sheepIDs: [fixture.first.id], note: ""),
            in: fixture.farmContext, context: fixture.context
        )
        let batch = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).first)
        for farmContext in [
            FarmContext(accountID: fixture.account.id, farmID: fixture.farm.id, role: .worker),
            FarmContext(accountID: fixture.account.id, farmID: UUID(), role: .owner),
        ] {
            XCTAssertThrowsError(try fixture.service.deleteProductionBatch(batchID: batch.id, reason: "无权限", in: farmContext, context: fixture.context))
        }
        XCTAssertNil(batch.deletedAt)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>()).allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TombstoneRecord>()).isEmpty)

        let administrator = FarmContext(accountID: fixture.account.id, farmID: fixture.farm.id, role: .administrator)
        try fixture.service.deleteProductionBatch(batchID: batch.id, reason: "管理员删除批次", in: administrator, context: fixture.context)
        XCTAssertNotNil(batch.deletedAt)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<TombstoneRecord>()).map(\.entityType).sorted(), [
            CloudEntityType.batchMembership.rawValue,
            CloudEntityType.productionBatch.rawValue,
        ].sorted())
    }

    func testDeleteBatchStagesCloudV2IntentForEveryDeletedEntity() throws {
        let fixture = try makeFixture()
        try fixture.service.execute(
            .createBatch(name: "云端批次", purpose: "育肥", startedAt: fixture.enteredAt, sheepIDs: [fixture.first.id], note: ""),
            in: fixture.farmContext, context: fixture.context
        )
        let batch = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ProductionBatchRecord>()).first)
        let member = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<BatchMembershipRecord>()).first)
        let deviceID = try ESheepCloudDeviceIdentityStore.deviceID(accountID: fixture.account.id)
        let farmID = fixture.farm.id
        try ESheepCloudSequenceWatermark.reconcile(farmID: farmID, deviceID: deviceID, floor: 0)
        addTeardownBlock {
            try SecureAccountStore.remove(account: "esheep-v2-sequence-\(farmID.uuidString.lowercased())-\(deviceID.uuidString.lowercased())")
        }
        fixture.context.insert(FarmStorageProfile(farmID: farmID, mode: .eSheepCloud, authorityGeneration: 1))
        fixture.context.insert(FarmRemoteBinding(farmID: farmID, ownerAccountID: fixture.account.id, provider: .eSheepCloud, state: .active, authorityGeneration: 1, remoteFarmID: farmID.uuidString.lowercased()))
        fixture.context.insert(ESheepCloudFarmState(farmID: farmID, farmGeneration: 1, activityState: .active))
        try fixture.context.save()
        try fixture.service.deleteProductionBatch(batchID: batch.id, reason: "删除云端批次", in: fixture.farmContext, context: fixture.context)
        let intents = try fixture.context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
        XCTAssertEqual(intents.count, 2)
        XCTAssertTrue(intents.allSatisfy { $0.commandKind == "record.revoke" })
        XCTAssertEqual(Set(intents.map(\.deviceSequence)).count, 2)
        let envelopes = try intents.map {
            try ESheepCloudCanonicalCodec.decode(
                ESheepCloudCommandEnvelopeV2.self,
                from: $0.commandEnvelopeData
            )
        }
        var revokedIDs: [String: UUID] = [:]
        for envelope in envelopes {
            guard case .deletion(.tombstone(let entityType, let entityID, _)) = envelope.payload else {
                return XCTFail("批次删除意图必须编码为带实体身份的撤销命令")
            }
            revokedIDs[entityType.rawValue] = entityID
        }
        XCTAssertEqual(revokedIDs[CloudEntityType.batchMembership.rawValue], member.id)
        XCTAssertEqual(revokedIDs[CloudEntityType.productionBatch.rawValue], batch.id)
        XCTAssertNotNil(batch.deletedAt)
        XCTAssertNotNil(member.deletedAt)
        XCTAssertNil(fixture.first.deletedAt)
    }

    func testDeleteCompletedAndEmptyBatches() throws {
        let fixture = try makeFixture()
        let batch = ProductionBatchRecord(farmID: fixture.farm.id, name: "空批次", purpose: "育肥", startedAt: fixture.enteredAt)
        batch.statusRawValue = ProductionBatchStatus.completed.rawValue
        fixture.context.insert(batch)
        try fixture.context.save()
        try fixture.service.deleteProductionBatch(batchID: batch.id, reason: "清理空批次", in: fixture.farmContext, context: fixture.context)
        XCTAssertNotNil(batch.deletedAt)
        XCTAssertThrowsError(try fixture.service.deleteProductionBatch(batchID: batch.id, reason: "重复删除", in: fixture.farmContext, context: fixture.context))
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(name: "batch-lifecycle-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "batch-owner-\(UUID().uuidString)", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "批次测试场")
        let enteredAt = Date(timeIntervalSince1970: 1_750_000_000)
        let first = SheepRecord(farmID: farm.id, earTag: "B001", breed: "湖羊", purpose: "留养", sex: .ewe, penID: nil, enteredAt: enteredAt)
        let second = SheepRecord(farmID: farm.id, earTag: "B002", breed: "湖羊", purpose: "留养", sex: .ewe, penID: nil, enteredAt: enteredAt)
        context.insert(account)
        context.insert(farm)
        context.insert(first)
        context.insert(second)
        try context.save()
        return Fixture(
            context: context,
            service: FarmCommandService(),
            account: account,
            farm: farm,
            first: first,
            second: second,
            enteredAt: enteredAt
        )
    }

    private func decodePayload(_ data: Data) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }
}

@MainActor
private struct Fixture {
    let context: ModelContext
    let service: FarmCommandService
    let account: AccountProfile
    let farm: FarmRecord
    let first: SheepRecord
    let second: SheepRecord
    let enteredAt: Date

    var farmContext: FarmContext {
        FarmContext(accountID: account.id, farmID: farm.id, role: .owner)
    }
}
