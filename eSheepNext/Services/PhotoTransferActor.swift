import CryptoKit
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

enum PhotoTransferError: LocalizedError {
    case sourceUnreadable
    case imageDecodeFailed
    case imageEncodeFailed
    case bindingMissing
    case assetMissing
    case remoteAssetMissing
    case remoteProviderUnavailable
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable: "无法读取照片源文件。"
        case .imageDecodeFailed: "无法解码照片。"
        case .imageEncodeFailed: "无法生成可同步的照片版本。"
        case .bindingMissing: "牧场尚未建立有效的 eSheep 云绑定。"
        case .assetMissing: "本地照片记录不存在。"
        case .remoteAssetMissing: "云端照片二进制不存在。"
        case .remoteProviderUnavailable: "当前云端照片服务不可用。"
        case .checksumMismatch: "照片下载后的校验值不一致。"
        }
    }
}

struct OptimizedPhoto: Sendable {
    let fileURL: URL
    let sourceDigest: String
    let payloadDigest: String
    let mimeType: String
    let sourceWidth: Int
    let sourceHeight: Int
    let cloudWidth: Int
    let cloudHeight: Int
    let capturedAt: Date?
    let byteCount: Int64
}

private struct ESheepCloudPhotoVariant: Sendable {
    let relativePath: String
    let digest: String
    let byteCount: Int64
}

