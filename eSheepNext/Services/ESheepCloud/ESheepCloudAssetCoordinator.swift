import Foundation
import SwiftData

struct ESheepCloudResumableUploadDescriptorV2: Sendable {
    let objectKey: String
    let variantSHA256: String
    let contentType: String
    let byteCount: Int64
    let metadata: [String: String]
}

struct ESheepCloudResumableUploadSessionV2: Sendable, Equatable {
    let url: URL
    let expiresAt: Date
    let byteOffset: Int64
}

/// Provider-neutral transfer surface used by Cloud Core. The concrete HTTP,
/// object-storage SDK and resumable-upload protocol stay in Infrastructure.
protocol ESheepCloudAssetTransferTransport: Sendable {
    func createResumableUpload(
        ticket: ESheepCloudAssetTransferTicketV2,
        descriptor: ESheepCloudResumableUploadDescriptorV2
    ) async throws -> ESheepCloudResumableUploadSessionV2

    func resumableUploadOffset(
        sessionURL: URL,
        authorizationToken: String
    ) async throws -> Int64

    func uploadResumableChunk(
        _ data: Data,
        sessionURL: URL,
        authorizationToken: String,
        byteOffset: Int64
    ) async throws -> Int64

    func confirmAssetUpload(
        farmID: UUID,
        farmGeneration: Int,
        assetID: UUID,
        variant: ESheepCloudAssetVariantV2
    ) async throws

    func downloadAsset(
        ticket: ESheepCloudAssetTransferTicketV2,
        destinationURL: URL
    ) async throws
}

enum ESheepCloudAssetCoordinatorError: LocalizedError {
    case localFileMissing
    case localDigestMismatch
    case malformedState
    case transferAuthorizationMissing
    case invalidProgress

    var errorDescription: String? {
        switch self {
        case .localFileMissing:
            "本机照片文件暂时无法读取。"
        case .localDigestMismatch:
            "本机照片完整性检查未通过。"
        case .malformedState:
            "照片保存状态不完整。"
        case .transferAuthorizationMissing:
            "照片保存凭据已失效，请稍后重试。"
        case .invalidProgress:
            "照片保存进度无法确认，已暂停并等待安全重试。"
        }
    }
}

private struct ESheepCloudPendingAssetUpload: Sendable {
    let farmID: UUID
    let farmGeneration: Int
    let assetID: UUID
    let sheepID: UUID?
    let logicalSHA256: String
    let variant: ESheepCloudAssetVariantV2
    let variantSHA256: String
    let relativePath: String
    let byteCount: Int64
    let byteOffset: Int64
    let contentType: String
    let metadata: [String: String]
    let metadataDigest: String
    let sessionURL: URL?
    let sessionExpiresAt: Date?
}

