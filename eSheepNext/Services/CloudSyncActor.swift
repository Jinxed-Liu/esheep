import Foundation
import Observation
import Supabase
import SwiftData

struct CloudCollaborationStartupPreparation: Sendable {
    let errorMessages: [String]
}

enum ESheepCloudRuntimeError: LocalizedError {
    case unavailable
    case accountMismatch
    case offline

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "eSheep+ 云暂时不可用，请稍后再试。"
        case .accountMismatch:
            "当前登录账号与这座牧场不一致，请重新登录。"
        case .offline:
            "当前处于离线状态，联网后会自动继续保存。"
        }
    }
}

enum SupabaseRealtimeHealth: Sendable, Equatable {
    case notActive
    case connecting
    case realtimeHealthy
    case cursorFallback(errorCode: String)

    var displayTitle: String {
        switch self {
        case .notActive: "未启用"
        case .connecting: "正在连接"
        case .realtimeHealthy: "Realtime 正常"
        case .cursorFallback: "Cursor 补拉"
        }
    }

    var errorCode: String? {
        guard case .cursorFallback(let value) = self else { return nil }
        return value
    }
}

enum DevelopmentSupabaseRealtimeGate {
    static let disabledKey = "development.supabase.realtimeDisabled"

    static var isDisabled: Bool {
        #if DEBUG
        Bundle.main.bundleIdentifier == "com.sheepfarm.next.dev" &&
            UserDefaults.standard.bool(forKey: disabledKey)
        #else
        false
        #endif
    }
}

enum DevelopmentSupabaseNetworkGate {
    static let forcedOfflineKey = "development.supabase.forcedOffline"

    static var isForcedOffline: Bool {
        #if DEBUG
        isForcedOffline(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            flag: UserDefaults.standard.bool(forKey: forcedOfflineKey)
        )
        #else
        false
        #endif
    }

    static func isForcedOffline(
        bundleIdentifier: String?,
        flag: Bool
    ) -> Bool {
        bundleIdentifier == "com.sheepfarm.next.dev" && flag
    }
}

/// App-level composition root for cloud work. The historical class name is
/// retained to avoid an unrelated environment migration. Current
/// `eSheepCloud` farms are always delegated to `ESheepCloudCore`; the V1
/// coordinator remains reachable only for persisted `.supabase` farms that
/// have not completed the audited V1 -> V2 cutover.
@MainActor
@Observable
final class CloudCollaborationStore {
    var isSynchronizing = false
    var lastSuccessfulSyncAt: Date?
    var lastErrorMessage: String?
    var workerHealth: WorkerHealthResponse?
    private(set) var supabaseRealtimeHealthByFarmID: [UUID: SupabaseRealtimeHealth] = [:]

    let photoTransfers: PhotoTransferActor
    let conflicts: ConflictResolutionActor
    let remoteSync: FarmRemoteSyncCoordinator?
    let supabaseTransport: SupabaseFarmTransport?
    let supabasePhotoTransfers: SupabasePhotoTransferCoordinator?

    private let modelContainer: ModelContainer
    private let eSheepCloudGateway: (any ESheepCloudGateway)?
    private let eSheepCloudAssetTransport: (any ESheepCloudAssetTransferTransport)?
    private let eSheepCloudAssetCoordinator: ESheepCloudAssetCoordinator?
    private let eSheepCloudMembershipGateway: (any ESheepCloudMembershipGateway)?
    private var eSheepCloudCoresByFarmID: [UUID: ESheepCloudCore] = [:]
    private var eSheepCloudCoreAccountIDsByFarmID: [UUID: UUID] = [:]
    private var eSheepCloudViewStatesByFarmID: [UUID: ESheepCloudViewState] = [:]
    private var eSheepCloudInitialSyncTasks: [
        UUID: Task<ESheepCloudInitialSyncReport, any Error>
    ] = [:]
    private var syncWakeObserver: NSObjectProtocol?
    private var pendingSyncWakeFarmIDs = Set<UUID>()
    private var syncWakeDebounceTask: Task<Void, Never>?
    private var isSyncWakeDrainRunning = false
    private var supabaseCursorPollTask: Task<Void, Never>?
    private var supabaseRealtimeTasks: [UUID: Task<Void, Never>] = [:]
    private var supabaseAccessibleFarmDiscoveryAccountIDs = Set<UUID>()
    private var eSheepCloudFarmDiscoveryAccountIDs = Set<UUID>()
    private var photoDataLoadTasks: [UUID: Task<Data, any Error>] = [:]

