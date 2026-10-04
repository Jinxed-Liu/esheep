import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class ESheepCloudV2Tests: XCTestCase {
    func testBusinessBaselineHasClosedTypedCodecForEveryRestorationShape() throws {
        let id = UUID(), related = UUID(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let values: [ESheepCloudBusinessBaselineValueV2] = [
            .pen(id: id, isActive: false),
            .productionBatch(id: id, status: .completed, endedAt: date),
            .batchMembership(id: id, batchID: related, sheepID: UUID(), joinedAt: date, leftAt: nil, leaveReason: nil),
            .lambingOffspring(id: id, lambingRecordID: related, sheepID: nil, sexRawValue: "公死亡",
                isStillborn: true, autoCreatedSheep: false, autoBirthWeightRecordID: nil),
            .reproduction(id: id, eweID: related, kind: .abortion, occurredAt: date,
                batchID: nil, paternalSourceRawValue: "unknown", duplicateProjectionID: nil),
            .transfer(id: id, sheepID: related, occurredAt: date, fromPenID: nil, recordedAt: date)
        ]
        for value in values {
            let payload = ESheepCloudCommandPayloadV2.historyRepair(.restoreBusinessBaseline(
                .init(sourceDigest: String(repeating: "a", count: 64), projection: value)))
            XCTAssertEqual(payload.kind, "migration.restoreBusinessBaseline")
            let data = try ESheepCloudCanonicalCodec.encode(payload)
            XCTAssertEqual(try ESheepCloudCanonicalCodec.decode(ESheepCloudCommandPayloadV2.self, from: data), payload)
        }
    }

    func testBusinessBaselineRejectsForeignIdentityButPreservesConfirmedHistoricalIntervals() throws {
        let fixture = try makeFixture()
        let event = try makeProfileNoteEvent(fixture: fixture, note: "source-only fixture")
        let otherPen = PenRecord(farmID: UUID(), name: "Other farm")
        fixture.context.insert(otherPen)
        let sheep = SheepRecord(farmID: fixture.farmID, earTag: "guard", breed: "湖羊", sex: .ewe,
                                penID: nil, enteredAt: .distantPast)
        let joinedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let batch = ProductionBatchRecord(farmID: fixture.farmID, name: "guard", purpose: "育肥", startedAt: joinedAt)
        let membership = BatchMembershipRecord(farmID: fixture.farmID, batchID: batch.id, sheepID: sheep.id, joinedAt: joinedAt)
        fixture.context.insert(sheep); fixture.context.insert(batch); fixture.context.insert(membership)
        try fixture.context.save()
        let index = ESheepCloudProjectionReplayContext()
        func apply(_ value: ESheepCloudBusinessBaselineValueV2) throws {
            _ = try ESheepCloudBusinessBaselineProjection.apply(
                .init(sourceDigest: String(repeating: "a", count: 64), projection: value),
                event: event, context: fixture.context, index: index)
        }
        XCTAssertThrowsError(try apply(.pen(id: otherPen.id, isActive: false)))
        XCTAssertTrue(otherPen.isActive)
        XCTAssertThrowsError(try apply(.batchMembership(id: membership.id, batchID: batch.id, sheepID: sheep.id,
            joinedAt: joinedAt.addingTimeInterval(1), leftAt: joinedAt.addingTimeInterval(-1), leaveReason: "invalid identity")))
        XCTAssertNil(membership.leftAt); XCTAssertNil(membership.leaveReason)
        try apply(.batchMembership(id: membership.id, batchID: batch.id, sheepID: sheep.id,
            joinedAt: joinedAt, leftAt: joinedAt.addingTimeInterval(-1), leaveReason: "来源确认"))
        XCTAssertEqual(membership.leaveReason, "来源确认")
        XCTAssertEqual(membership.leftAt, joinedAt.addingTimeInterval(-1))
        XCTAssertEqual(index.historyRepairIndex.preloadCount, 1)
    }

    func testBusinessBaselineDoesNotDeduplicateByDateWithoutMatchingSourceIdentity() throws {
        let fixture = try makeFixture()
        let event = try makeProfileNoteEvent(fixture: fixture, note: "source-only fixture")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let ewe = SheepRecord(farmID: fixture.farmID, earTag: "guard", breed: "湖羊", sex: .ewe,
                              penID: nil, enteredAt: .distantPast)
        let original = ReproductionRecord(farmID: fixture.farmID, eweID: ewe.id, kind: .abortion, occurredAt: date)
        let unrelated = ReproductionRecord(farmID: fixture.farmID, eweID: UUID(), kind: .abortion, occurredAt: date)
        fixture.context.insert(ewe); fixture.context.insert(original); fixture.context.insert(unrelated)
        try fixture.context.save()
        XCTAssertThrowsError(try ESheepCloudBusinessBaselineProjection.apply(
            .init(sourceDigest: String(repeating: "a", count: 64), projection:
                .reproduction(id: original.id, eweID: ewe.id, kind: .abortion, occurredAt: date,
                    batchID: nil, paternalSourceRawValue: "unknown", duplicateProjectionID: unrelated.id)),
            event: event, context: fixture.context, index: ESheepCloudProjectionReplayContext()))
        XCTAssertNil(original.deletedAt); XCTAssertNil(unrelated.deletedAt)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<TombstoneRecord>()).isEmpty)
    }

    func testRealFarmForwardHistoryRepairMatchesEverySheepInIncrementalAndFreshReplay() async throws {
        let extended = URL(fileURLWithPath: "/tmp/esheep-cloud-v2-extended-acceptance")
        let hasExtended = FileManager.default.fileExists(atPath: extended.appending(path: "summary.json").path)
        let root = hasExtended ? extended : URL(fileURLWithPath: "/tmp/esheep-cloud-v2-baseline-acceptance")
        let expectedHead: Int64 = hasExtended ? 49_344 : 38_164
        guard FileManager.default.fileExists(atPath: root.appending(path: "tail.json").path) else {
            throw XCTSkip("Private owner-approved baseline fixture not installed")
        }
        let snapshotRoot = URL(fileURLWithPath: "/tmp/esheep-cloud-v2-repair-acceptance")
        let ticket = try ESheepCloudCanonicalCodec.decode(ESheepCloudInitialSyncTicketV2.self,
            from: Data(contentsOf: snapshotRoot.appending(path: "ticket.json")))
        let tail = try ESheepCloudSnapshotCodec.decode(Data(contentsOf: root.appending(path: "tail.json")),
            farmID: ticket.manifest.farmID, farmGeneration: 3).compactMap { record -> ESheepCloudEventEnvelopeV2? in
                if case .event(let event) = record { return event }; return nil
            }
        XCTAssertEqual(tail.count, Int(expectedHead - 34_842))
        XCTAssertEqual(tail.last?.eventSequence, expectedHead)
        let expected = try ESheepCloudCanonicalCodec.decode([ESheepCloudSheepBaselineRepairV2].self,
            from: Data(contentsOf: root.appending(path: "expected-sheep.json")))
        let run = root.appending(path: "run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = root.appending(path: "air.store\(suffix)")
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: run.appending(path: "air.store\(suffix)"))
            }
        }
        let incremental = try AppSchema.makeContainer(name: "AirRepair", url: run.appending(path: "air.store"))
        let context = ModelContext(incremental)
        context.autosaveEnabled = false
        let index = ESheepCloudProjectionReplayContext()
        try index.preload(in: context)
        let writer = RemoteDomainApplyService(replayAssumesEmptyBusinessStore: true, replayContext: index)
        try writer.prepareResumableReplay(farmID: ticket.manifest.farmID, context: context)
        let started = Date()
        for (offset, event) in tail.enumerated() {
            _ = try ESheepCloudEventReducer.apply(event, context: context, savesChanges: false,
                replayContext: index, domainApplyService: writer)
            if (offset + 1).isMultiple(of: 256) {
                index.registerInsertedModels(in: context)
                writer.rebuildPendingReplayIndex(in: context)
                try context.save()
            }
        }
        try FarmHistoryRebuilder().rebuild(farmID: ticket.manifest.farmID, context: context, from: .distantPast)
        try context.save()
        try assertRepairedSheep(incremental, expected: expected, farmID: ticket.manifest.farmID)
        if hasExtended {
            try assertRepairedBusiness(incremental, root: root)
            XCTAssertEqual(index.historyRepairIndex.preloadCount, 1)
        }
        // A duplicate delivery must leave both receipts and business state unchanged.
        for event in tail.suffix(10) {
            XCTAssertTrue(try ESheepCloudEventReducer.apply(event, context: context).wasAlreadyApplied)
        }
        let fresh = try AppSchema.makeContainer(name: "FreshBaseline-\(UUID())", isStoredInMemoryOnly: true)
        var chunks: [Int:Data] = [:]
        for chunk in ticket.manifest.chunks {
            chunks[chunk.index] = try Data(contentsOf: snapshotRoot.appending(path: String(format: "chunk-%05d.json", chunk.index)))
        }
        let gateway = InitialSyncGatewayStub(ticket: ticket, chunkDataByIndex: chunks, tailEvents: tail)
        let coordinator = ESheepCloudInitialSyncCoordinator(farmID: ticket.manifest.farmID,
            container: fresh, gateway: gateway, applicationSupportURL: run.appending(path: "fresh"))
        let report = try await coordinator.prepareNewInstallation(expectedFarmGeneration: 3,
            expectedAccountID: ticket.memberAccountID)
        XCTAssertEqual(report.appliedEventHead, expectedHead)
        try assertRepairedSheep(fresh, expected: expected, farmID: ticket.manifest.farmID)
        if hasExtended { try assertRepairedBusiness(fresh, root: root) }
        try JSONSerialization.data(withJSONObject: ["incrementalPassed":true,"freshPassed":true,
            "comparedSheep":expected.count,"businessProjectionPassed":hasExtended,"eventHead":expectedHead,"elapsedSeconds":Date().timeIntervalSince(started)],
            options:[.sortedKeys]).write(to:run.appending(path:"baseline-acceptance.json"))
    }

    private func assertRepairedSheep(_ container: ModelContainer,
                                    expected: [ESheepCloudSheepBaselineRepairV2], farmID: UUID) throws {
        let context = ModelContext(container)
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let byID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id,$0) })
        XCTAssertEqual(sheep.count, 3264)
        for value in expected {
            let actual = try XCTUnwrap(byID[value.sheepID])
            XCTAssertEqual(actual.status, value.status, actual.earTag)
            XCTAssertEqual(actual.currentPenID, value.currentPenID, actual.earTag)
            XCTAssertEqual(actual.purpose, value.purpose, actual.earTag)
            XCTAssertEqual(actual.damID, value.damID, actual.earTag)
            XCTAssertEqual(actual.sireID, value.sireID, actual.earTag)
            XCTAssertEqual(actual.damProvenance, value.damProvenance, actual.earTag)
            XCTAssertEqual(actual.sireProvenance, value.sireProvenance, actual.earTag)
            XCTAssertEqual(actual.isBreedingRam, value.isBreedingRam, actual.earTag)
            XCTAssertEqual(actual.legacyEarTag, value.legacyEarTag, actual.earTag)
            XCTAssertEqual(actual.legacySourceKey, value.legacySourceKey, actual.earTag)
            XCTAssertEqual(actual.legacyStatusSnapshotIsAuthoritative == true, value.legacyStatusSnapshotIsAuthoritative, actual.earTag)
            XCTAssertEqual(actual.legacyPenSnapshotIsAuthoritative == true, value.legacyPenSnapshotIsAuthoritative, actual.earTag)
        }
        XCTAssertEqual(sheep.filter(\.isCurrentlyPresent).count, 560)
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
        XCTAssertEqual(CurrentFarmOccupancy.occupiedPens(farmID: farmID, sheep: sheep, pens: pens).count, 19)
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.deletedAt == nil }
        XCTAssertEqual(removals.count, 2163)
        let deadIDs = Set(sheep.filter { ["8115","8116","8117","8118","8119","8120","8121","8122"].contains($0.earTag) }.map(\.id))
        XCTAssertEqual(deadIDs.count, 8)
        XCTAssertEqual(removals.filter { deadIDs.contains($0.sheepID) && $0.kind == .deceased }.count, 8)
    }

    func testFieldStreamDigestPreservesAuthorityIdentifierSpelling() throws {
        let fixture = try makeFixture()
        let identifier = UUID(uuidString: "55c73a5f-0717-41b5-a56c-3e84a6c1cacd")!
        let value = ESheepCloudValueV2.identifier(identifier)
        for spelling in [identifier.uuidString.lowercased(), identifier.uuidString] {
            let rawValue = "{\"type\":\"identifier\",\"value\":\"\(spelling)\"}"
            let body = "{\"changes\":[{\"field\":\"avatar\",\"value\":\(rawValue)}]}"
            let event = ESheepCloudEventEnvelopeV2(
                protocolVersion: 2, schemaVersion: 1,
                farmID: fixture.farmID, farmGeneration: fixture.generation,
                eventSequence: 1, eventID: UUID(), commandID: UUID(),
                sourceCommandDigest: String(repeating: "a", count: 64),
                stream: .init(type: "sheepAvatar", id: fixture.sharedSheepID),
                payload: .fieldsPatched(
                    stream: .init(type: "sheepAvatar", id: fixture.sharedSheepID),
                    changes: [.init(field: "avatar", value: value, valueDigest: value.digest, fieldVersion: 1)]
                ),
                affectedFields: ["avatar"],
                eventBodyDigest: ESheepCloudEventBodyIntegrityV2.digest(canonicalJSON: body),
                beforeDigest: String(repeating: "0", count: 64),
                afterDigest: String(repeating: "0", count: 64),
                actorAccountID: fixture.accountID, sourceDeviceID: fixture.deviceID,
                sourceDeviceSequence: 1, occurredAt: .now, receivedAt: .now,
                eventDigest: "", eventBodyCanonical: body
            )
            let actual = try ESheepCloudEventReducer.canonicalFieldStateData(
                previous: Data("{}".utf8), updates: ["avatar": value], event: event
            )
            XCTAssertEqual(String(decoding: actual, as: UTF8.self), "{\"avatar\":\(rawValue)}")
            XCTAssertThrowsError(try ESheepCloudEventReducer.canonicalFieldStateData(
                previous: Data("{}".utf8), updates: ["avatar": .identifier(UUID())], event: event
            ))
        }
    }

    func testV2RemovalReplayReleasesRestoredLegacySnapshotButBaselinePreservesIt() throws {
        for isBaseline in [true, false] {
            let fixture = try makeFixture()
            let entry = Date(timeIntervalSince1970: 1_700_000_000)
            let removalDate = entry.addingTimeInterval(86_400)
            let pen = PenRecord(farmID: fixture.farmID, name: "恢复圈舍")
            let sheep = SheepRecord(farmID: fixture.farmID, earTag: "RESTORED-LAMB",
                breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: entry)
            sheep.legacyStatusSnapshotIsAuthoritative = true
            sheep.legacyPenSnapshotIsAuthoritative = true
            fixture.context.insert(pen)
            fixture.context.insert(sheep)
            try fixture.context.save()
            let removalID = UUID()
            let payload = try FarmCommandCloudPayloadEncoder.encode(.removeSheep(
                sheepID: sheep.id, kind: .sold, reason: "已出售", amountText: nil,
                occurredAt: removalDate, note: "", recordID: removalID
            ))
            let envelope = CloudOperationEnvelope(
                farmID: fixture.farmID, entityID: removalID,
                entityType: CloudEntityType.removal.rawValue, schemaVersion: 2,
                revision: 1, baseRevision: 0, operationID: UUID(),
                modifiedAt: removalDate, modifiedByAccountID: fixture.accountID,
                modifiedByDeviceID: fixture.deviceID, payload: payload,
                payloadDigest: CloudPayloadDigest.hex(for: payload),
                capabilityCertificate: "esheep-cloud-v2-event",
                operationSignature: Data(), deletedAt: nil
            )
            let writer = RemoteDomainApplyService()
            if isBaseline {
                _ = try writer.applyBaselineProjection(envelope, context: fixture.context)
            } else {
                _ = try writer.applyV2(envelope, context: fixture.context)
            }
            try FarmHistoryRebuilder().rebuild(farmID: fixture.farmID,
                context: fixture.context, from: entry, through: removalDate)
            try fixture.context.save()
            XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<RemovalRecord>()).count, 1)
            XCTAssertEqual(sheep.legacyStatusSnapshotIsAuthoritative, isBaseline)
            XCTAssertEqual(sheep.legacyPenSnapshotIsAuthoritative, isBaseline)
            XCTAssertEqual(sheep.status, isBaseline ? .active : .removed)
            XCTAssertEqual(sheep.isCurrentlyPresent, isBaseline)
            XCTAssertEqual(sheep.currentPenID, isBaseline ? pen.id : nil)
            XCTAssertEqual(sheep.removedAt, isBaseline ? nil : removalDate)
        }
    }

    func testAuthoritativeCareReplayUsesEventOrderButKeepsBusinessValidation() throws {
        let fixture = try makeFixture()
        let sheep = SheepRecord(
            farmID: fixture.farmID, earTag: "V2-CARE-REVISION",
            breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now
        )
        sheep.revision = 7
        fixture.context.insert(sheep)
        try fixture.context.save()
        func envelope(_ care: CareCommand) throws -> CloudOperationEnvelope {
            let data = try FarmCommandCloudPayloadEncoder.encode(.care(care))
            return .init(
                farmID: fixture.farmID, entityID: sheep.id,
                entityType: CloudEntityType.sheep.rawValue, schemaVersion: 2,
                revision: 1, baseRevision: 0, operationID: UUID(),
                modifiedAt: .now, modifiedByAccountID: fixture.accountID,
                modifiedByDeviceID: fixture.deviceID, payload: data,
                payloadDigest: CloudPayloadDigest.hex(for: data),
                capabilityCertificate: "esheep-cloud-v2-event",
                operationSignature: Data(), deletedAt: nil
            )
        }
        let purpose = try envelope(.setSheepPurpose(
            sheepID: sheep.id, purpose: .fattening,
            reason: "历史用途回放", expectedRevision: 1
        ))
        let writer = RemoteDomainApplyService(replayAssumesEmptyBusinessStore: true)
        try writer.prepareResumableReplay(farmID: fixture.farmID, context: fixture.context)
        XCTAssertThrowsError(try writer.apply(purpose, context: fixture.context)) {
            guard case FarmCommandError.pedigreeRevisionConflict = $0 else {
                return XCTFail("Expected V1 revision conflict, got \($0)")
            }
        }
        _ = try writer.applyV2(purpose, context: fixture.context)
        XCTAssertEqual(sheep.purpose, SheepPurpose.fattening.rawValue)
        XCTAssertEqual(sheep.revision, 8)
        let invalid = try envelope(.setBreedingRam(
            sheepID: sheep.id, isBreedingRam: true, expectedRevision: 1
        ))
        XCTAssertThrowsError(try writer.applyV2(invalid, context: fixture.context)) {
            guard case FarmCommandError.reproductionSireMustBeRam = $0 else {
                return XCTFail("Expected sex validation failure, got \($0)")
            }
        }
        XCTAssertFalse(sheep.isBreedingRam)
        XCTAssertEqual(sheep.revision, 8)
    }

    /// Opt-in acceptance against the complete, privately exported farm. The
    /// fixture is never checked into Git and cannot access the live gateway.
    func testRealFarmRepairSnapshotVerifiesAndActivatesFromEmptyStore() async throws {
        let root = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["ESHEEP_V2_REPLAY_FIXTURE"]
                ?? "/tmp/esheep-cloud-v2-repair-acceptance")
        guard FileManager.default.fileExists(atPath: root.appending(path: "ticket.json").path) else {
            throw XCTSkip("Set ESHEEP_V2_REPLAY_FIXTURE to a private full-scale repair fixture")
        }
        let ticket = try ESheepCloudCanonicalCodec.decode(
            ESheepCloudInitialSyncTicketV2.self,
            from: Data(contentsOf: root.appending(path: "ticket.json"))
        )
        XCTAssertEqual(ticket.manifest.boundaryEventSequence, 34_842)
        XCTAssertEqual(ticket.manifest.chunks.count, 128)
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudRealRepair-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        var chunks: [Int: Data] = [:]
        for chunk in ticket.manifest.chunks {
            chunks[chunk.index] = try Data(contentsOf: root.appending(
                path: String(format: "chunk-%05d.json", chunk.index)
            ))
        }
        let gateway = InitialSyncGatewayStub(ticket: ticket, chunkDataByIndex: chunks)
        let runRoot = root.appending(path: "run-\(UUID().uuidString)")
        let coordinator = ESheepCloudInitialSyncCoordinator(
            farmID: ticket.manifest.farmID, container: container,
            gateway: gateway, applicationSupportURL: runRoot
        )
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FarmRecord>()), 0)
        let started = Date()
        let report = try await coordinator.prepareNewInstallation(
            expectedFarmGeneration: ticket.manifest.farmGeneration,
            expectedAccountID: ticket.memberAccountID
        )
        let verify = ModelContext(container)
        XCTAssertEqual(report.appliedEventHead, 34_842)
        XCTAssertEqual(report.streamCount, 28_954)
        XCTAssertEqual(report.assetCount, 27)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<FarmRecord>()), 1)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()), 34_842)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<FeedRecord>()), 1_208)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<FeedIngredientBatchRecord>()), 0)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<FeedStockTransactionRecord>()), 0)
        let session = try XCTUnwrap(verify.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>()).first)
        XCTAssertEqual(session.state, .active)
        XCTAssertNotNil(session.activatedAt)
        let evidence: [String: Any] = [
            "snapshotID": ticket.manifest.snapshotID.uuidString,
            "generation": ticket.manifest.farmGeneration,
            "eventHead": report.appliedEventHead,
            "streamCount": report.streamCount,
            "assetCount": report.assetCount,
            "elapsedSeconds": Date().timeIntervalSince(started),
            "activated": session.state == .active,
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: runRoot.appending(path: "acceptance.json"), options: .atomic)
    }

    func testInfrastructureBase64DecoderAcceptsPostgreSQLLineWrapping() {
        let expected = Data(repeating: 0xAB, count: 128)
        let wrapped = expected.base64EncodedString(options: [
            .lineLength64Characters,
            .endLineWithLineFeed,
        ])

        XCTAssertTrue(wrapped.contains("\n"))
        XCTAssertEqual(
            ESheepCloudInfrastructureGateway.decodeLineWrappedBase64(wrapped),
            expected
        )
        XCTAssertNil(
            ESheepCloudInfrastructureGateway.decodeLineWrappedBase64(wrapped + "!")
        )
    }

    func testBusinessReplayErrorsDoNotQuarantineVerifiedCheckpoint() {
        XCTAssertFalse(
            ESheepCloudInitialSyncCoordinator.shouldQuarantineVerificationStore(
                for: FarmCommandError.feedIngredientBatchNotFound
            )
        )
        XCTAssertFalse(
            ESheepCloudInitialSyncCoordinator.shouldQuarantineVerificationStore(
                for: RemoteDomainApplyError.missingReference("ingredientBatchID")
            )
        )
        XCTAssertTrue(
            ESheepCloudInitialSyncCoordinator.shouldQuarantineVerificationStore(
                for: ESheepCloudInitialSyncError.verificationStoreIntegrity("quick_check")
            )
        )
        XCTAssertTrue(
            ESheepCloudInitialSyncCoordinator.shouldQuarantineVerificationStore(
                for: ESheepCloudInitialSyncError.existingVerificationCheckpointMismatch
            )
        )
    }

    func testInitialSyncUsesImmutableServerFarmIdentityAndActivatesAtomically() async throws {
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudInitialSyncTests-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let farmID = UUID()
        let ownerAccountID = UUID()
        let memberAccountID = UUID()
        let generation = 4
        let profile = ESheepCloudFarmProfileV2(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            name: "云端权威牧场",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            locationDisplayName: "呼和浩特",
            latitude: 40.842,
            longitude: 111.749,
            coordinateReferenceSystem: "wgs84",
            addressSnapshot: nil,
            timeZoneIdentifier: "Asia/Shanghai",
            locationSourceRawValue: "legacyMigration",
            horizontalAccuracyMeters: 12,
            locationUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let profileData = try ESheepCloudCanonicalCodec.encode(profile)
        let profileDigest = SHA256.hash(data: profileData)
            .map { String(format: "%02x", $0) }
            .joined()
        let totalDigest = SHA256.hash(data: Data(profileDigest.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = ESheepCloudSnapshotManifestV2(
            snapshotID: UUID(),
            farmID: farmID,
            farmGeneration: generation,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            boundaryEventSequence: 0,
            eventHeadAtCreation: 0,
            recordCounts: [
                .init(recordType: "streams", count: 0),
                .init(recordType: "events", count: 0),
                .init(recordType: "assets", count: 0),
            ],
            chunks: [],
            businessHistoryStartedAt: nil,
            businessHistoryEndedAt: nil,
            relationshipDigest: String(repeating: "0", count: 64),
            fieldVersionDigest: try ESheepCloudCanonicalCodec.digest(
                [[String: Int]]()
            ),
            farmProfileDigest: profileDigest,
            assets: [],
            totalDigest: totalDigest,
            createdAt: .now
        )
        let gateway = InitialSyncGatewayStub(ticket: .init(
            manifest: manifest,
            farmProfile: profile,
            memberAccountID: memberAccountID,
            memberRole: .worker,
            membershipStatus: "active",
            expiresAt: .now.addingTimeInterval(1_800)
        ))
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ESheepCloudInitialSync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let coordinator = ESheepCloudInitialSyncCoordinator(
            farmID: farmID,
            container: container,
            gateway: gateway,
            applicationSupportURL: temporaryRoot
        )

        let report = try await coordinator.prepareNewInstallation(
            expectedFarmGeneration: generation
        )

        XCTAssertEqual(report.appliedEventHead, 0)
        let context = ModelContext(container)
        let farm = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmRecord>())
                .first(where: { $0.id == farmID })
        )
        XCTAssertEqual(farm.ownerAccountID, ownerAccountID)
        XCTAssertEqual(farm.name, "云端权威牧场")
        XCTAssertEqual(farm.role, .worker)
        let storage = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmStorageProfile>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(storage.mode, .eSheepCloud)
        XCTAssertEqual(storage.authorityGeneration, generation)
        let binding = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(binding.provider, .eSheepCloud)
        XCTAssertEqual(binding.state, .active)
        let membership = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmMembershipBinding>())
                .first(where: {
                    $0.farmID == farmID && $0.accountID == memberAccountID
                })
        )
        XCTAssertEqual(membership.role, .worker)
        XCTAssertEqual(membership.status, .active)
        let session = try XCTUnwrap(
            context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.targetEventHead, report.appliedEventHead)
        XCTAssertNotNil(session.activatedAt)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<OutboxItem>()),
            0
        )
    }

    func testInitialSyncChunkFailureMarksSessionFailedWithoutTouchingActiveStore() async throws {
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudInitialSyncFailureTests-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let farmID = UUID()
        let ownerAccountID = UUID()
        let memberAccountID = UUID()
        let profile = ESheepCloudFarmProfileV2(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            name: "校验失败牧场",
            createdAt: .now,
            updatedAt: .now,
            locationDisplayName: nil,
            latitude: nil,
            longitude: nil,
            coordinateReferenceSystem: "wgs84",
            addressSnapshot: nil,
            timeZoneIdentifier: "Asia/Shanghai",
            locationSourceRawValue: nil,
            horizontalAccuracyMeters: nil,
            locationUpdatedAt: nil
        )
        let profileDigest = try ESheepCloudCanonicalCodec.digest(profile)
        let expectedChunk = Data("GOOD".utf8)
        let chunkDigest = SHA256.hash(data: expectedChunk)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = ESheepCloudSnapshotManifestV2(
            snapshotID: UUID(),
            farmID: farmID,
            farmGeneration: 1,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            boundaryEventSequence: 0,
            eventHeadAtCreation: 0,
            recordCounts: [
                .init(recordType: "streams", count: 0),
                .init(recordType: "events", count: 0),
                .init(recordType: "assets", count: 0),
            ],
            chunks: [
                .init(index: 0, byteCount: Int64(expectedChunk.count), contentSHA256: chunkDigest),
            ],
            businessHistoryStartedAt: nil,
            businessHistoryEndedAt: nil,
            relationshipDigest: String(repeating: "0", count: 64),
            fieldVersionDigest: try ESheepCloudCanonicalCodec.digest([[String: Int]]()),
            farmProfileDigest: profileDigest,
            assets: [],
            totalDigest: SHA256.hash(data: Data((profileDigest + chunkDigest).utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            createdAt: .now
        )
        let gateway = InitialSyncGatewayStub(
            ticket: .init(
                manifest: manifest,
                farmProfile: profile,
                memberAccountID: memberAccountID,
                memberRole: .worker,
                membershipStatus: "active",
                expiresAt: .now.addingTimeInterval(1_800)
            ),
            chunkDataByIndex: [0: Data("BADD".utf8)]
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "ESheepCloudInitialSyncFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let coordinator = ESheepCloudInitialSyncCoordinator(
            farmID: farmID,
            container: container,
            gateway: gateway,
            applicationSupportURL: temporaryRoot
        )

        do {
            _ = try await coordinator.prepareNewInstallation(expectedFarmGeneration: 1)
            XCTFail("corrupt snapshot chunk must fail closed")
        } catch {
            XCTAssertTrue(error is ESheepCloudInitialSyncError)
        }

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FarmRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ESheepCloudFarmState>()), 0)
        let session = try XCTUnwrap(
            context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(session.retryCount, 1)
        XCTAssertNotNil(session.lastErrorTraceID)
        XCTAssertEqual(try ESheepCloudCanonicalCodec.decode([Int].self, from: session.verifiedChunkIndexesData), [])
    }

    func testInitialSyncCancellationPausesSessionForResumingVerifiedChunks() async throws {
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudInitialSyncPausedTests-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let farmID = UUID()
        let ownerAccountID = UUID()
        let memberAccountID = UUID()
        let profile = ESheepCloudFarmProfileV2(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            name: "可恢复接收牧场",
            createdAt: .now,
            updatedAt: .now,
            locationDisplayName: nil,
            latitude: nil,
            longitude: nil,
            coordinateReferenceSystem: "wgs84",
            addressSnapshot: nil,
            timeZoneIdentifier: "Asia/Shanghai",
            locationSourceRawValue: nil,
            horizontalAccuracyMeters: nil,
            locationUpdatedAt: nil
        )
        let profileDigest = try ESheepCloudCanonicalCodec.digest(profile)
        let chunkData = Data("PAUSE".utf8)
        let chunkDigest = SHA256.hash(data: chunkData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = ESheepCloudSnapshotManifestV2(
            snapshotID: UUID(),
            farmID: farmID,
            farmGeneration: 1,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            boundaryEventSequence: 0,
            eventHeadAtCreation: 0,
            recordCounts: [
                .init(recordType: "streams", count: 0),
                .init(recordType: "events", count: 0),
                .init(recordType: "assets", count: 0),
            ],
            chunks: [
                .init(
                    index: 0,
                    byteCount: Int64(chunkData.count),
                    contentSHA256: chunkDigest
                ),
            ],
            businessHistoryStartedAt: nil,
            businessHistoryEndedAt: nil,
            relationshipDigest: String(repeating: "0", count: 64),
            fieldVersionDigest: try ESheepCloudCanonicalCodec.digest([[String: Int]]()),
            farmProfileDigest: profileDigest,
            assets: [],
            totalDigest: SHA256.hash(data: Data((profileDigest + chunkDigest).utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            createdAt: .now
        )
        let gateway = InitialSyncGatewayStub(
            ticket: .init(
                manifest: manifest,
                farmProfile: profile,
                memberAccountID: memberAccountID,
                memberRole: .worker,
                membershipStatus: "active",
                expiresAt: .now.addingTimeInterval(1_800)
            ),
            chunkDataByIndex: [0: chunkData],
            cancelChunkIndices: [0]
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ESheepCloudInitialSyncPaused-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let coordinator = ESheepCloudInitialSyncCoordinator(
            farmID: farmID,
            container: container,
            gateway: gateway,
            applicationSupportURL: temporaryRoot
        )

        do {
            _ = try await coordinator.prepareNewInstallation(expectedFarmGeneration: 1)
            XCTFail("a cancelled receive must remain resumable")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FarmRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ESheepCloudFarmState>()), 0)
        let session = try XCTUnwrap(
            context.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.retryCount, 0)
        XCTAssertNil(session.lastErrorTraceID)
        XCTAssertEqual(
            try ESheepCloudCanonicalCodec.decode([Int].self, from: session.verifiedChunkIndexesData),
            []
        )
    }

    func testNewInstallationReplaysDeletedBatchAndMembershipBeforeActivation() async throws {
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudDeletedBatchFreshInstall-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let farmID = UUID()
        let ownerAccountID = UUID()
        let memberAccountID = UUID()
        let deviceID = UUID()
        let generation = 8
        let profile = ESheepCloudFarmProfileV2(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            name: "批次删除首次同步测试场",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            locationDisplayName: nil,
            latitude: nil,
            longitude: nil,
            coordinateReferenceSystem: "wgs84",
            addressSnapshot: nil,
            timeZoneIdentifier: "Asia/Shanghai",
            locationSourceRawValue: nil,
            horizontalAccuracyMeters: nil,
            locationUpdatedAt: nil
        )
        let profileDigest = try ESheepCloudCanonicalCodec.digest(profile)
        let totalDigest = SHA256.hash(data: Data(profileDigest.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = ESheepCloudSnapshotManifestV2(
            snapshotID: UUID(),
            farmID: farmID,
            farmGeneration: generation,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            boundaryEventSequence: 0,
            eventHeadAtCreation: 0,
            recordCounts: [
                .init(recordType: "streams", count: 0),
                .init(recordType: "events", count: 0),
                .init(recordType: "assets", count: 0),
            ],
            chunks: [],
            businessHistoryStartedAt: nil,
            businessHistoryEndedAt: nil,
            relationshipDigest: String(repeating: "0", count: 64),
            fieldVersionDigest: try ESheepCloudCanonicalCodec.digest([[String: Int]]()),
            farmProfileDigest: profileDigest,
            assets: [],
            totalDigest: totalDigest,
            createdAt: .now
        )

        let sheepID = UUID()
        let batchID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var streamProgress: [ESheepCloudStreamReferenceV2: (count: Int64, digest: String)] = [:]
        let emptyStreamDigest = try ESheepCloudCanonicalCodec.digest(
            [String: ESheepCloudValueV2]()
        )
        func makeEvent(
            _ command: FarmCommand,
            entityType: CloudEntityType,
            entityID: UUID,
            sequence: Int64
        ) throws -> ESheepCloudEventEnvelopeV2 {
            let draft = try ESheepCloudCommandFactoryV2.make(
                command: command,
                farmID: farmID,
                primaryEntityType: entityType.rawValue,
                primaryEntityID: entityID
            )
            let stream = try XCTUnwrap(draft.affectedStreams.first)
            let previous = streamProgress[stream]
            let commandID = UUID()
            let eventID = UUID()
            let sourceDigest = try ESheepCloudCanonicalCodec.digest(draft.payload)
            let eventCount = (previous?.count ?? 0) + 1
            let beforeDigest = previous?.digest ?? emptyStreamDigest
            let afterDigest = try ESheepCloudCanonicalCodec.digest(
                ESheepCloudNonFieldStreamStateV2(
                    eventCount: eventCount,
                    lastCommandDigest: sourceDigest,
                    lastCommandID: commandID.uuidString.lowercased(),
                    lastCommandKind: draft.kind
                )
            )
            let receivedAt = draft.occurredAt.addingTimeInterval(1)
            func envelope(digest: String) -> ESheepCloudEventEnvelopeV2 {
                ESheepCloudEventEnvelopeV2(
                    protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                    schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                    farmID: farmID,
                    farmGeneration: generation,
                    eventSequence: sequence,
                    eventID: eventID,
                    commandID: commandID,
                    sourceCommandDigest: sourceDigest,
                    stream: stream,
                    payload: .businessCommandApplied(
                        commandKind: draft.kind,
                        payload: draft.payload
                    ),
                    affectedFields: draft.affectedFieldKeys,
                    eventBodyDigest: String(repeating: "d", count: 64),
                    beforeDigest: beforeDigest,
                    afterDigest: afterDigest,
                    actorAccountID: memberAccountID,
                    sourceDeviceID: deviceID,
                    sourceDeviceSequence: sequence,
                    occurredAt: draft.occurredAt,
                    receivedAt: receivedAt,
                    eventDigest: digest
                )
            }
            let unsigned = envelope(digest: "")
            let signed = envelope(digest: ESheepCloudEventDigestV2.hex(for: unsigned))
            streamProgress[stream] = (eventCount, afterDigest)
            return signed
        }

        let commands: [(FarmCommand, CloudEntityType, UUID)] = [
            (.addSheep(
                earTag: "SYNC-DELETE-1",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                occurredAt: startedAt.addingTimeInterval(-86_400),
                birthAt: nil,
                note: "首次安装同步样本"
            ), .sheep, sheepID),
            (.createBatch(
                name: "已删除批次",
                purpose: "育肥",
                startedAt: startedAt,
                sheepIDs: [sheepID],
                note: "首次安装同步样本"
            ), .productionBatch, batchID),
        ]
        var events: [ESheepCloudEventEnvelopeV2] = []
        for (offset, value) in commands.enumerated() {
            events.append(try makeEvent(value.0, entityType: value.1, entityID: value.2, sequence: Int64(offset + 1)))
        }
        let membershipID = StableCloudUUID.derived(
            namespace: batchID,
            name: "batch-member-\(sheepID.uuidString.lowercased())"
        )
        events.append(try makeEvent(
            .tombstoneEntity(entityType: .batchMembership, entityID: membershipID, reason: "删除批次"),
            entityType: .batchMembership,
            entityID: membershipID,
            sequence: 3
        ))
        events.append(try makeEvent(
            .tombstoneEntity(entityType: .productionBatch, entityID: batchID, reason: "删除批次"),
            entityType: .productionBatch,
            entityID: batchID,
            sequence: 4
        ))

        let checkpointSourceContainer = try AppSchema.makeContainer(
            name: "ESheepCloudDeletedBatchCheckpointSource-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let checkpointSourceContext = ModelContext(checkpointSourceContainer)
        checkpointSourceContext.insert(FarmRecord(
            id: farmID,
            ownerAccountID: ownerAccountID,
            name: profile.name
        ))
        let checkpointSourceState = ESheepCloudFarmState(
            farmID: farmID,
            farmGeneration: generation,
            activityState: .active
        )
        checkpointSourceState.integrityState = .passed
        checkpointSourceContext.insert(checkpointSourceState)
        _ = try ESheepCloudEventReducer.apply(events[0], context: checkpointSourceContext)
        let checkpointArchiveDirectory = FileManager.default.temporaryDirectory
            .appending(path: "ESheepCloudDeletedBatchCheckpoint-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: checkpointArchiveDirectory) }
        let checkpointManifest = try ESheepCloudCheckpointArchive.export(
            farmID: farmID,
            context: checkpointSourceContext,
            directory: checkpointArchiveDirectory
        )
        XCTAssertEqual(checkpointManifest.boundaryEventSequence, 1)
        let checkpointChunkDataByIndex = try Dictionary(uniqueKeysWithValues: checkpointManifest.chunks.map { chunk in
            let name = String(format: "%05d.json.gz", chunk.index)
            return (chunk.index, try Data(contentsOf: checkpointArchiveDirectory.appending(path: name)))
        })

        let gateway = InitialSyncGatewayStub(
            ticket: .init(
                manifest: manifest,
                farmProfile: profile,
                memberAccountID: memberAccountID,
                memberRole: .administrator,
                membershipStatus: "active",
                expiresAt: .now.addingTimeInterval(1_800)
            ),
            tailEvents: Array(events.dropFirst()),
            checkpointManifest: checkpointManifest,
            checkpointChunkDataByIndex: checkpointChunkDataByIndex
        )
        let support = FileManager.default.temporaryDirectory
            .appending(path: "ESheepCloudDeletedBatchFreshInstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let coordinator = ESheepCloudInitialSyncCoordinator(
            farmID: farmID,
            container: container,
            gateway: gateway,
            applicationSupportURL: support
        )

        let report = try await coordinator.prepareNewInstallation(
            expectedFarmGeneration: generation,
            expectedAccountID: memberAccountID
        )

        XCTAssertEqual(report.snapshotID, checkpointManifest.checkpointID)
        XCTAssertEqual(report.appliedEventHead, 4)
        let context = ModelContext(container)
        let farm = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmRecord>()).first { $0.id == farmID })
        XCTAssertEqual(farm.role, .administrator)
        let sheep = try XCTUnwrap(try context.fetch(FetchDescriptor<SheepRecord>()).first { $0.id == sheepID })
        XCTAssertNil(sheep.deletedAt)
        XCTAssertTrue(sheep.isCurrentlyPresent)
        let batch = try XCTUnwrap(try context.fetch(FetchDescriptor<ProductionBatchRecord>()).first { $0.id == batchID })
        let membership = try XCTUnwrap(try context.fetch(FetchDescriptor<BatchMembershipRecord>()).first { $0.id == membershipID })
        XCTAssertNotNil(batch.deletedAt)
        XCTAssertNotNil(membership.deletedAt)
        XCTAssertTrue(ProductionBatchVisibility.userManaged(farmID: farmID, batches: [batch]).isEmpty)
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>()).filter {
            $0.farmID == farmID && ($0.entityID == batchID || $0.entityID == membershipID)
        }
        XCTAssertEqual(Set(tombstones.map(\.entityID)), Set([batchID, membershipID]))
        let farmState = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first { $0.farmID == farmID }
        )
        XCTAssertEqual(farmState.lastAppliedEventSequence, 4)
        XCTAssertEqual(farmState.integrityState, .passed)
        let checkpointState = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ESheepCloudCheckpointState>()).first { $0.farmID == farmID }
        )
        XCTAssertEqual(checkpointState.stateRawValue, "active")
        XCTAssertEqual(checkpointState.boundaryEventSequence, 4)
    }

    func testInitialSyncMaterializesZeroEventStreamInsteadOfActivatingHalfProjection() async throws {
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudInitialSyncZeroEventStreamTests-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let farmID = UUID()
        let ownerAccountID = UUID()
        let memberAccountID = UUID()
        let streamID = UUID()
        let generation = 5
        let profile = ESheepCloudFarmProfileV2(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            name: "零事件资料流牧场",
            createdAt: .now,
            updatedAt: .now,
            locationDisplayName: nil,
            latitude: nil,
            longitude: nil,
            coordinateReferenceSystem: "wgs84",
            addressSnapshot: nil,
            timeZoneIdentifier: "Asia/Shanghai",
            locationSourceRawValue: nil,
            horizontalAccuracyMeters: nil,
            locationUpdatedAt: nil
        )
        let profileDigest = try ESheepCloudCanonicalCodec.digest(profile)
        let streamDigest = try ESheepCloudCanonicalCodec.digest(
            [String: ESheepCloudValueV2]()
        )
        let chunkObject: [[String: Any]] = [[
            "record_kind": "stream",
            "stream_type": "sheepAvatar",
            "stream_id": streamID.uuidString,
            "stream_version": 0,
            "field_versions": [:],
            "canonical_state": [:],
            "content_digest": streamDigest,
            "last_event_sequence": 0,
        ]]
        let chunkData = try JSONSerialization.data(
            withJSONObject: chunkObject,
            options: [.sortedKeys]
        )
        let chunkDigest = SHA256.hash(data: chunkData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = ESheepCloudSnapshotManifestV2(
            snapshotID: UUID(),
            farmID: farmID,
            farmGeneration: generation,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            boundaryEventSequence: 0,
            eventHeadAtCreation: 0,
            recordCounts: [
                .init(recordType: "streams", count: 1),
                .init(recordType: "events", count: 0),
                .init(recordType: "assets", count: 0),
            ],
            chunks: [
                .init(index: 0, byteCount: Int64(chunkData.count), contentSHA256: chunkDigest),
            ],
            businessHistoryStartedAt: nil,
            businessHistoryEndedAt: nil,
            relationshipDigest: String(repeating: "0", count: 64),
            fieldVersionDigest: try ESheepCloudCanonicalCodec.digest([[String: Int]]()),
            farmProfileDigest: profileDigest,
            assets: [],
            totalDigest: SHA256.hash(data: Data((profileDigest + chunkDigest).utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            createdAt: .now
        )
        let gateway = InitialSyncGatewayStub(
            ticket: .init(
                manifest: manifest,
                farmProfile: profile,
                memberAccountID: memberAccountID,
                memberRole: .worker,
                membershipStatus: "active",
                expiresAt: .now.addingTimeInterval(1_800)
            ),
            chunkDataByIndex: [0: chunkData]
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "ESheepCloudInitialSyncZeroEventStream-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let coordinator = ESheepCloudInitialSyncCoordinator(
            farmID: farmID,
            container: container,
            gateway: gateway,
            applicationSupportURL: temporaryRoot
        )

        let report = try await coordinator.prepareNewInstallation(
            expectedFarmGeneration: generation
        )

        XCTAssertEqual(report.streamCount, 1)
        let context = ModelContext(container)
        let stream = try XCTUnwrap(
            context.fetch(FetchDescriptor<ESheepCloudStreamState>())
                .first(where: { $0.streamID == streamID })
        )
        XCTAssertEqual(stream.streamType, "sheepAvatar")
        XCTAssertEqual(stream.streamVersion, 0)
        XCTAssertEqual(stream.lastEventSequence, 0)
        XCTAssertEqual(stream.contentDigest, streamDigest)
        XCTAssertEqual(stream.canonicalStateData, Data("{}".utf8))
    }

    func testCommandEnvelopeHasNoEntityBaseRevisionAndDigestIsDeterministic() throws {
        let commandID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let farmID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let accountID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let deviceID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let sheepID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let assetID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = ESheepCloudCommandFactoryV2.avatar(
            sheepID: sheepID,
            photoAssetID: assetID,
            occurredAt: date
        )
        let observation = ESheepCloudFieldObservationV2(
            stream: draft.affectedStreams[0],
            field: "avatar",
            observedVersion: 8,
            baseValueDigest: ESheepCloudValueV2.identifier(assetID).digest
        )

        func make() throws -> ESheepCloudCommandEnvelopeV2 {
            try ESheepCloudCommandEnvelopeV2(
                commandID: commandID,
                sourceRequestID: commandID,
                farmID: farmID,
                farmGeneration: 2,
                accountID: accountID,
                deviceID: deviceID,
                deviceSequence: 42,
                createdAt: date,
                occurredAt: date,
                payload: draft.payload,
                affectedStreams: draft.affectedStreams,
                affectedFields: [observation],
                fieldChanges: draft.fieldChanges,
                requiredAssetIDs: [assetID]
            )
        }

        let first = try make()
        let second = try make()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.contentDigest, second.contentDigest)
        XCTAssertEqual(first.payload.kind, "sheepAvatar.set")
        try first.validateDigest()

        let encoded = try ESheepCloudCanonicalCodec.encode(first)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("baseRevision"))
        XCTAssertFalse(json.contains("base_revision"))
        XCTAssertTrue(json.contains("observedVersion"))
        XCTAssertTrue(json.contains("baseValueDigest"))
    }

    /// The coverage gate reads this explicit registry assertion.  Keeping the
    /// assertion in the app target and exercising every discriminator prevents
    /// a test-only manifest from declaring a command complete without a typed
    /// payload and a deterministic replay route.
    func testV2CommandRegistryIsExhaustiveAndEveryKindHasTypedRoute() {
        let kinds = ESheepCloudCommandRegistryV2.allKinds
        XCTAssertEqual(kinds.count, 89)
        XCTAssertEqual(Set(kinds).count, kinds.count)
        XCTAssertEqual(ESheepCloudCommandRegistryV2.kindSet, Set(kinds))
        for kind in kinds {
            XCTAssertNotNil(
                ESheepCloudCommandRegistryV2.expectedPayloadCase(for: kind),
                "missing typed discriminator for \(kind)"
            )
            XCTAssertNotNil(
                ESheepCloudCommandRegistryV2.mergeMode(for: kind),
                "missing merge rule for \(kind)"
            )
            XCTAssertNotNil(
                ESheepCloudCommandRegistryV2.nativeProjectionRoute(for: kind),
                "missing native projection route for \(kind)"
            )
            XCTAssertTrue(
                ESheepCloudCommandRegistryV2.hasDeterministicReplayRoute(kind),
                "missing deterministic replay route for \(kind)"
            )
        }
    }

    func testEventBodyAndReceiptDigestMatchSQLGoldenVector() throws {
        let canonicalBody = "{\"changes\":[],\"command_kind\":\"sheepAvatar.set\"}"
        let bodyDigest = ESheepCloudEventBodyIntegrityV2.digest(
            canonicalJSON: canonicalBody
        )
        XCTAssertEqual(
            bodyDigest,
            "e48d829e9c34c3bcdd1ce4af9724b7103f27ed28ff81f6d857409bf712a2e217"
        )
        try ESheepCloudEventBodyIntegrityV2.validate(
            canonicalJSON: canonicalBody,
            expectedDigest: bodyDigest
        )
        XCTAssertThrowsError(try ESheepCloudEventBodyIntegrityV2.validate(
            canonicalJSON: canonicalBody + " ",
            expectedDigest: bodyDigest
        ))

        let event = ESheepCloudEventEnvelopeV2(
            protocolVersion: ESheepCloudProtocolV2.protocolVersion,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            farmID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            farmGeneration: 7,
            eventSequence: 42,
            eventID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            commandID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            sourceCommandDigest: String(repeating: "c", count: 64),
            stream: .init(
                type: "sheepAvatar",
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
            ),
            payload: .attentionResolved(
                attentionID: UUID(),
                field: "avatar",
                choice: .keepCloud,
                chosenValue: .null
            ),
            affectedFields: ["zeta", "avatar"],
            eventBodyDigest: bodyDigest,
            beforeDigest: String(repeating: "a", count: 64),
            afterDigest: String(repeating: "b", count: 64),
            actorAccountID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            sourceDeviceID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            sourceDeviceSequence: 99,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000.123),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000.456),
            eventDigest: ""
        )
        XCTAssertEqual(
            ESheepCloudEventDigestV2.hex(for: event),
            "1d830a1ad06c9c64a87f10cc17b2faf36c469e91c083f6071ba6bdfe59c58a22"
        )
    }

    func testEventRejectsMalformedProjectionDigestsEvenWhenOuterDigestMatches() throws {
        let unsigned = ESheepCloudEventEnvelopeV2(
            protocolVersion: ESheepCloudProtocolV2.protocolVersion,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            farmID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            farmGeneration: 1,
            eventSequence: 1,
            eventID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            commandID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            sourceCommandDigest: String(repeating: "c", count: 64),
            stream: .init(
                type: "photoAsset",
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
            ),
            payload: .businessCommandApplied(
                commandKind: "photoAsset.restore",
                payload: .photo(.restore(assetID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!))
            ),
            affectedFields: [],
            eventBodyDigest: String(repeating: "d", count: 64),
            beforeDigest: "not-a-sha256",
            afterDigest: String(repeating: "b", count: 64),
            actorAccountID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            sourceDeviceID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            sourceDeviceSequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_001),
            eventDigest: ""
        )
        let event = ESheepCloudEventEnvelopeV2(
            protocolVersion: unsigned.protocolVersion,
            schemaVersion: unsigned.schemaVersion,
            farmID: unsigned.farmID,
            farmGeneration: unsigned.farmGeneration,
            eventSequence: unsigned.eventSequence,
            eventID: unsigned.eventID,
            commandID: unsigned.commandID,
            sourceCommandDigest: unsigned.sourceCommandDigest,
            stream: unsigned.stream,
            payload: unsigned.payload,
            affectedFields: unsigned.affectedFields,
            eventBodyDigest: unsigned.eventBodyDigest,
            beforeDigest: unsigned.beforeDigest,
            afterDigest: unsigned.afterDigest,
            actorAccountID: unsigned.actorAccountID,
            sourceDeviceID: unsigned.sourceDeviceID,
            sourceDeviceSequence: unsigned.sourceDeviceSequence,
            occurredAt: unsigned.occurredAt,
            receivedAt: unsigned.receivedAt,
            eventDigest: ESheepCloudEventDigestV2.hex(for: unsigned)
        )

        XCTAssertThrowsError(try event.validateDigest())
    }

    func testSnapshotDecoderFailsClosedForUnknownEventKind() throws {
        let farmID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let eventID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let commandID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let streamID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let body = "{}"
        let record: [String: Any] = [
            "record_kind": "event",
            "event_sequence": 1,
            "event_id": eventID.uuidString,
            "command_id": commandID.uuidString,
            "source_command_digest": String(repeating: "c", count: 64),
            "stream_type": "sheepAvatar",
            "stream_id": streamID.uuidString,
            "event_kind": "future_event_kind",
            "event_body_canonical": body,
            "event_body_digest": ESheepCloudEventBodyIntegrityV2.digest(canonicalJSON: body),
            "affected_fields": [],
            "before_digest": String(repeating: "a", count: 64),
            "after_digest": String(repeating: "b", count: 64),
            "actor_account_id": UUID(uuidString: "55555555-5555-5555-5555-555555555555")!.uuidString,
            "source_device_id": UUID(uuidString: "66666666-6666-6666-6666-666666666666")!.uuidString,
            "source_device_sequence": 1,
            "occurred_at_millis": 1_800_000_000_000,
            "received_at_millis": 1_800_000_001_000,
            "event_digest": String(repeating: "e", count: 64),
        ]
        let data = try JSONSerialization.data(withJSONObject: [record], options: [.sortedKeys])

        XCTAssertThrowsError(
            try ESheepCloudSnapshotCodec.decode(
                data,
                farmID: farmID,
                farmGeneration: 1
            )
        )
    }

    func testSnapshotAssetStateMappingKeepsCloudSpellingOutOfLocalLedger() {
        XCTAssertEqual(
            ESheepCloudAssetWireStateV2(rawValue: "missing")?.localRawValue,
            ESheepCloudAssetTransferState.unavailable.rawValue
        )
        XCTAssertEqual(
            ESheepCloudAssetWireStateV2(rawValue: "recycle_bin")?.localRawValue,
            ESheepCloudAssetTransferState.recycleBin.rawValue
        )
        XCTAssertNil(ESheepCloudAssetWireStateV2(rawValue: "future_state"))
    }

    func testCommandEnvelopeRejectsInvalidSequenceAndDuplicateStreams() throws {
        let farmID = UUID()
        let accountID = UUID()
        let deviceID = UUID()
        let commandID = UUID()
        let sheepID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = ESheepCloudCommandFactoryV2.avatar(
            sheepID: sheepID,
            photoAssetID: nil,
            occurredAt: date
        )
        let stream = try XCTUnwrap(draft.affectedStreams.first)
        let observation = ESheepCloudFieldObservationV2(
            stream: stream,
            field: "avatar",
            observedVersion: 0,
            baseValueDigest: ESheepCloudValueV2.null.digest
        )

        XCTAssertThrowsError(try ESheepCloudCommandEnvelopeV2(
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: farmID,
            farmGeneration: 2,
            accountID: accountID,
            deviceID: deviceID,
            deviceSequence: 0,
            createdAt: date,
            occurredAt: date,
            payload: draft.payload,
            affectedStreams: [stream],
            affectedFields: [observation],
            fieldChanges: draft.fieldChanges
        ))
        XCTAssertThrowsError(try ESheepCloudCommandEnvelopeV2(
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: farmID,
            farmGeneration: 2,
            accountID: accountID,
            deviceID: deviceID,
            deviceSequence: 1,
            createdAt: date,
            occurredAt: date,
            payload: draft.payload,
            affectedStreams: [stream, stream],
            affectedFields: [observation],
            fieldChanges: draft.fieldChanges
        ))
    }

    func testStagingRequiresVerifiedDeviceSequenceBeforeWriting() throws {
        let fixture = try makeFixture(reconcilesSequence: false)
        XCTAssertThrowsError(try stageAvatar(assetID: nil, sequence: 1, fixture: fixture)) { error in
            XCTAssertTrue(error is ESheepCloudSequenceWatermark.SequenceError)
        }
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>()), 0)

        try ESheepCloudSequenceWatermark.reconcile(
            farmID: fixture.farmID, deviceID: fixture.deviceID, floor: 41
        )
        let intent = try stageAvatar(assetID: nil, sequence: 1, fixture: fixture)
        XCTAssertEqual(intent.deviceSequence, 42)
    }

    func testAvatarSetClearRestoreCollapsesOnlyUnsentIntentForSameSheep() throws {
        let fixture = try makeFixture()
        let firstAsset = UUID()
        let secondAsset = UUID()
        fixture.context.insert(verifiedAsset(
            id: firstAsset,
            farmID: fixture.farmID,
            generation: fixture.generation
        ))
        fixture.context.insert(verifiedAsset(
            id: secondAsset,
            farmID: fixture.farmID,
            generation: fixture.generation
        ))

        let first = try stageAvatar(
            assetID: firstAsset,
            sequence: 1,
            fixture: fixture
        )
        let clear = try stageAvatar(
            assetID: nil,
            sequence: 2,
            fixture: fixture
        )
        let restore = try stageAvatar(
            assetID: secondAsset,
            sequence: 3,
            fixture: fixture
        )

        XCTAssertEqual(first.lifecycle, .supersededLocally)
        XCTAssertEqual(clear.lifecycle, .supersededLocally)
        XCTAssertEqual(restore.lifecycle, .ready)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>()), 3)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
    }

    func testDependencyBlocksOnlyDependentIntent() throws {
        let fixture = try makeFixture()
        let prerequisiteID = UUID()
        let independentID = UUID()
        let dependentID = UUID()
        let draft = ESheepCloudCommandFactoryV2.avatar(
            sheepID: UUID(),
            photoAssetID: nil
        )

        let prerequisite = try ESheepCloudIntentWriter.stage(
            draft: draft,
            commandID: prerequisiteID,
            sourceRequestID: prerequisiteID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 1,
            context: fixture.context
        )
        let independent = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(sheepID: UUID(), photoAssetID: nil),
            commandID: independentID,
            sourceRequestID: independentID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 2,
            context: fixture.context
        )
        let dependent = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(sheepID: UUID(), photoAssetID: nil),
            commandID: dependentID,
            sourceRequestID: dependentID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 3,
            prerequisiteCommandIDs: [prerequisiteID],
            context: fixture.context
        )

        XCTAssertEqual(prerequisite.lifecycle, .ready)
        XCTAssertEqual(independent.lifecycle, .ready)
        XCTAssertEqual(dependent.lifecycle, .waitingForDependency)

        prerequisite.lifecycle = .needsConfirmation
        try ESheepCloudIntentWriter.refreshReadiness(
            farmID: fixture.farmID,
            context: fixture.context
        )
        XCTAssertEqual(independent.lifecycle, .ready)
        XCTAssertEqual(dependent.lifecycle, .waitingForDependency)

        prerequisite.lifecycle = .accepted
        try ESheepCloudIntentWriter.refreshReadiness(
            farmID: fixture.farmID,
            context: fixture.context
        )
        XCTAssertEqual(dependent.lifecycle, .ready)
    }

    func testCorruptedDependencyLedgerNeverDegradesToNoDependencies() async throws {
        let fixture = try makeFixture()
        let commandID = UUID()
        let intent = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(
                sheepID: fixture.sharedSheepID,
                photoAssetID: nil
            ),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 1,
            context: fixture.context
        )
        intent.lifecycle = .waitingForDependency
        intent.prerequisiteCommandIDsData = Data("not-json".utf8)
        try fixture.context.save()
        let store = ESheepCloudLocalStore(container: fixture.container)

        do {
            _ = try await store.prepareCycle(farmID: fixture.farmID, accountID: fixture.accountID)
            XCTFail("Malformed dependency must fail closed")
        } catch { /* Expected: the durable integrity hold is checked below. */ }
        let verification = ModelContext(fixture.container)
        let state = try XCTUnwrap(
            verification.fetch(FetchDescriptor<ESheepCloudFarmState>()).first
        )
        XCTAssertEqual(state.activityState, .integrityHold)
        XCTAssertEqual(state.integrityState, .failed)
        XCTAssertNotNil(state.integrityFailureTraceID)
        let preserved = try XCTUnwrap(
            verification.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
                .first(where: { $0.id == commandID })
        )
        XCTAssertEqual(preserved.lifecycle, .waitingForDependency)
        XCTAssertEqual(preserved.prerequisiteCommandIDsData, Data("not-json".utf8))
    }

    func testDependencyCannotCrossAccountBoundary() throws {
        let fixture = try makeFixture()
        let prerequisiteID = UUID()
        _ = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(
                sheepID: fixture.sharedSheepID,
                photoAssetID: nil
            ),
            commandID: prerequisiteID,
            sourceRequestID: prerequisiteID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 1,
            context: fixture.context
        )
        let otherAccountID = UUID()
        let commandID = UUID()

        XCTAssertThrowsError(try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(
                sheepID: fixture.sharedSheepID,
                photoAssetID: nil
            ),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: otherAccountID,
            deviceID: fixture.deviceID,
            deviceSequence: 2,
            prerequisiteCommandIDs: [prerequisiteID],
            context: fixture.context
        )) { error in
            XCTAssertEqual(
                error as? ESheepCloudIntentWriterError,
                .invalidDependency
            )
        }
    }

    func testFieldObservationUsesStreamFieldVersionInsteadOfEntityRevision() throws {
        let fixture = try makeFixture()
        let sheepID = UUID()
        let stream = ESheepCloudStreamState(
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            streamType: "sheepAvatar",
            streamID: sheepID,
            streamVersion: 99,
            fieldVersionsData: try ESheepCloudCanonicalCodec.encode([
                ESheepCloudFieldVersionEntryV2(
                    field: "avatar",
                    version: 7,
                    valueDigest: ESheepCloudValueV2.null.digest
                ),
            ])
        )
        fixture.context.insert(stream)
        let commandID = UUID()
        let intent = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(sheepID: sheepID, photoAssetID: nil),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 1,
            context: fixture.context
        )
        let envelope = try ESheepCloudCanonicalCodec.decode(
            ESheepCloudCommandEnvelopeV2.self,
            from: intent.commandEnvelopeData
        )

        XCTAssertEqual(envelope.affectedFields.count, 1)
        XCTAssertEqual(envelope.affectedFields[0].field, "avatar")
        XCTAssertEqual(envelope.affectedFields[0].observedVersion, 7)
        XCTAssertNotEqual(envelope.affectedFields[0].observedVersion, stream.streamVersion)
    }

    func testCorruptedFieldVersionLedgerCannotInventVersionZero() throws {
        let fixture = try makeFixture()
        let stream = ESheepCloudStreamState(
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            streamType: "sheepAvatar",
            streamID: fixture.sharedSheepID,
            streamVersion: 8,
            fieldVersionsData: Data("not-json".utf8)
        )
        fixture.context.insert(stream)
        let commandID = UUID()

        XCTAssertThrowsError(try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(
                sheepID: fixture.sharedSheepID,
                photoAssetID: nil
            ),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 1,
            context: fixture.context
        ))
        XCTAssertEqual(
            try fixture.context.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>()),
            0
        )
    }

    func testAwaitingResultIsNeverTurnedBackIntoReadyByDependencyRefresh() throws {
        let fixture = try makeFixture()
        let commandID = UUID()
        let intent = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(
                sheepID: fixture.sharedSheepID,
                photoAssetID: nil
            ),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 1,
            context: fixture.context
        )
        intent.lifecycle = .awaitingResult
        intent.nextRetryAt = .distantPast

        try ESheepCloudIntentWriter.refreshReadiness(
            farmID: fixture.farmID,
            context: fixture.context
        )

        XCTAssertEqual(intent.lifecycle, .awaitingResult)
    }

    func testTypedPayloadUsesExplicitDiscriminatorAndMismatchFailsClosed() throws {
        let sheepID = UUID()
        let assetID = UUID()
        let payload = ESheepCloudCommandPayloadV2.sheep(
            .setAvatar(sheepID: sheepID, photoAssetID: assetID)
        )
        let data = try ESheepCloudCanonicalCodec.encode(payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["kind"] as? String, "sheepAvatar.set")
        XCTAssertNotNil((object["body"] as? [String: Any])?["setAvatar"])

        var mismatched = object
        mismatched["kind"] = "sheepAvatar.clear"
        let mismatchedData = try JSONSerialization.data(
            withJSONObject: mismatched,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try ESheepCloudCanonicalCodec.decode(
                ESheepCloudCommandPayloadV2.self,
                from: mismatchedData
            )
        )
    }

    func testTemporaryAssetRejectionPreservesImmutableIntentForRetry() async throws {
        let fixture = try makeFixture()
        let assetID = UUID()
        fixture.context.insert(verifiedAsset(
            id: assetID,
            farmID: fixture.farmID,
            generation: fixture.generation
        ))
        let commandID = UUID()
        let intent = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(
                sheepID: fixture.sharedSheepID,
                photoAssetID: assetID
            ),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 1,
            context: fixture.context
        )
        let originalBytes = intent.commandEnvelopeData
        try fixture.context.save()
        let store = ESheepCloudLocalStore(container: fixture.container)

        try await store.recordCommandResults(
            [commandID: .rejected(.resourceUnavailable(assetID: assetID))],
            farmID: fixture.farmID,
            farmGeneration: fixture.generation
        )
        // A partial batch transport failure must not reset this already
        // acknowledged dependency result along with the unknown commands.
        try await store.markTransportUncertain(commandIDs: [commandID], message: "partial batch")

        let verificationContext = ModelContext(fixture.container)
        let updated = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
                .first(where: { $0.id == commandID })
        )
        XCTAssertEqual(updated.lifecycle, .waitingForDependency)
        XCTAssertNotNil(updated.nextRetryAt)
        XCTAssertEqual(updated.commandEnvelopeData, originalBytes)
        XCTAssertEqual(updated.id, commandID)

        do {
            try await store.recordCommandResults([commandID: .duplicate(original: .init(commandID: UUID(),
                events: [], attention: nil, rejection: nil, cloudHead: 0))],
                farmID: fixture.farmID, farmGeneration: fixture.generation)
            XCTFail("A receipt for a different original command must never finish this intent")
        } catch ESheepCloudContractError.malformedPayload { }

        updated.lifecycle = .sending
        try verificationContext.save()
        let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.markTransportUncertain(commandIDs: [commandID], message: "service unavailable",
            failure: .init(kind: .serviceUnavailable), now: failedAt)
        let retryContext = ModelContext(fixture.container)
        let persisted = try XCTUnwrap(try retryContext.fetch(FetchDescriptor<ESheepCloudPendingIntent>()).first)
        XCTAssertEqual(persisted.lifecycle, .awaitingResult)
        XCTAssertEqual(persisted.nextRetryAt, failedAt.addingTimeInterval(900))
        XCTAssertEqual(persisted.commandEnvelopeData, originalBytes)
    }

    func testAttentionResolutionSigningDataUsesStableWireChoice() {
        let resolution = ESheepCloudAttentionResolutionV2(
            attentionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            resolutionCommandID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            choice: .useThisDevice,
            expectedCloudValueDigest: String(repeating: "A", count: 64),
            farmGeneration: 2,
            accountID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            deviceID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            deviceSequence: 9,
            deviceSignature: Data()
        )

        XCTAssertEqual(
            String(decoding: resolution.canonicalSigningData, as: UTF8.self),
            [
                "esheep-cloud-attention-resolution-v2",
                "10000000-0000-0000-0000-000000000001",
                "20000000-0000-0000-0000-000000000002",
                "use_this_device",
                String(repeating: "a", count: 64),
                "2",
                "30000000-0000-0000-0000-000000000003",
                "40000000-0000-0000-0000-000000000004",
                "9",
            ].joined(separator: "\n")
        )
    }

    func testAttentionResolutionSurvivesTimeoutAndQueriesBeforeRetry() async throws {
        let fixture = try makeFixture()
        let attentionID = UUID()
        fixture.context.insert(makeAttention(
            id: attentionID,
            commandID: UUID(),
            deviceValue: .identifier(UUID()),
            cloudValue: .identifier(UUID()),
            fixture: fixture
        ))
        try fixture.context.save()
        let store = ESheepCloudLocalStore(container: fixture.container)
        let first = try await store.beginAttentionResolution(
            attentionID: attentionID,
            choice: .useThisDevice,
            farmID: fixture.farmID,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID
        )
        try await store.markAttentionResolutionAttempted(
            commandID: first.resolutionCommandID
        )
        let timeoutAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.markAttentionResolutionTransportUncertain(
            commandID: first.resolutionCommandID,
            message: "timeout",
            now: timeoutAt
        )

        let awaiting = try await store.prepareCycle(
            farmID: fixture.farmID,
            accountID: fixture.accountID,
            now: timeoutAt.addingTimeInterval(10_000)
        )
        XCTAssertEqual(
            awaiting.attentionResolutionsAwaitingStatus,
            [first.resolutionCommandID]
        )
        XCTAssertTrue(awaiting.readyAttentionResolutions.isEmpty)

        try await store.markUnknownAttentionResolutionsReadyToRetry([
            first.resolutionCommandID,
        ])
        let retry = try await store.prepareCycle(
            farmID: fixture.farmID,
            accountID: fixture.accountID,
            now: timeoutAt.addingTimeInterval(10_001)
        )
        let restored = try XCTUnwrap(retry.readyAttentionResolutions.first)
        XCTAssertEqual(restored.attentionID, first.attentionID)
        XCTAssertEqual(restored.resolutionCommandID, first.resolutionCommandID)
        XCTAssertEqual(restored.deviceSequence, first.deviceSequence)
        XCTAssertEqual(restored.choice, first.choice)
        XCTAssertEqual(restored.canonicalSigningData, first.canonicalSigningData)
    }

    func testCloudStatusRemovesAnAttentionItemThatNoLongerNeedsAChoice() async throws {
        let fixture = try makeFixture()
        let attention = makeAttention(
            id: UUID(),
            commandID: UUID(),
            deviceValue: .string("这台设备"),
            cloudValue: .string("eSheep+ 云"),
            fixture: fixture
        )
        fixture.context.insert(attention)
        try fixture.context.save()
        let store = ESheepCloudLocalStore(container: fixture.container)

        try await store.applyCloudStatus(
            ESheepCloudStatusV2(
                farmID: fixture.farmID,
                farmGeneration: fixture.generation,
                cloudHead: 0,
                latestSnapshotID: nil,
                v2Ready: true,
                writeFrozen: false,
                writeFreezeTraceID: nil,
                attentionItems: [],
                serverTime: .now
            ),
            accountID: fixture.accountID
        )

        let verificationContext = ModelContext(fixture.container)
        let updated = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<ESheepCloudAttentionItem>())
                .first(where: { $0.id == attention.id })
        )
        XCTAssertEqual(updated.state, .obsolete)
    }

    func testPhotoRegistrationWaitsForEveryVerifiedVariant() throws {
        let fixture = try makeFixture()
        let assetID = UUID()
        let metadata = photoMetadata(capturedAt: nil)
        let metadataDigest = try ESheepCloudCanonicalCodec.digest(metadata)
        let asset = ESheepCloudAssetState(
            assetID: assetID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            sheepID: fixture.sharedSheepID,
            contentSHA256: String(repeating: "a", count: 64),
            metadataDigest: metadataDigest,
            originalByteCount: 33
        )
        asset.metadataData = try ESheepCloudCanonicalCodec.encode(metadata)
        asset.thumbnailSHA256 = String(repeating: "b", count: 64)
        asset.avatarSHA256 = String(repeating: "c", count: 64)
        asset.originalSHA256 = String(repeating: "a", count: 64)
        asset.thumbnailByteCount = 11
        asset.avatarByteCount = 22
        fixture.context.insert(asset)

        let commandID = UUID()
        let intent = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.registerPhoto(
                assetID: assetID,
                sheepID: fixture.sharedSheepID,
                capturedAt: nil,
                mimeType: "image/jpeg",
                contentSHA256: String(repeating: "a", count: 64),
                metadata: metadata,
                metadataDigest: metadataDigest,
                thumbnailSHA256: String(repeating: "b", count: 64),
                avatarSHA256: String(repeating: "c", count: 64),
                originalSHA256: String(repeating: "a", count: 64),
                thumbnailByteCount: 11,
                avatarByteCount: 22,
                originalByteCount: 33
            ),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: 1,
            context: fixture.context
        )
        XCTAssertEqual(intent.lifecycle, .waitingForDependency)

        asset.thumbnailStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
        asset.avatarStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
        try ESheepCloudIntentWriter.refreshReadiness(
            farmID: fixture.farmID,
            context: fixture.context
        )
        XCTAssertEqual(intent.lifecycle, .waitingForDependency)

        asset.originalStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
        try ESheepCloudIntentWriter.refreshReadiness(
            farmID: fixture.farmID,
            context: fixture.context
        )
        XCTAssertEqual(intent.lifecycle, .ready)
    }

    func testPhotoRegistrationEventRebuildsVerifiedRemoteAssetExactlyOnce() throws {
        let fixture = try makeFixture()
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let event = try makePhotoRegistrationEvent(
            fixture: fixture,
            capturedAt: capturedAt,
            metadata: photoMetadata(capturedAt: capturedAt)
        )

        let first = try ESheepCloudEventReducer.apply(event, context: fixture.context)
        let duplicate = try ESheepCloudEventReducer.apply(event, context: fixture.context)

        XCTAssertFalse(first.wasAlreadyApplied)
        XCTAssertNil(first.historyChangedAt, "Descriptive profile edits must not rebuild occupancy history")
        XCTAssertTrue(duplicate.wasAlreadyApplied)
        let photo = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<PhotoAssetRecord>()).first
        )
        XCTAssertEqual(photo.id, event.stream.id)
        XCTAssertEqual(photo.sheepID, fixture.sharedSheepID)
        XCTAssertEqual(photo.capturedAt, capturedAt)
        XCTAssertEqual(photo.sourceSHA256, String(repeating: "d", count: 64))
        XCTAssertEqual(photo.sourcePixelWidth, 2_000)
        XCTAssertEqual(photo.sourcePixelHeight, 1_500)
        XCTAssertEqual(photo.cloudPixelWidth, 1_600)
        XCTAssertEqual(photo.cloudPixelHeight, 1_200)
        XCTAssertTrue(photo.isCloudAuthoritative)

        let asset = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ESheepCloudAssetState>()).first
        )
        XCTAssertEqual(asset.thumbnailSHA256, String(repeating: "b", count: 64))
        XCTAssertEqual(asset.avatarSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(asset.originalSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(asset.thumbnailByteCount, 11)
        XCTAssertEqual(asset.avatarByteCount, 22)
        XCTAssertEqual(asset.originalByteCount, 33)
        XCTAssertEqual(asset.thumbnailStateRawValue, ESheepCloudAssetTransferState.verified.rawValue)
        XCTAssertEqual(asset.avatarStateRawValue, ESheepCloudAssetTransferState.verified.rawValue)
        XCTAssertEqual(asset.originalStateRawValue, ESheepCloudAssetTransferState.verified.rawValue)
        XCTAssertEqual(
            try fixture.context.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()),
            1
        )
    }

    func testPhotoRestoreReenablesAllDerivedRenditions() throws {
        let fixture = try makeFixture()
        let assetID = UUID()
        let record = PhotoAssetRecord(
            id: assetID,
            farmID: fixture.farmID,
            sheepID: fixture.sharedSheepID,
            legacySourceKey: "restore-test",
            originalEarTag: "DH054",
            relativePath: "",
            sha256: String(repeating: "a", count: 64)
        )
        record.deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        fixture.context.insert(record)
        let asset = ESheepCloudAssetState(
            assetID: assetID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            sheepID: fixture.sharedSheepID,
            contentSHA256: String(repeating: "a", count: 64),
            metadataDigest: String(repeating: "b", count: 64),
            originalByteCount: 33
        )
        asset.thumbnailStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
        asset.avatarStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
        asset.originalStateRawValue = ESheepCloudAssetTransferState.recycleBin.rawValue
        asset.recycleExpiresAt = Date(timeIntervalSince1970: 1_800_000_100)
        fixture.context.insert(asset)

        let commandID = UUID()
        let eventID = UUID()
        let payload = ESheepCloudCommandPayloadV2.photo(
            .restore(assetID: assetID)
        )
        let beforeDigest = try ESheepCloudCanonicalCodec.digest(
            [String: ESheepCloudValueV2]()
        )
        let afterDigest = try ESheepCloudCanonicalCodec.digest(
            ESheepCloudNonFieldStreamStateV2(
                eventCount: 1,
                lastCommandDigest: String(repeating: "e", count: 64),
                lastCommandID: commandID.uuidString.lowercased(),
                lastCommandKind: payload.kind
            )
        )
        func makeEvent(digest: String) -> ESheepCloudEventEnvelopeV2 {
            ESheepCloudEventEnvelopeV2(
                protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                farmID: fixture.farmID,
                farmGeneration: fixture.generation,
                eventSequence: 1,
                eventID: eventID,
                commandID: commandID,
                sourceCommandDigest: String(repeating: "e", count: 64),
                stream: ESheepCloudStreamReferenceV2(
                    type: "photoAsset",
                    id: assetID
                ),
                payload: .businessCommandApplied(
                    commandKind: payload.kind,
                    payload: payload
                ),
                affectedFields: [],
                eventBodyDigest: String(repeating: "d", count: 64),
                beforeDigest: beforeDigest,
                afterDigest: afterDigest,
                actorAccountID: fixture.accountID,
                sourceDeviceID: fixture.deviceID,
                sourceDeviceSequence: 1,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_001),
                eventDigest: digest
            )
        }
        let unsigned = makeEvent(digest: "")
        let event = makeEvent(digest: ESheepCloudEventDigestV2.hex(for: unsigned))

        _ = try ESheepCloudEventReducer.apply(event, context: fixture.context)

        XCTAssertNil(record.deletedAt)
        XCTAssertEqual(
            asset.thumbnailStateRawValue,
            ESheepCloudAssetTransferState.verified.rawValue
        )
        XCTAssertEqual(
            asset.avatarStateRawValue,
            ESheepCloudAssetTransferState.verified.rawValue
        )
        XCTAssertEqual(
            asset.originalStateRawValue,
            ESheepCloudAssetTransferState.verified.rawValue
        )
        XCTAssertNil(asset.recycleExpiresAt)
    }

    func testV2FarmDoesNotFallBackToLegacyRestoreScreen() throws {
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudRootRoutingTests-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .eSheepCloud,
            transitionState: .idle,
            authorityGeneration: 3
        ))
        let restore = FarmRemoteRestoreRecord(
            accountID: accountID,
            farmID: farmID,
            authorityGeneration: 3,
            state: .catchingUp
        )
        context.insert(restore)
        try context.save()

        // Keep this behavior executable without rendering RootView: the
        // routing policy is intentionally pure and classifies only legacy
        // profiles as eligible for the compatibility screen.
        let profile = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmStorageProfile>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertFalse(
            ESheepCloudFarmVisibilityPolicy.isLegacyCompatibilityRestore(
                profileMode: profile.mode,
                transitionState: profile.transitionState
            )
        )
        XCTAssertTrue(
            ESheepCloudFarmVisibilityPolicy.isLegacyCompatibilityRestore(
                profileMode: .supabase,
                transitionState: .idle
            )
        )
        XCTAssertFalse(
            ESheepCloudFarmVisibilityPolicy.isLegacyCompatibilityRestore(
                profileMode: .supabase,
                transitionState: .readOnlyMigration
            )
        )
    }

    func testBusinessEventRebuildsEmptyDeviceWithoutUsingV1Projection() throws {
        let fixture = try makeFixture()
        let commandID = UUID()
        let recordID = UUID()
        let payload = ESheepCloudCommandPayloadV2.fact(.recordWeight(
            sheepID: fixture.sharedSheepID,
            kilogramsText: "42.5",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            note: ""
        ))
        let sourceCommandDigest = String(repeating: "e", count: 64)
        let afterDigest = try ESheepCloudCanonicalCodec.digest(
            ESheepCloudNonFieldStreamStateV2(
                eventCount: 1,
                lastCommandDigest: sourceCommandDigest,
                lastCommandID: commandID.uuidString.lowercased(),
                lastCommandKind: payload.kind
            )
        )
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_001)
        let eventID = UUID()
        func event(digest: String) -> ESheepCloudEventEnvelopeV2 {
            ESheepCloudEventEnvelopeV2(
                protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                farmID: fixture.farmID,
                farmGeneration: fixture.generation,
                eventSequence: 1,
                eventID: eventID,
                commandID: commandID,
                sourceCommandDigest: sourceCommandDigest,
                stream: .init(type: "weight", id: recordID),
                payload: .businessCommandApplied(
                    commandKind: payload.kind,
                    payload: payload
                ),
                affectedFields: [],
                eventBodyDigest: String(repeating: "d", count: 64),
                beforeDigest: try! ESheepCloudCanonicalCodec.digest(
                    [String: ESheepCloudValueV2]()
                ),
                afterDigest: afterDigest,
                actorAccountID: fixture.accountID,
                sourceDeviceID: fixture.deviceID,
                sourceDeviceSequence: 1,
                occurredAt: occurredAt,
                receivedAt: receivedAt,
                eventDigest: digest
            )
        }
        let unsigned = event(digest: "")
        let signed = event(digest: ESheepCloudEventDigestV2.hex(for: unsigned))

        let first = try ESheepCloudEventReducer.apply(signed, context: fixture.context)
        XCTAssertFalse(first.wasAlreadyApplied)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<WeightRecord>()), 1)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<WeightRecord>()).first?.recordedAt,
                       receivedAt, "Replaying a fact must not replace its recording metadata with this machine's current time")
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()), 1)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudStreamState>()), 1)

        let duplicate = try ESheepCloudEventReducer.apply(signed, context: fixture.context)
        XCTAssertTrue(duplicate.wasAlreadyApplied)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<WeightRecord>()), 1)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()), 1)
    }

    func testPurposeHistorySurvivesMultipleStreamsAndRepeatedEvents() throws {
        let fixture = try makeFixture()
        let commandID = UUID()
        let sheep = SheepRecord(id: fixture.sharedSheepID, farmID: fixture.farmID,
            earTag: "purpose-history", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .distantPast)
        sheep.purpose = "繁殖母羊"
        sheep.revision = 1
        fixture.context.insert(sheep)
        try fixture.context.save()
        let command = FarmCommand.care(.setSheepPurpose(sheepID: sheep.id, purpose: .fattening,
            reason: "用途变更历史", expectedRevision: 1))
        let payload = try ESheepCloudCommandFactoryV2.make(command: command,
            farmID: fixture.farmID, primaryEntityType: CloudEntityType.sheep.rawValue,
            primaryEntityID: sheep.id).payload
        let sourceDigest = String(repeating: "a", count: 64)
        let emptyDigest = try ESheepCloudCanonicalCodec.digest(
            [String: ESheepCloudValueV2]()
        )

        func event(
            sequence: Int64,
            stream: ESheepCloudStreamReferenceV2,
            digest: String
        ) -> ESheepCloudEventEnvelopeV2 {
            let afterDigest = try! ESheepCloudCanonicalCodec.digest(
                ESheepCloudNonFieldStreamStateV2(
                    eventCount: 1,
                    lastCommandDigest: sourceDigest,
                    lastCommandID: commandID.uuidString.lowercased(),
                    lastCommandKind: payload.kind
                )
            )
            return ESheepCloudEventEnvelopeV2(
                protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                farmID: fixture.farmID,
                farmGeneration: fixture.generation,
                eventSequence: sequence,
                eventID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012lld", sequence))!,
                commandID: commandID,
                sourceCommandDigest: sourceDigest,
                stream: stream,
                payload: .businessCommandApplied(
                    commandKind: payload.kind,
                    payload: payload
                ),
                affectedFields: [],
                eventBodyDigest: String(repeating: "b", count: 64),
                beforeDigest: emptyDigest,
                afterDigest: afterDigest,
                actorAccountID: fixture.accountID,
                sourceDeviceID: fixture.deviceID,
                sourceDeviceSequence: 1,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_001),
                eventDigest: digest
            )
        }

        let primaryStream = ESheepCloudStreamReferenceV2(
            type: "sheep",
            id: sheep.id
        )
        let semanticStream = ESheepCloudStreamReferenceV2(
            type: "sheepProfile",
            id: fixture.sharedSheepID
        )
        let firstUnsigned = event(sequence: 1, stream: primaryStream, digest: "")
        let first = event(
            sequence: 1,
            stream: primaryStream,
            digest: ESheepCloudEventDigestV2.hex(for: firstUnsigned)
        )
        let secondUnsigned = event(sequence: 2, stream: semanticStream, digest: "")
        let second = event(
            sequence: 2,
            stream: semanticStream,
            digest: ESheepCloudEventDigestV2.hex(for: secondUnsigned)
        )

        _ = try ESheepCloudEventReducer.apply(first, context: fixture.context)
        _ = try ESheepCloudEventReducer.apply(second, context: fixture.context)

        _ = try ESheepCloudEventReducer.apply(first, context: fixture.context)
        let operations = try fixture.context.fetch(FetchDescriptor<DomainOperation>())
        XCTAssertEqual(operations.count, 1)
        let facts = SheepPurposeTimeline.facts(from: operations)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.id, commandID)
        XCTAssertEqual(facts.first?.previousPurpose, "繁殖母羊")
        XCTAssertEqual(facts.first?.purpose, .fattening)
        XCTAssertEqual(facts.first?.reason, "用途变更历史")
        XCTAssertEqual(facts.first?.recordedAt, first.receivedAt)
        XCTAssertEqual(sheep.revision, 2)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()), 2)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudStreamState>()), 2)
        let farmState = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first
        )
        XCTAssertEqual(farmState.lastAppliedEventSequence, 2)
    }

    func testMultiStreamBusinessEventReplaysTypedPayloadOnlyOnce() throws {
        let fixture = try makeFixture()
        let commandID = UUID()
        let primaryRecordID = UUID()
        let payload = ESheepCloudCommandPayloadV2.fact(.recordWeight(
            sheepID: fixture.sharedSheepID,
            kilogramsText: "43.0",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            note: "多流事件"
        ))
        let sourceDigest = String(repeating: "a", count: 64)
        let emptyDigest = try ESheepCloudCanonicalCodec.digest(
            [String: ESheepCloudValueV2]()
        )

        func event(
            sequence: Int64,
            stream: ESheepCloudStreamReferenceV2,
            digest: String
        ) -> ESheepCloudEventEnvelopeV2 {
            let afterDigest = try! ESheepCloudCanonicalCodec.digest(
                ESheepCloudNonFieldStreamStateV2(
                    eventCount: 1,
                    lastCommandDigest: sourceDigest,
                    lastCommandID: commandID.uuidString.lowercased(),
                    lastCommandKind: payload.kind
                )
            )
            return ESheepCloudEventEnvelopeV2(
                protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                farmID: fixture.farmID,
                farmGeneration: fixture.generation,
                eventSequence: sequence,
                eventID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012lld", sequence))!,
                commandID: commandID,
                sourceCommandDigest: sourceDigest,
                stream: stream,
                payload: .businessCommandApplied(
                    commandKind: payload.kind,
                    payload: payload
                ),
                affectedFields: [],
                eventBodyDigest: String(repeating: "b", count: 64),
                beforeDigest: emptyDigest,
                afterDigest: afterDigest,
                actorAccountID: fixture.accountID,
                sourceDeviceID: fixture.deviceID,
                sourceDeviceSequence: 1,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_001),
                eventDigest: digest
            )
        }

        let primaryStream = ESheepCloudStreamReferenceV2(
            type: "weight",
            id: primaryRecordID
        )
        let semanticStream = ESheepCloudStreamReferenceV2(
            type: "sheepLocation",
            id: fixture.sharedSheepID
        )
        let firstUnsigned = event(sequence: 1, stream: primaryStream, digest: "")
        let first = event(
            sequence: 1,
            stream: primaryStream,
            digest: ESheepCloudEventDigestV2.hex(for: firstUnsigned)
        )
        let secondUnsigned = event(sequence: 2, stream: semanticStream, digest: "")
        let second = event(
            sequence: 2,
            stream: semanticStream,
            digest: ESheepCloudEventDigestV2.hex(for: secondUnsigned)
        )

        _ = try ESheepCloudEventReducer.apply(first, context: fixture.context)
        _ = try ESheepCloudEventReducer.apply(second, context: fixture.context)

        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<WeightRecord>()), 1)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()), 2)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ESheepCloudStreamState>()), 2)
        let farmState = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first
        )
        XCTAssertEqual(farmState.lastAppliedEventSequence, 2)
    }

    func testPhotoRegistrationEventWithIncompleteMetadataFailsClosed() throws {
        let fixture = try makeFixture()
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let event = try makePhotoRegistrationEvent(
            fixture: fixture,
            capturedAt: capturedAt,
            metadata: [
                "mimeType": "image/jpeg",
                "capturedAtMillis": "1800000000000",
            ]
        )

        XCTAssertThrowsError(
            try ESheepCloudEventReducer.apply(event, context: fixture.context)
        )
        XCTAssertEqual(
            try fixture.context.fetchCount(FetchDescriptor<PhotoAssetRecord>()),
            0
        )
        XCTAssertEqual(
            try fixture.context.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()),
            0
        )
        let state = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first
        )
        XCTAssertEqual(state.lastAppliedEventSequence, 0)
    }

    func testCheckpointPlusTailMatchesReplayAndDoesNotReapplyCoveredPrefix() async throws {
        let fixture = try makeFixture()
        fixture.context.insert(FarmRecord(id: fixture.farmID, ownerAccountID: fixture.accountID, name: "检查点增量"))
        fixture.context.insert(SheepRecord(id: fixture.sharedSheepID, farmID: fixture.farmID, earTag: "TAIL-1",
            breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .distantPast))
        let first = try makeProfileNoteEvent(fixture: fixture, note: "检查点内")
        let tail = try makeProfileNoteEvent(fixture: fixture, note: "检查点后", sequence: 2, previousNote: "检查点内")
        let commandID = UUID(), recordID = UUID(), eventID = UUID()
        let recordedAt = Date(timeIntervalSince1970: 1_800_000_001)
        let weightPayload = ESheepCloudCommandPayloadV2.fact(.recordWeight(sheepID: fixture.sharedSheepID,
            kilogramsText: "42.5", occurredAt: recordedAt.addingTimeInterval(-1), note: "增量称重"))
        let sourceDigest = String(repeating: "e", count: 64)
        let afterDigest = try ESheepCloudCanonicalCodec.digest(ESheepCloudNonFieldStreamStateV2(eventCount: 1,
            lastCommandDigest: sourceDigest, lastCommandID: commandID.uuidString.lowercased(), lastCommandKind: weightPayload.kind))
        let beforeDigest = try ESheepCloudCanonicalCodec.digest([String: ESheepCloudValueV2]())
        func weightEvent(digest: String) -> ESheepCloudEventEnvelopeV2 {
            .init(protocolVersion: ESheepCloudProtocolV2.protocolVersion, schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                farmID: fixture.farmID, farmGeneration: fixture.generation, eventSequence: 3, eventID: eventID,
                commandID: commandID, sourceCommandDigest: sourceDigest, stream: .init(type: "weight", id: recordID),
                payload: .businessCommandApplied(commandKind: weightPayload.kind, payload: weightPayload), affectedFields: [],
                eventBodyDigest: String(repeating: "d", count: 64), beforeDigest: beforeDigest, afterDigest: afterDigest,
                actorAccountID: fixture.accountID, sourceDeviceID: fixture.deviceID, sourceDeviceSequence: 3,
                occurredAt: recordedAt.addingTimeInterval(-1), receivedAt: recordedAt, eventDigest: digest)
        }
        let weight = weightEvent(digest: ESheepCloudEventDigestV2.hex(for: weightEvent(digest: "")))
        _ = try ESheepCloudEventReducer.apply(first, context: fixture.context)
        let root = FileManager.default.temporaryDirectory.appending(path: "CheckpointTail-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try ESheepCloudCheckpointArchive.export(farmID: fixture.farmID, context: fixture.context, directory: root.appending(path: "archive"))
        _ = try ESheepCloudEventReducer.apply(tail, context: fixture.context)
        _ = try ESheepCloudEventReducer.apply(weight, context: fixture.context)
        let importer = try ESheepCloudCheckpointImporter(manifest: manifest, accountID: fixture.accountID, storeURL: root.appending(path: "import.store"))
        for chunk in manifest.chunks {
            try await importer.importChunk(Data(contentsOf: root.appending(path: "archive").appending(path: String(format: "%05d.json.gz", chunk.index))), index: chunk.index)
        }
        try await importer.finish()
        try await importer.applyRecentPage(.init(events: [first, tail, weight], cloudHead: 3, hasMore: false))
        for adapter in ESheepCloudCheckpointRegistry.adapters where adapter.disposition == .transfer {
            let actual = try await importer.records(model: adapter.name)
            XCTAssertEqual(actual, try adapter.exportRows(fixture.farmID, fixture.context), adapter.name)
        }
        let head = try await importer.currentHead()
        XCTAssertEqual(head, 3)
    }

    func testDeletedBatchAndMembershipSurviveFreshCheckpointImport() async throws {
        let fixture = try makeFixture()
        let farm = FarmRecord(id: fixture.farmID, ownerAccountID: fixture.accountID, name: "删除批次检查点")
        let sheep = SheepRecord(
            id: fixture.sharedSheepID,
            farmID: fixture.farmID,
            earTag: "CHECKPOINT-DELETE-1",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        fixture.context.insert(farm)
        fixture.context.insert(sheep)
        let farmState = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first
        )
        farmState.integrityState = .passed
        farmState.activityState = .active
        let batchID = UUID()
        let membershipID = UUID()
        let deletedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let batch = ProductionBatchRecord(
            id: batchID,
            farmID: fixture.farmID,
            name: "已删除批次",
            purpose: "育肥",
            startedAt: sheep.enteredAt,
            note: "检查点新安装同步"
        )
        let membership = BatchMembershipRecord(
            id: membershipID,
            farmID: fixture.farmID,
            batchID: batch.id,
            sheepID: sheep.id,
            joinedAt: sheep.enteredAt
        )
        batch.deletedAt = deletedAt
        membership.deletedAt = deletedAt
        fixture.context.insert(batch)
        fixture.context.insert(membership)
        for (entityType, entityID) in [
            (CloudEntityType.batchMembership, membership.id),
            (.productionBatch, batch.id),
        ] {
            let tombstone = TombstoneRecord(
                farmID: fixture.farmID,
                entityType: entityType.rawValue,
                entityID: entityID,
                deletedByAccountID: fixture.accountID,
                reason: "检查点删除同步"
            )
            tombstone.deletedAt = deletedAt
            fixture.context.insert(tombstone)
        }
        try fixture.context.save()
        XCTAssertNil(sheep.deletedAt)

        let root = FileManager.default.temporaryDirectory
            .appending(path: "DeletedBatchCheckpoint-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveDirectory = root.appending(path: "archive", directoryHint: .isDirectory)
        let manifest = try ESheepCloudCheckpointArchive.export(
            farmID: fixture.farmID,
            context: fixture.context,
            directory: archiveDirectory
        )
        let importer = try ESheepCloudCheckpointImporter(
            manifest: manifest,
            accountID: fixture.accountID,
            storeURL: root.appending(path: "fresh-install.store")
        )
        for chunk in manifest.chunks {
            let name = String(format: "%05d.json.gz", chunk.index)
            try await importer.importChunk(
                Data(contentsOf: archiveDirectory.appending(path: name)),
                index: chunk.index
            )
        }
        try await importer.finish()

        for model in ["ProductionBatchRecord", "BatchMembershipRecord", "TombstoneRecord", "SheepRecord"] {
            let adapter = try XCTUnwrap(
                ESheepCloudCheckpointRegistry.adapters.first { $0.name == model }
            )
            let importedRows = try await importer.records(model: model)
            XCTAssertEqual(
                importedRows,
                try adapter.exportRows(fixture.farmID, fixture.context),
                "fresh checkpoint import must preserve \(model)"
            )
        }
        let importedBatchRows = try await importer.records(model: "ProductionBatchRecord")
        let importedMembershipRows = try await importer.records(model: "BatchMembershipRecord")
        let importedTombstones = try await importer.records(model: "TombstoneRecord")
        let importedSheepRows = try await importer.records(model: "SheepRecord")
        let importedBatch = try XCTUnwrap(importedBatchRows.first)
        let importedMembership = try XCTUnwrap(importedMembershipRows.first)
        let importedSheep = try XCTUnwrap(importedSheepRows.first)
        guard case .number? = importedBatch.values["deletedAt"],
              case .number? = importedMembership.values["deletedAt"],
              case .null? = importedSheep.values["deletedAt"] else {
            return XCTFail("checkpoint import must retain both deletion markers and the living sheep")
        }
        XCTAssertEqual(importedTombstones.count, 2)
        let head = try await importer.currentHead()
        XCTAssertEqual(head, 0)
    }

    func testFieldEventIsAppliedExactlyOnceWithVerifiedStreamDigest() throws {
        let fixture = try makeFixture()
        let farm = FarmRecord(
            id: fixture.farmID,
            ownerAccountID: fixture.accountID,
            name: "测试牧场"
        )
        let sheep = SheepRecord(
            id: fixture.sharedSheepID,
            farmID: fixture.farmID,
            earTag: "DH054",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        fixture.context.insert(farm)
        fixture.context.insert(sheep)
        let event = try makeProfileNoteEvent(fixture: fixture, note: "云端备注")

        let first = try ESheepCloudEventReducer.apply(event, context: fixture.context)
        let duplicate = try ESheepCloudEventReducer.apply(event, context: fixture.context)

        XCTAssertFalse(first.wasAlreadyApplied)
        XCTAssertTrue(duplicate.wasAlreadyApplied)
        XCTAssertEqual(sheep.note, "云端备注")
        XCTAssertEqual(
            try fixture.context.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()),
            1
        )
        let state = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first
        )
        XCTAssertEqual(state.lastAppliedEventSequence, 1)
        let stream = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<ESheepCloudStreamState>()).first
        )
        let versions = try ESheepCloudCanonicalCodec.decode(
            [ESheepCloudFieldVersionEntryV2].self,
            from: stream.fieldVersionsData
        )
        XCTAssertEqual(versions.first?.deviceSequence, 1)
    }

    func testKeepingCloudValuePreservesOriginalFieldAuthorMetadata() throws {
        let fixture = try makeFixture()
        let farm = FarmRecord(
            id: fixture.farmID,
            ownerAccountID: fixture.accountID,
            name: "测试牧场"
        )
        let sheep = SheepRecord(
            id: fixture.sharedSheepID,
            farmID: fixture.farmID,
            earTag: "DH054",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        sheep.note = "云端备注"
        fixture.context.insert(farm)
        fixture.context.insert(sheep)

        let originalAccountID = UUID()
        let originalDeviceID = UUID()
        let originalOccurredAt = Date(timeIntervalSince1970: 1_799_999_900)
        let originalReceivedAt = Date(timeIntervalSince1970: 1_799_999_901)
        let value = ESheepCloudValueV2.string("云端备注")
        let canonical = ["note": value]
        let contentDigest = try ESheepCloudCanonicalCodec.digest(canonical)
        let stream = ESheepCloudStreamState(
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            streamType: "sheepProfile",
            streamID: fixture.sharedSheepID,
            streamVersion: 1,
            fieldVersionsData: try ESheepCloudCanonicalCodec.encode([
                ESheepCloudFieldVersionEntryV2(
                    field: "note",
                    version: 1,
                    valueDigest: value.digest,
                    value: value,
                    accountID: originalAccountID,
                    deviceID: originalDeviceID,
                    deviceSequence: 7,
                    occurredAt: originalOccurredAt,
                    receivedAt: originalReceivedAt
                ),
            ]),
            canonicalStateData: try ESheepCloudCanonicalCodec.encode(canonical),
            contentDigest: contentDigest
        )
        fixture.context.insert(stream)

        let eventID = UUID()
        let commandID = UUID()
        let sourceDigest = String(repeating: "b", count: 64)
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_001)
        func event(digest: String) -> ESheepCloudEventEnvelopeV2 {
            ESheepCloudEventEnvelopeV2(
                protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                farmID: fixture.farmID,
                farmGeneration: fixture.generation,
                eventSequence: 1,
                eventID: eventID,
                commandID: commandID,
                sourceCommandDigest: sourceDigest,
                stream: .init(type: "sheepProfile", id: fixture.sharedSheepID),
                payload: .attentionResolved(
                    attentionID: UUID(),
                    field: "note",
                    choice: .keepCloud,
                    chosenValue: value
                ),
                affectedFields: ["note"],
                eventBodyDigest: String(repeating: "d", count: 64),
                beforeDigest: contentDigest,
                afterDigest: contentDigest,
                actorAccountID: fixture.accountID,
                sourceDeviceID: fixture.deviceID,
                sourceDeviceSequence: 99,
                occurredAt: receivedAt,
                receivedAt: receivedAt,
                eventDigest: digest
            )
        }
        let unsigned = event(digest: "")
        let outcome = try ESheepCloudEventReducer.apply(
            event(digest: ESheepCloudEventDigestV2.hex(for: unsigned)),
            context: fixture.context
        )
        XCTAssertEqual(outcome.eventSequence, unsigned.eventSequence)
        XCTAssertFalse(outcome.wasAlreadyApplied)

        let persisted = try ESheepCloudCanonicalCodec.decode(
            [ESheepCloudFieldVersionEntryV2].self,
            from: stream.fieldVersionsData
        ).first
        XCTAssertEqual(persisted?.version, 1)
        XCTAssertEqual(persisted?.accountID, originalAccountID)
        XCTAssertEqual(persisted?.deviceID, originalDeviceID)
        XCTAssertEqual(persisted?.deviceSequence, 7)
        XCTAssertEqual(persisted?.occurredAt, originalOccurredAt)
        XCTAssertEqual(persisted?.receivedAt, originalReceivedAt)
        XCTAssertEqual(stream.streamVersion, 1)
    }

    func testCloudViewStateNeverClaimsSafeBeforeHeadAndIntegrityAreVerified() {
        let state = ESheepCloudViewState()
        let notCaughtUp = ESheepCloudLocalCycleSnapshot(
            farmGeneration: 2,
            lastAppliedEventSequence: 4,
            cloudHead: 5,
            readyCommands: [],
            commandsAwaitingStatus: [],
            readyAttentionResolutions: [],
            attentionResolutionsAwaitingStatus: [],
            pendingCount: 0,
            attentionCount: 0,
            rejectedCount: 0,
            integrityState: .passed,
            activityState: .active,
            lastSafeSaveAt: nil
        )

        state.update(from: notCaughtUp)
        XCTAssertEqual(state.presentation, .checking)
        XCTAssertEqual(state.statusTitle, "正在检查牧场资料是否完整")

        let integrityHold = ESheepCloudLocalCycleSnapshot(
            farmGeneration: 2,
            lastAppliedEventSequence: 5,
            cloudHead: 5,
            readyCommands: [],
            commandsAwaitingStatus: [],
            readyAttentionResolutions: [],
            attentionResolutionsAwaitingStatus: [],
            pendingCount: 0,
            attentionCount: 0,
            rejectedCount: 0,
            integrityState: .failed,
            activityState: .integrityHold,
            lastSafeSaveAt: nil
        )
        state.update(from: integrityHold)
        XCTAssertEqual(state.presentation, .partiallyUnsaved)

        let safelySaved = ESheepCloudLocalCycleSnapshot(
            farmGeneration: 2,
            lastAppliedEventSequence: 5,
            cloudHead: 5,
            readyCommands: [],
            commandsAwaitingStatus: [],
            readyAttentionResolutions: [],
            attentionResolutionsAwaitingStatus: [],
            pendingCount: 0,
            attentionCount: 0,
            rejectedCount: 0,
            integrityState: .passed,
            activityState: .active,
            lastSafeSaveAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        state.update(from: safelySaved)
        XCTAssertEqual(state.presentation, .safelySaved)
        XCTAssertEqual(state.statusTitle, "已安全保存")
    }

    func testCloudViewStateKeepsPhotoTransfersOutOfSafeState() {
        let state = ESheepCloudViewState()
        let pendingPhoto = ESheepCloudLocalCycleSnapshot(
            farmGeneration: 2,
            lastAppliedEventSequence: 5,
            cloudHead: 5,
            readyCommands: [],
            commandsAwaitingStatus: [],
            readyAttentionResolutions: [],
            attentionResolutionsAwaitingStatus: [],
            pendingCount: 0,
            attentionCount: 0,
            rejectedCount: 0,
            integrityState: .passed,
            activityState: .active,
            lastSafeSaveAt: Date(timeIntervalSince1970: 1_800_000_000),
            pendingAssetCount: 2
        )

        state.update(from: pendingPhoto)
        XCTAssertEqual(state.presentation, .saving(2))
        XCTAssertEqual(state.statusTitle, "正在保存 2 项")

        let failedPhoto = ESheepCloudLocalCycleSnapshot(
            farmGeneration: 2,
            lastAppliedEventSequence: 5,
            cloudHead: 5,
            readyCommands: [],
            commandsAwaitingStatus: [],
            readyAttentionResolutions: [],
            attentionResolutionsAwaitingStatus: [],
            pendingCount: 0,
            attentionCount: 0,
            rejectedCount: 0,
            integrityState: .passed,
            activityState: .active,
            lastSafeSaveAt: Date(timeIntervalSince1970: 1_800_000_000),
            failedAssetCount: 1
        )

        state.update(from: failedPhoto)
        XCTAssertEqual(state.presentation, .partiallyUnsaved)
        XCTAssertEqual(state.statusTitle, "部分内容尚未保存，请稍后再试")
    }

    func testFinishCycleNeverMarksSafeWhileAttentionNeedsAChoice() async throws {
        let fixture = try makeFixture()
        let attention = makeAttention(
            id: UUID(),
            commandID: UUID(),
            deviceValue: .identifier(UUID()),
            cloudValue: .identifier(UUID()),
            fixture: fixture
        )
        fixture.context.insert(attention)
        try fixture.context.save()

        let store = ESheepCloudLocalStore(container: fixture.container)
        let report = try await store.finishCycle(
            farmID: fixture.farmID,
            accountID: fixture.accountID,
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )

        XCTAssertEqual(report.pendingCount, 1)
        XCTAssertEqual(report.attentionCount, 1)
        XCTAssertNil(report.lastSafeSaveAt)

        let verification = ModelContext(fixture.container)
        let state = try XCTUnwrap(
            verification.fetch(FetchDescriptor<ESheepCloudFarmState>()).first
        )
        XCTAssertNil(state.lastSafeSaveAt)
    }

    func testV1MigrationCreatesVerifiedBackupAndClassifiesOperationsWithoutReplayingThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ESheepCloudMigrationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Keep the source container and all verification contexts scoped.  The
        // backup intentionally copies SQLite sidecars, so the temporary root
        // must not be removed while a context still owns the source file.
        do {
        let storeURL = root.appending(path: "source.store")
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudMigrationSource",
            url: storeURL
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let accountID = UUID()
        let fallbackDeviceID = UUID()
        let sheepID = UUID()
        context.insert(FarmRecord(
            id: farmID,
            ownerAccountID: accountID,
            name: "待升级牧场"
        ))
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .supabase,
            authorityGeneration: 1
        ))

        func insert(
            id: UUID = UUID(),
            command: FarmCommand,
            entityType: CloudEntityType,
            entityID: UUID,
            sequence: Int64,
            status: OutboxStatus,
            avatar: SheepAvatarPhotoUpdate? = nil
        ) throws {
            let payload = try FarmCommandCloudPayloadEncoder.encode(
                command,
                sheepAvatarUpdate: avatar
            )
            let operation = DomainOperation(
                id: id,
                farmID: farmID,
                accountID: accountID,
                kind: command.operationKind,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
                summary: command.summary,
                entityType: entityType.rawValue,
                entityID: entityID,
                payload: payload,
                sourceRequestID: id
            )
            operation.modifiedByDeviceID = fallbackDeviceID
            context.insert(operation)
            let outbox = OutboxItem(
                farmID: farmID,
                accountID: accountID,
                operationID: id,
                entityType: entityType.rawValue,
                entityID: entityID,
                payloadDigest: operation.payloadDigest,
                deliveryProvider: .supabase,
                authorityGeneration: 1
            )
            outbox.statusRawValue = status.rawValue
            context.insert(outbox)
            context.insert(FarmOperationSequenceRecord(
                farmID: farmID,
                operationID: id,
                clientSequence: sequence
            ))
        }

        let weightID = UUID()
        try insert(
            id: weightID,
            command: .recordWeight(
                sheepID: sheepID,
                kilogramsText: "42.5",
                occurredAt: Date(timeIntervalSince1970: 1_800_000_001),
                note: ""
            ),
            entityType: .weight,
            entityID: weightID,
            sequence: 1,
            status: .pending
        )
        let avatarOperationID = UUID()
        let avatarAssetID = UUID()
        try insert(
            id: avatarOperationID,
            command: .updateSheepProfile(
                sheepID: sheepID,
                earTag: "DH054",
                breed: "湖羊",
                sex: .ewe,
                birthAt: nil,
                note: ""
            ),
            entityType: .sheep,
            entityID: sheepID,
            sequence: 2,
            status: .blockedConflict,
            avatar: SheepAvatarPhotoUpdate(photoAssetID: avatarAssetID)
        )
        let unknownID = UUID()
        try insert(
            id: unknownID,
            command: .addNote(
                sheepID: sheepID,
                penID: nil,
                text: "等待旧回执",
                occurredAt: Date(timeIntervalSince1970: 1_800_000_003)
            ),
            entityType: .note,
            entityID: unknownID,
            sequence: 3,
            status: .awaitingConfirmation
        )
        let confirmedID = UUID()
        try insert(
            id: confirmedID,
            command: .addNote(
                sheepID: sheepID,
                penID: nil,
                text: "已确认",
                occurredAt: Date(timeIntervalSince1970: 1_800_000_004)
            ),
            entityType: .note,
            entityID: confirmedID,
            sequence: 4,
            status: .confirmed
        )
        try context.save()

        let coordinator = ESheepCloudMigrationCoordinator(
            container: container,
            storeURL: storeURL,
            applicationSupportURL: root
        )
        let report = try await coordinator.prepareV1Migration(
            farmID: farmID,
            targetFarmGeneration: 2,
            fallbackDeviceID: fallbackDeviceID,
            now: Date(timeIntervalSince1970: 1_800_000_100)
        )

        XCTAssertEqual(report.convertibleIntentCount, 1)
        XCTAssertEqual(report.attentionCount, 1)
        XCTAssertEqual(report.unknownResultCount, 1)
        XCTAssertEqual(report.acceptedReceiptCount, 1)
        XCTAssertEqual(report.forwardRepairCount, 0)
        XCTAssertEqual(report.backupManifestDigest.count, 64)

        let verification = ModelContext(container)
        let state = try XCTUnwrap(
            verification.fetch(FetchDescriptor<ESheepCloudMigrationState>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(state.phase, .shadowConverted)
        XCTAssertEqual(state.sourceStoreQuickCheck, "ok")
        XCTAssertEqual(state.sourceBackupManifestDigest, report.backupManifestDigest)
        let profile = try XCTUnwrap(
            verification.fetch(FetchDescriptor<FarmStorageProfile>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(profile.mode, .supabase)
        XCTAssertEqual(profile.transitionState, .readOnlyMigration)

        let plan = try ESheepCloudCanonicalCodec.decode(
            ESheepCloudV1MappingPlanV2.self,
            from: state.mappingData
        )
        try plan.validateDigest()
        XCTAssertEqual(
            plan.operations.first(where: { $0.id == weightID })?.disposition,
            .convertAfterSnapshot
        )
        let avatarMapping = try XCTUnwrap(
            plan.operations.first(where: { $0.id == avatarOperationID })
        )
        XCTAssertEqual(avatarMapping.disposition, .createServerAttention)
        XCTAssertEqual(avatarMapping.attentionFieldDisplayName, "头像")
        XCTAssertEqual(avatarMapping.attentionDeviceValue, .identifier(avatarAssetID))
        XCTAssertEqual(
            plan.operations.first(where: { $0.id == unknownID })?.disposition,
            .queryV1Result
        )
        XCTAssertEqual(
            plan.operations.first(where: { $0.id == confirmedID })?.disposition,
            .mapAcceptedReceipt
        )
        XCTAssertEqual(
            try verification.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>()),
            0,
            "preflight must not submit or materialize a V2 intent"
        )

        let backupRoot = root.appending(
            path: report.backupDirectoryRelativePath,
            directoryHint: .isDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backupRoot.appending(path: "verified.store").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backupRoot.appending(path: "raw/source.store").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backupRoot.appending(path: "manifest.json").path
        ))

        let parityReport = ESheepCloudMigrationParityReportV2(
            formatVersion: 1,
            farmID: farmID,
            sourceGeneration: 1,
            targetGeneration: 2,
            sourceManifestDigest: String(repeating: "a", count: 64),
            targetManifestDigest: String(repeating: "a", count: 64),
            targetProjectionDigest: String(repeating: "b", count: 64),
            checks: [
                .init(
                    key: "sheep",
                    passed: true,
                    sourceCount: 1,
                    targetCount: 1,
                    sourceDigest: String(repeating: "c", count: 64),
                    targetDigest: String(repeating: "c", count: 64)
                ),
            ],
            allChecksPassed: true
        )
        XCTAssertThrowsError(try coordinator.recordVerifiedParity(
            farmID: farmID,
            report: parityReport,
            parityDigest: String(repeating: "d", count: 64)
        ))
        let parityDigest = try ESheepCloudCanonicalCodec.digest(parityReport)
        try coordinator.recordVerifiedParity(
            farmID: farmID,
            report: parityReport,
            parityDigest: parityDigest
        )
        let parityContext = ModelContext(container)
        let parityState = try XCTUnwrap(
            parityContext.fetch(FetchDescriptor<ESheepCloudMigrationState>())
                .first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(parityState.phase, .parityVerified)
        XCTAssertEqual(parityState.sourceManifestDigest, parityReport.sourceManifestDigest)
        XCTAssertEqual(parityState.targetManifestDigest, parityReport.targetManifestDigest)
        XCTAssertEqual(parityState.targetProjectionDigest, parityReport.targetProjectionDigest)
        XCTAssertEqual(parityState.parityDigest, parityDigest)
        }
    }

    func testV1MigrationFailsClosedWhenOperationHasNoOutboxEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ESheepCloudMigrationMissingOutboxTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Keep every ModelContainer/ModelContext inside this scope.  The
        // migration backup owns a SQLite store, so removing the temporary root
        // while a context is still alive can unlink its WAL/SHM files.
        do {
            let storeURL = root.appending(path: "source.store")
            let container = try AppSchema.makeContainer(
                name: "ESheepCloudMigrationMissingOutbox",
                url: storeURL
            )
            let context = ModelContext(container)
            let farmID = UUID()
            let accountID = UUID()
            let deviceID = UUID()
            let operationID = UUID()
            let sheepID = UUID()
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "无发送记录牧场"))
            context.insert(FarmStorageProfile(
                farmID: farmID,
                mode: .supabase,
                authorityGeneration: 1
            ))
            let payload = try FarmCommandCloudPayloadEncoder.encode(
                .addNote(
                    sheepID: sheepID,
                    penID: nil,
                    text: "没有可核对的旧发送记录",
                    occurredAt: Date(timeIntervalSince1970: 1_800_000_001)
                )
            )
            let operation = DomainOperation(
                id: operationID,
                farmID: farmID,
                accountID: accountID,
                kind: .addNote,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_001),
                summary: "待核对的旧备注",
                entityType: CloudEntityType.note.rawValue,
                entityID: operationID,
                payload: payload,
                sourceRequestID: operationID
            )
            operation.modifiedByDeviceID = deviceID
            context.insert(operation)
            context.insert(FarmOperationSequenceRecord(
                farmID: farmID,
                operationID: operationID,
                clientSequence: 1
            ))
            // Deliberately do not insert OutboxItem: an operation row alone cannot
            // prove that the old cloud accepted (or even received) the request.
            try context.save()

            let coordinator = ESheepCloudMigrationCoordinator(
                container: container,
                storeURL: storeURL,
                applicationSupportURL: root
            )
            let report = try await coordinator.prepareV1Migration(
                farmID: farmID,
                targetFarmGeneration: 2,
                fallbackDeviceID: deviceID,
                now: Date(timeIntervalSince1970: 1_800_000_100)
            )
            XCTAssertEqual(report.acceptedReceiptCount, 0)
            XCTAssertEqual(report.forwardRepairCount, 1)
            let verification = ModelContext(container)
            let state = try XCTUnwrap(
                verification.fetch(FetchDescriptor<ESheepCloudMigrationState>())
                    .first(where: { $0.farmID == farmID })
            )
            XCTAssertEqual(state.phase, .forwardRepairRequired)
            let plan = try ESheepCloudCanonicalCodec.decode(
                ESheepCloudV1MappingPlanV2.self,
                from: state.mappingData
            )
            XCTAssertEqual(
                plan.operations.first(where: { $0.id == operationID })?.disposition,
                .forwardRepairRequired
            )
            do {
                _ = try await coordinator.prepareV1Migration(
                    farmID: farmID,
                    targetFarmGeneration: 2,
                    fallbackDeviceID: deviceID
                )
                XCTFail("a durable forward-repair state must not be prepared again")
            } catch {
                guard let migrationError = error as? ESheepCloudMigrationError else {
                    return XCTFail("expected a durable forward-repair stop, got \(error)")
                }
                guard case .forwardRepairRequired = migrationError else {
                    return XCTFail("expected a durable forward-repair stop, got \(migrationError)")
                }
            }
        }
    }

    private func makeFixture(reconcilesSequence: Bool = true) throws -> Fixture {
        let container = try AppSchema.makeContainer(
            name: "ESheepCloudV2Tests-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let deviceID = UUID()
        let sequenceKey = "esheep-v2-sequence-\(farmID.uuidString.lowercased())-\(deviceID.uuidString.lowercased())"
        addTeardownBlock { try SecureAccountStore.remove(account: sequenceKey) }
        if reconcilesSequence {
            // An active test farm represents a validated cloud status. Seed the
            // same device watermark required by the production writer.
            try ESheepCloudSequenceWatermark.reconcile(farmID: farmID, deviceID: deviceID, floor: 0)
        }
        let generation = 2
        let state = ESheepCloudFarmState(
            farmID: farmID,
            farmGeneration: generation,
            activityState: .active
        )
        state.integrityState = .passed
        context.insert(state)
        return Fixture(
            container: container,
            context: context,
            farmID: farmID,
            generation: generation,
            accountID: UUID(),
            deviceID: deviceID
        )
    }

    private func verifiedAsset(
        id: UUID,
        farmID: UUID,
        generation: Int
    ) -> ESheepCloudAssetState {
        let asset = ESheepCloudAssetState(
            assetID: id,
            farmID: farmID,
            farmGeneration: generation,
            sheepID: nil,
            contentSHA256: String(repeating: "a", count: 64),
            metadataDigest: String(repeating: "b", count: 64)
        )
        asset.avatarStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
        return asset
    }

    private func photoMetadata(capturedAt: Date?) -> [String: String] {
        var metadata = [
            "mimeType": "image/jpeg",
            "sourceSHA256": String(repeating: "d", count: 64),
            "sourcePixelWidth": "2000",
            "sourcePixelHeight": "1500",
            "cloudPixelWidth": "1600",
            "cloudPixelHeight": "1200",
        ]
        if let capturedAt {
            metadata["capturedAtMillis"] = String(
                Int64((capturedAt.timeIntervalSince1970 * 1_000).rounded())
            )
        }
        return metadata
    }

    private func makePhotoRegistrationEvent(
        fixture: Fixture,
        capturedAt: Date?,
        metadata: [String: String]
    ) throws -> ESheepCloudEventEnvelopeV2 {
        let assetID = UUID()
        let commandID = UUID()
        let sourceCommandDigest = String(repeating: "e", count: 64)
        let stream = ESheepCloudStreamReferenceV2(type: "photoAsset", id: assetID)
        let payload = ESheepCloudCommandPayloadV2.photo(.register(
            assetID: assetID,
            sheepID: fixture.sharedSheepID,
            capturedAt: capturedAt,
            mimeType: "image/jpeg",
            contentSHA256: String(repeating: "a", count: 64),
            metadata: metadata,
            metadataDigest: try ESheepCloudCanonicalCodec.digest(metadata),
            thumbnailSHA256: String(repeating: "b", count: 64),
            avatarSHA256: String(repeating: "c", count: 64),
            originalSHA256: String(repeating: "a", count: 64),
            thumbnailByteCount: 11,
            avatarByteCount: 22,
            originalByteCount: 33
        ))
        let afterDigest = try ESheepCloudCanonicalCodec.digest(
            ESheepCloudNonFieldStreamStateV2(
                eventCount: 1,
                lastCommandDigest: sourceCommandDigest,
                lastCommandID: commandID.uuidString.lowercased(),
                lastCommandKind: payload.kind
            )
        )
        let occurredAt = capturedAt ?? Date(timeIntervalSince1970: 1_800_000_000)
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_001)
        func envelope(digest: String) -> ESheepCloudEventEnvelopeV2 {
            ESheepCloudEventEnvelopeV2(
                protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                farmID: fixture.farmID,
                farmGeneration: fixture.generation,
                eventSequence: 1,
                eventID: UUID(uuidString: "50000000-0000-4000-8000-000000000005")!,
                commandID: commandID,
                sourceCommandDigest: sourceCommandDigest,
                stream: stream,
                payload: .businessCommandApplied(
                    commandKind: payload.kind,
                    payload: payload
                ),
                affectedFields: [],
                eventBodyDigest: String(repeating: "d", count: 64),
                beforeDigest: try! ESheepCloudCanonicalCodec.digest(
                    [String: ESheepCloudValueV2]()
                ),
                afterDigest: afterDigest,
                actorAccountID: fixture.accountID,
                sourceDeviceID: fixture.deviceID,
                sourceDeviceSequence: 1,
                occurredAt: occurredAt,
                receivedAt: receivedAt,
                eventDigest: digest
            )
        }
        let unsigned = envelope(digest: "")
        return envelope(digest: ESheepCloudEventDigestV2.hex(for: unsigned))
    }

    private func makeAttention(
        id: UUID,
        commandID: UUID,
        deviceValue: ESheepCloudValueV2,
        cloudValue: ESheepCloudValueV2,
        fixture: Fixture
    ) -> ESheepCloudAttentionItem {
        ESheepCloudAttentionItem(
            id: id,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            commandID: commandID,
            streamType: "sheepAvatar",
            streamID: fixture.sharedSheepID,
            recordType: "sheepAvatar",
            recordID: fixture.sharedSheepID,
            recordDisplayName: "DH054",
            fieldKey: "avatar",
            fieldDisplayName: "头像",
            deviceValueData: try! ESheepCloudCanonicalCodec.encode(deviceValue),
            cloudValueData: try! ESheepCloudCanonicalCodec.encode(cloudValue),
            baseValueDigest: ESheepCloudValueV2.null.digest,
            deviceAccountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceOccurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            explanation: "两边修改了同一个字段。"
        )
    }

    private func stageAvatar(
        assetID: UUID?,
        sequence: Int64,
        fixture: Fixture
    ) throws -> ESheepCloudPendingIntent {
        let commandID = UUID()
        return try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(
                sheepID: fixture.sharedSheepID,
                photoAssetID: assetID
            ),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: fixture.farmID,
            farmGeneration: fixture.generation,
            accountID: fixture.accountID,
            deviceID: fixture.deviceID,
            deviceSequence: sequence,
            context: fixture.context
        )
    }

    private func makeProfileNoteEvent(
        fixture: Fixture,
        note: String,
        sequence: Int64 = 1, previousNote: String? = nil
    ) throws -> ESheepCloudEventEnvelopeV2 {
        let changed = ESheepCloudValueV2.string(note)
        let canonical = ["note": changed]
        let common = (
            eventID: UUID(),
            commandID: UUID(),
            sourceDigest: String(repeating: "a", count: 64),
            stream: ESheepCloudStreamReferenceV2(
                type: "sheepProfile",
                id: fixture.sharedSheepID
            ),
            beforeDigest: try ESheepCloudCanonicalCodec.digest(
                previousNote.map { ["note": ESheepCloudValueV2.string($0)] } ?? [:]
            ),
            afterDigest: try ESheepCloudCanonicalCodec.digest(canonical),
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        func envelope(digest: String) -> ESheepCloudEventEnvelopeV2 {
            ESheepCloudEventEnvelopeV2(
                protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                schemaVersion: ESheepCloudProtocolV2.schemaVersion,
                farmID: fixture.farmID,
                farmGeneration: fixture.generation,
                eventSequence: sequence,
                eventID: common.eventID,
                commandID: common.commandID,
                sourceCommandDigest: common.sourceDigest,
                stream: common.stream,
                payload: .fieldsPatched(
                    stream: common.stream,
                    changes: [.init(
                        field: "note",
                        value: changed,
                        valueDigest: changed.digest,
                        fieldVersion: sequence
                    )]
                ),
                affectedFields: ["note"],
                eventBodyDigest: String(repeating: "d", count: 64),
                beforeDigest: common.beforeDigest,
                afterDigest: common.afterDigest,
                actorAccountID: fixture.accountID,
                sourceDeviceID: fixture.deviceID,
                sourceDeviceSequence: sequence,
                occurredAt: common.occurredAt,
                receivedAt: common.receivedAt,
                eventDigest: digest
            )
        }
        let unsigned = envelope(digest: "")
        return envelope(digest: ESheepCloudEventDigestV2.hex(for: unsigned))
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let farmID: UUID
        let generation: Int
        let accountID: UUID
        let deviceID: UUID
        let sharedSheepID = UUID()
    }
}

