import ImageIO
import SwiftUI
import UIKit
import Vision

private enum SheepPhotoRenderingMode: String, Sendable, Hashable {
    case fullFrame
    case headFocused
}

struct SheepAvatarView: View {
    let photo: SheepPhotoReference?
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
            if let photo {
                SheepPhotoImage(
                    photos: [photo],
                    maximumPixelSize: Int(size * 3),
                    renderingMode: .headFocused
                )
            } else {
                Image(systemName: "sheep")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(AppTheme.brand)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

struct SheepBannerPhotoView: View {
    let photos: [SheepPhotoReference]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.brand.opacity(0.24),
                    Color(uiColor: .secondarySystemGroupedBackground),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if !photos.isEmpty {
                SheepPhotoImage(
                    photos: photos,
                    maximumPixelSize: 1_200,
                    renderingMode: .fullFrame
                )
            } else {
                Image(systemName: "sheep")
                    .font(.system(size: 74, weight: .semibold))
                    .foregroundStyle(AppTheme.brand.opacity(0.72))
            }
        }
    }
}

private struct SheepPhotoImage: View {
    @Environment(CloudCollaborationStore.self) private var collaboration

    let photos: [SheepPhotoReference]
    let maximumPixelSize: Int
    let renderingMode: SheepPhotoRenderingMode
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Image(systemName: "sheep")
                    .font(.system(
                        size: min(74, max(22, CGFloat(maximumPixelSize) * 0.16)),
                        weight: .semibold
                    ))
                    .foregroundStyle(AppTheme.brand.opacity(0.72))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(
            photos: photos,
            maximumPixelSize: maximumPixelSize,
            renderingMode: renderingMode
        )) {
            image = nil
            didFail = false
            var loaded: UIImage?
            for photo in photos {
                guard !Task.isCancelled else { return }
                loaded = await SheepPhotoThumbnailCache.image(
                    for: photo,
                    maximumPixelSize: maximumPixelSize,
                    renderingMode: renderingMode,
                    collaboration: collaboration
                )
                if loaded != nil { break }
            }
            guard !Task.isCancelled else { return }
            image = loaded
            didFail = loaded == nil
        }
    }

    private struct LoadKey: Hashable {
        let photos: [SheepPhotoReference]
        let maximumPixelSize: Int
        let renderingMode: SheepPhotoRenderingMode
    }
}

@MainActor
private enum SheepPhotoThumbnailCache {
    static let cache = NSCache<NSString, UIImage>()

    static func image(
        for photo: SheepPhotoReference,
        maximumPixelSize: Int,
        renderingMode: SheepPhotoRenderingMode,
        collaboration: CloudCollaborationStore
    ) async -> UIImage? {
        let key = "\(photo.id.uuidString.lowercased()):\(photo.digest):\(maximumPixelSize):\(renderingMode.rawValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? await collaboration.loadPhotoData(assetID: photo.id) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let renderTask = Task.detached(priority: .userInitiated) {
            thumbnail(
                from: data,
                maximumPixelSize: maximumPixelSize,
                renderingMode: renderingMode
            )
        }
        let image = await withTaskCancellationHandler {
            await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
        guard !Task.isCancelled else { return nil }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private nonisolated static func thumbnail(
        from data: Data,
        maximumPixelSize: Int,
        renderingMode: SheepPhotoRenderingMode
    ) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let decodePixelSize = renderingMode == .headFocused
            ? max(1_024, maximumPixelSize * 4)
            : maximumPixelSize
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: max(1, decodePixelSize),
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else {
            return nil
        }
        guard renderingMode == .headFocused else {
            return UIImage(cgImage: cgImage)
        }
        guard !Task.isCancelled else { return nil }
        let cropRect = animalHeadCropRect(in: cgImage)
            ?? salientRegionCropRect(in: cgImage)
            ?? fallbackCropRect(in: cgImage)
        return squareThumbnail(
            from: cgImage,
            cropRect: cropRect,
            maximumPixelSize: maximumPixelSize
        )
    }

    /// Vision's animal-pose request exposes eyes, nose and ear landmarks. It
    /// gives the most accurate crop when the sheep is large enough in frame.
    private nonisolated static func animalHeadCropRect(in image: CGImage) -> CGRect? {
        guard !Task.isCancelled else { return nil }
        let request = VNDetectAnimalBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }

