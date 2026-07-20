import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import zlib

extension UTType {
    static let officeOpenXMLSpreadsheet = UTType(filenameExtension: "xlsx")!
}

enum FarmImportFileKind: String, Codable, Sendable {
    case csv
    case xlsx
    case json
}

struct FarmImportRow: Codable, Equatable, Sendable, Identifiable {
    let rowNumber: Int
    let idempotencyKey: String
    let earTag: String
    let breed: String
    let sex: SheepSex
    let penName: String?
    let enteredAt: Date
    let birthAt: Date?
    let note: String

    var id: String { idempotencyKey }
}

struct FarmImportIssue: Codable, Equatable, Sendable, Identifiable {
    enum Severity: String, Codable, Sendable { case warning, error }

    let rowNumber: Int
    let field: String
    let message: String
    let severity: Severity

    var id: String { "\(rowNumber):\(field):\(message)" }
}

struct FarmImportPreview: Codable, Equatable, Sendable {
    let formatVersion: Int
    let fileKind: FarmImportFileKind
    let rows: [FarmImportRow]
    let issues: [FarmImportIssue]
    let duplicateRowNumbers: [Int]

    var acceptedRows: [FarmImportRow] {
        rows.filter { row in
            !duplicateRowNumbers.contains(row.rowNumber) &&
                !issues.contains(where: { $0.rowNumber == row.rowNumber && $0.severity == .error })
        }
    }

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
}

struct FarmImportCommitResult: Equatable, Sendable {
    let importedCount: Int
    let skippedCount: Int
}

enum FarmDataInterchangeError: LocalizedError {
    case unsupportedFile
    case malformedFile(String)
    case unsafeArchivePath
    case oversizedArchive

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "仅支持 XLSX、CSV 和 JSON 文件。"
        case .malformedFile(let detail): "文件无法读取：\(detail)"
        case .unsafeArchivePath: "文件包含不安全的归档路径。"
        case .oversizedArchive: "解压后的文件过大，已停止导入。"
        }
    }
}

enum FarmDataInterchange {
    static let columns = ["耳号", "品种", "性别", "圈舍", "入场日期", "出生日期", "备注"]

    static func preview(data: Data, fileExtension: String, existingEarTags: Set<String> = []) throws -> FarmImportPreview {
        let ext = fileExtension.lowercased()
        let kind: FarmImportFileKind
        let table: [[String]]
        switch ext {
        case "csv":
            kind = .csv
            table = try CSVCodec.decode(data)
        case "xlsx":
            kind = .xlsx
            table = try XLSXCodec.decode(data)
        case "json":
            kind = .json
            return try previewJSON(data, existingEarTags: existingEarTags)
        default:
            throw FarmDataInterchangeError.unsupportedFile
        }
        return makePreview(table: table, kind: kind, existingEarTags: existingEarTags)
    }

    static func xlsxData(farmID: UUID, sheep: [SheepRecord], pens: [PenRecord]) throws -> Data {
        try XLSXCodec.encode(table: exportTable(farmID: farmID, sheep: sheep, pens: pens))
    }

