import SwiftData
import SwiftUI

struct MigrationReviewCenterView: View {
    let farmID: UUID
    let report: MigrationReconciliationReport
    @Query private var sheep: [SheepRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var lots: [InventoryLotRecord]
    @Query private var health: [HealthRecord]
    @Query private var reproduction: [ReproductionRecord]
    @Query private var batches: [ProductionBatchRecord]
    @Query private var photos: [PhotoAssetRecord]
    @Query private var audit: [MigrationAuditRecord]

    private var farmSheep: [SheepRecord] { sheep.filter { $0.farmID == farmID }.sorted { $0.earTag < $1.earTag } }

    var body: some View {
        List {
            Section("验收结论") {
                LabeledContent("阻断项", value: "\(report.blockingDiscrepancies.count)")
                    .foregroundStyle(report.blockingDiscrepancies.isEmpty ? .green : .red)
                LabeledContent("警告项", value: "\(report.discrepancies.filter { $0.severity == .warning }.count)")
                LabeledContent("自动补建历史归档羊只", value: "\(report.archivalSheep)")
                Text(report.blockingDiscrepancies.isEmpty ? LocalizedStringKey("本临时迁移结果可进入人工验收。正式牧场、云端和旧版数据均未写入。") : LocalizedStringKey("仍有阻断项，不能给出迁移演练通过结论。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("逐项对账") {
                ForEach(report.expectedByType.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: "来源 \(report.expectedByType[key] ?? 0) · 转换 \(report.convertedByType[key] ?? 0)")
                }
            }

            if !report.discrepancies.isEmpty {
                Section("差异定位") {
                    ForEach(report.discrepancies) { item in
                        NavigationLink {
                            MigrationDiscrepancyDetailView(item: item, audit: audit)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey(item.category)).font(.headline)
                                Text(item.reason).font(.footnote).foregroundStyle(item.severity == .blocking ? .red : .secondary)
                                if let sourceKey = item.sourceKey { Text(sourceKey).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }

            Section("临时库浏览") {
                NavigationLink("羊只时间线（\(farmSheep.count)）") { MigrationSheepReviewView(sheep: farmSheep, farmID: farmID) }
                NavigationLink("投喂（\(feeds.filter { $0.farmID == farmID }.count)）") { MigrationSimpleRecordList(title: "投喂", records: feeds.filter { $0.farmID == farmID }.map { "\($0.occurredAt.formatted(date: .numeric, time: .omitted)) · \($0.legacySourceKey ?? $0.id.uuidString)" }) }
                NavigationLink("库存（\(lots.filter { $0.farmID == farmID }.count)）") { MigrationSimpleRecordList(title: "库存", records: lots.filter { $0.farmID == farmID }.map { "\($0.catalogName) · \($0.startingQuantityText) \($0.unit)" }) }
                NavigationLink("健康（\(health.filter { $0.farmID == farmID }.count)）") { MigrationSimpleRecordList(title: "健康", records: health.filter { $0.farmID == farmID }.map { "\($0.itemNameSnapshot) · \($0.legacySourceKey ?? $0.id.uuidString)" }) }
                NavigationLink("繁殖（\(reproduction.filter { $0.farmID == farmID }.count)）") { MigrationSimpleRecordList(title: "繁殖", records: reproduction.filter { $0.farmID == farmID }.map { "\($0.kind.displayName) · \($0.legacySourceKey ?? $0.id.uuidString)" }) }
                NavigationLink("生产批次（\(batches.filter { $0.farmID == farmID }.count)）") { MigrationSimpleRecordList(title: "生产批次", records: batches.filter { $0.farmID == farmID }.map { "\($0.name) · \($0.purpose)" }) }
                NavigationLink("照片（\(photos.filter { $0.farmID == farmID }.count)）") { MigrationSimpleRecordList(title: "照片", records: photos.filter { $0.farmID == farmID }.map { "\($0.originalEarTag) · \($0.legacySourceKey)" }) }
                NavigationLink("来源审计（\(audit.count)）") { MigrationAuditListView(audit: audit) }
            }
        }
        .navigationTitle("迁移验收中心")
    }
}

private struct MigrationSheepReviewView: View {
    let sheep: [SheepRecord]
    let farmID: UUID
    @Query private var weights: [WeightRecord]
    @Query private var transfers: [TransferRecord]
    @Query private var removals: [RemovalRecord]

    var body: some View {
        List(sheep, id: \.id) { item in
            NavigationLink {
                List {
                    Section("羊只") {
                        LabeledContent("耳号", value: item.earTag)
                        LabeledContent("旧耳号", value: item.legacyEarTag ?? "")
                        LabeledContent("来源", value: item.legacySourceKey ?? "")
                        if item.isHistoricalArchive { Text("历史归档羊只，仅用于还原时间线。") .font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section("时间线") {
                        ForEach(weights.filter { $0.farmID == farmID && $0.sheepID == item.id }, id: \.id) { Text("称重 · \($0.displayKilogramsText) 千克 · \($0.occurredAt.formatted(date: .numeric, time: .omitted))") }
                        ForEach(transfers.filter { $0.farmID == farmID && $0.sheepID == item.id }, id: \.id) { Text("转群 · \($0.occurredAt.formatted(date: .numeric, time: .omitted))") }
                        ForEach(removals.filter { $0.farmID == farmID && $0.sheepID == item.id }, id: \.id) { Text("离场 · \($0.occurredAt.formatted(date: .numeric, time: .omitted))") }
                    }
                }
                .navigationTitle(item.earTag)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.earTag)
                    Text(item.isHistoricalArchive ? "历史归档 · \(item.legacySourceKey ?? "")" : "\(item.breed) · \(item.status.displayName)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("羊只时间线")
    }
}

private struct MigrationDiscrepancyDetailView: View {
    let item: MigrationDiscrepancy
    let audit: [MigrationAuditRecord]
    var body: some View {
        List {
            Section("差异") {
                LabeledContent("类别", value: item.category)
                LabeledContent("级别", value: item.severity == .blocking ? "阻断" : "警告")
                Text(item.reason)
            }
            if let key = item.sourceKey {
                Section("来源 JSON") {
                    if let record = audit.first(where: { $0.sourceKey == key }) { Text(record.rawPayloadJSON).font(.caption.monospaced()) } else { Text(key).font(.caption.monospaced()) }
                }
            }
            if !item.targetRecordIDs.isEmpty { Section("目标临时记录") { ForEach(item.targetRecordIDs, id: \.self) { Text($0.uuidString).font(.caption.monospaced()) } } }
        }
        .navigationTitle("差异详情")
    }
}

private struct MigrationAuditListView: View {
    let audit: [MigrationAuditRecord]
    var body: some View { List(audit.sorted { $0.sourceKey < $1.sourceKey }, id: \.id) { record in NavigationLink(record.sourceKey) { List { Section("来源 JSON") { Text(record.rawPayloadJSON).font(.caption.monospaced()) }; Section("目标记录") { Text(record.targetEntityIDsJSON).font(.caption.monospaced()) } }.navigationTitle(record.entityType) } }.navigationTitle("来源审计") }
}

private struct MigrationSimpleRecordList: View {
    let title: String
    let records: [String]
    var body: some View { List(records, id: \.self) { Text($0) }.navigationTitle(title) }
}
