import Foundation
import SwiftData

enum AppSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    /// Keep the exact pre-insights operation shape here. Referencing the live
    /// `DomainOperation` type would silently change the V1 schema whenever V2
    /// gains another property and existing V1 stores could no longer be
    /// recognized for migration.
    @Model
    final class DomainOperation {
        var id: UUID
        var farmID: UUID
        var accountID: UUID
        var kindRawValue: String
        var occurredAt: Date
        var createdAt: Date
        var summary: String
        var schemaVersion: Int = 1
        var entityType: String = "FarmRoot"
        var entityID: UUID?
        var baseRevision: Int = 0
        var resultingRevision: Int = 1
        var payload: Data = Data("{}".utf8)
        var payloadDigest: String = ""
        var modifiedByDeviceID: UUID?
        var capabilityCertificate: String = ""
        var operationSignature: Data?

        init(
            id: UUID = UUID(),
            farmID: UUID,
            accountID: UUID,
            kindRawValue: String,
            occurredAt: Date = .now,
            summary: String
        ) {
            self.id = id
            self.farmID = farmID
            self.accountID = accountID
            self.kindRawValue = kindRawValue
            self.occurredAt = occurredAt
            self.createdAt = .now
            self.summary = summary
        }
    }

    @Model
    final class OutboxItem {
        var id: UUID
        var farmID: UUID
        var accountID: UUID
        var operationID: UUID
        var createdAt: Date
        var lastAttemptAt: Date?
        var attemptCount: Int
        var statusRawValue: String
        var errorMessage: String?
        var entityType: String = "FarmRoot"
        var entityID: UUID?
        var baseRevision: Int = 0
        var payloadDigest: String = ""
        var operationSignature: Data?
        var capabilityCertificate: String = ""
        var nextRetryAt: Date?
        var cloudRecordName: String?

        init(
            id: UUID = UUID(),
            farmID: UUID,
            accountID: UUID,
            operationID: UUID
        ) {
            self.id = id
            self.farmID = farmID
            self.accountID = accountID
            self.operationID = operationID
            self.createdAt = .now
            self.attemptCount = 0
            self.statusRawValue = OutboxStatus.pending.rawValue
        }
    }

    static var models: [any PersistentModel.Type] {
        AppSchema.preV3BusinessModelTypesWithoutDomainOperation + [DomainOperation.self, OutboxItem.self]
    }
}

enum AppSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    /// Freeze the V2 Outbox shape before V3 adds provider routing metadata.
    @Model
    final class OutboxItem {
        var id: UUID
        var farmID: UUID
        var accountID: UUID
        var operationID: UUID
        var createdAt: Date
        var lastAttemptAt: Date?
        var attemptCount: Int
        var statusRawValue: String
        var errorMessage: String?
        var entityType: String = "FarmRoot"
        var entityID: UUID?
        var baseRevision: Int = 0
        var payloadDigest: String = ""
        var operationSignature: Data?
        var capabilityCertificate: String = ""
        var nextRetryAt: Date?
        var cloudRecordName: String?

        init(
            id: UUID = UUID(),
            farmID: UUID,
            accountID: UUID,
            operationID: UUID
        ) {
            self.id = id
            self.farmID = farmID
            self.accountID = accountID
            self.operationID = operationID
            self.createdAt = .now
            self.attemptCount = 0
            self.statusRawValue = OutboxStatus.pending.rawValue
        }
    }

    static var models: [any PersistentModel.Type] {
        AppSchema.preV3BusinessModelTypes + [OutboxItem.self] + AppSchema.insightModelTypes
    }
}

enum AppSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV4ModelTypes }
}

enum AppSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV5ModelTypes }
}

enum AppSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV6ModelTypes }
}

enum AppSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV7ModelTypes }
}

