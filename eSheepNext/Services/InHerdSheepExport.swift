import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 牧场“在群羊只”导出。数据只从当前本机已同步的档案读取，不会改写羊只、圈舍或云端队列。
enum InHerdSheepExport {
    static let columnTitles = ["耳号", "圈舍", "出生日期", "入场日期", "品种", "性别", "用途", "状态", "备注"]

    static func csvData(farmID: UUID, sheep: [SheepRecord], pens: [PenRecord]) -> Data {
        let penNames = Dictionary(
            uniqueKeysWithValues: pens
                .filter { $0.farmID == farmID && $0.deletedAt == nil }
                .map { ($0.id, $0.name) }
        )
        let dateFormatter = makeDateFormatter()
        let rows = sheep
            .filter { $0.farmID == farmID && $0.deletedAt == nil && $0.isCurrentlyPresent }
            .sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
            .map { item in
                [
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
            }

        let csv = ([columnTitles] + rows)
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