    static func jsonData(farmID: UUID, sheep: [SheepRecord], pens: [PenRecord]) throws -> Data {
        let preview = makePreview(table: exportTable(farmID: farmID, sheep: sheep, pens: pens), kind: .json, existingEarTags: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(preview.rows)
    }

    static func singleSheepXLSXData(
        sheep: SheepRecord,
        penName: String?,
        weights: [WeightRecord],
        health: [HealthRecord],
        healthRecordIDs: Set<UUID> = [],
        reproduction: [ReproductionRecord],
        transfers: [TransferRecord],
        allSheep: [SheepRecord] = [],
        semenDonors: [SemenDonorRecord] = []
    ) throws -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let pedigreeSheep = allSheep.isEmpty ? [sheep] : allSheep.filter { $0.farmID == sheep.farmID && $0.deletedAt == nil }
        let byID = Dictionary(uniqueKeysWithValues: pedigreeSheep.map { ($0.id, $0) })
        let donor = sheep.semenDonorID.flatMap { id in semenDonors.first { $0.id == id && $0.farmID == sheep.farmID } }
        let profileTable = [
            ["单羊档案", sheep.earTag, "", ""],
            ["字段", "值", "", ""],
            ["品种", sheep.breed, "", ""],
            ["性别", sheep.sex.displayName, "", ""],
            ["状态", sheep.status.displayName, "", ""],
            ["当前圈舍", sheep.currentPenDisplayName(penName), "", ""],
            ["入场时间", formatter.string(from: sheep.enteredAt), "", ""],
            ["出生日期", sheep.birthAt.map(formatter.string(from:)) ?? "", "", ""],
            ["母本", sheep.damID.flatMap { byID[$0]?.earTag } ?? "未知", sheep.damProvenance?.displayName ?? "", ""],
            ["父本", sheep.sireID.flatMap { byID[$0]?.earTag } ?? "未知", sheep.sireProvenance?.displayName ?? "", ""],
            ["冻精供体", donor?.name ?? sheep.semenDonorNameSnapshot ?? "", donor?.registrationNumber ?? sheep.semenDonorRegistrationNumberSnapshot ?? "", sheep.semenDonorBreedSnapshot ?? donor?.breed ?? ""],
            ["种公羊资格", sheep.isBreedingRam ? "种公羊" : "否", "", ""],
            ["备注", sheep.note, "", ""],
        ]
        let weightRows = weights.filter { $0.farmID == sheep.farmID && $0.sheepID == sheep.id && $0.deletedAt == nil }.map { ["称重", formatter.string(from: $0.occurredAt), "\($0.kilogramsText) 千克", $0.note] }
        let healthRows = health.filter { $0.farmID == sheep.farmID && ($0.sheepID == sheep.id || healthRecordIDs.contains($0.id)) && $0.deletedAt == nil }.map { [HealthRecordKind(rawValue: $0.kindRawValue)?.displayName ?? "健康", formatter.string(from: $0.occurredAt), $0.itemNameSnapshot, $0.note] }
        let reproductionRows = reproduction.filter { $0.farmID == sheep.farmID && $0.eweID == sheep.id && $0.deletedAt == nil }.map { [ReproductionRecordKind(rawValue: $0.kindRawValue)?.displayName ?? "繁殖", formatter.string(from: $0.occurredAt), $0.result, $0.note] }
        let transferRows = transfers.filter { $0.farmID == sheep.farmID && $0.sheepID == sheep.id && $0.deletedAt == nil }.map { ["转群", formatter.string(from: $0.occurredAt), "圈舍变更", $0.note] }
        let timeline = (weightRows + healthRows + reproductionRows + transferRows).sorted { $0[1] < $1[1] }
        let timelineTable = [["时间线类型", "发生时间", "内容", "备注"]] + timeline

        let parentIDs = [sheep.damID, sheep.sireID].compactMap { $0 }
        let grandparentIDs = parentIDs.flatMap { id -> [UUID] in
            guard let parent = byID[id] else { return [] }
            return [parent.damID, parent.sireID].compactMap { $0 }
        }
        let relationRows = (parentIDs + grandparentIDs).enumerated().compactMap { index, id -> [String]? in
            guard let relative = byID[id] else { return nil }
            return [index < parentIDs.count ? "父母" : "祖父母", relative.earTag, relative.sex.displayName, relative.breed]
        }
        let pedigreeTable = [["关系", "耳号", "性别", "品种"]] + relationRows
        let children = pedigreeSheep.filter { $0.damID == sheep.id || $0.sireID == sheep.id }.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
        let childTable = [["耳号", "性别", "出生日期", "关系来源", "冻精供体快照"]] + children.map { child in
            [child.earTag, child.sex.displayName, child.birthAt.map(formatter.string(from:)) ?? "", (child.damID == sheep.id ? child.damProvenance : child.sireProvenance)?.displayName ?? "历史资料", child.semenDonorNameSnapshot ?? ""]
        }
        return try XLSXCodec.encode(sheets: [
            XLSXSheet(name: "单羊档案", rows: profileTable),
            XLSXSheet(name: "系谱关系", rows: pedigreeTable),
            XLSXSheet(name: "直接后代", rows: childTable),
            XLSXSheet(name: "时间线", rows: timelineTable),
        ])
    }

    private static func exportTable(farmID: UUID, sheep: [SheepRecord], pens: [PenRecord]) -> [[String]] {
        let penNames = Dictionary(uniqueKeysWithValues: pens.filter { $0.farmID == farmID && $0.deletedAt == nil }.map { ($0.id, $0.name) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let rows = sheep.filter { $0.farmID == farmID && $0.deletedAt == nil }.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }.map {
            [$0.earTag, $0.breed, $0.sex.displayName, $0.currentPenID.flatMap { penNames[$0] } ?? "", formatter.string(from: $0.enteredAt), $0.birthAt.map(formatter.string(from:)) ?? "", $0.note]
        }
        return [columns] + rows
    }

    private static func previewJSON(_ data: Data, existingEarTags: Set<String>) throws -> FarmImportPreview {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let rows = try decoder.decode([FarmImportRow].self, from: data)
            return validate(rows: rows, kind: .json, existingEarTags: existingEarTags)
        } catch {
            throw FarmDataInterchangeError.malformedFile("JSON 结构不符合导入清单。")
        }
    }

