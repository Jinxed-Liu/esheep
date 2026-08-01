import Foundation

/// The single source of truth for records that prove an Outbox operation was
/// durably delivered. Immutable operations are always required. A mutable
/// entity projection is required only for the latest non-bootstrap,
/// non-deletion operation. A deletion is authoritative once its immutable
/// operation and immutable tombstone are both confirmed.
enum CloudDeliveryReceiptContract {
  static func requiredRecordNames(
    for operation: DomainOperation,
    latestOperationForEntity: DomainOperation?,
    mapper: CloudRecordMapper = CloudRecordMapper()
  ) -> Set<String> {
    var names: Set<String> = [mapper.recordName(for: operation.id)]

    if operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
      let entityID = operation.entityID
    {
      names.insert(mapper.tombstoneRecordName(for: entityID))
      return names
    }

    guard let entityID = operation.entityID,
      !isRefreshedBootstrap(operation),
      latestOperationForEntity?.id == operation.id
    else {
      return names
    }
    names.insert(mapper.entityRecordName(for: entityID))
    return names
  }

  /// Legacy CKSyncEngine state can still report a mutable entity save for a
  /// tombstone created by an older build. It is safe to recognize that record
  /// as belonging to the operation, but it is never required for completion.
  static func acceptedRecordNames(
    for operation: DomainOperation,
    latestOperationForEntity: DomainOperation?,
    mapper: CloudRecordMapper = CloudRecordMapper()
  ) -> Set<String> {
    var names = requiredRecordNames(
      for: operation,
      latestOperationForEntity: latestOperationForEntity,
      mapper: mapper
    )
    if operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
      let entityID = operation.entityID
    {
      names.insert(mapper.entityRecordName(for: entityID))
    }
    return names
  }

  private static func isRefreshedBootstrap(_ operation: DomainOperation) -> Bool {
    guard operation.kindRawValue == DomainOperationKind.bootstrapEntity.rawValue else {
      return false
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let payload = try? decoder.decode(FarmCommandCloudPayload.self, from: operation.payload)
    else {
      return false
    }
    return payload.kind == .bootstrapEntity && (payload.integers["baselineVersion"] ?? 1) >= 2
  }
}
