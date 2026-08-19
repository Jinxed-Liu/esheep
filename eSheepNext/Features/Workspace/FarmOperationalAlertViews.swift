import SwiftData
import SwiftUI

enum FarmOperationalAlertLoadState: Equatable {
    case loading
    case loaded(FarmOperationalAlertSnapshot)
    case failed(String)
}

private enum FarmOperationalAlertRulesPresentation: String, Identifiable {
    case initial
    case settings

    var id: String { rawValue }
    var requiresConfiguration: Bool { self == .initial }
}

extension FarmOperationalAlertSnapshot {
    func count(for kind: FarmOperationalAlertKind) -> Int {
        operationalAlerts.count { $0.kind == kind }
    }
}

struct FarmOperationalAlertHomeCard: View {
    let state: FarmOperationalAlertLoadState
    let canManageRules: Bool
    let onOpen: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("待办与异常")
                .font(.headline)

            switch state {
            case .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("正在计算")
                            .foregroundStyle(.primary)
                        Text("正在后台核对业务事实与逾期日程。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: .rect(cornerRadius: 16))

            case .failed:
                VStack(alignment: .leading, spacing: 10) {
                    StatusRow(
                        title: "暂时无法计算",
                        detail: "未用 0 项掩盖错误，请重试。",
                        symbol: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    Button("重新计算", systemImage: "arrow.clockwise", action: onRetry)
                        .buttonStyle(.bordered)
                }

            case .loaded(let snapshot):
                Button(action: onOpen) {
                    loadedContent(snapshot)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func loadedContent(_ snapshot: FarmOperationalAlertSnapshot) -> some View {
        if !snapshot.isConfigured {
            StatusRow(
                title: "尚未配置异常规则",
                detail: canManageRules
                    ? "需先设置断奶日龄、提前预警天数、孕检天数与每日汇总时间。"
                    : "等待牧场主或管理员完成设置。",
                symbol: "exclamationmark.triangle.fill"
            )
        } else {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.totalPendingCount == 0 ? LocalizedStringKey("全部正常") : LocalizedStringKey("\(snapshot.totalPendingCount) 项待处理"))
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    categorySummary(snapshot)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: snapshot.totalPendingCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(snapshot.totalPendingCount == 0 ? .green : .orange)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: .rect(cornerRadius: 16))
        }
    }

    private func categorySummary(_ snapshot: FarmOperationalAlertSnapshot) -> Text {
        let weaningCount = snapshot.count(for: .weaningDueSoon) + snapshot.count(for: .weaningOverdue)
        let pregnancyCount = snapshot.count(for: .pregnancyCheckDueSoon) + snapshot.count(for: .pregnancyCheckOverdue)
        let tmrCount = snapshot.count(for: .tmrNotFed) + snapshot.count(for: .tmrLow) + snapshot.count(for: .tmrHigh)
        return Text("断奶 \(weaningCount) · 孕检 \(pregnancyCount) · TMR \(tmrCount) · 圈舍 \(snapshot.count(for: .invalidPen)) · 日程 \(snapshot.overdueReminders.count)")
    }
}

struct FarmOperationalAlertCenterView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FarmNotificationService.self) private var notifications

    let account: AccountProfile
    let farm: FarmRecord
    private let commandService = FarmCommandService()
    @State private var loadState: FarmOperationalAlertLoadState = .loading
    @State private var refreshRevision = 0
    @State private var rulesPresentation: FarmOperationalAlertRulesPresentation?
    @State private var selectedDeferralAlert: FarmOperationalAlert?
    @State private var errorMessage: String?

    private var canManageRules: Bool { CapabilitySet(role: farm.role).allows(.manageCatalogs) }
    private var canDefer: Bool { CapabilitySet(role: farm.role).allows(.recordProduction) }
    private var taskID: String { "\(farm.id.uuidString):\(refreshRevision)" }

