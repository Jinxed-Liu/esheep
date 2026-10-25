import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class ReproductionPersistenceContractTests: XCTestCase {
    func testV17StoreMigratesWithoutInventingAssociationsOrFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CycleMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "farm.store"), farmID = UUID(), eweID = UUID(), recordID = UUID(), breedingID = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        do {
            let schema = Schema(versionedSchema: AppSchemaV17.self)
            XCTAssertFalse(schema.entities.first { $0.name == "ReproductionRecord" }!.attributes.contains { $0.name == "reproductionCycleID" })
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration("cycle", schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(old)
            let record = AppSchemaV17.ReproductionRecord(id: recordID, farmID: farmID, eweID: eweID,
                kind: .pregnancyCheck, occurredAt: date, relatedBreedingRecordID: breedingID, result: "已孕", note: "原始检查")
            record.revision = 8
            context.insert(record); try context.save()
        }
        let current = try AppSchema.makeContainer(name: "cycle", url: url)
        let context = ModelContext(current)
        let rows = try context.fetch(FetchDescriptor<ReproductionRecord>())
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(row.id, recordID)
        XCTAssertEqual(row.occurredAt, date); XCTAssertEqual(row.result, "已孕")
        XCTAssertEqual(row.relatedBreedingRecordID, breedingID); XCTAssertEqual(row.revision, 8)
        XCTAssertNil(row.reproductionCycleID); XCTAssertNil(row.breedingRoundID); XCTAssertNil(row.breedingIntentRawValue)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
    }

    func testAuditedEntryCheckpointAndBackupPreserveAssociationsAndRejectStaleCycle() async throws {
        let container = try AppSchema.makeContainer(name: "CycleContract-\(UUID())", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "隔离验证")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "关联测试")
        let ewe = SheepRecord(farmID: farm.id, earTag: "CYCLE-001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: Date(timeIntervalSince1970: 100))
        let ram = SheepRecord(farmID: farm.id, earTag: "RAM-001", breed: "湖羊", sex: .ram, penID: nil, enteredAt: Date(timeIntervalSince1970: 100))
        ram.isBreedingRam = true
        context.insert(account); context.insert(farm); context.insert(ewe); context.insert(ram)
        context.insert(FarmStorageProfile(farmID: farm.id, mode: .localOnly))
        context.insert(ReproductionRecord(farmID: farm.id, eweID: ewe.id, kind: .parityBaseline,
            occurredAt: Date(timeIntervalSince1970: 100), parity: 0))
        try context.save()
        let scope = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner)
        let batch = CareReproductionBatchDraft(id: UUID(), kind: .breeding,
            subjects: [.init(eweID: ewe.id, result: "", breedingIntent: .newRound)], occurredAt: Date(timeIntervalSince1970: 200), sireID: ram.id, semenID: nil, semenUnitsPerEweText: nil, note: "", reminderAt: nil)
        try FarmCommandService().execute(.care(.recordReproductionBatch(batch)), in: scope, context: context)
        let facts = try context.fetch(FetchDescriptor<ReproductionRecord>())
        let breeding = try XCTUnwrap(facts.first { $0.kind == .breeding })
        XCTAssertEqual(breeding.reproductionCycleID, ewe.id)
        XCTAssertEqual(breeding.breedingRoundID, breeding.id)
        let check = CareReproductionBatchDraft(id: UUID(), kind: .pregnancyCheck,
            subjects: [.init(eweID: ewe.id, result: "已孕", relatedBreedingRecordID: breeding.id)], occurredAt: Date(timeIntervalSince1970: 300), sireID: nil, semenID: nil, semenUnitsPerEweText: nil, note: "", reminderAt: nil)
        try FarmCommandService().execute(.care(.recordReproductionBatch(check)), in: scope, context: context)
        let checked = try XCTUnwrap(try context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.kind == .pregnancyCheck })
        XCTAssertEqual(checked.breedingRoundID, breeding.id)
        let adapter = try XCTUnwrap(ESheepCloudCheckpointRegistry.adapters.first { $0.name == "ReproductionRecord" })
        let rows = try adapter.exportRows(farm.id, context)
        let oldRow = try XCTUnwrap(rows.first { $0.values["breedingRoundID"] == nil })
        XCTAssertNil(oldRow.values["reproductionCycleID"])
        let target = try AppSchema.makeContainer(name: "CycleCheckpoint-\(UUID())", isStoredInMemoryOnly: true)
        let targetContext = ModelContext(target)
        for row in rows { try adapter.insertRow(row, farm.id, targetContext) }
        try targetContext.save()
        XCTAssertEqual(try adapter.exportRows(farm.id, targetContext), rows)
        let cloudState = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3)
        cloudState.integrityState = .passed
        context.insert(cloudState); try context.save()
        let archiveRoot = FileManager.default.temporaryDirectory.appending(path: "CycleArchive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: archiveRoot) }
        // A local command log is not an acknowledged cloud projection. Preserve
        // the publisher's rejection, then construct the isolated projection
        // fixture from the resulting farm facts for the archive round trip.
        XCTAssertThrowsError(try ESheepCloudCheckpointArchive.export(farmID: farm.id, context: context,
            directory: archiveRoot.appending(path: "unacknowledged")))
        for name in ["FarmRecord", "SheepRecord"] {
            let projectionAdapter = try XCTUnwrap(ESheepCloudCheckpointRegistry.adapters.first { $0.name == name })
            for row in try projectionAdapter.exportRows(farm.id, context) {
                try projectionAdapter.insertRow(row, farm.id, targetContext)
            }
        }
        let projectionState = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3)
        projectionState.integrityState = .passed
        targetContext.insert(projectionState); try targetContext.save()
        let manifest = try ESheepCloudCheckpointArchive.export(farmID: farm.id, context: targetContext, directory: archiveRoot)
        XCTAssertEqual(manifest.minimumClientCapability, 2)
        XCTAssertNoThrow(try manifest.validate())
        let importer = try ESheepCloudCheckpointImporter(manifest: manifest, accountID: account.effectiveAccountID,
            storeURL: archiveRoot.appending(path: "restored.store"))
        for chunk in manifest.chunks {
            try await importer.importChunk(Data(contentsOf: archiveRoot.appending(path: String(format: "%05d.json.gz", chunk.index))), index: chunk.index)
        }
        try await importer.finish()
        let importedRows = try await importer.records(model: "ReproductionRecord")
        XCTAssertEqual(importedRows, rows)

        let future = ESheepCloudCheckpointManifest(formatVersion: manifest.formatVersion, minimumClientCapability: 3,
            checkpointID: manifest.checkpointID, farmID: manifest.farmID, farmGeneration: manifest.farmGeneration,
            boundaryEventSequence: manifest.boundaryEventSequence, boundaryEventDigest: manifest.boundaryEventDigest,
            receiptChainDigest: manifest.receiptChainDigest, businessDigest: manifest.businessDigest, modelCounts: manifest.modelCounts, chunks: manifest.chunks)
        XCTAssertThrowsError(try future.validate()) { XCTAssertTrue($0.localizedDescription.contains("请更新")) }

        let backup = try FarmLocalBackupService.export(farmID: farm.id, context: context)
        let preview = try FarmLocalBackupService.preview(data: backup)
        let restoredFarm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "恢复关联")
        let restore = try AppSchema.makeContainer(name: "CycleBackup-\(UUID())", isStoredInMemoryOnly: true)
        let restoreContext = ModelContext(restore)
        restoreContext.insert(restoredFarm); try restoreContext.save()
        _ = try FarmLocalBackupService.restore(preview, into: restoredFarm, account: account, context: restoreContext)
        let restored = try XCTUnwrap(try restoreContext.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.id == checked.id })
        XCTAssertEqual(restored.reproductionCycleID, checked.reproductionCycleID)
        XCTAssertEqual(restored.breedingRoundID, checked.breedingRoundID)
        context.insert(ReproductionRecord(farmID: farm.id, eweID: ewe.id, kind: .abortion, occurredAt: Date(timeIntervalSince1970: 400)))
        try context.save()
        let before = try context.fetchCount(FetchDescriptor<DomainOperation>())
        let stale = CareReproductionBatchDraft(id: UUID(), kind: .pregnancyCheck,
            subjects: [.init(eweID: ewe.id, result: "空怀", reproductionCycleID: ewe.id)], occurredAt: Date(timeIntervalSince1970: 500), sireID: nil, semenID: nil, semenUnitsPerEweText: nil, note: "", reminderAt: nil)
        XCTAssertThrowsError(try FarmCommandService().execute(.care(.recordReproductionBatch(stale)), in: scope, context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), before)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReproductionRecord>()), 4)
    }
}

