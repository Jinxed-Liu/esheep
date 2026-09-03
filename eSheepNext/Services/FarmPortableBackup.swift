import Foundation
import SwiftData

struct FarmPortableBackupEnvelopeV2: Codable, Sendable, Equatable {
    static let schemaVersion = 2

    struct Content: Codable, Sendable, Equatable {
        let legacyEnvelope: FarmBackupEnvelopeV1
        let supplement: FarmPortableBackupSupplementV2
    }

    let schemaVersion: Int
    let content: Content
    let checksum: String
}

struct FarmPortableBackupSupplementV2: Codable, Sendable, Equatable {
    struct FarmMetadata: Codable, Sendable, Equatable {
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

    struct Activity: Codable, Sendable, Equatable {
        let id: UUID; let title: String; let detail: String
        let occurredAt: Date; let createdAt: Date
    }

    struct Weaning: Codable, Sendable, Equatable {
        let id: UUID; let sheepID: UUID; let occurredAt: Date
        let weanWeightText: String; let birthAt: Date?
        let birthWeightText: String?; let averageDailyGainText: String?
        let damID: UUID?; let legacyDamEarTag: String?; let litterSize: Int?
        let note: String; let legacySourceKey: String?; let recordedAt: Date
        let revision: Int; let deletedAt: Date?
    }

    struct BreedingProgram: Codable, Sendable, Equatable {
        let id: UUID; let name: String; let createdAt: Date
        let legacySourceKey: String?; let revision: Int; let deletedAt: Date?
    }

    struct BreedingProgramStep: Codable, Sendable, Equatable {
        let id: UUID; let programID: UUID; let dayOffset: Int; let action: String
        let sortOrder: Int; let legacySourceKey: String?; let createdAt: Date
        let revision: Int; let deletedAt: Date?
    }

    struct ProductionBatch: Codable, Sendable, Equatable {
        let id: UUID; let name: String; let purpose: String
        let sourceRawValue: String; let statusRawValue: String
        let startedAt: Date; let endedAt: Date?; let note: String
        let createdAt: Date; let updatedAt: Date; let deletedAt: Date?
    }

    struct BatchMembership: Codable, Sendable, Equatable {
        let id: UUID; let batchID: UUID; let sheepID: UUID
        let joinedAt: Date; let leftAt: Date?; let leaveReason: String?
        let createdAt: Date; let updatedAt: Date; let deletedAt: Date?
    }

    struct DailyPenCount: Codable, Sendable, Equatable {
        let id: UUID; let penID: UUID; let purpose: String
        let date: Date; let count: Int; let rebuiltAt: Date
    }

    struct Note: Codable, Sendable, Equatable {
        let id: UUID; let sheepID: UUID?; let penID: UUID?
        let text: String; let occurredAt: Date; let createdAt: Date
        let deletedAt: Date?; let revision: Int
    }

    struct Photo: Codable, Sendable, Equatable {
        let id: UUID; let sheepID: UUID?; let legacySourceKey: String
        let originalEarTag: String; let sha256: String; let mimeType: String
        let sourceSHA256: String; let sourcePixelWidth: Int
        let sourcePixelHeight: Int; let cloudPixelWidth: Int
        let cloudPixelHeight: Int; let capturedAt: Date?
        let createdAt: Date; let deletedAt: Date?
    }

    struct SheepAvatar: Codable, Sendable, Equatable {
        let id: UUID; let sheepID: UUID; let photoAssetID: UUID?
        let updatedAt: Date
    }

    struct AssetFile: Codable, Sendable, Equatable {
        let assetID: UUID; let sha256: String; let mimeType: String
        let data: Data
    }

