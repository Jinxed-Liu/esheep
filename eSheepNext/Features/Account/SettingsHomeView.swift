import SwiftData
import SwiftUI
import UserNotifications

struct SettingsHomeView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(FarmNotificationService.self) private var notifications
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse) private var conflicts: [SyncConflictRecord]
    @Query private var storageProfiles: [FarmStorageProfile]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var scrollOffset: CGFloat = 0
    @State private var scrollOrigin: CGFloat?
    @State private var hasScrollInteraction = false

    private var unresolvedConflictCount: Int {
        conflicts.count {
            $0.farmID == farm.id
                && ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue
                    || $0.statusRawValue == SyncConflictStatus.quarantined.rawValue)
        }
    }

    private var policy: SettingsVisibilityPolicy {
        SettingsVisibilityPolicy(
            role: farm.role,
            cloudEnabled: CloudFeatureConfiguration.isEnabled ||
                SupabaseAccountConfiguration.isConfigured,
            subscriptionEnabled: SubscriptionFeatureConfiguration.isEnabled,
            unresolvedConflictCount: unresolvedConflictCount
        )
    }

    private var collapseProgress: CGFloat {
        min(max(scrollOffset / 94, 0), 1)
    }

    private var avatarMotionProgress: CGFloat {
        guard hasScrollInteraction else { return 0 }
        guard preferences.avatarMotionEnabled,
              !preferences.shouldReduceMotion,
              !systemReduceMotion else {
            return scrollOffset >= 76 ? 1 : 0
        }
        return collapseProgress
    }

    private var pullScale: CGFloat {
        guard preferences.avatarMotionEnabled,
              !preferences.shouldReduceMotion,
              !systemReduceMotion else { return 1 }
        return 1 + min(max(-scrollOffset, 0) / 700, 0.08)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                accountHeader

                AccountAccessNoticeCard(
                    authenticationMethod: account.authenticationMethod
                )

                SettingsCard(title: "账户") {
                    avatarRow
                    SettingsCardDivider()
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
                            title: "云存储",
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
                        subtitle: policy.shows(.dataConflicts)
                            ? "\(unresolvedConflictCount) 项数据需要处理"
                            : "空间占用、导入导出与备份",
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
                        PrivacyAndTermsSettingsView()
                    }
                }

                SettingsCard(title: "账户操作") {
                    SettingsActionContainer {
                        AccountSignOutButton()
                    }
                    if AccountIdentityClients.activeProvider != .supabase {
                        SettingsCardDivider(leading: 16)
                        SettingsActionContainer {
                            AccountDeletionButton(account: account)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.pageBackground)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, newValue in
            guard hasScrollInteraction else {
                scrollOrigin = newValue
                scrollOffset = 0
                return
            }
            if let scrollOrigin {
                scrollOffset = newValue - scrollOrigin
            } else {
                scrollOrigin = newValue
                scrollOffset = 0
            }
        }
        .onScrollPhaseChange { _, newPhase, context in
            guard !hasScrollInteraction,
                  newPhase == .tracking || newPhase == .interacting else {
                return
            }
            let geometry = context.geometry
            scrollOrigin =
                geometry.contentOffset.y + geometry.contentInsets.top
            scrollOffset = 0
            hasScrollInteraction = true
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    AccountAvatarView(account: account, size: 28)
                    Text(account.displayName)
                        .font(.headline)
                        .lineLimit(1)
                }
                .opacity(avatarMotionProgress)
                .offset(y: (1 - avatarMotionProgress) * 7)
                .accessibilityHidden(avatarMotionProgress < 0.8)
            }

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
        switch storageProfiles.first(where: { $0.farmID == farm.id })?.mode ?? .localOnly {
        case .localOnly: "仅本机，可选择 iCloud 或 Supabase"
        case .iCloud: "当前使用 iCloud"
        case .supabase: "当前使用 Supabase 云"
        }
    }

    private var accountHeader: some View {
        VStack(spacing: 11) {
            NavigationLink {
                AccountAvatarSettingsView(account: account)
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    AccountAvatarView(account: account, size: 104)
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.85), lineWidth: 3)
                        }
                        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)

                    Image(systemName: "camera.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(AppTheme.brand, in: .circle)
                        .overlay { Circle().stroke(.background, lineWidth: 3) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑头像")

            VStack(spacing: 4) {
                Text(account.displayName)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text("\(farm.name) · \(farm.role.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        .scaleEffect(pullScale)
        .scaleEffect(1 - avatarMotionProgress * 0.06)
        .opacity(1 - avatarMotionProgress * 0.28)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private var avatarRow: some View {
        NavigationLink {
            AccountAvatarSettingsView(account: account)
        } label: {
            SettingsRowContent(
                title: "头像",
                subtitle: account.avatarImageData == nil ? "选择一个头像" : "查看或更换头像",
                systemImage: "person.crop.circle.fill",
                iconColor: .teal
            )
        }
        .buttonStyle(.plain)
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

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            VStack(spacing: 0) {
                content()
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .clipShape(.rect(cornerRadius: 18))
        }
    }
}

private struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let iconColor: Color
    @ViewBuilder let destination: () -> Destination

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        iconColor: Color,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRowContent(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRowContent: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let iconColor: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(iconColor.gradient, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

private struct SettingsCardDivider: View {
    var leading: CGFloat = 57

    var body: some View {
        Divider()
            .padding(.leading, leading)
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
