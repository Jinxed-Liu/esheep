import CloudKit
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CloudCollaborationCenterView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CloudFarmBinding.updatedAt, order: .reverse) private var cloudBindings: [CloudFarmBinding]
    @Query(sort: \FarmMembershipBinding.updatedAt, order: .reverse) private var memberships: [FarmMembershipBinding]
    @Query(sort: \CapabilityCertificateRecord.expiresAt, order: .reverse) private var certificates: [CapabilityCertificateRecord]
    @Query(sort: \OutboxItem.createdAt, order: .reverse) private var outbox: [OutboxItem]
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse) private var conflicts: [SyncConflictRecord]
    @Query(sort: \CloudAssetTransfer.updatedAt, order: .reverse) private var assetTransfers: [CloudAssetTransfer]
    @Query(sort: \SecurityIncidentRecord.detectedAt, order: .reverse) private var incidents: [SecurityIncidentRecord]
    @Query(sort: \FarmMembershipSnapshotRecord.issuedAt, order: .reverse) private var membershipSnapshots: [FarmMembershipSnapshotRecord]
    @Query(sort: \FarmCheckpointRecord.createdAt, order: .reverse) private var checkpoints: [FarmCheckpointRecord]
    @Query(sort: \FarmRecoveryAssetRecord.createdAt, order: .reverse) private var recoveryAssets: [FarmRecoveryAssetRecord]
    @Query(sort: \CloudRebuildSessionRecord.updatedAt, order: .reverse) private var rebuildSessions: [CloudRebuildSessionRecord]
    @Query(sort: \CloudSyncDiagnosticSnapshotRecord.capturedAt, order: .reverse) private var diagnosticSnapshots: [CloudSyncDiagnosticSnapshotRecord]

    let account: AccountProfile
    let farm: FarmRecord

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var inviteRole: FarmRole = .worker
    @State private var generatedInvite: WorkerInviteResponse?
    @State private var redeemCode = ""
    @State private var redeemedInvite: WorkerRedeemResponse?
    @State private var sharePresentation: CloudSharePresentation?
    @State private var deletionConfirmation = false
    @State private var testGenerationProgress: TestFarmGenerationProgress?

    private var binding: CloudFarmBinding? { cloudBindings.first(where: { $0.farmID == farm.id }) }
    private var farmMemberships: [FarmMembershipBinding] { memberships.filter { $0.farmID == farm.id } }
    private var farmCertificates: [CapabilityCertificateRecord] { certificates.filter { $0.farmID == farm.id && $0.accountID == account.effectiveAccountID } }
    private var farmOutbox: [OutboxItem] { outbox.filter { $0.farmID == farm.id } }
    private var farmConflicts: [SyncConflictRecord] { conflicts.filter { $0.farmID == farm.id } }
    private var farmTransfers: [CloudAssetTransfer] { assetTransfers.filter { $0.farmID == farm.id } }
    private var farmIncidents: [SecurityIncidentRecord] { incidents.filter { $0.farmID == farm.id || $0.farmID == nil } }
    private var isDevelopmentTestFarm: Bool {
        !farm.isLocalOnlyMigration && farm.isDevelopmentTestFarm && farm.developmentSeed == TestFarmGeneratorActor.seed
    }

    var body: some View {
        List {
            identitySection
            cloudStatusSection
            syncSection
            if farm.role == .owner { ownerCollaborationSection }
            joinSection
            memberSection
            safetySection
            if farm.role == .owner { recoverySection }
            accountSection
        }
        .navigationTitle("云端协作")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshStatus()
        }
        .task {
            await refreshStatus()
        }
        .sheet(item: $sharePresentation) { presentation in
            CloudSharingControllerView(share: presentation.share, container: presentation.container)
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
        .confirmationDialog("确认删除账户", isPresented: $deletionConfirmation, titleVisibility: .visible) {
            Button("删除账户", role: .destructive) { deleteAccount() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("存在自有云端牧场时，身份服务会拒绝删除。删除成功后本机身份令牌会被清除。")
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

    private var cloudStatusSection: some View {
        Section("牧场云端状态") {
            LabeledContent("环境", value: "CloudKit Development")
            LabeledContent("本地存储", value: "SwiftData 离线工作库")
            LabeledContent("Zone", value: binding?.zoneName ?? "尚未创建")
            LabeledContent("数据库", value: binding?.databaseScope == .sharedDatabase ? "Shared Database" : "Private Database")
            LabeledContent("状态", value: bindingStateText)
            Text(isDevelopmentTestFarm
                 ? "当前是带固定标记的 Development 测试牧场，可以用于双机验收。"
                 : "当前牧场已被强制锁定为仅本地。试迁、迁移和真实牧场不能创建 CloudKit Zone、上传或共享。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var syncSection: some View {
        Section("同步中心") {
            CloudMetricRow(title: "待上传", value: farmOutbox.filter { $0.status == .pending || $0.status == .retryableFailure }.count, systemImage: "arrow.up.circle")
            CloudMetricRow(title: "等待确认", value: farmOutbox.filter { $0.status == .uploading || $0.status == .awaitingConfirmation }.count, systemImage: "clock")
            CloudMetricRow(title: "权限拒绝", value: farmOutbox.filter { $0.status == .rejectedPermission }.count, systemImage: "lock.trianglebadge.exclamationmark")
            CloudMetricRow(title: "冲突", value: farmConflicts.filter { $0.statusRawValue == SyncConflictStatus.unresolved.rawValue || $0.statusRawValue == SyncConflictStatus.quarantined.rawValue }.count, systemImage: "arrow.trianglehead.branch")
            Button {
                Task {
                    await collaboration.synchronizeNow()
                    await collaboration.maintainRecovery(farmID: farm.id)
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
        Section("场主协作") {
            if !isDevelopmentTestFarm {
                Label("仅 Development 测试牧场可启用云协作", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                Text("请新建空白牧场并生成固定测试数据，再建立 Development 云端协作；迁移后的牧场会始终保留在本机。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if binding?.state != .active {
                Button { prepareTestCloudFarm() } label: {
                    Label("启用测试云牧场", systemImage: "icloud.and.arrow.up")
                }
                .disabled(isWorking || account.serverBindingState != .verified)
            } else {
                Button { presentShare() } label: {
                    Label("打开系统共享", systemImage: "person.2.badge.plus")
                }
                .disabled(isWorking)
            }

            #if DEBUG
            Button { generateSevenDayTestFarm() } label: {
                Label("生成本机验收测试数据", systemImage: "hammer")
            }
            .disabled(isWorking || farm.isDevelopmentTestFarm || farm.isLocalOnlyMigration)
            if let progress = testGenerationProgress {
                ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                    Text(progress.stage)
                } currentValueLabel: {
                    Text("\(progress.completed)/\(progress.total)")
                }
            }
            if isDevelopmentTestFarm {
                LabeledContent("测试标记", value: farm.developmentSeed ?? "已标记")
                    .fontDesign(.monospaced)
            } else if farm.isLocalOnlyMigration {
                Text("这是已提交的本地迁移牧场，测试数据生成和 CloudKit 均已永久关闭。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if binding?.state != .active {
                Text("无需先迁移或启用 CloudKit。生成的数据只写入当前 Debug 牧场，之后可再选择是否建立云端测试绑定。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            #endif

            if isDevelopmentTestFarm {
                Picker("邀请角色", selection: $inviteRole) {
                    Text("管理员").tag(FarmRole.administrator)
                    Text("员工").tag(FarmRole.worker)
                }
                Button("生成一次性邀请码") { createInvite() }
                    .disabled(isWorking || binding?.state != .active)

                if let generatedInvite {
                    LabeledContent("邀请码", value: generatedInvite.code)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                    LabeledContent("有效期至", value: Date(timeIntervalSince1970: TimeInterval(generatedInvite.expiresAt)).formatted(date: .abbreviated, time: .shortened))
                    Text("必须同时向同一成员定向发送系统 CKShare 链接。邀请码本身不包含共享链接。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("确认已接受共享的成员") { confirmLatestInvite() }
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
            Text("先在系统中接受场主发来的 CKShare 链接，再输入邀请码。两个条件缺一不可。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var memberSection: some View {
        Section("成员与证书") {
            if farmMemberships.isEmpty {
                ContentUnavailableView("尚无成员快照", systemImage: "person.2", description: Text("身份服务连接后下拉刷新。"))
            } else {
                ForEach(farmMemberships, id: \.id) { member in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.displayName ?? member.role.displayName).font(.headline)
                            Text(member.role.displayName).font(.subheadline).foregroundStyle(.secondary)
                            Text(member.accountID.uuidString.lowercased()).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Text(member.statusRawValue).font(.caption).foregroundStyle(.secondary)
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
            if let certificate = farmCertificates.first(where: \.isUsable) {
                LabeledContent("当前证书", value: certificate.roleRawValue)
                LabeledContent("剩余有效期", value: certificate.expiresAt.formatted(.relative(presentation: .numeric)))
            } else {
                LabeledContent("当前证书", value: "不可用")
            }
            if let snapshot = membershipSnapshots.first(where: { $0.farmID == farm.id }) {
                LabeledContent("安全 generation", value: snapshot.generation.formatted())
                LabeledContent("快照签发", value: snapshot.issuedAt.formatted(date: .abbreviated, time: .shortened))
            } else {
                LabeledContent("成员安全快照", value: "尚未发布")
            }
            Button("刷新成员与能力证书") { refreshMembershipAndCapability() }
                .disabled(isWorking || account.serverBindingState != .verified)
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
                CloudRebuildCenterView(farm: farm, binding: binding)
            } label: {
                let farmSessions = rebuildSessions.filter { $0.farmID == farm.id }
                CloudMetricRow(
                    title: "云缓存重建",
                    value: farmSessions.filter { $0.status.isRunning || $0.status == .readyToCommit || $0.status == .failed }.count,
                    systemImage: "externaldrive.badge.icloud"
                )
            }
            CloudMetricRow(title: "照片传输", value: farmTransfers.filter { $0.statusRawValue != CloudAssetTransferStatus.completed.rawValue }.count, systemImage: "photo.stack")
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
        Section("账户") {
            if farm.role != .owner, let localMembership = farmMemberships.first(where: { $0.accountID == account.effectiveAccountID }) {
                Button("退出共享牧场", role: .destructive) { leaveSharedFarm(localMembership) }
                    .disabled(isWorking)
            }
            Button("删除账户", role: .destructive) { deletionConfirmation = true }
                .disabled(isWorking || account.serverBindingState != .verified)
        }
    }

    private var bindingStateText: String {
        switch binding?.state {
        case .localOnly, .none: "仅本地"
        case .preparingZone: "正在准备"
        case .active: "已启用"
        case .rebuildingCache: "正在重建云缓存"
        case .accessRevoked: "访问已撤销"
        case .requiresAccountReview: "需要检查账户"
        case .failed: "配置失败"
        }
    }

    private func refreshStatus() async {
        await collaboration.refreshAccountAvailability()
        await collaboration.captureDiagnostics(farmID: farm.id)
        guard account.serverBindingState == .verified, IdentityWorkerConfiguration.baseURL != nil else { return }
        do {
            let membership = MembershipActor(persistence: collaboration.persistence)
            _ = try await membership.refresh(farmID: farm.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareTestCloudFarm() {
        guard isDevelopmentTestFarm else {
            errorMessage = CloudSyncError.developmentTestFarmRequired.localizedDescription
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
                sharePresentation = CloudSharePresentation(share: share)
                successMessage = "测试云牧场、系统共享和能力证书已经建立。"
            }
        }
    }

    private func presentShare() {
        runTask {
            let share = try await collaboration.sync.ownerShare(farmID: farm.id)
            await MainActor.run { sharePresentation = CloudSharePresentation(share: share) }
        }
    }

    #if DEBUG
    private func generateSevenDayTestFarm() {
        runTask {
            let result = try await collaboration.testFarmGenerator.generate(
                farmID: farm.id,
                accountID: account.effectiveAccountID
            ) { progress in
                await MainActor.run { testGenerationProgress = progress }
            }
            if binding?.state == .active {
                await collaboration.synchronizeNow()
            }
            await MainActor.run {
                successMessage = "已生成 \(result.penCount) 个圈舍、\(result.sheepCount) 只羊、\(result.productionEventCount) 条生产事件和 \(result.photoCount) 张测试照片。"
            }
        }
    }
    #endif

    private func createInvite() {
        runTask {
            let service = InviteServiceActor(persistence: collaboration.persistence)
            let invite = try await service.create(farmID: farm.id, role: inviteRole)
            let share = try await collaboration.sync.ownerShare(farmID: farm.id)
            await MainActor.run {
                generatedInvite = invite
                sharePresentation = CloudSharePresentation(share: share)
            }
        }
    }

    private func redeemInvite() {
        runTask {
            let service = InviteServiceActor(persistence: collaboration.persistence)
            let result = try await service.redeem(code: redeemCode)
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
            let participantNames = try await collaboration.sync.acceptedParticipantRecordNames(farmID: farm.id)
            let knownNames = Set(farmMemberships.compactMap(\.shareParticipantRecordName))
            guard let participantName = participantNames.first(where: { !knownNames.contains($0) }) else {
                throw CloudSyncError.participantMissing
            }
            let service = InviteServiceActor(persistence: collaboration.persistence)
            try await service.confirm(inviteID: generatedInvite.inviteID, participantRecordName: participantName)
            _ = try await MembershipActor(persistence: collaboration.persistence).refresh(farmID: farm.id)
            _ = try await collaboration.membershipSnapshots.publish(farmID: farm.id, accountID: account.effectiveAccountID)
            await MainActor.run {
                self.generatedInvite = nil
                successMessage = "邀请码与已接受的系统共享参与者已完成绑定。"
            }
        }
    }

    private func changeRole(_ member: FarmMembershipBinding, to role: FarmRole) {
        runTask {
            let service = MembershipActor(persistence: collaboration.persistence)
            try await service.changeRole(memberID: member.serverMembershipID, farmID: farm.id, role: role)
            _ = try await service.refresh(farmID: farm.id)
            _ = try await collaboration.membershipSnapshots.publish(farmID: farm.id, accountID: account.effectiveAccountID)
            await MainActor.run { successMessage = "成员角色已更新，旧能力证书已撤销。" }
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
            await MainActor.run { successMessage = "成员能力与系统共享访问已撤销。" }
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
            await MainActor.run { successMessage = "成员快照和能力证书已刷新。" }
        }
    }

    private func deleteAccount() {
        runTask {
            try await IdentityWorkerClient.shared.deleteAccount()
            try SecureAccountStore.removeAppleUserIdentifier()
            await MainActor.run {
                modelContext.delete(account)
                try? modelContext.save()
                successMessage = "身份服务账户与本机登录资料已删除。"
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
    @Query(sort: \CloudRebuildSessionRecord.updatedAt, order: .reverse) private var sessions: [CloudRebuildSessionRecord]
    @Query(sort: \CloudRebuildIssueRecord.createdAt, order: .reverse) private var issues: [CloudRebuildIssueRecord]

    let farm: FarmRecord
    let binding: CloudFarmBinding?

    @State private var isWorking = false
    @State private var message: String?
    @State private var selectedReason: CloudRebuildReason = .manualVerification

    private var farmSessions: [CloudRebuildSessionRecord] { sessions.filter { $0.farmID == farm.id } }
    private var current: CloudRebuildSessionRecord? { farmSessions.first }
    private var currentIssues: [CloudRebuildIssueRecord] {
        guard let current else { return [] }
        return issues.filter { $0.sessionID == current.id }
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
        case .failed, .cancelled:
            Button("重新执行此会话") { resume(session.id) }
                .disabled(isWorking)
            Text("失败结果不会覆盖旧工作库，staging 证据会保留供复核。")
                .font(.footnote).foregroundStyle(.secondary)
        case .completed:
            LabeledContent("已保留 Outbox", value: session.preservedOutboxCount.formatted())
            LabeledContent("已应用操作", value: session.appliedOperationCount.formatted())
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

private struct CloudConflictCenterView: View {
    @Query(sort: \SyncConflictRecord.detectedAt, order: .reverse) private var conflicts: [SyncConflictRecord]
    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        List(conflicts.filter { $0.farmID == farm.id }, id: \.id) { conflict in
            NavigationLink {
                CloudConflictDetailView(account: account, farm: farm, conflict: conflict)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(conflict.entityType).font(.headline)
                    Text("本地 revision \(conflict.localRevision)，云端 revision \(conflict.remoteRevision)")
                    Text(conflict.statusRawValue).foregroundStyle(.secondary)
                    Text(conflict.detectedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if conflicts.allSatisfy({ $0.farmID != farm.id }) {
                ContentUnavailableView("没有冲突", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("冲突中心")
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
            Section("差异") {
                LabeledContent("实体", value: conflict.entityType)
                LabeledContent("本地 revision", value: conflict.localRevision.formatted())
                LabeledContent("云端 revision", value: conflict.remoteRevision.formatted())
                LabeledContent("本地摘要", value: String(conflict.localPayloadDigest.prefix(12)))
                LabeledContent("云端摘要", value: String(conflict.remotePayloadDigest.prefix(12)))
                if let accountID = conflict.remoteAccountID {
                    LabeledContent("远端账号", value: String(accountID.uuidString.lowercased().prefix(12)))
                }
                Text(conflict.reasonCode).font(.footnote).foregroundStyle(.secondary)
            }
            Section("场主决定") {
                TextField("处理说明", text: $note, axis: .vertical)
                Button("采用本地版本") { resolve(.acceptLocal) }
                    .disabled(!canResolve)
                Button("采用云端版本") { resolve(.acceptRemote) }
                    .disabled(!canResolve)
                if conflict.entityType == CloudEntityType.note.rawValue {
                    TextField("合并后的备注", text: $mergedText, axis: .vertical)
                    Button("保存手动合并") { resolve(.mergeText(mergedText)) }
                        .disabled(!canResolve || mergedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("库存、繁殖和批次冲突不会做字段拼接；无论选择哪一方，都必须重新通过业务约束校验。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let operationID = conflict.resolutionOperationID {
                Section("解决结果") {
                    LabeledContent("状态", value: conflict.statusRawValue)
                    LabeledContent("解决操作", value: String(operationID.uuidString.lowercased().prefix(12)))
                    if let resolvedAt = conflict.resolvedAt {
                        LabeledContent("完成时间", value: resolvedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
        }
        .navigationTitle("冲突详情")
        .navigationBarTitleDisplayMode(.inline)
        .alert("处理结果", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("完成", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private var canResolve: Bool {
        farm.role == .owner && !isWorking &&
        (conflict.statusRawValue == SyncConflictStatus.unresolved.rawValue || conflict.statusRawValue == SyncConflictStatus.quarantined.rawValue)
    }

    private func resolve(_ decision: ConflictResolutionDecision) {
        guard canResolve else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let operationID = try await collaboration.conflicts.resolve(
                    conflictID: conflict.id,
                    decision: decision,
                    note: note,
                    farm: FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: farm.role)
                )
                await collaboration.synchronizeNow()
                message = "冲突已生成解决操作 \(String(operationID.uuidString.lowercased().prefix(12)))，业务模型已更新并进入同步队列。"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct CloudRecoveryCenterView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Query(sort: \FarmCheckpointRecord.createdAt, order: .reverse) private var checkpoints: [FarmCheckpointRecord]
    @Query(sort: \CloudAssetTransfer.updatedAt, order: .reverse) private var transfers: [CloudAssetTransfer]
    @Query(sort: \FarmRecoveryAssetRecord.createdAt, order: .reverse) private var recoveryAssets: [FarmRecoveryAssetRecord]
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
    private var farmTransfers: [CloudAssetTransfer] { transfers.filter { $0.farmID == farm.id } }

    var body: some View {
        List {
            Section("恢复密钥") {
                Button("导出恢复包") { exportRecoveryPackage() }
                    .disabled(isWorking)
                SecureField("输入恢复码后导入", text: $importedRecoveryCode)
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
            Section("结构化恢复点") {
                Button("创建手动恢复点") { createCheckpoint() }
                    .disabled(isWorking)
                ForEach(farmCheckpoints, id: \.id) { checkpoint in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(FarmCheckpointReason(rawValue: checkpoint.reasonRawValue)?.displayName ?? checkpoint.reasonRawValue).font(.headline)
                        Text("\(checkpoint.entityCount) 个实体，\(checkpoint.assetCount) 张照片引用")
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
            Section("照片传输") {
                LabeledContent("共享区估算", value: ByteCountFormatter.string(fromByteCount: farmTransfers.filter { $0.direction == .upload }.reduce(0) { $0 + $1.byteCount }, countStyle: .file))
                LabeledContent("恢复区估算", value: ByteCountFormatter.string(fromByteCount: recoveryAssets.filter { $0.farmID == farm.id }.reduce(0) { $0 + $1.byteCount }, countStyle: .file))
                ForEach(farmTransfers, id: \.id) { transfer in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(transfer.directionRawValue, value: transfer.statusRawValue)
                        ProgressView(value: transfer.byteCount == 0 ? 0 : Double(transfer.transferredByteCount), total: max(1, Double(transfer.byteCount)))
                        if transfer.status == .failed {
                            Button("重试") { retry(transfer) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("恢复与照片")
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
            Button("生成恢复操作", role: .destructive) {
                if let id = restoreCandidateID { restore(id) }
                restoreCandidateID = nil
            }
            Button("取消", role: .cancel) { restoreCandidateID = nil }
        } message: {
            Text("系统会重新校验实体引用和业务约束，为恢复内容生成新的签名操作；任何冲突都会阻断本次提交。")
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
            await MainActor.run { message = "恢复点已加密并保存到场主私有恢复区。" }
        }
    }

    private func verify(_ checkpoint: FarmCheckpointRecord) {
        runTask {
            _ = try await collaboration.checkpoints.verifyCheckpoint(id: checkpoint.id)
            await MainActor.run { message = "恢复点的密钥、摘要、牧场编号和实体载荷校验通过。" }
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
                message = "已生成 \(result.recoveryOperationIDs.count) 个恢复操作，并校验恢复照片。"
            }
        }
    }

    private func retry(_ transfer: CloudAssetTransfer) {
        runTask {
            try await collaboration.photoTransfers.retry(transferID: transfer.id)
            await MainActor.run { message = "照片传输已完成。" }
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
        func itemTitle(for csc: UICloudSharingController) -> String? { "eSheep+ 测试牧场" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {}
    }
}