    var body: some View {
        content
        .background(AppTheme.pageBackground)
        .navigationTitle("待办与异常")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManageRules {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("提醒与异常规则", systemImage: "gearshape") {
                        rulesPresentation = .settings
                    }
                    .accessibilityLabel("提醒与异常规则")
                }
            }
        }
        .task(id: taskID) { await loadSnapshot() }
        .onReceive(NotificationCenter.default.publisher(for: FarmOperationalAlertRuntimeNotification.refreshRequested)) { notification in
            guard FarmOperationalAlertRuntimeNotification.farmID(from: notification) == farm.id else { return }
            refreshRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudRuntimeNotification.syncWake)) { notification in
            guard CloudRuntimeNotification.farmID(from: notification) == farm.id else { return }
            refreshRevision &+= 1
        }
        .sheet(item: $rulesPresentation) { presentation in
            NavigationStack {
                FarmOperationalAlertRulesView(
                    account: account,
                    farm: farm,
                    requiresConfiguration: presentation.requiresConfiguration,
                    showsCancelButton: true
                ) {
                    rulesPresentation = nil
                    refreshRevision &+= 1
                }
            }
            .interactiveDismissDisabled(presentation.requiresConfiguration)
        }
        .confirmationDialog(
            "暂缓此异常",
            isPresented: Binding(
                get: { selectedDeferralAlert != nil },
                set: { if !$0 { selectedDeferralAlert = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("暂缓 1 天") { deferSelectedAlert(days: 1) }
            Button("暂缓 3 天") { deferSelectedAlert(days: 3) }
            Button("暂缓 7 天") { deferSelectedAlert(days: 7) }
            Button("取消", role: .cancel) { selectedDeferralAlert = nil }
        } message: {
            Text("暂缓会同步到全牧场；业务事实闭环后会立即消失。")
        }
        .recordErrorAlert($errorMessage)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ScrollView {
                SettingsCard(title: "状态") {
                    SettingsRowContent(
                        title: "正在计算",
                        subtitle: "正在后台核对业务事实与逾期日程。",
                        systemImage: "hourglass",
                        iconColor: .blue,
                        showsChevron: false
                    )
                }
                .padding(16)
            }

        case .failed(let message):
            ScrollView {
                SettingsCard(title: "状态") {
                    SettingsRowContent(
                        title: "暂时无法计算",
                        subtitle: message,
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                        iconColor: .red,
                        showsChevron: false
                    )
                    SettingsCardDivider()
                    SettingsActionRow(
                        title: "重新计算",
                        subtitle: "再次读取当前牧场数据",
                        systemImage: "arrow.clockwise",
                        iconColor: .blue,
                        showsChevron: false
                    ) {
                        refreshRevision &+= 1
                    }
                }
                .padding(16)
            }

        case .loaded(let snapshot):
            if !snapshot.isConfigured {
                unconfiguredContent
            } else {
                configuredList(snapshot)
            }
        }
    }

    private var unconfiguredContent: some View {
        ScrollView {
            SettingsCard(title: "状态") {
                SettingsRowContent(
                    title: canManageRules ? "需要先设置规则" : "等待规则设置",
                    subtitle: canManageRules
                        ? "填写断奶日龄、提前预警天数，确认孕检天数和每日汇总时间后，系统才会开始计算。"
                        : "等待牧场主或管理员完成提醒与异常规则设置。",
                    systemImage: "exclamationmark.triangle.fill",
                    iconColor: .orange,
                    showsChevron: false
                )
                if canManageRules {
                    SettingsCardDivider()
                    SettingsActionRow(
                        title: "开始设置",
                        subtitle: "配置规则后启用待办计算",
                        systemImage: "slider.horizontal.3",
                        iconColor: .blue
                    ) {
                        rulesPresentation = .initial
                    }
                }
            }
            .padding(16)
        }
    }

    private func configuredList(_ snapshot: FarmOperationalAlertSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                SettingsCard(title: "业务预警与异常") {
                    if snapshot.operationalAlerts.isEmpty {
                        SettingsRowContent(
                            title: "没有业务预警或异常",
                            subtitle: "当前业务事实均符合已设置的规则",
                            systemImage: "checkmark.circle.fill",
                            iconColor: .green,
                            showsChevron: false
                        )
                    } else {
                        ForEach(Array(snapshot.operationalAlerts.enumerated()), id: \.element.id) { index, alert in
                            if index > 0 { SettingsCardDivider() }
                            HStack(spacing: 0) {
                                NavigationLink {
                                    destination(for: alert)
                                } label: {
                                    operationalAlertRow(alert, snapshot: snapshot)
                                }
                                .buttonStyle(.plain)

                                if canDefer && !alert.kind.isTMR {
                                    Button {
                                        selectedDeferralAlert = alert
                                    } label: {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.orange)
                                            .frame(width: 44, height: 48)
                                            .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("暂缓此异常")
                                }
                            }
                        }
                    }
                }

                SettingsCard(title: "逾期日程") {
                    if snapshot.overdueReminders.isEmpty {
                        SettingsRowContent(
                            title: "没有逾期日程",
                            subtitle: "所有日程均已完成或尚未到期",
                            systemImage: "checkmark.circle.fill",
                            iconColor: .green,
                            showsChevron: false
                        )
                    } else {
                        ForEach(Array(snapshot.overdueReminders.enumerated()), id: \.element.id) { index, reminder in
                            if index > 0 { SettingsCardDivider() }
                            SettingsNavigationRow(
                                title: reminder.title,
                                subtitle: "到期：\(reminder.dueAt.formatted(.dateTime.year().month().day().hour().minute()))",
                                systemImage: "calendar.badge.exclamationmark",
                                iconColor: .red
                            ) {
                                CareReminderCenterView(
                                    account: account,
                                    farm: farm,
                                    focusedReminderID: reminder.id
                                )
                            }
                        }
                    }
                }

                if snapshot.missingBirthDateCount > 0 {
                    SettingsCard(title: "覆盖说明") {
                        SettingsRowContent(
                            title: "有 \(snapshot.missingBirthDateCount) 只羊缺少出生日期",
                            subtitle: "这些羊只不会参与断奶日龄判断，也不会被误报为异常。",
                            systemImage: "info.circle.fill",
                            iconColor: .blue,
                            showsChevron: false
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshable { await loadSnapshot() }
    }

    private func operationalAlertRow(
        _ alert: FarmOperationalAlert,
        snapshot: FarmOperationalAlertSnapshot
    ) -> some View {
        HStack(alignment: .center, spacing: 13) {
            SettingsIcon(systemImage: alert.kind.symbol, color: .orange)
            VStack(alignment: .leading, spacing: 3) {
                alertTitleText(alert)
                    .font(.headline)
                    .foregroundStyle(.primary)
                alertDetailText(alert, snapshot: snapshot)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                deadlineText(alert, snapshot: snapshot)
                    .font(.caption)
                    .foregroundStyle(alert.kind.isDueSoon ? Color.orange : Color.red)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 56)
        .padding(.leading, 14)
        .padding(.vertical, 6)
        .contentShape(.rect)
    }

    private func alertTitleText(_ alert: FarmOperationalAlert) -> Text {
        switch alert.kind {
        case .weaningDueSoon:
            return Text("\(alert.earTag) · 断奶即将到期")
        case .weaningOverdue:
            return Text("\(alert.earTag) · 超龄未断奶")
        case .pregnancyCheckDueSoon:
            return Text("\(alert.earTag) · 孕检即将到期")
        case .pregnancyCheckOverdue:
            return Text("\(alert.earTag) · 配种后逾期未孕检")
        case .invalidPen:
            return Text("\(alert.earTag) · 未分有效圈舍")
        case .tmrNotFed:
            return Text("\(alert.earTag) · TMR 未投喂")
        case .tmrLow:
            return Text("\(alert.earTag) · TMR 投喂偏低")
        case .tmrHigh:
            return Text("\(alert.earTag) · TMR 投喂偏高")
        }
    }

    private func alertDetailText(
        _ alert: FarmOperationalAlert,
        snapshot: FarmOperationalAlertSnapshot
    ) -> Text {
        switch alert.kind {
        case .weaningOverdue:
            return Text("已达到 \(snapshot.rule?.weaningAgeDays ?? 0) 日龄，尚无有效断奶记录。")
        case .weaningDueSoon:
            let days = alert.daysUntilDue(
                now: snapshot.generatedAt,
                timeZoneIdentifier: snapshot.timeZoneIdentifier
            )
            return Text("将在 \(days) 天后达到 \(snapshot.rule?.weaningAgeDays ?? 0) 日龄，尚无有效断奶记录。")
        case .pregnancyCheckOverdue:
            return Text("配种后已达到 \(snapshot.rule?.pregnancyCheckDays ?? 0) 天，尚无后续孕检、流产或产羔记录。")
        case .pregnancyCheckDueSoon:
            let days = alert.daysUntilDue(
                now: snapshot.generatedAt,
                timeZoneIdentifier: snapshot.timeZoneIdentifier
            )
            return Text("还有 \(days) 天到孕检期限，尚无后续孕检、流产或产羔记录。")
        case .invalidPen:
            if alert.detail == "当前在场羊只尚未分圈。" {
                return Text("当前在场羊只尚未分圈。")
            }
            return Text("当前圈舍已停用、删除或引用失效。")
        case .tmrNotFed, .tmrLow, .tmrHigh:
            guard let meal = alert.tmrMeal,
                  let target = alert.tmrTargetText else {
                return Text(verbatim: alert.detail)
            }
            let mealName = String(localized: String.LocalizationValue(meal.displayName))
            switch alert.kind {
            case .tmrNotFed:
                return Text(verbatim: mealName + String(localized: "顿目标 \(target) kg，截止后仍无有效投喂记录。"))
            case .tmrLow, .tmrHigh:
                let actual = alert.tmrActualText ?? "--"
                let difference = alert.tmrDifferenceText ?? "--"
                return Text(verbatim: mealName + String(localized: "顿目标 \(target) kg，实际 \(actual) kg，差值 \(difference) kg。"))
            default:
                return Text(verbatim: alert.detail)
            }
        }
    }

    private func deadlineText(
        _ alert: FarmOperationalAlert,
        snapshot: FarmOperationalAlertSnapshot
    ) -> Text {
        if alert.kind == .invalidPen || alert.kind.isTMR { return Text("需立即处理") }
        if alert.kind.isDueSoon {
            let days = alert.daysUntilDue(
                now: snapshot.generatedAt,
                timeZoneIdentifier: snapshot.timeZoneIdentifier
            )
            return Text("还有 \(days) 天到期")
        }
        let days = alert.daysOverdue(
            now: snapshot.generatedAt,
            timeZoneIdentifier: snapshot.timeZoneIdentifier
        )
        return days == 0 ? Text("今天到期") : Text("已逾期 \(days) 天")
    }

    @ViewBuilder
    private func destination(for alert: FarmOperationalAlert) -> some View {
        switch alert.kind {
        case .weaningDueSoon, .weaningOverdue:
            WeaningEntryView(account: account, farm: farm, initialSheepID: alert.subjectID)
        case .pregnancyCheckDueSoon, .pregnancyCheckOverdue:
            ReproductionBatchEntryView(
                account: account,
                farm: farm,
                initialKind: .pregnancyCheck,
                initialEweID: alert.subjectID,
                initialRelatedBreedingID: alert.sourceEntityID
            )
        case .invalidPen:
            TransferEntryView(account: account, farm: farm, initialSheepID: alert.subjectID)
        case .tmrNotFed, .tmrLow, .tmrHigh:
            TMRMonitoringView(
                account: account,
                farm: farm,
                initialDate: alert.dueAt,
                initialPlanID: alert.sourceEntityID,
                initialPenID: alert.subjectID
            )
        }
    }

    @MainActor
    private func loadSnapshot() async {
        if case .loaded = loadState {
            // Preserve the last valid rows during pull-to-refresh.
        } else {
            loadState = .loading
        }
        do {
            let actor = FarmOperationalAlertSnapshotActor(container: modelContext.container)
            let snapshot = try await actor.load(farmID: farm.id)
            try Task.checkCancellation()
            loadState = .loaded(snapshot)
            if !snapshot.isConfigured, canManageRules {
                rulesPresentation = .initial
            }
            await notifications.rescheduleOperationalAlertDigest(snapshot)
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func deferSelectedAlert(days: Int) {
        guard let alert = selectedDeferralAlert,
              let snapshot = loadedSnapshot,
              let rule = snapshot.rule,
              let deferredUntil = FarmOperationalAlertDeferralPlan.deferredUntil(
                days: days,
                now: .now,
                timeZoneIdentifier: snapshot.timeZoneIdentifier,
                minuteOfDay: rule.digestMinuteOfDay
              ) else {
            selectedDeferralAlert = nil
            return
        }
        selectedDeferralAlert = nil
        do {
            let draft = FarmAlertDeferralDraft(
                id: alert.id,
                alertID: alert.id,
                alertKindRawValue: alert.kind.rawValue,
                subjectID: alert.subjectID,
                sourceEntityID: alert.sourceEntityID,
                conditionFingerprint: alert.conditionFingerprint,
                deferredUntil: deferredUntil
            )
            try commandService.execute(
                .care(.deferOperationalAlert(draft)),
                in: FarmContext(
                    accountID: account.effectiveAccountID,
                    farmID: farm.id,
                    role: farm.role
                ),
                context: modelContext
            )
            refreshRevision &+= 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var loadedSnapshot: FarmOperationalAlertSnapshot? {
        if case .loaded(let snapshot) = loadState { return snapshot }
        return nil
    }

}

struct FarmOperationalAlertRulesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var rules: [FarmCareRuleRecord]

    let account: AccountProfile
    let farm: FarmRecord
    let requiresConfiguration: Bool
    let showsCancelButton: Bool
    let onSaved: (() -> Void)?
    private let commandService = FarmCommandService()

    @State private var pregnancyCheckDays = 45
    @State private var gestationDays = 150
    @State private var weaningAgeDays = 60
    @State private var warningLeadDays = 3
    @State private var digestEnabled = true
    @State private var digestTime = Date.now
    @State private var didLoad = false
    @State private var errorMessage: String?

    init(
        account: AccountProfile,
        farm: FarmRecord,
        requiresConfiguration: Bool = false,
        showsCancelButton: Bool = false,
        onSaved: (() -> Void)? = nil
    ) {
        self.account = account
        self.farm = farm
        self.requiresConfiguration = requiresConfiguration
        self.showsCancelButton = showsCancelButton
        self.onSaved = onSaved
        let farmID = farm.id
        _rules = Query(filter: #Predicate<FarmCareRuleRecord> { $0.farmID == farmID })
    }

    private var canManage: Bool { CapabilitySet(role: farm.role).allows(.manageCatalogs) }

    var body: some View {
        Form {
            Section {
                Stepper("断奶日龄：\(weaningAgeDays) 天", value: $weaningAgeDays, in: 1...365)
                Stepper("配种后孕检：\(pregnancyCheckDays) 天", value: $pregnancyCheckDays, in: 1...365)
                Stepper("提前预警：\(warningLeadDays) 天", value: $warningLeadDays, in: 0...30)
                Stepper("妊娠周期：\(gestationDays) 天", value: $gestationDays, in: 100...220)
            } header: {
                Text("业务规则")
            } footer: {
                Text("断奶和孕检会在到期前预警；设为 0 天可关闭提前预警。规则只推导待办，不会自动修改业务数据。")
            }

            Section {
                Toggle("发送每日汇总", isOn: $digestEnabled)
                DatePicker(
                    "汇总时间",
                    selection: $digestTime,
                    displayedComponents: .hourAndMinute
                )
                .environment(\.timeZone, TimeZone(identifier: farm.timeZoneIdentifier) ?? .current)
                .disabled(!digestEnabled)
            } header: {
                Text("每日汇总")
            } footer: {
                Text("已授权通知的设备会各自保留一条滚动汇总；通知正文只显示待处理数量。")
            }

            if !canManage {
                Section {
                    Label("只有牧场主或管理员可以修改规则。", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(requiresConfiguration ? "初始规则设置" : "提醒与异常规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancelButton, !requiresConfiguration {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            if canManage {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                }
            }
        }
        .onAppear(perform: loadExistingRule)
        .recordErrorAlert($errorMessage)
        .farmExcelImport(account: account, farm: farm, sheets: ["提醒规则"])
    }

    private func loadExistingRule() {
        guard !didLoad else { return }
        didLoad = true
        if let rule = rules.first {
            pregnancyCheckDays = rule.pregnancyCheckDays
            gestationDays = rule.gestationDays
            weaningAgeDays = rule.weaningAgeDays ?? 60
            warningLeadDays = rule.operationalAlertsConfiguredAt == nil ? 3 : rule.warningLeadDays
            digestEnabled = rule.operationalAlertsConfiguredAt == nil ? true : rule.alertDigestEnabled
            digestTime = date(for: rule.alertDigestMinuteOfDay)
        } else {
            digestTime = date(for: 480)
        }
    }

    private func date(for minuteOfDay: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: farm.timeZoneIdentifier) ?? .current
        return calendar.date(
            bySettingHour: minuteOfDay / 60,
            minute: minuteOfDay % 60,
            second: 0,
            of: .now
        ) ?? .now
    }

    private var digestMinuteOfDay: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: farm.timeZoneIdentifier) ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: digestTime)
        return (components.hour ?? 8) * 60 + (components.minute ?? 0)
    }

    private func save() {
        guard canManage else { return }
        do {
            let draft = FarmOperationalAlertRuleDraft(
                id: rules.first?.id ?? UUID(),
                pregnancyCheckDays: pregnancyCheckDays,
                gestationDays: gestationDays,
                weaningAgeDays: weaningAgeDays,
                warningLeadDays: warningLeadDays,
                digestEnabled: digestEnabled,
                digestMinuteOfDay: digestMinuteOfDay
            )
            try commandService.execute(
                .care(.updateOperationalAlertRules(draft)),
                in: FarmContext(
                    accountID: account.effectiveAccountID,
                    farmID: farm.id,
                    role: farm.role
                ),
                context: modelContext
            )
            if let onSaved {
                onSaved()
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
