import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct AccountAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme

    let account: AccountProfile
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let data = account.avatarImageData {
                DownsampledDataImage(
                    data: data,
                    digest: avatarDigest(for: data),
                    targetSize: CGSize(width: size, height: size)
                ) {
                    fallbackAvatar
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .contentShape(.circle)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let characters = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return characters.first.map(String.init) ?? "羊"
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle().fill(AppTheme.brand.opacity(colorScheme == .dark ? 0.24 : 0.10))
            Text(initials)
                .font(.system(size: size * 0.36, weight: .medium, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? AppTheme.brandSoft : AppTheme.brand)
        }
    }

    private func avatarDigest(for data: Data) -> String {
        account.avatarCloudDigest ??
            "account-avatar|\(account.id.uuidString)|\(account.updatedAt.timeIntervalSince1970)|\(data.count)"
    }
}

struct AccountAvatarEditor: View {
    let account: AccountProfile

    @State private var selectedItem: PhotosPickerItem?
    @State private var draft: AccountAvatarDraft?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        let loadingPhoto = isLoading
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 24) {
                    AccountAvatarView(account: account, size: 208)
                        .padding(10)
                        .background(.background, in: .circle)
                        .overlay { Circle().strokeBorder(.primary.opacity(0.05), lineWidth: 1) }
                        .accessibilityHidden(false)
                        .accessibilityLabel("当前账号头像")

                    VStack(spacing: 8) {
                        Text(account.displayName)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(account.avatarImageData == nil ? "为自己选一张喜欢的照片" : "让牧场伙伴一眼认出你")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 36)

                Label("头像会同步到你的其他设备", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    HStack(spacing: 10) {
                        if loadingPhoto { ProgressView().tint(.white) }
                        else { Image(systemName: "photo.on.rectangle.angled") }
                        Text(loadingPhoto ? "正在读取照片" : "从相册选择")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(loadingPhoto)
                .accessibilityIdentifier("account-avatar-select")
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(AppTheme.pageBackground)
        }
        .background(AppTheme.pageBackground)
        .task(id: selectedItem) {
            guard let item = selectedItem else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ProfileAvatarError.invalidImage
                }
                let image = await Task.detached(priority: .userInitiated) {
                    ProfileAvatarProcessor.previewImage(from: data)
                }.value
                try Task.checkCancellation()
                guard let image else { throw ProfileAvatarError.invalidImage }
                draft = AccountAvatarDraft(image: image)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            selectedItem = nil
        }
        .sheet(item: $draft) { draft in
            AccountAvatarCropEditor(account: account, draft: draft)
        }
        .alert("头像没有更新", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