/// Uploads at most a bounded number of variants per synchronization cycle.
/// Each 6 MiB TUS boundary is persisted, so cancellation or process death can
/// only repeat an idempotent offset probe—not duplicate an object or command.
actor ESheepCloudAssetCoordinator {
    static let resumableChunkByteCount = 6 * 1_024 * 1_024

    private let container: ModelContainer
    private let gateway: any ESheepCloudGateway
    private let transport: any ESheepCloudAssetTransferTransport

    init(
        container: ModelContainer,
        gateway: any ESheepCloudGateway,
        transport: any ESheepCloudAssetTransferTransport
    ) {
        self.container = container
        self.gateway = gateway
        self.transport = transport
    }

    func downloadOriginalIfNeeded(assetID: UUID) async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let photo = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .first(where: { $0.id == assetID && $0.deletedAt == nil }),
              let state = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .first(where: {
                $0.id == assetID && $0.farmID == photo.farmID &&
                    $0.originalStateRawValue == ESheepCloudAssetTransferState.verified.rawValue
            }),
              let variantSHA256 = state.originalSHA256,
              variantSHA256.isESheepCloudSHA256 else {
            throw ESheepCloudAssetCoordinatorError.malformedState
        }
        if !photo.relativePath.isEmpty {
            let currentURL = PhotoTransferActor.absoluteURL(for: photo.relativePath)
            if FileManager.default.fileExists(atPath: currentURL.path),
               (try? PhotoTransferActor.digest(currentURL)) == variantSHA256 {
                return
            }
        }
        let metadata = try ESheepCloudCanonicalCodec.decode(
            [String: String].self,
            from: state.metadataData
        )
        guard try ESheepCloudCanonicalCodec.digest(metadata) == state.metadataDigest else {
            throw ESheepCloudAssetCoordinatorError.malformedState
        }
        let farmID = state.farmID
        let farmGeneration = state.farmGeneration
        let sheepID = state.sheepID
        let logicalSHA256 = state.contentSHA256
        let metadataDigest = state.metadataDigest
        let originalByteCount = state.originalByteCount
        let photoMimeType = photo.mimeType
        let request = ESheepCloudAssetTransferRequestV2(
            farmID: farmID,
            farmGeneration: farmGeneration,
            assetID: assetID,
            sheepID: sheepID,
            contentSHA256: logicalSHA256,
            variantSHA256: variantSHA256,
            metadata: metadata,
            metadataDigest: metadataDigest,
            variant: .original,
            direction: .download,
            byteOffset: 0,
            byteCount: originalByteCount
        )
        let ticket = try await gateway.prepareAssetTransfer(request)
        let fileExtension = (metadata["mimeType"] ?? photoMimeType) == "image/heic"
            ? "heic" : "jpg"
        let finalURL = try PhotoTransferActor.assetURL(
            farmID: farmID,
            assetID: assetID,
            fileExtension: fileExtension
        )
        let temporaryURL = finalURL.deletingLastPathComponent().appending(
            path: ".\(assetID.uuidString.lowercased())-download-\(UUID().uuidString.lowercased()).partial"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try await transport.downloadAsset(ticket: ticket, destinationURL: temporaryURL)
        guard try PhotoTransferActor.digest(temporaryURL) == variantSHA256 else {
            throw ESheepCloudAssetCoordinatorError.localDigestMismatch
        }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)

        // Re-fetch after the suspension; never retain a managed model across
        // network work or update a farm whose generation changed meanwhile.
        let writeContext = ModelContext(container)
        writeContext.autosaveEnabled = false
        guard let currentPhoto = try writeContext.fetch(FetchDescriptor<PhotoAssetRecord>())
            .first(where: { $0.id == assetID && $0.farmID == farmID }),
              let currentState = try writeContext.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .first(where: {
                $0.id == assetID && $0.farmID == farmID &&
                    $0.farmGeneration == farmGeneration &&
                    $0.originalSHA256 == variantSHA256
            }) else {
            throw ESheepCloudAssetCoordinatorError.malformedState
        }
        currentPhoto.relativePath = PhotoTransferActor.relativePath(for: finalURL)
        currentPhoto.isCloudAuthoritative = true
        currentPhoto.cloudRecordName = ticket.objectKey
        currentState.originalRelativePath = currentPhoto.relativePath
        currentState.originalRemoteObjectKey = ticket.objectKey
        currentState.downloadedByteCount = currentState.originalByteCount
        currentState.updatedAt = .now
        try writeContext.save()
    }

    @discardableResult
    func processReadyUploads(
        farmID: UUID,
        maximumVariants: Int = 3
    ) async throws -> Int {
        var completed = 0
        for _ in 0..<max(1, maximumVariants) {
            try Task.checkCancellation()
            guard let work = try nextUpload(farmID: farmID) else { break }
            do {
                try await upload(work)
                completed += 1
            } catch {
                try? markFailed(work, traceID: UUID().uuidString.lowercased())
                throw error
            }
        }
        return completed
    }

    private func upload(_ work: ESheepCloudPendingAssetUpload) async throws {
        let fileURL = PhotoTransferActor.absoluteURL(for: work.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ESheepCloudAssetCoordinatorError.localFileMissing
        }
        guard try PhotoTransferActor.digest(fileURL) == work.variantSHA256 else {
            throw ESheepCloudAssetCoordinatorError.localDigestMismatch
        }
        let request = ESheepCloudAssetTransferRequestV2(
            farmID: work.farmID,
            farmGeneration: work.farmGeneration,
            assetID: work.assetID,
            sheepID: work.sheepID,
            contentSHA256: work.logicalSHA256,
            variantSHA256: work.variantSHA256,
            metadata: work.metadata,
            metadataDigest: work.metadataDigest,
            variant: work.variant,
            direction: .upload,
            byteOffset: work.byteOffset,
            byteCount: work.byteCount
        )
        let ticket = try await gateway.prepareAssetTransfer(request)
        guard ticket.assetID == work.assetID,
              ticket.variant == work.variant else {
            throw ESheepCloudAssetCoordinatorError.transferAuthorizationMissing
        }
        try markPrepared(work, objectKey: ticket.objectKey)
        if ticket.isAlreadyVerified {
            try markVerified(work)
            return
        }
        guard let token = ticket.authorizationToken else {
            throw ESheepCloudAssetCoordinatorError.transferAuthorizationMissing
        }

        let session: ESheepCloudResumableUploadSessionV2
        if let existingURL = work.sessionURL,
           let expiresAt = work.sessionExpiresAt,
           expiresAt > .now.addingTimeInterval(60) {
            let remoteOffset = try await transport.resumableUploadOffset(
                sessionURL: existingURL,
                authorizationToken: token
            )
            guard remoteOffset >= 0, remoteOffset <= work.byteCount else {
                throw ESheepCloudAssetCoordinatorError.invalidProgress
            }
            session = .init(
                url: existingURL,
                expiresAt: expiresAt,
                byteOffset: remoteOffset
            )
            try recordProgress(work, offset: remoteOffset)
        } else {
            session = try await transport.createResumableUpload(
                ticket: ticket,
                descriptor: .init(
                    objectKey: ticket.objectKey,
                    variantSHA256: work.variantSHA256,
                    contentType: work.contentType,
                    byteCount: work.byteCount,
                    metadata: work.metadata
                )
            )
            guard session.byteOffset >= 0, session.byteOffset <= work.byteCount else {
                throw ESheepCloudAssetCoordinatorError.invalidProgress
            }
            try recordSession(work, session: session)
        }

        var offset = session.byteOffset
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while offset < work.byteCount {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let requested = min(
                Self.resumableChunkByteCount,
                Int(work.byteCount - offset)
            )
            guard let data = try handle.read(upToCount: requested),
                  !data.isEmpty else {
                throw ESheepCloudAssetCoordinatorError.localFileMissing
            }
            let newOffset = try await transport.uploadResumableChunk(
                data,
                sessionURL: session.url,
                authorizationToken: token,
                byteOffset: offset
            )
            guard newOffset == offset + Int64(data.count),
                  newOffset <= work.byteCount else {
                throw ESheepCloudAssetCoordinatorError.invalidProgress
            }
            offset = newOffset
            try recordProgress(work, offset: offset)
        }
        try await transport.confirmAssetUpload(
            farmID: work.farmID,
            farmGeneration: work.farmGeneration,
            assetID: work.assetID,
            variant: work.variant
        )
        try markVerified(work)
    }

    private func nextUpload(farmID: UUID) throws -> ESheepCloudPendingAssetUpload? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // A cutover creates a new farm generation. Old-generation resources
        // remain available for audit/recovery, but must never be uploaded by
        // the active V2 worker after the authority changes.
        guard let farmState = try context.fetch(FetchDescriptor<ESheepCloudFarmState>())
            .first(where: {
                $0.farmID == farmID &&
                    $0.activityState == .active &&
                    $0.integrityState == .passed
            }) else {
            return nil
        }
        let values = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .filter {
                $0.farmID == farmID &&
                    $0.farmGeneration == farmState.farmGeneration &&
                    ($0.nextTransferRetryAt == nil || $0.nextTransferRetryAt! <= .now)
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        for value in values {
            for variant in [ESheepCloudAssetVariantV2.thumbnail, .avatar, .original] {
                guard isUploadable(state: transferState(value, variant: variant)),
                      let digest = variantDigest(value, variant: variant),
                      let path = relativePath(value, variant: variant),
                      digest.isESheepCloudSHA256,
                      !path.isEmpty else { continue }
                let metadata = try ESheepCloudCanonicalCodec.decode(
                    [String: String].self,
                    from: value.metadataData
                )
                guard try ESheepCloudCanonicalCodec.digest(metadata) == value.metadataDigest else {
                    throw ESheepCloudAssetCoordinatorError.malformedState
                }
                setTransferState(value, variant: variant, state: .transferring)
                value.transferAttemptCount += 1
                value.nextTransferRetryAt = nil
                value.lastErrorTraceID = nil
                value.updatedAt = .now
                try context.save()
                return .init(
                    farmID: value.farmID,
                    farmGeneration: value.farmGeneration,
                    assetID: value.id,
                    sheepID: value.sheepID,
                    logicalSHA256: value.contentSHA256,
                    variant: variant,
                    variantSHA256: digest,
                    relativePath: path,
                    byteCount: variantByteCount(value, variant: variant),
                    byteOffset: transferredByteCount(value, variant: variant),
                    contentType: variant == .original
                        ? (metadata["mimeType"] ?? "application/octet-stream")
                        : "image/jpeg",
                    metadata: metadata,
                    metadataDigest: value.metadataDigest,
                    sessionURL: uploadSessionURL(value, variant: variant),
                    sessionExpiresAt: uploadSessionExpiresAt(value, variant: variant)
                )
            }
        }
        return nil
    }

    private func markPrepared(
        _ work: ESheepCloudPendingAssetUpload,
        objectKey: String
    ) throws {
        try update(work) { value in
            switch work.variant {
            case .thumbnail: value.thumbnailRemoteObjectKey = objectKey
            case .avatar: value.avatarRemoteObjectKey = objectKey
            case .original: value.originalRemoteObjectKey = objectKey
            }
        }
    }

    private func recordSession(
        _ work: ESheepCloudPendingAssetUpload,
        session: ESheepCloudResumableUploadSessionV2
    ) throws {
        try update(work) { value in
            switch work.variant {
            case .thumbnail:
                value.thumbnailUploadSessionURL = session.url.absoluteString
                value.thumbnailUploadSessionExpiresAt = session.expiresAt
            case .avatar:
                value.avatarUploadSessionURL = session.url.absoluteString
                value.avatarUploadSessionExpiresAt = session.expiresAt
            case .original:
                value.originalUploadSessionURL = session.url.absoluteString
                value.originalUploadSessionExpiresAt = session.expiresAt
            }
            setTransferredByteCount(value, variant: work.variant, count: session.byteOffset)
        }
    }

    private func recordProgress(
        _ work: ESheepCloudPendingAssetUpload,
        offset: Int64
    ) throws {
        try update(work) { value in
            setTransferredByteCount(value, variant: work.variant, count: offset)
            value.uploadedByteCount = value.thumbnailTransferredByteCount +
                value.avatarTransferredByteCount + value.originalTransferredByteCount
        }
    }

    private func markVerified(_ work: ESheepCloudPendingAssetUpload) throws {
        try update(work) { value in
            setTransferState(value, variant: work.variant, state: .verified)
            setTransferredByteCount(value, variant: work.variant, count: work.byteCount)
            value.verifiedRemoteByteCount = verifiedByteCount(value)
            value.lastVerifiedAt = .now
            value.transferAttemptCount = 0
            value.nextTransferRetryAt = nil
            value.lastErrorTraceID = nil
            clearUploadSession(value, variant: work.variant)
        }
    }

    private func markFailed(
        _ work: ESheepCloudPendingAssetUpload,
        traceID: String
    ) throws {
        try update(work) { value in
            setTransferState(value, variant: work.variant, state: .failed)
            value.lastErrorTraceID = traceID
            let exponent = min(9, max(0, value.transferAttemptCount - 1))
            value.nextTransferRetryAt = .now.addingTimeInterval(
                min(900, pow(2, Double(exponent)) * 2) * Double.random(in: 0.8...1.2)
            )
        }
    }

    private func update(
        _ work: ESheepCloudPendingAssetUpload,
        mutation: (ESheepCloudAssetState) -> Void
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let value = try context.fetch(FetchDescriptor<ESheepCloudAssetState>())
            .first(where: {
                $0.id == work.assetID && $0.farmID == work.farmID &&
                    $0.farmGeneration == work.farmGeneration &&
                    $0.contentSHA256 == work.logicalSHA256
            }) else {
            throw ESheepCloudAssetCoordinatorError.malformedState
        }
        mutation(value)
        value.updatedAt = .now
        try context.save()
    }

    private func isUploadable(state: ESheepCloudAssetTransferState) -> Bool {
        state == .queued || state == .failed || state == .transferring
    }

    private func transferState(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2
    ) -> ESheepCloudAssetTransferState {
        let raw: String
        switch variant {
        case .thumbnail: raw = value.thumbnailStateRawValue
        case .avatar: raw = value.avatarStateRawValue
        case .original: raw = value.originalStateRawValue
        }
        return ESheepCloudAssetTransferState(rawValue: raw) ?? .failed
    }

    private func setTransferState(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2,
        state: ESheepCloudAssetTransferState
    ) {
        switch variant {
        case .thumbnail: value.thumbnailStateRawValue = state.rawValue
        case .avatar: value.avatarStateRawValue = state.rawValue
        case .original: value.originalStateRawValue = state.rawValue
        }
    }

    private func variantDigest(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2
    ) -> String? {
        switch variant {
        case .thumbnail: value.thumbnailSHA256
        case .avatar: value.avatarSHA256
        case .original: value.originalSHA256
        }
    }

    private func relativePath(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2
    ) -> String? {
        switch variant {
        case .thumbnail: value.thumbnailRelativePath
        case .avatar: value.avatarRelativePath
        case .original: value.originalRelativePath
        }
    }

    private func variantByteCount(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2
    ) -> Int64 {
        switch variant {
        case .thumbnail: value.thumbnailByteCount
        case .avatar: value.avatarByteCount
        case .original: value.originalByteCount
        }
    }

    private func transferredByteCount(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2
    ) -> Int64 {
        switch variant {
        case .thumbnail: value.thumbnailTransferredByteCount
        case .avatar: value.avatarTransferredByteCount
        case .original: value.originalTransferredByteCount
        }
    }

    private func setTransferredByteCount(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2,
        count: Int64
    ) {
        switch variant {
        case .thumbnail: value.thumbnailTransferredByteCount = max(0, count)
        case .avatar: value.avatarTransferredByteCount = max(0, count)
        case .original: value.originalTransferredByteCount = max(0, count)
        }
    }

    private func uploadSessionURL(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2
    ) -> URL? {
        let raw: String?
        switch variant {
        case .thumbnail: raw = value.thumbnailUploadSessionURL
        case .avatar: raw = value.avatarUploadSessionURL
        case .original: raw = value.originalUploadSessionURL
        }
        return raw.flatMap(URL.init(string:))
    }

    private func uploadSessionExpiresAt(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2
    ) -> Date? {
        switch variant {
        case .thumbnail: value.thumbnailUploadSessionExpiresAt
        case .avatar: value.avatarUploadSessionExpiresAt
        case .original: value.originalUploadSessionExpiresAt
        }
    }

    private func clearUploadSession(
        _ value: ESheepCloudAssetState,
        variant: ESheepCloudAssetVariantV2
    ) {
        switch variant {
        case .thumbnail:
            value.thumbnailUploadSessionURL = nil
            value.thumbnailUploadSessionExpiresAt = nil
        case .avatar:
            value.avatarUploadSessionURL = nil
            value.avatarUploadSessionExpiresAt = nil
        case .original:
            value.originalUploadSessionURL = nil
            value.originalUploadSessionExpiresAt = nil
        }
    }

    private func verifiedByteCount(_ value: ESheepCloudAssetState) -> Int64 {
        var result: Int64 = 0
        if transferState(value, variant: .thumbnail) == .verified {
            result += value.thumbnailByteCount
        }
        if transferState(value, variant: .avatar) == .verified {
            result += value.avatarByteCount
        }
        if transferState(value, variant: .original) == .verified {
            result += value.originalByteCount
        }
        return result
    }
}

private extension String {
    var isESheepCloudSHA256: Bool {
        range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}
