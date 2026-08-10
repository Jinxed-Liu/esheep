import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FarmOperationalAlertTests: XCTestCase {
    private let farmID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let validPenID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let timeZoneIdentifier = "Asia/Shanghai"

    func testNoOperationalAlertsAreProducedBeforeRequiredRulesAreConfigured() {
        let now = date("2026-08-09T00:30:00+08:00")
        let sheep = makeSheep(
            earTag: "U001",
            penID: nil,
            birthAt: date("2026-01-01T00:00:00+08:00")
        )

        let snapshot = FarmOperationalAlertEngine.evaluate(
            farmID: farmID,
            timeZoneIdentifier: timeZoneIdentifier,
            now: now,
            rule: nil,
            sheep: [sheep],
            pens: [],
            weanings: [],
            reproduction: [],
            reminders: [],
            deferrals: []
        )

        XCTAssertFalse(snapshot.isConfigured)
        XCTAssertTrue(snapshot.operationalAlerts.isEmpty)
    }

    func testWeaningThresholdUsesFarmCalendarAndDoesNotGuessMissingBirthDates() {
        let now = date("2026-08-09T00:30:00+08:00")
        let calendar = farmCalendar
        let today = calendar.startOfDay(for: now)
        let dueBirth = calendar.date(byAdding: .day, value: -60, to: today)!
        let notDueBirth = calendar.date(byAdding: .day, value: -59, to: today)!
        let due = makeSheep(earTag: "W-DUE", penID: validPenID, birthAt: dueBirth)
        let notDue = makeSheep(earTag: "W-NOT-DUE", penID: validPenID, birthAt: notDueBirth)
        let unknown = makeSheep(earTag: "W-UNKNOWN", penID: validPenID, birthAt: nil)

        let snapshot = evaluate(
            now: now,
            sheep: [due, notDue, unknown],
            pens: [validPen()]
        )

        XCTAssertEqual(snapshot.operationalAlerts.filter { $0.kind == .weaningOverdue }.map(\.subjectID), [due.id])
        XCTAssertEqual(snapshot.missingBirthDateCount, 1)
        XCTAssertEqual(snapshot.operationalAlerts.first { $0.kind == .weaningOverdue }?.dueAt, today)
    }

    func testThirtyFiveDayWeaningRuleWarnsAtConfiguredThreeOrFiveDayLead() {
        let now = date("2026-08-09T12:00:00+08:00")
        let today = farmCalendar.startOfDay(for: now)
        let dueInThreeDays = makeSheep(
            earTag: "W-LEAD-3",
            penID: validPenID,
            birthAt: farmCalendar.date(byAdding: .day, value: -32, to: today)!
        )
        let dueInFiveDays = makeSheep(
            earTag: "W-LEAD-5",
            penID: validPenID,
            birthAt: farmCalendar.date(byAdding: .day, value: -30, to: today)!
        )

        let threeDayLead = evaluate(
            now: now,
            rule: configuredRule(weaningAgeDays: 35, warningLeadDays: 3),
            sheep: [dueInThreeDays, dueInFiveDays],
            pens: [validPen()]
        )
        XCTAssertEqual(
            threeDayLead.operationalAlerts.filter { $0.kind == .weaningDueSoon }.map(\.subjectID),
            [dueInThreeDays.id]
        )
        XCTAssertEqual(
            threeDayLead.operationalAlerts.first { $0.kind == .weaningDueSoon }?.daysUntilDue(
                now: now,
                timeZoneIdentifier: timeZoneIdentifier
            ),
            3
        )

        let fiveDayLead = evaluate(
            now: now,
            rule: configuredRule(weaningAgeDays: 35, warningLeadDays: 5),
            sheep: [dueInThreeDays, dueInFiveDays],
            pens: [validPen()]
        )
        XCTAssertEqual(
            Set(fiveDayLead.operationalAlerts.filter { $0.kind == .weaningDueSoon }.map(\.subjectID)),
            Set([dueInThreeDays.id, dueInFiveDays.id])
        )
    }

    func testWeaningCandidateUsesCurrentProductionStageBeforeHistoricalLambingLink() {
        let now = date("2026-08-09T12:00:00+08:00")
        let oldBirth = date("2026-01-01T00:00:00+08:00")
        let suckling = makeSheep(
            earTag: "STAGE-SUCKLING",
            purpose: "哺乳羔羊",
            penID: validPenID,
            birthAt: oldBirth
        )
        let breedingEwe = makeSheep(
            earTag: "STAGE-ADULT",
            purpose: "繁殖母羊",
            sex: .ewe,
            penID: validPenID,
            birthAt: oldBirth
        )
        let weanedStage = makeSheep(
            earTag: "STAGE-WEANED",
            purpose: "断奶羔羊",
            penID: validPenID,
            birthAt: oldBirth
        )
        let lambingID = UUID()
        let lambing = FarmOperationalAlertEngine.Reproduction(
            id: lambingID,
            eweID: UUID(),
            kind: .lambing,
            occurredAt: oldBirth,
            revision: 1,
            isDeleted: false
        )
        let links = [suckling, breedingEwe, weanedStage].map {
            FarmOperationalAlertEngine.LambingOffspring(
                id: UUID(),
                lambingRecordID: lambingID,
                sheepID: $0.id,
                isStillborn: false,
                revision: 1,
                isDeleted: false
            )
        }

        let snapshot = evaluate(
            now: now,
            sheep: [suckling, breedingEwe, weanedStage],
            pens: [validPen()],
            reproduction: [lambing],
            lambingOffspring: links
        )

        XCTAssertEqual(
            snapshot.operationalAlerts.filter { $0.kind == .weaningOverdue }.map(\.subjectID),
            [suckling.id]
        )
    }

    func testUnclassifiedLambNeedsCurrentCycleEvidenceInsteadOfHistoricalAgeAlone() {
        let now = date("2026-08-09T12:00:00+08:00")
        let rule = configuredRule(weaningAgeDays: 35, warningLeadDays: 5)
        let historicalAdult = makeSheep(
            earTag: "UNCLASSIFIED-OLD",
            purpose: "未分类",
            penID: validPenID,
            birthAt: date("2025-01-01T00:00:00+08:00"),
            createdAt: date("2026-07-01T00:00:00+08:00")
        )
        let youngAtConfiguration = makeSheep(
            earTag: "UNCLASSIFIED-YOUNG",
            purpose: "未分类",
            penID: validPenID,
            birthAt: date("2026-07-06T00:00:00+08:00"),
            createdAt: date("2026-07-06T00:00:00+08:00")
        )
        let linkedAdult = makeSheep(
            earTag: "UNCLASSIFIED-LINKED",
            purpose: "未分类",
            penID: validPenID,
            birthAt: date("2026-06-01T00:00:00+08:00"),
            createdAt: date("2026-06-01T00:00:00+08:00")
        )
        let lambingID = UUID()

        let snapshot = evaluate(
            now: now,
            rule: rule,
            sheep: [historicalAdult, youngAtConfiguration, linkedAdult],
            pens: [validPen()],
            reproduction: [
                .init(
                    id: lambingID,
                    eweID: UUID(),
                    kind: .lambing,
                    occurredAt: linkedAdult.birthAt!,
                    revision: 1,
                    isDeleted: false
                ),
            ],
            lambingOffspring: [
                .init(
                    id: UUID(),
                    lambingRecordID: lambingID,
                    sheepID: linkedAdult.id,
                    isStillborn: false,
                    revision: 1,
                    isDeleted: false
                ),
            ]
        )

        let weaningAlertIDs = Set(snapshot.operationalAlerts.compactMap {
            $0.kind == .weaningOverdue || $0.kind == .weaningDueSoon ? $0.subjectID : nil
        })
        XCTAssertEqual(weaningAlertIDs, Set([youngAtConfiguration.id, linkedAdult.id]))
        XCTAssertFalse(weaningAlertIDs.contains(historicalAdult.id))
    }

    func testDueSoonDeferralCannotHideOverdueTransitionAndPregnancyCheckAlsoWarnsEarly() {
        let warningNow = date("2026-08-09T12:00:00+08:00")
        let warningDay = farmCalendar.startOfDay(for: warningNow)
        let sheep = makeSheep(
            earTag: "W-TRANSITION",
            penID: validPenID,
            birthAt: farmCalendar.date(byAdding: .day, value: -32, to: warningDay)!
        )
        let rule = configuredRule(weaningAgeDays: 35, pregnancyCheckDays: 45, warningLeadDays: 3)
        let warningSnapshot = evaluate(
            now: warningNow,
            rule: rule,
            sheep: [sheep],
            pens: [validPen()]
        )
        let warning = warningSnapshot.operationalAlerts.first { $0.kind == .weaningDueSoon }!

        let dueNow = farmCalendar.date(byAdding: .day, value: 3, to: warningNow)!
        let overdueSnapshot = evaluate(
            now: dueNow,
            rule: rule,
            sheep: [sheep],
            pens: [validPen()],
            deferrals: [deferral(for: warning, now: warningNow)]
        )
        let overdue = overdueSnapshot.operationalAlerts.first { $0.kind == .weaningOverdue }
        XCTAssertNotNil(overdue)
        XCTAssertNotEqual(overdue?.id, warning.id)
        XCTAssertNotEqual(overdue?.conditionFingerprint, warning.conditionFingerprint)

        let ewe = makeSheep(earTag: "E-LEAD", sex: .ewe, penID: validPenID, birthAt: nil)
        let breeding = reproduction(
            eweID: ewe.id,
            kind: .breeding,
            occurredAt: farmCalendar.date(byAdding: .day, value: -42, to: warningNow)!
        )
        let pregnancySnapshot = evaluate(
            now: warningNow,
            rule: rule,
            sheep: [ewe],
            pens: [validPen()],
            reproduction: [breeding]
        )
        XCTAssertEqual(
            pregnancySnapshot.operationalAlerts.first { $0.kind == .pregnancyCheckDueSoon }?.daysUntilDue(
                now: warningNow,
                timeZoneIdentifier: timeZoneIdentifier
            ),
            3
        )
    }

    func testWeaningCalendarBoundaryDiffersFromUTCAtSameInstant() {
        let now = date("2026-08-09T09:00:00+08:00")
        let birthAt = date("2026-08-08T16:00:00Z")
        let sheep = makeSheep(earTag: "TZ001", penID: validPenID, birthAt: birthAt)
        let rule = configuredRule(weaningAgeDays: 1)

        let shanghai = evaluate(
            now: now,
            timeZoneIdentifier: "Asia/Shanghai",
            rule: rule,
            sheep: [sheep],
            pens: [validPen()]
        )
        let utc = evaluate(
            now: now,
            timeZoneIdentifier: "UTC",
            rule: rule,
            sheep: [sheep],
            pens: [validPen()]
        )

        XCTAssertEqual(shanghai.operationalAlerts.count { $0.kind == .weaningOverdue }, 0)
        XCTAssertEqual(utc.operationalAlerts.count { $0.kind == .weaningOverdue }, 1)
    }

    func testDeletedWeaningRevivesAlertWithNewConditionAndRestoredWeaningClosesIt() {
        let now = date("2026-08-09T12:00:00+08:00")
        let sheep = makeSheep(
            earTag: "W001",
            penID: validPenID,
            birthAt: date("2026-04-01T00:00:00+08:00")
        )
        let baseline = evaluate(now: now, sheep: [sheep], pens: [validPen()])
        let baselineAlert = baseline.operationalAlerts.first { $0.kind == .weaningOverdue }!
        let weaningID = UUID()
        let validWeaning = FarmOperationalAlertEngine.Weaning(
            id: weaningID,
            sheepID: sheep.id,
            revision: 1,
            isDeleted: false
        )
        let completed = evaluate(
            now: now,
            sheep: [sheep],
            pens: [validPen()],
            weanings: [validWeaning],
            deferrals: [deferral(for: baselineAlert, now: now)]
        )
        XCTAssertFalse(completed.operationalAlerts.contains { $0.kind == .weaningOverdue })

        let deletedWeaning = FarmOperationalAlertEngine.Weaning(
            id: weaningID,
            sheepID: sheep.id,
            revision: 2,
            isDeleted: true
        )
        let revived = evaluate(
            now: now,
            sheep: [sheep],
            pens: [validPen()],
            weanings: [deletedWeaning],
            deferrals: [deferral(for: baselineAlert, now: now)]
        )
        let revivedAlert = revived.operationalAlerts.first { $0.kind == .weaningOverdue }
        XCTAssertNotNil(revivedAlert)
        XCTAssertNotEqual(revivedAlert?.conditionFingerprint, baselineAlert.conditionFingerprint)

        let restored = FarmOperationalAlertEngine.Weaning(
            id: weaningID,
            sheepID: sheep.id,
            revision: 3,
            isDeleted: false
        )
        let restoredSnapshot = evaluate(
            now: now,
            sheep: [sheep],
            pens: [validPen()],
            weanings: [restored]
        )
        XCTAssertFalse(restoredSnapshot.operationalAlerts.contains { $0.kind == .weaningOverdue })
    }

    func testRemovedDeceasedAndHistoricalSheepNeverProduceOperationalAlerts() {
        let now = date("2026-08-09T12:00:00+08:00")
        let birthAt = date("2025-01-01T00:00:00+08:00")
        let removed = makeSheep(earTag: "R001", status: .removed, penID: nil, birthAt: birthAt)
        let deceased = makeSheep(earTag: "D001", status: .deceased, penID: nil, birthAt: birthAt)
        let historical = makeSheep(earTag: "H001", isHistoricalArchive: true, penID: nil, birthAt: birthAt)

        let snapshot = evaluate(now: now, sheep: [removed, deceased, historical], pens: [])

        XCTAssertTrue(snapshot.operationalAlerts.isEmpty)
        XCTAssertEqual(snapshot.missingBirthDateCount, 0)
    }

    func testOnlyLatestBreedingCycleIsEvaluatedAndLaterFactsCloseIt() {
        let now = date("2026-08-09T12:00:00+08:00")
        let calendar = farmCalendar
        let ewe = makeSheep(earTag: "E001", sex: .ewe, penID: validPenID, birthAt: nil)
        let oldBreeding = reproduction(
            eweID: ewe.id,
            kind: .breeding,
            occurredAt: calendar.date(byAdding: .day, value: -80, to: now)!
        )
        let newBreeding = reproduction(
            eweID: ewe.id,
            kind: .breeding,
            occurredAt: calendar.date(byAdding: .day, value: -20, to: now)!
        )

        let superseded = evaluate(
            now: now,
            sheep: [ewe],
            pens: [validPen()],
            reproduction: [oldBreeding, newBreeding]
        )
        XCTAssertFalse(superseded.operationalAlerts.contains { $0.kind == .pregnancyCheckOverdue })

        let overdue = evaluate(
            now: now,
            sheep: [ewe],
            pens: [validPen()],
            reproduction: [oldBreeding]
        )
        let originalAlert = overdue.operationalAlerts.first { $0.kind == .pregnancyCheckOverdue }!
        XCTAssertEqual(originalAlert.sourceEntityID, oldBreeding.id)

        let pregnancyCheck = reproduction(
            eweID: ewe.id,
            kind: .pregnancyCheck,
            occurredAt: calendar.date(byAdding: .day, value: -30, to: now)!
        )
        let closed = evaluate(
            now: now,
            sheep: [ewe],
            pens: [validPen()],
            reproduction: [oldBreeding, pregnancyCheck]
        )
        XCTAssertFalse(closed.operationalAlerts.contains { $0.kind == .pregnancyCheckOverdue })

        let deletedCheck = FarmOperationalAlertEngine.Reproduction(
            id: pregnancyCheck.id,
            eweID: pregnancyCheck.eweID,
            kind: pregnancyCheck.kind,
            occurredAt: pregnancyCheck.occurredAt,
            revision: 2,
            isDeleted: true
        )
        let revived = evaluate(
            now: now,
            sheep: [ewe],
            pens: [validPen()],
            reproduction: [oldBreeding, deletedCheck],
            deferrals: [deferral(for: originalAlert, now: now)]
        )
        XCTAssertEqual(revived.operationalAlerts.count { $0.kind == .pregnancyCheckOverdue }, 1)
    }

    func testNilInactiveDeletedAndCrossFarmPenReferencesAreInvalid() {
        let now = date("2026-08-09T12:00:00+08:00")
        let inactivePenID = UUID()
        let deletedPenID = UUID()
        let crossFarmPenID = UUID()
        let valid = makeSheep(earTag: "P-VALID", penID: validPenID, birthAt: nil)
        let none = makeSheep(earTag: "P-NONE", penID: nil, birthAt: nil)
        let inactive = makeSheep(earTag: "P-INACTIVE", penID: inactivePenID, birthAt: nil)
        let deleted = makeSheep(earTag: "P-DELETED", penID: deletedPenID, birthAt: nil)
        let crossFarm = makeSheep(earTag: "P-CROSS", penID: crossFarmPenID, birthAt: nil)
        let pens = [
            validPen(),
            .init(id: inactivePenID, isActive: false, revision: 2, isDeleted: false),
            .init(id: deletedPenID, isActive: true, revision: 2, isDeleted: true),
        ]

        let snapshot = evaluate(
            now: now,
            sheep: [valid, none, inactive, deleted, crossFarm],
            pens: pens
        )
        let subjects = Set(snapshot.operationalAlerts.filter { $0.kind == .invalidPen }.map(\.subjectID))

        XCTAssertEqual(subjects, Set([none.id, inactive.id, deleted.id, crossFarm.id]))
        XCTAssertFalse(subjects.contains(valid.id))
    }

    func testDeferralRequiresExactConditionExpiresAndCannotBecomePermanentIgnore() {
        let now = date("2026-08-09T12:00:00+08:00")
        let sheep = makeSheep(
            earTag: "S001",
            penID: validPenID,
            birthAt: date("2026-01-01T00:00:00+08:00")
        )
        let initial = evaluate(now: now, sheep: [sheep], pens: [validPen()])
        let alert = initial.operationalAlerts.first { $0.kind == .weaningOverdue }!

        let deferred = evaluate(
            now: now,
            sheep: [sheep],
            pens: [validPen()],
            deferrals: [deferral(for: alert, now: now)]
        )
        XCTAssertFalse(deferred.operationalAlerts.contains { $0.kind == .weaningOverdue })

        let expired = FarmOperationalAlertEngine.Deferral(
            alertID: alert.id,
            conditionFingerprint: alert.conditionFingerprint,
            deferredAt: now.addingTimeInterval(-2 * 86_400),
            deferredUntil: now.addingTimeInterval(-1)
        )
        XCTAssertTrue(evaluate(
            now: now,
            sheep: [sheep],
            pens: [validPen()],
            deferrals: [expired]
        ).operationalAlerts.contains { $0.kind == .weaningOverdue })

        let permanent = FarmOperationalAlertEngine.Deferral(
            alertID: alert.id,
            conditionFingerprint: alert.conditionFingerprint,
            deferredAt: now,
            deferredUntil: now.addingTimeInterval(365 * 86_400)
        )
        XCTAssertTrue(evaluate(
            now: now,
            sheep: [sheep],
            pens: [validPen()],
            deferrals: [permanent]
        ).operationalAlerts.contains { $0.kind == .weaningOverdue })

        XCTAssertTrue(evaluate(
            now: now,
            rule: configuredRule(weaningAgeDays: 61),
            sheep: [sheep],
            pens: [validPen()],
            deferrals: [deferral(for: alert, now: now)]
        ).operationalAlerts.contains { $0.kind == .weaningOverdue })
    }

    func testDeferralPlanUsesOnlyOneThreeOrSevenFarmCalendarDays() {
        let now = date("2026-08-09T12:00:00+08:00")
        XCTAssertEqual(
            FarmOperationalAlertDeferralPlan.deferredUntil(
                days: 1,
                now: now,
                timeZoneIdentifier: timeZoneIdentifier,
                minuteOfDay: 480
            ),
            date("2026-08-10T08:00:00+08:00")
        )
        XCTAssertEqual(
            FarmOperationalAlertDeferralPlan.deferredUntil(
                days: 3,
                now: now,
                timeZoneIdentifier: timeZoneIdentifier,
                minuteOfDay: 480
            ),
            date("2026-08-12T08:00:00+08:00")
        )
        XCTAssertEqual(
            FarmOperationalAlertDeferralPlan.deferredUntil(
                days: 7,
                now: now,
                timeZoneIdentifier: timeZoneIdentifier,
                minuteOfDay: 480
            ),
            date("2026-08-16T08:00:00+08:00")
        )
        XCTAssertNil(FarmOperationalAlertDeferralPlan.deferredUntil(
            days: 30,
            now: now,
            timeZoneIdentifier: timeZoneIdentifier,
            minuteOfDay: 480
        ))
    }

    func testPendingOverdueReminderFilteringAndFarmIsolationInBackgroundSnapshot() async throws {
        let container = try AppSchema.makeContainer(
            name: "alerts-reminders-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试")
        let farm = FarmRecord(id: farmID, ownerAccountID: account.effectiveAccountID, name: "本场")
        let otherFarm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "其他场")
        context.insert(account)
        context.insert(farm)
        context.insert(otherFarm)
        context.insert(FarmCareRuleRecord(
            farmID: farm.id,
            weaningAgeDays: 60,
            operationalAlertsConfiguredAt: .now,
            alertDigestEnabled: true
        ))
        let now = date("2026-08-09T12:00:00+08:00")
        let pending = reminder(farmID: farm.id, title: "本场待办", dueAt: now.addingTimeInterval(-60))
        let completed = reminder(farmID: farm.id, title: "已完成", dueAt: now.addingTimeInterval(-120))
        completed.statusRawValue = CareReminderStatus.completed.rawValue
        let dismissed = reminder(farmID: farm.id, title: "已忽略", dueAt: now.addingTimeInterval(-180))
        dismissed.statusRawValue = CareReminderStatus.dismissed.rawValue
        let future = reminder(farmID: farm.id, title: "未到期", dueAt: now.addingTimeInterval(60))
        let other = reminder(farmID: otherFarm.id, title: "其他场待办", dueAt: now.addingTimeInterval(-60))
        [pending, completed, dismissed, future, other].forEach(context.insert)
        try context.save()

        let snapshot = try await FarmOperationalAlertSnapshotActor(container: container).load(
            farmID: farm.id,
            now: now
        )

        XCTAssertEqual(snapshot.overdueReminders.map(\.title), ["本场待办"])
    }

    func testRuleAndDeferralCommandsUsePermissionsAuditAndOutbox() throws {
        XCTAssertEqual(
            CloudOperationSecurity.requiredCapability(
                for: CloudEntityType.careRule.rawValue,
                deletedAt: nil
            ),
            .manageCatalogs
        )
        XCTAssertEqual(
            CloudOperationSecurity.requiredCapability(
                for: CloudEntityType.alertDeferral.rawValue,
                deletedAt: nil
            ),
            .recordProduction
        )

        let container = try AppSchema.makeContainer(
            name: "alerts-command-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "测试场")
        context.insert(account)
        context.insert(farm)
        try context.save()
        let service = FarmCommandService()
        let owner = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner)
        let worker = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: .worker)
        let ruleID = UUID()
        let ruleDraft = FarmOperationalAlertRuleDraft(
            id: ruleID,
            pregnancyCheckDays: 42,
            gestationDays: 150,
            weaningAgeDays: 65,
            warningLeadDays: 5,
            digestEnabled: true,
            digestMinuteOfDay: 510
        )

        XCTAssertThrowsError(try service.execute(
            .care(.updateOperationalAlertRules(ruleDraft)),
            in: worker,
            context: context
        ))
        try service.execute(.care(.updateOperationalAlertRules(ruleDraft)), in: owner, context: context)
        let rule = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first)
        XCTAssertEqual(rule.id, ruleID)
        XCTAssertEqual(rule.weaningAgeDays, 65)
        XCTAssertEqual(rule.warningLeadDays, 5)
        XCTAssertEqual(rule.alertDigestMinuteOfDay, 510)
        XCTAssertNotNil(rule.operationalAlertsConfiguredAt)

        let alertID = UUID()
        let deferralDraft = FarmAlertDeferralDraft(
            id: alertID,
            alertID: alertID,
            alertKindRawValue: FarmOperationalAlertKind.invalidPen.rawValue,
            subjectID: UUID(),
            sourceEntityID: nil,
            conditionFingerprint: "condition-v1",
            deferredUntil: .now.addingTimeInterval(3 * 86_400)
        )
        try service.execute(.care(.deferOperationalAlert(deferralDraft)), in: worker, context: context)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).first)
        XCTAssertEqual(record.alertID, alertID)
        XCTAssertEqual(record.deferredByAccountID, account.effectiveAccountID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DomainOperation>()).contains {
            $0.entityType == CloudEntityType.alertDeferral.rawValue && $0.entityID == alertID
        })
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutboxItem>()).contains {
            $0.entityType == CloudEntityType.alertDeferral.rawValue && $0.entityID == alertID
        })
    }

    func testOldRulePayloadStillDecodesWithoutEnablingOperationalAlerts() throws {
        let ruleID = UUID()
        let encoded = try FarmCommandCloudPayloadEncoder.encode(
            .care(.updateRules(id: ruleID, pregnancyCheckDays: 50, gestationDays: 152))
        )
        let decoded = try FarmCommandCloudPayloadDecoder.decode(encoded)

        guard case .care(.updateRules(let decodedID, let checkDays, let gestationDays)) = decoded else {
            return XCTFail("旧规则命令未按原格式解码")
        }
        XCTAssertEqual(decodedID, ruleID)
        XCTAssertEqual(checkDays, 50)
        XCTAssertEqual(gestationDays, 152)
    }

    func testV9PointZeroOperationalRulePayloadWithoutLeadDaysStillDecodesAsDisabled() throws {
        let encoded = try FarmCommandCloudPayloadEncoder.encode(.care(.updateOperationalAlertRules(.init(
            id: UUID(),
            pregnancyCheckDays: 45,
            gestationDays: 150,
            weaningAgeDays: 35,
            digestEnabled: true,
            digestMinuteOfDay: 480
        ))))
        let decoded = try FarmCommandCloudPayloadDecoder.decode(encoded)

        guard case .care(.updateOperationalAlertRules(let draft)) = decoded else {
            return XCTFail("V9.0 异常规则命令未按兼容格式解码")
        }
        XCTAssertNil(draft.warningLeadDays)
        XCTAssertEqual(draft.effectiveWarningLeadDays, 0)
    }

    func testOldExcelRuleSheetStaysUnconfiguredAndNewColumnsEnableAlerts() throws {
        let container = try AppSchema.makeContainer(
            name: "alerts-excel-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "测试场")
        context.insert(account)
        context.insert(farm)
        try context.save()

        let oldWorkbook = try XLSXCodec.encode(sheets: [
            .init(name: "提醒规则", rows: [
                ["导入键", "孕检间隔天", "妊娠周期天"],
                ["old-rule", "47", "151"],
            ]),
        ])
        let oldPreview = try FarmExcelImportService.preview(data: oldWorkbook, farm: farm, context: context)
        XCTAssertTrue(oldPreview.canCommit, oldPreview.issues.map(\.message).joined(separator: "\n"))
        _ = try FarmExcelImportService.commit(oldPreview, account: account, farm: farm, context: context)
        let legacyRule = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first)
        XCTAssertEqual(legacyRule.pregnancyCheckDays, 47)
        XCTAssertNil(legacyRule.weaningAgeDays)
        XCTAssertNil(legacyRule.operationalAlertsConfiguredAt)

        let newWorkbook = try XLSXCodec.encode(sheets: [
            .init(name: "提醒规则", rows: [
                ["导入键", "孕检间隔天", "妊娠周期天", "断奶日龄", "每日汇总时间"],
                ["new-rule", "48", "152", "63", "08:30"],
            ]),
        ])
        let newPreview = try FarmExcelImportService.preview(data: newWorkbook, farm: farm, context: context)
        XCTAssertTrue(newPreview.canCommit, newPreview.issues.map(\.message).joined(separator: "\n"))
        _ = try FarmExcelImportService.commit(newPreview, account: account, farm: farm, context: context)

        XCTAssertEqual(legacyRule.pregnancyCheckDays, 48)
        XCTAssertEqual(legacyRule.gestationDays, 152)
        XCTAssertEqual(legacyRule.weaningAgeDays, 63)
        XCTAssertEqual(legacyRule.alertDigestMinuteOfDay, 510)
        XCTAssertEqual(legacyRule.warningLeadDays, 0)
        XCTAssertTrue(legacyRule.alertDigestEnabled)
        XCTAssertNotNil(legacyRule.operationalAlertsConfiguredAt)

        let currentWorkbook = try XLSXCodec.encode(sheets: [
            .init(name: "提醒规则", rows: [
                ["导入键", "孕检间隔天", "妊娠周期天", "断奶日龄", "提前预警天数", "每日汇总时间"],
                ["current-rule", "49", "153", "35", "5", "08:30"],
            ]),
        ])
        let currentPreview = try FarmExcelImportService.preview(data: currentWorkbook, farm: farm, context: context)
        XCTAssertTrue(currentPreview.canCommit, currentPreview.issues.map(\.message).joined(separator: "\n"))
        _ = try FarmExcelImportService.commit(currentPreview, account: account, farm: farm, context: context)
        XCTAssertEqual(legacyRule.weaningAgeDays, 35)
        XCTAssertEqual(legacyRule.warningLeadDays, 5)
    }

    func testBackupRestoreAndProviderNeutralBaselinePreserveConfiguredRulesAndDeferrals() throws {
        let container = try AppSchema.makeContainer(
            name: "alerts-backup-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "测试")
        let sourceFarm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "来源场")
        context.insert(account)
        context.insert(sourceFarm)
        let configuredAt = date("2026-08-01T08:00:00+08:00")
        let subject = SheepRecord(
            farmID: sourceFarm.id,
            earTag: "BACKUP-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: date("2026-01-01T00:00:00+08:00")
        )
        let rule = FarmCareRuleRecord(
            farmID: sourceFarm.id,
            pregnancyCheckDays: 43,
            gestationDays: 151,
            weaningAgeDays: 66,
            warningLeadDays: 5,
            operationalAlertsConfiguredAt: configuredAt,
            alertDigestEnabled: true,
            alertDigestMinuteOfDay: 495
        )
        let conditionFingerprint = "backup-condition"
        let sourceAlertName = [
            "operational-alert",
            FarmOperationalAlertKind.invalidPen.rawValue,
            subject.id.uuidString.lowercased(),
            "none",
            conditionFingerprint,
        ].joined(separator: ":")
        let sourceAlertID = StableCloudUUID.derived(namespace: sourceFarm.id, name: sourceAlertName)
        let deferral = FarmAlertDeferralRecord(
            id: sourceAlertID,
            farmID: sourceFarm.id,
            alertID: sourceAlertID,
            alertKindRawValue: FarmOperationalAlertKind.invalidPen.rawValue,
            subjectID: subject.id,
            conditionFingerprint: conditionFingerprint,
            deferredUntil: date("2026-08-12T08:15:00+08:00"),
            deferredByAccountID: account.effectiveAccountID,
            createdAt: date("2026-08-09T08:15:00+08:00")
        )
        context.insert(rule)
        context.insert(subject)
        context.insert(deferral)
        try context.save()

        let baseline = try MigrationCloudBootstrapService().makeProviderNeutralSnapshots(
            farm: sourceFarm,
            context: context
        )
        XCTAssertTrue(baseline.contains { $0.entityType == .careRule && $0.entityID == rule.id })
        XCTAssertTrue(baseline.contains { $0.entityType == .alertDeferral && $0.entityID == deferral.id })

        let backup = try FarmLocalBackupService.export(farmID: sourceFarm.id, context: context)
        let destinationContainer = try AppSchema.makeContainer(
            name: "alerts-restore-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let destinationContext = ModelContext(destinationContainer)
        let destinationAccount = AccountProfile(
            appleUserIdentifier: UUID().uuidString,
            displayName: "恢复测试"
        )
        let destinationFarm = FarmRecord(
            ownerAccountID: destinationAccount.effectiveAccountID,
            name: "恢复场"
        )
        destinationContext.insert(destinationAccount)
        destinationContext.insert(destinationFarm)
        try destinationContext.save()
        _ = try FarmLocalBackupService.restore(
            try FarmLocalBackupService.preview(data: backup),
            into: destinationFarm,
            account: destinationAccount,
            context: destinationContext
        )

        let restoredRule = try XCTUnwrap(try destinationContext.fetch(FetchDescriptor<FarmCareRuleRecord>()).first {
            $0.farmID == destinationFarm.id
        })
        let restoredDeferral = try XCTUnwrap(try destinationContext.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).first {
            $0.farmID == destinationFarm.id
        })
        XCTAssertEqual(restoredRule.weaningAgeDays, 66)
        XCTAssertEqual(restoredRule.warningLeadDays, 5)
        XCTAssertEqual(restoredRule.operationalAlertsConfiguredAt, configuredAt)
        XCTAssertTrue(restoredRule.alertDigestEnabled)
        XCTAssertEqual(restoredRule.alertDigestMinuteOfDay, 495)
        XCTAssertEqual(restoredDeferral.conditionFingerprint, "backup-condition")
        XCTAssertEqual(restoredDeferral.deferredByAccountID, account.effectiveAccountID)
        let restoredAlertID = StableCloudUUID.derived(namespace: destinationFarm.id, name: sourceAlertName)
        XCTAssertEqual(restoredDeferral.alertID, restoredAlertID)
        XCTAssertNotEqual(restoredDeferral.alertID, deferral.alertID)
    }

    func testRemoteDeferralReplayIsIdempotentAndKeepsEnvelopeOperator() throws {
        let container = try AppSchema.makeContainer(
            name: "alerts-remote-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let alertID = UUID()
        let modifiedAt = date("2026-08-09T09:00:00+08:00")
        let draft = FarmAlertDeferralDraft(
            id: alertID,
            alertID: alertID,
            alertKindRawValue: FarmOperationalAlertKind.weaningOverdue.rawValue,
            subjectID: UUID(),
            sourceEntityID: nil,
            conditionFingerprint: "remote-condition",
            deferredUntil: date("2026-08-12T08:00:00+08:00")
        )
        let payload = try FarmCommandCloudPayloadEncoder.encode(.care(.deferOperationalAlert(draft)))
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: alertID,
            entityType: CloudEntityType.alertDeferral.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: modifiedAt,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        XCTAssertEqual(
            try RemoteDomainApplyService().apply(envelope, context: context),
            .applied(rebuildHistoryFrom: nil)
        )
        XCTAssertEqual(try RemoteDomainApplyService().apply(envelope, context: context), .duplicate)
        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).first)
        XCTAssertEqual(record.deferredByAccountID, accountID)
        XCTAssertEqual(record.updatedAt, modifiedAt)
        XCTAssertEqual(record.revision, 1)
    }

    func testDigestPlanUsesOneStableIdentifierPrivateBodyAndFarmTimeZone() {
        let now = date("2026-08-09T07:30:00+08:00")
        let today = FarmOperationalAlertDigestPlan.nextDeliveryDate(
            now: now,
            timeZoneIdentifier: timeZoneIdentifier,
            minuteOfDay: 480
        )
        let afterDigest = FarmOperationalAlertDigestPlan.nextDeliveryDate(
            now: date("2026-08-09T08:30:00+08:00"),
            timeZoneIdentifier: timeZoneIdentifier,
            minuteOfDay: 480
        )

        XCTAssertEqual(FarmOperationalAlertDigestPlan.identifier(farmID: farmID), "operational-alert:\(farmID.uuidString.lowercased())")
        XCTAssertEqual(FarmOperationalAlertDigestPlan.body(count: 4), "有 4 项待处理事项，打开应用查看详情。")
        XCTAssertEqual(today, date("2026-08-09T08:00:00+08:00"))
        XCTAssertEqual(afterDigest, date("2026-08-10T08:00:00+08:00"))
        XCTAssertNil(FarmOperationalAlertDigestPlan.nextDeliveryDate(
            now: now,
            timeZoneIdentifier: "Invalid/TimeZone",
            minuteOfDay: 480
        ))
    }

    func testDigestNotificationRouteSwitchesFarmAndRequestsExceptionCenter() throws {
        let route = FarmNotificationRoute(farmID: farmID, kind: .openOperationalAlerts)
        let decodedRoute = try XCTUnwrap(FarmNotificationRoute(userInfo: route.userInfo))
        XCTAssertEqual(decodedRoute, route)

        FarmSystemNavigationStore.enqueue(.init(
            farmID: farmID,
            kind: .openOperationalAlerts,
            entityID: nil,
            query: nil
        ))
        let session = AppSession(
            activeAccountProfileID: nil,
            persistedLocalSessionAccountID: nil,
            persistActiveAccountProfileID: { _ in },
            clearActiveAccountProfileID: {}
        )
        session.consumeSystemNavigationTarget()

        XCTAssertEqual(session.selectedFarmID, farmID)
        XCTAssertEqual(session.selectedTab, .home)
        XCTAssertNotNil(session.pendingOperationalAlertsRequestID)
    }

    func testLargeFarmSnapshotKeepsExpectedCountsWithoutRepeatedQueries() {
        let now = date("2026-08-09T12:00:00+08:00")
        let oldBirthDate = date("2026-01-01T00:00:00+08:00")
        let sheep = (0..<10_000).map { index in
            makeSheep(
                earTag: String(format: "L%05d", index),
                penID: validPenID,
                birthAt: index.isMultiple(of: 2)
                    ? oldBirthDate
                    : nil
            )
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let snapshot = evaluate(now: now, sheep: sheep, pens: [validPen()])
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertEqual(snapshot.operationalAlerts.count { $0.kind == .weaningOverdue }, 5_000)
        XCTAssertEqual(snapshot.missingBirthDateCount, 5_000)
        XCTAssertLessThan(elapsed, 2, "10,000 只羊的纯计算不应超过 2 秒，实际为 \(elapsed) 秒")
    }

    private var farmCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    private func configuredRule(
        weaningAgeDays: Int = 60,
        pregnancyCheckDays: Int = 45,
        warningLeadDays: Int = 0
    ) -> FarmOperationalAlertRuleSnapshot {
        FarmOperationalAlertRuleSnapshot(
            id: UUID(),
            pregnancyCheckDays: pregnancyCheckDays,
            gestationDays: 150,
            weaningAgeDays: weaningAgeDays,
            warningLeadDays: warningLeadDays,
            operationalAlertsConfiguredAt: date("2026-08-01T08:00:00+08:00"),
            digestEnabled: true,
            digestMinuteOfDay: 480
        )
    }

    private func makeSheep(
        id: UUID = UUID(),
        earTag: String,
        purpose: String = "哺乳羔羊",
        sex: SheepSex = .ram,
        status: SheepStatus = .active,
        isHistoricalArchive: Bool = false,
        penID: UUID?,
        birthAt: Date?,
        createdAt: Date = Date(timeIntervalSince1970: 1_735_660_800),
        revision: Int = 1
    ) -> FarmOperationalAlertEngine.Sheep {
        FarmOperationalAlertEngine.Sheep(
            id: id,
            earTag: earTag,
            purpose: purpose,
            sex: sex,
            status: status,
            isHistoricalArchive: isHistoricalArchive,
            currentPenID: penID,
            birthAt: birthAt,
            enteredAt: Date(timeIntervalSince1970: 1_735_660_800),
            createdAt: createdAt,
            revision: revision
        )
    }

    private func validPen() -> FarmOperationalAlertEngine.Pen {
        .init(id: validPenID, isActive: true, revision: 1, isDeleted: false)
    }

    private func reproduction(
        eweID: UUID,
        kind: ReproductionRecordKind,
        occurredAt: Date
    ) -> FarmOperationalAlertEngine.Reproduction {
        .init(
            id: UUID(),
            eweID: eweID,
            kind: kind,
            occurredAt: occurredAt,
            revision: 1,
            isDeleted: false
        )
    }

    private func deferral(
        for alert: FarmOperationalAlert,
        now: Date
    ) -> FarmOperationalAlertEngine.Deferral {
        .init(
            alertID: alert.id,
            conditionFingerprint: alert.conditionFingerprint,
            deferredAt: now,
            deferredUntil: now.addingTimeInterval(3 * 86_400)
        )
    }

    private func reminder(farmID: UUID, title: String, dueAt: Date) -> CareReminderRecord {
        CareReminderRecord(
            farmID: farmID,
            kind: .booster,
            sourceEntityType: CloudEntityType.health.rawValue,
            sourceEntityID: UUID(),
            dueAt: dueAt,
            title: title
        )
    }

    private func evaluate(
        now: Date,
        timeZoneIdentifier: String? = nil,
        rule: FarmOperationalAlertRuleSnapshot? = nil,
        sheep: [FarmOperationalAlertEngine.Sheep],
        pens: [FarmOperationalAlertEngine.Pen],
        weanings: [FarmOperationalAlertEngine.Weaning] = [],
        reproduction: [FarmOperationalAlertEngine.Reproduction] = [],
        lambingOffspring: [FarmOperationalAlertEngine.LambingOffspring] = [],
        reminders: [FarmScheduledReminderSnapshot] = [],
        deferrals: [FarmOperationalAlertEngine.Deferral] = []
    ) -> FarmOperationalAlertSnapshot {
        FarmOperationalAlertEngine.evaluate(
            farmID: farmID,
            timeZoneIdentifier: timeZoneIdentifier ?? self.timeZoneIdentifier,
            now: now,
            rule: rule ?? configuredRule(),
            sheep: sheep,
            pens: pens,
            weanings: weanings,
            reproduction: reproduction,
            lambingOffspring: lambingOffspring,
            reminders: reminders,
            deferrals: deferrals
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.date(from: value)!
    }
}
