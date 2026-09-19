import SwiftData
import SwiftUI
import XCTest
@testable import eSheepNext

@MainActor
final class DesignExperienceTests: XCTestCase {
    func testEventExportDoesNotEscalateAdministratorOtherPrivileges() {
        let admin = CapabilitySet(role: .administrator)
        XCTAssertTrue(admin.allows(.exportEvents))
        for capability: FarmCapability in [.exportFarm, .deleteProtectedFacts, .recoverFarm, .manageMembers, .resolveConflicts] {
            XCTAssertFalse(admin.allows(capability))
        }
        XCTAssertTrue(CapabilitySet(role: .owner).allows(.exportEvents))
        XCTAssertFalse(CapabilitySet(role: .worker).allows(.exportEvents))
        XCTAssertTrue(CapabilitySet(role: .worker, grantedWorkerCapabilities: [.exportEvents]).allows(.exportEvents))
        XCTAssertTrue(CapabilitySet(role: .worker, grantedWorkerCapabilities: [.exportFarm]).allows(.exportEvents))
    }

    func testEventExportRechecksRoleAccountAndFarmAtExecution() throws {
        let f = try fixture()
        f.farm.roleRawValue = FarmRole.administrator.rawValue
        let identity = EventExportIdentity(accountProfileID: f.account.id, farmID: f.farm.id)
        XCTAssertNoThrow(try EventExportAuthorization.require(identity, session: f.session, context: f.context))
        f.farm.roleRawValue = FarmRole.worker.rawValue
        XCTAssertThrowsError(try EventExportAuthorization.require(identity, session: f.session, context: f.context))
        f.farm.roleRawValue = FarmRole.administrator.rawValue
        f.session.selectedFarmID = UUID()
        XCTAssertThrowsError(try EventExportAuthorization.require(identity, session: f.session, context: f.context))
        f.session.selectedFarmID = f.farm.id
        f.session.activeAccountProfileID = nil
        XCTAssertThrowsError(try EventExportAuthorization.require(identity, session: f.session, context: f.context))
    }

