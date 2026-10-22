import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class ESheepCloudFarmIdentityTests: XCTestCase {
    func testV19UpgradeEnrichesIdentityAndReleasesOnlyTheVerifiedPrefixHold() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "IdentityUpgrade-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "farm.store")
        let farmID = UUID(), assetID = UUID()
        do {
            let schema = Schema(versionedSchema: AppSchemaV19.self)
            XCTAssertFalse(schema.entities.first { $0.name == "ESheepCloudFarmIdentityState" }!.attributes.contains { $0.name == "latinNameVerified" })
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration("identity", schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(old)
            context.insert(FarmRecord(id: farmID, ownerAccountID: UUID(), name: "测试牧场"))
            context.insert(AppSchemaV19.ESheepCloudFarmIdentityState(farmID: farmID, farmGeneration: 3, name: "测试牧场", revision: 2))
            let state = ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .integrityHold)
            state.integrityState = .failed
            state.lastAppliedEventSequence = 7
            state.lastVerifiedEventSequence = 7
            state.integrityFailureTraceID = "legacy-identity-failure"
            context.insert(state)
            let asset = ESheepCloudAssetState(assetID: assetID, farmID: farmID, farmGeneration: 3,
                sheepID: UUID(), contentSHA256: String(repeating: "a", count: 64),
                metadataDigest: String(repeating: "b", count: 64), originalByteCount: 3)
            asset.originalRelativePath = "FarmAssets/pending.heic"
            asset.originalStateRawValue = ESheepCloudAssetTransferState.queued.rawValue
            context.insert(asset)
            context.insert(NoteRecord(farmID: farmID, text: "已有历史", occurredAt: .now))
            try context.save()
        }
        let container = try AppSchema.makeContainer(name: "identity", url: url)
        let page = ESheepCloudEventPageV2(events: [], cloudHead: 7, hasMore: false,
            farmIdentity: .init(farmID: farmID, farmGeneration: 3, name: "测试牧场", revision: 2, latinName: "Test Farm"))
        _ = try await ESheepCloudLocalStore(container: container).applyEventPage(page, farmID: farmID, farmGeneration: 3)
        let verification = ModelContext(container)
        let identity = try XCTUnwrap(verification.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>()).first)
        XCTAssertEqual(identity.latinName, "Test Farm")
        XCTAssertEqual(identity.revision, 2)
        XCTAssertTrue(identity.latinNameVerified)
        let state = try XCTUnwrap(verification.fetch(FetchDescriptor<ESheepCloudFarmState>()).first)
        XCTAssertEqual(state.integrityState, .passed)
        XCTAssertEqual(state.activityState, .active)
        XCTAssertEqual(state.lastAppliedEventSequence, 7)
        XCTAssertNil(state.integrityFailureTraceID)
        XCTAssertNil(state.lastSafeSaveAt)
        let asset = try XCTUnwrap(verification.fetch(FetchDescriptor<ESheepCloudAssetState>()).first)
        XCTAssertEqual(asset.id, assetID)
        XCTAssertEqual(asset.originalRelativePath, "FarmAssets/pending.heic")
        XCTAssertEqual(asset.originalStateRawValue, ESheepCloudAssetTransferState.queued.rawValue)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<NoteRecord>()).first?.text, "已有历史")
    }

    func testKnownEmptyLatinNameStillRejectsSameRevisionChange() throws {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "测试牧场")
        let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3, activityState: .active)
        context.insert(farm); context.insert(state)
        context.insert(ESheepCloudFarmIdentityState(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 2))
        try context.save()
        XCTAssertThrowsError(try ESheepCloudFarmIdentityProjection.apply(.init(farmID: farm.id,
            farmGeneration: 3, name: farm.name, revision: 2, latinName: "Unexpected"), state: state, context: context))
        XCTAssertEqual(ESheepCloudSyncFailure.classify(ESheepCloudMembershipError.malformedResponse).kind, .integrity)
    }

    func testNewIntegrityFailureBlocksLegacyRecoveryEvenAtVerifiedCursor() async throws {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "测试牧场")
        let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3, activityState: .integrityHold)
        state.integrityState = .failed
        let identity = ESheepCloudFarmIdentityState(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 2)
        identity.latinNameVerified = false
        context.insert(farm); context.insert(state); context.insert(identity); try context.save()
        let incoming = ESheepCloudFarmIdentityV2(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 2, latinName: "Test Farm")
        let bad = ESheepCloudEventEnvelopeV2(protocolVersion: 2, schemaVersion: 1, farmID: farm.id,
            farmGeneration: 3, eventSequence: 1, eventID: UUID(), commandID: UUID(),
            sourceCommandDigest: String(repeating: "a", count: 64), stream: .init(type: "photoAsset", id: UUID()),
            payload: .businessCommandApplied(commandKind: "photoAsset.restore", payload: .photo(.restore(assetID: UUID()))),
            affectedFields: [], eventBodyDigest: String(repeating: "b", count: 64),
            beforeDigest: String(repeating: "c", count: 64), afterDigest: String(repeating: "d", count: 64),
            actorAccountID: UUID(), sourceDeviceID: UUID(), sourceDeviceSequence: 1,
            occurredAt: .now, receivedAt: .now, eventDigest: "invalid")
        let store = ESheepCloudLocalStore(container: container)
        do {
            _ = try await store.applyEventPage(.init(events: [bad], cloudHead: 1, hasMore: false, farmIdentity: incoming), farmID: farm.id, farmGeneration: 3)
            XCTFail("Corrupt event must fail")
        } catch { XCTAssertEqual(error as? ESheepCloudContractError, .invalidEventDigest) }
        _ = try await store.applyEventPage(.init(events: [], cloudHead: 0, hasMore: false, farmIdentity: incoming), farmID: farm.id, farmGeneration: 3)
        let verification = ModelContext(container)
        let held = try XCTUnwrap(verification.fetch(FetchDescriptor<ESheepCloudFarmState>()).first)
        XCTAssertEqual(held.integrityState, .failed)
        XCTAssertEqual(held.activityState, .integrityHold)
        XCTAssertEqual(held.lastAppliedEventSequence, 0)
        XCTAssertTrue(try XCTUnwrap(verification.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>()).first).legacyIntegrityRecoveryBlocked)
    }

    func testIdentityEnrichmentDoesNotReleaseUnverifiedBusinessHold() async throws {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "测试牧场")
        let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3, activityState: .integrityHold)
        state.integrityState = .failed
        state.lastAppliedEventSequence = 8
        state.lastVerifiedEventSequence = 7
        let identity = ESheepCloudFarmIdentityState(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 2)
        identity.latinNameVerified = false
        context.insert(farm); context.insert(state); context.insert(identity); try context.save()
        let page = ESheepCloudEventPageV2(events: [], cloudHead: 8, hasMore: false,
            farmIdentity: .init(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 2, latinName: "Test Farm"))
        _ = try await ESheepCloudLocalStore(container: container).applyEventPage(page, farmID: farm.id, farmGeneration: 3)
        let verification = ModelContext(container)
        let held = try XCTUnwrap(verification.fetch(FetchDescriptor<ESheepCloudFarmState>()).first)
        XCTAssertEqual(held.integrityState, .failed)
        XCTAssertEqual(held.activityState, .integrityHold)
        XCTAssertNil(held.lastSafeSaveAt)
    }

    func testEmptySyncPageRenamesOnlyTargetFarmAndPersistsRevision() async throws {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "星露谷牧场")
        let copy = FarmRecord(ownerAccountID: UUID(), name: "星露谷牧场 · 外测审核副本")
        let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3, activityState: .active)
        state.integrityState = .passed
        let note = NoteRecord(farmID: farm.id, text: "原有历史记录", occurredAt: .now)
        context.insert(farm); context.insert(copy); context.insert(state); context.insert(note)
        try context.save()
        let store = ESheepCloudLocalStore(container: container)
        let page = ESheepCloudEventPageV2(events: [], cloudHead: 0, hasMore: false,
            farmIdentity: .init(farmID: farm.id, farmGeneration: 3, name: "吉昊羊场", revision: 1, latinName: "Jihao Farm"))
        let count = try await store.applyEventPage(page, farmID: farm.id, farmGeneration: 3)
        XCTAssertEqual(count, 0)
        let verification = ModelContext(container)
        let farms = try verification.fetch(FetchDescriptor<FarmRecord>())
        XCTAssertEqual(farms.first { $0.id == farm.id }?.name, "吉昊羊场")
        XCTAssertEqual(farms.first { $0.id == copy.id }?.name, "星露谷牧场 · 外测审核副本")
        XCTAssertEqual(try verification.fetch(FetchDescriptor<NoteRecord>()).first?.text, note.text)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>()).first?.revision, 1)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>()).first?.latinName, "Jihao Farm")
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()), 0)
    }

    func testDelayedMetadataCannotRevertNameAndForeignScopeIsRejected() throws {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "吉昊羊场")
        let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3, activityState: .active)
        context.insert(ESheepCloudFarmIdentityState(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 2))
        context.insert(farm); context.insert(state); try context.save()
        try ESheepCloudFarmIdentityProjection.apply(.init(farmID: farm.id, farmGeneration: 3,
            name: "旧名", revision: 1), state: state, context: context)
        XCTAssertEqual(farm.name, "吉昊羊场")
        for identity in [
            ESheepCloudFarmIdentityV2(farmID: UUID(), farmGeneration: 3, name: "其他牧场", revision: 3),
            .init(farmID: farm.id, farmGeneration: 4, name: "错代", revision: 3),
            .init(farmID: farm.id, farmGeneration: 3, name: "同版本不同名称", revision: 2)
        ] {
            XCTAssertThrowsError(try ESheepCloudFarmIdentityProjection.apply(identity, state: state, context: context))
        }
        XCTAssertEqual(farm.name, "吉昊羊场")
    }

    func testLatinNameUsesSameRevisionAndCanBeCleared() throws {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "测试牧场")
        let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3, activityState: .active)
        context.insert(farm); context.insert(state)
        let first = ESheepCloudFarmIdentityV2(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 1, latinName: "Test Farm")
        try ESheepCloudFarmIdentityProjection.apply(first, state: state, context: context)
        try context.save()
        XCTAssertThrowsError(try ESheepCloudFarmIdentityProjection.apply(.init(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 1, latinName: "Different"), state: state, context: context))
        try ESheepCloudFarmIdentityProjection.apply(.init(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 2), state: state, context: context)
        try ESheepCloudFarmIdentityProjection.apply(first, state: state, context: context)
        XCTAssertNil(try context.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>()).first?.latinName)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>()).first?.revision, 2)
        let old = Data("{\"farmID\":\"\(farm.id)\",\"farmGeneration\":3,\"name\":\"Legacy\",\"revision\":0}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ESheepCloudFarmIdentityV2.self, from: old).latinName)
    }

    func testNameValidationAndOldPageDecodingRemainCompatible() throws {
        XCTAssertTrue(ESheepCloudFarmIdentityV2.validName("吉昊羊场"))
        XCTAssertFalse(ESheepCloudFarmIdentityV2.validName(" \n"))
        XCTAssertFalse(ESheepCloudFarmIdentityV2.validName("羊\n场"))
        XCTAssertFalse(ESheepCloudFarmIdentityV2.validName(String(repeating: "羊", count: 81)))
        let oldPage = Data(#"{"events":[],"cloudHead":0,"hasMore":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ESheepCloudEventPageV2.self, from: oldPage).farmIdentity)
    }

    func testSnapshotSeedingCannotOverwriteLiveName() throws {
        let container = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = FarmRecord(ownerAccountID: UUID(), name: "吉昊羊场")
        let state = ESheepCloudFarmState(farmID: farm.id, farmGeneration: 3, activityState: .active)
        context.insert(ESheepCloudFarmIdentityState(farmID: farm.id, farmGeneration: 3, name: farm.name, revision: 1))
        context.insert(farm); context.insert(state); try context.save()
        let oldFarm = FarmRecord(id: farm.id, ownerAccountID: farm.ownerAccountID, name: "星露谷牧场")
        let seed = ESheepCloudFarmSeedV2(farm: oldFarm)
        try ESheepCloudProjectionTransaction.seedFarm(seed, context: context)
        XCTAssertEqual(farm.name, "吉昊羊场")
    }
}
