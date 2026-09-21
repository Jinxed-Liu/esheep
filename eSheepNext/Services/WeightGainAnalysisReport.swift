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
        var lines = [
            line(["范围", scopeName, "模式", filter.mode.title, "分析方式", population.rawValue]),
            line(["开始日期", filter.startDate.ISO8601Format(), "结束日期", filter.endDate.ISO8601Format(), "时区", analysisTimeZoneIdentifier, "事实读取时间", factsReadAt.ISO8601Format()]),
            line(["期间对象", "\(objectCount)", "称重羊只", "\(weighedCount)", "可计算羊只", "\(calculableCount)"]),
            line(["名单基准", cohortAnchorDate?.ISO8601Format() ?? "不适用", "固定名单", "\(cohortMembers.count)", "调群羊只", "\(transferSheepCount)", "跨舍区间", "\(crossPenIntervalCount)", "跨舍羊只", "\(crossPenSheepCount)"]),
            line(["口径", "合格区间总增重/总观察日，逐羊等权平均；同日常规称重优先，同来源取最后一次"]),
            line(["类型", "羊只ID", "耳号", "起始时间", "结束时间", "起重kg", "末重kg", "观察天数", "日增重g/天", "起点来源", "起点记录ID", "终点来源", "终点记录ID", "调群事件ID", "未纳入原因"])
        ]
        for member in cohortMembers {
            lines.append(line([
                "固定名单", member.sheepID.uuidString, member.earTag,
                member.anchorDate.ISO8601Format(), "", "", "", "", "",
                "", member.batchMembershipID?.uuidString ?? "", "", "",
                member.anchorTransferID?.uuidString ?? "", ""
            ]))
        }
        for row in rows {
            lines.append(line(["羊只汇总", row.sheepID.uuidString, row.earTag, row.startDate.ISO8601Format(), row.endDate.ISO8601Format(), "", "", "\(row.intervalDays)", "\(row.gramsPerDay)", "", "", "", "", "", ""]))
        }
        for interval in intervals {
            lines.append(line(["有效区间", interval.sheepID.uuidString, names[interval.sheepID] ?? "",
                interval.startDate.ISO8601Format(), interval.endDate.ISO8601Format(),
                interval.startSample.kilogramsText, interval.endSample.kilogramsText,
                "\(interval.intervalDays)", "\(interval.gramsPerDay)",
                interval.startSample.source.displayName, interval.startSample.id.uuidString,
                interval.endSample.source.displayName, interval.endSample.id.uuidString,
                interval.crossedTransfers.map { $0.id.uuidString }.joined(separator: ";"), ""]))
        }
        for interval in unassignedIntervals {
            lines.append(line([
                "未归属区间", interval.sheepID.uuidString, names[interval.sheepID] ?? "",
                interval.startDate.ISO8601Format(), interval.endDate.ISO8601Format(),
                interval.startSample.kilogramsText, interval.endSample.kilogramsText,
                "\(interval.intervalDays)", "\(interval.gramsPerDay)",
                interval.startSample.source.displayName, interval.startSample.id.uuidString,
                interval.endSample.source.displayName, interval.endSample.id.uuidString,
                interval.crossedTransfers.map { $0.id.uuidString }.joined(separator: ";"),
                interval.exclusionReason?.title ?? "跨舍无法归属单舍"
            ]))
        }
        for event in transferEvents {
            lines.append(line([
                "调群事件", event.sheepID.uuidString, event.earTag,
                event.occurredAt.ISO8601Format(), event.recordedAt.ISO8601Format(),
                event.fromPenName ?? "未分配", event.toPenName ?? "未分配", "", "",
                "", event.id.uuidString, "", "", event.id.uuidString, event.note
            ]))
        }
        for item in exclusions {
            lines.append(line(["未纳入", item.sheepID.uuidString, item.earTag, "", "", "", "", "", "", "", "", "", "", "", item.reason.title]))
        }
        return lines.joined(separator: "\r\n")
    }
}
