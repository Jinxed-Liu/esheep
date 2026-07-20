import CryptoKit
import Foundation
import SwiftData

enum MigrationIssueSeverity: String, Codable, Sendable { case blocking, warning, resolved }

struct MigrationManifest: Codable, Sendable, Equatable {
    let sessionID: UUID; let sourceChecksum: String; let sourceSchemaVersion: String?; let importedAt: Date; let importerVersion: Int
}

struct MigrationIssue: Codable, Sendable, Identifiable, Equatable {
    let id: UUID; var severity: MigrationIssueSeverity; var title: String; var detail: String; var sourceKey: String?
    init(severity: MigrationIssueSeverity, title: String, detail: String, sourceKey: String? = nil) { id = UUID(); self.severity = severity; self.title = title; self.detail = detail; self.sourceKey = sourceKey }
}

struct MigrationSheepCandidate: Codable, Sendable, Identifiable, Equatable {
    let id: String; let legacyEarTag: String; let breed: String; let sex: String; let pen: String; let birth: String; let status: String; let purpose: String; let note: String; var finalEarTag: String?; var enteredAtText: String?; var isHistoricalArchive: Bool?
}

struct MigrationRecordAssignment: Codable, Sendable, Identifiable, Equatable {
    let id: String; let kind: String; let legacyEarTag: String; let dateText: String; let penHint: String?; var targetSheepSourceKey: String?; var exclusionReason: String?
    var isResolved: Bool { targetSheepSourceKey != nil || exclusionReason != nil }
}

enum MigrationDecision: Sendable, Equatable { case renameSheep(sourceKey: String, finalEarTag: String), assignRecord(recordKey: String, sheepSourceKey: String), excludeRecord(recordKey: String, reason: String) }

struct MigrationSession: Codable, Sendable, Identifiable, Equatable {
    let id: UUID; let manifest: MigrationManifest; let sourcePayload: Data; var inspectorReport: LegacyMigrationReport; var sheep: [MigrationSheepCandidate]; var assignments: [MigrationRecordAssignment]; var issues: [MigrationIssue]
    var duplicateGroups: [[MigrationSheepCandidate]] { Dictionary(grouping: sheep, by: { EarTag.normalized($0.legacyEarTag) }).values.filter { $0.count > 1 }.sorted { ($0.first?.legacyEarTag ?? "") < ($1.first?.legacyEarTag ?? "") } }
    var blockingIssues: [MigrationIssue] { issues.filter { $0.severity == .blocking } }
    var isReadyForTemporaryBuild: Bool { inspectorReport.isReadyForDryRun && blockingIssues.isEmpty && assignments.allSatisfy(\.isResolved) }
}

struct LegacySourceDocument { let root: [String: Any] }
enum LegacySourceDecoder {
    static func decode(_ data: Data) throws -> LegacySourceDocument {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MigrationError.invalidSource }
        guard root["herd"] == nil else { return LegacySourceDocument(root: root) }
        var normalized = root
        normalized["herd"] = ["sheep": root["sheep"] ?? [], "removals": root["removals"] ?? [], "transfers": root["transfers"] ?? [], "events": root["events"] ?? [], "weanRecords": root["weanRecords"] ?? [], "abortionRecords": root["abortionRecords"] ?? [], "weighRecords": root["weighRecords"] ?? [], "customPens": root["customPens"] ?? [], "pens": root["pens"] ?? [], "productionBatches": root["productionBatches"] ?? [], "batchMemberships": root["batchMemberships"] ?? []]
        normalized["reproduction"] = ["lambing": root["lambing"] ?? [], "breedPrograms": root["breedPrograms"] ?? [], "semenRecords": root["semenRecords"] ?? []]
        normalized["feeding"] = ["feedRecords": root["feedRecords"] ?? [], "feedLibrary": root["feedLibrary"] ?? [], "feedRecipes": root["feedRecipes"] ?? []]
        normalized["health"] = ["vaccineCatalog": root["vaccineCatalog"] ?? [], "medicineCatalog": root["medicineCatalog"] ?? [], "diseaseCatalog": root["diseaseCatalog"] ?? [], "inventoryLots": root["inventoryLots"] ?? [], "inventoryTransactions": root["inventoryTransactions"] ?? [], "vaccineRecords": root["vaccineRecords"] ?? [], "treatmentRecords": root["treatmentRecords"] ?? []]
        normalized["media"] = ["photoData": root["photoData"] ?? [:]]
        normalized["farmSettings"] = ["farmName": root["farmName"] ?? ""]
        return LegacySourceDocument(root: normalized)
    }
}

struct LegacyMappingTable { var sheep: [String: UUID] = [:]; var pens: [String: UUID] = [:]; var ingredients: [String: UUID] = [:]; var feedIngredientBatches: [String: UUID] = [:]; var recipes: [String: UUID] = [:]; var batches: [String: UUID] = [:]; var inventoryLots: [String: UUID] = [:] }

struct MigrationBuildWorkspace {
    let sessionID: UUID
    let directory: URL
    var storeURL: URL { directory.appending(path: "temporary.store") }
    var assetsDirectory: URL { directory.appending(path: "assets", directoryHint: .isDirectory) }
    var reportURL: URL { directory.appending(path: "reconciliation.json") }
}

private struct MigrationActiveBuild: Codable {
    let buildID: String
}

enum StableMigrationID {
    static func uuid(sessionID: UUID, sourceKey: String) -> UUID {
        let hex = SHA256.hash(data: Data("\(sessionID.uuidString.lowercased())|\(sourceKey)".utf8)).map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))")!
    }
}

enum MigrationWorkspaceStore {
    private static var rootURL: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "eSheepNext/MigrationWorkspaces", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    static func directory(for sessionID: UUID) -> URL { let url = rootURL.appending(path: sessionID.uuidString, directoryHint: .isDirectory); try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
    static func activeWorkspace(for sessionID: UUID) -> MigrationBuildWorkspace {
        let sessionDirectory = directory(for: sessionID)
        let pointerURL = sessionDirectory.appending(path: "active-build.json")
        if let pointer = try? JSONDecoder().decode(MigrationActiveBuild.self, from: Data(contentsOf: pointerURL)) {
            let buildsDirectory = sessionDirectory.appendingPathComponent("builds", isDirectory: true)
            return MigrationBuildWorkspace(sessionID: sessionID, directory: buildsDirectory.appendingPathComponent(pointer.buildID, isDirectory: true))
        }
        // Compatibility for sessions built before the immutable-build layout.
        return MigrationBuildWorkspace(sessionID: sessionID, directory: sessionDirectory.appending(path: "current", directoryHint: .isDirectory))
    }
    static func storeURL(for sessionID: UUID) -> URL { activeWorkspace(for: sessionID).storeURL }
    static func assetsDirectory(for sessionID: UUID) -> URL { activeWorkspace(for: sessionID).assetsDirectory }
    static func save(_ session: MigrationSession) throws { try JSONEncoder().encode(session).write(to: directory(for: session.id).appending(path: "session.json"), options: .atomic) }
    static func load(sessionID: UUID) throws -> MigrationSession { try JSONDecoder().decode(MigrationSession.self, from: Data(contentsOf: directory(for: sessionID).appending(path: "session.json"))) }
    static func allSessions() -> [MigrationSession] { (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil))?.compactMap { try? JSONDecoder().decode(MigrationSession.self, from: Data(contentsOf: $0.appending(path: "session.json"))) }.sorted { $0.manifest.importedAt > $1.manifest.importedAt } ?? [] }
    static func makeStagingWorkspace(for sessionID: UUID) throws -> MigrationBuildWorkspace {
        let buildsDirectory = directory(for: sessionID).appendingPathComponent("builds", isDirectory: true)
        let workspace = MigrationBuildWorkspace(sessionID: sessionID, directory: buildsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: workspace.assetsDirectory, withIntermediateDirectories: true)
        return workspace
    }
    static func discard(_ workspace: MigrationBuildWorkspace) { try? FileManager.default.removeItem(at: workspace.directory) }
    static func commit(_ staging: MigrationBuildWorkspace) throws {
        let sessionDirectory = directory(for: staging.sessionID)
        let pointerURL = sessionDirectory.appending(path: "active-build.json")
        let previousPointerURL = sessionDirectory.appending(path: "previous-build.json")
        if let currentPointerData = try? Data(contentsOf: pointerURL) { try currentPointerData.write(to: previousPointerURL, options: .atomic) }
        try JSONEncoder().encode(MigrationActiveBuild(buildID: staging.directory.lastPathComponent)).write(to: pointerURL, options: .atomic)
    }
    static func hasActiveBuild(for sessionID: UUID) -> Bool { FileManager.default.fileExists(atPath: storeURL(for: sessionID).path(percentEncoded: false)) }
    static func delete(sessionID: UUID) throws { try FileManager.default.removeItem(at: directory(for: sessionID)) }
    static func saveBaseline(_ data: Data, for sessionID: UUID) throws { try data.write(to: directory(for: sessionID).appending(path: "baseline.json"), options: .atomic) }
    static func baseline(for sessionID: UUID) -> MigrationBaselineSnapshot? { try? JSONDecoder().decode(MigrationBaselineSnapshot.self, from: Data(contentsOf: directory(for: sessionID).appending(path: "baseline.json"))) }
}

