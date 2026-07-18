import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FarmDomainTests: XCTestCase {
    func testCapabilitySetIsFarmRoleScoped() {
        XCTAssertTrue(CapabilitySet(role: .owner).allows(.manageMembers))
        XCTAssertTrue(CapabilitySet(role: .administrator).allows(.recordProduction))
        XCTAssertFalse(CapabilitySet(role: .administrator).allows(.manageMembers))
        XCTAssertTrue(CapabilitySet(role: .worker).allows(.recordProduction))
        XCTAssertFalse(CapabilitySet(role: .worker).allows(.manageCatalogs))
    }

    func testSubscriptionNeverBlocksAuthorizedProductionRecording() {
        let basic = AccountEntitlement.basic(accountID: UUID(), state: .expired)
        XCTAssertTrue(SubscriptionCapabilityPolicy.canRecordProduction(role: .owner, entitlement: basic))
        XCTAssertTrue(SubscriptionCapabilityPolicy.canRecordProduction(role: .administrator, entitlement: basic))
        XCTAssertTrue(SubscriptionCapabilityPolicy.canRecordProduction(role: .worker, entitlement: basic))
    }

    func testAdditionalFarmRequiresMatchingOwnerProEntitlement() {
        let accountID = UUID()
        let active = AccountEntitlement(accountID: accountID, tier: .farmPro, state: .active, productID: SubscriptionProductID.yearly, validUntil: .now.addingTimeInterval(86_400))
        let grace = AccountEntitlement(accountID: accountID, tier: .farmPro, state: .gracePeriod, productID: SubscriptionProductID.monthly, validUntil: .now)
        let expired = AccountEntitlement(accountID: accountID, tier: .basic, state: .expired, productID: SubscriptionProductID.monthly, validUntil: .now)

        XCTAssertTrue(SubscriptionCapabilityPolicy.canCreateAdditionalFarm(role: .owner, entitlement: active))
        XCTAssertTrue(SubscriptionCapabilityPolicy.canCreateAdditionalFarm(role: .owner, entitlement: grace))
        XCTAssertFalse(SubscriptionCapabilityPolicy.canCreateAdditionalFarm(role: .owner, entitlement: expired))
        XCTAssertFalse(SubscriptionCapabilityPolicy.canCreateAdditionalFarm(role: .worker, entitlement: active))
    }

    func testFirstFarmIsFreeButAdditionalFarmRequiresPro() {
        let basic = AccountEntitlement.basic(accountID: UUID())
        let pro = AccountEntitlement(
            accountID: UUID(),
            tier: .farmPro,
            state: .active,
            productID: SubscriptionProductID.yearly,
            validUntil: .now.addingTimeInterval(86_400)
        )

        XCTAssertTrue(SubscriptionCapabilityPolicy.canCreateFarm(existingOwnedFarmCount: 0, entitlement: basic))
        XCTAssertFalse(SubscriptionCapabilityPolicy.canCreateFarm(existingOwnedFarmCount: 1, entitlement: basic))
        XCTAssertTrue(SubscriptionCapabilityPolicy.canCreateFarm(existingOwnedFarmCount: 1, entitlement: pro))
    }

    func testWidgetSnapshotKeepsEveryEntityFarmScoped() {
        let ownerID = UUID()
        let first = FarmRecord(ownerAccountID: ownerID, name: "北场")
        let second = FarmRecord(ownerAccountID: ownerID, name: "南场")
        let firstPen = PenRecord(farmID: first.id, name: "一号圈")
        let secondPen = PenRecord(farmID: second.id, name: "二号圈")
        let firstSheep = SheepRecord(farmID: first.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: firstPen.id, enteredAt: .now)
        let secondSheep = SheepRecord(farmID: second.id, earTag: "B001", breed: "杜泊", sex: .ram, penID: secondPen.id, enteredAt: .now)
        let pending = OutboxItem(farmID: first.id, accountID: ownerID, operationID: UUID())

        let snapshot = FarmSystemIntegrationService.makeSnapshot(
            farms: [first, second],
            sheep: [firstSheep, secondSheep],
            pens: [firstPen, secondPen],
            feeds: [],
            outbox: [pending],
            selectedFarmID: second.id
        )

        XCTAssertEqual(snapshot.version, FarmWidgetSnapshot.currentVersion)
        XCTAssertEqual(snapshot.selectedFarmID, second.id)
        XCTAssertEqual(snapshot.farms.first(where: { $0.farmID == first.id })?.sheep.map(\.farmID), [first.id])
        XCTAssertEqual(snapshot.farms.first(where: { $0.farmID == second.id })?.pens.map(\.farmID), [second.id])
        XCTAssertEqual(snapshot.farms.first(where: { $0.farmID == first.id })?.pendingOperationCount, 1)
    }

    func testSpotlightDeepLinkPreservesFarmAndEntityIdentity() throws {
        let farmID = UUID()
        let sheepID = UUID()
        let url = try XCTUnwrap(URL(string: "esheep://farm/\(farmID.uuidString)/sheep/\(sheepID.uuidString)?q=A001"))

        let target = try XCTUnwrap(FarmSystemIntegrationService.target(from: url))

        XCTAssertEqual(target.farmID, farmID)
        XCTAssertEqual(target.entityID, sheepID)
        XCTAssertEqual(target.kind, .searchSheep)
        XCTAssertEqual(target.query, "A001")
    }

    func testMigrationFarmIsRejectedByDevelopmentCloudGate() async throws {
        let container = try AppSchema.makeContainer(name: "migration-cloud-gate-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let migratedFarm = FarmRecord(ownerAccountID: UUID(), name: "本机迁移牧场")
        migratedFarm.isLocalOnlyMigration = true
        migratedFarm.isDevelopmentTestFarm = true // 即使有人错误写入测试标记，也必须拒绝。
        migratedFarm.developmentSeed = TestFarmGeneratorActor.seed
        context.insert(migratedFarm)
        try context.save()

        do {
            try await FarmPersistenceActor(container: container).requireDevelopmentTestFarm(farmID: migratedFarm.id)
            XCTFail("迁移牧场不能通过 Development 云端门禁")
        } catch let error as CloudSyncError {
            guard case .localOnlyMigration = error else {
                return XCTFail("收到错误的拒绝原因：\(error.localizedDescription)")
            }
        }
    }

    func testCloudAdmissionPolicySeparatesDevelopmentAndProduction() throws {
        let developmentTestFarm = CloudAdmissionRequest(
            environment: .development,
            role: .owner,
            membershipIsActive: true,
            isDeleted: false,
            isDevelopmentTestFarm: true,
            developmentSeed: TestFarmGeneratorActor.seed,
            isLocalOnlyMigration: false
        )
        XCTAssertNoThrow(try CloudAdmissionPolicy.validate(developmentTestFarm))

        var productionFarm = CloudAdmissionRequest(
            environment: .production,
            role: .owner,
            membershipIsActive: true,
            isDeleted: false,
            isDevelopmentTestFarm: false,
            developmentSeed: nil,
            isLocalOnlyMigration: false
        )
        XCTAssertNoThrow(try CloudAdmissionPolicy.validate(productionFarm))

        productionFarm = CloudAdmissionRequest(
            environment: .production,
            role: .owner,
            membershipIsActive: true,
            isDeleted: false,
            isDevelopmentTestFarm: true,
            developmentSeed: TestFarmGeneratorActor.seed,
            isLocalOnlyMigration: false
        )
        XCTAssertThrowsError(try CloudAdmissionPolicy.validate(productionFarm)) { error in
            XCTAssertEqual(error as? CloudAdmissionDenial, .formalFarmRequired)
        }
    }

    func testCloudAdmissionRejectsMigrationAndNonOwnerInEveryEnvironment() {
        let migration = CloudAdmissionRequest(
            environment: .production,
            role: .owner,
            membershipIsActive: true,
            isDeleted: false,
            isDevelopmentTestFarm: false,
            developmentSeed: nil,
            isLocalOnlyMigration: true
        )
        XCTAssertThrowsError(try CloudAdmissionPolicy.validate(migration)) { error in
            XCTAssertEqual(error as? CloudAdmissionDenial, .localOnlyMigration)
        }

        let worker = CloudAdmissionRequest(
            environment: .production,
            role: .worker,
            membershipIsActive: true,
            isDeleted: false,
            isDevelopmentTestFarm: false,
            developmentSeed: nil,
            isLocalOnlyMigration: false
        )
        XCTAssertThrowsError(try CloudAdmissionPolicy.validate(worker)) { error in
            XCTAssertEqual(error as? CloudAdmissionDenial, .ownerRequired)
        }
    }

    func testFreeChoiceUsesOnlyClosedIntervalsAndRealSheepDays() {
        let sheepID = UUID()
        let penID = UUID()
        let ingredientID = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let second = start.addingTimeInterval(2 * 86_400)
        let sheep = [SheepPresenceSnapshot(sheepID: sheepID, initialPenID: penID, enteredAt: start, removedAt: nil)]
        let feeds = [
            FeedSnapshot(feedID: UUID(), penID: penID, ingredientID: ingredientID, ingredientName: "苜蓿草", kilograms: 10, mode: .freeChoice, occurredAt: start),
            FeedSnapshot(feedID: UUID(), penID: penID, ingredientID: ingredientID, ingredientName: "苜蓿草", kilograms: 8, mode: .freeChoice, occurredAt: second)
        ]

        let result = FarmAnalytics.freeChoiceIntake(from: feeds, sheep: sheep, transfers: [], calendar: calendar)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kilograms, 10)
        XCTAssertEqual(result[0].sheepDays, 2)
        XCTAssertEqual(result[0].kilogramsPerSheepDay, 5)
        XCTAssertTrue(result[0].hasMissingFinalBoundary)
    }

    func testSheepDaysSplitsAtExactEntryTransferAndRemovalTimes() {
        let penA = UUID()
        let penB = UUID()
        let firstSheep = UUID()
        let secondSheep = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 0))!
        let noon = calendar.date(byAdding: .hour, value: 12, to: start)!
        let evening = calendar.date(byAdding: .hour, value: 18, to: start)!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let sheep = [
            SheepPresenceSnapshot(sheepID: firstSheep, initialPenID: penA, enteredAt: start, removedAt: nil),
            SheepPresenceSnapshot(sheepID: secondSheep, initialPenID: penA, enteredAt: noon, removedAt: evening)
        ]
        let transfers = [TransferSnapshot(sheepID: firstSheep, toPenID: penB, occurredAt: noon, stableID: UUID())]

        XCTAssertEqual(FarmAnalytics.sheepDays(in: penA, from: start, to: end, sheep: sheep, transfers: transfers, calendar: calendar), Decimal(string: "0.75")!)
        XCTAssertEqual(FarmAnalytics.sheepDays(in: penB, from: start, to: end, sheep: sheep, transfers: transfers, calendar: calendar), Decimal(string: "0.5")!)
    }

    func testCommandWritesOperationAndFarmScopedOutbox() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "test-user", displayName: "测试账户")
        let farm = FarmRecord(ownerAccountID: account.id, name: "北场")
        context.insert(account)
        context.insert(farm)
        try context.save()

        let command = FarmCommandService()
        let farmContext = FarmContext(accountID: account.id, farmID: farm.id, role: .owner)
        try command.execute(.createPen(name: "产羔舍", note: ""), in: farmContext, context: context)

        let pens = try context.fetch(FetchDescriptor<PenRecord>())
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
        XCTAssertEqual(pens.filter { $0.farmID == farm.id }.count, 1)
        XCTAssertEqual(operations.filter { $0.farmID == farm.id && $0.kindRawValue == DomainOperationKind.createPen.rawValue }.count, 1)
        XCTAssertEqual(outbox.filter { $0.farmID == farm.id && $0.accountID == account.id }.count, 1)
    }

    func testWorkerCannotChangeFeedCatalog() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "worker-user", displayName: "测试员工")
        let farm = FarmRecord(ownerAccountID: UUID(), name: "南场", role: .worker)
        context.insert(account)
        context.insert(farm)
        try context.save()

        XCTAssertThrowsError(try FarmCommandService().execute(.addIngredient(name: "玉米", unit: "千克", dryMatterText: nil), in: FarmContext(accountID: account.id, farmID: farm.id, role: .worker), context: context)) { error in
            XCTAssertEqual(error.localizedDescription, FarmPermissionError.denied(.manageCatalogs).localizedDescription)
        }
    }

    func testFarmLocationUsesCommandPipelineAndAllowsOwnerOrAdministrator() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let owner = AccountProfile(appleUserIdentifier: "location-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: owner.id, name: "位置测试场")
        context.insert(owner)
        context.insert(farm)
        try context.save()

        let command = FarmCommand.updateFarmLocation(
            displayName: "北山羊场",
            latitude: 39.9042,
            longitude: 116.4074,
            addressSnapshot: "北京市东城区",
            timeZoneIdentifier: "Asia/Shanghai",
            source: .mapSearch,
            horizontalAccuracyMeters: nil
        )
        let service = FarmCommandService()

        try service.execute(command, in: FarmContext(accountID: owner.id, farmID: farm.id, role: .owner), context: context)
        XCTAssertEqual(farm.locationSnapshot?.displayName, "北山羊场")
        XCTAssertEqual(farm.locationSnapshot?.latitude, 39.9042)
        XCTAssertEqual(farm.locationSnapshot?.longitude, 116.4074)
        XCTAssertEqual(farm.locationSnapshot?.source, .mapSearch)

        try service.execute(
            .updateFarmLocation(
                displayName: "北山羊场东区",
                latitude: 39.9043,
                longitude: 116.4075,
                addressSnapshot: nil,
                timeZoneIdentifier: "Asia/Shanghai",
                source: .manualCoordinate,
                horizontalAccuracyMeters: nil
            ),
            in: FarmContext(accountID: UUID(), farmID: farm.id, role: .administrator),
            context: context
        )
        XCTAssertEqual(farm.locationSnapshot?.displayName, "北山羊场东区")

        XCTAssertThrowsError(
            try service.execute(command, in: FarmContext(accountID: UUID(), farmID: farm.id, role: .worker), context: context)
        ) { error in
            XCTAssertEqual(error.localizedDescription, FarmPermissionError.denied(.editFarmLocation).localizedDescription)
        }

        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        let outbox = try context.fetch(FetchDescriptor<OutboxItem>())
        XCTAssertEqual(operations.filter { $0.kindRawValue == DomainOperationKind.updateFarmLocation.rawValue && $0.entityID == farm.id }.count, 2)
        XCTAssertEqual(outbox.filter { $0.entityID == farm.id && $0.entityType == CloudEntityType.farm.rawValue }.count, 2)
    }

    func testHistoricalTransferDoesNotReplaceCurrentPen() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "owner-user", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "东场")
        let olderPen = PenRecord(farmID: farm.id, name: "老圈")
        let currentPen = PenRecord(farmID: farm.id, name: "新圈")
        let start = Date(timeIntervalSince1970: 1_735_689_600)
        let sheep = SheepRecord(farmID: farm.id, earTag: "A001", breed: "湖羊", sex: .ewe, penID: olderPen.id, enteredAt: start)
        sheep.currentPenID = currentPen.id
        context.insert(account)
        context.insert(farm)
        context.insert(olderPen)
        context.insert(currentPen)
        context.insert(sheep)
        context.insert(TransferRecord(farmID: farm.id, sheepID: sheep.id, fromPenID: olderPen.id, toPenID: currentPen.id, occurredAt: start.addingTimeInterval(10 * 86_400)))
        try context.save()

        try FarmCommandService().execute(.transferSheep(sheepID: sheep.id, toPenID: nil, occurredAt: start.addingTimeInterval(5 * 86_400), note: "补录离圈"), in: FarmContext(accountID: account.id, farmID: farm.id, role: .owner), context: context)

        XCTAssertEqual(sheep.currentPenID, currentPen.id)
    }

    func testHistoryRebuildProjectsRemovalAndDailyPenCounts() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayOne = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let dayThree = calendar.date(byAdding: .day, value: 2, to: dayOne)!
        let account = AccountProfile(appleUserIdentifier: "rebuild-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "重建测试场")
        let pen = PenRecord(farmID: farm.id, name: "育成舍")
        let sheep = SheepRecord(farmID: farm.id, earTag: "R001", breed: "湖羊", purpose: "育成羊", sex: .ewe, penID: pen.id, enteredAt: dayOne)
        let removal = RemovalRecord(farmID: farm.id, sheepID: sheep.id, kind: .sold, reason: "出售", occurredAt: dayThree)
        context.insert(account)
        context.insert(farm)
        context.insert(pen)
        context.insert(sheep)
        context.insert(removal)
        try context.save()

        try FarmHistoryRebuilder(calendar: calendar).rebuild(farmID: farm.id, context: context, from: dayOne, through: dayThree)

        XCTAssertEqual(sheep.status, .removed)
        XCTAssertNil(sheep.currentPenID)
        let daily = try context.fetch(FetchDescriptor<DailyPenCountRecord>())
        XCTAssertEqual(daily.filter { $0.farmID == farm.id && $0.date == dayOne }.first?.count, 1)
        XCTAssertTrue(daily.filter { $0.farmID == farm.id && $0.date == dayTwo }.isEmpty)
        XCTAssertEqual(daily.filter { $0.farmID == farm.id && $0.date == dayThree }.first?.count, 0)
        XCTAssertEqual(
            DailyPenCountTimeline.count(for: pen.id, purpose: sheep.purpose, at: dayTwo, records: daily, calendar: calendar),
            1
        )
        XCTAssertEqual(
            DailyPenCountTimeline.count(for: pen.id, purpose: sheep.purpose, at: dayThree, records: daily, calendar: calendar),
            0
        )
    }

    func testHistoryRebuildIgnoresUnknownLegacyEntrySentinel() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstKnownDay = calendar.date(from: DateComponents(year: 2025, month: 3, day: 1))!
        let endDay = calendar.date(byAdding: .day, value: 1, to: firstKnownDay)!

        let account = AccountProfile(appleUserIdentifier: "unknown-entry-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "未知入场时间测试场")
        let historicalPen = PenRecord(farmID: farm.id, name: "历史羊舍")
        let currentPen = PenRecord(farmID: farm.id, name: "当前羊舍")
        let sheep = SheepRecord(
            farmID: farm.id,
            earTag: "U001",
            breed: "湖羊",
            purpose: "繁殖羊",
            sex: .ewe,
            penID: historicalPen.id,
            enteredAt: .distantPast
        )
        let transfer = TransferRecord(
            farmID: farm.id,
            sheepID: sheep.id,
            fromPenID: historicalPen.id,
            toPenID: currentPen.id,
            occurredAt: firstKnownDay
        )
        let staleCount = DailyPenCountRecord(
            farmID: farm.id,
            penID: historicalPen.id,
            purpose: sheep.purpose,
            date: calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))!,
            count: 99
        )
        context.insert(account)
        context.insert(farm)
        context.insert(historicalPen)
        context.insert(currentPen)
        context.insert(sheep)
        context.insert(transfer)
        context.insert(staleCount)
        try context.save()

        try FarmHistoryRebuilder(calendar: calendar).rebuild(
            farmID: farm.id,
            context: context,
            from: .distantPast,
            through: endDay
        )

        let daily = try context.fetch(FetchDescriptor<DailyPenCountRecord>())
            .filter { $0.farmID == farm.id }
        XCTAssertEqual(Set(daily.map(\.date)), Set([firstKnownDay, endDay]))
        XCTAssertTrue(daily.allSatisfy { $0.penID == currentPen.id && $0.count == 1 })
    }

    func testLegacyMigrationInspectorReportsRequiredSectionsAndCounts() throws {
        let payload = """
        {
          "schemaVersion": "healthManagement",
          "herd": {
            "sheep": [{"tag": "A001"}],
            "pens": [{"name": "产羔舍"}],
            "transfers": [],
            "removals": [],
            "productionBatches": [],
            "batchMemberships": []
          },
          "reproduction": {"lambing": [], "semenRecords": []},
          "feeding": {"feedRecords": [], "feedLibrary": [], "feedRecipes": []},
          "health": {"vaccineRecords": [], "treatmentRecords": []},
          "media": {"photoData": {"A001": "encoded"}}
        }
        """.data(using: .utf8)!

        let report = try LegacyMigrationInspector.inspect(payload)

        XCTAssertTrue(report.isReadyForDryRun)
        XCTAssertEqual(report.schemaVersion, "healthManagement")
        XCTAssertEqual(report.counts.sheep, 1)
        XCTAssertEqual(report.counts.pens, 1)
        XCTAssertEqual(report.counts.photos, 1)
    }

    func testRemovalCanBeRestoredThroughTheSameCommandPipeline() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "restore-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "恢复测试场")
        let pen = PenRecord(farmID: farm.id, name: "基础舍")
        let sheep = SheepRecord(farmID: farm.id, earTag: "R002", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now.addingTimeInterval(-86_400))
        context.insert(account)
        context.insert(farm)
        context.insert(pen)
        context.insert(sheep)
        try context.save()

        let service = FarmCommandService()
        let farmContext = FarmContext(accountID: account.id, farmID: farm.id, role: .owner)
        try service.execute(.removeSheep(sheepID: sheep.id, kind: .sold, reason: "出售", amountText: nil, occurredAt: .now, note: ""), in: farmContext, context: context)
        XCTAssertEqual(sheep.status, .removed)
        XCTAssertNil(sheep.currentPenID)
        XCTAssertEqual(sheep.currentPenDisplayName(pen.name), "已离群")

        let removal = try context.fetch(FetchDescriptor<RemovalRecord>()).first { $0.farmID == farm.id }
        XCTAssertNotNil(removal)
        try service.execute(.restoreSheep(removalID: try XCTUnwrap(removal?.id)), in: farmContext, context: context)
        XCTAssertEqual(sheep.status, .active)
        XCTAssertEqual(sheep.currentPenID, pen.id)
    }

    func testEveryNonPresentStatusHasNoCurrentPen() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "在场规则测试场")
        let pen = PenRecord(farmID: farm.id, name: "育成舍")
        context.insert(farm)
        context.insert(pen)
        for (offset, kind) in [RemovalKind.sold, .culled, .deceased].enumerated() {
            let sheep = SheepRecord(farmID: farm.id, earTag: "P00\(offset)", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now.addingTimeInterval(-86_400))
            context.insert(sheep)
            context.insert(RemovalRecord(farmID: farm.id, sheepID: sheep.id, kind: kind, reason: kind.displayName, occurredAt: .now))
        }
        try context.save()

        try FarmHistoryRebuilder().rebuild(farmID: farm.id, context: context)
        let migrated = try context.fetch(FetchDescriptor<SheepRecord>())
        XCTAssertTrue(migrated.allSatisfy { !$0.isCurrentlyPresent && $0.currentPenID == nil })
        XCTAssertTrue(migrated.allSatisfy { $0.currentPenDisplayName(pen.name) == "已离群" })
    }

    func testHealthConsumptionCannotExceedInventoryBalance() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "inventory-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "库存测试场")
        let pen = PenRecord(farmID: farm.id, name: "治疗舍")
        let sheep = SheepRecord(farmID: farm.id, earTag: "I001", breed: "湖羊", sex: .ewe, penID: pen.id, enteredAt: .now.addingTimeInterval(-86_400))
        let lot = InventoryLotRecord(farmID: farm.id, catalogName: "驱虫药", kind: .treatment, startingQuantityText: "5")
        context.insert(account)
        context.insert(farm)
        context.insert(pen)
        context.insert(sheep)
        context.insert(lot)
        context.insert(InventoryTransactionRecord(farmID: farm.id, inventoryLotID: lot.id, kind: .receipt, quantityText: "5", occurredAt: .now))
        try context.save()

        let service = FarmCommandService()
        let farmContext = FarmContext(accountID: account.id, farmID: farm.id, role: .owner)
        XCTAssertThrowsError(try service.execute(.recordHealth(sheepID: sheep.id, penID: nil, kind: .treatment, itemName: "驱虫药", occurredAt: .now, note: "", inventoryLotID: lot.id, quantityText: "6"), in: farmContext, context: context)) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.insufficientInventory.localizedDescription)
        }

        try service.execute(.recordHealth(sheepID: sheep.id, penID: nil, kind: .treatment, itemName: "驱虫药", occurredAt: .now, note: "", inventoryLotID: lot.id, quantityText: "3"), in: farmContext, context: context)
        let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>())
        XCTAssertEqual(transactions.filter { $0.inventoryLotID == lot.id && $0.kind == .consumption }.count, 1)
    }

    func testTombstoningHealthReversesInventoryAndRestoreReappliesConsumption() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "inventory-reversal-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "库存反冲测试场")
        let sheep = SheepRecord(farmID: farm.id, earTag: "I002", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now.addingTimeInterval(-86_400))
        let lot = InventoryLotRecord(farmID: farm.id, catalogName: "驱虫药", kind: .treatment, startingQuantityText: "5")
        context.insert(account)
        context.insert(farm)
        context.insert(sheep)
        context.insert(lot)
        context.insert(InventoryTransactionRecord(farmID: farm.id, inventoryLotID: lot.id, kind: .receipt, quantityText: "5", occurredAt: .now))
        try context.save()

        let service = FarmCommandService()
        let farmContext = FarmContext(accountID: account.id, farmID: farm.id, role: .owner)
        try service.execute(.recordHealth(sheepID: sheep.id, penID: nil, kind: .treatment, itemName: "驱虫药", occurredAt: .now, note: "", inventoryLotID: lot.id, quantityText: "3"), in: farmContext, context: context)
        let health = try XCTUnwrap(try context.fetch(FetchDescriptor<HealthRecord>()).first { $0.farmID == farm.id })

        try service.execute(.tombstoneEntity(entityType: .health, entityID: health.id, reason: "录入错误"), in: farmContext, context: context)
        XCTAssertNotNil(health.deletedAt)
        let reversal = try XCTUnwrap(try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).first {
            $0.sourceRecordID == health.id && $0.kind == .adjustment && $0.note.hasPrefix("删除健康记录反向恢复库存：")
        })
        XCTAssertEqual(reversal.quantity, 3)
        XCTAssertNil(reversal.deletedAt)

        // The reversal returns the full 5-unit balance, so this would fail without it.
        XCTAssertNoThrow(try service.execute(.recordHealth(sheepID: sheep.id, penID: nil, kind: .treatment, itemName: "驱虫药", occurredAt: .now, note: "", inventoryLotID: lot.id, quantityText: "5"), in: farmContext, context: context))

        let tombstone = try XCTUnwrap(try context.fetch(FetchDescriptor<TombstoneRecord>()).first { $0.entityID == health.id && $0.farmID == farm.id })
        try service.execute(.restoreTombstonedEntity(tombstoneID: tombstone.id), in: farmContext, context: context)
        XCTAssertNil(health.deletedAt)
        XCTAssertNotNil(reversal.deletedAt)
    }

    func testReproductionRequiresEweRamAndKeepsPregnancyCheckFreeOfPaternity() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "reproduction-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "繁殖校验测试场")
        let ewe = SheepRecord(farmID: farm.id, earTag: "E001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        let ram = SheepRecord(farmID: farm.id, earTag: "R001", breed: "湖羊", sex: .ram, penID: nil, enteredAt: .now)
        context.insert(account)
        context.insert(farm)
        context.insert(ewe)
        context.insert(ram)
        try context.save()

        let service = FarmCommandService()
        let farmContext = FarmContext(accountID: account.id, farmID: farm.id, role: .owner)
        XCTAssertThrowsError(try service.execute(.recordReproduction(eweID: ram.id, kind: .breeding, occurredAt: .now, sireID: nil, semenName: "S001", result: "", lambCount: 0, parity: nil, birthDeadCount: nil, offspring: [], note: ""), in: farmContext, context: context)) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.reproductionSubjectMustBeEwe.localizedDescription)
        }
        XCTAssertThrowsError(try service.execute(.recordReproduction(eweID: ewe.id, kind: .breeding, occurredAt: .now, sireID: ewe.id, semenName: nil, result: "", lambCount: 0, parity: nil, birthDeadCount: nil, offspring: [], note: ""), in: farmContext, context: context)) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.reproductionSireMustBeRam.localizedDescription)
        }
        XCTAssertThrowsError(try service.execute(.recordReproduction(eweID: ewe.id, kind: .pregnancyCheck, occurredAt: .now, sireID: ram.id, semenName: nil, result: "阳性", lambCount: 0, parity: nil, birthDeadCount: nil, offspring: [], note: ""), in: farmContext, context: context)) { error in
            XCTAssertEqual(error.localizedDescription, FarmCommandError.pregnancyCheckCannotSetPaternity.localizedDescription)
        }
        XCTAssertNoThrow(try service.execute(.recordReproduction(eweID: ewe.id, kind: .pregnancyCheck, occurredAt: .now, sireID: nil, semenName: nil, result: "阳性", lambCount: 0, parity: nil, birthDeadCount: nil, offspring: [], note: ""), in: farmContext, context: context))
    }

    func testEarTagRemainsUniqueAfterSheepLeavesFarm() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "permanent-tag-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "耳号测试场")
        context.insert(account)
        context.insert(farm)
        try context.save()
        let service = FarmCommandService()
        let farmContext = FarmContext(accountID: account.id, farmID: farm.id, role: .owner)
        try service.execute(.addSheep(earTag: " a001 ", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: .now, birthAt: nil, note: ""), in: farmContext, context: context)
        let sheep = try XCTUnwrap(try context.fetch(FetchDescriptor<SheepRecord>()).first)
        try service.execute(.removeSheep(sheepID: sheep.id, kind: .sold, reason: "出售", amountText: nil, occurredAt: .now, note: ""), in: farmContext, context: context)
        XCTAssertThrowsError(try service.execute(.addSheep(earTag: "A001", breed: "湖羊", sex: .ewe, penID: nil, occurredAt: .now, birthAt: nil, note: ""), in: farmContext, context: context))
    }

    func testDuplicateEarTagAndHistoricalOnlyRecordsAreAutomaticallyResolved() throws {
        let payload = """
        {"schemaVersion":3,"herd":{"sheep":[
          {"tag":"A001","pen":"育成舍","breed":"湖羊","sex":"母","birth":"2025-01-01"},
          {"tag":"A001","pen":"隔离舍","breed":"湖羊","sex":"母","birth":"2025-02-01"}
        ],"transfers":[{"tag":"A001","date":"2025-03-01","from":"育成舍","to":"隔离舍","reason":"测试"}],"removals":[],"weighRecords":[],"customPens":["育成舍","隔离舍"],"productionBatches":[],"batchMemberships":[]},"reproduction":{"lambing":[],"semenRecords":[]}}
        """.data(using: .utf8)!
        let session = try LegacyMigrationImporter.preview(source: payload)
        XCTAssertTrue(session.isReadyForTemporaryBuild)
        XCTAssertEqual(Set(session.sheep.compactMap(\.finalEarTag)), Set(["A001", "A001-02"]))
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        XCTAssertEqual(temporary.reconciliation.convertedSheep, 2)
        XCTAssertEqual(temporary.reconciliation.convertedTransfers, 1)
        let temporaryContext = ModelContext(temporary.container)
        XCTAssertEqual(try temporaryContext.fetch(FetchDescriptor<SheepRecord>()).count, 2)
    }

    func testHistoricalOnlyEarTagCreatesArchivedSheepAutomatically() throws {
        let payload = """
        {"schemaVersion":3,"herd":{"sheep":[{"tag":"A001","pen":"基础舍"}],"transfers":[],"removals":[{"tag":"H001","date":"2025-01-02","type":"出售","reason":"历史出售","amount":100}],"weighRecords":[],"productionBatches":[],"batchMemberships":[]},"reproduction":{"lambing":[],"semenRecords":[]}}
        """.data(using: .utf8)!
        let session = try LegacyMigrationImporter.preview(source: payload)
        let archive = try XCTUnwrap(session.sheep.first { $0.legacyEarTag == "H001" })
        XCTAssertTrue(archive.isHistoricalArchive == true)
        XCTAssertTrue(session.isReadyForTemporaryBuild)
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let context = ModelContext(temporary.container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SheepRecord>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RemovalRecord>()).count, 1)
    }

    func testMigrationConvertsAbortionIntoStructuredReproductionRecord() throws {
        let payload = """
        {"schemaVersion":3,"herd":{"sheep":[{"tag":"E001","pen":"繁殖舍","sex":"母"}],"transfers":[],"removals":[],"weighRecords":[],"abortionRecords":[{"tag":"E001","date":"2025-03-05","time":"09:20","parity":2,"count":2,"note":"观察恢复"}],"productionBatches":[],"batchMemberships":[]},"reproduction":{"lambing":[],"semenRecords":[]}}
        """.data(using: .utf8)!

        let session = try LegacyMigrationImporter.preview(source: payload)
        XCTAssertTrue(session.isReadyForTemporaryBuild)
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let temporaryContext = ModelContext(temporary.container)
        let record = try XCTUnwrap(try temporaryContext.fetch(FetchDescriptor<ReproductionRecord>()).first)
        XCTAssertEqual(record.kind, .abortion)
        XCTAssertEqual(record.result, "流产")
        XCTAssertEqual(record.lambCount, 2)
        XCTAssertEqual(record.note, "胎次：2；观察恢复")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 3, day: 5, hour: 9, minute: 20)))
        XCTAssertEqual(record.occurredAt, expected)

        let committed = try makeContainer()
        let targetContext = ModelContext(committed)
        let account = AccountProfile(appleUserIdentifier: "abortion-migration-owner", displayName: "场主")
        targetContext.insert(account)
        try targetContext.save()
        _ = try MigrationCommitService().commit(sessionID: session.id, account: account, destinationContext: targetContext)
        XCTAssertEqual(try targetContext.fetch(FetchDescriptor<ReproductionRecord>()).first?.kind, .abortion)
    }

    func testFullLegacyPackageBuildsPersistentTemporaryFarmWithAuditAndPhoto() throws {
        let payload = """
        {
          "schemaVersion": 3,
          "herd": {
            "sheep": [
              {"tag":"A001","pen":"繁殖舍","breed":"湖羊","sex":"母","birth":"2025-01-01"},
              {"tag":"R001","pen":"繁殖舍","breed":"杜泊","sex":"公","birth":"2024-01-01"}
            ], "customPens":["繁殖舍"], "transfers":[], "removals":[],
            "weighRecords":[{"tag":"A001","date":"2025-02-01","weight":45,"sex":"母"}],
            "productionBatches":[{"id":"batch-1","name":"春季育肥","purpose":"育肥","startedDate":"2025-01-01","status":"active","note":""}],
            "batchMemberships":[{"id":"member-1","batchId":"batch-1","sheepTag":"A001","joinedDate":"2025-01-02"}]
          },
          "reproduction": {
            "lambing":[{"date":"2025-03-01","dam":"A001","breed":"湖羊","pen":"繁殖舍","parity":1,"total":1,"male":1,"female":0,"dead":0,"difficult":"顺产","lambs":[{"tag":"L001","sex":"公","weight":4.2}],"semenCode":"S001"}],
            "semenRecords":[{"code":"S001","breed":"杜泊","source":"外购","batchNo":"2025A","dateAdded":"2025-01-01"}]
          },
          "feeding": {
            "feedLibrary":[{"id":"ing-1","name":"玉米","category":"能量","defaultNutrients":{"dryMatter":88},"batches":[]}],
            "feedRecipes":[{"id":"recipe-1","name":"育肥料","components":[{"ingredientId":"ing-1","asFedKgPerDay":1.5}],"note":""}],
            "feedRecords":[{"id":"feed-1","mode":"freeChoice","pen":"繁殖舍","date":"2025-03-02","ingredients":[{"name":"玉米","amount":"12","ingredientId":"ing-1"}],"note":"自由采食"}]
          },
          "health": {
            "vaccineCatalog":[{"id":"vac-1","name":"三联四防"}], "medicineCatalog":[{"id":"med-1","name":"驱虫药"}],
            "inventoryLots":[{"id":"lot-1","itemType":"vaccine","itemId":"vac-1","expiryDate":"2026-01-01","quantityInitial":20}],
            "inventoryTransactions":[{"id":"txn-1","lotId":"lot-1","direction":"in","quantity":20,"date":"2025-01-01"}],
            "vaccineRecords":[{"id":"vac-r1","date":"2025-03-03","mode":"byPen","pen":"繁殖舍","sheepTagsSnapshot":["A001"],"vaccineNameSnapshot":"三联四防","dosePerSheep":1,"note":""}],
            "treatmentRecords":[{"id":"treat-1","date":"2025-03-04","sheepTag":"A001","medicineNameSnapshot":"驱虫药","dose":2,"note":""}]
          },
          "media":{"photoData":{"A001":"AQID"}}, "farmSettings":{"farmName":"演练场"}
        }
        """.data(using: .utf8)!
        let session = try LegacyMigrationImporter.preview(source: payload)
        XCTAssertTrue(session.isReadyForTemporaryBuild)
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let context = ModelContext(temporary.container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedIngredientRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedRecipeRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthRecord>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReproductionRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ProductionBatchRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PhotoAssetRecord>()).count, 1)
        XCTAssertFalse(try context.fetch(FetchDescriptor<MigrationAuditRecord>()).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: MigrationWorkspaceStore.assetsDirectory(for: session.id).appending(path: "photo-0.bin").path(percentEncoded: false)))
    }

    func testStableMigrationIDsAndRebuildKeepTheSameTemporaryResult() throws {
        let payload = """
        {"schemaVersion":3,"herd":{"sheep":[{"tag":"S001","pen":"基础舍","birth":"2025-01-01"}],"transfers":[],"removals":[],"weighRecords":[],"productionBatches":[],"batchMemberships":[]},"reproduction":{"lambing":[],"semenRecords":[]}}
        """.data(using: .utf8)!
        let session = try LegacyMigrationImporter.preview(source: payload)
        let first = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let firstContext = ModelContext(first.container)
        let firstSheepID = try XCTUnwrap(try firstContext.fetch(FetchDescriptor<SheepRecord>()).first?.id)
        let firstAuditIDs = Set(try firstContext.fetch(FetchDescriptor<MigrationAuditRecord>()).map(\.id))

        let second = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let secondContext = ModelContext(second.container)
        XCTAssertEqual(try XCTUnwrap(try secondContext.fetch(FetchDescriptor<SheepRecord>()).first?.id), firstSheepID)
        XCTAssertEqual(Set(try secondContext.fetch(FetchDescriptor<MigrationAuditRecord>()).map(\.id)), firstAuditIDs)
        XCTAssertTrue(MigrationWorkspaceStore.hasActiveBuild(for: session.id))
    }

    func testArchivedSheepDoesNotCreateFalseSheepCountDifference() throws {
        let payload = """
        {"schemaVersion":3,"herd":{"sheep":[{"tag":"A001","pen":"基础舍"}],"transfers":[],"removals":[{"tag":"H001","date":"2025-01-02","type":"出售"}],"weighRecords":[],"productionBatches":[],"batchMemberships":[]},"reproduction":{"lambing":[],"semenRecords":[]}}
        """.data(using: .utf8)!
        let session = try LegacyMigrationImporter.preview(source: payload)
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        XCTAssertEqual(temporary.reconciliation.convertedSheep, 1)
        XCTAssertEqual(temporary.reconciliation.archivalSheep, 1)
        XCTAssertFalse(temporary.reconciliation.discrepancies.contains { $0.category == "羊只" })
    }

    func testMigrationPreservesLegacyTimesAndConvertsWeaningBeforeFormalCommit() throws {
        let payload = """
        {
          "schemaVersion": 3,
          "herd": {
            "sheep": [{"tag":"A001","pen":"育成舍","breed":"湖羊","sex":"母","birth":"2025-01-01"}],
            "customPens":["育成舍","繁殖舍"],
            "transfers":[{"tag":"A001","date":"2025-03-01","time":"08:15","from":"育成舍","to":"繁殖舍","reason":"配种"}],
            "removals":[{"tag":"A001","date":"2025-03-03","time":"16:45","type":"出售","reason":"出售","amount":500}],
            "weighRecords":[{"tag":"A001","date":"2025-02-01","weight":42}],
            "events":[{"id":"event-1","date":"2025-02-02","type":"备注","title":"旧事件","detail":"保留","tags":[],"sheepTag":"A001"}],
            "weanRecords":[{"tag":"A001","sex":"母","weanWeight":28,"weanDate":"2025-02-03","birthDate":"2025-01-01","birthWeight":4,"adg":0.25,"dam":"D001","litterSize":1}],
            "abortionRecords":[{"tag":"A001","date":"2025-02-04","parity":1,"count":1}],
            "productionBatches":[{"id":"batch-1","name":"春季育肥","purpose":"育肥","startedDate":"2025-02-01","startedTime":"07:30","status":"active","note":""}],
            "batchMemberships":[{"id":"member-1","batchId":"batch-1","sheepTag":"A001","joinedDate":"2025-02-01","joinedTime":"07:45"}]
          },
          "reproduction": {"lambing":[],"semenRecords":[],"breedPrograms":[{"id":"program-1","name":"同期发情","steps":[{"id":"step-1","day":1,"action":"打针"}],"createdAt":"2025-01-01"}]},
          "feeding": {"feedLibrary":[{"id":"ing-1","name":"玉米","batches":[]}],"feedRecipes":[],"feedRecords":[{"id":"feed-1","mode":"freeChoice","pen":"繁殖舍","date":"2025-03-01","time":"09:20","ingredients":[{"ingredientId":"ing-1","name":"玉米","amount":10}],"note":""}]}
        }
        """.data(using: .utf8)!

        let session = try LegacyMigrationImporter.preview(source: payload)
        XCTAssertTrue(session.isReadyForTemporaryBuild)
        XCTAssertFalse(session.issues.contains { $0.title == "断奶记录待结构化迁移" })
        XCTAssertFalse(session.issues.contains { $0.title == "配种方案待结构化迁移" })
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let temporaryContext = ModelContext(temporary.container)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        let transfer = try XCTUnwrap(try temporaryContext.fetch(FetchDescriptor<TransferRecord>()).first)
        XCTAssertEqual(calendar.component(.hour, from: transfer.occurredAt), 8)
        XCTAssertEqual(calendar.component(.minute, from: transfer.occurredAt), 15)
        let removal = try XCTUnwrap(try temporaryContext.fetch(FetchDescriptor<RemovalRecord>()).first)
        XCTAssertEqual(calendar.component(.hour, from: removal.occurredAt), 16)
        XCTAssertEqual(calendar.component(.minute, from: removal.occurredAt), 45)
        let feed = try XCTUnwrap(try temporaryContext.fetch(FetchDescriptor<FeedRecord>()).first)
        XCTAssertEqual(calendar.component(.hour, from: feed.occurredAt), 9)
        XCTAssertEqual(calendar.component(.minute, from: feed.occurredAt), 20)
        let membership = try XCTUnwrap(try temporaryContext.fetch(FetchDescriptor<BatchMembershipRecord>()).first)
        XCTAssertEqual(calendar.component(.hour, from: membership.joinedAt), 7)
        XCTAssertEqual(calendar.component(.minute, from: membership.joinedAt), 45)
        let weaning = try XCTUnwrap(try temporaryContext.fetch(FetchDescriptor<WeaningRecord>()).first)
        XCTAssertEqual(weaning.weanWeightText, "28")
        XCTAssertEqual(weaning.birthWeightText, "4")
        XCTAssertEqual(weaning.averageDailyGainText, "0.25")
        XCTAssertEqual(weaning.legacyDamEarTag, "D001")
        XCTAssertEqual(weaning.litterSize, 1)
        let program = try XCTUnwrap(try temporaryContext.fetch(FetchDescriptor<BreedingProgramRecord>()).first)
        XCTAssertEqual(program.name, "同期发情")
        let programStep = try XCTUnwrap(try temporaryContext.fetch(FetchDescriptor<BreedingProgramStepRecord>()).first)
        XCTAssertEqual(programStep.programID, program.id)
        XCTAssertEqual(programStep.dayOffset, 1)
        XCTAssertEqual(programStep.action, "打针")

        let archived = try temporaryContext.fetch(FetchDescriptor<MigrationAuditRecord>()).filter { $0.resolution == "preservedForStructuredMigration" }
        XCTAssertEqual(archived.count, 0)
        XCTAssertEqual(try temporaryContext.fetch(FetchDescriptor<NoteRecord>()).first?.text, "历史备注；旧事件；保留；来源耳号：A001")

        let destination = try AppSchema.makeContainer(name: "time-preserving-migration-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let destinationContext = ModelContext(destination)
        let account = AccountProfile(appleUserIdentifier: "time-preserving-owner", displayName: "场主")
        destinationContext.insert(account)
        try destinationContext.save()
        _ = try MigrationCommitService().commit(sessionID: session.id, account: account, destinationContext: destinationContext)
        let committedArchive = try destinationContext.fetch(FetchDescriptor<MigrationAuditRecord>()).filter {
            $0.sessionID == session.id && $0.resolution == "preservedForStructuredMigration"
        }
        XCTAssertEqual(committedArchive.count, 0)
        XCTAssertEqual(try destinationContext.fetch(FetchDescriptor<WeaningRecord>()).first?.averageDailyGainText, "0.25")
        XCTAssertEqual(try destinationContext.fetch(FetchDescriptor<BreedingProgramStepRecord>()).first?.action, "打针")
        XCTAssertEqual(try destinationContext.fetch(FetchDescriptor<NoteRecord>()).first?.text, "历史备注；旧事件；保留；来源耳号：A001")
    }

    func testMigrationReconcilesTimelineProjectionsAndConvertsStandaloneReproductionEvents() throws {
        let payload = """
        {
          "schemaVersion": 3,
          "herd": {
            "sheep": [{"tag":"E001","sex":"母","pen":"繁殖舍","birth":"2023-01-01"}],
            "weighRecords": [{"tag":"E001","date":"2025-02-01","weight":52}],
            "events": [
              {"id":"event-weight","date":"2025-02-01","type":"称重","title":"称重 52kg","detail":"体重 52kg","tags":[],"sheepTag":"E001"},
              {"id":"event-breed","date":"2025-02-03","type":"配种","title":"配种记录","detail":"冻精:S-001","tags":["冻精:S-001"],"sheepTag":"E001"},
              {"id":"event-program","date":"2025-02-04","type":"配种","title":"配种记录","detail":"程序:同期发情 第2天:打针","tags":[],"sheepTag":"E001"},
              {"id":"event-check","date":"2025-02-25","type":"孕检","title":"孕检","detail":"怀孕 22天","tags":[],"sheepTag":"E001"},
              {"id":"event-note","date":"2025-02-26","type":"备注","title":"观察","detail":"采食正常","tags":["日常"],"sheepTag":"E001"}
            ]
          },
          "reproduction": {"lambing":[],"semenRecords":[],"breedPrograms":[]}
        }
        """.data(using: .utf8)!

        let session = try LegacyMigrationImporter.preview(source: payload)
        XCTAssertTrue(session.isReadyForTemporaryBuild)
        XCTAssertFalse(session.issues.contains { $0.title == "历史事件待结构化迁移" })
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let context = ModelContext(temporary.container)

        XCTAssertEqual(try context.fetch(FetchDescriptor<WeightRecord>()).count, 1)
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>()).sorted { $0.occurredAt < $1.occurredAt }
        XCTAssertEqual(reproduction.map(\.kind), [.breeding, .pregnancyCheck])
        XCTAssertEqual(reproduction.first?.semenNameSnapshot, "S-001")
        let notes = try context.fetch(FetchDescriptor<NoteRecord>()).sorted { $0.occurredAt < $1.occurredAt }
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0.text.contains("第2天:打针") })
        XCTAssertTrue(notes.contains { $0.text.contains("观察") && $0.text.contains("日常") })
        let eventAudits = try context.fetch(FetchDescriptor<MigrationAuditRecord>()).filter { $0.sourceKey.hasPrefix("herd.events[") }
        XCTAssertEqual(eventAudits.count, 5)
        XCTAssertEqual(eventAudits.filter { $0.resolution == "reconciledWithStructuredFact" }.count, 1)
        XCTAssertEqual(eventAudits.filter { $0.resolution == "convertedFromLegacyTimeline" }.count, 2)
        XCTAssertFalse(eventAudits.contains { $0.resolution == "preservedForStructuredMigration" })
        XCTAssertEqual(temporary.reconciliation.expectedByType["繁殖"], 2)
        XCTAssertEqual(temporary.reconciliation.convertedByType["繁殖"], 2)
        XCTAssertFalse(temporary.reconciliation.blockingDiscrepancies.contains { $0.category == "繁殖" })
    }

    func testMigrationPreservesLegacyInHerdAndDepartedStatuses() throws {
        let payload = """
        {
          "schemaVersion": 3,
          "herd": {
            "sheep": [
              {"tag":"A001","sex":"母","pen":"繁殖舍","status":"在群","birth":"2024-01-01"},
              {"tag":"S001","sex":"母","pen":"育肥舍","status":"售卖","birth":"2024-01-02"},
              {"tag":"M001","sex":"公","pen":"——","status":"盘点消失","birth":"2024-01-03"}
            ],
            "removals": [
              {"tag":"S001","date":"2025-02-01","type":"售卖","reason":"出售"}
            ]
          },
          "reproduction": {"lambing":[],"semenRecords":[],"breedPrograms":[]}
        }
        """.data(using: .utf8)!

        let session = try LegacyMigrationImporter.preview(source: payload)
        XCTAssertFalse(session.issues.contains { $0.title == "当前状态与离场历史不一致" })
        var staleSession = session
        staleSession.issues.append(MigrationIssue(severity: .warning, title: "当前状态与离场历史不一致", detail: "旧版本遗留提示", sourceKey: "herd.sheep[1]"))
        try MigrationWorkspaceStore.save(staleSession)
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let context = ModelContext(temporary.container)
        let sheepByTag = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SheepRecord>()).map { ($0.earTag, $0) })
        let refreshedSession = try MigrationWorkspaceStore.load(sessionID: session.id)

        XCTAssertFalse(refreshedSession.issues.contains { $0.title == "当前状态与离场历史不一致" })
        XCTAssertEqual(sheepByTag["A001"]?.status, .active)
        XCTAssertNotNil(sheepByTag["A001"]?.currentPenID)
        XCTAssertEqual(sheepByTag["S001"]?.status, .removed)
        XCTAssertNil(sheepByTag["S001"]?.currentPenID)
        XCTAssertNotNil(sheepByTag["S001"]?.removedAt)
        XCTAssertEqual(sheepByTag["M001"]?.status, .removed)
        XCTAssertNil(sheepByTag["M001"]?.currentPenID)
    }

    func testMigrationKeepsLegacyCurrentStatusAndPenWhenHistoryIsPartial() throws {
        let payload = """
        {
          "schemaVersion": 3,
          "herd": {
            "sheep": [
              {"tag":"A001","sex":"母","pen":"当前繁殖舍","status":"在群","birth":"2022-01-01"},
              {"tag":"B001","sex":"公","pen":"旧舍","status":"出栏","birth":"2021-01-01"},
              {"tag":"C001","sex":"母","pen":"当前育成舍","status":"在场","birth":"2023-01-01"}
            ],
            "customPens": ["当前繁殖舍","当前育成舍","旧舍"],
            "transfers": [
              {"tag":"A001","date":"2023-01-02","time":"08:00","from":"历史入栏","to":"历史转入","reason":"旧记录"}
            ],
            "removals": [
              {"tag":"B001","date":"2024-02-01","time":"09:00","type":"出售","reason":"出售","amount":500},
              {"tag":"C001","date":"2024-03-01","time":"09:00","type":"出售","reason":"旧记录未同步","amount":500}
            ],
            "weighRecords": [], "productionBatches": [], "batchMemberships": []
          },
          "reproduction": {"lambing": [], "semenRecords": []}
        }
        """.data(using: .utf8)!

        let session = try LegacyMigrationImporter.preview(source: payload)
        XCTAssertTrue(session.isReadyForTemporaryBuild)
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let context = ModelContext(temporary.container)
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        let penID = Dictionary(uniqueKeysWithValues: pens.map { ($0.name, $0.id) })
        let a = try XCTUnwrap(sheep.first { $0.earTag == "A001" })
        let b = try XCTUnwrap(sheep.first { $0.earTag == "B001" })
        let c = try XCTUnwrap(sheep.first { $0.earTag == "C001" })

        XCTAssertEqual(a.status, .active)
        XCTAssertEqual(a.currentPenID, penID["当前繁殖舍"])
        XCTAssertEqual(a.initialPenID, penID["历史入栏"])
        XCTAssertEqual(a.legacyStatusSnapshotIsAuthoritative, true)
        XCTAssertEqual(a.legacyPenSnapshotIsAuthoritative, true)
        XCTAssertEqual(b.status, .removed)
        XCTAssertNil(b.currentPenID)
        XCTAssertNotNil(b.removedAt)
        XCTAssertEqual(c.status, .active, "旧版当前状态为在场时，不应被残缺离场历史反向覆盖")
        XCTAssertEqual(c.currentPenID, penID["当前育成舍"])

        let today = Calendar.current.startOfDay(for: .now)
        let todayCounts = try context.fetch(FetchDescriptor<DailyPenCountRecord>()).filter { $0.date == today }
        XCTAssertEqual(todayCounts.first { $0.penID == penID["当前繁殖舍"] }?.count, 1)
        XCTAssertEqual(todayCounts.first { $0.penID == penID["当前育成舍"] }?.count, 1)
    }

    func testWeaningCommandSnapshotsDomainFieldsAndCloudPayload() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "weaning-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "繁殖场")
        let dam = SheepRecord(farmID: farm.id, earTag: "D001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        let lamb = SheepRecord(farmID: farm.id, earTag: "L001", breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .now)
        context.insert(account)
        context.insert(farm)
        context.insert(dam)
        context.insert(lamb)
        try context.save()

        let occurredAt = Date(timeIntervalSince1970: 1_741_000_000)
        let birthAt = occurredAt.addingTimeInterval(-70 * 86_400)
        try FarmCommandService().execute(
            .recordWeaning(sheepID: lamb.id, weanWeightText: "27.5", occurredAt: occurredAt, birthAt: birthAt, birthWeightText: "3.8", averageDailyGainText: "0.339", damID: dam.id, litterSize: 2, note: "健康断奶"),
            in: FarmContext(accountID: account.id, farmID: farm.id, role: .owner),
            context: context
        )

        let record = try XCTUnwrap(try context.fetch(FetchDescriptor<WeaningRecord>()).first)
        XCTAssertEqual(record.sheepID, lamb.id)
        XCTAssertEqual(record.damID, dam.id)
        XCTAssertEqual(record.weanWeightText, "27.5")
        XCTAssertEqual(record.averageDailyGainText, "0.339")
        let operation = try XCTUnwrap(try context.fetch(FetchDescriptor<DomainOperation>()).first { $0.kindRawValue == DomainOperationKind.recordWeaning.rawValue })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(FarmCommandCloudPayload.self, from: operation.payload)
        XCTAssertEqual(operation.entityType, CloudEntityType.weaning.rawValue)
        XCTAssertEqual(payload.identifiers["sheepID"], lamb.id)
        XCTAssertEqual(payload.optionalIdentifiers["damID"] ?? nil, dam.id)
        XCTAssertEqual(payload.strings["weanWeightText"], "27.5")
        XCTAssertEqual(payload.integers["litterSize"], 2)
    }

    func testBreedingProgramCommandPersistsStepsAndCloudPayload() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "breeding-program-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "繁殖场")
        context.insert(account)
        context.insert(farm)
        try context.save()

        let createdAt = Date(timeIntervalSince1970: 1_741_000_000)
        let steps = [
            BreedingProgramStepDraft(id: UUID(), dayOffset: 0, action: "放栓"),
            BreedingProgramStepDraft(id: UUID(), dayOffset: 12, action: "撤栓并配种")
        ]
        try FarmCommandService().execute(
            .createBreedingProgram(name: "同期发情", createdAt: createdAt, steps: steps),
            in: FarmContext(accountID: account.id, farmID: farm.id, role: .owner),
            context: context
        )

        let program = try XCTUnwrap(try context.fetch(FetchDescriptor<BreedingProgramRecord>()).first)
        XCTAssertEqual(program.name, "同期发情")
        XCTAssertEqual(program.createdAt, createdAt)
        let records = try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(records.map(\.dayOffset), [0, 12])
        XCTAssertEqual(records.map(\.action), ["放栓", "撤栓并配种"])
        XCTAssertTrue(records.allSatisfy { $0.programID == program.id })
        let operation = try XCTUnwrap(try context.fetch(FetchDescriptor<DomainOperation>()).first { $0.kindRawValue == DomainOperationKind.createBreedingProgram.rawValue })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(FarmCommandCloudPayload.self, from: operation.payload)
        XCTAssertEqual(operation.entityType, CloudEntityType.breedingProgram.rawValue)
        XCTAssertEqual(payload.strings["name"], "同期发情")
        XCTAssertEqual(payload.breedingProgramSteps.map(\.id), steps.map(\.id))
        XCTAssertEqual(payload.breedingProgramSteps.map(\.dayOffset), [0, 12])
    }

    func testMigrationConvertsVerifiedPedigreeToStableRelationships() throws {
        let payload = """
        {
          "schemaVersion": 3,
          "herd": {
            "sheep": [
              {"tag":"D001","sex":"母","pen":"繁殖舍","birth":"2022-01-01"},
              {"tag":"S001","sex":"公","pen":"种公羊舍","birth":"2021-01-01"},
              {"tag":"L001","sex":"母","pen":"育成舍","birth":"2025-01-01","dam":"D001","sire":"S001"}
            ],
            "customPens":["繁殖舍","种公羊舍","育成舍"],
            "transfers":[],"removals":[],"weighRecords":[],"productionBatches":[],"batchMemberships":[]
          },
          "reproduction":{"lambing":[],"semenRecords":[]}
        }
        """.data(using: .utf8)!

        let session = try LegacyMigrationImporter.preview(source: payload)
        XCTAssertTrue(session.issues.contains { $0.title == "系谱将进行核验转换" })
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        XCTAssertTrue(temporary.reconciliation.blockingDiscrepancies.isEmpty)
        let temporaryContext = ModelContext(temporary.container)
        let sheep = try temporaryContext.fetch(FetchDescriptor<SheepRecord>())
        let dam = try XCTUnwrap(sheep.first { $0.earTag == "D001" })
        let sire = try XCTUnwrap(sheep.first { $0.earTag == "S001" })
        let lamb = try XCTUnwrap(sheep.first { $0.earTag == "L001" })
        XCTAssertEqual(lamb.damID, dam.id)
        XCTAssertEqual(lamb.sireID, sire.id)
        XCTAssertTrue(try temporaryContext.fetch(FetchDescriptor<MigrationAuditRecord>()).contains {
            $0.sourceKey == "herd.sheep[2].pedigree" && $0.resolution == "converted"
        })

        let destination = try AppSchema.makeContainer(name: "pedigree-migration-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let destinationContext = ModelContext(destination)
        let account = AccountProfile(appleUserIdentifier: "pedigree-owner", displayName: "场主")
        destinationContext.insert(account)
        try destinationContext.save()
        let commit = try MigrationCommitService().commit(sessionID: session.id, account: account, destinationContext: destinationContext)
        let committedLamb = try XCTUnwrap(try destinationContext.fetch(FetchDescriptor<SheepRecord>()).first { $0.farmID == commit.farmID && $0.earTag == "L001" })
        XCTAssertEqual(committedLamb.damID, dam.id)
        XCTAssertEqual(committedLamb.sireID, sire.id)
    }

    func testFailedStagingBuildLeavesLastReviewableTemporaryResultUntouched() throws {
        let payload = """
        {"schemaVersion":3,"herd":{"sheep":[{"tag":"A001","pen":"基础舍"}],"transfers":[],"removals":[],"weighRecords":[],"productionBatches":[],"batchMemberships":[]},"reproduction":{"lambing":[],"semenRecords":[]}}
        """.data(using: .utf8)!
        let session = try LegacyMigrationImporter.preview(source: payload)
        let built = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        let originalID = try XCTUnwrap(try ModelContext(built.container).fetch(FetchDescriptor<SheepRecord>()).first?.id)
        let broken = MigrationSession(id: session.id, manifest: session.manifest, sourcePayload: Data("[]".utf8), inspectorReport: session.inspectorReport, sheep: session.sheep, assignments: session.assignments, issues: session.issues)
        try MigrationWorkspaceStore.save(broken)
        defer { try? MigrationWorkspaceStore.save(session) }

        XCTAssertThrowsError(try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id))
        let reopened = try LegacyMigrationImporter.openTemporaryFarm(sessionID: session.id)
        XCTAssertEqual(try XCTUnwrap(try ModelContext(reopened.container).fetch(FetchDescriptor<SheepRecord>()).first?.id), originalID)
    }

    func testFormalMigrationCommitIsAtomicAndIdempotent() throws {
        let payload = """
        {"schemaVersion":3,"herd":{"sheep":[{"tag":"A001","pen":"基础舍","breed":"湖羊","sex":"母"}],"transfers":[],"removals":[],"weighRecords":[{"tag":"A001","date":"2025-01-02","weight":42}],"customPens":["基础舍"],"productionBatches":[],"batchMemberships":[]},"reproduction":{"lambing":[],"semenRecords":[]},"farmSettings":{"farmName":"正式迁移测试场"}}
        """.data(using: .utf8)!
        let session = try LegacyMigrationImporter.preview(source: payload)
        let temporary = try LegacyMigrationImporter.buildTemporaryFarm(sessionID: session.id)
        XCTAssertTrue(temporary.reconciliation.blockingDiscrepancies.isEmpty)

        let destination = try AppSchema.makeContainer(name: "formal-migration-\(UUID().uuidString)", isStoredInMemoryOnly: true)
        let context = ModelContext(destination)
        let account = AccountProfile(appleUserIdentifier: "formal-migration-owner", displayName: "场主")
        context.insert(account)
        try context.save()

        let first = try MigrationCommitService().commit(sessionID: session.id, account: account, destinationContext: context)
        XCTAssertFalse(first.wasAlreadyCommitted)
        let committedFarm = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmRecord>()).filter { $0.id == first.farmID }.first)
        XCTAssertEqual(committedFarm.ownerAccountID, account.effectiveAccountID)
        XCTAssertTrue(committedFarm.isLocalOnlyMigration)
        XCTAssertFalse(committedFarm.isDevelopmentTestFarm)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == first.farmID }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == first.farmID }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MigrationCommitRecord>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutboxItem>()).isEmpty)

        let second = try MigrationCommitService().commit(sessionID: session.id, account: account, destinationContext: context)
        XCTAssertTrue(second.wasAlreadyCommitted)
        XCTAssertEqual(second.farmID, first.farmID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FarmRecord>()).filter { $0.id == first.farmID }.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == first.farmID }.count, 1)
    }

    func testFeedRecordKeepsBatchPriceAndNutrientSnapshotsInItsCloudOperation() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "feed-snapshot-owner", displayName: "场主")
        let farm = FarmRecord(ownerAccountID: account.id, name: "饲喂快照测试场")
        let pen = PenRecord(farmID: farm.id, name: "育肥舍")
        let ingredient = FeedIngredientRecord(
            farmID: farm.id,
            name: "玉米",
            unit: "千克",
            dryMatterText: "88",
            nutrientSnapshotJSON: #"{"crudeProtein":9,"dryMatter":88}"#
        )
        let ingredientBatch = FeedIngredientBatchRecord(
            farmID: farm.id,
            ingredientID: ingredient.id,
            legacySourceKey: "feed-batch-1",
            batchName: "2025 春批",
            purchaseDate: nil,
            supplier: "供应商",
            storageLocation: "仓库",
            pricePerKilogramText: "2.35",
            initialKilogramsText: "1000",
            remainingKilogramsText: "1000",
            note: "",
            isActive: true
        )
        context.insert(account)
        context.insert(farm)
        context.insert(pen)
        context.insert(ingredient)
        context.insert(ingredientBatch)
        try context.save()

        try FarmCommandService().execute(
            .recordFeed(
                penID: pen.id,
                recipeID: nil,
                mode: .limited,
                occurredAt: Date(timeIntervalSince1970: 1_735_689_600),
                lines: [FeedLineDraft(ingredientID: ingredient.id, ingredientBatchID: ingredientBatch.id, kilogramsText: "25")],
                note: "早饲"
            ),
            in: FarmContext(accountID: account.id, farmID: farm.id, role: .owner),
            context: context
        )

        let line = try XCTUnwrap(try context.fetch(FetchDescriptor<FeedRecordLine>()).first)
        XCTAssertEqual(line.ingredientNameSnapshot, "玉米")
        XCTAssertEqual(line.ingredientBatchID, ingredientBatch.id)
        XCTAssertEqual(line.ingredientBatchNameSnapshot, "2025 春批")
        XCTAssertEqual(line.pricePerKilogramTextSnapshot, "2.35")
        XCTAssertEqual(line.nutrientSnapshotJSON, #"{"crudeProtein":9,"dryMatter":88}"#)
        XCTAssertEqual(line.unitSnapshot, "千克")
        XCTAssertEqual(line.dryMatterTextSnapshot, "88")

        ingredient.name = "新玉米"
        ingredient.nutrientSnapshotJSON = #"{"crudeProtein":7,"dryMatter":80}"#
        ingredientBatch.pricePerKilogramText = "3.80"
        try context.save()
        XCTAssertEqual(line.ingredientNameSnapshot, "玉米")
        XCTAssertEqual(line.pricePerKilogramTextSnapshot, "2.35")
        XCTAssertEqual(line.nutrientSnapshotJSON, #"{"crudeProtein":9,"dryMatter":88}"#)

        let operation = try XCTUnwrap(try context.fetch(FetchDescriptor<DomainOperation>()).first { $0.kindRawValue == DomainOperationKind.recordFeed.rawValue })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(FarmCommandCloudPayload.self, from: operation.payload)
        let cloudLine = try XCTUnwrap(payload.feedLines.first)
        XCTAssertEqual(cloudLine.ingredientNameSnapshot, "玉米")
        XCTAssertEqual(cloudLine.ingredientBatchNameSnapshot, "2025 春批")
        XCTAssertEqual(cloudLine.pricePerKilogramTextSnapshot, "2.35")
        XCTAssertEqual(cloudLine.nutrientSnapshotJSON, #"{"crudeProtein":9,"dryMatter":88}"#)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AccountProfile.self, FarmRecord.self, FarmActivity.self, PenRecord.self, SheepRecord.self,
            WeightRecord.self, WeaningRecord.self, BreedingProgramRecord.self, BreedingProgramStepRecord.self, TransferRecord.self, RemovalRecord.self, ProductionBatchRecord.self,
            BatchMembershipRecord.self, DailyPenCountRecord.self, FeedIngredientRecord.self, FeedRecipeRecord.self,
            FeedRecipeComponentRecord.self, FeedRecord.self, FeedRecordLine.self, InventoryLotRecord.self,
            InventoryTransactionRecord.self, HealthRecord.self, ReproductionRecord.self, SemenRecord.self,
            NoteRecord.self, DomainOperation.self, OutboxItem.self,
            TombstoneRecord.self, MigrationCommitRecord.self, MigrationAuditRecord.self, PhotoAssetRecord.self, HealthSubjectLink.self, LambingOffspringRecord.self, FeedIngredientBatchRecord.self, HealthCatalogItemRecord.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
