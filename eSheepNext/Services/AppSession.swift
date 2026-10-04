import Foundation
import Observation
import SwiftData

enum AppTab: Hashable {
    case home, workbench, analysis, search
    static var records: Self { .workbench }
    static var feeding: Self { .workbench }
    static var assistant: Self { .analysis }
}

enum WorkbenchSection: String, CaseIterable, Identifiable {
    case management = "管理", records = "生产记录", feeding = "投喂"
    var id: Self { self }
}

enum AppNavigationRequest: Codable, Sendable, Equatable {
    case home
    case addSheep
    case recordWeight
    case transferSheep
    case removeSheep
    case recordFeed
    case openSheep(UUID)

    private static let storageKey = "pending-app-navigation-request"

    static func enqueue(_ request: AppNavigationRequest) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func consume() -> AppNavigationRequest? {
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(AppNavigationRequest.self, from: data)
    }
}

enum FarmSessionError: LocalizedError {
    case emptyFarmName
    case farmNotFound

    var errorDescription: String? {
        switch self {
        case .emptyFarmName: "请填写牧场名称。"
        case .farmNotFound: "未找到要切换的牧场。"
        }
    }
}

@MainActor
@Observable
final class AppSession {
    @ObservationIgnored private let persistActiveAccountProfileID: (UUID) -> Void
    @ObservationIgnored private let clearActiveAccountProfileID: () -> Void
    @ObservationIgnored private var automaticRemoteDiscoveryAccountIDs = Set<UUID>()

    var activeAccountProfileID: UUID?
    var selectedFarmID: UUID?
    var selectedTab: AppTab = .home
    var workbenchSection: WorkbenchSection = .management
    var isCreateFarmPresented = false
    var isJoinFarmPresented = false
    var isReauthenticationPresented = false
    var lastSyncDescription = "本地记录待同步"
    var accountAccessStatus: AccountAccessStatus = .checking
    var authenticationRevision = 0
    private(set) var authenticationIdentityRevision = 0
    var authenticationNotice: String?
    private(set) var persistedLocalSessionAccountID: UUID?
    var pendingRecordEntry: PendingRecordEntry?
    var pendingSearchQuery: String?
    var pendingSheepID: UUID?
    var pendingCareReminderID: UUID?
    var pendingWidgetTarget: FarmSystemNavigationTarget?
    var pendingOperationalAlertsRequestID: UUID?
    var pendingESheepCloudInvitationCode: String?

    init(
        activeAccountProfileID: UUID? = SecureAccountStore.activeAccountProfileID(),
        persistedLocalSessionAccountID: UUID? = SecureAccountStore.persistedSessionAccountID(),
        persistActiveAccountProfileID: @escaping (UUID) -> Void = { identifier in
            _ = try? SecureAccountStore.saveActiveAccountProfileID(identifier)
        },
        clearActiveAccountProfileID: @escaping () -> Void = {
            _ = try? SecureAccountStore.clearActiveAccountProfileID()
        }
    ) {
        self.activeAccountProfileID = activeAccountProfileID
        self.persistedLocalSessionAccountID = persistedLocalSessionAccountID
        self.persistActiveAccountProfileID = persistActiveAccountProfileID
        self.clearActiveAccountProfileID = clearActiveAccountProfileID
    }

    func reconcileActiveFarm(with farms: [FarmRecord]) {
        guard !farms.isEmpty else {
            selectedFarmID = nil
            return
        }

        if let selectedFarmID, farms.contains(where: { $0.id == selectedFarmID }) {
            return
        }

        selectedFarmID = farms.first?.id
    }

    func consumePendingNavigationRequest() {
        guard let request = AppNavigationRequest.consume() else { return }
        switch request {
        case .home:
            selectedTab = .home
        case .addSheep:
            requestRecordEntry(.addSheep)
        case .recordWeight:
            requestRecordEntry(.weight)
        case .transferSheep:
            requestRecordEntry(.transfer)
        case .removeSheep:
            requestRecordEntry(.removal)
        case .recordFeed:
            workbenchSection = .feeding
            selectedTab = .workbench
            pendingRecordEntry = .feed
        case .openSheep(let sheepID):
            pendingSheepID = sheepID
            selectedTab = .search
        }
    }

