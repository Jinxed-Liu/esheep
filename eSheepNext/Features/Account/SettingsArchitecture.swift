import SwiftData
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
    case cloudRecovery
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
        if cloudEnabled && capabilities.allows(.recoverFarm) {
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
    let title: String
    let subtitle: String
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
                Label(document.title, systemImage: document.systemImage)
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
            Text(errorMessage ?? "")
        }
    }

    private func deleteAccount() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await IdentityWorkerClient.shared.deleteAccount()
                modelContext.delete(account)
                try modelContext.save()
                session.authenticationDidSignOut(warning: "账户已删除。")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct JoinFarmView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CloudCollaborationStore.self) private var collaboration

    let account: AccountProfile

    @State private var code = ""
    @State private var result: WorkerRedeemResponse?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var normalizedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("先打开牧场主发来的共享邀请，再输入邀请码。", systemImage: "1.circle")
                    Label("邀请码验证通过后，等待牧场主确认加入。", systemImage: "2.circle")
                } header: {
                    Text("加入步骤")
                }

                Section("邀请码") {
                    TextField("8 位邀请码", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)

                    Button(isWorking ? "正在验证…" : "验证并申请加入") {
                        redeem()
                    }
                    .disabled(isWorking || normalizedCode.count != 8)
                }

                if let result {
                    Section("申请已提交") {
                        LabeledContent("成员角色", value: result.role.displayName)
                        Text("牧场主确认后，牧场会自动出现在切换菜单中。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("加入牧场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "取消" : "完成") {
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
                Text(errorMessage ?? "")
            }
        }
    }

    private func redeem() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let service = InviteServiceActor(persistence: collaboration.persistence)
                result = try await service.redeem(code: normalizedCode)
                code = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