        var bestPoints: [VNRecognizedPoint] = []
        var bestScore: Float = -.greatestFiniteMagnitude
        for observation in request.results ?? [] {
            guard !Task.isCancelled,
                  let points = try? observation.recognizedPoints(.head) else {
                continue
            }
            let confidentPoints = points.values.filter { $0.confidence >= 0.18 }
            guard confidentPoints.count >= 2 else { continue }
            let averageConfidence = confidentPoints.reduce(Float.zero) {
                $0 + $1.confidence
            } / Float(confidentPoints.count)
            let xValues = confidentPoints.map { $0.location.x }
            let yValues = confidentPoints.map { $0.location.y }
            guard let minX = xValues.min(), let maxX = xValues.max(),
                  let minY = yValues.min(), let maxY = yValues.max() else {
                continue
            }
            let spread = Float(max(maxX - minX, maxY - minY))
            let score = averageConfidence
                + Float(min(confidentPoints.count, 9)) * 0.025
                + spread * 0.12
            if score > bestScore {
                bestScore = score
                bestPoints = confidentPoints
            }
        }
        guard !bestPoints.isEmpty else { return nil }

        let xValues = bestPoints.map { $0.location.x }
        let yValues = bestPoints.map { $0.location.y }
        guard let minX = xValues.min(), let maxX = xValues.max(),
              let minY = yValues.min(), let maxY = yValues.max() else {
            return nil
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let centerX = ((minX + maxX) * 0.5) * width
        let centerY = (1 - ((minY + maxY) * 0.5)) * height
        let landmarkSpan = max(
            (maxX - minX) * width,
            (maxY - minY) * height
        )
        let side = max(landmarkSpan * 2.15, min(width, height) * 0.36)
        return clampedSquareCropRect(
            centerX: centerX,
            centerY: centerY - side * 0.05,
            side: side,
            imageWidth: width,
            imageHeight: height
        )
    }

    /// When pose landmarks are unavailable, attention saliency still locates
    /// the visually dominant compact region instead of blindly center-cropping.
    private nonisolated static func salientRegionCropRect(in image: CGImage) -> CGRect? {
        guard !Task.isCancelled else { return nil }
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let objects = (request.results ?? []).flatMap { $0.salientObjects ?? [] }

        let candidate = objects
            .filter { $0.boundingBox.width * $0.boundingBox.height >= 0.004 }
            .max { lhs, rhs in
                saliencyScore(lhs) < saliencyScore(rhs)
            }
        guard let candidate else { return nil }

        let bounds = candidate.boundingBox
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let centerX = bounds.midX * width
        let centerY = (1 - bounds.midY) * height
        let objectSpan = max(bounds.width * width, bounds.height * height)
        let side = max(objectSpan * 1.75, min(width, height) * 0.48)
        return clampedSquareCropRect(
            centerX: centerX,
            centerY: centerY - side * 0.035,
            side: side,
            imageWidth: width,
            imageHeight: height
        )
    }

    private nonisolated static func saliencyScore(
        _ observation: VNRectangleObservation
    ) -> Float {
        let area = Float(observation.boundingBox.width * observation.boundingBox.height)
        let compactRegionScore = max(0, 1 - abs(area - 0.16) / 0.5)
        return observation.confidence * 2 + compactRegionScore * 0.4
    }

    private nonisolated static func fallbackCropRect(in image: CGImage) -> CGRect {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let side = min(width, height) * 0.78
        let centerY = height > width ? height * 0.36 : height * 0.46
        return clampedSquareCropRect(
            centerX: width * 0.5,
            centerY: centerY,
            side: side,
            imageWidth: width,
            imageHeight: height
        )
    }

    private nonisolated static func clampedSquareCropRect(
        centerX: CGFloat,
        centerY: CGFloat,
        side: CGFloat,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGRect {
        let resolvedSide = max(1, min(side, min(imageWidth, imageHeight)))
        let originX = min(
            max(0, centerX - resolvedSide * 0.5),
            imageWidth - resolvedSide
        )
        let originY = min(
            max(0, centerY - resolvedSide * 0.5),
            imageHeight - resolvedSide
        )
        return CGRect(
            x: originX,
            y: originY,
            width: resolvedSide,
            height: resolvedSide
        ).integral
    }

    private nonisolated static func squareThumbnail(
        from image: CGImage,
        cropRect: CGRect,
        maximumPixelSize: Int
    ) -> UIImage? {
        guard !Task.isCancelled,
              let cropped = image.cropping(to: cropRect) else {
            return nil
        }
        let dimension = max(1, min(
            maximumPixelSize,
            Int(min(cropRect.width, cropRect.height).rounded(.down))
        ))
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: dimension, height: dimension)
        )
        guard let result = context.makeImage() else { return nil }
        return UIImage(cgImage: result)
    }
}
