import Foundation
import SwiftData

enum SheepLabelBackup {
    static let modelNames: Set<String> = ["SheepLabelRecord", "SheepLabelAssignmentRecord", "SheepLabelChangeRecord"]
    static func capture(farmID: UUID, context: ModelContext) throws -> [ESheepCloudCheckpointRecord] {
        try ESheepCloudCheckpointRegistry.adapters.filter { modelNames.contains($0.name) }.flatMap { try $0.exportRows(farmID, context) }
    }
    static func validate(_ rows: [ESheepCloudCheckpointRecord], sheepIDs: Set<UUID>) throws {
        var keys = Set<String>()
        var labelIDs = Set<UUID>()
        for row in rows {
            guard modelNames.contains(row.model), case .string(let text) = row.values["id"], let id = UUID(uuidString: text), keys.insert(row.model + text.lowercased()).inserted else { throw FarmLocalBackupError.missingReference("羊只标签备份无效") }
            if row.model == "SheepLabelRecord" { labelIDs.insert(id) }
            if case .string(let sheep) = row.values["sheepID"], let id = UUID(uuidString: sheep), !sheepIDs.contains(id) { throw FarmLocalBackupError.missingReference("sheepLabel.sheepID") }
        }
        for row in rows where row.model == "SheepLabelAssignmentRecord" {
            guard case .string(let json) = row.values["labelIDsJSON"], let ids = try? JSONDecoder().decode([UUID].self, from: Data(json.utf8)), Set(ids).isSubset(of: labelIDs) else { throw FarmLocalBackupError.missingReference("sheepLabel.labelID") }
        }
    }
    static func restore(_ rows: [ESheepCloudCheckpointRecord], farmID: UUID, context: ModelContext) throws {
        let adapters = ESheepCloudCheckpointRegistry.adapters.filter { modelNames.contains($0.name) }
        for row in rows {
            guard let adapter = adapters.first(where: { $0.name == row.model }) else { throw FarmLocalBackupError.missingReference("sheepLabel.model") }
            var values = row.values; values["farmID"] = .string(farmID.uuidString.lowercased())
            try adapter.insertRow(.init(model: row.model, values: values), farmID, context)
        }
    }
}
