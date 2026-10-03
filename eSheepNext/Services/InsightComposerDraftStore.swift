import Foundation
import Observation

@MainActor
@Observable
final class InsightComposerDraft {
    private(set) var draftID: UUID = UUID()
    // SwiftUI bindings can write the current value again while focus or
    // enabled state changes. Only a real edit may protect a sent draft.
    var text = "" { didSet { if text != oldValue { revision += 1 } } }
    var images: [PendingInsightImage] = [] { didSet { if images != oldValue { revision += 1 } } }
    var audio: PendingInsightAudio? { didSet { if audio != oldValue { revision += 1 } } }
    var documents: [PendingInsightDocument] = [] { didSet { if documents != oldValue { revision += 1 } } }
    var modeRawValue = "conversation" { didSet { if modeRawValue != oldValue { revision += 1 } } }
    private(set) var revision = 0

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !images.isEmpty || audio != nil || !documents.isEmpty
    }

    func clear() {
        text = ""
        images = []
        audio = nil
        documents = []
        modeRawValue = "conversation"
        draftID = UUID()
        // Clearing an already-empty page still invalidates a pending restore.
        revision += 1
    }

    fileprivate func renewIdentity() { draftID = UUID() }

    fileprivate func restore(_ snapshot: InsightComposerDraftSnapshot) {
        draftID = snapshot.draftID
        text = snapshot.text
        images = snapshot.images.map { $0.image }
        audio = snapshot.audio?.audio
        documents = snapshot.documents
        modeRawValue = snapshot.modeRawValue
    }

    fileprivate var snapshot: InsightComposerDraftSnapshot {
        .init(draftID: draftID, text: text, images: images.map(InsightComposerDraftSnapshot.Image.init),
              audio: audio.map(InsightComposerDraftSnapshot.Audio.init), documents: documents, modeRawValue: modeRawValue)
    }
}

private struct InsightComposerDraftSnapshot: Codable, Sendable {
    struct Image: Codable, Sendable {
        let id: UUID
        let data: Data
        let mimeType: String
        let pixelWidth: Int
        let pixelHeight: Int
        let digest: String
        init(_ image: PendingInsightImage) {
            id = image.id; data = image.data; mimeType = image.mimeType
            pixelWidth = image.pixelWidth; pixelHeight = image.pixelHeight; digest = image.digest
        }
        var image: PendingInsightImage {
            .init(id: id, data: data, mimeType: mimeType, pixelWidth: pixelWidth, pixelHeight: pixelHeight, digest: digest)
        }
    }
    struct Audio: Codable, Sendable {
        let data: Data
        let mimeType: String
        let duration: TimeInterval
        let waveformSamples: [Float]
        init(_ audio: PendingInsightAudio) {
            data = audio.data; mimeType = audio.mimeType; duration = audio.duration; waveformSamples = audio.waveformSamples
        }
        var audio: PendingInsightAudio { .init(data: data, mimeType: mimeType, duration: duration, waveformSamples: waveformSamples) }
    }
    let draftID: UUID
    let text: String
    let images: [Image]
    let audio: Audio?
    let documents: [PendingInsightDocument]
    let modeRawValue: String
}

/// Drafts remain local, encrypted, and separate from durable conversations.
/// The list and its unsent chat page share one draft within each account/farm.
@MainActor
@Observable
final class InsightComposerDraftStore {
    private var drafts: [String: InsightComposerDraft] = [:]
    @ObservationIgnored private var loadedKeys = Set<String>()
    @ObservationIgnored private var failedRestoreKeys = Set<String>()
    @ObservationIgnored private var deletedKeys = Set<String>()
    @ObservationIgnored private var deletedAccounts = Set<UUID>()
    @ObservationIgnored private var accountEpochs: [UUID: Int] = [:]
    @ObservationIgnored private var operationRevisions: [String: Int] = [:]
    @ObservationIgnored private var accountRemovalTasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private let disk: InsightComposerDraftDiskStore

    init(rootDirectory: URL? = nil) {
        disk = InsightComposerDraftDiskStore(rootDirectory: rootDirectory)
    }

    func draft(scope: InsightSessionScope, conversationID: UUID?) -> InsightComposerDraft {
        let key = Self.key(scope: scope, conversationID: conversationID)
        if let existing = drafts[key] { return existing }
        let created = InsightComposerDraft()
        drafts[key] = created
        return created
    }

