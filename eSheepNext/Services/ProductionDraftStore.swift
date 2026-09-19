import Foundation

struct ProductionDraftKey: Codable, Hashable, Sendable {
    let environment: String
    let accountID: UUID
    let farmID: UUID
    let form: String

    var fileName: String {
        "\(accountID.uuidString)-\(farmID.uuidString)-\(form).json"
    }
}

struct ProductionDraft: Codable, Equatable, Sendable {
    var version = 1
    var id = UUID()
    var fields: [String: Data]
    var requestIDs: [UUID] = []
    // Optional for compatibility with drafts saved before time-mode persistence.
    var usesCurrentTime: Bool? = nil
    var updatedAt = Date.now
}

/// Local input only. Never included in farm backups, projections or cloud writes.
struct ProductionDraftStore: Sendable {
    let root: URL

    static var application: Self {
        let root = URL.applicationSupportDirectory.appending(path: "ProductionDrafts", directoryHint: .isDirectory)
        return Self(root: root)
    }

    func url(for key: ProductionDraftKey) -> URL {
        root.appending(path: key.environment, directoryHint: .isDirectory).appending(path: key.fileName)
    }

    func load(_ key: ProductionDraftKey) throws -> ProductionDraft? {
        let url = url(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft = try JSONDecoder().decode(ProductionDraft.self, from: Data(contentsOf: url))
        guard draft.version == 1 else { throw ProductionDraftError.unsupportedVersion }
        return draft
    }

    func save(_ draft: ProductionDraft, for key: ProductionDraftKey) throws {
        let url = url(for: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

    func remove(_ key: ProductionDraftKey) throws {
        let url = url(for: key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

enum ProductionDraftError: LocalizedError {
    case unsupportedVersion, contextChanged, incompleteRecovery
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "这份草稿来自不同版本，未修改原草稿。"
        case .contextChanged: "账号、牧场或权限已变化，请返回后重新打开。"
        case .incompleteRecovery: "提交回执不完整，请核对事件记录后再继续，当前草稿已保留。"
        }
    }
}
