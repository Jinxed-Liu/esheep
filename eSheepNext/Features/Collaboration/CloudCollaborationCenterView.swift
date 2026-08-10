import CloudKit
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MigrationUploadCardSnapshot: Equatable {
    let cloudState: MigrationCloudState
    let baselineEntityCount: Int
    let confirmedBaselineCount: Int
    let baselinePhotoCount: Int
    let confirmedOperationCount: Int
    let pendingCount: Int
    let uploadingCount: Int
    let blockedCount: Int
    let rejectedCount: Int
    let activePhotoCount: Int
    let cloudPhotoAssetCount: Int
    let retainedHistoricalPhotoAssetCount: Int

    var isComplete: Bool { cloudState == .synced }

    var progressCompletedCount: Int {
        min(max(confirmedBaselineCount, 0), max(baselineEntityCount, 0))
    }

    var currentOutstandingCount: Int {
        max(pendingCount, 0) + max(uploadingCount, 0)
    }

    var currentBlockedCount: Int {
        max(blockedCount, 0) + max(rejectedCount, 0)
    }

    var confirmedAfterBaselineCount: Int {
        max(confirmedOperationCount - confirmedBaselineCount, 0)
    }
}

struct CloudCollaborationCenterView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Environment(AppSession.self) private var session
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CloudFarmBinding.updatedAt, order: .reverse) private var cloudBindings: [CloudFarmBinding]
    @Query(sort: \FarmMembershipBinding.updatedAt, order: .reverse) private var memberships: [FarmMembershipBinding]
    @Query(sort: \CapabilityCertificateRecord.expiresAt, order: .reverse) private var certificates: [CapabilityCertificateRecord]
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse) private var conflicts: [SyncConflictRecord]
    @Query(sort: \CloudAssetTransfer.updatedAt, order: .reverse) private var assetTransfers: [CloudAssetTransfer]
    @Query(sort: \SecurityIncidentRecord.detectedAt, order: .reverse) private var incidents: [SecurityIncidentRecord]
    @Query(sort: \FarmMembershipSnapshotRecord.issuedAt, order: .reverse) private var membershipSnapshots: [FarmMembershipSnapshotRecord]
    @Query(sort: \FarmCheckpointRecord.createdAt, order: .reverse) private var checkpoints: [FarmCheckpointRecord]
    @Query(sort: \FarmRecoveryAssetRecord.createdAt, order: .reverse) private var recoveryAssets: [FarmRecoveryAssetRecord]
    @Query(sort: \CloudRebuildSessionRecord.updatedAt, order: .reverse) private var rebuildSessions: [CloudRebuildSessionRecord]
    @Query(sort: \CloudSyncDiagnosticSnapshotRecord.capturedAt, order: .reverse) private var diagnosticSnapshots: [CloudSyncDiagnosticSnapshotRecord]
    @Query private var migrationCommits: [MigrationCommitRecord]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var inviteRole: FarmRole = .worker
    @State private var generatedInvite: WorkerInviteResponse?
    @State private var invitationPackage: FarmInvitationPackage?
    @State private var presentedSheet: CloudCollaborationSheet?
    @State private var redeemCode = ""
    @State private var redeemedInvite: WorkerRedeemResponse?
    @State private var deletionConfirmation = false
    @State private var pendingOutboxCount = 0
    @State private var uploadingOutboxCount = 0
    @State private var rejectedOutboxCount = 0
    @State private var blockedOutboxCount = 0
    @State private var confirmedBaselineCount = 0
    @State private var confirmedOutboxCount = 0
    @State private var supersededOutboxCount = 0
    @State private var activePhotoCount = 0
    @State private var cloudPhotoAssetCount = 0
    @State private var retainedHistoricalPhotoAssetCount = 0
    @State private var hasLoadedUploadMetrics = false

    private var binding: CloudFarmBinding? { cloudBindings.first(where: { $0.farmID == farm.id }) }
    private var farmMemberships: [FarmMembershipBinding] { memberships.filter { $0.farmID == farm.id } }
    private var farmCertificates: [CapabilityCertificateRecord] { certificates.filter { $0.farmID == farm.id && $0.accountID == account.effectiveAccountID } }
    private var farmConflicts: [SyncConflictRecord] { conflicts.filter { $0.farmID == farm.id } }
    private var farmTransfers: [CloudAssetTransfer] { assetTransfers.filter { $0.farmID == farm.id } }
    private var farmIncidents: [SecurityIncidentRecord] { incidents.filter { $0.farmID == farm.id || $0.farmID == nil } }
    private var migrationCommit: MigrationCommitRecord? { migrationCommits.first { $0.farmID == farm.id } }
    private var isSyncedFormalFarm: Bool {
        migrationCommit?.status == .completed && migrationCommit?.cloudState == .synced
    }
    private var cloudAdmissionRequest: CloudAdmissionRequest {
        CloudAdmissionRequest(
            environment: .current,
            role: farm.role,
            membershipIsActive: farm.membershipStatusRawValue == "active",
            isDeleted: farm.deletedAt != nil,
            isLocalOnlyMigration: farm.isLocalOnlyMigration,
            hasVerifiedMigrationCommit: migrationCommit?.status == .completed,
            hasCompleteMigrationBaseline: migrationCommit.map { !$0.baselineDigest.isEmpty && $0.baselineEntityCount > 0 && $0.cloudState != .localCommitted && $0.cloudState != .failed } ?? false
        )
    }
    private var cloudAdmissionDenial: CloudAdmissionDenial? {
        do {
            try CloudAdmissionPolicy.validate(cloudAdmissionRequest)
            return nil
        } catch let denial as CloudAdmissionDenial {
            return denial
        } catch {
            return .inactiveMembership
        }
    }
    private var canPrepareCloud: Bool { cloudAdmissionDenial == nil }
    private var cloudAdmissionDescription: String {
        guard let denial = cloudAdmissionDenial else {
            return "当前正式迁移牧场已完成本地校验和云端基线，符合云端准入条件。"
        }
        switch denial {
        case .localOnlyMigration:
            return CloudSyncError.localOnlyMigration.localizedDescription
        case .verifiedMigrationRequired:
            return CloudSyncError.verifiedMigrationRequired.localizedDescription
        case .ownerRequired:
            return CloudSyncError.ownerRequired.localizedDescription
        case .deletedFarm, .inactiveMembership:
            return CloudSyncError.inactiveFarm.localizedDescription
        }
    }

    var body: some View {
        List {
            if farm.role == .owner { ownerCollaborationSection }
            memberSection
            if binding != nil {
                cloudStatusSection
                syncSection
                safetySection
                if farm.role == .owner {
                    recoverySection
                }
            }
            if let error = collaboration.lastErrorMessage {
                Section("需要处理") {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Button("重试") {
                        Task {
                            await collaboration.synchronizeNow()
                            await refreshStatus()
                        }
                    }
                    .disabled(collaboration.isSynchronizing)
                }
            }
            if farm.role != .owner { accountSection }
        }
        .refreshable {
            await refreshStatus()
        }
        .navigationTitle("成员与共享")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshStatus()
        }
        .task(id: generatedInvite?.inviteID) {
            guard generatedInvite != nil, farm.role == .owner else { return }
            for _ in 0..<60 {
                if await collaboration.reconcileInvitationAcceptance(
                    farmID: farm.id,
                    accountID: account.effectiveAccountID
                ) {
                    successMessage = "成员已接受邀请并自动加入牧场。"
                    generatedInvite = nil
                    await refreshStatus()
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .systemShare(let presentation):
                CloudSharingControllerView(
                    share: presentation.share,
                    container: presentation.container
                )
            case .invitation(let package):
                FarmInvitationPanel(package: package)
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("操作已完成", isPresented: Binding(
            get: { successMessage != nil },
            set: { if !$0 { successMessage = nil } }
        )) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(successMessage ?? "")
        }
    }

    private var identitySection: some View {
        Section("身份") {
            LabeledContent("Apple 登录", value: account.serverBindingState == .verified ? "身份服务已验证" : "仅本机绑定")
            LabeledContent("身份服务", value: IdentityWorkerConfiguration.baseURL == nil ? "未配置" : "已配置")
            LabeledContent("iCloud", value: collaboration.accountAvailability.displayName)
            if let health = collaboration.workerHealth {
                LabeledContent("Development 服务", value: health.environment)
                LabeledContent("服务版本", value: health.version)
                LabeledContent("D1", value: health.database)
            }
            if collaboration.isIdentityWriteLocked {
                Label("云端写入已锁定", systemImage: "lock.fill")
                    .foregroundStyle(.red)
            }
            if account.serverBindingState != .verified {
                Text("配置 Development Worker 后需要重新使用 Apple 登录，才能注册设备、取得角色证书和加入共享牧场。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func migrationUploadSection(_ commit: MigrationCommitRecord) -> some View {
        let snapshot = MigrationUploadCardSnapshot(
            cloudState: commit.cloudState,
            baselineEntityCount: commit.baselineEntityCount,
            confirmedBaselineCount: confirmedBaselineCount,
            baselinePhotoCount: commit.baselinePhotoCount,
            confirmedOperationCount: confirmedOutboxCount,
            pendingCount: pendingOutboxCount,
            uploadingCount: uploadingOutboxCount,
            blockedCount: blockedOutboxCount,
            rejectedCount: rejectedOutboxCount,
            activePhotoCount: activePhotoCount,
            cloudPhotoAssetCount: cloudPhotoAssetCount,
            retainedHistoricalPhotoAssetCount: retainedHistoricalPhotoAssetCount
        )

        return Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: snapshot.isComplete ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                        .font(.title2)
                        .foregroundStyle(commit.cloudState == .failed ? .red : AppTheme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.isComplete ? "迁移数据已上传" : "迁移数据上传")
                            .font(.headline)
                        Text(commit.cloudState.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                if !hasLoadedUploadMetrics {
                    ProgressView("正在核对当前同步状态")
                        .font(.footnote)
                } else if snapshot.isComplete {
                    Text("当前同步：待上传 \(snapshot.pendingCount.formatted()) · 处理中 \(snapshot.uploadingCount.formatted()) · 阻塞 \(snapshot.currentBlockedCount.formatted())")
                        .font(.footnote)
                        .foregroundStyle(snapshot.currentOutstandingCount == 0 && snapshot.currentBlockedCount == 0 ? Color.secondary : Color.orange)
                    if snapshot.retainedHistoricalPhotoAssetCount > 0 {
                        Text("有效照片 \(snapshot.activePhotoCount.formatted()) 张 · 云端资产 \(snapshot.cloudPhotoAssetCount.formatted()) 份（含 \(snapshot.retainedHistoricalPhotoAssetCount.formatted()) 份删除历史）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("有效照片 \(snapshot.activePhotoCount.formatted()) 张 · 云端资产 \(snapshot.cloudPhotoAssetCount.formatted()) 份")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("查看迁移技术明细") {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent(
                                "迁移基线写入",
                                value: "\(snapshot.progressCompletedCount.formatted()) / \(snapshot.baselineEntityCount.formatted())"
                            )
                            LabeledContent("当前已确认写入", value: snapshot.confirmedOperationCount.formatted())
                            LabeledContent("迁移时照片", value: "\(snapshot.baselinePhotoCount.formatted()) 张")
                            if snapshot.confirmedAfterBaselineCount > 0 {
                                LabeledContent("迁移基线外写入", value: snapshot.confirmedAfterBaselineCount.formatted())
                            }
                            if let syncedAt = commit.cloudSyncedAt {
                                LabeledContent("完成时间", value: syncedAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                    .font(.footnote)
                } else if commit.baselineEntityCount > 0 {
                    ProgressView(
                        value: Double(snapshot.progressCompletedCount),
                        total: Double(commit.baselineEntityCount)
                    )
                    Text("迁移基线已确认 \(snapshot.progressCompletedCount.formatted()) / \(commit.baselineEntityCount.formatted()) · 待上传 \(snapshot.pendingCount.formatted()) · 处理中 \(snapshot.uploadingCount.formatted()) · 阻塞 \(snapshot.currentBlockedCount.formatted())")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("待迁移照片 \(commit.baselinePhotoCount.formatted()) 张 · 已生成云端资产 \(snapshot.cloudPhotoAssetCount.formatted()) 份")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if commit.cloudState != .synced, let error = commit.cloudLastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if commit.cloudState != .synced {
                    Text("上传采用低负载分批处理；高温或低电量时会自动暂停。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if commit.cloudState != .synced && (commit.cloudState == .failed || commit.cloudLastError != nil) {
                    Button("继续上传") {
                        Task { await collaboration.resumeAutomaticMigrationUploads(accountID: account.effectiveAccountID) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var cloudStatusSection: some View {
        Section("牧场云端状态") {
            LabeledContent("环境", value: AppEnvironment.current.rawValue.capitalized)
            LabeledContent("本地存储", value: "SwiftData 离线工作库")
            LabeledContent("Zone", value: binding?.zoneName ?? "尚未创建")
            LabeledContent("数据库", value: binding?.databaseScope == .sharedDatabase ? "Shared Database" : "Private Database")
            LabeledContent("状态", value: bindingStateText)
            Text(cloudAdmissionDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var syncSection: some View {
        Section("同步中心") {
            CloudMetricRow(title: "待上传", value: pendingOutboxCount, systemImage: "arrow.up.circle")
            CloudMetricRow(title: "等待确认", value: uploadingOutboxCount, systemImage: "clock")
            CloudMetricRow(title: "上传阻塞", value: blockedOutboxCount, systemImage: "exclamationmark.icloud")
            CloudMetricRow(title: "权限拒绝", value: rejectedOutboxCount, systemImage: "lock.trianglebadge.exclamationmark")
            if supersededOutboxCount > 0 {
                CloudMetricRow(title: "云端权威取代", value: supersededOutboxCount, systemImage: "checkmark.shield")
            }
            CloudMetricRow(title: "冲突", value: farmConflicts.filter { $0.statusRawValue == SyncConflictStatus.unresolved.rawValue || $0.statusRawValue == SyncConflictStatus.quarantined.rawValue }.count, systemImage: "arrow.trianglehead.branch")
            Button {
                Task {
                    await collaboration.synchronizeNow()
                    await collaboration.maintainRecovery(farmID: farm.id)
                    refreshOutboxCounts()
                }
            } label: {
                Label(collaboration.isSynchronizing ? "正在同步" : "立即同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(collaboration.isSynchronizing || binding?.state != .active)
            if let last = collaboration.lastSuccessfulSyncAt {
                LabeledContent("最近完成", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if let error = collaboration.lastErrorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if let diagnostic = diagnosticSnapshots.first(where: { $0.farmID == farm.id }) {
                LabeledContent("诊断实体", value: diagnostic.authoritativeEntityCount.formatted())
                LabeledContent("诊断照片", value: diagnostic.assetCount.formatted())
                LabeledContent("诊断摘要", value: String(diagnostic.entityDigest.prefix(12)))
                    .fontDesign(.monospaced)
                LabeledContent("诊断时间", value: diagnostic.capturedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var ownerCollaborationSection: some View {
        Section("邀请成员") {
            if !canPrepareCloud && binding?.state != .active {
                Text("当前牧场还不能邀请成员，请稍后重试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if binding?.state != .active {
                Button { prepareCloudFarm() } label: {
                    Label("开启成员共享", systemImage: "person.2.badge.plus")
                }
                .disabled(isWorking)
            } else {
                if isSyncedFormalFarm {
                    Picker("成员角色", selection: $inviteRole) {
                        Text("管理员").tag(FarmRole.administrator)
                        Text("员工").tag(FarmRole.worker)
                    }

                    Button {
                        createInvite()
                    } label: {
                        Label(
                            isWorking ? "正在创建邀请…" : "邀请成员",
                            systemImage: "person.badge.plus"
                        )
                    }
                    .disabled(isWorking)
                    Text("创建后可选择靠近发送、iMessage、微信、链接或二维码。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("正在准备成员共享，完成后即可发送邀请", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }

            if let generatedInvite {
                LabeledContent("邀请码", value: generatedInvite.code)
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                LabeledContent(
                    "有效期至",
                    value: Date(timeIntervalSince1970: TimeInterval(generatedInvite.expiresAt))
                        .formatted(date: .abbreviated, time: .shortened)
                )
                Button {
                    openInvitationPanel()
                } label: {
                    Label("打开邀请方式", systemImage: "paperplane.fill")
                }
                .disabled(isWorking)
                if generatedInvite.shareParticipantID == nil {
                    Text("对方输入邀请码后，你批准其 iCloud 身份；对方随后打开邀请接受私有共享。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("检查并处理加入申请") {
                        confirmLatestInvite()
                    }
                    .disabled(isWorking)
                }
            }
        }
    }

    private var joinSection: some View {
        Section("加入牧场") {
            TextField("八位邀请码", text: $redeemCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .fontDesign(.monospaced)
            Button("验证邀请码") { redeemInvite() }
                .disabled(isWorking || redeemCode.trimmingCharacters(in: .whitespacesAndNewlines).count != 8)
            if let redeemedInvite {
                LabeledContent("角色", value: redeemedInvite.role.displayName)
                LabeledContent("状态", value: "等待场主确认 CKShare 参与者")
            }
            Text("先输入邀请码提交本机 iCloud 身份；场主批准后，再打开 CKShare 链接接受共享。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var memberSection: some View {
        Section("牧场成员") {
            if farmMemberships.isEmpty {
                Text("暂无可显示的成员")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(farmMemberships, id: \.id) { member in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.displayName ?? "牧场成员").font(.headline)
                            Text(member.role.displayName).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if farm.role == .owner && member.role != .owner {
                            Menu {
                                Button("设为管理员") { changeRole(member, to: .administrator) }
                                Button("设为员工") { changeRole(member, to: .worker) }
                                Divider()
                                Button("移除成员", role: .destructive) { removeMember(member) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .disabled(isWorking)
                        }
                    }
                }
            }
            Button("刷新成员列表") { refreshMembershipAndCapability() }
                .disabled(isWorking)
            if farm.role == .owner, binding?.state == .active {
                Button {
                    presentShare()
                } label: {
                    Label("管理苹果共享成员", systemImage: "person.2")
                }
                .disabled(isWorking)
                Text("这里用于查看或移除已共享成员，不是发送邀请。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var safetySection: some View {
        Section("冲突与安全") {
            NavigationLink {
                CloudConflictCenterView(account: account, farm: farm)
            } label: {
                CloudMetricRow(title: "冲突记录", value: farmConflicts.count, systemImage: "arrow.trianglehead.branch")
            }
            NavigationLink {
                CloudSecurityEventListView(farm: farm)
            } label: {
                CloudMetricRow(title: "安全事件", value: farmIncidents.count, systemImage: "checkmark.shield")
            }
            NavigationLink {
                CloudRebuildCenterView(farm: farm)
            } label: {
                let farmSessions = rebuildSessions.filter { $0.farmID == farm.id }
                CloudMetricRow(
                    title: "云缓存重建",
                    value: farmSessions.filter { $0.status.isRunning || $0.status == .readyToCommit || $0.status == .failed }.count,
                    systemImage: "externaldrive.badge.icloud"
                )
            }
            CloudMetricRow(
                title: "照片传输",
                value: farmTransfers.filter { !$0.status.isTerminal }.count,
                systemImage: "photo.stack"
            )
            Text("CKShare 不能提供 App 字段级服务端权限。这里的证书、设备签名、隔离与恢复属于风险缓解机制，不等同于绝对不可绕过的服务端授权。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var recoverySection: some View {
        Section("恢复与存储") {
            NavigationLink {
                CloudRecoveryCenterView(account: account, farm: farm)
            } label: {
                CloudMetricRow(title: "恢复点", value: checkpoints.filter { $0.farmID == farm.id }.count, systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }
            LabeledContent("共享照片估算", value: ByteCountFormatter.string(fromByteCount: farmTransfers.filter { $0.direction == .upload }.reduce(0) { $0 + $1.byteCount }, countStyle: .file))
            LabeledContent("私有恢复照片", value: ByteCountFormatter.string(fromByteCount: recoveryAssets.filter { $0.farmID == farm.id }.reduce(0) { $0 + $1.byteCount }, countStyle: .file))
            Text("照片在共享区与场主恢复区各保留一份压缩权威版本，界面数值为本机已知记录的估算值。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var accountSection: some View {
        Section {
            if farm.role != .owner, let localMembership = farmMemberships.first(where: { $0.accountID == account.effectiveAccountID }) {
                Button("退出共享牧场", role: .destructive) { leaveSharedFarm(localMembership) }
                    .disabled(isWorking)
            }
        }
    }

    private var bindingStateText: String {
        switch binding?.state {
        case .localOnly, .none: "仅本地"
        case .preparingZone: "正在准备"
        case .active: "云端通道已启用"
        case .rebuildingCache: "正在重建云缓存"
        case .accessRevoked: "访问已撤销"
        case .requiresAccountReview: "需要检查账户"
        case .failed: "配置失败"
        }
    }

    private func refreshStatus() async {
        await collaboration.refreshAccountAvailability()
        guard account.serverBindingState == .verified, IdentityWorkerConfiguration.baseURL != nil else { return }
        do {
            let membership = MembershipActor(persistence: collaboration.persistence)
            _ = try await membership.refresh(farmID: farm.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshOutboxCounts() {
        let farmID = farm.id
        let pending = OutboxStatus.pending.rawValue
        let retryable = OutboxStatus.retryableFailure.rawValue
        let uploading = OutboxStatus.uploading.rawValue
        let awaiting = OutboxStatus.awaitingConfirmation.rawValue
        let rejected = OutboxStatus.rejectedPermission.rawValue
        let blocked = OutboxStatus.blockedConflict.rawValue
        let confirmed = OutboxStatus.confirmed.rawValue
        let superseded = OutboxStatus.supersededRemoteAuthority.rawValue

        pendingOutboxCount = (try? modelContext.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && ($0.statusRawValue == pending || $0.statusRawValue == retryable)
        }))) ?? 0
        uploadingOutboxCount = (try? modelContext.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && ($0.statusRawValue == uploading || $0.statusRawValue == awaiting)
        }))) ?? 0
        rejectedOutboxCount = (try? modelContext.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == rejected
        }))) ?? 0
        blockedOutboxCount = (try? modelContext.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == blocked
        }))) ?? 0
        confirmedOutboxCount = (try? modelContext.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == confirmed
        }))) ?? 0
        supersededOutboxCount = (try? modelContext.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == superseded
        }))) ?? 0
        let bootstrapKind = DomainOperationKind.bootstrapEntity.rawValue
        let baselineOperationIDs = Set((try? modelContext.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID && $0.kindRawValue == bootstrapKind
        })))?.map(\.id) ?? [])
        confirmedBaselineCount = (try? modelContext.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate {
            $0.farmID == farmID && $0.statusRawValue == confirmed
        })))?.count(where: { baselineOperationIDs.contains($0.operationID) }) ?? 0

        activePhotoCount = (try? modelContext.fetchCount(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))) ?? 0
        cloudPhotoAssetCount = (try? modelContext.fetchCount(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.cloudRecordName != nil
        }))) ?? 0
        retainedHistoricalPhotoAssetCount = (try? modelContext.fetchCount(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.farmID == farmID
                && $0.deletedAt != nil
                && $0.cloudRecordName != nil
        }))) ?? 0
        hasLoadedUploadMetrics = true
    }

    private func prepareCloudFarm() {
        guard canPrepareCloud else {
            errorMessage = cloudAdmissionDescription
            return
        }
        runTask {
            let accountID = account.effectiveAccountID
            let identity = try await DeviceIdentityActor.shared.register()
            let share = try await collaboration.sync.prepareOwnerFarm(farmID: farm.id, farmName: farm.name, ownerAccountID: accountID)
            try await IdentityWorkerClient.shared.registerFarm(
                farmID: farm.id,
                zoneName: CloudZoneName.forFarm(farm.id),
                shareRecordName: share.recordID.recordName
            )
            let capability = try await IdentityWorkerClient.shared.issueCapability(farmID: farm.id, deviceID: identity.deviceID)
            try await collaboration.persistence.saveCapability(capability, accountID: accountID, farmID: farm.id, deviceID: identity.deviceID)
            _ = try await MembershipActor(persistence: collaboration.persistence).refresh(farmID: farm.id)
            _ = try await collaboration.membershipSnapshots.publish(farmID: farm.id, accountID: accountID)
            _ = try await collaboration.checkpoints.createCheckpoint(farmID: farm.id, reason: .initialCloudSetup)
            await MainActor.run {
                successMessage = "成员共享已开启，可以发送邀请了。"
            }
        }
    }

    private func presentShare() {
        runTask {
            let resolution = try await resolveOwnerShare()
            await MainActor.run {
                presentedSheet = .systemShare(
                    CloudSharePresentation(share: resolution.share)
                )
            }
        }
    }

    private func createInvite() {
        if CloudOneTimeInvitationRuntimePolicy.requiresSystemSharingFallback {
            createSystemShareInvite()
            return
        }
        runTask {
            let cloudInvitation = try await collaboration.sync
                .createOneTimeFarmInvitation(farmID: farm.id)
            let service = InviteServiceActor(persistence: collaboration.persistence)
            do {
                let invite = try await service.create(
                    farmID: farm.id,
                    role: inviteRole,
                    shareParticipantID: cloudInvitation.participantID,
                    shareURL: cloudInvitation.url
                )
                let package = FarmInvitationPackage(
                    inviteID: invite.inviteID,
                    farmID: farm.id,
                    farmName: farm.name,
                    role: invite.role,
                    url: cloudInvitation.url,
                    inviteCode: invite.code,
                    shareParticipantID: invite.shareParticipantID,
                    expiresAt: Date(
                        timeIntervalSince1970: TimeInterval(invite.expiresAt)
                    )
                )
                await MainActor.run {
                    generatedInvite = invite
                    invitationPackage = package
                    presentedSheet = .invitation(package)
                }
            } catch {
                try? await collaboration.sync.removeInvitationParticipant(
                    farmID: farm.id,
                    participantID: cloudInvitation.participantID
                )
                throw error
            }
        }
    }

    private func createSystemShareInvite() {
        runTask {
            let resolution = try await resolveOwnerShare()
            guard let url = resolution.share.url else {
                throw CloudSyncError.inviteURLUnavailable
            }
            let service = InviteServiceActor(persistence: collaboration.persistence)
            let invite = try await service.create(
                farmID: farm.id,
                role: inviteRole,
                shareURL: url
            )
            let package = FarmInvitationPackage(
                inviteID: invite.inviteID,
                farmID: farm.id,
                farmName: farm.name,
                role: invite.role,
                url: url,
                inviteCode: invite.code,
                shareParticipantID: invite.shareParticipantID,
                expiresAt: Date(
                    timeIntervalSince1970: TimeInterval(invite.expiresAt)
                )
            )
            await MainActor.run {
                generatedInvite = invite
                invitationPackage = package
                presentedSheet = .invitation(package)
            }
        }
    }

    private func openInvitationPanel() {
        guard let invitationPackage else {
            createInvite()
            return
        }
        presentedSheet = .invitation(invitationPackage)
    }

    private func resolveOwnerShare() async throws -> CloudOwnerShareResolution {
        let resolution = try await collaboration.sync.ownerShareRecoveringIfMissing(
            farmID: farm.id,
            farmName: farm.name
        )
        if resolution.didRecreate {
            try await IdentityWorkerClient.shared.registerFarm(
                farmID: farm.id,
                zoneName: CloudZoneName.forFarm(farm.id),
                shareRecordName: resolution.share.recordID.recordName
            )
        }
        return resolution
    }

    private func redeemInvite() {
        runTask {
            let service = InviteServiceActor(persistence: collaboration.persistence)
            let userRecordName = try await collaboration.sync.currentCloudUserRecordName()
            let result = try await service.redeem(
                code: redeemCode,
                cloudKitUserRecordName: userRecordName
            )
            await MainActor.run {
                redeemedInvite = result
                redeemCode = ""
                successMessage = "邀请码已绑定，等待场主确认系统共享参与者。"
            }
        }
    }

    private func confirmLatestInvite() {
        guard let generatedInvite else { return }
        runTask {
            let service = InviteServiceActor(persistence: collaboration.persistence)
            let pendingInvites = try await service.pending(farmID: farm.id)
            guard let pending = pendingInvites.first(where: {
                $0.inviteID == generatedInvite.inviteID
            }) else {
                throw CloudSyncError.participantMissing
            }

            let accepted = try await collaboration.sync
                .acceptedShareParticipants(farmID: farm.id)
            let acceptedParticipant = accepted.first { participant in
                if let expectedID = pending.shareParticipantID {
                    return participant.participantID == expectedID
                }
                return participant.recordName == pending.cloudKitUserRecordName
            }
            if let acceptedParticipant {
                try await service.confirm(
                    inviteID: generatedInvite.inviteID,
                    participantRecordName: acceptedParticipant.recordName
                )
                _ = try await MembershipActor(persistence: collaboration.persistence).refresh(farmID: farm.id)
                _ = try await collaboration.membershipSnapshots.publish(farmID: farm.id, accountID: account.effectiveAccountID)
                await MainActor.run {
                    self.generatedInvite = nil
                    successMessage = "成员已确认加入牧场。"
                }
                return
            }

            guard generatedInvite.shareParticipantID == nil,
                  let userRecordName = pending.cloudKitUserRecordName else {
                throw CloudSyncError.participantMissing
            }
            _ = try await collaboration.sync.prepareShareParticipant(
                farmID: farm.id,
                userRecordName: userRecordName
            )
            await MainActor.run {
                successMessage = "已把对方加入私有共享。请让对方再次打开邀请并接受共享；接受后会自动确认成员。"
            }
        }
    }

    private func changeRole(_ member: FarmMembershipBinding, to role: FarmRole) {
        runTask {
            let service = MembershipActor(persistence: collaboration.persistence)
            try await service.changeRole(memberID: member.serverMembershipID, farmID: farm.id, role: role)
            _ = try await service.refresh(farmID: farm.id)
            _ = try await collaboration.membershipSnapshots.publish(farmID: farm.id, accountID: account.effectiveAccountID)
            await MainActor.run { successMessage = "成员角色已更新。" }
        }
    }

    private func removeMember(_ member: FarmMembershipBinding) {
        runTask {
            let service = MembershipActor(persistence: collaboration.persistence)
            _ = try await collaboration.checkpoints.createCheckpoint(farmID: farm.id, reason: .beforeMemberRevocation)
            try await service.remove(memberID: member.serverMembershipID, farmID: farm.id)
            _ = try await service.refresh(farmID: farm.id)
            _ = try await collaboration.membershipSnapshots.publish(farmID: farm.id, accountID: account.effectiveAccountID)
            if let participantName = member.shareParticipantRecordName {
                do {
                    try await collaboration.sync.removeParticipant(farmID: farm.id, participantRecordName: participantName)
                } catch {
                    try await collaboration.persistence.recordSecurityIncident(
                        farmID: farm.id,
                        type: "shareParticipantRemovalPending",
                        recordName: participantName,
                        detail: "成员证书已撤销且安全快照已更新，但 CKShare 参与者移除失败：\(error.localizedDescription)"
                    )
                    throw error
                }
            }
            _ = try await collaboration.checkpoints.createCheckpoint(farmID: farm.id, reason: .afterMemberRevocation)
            await MainActor.run { successMessage = "成员已从牧场移除。" }
        }
    }

    private func refreshMembershipAndCapability() {
        runTask {
            let membership = MembershipActor(persistence: collaboration.persistence)
            _ = try await membership.refresh(farmID: farm.id)
            let invite = InviteServiceActor(persistence: collaboration.persistence)
            _ = try await invite.refreshCapability(accountID: account.effectiveAccountID, farmID: farm.id)
            if farm.role == .owner {
                _ = try await collaboration.membershipSnapshots.publish(farmID: farm.id, accountID: account.effectiveAccountID)
            }
            await collaboration.synchronizeNow()
            await collaboration.maintainRecovery(farmID: farm.id)
            await MainActor.run { successMessage = "成员列表已刷新。" }
        }
    }

    private func deleteAccount() {
        runTask {
            let deletion = try await AccountIdentityClients.active().deleteAccount()
            await MainActor.run {
                modelContext.delete(account)
                try? modelContext.save()
                session.authenticationDidSignOut(
                    warning: "账户删除已完成（任务 \(deletion.deletionJobID)）。身份服务会话、设备与本机登录资料均已撤销。"
                )
            }
        }
    }

    private func leaveSharedFarm(_ membership: FarmMembershipBinding) {
        runTask {
            try await MembershipActor(persistence: collaboration.persistence).remove(
                memberID: membership.serverMembershipID,
                farmID: farm.id
            )
            try await collaboration.sync.leaveSharedFarm(farmID: farm.id)
        }
    }

    private func runTask(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct CloudRebuildCenterView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query(sort: \CloudFarmBinding.updatedAt, order: .reverse) private var bindings: [CloudFarmBinding]
    @Query(sort: \CloudRebuildSessionRecord.updatedAt, order: .reverse) private var sessions: [CloudRebuildSessionRecord]
    @Query(sort: \CloudRebuildIssueRecord.createdAt, order: .reverse) private var issues: [CloudRebuildIssueRecord]

    let farm: FarmRecord

    @State private var isWorking = false
    @State private var message: String?
    @State private var selectedReason: CloudRebuildReason = .manualVerification

    private var farmSessions: [CloudRebuildSessionRecord] { sessions.filter { $0.farmID == farm.id } }
    private var current: CloudRebuildSessionRecord? { farmSessions.first }
    private var binding: CloudFarmBinding? { bindings.first(where: { $0.farmID == farm.id }) }
    private var currentIssues: [CloudRebuildIssueRecord] {
        guard let current else { return [] }
        return issues.filter { $0.sessionID == current.id }
    }
    private var showsEngineResetRetry: Bool {
        guard binding?.state == .rebuildingCache else { return false }
        switch binding?.lastErrorCode {
        case "engineResetPending", "engineResetInProgress", "engineResetFailed": return true
        default: return false
        }
    }

    var body: some View {
        List {
            Section("重建原则") {
                Text("重建期间牧场保持只读。系统从 CloudKit 全量拉取到独立 staging 工作区，校验通过前不会清空或覆盖当前本地缓存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("当前数据库", value: binding?.databaseScope == .sharedDatabase ? "Shared Database" : "Private Database")
                LabeledContent("当前本地结果", value: binding?.state == .rebuildingCache ? "只读保护中" : "保持可用")
            }

            Section("开始重建") {
                Picker("原因", selection: $selectedReason) {
                    ForEach(CloudRebuildReason.allCases, id: \.self) { reason in
                        Text(reason.displayName).tag(reason)
                    }
                }
                Button("建立新的 staging 重建") { start() }
                    .disabled(isWorking || binding == nil || current?.status.isRunning == true)
                Text("新会话会替代仍在运行的旧会话，但不会删除上一份已完成结果或未确认 Outbox。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let current {
                Section("当前会话") {
                    LabeledContent("状态", value: current.status.displayName)
                    LabeledContent("原因", value: current.reason.displayName)
                    ProgressView(value: current.progress)
                    LabeledContent("分页", value: current.pageCount.formatted())
                    LabeledContent("云端记录", value: current.fetchedRecordCount.formatted())
                    LabeledContent("权威操作", value: current.fetchedOperationCount.formatted())
                    LabeledContent("照片", value: "\(current.downloadedAssetCount)/\(current.fetchedAssetCount)")
                    if current.highestRevision > 0 {
                        LabeledContent("最高 revision", value: current.highestRevision.formatted())
                    }
                    if !current.entityDigest.isEmpty {
                        LabeledContent("实体摘要", value: String(current.entityDigest.prefix(16)))
                            .fontDesign(.monospaced)
                    }
                    if let error = current.lastErrorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    actionButtons(for: current)
                }

                Section("校验问题") {
                    if currentIssues.isEmpty {
                        ContentUnavailableView("没有已记录的问题", systemImage: "checkmark.shield")
                    } else {
                        ForEach(currentIssues, id: \.id) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(issue.code, systemImage: issue.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                                    .font(.headline)
                                    .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                                Text(issue.detail)
                                if let recordName = issue.recordName {
                                    Text(recordName).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if farmSessions.count > 1 {
                Section("历史会话") {
                    ForEach(farmSessions.dropFirst(), id: \.id) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.status.displayName).font(.headline)
                            Text(session.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(String(session.id.uuidString.lowercased().prefix(12)))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("云缓存重建")
        .navigationBarTitleDisplayMode(.inline)
        .alert("重建中心", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private func actionButtons(for session: CloudRebuildSessionRecord) -> some View {
        switch session.status {
        case .preparing, .fetching, .downloadingAssets, .validating, .committing:
            Button("取消并保留旧库", role: .destructive) { cancel(session.id) }
                .disabled(isWorking || session.status == .committing)
        case .readyToCommit:
            Button("切换到已校验缓存") { commit(session.id) }
                .disabled(isWorking)
            Text("切换仅替换当前牧场的已确认云端缓存；账号、其他牧场、本机配置和未确认 Outbox 不参与替换。")
                .font(.footnote).foregroundStyle(.secondary)
        case .failed:
            if session.lastErrorCode == "commitFailed" {
                Button("重新切换已校验缓存") { commit(session.id) }
                    .disabled(isWorking)
                Text("直接复用已经完成下载和校验的 staging，不会重新全量拉取。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("重新执行此会话") { resume(session.id) }
                    .disabled(isWorking)
                Text("失败结果不会覆盖旧工作库，staging 证据会保留供复核。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .cancelled:
            Button("重新执行此会话") { resume(session.id) }
                .disabled(isWorking)
            Text("已取消的会话会从头重新执行。")
                .font(.footnote).foregroundStyle(.secondary)
        case .completed:
            LabeledContent("已保留 Outbox", value: session.preservedOutboxCount.formatted())
            LabeledContent("已应用操作", value: session.appliedOperationCount.formatted())
            if showsEngineResetRetry {
                Button("重新连接增量同步") { retryEngineReset() }
                    .disabled(isWorking)
                Text("权威缓存已经切换完成；这里只重建增量同步引擎，不会重新下载整座牧场。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        guard let binding else { return }
        runTask {
            _ = try await collaboration.rebuilds.rebuild(farmID: farm.id, scope: binding.databaseScope, reason: selectedReason)
            await MainActor.run { message = "staging 重建已经启动，牧场已进入只读保护。" }
        }
    }

    private func cancel(_ id: UUID) {
        runTask {
            try await collaboration.rebuilds.cancel(sessionID: id)
            await MainActor.run { message = "重建已取消，旧本地缓存保持不变。" }
        }
    }

    private func resume(_ id: UUID) {
        runTask {
            try await collaboration.rebuilds.resume(sessionID: id)
            await MainActor.run { message = "重建已从头重新执行。" }
        }
    }

    private func commit(_ id: UUID) {
        runTask {
            let result = try await collaboration.commitRebuild(sessionID: id)
            await MainActor.run {
                message = "缓存切换完成，应用了 \(result.appliedOperationCount) 个权威操作，保留 \(result.preservedOutboxCount) 个未确认 Outbox。"
            }
        }
    }

    private func retryEngineReset() {
        runTask {
            try await collaboration.retryCompletedRebuildEngineReset(farmID: farm.id)
            await MainActor.run {
                message = "增量同步已经重新连接，牧场只读保护已解除。"
            }
        }
    }

    private func runTask(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}

private struct CloudMetricRow: View {
    let title: String
    let value: Int
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value, format: .number).foregroundStyle(.secondary)
        }
    }
}

struct CloudConflictCenterView: View {
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse) private var conflicts: [SyncConflictRecord]
    @Query private var outboxItems: [OutboxItem]
    @Query private var operations: [DomainOperation]
    @Query private var tombstones: [TombstoneRecord]
    @Environment(CloudCollaborationStore.self) private var collaboration
    let account: AccountProfile
    let farm: FarmRecord

    @State private var isReconcilingTombstones = false
    @State private var reconciliationMessage: String?

    private var unresolvedConflicts: [SyncConflictRecord] {
        conflicts.filter {
            $0.farmID == farm.id
                && ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue
                    || $0.statusRawValue == SyncConflictStatus.quarantined.rawValue)
        }
    }

    private var blockedTombstoneCount: Int {
        let blockedOperationIDs = Set(outboxItems.filter {
            $0.farmID == farm.id && $0.status == .blockedConflict
        }.map(\.operationID))
        return operations.count {
            $0.farmID == farm.id &&
                blockedOperationIDs.contains($0.id) &&
                $0.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue
        }
    }

    private var duplicateTombstoneProjectionCount: Int {
        let active = tombstones.filter { $0.farmID == farm.id && $0.restoredAt == nil }
        return Dictionary(grouping: active) {
            "\($0.entityID.uuidString.lowercased())|\($0.revision)"
        }.values.count { group in
            group.count > 1 && Set(group.map(\.operationID)).count > 1
        }
    }

    var body: some View {
        List {
            if blockedTombstoneCount > 0 || duplicateTombstoneProjectionCount > 0 {
                Section("CloudKit 删除证据") {
                    Button {
                        reconcileTombstones()
                    } label: {
                        Label(
                            isReconcilingTombstones
                                ? "正在核对 CloudKit…"
                                : blockedTombstoneCount > 0
                                    ? "核对 CloudKit 并修复（\(blockedTombstoneCount)）"
                                    : "核对 Tombstone 权威（\(duplicateTombstoneProjectionCount)）",
                            systemImage: "checkmark.shield"
                        )
                    }
                    .disabled(isReconcilingTombstones || farm.role != .owner)
                    Text("核对当前牧场的 Operation 与 Tombstone；只有签名验证通过才会修正本地投影或云端签名索引，无法证明一致时不会覆盖权威数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(unresolvedConflicts, id: \.id) { conflict in
                NavigationLink {
                    CloudConflictDetailView(account: account, farm: farm, conflict: conflict)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(conflict.displayName).font(.headline)
                        Text(conflict.businessTypeName).foregroundStyle(.secondary)
                        Text(conflict.detectedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if unresolvedConflicts.isEmpty && blockedTombstoneCount == 0 && duplicateTombstoneProjectionCount == 0 {
                ContentUnavailableView("没有需要处理的数据异常", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("数据异常处理")
        .navigationBarTitleDisplayMode(.inline)
        .alert("CloudKit 核对结果", isPresented: Binding(
            get: { reconciliationMessage != nil },
            set: { if !$0 { reconciliationMessage = nil } }
        )) {
            Button("完成", role: .cancel) {}
        } message: {
            Text(reconciliationMessage ?? "")
        }
    }

    private func reconcileTombstones() {
        guard !isReconcilingTombstones else { return }
        isReconcilingTombstones = true
        Task {
            defer { isReconcilingTombstones = false }
            do {
                let report = try await collaboration.reconcileTombstoneConflicts(farmID: farm.id)
                let lines = report.items.map {
                    "\($0.operationID.uuidString.prefix(8))：\($0.outcome.displayName)\n\($0.detail)"
                }
                reconciliationMessage = lines.isEmpty
                    ? "没有找到可安全核对的 Tombstone 阻塞项。"
                    : lines.joined(separator: "\n")
            } catch {
                reconciliationMessage = "核对未完成：\(error.localizedDescription)"
            }
        }
    }
}

private struct CloudConflictDetailView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    let account: AccountProfile
    let farm: FarmRecord
    let conflict: SyncConflictRecord

    @State private var note = ""
    @State private var mergedText = ""
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        List {
            Section("记录") {
                LabeledContent("名称", value: conflict.displayName)
                LabeledContent("业务类型", value: conflict.businessTypeName)
                LabeledContent("发现时间") {
                    Text(conflict.detectedAt, format: .dateTime.year().month().day().hour().minute())
                }
                Text("这条记录在本机和云端都发生过更改，请选择要保留的版本。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("选择保留版本") {
                TextField("处理说明（可选）", text: $note, axis: .vertical)
                Button("保留本机版本") { resolve(.acceptLocal) }
                    .disabled(!canResolve)
                Button("采用云端版本") { resolve(.acceptRemote) }
                    .disabled(!canResolve)
                if conflict.entityType == CloudEntityType.note.rawValue {
                    TextField("合并后的备注", text: $mergedText, axis: .vertical)
                    Button("使用合并后的备注") { resolve(.mergeText(mergedText)) }
                        .disabled(!canResolve || mergedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("选择后，应用会再次检查记录是否符合当前牧场的业务规则。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if conflict.resolvedAt != nil {
                Section("解决结果") {
                    LabeledContent("状态", value: "已处理")
                    if let resolvedAt = conflict.resolvedAt {
                        LabeledContent("完成时间", value: resolvedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
        .navigationTitle("选择记录版本")
        .navigationBarTitleDisplayMode(.inline)
        .alert("处理结果", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("完成", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private var canResolve: Bool {
        CapabilitySet(role: farm.role).allows(.resolveConflicts) && !isWorking &&
        (conflict.statusRawValue == SyncConflictStatus.unresolved.rawValue || conflict.statusRawValue == SyncConflictStatus.quarantined.rawValue)
    }

    private func resolve(_ decision: ConflictResolutionDecision) {
        guard canResolve else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await collaboration.conflicts.resolve(
                    conflictID: conflict.id,
                    decision: decision,
                    note: note,
                    farm: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
                )
                await collaboration.synchronizeNow()
                message = "数据异常已处理，所选版本会自动保存。"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private extension SyncConflictRecord {
    var displayName: String {
        for payload in [localPayload, remotePayload] {
            guard let object = try? JSONSerialization.jsonObject(with: payload),
                  let dictionary = object as? [String: Any] else { continue }
            for key in ["name", "earTag", "title", "displayName", "subject"] {
                if let value = dictionary[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        return "\(businessTypeName)记录"
    }

    var businessTypeName: String {
        switch entityType {
        case CloudEntityType.farm.rawValue: "牧场"
        case CloudEntityType.pen.rawValue: "圈舍"
        case CloudEntityType.sheep.rawValue: "羊只"
        case CloudEntityType.weight.rawValue: "称重"
        case CloudEntityType.weaning.rawValue: "断奶"
        case CloudEntityType.transfer.rawValue: "转群"
        case CloudEntityType.removal.rawValue: "离场"
        case CloudEntityType.productionBatch.rawValue, CloudEntityType.batchMembership.rawValue: "生产批次"
        case CloudEntityType.feedIngredient.rawValue,
             CloudEntityType.feedRecipe.rawValue,
             CloudEntityType.feedRecipeComponent.rawValue,
             CloudEntityType.feed.rawValue,
             CloudEntityType.feedLine.rawValue,
             CloudEntityType.feedIngredientBatch.rawValue: "饲喂"
        case CloudEntityType.inventoryLot.rawValue, CloudEntityType.inventoryTransaction.rawValue: "库存"
        case CloudEntityType.health.rawValue,
             CloudEntityType.healthCatalogItem.rawValue,
             CloudEntityType.healthSubjectLink.rawValue,
             CloudEntityType.careBatch.rawValue,
             CloudEntityType.careRule.rawValue,
             CloudEntityType.careReminder.rawValue,
             CloudEntityType.alertDeferral.rawValue: "健康与照护"
        case CloudEntityType.reproduction.rawValue,
             CloudEntityType.semen.rawValue,
             CloudEntityType.semenDonor.rawValue,
             CloudEntityType.semenTransaction.rawValue,
             CloudEntityType.breedingProgram.rawValue,
             CloudEntityType.breedingProgramStep.rawValue,
             CloudEntityType.lambingOffspring.rawValue,
             CloudEntityType.pedigreeChange.rawValue: "繁殖"
        case CloudEntityType.note.rawValue: "备注"
        case CloudEntityType.photoAsset.rawValue: "照片"
        default: "牧场业务"
        }
    }
}

struct CloudRecoveryCenterView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query(sort: \FarmCheckpointRecord.createdAt, order: .reverse) private var checkpoints: [FarmCheckpointRecord]
    let account: AccountProfile
    let farm: FarmRecord

    @State private var isWorking = false
    @State private var message: String?
    @State private var exportDocument: RecoveryPackageDocument?
    @State private var isExporting = false
    @State private var recoveryCode = ""
    @State private var importedRecoveryCode = ""
    @State private var isImporting = false
    @State private var restoreCandidateID: UUID?

    private var farmCheckpoints: [FarmCheckpointRecord] { checkpoints.filter { $0.farmID == farm.id } }

    var body: some View {
        List {
            Section("恢复包") {
                Button("导出恢复包") { exportRecoveryPackage() }
                    .disabled(isWorking)
                SecureField("恢复码", text: $importedRecoveryCode)
                    .textInputAutocapitalization(.characters)
                    .fontDesign(.monospaced)
                Button("选择恢复包并导入") { isImporting = true }
                    .disabled(isWorking || importedRecoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !recoveryCode.isEmpty {
                    Text("恢复码只在本次导出期间显示，请与恢复包分开保管。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(recoveryCode).font(.body.monospaced()).textSelection(.enabled)
                }
            }
            Section("恢复点") {
                Button("创建恢复点") { createCheckpoint() }
                    .disabled(isWorking)
                ForEach(farmCheckpoints, id: \.id) { checkpoint in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(FarmCheckpointReason(rawValue: checkpoint.reasonRawValue)?.displayName ?? checkpoint.reasonRawValue).font(.headline)
                        Text(checkpoint.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("验证") { verify(checkpoint) }
                            if checkpoint.verifiedAt != nil { Label("已验证", systemImage: "checkmark.seal") }
                            if checkpoint.verifiedAt != nil {
                                Button("恢复") { restoreCandidateID = checkpoint.id }
                                    .disabled(isWorking)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("云端恢复")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .eSheepRecovery, defaultFilename: "\(farm.name).esheep-recovery") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.eSheepRecovery, .json]) { result in
            importRecoveryPackage(result)
        }
        .alert("恢复中心", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("完成", role: .cancel) {}
        } message: { Text(message ?? "") }
        .confirmationDialog("确认从恢复点重建", isPresented: Binding(get: { restoreCandidateID != nil }, set: { if !$0 { restoreCandidateID = nil } }), titleVisibility: .visible) {
            Button("开始恢复", role: .destructive) {
                if let id = restoreCandidateID { restore(id) }
                restoreCandidateID = nil
            }
            Button("取消", role: .cancel) { restoreCandidateID = nil }
        } message: {
            Text("恢复前会检查数据完整性；如发现异常，本次恢复不会写入。")
        }
    }

    private func exportRecoveryPackage() {
        runTask {
            let export = try await FarmRecoveryKeyActor.shared.exportRecoveryPackage(farmID: farm.id)
            await MainActor.run {
                recoveryCode = export.recoveryCode
                exportDocument = RecoveryPackageDocument(data: export.packageData)
                isExporting = true
            }
        }
    }

    private func importRecoveryPackage(_ result: Result<URL, Error>) {
        runTask {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try await FarmRecoveryKeyActor.shared.importRecoveryPackage(data, recoveryCode: importedRecoveryCode, farmID: farm.id)
            await MainActor.run {
                importedRecoveryCode = ""
                message = "恢复密钥已写入 iCloud 钥匙串。"
            }
        }
    }

    private func createCheckpoint() {
        runTask {
            _ = try await collaboration.checkpoints.createCheckpoint(farmID: farm.id, reason: .manual)
            await MainActor.run { message = "恢复点已创建。" }
        }
    }

    private func verify(_ checkpoint: FarmCheckpointRecord) {
        runTask {
            _ = try await collaboration.checkpoints.verifyCheckpoint(id: checkpoint.id)
            await MainActor.run { message = "恢复点检查通过，可以执行恢复。" }
        }
    }

    private func restore(_ checkpointID: UUID) {
        runTask {
            let result = try await collaboration.checkpoints.restoreCheckpoint(
                id: checkpointID,
                farm: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
            )
            for assetID in result.photoAssetIDs {
                try await collaboration.photoTransfers.restoreFromOwnerBackup(assetID: assetID)
            }
            await collaboration.synchronizeNow()
            await MainActor.run {
                message = "恢复已完成，共恢复 \(result.recoveryOperationIDs.count) 条记录。"
            }
        }
    }

    private func runTask(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}

private struct RecoveryPackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.eSheepRecovery, .json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension UTType {
    static let eSheepRecovery = UTType(exportedAs: "com.sheepfarm.next.recovery-package", conformingTo: .json)
}

private struct CloudSecurityEventListView: View {
    @Query(sort: \SecurityIncidentRecord.detectedAt, order: .reverse) private var incidents: [SecurityIncidentRecord]
    let farm: FarmRecord

    var body: some View {
        List(incidents.filter { $0.farmID == farm.id || $0.farmID == nil }, id: \.id) { incident in
            VStack(alignment: .leading, spacing: 5) {
                Text(incident.incidentType).font(.headline)
                Text(incident.detail)
                Text(incident.detectedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("安全事件")
    }
}

@MainActor
private final class CloudSharePresentation: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer

    init(share: CKShare) {
        self.share = share
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String
        self.container = identifier.flatMap { $0.isEmpty ? nil : CKContainer(identifier: $0) } ?? .default()
    }
}

@MainActor
private enum CloudCollaborationSheet: Identifiable {
    case systemShare(CloudSharePresentation)
    case invitation(FarmInvitationPackage)

    var id: String {
        switch self {
        case .systemShare(let presentation):
            "system-share-\(presentation.id.uuidString)"
        case .invitation(let package):
            "invitation-\(package.id)"
        }
    }
}

private struct CloudSharingControllerView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for csc: UICloudSharingController) -> String? { "eSheep+ 牧场" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {}
    }
}
