import Foundation
import SwiftData

/// Bridges only existing native query/calculation/draft tools. Action execution stays in the
/// existing confirmation cards and audited command service, outside the Codex protocol.
@MainActor
enum InsightCodexFarmToolBridge {
    static func definitions(agent: InsightAgentContext, registry: InsightToolRegistry) throws -> [InsightCodexToolDefinition] {
        try registry.definitions(for: agent.farmContext).map { value in
            let data = try JSONEncoder().encode(value.parameters)
            let schema = try JSONDecoder().decode([String: InsightCodexJSONValue].self, from: data)
            return InsightCodexToolDefinition(name: value.name, description: value.description, inputSchema: schema)
        }
    }

    static func execute(event: InsightCodexEvent, agent: InsightAgentContext,
                        context: ModelContext, registry: InsightToolRegistry,
                        extendedDataAuthorized: Bool = false) throws -> InsightToolExecution {
        let expected = InsightCodexScope(accountID: agent.accountID, farmID: agent.farmID,
                                         conversationID: agent.conversationID)
        guard event.kind == .toolCall, event.scope == expected,
              let name = event.toolName, let callID = event.callID,
              let arguments = event.argumentsJSON,
              registry.definitions(for: agent.farmContext).contains(where: { $0.name == name }) else {
            throw InsightCodexError.scopeMismatch
        }
        // execute(call:) creates proposed drafts; it never invokes execute(draft:).
        // The owner persists returned drafts and waits for the existing user confirmation.
        return try registry.execute(InsightFunctionCall(callID: callID, name: name, argumentsJSON: arguments),
                                    agent: agent, context: context, extendedDataAuthorized: extendedDataAuthorized)
    }
}
