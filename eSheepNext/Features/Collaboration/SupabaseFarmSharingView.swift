import SwiftData
import SwiftUI
import UIKit
import VisionKit

enum ESheepCloudFarmInvitationLink {
    static func url(code: String) -> URL? {
        var components = URLComponents()
        components.scheme = AppEnvironment.current == .staging
            ? "esheep-staging"
            : "esheep"
        components.host = "join-farm"
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url
    }

    static func code(from url: URL) -> String? {
        let supportedHosts = ["join-farm", "supabase-invite"]
        guard ["esheep", "esheep-staging"].contains(url.scheme?.lowercased() ?? ""),
              supportedHosts.contains(url.host?.lowercased() ?? ""),
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
        if profiles.first(where: { $0.farmID == farm.id })?.mode == .eSheepCloud {
            ESheepCloudFarmSharingView(account: account, farm: farm)
        } else if profiles.first(where: { $0.farmID == farm.id })?.mode == .supabase {
            ContentUnavailableView(
                "成员资料正在升级",
                systemImage: "person.2.badge.gearshape",
                description: Text("完成 eSheep+ 云安全迁移后，即可继续邀请和管理成员。现有成员关系不会被改动。")
            )
            .navigationTitle("成员与共享")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "成员与共享",
                systemImage: "person.2.slash",
                description: Text("当前牧场仅保存在本机。请先在“云存储”中启用 eSheep 云，再管理成员与共享。")
            )
            .navigationTitle("成员与共享")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ESheepCloudFarmSharingView: View {
    @Environment(CloudCollaborationStore.self) private var collaboration

    let account: AccountProfile
    let farm: FarmRecord

    @State private var members: [ESheepCloudMemberV2] = []
    @State private var inviteRole: FarmRole = .worker
    @State private var invite: ESheepCloudInvitationV2?
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
                    ForEach(members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName?.isEmpty == false
                                    ? member.displayName!
                                    : "牧场成员")
                                    .font(.body)
                                    .lineLimit(1)
                                Text(LocalizedStringKey(member.role.displayName))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if farm.role == .owner,
                               member.role != .owner,
                               member.status == .active {
                                Button("撤权", role: .destructive) {
                                    revoke(member.id)
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
                        if let invitationURL = ESheepCloudFarmInvitationLink.url(code: invite.code) {
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
               let invitationURL = ESheepCloudFarmInvitationLink.url(code: invite.code) {
                ESheepCloudFarmInvitationQRCodeView(
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
        do {
            members = try await collaboration.eSheepCloudMembers(farmID: farm.id)
        } catch {
            errorMessage = naturalCloudMessage(for: error)
        }
    }

    private func createInvite() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                invite = try await collaboration.createESheepCloudInvitation(
                    farmID: farm.id,
                    role: inviteRole
                )
            } catch {
                errorMessage = naturalCloudMessage(for: error)
            }
        }
    }

    private func revoke(_ memberID: UUID) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await collaboration.revokeESheepCloudMember(
                    farmID: farm.id,
                    memberID: memberID
                )
                await refresh()
            } catch {
                errorMessage = naturalCloudMessage(for: error)
            }
        }
    }
}

struct ESheepCloudJoinFarmView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CloudCollaborationStore.self) private var collaboration

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
                Section("eSheep+ 云一次性邀请码") {
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
                        Label("扫描 eSheep+ 云邀请二维码", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("扫码和粘贴邀请码的效果相同；邀请码只能使用一次。")
                }
            }
            .navigationTitle("加入云端牧场")
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
                ESheepCloudFarmInvitationQRCodeScannerView { scannedCode in
                    code = scannedCode
                }
            }
        }
    }

    private func redeem() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let farm = try await collaboration.redeemAndReceiveESheepCloudFarm(
                    code: code
                )
                onJoined(farm)
                dismiss()
            } catch {
                errorMessage = naturalCloudMessage(for: error)
            }
        }
    }
}

private func naturalCloudMessage(for error: Error) -> String {
    switch error {
    case let value as ESheepCloudMembershipError:
        value.localizedDescription
    case let value as ESheepCloudInitialSyncError:
        value.localizedDescription
    case let value as ESheepCloudRuntimeError:
        value.localizedDescription
    case is CancellationError:
        "操作已暂停，重新打开后会从已完成的位置继续。"
    default:
        "eSheep+ 云暂时无法完成这项操作，请稍后再试。"
    }
}

private struct ESheepCloudFarmInvitationQRCodeView: View {
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
                        .accessibilityLabel("加入\(farmName)的 eSheep+ 云邀请二维码")
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

private struct ESheepCloudFarmInvitationQRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                FarmInvitationDataScanner { value in
                    guard let url = URL(string: value),
                          let code = ESheepCloudFarmInvitationLink.code(from: url) else {
                        errorMessage = "这不是有效的 eSheep+ 云邀请二维码。"
                        return
                    }
                    onScanned(code)
                    dismiss()
                }
                .ignoresSafeArea()
                Label("将 eSheep+ 云邀请二维码放入取景框", systemImage: "qrcode.viewfinder")
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
