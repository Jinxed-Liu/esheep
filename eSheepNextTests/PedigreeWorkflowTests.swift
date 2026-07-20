import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class PedigreeWorkflowTests: XCTestCase {
    func testCandidateInferenceUsesOnlyHistoricalSamePenBreedingRamsAndNeverConfirms() throws {
        let fixture = try makeFixture()
        let penA = PenRecord(farmID: fixture.farm.id, name: "配种一舍")
        let penB = PenRecord(farmID: fixture.farm.id, name: "配种二舍")
        fixture.context.insert(penA); fixture.context.insert(penB)
        let lambingAt = date("2026-07-20")
        let conceptionAt = date("2026-02-20")
        let ewe = SheepRecord(farmID: fixture.farm.id, earTag: "E001", breed: "湖羊", sex: .ewe, penID: penA.id, enteredAt: date("2025-01-01"))
        let samePen = SheepRecord(farmID: fixture.farm.id, earTag: "BR001", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: penA.id, enteredAt: date("2025-01-01"), birthAt: date("2024-01-01"))
        let ordinaryRam = SheepRecord(farmID: fixture.farm.id, earTag: "R002", breed: "杜泊", isBreedingRam: false, sex: .ram, penID: penA.id, enteredAt: date("2025-01-01"))
        let notEntered = SheepRecord(farmID: fixture.farm.id, earTag: "BR003", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: penA.id, enteredAt: conceptionAt.addingTimeInterval(1))
        let alreadyRemoved = SheepRecord(farmID: fixture.farm.id, earTag: "BR004", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: penA.id, enteredAt: date("2025-01-01"))
        alreadyRemoved.removedAt = conceptionAt.addingTimeInterval(-1)
        let movedTooLate = SheepRecord(farmID: fixture.farm.id, earTag: "BR005", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: penB.id, enteredAt: date("2025-01-01"))
        let movedBefore = SheepRecord(farmID: fixture.farm.id, earTag: "BR006", breed: "杜泊", isBreedingRam: true, sex: .ram, penID: penB.id, enteredAt: date("2025-01-01"))
        let child = SheepRecord(farmID: fixture.farm.id, earTag: "L001", breed: "湖羊", sex: .ewe, penID: penA.id, enteredAt: lambingAt, birthAt: lambingAt, damID: ewe.id)
        [ewe, samePen, ordinaryRam, notEntered, alreadyRemoved, movedTooLate, movedBefore, child].forEach { fixture.context.insert($0) }
        fixture.context.insert(TransferRecord(farmID: fixture.farm.id, sheepID: movedTooLate.id, fromPenID: penB.id, toPenID: penA.id, occurredAt: conceptionAt.addingTimeInterval(1), note: "受胎后转入"))
        fixture.context.insert(TransferRecord(farmID: fixture.farm.id, sheepID: movedBefore.id, fromPenID: penB.id, toPenID: penA.id, occurredAt: conceptionAt.addingTimeInterval(-1), note: "受胎前转入"))
        try fixture.context.save()

        let candidates = try PedigreeAnalysis.sireCandidates(eweID: ewe.id, lambingAt: lambingAt, gestationDays: 150, farmID: fixture.farm.id, context: fixture.context)
        XCTAssertEqual(Set(candidates.map(\.ramID)), Set([samePen.id, movedBefore.id]))
        XCTAssertNil(child.sireID, "候选推算不得自动确权")
        XCTAssertEqual(candidates.first { $0.ramID == samePen.id }?.conceptionAt, conceptionAt)
    }

    func testDirectRamExternalDonorAndLinkedDonorKeepHistoricalSnapshots() throws {
        let fixture = try makeFixture()
        let ewe = insertSheep(fixture, tag: "E001", sex: .ewe)
        let breedingRam = insertSheep(fixture, tag: "BR001", sex: .ram, isBreedingRam: true)
        let ordinaryRam = insertSheep(fixture, tag: "R002", sex: .ram)
        let directDraft = CareLambingDraft(eweID: ewe.id, occurredAt: date("2026-07-20"), sireID: breedingRam.id, semenID: nil, parity: 1, birthDeadCount: 0, offspring: [.init(earTag: "L001", sex: .ewe, birthWeightText: "3.2")], penID: nil, note: "本交")
        try fixture.service.execute(.care(.recordLambing(directDraft)), in: fixture.ownerContext, context: fixture.context)
        XCTAssertEqual(try sheep(fixture, "L001").sireID, breedingRam.id)

        let invalidDraft = CareLambingDraft(eweID: ewe.id, occurredAt: date("2026-07-21"), sireID: ordinaryRam.id, semenID: nil, parity: 2, birthDeadCount: 0, offspring: [.init(earTag: "L002", sex: .ewe, birthWeightText: "3")], penID: nil, note: "")
        XCTAssertThrowsError(try fixture.service.execute(.care(.recordLambing(invalidDraft)), in: fixture.ownerContext, context: fixture.context))

        let external = CareSemenDonorDraft(name: "外部供体A", registrationNumber: "EXT-A", breed: "杜泊")
        try fixture.service.execute(.care(.upsertSemenDonor(external)), in: fixture.ownerContext, context: fixture.context)
        let externalSemen = SemenRecord(farmID: fixture.farm.id, code: "SEM-A", breed: "杜泊", quantityText: "10", donorID: external.id)
        fixture.context.insert(externalSemen); try fixture.context.save()
        let externalLambing = CareLambingDraft(eweID: ewe.id, occurredAt: date("2026-07-22"), sireID: nil, semenID: externalSemen.id, parity: 2, birthDeadCount: 0, offspring: [.init(earTag: "L003", sex: .ram, birthWeightText: "3.4")], penID: nil, note: "外部冻精")
        try fixture.service.execute(.care(.recordLambing(externalLambing)), in: fixture.ownerContext, context: fixture.context)
        let externalChild = try sheep(fixture, "L003")
        XCTAssertNil(externalChild.sireID)
        XCTAssertEqual(externalChild.semenDonorID, external.id)
        XCTAssertEqual(externalChild.semenDonorNameSnapshot, "外部供体A")

        try fixture.service.execute(.care(.upsertSemenDonor(.init(id: external.id, name: "外部供体A-改名", registrationNumber: "EXT-A", breed: "杜泊", note: "新资料", expectedRevision: 1))), in: fixture.ownerContext, context: fixture.context)
        XCTAssertEqual(externalChild.semenDonorNameSnapshot, "外部供体A", "供体档案修改不能静默重写历史后代快照")

        let linked = CareSemenDonorDraft(name: "本场供体", registrationNumber: "LOCAL-B", breed: "杜泊", linkedRamID: breedingRam.id)
        try fixture.service.execute(.care(.upsertSemenDonor(linked)), in: fixture.ownerContext, context: fixture.context)
        let linkedSemen = SemenRecord(farmID: fixture.farm.id, code: "SEM-B", breed: "杜泊", quantityText: "10", donorID: linked.id)
        fixture.context.insert(linkedSemen); try fixture.context.save()
        let linkedLambing = CareLambingDraft(eweID: ewe.id, occurredAt: date("2026-07-23"), sireID: nil, semenID: linkedSemen.id, parity: 3, birthDeadCount: 0, offspring: [.init(earTag: "L004", sex: .ewe, birthWeightText: "3.1")], penID: nil, note: "关联供体")
        try fixture.service.execute(.care(.recordLambing(linkedLambing)), in: fixture.ownerContext, context: fixture.context)
        let linkedChild = try sheep(fixture, "L004")
        XCTAssertEqual(linkedChild.sireID, breedingRam.id)
        XCTAssertEqual(linkedChild.semenDonorID, linked.id)
        XCTAssertEqual(linkedChild.semenDonorRegistrationNumberSnapshot, "LOCAL-B")
    }

    func testPedigreeValidationAuditAndWorkerReadOnly() throws {
        let fixture = try makeFixture()
        let dam = insertSheep(fixture, tag: "E001", sex: .ewe, birthAt: date("2023-01-01"))
        let sire = insertSheep(fixture, tag: "BR001", sex: .ram, isBreedingRam: true, birthAt: date("2023-01-01"))
        let ordinary = insertSheep(fixture, tag: "R002", sex: .ram, birthAt: date("2023-01-01"))
        let child = insertSheep(fixture, tag: "L001", sex: .ewe, birthAt: date("2026-01-01"))

        let valid = CarePedigreeUpdateDraft(sheepID: child.id, damID: dam.id, sireID: sire.id, semenDonorID: nil, reason: "核对产羔本", expectedRevision: child.revision)
        XCTAssertThrowsError(try fixture.service.execute(.care(.updateSheepPedigree(valid)), in: fixture.workerContext, context: fixture.context))
        try fixture.service.execute(.care(.updateSheepPedigree(valid)), in: fixture.ownerContext, context: fixture.context)
        XCTAssertEqual(child.damID, dam.id); XCTAssertEqual(child.sireID, sire.id)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<PedigreeChangeRecord>()).filter { $0.sheepID == child.id }.count, 1)

        XCTAssertThrowsError(try fixture.service.execute(.care(.updateSheepPedigree(.init(sheepID: child.id, damID: child.id, sireID: sire.id, semenDonorID: nil, reason: "错误关系", expectedRevision: child.revision))), in: fixture.ownerContext, context: fixture.context))
        XCTAssertThrowsError(try fixture.service.execute(.care(.updateSheepPedigree(.init(sheepID: child.id, damID: dam.id, sireID: ordinary.id, semenDonorID: nil, reason: "普通公羊", expectedRevision: child.revision))), in: fixture.ownerContext, context: fixture.context))

        let youngerDam = insertSheep(fixture, tag: "E002", sex: .ewe, birthAt: date("2026-02-01"))
        XCTAssertThrowsError(try fixture.service.execute(.care(.updateSheepPedigree(.init(sheepID: child.id, damID: youngerDam.id, sireID: sire.id, semenDonorID: nil, reason: "日期倒置", expectedRevision: child.revision))), in: fixture.ownerContext, context: fixture.context))

        try fixture.service.execute(.care(.updateSheepPedigree(.init(sheepID: dam.id, damID: nil, sireID: nil, semenDonorID: nil, reason: "初始化", expectedRevision: dam.revision))), in: fixture.ownerContext, context: fixture.context)
        XCTAssertThrowsError(try fixture.service.execute(.care(.updateSheepPedigree(.init(sheepID: dam.id, damID: child.id, sireID: nil, semenDonorID: nil, reason: "制造循环", expectedRevision: dam.revision))), in: fixture.ownerContext, context: fixture.context))

        let otherFarm = FarmRecord(ownerAccountID: fixture.account.effectiveAccountID, name: "其他牧场")
        let otherDam = SheepRecord(farmID: otherFarm.id, earTag: "X001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: date("2023-01-01"))
        fixture.context.insert(otherFarm); fixture.context.insert(otherDam); try fixture.context.save()
        XCTAssertThrowsError(try fixture.service.execute(.care(.updateSheepPedigree(.init(sheepID: child.id, damID: otherDam.id, sireID: sire.id, semenDonorID: nil, reason: "跨场", expectedRevision: child.revision))), in: fixture.ownerContext, context: fixture.context))
    }

    func testBreedingPregnancyLambingCorrectionRevokeAndRestoreProtectDownstream() throws {
        let fixture = try makeFixture()
        let birthPen = PenRecord(farmID: fixture.farm.id, name: "产房")
        let laterPen = PenRecord(farmID: fixture.farm.id, name: "羔羊舍")
        fixture.context.insert(birthPen); fixture.context.insert(laterPen)
        let ewe = insertSheep(fixture, tag: "E001", sex: .ewe)
        let ram = insertSheep(fixture, tag: "BR001", sex: .ram, isBreedingRam: true)
        let breedingAt = date("2026-02-20")
        let subject = CareReproductionSubjectDraft(eweID: ewe.id)
        let batch = CareReproductionBatchDraft(id: UUID(), kind: .breeding, subjects: [subject], occurredAt: breedingAt, sireID: ram.id, semenID: nil, semenUnitsPerEweText: nil, note: "本交", reminderAt: date("2026-04-01"))
        try fixture.service.execute(.care(.recordReproductionBatch(batch)), in: fixture.ownerContext, context: fixture.context)
        let breeding = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.batchID == batch.id })

        let check = CareReproductionBatchDraft(id: UUID(), kind: .pregnancyCheck, subjects: [.init(eweID: ewe.id, result: "阳性", relatedBreedingRecordID: breeding.id)], occurredAt: date("2026-04-05"), sireID: nil, semenID: nil, semenUnitsPerEweText: nil, note: "", reminderAt: date("2026-07-20"))
        try fixture.service.execute(.care(.recordReproductionBatch(check)), in: fixture.ownerContext, context: fixture.context)
        let checkFact = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.batchID == check.id })
        XCTAssertEqual(checkFact.relatedBreedingRecordID, breeding.id)
        XCTAssertNil(checkFact.sireID, "孕检不得确认父本")

        let lambingID = UUID()
        let firstLamb = CareLambDraft(earTag: "L001", sex: .ewe, birthWeightText: "3.2")
        let lambing = CareLambingDraft(id: lambingID, eweID: ewe.id, occurredAt: date("2026-07-20"), sireID: nil, semenID: nil, relatedBreedingRecordID: breeding.id, parity: 1, birthDeadCount: 0, offspring: [firstLamb], penID: birthPen.id, note: "顺产")
        try fixture.service.execute(.care(.recordLambing(lambing)), in: fixture.ownerContext, context: fixture.context)
        let child = try sheep(fixture, "L001")
        XCTAssertEqual(child.sireID, ram.id)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<CareReminderRecord>()).filter { $0.sheepID == ewe.id && $0.kind == .expectedLambing }.allSatisfy { $0.status == .completed })

        try fixture.service.execute(.transferSheep(sheepID: child.id, toPenID: laterPen.id, occurredAt: date("2026-07-20"), note: "转入羔羊舍"), in: fixture.ownerContext, context: fixture.context)
        try fixture.service.execute(.recordWeight(sheepID: child.id, kilogramsText: "10", occurredAt: date("2026-07-20"), note: "下游称重"), in: fixture.ownerContext, context: fixture.context)
        let omitted = CareLambDraft(earTag: "L002", sex: .ram, birthWeightText: "3.0")
        let corrected = CareLambingDraft(id: lambingID, eweID: ewe.id, occurredAt: date("2026-07-19"), sireID: nil, semenID: nil, relatedBreedingRecordID: breeding.id, parity: 2, birthDeadCount: 0, offspring: [firstLamb, omitted], penID: birthPen.id, note: "补录双羔")
        try fixture.service.execute(.care(.correctLambing(originalID: lambingID, replacement: corrected, reason: "胎次与羔羊漏录")), in: fixture.ownerContext, context: fixture.context)
        XCTAssertEqual(try sheep(fixture, "L001").birthAt, date("2026-07-19"))
        XCTAssertEqual(child.currentPenID, laterPen.id, "产羔修正不能覆盖后续转舍形成的当前圈舍")
        XCTAssertNotNil(try? sheep(fixture, "L002"))

        try fixture.service.execute(.care(.revokeLambing(recordID: lambingID, reason: "核对发现重复产羔事实")), in: fixture.ownerContext, context: fixture.context)
        XCTAssertNotNil(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.id == lambingID }?.deletedAt)
        XCTAssertNil(child.damID); XCTAssertNil(child.sireID)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<WeightRecord>()).contains { $0.sheepID == child.id && $0.note == "下游称重" && $0.deletedAt == nil })
        XCTAssertNotNil(try sheep(fixture, "L001"), "撤销产羔不能删除羔羊档案")

        try fixture.service.execute(.care(.restoreLambing(recordID: lambingID)), in: fixture.ownerContext, context: fixture.context)
        XCTAssertEqual(child.damID, ewe.id); XCTAssertEqual(child.sireID, ram.id)
        XCTAssertNil(try fixture.context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.id == lambingID }?.deletedAt)

        let removedByCorrection = CareLambingDraft(id: lambingID, eweID: ewe.id, occurredAt: date("2026-07-19"), sireID: nil, semenID: nil, relatedBreedingRecordID: breeding.id, parity: 2, birthDeadCount: 0, offspring: [firstLamb], penID: birthPen.id, note: "复核为单羔")
        try fixture.service.execute(.care(.correctLambing(originalID: lambingID, replacement: removedByCorrection, reason: "删除误录羔羊子项")), in: fixture.ownerContext, context: fixture.context)
        let removedDetail = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<LambingOffspringRecord>()).first { $0.id == omitted.id })
        XCTAssertNotNil(removedDetail.deletedAt)

        try fixture.service.execute(.care(.revokeLambing(recordID: lambingID, reason: "再次核对产羔事实")), in: fixture.ownerContext, context: fixture.context)
        try fixture.service.execute(.care(.restoreLambing(recordID: lambingID)), in: fixture.ownerContext, context: fixture.context)
        XCTAssertNotNil(removedDetail.deletedAt, "恢复产羔不能复活此前由产羔修正删除的子项")
        XCTAssertNil(try sheep(fixture, "L002").damID)
    }

    func testExcelPedigreeAndDonorImportIsAtomicAndBackupRoundTrips() throws {
        let fixture = try makeFixture()
        let dam = insertSheep(fixture, tag: "E001", sex: .ewe, birthAt: date("2023-01-01"))
        let ram = insertSheep(fixture, tag: "BR001", sex: .ram, isBreedingRam: true, birthAt: date("2023-01-01"))
        let child = insertSheep(fixture, tag: "L001", sex: .ewe, birthAt: date("2026-01-01"))
        let data = try XLSXCodec.encode(sheets: [
            XLSXSheet(name: "冻精供体", rows: [
                ["导入键", "供体名称", "登记号", "品种", "关联种公羊耳号", "状态", "备注"],
                ["donor-1", "供体一号", "DONOR-1", "杜泊", "BR001", "在用", "核验登记证"],
            ]),
            XLSXSheet(name: "系谱关系", rows: [
                ["导入键", "羊只耳号", "母本耳号", "父本来源", "种公羊耳号", "供体登记号", "修改原因"],
                ["pedigree-1", "L001", "E001", "冻精供体", "", "DONOR-1", "核对纸质产羔本"],
            ]),
        ])
        let preview = try FarmExcelImportService.preview(data: data, farm: fixture.farm, context: fixture.context, allowedSheetNames: ["冻精供体", "系谱关系"])
        XCTAssertTrue(preview.canCommit, "\(preview.issues)")
        XCTAssertEqual(try FarmExcelImportService.commit(preview, account: fixture.account, farm: fixture.farm, context: fixture.context), 2)
        let donor = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<SemenDonorRecord>()).first { $0.registrationNumber == "DONOR-1" })
        XCTAssertEqual(donor.linkedRamID, ram.id)
        XCTAssertEqual(child.damID, dam.id); XCTAssertEqual(child.sireID, ram.id); XCTAssertEqual(child.semenDonorID, donor.id)

        let backup = try FarmLocalBackupService.export(farmID: fixture.farm.id, context: fixture.context)
        let destination = try makeFixture()
        _ = try FarmLocalBackupService.restore(try FarmLocalBackupService.preview(data: backup), into: destination.farm, account: destination.account, context: destination.context)
        XCTAssertEqual(try destination.context.fetch(FetchDescriptor<SemenDonorRecord>()).filter { $0.farmID == destination.farm.id }.count, 1)
        XCTAssertEqual(try destination.context.fetch(FetchDescriptor<PedigreeChangeRecord>()).filter { $0.farmID == destination.farm.id }.count, 1)
    }

    private func makeFixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(name: "pedigree-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "系谱测试")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "系谱测试牧场")
        context.insert(account); context.insert(farm); try context.save()
        return .init(container: container, context: context, account: account, farm: farm, service: FarmCommandService())
    }

    @discardableResult
    private func insertSheep(_ fixture: Fixture, tag: String, sex: SheepSex, isBreedingRam: Bool = false, birthAt: Date? = nil) -> SheepRecord {
        let record = SheepRecord(farmID: fixture.farm.id, earTag: tag, breed: sex == .ram ? "杜泊" : "湖羊", isBreedingRam: isBreedingRam, sex: sex, penID: nil, enteredAt: date("2022-01-01"), birthAt: birthAt)
        fixture.context.insert(record)
        try? fixture.context.save()
        return record
    }

    private func sheep(_ fixture: Fixture, _ tag: String) throws -> SheepRecord {
        try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<SheepRecord>()).first { $0.farmID == fixture.farm.id && $0.earTag == tag })
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
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