    private static func makePreview(table: [[String]], kind: FarmImportFileKind, existingEarTags: Set<String>) -> FarmImportPreview {
        guard let header = table.first else { return FarmImportPreview(formatVersion: 1, fileKind: kind, rows: [], issues: [], duplicateRowNumbers: []) }
        let indexes = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element.trimmingCharacters(in: .whitespacesAndNewlines), $0.offset) })
        var rows: [FarmImportRow] = []
        var issues: [FarmImportIssue] = []
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.isLenient = false
        dateFormatter.dateFormat = "yyyy-MM-dd"

        func value(_ row: [String], _ name: String) -> String {
            guard let index = indexes[name], row.indices.contains(index) else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (offset, source) in table.dropFirst().enumerated() {
            let rowNumber = offset + 2
            let earTag = value(source, "耳号")
            let breed = value(source, "品种")
            if earTag.isEmpty { issues.append(.init(rowNumber: rowNumber, field: "耳号", message: "耳号不能为空。", severity: .error)) }
            if breed.isEmpty { issues.append(.init(rowNumber: rowNumber, field: "品种", message: "品种不能为空。", severity: .error)) }
            let enteredText = value(source, "入场日期")
            guard let enteredAt = spreadsheetDate(enteredText, formatter: dateFormatter) else {
                issues.append(.init(rowNumber: rowNumber, field: "入场日期", message: "请使用 yyyy-MM-dd。", severity: .error))
                continue
            }
            let birthText = value(source, "出生日期")
            let birthAt = birthText.isEmpty ? nil : spreadsheetDate(birthText, formatter: dateFormatter)
            if !birthText.isEmpty && birthAt == nil { issues.append(.init(rowNumber: rowNumber, field: "出生日期", message: "请使用 yyyy-MM-dd。", severity: .error)) }
            let sexText = value(source, "性别")
            let sex: SheepSex = sexText == "母羊" || sexText.lowercased() == "ewe" ? .ewe : (sexText == "公羊" || sexText.lowercased() == "ram" ? .ram : .unknown)
            let key = stableKey(earTag: earTag, enteredAt: enteredAt)
            rows.append(.init(rowNumber: rowNumber, idempotencyKey: key, earTag: earTag, breed: breed, sex: sex, penName: optional(value(source, "圈舍")), enteredAt: enteredAt, birthAt: birthAt, note: value(source, "备注")))
        }
        return validate(rows: rows, kind: kind, existingEarTags: existingEarTags, initialIssues: issues)
    }

    private static func validate(rows: [FarmImportRow], kind: FarmImportFileKind, existingEarTags: Set<String>, initialIssues: [FarmImportIssue] = []) -> FarmImportPreview {
        var seen = Set<String>()
        let existing = Set(existingEarTags.map(EarTag.normalized))
        var duplicates: [Int] = []
        var issues = initialIssues
        for row in rows {
            let normalized = EarTag.normalized(row.earTag)
            if existing.contains(normalized) || !seen.insert(normalized).inserted {
                duplicates.append(row.rowNumber)
                issues.append(.init(rowNumber: row.rowNumber, field: "耳号", message: "耳号已存在，将跳过。", severity: .warning))
            }
        }
        return FarmImportPreview(formatVersion: 1, fileKind: kind, rows: rows, issues: issues, duplicateRowNumbers: duplicates)
    }

    private static func stableKey(earTag: String, enteredAt: Date) -> String {
        "sheep:\(EarTag.normalized(earTag)):\(Int(enteredAt.timeIntervalSince1970))"
    }

    private static func optional(_ text: String) -> String? { text.isEmpty ? nil : text }

    private static func spreadsheetDate(_ text: String, formatter: DateFormatter) -> Date? {
        let strictDateRange = text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression)
        if strictDateRange != nil, let date = formatter.date(from: text), formatter.string(from: date) == text { return date }
        guard let serial = Double(text), serial >= 1, serial < 2_958_466 else { return nil }
        // Excel 的 1900 日期系统包含虚构的 1900-02-29；1899-12-30 基准可保持现代日期一致。
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 1899; components.month = 12; components.day = 30
        guard let epoch = components.date else { return nil }
        return epoch.addingTimeInterval(serial * 86_400)
    }
}

