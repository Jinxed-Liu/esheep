import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

extension ESheepCloudV2Tests {
    func assertRepairedBusiness(_ container: ModelContainer, root: URL) throws {
        let expected = try ESheepCloudCanonicalCodec.decode([ESheepCloudBusinessBaselineRepairV2].self,
            from: Data(contentsOf: root.appending(path: "expected-business.json")))
        XCTAssertEqual(expected.count, 11_180)
        let context = ModelContext(container)
        let pens = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PenRecord>()).map { ($0.id,$0) })
        let memberships = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BatchMembershipRecord>()).map { ($0.id,$0) })
        let batches = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ProductionBatchRecord>()).map { ($0.id,$0) })
        let offspring = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<LambingOffspringRecord>()).map { ($0.id,$0) })
        let transfers = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TransferRecord>()).map { ($0.id,$0) })
        let reproductions = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ReproductionRecord>()).map { ($0.id,$0) })
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
        for item in expected {
            switch item.projection {
            case .pen(let id, let active):
                XCTAssertEqual(try XCTUnwrap(pens[id]).isActive, active)
            case .batchMembership(let id, let batchID, let sheepID, let joinedAt, let leftAt, let reason):
                let value = try XCTUnwrap(memberships[id])
                XCTAssertEqual(value.batchID,batchID); XCTAssertEqual(value.sheepID,sheepID)
                XCTAssertEqual(value.joinedAt,joinedAt); XCTAssertEqual(value.leftAt,leftAt)
                XCTAssertEqual(value.leaveReason,reason)
            case .productionBatch(let id, let status, let endedAt):
                let value = try XCTUnwrap(batches[id])
                XCTAssertEqual(value.status,status); XCTAssertEqual(value.endedAt,endedAt)
            case .lambingOffspring(let id, let recordID, let sheepID, let sex, let stillborn, let autoSheep, let weightID):
                let value = try XCTUnwrap(offspring[id])
                XCTAssertEqual(value.lambingRecordID,recordID); XCTAssertEqual(value.sheepID,sheepID)
                XCTAssertEqual(value.sexRawValue,sex); XCTAssertEqual(value.isStillborn,stillborn)
                XCTAssertEqual(value.autoCreatedSheep,autoSheep); XCTAssertEqual(value.autoBirthWeightRecordID,weightID)
            case .reproduction(let id, let eweID, let kind, let occurredAt, let batchID, let source, let duplicateID):
                let value = try XCTUnwrap(reproductions[id])
                XCTAssertEqual(value.eweID,eweID); XCTAssertEqual(value.kind,kind)
                XCTAssertEqual(value.occurredAt,occurredAt); XCTAssertEqual(value.batchID,batchID)
                XCTAssertEqual(value.paternalSourceRawValue,source)
                XCTAssertNil(value.deletedAt)
                if let duplicateID {
                    XCTAssertNotNil(try XCTUnwrap(reproductions[duplicateID]).deletedAt)
                    XCTAssertEqual(tombstones.filter { $0.entityID == duplicateID && $0.operationID != nil }.count,1)
                }
            case .transfer(let id, let sheepID, let occurredAt, let fromPenID, let recordedAt):
                let value = try XCTUnwrap(transfers[id])
                XCTAssertEqual(value.sheepID,sheepID); XCTAssertEqual(value.occurredAt,occurredAt)
                XCTAssertEqual(value.fromPenID,fromPenID)
                XCTAssertEqual(value.recordedAt.timeIntervalSince1970,recordedAt.timeIntervalSince1970,accuracy:0.001)
            }
        }
        XCTAssertEqual(reproductions.values.filter { $0.deletedAt == nil }.count,1023)
        XCTAssertEqual(batches.values.filter { $0.deletedAt == nil && $0.status == .completed }.count,30)
        XCTAssertEqual(batches.values.filter { $0.deletedAt == nil && $0.status == .active }.count,10)
        XCTAssertEqual(pens.values.filter { $0.deletedAt == nil && !$0.isActive }.count,3)
        // The source cloud command proves this batch exists. Keep it even
        // though the older developer projection lacked its container model.
        let careBatches = try context.fetch(FetchDescriptor<CareBatchRecord>()).filter { $0.deletedAt == nil }
        XCTAssertEqual(careBatches.map(\.id),[UUID(uuidString:"ab58f706-5f88-dcdb-7988-9cf05b224583")!])
    }
}
