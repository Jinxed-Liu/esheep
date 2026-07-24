import CloudKit
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
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable: "无法读取照片源文件。"
        case .imageDecodeFailed: "无法解码照片。"
        case .imageEncodeFailed: "无法生成云端照片版本。"
        case .bindingMissing: "牧场尚未建立有效的 CloudKit 绑定。"
        case .assetMissing: "本地照片记录不存在。"
        case .remoteAssetMissing: "CloudKit 照片二进制不存在。"
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

actor PhotoTransferActor {
    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private let mapper = CloudRecordMapper()
    private let recoveryKeys: FarmRecoveryKeyActor
    private let deviceIdentity: DeviceIdentityActor
    private var didRecoverInterruptedTransfers = false

    init(modelContainer: ModelContainer, containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String, recoveryKeys: FarmRecoveryKeyActor = .shared, deviceIdentity: DeviceIdentityActor = .shared) {
        self.modelContainer = modelContainer
        self.cloudContainer = containerIdentifier.flatMap { $0.isEmpty ? nil : CKContainer(identifier: $0) } ?? .default()
        self.recoveryKeys = recoveryKeys
        self.deviceIdentity = deviceIdentity
    }

    func enqueue(data: Data, farmID: UUID, entityID: UUID?) throws -> UUID {
        let sourceURL = FileManager.default.temporaryDirectory.appending(path: "esheep-photo-\(UUID().uuidString.lowercased())")
        try data.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        return try enqueue(sourceURL: sourceURL, farmID: farmID, entityID: entityID)
    }

    func enqueue(sourceURL: URL, farmID: UUID, entityID: UUID?) throws -> UUID {
        let assetID = UUID()
        let optimized = try Self.optimize(sourceURL: sourceURL, farmID: farmID, assetID: assetID)
        let context = ModelContext(modelContainer)
        if let duplicate = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: {
            $0.farmID == farmID && $0.sha256 == optimized.payloadDigest && $0.deletedAt == nil
        }) {
            try? FileManager.default.removeItem(at: optimized.fileURL)
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
        context.insert(CloudAssetTransfer(
            farmID: farmID,
            assetID: assetID,
            localRelativePath: asset.relativePath,
            payloadDigest: optimized.payloadDigest,
            byteCount: optimized.byteCount,
            direction: .upload,
            sourceDigest: optimized.sourceDigest
        ))
        try context.save()
        return assetID
    }

    func upload(assetID: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: { $0.id == assetID }),
              let transfer = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).first(where: { $0.assetID == assetID && $0.direction == .upload }) else {
            throw PhotoTransferError.assetMissing
        }
        transfer.statusRawValue = CloudAssetTransferStatus.uploading.rawValue
        transfer.attemptCount += 1
        transfer.updatedAt = .now
        try context.save()
        do {
            guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == asset.farmID && $0.state == .active }) else {
                throw PhotoTransferError.bindingMissing
            }
            let fileURL = Self.absoluteURL(for: asset.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw PhotoTransferError.sourceUnreadable }
            guard let accountID = try context.fetch(FetchDescriptor<AccountProfile>()).first?.effectiveAccountID,
                  let certificate = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>()).filter({
                      $0.farmID == asset.farmID && $0.accountID == accountID && $0.isUsable
                  }).max(by: { $0.expiresAt < $1.expiresAt }) else {
                throw FarmCommandError.cloudIdentityLocked
            }
            let identity = try await deviceIdentity.identity()
            let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
            let unsigned = FarmAssetEnvelope(
                farmID: asset.farmID,
                assetID: asset.id,
                entityID: asset.sheepID,
                sourceDigest: asset.sourceSHA256,
                payloadDigest: asset.sha256,
                mimeType: asset.mimeType,
                pixelWidth: asset.cloudPixelWidth,
                pixelHeight: asset.cloudPixelHeight,
                capturedAt: asset.capturedAt,
                byteCount: Self.fileSize(fileURL),
                createdAt: asset.createdAt,
                modifiedByAccountID: accountID,
                modifiedByDeviceID: identity.deviceID,
                capabilityCertificate: certificate.certificateJWS,
                signature: Data()
            )
            let envelope = FarmAssetEnvelope(
                farmID: unsigned.farmID,
                assetID: unsigned.assetID,
                entityID: unsigned.entityID,
                sourceDigest: unsigned.sourceDigest,
                payloadDigest: unsigned.payloadDigest,
                mimeType: unsigned.mimeType,
                pixelWidth: unsigned.pixelWidth,
                pixelHeight: unsigned.pixelHeight,
                capturedAt: unsigned.capturedAt,
                byteCount: unsigned.byteCount,
                createdAt: unsigned.createdAt,
                modifiedByAccountID: unsigned.modifiedByAccountID,
                modifiedByDeviceID: unsigned.modifiedByDeviceID,
                capabilityCertificate: unsigned.capabilityCertificate,
                signature: try await deviceIdentity.sign(unsigned.canonicalSigningDataV2)
            )
            let record = mapper.assetRecord(envelope: envelope, fileURL: fileURL, zoneID: zoneID)
            let database = binding.databaseScope == .sharedDatabase ? cloudContainer.sharedCloudDatabase : cloudContainer.privateCloudDatabase
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
            _ = try result.saveResults[record.recordID]?.get()
            asset.cloudRecordName = record.recordID.recordName
            asset.isCloudAuthoritative = true
            transfer.remoteRecordName = record.recordID.recordName
            transfer.transferredByteCount = transfer.byteCount
            transfer.statusRawValue = CloudAssetTransferStatus.completed.rawValue
            transfer.lastErrorCode = nil
            transfer.updatedAt = .now
            try context.save()
            if binding.databaseScope == .privateDatabase {
                try await backupForOwner(assetID: assetID)
            }
        } catch {
            transfer.statusRawValue = CloudAssetTransferStatus.failed.rawValue
            transfer.lastErrorCode = String(describing: error)
            transfer.nextRetryAt = Date().addingTimeInterval(min(3600, pow(2, Double(transfer.attemptCount)) * 30))
            transfer.updatedAt = .now
            try? context.save()
            throw error
        }
    }

    func download(assetID: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: { $0.id == assetID }) else { throw PhotoTransferError.assetMissing }
        guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == asset.farmID && $0.state == .active }) else { throw PhotoTransferError.bindingMissing }
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: mapper.assetRecordName(for: assetID), zoneID: zoneID)
        let database = binding.databaseScope == .sharedDatabase ? cloudContainer.sharedCloudDatabase : cloudContainer.privateCloudDatabase
        let record = try await database.record(for: recordID)
        guard let remote = record[CloudRecordField.asset] as? CKAsset, let remoteURL = remote.fileURL else { throw PhotoTransferError.remoteAssetMissing }
        let destination = try Self.assetURL(farmID: asset.farmID, assetID: asset.id, fileExtension: asset.mimeType == "image/heic" ? "heic" : "jpg")
        try Self.replaceItem(at: destination, with: remoteURL)
        guard try Self.digest(destination) == asset.sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw PhotoTransferError.checksumMismatch
        }
        asset.relativePath = Self.relativePath(for: destination)
        asset.isCloudAuthoritative = true
        if let transfer = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).first(where: { $0.assetID == assetID && $0.direction == .download }) {
            transfer.statusRawValue = CloudAssetTransferStatus.completed.rawValue
            transfer.transferredByteCount = transfer.byteCount
            transfer.updatedAt = .now
        }
        try context.save()
    }

    func retry(transferID: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let transfer = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).first(where: { $0.id == transferID }) else { return }
        transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
        transfer.nextRetryAt = nil
        transfer.lastErrorCode = nil
        try context.save()
        switch transfer.direction {
        case .upload: try await upload(assetID: transfer.assetID)
        case .download: try await download(assetID: transfer.assetID)
        case .recoveryBackup: try await backupForOwner(assetID: transfer.assetID)
        case .recoveryRestore: try await restoreFromOwnerBackup(assetID: transfer.assetID)
        }
    }

    func processPendingTransfers() async {
        let context = ModelContext(modelContainer)
        if !didRecoverInterruptedTransfers {
            didRecoverInterruptedTransfers = true
            let interrupted = (try? context.fetch(FetchDescriptor<CloudAssetTransfer>()))?.filter {
                PhotoTransferInterruptionPolicy.shouldRequeue(status: $0.status)
            } ?? []
            for transfer in interrupted {
                transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
                transfer.lastErrorCode = "上次传输在进程结束时中断，已自动恢复。"
                transfer.nextRetryAt = nil
                transfer.updatedAt = .now
            }
            if !interrupted.isEmpty { try? context.save() }
        }
        let pending = (try? context.fetch(FetchDescriptor<CloudAssetTransfer>()))?.filter {
            ($0.status == .pending || $0.status == .failed) && ($0.nextRetryAt == nil || $0.nextRetryAt! <= .now)
        } ?? []
        for transfer in pending {
            try? await retry(transferID: transfer.id)
        }
    }

    func localFileData(assetID: UUID) throws -> Data {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: { $0.id == assetID }) else {
            throw PhotoTransferError.assetMissing
        }
        return try Data(contentsOf: Self.absoluteURL(for: asset.relativePath))
    }

    func updateCapturedAt(assetID: UUID, capturedAt: Date) throws {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: {
            $0.id == assetID && $0.deletedAt == nil
        }) else {
            throw PhotoTransferError.assetMissing
        }

        asset.capturedAt = capturedAt
        if let transfer = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).first(where: {
            $0.assetID == assetID && $0.direction == .upload
        }) {
            transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
            transfer.nextRetryAt = nil
            transfer.lastErrorCode = nil
            transfer.updatedAt = .now
        } else {
            let fileURL = Self.absoluteURL(for: asset.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw PhotoTransferError.sourceUnreadable
            }
            context.insert(CloudAssetTransfer(
                farmID: asset.farmID,
                assetID: asset.id,
                localRelativePath: asset.relativePath,
                payloadDigest: asset.sha256,
                byteCount: Self.fileSize(fileURL),
                direction: .upload,
                sourceDigest: asset.sourceSHA256.isEmpty ? asset.sha256 : asset.sourceSHA256
            ))
        }
        try context.save()
    }

    func verify(assetID: UUID) throws -> Bool {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: { $0.id == assetID }) else { throw PhotoTransferError.assetMissing }
        return try Self.digest(Self.absoluteURL(for: asset.relativePath)) == asset.sha256
    }

    func backupForOwner(assetID: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: { $0.id == assetID }) else { throw PhotoTransferError.assetMissing }
        if asset.recoveryBackedUpAt != nil { return }
        let source = Self.absoluteURL(for: asset.relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw PhotoTransferError.sourceUnreadable }
        let encryptedData = try await recoveryKeys.seal(Data(contentsOf: source), farmID: asset.farmID)
        let encryptedURL = try Self.recoveryAssetURL(farmID: asset.farmID, assetID: asset.id)
        try encryptedData.write(to: encryptedURL, options: .atomic)

        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.recovery(for: asset.farmID), ownerName: CKCurrentUserDefaultName)
        _ = try await cloudContainer.privateCloudDatabase.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let recordID = CKRecord.ID(recordName: "recovery_asset_\(asset.sha256)", zoneID: zoneID)
        let record = CKRecord(recordType: CloudRecordType.farmRecoveryAsset.rawValue, recordID: recordID)
        record[CloudRecordField.farmID] = asset.farmID.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.entityID] = asset.id.uuidString.lowercased() as CKRecordValue
        record[CloudRecordField.payloadDigest] = asset.sha256 as CKRecordValue
        record[CloudRecordField.byteCount] = Int64(encryptedData.count) as CKRecordValue
        record[CloudRecordField.asset] = CKAsset(fileURL: encryptedURL)
        let result = try await cloudContainer.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
        _ = try result.saveResults[recordID]?.get()
        asset.recoveryRecordName = recordID.recordName
        asset.recoveryBackedUpAt = .now
        let local = FarmRecoveryAssetRecord(farmID: asset.farmID, assetID: asset.id, payloadDigest: asset.sha256, encryptedRelativePath: Self.relativePath(for: encryptedURL), byteCount: Int64(encryptedData.count))
        local.cloudRecordName = recordID.recordName
        local.verifiedAt = .now
        context.insert(local)
        try context.save()
    }

    func restoreFromOwnerBackup(assetID: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first(where: { $0.id == assetID }), let recordName = asset.recoveryRecordName else { throw PhotoTransferError.assetMissing }
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.recovery(for: asset.farmID), ownerName: CKCurrentUserDefaultName)
        let record = try await cloudContainer.privateCloudDatabase.record(for: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        guard let ckAsset = record[CloudRecordField.asset] as? CKAsset, let fileURL = ckAsset.fileURL else { throw PhotoTransferError.remoteAssetMissing }
        let decrypted = try await recoveryKeys.open(Data(contentsOf: fileURL), farmID: asset.farmID)
        guard CloudPayloadDigest.hex(for: decrypted) == asset.sha256 else { throw PhotoTransferError.checksumMismatch }
        let destination = try Self.assetURL(farmID: asset.farmID, assetID: asset.id, fileExtension: asset.mimeType == "image/heic" ? "heic" : "jpg")
        try decrypted.write(to: destination, options: .atomic)
        asset.relativePath = Self.relativePath(for: destination)
        try context.save()
        try await upload(assetID: assetID)
    }

    static func optimize(sourceURL: URL, farmID: UUID, assetID: UUID) throws -> OptimizedPhoto {
        let sourceData = try Data(contentsOf: sourceURL)
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PhotoTransferError.imageDecodeFailed }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PhotoTransferError.imageDecodeFailed }
        var output = try assetURL(farmID: farmID, assetID: assetID, fileExtension: "heic")
        var mimeType = "image/heic"
        var quality = 0.82
        var destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil)
        if destination == nil {
            output = try assetURL(farmID: farmID, assetID: assetID, fileExtension: "jpg")
            mimeType = "image/jpeg"
            quality = 0.86
            destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        }
        guard let destination else { throw PhotoTransferError.imageEncodeFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoTransferError.imageEncodeFailed }
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
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func captureDate(_ properties: [CFString: Any]?) -> Date? {
        guard let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any], let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func baseDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "eSheepNext", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func assetURL(farmID: UUID, assetID: UUID, fileExtension: String) throws -> URL {
        let directory = try baseDirectory().appending(path: "CloudAssets/\(farmID.uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(assetID.uuidString.lowercased()).\(fileExtension)")
    }

    private static func recoveryAssetURL(farmID: UUID, assetID: UUID) throws -> URL {
        let directory = try baseDirectory().appending(path: "Recovery/\(farmID.uuidString.lowercased())/Assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(assetID.uuidString.lowercased()).sealed")
    }

    private static func absoluteURL(for path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return localAssetURL(for: path, applicationSupportDirectory: support)
    }

    /// Formal migration assets predate the eSheepNext subdirectory used by
    /// newly captured photos. Keep that persisted relative-path contract so
    /// upgraded farms can upload their original files without moving them.
    static func localAssetURL(for path: String, applicationSupportDirectory: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("MigrationAssets/") {
            return applicationSupportDirectory.appending(path: path)
        }
        return applicationSupportDirectory.appending(path: "eSheepNext/\(path)")
    }

    private static func relativePath(for url: URL) -> String {
        guard let root = try? baseDirectory().standardizedFileURL.path, url.standardizedFileURL.path.hasPrefix(root + "/") else { return url.path }
        return String(url.standardizedFileURL.path.dropFirst(root.count + 1))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private static func replaceItem(at destination: URL, with source: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

enum PhotoTransferInterruptionPolicy {
    static func shouldRequeue(status: CloudAssetTransferStatus) -> Bool {
        status == .uploading || status == .downloading
    }
}
