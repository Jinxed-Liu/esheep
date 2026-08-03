import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class CareWorkflowTests: XCTestCase {
    func testBatchHealthCreatesStableSubjectsAndOneAuditableConsumption() throws {
        let fixture = try makeFixture()
        let pen = PenRecord(farmID: fixture.farm.id, name: "一号圈")
        let first = SheepRecord(farmID: fixture.farm.id, earTag: "E001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now.addingTimeInterval(-3_600))
        let second = SheepRecord(farmID: fixture.farm.id, earTag: "E002", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now.addingTimeInterval(-3_600))
        fixture.context.insert(pen); fixture.context.insert(first); fixture.context.insert(second)
        let lot = try receiveInventory(fixture, quantity: "20")
        let recordID = UUID()

        try fixture.service.execute(.care(.recordHealth(.init(id: recordID, batchID: UUID(), subjectIDs: [], penID: pen.id, catalogItemID: nil, kind: .vaccination, itemName: "三联四防", occurredAt: .now, note: "整圈免疫", inventoryLotID: lot.id, dosePerSubjectText: "2", unit: "毫升", route: "肌注", reminderAt: .now.addingTimeInterval(86_400)))), in: fixture.ownerContext, context: fixture.context)

        let links = try fixture.context.fetch(FetchDescriptor<HealthSubjectLink>()).filter { $0.healthRecordID == recordID }
        XCTAssertEqual(Set(links.map(\.sheepID)), Set([first.id, second.id]))
        let consumption = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<InventoryTransactionRecord>()).first { $0.sourceRecordID == recordID && $0.kind == .consumption })
        XCTAssertEqual(consumption.quantityText, "4")
        XCTAssertEqual(try FarmCareCommandHandler.inventoryBalance(lot, context: fixture.context), 16)

        first.currentPenID = nil
        XCTAssertEqual(Set(links.map(\.sheepID)), Set([first.id, second.id]), "转群不能改变健康事实的实际对象快照")
    }

    func testInsufficientInventoryRejectsWholeBatchWithoutPartialFacts() throws {
        let fixture = try makeFixture()
        let sheep = try insertEwe(fixture, earTag: "E001")
        let lot = try receiveInventory(fixture, quantity: "1")
        let draft = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: [sheep.id], penID: nil, catalogItemID: nil, kind: .treatment, itemName: "青霉素", occurredAt: .now, note: "", inventoryLotID: lot.id, dosePerSubjectText: "2", unit: "毫升", route: "肌注", reminderAt: nil)

        XCTAssertThrowsError(try fixture.service.execute(.care(.recordHealth(draft)), in: fixture.ownerContext, context: fixture.context))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).isEmpty)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<HealthSubjectLink>()).isEmpty)
        XCTAssertEqual(try FarmCareCommandHandler.inventoryBalance(lot, context: fixture.context), 1)
    }

    func testHealthCorrectionReversesOldInventoryAndRebuildsReminder() throws {
        let fixture = try makeFixture()
        let sheep = try insertEwe(fixture, earTag: "E001")
        let lot = try receiveInventory(fixture, quantity: "10")
        let oldID = UUID()
        let oldReminder = Date.now.addingTimeInterval(86_400)
        try fixture.service.execute(.care(.recordHealth(.init(id: oldID, batchID: UUID(), subjectIDs: [sheep.id], penID: nil, catalogItemID: nil, kind: .vaccination, itemName: "疫苗", occurredAt: .now, note: "", inventoryLotID: lot.id, dosePerSubjectText: "4", unit: "毫升", route: "肌注", reminderAt: oldReminder))), in: fixture.ownerContext, context: fixture.context)

        let replacementID = UUID()
        let newReminder = Date.now.addingTimeInterval(172_800)
        let replacement = CareHealthDraft(id: replacementID, batchID: UUID(), subjectIDs: [sheep.id], penID: nil, catalogItemID: nil, kind: .vaccination, itemName: "疫苗", occurredAt: .now, note: "剂量修正", inventoryLotID: lot.id, dosePerSubjectText: "2", unit: "毫升", route: "肌注", reminderAt: newReminder)
        try fixture.service.execute(.care(.correctHealth(originalID: oldID, replacement: replacement, reason: "剂量录错")), in: fixture.ownerContext, context: fixture.context)

        XCTAssertNotNil(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).first { $0.id == oldID }?.deletedAt)
        XCTAssertEqual(try FarmCareCommandHandler.inventoryBalance(lot, context: fixture.context), 8)
        let reminders = try fixture.context.fetch(FetchDescriptor<CareReminderRecord>())
        XCTAssertTrue(reminders.contains { $0.sourceEntityID == oldID && $0.deletedAt != nil })
        XCTAssertTrue(reminders.contains { $0.sourceEntityID == replacementID && $0.deletedAt == nil && $0.dueAt == newReminder })
    }

    func testBatchBreedingCreatesPerEweFactsAndPerFactSemenLedger() throws {
        let fixture = try makeFixture()
        let first = try insertEwe(fixture, earTag: "E001")
        let second = try insertEwe(fixture, earTag: "E002")
        let semen = SemenRecord(farmID: fixture.farm.id, code: "DORPER-01", breed: "杜泊", quantityText: "3")
        fixture.context.insert(semen)
        let batchID = UUID()
        let subjects = [CareReproductionSubjectDraft(eweID: first.id), CareReproductionSubjectDraft(eweID: second.id)]
        try fixture.service.execute(.care(.recordReproductionBatch(.init(id: batchID, kind: .breeding, subjects: subjects, occurredAt: .now, sireID: nil, semenID: semen.id, semenUnitsPerEweText: "1", note: "人工授精", reminderAt: .now.addingTimeInterval(45 * 86_400)))), in: fixture.ownerContext, context: fixture.context)

        let facts = try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.batchID == batchID }
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(Set(facts.map(\.eweID)), Set([first.id, second.id]))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<SemenTransactionRecord>()).filter { $0.kind == .consumption }.count, 2)
        XCTAssertEqual(try FarmCareCommandHandler.semenBalance(semen, context: fixture.context), 1)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<CareReminderRecord>()).filter { $0.kind == .pregnancyCheck }.count, 2)

        let corrected = try XCTUnwrap(facts.first)
        let replacement = CareReproductionBatchDraft(id: UUID(), kind: .breeding, subjects: [.init(eweID: corrected.eweID)], occurredAt: .now, sireID: nil, semenID: semen.id, semenUnitsPerEweText: "1", note: "修正", reminderAt: .now.addingTimeInterval(46 * 86_400))
        try fixture.service.execute(.care(.correctReproduction(originalID: corrected.id, replacement: replacement, reason: "日期录错")), in: fixture.ownerContext, context: fixture.context)
        XCTAssertNotNil(corrected.deletedAt)
        XCTAssertEqual(try FarmCareCommandHandler.semenBalance(semen, context: fixture.context), 1)
    }

    func testLambingCreatesPedigreeAndDuplicateEarTagRollsBack() throws {
        let fixture = try makeFixture()
        let ewe = try insertEwe(fixture, earTag: "E001")
        insertParityBaseline(fixture, ewe: ewe, parity: 1)
        let ram = SheepRecord(farmID: fixture.farm.id, earTag: "R001", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: nil, enteredAt: .now)
        fixture.context.insert(ram)
        let lambingID = UUID()
        try fixture.service.execute(.care(.recordLambing(.init(id: lambingID, eweID: ewe.id, occurredAt: .now, sireID: ram.id, semenID: nil, parity: 2, birthDeadCount: 0, offspring: [.init(earTag: "L001", sex: .ewe, birthWeightText: "3.2")], penID: nil, note: "顺产"))), in: fixture.ownerContext, context: fixture.context)

        let lamb = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<SheepRecord>()).first { $0.earTag == "L001" })
        XCTAssertEqual(lamb.damID, ewe.id)
        XCTAssertEqual(lamb.sireID, ram.id)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.lambingRecordID == lambingID }.count, 1)
        let childOperations = try fixture.context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == fixture.farm.id &&
                ($0.entityID == lamb.id ||
                    ($0.entityType == CloudEntityType.weight.rawValue &&
                        $0.kindRawValue == DomainOperationKind.recordWeight.rawValue))
        }
        XCTAssertTrue(childOperations.contains {
            $0.entityID == lamb.id &&
                $0.kindRawValue == DomainOperationKind.addSheep.rawValue &&
                $0.baseRevision == 0 &&
                $0.resultingRevision == 1
        })
        XCTAssertTrue(childOperations.contains {
            $0.entityType == CloudEntityType.weight.rawValue &&
                $0.kindRawValue == DomainOperationKind.recordWeight.rawValue
        })

        let before = try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).count
        let duplicate = CareLambingDraft(id: UUID(), eweID: ewe.id, occurredAt: .now, sireID: ram.id, semenID: nil, parity: 3, birthDeadCount: 0, offspring: [.init(earTag: "L001", sex: .ram, birthWeightText: "3")], penID: nil, note: "")
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(duplicate)), in: fixture.ownerContext, context: fixture.context))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).count, before)

        let invalidDeadCount = CareLambingDraft(id: UUID(), eweID: ewe.id, occurredAt: .now, sireID: ram.id, semenID: nil, parity: 3, birthDeadCount: 0, offspring: [.init(earTag: "", sex: .ram, birthWeightText: "2.5", createSheepRecord: false, isStillborn: true)], penID: nil, note: "")
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(invalidDeadCount)), in: fixture.ownerContext, context: fixture.context))
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).count, before)
    }

    func testConfirmedSupabaseLambingBackfillsMissingChildDeliveryOperations() throws {
        let fixture = try makeFixture()
        let ewe = try insertEwe(fixture, earTag: "E-BACKFILL")
        insertParityBaseline(fixture, ewe: ewe, parity: 0)
        let draft = CareLambingDraft(
            eweID: ewe.id,
            occurredAt: .now.addingTimeInterval(-60),
            sireID: nil,
            semenID: nil,
            parity: 1,
            birthDeadCount: 0,
            offspring: [.init(earTag: "L-BACKFILL", sex: .ewe, birthWeightText: "3.1")],
            penID: nil,
            note: ""
        )
        try fixture.service.execute(
            .care(.recordLambing(draft)),
            in: fixture.ownerContext,
            context: fixture.context
        )
        let parent = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).first {
            $0.kindRawValue == DomainOperationKind.care.rawValue && $0.entityID == draft.id
        })
        let children = try fixture.context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.id != parent.id &&
                ($0.kindRawValue == DomainOperationKind.addSheep.rawValue ||
                    $0.kindRawValue == DomainOperationKind.recordWeight.rawValue)
        }
        XCTAssertEqual(children.count, 2)
        let childIDs = Set(children.map(\.id))
        for operation in children { fixture.context.delete(operation) }
        for sequence in try fixture.context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
            where childIDs.contains(sequence.operationID) {
            fixture.context.delete(sequence)
        }
        fixture.context.insert(FarmStorageProfile(
            farmID: fixture.farm.id,
            mode: .supabase,
            authorityGeneration: 1
        ))
        fixture.context.insert(FarmRemoteBinding(
            farmID: fixture.farm.id,
            ownerAccountID: fixture.account.effectiveAccountID,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: fixture.farm.id.uuidString.lowercased()
        ))
        let parentOutbox = OutboxItem(
            farmID: fixture.farm.id,
            accountID: fixture.account.effectiveAccountID,
            operationID: parent.id,
            entityType: parent.entityType,
            entityID: parent.entityID,
            baseRevision: parent.baseRevision,
            payloadDigest: parent.payloadDigest,
            deliveryProvider: .supabase,
            authorityGeneration: 1
        )
        parentOutbox.statusRawValue = OutboxStatus.confirmed.rawValue
        fixture.context.insert(parentOutbox)
        try fixture.context.save()

        XCTAssertEqual(try fixture.service.repairMissingCompositeChildDeliveryOperations(
            farmID: fixture.farm.id,
            context: fixture.context
        ), 2)
        let repairedOperations = try fixture.context.fetch(FetchDescriptor<DomainOperation>()).filter {
            childIDs.contains($0.id)
        }
        XCTAssertEqual(repairedOperations.count, 2)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == fixture.farm.id &&
                $0.deliveryProvider == .supabase &&
                $0.status == .pending
        }.count, 2)

        let repairedSheepOperation = try XCTUnwrap(repairedOperations.first {
            $0.kindRawValue == DomainOperationKind.addSheep.rawValue
        })
        let repairedSheepOperationID = repairedSheepOperation.id
        let repairedSheepEntityID = repairedSheepOperation.entityID
        let retryContext = ModelContext(fixture.container)
        let persistedSheepOperation = try XCTUnwrap(
            try retryContext.fetch(FetchDescriptor<DomainOperation>()).first {
                $0.id == repairedSheepOperationID
            }
        )
        let invalidSheepOutbox = try XCTUnwrap(
            try retryContext.fetch(FetchDescriptor<OutboxItem>()).first {
                $0.operationID == repairedSheepOperationID
            }
        )
        persistedSheepOperation.resultingRevision = 3
        retryContext.delete(invalidSheepOutbox)
        let rejectedSheepOutbox = OutboxItem(
            farmID: fixture.farm.id,
            accountID: fixture.account.effectiveAccountID,
            operationID: persistedSheepOperation.id,
            entityType: persistedSheepOperation.entityType,
            entityID: persistedSheepOperation.entityID,
            baseRevision: persistedSheepOperation.baseRevision,
            payloadDigest: persistedSheepOperation.payloadDigest,
            deliveryProvider: .supabase,
            authorityGeneration: 1
        )
        rejectedSheepOutbox.statusRawValue = OutboxStatus.retryableFailure.rawValue
        rejectedSheepOutbox.errorMessage = "resulting_revision_invalid"
        retryContext.insert(rejectedSheepOutbox)
        try retryContext.save()

        XCTAssertEqual(try fixture.service.repairMissingCompositeChildDeliveryOperations(
            farmID: fixture.farm.id,
            context: retryContext
        ), 1)
        XCTAssertEqual(rejectedSheepOutbox.status, .supersededRemoteAuthority)
        XCTAssertEqual(rejectedSheepOutbox.errorMessage, "superseded_invalid_child_revision")
        let correctedSheepOperations = try retryContext.fetch(
            FetchDescriptor<DomainOperation>()
        ).filter {
            $0.entityID == repairedSheepEntityID &&
                $0.kindRawValue == DomainOperationKind.addSheep.rawValue &&
                $0.id != repairedSheepOperationID
        }
        let correctedSheepOperation = try XCTUnwrap(correctedSheepOperations.first)
        XCTAssertEqual(correctedSheepOperation.baseRevision, 0)
        XCTAssertEqual(correctedSheepOperation.resultingRevision, 1)
        XCTAssertEqual(try retryContext.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.operationID == correctedSheepOperation.id && $0.status == .pending
        }.count, 1)
    }

    func testFirstLambingWithoutStoredParityStartsAtOne() throws {
        let fixture = try makeFixture()
        let lambingAt = Date.now.addingTimeInterval(-60)
        let ewe = SheepRecord(
            farmID: fixture.farm.id,
            earTag: "E-NO-PARITY",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: lambingAt.addingTimeInterval(-30 * 86_400)
        )
        fixture.context.insert(ewe)
        try fixture.context.save()

        let wrongParity = CareLambingDraft(
            eweID: ewe.id,
            occurredAt: lambingAt,
            sireID: nil,
            semenID: nil,
            parity: 2,
            birthDeadCount: 0,
            offspring: [.init(earTag: "L-NO-PARITY-WRONG", sex: .ewe)],
            penID: nil,
            note: ""
        )
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(wrongParity)), in: fixture.ownerContext, context: fixture.context)) { error in
            guard case FarmCommandError.lambingParityMismatch(current: 0, attempted: 2) = error else {
                return XCTFail("无胎次记录应按 0 胎计算，实际错误：\(error)")
            }
        }

        let firstLambing = CareLambingDraft(
            eweID: ewe.id,
            occurredAt: lambingAt,
            sireID: nil,
            semenID: nil,
            parity: 1,
            birthDeadCount: 0,
            offspring: [.init(earTag: "L-NO-PARITY-FIRST", sex: .ram)],
            penID: nil,
            note: "首次录入"
        )
        try fixture.service.execute(.care(.recordLambing(firstLambing)), in: fixture.ownerContext, context: fixture.context)

        let saved = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first {
            $0.eweID == ewe.id && $0.kind == .lambing && $0.deletedAt == nil
        })
        XCTAssertEqual(saved.parity, 1)
    }

    func testNewEweParityBaselineControlsFirstAndLaterLambingParity() throws {
        let fixture = try makeFixture()
        let enteredAt = Date(timeIntervalSince1970: 1_650_000_000)
        let firstLambingAt = enteredAt.addingTimeInterval(30 * 86_400)
        try fixture.service.execute(
            .addSheep(
                earTag: "E004",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                occurredAt: enteredAt,
                birthAt: nil,
                currentParity: 4,
                note: "外场转入"
            ),
            in: fixture.ownerContext,
            context: fixture.context
        )
        let ewe = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<SheepRecord>()).first { $0.earTag == "E004" })
        let baseline = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first {
            $0.id == LambingEntrySemantics.entryParityBaselineID(sheepID: ewe.id)
        })
        XCTAssertEqual(baseline.kind, .parityBaseline)
        XCTAssertEqual(baseline.parity, 4)
        XCTAssertThrowsError(try fixture.service.execute(.tombstoneEntity(entityType: .reproduction, entityID: baseline.id, reason: "不应直接删除"), in: fixture.ownerContext, context: fixture.context)) { error in
            guard case FarmCommandError.parityBaselineManagedInProfile = error else { return XCTFail("实际错误：\(error)") }
        }

        let addOperation = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).first { $0.entityID == ewe.id })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(FarmCommandCloudPayload.self, from: addOperation.payload).integers["currentParity"], 4)

        let wrong = CareLambingDraft(
            eweID: ewe.id,
            occurredAt: firstLambingAt,
            sireID: nil,
            semenID: nil,
            parity: 1,
            birthDeadCount: 0,
            offspring: [.init(earTag: "L-WRONG", sex: .ewe)],
            penID: nil,
            note: ""
        )
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(wrong)), in: fixture.ownerContext, context: fixture.context)) { error in
            guard case FarmCommandError.lambingParityMismatch(current: 4, attempted: 1) = error else {
                return XCTFail("应按当前 4 胎阻止手填第 1 胎，实际错误：\(error)")
            }
        }

        let first = CareLambingDraft(
            eweID: ewe.id,
            occurredAt: firstLambingAt,
            sireID: nil,
            semenID: nil,
            parity: 5,
            birthDeadCount: 0,
            offspring: [.init(earTag: "L005", sex: .ewe)],
            penID: nil,
            note: "转入后首次记录"
        )
        try fixture.service.execute(.care(.recordLambing(first)), in: fixture.ownerContext, context: fixture.context)

        let secondLambingAt = firstLambingAt.addingTimeInterval(180 * 86_400)
        let second = CareLambingDraft(
            eweID: ewe.id,
            occurredAt: secondLambingAt,
            sireID: nil,
            semenID: nil,
            parity: 6,
            birthDeadCount: 0,
            offspring: [.init(earTag: "L006", sex: .ram)],
            penID: nil,
            note: ""
        )
        try fixture.service.execute(.care(.recordLambing(second)), in: fixture.ownerContext, context: fixture.context)
        let facts = try fixture.context.fetch(FetchDescriptor<ReproductionRecord>())
        XCTAssertEqual(LambingEntrySemantics.currentParity(eweID: ewe.id, farmID: fixture.farm.id, before: secondLambingAt.addingTimeInterval(1), records: facts), 6)

        try fixture.service.execute(
            .addSheep(earTag: "Y000", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: enteredAt, birthAt: nil, currentParity: 0, note: "青年母羊"),
            in: fixture.ownerContext,
            context: fixture.context
        )
        let youngEwe = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<SheepRecord>()).first { $0.earTag == "Y000" })
        try fixture.service.execute(
            .care(.recordLambing(.init(eweID: youngEwe.id, occurredAt: firstLambingAt, sireID: nil, semenID: nil, parity: 1, birthDeadCount: 0, offspring: [.init(earTag: "Y001", sex: .ewe)], penID: nil, note: "初产"))),
            in: fixture.ownerContext,
            context: fixture.context
        )
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).contains {
            $0.eweID == youngEwe.id && $0.kind == .lambing && $0.parity == 1
        })
    }

    func testRemoteSheepParityBaselineAndProfileCorrectionReplayDeterministically() throws {
        let fixture = try makeFixture()
        let sheepID = UUID()
        let enteredAt = Date(timeIntervalSince1970: 1_910_000_000)
        let addPayload = try FarmCommandCloudPayloadEncoder.encode(
            .addSheep(earTag: "REMOTE-EWE", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: enteredAt, birthAt: nil, currentParity: 3, note: "")
        )
        let addEnvelope = CloudOperationEnvelope(
            farmID: fixture.farm.id,
            entityID: sheepID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: enteredAt,
            modifiedByAccountID: fixture.account.effectiveAccountID,
            modifiedByDeviceID: UUID(),
            payload: addPayload,
            payloadDigest: CloudPayloadDigest.hex(for: addPayload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        XCTAssertEqual(try RemoteDomainApplyService().apply(addEnvelope, context: fixture.context), .applied(rebuildHistoryFrom: enteredAt))
        XCTAssertEqual(try RemoteDomainApplyService().apply(addEnvelope, context: fixture.context), .duplicate)
        let entryBaseline = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first {
            $0.id == LambingEntrySemantics.entryParityBaselineID(sheepID: sheepID)
        })
        XCTAssertEqual(entryBaseline.parity, 3)

        let correctedAt = enteredAt.addingTimeInterval(10 * 86_400)
        let updatePayload = try FarmCommandCloudPayloadEncoder.encode(
            .updateSheepProfile(sheepID: sheepID, earTag: "REMOTE-EWE", breed: "湖羊", sex: .ewe, birthAt: nil, currentParity: 7, parityRecordedAt: correctedAt, note: "核对产羔本")
        )
        let updateEnvelope = CloudOperationEnvelope(
            farmID: fixture.farm.id,
            entityID: sheepID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: correctedAt,
            modifiedByAccountID: fixture.account.effectiveAccountID,
            modifiedByDeviceID: UUID(),
            payload: updatePayload,
            payloadDigest: CloudPayloadDigest.hex(for: updatePayload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        XCTAssertEqual(try RemoteDomainApplyService().apply(updateEnvelope, context: fixture.context), .applied(rebuildHistoryFrom: nil))
        let correction = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first {
            $0.id == LambingEntrySemantics.parityCorrectionID(sheepID: sheepID, sheepRevision: 2)
        })
        XCTAssertEqual(correction.parity, 7)
        XCTAssertEqual(correction.occurredAt, correctedAt)
        let facts = try fixture.context.fetch(FetchDescriptor<ReproductionRecord>())
        XCTAssertEqual(LambingEntrySemantics.currentParity(eweID: sheepID, farmID: fixture.farm.id, before: .distantFuture, records: facts), 7)
    }

    func testParityBaselineFollowsUnreferencedEweDeletionAndRestore() throws {
        let fixture = try makeFixture()
        let enteredAt = Date(timeIntervalSince1970: 1_905_000_000)
        try fixture.service.execute(
            .addSheep(
                earTag: "DELETE-EWE",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                occurredAt: enteredAt,
                birthAt: nil,
                currentParity: 2,
                note: ""
            ),
            in: fixture.ownerContext,
            context: fixture.context
        )
        let ewe = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<SheepRecord>()).first {
            $0.earTag == "DELETE-EWE"
        })
        let parityID = LambingEntrySemantics.entryParityBaselineID(sheepID: ewe.id)

        try fixture.service.execute(
            .tombstoneEntity(entityType: .sheep, entityID: ewe.id, reason: "误建档"),
            in: fixture.ownerContext,
            context: fixture.context
        )
        XCTAssertNotNil(ewe.deletedAt)
        let deletedParity = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first {
            $0.id == parityID
        })
        XCTAssertNotNil(deletedParity.deletedAt)

        let tombstone = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<TombstoneRecord>()).first {
            $0.entityID == ewe.id && $0.restoredAt == nil
        })
        try fixture.service.execute(
            .restoreTombstonedEntity(tombstoneID: tombstone.id),
            in: fixture.ownerContext,
            context: fixture.context
        )
        XCTAssertNil(ewe.deletedAt)
        XCTAssertNil(deletedParity.deletedAt)
    }

    func testTombstoneUsesProjectionRevisionAfterCompactRestore() throws {
        let fixture = try makeFixture()
        let sheep = SheepRecord(
            farmID: fixture.farm.id,
            earTag: "RESTORED-REVISION",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now.addingTimeInterval(-86_400)
        )
        sheep.revision = 7
        fixture.context.insert(sheep)
        try fixture.context.save()

        try fixture.service.execute(
            .tombstoneEntity(
                entityType: .sheep,
                entityID: sheep.id,
                reason: "验证紧凑检查点 revision"
            ),
            in: fixture.ownerContext,
            context: fixture.context
        )

        let operation = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).first {
            $0.entityID == sheep.id &&
                $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue
        })
        XCTAssertEqual(operation.baseRevision, 7)
        XCTAssertEqual(operation.resultingRevision, 8)
    }

    func testMissingParityDefaultsToZeroAndLegacyCorrectionKeepsRecordedParity() throws {
        let farmID = UUID()
        let eweID = UUID()
        let lambingAt = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = ReproductionRecord(
            farmID: farmID,
            eweID: eweID,
            kind: .lambing,
            occurredAt: lambingAt,
            parity: 4
        )

        XCTAssertEqual(LambingEntrySemantics.currentParity(
            eweID: eweID,
            farmID: farmID,
            before: lambingAt,
            records: []
        ), 0)
        XCTAssertEqual(LambingEntrySemantics.priorParityForLambing(
            eweID: eweID,
            farmID: farmID,
            at: lambingAt,
            existingRecordID: nil,
            records: [legacy]
        ), 0)
        XCTAssertEqual(LambingEntrySemantics.priorParityForLambing(
            eweID: eweID,
            farmID: farmID,
            at: lambingAt,
            existingRecordID: legacy.id,
            records: [legacy]
        ), 3)
    }

    func testLambingWeightUsesActualDateAndOnlyTwentyFourHourWeightIsBirthWeight() throws {
        let fixture = try makeFixture()
        let lambingAt = Date(timeIntervalSince1970: 1_650_000_000)
        let ewe = SheepRecord(farmID: fixture.farm.id, earTag: "E-WEIGHT", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: lambingAt.addingTimeInterval(-30 * 86_400))
        fixture.context.insert(ewe)
        insertParityBaseline(fixture, ewe: ewe, parity: 0)
        let newborn = CareLambDraft(earTag: "L-BIRTH", sex: .ewe, birthWeightText: "3.2", weightOccurredAt: lambingAt.addingTimeInterval(12 * 3_600))
        let later = CareLambDraft(earTag: "L-LATER", sex: .ram, birthWeightText: "5.1", weightOccurredAt: lambingAt.addingTimeInterval(5 * 86_400))
        let unweighed = CareLambDraft(earTag: "L-NONE", sex: .ewe)

        try fixture.service.execute(
            .care(.recordLambing(.init(eweID: ewe.id, occurredAt: lambingAt, sireID: nil, semenID: nil, parity: 1, birthDeadCount: 0, offspring: [newborn, later, unweighed], penID: nil, note: ""))),
            in: fixture.ownerContext,
            context: fixture.context
        )

        let details = try fixture.context.fetch(FetchDescriptor<LambingOffspringRecord>())
        let birthDetail = try XCTUnwrap(details.first { $0.legacyEarTag == "L-BIRTH" })
        let laterDetail = try XCTUnwrap(details.first { $0.legacyEarTag == "L-LATER" })
        let unweighedDetail = try XCTUnwrap(details.first { $0.legacyEarTag == "L-NONE" })
        XCTAssertEqual(birthDetail.birthWeightText, "3.2")
        XCTAssertEqual(laterDetail.birthWeightText, "", "出生多日后的体重不能进入初生重事实")
        XCTAssertEqual(unweighedDetail.birthWeightText, "")
        XCTAssertNil(unweighedDetail.autoBirthWeightRecordID)

        let weights = try fixture.context.fetch(FetchDescriptor<WeightRecord>())
        let birthWeight = try XCTUnwrap(birthDetail.autoBirthWeightRecordID.flatMap { id in weights.first { $0.id == id } })
        let laterWeight = try XCTUnwrap(laterDetail.autoBirthWeightRecordID.flatMap { id in weights.first { $0.id == id } })
        XCTAssertEqual(birthWeight.occurredAt, newborn.weightOccurredAt)
        XCTAssertEqual(birthWeight.note, "初生重")
        XCTAssertEqual(laterWeight.occurredAt, later.weightOccurredAt)
        XCTAssertEqual(laterWeight.note, "产羔录入称重")
        XCTAssertFalse(weights.contains { $0.sheepID == unweighed.sheepID })
    }

    func testLateLambWeightRequiresAProfileAndStillbornWeightMustBeWithinBirthWindow() throws {
        let fixture = try makeFixture()
        let lambingAt = Date(timeIntervalSince1970: 1_650_000_000)
        let ewe = SheepRecord(farmID: fixture.farm.id, earTag: "E-INVALID-WEIGHT", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: lambingAt.addingTimeInterval(-86_400))
        fixture.context.insert(ewe)
        insertParityBaseline(fixture, ewe: ewe, parity: 0)
        let lateAt = lambingAt.addingTimeInterval(2 * 86_400)

        let withoutProfile = CareLambingDraft(eweID: ewe.id, occurredAt: lambingAt, sireID: nil, semenID: nil, parity: 1, birthDeadCount: 0, offspring: [.init(earTag: "L-NO-PROFILE", sex: .ram, birthWeightText: "4.5", weightOccurredAt: lateAt, createSheepRecord: false)], penID: nil, note: "")
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(withoutProfile)), in: fixture.ownerContext, context: fixture.context)) { error in
            guard case FarmCommandError.routineLambWeightRequiresSheepRecord = error else { return XCTFail("实际错误：\(error)") }
        }

        let stillborn = CareLambingDraft(eweID: ewe.id, occurredAt: lambingAt, sireID: nil, semenID: nil, parity: 1, birthDeadCount: 1, offspring: [.init(earTag: "L-STILL", sex: .ewe, birthWeightText: "4", weightOccurredAt: lateAt, createSheepRecord: false, isStillborn: true)], penID: nil, note: "")
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(stillborn)), in: fixture.ownerContext, context: fixture.context)) { error in
            guard case FarmCommandError.stillbornWeightMustBeBirth = error else { return XCTFail("实际错误：\(error)") }
        }
    }

    func testLambingAndLambWeightRejectFutureFacts() throws {
        let fixture = try makeFixture()
        let now = Date.now
        let ewe = SheepRecord(
            farmID: fixture.farm.id,
            earTag: "E-FUTURE",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: now.addingTimeInterval(-30 * 86_400)
        )
        fixture.context.insert(ewe)
        insertParityBaseline(fixture, ewe: ewe, parity: 0)

        let futureLambing = CareLambingDraft(
            eweID: ewe.id,
            occurredAt: now.addingTimeInterval(3_600),
            sireID: nil,
            semenID: nil,
            parity: 1,
            birthDeadCount: 0,
            offspring: [.init(earTag: "L-FUTURE-BIRTH", sex: .ewe)],
            penID: nil,
            note: ""
        )
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(futureLambing)), in: fixture.ownerContext, context: fixture.context)) { error in
            guard case FarmCommandError.futureFactDate(let label) = error else {
                return XCTFail("应阻止未来产羔时间，实际错误：\(error)")
            }
            XCTAssertEqual(label, "产羔时间")
        }

        let futureWeight = CareLambingDraft(
            eweID: ewe.id,
            occurredAt: now.addingTimeInterval(-2 * 86_400),
            sireID: nil,
            semenID: nil,
            parity: 1,
            birthDeadCount: 0,
            offspring: [
                .init(
                    earTag: "L-FUTURE-WEIGHT",
                    sex: .ram,
                    birthWeightText: "4.2",
                    weightOccurredAt: now.addingTimeInterval(3_600)
                )
            ],
            penID: nil,
            note: ""
        )
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(futureWeight)), in: fixture.ownerContext, context: fixture.context)) { error in
            guard case FarmCommandError.futureFactDate(let label) = error else {
                return XCTFail("应阻止未来称重时间，实际错误：\(error)")
            }
            XCTAssertEqual(label, "称重时间")
        }

        XCTAssertFalse(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).contains {
            $0.eweID == ewe.id && $0.kind == .lambing && $0.deletedAt == nil
        })
    }

    func testWorkerCanRecordButCannotMaintainCatalogAndCareBackupRestores() throws {
        let source = try makeFixture()
        let ewe = try insertEwe(source, earTag: "E001")
        let record = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: [ewe.id], penID: nil, catalogItemID: nil, kind: .treatment, itemName: "观察", occurredAt: .now, note: "", inventoryLotID: nil, dosePerSubjectText: nil, unit: "", route: "", reminderAt: nil)
        try source.service.execute(.care(.recordHealth(record)), in: source.workerContext, context: source.context)
        XCTAssertThrowsError(try source.service.execute(.care(.upsertHealthCatalog(id: UUID(), kindRawValue: HealthRecordKind.treatment.rawValue, name: "药品", category: "抗菌", unit: "毫升", defaultDoseText: "1", defaultRoute: "肌注", reminderIntervalDays: nil, note: "", isActive: true)), in: source.workerContext, context: source.context))

        let data = try FarmLocalBackupService.export(farmID: source.farm.id, context: source.context)
        let preview = try FarmLocalBackupService.preview(data: data)
        XCTAssertEqual(preview.envelope.payload.care?.health.count, 1)
        let destination = try makeFixture()
        _ = try FarmLocalBackupService.restore(preview, into: destination.farm, account: destination.account, context: destination.context)
        XCTAssertEqual(try destination.context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == destination.farm.id }.count, 1)
        XCTAssertEqual(try destination.context.fetch(FetchDescriptor<HealthSubjectLink>()).filter { $0.farmID == destination.farm.id }.count, 1)
    }

    func testRemoteCareReplayIsIdempotent() throws {
        let fixture = try makeFixture()
        let ewe = try insertEwe(fixture, earTag: "E001")
        let draft = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: [ewe.id], penID: nil, catalogItemID: nil, kind: .treatment, itemName: "远端健康事实", occurredAt: .now, note: "", inventoryLotID: nil, dosePerSubjectText: nil, unit: "", route: "", reminderAt: nil)
        let payload = try FarmCommandCloudPayloadEncoder.encode(.care(.recordHealth(draft)))
        let envelope = CloudOperationEnvelope(farmID: fixture.farm.id, entityID: draft.id, entityType: CloudEntityType.health.rawValue, schemaVersion: 2, revision: 1, baseRevision: 0, operationID: UUID(), modifiedAt: .now, modifiedByAccountID: fixture.account.effectiveAccountID, modifiedByDeviceID: UUID(), payload: payload, payloadDigest: CloudPayloadDigest.hex(for: payload), capabilityCertificate: "test", operationSignature: Data(), deletedAt: nil)

        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: fixture.context), .applied(rebuildHistoryFrom: nil))
        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: fixture.context), .duplicate)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.id == draft.id }.count, 1)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<HealthSubjectLink>()).filter { $0.healthRecordID == draft.id }.count, 1)
    }

    func testCareCommandsRejectCrossFarmSubjects() throws {
        let fixture = try makeFixture()
        let otherFarm = FarmRecord(ownerAccountID: fixture.account.effectiveAccountID, name: "其他牧场")
        let otherSheep = SheepRecord(farmID: otherFarm.id, earTag: "X001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        fixture.context.insert(otherFarm); fixture.context.insert(otherSheep); try fixture.context.save()
        let draft = CareHealthDraft(id: UUID(), batchID: UUID(), subjectIDs: [otherSheep.id], penID: nil, catalogItemID: nil, kind: .treatment, itemName: "跨场记录", occurredAt: .now, note: "", inventoryLotID: nil, dosePerSubjectText: nil, unit: "", route: "", reminderAt: nil)
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordHealth(draft)), in: fixture.ownerContext, context: fixture.context))
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<HealthRecord>()).isEmpty)
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试账户")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "健康繁殖测试牧场")
        context.insert(account); context.insert(farm); try context.save()
        return .init(container: container, context: context, account: account, farm: farm, service: FarmCommandService())
    }

    private func insertEwe(_ fixture: Fixture, earTag: String) throws -> SheepRecord {
        let sheep = SheepRecord(farmID: fixture.farm.id, earTag: earTag, breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now.addingTimeInterval(-3_600))
        fixture.context.insert(sheep); try fixture.context.save(); return sheep
    }

    private func insertParityBaseline(_ fixture: Fixture, ewe: SheepRecord, parity: Int) {
        fixture.context.insert(ReproductionRecord(
            id: LambingEntrySemantics.entryParityBaselineID(sheepID: ewe.id),
            farmID: fixture.farm.id,
            eweID: ewe.id,
            kind: .parityBaseline,
            occurredAt: ewe.enteredAt,
            parity: parity,
            note: "测试胎次基准"
        ))
        try? fixture.context.save()
    }

    private func receiveInventory(_ fixture: Fixture, quantity: String) throws -> InventoryLotRecord {
        try fixture.service.execute(.care(.receiveInventory(id: UUID(), catalogName: "样品", catalogItemID: nil, kindRawValue: HealthRecordKind.vaccination.rawValue, batchNumber: "B-001", supplier: "测试供应商", unit: "毫升", expiresAt: .now.addingTimeInterval(30 * 86_400), quantityText: quantity, occurredAt: .now, note: "入库")), in: fixture.ownerContext, context: fixture.context)
        return try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<InventoryLotRecord>()).first { $0.farmID == fixture.farm.id })
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let account: AccountProfile
        let farm: FarmRecord
        let service: FarmCommandService
        var ownerContext: FarmContext { .init(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner) }
        var workerContext: FarmContext { .init(accountID: account.effectiveAccountID, farmID: farm.id, role: .worker) }
    }
}