enum AppSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV8ModelTypes }

    // Freeze the feed domain exactly as it existed before the rebuild.  These
    // are schema-only types; runtime code continues to use the V8 models
    // below.  Keeping the old shape here is what makes V7 -> V8 a real
    // additive migration instead of silently redefining the old store.
    @Model
    final class FeedIngredientRecord {
        var id: UUID
        var farmID: UUID
        var name: String
        var category: String
        var legacySourceKey: String?
        var nutrientSnapshotJSON: String
        var unit: String
        var dryMatterText: String?
        var isActive: Bool
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init(id: UUID = UUID(), farmID: UUID, name: String, unit: String = "千克", dryMatterText: String? = nil, category: String = "", legacySourceKey: String? = nil, nutrientSnapshotJSON: String = "{}") {
            self.id = id; self.farmID = farmID; self.name = name; self.category = category
            self.legacySourceKey = legacySourceKey; self.nutrientSnapshotJSON = nutrientSnapshotJSON
            self.unit = unit; self.dryMatterText = dryMatterText; self.isActive = true
            self.createdAt = .now; self.updatedAt = .now; self.deletedAt = nil
        }
    }

    @Model
    final class FeedRecipeRecord {
        var id: UUID
        var farmID: UUID
        var name: String
        var targetPenName: String?
        var stageRawValue: String
        var headCount: Int?
        var legacySourceKey: String?
        var note: String
        var isActive: Bool
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init(id: UUID = UUID(), farmID: UUID, name: String, note: String = "", targetPenName: String? = nil, stageRawValue: String = "", headCount: Int? = nil, legacySourceKey: String? = nil) {
            self.id = id; self.farmID = farmID; self.name = name; self.targetPenName = targetPenName
            self.stageRawValue = stageRawValue; self.headCount = headCount; self.legacySourceKey = legacySourceKey
            self.note = note; self.isActive = true; self.createdAt = .now; self.updatedAt = .now; self.deletedAt = nil
        }
    }

    @Model
    final class FeedRecipeComponentRecord {
        var id: UUID
        var farmID: UUID
        var recipeID: UUID
        var ingredientID: UUID
        var kilogramsText: String
        var legacyBatchID: String?
        var pricePerKilogramText: String?
        var nutrientSnapshotJSON: String
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        init(id: UUID = UUID(), farmID: UUID, recipeID: UUID, ingredientID: UUID, kilogramsText: String, legacyBatchID: String? = nil, pricePerKilogramText: String? = nil, nutrientSnapshotJSON: String = "{}") {
            self.id = id; self.farmID = farmID; self.recipeID = recipeID; self.ingredientID = ingredientID
            self.kilogramsText = kilogramsText; self.legacyBatchID = legacyBatchID
            self.pricePerKilogramText = pricePerKilogramText; self.nutrientSnapshotJSON = nutrientSnapshotJSON
            self.createdAt = .now; self.updatedAt = .now; self.deletedAt = nil
        }
    }

    @Model
    final class FeedRecord {
        var id: UUID
        var farmID: UUID
        var penID: UUID
        var recipeID: UUID?
        var modeRawValue: String
        var occurredAt: Date
        var recordedAt: Date
        var note: String
        var mealName: String
        var feederName: String
        var remainingKilogramsText: String?
        var discardedKilogramsText: String?
        var legacySourceKey: String?
        var revision: Int
        var deletedAt: Date?

        init(id: UUID = UUID(), farmID: UUID, penID: UUID, recipeID: UUID? = nil, mode: FeedMode, occurredAt: Date, note: String = "", mealName: String = "", feederName: String = "", remainingKilogramsText: String? = nil, discardedKilogramsText: String? = nil, legacySourceKey: String? = nil) {
            self.id = id; self.farmID = farmID; self.penID = penID; self.recipeID = recipeID
            self.modeRawValue = mode.rawValue; self.occurredAt = occurredAt; self.recordedAt = .now
            self.note = note; self.mealName = mealName; self.feederName = feederName
            self.remainingKilogramsText = remainingKilogramsText; self.discardedKilogramsText = discardedKilogramsText
            self.legacySourceKey = legacySourceKey; self.revision = 1; self.deletedAt = nil
        }
    }

    @Model
    final class FeedRecordLine {
        var id: UUID
        var farmID: UUID
        var feedRecordID: UUID
        var ingredientID: UUID
        var kilogramsText: String
        var ingredientNameSnapshot: String
        var ingredientBatchID: UUID?
        var ingredientBatchNameSnapshot: String?
        var pricePerKilogramTextSnapshot: String?
        var nutrientSnapshotJSON: String?
        var unitSnapshot: String?
        var dryMatterTextSnapshot: String?
        var createdAt: Date
        var deletedAt: Date?

        init(id: UUID = UUID(), farmID: UUID, feedRecordID: UUID, ingredientID: UUID, kilogramsText: String, ingredientNameSnapshot: String, ingredientBatchID: UUID? = nil, ingredientBatchNameSnapshot: String? = nil, pricePerKilogramTextSnapshot: String? = nil, nutrientSnapshotJSON: String? = nil, unitSnapshot: String? = nil, dryMatterTextSnapshot: String? = nil) {
            self.id = id; self.farmID = farmID; self.feedRecordID = feedRecordID; self.ingredientID = ingredientID
            self.kilogramsText = kilogramsText; self.ingredientNameSnapshot = ingredientNameSnapshot
            self.ingredientBatchID = ingredientBatchID; self.ingredientBatchNameSnapshot = ingredientBatchNameSnapshot
            self.pricePerKilogramTextSnapshot = pricePerKilogramTextSnapshot; self.nutrientSnapshotJSON = nutrientSnapshotJSON
            self.unitSnapshot = unitSnapshot; self.dryMatterTextSnapshot = dryMatterTextSnapshot
            self.createdAt = .now; self.deletedAt = nil
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

        init(id: UUID = UUID(), farmID: UUID, ingredientID: UUID, legacySourceKey: String = "", batchName: String, purchaseDate: Date? = nil, supplier: String = "", storageLocation: String = "", pricePerKilogramText: String = "0", initialKilogramsText: String? = nil, remainingKilogramsText: String? = nil, note: String = "", isActive: Bool = true) {
            self.id = id; self.farmID = farmID; self.ingredientID = ingredientID; self.legacySourceKey = legacySourceKey
            self.batchName = batchName; self.purchaseDate = purchaseDate; self.supplier = supplier; self.storageLocation = storageLocation
            self.pricePerKilogramText = pricePerKilogramText; self.initialKilogramsText = initialKilogramsText; self.remainingKilogramsText = remainingKilogramsText
            self.note = note; self.isActive = isActive; self.createdAt = .now
        }
    }
}

