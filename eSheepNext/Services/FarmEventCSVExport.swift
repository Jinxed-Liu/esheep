import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 事件记录导出的业务范围。主数据仍由完整 XLSX/备份导出负责；这里覆盖事件历史中的每一种生产记录。
enum FarmEventExportScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case birth
    case sheep
    case batch
    case purpose
    case weight
    case weaning
    case transfer
    case removal
    case feed
    case health
    case reproduction
    case inventory
    case note
    case lambing
    case breeding
    case pregnancyCheck
    case abortion
    case parityBaseline
    case sold
    case deceased
    case culled
    case transferredOut
    case treatment
    case vaccination
    case directFeed
    case tmrFeed
    case inventoryReceipt
    case inventoryAdjustment
    case semenReceipt
    case semenAdjustment
    case batchCreated
    case batchDeleted
    case batchDeparture

    var id: Self { self }
    var displayName: String {
        switch self {
        case .all: "全部记录"
        case .birth: "出生记录"
        case .sheep: "羊只建档"
        case .batch: "生产批次"
        case .purpose: "用途变更"
        case .weight: "称重记录"
        case .weaning: "断奶羔羊"
        case .transfer: "转群记录"
        case .removal: "离群记录"
        case .feed: "投喂记录"
        case .health: "健康记录"
        case .reproduction: "繁殖记录"
        case .inventory: "库存记录"
        case .note: "备注记录"
        case .lambing: "产羔"
        case .breeding: "配种"
        case .pregnancyCheck: "孕检"
        case .abortion: "流产"
        case .parityBaseline: "胎次确认"
        case .sold: "出售"
        case .deceased: "死亡"
        case .culled: "淘汰"
        case .transferredOut: "转出"
        case .treatment: "治疗"
        case .vaccination: "疫苗"
        case .directFeed: "直接投喂"
        case .tmrFeed: "TMR 投喂"
        case .inventoryReceipt: "药品疫苗入库"
        case .inventoryAdjustment: "药品疫苗盘点"
        case .semenReceipt: "冻精入库"
        case .semenAdjustment: "冻精盘点"
        case .batchCreated: "建立生产批次"
        case .batchDeleted: "删除生产批次"
        case .batchDeparture: "移出批次"
        }
    }
    var filterName: String {
        switch self {
        case .all: String(localized: "全部事件")
        case .birth: String(localized: "出生")
        case .sheep: String(localized: "羊只建档")
        case .batch: String(localized: "全部批次事件")
        case .purpose: String(localized: "用途变更")
        case .weight: String(localized: "称重")
        case .weaning: String(localized: "断奶")
        case .transfer: String(localized: "转群")
        case .removal: String(localized: "全部离群事件")
        case .feed: String(localized: "全部投喂事件")
        case .health: String(localized: "全部健康事件")
        case .reproduction: String(localized: "全部繁殖事件")
        case .inventory: String(localized: "全部库存事件")
        case .note: String(localized: "备注")
        case .lambing: String(localized: "产羔")
        case .breeding: String(localized: "配种")
        case .pregnancyCheck: String(localized: "孕检")
        case .abortion: String(localized: "流产")
        case .parityBaseline: String(localized: "胎次确认")
        case .sold: String(localized: "出售")
        case .deceased: String(localized: "死亡")
        case .culled: String(localized: "淘汰")
        case .transferredOut: String(localized: "转出")
        case .treatment: String(localized: "治疗")
        case .vaccination: String(localized: "疫苗")
        case .directFeed: String(localized: "直接投喂")
        case .tmrFeed: String(localized: "TMR 投喂")
        case .inventoryReceipt: String(localized: "药品疫苗入库")
        case .inventoryAdjustment: String(localized: "药品疫苗盘点")
        case .semenReceipt: String(localized: "冻精入库")
        case .semenAdjustment: String(localized: "冻精盘点")
        case .batchCreated: String(localized: "建立生产批次")
        case .batchDeleted: String(localized: "删除生产批次")
        case .batchDeparture: String(localized: "移出批次")
        }
    }
    var symbol: String {
        switch self {
        case .all: "clock.arrow.circlepath"
        case .birth: "calendar.badge.plus"
        case .sheep: "tag"
        case .batch: "square.stack.3d.up"
        case .purpose: "arrow.trianglehead.2.clockwise.rotate.90"
        case .weight: "scalemass"
        case .weaning: "leaf.circle.fill"
        case .transfer: "arrow.left.arrow.right"
        case .removal: "arrowshape.turn.up.right.circle"
        case .feed: "leaf"
        case .health: "cross.case"
        case .reproduction: "heart.text.clipboard"
        case .inventory: "shippingbox"
        case .note: "note.text"
        case .lambing: "heart"
        case .breeding: "heart.text.clipboard"
        case .pregnancyCheck: "heart.text.clipboard"
        case .abortion: "heart.text.clipboard"
        case .parityBaseline: "list.number"
        case .sold: "arrow.up.forward"
        case .deceased: "minus.circle"
        case .culled: "minus.circle"
        case .transferredOut: "arrow.up.forward"
        case .treatment: "cross.case"
        case .vaccination: "syringe"
        case .directFeed: "leaf"
        case .tmrFeed: "leaf"
        case .inventoryReceipt: "shippingbox"
        case .inventoryAdjustment: "shippingbox"
        case .semenReceipt: "shippingbox"
        case .semenAdjustment: "shippingbox"
        case .batchCreated: "square.stack.3d.up"
        case .batchDeleted: "square.stack.3d.up"
        case .batchDeparture: "square.stack.3d.up"
        }
    }
    func includes(_ event: FarmEventSnapshot) -> Bool {
        switch self {
        case .all: true
        case .birth: event.entityType == .sheep && event.isDerived && event.title == "出生"
        case .sheep: event.entityType == .sheep && !event.isDerived
        case .batch: event.entityType == .productionBatch || event.entityType == .batchMembership
        case .purpose: event.entityType == .sheep && event.isDerived && event.title == "用途变更"
        case .weight: event.entityType == .weight
        case .weaning: event.entityType == .weaning
        case .transfer: event.entityType == .transfer
        case .removal: event.entityType == .removal
        case .feed: event.entityType == .feed
        case .health: event.entityType == .health
        case .reproduction: event.entityType == .reproduction
        case .inventory: event.entityType == .inventoryTransaction || event.entityType == .semenTransaction
        case .note: event.entityType == .note
        default: event.recordScope == self
        }
    }

    static func scope(for event: FarmEventSnapshot) -> FarmEventExportScope {
        if let recordScope = event.recordScope { return recordScope }
        return allCases.first(where: { $0 != .all && $0.includes(event) }) ?? .all
    }
}

