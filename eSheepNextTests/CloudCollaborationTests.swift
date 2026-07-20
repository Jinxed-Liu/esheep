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

    func testOperationSecurityUsesCloudWriteTimeForMigratedHistory() throws {
        let privateKey = P256.Signing.PrivateKey()
        let historicalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cloudWriteDate = historicalDate.addingTimeInterval(86_400)
        let payload = Data("{}".utf8)
        var envelope = makeEnvelope(payload: payload, signature: Data(), modifiedAt: historicalDate)
        envelope = makeEnvelope(
            payload: payload,
            signature: try privateKey.signature(for: envelope.canonicalSigningData).rawRepresentation,
            modifiedAt: historicalDate
        )
        let claims = CapabilityCertificateClaims(
            certificateID: UUID().uuidString,
            accountID: envelope.modifiedByAccountID,
            farmID: envelope.farmID,
            deviceID: envelope.modifiedByDeviceID,
            role: .worker,
            capabilities: [.readFarm, .recordProduction],
            iat: Int(cloudWriteDate.timeIntervalSince1970) - 10,
            exp: Int(cloudWriteDate.timeIntervalSince1970) + 300,
            iss: "esheep-next-identity",
            aud: "esheep-next-cloud-operation"
        )

        XCTAssertNoThrow(try CloudOperationSecurity.validate(
            envelope: envelope,
            claims: claims,
            devicePublicKeyX963: privateKey.publicKey.x963Representation,
            authorizationDate: cloudWriteDate
        ))
    }

    func testExistingIdenticalCloudRecordIsIdempotentSuccess() throws {
        let mapper = CloudRecordMapper()
        let envelope = makeEnvelope(payload: Data("{\"value\":1}".utf8), signature: Data([1]))
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(envelope.farmID), ownerName: CKCurrentUserDefaultName)
        let client = mapper.operationRecord(from: envelope, zoneID: zoneID)
        let server = mapper.operationRecord(from: envelope, zoneID: zoneID)

        XCTAssertTrue(CloudRecordIdempotency.equivalent(client: client, server: server))
        server[CloudRecordField.payloadDigest] = "different" as CKRecordValue
        XCTAssertFalse(CloudRecordIdempotency.equivalent(client: client, server: server))
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

    func testCheckpointKeepsAndReplaysFullPedigreeOperationHistory() throws {
        let sourceContainer = try AppSchema.makeContainer(name: "checkpoint-source-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let source = ModelContext(sourceContainer)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "恢复测试")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "恢复测试牧场")
        source.insert(account); source.insert(farm); try source.save()
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner)
        let commands = FarmCommandService()
        try commands.execute(.addSheep(earTag: "E001", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: .now, birthAt: nil, note: ""), in: farmContext, context: source)
        try commands.execute(.addSheep(earTag: "BR001", breed: "杜泊", sex: .ram, penID: nil, occurredAt: .now, birthAt: nil, note: ""), in: farmContext, context: source)
        try commands.execute(.addSheep(earTag: "L001", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: .now, birthAt: nil, note: ""), in: farmContext, context: source)
        let sourceSheep = try source.fetch(FetchDescriptor<SheepRecord>())
        let dam = try XCTUnwrap(sourceSheep.first { $0.earTag == "E001" })
        let ram = try XCTUnwrap(sourceSheep.first { $0.earTag == "BR001" })
        let child = try XCTUnwrap(sourceSheep.first { $0.earTag == "L001" })
        try commands.execute(.care(.setBreedingRam(sheepID: ram.id, isBreedingRam: true, expectedRevision: ram.revision)), in: farmContext, context: source)
        try commands.execute(.care(.updateSheepPedigree(.init(sheepID: child.id, damID: dam.id, sireID: ram.id, semenDonorID: nil, reason: "恢复点系谱", expectedRevision: child.revision))), in: farmContext, context: source)

        let operations = try source.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farm.id && $0.entityID != nil }
        let snapshots = try FarmCheckpointOperationHistory.snapshots(operations: operations, farmID: farm.id, context: source)
        XCTAssertEqual(snapshots.filter { $0.entityID == child.id }.count, 2, "恢复点必须同时保留建档与后续系谱命令")
        XCTAssertEqual(snapshots.filter { $0.entityID == ram.id }.count, 2, "恢复点必须同时保留建档与种公羊资格命令")

        let checkpointID = UUID()
        let manifest = FarmCheckpointManifest(schemaVersion: 2, checkpointID: checkpointID, farmID: farm.id, createdAt: .now, operationWatermark: .now, securityGeneration: 1, entities: snapshots, tombstones: [], assets: [], entityCounts: [:], entityDigests: [:])
        let envelopes = FarmCheckpointOperationHistory.sourceEnvelopes(snapshots: snapshots, manifest: manifest, accountID: account.effectiveAccountID)
        let targetContainer = try AppSchema.makeContainer(name: "checkpoint-target-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let target = ModelContext(targetContainer)
        target.insert(FarmRecord(id: farm.id, ownerAccountID: account.effectiveAccountID, name: farm.name)); try target.save()
        for envelope in CloudRebuildActor.sortedOperations(envelopes) {
            guard case .conflict = try RemoteDomainApplyService().apply(envelope, context: target) else { continue }
            XCTFail("恢复点完整历史不应产生冲突：\(envelope.operationID)")
        }

        let restored = try target.fetch(FetchDescriptor<SheepRecord>())
        let restoredRam = try XCTUnwrap(restored.first { $0.id == ram.id })
        let restoredChild = try XCTUnwrap(restored.first { $0.id == child.id })
        XCTAssertTrue(restoredRam.isBreedingRam)
        XCTAssertEqual(restoredChild.damID, dam.id)
        XCTAssertEqual(restoredChild.sireID, ram.id)
        XCTAssertEqual(try target.fetch(FetchDescriptor<PedigreeChangeRecord>()).filter { $0.sheepID == child.id }.count, 1)

        let nestedRecovery = try envelopes.map {
            try wrapRecovery(
                wrapRecovery($0, checkpointID: checkpointID, level: 1),
                checkpointID: checkpointID,
                level: 2
            )
        }
        XCTAssertNoThrow(try CloudRebuildBundleValidator.validateReferences(operations: nestedRecovery, assets: []))
        let nestedContainer = try AppSchema.makeContainer(name: "checkpoint-nested-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let nestedTarget = ModelContext(nestedContainer)
        nestedTarget.insert(FarmRecord(id: farm.id, ownerAccountID: account.effectiveAccountID, name: farm.name)); try nestedTarget.save()
        for envelope in CloudRebuildActor.sortedOperations(Array(nestedRecovery.reversed())) {
            guard case .conflict = try RemoteDomainApplyService().apply(envelope, context: nestedTarget) else { continue }
            XCTFail("嵌套恢复操作不应产生冲突：\(envelope.operationID)")
        }
        let nestedSheep = try nestedTarget.fetch(FetchDescriptor<SheepRecord>())
        XCTAssertTrue(try XCTUnwrap(nestedSheep.first { $0.id == ram.id }).isBreedingRam)
        XCTAssertEqual(try XCTUnwrap(nestedSheep.first { $0.id == child.id }).sireID, ram.id)
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

    private func makeEnvelope(
        payload: Data,
        signature: Data,
        entityType: String = CloudEntityType.weight.rawValue,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> CloudOperationEnvelope {
        CloudOperationEnvelope(
            farmID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            entityID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            entityType: entityType,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            modifiedAt: modifiedAt,
            modifiedByAccountID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            modifiedByDeviceID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test-certificate",
            operationSignature: signature,
            deletedAt: nil
        )
    }

    private func wrapRecovery(_ source: CloudOperationEnvelope, checkpointID: UUID, level: Int) throws -> CloudOperationEnvelope {
        var payload = FarmCommandCloudPayload(kind: .recoverEntity)
        payload.identifiers = ["checkpointID": checkpointID, "entityID": source.entityID]
        payload.strings = ["entityType": source.entityType, "sourcePayloadDigest": source.payloadDigest]
        payload.integers = ["sourceRevision": source.revision]
        payload.dataValues = ["resolvedPayload": source.payload]
        let encoded = try JSONEncoder.cloud.encode(payload)
        return CloudOperationEnvelope(
            farmID: source.farmID,
            entityID: source.entityID,
            entityType: source.entityType,
            schemaVersion: 2,
            revision: source.revision + 1,
            baseRevision: source.revision,
            operationID: StableCloudUUID.derived(namespace: checkpointID, name: "nested-\(level)-\(source.operationID.uuidString.lowercased())"),
            modifiedAt: source.modifiedAt,
            modifiedByAccountID: source.modifiedByAccountID,
            modifiedByDeviceID: source.modifiedByDeviceID,
            payload: encoded,
            payloadDigest: CloudPayloadDigest.hex(for: encoded),
            capabilityCertificate: source.capabilityCertificate,
            operationSignature: source.operationSignature,
            deletedAt: source.deletedAt
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