extension ReproductionPersistenceContractTests {
    func testLegacyLambingCorrectionPreservesConfirmedAssociationButExplicitCycleCanClearIt() {
        let farmID = UUID(), eweID = UUID(), breedingID = UUID(), roundID = UUID()
        let original = ReproductionRecord(farmID: farmID, eweID: eweID, kind: .lambing, occurredAt: .now,
            relatedBreedingRecordID: breedingID, reproductionCycleID: eweID, breedingRoundID: roundID, parity: 1)
        let legacy = CareLambingDraft(id: original.id, eweID: eweID, occurredAt: original.occurredAt,
            sireID: nil, semenID: nil, parity: 1, birthDeadCount: 0, offspring: [], penID: nil, note: "修正备注")
        let preserved = legacy.preservingReproductionAssociation(from: original)
        XCTAssertEqual(preserved.relatedBreedingRecordID, breedingID)
        XCTAssertEqual(preserved.breedingRoundID, roundID)
        XCTAssertEqual(preserved.reproductionCycleID, eweID)
        let explicit = CareLambingDraft(id: original.id, eweID: eweID, occurredAt: original.occurredAt,
            sireID: nil, semenID: nil, reproductionCycleID: eweID, parity: 1, birthDeadCount: 0, offspring: [], penID: nil, note: "核实无对应配种")
        XCTAssertNil(explicit.preservingReproductionAssociation(from: original).relatedBreedingRecordID)
        XCTAssertNil(explicit.preservingReproductionAssociation(from: original).breedingRoundID)
    }
}
