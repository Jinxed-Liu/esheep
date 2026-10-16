import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class PenManagementPolicyTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, ModelContext, FarmContext) {
        let container = try AppSchema.makeContainer(name: "pens-\(UUID())", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "羊舍测试")
        context.insert(account)
        context.insert(farm)
        context.insert(FarmStorageProfile(farmID: farm.id, mode: .localOnly))
        try context.save()
        return (container, context, FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner))
    }

    func testCreateRenameAndInactiveNamesUseOneFarmScopedRule() throws {
        let (container, context, farm) = try fixture()
        withExtendedLifetime(container) {}
        let service = FarmCommandService()
        try service.execute(.createPen(name: " \nA舍　", note: ""), in: farm, context: context)
        let pen = try XCTUnwrap(context.fetch(FetchDescriptor<PenRecord>()).first)
        XCTAssertEqual(pen.name, "A舍")
        try service.execute(.setPenActive(penID: pen.id, isActive: false), in: farm, context: context)
        XCTAssertThrowsError(try service.execute(.createPen(name: "a舍", note: ""), in: farm, context: context))
        try service.execute(.createPen(name: "B舍", note: ""), in: farm, context: context)
        let other = try XCTUnwrap(context.fetch(FetchDescriptor<PenRecord>()).first { $0.name == "B舍" })
        XCTAssertThrowsError(try service.execute(.updatePen(penID: other.id, name: " a舍 ", note: ""), in: farm, context: context))
        XCTAssertEqual(other.name, "B舍")
        XCTAssertThrowsError(try service.execute(.createPen(name: " \n　", note: ""), in: farm, context: context))
        XCTAssertNoThrow(try PenManagementPolicy.validateName("A舍", farmID: UUID(), context: context))
    }

    func testLegacyDuplicatesStayIntactButCannotBeResolvedByFirstMatch() throws {
        let (container, context, farm) = try fixture()
        withExtendedLifetime(container) {}
        let first = PenRecord(farmID: farm.farmID, name: "一舍")
        let second = PenRecord(farmID: farm.farmID, name: "一舍")
        context.insert(first); context.insert(second); try context.save()
        let service = FarmCommandService()
        try service.execute(.updatePen(penID: first.id, name: "一舍", note: "历史备注"), in: farm, context: context)
        XCTAssertEqual(second.name, "一舍")
        XCTAssertThrowsError(try PenManagementPolicy.resolve("一舍", in: [first, second]))
        try service.execute(.updatePen(penID: first.id, name: "一舍东", note: first.note), in: farm, context: context)
        XCTAssertEqual(try PenManagementPolicy.resolve("一舍", in: [first, second])?.id, second.id)
    }

    func testEmptyActivePenIsNotInactiveOrArchived() {
        let empty = PenManagementRowSnapshot(id: UUID(), name: "备用", note: "", isActive: true, currentSheepCount: 0)
        let inactive = PenManagementRowSnapshot(id: UUID(), name: "旧舍", note: "", isActive: false, currentSheepCount: 0)
        XCTAssertTrue(PenDisplayScope.all.includes(empty))
        XCTAssertTrue(PenDisplayScope.empty.includes(empty))
        XCTAssertFalse(PenDisplayScope.inactive.includes(empty))
        XCTAssertFalse(PenDisplayScope.occupied.includes(empty))
        XCTAssertFalse(PenDisplayScope.empty.includes(inactive))
        XCTAssertTrue(PenDisplayScope.inactive.includes(inactive))
        XCTAssertEqual(empty.statusText, "启用 · 空舍")
        XCTAssertEqual(inactive.statusText, "已停用 · 空舍")
    }

    func testWorkerCannotChangeLifecycleEvenWithLocallyGrantedCapabilities() throws {
        let (container, context, farm) = try fixture()
        withExtendedLifetime(container) {}
        let worker = FarmContext(accountID: farm.accountID, farmID: farm.farmID, role: .worker,
                                 grantedWorkerCapabilities: [.manageCatalogs, .deleteProtectedFacts])
        let service = FarmCommandService()
        try service.execute(.createPen(name: "员工新建", note: ""), in: worker, context: context)
        let pen = try XCTUnwrap(context.fetch(FetchDescriptor<PenRecord>()).first)
        try service.execute(.updatePen(penID: pen.id, name: "员工编辑", note: ""), in: worker, context: context)
        XCTAssertThrowsError(try service.execute(.setPenActive(penID: pen.id, isActive: false), in: worker, context: context))
        XCTAssertThrowsError(try service.execute(.tombstoneEntity(entityType: .pen, entityID: pen.id, reason: "误建"), in: worker, context: context))
        XCTAssertTrue(pen.isActive)
        XCTAssertNil(pen.deletedAt)
    }

    func testUnusedDeletionKeepsAuditAndRestoreCannotCreateDuplicate() throws {
        let (container, context, farm) = try fixture()
        withExtendedLifetime(container) {}
        let service = FarmCommandService()
        try service.execute(.createPen(name: "误建", note: ""), in: farm, context: context)
        let pen = try XCTUnwrap(context.fetch(FetchDescriptor<PenRecord>()).first)
        try service.execute(.tombstoneEntity(entityType: .pen, entityID: pen.id, reason: "重复建档"), in: farm, context: context)
        XCTAssertNotNil(pen.deletedAt)
        let tombstone = try XCTUnwrap(context.fetch(FetchDescriptor<TombstoneRecord>()).first)
        XCTAssertEqual(tombstone.entityID, pen.id)
        XCTAssertEqual(tombstone.reason, "重复建档")
        XCTAssertNotNil(tombstone.operationID)
        try service.execute(.createPen(name: "误建", note: ""), in: farm, context: context)
        XCTAssertThrowsError(try service.execute(.restoreTombstonedEntity(tombstoneID: tombstone.id), in: farm, context: context))
        XCTAssertNotNil(pen.deletedAt)
    }

    func testRevokedFeedHealthNotesAndTMRPlansStillProtectHistoricalPens() throws {
        let (container, context, farm) = try fixture()
        withExtendedLifetime(container) {}
        let pen = PenRecord(farmID: farm.farmID, name: "历史舍")
        context.insert(pen); try context.save()
        let note = NoteRecord(farmID: farm.farmID, penID: pen.id, text: "已撤销的历史备注", occurredAt: .now)
        note.deletedAt = .now
        context.insert(note); try context.save()
        XCTAssertThrowsError(try FarmCommandService().execute(.tombstoneEntity(entityType: .pen, entityID: pen.id, reason: "不应删除"), in: farm, context: context))
        XCTAssertNil(pen.deletedAt)
        XCTAssertEqual(note.text, "已撤销的历史备注")
        // An empty historical pen can be retired without deleting its history.
        try FarmCommandService().execute(.setPenActive(penID: pen.id, isActive: false), in: farm, context: context)
        XCTAssertFalse(pen.isActive)
        XCTAssertNotNil(note.deletedAt)
    }

    func testFeedAndTMRReferencesBlockDeletionWithoutSheepOrTransfers() throws {
        let (container, context, farm) = try fixture()
        withExtendedLifetime(container) {}
        let feedPen = PenRecord(farmID: farm.farmID, name: "投喂历史")
        let planPen = PenRecord(farmID: farm.farmID, name: "计划")
        context.insert(feedPen); context.insert(planPen)
        let feed = FeedRecord(farmID: farm.farmID, penID: feedPen.id, mode: .limited, occurredAt: .now)
        feed.deletedAt = .now
        context.insert(feed)
        context.insert(TMRFeedingPlanPenRecord(farmID: farm.farmID, planID: UUID(), penID: planPen.id, penNameSnapshot: planPen.name))
        try context.save()
        for pen in [feedPen, planPen] {
            XCTAssertThrowsError(try FarmCommandService().execute(.tombstoneEntity(entityType: .pen, entityID: pen.id, reason: "不应删除"), in: farm, context: context))
            XCTAssertNil(pen.deletedAt)
        }
    }

    func testHistoricalFieldReferencesProtectPensWithoutTreatingNotesAsReferences() throws {
        let (container, context, farm) = try fixture()
        withExtendedLifetime(container) {}
        let referenced = PenRecord(farmID: farm.farmID, name: "历史字段")
        let onlyMentioned = PenRecord(farmID: farm.farmID, name: "普通文字")
        context.insert(referenced); context.insert(onlyMentioned)
        for _ in 0..<260 {
            context.insert(DomainOperation(farmID: farm.farmID, accountID: farm.accountID, kind: .care, summary: "其他历史"))
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "field": "initialPenID", "chosen_value": ["type": "uuid", "value": referenced.id.uuidString],
            "note": onlyMentioned.id.uuidString,
        ])
        context.insert(DomainOperation(farmID: farm.farmID, accountID: farm.accountID, kind: .care,
                                      summary: "历史字段更正", entityType: CloudEntityType.sheep.rawValue, payload: payload))
        try context.save()
        XCTAssertTrue(try PenManagementPolicy.hasReferences(penID: referenced.id, farmID: farm.farmID, context: context))
        XCTAssertFalse(try PenManagementPolicy.hasReferences(penID: onlyMentioned.id, farmID: farm.farmID, context: context))
    }
}
