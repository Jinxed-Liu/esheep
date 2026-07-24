import CloudKit
import Foundation

enum CloudRecordField {
    static let farmID = "farmID"
    static let entityID = "entityID"
    static let entityType = "entityType"
    static let schemaVersion = "schemaVersion"
    static let revision = "revision"
    static let baseRevision = "baseRevision"
    static let operationID = "operationID"
    static let modifiedAt = "modifiedAt"
    static let modifiedByAccountID = "modifiedByAccountID"
    static let modifiedByDeviceID = "modifiedByDeviceID"
    static let payload = "payload"
    static let payloadDigest = "payloadDigest"
    static let capabilityCertificate = "capabilityCertificate"
    static let operationSignature = "operationSignature"
    static let deletedAt = "deletedAt"
    static let asset = "asset"
    static let sourceDigest = "sourceDigest"
    static let byteCount = "byteCount"
    static let mimeType = "mimeType"
    static let pixelWidth = "pixelWidth"
    static let pixelHeight = "pixelHeight"
    static let capturedAt = "capturedAt"
    static let assetSignatureVersion = "assetSignatureVersion"
    static let generation = "generation"
    static let issuedAt = "issuedAt"
    static let signature = "signature"
    static let bootstrapState = "bootstrapState"
    static let bootstrapDigest = "bootstrapDigest"
    static let bootstrapEntityCount = "bootstrapEntityCount"
    static let bootstrapPhotoCount = "bootstrapPhotoCount"
    static let bootstrapVersion = "bootstrapVersion"
    static let bootstrapCutoffAt = "bootstrapCutoffAt"
}

struct CloudRecordMapper: Sendable {
    struct FarmRootValue: Sendable, Equatable {
        let farmID: UUID
        let name: String
        let ownerAccountID: UUID
        let modifiedAt: Date
    }

