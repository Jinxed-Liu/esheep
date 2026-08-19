import SwiftData
import LocalAuthentication
import SwiftUI
import VisionKit

enum SettingsDestination: String, CaseIterable, Hashable {
    case accountAvatar
    case accountDisplayName
    case notifications
    case dataStorage
    case appearance
    case powerSaving
    case language
    case insightAssistant
    case privacyAndTerms
    case subscription
    case farmLocation
    case membersAndSharing
    case importData
    case exportData
    case localBackup
    case cloudRecovery
    case dataConflicts
}

struct SettingsVisibilityPolicy: Equatable {
    let capabilities: CapabilitySet
    let cloudEnabled: Bool
    let memberSharingEnabled: Bool
    let subscriptionEnabled: Bool
    let unresolvedConflictCount: Int
    let storageMode: FarmStorageMode

    init(
        role: FarmRole,
        grantedWorkerCapabilities: Set<FarmCapability> = [],
        cloudEnabled: Bool,
        memberSharingEnabled: Bool = MemberSharingConfiguration.isEnabled,
        subscriptionEnabled: Bool,
        unresolvedConflictCount: Int,
        storageMode: FarmStorageMode = .localOnly
    ) {
        capabilities = CapabilitySet(
            role: role,
            grantedWorkerCapabilities: grantedWorkerCapabilities
        )
        self.cloudEnabled = cloudEnabled
        self.memberSharingEnabled = memberSharingEnabled
        self.subscriptionEnabled = subscriptionEnabled
        self.unresolvedConflictCount = unresolvedConflictCount
        self.storageMode = storageMode
    }

    var mainDestinations: [SettingsDestination] {
        [
            .accountAvatar,
            .accountDisplayName,
            .notifications,
            .dataStorage,
            .appearance,
            .powerSaving,
            .language,
            .insightAssistant,
            .privacyAndTerms,
        ]
    }

    var accountDestinations: Set<SettingsDestination> {
        subscriptionEnabled ? [.subscription] : []
    }

    var farmDestinations: Set<SettingsDestination> {
        var destinations: Set<SettingsDestination> = []
        if capabilities.allows(.editFarmLocation) {
            destinations.insert(.farmLocation)
        }
        if cloudEnabled && memberSharingEnabled {
            destinations.insert(.membersAndSharing)
        }
        if capabilities.allows(.recordProduction) {
            destinations.insert(.importData)
            destinations.insert(.localBackup)
        }
        if capabilities.allows(.exportFarm) {
            destinations.insert(.exportData)
            destinations.insert(.localBackup)
        }
        if storageMode == .iCloud && capabilities.allows(.recoverFarm) {
            destinations.insert(.cloudRecovery)
        }
        if unresolvedConflictCount > 0 && capabilities.allows(.resolveConflicts) {
            destinations.insert(.dataConflicts)
        }
        return destinations
    }

    func shows(_ destination: SettingsDestination) -> Bool {
        mainDestinations.contains(destination)
            || accountDestinations.contains(destination)
            || farmDestinations.contains(destination)
    }
}

struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.brand)
        }
        .padding(.vertical, 2)
    }
}

struct AccountAvatarSettingsView: View {
    let account: AccountProfile

