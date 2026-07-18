import CloudKit
import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

enum CloudAccountAvailability: Equatable, Sendable {
    case checking
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable(String)

    var displayName: String {
        switch self {
        case .checking: "正在检查"
        case .available: "iCloud 可用"
        case .noAccount: "未登录 iCloud"
        case .restricted: "iCloud 受系统限制"
        case .couldNotDetermine: "无法确定 iCloud 状态"
        case .temporarilyUnavailable: "iCloud 暂时不可用"
        }
    }
}

enum CloudSyncError: LocalizedError {
    case featureDisabled
    case accountUnavailable
    case farmBindingMissing
    case rootSaveFailed
    case shareSaveFailed
    case participantMissing
    case localBaselineUnsupported
    case developmentTestFarmRequired
    case formalFarmRequired
    case localOnlyMigration
    case ownerRequired
    case inactiveFarm

    var errorDescription: String? {
        switch self {
        case .featureDisabled: "当前构建未启用云端协作。"
        case .accountUnavailable: "当前 iCloud 账户不可用。"
        case .farmBindingMissing: "当前牧场尚未建立 CloudKit 绑定。"
        case .rootSaveFailed: "无法保存牧场云端根记录。"
        case .shareSaveFailed: "无法创建牧场共享记录。"
        case .participantMissing: "尚未发现已接受系统共享的新参与者。"
        case .localBaselineUnsupported: "该牧场包含旧格式本地操作，不能直接作为云端测试牧场。请新建空白测试牧场进行本阶段验收。"
        case .developmentTestFarmRequired: "当前牧场不是带固定 Development 标记的测试牧场。迁移和真实牧场只能保留在本机，不能创建 CloudKit Zone、上传或共享。"
        case .formalFarmRequired: "Staging 和 Production 只允许正式新建牧场使用云端协作，Development 测试牧场不能进入发行环境。"
        case .localOnlyMigration: "该牧场来自旧版正式迁移，已永久锁定为仅本机使用，不能上传或共享。"
        case .ownerRequired: "只有当前牧场的场主可以建立 CloudKit Zone 和共享。"
        case .inactiveFarm: "当前牧场已删除或成员关系无效，不能启用云端协作。"
        }
    }
}

private final class CloudSyncEngineDelegateProxy: CKSyncEngineDelegate, @unchecked Sendable {
    weak var owner: CloudSyncActor?

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await owner?.handleEvent(event, syncEngine: syncEngine)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await owner?.nextRecordZoneChangeBatch(context, syncEngine: syncEngine)
    }
}