struct FarmEventScopeGroup: Identifiable {
    let title: String
    let scopes: [FarmEventExportScope]
    var id: String { title }
}

extension FarmEventExportScope {
    static let shortcuts: [Self] = [
        .all, .lambing, .breeding, .pregnancyCheck, .weight, .weaning, .transfer,
        .sold, .deceased, .culled, .transferredOut, .treatment, .vaccination,
        .directFeed, .tmrFeed, .birth, .sheep, .purpose, .abortion, .parityBaseline,
        .inventoryReceipt, .inventoryAdjustment, .semenReceipt, .semenAdjustment,
        .batchCreated, .batchDeleted, .batchDeparture, .note
    ]
    static let groups: [FarmEventScopeGroup] = [
        .init(title: "繁殖", scopes: [.reproduction, .lambing, .breeding, .pregnancyCheck, .abortion, .parityBaseline]),
        .init(title: "羊群与生长", scopes: [.sheep, .birth, .weight, .weaning, .transfer, .purpose]),
        .init(title: "离群", scopes: [.removal, .sold, .deceased, .culled, .transferredOut]),
        .init(title: "健康", scopes: [.health, .treatment, .vaccination]),
        .init(title: "饲喂", scopes: [.feed, .directFeed, .tmrFeed]),
        .init(title: "库存", scopes: [.inventory, .inventoryReceipt, .inventoryAdjustment, .semenReceipt, .semenAdjustment]),
        .init(title: "生产批次", scopes: [.batch, .batchCreated, .batchDeleted, .batchDeparture]),
        .init(title: "其他", scopes: [.note])
    ]
    static func reproduction(_ kind: ReproductionRecordKind) -> Self {
        switch kind {
        case .lambing: .lambing
        case .breeding: .breeding
        case .pregnancyCheck: .pregnancyCheck
        case .abortion: .abortion
        case .parityBaseline: .parityBaseline
        }
    }
    static func removal(_ kind: RemovalKind) -> Self {
        switch kind {
        case .sold: .sold
        case .deceased: .deceased
        case .culled: .culled
        case .transferredOut: .transferredOut
        }
    }
}

