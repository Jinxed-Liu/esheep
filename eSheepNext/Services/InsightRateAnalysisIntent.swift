import Foundation

/// A small semantic gate for the one class of question where returning a raw
/// record is materially wrong: a request for weight change or daily gain.
///
/// This is not a second natural-language answer engine. It only identifies a
/// well-known analytical intent and lets the local typed calculator run before
/// the model gets a chance to collapse it into `query_farm_records`. Entity
/// resolution still comes from the current farm's records. Unsupported or
/// ambiguous filters stay with the model rather than being silently dropped.
struct InsightRateAnalysisIntent: Equatable, Sendable {
    let penNames: [String]
    let dateFrom: String
    let dateTo: String

    var penName: String? { penNames.count == 1 ? penNames[0] : nil }

    static func detect(
        question: String,
        availablePenNames: [String],
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> InsightRateAnalysisIntent? {
        let normalized = normalize(question)
        guard !normalized.isEmpty,
              containsRateIntent(normalized),
              !containsRecordOnlyIntent(normalized),
              !containsSingleEntityIntent(normalized),
              let dates = resolveDates(in: normalized, now: now, timeZone: timeZone),
              let penNames = resolvePens(in: normalized, availableNames: availablePenNames) else {
            return nil
        }
        let scopeText = penNames.sorted { normalize($0).count > normalize($1).count }.reduce(normalized) {
            $0.replacingOccurrences(of: normalize($1), with: "")
        }
        let remainingText = dates.phrase.isEmpty
            ? scopeText
            : scopeText.replacingOccurrences(of: dates.phrase, with: "")
        guard !containsUnsupportedScopeIntent(scopeText),
              containsOnlyNeutralRequestText(remainingText) else { return nil }
        return InsightRateAnalysisIntent(
            penNames: penNames,
            dateFrom: dates.from,
            dateTo: dates.to
        )
    }

    /// The complete rate plan is intentionally fixed only after the semantic
    /// gate has fired. It mirrors the calculation tool's complete-plan
    /// contract: every sheep's real adjacent weighing intervals, then the
    /// overall, interval, production-batch and lifecycle dimensions.
    var calculationArguments: [String: Any] {
        [
            "source": "weight_samples",
            "sample_policy": "canonical_timeline",
            "cohort": "all_profiles",
            "pen_membership": "at_cutoff",
            "pen_name": penName ?? "",
            "pen_names": penNames,
            "ear_tag": "",
            "breed": "",
            "sex": "",
            "date_from": dateFrom,
            "date_to": dateTo,
            "as_of": "",
            "partition_by": "sheep",
            "window": "adjacent",
            "transform": "difference_per_day",
            "analysis_scope": "complete",
            "group_by": "none",
            "reduce": "average",
            "selection": "all",
            "limit": 100,
        ]
    }

    var instruction: String {
        let scope = penNames.isEmpty
            ? "当前牧场"
            : "圈舍“\(penNames.joined(separator: "、"))”"
        let dates = dateFrom.isEmpty ? "" : "，分析日期为 \(dateFrom) 至 \(dateTo)"
        return "本轮已识别为\(scope)的增重/日增重分析请求\(dates)。App 已按增重分析页面的统一体重时间线和分析结束时的圈舍名单完成完整计算，同羊跨舍后的有效称重仍连续配对。请直接依据该计算证据回答，保留全部请求圈舍以及总体结论、称重区间、生产批次、生命周期和数据完整性五个部分，不要改查单条称重记录。"
    }

    private static func containsRateIntent(_ value: String) -> Bool {
        [
            "日增重", "平均日增重", "日增重率", "增重速度", "生长速度",
            "每天增重", "每天增加多少", "体重增长", "增重多少", "增长多少",
            "daily gain", "average daily gain", "weight gain", "gain/day", "adg",
        ].contains { value.contains(normalize($0)) } ||
            (value.contains("分析") && (value.contains("增重") || value.contains("称重数据")))
    }

    private static func containsRecordOnlyIntent(_ value: String) -> Bool {
        [
            "称重记录", "称重明细", "称重列表", "原始称重", "哪次称重",
            "最近一次称重", "最新一次称重", "上次称重", "称重有几条",
        ].contains { value.contains($0) }
    }

    private static func containsSingleEntityIntent(_ value: String) -> Bool {
        [
            "某只", "单只", "一只", "这只", "这头", "哪只", "耳号",
            "羊号", "逐只", "每只羊", "分别看每只",
        ].contains { value.contains($0) }
    }

    private static func containsUnsupportedScopeIntent(_ value: String) -> Bool {
        // Precalculation can seed only the ordinary end-cohort analysis.
        // A narrower population, sample source, or result view requires the
        // model to plan a tool call that actually preserves those conditions.
        [
            "在舍", "全程", "连续在", "仍在群", "当前在群", "当前在场", "存栏",
            "批次", "公羊", "母羊", "公母", "性别", "羔羊", "种羊", "品种", "湖羊", "杜泊",
            "小尾寒羊", "萨福克", "常规称重", "断奶", "初生", "月龄", "年龄",
            "只看", "仅", "首末", "两次称重", "按月", "按日", "每月", "每天的",
            "排名", "中位数", "最大", "最小", "离场", "死淘", "死亡", "出售", "淘汰", "转出",
            "低于", "高于", "超过", "大于", "小于", "以上", "以下",
        ].contains { value.contains($0) }
    }

    private static func containsOnlyNeutralRequestText(_ value: String) -> Bool {
        // Known entities and the supported date range are already removed.
        // Only ordinary request wording may remain: an unfamiliar breed,
        // age, production stage, or other condition needs model planning.
        let neutralTokens = [
            "平均日增重率", "平均日增重", "每日平均增重", "每日增重", "日增重率", "日增重",
            "增重速度", "生长速度", "每天增重", "每天增加多少", "体重增长", "增重多少", "增长多少",
            "称重数据", "体重数据", "称重", "数据", "增重", "平均",
            "当前牧场", "整个牧场", "本牧场", "全场", "牧场", "羊群", "羊只", "全群", "整体",
            "请帮我", "帮我", "告诉我", "给我", "分析一下", "计算一下", "算一下", "算一算",
            "看一下", "做一下", "做个", "进行", "分析", "计算", "查询", "看看", "算算",
            "是多少", "多少", "一下", "情况", "期间", "日期", "以及", "还有",
            "请", "把", "将", "的", "和", "与", "呢", "吧",
            "average daily gain", "daily gain", "weight gain", "gain/day", "adg",
            "whole farm", "the farm", "the herd", "farm", "herd", "sheep", "overall",
            "what is the", "what is", "how much", "for the", "calculate", "analyze", "analysis",
            "please", "for", "the", "of",
        ].map(normalize).sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0 < $1
        }
        var remaining = value[...]
        while !remaining.isEmpty {
            guard let token = neutralTokens.first(where: { remaining.hasPrefix($0) }) else { return false }
            remaining = remaining.dropFirst(token.count)
        }
        return true
    }