    var body: some View {
        List {
            Section {
                AccountAvatarEditor(account: account)
            }
        }
        .navigationTitle("头像")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyAndTermsSettingsView: View {
    var body: some View {
        List(LegalDocument.allCases) { document in
            NavigationLink {
                LegalDocumentView(document: document)
            } label: {
                Label(LocalizedStringKey(document.title), systemImage: document.systemImage)
            }
        }
        .navigationTitle("隐私与条款")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountDeletionButton: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session

    let account: AccountProfile

    @State private var isConfirming = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Button("删除账户", role: .destructive) {
            isConfirming = true
        }
        .disabled(isWorking)
        .confirmationDialog("确认删除账户", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("永久删除账户", role: .destructive) {
                deleteAccount()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会撤销登录与共享关系，且无法撤销。若你仍拥有牧场，系统会要求先处理这些牧场。")
        }
        .alert("无法删除账户", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage ?? ""))
        }
    }

    private func deleteAccount() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                guard session.accountAccessStatus.allowsCloudOperations else {
                    session.isReauthenticationPresented = true
                    throw AccountDeletionAuthorizationError.freshSignInRequired
                }
                _ = try await AccountIdentityClients.active().refreshSession()
                try await AccountDeletionAuthorization.confirmBiometrics()
                let deletion = try await AccountIdentityClients.active().deleteAccount()
                modelContext.delete(account)
                try modelContext.save()
                session.authenticationDidSignOut(
                    warning: "删除申请已提交（任务 \(deletion.deletionJobID)）。服务器将在完成检查后处理；请保存任务编号。"
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

enum AccountDeletionAuthorizationError: LocalizedError {
    case freshSignInRequired

    var errorDescription: String? {
        "删除账号前必须先完成一次有效登录，然后重新确认。"
    }
}

enum AccountDeletionAuthorization {
    static func confirmBiometrics() async throws {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &evaluationError
        ) else {
            throw evaluationError ?? AccountDeletionAuthorizationError.freshSignInRequired
        }
        let approved = try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "确认提交 eSheep+ 账号删除申请"
        )
        guard approved else {
            throw AccountDeletionAuthorizationError.freshSignInRequired
        }
    }
}

struct JoinFarmView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppSession.self) private var session
    @Environment(CloudCollaborationStore.self) private var collaboration

    let account: AccountProfile

    @State private var code = ""
    @State private var result: WorkerRedeemResponse?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isProximityReceiverPresented = false
    @State private var isQRCodeScannerPresented = false
    @State private var shareURL: URL?
    @State private var isSupabaseJoinPresented = false
    @State private var supabaseJoinedFarmID: UUID?

    private var normalizedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                if SupabaseAccountConfiguration.isConfigured {
                    Section {
                        Button {
                            isSupabaseJoinPresented = true
                        } label: {
                            Label(
                                "使用 Supabase 一次性邀请码",
                                systemImage: "externaldrive.connected.to.line.below"
                            )
                        }
                    } footer: {
                        Text("Supabase 邀请为 256 位随机码，24 小时内只能兑换一次。")
                    }
                }

                Section {
                    Button {
                        guard DataScannerViewController.isSupported,
                              DataScannerViewController.isAvailable else {
                            errorMessage = "当前设备暂时不能使用相机扫描，请检查相机权限，或手动输入邀请码。"
                            return
                        }
                        isQRCodeScannerPresented = true
                    } label: {
                        Label("扫描邀请二维码", systemImage: "qrcode.viewfinder")
                    }

                    Button {
                        isProximityReceiverPresented = true
                    } label: {
                        Label("靠近接收邀请", systemImage: "wave.3.left.circle.fill")
                    }
                } footer: {
                    Text("与场主面对面时，双方打开靠近邀请页面，将手机并排放置并逐渐靠近；不要让顶部相碰，以免触发系统 NameDrop。")
                }

                Section {
                    Label("输入邀请消息中的 8 位邀请码。", systemImage: "1.circle")
                    Label("等待场主批准你的 iCloud 身份。", systemImage: "2.circle")
                    Label("场主批准后，打开邀请链接接受共享。", systemImage: "3.circle")
                } header: {
                    Text("加入步骤")
                }

                Section("邀请码") {
                    TextField("8 位邀请码", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)

                    Button(isWorking ? LocalizedStringKey("正在验证…") : LocalizedStringKey("验证并申请加入")) {
                        redeem()
                    }
                    .disabled(isWorking || normalizedCode.count != 8)
                }

                if let result {
                    Section("申请已提交") {
                        LabeledContent("成员角色") {
                            Text(LocalizedStringKey(result.role.displayName))
                        }
                        Text("牧场主确认后，牧场会自动出现在切换菜单中。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let shareURL {
                            Button("场主批准后接受共享") {
                                openURL(shareURL)
                            }
                        }
                    }
                }
            }
            .navigationTitle("加入牧场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? LocalizedStringKey("取消") : LocalizedStringKey("完成")) {
                        dismiss()
                    }
                }
            }
            .alert("无法加入牧场", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(errorMessage ?? ""))
            }
            .sheet(isPresented: $isProximityReceiverPresented) {
                ProximityInvitationReceiverView(accountID: account.effectiveAccountID)
            }
            .sheet(isPresented: $isQRCodeScannerPresented) {
                FarmInvitationQRCodeScannerView { invitation in
                    code = invitation.code
                    shareURL = invitation.shareURL
                }
            }
            .task {
                guard let invitation = session.pendingFarmInvitation else { return }
                code = invitation.code
                shareURL = invitation.shareURL
                session.pendingFarmInvitation = nil
            }
        }
        .sheet(isPresented: $isSupabaseJoinPresented) {
            SupabaseJoinFarmView(account: account) { farm in
                supabaseJoinedFarmID = farm.id
            }
        }
        .onChange(of: isSupabaseJoinPresented) { _, isPresented in
            guard !isPresented,
                  let farmID = supabaseJoinedFarmID else { return }
            supabaseJoinedFarmID = nil
            session.selectedFarmID = farmID
            dismiss()
        }
    }

    private func redeem() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let service = InviteServiceActor(persistence: collaboration.persistence)
                let userRecordName = try await collaboration.sync.currentCloudUserRecordName()
                let redemption = try await service.redeem(
                    code: normalizedCode,
                    cloudKitUserRecordName: userRecordName
                )
                result = redemption
                shareURL = redemption.shareURL ?? shareURL
                code = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
