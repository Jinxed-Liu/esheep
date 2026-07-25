import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class AppSchemaMigrationTests: XCTestCase {
    func testVersionedSchemaContainsEveryCurrentModel() {
        let versioned = Schema(versionedSchema: AppSchemaV2.self)
        let current = AppSchema.makeSchema()

        XCTAssertEqual(AppSchema.currentVersion, "2.0.0")
        XCTAssertEqual(versioned.entities.map(\.name).sorted(), current.entities.map(\.name).sorted())
        XCTAssertEqual(
            AppSchemaMigrationPlan.schemas.map { Schema(versionedSchema: $0).version },
            [Schema.Version(1, 0, 0), Schema.Version(2, 0, 0)]
        )
        XCTAssertEqual(AppSchemaMigrationPlan.stages.count, 1)
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