actor CloudSyncActor {
    private let container: CKContainer
    private let persistence: FarmPersistenceActor
    private let deviceIdentity: DeviceIdentityActor
    private let mapper = CloudRecordMapper()
    private let delegateProxy: CloudSyncEngineDelegateProxy
    private var privateEngine: CKSyncEngine
    private var sharedEngine: CKSyncEngine

    init(containerIdentifier: String?, persistence: FarmPersistenceActor, deviceIdentity: DeviceIdentityActor = .shared) {
        let container: CKContainer
        if let containerIdentifier, !containerIdentifier.isEmpty {
            container = CKContainer(identifier: containerIdentifier)
        } else {
            container = .default()
        }
        self.container = container
        self.persistence = persistence
        self.deviceIdentity = deviceIdentity
        let proxy = CloudSyncEngineDelegateProxy()
        self.delegateProxy = proxy

        var privateConfiguration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: CloudEngineStateDiskStore.load(scope: .privateDatabase),
            delegate: proxy
        )
        privateConfiguration.automaticallySync = !CloudEngineStateDiskStore.wasCorrupted(scope: .privateDatabase)
        privateConfiguration.subscriptionID = "esheep-next-private"
        self.privateEngine = CKSyncEngine(privateConfiguration)

        var sharedConfiguration = CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase,
            stateSerialization: CloudEngineStateDiskStore.load(scope: .sharedDatabase),
            delegate: proxy
        )
        sharedConfiguration.automaticallySync = !CloudEngineStateDiskStore.wasCorrupted(scope: .sharedDatabase)
        sharedConfiguration.subscriptionID = "esheep-next-shared"
        self.sharedEngine = CKSyncEngine(sharedConfiguration)
        proxy.owner = self
    }

    func accountAvailability() async -> CloudAccountAvailability {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .couldNotDetermine
            case .temporarilyUnavailable: return .temporarilyUnavailable("CloudKit 报告账户暂时不可用。")
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return .temporarilyUnavailable(error.localizedDescription)
        }
    }

    func corruptedStateScopes() -> [CloudDatabaseScope] {
        [.privateDatabase, .sharedDatabase].filter { CloudEngineStateDiskStore.wasCorrupted(scope: $0) }
    }

    func prepareOwnerFarm(farmID: UUID, farmName: String, ownerAccountID: UUID) async throws -> CKShare {
        guard CloudFeatureConfiguration.isEnabled else { throw CloudSyncError.featureDisabled }
        try await persistence.requireCloudAdmission(farmID: farmID, environment: .current)
        guard await accountAvailability() == .available else { throw CloudSyncError.accountUnavailable }
        guard try await persistence.isCloudPreparationReady(farmID: farmID) else {
            throw CloudSyncError.localBaselineUnsupported
        }
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)
        let recoveryZoneID = CKRecordZone.ID(zoneName: CloudZoneName.recovery(for: farmID), ownerName: CKCurrentUserDefaultName)
        let recoveryZone = CKRecordZone(zoneID: recoveryZoneID)
        let zoneResult = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone, recoveryZone], deleting: [])
        _ = try zoneResult.saveResults[zoneID]?.get()
        _ = try zoneResult.saveResults[recoveryZoneID]?.get()

        let root = mapper.rootRecord(farmID: farmID, farmName: farmName, ownerAccountID: ownerAccountID, zoneID: zoneID)
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = farmName as CKRecordValue
        let result = try await container.privateCloudDatabase.modifyRecords(saving: [root, share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard (try result.saveResults[root.recordID]?.get()) != nil else { throw CloudSyncError.rootSaveFailed }
        guard let savedShare = try result.saveResults[share.recordID]?.get() as? CKShare else { throw CloudSyncError.shareSaveFailed }
        try await persistence.upsertBinding(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            scope: .privateDatabase,
            shareRecordName: savedShare.recordID.recordName,
            state: .active
        )
        return savedShare
    }

    func attachAcceptedShare(farmID: UUID, ownerAccountID: UUID, zoneID: CKRecordZone.ID, shareRecordName: String) async throws {
        try await persistence.upsertBinding(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            scope: .sharedDatabase,
            shareRecordName: shareRecordName,
            zoneOwnerName: zoneID.ownerName,
            state: .requiresAccountReview
        )
        try await persistence.stageAcceptedSharedFarm(farmID: farmID, temporaryOwnerAccountID: ownerAccountID)
    }

    func ownerShare(farmID: UUID) async throws -> CKShare {
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID),
              binding.databaseScope == .privateDatabase,
              let shareRecordName = binding.shareRecordName else {
            throw CloudSyncError.farmBindingMissing
        }
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: shareRecordName, zoneID: zoneID)
        guard let share = try await container.privateCloudDatabase.record(for: recordID) as? CKShare else {
            throw CloudSyncError.shareSaveFailed
        }
        return share
    }

    func acceptedParticipantRecordNames(farmID: UUID) async throws -> [String] {
        let share = try await ownerShare(farmID: farmID)
        return share.participants.compactMap { participant in
            guard participant.role != .owner,
                  participant.acceptanceStatus == .accepted else { return nil }
            return participant.userIdentity.userRecordID?.recordName
        }
    }

    func removeParticipant(farmID: UUID, participantRecordName: String) async throws {
        let share = try await ownerShare(farmID: farmID)
        guard let participant = share.participants.first(where: {
            $0.userIdentity.userRecordID?.recordName == participantRecordName && $0.role != .owner
        }) else { throw CloudSyncError.participantMissing }
        share.removeParticipant(participant)
        let result = try await container.privateCloudDatabase.modifyRecords(
            saving: [share],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        _ = try result.saveResults[share.recordID]?.get()
    }

    func leaveSharedFarm(farmID: UUID) async throws {
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID),
              binding.databaseScope == .sharedDatabase else {
            throw CloudSyncError.farmBindingMissing
        }
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        try await persistence.revokeSharedAccess(farmID: farmID)
    }

    func synchronizeNow() async throws {
        guard CloudFeatureConfiguration.isEnabled else { throw CloudSyncError.featureDisabled }
        let pending = try await persistence.pendingRecordIDs()
        let privateChanges = pending.filter { $0.1 == .privateDatabase }.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.0) }
        let sharedChanges = pending.filter { $0.1 == .sharedDatabase }.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.0) }
        if !privateChanges.isEmpty { privateEngine.state.add(pendingRecordZoneChanges: privateChanges) }
        if !sharedChanges.isEmpty { sharedEngine.state.add(pendingRecordZoneChanges: sharedChanges) }
        async let privateFetch: Void = privateEngine.fetchChanges()
        async let sharedFetch: Void = sharedEngine.fetchChanges()
        _ = try await (privateFetch, sharedFetch)
        async let privateSend: Void = privateEngine.sendChanges()
        async let sharedSend: Void = sharedEngine.sendChanges()
        _ = try await (privateSend, sharedSend)
    }

    func resetEngine(scope: CloudDatabaseScope) async throws {
        try CloudEngineStateDiskStore.remove(scope: scope)
        let database = scope == .privateDatabase ? container.privateCloudDatabase : container.sharedCloudDatabase
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: nil,
            delegate: delegateProxy
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = scope == .privateDatabase ? "esheep-next-private" : "esheep-next-shared"
        let engine = CKSyncEngine(configuration)
        if scope == .privateDatabase {
            privateEngine = engine
        } else {
            sharedEngine = engine
        }
        try await engine.fetchChanges()
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let scope = scope(for: syncEngine)
        do {
            switch event {
            case .stateUpdate(let update):
                try await persistence.saveEngineState(update.stateSerialization, scope: scope)
            case .fetchedRecordZoneChanges(let changes):
                try await persistence.ingest(changes.modifications.map(\.record), scope: scope)
                try await persistence.recordUnexpectedDeletions(changes.deletions)
            case .sentRecordZoneChanges(let changes):
                try await persistence.confirmSavedRecords(changes.savedRecords, scope: scope)
                try await persistence.markFailedRecords(changes.failedRecordSaves)
            case .accountChange:
                try await persistence.lockAllCloudFarmsForAccountReview()
            default:
                break
            }
        } catch {
            try? await persistence.recordSecurityIncident(
                farmID: nil,
                type: "syncEventFailed",
                detail: "\(scope.rawValue): \(error.localizedDescription)"
            )
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = scope(for: syncEngine)
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [persistence, deviceIdentity] recordID in
            await persistence.record(for: recordID, scope: scope, device: deviceIdentity)
        }
    }

    private func scope(for engine: CKSyncEngine) -> CloudDatabaseScope {
        engine === privateEngine ? .privateDatabase : .sharedDatabase
    }
}

