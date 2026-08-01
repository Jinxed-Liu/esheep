import CloudKit
import SwiftData
import XCTest

@testable import eSheepNext

@MainActor
final class CloudTombstoneReconciliationTests: XCTestCase {
  func testTombstoneDeliveryRequiresOnlyOperationAndTombstone() throws {
    let fixture = try makeFixture()
    let names = CloudDeliveryReceiptContract.requiredRecordNames(
      for: fixture.operation,
      latestOperationForEntity: fixture.operation
    )

    XCTAssertEqual(
      names,
      [
        fixture.mapper.recordName(for: fixture.operation.id),
        fixture.mapper.tombstoneRecordName(for: fixture.entityID),
      ])
    XCTAssertFalse(names.contains(fixture.mapper.entityRecordName(for: fixture.entityID)))
    XCTAssertTrue(OutboxStatus.supersededRemoteAuthority.isTerminalDelivery)
  }

  func testOperationAndTombstoneReceiptsConfirmOutboxIdempotently() async throws {
    let fixture = try makeFixture()
    let container = try AppSchema.makeContainer(
      name: "tombstone-receipts-\(UUID().uuidString)",
      isStoredInMemoryOnly: true
    )
    let context = ModelContext(container)
    context.insert(fixture.binding)
    context.insert(fixture.operation)
    context.insert(fixture.outbox)
    context.insert(fixture.tombstone)
    try context.save()

    let persistence = FarmPersistenceActor(container: container)
    try await persistence.confirmSavedRecords(
      [fixture.operationRecord, fixture.tombstoneRecord],
      scope: .privateDatabase
    )
    try await persistence.confirmSavedRecords(
      [fixture.operationRecord, fixture.tombstoneRecord],
      scope: .privateDatabase
    )

    let verification = ModelContext(container)
    let outbox = try XCTUnwrap(verification.fetch(FetchDescriptor<OutboxItem>()).first)
    let receipts = try verification.fetch(FetchDescriptor<CloudOperationReceipt>())
    XCTAssertEqual(outbox.status, .confirmed)
    XCTAssertEqual(receipts.count, 2)
    XCTAssertFalse(
      receipts.contains {
        $0.recordName == fixture.mapper.entityRecordName(for: fixture.entityID)
      })
  }

  func testConfirmedTombstoneSchedulesOnlyMissingOperation() async throws {
    let fixture = try makeFixture()
    let container = try AppSchema.makeContainer(
      name: "tombstone-operation-retry-\(UUID().uuidString)",
      isStoredInMemoryOnly: true
    )
    let context = ModelContext(container)
    context.insert(fixture.binding)
    context.insert(fixture.operation)
    context.insert(fixture.outbox)
    context.insert(fixture.tombstone)
    try context.save()
    let persistence = FarmPersistenceActor(container: container)

    try await persistence.confirmSavedRecords(
      [fixture.tombstoneRecord],
      scope: .privateDatabase
    )
    let pending = try await persistence.pendingRecordIDs(
      maxOutboxItems: 1,
      farmID: fixture.farmID
    )

    XCTAssertEqual(
      pending.map { $0.0.recordName },
      [
        fixture.mapper.recordName(for: fixture.operation.id)
      ])
    XCTAssertEqual(
      try ModelContext(container).fetch(FetchDescriptor<OutboxItem>()).first?.status,
      .awaitingConfirmation
    )
  }

  func testEvidenceEvaluatorConfirmsEquivalentDeletion() throws {
    let fixture = try makeFixture()
    let decision = CloudTombstoneEvidenceEvaluator.evaluate(
      candidate: fixture.candidate,
      evidence: CloudTombstoneRemoteEvidence(
        localOperationRecord: fixture.operationRecord,
        tombstoneRecord: fixture.tombstoneRecord,
        authoritativeOperationRecord: nil,
        entityProjectionRecord: fixture.entityRecord
      )
    )
    guard case .equivalent = decision else {
      return XCTFail("相同 Operation 与 Tombstone 应幂等确认")
    }
  }

