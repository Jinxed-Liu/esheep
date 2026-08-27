import CloudKit
import Foundation

enum CloudTombstoneReconciliationOutcome: String, Codable, Sendable, Equatable {
  case equivalentConfirmed
  case operationRetryNeeded
  case supersededByRemote
  case unresolvedDivergence

  var displayName: String {
    switch self {
    case .equivalentConfirmed: "已核对并确认"
    case .operationRetryNeeded: "仅重传操作记录"
    case .supersededByRemote: "已采用云端权威"
    case .unresolvedDivergence: "仍需人工检查"
    }
  }
}

struct CloudTombstoneReconciliationItem: Codable, Sendable, Equatable, Identifiable {
  let operationID: UUID
  let entityID: UUID
  let outcome: CloudTombstoneReconciliationOutcome
  let detail: String

  var id: UUID { operationID }
}

struct CloudTombstoneReconciliationReport: Codable, Sendable, Equatable {
  let farmID: UUID
  let startedAt: Date
  let completedAt: Date
  let items: [CloudTombstoneReconciliationItem]

  var resolvedCount: Int {
    items.count { $0.outcome != .unresolvedDivergence }
  }
}

struct CloudTombstoneSupersessionReceipt: Codable, Sendable, Equatable {
  let localOperationID: UUID
  let authoritativeOperation: CloudOperationEnvelope
  let operationRecordName: String
  let tombstoneRecordName: String
  let zoneName: String
  let zoneOwnerName: String
  let databaseScope: CloudDatabaseScope
  let reconciledAt: Date
}

struct CloudTombstoneConflictCandidate: Sendable, Equatable {
  let outboxID: UUID?
  let farmID: UUID
  let scope: CloudDatabaseScope
  let zoneName: String
  let zoneOwnerName: String
  let localOperation: CloudOperationEnvelope
  let localTombstone: FarmTombstoneEnvelope

  var zoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
  }
}

struct CloudTombstoneRemoteEvidence: @unchecked Sendable {
  let localOperationRecord: CKRecord?
  let tombstoneRecord: CKRecord?
  let authoritativeOperationRecord: CKRecord?
  let entityProjectionRecord: CKRecord?
}

struct CloudTombstoneCredentialRepairPlan: @unchecked Sendable {
  let operationRecord: CKRecord
  let tombstoneRecord: CKRecord
  let envelope: CloudOperationEnvelope
}

enum CloudTombstoneEvidenceDecision: @unchecked Sendable {
  case equivalent(operation: CKRecord, tombstone: CKRecord)
  case retryOperation(tombstone: CKRecord)
  case superseded(operation: CKRecord, tombstone: CKRecord, envelope: CloudOperationEnvelope)
  case unresolved(String)
}

