import CloudKit
import CryptoKit
import SwiftData
import UIKit
import XCTest
@testable import eSheepNext

@MainActor
final class CloudCollaborationTests: XCTestCase {
    func testCloudRecordMapperRoundTripsOperationEnvelope() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = Data("{\"value\":1}".utf8)
        let unsigned = makeEnvelope(payload: payload, signature: Data())
        let signature = try privateKey.signature(for: unsigned.canonicalSigningData).rawRepresentation
        let envelope = makeEnvelope(payload: payload, signature: signature)
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(envelope.farmID), ownerName: CKCurrentUserDefaultName)

        let mapper = CloudRecordMapper()
        let record = mapper.operationRecord(from: envelope, zoneID: zoneID)
        let decoded = try mapper.operationEnvelope(from: record)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(record.recordID.recordName, "op_\(envelope.operationID.uuidString.lowercased())")

        let entityRecord = mapper.entityRecord(from: envelope, zoneID: zoneID)
        XCTAssertEqual(try mapper.operationEnvelope(from: entityRecord), envelope)
        XCTAssertEqual(entityRecord.recordType, CloudRecordType.farmEntity.rawValue)
        XCTAssertEqual(entityRecord.recordID.recordName, "entity_\(envelope.entityID.uuidString.lowercased())")
    }

    func testZoneWideShareUsesSystemRecordName() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(UUID()), ownerName: CKCurrentUserDefaultName)
        let share = CKShare(recordZoneID: zoneID)
        XCTAssertEqual(share.recordID.zoneID, zoneID)
        XCTAssertEqual(share.recordID.recordName, CKRecordNameZoneWideShare)
        XCTAssertEqual(share.publicPermission, .none)
    }

    func testTombstoneRecordUsesStableEntityRecordName() throws {
        let farmID = UUID()
        let entityID = UUID()
        let operationID = UUID()
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        let envelope = FarmTombstoneEnvelope(
            tombstoneID: UUID(),
            farmID: farmID,
            entityType: CloudEntityType.note.rawValue,
            entityID: entityID,
            revision: 2,
            deletedAt: .now,
            deletedByAccountID: UUID(),
            reason: "测试删除",
            operationID: operationID,
            restoresTombstoneID: nil
        )
        let mapper = CloudRecordMapper()
        let record = mapper.tombstoneRecord(envelope: envelope, certificate: "certificate", signature: Data([1, 2, 3]), zoneID: zoneID)
        XCTAssertEqual(record.recordID.recordName, mapper.tombstoneRecordName(for: entityID))
        XCTAssertEqual(record[CloudRecordField.operationID] as? String, operationID.uuidString.lowercased())
        XCTAssertNotNil(record[CloudRecordField.payload] as? Data)
    }

    func testOperationSecurityRejectsRoleWithoutCatalogCapability() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = Data("{}".utf8)
        var envelope = makeEnvelope(payload: payload, signature: Data(), entityType: CloudEntityType.feedIngredient.rawValue)
        let signature = try privateKey.signature(for: envelope.canonicalSigningData).rawRepresentation
        envelope = makeEnvelope(payload: payload, signature: signature, entityType: CloudEntityType.feedIngredient.rawValue)
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: envelope.modifiedByAccountID,
            farmID: envelope.farmID,
            deviceID: envelope.modifiedByDeviceID,
            role: .worker,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(envelope.modifiedAt.timeIntervalSince1970) - 10,
            exp: Int(envelope.modifiedAt.timeIntervalSince1970) + 300,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )

        XCTAssertThrowsError(try CloudOperationSecurity.validate(envelope: envelope, claims: claims, devicePublicKeyX963: privateKey.publicKey.x963Representation)) { error in
            XCTAssertEqual(error as? CloudContractError, .capabilityDenied)
        }
    }

    func testOperationSecurityAcceptsMatchingSignedProductionOperation() throws {
        let privateKey = P256.Signing.PrivateKey()
        let payload = Data("{}".utf8)
        var envelope = makeEnvelope(payload: payload, signature: Data())
        envelope = makeEnvelope(payload: payload, signature: try privateKey.signature(for: envelope.canonicalSigningData).rawRepresentation)
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: envelope.modifiedByAccountID,
            farmID: envelope.farmID,
            deviceID: envelope.modifiedByDeviceID,
            role: .worker,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(envelope.modifiedAt.timeIntervalSince1970) - 10,
            exp: Int(envelope.modifiedAt.timeIntervalSince1970) + 300,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )

        XCTAssertNoThrow(try CloudOperationSecurity.validate(envelope: envelope, claims: claims, devicePublicKeyX963: privateKey.publicKey.x963Representation))
    }

    func testCommandPipelineStoresFullPayloadAndStableTarget() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()

        try FarmCommandService().execute(.createPen(name: "北一舍", note: "育肥"), in: FarmContext(accountID: accountID, farmID: farmID, role: .owner), context: context)

        let operation = try XCTUnwrap(context.fetch(FetchDescriptor<DomainOperation>()).first)
        let outbox = try XCTUnwrap(context.fetch(FetchDescriptor<OutboxItem>()).first)
        let pen = try XCTUnwrap(context.fetch(FetchDescriptor<PenRecord>()).first)
        let payload = try JSONDecoder.cloud.decode(FarmCommandCloudPayload.self, from: operation.payload)
        XCTAssertEqual(payload.strings["name"], "北一舍")
        XCTAssertEqual(operation.entityID, pen.id)
        XCTAssertEqual(operation.entityType, CloudEntityType.pen.rawValue)
        XCTAssertEqual(outbox.entityID, pen.id)
        XCTAssertEqual(outbox.payloadDigest, operation.payloadDigest)
    }

    func testRemoteApplyIsIdempotent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let targetID = UUID()
        let command = FarmCommand.createPen(name: "南一舍", note: "隔离")
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: targetID,
            entityType: CloudEntityType.pen.rawValue,
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

        let service = RemoteDomainApplyService()
        XCTAssertEqual(try service.apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try service.apply(envelope, context: context), .duplicate)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PenRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PenRecord>()).first?.id, targetID)
    }

    func testRemoteFarmLocationCommandUpdatesTheExistingFarm() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let farm = FarmRecord(id: farmID, ownerAccountID: UUID(), name: "云端位置测试场")
        context.insert(farm)
        try context.save()

        let command = FarmCommand.updateFarmLocation(
            displayName: "西山牧场",
            latitude: 40.010_125,
            longitude: 116.289_321,
            addressSnapshot: "北京市海淀区",
            timeZoneIdentifier: "Asia/Shanghai",
            source: .mapSearch,
            horizontalAccuracyMeters: nil
        )
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let modifiedAt = Date(timeIntervalSince1970: 1_741_000_000)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: farmID,
            entityType: CloudEntityType.farm.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
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

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(farm.locationSnapshot?.displayName, "西山牧场")
        XCTAssertEqual(farm.locationSnapshot?.latitude, 40.010_125)
        XCTAssertEqual(farm.locationSnapshot?.longitude, 116.289_321)
        XCTAssertEqual(farm.locationSnapshot?.source, .mapSearch)
        XCTAssertEqual(farm.locationUpdatedAt, modifiedAt)
    }

    func testRemoteBreedingProgramApplyIsIdempotentAndKeepsOrderedSteps() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let programID = UUID()
        let steps = [
            BreedingProgramStepDraft(id: UUID(), dayOffset: 0, action: "放栓"),
            BreedingProgramStepDraft(id: UUID(), dayOffset: 12, action: "撤栓并配种")
        ]
        let payload = try FarmCommandCloudPayloadEncoder.encode(
            .createBreedingProgram(name: "同期发情", createdAt: Date(timeIntervalSince1970: 1_741_000_000), steps: steps)
        )
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: programID,
            entityType: CloudEntityType.breedingProgram.rawValue,
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

        let service = RemoteDomainApplyService()
        XCTAssertEqual(try service.apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try service.apply(envelope, context: context), .duplicate)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BreedingProgramRecord>()).first?.id, programID)
        let storedSteps = try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(storedSteps.map(\.id), steps.map(\.id))
        XCTAssertEqual(storedSteps.map(\.action), ["放栓", "撤栓并配种"])
        XCTAssertTrue(storedSteps.allSatisfy { $0.programID == programID })
    }

    func testStableDerivedUUIDDoesNotChange() {
        let namespace = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(StableCloudUUID.derived(namespace: namespace, name: "inventory-receipt"), StableCloudUUID.derived(namespace: namespace, name: "inventory-receipt"))
        XCTAssertNotEqual(StableCloudUUID.derived(namespace: namespace, name: "inventory-receipt"), StableCloudUUID.derived(namespace: namespace, name: "inventory-consumption"))
    }

    func testRemoteDuplicateEarTagBecomesConflict() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        context.insert(SheepRecord(farmID: farmID, earTag: "A-100", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now))
        try context.save()
        let payload = try FarmCommandCloudPayloadEncoder.encode(.addSheep(earTag: " a-100 ", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: .now, birthAt: nil, note: ""))
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: UUID(),
            entityType: CloudEntityType.sheep.rawValue,
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
        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .conflict(localRevision: 0))
        XCTAssertEqual(try context.fetch(FetchDescriptor<SheepRecord>()).count, 1)
    }

    func testRecoveryOperationReplaysCheckpointPayload() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farmID = UUID()
        let entityID = UUID()
        let sourcePayload = try FarmCommandCloudPayloadEncoder.encode(.createPen(name: "恢复舍", note: "checkpoint"))
        var recoveryPayload = FarmCommandCloudPayload(kind: .recoverEntity)
        recoveryPayload.identifiers = ["checkpointID": UUID(), "entityID": entityID]
        recoveryPayload.strings = ["entityType": CloudEntityType.pen.rawValue, "sourcePayloadDigest": CloudPayloadDigest.hex(for: sourcePayload)]
        recoveryPayload.integers = ["sourceRevision": 1]
        recoveryPayload.dataValues = ["resolvedPayload": sourcePayload]
        let encoded = try JSONEncoder.cloud.encode(recoveryPayload)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: CloudEntityType.pen.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: encoded,
            payloadDigest: CloudPayloadDigest.hex(for: encoded),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .applied(rebuildHistoryFrom: nil))
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<PenRecord>()).first(where: { $0.id == entityID }))
        XCTAssertEqual(restored.name, "恢复舍")
    }

    func testPhotoOptimizationCapsLongestEdgeAndProducesVerifiableDigest() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1000))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        }
        let sourceURL = FileManager.default.temporaryDirectory.appending(path: "photo-source-\(UUID().uuidString).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let optimized = try PhotoTransferActor.optimize(sourceURL: sourceURL, farmID: UUID(), assetID: UUID())
        defer { try? FileManager.default.removeItem(at: optimized.fileURL) }
        XCTAssertEqual(max(optimized.cloudWidth, optimized.cloudHeight), 2560)
        XCTAssertGreaterThan(max(optimized.sourceWidth, optimized.sourceHeight), 2560)
        XCTAssertEqual(optimized.sourceWidth / optimized.sourceHeight, 3)
        XCTAssertFalse(optimized.sourceDigest.isEmpty)
        XCTAssertFalse(optimized.payloadDigest.isEmpty)
        XCTAssertGreaterThan(optimized.byteCount, 0)
    }

    func testCertificateIsValidatedAtOperationTimeNotDownloadTime() {
        let issued = Date(timeIntervalSince1970: 1_700_000_000)
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: UUID(),
            farmID: UUID(),
            deviceID: UUID(),
            role: .worker,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(issued.timeIntervalSince1970),
            exp: Int(issued.addingTimeInterval(604_800).timeIntervalSince1970),
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )
        XCTAssertTrue(claims.isValid(at: issued.addingTimeInterval(60)))
        XCTAssertFalse(claims.isValid(at: issued.addingTimeInterval(604_801)))
    }

    private func makeEnvelope(payload: Data, signature: Data, entityType: String = CloudEntityType.weight.rawValue) -> CloudOperationEnvelope {
        CloudOperationEnvelope(
            farmID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            entityID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            entityType: entityType,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedByAccountID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            modifiedByDeviceID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test-certificate",
            operationSignature: signature,
            deletedAt: nil
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            FarmRecord.self,
            PenRecord.self,
            SheepRecord.self,
            WeightRecord.self,
            WeaningRecord.self,
            BreedingProgramRecord.self,
            BreedingProgramStepRecord.self,
            TransferRecord.self,
            RemovalRecord.self,
            ProductionBatchRecord.self,
            BatchMembershipRecord.self,
            DailyPenCountRecord.self,
            FeedIngredientRecord.self,
            FeedRecipeRecord.self,
            FeedRecipeComponentRecord.self,
            FeedRecord.self,
            FeedRecordLine.self,
            InventoryLotRecord.self,
            InventoryTransactionRecord.self,
            HealthRecord.self,
            ReproductionRecord.self,
            SemenRecord.self,
            NoteRecord.self,
            DomainOperation.self,
            OutboxItem.self,
        ])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
}

private extension JSONDecoder {
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
