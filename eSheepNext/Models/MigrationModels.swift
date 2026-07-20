import Foundation
import SwiftData

enum MigrationCommitStatus: String, Codable, Sendable {
    case completed
}

enum MigrationCloudState: String, Codable, Sendable, CaseIterable {
    case localCommitted
    case baselineReady
    case provisioning
    case uploading
    case verifying
    case synced
    case failed

    var displayName: String {
        switch self {
        case .localCommitted: "已保存在本机"
        case .baselineReady: "等待联网上传"
        case .provisioning: "正在建立 iCloud 牧场"
        case .uploading: "正在上传迁移数据"
        case .verifying: "正在核对云端数据"
        case .synced: "iCloud 已完成"
        case .failed: "云端准备失败"
        }
    }
}

@Model
final class MigrationCommitRecord {
    var id: UUID
    var sessionID: UUID
    var sourceChecksum: String
    var farmID: UUID
    var ownerAccountID: UUID
    var statusRawValue: String
    var recordCountsJSON: String
    var assetsRelativeDirectory: String
    var committedAt: Date
    var cloudStateRawValue: String = MigrationCloudState.localCommitted.rawValue
    var baselineDigest: String = ""
    var baselineEntityCount: Int = 0
    var baselinePhotoCount: Int = 0
    var cloudRetryCount: Int = 0
    var cloudLastError: String?
    var cloudUpgradedAt: Date?
    var cloudSyncedAt: Date?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        sourceChecksum: String,
        farmID: UUID,
        ownerAccountID: UUID,
        recordCountsJSON: String,
        assetsRelativeDirectory: String,
        committedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceChecksum = sourceChecksum
        self.farmID = farmID
        self.ownerAccountID = ownerAccountID
        self.statusRawValue = MigrationCommitStatus.completed.rawValue
        self.recordCountsJSON = recordCountsJSON
        self.assetsRelativeDirectory = assetsRelativeDirectory
        self.committedAt = committedAt
    }

    var status: MigrationCommitStatus {
        MigrationCommitStatus(rawValue: statusRawValue) ?? .completed
    }

    var cloudState: MigrationCloudState {
        get { MigrationCloudState(rawValue: cloudStateRawValue) ?? .localCommitted }
        set { cloudStateRawValue = newValue.rawValue }
    }
}

@Model
final class MigrationAuditRecord {
    var id: UUID
    var sessionID: UUID
    var sourceKey: String
    var entityType: String
    var targetEntityIDsJSON: String
    var rawPayloadJSON: String
    var resolution: String
    var exclusionReason: String?
    var createdAt: Date

    init(id: UUID = UUID(), sessionID: UUID, sourceKey: String, entityType: String, targetEntityIDsJSON: String = "[]", rawPayloadJSON: String, resolution: String = "converted", exclusionReason: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.sourceKey = sourceKey; self.entityType = entityType
        self.targetEntityIDsJSON = targetEntityIDsJSON; self.rawPayloadJSON = rawPayloadJSON; self.resolution = resolution
        self.exclusionReason = exclusionReason; self.createdAt = .now
    }
}

@Model
final class PhotoAssetRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID?
    var legacySourceKey: String
    var originalEarTag: String
    var relativePath: String
    var sha256: String
    var mimeType: String
    var sourceSHA256: String = ""
    var sourcePixelWidth: Int = 0
    var sourcePixelHeight: Int = 0
    var cloudPixelWidth: Int = 0
    var cloudPixelHeight: Int = 0
    var capturedAt: Date?
    var cloudRecordName: String?
    var recoveryRecordName: String?
    var isCloudAuthoritative: Bool = false
    var recoveryBackedUpAt: Date?
    var createdAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), farmID: UUID, sheepID: UUID?, legacySourceKey: String, originalEarTag: String, relativePath: String, sha256: String, mimeType: String = "image/jpeg") {
        self.id = id; self.farmID = farmID; self.sheepID = sheepID; self.legacySourceKey = legacySourceKey
        self.originalEarTag = originalEarTag; self.relativePath = relativePath; self.sha256 = sha256; self.mimeType = mimeType
        self.createdAt = .now
    }
}

@Model
final class HealthSubjectLink {
    var id: UUID
    var farmID: UUID
    var healthRecordID: UUID
    var sheepID: UUID
    var createdAt: Date

