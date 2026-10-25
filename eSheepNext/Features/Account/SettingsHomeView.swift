import Observation
import SwiftData
import SwiftUI
import UIKit
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
    @State private var avatarScrollController = SettingsAvatarScrollController()

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

                        if farm.role == .owner,
                           let profile = storageProfiles.first(where: { $0.farmID == farm.id }),
                           profile.mode == .eSheepCloud {
                            SettingsNavigationRow(
                                title: "牧场名称", subtitle: farm.name,
                                systemImage: "pencil.line", iconColor: .green
                            ) {
                                FarmNameSettingsView(farm: farm, generation: profile.authorityGeneration)
                            }
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
            .background {
                if #available(iOS 18, *) {
                    EmptyView()
                } else {
                    SettingsAvatarLegacyScrollObserver(
                        motion: avatarMotion,
                        hasImage: account.avatarImageData != nil,
                        resetRevision: avatarScrollController.legacyResetRevision
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .scrollIndicators(.hidden)
        .compatibilityScrollEdgeHidden(true, for: .top)
        .onGeometryChange(for: CGPoint.self) { geometry in
            geometry.frame(in: .global).origin
        } action: { origin in
            // Measure the stationary viewport. Combining the moving header's
            // frame with a separately delivered scroll offset feeds transient
            // drag displacement back into header height and cancels the pull.
            avatarMotion.updateContentOrigin(origin)
        }
        // Measure inside this modifier: its outer layout still starts below
        // the navigation safe area even though the scroll viewport fills it.
        .ignoresSafeArea(.container, edges: .top)
        .background(AppTheme.pageBackground)
        .modifier(SettingsAvatarScrollTrackingModifier(
            motion: avatarMotion,
            hasImage: account.avatarImageData != nil,
            controller: avatarScrollController
        ))
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
                        avatarScrollController.resetToTop()
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
        .compatibilityToolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .modifier(SettingsAvatarToolbarModifier(
            account: account, titleProgress: avatarMotion.titleProgress
        ))
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
            avatarScrollController.resetToTop()
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

private struct SettingsAvatarToolbarModifier: ViewModifier {
    let account: AccountProfile
    let titleProgress: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    navigationTitlePlaceholder
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarItem(placement: .confirmationAction) {
                    editAccountLink
                }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    navigationTitlePlaceholder
                }

                ToolbarItem(placement: .confirmationAction) {
                    editAccountLink
                }
            }
        }
    }

    private var navigationTitlePlaceholder: some View {
        // The overlay renders the name into its locked position; this supplies
        // the semantic navigation title without drawing it a second time.
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(account.displayName)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHidden(titleProgress < 0.8)
    }

    private var editAccountLink: some View {
        NavigationLink {
            AccountDisplayNameEditor(account: account)
        } label: {
            Text("编辑")
        }
    }
}

/// Keeps new-system scroll commands in the caller's original transaction while
/// avoiding an iOS 18-only stored type in the iOS 17 view.
@MainActor
@Observable
private final class SettingsAvatarScrollController {
    private(set) var legacyResetRevision = 0
    @ObservationIgnored private let modernStateStorage: Any?

    init() {
        if #available(iOS 18, *) {
            modernStateStorage = SettingsAvatarModernScrollState()
        } else {
            modernStateStorage = nil
        }
    }

    @available(iOS 18, *)
    var modernState: SettingsAvatarModernScrollState {
        guard let state = modernStateStorage as? SettingsAvatarModernScrollState else {
            preconditionFailure("Modern scroll state requires iOS 18")
        }
        return state
    }

    func resetToTop() {
        if #available(iOS 18, *) {
            modernState.position.scrollTo(edge: .top)
        } else {
            legacyResetRevision += 1
        }
    }
}

@available(iOS 18, *)
@MainActor
@Observable
private final class SettingsAvatarModernScrollState {
    // ObjC class enumeration can realize this class even on iOS 17. Keep the
    // stored layout free of newer SwiftUI types; availability guards callers.
    @ObservationIgnored private var positionStorage: Any

    init() {
        positionStorage = ScrollPosition(edge: .top)
    }

    var position: ScrollPosition {
        get {
            access(keyPath: \.position)
            return positionStorage as! ScrollPosition
        }
        set {
            let previous = positionStorage as! ScrollPosition
            guard shouldNotifyObservers(previous, newValue) else {
                positionStorage = newValue
                return
            }
            withMutation(keyPath: \.position) {
                positionStorage = newValue
            }
        }
        _modify {
            access(keyPath: \.position)
            _$observationRegistrar.willSet(self, keyPath: \.position)
            var value = positionStorage as! ScrollPosition
            defer {
                positionStorage = value
                _$observationRegistrar.didSet(self, keyPath: \.position)
            }
            yield &value
        }
    }
}

