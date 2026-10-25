import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 牧场“在群羊只”导出。数据只从当前本机已同步的档案读取，不会改写羊只、圈舍或云端队列。
enum InHerdSheepExport {
    static let columnTitles = ["耳号", "圈舍", "出生日期", "入场日期", "品种", "性别", "用途", "状态", "备注"]

    static func csvData(farmID: UUID, sheep: [SheepRecord], pens: [PenRecord], reproduction: [ReproductionRecord]? = nil) -> Data {
        let penNames = Dictionary(
            uniqueKeysWithValues: pens
                .filter { $0.farmID == farmID && $0.deletedAt == nil }
                .map { ($0.id, $0.name) }
        )
        let dateFormatter = makeDateFormatter()
        let states = ReproductionReminderValidity.states(records: reproduction ?? [], eweIDs: sheep.filter { $0.sex == .ewe }.map(\.id), now: .now)
        let currentSheep = sheep
            .filter { $0.farmID == farmID && $0.deletedAt == nil && $0.isCurrentlyPresent }
            .sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
        let rows: [[String]] = currentSheep.map { item -> [String] in
            var values: [String] = [
                item.earTag,
                item.currentPenDisplayName(item.currentPenID.flatMap { penNames[$0] }),
                item.birthAt.map(dateFormatter.string(from:)) ?? "",
                dateFormatter.string(from: item.enteredAt),
                item.breed,
                item.sex.displayName,
                item.purpose,
                item.status.displayName,
                item.note
            ]
            if reproduction != nil {
                let state = states[item.id]
                let completedParity = state?.completedParity
                let targetParity = state?.targetParity
                values.append(completedParity.map { String($0) } ?? "")
                values.append(targetParity.map { String($0) } ?? "")
                values.append(state?.displayState ?? (item.sex == .ewe ? "胎次待核实" : "不适用"))
                values.append(state?.issues.joined(separator: "；") ?? "")
            }
            return values
        }

        let titles = columnTitles + (reproduction == nil ? [] : ["已完成产羔胎次", "本轮目标胎次", "本轮繁殖状态", "繁殖资料待核实"])
        let csv = ([titles] + rows)
            .map { $0.map(escapeCSVField).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        // BOM 使 Windows 版 Excel 直接识别中文 UTF-8，而不会出现乱码。
        return Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8)
    }

    static func fileName(farmName: String, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = farmName
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "在群羊只_\(cleaned.isEmpty ? "牧场" : cleaned)_\(formatter.string(from: date)).csv"
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func escapeCSVField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

struct InHerdSheepExportDocument: FileDocument {
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

/// 牧场“离群羊只”导出。以未撤销的离群记录为权威事实，并兼容只有 `removedAt` 的旧羊只档案。
enum RemovedSheepExport {
    static let columnTitles = ["耳号", "离群日期", "离群类型", "离群原因", "金额", "出生日期", "入场日期", "品种", "性别", "用途", "状态", "羊只备注", "离群备注"]

    static func csvData(farmID: UUID, sheep: [SheepRecord], removals: [RemovalRecord]) -> Data {
        let latestRemovalBySheepID = Dictionary(
            grouping: removals.filter { $0.farmID == farmID && $0.deletedAt == nil },
            by: \.sheepID
        ).compactMapValues { records in
            records.max {
                if $0.occurredAt == $1.occurredAt { return $0.recordedAt < $1.recordedAt }
                return $0.occurredAt < $1.occurredAt
            }
        }
        let dateFormatter = makeDateFormatter()
        let rows = sheep
            .filter {
                $0.farmID == farmID &&
                    $0.deletedAt == nil &&
                    !$0.isCurrentlyPresent &&
                    !$0.isHistoricalArchive
            }
            .map { item in
                (sheep: item, removal: latestRemovalBySheepID[item.id])
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.removal?.occurredAt ?? lhs.sheep.removedAt ?? .distantPast
                let rhsDate = rhs.removal?.occurredAt ?? rhs.sheep.removedAt ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.sheep.earTag.localizedStandardCompare(rhs.sheep.earTag) == .orderedAscending
                }
                return lhsDate > rhsDate
            }
            .map { item in
                let removalDate = item.removal?.occurredAt ?? item.sheep.removedAt
                return [
                    item.sheep.earTag,
                    removalDate.map(dateFormatter.string(from:)) ?? "",
                    item.removal?.kind.displayName ?? item.sheep.status.displayName,
                    item.removal?.reason ?? "",
                    item.removal?.amountText ?? "",
                    item.sheep.birthAt.map(dateFormatter.string(from:)) ?? "",
                    dateFormatter.string(from: item.sheep.enteredAt),
                    item.sheep.breed,
                    item.sheep.sex.displayName,
                    item.sheep.purpose,
                    item.sheep.status.displayName,
                    item.sheep.note,
                    item.removal?.note ?? ""
                ]
            }

        let csv = ([columnTitles] + rows)
            .map { $0.map(escapeCSVField).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8)
    }

    static func fileName(farmName: String, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = farmName
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "离群羊只_\(cleaned.isEmpty ? "牧场" : cleaned)_\(formatter.string(from: date)).csv"
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func escapeCSVField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