    func consumeSystemNavigationTarget() {
        guard let target = FarmSystemNavigationStore.consume() else { return }
        selectedFarmID = target.farmID
        switch target.kind {
        case .home:
            selectedTab = .home
        case .searchSheep:
            pendingSearchQuery = target.query
            pendingSheepID = target.entityID
            selectedTab = .search
        case .openPen:
            pendingSearchQuery = target.query
            selectedTab = .search
        case .recordWeight:
            workbenchSection = .records
            selectedTab = .workbench
            pendingRecordEntry = .weight
        case .recordFeed:
            workbenchSection = .feeding
            selectedTab = .workbench
            pendingRecordEntry = .feed
        case .openCareReminder:
            pendingCareReminderID = target.entityID
            workbenchSection = .records
            selectedTab = .workbench
        case .openWidget:
            if target.query == FarmWidgetKind.overview.rawValue || target.query == FarmWidgetKind.duty.rawValue {
                selectedTab = .home
            } else if target.query == FarmWidgetKind.journal.rawValue {
                workbenchSection = .feeding
                selectedTab = .workbench
            } else {
                pendingWidgetTarget = target
            }
        case .openOperationalAlerts:
            pendingOperationalAlertsRequestID = UUID()
            selectedTab = .home
        }
    }

    func requestRecordEntry(_ entry: PendingRecordEntry) {
        workbenchSection = [.feed, .trough, .tmrProduction, .tmrFeeding].contains(entry) ? .feeding : .records
        selectedTab = .workbench
        pendingRecordEntry = entry
    }

    func switchFarm(to farmID: UUID, availableFarms: [FarmRecord]) throws {
        guard availableFarms.contains(where: { $0.id == farmID }) else {
            throw FarmSessionError.farmNotFound
        }

        selectedFarmID = farmID
        resetWorkspaceNavigation()
    }

    func resetWorkspaceNavigation() {
        pendingWidgetTarget = nil
        selectedTab = .home
        workbenchSection = .management
        pendingRecordEntry = nil
        pendingSearchQuery = nil
        pendingSheepID = nil
        pendingCareReminderID = nil
        pendingOperationalAlertsRequestID = nil
    }

    func context(for account: AccountProfile, activeFarm: FarmRecord) -> FarmContext {
        FarmContext(accountID: account.effectiveAccountID, farmID: activeFarm.id, role: activeFarm.role)
    }

    func authenticationDidSucceed(accountProfileID: UUID? = nil) {
        let previousAccountProfileID = activeAccountProfileID
        if let accountProfileID {
            activeAccountProfileID = accountProfileID
            persistActiveAccountProfileID(accountProfileID)
        }
        persistedLocalSessionAccountID = SecureAccountStore.persistedSessionAccountID()
        accountAccessStatus = .checking
        isReauthenticationPresented = false
        authenticationNotice = nil
        authenticationRevision += 1
        if activeAccountProfileID != previousAccountProfileID {
            authenticationIdentityRevision += 1
        }
    }

    func authenticationDidSignOut(warning: String? = nil) {
        activeAccountProfileID = nil
        clearActiveAccountProfileID()
        selectedFarmID = nil
        selectedTab = .home
        persistedLocalSessionAccountID = nil
        let notice = warning ?? "已退出登录。本机牧场缓存仍保留并与其他账号隔离；重新登录同一账号后可继续使用。"
        accountAccessStatus = .requiresSignIn(notice)
        isReauthenticationPresented = false
        authenticationNotice = notice
        authenticationRevision += 1
        authenticationIdentityRevision += 1
    }

    func authenticationCheckDidFinish(
        _ status: AccountAccessStatus,
        automaticallyPresentReauthentication: Bool
    ) {
        let wasReauthenticationRequired = accountAccessStatus.requiresSignIn
        accountAccessStatus = status

        if status.requiresSignIn {
            if automaticallyPresentReauthentication && !wasReauthenticationRequired {
                isReauthenticationPresented = true
            }
        } else {
            isReauthenticationPresented = false
        }
    }

    func requestAuthenticationRefresh() {
        accountAccessStatus = .checking
        authenticationRevision += 1
    }

    func beginAutomaticRemoteDiscovery(accountID: UUID) -> Bool {
        automaticRemoteDiscoveryAccountIDs.insert(accountID).inserted
    }

    func finishAutomaticRemoteDiscovery(accountID: UUID) {
        automaticRemoteDiscoveryAccountIDs.remove(accountID)
    }

    @discardableResult
    func createFarm(
        named name: String,
        account: AccountProfile,
        entitlement: AccountEntitlement,
        context: ModelContext,
        commandService: FarmCommandService = FarmCommandService()
    ) throws -> FarmRecord {
        let farm = try commandService.createFarm(
            named: name,
            account: account,
            entitlement: entitlement,
            context: context
        )

        selectedFarmID = farm.id
        selectedTab = .home
        return farm
    }
}

enum PendingRecordEntry: String, Sendable, Equatable, Identifiable {
    case addSheep
    case weight
    case transfer
    case removal
    case feed
    case health, weaning, reproduction, lambing, note, trough, tmrProduction, tmrFeeding

    var id: String { rawValue }
}