    nonisolated static func prepareStartup(
        container: ModelContainer
    ) -> CloudCollaborationStartupPreparation {
        var startupErrorMessages: [String] = []
        do {
            _ = try PhotoAssetProjectionRepair.repair(container: container)
        } catch {
            startupErrorMessages.append(
                "照片本地投影修复失败：\(error.localizedDescription)"
            )
        }
        do {
            _ = try PostRecoveryHistoryProjectionRepair.repair(container: container)
        } catch {
            startupErrorMessages.append(
                "增量历史投影修复失败：\(error.localizedDescription)"
            )
        }
        do {
            _ = try RemoteProjectionReceiptRepair.repair(container: container)
        } catch {
            startupErrorMessages.append(
                "云端操作投影自愈失败：\(error.localizedDescription)"
            )
        }
        return CloudCollaborationStartupPreparation(
            errorMessages: startupErrorMessages
        )
    }

    init(
        container: ModelContainer,
        startupPreparation: CloudCollaborationStartupPreparation? = nil
    ) {
        modelContainer = container
        photoTransfers = PhotoTransferActor(modelContainer: container)
        conflicts = ConflictResolutionActor(container: container)
        if let client = AccountIdentityClients.supabaseClient {
            let gateway = ESheepCloudInfrastructureGateway(client: client)
            eSheepCloudGateway = gateway
            eSheepCloudAssetTransport = gateway
            eSheepCloudAssetCoordinator = ESheepCloudAssetCoordinator(
                container: container,
                gateway: gateway,
                transport: gateway
            )
            eSheepCloudMembershipGateway = ESheepCloudMembershipInfrastructureGateway(
                client: client
            )
            let transport = SupabaseFarmTransport(client: client)
            supabaseTransport = transport
            remoteSync = FarmRemoteSyncCoordinator(
                container: container,
                transport: transport
            )
            supabasePhotoTransfers = SupabasePhotoTransferCoordinator(
                container: container,
                client: client,
                localPhotos: photoTransfers
            )
        } else {
            eSheepCloudGateway = nil
            eSheepCloudAssetTransport = nil
            eSheepCloudAssetCoordinator = nil
            eSheepCloudMembershipGateway = nil
            supabaseTransport = nil
            remoteSync = nil
            supabasePhotoTransfers = nil
        }

        let preparation = startupPreparation ?? Self.prepareStartup(
            container: container
        )
        if !preparation.errorMessages.isEmpty {
            lastErrorMessage = preparation.errorMessages.joined(separator: "\n")
        }
        installRuntimeObservers()
        startSupabaseCursorPollingIfNeeded()
        if AccountIdentityClients.supabaseClient != nil {
            Task { @MainActor [weak self] in
                await self?.resumeESheepCloudInitialSyncSessions()
                await self?.resumeSupabaseAuthorityTransitions()
            }
        }
    }

    isolated deinit {
        if let syncWakeObserver {
            NotificationCenter.default.removeObserver(syncWakeObserver)
        }
        syncWakeDebounceTask?.cancel()
        supabaseCursorPollTask?.cancel()
        supabaseRealtimeTasks.values.forEach { $0.cancel() }
        eSheepCloudInitialSyncTasks.values.forEach { $0.cancel() }
        photoDataLoadTasks.values.forEach { $0.cancel() }
    }

    func supabaseRealtimeHealth(farmID: UUID) -> SupabaseRealtimeHealth {
        supabaseRealtimeHealthByFarmID[farmID] ?? .notActive
    }

    var isESheepCloudAvailable: Bool {
        eSheepCloudGateway != nil && eSheepCloudMembershipGateway != nil
    }

    /// Stable observable state owned by the V2 engine for one farm. Creating
    /// this value never starts networking and never falls back to V1.
    func eSheepCloudViewState(farmID: UUID) -> ESheepCloudViewState {
        if let existing = eSheepCloudViewStatesByFarmID[farmID] {
            return existing
        }
        let value = ESheepCloudViewState()
        eSheepCloudViewStatesByFarmID[farmID] = value
        return value
    }

    func eSheepCloudMembers(farmID: UUID) async throws -> [ESheepCloudMemberV2] {
        guard let eSheepCloudMembershipGateway else {
            throw ESheepCloudRuntimeError.unavailable
        }
        return try await eSheepCloudMembershipGateway.members(farmID: farmID)
    }

    func createESheepCloudInvitation(
        farmID: UUID,
        role: FarmRole
    ) async throws -> ESheepCloudInvitationV2 {
        guard let eSheepCloudMembershipGateway else {
            throw ESheepCloudRuntimeError.unavailable
        }
        return try await eSheepCloudMembershipGateway.createInvitation(
            farmID: farmID,
            role: role
        )
    }

    func revokeESheepCloudMember(
        farmID: UUID,
        memberID: UUID
    ) async throws {
        guard let eSheepCloudMembershipGateway else {
            throw ESheepCloudRuntimeError.unavailable
        }
        try await eSheepCloudMembershipGateway.revokeMember(
            farmID: farmID,
            memberID: memberID
        )
    }