enum CloudTombstoneEvidenceEvaluator {
  static func evaluate(
    candidate: CloudTombstoneConflictCandidate,
    evidence: CloudTombstoneRemoteEvidence,
    mapper: CloudRecordMapper = CloudRecordMapper()
  ) -> CloudTombstoneEvidenceDecision {
    guard let tombstoneRecord = evidence.tombstoneRecord,
      tombstoneRecord.recordID.zoneID == candidate.zoneID
    else {
      return .unresolved("云端 Tombstone 缺失或位于错误的 Zone。")
    }
    let remoteTombstone: FarmTombstoneEnvelope
    do {
      remoteTombstone = try mapper.tombstoneEnvelope(from: tombstoneRecord)
    } catch {
      return .unresolved("云端 Tombstone 字段、载荷或签名索引不一致。")
    }
    guard remoteTombstone.farmID == candidate.farmID,
      remoteTombstone.entityID == candidate.localTombstone.entityID,
      remoteTombstone.entityType == candidate.localTombstone.entityType,
      remoteTombstone.revision == candidate.localTombstone.revision
    else {
      return .unresolved("云端 Tombstone 的牧场、实体、类型或 revision 不匹配。")
    }

    if remoteTombstone.operationID == candidate.localOperation.operationID {
      guard let operationRecord = evidence.localOperationRecord else {
        return tombstoneMatchesLocalSemantics(remoteTombstone, candidate.localTombstone)
          && tombstoneCredentialsMatchEnvelope(tombstoneRecord, candidate.localOperation)
          ? .retryOperation(tombstone: tombstoneRecord)
          : .unresolved("Tombstone 使用本地 operationID，但删除语义不同。")
      }
      guard operationRecord.recordID.zoneID == candidate.zoneID,
        let envelope = try? mapper.operationEnvelope(from: operationRecord),
        operationsHaveSameImmutableFact(envelope, candidate.localOperation),
        operationRecord.recordID.recordName == mapper.recordName(for: envelope.operationID),
        tombstoneCredentialsMatchOperation(tombstoneRecord, operationRecord),
        tombstoneMatchesOperation(remoteTombstone, envelope),
        tombstoneMatchesLocalSemantics(remoteTombstone, candidate.localTombstone)
      else {
        var mismatches: [String] = []
        if operationRecord.recordID.zoneID != candidate.zoneID { mismatches.append("zone") }
        if let envelope = try? mapper.operationEnvelope(from: operationRecord) {
          mismatches.append(contentsOf: immutableOperationMismatches(envelope, candidate.localOperation))
          if operationRecord.recordID.recordName != mapper.recordName(for: envelope.operationID) {
            mismatches.append("recordName")
          }
          if !tombstoneMatchesOperation(remoteTombstone, envelope) {
            mismatches.append("删除语义")
          }
        } else {
          mismatches.append("Operation 无法解析")
        }
        mismatches.append(contentsOf: credentialMismatches(tombstoneRecord, operationRecord))
        if !tombstoneMatchesLocalSemantics(remoteTombstone, candidate.localTombstone) {
          mismatches.append("本机 Tombstone 语义")
        }
        return .unresolved(
          "同一 operationID 的云端证据不一致：\(Array(Set(mismatches)).sorted().joined(separator: "、"))。"
        )
      }
      return .equivalent(operation: operationRecord, tombstone: tombstoneRecord)
    }

    guard let operationRecord = evidence.authoritativeOperationRecord else {
      return .unresolved("云端 Tombstone 指向另一条 operationID，但对应 Operation 缺失。")
    }
    guard operationRecord.recordID.zoneID == candidate.zoneID else {
      return .unresolved("云端权威 Operation 位于错误的 Zone。")
    }
    guard let envelope = try? mapper.operationEnvelope(from: operationRecord) else {
      return .unresolved("云端权威 Operation 字段或载荷无法解析。")
    }
    var mismatches: [String] = []
    if operationRecord.recordID.recordName != mapper.recordName(for: remoteTombstone.operationID) {
      mismatches.append("recordName")
    }
    if envelope.operationID != remoteTombstone.operationID { mismatches.append("operationID") }
    if envelope.farmID != candidate.farmID { mismatches.append("farmID") }
    if envelope.entityID != candidate.localOperation.entityID { mismatches.append("entityID") }
    if envelope.entityType != candidate.localOperation.entityType { mismatches.append("entityType") }
    if envelope.baseRevision != candidate.localOperation.baseRevision { mismatches.append("baseRevision") }
    if envelope.revision != candidate.localOperation.revision { mismatches.append("revision") }
    mismatches.append(contentsOf: credentialMismatches(tombstoneRecord, operationRecord))
    if !tombstoneMatchesOperation(remoteTombstone, envelope) {
      mismatches.append("删除语义")
    }
    if !isTombstoneOperation(envelope) { mismatches.append("操作类型") }
    guard mismatches.isEmpty else {
      return .unresolved(
        "云端不同 operationID 的删除证据链不一致：\(mismatches.joined(separator: "、"))。"
      )
    }
    return .superseded(
      operation: operationRecord,
      tombstone: tombstoneRecord,
      envelope: envelope
    )
  }

  private static func tombstoneMatchesLocalSemantics(
    _ remote: FarmTombstoneEnvelope,
    _ local: FarmTombstoneEnvelope
  ) -> Bool {
    remote.farmID == local.farmID && remote.entityType == local.entityType
      && remote.entityID == local.entityID && remote.revision == local.revision
      && remote.deletedByAccountID == local.deletedByAccountID && remote.reason == local.reason
      && abs(remote.deletedAt.timeIntervalSince(local.deletedAt)) < 1
  }

