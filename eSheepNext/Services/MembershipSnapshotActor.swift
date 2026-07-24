import CloudKit
import CryptoKit
import Foundation
import SwiftData

actor MembershipSnapshotActor {
    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private let persistence: FarmPersistenceActor
    private let mapper = CloudRecordMapper()
    private let deviceIdentity: DeviceIdentityActor
    private let worker: IdentityWorkerClient

    init(
        modelContainer: ModelContainer,
        persistence: FarmPersistenceActor,
        containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String,
        deviceIdentity: DeviceIdentityActor = .shared,
        worker: IdentityWorkerClient = .shared
    ) {
        self.modelContainer = modelContainer
        self.persistence = persistence
        self.cloudContainer = containerIdentifier.flatMap { $0.isEmpty ? nil : CKContainer(identifier: $0) } ?? .default()
        self.deviceIdentity = deviceIdentity
        self.worker = worker
    }

    func publish(farmID: UUID, accountID: UUID) async throws -> MembershipSnapshotRecordValue {
        let workerSnapshot = try await worker.farmSecuritySnapshot(farmID: farmID)
        try await persistence.saveSecuritySnapshot(workerSnapshot)
        let context = ModelContext(modelContainer)
        guard let certificate = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>())
            .filter({ $0.farmID == farmID && $0.accountID == accountID && $0.roleRawValue == FarmRole.owner.rawValue && $0.isUsable })
            .max(by: { $0.expiresAt < $1.expiresAt }) else {
            throw FarmPermissionError.denied(.manageMembers)
        }
        let identity = try await deviceIdentity.identity()
        let envelope = Self.envelope(from: workerSnapshot)
        let payload = try JSONEncoder.cloud.encode(envelope)
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(workerSnapshot.issuedAt))
        let signingData = Self.signingData(
            farmID: farmID,
            generation: workerSnapshot.generation,
            issuedAt: issuedAt,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            accountID: accountID,
            deviceID: identity.deviceID
        )
        let signature = try await deviceIdentity.sign(signingData)
        let local = FarmMembershipSnapshotRecord(
            farmID: farmID,
            generation: workerSnapshot.generation,
            issuedAt: issuedAt,
            payload: payload,
            signedByAccountID: accountID,
            signedByDeviceID: identity.deviceID,
            capabilityCertificate: certificate.certificateJWS,
            signature: signature
        )
        var value = MembershipSnapshotRecordValue(id: local.id, farmID: local.farmID, generation: local.generation, issuedAt: local.issuedAt, payload: local.payload, signedByAccountID: local.signedByAccountID, signedByDeviceID: local.signedByDeviceID, capabilityCertificate: local.capabilityCertificate, signature: local.signature, cloudRecordName: nil, validatedAt: nil)
        try await persistence.saveMembershipSnapshotRecord(value)
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID), binding.databaseScope == .privateDatabase, binding.state == .active else {
            throw PhotoTransferError.bindingMissing
        }
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: "membership_snapshot", zoneID: zoneID)
        let existingRecord: CKRecord?
        do {
            existingRecord = try await cloudContainer.privateCloudDatabase.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            existingRecord = nil
        }
        let record = mapper.membershipSnapshotRecord(
            record: local,
            zoneID: zoneID,
            existingRecord: existingRecord
        )
        let result = try await cloudContainer.privateCloudDatabase.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        _ = try result.saveResults[record.recordID]?.get()
        value = MembershipSnapshotRecordValue(id: value.id, farmID: value.farmID, generation: value.generation, issuedAt: value.issuedAt, payload: value.payload, signedByAccountID: value.signedByAccountID, signedByDeviceID: value.signedByDeviceID, capabilityCertificate: value.capabilityCertificate, signature: value.signature, cloudRecordName: record.recordID.recordName, validatedAt: .now)
        try await persistence.saveValidatedMembershipSnapshotRecord(value, envelope: envelope)
        return value
    }

    func validate(_ record: CKRecord) async throws -> MembershipSnapshotRecordValue {
        guard record.recordType == CloudRecordType.farmMembershipSnapshot.rawValue,
              let farmText = record[CloudRecordField.farmID] as? String,
              let farmID = UUID(uuidString: farmText),
              let generation = Self.integer(record[CloudRecordField.generation]),
              let issuedAt = record[CloudRecordField.issuedAt] as? Date,
              let payload = record[CloudRecordField.payload] as? Data,
              let digest = record[CloudRecordField.payloadDigest] as? String,
              let accountText = record[CloudRecordField.modifiedByAccountID] as? String,
              let accountID = UUID(uuidString: accountText),
              let deviceText = record[CloudRecordField.modifiedByDeviceID] as? String,
              let deviceID = UUID(uuidString: deviceText),
              let certificate = record[CloudRecordField.capabilityCertificate] as? String,
              let signature = record[CloudRecordField.signature] as? Data,
              digest == CloudPayloadDigest.hex(for: payload) else {
            throw CloudContractError.malformedRecord
        }
        let envelope = try JSONDecoder.membership.decode(FarmMembershipSnapshotEnvelope.self, from: payload)
        guard envelope.farmID == farmID, envelope.generation == generation else { throw CloudContractError.malformedRecord }
        let context = ModelContext(modelContainer)
        guard let publicKeyPEM = Bundle.main.object(forInfoDictionaryKey: "CAPABILITY_SIGNING_PUBLIC_KEY_PEM") as? String,
              !publicKeyPEM.isEmpty else { throw CloudContractError.invalidCertificate }
        let claims = try CapabilityCertificateVerifier.verify(certificate, publicKeyPEM: publicKeyPEM)
        guard claims.role == .owner, claims.farmID == farmID, claims.accountID == accountID, claims.deviceID == deviceID, claims.capabilities.contains(.manageMembers) else {
            throw CloudContractError.capabilityDenied
        }
        guard let device = try context.fetch(FetchDescriptor<DeviceIdentityRecord>()).first(where: { $0.id == deviceID && $0.accountID == accountID }) else {
            throw CloudContractError.invalidDeviceSignature
        }
        let signingData = Self.signingData(farmID: farmID, generation: generation, issuedAt: issuedAt, payloadDigest: digest, accountID: accountID, deviceID: deviceID)
        try DeviceSignatureVerifier.verify(signature: signature, data: signingData, publicKeyX963: device.publicKeyX963)
        let value = MembershipSnapshotRecordValue(id: UUID(), farmID: farmID, generation: generation, issuedAt: issuedAt, payload: payload, signedByAccountID: accountID, signedByDeviceID: deviceID, capabilityCertificate: certificate, signature: signature, cloudRecordName: record.recordID.recordName, validatedAt: .now)
        try await persistence.saveMembershipSnapshotRecord(value)
        return value
    }

    static func signingData(farmID: UUID, generation: Int, issuedAt: Date, payloadDigest: String, accountID: UUID, deviceID: UUID) -> Data {
        Data([
            farmID.uuidString.lowercased(),
            String(generation),
            CloudDateText.string(from: issuedAt),
            payloadDigest,
            accountID.uuidString.lowercased(),
            deviceID.uuidString.lowercased(),
        ].joined(separator: "\n").utf8)
    }

    private static func envelope(from snapshot: WorkerFarmSecuritySnapshot) -> FarmMembershipSnapshotEnvelope {
        FarmMembershipSnapshotEnvelope(
            farmID: snapshot.farmID,
            generation: snapshot.generation,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(snapshot.issuedAt)),
            members: snapshot.members.map { .init(membershipID: $0.membershipID, accountID: $0.accountID, role: $0.role, status: $0.status, shareParticipantRecordName: $0.shareParticipantRecordName) },
            devices: snapshot.devices.map { .init(deviceID: $0.deviceID, accountID: $0.accountID, publicKeyJWK: $0.publicKeyJWK) },
            revokedCertificates: snapshot.revokedCertificates.map { .init(certificateID: $0.certificateID, revokedAt: $0.revokedAt) }
        )
    }

    private static func integer(_ value: CKRecordValue?) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }
}

enum DeviceSignatureVerifier {
    static func verify(signature: Data, data: Data, publicKeyX963: Data) throws {
        let key = try P256.Signing.PublicKey(x963Representation: publicKeyX963)
        let value = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        guard key.isValidSignature(value, for: data) else { throw CloudContractError.invalidDeviceSignature }
    }
}

private extension JSONDecoder {
    static var membership: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
