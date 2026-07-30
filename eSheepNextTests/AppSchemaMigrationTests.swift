import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class AppSchemaMigrationTests: XCTestCase {
    func testVersionedSchemaContainsEveryCurrentModel() {
        let versioned = Schema(versionedSchema: AppSchemaV6.self)
        let current = AppSchema.makeSchema()

        XCTAssertEqual(AppSchema.currentVersion, "6.0.0")
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
            ]
        )
        XCTAssertEqual(AppSchemaMigrationPlan.stages.count, 5)
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
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
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
