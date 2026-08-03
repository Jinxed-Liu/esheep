import Foundation
import SwiftData

struct FarmExcelIssue: Sendable, Equatable, Identifiable {
    enum Severity: Sendable { case warning, error }
    let sheet: String
    let row: Int
    let field: String
    let message: String
    let severity: Severity
    var id: String { "\(sheet):\(row):\(field):\(message)" }
}

struct FarmExcelRow: Sendable, Equatable, Identifiable {
    let sheet: String
    let rowNumber: Int
    let values: [String: String]
    var id: String { "\(sheet):\(rowNumber)" }
    subscript(_ field: String) -> String { values[field]?.trimmed ?? "" }

    func listValues(_ field: String) -> [String] {
        self[field]
            .components(separatedBy: CharacterSet(charactersIn: ";；,，、\n"))
            .map(\.trimmed)
            .filter { !$0.isEmpty }
    }
}

struct FarmExcelSheetSummary: Sendable, Equatable, Identifiable {
    let name: String
    let rowCount: Int
    var id: String { name }
}

struct FarmExcelRemovalBatchSummary: Sendable, Equatable, Identifiable {
    let id: String
    let rowNumber: Int
    let kind: String
    let sheepCount: Int
    let totalAmountText: String?
}

struct FarmExcelPreview: Sendable, Equatable, Identifiable {
    let rows: [FarmExcelRow]
    let issues: [FarmExcelIssue]
    let summaries: [FarmExcelSheetSummary]
    var id: String { rows.map(\.id).joined(separator: "|") }
    var errorCount: Int { issues.count { $0.severity == .error } }
    var warningCount: Int { issues.count { $0.severity == .warning } }
    var canCommit: Bool { !rows.isEmpty && errorCount == 0 }
    var removalBatchSummaries: [FarmExcelRemovalBatchSummary] {
        rows.filter { $0.sheet == "离场" }.map { row in
            let total = Decimal.stable(row["总售卖金额"]).map(\.stableText)
            return FarmExcelRemovalBatchSummary(
                id: row.id,
                rowNumber: row.rowNumber,
                kind: row["类型"],
                sheepCount: row.listValues("羊只耳号列表").count,
                totalAmountText: total
            )
        }
    }
    var expandedRecordCount: Int {
        rows.reduce(into: 0) { count, row in
            count += row.sheet == "离场" ? row.listValues("羊只耳号列表").count : 1
        }
    }
}

private struct FarmExcelSheetSchema {
    let name: String
    let capability: FarmCapability
    let columns: [String]
    let required: Set<String>
    let example: [String]
}

@MainActor
enum FarmExcelImportService {
    static let templateVersion = 5

    /// Template columns may evolve, but an import key is documented as a
    /// long-lived business identity. Keep the original v3 namespace so the
    /// same workbook row does not acquire a different record identity merely
    /// because the app learned how to read a newer template format.
    private static let stableIdentityVersion = 3

