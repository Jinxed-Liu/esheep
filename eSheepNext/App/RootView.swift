import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Environment(SubscriptionService.self) private var subscription
    @Query private var accounts: [AccountProfile]
    @Query(sort: \FarmRecord.updatedAt, order: .reverse) private var farms: [FarmRecord]
    @Query private var cloudBindings: [CloudFarmBinding]
    @Query private var membershipBindings: [FarmMembershipBinding]
    @Query private var sheep: [SheepRecord]
    @Query private var pens: [PenRecord]
    @Query private var feeds: [FeedRecord]
    @Query private var outbox: [OutboxItem]
    @State private var credentialStatus: AppleCredentialStatus = .checking
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var session = session

        Group {
            if let account = activeAccount {
                switch credentialStatus {
                case .authorized, .transferred:
                    if visibleFarms.isEmpty {
                        FarmSetupView(account: account)
                    } else {
                        FarmWorkspaceView(account: account, farms: visibleFarms)
                    }
                case .checking:
                    ProgressView("正在验证 Apple 登录状态")
                case .requiresSignIn:
                    WelcomeView(reauthenticationRequired: true)
                case .unavailable(let message):
                    ContentUnavailableView("无法验证登录状态", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(message))
                }
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $session.isCreateFarmPresented) {
            if let account = activeAccount {
                CreateFarmSheet(account: account)
            }
        }
        .task(id: visibleFarms.map(\.id)) {
            session.reconcileActiveFarm(with: visibleFarms)
            session.consumePendingNavigationRequest()
            session.consumeSystemNavigationTarget()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.consumePendingNavigationRequest()
                session.consumeSystemNavigationTarget()
            } else if phase == .background {
                FarmBackgroundRefresh.schedule()
            }
        }
        .onOpenURL { url in
            guard let target = FarmSystemIntegrationService.target(from: url) else { return }
            FarmSystemNavigationStore.enqueue(target)
            session.consumeSystemNavigationTarget()
        }
        .task(id: systemSnapshotRevision) {
            let snapshot = FarmSystemIntegrationService.makeSnapshot(
                farms: visibleFarms,
                sheep: sheep,
                pens: pens,
                feeds: feeds,
                outbox: outbox,
                selectedFarmID: session.selectedFarmID
            )
            await FarmSystemIntegrationService.publish(snapshot)
        }
        .task(id: authenticationTaskID) {
            if let account = activeAccount, account.authenticationMethod == .password {
                credentialStatus = SecureAccountStore.hasWorkerSession() ? .authorized : .requiresSignIn
            } else if activeAccount != nil {
                credentialStatus = await AppleCredentialVerifier.currentStatus()
            } else {
                credentialStatus = .requiresSignIn
            }
            await collaboration.refreshAccountAvailability()
            if let account = activeAccount {
                await subscription.activate(accountID: account.effectiveAccountID)
            } else {
                subscription.reset()
            }
        }
        .task(id: foregroundCloudSyncTaskID) {
            guard scenePhase == .active,
                  CloudFeatureConfiguration.isEnabled,
                  activeAccount?.serverBindingState == .verified,
                  activeCloudBindings.contains(where: { $0.state == .active }) else { return }
            await collaboration.synchronizeNow()
        }
        .task(id: maintenanceTaskID) {
            guard let account = activeAccount, account.serverBindingState == .verified else { return }
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
        return "\(accountPart)|\(farmPart)"
    }

    private var authenticationTaskID: String {
        return "\(session.activeAccountProfileID?.uuidString ?? "none")|\(session.authenticationRevision)"
    }

    private var foregroundCloudSyncTaskID: String {
        let accountPart = activeAccount?.effectiveAccountID.uuidString ?? "none"
        let bindingPart = activeCloudBindings
            .filter { $0.state == .active }
            .map { "\($0.farmID.uuidString):\($0.updatedAt.timeIntervalSince1970)" }
            .sorted()
            .joined(separator: ",")
        let activeFarmIDs = Set(activeCloudBindings.filter { $0.state == .active }.map(\.farmID))
        let pendingPart = outbox
            .filter {
                activeFarmIDs.contains($0.farmID) &&
                    ($0.status == .pending || $0.status == .retryableFailure)
            }
            .map { $0.id.uuidString }
            .sorted()
            .joined(separator: ",")
        return "\(scenePhase)|\(accountPart)|\(bindingPart)|\(pendingPart)"
    }

    private var systemSnapshotRevision: String {
        let farmPart = visibleFarms.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        let sheepPart = sheep.filter { visibleFarmIDs.contains($0.farmID) }.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        let penPart = pens.filter { visibleFarmIDs.contains($0.farmID) }.map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        return "\(farmPart)|\(sheepPart)|\(penPart)|\(feeds.count)|\(outbox.count)|\(session.selectedFarmID?.uuidString ?? "none")"
    }

    private var visibleFarmIDs: Set<UUID> { Set(visibleFarms.map(\.id)) }
}