@MainActor
@Observable
final class CloudCollaborationStore {
    var accountAvailability: CloudAccountAvailability = .checking
    var isSynchronizing = false
    var lastSuccessfulSyncAt: Date?
    var lastErrorMessage: String?
    var isIdentityWriteLocked = false
    var workerHealth: WorkerHealthResponse?

    let persistence: FarmPersistenceActor
    let sync: CloudSyncActor
    let photoTransfers: PhotoTransferActor
    let checkpoints: FarmCheckpointActor
    let membershipSnapshots: MembershipSnapshotActor
    let conflicts: ConflictResolutionActor
    let rebuilds: CloudRebuildActor
    let testFarmGenerator: TestFarmGeneratorActor

    init(container: ModelContainer) {
        let persistence = FarmPersistenceActor(container: container)
        self.persistence = persistence
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String
        self.sync = CloudSyncActor(containerIdentifier: identifier, persistence: persistence)
        self.photoTransfers = PhotoTransferActor(modelContainer: container, containerIdentifier: identifier)
        self.checkpoints = FarmCheckpointActor(modelContainer: container, containerIdentifier: identifier)
        self.membershipSnapshots = MembershipSnapshotActor(modelContainer: container, persistence: persistence, containerIdentifier: identifier)
        self.conflicts = ConflictResolutionActor(container: container)
        self.rebuilds = CloudRebuildActor(modelContainer: container, persistence: persistence, containerIdentifier: identifier)
        self.testFarmGenerator = TestFarmGeneratorActor(modelContainer: container, photoTransfers: photoTransfers)
    }

    func refreshAccountAvailability() async {
        accountAvailability = await sync.accountAvailability()
        if IdentityWorkerConfiguration.baseURL != nil {
            workerHealth = try? await IdentityWorkerClient.shared.health()
        }
        let corruptedScopes = await sync.corruptedStateScopes()
        if !corruptedScopes.isEmpty {
            let names = corruptedScopes.map(\.rawValue).joined(separator: "、")
            lastErrorMessage = "检测到同步状态损坏（\(names)）。自动同步已暂停，请在云缓存重建中心完成 staging 重建。"
        }
    }