actor PhotoTransferActor {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func enqueue(data: Data, farmID: UUID, entityID: UUID?) throws -> UUID {
        let sourceURL = FileManager.default.temporaryDirectory.appending(
            path: "esheep-photo-\(UUID().uuidString.lowercased())"
        )
        try data.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        return try enqueue(sourceURL: sourceURL, farmID: farmID, entityID: entityID)
    }

    func enqueue(sourceURL: URL, farmID: UUID, entityID: UUID?) throws -> UUID {
        let context = ModelContext(modelContainer)
        let route = try FarmStorageRouter.route(farmID: farmID, context: context)
        guard route.transitionState != .readOnlyMigration else {
            throw FarmCommandError.cloudMigrationInProgress
        }
        guard route.mode != .retiredAppleCloud else {
            throw PhotoTransferError.bindingMissing
        }

        let assetID = UUID()
        let optimized = try Self.optimize(
            sourceURL: sourceURL,
            farmID: farmID,
            assetID: assetID
        )
        if let duplicate = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .first(where: {
                $0.farmID == farmID &&
                    $0.sheepID == entityID &&
                    $0.sha256 == optimized.payloadDigest &&
                    $0.deletedAt == nil
            }) {
            let existingURL = Self.absoluteURL(for: duplicate.relativePath)
            if FileManager.default.fileExists(atPath: existingURL.path),
               (try? Self.digest(existingURL)) == optimized.payloadDigest {
                try? FileManager.default.removeItem(at: optimized.fileURL)
                if route.deliveryProvider == .eSheepCloud {
                    try stageESheepCloudTransferIfNeeded(
                        asset: duplicate,
                        byteCount: Self.fileSize(existingURL),
                        route: route,
                        context: context
                    )
                    try context.save()
                    CloudRuntimeNotification.postSyncWake(farmID: farmID)
                }
                return duplicate.id
            }

            let fileExtension = optimized.mimeType == "image/heic" ? "heic" : "jpg"
            let destination = try Self.assetURL(
                farmID: farmID,
                assetID: duplicate.id,
                fileExtension: fileExtension
            )
            try Self.replaceItem(at: destination, with: optimized.fileURL)
            try? FileManager.default.removeItem(at: optimized.fileURL)
            duplicate.relativePath = Self.relativePath(for: destination)
            duplicate.sourceSHA256 = optimized.sourceDigest
            duplicate.sourcePixelWidth = optimized.sourceWidth
            duplicate.sourcePixelHeight = optimized.sourceHeight
            duplicate.cloudPixelWidth = optimized.cloudWidth
            duplicate.cloudPixelHeight = optimized.cloudHeight
            duplicate.capturedAt = optimized.capturedAt
            duplicate.mimeType = optimized.mimeType
            try stageSupabaseTransferIfNeeded(
                asset: duplicate,
                byteCount: optimized.byteCount,
                route: route,
                context: context
            )
            try stageESheepCloudTransferIfNeeded(
                asset: duplicate,
                byteCount: optimized.byteCount,
                route: route,
                context: context
            )
            try context.save()
            if route.deliveryProvider == .supabase || route.deliveryProvider == .eSheepCloud {
                CloudRuntimeNotification.postSyncWake(farmID: farmID)
            }
            return duplicate.id
        }

        let asset = PhotoAssetRecord(
            id: assetID,
            farmID: farmID,
            sheepID: entityID,
            legacySourceKey: "local:\(assetID.uuidString.lowercased())",
            originalEarTag: "",
            relativePath: Self.relativePath(for: optimized.fileURL),
            sha256: optimized.payloadDigest,
            mimeType: optimized.mimeType
        )
        asset.sourceSHA256 = optimized.sourceDigest
        asset.sourcePixelWidth = optimized.sourceWidth
        asset.sourcePixelHeight = optimized.sourceHeight
        asset.cloudPixelWidth = optimized.cloudWidth
        asset.cloudPixelHeight = optimized.cloudHeight
        asset.capturedAt = optimized.capturedAt
        context.insert(asset)

        if route.deliveryProvider == .supabase {
            try stageSupabaseTransferIfNeeded(
                asset: asset,
                byteCount: optimized.byteCount,
                route: route,
                context: context
            )
            if let accountID = try context.fetch(FetchDescriptor<AccountProfile>())
                .first?.effectiveAccountID {
                var payload = FarmCommandCloudPayload(kind: .addPhoto)
                payload.strings = [
                    "sha256": asset.sha256,
                    "sourceSHA256": asset.sourceSHA256,
                    "mimeType": asset.mimeType,
                ]
                payload.optionalIdentifiers = ["sheepID": entityID]
                payload.optionalDates = ["capturedAt": asset.capturedAt]
                payload.integers = [
                    "sourcePixelWidth": asset.sourcePixelWidth,
                    "sourcePixelHeight": asset.sourcePixelHeight,
                    "cloudPixelWidth": asset.cloudPixelWidth,
                    "cloudPixelHeight": asset.cloudPixelHeight,
                    "byteCount": Int(optimized.byteCount),
                ]
                let operationID = UUID()
                _ = try FarmStorageRouter.takeNextOperationSequence(
                    farmID: farmID,
                    operationID: operationID,
                    context: context
                )
                let operation = DomainOperation(
                    id: operationID,
                    farmID: farmID,
                    accountID: accountID,
                    kind: .addPhoto,
                    summary: "添加照片",
                    entityType: CloudEntityType.photoAsset.rawValue,
                    entityID: assetID,
                    payload: try JSONEncoder.cloud.encode(payload)
                )
                context.insert(operation)
                context.insert(OutboxItem(
                    farmID: farmID,
                    accountID: accountID,
                    operationID: operation.id,
                    entityType: operation.entityType,
                    entityID: operation.entityID,
                    baseRevision: operation.baseRevision,
                    payloadDigest: operation.payloadDigest,
                    deliveryProvider: .supabase,
                    authorityGeneration: route.deliveryAuthorityGeneration
                ))
            }
        } else if route.deliveryProvider == .eSheepCloud {
            try stageESheepCloudTransferIfNeeded(
                asset: asset,
                byteCount: optimized.byteCount,
                route: route,
                context: context
            )
        }
        try context.save()
        if route.deliveryProvider == .supabase || route.deliveryProvider == .eSheepCloud {
            CloudRuntimeNotification.postSyncWake(farmID: farmID)
        }
        return assetID
    }

    func localFileData(assetID: UUID) throws -> Data {
        let context = ModelContext(modelContainer)
        let candidates = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter {
            $0.id == assetID && $0.deletedAt == nil
        }
        guard !candidates.isEmpty else { throw PhotoTransferError.assetMissing }
        var foundLocalFile = false
        for asset in candidates where !asset.relativePath.isEmpty {
            let fileURL = Self.absoluteURL(for: asset.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            foundLocalFile = true
            guard try Self.digest(fileURL) == asset.sha256 else { continue }
            return try Data(contentsOf: fileURL)
        }
        if foundLocalFile { throw PhotoTransferError.checksumMismatch }
        throw PhotoTransferError.sourceUnreadable
    }

    func deliveryProvider(assetID: UUID) throws -> FarmRemoteProvider? {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .first(where: { $0.id == assetID && $0.deletedAt == nil }) else {
            throw PhotoTransferError.assetMissing
        }
        return try FarmStorageRouter.route(
            farmID: asset.farmID,
            context: context
        ).deliveryProvider
    }

    func updateCapturedAt(assetID: UUID, capturedAt: Date) throws {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .first(where: { $0.id == assetID && $0.deletedAt == nil }) else {
            throw PhotoTransferError.assetMissing
        }
        let route = try FarmStorageRouter.route(farmID: asset.farmID, context: context)
        guard route.transitionState != .readOnlyMigration else {
            throw FarmCommandError.cloudMigrationInProgress
        }
        guard route.mode != .retiredAppleCloud else {
            throw PhotoTransferError.bindingMissing
        }
        asset.capturedAt = capturedAt
        if route.deliveryProvider == .supabase {
            let fileURL = Self.absoluteURL(for: asset.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw PhotoTransferError.sourceUnreadable
            }
            try stageSupabaseTransferIfNeeded(
                asset: asset,
                byteCount: Self.fileSize(fileURL),
                route: route,
                context: context
            )
        }
        try context.save()
        if route.deliveryProvider == .supabase {
            CloudRuntimeNotification.postSyncWake(farmID: asset.farmID)
        }
    }

    func verify(assetID: UUID) throws -> Bool {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .first(where: { $0.id == assetID }) else {
            throw PhotoTransferError.assetMissing
        }
        return try Self.digest(Self.absoluteURL(for: asset.relativePath)) == asset.sha256
    }

    private func stageSupabaseTransferIfNeeded(
        asset: PhotoAssetRecord,
        byteCount: Int64,
        route: FarmStorageRoute,
        context: ModelContext
    ) throws {
        guard route.deliveryProvider == .supabase else { return }
        let uploads = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).filter {
            $0.farmID == asset.farmID &&
                $0.assetID == asset.id &&
                $0.direction == .upload
        }
        if let transfer = uploads.max(by: { $0.updatedAt < $1.updatedAt }) {
            transfer.localRelativePath = asset.relativePath
            transfer.payloadDigest = asset.sha256
            transfer.byteCount = byteCount
            transfer.sourceDigest = asset.sourceSHA256.isEmpty
                ? asset.sha256
                : asset.sourceSHA256
            transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
            transfer.transferredByteCount = 0
            transfer.lastErrorCode = nil
            transfer.nextRetryAt = nil
            transfer.updatedAt = .now
        } else {
            context.insert(CloudAssetTransfer(
                farmID: asset.farmID,
                assetID: asset.id,
                localRelativePath: asset.relativePath,
                payloadDigest: asset.sha256,
                byteCount: byteCount,
                direction: .upload,
                sourceDigest: asset.sourceSHA256.isEmpty
                    ? asset.sha256
                    : asset.sourceSHA256
            ))
        }
    }

    /// Stages the optimistic photo projection, all resource variants and the
    /// immutable registration command in the caller's single ModelContext
    /// save. A process cannot expose a photo without its matching intent, or
    /// enqueue an intent whose photo projection was never saved.
    private func stageESheepCloudTransferIfNeeded(
        asset: PhotoAssetRecord,
        byteCount: Int64,
        route: FarmStorageRoute,
        context: ModelContext
    ) throws {
        guard route.deliveryProvider == .eSheepCloud else { return }
        guard let farmState = try context.fetch(FetchDescriptor<ESheepCloudFarmState>())
            .first(where: {
                $0.farmID == asset.farmID &&
                    $0.farmGeneration == route.deliveryAuthorityGeneration &&
                    $0.activityState == .active
            }) else {
            throw ESheepCloudIntentWriterError.farmStateMissing
        }

        let originalURL = Self.absoluteURL(for: asset.relativePath)
        guard FileManager.default.fileExists(atPath: originalURL.path),
              try Self.digest(originalURL) == asset.sha256 else {
            throw PhotoTransferError.checksumMismatch
        }
        let thumbnail = try Self.makeJPEGVariant(
            sourceURL: originalURL,
            farmID: asset.farmID,
            assetID: asset.id,
            variant: .thumbnail,
            maximumPixelSize: 512,
            quality: 0.78
        )
        let avatar = try Self.makeJPEGVariant(
            sourceURL: originalURL,
            farmID: asset.farmID,
            assetID: asset.id,
            variant: .avatar,
            maximumPixelSize: 1024,
            quality: 0.84
        )
        let metadata = Self.eSheepCloudMetadata(for: asset)
        let metadataDigest = try ESheepCloudCanonicalCodec.digest(metadata)
        let states = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .filter { $0.id == asset.id && $0.farmID == asset.farmID }
        guard states.count <= 1 else {
            throw ESheepCloudContractError.malformedPayload
        }
        let state = states.first ?? ESheepCloudAssetState(
            assetID: asset.id,
            farmID: asset.farmID,
            farmGeneration: route.deliveryAuthorityGeneration,
            sheepID: asset.sheepID,
            contentSHA256: asset.sha256,
            metadataDigest: metadataDigest,
            originalByteCount: byteCount
        )
        if states.isEmpty { context.insert(state) }
        guard state.farmGeneration == route.deliveryAuthorityGeneration,
              state.contentSHA256 == asset.sha256 else {
            throw ESheepCloudContractError.malformedPayload
        }
        state.sheepID = asset.sheepID
        state.metadataDigest = metadataDigest
        state.metadataData = try ESheepCloudCanonicalCodec.encode(metadata)
        state.thumbnailSHA256 = thumbnail.digest
        state.avatarSHA256 = avatar.digest
        state.originalSHA256 = asset.sha256
        state.thumbnailRelativePath = thumbnail.relativePath
        state.avatarRelativePath = avatar.relativePath
        state.originalRelativePath = asset.relativePath
        state.thumbnailByteCount = thumbnail.byteCount
        state.avatarByteCount = avatar.byteCount
        state.originalByteCount = max(0, byteCount)
        if state.thumbnailStateRawValue != ESheepCloudAssetTransferState.verified.rawValue {
            state.thumbnailStateRawValue = ESheepCloudAssetTransferState.queued.rawValue
            state.thumbnailTransferredByteCount = 0
        }
        if state.avatarStateRawValue != ESheepCloudAssetTransferState.verified.rawValue {
            state.avatarStateRawValue = ESheepCloudAssetTransferState.queued.rawValue
            state.avatarTransferredByteCount = 0
        }
        if state.originalStateRawValue != ESheepCloudAssetTransferState.verified.rawValue {
            state.originalStateRawValue = ESheepCloudAssetTransferState.queued.rawValue
            state.originalTransferredByteCount = 0
        }
        state.updatedAt = .now

        if try hasPhotoRegistration(
            assetID: asset.id,
            farmID: asset.farmID,
            farmGeneration: route.deliveryAuthorityGeneration,
            context: context
        ) {
            farmState.lastSafeSaveAt = nil
            return
        }
        guard let accountID = try context.fetch(FetchDescriptor<AccountProfile>())
            .first?.effectiveAccountID else {
            throw PhotoTransferError.bindingMissing
        }
        let commandID = UUID()
        let sequence = try FarmStorageRouter.takeNextOperationSequence(
            farmID: asset.farmID,
            operationID: commandID,
            context: context
        )
        _ = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.registerPhoto(
                assetID: asset.id,
                sheepID: asset.sheepID,
                capturedAt: asset.capturedAt,
                mimeType: asset.mimeType,
                contentSHA256: asset.sha256,
                metadata: metadata,
                metadataDigest: metadataDigest,
                thumbnailSHA256: thumbnail.digest,
                avatarSHA256: avatar.digest,
                originalSHA256: asset.sha256,
                thumbnailByteCount: thumbnail.byteCount,
                avatarByteCount: avatar.byteCount,
                originalByteCount: byteCount,
                occurredAt: asset.capturedAt ?? .now
            ),
            commandID: commandID,
            sourceRequestID: commandID,
            farmID: asset.farmID,
            farmGeneration: route.deliveryAuthorityGeneration,
            accountID: accountID,
            deviceID: try ESheepCloudDeviceIdentityStore.deviceID(accountID: accountID),
            deviceSequence: sequence,
            context: context
        )
    }

    private func hasPhotoRegistration(
        assetID: UUID,
        farmID: UUID,
        farmGeneration: Int,
        context: ModelContext
    ) throws -> Bool {
        if try context.fetch(FetchDescriptor<ESheepCloudStreamState>()).contains(where: {
            $0.farmID == farmID && $0.farmGeneration == farmGeneration &&
                $0.streamType == "photoAsset" && $0.streamID == assetID
        }) {
            return true
        }
        for intent in try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
            where intent.farmID == farmID && intent.farmGeneration == farmGeneration &&
                intent.commandKind == "photoAsset.register" {
            guard let envelope = try? ESheepCloudCanonicalCodec.decode(
                ESheepCloudCommandEnvelopeV2.self,
                from: intent.commandEnvelopeData
            ) else { continue }
            if envelope.affectedStreams == [
                ESheepCloudStreamReferenceV2(type: "photoAsset", id: assetID),
            ] {
                return true
            }
        }
        return false
    }

    private static func eSheepCloudMetadata(
        for asset: PhotoAssetRecord
    ) -> [String: String] {
        var metadata: [String: String] = [
            "mimeType": asset.mimeType,
            "sourceSHA256": asset.sourceSHA256,
            "sourcePixelWidth": String(asset.sourcePixelWidth),
            "sourcePixelHeight": String(asset.sourcePixelHeight),
            "cloudPixelWidth": String(asset.cloudPixelWidth),
            "cloudPixelHeight": String(asset.cloudPixelHeight),
        ]
        if let capturedAt = asset.capturedAt {
            metadata["capturedAtMillis"] = String(
                Int64((capturedAt.timeIntervalSince1970 * 1_000).rounded())
            )
        }
        return metadata
    }

    private static func makeJPEGVariant(
        sourceURL: URL,
        farmID: UUID,
        assetID: UUID,
        variant: ESheepCloudAssetVariantV2,
        maximumPixelSize: Int,
        quality: Double
    ) throws -> ESheepCloudPhotoVariant {
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        ) else {
            throw PhotoTransferError.imageDecodeFailed
        }
        let destinationURL = try assetVariantURL(
            farmID: farmID,
            assetID: assetID,
            variant: variant,
            fileExtension: "jpg"
        )
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoTransferError.imageEncodeFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoTransferError.imageEncodeFailed
        }
        return ESheepCloudPhotoVariant(
            relativePath: relativePath(for: destinationURL),
            digest: try digest(destinationURL),
            byteCount: fileSize(destinationURL)
        )
    }

    static func optimize(
        sourceURL: URL,
        farmID: UUID,
        assetID: UUID
    ) throws -> OptimizedPhoto {
        let sourceData = try Data(contentsOf: sourceURL)
        guard let source = CGImageSourceCreateWithData(
            sourceData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw PhotoTransferError.imageDecodeFailed
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw PhotoTransferError.imageDecodeFailed
        }
        var output = try assetURL(
            farmID: farmID,
            assetID: assetID,
            fileExtension: "heic"
        )
        var mimeType = "image/heic"
        var quality = 0.82
        var destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        )
        if destination == nil {
            output = try assetURL(
                farmID: farmID,
                assetID: assetID,
                fileExtension: "jpg"
            )
            mimeType = "image/jpeg"
            quality = 0.86
            destination = CGImageDestinationCreateWithURL(
                output as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        }
        guard let destination else { throw PhotoTransferError.imageEncodeFailed }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoTransferError.imageEncodeFailed
        }
        return OptimizedPhoto(
            fileURL: output,
            sourceDigest: CloudPayloadDigest.hex(for: sourceData),
            payloadDigest: try digest(output),
            mimeType: mimeType,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            cloudWidth: image.width,
            cloudHeight: image.height,
            capturedAt: captureDate(properties),
            byteCount: fileSize(output)
        )
    }

    static func digest(_ fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func captureDate(_ properties: [CFString: Any]?) -> Date? {
        guard let exif = properties?[kCGImagePropertyExifDictionary]
                as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func baseDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "eSheepNext", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func assetURL(
        farmID: UUID,
        assetID: UUID,
        fileExtension: String
    ) throws -> URL {
        let directory = try baseDirectory().appending(
            path: "FarmAssets/\(farmID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appending(
            path: "\(assetID.uuidString.lowercased()).\(fileExtension)"
        )
    }

    static func assetVariantURL(
        farmID: UUID,
        assetID: UUID,
        variant: ESheepCloudAssetVariantV2,
        fileExtension: String
    ) throws -> URL {
        let directory = try baseDirectory().appending(
            path: "FarmAssets/\(farmID.uuidString.lowercased())/\(assetID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appending(path: "\(variant.rawValue).\(fileExtension)")
    }

    static func absoluteURL(for path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return localAssetURL(for: path, applicationSupportDirectory: support)
    }

    /// Resolve current files and legacy import/photo cache paths without
    /// requiring the retired provider runtime.
    static func localAssetURL(
        for path: String,
        applicationSupportDirectory: URL
    ) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("MigrationAssets/") {
            return applicationSupportDirectory.appending(path: path)
        }
        let current = applicationSupportDirectory.appending(
            path: "eSheepNext/\(path)"
        )
        if FileManager.default.fileExists(atPath: current.path) { return current }
        let legacy = applicationSupportDirectory.appending(path: path)
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return current
    }

    static func relativePath(for url: URL) -> String {
        guard let root = try? baseDirectory().standardizedFileURL.path,
              url.standardizedFileURL.path.hasPrefix(root + "/") else {
            return url.path
        }
        return String(url.standardizedFileURL.path.dropFirst(root.count + 1))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
    }

    private static func replaceItem(at destination: URL, with source: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

enum PhotoTransferInterruptionPolicy {
    static func shouldRequeue(status: CloudAssetTransferStatus) -> Bool {
        status == .uploading || status == .downloading
    }
}