    func operationRecord(from envelope: CloudOperationEnvelope, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName(for: envelope.operationID), zoneID: zoneID)
        return record(from: envelope, recordType: .farmOperation, recordID: recordID)
    }

    func entityRecord(from envelope: CloudOperationEnvelope, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: entityRecordName(for: envelope.entityID), zoneID: zoneID)
        return record(from: envelope, recordType: .farmEntity, recordID: recordID)
    }

    /// FarmEntity is a mutable latest-state projection. CloudKit requires an
    /// existing record's system fields (especially its change tag) for an
    /// optimistic update, so reuse the fetched server object only after its
    /// operation lineage has been verified as an ancestor of this operation.
    /// Returning a fresh record for an incompatible server value deliberately
    /// lets CloudKit report a conflict instead of overwriting another device.
    func entityRecord(
        from envelope: CloudOperationEnvelope,
        zoneID: CKRecordZone.ID,
        existingRecord: CKRecord?,
        existingRecordIsVerifiedAncestor: Bool = false
    ) -> CKRecord {
        let recordID = CKRecord.ID(recordName: entityRecordName(for: envelope.entityID), zoneID: zoneID)
        guard let existingRecord,
              CloudEntityProjectionPolicy.canApply(
                envelope: envelope,
                to: existingRecord,
                ancestorIsVerified: existingRecordIsVerifiedAncestor
              ) else {
            return record(from: envelope, recordType: .farmEntity, recordID: recordID)
        }
        return apply(envelope, to: existingRecord)
    }

    private func record(from envelope: CloudOperationEnvelope, recordType: CloudRecordType, recordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: recordType.rawValue, recordID: recordID)
        return apply(envelope, to: record)
    }

    private func apply(_ envelope: CloudOperationEnvelope, to record: CKRecord) -> CKRecord {
        record[CloudRecordField.farmID] = envelope.farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.entityID] = envelope.entityID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.entityType] = envelope.entityType as CKRecordValue
        record[CloudRecordField.schemaVersion] = envelope.schemaVersion as CKRecordValue
        record[CloudRecordField.revision] = envelope.revision as CKRecordValue
        record[CloudRecordField.baseRevision] = envelope.baseRevision as CKRecordValue
        record[CloudRecordField.operationID] = envelope.operationID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.modifiedAt] = envelope.modifiedAt as CKRecordValue
        record[CloudRecordField.modifiedByAccountID] = envelope.modifiedByAccountID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.modifiedByDeviceID] = envelope.modifiedByDeviceID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.payload] = envelope.payload as CKRecordValue
        record[CloudRecordField.payloadDigest] = envelope.payloadDigest as CKRecordValue
        record[CloudRecordField.capabilityCertificate] = envelope.capabilityCertificate as CKRecordValue
        record[CloudRecordField.operationSignature] = envelope.operationSignature as CKRecordValue
        if let deletedAt = envelope.deletedAt {
            record[CloudRecordField.deletedAt] = deletedAt as CKRecordValue
        } else {
            // A restore operation must clear a tombstone left on the mutable
            // projection rather than inheriting it from the fetched record.
            record[CloudRecordField.deletedAt] = nil
        }
        return record
    }

    func operationEnvelope(from record: CKRecord) throws -> CloudOperationEnvelope {
        guard (record.recordType == CloudRecordType.farmOperation.rawValue || record.recordType == CloudRecordType.farmEntity.rawValue),
              let farmID = uuid(record[CloudRecordField.farmID]),
              let entityID = uuid(record[CloudRecordField.entityID]),
              let entityType = record[CloudRecordField.entityType] as? String,
              let schemaVersion = integer(record[CloudRecordField.schemaVersion]),
              let revision = integer(record[CloudRecordField.revision]),
              let baseRevision = integer(record[CloudRecordField.baseRevision]),
              let operationID = uuid(record[CloudRecordField.operationID]),
              let modifiedAt = record[CloudRecordField.modifiedAt] as? Date,
              let accountID = uuid(record[CloudRecordField.modifiedByAccountID]),
              let deviceID = uuid(record[CloudRecordField.modifiedByDeviceID]),
              let payload = record[CloudRecordField.payload] as? Data,
              let payloadDigest = record[CloudRecordField.payloadDigest] as? String,
              let capabilityCertificate = record[CloudRecordField.capabilityCertificate] as? String,
              let operationSignature = record[CloudRecordField.operationSignature] as? Data else {
            throw CloudContractError.malformedRecord
        }
        return CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: entityType,
            schemaVersion: schemaVersion,
            revision: revision,
            baseRevision: baseRevision,
            operationID: operationID,
            modifiedAt: modifiedAt,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: deviceID,
            payload: payload,
            payloadDigest: payloadDigest,
            capabilityCertificate: capabilityCertificate,
            operationSignature: operationSignature,
            deletedAt: record[CloudRecordField.deletedAt] as? Date
        )
    }

    func rootRecord(farmID: UUID, farmName: String, ownerAccountID: UUID, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: "root_\(farmID.uuidString.lowercased())", zoneID: zoneID)
        let record = CKRecord(recordType: CloudRecordType.farmRoot.rawValue, recordID: recordID)
        record[CloudRecordField.farmID] = farmID.uuidString.lowercased() as CKRecordValue
        record["farmName"] = farmName as CKRecordValue
        record["ownerAccountID"] = ownerAccountID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.schemaVersion] = 1 as CKRecordValue
        record[CloudRecordField.revision] = 1 as CKRecordValue
        record[CloudRecordField.modifiedAt] = Date.now as CKRecordValue
        return record
    }

    func assetRecord(envelope: FarmAssetEnvelope, fileURL: URL, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: assetRecordName(for: envelope.assetID), zoneID: zoneID)
        let record = CKRecord(recordType: CloudRecordType.farmAsset.rawValue, recordID: recordID)
        record[CloudRecordField.farmID] = envelope.farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.entityID] = envelope.assetID.uuidString.lowercased() as CKRecordValue
        if let entityID = envelope.entityID { record["linkedEntityID"] = entityID.uuidString.lowercased() as CKRecordValue }
        record[CloudRecordField.sourceDigest] = envelope.sourceDigest as CKRecordValue
        record[CloudRecordField.payloadDigest] = envelope.payloadDigest as CKRecordValue
        record[CloudRecordField.mimeType] = envelope.mimeType as CKRecordValue
        record[CloudRecordField.pixelWidth] = envelope.pixelWidth as CKRecordValue
        record[CloudRecordField.pixelHeight] = envelope.pixelHeight as CKRecordValue
        record[CloudRecordField.byteCount] = envelope.byteCount as CKRecordValue
        record[CloudRecordField.modifiedAt] = envelope.createdAt as CKRecordValue
        record[CloudRecordField.modifiedByAccountID] = envelope.modifiedByAccountID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.modifiedByDeviceID] = envelope.modifiedByDeviceID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.capabilityCertificate] = envelope.capabilityCertificate as CKRecordValue
        record[CloudRecordField.signature] = envelope.signature as CKRecordValue
        record[CloudRecordField.assetSignatureVersion] = 2 as CKRecordValue
        if let capturedAt = envelope.capturedAt { record[CloudRecordField.capturedAt] = capturedAt as CKRecordValue }
        record[CloudRecordField.asset] = CKAsset(fileURL: fileURL)
        return record
    }

    /// A missing marker is the only implicit legacy form. Any explicit value
    /// must be one of the protocol versions we understand; malformed strings,
    /// booleans, fractions, and future versions fail closed.
    func assetSignatureVersion(from record: CKRecord) throws -> Int? {
        guard let rawValue = record[CloudRecordField.assetSignatureVersion] else {
            return nil
        }
        guard !(rawValue is Bool),
              let version = rawValue as? Int,
              version == FarmAssetSignatureFormat.legacyV1.rawValue ||
                version == FarmAssetSignatureFormat.v2.rawValue else {
            throw CloudContractError.invalidDeviceSignature
        }
        return version
    }

    func assetAuthorizationDate(from record: CKRecord) throws -> Date {
        try Self.assetAuthorizationDate(
            modificationDate: record.modificationDate,
            creationDate: record.creationDate
        )
    }

    static func assetAuthorizationDate(
        modificationDate: Date?,
        creationDate: Date?
    ) throws -> Date {
        guard let value = modificationDate ?? creationDate else {
            throw CloudContractError.capabilityDenied
        }
        return value
    }

    func membershipSnapshotRecord(
        record: FarmMembershipSnapshotRecord,
        zoneID: CKRecordZone.ID,
        existingRecord: CKRecord? = nil
    ) -> CKRecord {
        let recordID = CKRecord.ID(recordName: "membership_snapshot", zoneID: zoneID)
        let cloud: CKRecord
        if let existingRecord, existingRecord.recordID == recordID,
           existingRecord.recordType == CloudRecordType.farmMembershipSnapshot.rawValue {
            cloud = existingRecord
        } else {
            cloud = CKRecord(recordType: CloudRecordType.farmMembershipSnapshot.rawValue, recordID: recordID)
        }
        cloud[CloudRecordField.farmID] = record.farmID.uuidString.lowercased() as CKRecordValue
        cloud[CloudRecordField.generation] = record.generation as CKRecordValue
        cloud[CloudRecordField.issuedAt] = record.issuedAt as CKRecordValue
        cloud[CloudRecordField.payload] = record.payload as CKRecordValue
        cloud[CloudRecordField.payloadDigest] = record.payloadDigest as CKRecordValue
        cloud[CloudRecordField.modifiedByAccountID] = record.signedByAccountID.uuidString.lowercased() as CKRecordValue
        cloud[CloudRecordField.modifiedByDeviceID] = record.signedByDeviceID.uuidString.lowercased() as CKRecordValue
        cloud[CloudRecordField.capabilityCertificate] = record.capabilityCertificate as CKRecordValue
        cloud[CloudRecordField.signature] = record.signature as CKRecordValue
        return cloud
    }

    func tombstoneRecord(envelope: FarmTombstoneEnvelope, certificate: String, signature: Data, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: "tombstone_\(envelope.entityID.uuidString.lowercased())", zoneID: zoneID)
        let record = CKRecord(recordType: CloudRecordType.farmTombstone.rawValue, recordID: recordID)
        record[CloudRecordField.farmID] = envelope.farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.entityID] = envelope.entityID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.entityType] = envelope.entityType as CKRecordValue
        record[CloudRecordField.revision] = envelope.revision as CKRecordValue
        record[CloudRecordField.operationID] = envelope.operationID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.deletedAt] = envelope.deletedAt as CKRecordValue
        record["deletedByAccountID"] = envelope.deletedByAccountID.uuidString.lowercased() as CKRecordValue
        record["reason"] = envelope.reason as CKRecordValue
        if let payload = try? JSONEncoder.cloud.encode(envelope) {
            record[CloudRecordField.payload] = payload as CKRecordValue
        }
        record[CloudRecordField.capabilityCertificate] = certificate as CKRecordValue
        record[CloudRecordField.signature] = signature as CKRecordValue
        return record
    }

    func farmRootValue(from record: CKRecord) throws -> FarmRootValue {
        guard record.recordType == CloudRecordType.farmRoot.rawValue,
              let farmID = uuid(record[CloudRecordField.farmID]),
              let name = record["farmName"] as? String,
              let ownerAccountID = uuid(record["ownerAccountID"]),
              let modifiedAt = record[CloudRecordField.modifiedAt] as? Date else {
            throw CloudContractError.malformedRecord
        }
        return FarmRootValue(farmID: farmID, name: name, ownerAccountID: ownerAccountID, modifiedAt: modifiedAt)
    }

    func recordName(for operationID: UUID) -> String {
        "op_\(operationID.uuidString.lowercased())"
    }

    func entityRecordName(for entityID: UUID) -> String {
        "entity_\(entityID.uuidString.lowercased())"
    }

    func entityID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.recordName.hasPrefix("entity_") else { return nil }
        return UUID(uuidString: String(recordID.recordName.dropFirst(7)))
    }

    func assetRecordName(for assetID: UUID) -> String {
        "asset_\(assetID.uuidString.lowercased())"
    }

    func assetID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.recordName.hasPrefix("asset_") else { return nil }
        return UUID(uuidString: String(recordID.recordName.dropFirst(6)))
    }

    func tombstoneRecordName(for entityID: UUID) -> String {
        "tombstone_\(entityID.uuidString.lowercased())"
    }

    func tombstoneEntityID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.recordName.hasPrefix("tombstone_") else { return nil }
        return UUID(uuidString: String(recordID.recordName.dropFirst(10)))
    }

    func operationID(from recordID: CKRecord.ID) -> UUID? {
        if recordID.recordName.hasPrefix("op_") {
            return UUID(uuidString: String(recordID.recordName.dropFirst(3)))
        }
        return nil
    }

    private func uuid(_ value: CKRecordValue?) -> UUID? {
        guard let text = value as? String else { return nil }
        return UUID(uuidString: text)
    }

    private func integer(_ value: CKRecordValue?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

enum CloudEntityProjectionPolicy {
    static func canApply(
        envelope: CloudOperationEnvelope,
        to server: CKRecord,
        ancestorIsVerified: Bool = false
    ) -> Bool {
        guard matchesProjection(
            record: server,
            recordID: CKRecord.ID(
                recordName: "entity_\(envelope.entityID.uuidString.lowercased())",
                zoneID: server.recordID.zoneID
            ),
            farmID: envelope.farmID.uuidString.lowercased(),
            entityID: envelope.entityID.uuidString.lowercased(),
            entityType: envelope.entityType
        ), let serverRevision = integer(server[CloudRecordField.revision]) else {
            return false
        }

        if serverRevision == envelope.revision &&
            server[CloudRecordField.operationID] as? String == envelope.operationID.uuidString.lowercased() &&
            server[CloudRecordField.payloadDigest] as? String == envelope.payloadDigest {
            return true
        }

        return ancestorIsVerified && serverRevision <= envelope.baseRevision
    }

    /// Revision equality is necessary but not sufficient for retry. The caller
    /// must also prove that the server operation belongs to the local immutable
    /// lineage; the boolean keeps that authorization explicit at the call site.
    static func canRetry(
        client: CKRecord,
        against server: CKRecord,
        ancestorIsVerified: Bool = false
    ) -> Bool {
        guard let farmID = client[CloudRecordField.farmID] as? String,
              let entityID = client[CloudRecordField.entityID] as? String,
              let entityType = client[CloudRecordField.entityType] as? String,
              matchesProjection(
                record: server,
                recordID: client.recordID,
                farmID: farmID,
                entityID: entityID,
                entityType: entityType
              ),
              let baseRevision = integer(client[CloudRecordField.baseRevision]),
              let serverRevision = integer(server[CloudRecordField.revision]) else {
            return false
        }
        return ancestorIsVerified && serverRevision == baseRevision
    }

    static func revisions(client: CKRecord, server: CKRecord) -> (base: Int?, remote: Int?) {
        (integer(client[CloudRecordField.baseRevision]), integer(server[CloudRecordField.revision]))
    }

    private static func matchesProjection(
        record: CKRecord,
        recordID: CKRecord.ID,
        farmID: String,
        entityID: String,
        entityType: String
    ) -> Bool {
        record.recordType == CloudRecordType.farmEntity.rawValue &&
            record.recordID == recordID &&
            record[CloudRecordField.farmID] as? String == farmID &&
            record[CloudRecordField.entityID] as? String == entityID &&
            record[CloudRecordField.entityType] as? String == entityType
    }

    private static func integer(_ value: CKRecordValue?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

/// Verifies that a mutable server projection belongs to the local immutable
/// operation chain. This allows a later operation to repair a skipped
/// intermediate projection without treating a different device's branch as
/// its own base revision.
enum CloudEntityProjectionLineage {
    static func isVerifiedAncestor(
        server: CKRecord,
        candidate: DomainOperation,
        history: [DomainOperation],
        confirmedOperationRecordNames: Set<String>,
        mapper: CloudRecordMapper = CloudRecordMapper()
    ) -> Bool {
        guard let entityID = candidate.entityID,
              server.recordType == CloudRecordType.farmEntity.rawValue,
              server.recordID.recordName == mapper.entityRecordName(for: entityID),
              server[CloudRecordField.farmID] as? String == candidate.farmID.uuidString.lowercased(),
              server[CloudRecordField.entityID] as? String == entityID.uuidString.lowercased(),
              server[CloudRecordField.entityType] as? String == candidate.entityType,
              let serverRevision = integer(server[CloudRecordField.revision]),
              let serverOperationIDText = server[CloudRecordField.operationID] as? String,
              let serverOperationID = UUID(uuidString: serverOperationIDText),
              let serverPayloadDigest = server[CloudRecordField.payloadDigest] as? String else {
            return false
        }

        if serverRevision == candidate.resultingRevision {
            return serverOperationID == candidate.id && serverPayloadDigest == candidate.payloadDigest
        }
        guard serverRevision <= candidate.baseRevision else { return false }

        let entityHistory = history.filter {
            $0.farmID == candidate.farmID &&
            $0.entityID == entityID &&
            $0.entityType == candidate.entityType
        }
        guard let serverOperation = entityHistory.first(where: {
            $0.resultingRevision == serverRevision &&
            $0.id == serverOperationID &&
            $0.payloadDigest == serverPayloadDigest
        }) else {
            return false
        }

        var previousRevision = serverOperation.resultingRevision
        guard previousRevision == serverRevision else { return false }
        if previousRevision == candidate.baseRevision { return true }

        for revision in (serverRevision + 1)...candidate.baseRevision {
            let bridges = entityHistory.filter {
                $0.baseRevision == previousRevision && $0.resultingRevision == revision
            }
            guard bridges.count == 1, let bridge = bridges.first,
                  confirmedOperationRecordNames.contains(mapper.recordName(for: bridge.id)) else {
                return false
            }
            previousRevision = bridge.resultingRevision
        }
        return previousRevision == candidate.baseRevision
    }

    private static func integer(_ value: CKRecordValue?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

enum CloudBlockedConflictRecovery {
    static func isEligible(_ message: String?) -> Bool {
        guard let message else { return true }
        if message.contains("record to insert already exists") { return true }
        if message.hasPrefix("云端实体版本") {
            let revisions = message
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            return revisions.count >= 2 && revisions[0] < revisions[1]
        }
        return !message.hasPrefix("云端已有不同内容")
    }
}