    private static func containsExplicitDateFilter(_ value: String) -> Bool {
        if value.range(of: #"\d{4}"#, options: .regularExpression) != nil ||
            value.range(of: #"(?:\d{1,2}|[一二三四五六七八九十]{1,3})月"#, options: .regularExpression) != nil ||
            value.range(of: #"\d{1,2}[/-]\d{1,2}|\d+(?:天|周)"#, options: .regularExpression) != nil {
            return true
        }
        return [
            "今年", "去年", "本月", "上月", "本周", "上周", "今天", "昨天",
            "期间", "截至", "截止", "日期", "从", "至", "到", "最近",
            "以前", "之前", "以后", "之后",
            "过去", "近期", "上个月", "这个月", "这周", "上星期", "本星期",
            "季度", "上半年", "下半年", "本年度", "近一年", "近一个月",
        ]
            .contains { value.contains($0) }
    }

    private struct DateFilter {
        let from: String
        let to: String
        let phrase: String
    }

    private static func resolveDates(
        in question: String,
        now: Date,
        timeZone: TimeZone
    ) -> DateFilter? {
        // Only an unambiguous pair of complete Chinese calendar dates is
        // handled here. Relative dates and yearless cross-year ranges need
        // natural-language planning instead of an invented year.
        let pattern = #"(?<!\d)(?:从)?(?:(\d{4})年)?(\d{1,2})月(\d{1,2})(?:日|号)(?:到|至|[-~～—])(?:(\d{4})年)?(\d{1,2})月(\d{1,2})(?:日|号)(?!\d)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = question as NSString
        let matches = expression.matches(in: question, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else {
            return containsExplicitDateFilter(question) ? nil : DateFilter(from: "", to: "", phrase: "")
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        let remainder = text.replacingCharacters(in: match.range, with: "")
            .replacingOccurrences(of: "期间", with: "")
            .replacingOccurrences(of: "日期", with: "")
        guard !containsExplicitDateFilter(remainder) else { return nil }
        func number(_ capture: Int) -> Int? {
            let range = match.range(at: capture)
            return range.location == NSNotFound ? nil : Int(text.substring(with: range))
        }
        guard let fromMonth = number(2), let fromDay = number(3),
              let toMonth = number(5), let toDay = number(6) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentYear = calendar.component(.year, from: now)
        let fromYear = number(1) ?? number(4) ?? currentYear
        let toYear = number(4) ?? number(1) ?? currentYear
        func date(year: Int, month: Int, day: Int) -> Date? {
            let components = DateComponents(year: year, month: month, day: day)
            guard (1...9999).contains(year), let date = calendar.date(from: components),
                  calendar.component(.year, from: date) == year,
                  calendar.component(.month, from: date) == month,
                  calendar.component(.day, from: date) == day else { return nil }
            return date
        }
        guard let start = date(year: fromYear, month: fromMonth, day: fromDay),
              let end = date(year: toYear, month: toMonth, day: toDay),
              start <= end,
              end <= calendar.startOfDay(for: now) else { return nil }
        return DateFilter(
            from: String(format: "%04d-%02d-%02d", fromYear, fromMonth, fromDay),
            to: String(format: "%04d-%02d-%02d", toYear, toMonth, toDay),
            phrase: text.substring(with: match.range)
        )
    }

    private struct PenMatch {
        let name: String
        let range: Range<String.Index>
        let length: Int
    }

    private static func resolvePens(in question: String, availableNames: [String]) -> [String]? {
        var matches: [PenMatch] = []
        for name in Set(availableNames) {
            let key = normalize(name)
            guard !key.isEmpty else { continue }
            var searchStart = question.startIndex
            while searchStart < question.endIndex,
                  let range = question.range(of: key, range: searchStart..<question.endIndex) {
                matches.append(PenMatch(name: name, range: range, length: key.count))
                searchStart = range.upperBound
            }
        }
        // Prefer the complete entity when one pen name is contained in
        // another. Sorting by occurrence afterwards preserves user order.
        matches.sort {
            if $0.length != $1.length { return $0.length > $1.length }
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            return $0.name < $1.name
        }
        var selected: [PenMatch] = []
        for match in matches where !selected.contains(where: { $0.range.overlaps(match.range) }) {
            selected.append(match)
        }
        selected.sort { $0.range.lowerBound < $1.range.lowerBound }
        // A known suffix such as “一舍” must not resolve the unknown entity
        // “大棚十一舍”. Every numbered pen reference must be covered by a
        // complete available name, including a direction suffix when present.
        let numberedPenPattern = #"(?:[大小]棚)?[零〇一二三四五六七八九十百千万两\d]+舍[东西南北]?"#
        if let expression = try? NSRegularExpression(pattern: numberedPenPattern) {
            let references = expression.matches(
                in: question,
                range: NSRange(location: 0, length: (question as NSString).length)
            )
            for reference in references {
                guard let range = Range(reference.range, in: question),
                      selected.contains(where: {
                        $0.range.lowerBound <= range.lowerBound && $0.range.upperBound >= range.upperBound
                      }) else { return nil }
            }
        }
        var remainder = question
        for match in selected.reversed() {
            remainder.replaceSubrange(match.range, with: "")
        }
        // An unmatched pen reference must not turn a partial request into
        // a farm-wide or subset analysis.
        guard !remainder.contains("舍"), !remainder.contains("圈") else { return nil }
        var seen: Set<String> = []
        return selected.compactMap { match in
            seen.insert(normalize(match.name)).inserted ? match.name : nil
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .filter { !$0.isWhitespace && !"，。！？；：、,.!?;:".contains($0) }
    }
}
