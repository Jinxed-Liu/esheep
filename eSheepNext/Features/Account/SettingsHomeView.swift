import SwiftData
import SwiftUI
import UserNotifications

struct SettingsHomeView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(FarmNotificationService.self) private var notifications
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse) private var conflicts: [SyncConflictRecord]
    @Query(sort: \ESheepCloudAttentionItem.createdAt, order: .reverse)
    private var cloudAttentionItems: [ESheepCloudAttentionItem]
    @Query private var storageProfiles: [FarmStorageProfile]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var avatarMotion = AccountAvatarMotionCoordinator()
    @State private var isEditingAvatar = false
    @State private var avatarScrollPosition = ScrollPosition(edge: .top)

    private var unresolvedConflictCount: Int {
        conflicts.count {
            $0.farmID == farm.id
                && ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue
                    || $0.statusRawValue == SyncConflictStatus.quarantined.rawValue)
        }
    }

    private var cloudAttentionCount: Int {
        cloudAttentionItems.count {
            $0.farmID == farm.id &&
                ($0.state == .open || $0.state == .resolving)
        }
    }

    private var pendingDecisionCount: Int {
        switch storageMode {
        case .eSheepCloud:
            cloudAttentionCount
        case .supabase:
            // Migration-aware: surface V2 attention items for a legacy-profile
            // farm when present.
            cloudAttentionCount
        case .localOnly, .retiredAppleCloud:
            unresolvedConflictCount
        }
    }

    private var policy: SettingsVisibilityPolicy {
        SettingsVisibilityPolicy(
            role: farm.role,
            cloudEnabled: ESheepCloudAvailability.isConfigured,
            subscriptionEnabled: SubscriptionFeatureConfiguration.isEnabled,
            unresolvedConflictCount: pendingDecisionCount
        )
    }

    private var storageMode: FarmStorageMode {
        storageProfiles.first(where: { $0.farmID == farm.id })?.mode ?? .localOnly
    }

    private var avatarAnimationsEnabled: Bool {
        preferences.avatarMotionEnabled
            && !preferences.shouldReduceMotion
            && !systemReduceMotion
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SettingsAvatarHeader(
                    account: account,
                    farm: farm,
                    motion: avatarMotion,
                    expansion: avatarMotion.expansion,
                    onTap: openAvatar,
                    onEdit: { isEditingAvatar = true }
                )

                LazyVStack(spacing: 20) {
                    AccountAccessNoticeCard(
                        authenticationMethod: account.authenticationMethod
                    )

                    SettingsCard(title: "账户") {
                        SettingsNavigationRow(
                            title: "名称",
                            subtitle: account.displayName,
                            systemImage: "person.text.rectangle",
                            iconColor: .blue
                        ) {
                            AccountDisplayNameEditor(account: account)
                        }
                        SettingsCardDivider()
                        AccountAccessSettingsRow(
                            authenticationMethod: account.authenticationMethod
                        )

                        if policy.shows(.subscription) {
                            SettingsCardDivider()
                            SettingsNavigationRow(
                                title: "订阅与购买",
                                subtitle: "方案、权益与购买记录",
                                systemImage: "star.fill",
                                iconColor: .orange
                            ) {
                                SubscriptionSettingsView(account: account)
                            }
                        }
                    }

                    SettingsCard(title: "当前牧场") {
                        if farm.role == .owner {
                            SettingsNavigationRow(
                                title: "eSheep+ 云",
                                subtitle: cloudStorageSubtitle,
                                systemImage: "externaldrive.connected.to.line.below",
                                iconColor: .teal
                            ) {
                                FarmCloudStorageSettingsView(account: account, farm: farm)
                            }
                        }

                        if farm.role == .owner, policy.shows(.farmLocation) {
                            SettingsCardDivider()
                        }

                        if policy.shows(.farmLocation) {
                            SettingsNavigationRow(
                                title: "牧场位置",
                                subtitle: farm.locationSnapshot?.displayName ?? "尚未设置",
                                systemImage: "location.fill",
                                iconColor: .cyan
                            ) {
                                FarmLocationSettingsView(account: account, farm: farm)
                            }
                        }

                        if policy.shows(.farmLocation), policy.shows(.membersAndSharing) {
                            SettingsCardDivider()
                        }

                        if policy.shows(.membersAndSharing) {
                            SettingsNavigationRow(
                                title: "成员与共享",
                                subtitle: farm.role == .owner ? "邀请并管理牧场成员" : "查看牧场成员",
                                systemImage: "person.2.fill",
                                iconColor: .indigo
                            ) {
                                FarmMembersAndSharingView(account: account, farm: farm)
                            }
                        }
                    }

                    SettingsCard(title: "偏好设置") {
                        SettingsNavigationRow(
                            title: "小组件", subtitle: "组件库、圈舍与批次、独立配置",
                            systemImage: "square.grid.2x2.fill", iconColor: .green
                        ) {
                            FarmWidgetSettingsView(farm: farm)
                        }
                        SettingsCardDivider()
                        SettingsNavigationRow(
                            title: "通知",
                            subtitle: notificationStatusText,
                            systemImage: "bell.fill",
                            iconColor: .red
                        ) {
                            SystemServicesSettingsView(farm: farm)
                        }
                        SettingsCardDivider()
                        SettingsNavigationRow(
                            title: "数据与存储",
                            subtitle: dataStorageSubtitle,
                            systemImage: "internaldrive.fill",
                            iconColor: .green
                        ) {
                            FarmDataInterchangeView(account: account, farm: farm)
                        }
                        SettingsCardDivider()
                        SettingsNavigationRow(
                            title: "外观",
                            subtitle: preferences.appearance.displayName,
                            systemImage: "paintbrush.fill",
                            iconColor: .blue
                        ) {
                            AppearanceSettingsView(account: account)
                        }
                        SettingsCardDivider()
                        SettingsNavigationRow(
                            title: "省电",
                            subtitle: preferences.effectivePowerSavingEnabled ? "已开启" : "标准模式",
                            systemImage: "battery.75percent",
                            iconColor: .yellow
                        ) {
                            PowerSavingSettingsView()
                        }
                        SettingsCardDivider()
                        SettingsNavigationRow(
                            title: "语言",
                            subtitle: preferences.language.displayName,
                            systemImage: "globe",
                            iconColor: .purple
                        ) {
                            LanguageSettingsView()
                        }
                    }

                    SettingsCard(title: "AI 与隐私") {
                        SettingsNavigationRow(
                            title: "AI 助手",
                            subtitle: "API Key、数据使用与加密同步",
                            systemImage: "sparkles",
                            iconColor: .blue
                        ) {
                            InsightAssistantSettingsView(account: account, farm: farm)
                        }
                        SettingsCardDivider()
                        SettingsNavigationRow(
                            title: "隐私与条款",
                            subtitle: "条款、隐私与数据使用说明",
                            systemImage: "hand.raised.fill",
                            iconColor: .gray
                        ) {
                            PrivacyAndTermsSettingsView(account: account)
                        }
                    }

                    SettingsCard(title: "账户操作") {
                        SettingsActionContainer {
                            AccountSignOutButton()
                        }
                        SettingsCardDivider(leading: 16)
                        SettingsActionContainer {
                            AccountDeletionButton(account: account)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20 + 16 * avatarMotion.expansion)
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .scrollPosition($avatarScrollPosition)
        .background(AppTheme.pageBackground)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offsetY in
            avatarMotion.updateScroll(offsetY: offsetY, hasImage: account.avatarImageData != nil)
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            let isDragging = newPhase == .tracking || newPhase == .interacting
            let wasDragging = oldPhase == .tracking || oldPhase == .interacting
            if isDragging {
                avatarMotion.beginDragging()
            } else if wasDragging {
                avatarMotion.endDragging()
            }
        }
        .overlay {
            SettingsAvatarOverlay(
                account: account,
                farm: farm,
                motion: avatarMotion,
                expansion: avatarMotion.expansion
            )
            // The scroll-content button owns the native pull gesture and accessibility;
            // the photo overlay supplies the current image bounds to the gallery.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .sensoryFeedback(.impact(weight: .medium, intensity: 1), trigger: avatarMotion.expansionFeedback)
            .sensoryFeedback(.selection, trigger: avatarMotion.collapseFeedback)
            .sensoryFeedback(.impact(weight: .medium, intensity: 1), trigger: avatarMotion.viewerFeedback)
        }
        .onChange(of: avatarAnimationsEnabled, initial: true) { _, enabled in
            avatarMotion.configure(animationsEnabled: enabled)
        }
        .background {
            AccountAvatarGalleryPresenter(
                isPresented: avatarMotion.isViewerPresented,
                account: account,
                reduceMotion: !avatarAnimationsEnabled,
                initialImage: avatarMotion.previewImage,
                initialDigest: avatarMotion.previewDigest,
                sourceProvider: { avatarMotion.rendererSourceProvider?() },
                onSourceVisibilityChange: { avatarMotion.setSourceHidden($0) },
                onPresented: {
                    guard avatarMotion.isViewerPresented,
                          avatarMotion.interaction.presentation == .presenting else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        avatarScrollPosition.scrollTo(edge: .top)
                        avatarMotion.viewerDidPresent()
                    }
                },
                onClose: { closeAvatarViewer() },
                onEdit: { closeAvatarViewer(editAvatar: true) },
                onDismiss: {
                    if avatarMotion.viewerDidDismiss() {
                        isEditingAvatar = true
                    }
                }
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .navigationDestination(isPresented: $isEditingAvatar) {
            AccountAvatarSettingsView(account: account)
        }
        .onDisappear {
            avatarMotion.resetIfNotPresenting()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // The overlay renders the same name all the way into its
                // locked position. Reserve only a semantic navigation title.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(account.displayName)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHidden(avatarMotion.titleProgress < 0.8)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .confirmationAction) {
                NavigationLink {
                    AccountDisplayNameEditor(account: account)
                } label: {
                    Text("编辑")
                }
            }
        }
        .task {
            await notifications.refreshAuthorizationStatus()
        }
    }

    private var cloudStorageSubtitle: String {
        switch storageMode {
        case .localOnly: "仅保存在此设备"
        case .retiredAppleCloud: "旧云存储已停用"
        case .eSheepCloud:
            cloudAttentionCount > 0
                ? "\(cloudAttentionCount) 项需要你确认"
                : "当前使用 eSheep+ 云"
        case .supabase: "当前使用 eSheep+ 云"
        }
    }

    private var dataStorageSubtitle: String {
        if storageMode == .eSheepCloud, cloudAttentionCount > 0 {
            return "有 \(cloudAttentionCount) 项内容需要确认"
        }
        if storageMode == .supabase {
            return "准备 eSheep+ 云"
        }
        if storageMode != .eSheepCloud, policy.shows(.dataConflicts) {
            return "有待处理的数据异常"
        }
        return "空间占用、导入导出与备份"
    }

    private func closeAvatarViewer(editAvatar: Bool = false) {
        guard avatarMotion.isViewerPresented else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            avatarScrollPosition.scrollTo(edge: .top)
            avatarMotion.requestDismissal(editAvatar: editAvatar)
        }
    }

    private func openAvatar() {
        if account.avatarImageData == nil {
            isEditingAvatar = true
        } else {
            avatarMotion.tapAvatar()
        }
    }

    private var notificationStatusText: String {
        switch notifications.authorizationStatus {
        case .notDetermined: "尚未设置"
        case .denied: "已关闭"
        case .authorized: "已开启"
        case .provisional: "已临时开启"
        case .ephemeral: "当前会话已开启"
        @unknown default: "查看通知设置"
        }
    }
}

private struct SettingsActionContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            content()
            Spacer()
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 16)
        .contentShape(.rect)
    }
}
