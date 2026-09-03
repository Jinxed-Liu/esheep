import SwiftData
import SwiftUI
import UIKit

/// The user-facing V2 cloud center. It intentionally presents business state
/// rather than transport, queue, database, or provider implementation details.
struct ESheepCloudCenterView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query private var farmStates: [ESheepCloudFarmState]
    @Query private var pendingIntents: [ESheepCloudPendingIntent]
    @Query private var attentionItems: [ESheepCloudAttentionItem]
    @Query private var assetStates: [ESheepCloudAssetState]
    @Query private var initialSessions: [ESheepCloudInitialSyncSession]
    @Query private var migrationStates: [ESheepCloudMigrationState]
    @Query private var storageProfiles: [FarmStorageProfile]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var engineState: ESheepCloudViewState?
    @State private var refreshMessage: String?
    @State private var isRefreshing = false
    @State private var isReceivingInitialSync = false
    @State private var isPreparingMigration = false
    @State private var migrationReport: ESheepCloudMigrationPreparationReportV2?

    init(account: AccountProfile, farm: FarmRecord) {
        self.account = account
        self.farm = farm
        let farmID = farm.id
        _farmStates = Query(
            filter: #Predicate<ESheepCloudFarmState> { $0.farmID == farmID },
            sort: \ESheepCloudFarmState.updatedAt,
            order: .reverse
        )
        _pendingIntents = Query(
            filter: #Predicate<ESheepCloudPendingIntent> { $0.farmID == farmID },
            sort: \ESheepCloudPendingIntent.occurredAt,
            order: .reverse
        )
        _attentionItems = Query(
            filter: #Predicate<ESheepCloudAttentionItem> { $0.farmID == farmID },
            sort: \ESheepCloudAttentionItem.createdAt,
            order: .reverse
        )
        _assetStates = Query(
            filter: #Predicate<ESheepCloudAssetState> { $0.farmID == farmID },
            sort: \ESheepCloudAssetState.updatedAt,
            order: .reverse
        )
        _initialSessions = Query(
            filter: #Predicate<ESheepCloudInitialSyncSession> { $0.farmID == farmID },
            sort: \ESheepCloudInitialSyncSession.updatedAt,
            order: .reverse
        )
        _migrationStates = Query(
            filter: #Predicate<ESheepCloudMigrationState> { $0.farmID == farmID },
            sort: \ESheepCloudMigrationState.updatedAt,
            order: .reverse
        )
        _storageProfiles = Query(
            filter: #Predicate<FarmStorageProfile> { $0.farmID == farmID },
            sort: \FarmStorageProfile.updatedAt,
            order: .reverse
        )
    }

    private var currentFarmState: ESheepCloudFarmState? {
        farmStates.max { lhs, rhs in
            if lhs.farmGeneration != rhs.farmGeneration {
                return lhs.farmGeneration < rhs.farmGeneration
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private var activeGeneration: Int? {
        currentFarmState?.farmGeneration
    }

    private var currentIntents: [ESheepCloudPendingIntent] {
        guard let activeGeneration else { return [] }
        return pendingIntents.filter {
            $0.farmGeneration == activeGeneration &&
                $0.accountID == account.effectiveAccountID
        }
    }

    private var waitingIntents: [ESheepCloudPendingIntent] {
        currentIntents.filter {
            !$0.lifecycle.isTerminal && $0.lifecycle != .needsConfirmation
        }
    }

    private var rejectedIntentCount: Int {
        currentIntents.count { $0.lifecycle == .rejected }
    }

    private var activeAttentionItems: [ESheepCloudAttentionItem] {
        guard let activeGeneration else { return [] }
        return attentionItems.filter {
            $0.farmGeneration == activeGeneration &&
                ($0.state == .open || $0.state == .resolving)
        }
    }

    private var currentAssets: [ESheepCloudAssetState] {
        guard let activeGeneration else { return [] }
        return assetStates.filter { $0.farmGeneration == activeGeneration }
    }

    private var pendingAssetCount: Int {
        currentAssets.count { asset in
            [asset.thumbnailStateRawValue, asset.avatarStateRawValue,
             asset.originalStateRawValue].contains { value in
                value == ESheepCloudAssetTransferState.localOnly.rawValue ||
                    value == ESheepCloudAssetTransferState.queued.rawValue ||
                    value == ESheepCloudAssetTransferState.transferring.rawValue ||
                    value == ESheepCloudAssetTransferState.failed.rawValue
            }
        }
    }

    private var failedAssetCount: Int {
        currentAssets.count { asset in
            [asset.thumbnailStateRawValue, asset.avatarStateRawValue,
             asset.originalStateRawValue].contains {
                $0 == ESheepCloudAssetTransferState.failed.rawValue
            }
        }
    }

    private var localPhotoBytes: Int64 {
        currentAssets.reduce(into: Int64(0)) { total, asset in
            total += max(0, asset.originalByteCount)
        }
    }

    private var latestInitialSession: ESheepCloudInitialSyncSession? {
        initialSessions.first
    }

    private var storageProfile: FarmStorageProfile? {
        storageProfiles.first
    }

    private var latestMigrationState: ESheepCloudMigrationState? {
        migrationStates.first
    }

    private var isLegacyFarmAwaitingMigration: Bool {
        storageProfile?.mode == .supabase
    }

    private var migrationPlan: ESheepCloudV1MappingPlanV2? {
        guard let data = latestMigrationState?.mappingData else { return nil }
        return try? ESheepCloudCanonicalCodec.decode(
            ESheepCloudV1MappingPlanV2.self,
            from: data
        )
    }

    private var migrationCounts: (accepted: Int, convertible: Int, unknown: Int, attention: Int, photos: Int)? {
        if let migrationReport {
            return (
                migrationReport.acceptedReceiptCount,
                migrationReport.convertibleIntentCount,
                migrationReport.unknownResultCount,
                migrationReport.attentionCount,
                migrationReport.photoReconciliationCount
            )
        }
        guard let plan = migrationPlan else { return nil }
        return (
            plan.operations.count { $0.disposition == .mapAcceptedReceipt },
            plan.operations.count { $0.disposition == .convertAfterSnapshot },
            plan.operations.count { $0.disposition == .queryV1Result },
            plan.operations.count { $0.disposition == .createServerAttention },
            plan.operations.count { $0.disposition == .reconcilePhotoAsset }
        )
    }

    private var migrationStatusText: String {
        switch latestMigrationState?.phase ?? .notStarted {
        case .notStarted:
            "开始前会先备份本机资料，并逐项检查旧操作；这一步不会修改云端。"
        case .backupVerified:
            "本机备份已完成，正在整理需要核对的内容。"
        case .shadowConverted:
            "本机备份和操作整理已完成，等待 eSheep+ 云进行资料核对。"
        case .parityVerified:
            "本机与 eSheep+ 云资料已核对一致，等待最后确认。"
        case .readyToCutOver:
            "迁移已准备好，完成现场确认后才能切换云端。"
        case .v1WriteClosed:
            "正在完成云端切换，暂时不能新增这座牧场的内容。"
        case .v2Active:
            "这座牧场已经使用 eSheep+ 云。"
        case .forwardRepairRequired:
            "有旧操作无法安全解释，已保留原数据；修复完成前不会切换。"
        }
    }

    private var engineReportsOffline: Bool {
        guard let presentation = engineState?.presentation else { return false }
        if case .offline = presentation { return true }
        return false
    }

    private var statusTitle: String {
        if !activeAttentionItems.isEmpty {
            return "\(activeAttentionItems.count) 项需要你确认"
        }
        if currentFarmState == nil || currentFarmState?.activityState == .preparing {
            return "正在准备牧场资料"
        }
        if currentFarmState?.activityState == .accessRevoked {
            return "需要重新登录"
        }
        if failedAssetCount > 0 ||
            rejectedIntentCount > 0 ||
            currentFarmState?.activityState == .integrityHold ||
            currentFarmState?.integrityState == .failed {
            return "部分内容尚未保存，请稍后再试"
        }
        if engineReportsOffline, !waitingIntents.isEmpty {
            return "离线，联网后自动保存"
        }
        if !waitingIntents.isEmpty {
            return "正在保存 \(waitingIntents.count) 项"
        }
        if pendingAssetCount > 0 {
            return "正在保存 \(pendingAssetCount) 项"
        }
        if let engineState, engineState.presentation != .preparing {
            return engineState.statusTitle
        }
        if let state = currentFarmState,
           state.activityState == .active,
           state.integrityState == .passed,
           state.lastAppliedEventSequence >= state.cloudEventHead,
           state.lastSafeSaveAt != nil {
            return "已安全保存"
        }
        return "正在准备牧场资料"
    }

    private var statusSymbol: String {
        if !activeAttentionItems.isEmpty { return "exclamationmark.bubble.fill" }
        if statusTitle == "已安全保存" { return "checkmark.circle.fill" }
        if statusTitle == "需要重新登录" { return "person.crop.circle.badge.exclamationmark" }
        if statusTitle.hasPrefix("离线") { return "wifi.slash" }
        return "arrow.trianglehead.2.clockwise.rotate.90"
    }

    private var statusColor: Color {
        if !activeAttentionItems.isEmpty { return .orange }
        if statusTitle == "已安全保存" { return .green }
        if statusTitle == "需要重新登录" { return .red }
        return .secondary
    }

    var body: some View {
        Form {
            Section {
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                    .accessibilityLabel("eSheep+ 云状态，\(statusTitle)")

                if let savedAt = currentFarmState?.lastSafeSaveAt ?? engineState?.lastSafeSaveAt {
                    LabeledContent("最近安全保存") {
                        Text(savedAt, format: .relative(presentation: .named))
                    }
                }

                if let refreshMessage {
                    Text(refreshMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if isLegacyFarmAwaitingMigration {
                        prepareMigration()
                    } else {
                        refreshFromCloud()
                    }
                } label: {
                    if isRefreshing {
                        Label("正在检查", systemImage: "hourglass")
                    } else if isLegacyFarmAwaitingMigration {
                        Label("检查本机资料", systemImage: "checkmark.shield")
                    } else {
                        Label("现在检查保存状态", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || isPreparingMigration)
            } header: {
                Text("当前状态")
            } footer: {
                Text("正常保存时无需停留在这里；离开此页面后仍会继续。")
            }

            if isLegacyFarmAwaitingMigration {
                migrationPreparationSection
            } else if currentFarmState == nil || currentFarmState?.activityState == .preparing {
                ESheepCloudPreparationSection(
                    session: latestInitialSession,
                    isRetrying: isReceivingInitialSync,
                    onRetry: retryInitialReceive
                )
            }

            Section("正在等待保存的内容") {
                if waitingIntents.isEmpty {
                    Label("没有等待保存的内容", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("合计", value: "\(waitingIntents.count) 项")
                    ForEach(waitingIntents.prefix(5)) { intent in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ESheepCloudCommandPresentation.title(for: intent.commandKind))
                            Text(intent.occurredAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if waitingIntents.count > 5 {
                        Text("另有 \(waitingIntents.count - 5) 项正在依次保存")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if activeAttentionItems.isEmpty {
                    Label("没有需要你决定的内容", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeAttentionItems) { item in
                        NavigationLink {
                            ESheepCloudAttentionDetailView(
                                account: account,
                                farm: farm,
                                item: item
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.recordDisplayName)
                                    .font(.body.weight(.semibold))
                                Text("\(item.fieldDisplayName)需要选择保留哪一边")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if item.state == .resolving {
                                    Label("正在按你的选择处理", systemImage: "hourglass")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } header: {
                Text("需要确认")
            } footer: {
                Text("这里只暂停相关字段及依赖操作，牧场的其他内容会继续保存。")
            }

            Section {
                LabeledContent("照片资料", value: "\(currentAssets.count) 张")
                LabeledContent(
                    "本机照片空间",
                    value: ByteCountFormatter.string(
                        fromByteCount: localPhotoBytes,
                        countStyle: .file
                    )
                )
                if pendingAssetCount > 0 {
                    LabeledContent("正在准备保存", value: "\(pendingAssetCount) 张")
                }
                Text("头像和预览图优先准备；照片原图在后台保存，需要查看时可重新接收。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("照片与本机离线空间")
            }

            Section("牧场成员与共享") {
                NavigationLink {
                    FarmMembersAndSharingView(account: account, farm: farm)
                } label: {
                    Label("查看成员与共享设置", systemImage: "person.2.fill")
                }
            }

            Section("备份、导出和诊断") {
                NavigationLink {
                    FarmDataInterchangeView(account: account, farm: farm)
                } label: {
                    Label("数据与存储", systemImage: "externaldrive.fill")
                }
                Text("诊断信息默认只包含业务状态和脱敏编号，不包含照片内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("eSheep+ 云")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: farm.id) {
            engineState = collaboration.eSheepCloudViewState(farmID: farm.id)
            await refreshFromCloudIfNeeded()
        }
    }

    private func refreshFromCloud() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshMessage = nil
        Task {
            defer { isRefreshing = false }
            do {
                _ = try await collaboration.synchronizeESheepCloudFarm(
                    farmID: farm.id,
                    accountID: account.effectiveAccountID
                )
            } catch {
                refreshMessage = ESheepCloudUserMessage.text(for: error)
            }
        }
    }

    private func refreshFromCloudIfNeeded() async {
        guard !isRefreshing else { return }
        // A legacy farm must first pass the local, read-only migration
        // preflight. Calling the V2 cycle before that creates a misleading
        // "not prepared" error and could hide the actionable migration step.
        guard !isLegacyFarmAwaitingMigration else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await collaboration.synchronizeESheepCloudFarm(
                farmID: farm.id,
                accountID: account.effectiveAccountID
            )
            refreshMessage = nil
        } catch {
            refreshMessage = ESheepCloudUserMessage.text(for: error)
        }
    }

    /// A paused receive normally resumes on the next launch.  Keep an explicit
    /// action for a user who has stayed on this page, and for a failed attempt
    /// whose staging files must be retried after the underlying issue is gone.
    private func retryInitialReceive() {
        guard !isReceivingInitialSync,
              let session = latestInitialSession,
              session.state == .paused || session.state == .failed ||
                  session.state == .connecting else {
            return
        }
        isReceivingInitialSync = true
        refreshMessage = nil
        Task { @MainActor in
            defer { isReceivingInitialSync = false }
            do {
                _ = try await collaboration.receiveESheepCloudFarm(
                    farmID: farm.id,
                    expectedFarmGeneration: session.farmGeneration
                )
                refreshMessage = "牧场资料已准备完成，可以进入牧场了。"
            } catch {
                refreshMessage = ESheepCloudUserMessage.text(for: error)
            }
        }
    }

    @ViewBuilder
    private var migrationPreparationSection: some View {
        Section {
            Text(migrationStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let counts = migrationCounts {
                LabeledContent(
                    "已核对内容",
                    value: "\(counts.accepted + counts.convertible + counts.unknown + counts.attention + counts.photos) 项"
                )
                if counts.attention > 0 {
                    Label(
                        "\(counts.attention) 项需要完成后选择",
                        systemImage: "exclamationmark.bubble"
                    )
                    .foregroundStyle(.orange)
                }
                if counts.unknown > 0 {
                    Label(
                        "\(counts.unknown) 项正在等待原始处理结果",
                        systemImage: "clock"
                    )
                    .foregroundStyle(.secondary)
                }
                if counts.photos > 0 {
                    Label(
                        "\(counts.photos) 张照片只做资料核对，不会重复上传",
                        systemImage: "photo"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            switch latestMigrationState?.phase ?? .notStarted {
            case .notStarted:
                Button {
                    prepareMigration()
                } label: {
                    if isPreparingMigration {
                        Label("正在备份并检查", systemImage: "hourglass")
                    } else {
                        Label("开始安全准备", systemImage: "checkmark.shield")
                    }
                }
                .disabled(isPreparingMigration)
            case .forwardRepairRequired:
                Label("需要先处理无法解释的旧操作", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .backupVerified, .shadowConverted, .parityVerified,
                 .readyToCutOver, .v1WriteClosed, .v2Active:
                EmptyView()
            }
        } header: {
            Text("准备 eSheep+ 云")
        } footer: {
            Text("准备期间只锁定这座牧场的旧云端写入；不会覆盖本机资料，也不会在没有现场确认时切换云端。")
        }
    }

    private func prepareMigration() {
        guard !isPreparingMigration else { return }
        isPreparingMigration = true
        refreshMessage = nil
        Task { @MainActor in
            defer { isPreparingMigration = false }
            do {
                migrationReport = try await collaboration.prepareESheepCloudMigration(
                    farmID: farm.id,
                    accountID: account.effectiveAccountID
                )
                refreshMessage = "本机备份和资料整理已完成，等待 eSheep+ 云核对。"
            } catch {
                refreshMessage = ESheepCloudUserMessage.text(for: error)
            }
        }
    }
}

private struct ESheepCloudPreparationSection: View {
    let session: ESheepCloudInitialSyncSession?
    let isRetrying: Bool
    let onRetry: () -> Void

    private var currentStep: Int {
        guard let session else { return 1 }
        switch session.state {
        case .connecting, .paused, .failed: return 1
        case .receiving: return 2
        case .verifying, .applyingRecentChanges, .buildingIndexes: return 3
        case .readyToActivate, .active: return 4
        }
    }

    private let titles = [
        "连接 eSheep+ 云",
        "接收牧场资料",
        "检查资料是否完整",
        "即将完成",
    ]

    var body: some View {
        Section {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 12) {
                    Image(systemName: index + 1 < currentStep
                        ? "checkmark.circle.fill"
                        : index + 1 == currentStep
                            ? "circle.dotted.circle.fill"
                            : "circle")
                        .foregroundStyle(index + 1 <= currentStep ? Color.accentColor : .secondary)
                    Text(title)
                        .foregroundStyle(index + 1 == currentStep ? .primary : .secondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("第 \(index + 1) 步，\(title)\(index + 1 == currentStep ? "，正在进行" : "")")
            }

            if let session, session.expectedByteCount > 0 {
                ProgressView(
                    value: Double(session.receivedByteCount),
                    total: Double(session.expectedByteCount)
                )
                .accessibilityLabel("牧场资料接收进度")
            } else {
                ProgressView()
                    .accessibilityLabel("正在准备牧场资料")
            }

            if let session,
               session.state == .paused || session.state == .failed ||
                   session.state == .connecting {
                if session.state == .failed {
                    Label(
                        "这次接收没有完成，原有牧场资料没有受到影响。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                } else if session.state == .paused {
                    Label(
                        "接收已暂时停下，已完成的部分会继续使用。",
                        systemImage: "pause.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Button(action: onRetry) {
                    Label(
                        isRetrying ? "正在继续接收" : "继续接收资料",
                        systemImage: isRetrying ? "hourglass" : "arrow.clockwise"
                    )
                }
                .disabled(isRetrying)
            }
        } header: {
            Text("正在准备牧场资料")
        } footer: {
            Text("可以返回牧场列表，准备工作会在后台继续。资料完整之前不会打开半成品牧场。")
        }
    }
}

private struct ESheepCloudAttentionDetailView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration

    let account: AccountProfile
    let farm: FarmRecord
    let item: ESheepCloudAttentionItem

    @State private var proposedChoice: ESheepCloudAttentionResolutionChoiceV2?
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var copyNotice: String?

    private var deviceValue: ESheepCloudValueV2? {
        try? ESheepCloudCanonicalCodec.decode(
            ESheepCloudValueV2.self,
            from: item.deviceValueData
        )
    }

    private var cloudValue: ESheepCloudValueV2? {
        try? ESheepCloudCanonicalCodec.decode(
            ESheepCloudValueV2.self,
            from: item.cloudValueData
        )
    }

    private var isActionAvailable: Bool {
        item.state == .open && !isResolving
    }

    var body: some View {
        Form {
            Section("需要确认的内容") {
                LabeledContent("记录", value: item.recordDisplayName)
                LabeledContent("具体项目", value: item.fieldDisplayName)
                Text(item.explanation.isEmpty
                    ? "这个项目在两边都被改成了不同内容，系统无法替你判断哪一个正确。"
                    : item.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("复制本次注意项证据") {
                    UIPasteboard.general.string = item.exportText
                    copyNotice = "注意项证据已复制到剪贴板。"
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }

            Section {
                ESheepCloudValuePreview(
                    title: "这台设备准备保存的内容",
                    fieldKey: item.fieldKey,
                    value: deviceValue
                )
                Divider()
                LabeledContent("操作者", value: item.deviceAccountDisplayName ?? "当前账号")
                LabeledContent("设备", value: item.deviceDisplayName ?? "这台设备")
                LabeledContent("操作时间") {
                    Text(item.deviceOccurredAt, format: .dateTime.year().month().day().hour().minute())
                }
            } header: {
                Text("这台设备")
            }

            Section {
                ESheepCloudValuePreview(
                    title: "eSheep+ 云当前内容",
                    fieldKey: item.fieldKey,
                    value: cloudValue
                )
                Divider()
                LabeledContent("操作者", value: item.cloudAccountDisplayName ?? "另一位牧场成员")
                LabeledContent("设备", value: item.cloudDeviceDisplayName ?? "另一台设备")
                if let cloudReceivedAt = item.cloudReceivedAt {
                    LabeledContent("保存时间") {
                        Text(cloudReceivedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }
            } header: {
                Text("eSheep+ 云")
            }

            Section {
                if item.state == .resolving || isResolving {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在按你的选择处理。收到 eSheep+ 云确认后才会完成。")
                    }
                } else if item.state == .resolved || item.state == .obsolete {
                    Label("这项内容已经处理完成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("采用这台设备的内容") {
                        proposedChoice = .useThisDevice
                    }
                    .accessibilityHint("将这台设备准备保存的内容作为最终内容")

                    Button("保留云端内容") {
                        proposedChoice = .keepCloud
                    }
                    .accessibilityHint("不改变 eSheep+ 云当前内容")

                    Button("放弃本次操作", role: .destructive) {
                        proposedChoice = .abandonOperation
                    }
                    .accessibilityHint("放弃这台设备的这一次修改并保留云端内容")
                }
            } header: {
                Text("你的选择")
            } footer: {
                Text("你的选择和两边原始内容会保留在操作记录中。")
            }
        }
        .navigationTitle(item.fieldDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            proposedChoice?.confirmationTitle ?? "确认选择",
            isPresented: Binding(
                get: { proposedChoice != nil },
                set: { if !$0 { proposedChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let proposedChoice {
                Button(proposedChoice.actionTitle, role: proposedChoice.buttonRole) {
                    resolve(proposedChoice)
                }
            }
            Button("再看一下", role: .cancel) {}
        } message: {
            Text("eSheep+ 云确认处理完成之前，这项内容仍会显示为正在处理。")
        }
        .alert("未能完成处理", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "请稍后再试。")
        }
        .alert("提示", isPresented: Binding(
            get: { copyNotice != nil },
            set: { if !$0 { copyNotice = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(copyNotice ?? "已复制到剪贴板。")
        }
    }

    private func resolve(_ choice: ESheepCloudAttentionResolutionChoiceV2) {
        guard isActionAvailable else { return }
        proposedChoice = nil
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                try await collaboration.resolveESheepCloudAttention(
                    id: item.id,
                    farmID: farm.id,
                    accountID: account.effectiveAccountID,
                    choice: choice
                )
            } catch {
                errorMessage = ESheepCloudUserMessage.text(for: error)
            }
        }
    }
}

private extension ESheepCloudAttentionItem {
    var exportText: String {
        """
注意项ID: \(id.uuidString.lowercased())
实体类型: \(recordType)
实体ID: \(recordID.uuidString.lowercased())
字段: \(fieldKey) / \(fieldDisplayName)
流: \(streamType) / \(streamID.uuidString.lowercased())
命令ID: \(commandID.uuidString.lowercased())
基础内容摘要: \(baseValueDigest)
状态: \(stateRawValue)
原因说明: \(explanation.isEmpty ? "无" : explanation)
这台设备操作者: \(deviceAccountDisplayName ?? "\(deviceAccountID)")
这台设备ID: \(deviceID.uuidString.lowercased())
这台设备时间: \(deviceOccurredAt.formatted(date: .numeric, time: .standard))
云端操作者: \(cloudAccountDisplayName ?? "未知")
云端设备: \(cloudDeviceID?.uuidString.lowercased() ?? "未知")
云端时间: \(cloudReceivedAt?.formatted(date: .numeric, time: .standard) ?? "未接收")
"""
    }
}

private struct ESheepCloudValuePreview: View {
    let title: String
    let fieldKey: String
    let value: ESheepCloudValueV2?

    private var isPhotoValue: Bool {
        let normalized = fieldKey.lowercased()
        return normalized.contains("avatar") || normalized.contains("photo")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            switch value {
            case .identifier(let assetID) where isPhotoValue:
                ESheepCloudPhotoValuePreview(assetID: assetID)
            case .null where isPhotoValue:
                Label("使用默认头像", systemImage: "person.crop.circle")
                    .font(.headline)
            case .some(let value):
                Text(value.userFacingText)
                    .font(.headline)
                    .textSelection(.enabled)
            case nil:
                Label("内容暂时无法显示", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ESheepCloudPhotoValuePreview: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    let assetID: UUID

    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(image == nil ? "一张照片（正在准备预览）" : "这张照片")
                .font(.headline)
        }
        .task(id: assetID) {
            guard let data = try? await collaboration.loadPhotoData(assetID: assetID) else {
                return
            }
            image = UIImage(data: data)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(image == nil ? "一张照片，预览尚未准备好" : "照片预览")
    }
}

private enum ESheepCloudCommandPresentation {
    static func title(for commandKind: String) -> String {
        if commandKind.hasPrefix("sheepAvatar.") { return "更新羊只头像" }
        if commandKind.hasPrefix("sheep.") { return "更新羊只资料" }
        if commandKind.hasPrefix("weight.") { return "保存称重记录" }
        if commandKind.hasPrefix("feed.") || commandKind.hasPrefix("feeding.") {
            return "保存饲喂记录"
        }
        if commandKind.hasPrefix("health.") { return "保存健康记录" }
        if commandKind.hasPrefix("reproduction.") { return "保存繁殖记录" }
        if commandKind.hasPrefix("photo.") { return "保存照片资料" }
        if commandKind.hasPrefix("pen.") { return "更新栏舍资料" }
        if commandKind.hasPrefix("batch.") { return "更新批次资料" }
        if commandKind.hasPrefix("inventory.") { return "保存库存记录" }
        if commandKind.hasPrefix("farm.") { return "更新牧场资料" }
        return "保存一项牧场记录"
    }
}

private enum ESheepCloudUserMessage {
    static func text(for error: Error) -> String {
        if let value = error as? ESheepCloudCoreError {
            return value.localizedDescription
        }
        if let value = error as? ESheepCloudRuntimeError {
            return value.localizedDescription
        }
        if let value = error as? ESheepCloudMigrationError {
            return value.localizedDescription
        }
        return "部分内容尚未保存，请稍后再试。"
    }
}

private extension ESheepCloudValueV2 {
    var userFacingText: String {
        switch self {
        case .null:
            "未设置"
        case .string(let value):
            value.isEmpty ? "空白" : value
        case .integer(let value):
            value.formatted()
        case .decimal(let value):
            value
        case .boolean(let value):
            value ? "是" : "否"
        case .date(let value):
            value.formatted(date: .abbreviated, time: .shortened)
        case .identifier:
            "已选择的关联内容"
        case .strings(let values):
            values.isEmpty ? "未设置" : values.joined(separator: "、")
        case .identifiers(let values):
            values.isEmpty ? "未设置" : "已选择 \(values.count) 项"
        }
    }
}

private extension ESheepCloudAttentionResolutionChoiceV2 {
    var actionTitle: String {
        switch self {
        case .useThisDevice: "采用这台设备的内容"
        case .keepCloud: "保留云端内容"
        case .abandonOperation: "放弃本次操作"
        case .resubmit: "重新提交本次操作"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .useThisDevice: "采用这台设备的内容？"
        case .keepCloud: "保留 eSheep+ 云当前内容？"
        case .abandonOperation: "放弃这一次修改？"
        case .resubmit: "重新提交这一次修改？"
        }
    }

    var buttonRole: ButtonRole? {
        self == .abandonOperation ? .destructive : nil
    }
}