    private static let schemas: [FarmExcelSheetSchema] = [
        .init(name: "圈舍", capability: .recordProduction, columns: ["导入键", "圈舍名称", "备注"], required: ["导入键", "圈舍名称"], example: ["示例-pen-01", "育肥一圈", "南侧圈舍"]),
        .init(name: "新建羊只", capability: .recordProduction, columns: ["导入键", "耳号", "品种", "性别", "当前胎次", "圈舍", "入场日期", "出生日期", "备注"], required: ["导入键", "耳号", "品种", "性别", "入场日期"], example: ["示例-sheep-01", "A001", "湖羊", "母羊", "0", "育肥一圈", "2026-07-19", "2026-02-01", ""]),
        .init(name: "称重", capability: .recordProduction, columns: ["导入键", "耳号", "体重kg", "发生日期", "备注"], required: ["导入键", "耳号", "体重kg", "发生日期"], example: ["示例-weight-01", "A001", "35.6", "2026-07-19", "晨间称重"]),
        .init(name: "断奶", capability: .recordProduction, columns: ["导入键", "耳号", "断奶重kg", "转入圈舍", "发生日期", "出生日期", "备注"], required: ["导入键", "耳号", "断奶重kg", "转入圈舍", "发生日期"], example: ["示例-wean-01", "A001", "22.5", "育肥二圈", "2026-07-19", "2026-03-01", ""]),
        .init(name: "转群", capability: .recordProduction, columns: ["导入键", "耳号", "转入圈舍", "发生日期", "备注"], required: ["导入键", "耳号", "转入圈舍", "发生日期"], example: ["示例-transfer-01", "A001", "育肥二圈", "2026-07-19", ""]),
        .init(name: "离场", capability: .recordProduction, columns: ["导入键", "羊只耳号列表", "类型", "原因", "总售卖金额", "发生日期", "备注"], required: ["导入键", "羊只耳号列表", "类型", "原因", "发生日期"], example: ["示例-remove-01", "A001;A002", "出售", "正常销售", "2400", "2026-07-19", "同一行代表同一批离场"]),
        .init(name: "生产批次", capability: .recordProduction, columns: ["导入键", "批次名称", "生产目的", "开始日期", "羊只耳号列表", "备注"], required: ["导入键", "批次名称", "生产目的", "开始日期", "羊只耳号列表"], example: ["示例-batch-01", "2026春羔育肥", "育肥", "2026-07-01", "A001;A002", "只允许人工选择"]),
        .init(name: "批次脱离", capability: .recordProduction, columns: ["导入键", "批次名称", "耳号", "脱离日期", "原因"], required: ["导入键", "批次名称", "耳号", "脱离日期", "原因"], example: ["示例-leave-01", "2026春羔育肥", "A001", "2026-10-01", "留养"]),
        .init(name: "饲料原料", capability: .manageCatalogs, columns: ["导入键", "原料名称", "单位", "干物质"], required: ["导入键", "原料名称", "单位"], example: ["示例-ingredient-01", "玉米", "千克", "0.88"]),
        .init(name: "饲料配方", capability: .manageCatalogs, columns: ["导入键", "配方名称", "备注"], required: ["导入键", "配方名称"], example: ["示例-recipe-01", "育肥前期料", "每100kg"]),
        .init(name: "配方组成", capability: .manageCatalogs, columns: ["导入键", "配方名称", "原料名称", "用量kg"], required: ["导入键", "配方名称", "原料名称", "用量kg"], example: ["示例-component-01", "育肥前期料", "玉米", "60"]),
        .init(name: "投喂", capability: .recordProduction, columns: ["导入键", "圈舍", "配方名称", "方式", "发生日期", "投喂明细", "备注"], required: ["导入键", "圈舍", "方式", "发生日期", "投喂明细"], example: ["示例-feed-01", "育肥一圈", "育肥前期料", "限量投喂", "2026-07-19", "玉米|60;豆粕|20", "数量均为kg"]),
        .init(name: "健康目录", capability: .manageCatalogs, columns: ["导入键", "类型", "名称", "类别", "单位", "默认剂量", "给药途径", "复免间隔天", "启用", "备注"], required: ["导入键", "类型", "名称", "单位"], example: ["示例-catalog-01", "疫苗", "羊三联四防", "疫苗", "毫升", "2", "肌肉注射", "180", "是", ""]),
        .init(name: "库存入库", capability: .manageCatalogs, columns: ["导入键", "目录名称", "类型", "批号", "供应商", "单位", "有效期", "数量", "入库日期", "备注"], required: ["导入键", "目录名称", "类型", "批号", "单位", "数量", "入库日期"], example: ["示例-stock-01", "羊三联四防", "疫苗", "202607A", "供应商", "毫升", "2027-07-01", "100", "2026-07-19", ""]),
        .init(name: "库存调整", capability: .manageCatalogs, columns: ["导入键", "目录名称", "批号", "调整数量", "发生日期", "备注"], required: ["导入键", "目录名称", "批号", "调整数量", "发生日期"], example: ["示例-stock-adjust-01", "羊三联四防", "202607A", "-2", "2026-07-19", "盘点差异"]),
        .init(name: "健康记录", capability: .recordProduction, columns: ["导入键", "类型", "名称", "羊只耳号列表", "圈舍", "目录名称", "库存批号", "每只剂量", "单位", "给药途径", "发生日期", "提醒日期", "备注"], required: ["导入键", "类型", "名称", "发生日期"], example: ["示例-health-01", "疫苗", "羊三联四防", "A001;A002", "", "羊三联四防", "202607A", "2", "毫升", "肌肉注射", "2026-07-19", "2027-01-15", ""]),
        .init(name: "冻精供体", capability: .manageCatalogs, columns: ["导入键", "供体名称", "登记号", "品种", "关联种公羊耳号", "状态", "备注"], required: ["导入键", "供体名称", "品种"], example: ["示例-donor-01", "杜泊供体01", "CN-DP-001", "杜泊", "R001", "在用", ""]),
        .init(name: "冻精入库", capability: .manageCatalogs, columns: ["导入键", "冻精编号", "品种", "来源", "批号", "数量", "供体登记号"], required: ["导入键", "冻精编号", "品种", "数量"], example: ["示例-semen-01", "S20260701", "杜泊", "种公羊站", "D01", "20", "CN-DP-001"]),
        .init(name: "冻精调整", capability: .manageCatalogs, columns: ["导入键", "冻精编号", "调整数量", "发生日期", "备注"], required: ["导入键", "冻精编号", "调整数量", "发生日期"], example: ["示例-semen-adjust-01", "S20260701", "-1", "2026-07-19", "盘点差异"]),
        .init(name: "繁殖记录", capability: .recordProduction, columns: ["导入键", "类型", "母羊耳号列表", "结果", "种公羊耳号", "冻精编号", "每只冻精数量", "发生日期", "提醒日期", "备注"], required: ["导入键", "类型", "母羊耳号列表", "发生日期"], example: ["示例-repro-01", "配种", "E001;E002", "已配", "R001", "", "", "2026-07-19", "2026-09-02", ""]),
        .init(name: "产羔", capability: .recordProduction, columns: ["导入键", "母羊耳号", "发生日期", "种公羊耳号", "冻精编号", "产羔明细", "圈舍", "备注"], required: ["导入键", "母羊耳号", "发生日期", "产羔明细"], example: ["示例-lambing-01", "E001", "2026-07-19", "R001", "", "L001|母羊|3.4|2026-07-19|是|否;死胎1|未知|2.8|2026-07-19|否|是", "产羔圈", ""]),
        .init(name: "系谱关系", capability: .editHistoricalFacts, columns: ["导入键", "羊只耳号", "母本耳号", "父本来源", "种公羊耳号", "供体登记号", "修改原因"], required: ["导入键", "羊只耳号", "父本来源", "修改原因"], example: ["示例-pedigree-01", "L001", "E001", "种公羊", "R001", "", "核对产羔本后确认"]),
        .init(name: "配种方案", capability: .manageCatalogs, columns: ["导入键", "方案名称", "创建日期", "步骤"], required: ["导入键", "方案名称", "创建日期", "步骤"], example: ["示例-program-01", "同期发情方案", "2026-07-19", "0|放栓;12|撤栓;14|配种"]),
        .init(name: "备注", capability: .recordProduction, columns: ["导入键", "耳号", "圈舍", "内容", "发生日期"], required: ["导入键", "内容", "发生日期"], example: ["示例-note-01", "A001", "", "观察采食情况", "2026-07-19"]),
        .init(name: "提醒规则", capability: .manageCatalogs, columns: ["导入键", "孕检间隔天", "妊娠周期天"], required: ["导入键", "孕检间隔天", "妊娠周期天"], example: ["示例-rule-01", "45", "150"])
    ]

    private static let legacyColumnAliases: [String: [String: [String]]] = [
        "离场": [
            "羊只耳号列表": ["耳号"],
            "总售卖金额": ["金额"],
        ],
    ]

    /// Added in v4. Older workbooks remain importable and use the documented
    /// blank default (0) for a newly imported ewe.
    private static let backwardCompatibleOptionalColumns: [String: Set<String>] = [
        "新建羊只": ["当前胎次"],
    ]

    static func templateData() throws -> Data {
        try templateData(sheetNames: Set(schemas.map(\.name)))
    }

    static func templateData(sheetNames: Set<String>) throws -> Data {
        let selectedSchemas = schemas.filter { sheetNames.contains($0.name) }
        guard !selectedSchemas.isEmpty else { throw FarmDataInterchangeError.malformedFile("没有可导出的录入模板。") }
        let instructions = XLSXSheet(name: "填写说明", rows: [
            ["eSheepNext 全功能录入模板", "版本 \(templateVersion)"],
            ["使用方法", "只填写需要导入的工作表；保留首行字段名；删除或覆盖示例行；日期统一使用 yyyy-MM-dd。"],
            ["导入键", "每行填写本文件内唯一、长期稳定的自定义编号，用于定位问题和生成稳定事实标识。"],
            ["新建羊只核对", "只核对当前牧场已有耳号和本文件内重复耳号；不会要求新耳号预先存在。"],
            ["母羊当前胎次", "新建母羊时填写已经完成的胎次；留空或没有既往胎次事实均按 0 胎处理，首次产羔自动记为第 1 胎。"],
            ["产羔胎次", "产羔表不手填胎次，系统以产羔时间点之前的有效胎次自动加 1。"],
            ["羔羊称重", "填写体重时必须填写实际称重日期；出生 24 小时内记为初生重，超过 24 小时记为普通称重。未称重可同时留空。"],
            ["断奶日增重", "系统以出生后、断奶前最早一条实际称重为起点自动计算；断奶表不填写初生重和日增重。没有有效称重时不计算。"],
            ["断奶调舍", "断奶不填写母本或胎只数；每条断奶必须填写转入圈舍，断奶事实与调舍在同一事务中提交。"],
            ["引用核对", "称重、断奶、转群等事件的耳号，以及圈舍、目录、库存批号、冻精等引用，必须已在当前牧场存在或在本文件前置工作表中创建。"],
            ["批量列表", "多个耳号使用英文分号 ; 分隔。组合明细使用 | 分列、使用 ; 分条。"],
            ["离场批次", "离场表每行代表同一次离场；可填写多个耳号。出售时只填写整批总售卖金额，不填写或推算单羊价格。"],
            ["事务", "整份文件通过权限、业务校验、SwiftData、审计和 Outbox 管道一次提交；任一阻断错误会整批回滚。"],
            ["不支持", "历史修正、撤销、恢复、删除不通过 Excel 执行，请在 App 内逐条确认。"]
        ])
        return try XLSXCodec.encode(sheets: [instructions] + selectedSchemas.map { XLSXSheet(name: $0.name, rows: [$0.columns, $0.example]) })
    }

