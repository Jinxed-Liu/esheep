import Foundation

/// Test seam for the App-owned cipher actor. Identity payloads deliberately do
/// not test encryption; this fixture controls actor suspension deterministically.
actor InsightPersonalCryptoActor {
    static let shared = InsightPersonalCryptoActor()
    private var holdNext = false
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var sealCount = 0
    func holdNextSeal() { holdNext = true }
    var isWaiting: Bool { pending != nil }
    func releaseSeal() { pending?.resume(); pending = nil }
    func seal(_ data: Data, accountID: UUID, recordID: String) async throws -> Data {
        sealCount += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { pending = $0 }
        }
        return data
    }
    func open(_ data: Data, accountID: UUID, recordID: String) async throws -> Data { data }
}

@main
struct InsightRuntimeEpochRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }
    static func waitForSeal() async throws {
        for _ in 0..<2_000 {
            if await InsightPersonalCryptoActor.shared.isWaiting { return }
            await Task.yield()
        }
        throw Failure(description: "Cipher fixture did not suspend.")
    }
    static func stopped(_ task: Task<Void, Error>) async throws {
        do { try await task.value; throw Failure(description: "Deleted epoch accepted late save.") }
        catch InsightWorkflowError.stopped {}
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("esheep-runtime-epoch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InsightRuntimeStore(rootDirectory: directory)
        let accountID = UUID(), farmID = UUID(), conversationID = UUID()
        var value = InsightConversationRuntime(accountID: accountID, farmID: farmID, conversationID: conversationID)
        value.revision = 1
        let beforeWithdrawal = value
        await InsightPersonalCryptoActor.shared.holdNextSeal()
        let oldSave = Task { try await store.save(beforeWithdrawal) }
        try await waitForSeal()
        try await store.removeAccount(accountID)
        await store.enableAccount(accountID)
        await InsightPersonalCryptoActor.shared.releaseSeal()
        try await stopped(oldSave)
        try require(!FileManager.default.fileExists(atPath: directory.path), "Old epoch recreated removed account files.")
        print("PASS: first pending save cannot resurrect an account after withdrawal and new consent")

        // New consent can record new work in the same historical conversation.
        try await store.save(value)
        let loaded = try await store.load(accountID: accountID, farmID: farmID, conversationID: conversationID)
        try require(loaded?.revision == 1 && loaded?.conversationID == conversationID, "Fresh epoch could not persist current conversation.")
        try await store.removeAccount(accountID)
        await store.enableAccount(accountID)
        value.revision = 1
        try await store.save(value)
        let reloaded = try await store.load(accountID: accountID, farmID: farmID, conversationID: conversationID)
        try require(reloaded?.revision == 1, "Account clearing permanently tombstoned an existing conversation.")
        print("PASS: new consent permits fresh runtime in previously saved history")

        value.revision = 2
        let beforeDeletion = value
        await InsightPersonalCryptoActor.shared.holdNextSeal()
        let lateConversationSave = Task { try await store.save(beforeDeletion) }
        try await waitForSeal()
        try await store.removeConversation(accountID: accountID, farmID: farmID, conversationID: conversationID)
        await InsightPersonalCryptoActor.shared.releaseSeal()
        try await stopped(lateConversationSave)
        let deleted = try await store.load(accountID: accountID, farmID: farmID, conversationID: conversationID)
        try require(deleted == nil, "Late save resurrected a deleted conversation.")
        print("PASS: conversation deletion permanently blocks in-flight and later runtime writes")
        print("Runtime epoch regression passed: 3 deterministic actor checks; cipher fixture only, encryption and iOS file protection not verified.")
    }
}
