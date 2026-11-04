#if DEBUG
import SwiftData
import SwiftUI

/// Only the explicit, local design fixture can reach this seed. No remote
/// runtime is started and no real-farm record is read or changed.
struct DevelopmentReproductionAcceptanceView: View {
    let account: AccountProfile
    let farm: FarmRecord
    @State private var dataStore = FarmDeepAnalyticsStore()
    var body: some View {
        NavigationStack {
            if ProcessInfo.processInfo.arguments.contains("--design-reproduction-history") {
                FarmEventHistoryView(account: account, farm: farm)
            } else if ProcessInfo.processInfo.arguments.contains("--design-reproduction-evidence") {
                DevelopmentReproductionEvidenceEntry(account: account, farm: farm)
            } else {
                ReproductionAnalysisHomeView(account: account, farm: farm, dataStore: dataStore)
            }
        }
    }
}

private struct DevelopmentReproductionEvidenceEntry: View {
    let account: AccountProfile
    let farm: FarmRecord
    @Query(sort: \SheepRecord.earTag) private var sheep: [SheepRecord]
    var body: some View {
        if let ewe = sheep.first(where: { $0.farmID == farm.id && $0.earTag == "QA-001" }) {
            if ProcessInfo.processInfo.arguments.contains("--design-reproduction-evidence-from-sheep") {
                SheepDetailEntryView(account: account, farm: farm, sheepID: ewe.id)
            } else {
                ReproductionEvidenceView(account: account, farm: farm, eweID: ewe.id)
            }
        }
    }
}

