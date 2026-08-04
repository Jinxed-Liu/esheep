import SwiftData
import XCTest
@testable import eSheepNext

final class FarmRemoteSyncCoordinatorTests: XCTestCase {
    @MainActor
    func testSuccessfulEmptyPullClearsStaleBindingError() async throws {
        let container = try AppSchema.makeContainer(
            name: "remote-no-op-pull-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let binding = FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        )
        binding.lastPulledRevision = 492
        binding.lastErrorCode = "NSURLError:-1200"
        context.insert(binding)
        try context.save()

        let transport = ICloudFarmTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in [] },
            pullOperations: { _, _, revision, _ in
                FarmRemotePullPage(
                    operations: [],
                    cursorRevision: revision,
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
            },
            members: { _ in [] },
            deactivate: { _, _, _ in }
        ))
        let result = try await FarmRemoteSyncCoordinator(
            container: container,
            transport: transport
        ).synchronize(farmID: farmID)

        XCTAssertEqual(result.cursorRevision, 492)
        XCTAssertEqual(result.downloadedOperationCount, 0)
        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<FarmRemoteBinding>()).first
        )
        XCTAssertNil(stored.lastErrorCode)
        XCTAssertNotNil(stored.lastSuccessfulSyncAt)
    }

    func testDuplicateTombstonesForOneOperationAreReducedWithoutTrapping() {
        let farmID = UUID()
        let operationID = UUID()
        let entityID = UUID()
        let accountID = UUID()
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let first = TombstoneRecord(
            farmID: farmID,
            entityType: CloudEntityType.removal.rawValue,
            entityID: entityID,
            deletedByAccountID: accountID,
            reason: "重复删除事实",
            operationID: operationID
        )
        first.deletedAt = later
        let duplicate = TombstoneRecord(
            farmID: farmID,
            entityType: CloudEntityType.removal.rawValue,
            entityID: entityID,
            deletedByAccountID: accountID,
            reason: "重复删除事实",
            operationID: operationID
        )
        duplicate.deletedAt = earlier
        let anotherFarm = TombstoneRecord(
            farmID: UUID(),
            entityType: CloudEntityType.removal.rawValue,
            entityID: entityID,
            deletedByAccountID: accountID,
            reason: "其他牧场",
            operationID: operationID
        )

        let result = FarmRemoteSyncCoordinator.tombstoneDeletedAtByOperationID(
            [first, duplicate, anotherFarm],
            farmID: farmID,
            operationIDs: [operationID]
        )

        XCTAssertEqual(result, [operationID: earlier])
    }

    @MainActor
    func testProviderNeutralEnvelopeRebuildsTheSameBusinessProjection() throws {
        let first = try AppSchema.makeContainer(
            name: "provider-contract-first-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let second = try AppSchema.makeContainer(
            name: "provider-contract-second-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let farmID = UUID()
        let sheepID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let command = FarmCommand.addSheep(
            earTag: "CONTRACT-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            occurredAt: occurredAt,
            birthAt: Date(timeIntervalSince1970: 1_650_000_000),
            currentParity: 3,
            note: "provider-neutral"
        )
        let payload = try FarmCommandCloudPayloadEncoder.encode(command)
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: sheepID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )

        for container in [first, second] {
            let context = ModelContext(container)
            XCTAssertEqual(
                try RemoteDomainApplyService().apply(envelope, context: context),
                .applied(rebuildHistoryFrom: occurredAt)
            )
            try context.save()
        }

        XCTAssertEqual(
            try projectionSummary(container: first, farmID: farmID),
            try projectionSummary(container: second, farmID: farmID)
        )
    }

    @MainActor
    private func projectionSummary(
        container: ModelContainer,
        farmID: UUID
    ) throws -> [String] {
        let context = ModelContext(container)
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farmID
        }
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>()).filter {
            $0.farmID == farmID
        }
        return sheep.map {
            "sheep|\($0.id.uuidString)|\($0.earTag)|\($0.sex.rawValue)|\($0.revision)"
        }.sorted() + reproduction.map {
            "reproduction|\($0.id.uuidString)|\($0.kind.rawValue)|\($0.parity ?? -1)"
        }.sorted()
    }
}
