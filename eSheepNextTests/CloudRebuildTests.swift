import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class CloudRebuildTests: XCTestCase {
    func testVerifiedReplacementPreservesPendingOutboxAndReplacesOnlyFarmCache() async throws {
        let container = try AppSchema.makeContainer(name: "rebuild-test", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let otherFarmID = UUID()
        let ownerID = UUID()
        let farm = FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存")
        context.insert(farm)
        context.insert(FarmRecord(id: otherFarmID, ownerAccountID: ownerID, name: "其他牧场"))
        context.insert(PenRecord(farmID: farmID, name: "应被替换"))
        context.insert(PenRecord(farmID: otherFarmID, name: "必须保留"))
        let pendingID = UUID()
        context.insert(OutboxItem(farmID: farmID, accountID: ownerID, operationID: pendingID))
        try context.save()

        let operation = try makeOperation(farmID: farmID, command: .createPen(name: "云端圈舍", note: "已确认"), entityType: .pen)
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation])
        let result = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(using: bundle)

        let verify = ModelContext(container)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.map(\.name), ["云端圈舍"])
        XCTAssertEqual(try verify.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == otherFarmID }.map(\.name), ["必须保留"])
        XCTAssertEqual(try verify.fetch(FetchDescriptor<OutboxItem>()).filter { $0.operationID == pendingID }.count, 1)
        XCTAssertEqual(result.preservedOutboxCount, 1)
        XCTAssertEqual(result.appliedOperationCount, 1)
    }

    func testFailedReplacementRollsBackOldWorkingCache() async throws {
        let container = try AppSchema.makeContainer(name: "rollback-test", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "旧缓存"))
        let oldPen = PenRecord(farmID: farmID, name: "旧圈舍")
        context.insert(oldPen)
        try context.save()

        let missingSheepWeight = try makeOperation(
            farmID: farmID,
            command: .recordWeight(sheepID: UUID(), kilogramsText: "42", occurredAt: .now, note: "无效引用"),
            entityType: .weight
        )
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [missingSheepWeight])

        do {
            _ = try await FarmPersistenceActor(container: container).replaceConfirmedFarmCache(using: bundle)
            XCTFail("缺失引用必须使 staging 提交失败")
        } catch {
            let verify = ModelContext(container)
            let pens = try verify.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }
            XCTAssertEqual(pens.count, 1)
            XCTAssertEqual(pens.first?.id, oldPen.id)
            XCTAssertEqual(pens.first?.name, "旧圈舍")
        }
    }

    func testRepeatedReplacementProducesSameDigestAndNoDuplicateEntity() async throws {
        let container = try AppSchema.makeContainer(name: "idempotent-rebuild", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "测试"))
        try context.save()
        let operation = try makeOperation(farmID: farmID, command: .createPen(name: "稳定圈舍", note: ""), entityType: .pen)
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation])
        let persistence = FarmPersistenceActor(container: container)

        let first = try await persistence.replaceConfirmedFarmCache(using: bundle)
        let second = try await persistence.replaceConfirmedFarmCache(using: bundle)

        XCTAssertEqual(first.entityDigest, second.entityDigest)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.count, 1)
    }

    func testAppSchemaAlwaysUsesExplicitNonCloudKitConfiguration() throws {
        XCTAssertNoThrow(try AppSchema.makeContainer(name: "schema-contract", isStoredInMemoryOnly: true))
    }

    func testDiskStagingStoreCanBeRebuiltAndVerifiedRepeatedly() throws {
        let farmID = UUID()
        let ownerID = UUID()
        let operation = try makeOperation(farmID: farmID, command: .createPen(name: "staging 圈舍", note: ""), entityType: .pen)
        let bundle = makeBundle(farmID: farmID, ownerID: ownerID, operations: [operation])
        let workspace = FileManager.default.temporaryDirectory.appending(path: "CloudRebuildTests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let first = try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)
        try CloudRebuildStagingBuilder.verify(bundle: bundle, workspace: workspace)
        let second = try CloudRebuildStagingBuilder.build(bundle: bundle, workspace: workspace)
        try CloudRebuildStagingBuilder.verify(bundle: bundle, workspace: workspace)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.operationCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appending(path: "SwiftData/staging.store").path))
    }

    private func makeOperation(farmID: UUID, command: FarmCommand, entityType: CloudEntityType) throws -> CloudOperationEnvelope {
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        return CloudOperationEnvelope(
            farmID: farmID,
            entityID: UUID(),
            entityType: entityType.rawValue,
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
    }

    private func makeBundle(farmID: UUID, ownerID: UUID, operations: [CloudOperationEnvelope]) -> CloudRebuildBundle {
        CloudRebuildBundle(
            sessionID: UUID(),
            farmID: farmID,
            scope: .privateDatabase,
            root: CloudRebuildRootSnapshot(farmID: farmID, name: "云端牧场", ownerAccountID: ownerID, modifiedAt: .now),
            operations: operations,
            assets: [],
            membershipSnapshot: nil,
            deletedRecordNames: [],
            pageCount: 2,
            recordCount: operations.count + 1,
            createdAt: .now
        )
    }
}
