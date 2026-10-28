import Foundation

/// Detailed rows complement the human-readable timeline without changing any
/// stored facts. Inputs are scoped by FarmDataInterchange; detail is the same
/// subject's immutable snapshot produced by SheepDetailSnapshotActor.
enum SingleSheepArchiveFacts {
    struct Weight {
        let id: UUID
        let date: Date
        let kilogramsText: String
        let source: SheepWeightSource
        let note: String
    }

    static func weights(records: [WeightRecord], detail: SheepDetailSnapshot?) -> [Weight] {
        // Keep every ordinary measurement, including multiple readings per day
        // and their notes. Daily canonical weights are only for gain analytics.
        var result = records.map {
            Weight(id: $0.id, date: $0.occurredAt, kilogramsText: $0.kilogramsText,
                   source: $0.note == "初生重" ? .lambingBirth : .weighing, note: $0.note)
        }
        let recordIDs = Set(records.map(\.id))
        for value in detail?.weights ?? [] where !recordIDs.contains(value.id) && value.source != .weighing {
            // A migrated birth fact can exist in both a WeightRecord and the
            // lambing/weaning source. Do not repeat the same birth fact.
            let duplicatesBirth = (value.source == .lambingBirth || value.source == .weaningBirth) && result.contains {
                ($0.source == .lambingBirth || $0.source == .weaningBirth) && $0.date == value.occurredAt &&
                    WeightPrecision.storageText($0.kilogramsText) == WeightPrecision.storageText(value.kilogramsText)
            }
            if !duplicatesBirth {
                result.append(Weight(id: value.id, date: value.occurredAt, kilogramsText: value.kilogramsText, source: value.source, note: ""))
            }
        }
        return ordered(result, date: \.date, id: \.id)
    }

    static func sheets(
        sheep: SheepRecord, formatter: DateFormatter, weights: [Weight],
        health: [HealthRecord], transfers: [TransferRecord], reproduction: [ReproductionRecord],
        weanings: [WeaningRecord], removals: [RemovalRecord], notes: [NoteRecord],
        purposes: [SheepPurposeTimelineFact], pens: [PenRecord]
    ) -> [XLSXSheet] {
        let identity = ["记录ID", "牧场ID", "羊只ID", "耳号"]
        func prefix(_ id: UUID) -> [String] {
            [id.uuidString, sheep.farmID.uuidString, sheep.id.uuidString, sheep.earTag]
        }
        func date(_ value: Date?) -> String { value.map(formatter.string(from:)) ?? "" }
        let scopedPens = pens.filter { $0.farmID == sheep.farmID && $0.deletedAt == nil }
        func penName(_ id: UUID?) -> String {
            guard let id else { return "未分圈" }
            return scopedPens.first { $0.id == id }?.name ?? "未找到圈舍"
        }
        let weightRows = weights.map {
            prefix($0.id) + [date($0.date), $0.source.displayName, WeightPrecision.displayText($0.kilogramsText), $0.note]
        }
        let healthRows = ordered(health, date: \.occurredAt, id: \.id).map {
            prefix($0.id) + [date($0.occurredAt), HealthRecordKind(rawValue: $0.kindRawValue)?.displayName ?? $0.kindRawValue, $0.itemNameSnapshot,
                            $0.quantityText ?? "", $0.unit, $0.route, $0.sheepID?.uuidString ?? "",
                            $0.penID?.uuidString ?? "", $0.note]
        }
        let transferRows = ordered(transfers, date: \.occurredAt, id: \.id).map {
            prefix($0.id) + [date($0.occurredAt), $0.fromPenID?.uuidString ?? "", penName($0.fromPenID),
                            $0.toPenID?.uuidString ?? "", penName($0.toPenID), $0.note]
        }
        let reproductionRows: [[String]] = ordered(reproduction, date: \.occurredAt, id: \.id).map { record in
            var row = prefix(record.id)
            row += [date(record.occurredAt), ReproductionRecordKind(rawValue: record.kindRawValue)?.displayName ?? record.kindRawValue, record.eweID.uuidString,
                    record.sireID?.uuidString ?? "", record.result]
            row += [record.parity.map { String($0) } ?? "", record.kind == .lambing ? String(record.lambCount) : "",
                    record.birthDeadCount.map { String($0) } ?? "", record.relatedBreedingRecordID?.uuidString ?? ""]
            row += [record.semenDonorNameSnapshot ?? "", record.semenDonorRegistrationNumberSnapshot ?? "", record.note]
            return row
        }
        let weaningRows = ordered(weanings, date: \.occurredAt, id: \.id).map {
            prefix($0.id) + [date($0.occurredAt), WeightPrecision.displayText($0.weanWeightText), date($0.birthAt),
                            $0.birthWeightText.map(WeightPrecision.displayText) ?? "", $0.damID?.uuidString ?? "",
                            $0.legacyDamEarTag ?? "", $0.litterSize.map { String($0) } ?? "", $0.note]
        }
        let removalRows = ordered(removals, date: \.occurredAt, id: \.id).map {
            // Batch money is deliberately not presented as this sheep's price.
            prefix($0.id) + [date($0.occurredAt), $0.kind.displayName, $0.reason, $0.amountText ?? "",
                            $0.removalBatchID?.uuidString ?? "", $0.batchTotalAmountText ?? "", $0.note]
        }
        let noteRows = ordered(notes, date: \.occurredAt, id: \.id).map {
            prefix($0.id) + [date($0.occurredAt), $0.text]
        }
        let purposeRows = ordered(purposes, date: \.occurredAt, id: \.id).map {
            prefix($0.id) + [date($0.occurredAt), $0.previousPurpose ?? "", $0.purpose.displayName, $0.reason]
        }
        return [
            XLSXSheet(name: "体重记录", rows: [identity + ["发生时间", "来源", "体重kg", "备注"]] + weightRows),
            XLSXSheet(name: "健康记录", rows: [identity + ["发生时间", "类型", "项目", "剂量", "单位", "给药途径", "原记录羊只ID", "圈舍ID", "备注"]] + healthRows),
            XLSXSheet(name: "转群记录", rows: [identity + ["发生时间", "转出圈舍ID", "转出圈舍", "转入圈舍ID", "转入圈舍", "备注"]] + transferRows),
            XLSXSheet(name: "繁殖记录", rows: [identity + ["发生时间", "类型", "母羊ID", "公羊ID", "结果", "胎次", "产羔数", "死羔数", "关联配种记录ID", "冻精供体快照", "供体登记号快照", "备注"]] + reproductionRows),
            XLSXSheet(name: "断奶记录", rows: [identity + ["发生时间", "断奶重kg", "出生时间", "初生重kg", "母本ID", "历史母本耳号", "胎只数", "备注"]] + weaningRows),
            XLSXSheet(name: "离场记录", rows: [identity + ["发生时间", "类型", "原因", "历史单羊金额", "离场批次ID", "整批总金额（非单羊价格）", "备注"]] + removalRows),
            XLSXSheet(name: "备注记录", rows: [identity + ["发生时间", "备注"]] + noteRows),
            XLSXSheet(name: "用途记录", rows: [identity + ["发生时间", "原用途", "新用途", "备注"]] + purposeRows),
        ]
    }

    private static func ordered<T>(_ values: [T], date: KeyPath<T, Date>, id: KeyPath<T, UUID>) -> [T] {
        values.sorted {
            if $0[keyPath: date] != $1[keyPath: date] { return $0[keyPath: date] < $1[keyPath: date] }
            return $0[keyPath: id].uuidString < $1[keyPath: id].uuidString
        }
    }
}