  static func operationsAreImmutableEquivalent(
    _ lhs: CloudOperationEnvelope,
    _ rhs: CloudOperationEnvelope
  ) -> Bool {
    lhs.farmID == rhs.farmID && lhs.entityID == rhs.entityID
      && lhs.entityType == rhs.entityType && lhs.schemaVersion == rhs.schemaVersion
      && lhs.revision == rhs.revision && lhs.baseRevision == rhs.baseRevision
      && lhs.operationID == rhs.operationID
      && abs(lhs.modifiedAt.timeIntervalSince(rhs.modifiedAt)) < 1
      && lhs.modifiedByAccountID == rhs.modifiedByAccountID
      && lhs.modifiedByDeviceID == rhs.modifiedByDeviceID
      && lhs.payload == rhs.payload && lhs.payloadDigest == rhs.payloadDigest
      && lhs.capabilityCertificate == rhs.capabilityCertificate
      && lhs.operationSignature == rhs.operationSignature
      && optionalDatesMatch(lhs.deletedAt, rhs.deletedAt)
  }

  /// CloudKit's immutable Operation is authoritative for its signing tuple.
  /// Older clients could re-sign a persisted DomainOperation while retrying a
  /// sibling Tombstone record, mutating only device/certificate/signature in
  /// the local cache. All business fields must still match exactly.
  static func operationsHaveSameImmutableFact(
    _ lhs: CloudOperationEnvelope,
    _ rhs: CloudOperationEnvelope
  ) -> Bool {
    lhs.farmID == rhs.farmID && lhs.entityID == rhs.entityID
      && lhs.entityType == rhs.entityType && lhs.schemaVersion == rhs.schemaVersion
      && lhs.revision == rhs.revision && lhs.baseRevision == rhs.baseRevision
      && lhs.operationID == rhs.operationID
      && abs(lhs.modifiedAt.timeIntervalSince(rhs.modifiedAt)) < 1
      && lhs.modifiedByAccountID == rhs.modifiedByAccountID
      && lhs.payload == rhs.payload && lhs.payloadDigest == rhs.payloadDigest
      && optionalDatesMatch(lhs.deletedAt, rhs.deletedAt)
  }

  static func credentialRepairPlan(
    candidate: CloudTombstoneConflictCandidate,
    evidence: CloudTombstoneRemoteEvidence,
    mapper: CloudRecordMapper = CloudRecordMapper()
  ) -> CloudTombstoneCredentialRepairPlan? {
    guard let tombstoneRecord = evidence.tombstoneRecord,
      tombstoneRecord.recordID.zoneID == candidate.zoneID,
      let remoteTombstone = try? mapper.tombstoneEnvelope(from: tombstoneRecord),
      remoteTombstone.farmID == candidate.farmID,
      remoteTombstone.entityID == candidate.localOperation.entityID,
      remoteTombstone.entityType == candidate.localOperation.entityType,
      remoteTombstone.revision == candidate.localOperation.revision
    else { return nil }

    let operationRecord =
      remoteTombstone.operationID == candidate.localOperation.operationID
      ? evidence.localOperationRecord
      : evidence.authoritativeOperationRecord
    guard let operationRecord,
      operationRecord.recordID.zoneID == candidate.zoneID,
      let envelope = try? mapper.operationEnvelope(from: operationRecord),
      operationRecord.recordID.recordName == mapper.recordName(for: envelope.operationID),
      envelope.operationID == remoteTombstone.operationID,
      envelope.farmID == candidate.farmID,
      envelope.entityID == candidate.localOperation.entityID,
      envelope.entityType == candidate.localOperation.entityType,
      envelope.baseRevision == candidate.localOperation.baseRevision,
      envelope.revision == candidate.localOperation.revision,
      tombstoneMatchesOperation(remoteTombstone, envelope),
      isTombstoneOperation(envelope),
      !credentialMismatches(tombstoneRecord, operationRecord).isEmpty
    else { return nil }

    if envelope.operationID == candidate.localOperation.operationID,
      !operationsHaveSameImmutableFact(envelope, candidate.localOperation)
    {
      return nil
    }
    return CloudTombstoneCredentialRepairPlan(
      operationRecord: operationRecord,
      tombstoneRecord: tombstoneRecord,
      envelope: envelope
    )
  }

