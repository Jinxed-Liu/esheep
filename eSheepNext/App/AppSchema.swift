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
        ]
    }
}

enum AppSchema {
    static let currentVersion = "6.0.0"

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
            FarmStorageProfile.self,
            FarmRemoteBinding.self,
            FarmOperationSequenceCounter.self,
            FarmOperationSequenceRecord.self,
            FarmBaselineMigrationRecord.self,
            FarmRemoteRestoreRecord.self,
        ]
    }

    fileprivate static var preV3BusinessModelTypes: [any PersistentModel.Type] {
        businessModelTypes.filter {
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
        businessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmOperationSequenceCounter.self) &&
            ObjectIdentifier($0) != ObjectIdentifier(FarmOperationSequenceRecord.self)
        }
    }

    fileprivate static var preV5BusinessModelTypes: [any PersistentModel.Type] {
        businessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmBaselineMigrationRecord.self)
        }
    }

    fileprivate static var preV6BusinessModelTypes: [any PersistentModel.Type] {
        businessModelTypes.filter {
            ObjectIdentifier($0) != ObjectIdentifier(FarmRemoteRestoreRecord.self)
        }
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

    static func makeSchema() -> Schema {
        Schema(versionedSchema: AppSchemaV6.self)
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