    func restore(scope: InsightSessionScope, conversationID: UUID?) async throws {
        let key = Self.key(scope: scope, conversationID: conversationID)
        guard !deletedAccounts.contains(scope.accountID), !deletedKeys.contains(key) else { return }
        guard loadedKeys.insert(key).inserted else { return }
        let current = draft(scope: scope, conversationID: conversationID)
        let revision = current.revision
        let accountEpoch = accountEpochs[scope.accountID] ?? 0
        let snapshot: InsightComposerDraftSnapshot?
        do {
            snapshot = try await disk.load(scope: scope, key: key, accountEpoch: accountEpoch)
            guard accountEpochs[scope.accountID, default: 0] == accountEpoch, !deletedAccounts.contains(scope.accountID) else { return }
            failedRestoreKeys.remove(key)
        } catch {
            guard accountEpochs[scope.accountID, default: 0] == accountEpoch, !deletedAccounts.contains(scope.accountID) else { return }
            loadedKeys.remove(key)
            failedRestoreKeys.insert(key)
            throw error
        }
        guard let snapshot, current.revision == revision, !current.hasContent,
              !deletedAccounts.contains(scope.accountID), !deletedKeys.contains(key) else { return }
        current.restore(snapshot)
    }

    func save(scope: InsightSessionScope, conversationID: UUID?) async throws {
        let key = Self.key(scope: scope, conversationID: conversationID)
        guard !deletedAccounts.contains(scope.accountID), !deletedKeys.contains(key) else { return }
        let current = draft(scope: scope, conversationID: conversationID)
        // A locked/corrupt sidecar must not be erased by an empty view leaving.
        guard !failedRestoreKeys.contains(key) else { throw InsightComposerDraftError.restoreFailed }
        let operationRevision = nextOperationRevision(key: key)
        if current.hasContent || current.modeRawValue != "conversation" {
            let snapshot = current.snapshot
            try await disk.save(snapshot, scope: scope, key: key, operationRevision: operationRevision,
                accountEpoch: accountEpochs[scope.accountID] ?? 0)
        } else {
            try await disk.remove(key: key, operationRevision: operationRevision)
        }
    }

    func clear(scope: InsightSessionScope, conversationID: UUID?) {
        let key = Self.key(scope: scope, conversationID: conversationID)
        drafts[key]?.clear()
        failedRestoreKeys.remove(key)
        let operationRevision = nextOperationRevision(key: key)
        Task { try? await disk.remove(key: key, operationRevision: operationRevision) }
    }

    func consumeNewDraft(scope: InsightSessionScope, expectedRevision: Int?) {
        consumeNewDraftInMemory(scope: scope, expectedRevision: expectedRevision)
        Task { try? await save(scope: scope, conversationID: nil) }
    }

    private func consumeNewDraftInMemory(scope: InsightSessionScope, expectedRevision: Int?) {
        let current = draft(scope: scope, conversationID: nil)
        if expectedRevision == nil || current.revision == expectedRevision {
            current.clear()
            failedRestoreKeys.remove(Self.key(scope: scope, conversationID: nil))
        } else {
            // Content edited while an archive was saving belongs to the next chat.
            current.renewIdentity()
        }
    }

    /// Complete the sent draft's disk removal, or persist genuine later edits,
    /// before the caller replaces the list composer with the saved chat.
    func consumeNewDraftAndSave(scope: InsightSessionScope, expectedRevision: Int?) async throws {
        // Calling the asynchronous convenience method here would schedule a
        // competing save, allowing this awaited operation to be superseded
        // before that second save has actually written the next draft.
        consumeNewDraftInMemory(scope: scope, expectedRevision: expectedRevision)
        try await save(scope: scope, conversationID: nil)
    }

    func removeConversation(scope: InsightSessionScope, conversationID: UUID) {
        let key = Self.key(scope: scope, conversationID: conversationID)
        deletedKeys.insert(key)
        drafts.removeValue(forKey: key)?.clear()
        Task { try? await disk.removePermanently(key: key) }
    }

    func removeAccount(accountID: UUID) {
        deletedAccounts.insert(accountID)
        let epoch = (accountEpochs[accountID] ?? 0) + 1
        accountEpochs[accountID] = epoch
        let prefix = accountID.uuidString + "/"
        for key in Array(drafts.keys) where key.hasPrefix(prefix) { drafts.removeValue(forKey: key)?.clear() }
        accountRemovalTasks[accountID] = Task { try await disk.removeAccount(accountID, accountEpoch: epoch) }
    }

    func waitForAccountRemoval(accountID: UUID) async throws {
        try await accountRemovalTasks[accountID]?.value
    }

