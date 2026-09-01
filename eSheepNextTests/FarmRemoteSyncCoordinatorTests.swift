import SwiftData
import XCTest
@testable import eSheepNext

private struct TestFarmRemoteTransportEndpoints: Sendable {
    let establishBaseline: @Sendable (FarmRemoteBaseline) async throws -> Void
    let pushOperations: @Sendable ([CloudOperationEnvelope], Int) async throws -> [FarmRemoteOperationReceipt]
    let pullOperations: @Sendable (UUID, Int, Int, Int) async throws -> FarmRemotePullPage
    let uploadAsset: @Sendable (UUID, Int, UUID, Data, String, String) async throws -> FarmRemoteAsset
    let downloadAsset: @Sendable (FarmRemoteAsset) async throws -> Data
    let members: @Sendable (UUID) async throws -> [FarmRemoteMember]
    let deactivate: @Sendable (UUID, Int, Bool) async throws -> Void
}

private actor TestFarmRemoteTransport: FarmRemoteTransport {
    nonisolated let provider = FarmRemoteProvider.supabase
    private let endpoints: TestFarmRemoteTransportEndpoints

    init(endpoints: TestFarmRemoteTransportEndpoints) {
        self.endpoints = endpoints
    }

    func establishBaseline(_ baseline: FarmRemoteBaseline) async throws {
        try await endpoints.establishBaseline(baseline)
    }

    func pushOperations(
        _ operations: [CloudOperationEnvelope],
        authorityGeneration: Int
    ) async throws -> [FarmRemoteOperationReceipt] {
        try await endpoints.pushOperations(operations, authorityGeneration)
    }

    func pullOperations(
        farmID: UUID,
        authorityGeneration: Int,
        after revision: Int,
        limit: Int
    ) async throws -> FarmRemotePullPage {
        try await endpoints.pullOperations(
            farmID,
            authorityGeneration,
            revision,
            max(1, limit)
        )
    }

    func uploadAsset(
        farmID: UUID,
        authorityGeneration: Int,
        assetID: UUID,
        data: Data,
        sha256: String,
        contentType: String
    ) async throws -> FarmRemoteAsset {
        try await endpoints.uploadAsset(
            farmID,
            authorityGeneration,
            assetID,
            data,
            sha256,
            contentType
        )
    }

    func downloadAsset(_ asset: FarmRemoteAsset) async throws -> Data {
        try await endpoints.downloadAsset(asset)
    }

    func members(farmID: UUID) async throws -> [FarmRemoteMember] {
        try await endpoints.members(farmID)
    }

    func deactivate(
        farmID: UUID,
        authorityGeneration: Int,
        archive: Bool
    ) async throws {
        try await endpoints.deactivate(farmID, authorityGeneration, archive)
    }
}