    func synchronizeNow() async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        lastErrorMessage = nil
        defer { isSynchronizing = false }
        do {
            await photoTransfers.processPendingTransfers()
            try await sync.synchronizeNow()
            await photoTransfers.processPendingTransfers()
            lastSuccessfulSyncAt = .now
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func maintainRecovery(farmID: UUID) async {
        do {
            if let reason = try await checkpoints.shouldCreateAutomaticCheckpoint(farmID: farmID) {
                _ = try await checkpoints.createCheckpoint(farmID: farmID, reason: reason)
            }
        } catch FarmCheckpointError.ownerBindingRequired {
            // Shared-database members do not own the private recovery zone.
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func captureDiagnostics(farmID: UUID) async {
        do {
            let health = workerHealth.map { "\($0.environment)/\($0.database)/\($0.version)" } ?? "not-configured"
            try await persistence.captureDiagnosticSnapshot(
                farmID: farmID,
                workerHealth: health,
                cloudAccount: accountAvailability.displayName
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func commitRebuild(sessionID: UUID) async throws -> CloudRebuildResult {
        let result = try await rebuilds.commit(sessionID: sessionID)
        guard let binding = try await persistence.bindingSnapshot(farmID: result.farmID) else {
            throw CloudSyncError.farmBindingMissing
        }
        do {
            try await sync.resetEngine(scope: binding.databaseScope)
            return result
        } catch {
            try? await persistence.setRebuildLock(
                farmID: result.farmID,
                enabled: true,
                errorCode: "engineResetFailed"
            )
            throw error
        }
    }

    func acceptShareNotification(_ notification: Notification, accountID: UUID) async {
        guard let userInfo = notification.userInfo,
              let zoneName = userInfo["zoneName"] as? String,
              let zoneOwnerName = userInfo["zoneOwnerName"] as? String,
              let shareRecordName = userInfo["shareRecordName"] as? String,
              let farmID = CloudZoneName.farmID(from: zoneName) else {
            lastErrorMessage = "系统共享信息不完整，无法建立本地牧场绑定。"
            return
        }
        do {
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
            try await sync.attachAcceptedShare(
                farmID: farmID,
                ownerAccountID: accountID,
                zoneID: zoneID,
                shareRecordName: shareRecordName
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func performIdentityMaintenance(accountID: UUID, farmIDs: [UUID]) async {
        guard IdentityWorkerConfiguration.baseURL != nil else { return }
        do {
            let status = try await IdentityWorkerClient.shared.accountStatus()
            guard status.accountID == accountID, status.status == "active" else {
                isIdentityWriteLocked = true
                lastErrorMessage = "身份服务账号与本机账号不一致，云端牧场已锁定写入。"
                return
            }
            isIdentityWriteLocked = false
            let membership = MembershipActor(persistence: persistence)
            let invite = InviteServiceActor(persistence: persistence)
            for farmID in farmIDs {
                _ = try await membership.refresh(farmID: farmID)
                _ = try await invite.refreshCapability(accountID: accountID, farmID: farmID)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}

final class CloudShareAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = FarmNotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        FarmSystemNavigationStore.enqueue(.init(
            farmID: route.farmID,
            kind: route.kind,
            entityID: route.entityID,
            query: nil
        ))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task {
            do {
                let container = CKContainer(identifier: cloudKitShareMetadata.containerIdentifier)
                let share = try await container.accept(cloudKitShareMetadata)
                let zoneID = share.recordID.zoneID
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .didAcceptFarmCloudShare,
                        object: nil,
                        userInfo: [
                            "zoneName": zoneID.zoneName,
                            "zoneOwnerName": zoneID.ownerName,
                            "shareRecordName": share.recordID.recordName,
                        ]
                    )
                }
            } catch {
                await MainActor.run {
                    NotificationCenter.default.post(name: .didFailToAcceptFarmCloudShare, object: error)
                }
            }
        }
    }
}

extension Notification.Name {
    static let didAcceptFarmCloudShare = Notification.Name("eSheepNext.didAcceptFarmCloudShare")
    static let didFailToAcceptFarmCloudShare = Notification.Name("eSheepNext.didFailToAcceptFarmCloudShare")
}
