import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class ReproductionManagementPersistenceTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, ModelContext, AccountProfile, FarmRecord, PenRecord, SheepRecord) {
        let container = try AppSchema.makeContainer(name: "ReproductionPersistence-\(UUID())", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "隔离繁殖测试")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: "隔离测试场")
        let pen = PenRecord(farmID: farm.id, name: "繁殖一舍")
        let sheep = SheepRecord(farmID: farm.id, earTag: "TEST-EWE", breed: "湖羊", sex: .ewe, penID: pen.id,
            enteredAt: Date(timeIntervalSince1970: 1_600_000_000), birthAt: Date(timeIntervalSince1970: 1_500_000_000))
        context.insert(account); context.insert(farm); context.insert(pen); context.insert(sheep)
        context.insert(FarmStorageProfile(farmID: farm.id, mode: .localOnly))
        context.insert(ReproductionRecord(farmID: farm.id, eweID: sheep.id, kind: .parityBaseline,
            occurredAt: sheep.enteredAt, parity: 0))
        try context.save()
        return (container, context, account, farm, pen, sheep)
    }
    private func settings(pen: PenRecord, sheep: SheepRecord) -> ReproductionManagementSettings {
        var value = ReproductionManagementSettings()
        value.scopeConfigured = true; value.selectedPenIDs = [pen.id]
        value.setUsage(.breeding, for: pen.id)
        value.youthBreedingConfirmedSheepIDs = [sheep.id]
        value.postpartumReminderDays = 90; value.postpartumWarningDays = 120
        value.maidenReminderMonths = 10; value.maidenWarningMonths = 12
        return value
    }

    func testSettingsUseAuditedCommandAndDoNotEnableUnrelatedRules() throws {
        let (_, context, account, farm, pen, sheep) = try fixture()
        let value = settings(pen: pen, sheep: sheep)
        try ReproductionManagementSettingsService.save(value, expected: nil, accountID: account.effectiveAccountID, farm: farm, context: context)
        let rule = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first)
        XCTAssertEqual(try ReproductionManagementSettings.decode(rule.reproductionSettingsJSON), try value.validated())
        XCTAssertNil(rule.operationalAlertsConfiguredAt)
        XCTAssertNil(rule.weaningAgeDays)
        XCTAssertFalse(rule.alertDigestEnabled)
        let operation = try XCTUnwrap(try context.fetch(FetchDescriptor<DomainOperation>()).last)
        XCTAssertEqual(operation.entityType, CloudEntityType.careRule.rawValue)
        XCTAssertTrue(operation.summary.contains("青年母羊参配确认"))
        let decoded = try FarmCommandCloudPayloadDecoder.decode(operation.payload)
        guard case .care(.updateOperationalAlertRules(let draft)) = decoded else { return XCTFail("Wrong audited command") }
        XCTAssertEqual(draft.reproductionSettings, try value.validated())
        XCTAssertEqual(draft.updatesReproductionOnly, true)
    }

    func testOldRuleCommandsPreserveNewSettingsAndConcurrentSettingsEditsFail() throws {
        let (_, context, account, farm, pen, sheep) = try fixture()
        let value = settings(pen: pen, sheep: sheep)
        try ReproductionManagementSettingsService.save(value, expected: nil, accountID: account.effectiveAccountID, farm: farm, context: context)
        let rule = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first)
        let owner = FarmContext(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner)
        try FarmCommandService().execute(.care(.updateOperationalAlertRules(.init(id: rule.id, pregnancyCheckDays: 42,
            gestationDays: 151, weaningAgeDays: 65, warningLeadDays: 5, digestEnabled: true, digestMinuteOfDay: 510))), in: owner, context: context)
        XCTAssertEqual(try ReproductionManagementSettings.decode(rule.reproductionSettingsJSON), try value.validated())
        var edited = value; edited.minimumAgeMonths = 9
        try ReproductionManagementSettingsService.save(edited, expected: try value.validated(), accountID: account.effectiveAccountID, farm: farm, context: context)
        XCTAssertEqual(rule.pregnancyCheckDays, 42)
        XCTAssertEqual(rule.weaningAgeDays, 65)
        XCTAssertEqual(rule.alertDigestMinuteOfDay, 510)
        XCTAssertThrowsError(try ReproductionManagementSettingsService.save(value, expected: try value.validated(), accountID: account.effectiveAccountID, farm: farm, context: context)) {
            XCTAssertTrue($0 is ReproductionSettingsError)
        }
        XCTAssertEqual(try ReproductionManagementSettings.decode(rule.reproductionSettingsJSON), try edited.validated())
    }

    func testPermissionsAndForeignFarmReferencesAreRejected() throws {
        let (_, context, account, farm, pen, sheep) = try fixture()
        let value = settings(pen: pen, sheep: sheep)
        farm.roleRawValue = FarmRole.worker.rawValue
        try context.save()
        XCTAssertThrowsError(try ReproductionManagementSettingsService.save(value, expected: nil,
            accountID: account.effectiveAccountID, farm: farm, context: context))
        farm.roleRawValue = FarmRole.owner.rawValue
        try context.save()
        var foreign = value; foreign.selectedPenIDs = [UUID()]
        XCTAssertThrowsError(try ReproductionManagementSettingsService.save(foreign, expected: nil,
            accountID: account.effectiveAccountID, farm: farm, context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FarmCareRuleRecord>()), 0)
    }

    func testPortableBackupAndProviderNeutralBaselinePreservePenUsageAndReadiness() throws {
        let (_, context, account, farm, pen, sheep) = try fixture()
        let value = settings(pen: pen, sheep: sheep)
        try ReproductionManagementSettingsService.save(value, expected: nil, accountID: account.effectiveAccountID, farm: farm, context: context)
        let snapshots = try FarmBaselineSnapshotService().makeProviderNeutralSnapshots(farm: farm, context: context)
        XCTAssertTrue(snapshots.contains { $0.entityType == .careRule })
        let data = try FarmLocalBackupService.export(farmID: farm.id, context: context)
        let preview = try FarmLocalBackupService.preview(data: data)
        let destination = try AppSchema.makeContainer(name: "ReproductionRestore-\(UUID())", isStoredInMemoryOnly: true)
        let target = ModelContext(destination)
        let restoredAccount = AccountProfile(appleUserIdentifier: UUID().uuidString, displayName: "恢复测试")
        let restoredFarm = FarmRecord(ownerAccountID: restoredAccount.effectiveAccountID, name: "恢复测试场")
        target.insert(restoredAccount); target.insert(restoredFarm)
        try target.save()
        _ = try FarmLocalBackupService.restore(preview, into: restoredFarm, account: restoredAccount, context: target)
        let rule = try XCTUnwrap(try target.fetch(FetchDescriptor<FarmCareRuleRecord>()).first)
        XCTAssertEqual(try ReproductionManagementSettings.decode(rule.reproductionSettingsJSON), try value.validated())
        XCTAssertEqual(rule.farmID, restoredFarm.id)
        XCTAssertEqual(try target.fetch(FetchDescriptor<PenRecord>()).first?.id, pen.id)
        XCTAssertEqual(try target.fetch(FetchDescriptor<SheepRecord>()).first?.id, sheep.id)
    }

    func testNewAndFieldlessLegacyCheckpointsPreserveOriginalBusinessDigest() async throws {
        for configured in [false, true] {
            let (_, context, account, farm, pen, sheep) = try fixture()
            let value = settings(pen: pen, sheep: sheep)
            let rule = FarmCareRuleRecord(farmID: farm.id,
                reproductionSettingsJSON: configured ? try value.encodedJSON() : nil)
            context.insert(rule)
            let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3)
            state.integrityState = .passed
            context.insert(state)
            try context.save()
            let adapter = try XCTUnwrap(ESheepCloudCheckpointRegistry.adapters.first { $0.name == "FarmCareRuleRecord" })
            let sourceRows = try adapter.exportRows(farm.id, context)
            XCTAssertEqual(sourceRows.first?.values["reproductionSettingsJSON"] != nil, configured)
            let root = FileManager.default.temporaryDirectory.appending(path: "ReproductionCheckpoint-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = root.appending(path: "archive")
            let manifest = try ESheepCloudCheckpointArchive.export(farmID: farm.id, context: context, directory: archive)
            XCTAssertEqual(manifest.minimumClientCapability, 1)
            let importer = try ESheepCloudCheckpointImporter(manifest: manifest, accountID: account.effectiveAccountID,
                storeURL: root.appending(path: "verified.store"))
            for chunk in manifest.chunks {
                try await importer.importChunk(Data(contentsOf: archive.appending(path: String(format: "%05d.json.gz", chunk.index))), index: chunk.index)
            }
            try await importer.finish()
            let restored = try await importer.records(model: "FarmCareRuleRecord")
            XCTAssertEqual(restored, sourceRows)
        }
    }

    func testCheckpointAdapterStillRejectsMissingRequiredOrUnknownFields() throws {
        let (_, context, _, farm, _, _) = try fixture()
        let rule = FarmCareRuleRecord(farmID: farm.id)
        context.insert(rule); try context.save()
        let adapter = try XCTUnwrap(ESheepCloudCheckpointRegistry.adapters.first { $0.name == "FarmCareRuleRecord" })
        let row = try XCTUnwrap(try adapter.exportRows(farm.id, context).first)
        let other = try AppSchema.makeContainer(name: "ReproductionInvalidCheckpoint-\(UUID())", isStoredInMemoryOnly: true)
        let target = ModelContext(other)
        var missing = row.values; missing.removeValue(forKey: "pregnancyCheckDays")
        XCTAssertThrowsError(try adapter.insertRow(.init(model: row.model, values: missing), farm.id, target))
        var unknown = row.values; unknown["unrecognisedBusinessField"] = .string("x")
        XCTAssertThrowsError(try adapter.insertRow(.init(model: row.model, values: unknown), farm.id, target))
    }

    func testOperationalSnapshotUsesSameScopeAndOneAlertPerEwe() async throws {
        let (container, context, account, farm, pen, sheep) = try fixture()
        var value = settings(pen: pen, sheep: sheep)
        value.maidenReminderMonths = 10; value.maidenWarningMonths = 12
        let rule = FarmCareRuleRecord(farmID: farm.id, weaningAgeDays: 60, operationalAlertsConfiguredAt: .now,
            reproductionSettingsJSON: try value.encodedJSON())
        context.insert(rule)
        let check = ReproductionRecord(farmID: farm.id, eweID: sheep.id, kind: .breeding,
            occurredAt: Date.now.addingTimeInterval(-60 * 86_400))
        context.insert(check)
        let otherPen = PenRecord(farmID: farm.id, name: "未选舍")
        let other = SheepRecord(farmID: farm.id, earTag: "OUTSIDE", breed: "湖羊", sex: .ewe,
            penID: otherPen.id, enteredAt: sheep.enteredAt, birthAt: sheep.birthAt)
        context.insert(otherPen); context.insert(other)
        context.insert(ReproductionRecord(farmID: farm.id, eweID: other.id, kind: .breeding, occurredAt: check.occurredAt))
        try context.save()
        let snapshot = try await FarmOperationalAlertSnapshotActor(container: container).load(farmID: farm.id)
        XCTAssertTrue(snapshot.reproductionConfigured)
        XCTAssertEqual(Set(snapshot.operationalAlerts.filter { $0.kind.isReproductionManagement }.map(\.subjectID)), Set([sheep.id, other.id]))
        XCTAssertEqual(snapshot.operationalAlerts.first { $0.subjectID == other.id && $0.kind.isReproductionManagement }?.kind, .reproductionReview)
        XCTAssertFalse(snapshot.operationalAlerts.contains { $0.kind == .pregnancyCheckOverdue })
        let alert = try XCTUnwrap(snapshot.operationalAlerts.first { $0.subjectID == sheep.id })
        XCTAssertTrue(alert.detail.contains("青年母羊"))
        XCTAssertTrue(alert.detail.contains("配种后"))
        try FarmCommandService().execute(.care(.deferOperationalAlert(.init(id: UUID(), alertID: alert.id,
            alertKindRawValue: alert.kind.rawValue, subjectID: sheep.id, sourceEntityID: alert.sourceEntityID,
            conditionFingerprint: alert.conditionFingerprint, deferredUntil: Date.now.addingTimeInterval(86_400)))),
            in: .init(accountID: account.effectiveAccountID, farmID: farm.id, role: .owner), context: context)
        let deferred = try await FarmOperationalAlertSnapshotActor(container: container).load(farmID: farm.id)
        XCTAssertEqual(deferred.operationalAlerts.filter { $0.kind.isReproductionManagement }.map(\.subjectID), [other.id])
    }

    func testAuthoritativeV2ReplayCarriesNewSettingsAndLegacyRuleUpdatePreservesThem() throws {
        let (_, context, account, farm, pen, sheep) = try fixture()
        let value = try settings(pen: pen, sheep: sheep).validated()
        let ruleID = UUID(), deviceID = UUID()
        let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3)
        state.integrityState = .passed
        context.insert(state); try context.save()
        var previousDigest = try ESheepCloudCanonicalCodec.digest([String: ESheepCloudValueV2]())
        func event(_ draftValue: FarmOperationalAlertRuleDraft, sequence: Int64) throws -> ESheepCloudEventEnvelopeV2 {
            let draft = try ESheepCloudCommandFactoryV2.make(command: .care(.updateOperationalAlertRules(draftValue)),
                farmID: farm.id, primaryEntityType: CloudEntityType.careRule.rawValue, primaryEntityID: ruleID)
            XCTAssertEqual(draft.kind, "care.operationalAlertRules.update")
            XCTAssertEqual(draft.affectedFieldKeys, draftValue.updatesReproductionOnly == true ? ["reproductionSettings"] : ["rules"])
            let commandID = UUID(), eventID = UUID()
            let source = try ESheepCloudCanonicalCodec.digest(draft.payload)
            let after = try ESheepCloudCanonicalCodec.digest(ESheepCloudNonFieldStreamStateV2(eventCount: sequence,
                lastCommandDigest: source, lastCommandID: commandID.uuidString.lowercased(), lastCommandKind: draft.kind))
            func envelope(_ digest: String) -> ESheepCloudEventEnvelopeV2 {
                .init(protocolVersion: 2, schemaVersion: 1, farmID: farm.id, farmGeneration: 3,
                    eventSequence: sequence, eventID: eventID, commandID: commandID, sourceCommandDigest: source,
                    stream: draft.affectedStreams[0], payload: .businessCommandApplied(commandKind: draft.kind, payload: draft.payload),
                    affectedFields: draft.affectedFieldKeys, eventBodyDigest: String(repeating: "d", count: 64),
                    beforeDigest: previousDigest, afterDigest: after, actorAccountID: account.effectiveAccountID,
                    sourceDeviceID: deviceID, sourceDeviceSequence: sequence, occurredAt: draft.occurredAt,
                    receivedAt: draft.occurredAt.addingTimeInterval(1), eventDigest: digest)
            }
            let result = envelope(ESheepCloudEventDigestV2.hex(for: envelope("")))
            previousDigest = after
            return result
        }
        let first = try event(.init(id: ruleID, pregnancyCheckDays: 45, gestationDays: 150, weaningAgeDays: 60,
            digestEnabled: false, digestMinuteOfDay: 480, reproductionSettings: value, updatesReproductionOnly: true), sequence: 1)
        _ = try ESheepCloudEventReducer.apply(first, context: context)
        let rule = try XCTUnwrap(try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first)
        XCTAssertEqual(try ReproductionManagementSettings.decode(rule.reproductionSettingsJSON), value)
        XCTAssertNil(rule.operationalAlertsConfiguredAt)
        let second = try event(.init(id: ruleID, pregnancyCheckDays: 42, gestationDays: 151, weaningAgeDays: 65,
            warningLeadDays: 5, digestEnabled: true, digestMinuteOfDay: 510), sequence: 2)
        _ = try ESheepCloudEventReducer.apply(second, context: context)
        XCTAssertEqual(try ReproductionManagementSettings.decode(rule.reproductionSettingsJSON), value)
        XCTAssertEqual(rule.pregnancyCheckDays, 42)
        XCTAssertEqual(rule.weaningAgeDays, 65)
        XCTAssertEqual(state.lastAppliedEventSequence, 2)
    }
}
