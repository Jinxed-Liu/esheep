import Foundation
import SwiftData

enum AppSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.modelTypes }
}

enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self]
    }

    // V1 freezes the schema that shipped before formal versioning was
    // introduced. Future schema versions must add an explicit lightweight or
    // custom stage here; opening a store must never trigger business commands.
    static var stages: [MigrationStage] {
        []
    }
}

enum AppSchema {
    static let currentVersion = "1.0.0"

    static func defaultStoreURL(name: String = "eSheepNext") -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "\(name).store")
    }

    static var modelTypes: [any PersistentModel.Type] {
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
            HealthSubjectLink.self,
            LambingOffspringRecord.self,
            FeedIngredientBatchRecord.self,
            HealthCatalogItemRecord.self,
            CareBatchRecord.self,
            SemenTransactionRecord.self,
            FarmCareRuleRecord.self,
            CareReminderRecord.self,
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
        ]
    }

    static func makeSchema() -> Schema {
        Schema(versionedSchema: AppSchemaV1.self)
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
