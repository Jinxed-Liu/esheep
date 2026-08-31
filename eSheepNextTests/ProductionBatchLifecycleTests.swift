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
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<OutboxItem>()).filter { $0.entityID == batch.id }.count, 1)
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
                DomainOperationKind.leaveBatchMembership.rawValue,
                DomainOperationKind.restoreBatchMembership.rawValue,
            ]
        )
        XCTAssertEqual(membershipOperations.map(\.baseRevision), [1, 2])
        XCTAssertEqual(membershipOperations.map(\.resultingRevision), [2, 3])
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