    let sourceStorageMode: FarmStorageMode
    let sourceAuthorityGeneration: Int
    let sourceWasFullySynchronized: Bool
    let appSchemaVersion: String
    let farmMetadata: FarmMetadata
    let activities: [Activity]
    let weanings: [Weaning]
    let breedingPrograms: [BreedingProgram]
    let breedingProgramSteps: [BreedingProgramStep]
    let productionBatches: [ProductionBatch]
    let batchMemberships: [BatchMembership]
    let dailyPenCounts: [DailyPenCount]
    let notes: [Note]
    let photos: [Photo]
    let sheepAvatars: [SheepAvatar]
    let assetFiles: [AssetFile]

    var additionalEntityCount: Int {
        activities.count + weanings.count + breedingPrograms.count +
            breedingProgramSteps.count + productionBatches.count +
            batchMemberships.count + dailyPenCounts.count + notes.count +
            photos.count + sheepAvatars.count
    }
}

struct FarmPortableBackupPreview: Sendable, Equatable {
    let legacyPreview: FarmBackupPreview
    let portableEnvelope: FarmPortableBackupEnvelopeV2?

    var sourceStorageMode: FarmStorageMode {
        portableEnvelope?.content.supplement.sourceStorageMode ?? .localOnly
    }

    var sourceWasFullySynchronized: Bool {
        portableEnvelope?.content.supplement.sourceWasFullySynchronized ?? false
    }

    var entityCount: Int {
        legacyPreview.entityCount +
            (portableEnvelope?.content.supplement.additionalEntityCount ?? 0)
    }

    var photoCount: Int {
        portableEnvelope?.content.supplement.photos.filter {
            $0.deletedAt == nil
        }.count ?? 0
    }

    var summary: String {
        let source: String
        switch sourceStorageMode {
        case .localOnly: source = "仅本机"
        case .retiredAppleCloud: source = "已停用的旧云存储"
        case .eSheepCloud, .supabase: source = "eSheep+ 云"
        }
        return "来源：\(source) · 业务记录 \(entityCount) · 照片 \(photoCount)"
    }
}

struct FarmPortableBackupRestoreResult: Sendable, Equatable {
    let farmID: UUID
    let restoredEntityCount: Int
    let restoredPhotoCount: Int
}

enum FarmPortableBackupError: LocalizedError {
    case unsupportedVersion
    case checksumMismatch
    case invalidSourceMode
    case duplicateIdentifier(String)
    case missingReference(String)
    case missingAsset(UUID)
    case invalidAsset(UUID)
    case sourceFarmStillPresent
    case identifierCollision

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "备份版本不受支持。"
        case .checksumMismatch: "完整备份校验失败，文件可能不完整或已被修改。"
        case .invalidSourceMode: "备份中的牧场存储来源无效。"
        case .duplicateIdentifier(let type): "完整备份包含重复的\(type)标识。"
        case .missingReference(let field): "完整备份缺少被引用的数据：\(field)。"
        case .missingAsset(let id): "完整备份缺少照片文件：\(id.uuidString.lowercased())。"
        case .invalidAsset(let id): "完整备份照片摘要不一致：\(id.uuidString.lowercased())。"
        case .sourceFarmStillPresent: "原牧场仍在本机。为避免两份相同业务标识互相覆盖，只能先验证备份；请在新安装或原牧场已安全移除后恢复。"
        case .identifierCollision: "备份中的业务标识已被其他牧场使用，已停止恢复。"
        }
    }
}