  private static func immutableOperationMismatches(
    _ lhs: CloudOperationEnvelope,
    _ rhs: CloudOperationEnvelope
  ) -> [String] {
    var result: [String] = []
    if lhs.farmID != rhs.farmID { result.append("farmID") }
    if lhs.entityID != rhs.entityID { result.append("entityID") }
    if lhs.entityType != rhs.entityType { result.append("entityType") }
    if lhs.schemaVersion != rhs.schemaVersion { result.append("schemaVersion") }
    if lhs.revision != rhs.revision { result.append("revision") }
    if lhs.baseRevision != rhs.baseRevision { result.append("baseRevision") }
    if lhs.operationID != rhs.operationID { result.append("operationID") }
    if abs(lhs.modifiedAt.timeIntervalSince(rhs.modifiedAt)) >= 1 { result.append("modifiedAt") }
    if lhs.modifiedByAccountID != rhs.modifiedByAccountID { result.append("accountID") }
    if lhs.modifiedByDeviceID != rhs.modifiedByDeviceID { result.append("deviceID") }
    if lhs.payload != rhs.payload { result.append("payload") }
    if lhs.payloadDigest != rhs.payloadDigest { result.append("payloadDigest") }
    if lhs.capabilityCertificate != rhs.capabilityCertificate { result.append("capabilityCertificate") }
    if lhs.operationSignature != rhs.operationSignature { result.append("operationSignature") }
    if !optionalDatesMatch(lhs.deletedAt, rhs.deletedAt) { result.append("deletedAt") }
    return result
  }

  private static func optionalDatesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case let (.some(lhs), .some(rhs)): abs(lhs.timeIntervalSince(rhs)) < 1
    default: false
    }
  }

  private static func tombstoneMatchesOperation(
    _ tombstone: FarmTombstoneEnvelope,
    _ operation: CloudOperationEnvelope
  ) -> Bool {
    tombstone.farmID == operation.farmID && tombstone.entityID == operation.entityID
      && tombstone.entityType == operation.entityType && tombstone.revision == operation.revision
      && tombstone.operationID == operation.operationID
      && operation.deletedAt.map { abs($0.timeIntervalSince(tombstone.deletedAt)) < 1 } == true
      && isTombstoneOperation(operation)
  }

  private static func tombstoneCredentialsMatchOperation(
    _ tombstone: CKRecord,
    _ operation: CKRecord
  ) -> Bool {
    (tombstone[CloudRecordField.capabilityCertificate] as? String)
      == (operation[CloudRecordField.capabilityCertificate] as? String)
      && (tombstone[CloudRecordField.signature] as? Data)
        == (operation[CloudRecordField.operationSignature] as? Data)
  }

  private static func credentialMismatches(
    _ tombstone: CKRecord,
    _ operation: CKRecord
  ) -> [String] {
    var result: [String] = []
    if (tombstone[CloudRecordField.capabilityCertificate] as? String)
      != (operation[CloudRecordField.capabilityCertificate] as? String)
    {
      result.append("capabilityCertificate 索引")
    }
    if (tombstone[CloudRecordField.signature] as? Data)
      != (operation[CloudRecordField.operationSignature] as? Data)
    {
      result.append("signature 索引")
    }
    return result
  }

  private static func tombstoneCredentialsMatchEnvelope(
    _ tombstone: CKRecord,
    _ operation: CloudOperationEnvelope
  ) -> Bool {
    (tombstone[CloudRecordField.capabilityCertificate] as? String)
      == operation.capabilityCertificate
      && (tombstone[CloudRecordField.signature] as? Data) == operation.operationSignature
  }

  private static func isTombstoneOperation(_ envelope: CloudOperationEnvelope) -> Bool {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard
      let payload = try? decoder.decode(
        FarmCommandCloudPayload.self,
        from: envelope.payload
      )
    else { return false }
    return payload.kind == DomainOperationKind.tombstoneEntity
  }
}

protocol CloudTombstoneRecordFetching: Sendable {
  func record(for id: CKRecord.ID, scope: CloudDatabaseScope) async throws -> CKRecord?
  func save(_ record: CKRecord, scope: CloudDatabaseScope) async throws -> CKRecord
}

actor CloudKitTombstoneRecordFetcher: CloudTombstoneRecordFetching {
  private let containerIdentifier: String?
  private lazy var container: CKContainer = Self.makeContainer(
    identifier: containerIdentifier
  )

  init(containerIdentifier: String?) {
    self.containerIdentifier = containerIdentifier
  }

  private static func makeContainer(identifier: String?) -> CKContainer {
    if let identifier, !identifier.isEmpty {
      return CKContainer(identifier: identifier)
    }
    return CKContainer.default()
  }

  func record(for id: CKRecord.ID, scope: CloudDatabaseScope) async throws -> CKRecord? {
    let database =
      scope == .privateDatabase
      ? container.privateCloudDatabase
      : container.sharedCloudDatabase
    do {
      return try await database.record(for: id)
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    }
  }

  func save(_ record: CKRecord, scope: CloudDatabaseScope) async throws -> CKRecord {
    let database =
      scope == .privateDatabase
      ? container.privateCloudDatabase
      : container.sharedCloudDatabase
    return try await database.save(record)
  }
}

