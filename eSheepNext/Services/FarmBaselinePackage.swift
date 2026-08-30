import CryptoKit
import Foundation
import SwiftData

struct FarmBaselinePackageV2: Codable, Sendable, Equatable {
    static let schema = "esheepnext.supabase-baseline.v2"

    enum OperationRole: String, Codable, Sendable {
        case bootstrapEntity
        case originalHistory
        case tombstone
    }

    struct Operation: Codable, Sendable, Equatable {
        let envelope: CloudOperationEnvelope
        let clientSequence: Int64
        let role: OperationRole
        let historySummary: String
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
        let operationCount: Int
        let entityCount: Int
        let tombstoneCount: Int
        let assetCount: Int
        let originalHistoryCount: Int
        let operationDigests: [String]
        let assetDigests: [String]
    }

    let manifest: Manifest
    let manifestDigest: String
    let operations: [Operation]
    let assets: [Asset]

    var encoded: Data {
        get throws { try JSONEncoder.cloud.encode(self) }
    }
}

enum FarmBaselinePackageError: LocalizedError {
    case unsupportedFarm
    case existingPackageMismatch
    case missingEntityID
    case missingAsset(String)
    case invalidAsset(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFarm:
            "本阶段只允许星露谷测试牧场执行非空 Supabase 启云。"
        case .existingPackageMismatch:
            "已落盘的迁移基线与本地迁移记录不一致，已停止重新生成。"
        case .missingEntityID:
            "原始业务历史缺少实体标识，不能生成可验证基线。"
        case .missingAsset(let path):
            "基线照片文件缺失：\(path)。"
        case .invalidAsset(let path):
            "基线照片摘要不一致：\(path)。"
        }
    }
}

@MainActor
struct FarmBaselinePackageBuilder {
    static let developmentTargetFarmID = UUID(
        uuidString: "8B0FA55E-2A34-4398-AE77-7D7D3701C5DD"
    )!

    private let deviceIdentity: DeviceIdentityActor

    init(deviceIdentity: DeviceIdentityActor = .shared) {
        self.deviceIdentity = deviceIdentity
    }

