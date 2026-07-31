import SwiftData
import SwiftUI

#if DEBUG
private enum DevelopmentLocalAccountRecoveryError: LocalizedError {
    case supabaseDevelopmentDisabled
    case farmNotFound
    case activeSheepCountMismatch(expected: Int, actual: Int)
    case ownerMembershipMismatch
    case privateBindingMismatch
    case validatedSnapshotMissing
    case ownerAlreadyBound

    var errorDescription: String? {
        switch self {
        case .supabaseDevelopmentDisabled:
            "只允许在已启用 Supabase 的 Development 构建中执行。"
        case .farmNotFound:
            "没有找到指定的本地牧场。"
        case .activeSheepCountMismatch(let expected, let actual):
            "在场羊只校验失败：预期 \(expected)，实际 \(actual)。"
        case .ownerMembershipMismatch:
            "当前账号与旧场主成员记录不一致。"
        case .privateBindingMismatch:
            "旧牧场的私有云绑定证据不一致。"
        case .validatedSnapshotMissing:
            "没有找到已经验证的场主成员快照。"
        case .ownerAlreadyBound:
            "旧场主账号已绑定到另一个本地账户。"
        }
    }
}
#endif

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Environment(SubscriptionService.self) private var subscription
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    @Query private var accounts: [AccountProfile]
    @Query(sort: \FarmRecord.updatedAt, order: .reverse) private var farms: [FarmRecord]
    @Query private var cloudBindings: [CloudFarmBinding]
    @Query private var remoteBindings: [FarmRemoteBinding]
    @Query private var remoteRestoreRecords: [FarmRemoteRestoreRecord]
    @Query private var membershipBindings: [FarmMembershipBinding]
    @Query private var migrationCommits: [MigrationCommitRecord]
    @Query(sort: \CloudRebuildSessionRecord.updatedAt, order: .reverse)
    private var cloudRebuildSessions: [CloudRebuildSessionRecord]
    @State private var systemSnapshotRevision = 0

    var body: some View {
        @Bindable var session = session

        Group {
            if let account = activeAccount, hasPersistedLocalAccount(for: account) {
                if let restore = pendingRemoteRestore {
                    SupabaseFarmRestoreProgressView(record: restore)
                } else if visibleFarms.isEmpty {
                    if pendingSharedFarmIDs.isEmpty {
                        FarmSetupView(account: account)
                    } else {
                        SharedFarmAdmissionProgressView()
                    }
                } else {
                    FarmWorkspaceView(
                        account: account,
                        farms: visibleFarms,
                        sharedFarmAdmissionStatus: sharedFarmAdmissionStatus
                    )
                }
            } else {
                WelcomeView(reauthenticationRequired: activeAccount != nil)
            }
        }
        .sheet(isPresented: $session.isCreateFarmPresented) {
            if let account = activeAccount {
                CreateFarmSheet(account: account)
            }
        }
        .sheet(isPresented: $session.isJoinFarmPresented) {
            if let account = activeAccount {
                JoinFarmView(account: account)
            }
        }
        .sheet(isPresented: $session.isReauthenticationPresented) {
            WelcomeView(reauthenticationRequired: true)
        }
        .task(id: visibleFarms.map(\.id)) {
            session.reconcileActiveFarm(with: visibleFarms)
            session.consumePendingNavigationRequest()
            session.consumeSystemNavigationTarget()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                preferences.refreshSystemPowerState()
                session.consumePendingNavigationRequest()
                session.consumeSystemNavigationTarget()
            } else if phase == .background {
                FarmBackgroundRefresh.schedule()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            preferences.refreshSystemPowerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudRuntimeNotification.syncWake)) { notification in
            guard let farmID = CloudRuntimeNotification.farmID(from: notification),
                  visibleFarms.contains(where: { $0.id == farmID }) else { return }
            systemSnapshotRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudRuntimeNotification.recoveryRequired)) { notification in
            guard let farmID = CloudRuntimeNotification.farmID(from: notification),
                  visibleFarms.contains(where: { $0.id == farmID }) else { return }
            systemSnapshotRevision &+= 1
        }
        .onOpenURL { url in
            if let invitation = PendingFarmInvitation(url: url) {
                session.pendingFarmInvitation = invitation
                session.isJoinFarmPresented = true
                return
            }
            guard let target = FarmSystemIntegrationService.target(from: url) else { return }
            FarmSystemNavigationStore.enqueue(target)
            session.consumeSystemNavigationTarget()
        }
        .task(id: systemSnapshotTaskID) {
            await refreshSystemSnapshotAfterLaunch()
        }
        .task(id: authenticationTaskID) {
            await verifyActiveAccount()
        }
        .task(id: foregroundCloudSyncTaskID) {
            let activeICloudFarmIDs = Set(
                activeCloudBindings.filter { $0.state == .active }.map(\.farmID)
            )
            let activeSupabaseFarmIDs = Set(
                remoteBindings.filter {
                    $0.provider == .supabase && $0.state == .active
                }.map(\.farmID)
            )
            let activeFarmIDs = activeICloudFarmIDs.union(activeSupabaseFarmIDs)
            guard scenePhase == .active,
                  session.accountAccessStatus.allowsCloudOperations,
                  (CloudFeatureConfiguration.isEnabled || SupabaseAccountConfiguration.isConfigured),
                  activeAccount?.serverBindingState == .verified,
                  !migrationCommits.contains(where: {
                      activeFarmIDs.contains($0.farmID) &&
                      $0.ownerAccountID == activeAccount?.effectiveAccountID &&
                      $0.cloudState != .synced
                  }),
                  !activeFarmIDs.isEmpty else { return }
            await collaboration.resumeSupabaseSynchronization()
            guard !Task.isCancelled else { return }
            guard await waitForSecondaryLaunchWindow(.milliseconds(700)) else { return }
            await collaboration.synchronizeNow()
        }
        .task(id: sharedFarmAdmissionTaskID) {
            await completePendingSharedFarmAdmissions()
        }
        .task(id: accountAvatarCloudTaskID) {
            guard scenePhase == .active,
                  session.accountAccessStatus.allowsCloudOperations,
                  let account = activeAccount,
                  account.serverBindingState == .verified,
                  IdentityWorkerConfiguration.baseURL != nil else { return }
            guard await waitForSecondaryLaunchWindow(.seconds(2)) else { return }
            while !Task.isCancelled {
                do {
                    try await AccountAvatarCloudSyncService.shared.synchronize(
                        account: account,
                        context: modelContext
                    )
                } catch is CancellationError {
                    return
                } catch {
                    // Avatar sync must never block farm access. The editor
                    // presents explicit upload/removal errors to the user.
                    #if DEBUG
                    print("[AccountAvatarCloudSync] \(error)")
                    #endif
                }
                do {
                    try await Task.sleep(for: preferences.avatarSyncInterval)
                } catch {
                    return
                }
            }
        }
        .task(id: insightPersonalSyncTaskID) {
            guard scenePhase == .active,
                  session.accountAccessStatus.allowsCloudOperations,
                  let account = activeAccount,
                  account.serverBindingState == .verified,
                  IdentityWorkerConfiguration.baseURL != nil else { return }
            guard await waitForSecondaryLaunchWindow(.seconds(3)) else { return }
            while !Task.isCancelled {
                await InsightPersonalSyncActor.shared.synchronize(
                    accountID: account.effectiveAccountID,
                    context: modelContext
                )
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
            }
        }
        .task(id: migrationCloudTaskID) {
            guard scenePhase == .active,
                  session.accountAccessStatus.allowsCloudOperations,
                  let account = activeAccount,
                  account.serverBindingState == .verified else { return }
            guard await waitForSecondaryLaunchWindow(.milliseconds(1_200)) else { return }
            let accountID = account.effectiveAccountID
            guard session.beginAutomaticCloudRecovery(accountID: accountID) else { return }
            defer { session.finishAutomaticCloudRecovery(accountID: accountID) }

            // The authoritative source device must be allowed to finish its
            // immutable migration upload before any recovery root preflight.
            // A slow CloudKit root read must never sit in front of the Outbox
            // drain and make an in-progress migration appear stalled.
            await collaboration.resumeAutomaticMigrationUploads(accountID: accountID)
            guard !Task.isCancelled else { return }
            do {
                _ = try await OwnerFarmRecoveryCoordinator(
                    modelContainer: modelContext.container
                ).stageMismatchedActiveOwnerFarms(accountID: accountID)
            } catch is CancellationError {
                return
            } catch {
                // A transient root preflight failure must not prevent a farm
                // already locked in rebuildingCache from resuming its staged
                // recovery on this foreground pass.
                collaboration.lastErrorMessage = error.localizedDescription
            }
            await collaboration.discoverAndRestoreOwnerFarms(accountID: accountID)
            guard !Task.isCancelled else { return }
            // Supabase discovery imports the recovered farm through an
            // independent ModelContext. Force this root query/view boundary
            // to reconcile immediately after the durable import completes
            // instead of waiting for another scene transition or relaunch.
            systemSnapshotRevision &+= 1
        }
        .task(id: maintenanceTaskID) {
            guard session.accountAccessStatus.allowsCloudOperations,
                  let account = activeAccount,
                  account.serverBindingState == .verified else { return }
            guard await waitForSecondaryLaunchWindow(.seconds(5)) else { return }
            while !Task.isCancelled {
                let farmIDs = activeCloudBindings.filter { $0.state == .active }.map(\.farmID)
                await collaboration.performIdentityMaintenance(accountID: account.effectiveAccountID, farmIDs: farmIDs)
                do {
                    try await Task.sleep(for: .seconds(43_200))
                } catch {
                    return
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didAcceptFarmCloudShare)) { notification in
            guard let account = activeAccount else { return }
            Task {
                await collaboration.acceptShareNotification(notification, accountID: account.effectiveAccountID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didFailToAcceptFarmCloudShare)) { notification in
            collaboration.lastErrorMessage = (notification.object as? Error)?.localizedDescription ?? "系统共享接受失败。"
        }
    }

    private var activeAccount: AccountProfile? {
        guard let profileID = session.activeAccountProfileID else { return nil }
        return accounts.first(where: { $0.id == profileID })
    }

    private func hasPersistedLocalAccount(for account: AccountProfile) -> Bool {
        // The selected profile is the local-data isolation boundary. A remote
        // provider session may expire or temporarily resolve to a different
        // appAccountID during an account migration; that must pause cloud
        // operations, not hide the already selected profile's local farms.
        // Explicit sign-out still clears activeAccountProfileID immediately.
        session.activeAccountProfileID == account.id
    }

    private var pendingRemoteRestore: FarmRemoteRestoreRecord? {
        guard let account = activeAccount else { return nil }
        return remoteRestoreRecords
            .filter {
                $0.accountID == account.effectiveAccountID &&
                    $0.state != .completed
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func verifyActiveAccount() async {
        guard scenePhase == .active else { return }
        guard let account = activeAccount else {
            session.authenticationCheckDidFinish(
                .requiresSignIn("请登录账户后继续。"),
                automaticallyPresentReauthentication: false
            )
            subscription.reset()
            return
        }

        #if DEBUG
        do {
            if let clone = try cloneDevelopmentFarmIfRequested(account: account) {
                session.selectedFarmID = clone.targetFarmID
                systemSnapshotRevision &+= 1
                print(
                    "[DevelopmentFarmClone] target=\(clone.targetFarmID.uuidString.lowercased()) " +
                        "business=\(clone.clonedBusinessRecordCount) " +
                        "operations=\(clone.clonedOperationCount) " +
                        "photos=\(clone.clonedPhotoCount) " +
                        "activeSheep=\(clone.activeSheepCount) " +
                        "alreadyCompleted=\(clone.alreadyCompleted)"
                )
            }
            if try repairDevelopmentLocalAccountBindingIfRequested(account: account) {
                session.authenticationCheckDidFinish(
                    .requiresSignIn("已恢复原本地牧场的账号关联；本地数据可以使用。重新登录后再继续云端验证。"),
                    automaticallyPresentReauthentication: false
                )
                subscription.reset()
                return
            }
        } catch {
            collaboration.lastErrorMessage = "本地牧场账号关联恢复未执行：\(error.localizedDescription)"
        }
        #endif

        guard account.serverBindingState == .verified,
              hasPersistedLocalAccount(for: account) else {
            session.authenticationCheckDidFinish(
                .requiresSignIn("本机登录会话不存在，请重新登录。"),
                automaticallyPresentReauthentication: false
            )
            subscription.reset()
            return
        }

        let status = await AccountAccessResolver.resolve(for: account)
        guard !Task.isCancelled else { return }

        session.authenticationCheckDidFinish(
            status,
            automaticallyPresentReauthentication: true
        )

        guard status.allowsCloudOperations else {
            subscription.reset()
            return
        }

        await collaboration.refreshAccountAvailability()
        await subscription.activate(accountID: account.effectiveAccountID)
    }

    #if DEBUG
    @MainActor
    private func cloneDevelopmentFarmIfRequested(
        account: AccountProfile
    ) throws -> DevelopmentFarmCloneResult? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let sourceFarmID = developmentArgument(
            named: "--clone-source-farm",
            in: arguments
        ).flatMap(UUID.init(uuidString:)),
        let targetFarmID = developmentArgument(
            named: "--clone-target-farm",
            in: arguments
        ).flatMap(UUID.init(uuidString:)),
        let expectedActiveCount = developmentArgument(
            named: "--expected-active-sheep",
            in: arguments
        ).flatMap(Int.init) else {
            return nil
        }
        guard SupabaseAccountConfiguration.isEnabled else {
            throw DevelopmentLocalAccountRecoveryError.supabaseDevelopmentDisabled
        }
        return try DevelopmentFarmCloneService.clone(
            sourceFarmID: sourceFarmID,
            targetFarmID: targetFarmID,
            account: account,
            expectedActiveSheepCount: expectedActiveCount,
            context: modelContext
        )
    }

    @MainActor
    private func repairDevelopmentLocalAccountBindingIfRequested(
        account: AccountProfile
    ) throws -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let farmID = developmentArgument(
            named: "--recover-local-account-farm",
            in: arguments
        ).flatMap(UUID.init(uuidString:)),
        let expectedActiveCount = developmentArgument(
            named: "--expected-active-sheep",
            in: arguments
        ).flatMap(Int.init) else {
            return false
        }

        guard SupabaseAccountConfiguration.isEnabled else {
            throw DevelopmentLocalAccountRecoveryError.supabaseDevelopmentDisabled
        }
        guard let farm = farms.first(where: {
            $0.id == farmID && $0.deletedAt == nil
        }) else {
            throw DevelopmentLocalAccountRecoveryError.farmNotFound
        }
        guard farm.ownerAccountID != account.effectiveAccountID else {
            session.selectedFarmID = farm.id
            return false
        }

        let activeSheepCount = try modelContext.fetch(
            FetchDescriptor<SheepRecord>()
        ).lazy.filter {
            $0.farmID == farm.id &&
                $0.deletedAt == nil &&
                $0.statusRawValue == SheepStatus.active.rawValue
        }.count
        guard activeSheepCount == expectedActiveCount else {
            throw DevelopmentLocalAccountRecoveryError.activeSheepCountMismatch(
                expected: expectedActiveCount,
                actual: activeSheepCount
            )
        }

        let normalizedAccountName = account.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard membershipBindings.contains(where: {
            $0.farmID == farm.id &&
                $0.accountID == farm.ownerAccountID &&
                $0.role == .owner &&
                $0.status == .active &&
                ($0.displayName ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    == normalizedAccountName
        }) else {
            throw DevelopmentLocalAccountRecoveryError.ownerMembershipMismatch
        }
        guard cloudBindings.contains(where: {
            $0.farmID == farm.id &&
                $0.ownerAccountID == farm.ownerAccountID &&
                $0.databaseScope == .privateDatabase &&
                $0.state == .active
        }) else {
            throw DevelopmentLocalAccountRecoveryError.privateBindingMismatch
        }

        let snapshots = try modelContext.fetch(
            FetchDescriptor<FarmMembershipSnapshotRecord>()
        )
        guard snapshots.contains(where: {
            $0.farmID == farm.id &&
                $0.signedByAccountID == farm.ownerAccountID &&
                $0.validatedAt != nil
        }) else {
            throw DevelopmentLocalAccountRecoveryError.validatedSnapshotMissing
        }
        guard !accounts.contains(where: {
            $0.id != account.id &&
                $0.effectiveAccountID == farm.ownerAccountID
        }) else {
            throw DevelopmentLocalAccountRecoveryError.ownerAlreadyBound
        }

        account.serverAccountID = farm.ownerAccountID
        account.serverBindingStateRaw = ServerBindingState.verified.rawValue
        account.updatedAt = .now
        try modelContext.save()
        session.selectedFarmID = farm.id
        return true
    }

    private func developmentArgument(
        named name: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
    #endif

    private var visibleFarms: [FarmRecord] {
        guard let account = activeAccount else { return [] }
        let hiddenRestoringFarmIDs = Set(
            remoteRestoreRecords
                .filter {
                    $0.accountID == account.effectiveAccountID &&
                        $0.state != .completed
                }
                .map(\.farmID)
        )
        let bindingsByFarmID = Dictionary(grouping: cloudBindings, by: \.farmID)
        let membershipsByFarmID = Dictionary(
            grouping: membershipBindings.filter {
                $0.accountID == account.effectiveAccountID
            },
            by: \.farmID
        ).compactMapValues { $0.first?.status }
        return farms.filter { farm in
            guard !hiddenRestoringFarmIDs.contains(farm.id) else {
                return false
            }
            let binding = bindingsByFarmID[farm.id]?.first
            if let sharedBinding = bindingsByFarmID[farm.id]?.first(where: {
                $0.databaseScope == .sharedDatabase
            }) {
                guard let membershipStatus = membershipsByFarmID[farm.id] else {
                    return false
                }
                return SharedFarmAdmissionPolicy.isReadyForDisplay(
                    bindingScope: sharedBinding.databaseScope,
                    bindingState: sharedBinding.state,
                    farmName: farm.name,
                    membershipStatus: membershipStatus
                )
            }
            return SharedFarmAdmissionPolicy.isLocallyOwnedForDisplay(
                farmOwnerAccountID: farm.ownerAccountID,
                activeAccountID: account.effectiveAccountID,
                bindingScope: binding?.databaseScope
            )
        }
    }

    private var pendingSharedFarmIDs: [UUID] {
        guard let account = activeAccount else { return [] }
        let membershipStatuses = Dictionary(
            grouping: membershipBindings.filter {
                $0.accountID == account.effectiveAccountID
            },
            by: \.farmID
        ).compactMapValues { $0.first?.status }
        let farmNames = Dictionary(
            uniqueKeysWithValues: farms.map { ($0.id, $0.name) }
        )
        return Set(cloudBindings.compactMap { binding in
            guard binding.databaseScope == .sharedDatabase,
                  let farmName = farmNames[binding.farmID],
                  SharedFarmAdmissionPolicy.isPendingAdmission(
                      bindingScope: binding.databaseScope,
                      bindingState: binding.state,
                      farmName: farmName,
                      membershipStatus: membershipStatuses[binding.farmID]
                  ) else {
                return nil
            }
            return binding.farmID
        })
        .sorted { $0.uuidString < $1.uuidString }
    }

    private var activeCloudBindings: [CloudFarmBinding] {
        let farmIDs = Set(visibleFarms.map(\.id))
        return cloudBindings.filter { farmIDs.contains($0.farmID) }
    }

    private var currentSharedFarmAdmissionSession: CloudRebuildSessionRecord? {
        let farmIDs = Set(pendingSharedFarmIDs)
        return cloudRebuildSessions.first {
            farmIDs.contains($0.farmID) &&
                $0.databaseScope == .sharedDatabase
        }
    }

    private var sharedFarmAdmissionStatus: SharedFarmAdmissionStatus? {
        guard !pendingSharedFarmIDs.isEmpty else { return nil }
        guard let session = currentSharedFarmAdmissionSession else {
            return SharedFarmAdmissionStatus(detailText: "正在验证成员权限和场主签名")
        }
        let detailText: String
        switch session.status {
        case .preparing:
            detailText = "正在建立安全下载通道"
        case .fetching:
            if session.fetchedRecordCount > 0 {
                detailText = "已下载 \(session.fetchedRecordCount.formatted()) 条 · 第 \(session.pageCount.formatted()) 页"
            } else {
                detailText = "正在读取云端牧场资料"
            }
        case .downloadingAssets:
            detailText = "正在下载照片 \(session.downloadedAssetCount.formatted()) / \(session.fetchedAssetCount.formatted())"
        case .validating:
            detailText = "资料已下载，正在校验完整性"
        case .readyToCommit:
            detailText = "校验完成，正在准备显示牧场"
        case .committing:
            detailText = "正在安全切换到共享牧场资料"
        case .completed:
            detailText = "资料已就绪，正在完成成员绑定"
        case .failed, .cancelled:
            detailText = session.status == .failed
                ? "加入中断，已停止自动重试"
                : "加入已暂停"
        }
        return SharedFarmAdmissionStatus(detailText: detailText)
    }

    private var maintenanceTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
        let farmPart = activeCloudBindings.filter { $0.state == .active }.map(\.farmID.uuidString).sorted().joined(separator: ",")
        return "\(accountPart)|\(farmPart)|\(session.accountAccessStatus.taskKey)"
    }

    private var authenticationTaskID: String {
        "\(scenePhase)|\(session.activeAccountProfileID?.uuidString ?? "none")|\(session.authenticationRevision)"
    }

    private var foregroundCloudSyncTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
        let activeICloudFarmIDs = Set(
            activeCloudBindings.filter { $0.state == .active }.map(\.farmID)
        )
        let activeSupabaseFarmIDs = Set(
            remoteBindings.filter {
                $0.provider == .supabase && $0.state == .active
            }.map(\.farmID)
        )
        let activeFarmIDs = activeICloudFarmIDs.union(activeSupabaseFarmIDs)
        let bindingPart = activeFarmIDs
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
        let migrationPart = migrationCommits
            .filter { activeFarmIDs.contains($0.farmID) }
            .map { "\($0.farmID.uuidString):\($0.cloudState.rawValue)" }
            .sorted()
            .joined(separator: ",")
        return "\(scenePhase)|\(accountPart)|\(bindingPart)|\(migrationPart)|\(session.accountAccessStatus.taskKey)"
    }

    private var sharedFarmAdmissionTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
        let farmPart = pendingSharedFarmIDs.map(\.uuidString).joined(separator: ",")
        return "\(scenePhase)|\(accountPart)|\(farmPart)|\(session.accountAccessStatus.taskKey)"
    }

    private var migrationCloudTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
        // Cache replacement inserts the recovered migration commit and legacy
        // cleanup deletes the superseded one. Neither may change this task's
        // identity or SwiftUI will cancel and restart the recovery mid-commit.
        return "\(scenePhase)|\(accountPart)|\(session.accountAccessStatus.taskKey)"
    }

    private var accountAvatarCloudTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
        return "\(scenePhase)|\(accountPart)|\(preferences.effectivePowerSavingEnabled)|\(session.accountAccessStatus.taskKey)"
    }

    private var insightPersonalSyncTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
        return "\(scenePhase)|\(accountPart)|\(session.accountAccessStatus.taskKey)"
    }

    private var systemSnapshotTaskID: String {
        let farmPart = visibleFarms.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        return "\(scenePhase)|\(farmPart)|\(session.selectedFarmID?.uuidString ?? "none")|\(systemSnapshotRevision)"
    }

    @MainActor
    private func refreshSystemSnapshotAfterLaunch() async {
        guard scenePhase == .active, !visibleFarms.isEmpty else { return }
        do {
            // Widget data is useful but must not compete with the first frame.
            try await Task.sleep(for: .milliseconds(1_500))
            let snapshot = try await FarmSystemSnapshotActor(
                container: modelContext.container
            ).makeSnapshot(
                farmIDs: visibleFarms.map(\.id),
                selectedFarmID: session.selectedFarmID
            )
            try Task.checkCancellation()
            let previousDomains = await FarmSystemIntegrationService.publish(
                snapshot,
                refreshSearchIndex: false
            )

            // Spotlight indexing is the heaviest secondary launch job. Run it
            // only after the workspace has had time to become interactive.
            try await Task.sleep(for: .seconds(8))
            await FarmSystemIntegrationService.refreshSearchIndex(
                snapshot,
                replacingDomains: previousDomains
            )
        } catch is CancellationError {
            return
        } catch {
            #if DEBUG
            print("[FarmSystemSnapshot] \(error)")
            #endif
        }
    }

    @MainActor
    private func completePendingSharedFarmAdmissions() async {
        guard scenePhase == .active,
              session.accountAccessStatus.allowsCloudOperations,
              let account = activeAccount,
              account.serverBindingState == .verified,
              CloudFeatureConfiguration.isEnabled,
              !pendingSharedFarmIDs.isEmpty else {
            return
        }
        guard await waitForSecondaryLaunchWindow(.milliseconds(700)) else {
            return
        }

        var attempt = 0
        while !Task.isCancelled {
            let farmIDs = pendingSharedFarmIDs
            guard !farmIDs.isEmpty else { return }
            var completedAny = false
            for farmID in farmIDs {
                guard !Task.isCancelled else { return }
                if await collaboration.completeAcceptedSharedFarmAdmission(
                    farmID: farmID,
                    accountID: account.effectiveAccountID
                ) {
                    completedAny = true
                }
            }
            if completedAny {
                systemSnapshotRevision &+= 1
                session.reconcileActiveFarm(with: visibleFarms)
            }
            attempt += 1
            do {
                try await Task.sleep(
                    for: attempt <= 24 ? .seconds(5) : .seconds(30)
                )
            } catch {
                return
            }
        }
    }

    private func waitForSecondaryLaunchWindow(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

private struct SharedFarmAdmissionProgressView: View {
    var body: some View {
        ContentUnavailableView {
            Label("正在加入共享牧场", systemImage: "person.2.badge.gearshape")
        } description: {
            Text("成员资格已经建立，正在验证场主签名并下载完整牧场资料。")
        } actions: {
            ProgressView()
                .controlSize(.large)
        }
    }
}