enum SecureImportFileLoader {
    static func load(from sourceURL: URL, maximumBytes: Int = 25 * 1024 * 1024) throws -> Data {
        guard sourceURL.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { sourceURL.stopAccessingSecurityScopedResource() }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { throw FarmDataInterchangeError.unsupportedFile }
                guard (values.fileSize ?? 0) <= maximumBytes else { throw FarmDataInterchangeError.oversizedArchive }
                let temporary = FileManager.default.temporaryDirectory.appending(path: "esheep-import-\(UUID().uuidString).\(coordinatedURL.pathExtension)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: coordinatedURL, to: temporary)
                let data = try Data(contentsOf: temporary, options: [.mappedIfSafe])
                guard data.count <= maximumBytes else { throw FarmDataInterchangeError.oversizedArchive }
                result = .success(data)
            } catch { result = .failure(error) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FarmDataInterchangeError.malformedFile("文件协调失败。") }
        return try result.get()
    }
}

@MainActor
enum FarmImportCommitService {
    static func commit(
        _ preview: FarmImportPreview,
        account: AccountProfile,
        farm: FarmRecord,
        context: ModelContext,
        commandService: FarmCommandService = FarmCommandService()
    ) throws -> FarmImportCommitResult {
        let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
        var pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farm.id && $0.deletedAt == nil }
        let existing = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farm.id }.map { EarTag.normalized($0.earTag) }
        var knownTags = Set(existing)
        var imported = 0, skipped = preview.rows.count - preview.acceptedRows.count
        for row in preview.acceptedRows {
            guard knownTags.insert(EarTag.normalized(row.earTag)).inserted else { skipped += 1; continue }
            var penID: UUID?
            if let requestedPen = row.penName {
                if let pen = pens.first(where: { $0.name.localizedCaseInsensitiveCompare(requestedPen) == .orderedSame }) {
                    penID = pen.id
                } else {
                    try commandService.execute(.createPen(name: requestedPen, note: "由导入文件创建"), in: farmContext, context: context)
                    pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farm.id && $0.deletedAt == nil }
                    penID = pens.first(where: { $0.name.localizedCaseInsensitiveCompare(requestedPen) == .orderedSame })?.id
                }
            }
            try commandService.execute(.addSheep(earTag: row.earTag, breed: row.breed, sex: row.sex, penID: penID, occurredAt: row.enteredAt, birthAt: row.birthAt, note: row.note), in: farmContext, context: context)
            imported += 1
        }
        return FarmImportCommitResult(importedCount: imported, skippedCount: skipped)
    }
}

struct FarmInterchangeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.officeOpenXMLSpreadsheet, .json, .commaSeparatedText] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private enum CSVCodec {
    static func decode(_ data: Data) throws -> [[String]] {
        var text = String(decoding: data, as: UTF8.self)
        if text.first == "\u{FEFF}" { text.removeFirst() }
        var result: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 } else { quoted = false }
                } else { field.append(character) }
            } else {
                switch character {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))); result.append(row); row = []; field = ""
                default: field.append(character)
                }
            }
            index += 1
        }
        if quoted { throw FarmDataInterchangeError.malformedFile("CSV 引号未闭合。") }
        if !field.isEmpty || !row.isEmpty { row.append(field); result.append(row) }
        return result.filter { !$0.allSatisfy { $0.isEmpty } }
    }
}

struct XLSXSheet: Sendable, Equatable {
    let name: String
    let rows: [[String]]
}

enum XLSXCodec {
    static func encode(table: [[String]]) throws -> Data {
        try encode(sheets: [XLSXSheet(name: "羊只档案", rows: table)])
    }