@MainActor
private struct SettingsAvatarScrollTrackingModifier: ViewModifier {
    let motion: AccountAvatarMotionCoordinator
    let hasImage: Bool
    let controller: SettingsAvatarScrollController

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.modifier(SettingsAvatarModernScrollTrackingModifier(
                motion: motion, hasImage: hasImage, state: controller.modernState
            ))
        } else {
            content
        }
    }
}

@available(iOS 18, *)
@MainActor
private struct SettingsAvatarModernScrollTrackingModifier: ViewModifier {
    let motion: AccountAvatarMotionCoordinator
    let hasImage: Bool
    @Bindable var state: SettingsAvatarModernScrollState

    func body(content: Content) -> some View {
        content
            .scrollPosition($state.position)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offsetY in
                motion.updateScroll(offsetY: offsetY, hasImage: hasImage)
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                let isDragging = newPhase == .tracking || newPhase == .interacting
                let wasDragging = oldPhase == .tracking || oldPhase == .interacting
                if isDragging {
                    motion.beginDragging()
                } else if wasDragging {
                    motion.endDragging()
                }
            }
    }
}

/// Observes the existing scroll view on iOS 17, leaving its delegate and
/// gesture recognition intact so pulling the avatar behaves like native scroll.
@MainActor
private struct SettingsAvatarLegacyScrollObserver: UIViewRepresentable {
    let motion: AccountAvatarMotionCoordinator
    let hasImage: Bool
    let resetRevision: Int

    func makeUIView(context: Context) -> SettingsAvatarLegacyScrollObserverUIView {
        let view = SettingsAvatarLegacyScrollObserverUIView(frame: .zero)
        view.configure(motion: motion, hasImage: hasImage, resetRevision: resetRevision)
        return view
    }

    func updateUIView(_ uiView: SettingsAvatarLegacyScrollObserverUIView, context: Context) {
        uiView.configure(motion: motion, hasImage: hasImage, resetRevision: resetRevision)
    }

    static func dismantleUIView(_ uiView: SettingsAvatarLegacyScrollObserverUIView, coordinator: ()) {
        uiView.invalidate()
    }
}

@MainActor
private final class SettingsAvatarLegacyScrollObserverUIView: UIView {
    private weak var scrollView: UIScrollView?
    private var motion: AccountAvatarMotionCoordinator?
    private var hasImage = false
    private var lastResetRevision: Int?
    private var needsReset = false
    private var isDragging = false
    private var lastReportedOffsetY: CGFloat?
    private var lastReportedHasImage: Bool?
    private var offsetObservation: NSKeyValueObservation?
    private var pendingUpdate: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(motion: AccountAvatarMotionCoordinator, hasImage: Bool, resetRevision: Int) {
        if self.motion !== motion {
            lastReportedOffsetY = nil
            lastReportedHasImage = nil
        }
        self.motion = motion
        self.hasImage = hasImage
        if let lastResetRevision, lastResetRevision != resetRevision {
            needsReset = true
        }
        lastResetRevision = resetRevision
        refreshAttachment()
        scheduleUpdate()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        refreshAttachment()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            detach()
        } else {
            refreshAttachment()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshAttachment()
        scheduleUpdate()
    }

    private func refreshAttachment() {
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let candidate = view as? UIScrollView {
                guard scrollView !== candidate else { return }
                detach()
                scrollView = candidate
                offsetObservation = candidate.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.scheduleUpdate()
                    }
                }
                candidate.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                scheduleUpdate()
                return
            }
            ancestor = view.superview
        }
    }

    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        let dragging = recognizer.state == .began || recognizer.state == .changed
        if dragging && !isDragging {
            motion?.beginDragging()
        } else if !dragging && isDragging {
            // Deliver the final pull offset while this drag is still eligible.
            reportOffset()
            motion?.endDragging()
        }
        isDragging = dragging
    }

    private func scheduleUpdate() {
        guard scrollView != nil else { return }
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, let scrollView = self.scrollView else { return }
            self.pendingUpdate = nil
            if self.needsReset {
                self.needsReset = false
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: -scrollView.adjustedContentInset.top),
                    animated: false
                )
            }
            self.reportOffset()
        }
    }

    private func reportOffset() {
        guard let scrollView else { return }
        let offsetY = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        guard lastReportedOffsetY != offsetY || lastReportedHasImage != hasImage else { return }
        lastReportedOffsetY = offsetY
        lastReportedHasImage = hasImage
        motion?.updateScroll(offsetY: offsetY, hasImage: hasImage)
    }

    private func detach() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        offsetObservation?.invalidate()
        offsetObservation = nil
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
        scrollView = nil
        lastReportedOffsetY = nil
        lastReportedHasImage = nil
        if isDragging { motion?.endDragging() }
        isDragging = false
    }

    func invalidate() {
        detach()
        motion = nil
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
