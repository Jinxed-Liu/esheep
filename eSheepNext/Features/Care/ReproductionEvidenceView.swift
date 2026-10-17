import SwiftData
import SwiftUI

struct ReproductionEvidenceView: View {
    @Query private var rules: [FarmCareRuleRecord]
    @Query private var records: [ReproductionRecord]
    let account: AccountProfile
    let farm: FarmRecord
    @Query private var subject: [SheepRecord]
    let eweID: UUID

    init(account: AccountProfile, farm: FarmRecord, eweID: UUID) {
        self.account = account; self.farm = farm; self.eweID = eweID
        let farmID = farm.id
        _rules = Query(filter: #Predicate<FarmCareRuleRecord> { $0.farmID == farmID })
        _subject = Query(filter: #Predicate<SheepRecord> { $0.farmID == farmID && $0.id == eweID })
        _records = Query(filter: #Predicate<ReproductionRecord> { $0.farmID == farmID && $0.eweID == eweID }, sort: \ReproductionRecord.occurredAt, order: .reverse)
    }
    var body: some View {
        let now = Date.now
        let facts = ReproductionCycleResolver.facts(records: records)
        let state = ReproductionCycleResolver.resolve(eweID: eweID, facts: facts, asOf: now)
        let settings = try? ReproductionManagementSettings.decode(rules.first?.reproductionSettingsJSON)
        let preBreedingLamb = subject.first.map {
            ReproductionReviewPolicy.isPreBreedingLamb(purpose: $0.purpose, birthAt: $0.birthAt,
                removedAt: $0.removedAt, hasReproductionFacts: facts.contains { $0.occurredAt <= now },
                asOf: now, timeZoneIdentifier: farm.timeZoneIdentifier, minimumAgeMonths: settings?.minimumAgeMonths ?? 10)
        } ?? false
        List {
            Section("本轮繁殖") {
                LabeledContent("状态", value: preBreedingLamb ? "羔羊，未进入繁殖管理" : state.displayState)
                if preBreedingLamb {
                    Text("尚无自身繁殖记录，不因缺少胎次资料列入繁殖待核实。")
                } else {
                    Text(verbatim: state.parityText + " · " + state.targetParityText)
                }
                Text("关联按实际发生时间核对；历史推导只用于读取，人工修正会保留审计记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !preBreedingLamb && !state.issues.isEmpty {
                Section("繁殖资料待核实") {
                    ForEach(state.issues, id: \.self) { Text(verbatim: $0).foregroundStyle(.orange) }
                    Text("选择下方原始记录核对、修正关联或撤销错误事实。胎次在羊只档案中确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("繁殖事实与关联依据") {
                ForEach(records) { record in
                    NavigationLink {
                        ReproductionRecordDetailView(account: account, farm: farm, record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: record.kind.displayName + (record.result.isEmpty ? "" : " · " + record.result))
                            Text(record.occurredAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            if let association = state.association(for: record.id) {
                                Text(verbatim: association.reason).font(.footnote).foregroundStyle(association.cycleID == nil ? .orange : .secondary)
                            } else if record.kind != .parityBaseline {
                                Text(record.deletedAt != nil ? "已撤销" : "历史周期记录").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("繁殖依据与历史")
        .environment(\.timeZone, TimeZone(identifier: farm.timeZoneIdentifier) ?? .current)
    }
}

struct ReproductionReviewCenter: View {
    @Query private var rules: [FarmCareRuleRecord]
    @Query private var records: [ReproductionRecord]
    @Query private var sheep: [SheepRecord]
    let account: AccountProfile
    let farm: FarmRecord
    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account; self.farm = farm
        let farmID = farm.id
        _rules = Query(filter: #Predicate<FarmCareRuleRecord> { $0.farmID == farmID })
        _records = Query(filter: #Predicate<ReproductionRecord> { $0.farmID == farmID && $0.deletedAt == nil })
        _sheep = Query(filter: #Predicate<SheepRecord> { $0.farmID == farmID && $0.deletedAt == nil && $0.sexRawValue == "ewe" }, sort: \SheepRecord.earTag)
    }
    var body: some View {
        let groups = Dictionary(grouping: ReproductionCycleResolver.facts(records: records), by: \.eweID)
        let now = Date.now
        let settings = try? ReproductionManagementSettings.decode(rules.first?.reproductionSettingsJSON)
        let rows = sheep.filter { ewe in
            !ReproductionReviewPolicy.isPreBreedingLamb(purpose: ewe.purpose, birthAt: ewe.birthAt,
                removedAt: ewe.removedAt, hasReproductionFacts: (groups[ewe.id] ?? []).contains { $0.occurredAt <= now },
                asOf: now, timeZoneIdentifier: farm.timeZoneIdentifier, minimumAgeMonths: settings?.minimumAgeMonths ?? 10)
        }.map { ($0, ReproductionCycleResolver.resolve(eweID: $0.id, facts: groups[$0.id] ?? [], asOf: now)) }.filter { !$0.1.issues.isEmpty }
        List {
            Section {
                Text("共 \(rows.count) 只母羊资料待核实，不能将不确定结果计为已孕或空怀。")
                Text("包含在场与离场历史母羊；尚未到起算月龄且无自身繁殖记录的羔羊不列入。羊舍勾选仅影响统计范围。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.0.id) { ewe, state in
                NavigationLink {
                    ReproductionEvidenceView(account: account, farm: farm, eweID: ewe.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: ewe.earTag + (ewe.isCurrentlyPresent ? " · 在场" : " · 离场 / 历史")).font(.headline)
                        Text(verbatim: state.parityText + " · " + state.displayState).font(.subheadline)
                        Text(verbatim: state.issues.joined(separator: "；")).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }.navigationTitle("繁殖资料待核实")
    }
}
