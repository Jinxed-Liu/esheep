import Foundation
import SwiftData

/// Large factual reads must not occupy the conversation's main actor. The
/// worker owns its context and returns serialized evidence only; SwiftData
/// objects never cross executors or become a second farm-data cache.
actor InsightFarmReadWorker {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func execute(_ call: InsightFunctionCall, farmID: UUID, now: Date = .now) throws -> String {
        try Task.checkCancellation()
        guard let data = call.argumentsJSON.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InsightToolError.invalidArguments("JSON")
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let output: String
        switch call.name {
        case InsightFarmQueryEngine.toolName:
            output = try InsightFarmQueryEngine().execute(
                arguments: arguments, farmID: farmID, context: context, now: now
            )
        case InsightFarmCalculationEngine.toolName:
            output = try InsightFarmCalculationEngine().execute(
                arguments: arguments, farmID: farmID, context: context, now: now
            )
        default:
            throw InsightToolError.invalidArguments("read-only tool")
        }
        try Task.checkCancellation()
        return output
    }
}
