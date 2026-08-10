import CryptoKit
import Foundation
import SwiftData

enum LegacyFeedIncrementalImportError: LocalizedError {
    case noFeedRecords
    case unmatchedPens([String])
    case invalidFeed(String)
    case accountCannotImport

    var errorDescription: String? {
        switch self {
        case .noFeedRecords: "所选文件中没有 eSheep+ 投喂记录。"
        case .unmatchedPens(let names): "以下圈舍无法对应当前牧场：\(names.joined(separator: "、"))。请先在当前牧场核对圈舍名称。"
        case .invalidFeed(let detail): "投喂记录无法解析：\(detail)"
        case .accountCannotImport: "只有牧场主或管理员可以合并历史投喂。"
        }
    }
}

struct LegacyFeedMergePreview: Sendable {
    let sourceChecksum: String
    let sourceFileName: String
    let sourceFileDate: Date?
    let sourceRecordCount: Int
    let duplicateCount: Int
    let unmatchedPenNames: [String]
    let newIngredientCount: Int
    let newFeeds: [HistoricalFeedEntryDraft]
    let ingredientCommands: [FeedIngredientDraft]

    var canCommit: Bool { !newFeeds.isEmpty && unmatchedPenNames.isEmpty }
}

struct LegacyFeedMergeResult: Sendable, Equatable {
    let importedFeedCount: Int
    let importedLineCount: Int
    let createdIngredientCount: Int
}