    static func preview(data: Data, farm: FarmRecord, context: ModelContext, allowedSheetNames: Set<String>? = nil) throws -> FarmExcelPreview {
        let decoded = try XLSXCodec.decodeSheets(data)
        let byName = Dictionary(uniqueKeysWithValues: decoded.map { ($0.name, $0.rows) })
        let selectedSchemas = schemas.filter { allowedSheetNames?.contains($0.name) ?? true }
        var rows: [FarmExcelRow] = [], issues: [FarmExcelIssue] = [], summaries: [FarmExcelSheetSummary] = []
        var keys = Set<String>()
        for schema in selectedSchemas {
            guard let table = byName[schema.name], let header = table.first else { continue }
            let trimmedHeader = header.map(\.trimmed)
            let indexes = Dictionary(uniqueKeysWithValues: trimmedHeader.enumerated().map { ($0.element, $0.offset) })
            let aliases = legacyColumnAliases[schema.name] ?? [:]
            func sourceIndex(for column: String) -> Int? {
                if let index = indexes[column] { return index }
                return aliases[column]?.compactMap { indexes[$0] }.first
            }
            let optionalLegacyColumns = backwardCompatibleOptionalColumns[schema.name] ?? []
            for column in schema.columns where sourceIndex(for: column) == nil && !optionalLegacyColumns.contains(column) {
                issues.append(.init(sheet: schema.name, row: 1, field: column, message: "缺少模板字段“\(column)”。", severity: .error))
            }
            var count = 0
            for (offset, source) in table.dropFirst().enumerated() {
                let rowNumber = offset + 2
                if source.allSatisfy({ $0.trimmed.isEmpty }) || source.first?.trimmed.hasPrefix("示例") == true { continue }
                var values: [String: String] = [:]
                for column in schema.columns { if let index = sourceIndex(for: column), source.indices.contains(index) { values[column] = source[index].trimmed } }
                let row = FarmExcelRow(sheet: schema.name, rowNumber: rowNumber, values: values)
                rows.append(row); count += 1
                for field in schema.required where row[field].isEmpty { issues.append(.init(sheet: schema.name, row: rowNumber, field: field, message: "不能为空。", severity: .error)) }
                let key = row["导入键"].lowercased()
                if !key.isEmpty && !keys.insert(key).inserted { issues.append(.init(sheet: schema.name, row: rowNumber, field: "导入键", message: "与本文件其他行重复。", severity: .error)) }
                if !CapabilitySet(role: farm.role).allows(schema.capability) { issues.append(.init(sheet: schema.name, row: rowNumber, field: "权限", message: "当前角色没有导入此类数据的权限。", severity: .error)) }
                validateFormats(row, issues: &issues)
            }
            if count > 0 { summaries.append(.init(name: schema.name, rowCount: count)) }
        }
        let ignored = Set(decoded.map(\.name).filter { $0 != "填写说明" }).subtracting(Set(selectedSchemas.map(\.name)))
        for name in ignored.sorted() { issues.append(.init(sheet: name, row: 1, field: "工作表", message: "不属于当前录入页面，已忽略。", severity: .warning)) }
        try validateReferences(rows, farmID: farm.id, context: context, issues: &issues)
        return FarmExcelPreview(rows: rows, issues: issues, summaries: summaries)
    }

