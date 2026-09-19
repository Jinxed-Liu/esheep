import ImageIO
import SwiftData
import SwiftUI
import UIKit

struct AccountAvatarDraft: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct AccountAvatarCropEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let account: AccountProfile
    let draft: AccountAvatarDraft

    @State private var zoom: CGFloat = 1
    // Offset is a fraction of the crop diameter, independent of screen size.
    @State private var offset: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var translation: CGSize = .zero
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var effectiveZoom: CGFloat { min(max(zoom * magnification, 1), 4) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 8) {
                        Text("选一个喜欢的角度")
                            .font(.title2.weight(.semibold))
                        Text("拖动照片调整位置，双指缩放")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                    GeometryReader { geometry in
                        cropPreview(side: geometry.size.width)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 340)

                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            Image(systemName: "minus.magnifyingglass")
                                .accessibilityHidden(true)
                            Slider(value: $zoom, in: 1...4)
                                .accessibilityLabel("照片缩放")
                            Image(systemName: "plus.magnifyingglass")
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                        Button("重新居中", systemImage: "arrow.counterclockwise") {
                            zoom = 1
                            offset = .zero
                        }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                    }
                    .frame(maxWidth: 340)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .disabled(isSaving)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action: saveAvatar) {
                    HStack(spacing: 10) {
                        if isSaving { ProgressView().tint(.white) }
                        Text(isSaving ? "正在保存头像" : "使用这张头像")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(isSaving)
                .accessibilityIdentifier("account-avatar-confirm")
                .frame(maxWidth: 440)
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(AppTheme.pageBackground)
            }
            .background(AppTheme.pageBackground)
            .navigationTitle("调整头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .onChange(of: zoom) {
                offset = AvatarCropGeometry.clampedOffset(imageSize: draft.image.size, zoom: zoom, offset: offset)
            }
            .alert("头像没有保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("继续调整", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .tint(AppTheme.brand)
        .interactiveDismissDisabled(isSaving)
    }

    private func cropPreview(side: CGFloat) -> some View {
        let proposedOffset = CGSize(
            width: offset.width + translation.width / max(side, 1),
            height: offset.height + translation.height / max(side, 1)
        )
        let rect = AvatarCropGeometry.drawRect(
            imageSize: draft.image.size, side: side, zoom: effectiveZoom, offset: proposedOffset
        )
        return Image(uiImage: draft.image)
            .resizable()
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .frame(width: side, height: side)
            .clipShape(.circle)
            .overlay { Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
            .contentShape(.circle)
            .gesture(
                DragGesture()
                    .updating($translation) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset = AvatarCropGeometry.clampedOffset(
                            imageSize: draft.image.size,
                            zoom: effectiveZoom,
                            offset: CGSize(
                                width: offset.width + value.translation.width / max(side, 1),
                                height: offset.height + value.translation.height / max(side, 1)
                            )
                        )
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnification) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 1), 4) }
            )
            .accessibilityLabel("头像裁剪预览")
            .accessibilityHint("可使用缩放滑块或位置调整操作")
            .accessibilityAction(named: Text("向左移动")) { move(x: -0.1, y: 0) }
            .accessibilityAction(named: Text("向右移动")) { move(x: 0.1, y: 0) }
            .accessibilityAction(named: Text("向上移动")) { move(x: 0, y: -0.1) }
            .accessibilityAction(named: Text("向下移动")) { move(x: 0, y: 0.1) }
    }

    private func move(x: CGFloat, y: CGFloat) {
        offset = AvatarCropGeometry.clampedOffset(
            imageSize: draft.image.size, zoom: zoom,
            offset: CGSize(width: offset.width + x, height: offset.height + y)
        )
    }

    private func saveAvatar() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let previousDigest = account.avatarCloudDigest
                guard let data = ProfileAvatarProcessor.makeJPEG(from: draft.image, zoom: zoom, offset: offset) else {
                    throw ProfileAvatarError.invalidImage
                }
                try await AccountAvatarCloudSyncService.shared.upload(data, account: account, context: modelContext)
                if let previousDigest {
                    await ImageThumbnailPipeline.shared.invalidate(digest: previousDigest)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                // Retain the photo and crop so a failed upload can be retried.
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Shared by the preview and exported JPEG so they always show the same crop.
enum AvatarCropGeometry {
    static func clampedOffset(imageSize: CGSize, zoom: CGFloat, offset: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(1 / imageSize.width, 1 / imageSize.height) * min(max(zoom, 1), 4)
        let limitX = max(0, (imageSize.width * scale - 1) / 2)
        let limitY = max(0, (imageSize.height * scale - 1) / 2)
        return CGSize(
            width: min(max(offset.width, -limitX), limitX),
            height: min(max(offset.height, -limitY), limitY)
        )
    }

    static func drawRect(imageSize: CGSize, side: CGFloat, zoom: CGFloat, offset: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, side > 0 else { return .zero }
        let scale = max(side / imageSize.width, side / imageSize.height) * min(max(zoom, 1), 4)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let boundedOffset = clampedOffset(imageSize: imageSize, zoom: zoom, offset: offset)
        return CGRect(
            x: (side - size.width) / 2 + boundedOffset.width * side,
            y: (side - size.height) / 2 + boundedOffset.height * side,
            width: size.width, height: size.height
        )
    }
}

enum ProfileAvatarError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "无法读取这张照片，请选择另一张图片。" }
}

enum ProfileAvatarProcessor {
    nonisolated static func previewImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    static func makeJPEG(from image: UIImage, zoom: CGFloat, offset: CGSize, side: CGFloat = 384) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let rect = AvatarCropGeometry.drawRect(imageSize: image.size, side: side, zoom: zoom, offset: offset)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).jpegData(
            withCompressionQuality: 0.82
        ) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: rect)
        }
    }
}
