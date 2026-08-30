import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class SheepDetailSnapshotActorTests: XCTestCase {
    func testDetailSnapshotLoadsTargetRecordsOnceAndIgnoresOtherSheep() async throws {
        let container = try AppSchema.makeContainer(
            name: "sheep-detail-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let penID = UUID()
        let pen = PenRecord(id: penID, farmID: farmID, name: "产羔舍")
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "S3-SH030",
            breed: "湖羊",
            sex: .ewe,
            penID: penID,
            enteredAt: Date(timeIntervalSince1970: 100),
            birthAt: Date(timeIntervalSince1970: 50),
            note: "重点观察"
        )
        let otherSheep = SheepRecord(
            farmID: farmID,
            earTag: "OTHER",
            breed: "杜泊",
            sex: .ram,
            penID: nil,
            enteredAt: Date(timeIntervalSince1970: 100)
        )
        let olderWeight = WeightRecord(
            farmID: farmID,
            sheepID: sheep.id,
            kilogramsText: "40",
            occurredAt: Date(timeIntervalSince1970: 200)
        )
        let newerWeight = WeightRecord(
            farmID: farmID,
            sheepID: sheep.id,
            kilogramsText: "42.5",
            occurredAt: Date(timeIntervalSince1970: 300)
        )
        let unrelatedWeight = WeightRecord(
            farmID: farmID,
            sheepID: otherSheep.id,
            kilogramsText: "90",
            occurredAt: Date(timeIntervalSince1970: 900)
        )
        let weaning = WeaningRecord(
            farmID: farmID,
            sheepID: sheep.id,
            occurredAt: Date(timeIntervalSince1970: 250),
            weanWeightText: "25",
            birthAt: sheep.birthAt,
            birthWeightText: "3.2"
        )
        let unrelatedWeaning = WeaningRecord(
            farmID: farmID,
            sheepID: otherSheep.id,
            occurredAt: Date(timeIntervalSince1970: 950),
            weanWeightText: "70",
            birthAt: Date(timeIntervalSince1970: 40),
            birthWeightText: "5"
        )
        let birthDetail = LambingOffspringRecord(
            farmID: farmID,
            lambingRecordID: UUID(),
            sheepID: sheep.id,
            legacyEarTag: sheep.earTag,
            sexRawValue: LambSex.female.rawValue,
            birthWeightText: "3.2"
        )
        let transfer = TransferRecord(
            farmID: farmID,
            sheepID: sheep.id,
            fromPenID: nil,
            toPenID: UUID(),
            occurredAt: Date(timeIntervalSince1970: 400),
            note: "转入产羔舍"
        )
        let directHealth = HealthRecord(
            farmID: farmID,
            sheepID: sheep.id,
            penID: nil,
            kind: .vaccination,
            itemNameSnapshot: "羊痘疫苗",
            occurredAt: Date(timeIntervalSince1970: 500)
        )
        let linkedHealth = HealthRecord(
            farmID: farmID,
            sheepID: nil,
            penID: UUID(),
            kind: .treatment,
            itemNameSnapshot: "群体驱虫",
            occurredAt: Date(timeIntervalSince1970: 600)
        )
        let unrelatedHealth = HealthRecord(
            farmID: farmID,
            sheepID: otherSheep.id,
            penID: nil,
            kind: .treatment,
            itemNameSnapshot: "其他羊治疗",
            occurredAt: Date(timeIntervalSince1970: 650)
        )
        let healthLink = HealthSubjectLink(
            farmID: farmID,
            healthRecordID: linkedHealth.id,
            sheepID: sheep.id
        )
        let lambing = ReproductionRecord(
            farmID: farmID,
            eweID: sheep.id,
            kind: .lambing,
            occurredAt: Date(timeIntervalSince1970: 700),
            lambCount: 2,
            parity: 1,
            birthDeadCount: 0,
            note: "双羔"
        )
        let photo = PhotoAssetRecord(
            farmID: farmID,
            sheepID: sheep.id,
            legacySourceKey: "photo-1",
            originalEarTag: sheep.earTag,
            relativePath: "photo-1.jpg",
            sha256: "abc"
        )
        photo.capturedAt = Date(timeIntervalSince1970: 800)
        context.insert(pen)
        context.insert(sheep)
        context.insert(otherSheep)
        context.insert(olderWeight)
        context.insert(newerWeight)
        context.insert(unrelatedWeight)
        context.insert(weaning)
        context.insert(unrelatedWeaning)
        context.insert(birthDetail)
        context.insert(transfer)
        context.insert(directHealth)
        context.insert(linkedHealth)
        context.insert(unrelatedHealth)
        context.insert(healthLink)
        context.insert(lambing)
        context.insert(photo)
        try context.save()

        let subject = SheepDetailSubjectSnapshot(
            id: sheep.id,
            earTag: sheep.earTag,
            breed: sheep.breed,
            purpose: sheep.purpose,
            sex: sheep.sex,
            status: sheep.status,
            initialPenID: sheep.initialPenID,
            currentPenID: sheep.currentPenID,
            birthAt: sheep.birthAt,
            enteredAt: sheep.enteredAt,
            removedAt: sheep.removedAt
        )
        let reader = SheepDetailSnapshotActor(container: container)
        let entry = try await reader.loadEntry(farmID: farmID, sheepID: sheep.id)
        let screen = try await reader.loadScreen(farmID: farmID, sheepID: sheep.id)
        let snapshot = try await reader.load(farmID: farmID, sheepID: sheep.id, subject: subject)

        XCTAssertEqual(entry?.subject.id, sheep.id)
        XCTAssertEqual(entry?.subject.earTag, "S3-SH030")
        XCTAssertEqual(entry?.subject.note, "重点观察")
        XCTAssertEqual(entry?.penName, "产羔舍")
        XCTAssertEqual(screen?.entry.subject.id, sheep.id)
        XCTAssertNil(screen?.detailLoadErrorDescription)
        XCTAssertEqual(screen?.detail?.timeline.count, 9)
        XCTAssertEqual(snapshot.weights.map(\.kilograms), [42.5, 25, 40, 3.2])
        XCTAssertEqual(snapshot.weights.map(\.source), [.weighing, .weaning, .weighing, .lambingBirth])
        XCTAssertEqual(snapshot.photos.map(\.id), [photo.id])
        XCTAssertEqual(snapshot.timeline.count, 9)
        XCTAssertEqual(snapshot.timeline.map(\.date), snapshot.timeline.map(\.date).sorted(by: >))
        XCTAssertEqual(snapshot.timeline.first?.id, photo.id)
        XCTAssertTrue(snapshot.timeline.contains { $0.title == "断奶重" && $0.detail == "25 千克" })
        XCTAssertTrue(snapshot.timeline.contains { $0.title == "初生重" && $0.detail == "3.2 千克" })
        XCTAssertFalse(snapshot.timeline.contains { $0.detail.contains("其他羊治疗") })
        XCTAssertEqual(snapshot.lifecycleInsight.summary, "S3-SH030 湖羊")
        XCTAssertEqual(snapshot.reproductionInsight.summary, "S3-SH030 共1胎")

        let workbook = try await reader.singleSheepXLSXData(
            farmID: farmID,
            sheepID: sheep.id,
            penName: "产羔舍"
        )
        XCTAssertFalse(workbook.isEmpty)
    }
}