    private static func validateFormats(_ row: FarmExcelRow, issues: inout [FarmExcelIssue]) {
        let dateFields = ["入场日期", "出生日期", "发生日期", "开始日期", "脱离日期", "有效期", "入库日期", "提醒日期", "创建日期"]
        for field in dateFields where !row[field].isEmpty && parseDate(row[field]) == nil { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: field, message: "请使用 yyyy-MM-dd。", severity: .error)) }
        let positiveFields = ["体重kg", "断奶重kg", "出生重kg", "日增重kg", "总售卖金额", "干物质", "用量kg", "默认剂量", "数量", "每只剂量", "每只冻精数量"]
        for field in positiveFields where !row[field].isEmpty && (Decimal.stable(row[field]).map { $0 > 0 } != true) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: field, message: "必须是大于零的数值。", severity: .error)) }
        for field in ["调整数量"] where !row[field].isEmpty && (Decimal.stable(row[field]).map { $0 != 0 } != true) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: field, message: "必须是非零数值。", severity: .error)) }
        if row.sheet == "新建羊只", !["母羊", "公羊", "未知"].contains(row["性别"]) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "性别", message: "只能填写母羊、公羊或未知。", severity: .error)) }
        if row.sheet == "新建羊只", !row["当前胎次"].isEmpty {
            if Int(row["当前胎次"]).map({ $0 >= 0 }) != true {
                issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "当前胎次", message: "必须是大于或等于 0 的整数。", severity: .error))
            } else if row["性别"] != "母羊" {
                issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "当前胎次", message: "只有母羊可以填写当前胎次。", severity: .error))
            }
        }
        if row.sheet == "离场" {
            if !["出售", "淘汰", "死亡", "转出"].contains(row["类型"]) {
                issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "类型", message: "只能填写出售、淘汰、死亡或转出。", severity: .error))
            }
            if row["类型"] == "出售", row["总售卖金额"].isEmpty {
                issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "总售卖金额", message: "同批出售必须填写一笔总售卖金额。", severity: .error))
            }
            if row["类型"] != "出售", !row["总售卖金额"].isEmpty {
                issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "总售卖金额", message: "只有出售批次可以填写总售卖金额。", severity: .error))
            }
        }
        if ["健康目录", "库存入库", "健康记录"].contains(row.sheet), !["治疗", "疫苗"].contains(row["类型"]) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "类型", message: "只能填写治疗或疫苗。", severity: .error)) }
        if row.sheet == "繁殖记录", !["配种", "孕检", "流产"].contains(row["类型"]) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "类型", message: "只能填写配种、孕检或流产；产羔请使用产羔表。", severity: .error)) }
        if row.sheet == "冻精供体", !row["状态"].isEmpty, !["在用", "停用"].contains(row["状态"]) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "状态", message: "只能填写在用或停用。", severity: .error)) }
        if row.sheet == "系谱关系", !["未知", "种公羊", "冻精供体"].contains(row["父本来源"]) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "父本来源", message: "只能填写未知、种公羊或冻精供体。", severity: .error)) }
    }

    private static func validateReferences(_ rows: [FarmExcelRow], farmID: UUID, context: ModelContext, issues: inout [FarmExcelIssue]) throws {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }
        let currentTags = Set(sheep.map { EarTag.normalized($0.earTag) })
        let newRows = rows.filter { $0.sheet == "新建羊只" }
        var newTags = Set<String>()
        for row in newRows {
            let tag = EarTag.normalized(row["耳号"])
            if currentTags.contains(tag) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "耳号", message: "当前牧场已存在该耳号。", severity: .error)) }
            else if !tag.isEmpty && !newTags.insert(tag).inserted { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "耳号", message: "与本文件其他新建羊只重复。", severity: .error)) }
        }
        let knownTags = currentTags.union(newTags)
        let existingPens = Set(try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { $0.name.normalizedLookup })
        let newPens = Set(rows.filter { $0.sheet == "圈舍" }.map { $0["圈舍名称"].normalizedLookup })
        let knownPens = existingPens.union(newPens)
        let existingIngredients = Set(try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { $0.name.normalizedLookup })
        let knownIngredients = existingIngredients.union(rows.filter { $0.sheet == "饲料原料" }.map { $0["原料名称"].normalizedLookup })
        let existingRecipes = Set(try context.fetch(FetchDescriptor<FeedRecipeRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { $0.name.normalizedLookup })
        let knownRecipes = existingRecipes.union(rows.filter { $0.sheet == "饲料配方" }.map { $0["配方名称"].normalizedLookup })
        let existingCatalogs = Set(try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).filter { $0.farmID == farmID }.map { $0.name.normalizedLookup })
        let knownCatalogs = existingCatalogs.union(rows.filter { $0.sheet == "健康目录" }.map { $0["名称"].normalizedLookup })
        let existingSemen = Set(try context.fetch(FetchDescriptor<SemenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { $0.code.normalizedLookup })
        let knownSemen = existingSemen.union(rows.filter { $0.sheet == "冻精入库" }.map { $0["冻精编号"].normalizedLookup })
        let existingDonorRegistrations = Set(try context.fetch(FetchDescriptor<SemenDonorRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil && !$0.registrationNumber.isEmpty }.map { $0.registrationNumber.normalizedLookup })
        let plannedDonorRegistrations = Set(rows.filter { $0.sheet == "冻精供体" && !$0["登记号"].isEmpty }.map { $0["登记号"].normalizedLookup })
        let knownDonorRegistrations = existingDonorRegistrations.union(plannedDonorRegistrations)
        let existingLots = Set(try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { "\($0.catalogName.normalizedLookup)|\($0.batchNumber.normalizedLookup)" })
        let plannedLots = Set(rows.filter { $0.sheet == "库存入库" }.map { "\($0["目录名称"].normalizedLookup)|\($0["批号"].normalizedLookup)" })
        let knownLots = existingLots.union(plannedLots)
        let existingBatches = Set(try context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }.map { $0.name.normalizedLookup })
        let knownBatches = existingBatches.union(rows.filter { $0.sheet == "生产批次" }.map { $0["批次名称"].normalizedLookup })
        let uniqueMasterFields: [(String, String, Set<String>)] = [
            ("圈舍", "圈舍名称", existingPens), ("饲料原料", "原料名称", existingIngredients),
            ("饲料配方", "配方名称", existingRecipes),
            ("冻精入库", "冻精编号", existingSemen), ("生产批次", "批次名称", existingBatches)
        ]
        for (sheet, field, existingValues) in uniqueMasterFields {
            var seen = Set<String>()
            for row in rows where row.sheet == sheet {
                let value = row[field].normalizedLookup
                if existingValues.contains(value) { issues.append(.init(sheet: sheet, row: row.rowNumber, field: field, message: "当前牧场已存在同名记录。", severity: .error)) }
                else if !value.isEmpty && !seen.insert(value).inserted { issues.append(.init(sheet: sheet, row: row.rowNumber, field: field, message: "与本文件同工作表的其他行重复。", severity: .error)) }
            }
        }
        var donorRegistrationsSeen = Set<String>()
        for row in rows where row.sheet == "冻精供体" && !row["登记号"].isEmpty {
            let registration = row["登记号"].normalizedLookup
            if !donorRegistrationsSeen.insert(registration).inserted { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "登记号", message: "与本文件其他供体登记号重复。", severity: .error)) }
        }
        var removalTagsSeen = Set<String>()
        for row in rows where row.sheet == "离场" {
            for tag in row.listValues("羊只耳号列表") {
                let normalized = EarTag.normalized(tag)
                if !normalized.isEmpty, !removalTagsSeen.insert(normalized).inserted {
                    issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "羊只耳号列表", message: "耳号 \(tag) 在本文件的离场批次中重复。", severity: .error))
                }
            }
        }
        for row in rows {
            let tagFields = ["耳号", "羊只耳号", "母羊耳号", "母本耳号", "种公羊耳号", "关联种公羊耳号", "母羊耳号列表", "羊只耳号列表"]
            if row.sheet != "新建羊只" {
                for field in tagFields where !row[field].isEmpty {
                    for tag in splitList(row[field]) where !knownTags.contains(EarTag.normalized(tag)) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: field, message: "当前牧场及本文件的新建羊只中找不到耳号 \(tag)。", severity: .error)) }
                }
            }
            for field in ["圈舍", "转入圈舍"] where !row[field].isEmpty && !knownPens.contains(row[field].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: field, message: "当前牧场及本文件中找不到该圈舍。", severity: .error)) }
            if row.sheet == "备注", row["耳号"].isEmpty && row["圈舍"].isEmpty { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "对象", message: "耳号或圈舍至少填写一个。", severity: .error)) }
            if row.sheet == "健康记录", row["羊只耳号列表"].isEmpty && row["圈舍"].isEmpty { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "对象", message: "羊只耳号列表或圈舍至少填写一个。", severity: .error)) }
            if row.sheet == "配方组成" {
                if !knownRecipes.contains(row["配方名称"].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "配方名称", message: "当前牧场及本文件中找不到该配方。", severity: .error)) }
                if !knownIngredients.contains(row["原料名称"].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "原料名称", message: "当前牧场及本文件中找不到该原料。", severity: .error)) }
            }
            if row.sheet == "投喂" {
                if !row["配方名称"].isEmpty && !knownRecipes.contains(row["配方名称"].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "配方名称", message: "当前牧场及本文件中找不到该配方。", severity: .error)) }
                if let pairs = try? parsePairs(row["投喂明细"]) {
                    for pair in pairs where !knownIngredients.contains(pair.0.normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "投喂明细", message: "找不到原料 \(pair.0)。", severity: .error)) }
                } else { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "投喂明细", message: "请使用 原料|公斤;原料|公斤 格式。", severity: .error)) }
            }
            if row.sheet == "库存入库", !row["目录名称"].isEmpty && !knownCatalogs.contains(row["目录名称"].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "目录名称", message: "目录不存在，将按库存名称入库但不会绑定健康目录。", severity: .warning)) }
            if row.sheet == "库存调整" {
                let key = "\(row["目录名称"].normalizedLookup)|\(row["批号"].normalizedLookup)"
                if !knownLots.contains(key) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "批号", message: "当前牧场及本文件中找不到唯一库存批次。", severity: .error)) }
            }
            if row.sheet == "健康记录" {
                if !row["目录名称"].isEmpty && !knownCatalogs.contains(row["目录名称"].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "目录名称", message: "当前牧场及本文件中找不到健康目录。", severity: .error)) }
                if !row["库存批号"].isEmpty {
                    let name = row["目录名称"].isEmpty ? row["名称"] : row["目录名称"]
                    if !knownLots.contains("\(name.normalizedLookup)|\(row["库存批号"].normalizedLookup)") { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "库存批号", message: "当前牧场及本文件中找不到唯一库存批次。", severity: .error)) }
                    if row["每只剂量"].isEmpty { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "每只剂量", message: "绑定库存批次时必须填写每只剂量。", severity: .error)) }
                }
            }
            if ["冻精调整", "繁殖记录", "产羔"].contains(row.sheet), !row["冻精编号"].isEmpty && !knownSemen.contains(row["冻精编号"].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "冻精编号", message: "当前牧场及本文件中找不到该冻精。", severity: .error)) }
            if ["冻精入库", "系谱关系"].contains(row.sheet), !row["供体登记号"].isEmpty && !knownDonorRegistrations.contains(row["供体登记号"].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "供体登记号", message: "当前牧场及本文件中找不到该冻精供体。", severity: .error)) }
            if row.sheet == "批次脱离", !knownBatches.contains(row["批次名称"].normalizedLookup) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "批次名称", message: "当前牧场及本文件中找不到该生产批次。", severity: .error)) }
            if ["繁殖记录", "产羔"].contains(row.sheet), !row["种公羊耳号"].isEmpty, !sheep.contains(where: { $0.farmID == farmID && EarTag.normalized($0.earTag) == EarTag.normalized(row["种公羊耳号"]) && $0.sex == .ram && $0.isBreedingRam }) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "种公羊耳号", message: "该耳号未被明确标记为种公羊。", severity: .error)) }
            if row.sheet == "冻精供体", !row["关联种公羊耳号"].isEmpty, !sheep.contains(where: { $0.farmID == farmID && EarTag.normalized($0.earTag) == EarTag.normalized(row["关联种公羊耳号"]) && $0.sex == .ram && $0.isBreedingRam }) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "关联种公羊耳号", message: "供体只能关联已明确标记的种公羊。", severity: .error)) }
            if row.sheet == "繁殖记录", row["类型"] == "配种", row["种公羊耳号"].isEmpty == row["冻精编号"].isEmpty { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "配种来源", message: "本交种公羊与冻精必须二选一。", severity: .error)) }
            if row.sheet == "繁殖记录", row["类型"] != "配种", (!row["种公羊耳号"].isEmpty || !row["冻精编号"].isEmpty) { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "配种来源", message: "孕检和流产不能确认父本；请在 App 内关联原配种记录。", severity: .error)) }
            if row.sheet == "产羔", !row["种公羊耳号"].isEmpty && !row["冻精编号"].isEmpty { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "父本来源", message: "种公羊与冻精必须二选一。", severity: .error)) }
            if row.sheet == "系谱关系" {
                let source = row["父本来源"]
                if source == "未知", !row["种公羊耳号"].isEmpty || !row["供体登记号"].isEmpty { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "父本来源", message: "父本未知时不能填写种公羊或供体。", severity: .error)) }
                if source == "种公羊", row["种公羊耳号"].isEmpty || !row["供体登记号"].isEmpty { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "父本来源", message: "种公羊来源必须且只能填写种公羊耳号。", severity: .error)) }
                if source == "冻精供体", row["供体登记号"].isEmpty || !row["种公羊耳号"].isEmpty { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "父本来源", message: "冻精供体来源必须且只能填写供体登记号。", severity: .error)) }
            }
            if row.sheet == "产羔" {
                guard let lambingAt = parseDate(row["发生日期"]),
                      (try? parseLambs(row["产羔明细"], parentID: UUID(), lambingAt: lambingAt)) != nil else {
                    issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "产羔明细", message: "请使用 耳号|性别|体重|称重日期|建档|死胎 格式。", severity: .error))
                    continue
                }
            }
            if row.sheet == "配种方案", (try? parsePairs(row["步骤"])) == nil { issues.append(.init(sheet: row.sheet, row: row.rowNumber, field: "步骤", message: "请使用 天数|操作;天数|操作 格式。", severity: .error)) }
        }
    }

    static func commit(_ preview: FarmExcelPreview, account: AccountProfile, farm: FarmRecord, context: ModelContext, commandService: FarmCommandService = FarmCommandService()) throws -> Int {
        guard preview.canCommit else { throw FarmDataInterchangeError.malformedFile("预检仍有阻断错误。") }
        let order = Dictionary(uniqueKeysWithValues: schemas.enumerated().map { ($0.element.name, $0.offset) })
        let rows = preview.rows.sorted { (order[$0.sheet] ?? 999, $0.rowNumber) < (order[$1.sheet] ?? 999, $1.rowNumber) }
        var index = 0
        var followups: [ExcelFollowup] = []
        var followupIndex = 0
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
        try commandService.executeBatch(in: farmContext, context: context) {
            if followups.indices.contains(followupIndex) {
                defer { followupIndex += 1 }
                return try followupCommand(followups[followupIndex], farmID: farm.id, context: context)
            }
            guard rows.indices.contains(index) else { return nil }
            let row = rows[index]; index += 1
            if row.sheet == "离场" {
                let commands = try removalCommands(for: row, farmID: farm.id, context: context)
                guard let first = commands.first else {
                    throw FarmDataInterchangeError.malformedFile("离场批次没有可导入的羊只。")
                }
                followups.append(contentsOf: commands.dropFirst().map(ExcelFollowup.command))
                return first
            }
            if row.sheet == "断奶" {
                let commands = try weaningCommands(for: row, farmID: farm.id, context: context)
                guard let first = commands.first else {
                    throw FarmDataInterchangeError.malformedFile("断奶记录缺少可提交的操作。")
                }
                followups.append(contentsOf: commands.dropFirst().map(ExcelFollowup.command))
                return first
            }
            if row.sheet == "冻精供体", !row["关联种公羊耳号"].isEmpty,
               try existingDonor(for: row, farmID: farm.id, context: context) == nil {
                followups.append(.linkNewDonor(row))
            }
            if row.sheet == "冻精入库", !row["供体登记号"].isEmpty {
                followups.append(.linkSemenDonor(row))
            }
            return try command(for: row, farmID: farm.id, context: context)
        }
        return preview.expandedRecordCount
    }

    private enum ExcelFollowup {
        case command(FarmCommand)
        case linkNewDonor(FarmExcelRow)
        case linkSemenDonor(FarmExcelRow)
    }

    private static func followupCommand(_ followup: ExcelFollowup, farmID: UUID, context: ModelContext) throws -> FarmCommand {
        switch followup {
        case .command(let command):
            return command
        case .linkNewDonor(let row):
            let id = stableImportID(farmID: farmID, sheet: row.sheet, key: row["导入键"])
            guard let ram = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && EarTag.normalized($0.earTag) == EarTag.normalized(row["关联种公羊耳号"]) }) else { throw FarmCommandError.sheepNotFound }
            return .care(.upsertSemenDonor(.init(id: id, name: row["供体名称"], registrationNumber: row["登记号"], breed: row["品种"], linkedRamID: ram.id, note: row["备注"], status: row["状态"] == "停用" ? .inactive : .active, expectedRevision: 1)))
        case .linkSemenDonor(let row):
            guard let semen = try context.fetch(FetchDescriptor<SemenRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.code.normalizedLookup == row["冻精编号"].normalizedLookup }) else { throw FarmCommandError.missingRequiredValue("冻精") }
            guard let donor = try context.fetch(FetchDescriptor<SemenDonorRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.registrationNumber.normalizedLookup == row["供体登记号"].normalizedLookup }) else { throw FarmCommandError.semenDonorNotFound }
            return .care(.setSemenDonor(semenID: semen.id, donorID: donor.id, expectedRevision: semen.revision))
        }
    }

    private static func command(for row: FarmExcelRow, farmID: UUID, context: ModelContext) throws -> FarmCommand {
        func sheep(_ tag: String) throws -> SheepRecord { guard let value = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && EarTag.normalized($0.earTag) == EarTag.normalized(tag) }) else { throw FarmCommandError.sheepNotFound }; return value }
        func pen(_ name: String) throws -> PenRecord { guard let value = try context.fetch(FetchDescriptor<PenRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.name.normalizedLookup == name.normalizedLookup }) else { throw FarmCommandError.penNotFound }; return value }
        func ingredient(_ name: String) throws -> FeedIngredientRecord { guard let value = try context.fetch(FetchDescriptor<FeedIngredientRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.name.normalizedLookup == name.normalizedLookup }) else { throw FarmCommandError.ingredientNotFound }; return value }
        func recipe(_ name: String) throws -> FeedRecipeRecord { guard let value = try context.fetch(FetchDescriptor<FeedRecipeRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.name.normalizedLookup == name.normalizedLookup }) else { throw FarmCommandError.missingRequiredValue("配方") }; return value }
        func semen(_ code: String) throws -> SemenRecord { guard let value = try context.fetch(FetchDescriptor<SemenRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.code.normalizedLookup == code.normalizedLookup }) else { throw FarmCommandError.missingRequiredValue("冻精") }; return value }
        func donor(_ registration: String) throws -> SemenDonorRecord { guard let value = try context.fetch(FetchDescriptor<SemenDonorRecord>()).first(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.registrationNumber.normalizedLookup == registration.normalizedLookup }) else { throw FarmCommandError.semenDonorNotFound }; return value }
        func catalog(_ name: String) throws -> HealthCatalogItemRecord { guard let value = try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).first(where: { $0.farmID == farmID && $0.name.normalizedLookup == name.normalizedLookup }) else { throw FarmCommandError.missingRequiredValue("健康目录") }; return value }
        func lot(_ name: String, _ batch: String) throws -> InventoryLotRecord { let matches = try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil && $0.catalogName.normalizedLookup == name.normalizedLookup && $0.batchNumber.normalizedLookup == batch.normalizedLookup }; guard matches.count == 1, let value = matches.first else { throw FarmCommandError.inventoryLotNotFound }; return value }
        let id = stableImportID(farmID: farmID, sheet: row.sheet, key: row["导入键"])
        switch row.sheet {
        case "圈舍": return .createPen(name: row["圈舍名称"], note: row["备注"])
        case "新建羊只":
            let sex = sheepSex(row["性别"])
            return .addSheep(earTag: row["耳号"], breed: row["品种"], sex: sex, penID: try optionalPen(row["圈舍"], pen: pen)?.id, occurredAt: parseDate(row["入场日期"])!, birthAt: parseDate(row["出生日期"]), currentParity: sex == .ewe ? (Int(row["当前胎次"]) ?? 0) : nil, note: row["备注"])
        case "称重": return .recordWeight(sheepID: try sheep(row["耳号"]).id, kilogramsText: row["体重kg"], occurredAt: parseDate(row["发生日期"])!, note: row["备注"])
        case "断奶":
            guard let command = try weaningCommands(for: row, farmID: farmID, context: context).first else {
                throw FarmDataInterchangeError.malformedFile("断奶记录缺少可提交的操作。")
            }
            return command
        case "转群": return .transferSheep(sheepID: try sheep(row["耳号"]).id, toPenID: try pen(row["转入圈舍"]).id, occurredAt: parseDate(row["发生日期"])!, note: row["备注"])
        case "离场":
            guard let command = try removalCommands(for: row, farmID: farmID, context: context).first else {
                throw FarmDataInterchangeError.malformedFile("离场批次没有可导入的羊只。")
            }
            return command
        case "生产批次": return .createBatch(name: row["批次名称"], purpose: row["生产目的"], startedAt: parseDate(row["开始日期"])!, sheepIDs: try splitList(row["羊只耳号列表"]).map { try sheep($0).id }, note: row["备注"])
        case "批次脱离": let batch = try context.fetch(FetchDescriptor<ProductionBatchRecord>()).first { $0.farmID == farmID && $0.deletedAt == nil && $0.name.normalizedLookup == row["批次名称"].normalizedLookup }; guard let batch else { throw FarmCommandError.batchNotFound }; return .leaveBatch(batchID: batch.id, sheepID: try sheep(row["耳号"]).id, leftAt: parseDate(row["脱离日期"])!, reason: row["原因"])
        case "饲料原料": return .addIngredient(name: row["原料名称"], unit: row["单位"], dryMatterText: row["干物质"].nilIfEmpty)
        case "饲料配方": return .createRecipe(name: row["配方名称"], note: row["备注"])
        case "配方组成": return .addRecipeComponent(recipeID: try recipe(row["配方名称"]).id, ingredientID: try ingredient(row["原料名称"]).id, kilogramsText: row["用量kg"])
        case "投喂": let lines = try parsePairs(row["投喂明细"]).map { FeedLineDraft(ingredientID: try ingredient($0.0).id, kilogramsText: $0.1) }; return .recordFeed(penID: try pen(row["圈舍"]).id, recipeID: try row["配方名称"].nilIfEmpty.map { try recipe($0).id }, mode: row["方式"] == "自由采食" ? .freeChoice : .limited, occurredAt: parseDate(row["发生日期"])!, lines: lines, note: row["备注"])
        case "健康目录": let existingID = try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).first { $0.farmID == farmID && $0.name.normalizedLookup == row["名称"].normalizedLookup }?.id; return .care(.upsertHealthCatalog(id: existingID ?? id, kindRawValue: healthKind(row["类型"]).rawValue, name: row["名称"], category: row["类别"], unit: row["单位"], defaultDoseText: row["默认剂量"].nilIfEmpty, defaultRoute: row["给药途径"], reminderIntervalDays: Int(row["复免间隔天"]), note: row["备注"], isActive: row["启用"] != "否"))
        case "库存入库": return .care(.receiveInventory(id: id, catalogName: row["目录名称"], catalogItemID: try? catalog(row["目录名称"]).id, kindRawValue: healthKind(row["类型"]).rawValue, batchNumber: row["批号"], supplier: row["供应商"], unit: row["单位"], expiresAt: parseDate(row["有效期"]), quantityText: row["数量"], occurredAt: parseDate(row["入库日期"])!, note: row["备注"]))
        case "库存调整": return .care(.adjustInventory(id: id, lotID: try lot(row["目录名称"], row["批号"]).id, quantityDeltaText: row["调整数量"], occurredAt: parseDate(row["发生日期"])!, note: row["备注"]))
        case "健康记录": let subjects = try splitList(row["羊只耳号列表"]).map { try sheep($0).id }; let catalogItem = try row["目录名称"].nilIfEmpty.map(catalog); let inventory = try row["库存批号"].nilIfEmpty.map { try lot(row["目录名称"].isEmpty ? row["名称"] : row["目录名称"], $0) }; return .care(.recordHealth(.init(id: id, batchID: StableCloudUUID.derived(namespace: id, name: "batch"), subjectIDs: subjects, penID: try optionalPen(row["圈舍"], pen: pen)?.id, catalogItemID: catalogItem?.id, kind: healthKind(row["类型"]), itemName: row["名称"], occurredAt: parseDate(row["发生日期"])!, note: row["备注"], inventoryLotID: inventory?.id, dosePerSubjectText: row["每只剂量"].nilIfEmpty, unit: row["单位"], route: row["给药途径"], reminderAt: parseDate(row["提醒日期"]))))
        case "冻精供体": let existing = try existingDonor(for: row, farmID: farmID, context: context); let ramID = try row["关联种公羊耳号"].nilIfEmpty.map { try sheep($0).id }; return .care(.upsertSemenDonor(.init(id: existing?.id ?? id, name: row["供体名称"], registrationNumber: row["登记号"], breed: row["品种"], linkedRamID: existing == nil ? nil : ramID, note: row["备注"], status: row["状态"] == "停用" ? .inactive : .active, expectedRevision: existing?.revision ?? 0)))
        case "冻精入库": return .addSemen(code: row["冻精编号"], breed: row["品种"], source: row["来源"], batchNumber: row["批号"], quantityText: row["数量"])
        case "冻精调整": return .care(.adjustSemen(id: id, semenID: try semen(row["冻精编号"]).id, quantityDeltaText: row["调整数量"], occurredAt: parseDate(row["发生日期"])!, note: row["备注"]))
        case "繁殖记录": let subjects = try splitList(row["母羊耳号列表"]).map { CareReproductionSubjectDraft(id: StableCloudUUID.derived(namespace: id, name: EarTag.normalized($0)), eweID: try sheep($0).id, result: row["结果"]) }; return .care(.recordReproductionBatch(.init(id: id, kind: reproductionKind(row["类型"]), subjects: subjects, occurredAt: parseDate(row["发生日期"])!, sireID: try row["种公羊耳号"].nilIfEmpty.map { try sheep($0).id }, semenID: try row["冻精编号"].nilIfEmpty.map { try semen($0).id }, semenUnitsPerEweText: row["每只冻精数量"].nilIfEmpty, note: row["备注"], reminderAt: parseDate(row["提醒日期"]))))
        case "产羔":
            let occurredAt = parseDate(row["发生日期"])!
            let ewe = try sheep(row["母羊耳号"])
            let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>())
            let currentParity = LambingEntrySemantics.currentParity(eweID: ewe.id, farmID: farmID, before: occurredAt, records: reproduction)
            let lambs = try parseLambs(row["产羔明细"], parentID: id, lambingAt: occurredAt)
            return .care(.recordLambing(.init(id: id, eweID: ewe.id, occurredAt: occurredAt, sireID: try row["种公羊耳号"].nilIfEmpty.map { try sheep($0).id }, semenID: try row["冻精编号"].nilIfEmpty.map { try semen($0).id }, parity: currentParity + 1, birthDeadCount: lambs.count { $0.isStillborn }, offspring: lambs, penID: try optionalPen(row["圈舍"], pen: pen)?.id, note: row["备注"])))
        case "系谱关系": let child = try sheep(row["羊只耳号"]); let source = row["父本来源"]; return .care(.updateSheepPedigree(.init(id: id, sheepID: child.id, damID: try row["母本耳号"].nilIfEmpty.map { try sheep($0).id }, sireID: source == "种公羊" ? try sheep(row["种公羊耳号"]).id : nil, semenDonorID: source == "冻精供体" ? try donor(row["供体登记号"]).id : nil, reason: row["修改原因"], expectedRevision: child.revision)))
        case "配种方案": return .createBreedingProgram(name: row["方案名称"], createdAt: parseDate(row["创建日期"])!, steps: try parsePairs(row["步骤"]).map { guard let day = Int($0.0) else { throw FarmDataInterchangeError.malformedFile("配种方案步骤天数无效。") }; return BreedingProgramStepDraft(dayOffset: day, action: $0.1) })
        case "备注": return .addNote(sheepID: try row["耳号"].nilIfEmpty.map { try sheep($0).id }, penID: try optionalPen(row["圈舍"], pen: pen)?.id, text: row["内容"], occurredAt: parseDate(row["发生日期"])!)
        case "提醒规则": let existingID = try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first { $0.farmID == farmID }?.id; return .care(.updateRules(id: existingID ?? id, pregnancyCheckDays: Int(row["孕检间隔天"]) ?? 0, gestationDays: Int(row["妊娠周期天"]) ?? 0))
        default: throw FarmDataInterchangeError.malformedFile("不支持的工作表 \(row.sheet)。")
        }
    }

    private static func removalCommands(for row: FarmExcelRow, farmID: UUID, context: ModelContext) throws -> [FarmCommand] {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let sheepByTag = Dictionary(uniqueKeysWithValues: sheep.map { (EarTag.normalized($0.earTag), $0) })
        let batchID = StableCloudUUID.derived(
            namespace: farmID,
            name: "excel-v\(stableIdentityVersion):离场:\(row["导入键"].lowercased()):batch"
        )
        let kind = removalKind(row["类型"])
        let batchTotal = kind == .sold ? row["总售卖金额"].nilIfEmpty : nil
        return try row.listValues("羊只耳号列表").map { tag in
            let normalizedTag = EarTag.normalized(tag)
            guard let sheep = sheepByTag[normalizedTag] else { throw FarmCommandError.sheepNotFound }
            let recordID = StableCloudUUID.derived(namespace: batchID, name: "member:\(normalizedTag)")
            return .removeSheep(
                sheepID: sheep.id,
                kind: kind,
                reason: row["原因"],
                amountText: nil,
                occurredAt: parseDate(row["发生日期"])!,
                note: row["备注"],
                recordID: recordID,
                removalBatchID: batchID,
                batchTotalAmountText: batchTotal
            )
        }
    }

    private static func weaningCommands(
        for row: FarmExcelRow,
        farmID: UUID,
        context: ModelContext
    ) throws -> [FarmCommand] {
        guard let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: {
            $0.farmID == farmID &&
                $0.deletedAt == nil &&
                EarTag.normalized($0.earTag) == EarTag.normalized(row["耳号"])
        }) else {
            throw FarmCommandError.sheepNotFound
        }
        guard let pen = try context.fetch(FetchDescriptor<PenRecord>()).first(where: {
            $0.farmID == farmID &&
                $0.deletedAt == nil &&
                $0.isActive &&
                $0.name.normalizedLookup == row["转入圈舍"].normalizedLookup
        }) else {
            throw FarmCommandError.penNotFound
        }
        guard let occurredAt = parseDate(row["发生日期"]) else {
            throw FarmDataInterchangeError.malformedFile("断奶发生日期无效。")
        }
        return WeaningWorkflow.commands(
            sheepID: sheep.id,
            weanWeightText: row["断奶重kg"],
            occurredAt: occurredAt,
            birthAt: parseDate(row["出生日期"]),
            toPenID: pen.id,
            note: row["备注"]
        )
    }

    private static func existingDonor(for row: FarmExcelRow, farmID: UUID, context: ModelContext) throws -> SemenDonorRecord? {
        let donors = try context.fetch(FetchDescriptor<SemenDonorRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        if !row["登记号"].isEmpty, let match = donors.first(where: { $0.registrationNumber.normalizedLookup == row["登记号"].normalizedLookup }) { return match }
        return donors.first { $0.name.normalizedLookup == row["供体名称"].normalizedLookup }
    }

    private static func optionalPen(_ value: String, pen: (String) throws -> PenRecord) throws -> PenRecord? { value.isEmpty ? nil : try pen(value) }

    static func stableImportID(farmID: UUID, sheet: String, key: String) -> UUID {
        StableCloudUUID.derived(
            namespace: farmID,
            name: "excel-v\(stableIdentityVersion):\(sheet):\(key.lowercased())"
        )
    }

    private static func splitList(_ value: String) -> [String] { value.components(separatedBy: CharacterSet(charactersIn: ";；,，、\n")).map(\.trimmed).filter { !$0.isEmpty } }
    private static func parsePairs(_ value: String) throws -> [(String, String)] { try splitList(value).map { let parts = $0.split(separator: "|", maxSplits: 1).map { String($0).trimmed }; guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw FarmDataInterchangeError.malformedFile("组合明细必须使用 名称|数值 格式。") }; return (parts[0], parts[1]) } }
    private static func parseLambs(_ value: String, parentID: UUID, lambingAt: Date) throws -> [CareLambDraft] {
        try splitList(value).enumerated().map { index, item in
            let parts = item.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmed }
            guard parts.count == 5 || parts.count == 6 else {
                throw FarmDataInterchangeError.malformedFile("产羔明细必须使用 耳号|性别|体重|称重日期|建档|死胎 格式；旧版五段格式仍按产羔当日称重处理。")
            }
            let sex = sheepSex(parts[1])
            guard sex != .unknown || parts[1] == "未知" else {
                throw FarmDataInterchangeError.malformedFile("羔羊性别无效。")
            }
            let hasWeightDate = parts.count == 6
            let weightDate = hasWeightDate ? (parts[3].isEmpty ? nil : parseDate(parts[3])) : lambingAt
            if hasWeightDate, !parts[2].isEmpty, weightDate == nil {
                throw FarmDataInterchangeError.malformedFile("填写羔羊体重时，称重日期不能为空且必须有效。")
            }
            let createIndex = hasWeightDate ? 4 : 3
            let stillbornIndex = hasWeightDate ? 5 : 4
            return CareLambDraft(
                id: StableCloudUUID.derived(namespace: parentID, name: "lamb-detail-\(index)"),
                sheepID: StableCloudUUID.derived(namespace: parentID, name: "lamb-sheep-\(index)"),
                earTag: parts[0],
                sex: sex,
                birthWeightText: parts[2],
                weightOccurredAt: parts[2].isEmpty ? nil : weightDate,
                createSheepRecord: parts[createIndex] == "是",
                isStillborn: parts[stillbornIndex] == "是"
            )
        }
    }
    private static func parseDate(_ value: String) -> Date? { guard !value.isEmpty else { return nil }; let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.isLenient = false; formatter.dateFormat = "yyyy-MM-dd"; if let date = formatter.date(from: value), formatter.string(from: date) == value { return date }; guard let serial = Double(value), serial >= 1, serial < 2_958_466 else { return nil }; var components = DateComponents(); components.calendar = Calendar(identifier: .gregorian); components.timeZone = TimeZone(secondsFromGMT: 0); components.year = 1899; components.month = 12; components.day = 30; return components.date?.addingTimeInterval(serial * 86_400) }
    private static func sheepSex(_ value: String) -> SheepSex { value == "母羊" ? .ewe : (value == "公羊" ? .ram : .unknown) }
    private static func healthKind(_ value: String) -> HealthRecordKind { value == "疫苗" ? .vaccination : .treatment }
    private static func reproductionKind(_ value: String) -> ReproductionRecordKind { value == "孕检" ? .pregnancyCheck : (value == "流产" ? .abortion : .breeding) }
    private static func removalKind(_ value: String) -> RemovalKind { value == "淘汰" ? .culled : (value == "死亡" ? .deceased : (value == "转出" ? .transferredOut : .sold)) }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : trimmed }
    var normalizedLookup: String { trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN")) }
}
