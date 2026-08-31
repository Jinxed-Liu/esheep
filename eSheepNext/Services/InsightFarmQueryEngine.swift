import Foundation
import SwiftData

/// A deliberately bounded query surface for the assistant. The model may compose
/// filters, grouping and metrics, but all data access and arithmetic stay local.
struct InsightFarmQueryEngine {
    static let toolName = "query_farm_data"
    static let persistedEvidenceToolName = "query_farm_data_evidence"

    struct GroundedOutput: Equatable {
        let queryID: String
        let queryKind: String
        let subject: String
        let markdown: String
        let rowCount: Int
        let totalMatchingCount: Int
        let isComplete: Bool
        let contractVersion: String
        let canonicalArgumentsJSON: String
        let timeZoneIdentifier: String
        let stateBasis: [String]
        let unknownStateCount: Int
        let projectionMismatchCount: Int

        init?(toolOutput: String) {
            guard let data = toolOutput.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["evidence_kind"] as? String == "farm_query",
                  let queryID = object["query_id"] as? String,
                  let queryKind = object["query_kind"] as? String,
                  let subject = object["subject"] as? String,
                  let markdown = object["answer_markdown"] as? String,
                  let rowCount = object["row_count"] as? Int,
                  let totalMatchingCount = object["total_matching_count"] as? Int,
                  let isComplete = object["is_complete"] as? Bool,
                  let contractVersion = object["contract_version"] as? String,
                  contractVersion == FarmFactContract.version,
                  let canonicalArguments = object["canonical_arguments"] as? [String: Any],
                  let canonicalData = try? JSONSerialization.data(
                    withJSONObject: canonicalArguments,
                    options: [.sortedKeys]
                  ),
                  let timeZoneIdentifier = object["time_zone"] as? String,
                  let stateBasis = object["state_basis"] as? [String],
                  let unknownStateCount = object["unknown_state_count"] as? Int,
                  let projectionMismatchCount = object["projection_mismatch_count"] as? Int else {
                return nil
            }
            self.queryID = queryID
            self.queryKind = queryKind
            self.subject = subject
            self.markdown = markdown
            self.rowCount = rowCount
            self.totalMatchingCount = totalMatchingCount
            self.isComplete = isComplete
            self.contractVersion = contractVersion
            self.canonicalArgumentsJSON = String(decoding: canonicalData, as: UTF8.self)
            self.timeZoneIdentifier = timeZoneIdentifier
            self.stateBasis = stateBasis
            self.unknownStateCount = unknownStateCount
            self.projectionMismatchCount = projectionMismatchCount
        }
    }

    static func canonicalArguments(in toolOutput: String) -> [String: Any]? {
        guard let data = toolOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["evidence_kind"] as? String == "farm_query",
              object["contract_version"] as? String == FarmFactContract.version else {
            return nil
        }
        return object["canonical_arguments"] as? [String: Any]
    }

    private struct Request {
        let queryKind: String
        let subject: String
        let dateField: String
        let dateFrom: Date?
        let dateTo: Date?
        let asOf: Date
        let earTag: String
        let sex: String
        let status: String
        let breed: String
        let penName: String
        let kind: String
        let itemName: String
        let groupBy: String
        let metric: String
        let minimumValue: Decimal?
        let maximumValue: Decimal?
        let relations: [RelationRequest]
        let limit: Int
        let timeZone: TimeZone
        let timeZoneIdentifier: String
        let stateCutoff: FarmFactContract.StateCutoff
        let canonicalArguments: [String: Any]
    }

    private struct RelationRequest {
        let subject: String
        let kind: String
        let itemName: String
        let dateFrom: Date?
        let dateTo: Date?
        let existence: String
        let minimumCount: Int
        let maximumCount: Int?
        let minimumValue: Decimal?
        let maximumValue: Decimal?
    }

    private struct Row {
        let values: [String: String]
        let group: String
        let number: Decimal?
    }

    private struct FactAudit {
        var stateBasis = Set<String>()
        var unknownStateCount = 0
        var projectionMismatchCount = 0

        static let empty = FactAudit()
    }

    private struct RowResult {
        let rows: [Row]
        let audit: FactAudit
    }