  func testEvidenceEvaluatorAllowsSubsecondCloudKitDateRoundTrip() throws {
    let fixture = try makeFixture()
    let local = fixture.candidate.localOperation
    let envelope = CloudOperationEnvelope(
      farmID: local.farmID,
      entityID: local.entityID,
      entityType: local.entityType,
      schemaVersion: local.schemaVersion,
      revision: local.revision,
      baseRevision: local.baseRevision,
      operationID: local.operationID,
      modifiedAt: local.modifiedAt.addingTimeInterval(0.5),
      modifiedByAccountID: local.modifiedByAccountID,
      modifiedByDeviceID: local.modifiedByDeviceID,
      payload: local.payload,
      payloadDigest: local.payloadDigest,
      capabilityCertificate: local.capabilityCertificate,
      operationSignature: local.operationSignature,
      deletedAt: local.deletedAt?.addingTimeInterval(0.5)
    )
    let operationRecord = fixture.mapper.operationRecord(
      from: envelope,
      zoneID: fixture.zoneID
    )
    let tombstoneRecord = fixture.mapper.tombstoneRecord(
      envelope: fixture.localTombstoneEnvelope,
      certificate: envelope.capabilityCertificate,
      signature: envelope.operationSignature,
      zoneID: fixture.zoneID
    )

    let decision = CloudTombstoneEvidenceEvaluator.evaluate(
      candidate: fixture.candidate,
      evidence: CloudTombstoneRemoteEvidence(
        localOperationRecord: operationRecord,
        tombstoneRecord: tombstoneRecord,
        authoritativeOperationRecord: nil,
        entityProjectionRecord: fixture.entityRecord
      )
    )
    guard case .equivalent = decision else {
      return XCTFail("CloudKit 亚秒时间精度变化不应破坏不可变操作等价性")
    }
  }

  func testEvidenceEvaluatorUsesVerifiedRemoteAuthorizationForSameOperationFact() throws {
    let fixture = try makeFixture()
    let local = fixture.candidate.localOperation
    let remote = CloudOperationEnvelope(
      farmID: local.farmID,
      entityID: local.entityID,
      entityType: local.entityType,
      schemaVersion: local.schemaVersion,
      revision: local.revision,
      baseRevision: local.baseRevision,
      operationID: local.operationID,
      modifiedAt: local.modifiedAt,
      modifiedByAccountID: local.modifiedByAccountID,
      modifiedByDeviceID: UUID(),
      payload: local.payload,
      payloadDigest: local.payloadDigest,
      capabilityCertificate: "remote-certificate",
      operationSignature: Data([7, 8, 9]),
      deletedAt: local.deletedAt
    )
    let operationRecord = fixture.mapper.operationRecord(from: remote, zoneID: fixture.zoneID)
    let tombstoneRecord = fixture.mapper.tombstoneRecord(
      envelope: fixture.localTombstoneEnvelope,
      certificate: remote.capabilityCertificate,
      signature: remote.operationSignature,
      zoneID: fixture.zoneID
    )

    let decision = CloudTombstoneEvidenceEvaluator.evaluate(
      candidate: fixture.candidate,
      evidence: CloudTombstoneRemoteEvidence(
        localOperationRecord: operationRecord,
        tombstoneRecord: tombstoneRecord,
        authoritativeOperationRecord: nil,
        entityProjectionRecord: nil
      )
    )
    guard case .equivalent = decision else {
      return XCTFail("同一业务事实应采用已验证的云端签名授权")
    }
  }

  func testCredentialRepairPlanOnlyRepairsTombstoneAuthorizationIndexes() throws {
    let fixture = try makeFixture()
    let mismatchedTombstone = fixture.mapper.tombstoneRecord(
      envelope: fixture.localTombstoneEnvelope,
      certificate: fixture.candidate.localOperation.capabilityCertificate,
      signature: Data([9, 9, 9]),
      zoneID: fixture.zoneID
    )
    let evidence = CloudTombstoneRemoteEvidence(
      localOperationRecord: fixture.operationRecord,
      tombstoneRecord: mismatchedTombstone,
      authoritativeOperationRecord: nil,
      entityProjectionRecord: nil
    )

    let plan = CloudTombstoneEvidenceEvaluator.credentialRepairPlan(
      candidate: fixture.candidate,
      evidence: evidence
    )
    XCTAssertNotNil(plan)
    XCTAssertEqual(plan?.envelope.operationID, fixture.operation.id)
    XCTAssertEqual(
      plan?.operationRecord[CloudRecordField.operationSignature] as? Data,
      fixture.operation.operationSignature
    )
  }

