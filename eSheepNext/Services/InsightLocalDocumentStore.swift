import CryptoKit
import Foundation

protocol InsightDocumentCipher: Sendable {
    func seal(_ data: Data, accountID: UUID, recordID: String) async throws -> Data
    func open(_ data: Data, accountID: UUID, recordID: String) async throws -> Data
}

extension InsightPersonalCryptoActor: InsightDocumentCipher {}

/// Encrypted metadata contains only the selected evidence; source bytes are
/// encrypted separately so raw documents never enter message text or sync.
struct InsightArchivedDocument: Codable, Sendable, Equatable {
    let id: UUID
    let fileName: String
    let mimeType: String
    let digest: String
    let byteCount: Int
    let sections: [InsightDocumentSection]
    let issues: [InsightDocumentIssue]
    let selection: [InsightDocumentRange]
    let acknowledgesPartialContent: Bool
    let originalReadableBlockCount: Int

    init(_ document: PendingInsightDocument) throws {
        _ = try document.modelContextText()
        id = document.id
        fileName = document.fileName
        mimeType = document.mimeType
        digest = document.digest
        byteCount = document.byteCount
        issues = document.issues
        selection = document.selection
        acknowledgesPartialContent = document.acknowledgesPartialContent
        originalReadableBlockCount = document.originalReadableBlockCount ?? document.sections.reduce(0) { $0 + $1.blocks.count }
        sections = document.sections.compactMap { section in
            let blocks = section.blocks.filter { block in
                document.selection.contains { $0.sectionID == section.id && block.id >= $0.firstBlock && block.id <= $0.lastBlock }
            }
            return blocks.isEmpty ? nil : .init(id: section.id, title: section.title, blocks: blocks, totalBlockCount: section.totalBlockCount)
        }
    }
}

/// History chips and model replay read only selected evidence, never source bytes.
struct InsightStoredDocumentPreview: Identifiable, Sendable, Equatable {
    let archive: InsightArchivedDocument
    var id: UUID { archive.id }
    var fileName: String { archive.fileName }
    var mimeType: String { archive.mimeType }
    var digest: String { archive.digest }
    var byteCount: Int { archive.byteCount }
    var sections: [InsightDocumentSection] { archive.sections }
    var issues: [InsightDocumentIssue] { archive.issues }
    var selection: [InsightDocumentRange] { archive.selection }
    var isPartialSelection: Bool {
        !issues.isEmpty || sections.reduce(0, { $0 + $1.blocks.count }) < archive.originalReadableBlockCount
    }

    func modelContextText(maxUTF8Bytes: Int = InsightDocumentAnalysis.maximumContextBytes) throws -> String {
        let blocks = selection.flatMap { range in
            sections.first(where: { $0.id == range.sectionID })?.blocks.filter { $0.id >= range.firstBlock && $0.id <= range.lastBlock } ?? []
        }
        guard !blocks.isEmpty else { throw InsightDocumentError.selectionRequired }
        return try InsightDocumentContextRenderer.render(id: id, fileName: fileName, digest: digest,
                                                        isPartial: isPartialSelection, issues: issues, blocks: blocks, maximumBytes: maxUTF8Bytes)
    }
}