enum AppSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV9ModelTypes }

    /// Freeze the V8 care-rule shape before V9 adds operational-alert fields.
    /// Existing V8 stores must be recognized without treating the live V9
    /// model as if it had already shipped.
    @Model
    final class FarmCareRuleRecord {
        var id: UUID
        var farmID: UUID
        var pregnancyCheckDays: Int
        var gestationDays: Int
        var createdAt: Date
        var updatedAt: Date
        var revision: Int

        init(
            id: UUID = UUID(),
            farmID: UUID,
            pregnancyCheckDays: Int = 45,
            gestationDays: Int = 150
        ) {
            self.id = id
            self.farmID = farmID
            self.pregnancyCheckDays = pregnancyCheckDays
            self.gestationDays = gestationDays
            self.createdAt = .now
            self.updatedAt = .now
            self.revision = 1
        }
    }
}

/// Freeze the first V9 shape that has already been installed on development
/// devices. V9.1 adds only the configurable early-warning lead time.
enum AppSchemaV9_0: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV9_1ModelTypes }

    @Model
    final class FarmCareRuleRecord {
        var id: UUID
        var farmID: UUID
        var pregnancyCheckDays: Int
        var gestationDays: Int
        var weaningAgeDays: Int?
        var operationalAlertsConfiguredAt: Date?
        var alertDigestEnabled: Bool = false
        var alertDigestMinuteOfDay: Int = 480
        var createdAt: Date
        var updatedAt: Date
        var revision: Int

        init(
            id: UUID = UUID(),
            farmID: UUID,
            pregnancyCheckDays: Int = 45,
            gestationDays: Int = 150,
            weaningAgeDays: Int? = nil,
            operationalAlertsConfiguredAt: Date? = nil,
            alertDigestEnabled: Bool = false,
            alertDigestMinuteOfDay: Int = 480
        ) {
            self.id = id
            self.farmID = farmID
            self.pregnancyCheckDays = pregnancyCheckDays
            self.gestationDays = gestationDays
            self.weaningAgeDays = weaningAgeDays
            self.operationalAlertsConfiguredAt = operationalAlertsConfiguredAt
            self.alertDigestEnabled = alertDigestEnabled
            self.alertDigestMinuteOfDay = alertDigestMinuteOfDay
            self.createdAt = .now
            self.updatedAt = .now
            self.revision = 1
        }
    }
}

