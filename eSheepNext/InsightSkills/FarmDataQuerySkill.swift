import Foundation

/// Semantic layer between natural-language farm questions and the bounded
/// SwiftData query engine. The model chooses a business meaning, not a table.
enum FarmDataQuerySkill {
    static let identifier = "farm-data-query"

    enum QueryKind: String, CaseIterable, Sendable {
        case sheepProfiles = "sheep_profiles"
        case bornLambs = "born_lambs"
        case bornLambLifecycle = "born_lamb_lifecycle"
        case lambingEvents = "lambing_events"
        case weightRecords = "weight_records"
        case reproductionRecords = "reproduction_records"
        case healthRecords = "health_records"
        case feedingRecords = "feeding_records"
        case inventory = "inventory"
    }

    static let instructions = """
    牧场数据查询技能：先确定用户询问的业务指标，再调用 query_farm_data。不要直接选择看起来相近的数据库字段。
    - 出生羔羊数、产羔羔羊数：query_kind=born_lambs。技能固定读取产羔事件并累加 lambCount。
    - 按出生月份同时询问在群、死亡、出售、淘汰或转出：query_kind=born_lamb_lifecycle。技能同时读取产羔事件总数与羊只档案当前生命周期状态，并把不同口径分列展示。
    - 产羔次数：query_kind=lambing_events。技能统计产羔事件条数，不能与出生羔羊数混用。
    - 羊只档案及档案出生日期：query_kind=sheep_profiles。只有用户明确询问档案字段时使用。
    - 称重、繁殖明细、健康、饲喂、库存分别使用对应 query_kind。
    用户要求按月时使用 group_by=month 并给出明确日期范围。无法覆盖全部条件时说明不支持，不得改用近似指标。
    """

    static func normalize(arguments: [String: Any]) throws -> [String: Any] {
        guard let raw = arguments["query_kind"] as? String,
              let queryKind = QueryKind(rawValue: raw) else {
            throw InsightToolError.invalidArguments("query_kind")
        }
        var values = arguments
        switch queryKind {
        case .bornLambs:
            values["subject"] = "reproduction"
            values["date_field"] = "occurred_at"
            values["kind"] = ReproductionRecordKind.lambing.rawValue
            values["metric"] = "sum"
        case .bornLambLifecycle:
            values["subject"] = "sheep"
            values["date_field"] = "birth_at"
            values["group_by"] = "month"
            values["metric"] = "count"
            values["status"] = ""
            values["relations"] = []
        case .lambingEvents:
            values["subject"] = "reproduction"
            values["date_field"] = "occurred_at"
            values["kind"] = ReproductionRecordKind.lambing.rawValue
            values["metric"] = "count"
        case .sheepProfiles:
            values["subject"] = "sheep"
        case .weightRecords:
            values["subject"] = "weights"
            values["date_field"] = "occurred_at"
        case .reproductionRecords:
            values["subject"] = "reproduction"
            values["date_field"] = "occurred_at"
        case .healthRecords:
            values["subject"] = "health"
            values["date_field"] = "occurred_at"
        case .feedingRecords:
            values["subject"] = "feeding"
            values["date_field"] = "occurred_at"
        case .inventory:
            values["subject"] = "inventory"
        }
        values["query_kind"] = queryKind.rawValue
        return values
    }

    static func requiredQueryKind(for userText: String) -> QueryKind? {
        let value = userText.replacingOccurrences(of: " ", with: "")
        let asksBornLambs = value.contains("出生多少羔羊")
            || value.contains("出生羔羊数")
            || value.contains("出生的羔羊")
            || value.contains("产羔多少只")
            || value.contains("产羔羔羊数")
            || (value.contains("出生") && value.contains("羔羊"))
        guard asksBornLambs else { return nil }
        let asksLifecycle = ["在群", "死亡", "死淘", "出售", "售卖", "淘汰", "转出", "离群"]
            .contains(where: value.contains)
        return asksLifecycle ? .bornLambLifecycle : .bornLambs
    }

    static func queryKind(in argumentsJSON: String) -> QueryKind? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawValue = object["query_kind"] as? String else {
            return nil
        }
        return QueryKind(rawValue: rawValue)
    }
}