actor CloudTombstoneConflictReconciliationService {
  private let persistence: FarmPersistenceActor
  private let fetcher: any CloudTombstoneRecordFetching
  private let mapper = CloudRecordMapper()

  init(
    persistence: FarmPersistenceActor,
    fetcher: any CloudTombstoneRecordFetching
  ) {
    self.persistence = persistence
    self.fetcher = fetcher
  }

  init(containerIdentifier: String?, persistence: FarmPersistenceActor) {
    self.persistence = persistence
    self.fetcher = CloudKitTombstoneRecordFetcher(containerIdentifier: containerIdentifier)
  }

  func reconcile(farmID: UUID) async throws -> CloudTombstoneReconciliationReport {
    let startedAt = Date.now
    let blockedCandidates = try await persistence.tombstoneConflictCandidates(farmID: farmID)
    let candidates = blockedCandidates.isEmpty
      ? try await persistence.tombstoneAuthorityProjectionCandidates(farmID: farmID)
      : blockedCandidates
    var items: [CloudTombstoneReconciliationItem] = []
    for candidate in candidates {
      do {
        let tombstoneID = CKRecord.ID(
          recordName: mapper.tombstoneRecordName(for: candidate.localTombstone.entityID),
          zoneID: candidate.zoneID
        )
        let localOperationID = CKRecord.ID(
          recordName: mapper.recordName(for: candidate.localOperation.operationID),
          zoneID: candidate.zoneID
        )
        let entityID = CKRecord.ID(
          recordName: mapper.entityRecordName(for: candidate.localOperation.entityID),
          zoneID: candidate.zoneID
        )
        var tombstone = try await fetcher.record(for: tombstoneID, scope: candidate.scope)
        let localOperation = try await fetcher.record(for: localOperationID, scope: candidate.scope)
        let remoteTombstone = tombstone.flatMap { try? mapper.tombstoneEnvelope(from: $0) }
        let authoritativeOperation: CKRecord?
        if let operationID = remoteTombstone?.operationID,
          operationID != candidate.localOperation.operationID
        {
          authoritativeOperation = try await fetcher.record(
            for: CKRecord.ID(
              recordName: mapper.recordName(for: operationID),
              zoneID: candidate.zoneID
            ),
            scope: candidate.scope
          )
        } else {
          authoritativeOperation = nil
        }
        let projection = try await fetcher.record(for: entityID, scope: candidate.scope)
        var evidence = CloudTombstoneRemoteEvidence(
          localOperationRecord: localOperation,
          tombstoneRecord: tombstone,
          authoritativeOperationRecord: authoritativeOperation,
          entityProjectionRecord: projection
        )
        if let repair = CloudTombstoneEvidenceEvaluator.credentialRepairPlan(
          candidate: candidate,
          evidence: evidence,
          mapper: mapper
        ) {
          try await persistence.validateTombstoneCredentialRepairAuthority(
            repair.operationRecord,
            candidate: candidate,
            expectedOperationID: repair.envelope.operationID
          )
          repair.tombstoneRecord[CloudRecordField.capabilityCertificate] =
            repair.operationRecord[CloudRecordField.capabilityCertificate]
          repair.tombstoneRecord[CloudRecordField.signature] =
            repair.operationRecord[CloudRecordField.operationSignature]
          tombstone = try await fetcher.save(repair.tombstoneRecord, scope: candidate.scope)
          evidence = CloudTombstoneRemoteEvidence(
            localOperationRecord: localOperation,
            tombstoneRecord: tombstone,
            authoritativeOperationRecord: authoritativeOperation,
            entityProjectionRecord: projection
          )
        }
        let item = try await persistence.applyTombstoneReconciliation(
          candidate: candidate,
          evidence: evidence
        )
        items.append(item)
      } catch {
        items.append(
          CloudTombstoneReconciliationItem(
            operationID: candidate.localOperation.operationID,
            entityID: candidate.localOperation.entityID,
            outcome: .unresolvedDivergence,
            detail: "CloudKit 证据读取或安全验证失败：\(error.localizedDescription)"
          ))
      }
    }
    return CloudTombstoneReconciliationReport(
      farmID: farmID,
      startedAt: startedAt,
      completedAt: .now,
      items: items
    )
  }
}