    func loadOrCreate(
        farm: FarmRecord,
        migrationID: UUID,
        authorityGeneration: Int,
        context: ModelContext
    ) async throws -> (FarmBaselinePackageV2, FarmBaselineMigrationRecord) {
        #if DEBUG
        guard farm.id == Self.developmentTargetFarmID else {
            throw FarmBaselinePackageError.unsupportedFarm
        }
        #endif

        if let record = try validMigrationRecord(
            farmID: farm.id,
            migrationID: migrationID,
            context: context
        ) {
            let url = try Self.packageURL(relativePath: record.packageRelativePath)
            let data = try Data(contentsOf: url)
            guard Self.digest(data) == record.packageDigest else {
                throw FarmBaselinePackageError.existingPackageMismatch
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let package = try decoder.decode(
                FarmBaselinePackageV2.self,
                from: data
            )
            guard package.manifest.farmID == farm.id,
                  package.manifest.migrationID == migrationID,
                  package.manifestDigest == Self.digest(
                    try JSONEncoder.cloud.encode(package.manifest)
                  ) else {
                throw FarmBaselinePackageError.existingPackageMismatch
            }
            return (package, record)
        }

        let sequences = try ensureOriginalSequences(farmID: farm.id, context: context)
        let frozenSequence = sequences.values.max() ?? 0
        let identity = try await deviceIdentity.identity()
        let originalHistoryCutoff = try developmentCloneCutoff(
            farmID: farm.id,
            context: context
        )
        let originalOperations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter {
                $0.farmID == farm.id &&
                    $0.kindRawValue != DomainOperationKind.bootstrapEntity.rawValue &&
                    (
                        originalHistoryCutoff == nil ||
                            $0.occurredAt < originalHistoryCutoff!
                    )
            }
            .sorted {
                let lhs = sequences[$0.id] ?? 0
                let rhs = sequences[$1.id] ?? 0
                if lhs != rhs { return lhs < rhs }
                return $0.id.uuidString < $1.id.uuidString
            }
        let activeTombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
            .filter { $0.farmID == farm.id && $0.restoredAt == nil }
            .sorted {
                if $0.deletedAt != $1.deletedAt { return $0.deletedAt < $1.deletedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        var packaged: [FarmBaselinePackageV2.Operation] = []
        for operation in originalOperations {
            guard let entityID = operation.entityID else {
                throw FarmBaselinePackageError.missingEntityID
            }
            let deletedAt = activeTombstones.first {
                $0.operationID == operation.id
            }?.deletedAt
            let envelope = try await signedEnvelope(
                farmID: farm.id,
                entityID: entityID,
                entityType: operation.entityType,
                revision: operation.resultingRevision,
                baseRevision: operation.baseRevision,
                operationID: operation.id,
                modifiedAt: operation.occurredAt,
                accountID: operation.accountID,
                deviceID: identity.deviceID,
                payload: operation.payload,
                deletedAt: deletedAt
            )
            packaged.append(.init(
                envelope: envelope,
                clientSequence: sequences[operation.id] ?? 0,
                role: deletedAt == nil ? .originalHistory : .tombstone,
                historySummary: operation.summary
            ))
        }

        var nextSequence = frozenSequence + 1
        let snapshots = try FarmBaselineSnapshotService()
            .makeProviderNeutralSnapshots(farm: farm, context: context)
        let cutoffAt = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: {
                $0.farmID == farm.id && $0.migrationID == migrationID
            })?.updatedAt ?? farm.updatedAt
        for snapshot in snapshots {
            let sourceDigest = CloudPayloadDigest.hex(for: snapshot.sourcePayload)
            let operationID = StableMigrationID.uuid(
                sessionID: migrationID,
                sourceKey: "supabase-bootstrap:\(snapshot.entityType.rawValue):" +
                    "\(snapshot.entityID.uuidString.lowercased()):\(sourceDigest)"
            )
            let bootstrap = BootstrapEntityEnvelopeV1(
                entityType: snapshot.entityType.rawValue,
                entityID: snapshot.entityID,
                sourceRevision: snapshot.sourceRevision,
                sourcePayload: snapshot.sourcePayload
            )
            var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
            wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(bootstrap)
            wrapper.integers["baselineVersion"] = 2
            wrapper.strings["baselineSlot"] = String(snapshot.replayOrder)
            wrapper.dates["baselineCutoffAt"] = cutoffAt
            let payload = try JSONEncoder.cloud.encode(wrapper)
            let envelope = try await signedEnvelope(
                farmID: farm.id,
                entityID: snapshot.entityID,
                entityType: snapshot.entityType.rawValue,
                revision: snapshot.sourceRevision,
                baseRevision: 0,
                operationID: operationID,
                modifiedAt: cutoffAt,
                accountID: farm.ownerAccountID,
                deviceID: identity.deviceID,
                payload: payload,
                deletedAt: nil
            )
            packaged.append(.init(
                envelope: envelope,
                clientSequence: nextSequence,
                role: .bootstrapEntity,
                historySummary: ""
            ))
            nextSequence += 1
        }

        let assets = try assetDescriptors(farmID: farm.id, context: context)
        let photosByID = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                .filter { $0.farmID == farm.id }
                .map { ($0.id, $0) }
        )
        for asset in assets {
            guard let photo = photosByID[asset.assetID] else {
                throw FarmBaselinePackageError.missingAsset(asset.relativePath)
            }
            // Deleted photos remain encrypted/private assets in the checkpoint
            // manifest, but are not recreated as live photo entities. Their
            // Tombstones below retain the deletion.
            guard photo.deletedAt == nil else { continue }
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
            let operationID = StableMigrationID.uuid(
                sessionID: migrationID,
                sourceKey: "supabase-photo:\(asset.assetID.uuidString.lowercased()):" +
                    asset.sha256
            )
            let envelope = try await signedEnvelope(
                farmID: farm.id,
                entityID: asset.assetID,
                entityType: CloudEntityType.photoAsset.rawValue,
                revision: 1,
                baseRevision: 0,
                operationID: operationID,
                modifiedAt: photo.createdAt,
                accountID: farm.ownerAccountID,
                deviceID: identity.deviceID,
                payload: data,
                deletedAt: nil
            )
            packaged.append(.init(
                envelope: envelope,
                clientSequence: nextSequence,
                role: .bootstrapEntity,
                historySummary: ""
            ))
            nextSequence += 1
        }

        // Tombstones must be the final projection operations. Original delete
        // operations keep their operation IDs and user-visible summaries, but
        // receive migration-only sequence positions after bootstrap entities.
        // This prevents a later bootstrap from accidentally reviving a deleted
        // entity while preserving the original business history itself.
        let originalTombstoneItems = packaged.filter { $0.role == .tombstone }
        packaged.removeAll { $0.role == .tombstone }
        for item in originalTombstoneItems {
            packaged.append(.init(
                envelope: item.envelope,
                clientSequence: nextSequence,
                role: .tombstone,
                historySummary: item.historySummary
            ))
            nextSequence += 1
        }

        let originalTombstoneOperationIDs = Set(originalOperations.map(\.id))
        for tombstone in activeTombstones
            where tombstone.operationID == nil ||
                !originalTombstoneOperationIDs.contains(tombstone.operationID!) {
            guard let entityType = CloudEntityType(rawValue: tombstone.entityType) else {
                continue
            }
            let operationID = tombstone.operationID ?? StableMigrationID.uuid(
                sessionID: migrationID,
                sourceKey: "supabase-tombstone:\(tombstone.id.uuidString.lowercased())"
            )
            let payload = try FarmCommandCloudPayloadEncoder.encode(.tombstoneEntity(
                entityType: entityType,
                entityID: tombstone.entityID,
                reason: tombstone.reason
            ))
            let envelope = try await signedEnvelope(
                farmID: farm.id,
                entityID: tombstone.entityID,
                entityType: tombstone.entityType,
                revision: tombstone.revision,
                baseRevision: max(0, tombstone.revision - 1),
                operationID: operationID,
                modifiedAt: tombstone.deletedAt,
                accountID: tombstone.deletedByAccountID,
                deviceID: identity.deviceID,
                payload: payload,
                deletedAt: tombstone.deletedAt
            )
            packaged.append(.init(
                envelope: envelope,
                clientSequence: nextSequence,
                role: .tombstone,
                historySummary: "删除权威记录"
            ))
            nextSequence += 1
        }

        packaged.sort {
            if $0.clientSequence != $1.clientSequence {
                return $0.clientSequence < $1.clientSequence
            }
            return $0.envelope.operationID.uuidString <
                $1.envelope.operationID.uuidString
        }
        let projectedEntityCount = Set(packaged.map {
            "\($0.envelope.entityType):\($0.envelope.entityID.uuidString.lowercased())"
        }).count
        let manifest = FarmBaselinePackageV2.Manifest(
            schema: FarmBaselinePackageV2.schema,
            farmID: farm.id,
            migrationID: migrationID,
            authorityGeneration: authorityGeneration,
            frozenOperationSequence: frozenSequence,
            operationCount: packaged.count,
            entityCount: projectedEntityCount,
            tombstoneCount: activeTombstones.count,
            assetCount: assets.count,
            originalHistoryCount: originalOperations.count,
            operationDigests: packaged.map {
                "\($0.envelope.operationID.uuidString.lowercased()):" +
                    "\($0.envelope.payloadDigest):\($0.clientSequence)"
            },
            assetDigests: assets.map {
                "\($0.assetID.uuidString.lowercased()):\($0.sha256):\($0.byteCount)"
            }
        )
        let manifestDigest = Self.digest(try JSONEncoder.cloud.encode(manifest))
        let package = FarmBaselinePackageV2(
            manifest: manifest,
            manifestDigest: manifestDigest,
            operations: packaged,
            assets: assets
        )
        let packageData = try package.encoded
        let relativePath = "SupabaseBaselinePackages/" +
            "\(farm.id.uuidString.lowercased())/" +
            "\(migrationID.uuidString.lowercased()).json"
        let url = try Self.packageURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try packageData.write(to: url, options: [.atomic, .completeFileProtection])

        if let counter = try context.fetch(FetchDescriptor<FarmOperationSequenceCounter>())
            .first(where: { $0.farmID == farm.id }) {
            counter.nextSequence = max(counter.nextSequence, nextSequence)
        } else {
            context.insert(FarmOperationSequenceCounter(
                farmID: farm.id,
                nextSequence: nextSequence
            ))
        }
        let record = FarmBaselineMigrationRecord(
            farmID: farm.id,
            migrationID: migrationID,
            frozenOperationSequence: frozenSequence,
            packageRelativePath: relativePath,
            packageDigest: Self.digest(packageData),
            operationCount: manifest.operationCount,
            entityCount: manifest.entityCount,
            tombstoneCount: manifest.tombstoneCount,
            assetCount: manifest.assetCount
        )
        context.insert(record)
        try context.save()
        return (package, record)
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
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        for operation in operations where sequences[operation.id] == nil {
            sequences[operation.id] = try FarmStorageRouter.takeNextOperationSequence(
                farmID: farmID,
                operationID: operation.id,
                context: context
            )
        }
        try context.save()
        return sequences
    }

    private func signedEnvelope(
        farmID: UUID,
        entityID: UUID,
        entityType: String,
        revision: Int,
        baseRevision: Int,
        operationID: UUID,
        modifiedAt: Date,
        accountID: UUID,
        deviceID: UUID,
        payload: Data,
        deletedAt: Date?
    ) async throws -> CloudOperationEnvelope {
        var envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: entityType,
            schemaVersion: 2,
            revision: max(1, revision),
            baseRevision: max(0, baseRevision),
            operationID: operationID,
            modifiedAt: modifiedAt,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: deviceID,
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "supabase-authenticated-owner-baseline",
            operationSignature: Data(),
            deletedAt: deletedAt
        )
        let signature = try await deviceIdentity.sign(envelope.canonicalSigningData)
        envelope = CloudOperationEnvelope(
            farmID: envelope.farmID,
            entityID: envelope.entityID,
            entityType: envelope.entityType,
            schemaVersion: envelope.schemaVersion,
            revision: envelope.revision,
            baseRevision: envelope.baseRevision,
            operationID: envelope.operationID,
            modifiedAt: envelope.modifiedAt,
            modifiedByAccountID: envelope.modifiedByAccountID,
            modifiedByDeviceID: envelope.modifiedByDeviceID,
            payload: envelope.payload,
            payloadDigest: envelope.payloadDigest,
            capabilityCertificate: envelope.capabilityCertificate,
            operationSignature: signature,
            deletedAt: envelope.deletedAt
        )
        return envelope
    }

