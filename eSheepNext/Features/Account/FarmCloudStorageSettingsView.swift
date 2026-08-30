import Foundation
import SwiftData
import SwiftUI

struct FarmCloudStorageSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query private var remoteBindings: [FarmRemoteBinding]
    @Query private var outboxItems: [OutboxItem]
    @Query private var baselineMigrations: [FarmBaselineMigrationRecord]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var eligibilityReason: String?
    @State private var isLoading = true
    @State private var isActivating = false
    @State private var isConfirmingActivation = false
    @State private var statusMessage: LocalizedStringKey?
    @State private var errorMessage: String?
    @State private var compactRebuildProgress:
        FarmCompactBaselineRebuildProgress?
    @State private var remoteStorageMetrics: SupabaseFarmStorageMetrics?
    @State private var remoteTransitionStatus:
        FarmCompactAuthorityTransitionStatus?
    @State private var isRunningDevelopmentAcceptanceCommand = false
    @State private var developmentAcceptanceMessage: String?
    @AppStorage(DevelopmentSupabaseActivationGate.pausePointKey)
    private var developmentPausePointRawValue = ""
    @AppStorage(DevelopmentSupabaseActivationGate.lastPausedPointKey)
    private var developmentLastPausedPointRawValue = ""
    @AppStorage(DevelopmentSupabaseRealtimeGate.disabledKey)
    private var developmentRealtimeDisabled = false
    @AppStorage(DevelopmentSupabaseNetworkGate.forcedOfflineKey)
    private var developmentSupabaseForcedOffline = false

    private var profile: FarmStorageProfile? {
        let profiles = (try? modelContext.fetch(FetchDescriptor<FarmStorageProfile>())) ?? []
        return profiles.first { $0.farmID == farm.id }
    }

    private var modeTitle: String {
        switch profile?.mode ?? .localOnly {
        case .localOnly: "仅保存在此设备"
        case .retiredAppleCloud: "旧云存储已停用"
        case .supabase: "eSheep 云"
        }
    }

    private var remoteBinding: FarmRemoteBinding? {
        remoteBindings.first { $0.farmID == farm.id && $0.provider == .supabase }
    }

    private var pendingOutboxCount: Int {
        outboxItems.count {
            $0.farmID == farm.id
                && $0.deliveryProvider == .supabase
                && !$0.status.isTerminalDelivery
        }
    }

    private var baselineProgress: FarmBaselineMigrationRecord? {
        let farmMigrations = baselineMigrations.filter { $0.farmID == farm.id }
        if let migrationID = profile?.migrationID {
            return farmMigrations
                .filter { $0.migrationID == migrationID }
                .max { $0.updatedAt < $1.updatedAt }
        }
        guard profile?.mode == .supabase else { return nil }
        return farmMigrations.max { $0.updatedAt < $1.updatedAt }
    }

    private var canManuallyActivate: Bool {
        guard let state = profile?.transitionState else { return true }
        return state == .idle || state == .failed
    }

    private var activationButtonTitle: String {
        if isActivating {
            return "正在启用 eSheep 云…"
        }
        if profile?.transitionState == .failed {
            return "继续启用 eSheep 云"
        }
        if profile?.transitionState != .idle {
            return "正在自动恢复启云…"
        }
        return "启用 eSheep 云"
    }

    var body: some View {
        Form {
            Section("当前模式") {
                LabeledContent("数据保存在") {
                    Text(LocalizedStringKey(modeTitle))
                }
                if let profile, profile.transitionState != .idle {
                    LabeledContent("切换状态") {
                        Text("正在安全迁移")
                    }
                }
                Text("离线时仍可继续录入；恢复网络后会自动同步到当前云存储。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if profile?.mode == .localOnly {
                Section("云端保存") {
                    Button {
                        isConfirmingActivation = true
                    } label: {
                        Label(
                            LocalizedStringKey(activationButtonTitle),
                            systemImage: "externaldrive.connected.to.line.below.fill"
                        )
                    }
                    .disabled(
                        isLoading ||
                        isActivating ||
                        !canManuallyActivate ||
                        eligibilityReason != nil ||
                        AccountIdentityClients.supabaseClient == nil
                    )

                    if let eligibilityReason {
                        eligibilityReasonView(eligibilityReason)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if profile?.mode == .localOnly {
                Section("启用说明") {
                    Label("开始前自动生成完整本地备份", systemImage: "externaldrive.badge.checkmark")
                    Label("业务记录、历史、删除记录和照片会先完整校验", systemImage: "checkmark.shield")
                    Label("校验完成后才会切换到 eSheep 云", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    Label("当前版本免费使用", systemImage: "checkmark.seal")
                }
            } else if profile?.mode == .supabase {
                Section("同步状态") {
                    LabeledContent("待同步记录", value: pendingOutboxCount.formatted())
                    LabeledContent(
                        "已保存记录",
                        value: (remoteStorageMetrics?.entityCount ?? 0).formatted()
                    )
                    LabeledContent(
                        "照片占用空间",
                        value: ByteCountFormatter.string(
                            fromByteCount: remoteStorageMetrics?.storageObjectBytes ?? 0,
                            countStyle: .file
                        )
                    )
                    Text("同步中断不会丢失本机记录，恢复网络后会自动继续。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.green)
                }
            }

            #if DEBUG && ESHEEP_INTERNAL_ACCEPTANCE_UI
            if Bundle.main.bundleIdentifier == "com.sheepfarm.next.dev" {
                Section("Development 验收") {
                    LabeledContent("Mode", value: profile?.mode.rawValue ?? "localOnly")
                    LabeledContent(
                        "Generation",
                        value: (profile?.authorityGeneration ?? 0).formatted()
                    )
                    LabeledContent(
                        "Migration",
                        value: profile?.transitionState.rawValue ?? "idle"
                    )
                    LabeledContent(
                        "远端迁移",
                        value: remoteTransitionStatus?.status ?? "未知"
                    )
                    LabeledContent(
                        "远端 Revision",
                        value:
                            (remoteTransitionStatus?.currentRevision ?? 0)
                            .formatted()
                    )
                    LabeledContent(
                        "Cursor",
                        value: (remoteBinding?.lastPulledRevision ?? 0).formatted()
                    )
                    LabeledContent("Outbox", value: pendingOutboxCount.formatted())
                    if let remoteStorageMetrics {
                        LabeledContent(
                            "云端实体",
                            value: remoteStorageMetrics.entityCount.formatted()
                        )
                        LabeledContent(
                            "增量操作",
                            value: remoteStorageMetrics.operationCount.formatted()
                        )
                        LabeledContent(
                            "逻辑载荷",
                            value: ByteCountFormatter.string(
                                fromByteCount:
                                    remoteStorageMetrics.logicalPayloadBytes,
                                countStyle: .file
                            )
                        )
                        LabeledContent(
                            "Storage 对象",
                            value:
                                remoteStorageMetrics.storageObjectCount
                                .formatted()
                        )
                        LabeledContent(
                            "Storage 用量",
                            value: ByteCountFormatter.string(
                                fromByteCount:
                                    remoteStorageMetrics.storageObjectBytes,
                                countStyle: .file
                            )
                        )
                        LabeledContent(
                            "重复 SHA",
                            value:
                                remoteStorageMetrics.duplicateAssetSHACount
                                .formatted()
                        )
                        LabeledContent(
                            "检查点",
                            value:
                                remoteStorageMetrics.checkpointCount.formatted()
                        )
                    }
                    if let baselineProgress {
                        let operationTotal = max(1, baselineProgress.operationCount)
                        let operationFraction = min(
                            1,
                            Double(baselineProgress.confirmedOperationCount) /
                                Double(operationTotal)
                        )
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("实体投影上传")
                                Spacer()
                                Text(operationFraction, format: .percent.precision(.fractionLength(1)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: operationFraction)
                                .progressViewStyle(.linear)
                            Text(
                                "\(baselineProgress.confirmedOperationCount.formatted()) / " +
                                    "\(baselineProgress.operationCount.formatted()) 个投影"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        LabeledContent(
                            "基线批次",
                            value: baselineProgress.confirmedBatchCount.formatted()
                        )
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("照片上传")
                                Spacer()
                                Text(
                                    "\(baselineProgress.uploadedAssetCount) / " +
                                        "\(baselineProgress.assetCount)"
                                )
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            }
                            ProgressView(
                                value: Double(baselineProgress.uploadedAssetCount),
                                total: Double(max(1, baselineProgress.assetCount))
                            )
                            .progressViewStyle(.linear)
                        }
                        LabeledContent(
                            "服务端 Revision",
                            value: baselineProgress.serverRevision.formatted()
                        )
                        if let compactRebuildProgress {
                            let total = max(
                                1,
                                compactRebuildProgress.totalProjectionCount
                            )
                            let fraction = min(
                                1,
                                Double(
                                    compactRebuildProgress
                                        .processedProjectionCount
                                ) / Double(total)
                            )
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(
                                        LocalizedStringKey(
                                            compactRebuildProgress.phase.displayName
                                        )
                                    )
                                    Spacer()
                                    Text(
                                        fraction,
                                        format: .percent.precision(
                                            .fractionLength(1)
                                        )
                                    )
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                }
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                Text(
                                    "\(compactRebuildProgress.processedProjectionCount.formatted()) / " +
                                        "\(compactRebuildProgress.totalProjectionCount.formatted()) 个投影"
                                )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent(
                        "最后错误",
                        value: remoteBinding?.lastErrorCode ?? "无"
                    )
                    let realtimeHealth = collaboration.supabaseRealtimeHealth(farmID: farm.id)
                    LabeledContent("Realtime", value: realtimeHealth.displayTitle)
                    if let realtimeErrorCode = realtimeHealth.errorCode {
                        LabeledContent("Realtime 错误", value: realtimeErrorCode)
                        Text("实时提醒暂不可用；数据仍由权威 cursor 每30秒补拉。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Toggle(
                        "关闭 Realtime（验收 cursor）",
                        isOn: $developmentRealtimeDisabled
                    )
                    .onChange(of: developmentRealtimeDisabled) {
                        collaboration.refreshSupabaseRealtimeAcceptanceMode()
                    }
                    Toggle(
                        "强制 Supabase 离线（验收 Outbox）",
                        isOn: $developmentSupabaseForcedOffline
                    )
                    .onChange(of: developmentSupabaseForcedOffline) {
                        collaboration.refreshSupabaseRealtimeAcceptanceMode()
                    }
                    if developmentSupabaseForcedOffline {
                        Text("仅暂停本机 Supabase 发送、拉取和 Realtime；本地命令仍会写入 Outbox。关闭后立即恢复同步。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button("生成20条在线验收记录") {
                        createDevelopmentAcceptanceNotes(
                            prefix: "DEV-A-ONLINE",
                            count: 20
                        )
                    }
                    Button("生成1条 Cursor 验收记录") {
                        createDevelopmentAcceptanceNotes(
                            prefix: "DEV-A-CURSOR",
                            count: 1,
                            appendAfterExisting: true
                        )
                    }
                    Button("生成20条离线验收记录") {
                        createDevelopmentAcceptanceNotes(
                            prefix: "DEV-A-OFFLINE",
                            count: 20,
                            appendAfterExisting: true
                        )
                    }
                    Button("撤销全部 DEV-A 验收记录", role: .destructive) {
                        revokeDevelopmentAcceptanceNotes()
                    }
                    .disabled(isRunningDevelopmentAcceptanceCommand)
                    if let developmentAcceptanceMessage {
                        Text(verbatim: developmentAcceptanceMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Picker("下次启云暂停于", selection: $developmentPausePointRawValue) {
                        Text("不暂停").tag("")
                        ForEach(
                            DevelopmentSupabaseActivationGate.pausePoints,
                            id: \.rawValue
                        ) { point in
                            Text(LocalizedStringKey(point.rawValue)).tag(point.rawValue)
                        }
                    }
                    if !developmentLastPausedPointRawValue.isEmpty {
                        LabeledContent(
                            "上次暂停",
                            value: developmentLastPausedPointRawValue
                        )
                    }
                    Text("暂停点为一次性设置。到达后任务会保持挂起，强杀并重启 App 即会从该状态续跑。选择 uploadingBaseline 时，续传完成后还会在 committingAuthority 自动暂停一次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("这里只显示本机验收状态，不上传本地牧场名称、存在性或业务内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .navigationTitle("云存储")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
            while !Task.isCancelled {
                refreshCompactRebuildProgress()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .confirmationDialog(
            "启用 eSheep 云？",
            isPresented: $isConfirmingActivation,
            titleVisibility: .visible
        ) {
            Button("备份并启用") {
                activate()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("系统会先生成完整备份并校验全部记录与照片。切换过程中断后会从安全断点继续。")
        }
        .alert("无法完成启云", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage ?? ""))
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        guard let client = AccountIdentityClients.supabaseClient else {
            eligibilityReason = SupabaseAccountConfiguration.isEnabled
                ? "eSheep 云配置缺失。"
                : "eSheep 云功能未开启。"
            return
        }
        do {
            let service = SupabaseFarmActivationService(client: client)
            eligibilityReason = try service.eligibilityReason(
                farmID: farm.id,
                context: modelContext
            )
            if profile?.mode == .supabase {
                remoteStorageMetrics = try await
                    SupabaseFarmStorageMetricsClient(client: client)
                    .metrics(farmID: farm.id)
                if let migration = baselineProgress {
                    remoteTransitionStatus = try? await
                        SupabaseFarmTransport(client: client)
                        .compactAuthorityTransitionStatus(
                            farmID: farm.id,
                            migrationID: migration.migrationID
                        )
                } else {
                    remoteTransitionStatus = nil
                }
            } else {
                remoteStorageMetrics = nil
                remoteTransitionStatus = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func eligibilityReasonView(_ reason: String) -> some View {
        switch reason {
        case "eSheep 云配置缺失。":
            Text("eSheep 云配置缺失。")
        case "eSheep 云功能未开启。":
            Text("eSheep 云功能未开启。")
        default:
            Text(verbatim: reason)
        }
    }

    private func activate() {
        guard !isActivating,
              let client = AccountIdentityClients.supabaseClient else {
            return
        }
        isActivating = true
        Task { @MainActor in
            defer { isActivating = false }
            do {
                let backupURL = try await SupabaseFarmActivationService(
                    client: client
                ).activate(farm: farm, context: modelContext)
                statusMessage = "已启用 eSheep 云。完整备份：\(backupURL.lastPathComponent)"
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshCompactRebuildProgress() {
        guard let migration = baselineProgress else {
            compactRebuildProgress = nil
            return
        }
        compactRebuildProgress = FarmCompactBaselineRebuildProgressStore.load(
            farmID: farm.id,
            migrationID: migration.migrationID
        )
    }

    private func createDevelopmentAcceptanceNotes(
        prefix: String,
        count: Int,
        appendAfterExisting: Bool = false
    ) {
        guard !isRunningDevelopmentAcceptanceCommand,
              profile?.mode == .supabase,
              profile?.transitionState == .idle else {
            return
        }
        isRunningDevelopmentAcceptanceCommand = true
        Task { @MainActor in
            defer { isRunningDevelopmentAcceptanceCommand = false }
            do {
                let existingTexts = Set(
                    try modelContext.fetch(FetchDescriptor<NoteRecord>())
                        .filter {
                            $0.farmID == farm.id &&
                                $0.text.hasPrefix(prefix + "-")
                        }
                        .map(\.text)
                )
                let targetSheepID = try modelContext.fetch(FetchDescriptor<SheepRecord>())
                    .filter {
                        $0.farmID == farm.id &&
                            $0.deletedAt == nil &&
                            $0.status == .active
                    }
                    .min {
                        $0.id.uuidString.lowercased() <
                            $1.id.uuidString.lowercased()
                    }?
                    .id
                let targetPenID = targetSheepID == nil
                    ? try modelContext.fetch(FetchDescriptor<PenRecord>())
                        .filter {
                            $0.farmID == farm.id &&
                                $0.deletedAt == nil &&
                                $0.isActive
                        }
                        .min {
                            $0.id.uuidString.lowercased() <
                                $1.id.uuidString.lowercased()
                        }?
                        .id
                    : nil
                guard targetSheepID != nil || targetPenID != nil else {
                    throw CocoaError(
                        .validationMissingMandatoryProperty,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "星露谷没有可关联的在场羊只或有效圈舍，无法创建验收备注。"
                        ]
                    )
                }
                let nextIndex: Int
                if appendAfterExisting {
                    nextIndex = existingTexts.compactMap { value in
                        Int(value.dropFirst(prefix.count + 1))
                    }.max().map { $0 + 1 } ?? 1
                } else {
                    nextIndex = 1
                }
                var createdCount = 0
                for offset in 0..<max(1, count) {
                    let index = nextIndex + offset
                    let text = "\(prefix)-\(String(format: "%03d", index))"
                    guard !existingTexts.contains(text) else { continue }
                    try FarmCommandService().execute(
                        .addNote(
                            sheepID: targetSheepID,
                            penID: targetPenID,
                            text: text,
                            occurredAt: .now
                        ),
                        in: FarmContext(
                            accountID: account.effectiveAccountID,
                            farmID: farm.id,
                            role: farm.role
                        ),
                        context: modelContext
                    )
                    createdCount += 1
                }
                developmentAcceptanceMessage =
                    "已创建 \(createdCount) 条 \(prefix) 记录；重复标识未再次创建。"
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func revokeDevelopmentAcceptanceNotes() {
        guard !isRunningDevelopmentAcceptanceCommand else { return }
        isRunningDevelopmentAcceptanceCommand = true
        Task { @MainActor in
            defer { isRunningDevelopmentAcceptanceCommand = false }
            do {
                let notes = try modelContext.fetch(FetchDescriptor<NoteRecord>())
                    .filter {
                        $0.farmID == farm.id &&
                            $0.deletedAt == nil &&
                            $0.text.hasPrefix("DEV-A-")
                    }
                for note in notes {
                    try FarmCommandService().execute(
                        .tombstoneEntity(
                            entityType: .note,
                            entityID: note.id,
                            reason: "Development 双机同步验收完成"
                        ),
                        in: FarmContext(
                            accountID: account.effectiveAccountID,
                            farmID: farm.id,
                            role: farm.role
                        ),
                        context: modelContext
                    )
                }
                developmentAcceptanceMessage =
                    "已通过 FarmCommandService 撤销 \(notes.count) 条验收记录。"
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
