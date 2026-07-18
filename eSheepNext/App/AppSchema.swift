import Foundation
import SwiftData

enum AppSchema {
    static func makeSchema() -> Schema {
        Schema([
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
        ])
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
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storeURL = directory.appending(path: "\(name).store")
            configuration = ModelConfiguration(name, schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
