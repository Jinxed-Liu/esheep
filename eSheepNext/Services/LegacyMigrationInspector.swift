import Foundation

struct LegacyMigrationCounts: Codable, Sendable, Equatable {
    var sheep = 0
    var pens = 0
    var transfers = 0
    var removals = 0
    var weights = 0
    var weanings = 0
    var batches = 0
    var batchMemberships = 0
    var lambings = 0
    var abortions = 0
    var breedPrograms = 0
    var semen = 0
    var feedRecords = 0
    var feedIngredients = 0
    var feedRecipes = 0
    var healthRecords = 0
    var inventoryLots = 0
    var inventoryTransactions = 0
    var vaccineCatalog = 0
    var medicineCatalog = 0
    var diseaseCatalog = 0
    var photos = 0
}

struct LegacyMigrationReport: Codable, Sendable, Equatable {
    let schemaVersion: String?
    let counts: LegacyMigrationCounts
    let fatalIssues: [String]
    let warnings: [String]

    var isReadyForDryRun: Bool { fatalIssues.isEmpty }
}

enum LegacyMigrationInspector {
    static func inspect(_ data: Data) throws -> LegacyMigrationReport {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            return LegacyMigrationReport(schemaVersion: nil, counts: .init(), fatalIssues: ["迁移包根节点不是对象。"], warnings: [])
        }

        var issues: [String] = []
        var warnings: [String] = []
        guard let herd = root["herd"] as? [String: Any] else {
            issues.append("缺少 herd 区段。")
            return LegacyMigrationReport(schemaVersion: schemaVersion(from: root), counts: .init(), fatalIssues: issues, warnings: warnings)
        }
        guard let reproduction = root["reproduction"] as? [String: Any] else {
            issues.append("缺少 reproduction 区段。")
            return LegacyMigrationReport(schemaVersion: schemaVersion(from: root), counts: .init(), fatalIssues: issues, warnings: warnings)
        }

        let feeding = root["feeding"] as? [String: Any]
        let health = root["health"] as? [String: Any]
        let media = root["media"] as? [String: Any]
        var counts = LegacyMigrationCounts()
        counts.sheep = countArray(herd["sheep"])
        counts.pens = countArray(herd["pens"]) + countArray(herd["customPens"])
        counts.transfers = countArray(herd["transfers"])
        counts.removals = countArray(herd["removals"])
        counts.weights = countArray(herd["weighRecords"])
        counts.weanings = countArray(herd["weanRecords"])
        counts.batches = countArray(herd["productionBatches"])
        counts.batchMemberships = countArray(herd["batchMemberships"])
        counts.lambings = countArray(reproduction["lambing"])
        counts.abortions = countArray(herd["abortionRecords"])
        counts.breedPrograms = countArray(reproduction["breedPrograms"])
        counts.semen = countArray(reproduction["semenRecords"])
        counts.feedRecords = countArray(feeding?["feedRecords"])
        counts.feedIngredients = countArray(feeding?["feedLibrary"])
        counts.feedRecipes = countArray(feeding?["feedRecipes"])
        counts.healthRecords = countArray(health?["vaccineRecords"]) + countArray(health?["treatmentRecords"])
        counts.inventoryLots = countArray(health?["inventoryLots"])
        counts.inventoryTransactions = countArray(health?["inventoryTransactions"])
        counts.vaccineCatalog = countArray(health?["vaccineCatalog"])
        counts.medicineCatalog = countArray(health?["medicineCatalog"])
        counts.diseaseCatalog = countArray(health?["diseaseCatalog"])
        counts.photos = countDictionary(media?["photoData"])

        if counts.sheep == 0 { warnings.append("迁移包没有羊只记录。") }
        if counts.transfers > 0 && counts.pens == 0 { warnings.append("存在转群记录但未发现圈舍定义，需要在映射预览中处理。") }
        if counts.batchMemberships > 0 && counts.batches == 0 { issues.append("批次成员记录缺少对应批次定义。") }
        if root["schemaVersion"] == nil { warnings.append("迁移包未标注 schemaVersion，将按兼容模式解析。") }

        return LegacyMigrationReport(schemaVersion: schemaVersion(from: root), counts: counts, fatalIssues: issues, warnings: warnings)
    }

    private static func schemaVersion(from root: [String: Any]) -> String? {
        guard let value = root["schemaVersion"] else { return nil }
        return String(describing: value)
    }

    private static func countArray(_ value: Any?) -> Int {
        (value as? [Any])?.count ?? 0
    }

    private static func countDictionary(_ value: Any?) -> Int {
        (value as? [String: Any])?.count ?? 0
    }
}
