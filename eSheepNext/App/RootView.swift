import SwiftData
import SwiftUI

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
    @Query private var membershipBindings: [FarmMembershipBinding]
    @Query private var sheep: [SheepRecord]
    @Query private var pens: [PenRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var migrationCommits: [MigrationCommitRecord]

    var body: some View {
        @Bindable var session = session

        Group {
            if let account = activeAccount, hasPersistedLocalAccount(for: account) {
                if visibleFarms.isEmpty {
                    FarmSetupView(account: account)
                } else {
                    FarmWorkspaceView(account: account, farms: visibleFarms)
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
        .onOpenURL { url in
            guard let target = FarmSystemIntegrationService.target(from: url) else { return }
            FarmSystemNavigationStore.enqueue(target)
            session.consumeSystemNavigationTarget()
        }
        .task(id: systemSnapshotRevision) {
            var pendingOperationCounts: [UUID: Int] = [:]
            for farm in visibleFarms {
                let farmID = farm.id
                let pending = OutboxStatus.pending.rawValue
                let retryable = OutboxStatus.retryableFailure.rawValue
                let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate {
                    $0.farmID == farmID && ($0.statusRawValue == pending || $0.statusRawValue == retryable)
                })
                pendingOperationCounts[farmID] = (try? modelContext.fetchCount(descriptor)) ?? 0
            }
            let snapshot = FarmSystemIntegrationService.makeSnapshot(
                farms: visibleFarms,
                sheep: sheep,
                pens: pens,
                feeds: feeds,
                pendingOperationCounts: pendingOperationCounts,
                selectedFarmID: session.selectedFarmID
            )
            await FarmSystemIntegrationService.publish(snapshot)
        }
        .task(id: authenticationTaskID) {
            await verifyActiveAccount()
        }
        .task(id: foregroundCloudSyncTaskID) {
            let activeFarmIDs = Set(activeCloudBindings.filter { $0.state == .active }.map(\.farmID))
            guard scenePhase == .active,
                  session.accountAccessStatus.allowsCloudOperations,
                  CloudFeatureConfiguration.isEnabled,
                  activeAccount?.serverBindingState == .verified,
                  !migrationCommits.contains(where: {
                      activeFarmIDs.contains($0.farmID) &&
                      $0.ownerAccountID == activeAccount?.effectiveAccountID &&
                      $0.cloudState != .synced
                  }),
                  !activeFarmIDs.isEmpty else { return }
            await collaboration.synchronizeNow()
        }
        .task(id: accountAvatarCloudTaskID) {
            guard scenePhase == .active,
                  session.accountAccessStatus.allowsCloudOperations,
                  let account = activeAccount,
                  account.serverBindingState == .verified,
                  IdentityWorkerConfiguration.baseURL != nil else { return }
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
        .task(id: migrationCloudTaskID) {
            guard scenePhase == .active,
                  session.accountAccessStatus.allowsCloudOperations,
                  let account = activeAccount,
                  account.serverBindingState == .verified else { return }
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
        }
        .task(id: maintenanceTaskID) {
            guard session.accountAccessStatus.allowsCloudOperations,
                  let account = activeAccount,
                  account.serverBindingState == .verified else { return }
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
        SecureAccountStore.hasPersistedSession(for: account.effectiveAccountID)
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

    private var visibleFarms: [FarmRecord] {
        guard let account = activeAccount else { return [] }
        let sharedFarmIDs = Set(membershipBindings.compactMap { binding in
            binding.accountID == account.effectiveAccountID && binding.status == .active ? binding.farmID : nil
        })
        return farms.filter { $0.ownerAccountID == account.effectiveAccountID || sharedFarmIDs.contains($0.id) }
    }

    private var activeCloudBindings: [CloudFarmBinding] {
        let farmIDs = Set(visibleFarms.map(\.id))
        return cloudBindings.filter { farmIDs.contains($0.farmID) }
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
        let activeFarmIDs = Set(activeCloudBindings.filter { $0.state == .active }.map(\.farmID))
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

    private var systemSnapshotRevision: String {
        let farmPart = visibleFarms.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        let sheepPart = sheep.filter { visibleFarmIDs.contains($0.farmID) }.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        let penPart = pens.filter { visibleFarmIDs.contains($0.farmID) }.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        return "\(farmPart)|\(sheepPart)|\(penPart)|\(feeds.count)|\(session.selectedFarmID?.uuidString ?? "none")"
    }

    private var visibleFarmIDs: Set<UUID> { Set(visibleFarms.map(\.id)) }
}
