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
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "S3-SH030",
            breed: "湖羊",
            sex: .ewe,
            penID: UUID(),
            enteredAt: Date(timeIntervalSince1970: 100),
            birthAt: Date(timeIntervalSince1970: 50)
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
        context.insert(sheep)
        context.insert(otherSheep)
        context.insert(olderWeight)
        context.insert(newerWeight)
        context.insert(unrelatedWeight)
        context.insert(transfer)
        context.insert(directHealth)
        context.insert(linkedHealth)
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
        let snapshot = try await reader.load(farmID: farmID, sheepID: sheep.id, subject: subject)

        XCTAssertEqual(snapshot.weights.map(\.id), [newerWeight.id, olderWeight.id])
        XCTAssertEqual(snapshot.photos.map(\.id), [photo.id])
        XCTAssertEqual(snapshot.timeline.count, 7)
        XCTAssertEqual(snapshot.timeline.map(\.date), snapshot.timeline.map(\.date).sorted(by: >))
        XCTAssertEqual(snapshot.timeline.first?.id, photo.id)
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
