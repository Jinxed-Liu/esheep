import Foundation
import Observation
import Supabase
import SwiftData

struct CloudCollaborationStartupPreparation: Sendable {
    let errorMessages: [String]
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

/// Runtime collaboration state after the old provider retirement. Historical
/// class name is retained to avoid a broad, unrelated environment migration;
/// every remote path in this implementation is Supabase-only.
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
    private var syncWakeObserver: NSObjectProtocol?
    private var pendingSyncWakeFarmIDs = Set<UUID>()
    private var syncWakeDebounceTask: Task<Void, Never>?
    private var isSyncWakeDrainRunning = false
    private var supabaseCursorPollTask: Task<Void, Never>?
    private var supabaseRealtimeTasks: [UUID: Task<Void, Never>] = [:]
    private var supabaseAccessibleFarmDiscoveryAccountIDs = Set<UUID>()
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
        photoDataLoadTasks.values.forEach { $0.cancel() }
    }

    func supabaseRealtimeHealth(farmID: UUID) -> SupabaseRealtimeHealth {
        supabaseRealtimeHealthByFarmID[farmID] ?? .notActive
    }

    /// Returns verified local bytes and uses Supabase only when the local cache
    /// is missing. A retired-provider marker fails closed and can never download.
    func loadPhotoData(assetID: UUID) async throws -> Data {
        if let existing = photoDataLoadTasks[assetID] {
            return try await existing.value
        }
        let task = Task<Data, any Error> {
            [photoTransfers, supabasePhotoTransfers] in
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
            await self?.synchronizeSupabaseFarms()
        }
    }

    func resumeSupabaseSynchronization() async {
        startSupabaseCursorPollingIfNeeded()
        refreshSupabaseRealtimeSubscriptions()
        await synchronizeSupabaseFarms()
    }

    func synchronizeNow() async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        lastErrorMessage = nil
        defer { isSynchronizing = false }
        await synchronizeSupabaseFarms()
    }

    func discoverAndRestoreOwnerFarms(accountID: UUID) async {
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
                    guard route.deliveryProvider == .supabase else { continue }
                    guard !DevelopmentSupabaseNetworkGate.isForcedOffline else {
                        continue
                    }
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
        guard remoteSync != nil else { return }
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
                await self?.synchronizeSupabaseFarms()
            }
        }
    }

    private func refreshSupabaseRealtimeSubscriptions() {
        guard let supabaseTransport else { return }
        let context = ModelContext(modelContainer)
        let activeFarmIDs = Set(
            ((try? context.fetch(FetchDescriptor<FarmRemoteBinding>())) ?? [])
                .filter { $0.provider == .supabase && $0.state == .active }
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

    private func synchronizeSupabaseFarms() async {
        guard let remoteSync,
              !DevelopmentSupabaseNetworkGate.isForcedOffline else {
            return
        }
        let context = ModelContext(modelContainer)
        let farmIDs = (try? context.fetch(FetchDescriptor<FarmRemoteBinding>()))?
            .filter { $0.provider == .supabase && $0.state == .active }
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
