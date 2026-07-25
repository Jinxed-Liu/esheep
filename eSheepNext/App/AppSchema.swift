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

    static var models: [any PersistentModel.Type] {
        AppSchema.businessModelTypesWithoutDomainOperation + [DomainOperation.self]
    }
}

enum AppSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { AppSchema.modelTypes }
}

enum AppSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self]
    }

    // V1 freezes the schema that shipped before formal versioning was
    // introduced. Future schema versions must add an explicit lightweight or
    // custom stage here; opening a store must never trigger business commands.
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self)]
    }
}

enum AppSchema {
    static let currentVersion = "2.0.0"

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

    fileprivate static var businessModelTypesWithoutDomainOperation: [any PersistentModel.Type] {
        businessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(DomainOperation.self)
        }
    }

    static var modelTypes: [any PersistentModel.Type] {
        businessModelTypes + [
            InsightConversationRecord.self,
            InsightMessageRecord.self,
            InsightAttachmentRecord.self,
            InsightActionDraftRecord.self,
            InsightExecutionReceiptRecord.self,
            InsightSyncStateRecord.self,
        ]
    }

    static func makeSchema() -> Schema {
        Schema(versionedSchema: AppSchemaV2.self)
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
