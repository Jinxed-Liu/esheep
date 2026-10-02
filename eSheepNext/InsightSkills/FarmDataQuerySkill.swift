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
    - 派生体重计算由模型组合 source、sample_policy、cohort、pen_membership、partition、window、transform、analysis_scope、group 和 reduce，App 执行并审计计算计划。默认增重分析与 App 增重分析页共用 WeightGainAnalyticsEngine：sample_policy=canonical_timeline、cohort=all_profiles、pen_membership=at_cutoff。同日统计点采用常规称重优先，其次可追溯断奶重、初生重，同来源取当天最后一次。
    - 圈舍筛选确定分析结束日牧场时区日末的羊群；分析结束日为当天时截至本轮已读取事实时间。pen_names 数组一次传入用户要求的全部精确圈舍名称；单舍可用兼容字段 pen_name，不筛圈舍时数组和字符串均为空。不能只回答多舍请求中的一个舍，不能用当前圈舍或末次称重圈舍替代历史期末圈舍。跨舍同羊称重连续配对，展示实际转群发生日期及原舍、目标舍，末次称重之后且截止之前的转群也保留。跨舍增重不能推断为某一圈舍独立贡献。
    - 用户询问群体变化率时，即使指定多个圈舍或日期范围也使用 analysis_scope=complete、window=adjacent、transform=difference_per_day；只有明确要求单一值或单一分组才用 focused。返回总体、真实称重区间、生产批次、截止时点生命周期及数据完整性，多舍还逐舍展示结果，零有效样本显示 0 只、日增重 —。单羊先以有效区间总增重除以总观察天数，再按羊只等权平均；区间等权平均仅作明确标注的补充。
    - 仅用户明确询问历史“在舍期间表现”或要求区间全程连续在舍时，使用 pen_membership=at_measurement；recorded_only 可用于明确只分析常规称重。该独立口径验证完整时间线的连续归属，不能删掉中间样本再拼区间。生产批次归属核查整个区间连续且唯一，退出重入、重叠、跨批次和未分批次单列。负增重和零增重保留。用户明确要求截止时仍在群的子样本时才用 cohort=current_in_herd。
    用户给定日期或月份时传入明确范围。date_from/date_to 接受 YYYY-MM-DD（牧场时区完整日）或 ISO 8601；as_of 为空时按分析结束日截止，无结束日则截至本轮事实时间。App 默认增重口径的显式 as_of 也以分析结束日封顶，期末名单与生命周期采用同一截止时间。真实称重区间两端须位于分析范围，不插值，不借范围外称重点补足。无法覆盖全部条件时说明不支持，不得改用近似指标。
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
