import Foundation

/// A concise public account of actual tool work. Provider reasoning and
/// request scheduling remain in the protected runtime trace.
enum InsightPublicProcess {
    struct Step: Identifiable, Equatable {
        let id: String
        var title: String
        var detail: String
        var state: InsightRuntimeRecord.State
        let isTool: Bool
    }

    static func steps(
        records: [InsightRuntimeRecord],
        exchanges: [MiMoFunctionExchange],
        isCompleted: Bool
    ) -> [Step] {
        let evidence = Dictionary(exchanges.map { ($0.call.callID, $0) }, uniquingKeysWith: { _, last in last })
        var result: [Step] = []
        var indices: [String: Int] = [:]
        for record in records {
            let step: Step
            let key: String
            switch record.kind {
            case .reasoning:
                continue
            case .status:
                if record.title == "复核答案" || record.title == "答案复核" || record.title.hasPrefix("额外复核") {
                    key = "review"
                    step = Step(id: key, title: "核对分析结果", detail: "检查回答与实际查询、计算结果是否一致", state: record.state, isTool: false)
                } else if record.title == "整理结果", record.state == .running, !isCompleted {
                    key = "answer"
                    step = Step(id: key, title: "生成答复", detail: "整理本次分析的回答", state: .running, isTool: false)
                } else {
                    continue
                }
            case .tool:
                let exchange = record.callID.flatMap { evidence[$0] }
                let arguments = object(exchange?.call.argumentsJSON)
                let output = record.state == .completed && exchange?.succeeded == true ? object(exchange?.output) : [:]
                let actualArguments = output["canonical_arguments"] as? [String: Any] ?? arguments
                let title = toolTitle(record.title, arguments: actualArguments)
                let scope = context(arguments: actualArguments, output: output, exchanges: exchanges)
                let summary = resultSummary(name: record.title, arguments: actualArguments, output: output)
                let detail = [scope, summary].filter { !$0.isEmpty }.joined(separator: "\n")
                key = "tool:\(record.title):\(scope)"
                step = Step(id: record.callID ?? record.id.uuidString, title: title, detail: detail, state: record.state, isTool: true)
            }
            if let index = indices[key] {
                // Retain identity while a retry updates the same visible step.
                result[index].state = step.state
                result[index].detail = step.detail
                result[index].title = step.title
            } else {
                indices[key] = result.count
                result.append(step)
            }
        }
        if isCompleted {
            result.removeAll { $0.id == "answer" }
            result.append(Step(id: "answer", title: "生成答复", detail: "本次回答已完成", state: .completed, isTool: false))
        } else if let last = records.last(where: { $0.kind != .reasoning }), last.title != "整理结果" {
            // A provisional text phase before another tool is not a finished
            // answer. It must not remain as a misleading completed step.
            result.removeAll { $0.id == "answer" }
        }
        return result
    }

    static func currentStep(records: [InsightRuntimeRecord], steps: [Step]) -> Step? {
        if let running = steps.last(where: { $0.state == .running }) { return running }
        if records.contains(where: { $0.state == .running && ($0.kind == .reasoning || $0.title == "模型处理中") }) {
            let lastTool = steps.last { $0.isTool && $0.state == .completed }
            return Step(id: "analysis", title: lastTool == nil ? "理解你的问题" : "结合已读取的数据分析", detail: lastTool?.detail ?? "", state: .running, isTool: false)
        }
        if var lastTool = steps.last(where: { $0.isTool && $0.state == .completed }) {
            lastTool.title = "已完成：" + lastTool.title
            return lastTool
        }
        if records.contains(where: { $0.state == .running && $0.kind == .status }) {
            return Step(id: "analysis", title: "正在理解你的问题", detail: "", state: .running, isTool: false)
        }
        return nil
    }

    /// Store only facts needed by this presentation, without private reasoning,
    /// raw result rows, entity payloads, or assistant text.
    static func compactExchange(call: InsightFunctionCall, output: String = "", succeeded: Bool = false) -> MiMoFunctionExchange {
        let argumentKeys: Set<String> = [
            "category", "query", "query_kind", "subject", "source", "transform", "window", "pen_name", "pen_names",
            "batch_id", "production_batch_name", "date_from", "date_to", "as_of", "ear_tag", "breed", "sex", "kind", "item_name",
        ]
        let arguments = object(call.argumentsJSON).filter { argumentKeys.contains($0.key) }
        let outputKeys: Set<String> = [
            "canonical_arguments", "returned_count", "total_matching_count", "analyzed_profile_count", "observation_count",
            "cross_pen_interval_count", "excluded_insufficient_sample_profiles", "is_complete", "time_zone", "transfer_events_truncated",
        ]
        let originalOutput = object(output)
        var publicOutput = originalOutput.filter { outputKeys.contains($0.key) }
        if let canonical = publicOutput["canonical_arguments"] as? [String: Any] {
            publicOutput["canonical_arguments"] = canonical.filter { argumentKeys.contains($0.key) }
        }
        if call.name == "get_farm_entities", let rows = originalOutput["rows"] as? [[String: Any]] {
            publicOutput["rows"] = rows.map { $0.filter { ["id", "name"].contains($0.key) } }
        }
        return MiMoFunctionExchange(
            call: InsightFunctionCall(callID: call.callID, name: call.name, argumentsJSON: json(arguments)),
            output: publicOutput.isEmpty ? "" : json(publicOutput), succeeded: succeeded
        )
    }

