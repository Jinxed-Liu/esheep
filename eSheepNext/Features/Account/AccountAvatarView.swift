import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct AccountAvatarView: View {
    let account: AccountProfile
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let data = account.avatarImageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [AppTheme.brand, AppTheme.brandSoft],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(initials)
                        .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay { Circle().stroke(.white.opacity(0.72), lineWidth: size > 40 ? 2 : 1) }
        .contentShape(.circle)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let characters = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return characters.first.map(String.init) ?? "羊"
    }
}

struct AccountAvatarEditor: View {
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile

    @State private var selectedItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        let hasAvatar = account.avatarImageData != nil

        VStack(spacing: 14) {
            AccountAvatarView(account: account, size: 88)

            VStack(spacing: 8) {
                Text(account.displayName)
                    .font(.title3.bold())
                Text("头像会同步到使用同一 eSheep+ 账号的设备")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Label(hasAvatar ? "更换头像" : "选择头像", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)

                if hasAvatar {
                    Button("移除", systemImage: "trash", role: .destructive, action: removeAvatar)
                        .buttonStyle(.bordered)
                }
            }

            if isProcessing {
                ProgressView("正在同步头像")
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            importAvatar(from: item)
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

    private func importAvatar(from item: PhotosPickerItem) {
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do {
                guard let sourceData = try await item.loadTransferable(type: Data.self),
                      let avatarData = ProfileAvatarProcessor.makeJPEG(from: sourceData) else {
                    throw ProfileAvatarError.invalidImage
                }
                try await AccountAvatarCloudSyncService.shared.upload(
                    avatarData,
                    account: account,
                    context: modelContext
                )
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            selectedItem = nil
        }
    }

    private func removeAvatar() {
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do {
                try await AccountAvatarCloudSyncService.shared.remove(
                    account: account,
                    context: modelContext
                )
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum ProfileAvatarError: LocalizedError {
    case invalidImage

    var errorDescription: String? { "无法读取这张照片，请选择另一张图片。" }
}

private enum ProfileAvatarProcessor {
    static func makeJPEG(from data: Data, side: CGFloat = 384) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = max(side / sourceSize.width, side / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            source.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return image.jpegData(compressionQuality: 0.82)
    }
}
