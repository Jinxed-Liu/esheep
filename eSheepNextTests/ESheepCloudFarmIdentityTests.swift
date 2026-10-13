import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class ESheepCloudFarmIdentityTests: XCTestCase {
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
            farmIdentity: .init(farmID: farm.id, farmGeneration: 3, name: "吉昊羊场", revision: 1))
        let count = try await store.applyEventPage(page, farmID: farm.id, farmGeneration: 3)
        XCTAssertEqual(count, 0)
        let verification = ModelContext(container)
        let farms = try verification.fetch(FetchDescriptor<FarmRecord>())
        XCTAssertEqual(farms.first { $0.id == farm.id }?.name, "吉昊羊场")
        XCTAssertEqual(farms.first { $0.id == copy.id }?.name, "星露谷牧场 · 外测审核副本")
        XCTAssertEqual(try verification.fetch(FetchDescriptor<NoteRecord>()).first?.text, note.text)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<ESheepCloudFarmIdentityState>()).first?.revision, 1)
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
