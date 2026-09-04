import SwiftData
import SwiftUI

enum ESheepCloudFarmVisibilityPolicy {
    static func isReadyForDisplay(
        bindingState: FarmRemoteBindingState?,
        membershipStatus: FarmMembershipStatus?
    ) -> Bool {
        bindingState == .active && membershipStatus == .active
    }

    static func isLegacyCompatibilityRestore(
        profileMode: FarmStorageMode?,
        transitionState: FarmStorageTransitionState?
    ) -> Bool {
        guard let profileMode else { return true }
        return profileMode == .supabase &&
            transitionState != .readOnlyMigration
    }
}

#if DEBUG
import UIKit
#endif

#if DEBUG
private enum DevelopmentLocalAccountRecoveryError: LocalizedError {
    case eSheepCloudDevelopmentDisabled

    var errorDescription: String? {
        switch self {
        case .eSheepCloudDevelopmentDisabled:
            "只允许在已启用 eSheep+ 云的 Development 构建中执行。"
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
    @Environment(FarmNotificationService.self) private var notifications
    @Environment(\.scenePhase) private var scenePhase
    @Query private var accounts: [AccountProfile]
    @Query(sort: \FarmRecord.updatedAt, order: .reverse) private var farms: [FarmRecord]
    @Query private var remoteBindings: [FarmRemoteBinding]
    @Query private var remoteRestoreRecords: [FarmRemoteRestoreRecord]
    @Query private var membershipBindings: [FarmMembershipBinding]
    @Query private var storageProfiles: [FarmStorageProfile]
    @Query private var initialSyncSessions: [ESheepCloudInitialSyncSession]
    @State private var lifecycleCoordinator = AppLifecycleCoordinator()

    var body: some View {
        @Bindable var session = session

        Group {
            if let account = activeAccount,
               hasPersistedLocalAccount(for: account),
               hasCurrentLegalConsent(for: account) {
                if let restore = pendingRemoteRestore {
                    SupabaseFarmRestoreProgressView(record: restore)
                } else if let initialSync = pendingESheepCloudInitialSync {
                    ESheepCloudInitialSyncProgressView(session: initialSync)
                } else if visibleFarms.isEmpty {
                    FarmSetupView(account: account)
                } else {
                    FarmWorkspaceView(
                        account: account,
                        farms: visibleFarms,
                        sharedFarmAdmissionStatus: nil
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
                ESheepCloudJoinFarmView(
                    account: account,
                    initialCode: session.pendingESheepCloudInvitationCode
                ) { farm in
                    session.pendingESheepCloudInvitationCode = nil
                    session.selectedFarmID = farm.id
                }
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
        .onChange(of: session.selectedFarmID) { _, _ in
            PerformanceTrace.event(.farmSwitch, count: visibleFarms.count)
        }
        .onChange(of: scenePhase) { _, phase in
#if DEBUG
            // Keep the debug device awake while the farm workflow is being
            // exercised; backgrounding the app restores normal system lock.
            UIApplication.shared.isIdleTimerDisabled = phase == .active
#endif
            if phase == .active {
                preferences.refreshSystemPowerState()
                session.consumePendingNavigationRequest()
                session.consumeSystemNavigationTarget()
            } else if phase == .background {
                FarmBackgroundRefresh.schedule()
            }
        }
#if DEBUG
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
        }
#endif
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            preferences.refreshSystemPowerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudRuntimeNotification.syncWake)) { notification in
            guard let farmID = CloudRuntimeNotification.farmID(from: notification),
                  visibleFarms.contains(where: { $0.id == farmID }) else { return }
            lifecycleCoordinator.requestRefresh([
                .systemSnapshot,
                .operationalAlerts,
            ])
        }
        .onReceive(NotificationCenter.default.publisher(for: FarmOperationalAlertRuntimeNotification.refreshRequested)) { notification in
            guard let farmID = FarmOperationalAlertRuntimeNotification.farmID(from: notification),
                  visibleFarms.contains(where: { $0.id == farmID }) else { return }
            lifecycleCoordinator.requestRefresh(.operationalAlerts)
        }
        .onOpenURL { url in
            if let code = ESheepCloudFarmInvitationLink.code(from: url),
               collaboration.isESheepCloudAvailable {
                session.pendingESheepCloudInvitationCode = code
                session.isJoinFarmPresented = true
                return
            }
            guard let target = FarmSystemIntegrationService.target(from: url) else { return }
            FarmSystemNavigationStore.enqueue(target)
            session.consumeSystemNavigationTarget()
        }
        .task(id: systemSnapshotTaskID) {
            let context = systemSnapshotTaskID
            await lifecycleCoordinator.performSingleFlight(
                kind: .systemSnapshot,
                context: context
            ) { lease in
                await refreshSystemSnapshotAfterLaunch(lease: lease)
            }
        }
        .task(id: operationalAlertDigestTaskID) {
            let context = operationalAlertDigestTaskID
            await lifecycleCoordinator.performSingleFlight(
                kind: .operationalAlerts,
                context: context
            ) { lease in
                await refreshOperationalAlertDigests(lease: lease)
            }
        }
        .task(id: authenticationTaskID) {
            let context = authenticationTaskID
            await lifecycleCoordinator.performSingleFlight(
                kind: .authentication,
                context: context
            ) { lease in
                await verifyActiveAccount(lease: lease)
            }
        }
        .task(id: foregroundCloudSyncTaskID) {
            let context = foregroundCloudSyncTaskID
            await lifecycleCoordinator.performSingleFlight(
                kind: .foregroundCloudSync,
                context: context
            ) { lease in
                await performForegroundCloudSync(lease: lease)
            }
        }
        .task(id: accountAvatarCloudTaskID) {
            let context = accountAvatarCloudTaskID
            await lifecycleCoordinator.performSingleFlight(
                kind: .accountAvatarSync,
                context: context
            ) { lease in
                await runAccountAvatarCloudSyncLoop(lease: lease)
            }
        }
        .task(id: insightPersonalSyncTaskID) {
            let context = insightPersonalSyncTaskID
            await lifecycleCoordinator.performSingleFlight(
                kind: .insightPersonalSync,
                context: context
            ) { lease in
                await runInsightPersonalSyncLoop(lease: lease)
            }
        }
        .task(id: remoteFarmDiscoveryTaskID) {
            let context = remoteFarmDiscoveryTaskID
            await lifecycleCoordinator.performSingleFlight(
                kind: .migrationRecovery,
                context: context
            ) { lease in
                await discoverRemoteFarmsIfNeeded(lease: lease)
            }
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

    private func hasCurrentLegalConsent(for account: AccountProfile) -> Bool {
        account.acceptedTermsVersion == LegalPolicyVersions.terms &&
            account.acceptedPrivacyVersion == LegalPolicyVersions.privacy &&
            LegalConsentStore.hasCurrentConsent(for: account.effectiveAccountID)
    }

    private var pendingRemoteRestore: FarmRemoteRestoreRecord? {
        guard let account = activeAccount else { return nil }
        return remoteRestoreRecords
            .filter { record in
                record.accountID == account.effectiveAccountID &&
                    record.state != .completed &&
                    isLegacyCompatibilityRestore(record)
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private var pendingESheepCloudInitialSync: ESheepCloudInitialSyncSession? {
        guard let account = activeAccount else { return nil }
        let accessibleFarmIDs = Set(
            membershipBindings
                .filter {
                    $0.accountID == account.effectiveAccountID &&
                        $0.status == .active
                }
                .map(\.farmID)
        )
        return initialSyncSessions
            .filter {
                accessibleFarmIDs.contains($0.farmID) && $0.state != .active
            }
            .max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
                return lhs.startedAt < rhs.startedAt
            }
    }

    /// The old checkpoint restore screen is a compatibility escape hatch for
    /// farms that are still on the legacy route.  A V2 farm (or a farm already
    /// behind the read-only migration barrier) must never be sent back to that
    /// screen: its only normal entry point is eSheep+ Cloud's initial receive
    /// or migration center.
    private func isLegacyCompatibilityRestore(
        _ record: FarmRemoteRestoreRecord
    ) -> Bool {
        guard let profile = storageProfiles.first(where: {
            $0.farmID == record.farmID
        }) else {
            // A discovery record can be created before the local profile is
            // materialized.  Keep this narrow rescue path available until the
            // profile is known, but never classify an explicit V2 profile as
            // legacy below.
            return true
        }
        return ESheepCloudFarmVisibilityPolicy.isLegacyCompatibilityRestore(
            profileMode: profile.mode,
            transitionState: profile.transitionState
        )
    }

    @MainActor
    private func performForegroundCloudSync(
        lease: AppLifecycleCoordinator.Lease
    ) async {
        let activeFarmIDs = Set(
            remoteBindings.filter {
                ($0.provider == .supabase || $0.provider == .eSheepCloud) &&
                    $0.state == .active
            }.map(\.farmID)
        )
        guard scenePhase == .active,
              session.accountAccessStatus.allowsCloudOperations,
              ESheepCloudAvailability.isConfigured,
              activeAccount?.serverBindingState == .verified,
              !activeFarmIDs.isEmpty,
              lifecycleCoordinator.isCurrent(lease) else { return }

        let interval = PerformanceTrace.begin(.foregroundResume, count: activeFarmIDs.count)
        defer { PerformanceTrace.end(interval) }

        // Let the foreground transition and the first interactive frame settle
        // before network reconciliation starts competing for CPU and model work.
        guard await waitForSecondaryLaunchWindow(.milliseconds(700)) else { return }
        guard lifecycleCoordinator.isCurrent(lease) else { return }
        // The resume entry point reconciles both eSheep+ Cloud V2 and the
        // remaining legacy farms, and reconnects the legacy realtime listeners.
        // A second synchronizeNow()
        // here repeated the same work on every foreground transition.
        await collaboration.resumeSupabaseSynchronization()
    }

    @MainActor
    private func runAccountAvatarCloudSyncLoop(
        lease: AppLifecycleCoordinator.Lease
    ) async {
        guard scenePhase == .active,
              session.accountAccessStatus.allowsCloudOperations,
              let account = activeAccount,
              account.serverBindingState == .verified,
              ESheepCloudAvailability.isConfigured ||
                IdentityWorkerConfiguration.baseURL != nil,
              lifecycleCoordinator.isCurrent(lease) else { return }
        guard await waitForSecondaryLaunchWindow(.seconds(2)) else { return }
        while lifecycleCoordinator.isCurrent(lease) {
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
            guard lifecycleCoordinator.isCurrent(lease) else { return }
            do {
                try await Task.sleep(for: preferences.avatarSyncInterval)
            } catch {
                return
            }
        }
    }

    @MainActor
    private func runInsightPersonalSyncLoop(
        lease: AppLifecycleCoordinator.Lease
    ) async {
        guard scenePhase == .active,
              session.accountAccessStatus.allowsCloudOperations,
              let account = activeAccount,
              account.serverBindingState == .verified,
              IdentityWorkerConfiguration.baseURL != nil,
              lifecycleCoordinator.isCurrent(lease) else { return }
        guard await waitForSecondaryLaunchWindow(.seconds(3)) else { return }
        while lifecycleCoordinator.isCurrent(lease) {
            await InsightPersonalSyncActor.shared.synchronize(
                accountID: account.effectiveAccountID,
                context: modelContext
            )
            guard lifecycleCoordinator.isCurrent(lease) else { return }
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }
        }
    }

    @MainActor
    private func discoverRemoteFarmsIfNeeded(
        lease: AppLifecycleCoordinator.Lease
    ) async {
        guard scenePhase == .active,
              session.accountAccessStatus.allowsCloudOperations,
              let account = activeAccount,
              account.serverBindingState == .verified,
              lifecycleCoordinator.isCurrent(lease) else { return }
        guard await waitForSecondaryLaunchWindow(.milliseconds(1_200)) else { return }
        guard lifecycleCoordinator.isCurrent(lease) else { return }
        await recoverAccessibleFarms(
            accountID: account.effectiveAccountID,
            lease: lease
        )
    }

    @MainActor
    private func verifyActiveAccount(
        lease: AppLifecycleCoordinator.Lease
    ) async {
        let interval = PerformanceTrace.begin(.authentication)
        defer { PerformanceTrace.end(interval) }
        guard lifecycleCoordinator.isCurrent(lease) else { return }
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
                lifecycleCoordinator.requestRefresh(.systemSnapshot)
                print(
                    "[DevelopmentFarmClone] target=\(clone.targetFarmID.uuidString.lowercased()) " +
                        "business=\(clone.clonedBusinessRecordCount) " +
                        "operations=\(clone.clonedOperationCount) " +
                        "photos=\(clone.clonedPhotoCount) " +
                        "activeSheep=\(clone.activeSheepCount) " +
                        "alreadyCompleted=\(clone.alreadyCompleted)"
                )
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

        guard hasCurrentLegalConsent(for: account) else {
            session.authenticationCheckDidFinish(
                .requiresSignIn("服务条款或隐私政策已更新，请阅读并重新明确同意后继续。"),
                automaticallyPresentReauthentication: false
            )
            subscription.reset()
            return
        }

        let status = await AccountAccessResolver.resolve(for: account)
        guard lifecycleCoordinator.isCurrent(lease) else { return }

        session.authenticationCheckDidFinish(
            status,
            automaticallyPresentReauthentication: true
        )

        guard status.allowsCloudOperations else {
            subscription.reset()
            return
        }

        await collaboration.refreshAccountAvailability()
        guard lifecycleCoordinator.isCurrent(lease) else { return }
        await subscription.activate(accountID: account.effectiveAccountID)
        guard lifecycleCoordinator.isCurrent(lease) else { return }

        // A clean install still needs a deterministic first discovery because
        // the sibling SwiftUI task may not be recreated after authentication.
        // Once any local or remote farm state is known, the dedicated delayed
        // discovery task owns later refreshes; repeating it here made every
        // foreground authentication path restore the same farms again.
        let knownAccountFarmIDs = Set(farms.compactMap { farm -> UUID? in
            farm.ownerAccountID == account.effectiveAccountID ? farm.id : nil
        }).union(membershipBindings.compactMap { membership -> UUID? in
            membership.accountID == account.effectiveAccountID
                ? membership.farmID
                : nil
        })
        let hasKnownRemoteFarmState = remoteBindings.contains { binding in
            (binding.provider == .eSheepCloud || binding.provider == .supabase) &&
                knownAccountFarmIDs.contains(binding.farmID)
        }
        if visibleFarms.isEmpty && !hasKnownRemoteFarmState {
            await recoverAccessibleFarms(
                accountID: account.effectiveAccountID,
                lease: lease
            )
        }
    }

    @MainActor
    private func recoverAccessibleFarms(
        accountID: UUID,
        lease: AppLifecycleCoordinator.Lease? = nil
    ) async {
        if let lease, !lifecycleCoordinator.isCurrent(lease) { return }
        guard session.beginAutomaticRemoteDiscovery(accountID: accountID) else { return }
        defer { session.finishAutomaticRemoteDiscovery(accountID: accountID) }

        let interval = PerformanceTrace.begin(.syncRebuild)
        defer { PerformanceTrace.end(interval) }

        await collaboration.discoverAndRestoreOwnerFarms(accountID: accountID)
        guard !Task.isCancelled else { return }
        if let lease, !lifecycleCoordinator.isCurrent(lease) { return }
        // Supabase discovery imports the recovered farm through an
        // independent ModelContext. Force this root query/view boundary to
        // reconcile immediately after the durable import completes.
        lifecycleCoordinator.requestRefresh(.systemSnapshot)
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
        guard ESheepCloudAvailability.isEnabled else {
            throw DevelopmentLocalAccountRecoveryError.eSheepCloudDevelopmentDisabled
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
                .filter { record in
                    record.accountID == account.effectiveAccountID &&
                        record.state != .completed &&
                        isLegacyCompatibilityRestore(record)
                }
                .map(\.farmID)
        )
        let remoteBindingsByFarmID = Dictionary(
            grouping: remoteBindings,
            by: \.farmID
        )
        let membershipsByFarmID = Dictionary(
            grouping: membershipBindings.filter {
                $0.accountID == account.effectiveAccountID
            },
            by: \.farmID
        ).compactMapValues { $0.first?.status }

        return farms.filter { farm in
            guard farm.deletedAt == nil,
                  !hiddenRestoringFarmIDs.contains(farm.id) else {
                return false
            }
            if let remoteBinding = remoteBindingsByFarmID[farm.id]?.first(
                where: {
                    $0.provider == .eSheepCloud || $0.provider == .supabase
                }
            ) {
                return ESheepCloudFarmVisibilityPolicy.isReadyForDisplay(
                    bindingState: remoteBinding.state,
                    membershipStatus: membershipsByFarmID[farm.id]
                )
            }
            return farm.ownerAccountID == account.effectiveAccountID
        }
    }

    /// System surfaces follow an active eSheep+ Cloud authority. Local-only
    /// recovery farms remain available inside the app until explicitly
    /// audited, but they must not leak back into Spotlight, widgets or intents.
    private var cloudSystemFarms: [FarmRecord] {
        let activeCloudFarmIDs = Set(remoteBindings.compactMap { binding -> UUID? in
            (binding.provider == .supabase || binding.provider == .eSheepCloud) &&
                binding.state == .active
                ? binding.farmID
                : nil
        })
        return visibleFarms.filter { activeCloudFarmIDs.contains($0.id) }
    }

    private var cloudSystemSelectedFarmID: UUID? {
        if let selectedFarmID = session.selectedFarmID,
           cloudSystemFarms.contains(where: { $0.id == selectedFarmID }) {
            return selectedFarmID
        }
        return cloudSystemFarms.first?.id
    }

    private var authenticationTaskID: String {
        "\(scenePhase)|\(session.activeAccountProfileID?.uuidString ?? "none")|\(session.authenticationRevision)"
    }

    private var foregroundCloudSyncTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
        let bindingPart = remoteBindings
            .filter {
                $0.provider == .supabase || $0.provider == .eSheepCloud
            }
            .map {
                "\($0.farmID.uuidString):\($0.provider.rawValue):\($0.authorityGeneration):\($0.state.rawValue)"
            }
            .sorted()
            .joined(separator: ",")
        return "\(scenePhase)|\(accountPart)|\(bindingPart)|\(session.accountAccessStatus.taskKey)"
    }

    private var remoteFarmDiscoveryTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
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
        let farmPart = cloudSystemFarms.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        return "\(scenePhase)|\(farmPart)|\(cloudSystemSelectedFarmID?.uuidString ?? "none")|\(lifecycleCoordinator.systemSnapshotRevision)"
    }

    private var operationalAlertDigestTaskID: String {
        let farmPart = visibleFarms.map(\.id).sorted { $0.uuidString < $1.uuidString }
            .map(\.uuidString)
            .joined(separator: ",")
        return "\(scenePhase)|\(farmPart)|\(lifecycleCoordinator.operationalAlertRevision)"
    }

    @MainActor
    private func refreshOperationalAlertDigests(
        lease: AppLifecycleCoordinator.Lease
    ) async {
        guard scenePhase == .active,
              !visibleFarms.isEmpty,
              lifecycleCoordinator.isCurrent(lease) else { return }
        let interval = PerformanceTrace.begin(
            .operationalAlerts,
            count: visibleFarms.count
        )
        defer { PerformanceTrace.end(interval) }
        do {
            // Keep alert calculation behind the first interactive frame.
            try await Task.sleep(for: .milliseconds(900))
            let actor = FarmOperationalAlertSnapshotActor(container: modelContext.container)
            for farm in visibleFarms {
                try Task.checkCancellation()
                guard lifecycleCoordinator.isCurrent(lease) else { return }
                do {
                    let snapshot = try await actor.load(farmID: farm.id)
                    try Task.checkCancellation()
                    guard lifecycleCoordinator.isCurrent(lease) else { return }
                    await notifications.rescheduleOperationalAlertDigest(snapshot)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    #if DEBUG
                    print("[OperationalAlertDigest] \(farm.id): \(error)")
                    #endif
                }
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    @MainActor
    private func refreshSystemSnapshotAfterLaunch(
        lease: AppLifecycleCoordinator.Lease
    ) async {
        guard scenePhase == .active,
              lifecycleCoordinator.isCurrent(lease) else { return }
        let systemFarms = cloudSystemFarms
        let selectedFarmID = cloudSystemSelectedFarmID
        let interval = PerformanceTrace.begin(
            .systemSnapshot,
            count: systemFarms.count
        )
        defer { PerformanceTrace.end(interval) }
        do {
            // Widget data is useful but must not compete with the first frame.
            try await Task.sleep(for: .milliseconds(1_500))
            let snapshot: FarmWidgetSnapshot
            if systemFarms.isEmpty {
                snapshot = FarmWidgetSnapshot(
                    version: FarmWidgetSnapshot.currentVersion,
                    generatedAt: .now,
                    selectedFarmID: nil,
                    farms: []
                )
            } else {
                snapshot = try await FarmSystemSnapshotActor(
                    container: modelContext.container
                ).makeSnapshot(
                    farmIDs: systemFarms.map(\.id),
                    selectedFarmID: selectedFarmID
                )
            }
            try Task.checkCancellation()
            guard lifecycleCoordinator.isCurrent(lease) else { return }
            await FarmSystemIntegrationService.publish(snapshot)

            // Spotlight indexing is the heaviest secondary launch job. Run it
            // only after the workspace has had time to become interactive.
            try await Task.sleep(for: .seconds(8))
            guard lifecycleCoordinator.isCurrent(lease) else { return }
            let spotlightSnapshot: FarmSpotlightSnapshot?
            do {
                spotlightSnapshot = try await FarmSpotlightSnapshotActor(
                    container: modelContext.container
                ).makeSnapshot(farmID: selectedFarmID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Never keep a previous farm's local index when current event
                // history cannot be assembled safely.
                await FarmSystemIntegrationService.refreshSearchIndex(nil)
                throw error
            }
            try Task.checkCancellation()
            guard lifecycleCoordinator.isCurrent(lease) else { return }
            await FarmSystemIntegrationService.refreshSearchIndex(spotlightSnapshot)
        } catch is CancellationError {
            return
        } catch {
            #if DEBUG
            print("[FarmSystemSnapshot] \(error)")
            #endif
        }
    }

    @MainActor
    private func waitForSecondaryLaunchWindow(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