enum MigrationResolutionService {
    static func apply(_ decision: MigrationDecision, to session: inout MigrationSession) throws {
        switch decision {
        case let .renameSheep(key, tag):
            let normalized = EarTag.normalized(tag); guard !normalized.isEmpty else { throw MigrationError.invalidEarTag }; guard let index = session.sheep.firstIndex(where: { $0.id == key }) else { throw MigrationError.unknownSource }
            guard !session.sheep.enumerated().contains(where: { $0.offset != index && $0.element.finalEarTag.map(EarTag.normalized) == normalized }) else { throw MigrationError.duplicateFinalEarTag }; session.sheep[index].finalEarTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .assignRecord(key, sheepKey):
            guard session.sheep.contains(where: { $0.id == sheepKey }), let index = session.assignments.firstIndex(where: { $0.id == key }) else { throw MigrationError.unknownSource }; session.assignments[index].targetSheepSourceKey = sheepKey; session.assignments[index].exclusionReason = nil
        case let .excludeRecord(key, reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let index = session.assignments.firstIndex(where: { $0.id == key }) else { throw MigrationError.missingExclusionReason }; session.assignments[index].targetSheepSourceKey = nil; session.assignments[index].exclusionReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        refreshIssues(&session); try MigrationWorkspaceStore.save(session)
    }
    static func refreshIssues(_ session: inout MigrationSession) {
        session.issues.removeAll { $0.sourceKey?.hasPrefix("dynamic:") == true }
        for sheep in session.sheep where EarTag.normalized(sheep.legacyEarTag).isEmpty { session.issues.append(MigrationIssue(severity: .blocking, title: "羊只缺少耳号", detail: "来源 \(sheep.id) 没有可用耳号。", sourceKey: "dynamic:empty:\(sheep.id)")) }
        for group in session.duplicateGroups where group.contains(where: { $0.finalEarTag == nil }) { session.issues.append(MigrationIssue(severity: .blocking, title: "重复耳号待确认", detail: "耳号 \(group[0].legacyEarTag) 有 \(group.count) 只羊。", sourceKey: "dynamic:duplicate:\(EarTag.normalized(group[0].legacyEarTag))")) }
        for item in session.assignments where !item.isResolved { session.issues.append(MigrationIssue(severity: .blocking, title: "历史记录待归属", detail: "\(item.kind)（\(item.legacyEarTag)，\(item.dateText)）需要指定羊只或标记无效。", sourceKey: "dynamic:record:\(item.id)")) }
    }
}

enum MigrationError: LocalizedError { case invalidSource, invalidEarTag, duplicateFinalEarTag, unknownSource, missingExclusionReason, notReady, noTemporaryResult
    var errorDescription: String? { switch self { case .invalidSource: "迁移包不是有效 JSON 对象。"; case .invalidEarTag: "耳号不能为空。"; case .duplicateFinalEarTag: "新耳号与牧场内其他羊只重复。"; case .unknownSource: "迁移来源记录不存在。"; case .missingExclusionReason: "标记无效时必须填写原因。"; case .notReady: "迁移会话仍有阻断问题。"; case .noTemporaryResult: "该会话尚无可审阅的临时迁移结果。" } }
}

struct MigrationBaselineSnapshot: Codable, Sendable, Equatable { var expectedCounts: [String: Int]; var dailyPenCounts: [String: Int]? }
enum MigrationDiscrepancySeverity: String, Codable, Sendable { case blocking, warning }
struct MigrationDiscrepancy: Codable, Sendable, Identifiable, Equatable {
    let id: String; let severity: MigrationDiscrepancySeverity; let category: String; let sourceKey: String?; let targetRecordIDs: [UUID]; let reason: String
}
struct MigrationReconciliationReport: Codable, Sendable, Equatable {
    let source: LegacyMigrationCounts; let convertedSheep: Int; let archivalSheep: Int; let convertedPens: Int; let convertedWeights: Int; let convertedTransfers: Int; let convertedRemovals: Int; let excludedRecords: Int; let convertedByType: [String: Int]; let expectedByType: [String: Int]; let discrepancies: [MigrationDiscrepancy]
    var blockingDiscrepancies: [MigrationDiscrepancy] { discrepancies.filter { $0.severity == .blocking } }
}
struct MigrationTemporaryFarm: @unchecked Sendable { let container: ModelContainer; let farmID: UUID; let reconciliation: MigrationReconciliationReport }

enum LegacyMigrationImporter {
    static func preview(source: Data) throws -> MigrationSession {
        let report = try LegacyMigrationInspector.inspect(source); let document = try LegacySourceDecoder.decode(source); let root = document.root; let herd = section("herd", root); let reproduction = section("reproduction", root); let health = section("health", root); let media = section("media", root)
        var candidates = records(herd["sheep"]).enumerated().map { i, item in MigrationSheepCandidate(id: "herd.sheep[\(i)]", legacyEarTag: string(item["tag"]), breed: string(item["breed"]), sex: string(item["sex"]), pen: legacyPenName(string(item["pen"])), birth: string(item["birth"]), status: string(item["status"]), purpose: string(item["purpose"]), note: string(item["note"]), finalEarTag: nil, enteredAtText: string(item["birth"]), isHistoricalArchive: false) }
        var assignments: [MigrationRecordAssignment] = []
        appendAssignments(&assignments, kind: "转群", path: "herd.transfers", records: records(herd["transfers"]), tagKey: "tag", penKey: "to")
        appendAssignments(&assignments, kind: "离场", path: "herd.removals", records: records(herd["removals"]), tagKey: "tag")
        appendAssignments(&assignments, kind: "称重", path: "herd.weighRecords", records: records(herd["weighRecords"]), tagKey: "tag")
        appendAssignments(&assignments, kind: "断奶羊只", path: "herd.weanRecords", records: records(herd["weanRecords"]), tagKey: "tag")
        appendAssignments(&assignments, kind: "流产母羊", path: "herd.abortionRecords", records: records(herd["abortionRecords"]), tagKey: "tag")
        appendAssignments(&assignments, kind: "批次成员", path: "herd.batchMemberships", records: records(herd["batchMemberships"]), tagKey: "sheepTag")
        appendAssignments(&assignments, kind: "产羔母羊", path: "reproduction.lambing", records: records(reproduction["lambing"]), tagKey: "dam", penKey: "pen")
        appendAssignments(&assignments, kind: "治疗", path: "health.treatmentRecords", records: records(health["treatmentRecords"]), tagKey: "sheepTag")
        for (i, vaccine) in records(health["vaccineRecords"]).enumerated() { for (j, tag) in (vaccine["sheepTagsSnapshot"] as? [String] ?? []).enumerated() { assignments.append(MigrationRecordAssignment(id: "health.vaccineRecords[\(i)].sheepTagsSnapshot[\(j)]", kind: "免疫对象", legacyEarTag: tag, dateText: string(vaccine["date"]), penHint: string(vaccine["pen"]), targetSheepSourceKey: nil, exclusionReason: nil)) } }
        for (i, entry) in photoEntries(media).enumerated() { assignments.append(MigrationRecordAssignment(id: "media.photoData[\(i)]", kind: "照片", legacyEarTag: entry.tag, dateText: "", penHint: nil, targetSheepSourceKey: nil, exclusionReason: nil)) }
        appendHistoricalArchiveCandidates(to: &candidates, assignments: assignments)
        let id = UUID(); let checksum = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(); var session = MigrationSession(id: id, manifest: MigrationManifest(sessionID: id, sourceChecksum: checksum, sourceSchemaVersion: report.schemaVersion, importedAt: .now, importerVersion: 3), sourcePayload: source, inspectorReport: report, sheep: candidates, assignments: assignments, issues: [])
        applyAutomaticIdentityResolution(to: &session)
        validateSource(root: root, session: &session); MigrationResolutionService.refreshIssues(&session); try MigrationWorkspaceStore.save(session); return session
    }

    static func buildTemporaryFarm(sessionID: UUID) throws -> MigrationTemporaryFarm {
        // A saved migration session can outlive importer fixes. Recreate all
        // source-derived issues from its original JSON before every dry run so
        // a stale warning never overrides the corrected conversion rules.
        var session = try MigrationWorkspaceStore.load(sessionID: sessionID)
        let root = try LegacySourceDecoder.decode(session.sourcePayload).root
        session.issues.removeAll()
        validateSource(root: root, session: &session)
        MigrationResolutionService.refreshIssues(&session)
        try MigrationWorkspaceStore.save(session)
        guard session.isReadyForTemporaryBuild else { throw MigrationError.notReady }
        let staging = try MigrationWorkspaceStore.makeStagingWorkspace(for: sessionID)
        do {
        let schema = migrationSchema(); let configuration = ModelConfiguration("Migration-\(sessionID.uuidString)", schema: schema, url: staging.storeURL, allowsSave: true, cloudKitDatabase: .none); let container = try ModelContainer(for: schema, configurations: configuration); let context = ModelContext(container)
        func stable(_ sourceKey: String) -> UUID { StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey) }
        let herd = section("herd", root); let feeding = section("feeding", root); let reproduction = section("reproduction", root); let health = section("health", root); let media = section("media", root)
        let farm = FarmRecord(id: stable("farm"), ownerAccountID: stable("owner"), name: string(section("farmSettings", root)["farmName"]).isEmpty ? "迁移演练牧场" : string(section("farmSettings", root)["farmName"])); context.insert(farm); var mapping = LegacyMappingTable(); var bySource: [String: SheepRecord] = [:]
        let legacyTransfers = records(herd["transfers"])
        let rawPenNames =
            ((herd["customPens"] as? [String]) ?? [])
                + records(herd["pens"]).map { string($0["name"]) }
                + session.sheep.map(\.pen)
                + records(feeding["feedRecords"]).map { string($0["pen"]) }
                + legacyTransfers.flatMap { [string($0["from"]), string($0["to"])] }
                + records(reproduction["lambing"]).map { string($0["pen"]) }
                + records(health["vaccineRecords"]).map { string($0["pen"]) }
        let penNames = Set(rawPenNames.map(legacyPenName)).filter { !$0.isEmpty }
        for name in penNames.sorted() { let key = "pen:\(name)"; let pen = PenRecord(id: stable(key), farmID: farm.id, name: name); context.insert(pen); mapping.pens[name] = pen.id; audit(context, session, key, "pen", ["name": name], [pen.id]) }
        for candidate in session.sheep {
            let isHistoricalArchive = candidate.isHistoricalArchive == true
            let currentStatus = isHistoricalArchive ? SheepStatus.removed : legacyCurrentStatus(candidate.status)
            let currentPenName = legacyPenName(candidate.pen)
            let initialPenName = inferredLegacyInitialPenName(for: candidate, transfers: legacyTransfers)
            let sheep = SheepRecord(
                id: stable(candidate.id),
                farmID: farm.id,
                earTag: candidate.finalEarTag ?? candidate.legacyEarTag,
                legacyEarTag: candidate.legacyEarTag,
                legacySourceKey: candidate.id,
                isHistoricalArchive: isHistoricalArchive,
                breed: candidate.breed,
                purpose: candidate.purpose.isEmpty ? "未分类" : candidate.purpose,
                sex: sex(candidate.sex),
                penID: mapping.pens[initialPenName],
                enteredAt: date(candidate.enteredAtText ?? candidate.birth) ?? .distantPast,
                birthAt: isHistoricalArchive ? nil : date(candidate.birth),
                note: candidate.note
            )
            sheep.isBreedingRam = sheep.sex == .ram && (sheep.purpose.contains("种公羊") || currentPenName.contains("种公羊"))
            sheep.statusRawValue = currentStatus.rawValue
            sheep.currentPenID = currentStatus == .active ? mapping.pens[currentPenName] : nil
            sheep.legacyStatusSnapshotIsAuthoritative = !isHistoricalArchive && !candidate.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            sheep.legacyPenSnapshotIsAuthoritative = !isHistoricalArchive && currentStatus == .active && !currentPenName.isEmpty
            context.insert(sheep)
            mapping.sheep[candidate.id] = sheep.id
            bySource[candidate.id] = sheep
            audit(context, session, candidate.id, "sheep", ["tag": candidate.legacyEarTag, "historicalArchive": isHistoricalArchive], [sheep.id], resolution: date(candidate.enteredAtText ?? candidate.birth) == nil ? "missingLegacyTimeStoredAsDistantPast" : "converted")
            audit(context, session, "\(candidate.id).currentState", "legacyCurrentSnapshot", ["status": candidate.status, "pen": currentPenName], [sheep.id], resolution: "currentSnapshotAuthoritative")
        }
        let ingredientRecords = records(feeding["feedLibrary"])
        for (i, item) in ingredientRecords.enumerated() {
            let oldID = string(item["id"])
            let sourceKey = "feeding.feedLibrary[\(i)]"
            let nutrientSnapshot = json(item["defaultNutrients"])
            let record = FeedIngredientRecord(
                id: stable(sourceKey),
                farmID: farm.id,
                name: string(item["name"]),
                unit: string(item["unit"]).isEmpty ? "千克" : string(item["unit"]),
                dryMatterText: number(path(item, ["defaultNutrients", "dryMatter"]))?.stableText,
                category: string(item["category"]),
                legacySourceKey: sourceKey,
                nutrientSnapshotJSON: nutrientSnapshot
            )
            context.insert(record)
            mapping.ingredients[oldID] = record.id
            mapping.ingredients[string(item["name"])] = record.id
            for (batchIndex, batch) in records(item["batches"]).enumerated() {
                let batchKey = "\(sourceKey).batches[\(batchIndex)]"
                let batchRecord = FeedIngredientBatchRecord(
                    id: stable(batchKey),
                    farmID: farm.id,
                    ingredientID: record.id,
                    legacySourceKey: batchKey,
                    batchName: string(batch["batchName"]),
                    purchaseDate: date(string(batch["purchaseDate"])),
                    supplier: string(batch["supplier"]),
                    storageLocation: string(batch["storageLocation"]),
                    pricePerKilogramText: number(batch["pricePerKg"])?.stableText ?? "0",
                    initialKilogramsText: number(batch["initialKg"])?.stableText,
                    remainingKilogramsText: number(batch["remainingKg"])?.stableText,
                    note: string(batch["note"]),
                    isActive: batch["isActive"] as? Bool ?? true
                )
                context.insert(batchRecord)
                let legacyBatchID = string(batch["id"])
                if !legacyBatchID.isEmpty { mapping.feedIngredientBatches[legacyBatchID] = batchRecord.id }
                let legacyBatchName = string(batch["batchName"])
                if !legacyBatchName.isEmpty { mapping.feedIngredientBatches[legacyBatchName] = batchRecord.id }
                audit(context, session, batchKey, "feedIngredientBatch", batch, [batchRecord.id])
            }
            audit(context, session, sourceKey, "feedIngredient", item, [record.id])
        }
        for (i, item) in records(feeding["feedRecipes"]).enumerated() { let sourceKey = "feeding.feedRecipes[\(i)]"; let recipe = FeedRecipeRecord(id: stable(sourceKey), farmID: farm.id, name: string(item["name"]), note: string(item["note"]), targetPenName: string(item["targetPen"]).isEmpty ? nil : string(item["targetPen"]), stageRawValue: string(item["stage"]), headCount: number(item["headCount"]).map { NSDecimalNumber(decimal: $0).intValue }, legacySourceKey: sourceKey); context.insert(recipe); mapping.recipes[string(item["id"])] = recipe.id; for (componentIndex, component) in records(item["components"]).enumerated() { guard let ingredientID = mapping.ingredients[string(component["ingredientId"])] else { continue }; context.insert(FeedRecipeComponentRecord(id: stable("\(sourceKey).components[\(componentIndex)]"), farmID: farm.id, recipeID: recipe.id, ingredientID: ingredientID, kilogramsText: number(component["asFedKgPerDay"])?.stableText ?? "0", legacyBatchID: string(component["batchId"]).isEmpty ? nil : string(component["batchId"]), pricePerKilogramText: number(component["pricePerKgSnapshot"])?.stableText, nutrientSnapshotJSON: json(component["nutrientsSnapshot"]))) }; audit(context, session, sourceKey, "feedRecipe", item, [recipe.id]) }
        for (i, item) in records(feeding["feedRecords"]).enumerated() {
            guard let penID = mapping.pens[legacyPenName(string(item["pen"]))] else { continue }
            let timestamp = legacyTimestamp(dateText: string(item["date"]), timeText: string(item["time"]))
            guard let occurredAt = timestamp.occurredAt else { continue }
            let sourceKey = "feeding.feedRecords[\(i)]"
            let feed = FeedRecord(id: stable(sourceKey), farmID: farm.id, penID: penID, recipeID: nil, mode: string(item["mode"]).lowercased().contains("free") ? .freeChoice : .limited, occurredAt: occurredAt, note: string(item["note"]), mealName: string(item["mealName"]), feederName: string(item["feederName"]), remainingKilogramsText: number(item["remainingKg"])?.stableText, discardedKilogramsText: number(item["discardedKg"])?.stableText, legacySourceKey: sourceKey)
            context.insert(feed)
            for (lineIndex, line) in records(item["ingredients"]).enumerated() {
                let ingredientID = mapping.ingredients[string(line["ingredientId"])] ?? mapping.ingredients[string(line["name"])]
                guard let ingredientID else { continue }
                let ingredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>())
                guard let ingredient = ingredients.first(where: { $0.id == ingredientID && $0.farmID == farm.id }) else { continue }
                let batchID = mapping.feedIngredientBatches[string(line["batchId"])]
                let ingredientBatch = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first(where: { $0.id == batchID && $0.farmID == farm.id })
                let lineNutrients = json(line["nutrientsSnapshot"])
                let nutrientSnapshot = lineNutrients == "{}" ? ingredient.nutrientSnapshotJSON : lineNutrients
                let linePrice = number(line["pricePerKgSnapshot"])?.stableText
                let priceSnapshot = linePrice ?? ingredientBatch?.pricePerKilogramText
                let lineName = string(line["name"])
                let lineUnit = string(line["unit"])
                let batchName = ingredientBatch?.batchName.trimmingCharacters(in: .whitespacesAndNewlines)
                context.insert(FeedRecordLine(
                    id: stable("\(sourceKey).ingredients[\(lineIndex)]"),
                    farmID: farm.id,
                    feedRecordID: feed.id,
                    ingredientID: ingredientID,
                    kilogramsText: number(line["amount"])?.stableText ?? "0",
                    ingredientNameSnapshot: lineName.isEmpty ? ingredient.name : lineName,
                    ingredientBatchID: ingredientBatch?.id,
                    ingredientBatchNameSnapshot: batchName?.isEmpty == false ? batchName : nil,
                    pricePerKilogramTextSnapshot: priceSnapshot,
                    nutrientSnapshotJSON: nutrientSnapshot,
                    unitSnapshot: lineUnit.isEmpty ? ingredient.unit : lineUnit,
                    dryMatterTextSnapshot: number(line["dryMatterSnapshot"])?.stableText ?? ingredient.dryMatterText
                ))
            }
            audit(context, session, sourceKey, "feedRecord", item, [feed.id], resolution: timestamp.auditResolution)
        }
        var catalogNames: [String: String] = [:]
        for (kind, items) in [("vaccine", records(health["vaccineCatalog"])), ("medicine", records(health["medicineCatalog"])), ("disease", records(health["diseaseCatalog"]))] { for (index, item) in items.enumerated() { let sourceKey = "health.\(kind)Catalog[\(index)]"; let catalog = HealthCatalogItemRecord(id: stable(sourceKey), farmID: farm.id, legacySourceKey: sourceKey, legacyCatalogID: string(item["id"]), kindRawValue: kind, name: string(item["name"]), category: string(item["category"]), unit: string(item["unit"]), defaultDoseText: number(item["defaultDose"])?.stableText, defaultRoute: string(item["defaultRoute"]), note: string(item["note"]), isActive: item["isActive"] as? Bool ?? true); context.insert(catalog); catalogNames[string(item["id"])] = catalog.name; audit(context, session, sourceKey, "healthCatalog", item, [catalog.id]) } }
        for (i, item) in records(health["inventoryLots"]).enumerated() { let sourceKey = "health.inventoryLots[\(i)]"; let lot = InventoryLotRecord(id: stable(sourceKey), farmID: farm.id, catalogName: catalogNames[string(item["itemId"])] ?? string(item["itemId"]), kind: string(item["itemType"]) == "vaccine" ? .vaccination : .treatment, expiresAt: date(string(item["expiryDate"])), startingQuantityText: number(item["quantityInitial"])?.stableText ?? "0", legacySourceKey: sourceKey, batchNumber: string(item["batchNo"]), supplier: string(item["supplier"]), receivedAt: date(string(item["receivedDate"])), unit: string(item["unit"])); context.insert(lot); mapping.inventoryLots[string(item["id"])] = lot.id; audit(context, session, sourceKey, "inventoryLot", item, [lot.id]) }
        for (i, item) in records(health["inventoryTransactions"]).enumerated() { guard let lotID = mapping.inventoryLots[string(item["lotId"])], let occurredAt = date(string(item["date"])) else { throw MigrationError.notReady }; let sourceKey = "health.inventoryTransactions[\(i)]"; let direction = string(item["direction"]); let kind: InventoryTransactionKind = direction == "in" ? .receipt : direction == "out" ? .consumption : .adjustment; let transaction = InventoryTransactionRecord(id: stable(sourceKey), farmID: farm.id, inventoryLotID: lotID, kind: kind, quantityText: number(item["quantity"])?.stableText ?? "0", occurredAt: occurredAt); context.insert(transaction); audit(context, session, sourceKey, "inventoryTransaction", item, [transaction.id]) }
        let assignments = Dictionary(uniqueKeysWithValues: session.assignments.map { ($0.id, $0) })
        for (i, item) in records(health["treatmentRecords"]).enumerated() { guard let occurredAt = date(string(item["date"])) else { throw MigrationError.notReady }; let sourceKey = "health.treatmentRecords[\(i)]"; let assignment = assignments[sourceKey]; let healthRecord = HealthRecord(id: stable(sourceKey), farmID: farm.id, sheepID: assignment.flatMap { bySource[$0.targetSheepSourceKey ?? ""]?.id }, penID: nil, kind: .treatment, itemNameSnapshot: string(item["medicineNameSnapshot"]), occurredAt: occurredAt, note: string(item["note"]), quantityText: number(item["dose"])?.stableText, unit: string(item["unit"]), route: string(item["route"]), legacySourceKey: sourceKey); context.insert(healthRecord); audit(context, session, sourceKey, "treatment", item, [healthRecord.id]) }
        for (i, item) in records(health["vaccineRecords"]).enumerated() { guard let occurredAt = date(string(item["date"])) else { throw MigrationError.notReady }; let sourceKey = "health.vaccineRecords[\(i)]"; let record = HealthRecord(id: stable(sourceKey), farmID: farm.id, sheepID: nil, penID: mapping.pens[legacyPenName(string(item["pen"]))], kind: .vaccination, itemNameSnapshot: string(item["vaccineNameSnapshot"]), occurredAt: occurredAt, note: string(item["note"]), quantityText: number(item["dosePerSheep"])?.stableText, unit: string(item["unit"]), route: string(item["route"]), legacySourceKey: sourceKey); context.insert(record); for j in (item["sheepTagsSnapshot"] as? [String] ?? []).indices { if let source = assignments["health.vaccineRecords[\(i)].sheepTagsSnapshot[\(j)]"]?.targetSheepSourceKey, let sheep = bySource[source] { context.insert(HealthSubjectLink(id: stable("\(sourceKey).sheepTagsSnapshot[\(j)]"), farmID: farm.id, healthRecordID: record.id, sheepID: sheep.id)) } }; audit(context, session, sourceKey, "vaccination", item, [record.id]) }
        for (i, item) in records(reproduction["semenRecords"]).enumerated() { let sourceKey = "reproduction.semenRecords[\(i)]"; let semen = SemenRecord(id: stable(sourceKey), farmID: farm.id, code: string(item["code"]), breed: string(item["breed"]), source: string(item["source"]), batchNumber: string(item["batchNo"]), quantityText: "0", legacySourceKey: sourceKey); context.insert(semen); audit(context, session, sourceKey, "semen", item, [semen.id]) }
        for (i, item) in records(reproduction["lambing"]).enumerated() { let sourceKey = "reproduction.lambing[\(i)]"; let assignment = assignments[sourceKey]; let total = number(item["total"]).map { NSDecimalNumber(decimal: $0).intValue } ?? 0; guard let eweID = bySource[assignment?.targetSheepSourceKey ?? ""]?.id, let occurredAt = date(string(item["date"])) else { throw MigrationError.notReady }; let record = ReproductionRecord(id: stable(sourceKey), farmID: farm.id, eweID: eweID, kind: .lambing, occurredAt: occurredAt, semenNameSnapshot: string(item["semenCode"]), lambCount: total, parity: number(item["parity"]).map { NSDecimalNumber(decimal: $0).intValue }, birthDeadCount: number(item["dead"]).map { NSDecimalNumber(decimal: $0).intValue }, note: string(item["difficult"]), legacySourceKey: sourceKey); context.insert(record); for (lambIndex, lamb) in records(item["lambs"]).enumerated() { let match = bySource.first(where: { EarTag.normalized($0.value.legacyEarTag ?? "") == EarTag.normalized(string(lamb["tag"])) })?.value; context.insert(LambingOffspringRecord(id: stable("\(sourceKey).lambs[\(lambIndex)]"), farmID: farm.id, lambingRecordID: record.id, sheepID: match?.id, legacyEarTag: string(lamb["tag"]), sexRawValue: string(lamb["sex"]), birthWeightText: number(lamb["weight"])?.stableText ?? "0")) }; audit(context, session, sourceKey, "lambing", item, [record.id]) }
        for (i, item) in records(herd["abortionRecords"]).enumerated() {
            let sourceKey = "herd.abortionRecords[\(i)]"
            guard let eweID = bySource[assignments[sourceKey]?.targetSheepSourceKey ?? ""]?.id else { throw MigrationError.notReady }
            let timestamp = legacyTimestamp(dateText: string(item["date"]), timeText: string(item["time"]))
            guard let occurredAt = timestamp.occurredAt else { continue }
            let parity = number(item["parity"]).map { NSDecimalNumber(decimal: $0).intValue }
            let count = number(item["count"]).map { NSDecimalNumber(decimal: $0).intValue } ?? 0
            let legacyNote = string(item["note"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let note = [
                parity.map { "胎次：\($0)" },
                legacyNote.isEmpty ? nil : legacyNote
            ].compactMap { $0 }.joined(separator: "；")
            let record = ReproductionRecord(id: stable(sourceKey), farmID: farm.id, eweID: eweID, kind: .abortion, occurredAt: occurredAt, result: "流产", lambCount: count, note: note, legacySourceKey: sourceKey)
            context.insert(record)
            audit(context, session, sourceKey, "abortion", item, [record.id], resolution: timestamp.auditResolution)
        }
        for (i, item) in records(herd["productionBatches"]).enumerated() {
            let timestamp = legacyTimestamp(dateText: string(item["startedDate"]), timeText: string(item["startedTime"]))
            guard let startedAt = timestamp.occurredAt else { continue }
            let sourceKey = "herd.productionBatches[\(i)]"
            let batch = ProductionBatchRecord(id: stable(sourceKey), farmID: farm.id, name: string(item["name"]), purpose: string(item["purpose"]), source: .historicalMigration, startedAt: startedAt, note: string(item["note"]))
            batch.statusRawValue = string(item["status"]).isEmpty ? ProductionBatchStatus.active.rawValue : string(item["status"])
            batch.endedAt = legacyTimestamp(dateText: string(item["endedDate"]), timeText: string(item["endedTime"])).occurredAt
            context.insert(batch)
            mapping.batches[string(item["id"])] = batch.id
            audit(context, session, sourceKey, "productionBatch", item, [batch.id], resolution: timestamp.auditResolution)
        }
        for (i, item) in records(herd["batchMemberships"]).enumerated() {
            guard let batchID = mapping.batches[string(item["batchId"])], let source = assignments["herd.batchMemberships[\(i)]"]?.targetSheepSourceKey, let sheep = bySource[source] else { continue }
            let timestamp = legacyTimestamp(dateText: string(item["joinedDate"]), timeText: string(item["joinedTime"]))
            guard let joinedAt = timestamp.occurredAt else { continue }
            let sourceKey = "herd.batchMemberships[\(i)]"
            let membership = BatchMembershipRecord(id: stable(sourceKey), farmID: farm.id, batchID: batchID, sheepID: sheep.id, joinedAt: joinedAt)
            membership.leftAt = legacyTimestamp(dateText: string(item["leftDate"]), timeText: string(item["leftTime"])).occurredAt
            membership.leaveReason = string(item["leaveReason"])
            context.insert(membership)
            audit(context, session, sourceKey, "batchMembership", item, [membership.id], resolution: timestamp.auditResolution)
        }
        convertBreedingPrograms(root: root, session: session, farm: farm, context: context)
        convertCoreHistory(root: root, session: session, farm: farm, mapping: mapping, sheep: bySource, context: context)
        convertLegacyTimelineEvents(root: root, session: session, farm: farm, sheep: bySource, context: context)
        let handledPedigreeSources = convertPedigree(root: root, session: session, farm: farm, sheep: bySource, context: context)
        archiveFactsAwaitingStructuredMigration(root: root, session: session, context: context, handledPedigreeSources: handledPedigreeSources)
        for (i, photo) in photoEntries(media).enumerated() { guard let source = assignments["media.photoData[\(i)]"]?.targetSheepSourceKey, let sheep = bySource[source] else { continue }; let payload = photo.base64.components(separatedBy: ",").last ?? photo.base64; guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { continue }; let sourceKey = "media.photoData[\(i)]"; let relative = "assets/photo-\(i).bin"; try data.write(to: staging.directory.appending(path: relative), options: .atomic); let asset = PhotoAssetRecord(id: stable(sourceKey), farmID: farm.id, sheepID: sheep.id, legacySourceKey: sourceKey, originalEarTag: photo.tag, relativePath: relative, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()); context.insert(asset); audit(context, session, sourceKey, "photo", ["tag": photo.tag], [asset.id]) }
        try context.save(); try FarmHistoryRebuilder().rebuild(farmID: farm.id, context: context); try context.save(); let reconciliation = MigrationReconciliationService.compare(source: session.inspectorReport.counts, session: session, context: context, farmID: farm.id, assetsDirectory: staging.directory, baseline: MigrationWorkspaceStore.baseline(for: session.id)); try JSONEncoder().encode(reconciliation).write(to: staging.reportURL, options: .atomic)
        try MigrationWorkspaceStore.commit(staging)
        return MigrationTemporaryFarm(container: container, farmID: farm.id, reconciliation: reconciliation)
        } catch { MigrationWorkspaceStore.discard(staging); throw error }
    }

    static func openTemporaryFarm(sessionID: UUID) throws -> MigrationTemporaryFarm {
        guard MigrationWorkspaceStore.hasActiveBuild(for: sessionID) else { throw MigrationError.noTemporaryResult }
        let schema = migrationSchema()
        let configuration = ModelConfiguration("Migration-\(sessionID.uuidString)", schema: schema, url: MigrationWorkspaceStore.storeURL(for: sessionID), allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        guard let farmID = try context.fetch(FetchDescriptor<FarmRecord>()).first?.id else { throw MigrationError.noTemporaryResult }
        let reportData = try Data(contentsOf: MigrationWorkspaceStore.activeWorkspace(for: sessionID).reportURL)
        return MigrationTemporaryFarm(container: container, farmID: farmID, reconciliation: try JSONDecoder().decode(MigrationReconciliationReport.self, from: reportData))
    }

    private static func convertCoreHistory(root: [String: Any], session: MigrationSession, farm: FarmRecord, mapping: LegacyMappingTable, sheep: [String: SheepRecord], context: ModelContext) {
        let assignments = Dictionary(uniqueKeysWithValues: session.assignments.map { ($0.id, $0) })
        let herd = section("herd", root)

        for (i, item) in records(herd["weighRecords"]).enumerated() {
            guard let source = assignments["herd.weighRecords[\(i)]"]?.targetSheepSourceKey,
                  let record = sheep[source] else { continue }
            let timestamp = legacyTimestamp(dateText: string(item["date"]), timeText: nil)
            guard let occurredAt = timestamp.occurredAt else { continue }
            let sourceKey = "herd.weighRecords[\(i)]"
            let value = WeightRecord(id: StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey), farmID: farm.id, sheepID: record.id, kilogramsText: number(item["weight"])?.stableText ?? "0", occurredAt: occurredAt)
            context.insert(value)
            audit(context, session, sourceKey, "weight", item, [value.id], resolution: timestamp.auditResolution)
        }

        for (i, item) in records(herd["weanRecords"]).enumerated() {
            let sourceKey = "herd.weanRecords[\(i)]"
            guard let source = assignments[sourceKey]?.targetSheepSourceKey,
                  let sheepRecord = sheep[source] else { continue }
            let timestamp = legacyTimestamp(dateText: string(item["weanDate"]), timeText: nil)
            guard let occurredAt = timestamp.occurredAt else { continue }
            let legacyDamTag = string(item["dam"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let damMatches = sheep.values.filter {
                EarTag.normalized($0.legacyEarTag ?? "") == EarTag.normalized(legacyDamTag) && $0.sex == .ewe
            }
            let damID = damMatches.count == 1 ? damMatches[0].id : nil
            let litterSize = number(item["litterSize"]).map { NSDecimalNumber(decimal: $0).intValue }.flatMap { $0 > 0 ? $0 : nil }
            let value = WeaningRecord(
                id: StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey),
                farmID: farm.id,
                sheepID: sheepRecord.id,
                occurredAt: occurredAt,
                weanWeightText: number(item["weanWeight"])?.stableText ?? "0",
                birthAt: date(string(item["birthDate"])),
                birthWeightText: number(item["birthWeight"])?.stableText,
                averageDailyGainText: number(item["adg"])?.stableText,
                damID: damID,
                legacyDamEarTag: legacyDamTag.isEmpty ? nil : legacyDamTag,
                litterSize: litterSize,
                legacySourceKey: sourceKey
            )
            context.insert(value)
            audit(context, session, sourceKey, "weaning", item, [value.id], resolution: timestamp.auditResolution)
        }

        for (i, item) in records(herd["transfers"]).enumerated() {
            guard let source = assignments["herd.transfers[\(i)]"]?.targetSheepSourceKey,
                  let record = sheep[source] else { continue }
            let timestamp = legacyTimestamp(dateText: string(item["date"]), timeText: string(item["time"]))
            guard let occurredAt = timestamp.occurredAt else { continue }
            let sourceKey = "herd.transfers[\(i)]"
            let transfer = TransferRecord(id: StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey), farmID: farm.id, sheepID: record.id, fromPenID: mapping.pens[legacyPenName(string(item["from"]))], toPenID: mapping.pens[legacyPenName(string(item["to"]))], occurredAt: occurredAt, note: string(item["reason"]))
            context.insert(transfer)
            audit(context, session, sourceKey, "transfer", item, [transfer.id], resolution: timestamp.auditResolution)
        }

        for (i, item) in records(herd["removals"]).enumerated() {
            guard let source = assignments["herd.removals[\(i)]"]?.targetSheepSourceKey,
                  let record = sheep[source] else { continue }
            let timestamp = legacyTimestamp(dateText: string(item["date"]), timeText: string(item["time"]))
            guard let occurredAt = timestamp.occurredAt else { continue }
            let sourceKey = "herd.removals[\(i)]"
            let kind: RemovalKind = string(item["type"]).contains("死亡") ? .deceased : string(item["type"]).contains("淘汰") ? .culled : .sold
            let removal = RemovalRecord(id: StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey), farmID: farm.id, sheepID: record.id, kind: kind, reason: string(item["reason"]), amountText: number(item["amount"])?.stableText, occurredAt: occurredAt)
            context.insert(removal)
            audit(context, session, sourceKey, "removal", item, [removal.id], resolution: timestamp.auditResolution)
        }
    }

    private static func convertBreedingPrograms(root: [String: Any], session: MigrationSession, farm: FarmRecord, context: ModelContext) {
        let reproduction = section("reproduction", root)
        for (index, source) in records(reproduction["breedPrograms"]).enumerated() {
            let sourceKey = "reproduction.breedPrograms[\(index)]"
            let name = string(source["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let createdAt = date(string(source["createdAt"])) ?? farm.createdAt
            let program = BreedingProgramRecord(
                id: StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey),
                farmID: farm.id,
                name: name.isEmpty ? "未命名配种方案" : name,
                createdAt: createdAt,
                legacySourceKey: sourceKey
            )
            context.insert(program)
            var targetIDs = [program.id]
            for (stepIndex, stepSource) in records(source["steps"]).enumerated() {
                let stepSourceKey = "\(sourceKey).steps[\(stepIndex)]"
                let dayOffset = max(0, number(stepSource["day"]).map { NSDecimalNumber(decimal: $0).intValue } ?? 0)
                let action = string(stepSource["action"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let step = BreedingProgramStepRecord(
                    id: StableMigrationID.uuid(sessionID: session.id, sourceKey: stepSourceKey),
                    farmID: farm.id,
                    programID: program.id,
                    dayOffset: dayOffset,
                    action: action.isEmpty ? "未命名操作" : action,
                    sortOrder: stepIndex,
                    legacySourceKey: stepSourceKey,
                    createdAt: createdAt
                )
                context.insert(step)
                targetIDs.append(step.id)
            }
            audit(context, session, sourceKey, "breedingProgram", source, targetIDs)
        }
    }

    private static func convertLegacyTimelineEvents(root: [String: Any], session: MigrationSession, farm: FarmRecord, sheep: [String: SheepRecord], context: ModelContext) {
        let events = records(section("herd", root)["events"])
        guard !events.isEmpty else { return }

        let allSheep = Array(sheep.values)
        let weights = (try? context.fetch(FetchDescriptor<WeightRecord>()))?.filter { $0.farmID == farm.id } ?? []
        let transfers = (try? context.fetch(FetchDescriptor<TransferRecord>()))?.filter { $0.farmID == farm.id } ?? []
        let removals = (try? context.fetch(FetchDescriptor<RemovalRecord>()))?.filter { $0.farmID == farm.id } ?? []
        var reproduction = (try? context.fetch(FetchDescriptor<ReproductionRecord>()))?.filter { $0.farmID == farm.id } ?? []
        let health = (try? context.fetch(FetchDescriptor<HealthRecord>()))?.filter { $0.farmID == farm.id } ?? []
        let healthSubjects = (try? context.fetch(FetchDescriptor<HealthSubjectLink>()))?.filter { $0.farmID == farm.id } ?? []

        for (index, event) in events.enumerated() {
            let sourceKey = "herd.events[\(index)]"
            guard let occurredAt = date(string(event["date"])) else { continue }
            let type = string(event["type"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = string(event["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = string(event["detail"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = (event["tags"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let rawSheepTag = string(event["sheepTag"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let subjectMatches = allSheep.filter {
                let tag = EarTag.normalized($0.legacyEarTag ?? $0.earTag)
                return !rawSheepTag.isEmpty && tag == EarTag.normalized(rawSheepTag)
            }
            let subject = subjectMatches.count == 1 ? subjectMatches[0] : nil

            if let targetID = legacyTimelineDuplicateTarget(
                type: type,
                title: title,
                occurredAt: occurredAt,
                subject: subject,
                allSheep: allSheep,
                weights: weights,
                transfers: transfers,
                removals: removals,
                reproduction: reproduction,
                health: health,
                healthSubjects: healthSubjects
            ) {
                audit(context, session, sourceKey, "legacyTimelineProjection", event, [targetID], resolution: "reconciledWithStructuredFact")
                continue
            }

            if type == "配种", let ewe = subject, ewe.sex == .ewe, legacyEventIsActualBreeding(detail: detail) {
                let record = ReproductionRecord(
                    id: StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey),
                    farmID: farm.id,
                    eweID: ewe.id,
                    kind: .breeding,
                    occurredAt: occurredAt,
                    semenNameSnapshot: legacySemenCode(in: detail),
                    result: "配种",
                    note: legacyTimelineText(type: type, title: title, detail: detail, tags: tags, sheepTag: rawSheepTag),
                    legacySourceKey: sourceKey
                )
                context.insert(record)
                reproduction.append(record)
                audit(context, session, sourceKey, "breeding", event, [record.id], resolution: "convertedFromLegacyTimeline")
                continue
            }

            if type == "孕检", let ewe = subject, ewe.sex == .ewe {
                let result = detail.isEmpty ? (title.isEmpty ? "孕检" : title) : detail
                let record = ReproductionRecord(
                    id: StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey),
                    farmID: farm.id,
                    eweID: ewe.id,
                    kind: .pregnancyCheck,
                    occurredAt: occurredAt,
                    result: result,
                    note: legacyTimelineText(type: type, title: title, detail: detail, tags: tags, sheepTag: rawSheepTag),
                    legacySourceKey: sourceKey
                )
                context.insert(record)
                reproduction.append(record)
                audit(context, session, sourceKey, "pregnancyCheck", event, [record.id], resolution: "convertedFromLegacyTimeline")
                continue
            }

            let note = NoteRecord(
                id: StableMigrationID.uuid(sessionID: session.id, sourceKey: sourceKey),
                farmID: farm.id,
                sheepID: subject?.id,
                text: legacyTimelineText(type: type, title: title, detail: detail, tags: tags, sheepTag: rawSheepTag),
                occurredAt: occurredAt
            )
            context.insert(note)
            audit(context, session, sourceKey, "legacyTimelineNote", event, [note.id], resolution: "preservedAsSupplementalNote")
        }
    }

    private static func legacyTimelineDuplicateTarget(
        type: String,
        title: String,
        occurredAt: Date,
        subject: SheepRecord?,
        allSheep: [SheepRecord],
        weights: [WeightRecord],
        transfers: [TransferRecord],
        removals: [RemovalRecord],
        reproduction: [ReproductionRecord],
        health: [HealthRecord],
        healthSubjects: [HealthSubjectLink]
    ) -> UUID? {
        func unique(_ ids: [UUID]) -> UUID? {
            ids.count == 1 ? ids[0] : nil
        }

        switch type {
        case "称重":
            guard let subject else { return nil }
            return unique(weights.filter { $0.sheepID == subject.id && sameLegacyDay($0.occurredAt, occurredAt) }.map(\.id))
        case "转群":
            guard let subject else { return nil }
            return unique(transfers.filter { $0.sheepID == subject.id && sameLegacyDay($0.occurredAt, occurredAt) }.map(\.id))
        case "离群":
            guard let subject else { return nil }
            return unique(removals.filter { $0.sheepID == subject.id && sameLegacyDay($0.occurredAt, occurredAt) }.map(\.id))
        case "产羔":
            guard let subject else { return nil }
            return unique(reproduction.filter { $0.eweID == subject.id && $0.kind == .lambing && sameLegacyDay($0.occurredAt, occurredAt) }.map(\.id))
        case "治疗":
            guard let subject else { return nil }
            return unique(health.compactMap { record in
                let kind = HealthRecordKind(rawValue: record.kindRawValue)
                return kind == .treatment && record.sheepID == subject.id && sameLegacyDay(record.occurredAt, occurredAt) ? record.id : nil
            })
        case "疫苗":
            guard let subject else { return nil }
            return unique(health.compactMap { record in
                let kind = HealthRecordKind(rawValue: record.kindRawValue)
                let isSubjectLinked = healthSubjects.contains { link in
                    link.healthRecordID == record.id && link.sheepID == subject.id
                }
                return kind == .vaccination && sameLegacyDay(record.occurredAt, occurredAt) && isSubjectLinked ? record.id : nil
            })
        case "入群":
            let prefix = "入群"
            let lambTag = title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let matches = allSheep.filter {
                !lambTag.isEmpty && EarTag.normalized($0.legacyEarTag ?? $0.earTag) == EarTag.normalized(lambTag) && (($0.birthAt.map { sameLegacyDay($0, occurredAt) } ?? false) || sameLegacyDay($0.enteredAt, occurredAt))
            }
            return matches.count == 1 ? matches[0].id : nil
        default:
            return nil
        }
    }

    private static func legacyEventIsActualBreeding(detail: String) -> Bool {
        guard let range = detail.range(of: "天:", options: .backwards) else { return true }
        let action = detail[range.upperBound...].components(separatedBy: " 冻精:").first ?? ""
        return action.contains("配种")
    }

    private static func legacySemenCode(in detail: String) -> String? {
        guard let range = detail.range(of: "冻精:") else { return nil }
        let value = detail[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func legacyTimelineText(type: String, title: String, detail: String, tags: [String], sheepTag: String) -> String {
        let parts: [String?] = [
            type.isEmpty ? nil : "历史\(type)",
            title.isEmpty ? nil : title,
            detail.isEmpty ? nil : detail,
            tags.isEmpty ? nil : "标签：\(tags.joined(separator: "、"))",
            sheepTag.isEmpty ? nil : "来源耳号：\(sheepTag)"
        ]
        let text = parts.compactMap { $0 }.joined(separator: "；")
        return text.isEmpty ? "历史事件" : text
    }

    private static func convertPedigree(root: [String: Any], session: MigrationSession, farm: FarmRecord, sheep: [String: SheepRecord], context: ModelContext) -> Set<String> {
        let herd = section("herd", root)
        let byNormalizedLegacyTag = Dictionary(grouping: sheep.values, by: {
            EarTag.normalized($0.legacyEarTag ?? $0.earTag)
        })
        var handled = Set<String>()

        for (index, source) in records(herd["sheep"]).enumerated() {
            let sourceKey = "herd.sheep[\(index)]"
            let pedigreeKey = "\(sourceKey).pedigree"
            let damTag = EarTag.normalized(string(source["dam"]))
            let sireTag = EarTag.normalized(string(source["sire"]))
            guard !damTag.isEmpty || !sireTag.isEmpty else { continue }
            guard let child = sheep[sourceKey] else { continue }
            handled.insert(pedigreeKey)
            var targetIDs = [child.id]
            var unresolved: [String] = []

            if !damTag.isEmpty {
                let matches = byNormalizedLegacyTag[damTag] ?? []
                if matches.count == 1, let dam = matches.first, dam.id != child.id, dam.sex == .ewe {
                    child.damID = dam.id
                    targetIDs.append(dam.id)
                } else {
                    unresolved.append("母本 \(damTag) 未找到唯一且性别为母的羊只")
                }
            }
            if !sireTag.isEmpty {
                let matches = byNormalizedLegacyTag[sireTag] ?? []
                if matches.count == 1, let sire = matches.first, sire.id != child.id, sire.sex == .ram {
                    child.sireID = sire.id
                    targetIDs.append(sire.id)
                } else {
                    unresolved.append("父本 \(sireTag) 未找到唯一且性别为公的羊只")
                }
            }

            audit(
                context,
                session,
                pedigreeKey,
                "pedigree",
                source,
                targetIDs,
                resolution: unresolved.isEmpty ? "converted" : "preservedForStructuredMigration",
                exclusionReason: unresolved.isEmpty ? nil : unresolved.joined(separator: "；")
            )
        }
        return handled
    }

    private static func archiveFactsAwaitingStructuredMigration(root: [String: Any], session: MigrationSession, context: ModelContext, handledPedigreeSources: Set<String>) {
        let herd = section("herd", root)
        let groups: [(path: String, entityType: String, reason: String, items: [[String: Any]])] = []

        for group in groups {
            for (index, item) in group.items.enumerated() {
                audit(context, session, "\(group.path)[\(index)]", group.entityType, item, [], resolution: "preservedForStructuredMigration", exclusionReason: group.reason)
            }
        }

        for (index, sheep) in records(herd["sheep"]).enumerated() where (!string(sheep["dam"]).isEmpty || sheep["sire"] != nil) && !handledPedigreeSources.contains("herd.sheep[\(index)].pedigree") {
            audit(context, session, "herd.sheep[\(index)].pedigree", "待结构化迁移：系谱", sheep, [], resolution: "preservedForStructuredMigration", exclusionReason: "母本、公本或冻精来源无法在未完成系谱规则前安全推断，原始记录已保留。")
        }
    }

    private static func appendHistoricalArchiveCandidates(to candidates: inout [MigrationSheepCandidate], assignments: [MigrationRecordAssignment]) {
        var known = Set(candidates.map { EarTag.normalized($0.legacyEarTag) })
        for assignment in assignments {
            let tag = EarTag.normalized(assignment.legacyEarTag)
            guard !tag.isEmpty, !known.contains(tag) else { continue }
            candidates.append(MigrationSheepCandidate(id: "history.archive.\(tag)", legacyEarTag: assignment.legacyEarTag, breed: "未知", sex: "", pen: assignment.penHint ?? "", birth: "", status: "历史归档", purpose: "历史归档", note: "由\(assignment.kind)历史记录自动补建", finalEarTag: assignment.legacyEarTag, enteredAtText: assignment.dateText.isEmpty ? nil : assignment.dateText, isHistoricalArchive: true))
            known.insert(tag)
        }
    }

    private static func applyAutomaticIdentityResolution(to session: inout MigrationSession) {
        let reservedTags = Set(session.sheep.map { EarTag.normalized($0.legacyEarTag) })
        var usedTags = Set<String>()
        let groups = Dictionary(grouping: session.sheep.indices, by: { EarTag.normalized(session.sheep[$0].legacyEarTag) })
        for key in groups.keys.sorted() {
            guard let indexes = groups[key] else { continue }
            let ordered = indexes.sorted { candidateSort(session.sheep[$0], session.sheep[$1]) }
            for (position, index) in ordered.enumerated() {
                let original = session.sheep[index].legacyEarTag
                var final = original
                if position > 0 {
                    var suffix = position + 1
                    repeat { final = "\(original)-\(String(format: "%02d", suffix))"; suffix += 1 } while reservedTags.contains(EarTag.normalized(final)) || usedTags.contains(EarTag.normalized(final))
                }
                session.sheep[index].finalEarTag = final
                usedTags.insert(EarTag.normalized(final))
            }
            if ordered.count > 1 { session.issues.append(MigrationIssue(severity: .warning, title: "重复耳号已自动处理", detail: "\(session.sheep[ordered[0]].legacyEarTag) 已按时间和来源稳定排序，后续个体自动添加编号后缀。", sourceKey: "auto:duplicate:\(key)")) }
        }
        let candidates = Dictionary(grouping: session.sheep, by: { EarTag.normalized($0.legacyEarTag) })
        for index in session.assignments.indices {
            let assignment = session.assignments[index]
            guard assignment.targetSheepSourceKey == nil, assignment.exclusionReason == nil else { continue }
            let matches = candidates[EarTag.normalized(assignment.legacyEarTag)] ?? []
            guard let target = automaticTarget(for: assignment, candidates: matches) else { continue }
            session.assignments[index].targetSheepSourceKey = target.id
        }
        let archiveCount = session.sheep.filter { $0.isHistoricalArchive == true }.count
        if archiveCount > 0 { session.issues.append(MigrationIssue(severity: .warning, title: "已自动补建历史归档羊只", detail: "从旧版历史记录中补建 \(archiveCount) 只已不在羊只列表中的个体。", sourceKey: "auto:archives")) }
    }

    private static func automaticTarget(for assignment: MigrationRecordAssignment, candidates: [MigrationSheepCandidate]) -> MigrationSheepCandidate? {
        guard !candidates.isEmpty else { return nil }
        if let pen = assignment.penHint, !pen.isEmpty {
            let matches = candidates.filter { $0.pen == pen }
            if matches.count == 1 { return matches[0] }
        }
        if let occurredAt = date(assignment.dateText) {
            let eligible = candidates.filter { date($0.enteredAtText ?? $0.birth).map { $0 <= occurredAt } ?? false }
            if let latest = eligible.max(by: { (date($0.enteredAtText ?? $0.birth) ?? .distantPast) < (date($1.enteredAtText ?? $1.birth) ?? .distantPast) }) { return latest }
        }
        return candidates.sorted(by: candidateSort).first
    }

    private static func candidateSort(_ lhs: MigrationSheepCandidate, _ rhs: MigrationSheepCandidate) -> Bool {
        let left = date(lhs.enteredAtText ?? lhs.birth) ?? .distantPast
        let right = date(rhs.enteredAtText ?? rhs.birth) ?? .distantPast
        return left == right ? lhs.id < rhs.id : left < right
    }

    private static func validateSource(root: [String: Any], session: inout MigrationSession) {
        let media = section("media", root)
        for (i, photo) in photoEntries(media).enumerated() {
            let payload = photo.base64.components(separatedBy: ",").last ?? photo.base64
            if Data(base64Encoded: payload, options: .ignoreUnknownCharacters) == nil {
                session.issues.append(MigrationIssue(severity: .blocking, title: "照片无法解码", detail: "耳号 \(photo.tag) 的照片数据损坏。", sourceKey: "media.photoData[\(i)]"))
            }
        }

        let herd = section("herd", root)
        let transfers = records(herd["transfers"])
        let removals = records(herd["removals"])
        for (index, sourceSheep) in records(herd["sheep"]).enumerated() {
            let tag = EarTag.normalized(string(sourceSheep["tag"]))
            guard !tag.isEmpty else { continue }
            let sourceKey = "herd.sheep[\(index)]"
            let rawStatus = string(sourceSheep["status"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = legacyCurrentStatus(rawStatus)
            let matchingRemovals = removals.filter { EarTag.normalized(string($0["tag"])) == tag }
            if !rawStatus.isEmpty, status == .active, !matchingRemovals.isEmpty {
                session.issues.append(MigrationIssue(severity: .warning, title: "当前状态与离场历史不一致", detail: "耳号 \(string(sourceSheep["tag"])) 的旧版当前状态仍为在场，但存在离场历史；迁移将以旧版当前状态作为在场判定，并保留离场历史供核查。", sourceKey: sourceKey))
            }
            let currentPen = legacyPenName(string(sourceSheep["pen"]))
            let latestTransferPen = transfers.compactMap { transfer -> (Date, String)? in
                guard EarTag.normalized(string(transfer["tag"])) == tag,
                      let occurredAt = legacyTimestamp(dateText: string(transfer["date"]), timeText: string(transfer["time"])).occurredAt else {
                    return nil
                }
                let destination = legacyPenName(string(transfer["to"]))
                return destination.isEmpty ? nil : (occurredAt, destination)
            }.max { lhs, rhs in lhs.0 < rhs.0 }?.1
            if status == .active, !currentPen.isEmpty, let latestTransferPen, currentPen != latestTransferPen {
                session.issues.append(MigrationIssue(severity: .warning, title: "当前羊舍与转群历史不一致", detail: "耳号 \(string(sourceSheep["tag"])) 的旧版当前羊舍为「\(currentPen)」，最新转群目标为「\(latestTransferPen)」；迁移将以当前羊舍作为在场位置，并保留历史转群。", sourceKey: sourceKey))
            }
        }
        let pendingStructuredMigration: [(String, String, [[String: Any]])] = []
        for (path, name, items) in pendingStructuredMigration where !items.isEmpty {
            session.issues.append(MigrationIssue(severity: .warning, title: "\(name)待结构化迁移", detail: "共 \(items.count) 条已原样保留在来源审计中，当前不会伪装成已转换的业务事实。", sourceKey: path))
        }
        if records(herd["sheep"]).contains(where: { !string($0["dam"]).isEmpty || $0["sire"] != nil }) {
            session.issues.append(MigrationIssue(severity: .warning, title: "系谱将进行核验转换", detail: "仅在母本、公本耳号唯一且性别匹配时建立稳定 UUID 关系；无法安全匹配的来源会保留在迁移审计中。", sourceKey: "herd.sheep"))
        }

        let timedGroups = [
            ("herd.transfers", records(herd["transfers"]), "date", "time"),
            ("herd.removals", records(herd["removals"]), "date", "time"),
            ("herd.productionBatches", records(herd["productionBatches"]), "startedDate", "startedTime"),
            ("herd.batchMemberships", records(herd["batchMemberships"]), "joinedDate", "joinedTime"),
            ("feeding.feedRecords", records(section("feeding", root)["feedRecords"]), "date", "time"),
            ("health.inventoryTransactions", records(section("health", root)["inventoryTransactions"]), "date", "time"),
            ("health.treatmentRecords", records(section("health", root)["treatmentRecords"]), "date", "time"),
            ("health.vaccineRecords", records(section("health", root)["vaccineRecords"]), "date", "time"),
            ("reproduction.lambing", records(section("reproduction", root)["lambing"]), "date", "time"),
            ("herd.events", records(herd["events"]), "date", "time")
        ]
        for (path, items, dateKey, timeKey) in timedGroups {
            for (index, item) in items.enumerated() where legacyTimestamp(dateText: string(item[dateKey]), timeText: string(item[timeKey])).occurredAt == nil {
                session.issues.append(MigrationIssue(severity: .blocking, title: "历史时间无效", detail: "\(path) 第 \(index + 1) 条记录的日期或时间无法解析，不能使用当前时间替代。", sourceKey: "\(path)[\(index)]"))
            }
        }
    }
}

enum MigrationReconciliationService {
    static func compare(source: LegacyMigrationCounts, session: MigrationSession, context: ModelContext, farmID: UUID, assetsDirectory: URL, baseline: MigrationBaselineSnapshot?) -> MigrationReconciliationReport {
        let sheep = fetch(SheepRecord.self, context).filter { $0.farmID == farmID }; let pens = fetch(PenRecord.self, context).filter { $0.farmID == farmID }
        let weights = fetch(WeightRecord.self, context).filter { $0.farmID == farmID }; let transfers = fetch(TransferRecord.self, context).filter { $0.farmID == farmID }; let removals = fetch(RemovalRecord.self, context).filter { $0.farmID == farmID }
        let weanings = fetch(WeaningRecord.self, context).filter { $0.farmID == farmID }
        let breedingPrograms = fetch(BreedingProgramRecord.self, context).filter { $0.farmID == farmID }
        let breedingProgramSteps = fetch(BreedingProgramStepRecord.self, context).filter { $0.farmID == farmID }
        let ingredients = fetch(FeedIngredientRecord.self, context).filter { $0.farmID == farmID }; let recipes = fetch(FeedRecipeRecord.self, context).filter { $0.farmID == farmID }; let feeds = fetch(FeedRecord.self, context).filter { $0.farmID == farmID }
        let lots = fetch(InventoryLotRecord.self, context).filter { $0.farmID == farmID }; let transactions = fetch(InventoryTransactionRecord.self, context).filter { $0.farmID == farmID }; let health = fetch(HealthRecord.self, context).filter { $0.farmID == farmID }
        let reproduction = fetch(ReproductionRecord.self, context).filter { $0.farmID == farmID }; let batches = fetch(ProductionBatchRecord.self, context).filter { $0.farmID == farmID }; let members = fetch(BatchMembershipRecord.self, context).filter { $0.farmID == farmID }
        let photos = fetch(PhotoAssetRecord.self, context).filter { $0.farmID == farmID }; let audit = fetch(MigrationAuditRecord.self, context).filter { $0.sessionID == session.id }
        let convertedSheep = sheep.filter { !$0.isHistoricalArchive }.count
        let archivalSheep = sheep.filter { $0.isHistoricalArchive }.count
        var converted: [String: Int] = [:]
        converted["羊只"] = convertedSheep; converted["历史归档羊只"] = archivalSheep; converted["圈舍"] = pens.count
        converted["称重"] = weights.count; converted["转群"] = transfers.count; converted["离场"] = removals.count
        converted["断奶"] = weanings.count
        converted["配种方案"] = breedingPrograms.count
        converted["原料"] = ingredients.count; converted["配方"] = recipes.count; converted["投喂"] = feeds.count
        converted["库存批次"] = lots.count; converted["库存流水"] = transactions.count; converted["健康"] = health.count
        converted["繁殖"] = reproduction.count; converted["批次"] = batches.count; converted["批次成员"] = members.count
        converted["照片"] = photos.count; converted["审计"] = audit.count
        // Older exports keep actual breeding and pregnancy checks in the
        // generic timeline. They are intentionally promoted into structured
        // reproduction records, so the expected count must include the audit
        // entries for those source facts as well as lambing and abortion rows.
        let timelineReproductionFacts = audit.filter {
            $0.resolution == "convertedFromLegacyTimeline"
                && ["breeding", "pregnancyCheck"].contains($0.entityType)
        }.count
        var expected = ["羊只": source.sheep, "圈舍": source.pens, "称重": source.weights, "断奶": source.weanings, "配种方案": source.breedPrograms, "转群": source.transfers, "离场": source.removals, "原料": source.feedIngredients, "配方": source.feedRecipes, "投喂": source.feedRecords, "库存批次": source.inventoryLots, "库存流水": source.inventoryTransactions, "健康": source.healthRecords, "繁殖": source.lambings + source.abortions + timelineReproductionFacts, "批次": source.batches, "批次成员": source.batchMemberships, "照片": source.photos]
        baseline?.expectedCounts.forEach { expected[$0.key] = $0.value }
        var discrepancies: [MigrationDiscrepancy] = []
        func add(_ severity: MigrationDiscrepancySeverity, _ category: String, _ reason: String, _ sourceKey: String? = nil, _ ids: [UUID] = []) { discrepancies.append(MigrationDiscrepancy(id: "\(severity.rawValue)|\(category)|\(sourceKey ?? reason)|\(ids.map(\.uuidString).joined(separator: ","))", severity: severity, category: category, sourceKey: sourceKey, targetRecordIDs: ids, reason: reason)) }
        for key in expected.keys.sorted() where converted[key] != expected[key] { add(key == "圈舍" ? .warning : .blocking, key, "来源 \(expected[key] ?? 0) 条，临时库转换 \(converted[key] ?? 0) 条。") }
        let sheepIDs = Set(sheep.map(\.id)); let penIDs = Set(pens.map(\.id)); let ingredientIDs = Set(ingredients.map(\.id)); let recipeIDs = Set(recipes.map(\.id)); let batchIDs = Set(batches.map(\.id)); let lotIDs = Set(lots.map(\.id)); let healthIDs = Set(health.map(\.id)); let reproductionIDs = Set(reproduction.map(\.id))
        for record in sheep where (record.damID != nil && !sheepIDs.contains(record.damID!)) || (record.sireID != nil && !sheepIDs.contains(record.sireID!)) {
            add(.blocking, "系谱引用", "羊只系谱引用不存在的父本或母本。", record.legacySourceKey, [record.id])
        }
        for record in sheep {
            if let damID = record.damID, let dam = sheep.first(where: { $0.id == damID }), dam.sex != .ewe {
                add(.blocking, "系谱性别", "母本必须是母羊。", record.legacySourceKey, [record.id, damID])
            }
            if let sireID = record.sireID, let sire = sheep.first(where: { $0.id == sireID }), sire.sex != .ram {
                add(.blocking, "系谱性别", "父本必须是公羊。", record.legacySourceKey, [record.id, sireID])
            }
        }
        for record in weights where !sheepIDs.contains(record.sheepID) { add(.blocking, "UUID 引用", "称重记录引用不存在的羊只。", nil, [record.id, record.sheepID]) }
        for record in weanings where !sheepIDs.contains(record.sheepID) || (record.damID != nil && !sheepIDs.contains(record.damID!)) { add(.blocking, "UUID 引用", "断奶记录存在无效羊只或母本引用。", record.legacySourceKey, [record.id]) }
        for record in weanings {
            guard let damID = record.damID,
                  let dam = sheep.first(where: { $0.id == damID }),
                  dam.sex != .ewe else { continue }
            add(.blocking, "断奶母本", "断奶记录的母本必须是母羊。", record.legacySourceKey, [record.id, damID])
        }
        let breedingProgramIDs = Set(breedingPrograms.map(\.id))
        for step in breedingProgramSteps where !breedingProgramIDs.contains(step.programID) || step.dayOffset < 0 || step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.blocking, "配种方案", "配种方案步骤缺少有效方案、日龄或操作内容。", step.legacySourceKey, [step.id, step.programID])
        }
        for record in transfers where !sheepIDs.contains(record.sheepID) || (record.fromPenID != nil && !penIDs.contains(record.fromPenID!)) || (record.toPenID != nil && !penIDs.contains(record.toPenID!)) { add(.blocking, "UUID 引用", "转群记录存在无效羊只或圈舍引用。", nil, [record.id]) }
        for record in removals where !sheepIDs.contains(record.sheepID) { add(.blocking, "UUID 引用", "离场记录引用不存在的羊只。", nil, [record.id, record.sheepID]) }
        for record in fetch(FeedRecipeComponentRecord.self, context).filter({ $0.farmID == farmID }) where !recipeIDs.contains(record.recipeID) || !ingredientIDs.contains(record.ingredientID) { add(.blocking, "UUID 引用", "配方组成引用不存在的配方或原料。", nil, [record.id]) }
        for record in fetch(FeedRecordLine.self, context).filter({ $0.farmID == farmID }) where !feeds.contains(where: { $0.id == record.feedRecordID }) || !ingredientIDs.contains(record.ingredientID) { add(.blocking, "UUID 引用", "投喂明细引用不存在的投喂或原料。", nil, [record.id]) }
        for record in transactions where !lotIDs.contains(record.inventoryLotID) { add(.blocking, "UUID 引用", "库存流水引用不存在的库存批次。", nil, [record.id]) }
        for record in health where (record.sheepID != nil && !sheepIDs.contains(record.sheepID!)) || (record.penID != nil && !penIDs.contains(record.penID!)) || (record.inventoryLotID != nil && !lotIDs.contains(record.inventoryLotID!)) { add(.blocking, "UUID 引用", "健康记录存在无效引用。", record.legacySourceKey, [record.id]) }
        for record in fetch(HealthSubjectLink.self, context).filter({ $0.farmID == farmID }) where !healthIDs.contains(record.healthRecordID) || !sheepIDs.contains(record.sheepID) { add(.blocking, "UUID 引用", "免疫对象存在无效引用。", nil, [record.id]) }
        for record in reproduction where !sheepIDs.contains(record.eweID) || (record.sireID != nil && !sheepIDs.contains(record.sireID!)) { add(.blocking, "UUID 引用", "繁殖记录存在无效羊只引用。", record.legacySourceKey, [record.id]) }
        for record in fetch(LambingOffspringRecord.self, context).filter({ $0.farmID == farmID }) where !reproductionIDs.contains(record.lambingRecordID) || (record.sheepID != nil && !sheepIDs.contains(record.sheepID!)) { add(.blocking, "UUID 引用", "产羔明细存在无效引用。", nil, [record.id]) }
        for record in members where !batchIDs.contains(record.batchID) || !sheepIDs.contains(record.sheepID) { add(.blocking, "UUID 引用", "批次成员存在无效引用。", nil, [record.id]) }
        for record in reproduction.filter({ $0.kind == .lambing }) { let offspring = fetch(LambingOffspringRecord.self, context).filter { $0.lambingRecordID == record.id }.count; if record.lambCount != offspring { add(.blocking, "产羔明细", "产羔数 \(record.lambCount) 与羔羊明细 \(offspring) 不一致。", record.legacySourceKey, [record.id]) } }
        for photo in photos { let url = assetsDirectory.appending(path: photo.relativePath); guard let data = try? Data(contentsOf: url) else { add(.blocking, "照片", "照片文件缺失。", photo.legacySourceKey, [photo.id]); continue }; let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(); if checksum != photo.sha256 { add(.blocking, "照片", "照片校验和不一致。", photo.legacySourceKey, [photo.id]) }; if let sheepID = photo.sheepID, !sheepIDs.contains(sheepID) { add(.blocking, "照片", "照片引用不存在的羊只。", photo.legacySourceKey, [photo.id]) } }
        for record in fetch(DailyPenCountRecord.self, context).filter({ $0.farmID == farmID }) where !penIDs.contains(record.penID) || record.count < 0 { add(.blocking, "每日圈舍存栏", "历史重建产生无效的每日圈舍存栏记录。", nil, [record.id]) }
        for assignment in session.assignments where assignment.exclusionReason != nil { add(.warning, "人工排除", assignment.exclusionReason ?? "已排除", assignment.id) }
        let requiredAuditCount = expected.values.reduce(0, +)
        if audit.count < requiredAuditCount { add(.blocking, "审计", "转换记录缺少来源审计：需要至少 \(requiredAuditCount) 条，实际 \(audit.count) 条。") }
        return MigrationReconciliationReport(source: source, convertedSheep: convertedSheep, archivalSheep: archivalSheep, convertedPens: pens.count, convertedWeights: weights.count, convertedTransfers: transfers.count, convertedRemovals: removals.count, excludedRecords: session.assignments.filter { $0.exclusionReason != nil }.count, convertedByType: converted, expectedByType: expected, discrepancies: discrepancies)
    }

    private static func fetch<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }
}

private func migrationSchema() -> Schema { Schema([FarmRecord.self, PenRecord.self, SheepRecord.self, WeightRecord.self, WeaningRecord.self, BreedingProgramRecord.self, BreedingProgramStepRecord.self, TransferRecord.self, RemovalRecord.self, ProductionBatchRecord.self, BatchMembershipRecord.self, DailyPenCountRecord.self, FeedIngredientRecord.self, FeedRecipeRecord.self, FeedRecipeComponentRecord.self, FeedRecord.self, FeedRecordLine.self, InventoryLotRecord.self, InventoryTransactionRecord.self, HealthRecord.self, ReproductionRecord.self, SemenRecord.self, SemenDonorRecord.self, PedigreeChangeRecord.self, NoteRecord.self, MigrationAuditRecord.self, PhotoAssetRecord.self, HealthSubjectLink.self, LambingOffspringRecord.self, FeedIngredientBatchRecord.self, HealthCatalogItemRecord.self]) }
private func section(_ name: String, _ root: [String: Any]) -> [String: Any] { root[name] as? [String: Any] ?? [:] }
private func records(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
private func string(_ value: Any?) -> String { value as? String ?? "" }
private func number(_ value: Any?) -> Decimal? { if let value = value as? Double { return Decimal(value) }; if let value = value as? Int { return Decimal(value) }; if let value = value as? String { return Decimal.stable(value) }; return nil }
private func json(_ value: Any?) -> String { guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }; return String(data: data, encoding: .utf8) ?? "{}" }
private func path(_ object: [String: Any], _ keys: [String]) -> Any? { keys.reduce(object as Any?) { partial, key in (partial as? [String: Any])?[key] } }

private struct LegacyTimestamp {
    let occurredAt: Date?
    let auditResolution: String
}

private func legacyTimestamp(dateText: String, timeText: String?) -> LegacyTimestamp {
    let normalizedTime = (timeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedTime.isEmpty {
        guard let exact = legacyDateTime(dateText: dateText, timeText: normalizedTime) else {
            return LegacyTimestamp(occurredAt: nil, auditResolution: "invalidLegacyTime")
        }
        return LegacyTimestamp(occurredAt: exact, auditResolution: "convertedWithExactTime")
    }
    return LegacyTimestamp(occurredAt: legacyDateTime(dateText: dateText, timeText: nil), auditResolution: "convertedWithDateOnlyPrecision")
}

private func date(_ value: String) -> Date? {
    legacyDateTime(dateText: value, timeText: nil)
}

private func legacyPenName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func legacyCurrentStatus(_ value: String) -> SheepStatus {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty || ["在群", "在场", "存栏", "正常", "在栏"].contains(normalized) {
        return .active
    }
    if normalized.contains("死亡") || normalized.contains("死") {
        return .deceased
    }
    // eSheep+ itself treats only `在群` (and legacy blanks) as current herd.
    // In particular, `售卖` and `盘点消失` are common old-table terminal
    // statuses. Omitting them here made 1,471 departed sheep appear active
    // while their removal history still said otherwise.
    if ["离群", "离场", "出栏", "出售", "售卖", "淘汰", "转出", "已售", "盘点消失", "失踪"].contains(where: normalized.contains) {
        return .removed
    }
    return .active
}

private func inferredLegacyInitialPenName(
    for candidate: MigrationSheepCandidate,
    transfers: [[String: Any]]
) -> String {
    let tag = EarTag.normalized(candidate.legacyEarTag)
    guard !tag.isEmpty else { return legacyPenName(candidate.pen) }

    let origins: [(occurredAt: Date, pen: String)] = transfers.compactMap { record in
        guard EarTag.normalized(string(record["tag"])) == tag,
              let occurredAt = legacyTimestamp(dateText: string(record["date"]), timeText: string(record["time"])).occurredAt else {
            return nil
        }
        let pen = legacyPenName(string(record["from"]))
        return pen.isEmpty ? nil : (occurredAt, pen)
    }
    return origins.sorted { lhs, rhs in
        lhs.occurredAt == rhs.occurredAt ? lhs.pen < rhs.pen : lhs.occurredAt < rhs.occurredAt
    }.first?.pen ?? legacyPenName(candidate.pen)
}

private func legacyDateTime(dateText: String, timeText: String?) -> Date? {
    let day = dateText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !day.isEmpty else { return nil }
    let time = timeText?.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = time.map { "\(day) \($0)" } ?? day
    let formats: [String]
    if time == nil {
        formats = ["yyyy-MM-dd", "yyyy/MM/dd"]
    } else {
        formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd H:mm:ss", "yyyy-MM-dd H:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd H:mm:ss", "yyyy/MM/dd H:mm"]
    }
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        formatter.isLenient = false
        if let value = formatter.date(from: source) {
            return value
        }
    }
    return nil
}

private func sameLegacyDay(_ lhs: Date, _ rhs: Date) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    return calendar.isDate(lhs, inSameDayAs: rhs)
}
private func sex(_ value: String) -> SheepSex { value == "母" ? .ewe : value == "公" ? .ram : .unknown }
private func appendAssignments(_ output: inout [MigrationRecordAssignment], kind: String, path: String, records: [[String: Any]], tagKey: String, penKey: String? = nil) { for (index, item) in records.enumerated() { output.append(MigrationRecordAssignment(id: "\(path)[\(index)]", kind: kind, legacyEarTag: string(item[tagKey]), dateText: string(item["date"]), penHint: penKey.map { string(item[$0]) }, targetSheepSourceKey: nil, exclusionReason: nil)) } }
private func photoEntries(_ media: [String: Any]) -> [(tag: String, base64: String)] { (media["photoData"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) } }
private func audit(_ context: ModelContext, _ session: MigrationSession, _ sourceKey: String, _ type: String, _ payload: Any, _ targetIDs: [UUID], resolution: String = "converted", exclusionReason: String? = nil) { let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(); let raw = String(data: data, encoding: .utf8) ?? "{}"; let ids = (try? String(data: JSONEncoder().encode(targetIDs.map(\.uuidString)), encoding: .utf8)) ?? "[]"; context.insert(MigrationAuditRecord(id: StableMigrationID.uuid(sessionID: session.id, sourceKey: "audit:\(sourceKey)"), sessionID: session.id, sourceKey: sourceKey, entityType: type, targetEntityIDsJSON: ids, rawPayloadJSON: raw, resolution: resolution, exclusionReason: exclusionReason)) }