    init(id: UUID = UUID(), farmID: UUID, healthRecordID: UUID, sheepID: UUID) {
        self.id = id; self.farmID = farmID; self.healthRecordID = healthRecordID; self.sheepID = sheepID; self.createdAt = .now
    }
}

@Model
final class LambingOffspringRecord {
    var id: UUID
    var farmID: UUID
    var lambingRecordID: UUID
    var sheepID: UUID?
    var legacyEarTag: String
    var sexRawValue: String
    var birthWeightText: String
    var isStillborn: Bool = false
    var autoCreatedSheep: Bool = false
    var autoBirthWeightRecordID: UUID? = nil
    var autoPedigreeRevokedByLambing: Bool = false
    var autoBirthWeightRevokedByLambing: Bool = false
    /// 只标记由“撤销产羔”临时隐藏的子项；产羔修正删除的子项不得在恢复时复活。
    var deletedByLambingRevocation: Bool = false
    var revision: Int = 1
    var createdAt: Date
    var updatedAt: Date = Date.now
    var deletedAt: Date? = nil

    init(id: UUID = UUID(), farmID: UUID, lambingRecordID: UUID, sheepID: UUID?, legacyEarTag: String, sexRawValue: String, birthWeightText: String, isStillborn: Bool = false, autoCreatedSheep: Bool = false, autoBirthWeightRecordID: UUID? = nil) {
        self.id = id; self.farmID = farmID; self.lambingRecordID = lambingRecordID; self.sheepID = sheepID
        self.legacyEarTag = legacyEarTag; self.sexRawValue = sexRawValue; self.birthWeightText = birthWeightText; self.isStillborn = isStillborn
        self.autoCreatedSheep = autoCreatedSheep; self.autoBirthWeightRecordID = autoBirthWeightRecordID; self.createdAt = .now; self.updatedAt = self.createdAt
    }
}

@Model
final class FeedIngredientBatchRecord {
    var id: UUID
    var farmID: UUID
    var ingredientID: UUID
    var legacySourceKey: String
    var batchName: String
    var purchaseDate: Date?
    var supplier: String
    var storageLocation: String
    var pricePerKilogramText: String
    var initialKilogramsText: String?
    var remainingKilogramsText: String?
    var note: String
    var isActive: Bool
    var createdAt: Date

    init(id: UUID = UUID(), farmID: UUID, ingredientID: UUID, legacySourceKey: String, batchName: String, purchaseDate: Date?, supplier: String, storageLocation: String, pricePerKilogramText: String, initialKilogramsText: String?, remainingKilogramsText: String?, note: String, isActive: Bool) {
        self.id = id; self.farmID = farmID; self.ingredientID = ingredientID; self.legacySourceKey = legacySourceKey
        self.batchName = batchName; self.purchaseDate = purchaseDate; self.supplier = supplier; self.storageLocation = storageLocation
        self.pricePerKilogramText = pricePerKilogramText; self.initialKilogramsText = initialKilogramsText; self.remainingKilogramsText = remainingKilogramsText
        self.note = note; self.isActive = isActive; self.createdAt = .now
    }
}

@Model
final class HealthCatalogItemRecord {
    var id: UUID
    var farmID: UUID
    var legacySourceKey: String
    var legacyCatalogID: String
    var kindRawValue: String
    var name: String
    var category: String
    var unit: String
    var defaultDoseText: String?
    var defaultRoute: String
    var reminderIntervalDays: Int? = nil
    var note: String
    var isActive: Bool
    var createdAt: Date

    init(id: UUID = UUID(), farmID: UUID, legacySourceKey: String, legacyCatalogID: String, kindRawValue: String, name: String, category: String, unit: String, defaultDoseText: String?, defaultRoute: String, reminderIntervalDays: Int? = nil, note: String, isActive: Bool) {
        self.id = id; self.farmID = farmID; self.legacySourceKey = legacySourceKey; self.legacyCatalogID = legacyCatalogID
        self.kindRawValue = kindRawValue; self.name = name; self.category = category; self.unit = unit; self.defaultDoseText = defaultDoseText
        self.defaultRoute = defaultRoute; self.reminderIntervalDays = reminderIntervalDays; self.note = note; self.isActive = isActive; self.createdAt = .now
    }
}