    func testDraftPersistsAndIsIsolatedByAccountFarmAndEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductionDraftStore(root: root)
        let key = ProductionDraftKey(environment: "dev", accountID: UUID(), farmID: UUID(), form: "weight")
        let draft = ProductionDraft(fields: ["weight": Data("23.4".utf8)], requestIDs: [UUID()])
        try store.save(draft, for: key)
        XCTAssertEqual(try ProductionDraftStore(root: root).load(key), draft)
        for other in [ProductionDraftKey(environment: "release", accountID: key.accountID, farmID: key.farmID, form: key.form), ProductionDraftKey(environment: "dev", accountID: UUID(), farmID: key.farmID, form: key.form), ProductionDraftKey(environment: "dev", accountID: key.accountID, farmID: UUID(), form: key.form)] {
            XCTAssertNil(try store.load(other))
        }
        try store.remove(key)
        XCTAssertNil(try store.load(key))
    }

    func testInterruptedSubmitRecoversReceiptWithoutDuplicatingWeight() throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductionDraftStore(root: root)
        var weight = ""
        var selected: UUID?
        let fields = [ProductionDraftField("kilograms", Binding(get: { weight }, set: { weight = $0 })), ProductionDraftField("sheepID", Binding(get: { selected }, set: { selected = $0 }), reset: { nil })]
        let editor = ProductionEntrySession(store: store)
        editor.configure(form: "weight", account: f.account, farm: f.farm, fields: fields, appSession: f.session, context: f.context, prefill: .init())
        selected = f.sheep.id
        weight = "23.4"
        editor.update(fields: fields)
        let command = FarmCommand.recordWeight(sheepID: f.sheep.id, kilogramsText: weight, occurredAt: .now, note: "")
        try editor.execute(command, in: f.farmContext, context: f.context)
        try editor.execute(command, in: f.farmContext, context: f.context)
        XCTAssertEqual(try f.context.fetchCount(FetchDescriptor<WeightRecord>()), 1)
        let recovered = ProductionEntrySession(store: store)
        recovered.configure(form: "weight", account: f.account, farm: f.farm, fields: fields, appSession: f.session, context: f.context, prefill: .init())
        XCTAssertFalse(recovered.hasRecoverableDraft)
        XCTAssertNil(recovered.draft)
        XCTAssertNotNil(recovered.recoveryNotice)
    }

    func testDraftRestoresTimeModeAcrossSessionsAndKeepsLegacyDate() throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductionDraftStore(root: root)
        let key = ProductionDraftKey(environment: Bundle.main.bundleIdentifier ?? "eSheepNext", accountID: f.account.effectiveAccountID, farmID: f.farm.id, form: "weight")
        let savedDate = Date.now.addingTimeInterval(-600)
        for mode: Bool? in [true, false, nil] {
            var date = Date.now
            var weight = ""
            let saved = ProductionDraft(fields: ["occurredAt": try JSONEncoder().encode(savedDate), "kilograms": try JSONEncoder().encode("25")], usesCurrentTime: mode)
            try store.save(saved, for: key)
            let fields = [ProductionDraftField("occurredAt", Binding(get: { date }, set: { date = $0 }), carry: true), ProductionDraftField("kilograms", Binding(get: { weight }, set: { weight = $0 }))]
            let editor = ProductionEntrySession(store: store)
            editor.configure(form: "weight", account: f.account, farm: f.farm, fields: fields, appSession: f.session, context: f.context, prefill: .init())
            XCTAssertTrue(editor.hasRecoverableDraft)
            editor.recover()
            XCTAssertEqual(editor.usesCurrentTime, mode ?? false)
            XCTAssertEqual(date, savedDate)
            XCTAssertEqual(weight, "25")
            editor.usesCurrentTime.toggle()
            try editor.persist()
            XCTAssertEqual(try store.load(key)?.usesCurrentTime, editor.usesCurrentTime)
        }
    }

    func testInitialFormRowsDoNotCreateDraftOrOverwriteOperatorInput() throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var rows = [String]()
        var amount = ""
        var fields: [ProductionDraftField] {
            [ProductionDraftField("rows", Binding(get: { rows }, set: { rows = $0 })), ProductionDraftField("amount", Binding(get: { amount }, set: { amount = $0 }))]
        }
        let editor = ProductionEntrySession(store: .init(root: root))
        editor.configure(form: "setup", account: f.account, farm: f.farm, fields: fields, appSession: f.session, context: f.context, prefill: .init())
        rows = ["available pen"]
        editor.acceptInitialValues(fields: fields)
        editor.update(fields: fields)
        XCTAssertNil(editor.draft)
        amount = "25"
        editor.update(fields: fields)
        let entered = editor.draft
        editor.acceptInitialValues(fields: fields)
        XCTAssertEqual(editor.draft, entered)
        XCTAssertNotNil(editor.draft)
    }

    func testContinueClearsResultAndSubjectButKeepsTaskParameter() throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var parameter = "湖羊"
        var amount = ""
        var subject: UUID?
        var fields: [ProductionDraftField] { [ProductionDraftField("breed", Binding(get: { parameter }, set: { parameter = $0 }), carry: true), ProductionDraftField("kilograms", Binding(get: { amount }, set: { amount = $0 })), ProductionDraftField("sheepID", Binding(get: { subject }, set: { subject = $0 }), reset: { nil })] }
        let editor = ProductionEntrySession(store: .init(root: root))
        editor.configure(form: "continue", account: f.account, farm: f.farm, fields: fields, appSession: f.session, context: f.context, prefill: .init())
        parameter = "杜泊"
        amount = "31.2"
        subject = f.sheep.id
        editor.update(fields: fields)
        XCTAssertTrue(editor.begin(continuing: true))
        XCTAssertFalse(editor.begin(continuing: true))
        editor.complete()
        editor.isApplyingFields = false
        XCTAssertEqual(parameter, "杜泊")
        XCTAssertEqual(amount, "")
        XCTAssertNil(subject)
        XCTAssertNil(editor.draft)
        editor.update(fields: fields)
        XCTAssertNil(editor.draft, "A disappearing or rerendered saved form must not resurrect its old draft")
        amount = "32.1"
        editor.update(fields: fields)
        XCTAssertTrue(editor.begin(continuing: false))
        editor.complete()
        editor.update(fields: fields)
        XCTAssertNil(editor.draft)
    }

    func testInvalidBatchRollsBackRecordsAndReceipts() throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = ProductionEntrySession(store: .init(root: root))
        editor.configure(form: "batch", account: f.account, farm: f.farm, fields: [], appSession: f.session, context: f.context, prefill: .init())
        XCTAssertThrowsError(try editor.executeBatch([
            .recordWeight(sheepID: f.sheep.id, kilogramsText: "25", occurredAt: .now, note: ""),
            .recordWeight(sheepID: UUID(), kilogramsText: "26", occurredAt: .now, note: "")
        ], in: f.farmContext, context: f.context))
        XCTAssertEqual(try f.context.fetchCount(FetchDescriptor<WeightRecord>()), 0)
        XCTAssertEqual(try f.context.fetchCount(FetchDescriptor<InsightExecutionReceiptRecord>()), 0)
        XCTAssertNotNil(editor.draft)
    }

    func testNewNavigationKeepsFeedAndRecordIntentDestinations() throws {
        let f = try fixture()
        f.session.requestRecordEntry(.tmrFeeding)
        XCTAssertEqual(f.session.selectedTab, .workbench)
        XCTAssertEqual(f.session.workbenchSection, .feeding)
        f.session.requestRecordEntry(.health)
        XCTAssertEqual(f.session.workbenchSection, .records)
        f.session.pendingSearchQuery = "OLD"
        f.session.pendingSheepID = f.sheep.id
        try f.session.switchFarm(to: f.farm.id, availableFarms: [f.farm])
        XCTAssertEqual(f.session.selectedTab, .home)
        XCTAssertNil(f.session.pendingSearchQuery)
        XCTAssertNil(f.session.pendingRecordEntry)
        XCTAssertNil(f.session.pendingSheepID)
    }

    func testTenContinuousWeightsHaveUniqueReceiptsAndNoResidualDraft() throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var weight = ""
        var selected: UUID?
        var date = Date.now.addingTimeInterval(-60)
        var fields: [ProductionDraftField] {
            [ProductionDraftField("kilograms", Binding(get: { weight }, set: { weight = $0 })),
             ProductionDraftField("sheepID", Binding(get: { selected }, set: { selected = $0 }), reset: { nil }),
             ProductionDraftField("occurredAt", Binding(get: { date }, set: { date = $0 }), carry: true)]
        }
        let editor = ProductionEntrySession(store: .init(root: root))
        editor.configure(form: "weight", account: f.account, farm: f.farm, fields: fields, appSession: f.session, context: f.context, prefill: .init())
        for index in 0..<10 {
            let animal = SheepRecord(farmID: f.farm.id, earTag: "QA-\(index + 10)", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now.addingTimeInterval(-3600))
            f.context.insert(animal)
            try f.context.save()
            selected = animal.id; weight = "\(25 + index).5"
            editor.update(fields: fields)
            let started = Date.now
            XCTAssertTrue(editor.begin(continuing: true))
            XCTAssertGreaterThanOrEqual(date, started)
            try editor.execute(.recordWeight(sheepID: animal.id, kilogramsText: weight, occurredAt: date, note: ""), in: f.farmContext, context: f.context)
            editor.complete()
            editor.isApplyingFields = false // SwiftUI delivers the field changes on the next render.
            editor.update(fields: fields)
            XCTAssertNil(selected); XCTAssertEqual(weight, ""); XCTAssertNil(editor.draft)
        }
        XCTAssertEqual(try f.context.fetchCount(FetchDescriptor<WeightRecord>()), 10)
        let receipts = try f.context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>())
        XCTAssertEqual(Set(receipts.map(\.sourceRequestID)).count, 10)
        let manual = Date.now.addingTimeInterval(-600)
        date = manual; editor.update(fields: fields)
        XCTAssertFalse(editor.usesCurrentTime)
        XCTAssertTrue(editor.begin(continuing: true))
        XCTAssertEqual(date, manual)
        editor.endAttempt()
    }

    func testDeferredConfirmationBlocksRepeatedSubmitUntilCancelled() throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = ProductionEntrySession(store: .init(root: root))
        editor.configure(form: "confirmation", account: f.account, farm: f.farm, fields: [], appSession: f.session, context: f.context, prefill: .init())
        XCTAssertTrue(editor.begin(continuing: true))
        editor.holdSubmission(); editor.endAttempt()
        XCTAssertTrue(editor.isSubmitting)
        XCTAssertFalse(editor.begin(continuing: true))
        editor.cancelDeferredSubmission()
        XCTAssertTrue(editor.begin(continuing: false))
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let account: AccountProfile
        let farm: FarmRecord
        let sheep: SheepRecord
        let session: AppSession
        var farmContext: FarmContext { .init(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role) }
    }

    private func fixture() throws -> Fixture {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "隔离测试")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "设计验收测试")
        let sheep = SheepRecord(farmID: farm.id, earTag: "QA-001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now.addingTimeInterval(-3600))
        context.insert(account); context.insert(farm); context.insert(sheep)
        try context.save()
        let session = AppSession(activeAccountProfileID: account.id, persistedLocalSessionAccountID: nil, persistActiveAccountProfileID: { _ in }, clearActiveAccountProfileID: {})
        session.selectedFarmID = farm.id
        return Fixture(container: container, context: context, account: account, farm: farm, sheep: sheep, session: session)
    }
}
