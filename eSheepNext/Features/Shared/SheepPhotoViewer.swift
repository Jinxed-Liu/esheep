import SwiftUI
import UIKit

struct SheepPhotoPreviewItem: Identifiable, Sendable, Hashable {
    struct Photo: Identifiable, Sendable, Hashable {
        let reference: SheepPhotoReference
        let displayedAt: Date?
        var id: UUID { reference.id }
    }

    let id: UUID
    let photos: [Photo]
    let initialPhotoID: UUID

    init?(photos: [Photo], selectedPhotoID: UUID? = nil) {
        var seen = Set<UUID>()
        let uniquePhotos = photos.filter { seen.insert($0.id).inserted }
        guard let first = uniquePhotos.first else { return nil }
        self.photos = uniquePhotos
        initialPhotoID = uniquePhotos.first { $0.id == selectedPhotoID }?.id ?? first.id
        id = initialPhotoID
    }
}

struct SheepPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss

    let item: SheepPhotoPreviewItem
    let earTag: String

    // The cover owns a fixed gallery snapshot; selection is seeded once per presentation.
    @State private var selectedPhotoID: UUID

    init(item: SheepPhotoPreviewItem, earTag: String) {
        self.item = item
        self.earTag = earTag
        _selectedPhotoID = State(initialValue: item.initialPhotoID)
    }

    private var selectedIndex: Int {
        item.photos.firstIndex { $0.id == selectedPhotoID } ?? 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selectedPhotoID) {
                ForEach(item.photos) { photo in
                    SheepPhotoPage(
                        photo: photo.reference,
                        earTag: earTag,
                        isActive: photo.id == selectedPhotoID
                    )
                    .tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityIdentifier("sheep-photo-pager")
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
                        .frame(width: 44, height: 44)
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
            VStack(spacing: 8) {
                if item.photos.count > 1 {
                    HStack(spacing: 24) {
                        Button { moveSelection(by: -1) } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("上一张照片")
                        .disabled(selectedIndex == 0)
                        Text("\(selectedIndex + 1) / \(item.photos.count)")
                            .monospacedDigit()
                            .accessibilityLabel("第 \(selectedIndex + 1) 张，共 \(item.photos.count) 张")
                            .accessibilityIdentifier("sheep-photo-position")
                        Button { moveSelection(by: 1) } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("下一张照片")
                        .disabled(selectedIndex == item.photos.count - 1)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                if let displayedAt = item.photos[selectedIndex].displayedAt {
                    Text(displayedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .foregroundStyle(.white)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.82))
        }
        .preferredColorScheme(.dark)
    }

    private func moveSelection(by offset: Int) {
        let next = selectedIndex + offset
        guard item.photos.indices.contains(next) else { return }
        selectedPhotoID = item.photos[next].id
    }
}

private struct SheepPhotoPage: View {
    @Environment(CloudCollaborationStore.self) private var collaboration
    let photo: SheepPhotoReference
    let earTag: String
    let isActive: Bool

    @State private var loadState: LoadState = .loading
    @State private var retryToken = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: LoadKey(photo: photo, isActive: isActive, retryToken: retryToken)) {
                // Release the previous original and cancel its request when moving away.
                guard isActive else {
                    loadState = .loading
                    return
                }
                await loadPhoto()
            }
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
        guard !Task.isCancelled else { return }
        do {
            let data = try await collaboration.loadPhotoData(assetID: photo.id)
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
            // Failure belongs to this photo; never substitute another gallery page.
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
        let photo: SheepPhotoReference
        let isActive: Bool
        let retryToken: Int
    }
}