    private static func toolTitle(_ name: String, arguments: [String: Any]) -> String {
        switch name {
        case "get_farm_entities": return "核对\(entityName(text(arguments["category"])))"
        case "get_farm_overview": return "读取牧场概况"
        case "query_farm_records", "query_farm_data":
            let isWeightQuery = text(arguments["subject"]) == "weights" ||
                text(arguments["query_kind"]) == "weight_records" || text(arguments["source"]).contains("weight")
            return isWeightQuery ? "读取称重记录" : "查询牧场记录"
        case "calculate_farm_data":
            return text(arguments["transform"]) == "difference_per_day" ? "计算日增重" : "计算牧场指标"
        case "find_sheep": return "查找羊只"
        case "match_sheep_ear_tags": return "核对羊只耳号"
        case "analyze_farm": return "分析牧场数据"
        case "get_extended_farm_records": return "读取已授权牧场记录"
        case "get_farm_action_schema": return "核对操作所需字段"
        case "create_farm_export": return "生成牧场文件"
        case "读取目标操作回执", "get_goal_action_receipts": return "核对操作回执"
        default: return name.hasPrefix("draft_") ? "生成待确认操作卡" : "读取牧场资料"
        }
    }

    private static func context(arguments: [String: Any], output: [String: Any], exchanges: [MiMoFunctionExchange]) -> String {
        var parts: [String] = []
        let query = text(arguments["query"])
        if !query.isEmpty { parts.append("查找“\(query)”") }
        var pens = (arguments["pen_names"] as? [String] ?? []).map { text($0) }.filter { !$0.isEmpty }
        let pen = text(arguments["pen_name"])
        if !pen.isEmpty, !pens.contains(pen) { pens.append(pen) }
        if !pens.isEmpty {
            parts.append("\(pens.count) 个圈舍：" + pens.prefix(8).joined(separator: "、") + (pens.count > 8 ? "等" : ""))
        }
        let batchID = text(arguments["batch_id"])
        var batchName = text(arguments["production_batch_name"])
        if batchName.isEmpty, !batchID.isEmpty {
            for exchange in exchanges where exchange.call.name == "get_farm_entities" && exchange.succeeded {
                guard text(object(exchange.call.argumentsJSON)["category"]) == "production_batches" else { continue }
                let rows = object(exchange.output)["rows"] as? [[String: Any]] ?? []
                if let row = rows.first(where: { text($0["id"]).lowercased() == batchID.lowercased() }) {
                    batchName = text(row["name"])
                    break
                }
            }
        }
        if !batchName.isEmpty { parts.append("生产批次：\(batchName)") }
        else if !batchID.isEmpty { parts.append("指定生产批次") }
        let timeZone = text(output["time_zone"])
        let from = dateText(text(arguments["date_from"]), timeZone: timeZone)
        let to = dateText(text(arguments["date_to"]), timeZone: timeZone)
        if !from.isEmpty || !to.isEmpty {
            parts.append("日期：\(from.isEmpty ? "未限制开始日期" : from) 至 \(to.isEmpty ? "未限制结束日期" : to)")
        } else {
            let asOf = dateText(text(arguments["as_of"]), timeZone: timeZone)
            if !asOf.isEmpty { parts.append("数据截止：\(asOf)") }
        }
        for (key, label) in [("ear_tag", "耳号"), ("breed", "品种"), ("item_name", "项目")] {
            let value = text(arguments[key])
            if !value.isEmpty { parts.append("\(label)：\(value)") }
        }
        return parts.joined(separator: "；")
    }

    private static func resultSummary(name: String, arguments: [String: Any], output: [String: Any]) -> String {
        guard !output.isEmpty else { return "" }
        if name == "get_farm_entities", let count = output["returned_count"] as? Int {
            let names = (output["rows"] as? [[String: Any]] ?? []).compactMap { row -> String? in
                let name = text(row["name"])
                return name.isEmpty ? nil : name
            }
            return "已读取 \(count) 个\(entityName(text(arguments["category"])))" + (names.isEmpty ? "" : "：" + names.prefix(3).joined(separator: "、") + (names.count > 3 ? "等" : ""))
        }
        if name == "calculate_farm_data", let sheep = output["analyzed_profile_count"] as? Int,
           let intervals = output["observation_count"] as? Int {
            var summary = "已计算 \(sheep) 只羊、\(intervals) 个有效区间"
            if let crossPen = output["cross_pen_interval_count"] as? Int, crossPen > 0 { summary += "；保留 \(crossPen) 个跨舍区间" }
            if let insufficient = output["excluded_insufficient_sample_profiles"] as? Int, insufficient > 0 { summary += "；\(insufficient) 只羊缺少成对称重" }
            else if output["is_complete"] as? Bool == false { summary += "；完整性仍需核对" }
            return summary
        }
        if let count = output["total_matching_count"] as? Int { return "已匹配 \(count) 条记录" }
        return ""
    }

    private static func entityName(_ category: String) -> String {
        ["production_batches": "生产批次", "pens": "圈舍", "ingredients": "饲料原料", "recipes": "饲喂配方",
         "health_catalog": "健康项目", "inventory_lots": "库存批次", "semen": "冻精", "semen_donors": "冻精供体", "reminders": "提醒"][category] ?? "牧场资料"
    }

    private static func text(_ value: Any?) -> String {
        guard let value = value as? String else { return "" }
        return String(value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    private static func object(_ value: String?) -> [String: Any] {
        guard let data = value?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dateText(_ value: String, timeZone: String) -> String {
        guard !value.isEmpty else { return "" }
        if value.count == 10 { return value }
        guard let zone = TimeZone(identifier: timeZone) else { return value }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed = parser.date(from: value)
        if parsed == nil { parser.formatOptions = [.withInternetDateTime]; parsed = parser.date(from: value) }
        guard let parsed else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: parsed)
    }
}