    func redeemAndReceiveESheepCloudFarm(code: String) async throws -> FarmRecord {
        guard let eSheepCloudMembershipGateway else {
            throw ESheepCloudRuntimeError.unavailable
        }
        let redemption = try await eSheepCloudMembershipGateway.redeemInvitation(
            code: code
        )
        try persistInitialSyncAdmission(
            farmID: redemption.farmID,
            farmGeneration: redemption.farmGeneration
        )
        _ = try await receiveESheepCloudFarm(
            farmID: redemption.farmID,
            expectedFarmGeneration: redemption.farmGeneration
        )
        let context = ModelContext(modelContainer)
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == redemption.farmID }) else {
            throw ESheepCloudInitialSyncError.manifestMismatch
        }
        return farm
    }

    func synchronizeESheepCloudFarm(
        farmID: UUID,
        accountID: UUID
    ) async throws -> ESheepCloudSyncCycleReport {
        guard !DevelopmentSupabaseNetworkGate.isForcedOffline else {
            throw ESheepCloudRuntimeError.offline
        }
        let core = try eSheepCloudCore(farmID: farmID, accountID: accountID)
        let report = try await core.synchronize()
        lastSuccessfulSyncAt = report.safelySavedAt ?? .now
        return report
    }

    /// Runs the read-only half of the V1 -> V2 migration.  This deliberately
    /// never calls a cloud write RPC: it creates a verified local backup and a
    /// durable mapping plan, then places the legacy route behind the
    /// read-only barrier.  The server-side parity check and authority cutover
    /// remain separate, explicitly authorized operations.
    func prepareESheepCloudMigration(
        farmID: UUID,
        accountID: UUID
    ) async throws -> ESheepCloudMigrationPreparationReportV2 {
        let context = ModelContext(modelContainer)
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == farmID }),
              farm.ownerAccountID == accountID else {
            throw ESheepCloudMigrationError.accountMismatch
        }
        if let persistedAccountID = SecureAccountStore.persistedSessionAccountID(),
           persistedAccountID != accountID {
            throw ESheepCloudMigrationError.accountMismatch
        }
        guard let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: { $0.farmID == farmID }),
              profile.mode == .supabase else {
            throw ESheepCloudMigrationError.sourceIsNotLegacyCloud
        }

        // Resolve the account-scoped device identity before taking the backup;
        // this ensures any migrated operation has a stable actor identity while
        // still keeping this method entirely local/read-only with respect to
        // the remote service.
        let identity = try await DeviceIdentityActor.shared.identity()
        let coordinator = ESheepCloudMigrationCoordinator(container: modelContainer)
        return try await coordinator.prepareV1Migration(
            farmID: farmID,
            targetFarmGeneration: profile.authorityGeneration + 1,
            fallbackDeviceID: identity.deviceID
        )
    }

    func resolveESheepCloudAttention(
        id: UUID,
        farmID: UUID,
        accountID: UUID,
        choice: ESheepCloudAttentionResolutionChoiceV2
    ) async throws {
        guard !DevelopmentSupabaseNetworkGate.isForcedOffline else {
            throw ESheepCloudRuntimeError.offline
        }
        let core = try eSheepCloudCore(farmID: farmID, accountID: accountID)
        let report = try await core.resolveAttention(id: id, choice: choice)
        lastSuccessfulSyncAt = report.safelySavedAt ?? .now
    }

    /// Receives a new-install farm into an isolated verification store and
    /// exposes it to the app only after snapshot, event and relationship
    /// checks have all passed in one activation save.
    func receiveESheepCloudFarm(
        farmID: UUID,
        expectedFarmGeneration: Int? = nil
    ) async throws -> ESheepCloudInitialSyncReport {
        guard !DevelopmentSupabaseNetworkGate.isForcedOffline else {
            throw ESheepCloudRuntimeError.offline
        }
        guard let eSheepCloudGateway else {
            throw ESheepCloudRuntimeError.unavailable
        }
        if let existing = eSheepCloudInitialSyncTasks[farmID] {
            return try await existing.value
        }
        let task = Task<ESheepCloudInitialSyncReport, any Error> {
            let coordinator = await ESheepCloudInitialSyncCoordinator(
                farmID: farmID,
                container: modelContainer,
                gateway: eSheepCloudGateway
            )
            return try await coordinator.prepareNewInstallation(
                expectedFarmGeneration: expectedFarmGeneration
            )
        }
        eSheepCloudInitialSyncTasks[farmID] = task
        defer { eSheepCloudInitialSyncTasks.removeValue(forKey: farmID) }
        let report = try await task.value
        eSheepCloudCoresByFarmID.removeValue(forKey: farmID)
        eSheepCloudCoreAccountIDsByFarmID.removeValue(forKey: farmID)
        eSheepCloudViewStatesByFarmID.removeValue(forKey: farmID)
        lastSuccessfulSyncAt = .now
        CloudRuntimeNotification.postSyncWake(farmID: farmID)
        return report
    }

    /// Returns verified local bytes and uses Supabase only when the local cache
    /// is missing. A retired-provider marker fails closed and can never download.
    func loadPhotoData(assetID: UUID) async throws -> Data {
        if let existing = photoDataLoadTasks[assetID] {
            return try await existing.value
        }
        let task = Task<Data, any Error> {
            [photoTransfers, supabasePhotoTransfers, eSheepCloudAssetCoordinator] in
            do {
                return try await photoTransfers.localFileData(assetID: assetID)
            } catch {
                let localFailure = error
                guard let provider = try await photoTransfers.deliveryProvider(
                    assetID: assetID
                ) else {
                    throw localFailure
                }
                switch provider {
                case .eSheepCloud:
                    guard let eSheepCloudAssetCoordinator else {
                        throw PhotoTransferError.remoteProviderUnavailable
                    }
                    try await eSheepCloudAssetCoordinator.downloadOriginalIfNeeded(
                        assetID: assetID
                    )
                case .supabase:
                    guard let supabasePhotoTransfers else {
                        throw PhotoTransferError.remoteProviderUnavailable
                    }
                    try await supabasePhotoTransfers.downloadIfNeeded(
                        assetID: assetID
                    )
                case .retiredAppleCloud:
                    throw PhotoTransferError.remoteProviderUnavailable
                }
                return try await photoTransfers.localFileData(assetID: assetID)
            }
        }
        photoDataLoadTasks[assetID] = task
        do {
            let data = try await task.value
            photoDataLoadTasks[assetID] = nil
            return data
        } catch {
            photoDataLoadTasks[assetID] = nil
            throw error
        }
    }

    func refreshSupabaseRealtimeAcceptanceMode() {
        startSupabaseCursorPollingIfNeeded()
        refreshSupabaseRealtimeSubscriptions()
        Task { @MainActor [weak self] in
            await self?.synchronizeRemoteFarms()
        }
    }

    func resumeSupabaseSynchronization() async {
        startSupabaseCursorPollingIfNeeded()
        refreshSupabaseRealtimeSubscriptions()
        await synchronizeRemoteFarms()
    }

    func synchronizeNow() async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        lastErrorMessage = nil
        defer { isSynchronizing = false }
        await synchronizeRemoteFarms()
    }

    func discoverAndRestoreOwnerFarms(accountID: UUID) async {
        await discoverAndReceiveESheepCloudFarms(accountID: accountID)
        guard let client = AccountIdentityClients.supabaseClient else { return }
        await discoverAndRestoreSupabaseAccessibleFarms(
            accountID: accountID,
            client: client
        )
    }

    /// Kept for the settings health screen; it no longer probes any Apple cloud
    /// account or starts a retired-provider synchronization engine.
    func refreshAccountAvailability() async {
        if IdentityWorkerConfiguration.baseURL != nil {
            workerHealth = try? await IdentityWorkerClient.shared.health()
        }
    }

    private func installRuntimeObservers() {
        syncWakeObserver = NotificationCenter.default.addObserver(
            forName: CloudRuntimeNotification.syncWake,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let farmID = CloudRuntimeNotification.farmID(
                from: notification
            ) else { return }
            Task { @MainActor [weak self] in
                self?.scheduleSyncWake(farmID: farmID)
            }
        }
    }

    private func scheduleSyncWake(farmID: UUID) {
        pendingSyncWakeFarmIDs.insert(farmID)
        guard !isSyncWakeDrainRunning else { return }
        syncWakeDebounceTask?.cancel()
        syncWakeDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            await self?.drainSyncWakes()
        }
    }

    private func drainSyncWakes() async {
        guard !isSyncWakeDrainRunning else { return }
        isSyncWakeDrainRunning = true
        defer {
            isSyncWakeDrainRunning = false
            if let farmID = pendingSyncWakeFarmIDs.first {
                scheduleSyncWake(farmID: farmID)
            }
        }
        while !pendingSyncWakeFarmIDs.isEmpty {
            let farmIDs = pendingSyncWakeFarmIDs
            pendingSyncWakeFarmIDs.removeAll()
            for farmID in farmIDs {
                do {
                    let route = try FarmStorageRouter.route(
                        farmID: farmID,
                        context: ModelContext(modelContainer)
                    )
                    guard route.transitionState == .idle else {
                        continue
                    }
                    guard !DevelopmentSupabaseNetworkGate.isForcedOffline else {
                        continue
                    }
                    switch route.deliveryProvider {
                    case .eSheepCloud:
                        guard let accountID = activeESheepCloudAccountID() else {
                            throw ESheepCloudRuntimeError.accountMismatch
                        }
                        _ = try await synchronizeESheepCloudFarm(
                            farmID: farmID,
                            accountID: accountID
                        )
                    case .supabase:
                        guard let remoteSync else {
                            throw AccountIdentityClientError.notConfigured
                        }
                        var result: FarmRemoteSyncResult
                        repeat {
                            result = try await remoteSync.synchronize(
                                farmID: farmID,
                                maxOutboxItems: 25
                            )
                        } while result.uploadedOperationCount == 25
                        await supabasePhotoTransfers?.processPendingTransfers()
                        lastSuccessfulSyncAt = .now
                    case .retiredAppleCloud, nil:
                        continue
                    }
                } catch is CancellationError {
                    pendingSyncWakeFarmIDs.insert(farmID)
                    return
                } catch {
                    lastErrorMessage = error.localizedDescription
                    recordSupabaseSyncError(error, farmID: farmID)
                }
            }
        }
    }

    private func startSupabaseCursorPollingIfNeeded() {
        guard remoteSync != nil || eSheepCloudGateway != nil else { return }
        if let supabaseCursorPollTask, !supabaseCursorPollTask.isCancelled {
            return
        }
        refreshSupabaseRealtimeSubscriptions()
        supabaseCursorPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                self?.refreshSupabaseRealtimeSubscriptions()
                await self?.synchronizeRemoteFarms()
            }
        }
    }

    private func refreshSupabaseRealtimeSubscriptions() {
        guard let supabaseTransport else { return }
        let context = ModelContext(modelContainer)
        let idleFarmIDs = Set(
            ((try? context.fetch(FetchDescriptor<FarmStorageProfile>())) ?? [])
                .filter { $0.mode == .supabase && $0.transitionState == .idle }
                .map(\.farmID)
        )
        let activeFarmIDs = Set(
            ((try? context.fetch(FetchDescriptor<FarmRemoteBinding>())) ?? [])
                .filter {
                    $0.provider == .supabase && $0.state == .active &&
                        idleFarmIDs.contains($0.farmID)
                }
                .map(\.farmID)
        )
        if DevelopmentSupabaseNetworkGate.isForcedOffline ||
            DevelopmentSupabaseRealtimeGate.isDisabled {
            supabaseRealtimeTasks.values.forEach { $0.cancel() }
            supabaseRealtimeTasks.removeAll()
            for farmID in activeFarmIDs {
                supabaseRealtimeHealthByFarmID[farmID] = .cursorFallback(
                    errorCode: DevelopmentSupabaseNetworkGate.isForcedOffline
                        ? "developmentForcedOffline"
                        : "developmentDisabled"
                )
            }
            return
        }

        let staleFarmIDs = supabaseRealtimeTasks.keys.filter {
            !activeFarmIDs.contains($0)
        }
        for farmID in staleFarmIDs {
            supabaseRealtimeTasks[farmID]?.cancel()
            supabaseRealtimeTasks.removeValue(forKey: farmID)
            supabaseRealtimeHealthByFarmID.removeValue(forKey: farmID)
        }
        for farmID in activeFarmIDs where supabaseRealtimeTasks[farmID] == nil {
            supabaseRealtimeHealthByFarmID[farmID] = .connecting
            supabaseRealtimeTasks[farmID] = Task { @MainActor [weak self] in
                do {
                    for try await notification in await supabaseTransport
                        .revisionNotifications(farmID: farmID) {
                        guard !Task.isCancelled else { return }
                        switch notification {
                        case .subscribed:
                            self?.supabaseRealtimeHealthByFarmID[farmID] =
                                .realtimeHealthy
                        case .revision:
                            self?.supabaseRealtimeHealthByFarmID[farmID] =
                                .realtimeHealthy
                            self?.scheduleSyncWake(farmID: farmID)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self?.supabaseRealtimeHealthByFarmID[farmID] =
                        .cursorFallback(errorCode: "streamEnded")
                } catch is CancellationError {
                    return
                } catch {
                    self?.supabaseRealtimeHealthByFarmID[farmID] =
                        .cursorFallback(
                            errorCode: Self.supabaseRealtimeErrorCode(error)
                        )
                }
                self?.supabaseRealtimeTasks.removeValue(forKey: farmID)
            }
        }
    }

    private static func supabaseRealtimeErrorCode(_ error: Error) -> String {
        let value = error as NSError
        return "\(String(describing: type(of: error))):\(value.code)"
    }

    private func synchronizeRemoteFarms() async {
        guard !DevelopmentSupabaseNetworkGate.isForcedOffline else {
            return
        }
        await synchronizeESheepCloudFarms()
        await synchronizeLegacySupabaseFarms()
    }

    private func synchronizeESheepCloudFarms() async {
        guard eSheepCloudGateway != nil,
              let accountID = activeESheepCloudAccountID() else {
            return
        }
        let context = ModelContext(modelContainer)
        let profiles = (try? context.fetch(FetchDescriptor<FarmStorageProfile>())) ?? []
        let bindings = (try? context.fetch(FetchDescriptor<FarmRemoteBinding>())) ?? []
        let states = (try? context.fetch(FetchDescriptor<ESheepCloudFarmState>())) ?? []
        let boundFarmIDs = Set(bindings.compactMap { binding -> UUID? in
            guard binding.provider == .eSheepCloud,
                  binding.state == .active || binding.state == .readOnly else {
                return nil
            }
            return binding.farmID
        })
        let stateFarmIDs = Set(states.compactMap { state -> UUID? in
            guard state.activityState != .accessRevoked else { return nil }
            return state.farmID
        })
        let farmIDs = profiles.compactMap { profile -> UUID? in
            guard profile.mode == .eSheepCloud,
                  profile.transitionState == .idle,
                  boundFarmIDs.contains(profile.farmID),
                  stateFarmIDs.contains(profile.farmID) else {
                return nil
            }
            return profile.farmID
        }
        for farmID in farmIDs {
            do {
                _ = try await synchronizeESheepCloudFarm(
                    farmID: farmID,
                    accountID: accountID
                )
            } catch is CancellationError {
                return
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func synchronizeLegacySupabaseFarms() async {
        guard let remoteSync else { return }
        let context = ModelContext(modelContainer)
        let idleFarmIDs = Set(
            ((try? context.fetch(FetchDescriptor<FarmStorageProfile>())) ?? [])
                .filter { $0.mode == .supabase && $0.transitionState == .idle }
                .map(\.farmID)
        )
        let farmIDs = (try? context.fetch(FetchDescriptor<FarmRemoteBinding>()))?
            .filter {
                $0.provider == .supabase && $0.state == .active &&
                    idleFarmIDs.contains($0.farmID)
            }
            .map(\.farmID) ?? []
        for farmID in farmIDs {
            do {
                _ = try await remoteSync.synchronize(
                    farmID: farmID,
                    maxOutboxItems: 25
                )
                lastSuccessfulSyncAt = .now
            } catch is CancellationError {
                return
            } catch {
                lastErrorMessage = error.localizedDescription
                recordSupabaseSyncError(error, farmID: farmID)
            }
        }
        await supabasePhotoTransfers?.processPendingTransfers()
        await optimizeVerifiedSupabaseCachesIfPossible()
    }

    private func eSheepCloudCore(
        farmID: UUID,
        accountID: UUID
    ) throws -> ESheepCloudCore {
        guard let gateway = eSheepCloudGateway else {
            throw ESheepCloudRuntimeError.unavailable
        }
        if let existingAccountID = eSheepCloudCoreAccountIDsByFarmID[farmID] {
            if existingAccountID == accountID,
               let existing = eSheepCloudCoresByFarmID[farmID] {
                return existing
            }
            // A core never crosses account scope. It has no background task of
            // its own, so dropping the reference is sufficient; the next
            // authenticated account receives a fresh engine and view state.
            eSheepCloudCoresByFarmID.removeValue(forKey: farmID)
            eSheepCloudCoreAccountIDsByFarmID.removeValue(forKey: farmID)
            eSheepCloudViewStatesByFarmID.removeValue(forKey: farmID)
        }
        let core = ESheepCloudCore(
            farmID: farmID,
            accountID: accountID,
            container: modelContainer,
            gateway: gateway,
            assetTransport: eSheepCloudAssetTransport,
            viewState: eSheepCloudViewState(farmID: farmID)
        )
        eSheepCloudCoreAccountIDsByFarmID[farmID] = accountID
        eSheepCloudCoresByFarmID[farmID] = core
        return core
    }

    private func activeESheepCloudAccountID() -> UUID? {
        guard let accountID = SecureAccountStore.persistedSessionAccountID() else {
            return nil
        }
        let context = ModelContext(modelContainer)
        return try? context.fetch(FetchDescriptor<AccountProfile>())
            .first(where: { $0.effectiveAccountID == accountID })?
            .effectiveAccountID
    }

    private func recordSupabaseSyncError(_ error: Error, farmID: UUID) {
        let context = ModelContext(modelContainer)
        guard let binding = try? context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .first(where: {
                $0.farmID == farmID && $0.provider == .supabase
            }) else {
            return
        }
        let value = error as NSError
        binding.lastErrorCode =
            "\(String(describing: type(of: error))):\(value.code):" +
            String(error.localizedDescription.prefix(320))
        binding.updatedAt = .now
        try? context.save()
    }

    private func optimizeVerifiedSupabaseCachesIfPossible() async {
        let context = ModelContext(modelContainer)
        let profiles = (try? context.fetch(
            FetchDescriptor<FarmStorageProfile>()
        )) ?? []
        let activeFarmIDs = Set(profiles.compactMap { profile -> UUID? in
            guard profile.mode == .supabase,
                  profile.transitionState == .idle else {
                return nil
            }
            return profile.farmID
        })
        let migrations = (try? context.fetch(
            FetchDescriptor<FarmBaselineMigrationRecord>()
        )) ?? []
        for migration in migrations where
            activeFarmIDs.contains(migration.farmID) &&
            migration.checkpointID != nil {
            _ = try? await LocalStorageOptimizationService()
                .optimizeAfterVerifiedSupabaseActivation(
                    farmID: migration.farmID,
                    migrationID: migration.migrationID,
                    context: context
                )
        }
    }

    private func resumeESheepCloudInitialSyncSessions() async {
        guard eSheepCloudGateway != nil,
              !DevelopmentSupabaseNetworkGate.isForcedOffline else {
            return
        }
        let context = ModelContext(modelContainer)
        let sessions = (try? context.fetch(
            FetchDescriptor<ESheepCloudInitialSyncSession>()
        )) ?? []
        var generationsByFarmID: [UUID: Int] = [:]
        for session in sessions where session.state != .active {
            // `paused` is a durable, resumable state (for example after a
            // cancelled task or a transport interruption).  It must be
            // retried on the next launch; otherwise a verified chunk ledger
            // can remain stranded forever with no UI action that resumes it.
            // A farm can have more than one historical paused snapshot.  The
            // coordinator will reuse the matching snapshot and safely create
            // a new session when the server has issued a newer manifest.
            // Prefer the highest generation so recovery never depends on the
            // undefined ordering of a SwiftData fetch.
            if let current = generationsByFarmID[session.farmID],
               current >= session.farmGeneration {
                continue
            }
            generationsByFarmID[session.farmID] = session.farmGeneration
        }
        for (farmID, generation) in generationsByFarmID {
            do {
                _ = try await receiveESheepCloudFarm(
                    farmID: farmID,
                    expectedFarmGeneration: generation
                )
            } catch is CancellationError {
                return
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// Reconstructs new-install admissions from the authoritative membership
    /// list. This closes the process-death window between invitation redemption
    /// and the first local initial-sync save without treating list data as a
    /// farm snapshot.
    private func discoverAndReceiveESheepCloudFarms(accountID: UUID) async {
        guard let eSheepCloudMembershipGateway,
              eSheepCloudFarmDiscoveryAccountIDs.insert(accountID).inserted,
              !DevelopmentSupabaseNetworkGate.isForcedOffline else {
            return
        }
        defer { eSheepCloudFarmDiscoveryAccountIDs.remove(accountID) }
        do {
            let accesses = try await eSheepCloudMembershipGateway.accessibleFarms()
            guard accesses.allSatisfy({ $0.memberAccountID == accountID }) else {
                throw ESheepCloudMembershipError.accountMismatch
            }
            try reconcileESheepCloudAccesses(accesses, accountID: accountID)
            for access in accesses where access.initialSyncReady {
                if try isActiveESheepCloudFarm(
                    farmID: access.farmID,
                    farmGeneration: access.farmGeneration,
                    accountID: accountID
                ) {
                    continue
                }
                try persistInitialSyncAdmission(
                    farmID: access.farmID,
                    farmGeneration: access.farmGeneration
                )
                do {
                    _ = try await receiveESheepCloudFarm(
                        farmID: access.farmID,
                        expectedFarmGeneration: access.farmGeneration
                    )
                } catch ESheepCloudInitialSyncError.existingFarmRequiresMigration {
                    // Existing V1 business data must enter through the audited
                    // migration path. Discovery is never allowed to overwrite it.
                    continue
                }
            }
        } catch is CancellationError {
            return
        } catch {
            lastErrorMessage = "eSheep+ 云牧场接收失败：\(error.localizedDescription)"
        }
    }

    private func isActiveESheepCloudFarm(
        farmID: UUID,
        farmGeneration: Int,
        accountID: UUID
    ) throws -> Bool {
        let context = ModelContext(modelContainer)
        let bindingIsActive = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .contains {
                $0.farmID == farmID &&
                    $0.provider == .eSheepCloud &&
                    $0.state == .active &&
                    $0.authorityGeneration == farmGeneration
            }
        let membershipIsActive = try context.fetch(
            FetchDescriptor<FarmMembershipBinding>()
        ).contains {
            $0.farmID == farmID &&
                $0.accountID == accountID &&
                $0.status == .active
        }
        return bindingIsActive && membershipIsActive
    }

    /// Absence from a successfully returned account-scoped list is an
    /// authoritative revocation. Network errors never enter this method, so
    /// an offline launch cannot hide or delete a local farm accidentally.
    private func reconcileESheepCloudAccesses(
        _ accesses: [ESheepCloudFarmAccessV2],
        accountID: UUID
    ) throws {
        let context = ModelContext(modelContainer)
        let byFarmID = Dictionary(uniqueKeysWithValues: accesses.map {
            ($0.farmID, $0)
        })
        let memberships = try context.fetch(FetchDescriptor<FarmMembershipBinding>())
            .filter { $0.accountID == accountID }
        let bindings = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .filter { $0.provider == .eSheepCloud }
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())

        for membership in memberships {
            guard bindings.contains(where: { $0.farmID == membership.farmID }) else {
                continue
            }
            if let access = byFarmID[membership.farmID] {
                membership.roleRawValue = access.role.rawValue
                membership.statusRawValue = FarmMembershipStatus.active.rawValue
                membership.updatedAt = .now
                if let farm = farms.first(where: { $0.id == access.farmID }) {
                    farm.roleRawValue = access.role.rawValue
                    farm.membershipStatusRawValue = FarmMembershipStatus.active.rawValue
                }
            } else {
                membership.statusRawValue = FarmMembershipStatus.revoked.rawValue
                membership.updatedAt = .now
                if let binding = bindings.first(where: {
                    $0.farmID == membership.farmID
                }) {
                    binding.stateRawValue = FarmRemoteBindingState.accessRevoked.rawValue
                    binding.updatedAt = .now
                }
                if let farm = farms.first(where: { $0.id == membership.farmID }) {
                    farm.membershipStatusRawValue = FarmMembershipStatus.revoked.rawValue
                }
            }
        }
        try context.save()
    }

    private func persistInitialSyncAdmission(
        farmID: UUID,
        farmGeneration: Int
    ) throws {
        let context = ModelContext(modelContainer)
        let existing = try context.fetch(
            FetchDescriptor<ESheepCloudInitialSyncSession>()
        ).contains {
            $0.farmID == farmID &&
                $0.farmGeneration == farmGeneration &&
                $0.state != .active
        }
        guard !existing else { return }
        let relativePath = "ESheepCloud/Staging/" +
            farmID.uuidString.lowercased() +
            "/pending/verification.store"
        context.insert(ESheepCloudInitialSyncSession(
            farmID: farmID,
            farmGeneration: farmGeneration,
            stagingGeneration: farmGeneration,
            stagingStoreRelativePath: relativePath
        ))
        try context.save()
    }

    private func resumeSupabaseAuthorityTransitions() async {
        guard let client = AccountIdentityClients.supabaseClient else { return }
        let context = ModelContext(modelContainer)
        if let accountID = try? context.fetch(FetchDescriptor<AccountProfile>())
            .first?.effectiveAccountID {
            await discoverAndRestoreSupabaseAccessibleFarms(
                accountID: accountID,
                client: client
            )
        }
        let profiles = (try? context.fetch(
            FetchDescriptor<FarmStorageProfile>()
        )) ?? []
        let pendingFarmIDs = Set(profiles.compactMap { profile -> UUID? in
            let targetsSupabase = profile.targetMode == .supabase ||
                (profile.mode == .supabase &&
                    [.drainingOperations, .archivingSource]
                        .contains(profile.transitionState))
            guard targetsSupabase, profile.transitionState != .idle else {
                return nil
            }
            return profile.farmID
        })
        let farms = (try? context.fetch(FetchDescriptor<FarmRecord>())) ?? []
        let service = SupabaseFarmActivationService(client: client)
        let locallyCompletedFarmIDs = Set(profiles.compactMap {
            profile -> UUID? in
            guard profile.mode == .supabase,
                  profile.transitionState == .idle else {
                return nil
            }
            return profile.farmID
        })
        for farm in farms where locallyCompletedFarmIDs.contains(farm.id) {
            do {
                if try await service.reconcileCompletedLocalActivation(
                    farm: farm,
                    context: context
                ) {
                    lastSuccessfulSyncAt = .now
                }
            } catch FarmRemoteTransportError.authorityTransitionMissing {
                // Farms created by another supported path may have no compact
                // transition receipt. That is not a synchronization failure.
            } catch {
                lastErrorMessage =
                    "eSheep 云迁移终态对账失败：\(error.localizedDescription)"
            }
        }
        for farm in farms where pendingFarmIDs.contains(farm.id) {
            do {
                _ = try await service.activate(farm: farm, context: context)
            } catch {
                lastErrorMessage =
                    "eSheep 云启用恢复失败：\(error.localizedDescription)"
            }
        }
        refreshSupabaseRealtimeSubscriptions()
    }

    private func discoverAndRestoreSupabaseAccessibleFarms(
        accountID: UUID,
        client: SupabaseClient
    ) async {
        guard supabaseAccessibleFarmDiscoveryAccountIDs
            .insert(accountID).inserted else {
            return
        }
        defer { supabaseAccessibleFarmDiscoveryAccountIDs.remove(accountID) }
        do {
            let context = ModelContext(modelContainer)
            _ = try await SupabaseOwnedFarmDiscoveryService(client: client)
                .discoverAndRestoreAccessibleFarms(
                    accountID: accountID,
                    context: context
                )
        } catch is CancellationError {
            return
        } catch {
            lastErrorMessage =
                "eSheep 云牧场发现失败：\(error.localizedDescription)"
        }
    }
}
