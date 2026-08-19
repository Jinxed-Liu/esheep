import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class LocalHerdWorkflowTests: XCTestCase {
    func testSecureImportLoaderAcceptsDirectlyReadableNonScopedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "esheep-direct-import-\(UUID().uuidString).json")
        let expected = Data(#"{"schemaVersion":1}"#.utf8)
        try expected.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try SecureImportFileLoader.load(from: url), expected)
    }

    func testPenAndSheepProfileUpdatesStayInsideCommandPipeline() throws {
        let fixture = try makeFixture()
        let secondPen = PenRecord(farmID: fixture.farm.id, name: "二号圈")
        fixture.context.insert(secondPen)
        let sheep = SheepRecord(farmID: fixture.farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: secondPen.id, enteredAt: .now)
        let conflictingSheep = SheepRecord(farmID: fixture.farm.id, earTag: "B001", breed: "杜泊", sex: .ram, penID: nil, enteredAt: .now)
        fixture.context.insert(sheep)
        fixture.context.insert(conflictingSheep)
        try fixture.context.save()

        XCTAssertThrowsError(try fixture.service.execute(.setPenActive(penID: secondPen.id, isActive: false), in: fixture.farmContext, context: fixture.context))
        try fixture.service.execute(.updatePen(penID: secondPen.id, name: "后备母羊圈", note: "东侧"), in: fixture.farmContext, context: fixture.context)
        XCTAssertThrowsError(try fixture.service.execute(.updateSheepProfile(sheepID: sheep.id, earTag: " b001 ", breed: "湖羊", sex: .ewe, birthAt: nil, note: ""), in: fixture.farmContext, context: fixture.context))
        try fixture.service.execute(.updateSheepProfile(sheepID: sheep.id, earTag: "A-001", breed: "湖羊改良", sex: .ewe, birthAt: Date(timeIntervalSince1970: 1_700_000_000), note: "重点观察"), in: fixture.farmContext, context: fixture.context)

        XCTAssertEqual(secondPen.name, "后备母羊圈")
        XCTAssertEqual(sheep.earTag, "A-001")
        XCTAssertEqual(sheep.breed, "湖羊改良")
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<DomainOperation>()).contains { $0.kindRawValue == DomainOperationKind.updateSheepProfile.rawValue })
    }

    func testCorrectionsTombstoneOriginalsAndRebuildCurrentState() throws {
        let fixture = try makeFixture()
        let penA = PenRecord(farmID: fixture.farm.id, name: "A圈")
        let penB = PenRecord(farmID: fixture.farm.id, name: "B圈")
        let penC = PenRecord(farmID: fixture.farm.id, name: "C圈")
        [penA, penB, penC].forEach(fixture.context.insert)
        let enteredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sheep = SheepRecord(farmID: fixture.farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: penA.id, enteredAt: enteredAt)
        fixture.context.insert(sheep)
        try fixture.context.save()

        try fixture.service.execute(.recordWeight(sheepID: sheep.id, kilogramsText: "40", occurredAt: enteredAt.addingTimeInterval(100), note: "原值"), in: fixture.farmContext, context: fixture.context)
        let originalWeight = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<WeightRecord>()).first { $0.deletedAt == nil })
        try fixture.service.execute(.correctWeight(originalID: originalWeight.id, kilogramsText: "41.5", occurredAt: originalWeight.occurredAt, note: "复称", reason: "录入错误"), in: fixture.farmContext, context: fixture.context)

        try fixture.service.execute(.transferSheep(sheepID: sheep.id, toPenID: penB.id, occurredAt: enteredAt.addingTimeInterval(200), note: "原转群"), in: fixture.farmContext, context: fixture.context)
        let originalTransfer = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<TransferRecord>()).first { $0.deletedAt == nil })
        try fixture.service.execute(.correctTransfer(originalID: originalTransfer.id, toPenID: penC.id, occurredAt: originalTransfer.occurredAt, note: "改到C圈", reason: "圈舍选错"), in: fixture.farmContext, context: fixture.context)

        try fixture.service.execute(.removeSheep(sheepID: sheep.id, kind: .sold, reason: "出售", amountText: "1000", occurredAt: enteredAt.addingTimeInterval(300), note: ""), in: fixture.farmContext, context: fixture.context)
        let originalRemoval = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<RemovalRecord>()).first { $0.deletedAt == nil })
        try fixture.service.execute(.correctRemoval(originalID: originalRemoval.id, kind: .culled, reason: "淘汰", amountText: nil, occurredAt: originalRemoval.occurredAt, note: "", correctionReason: "类型选错"), in: fixture.farmContext, context: fixture.context)

        let activeWeight = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<WeightRecord>()).first { $0.deletedAt == nil })
        let activeTransfer = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<TransferRecord>()).first { $0.deletedAt == nil })
        let activeRemoval = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<RemovalRecord>()).first { $0.deletedAt == nil })
        XCTAssertEqual(activeWeight.kilogramsText, "41.5")
        XCTAssertEqual(activeTransfer.toPenID, penC.id)
        XCTAssertEqual(activeRemoval.kind, .culled)
        XCTAssertEqual(sheep.currentPenID, nil)
        XCTAssertEqual(sheep.status, .removed)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.reason.hasPrefix("修正：") }.count, 3)

        try fixture.service.execute(.restoreSheep(removalID: activeRemoval.id), in: fixture.farmContext, context: fixture.context)
        XCTAssertEqual(sheep.status, .active)
        XCTAssertEqual(sheep.currentPenID, penC.id)
    }

    func testSameDayRemovalFastPathProjectsEveryRemovalKindAndCurrentCount() throws {
        let fixture = try makeFixture()
        let pen = PenRecord(farmID: fixture.farm.id, name: "离群前圈舍")
        let kinds = RemovalKind.allCases
        let sheep = kinds.enumerated().map { index, _ in
            SheepRecord(
                farmID: fixture.farm.id,
                earTag: "R\(index + 1)",
                breed: "湖羊",
                sex: .ewe,
                penID: pen.id,
                enteredAt: Date.now.addingTimeInterval(-86_400)
            )
        }
        fixture.context.insert(pen)
        sheep.forEach(fixture.context.insert)
        let today = Calendar.current.startOfDay(for: .now)
        fixture.context.insert(DailyPenCountRecord(
            farmID: fixture.farm.id,
            penID: pen.id,
            purpose: sheep[0].purpose,
            date: today,
            count: sheep.count
        ))
        try fixture.context.save()

        for (item, kind) in zip(sheep, kinds) {
            try fixture.service.execute(
                .removeSheep(
                    sheepID: item.id,
                    kind: kind,
                    reason: kind.displayName,
                    amountText: nil,
                    occurredAt: .now,
                    note: ""
                ),
                in: fixture.farmContext,
                context: fixture.context
            )
            XCTAssertEqual(item.status, kind.resultingStatus)
            XCTAssertNil(item.currentPenID)
        }

        let currentCounts = try fixture.context.fetch(FetchDescriptor<DailyPenCountRecord>()).filter {
            $0.farmID == fixture.farm.id && $0.penID == pen.id && $0.date == today
        }
        XCTAssertEqual(currentCounts.count, 1)
        XCTAssertEqual(currentCounts.first?.count, 0)
    }

    func testHistorySnapshotLoadsOneSheepAsOneBackgroundUpdate() async throws {
        let fixture = try makeFixture()
        let pen = PenRecord(farmID: fixture.farm.id, name: "当前圈")
        let sheep = SheepRecord(farmID: fixture.farm.id, earTag: "H001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now)
        let otherSheep = SheepRecord(farmID: fixture.farm.id, earTag: "H002", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now)
        let activeWeight = WeightRecord(farmID: fixture.farm.id, sheepID: sheep.id, kilogramsText: "42", occurredAt: .now)
        let deletedWeight = WeightRecord(farmID: fixture.farm.id, sheepID: sheep.id, kilogramsText: "41", occurredAt: .now.addingTimeInterval(-60))
        deletedWeight.deletedAt = .now
        let unrelatedWeight = WeightRecord(farmID: fixture.farm.id, sheepID: otherSheep.id, kilogramsText: "80", occurredAt: .now)
        let tombstone = TombstoneRecord(
            farmID: fixture.farm.id,
            entityType: CloudEntityType.weight.rawValue,
            entityID: deletedWeight.id,
            deletedByAccountID: fixture.account.id,
            reason: "用户撤销称重记录",
            revision: 1
        )
        fixture.context.insert(pen)
        fixture.context.insert(sheep)
        fixture.context.insert(otherSheep)
        fixture.context.insert(activeWeight)
        fixture.context.insert(deletedWeight)
        fixture.context.insert(unrelatedWeight)
        fixture.context.insert(tombstone)
        try fixture.context.save()

        let snapshot = try await SheepRecordHistoryActor(container: fixture.container).load(
            farmID: fixture.farm.id,
            sheepID: sheep.id
        )

        XCTAssertEqual(snapshot.weights.map(\.id), [activeWeight.id])
        XCTAssertEqual(snapshot.tombstones.map(\.id), [tombstone.id])
        XCTAssertEqual(snapshot.penName(pen.id), pen.name)
    }

    func testBackupValidatesInStagingAndRestoresIdempotently() throws {
        let source = try makeFixture()
        let pen = PenRecord(farmID: source.farm.id, name: "一号圈")
        let sheep = SheepRecord(farmID: source.farm.id, earTag: "B001", breed: "杜泊", sex: .ram, penID: pen.id, enteredAt: .now)
        source.context.insert(pen); source.context.insert(sheep)
        try source.service.execute(.recordWeight(sheepID: sheep.id, kilogramsText: "55", occurredAt: .now, note: "备份样本"), in: source.farmContext, context: source.context)
        let data = try FarmLocalBackupService.export(farmID: source.farm.id, context: source.context)
        let preview = try FarmLocalBackupService.preview(data: data)
        XCTAssertEqual(preview.envelope.payload.sheep.count, 1)
        let portableLegacyPreview = try FarmPortableBackupService.preview(data: data)
        XCTAssertNil(portableLegacyPreview.portableEnvelope)
        XCTAssertEqual(portableLegacyPreview.sourceStorageMode, .localOnly)

        let destination = try makeFixture(farmName: "空牧场")
        let first = try FarmLocalBackupService.restore(preview, into: destination.farm, account: destination.account, context: destination.context)
        let second = try FarmLocalBackupService.restore(preview, into: destination.farm, account: destination.account, context: destination.context)
        XCTAssertFalse(first.alreadyRestored)
        XCTAssertTrue(second.alreadyRestored)
        XCTAssertEqual(try destination.context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == destination.farm.id }.count, 1)
        XCTAssertEqual(destination.farm.name, source.farm.name)

        let nonemptyDestination = try makeFixture(farmName: "非空牧场")
        nonemptyDestination.context.insert(PenRecord(farmID: nonemptyDestination.farm.id, name: "已有圈舍"))
        try nonemptyDestination.context.save()
        XCTAssertThrowsError(try FarmLocalBackupService.restore(preview, into: nonemptyDestination.farm, account: nonemptyDestination.account, context: nonemptyDestination.context))
        XCTAssertEqual(try nonemptyDestination.context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == nonemptyDestination.farm.id }.count, 0)

        var decoded = try JSONDecoder.iso8601.decode(FarmBackupEnvelopeV1.self, from: data)
        decoded = .init(schemaVersion: decoded.schemaVersion, payload: decoded.payload, checksum: "bad-checksum")
        let invalid = try JSONEncoder.iso8601.encode(decoded)
        XCTAssertThrowsError(try FarmLocalBackupService.preview(data: invalid))
    }

    func testPortableBackupRestoresSupplementAndPhotoIntoNewLocalFarm() throws {
        let source = try makeFixture(farmName: "可携带备份源牧场")
        let pen = PenRecord(farmID: source.farm.id, name: "恢复圈舍")
        let sheep = SheepRecord(
            farmID: source.farm.id,
            earTag: "PORTABLE-001",
            breed: "湖羊",
            sex: .ewe,
            penID: pen.id,
            enteredAt: .now
        )
        let program = BreedingProgramRecord(farmID: source.farm.id, name: "同步程序")
        let batch = ProductionBatchRecord(
            farmID: source.farm.id,
            name: "育成批次",
            purpose: "育成",
            startedAt: .now
        )
        let photoID = UUID()
        let photoData = Data("portable-photo-bytes".utf8)
        let photoDigest = CloudPayloadDigest.hex(for: photoData)
        let sourcePhotoURL = try PhotoTransferActor.assetURL(
            farmID: source.farm.id,
            assetID: photoID,
            fileExtension: "jpg"
        )
        try photoData.write(to: sourcePhotoURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourcePhotoURL) }

        source.farm.locationDisplayName = "测试牧场位置"
        source.context.insert(pen)
        source.context.insert(sheep)
        source.context.insert(FarmActivity(farmID: source.farm.id, title: "备份活动"))
        source.context.insert(WeaningRecord(
            farmID: source.farm.id,
            sheepID: sheep.id,
            occurredAt: .now,
            weanWeightText: "23.5",
            note: "备份断奶"
        ))
        source.context.insert(program)
        source.context.insert(BreedingProgramStepRecord(
            farmID: source.farm.id,
            programID: program.id,
            dayOffset: 1,
            action: "执行测试步骤",
            sortOrder: 0
        ))
        source.context.insert(batch)
        source.context.insert(BatchMembershipRecord(
            farmID: source.farm.id,
            batchID: batch.id,
            sheepID: sheep.id,
            joinedAt: .now
        ))
        source.context.insert(DailyPenCountRecord(
            farmID: source.farm.id,
            penID: pen.id,
            purpose: sheep.purpose,
            date: Calendar.current.startOfDay(for: .now),
            count: 1
        ))
        source.context.insert(NoteRecord(
            farmID: source.farm.id,
            sheepID: sheep.id,
            text: "需随备份恢复的备注",
            occurredAt: .now
        ))
        source.context.insert(PhotoAssetRecord(
            id: photoID,
            farmID: source.farm.id,
            sheepID: sheep.id,
            legacySourceKey: "portable-photo",
            originalEarTag: sheep.earTag,
            relativePath: PhotoTransferActor.relativePath(for: sourcePhotoURL),
            sha256: photoDigest,
            mimeType: "image/jpeg"
        ))
        source.context.insert(SheepAvatarRecord(
            farmID: source.farm.id,
            sheepID: sheep.id,
            photoAssetID: photoID
        ))
        try source.context.save()

        let data = try FarmPortableBackupService.export(
            farmID: source.farm.id,
            sourceStorageMode: .iCloud,
            sourceAuthorityGeneration: 7,
            sourceWasFullySynchronized: true,
            context: source.context
        )
        let preview = try FarmPortableBackupService.preview(data: data)
        XCTAssertEqual(preview.sourceStorageMode, .iCloud)
        XCTAssertTrue(preview.sourceWasFullySynchronized)
        XCTAssertEqual(preview.photoCount, 1)

        let destinationContainer = try AppSchema.makeContainer(
            name: UUID().uuidString,
            isStoredInMemoryOnly: true
        )
        let destinationContext = ModelContext(destinationContainer)
        let destinationAccount = AccountProfile(
            appleUserIdentifier: UUID().uuidString,
            displayName: "恢复账户"
        )
        destinationContext.insert(destinationAccount)
        try destinationContext.save()

        let result = try FarmPortableBackupService.restoreAsNewLocalFarm(
            preview,
            account: destinationAccount,
            context: destinationContext
        )
        let restoredFarmID = result.farmID
        let restoredPhoto = try XCTUnwrap(
            try destinationContext.fetch(FetchDescriptor<PhotoAssetRecord>())
                .first(where: { $0.farmID == restoredFarmID && $0.id == photoID })
        )
        let restoredPhotoURL = PhotoTransferActor.absoluteURL(for: restoredPhoto.relativePath)
        defer { try? FileManager.default.removeItem(at: restoredPhotoURL) }

        XCTAssertEqual(result.restoredPhotoCount, 1)
        XCTAssertEqual(try Data(contentsOf: restoredPhotoURL), photoData)
        XCTAssertEqual(
            try destinationContext.fetch(FetchDescriptor<FarmStorageProfile>())
                .first(where: { $0.farmID == restoredFarmID })?.mode,
            .localOnly
        )
        XCTAssertNil(
            try destinationContext.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first(where: { $0.farmID == restoredFarmID })
        )
        XCTAssertEqual(
            try destinationContext.fetch(FetchDescriptor<WeaningRecord>())
                .filter { $0.farmID == restoredFarmID }.first?.weanWeightText,
            "23.5"
        )
        XCTAssertEqual(try destinationContext.fetch(FetchDescriptor<BreedingProgramStepRecord>()).filter { $0.farmID == restoredFarmID }.count, 1)
        XCTAssertEqual(try destinationContext.fetch(FetchDescriptor<ProductionBatchRecord>()).filter { $0.farmID == restoredFarmID }.count, 1)
        XCTAssertEqual(try destinationContext.fetch(FetchDescriptor<BatchMembershipRecord>()).filter { $0.farmID == restoredFarmID }.count, 1)
        XCTAssertEqual(try destinationContext.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == restoredFarmID }.first?.text, "需随备份恢复的备注")
        XCTAssertEqual(try destinationContext.fetch(FetchDescriptor<SheepAvatarRecord>()).filter { $0.farmID == restoredFarmID }.first?.photoAssetID, photoID)
        XCTAssertEqual(
            try destinationContext.fetch(FetchDescriptor<FarmRecord>())
                .first(where: { $0.id == restoredFarmID })?.locationDisplayName,
            "测试牧场位置"
        )
    }

    func testFileBackupCannotOverwriteCloudAuthorityFarm() throws {
        let source = try makeFixture()
        source.context.insert(PenRecord(farmID: source.farm.id, name: "备份圈舍"))
        try source.context.save()
        let preview = try FarmLocalBackupService.preview(
            data: FarmLocalBackupService.export(
                farmID: source.farm.id,
                context: source.context
            )
        )

        for mode in [FarmStorageMode.iCloud, .supabase] {
            let destination = try makeFixture(farmName: "云端目标")
            destination.context.insert(FarmStorageProfile(
                farmID: destination.farm.id,
                mode: mode
            ))
            try destination.context.save()

            XCTAssertThrowsError(
                try FarmLocalBackupService.restore(
                    preview,
                    into: destination.farm,
                    account: destination.account,
                    context: destination.context
                )
            ) { error in
                guard case FarmLocalBackupError.cloudTargetForbidden = error else {
                    return XCTFail("应拒绝覆盖云端权威牧场，实际错误：\(error)")
                }
            }
        }
    }

    private func makeFixture(farmName: String = "本地流程牧场") throws -> Fixture {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试账户")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: farmName)
        context.insert(account); context.insert(farm); try context.save()
        return Fixture(container: container, context: context, account: account, farm: farm, service: FarmCommandService())
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let account: AccountProfile
        let farm: FarmRecord
        let service: FarmCommandService
        var farmContext: FarmContext { .init(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role) }
    }
}

private extension JSONDecoder { static var iso8601: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value } }
private extension JSONEncoder { static var iso8601: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]; return value } }