    static func encode(sheets: [XLSXSheet]) throws -> Data {
        guard !sheets.isEmpty else { throw FarmDataInterchangeError.malformedFile("工作簿不能为空。") }
        var usedNames = Set<String>()
        let normalized = sheets.enumerated().map { index, sheet -> XLSXSheet in
            var base = String(sheet.name.prefix(31)).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
            if base.isEmpty { base = "工作表\(index + 1)" }
            var candidate = base, suffix = 2
            while !usedNames.insert(candidate.lowercased()).inserted {
                let tail = "-\(suffix)"; candidate = String(base.prefix(max(1, 31 - tail.count))) + tail; suffix += 1
            }
            return XLSXSheet(name: candidate, rows: sheet.rows)
        }
        var entries: [(String, Data)] = []
        let overrides = normalized.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined()
        entries.append(("[Content_Types].xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(overrides)</Types>".utf8)))
        entries.append(("_rels/.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>".utf8)))
        let workbookSheets = normalized.enumerated().map { "<sheet name=\"\(xmlEscape($0.element.name))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined()
        entries.append(("xl/workbook.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(workbookSheets)</sheets></workbook>".utf8)))
        let relationships = normalized.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined() + "<Relationship Id=\"rId\(normalized.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        entries.append(("xl/_rels/workbook.xml.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>".utf8)))
        entries.append(("xl/styles.xml", Data(stylesXML.utf8)))
        for (sheetIndex, sheet) in normalized.enumerated() {
            let sheetRows = sheet.rows.enumerated().map { rowIndex, row in
            let cells = row.enumerated().map { columnIndex, value in
                let ref = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                let style = rowIndex == 0 ? " s=\"1\"" : (value.hasPrefix("示例") ? " s=\"2\"" : "")
                return "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
            }.joined()
            return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
            }.joined()
            let maxColumns = max(sheet.rows.map(\.count).max() ?? 1, 1)
            let cols = (1...maxColumns).map { "<col min=\"\($0)\" max=\"\($0)\" width=\"18\" customWidth=\"1\"/>" }.joined()
            let autoFilter = sheet.rows.count > 1 ? "<autoFilter ref=\"A1:\(columnName(maxColumns))\(sheet.rows.count)\"/>" : ""
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols>\(cols)</cols><sheetData>\(sheetRows)</sheetData>\(autoFilter)</worksheet>"
            entries.append(("xl/worksheets/sheet\(sheetIndex + 1).xml", Data(xml.utf8)))
        }
        return ZIPArchive.encode(entries)
    }

    static func decode(_ data: Data) throws -> [[String]] {
        guard let first = try decodeSheets(data).first else { throw FarmDataInterchangeError.malformedFile("XLSX 缺少工作表。") }
        return first.rows
    }

    static func decodeSheets(_ data: Data) throws -> [XLSXSheet] {
        let entries = try ZIPArchive.decode(data)
        let shared = entries["xl/sharedStrings.xml"].map(SharedStringsParser.parse) ?? []
        let names = entries["xl/workbook.xml"].map(WorkbookSheetNameParser.parse) ?? []
        var sheets: [XLSXSheet] = []
        for index in 1...max(names.count, 1) {
            guard let xml = entries["xl/worksheets/sheet\(index).xml"] else { continue }
            sheets.append(XLSXSheet(name: names.indices.contains(index - 1) ? names[index - 1] : "工作表\(index)", rows: WorksheetParser.parse(xml, sharedStrings: shared)))
        }
        return sheets
    }

    private static func columnName(_ number: Int) -> String {
        var number = number, result = ""
        while number > 0 { number -= 1; result.insert(Character(UnicodeScalar(65 + number % 26)!), at: result.startIndex); number /= 26 }
        return result
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="11"/><name val="Aptos"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos"/></font><font><i/><color rgb="FF666666"/><sz val="11"/><name val="Aptos"/></font></fonts><fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF2E7D5B"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF2F4F3"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="2" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """
}

private final class WorkbookSheetNameParser: NSObject, XMLParserDelegate {
    private var names: [String] = []
    static func parse(_ data: Data) -> [String] { let delegate = WorkbookSheetNameParser(); let parser = XMLParser(data: data); parser.delegate = delegate; parser.parse(); return delegate.names }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "sheet", let name = attributeDict["name"] { names.append(name) }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var values: [String] = [], current = ""
    private var capturesText = false
    static func parse(_ data: Data) -> [String] { let delegate = SharedStringsParser(); let parser = XMLParser(data: data); parser.delegate = delegate; parser.parse(); return delegate.values }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) { if elementName == "si" { current = "" }; if elementName == "t" { capturesText = true } }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capturesText { current += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if elementName == "t" { capturesText = false }; if elementName == "si" { values.append(current) } }
}