struct FarmEventScopePicker: View {
    @Binding var selection: FarmEventExportScope
    var body: some View {
        Picker("事件类型", selection: $selection) {
            Text("全部事件").tag(FarmEventExportScope.all)
            ForEach(FarmEventExportScope.groups) { group in
                Section {
                    ForEach(group.scopes) { scope in
                        Text(verbatim: scope.filterName).tag(scope)
                    }
                } header: { Text(LocalizedStringKey(group.title)) }
            }
        }
    }
}

enum FarmEventExportRange: Sendable, Equatable {
    case all
    /// 开始日和结束日均按牧场设备当前日历包含整天。
    case days(from: Date, through: Date)
}

enum FarmEventCSVExport {
    static let fixedColumnTitles = ["发生时间", "录入时间", "类别", "记录类型", "主对象", "摘要"]

    static func matchingEvents(
        _ events: [FarmEventSnapshot],
        scope: FarmEventExportScope,
        range: FarmEventExportRange,
        calendar: Calendar = .current
    ) -> [FarmEventSnapshot] {
        let bounds = normalizedBounds(for: range, calendar: calendar)
        return events
            .filter { matches($0, scope: scope, bounds: bounds) }
            .sorted(by: eventSort)
    }

    /// 导出页预览只计数、不排序，避免每次调整日期时重复做全量排序。
    static func matchingEventCount(
        _ events: [FarmEventSnapshot],
        scope: FarmEventExportScope,
        range: FarmEventExportRange,
        calendar: Calendar = .current
    ) -> Int {
        let bounds = normalizedBounds(for: range, calendar: calendar)
        return events.lazy.filter { matches($0, scope: scope, bounds: bounds) }.count
    }

    static func csvData(
        events: [FarmEventSnapshot],
        scope: FarmEventExportScope,
        range: FarmEventExportRange,
        calendar: Calendar = .current
    ) -> Data {
        let records = matchingEvents(events, scope: scope, range: range, calendar: calendar)
        var seenFieldTitles = Set<String>()
        var fieldTitles: [String] = []
        for event in records {
            for field in event.fields where seenFieldTitles.insert(field.label).inserted {
                fieldTitles.append(field.label)
            }
        }
        let columnTitles = fixedColumnTitles + fieldTitles + ["备注", "记录ID"]
        let formatter = makeDateTimeFormatter(calendar: calendar)
        let rows = records.map { event in
            var valuesByField = [String: String]()
            for field in event.fields where valuesByField[field.label] == nil {
                valuesByField[field.label] = field.value
            }
            return [
                formatter.string(from: event.occurredAt),
                formatter.string(from: event.recordedAt),
                event.category.displayName,
                event.title,
                event.subject,
                event.detail,
            ] + fieldTitles.map { valuesByField[$0] ?? "" } + [event.note, event.id.uuidString.lowercased()]
        }
        let csv = ([columnTitles] + rows)
            .map { $0.map(escapeCSVField).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8)
    }

    static func fileName(
        farmName: String,
        scope: FarmEventExportScope,
        range: FarmEventExportRange,
        exportedAt: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let safeFarmName = sanitizedFileComponent(farmName, fallback: "牧场")
        let exportedFormatter = makeDayFormatter(calendar: calendar)
        let rangeText: String
        switch range {
        case .all:
            rangeText = "全部时间"
        case .days(let first, let second):
            let lower = min(first, second)
            let upper = max(first, second)
            rangeText = "\(exportedFormatter.string(from: lower))-\(exportedFormatter.string(from: upper))"
        }
        return "\(scope.displayName)_\(safeFarmName)_\(rangeText)_\(exportedFormatter.string(from: exportedAt)).csv"
    }

    private static func normalizedBounds(
        for range: FarmEventExportRange,
        calendar: Calendar
    ) -> Range<Date>? {
        guard case .days(let first, let second) = range else { return nil }
        let lowerDay = calendar.startOfDay(for: min(first, second))
        let upperDay = calendar.startOfDay(for: max(first, second))
        guard let upperExclusive = calendar.date(byAdding: .day, value: 1, to: upperDay) else { return nil }
        return lowerDay..<upperExclusive
    }

    private static func matches(
        _ event: FarmEventSnapshot,
        scope: FarmEventExportScope,
        bounds: Range<Date>?
    ) -> Bool {
        guard scope.includes(event) else { return false }
        guard let bounds else { return true }
        return event.occurredAt >= bounds.lowerBound && event.occurredAt < bounds.upperBound
    }

    private static func eventSort(_ lhs: FarmEventSnapshot, _ rhs: FarmEventSnapshot) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private static func makeDateTimeFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    private static func makeDayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }

    private static func sanitizedFileComponent(_ value: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func escapeCSVField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

struct FarmEventCSVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