  func testProjectionCandidatesRequireDuplicateEntityAndRevisionWithoutOutbox() async throws {
    let fixture = try makeFixture()
    let container = try AppSchema.makeContainer(
      name: "tombstone-projection-candidates-\(UUID().uuidString)",
      isStoredInMemoryOnly: true
    )
    let context = ModelContext(container)
    context.insert(fixture.binding)
    context.insert(fixture.operation)
    context.insert(fixture.tombstone)

    let secondID = UUID()
    let second = DomainOperation(
      id: secondID,
      farmID: fixture.farmID,
      accountID: fixture.accountID,
      kind: .tombstoneEntity,
      occurredAt: fixture.operation.occurredAt.addingTimeInterval(10),
      summary: "重复删除事实",
      entityType: fixture.operation.entityType,
      entityID: fixture.entityID,
      baseRevision: fixture.operation.baseRevision,
      resultingRevision: fixture.operation.resultingRevision,
      payload: fixture.operation.payload
    )
    second.modifiedByDeviceID = fixture.deviceID
    second.capabilityCertificate = "certificate"
    second.operationSignature = Data([4, 5, 6])
    let duplicate = TombstoneRecord(
      farmID: fixture.farmID,
      entityType: fixture.operation.entityType,
      entityID: fixture.entityID,
      deletedByAccountID: fixture.accountID,
      reason: "重复删除事实",
      revision: fixture.operation.resultingRevision,
      operationID: secondID
    )
    duplicate.deletedAt = second.occurredAt
    context.insert(second)
    context.insert(duplicate)
    try context.save()

    let candidates = try await FarmPersistenceActor(container: container)
      .tombstoneAuthorityProjectionCandidates(farmID: fixture.farmID)
    XCTAssertEqual(candidates.count, 2)
    XCTAssertTrue(candidates.allSatisfy { $0.outboxID == nil })
    XCTAssertEqual(Set(candidates.map(\.localOperation.operationID)), Set([fixture.operation.id, secondID]))

    duplicate.operationID = fixture.operation.id
    try context.save()
    let reconciledCandidates = try await FarmPersistenceActor(container: container)
      .tombstoneAuthorityProjectionCandidates(farmID: fixture.farmID)
    XCTAssertTrue(reconciledCandidates.isEmpty)
  }

  func testEvidenceEvaluatorRetriesOnlyMissingOperation() throws {
    let fixture = try makeFixture()
    let decision = CloudTombstoneEvidenceEvaluator.evaluate(
      candidate: fixture.candidate,
      evidence: CloudTombstoneRemoteEvidence(
        localOperationRecord: nil,
        tombstoneRecord: fixture.tombstoneRecord,
        authoritativeOperationRecord: nil,
        entityProjectionRecord: fixture.entityRecord
      )
    )
    guard case .retryOperation = decision else {
      return XCTFail("已有等价 Tombstone 时只能重传缺失 Operation")
    }
  }

  func testEvidenceEvaluatorAdoptsDifferentVerifiedDeletionChainStructurally() throws {
    let fixture = try makeFixture()
    let remoteOperationID = UUID()
    let remoteEnvelope = CloudOperationEnvelope(
      farmID: fixture.farmID,
      entityID: fixture.entityID,
      entityType: fixture.operation.entityType,
      schemaVersion: fixture.operation.schemaVersion,
      revision: fixture.operation.resultingRevision,
      baseRevision: fixture.operation.baseRevision,
      operationID: remoteOperationID,
      modifiedAt: fixture.operation.occurredAt,
      modifiedByAccountID: fixture.accountID,
      modifiedByDeviceID: fixture.deviceID,
      payload: fixture.operation.payload,
      payloadDigest: fixture.operation.payloadDigest,
      capabilityCertificate: "certificate",
      operationSignature: Data([1, 2, 3]),
      deletedAt: fixture.tombstone.deletedAt
    )
    let remoteOperation = fixture.mapper.operationRecord(
      from: remoteEnvelope,
      zoneID: fixture.zoneID
    )
    let remoteTombstoneEnvelope = FarmTombstoneEnvelope(
      tombstoneID: UUID(),
      farmID: fixture.farmID,
      entityType: fixture.operation.entityType,
      entityID: fixture.entityID,
      revision: fixture.operation.resultingRevision,
      deletedAt: fixture.tombstone.deletedAt,
      deletedByAccountID: fixture.accountID,
      reason: "云端删除",
      operationID: remoteOperationID,
      restoresTombstoneID: nil
    )
    let remoteTombstone = fixture.mapper.tombstoneRecord(
      envelope: remoteTombstoneEnvelope,
      certificate: remoteEnvelope.capabilityCertificate,
      signature: remoteEnvelope.operationSignature,
      zoneID: fixture.zoneID
    )

    let decision = CloudTombstoneEvidenceEvaluator.evaluate(
      candidate: fixture.candidate,
      evidence: CloudTombstoneRemoteEvidence(
        localOperationRecord: nil,
        tombstoneRecord: remoteTombstone,
        authoritativeOperationRecord: remoteOperation,
        entityProjectionRecord: fixture.entityRecord
      )
    )
    guard case .superseded(_, _, let envelope) = decision else {
      return XCTFail("另一条完整同 revision 删除链应进入远端权威核验")
    }
    XCTAssertEqual(envelope.operationID, remoteOperationID)
  }