private final class WorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [[String]] = [], row: [String] = [], cellType = "", cellReference = "", value = "", capturesValue = false
    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }
    static func parse(_ data: Data, sharedStrings: [String]) -> [[String]] { let delegate = WorksheetParser(sharedStrings: sharedStrings); let parser = XMLParser(data: data); parser.delegate = delegate; parser.parse(); return delegate.rows }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "row" { row = [] }
        if elementName == "c" { cellType = attributeDict["t"] ?? ""; cellReference = attributeDict["r"] ?? ""; value = "" }
        if elementName == "v" || elementName == "t" { capturesValue = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capturesValue { value += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "v" || elementName == "t" { capturesValue = false }
        if elementName == "c" {
            let letters = cellReference.prefix { $0.isLetter }
            let column = letters.reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) }
            while row.count < max(column - 1, 0) { row.append("") }
            let resolved = cellType == "s" ? (Int(value).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? "") : value
            row.append(resolved)
        }
        if elementName == "row" { rows.append(row) }
    }
}

private enum ZIPArchive {
    static func encode(_ entries: [(String, Data)]) -> Data {
        var output = Data(), central = Data(), offset: UInt32 = 0
        for (name, contents) in entries {
            let nameData = Data(name.utf8), crc = contents.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(contents.count)) }
            var local = Data(); local.appendLE(UInt32(0x04034b50)); local.appendLE(UInt16(20)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt32(crc)); local.appendLE(UInt32(contents.count)); local.appendLE(UInt32(contents.count)); local.appendLE(UInt16(nameData.count)); local.appendLE(UInt16(0)); local.append(nameData); local.append(contents)
            output.append(local)
            var header = Data(); header.appendLE(UInt32(0x02014b50)); header.appendLE(UInt16(20)); header.appendLE(UInt16(20)); header.appendLE(UInt16(0)); header.appendLE(UInt16(0)); header.appendLE(UInt16(0)); header.appendLE(UInt16(0)); header.appendLE(UInt32(crc)); header.appendLE(UInt32(contents.count)); header.appendLE(UInt32(contents.count)); header.appendLE(UInt16(nameData.count)); header.appendLE(UInt16(0)); header.appendLE(UInt16(0)); header.appendLE(UInt16(0)); header.appendLE(UInt16(0)); header.appendLE(UInt32(0)); header.appendLE(offset); header.append(nameData); central.append(header)
            offset += UInt32(local.count)
        }
        let centralOffset = UInt32(output.count); output.append(central)
        output.appendLE(UInt32(0x06054b50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt16(entries.count)); output.appendLE(UInt32(central.count)); output.appendLE(centralOffset); output.appendLE(UInt16(0))
        return output
    }

    static func decode(_ archive: Data) throws -> [String: Data] {
        var cursor = 0, result: [String: Data] = [:], total = 0
        while cursor + 30 <= archive.count, archive.uint32(at: cursor) == 0x04034b50 {
            let flags = archive.uint16(at: cursor + 6), method = archive.uint16(at: cursor + 8)
            guard flags & 0x08 == 0 else { throw FarmDataInterchangeError.malformedFile("不支持数据描述符 ZIP。") }
            let compressedSize = Int(archive.uint32(at: cursor + 18)), uncompressedSize = Int(archive.uint32(at: cursor + 22)), nameLength = Int(archive.uint16(at: cursor + 26)), extraLength = Int(archive.uint16(at: cursor + 28))
            let nameStart = cursor + 30, dataStart = nameStart + nameLength + extraLength, dataEnd = dataStart + compressedSize
            guard dataEnd <= archive.count, let name = String(data: archive[nameStart..<(nameStart + nameLength)], encoding: .utf8), !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw FarmDataInterchangeError.unsafeArchivePath }
            let compressed = Data(archive[dataStart..<dataEnd]), contents: Data
            if method == 0 { contents = compressed }
            else if method == 8 { contents = try inflate(compressed, expectedSize: uncompressedSize) }
            else { throw FarmDataInterchangeError.malformedFile("XLSX 使用了不支持的压缩方式。") }
            total += contents.count; if total > 50 * 1024 * 1024 { throw FarmDataInterchangeError.oversizedArchive }
            result[name] = contents; cursor = dataEnd
        }
        return result
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        let outputCapacity = max(expectedSize, 1)
        var stream = z_stream(), output = Data(count: outputCapacity)
        let status = data.withUnsafeBytes { input in output.withUnsafeMutableBytes { destination -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count); stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(outputCapacity)
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Z_MEM_ERROR }
            defer { inflateEnd(&stream) }
            return zlib.inflate(&stream, Z_FINISH)
        } }
        guard status == Z_STREAM_END else { throw FarmDataInterchangeError.malformedFile("XLSX 解压失败。") }
        output.count = Int(stream.total_out); return output
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) } }
    func uint16(at offset: Int) -> UInt16 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian } }
    func uint32(at offset: Int) -> UInt32 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian } }
}
