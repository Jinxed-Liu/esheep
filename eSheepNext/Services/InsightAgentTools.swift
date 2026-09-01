import EventKit
import Foundation
import LocalAuthentication
import SwiftData

enum InsightToolError: LocalizedError {
    case unknownTool
    case invalidArguments(String)
    case permissionDenied
    case crossFarmReference
    case staleRevision
    case obsoleteWeaningDraft
    case resultTooLarge
    case farmFactsUnavailable(String)
    case extendedDataConsentRequired
    case deviceActionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool:
            "模型请求了未授权的工具。"
        case .invalidArguments(let field):
            "工具参数无效：\(field)。"
        case .permissionDenied:
            "当前牧场角色没有执行此工具的权限。"
        case .crossFarmReference:
            "工具引用的数据不属于当前牧场。"
        case .staleRevision:
            "草案引用的数据已经变化，请重新生成草案。"
        case .obsoleteWeaningDraft:
            "这张旧版断奶草案缺少目标圈舍，请删除后重新让 AI 生成断奶卡片。"
        case .resultTooLarge:
            "工具结果超过安全发送范围，需要缩小查询。"
        case .farmFactsUnavailable(let message):
            "牧场事实暂不可用：\(message)"
        case .extendedDataConsentRequired:
            "该工具需要用户针对本次扩展数据发送明确授权。"
        case .deviceActionUnavailable(let message):
            message
        }
    }
}

struct InsightAgentContext: Sendable {
    let accountID: UUID
    let farmID: UUID
    let role: FarmRole
    let originDeviceID: UUID
    let conversationID: UUID

    var farmContext: FarmContext {
        FarmContext(accountID: accountID, farmID: farmID, role: role)
    }
}

struct InsightGeneratedFile: Sendable, Equatable, Identifiable {
    enum FileKind: String, Sendable, Equatable {
        case xlsx
        case json
        case csv
    }

    let id: UUID
    let fileName: String
    let kind: FileKind
    let data: Data

    init(
        id: UUID = UUID(),
        fileName: String,
        kind: FileKind,
        data: Data
    ) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.data = data
    }
}

struct InsightToolExecution {
    let output: String
    let actionDrafts: [InsightActionDraftRecord]
    let generatedFile: InsightGeneratedFile?

    var actionDraft: InsightActionDraftRecord? {
        actionDrafts.first
    }

    init(output: String, actionDraft: InsightActionDraftRecord?) {
        self.output = output
        self.actionDrafts = actionDraft.map { [$0] } ?? []
        self.generatedFile = nil
    }

    init(output: String, actionDrafts: [InsightActionDraftRecord]) {
        self.output = output
        self.actionDrafts = actionDrafts
        self.generatedFile = nil
    }

    init(output: String, generatedFile: InsightGeneratedFile) {
        self.output = output
        self.actionDrafts = []
        self.generatedFile = generatedFile
    }
}

struct InsightExtendedDataDisclosure: Sendable, Equatable, Identifiable {
    let id: String
    let category: String
    let dateRange: String
    let rowCount: Int
    let estimatedBytes: Int

    var message: String {
        "类别：\(category)\n日期：\(dateRange)\n记录：\(rowCount) 条\n预计：\(ByteCountFormatter.string(fromByteCount: Int64(estimatedBytes), countStyle: .file))\n仅授权本次工具调用。"
    }
}

struct RecordWeightToolPayload: Codable {
    let sheepID: UUID
    let earTag: String
    let kilogramsText: String
    let occurredAt: Date
    let note: String
}

struct RecordWeaningToolPayload: Codable {
    let sheepID: UUID
    let earTag: String
    let weanWeightText: String
    let toPenID: UUID
    let penName: String
    let occurredAt: Date
    let note: String
}

private struct AddNoteToolPayload: Codable {
    let sheepID: UUID?
    let penID: UUID?
    let subject: String
    let text: String
    let occurredAt: Date
}

private struct TransferSheepToolPayload: Codable {
    let sheepID: UUID
    let earTag: String
    let toPenID: UUID?
    let penName: String
    let occurredAt: Date
    let note: String
}

struct CanonicalFarmCommandToolPayload: Codable {
    let commandPayload: Data
}

struct InsightReminderDraft: Codable, Sendable, Equatable {
    let title: String
    let notes: String
    let dueAt: Date?
}

struct InsightCalendarEventDraft: Codable, Sendable, Equatable {
    let title: String
    let notes: String
    let startAt: Date
    let endAt: Date
}

@MainActor
final class InsightToolRegistry {
    static let maximumRows = 50
    static let maximumBatchEarTags = 200
    static let maximumOutputBytes = 100 * 1_024

    private struct SheepEarTagIndex {
        let exactMatches: [String: [SheepRecord]]
        let numericBodyMatches: [String: [SheepRecord]]
    }

    private enum SheepEarTagResolution {
        case matched(SheepRecord, matchKind: String)
        case ambiguous([SheepRecord])
        case notFound
    }

    private struct FarmValidationSnapshot {
        let knownEntityIDs: Set<UUID>
        let revisionsByEntityID: [UUID: Int]
    }