enum AppSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 1, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV10ModelTypes }

    /// Freeze the V9 feed shape. V10 persists explicit excluded sheep UUIDs;
    /// keeping this schema-only type prevents an installed V9 store from
    /// being silently reinterpreted as if that field had always existed.
    @Model
    final class FeedRecord {
        var id: UUID
        var farmID: UUID
        var penID: UUID
        var recipeID: UUID?
        var modeRawValue: String
        var occurredAt: Date
        var recordedAt: Date
        var note: String
        var mealName: String
        var feederName: String
        var remainingKilogramsText: String?
        var discardedKilogramsText: String?
        var recipeHeadCountSnapshot: Int?
        var actualHeadCountSnapshot: Int?
        var scaleFactorText: String?
        var remainingCompositionJSON: String?
        var legacySourceKey: String?
        var revision: Int
        var deletedAt: Date?

        init(
            id: UUID = UUID(),
            farmID: UUID,
            penID: UUID,
            recipeID: UUID? = nil,
            mode: FeedMode,
            occurredAt: Date,
            note: String = "",
            mealName: String = "",
            feederName: String = "",
            remainingKilogramsText: String? = nil,
            discardedKilogramsText: String? = nil,
            recipeHeadCountSnapshot: Int? = nil,
            actualHeadCountSnapshot: Int? = nil,
            scaleFactorText: String? = nil,
            remainingCompositionJSON: String? = nil,
            legacySourceKey: String? = nil
        ) {
            self.id = id
            self.farmID = farmID
            self.penID = penID
            self.recipeID = recipeID
            self.modeRawValue = mode.rawValue
            self.occurredAt = occurredAt
            self.recordedAt = .now
            self.note = note
            self.mealName = mealName
            self.feederName = feederName
            self.remainingKilogramsText = remainingKilogramsText
            self.discardedKilogramsText = discardedKilogramsText
            self.recipeHeadCountSnapshot = recipeHeadCountSnapshot
            self.actualHeadCountSnapshot = actualHeadCountSnapshot
            self.scaleFactorText = scaleFactorText
            self.remainingCompositionJSON = remainingCompositionJSON
            self.legacySourceKey = legacySourceKey
            self.revision = 1
            self.deletedAt = nil
        }
    }
}

enum AppSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.preV11ModelTypes }
}

enum AppSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.modelTypes }
}

enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            AppSchemaV1.self,
            AppSchemaV2.self,
            AppSchemaV3.self,
            AppSchemaV4.self,
            AppSchemaV5.self,
            AppSchemaV6.self,
            AppSchemaV7.self,
            AppSchemaV8.self,
            AppSchemaV9_0.self,
            AppSchemaV9.self,
            AppSchemaV10.self,
            AppSchemaV11.self,
        ]
    }

    // V1 freezes the schema that shipped before formal versioning was
    // introduced. Future schema versions must add an explicit lightweight or
    // custom stage here; opening a store must never trigger business commands.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self),
            .custom(
                fromVersion: AppSchemaV2.self,
                toVersion: AppSchemaV3.self,
                willMigrate: nil,
                didMigrate: { context in
                    let farms = try context.fetch(FetchDescriptor<FarmRecord>())
                    let cloudKitBindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
                    let existingProfiles = try context.fetch(FetchDescriptor<FarmStorageProfile>())
                    let profiledFarmIDs = Set(existingProfiles.map(\.farmID))
                    let iCloudFarmIDs = Set(cloudKitBindings.map(\.farmID))

                    for farm in farms where !profiledFarmIDs.contains(farm.id) {
                        context.insert(FarmStorageProfile(
                            farmID: farm.id,
                            mode: iCloudFarmIDs.contains(farm.id) ? .iCloud : .localOnly
                        ))
                    }

                    for item in try context.fetch(FetchDescriptor<OutboxItem>()) {
                        if iCloudFarmIDs.contains(item.farmID) {
                            item.deliveryProviderRawValue = FarmRemoteProvider.iCloud.rawValue
                        } else {
                            item.deliveryProviderRawValue = nil
                            item.statusRawValue = OutboxStatus.notRequiredLocalOnly.rawValue
                        }
                        item.authorityGeneration = 0
                        item.remoteReceiptData = nil
                    }
                    try context.save()
                }
            ),
            .custom(
                fromVersion: AppSchemaV3.self,
                toVersion: AppSchemaV4.self,
                willMigrate: nil,
                didMigrate: { context in
                    let farms = try context.fetch(FetchDescriptor<FarmRecord>())

                    let operations = try context.fetch(FetchDescriptor<DomainOperation>())
                    let operationsByFarm = Dictionary(grouping: operations, by: \.farmID)
                    let existingRecords = try context.fetch(
                        FetchDescriptor<FarmOperationSequenceRecord>()
                    )
                    let recordedOperationIDs = Set(existingRecords.map(\.operationID))
                    let existingCounters = try context.fetch(
                        FetchDescriptor<FarmOperationSequenceCounter>()
                    )
                    for farm in farms {
                        let ordered = (operationsByFarm[farm.id] ?? []).sorted {
                            if $0.createdAt != $1.createdAt {
                                return $0.createdAt < $1.createdAt
                            }
                            return $0.id.uuidString < $1.id.uuidString
                        }
                        for (offset, operation) in ordered.enumerated() {
                            if !recordedOperationIDs.contains(operation.id) {
                                context.insert(FarmOperationSequenceRecord(
                                    farmID: farm.id,
                                    operationID: operation.id,
                                    clientSequence: Int64(offset + 1)
                                ))
                            }
                        }
                        if !existingCounters.contains(where: { $0.farmID == farm.id }) {
                            context.insert(FarmOperationSequenceCounter(
                                farmID: farm.id,
                                nextSequence: Int64(ordered.count + 1)
                            ))
                        }
                    }
                    try context.save()
                }
            ),
            .lightweight(fromVersion: AppSchemaV4.self, toVersion: AppSchemaV5.self),
            .lightweight(fromVersion: AppSchemaV5.self, toVersion: AppSchemaV6.self),
            .lightweight(fromVersion: AppSchemaV6.self, toVersion: AppSchemaV7.self),
            .lightweight(fromVersion: AppSchemaV7.self, toVersion: AppSchemaV8.self),
            .lightweight(fromVersion: AppSchemaV8.self, toVersion: AppSchemaV9_0.self),
            .lightweight(fromVersion: AppSchemaV9_0.self, toVersion: AppSchemaV9.self),
            .lightweight(fromVersion: AppSchemaV9.self, toVersion: AppSchemaV10.self),
            .custom(
                fromVersion: AppSchemaV10.self,
                toVersion: AppSchemaV11.self,
                willMigrate: nil,
                didMigrate: { context in
                    let recipes = try context.fetch(FetchDescriptor<FeedRecipeRecord>())
                    let existingRecipeIDs = Set(
                        try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>()).map(\.recipeID)
                    )
                    for recipe in recipes where !existingRecipeIDs.contains(recipe.id) {
                        let referenceHeadCount = recipe.headCount.flatMap { $0 > 0 ? $0 : nil }
                        let profile = TMRFormulaProfileRecord(
                            id: recipe.id,
                            farmID: recipe.farmID,
                            recipeID: recipe.id,
                            quantityBasis: .wholeGroupDaily,
                            referenceHeadCount: referenceHeadCount,
                            defaultScaleMode: .scaledByHeadCount,
                            formulaRevision: 1,
                            needsReview: referenceHeadCount == nil,
                            createdAt: recipe.createdAt
                        )
                        profile.updatedAt = recipe.updatedAt
                        profile.deletedAt = recipe.deletedAt
                        context.insert(profile)
                    }
                    // A TMR formula identifies ingredient varieties only. Older
                    // feed recipes could pin a stock lot; preserve that identifier
                    // as legacy context, then release the live dependency so the
                    // operator chooses real lots while producing each batch.
                    for component in try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()) {
                        guard let ingredientBatchID = component.ingredientBatchID else { continue }
                        if component.legacyBatchID?.isEmpty != false {
                            component.legacyBatchID = ingredientBatchID.uuidString.lowercased()
                        }
                        component.ingredientBatchID = nil
                    }
                    try context.save()
                }
            ),
        ]
    }
}

