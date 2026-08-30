import SwiftData
import LocalAuthentication
import SwiftUI

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
    case dataConflicts
}

struct SettingsVisibilityPolicy: Equatable {
    let capabilities: CapabilitySet
    let cloudEnabled: Bool
    let memberSharingEnabled: Bool
    let subscriptionEnabled: Bool
    let unresolvedConflictCount: Int

    init(
        role: FarmRole,
        grantedWorkerCapabilities: Set<FarmCapability> = [],
        cloudEnabled: Bool,
        memberSharingEnabled: Bool = MemberSharingConfiguration.isEnabled,
        subscriptionEnabled: Bool,
        unresolvedConflictCount: Int
    ) {
        capabilities = CapabilitySet(
            role: role,
            grantedWorkerCapabilities: grantedWorkerCapabilities
        )
        self.cloudEnabled = cloudEnabled
        self.memberSharingEnabled = memberSharingEnabled
        self.subscriptionEnabled = subscriptionEnabled
        self.unresolvedConflictCount = unresolvedConflictCount
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
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session

    let account: AccountProfile

    @State private var isConfirmingWithdrawal = false
    @State private var isWithdrawing = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("法律文件") {
                ForEach(LegalDocument.allCases) { document in
                    NavigationLink {
                        LegalDocumentView(document: document)
                    } label: {
                        Label(
                            LocalizedStringKey(document.title),
                            systemImage: document.systemImage
                        )
                    }
                }
            }

            Section("同意状态") {
                LabeledContent("服务条款", value: account.acceptedTermsVersion.isEmpty
                    ? "未记录"
                    : account.acceptedTermsVersion)
                LabeledContent("隐私政策", value: account.acceptedPrivacyVersion.isEmpty
                    ? "未记录"
                    : account.acceptedPrivacyVersion)
                LabeledContent(
                    "当前状态",
                    value: hasCurrentLegalConsent ? "已同意当前版本" : "需要重新确认"
                )

                Button("撤回境外云处理同意并退出", role: .destructive) {
                    isConfirmingWithdrawal = true
                }
                .disabled(isWithdrawing || !hasAnyRecordedConsent)
            }
        }
        .navigationTitle("隐私与条款")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "撤回同意后停止云服务",
            isPresented: $isConfirmingWithdrawal,
            titleVisibility: .visible
        ) {
            Button("撤回并退出", role: .destructive) {
                withdrawLegalConsent()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("App 会立即停止当前账号的新云同步和 AI 调用并退出登录。本机缓存不会自动删除；请先导出所需数据。再次登录前必须重新阅读并明确同意。删除云端账号和历史数据需另行使用“删除账户”。")
        }
        .alert("撤回操作未完整完成", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var hasCurrentLegalConsent: Bool {
        account.acceptedTermsVersion == LegalPolicyVersions.terms &&
            account.acceptedPrivacyVersion == LegalPolicyVersions.privacy &&
            LegalConsentStore.hasCurrentConsent(for: account.effectiveAccountID)
    }

    private var hasAnyRecordedConsent: Bool {
        !account.acceptedTermsVersion.isEmpty ||
            !account.acceptedPrivacyVersion.isEmpty ||
            LegalConsentStore.receipt(for: account.effectiveAccountID) != nil
    }

    private func withdrawLegalConsent() {
        guard !isWithdrawing else { return }
        isWithdrawing = true

        Task { @MainActor in
            var warnings: [String] = []
            let accountID = account.effectiveAccountID
            let identity: (any AccountIdentityClient)?

            do {
                identity = try AccountIdentityClients.active()
            } catch {
                identity = nil
                warnings.append("账号服务不可用，服务器撤回凭证需稍后人工核对：\(error.localizedDescription)")
            }

            if let identity {
                do {
                    try await identity.recordLegalConsentWithdrawal(
                        LegalConsentWithdrawalEvent()
                    )
                } catch {
                    warnings.append("服务器未能写入撤回凭证：\(error.localizedDescription)")
                }
            }

            if AIPrivacyConsentStore.hasCurrentConsent(for: accountID),
               let identity {
                do {
                    try await identity.recordAIPrivacyConsent(
                        AIPrivacyConsentEvent(action: .withdrawn)
                    )
                } catch {
                    warnings.append("AI 撤回凭证未能同步：\(error.localizedDescription)")
                }
            }

            do {
                try LegalConsentStore.remove(for: accountID)
                try AIPrivacyConsentStore.withdraw(for: accountID)
            } catch {
                warnings.append("本机安全凭证清理失败：\(error.localizedDescription)")
            }

            account.acceptedTermsVersion = ""
            account.acceptedPrivacyVersion = ""
            account.updatedAt = .now
            do {
                try modelContext.save()
            } catch {
                warnings.append("本机账号状态保存失败：\(error.localizedDescription)")
            }

            if let identity {
                do {
                    let result = try await identity.signOut()
                    if let warning = result.warningMessage {
                        warnings.append(warning)
                    }
                } catch {
                    warnings.append("服务器会话未能即时撤销：\(error.localizedDescription)")
                }
            }

            await ImageThumbnailPipeline.shared.removeAll()
            let message = (["已撤回当前版本同意并停止本机云处理。"] + warnings)
                .joined(separator: "\n")
            session.authenticationDidSignOut(warning: message)
            isWithdrawing = false
        }
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
