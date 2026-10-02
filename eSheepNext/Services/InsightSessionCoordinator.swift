import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class InsightSessionCoordinator {
    static let shared = InsightSessionCoordinator()
    let requestQueue: InsightSessionRequestQueue
    let draftStore = InsightComposerDraftStore()
    @ObservationIgnored private var controllers: [String: InsightConversationController] = [:]
    @ObservationIgnored private var controllerScopes: [ObjectIdentifier: InsightSessionScope] = [:]
    @ObservationIgnored private var loadedScopes = Set<InsightSessionScope>()
    @ObservationIgnored private var connectedContexts: [ObjectIdentifier: ObjectIdentifier] = [:]
    @ObservationIgnored private var accountCleanupTasks: [UUID: (id: UUID, task: Task<Void, Error>)] = [:]
#if DEBUG
    @ObservationIgnored private var designAcceptanceClients: [InsightSessionScope: any MiMoResponding] = [:]
#endif
    private(set) var deletedConversations = Set<String>()

    init(maximumConcurrentRequests: Int = 2) {
        requestQueue = InsightSessionRequestQueue(maximumConcurrentRequests: maximumConcurrentRequests)
    }

    func controller(account: AccountProfile, farm: FarmRecord, conversationID: UUID?, draftID: UUID? = nil) -> InsightConversationController {
        let scope = InsightConversationScope(accountID: account.effectiveAccountID, farmID: farm.id)
        let key = controllerKey(scope: scope, conversationID: conversationID,
            draftID: draftID ?? draft(scope: scope, conversationID: nil).draftID)
        if let existing = controllers[key] { return existing }
#if DEBUG
        let client: any MiMoResponding = designAcceptanceClients[sessionScope(scope)] ?? MiMoClient.shared
        let created = InsightConversationController(account: account, farm: farm, client: client)
#else
        let created = InsightConversationController(account: account, farm: farm)
#endif
        controllers[key] = created
        controllerScopes[ObjectIdentifier(created)] = sessionScope(scope)
        return created
    }

#if DEBUG
    /// Sends through the real controller using an offline responder only for
    /// the explicitly launched, synthetic acceptance account and farm.
    func configureDesignAcceptanceClient(_ client: any MiMoResponding, account: AccountProfile, farm: FarmRecord) throws {
        let arguments = ProcessInfo.processInfo.arguments
        let scope = InsightSessionScope(accountID: account.effectiveAccountID, farmID: farm.id)
        guard arguments.contains("--design-acceptance"),
              arguments.contains("--design-insight-offline-send"),
              account.appleSubjectHash == AppleIdentityHash.value(for: "design-acceptance-local"),
              account.serverAccountID == nil, farm.ownerAccountID == account.id,
              !controllerScopes.values.contains(scope) else {
            throw InsightSecurityError.accountMismatch
        }
        designAcceptanceClients[scope] = client
    }
#endif

    func connect(_ controller: InsightConversationController, to context: ModelContext, preferredConversationID: UUID? = nil) async {
        let controllerID = ObjectIdentifier(controller)
        if let originalScope = controllerScopes[controllerID], originalScope != sessionScope(controller.conversationScope) {
            controller.pauseForLifecycle(reason: "账号身份已变更，请从当前牧场的聊天列表重新打开。")
            controller.errorMessage = "账号身份已变更，原会话不会转入新账号。"
            return
        }
        if AIPrivacyConsentStore.hasCurrentConsent(for: controller.conversationScope.accountID) {
            do { try await draftStore.enableAccount(accountID: controller.conversationScope.accountID) }
            catch { controller.errorMessage = "草稿安全存储暂时不可用：\(error.localizedDescription)" }
        }
        let contextID = ObjectIdentifier(context)
        if connectedContexts[controllerID] == contextID {
            if !controller.isGenerating {
                controller.refresh()
                await controller.refreshCredential()
            }
            return
        }
        if connectedContexts[controllerID] != nil {
            controller.pauseForLifecycle(reason: "本机数据容器已切换，任务已暂停。")
        }
        connectedContexts[controllerID] = contextID
        let scope = sessionScope(controller.conversationScope)
        if loadedScopes.insert(scope).inserted {
            controller.connectLocalState(to: context, recoverInterrupted: true)
        }
        await controller.connect(to: context, preferredConversationID: preferredConversationID, recoverInterrupted: false)
    }

    func draft(scope: InsightConversationScope, conversationID: UUID?) -> InsightComposerDraft {
        draftStore.draft(scope: sessionScope(scope), conversationID: conversationID)
    }

    func completeDraft(scope: InsightConversationScope, draftID: UUID, conversationID: UUID, controller: InsightConversationController, expectedDraftRevision: Int? = nil) {
        guard controllerScopes[ObjectIdentifier(controller)] == sessionScope(scope) else { return }
        controllers[controllerKey(scope: scope, conversationID: conversationID, draftID: nil)] = controller
        controllers.removeValue(forKey: controllerKey(scope: scope, conversationID: nil, draftID: draftID))
        draftStore.consumeNewDraft(scope: sessionScope(scope), expectedRevision: expectedDraftRevision)
    }

    func acquire(scope: InsightConversationScope, requestID: UUID, conversationID: UUID? = nil) async throws {
        if let conversationID, isDeleted(scope: scope, conversationID: conversationID) { throw CancellationError() }
        try await requestQueue.acquire(scope: sessionScope(scope), requestID: requestID, conversationID: conversationID)
    }

    func release(requestID: UUID) { requestQueue.release(requestID: requestID) }
    func cancel(requestID: UUID) { requestQueue.cancel(requestID: requestID) }

    func allowsWork(scope: InsightConversationScope) -> Bool {
        requestQueue.isForeground && requestQueue.activeScope == sessionScope(scope)
    }

    func activate(scope: InsightConversationScope?) {
        let selected = scope.map(sessionScope)
        guard requestQueue.activeScope != selected else { return }
        requestQueue.activate(scope: selected)
        for controller in uniqueControllers where controllerScopes[ObjectIdentifier(controller)] != selected {
            controller.pauseForLifecycle(reason: "账号或牧场已切换，任务已暂停。")
        }
    }

    func setForeground(_ foreground: Bool) {
        requestQueue.setForeground(foreground)
        if !foreground {
            for controller in uniqueControllers {
                controller.pauseForLifecycle(reason: "App 已离开前台，任务已暂停。")
            }
        }
    }

    func pauseAll(reason: String) {
        requestQueue.pauseAll()
        for controller in uniqueControllers { controller.pauseForLifecycle(reason: reason) }
    }

    func clearAccountRuntime(accountID: UUID) {
        draftStore.removeAccount(accountID: accountID)
        for controller in uniqueControllers where controllerScopes[ObjectIdentifier(controller)]?.accountID == accountID || controller.conversationScope.accountID == accountID {
            controller.clearRuntimeForConsentWithdrawal()
        }
        let previous = accountCleanupTasks[accountID]?.task
        let cleanupID = UUID()
        let cleanup = Task<Void, Error> { @MainActor [draftStore] in
            if let previous { _ = try? await previous.value }
            var failures: [String] = []
            do { try await InsightRuntimeStore.shared.removeAccount(accountID) }
            catch { failures.append(error.localizedDescription) }
            do { try await InsightLocalDocumentStore.shared.removeAccount(accountID: accountID) }
            catch { failures.append(error.localizedDescription) }
            do { try await draftStore.waitForAccountRemoval(accountID: accountID) }
            catch { failures.append(error.localizedDescription) }
            if !failures.isEmpty { throw InsightAccountCleanupError(failures: failures) }
        }
        accountCleanupTasks[accountID] = (cleanupID, cleanup)
    }

    func waitForAccountCleanup(accountID: UUID) async throws {
        while let cleanup = accountCleanupTasks[accountID] {
            do { try await cleanup.task.value }
            catch {
                if accountCleanupTasks[accountID]?.id != cleanup.id { continue }
                throw error
            }
            if accountCleanupTasks[accountID]?.id == cleanup.id { return }
        }
    }

    func state(scope: InsightConversationScope, conversationID: UUID) -> InsightSessionRunState? {
        requestQueue.state(scope: sessionScope(scope), conversationID: conversationID)
    }

    func cachedController(scope: InsightConversationScope, conversationID: UUID) -> InsightConversationController? {
        controllers[controllerKey(scope: scope, conversationID: conversationID, draftID: nil)]
    }

    func isDeleted(scope: InsightConversationScope, conversationID: UUID) -> Bool {
        deletedConversations.contains(controllerKey(scope: scope, conversationID: conversationID, draftID: nil))
    }

    func cancelConversation(_ conversationID: UUID, scope: InsightConversationScope) {
        deletedConversations.insert(controllerKey(scope: scope, conversationID: conversationID, draftID: nil))
        for entry in Array(requestQueue.entries.values) where entry.scope == sessionScope(scope) && entry.conversationID == conversationID {
            requestQueue.cancel(requestID: entry.requestID)
        }
        for controller in uniqueControllers where controllerScopes[ObjectIdentifier(controller)] == sessionScope(scope) && controller.currentConversationID == conversationID {
            controller.stopGenerating()
        }
    }

    func restoreConversationAfterFailedDeletion(_ conversationID: UUID, scope: InsightConversationScope) {
        deletedConversations.remove(controllerKey(scope: scope, conversationID: conversationID, draftID: nil))
    }

    func delete(_ conversation: InsightConversationRecord, using controller: InsightConversationController) {
        let scope = controller.conversationScope
        guard scope.contains(conversation) else { return }
        let key = controllerKey(scope: scope, conversationID: conversation.id, draftID: nil)
        deletedConversations.insert(key)
        cancelConversation(conversation.id, scope: scope)
        controller.deleteConversation(conversation)
        if conversation.deletedAt == nil { deletedConversations.remove(key) }
        else { draftStore.removeConversation(scope: sessionScope(scope), conversationID: conversation.id) }
    }

    private var uniqueControllers: [InsightConversationController] {
        var seen = Set<ObjectIdentifier>()
        return controllers.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func sessionScope(_ scope: InsightConversationScope) -> InsightSessionScope {
        InsightSessionScope(accountID: scope.accountID, farmID: scope.farmID)
    }

    private func controllerKey(scope: InsightConversationScope, conversationID: UUID?, draftID: UUID?) -> String {
        "\(scope.accountID)/\(scope.farmID)/\(conversationID.map { "conversation-\($0)" } ?? "draft-\(draftID?.uuidString ?? "list")")"
    }
}

private struct InsightAccountCleanupError: LocalizedError {
    let failures: [String]
    var errorDescription: String? { failures.joined(separator: "\n") }
}
