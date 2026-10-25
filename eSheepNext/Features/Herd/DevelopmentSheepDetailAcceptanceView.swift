#if DEBUG
import SwiftData
import SwiftUI

/// Explicit local-only launch path. Never starts remote runtime or opens a real farm.
struct DevelopmentSheepDetailAcceptanceView: View {
    @Query private var sheep: [SheepRecord]
    let account: AccountProfile
    let farm: FarmRecord
    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account; self.farm = farm
        let farmID = farm.id
        _sheep = Query(filter: #Predicate<SheepRecord> { $0.farmID == farmID }, sort: \SheepRecord.earTag)
    }
    var body: some View {
        NavigationStack {
            List {
                Text("本机隔离验收样本，不连接生产云端").font(.footnote)
                ForEach(sheep) { ewe in
                    NavigationLink(ewe.earTag) { SheepDetailEntryView(account: account, farm: farm, sheepID: ewe.id) }
                        .accessibilityIdentifier("detail-fixture-\(ewe.earTag)")
                }
            }.navigationTitle("羊只详情验收")
        }
    }
    @MainActor
    static func seed(farm: FarmRecord, context: ModelContext) throws {
        guard ProcessInfo.processInfo.arguments.contains("--design-sheep-detail"),
              try FarmStorageRouter.route(farmID: farm.id, context: context).mode == .localOnly else { throw InsightSecurityError.accountMismatch }
        let farmID = farm.id
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.farmID == farmID }))
        guard let target = sheep.first(where: { $0.earTag == "QA-010" }) else { return }
        let targetID = target.id
        guard try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate { $0.sheepID == targetID })).isEmpty else { return }
        target.purpose = SheepPurpose.fattening.rawValue
        let calendar = Calendar.farm(identifier: farm.timeZoneIdentifier)
        for (days, kilograms) in [(100,"20.00"),(90,"22.00"),(60,"22.00"),(30,"21.00"),(10,"26.00")] {
            context.insert(WeightRecord(farmID: farmID, sheepID: target.id, kilogramsText: kilograms,
                occurredAt: calendar.date(byAdding: .day, value: -days, to: .now)!))
        }
        try context.save()
    }
}
#endif
