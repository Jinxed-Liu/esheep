import Foundation

extension WeightGainAnalysisResult {
    /// Export the displayed result, including every accepted interval and excluded animal.
    /// Quoting and formula neutralization keep ear tags safe when opened in spreadsheets.
    func csvReport(scopeName: String) -> String {
        func cell(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = ["=", "+", "-", "@"].contains(where: { trimmed.hasPrefix($0) }) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func line(_ values: [String]) -> String { values.map(cell).joined(separator: ",") }
        let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.sheepID, $0.earTag) })
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.sheepID, $0) })
        func history(_ events: [WeightGainTransferEvidence]) -> String {
            events.map { "\($0.occurredAt.ISO8601Format()) \($0.fromPenName ?? "未分舍") → \($0.toPenName ?? "未分舍")" }.joined(separator: "; ")
        }
        func record(_ values: [String], sheepID: UUID, event: WeightGainTransferEvidence? = nil,
                    interval: WeightGainAnalysisInterval? = nil) -> String {
            let row = rowsByID[sheepID]
            return line(values + [
                row?.analysisEndPenID?.uuidString ?? "", row.map { $0.analysisEndPenName ?? "未分舍" } ?? "",
                row?.analysisEndDate.ISO8601Format() ?? "", row?.penHistoryStartPenName ?? "",
                event?.occurredAt.ISO8601Format() ?? "", event?.fromPenName ?? "", event?.toPenName ?? "",
                history(interval?.crossedTransfers ?? row?.penHistory ?? []),
                interval.map { $0.canBeAttributedToSinglePen ? "是" : "否（跨舍或未知）" } ?? ""
            ])
        }
        var lines = [
            line(["范围", scopeName, "模式", filter.mode.title, "分析方式", population.rawValue]),
            line(["开始日期", filter.startDate.ISO8601Format(), "结束日期", filter.endDate.ISO8601Format(), "时区", analysisTimeZoneIdentifier, "事实读取时间", factsReadAt.ISO8601Format()]),
            line(["期间对象", "\(objectCount)", "称重羊只", "\(weighedCount)", "可计算羊只", "\(calculableCount)"]),
            line(["名单基准", cohortAnchorDate?.ISO8601Format() ?? "不适用", "固定名单", "\(cohortMembers.count)", "调群羊只", "\(transferSheepCount)", "跨舍区间", "\(crossPenIntervalCount)", "跨舍羊只", "\(crossPenSheepCount)"]),
            line(["口径", "合格区间总增重/总观察日，逐羊等权平均；同日常规称重优先，同来源取最后一次"]),
            line(["圈舍口径", "圈舍按分析结束日期还原；转群前后同羊称重连续配对，逐条保留圈舍历史"]),
            line(["类型", "羊只ID", "耳号", "起始时间", "结束时间", "起重kg", "末重kg", "观察天数", "日增重g/天", "起点来源", "起点记录ID", "终点来源", "终点记录ID", "调群事件ID", "未纳入原因", "期末圈舍ID", "期末圈舍", "圈舍基准时间", "起始圈舍", "转群日期", "转出圈舍", "转入圈舍", "圈舍历史", "可归属单舍"])
        ]
        for member in cohortMembers {
            lines.append(record([
                "固定名单", member.sheepID.uuidString, member.earTag,
                member.anchorDate.ISO8601Format(), "", "", "", "", "",
                "", member.batchMembershipID?.uuidString ?? "", "", "",
                member.anchorTransferID?.uuidString ?? "", ""
            ], sheepID: member.sheepID))
        }
        for row in rows {
            lines.append(record(["羊只汇总", row.sheepID.uuidString, row.earTag, row.startDate.ISO8601Format(), row.endDate.ISO8601Format(), "\(row.startWeight)", "\(row.endWeight)", "\(row.intervalDays)", "\(row.gramsPerDay)", "", "", "", "", "", ""], sheepID: row.sheepID))
        }
        for interval in intervals {
            lines.append(record(["有效区间", interval.sheepID.uuidString, names[interval.sheepID] ?? "",
                interval.startDate.ISO8601Format(), interval.endDate.ISO8601Format(),
                interval.startSample.kilogramsText, interval.endSample.kilogramsText,
                "\(interval.intervalDays)", "\(interval.gramsPerDay)",
                interval.startSample.source.displayName, interval.startSample.id.uuidString,
                interval.endSample.source.displayName, interval.endSample.id.uuidString,
                interval.crossedTransfers.map { $0.id.uuidString }.joined(separator: ";"), ""], sheepID: interval.sheepID, interval: interval))
        }
        for interval in unassignedIntervals {
            lines.append(record([
                "未归属区间", interval.sheepID.uuidString, names[interval.sheepID] ?? "",
                interval.startDate.ISO8601Format(), interval.endDate.ISO8601Format(),
                interval.startSample.kilogramsText, interval.endSample.kilogramsText,
                "\(interval.intervalDays)", "\(interval.gramsPerDay)",
                interval.startSample.source.displayName, interval.startSample.id.uuidString,
                interval.endSample.source.displayName, interval.endSample.id.uuidString,
                interval.crossedTransfers.map { $0.id.uuidString }.joined(separator: ";"),
                interval.exclusionReason?.title ?? "跨舍无法归属单舍"
            ], sheepID: interval.sheepID, interval: interval))
        }
        for event in transferEvents {
            lines.append(record([
                "调群事件", event.sheepID.uuidString, event.earTag,
                event.occurredAt.ISO8601Format(), event.recordedAt.ISO8601Format(),
                "", "", "", "",
                "", event.id.uuidString, "", "", event.id.uuidString, event.note
            ], sheepID: event.sheepID, event: event))
        }
        for item in exclusions {
            lines.append(record(["未纳入", item.sheepID.uuidString, item.earTag, "", "", "", "", "", "", "", "", "", "", "", item.reason.title], sheepID: item.sheepID))
        }
        return lines.joined(separator: "\r\n")
    }
}