    func execute(
        arguments: [String: Any],
        farmID: UUID,
        context: ModelContext,
        now: Date = .now
    ) throws -> String {
        let normalizedArguments = try FarmDataQuerySkill.normalize(arguments: arguments)
        let farmTimeZone = try farmTimeZone(farmID: farmID, context: context)
        let request = try parse(
            normalizedArguments,
            now: now,
            timeZone: farmTimeZone.value,
            timeZoneIdentifier: farmTimeZone.identifier
        )
        if request.queryKind == FarmDataQuerySkill.QueryKind.bornLambLifecycle.rawValue {
            return try bornLambLifecycleOutput(
                request,
                farmID: farmID,
                context: context,
                now: now
            )
        }
        guard request.subject == "sheep" || request.relations.isEmpty else {
            throw InsightToolError.invalidArguments("relations")
        }
        let rows: [Row]
        let columns: [(key: String, title: String)]
        let subjectName: String
        var audit = FactAudit.empty

        switch request.subject {
        case "sheep":
            subjectName = "羊只"
            columns = [
                ("ear_tag", "耳号"), ("sex", "性别"), ("breed", "品种"),
                ("status", "状态"), ("pen", "圈舍"), ("birth_at", "出生日期"),
            ]
            let result = try sheepRows(request, farmID: farmID, context: context)
            rows = result.rows
            audit = result.audit
        case "weights":
            subjectName = "称重"
            columns = [
                ("occurred_at", "日期"), ("ear_tag", "耳号"),
                ("kilograms", "体重(kg)"), ("pen", "当日圈舍"),
            ]
            rows = try weightRows(request, farmID: farmID, context: context)
        case "reproduction":
            subjectName = "繁殖记录"
            columns = [
                ("occurred_at", "日期"), ("ear_tag", "母羊耳号"),
                ("kind", "类型"), ("lamb_count", "羔羊数"),
                ("parity", "胎次"), ("result", "结果"),
            ]
            rows = try reproductionRows(request, farmID: farmID, context: context)
        case "health":
            subjectName = "健康记录"
            columns = [
                ("occurred_at", "日期"), ("ear_tag", "耳号"),
                ("pen", "圈舍"), ("kind", "类型"),
                ("item", "项目"), ("quantity", "用量"),
            ]
            rows = try healthRows(request, farmID: farmID, context: context)
        case "feeding":
            subjectName = "饲喂记录"
            columns = [
                ("occurred_at", "日期"), ("pen", "圈舍"),
                ("ingredient", "原料"), ("kilograms", "数量(kg)"),
                ("meal", "餐次"),
            ]
            rows = try feedingRows(request, farmID: farmID, context: context)
        case "inventory":
            subjectName = "健康库存"
            columns = [
                ("item", "项目"), ("batch", "批号"), ("kind", "类型"),
                ("quantity", "当前数量"), ("unit", "单位"), ("expires_at", "到期日"),
            ]
            rows = try inventoryRows(request, farmID: farmID, context: context)
        default:
            throw InsightToolError.invalidArguments("subject")
        }

        let totalCount = rows.count
        let limitedRows = Array(rows.prefix(request.limit))
        let rendersAggregate = request.groupBy != "none" || request.metric != "records"
        let renderedRows = rendersAggregate ? rows : limitedRows
        let complete = rendersAggregate || totalCount <= request.limit
        let queryID = UUID().uuidString.lowercased()
        let markdown = renderMarkdown(
            subjectName: subjectName,
            request: request,
            rows: renderedRows,
            totalCount: totalCount,
            columns: columns,
            isComplete: complete
        )
        let object: [String: Any] = [
            "evidence_kind": "farm_query",
            "query_id": queryID,
            "contract_version": FarmFactContract.version,
            "query_kind": request.queryKind,
            "farm_id": farmID.uuidString.lowercased(),
            "executed_at": Self.iso8601(now),
            "as_of": Self.iso8601(request.asOf),
            "time_zone": request.timeZoneIdentifier,
            "state_cutoff_basis": request.stateCutoff.evidenceName,
            "state_basis": audit.stateBasis.sorted(),
            "unknown_state_count": audit.unknownStateCount,
            "projection_mismatch_count": audit.projectionMismatchCount,
            "data_origin": "device_swiftdata",
            "subject": request.subject,
            "source_description": sourceDescription(request),
            "filters_applied": filterDescriptions(request),
            "metric": request.metric,
            "group_by": request.groupBy,
            "row_count": renderedRows.count,
            "total_matching_count": totalCount,
            "is_complete": complete,
            "completeness": complete ? "complete" : "limited",
            "canonical_arguments": request.canonicalArguments,
            "answer_markdown": markdown,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 64 * 1_024 else { throw InsightToolError.resultTooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private func bornLambLifecycleOutput(
        _ request: Request,
        farmID: UUID,
        context: ModelContext,
        now: Date
    ) throws -> String {
        let lambingRecords = try context.fetch(FetchDescriptor<ReproductionRecord>()).filter {
            $0.farmID == farmID
                && $0.deletedAt == nil
                && $0.kind == .lambing
                && $0.occurredAt <= request.asOf
                && inDateRange($0.occurredAt, request)
        }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            guard $0.farmID == farmID,
                  $0.deletedAt == nil,
                  $0.enteredAt <= request.asOf,
                  let birthAt = $0.birthAt,
                  birthAt <= request.asOf else { return false }
            return inDateRange(birthAt, request)
        }
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt <= request.asOf
        }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt <= request.asOf
        }
        let removalsBySheepID = Dictionary(grouping: removals, by: \.sheepID)
        let transfersBySheepID = Dictionary(grouping: transfers, by: \.sheepID)

        var bornByMonth: [String: Int] = [:]
        for record in lambingRecords {
            bornByMonth[Self.month(record.occurredAt, timeZone: request.timeZone), default: 0] += record.lambCount
        }

        var profilesByMonth: [String: Int] = [:]
        var activeByMonth: [String: Int] = [:]
        var deceasedByMonth: [String: Int] = [:]
        var soldByMonth: [String: Int] = [:]
        var culledByMonth: [String: Int] = [:]
        var transferredByMonth: [String: Int] = [:]
        var unknownRemovalByMonth: [String: Int] = [:]
        var audit = FactAudit.empty
        for item in sheep {
            guard let birthAt = item.birthAt else { continue }
            let fact = FarmSheepStateResolver.current(
                item,
                at: request.asOf,
                transfers: transfersBySheepID[item.id] ?? [],
                removals: removalsBySheepID[item.id] ?? []
            )
            audit.stateBasis.insert(fact.basis.rawValue)
            guard fact.isIncluded else { continue }
            if !fact.presenceProjectionMatchesStoredState ||
                !fact.statusProjectionMatchesStoredState {
                audit.projectionMismatchCount += 1
            }
            let month = Self.month(birthAt, timeZone: request.timeZone)
            profilesByMonth[month, default: 0] += 1
            switch fact.status {
            case .active:
                activeByMonth[month, default: 0] += 1
            case .deceased:
                deceasedByMonth[month, default: 0] += 1
            case .removed:
                switch fact.removalKind {
                case .deceased: deceasedByMonth[month, default: 0] += 1
                case .sold: soldByMonth[month, default: 0] += 1
                case .culled: culledByMonth[month, default: 0] += 1
                case .transferredOut: transferredByMonth[month, default: 0] += 1
                case nil: unknownRemovalByMonth[month, default: 0] += 1
                }
            case nil:
                audit.unknownStateCount += 1
            }
        }

        guard audit.projectionMismatchCount == 0 else {
            throw InsightToolError.farmFactsUnavailable(
                "有 \(audit.projectionMismatchCount) 只羊的当前档案与事件流水不一致，已停止计算生命周期数量。"
            )
        }

        let months = Set(monthBuckets(request))
            .union(bornByMonth.keys)
            .union(profilesByMonth.keys)
            .sorted()
        let rangeStart = request.dateFrom.map { Self.day($0, timeZone: request.timeZone) } ?? "不限"
        let rangeEnd = request.dateTo.map { Self.day($0, timeZone: request.timeZone) }
            ?? Self.day(request.asOf, timeZone: request.timeZone)
        var lines = [
            "查询结果：出生羔羊及当前生命周期状态",
            "",
            "- 出生数来源：当前设备 SwiftData · 产羔记录 ReproductionRecord.lambCount",
            "- 状态数来源：当前设备 SwiftData · \(FarmFactContract.version) 当前状态规则",
            "- 牧场时区：\(request.timeZoneIdentifier)",
            "- 日期范围：\(rangeStart) 至 \(rangeEnd)",
            "- 状态截止：\(Self.iso8601(request.asOf))",
            "- 完整性：完整结果",
            "",
            "| 出生月份 | 产羔记录出生数 | 已建档羔羊 | 现在在群 | 死亡 | 出售 | 淘汰 | 转出 | 离群类型未明 |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
        lines += months.map { month in
            "| \(month) | \(bornByMonth[month, default: 0]) | \(profilesByMonth[month, default: 0]) | \(activeByMonth[month, default: 0]) | \(deceasedByMonth[month, default: 0]) | \(soldByMonth[month, default: 0]) | \(culledByMonth[month, default: 0]) | \(transferredByMonth[month, default: 0]) | \(unknownRemovalByMonth[month, default: 0]) |"
        }
        lines += [
            "",
            "口径说明：产羔记录保存每次出生数量；生命周期状态只统计已建立羊只档案且填写出生日期的个体。两者可能无法逐只对应，因此分列展示，不使用状态数倒推出生数。",
            "",
            "注意：结果来自当前设备本地数据库，不代表云端同步已经完成。",
        ]
        let markdown = lines.joined(separator: "\n")
        let queryID = UUID().uuidString.lowercased()
        let object: [String: Any] = [
            "evidence_kind": "farm_query",
            "query_id": queryID,
            "contract_version": FarmFactContract.version,
            "query_kind": request.queryKind,
            "farm_id": farmID.uuidString.lowercased(),
            "executed_at": Self.iso8601(now),
            "as_of": Self.iso8601(request.asOf),
            "time_zone": request.timeZoneIdentifier,
            "state_cutoff_basis": request.stateCutoff.evidenceName,
            "state_basis": audit.stateBasis.sorted(),
            "unknown_state_count": audit.unknownStateCount,
            "projection_mismatch_count": audit.projectionMismatchCount,
            "data_origin": "device_swiftdata",
            "subject": "born_lamb_lifecycle",
            "source_description": "产羔记录 lambCount + 羊只档案出生日期 + \(FarmFactContract.version) 当前状态规则",
            "filters_applied": filterDescriptions(request),
            "metric": "lifecycle_counts",
            "group_by": "month",
            "row_count": months.count,
            "total_matching_count": bornByMonth.values.reduce(0, +),
            "is_complete": true,
            "completeness": "complete",
            "canonical_arguments": request.canonicalArguments,
            "answer_markdown": markdown,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 64 * 1_024 else { throw InsightToolError.resultTooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private func parse(
        _ values: [String: Any],
        now: Date,
        timeZone: TimeZone,
        timeZoneIdentifier: String
    ) throws -> Request {
        func string(_ key: String) throws -> String {
            guard let value = values[key] as? String, value.count <= 1_000 else {
                throw InsightToolError.invalidArguments(key)
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func optionalDate(_ key: String) throws -> Date? {
            let value = try string(key)
            return value.isEmpty ? nil : try Self.parseDate(value, field: key)
        }
        func optionalDecimal(_ key: String) throws -> Decimal? {
            let value = try string(key)
            guard !value.isEmpty else { return nil }
            guard let decimal = Decimal.stable(value) else {
                throw InsightToolError.invalidArguments(key)
            }
            return decimal
        }
        func relationString(_ values: [String: Any], _ key: String) throws -> String {
            guard let value = values[key] as? String, value.count <= 1_000 else {
                throw InsightToolError.invalidArguments("relations.\(key)")
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func relationDate(_ values: [String: Any], _ key: String) throws -> Date? {
            let value = try relationString(values, key)
            return value.isEmpty ? nil : try Self.parseDate(value, field: "relations.\(key)")
        }
        func relationDecimal(_ values: [String: Any], _ key: String) throws -> Decimal? {
            let value = try relationString(values, key)
            guard !value.isEmpty else { return nil }
            guard let decimal = Decimal.stable(value) else {
                throw InsightToolError.invalidArguments("relations.\(key)")
            }
            return decimal
        }
        guard let limitNumber = values["limit"] as? NSNumber else {
            throw InsightToolError.invalidArguments("limit")
        }
        let limit = limitNumber.intValue
        guard Double(limit) == limitNumber.doubleValue, (1...100).contains(limit) else {
            throw InsightToolError.invalidArguments("limit")
        }
        let dateFrom = try optionalDate("date_from")
        let dateTo = try optionalDate("date_to")
        if let dateFrom, let dateTo, dateFrom > dateTo {
            throw InsightToolError.invalidArguments("date_from/date_to")
        }
        let asOfText = try string("as_of")
        let hasExplicitAsOf = !asOfText.isEmpty
        let asOf = hasExplicitAsOf
            ? try Self.parseDate(asOfText, field: "as_of")
            : now
        guard asOf <= now.addingTimeInterval(300) else {
            throw InsightToolError.invalidArguments("as_of")
        }
        let minimumValue = try optionalDecimal("minimum_value")
        let maximumValue = try optionalDecimal("maximum_value")
        if let minimumValue, let maximumValue, minimumValue > maximumValue {
            throw InsightToolError.invalidArguments("minimum_value/maximum_value")
        }
        guard let relationObjects = values["relations"] as? [[String: Any]], relationObjects.count <= 8 else {
            throw InsightToolError.invalidArguments("relations")
        }
        let relations = try relationObjects.map { relation -> RelationRequest in
            let subject = try relationString(relation, "subject").lowercased()
            guard ["weights", "weanings", "reproduction", "health", "transfers", "removals"]
                .contains(subject) else {
                throw InsightToolError.invalidArguments("relations.subject")
            }
            let existence = try relationString(relation, "existence").lowercased()
            guard ["yes", "no"].contains(existence),
                  let minimumCountNumber = relation["minimum_count"] as? NSNumber,
                  let maximumCountNumber = relation["maximum_count"] as? NSNumber else {
                throw InsightToolError.invalidArguments("relations.count")
            }
            let minimumCount = minimumCountNumber.intValue
            let maximumCountValue = maximumCountNumber.intValue
            guard Double(minimumCount) == minimumCountNumber.doubleValue,
                  Double(maximumCountValue) == maximumCountNumber.doubleValue,
                  (0...10_000).contains(minimumCount),
                  (0...10_000).contains(maximumCountValue),
                  maximumCountValue == 0 || maximumCountValue >= minimumCount else {
                throw InsightToolError.invalidArguments("relations.count")
            }
            let relationMinimumValue = try relationDecimal(relation, "minimum_value")
            let relationMaximumValue = try relationDecimal(relation, "maximum_value")
            if let relationMinimumValue, let relationMaximumValue,
               relationMinimumValue > relationMaximumValue {
                throw InsightToolError.invalidArguments("relations.value")
            }
            let relationDateFrom = try relationDate(relation, "date_from")
            let relationDateTo = try relationDate(relation, "date_to")
            if let relationDateFrom, let relationDateTo, relationDateFrom > relationDateTo {
                throw InsightToolError.invalidArguments("relations.date")
            }
            return RelationRequest(
                subject: subject,
                kind: try relationString(relation, "kind").lowercased(),
                itemName: try relationString(relation, "item_name"),
                dateFrom: relationDateFrom,
                dateTo: relationDateTo,
                existence: existence,
                minimumCount: minimumCount,
                maximumCount: maximumCountValue == 0 ? nil : maximumCountValue,
                minimumValue: relationMinimumValue,
                maximumValue: relationMaximumValue
            )
        }
        let subject = try string("subject").lowercased()
        let dateField = try string("date_field").lowercased()
        let allowedDateFields: [String: Set<String>] = [
            "sheep": ["none", "birth_at", "entered_at"],
            "weights": ["occurred_at"],
            "reproduction": ["occurred_at"],
            "health": ["occurred_at"],
            "feeding": ["occurred_at"],
            "inventory": ["none", "expires_at"],
        ]
        guard let subjectDateFields = allowedDateFields[subject],
              subjectDateFields.contains(dateField) else {
            throw InsightToolError.invalidArguments("subject/date_field")
        }
        if (dateFrom != nil || dateTo != nil), dateField == "none" {
            throw InsightToolError.invalidArguments("date_field")
        }
        let groupBy = try string("group_by").lowercased()
        if groupBy == "month", dateField == "none" {
            throw InsightToolError.invalidArguments("group_by/date_field")
        }
        return Request(
            queryKind: try string("query_kind").lowercased(),
            subject: subject,
            dateField: dateField,
            dateFrom: dateFrom,
            dateTo: dateTo,
            asOf: asOf,
            earTag: try string("ear_tag"),
            sex: try string("sex").lowercased(),
            status: try string("status").lowercased(),
            breed: try string("breed"),
            penName: try string("pen_name"),
            kind: try string("kind").lowercased(),
            itemName: try string("item_name"),
            groupBy: groupBy,
            metric: try string("metric").lowercased(),
            minimumValue: minimumValue,
            maximumValue: maximumValue,
            relations: relations,
            limit: limit,
            timeZone: timeZone,
            timeZoneIdentifier: timeZoneIdentifier,
            stateCutoff: hasExplicitAsOf ? .historical(asOf) : .current(asOf),
            canonicalArguments: values
        )
    }

    private func sheepRows(_ request: Request, farmID: UUID, context: ModelContext) throws -> RowResult {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.enteredAt <= request.asOf
        }
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let weights = request.relations.contains(where: { $0.subject == "weights" })
            ? try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
            : []
        let weanings = request.relations.contains(where: { $0.subject == "weanings" })
            ? try context.fetch(FetchDescriptor<WeaningRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
            : []
        let reproduction = request.relations.contains(where: { $0.subject == "reproduction" })
            ? try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
            : []
        let health = request.relations.contains(where: { $0.subject == "health" })
            ? try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
            : []
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        let transfersBySheepID = Dictionary(grouping: transfers) { $0.sheepID }
        let removalsBySheepID = Dictionary(grouping: removals) { $0.sheepID }
        let weightsBySheepID = Dictionary(grouping: weights) { $0.sheepID }
        let weaningsBySheepID = Dictionary(grouping: weanings) { $0.sheepID }
        let reproductionBySheepID = Dictionary(grouping: reproduction) { $0.eweID }
        var healthBySheepID: [UUID: [HealthRecord]] = [:]
        for record in health {
            if let sheepID = record.sheepID {
                healthBySheepID[sheepID, default: []].append(record)
            }
        }
        var audit = FactAudit.empty
        var rows: [Row] = []
        rows.reserveCapacity(sheep.count)
        let isCurrentCutoff: Bool
        switch request.stateCutoff {
        case .current: isCurrentCutoff = true
        case .historical: isCurrentCutoff = false
        }
        let requiresExactStatusProjection = request.queryKind != FarmDataQuerySkill.QueryKind.currentHerd.rawValue
            || request.groupBy == "status"
        let requiresExactPenProjection = !request.penName.isEmpty
            || request.groupBy == "pen"
            || request.metric == "records"

        for item in sheep {
            let itemTransfers = transfersBySheepID[item.id] ?? []
            let itemRemovals = removalsBySheepID[item.id] ?? []
            let fact = FarmSheepStateResolver.resolve(
                item,
                cutoff: request.stateCutoff,
                transfers: itemTransfers,
                removals: itemRemovals
            )
            audit.stateBasis.insert(fact.basis.rawValue)
            guard fact.isIncluded else { continue }
            if !fact.isKnown { audit.unknownStateCount += 1 }
            if isCurrentCutoff {
                let hasMismatch = !fact.presenceProjectionMatchesStoredState
                    || (requiresExactStatusProjection && !fact.statusProjectionMatchesStoredState)
                    || (requiresExactPenProjection && !fact.penProjectionMatchesStoredState)
                if hasMismatch { audit.projectionMismatchCount += 1 }
            }

            let status = fact.status
            let pen: String
            if let status {
                pen = fact.penID.flatMap { penNames[$0] }
                    ?? (status == .active ? "未分圈" : "已离群")
            } else {
                pen = "状态无法判断"
            }
            guard matches(item.earTag, request.earTag),
                  matches(item.breed, request.breed),
                  matches(pen, request.penName),
                  request.sex.isEmpty || item.sex.rawValue == request.sex,
                  request.status.isEmpty || status?.rawValue == request.status,
                  sheepDateMatches(item, request: request),
                  relationsMatch(
                      sheepID: item.id,
                      request: request,
                      weights: weightsBySheepID[item.id] ?? [],
                      weanings: weaningsBySheepID[item.id] ?? [],
                      reproduction: reproductionBySheepID[item.id] ?? [],
                      health: healthBySheepID[item.id] ?? [],
                      transfers: itemTransfers,
                      removals: itemRemovals
                  ) else { continue }
            let values = [
                "ear_tag": item.earTag,
                "sex": item.sex.displayName,
                "breed": item.breed.isEmpty ? "未填写" : item.breed,
                "status": status?.displayName ?? "无法判断",
                "pen": pen,
                "birth_at": item.birthAt.map { Self.day($0, timeZone: request.timeZone) } ?? "未填写",
                "entered_at": Self.day(item.enteredAt, timeZone: request.timeZone),
            ]
            rows.append(Row(
                values: values,
                group: groupValue(request.groupBy, dateField: request.dateField, values: values),
                number: nil
            ))
        }
        if audit.projectionMismatchCount > 0 {
            throw InsightToolError.farmFactsUnavailable(
                "有 \(audit.projectionMismatchCount) 只羊的物化档案与统一事实规则不一致，已停止返回可能与首页不同的结果。"
            )
        }
        if !isCurrentCutoff,
           audit.unknownStateCount > 0,
           (!request.status.isEmpty || !request.penName.isEmpty || ["status", "pen"].contains(request.groupBy)) {
            throw InsightToolError.farmFactsUnavailable(
                "有 \(audit.unknownStateCount) 只羊缺少可证明该历史时点状态的日期或事件，不能给出完整历史状态统计。"
            )
        }
        rows.sort { ($0.values["ear_tag"] ?? "") < ($1.values["ear_tag"] ?? "") }
        return RowResult(rows: rows, audit: audit)
    }

    private func weightRows(_ request: Request, farmID: UUID, context: ModelContext) throws -> [Row] {
        let sheep = try currentSheep(farmID: farmID, context: context)
        let sheepByID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let transfersBySheepID = Dictionary(grouping: transfers) { $0.sheepID }
        return try context.fetch(FetchDescriptor<WeightRecord>()).compactMap { record in
            guard record.farmID == farmID, record.deletedAt == nil,
                  record.occurredAt <= request.asOf, inDateRange(record.occurredAt, request),
                  let item = sheepByID[record.sheepID] else { return nil }
            let kilograms = record.kilograms
            let pen = FarmHistoryTimeline.pen(
                for: item,
                at: record.occurredAt,
                transfers: transfersBySheepID[item.id] ?? []
            )
                .flatMap { penNames[$0] } ?? "未分圈"
            guard sheepMatches(item, pen: pen, request: request), numberMatches(kilograms, request) else { return nil }
            let values = [
                "occurred_at": Self.day(record.occurredAt, timeZone: request.timeZone), "ear_tag": item.earTag,
                "kilograms": kilograms.stableText, "pen": pen,
                "breed": item.breed, "sex": item.sex.displayName,
            ]
            return Row(values: values, group: groupValue(request.groupBy, dateField: request.dateField, values: values), number: kilograms)
        }
        .sorted { ($0.values["occurred_at"] ?? "") > ($1.values["occurred_at"] ?? "") }
    }

    private func reproductionRows(_ request: Request, farmID: UUID, context: ModelContext) throws -> [Row] {
        let sheep = try currentSheep(farmID: farmID, context: context)
        let sheepByID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let transfersBySheepID = Dictionary(grouping: transfers) { $0.sheepID }
        return try context.fetch(FetchDescriptor<ReproductionRecord>()).compactMap { record in
            guard record.farmID == farmID, record.deletedAt == nil,
                  record.occurredAt <= request.asOf, inDateRange(record.occurredAt, request),
                  let ewe = sheepByID[record.eweID],
                  request.kind.isEmpty || record.kind.rawValue == request.kind else { return nil }
            let pen = FarmHistoryTimeline.pen(
                for: ewe,
                at: record.occurredAt,
                transfers: transfersBySheepID[ewe.id] ?? []
            )
                .flatMap { penNames[$0] } ?? "未分圈"
            let numeric = Decimal(record.lambCount)
            guard sheepMatches(ewe, pen: pen, request: request), numberMatches(numeric, request) else { return nil }
            let values = [
                "occurred_at": Self.day(record.occurredAt, timeZone: request.timeZone), "ear_tag": ewe.earTag,
                "kind": record.kind.displayName, "lamb_count": String(record.lambCount),
                "parity": record.parity.map(String.init) ?? "未填写",
                "result": record.result.isEmpty ? "未填写" : record.result,
                "pen": pen, "breed": ewe.breed, "sex": ewe.sex.displayName,
            ]
            return Row(values: values, group: groupValue(request.groupBy, dateField: request.dateField, values: values), number: numeric)
        }
        .sorted { ($0.values["occurred_at"] ?? "") > ($1.values["occurred_at"] ?? "") }
    }

    private func healthRows(_ request: Request, farmID: UUID, context: ModelContext) throws -> [Row] {
        let sheep = try currentSheep(farmID: farmID, context: context)
        let sheepByID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        return try context.fetch(FetchDescriptor<HealthRecord>()).compactMap { record in
            guard record.farmID == farmID, record.deletedAt == nil,
                  record.occurredAt <= request.asOf, inDateRange(record.occurredAt, request),
                  request.kind.isEmpty || record.kind.rawValue == request.kind,
                  matches(record.itemNameSnapshot, request.itemName) else { return nil }
            let item = record.sheepID.flatMap { sheepByID[$0] }
            let pen = record.penID.flatMap { penNames[$0] } ?? "未关联圈舍"
            if !request.earTag.isEmpty, item.map({ matches($0.earTag, request.earTag) }) != true { return nil }
            if !request.breed.isEmpty, item.map({ matches($0.breed, request.breed) }) != true { return nil }
            if !request.sex.isEmpty, item?.sex.rawValue != request.sex { return nil }
            guard matches(pen, request.penName) else { return nil }
            let numeric = record.quantityText.flatMap(Decimal.stable)
            guard numberMatches(numeric, request) else { return nil }
            let quantity = [record.quantityText, record.unit].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let values = [
                "occurred_at": Self.day(record.occurredAt, timeZone: request.timeZone), "ear_tag": item?.earTag ?? "未关联羊只",
                "pen": pen, "kind": record.kind.displayName, "item": record.itemNameSnapshot,
                "quantity": quantity.isEmpty ? "未填写" : quantity,
                "breed": item?.breed.isEmpty == false ? item?.breed ?? "" : "未填写",
                "sex": item?.sex.displayName ?? "未关联羊只",
            ]
            return Row(values: values, group: groupValue(request.groupBy, dateField: request.dateField, values: values), number: numeric)
        }
        .sorted { ($0.values["occurred_at"] ?? "") > ($1.values["occurred_at"] ?? "") }
    }

    private func feedingRows(_ request: Request, farmID: UUID, context: ModelContext) throws -> [Row] {
        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let penNames = Dictionary(uniqueKeysWithValues: pens.map { ($0.id, $0.name) })
        let feeds = try context.fetch(FetchDescriptor<FeedRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt <= request.asOf && inDateRange($0.occurredAt, request)
        }
        let feedByID = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        return try context.fetch(FetchDescriptor<FeedRecordLine>()).compactMap { line in
            guard line.farmID == farmID, line.deletedAt == nil, let feed = feedByID[line.feedRecordID] else { return nil }
            let pen = penNames[feed.penID] ?? "未知圈舍"
            guard matches(pen, request.penName), matches(line.ingredientNameSnapshot, request.itemName),
                  numberMatches(line.kilograms, request) else { return nil }
            let values = [
                "occurred_at": Self.day(feed.occurredAt, timeZone: request.timeZone), "pen": pen,
                "ingredient": line.ingredientNameSnapshot, "kilograms": line.kilograms.stableText,
                "meal": feed.mealName.isEmpty ? "未填写" : feed.mealName,
                "item": line.ingredientNameSnapshot,
            ]
            return Row(values: values, group: groupValue(request.groupBy, dateField: request.dateField, values: values), number: line.kilograms)
        }
        .sorted { ($0.values["occurred_at"] ?? "") > ($1.values["occurred_at"] ?? "") }
    }

    private func inventoryRows(_ request: Request, farmID: UUID, context: ModelContext) throws -> [Row] {
        let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && $0.occurredAt <= request.asOf
        }
        let byLot = Dictionary(grouping: transactions, by: \.inventoryLotID)
        return try context.fetch(FetchDescriptor<InventoryLotRecord>()).compactMap { lot in
            guard lot.farmID == farmID, lot.deletedAt == nil,
                  matches(lot.catalogName, request.itemName),
                  request.kind.isEmpty || lot.kindRawValue == request.kind,
                  request.dateField != "expires_at"
                    || lot.expiresAt.map({ inDateRange($0, request) }) == true else { return nil }
            let quantity = (byLot[lot.id] ?? []).reduce(Decimal.zero) { partial, transaction in
                switch transaction.kind {
                case .receipt, .adjustment: partial + transaction.quantity
                case .consumption: partial - transaction.quantity
                }
            }
            guard numberMatches(quantity, request) else { return nil }
            let values = [
                "item": lot.catalogName, "batch": lot.batchNumber.isEmpty ? "未填写" : lot.batchNumber,
                "kind": HealthRecordKind(rawValue: lot.kindRawValue)?.displayName ?? lot.kindRawValue,
                "quantity": quantity.stableText, "unit": lot.unit.isEmpty ? "未填写" : lot.unit,
                "expires_at": lot.expiresAt.map { Self.day($0, timeZone: request.timeZone) } ?? "未填写",
            ]
            return Row(values: values, group: groupValue(request.groupBy, dateField: request.dateField, values: values), number: quantity)
        }
        .sorted { ($0.values["item"] ?? "") < ($1.values["item"] ?? "") }
    }

    private func renderMarkdown(
        subjectName: String,
        request: Request,
        rows: [Row],
        totalCount: Int,
        columns: [(key: String, title: String)],
        isComplete: Bool
    ) -> String {
        let filters = filterDescriptions(request)
        let scope = filters.isEmpty ? "当前牧场全部符合权限的数据" : filters.joined(separator: "；")
        let completeness = isComplete ? "完整结果" : "仅显示前 \(rows.count) 条，共匹配 \(totalCount) 条"
        var lines = [
            "查询结果：\(subjectName)",
            "",
            "- 数据来源：\(sourceDescription(request))",
            "- 事实契约：\(FarmFactContract.version)",
            "- 牧场时区：\(request.timeZoneIdentifier)",
            "- 查询条件：\(scope)",
            "- 数据截止：\(Self.iso8601(request.asOf))",
            "- 完整性：\(completeness)",
        ]
        if request.groupBy != "none" || request.metric != "records" {
            var groups = Dictionary(grouping: rows, by: \.group).map { key, values in
                let numbers = values.compactMap(\.number)
                let metricValue: String
                switch request.metric {
                case "sum": metricValue = numbers.reduce(0, +).stableText
                case "average":
                    metricValue = numbers.isEmpty ? "无可计算数值" : (numbers.reduce(0, +) / Decimal(numbers.count)).stableText
                case "minimum": metricValue = numbers.min()?.stableText ?? "无可计算数值"
                case "maximum": metricValue = numbers.max()?.stableText ?? "无可计算数值"
                default: metricValue = String(values.count)
                }
                return (key.isEmpty ? "全部" : key, metricValue)
            }
            if request.groupBy == "month" {
                let existing = Set(groups.map(\.0))
                let emptyValue = ["count", "sum", "records"].contains(request.metric) ? "0" : "—"
                groups += monthBuckets(request).filter { !existing.contains($0) }.map { ($0, emptyValue) }
            }
            groups.sort { $0.0 < $1.0 }
            lines += ["", "| 分组 | \(metricTitle(request.metric)) |", "|---|---:|"]
            lines += groups.map { "| \(escape($0.0)) | \(escape($0.1)) |" }
        } else if rows.isEmpty {
            lines += ["", "按上述条件未查询到记录。"]
        } else {
            lines += ["", "| " + columns.map(\.title).joined(separator: " | ") + " |"]
            lines += ["|" + columns.map { _ in "---" }.joined(separator: "|") + "|"]
            lines += rows.map { row in
                "| " + columns.map { escape(row.values[$0.key] ?? "") }.joined(separator: " | ") + " |"
            }
        }
        lines += [
            "",
            "以上结果由当前设备的 App 本地数据库直接计算；未查询到的字段没有补写。",
            "注意：本结果不代表云端同步已经完成；请结合页面显示的数据同步状态判断是否为最新数据。",
        ]
        return lines.joined(separator: "\n")
    }

    private func filterDescriptions(_ request: Request) -> [String] {
        var values: [String] = []
        if request.dateField != "none" { values.append("日期字段=\(dateFieldTitle(request.dateField))") }
        if let dateFrom = request.dateFrom {
            values.append("日期≥\(Self.day(dateFrom, timeZone: request.timeZone))")
        }
        if let dateTo = request.dateTo {
            values.append("日期≤\(Self.day(dateTo, timeZone: request.timeZone))")
        }
        if !request.earTag.isEmpty { values.append("耳号包含“\(request.earTag)”") }
        if !request.sex.isEmpty { values.append("性别=\(request.sex)") }
        if !request.status.isEmpty { values.append("状态=\(request.status)") }
        if !request.breed.isEmpty { values.append("品种包含“\(request.breed)”") }
        if !request.penName.isEmpty { values.append("圈舍包含“\(request.penName)”") }
        if !request.kind.isEmpty { values.append("类型=\(request.kind)") }
        if !request.itemName.isEmpty { values.append("项目包含“\(request.itemName)”") }
        if let minimumValue = request.minimumValue { values.append("数值≥\(minimumValue.stableText)") }
        if let maximumValue = request.maximumValue { values.append("数值≤\(maximumValue.stableText)") }
        values += request.relations.map { relation in
            var details = [relation.subject]
            if !relation.kind.isEmpty { details.append("类型=\(relation.kind)") }
            if !relation.itemName.isEmpty { details.append("项目包含“\(relation.itemName)”") }
            if let dateFrom = relation.dateFrom {
                details.append("从\(Self.day(dateFrom, timeZone: request.timeZone))")
            }
            if let dateTo = relation.dateTo {
                details.append("到\(Self.day(dateTo, timeZone: request.timeZone))")
            }
            if relation.minimumCount > 0 { details.append("至少\(relation.minimumCount)条") }
            if let maximumCount = relation.maximumCount { details.append("至多\(maximumCount)条") }
            if let minimumValue = relation.minimumValue { details.append("数值≥\(minimumValue.stableText)") }
            if let maximumValue = relation.maximumValue { details.append("数值≤\(maximumValue.stableText)") }
            details.append(relation.existence == "yes" ? "必须存在" : "必须不存在")
            return "关联条件：" + details.joined(separator: "，")
        }
        return values
    }

    private func relationsMatch(
        sheepID: UUID,
        request: Request,
        weights: [WeightRecord],
        weanings: [WeaningRecord],
        reproduction: [ReproductionRecord],
        health: [HealthRecord],
        transfers: [TransferRecord],
        removals: [RemovalRecord]
    ) -> Bool {
        request.relations.allSatisfy { relation in
            let candidates: [(date: Date, kind: String, item: String, number: Decimal?)]
            switch relation.subject {
            case "weights":
                candidates = weights.filter { $0.sheepID == sheepID }.map {
                    ($0.occurredAt, "weight", "", $0.kilograms)
                }
            case "weanings":
                candidates = weanings.filter { $0.sheepID == sheepID }.map {
                    ($0.occurredAt, "weaning", "", Decimal.stable($0.weanWeightText))
                }
            case "reproduction":
                candidates = reproduction.filter { $0.eweID == sheepID }.map {
                    ($0.occurredAt, $0.kind.rawValue, "", Decimal($0.lambCount))
                }
            case "health":
                candidates = health.filter { $0.sheepID == sheepID }.map {
                    ($0.occurredAt, $0.kind.rawValue, $0.itemNameSnapshot, $0.quantityText.flatMap(Decimal.stable))
                }
            case "transfers":
                candidates = transfers.filter { $0.sheepID == sheepID }.map {
                    ($0.occurredAt, "transfer", "", nil)
                }
            case "removals":
                candidates = removals.filter { $0.sheepID == sheepID }.map {
                    ($0.occurredAt, $0.kind.rawValue, $0.reason, $0.amountText.flatMap(Decimal.stable))
                }
            default:
                return false
            }
            let matching = candidates.filter { candidate in
                candidate.date <= request.asOf
                    && (relation.dateFrom.map { candidate.date >= $0 } ?? true)
                    && (relation.dateTo.map { candidate.date <= $0 } ?? true)
                    && (relation.kind.isEmpty || candidate.kind == relation.kind)
                    && matches(candidate.item, relation.itemName)
                    && relationNumberMatches(candidate.number, relation)
            }
            if relation.existence == "no" { return matching.isEmpty }
            guard !matching.isEmpty, matching.count >= max(1, relation.minimumCount) else { return false }
            return relation.maximumCount.map { matching.count <= $0 } ?? true
        }
    }

    private func relationNumberMatches(_ value: Decimal?, _ relation: RelationRequest) -> Bool {
        if relation.minimumValue == nil && relation.maximumValue == nil { return true }
        guard let value else { return false }
        return (relation.minimumValue.map { value >= $0 } ?? true)
            && (relation.maximumValue.map { value <= $0 } ?? true)
    }

    private func farmTimeZone(
        farmID: UUID,
        context: ModelContext
    ) throws -> (value: TimeZone, identifier: String) {
        let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first {
            $0.id == farmID && $0.deletedAt == nil
        }
        guard let farm else {
            throw InsightToolError.farmFactsUnavailable(
                "当前牧场记录不存在，无法确定数据边界和时区。"
            )
        }
        let identifier = farm.timeZoneIdentifier
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw InsightToolError.farmFactsUnavailable(
                "牧场时区 \(identifier) 无效，不能可靠划分日期和月份。"
            )
        }
        return (timeZone, identifier)
    }

    private func currentSheep(farmID: UUID, context: ModelContext) throws -> [SheepRecord] {
        try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
    }

    private func sheepMatches(_ sheep: SheepRecord, pen: String, request: Request) -> Bool {
        matches(sheep.earTag, request.earTag) && matches(sheep.breed, request.breed)
            && matches(pen, request.penName)
            && (request.sex.isEmpty || sheep.sex.rawValue == request.sex)
            && (request.status.isEmpty || sheep.status.rawValue == request.status)
    }

    private func inDateRange(_ date: Date, _ request: Request) -> Bool {
        (request.dateFrom.map { date >= $0 } ?? true) && (request.dateTo.map { date <= $0 } ?? true)
    }

    private func sheepDateMatches(_ sheep: SheepRecord, request: Request) -> Bool {
        switch request.dateField {
        case "birth_at":
            guard let birthAt = sheep.birthAt else { return false }
            return inDateRange(birthAt, request)
        case "entered_at":
            return inDateRange(sheep.enteredAt, request)
        default:
            return request.dateFrom == nil && request.dateTo == nil
        }
    }

    private func numberMatches(_ value: Decimal?, _ request: Request) -> Bool {
        if request.minimumValue == nil && request.maximumValue == nil { return true }
        guard let value else { return false }
        return (request.minimumValue.map { value >= $0 } ?? true)
            && (request.maximumValue.map { value <= $0 } ?? true)
    }

    private func matches(_ value: String, _ query: String) -> Bool {
        query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }

    private func groupValue(_ groupBy: String, dateField: String, values: [String: String]) -> String {
        switch groupBy {
        case "pen": values["pen"] ?? "未分圈"
        case "breed": values["breed"] ?? "未填写"
        case "sex": values["sex"] ?? "未填写"
        case "status": values["status"] ?? "未填写"
        case "kind": values["kind"] ?? "未填写"
        case "item": values["item"] ?? values["ingredient"] ?? "未填写"
        case "month": String((values[dateField] ?? "").prefix(7))
        default: "全部"
        }
    }

    private func dateFieldTitle(_ dateField: String) -> String {
        switch dateField {
        case "birth_at": "羊只档案出生日期"
        case "entered_at": "羊只入场日期"
        case "occurred_at": "业务记录发生日期"
        case "expires_at": "库存到期日期"
        default: "不按日期筛选"
        }
    }

    private func monthBuckets(_ request: Request) -> [String] {
        guard let dateFrom = request.dateFrom else { return [] }
        let effectiveEnd = min(request.dateTo ?? request.asOf, request.asOf)
        guard dateFrom <= effectiveEnd else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = request.timeZone
        guard var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: dateFrom)) else {
            return []
        }
        var values: [String] = []
        while cursor <= effectiveEnd, values.count < 240 {
            values.append(Self.month(cursor, timeZone: request.timeZone))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return values
    }

    private func sourceDescription(_ request: Request) -> String {
        switch request.subject {
        case "sheep":
            switch request.dateField {
            case "birth_at": return "当前设备 SwiftData · SheepRecord.birthAt + \(FarmFactContract.version) 羊只范围"
            case "entered_at": return "当前设备 SwiftData · SheepRecord.enteredAt + \(FarmFactContract.version) 羊只范围"
            default: return "当前设备 SwiftData · 羊只档案 + \(FarmFactContract.version) 羊只状态规则"
            }
        case "weights": return "当前设备 SwiftData · 称重记录 WeightRecord.occurredAt/kilograms"
        case "reproduction": return "当前设备 SwiftData · 繁殖记录 ReproductionRecord.occurredAt/lambCount"
        case "health": return "当前设备 SwiftData · 健康记录 HealthRecord"
        case "feeding": return "当前设备 SwiftData · 饲喂记录 FeedingRecord/FeedingLineRecord"
        case "inventory": return "当前设备 SwiftData · 健康库存 InventoryLotRecord/InventoryTransactionRecord"
        default: return "当前设备 SwiftData"
        }
    }

    private func metricTitle(_ metric: String) -> String {
        switch metric {
        case "sum": "合计"
        case "average": "平均值"
        case "minimum": "最小值"
        case "maximum": "最大值"
        default: "记录数"
        }
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func parseDate(_ value: String, field: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw InsightToolError.invalidArguments(field) }
        return date
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func day(_ date: Date) -> String {
        day(date, timeZone: .current)
    }

    static func day(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func month(_ date: Date) -> String {
        month(date, timeZone: .current)
    }

    static func month(_ date: Date, timeZone: TimeZone) -> String {
        String(day(date, timeZone: timeZone).prefix(7))
    }
}
