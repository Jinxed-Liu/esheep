import SwiftUI
import UIKit

struct SheepPhotoPreviewItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let candidates: [SheepPhotoReference]
    let displayedAt: Date?

    init?(
        candidates: [SheepPhotoReference],
        displayedAt: Date? = nil
    ) {
        guard let first = candidates.first else { return nil }
        id = first.id
        self.candidates = candidates
        self.displayedAt = displayedAt
    }
}

struct SheepPhotoViewer: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    @Environment(\.dismiss) private var dismiss

    let item: SheepPhotoPreviewItem
    let earTag: String

    @State private var loadState: LoadState = .loading
    @State private var retryToken = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 16) {
                Text(earTag)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("关闭照片大图")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.82))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let displayedAt = item.displayedAt {
                Text(displayedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.82))
            }
        }
        .task(id: LoadKey(
            candidates: item.candidates,
            retryToken: retryToken
        )) {
            await loadPhoto()
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView("正在加载照片")
                .tint(.white)
                .foregroundStyle(.white)
        case .loaded(let image):
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityLabel("\(earTag)羊只照片大图")
            }
        case .failed:
            VStack(spacing: 16) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 44, weight: .semibold))
                Text("照片加载失败")
                    .font(.headline)
                Button("重新加载") {
                    retryToken &+= 1
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
        }
    }

    @MainActor
    private func loadPhoto() async {
        loadState = .loading
        for candidate in item.candidates {
            guard !Task.isCancelled else { return }
            do {
                let data = try await collaboration.loadPhotoData(assetID: candidate.id)
                let decodeTask = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else { return nil as UIImage? }
                    return UIImage(data: data)
                }
                let image = await withTaskCancellationHandler {
                    await decodeTask.value
                } onCancel: {
                    decodeTask.cancel()
                }
                guard !Task.isCancelled else { return }
                if let image {
                    loadState = .loaded(image)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
        guard !Task.isCancelled else { return }
        loadState = .failed
    }

    private enum LoadState {
        case loading
        case loaded(UIImage)
        case failed
    }

    private struct LoadKey: Hashable {
        let candidates: [SheepPhotoReference]
        let retryToken: Int
    }
}
