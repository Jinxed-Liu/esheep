import SwiftData
import SwiftUI

struct FarmMembersAndSharingView: View {
    @Query private var profiles: [FarmStorageProfile]

    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        if profiles.first(where: { $0.farmID == farm.id })?.mode == .supabase {
            SupabaseFarmSharingView(account: account, farm: farm)
        } else {
            CloudCollaborationCenterView(account: account, farm: farm)
        }
    }
}

struct SupabaseFarmSharingView: View {
    let account: AccountProfile
    let farm: FarmRecord

    @State private var members: [FarmRemoteMember] = []
    @State private var inviteRole: FarmRole = .worker
    @State private var invite: SupabaseFarmInvite?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("成员") {
                if members.isEmpty {
                    Text("正在读取成员…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(members, id: \.accountID) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.accountID.uuidString.lowercased())
                                    .font(.footnote.monospaced())
                                    .lineLimit(1)
                                Text(member.role.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if farm.role == .owner,
                               member.role != .owner,
                               member.status == .active,
                               let userID = member.providerUserID {
                                Button("撤权", role: .destructive) {
                                    revoke(userID)
                                }
                                .disabled(isWorking)
                            }
                        }
                    }
                }
            }

            if farm.role == .owner || farm.role == .administrator {
                Section("一次性邀请") {
                    Picker("角色", selection: $inviteRole) {
                        Text(FarmRole.worker.displayName).tag(FarmRole.worker)
                        Text(FarmRole.administrator.displayName).tag(FarmRole.administrator)
                    }
                    Button(isWorking ? "正在生成…" : "生成 24 小时邀请码") {
                        createInvite()
                    }
                    .disabled(isWorking)

                    if let invite {
                        Text(invite.code)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        ShareLink(item: invite.code) {
                            Label("分享邀请码", systemImage: "square.and.arrow.up")
                        }
                        Text("服务端只保存 SHA-256；该 256 位随机邀请码只能兑换一次。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("成员与共享")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
        }
        .alert("共享操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refresh() async {
        guard let client = AccountIdentityClients.supabaseClient else {
            errorMessage = SupabaseFarmCloudError.notConfigured.localizedDescription
            return
        }
        do {
            members = try await SupabaseFarmTransport(client: client)
                .members(farmID: farm.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createInvite() {
        guard !isWorking,
              let client = AccountIdentityClients.supabaseClient else {
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                invite = try await SupabaseFarmInviteClient(client: client)
                    .create(farmID: farm.id, role: inviteRole)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func revoke(_ userID: UUID) {
        guard !isWorking,
              let client = AccountIdentityClients.supabaseClient else {
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await SupabaseFarmInviteClient(client: client)
                    .revoke(farmID: farm.id, memberUserID: userID)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct SupabaseJoinFarmView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let onJoined: @MainActor (FarmRecord) -> Void

    @State private var code = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Supabase 一次性邀请码") {
                    TextField("粘贴邀请码", text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button(isWorking ? "正在加入…" : "加入牧场") {
                        redeem()
                    }
                    .disabled(
                        isWorking ||
                        code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    if isWorking {
                        Label("正在验证成员资格并恢复牧场资料…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("加入 Supabase 牧场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
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
        guard !isWorking,
              let client = AccountIdentityClients.supabaseClient else {
            return
        }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let farm = try await SupabaseFarmJoinService(client: client).redeemAndInstall(
                    code: code,
                    accountID: account.effectiveAccountID,
                    context: modelContext
                )
                onJoined(farm)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
