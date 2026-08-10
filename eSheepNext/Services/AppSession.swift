import Foundation
import Observation
import SwiftData

enum AppTab: Hashable {
    case home
    case assistant
    case records
    case feeding
    case search
}

struct PendingFarmInvitation: Sendable, Equatable {
    let code: String
    let shareURL: URL

    init?(url: URL) {
        guard url.host == "invite",
              url.scheme == "esheep" || url.scheme == "esheep-staging",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
              code.count == 8,
              let shareValue = components.queryItems?.first(where: { $0.name == "share" })?.value,
              let shareURL = URL(string: shareValue),
              shareURL.scheme == "https" else {
            return nil
        }
        self.code = code
        self.shareURL = shareURL
    }
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
    @ObservationIgnored private var automaticCloudRecoveryAccountIDs = Set<UUID>()

    var activeAccountProfileID: UUID?
    var selectedFarmID: UUID?
    var selectedTab: AppTab = .home
    var isCreateFarmPresented = false
    var isJoinFarmPresented = false
    var isReauthenticationPresented = false
    var lastSyncDescription = "本地记录待同步"
    var accountAccessStatus: AccountAccessStatus = .checking
    var authenticationRevision = 0
    var authenticationNotice: String?
    private(set) var persistedLocalSessionAccountID: UUID?
    var pendingRecordEntry: PendingRecordEntry?
    var pendingSearchQuery: String?
    var pendingSheepID: UUID?
    var pendingCareReminderID: UUID?
    var pendingOperationalAlertsRequestID: UUID?
    var pendingFarmInvitation: PendingFarmInvitation?

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
            selectedTab = .feeding
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
            selectedTab = .records
            pendingRecordEntry = .weight
        case .recordFeed:
            selectedTab = .feeding
            pendingRecordEntry = .feed
        case .openCareReminder:
            pendingCareReminderID = target.entityID
            selectedTab = .records
        case .openOperationalAlerts:
            pendingOperationalAlertsRequestID = UUID()
            selectedTab = .home
        }
    }

    func requestRecordEntry(_ entry: PendingRecordEntry) {
        selectedTab = entry == .feed ? .feeding : .records
        pendingRecordEntry = entry
    }

    func switchFarm(to farmID: UUID, availableFarms: [FarmRecord]) throws {
        guard availableFarms.contains(where: { $0.id == farmID }) else {
            throw FarmSessionError.farmNotFound
        }

        selectedFarmID = farmID
        selectedTab = .home
    }

    func context(for account: AccountProfile, activeFarm: FarmRecord) -> FarmContext {
        FarmContext(accountID: account.effectiveAccountID, farmID: activeFarm.id, role: activeFarm.role)
    }

    func authenticationDidSucceed(accountProfileID: UUID? = nil) {
        if let accountProfileID {
            activeAccountProfileID = accountProfileID
            persistActiveAccountProfileID(accountProfileID)
        }
        persistedLocalSessionAccountID = SecureAccountStore.persistedSessionAccountID()
        accountAccessStatus = .checking
        isReauthenticationPresented = false
        authenticationNotice = nil
        authenticationRevision += 1
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

    func beginAutomaticCloudRecovery(accountID: UUID) -> Bool {
        automaticCloudRecoveryAccountIDs.insert(accountID).inserted
    }

    func finishAutomaticCloudRecovery(accountID: UUID) {
        automaticCloudRecoveryAccountIDs.remove(accountID)
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

    var id: String { rawValue }
}