enum AppSchema {
    static let currentVersion = "11.0.0"

    static func defaultStoreURL(name: String = "eSheepNext") -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "\(name).store")
    }

    static var businessModelTypes: [any PersistentModel.Type] {
        [
            AccountProfile.self,
            FarmRecord.self,
            FarmActivity.self,
            PenRecord.self,
            SheepRecord.self,
            WeightRecord.self,
            WeaningRecord.self,
            BreedingProgramRecord.self,
            BreedingProgramStepRecord.self,
            TransferRecord.self,
            RemovalRecord.self,
            ProductionBatchRecord.self,
            BatchMembershipRecord.self,
            DailyPenCountRecord.self,
            FeedIngredientRecord.self,
            FeedRecipeRecord.self,
            FeedRecipeComponentRecord.self,
            FeedRecord.self,
            FeedRecordLine.self,
            FeedTroughObservationRecord.self,
            FeedStockTransactionRecord.self,
            FeedStockCountRecord.self,
            InventoryLotRecord.self,
            InventoryTransactionRecord.self,
            HealthRecord.self,
            ReproductionRecord.self,
            SemenRecord.self,
            SemenDonorRecord.self,
            PedigreeChangeRecord.self,
            NoteRecord.self,
            DomainOperation.self,
            OutboxItem.self,
            TombstoneRecord.self,
            MigrationCommitRecord.self,
            MigrationAuditRecord.self,
            PhotoAssetRecord.self,
            SheepAvatarRecord.self,
            HealthSubjectLink.self,
            LambingOffspringRecord.self,
            FeedIngredientBatchRecord.self,
            HealthCatalogItemRecord.self,
            CareBatchRecord.self,
            SemenTransactionRecord.self,
            FarmCareRuleRecord.self,
            CareReminderRecord.self,
            FarmAlertDeferralRecord.self,
            CloudFarmBinding.self,
            CloudZoneState.self,
            FarmMembershipBinding.self,
            DeviceIdentityRecord.self,
            CapabilityCertificateRecord.self,
            RevokedCapabilityCertificateRecord.self,
            SyncConflictRecord.self,
            CloudOperationReceipt.self,
            CloudAssetTransfer.self,
            FarmMembershipSnapshotRecord.self,
            FarmCheckpointRecord.self,
            FarmRecoveryAssetRecord.self,
            SecurityIncidentRecord.self,
            CloudRebuildSessionRecord.self,
            CloudRebuildIssueRecord.self,
            CloudSyncDiagnosticSnapshotRecord.self,
            FarmStorageProfile.self,
            FarmRemoteBinding.self,
            FarmOperationSequenceCounter.self,
            FarmOperationSequenceRecord.self,
            FarmBaselineMigrationRecord.self,
            FarmRemoteRestoreRecord.self,
            TMRFormulaProfileRecord.self,
            TMRFeedingPlanRecord.self,
            TMRFeedingPlanPenRecord.self,
            TMRBatchRecord.self,
            TMRBatchIngredientRecord.self,
            TMRBatchLoadLineRecord.self,
            TMRBatchMovementRecord.self,
            TMRFeedingRunRecord.self,
            TMRFeedingAllocationRecord.self,
            TMRMealCompletionRecord.self,
            TMRDeviationAcknowledgementRecord.self,
            TMRMonitoringRuleRecord.self,
        ]
    }

    /// V10 was the last schema before TMR. Historical schemas must derive from
    /// this frozen business entity set, never from `businessModelTypes`, or a
    /// newly added current model would silently change every older schema hash.
    fileprivate static var preV11BusinessModelTypes: [any PersistentModel.Type] {
        [
            AccountProfile.self,
            FarmRecord.self,
            FarmActivity.self,
            PenRecord.self,
            SheepRecord.self,
            WeightRecord.self,
            WeaningRecord.self,
            BreedingProgramRecord.self,
            BreedingProgramStepRecord.self,
            TransferRecord.self,
            RemovalRecord.self,
            ProductionBatchRecord.self,
            BatchMembershipRecord.self,
            DailyPenCountRecord.self,
            FeedIngredientRecord.self,
            FeedRecipeRecord.self,
            FeedRecipeComponentRecord.self,
            FeedRecord.self,
            FeedRecordLine.self,
            FeedTroughObservationRecord.self,
            FeedStockTransactionRecord.self,
            FeedStockCountRecord.self,
            InventoryLotRecord.self,
            InventoryTransactionRecord.self,
            HealthRecord.self,
            ReproductionRecord.self,
            SemenRecord.self,
            SemenDonorRecord.self,
            PedigreeChangeRecord.self,
            NoteRecord.self,
            DomainOperation.self,
            OutboxItem.self,
            TombstoneRecord.self,
            MigrationCommitRecord.self,
            MigrationAuditRecord.self,
            PhotoAssetRecord.self,
            SheepAvatarRecord.self,
            HealthSubjectLink.self,
            LambingOffspringRecord.self,
            FeedIngredientBatchRecord.self,
            HealthCatalogItemRecord.self,
            CareBatchRecord.self,
            SemenTransactionRecord.self,
            FarmCareRuleRecord.self,
            CareReminderRecord.self,
            FarmAlertDeferralRecord.self,
            CloudFarmBinding.self,
            CloudZoneState.self,
            FarmMembershipBinding.self,
            DeviceIdentityRecord.self,
            CapabilityCertificateRecord.self,
            RevokedCapabilityCertificateRecord.self,
            SyncConflictRecord.self,
            CloudOperationReceipt.self,
            CloudAssetTransfer.self,
            FarmMembershipSnapshotRecord.self,
            FarmCheckpointRecord.self,
            FarmRecoveryAssetRecord.self,
            SecurityIncidentRecord.self,
            CloudRebuildSessionRecord.self,
            CloudRebuildIssueRecord.self,
            CloudSyncDiagnosticSnapshotRecord.self,
            FarmStorageProfile.self,
            FarmRemoteBinding.self,
            FarmOperationSequenceCounter.self,
            FarmOperationSequenceRecord.self,
            FarmBaselineMigrationRecord.self,
            FarmRemoteRestoreRecord.self,
        ]
    }

    fileprivate static var preV3BusinessModelTypes: [any PersistentModel.Type] {
        preV7BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(OutboxItem.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FarmStorageProfile.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FarmRemoteBinding.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FarmOperationSequenceCounter.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FarmOperationSequenceRecord.self)
        }
    }

    fileprivate static var preV3BusinessModelTypesWithoutDomainOperation: [any PersistentModel.Type] {
        preV3BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(DomainOperation.self)
        }
    }

    fileprivate static var preV4BusinessModelTypes: [any PersistentModel.Type] {
        preV7BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmOperationSequenceCounter.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FarmOperationSequenceRecord.self)
        }
    }

    fileprivate static var preV5BusinessModelTypes: [any PersistentModel.Type] {
        preV7BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmBaselineMigrationRecord.self)
        }
    }

    fileprivate static var preV6BusinessModelTypes: [any PersistentModel.Type] {
        preV7BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmRemoteRestoreRecord.self)
        }
    }

    fileprivate static var preV7BusinessModelTypes: [any PersistentModel.Type] {
        preV8BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(SheepAvatarRecord.self)
        }
    }

    /// The store currently shipping as V7 contains SheepAvatarRecord and the
    /// old feed entities, but not the V8 stock ledger/count entities. Keep
    /// this exact entity set for V7 recognition; older schemas intentionally
    /// remove SheepAvatarRecord below.
    fileprivate static var preV8BusinessModelTypes: [any PersistentModel.Type] {
        preV11BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmCareRuleRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FarmAlertDeferralRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedStockTransactionRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedStockCountRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedIngredientRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedRecipeRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedRecipeComponentRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedRecordLine.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedIngredientBatchRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedTroughObservationRecord.self)
        } + [
            AppSchemaV7.FeedIngredientRecord.self,
            AppSchemaV7.FeedRecipeRecord.self,
            AppSchemaV7.FeedRecipeComponentRecord.self,
            AppSchemaV7.FeedRecord.self,
            AppSchemaV7.FeedRecordLine.self,
            AppSchemaV7.FeedIngredientBatchRecord.self,
            AppSchemaV8.FarmCareRuleRecord.self,
        ]
    }

    fileprivate static var preV9BusinessModelTypes: [any PersistentModel.Type] {
        preV11BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmCareRuleRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FarmAlertDeferralRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedTroughObservationRecord.self)
        } + [
            AppSchemaV8.FarmCareRuleRecord.self,
            AppSchemaV9.FeedRecord.self,
        ]
    }

    fileprivate static var preV9_1BusinessModelTypes: [any PersistentModel.Type] {
        preV11BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmCareRuleRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedTroughObservationRecord.self)
        } + [
            AppSchemaV9_0.FarmCareRuleRecord.self,
            AppSchemaV9.FeedRecord.self,
        ]
    }

    fileprivate static var preV10BusinessModelTypes: [any PersistentModel.Type] {
        preV11BusinessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FeedRecord.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FeedTroughObservationRecord.self)
        } + [
            AppSchemaV9.FeedRecord.self,
        ]
    }

    fileprivate static var insightModelTypes: [any PersistentModel.Type] {
        [
            InsightConversationRecord.self,
            InsightMessageRecord.self,
            InsightAttachmentRecord.self,
            InsightActionDraftRecord.self,
            InsightExecutionReceiptRecord.self,
            InsightSyncStateRecord.self,
        ]
    }

    static var modelTypes: [any PersistentModel.Type] {
        businessModelTypes + insightModelTypes
    }

    fileprivate static var preV4ModelTypes: [any PersistentModel.Type] {
        preV4BusinessModelTypes + insightModelTypes
    }

    fileprivate static var preV5ModelTypes: [any PersistentModel.Type] {
        preV5BusinessModelTypes + insightModelTypes
    }

    fileprivate static var preV6ModelTypes: [any PersistentModel.Type] {
        preV6BusinessModelTypes + insightModelTypes
    }

    fileprivate static var preV7ModelTypes: [any PersistentModel.Type] {
        preV7BusinessModelTypes + insightModelTypes
    }

    fileprivate static var preV8ModelTypes: [any PersistentModel.Type] {
        preV8BusinessModelTypes + insightModelTypes
    }

    fileprivate static var preV9ModelTypes: [any PersistentModel.Type] {
        preV9BusinessModelTypes + insightModelTypes
    }

    fileprivate static var preV9_1ModelTypes: [any PersistentModel.Type] {
        preV9_1BusinessModelTypes + insightModelTypes
    }

    fileprivate static var preV10ModelTypes: [any PersistentModel.Type] {
        preV10BusinessModelTypes + insightModelTypes
    }

    fileprivate static var preV11ModelTypes: [any PersistentModel.Type] {
        preV11BusinessModelTypes + insightModelTypes
    }

    static func makeSchema() -> Schema {
        Schema(versionedSchema: AppSchemaV11.self)
    }

    static func makeConfiguration(
        name: String,
        url: URL? = nil,
        isStoredInMemoryOnly: Bool = false
    ) -> ModelConfiguration {
        let schema = makeSchema()
        if let url {
            return ModelConfiguration(
                name,
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        }
        return ModelConfiguration(
            name,
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: .none
        )
    }

    static func makeContainer(
        name: String = "eSheepNext",
        url: URL? = nil,
        isStoredInMemoryOnly: Bool = false
    ) throws -> ModelContainer {
        let schema = makeSchema()
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(name, schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        } else if !isStoredInMemoryOnly {
            let storeURL = defaultStoreURL(name: name)
            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(name, schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly, cloudKitDatabase: .none)
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: AppSchemaMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