@MainActor
enum FarmPortableBackupService {
    static func export(
        farmID: UUID,
        sourceStorageMode: FarmStorageMode,
        sourceAuthorityGeneration: Int,
        sourceWasFullySynchronized: Bool,
        context: ModelContext,
        exportedAt: Date = .now
    ) throws -> Data {
        let legacyData = try FarmLocalBackupService.export(
            farmID: farmID,
            context: context,
            exportedAt: exportedAt
        )
        // Do not hand the user a file that only fails when they need it for
        // recovery. The portable export has to pass the same staging restore
        // used by the import path before the document picker is presented.
        let legacyPreview = try FarmLocalBackupService.preview(data: legacyData)
        let legacyEnvelope = legacyPreview.envelope
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == farmID && $0.deletedAt == nil }) else {
            throw FarmLocalBackupError.farmMismatch
        }
        let supplement = try captureSupplement(
            farm: farm,
            sourceStorageMode: sourceStorageMode,
            sourceAuthorityGeneration: sourceAuthorityGeneration,
            sourceWasFullySynchronized: sourceWasFullySynchronized,
            context: context
        )
        let content = FarmPortableBackupEnvelopeV2.Content(
            legacyEnvelope: legacyEnvelope,
            supplement: supplement
        )
        let envelope = FarmPortableBackupEnvelopeV2(
            schemaVersion: FarmPortableBackupEnvelopeV2.schemaVersion,
            content: content,
            checksum: digest(content)
        )
        let data = try encoder.encode(envelope)
        _ = try preview(data: data)
        return data
    }

    static func preview(data: Data) throws -> FarmPortableBackupPreview {
        if let envelope = try? decoder.decode(
            FarmPortableBackupEnvelopeV2.self,
            from: data
        ) {
            guard envelope.schemaVersion == FarmPortableBackupEnvelopeV2.schemaVersion else {
                throw FarmPortableBackupError.unsupportedVersion
            }
            guard envelope.checksum == digest(envelope.content) else {
                throw FarmPortableBackupError.checksumMismatch
            }
            let legacyData = try encoder.encode(envelope.content.legacyEnvelope)
            let legacyPreview = try FarmLocalBackupService.preview(data: legacyData)
            try validate(
                envelope.content.supplement,
                legacyPayload: legacyPreview.envelope.payload
            )
            try validateInTemporaryStore(
                legacyPreview: legacyPreview,
                supplement: envelope.content.supplement
            )
            return .init(
                legacyPreview: legacyPreview,
                portableEnvelope: envelope
            )
        }

        let legacyPreview = try FarmLocalBackupService.preview(data: data)
        return .init(legacyPreview: legacyPreview, portableEnvelope: nil)
    }

    static func restoreAsNewLocalFarm(
        _ preview: FarmPortableBackupPreview,
        account: AccountProfile,
        context: ModelContext
    ) throws -> FarmPortableBackupRestoreResult {
        let sourceFarmID = preview.legacyPreview.envelope.payload.farm.id
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        guard !farms.contains(where: {
            $0.id == sourceFarmID && $0.deletedAt == nil
        }) else {
            throw FarmPortableBackupError.sourceFarmStillPresent
        }
        if let supplement = preview.portableEnvelope?.content.supplement {
            try validateNoForeignIdentifierCollision(
                supplement,
                context: context
            )
        }

        let restoredFarmID = UUID()
        let sourceFarm = preview.legacyPreview.envelope.payload.farm
        let farm = FarmRecord(
            id: restoredFarmID,
            ownerAccountID: account.effectiveAccountID,
            name: sourceFarm.name,
            role: .owner,
            createdAt: sourceFarm.createdAt,
            updatedAt: sourceFarm.updatedAt
        )
        let profile = FarmStorageProfile(
            farmID: restoredFarmID,
            mode: .localOnly
        )
        context.insert(farm)
        context.insert(profile)

        var createdAssetURLs: [URL] = []
        do {
            let localResult = try FarmLocalBackupService.restore(
                preview.legacyPreview,
                into: farm,
                account: account,
                context: context
            ) { farmID, _, restoreContext in
                guard let supplement = preview.portableEnvelope?.content.supplement else {
                    return
                }
                createdAssetURLs = try insertSupplement(
                    supplement,
                    farm: farm,
                    farmID: farmID,
                    context: restoreContext,
                    writesAssetFiles: true
                )
            }
            return .init(
                farmID: restoredFarmID,
                restoredEntityCount: localResult.restoredCount +
                    (preview.portableEnvelope?.content.supplement.additionalEntityCount ?? 0),
                restoredPhotoCount: preview.photoCount
            )
        } catch {
            context.rollback()
            for url in createdAssetURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private static func captureSupplement(
        farm: FarmRecord,
        sourceStorageMode: FarmStorageMode,
        sourceAuthorityGeneration: Int,
        sourceWasFullySynchronized: Bool,
        context: ModelContext
    ) throws -> FarmPortableBackupSupplementV2 {
        let farmID = farm.id
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var assetFiles: [FarmPortableBackupSupplementV2.AssetFile] = []
        for photo in photos where photo.deletedAt == nil {
            let url = PhotoTransferActor.absoluteURL(for: photo.relativePath)
            guard let data = try? Data(contentsOf: url) else {
                throw FarmPortableBackupError.missingAsset(photo.id)
            }
            let sha256 = CloudPayloadDigest.hex(for: data)
            guard sha256 == photo.sha256.lowercased() else {
                throw FarmPortableBackupError.invalidAsset(photo.id)
            }
            assetFiles.append(.init(
                assetID: photo.id,
                sha256: sha256,
                mimeType: photo.mimeType,
                data: data
            ))
        }
        return .init(
            sourceStorageMode: sourceStorageMode,
            sourceAuthorityGeneration: sourceAuthorityGeneration,
            sourceWasFullySynchronized: sourceWasFullySynchronized,
            appSchemaVersion: AppSchema.currentVersion,
            farmMetadata: .init(
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
            activities: try context.fetch(FetchDescriptor<FarmActivity>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, title: $0.title, detail: $0.detail, occurredAt: $0.occurredAt, createdAt: $0.createdAt)
                },
            weanings: try context.fetch(FetchDescriptor<WeaningRecord>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, sheepID: $0.sheepID, occurredAt: $0.occurredAt, weanWeightText: $0.weanWeightText, birthAt: $0.birthAt, birthWeightText: $0.birthWeightText, averageDailyGainText: $0.averageDailyGainText, damID: $0.damID, legacyDamEarTag: $0.legacyDamEarTag, litterSize: $0.litterSize, note: $0.note, legacySourceKey: $0.legacySourceKey, recordedAt: $0.recordedAt, revision: $0.revision, deletedAt: $0.deletedAt)
                },
            breedingPrograms: try context.fetch(FetchDescriptor<BreedingProgramRecord>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, name: $0.name, createdAt: $0.createdAt, legacySourceKey: $0.legacySourceKey, revision: $0.revision, deletedAt: $0.deletedAt)
                },
            breedingProgramSteps: try context.fetch(FetchDescriptor<BreedingProgramStepRecord>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, programID: $0.programID, dayOffset: $0.dayOffset, action: $0.action, sortOrder: $0.sortOrder, legacySourceKey: $0.legacySourceKey, createdAt: $0.createdAt, revision: $0.revision, deletedAt: $0.deletedAt)
                },
            productionBatches: try context.fetch(FetchDescriptor<ProductionBatchRecord>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, name: $0.name, purpose: $0.purpose, sourceRawValue: $0.sourceRawValue, statusRawValue: $0.statusRawValue, startedAt: $0.startedAt, endedAt: $0.endedAt, note: $0.note, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
                },
            batchMemberships: try context.fetch(FetchDescriptor<BatchMembershipRecord>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, batchID: $0.batchID, sheepID: $0.sheepID, joinedAt: $0.joinedAt, leftAt: $0.leftAt, leaveReason: $0.leaveReason, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
                },
            dailyPenCounts: try context.fetch(FetchDescriptor<DailyPenCountRecord>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, penID: $0.penID, purpose: $0.purpose, date: $0.date, count: $0.count, rebuiltAt: $0.rebuiltAt)
                },
            notes: try context.fetch(FetchDescriptor<NoteRecord>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, sheepID: $0.sheepID, penID: $0.penID, text: $0.text, occurredAt: $0.occurredAt, createdAt: $0.createdAt, deletedAt: $0.deletedAt, revision: $0.revision)
                },
            photos: photos.map {
                .init(id: $0.id, sheepID: $0.sheepID, legacySourceKey: $0.legacySourceKey, originalEarTag: $0.originalEarTag, sha256: $0.sha256, mimeType: $0.mimeType, sourceSHA256: $0.sourceSHA256, sourcePixelWidth: $0.sourcePixelWidth, sourcePixelHeight: $0.sourcePixelHeight, cloudPixelWidth: $0.cloudPixelWidth, cloudPixelHeight: $0.cloudPixelHeight, capturedAt: $0.capturedAt, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            sheepAvatars: try context.fetch(FetchDescriptor<SheepAvatarRecord>())
                .filter { $0.farmID == farmID }.map {
                    .init(id: $0.id, sheepID: $0.sheepID, photoAssetID: $0.photoAssetID, updatedAt: $0.updatedAt)
                },
            assetFiles: assetFiles
        )
    }

    private static func validate(
        _ supplement: FarmPortableBackupSupplementV2,
        legacyPayload: FarmBackupPayloadV1
    ) throws {
        try unique(supplement.activities.map(\.id), "牧场活动")
        try unique(supplement.weanings.map(\.id), "断奶")
        try unique(supplement.breedingPrograms.map(\.id), "配种程序")
        try unique(supplement.breedingProgramSteps.map(\.id), "配种程序步骤")
        try unique(supplement.productionBatches.map(\.id), "生产批次")
        try unique(supplement.batchMemberships.map(\.id), "生产批次成员")
        try unique(supplement.dailyPenCounts.map(\.id), "每日圈舍数量")
        try unique(supplement.notes.map(\.id), "备注")
        try unique(supplement.photos.map(\.id), "照片")
        try unique(supplement.sheepAvatars.map(\.id), "羊只头像")
        try unique(supplement.assetFiles.map(\.assetID), "照片文件")

        let sheepIDs = Set(legacyPayload.sheep.map(\.id))
        let penIDs = Set(legacyPayload.pens.map(\.id))
        let programIDs = Set(supplement.breedingPrograms.map(\.id))
        let batchIDs = Set(supplement.productionBatches.map(\.id))
        let photoIDs = Set(supplement.photos.filter { $0.deletedAt == nil }.map(\.id))
        for item in supplement.weanings {
            guard sheepIDs.contains(item.sheepID) else { throw FarmPortableBackupError.missingReference("weaning.sheepID") }
            if let damID = item.damID, !sheepIDs.contains(damID) { throw FarmPortableBackupError.missingReference("weaning.damID") }
        }
        for item in supplement.breedingProgramSteps where !programIDs.contains(item.programID) { throw FarmPortableBackupError.missingReference("breedingProgramStep.programID") }
        for item in supplement.batchMemberships {
            guard batchIDs.contains(item.batchID), sheepIDs.contains(item.sheepID) else { throw FarmPortableBackupError.missingReference("batchMembership") }
        }
        for item in supplement.dailyPenCounts where !penIDs.contains(item.penID) { throw FarmPortableBackupError.missingReference("dailyPenCount.penID") }
        for item in supplement.notes {
            if let sheepID = item.sheepID, !sheepIDs.contains(sheepID) { throw FarmPortableBackupError.missingReference("note.sheepID") }
            if let penID = item.penID, !penIDs.contains(penID) { throw FarmPortableBackupError.missingReference("note.penID") }
        }
        for item in supplement.photos {
            if let sheepID = item.sheepID, !sheepIDs.contains(sheepID) { throw FarmPortableBackupError.missingReference("photo.sheepID") }
        }
        for item in supplement.sheepAvatars {
            guard sheepIDs.contains(item.sheepID) else { throw FarmPortableBackupError.missingReference("sheepAvatar.sheepID") }
            if let photoID = item.photoAssetID, !photoIDs.contains(photoID) { throw FarmPortableBackupError.missingReference("sheepAvatar.photoAssetID") }
        }
        let assetsByID = Dictionary(uniqueKeysWithValues: supplement.assetFiles.map { ($0.assetID, $0) })
        for photo in supplement.photos where photo.deletedAt == nil {
            guard let asset = assetsByID[photo.id] else { throw FarmPortableBackupError.missingAsset(photo.id) }
            guard asset.sha256 == photo.sha256.lowercased(),
                  asset.sha256 == CloudPayloadDigest.hex(for: asset.data),
                  asset.mimeType == photo.mimeType else {
                throw FarmPortableBackupError.invalidAsset(photo.id)
            }
        }
    }

    private static func validateInTemporaryStore(
        legacyPreview: FarmBackupPreview,
        supplement: FarmPortableBackupSupplementV2
    ) throws {
        let container = try AppSchema.makeContainer(
            name: "PortableBackupValidation-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(
            appleUserIdentifier: "portable-backup-validation-\(UUID().uuidString)",
            displayName: "备份校验"
        )
        let farm = FarmRecord(
            ownerAccountID: account.effectiveAccountID,
            name: legacyPreview.envelope.payload.farm.name
        )
        context.insert(account)
        context.insert(farm)
        context.insert(FarmStorageProfile(farmID: farm.id, mode: .localOnly))
        _ = try FarmLocalBackupService.restore(
            legacyPreview,
            into: farm,
            account: account,
            context: context
        ) { farmID, _, restoreContext in
            _ = try insertSupplement(
                supplement,
                farm: farm,
                farmID: farmID,
                context: restoreContext,
                writesAssetFiles: false
            )
        }
    }

    private static func insertSupplement(
        _ supplement: FarmPortableBackupSupplementV2,
        farm: FarmRecord,
        farmID: UUID,
        context: ModelContext,
        writesAssetFiles: Bool
    ) throws -> [URL] {
        let metadata = supplement.farmMetadata
        farm.locationDisplayName = metadata.locationDisplayName
        farm.latitude = metadata.latitude
        farm.longitude = metadata.longitude
        farm.coordinateReferenceSystem = metadata.coordinateReferenceSystem
        farm.addressSnapshot = metadata.addressSnapshot
        farm.timeZoneIdentifier = metadata.timeZoneIdentifier
        farm.locationSourceRawValue = metadata.locationSourceRawValue
        farm.horizontalAccuracyMeters = metadata.horizontalAccuracyMeters
        farm.locationUpdatedAt = metadata.locationUpdatedAt
        for value in supplement.activities {
            context.insert(FarmActivity(id: value.id, farmID: farmID, title: value.title, detail: value.detail, occurredAt: value.occurredAt, createdAt: value.createdAt))
        }
        for value in supplement.weanings {
            let record = WeaningRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, occurredAt: value.occurredAt, weanWeightText: value.weanWeightText, birthAt: value.birthAt, birthWeightText: value.birthWeightText, averageDailyGainText: value.averageDailyGainText, damID: value.damID, legacyDamEarTag: value.legacyDamEarTag, litterSize: value.litterSize, note: value.note, legacySourceKey: value.legacySourceKey)
            record.recordedAt = value.recordedAt; record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in supplement.breedingPrograms {
            let record = BreedingProgramRecord(id: value.id, farmID: farmID, name: value.name, createdAt: value.createdAt, legacySourceKey: value.legacySourceKey)
            record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in supplement.breedingProgramSteps {
            let record = BreedingProgramStepRecord(id: value.id, farmID: farmID, programID: value.programID, dayOffset: value.dayOffset, action: value.action, sortOrder: value.sortOrder, legacySourceKey: value.legacySourceKey, createdAt: value.createdAt)
            record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in supplement.productionBatches {
            let record = ProductionBatchRecord(id: value.id, farmID: farmID, name: value.name, purpose: value.purpose, source: ProductionBatchSource(rawValue: value.sourceRawValue) ?? .manual, startedAt: value.startedAt, note: value.note)
            record.statusRawValue = value.statusRawValue; record.endedAt = value.endedAt; record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in supplement.batchMemberships {
            let record = BatchMembershipRecord(id: value.id, farmID: farmID, batchID: value.batchID, sheepID: value.sheepID, joinedAt: value.joinedAt)
            record.leftAt = value.leftAt; record.leaveReason = value.leaveReason; record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in supplement.dailyPenCounts { context.insert(DailyPenCountRecord(id: value.id, farmID: farmID, penID: value.penID, purpose: value.purpose, date: value.date, count: value.count, rebuiltAt: value.rebuiltAt)) }
        for value in supplement.notes {
            let record = NoteRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, penID: value.penID, text: value.text, occurredAt: value.occurredAt)
            record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; record.revision = value.revision; context.insert(record)
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: supplement.assetFiles.map { ($0.assetID, $0) })
        var createdAssetURLs: [URL] = []
        for value in supplement.photos {
            let relativePath: String
            if writesAssetFiles, value.deletedAt == nil {
                guard let asset = assetsByID[value.id] else { throw FarmPortableBackupError.missingAsset(value.id) }
                let fileExtension = value.mimeType == "image/heic" ? "heic" : "jpg"
                let destination = try PhotoTransferActor.assetURL(farmID: farmID, assetID: value.id, fileExtension: fileExtension)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw FarmPortableBackupError.identifierCollision }
                try asset.data.write(to: destination, options: [.atomic, .completeFileProtection])
                createdAssetURLs.append(destination)
                relativePath = PhotoTransferActor.relativePath(for: destination)
            } else {
                relativePath = ""
            }
            let record = PhotoAssetRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, legacySourceKey: value.legacySourceKey, originalEarTag: value.originalEarTag, relativePath: relativePath, sha256: value.sha256, mimeType: value.mimeType)
            record.sourceSHA256 = value.sourceSHA256; record.sourcePixelWidth = value.sourcePixelWidth; record.sourcePixelHeight = value.sourcePixelHeight; record.cloudPixelWidth = value.cloudPixelWidth; record.cloudPixelHeight = value.cloudPixelHeight; record.capturedAt = value.capturedAt; record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in supplement.sheepAvatars { context.insert(SheepAvatarRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, photoAssetID: value.photoAssetID, updatedAt: value.updatedAt)) }
        return createdAssetURLs
    }

    private static func validateNoForeignIdentifierCollision(
        _ supplement: FarmPortableBackupSupplementV2,
        context: ModelContext
    ) throws {
        let ids = Set(
            supplement.activities.map(\.id) + supplement.weanings.map(\.id) +
            supplement.breedingPrograms.map(\.id) + supplement.breedingProgramSteps.map(\.id) +
            supplement.productionBatches.map(\.id) + supplement.batchMemberships.map(\.id) +
            supplement.dailyPenCounts.map(\.id) + supplement.notes.map(\.id) +
            supplement.photos.map(\.id) + supplement.sheepAvatars.map(\.id)
        )
        let collision = try context.fetch(FetchDescriptor<FarmActivity>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<WeaningRecord>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<BreedingProgramRecord>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<ProductionBatchRecord>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<BatchMembershipRecord>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<DailyPenCountRecord>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<NoteRecord>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<PhotoAssetRecord>()).contains { ids.contains($0.id) }
            || context.fetch(FetchDescriptor<SheepAvatarRecord>()).contains { ids.contains($0.id) }
        guard !collision else { throw FarmPortableBackupError.identifierCollision }
    }

    private static func unique(_ values: [UUID], _ type: String) throws {
        guard Set(values).count == values.count else {
            throw FarmPortableBackupError.duplicateIdentifier(type)
        }
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "" }
        return CloudPayloadDigest.hex(for: data)
    }

    private static var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }

    private static var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