actor InitialSyncGatewayStub: ESheepCloudGateway, ESheepCloudCheckpointGateway {
    enum StubError: Error { case unexpectedCall }

    let ticket: ESheepCloudInitialSyncTicketV2
    let chunkDataByIndex: [Int: Data]
    let cancelChunkIndices: Set<Int>
    let tailEvents: [ESheepCloudEventEnvelopeV2]
    let checkpointManifest: ESheepCloudCheckpointManifest?
    let checkpointChunkDataByIndex: [Int: Data]
    private var cancelNextPull = false
    func cancelOnePull() { cancelNextPull = true }

    init(
        ticket: ESheepCloudInitialSyncTicketV2,
        chunkDataByIndex: [Int: Data] = [:],
        cancelChunkIndices: Set<Int> = [],
        tailEvents: [ESheepCloudEventEnvelopeV2] = [],
        checkpointManifest: ESheepCloudCheckpointManifest? = nil,
        checkpointChunkDataByIndex: [Int: Data] = [:]
    ) {
        self.ticket = ticket
        self.chunkDataByIndex = chunkDataByIndex
        self.cancelChunkIndices = cancelChunkIndices
        self.tailEvents = tailEvents
        self.checkpointManifest = checkpointManifest
        self.checkpointChunkDataByIndex = checkpointChunkDataByIndex
    }

    func openCheckpoint(
        farmID: UUID,
        farmGeneration: Int,
        checkpointID: UUID?
    ) async throws -> ESheepCloudCheckpointTicket {
        guard farmID == ticket.manifest.farmID,
              farmGeneration == ticket.manifest.farmGeneration else {
            throw StubError.unexpectedCall
        }
        guard let checkpointManifest else {
            return .init(manifest: nil, downloads: [])
        }
        guard checkpointManifest.farmID == farmID,
              checkpointManifest.farmGeneration == farmGeneration,
              checkpointID == nil || checkpointID == checkpointManifest.checkpointID else {
            throw StubError.unexpectedCall
        }
        let downloads = try checkpointManifest.chunks.map { chunk in
            guard let url = URL(string: "https://checkpoint.invalid/\(chunk.index)") else {
                throw StubError.unexpectedCall
            }
            return ESheepCloudCheckpointTicket.Download(index: chunk.index, url: url)
        }
        return .init(manifest: checkpointManifest, downloads: downloads)
    }

    func downloadCheckpointChunk(
        _ download: ESheepCloudCheckpointTicket.Download,
        descriptor: ESheepCloudCheckpointManifest.Chunk
    ) async throws -> Data {
        guard download.index == descriptor.index,
              checkpointManifest?.chunks.indices.contains(download.index) == true,
              let data = checkpointChunkDataByIndex[download.index] else {
            throw StubError.unexpectedCall
        }
        return data
    }

    func openInitialSync(
        farmID: UUID,
        farmGeneration: Int?
    ) async throws -> ESheepCloudInitialSyncTicketV2 {
        guard farmID == ticket.manifest.farmID,
              farmGeneration == ticket.manifest.farmGeneration else {
            throw StubError.unexpectedCall
        }
        return ticket
    }

    func downloadSnapshotChunk(
        snapshotID: UUID,
        chunkIndex: Int,
        byteOffset: Int64
    ) async throws -> Data {
        if cancelChunkIndices.contains(chunkIndex) {
            throw CancellationError()
        }
        guard snapshotID == ticket.manifest.snapshotID,
              byteOffset == 0,
              let data = chunkDataByIndex[chunkIndex] else {
            throw StubError.unexpectedCall
        }
        return data
    }

    func pullEvents(
        farmID: UUID,
        farmGeneration: Int,
        after eventSequence: Int64,
        limit: Int
    ) async throws -> ESheepCloudEventPageV2 {
        if cancelNextPull { cancelNextPull = false; throw CancellationError() }
        guard farmID == ticket.manifest.farmID,
              farmGeneration == ticket.manifest.farmGeneration,
              eventSequence >= ticket.manifest.boundaryEventSequence else {
            throw StubError.unexpectedCall
        }
        let head = tailEvents.last?.eventSequence ?? ticket.manifest.boundaryEventSequence
        let page = Array(tailEvents.filter { $0.eventSequence > eventSequence }.prefix(limit))
        return .init(events: page, cloudHead: head, hasMore: (page.last?.eventSequence ?? eventSequence) < head)
    }

    func submitCommands(
        _ commands: [ESheepCloudSignedCommandV2]
    ) async throws -> [UUID: ESheepCloudCommandResultV2] {
        throw StubError.unexpectedCall
    }

    func queryCommandStatus(
        farmID: UUID,
        commandIDs: [UUID]
    ) async throws -> [UUID: ESheepCloudCommandResultV2] {
        throw StubError.unexpectedCall
    }

    func resolveAttention(
        farmID: UUID,
        resolution: ESheepCloudAttentionResolutionV2
    ) async throws -> ESheepCloudCommandResultV2 {
        throw StubError.unexpectedCall
    }

    func prepareAssetTransfer(
        _ request: ESheepCloudAssetTransferRequestV2
    ) async throws -> ESheepCloudAssetTransferTicketV2 {
        throw StubError.unexpectedCall
    }

    func fetchCloudStatus(farmID: UUID) async throws -> ESheepCloudStatusV2 {
        throw StubError.unexpectedCall
    }
}