    func enableAccount(accountID: UUID) async throws {
        guard deletedAccounts.contains(accountID) else { return }
        let epoch = (accountEpochs[accountID] ?? 0) + 1
        accountEpochs[accountID] = epoch
        try await disk.enableAccount(accountID, accountEpoch: epoch)
        guard accountEpochs[accountID] == epoch else { return }
        deletedAccounts.remove(accountID)
        let prefix = accountID.uuidString + "/"
        loadedKeys = loadedKeys.filter { !$0.hasPrefix(prefix) }
        failedRestoreKeys = failedRestoreKeys.filter { !$0.hasPrefix(prefix) }
    }

    private static func key(scope: InsightSessionScope, conversationID: UUID?) -> String {
        "\(scope.accountID.uuidString)/\(scope.farmID.uuidString)/\(conversationID?.uuidString ?? "new")"
    }

    private func nextOperationRevision(key: String) -> Int {
        let revision = (operationRevisions[key] ?? 0) + 1
        operationRevisions[key] = revision
        return revision
    }
}

private enum InsightComposerDraftError: LocalizedError {
    case restoreFailed
    var errorDescription: String? { "尚未恢复原草稿，不能覆盖其加密文件。" }
}

private actor InsightComposerDraftDiskStore {
    private let directory: URL
    private var revisions: [String: Int] = [:]
    private var deletedKeys = Set<String>()
    private var deletedAccounts = Set<UUID>()
    private var accountEpochs: [UUID: Int] = [:]

    init(rootDirectory: URL? = nil) {
        directory = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "InsightComposerDrafts", directoryHint: .isDirectory)
    }

    func load(scope: InsightSessionScope, key: String, accountEpoch: Int) async throws -> InsightComposerDraftSnapshot? {
        guard !deletedAccounts.contains(scope.accountID), accountEpochs[scope.accountID, default: 0] == accountEpoch else { return nil }
        let url = fileURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let encrypted = try Data(contentsOf: url)
        let data = try await InsightPersonalCryptoActor.shared.open(encrypted, accountID: scope.accountID, recordID: "composer-draft/\(key)")
        guard !deletedAccounts.contains(scope.accountID), accountEpochs[scope.accountID, default: 0] == accountEpoch else { return nil }
        return try JSONDecoder().decode(InsightComposerDraftSnapshot.self, from: data)
    }

    func save(_ snapshot: InsightComposerDraftSnapshot, scope: InsightSessionScope, key: String, operationRevision: Int, accountEpoch: Int) async throws {
        guard !deletedKeys.contains(key), !deletedAccounts.contains(scope.accountID),
              accountEpochs[scope.accountID, default: 0] == accountEpoch else { return }
        guard operationRevision > (revisions[key] ?? 0) else { return }
        revisions[key] = operationRevision
        let data = try JSONEncoder().encode(snapshot)
        let encrypted = try await InsightPersonalCryptoActor.shared.seal(data, accountID: scope.accountID, recordID: "composer-draft/\(key)")
        guard revisions[key] == operationRevision, !deletedKeys.contains(key), !deletedAccounts.contains(scope.accountID),
              accountEpochs[scope.accountID, default: 0] == accountEpoch else { return }
        let url = fileURL(key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var parent = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try parent.setResourceValues(values)
        try encrypted.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(key: String, operationRevision: Int) throws {
        guard operationRevision > (revisions[key] ?? 0) else { return }
        revisions[key] = operationRevision
        try removeFile(key: key)
    }

    private func removeFile(key: String) throws {
        let url = fileURL(key: key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func removePermanently(key: String) throws {
        deletedKeys.insert(key)
        try removeFile(key: key)
    }

    func removeAccount(_ accountID: UUID, accountEpoch: Int) throws {
        guard accountEpoch >= accountEpochs[accountID, default: 0] else { return }
        accountEpochs[accountID] = accountEpoch
        deletedAccounts.insert(accountID)
        try removeAccountFiles(accountID)
    }

    func enableAccount(_ accountID: UUID, accountEpoch: Int) throws {
        guard accountEpoch > accountEpochs[accountID, default: 0] else { return }
        // The earlier purge may still be queued when consent is granted again.
        try removeAccountFiles(accountID)
        accountEpochs[accountID] = accountEpoch
        deletedAccounts.remove(accountID)
    }

    private func removeAccountFiles(_ accountID: UUID) throws {
        let url = directory.appending(path: accountID.uuidString, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func fileURL(key: String) -> URL { directory.appending(path: key + ".draft") }
}
