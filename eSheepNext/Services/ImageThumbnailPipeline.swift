import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit

struct ImageThumbnail: @unchecked Sendable {
    let cgImage: CGImage
    let scale: CGFloat
}

protocol ImageThumbnailProviding: Sendable {
    func thumbnail(
        data: Data,
        digest: String,
        targetSize: CGSize,
        scale: CGFloat
    ) async -> ImageThumbnail?

    func invalidate(digest: String) async
    func removeAll() async
}

actor ImageThumbnailPipeline: ImageThumbnailProviding {
    static let shared = ImageThumbnailPipeline()

    private final class CacheBox: NSObject {
        let thumbnail: ImageThumbnail

        init(_ thumbnail: ImageThumbnail) {
            self.thumbnail = thumbnail
        }
    }

    private let cache = NSCache<NSString, CacheBox>()
    private var keysByDigest: [String: Set<String>] = [:]

    init(countLimit: Int = 96, totalCostLimit: Int = 48 * 1_024 * 1_024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func thumbnail(
        data: Data,
        digest: String,
        targetSize: CGSize,
        scale: CGFloat
    ) async -> ImageThumbnail? {
        let normalizedScale = max(1, scale)
        let pixelWidth = max(1, Int(ceil(targetSize.width * normalizedScale)))
        let pixelHeight = max(1, Int(ceil(targetSize.height * normalizedScale)))
        let maxPixelSize = max(pixelWidth, pixelHeight)
        let key = "\(digest)|\(pixelWidth)x\(pixelHeight)|\(normalizedScale)"
        if let cached = cache.object(forKey: key as NSString)?.thumbnail {
            return cached
        }
        guard !Task.isCancelled else { return nil }

        let interval = PerformanceTrace.begin(.imageDecode, count: data.count)
        defer { PerformanceTrace.end(interval) }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard !Task.isCancelled,
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  thumbnailOptions as CFDictionary
              ) else {
            return nil
        }

        let result = ImageThumbnail(cgImage: image, scale: normalizedScale)
        let cost = image.bytesPerRow * image.height
        cache.setObject(CacheBox(result), forKey: key as NSString, cost: cost)
        keysByDigest[digest, default: []].insert(key)
        return result
    }

    func invalidate(digest: String) async {
        guard let keys = keysByDigest.removeValue(forKey: digest) else { return }
        for key in keys {
            cache.removeObject(forKey: key as NSString)
        }
    }

    func removeAll() async {
        cache.removeAllObjects()
        keysByDigest.removeAll(keepingCapacity: true)
    }
}

@MainActor
enum ImageThumbnailMemoryPressureMonitor {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await ImageThumbnailPipeline.shared.removeAll()
            }
        }
    }
}

struct DownsampledDataImage<Placeholder: View>: View {
    @Environment(\.displayScale) private var displayScale

    let data: Data
    let digest: String
    let targetSize: CGSize
    let contentMode: ContentMode
    @ViewBuilder let placeholder: Placeholder

    @State private var thumbnail: ImageThumbnail?

    init(
        data: Data,
        digest: String,
        targetSize: CGSize,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.data = data
        self.digest = digest
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(
                    decorative: thumbnail.cgImage,
                    scale: thumbnail.scale,
                    orientation: .up
                )
                .resizable()
                .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: requestID) {
            let loaded = await ImageThumbnailPipeline.shared.thumbnail(
                data: data,
                digest: digest,
                targetSize: targetSize,
                scale: displayScale
            )
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
    }

    private var requestID: RequestID {
        RequestID(
            digest: digest,
            pixelWidth: Int(ceil(targetSize.width * displayScale)),
            pixelHeight: Int(ceil(targetSize.height * displayScale))
        )
    }

    private struct RequestID: Hashable {
        let digest: String
        let pixelWidth: Int
        let pixelHeight: Int
    }
}