final class FarmRemoteSyncCoordinatorTests: XCTestCase {
    func testPedigreeUploadIsQuarantinedWhenBreedingRamPrerequisiteConflicts() throws {
        let farmID = UUID()
        let ramID = UUID()
        let childID = UUID()
        let unrelatedSheepID = UUID()
        let conflictID = UUID()
        let pedigreeID = UUID()
        let dependentProfileID = UUID()
        let unrelatedID = UUID()

        func pending(
            id: UUID,
            entityID: UUID,
            sequence: Int64,
            command: FarmCommand,
            baseRevision: Int = 1,
            resultingRevision: Int = 2
        ) throws -> FarmRemotePendingOperation {
            let payload = try FarmCommandCloudPayloadEncoder.encode(command)
            return FarmRemotePendingOperation(
                envelope: CloudOperationEnvelope(
                    farmID: farmID,
                    entityID: entityID,
                    entityType: CloudEntityType.sheep.rawValue,
                    schemaVersion: 2,
                    revision: resultingRevision,
                    baseRevision: baseRevision,
                    operationID: id,
                    modifiedAt: .now,
                    modifiedByAccountID: UUID(),
                    modifiedByDeviceID: UUID(),
                    payload: payload,
                    payloadDigest: CloudPayloadDigest.hex(for: payload),
                    capabilityCertificate: "test",
                    operationSignature: Data(),
                    deletedAt: nil
                ),
                clientSequence: sequence
            )
        }

        let operations = try [
            pending(
                id: conflictID,
                entityID: ramID,
                sequence: 96,
                command: .care(.setBreedingRam(
                    sheepID: ramID,
                    isBreedingRam: true,
                    expectedRevision: 1
                ))
            ),
            pending(
                id: pedigreeID,
                entityID: childID,
                sequence: 97,
                command: .care(.updateSheepPedigree(.init(
                    sheepID: childID,
                    damID: nil,
                    sireID: ramID,
                    semenDonorID: nil,
                    reason: "选择父本",
                    expectedRevision: 1
                )))
            ),
            pending(
                id: dependentProfileID,
                entityID: childID,
                sequence: 98,
                command: .updateSheepProfile(
                    sheepID: childID,
                    earTag: "CHILD",
                    breed: "寒羊",
                    sex: .ewe,
                    birthAt: nil,
                    currentParity: nil,
                    parityRecordedAt: nil,
                    note: "依赖系谱修订"
                ),
                baseRevision: 2,
                resultingRevision: 3
            ),
            pending(
                id: unrelatedID,
                entityID: unrelatedSheepID,
                sequence: 99,
                command: .updateSheepProfile(
                    sheepID: unrelatedSheepID,
                    earTag: "UNRELATED",
                    breed: "湖羊",
                    sex: .ewe,
                    birthAt: nil,
                    currentParity: nil,
                    parityRecordedAt: nil,
                    note: ""
                )
            ),
        ]

        XCTAssertEqual(
            FarmRemoteSyncCoordinator.causallyDependentOperationIDs(
                afterConflict: conflictID,
                in: operations
            ),
            [pedigreeID, dependentProfileID]
        )
    }

    func testRebasedBreedingRamQualificationDoesNotPermanentlyBlockLaterPedigree() throws {
        let farmID = UUID()
        let ramID = UUID()
        let childID = UUID()
        let conflictID = UUID()
        let rebasedQualificationID = UUID()
        let pedigreeID = UUID()

        func pending(
            id: UUID,
            entityID: UUID,
            sequence: Int64,
            command: FarmCommand,
            baseRevision: Int,
            resultingRevision: Int
        ) throws -> FarmRemotePendingOperation {
            let payload = try FarmCommandCloudPayloadEncoder.encode(command)
            return FarmRemotePendingOperation(
                envelope: CloudOperationEnvelope(
                    farmID: farmID,
                    entityID: entityID,
                    entityType: CloudEntityType.sheep.rawValue,
                    schemaVersion: 2,
                    revision: resultingRevision,
                    baseRevision: baseRevision,
                    operationID: id,
                    modifiedAt: .now,
                    modifiedByAccountID: UUID(),
                    modifiedByDeviceID: UUID(),
                    payload: payload,
                    payloadDigest: CloudPayloadDigest.hex(for: payload),
                    capabilityCertificate: "test",
                    operationSignature: Data(),
                    deletedAt: nil
                ),
                clientSequence: sequence
            )
        }

        let operations = try [
            pending(
                id: conflictID,
                entityID: ramID,
                sequence: 1,
                command: .care(.setBreedingRam(
                    sheepID: ramID,
                    isBreedingRam: true,
                    expectedRevision: 1
                )),
                baseRevision: 1,
                resultingRevision: 2
            ),
            pending(
                id: rebasedQualificationID,
                entityID: ramID,
                sequence: 2,
                command: .care(.setBreedingRam(
                    sheepID: ramID,
                    isBreedingRam: true,
                    expectedRevision: 5
                )),
                baseRevision: 5,
                resultingRevision: 6
            ),
            pending(
                id: pedigreeID,
                entityID: childID,
                sequence: 3,
                command: .care(.updateSheepPedigree(.init(
                    sheepID: childID,
                    damID: nil,
                    sireID: ramID,
                    semenDonorID: nil,
                    reason: "资格重建后录入",
                    expectedRevision: 1
                ))),
                baseRevision: 1,
                resultingRevision: 2
            ),
        ]

        XCTAssertEqual(
            FarmRemoteSyncCoordinator.causallyDependentOperationIDs(
                afterConflict: conflictID,
                in: operations
            ),
            []
        )
    }