    private func assetDescriptors(
        farmID: UUID,
        context: ModelContext
    ) throws -> [FarmBaselinePackageV2.Asset] {
        try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { photo in
                let url = try Self.assetURL(relativePath: photo.relativePath)
                guard let data = try? Data(contentsOf: url) else {
                    throw FarmBaselinePackageError.missingAsset(photo.relativePath)
                }
                guard Self.digest(data) == photo.sha256.lowercased() else {
                    throw FarmBaselinePackageError.invalidAsset(photo.relativePath)
                }
                return .init(
                    assetID: photo.id,
                    relativePath: photo.relativePath,
                    sha256: photo.sha256.lowercased(),
                    byteCount: Int64(data.count),
                    contentType: photo.mimeType
                )
            }
    }

    private func developmentCloneCutoff(
        farmID: UUID,
        context: ModelContext
    ) throws -> Date? {
        #if DEBUG
        guard farmID == Self.developmentTargetFarmID else { return nil }
        return try context.fetch(FetchDescriptor<FarmActivity>())
            .first {
                $0.farmID == farmID &&
                    $0.title == "Development 牧场克隆完成"
            }?
            .occurredAt
        #else
        return nil
        #endif
    }

    private func validMigrationRecord(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws -> FarmBaselineMigrationRecord? {
        let records = try context.fetch(
            FetchDescriptor<FarmBaselineMigrationRecord>()
        ).filter {
            $0.farmID == farmID && $0.migrationID == migrationID
        }
        guard !records.isEmpty else { return nil }
        var selected: FarmBaselineMigrationRecord?
        for record in records.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let url = try Self.packageURL(
                relativePath: record.packageRelativePath
            )
            guard let data = try? Data(contentsOf: url),
                  Self.digest(data) == record.packageDigest else {
                continue
            }
            selected = record
            break
        }
        guard let selected else {
            throw FarmBaselinePackageError.existingPackageMismatch
        }
        for record in records where record.id != selected.id {
            context.delete(record)
        }
        if records.count > 1 { try context.save() }
        return selected
    }

    static func packageURL(relativePath: String) throws -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: relativePath)
    }

    static func assetURL(relativePath: String) throws -> URL {
        PhotoTransferActor.absoluteURL(for: relativePath)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
