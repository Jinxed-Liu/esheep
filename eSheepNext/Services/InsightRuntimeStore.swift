import Foundation

struct InsightConversationRuntime: Codable, Sendable {
    let accountID: UUID
    let farmID: UUID
    let conversationID: UUID
    var revision: Int64 = 0
    var records: [UUID: [InsightRuntimeRecord]] = [:]
    var reasoning: [UUID: [MiMoReasoningRecord]] = [:]
    var plans: [UUID: InsightPlan] = [:]
    var goals: [UUID: InsightGoal] = [:]
    var budgetByMessageID: [UUID: InsightRunBudgetSnapshot] = [:]
    var goalBudgetByID: [UUID: InsightRunBudgetSnapshot] = [:]
    var budgetSegmentsByMessageID: [UUID: [InsightRunBudgetSnapshot]] = [:]
    var exports: [UUID: InsightGoalExportCheckpoint] = [:]
    var turn: InsightTurnCheckpoint?
    var pendingMessageID: UUID?
    var pausedReason: String?
    var processExchangesByMessageID: [UUID: [MiMoFunctionExchange]]?
}

struct InsightTurnCheckpoint: Codable, Sendable {
    var requestID: UUID
    let userMessageID: UUID?
    let assistantMessageID: UUID
    let text: String
    let mode: InsightSubmissionMode
    let configuration: InsightRunConfiguration
    let goalID: UUID?
    let isGoalVerification: Bool
    var exchanges: [MiMoFunctionExchange] = []
    var requiresUnretainedAudio = false
    var revisesPlanID: UUID?
}

struct InsightGoalExportCheckpoint: Codable, Sendable {
    let fileID: UUID
    var file: InsightGeneratedFile?
    let goalID: UUID
    let messageID: UUID
    var savedAt: Date?
}

/// Local, encrypted process history. It is deliberately absent from the farm
/// schema and personal-sync DTOs: a process trace is not a farm fact.
actor InsightRuntimeStore {
    static let shared = InsightRuntimeStore()
    private let root: URL
    private var latestRevision: [String: Int64] = [:]
    private var deleted = Set<String>()
    private var deletedAccounts = Set<UUID>()
    private var accountEpoch: [UUID: Int] = [:]

    init(rootDirectory: URL? = nil) {
        root = rootDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "InsightRuntime", directoryHint: .isDirectory)
    }

    func save(_ value: InsightConversationRuntime) async throws {
        let key = identifier(value.accountID, value.farmID, value.conversationID)
        let epoch = accountEpoch[value.accountID] ?? 0
        guard !deletedAccounts.contains(value.accountID), !deleted.contains(key) else { throw InsightWorkflowError.stopped }
        guard value.revision >= (latestRevision[key] ?? -1) else { return }
        let plain = try JSONEncoder().encode(value)
        let encrypted = try await InsightPersonalCryptoActor.shared.seal(
            plain, accountID: value.accountID, recordID: key
        )
        // Actor reentrancy during encryption cannot resurrect a deleted thread
        // or overwrite a newer checkpoint that finished encryption first.
        guard !deletedAccounts.contains(value.accountID), !deleted.contains(key),
              epoch == (accountEpoch[value.accountID] ?? 0) else { throw InsightWorkflowError.stopped }
        guard value.revision >= (latestRevision[key] ?? -1) else { return }
        let directory = scopeDirectory(value.accountID, value.farmID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        let path = fileURL(value.accountID, value.farmID, value.conversationID)
        try encrypted.write(to: path, options: [.atomic, .completeFileProtection])
        latestRevision[key] = value.revision
    }

    func load(accountID: UUID, farmID: UUID, conversationID: UUID) async throws -> InsightConversationRuntime? {
        let key = identifier(accountID, farmID, conversationID)
        let epoch = accountEpoch[accountID] ?? 0
        let path = fileURL(accountID, farmID, conversationID)
        guard !deletedAccounts.contains(accountID), !deleted.contains(key),
              FileManager.default.fileExists(atPath: path.path) else { return nil }
        let encrypted = try Data(contentsOf: path)
        let plain = try await InsightPersonalCryptoActor.shared.open(encrypted, accountID: accountID, recordID: key)
        let value = try JSONDecoder().decode(InsightConversationRuntime.self, from: plain)
        guard value.accountID == accountID, value.farmID == farmID, value.conversationID == conversationID,
              !deletedAccounts.contains(accountID), !deleted.contains(key) else { throw InsightSecurityError.accountMismatch }
        guard epoch == (accountEpoch[accountID] ?? 0) else { throw InsightWorkflowError.stopped }
        latestRevision[key] = max(latestRevision[key] ?? 0, value.revision)
        return value
    }

    func removeConversation(accountID: UUID, farmID: UUID, conversationID: UUID) throws {
        deleted.insert(identifier(accountID, farmID, conversationID))
        let path = fileURL(accountID, farmID, conversationID)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    func removeAccount(_ accountID: UUID) throws {
        deletedAccounts.insert(accountID)
        accountEpoch[accountID, default: 0] += 1
        let prefix = "runtime/\(accountID.uuidString.lowercased())/"
        for key in Array(latestRevision.keys) where key.hasPrefix(prefix) { latestRevision.removeValue(forKey: key) }
        let directory = root.appending(path: accountID.uuidString.lowercased(), directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// A newly granted consent starts a fresh epoch. Pending work from before
    /// withdrawal remains invalid even when this account is enabled again.
    func enableAccount(_ accountID: UUID) {
        if deletedAccounts.remove(accountID) != nil { accountEpoch[accountID, default: 0] += 1 }
    }

    private func identifier(_ accountID: UUID, _ farmID: UUID, _ conversationID: UUID) -> String {
        "runtime/\(accountID.uuidString.lowercased())/\(farmID.uuidString.lowercased())/\(conversationID.uuidString.lowercased())"
    }

    private func scopeDirectory(_ accountID: UUID, _ farmID: UUID) -> URL {
        root.appending(path: accountID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: farmID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func fileURL(_ accountID: UUID, _ farmID: UUID, _ conversationID: UUID) -> URL {
        scopeDirectory(accountID, farmID).appending(path: "\(conversationID.uuidString.lowercased()).sealed")
    }
}