  func testEvidenceEvaluatorRejectsWrongZoneRevisionAndCredentialMismatch() throws {
    let fixture = try makeFixture()
    let wrongZone = CKRecordZone.ID(zoneName: "farm_\(UUID().uuidString.lowercased())")
    let wrongZoneRecord = fixture.mapper.tombstoneRecord(
      envelope: fixture.localTombstoneEnvelope,
      certificate: "certificate",
      signature: Data([1, 2, 3]),
      zoneID: wrongZone
    )
    guard
      case .unresolved = CloudTombstoneEvidenceEvaluator.evaluate(
        candidate: fixture.candidate,
        evidence: CloudTombstoneRemoteEvidence(
          localOperationRecord: fixture.operationRecord,
          tombstoneRecord: wrongZoneRecord,
          authoritativeOperationRecord: nil,
          entityProjectionRecord: nil
        )
      )
    else {
      return XCTFail("错误 Zone 必须拒绝")
    }

    let wrongRevisionEnvelope = FarmTombstoneEnvelope(
      tombstoneID: fixture.tombstone.id,
      farmID: fixture.farmID,
      entityType: fixture.operation.entityType,
      entityID: fixture.entityID,
      revision: fixture.operation.resultingRevision + 1,
      deletedAt: fixture.tombstone.deletedAt,
      deletedByAccountID: fixture.accountID,
      reason: fixture.tombstone.reason,
      operationID: fixture.operation.id,
      restoresTombstoneID: nil
    )
    let wrongRevision = fixture.mapper.tombstoneRecord(
      envelope: wrongRevisionEnvelope,
      certificate: "certificate",
      signature: Data([1, 2, 3]),
      zoneID: fixture.zoneID
    )
    guard
      case .unresolved = CloudTombstoneEvidenceEvaluator.evaluate(
        candidate: fixture.candidate,
        evidence: CloudTombstoneRemoteEvidence(
          localOperationRecord: fixture.operationRecord,
          tombstoneRecord: wrongRevision,
          authoritativeOperationRecord: nil,
          entityProjectionRecord: nil
        )
      )
    else {
      return XCTFail("错误 revision 必须拒绝")
    }

    let wrongCredential = fixture.mapper.tombstoneRecord(
      envelope: fixture.localTombstoneEnvelope,
      certificate: "different-certificate",
      signature: Data([9]),
      zoneID: fixture.zoneID
    )
    guard
      case .unresolved = CloudTombstoneEvidenceEvaluator.evaluate(
        candidate: fixture.candidate,
        evidence: CloudTombstoneRemoteEvidence(
          localOperationRecord: fixture.operationRecord,
          tombstoneRecord: wrongCredential,
          authoritativeOperationRecord: nil,
          entityProjectionRecord: nil
        )
      )
    else {
      return XCTFail("证书或签名索引不匹配必须拒绝")
    }
  }

