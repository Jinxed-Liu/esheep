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
    var activeAccountProfileID: UUID?
    var selectedFarmID: UUID?
    var selectedTab: AppTab = .home
    var isCreateFarmPresented = false
    var lastSyncDescription = "本地记录待同步"
    var authenticationRevision = 0
    var authenticationNotice: String?
    var pendingRecordEntry: PendingRecordEntry?
    var pendingSearchQuery: String?
    var pendingSheepID: UUID?

    init() {
        activeAccountProfileID = SecureAccountStore.activeAccountProfileID()
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
            try? SecureAccountStore.saveActiveAccountProfileID(accountProfileID)
        }
        authenticationNotice = nil
        authenticationRevision += 1
    }

    func authenticationDidSignOut(warning: String? = nil) {
        selectedFarmID = nil
        selectedTab = .home
        authenticationNotice = warning ?? "已退出登录。本机牧场缓存仍保留并与其他账号隔离；重新登录同一账号后可继续使用。"
        authenticationRevision += 1
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
