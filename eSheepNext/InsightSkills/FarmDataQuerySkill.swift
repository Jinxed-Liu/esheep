import Foundation

/// Semantic layer between natural-language farm questions and the bounded
/// SwiftData query engine. The model chooses a business meaning, not a table.
enum FarmDataQuerySkill {
    static let identifier = "farm-data-query"

    enum QueryKind: String, CaseIterable, Sendable {
        case currentHerd = "current_herd"
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
    牧场事实技能：先理解用户实际询问的量，再自主选择工具。直接明细和单表聚合使用 query_farm_data；涉及同一对象的相邻记录、首末记录、差值、间隔天数或变化速率时，使用 calculate_farm_data 组合通用算子。不要直接选择看起来相近的数据库字段，也不要把工具输出原样当成最终回答。
    - 当前在场、在群、存栏羊只：query_kind=current_herd。状态固定使用全 App 共用的当前投影规则，自动排除历史归档；不得用“没有离群事件”近似代替当前在场状态。
    - 出生羔羊数、产羔羔羊数：query_kind=born_lambs。技能固定读取产羔事件并累加 lambCount。
    - 按出生月份同时询问在群、死亡、出售、淘汰或转出：query_kind=born_lamb_lifecycle。技能同时读取产羔事件总数与羊只档案当前生命周期状态，并把不同口径分列展示。
    - 产羔次数：query_kind=lambing_events。技能统计产羔事件条数，不能与出生羔羊数混用。
    - 羊只档案及档案出生日期：query_kind=sheep_profiles。只有用户明确询问档案字段时使用。
    - 称重、繁殖明细、健康、饲喂、库存分别使用对应 query_kind。
    - 派生体重计算不增加专用指标名：由模型组合 source、cohort、pen_membership、partition、window、transform、analysis_scope、group 和 reduce；App 只执行并审计这份计算计划。cohort=current_in_herd 表示以截止时点仍在群的羊，cohort=all_profiles 表示全部非历史归档档案；pen_membership=at_cutoff 按截止时点圈舍，at_measurement 在完整羊只时间线上验证每个真实相邻区间的圈舍归属。必须按问题的对象和时间口径选择，不能默认套用当前圈舍。
    - 用户询问一个圈舍、批次或群体的变化率而未明确只要某个日期、某一批次、某种生命周期或单一总体值时，analysis_scope=complete；必须用 window=adjacent 和 transform=difference_per_day，完整列出总体结论、不同称重区间、生产批次、截至时点生命周期及数据完整性。单个跨期首末平均值只能作为补充，不能替代相邻区间分析。
    - 历史圈舍表现使用 cohort=all_profiles + pen_membership=at_measurement，并在生命周期维度把当前在群、出售、死亡、淘汰、转出分别展示；用户明确询问“当前仍在群这些羊”时才改用 current_in_herd + at_cutoff。生产批次仅在区间两端属于同一唯一批次时归入该批次，跨批次、重叠和未分批次必须单列。
    用户要求按月时给出明确日期范围。无法覆盖全部条件时说明不支持，不得改用近似指标。
    """

    static func normalize(arguments: [String: Any]) throws -> [String: Any] {
        guard let raw = arguments["query_kind"] as? String,
              let queryKind = QueryKind(rawValue: raw) else {
            throw InsightToolError.invalidArguments("query_kind")
        }
        try validateBeforeCanonicalization(arguments, queryKind: queryKind)
        var values = arguments
        switch queryKind {
        case .currentHerd:
            values["subject"] = "sheep"
            values["status"] = SheepStatus.active.rawValue
            values["as_of"] = ""
            values["relations"] = []
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
            values["as_of"] = ""
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
        try validate(values, queryKind: queryKind)
        return values
    }

    /// Canonical query kinds intentionally replace source-selection fields,
    /// but they must not erase a real user condition such as a historical
    /// cutoff or a relation filter before validation can see it.
    private static func validateBeforeCanonicalization(
        _ values: [String: Any],
        queryKind: QueryKind
    ) throws {
        func text(_ key: String) -> String {
            (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func rejectNonEmpty(_ keys: [String]) throws {
            if let key = keys.first(where: { !text($0).isEmpty }) {
                throw InsightToolError.invalidArguments("\(key) 不适用于 \(queryKind.rawValue)")
            }
        }
        func rejectRelations() throws {
            if let relations = values["relations"] as? [[String: Any]], !relations.isEmpty {
                throw InsightToolError.invalidArguments("relations 不适用于 \(queryKind.rawValue)")
            }
        }

        switch queryKind {
        case .currentHerd:
            try rejectNonEmpty(["as_of"])
            let status = text("status").lowercased()
            if !status.isEmpty, status != SheepStatus.active.rawValue {
                throw InsightToolError.invalidArguments(
                    "status 与 \(queryKind.rawValue) 的当前在场口径冲突"
                )
            }
            try rejectRelations()
        case .bornLambLifecycle:
            try rejectNonEmpty([
                "as_of", "ear_tag", "sex", "status", "breed", "pen_name",
                "kind", "item_name", "minimum_value", "maximum_value",
            ])
            try rejectRelations()
        default:
            break
        }
    }

    /// Rejects conditions that a semantic query cannot actually honor. The
    /// previous generic surface silently dropped several filters and still
    /// labelled the result complete, which is more dangerous than refusing it.
    private static func validate(_ values: [String: Any], queryKind: QueryKind) throws {
        func text(_ key: String) -> String {
            (values[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func rejectNonEmpty(_ keys: [String]) throws {
            if let key = keys.first(where: { !text($0).isEmpty }) {
                throw InsightToolError.invalidArguments("\(key) 不适用于 \(queryKind.rawValue)")
            }
        }
        func rejectRelations() throws {
            if let relations = values["relations"] as? [[String: Any]], !relations.isEmpty {
                throw InsightToolError.invalidArguments("relations 不适用于 \(queryKind.rawValue)")
            }
        }

        let metric = text("metric")
        let allowedMetrics: Set<String>
        switch queryKind {
        case .currentHerd, .sheepProfiles:
            allowedMetrics = ["records", "count"]
        case .bornLambs:
            allowedMetrics = ["sum"]
        case .bornLambLifecycle:
            allowedMetrics = ["count"]
        case .lambingEvents:
            allowedMetrics = ["count"]
        case .weightRecords, .reproductionRecords, .healthRecords, .feedingRecords, .inventory:
            allowedMetrics = ["records", "count", "sum", "average", "minimum", "maximum"]
        }
        guard allowedMetrics.contains(metric) else {
            throw InsightToolError.invalidArguments("metric 不适用于 \(queryKind.rawValue)")
        }

        let groupBy = text("group_by")
        let allowedGroups: Set<String>
        switch queryKind {
        case .currentHerd, .sheepProfiles:
            allowedGroups = ["none", "pen", "breed", "sex", "status", "month"]
        case .bornLambs, .lambingEvents, .reproductionRecords:
            allowedGroups = ["none", "pen", "breed", "kind", "month"]
        case .bornLambLifecycle:
            allowedGroups = ["month"]
        case .weightRecords:
            allowedGroups = ["none", "pen", "breed", "sex", "month"]
        case .healthRecords:
            allowedGroups = ["none", "pen", "breed", "sex", "kind", "item", "month"]
        case .feedingRecords:
            allowedGroups = ["none", "pen", "item", "month"]
        case .inventory:
            allowedGroups = ["none", "kind", "item", "month"]
        }
        guard allowedGroups.contains(groupBy) else {
            throw InsightToolError.invalidArguments("group_by 不适用于 \(queryKind.rawValue)")
        }

        switch queryKind {
        case .currentHerd:
            try rejectNonEmpty(["kind", "item_name", "minimum_value", "maximum_value"])
            try rejectRelations()
        case .bornLambLifecycle:
            try rejectNonEmpty([
                "ear_tag", "sex", "status", "breed", "pen_name", "kind", "item_name",
                "minimum_value", "maximum_value",
            ])
            try rejectRelations()
        case .feedingRecords:
            try rejectNonEmpty(["ear_tag", "sex", "status", "breed", "kind"])
            try rejectRelations()
        case .inventory:
            try rejectNonEmpty(["ear_tag", "sex", "status", "breed", "pen_name"])
            try rejectRelations()
        case .bornLambs, .lambingEvents, .reproductionRecords:
            try rejectNonEmpty(["status", "item_name"])
            try rejectRelations()
        case .weightRecords:
            try rejectNonEmpty(["status", "kind", "item_name"])
            try rejectRelations()
        case .healthRecords:
            try rejectNonEmpty(["status"])
            try rejectRelations()
        case .sheepProfiles:
            try rejectNonEmpty(["kind", "item_name", "minimum_value", "maximum_value"])
        }
    }
}