  private func makeFixture() throws -> Fixture {
    let mapper = CloudRecordMapper()
    let farmID = UUID()
    let accountID = UUID()
    let deviceID = UUID()
    let entityID = UUID()
    let operationID = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: CloudZoneName.forFarm(farmID),
      ownerName: CKCurrentUserDefaultName
    )
    let payload = try FarmCommandCloudPayloadEncoder.encode(
      .tombstoneEntity(entityType: .removal, entityID: entityID, reason: "测试删除")
    )
    let operation = DomainOperation(
      id: operationID,
      farmID: farmID,
      accountID: accountID,
      kind: .tombstoneEntity,
      occurredAt: Date(timeIntervalSince1970: 1_750_000_000),
      summary: "删除记录",
      entityType: CloudEntityType.removal.rawValue,
      entityID: entityID,
      baseRevision: 1,
      resultingRevision: 2,
      payload: payload
    )
    operation.modifiedByDeviceID = deviceID
    operation.capabilityCertificate = "certificate"
    operation.operationSignature = Data([1, 2, 3])
    let tombstone = TombstoneRecord(
      farmID: farmID,
      entityType: operation.entityType,
      entityID: entityID,
      deletedByAccountID: accountID,
      reason: "测试删除",
      revision: 2,
      operationID: operationID
    )
    tombstone.deletedAt = operation.occurredAt
    let outbox = OutboxItem(
      farmID: farmID,
      accountID: accountID,
      operationID: operationID,
      entityType: operation.entityType,
      entityID: entityID,
      baseRevision: 1,
      payloadDigest: operation.payloadDigest
    )
    outbox.statusRawValue = OutboxStatus.blockedConflict.rawValue
    let envelope = CloudOperationEnvelope(
      farmID: farmID,
      entityID: entityID,
      entityType: operation.entityType,
      schemaVersion: operation.schemaVersion,
      revision: operation.resultingRevision,
      baseRevision: operation.baseRevision,
      operationID: operationID,
      modifiedAt: operation.occurredAt,
      modifiedByAccountID: accountID,
      modifiedByDeviceID: deviceID,
      payload: operation.payload,
      payloadDigest: operation.payloadDigest,
      capabilityCertificate: operation.capabilityCertificate,
      operationSignature: operation.operationSignature!,
      deletedAt: tombstone.deletedAt
    )
    let tombstoneEnvelope = FarmTombstoneEnvelope(
      tombstoneID: tombstone.id,
      farmID: farmID,
      entityType: operation.entityType,
      entityID: entityID,
      revision: tombstone.revision,
      deletedAt: tombstone.deletedAt,
      deletedByAccountID: accountID,
      reason: tombstone.reason,
      operationID: operationID,
      restoresTombstoneID: nil
    )
    let binding = CloudFarmBinding(
      farmID: farmID,
      ownerAccountID: accountID,
      databaseScope: .privateDatabase,
      state: .active
    )
    binding.zoneName = zoneID.zoneName
    binding.zoneOwnerName = zoneID.ownerName
    return Fixture(
      mapper: mapper,
      farmID: farmID,
      accountID: accountID,
      deviceID: deviceID,
      entityID: entityID,
      zoneID: zoneID,
      binding: binding,
      operation: operation,
      tombstone: tombstone,
      outbox: outbox,
      localTombstoneEnvelope: tombstoneEnvelope,
      candidate: CloudTombstoneConflictCandidate(
        outboxID: outbox.id,
        farmID: farmID,
        scope: .privateDatabase,
        zoneName: zoneID.zoneName,
        zoneOwnerName: zoneID.ownerName,
        localOperation: envelope,
        localTombstone: tombstoneEnvelope
      ),
      operationRecord: mapper.operationRecord(from: envelope, zoneID: zoneID),
      tombstoneRecord: mapper.tombstoneRecord(
        envelope: tombstoneEnvelope,
        certificate: envelope.capabilityCertificate,
        signature: envelope.operationSignature,
        zoneID: zoneID
      ),
      entityRecord: mapper.entityRecord(from: envelope, zoneID: zoneID)
    )
  }
}

private struct Fixture {
  let mapper: CloudRecordMapper
  let farmID: UUID
  let accountID: UUID
  let deviceID: UUID
  let entityID: UUID
  let zoneID: CKRecordZone.ID
  let binding: CloudFarmBinding
  let operation: DomainOperation
  let tombstone: TombstoneRecord
  let outbox: OutboxItem
  let localTombstoneEnvelope: FarmTombstoneEnvelope
  let candidate: CloudTombstoneConflictCandidate
  let operationRecord: CKRecord
  let tombstoneRecord: CKRecord
  let entityRecord: CKRecord
}
