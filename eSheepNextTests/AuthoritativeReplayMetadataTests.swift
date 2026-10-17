import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class AuthoritativeReplayMetadataTests: XCTestCase {
    func testCareEventsKeepDistinctReceiptTimesBeforeContextSave() throws {
        let container = try AppSchema.makeContainer(name: "ReplayMetadata-\(UUID())", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let accountID = UUID()
        let farm = FarmRecord(ownerAccountID: accountID, name: "回放时间")
        let ewe = SheepRecord(farmID: farm.id, earTag: "EWE", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: Date(timeIntervalSince1970: 100))
        context.insert(farm); context.insert(ewe); try context.save()
        let service = RemoteDomainApplyService()
        var expected: [UUID: Date] = [:]
        for index in 0..<2 {
            let occurred = Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 86400)
            let received = occurred.addingTimeInterval(321)
            let batch = CareReproductionBatchDraft(id: UUID(), kind: .pregnancyCheck,
                subjects: [.init(eweID: ewe.id, result: index == 0 ? "复检" : "已孕")],
                occurredAt: occurred, sireID: nil, semenID: nil, semenUnitsPerEweText: nil,
                note: "", reminderAt: occurred.addingTimeInterval(150 * 86400))
            let command = FarmCommand.care(.recordReproductionBatch(batch))
            let payload = ESheepCloudCommandPayloadV2.care(.recordReproductionBatch(batch))
            let event = ESheepCloudEventEnvelopeV2(protocolVersion: ESheepCloudProtocolV2.protocolVersion,
                schemaVersion: ESheepCloudProtocolV2.schemaVersion, farmID: farm.id, farmGeneration: 1,
                eventSequence: Int64(index + 1), eventID: UUID(), commandID: UUID(), sourceCommandDigest: "test",
                stream: .init(type: "careBatch", id: batch.id),
                payload: .businessCommandApplied(commandKind: payload.kind, payload: payload),
                affectedFields: [], eventBodyDigest: "test", beforeDigest: "test", afterDigest: "test",
                actorAccountID: accountID, sourceDeviceID: UUID(), sourceDeviceSequence: Int64(index + 1),
                occurredAt: occurred, receivedAt: received, eventDigest: "test")
            _ = try service.applyV2AuthoritativeCommand(command, event: event, entityType: "careBatch", context: context)
            expected[batch.id] = received
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.batchID == batch.id })
            XCTAssertEqual(row.occurredAt, occurred)
        }
        for row in try context.fetch(FetchDescriptor<ReproductionRecord>()) {
            XCTAssertEqual(row.createdAt, expected[row.batchID!])
            XCTAssertEqual(row.updatedAt, expected[row.batchID!])
        }
        for row in try context.fetch(FetchDescriptor<CareBatchRecord>()) { XCTAssertEqual(row.createdAt, expected[row.id]) }
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
    }

    func testHistoricalSubjectRetainsArchiveFlagInAnalytics() {
        let subject = SheepDetailSubjectSnapshot(id: UUID(), earTag: "ARCHIVE", breed: "", purpose: "",
            sex: .unknown, status: .active, isHistoricalArchive: true, initialPenID: nil,
            currentPenID: nil, birthAt: nil, enteredAt: .distantPast, removedAt: nil)
        XCTAssertTrue(subject.analyticsValue.isHistoricalArchive)
        XCTAssertFalse(subject.analyticsValue.isCurrentlyPresent)
    }
}