    func definitions(for farm: FarmContext) -> [InsightToolDefinition] {
        guard farm.capabilities.allows(.readFarm) else { return [] }
        var values = [
            Self.tool(
                "get_farm_overview",
                "读取当前牧场的羊只、圈舍、今日投喂和近七日健康记录数量。只返回聚合数据。",
                properties: [:],
                required: []
            ),
            Self.tool(
                InsightFarmQueryEngine.toolName,
                "读取当前牧场的权威明细或执行不需要跨行时间运算的直接聚合。当前在场、在群、存栏使用 query_kind=current_herd；出生羔羊数使用 born_lambs。需要相邻记录、首末记录、差值、间隔或变化速率时改用 calculate_farm_data。所有筛选都在 App 本地执行，字符串筛选不需要时传空字符串。",
                properties: [
                    "query_kind": Self.enumString(
                        "业务查询口径。必须先按牧场数据查询技能选择；App 会据此固定真实数据源，无法完整执行的条件会被拒绝。",
                        values: FarmDataQuerySkill.QueryKind.allCases.map(\.rawValue)
                    ),
                    "subject": Self.enumString(
                        "查询对象",
                        values: ["sheep", "weights", "reproduction", "health", "feeding", "inventory"]
                    ),
                    "date_field": Self.enumString(
                        "日期范围和按月分组所使用的明确字段。sheep 只能用 none、birth_at、entered_at；业务记录只能用 occurred_at；inventory 用 none 或 expires_at。不得同时描述两个日期口径。",
                        values: ["none", "birth_at", "entered_at", "occurred_at", "expires_at"]
                    ),
                    "date_from": Self.string("ISO 8601 开始时间；不限制时传空字符串"),
                    "date_to": Self.string("ISO 8601 结束时间；不限制时传空字符串"),
                    "as_of": Self.string("历史状态截止时点 ISO 8601；查询当前状态时传空字符串"),
                    "ear_tag": Self.string("耳号关键词；不筛选时传空字符串"),
                    "sex": Self.enumString("性别", values: ["", "ewe", "ram", "unknown"]),
                    "status": Self.enumString("羊只状态", values: ["", "active", "removed", "deceased"]),
                    "breed": Self.string("品种关键词；不筛选时传空字符串"),
                    "pen_name": Self.string("圈舍名称关键词；不筛选时传空字符串"),
                    "kind": Self.string("记录类型原始值；不筛选时传空字符串"),
                    "item_name": Self.string("健康项目、饲料原料或库存名称关键词；不筛选时传空字符串"),
                    "group_by": Self.enumString(
                        "分组字段",
                        values: ["none", "pen", "breed", "sex", "status", "kind", "item", "month"]
                    ),
                    "metric": Self.enumString(
                        "结果形式；records 返回明细，其余返回确定性聚合",
                        values: ["records", "count", "sum", "average", "minimum", "maximum"]
                    ),
                    "minimum_value": Self.string("数值下限；不限制时传空字符串"),
                    "maximum_value": Self.string("数值上限；不限制时传空字符串"),
                    "relations": .object([
                        "type": .string("array"),
                        "description": .string("仅查询 sheep 时使用的关联事件条件，可同时给出最多 8 条，例如既有产羔记录且最近没有配种；无关联条件时传空数组"),
                        "maxItems": .number(8),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "subject": Self.enumString(
                                    "关联记录",
                                    values: ["weights", "weanings", "reproduction", "health", "transfers", "removals"]
                                ),
                                "kind": Self.string("记录类型原始值；不限制时传空字符串"),
                                "item_name": Self.string("健康项目关键词；不限制时传空字符串"),
                                "date_from": Self.string("ISO 8601 开始时间；不限制时传空字符串"),
                                "date_to": Self.string("ISO 8601 结束时间；不限制时传空字符串"),
                                "existence": Self.enumString("必须存在或必须不存在", values: ["yes", "no"]),
                                "minimum_count": .object([
                                    "type": .string("integer"),
                                    "minimum": .number(0),
                                    "maximum": .number(10_000),
                                ]),
                                "maximum_count": .object([
                                    "type": .string("integer"),
                                    "description": .string("0 表示不设上限"),
                                    "minimum": .number(0),
                                    "maximum": .number(10_000),
                                ]),
                                "minimum_value": Self.string("关联数值下限，如体重或产羔数；不限制时传空字符串"),
                                "maximum_value": Self.string("关联数值上限；不限制时传空字符串"),
                            ]),
                            "required": .array([
                                "subject", "kind", "item_name", "date_from", "date_to", "existence",
                                "minimum_count", "maximum_count", "minimum_value", "maximum_value",
                            ].map(JSONValue.string)),
                            "additionalProperties": .bool(false),
                        ]),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("明细最多返回 1 到 100 条"),
                        "minimum": .number(1),
                        "maximum": .number(100),
                    ]),
                ],
                required: [
                    "query_kind", "subject", "date_field", "date_from", "date_to", "as_of", "ear_tag", "sex", "status",
                    "breed", "pen_name", "kind", "item_name", "group_by", "metric",
                    "minimum_value", "maximum_value", "relations", "limit",
                ]
            ),
            Self.tool(
                InsightFarmCalculationEngine.toolName,
                "在当前设备的权威牧场事实上执行通用数值流水线：选择样本源和群体，按羊分区，选择单点/相邻/首末窗口，再计算值、差值、日历间隔或单位日变化，最后分组并聚合。完整群体变化率分析可一次确定性返回总体、真实相邻称重区间、生产批次和截至时点生命周期四个维度。工具不理解自然语言指标；模型必须根据用户问题自行组合算子。结果是证据而不是最终答复。当前仅支持体重样本源。",
                properties: [
                    "source": Self.enumString(
                        "本地数值事实源",
                        values: ["weight_samples"]
                    ),
                    "sample_policy": Self.enumString(
                        "recorded_only 只用常规称重；canonical_timeline 使用按牧场日去重的统一体重时间线",
                        values: ["recorded_only", "canonical_timeline"]
                    ),
                    "cohort": Self.enumString(
                        "参与计算的羊只群体；current_in_herd 使用 App 统一当前状态事实",
                        values: ["all_profiles", "current_in_herd", "removed"]
                    ),
                    "pen_membership": Self.enumString(
                        "圈舍筛选时点：at_cutoff 按 as_of 时点归属；at_measurement 按每条样本发生时归属",
                        values: ["at_cutoff", "at_measurement"]
                    ),
                    "pen_name": Self.string("精确圈舍名称；不筛选时传空字符串"),
                    "ear_tag": Self.string("耳号关键词；不筛选时传空字符串"),
                    "breed": Self.string("品种关键词；不筛选时传空字符串"),
                    "sex": Self.enumString(
                        "性别；不筛选时传空字符串",
                        values: ["", "ewe", "ram", "unknown"]
                    ),
                    "date_from": Self.string("样本 ISO 8601 开始时间；不限制时传空字符串"),
                    "date_to": Self.string("样本 ISO 8601 结束时间；不限制时传空字符串"),
                    "as_of": Self.string("群体状态和样本截止时点 ISO 8601；当前时点传空字符串"),
                    "partition_by": Self.enumString(
                        "窗口计算必须按 sheep 分区；单点聚合可用 none",
                        values: ["sheep", "none"]
                    ),
                    "window": Self.enumString(
                        "none 为每条样本；adjacent 为同羊相邻两点；first_to_last 为同羊首末两点",
                        values: ["none", "adjacent", "first_to_last"]
                    ),
                    "transform": Self.enumString(
                        "value 取终点值；difference 终点减起点；elapsed_days 牧场日历天数；difference_per_day 差值除以牧场日历天数",
                        values: ["value", "difference", "elapsed_days", "difference_per_day"]
                    ),
                    "analysis_scope": Self.enumString(
                        "complete 用于未明确限定单一视角的群体变化率分析，并强制返回总体、称重区间、生产批次、生命周期及完整性；focused 仅用于用户明确指定单一值或单一分组",
                        values: ["focused", "complete"]
                    ),
                    "group_by": Self.enumString(
                        "主结果按整体、真实起止称重区间、区间终点日/月、生产批次、截至时点生命周期、羊只或圈舍分组；complete 还会自动返回四个完整分析维度",
                        values: [
                            "none", "weighing_interval", "interval_end_day", "interval_end_month",
                            "production_batch", "lifecycle_status", "sheep", "pen",
                        ]
                    ),
                    "reduce": Self.enumString(
                        "对每组观察值返回明细或执行确定性聚合",
                        values: ["records", "count", "sum", "average", "minimum", "maximum"]
                    ),
                    "selection": Self.enumString(
                        "all 返回全部分组；latest 仅用于日期分组并返回最近一组",
                        values: ["all", "latest"]
                    ),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("最多返回 1 到 100 个分组或明细"),
                        "minimum": .number(1),
                        "maximum": .number(100),
                    ]),
                ],
                required: [
                    "source", "sample_policy", "cohort", "pen_membership", "pen_name",
                    "ear_tag", "breed", "sex", "date_from", "date_to", "as_of",
                    "partition_by", "window", "transform", "analysis_scope", "group_by", "reduce",
                    "selection", "limit",
                ]
            ),
            Self.tool(
                "find_sheep",
                "在当前牧场按耳号或品种查找羊只，精确耳号优先，最多返回 20 条。返回出生日期、入场日期、性别、品种、统一事实契约下的当前状态和圈舍；不能访问其他牧场。",
                properties: [
                    "query": Self.string("耳号或品种关键词"),
                ],
                required: ["query"]
            ),
            Self.tool(
                "match_sheep_ear_tags",
                "一次批量核对当前牧场的 1 到 200 个耳号。多个耳号或图片识别出的耳号必须一次调用本工具，不能逐个调用 find_sheep。精确耳号优先；输入为纯数字时，只在去掉现有耳号的非数字前缀后能够唯一对应时匹配。歧义项不会猜测。",
                properties: [
                    "ear_tags": .object([
                        "type": .string("array"),
                        "description": .string("要核对的 1 到 200 个耳号，保持用户或图片中的原始顺序"),
                        "minItems": .number(1),
                        "maxItems": .number(Double(Self.maximumBatchEarTags)),
                        "items": Self.string("一个原始耳号"),
                    ]),
                ],
                required: ["ear_tags"]
            ),
            Self.tool(
                "get_farm_entities",
                "读取当前牧场圈舍、生产批次、饲料目录、健康目录、库存、冻精、供体或提醒的权威名称、UUID、状态和 revision。生成引用这些实体的操作草案前必须先查询，不能猜 UUID。",
                properties: [
                    "category": Self.enumString(
                        "实体类别",
                        values: [
                            "pens", "production_batches", "ingredients", "recipes",
                            "health_catalog", "inventory_lots", "semen",
                            "semen_donors", "reminders",
                        ]
                    ),
                    "query": Self.string("名称、编号或批号关键词；空字符串返回全部"),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("1 到 50"),
                        "minimum": .number(1),
                        "maximum": .number(50),
                    ]),
                ],
                required: ["category", "query", "limit"]
            ),
        ]
        let exportFormats =
            (farm.capabilities.allows(.exportFarm) ? ["xlsx", "backup"] : [])
            + (farm.capabilities.allows(.recordProduction) ? ["template"] : [])
        if !exportFormats.isEmpty {
            values.append(
                Self.tool(
                    "create_farm_export",
                    "直接调用 App 的权威导出接口生成文件。xlsx 为当前牧场 Excel 工作簿，backup 为可恢复的完整 JSON 备份，template 为全功能 Excel 录入模板。工具成功只代表文件已生成，仍需用户在系统保存面板选择位置。",
                    properties: [
                        "format": Self.enumString(
                            "导出格式",
                            values: exportFormats
                        ),
                    ],
                    required: ["format"]
                )
            )
        }
        if farm.capabilities.allows(.viewAnalytics) {
            values.append(contentsOf: [
                Self.tool(
                    "analyze_farm",
                    "按当前牧场的权威记录计算聚合分析。模型应根据问题自主选择 population、weight、lamb、reproduction 或 feeding；不会返回原始备注或跨牧场数据。",
                    properties: [
                        "focus": Self.string("分析主题：population、weight、lamb、reproduction、feeding"),
                        "year": Self.string("四位年份；空字符串表示全部年份"),
                    ],
                    required: ["focus", "year"]
                ),
                Self.tool(
                    "get_extended_farm_records",
                    "读取当前牧场的原始备注、健康明细或繁殖明细。每次调用前 App 都会向用户显示类别、日期范围、条数和大小并单次授权；拒绝后不得重试索取。",
                    properties: [
                        "category": Self.enumString(
                            "扩展数据类别",
                            values: ["raw_notes", "health", "reproduction"]
                        ),
                        "from": Self.string("ISO 8601 开始时间"),
                        "to": Self.string("ISO 8601 结束时间"),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("1 到 50"),
                            "minimum": .number(1),
                            "maximum": .number(50),
                        ]),
                    ],
                    required: ["category", "from", "to", "limit"]
                )
            ])
        }
        values.append(contentsOf: [
            Self.tool(
                "get_farm_action_schema",
                "读取某个牧场动作的本地白名单载荷格式。计划修改牧场数据时，先调用此工具，再调用 draft_farm_command。",
                properties: [
                    "operation_kind": Self.enumString(
                        "牧场动作类型",
                        values: Self.aiFarmOperationKinds.map(\.rawValue)
                    ),
                ],
                required: ["operation_kind"]
            ),
            Self.tool(
                "draft_reminder",
                "生成一个系统提醒事项草案。必须由用户在 App 中确认后才会写入提醒事项。",
                properties: [
                    "title": Self.string("提醒标题"),
                    "notes": Self.string("补充说明，可为空"),
                    "due_at": Self.string("ISO 8601 到期时间，可为空字符串"),
                ],
                required: ["title", "notes", "due_at"]
            ),
            Self.tool(
                "draft_calendar_event",
                "生成一个系统日历事件草案。必须由用户在 App 中确认后才会写入日历。",
                properties: [
                    "title": Self.string("事件标题"),
                    "notes": Self.string("事件说明，可为空"),
                    "start_at": Self.string("ISO 8601 开始时间"),
                    "end_at": Self.string("ISO 8601 结束时间，必须晚于开始时间"),
                ],
                required: ["title", "notes", "start_at", "end_at"]
            ),
        ])
        if Self.aiFarmOperationKinds.contains(where: {
            farm.capabilities.allows(Self.capability(for: $0))
        }) {
            values.append(
                Self.tool(
                    "draft_farm_command",
                    "根据 get_farm_action_schema 返回的格式生成牧场操作草案。payload_json 必须是该格式的 JSON 字符串；风险、权限和命令类型由 App 本地重新计算。模型绝不能直接执行。",
                    properties: [
                        "operation_kind": Self.enumString(
                            "必须与 payload_json.kind 完全一致",
                            values: Self.aiFarmOperationKinds.map(\.rawValue)
                        ),
                        "payload_json": Self.string("规范 FarmCommandCloudPayload JSON，最多 32 KB"),
                    ],
                    required: ["operation_kind", "payload_json"]
                )
            )
        }
        if farm.capabilities.allows(.recordProduction) {
            values.append(contentsOf: [
                Self.tool(
                    "draft_record_weaning",
                    "为单只羊生成一张真正的断奶事件草案，并在同一次用户确认中把该羊调入目标圈舍。多只羊必须改用 draft_record_weanings。断奶不需要母本或胎只数；不要改用称重草案，也不要另生成转群草案。只接受当前牧场已存在的精确耳号、有效圈舍和大于零的断奶重。",
                    properties: [
                        "ear_tag": Self.string("断奶羊只的精确耳号"),
                        "wean_weight": Self.string("大于零的断奶重量，单位千克"),
                        "to_pen_name": Self.string("断奶后调入的精确目标圈舍名称"),
                        "occurred_at": Self.string("ISO 8601 断奶及调舍时间"),
                        "note": Self.string("备注，可为空"),
                    ],
                    required: ["ear_tag", "wean_weight", "to_pen_name", "occurred_at", "note"]
                ),
                Self.tool(
                    "draft_record_weanings",
                    "一次为 1 到 50 只羊生成完整断奶卡片。整批使用同一个断奶日期、目标圈舍和备注；每张卡片在一次用户确认后原子写入断奶事实并调入目标圈舍。必须整批校验成功后才生成，不能拆成称重卡片和转群卡片。",
                    properties: [
                        "occurred_at": Self.string("全部羊只共同使用的 ISO 8601 断奶及调舍时间"),
                        "to_pen_name": Self.string("全部羊只断奶后调入的精确目标圈舍名称"),
                        "note": Self.string("全部羊只共同使用的备注，可为空"),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("1 到 50 条断奶数据，保持用户确认的原始顺序"),
                            "minItems": .number(1),
                            "maxItems": .number(Double(Self.maximumRows)),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "ear_tag": Self.string("当前牧场已存在的精确耳号"),
                                    "wean_weight": Self.string("大于零的断奶重量，单位千克"),
                                ]),
                                "required": .array([
                                    .string("ear_tag"),
                                    .string("wean_weight"),
                                ]),
                                "additionalProperties": .bool(false),
                            ]),
                        ]),
                    ],
                    required: ["occurred_at", "to_pen_name", "note", "items"]
                ),
                Self.tool(
                    "draft_record_weight",
                    "生成一条羊只称重草案。只接受当前牧场已存在的精确耳号，用户确认后才执行。",
                    properties: [
                        "ear_tag": Self.string("精确耳号"),
                        "kilograms": Self.string("大于零的公斤数"),
                        "occurred_at": Self.string("ISO 8601 称重时间"),
                        "note": Self.string("备注，可为空"),
                    ],
                    required: ["ear_tag", "kilograms", "occurred_at", "note"]
                ),
                Self.tool(
                    "draft_record_weights",
                    "一次生成多条同一时间的羊只称重草案。用户已经给出多个明确耳号和重量时必须优先使用本工具，不要逐条调用 draft_record_weight，也不要先拿一条试提交。所有草案都只会显示为待确认，用户逐项确认后才执行。",
                    properties: [
                        "occurred_at": Self.string("全部称重共同使用的 ISO 8601 称重时间"),
                        "note": Self.string("全部称重共同使用的备注，可为空"),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("1 到 50 条称重数据"),
                            "minItems": .number(1),
                            "maxItems": .number(Double(Self.maximumRows)),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "ear_tag": Self.string("当前牧场已存在的精确耳号"),
                                    "kilograms": Self.string("大于零的公斤数"),
                                ]),
                                "required": .array([
                                    .string("ear_tag"),
                                    .string("kilograms"),
                                ]),
                                "additionalProperties": .bool(false),
                            ]),
                        ]),
                    ],
                    required: ["occurred_at", "note", "items"]
                ),
                Self.tool(
                    "draft_sell_sheep_batch",
                    "一次为 1 到 200 只羊生成同一批次的出售草案。用户说明多只羊在同一天全部出售并给出一个总售卖金额时必须使用本工具，只调用一次；无需先逐只查羊，也不要逐只调用 draft_farm_command。精确耳号优先；纯数字只在去掉现有耳号的非数字前缀后唯一对应时匹配。App 会为每只羊生成待确认卡片，共享同一个出售批次和总金额；用户在任一卡片选择执行同批操作并通过一次生物认证后，整批才会写入。",
                    properties: [
                        "occurred_at": Self.string("全部羊只共同使用的 ISO 8601 出售时间"),
                        "total_amount": Self.string("本批全部羊只合计的大于零售卖金额"),
                        "note": Self.string("本批出售备注，可为空"),
                        "ear_tags": .object([
                            "type": .string("array"),
                            "description": .string("1 到 200 个当前在场羊只耳号，可使用能够唯一对应现有字母前缀耳号的纯数字"),
                            "minItems": .number(1),
                            "maxItems": .number(Double(Self.maximumBatchEarTags)),
                            "items": Self.string("当前牧场已存在且在场的耳号"),
                        ]),
                    ],
                    required: ["occurred_at", "total_amount", "note", "ear_tags"]
                ),
                Self.tool(
                    "draft_add_note",
                    "生成牧场备注草案，可关联羊只或圈舍。用户确认后才执行。",
                    properties: [
                        "ear_tag": Self.string("精确耳号，可为空字符串"),
                        "pen_name": Self.string("精确圈舍名称，可为空字符串"),
                        "text": Self.string("备注正文"),
                        "occurred_at": Self.string("ISO 8601 发生时间"),
                    ],
                    required: ["ear_tag", "pen_name", "text", "occurred_at"]
                ),
                Self.tool(
                    "draft_transfer_sheep",
                    "生成羊只转群草案。目标圈舍为空字符串表示转为未分圈，用户确认后才执行。",
                    properties: [
                        "ear_tag": Self.string("精确耳号"),
                        "to_pen_name": Self.string("精确目标圈舍名称，可为空字符串"),
                        "occurred_at": Self.string("ISO 8601 转群时间"),
                        "note": Self.string("备注，可为空"),
                    ],
                    required: ["ear_tag", "to_pen_name", "occurred_at", "note"]
                ),
            ])
        }
        return values
    }

    func execute(
        _ call: InsightFunctionCall,
        agent: InsightAgentContext,
        context: ModelContext,
        extendedDataAuthorized: Bool = false
    ) throws -> InsightToolExecution {
        guard agent.farmContext.capabilities.allows(.readFarm) else {
            throw InsightToolError.permissionDenied
        }
        let arguments = try Self.arguments(call.argumentsJSON)
        switch call.name {
        case "get_farm_overview":
            return .init(output: try farmOverview(farmID: agent.farmID, context: context), actionDraft: nil)
        case InsightFarmQueryEngine.toolName:
            return .init(
                output: try InsightFarmQueryEngine().execute(
                    arguments: arguments,
                    farmID: agent.farmID,
                    context: context
                ),
                actionDraft: nil
            )
        case InsightFarmCalculationEngine.toolName:
            return .init(
                output: try InsightFarmCalculationEngine().execute(
                    arguments: arguments,
                    farmID: agent.farmID,
                    context: context
                ),
                actionDraft: nil
            )
        case "find_sheep":
            return .init(
                output: try findSheep(
                    query: try Self.string(arguments, "query"),
                    farmID: agent.farmID,
                    context: context
                ),
                actionDraft: nil
            )
        case "match_sheep_ear_tags":
            guard let earTags = arguments["ear_tags"] as? [String],
                  (1...Self.maximumBatchEarTags).contains(earTags.count) else {
                throw InsightToolError.invalidArguments("ear_tags")
            }
            return .init(
                output: try matchSheepEarTags(
                    earTags,
                    farmID: agent.farmID,
                    context: context
                ),
                actionDraft: nil
            )
        case "get_farm_entities":
            return .init(
                output: try farmEntities(
                    category: try Self.nonempty(arguments, "category"),
                    query: try Self.string(arguments, "query"),
                    limit: try Self.integer(
                        arguments,
                        "limit",
                        range: 1...Self.maximumRows
                    ),
                    farmID: agent.farmID,
                    context: context
                ),
                actionDraft: nil
            )
        case "create_farm_export":
            return try createFarmExport(
                format: try Self.nonempty(arguments, "format"),
                agent: agent,
                farmID: agent.farmID,
                context: context
            )
        case "analyze_farm":
            try require(.viewAnalytics, agent: agent)
            return .init(
                output: try analyzeFarm(
                    focus: try Self.nonempty(arguments, "focus"),
                    year: try Self.string(arguments, "year"),
                    farmID: agent.farmID,
                    context: context
                ),
                actionDraft: nil
            )
        case "get_extended_farm_records":
            try require(.viewAnalytics, agent: agent)
            guard extendedDataAuthorized else {
                throw InsightToolError.extendedDataConsentRequired
            }
            return .init(
                output: try extendedFarmRecords(
                    arguments,
                    farmID: agent.farmID,
                    context: context
                ),
                actionDraft: nil
            )
        case "get_farm_action_schema":
            return .init(
                output: try actionSchema(
                    operationKind: try Self.nonempty(arguments, "operation_kind")
                ),
                actionDraft: nil
            )
        case "draft_farm_command":
            return try canonicalFarmCommandDraft(arguments, agent: agent, context: context)
        case "draft_record_weaning":
            try require(.recordProduction, agent: agent)
            return try recordWeaningDraft(arguments, agent: agent, context: context)
        case "draft_record_weanings":
            try require(.recordProduction, agent: agent)
            return try recordWeaningDrafts(arguments, agent: agent, context: context)
        case "draft_record_weight":
            try require(.recordProduction, agent: agent)
            return try recordWeightDraft(arguments, agent: agent, context: context)
        case "draft_record_weights":
            try require(.recordProduction, agent: agent)
            return try recordWeightDrafts(arguments, agent: agent, context: context)
        case "draft_sell_sheep_batch":
            try require(.recordProduction, agent: agent)
            return try sellSheepBatchDrafts(arguments, agent: agent, context: context)
        case "draft_add_note":
            try require(.recordProduction, agent: agent)
            return try addNoteDraft(arguments, agent: agent, context: context)
        case "draft_transfer_sheep":
            try require(.recordProduction, agent: agent)
            return try transferDraft(arguments, agent: agent, context: context)
        case "draft_reminder":
            return try reminderDraft(arguments, agent: agent)
        case "draft_calendar_event":
            return try calendarDraft(arguments, agent: agent)
        default:
            throw InsightToolError.unknownTool
        }
    }

    func extendedDataDisclosure(
        for call: InsightFunctionCall,
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightExtendedDataDisclosure? {
        guard call.name == "get_extended_farm_records" else { return nil }
        try require(.viewAnalytics, agent: agent)
        let arguments = try Self.arguments(call.argumentsJSON)
        let category = try Self.nonempty(arguments, "category")
        let from = try Self.date(arguments, "from")
        let to = try Self.date(arguments, "to")
        let limit = try Self.integer(arguments, "limit", range: 1...Self.maximumRows)
        guard to >= from else { throw InsightToolError.invalidArguments("to") }
        let output = try extendedFarmRecords(
            arguments,
            farmID: agent.farmID,
            context: context
        )
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let rowCount = object?["row_count"] as? Int ?? limit
        return InsightExtendedDataDisclosure(
            id: call.callID,
            category: Self.extendedCategoryName(category),
            dateRange: "\(from.formatted(date: .abbreviated, time: .shortened)) – \(to.formatted(date: .abbreviated, time: .shortened))",
            rowCount: rowCount,
            estimatedBytes: output.utf8.count
        )
    }

    func farmCommand(for draft: InsightActionDraftRecord) throws -> FarmCommand {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch draft.toolName {
        case "draft_record_weaning":
            let value = try decoder.decode(RecordWeaningToolPayload.self, from: draft.argumentsJSON)
            return .recordWeaning(
                sheepID: value.sheepID,
                weanWeightText: value.weanWeightText,
                occurredAt: value.occurredAt,
                birthAt: nil,
                birthWeightText: nil,
                averageDailyGainText: nil,
                damID: nil,
                litterSize: nil,
                note: value.note
            )
        case "draft_record_weight":
            let value = try decoder.decode(RecordWeightToolPayload.self, from: draft.argumentsJSON)
            return .recordWeight(
                sheepID: value.sheepID,
                kilogramsText: value.kilogramsText,
                occurredAt: value.occurredAt,
                note: value.note
            )
        case "draft_add_note":
            let value = try decoder.decode(AddNoteToolPayload.self, from: draft.argumentsJSON)
            return .addNote(
                sheepID: value.sheepID,
                penID: value.penID,
                text: value.text,
                occurredAt: value.occurredAt
            )
        case "draft_transfer_sheep":
            let value = try decoder.decode(TransferSheepToolPayload.self, from: draft.argumentsJSON)
            return .transferSheep(
                sheepID: value.sheepID,
                toPenID: value.toPenID,
                occurredAt: value.occurredAt,
                note: value.note
            )
        case "draft_farm_command":
            let value = try decoder.decode(
                CanonicalFarmCommandToolPayload.self,
                from: draft.argumentsJSON
            )
            return try FarmCommandCloudPayloadDecoder.decode(value.commandPayload)
        default:
            throw InsightToolError.unknownTool
        }
    }

    /// Most action cards map to one authoritative command. A weaning card maps
    /// to the weaning fact plus its required pen transfer so the controller can
    /// commit both operations atomically while still presenting one card.
    func farmCommands(for draft: InsightActionDraftRecord) throws -> [FarmCommand] {
        guard draft.toolName == "draft_record_weaning" else {
            return [try farmCommand(for: draft)]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(RecordWeaningToolPayload.self, from: draft.argumentsJSON)
        return WeaningWorkflow.commands(
            sheepID: value.sheepID,
            weanWeightText: value.weanWeightText,
            occurredAt: value.occurredAt,
            birthAt: nil,
            toPenID: value.toPenID,
            note: value.note
        )
    }

    func removalBatchID(for draft: InsightActionDraftRecord) -> UUID? {
        guard let command = try? farmCommand(for: draft),
              case .removeSheep(
            _, _, _, _, _, _, _, let removalBatchID, _
        ) = command else {
            return nil
        }
        return removalBatchID
    }

    func editablePayloadText(for draft: InsightActionDraftRecord) throws -> String {
        let data: Data
        if draft.toolName == "draft_farm_command" {
            data = try JSONDecoder().decode(
                CanonicalFarmCommandToolPayload.self,
                from: draft.argumentsJSON
            ).commandPayload
        } else {
            data = draft.argumentsJSON
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: pretty, as: UTF8.self)
    }

    func occurredAt(for draft: InsightActionDraftRecord) -> Date? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch draft.toolName {
        case "draft_record_weaning":
            return try? decoder.decode(
                RecordWeaningToolPayload.self,
                from: draft.argumentsJSON
            ).occurredAt
        case "draft_record_weight":
            return try? decoder.decode(
                RecordWeightToolPayload.self,
                from: draft.argumentsJSON
            ).occurredAt
        case "draft_add_note":
            return try? decoder.decode(
                AddNoteToolPayload.self,
                from: draft.argumentsJSON
            ).occurredAt
        case "draft_transfer_sheep":
            return try? decoder.decode(
                TransferSheepToolPayload.self,
                from: draft.argumentsJSON
            ).occurredAt
        case "draft_calendar_event":
            return try? decoder.decode(
                InsightCalendarEventDraft.self,
                from: draft.argumentsJSON
            ).startAt
        case "draft_reminder":
            return try? decoder.decode(
                InsightReminderDraft.self,
                from: draft.argumentsJSON
            ).dueAt
        default:
            return nil
        }
    }

    func updateDraftPayload(
        _ text: String,
        for draft: InsightActionDraftRecord
    ) throws {
        guard let data = text.data(using: .utf8), data.count <= 32 * 1_024 else {
            throw InsightToolError.invalidArguments("草案字段")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        switch draft.toolName {
        case "draft_farm_command":
            let oldCommand = try farmCommand(for: draft)
            let payload = try Self.decodeCanonicalPayload(data)
            let newCommand = try FarmCommandCloudPayloadDecoder.decode(payload)
            guard newCommand.operationKind == oldCommand.operationKind,
                  newCommand.requiredCapability == oldCommand.requiredCapability,
                  Self.risk(for: newCommand) == Self.risk(for: oldCommand) else {
                throw InsightToolError.permissionDenied
            }
            draft.argumentsJSON = try encoder.encode(CanonicalFarmCommandToolPayload(
                commandPayload: Self.encodeCanonicalPayload(payload)
            ))
            draft.title = newCommand.summary
            draft.summary = newCommand.summary
        case "draft_record_weaning":
            let oldValue = try decodeEdited(
                RecordWeaningToolPayload.self,
                from: draft.argumentsJSON
            )
            let value = try decodeEdited(RecordWeaningToolPayload.self, from: data)
            guard value.sheepID == oldValue.sheepID,
                  value.toPenID == oldValue.toPenID,
                  EarTag.normalized(value.earTag) == EarTag.normalized(oldValue.earTag),
                  value.penName.trimmingCharacters(in: .whitespacesAndNewlines)
                      .localizedCaseInsensitiveCompare(
                          oldValue.penName.trimmingCharacters(in: .whitespacesAndNewlines)
                      ) == .orderedSame else {
                throw InsightToolError.permissionDenied
            }
            draft.argumentsJSON = try encoder.encode(value)
            draft.summary = "\(value.earTag) · \(value.weanWeightText) kg · 调入 \(value.penName)"
        case "draft_record_weight":
            let value = try decodeEdited(RecordWeightToolPayload.self, from: data)
            draft.argumentsJSON = try encoder.encode(value)
            draft.summary = "\(value.earTag) · \(value.kilogramsText) kg"
        case "draft_add_note":
            let value = try decodeEdited(AddNoteToolPayload.self, from: data)
            draft.argumentsJSON = try encoder.encode(value)
            draft.summary = "\(value.subject) · \(value.text)"
        case "draft_transfer_sheep":
            let value = try decodeEdited(TransferSheepToolPayload.self, from: data)
            draft.argumentsJSON = try encoder.encode(value)
            draft.summary = "\(value.earTag) → \(value.penName)"
        case "draft_reminder":
            let value = try decodeEdited(InsightReminderDraft.self, from: data)
            draft.argumentsJSON = try encoder.encode(value)
            draft.summary = value.dueAt.map {
                "\(value.title) · \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? value.title
        case "draft_calendar_event":
            let value = try decodeEdited(InsightCalendarEventDraft.self, from: data)
            guard value.endAt > value.startAt else {
                throw InsightToolError.invalidArguments("endAt")
            }
            draft.argumentsJSON = try encoder.encode(value)
            draft.summary = "\(value.title) · \(value.startAt.formatted(date: .abbreviated, time: .shortened))"
        default:
            throw InsightToolError.unknownTool
        }
        draft.updatedAt = .now
    }

    func validate(
        _ draft: InsightActionDraftRecord,
        agent: InsightAgentContext,
        context: ModelContext
    ) throws {
        try validate(draft, agent: agent, context: context, snapshot: nil)
    }

    /// Validates a user-confirmed group against one consistent farm snapshot.
    /// The previous per-draft path reloaded every farm entity table for every
    /// card, turning a 121-item confirmation into thousands of main-thread
    /// SwiftData fetches. Security checks remain per draft; only the immutable
    /// lookup snapshot is shared by the batch.
    func validate(
        _ drafts: [InsightActionDraftRecord],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws {
        guard !drafts.isEmpty else { return }
        let expectedEntityIDs = Set(drafts.compactMap { draft -> UUID? in
            guard draft.expectedRevision != nil else { return nil }
            return draft.expectedEntityID
        })
        let removalReferenceIDs = try canonicalRemovalReferenceIDs(for: drafts)
        let revisionsByEntityID = try entityRevisions(
            ids: expectedEntityIDs,
            farmID: agent.farmID,
            context: context
        )
        let snapshot = FarmValidationSnapshot(
            knownEntityIDs: removalReferenceIDs == nil
                ? (drafts.contains(where: { $0.toolName == "draft_farm_command" })
                    ? try knownFarmEntityIDs(farmID: agent.farmID, context: context)
                    : [])
                : Set(revisionsByEntityID.keys),
            revisionsByEntityID: revisionsByEntityID
        )
        for draft in drafts {
            try validate(draft, agent: agent, context: context, snapshot: snapshot)
        }
    }

    private func validate(
        _ draft: InsightActionDraftRecord,
        agent: InsightAgentContext,
        context: ModelContext,
        snapshot: FarmValidationSnapshot?
    ) throws {
        guard draft.accountID == agent.accountID, draft.farmID == agent.farmID else {
            throw InsightToolError.crossFarmReference
        }
        let expectedPolicy = try policy(for: draft)
        guard draft.requiredCapability == expectedPolicy.capability,
              draft.risk == expectedPolicy.risk else {
            throw InsightToolError.permissionDenied
        }
        try require(expectedPolicy.capability, agent: agent)
        if draft.toolName == "draft_farm_command" {
            let command = try farmCommand(for: draft)
            guard command.requiredCapability == draft.requiredCapability else {
                throw InsightToolError.permissionDenied
            }
            let value = try JSONDecoder().decode(
                CanonicalFarmCommandToolPayload.self,
                from: draft.argumentsJSON
            )
            let payload = try Self.decodeCanonicalPayload(value.commandPayload)
            try validateReferences(
                payload: payload,
                command: command,
                farmID: agent.farmID,
                context: context,
                knownEntityIDs: snapshot?.knownEntityIDs
            )
        } else if draft.toolName == "draft_record_weaning" {
            try validateWeaningDraft(draft, farmID: agent.farmID, context: context)
        }
        guard let expectedEntityID = draft.expectedEntityID,
              let expectedRevision = draft.expectedRevision else { return }

        let currentRevision: Int?
        if let snapshot {
            currentRevision = snapshot.revisionsByEntityID[expectedEntityID]
        } else {
            currentRevision = try entityRevision(
                id: expectedEntityID,
                farmID: agent.farmID,
                context: context
            )
        }
        if let currentRevision {
            guard currentRevision == expectedRevision else {
                throw InsightToolError.staleRevision
            }
            return
        }
        throw InsightToolError.crossFarmReference
    }

    /// A generated removal draft references only its sheep; the shared batch
    /// revision snapshot already proves that sheep belongs to this farm. This
    /// avoids loading every unrelated entity table before a large sale while
    /// retaining the same cross-farm and stale-revision rejection behavior.
    private func canonicalRemovalReferenceIDs(
        for drafts: [InsightActionDraftRecord]
    ) throws -> Set<UUID>? {
        var result: Set<UUID> = []
        for draft in drafts {
            guard draft.toolName == "draft_farm_command",
                  draft.expectedRevision != nil,
                  let expectedEntityID = draft.expectedEntityID,
                  case .removeSheep(let sheepID, _, _, _, _, _, _, _, _) = try farmCommand(for: draft),
                  sheepID == expectedEntityID else {
                return nil
            }
            result.insert(sheepID)
        }
        return result
    }

    private func policy(
        for draft: InsightActionDraftRecord
    ) throws -> (capability: FarmCapability, risk: InsightActionRisk) {
        switch draft.toolName {
        case "draft_record_weaning", "draft_record_weight", "draft_add_note", "draft_transfer_sheep":
            return (.recordProduction, .normal)
        case InsightImportCoordinator.toolName:
            return (.recordProduction, .high)
        case "draft_reminder", "draft_calendar_event":
            return (.readFarm, .normal)
        case "draft_farm_command":
            let command = try farmCommand(for: draft)
            if case .recordWeaning = command {
                throw InsightToolError.obsoleteWeaningDraft
            }
            return (command.requiredCapability, Self.risk(for: command))
        default:
            throw InsightToolError.unknownTool
        }
    }

    private func canonicalFarmCommandDraft(
        _ arguments: [String: Any],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        let operationText = try Self.nonempty(arguments, "operation_kind")
        guard let operationKind = DomainOperationKind(rawValue: operationText),
              Self.aiFarmOperationKinds.contains(operationKind) else {
            throw InsightToolError.invalidArguments("operation_kind")
        }
        let payloadText = try Self.nonempty(arguments, "payload_json")
        guard let payloadData = payloadText.data(using: .utf8),
              payloadData.count <= 32 * 1_024 else {
            throw InsightToolError.invalidArguments("payload_json")
        }
        let payload = try Self.decodeCanonicalPayload(payloadData)
        guard payload.kind == operationKind else {
            throw InsightToolError.invalidArguments("operation_kind")
        }
        let canonicalData = try Self.encodeCanonicalPayload(payload)
        let command = try FarmCommandCloudPayloadDecoder.decode(payload)
        try require(command.requiredCapability, agent: agent)
        return try canonicalFarmCommandProposal(
            command: command,
            canonicalData: canonicalData,
            payload: payload,
            agent: agent,
            context: context
        )
    }

    private func canonicalFarmCommandProposal(
        command: FarmCommand,
        canonicalData: Data,
        payload: FarmCommandCloudPayload,
        summary: String? = nil,
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        try validateReferences(
            payload: payload,
            command: command,
            farmID: agent.farmID,
            context: context
        )
        let primary = try primaryRevision(
            in: payload,
            farmID: agent.farmID,
            context: context
        )
        let draft = try makeDraft(
            toolName: "draft_farm_command",
            title: command.summary,
            summary: summary ?? command.summary,
            payload: CanonicalFarmCommandToolPayload(commandPayload: canonicalData),
            risk: Self.risk(for: command),
            capability: command.requiredCapability,
            expectedEntityID: primary?.id,
            expectedRevision: primary?.revision,
            agent: agent
        )
        return proposalOutput(draft)
    }

    private func actionSchema(operationKind text: String) throws -> String {
        guard let kind = DomainOperationKind(rawValue: text),
              Self.aiFarmOperationKinds.contains(kind) else {
            throw InsightToolError.invalidArguments("operation_kind")
        }
        return try boundedJSON([
            "operation_kind": kind.rawValue,
            "required_capability": kind == .care
                ? "derived_per_care_case"
                : Self.capability(for: kind).rawValue,
            "risk": kind == .care
                ? "derived_per_care_case"
                : Self.risk(for: kind).rawValue,
            "payload_root": [
                "kind": kind.rawValue,
                "strings": Self.requiredStringFields[kind] ?? [],
                "optionalStrings": Self.optionalStringFields[kind] ?? [],
                "identifiers": Self.requiredIdentifierFields[kind] ?? [],
                "optionalIdentifiers": Self.optionalIdentifierFields[kind] ?? [],
                "dates": Self.requiredDateFields[kind] ?? [],
                "optionalDates": Self.optionalDateFields[kind] ?? [],
                "integers": Self.integerFields[kind] ?? [],
                "feedLines": kind == .recordFeed ? ["id", "ingredientID", "kilogramsText", "ingredientBatchID"] : [],
                "breedingProgramSteps": kind == .createBreedingProgram ? ["id", "dayOffset", "action", "sortOrder"] : [],
                "lambingOffspring": kind == .recordReproduction ? ["id", "sheepID", "earTag", "sexRawValue", "birthWeightText"] : [],
                "careCommand": kind == .care ? Self.careCommandActionSchema : [:],
            ],
            "rules": [
                "Include empty objects or arrays for unused payload root fields.",
                "Dates use ISO 8601.",
                "All referenced UUIDs must come from current-farm read tools.",
                "The App derives capability, risk, confirmation count and command mapping.",
            ],
        ])
    }

    /// `CareCommand` is a synthesized Codable enum. Returning its exact wire
    /// shape on demand lets the model construct any authorized care command
    /// without exposing a broad free-form decoder or trusting model-declared
    /// capability/risk values.
    private static var careCommandActionSchema: [String: Any] {
        [
            "encoding": [
                "root": "Object containing exactly one case name.",
                "single_unlabeled_value": "Use key _0 for the nested draft or snapshot.",
                "date": "ISO 8601 string",
                "uuid": "Lowercase UUID string obtained from current-farm tools, or a newly generated UUID only for a new record.",
                "optional": "Use null when absent.",
            ],
            "enum_values": [
                "HealthRecordKind": ["treatment", "vaccination"],
                "ReproductionRecordKind": ["breeding", "pregnancyCheck", "lambing", "abortion"],
                "SheepSex": ["ewe", "ram", "unknown"],
                "SemenDonorStatus": ["active", "inactive"],
                "CareReminderStatus": ["pending", "completed", "dismissed"],
            ],
            "policies": [
                "manageCatalogs_high": [
                    "upsertHealthCatalog", "receiveInventory", "adjustInventory",
                    "setInventoryLotActive", "adjustSemen", "upsertSemenDonor",
                    "setSemenDonor", "updateRules",
                ],
                "editHistoricalFacts_high": [
                    "correctHealth", "updateSheepPedigree",
                    "restorePedigreeAudit", "correctReproduction", "correctLambing",
                    "revokeLambing", "restoreLambing",
                ],
                "recordProduction_high": ["recordReproductionBatch", "recordLambing"],
                "recordProduction_normal": ["recordHealth", "setReminderStatus"],
            ],
            "cases": [
                "upsertHealthCatalog": [
                    "id", "kindRawValue", "name", "category", "unit", "defaultDoseText?",
                    "defaultRoute", "reminderIntervalDays?", "note", "isActive",
                ],
                "recordHealth": ["_0:CareHealthDraft"],
                "correctHealth": ["originalID", "replacement:CareHealthDraft", "reason"],
                "receiveInventory": [
                    "id", "catalogName", "catalogItemID?", "kindRawValue", "batchNumber",
                    "supplier", "unit", "expiresAt?", "quantityText", "occurredAt", "note",
                ],
                "adjustInventory": ["id", "lotID", "quantityDeltaText", "occurredAt", "note"],
                "setInventoryLotActive": ["lotID", "isActive"],
                "adjustSemen": ["id", "semenID", "quantityDeltaText", "occurredAt", "note"],
                "upsertSemenDonor": ["_0:CareSemenDonorDraft"],
                "setSemenDonor": ["semenID", "donorID?", "expectedRevision"],
                "updateSheepPedigree": ["_0:CarePedigreeUpdateDraft"],
                "restorePedigreeAudit": ["_0:CarePedigreeAuditSnapshot"],
                "recordReproductionBatch": ["_0:CareReproductionBatchDraft"],
                "recordLambing": ["_0:CareLambingDraft"],
                "correctReproduction": ["originalID", "replacement:CareReproductionBatchDraft", "reason"],
                "correctLambing": ["originalID", "replacement:CareLambingDraft", "reason"],
                "revokeLambing": ["recordID", "reason"],
                "restoreLambing": ["recordID"],
                "updateRules": ["id", "pregnancyCheckDays", "gestationDays"],
                "setReminderStatus": ["reminderID", "status"],
            ],
            "nested_types": [
                "CareHealthDraft": [
                    "id", "batchID", "subjectIDs[]", "penID?", "catalogItemID?", "kind",
                    "itemName", "occurredAt", "note", "inventoryLotID?", "dosePerSubjectText?",
                    "unit", "route", "reminderAt?",
                ],
                "CareSemenDonorDraft": [
                    "id", "name", "registrationNumber", "breed", "linkedRamID?", "note",
                    "status", "expectedRevision",
                ],
                "CarePedigreeUpdateDraft": [
                    "id", "sheepID", "damID?", "sireID?", "semenDonorID?", "reason",
                    "expectedRevision",
                ],
                "CarePedigreeAuditSnapshot": [
                    "id", "sheepID", "beforeDamID?", "afterDamID?", "beforeSireID?",
                    "afterSireID?", "beforeSemenDonorID?", "afterSemenDonorID?",
                    "beforeDamSourceRawValue?", "afterDamSourceRawValue?",
                    "beforeSireSourceRawValue?", "afterSireSourceRawValue?", "reason",
                    "changedByAccountID", "sheepRevision", "occurredAt",
                ],
                "CareReproductionBatchDraft": [
                    "id", "kind", "subjects[]:CareReproductionSubjectDraft", "occurredAt",
                    "sireID?", "semenID?", "semenUnitsPerEweText?", "note", "reminderAt?",
                ],
                "CareReproductionSubjectDraft": [
                    "id", "eweID", "result", "relatedBreedingRecordID?",
                ],
                "CareLambingDraft": [
                    "id", "eweID", "occurredAt", "sireID?", "semenID?",
                    "relatedBreedingRecordID?", "parity", "birthDeadCount",
                    "offspring[]:CareLambDraft", "penID?", "note",
                ],
                "CareLambDraft": [
                    "id", "sheepID", "earTag", "breed?", "sex", "birthWeightText",
                    "createSheepRecord", "isStillborn",
                ],
            ],
        ]
    }

    private func farmEntities(
        category: String,
        query: String,
        limit: Int,
        farmID: UUID,
        context: ModelContext
    ) throws -> String {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ values: String...) -> Bool {
            normalizedQuery.isEmpty || values.contains {
                $0.localizedCaseInsensitiveContains(normalizedQuery)
            }
        }
        let rows: [[String: Any]]
        switch category {
        case "pens":
            rows = try context.fetch(FetchDescriptor<PenRecord>())
                .filter {
                    $0.farmID == farmID && $0.deletedAt == nil && matches($0.name, $0.note)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "name": $0.name,
                        "is_active": $0.isActive,
                        "revision": $0.revision,
                    ]
                }
        case "production_batches":
            rows = try context.fetch(FetchDescriptor<ProductionBatchRecord>())
                .filter {
                    $0.farmID == farmID && $0.deletedAt == nil
                        && matches($0.name, $0.purpose, $0.statusRawValue)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "name": $0.name,
                        "purpose": $0.purpose,
                        "status": $0.statusRawValue,
                    ]
                }
        case "ingredients":
            rows = try context.fetch(FetchDescriptor<FeedIngredientRecord>())
                .filter {
                    $0.farmID == farmID && $0.deletedAt == nil
                        && matches($0.name, $0.category, $0.unit)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "name": $0.name,
                        "category": $0.category,
                        "unit": $0.unit,
                        "is_active": $0.isActive,
                    ]
                }
        case "recipes":
            rows = try context.fetch(FetchDescriptor<FeedRecipeRecord>())
                .filter {
                    $0.farmID == farmID && $0.deletedAt == nil
                        && matches($0.name, $0.note)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "name": $0.name,
                        "is_active": $0.isActive,
                    ]
                }
        case "health_catalog":
            rows = try context.fetch(FetchDescriptor<HealthCatalogItemRecord>())
                .filter {
                    $0.farmID == farmID
                        && matches($0.name, $0.category, $0.kindRawValue, $0.unit)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "name": $0.name,
                        "category": $0.category,
                        "kind": $0.kindRawValue,
                        "unit": $0.unit,
                        "route": $0.defaultRoute,
                        "is_active": $0.isActive,
                    ]
                }
        case "inventory_lots":
            rows = try context.fetch(FetchDescriptor<InventoryLotRecord>())
                .filter {
                    $0.farmID == farmID && $0.deletedAt == nil
                        && matches($0.catalogName, $0.batchNumber, $0.supplier)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "catalog_name": $0.catalogName,
                        "batch_number": $0.batchNumber,
                        "supplier": $0.supplier,
                        "unit": $0.unit,
                        "kind": $0.kindRawValue,
                        "is_active": $0.isActive,
                    ]
                }
        case "semen":
            rows = try context.fetch(FetchDescriptor<SemenRecord>())
                .filter {
                    $0.farmID == farmID && $0.deletedAt == nil
                        && matches($0.code, $0.breed, $0.batchNumber, $0.source)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "code": $0.code,
                        "breed": $0.breed,
                        "batch_number": $0.batchNumber,
                        "quantity": $0.quantityText,
                        "revision": $0.revision,
                    ]
                }
        case "semen_donors":
            rows = try context.fetch(FetchDescriptor<SemenDonorRecord>())
                .filter {
                    $0.farmID == farmID && $0.deletedAt == nil
                        && matches($0.name, $0.registrationNumber, $0.breed)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "name": $0.name,
                        "registration_number": $0.registrationNumber,
                        "breed": $0.breed,
                        "status": $0.statusRawValue,
                        "revision": $0.revision,
                    ]
                }
        case "reminders":
            rows = try context.fetch(FetchDescriptor<CareReminderRecord>())
                .filter {
                    $0.farmID == farmID && $0.deletedAt == nil
                        && matches($0.title, $0.kindRawValue, $0.statusRawValue)
                }
                .prefix(limit)
                .map {
                    [
                        "id": $0.id.uuidString.lowercased(),
                        "title": $0.title,
                        "kind": $0.kindRawValue,
                        "status": $0.statusRawValue,
                        "due_at": ISO8601DateFormatter().string(from: $0.dueAt),
                        "revision": $0.revision,
                    ]
                }
        default:
            throw InsightToolError.invalidArguments("category")
        }
        return try boundedJSON([
            "category": category,
            "query": normalizedQuery,
            "returned_count": rows.count,
            "rows": rows,
            "farm_scoped": true,
        ])
    }

    private func createFarmExport(
        format: String,
        agent: InsightAgentContext,
        farmID: UUID,
        context: ModelContext
    ) throws -> InsightToolExecution {
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: {
            $0.id == farmID && $0.deletedAt == nil
        }) else {
            throw InsightToolError.crossFarmReference
        }
        let day = Date.now.formatted(.iso8601.year().month().day())
        let safeFarmName = farm.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let generatedFile: InsightGeneratedFile
        switch format {
        case "xlsx":
            try require(.exportFarm, agent: agent)
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            let pens = try context.fetch(FetchDescriptor<PenRecord>())
            generatedFile = InsightGeneratedFile(
                fileName: "牧场档案_\(safeFarmName)_\(day).xlsx",
                kind: .xlsx,
                data: try FarmDataInterchange.xlsxData(
                    farmID: farmID,
                    sheep: sheep,
                    pens: pens
                )
            )
        case "backup":
            try require(.exportFarm, agent: agent)
            let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>())
                .first(where: { $0.farmID == farmID })
            let storageMode = profile?.mode ?? .localOnly
            if let provider = storageMode.deliveryProvider {
                let hasPendingCloudOperations = try context.fetch(
                    FetchDescriptor<OutboxItem>()
                ).contains {
                    $0.farmID == farmID &&
                        $0.deliveryProvider == provider &&
                        !$0.status.isTerminalDelivery
                }
                guard !hasPendingCloudOperations else {
                    throw InsightToolError.deviceActionUnavailable(
                        "牧场仍有记录等待上传。请联网同步完成后再生成完整备份。"
                    )
                }
            }
            generatedFile = InsightGeneratedFile(
                fileName: "牧场完整备份_\(safeFarmName)_\(day).esheep-backup",
                kind: .json,
                data: try FarmPortableBackupService.export(
                    farmID: farmID,
                    sourceStorageMode: storageMode,
                    sourceAuthorityGeneration: profile?.authorityGeneration ?? 0,
                    sourceWasFullySynchronized: true,
                    context: context
                )
            )
        case "template":
            try require(.recordProduction, agent: agent)
            generatedFile = InsightGeneratedFile(
                fileName: "eSheepNext全功能录入模板_v\(FarmExcelImportService.templateVersion).xlsx",
                kind: .xlsx,
                data: try FarmExcelImportService.templateData()
            )
        default:
            throw InsightToolError.invalidArguments("format")
        }
        return InsightToolExecution(
            output: try boundedJSON([
                "status": "file_generated",
                "file_name": generatedFile.fileName,
                "byte_count": generatedFile.data.count,
                "requires_save_destination": true,
                "executed": true,
            ]),
            generatedFile: generatedFile
        )
    }

    private func farmOverview(farmID: UUID, context: ModelContext) throws -> String {
        let today = Calendar.current.startOfDay(for: .now)
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.status == .active
        }
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.isActive
        }
        let feeds = try context.fetch(FetchDescriptor<FeedRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt >= today
        }
        let health = try context.fetch(FetchDescriptor<HealthRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt >= sevenDaysAgo
        }
        return try boundedJSON([
            "active_sheep_count": sheep.count,
            "active_pen_count": pens.count,
            "today_feed_count": feeds.count,
            "health_record_count_last_7_days": health.count,
            "scope": "current_farm_only",
        ])
    }

    private func findSheep(query: String, farmID: UUID, context: ModelContext) throws -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw InsightToolError.invalidArguments("query") }
        let normalizedKey = normalized.lowercased()
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let transfersBySheep = Dictionary(grouping: transfers, by: \.sheepID)
        let removalsBySheep = Dictionary(grouping: removals, by: \.sheepID)
        let values = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil &&
                ($0.earTag.localizedCaseInsensitiveContains(normalized)
                    || $0.breed.localizedCaseInsensitiveContains(normalized))
        }.sorted { lhs, rhs in
            let lhsExact = lhs.earTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedKey
            let rhsExact = rhs.earTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedKey
            if lhsExact != rhsExact { return lhsExact }
            if lhs.earTag != rhs.earTag {
                return lhs.earTag.localizedStandardCompare(rhs.earTag) == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let now = Date.now
        let result: [[String: Any]] = values.prefix(20).map { sheep in
            let fact = FarmSheepStateResolver.resolve(
                sheep,
                cutoff: .current(now),
                transfers: transfersBySheep[sheep.id] ?? [],
                removals: removalsBySheep[sheep.id] ?? []
            )
            return [
                "id": sheep.id.uuidString.lowercased(),
                "ear_tag": sheep.earTag,
                "breed": sheep.breed,
                "sex": sheep.sex.rawValue,
                "birth_at": sheep.birthAt.map(Self.iso8601) ?? NSNull(),
                "entered_at": Self.iso8601(sheep.enteredAt),
                "status": fact.status?.rawValue ?? "unknown",
                "currently_present": fact.isPresent,
                "pen": fact.penID.flatMap { penNames[$0] } ?? "未分圈",
                "state_basis": fact.basis.rawValue,
                "projection_matches_stored_state": fact.projectionMatchesStoredState,
                "revision": sheep.revision,
            ]
        }
        return try boundedJSON([
            "rows": result,
            "row_count": result.count,
            "truncated": values.count > result.count,
            "contract_version": FarmFactContract.version,
            "queried_at": Self.iso8601(now),
            "scope": "current_farm_only",
        ])
    }

    private func matchSheepEarTags(
        _ earTags: [String],
        farmID: UUID,
        context: ModelContext
    ) throws -> String {
        let index = try sheepEarTagIndex(farmID: farmID, context: context)
        var matchedRows: [[String: Any]] = []
        var canonicalEarTags: [String] = []
        var unmatchedEarTags: [String] = []
        var ambiguousRows: [[String: Any]] = []
        var duplicateInputEarTags: [String] = []
        var seenSheepIDs = Set<UUID>()

        for earTag in earTags {
            switch resolveSheepEarTag(earTag, index: index) {
            case .matched(let sheep, let matchKind):
                guard seenSheepIDs.insert(sheep.id).inserted else {
                    duplicateInputEarTags.append(earTag)
                    continue
                }
                canonicalEarTags.append(sheep.earTag)
                matchedRows.append([
                    "input_ear_tag": earTag,
                    "canonical_ear_tag": sheep.earTag,
                    "id": sheep.id.uuidString.lowercased(),
                    "match_kind": matchKind,
                    "status": sheep.status.rawValue,
                    "currently_present": sheep.isCurrentlyPresent,
                ])
            case .ambiguous(let matches):
                ambiguousRows.append([
                    "input_ear_tag": earTag,
                    "candidates": matches.prefix(5).map {
                        [
                            "canonical_ear_tag": $0.earTag,
                            "status": $0.status.rawValue,
                            "currently_present": $0.isCurrentlyPresent,
                        ] as [String: Any]
                    },
                ])
            case .notFound:
                unmatchedEarTags.append(earTag)
            }
        }

        let needsReview = !unmatchedEarTags.isEmpty ||
            !ambiguousRows.isEmpty ||
            !duplicateInputEarTags.isEmpty
        return try boundedJSON([
            "status": needsReview ? "needs_review" : "all_matched",
            "input_count": earTags.count,
            "matched_count": canonicalEarTags.count,
            "unmatched_count": unmatchedEarTags.count,
            "ambiguous_count": ambiguousRows.count,
            "duplicate_input_count": duplicateInputEarTags.count,
            "canonical_ear_tags": canonicalEarTags,
            "matches": matchedRows,
            "unmatched_ear_tags": unmatchedEarTags,
            "ambiguous_matches": ambiguousRows,
            "duplicate_input_ear_tags": duplicateInputEarTags,
            "scope": "current_farm_only",
        ])
    }

    private func extendedFarmRecords(
        _ arguments: [String: Any],
        farmID: UUID,
        context: ModelContext
    ) throws -> String {
        let category = try Self.nonempty(arguments, "category")
        let from = try Self.date(arguments, "from")
        let to = try Self.date(arguments, "to")
        let limit = try Self.integer(arguments, "limit", range: 1...Self.maximumRows)
        guard to >= from else { throw InsightToolError.invalidArguments("to") }
        let rows: [[String: Any]]
        let totalCount: Int
        switch category {
        case "raw_notes":
            let values = try context.fetch(FetchDescriptor<NoteRecord>()).filter {
                $0.farmID == farmID &&
                    $0.deletedAt == nil &&
                    $0.occurredAt >= from &&
                    $0.occurredAt <= to
            }.sorted { $0.occurredAt > $1.occurredAt }
            totalCount = values.count
            rows = values.prefix(limit).map {
                [
                    "id": $0.id.uuidString.lowercased(),
                    "sheep_id": $0.sheepID?.uuidString.lowercased() ?? NSNull(),
                    "pen_id": $0.penID?.uuidString.lowercased() ?? NSNull(),
                    "occurred_at": Self.iso8601($0.occurredAt),
                    "text": $0.text,
                    "revision": $0.revision,
                ]
            }
        case "health":
            let values = try context.fetch(FetchDescriptor<HealthRecord>()).filter {
                $0.farmID == farmID &&
                    $0.deletedAt == nil &&
                    $0.occurredAt >= from &&
                    $0.occurredAt <= to
            }.sorted { $0.occurredAt > $1.occurredAt }
            totalCount = values.count
            rows = values.prefix(limit).map {
                [
                    "id": $0.id.uuidString.lowercased(),
                    "sheep_id": $0.sheepID?.uuidString.lowercased() ?? NSNull(),
                    "pen_id": $0.penID?.uuidString.lowercased() ?? NSNull(),
                    "kind": $0.kindRawValue,
                    "item": $0.itemNameSnapshot,
                    "occurred_at": Self.iso8601($0.occurredAt),
                    "quantity": $0.quantityText ?? NSNull(),
                    "unit": $0.unit,
                    "route": $0.route,
                    "note": $0.note,
                ]
            }
        case "reproduction":
            let values = try context.fetch(FetchDescriptor<ReproductionRecord>()).filter {
                $0.farmID == farmID &&
                    $0.deletedAt == nil &&
                    $0.occurredAt >= from &&
                    $0.occurredAt <= to
            }.sorted { $0.occurredAt > $1.occurredAt }
            totalCount = values.count
            rows = values.prefix(limit).map {
                [
                    "id": $0.id.uuidString.lowercased(),
                    "ewe_id": $0.eweID.uuidString.lowercased(),
                    "sire_id": $0.sireID?.uuidString.lowercased() ?? NSNull(),
                    "semen_id": $0.semenID?.uuidString.lowercased() ?? NSNull(),
                    "kind": $0.kindRawValue,
                    "occurred_at": Self.iso8601($0.occurredAt),
                    "result": $0.result,
                    "lamb_count": $0.lambCount,
                    "parity": $0.parity ?? NSNull(),
                    "birth_dead_count": $0.birthDeadCount ?? NSNull(),
                    "note": $0.note,
                    "revision": $0.revision,
                ]
            }
        default:
            throw InsightToolError.invalidArguments("category")
        }
        return try boundedJSON([
            "category": category,
            "from": Self.iso8601(from),
            "to": Self.iso8601(to),
            "rows": rows,
            "row_count": rows.count,
            "total_matching_count": totalCount,
            "truncated": totalCount > rows.count,
            "scope": "current_farm_only",
            "authorization": "granted_for_this_call",
        ])
    }

    private func analyzeFarm(
        focus: String,
        year: String,
        farmID: UUID,
        context: ModelContext
    ) throws -> String {
        let selectedYear: String?
        if year.isEmpty {
            selectedYear = nil
        } else {
            guard year.count == 4, Int(year) != nil else {
                throw InsightToolError.invalidArguments("year")
            }
            selectedYear = year
        }
        let snapshot = try analyticsSnapshot(farmID: farmID, context: context)
        switch focus.lowercased() {
        case "population":
            let active = snapshot.sheep.filter { $0.status == .active }
            let penNames = Dictionary(uniqueKeysWithValues: snapshot.pens.map { ($0.id, $0.name) })
            let byPen = Dictionary(grouping: active, by: {
                $0.currentPenID.flatMap { penNames[$0] } ?? "未分圈"
            })
            let byBreed = Dictionary(grouping: active, by: {
                $0.breed.isEmpty ? "未填写" : $0.breed
            })
            return try boundedJSON([
                "focus": "population",
                "active_count": active.count,
                "ewe_count": active.count(where: { $0.sex == .ewe }),
                "ram_count": active.count(where: { $0.sex == .ram }),
                "by_pen": byPen.map { ["name": $0.key, "count": $0.value.count] }
                    .sorted { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }
                    .prefix(50)
                    .map { $0 },
                "by_breed": byBreed.map { ["name": $0.key, "count": $0.value.count] }
                    .sorted { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }
                    .prefix(50)
                    .map { $0 },
            ])
        case "weight":
            let result = WeightGainAnalyticsEngine.cohort(
                snapshot: snapshot,
                snapshotDate: .now,
                scope: .inHerdOnly
            )
            return try boundedJSON([
                "focus": "weight",
                "sampled_sheep_count": result.sheepIDs.count,
                "latest_average_weight_kg": Self.json(result.latestAverageWeight),
                "latest_average_daily_gain_kg": Self.json(result.latestAverageADG),
                "trend": result.weightTrend.suffix(12).map {
                    ["date": Self.iso8601($0.date), "average_weight_kg": $0.value]
                },
                "adg_trend": result.adgTrend.suffix(12).map {
                    ["date": Self.iso8601($0.date), "average_daily_gain_kg": $0.value]
                },
            ])
        case "lamb":
            let result = LambAnalyticsEngine.calculate(
                snapshot: snapshot,
                selectedYear: selectedYear
            )
            return try boundedJSON([
                "focus": "lamb",
                "year": selectedYear ?? "all",
                "total_lambs": result.lambStats.totalLambs,
                "birth_mortality_rate": result.lambStats.mortalityRate,
                "death_cull_rate": result.lambStats.deathCullRate,
                "weaning_count": result.weaning.total,
                "average_weaning_adg_g": result.weaning.averageADG,
                "abnormal_weaning_rows": result.weaning.abnormalCount,
                "incomplete_lambing_rows": result.incompleteLambingCount,
                "months": result.lambStats.months.prefix(12).map {
                    [
                        "month": $0.month,
                        "total_lambs": $0.totalLambs,
                        "birth_dead": $0.birthDead,
                        "average_per_lambing": $0.avgPerLamb,
                    ] as [String: Any]
                },
            ])
        case "reproduction":
            let result = ReproductionAnalyticsEngine.calculate(
                snapshot: snapshot,
                selectedYear: selectedYear
            )
            return try boundedJSON([
                "focus": "reproduction",
                "year": selectedYear ?? "all",
                "average_lambs_per_lambing": result.overview.averageTotal,
                "mortality_rate": result.overview.mortalityRate,
                "average_birth_weight_kg": result.overview.averageBirthWeight,
                "male_count": result.maleCount,
                "female_count": result.femaleCount,
                "incomplete_lambing_rows": result.incompleteLambingCount,
                "months": result.monthly.suffix(12).map {
                    [
                        "month": $0.month,
                        "lambings": $0.lambings,
                        "total_lambs": $0.total,
                        "male": $0.male,
                        "female": $0.female,
                    ] as [String: Any]
                },
                "breed_rows": result.breedRows.prefix(20).map {
                    [
                        "breed": $0.breed,
                        "sheep_count": $0.sheepCount,
                        "lambing_count": $0.lambingCount,
                        "average_lambs": $0.averageLambs,
                    ] as [String: Any]
                },
            ])
        case "feeding":
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            let rows = snapshot.feeds.filter { $0.occurredAt >= cutoff }
            let penNames = Dictionary(uniqueKeysWithValues: snapshot.pens.map { ($0.id, $0.name) })
            let byPen = Dictionary(grouping: rows, by: { penNames[$0.penID] ?? "未知圈舍" })
            let byIngredient = Dictionary(grouping: rows) { (row: FarmAnalyticsSnapshot.Feed) in
                row.ingredientName
            }
            let byPenRows: [[String: Any]] = byPen.map { name, feeds in
                ["name": name, "kilograms": feeds.reduce(0) { $0 + $1.kilograms }]
            }
            .sorted { lhs, rhs in
                (lhs["kilograms"] as? Double ?? 0) > (rhs["kilograms"] as? Double ?? 0)
            }
            .prefix(50)
            .map { $0 }
            let byIngredientRows: [[String: Any]] = byIngredient.map { name, feeds in
                ["name": name, "kilograms": feeds.reduce(0) { $0 + $1.kilograms }]
            }
            .sorted { lhs, rhs in
                (lhs["kilograms"] as? Double ?? 0) > (rhs["kilograms"] as? Double ?? 0)
            }
            .prefix(50)
            .map { $0 }
            return try boundedJSON([
                "focus": "feeding",
                "period_days": 30,
                "record_line_count": rows.count,
                "total_kg": rows.reduce(0) { $0 + $1.kilograms },
                "by_pen": byPenRows,
                "by_ingredient": byIngredientRows,
            ])
        default:
            throw InsightToolError.invalidArguments("focus")
        }
    }

    private func analyticsSnapshot(
        farmID: UUID,
        context: ModelContext
    ) throws -> FarmAnalyticsSnapshot {
        FarmAnalyticsSnapshot.make(
            farmID: farmID,
            sheep: try context.fetch(FetchDescriptor<SheepRecord>()),
            pens: try context.fetch(FetchDescriptor<PenRecord>()),
            weights: try context.fetch(FetchDescriptor<WeightRecord>()),
            weanings: try context.fetch(FetchDescriptor<WeaningRecord>()),
            reproduction: try context.fetch(FetchDescriptor<ReproductionRecord>()),
            offspring: try context.fetch(FetchDescriptor<LambingOffspringRecord>()),
            removals: try context.fetch(FetchDescriptor<RemovalRecord>()),
            transfers: try context.fetch(FetchDescriptor<TransferRecord>()),
            memberships: try context.fetch(FetchDescriptor<BatchMembershipRecord>()),
            feeds: try context.fetch(FetchDescriptor<FeedRecord>()),
            feedLines: try context.fetch(FetchDescriptor<FeedRecordLine>())
        )
    }

    private func recordWeaningDraft(
        _ arguments: [String: Any],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        let sheep = try exactSheep(
            earTag: try Self.string(arguments, "ear_tag"),
            farmID: agent.farmID,
            context: context
        )
        guard sheep.status == .active else {
            throw InsightToolError.invalidArguments("ear_tag")
        }
        let weanWeight = try Self.string(arguments, "wean_weight")
        guard Decimal.stable(weanWeight).map({ $0 > 0 }) == true else {
            throw InsightToolError.invalidArguments("wean_weight")
        }
        let pen = try exactPen(
            name: try Self.nonempty(arguments, "to_pen_name"),
            farmID: agent.farmID,
            context: context
        )
        let occurredAt = try Self.date(arguments, "occurred_at")
        guard occurredAt <= Date.now,
              sheep.birthAt.map({ $0 <= occurredAt }) ?? true else {
            throw InsightToolError.invalidArguments("occurred_at")
        }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter {
            $0.farmID == agent.farmID && $0.sheepID == sheep.id && $0.deletedAt == nil
        }
        guard FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers) != pen.id else {
            throw InsightToolError.invalidArguments("to_pen_name")
        }
        let payload = RecordWeaningToolPayload(
            sheepID: sheep.id,
            earTag: sheep.earTag,
            weanWeightText: weanWeight,
            toPenID: pen.id,
            penName: pen.name,
            occurredAt: occurredAt,
            note: try Self.string(arguments, "note")
        )
        let draft = try makeDraft(
            toolName: "draft_record_weaning",
            title: "记录断奶",
            summary: "\(sheep.earTag) · \(weanWeight) kg · 调入 \(pen.name)",
            payload: payload,
            risk: .normal,
            capability: .recordProduction,
            expectedEntityID: sheep.id,
            expectedRevision: sheep.revision,
            agent: agent
        )
        return proposalOutput(draft)
    }

    private func recordWeaningDrafts(
        _ arguments: [String: Any],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        guard let items = arguments["items"] as? [[String: Any]],
              (1...Self.maximumRows).contains(items.count) else {
            throw InsightToolError.invalidArguments("items")
        }
        let occurredAt = try Self.date(arguments, "occurred_at")
        guard occurredAt <= Date.now else {
            throw InsightToolError.invalidArguments("occurred_at")
        }
        let pen = try exactPen(
            name: try Self.nonempty(arguments, "to_pen_name"),
            farmID: agent.farmID,
            context: context
        )
        let note = try Self.string(arguments, "note")
        let sheepByEarTag = Dictionary(grouping: try context.fetch(
            FetchDescriptor<SheepRecord>()
        ).filter {
            $0.farmID == agent.farmID && $0.deletedAt == nil
        }) {
            EarTag.normalized($0.earTag)
        }
        let transfersBySheepID = Dictionary(grouping: try context.fetch(
            FetchDescriptor<TransferRecord>()
        ).filter {
            $0.farmID == agent.farmID && $0.deletedAt == nil
        }, by: \.sheepID)
        var seenSheepIDs = Set<UUID>()
        var resolved: [(sheep: SheepRecord, weanWeight: String)] = []
        resolved.reserveCapacity(items.count)

        // Validate the complete batch before creating any card. A single OCR,
        // ear-tag, date or target-pen error must not leave a partial batch that
        // the assistant can mistakenly describe as complete.
        for (index, item) in items.enumerated() {
            let inputEarTag = try Self.nonempty(item, "ear_tag")
            let matches = sheepByEarTag[EarTag.normalized(inputEarTag)] ?? []
            guard matches.count == 1, let sheep = matches.first else {
                throw InsightToolError.invalidArguments("items[\(index)].ear_tag")
            }
            guard sheep.status == .active,
                  seenSheepIDs.insert(sheep.id).inserted else {
                throw InsightToolError.invalidArguments("items[\(index)].ear_tag")
            }
            let weanWeight = try Self.string(item, "wean_weight")
            guard Decimal.stable(weanWeight).map({ $0 > 0 }) == true else {
                throw InsightToolError.invalidArguments("items[\(index)].wean_weight")
            }
            guard sheep.birthAt.map({ $0 <= occurredAt }) ?? true else {
                throw InsightToolError.invalidArguments("occurred_at")
            }
            let transfers = transfersBySheepID[sheep.id] ?? []
            guard FarmHistoryTimeline.pen(
                for: sheep,
                at: occurredAt,
                transfers: transfers
            ) != pen.id else {
                throw InsightToolError.invalidArguments("to_pen_name")
            }
            resolved.append((sheep, weanWeight))
        }

        let drafts = try resolved.map { value in
            try makeDraft(
                toolName: "draft_record_weaning",
                title: "记录断奶",
                summary: "\(value.sheep.earTag) · \(value.weanWeight) kg · 调入 \(pen.name)",
                payload: RecordWeaningToolPayload(
                    sheepID: value.sheep.id,
                    earTag: value.sheep.earTag,
                    weanWeightText: value.weanWeight,
                    toPenID: pen.id,
                    penName: pen.name,
                    occurredAt: occurredAt,
                    note: note
                ),
                risk: .normal,
                capability: .recordProduction,
                expectedEntityID: value.sheep.id,
                expectedRevision: value.sheep.revision,
                agent: agent
            )
        }
        return proposalOutput(drafts)
    }

    private func validateWeaningDraft(
        _ draft: InsightActionDraftRecord,
        farmID: UUID,
        context: ModelContext
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value: RecordWeaningToolPayload
        do {
            value = try decoder.decode(RecordWeaningToolPayload.self, from: draft.argumentsJSON)
        } catch {
            throw InsightToolError.invalidArguments("草案字段")
        }
        let sheepID = value.sheepID
        let penID = value.toPenID
        let activeStatus = SheepStatus.active.rawValue
        var sheepDescriptor = FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.id == sheepID &&
                $0.farmID == farmID &&
                $0.deletedAt == nil &&
                $0.statusRawValue == activeStatus
        })
        sheepDescriptor.fetchLimit = 1
        var penDescriptor = FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.id == penID &&
                $0.farmID == farmID &&
                $0.deletedAt == nil &&
                $0.isActive
        })
        penDescriptor.fetchLimit = 1
        guard draft.expectedEntityID == value.sheepID,
              Decimal.stable(value.weanWeightText).map({ $0 > 0 }) == true,
              value.occurredAt <= Date.now,
              let sheep = try context.fetch(sheepDescriptor).first,
              EarTag.normalized(sheep.earTag) == EarTag.normalized(value.earTag),
              let pen = try context.fetch(penDescriptor).first,
              pen.name.trimmingCharacters(in: .whitespacesAndNewlines)
                  .localizedCaseInsensitiveCompare(
                      value.penName.trimmingCharacters(in: .whitespacesAndNewlines)
                  ) == .orderedSame else {
            throw InsightToolError.crossFarmReference
        }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.sheepID == sheepID &&
                $0.deletedAt == nil
        }))
        guard FarmHistoryTimeline.pen(for: sheep, at: value.occurredAt, transfers: transfers) != pen.id else {
            throw InsightToolError.invalidArguments("toPenID")
        }
    }

    private func recordWeightDraft(
        _ arguments: [String: Any],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        let sheep = try exactSheep(
            earTag: try Self.string(arguments, "ear_tag"),
            farmID: agent.farmID,
            context: context
        )
        let kilograms = try Self.string(arguments, "kilograms")
        guard let value = Decimal(string: kilograms), value > 0 else {
            throw InsightToolError.invalidArguments("kilograms")
        }
        let payload = RecordWeightToolPayload(
            sheepID: sheep.id,
            earTag: sheep.earTag,
            kilogramsText: kilograms,
            occurredAt: try Self.date(arguments, "occurred_at"),
            note: try Self.string(arguments, "note")
        )
        let draft = try makeDraft(
            toolName: "draft_record_weight",
            title: "记录称重",
            summary: "\(sheep.earTag) · \(kilograms) kg",
            payload: payload,
            risk: .normal,
            capability: .recordProduction,
            expectedEntityID: sheep.id,
            expectedRevision: sheep.revision,
            agent: agent
        )
        return proposalOutput(draft)
    }

    private func recordWeightDrafts(
        _ arguments: [String: Any],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        guard let items = arguments["items"] as? [[String: Any]],
              (1...Self.maximumRows).contains(items.count) else {
            throw InsightToolError.invalidArguments("items")
        }
        let occurredAt = try Self.date(arguments, "occurred_at")
        let note = try Self.string(arguments, "note")
        var seenSheepIDs = Set<UUID>()
        var resolved: [(sheep: SheepRecord, kilograms: String)] = []
        resolved.reserveCapacity(items.count)

        // Resolve and validate the entire batch before creating any draft so a
        // malformed row cannot leave the user with a misleading partial batch.
        for (index, item) in items.enumerated() {
            let sheep = try exactSheep(
                earTag: try Self.string(item, "ear_tag"),
                farmID: agent.farmID,
                context: context
            )
            guard seenSheepIDs.insert(sheep.id).inserted else {
                throw InsightToolError.invalidArguments("items[\(index)].ear_tag 重复")
            }
            let kilograms = try Self.string(item, "kilograms")
            guard let value = Decimal(string: kilograms), value > 0 else {
                throw InsightToolError.invalidArguments("items[\(index)].kilograms")
            }
            resolved.append((sheep, kilograms))
        }

        let drafts = try resolved.map { value in
            try makeDraft(
                toolName: "draft_record_weight",
                title: "记录称重",
                summary: "\(value.sheep.earTag) · \(value.kilograms) kg",
                payload: RecordWeightToolPayload(
                    sheepID: value.sheep.id,
                    earTag: value.sheep.earTag,
                    kilogramsText: value.kilograms,
                    occurredAt: occurredAt,
                    note: note
                ),
                risk: .normal,
                capability: .recordProduction,
                expectedEntityID: value.sheep.id,
                expectedRevision: value.sheep.revision,
                agent: agent
            )
        }
        return proposalOutput(drafts)
    }

    private func sellSheepBatchDrafts(
        _ arguments: [String: Any],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        guard let earTags = arguments["ear_tags"] as? [String],
              (1...Self.maximumBatchEarTags).contains(earTags.count) else {
            throw InsightToolError.invalidArguments("ear_tags")
        }
        let occurredAt = try Self.date(arguments, "occurred_at")
        let totalAmount = try Self.string(arguments, "total_amount")
        guard let total = Decimal(string: totalAmount), total > 0,
              let stableTotal = Decimal.stable(totalAmount)?.stableText else {
            throw InsightToolError.invalidArguments("total_amount")
        }
        let note = try Self.string(arguments, "note")
        var seenSheepIDs = Set<UUID>()
        var sheep: [SheepRecord] = []
        sheep.reserveCapacity(earTags.count)
        let earTagIndex = try sheepEarTagIndex(farmID: agent.farmID, context: context)

        // Resolve the full batch before creating any proposal. One invalid,
        // duplicated or already-removed ear tag rejects the whole call.
        for (index, earTag) in earTags.enumerated() {
            let item: SheepRecord
            switch resolveSheepEarTag(earTag, index: earTagIndex) {
            case .matched(let value, _):
                item = value
            case .ambiguous(let matches):
                let candidates = matches.prefix(5).map(\.earTag).joined(separator: "、")
                throw InsightToolError.invalidArguments(
                    "ear_tags[\(index)] \(earTag) 匹配到多个羊号：\(candidates)"
                )
            case .notFound:
                throw InsightToolError.invalidArguments(
                    "ear_tags[\(index)] 找不到 \(earTag)"
                )
            }
            guard item.isCurrentlyPresent else {
                throw InsightToolError.invalidArguments("ear_tags[\(index)] 已离场")
            }
            guard seenSheepIDs.insert(item.id).inserted else {
                throw InsightToolError.invalidArguments("ear_tags[\(index)] 重复")
            }
            sheep.append(item)
        }

        let removalBatchID = UUID()
        let drafts = try sheep.map { item in
            let command = FarmCommand.removeSheep(
                sheepID: item.id,
                kind: .sold,
                reason: "出售",
                amountText: nil,
                occurredAt: occurredAt,
                note: note,
                recordID: nil,
                removalBatchID: removalBatchID,
                batchTotalAmountText: stableTotal
            )
            let canonicalData = try FarmCommandCloudPayloadEncoder.encode(command)
            let payload = try Self.decodeCanonicalPayload(canonicalData)
            return try canonicalFarmCommandProposal(
                command: command,
                canonicalData: canonicalData,
                payload: payload,
                summary: "\(item.earTag) · 批量出售，总价 ¥\(stableTotal)",
                agent: agent,
                context: context
            ).actionDrafts[0]
        }
        return proposalOutput(drafts)
    }

    private func addNoteDraft(
        _ arguments: [String: Any],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        let earTag = try Self.string(arguments, "ear_tag")
        let penName = try Self.string(arguments, "pen_name")
        let sheep = earTag.isEmpty ? nil : try exactSheep(earTag: earTag, farmID: agent.farmID, context: context)
        let pen = penName.isEmpty ? nil : try exactPen(name: penName, farmID: agent.farmID, context: context)
        guard sheep != nil || pen != nil else {
            throw InsightToolError.invalidArguments("ear_tag or pen_name")
        }
        let text = try Self.nonempty(arguments, "text")
        let subject = sheep?.earTag ?? pen?.name ?? "牧场"
        let payload = AddNoteToolPayload(
            sheepID: sheep?.id,
            penID: pen?.id,
            subject: subject,
            text: text,
            occurredAt: try Self.date(arguments, "occurred_at")
        )
        let draft = try makeDraft(
            toolName: "draft_add_note",
            title: "添加备注",
            summary: "\(subject) · \(text)",
            payload: payload,
            risk: .normal,
            capability: .recordProduction,
            expectedEntityID: sheep?.id ?? pen?.id,
            expectedRevision: sheep?.revision ?? pen?.revision,
            agent: agent
        )
        return proposalOutput(draft)
    }

    private func transferDraft(
        _ arguments: [String: Any],
        agent: InsightAgentContext,
        context: ModelContext
    ) throws -> InsightToolExecution {
        let sheep = try exactSheep(
            earTag: try Self.string(arguments, "ear_tag"),
            farmID: agent.farmID,
            context: context
        )
        let penName = try Self.string(arguments, "to_pen_name")
        let pen = penName.isEmpty ? nil : try exactPen(name: penName, farmID: agent.farmID, context: context)
        let payload = TransferSheepToolPayload(
            sheepID: sheep.id,
            earTag: sheep.earTag,
            toPenID: pen?.id,
            penName: pen?.name ?? "未分圈",
            occurredAt: try Self.date(arguments, "occurred_at"),
            note: try Self.string(arguments, "note")
        )
        let draft = try makeDraft(
            toolName: "draft_transfer_sheep",
            title: "记录转群",
            summary: "\(sheep.earTag) → \(payload.penName)",
            payload: payload,
            risk: .normal,
            capability: .recordProduction,
            expectedEntityID: sheep.id,
            expectedRevision: sheep.revision,
            agent: agent
        )
        return proposalOutput(draft)
    }

    private func reminderDraft(
        _ arguments: [String: Any],
        agent: InsightAgentContext
    ) throws -> InsightToolExecution {
        let dueText = try Self.string(arguments, "due_at")
        let value = InsightReminderDraft(
            title: try Self.nonempty(arguments, "title"),
            notes: try Self.string(arguments, "notes"),
            dueAt: dueText.isEmpty ? nil : try Self.parseDate(dueText, field: "due_at")
        )
        let draft = try makeDraft(
            toolName: "draft_reminder",
            title: "创建提醒事项",
            summary: value.dueAt.map { "\(value.title) · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? value.title,
            payload: value,
            risk: .normal,
            capability: .readFarm,
            expectedEntityID: nil,
            expectedRevision: nil,
            agent: agent
        )
        return proposalOutput(draft)
    }

    private func calendarDraft(
        _ arguments: [String: Any],
        agent: InsightAgentContext
    ) throws -> InsightToolExecution {
        let start = try Self.date(arguments, "start_at")
        let end = try Self.date(arguments, "end_at")
        guard end > start else { throw InsightToolError.invalidArguments("end_at") }
        let value = InsightCalendarEventDraft(
            title: try Self.nonempty(arguments, "title"),
            notes: try Self.string(arguments, "notes"),
            startAt: start,
            endAt: end
        )
        let draft = try makeDraft(
            toolName: "draft_calendar_event",
            title: "创建日历事件",
            summary: "\(value.title) · \(start.formatted(date: .abbreviated, time: .shortened))",
            payload: value,
            risk: .normal,
            capability: .readFarm,
            expectedEntityID: nil,
            expectedRevision: nil,
            agent: agent
        )
        return proposalOutput(draft)
    }

    private func proposalOutput(_ draft: InsightActionDraftRecord) -> InsightToolExecution {
        InsightToolExecution(
            output: "{\"status\":\"proposal_created\",\"draft_id\":\"\(draft.id.uuidString.lowercased())\",\"requires_user_confirmation\":true}",
            actionDraft: draft
        )
    }

    private func proposalOutput(
        _ drafts: [InsightActionDraftRecord]
    ) -> InsightToolExecution {
        let object: [String: Any] = [
            "status": "proposals_created",
            "proposal_count": drafts.count,
            "draft_ids": drafts.map { $0.id.uuidString.lowercased() },
            "requires_user_confirmation": true,
            "executed_count": 0,
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return InsightToolExecution(
            output: data.map { String(decoding: $0, as: UTF8.self) }
                ?? "{\"status\":\"proposals_created\",\"requires_user_confirmation\":true,\"executed_count\":0}",
            actionDrafts: drafts
        )
    }

    private func makeDraft<Payload: Encodable>(
        toolName: String,
        title: String,
        summary: String,
        payload: Payload,
        risk: InsightActionRisk,
        capability: FarmCapability,
        expectedEntityID: UUID?,
        expectedRevision: Int?,
        agent: InsightAgentContext
    ) throws -> InsightActionDraftRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return InsightActionDraftRecord(
            conversationID: agent.conversationID,
            accountID: agent.accountID,
            farmID: agent.farmID,
            originDeviceID: agent.originDeviceID,
            toolName: toolName,
            title: title,
            summary: summary,
            argumentsJSON: try encoder.encode(payload),
            risk: risk,
            requiredCapability: capability,
            expectedEntityID: expectedEntityID,
            expectedRevision: expectedRevision
        )
    }

    private func exactSheep(earTag: String, farmID: UUID, context: ModelContext) throws -> SheepRecord {
        let normalized = EarTag.normalized(earTag)
        guard let value = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: {
            $0.farmID == farmID && $0.deletedAt == nil && EarTag.normalized($0.earTag) == normalized
        }) else {
            throw InsightToolError.invalidArguments("ear_tag")
        }
        return value
    }

    private func sheepEarTagIndex(
        farmID: UUID,
        context: ModelContext
    ) throws -> SheepEarTagIndex {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
            .sorted {
                $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending
            }
        var exactMatches: [String: [SheepRecord]] = [:]
        var numericBodyMatches: [String: [SheepRecord]] = [:]

        for item in sheep {
            exactMatches[EarTag.normalized(item.earTag), default: []].append(item)
            if let numericBody = Self.numericEarTagBody(item.earTag) {
                numericBodyMatches[numericBody, default: []].append(item)
            }
        }
        return SheepEarTagIndex(
            exactMatches: exactMatches,
            numericBodyMatches: numericBodyMatches
        )
    }

    private func resolveSheepEarTag(
        _ earTag: String,
        index: SheepEarTagIndex
    ) -> SheepEarTagResolution {
        let exactMatches = index.exactMatches[EarTag.normalized(earTag)] ?? []
        if exactMatches.count == 1, let sheep = exactMatches.first {
            return .matched(sheep, matchKind: "exact")
        }
        if exactMatches.count > 1 {
            return .ambiguous(exactMatches)
        }

        guard let numericReference = Self.numericEarTagReference(earTag) else {
            return .notFound
        }
        let numericMatches = index.numericBodyMatches[numericReference] ?? []
        if numericMatches.count == 1, let sheep = numericMatches.first {
            return .matched(sheep, matchKind: "unique_numeric_body")
        }
        if numericMatches.count > 1 {
            return .ambiguous(numericMatches)
        }
        return .notFound
    }

    private static func numericEarTagReference(_ value: String) -> String? {
        let normalized = SearchText.normalized(value)
        guard !normalized.isEmpty,
              normalized.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return normalized
    }

    private static func numericEarTagBody(_ value: String) -> String? {
        let digits = String(SearchText.normalized(value).filter { $0.isNumber })
        return digits.isEmpty ? nil : digits
    }

    private func exactPen(name: String, farmID: UUID, context: ModelContext) throws -> PenRecord {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try context.fetch(FetchDescriptor<PenRecord>()).first(where: {
            $0.farmID == farmID &&
                $0.deletedAt == nil &&
                $0.isActive &&
                $0.name.localizedCaseInsensitiveCompare(normalized) == .orderedSame
        }) else {
            throw InsightToolError.invalidArguments("pen_name")
        }
        return value
    }

    private func validateReferences(
        payload: FarmCommandCloudPayload,
        command: FarmCommand,
        farmID: UUID,
        context: ModelContext,
        knownEntityIDs: Set<UUID>? = nil
    ) throws {
        var referencedIDs = Set(payload.identifiers.values)
        referencedIDs.formUnion(payload.optionalIdentifiers.values.compactMap { $0 })
        switch command {
        case .createBatch(_, _, _, let sheepIDs, _):
            referencedIDs.formUnion(sheepIDs)
        case .removeSheep(_, _, _, _, _, _, _, let removalBatchID, _):
            // A removal batch ID is a new correlation identifier shared by
            // the drafts, not a reference to an existing farm entity.
            if let removalBatchID {
                referencedIDs.remove(removalBatchID)
            }
        case .recordFeed(_, _, _, _, let lines, _):
            referencedIDs.formUnion(lines.map(\.ingredientID))
            referencedIDs.formUnion(lines.compactMap(\.ingredientBatchID))
        case .recordReproduction(_, _, _, _, _, _, _, _, _, let offspring, _):
            referencedIDs.formUnion(offspring.compactMap(\.sheepID))
        case .care(let careCommand):
            referencedIDs.formUnion(Self.careReferenceIDs(careCommand))
        default:
            break
        }
        let knownIDs = try knownEntityIDs
            ?? knownFarmEntityIDs(farmID: farmID, context: context)
        guard referencedIDs.isSubset(of: knownIDs) else {
            throw InsightToolError.crossFarmReference
        }
    }

    private func knownFarmEntityIDs(
        farmID: UUID,
        context: ModelContext
    ) throws -> Set<UUID> {
        var result: Set<UUID> = []
        result.formUnion(try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<WeaningRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<BreedingProgramRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<FeedRecipeRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<SemenRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<SemenDonorRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<PedigreeChangeRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<NoteRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<CareBatchRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<CareReminderRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).filter { $0.farmID == farmID }.map(\.id))
        result.formUnion(try context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.farmID == farmID }.map(\.id))
        return result
    }

    private func primaryRevision(
        in payload: FarmCommandCloudPayload,
        farmID: UUID,
        context: ModelContext
    ) throws -> (id: UUID, revision: Int)? {
        let preferredFields = [
            "originalID", "entityID", "tombstoneID", "removalID",
            "sheepID", "eweID", "penID", "lotID", "semenID",
            "batchID", "recipeID", "ingredientID",
        ]
        var identifiers = preferredFields.compactMap {
            payload.identifiers[$0] ?? (payload.optionalIdentifiers[$0] ?? nil)
        }
        let preferredIDs = Set(identifiers)
        identifiers.append(contentsOf: payload.identifiers.values.filter {
            !preferredIDs.contains($0)
        })
        for id in identifiers {
            if let revision = try entityRevision(id: id, farmID: farmID, context: context) {
                return (id, revision)
            }
        }
        return nil
    }

    private func entityRevision(
        id: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> Int? {
        if let value = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<PenRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<WeightRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<WeaningRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<TransferRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<RemovalRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<FeedRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<SemenRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<SemenDonorRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<NoteRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<CareReminderRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        if let value = try context.fetch(FetchDescriptor<TombstoneRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID
        }) { return value.revision }
        return nil
    }

    private func entityRevisions(
        ids: Set<UUID>,
        farmID: UUID,
        context: ModelContext
    ) throws -> [UUID: Int] {
        guard !ids.isEmpty else { return [:] }
        var unresolved = ids
        var revisions: [UUID: Int] = [:]

        func capture<T>(
            _ values: [T],
            id: KeyPath<T, UUID>,
            farmID valueFarmID: KeyPath<T, UUID>,
            revision: KeyPath<T, Int>
        ) {
            for value in values where value[keyPath: valueFarmID] == farmID {
                let entityID = value[keyPath: id]
                guard unresolved.remove(entityID) != nil else { continue }
                revisions[entityID] = value[keyPath: revision]
            }
        }

        // Most assistant action cards target sheep. Keep the confirmation hot
        // path proportional to the selected cards instead of faulting every
        // sheep in a large farm just to compare one or a few revisions.
        let sheepIDs = Array(unresolved)
        capture(
            try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                sheepIDs.contains($0.id) && $0.farmID == farmID
            })),
            id: \.id,
            farmID: \.farmID,
            revision: \.revision
        )
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<PenRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<WeightRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<WeaningRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<TransferRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<RemovalRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<FeedRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<ReproductionRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<LambingOffspringRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<SemenRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<SemenDonorRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<NoteRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<CareReminderRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        if unresolved.isEmpty { return revisions }
        capture(try context.fetch(FetchDescriptor<TombstoneRecord>()), id: \.id, farmID: \.farmID, revision: \.revision)
        return revisions
    }

    private static func careReferenceIDs(_ command: CareCommand) -> Set<UUID> {
        var result: Set<UUID> = []
        func add(_ value: UUID?) {
            if let value { result.insert(value) }
        }
        func addHealth(_ draft: CareHealthDraft) {
            result.formUnion(draft.subjectIDs)
            add(draft.penID)
            add(draft.catalogItemID)
            add(draft.inventoryLotID)
        }
        func addReproduction(_ draft: CareReproductionBatchDraft) {
            result.formUnion(draft.subjects.map(\.eweID))
            result.formUnion(draft.subjects.compactMap(\.relatedBreedingRecordID))
            add(draft.sireID)
            add(draft.semenID)
        }
        func addLambing(_ draft: CareLambingDraft) {
            result.insert(draft.eweID)
            add(draft.sireID)
            add(draft.semenID)
            add(draft.relatedBreedingRecordID)
            add(draft.penID)
        }
        switch command {
        case .upsertHealthCatalog, .updateRules, .updateOperationalAlertRules:
            break
        case .recordHealth(let draft):
            addHealth(draft)
        case .correctHealth(let originalID, let replacement, _):
            result.insert(originalID)
            addHealth(replacement)
        case .receiveInventory(_, _, let catalogItemID, _, _, _, _, _, _, _, _):
            add(catalogItemID)
        case .adjustInventory(_, let lotID, _, _, _), .setInventoryLotActive(let lotID, _):
            result.insert(lotID)
        case .adjustSemen(_, let semenID, _, _, _):
            result.insert(semenID)
        case .upsertSemenDonor(let draft):
            add(draft.linkedRamID)
        case .setSemenDonor(let semenID, let donorID, _):
            result.insert(semenID)
            add(donorID)
        case .updateSheepPedigree(let draft):
            result.insert(draft.sheepID)
            add(draft.damID)
            add(draft.sireID)
            add(draft.semenDonorID)
        case .setBreedingRam(let sheepID, _, _),
             .setSheepPurpose(let sheepID, _, _, _):
            result.insert(sheepID)
        case .restorePedigreeAudit(let snapshot):
            result.insert(snapshot.id)
            result.insert(snapshot.sheepID)
            [
                snapshot.beforeDamID, snapshot.afterDamID,
                snapshot.beforeSireID, snapshot.afterSireID,
                snapshot.beforeSemenDonorID, snapshot.afterSemenDonorID,
            ].forEach(add)
        case .recordReproductionBatch(let draft):
            addReproduction(draft)
        case .recordLambing(let draft):
            addLambing(draft)
        case .correctReproduction(let originalID, let replacement, _):
            result.insert(originalID)
            addReproduction(replacement)
        case .correctLambing(let originalID, let replacement, _):
            result.insert(originalID)
            addLambing(replacement)
        case .revokeLambing(let recordID, _), .restoreLambing(let recordID):
            result.insert(recordID)
        case .deferOperationalAlert(let draft):
            add(draft.subjectID)
            add(draft.sourceEntityID)
        case .setReminderStatus(let reminderID, _):
            result.insert(reminderID)
        }
        return result
    }

    private static let aiFarmOperationKinds: [DomainOperationKind] = [
        .updateFarmLocation,
        .createPen, .updatePen, .setPenActive,
        .addSheep, .updateSheepProfile,
        .recordWeight, .correctWeight,
        .createBreedingProgram,
        .transferSheep, .correctTransfer,
        .removeSheep, .correctRemoval, .restoreSheep,
        .createBatch, .assignBatchMembership, .leaveBatchMembership,
        .addIngredient, .createRecipe, .addRecipeComponent,
        .recordFeed, .recordHealth, .receiveInventory, .addSemen,
        .recordReproduction, .care, .addNote,
        .tombstoneEntity, .restoreTombstonedEntity,
    ]

    private static func capability(for kind: DomainOperationKind) -> FarmCapability {
        switch kind {
        case .updateFarmLocation:
            .editFarmLocation
        case .correctWeight, .correctTransfer, .correctRemoval:
            .editHistoricalFacts
        case .restoreSheep, .tombstoneEntity, .restoreTombstonedEntity:
            .deleteProtectedFacts
        case .createBreedingProgram, .addIngredient, .createRecipe, .addRecipeComponent:
            .manageCatalogs
        default:
            .recordProduction
        }
    }

    private static func risk(for kind: DomainOperationKind) -> InsightActionRisk {
        switch kind {
        case .updateFarmLocation, .createPen, .updatePen, .setPenActive,
             .correctWeight, .createBreedingProgram, .correctTransfer,
             .removeSheep, .correctRemoval, .restoreSheep,
             .addIngredient, .createRecipe, .addRecipeComponent,
             .receiveInventory, .addSemen, .recordReproduction, .care,
             .tombstoneEntity, .restoreTombstonedEntity:
            .high
        default:
            .normal
        }
    }

    private static func risk(for command: FarmCommand) -> InsightActionRisk {
        switch command {
        case .care(let careCommand):
            switch careCommand {
            case .recordHealth, .setReminderStatus:
                return .normal
            default:
                return .high
            }
        default:
            return risk(for: command.operationKind)
        }
    }

    private static let requiredStringFields: [DomainOperationKind: [String]] = [
        .updateFarmLocation: ["displayName", "latitude", "longitude", "timeZoneIdentifier", "source"],
        .createPen: ["name", "note"],
        .updatePen: ["name", "note"],
        .addSheep: ["earTag", "breed", "sex", "note"],
        .updateSheepProfile: ["earTag", "breed", "sex", "note"],
        .recordWeight: ["kilogramsText", "note"],
        .correctWeight: ["kilogramsText", "note", "reason"],
        .recordWeaning: ["weanWeightText", "note"],
        .createBreedingProgram: ["name"],
        .transferSheep: ["note"],
        .correctTransfer: ["note", "reason"],
        .removeSheep: ["kind", "reason", "note"],
        .correctRemoval: ["kind", "reason", "note", "correctionReason"],
        .createBatch: ["name", "purpose", "note", "sheepIDs"],
        .leaveBatchMembership: ["reason"],
        .addIngredient: ["name", "unit"],
        .createRecipe: ["name", "note"],
        .addRecipeComponent: ["kilogramsText"],
        .recordFeed: ["mode", "note"],
        .recordHealth: ["kind", "itemName", "note"],
        .receiveInventory: ["catalogName", "kind", "quantityText", "note"],
        .addSemen: ["code", "breed", "source", "batchNumber", "quantityText"],
        .recordReproduction: ["kind", "result", "note"],
        .addNote: ["text"],
        .tombstoneEntity: ["entityType", "reason"],
    ]

    private static let optionalStringFields: [DomainOperationKind: [String]] = [
        .updateFarmLocation: ["addressSnapshot", "horizontalAccuracyMeters"],
        .removeSheep: ["amountText", "batchTotalAmountText"],
        .correctRemoval: ["amountText"],
        .addIngredient: ["dryMatterText"],
        .recordHealth: ["quantityText"],
        .recordReproduction: ["semenName"],
    ]

    private static let requiredIdentifierFields: [DomainOperationKind: [String]] = [
        .updatePen: ["penID"],
        .setPenActive: ["penID"],
        .updateSheepProfile: ["sheepID"],
        .recordWeight: ["sheepID"],
        .correctWeight: ["originalID"],
        .recordWeaning: ["sheepID"],
        .transferSheep: ["sheepID"],
        .correctTransfer: ["originalID"],
        .removeSheep: ["sheepID"],
        .correctRemoval: ["originalID"],
        .restoreSheep: ["removalID"],
        .assignBatchMembership: ["batchID", "sheepID"],
        .leaveBatchMembership: ["batchID", "sheepID"],
        .addRecipeComponent: ["recipeID", "ingredientID"],
        .recordFeed: ["penID"],
        .recordReproduction: ["eweID"],
        .tombstoneEntity: ["entityID"],
        .restoreTombstonedEntity: ["tombstoneID"],
    ]

    private static let optionalIdentifierFields: [DomainOperationKind: [String]] = [
        .addSheep: ["penID"],
        .recordWeaning: ["damID"],
        .transferSheep: ["toPenID"],
        .correctTransfer: ["toPenID"],
        .removeSheep: ["removalBatchID"],
        .recordFeed: ["recipeID"],
        .recordHealth: ["sheepID", "penID", "inventoryLotID"],
        .recordReproduction: ["sireID"],
        .addNote: ["sheepID", "penID"],
    ]

    private static let requiredDateFields: [DomainOperationKind: [String]] = [
        .addSheep: ["occurredAt"],
        .recordWeight: ["occurredAt"],
        .correctWeight: ["occurredAt"],
        .recordWeaning: ["occurredAt"],
        .createBreedingProgram: ["createdAt"],
        .transferSheep: ["occurredAt"],
        .correctTransfer: ["occurredAt"],
        .removeSheep: ["occurredAt"],
        .correctRemoval: ["occurredAt"],
        .createBatch: ["startedAt"],
        .assignBatchMembership: ["joinedAt"],
        .leaveBatchMembership: ["leftAt"],
        .recordFeed: ["occurredAt"],
        .recordHealth: ["occurredAt"],
        .receiveInventory: ["occurredAt"],
        .recordReproduction: ["occurredAt"],
        .addNote: ["occurredAt"],
    ]

    private static let optionalDateFields: [DomainOperationKind: [String]] = [
        .addSheep: ["birthAt"],
        .updateSheepProfile: ["birthAt"],
        .recordWeaning: ["birthAt"],
        .receiveInventory: ["expiresAt"],
    ]

    private static let integerFields: [DomainOperationKind: [String]] = [
        .setPenActive: ["isActive"],
        .recordWeaning: ["litterSize"],
        .recordReproduction: ["lambCount", "parity", "birthDeadCount"],
    ]

    private func require(_ capability: FarmCapability, agent: InsightAgentContext) throws {
        guard agent.farmContext.capabilities.allows(capability) else {
            throw InsightToolError.permissionDenied
        }
    }

    private func boundedJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= Self.maximumOutputBytes else { throw InsightToolError.resultTooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private static func arguments(_ value: String) throws -> [String: Any] {
        guard let data = value.data(using: .utf8),
              data.count <= 32 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InsightToolError.invalidArguments("JSON")
        }
        return object
    }

    private static func decodeCanonicalPayload(_ data: Data) throws -> FarmCommandCloudPayload {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InsightToolError.invalidArguments("payload_json")
        }
        for key in [
            "strings", "optionalStrings", "identifiers", "optionalIdentifiers",
            "dates", "optionalDates", "integers", "dataValues",
        ] where object[key] == nil {
            object[key] = [String: Any]()
        }
        for key in ["feedLines", "breedingProgramSteps", "lambingOffspring"] where object[key] == nil {
            object[key] = [Any]()
        }
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(FarmCommandCloudPayload.self, from: normalized)
        } catch {
            throw InsightToolError.invalidArguments("payload_json")
        }
    }

    private func decodeEdited<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw InsightToolError.invalidArguments("草案字段")
        }
    }

    private static func encodeCanonicalPayload(_ payload: FarmCommandCloudPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func string(_ values: [String: Any], _ key: String) throws -> String {
        guard let value = values[key] as? String, value.count <= 8_000 else {
            throw InsightToolError.invalidArguments(key)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonempty(_ values: [String: Any], _ key: String) throws -> String {
        let value = try string(values, key)
        guard !value.isEmpty else { throw InsightToolError.invalidArguments(key) }
        return value
    }

    private static func date(_ values: [String: Any], _ key: String) throws -> Date {
        try parseDate(string(values, key), field: key)
    }

    private static func integer(
        _ values: [String: Any],
        _ key: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let number = values[key] as? NSNumber else {
            throw InsightToolError.invalidArguments(key)
        }
        let value = number.intValue
        guard Double(value) == number.doubleValue, range.contains(value) else {
            throw InsightToolError.invalidArguments(key)
        }
        return value
    }

    private static func parseDate(_ value: String, field: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw InsightToolError.invalidArguments(field)
        }
        return date
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func json(_ value: Double?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func extendedCategoryName(_ value: String) -> String {
        switch value {
        case "raw_notes": "原始备注"
        case "health": "健康明细"
        case "reproduction": "繁殖明细"
        default: value
        }
    }

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: JSONValue],
        required: [String]
    ) -> InsightToolDefinition {
        InsightToolDefinition(
            name: name,
            description: description,
            parameters: [
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ]
        )
    }

    private static func string(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }

    private static func enumString(_ description: String, values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }
}

@MainActor
final class InsightDeviceActionService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func execute(draft: InsightActionDraftRecord) async throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch draft.toolName {
        case "draft_reminder":
            let value = try decoder.decode(InsightReminderDraft.self, from: draft.argumentsJSON)
            guard try await eventStore.requestFullAccessToReminders() else {
                throw InsightToolError.deviceActionUnavailable("未获得提醒事项权限，未创建提醒。")
            }
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = value.title
            reminder.notes = nonEmpty(value.notes)
            guard let calendar = eventStore.defaultCalendarForNewReminders() else {
                throw InsightToolError.deviceActionUnavailable("系统没有可写入的提醒事项清单。")
            }
            reminder.calendar = calendar
            if let dueAt = value.dueAt {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
                    from: dueAt
                )
                reminder.addAlarm(EKAlarm(absoluteDate: dueAt))
            }
            try eventStore.save(reminder, commit: true)
            return reminder.calendarItemIdentifier
        case "draft_calendar_event":
            let value = try decoder.decode(InsightCalendarEventDraft.self, from: draft.argumentsJSON)
            guard try await eventStore.requestWriteOnlyAccessToEvents() else {
                throw InsightToolError.deviceActionUnavailable("未获得日历写入权限，未创建事件。")
            }
            let event = EKEvent(eventStore: eventStore)
            event.title = value.title
            event.notes = nonEmpty(value.notes)
            event.startDate = value.startAt
            event.endDate = value.endAt
            guard let calendar = eventStore.defaultCalendarForNewEvents else {
                throw InsightToolError.deviceActionUnavailable("系统没有可写入的默认日历。")
            }
            event.calendar = calendar
            try eventStore.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        default:
            throw InsightToolError.unknownTool
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum InsightBiometricConfirmation {
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? InsightToolError.deviceActionUnavailable("当前设备未配置 Face ID 或 Touch ID。")
        }
        let approved = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        guard approved else {
            throw InsightToolError.deviceActionUnavailable("生物认证未通过。")
        }
    }
}