@MainActor
enum DevelopmentReproductionAcceptance {
    static func seed(account: AccountProfile, farm: FarmRecord, context: ModelContext) throws {
        guard ProcessInfo.processInfo.arguments.contains("--design-reproduction"),
              account.appleSubjectHash == AppleIdentityHash.value(for: "design-acceptance-local"),
              try FarmStorageRouter.route(farmID: farm.id, context: context).mode == .localOnly else {
            throw InsightSecurityError.accountMismatch
        }
        let farmID = farm.id
        guard try context.fetch(FetchDescriptor<FarmCareRuleRecord>(predicate: #Predicate { $0.farmID == farmID })).isEmpty else { return }
        farm.timeZoneIdentifier = "Asia/Shanghai"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: farm.timeZoneIdentifier)!
        let today = calendar.startOfDay(for: .now)
        func ago(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today)! }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.farmID == farmID }))
            .sorted { $0.earTag < $1.earTag }
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate { $0.farmID == farmID }))
        guard sheep.count == 12, let adultPen = pens.first else { throw FarmCommandError.sourceRecordNotFound }
        let searchReady = ProcessInfo.processInfo.arguments.contains("--design-search")
        if searchReady {
            // Only the UUID-scoped offline search fixture needs a profile old
            // ear tag; production records and the other fixture routes stay intact.
            sheep[0].legacyEarTag = "QA-OLD-001"
        }
        let youngPen = PenRecord(farmID: farmID, name: "青年母羊舍")
        context.insert(youngPen)
        context.insert(PenRecord(farmID: farmID, name: "空舍（繁殖验收）"))
        let days = [0, 30, 31, 60, 180, 181, 210, 211]
        for (index, postpartum) in days.enumerated() {
            // Keep the search fixture's day-zero record inside today's date
            // filter in both the simulator's and the farm's time zones.
            let birth = ReproductionRecord(farmID: farmID, eweID: sheep[index].id, kind: .lambing,
                occurredAt: searchReady && index == 0 ? .now : ago(postpartum),
                lambCount: 1, parity: index < 4 ? 1 : 2, birthDeadCount: 0,
                note: "隔离繁殖验收样本")
            context.insert(birth)
            context.insert(LambingOffspringRecord(farmID: farmID, lambingRecordID: birth.id, sheepID: nil,
                legacyEarTag: "QA-LAMB-\(index)", sexRawValue: LambSex.female.rawValue, birthWeightText: "3.5"))
        }
        for ewe in sheep.suffix(4) {
            try FarmCommandService().execute(.transferSheep(sheepID: ewe.id, toPenID: youngPen.id,
                occurredAt: ago(5), note: "隔离繁殖验收转舍"),
                in: .init(accountID: account.effectiveAccountID, farmID: farmID, role: .administrator), context: context)
        }
        sheep[11].birthAt = ago(200)
        sheep[11].enteredAt = ago(150)
        context.insert(ReproductionRecord(farmID: farmID, eweID: sheep[8].id, kind: .pregnancyCheck,
            occurredAt: ago(2), result: "已孕", note: "隔离青孕样本"))
        context.insert(ReproductionRecord(farmID: farmID, eweID: sheep[9].id, kind: .pregnancyCheck,
            occurredAt: ago(2), result: "空怀", note: "隔离空怀样本"))
        var settings = ReproductionManagementSettings()
        settings.scopeConfigured = true
        settings.selectedPenIDs = [adultPen.id, youngPen.id]
        settings.setUsage(.breeding, for: adultPen.id)
        settings.setUsage(.replacement, for: youngPen.id)
        settings.youthBreedingConfirmedSheepIDs = [sheep[8].id, sheep[9].id]
        settings.postpartumReminderDays = 90; settings.postpartumWarningDays = 120
        settings.maidenReminderMonths = 10; settings.maidenWarningMonths = 12
        context.insert(FarmCareRuleRecord(farmID: farmID, weaningAgeDays: 60, operationalAlertsConfiguredAt: .now,
            reproductionSettingsJSON: try settings.encodedJSON()))
        if ProcessInfo.processInfo.arguments.contains("--design-reproduction-history") {
            let eweID = sheep[0].id
            let birth = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.eweID == eweID
            })).first { $0.kind == .lambing }!
            birth.occurredAt = ago(8); birth.lambCount = 5; birth.birthDeadCount = 1
            let birthID = birth.id
            let firstLink = try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.lambingRecordID == birthID
            })).first!
            let live = SheepRecord(farmID: farmID, earTag: "QA-LIVE", breed: "湖羊", sex: .ewe,
                penID: adultPen.id, enteredAt: ago(8), birthAt: ago(8), damID: eweID)
            let dead = SheepRecord(farmID: farmID, earTag: "QA-DEAD", breed: "湖羊", sex: .ram,
                penID: adultPen.id, enteredAt: ago(8), birthAt: ago(8), damID: eweID)
            dead.statusRawValue = SheepStatus.deceased.rawValue; dead.removedAt = ago(3)
            context.insert(live); context.insert(dead)
            let birthWeight = WeightRecord(farmID: farmID, sheepID: live.id, kilogramsText: "3.4", occurredAt: ago(8))
            let laterWeight = WeightRecord(farmID: farmID, sheepID: dead.id, kilogramsText: "4.1", occurredAt: ago(5))
            context.insert(birthWeight); context.insert(laterWeight)
            firstLink.sheepID = live.id; firstLink.legacyEarTag = "QA-OLD"
            firstLink.birthWeightText = "3.4"; firstLink.autoBirthWeightRecordID = birthWeight.id
            context.insert(LambingOffspringRecord(farmID: farmID, lambingRecordID: birthID, sheepID: dead.id,
                legacyEarTag: dead.earTag, sexRawValue: LambSex.male.rawValue, birthWeightText: "4.1",
                autoBirthWeightRecordID: laterWeight.id))
            context.insert(RemovalRecord(farmID: farmID, sheepID: dead.id, kind: .deceased,
                reason: "隔离回归样本", occurredAt: ago(3)))
            context.insert(LambingOffspringRecord(farmID: farmID, lambingRecordID: birthID, sheepID: nil,
                legacyEarTag: "QA-UNLINKED", sexRawValue: LambSex.female.rawValue, birthWeightText: "3.1"))
            context.insert(LambingOffspringRecord(farmID: farmID, lambingRecordID: birthID, sheepID: nil,
                legacyEarTag: "", sexRawValue: "unknown", birthWeightText: "", isStillborn: true))
            context.insert(ReproductionRecord(farmID: farmID, eweID: eweID, kind: .breeding,
                occurredAt: ago(155), note: "隔离筛选样本"))
        }
        if ProcessInfo.processInfo.arguments.contains("--design-reproduction-evidence") {
            let ewe = sheep[0]
            ewe.birthAt = ago(1_800)
            ewe.enteredAt = ago(1_600)
            let eweID = ewe.id
            let facts = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.eweID == eweID
            }))
            for fact in facts {
                if fact.kind == .parityBaseline { fact.occurredAt = ago(1_600) }
                if fact.kind == .lambing { fact.parity = 5 }
            }
            for (kind, days, result) in [(ReproductionRecordKind.breeding, 90, ""),
                                        (.pregnancyCheck, 45, "已孕"), (.abortion, 400, "")] {
                context.insert(ReproductionRecord(farmID: farmID, eweID: ewe.id, kind: kind,
                    occurredAt: ago(days), result: result, note: "隔离详情回归样本"))
            }
            for index in 1...4 {
                context.insert(ReproductionRecord(farmID: farmID, eweID: ewe.id, kind: .lambing,
                    occurredAt: ago(index * 300), lambCount: 1, parity: 5 - index))
            }
            // Stress only the explicit local fixture, never a connected farm.
            for index in 0..<10_000 {
                context.insert(SheepRecord(farmID: farmID, earTag: "ZZ-STRESS-\(index)",
                    breed: "湖羊", sex: .ewe, penID: nil, enteredAt: ago(500)))
                for _ in 0..<2 {
                    context.insert(TombstoneRecord(farmID: farmID, entityType: CloudEntityType.reproduction.rawValue,
                        entityID: UUID(), deletedByAccountID: account.effectiveAccountID, reason: "隔离回归样本"))
                }
                if index % 500 == 0 { try context.save() }
            }
        }
        try context.save()
    }
}
#endif

