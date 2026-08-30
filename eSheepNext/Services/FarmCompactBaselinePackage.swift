import Compression
import CryptoKit
import Foundation
import SwiftData

struct FarmCompactBaselinePackageV1: Codable, Sendable, Equatable {
    static let schema = "esheepnext.supabase-compact-checkpoint.v1"

    struct FarmSnapshot: Codable, Sendable, Equatable {
        let id: UUID
        let ownerAccountID: UUID
        let name: String
        let role: FarmRole
        let membershipStatusRawValue: String
        let createdAt: Date
        let updatedAt: Date
        let locationDisplayName: String?
        let latitude: Double?
        let longitude: Double?
        let coordinateReferenceSystem: String
        let addressSnapshot: String?
        let timeZoneIdentifier: String
        let locationSourceRawValue: String?
        let horizontalAccuracyMeters: Double?
        let locationUpdatedAt: Date?
    }

    struct Projection: Codable, Sendable, Equatable {
        let entityType: String
        let entityID: UUID
        let revision: Int
        let payload: Data
        let payloadDigest: String
        let modifiedAt: Date
        let deletedAt: Date?
        let replayOrder: Int
    }

    struct HistoryOperation: Codable, Sendable, Equatable {
        let operationID: UUID
        let accountID: UUID
        let kindRawValue: String
        let occurredAt: Date
        let summary: String
        let entityType: String
        let entityID: UUID?
        let baseRevision: Int
        let resultingRevision: Int
        let payload: Data
        let payloadDigest: String
        let clientSequence: Int64
    }

    struct Tombstone: Codable, Sendable, Equatable {
        let id: UUID
        let entityType: String
        let entityID: UUID
        let deletedByAccountID: UUID
        let reason: String
        let revision: Int
        let operationID: UUID?
        let deletedAt: Date
        let restoredAt: Date?
        let restoredByOperationID: UUID?
    }

    struct Asset: Codable, Sendable, Equatable {
        let assetID: UUID
        let relativePath: String
        let sha256: String
        let byteCount: Int64
        let contentType: String
    }

    struct Manifest: Codable, Sendable, Equatable {
        let schema: String
        let farmID: UUID
        let migrationID: UUID
        let authorityGeneration: Int
        let frozenOperationSequence: Int64
        let projectionCount: Int
        let activeProjectionCount: Int
        let tombstoneProjectionCount: Int
        let tombstoneHistoryCount: Int
        let historyOperationCount: Int
        let assetCount: Int
        let projectionDigest: String
        let historyDigest: String
        let tombstoneDigest: String
        let assetDigest: String
    }

    let manifest: Manifest
    let farm: FarmSnapshot
    let projections: [Projection]
    let history: [HistoryOperation]
    let tombstones: [Tombstone]
    let assets: [Asset]

    var manifestDigest: String {
        get throws {
            try FarmCompactBaselineArchive.digest(
                JSONEncoder.cloud.encode(manifest)
            )
        }
    }
}

enum FarmCompactBaselineArchiveError: LocalizedError {
    case invalidHeader
    case compressionFailed
    case decompressionFailed
    case uncompressedSizeInvalid
    case digestMismatch

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            "紧凑基线文件头无效。"
        case .compressionFailed:
            "紧凑基线压缩失败。"
        case .decompressionFailed:
            "紧凑基线解压失败。"
        case .uncompressedSizeInvalid:
            "紧凑基线原始大小无效。"
        case .digestMismatch:
            "紧凑基线摘要不一致。"
        }
    }
}

enum FarmCompactBaselineArchive {
    private static let magic = Data([0x45, 0x53, 0x42, 0x43, 0x30, 0x30, 0x30, 0x31])
    private static let headerByteCount = 16
    private static let maximumUncompressedBytes = 512 * 1_024 * 1_024

