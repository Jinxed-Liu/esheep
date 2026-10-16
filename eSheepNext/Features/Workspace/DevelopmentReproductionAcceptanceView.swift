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
        NavigationStack { ReproductionAnalysisHomeView(account: account, farm: farm, dataStore: dataStore) }
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
        let youngPen = PenRecord(farmID: farmID, name: "青年母羊舍")
        context.insert(youngPen)
        context.insert(PenRecord(farmID: farmID, name: "空舍（繁殖验收）"))
        let days = [0, 30, 31, 60, 180, 181, 210, 211]
        for (index, postpartum) in days.enumerated() {
            let birth = ReproductionRecord(farmID: farmID, eweID: sheep[index].id, kind: .lambing,
                occurredAt: ago(postpartum), lambCount: 1, parity: index < 4 ? 1 : 2, birthDeadCount: 0,
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
        try context.save()
    }
}
#endif
