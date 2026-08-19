import SwiftData
import SwiftUI
import UIKit
import VisionKit

enum SupabaseFarmInvitationLink {
    static func url(code: String) -> URL? {
        var components = URLComponents()
        components.scheme = AppEnvironment.current == .staging
            ? "esheep-staging"
            : "esheep"
        components.host = "supabase-invite"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url
    }

    static func code(from url: URL) -> String? {
        guard ["esheep", "esheep-staging"].contains(url.scheme?.lowercased() ?? ""),
              url.host == "supabase-invite",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }
}

struct FarmMembersAndSharingView: View {
    @Query private var profiles: [FarmStorageProfile]

    let account: AccountProfile
    let farm: FarmRecord

    var body: some View {
        if profiles.first(where: { $0.farmID == farm.id })?.mode == .supabase {
            SupabaseFarmSharingView(account: account, farm: farm)
        } else {
            #if DEBUG
            CloudCollaborationCenterView(account: account, farm: farm)
            #else
            ContentUnavailableView(
                "成员与共享",
                systemImage: "externaldrive.badge.icloud",
                description: Text("CloudKit 仅用于读取和迁移旧牧场。3.1 新建云端牧场以 Supabase 为权威；每个牧场的数据彼此独立。")
            )
            .navigationTitle("成员与共享")
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

struct SupabaseFarmSharingView: View {
    let account: AccountProfile
    let farm: FarmRecord

    @State private var members: [FarmRemoteMember] = []
    @State private var inviteRole: FarmRole = .worker
    @State private var invite: SupabaseFarmInvite?
    @State private var isQRCodePresented = false
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
                                Text(LocalizedStringKey(member.role.displayName))
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
                        Text(LocalizedStringKey(FarmRole.worker.displayName)).tag(FarmRole.worker)
                        Text(LocalizedStringKey(FarmRole.administrator.displayName)).tag(FarmRole.administrator)
                    }
                    Button(isWorking ? LocalizedStringKey("正在生成…") : LocalizedStringKey("生成 24 小时邀请码")) {
                        createInvite()
                    }
                    .disabled(isWorking)

                    if let invite {
                        Text(invite.code)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        if let invitationURL = SupabaseFarmInvitationLink.url(code: invite.code) {
                            Button {
                                isQRCodePresented = true
                            } label: {
                                Label("显示邀请二维码", systemImage: "qrcode")
                            }
                            ShareLink(
                                item: invitationURL,
                                subject: Text("邀请你加入\(farm.name)"),
                                message: Text("请用 eSheep+ 打开链接，或在“加入牧场”中扫描二维码。")
                            ) {
                                Label("分享邀请", systemImage: "square.and.arrow.up")
                            }
                        } else {
                            ShareLink(item: invite.code) {
                                Label("分享邀请码", systemImage: "square.and.arrow.up")
                            }
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
        .sheet(isPresented: $isQRCodePresented) {
            if let invite,
               let invitationURL = SupabaseFarmInvitationLink.url(code: invite.code) {
                SupabaseFarmInvitationQRCodeView(
                    farmName: farm.name,
                    role: inviteRole,
                    expiresAt: invite.expiresAt,
                    invitationURL: invitationURL
                )
            }
        }
        .alert("共享操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage ?? ""))
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
    @State private var isScannerPresented = false

    init(
        account: AccountProfile,
        initialCode: String? = nil,
        onJoined: @escaping @MainActor (FarmRecord) -> Void
    ) {
        self.account = account
        self.onJoined = onJoined
        _code = State(initialValue: initialCode ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Supabase 一次性邀请码") {
                    TextField("粘贴邀请码", text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button(isWorking ? LocalizedStringKey("正在加入…") : LocalizedStringKey("加入牧场")) {
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

                Section {
                    Button {
                        guard DataScannerViewController.isSupported,
                              DataScannerViewController.isAvailable else {
                            errorMessage = "当前设备无法使用二维码扫描，请粘贴邀请码。"
                            return
                        }
                        isScannerPresented = true
                    } label: {
                        Label("扫描 Supabase 邀请二维码", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("扫码和粘贴长邀请码使用同一个 Supabase 兑换流程。")
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
                Text(LocalizedStringKey(errorMessage ?? ""))
            }
            .sheet(isPresented: $isScannerPresented) {
                SupabaseFarmInvitationQRCodeScannerView { scannedCode in
                    code = scannedCode
                }
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

private struct SupabaseFarmInvitationQRCodeView: View {
    @Environment(\.dismiss) private var dismiss

    let farmName: String
    let role: FarmRole
    let expiresAt: Date
    let invitationURL: URL

    private var image: UIImage? {
        FarmInvitationQRCodeGenerator.image(
            for: invitationURL.absoluteString,
            dimension: 900
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 12)
                Text(farmName).font(.title2.bold())
                Text("请让对方打开 eSheep+ → 加入牧场 → 扫描二维码")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let image {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320)
                        .padding(18)
                        .background(.white, in: .rect(cornerRadius: 20))
                        .accessibilityLabel("加入\(farmName)的 Supabase 邀请二维码")
                } else {
                    ContentUnavailableView("二维码生成失败", systemImage: "qrcode")
                }
                Label(
                    "\(role.displayName) · \(expiresAt.formatted(date: .abbreviated, time: .shortened)) 前有效",
                    systemImage: "lock.shield.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("二维码邀请")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct SupabaseFarmInvitationQRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                FarmInvitationDataScanner { value in
                    guard let url = URL(string: value),
                          let code = SupabaseFarmInvitationLink.code(from: url) else {
                        errorMessage = "这不是有效的 eSheep+ Supabase 邀请二维码。"
                        return
                    }
                    onScanned(code)
                    dismiss()
                }
                .ignoresSafeArea()
                Label("将 Supabase 邀请二维码放入取景框", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 28)
            }
            .navigationTitle("扫描邀请")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("无法识别邀请", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("继续扫描", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(errorMessage ?? ""))
            }
        }
    }
}
