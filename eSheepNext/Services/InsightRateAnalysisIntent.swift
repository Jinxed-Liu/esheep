import Foundation

/// A small semantic gate for the one class of question where returning a raw
/// record is materially wrong: a request for weight change or daily gain.
///
/// This is not a second natural-language answer engine. It only identifies a
/// well-known analytical intent and lets the local typed calculator run before
/// the model gets a chance to collapse it into `query_farm_records`. Entity
/// resolution (the pen name) still comes from the current farm's records.
struct InsightRateAnalysisIntent: Equatable, Sendable {
    let penName: String?

    static func detect(
        question: String,
        availablePenNames: [String]
    ) -> InsightRateAnalysisIntent? {
        let normalized = normalize(question)
        guard !normalized.isEmpty,
              containsRateIntent(normalized),
              !containsRecordOnlyIntent(normalized),
              !containsExplicitDateFilter(normalized),
              !containsSingleEntityIntent(normalized) else {
            return nil
        }

        let penName = availablePenNames
            .filter { !normalize($0).isEmpty && normalized.contains(normalize($0)) }
            .max {
                normalize($0).count < normalize($1).count
            }
        return InsightRateAnalysisIntent(penName: penName)
    }

    /// The complete rate plan is intentionally fixed only after the semantic
    /// gate has fired. It mirrors the calculation tool's complete-plan
    /// contract: every sheep's real adjacent weighing intervals, then the
    /// overall, interval, production-batch and lifecycle dimensions.
    var calculationArguments: [String: Any] {
        [
            "source": "weight_samples",
            "sample_policy": "recorded_only",
            "cohort": "all_profiles",
            "pen_membership": "at_measurement",
            "pen_name": penName ?? "",
            "ear_tag": "",
            "breed": "",
            "sex": "",
            "date_from": "",
            "date_to": "",
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
        let scope = penName.map { "圈舍“\($0)”" } ?? "当前牧场"
        return "本轮已识别为\(scope)的增重/日增重分析请求。App 已先用本地权威称重数据完成完整计算；请直接依据该计算证据回答，保留总体结论、称重区间、生产批次、生命周期和数据完整性五个部分，不要改查单条称重记录。"
    }

    private static func containsRateIntent(_ value: String) -> Bool {
        [
            "日增重", "平均日增重", "日增重率", "增重速度", "生长速度",
            "每天增重", "每天增加多少", "体重增长", "增重多少", "增长多少",
            "daily gain", "average daily gain", "weight gain", "gain/day", "adg",
        ].contains { value.contains($0) }
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

    private static func containsExplicitDateFilter(_ value: String) -> Bool {
        if value.range(of: #"20\d{2}"#, options: .regularExpression) != nil ||
            value.range(of: #"\d{1,2}月"#, options: .regularExpression) != nil {
            return true
        }
        return ["今年", "去年", "本月", "上月", "期间", "截至", "日期", "从", "至", "到"]
            .contains { value.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .filter { !$0.isWhitespace && !"，。！？；：、,.!?;:".contains($0) }
    }
}
