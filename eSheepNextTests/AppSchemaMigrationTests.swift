import Foundation
import CoreData
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class AppSchemaMigrationTests: XCTestCase {
    func testHistoricalSchemasDoNotAbsorbTMRModels() {
        let historicalSchemas: [any VersionedSchema.Type] = [
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
        ]

        for versionedSchema in historicalSchemas {
            let names = Schema(versionedSchema: versionedSchema).entities.map(\.name)
            XCTAssertFalse(
                names.contains(where: { $0.hasPrefix("TMR") }),
                "Historical schema \(Schema(versionedSchema: versionedSchema).version) absorbed a current TMR model"
            )
        }

        XCTAssertEqual(
            Schema(versionedSchema: AppSchemaV11.self).entities.filter { $0.name.hasPrefix("TMR") }.count,
            12
        )
    }

    func testVersionedSchemaContainsEveryCurrentModel() {
        let versioned = Schema(versionedSchema: AppSchemaV11.self)
        let current = AppSchema.makeSchema()

        XCTAssertEqual(AppSchema.currentVersion, "11.0.0")
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
                Schema.Version(8, 0, 0),
                Schema.Version(9, 0, 0),
                Schema.Version(9, 1, 0),
                Schema.Version(10, 0, 0),
                Schema.Version(11, 0, 0),
            ]
        )
        XCTAssertEqual(AppSchemaMigrationPlan.stages.count, 11)
    }

    func testV10RecipesBecomeReviewableTMRProfilesWithoutInventingHistoricalBatchesOrPlans() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaV10TMR-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V10TMR.store")
        let accountID = UUID()
        let farmID = UUID()
        let recipeWithHeadCountID = UUID()
        let recipeWithoutHeadCountID = UUID()
        let ingredientID = UUID()
        let ingredientBatchID = UUID()
        let componentID = UUID()
        let feedID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV10.self)
            let configuration = ModelConfiguration(
                "V10TMR",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(id: accountID, appleUserIdentifier: "v10-tmr", displayName: "V10 TMR"))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "V10 TMR 场"))
            context.insert(FeedRecipeRecord(id: recipeWithHeadCountID, farmID: farmID, name: "有参考羊数", headCount: 100))
            context.insert(FeedRecipeRecord(id: recipeWithoutHeadCountID, farmID: farmID, name: "缺参考羊数", headCount: nil))
            context.insert(FeedIngredientRecord(id: ingredientID, farmID: farmID, name: "旧玉米", unit: "千克", nutrientSnapshotJSON: "{}", kind: .custom))
            context.insert(FeedIngredientBatchRecord(id: ingredientBatchID, farmID: farmID, ingredientID: ingredientID, batchName: "旧库存批次", pricePerKilogramText: "2", stockWeightConfirmed: true, initialKilogramsText: "100", remainingKilogramsText: "100", note: "", isActive: true))
            context.insert(FeedRecipeComponentRecord(id: componentID, farmID: farmID, recipeID: recipeWithHeadCountID, ingredientID: ingredientID, kilogramsText: "20", ingredientBatchID: ingredientBatchID))
            context.insert(FeedRecord(id: feedID, farmID: farmID, penID: UUID(), mode: .limited, occurredAt: .now, mealName: "早"))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V10TMR", url: storeURL)
        let context = ModelContext(reopened)
        let profiles = try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>())
        XCTAssertEqual(profiles.count, 2)
        let confirmed = try XCTUnwrap(profiles.first { $0.recipeID == recipeWithHeadCountID })
        XCTAssertEqual(confirmed.quantityBasis, .wholeGroupDaily)
        XCTAssertEqual(confirmed.referenceHeadCount, 100)
        XCTAssertFalse(confirmed.needsReview)
        let pending = try XCTUnwrap(profiles.first { $0.recipeID == recipeWithoutHeadCountID })
        XCTAssertNil(pending.referenceHeadCount)
        XCTAssertTrue(pending.needsReview)
        let migratedComponent = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).first { $0.id == componentID }
        )
        XCTAssertNil(migratedComponent.ingredientBatchID)
        XCTAssertEqual(migratedComponent.legacyBatchID, ingredientBatchID.uuidString.lowercased())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FeedRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TMRBatchRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TMRFeedingPlanRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
    }

    func testInstalledV9FeedMigratesToV10WithoutChangingSnapshotsOrCreatingOperations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaInstalledV9Feed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V9Feed.store")
        let accountID = UUID()
        let farmID = UUID()
        let penID = UUID()
        let feedID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_775_260_800)

        do {
            let schema = Schema(versionedSchema: AppSchemaV9.self)
            let configuration = ModelConfiguration(
                "V9Feed",
                schema: schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(
                id: accountID,
                appleUserIdentifier: "installed-v9-feed",
                displayName: "V9 投喂迁移"
            ))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "V9 投喂场"))
            context.insert(PenRecord(id: penID, farmID: farmID, name: "育肥一圈"))
            context.insert(AppSchemaV9.FeedRecord(
                id: feedID,
                farmID: farmID,
                penID: penID,
                mode: .limited,
                occurredAt: occurredAt,
                note: "保留旧投喂",
                mealName: "早饲",
                feederName: "迁移测试",
                remainingKilogramsText: "1.25",
                discardedKilogramsText: "0.2",
                recipeHeadCountSnapshot: 20,
                actualHeadCountSnapshot: 18,
                scaleFactorText: "0.9",
                remainingCompositionJSON: "[{\"ingredientName\":\"玉米\",\"kilograms\":1.25}]",
                legacySourceKey: "v9-feed"
            ))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V9Feed", url: storeURL)
        let context = ModelContext(reopened)
        let feed = try XCTUnwrap(try context.fetch(FetchDescriptor<FeedRecord>()).first)
        XCTAssertEqual(feed.id, feedID)
        XCTAssertEqual(feed.occurredAt, occurredAt)
        XCTAssertEqual(feed.note, "保留旧投喂")
        XCTAssertEqual(feed.remainingKilogramsText, "1.25")
        XCTAssertEqual(feed.discardedKilogramsText, "0.2")
        XCTAssertEqual(feed.actualHeadCountSnapshot, 18)
        XCTAssertEqual(feed.scaleFactorText, "0.9")
        XCTAssertEqual(feed.remainingCompositionJSON, "[{\"ingredientName\":\"玉米\",\"kilograms\":1.25}]")
        XCTAssertEqual(feed.excludedSheepIDs, [])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FeedTroughObservationRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
    }

    func testInstalledV8CareRulesRemainUnconfiguredAfterV9Migration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaInstalledV8Alerts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V8.store")
        let accountID = UUID()
        let farmID = UUID()
        let ruleID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV8.self)
            let configuration = ModelConfiguration("V8Alerts", schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(id: accountID, appleUserIdentifier: "installed-v8-alerts", displayName: "V8 提醒迁移"))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "V8 牧场"))
            context.insert(AppSchemaV8.FarmCareRuleRecord(
                id: ruleID,
                farmID: farmID,
                pregnancyCheckDays: 52,
                gestationDays: 148
            ))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V8Alerts", url: storeURL)
        let context = ModelContext(reopened)
        let rule = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first)
        XCTAssertEqual(rule.id, ruleID)
        XCTAssertEqual(rule.pregnancyCheckDays, 52)
        XCTAssertEqual(rule.gestationDays, 148)
        XCTAssertNil(rule.weaningAgeDays)
        XCTAssertEqual(rule.warningLeadDays, 0)
        XCTAssertNil(rule.operationalAlertsConfiguredAt)
        XCTAssertFalse(rule.alertDigestEnabled)
        XCTAssertEqual(rule.alertDigestMinuteOfDay, 480)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FarmAlertDeferralRecord>()), 0)
    }

    func testInstalledV9PointZeroRulesGainDisabledEarlyWarningWithoutLosingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaInstalledV9PointZeroAlerts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V9PointZero.store")
        let accountID = UUID()
        let farmID = UUID()
        let ruleID = UUID()
        let configuredAt = Date(timeIntervalSince1970: 1_754_006_400)

        do {
            let schema = Schema(versionedSchema: AppSchemaV9_0.self)
            let configuration = ModelConfiguration("V9PointZeroAlerts", schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(id: accountID, appleUserIdentifier: "installed-v9-point-zero-alerts", displayName: "V9.0 提醒迁移"))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "V9.0 牧场"))
            context.insert(AppSchemaV9_0.FarmCareRuleRecord(
                id: ruleID,
                farmID: farmID,
                pregnancyCheckDays: 42,
                gestationDays: 151,
                weaningAgeDays: 35,
                operationalAlertsConfiguredAt: configuredAt,
                alertDigestEnabled: true,
                alertDigestMinuteOfDay: 510
            ))
            try context.save()
        }

        let reopened = try AppSchema.makeContainer(name: "V9PointZeroAlerts", url: storeURL)
        let context = ModelContext(reopened)
        let rule = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first)
        XCTAssertEqual(rule.id, ruleID)
        XCTAssertEqual(rule.weaningAgeDays, 35)
        XCTAssertEqual(rule.warningLeadDays, 0)
        XCTAssertEqual(rule.operationalAlertsConfiguredAt, configuredAt)
        XCTAssertTrue(rule.alertDigestEnabled)
        XCTAssertEqual(rule.alertDigestMinuteOfDay, 510)
    }

    func testInstalledV7PreservesFeedSnapshotsAndAddsEmptyStockLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AppSchemaInstalledV7Feed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "V7.store")
        let accountID = UUID()
        let farmID = UUID()
        let penID = UUID()
        let ingredientID = UUID()
        let batchID = UUID()
        let recipeID = UUID()
        let componentID = UUID()
        let feedID = UUID()
        let lineID = UUID()

        do {
            let schema = Schema(versionedSchema: AppSchemaV7.self)
            let configuration = ModelConfiguration("V7Feed", schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(AccountProfile(id: accountID, appleUserIdentifier: "installed-v7-feed", displayName: "V7 原料迁移"))
            context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "V7 投喂场"))
            context.insert(PenRecord(id: penID, farmID: farmID, name: "一圈"))
            context.insert(AppSchemaV7.FeedIngredientRecord(id: ingredientID, farmID: farmID, name: "旧玉米", unit: "千克", dryMatterText: "86", category: "能量", nutrientSnapshotJSON: "{\"dryMatter\":86,\"crudeProtein\":9}"))
            context.insert(AppSchemaV7.FeedIngredientBatchRecord(id: batchID, farmID: farmID, ingredientID: ingredientID, batchName: "旧批次", pricePerKilogramText: "2.2", initialKilogramsText: "100", remainingKilogramsText: "70", note: "旧库存", isActive: true))
            context.insert(AppSchemaV7.FeedRecipeRecord(id: recipeID, farmID: farmID, name: "旧配方", note: "旧配方", targetPenName: "一圈", stageRawValue: "育肥羊", headCount: 20))
            context.insert(AppSchemaV7.FeedRecipeComponentRecord(id: componentID, farmID: farmID, recipeID: recipeID, ingredientID: ingredientID, kilogramsText: "10", pricePerKilogramText: "2.2", nutrientSnapshotJSON: "{\"dryMatter\":86}"))
            context.insert(AppSchemaV7.FeedRecord(id: feedID, farmID: farmID, penID: penID, recipeID: recipeID, mode: .limited, occurredAt: .now, note: "旧投喂", remainingKilogramsText: "1.5", discardedKilogramsText: "0.2"))
            context.insert(AppSchemaV7.FeedRecordLine(id: lineID, farmID: farmID, feedRecordID: feedID, ingredientID: ingredientID, kilogramsText: "10", ingredientNameSnapshot: "旧玉米", ingredientBatchID: batchID, ingredientBatchNameSnapshot: "旧批次", pricePerKilogramTextSnapshot: "2.2", nutrientSnapshotJSON: "{\"dryMatter\":86}", unitSnapshot: "千克", dryMatterTextSnapshot: "86"))
            try context.save()
        }

        let v7Metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: storeURL
        )
        XCTAssertEqual(
            v7Metadata["NSStoreModelVersionChecksumKey"] as? String,
            "Pan+FE5drgwNZfB0rqwiqDLK94frr7V2QkP0+WrDFE8=",
            "AppSchemaV7 must remain byte-for-byte compatible with the V7 store shipped to devices"
        )

        let reopened = try AppSchema.makeContainer(name: "V7Feed", url: storeURL)
        let context = ModelContext(reopened)
        let ingredient = try XCTUnwrap(try context.fetch(FetchDescriptor<FeedIngredientRecord>()).first)
        let batch = try XCTUnwrap(try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first)
        let recipe = try XCTUnwrap(try context.fetch(FetchDescriptor<FeedRecipeRecord>()).first)
        let component = try XCTUnwrap(try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).first)
        let feed = try XCTUnwrap(try context.fetch(FetchDescriptor<FeedRecord>()).first)
        let line = try XCTUnwrap(try context.fetch(FetchDescriptor<FeedRecordLine>()).first)
        XCTAssertEqual(ingredient.nutrientSnapshotJSON, "{\"dryMatter\":86,\"crudeProtein\":9}")
        XCTAssertEqual(batch.remainingKilogramsText, "70")
        XCTAssertNil(batch.purchasedKilogramsText)
        XCTAssertNil(recipe.targetPenID)
        XCTAssertNil(component.ingredientBatchID)
        XCTAssertNil(feed.recipeHeadCountSnapshot)
        XCTAssertNil(feed.scaleFactorText)
        XCTAssertNil(line.stockQuantityText)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FeedStockTransactionRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FeedStockCountRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DomainOperation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OutboxItem>()), 0)
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