    static func encode(_ package: FarmCompactBaselinePackageV1) throws -> Data {
        let clear = try JSONEncoder.cloud.encode(package)
        var destinationCapacity = max(64 * 1_024, clear.count / 2)
        var compressed = Data()

        while destinationCapacity <= clear.count * 2 + 64 * 1_024 {
            var candidate = Data(count: destinationCapacity)
            let encodedCount = candidate.withUnsafeMutableBytes { destinationBuffer in
                clear.withUnsafeBytes { sourceBuffer in
                    guard let destination = destinationBuffer.bindMemory(
                        to: UInt8.self
                    ).baseAddress,
                    let source = sourceBuffer.bindMemory(
                        to: UInt8.self
                    ).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(
                        destination,
                        destinationCapacity,
                        source,
                        clear.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
            }
            if encodedCount > 0 {
                candidate.count = encodedCount
                compressed = candidate
                break
            }
            destinationCapacity *= 2
        }
        guard !compressed.isEmpty else {
            throw FarmCompactBaselineArchiveError.compressionFailed
        }

        var output = Data()
        output.reserveCapacity(headerByteCount + compressed.count)
        output.append(magic)
        var uncompressedSize = UInt64(clear.count).bigEndian
        withUnsafeBytes(of: &uncompressedSize) { output.append(contentsOf: $0) }
        output.append(compressed)
        return output
    }

    static func decode(_ archive: Data) throws -> FarmCompactBaselinePackageV1 {
        guard archive.count > headerByteCount,
              archive.prefix(magic.count) == magic else {
            throw FarmCompactBaselineArchiveError.invalidHeader
        }
        let sizeData = archive[magic.count..<headerByteCount]
        let uncompressedSize = sizeData.reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard uncompressedSize > 0,
              uncompressedSize <= UInt64(maximumUncompressedBytes) else {
            throw FarmCompactBaselineArchiveError.uncompressedSizeInvalid
        }
        let compressed = archive.dropFirst(headerByteCount)
        var clear = Data(count: Int(uncompressedSize))
        let decodedCount = clear.withUnsafeMutableBytes { destinationBuffer in
            compressed.withUnsafeBytes { sourceBuffer in
                guard let destination = destinationBuffer.bindMemory(
                    to: UInt8.self
                ).baseAddress,
                let source = sourceBuffer.bindMemory(
                    to: UInt8.self
                ).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destination,
                    Int(uncompressedSize),
                    source,
                    compressed.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decodedCount == Int(uncompressedSize) else {
            throw FarmCompactBaselineArchiveError.decompressionFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCompactBaselinePackageV1.self, from: clear)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
struct FarmCompactBaselinePackageBuilder {
    static let relativeRoot = "SupabaseCompactCheckpoints"

    func loadOrCreate(
        farm: FarmRecord,
        migrationID: UUID,
        authorityGeneration: Int,
        context: ModelContext
    ) throws -> (FarmCompactBaselinePackageV1, Data, FarmBaselineMigrationRecord) {
        if let record = try validRecord(
            farmID: farm.id,
            migrationID: migrationID,
            context: context
        ) {
            let archive = try Data(
                contentsOf: try Self.archiveURL(
                    relativePath: record.packageRelativePath
                )
            )
            guard FarmCompactBaselineArchive.digest(archive) ==
                    record.packageDigest else {
                throw FarmCompactBaselineArchiveError.digestMismatch
            }
            let package = try FarmCompactBaselineArchive.decode(archive)
            try validate(
                package,
                farmID: farm.id,
                migrationID: migrationID,
                authorityGeneration: authorityGeneration
            )
            return (package, archive, record)
        }

        let sequences = try ensureOriginalSequences(
            farmID: farm.id,
            context: context
        )
        let frozenSequence = sequences.values.max() ?? 0
        let cutoffAt = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first {
                $0.farmID == farm.id && $0.migrationID == migrationID
            }?.updatedAt ?? farm.updatedAt
        let history = try historyOperations(
            farmID: farm.id,
            sequences: sequences,
            context: context
        )
        let tombstones = try tombstoneHistory(
            farmID: farm.id,
            context: context
        )
        let assets = try assetDescriptors(
            farmID: farm.id,
            context: context
        )
        var projections = try FarmBaselineSnapshotService()
            .makeProviderNeutralSnapshots(farm: farm, context: context)
            .map {
                FarmCompactBaselinePackageV1.Projection(
                    entityType: $0.entityType.rawValue,
                    entityID: $0.entityID,
                    revision: max(1, $0.sourceRevision),
                    payload: $0.sourcePayload,
                    payloadDigest: FarmCompactBaselineArchive.digest(
                        $0.sourcePayload
                    ),
                    modifiedAt: cutoffAt,
                    deletedAt: nil,
                    replayOrder: $0.replayOrder
                )
            }
        projections.append(contentsOf: try activePhotoProjections(
            farm: farm,
            assets: assets,
            cutoffAt: cutoffAt,
            context: context
        ))

        var latestTombstones: [String: FarmCompactBaselinePackageV1.Tombstone] = [:]
        for item in tombstones {
            let key = "\(item.entityType):\(item.entityID.uuidString.lowercased())"
            if let existing = latestTombstones[key],
               existing.deletedAt > item.deletedAt {
                continue
            }
            latestTombstones[key] = item
        }
        for (offset, item) in latestTombstones.values
            .sorted(by: {
                if $0.deletedAt != $1.deletedAt {
                    return $0.deletedAt < $1.deletedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            })
            .enumerated() {
            guard let entityType = CloudEntityType(rawValue: item.entityType) else {
                continue
            }
            let payload = try FarmCommandCloudPayloadEncoder.encode(
                .tombstoneEntity(
                    entityType: entityType,
                    entityID: item.entityID,
                    reason: item.reason
                )
            )
            projections.append(.init(
                entityType: item.entityType,
                entityID: item.entityID,
                revision: max(1, item.revision),
                payload: payload,
                payloadDigest: FarmCompactBaselineArchive.digest(payload),
                modifiedAt: item.deletedAt,
                deletedAt: item.deletedAt,
                replayOrder: 1_000_000 + offset
            ))
        }

        var uniqueProjections: [String: FarmCompactBaselinePackageV1.Projection] = [:]
        for projection in projections.sorted(by: projectionOrder) {
            uniqueProjections[
                "\(projection.entityType):" +
                    projection.entityID.uuidString.lowercased()
            ] = projection
        }
        projections = uniqueProjections.values.sorted(by: projectionOrder)
        let activeProjectionCount = projections.count { $0.deletedAt == nil }
        let tombstoneProjectionCount = projections.count - activeProjectionCount

        let projectionDigest = digestLines(projections.map {
            "\($0.entityType):\($0.entityID.uuidString.lowercased()):" +
                "\($0.revision):\($0.payloadDigest):" +
                "\($0.deletedAt?.timeIntervalSince1970 ?? -1)"
        })
        let historyDigest = digestLines(history.map {
            "\($0.operationID.uuidString.lowercased()):" +
                "\($0.payloadDigest):\($0.clientSequence)"
        })
        let tombstoneDigest = digestLines(tombstones.map {
            "\($0.id.uuidString.lowercased()):" +
                "\($0.entityType):\($0.entityID.uuidString.lowercased()):" +
                "\(Int64($0.deletedAt.timeIntervalSince1970 * 1_000))"
        })
        let assetDigest = digestLines(assets.map {
            "\($0.assetID.uuidString.lowercased()):\($0.sha256):\($0.byteCount)"
        })
        let manifest = FarmCompactBaselinePackageV1.Manifest(
            schema: FarmCompactBaselinePackageV1.schema,
            farmID: farm.id,
            migrationID: migrationID,
            authorityGeneration: authorityGeneration,
            frozenOperationSequence: frozenSequence,
            projectionCount: projections.count,
            activeProjectionCount: activeProjectionCount,
            tombstoneProjectionCount: tombstoneProjectionCount,
            tombstoneHistoryCount: tombstones.count,
            historyOperationCount: history.count,
            assetCount: assets.count,
            projectionDigest: projectionDigest,
            historyDigest: historyDigest,
            tombstoneDigest: tombstoneDigest,
            assetDigest: assetDigest
        )
        let package = FarmCompactBaselinePackageV1(
            manifest: manifest,
            farm: .init(
                id: farm.id,
                ownerAccountID: farm.ownerAccountID,
                name: farm.name,
                role: farm.role,
                membershipStatusRawValue: farm.membershipStatusRawValue,
                createdAt: farm.createdAt,
                updatedAt: farm.updatedAt,
                locationDisplayName: farm.locationDisplayName,
                latitude: farm.latitude,
                longitude: farm.longitude,
                coordinateReferenceSystem: farm.coordinateReferenceSystem,
                addressSnapshot: farm.addressSnapshot,
                timeZoneIdentifier: farm.timeZoneIdentifier,
                locationSourceRawValue: farm.locationSourceRawValue,
                horizontalAccuracyMeters: farm.horizontalAccuracyMeters,
                locationUpdatedAt: farm.locationUpdatedAt
            ),
            projections: projections,
            history: history,
            tombstones: tombstones,
            assets: assets
        )
        let archive = try FarmCompactBaselineArchive.encode(package)
        let relativePath = "\(Self.relativeRoot)/" +
            "\(farm.id.uuidString.lowercased())/" +
            "\(migrationID.uuidString.lowercased()).esbc"
        let url = try Self.archiveURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try archive.write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
        let record = FarmBaselineMigrationRecord(
            farmID: farm.id,
            migrationID: migrationID,
            frozenOperationSequence: frozenSequence,
            packageRelativePath: relativePath,
            packageDigest: FarmCompactBaselineArchive.digest(archive),
            operationCount: manifest.projectionCount,
            entityCount: manifest.projectionCount,
            tombstoneCount: manifest.tombstoneHistoryCount,
            assetCount: manifest.assetCount
        )
        context.insert(record)
        try context.save()
        return (package, archive, record)
    }

    static func archiveURL(relativePath: String) throws -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: relativePath)
    }

    static func assetURL(relativePath: String) throws -> URL {
        try FarmBaselinePackageBuilder.assetURL(relativePath: relativePath)
    }

    private func validate(
        _ package: FarmCompactBaselinePackageV1,
        farmID: UUID,
        migrationID: UUID,
        authorityGeneration: Int
    ) throws {
        guard package.manifest.schema == FarmCompactBaselinePackageV1.schema,
              package.manifest.farmID == farmID,
              package.farm.id == farmID,
              package.manifest.migrationID == migrationID,
              package.manifest.authorityGeneration == authorityGeneration,
              package.manifest.projectionCount == package.projections.count,
              package.manifest.historyOperationCount == package.history.count,
              package.manifest.tombstoneHistoryCount == package.tombstones.count,
              package.manifest.assetCount == package.assets.count else {
            throw FarmBaselinePackageError.existingPackageMismatch
        }
    }

    private func validRecord(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws -> FarmBaselineMigrationRecord? {
        let records = try context.fetch(
            FetchDescriptor<FarmBaselineMigrationRecord>()
        ).filter {
            $0.farmID == farmID &&
                $0.migrationID == migrationID &&
                $0.packageRelativePath.hasSuffix(".esbc")
        }
        guard !records.isEmpty else { return nil }
        guard let selected = records.sorted(by: {
            $0.updatedAt > $1.updatedAt
        }).first(where: { record in
            guard let data = try? Data(
                contentsOf: try Self.archiveURL(
                    relativePath: record.packageRelativePath
                )
            ) else {
                return false
            }
            return FarmCompactBaselineArchive.digest(data) ==
                record.packageDigest
        }) else {
            throw FarmBaselinePackageError.existingPackageMismatch
        }
        for record in records where record.id != selected.id {
            context.delete(record)
        }
        if records.count > 1 { try context.save() }
        return selected
    }

    private func ensureOriginalSequences(
        farmID: UUID,
        context: ModelContext
    ) throws -> [UUID: Int64] {
        var sequences = try FarmStorageRouter.operationSequences(
            farmID: farmID,
            context: context
        )
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == farmID }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        for operation in operations where sequences[operation.id] == nil {
            sequences[operation.id] =
                try FarmStorageRouter.takeNextOperationSequence(
                    farmID: farmID,
                    operationID: operation.id,
                    context: context
                )
        }
        try context.save()
        return sequences
    }

    private func historyOperations(
        farmID: UUID,
        sequences: [UUID: Int64],
        context: ModelContext
    ) throws -> [FarmCompactBaselinePackageV1.HistoryOperation] {
        try context.fetch(FetchDescriptor<DomainOperation>())
            .filter {
                $0.farmID == farmID &&
                    $0.kindRawValue !=
                        DomainOperationKind.bootstrapEntity.rawValue
            }
            .map {
                .init(
                    operationID: $0.id,
                    accountID: $0.accountID,
                    kindRawValue: $0.kindRawValue,
                    occurredAt: $0.occurredAt,
                    summary: $0.summary,
                    entityType: $0.entityType,
                    entityID: $0.entityID,
                    baseRevision: $0.baseRevision,
                    resultingRevision: $0.resultingRevision,
                    payload: $0.payload,
                    payloadDigest: $0.payloadDigest,
                    clientSequence: sequences[$0.id] ?? 0
                )
            }
            .sorted {
                if $0.clientSequence != $1.clientSequence {
                    return $0.clientSequence < $1.clientSequence
                }
                return $0.operationID.uuidString <
                    $1.operationID.uuidString
            }
    }

    private func tombstoneHistory(
        farmID: UUID,
        context: ModelContext
    ) throws -> [FarmCompactBaselinePackageV1.Tombstone] {
        try context.fetch(FetchDescriptor<TombstoneRecord>())
            .filter { $0.farmID == farmID && $0.restoredAt == nil }
            .map {
                .init(
                    id: $0.id,
                    entityType: $0.entityType,
                    entityID: $0.entityID,
                    deletedByAccountID: $0.deletedByAccountID,
                    reason: $0.reason,
                    revision: $0.revision,
                    operationID: $0.operationID,
                    deletedAt: $0.deletedAt,
                    restoredAt: $0.restoredAt,
                    restoredByOperationID: $0.restoredByOperationID
                )
            }
            .sorted {
                if $0.deletedAt != $1.deletedAt {
                    return $0.deletedAt < $1.deletedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private func assetDescriptors(
        farmID: UUID,
        context: ModelContext
    ) throws -> [FarmCompactBaselinePackageV1.Asset] {
        try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { photo in
                let url = try FarmBaselinePackageBuilder.assetURL(
                    relativePath: photo.relativePath
                )
                guard let data = try? Data(contentsOf: url) else {
                    throw FarmBaselinePackageError.missingAsset(
                        photo.relativePath
                    )
                }
                let digest = FarmCompactBaselineArchive.digest(data)
                guard digest == photo.sha256.lowercased() else {
                    throw FarmBaselinePackageError.invalidAsset(
                        photo.relativePath
                    )
                }
                return .init(
                    assetID: photo.id,
                    relativePath: photo.relativePath,
                    sha256: digest,
                    byteCount: Int64(data.count),
                    contentType: photo.mimeType
                )
            }
    }

    private func activePhotoProjections(
        farm: FarmRecord,
        assets: [FarmCompactBaselinePackageV1.Asset],
        cutoffAt: Date,
        context: ModelContext
    ) throws -> [FarmCompactBaselinePackageV1.Projection] {
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farm.id && $0.deletedAt == nil }
        let photosByID = Dictionary(
            uniqueKeysWithValues: photos.map { ($0.id, $0) }
        )
        return try assets.compactMap { asset in
            guard let photo = photosByID[asset.assetID] else { return nil }
            var payload = FarmCommandCloudPayload(kind: .addPhoto)
            payload.strings = [
                "sha256": asset.sha256,
                "sourceSHA256": photo.sourceSHA256.isEmpty
                    ? asset.sha256
                    : photo.sourceSHA256,
                "mimeType": asset.contentType,
            ]
            payload.optionalIdentifiers = ["sheepID": photo.sheepID]
            payload.optionalDates = ["capturedAt": photo.capturedAt]
            payload.integers = [
                "sourcePixelWidth": photo.sourcePixelWidth,
                "sourcePixelHeight": photo.sourcePixelHeight,
                "cloudPixelWidth": photo.cloudPixelWidth,
                "cloudPixelHeight": photo.cloudPixelHeight,
                "byteCount": Int(asset.byteCount),
            ]
            let data = try JSONEncoder.cloud.encode(payload)
            return .init(
                entityType: CloudEntityType.photoAsset.rawValue,
                entityID: asset.assetID,
                revision: 1,
                payload: data,
                payloadDigest: FarmCompactBaselineArchive.digest(data),
                modifiedAt: photo.createdAt,
                deletedAt: nil,
                replayOrder: 900_000
            )
        }
    }

    private func projectionOrder(
        _ lhs: FarmCompactBaselinePackageV1.Projection,
        _ rhs: FarmCompactBaselinePackageV1.Projection
    ) -> Bool {
        if lhs.replayOrder != rhs.replayOrder {
            return lhs.replayOrder < rhs.replayOrder
        }
        if lhs.entityType != rhs.entityType {
            return lhs.entityType < rhs.entityType
        }
        return lhs.entityID.uuidString < rhs.entityID.uuidString
    }

    private func digestLines(_ lines: [String]) -> String {
        FarmCompactBaselineArchive.digest(
            Data(lines.joined(separator: "\n").utf8)
        )
    }
}