    @MainActor
    func testConflictedPullAdvancesCursorWithoutForgingDurableReceipt() async throws {
        let container = try AppSchema.makeContainer(
            name: "remote-conflict-no-receipt-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let sheepID = UUID()
        let removalID = UUID()
        let removedAt = Date(timeIntervalSince1970: 1_780_500_000)
        context.insert(FarmRecord(
            id: farmID,
            ownerAccountID: ownerID,
            name: "冲突回执测试场"
        ))
        context.insert(SheepRecord(
            id: sheepID,
            farmID: farmID,
            earTag: "CONFLICT-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: removedAt.addingTimeInterval(-86_400)
        ))
        let localRemoval = RemovalRecord(
            id: removalID,
            farmID: farmID,
            sheepID: sheepID,
            kind: .deceased,
            reason: "旧投影",
            occurredAt: removedAt
        )
        localRemoval.deletedAt = removedAt.addingTimeInterval(60)
        localRemoval.revision = 1
        context.insert(localRemoval)
        context.insert(FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            provider: .supabase,
            state: .preparing,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        ))
        try context.save()

        let payload = try FarmCommandCloudPayloadEncoder.encode(
            .removeSheep(
                sheepID: sheepID,
                kind: .deceased,
                reason: "云端权威离场",
                amountText: nil,
                occurredAt: removedAt,
                note: "",
                recordID: removalID
            )
        )
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: removalID,
            entityType: CloudEntityType.removal.rawValue,
            schemaVersion: 2,
            revision: 3,
            baseRevision: 2,
            operationID: UUID(),
            modifiedAt: removedAt.addingTimeInterval(120),
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data([1]),
            deletedAt: nil
        )
        let transport = TestFarmRemoteTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in [] },
            pullOperations: { _, _, _, _ in
                FarmRemotePullPage(
                    operations: [envelope],
                    cursorRevision: 1,
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            members: { _ in [] },
            deactivate: { _, _, _ in }
        ))

        let result = try await FarmRemoteSyncCoordinator(
            container: container,
            transport: transport
        ).catchUpRestoredFarm(farmID: farmID)

        let verification = ModelContext(container)
        XCTAssertEqual(result.conflictCount, 1)
        XCTAssertEqual(result.cursorRevision, 1)
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<DomainOperation>()).isEmpty
        )
        let conflict = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<SyncConflictRecord>()).first
        )
        XCTAssertEqual(conflict.entityID, removalID)
        XCTAssertEqual(conflict.statusRawValue, SyncConflictStatus.unresolved.rawValue)
        XCTAssertNotNil(conflict.remoteEnvelopeData)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first?.lastPulledRevision,
            1
        )

        // Once the missing intervening revision becomes available, startup or
        // the next sync retries the retained envelope and creates the durable
        // receipt only after the projection was actually applied.
        let conflictedRemoval = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<RemovalRecord>()).first
        )
        conflictedRemoval.revision = 2
        try verification.save()
        XCTAssertEqual(
            try RemoteProjectionReceiptRepair.repair(
                farmID: farmID,
                context: verification
            ),
            2
        )
        XCTAssertNil(conflictedRemoval.deletedAt)
        XCTAssertEqual(conflictedRemoval.revision, 3)
        XCTAssertEqual(conflict.statusRawValue, SyncConflictStatus.acceptedRemote.rawValue)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<DomainOperation>()).count,
            1
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SheepRecord>()).first?.status,
            .deceased
        )
    }

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

        let transport = TestFarmRemoteTransport(endpoints: .init(
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
                throw FarmRemoteTransportError.unsupportedOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedOperation
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

        let transport = TestFarmRemoteTransport(endpoints: .init(
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
                throw FarmRemoteTransportError.unsupportedOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedOperation
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

        let transport = TestFarmRemoteTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            pullOperations: { _, _, revision, _ in
                FarmRemotePullPage(
                    operations: [],
                    cursorRevision: max(revision, 847),
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedOperation
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
    func testRestoreRetryTrustsMatchingDurableOperationReceipt() async throws {
        let container = try AppSchema.makeContainer(
            name: "restore-durable-receipt-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let sheepID = UUID()
        let operationID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = try FarmCommandCloudPayloadEncoder.encode(
            .care(.setBreedingRam(
                sheepID: sheepID,
                isBreedingRam: true,
                expectedRevision: 1
            ))
        )
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: sheepID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: operationID,
            modifiedAt: modifiedAt,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: accountID,
            name: "断点恢复牧场"
        )
        let sheep = SheepRecord(
            id: sheepID,
            farmID: farmID,
            earTag: "RECEIPT-RAM",
            breed: "杜泊",
            isBreedingRam: true,
            sex: .ram,
            penID: nil,
            enteredAt: modifiedAt
        )
        // A later operation was already partially persisted before the old
        // restore attempt failed, so replaying this older 1→2 operation would
        // manufacture a conflict unless its durable operation receipt wins.
        sheep.revision = 3
        let receipt = DomainOperation(
            id: operationID,
            farmID: farmID,
            accountID: accountID,
            kind: .care,
            occurredAt: modifiedAt,
            summary: "Supabase 同步：care",
            entityType: CloudEntityType.sheep.rawValue,
            entityID: sheepID,
            baseRevision: 1,
            resultingRevision: 2,
            payload: payload
        )
        let binding = FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            provider: .supabase,
            state: .preparing,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        )
        context.insert(farm)
        context.insert(sheep)
        context.insert(receipt)
        context.insert(binding)
        try context.save()

        let transport = TestFarmRemoteTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in [] },
            pullOperations: { _, _, revision, _ in
                guard revision == 0 else {
                    return FarmRemotePullPage(
                        operations: [],
                        cursorRevision: 3,
                        hasMore: false
                    )
                }
                return FarmRemotePullPage(
                    operations: [envelope],
                    cursorRevision: 3,
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            members: { _ in [] },
            deactivate: { _, _, _ in }
        ))

        let result = try await FarmRemoteSyncCoordinator(
            container: container,
            transport: transport
        ).catchUpRestoredFarm(farmID: farmID)

        let verification = ModelContext(container)
        XCTAssertEqual(result.cursorRevision, 3)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<SheepRecord>())
                .first?.revision,
            3
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<DomainOperation>()).count,
            1
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first?.lastPulledRevision,
            3
        )
    }

    @MainActor
    func testFailedPulledPageRollsBackEveryProjectionAndReceipt() async throws {
        let container = try AppSchema.makeContainer(
            name: "restore-page-atomicity-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let noteID = UUID()
        context.insert(FarmRecord(
            id: farmID,
            ownerAccountID: accountID,
            name: "原子恢复牧场"
        ))
        context.insert(FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: accountID,
            provider: .supabase,
            state: .preparing,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        ))
        try context.save()

        let notePayload = try FarmCommandCloudPayloadEncoder.encode(
            .addNote(
                sheepID: nil,
                penID: nil,
                text: "本页必须整体回滚",
                occurredAt: .now
            )
        )
        let noteEnvelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: noteID,
            entityType: CloudEntityType.note.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: UUID(),
            payload: notePayload,
            payloadDigest: CloudPayloadDigest.hex(for: notePayload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        let missingSheepID = UUID()
        let invalidPayload = try FarmCommandCloudPayloadEncoder.encode(
            .care(.setBreedingRam(
                sheepID: missingSheepID,
                isBreedingRam: true,
                expectedRevision: 1
            ))
        )
        let invalidEnvelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: missingSheepID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: UUID(),
            modifiedAt: .now,
            modifiedByAccountID: accountID,
            modifiedByDeviceID: UUID(),
            payload: invalidPayload,
            payloadDigest: CloudPayloadDigest.hex(for: invalidPayload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        let transport = TestFarmRemoteTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in [] },
            // Deliberately return the same two-operation page while the
            // coordinator narrows its limit. Every failed attempt must leave
            // the persistent store unchanged.
            pullOperations: { _, _, _, _ in
                FarmRemotePullPage(
                    operations: [noteEnvelope, invalidEnvelope],
                    cursorRevision: 2,
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            members: { _ in [] },
            deactivate: { _, _, _ in }
        ))

        do {
            _ = try await FarmRemoteSyncCoordinator(
                container: container,
                transport: transport
            ).catchUpRestoredFarm(farmID: farmID)
            XCTFail("Expected the invalid second operation to fail the page")
        } catch {
            XCTAssertTrue(error is FarmRemoteSyncError)
        }

        let verification = ModelContext(container)
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<NoteRecord>()).isEmpty
        )
        XCTAssertTrue(
            try verification.fetch(FetchDescriptor<DomainOperation>()).isEmpty
        )
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first?.lastPulledRevision,
            0
        )
    }

    @MainActor
    func testRestoreQuarantinesRemotePedigreeQualificationMismatchAndAdvancesCursor() async throws {
        let container = try AppSchema.makeContainer(
            name: "remote-pedigree-qualification-conflict-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let farmID = UUID()
        let ownerID = UUID()
        let damID = UUID()
        let sireID = UUID()
        let childID = UUID()
        let penID = UUID()
        let operationID = UUID()
        let photoID = UUID()
        let photoOperationID = UUID()
        let transferID = UUID()
        let transferOperationID = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_788_225_539)

        context.insert(FarmRecord(
            id: farmID,
            ownerAccountID: ownerID,
            name: "远端系谱冲突恢复场"
        ))
        context.insert(SheepRecord(
            id: damID,
            farmID: farmID,
            earTag: "DAM-001",
            breed: "寒羊",
            sex: .ewe,
            penID: nil,
            enteredAt: occurredAt.addingTimeInterval(-86_400)
        ))
        context.insert(SheepRecord(
            id: sireID,
            farmID: farmID,
            earTag: "RAM-LEGACY",
            breed: "寒羊",
            purpose: "种公羊",
            isBreedingRam: false,
            sex: .ram,
            penID: nil,
            enteredAt: occurredAt.addingTimeInterval(-86_400)
        ))
        context.insert(SheepRecord(
            id: childID,
            farmID: farmID,
            earTag: "LAMB-001",
            breed: "寒羊",
            sex: .ewe,
            penID: nil,
            enteredAt: occurredAt,
            birthAt: occurredAt,
            damID: damID
        ))
        context.insert(PenRecord(
            id: penID,
            farmID: farmID,
            name: "恢复验收舍"
        ))
        context.insert(FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerID,
            provider: .supabase,
            state: .preparing,
            authorityGeneration: 1,
            remoteFarmID: farmID.uuidString.lowercased()
        ))
        try context.save()

        let payload = try FarmCommandCloudPayloadEncoder.encode(
            .care(.updateSheepPedigree(.init(
                id: UUID(),
                sheepID: childID,
                damID: damID,
                sireID: sireID,
                semenDonorID: nil,
                reason: "人工核对后确认",
                expectedRevision: 1
            )))
        )
        let envelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: childID,
            entityType: CloudEntityType.sheep.rawValue,
            schemaVersion: 2,
            revision: 2,
            baseRevision: 1,
            operationID: operationID,
            modifiedAt: occurredAt,
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        let photoDigest = String(repeating: "a", count: 64)
        var photoPayload = FarmCommandCloudPayload(kind: .addPhoto)
        photoPayload.strings = [
            "sha256": photoDigest,
            "sourceSHA256": photoDigest,
            "mimeType": "image/heic",
            "originalEarTag": "LAMB-001"
        ]
        photoPayload.integers = ["byteCount": 518_884]
        photoPayload.optionalIdentifiers = ["sheepID": childID]
        let photoPayloadData = try JSONEncoder.cloud.encode(photoPayload)
        let photoEnvelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: photoID,
            entityType: CloudEntityType.photoAsset.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: photoOperationID,
            modifiedAt: occurredAt.addingTimeInterval(1),
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            payload: photoPayloadData,
            payloadDigest: CloudPayloadDigest.hex(for: photoPayloadData),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        var transferPayload = FarmCommandCloudPayload(kind: .transferSheep)
        transferPayload.identifiers = ["sheepID": childID]
        transferPayload.optionalIdentifiers = ["toPenID": penID]
        transferPayload.dates = ["occurredAt": occurredAt.addingTimeInterval(2)]
        transferPayload.strings = ["note": "冲突后的转群仍须落地"]
        let transferPayloadData = try JSONEncoder.cloud.encode(transferPayload)
        let transferEnvelope = CloudOperationEnvelope(
            farmID: farmID,
            entityID: transferID,
            entityType: CloudEntityType.transfer.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: transferOperationID,
            modifiedAt: occurredAt.addingTimeInterval(2),
            modifiedByAccountID: ownerID,
            modifiedByDeviceID: UUID(),
            payload: transferPayloadData,
            payloadDigest: CloudPayloadDigest.hex(for: transferPayloadData),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
        let transport = TestFarmRemoteTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in [] },
            pullOperations: { _, _, _, _ in
                FarmRemotePullPage(
                    operations: [envelope, photoEnvelope, transferEnvelope],
                    cursorRevision: 4,
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            members: { _ in [] },
            deactivate: { _, _, _ in }
        ))

        let result = try await FarmRemoteSyncCoordinator(
            container: container,
            transport: transport
        ).catchUpRestoredFarm(farmID: farmID)

        XCTAssertEqual(result.cursorRevision, 4)
        XCTAssertEqual(result.conflictCount, 1)
        let verification = ModelContext(container)
        let child = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<SheepRecord>())
                .first(where: { $0.id == childID })
        )
        XCTAssertNil(child.sireID)
        let durableOperations = try verification.fetch(
            FetchDescriptor<DomainOperation>()
        )
        XCTAssertEqual(
            Set(durableOperations.map(\.id)),
            Set([photoOperationID, transferOperationID])
        )
        let restoredPhoto = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<PhotoAssetRecord>())
                .first(where: { $0.id == photoID })
        )
        XCTAssertEqual(restoredPhoto.sheepID, childID)
        XCTAssertEqual(restoredPhoto.sha256, photoDigest)
        let photoDownload = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<CloudAssetTransfer>())
                .first(where: { $0.assetID == photoID })
        )
        XCTAssertEqual(photoDownload.direction, .download)
        XCTAssertEqual(photoDownload.status, .pending)
        XCTAssertEqual(photoDownload.byteCount, 518_884)
        let restoredTransfer = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<TransferRecord>())
                .first(where: { $0.id == transferID })
        )
        XCTAssertEqual(restoredTransfer.sheepID, childID)
        XCTAssertEqual(restoredTransfer.toPenID, penID)
        let conflict = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<SyncConflictRecord>()).first
        )
        XCTAssertEqual(
            conflict.reasonCode,
            "remotePedigreeParentQualificationMismatch"
        )
        XCTAssertEqual(conflict.remoteRevision, 2)
        XCTAssertNotNil(conflict.remoteEnvelopeData)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<FarmRemoteBinding>())
                .first?.lastPulledRevision,
            4
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

        let transport = TestFarmRemoteTransport(endpoints: .init(
            establishBaseline: { _ in },
            pushOperations: { _, _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            pullOperations: { _, _, revision, _ in
                FarmRemotePullPage(
                    operations: [],
                    cursorRevision: revision,
                    hasMore: false
                )
            },
            uploadAsset: { _, _, _, _, _, _ in
                throw FarmRemoteTransportError.unsupportedOperation
            },
            downloadAsset: { _ in
                throw FarmRemoteTransportError.unsupportedOperation
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