actor InsightLocalDocumentStore {
    static let shared = InsightLocalDocumentStore()

    private struct Manifest: Codable {
        let accountID: UUID
        let farmID: UUID
        let conversationID: UUID
        let messageID: UUID
        let documents: [InsightArchivedDocument]
    }

    private let rootDirectory: URL
    private let crypto: any InsightDocumentCipher
    private var disabledAccounts = Set<UUID>()
    private var deletedConversations = Set<String>()
    private var deletedMessages = Set<String>()
    private var accountEpochs: [UUID: UInt64] = [:]
    private var conversationEpochs: [String: UInt64] = [:]
    private var messageEpochs: [String: UInt64] = [:]

    private struct ScopeToken {
        let accountID: UUID
        let conversationKey: String
        let messageKey: String
        let accountEpoch: UInt64
        let conversationEpoch: UInt64
        let messageEpoch: UInt64
    }

    init(rootDirectory: URL? = nil, crypto: any InsightDocumentCipher = InsightPersonalCryptoActor.shared) {
        self.rootDirectory = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "InsightDocuments", directoryHint: .isDirectory)
        self.crypto = crypto
    }

    func save(
        _ documents: [PendingInsightDocument], messageID: UUID, conversationID: UUID, accountID: UUID, farmID: UUID
    ) async throws {
        let token = try capture(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        try InsightDocumentAnalysis.validate(documents)
        guard !documents.isEmpty else { return }
        let archived = try documents.map(InsightArchivedDocument.init)
        let destination = messageDirectory(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try await load(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
            try check(token)
            guard try existing.map(InsightArchivedDocument.init) == archived else {
                throw InsightDocumentError.malformed("附件保存标识冲突，原文档已保留，请重试发送。")
            }
            return
        }
        let temporary = destination.deletingLastPathComponent().appending(path: ".pending-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try protect(temporary)
        let recordScope = scope(messageID: messageID, conversationID: conversationID, farmID: farmID)
        for document in documents {
            let encrypted = try await crypto.seal(document.rawData, accountID: accountID, recordID: "\(recordScope)/\(document.id.uuidString)/source")
            try check(token)
            let url = temporary.appending(path: "\(document.id.uuidString.lowercased()).bin")
            try encrypted.write(to: url, options: .atomic)
            try protect(url)
        }
        let manifest = Manifest(accountID: accountID, farmID: farmID, conversationID: conversationID, messageID: messageID, documents: archived)
        let encryptedManifest = try await crypto.seal(JSONEncoder().encode(manifest), accountID: accountID, recordID: "\(recordScope)/manifest")
        try check(token)
        let manifestURL = temporary.appending(path: "manifest.bin")
        try encryptedManifest.write(to: manifestURL, options: .atomic)
        try protect(manifestURL)
        try check(token)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func load(messageID: UUID, conversationID: UUID, accountID: UUID, farmID: UUID) async throws -> [PendingInsightDocument] {
        guard let token = try? capture(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID) else { return [] }
        let directory = messageDirectory(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        guard let manifest = try await readManifest(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID) else { return [] }
        try check(token)
        let recordScope = scope(messageID: messageID, conversationID: conversationID, farmID: farmID)
        var documents: [PendingInsightDocument] = []
        for archived in manifest.documents {
            guard archived.byteCount <= InsightDocumentAnalysis.maximumFileBytes else { throw InsightDocumentError.fileTooLarge }
            let sourceURL = directory.appending(path: "\(archived.id.uuidString.lowercased()).bin")
            let encrypted = try boundedData(at: sourceURL, maximumBytes: InsightDocumentAnalysis.maximumFileBytes + 64)
            let data = try await crypto.open(encrypted, accountID: accountID, recordID: "\(recordScope)/\(archived.id.uuidString)/source")
            try check(token)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == archived.byteCount, digest == archived.digest else { throw InsightSecurityError.corruptedCiphertext }
            documents.append(PendingInsightDocument(
                id: archived.id, fileName: archived.fileName, mimeType: archived.mimeType,
                rawData: data, digest: digest, sections: archived.sections, issues: archived.issues,
                selection: archived.selection, acknowledgesPartialContent: archived.acknowledgesPartialContent,
                originalReadableBlockCount: archived.originalReadableBlockCount
            ))
        }
        try InsightDocumentAnalysis.validate(documents)
        try check(token)
        return documents
    }

    func previews(messageID: UUID, conversationID: UUID, accountID: UUID, farmID: UUID) async throws -> [InsightStoredDocumentPreview] {
        guard let token = try? capture(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID) else { return [] }
        guard let manifest = try await readManifest(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID) else { return [] }
        try check(token)
        return manifest.documents.map { .init(archive: $0) }
    }

    func removeMessage(messageID: UUID, conversationID: UUID, accountID: UUID, farmID: UUID) throws {
        let key = messageKey(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        deletedMessages.insert(key)
        messageEpochs[key, default: 0] += 1
        try remove(messageDirectory(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID))
    }

    func removeConversation(conversationID: UUID, accountID: UUID, farmID: UUID) throws {
        let key = conversationKey(conversationID: conversationID, accountID: accountID, farmID: farmID)
        deletedConversations.insert(key)
        conversationEpochs[key, default: 0] += 1
        try remove(conversationDirectory(conversationID: conversationID, accountID: accountID, farmID: farmID))
    }

    func removeAccount(accountID: UUID) throws {
        disabledAccounts.insert(accountID)
        accountEpochs[accountID, default: 0] += 1
        try remove(rootDirectory.appending(path: accountID.uuidString.lowercased(), directoryHint: .isDirectory))
    }

    func enableAccount(accountID: UUID) {
        if disabledAccounts.remove(accountID) != nil { accountEpochs[accountID, default: 0] += 1 }
    }

    private func readManifest(messageID: UUID, conversationID: UUID, accountID: UUID, farmID: UUID) async throws -> Manifest? {
        let token = try capture(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        let directory = messageDirectory(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        let url = directory.appending(path: "manifest.bin")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let encrypted = try boundedData(at: url, maximumBytes: 2 * 1_024 * 1_024)
        let recordScope = scope(messageID: messageID, conversationID: conversationID, farmID: farmID)
        let plaintext = try await crypto.open(encrypted, accountID: accountID, recordID: "\(recordScope)/manifest")
        try check(token)
        let manifest = try JSONDecoder().decode(Manifest.self, from: plaintext)
        guard manifest.accountID == accountID, manifest.farmID == farmID,
              manifest.conversationID == conversationID, manifest.messageID == messageID,
              manifest.documents.count <= 3 else { throw InsightSecurityError.accountMismatch }
        return manifest
    }

    private func conversationKey(conversationID: UUID, accountID: UUID, farmID: UUID) -> String {
        "\(accountID)/\(farmID)/\(conversationID)"
    }

    private func messageKey(messageID: UUID, conversationID: UUID, accountID: UUID, farmID: UUID) -> String {
        "\(conversationKey(conversationID: conversationID, accountID: accountID, farmID: farmID))/\(messageID)"
    }

    private func capture(messageID: UUID, conversationID: UUID, accountID: UUID, farmID: UUID) throws -> ScopeToken {
        let conversation = conversationKey(conversationID: conversationID, accountID: accountID, farmID: farmID)
        let message = messageKey(messageID: messageID, conversationID: conversationID, accountID: accountID, farmID: farmID)
        let token = ScopeToken(accountID: accountID, conversationKey: conversation, messageKey: message,
                               accountEpoch: accountEpochs[accountID, default: 0],
                               conversationEpoch: conversationEpochs[conversation, default: 0], messageEpoch: messageEpochs[message, default: 0])
        try check(token)
        return token
    }

    private func check(_ token: ScopeToken) throws {
        guard !disabledAccounts.contains(token.accountID), !deletedConversations.contains(token.conversationKey),
              !deletedMessages.contains(token.messageKey), accountEpochs[token.accountID, default: 0] == token.accountEpoch,
              conversationEpochs[token.conversationKey, default: 0] == token.conversationEpoch,
              messageEpochs[token.messageKey, default: 0] == token.messageEpoch else { throw InsightDocumentError.storageScopeDeleted }
    }

    private func remove(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func conversationDirectory(conversationID: UUID, accountID: UUID, farmID: UUID) -> URL {
        rootDirectory.appending(path: accountID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: farmID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: conversationID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func messageDirectory(messageID: UUID, conversationID: UUID, accountID: UUID, farmID: UUID) -> URL {
        conversationDirectory(conversationID: conversationID, accountID: accountID, farmID: farmID)
            .appending(path: messageID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func scope(messageID: UUID, conversationID: UUID, farmID: UUID) -> String {
        "local-document/\(farmID.uuidString)/\(conversationID.uuidString)/\(messageID.uuidString)"
    }

    private func protect(_ url: URL) throws {
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw InsightSecurityError.corruptedCiphertext }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw InsightSecurityError.corruptedCiphertext }
        return data
    }
}
