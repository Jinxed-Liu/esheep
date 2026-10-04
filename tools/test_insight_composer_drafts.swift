import Foundation

/// Run with production DraftStore/Queue and unchanged App media/document value
/// types. The controllable App-owned cipher fixture returns identity payloads:
/// these checks exercise storage ordering and scope isolation, not encryption.
@main
struct InsightComposerDraftRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
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

    static func fileURL(_ root: URL, _ scope: InsightSessionScope, _ conversationID: UUID? = nil) -> URL {
        root.appending(path: "\(scope.accountID)/\(scope.farmID)/\(conversationID?.uuidString ?? "new").draft")
    }

    @MainActor
    static func restoredText(_ root: URL, _ scope: InsightSessionScope, _ conversationID: UUID? = nil) async throws -> String {
        let reader = InsightComposerDraftStore(rootDirectory: root)
        try await reader.restore(scope: scope, conversationID: conversationID)
        return reader.draft(scope: scope, conversationID: conversationID).text
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "esheep-composer-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InsightComposerDraftStore(rootDirectory: root)
        let scope = InsightSessionScope(accountID: UUID(), farmID: UUID())
        let otherFarm = InsightSessionScope(accountID: scope.accountID, farmID: UUID())
        let otherAccount = InsightSessionScope(accountID: UUID(), farmID: scope.farmID)
        let draft = store.draft(scope: scope, conversationID: nil)
        try require(draft === store.draft(scope: scope, conversationID: nil), "One scope returned different unsent drafts.")
        try require(draft !== store.draft(scope: otherFarm, conversationID: nil) && draft !== store.draft(scope: otherAccount, conversationID: nil), "Drafts leaked between farm/account scopes.")
        draft.text = "尚未发送的称重问题"
        draft.modeRawValue = "plan"
        draft.images = [.init(data: Data([1, 2]), mimeType: "image/jpeg", pixelWidth: 2, pixelHeight: 3, digest: "fixture")]
        draft.audio = .init(data: Data([3]), mimeType: "audio/mp4", duration: 2, waveformSamples: [0.1, 0.2])
        draft.documents = [.init(id: UUID(), fileName: "待选择.txt", mimeType: "text/plain", rawData: Data("附件草稿".utf8), digest: "fixture", sections: [], issues: [])]
        try await store.save(scope: scope, conversationID: nil)
        let reader = InsightComposerDraftStore(rootDirectory: root)
        try await reader.restore(scope: scope, conversationID: nil)
        let restored = reader.draft(scope: scope, conversationID: nil)
        try require(restored.text == draft.text && restored.modeRawValue == "plan" && restored.images == draft.images && restored.audio == draft.audio && restored.documents == draft.documents && restored.draftID == draft.draftID, "Draft content/media/mode/identity failed to restore.")
        print("PASS: account/farm draft isolation and media/mode/identity round trip")

        let unchangedScope = InsightSessionScope(accountID: scope.accountID, farmID: UUID())
        let unchanged = store.draft(scope: unchangedScope, conversationID: nil)
        unchanged.text = "Composer\nSecond line"
        unchanged.images = draft.images
        unchanged.audio = draft.audio
        unchanged.documents = draft.documents
        unchanged.modeRawValue = draft.modeRawValue
        try await store.save(scope: unchangedScope, conversationID: nil)
        let unchangedRevision = unchanged.revision
        // Focus/disabled updates can write the same binding values after send.
        let sentText = unchanged.text
        let sentImages = unchanged.images
        let sentAudio = unchanged.audio
        let sentDocuments = unchanged.documents
        let sentMode = unchanged.modeRawValue
        unchanged.text = sentText
        unchanged.images = sentImages
        unchanged.audio = sentAudio
        unchanged.documents = sentDocuments
        unchanged.modeRawValue = sentMode
        store.consumeNewDraft(scope: unchangedScope, expectedRevision: unchangedRevision)
        try await store.save(scope: unchangedScope, conversationID: nil)
        let consumedText = try await restoredText(root, unchangedScope)
        try require(!unchanged.hasContent && consumedText.isEmpty, "Same-value binding writes preserved the sent draft after cold restore.")
        print("PASS: same-value binding writes cannot preserve a sent draft on cold restore")

        let submittedRevision = draft.revision
        let oldIdentity = draft.draftID
        draft.text = "保存期间继续输入的新问题"
        store.consumeNewDraft(scope: scope, expectedRevision: submittedRevision)
        try require(draft.text == "保存期间继续输入的新问题" && draft.draftID != oldIdentity && !draft.images.isEmpty, "First send consumed later edits or reused the sent identity.")
        let acceptedRevision = draft.revision
        let acceptedIdentity = draft.draftID
        store.consumeNewDraft(scope: scope, expectedRevision: acceptedRevision)
        try require(!draft.hasContent && draft.modeRawValue == "conversation" && draft.draftID != acceptedIdentity, "Successful unchanged first send did not clear/renew draft.")
        print("PASS: first-send revision protects newer edits and renews each draft identity")

        let durableScope = InsightSessionScope(accountID: scope.accountID, farmID: UUID())
        let durableDraft = store.draft(scope: durableScope, conversationID: nil)
        durableDraft.text = "saved before send"
        try await store.save(scope: durableScope, conversationID: nil)
        let durableRevision = durableDraft.revision
        let durableIdentity = durableDraft.draftID
        durableDraft.text = "edited during send\nKeep this line"
        let sealsBeforeConsumption = await InsightPersonalCryptoActor.shared.sealCount
        await InsightPersonalCryptoActor.shared.holdNextSeal()
        var consumptionReturned = false
        let consumption = Task { @MainActor in
            try await store.consumeNewDraftAndSave(scope: durableScope, expectedRevision: durableRevision)
            consumptionReturned = true
        }
        try await waitForSeal()
        try require(!consumptionReturned, "Awaited consumption returned while its encrypted save was suspended.")
        let beforeConsumptionFinished = try await restoredText(root, durableScope)
        try require(beforeConsumptionFinished == "saved before send", "A duplicate consumption save bypassed the held encrypted write.")
        await InsightPersonalCryptoActor.shared.releaseSeal()
        try await consumption.value
        let preservedText = try await restoredText(root, durableScope)
        let sealsAfterConsumption = await InsightPersonalCryptoActor.shared.sealCount
        try require(sealsAfterConsumption == sealsBeforeConsumption + 1, "Awaited consumption scheduled more than one encrypted save.")
        try require(preservedText == durableDraft.text && durableDraft.draftID != durableIdentity, "Durable consumption lost the next draft's real edits.")
        let finalRevision = durableDraft.revision
        try await store.consumeNewDraftAndSave(scope: durableScope, expectedRevision: finalRevision)
        let durablyClearedText = try await restoredText(root, durableScope)
        try require(durablyClearedText.isEmpty && !FileManager.default.fileExists(atPath: fileURL(root, durableScope).path), "Awaited consumption returned before the sent draft was removed.")
        print("PASS: awaited consumption persists genuine later edits and removes an unchanged sent draft")

        draft.text = "old snapshot"
        await InsightPersonalCryptoActor.shared.holdNextSeal()
        let oldSave = Task { @MainActor in try await store.save(scope: scope, conversationID: nil) }
        try await waitForSeal()
        draft.text = "latest snapshot"
        try await store.save(scope: scope, conversationID: nil)
        await InsightPersonalCryptoActor.shared.releaseSeal()
        try await oldSave.value
        let latest = try await restoredText(root, scope)
        try require(latest == "latest snapshot", "Late seal overwrote a newer save.")
        print("PASS: latest save survives a delayed earlier seal")

        draft.text = "will be cleared"
        await InsightPersonalCryptoActor.shared.holdNextSeal()
        let clearRace = Task { @MainActor in try await store.save(scope: scope, conversationID: nil) }
        try await waitForSeal()
        store.clear(scope: scope, conversationID: nil)
        draft.text = "new draft after clear"
        try await store.save(scope: scope, conversationID: nil)
        await InsightPersonalCryptoActor.shared.releaseSeal()
        try await clearRace.value
        let afterClear = try await restoredText(root, scope)
        try require(afterClear == "new draft after clear", "Old save/remove erased the new draft after clear.")
        print("PASS: clear and delayed old save cannot erase the next draft")

        draft.text = "sensitive pre-withdrawal draft"
        await InsightPersonalCryptoActor.shared.holdNextSeal()
        let withdrawnSave = Task { @MainActor in try await store.save(scope: scope, conversationID: nil) }
        try await waitForSeal()
        store.removeAccount(accountID: scope.accountID)
        try await store.enableAccount(accountID: scope.accountID)
        let fresh = store.draft(scope: scope, conversationID: nil)
        fresh.text = "new consent draft"
        try await store.save(scope: scope, conversationID: nil)
        await InsightPersonalCryptoActor.shared.releaseSeal()
        try await withdrawnSave.value
        let afterConsent = try await restoredText(root, scope)
        try require(afterConsent == "new consent draft", "Old account epoch resurrected sensitive draft after new consent.")
        try require(draft.text.isEmpty && draft.images.isEmpty && draft.audio == nil && draft.documents.isEmpty, "Withdrawal retained sensitive in-memory inputs.")
        print("PASS: withdrawal/new consent rejects late old seals and clears captured inputs")

        let conversationID = UUID()
        let conversationDraft = store.draft(scope: scope, conversationID: conversationID)
        conversationDraft.text = "deleted conversation input"
        await InsightPersonalCryptoActor.shared.holdNextSeal()
        let deletedSave = Task { @MainActor in try await store.save(scope: scope, conversationID: conversationID) }
        try await waitForSeal()
        store.removeConversation(scope: scope, conversationID: conversationID)
        store.removeAccount(accountID: scope.accountID)
        try await store.enableAccount(accountID: scope.accountID)
        await InsightPersonalCryptoActor.shared.releaseSeal()
        try await deletedSave.value
        store.draft(scope: scope, conversationID: conversationID).text = "late write attempt"
        try await store.save(scope: scope, conversationID: conversationID)
        try require(!FileManager.default.fileExists(atPath: fileURL(root, scope, conversationID).path), "New consent resurrected a deleted conversation draft.")
        print("PASS: deleted conversation tombstone survives new consent and late seal")

        let corruptedScope = InsightSessionScope(accountID: UUID(), farmID: UUID())
        let corruptURL = fileURL(root, corruptedScope)
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("unreadable snapshot".utf8)
        try invalid.write(to: corruptURL)
        do {
            try await store.restore(scope: corruptedScope, conversationID: nil)
            throw Failure(description: "Malformed draft unexpectedly restored.")
        } catch is DecodingError {}
        store.draft(scope: corruptedScope, conversationID: nil).text = "new unsaved content"
        do {
            try await store.save(scope: corruptedScope, conversationID: nil)
            throw Failure(description: "Failed restore was silently overwritten.")
        } catch is Failure { throw Failure(description: "Failed restore was silently overwritten.") }
        catch {}
        let originalSidecar = try Data(contentsOf: corruptURL)
        try require(originalSidecar == invalid, "Failed restore overwrote its original sidecar.")
        print("PASS: failed restore preserves the original sidecar and rejects misleading save")
        store.removeAccount(accountID: corruptedScope.accountID)
        try await store.waitForAccountRemoval(accountID: corruptedScope.accountID)
        try require(!FileManager.default.fileExists(atPath: corruptURL.path), "Awaited account purge left the original sidecar on disk.")
        print("PASS: sensitive account cleanup can be awaited to physical file removal")
        print("Composer draft regression passed: 10 behavioral checks; identity cipher fixture only, no iOS build.")
    }
}