@MainActor
enum LegacyFeedIncrementalImportService {
    static func preview(
        source: Data,
        sourceFileName: String,
        sourceFileDate: Date?,
        farmID: UUID,
        context: ModelContext
    ) throws -> LegacyFeedMergePreview {
        let root = try LegacySourceDecoder.decode(source).root
        let feeding = (root["feeding"] as? [String: Any]) ?? [:]
        let rawFeeds = feeding["feedRecords"] as? [[String: Any]] ?? []
        guard !rawFeeds.isEmpty else { throw LegacyFeedIncrementalImportError.noFeedRecords }

        let pens = try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let penByName = pens.reduce(into: [String: PenRecord]()) { result, pen in result[normalizedName(pen.name)] = pen }
        let ingredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        var ingredientIDByName = ingredients.reduce(into: [String: UUID]()) { result, ingredient in result[normalizedName(ingredient.name)] = ingredient.id }
        let existingFeeds = try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let existingLines = try context.fetch(FetchDescriptor<FeedRecordLine>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let linesByFeed = Dictionary(grouping: existingLines, by: \.feedRecordID)
        let existingSignatures = Set(existingFeeds.compactMap { feed -> String? in
            guard let pen = pens.first(where: { $0.id == feed.penID }) else { return nil }
            return signature(
                penName: pen.name,
                occurredAt: feed.occurredAt,
                mode: feed.mode,
                mealName: feed.mealName,
                feederName: feed.feederName,
                note: feed.note,
                lines: (linesByFeed[feed.id] ?? []).map { ($0.ingredientNameSnapshot, $0.kilogramsText) }
            )
        })
        let existingIDs = Set(existingFeeds.map(\.id))
        let library = feeding["feedLibrary"] as? [[String: Any]] ?? []
        let libraryByID = Dictionary(uniqueKeysWithValues: library.compactMap { item -> (String, [String: Any])? in
            let id = text(item["id"])
            return id.isEmpty ? nil : (id, item)
        })

        var newIngredients: [FeedIngredientDraft] = []
        var newFeeds: [HistoricalFeedEntryDraft] = []
        var duplicateCount = 0
        var unmatched = Set<String>()
        let checksum = digest(source)

        for (index, raw) in rawFeeds.enumerated() {
            let penName = text(raw["pen"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pen = penByName[normalizedName(penName)] else {
                unmatched.insert(penName.isEmpty ? "第 \(index + 1) 条记录（圈舍为空）" : penName)
                continue
            }
            guard let occurredAt = timestamp(dateText: text(raw["date"]), timeText: text(raw["time"])) else {
                throw LegacyFeedIncrementalImportError.invalidFeed("第 \(index + 1) 条缺少有效日期")
            }
            let rawLines = raw["ingredients"] as? [[String: Any]] ?? []
            guard !rawLines.isEmpty else { throw LegacyFeedIncrementalImportError.invalidFeed("第 \(index + 1) 条没有原料明细") }
            let mode: FeedMode = text(raw["mode"]).lowercased().contains("free") || text(raw["mode"]).contains("自由") ? .freeChoice : .limited
            let sourceID = text(raw["id"])
            let lineIdentity = rawLines.map { "\(text($0["name"])):\(decimalText($0["amount"]) ?? "")" }.joined(separator: "|")
            let fallbackIdentity = digest(Data("\(penName)|\(occurredAt.timeIntervalSince1970)|\(mode.rawValue)|\(lineIdentity)|\(text(raw["mealName"]))|\(text(raw["feederName"]))|\(text(raw["note"]))".utf8))
            let sourceIdentity = sourceID.isEmpty ? fallbackIdentity : sourceID
            let legacySourceKey = "esheepplus-feed:\(sourceIdentity)"
            let feedID = StableCloudUUID.derived(namespace: farmID, name: legacySourceKey)
            let canonical = signature(penName: penName, occurredAt: occurredAt, mode: mode, mealName: text(raw["mealName"]), feederName: text(raw["feederName"]), note: text(raw["note"]), lines: rawLines.map { (text($0["name"]), decimalText($0["amount"]) ?? "") })
            if existingIDs.contains(feedID) || existingFeeds.contains(where: { $0.legacySourceKey == legacySourceKey }) || existingSignatures.contains(canonical) {
                duplicateCount += 1
                continue
            }

            var lines: [HistoricalFeedLineDraft] = []
            for (lineIndex, rawLine) in rawLines.enumerated() {
                let name = text(rawLine["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let amount = decimalText(rawLine["amount"]), Decimal.stable(amount).map({ $0 > 0 }) == true else {
                    throw LegacyFeedIncrementalImportError.invalidFeed("第 \(index + 1) 条的第 \(lineIndex + 1) 项原料或用量无效")
                }
                let libraryItem = libraryByID[text(rawLine["ingredientId"])]
                let key = normalizedName(name)
                let ingredientID: UUID
                if let existing = ingredientIDByName[key] {
                    ingredientID = existing
                } else {
                    ingredientID = StableCloudUUID.derived(namespace: farmID, name: "esheepplus-historical-ingredient:\(key)")
                    ingredientIDByName[key] = ingredientID
                    let nutrientJSON = jsonText(rawLine["nutrientsSnapshot"]) ?? jsonText(libraryItem?["nutrients"]) ?? "{}"
                    let dryMatter = nutrientValue(rawLine["nutrientsSnapshot"], keys: ["dm", "dryMatter", "DM"]) ?? nutrientValue(libraryItem?["nutrients"], keys: ["dm", "dryMatter", "DM"])
                    newIngredients.append(FeedIngredientDraft(id: ingredientID, name: name, unit: "千克", category: "历史投喂", dryMatterText: dryMatter, nutrientSnapshotJSON: nutrientJSON, kind: .legacy, sourceTemplateID: nil, sourceTemplateCode: nil, mixtureComponentsJSON: nil, note: "由 eSheep+ 历史投喂补录自动建立；不建立库存。"))
                }
                let nutrientJSON = jsonText(rawLine["nutrientsSnapshot"]) ?? jsonText(libraryItem?["nutrients"]) ?? "{}"
                let dryMatter = nutrientValue(rawLine["nutrientsSnapshot"], keys: ["dm", "dryMatter", "DM"]) ?? nutrientValue(libraryItem?["nutrients"], keys: ["dm", "dryMatter", "DM"])
                lines.append(HistoricalFeedLineDraft(
                    id: StableCloudUUID.derived(namespace: feedID, name: "line-\(lineIndex)"),
                    ingredientID: ingredientID,
                    kilogramsText: amount,
                    ingredientNameSnapshot: name,
                    ingredientBatchNameSnapshot: optionalText(rawLine["batchNameSnapshot"]),
                    pricePerKilogramTextSnapshot: decimalText(rawLine["pricePerKgSnapshot"]),
                    nutrientSnapshotJSON: nutrientJSON,
                    unitSnapshot: "千克",
                    dryMatterTextSnapshot: dryMatter
                ))
            }
            let remainingJSON = jsonText(raw["remainingPercents"])
            newFeeds.append(HistoricalFeedEntryDraft(
                id: feedID,
                legacySourceKey: legacySourceKey,
                penID: pen.id,
                mode: mode,
                occurredAt: occurredAt,
                mealName: text(raw["mealName"]),
                feederName: text(raw["feederName"]),
                remainingKilogramsText: decimalText(raw["remainingKg"]),
                discardedKilogramsText: decimalText(raw["discardedKg"]),
                remainingCompositionJSON: remainingJSON,
                lines: lines,
                note: text(raw["note"])
            ))
        }

        return LegacyFeedMergePreview(sourceChecksum: checksum, sourceFileName: sourceFileName, sourceFileDate: sourceFileDate, sourceRecordCount: rawFeeds.count, duplicateCount: duplicateCount, unmatchedPenNames: unmatched.sorted(), newIngredientCount: newIngredients.count, newFeeds: newFeeds.sorted { $0.occurredAt < $1.occurredAt }, ingredientCommands: newIngredients)
    }

    static func commit(_ preview: LegacyFeedMergePreview, account: AccountProfile, farm: FarmRecord, context: ModelContext) throws -> LegacyFeedMergeResult {
        guard farm.role == .owner || farm.role == .administrator else { throw LegacyFeedIncrementalImportError.accountCannotImport }
        guard preview.unmatchedPenNames.isEmpty else { throw LegacyFeedIncrementalImportError.unmatchedPens(preview.unmatchedPenNames) }
        let commands: [(command: FarmCommand, sourceRequestID: UUID)] = preview.ingredientCommands.map {
            (.saveFeedIngredient($0), StableCloudUUID.derived(namespace: farm.id, name: "plus-feed-ingredient-command:\($0.id?.uuidString ?? $0.name)"))
        } + preview.newFeeds.map {
            (.importHistoricalFeed($0), StableCloudUUID.derived(namespace: farm.id, name: "plus-feed-command:\($0.legacySourceKey)"))
        }
        _ = try FarmCommandService().executeBatch(commands, in: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role), context: context)
        return LegacyFeedMergeResult(importedFeedCount: preview.newFeeds.count, importedLineCount: preview.newFeeds.reduce(0) { $0 + $1.lines.count }, createdIngredientCount: preview.ingredientCommands.count)
    }

    private static func normalizedName(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN")) }
    private static func text(_ value: Any?) -> String { if let value = value as? String { return value }; if let value { return String(describing: value) }; return "" }
    private static func optionalText(_ value: Any?) -> String? { let value = text(value).trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
    private static func decimalText(_ value: Any?) -> String? { if let value = value as? NSNumber { return Decimal(value.doubleValue).stableText }; if let value = value as? String, let decimal = Decimal.stable(value) { return decimal.stableText }; return nil }
    private static func jsonText(_ value: Any?) -> String? { guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }; return String(data: data, encoding: .utf8) }
    private static func nutrientValue(_ value: Any?, keys: [String]) -> String? { guard let values = value as? [String: Any] else { return nil }; for key in keys { if let result = decimalText(values[key]) { return result } }; return nil }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func signature(penName: String, occurredAt: Date, mode: FeedMode, mealName: String, feederName: String, note: String, lines: [(String, String)]) -> String {
        let lineText = lines.map { "\(normalizedName($0.0)):\(Decimal.stable($0.1)?.stableText ?? $0.1)" }.sorted().joined(separator: "|")
        return digest(Data("\(normalizedName(penName))|\(Int(occurredAt.timeIntervalSince1970))|\(mode.rawValue)|\(normalizedName(mealName))|\(normalizedName(feederName))|\(note.trimmingCharacters(in: .whitespacesAndNewlines))|\(lineText)".utf8))
    }
    private static func timestamp(dateText: String, timeText: String) -> Date? {
        let combined = timeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? dateText : "\(dateText) \(timeText)"
        if let date = ISO8601DateFormatter().date(from: combined) { return date }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = format
            if let date = formatter.date(from: combined) { return date }
        }
        return nil
    }
}
