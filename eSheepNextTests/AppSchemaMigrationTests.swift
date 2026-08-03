import Foundation
import CoreData
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class AppSchemaMigrationTests: XCTestCase {
    func testVersionedSchemaContainsEveryCurrentModel() {
        let versioned = Schema(versionedSchema: AppSchemaV7.self)
        let current = AppSchema.makeSchema()

        XCTAssertEqual(AppSchema.currentVersion, "7.0.0")
        XCTAssertEqual(versioned.entities.map(\.name).sorted(), current.entities.map(\.name).sorted())
        XCTAssertEqual(
            AppSchemaMigrationPlan.schemas.map { Schema(versionedSchema: $0).version },
            [
                Schema.Version(1, 0, 0),
                Schema.Version(2, 0, 0),
                Schema.Version(3, 0, 0),
                Schema.Version(4, 0, 0),
                Schema.Version(5, 0, 0),
                Schema.Version(6, 0, 0),
                Schema.Version(7, 0, 0),
            ]
        )
        XCTAssertEqual(AppSchemaMigrationPlan.stages.count, 6)
    }

    func testPublishedV7RestoreRecordSchemaRemainsFrozen() throws {
        let schema = Schema(versionedSchema: AppSchemaV7.self)
        let entity = try XCTUnwrap(
            schema.entities.first { $0.name == "FarmRemoteRestoreRecord" }
        )

        XCTAssertEqual(
            Set(entity.properties.map(\.name)),
            Set([
                "id",
                "accountID",
                "ownerAccountID",
                "memberRoleRawValue",
                "serverMembershipID",
                "farmID",
                "authorityGeneration",
                "stateRawValue",
                "checkpointID",
                "checkpointMigrationID",
                "checkpointRelativePath",
                "checkpointDigest",
                "checkpointRevision",
                "targetCursorRevision",
                "currentCursorRevision",
                "totalEntityCount",
                "restoredEntityCount",
                "totalAssetCount",
                "downloadedAssetCount",
                "promotedAssetCount",
                "lastErrorCode",
                "createdAt",
                "updatedAt",
                "completedAt",
            ])
        )
    }

    func testInstalledV7RestoreRecordReopensRepeatedly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "AppSchemaInstalledV7-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V7.store")
        let accountID = UUID()
        let ownerAccountID = UUID()
        let farmID = UUID()
        let membershipID = "supabase:\(farmID.uuidString.lowercased()):member"

        do {
            let schema = Schema(versionedSchema: AppSchemaV7.self)
            let configuration = ModelConfiguration(
                "V7",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
            let context = ModelContext(container)
            context.insert(FarmRemoteRestoreRecord(
                accountID: accountID,
                farmID: farmID,
                authorityGeneration: 1,
                ownerAccountID: ownerAccountID,
                memberRole: .worker,
                serverMembershipID: membershipID,
                state: .completed,
                targetCursorRevision: 842
            ))
            try context.save()
        }

        for _ in 0..<2 {
            let reopened = try AppSchema.makeContainer(name: "V7", url: storeURL)
            let context = ModelContext(reopened)
            let record = try XCTUnwrap(
                try context.fetch(FetchDescriptor<FarmRemoteRestoreRecord>()).first
            )
            XCTAssertEqual(record.accountID, accountID)
            XCTAssertEqual(record.ownerAccountID, ownerAccountID)
            XCTAssertEqual(record.farmID, farmID)
            XCTAssertEqual(record.authorityGeneration, 1)
            XCTAssertEqual(record.memberRole, .worker)
            XCTAssertEqual(record.serverMembershipID, membershipID)
            XCTAssertEqual(record.state, .completed)
            XCTAssertEqual(record.targetCursorRevision, 842)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
        }
    }

    /// The stable-baseline gate can point this test at a copied device store.
    /// The source backup is never opened in place: the store and SQLite
    /// sidecars are copied to a disposable directory before SwiftData opens it.
    func testProvidedDeviceV7BackupOpensRepeatedly() throws {
        guard let sourcePath = ProcessInfo.processInfo.environment[
            "ESHEEP_DEVICE_V7_STORE"
        ], !sourcePath.isEmpty else {
            return
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "AppSchemaDeviceV7-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let currentModelURL = directory.appending(path: "CurrentV7.store")
        do {
            let schema = Schema(versionedSchema: AppSchemaV7.self)
            let configuration = ModelConfiguration(
                "CurrentV7",
                schema: schema,
                url: currentModelURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            _ = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        }
        let deviceMetadata = try NSPersistentStoreCoordinator
            .metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: sourceURL
            )
        let currentMetadata = try NSPersistentStoreCoordinator
            .metadataForPersistentStore(
                ofType: NSSQLiteStoreType,
                at: currentModelURL
            )
        let deviceHashes = try XCTUnwrap(
            deviceMetadata["NSStoreModelVersionHashes"] as? [String: Data]
        )
        let currentHashes = try XCTUnwrap(
            currentMetadata["NSStoreModelVersionHashes"] as? [String: Data]
        )
        XCTAssertEqual(Set(deviceHashes.keys), Set(currentHashes.keys))
        for key in Set(deviceHashes.keys).intersection(currentHashes.keys) {
            XCTAssertEqual(
                deviceHashes[key],
                currentHashes[key],
                "已安装 V7 模型发生变化：\(key)"
            )
        }
        guard deviceHashes == currentHashes else { return }
        var expectedCounts: (farms: Int, sheep: Int, operations: Int, outbox: Int)?
        for attempt in 0..<2 {
            // Use a fresh copy for each open. SwiftData can retain the first
            // store coordinator until the test autorelease pool drains; a
            // second coordinator for the exact same URL would test file-lock
            // lifetime rather than schema compatibility.
            let copiedURL = directory.appending(path: "DeviceV7-\(attempt).store")
            try FileManager.default.copyItem(at: sourceURL, to: copiedURL)
            for suffix in ["-wal", "-shm"] {
                let sourceSidecar = URL(fileURLWithPath: sourcePath + suffix)
                guard FileManager.default.fileExists(atPath: sourceSidecar.path) else {
                    continue
                }
                try FileManager.default.copyItem(
                    at: sourceSidecar,
                    to: URL(fileURLWithPath: copiedURL.path + suffix)
                )
            }
            let container = try AppSchema.makeContainer(
                name: "DeviceV7-\(attempt)",
                url: copiedURL
            )
            let context = ModelContext(container)
            let counts = (
                farms: try context.fetchCount(FetchDescriptor<FarmRecord>()),
                sheep: try context.fetchCount(FetchDescriptor<SheepRecord>()),
                operations: try context.fetchCount(FetchDescriptor<DomainOperation>()),
                outbox: try context.fetchCount(FetchDescriptor<OutboxItem>())
            )
            XCTAssertGreaterThan(counts.farms, 0)
            XCTAssertGreaterThan(counts.sheep, 0)
            if let expectedCounts {
                XCTAssertEqual(counts.farms, expectedCounts.farms)
                XCTAssertEqual(counts.sheep, expectedCounts.sheep)
                XCTAssertEqual(counts.operations, expectedCounts.operations)
                XCTAssertEqual(counts.outbox, expectedCounts.outbox)
            } else {
                expectedCounts = counts
            }
        }
    }

    func testInstalledV6MigratesToV7WithoutChangingSheepOrPhotos() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaInstalledV6-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V6.store")
        let accountID = UUID()
        let farmID = UUID()
        let sheepID = UUID()
        let photoID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV6.self)
            let configuration = ModelConfiguration(
                "V6",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(
                id: accountID,
                appleUserIdentifier: "installed-v6",
                displayName: "已安装 V6"
            ))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "V6 牧场"))
            context.insert(SheepRecord(
                id: sheepID,
                farmID: farmID,
                earTag: "V6001",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now
            ))
            context.insert(PhotoAssetRecord(
                id: photoID,
                farmID: farmID,
                sheepID: sheepID,
                legacySourceKey: "test:v6",
                originalEarTag: "V6001",
                relativePath: "Assets/v6.jpg",
                sha256: "v6-photo"
            ))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V6", url: storeURL)
        let context = ModelContext(reopened)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SheepRecord>()).first?.id, sheepID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first?.id, photoID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SheepAvatarRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
    }

    func testInstalledV5MigratesToV6WithoutCreatingRestoreWork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "AppSchemaInstalledV5-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V5.store")
        let accountID = UUID()
        let farmID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV5.self)
            let configuration = ModelConfiguration(
                "V5",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
            let context = ModelContext(container)
            context.insert(AccountProfile(
                id: accountID,
                appleUserIdentifier: "installed-v5",
                displayName: "已安装 V5"
            ))
            context.insert(FarmRecord(
                id: farmID,
                ownerAccountID: accountID,
                name: "V5 牧场"
            ))
            context.insert(FarmStorageProfile(
                farmID: farmID,
                mode: .supabase,
                authorityGeneration: 1
            ))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V5", url: storeURL)
        let context = ModelContext(reopened)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<FarmRemoteRestoreRecord>()),
            0
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<DomainOperation>()),
            0
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<OutboxItem>()),
            0
        )
    }

    func testInstalledV4MigratesToV5WithoutGeneratingMigrationWork() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaInstalledV4-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V4.store")
        let accountID = UUID()
        let farmID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV4.self)
            let configuration = ModelConfiguration(
                "V4",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
            let context = ModelContext(container)
            context.insert(AccountProfile(
                id: accountID,
                appleUserIdentifier: "installed-v4",
                displayName: "已安装 V4"
            ))
            context.insert(FarmRecord(
                id: farmID,
                ownerAccountID: accountID,
                name: "V4 牧场"
            ))
            context.insert(FarmStorageProfile(farmID: farmID, mode: .localOnly))
            context.insert(FarmOperationSequenceCounter(
                farmID: farmID,
                nextSequence: 1
            ))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V4", url: storeURL)
        let context = ModelContext(reopened)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FarmRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<FarmBaselineMigrationRecord>()),
            0
        )
    }

    func testOpeningPersistentStoreDoesNotCreateBusinessOperationsOrOutbox() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Legacy.store")
        let accountID = UUID()
        let farmID = UUID()

        do {
            let legacySchema = Schema(versionedSchema: AppSchemaV1.self)
            let configuration = ModelConfiguration(
                "Legacy",
                schema: legacySchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(for: legacySchema, configurations: [configuration])
            let context = ModelContext(legacyContainer)
            context.insert(AccountProfile(id: accountID, appleUserIdentifier: "migration-test", displayName: "迁移测试"))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "迁移牧场"))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "Legacy", url: storeURL)
        let context = ModelContext(reopened)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AccountProfile>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FarmRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
        let profile = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmStorageProfile>()).first(where: { $0.farmID == farmID })
        )
        XCTAssertEqual(profile.mode, .localOnly)
        XCTAssertEqual(profile.transitionState, .idle)
        XCTAssertEqual(profile.authorityGeneration, 0)
    }

    func testV2ToV3ClassifiesBindingsAndRetiresLocalOutboxWithoutBusinessCommands() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaStorageMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V2.store")
        let accountID = UUID()
        let iCloudFarmID = UUID()
        let localFarmID = UUID()
        let iCloudOperationID = UUID()
        let localOperationID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV2.self)
            let configuration = ModelConfiguration(
                "V2",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(
                id: accountID,
                appleUserIdentifier: "v2-storage-migration",
                displayName: "V2 迁移"
            ))
            context.insert(FarmRecord(id: iCloudFarmID, ownerAccountID: accountID, name: "iCloud 牧场"))
            context.insert(FarmRecord(id: localFarmID, ownerAccountID: accountID, name: "本地牧场"))
            context.insert(CloudFarmBinding(
                farmID: iCloudFarmID,
                ownerAccountID: accountID,
                state: .active
            ))
            context.insert(AppSchemaV2.OutboxItem(
                farmID: iCloudFarmID,
                accountID: accountID,
                operationID: iCloudOperationID
            ))
            context.insert(AppSchemaV2.OutboxItem(
                farmID: localFarmID,
                accountID: accountID,
                operationID: localOperationID
            ))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V2", url: storeURL)
        let context = ModelContext(reopened)
        let profiles = try context.fetch(FetchDescriptor<FarmStorageProfile>())
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())

        XCTAssertEqual(profiles.first(where: { $0.farmID == iCloudFarmID })?.mode, .iCloud)
        XCTAssertEqual(profiles.first(where: { $0.farmID == localFarmID })?.mode, .localOnly)
        XCTAssertEqual(
            outbox.first(where: { $0.operationID == iCloudOperationID })?.deliveryProvider,
            .iCloud
        )
        XCTAssertEqual(
            outbox.first(where: { $0.operationID == localOperationID })?.status,
            .notRequiredLocalOnly
        )
        XCTAssertNil(outbox.first(where: { $0.operationID == localOperationID })?.deliveryProvider)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
    }

    func testV2ToV3BackfillsStableOperationAndOutboxSequences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaSequenceMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V2.store")
        let accountID = UUID()
        let farmID = UUID()
        let earlierID = UUID()
        let laterID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV2.self)
            let configuration = ModelConfiguration(
                "V2",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(
                id: accountID,
                appleUserIdentifier: "v2-sequence-migration",
                displayName: "V2 序号迁移"
            ))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "序号牧场"))
            let later = DomainOperation(
                id: laterID,
                farmID: farmID,
                accountID: accountID,
                kind: .createPen,
                summary: "后创建"
            )
            later.createdAt = Date(timeIntervalSince1970: 200)
            let earlier = DomainOperation(
                id: earlierID,
                farmID: farmID,
                accountID: accountID,
                kind: .createFarm,
                summary: "先创建"
            )
            earlier.createdAt = Date(timeIntervalSince1970: 100)
            context.insert(later)
            context.insert(earlier)
            context.insert(AppSchemaV2.OutboxItem(
                farmID: farmID,
                accountID: accountID,
                operationID: laterID
            ))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V2", url: storeURL)
        let context = ModelContext(reopened)
        let outbox = try XCTUnwrap(
            context.fetch(FetchDescriptor<OutboxItem>())
                .first(where: { $0.operationID == laterID })
        )
        let profile = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmStorageProfile>())
                .first(where: { $0.farmID == farmID })
        )

        let sequences = try FarmStorageRouter.operationSequences(
            farmID: farmID,
            context: context
        )
        XCTAssertEqual(sequences[earlierID], 1)
        XCTAssertEqual(sequences[laterID], 2)
        XCTAssertEqual(sequences[outbox.operationID], 2)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FarmOperationSequenceCounter>())
                .first(where: { $0.farmID == profile.farmID })?.nextSequence,
            3
        )
    }

    func testInstalledDevelopmentV3MigratesToV4WithoutLosingSequenceOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaInstalledV3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V3.store")
        let accountID = UUID()
        let farmID = UUID()
        let operationID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV3.self)
            let configuration = ModelConfiguration(
                "V3",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(
                id: accountID,
                appleUserIdentifier: "installed-v3",
                displayName: "已安装 V3"
            ))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "V3 牧场"))
            context.insert(FarmStorageProfile(farmID: farmID, mode: .localOnly))
            let operation = DomainOperation(
                id: operationID,
                farmID: farmID,
                accountID: accountID,
                kind: .createFarm,
                summary: "创建牧场"
            )
            operation.createdAt = Date(timeIntervalSince1970: 100)
            context.insert(operation)
            let outbox = OutboxItem(
                farmID: farmID,
                accountID: accountID,
                operationID: operationID
            )
            outbox.deliveryProviderRawValue = nil
            outbox.statusRawValue = OutboxStatus.notRequiredLocalOnly.rawValue
            context.insert(outbox)
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V3", url: storeURL)
        let context = ModelContext(reopened)
        let operation = try XCTUnwrap(
            context.fetch(FetchDescriptor<DomainOperation>()).first(where: { $0.id == operationID })
        )
        let outbox = try XCTUnwrap(
            context.fetch(FetchDescriptor<OutboxItem>()).first(where: { $0.operationID == operationID })
        )
        let profile = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmStorageProfile>()).first(where: { $0.farmID == farmID })
        )

        let sequences = try FarmStorageRouter.operationSequences(
            farmID: farmID,
            context: context
        )
        XCTAssertEqual(sequences[operation.id], 1)
        XCTAssertEqual(sequences[outbox.operationID], 1)
        XCTAssertEqual(outbox.status, .notRequiredLocalOnly)
        XCTAssertEqual(profile.mode, .localOnly)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FarmOperationSequenceCounter>())
                .first(where: { $0.farmID == farmID })?.nextSequence,
            2
        )
    }

    func testV1DomainOperationMigratesWithNilSourceRequestID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaOperationMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Legacy.store")
        let operationID = UUID()
        let accountID = UUID()
        let farmID = UUID()
        let entityID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_750_000_000)
        let payload = Data(#"{"kind":"recordWeight"}"#.utf8)

        do {
            let legacySchema = Schema(versionedSchema: AppSchemaV1.self)
            let configuration = ModelConfiguration(
                "Legacy",
                schema: legacySchema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(for: legacySchema, configurations: [configuration])
            let context = ModelContext(legacyContainer)
            let operation = AppSchemaV1.DomainOperation(
                id: operationID,
                farmID: farmID,
                accountID: accountID,
                kindRawValue: DomainOperationKind.recordWeight.rawValue,
                occurredAt: occurredAt,
                summary: "记录称重"
            )
            operation.entityType = CloudEntityType.weight.rawValue
            operation.entityID = entityID
            operation.baseRevision = 0
            operation.resultingRevision = 1
            operation.payload = payload
            operation.payloadDigest = CloudPayloadDigest.hex(for: payload)
            context.insert(operation)
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "Legacy", url: storeURL)
        let context = ModelContext(reopened)
        let migrated = try XCTUnwrap(
            try context.fetch(FetchDescriptor<DomainOperation>()).first(where: { $0.id == operationID })
        )

        XCTAssertEqual(migrated.farmID, farmID)
        XCTAssertEqual(migrated.accountID, accountID)
        XCTAssertEqual(migrated.kindRawValue, DomainOperationKind.recordWeight.rawValue)
        XCTAssertEqual(migrated.occurredAt, occurredAt)
        XCTAssertEqual(migrated.entityID, entityID)
        XCTAssertEqual(migrated.payload, payload)
        XCTAssertNil(migrated.sourceRequestID)
    }

    func testQuarantineMovesStoreAndSidecarsWithoutDeletingBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StoreQuarantine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "eSheepNext.store")
        let fixtures: [(URL, Data)] = [
            (storeURL, Data("store".utf8)),
            (directory.appending(path: "eSheepNext.store-wal"), Data("wal".utf8)),
            (directory.appending(path: "eSheepNext.store-shm"), Data("shm".utf8)),
        ]
        for fixture in fixtures {
            try fixture.1.write(to: fixture.0)
        }

        let destination = try LocalStoreRecoveryService.quarantineCurrentStore(
            storeURL: storeURL,
            now: Date(timeIntervalSince1970: 0)
        )

        for fixture in fixtures {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.0.path))
            let quarantined = destination.appending(path: fixture.0.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: quarantined), fixture.1)
        }
    }

    func testDiagnosticReportOmitsBusinessAndCredentialPayloads() {
        let failure = LocalStoreLaunchFailure(
            error: NSError(domain: "MigrationTest", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "\(NSHomeDirectory())/Library/Application Support/eSheepNext.store could not open",
                "access_token": "must-not-appear",
            ])
        )

        XCTAssertTrue(failure.diagnosticText.contains("MigrationTest / 17"))
        XCTAssertTrue(failure.diagnosticText.contains("<App Sandbox>"))
        XCTAssertFalse(failure.diagnosticText.contains("must-not-appear"))
        XCTAssertFalse(failure.diagnosticText.contains(NSHomeDirectory()))
    }
}
