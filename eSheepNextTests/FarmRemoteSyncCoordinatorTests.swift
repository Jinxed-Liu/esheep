import SwiftData
import XCTest
@testable import eSheepNext

final class FarmRemoteSyncCoordinatorTests: XCTestCase {
    func testLegacyCloudPayloadDecodesMissingLaterCollectionsAsEmpty() throws {
        let data = Data(#"""
        {
            "kind":"addNote",
            "strings":{"text":"legacy"},
            "optionalIdentifiers":{"penID":null},
            "dates":{"occurredAt":"2026-08-03T15:02:57Z"}
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payload = try decoder.decode(
            FarmCommandCloudPayload.self,
            from: data
        )

        XCTAssertEqual(payload.kind, .addNote)
        XCTAssertEqual(payload.strings["text"], "legacy")
        XCTAssertTrue(payload.feedLines.isEmpty)
        XCTAssertTrue(payload.recipeComponents.isEmpty)
        XCTAssertTrue(payload.breedingProgramSteps.isEmpty)
        XCTAssertTrue(payload.lambingOffspring.isEmpty)
        XCTAssertNil(payload.careCommand)
        XCTAssertNil(payload.tmrCommand)
        XCTAssertNil(payload.tmrBaselineSnapshot)
    }

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

    @MainActor
    func testCursorAheadBackfillsMissingTMRFormulaHistory() async throws {
        let sourceContainer = try AppSchema.makeContainer(
            name: "tmr-backfill-source-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let source = ModelContext(sourceContainer)
        let appleIdentifier = "tmr-backfill-\(UUID().uuidString)"
        let account = AccountProfile(
            appleUserIdentifier: appleIdentifier,
            displayName: "TMR 回补测试"
        )
        let farmID = UUID()
        let farm = FarmRecord(id: farmID, ownerAccountID: account.id, name: "TMR 回补牧场")
        let ingredient = FeedIngredientRecord(
            id: UUID(),
            farmID: farmID,
            name: "回补原料",
            unit: "千克",
            category: "精料",
            nutrientSnapshotJSON: "{}",
            kind: .custom
        )
        source.insert(account)
        source.insert(farm)
        // Keep this fixture local-only so creating the source TMR operation
        // does not depend on the production cloud-admission directory.
        source.insert(FarmStorageProfile(farmID: farmID, mode: .localOnly))
        source.insert(ingredient)
        try source.save()

        try FarmCommandService().execute(
            .tmr(.saveFormula(TMRFormulaDraft(
                id: UUID(),
                name: "云端测试配方",
                quantityBasis: .wholeGroupDaily,
                referenceHeadCount: 100,
                components: [
                    TMRFormulaComponentDraft(
                        ingredientID: ingredient.id,
                        quantityText: "100"
                    )
                ]
            ))),
            in: FarmContext(accountID: account.id, farmID: farmID, role: .owner),
            context: source
        )
        let sourceOperation = try XCTUnwrap(
            try source.fetch(FetchDescriptor<DomainOperation>()).first {
                $0.farmID == farmID &&
                    $0.kindRawValue == DomainOperationKind.saveTMRFormula.rawValue
            }
        )
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: try XCTUnwrap(sourceOperation.entityID),
            entityType: sourceOperation.entityType,
            schemaVersion: sourceOperation.schemaVersion,
            revision: sourceOperation.resultingRevision,
            baseRevision: sourceOperation.baseRevision,
            operationID: sourceOperation.id,
            modifiedAt: sourceOperation.createdAt,
            modifiedByAccountID: sourceOperation.accountID,
            modifiedByDeviceID: sourceOperation.modifiedByDeviceID ?? UUID(),
            payload: sourceOperation.payload,
            payloadDigest: sourceOperation.payloadDigest,
            capabilityCertificate: sourceOperation.capabilityCertificate,
            operationSignature: sourceOperation.operationSignature ?? Data(),
            deletedAt: nil
        )

        let targetContainer = try AppSchema.makeContainer(
            name: "tmr-backfill-target-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let target = ModelContext(targetContainer)
        target.insert(AccountProfile(
            id: account.id,
            appleUserIdentifier: appleIdentifier,
            displayName: account.displayName
        ))
        target.insert(FarmRecord(id: farmID, ownerAccountID: account.id, name: farm.name))
        target.insert(FeedIngredientRecord(
            id: ingredient.id,
            farmID: farmID,
            name: ingredient.name,
            unit: ingredient.unit,
            category: ingredient.category,
            nutrientSnapshotJSON: ingredient.nutrientSnapshotJSON,
            kind: .custom
        ))
        let binding = FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: account.id,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        )
        // Simulate the faulty client: the cursor has passed the TMR revision,
        // but no TMR projection or receipt exists locally.
        binding.lastPulledRevision = 99
        target.insert(binding)
        try target.save()

        let transport = ICloudFarmTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in [] },
            pullOperations: { _, _, revision, _ in
                if revision == 0 {
                    return FarmRemotePullPage(
                        operations: [envelope],
                        cursorRevision: envelope.revision,
                        hasMore: false
                    )
                }
                return FarmRemotePullPage(
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
            container: targetContainer,
            transport: transport
        ).synchronize(farmID: farmID)

        XCTAssertEqual(result.downloadedOperationCount, 1)
        XCTAssertEqual(
            try target.fetch(FetchDescriptor<TMRFormulaProfileRecord>()).first?.formulaRevision,
            1
        )
        XCTAssertEqual(
            try target.fetch(FetchDescriptor<FeedRecipeRecord>()).first?.name,
            "云端测试配方"
        )
        XCTAssertEqual(
            try target.fetch(FetchDescriptor<DomainOperation>()).filter {
                $0.kindRawValue == DomainOperationKind.saveTMRFormula.rawValue
            }.count,
            1
        )
        XCTAssertEqual(
            try target.fetch(FetchDescriptor<FarmRemoteBinding>()).first?.lastPulledRevision,
            99
        )
    }

    @MainActor
    func testRestoreCatchUpPullsPreparingBindingWithoutUploading() async throws {
        let container = try AppSchema.makeContainer(
            name: "restore-pull-only-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let binding = FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            provider: .supabase,
            state: .preparing,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        )
        binding.lastPulledRevision = 842
        context.insert(binding)
        try context.save()

        let transport = ICloudFarmTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in
                throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
            },
            pullOperations: { _, _, revision, _ in
                FarmRemotePullPage(
                    operations: [],
                    cursorRevision: max(revision, 847),
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
        ).catchUpRestoredFarm(farmID: farmID)

        XCTAssertEqual(result.uploadedOperationCount, 0)
        XCTAssertEqual(result.cursorRevision, 847)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first?.state,
            .preparing
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first?.lastPulledRevision,
            847
        )
    }

    @MainActor
    func testNormalSyncQuarantinesOutboxFromRevokedMember() async throws {
        let container = try AppSchema.makeContainer(
            name: "revoked-member-outbox-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let revokedMemberID = UUID()
        context.insert(FarmRecord(
            id: farmID,
            ownerAccountID: ownerID,
            name: "恢复牧场",
            role: .owner
        ))
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .supabase,
            authorityGeneration: 1
        ))
        context.insert(FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            provider: .supabase,
            state: .active,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        ))
        context.insert(FarmMembershipBinding(
            serverMembershipID: "revoked-member",
            farmID: farmID,
            accountID: revokedMemberID,
            role: .worker,
            status: .revoked
        ))
        let outbox = OutboxItem(
            farmID: farmID,
            accountID: revokedMemberID,
            operationID: UUID(),
            entityType: CloudEntityType.note.rawValue,
            entityID: UUID(),
            deliveryProvider: .supabase,
            authorityGeneration: 1
        )
        outbox.statusRawValue = OutboxStatus.retryableFailure.rawValue
        outbox.errorMessage = "operation_identity_mismatch"
        context.insert(outbox)
        try context.save()

        let transport = ICloudFarmTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in
                throw FarmRemoteTransportError.unsupportedICloudBridgeOperation
            },
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
        _ = try await FarmRemoteSyncCoordinator(
            container: container,
            transport: transport
        ).synchronize(farmID: farmID)

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<OutboxItem>())
                .first { $0.id == outbox.id }
        )
        XCTAssertEqual(stored.status, .quarantinedMembershipRevoked)
        XCTAssertEqual(stored.errorMessage, "membership_revoked")
        XCTAssertNil(stored.nextRetryAt)
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
