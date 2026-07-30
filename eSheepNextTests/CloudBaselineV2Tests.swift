import CloudKit
import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class CloudBaselineV2Tests: XCTestCase {
    func testVersion2SheepBootstrapRoundTripRestoresAuthoritativeStatusAndCurrentPen() throws {
        let sourceContainer = try AppSchema.makeContainer(
            name: "baseline-v2-sheep-source-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let source = ModelContext(sourceContainer)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        farm.isLocalOnlyMigration = true
        let initialPen = PenRecord(farmID: farm.id, name: "初始圈")
        let currentPen = PenRecord(farmID: farm.id, name: "当前圈")
        let removedAt = Date(timeIntervalSince1970: 1_735_689_600)

        let removedSheep = SheepRecord(
            farmID: farm.id,
            earTag: "REMOVED-001",
            breed: "湖羊",
            sex: .ewe,
            penID: initialPen.id,
            enteredAt: removedAt.addingTimeInterval(-86_400)
        )
        removedSheep.statusRawValue = SheepStatus.removed.rawValue
        removedSheep.currentPenID = nil
        removedSheep.removedAt = removedAt
        removedSheep.legacyStatusSnapshotIsAuthoritative = true
        removedSheep.legacyPenSnapshotIsAuthoritative = true

        let activeSheep = SheepRecord(
            farmID: farm.id,
            earTag: "ACTIVE-001",
            breed: "湖羊",
            sex: .ewe,
            penID: initialPen.id,
            enteredAt: removedAt.addingTimeInterval(-172_800)
        )
        activeSheep.statusRawValue = SheepStatus.active.rawValue
        activeSheep.currentPenID = currentPen.id
        activeSheep.legacyStatusSnapshotIsAuthoritative = true
        activeSheep.legacyPenSnapshotIsAuthoritative = true

        let commit = MigrationCommitRecord(
            sessionID: UUID(),
            sourceChecksum: "verified-source",
            farmID: farm.id,
            ownerAccountID: ownerID,
            recordCountsJSON: "{}",
            assetsRelativeDirectory: ""
        )
        source.insert(farm)
        source.insert(initialPen)
        source.insert(currentPen)
        source.insert(removedSheep)
        source.insert(activeSheep)
        source.insert(commit)
        try source.save()

        _ = try MigrationCloudBootstrapService().prepare(
            commit: commit,
            farm: farm,
            accountID: ownerID,
            context: source
        )
        try source.save()

        let sheepOperations = try source.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farm.id && $0.entityType == CloudEntityType.sheep.rawValue
        }
        XCTAssertEqual(sheepOperations.count, 2)

        let recoveryContainer = try AppSchema.makeContainer(
            name: "baseline-v2-sheep-recovery-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let recovery = ModelContext(recoveryContainer)
        for operation in sheepOperations {
            _ = try RemoteDomainApplyService().apply(makeEnvelope(from: operation), context: recovery)
        }
        try recovery.save()

        let recovered = try recovery.fetch(FetchDescriptor<SheepRecord>())
        let recoveredRemoved = try XCTUnwrap(recovered.first { $0.id == removedSheep.id })
        XCTAssertEqual(recoveredRemoved.status, .removed)
        XCTAssertEqual(recoveredRemoved.removedAt, removedAt)
        XCTAssertNil(recoveredRemoved.currentPenID)
        XCTAssertEqual(recoveredRemoved.initialPenID, initialPen.id)
        XCTAssertEqual(recoveredRemoved.legacyStatusSnapshotIsAuthoritative, true)
        XCTAssertEqual(recoveredRemoved.legacyPenSnapshotIsAuthoritative, true)

        let recoveredActive = try XCTUnwrap(recovered.first { $0.id == activeSheep.id })
        XCTAssertEqual(recoveredActive.status, .active)
        XCTAssertNil(recoveredActive.removedAt)
        XCTAssertEqual(recoveredActive.initialPenID, initialPen.id)
        XCTAssertEqual(recoveredActive.currentPenID, currentPen.id)
        XCTAssertEqual(recoveredActive.legacyStatusSnapshotIsAuthoritative, true)
        XCTAssertEqual(recoveredActive.legacyPenSnapshotIsAuthoritative, true)
    }

    func testVersion2HistoricalTransferBootstrapDoesNotOverrideAuthoritativeSheepSnapshot() throws {
        let sourceContainer = try AppSchema.makeContainer(
            name: "baseline-v2-history-source-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let source = ModelContext(sourceContainer)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "历史状态牧场")
        farm.isLocalOnlyMigration = true
        let initialPen = PenRecord(farmID: farm.id, name: "初始圈")
        let historicalPen = PenRecord(farmID: farm.id, name: "历史转入圈")
        let removedAt = Date(timeIntervalSince1970: 1_735_689_600)
        let sheep = SheepRecord(
            farmID: farm.id,
            earTag: "LEGACY-REMOVED-001",
            breed: "湖羊",
            sex: .ewe,
            penID: initialPen.id,
            enteredAt: removedAt.addingTimeInterval(-172_800)
        )
        sheep.statusRawValue = SheepStatus.removed.rawValue
        sheep.currentPenID = nil
        sheep.removedAt = nil
        sheep.legacyStatusSnapshotIsAuthoritative = true
        sheep.legacyPenSnapshotIsAuthoritative = true
        let historicalTransfer = TransferRecord(
            farmID: farm.id,
            sheepID: sheep.id,
            fromPenID: initialPen.id,
            toPenID: historicalPen.id,
            occurredAt: removedAt.addingTimeInterval(-86_400),
            note: "迁移前历史转群"
        )
        let commit = MigrationCommitRecord(
            sessionID: UUID(),
            sourceChecksum: "verified-history-source",
            farmID: farm.id,
            ownerAccountID: ownerID,
            recordCountsJSON: "{}",
            assetsRelativeDirectory: ""
        )
        source.insert(farm)
        source.insert(initialPen)
        source.insert(historicalPen)
        source.insert(sheep)
        source.insert(historicalTransfer)
        source.insert(commit)
        try source.save()

        _ = try MigrationCloudBootstrapService().prepare(
            commit: commit,
            farm: farm,
            accountID: ownerID,
            context: source
        )
        try source.save()
        let operations = CloudRebuildActor.sortedOperations(
            try source.fetch(FetchDescriptor<DomainOperation>())
                .filter { $0.farmID == farm.id }
                .map(makeEnvelope(from:))
        )

        let recoveryContainer = try AppSchema.makeContainer(
            name: "baseline-v2-history-recovery-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let recovery = ModelContext(recoveryContainer)
        let service = RemoteDomainApplyService(replayAssumesEmptyBusinessStore: true)
        for operation in operations {
            _ = try service.apply(operation, context: recovery)
        }
        try FarmHistoryRebuilder().rebuild(
            farmID: farm.id,
            context: recovery,
            from: .distantPast
        )
        try recovery.save()

        let recovered = try XCTUnwrap(
            try recovery.fetch(FetchDescriptor<SheepRecord>())
                .first { $0.id == sheep.id }
        )
        XCTAssertEqual(recovered.status, .removed)
        XCTAssertNil(recovered.currentPenID)
        XCTAssertEqual(recovered.legacyStatusSnapshotIsAuthoritative, true)
        XCTAssertEqual(recovered.legacyPenSnapshotIsAuthoritative, true)
        XCTAssertEqual(
            try recovery.fetch(FetchDescriptor<TransferRecord>())
                .filter { $0.sheepID == sheep.id }
                .count,
            1,
            "历史实体仍须恢复，但不能推翻同一基线里的最终 Sheep 快照"
        )
    }

    func testBaselineCanonicalizationReusesUnchangedV1ReplacesChangedSlotWithV2AndHonorsCutoffTombstone() throws {
        let farmID = UUID()
        let cutoff = Date(timeIntervalSince1970: 1_735_689_600)
        let replacedEntityID = UUID()
        let unchangedEntityID = UUID()
        let deletedEntityID = UUID()

        let replacedV1 = try makeBootstrapEnvelope(
            farmID: farmID,
            entityID: replacedEntityID,
            sourcePayload: try FarmCommandCloudPayloadEncoder.encode(.addSheep(
                earTag: "OLD",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                occurredAt: cutoff.addingTimeInterval(-10_000),
                birthAt: nil,
                note: ""
            )),
            baselineVersion: nil,
            baselineSlot: nil,
            modifiedAt: cutoff.addingTimeInterval(-1_000)
        )
        let replacedV2 = try makeBootstrapEnvelope(
            farmID: farmID,
            entityID: replacedEntityID,
            sourcePayload: try FarmCommandCloudPayloadEncoder.encode(.addSheep(
                earTag: "CURRENT",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                occurredAt: cutoff.addingTimeInterval(-10_000),
                birthAt: nil,
                note: ""
            )),
            baselineVersion: 2,
            baselineSlot: "20",
            baselineCutoffAt: cutoff,
            modifiedAt: cutoff
        )
        let unchangedV1 = try makeBootstrapEnvelope(
            farmID: farmID,
            entityID: unchangedEntityID,
            sourcePayload: try FarmCommandCloudPayloadEncoder.encode(.addSheep(
                earTag: "UNCHANGED",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                occurredAt: cutoff.addingTimeInterval(-10_000),
                birthAt: nil,
                note: ""
            )),
            baselineVersion: nil,
            baselineSlot: nil,
            modifiedAt: cutoff.addingTimeInterval(-1_000)
        )
        let deletedV1 = try makeBootstrapEnvelope(
            farmID: farmID,
            entityID: deletedEntityID,
            sourcePayload: try FarmCommandCloudPayloadEncoder.encode(.addSheep(
                earTag: "DELETED",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                occurredAt: cutoff.addingTimeInterval(-10_000),
                birthAt: nil,
                note: ""
            )),
            baselineVersion: nil,
            baselineSlot: nil,
            modifiedAt: cutoff.addingTimeInterval(-1_000)
        )
        let tombstone = try makeCommandEnvelope(
            farmID: farmID,
            entityID: deletedEntityID,
            entityType: .sheep,
            command: .tombstoneEntity(entityType: .sheep, entityID: deletedEntityID, reason: "误建档"),
            modifiedAt: cutoff.addingTimeInterval(-100)
        )
        let preCutoffDelta = try makeCommandEnvelope(
            farmID: farmID,
            entityID: UUID(),
            entityType: .pen,
            command: .createPen(name: "已进入快照", note: ""),
            modifiedAt: cutoff.addingTimeInterval(-1)
        )
        let postCutoffDelta = try makeCommandEnvelope(
            farmID: farmID,
            entityID: UUID(),
            entityType: .pen,
            command: .createPen(name: "快照后新增", note: ""),
            modifiedAt: cutoff.addingTimeInterval(1)
        )

        let canonical = try CloudRebuildActor.canonicalizeBaselineOperations(
            [
                replacedV1,
                replacedV2,
                unchangedV1,
                deletedV1,
                tombstone,
                preCutoffDelta,
                postCutoffDelta,
            ],
            expectedVersion: 2,
            cutoffAt: cutoff
        )
        let operationIDs = Set(canonical.map(\.operationID))

        XCTAssertEqual(operationIDs, Set([
            replacedV2.operationID,
            unchangedV1.operationID,
            tombstone.operationID,
            postCutoffDelta.operationID,
        ]))
        XCTAssertFalse(operationIDs.contains(replacedV1.operationID))
        XCTAssertFalse(operationIDs.contains(deletedV1.operationID))
        XCTAssertFalse(operationIDs.contains(preCutoffDelta.operationID))
    }

    func testRebuildUsesImmutableOperationAsAuthorityAndIgnoresOnlyBaselineDiscardedProjection() throws {
        let farmID = UUID()
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let postCutoff = try makeCommandEnvelope(
            farmID: farmID,
            entityID: UUID(),
            entityType: .pen,
            command: .createPen(name: "快照后新增", note: ""),
            modifiedAt: cutoff.addingTimeInterval(1)
        )

        XCTAssertEqual(
            try CloudRebuildActor.reconcileAuthoritativeOperationSources(
                immutableOperations: [postCutoff],
                projections: [postCutoff],
                expectedBaselineVersion: 2,
                cutoffAt: cutoff
            ),
            [postCutoff]
        )
        let staleProjection = CloudOperationEnvelope(
            farmID: postCutoff.farmID,
            entityID: postCutoff.entityID,
            entityType: postCutoff.entityType,
            schemaVersion: postCutoff.schemaVersion,
            revision: postCutoff.revision,
            baseRevision: postCutoff.baseRevision,
            operationID: postCutoff.operationID,
            modifiedAt: postCutoff.modifiedAt.addingTimeInterval(-1),
            modifiedByAccountID: postCutoff.modifiedByAccountID,
            modifiedByDeviceID: postCutoff.modifiedByDeviceID,
            payload: postCutoff.payload,
            payloadDigest: postCutoff.payloadDigest,
            capabilityCertificate: postCutoff.capabilityCertificate,
            operationSignature: postCutoff.operationSignature,
            deletedAt: postCutoff.deletedAt
        )
        XCTAssertEqual(
            try CloudRebuildActor.reconcileAuthoritativeOperationSources(
                immutableOperations: [postCutoff],
                projections: [staleProjection],
                expectedBaselineVersion: 2,
                cutoffAt: cutoff
            ),
            [postCutoff],
            "可变投影的非权威字段过期时，重建必须继续采用不可变操作"
        )
        XCTAssertThrowsError(
            try CloudRebuildActor.reconcileAuthoritativeOperationSources(
                immutableOperations: [],
                projections: [postCutoff],
                expectedBaselineVersion: 2,
                cutoffAt: cutoff
            )
        )

        let interruptedCutoff = cutoff.addingTimeInterval(60)
        let interruptedProjection = try makeBootstrapEnvelope(
            farmID: farmID,
            entityID: UUID(),
            sourcePayload: try FarmCommandCloudPayloadEncoder.encode(.addSheep(
                earTag: "错误基线投影",
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                occurredAt: cutoff.addingTimeInterval(-100),
                birthAt: nil,
                note: ""
            )),
            baselineVersion: 2,
            baselineSlot: "20",
            baselineCutoffAt: interruptedCutoff,
            modifiedAt: interruptedCutoff
        )
        XCTAssertTrue(
            try CloudRebuildActor.reconcileAuthoritativeOperationSources(
                immutableOperations: [],
                projections: [interruptedProjection],
                expectedBaselineVersion: 2,
                cutoffAt: cutoff
            ).isEmpty,
            "被 ready root 明确排除的中断基线投影不能重新带回 521 版本"
        )
    }

    func testRefreshedBaselineQueuesImmutableOperationWithoutOverwritingEntityProjection() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-outbox-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let penID = UUID()
        let sourcePayload = try FarmCommandCloudPayloadEncoder.encode(.createPen(name: "当前圈", note: ""))
        let snapshot = BootstrapEntityEnvelopeV1(
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            sourceRevision: 1,
            sourcePayload: sourcePayload
        )
        var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
        wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(snapshot)
        wrapper.integers["baselineVersion"] = 2
        wrapper.strings["baselineSlot"] = "10"
        wrapper.dates["baselineCutoffAt"] = .now
        let operation = DomainOperation(
            farmID: farm.id,
            accountID: ownerID,
            kind: .bootstrapEntity,
            summary: "迁移云端基线：pen",
            entityType: CloudEntityType.pen.rawValue,
            entityID: penID,
            payload: try JSONEncoder.cloud.encode(wrapper)
        )
        let outbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: penID,
            baseRevision: 0,
            payloadDigest: operation.payloadDigest
        )
        context.insert(farm)
        context.insert(CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(operation)
        context.insert(outbox)
        try context.save()

        let pending = try await FarmPersistenceActor(container: container).pendingRecordIDs(maxOutboxItems: 1)
        XCTAssertEqual(pending.map(\.0.recordName), [CloudRecordMapper().recordName(for: operation.id)])
    }

    func testRefreshedBaselineConflictedProjectionIsConfirmedFromImmutableOperationReceipt() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-receipt-reconcile-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let entityID = UUID()
        let sourcePayload = try FarmCommandCloudPayloadEncoder.encode(.createPen(name: "当前圈", note: ""))
        let snapshot = BootstrapEntityEnvelopeV1(
            entityType: CloudEntityType.pen.rawValue,
            entityID: entityID,
            sourceRevision: 1,
            sourcePayload: sourcePayload
        )
        var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
        wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(snapshot)
        wrapper.integers["baselineVersion"] = 2
        wrapper.strings["baselineSlot"] = "10"
        wrapper.dates["baselineCutoffAt"] = .now
        let operation = DomainOperation(
            farmID: farm.id,
            accountID: ownerID,
            kind: .bootstrapEntity,
            summary: "迁移云端基线：pen",
            entityType: CloudEntityType.pen.rawValue,
            entityID: entityID,
            payload: try JSONEncoder.cloud.encode(wrapper)
        )
        let outbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: entityID,
            baseRevision: 0,
            payloadDigest: operation.payloadDigest
        )
        outbox.statusRawValue = OutboxStatus.blockedConflict.rawValue
        outbox.errorMessage = "云端已有不同内容：实体版本 2 与本地操作基线 0 不属于同一已确认操作链，已停止自动覆盖。"
        let receipt = CloudOperationReceipt(
            farmID: farm.id,
            operationID: operation.id,
            recordName: CloudRecordMapper().recordName(for: operation.id),
            serverChangeTag: "saved-operation",
            databaseScope: .privateDatabase,
            zoneName: CloudZoneName.forFarm(farm.id),
            zoneOwnerName: CKCurrentUserDefaultName
        )
        context.insert(farm)
        context.insert(CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(operation)
        context.insert(outbox)
        context.insert(receipt)
        try context.save()

        let reconciled = try await FarmPersistenceActor(container: container)
            .reconcileRefreshedBootstrapOutbox(farmID: farm.id)
        let refreshed = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<OutboxItem>()).first)

        XCTAssertEqual(reconciled, 1)
        XCTAssertEqual(refreshed.status, .confirmed)
        XCTAssertNil(refreshed.errorMessage)
        XCTAssertEqual(refreshed.cloudRecordName, receipt.recordName)
    }

    func testRefreshedBaselineConflictedProjectionWithoutReceiptRetriesOnlyImmutableOperation() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-projection-retry-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let entityID = UUID()
        let sourcePayload = try FarmCommandCloudPayloadEncoder.encode(.createPen(name: "当前圈", note: ""))
        let snapshot = BootstrapEntityEnvelopeV1(
            entityType: CloudEntityType.pen.rawValue,
            entityID: entityID,
            sourceRevision: 1,
            sourcePayload: sourcePayload
        )
        var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
        wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(snapshot)
        wrapper.integers["baselineVersion"] = 2
        wrapper.strings["baselineSlot"] = "10"
        wrapper.dates["baselineCutoffAt"] = .now
        let operation = DomainOperation(
            farmID: farm.id,
            accountID: ownerID,
            kind: .bootstrapEntity,
            summary: "迁移云端基线：pen",
            entityType: CloudEntityType.pen.rawValue,
            entityID: entityID,
            payload: try JSONEncoder.cloud.encode(wrapper)
        )
        let outbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: entityID,
            baseRevision: 0,
            payloadDigest: operation.payloadDigest
        )
        outbox.statusRawValue = OutboxStatus.blockedConflict.rawValue
        outbox.errorMessage = "云端已有不同内容：实体版本 2 与本地操作基线 0 不属于同一已确认操作链，已停止自动覆盖。"
        context.insert(farm)
        context.insert(CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(operation)
        context.insert(outbox)
        try context.save()

        let reconciled = try await FarmPersistenceActor(container: container)
            .reconcileRefreshedBootstrapOutbox(farmID: farm.id)
        let refreshed = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<OutboxItem>()).first)
        let pending = try await FarmPersistenceActor(container: container).pendingRecordIDs(maxOutboxItems: 1)

        XCTAssertEqual(reconciled, 1)
        XCTAssertEqual(refreshed.status, .pending)
        XCTAssertNil(refreshed.errorMessage)
        XCTAssertEqual(pending.map(\.0.recordName), [CloudRecordMapper().recordName(for: operation.id)])
    }

    func testLegacyZoneLessReceiptCannotConfirmRefreshedOutbox() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-zone-less-receipt-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let operation = try makeRefreshedBootstrapOperation(
            farmID: farm.id,
            ownerID: ownerID,
            entityID: UUID()
        )
        let outbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID,
            payloadDigest: operation.payloadDigest
        )
        outbox.statusRawValue = OutboxStatus.blockedConflict.rawValue
        outbox.errorMessage = "云端已有不同内容：实体版本 2 与本地操作基线 0 不属于同一已确认操作链，已停止自动覆盖。"
        context.insert(farm)
        context.insert(CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(operation)
        context.insert(outbox)
        context.insert(CloudOperationReceipt(
            farmID: farm.id,
            operationID: operation.id,
            recordName: CloudRecordMapper().recordName(for: operation.id),
            serverChangeTag: "legacy-without-zone",
            databaseScope: .privateDatabase
        ))
        try context.save()

        let reconciled = try await FarmPersistenceActor(container: container)
            .reconcileRefreshedBootstrapOutbox(farmID: farm.id)
        let refreshed = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<OutboxItem>()).first)

        XCTAssertEqual(reconciled, 1)
        XCTAssertEqual(refreshed.status, .pending)
        XCTAssertNil(refreshed.cloudRecordName)
    }

    func testLegacyZoneLessReceiptBackfillsOnlyFromCompleteCurrentBindingProof() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-zone-receipt-backfill-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let binding = CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        )
        let operation = try makeRefreshedBootstrapOperation(
            farmID: farm.id,
            ownerID: ownerID,
            entityID: UUID()
        )
        let recordName = CloudRecordMapper().recordName(for: operation.id)
        let outbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID,
            payloadDigest: operation.payloadDigest
        )
        outbox.statusRawValue = OutboxStatus.confirmed.rawValue
        outbox.cloudRecordName = recordName
        context.insert(farm)
        context.insert(binding)
        context.insert(operation)
        context.insert(outbox)
        context.insert(CloudOperationReceipt(
            farmID: farm.id,
            operationID: operation.id,
            recordName: recordName,
            serverChangeTag: "saved-by-cloudkit",
            databaseScope: .privateDatabase,
            confirmedAt: binding.createdAt.addingTimeInterval(1)
        ))
        try context.save()

        let backfilled = try await FarmPersistenceActor(container: container)
            .backfillLegacyReceiptZoneIdentity(farmID: farm.id)
        let receipt = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<CloudOperationReceipt>()).first)

        XCTAssertEqual(backfilled, 1)
        XCTAssertEqual(receipt.zoneName, binding.zoneName)
        XCTAssertEqual(receipt.zoneOwnerName, binding.zoneOwnerName)
    }

    func testBindingIdentityChangeRequeuesConfirmedOutboxWithoutMatchingZoneReceipt() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-binding-receipt-reset-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let operation = try makeRefreshedBootstrapOperation(
            farmID: farm.id,
            ownerID: ownerID,
            entityID: UUID()
        )
        let outbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID,
            payloadDigest: operation.payloadDigest
        )
        outbox.statusRawValue = OutboxStatus.confirmed.rawValue
        outbox.cloudRecordName = CloudRecordMapper().recordName(for: operation.id)
        context.insert(farm)
        context.insert(CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(operation)
        context.insert(outbox)
        context.insert(CloudOperationReceipt(
            farmID: farm.id,
            operationID: operation.id,
            recordName: CloudRecordMapper().recordName(for: operation.id),
            serverChangeTag: "legacy-without-zone",
            databaseScope: .privateDatabase
        ))
        try context.save()

        try await FarmPersistenceActor(container: container).upsertBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            scope: .sharedDatabase,
            shareRecordName: "share",
            zoneOwnerName: "new-zone-owner",
            state: .active
        )
        let verify = ModelContext(container)
        let refreshed = try XCTUnwrap(verify.fetch(FetchDescriptor<OutboxItem>()).first)
        let binding = try XCTUnwrap(verify.fetch(FetchDescriptor<CloudFarmBinding>()).first)

        XCTAssertEqual(refreshed.status, .pending)
        XCTAssertNil(refreshed.cloudRecordName)
        XCTAssertEqual(binding.databaseScope, .sharedDatabase)
        XCTAssertEqual(binding.zoneOwnerName, "new-zone-owner")
    }

    func testRefreshedProjectionCleanupSurvivesConfirmedOutboxButPreservesRealPendingProjection() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-stale-projection-cleanup-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let entityID = UUID()
        let refreshed = try makeRefreshedBootstrapOperation(
            farmID: farm.id,
            ownerID: ownerID,
            entityID: entityID
        )
        let refreshedOutbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: refreshed.id,
            entityType: refreshed.entityType,
            entityID: entityID,
            baseRevision: refreshed.baseRevision,
            payloadDigest: refreshed.payloadDigest
        )
        refreshedOutbox.statusRawValue = OutboxStatus.confirmed.rawValue
        context.insert(farm)
        context.insert(refreshed)
        context.insert(refreshedOutbox)
        try context.save()

        let persistence = FarmPersistenceActor(container: container)
        let staleNames = try await persistence.refreshedBootstrapEntityRecordNames(farmID: farm.id)
        XCTAssertEqual(staleNames, Set([CloudRecordMapper().entityRecordName(for: entityID)]))

        let realUpdate = DomainOperation(
            farmID: farm.id,
            accountID: ownerID,
            kind: .updatePen,
            summary: "更新圈舍",
            entityType: CloudEntityType.pen.rawValue,
            entityID: entityID,
            baseRevision: 1,
            resultingRevision: 2
        )
        context.insert(realUpdate)
        context.insert(OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: realUpdate.id,
            entityType: realUpdate.entityType,
            entityID: entityID,
            baseRevision: realUpdate.baseRevision,
            payloadDigest: realUpdate.payloadDigest
        ))
        try context.save()

        let protectedNames = try await persistence.refreshedBootstrapEntityRecordNames(farmID: farm.id)
        XCTAssertTrue(protectedNames.isEmpty)
    }

    func testSentRecordReceiptRequiresExactActiveZoneScopeAndExpectedV2RecordName() async throws {
        let container = try AppSchema.makeContainer(
            name: "sent-record-boundary-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let unrelatedFarm = FarmRecord(ownerAccountID: ownerID, name: "其他牧场")
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let operation = try makeRefreshedBootstrapOperation(
            farmID: farm.id,
            ownerID: ownerID,
            entityID: UUID()
        )
        let outbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID,
            payloadDigest: operation.payloadDigest
        )
        for value in [unrelatedFarm, farm] {
            context.insert(value)
            context.insert(CloudFarmBinding(
                farmID: value.id,
                ownerAccountID: ownerID,
                databaseScope: .privateDatabase,
                state: .active
            ))
        }
        context.insert(operation)
        context.insert(outbox)
        try context.save()

        let mapper = CloudRecordMapper()
        let wrongZoneID = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(unrelatedFarm.id),
            ownerName: CKCurrentUserDefaultName
        )
        let correctZoneID = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(farm.id),
            ownerName: CKCurrentUserDefaultName
        )
        let wrongZoneRecord = CKRecord(
            recordType: CloudRecordType.farmOperation.rawValue,
            recordID: CKRecord.ID(recordName: mapper.recordName(for: operation.id), zoneID: wrongZoneID)
        )
        let correctRecord = CKRecord(
            recordType: CloudRecordType.farmOperation.rawValue,
            recordID: CKRecord.ID(recordName: mapper.recordName(for: operation.id), zoneID: correctZoneID)
        )
        let staleProjection = CKRecord(
            recordType: CloudRecordType.farmEntity.rawValue,
            recordID: CKRecord.ID(
                recordName: mapper.entityRecordName(for: try XCTUnwrap(operation.entityID)),
                zoneID: correctZoneID
            )
        )
        staleProjection[CloudRecordField.operationID] = operation.id.uuidString.lowercased() as CKRecordValue

        let persistence = FarmPersistenceActor(container: container)
        try await persistence.confirmSavedRecords([wrongZoneRecord], scope: .privateDatabase)
        try await persistence.confirmSavedRecords([correctRecord], scope: .sharedDatabase)
        try await persistence.confirmSavedRecords([staleProjection], scope: .privateDatabase)

        var verify = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(verify.fetch(FetchDescriptor<OutboxItem>()).first).status, .pending)
        XCTAssertTrue(try verify.fetch(FetchDescriptor<CloudOperationReceipt>()).isEmpty)

        try await persistence.confirmSavedRecords([correctRecord], scope: .privateDatabase)
        verify = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(verify.fetch(FetchDescriptor<OutboxItem>()).first).status, .confirmed)
        let receipts = try verify.fetch(FetchDescriptor<CloudOperationReceipt>())
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.farmID, farm.id)
        XCTAssertEqual(receipts.first?.databaseScopeRawValue, CloudDatabaseScope.privateDatabase.rawValue)
        XCTAssertEqual(receipts.first?.recordName, mapper.recordName(for: operation.id))
        XCTAssertEqual(receipts.first?.zoneName, correctZoneID.zoneName)
        XCTAssertEqual(receipts.first?.zoneOwnerName, correctZoneID.ownerName)
    }

    func testSentRecordConfirmationKeepsDuplicateOperationIDsIsolatedByFarm() async throws {
        let container = try AppSchema.makeContainer(
            name: "sent-record-duplicate-operation-boundary-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let operationID = UUID()
        let firstFarm = FarmRecord(ownerAccountID: ownerID, name: "一号牧场")
        let secondFarm = FarmRecord(ownerAccountID: ownerID, name: "二号牧场")
        let firstOperation = try makeRefreshedBootstrapOperation(
            farmID: firstFarm.id,
            ownerID: ownerID,
            entityID: UUID(),
            operationID: operationID
        )
        let secondOperation = try makeRefreshedBootstrapOperation(
            farmID: secondFarm.id,
            ownerID: ownerID,
            entityID: UUID(),
            operationID: operationID
        )
        for farm in [firstFarm, secondFarm] {
            context.insert(farm)
            context.insert(CloudFarmBinding(
                farmID: farm.id,
                ownerAccountID: ownerID,
                databaseScope: .privateDatabase,
                state: .active
            ))
        }
        for operation in [firstOperation, secondOperation] {
            context.insert(operation)
            context.insert(OutboxItem(
                farmID: operation.farmID,
                accountID: ownerID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID,
                payloadDigest: operation.payloadDigest
            ))
        }
        try context.save()

        let mapper = CloudRecordMapper()
        let secondRecord = CKRecord(
            recordType: CloudRecordType.farmOperation.rawValue,
            recordID: CKRecord.ID(
                recordName: mapper.recordName(for: operationID),
                zoneID: CKRecordZone.ID(
                    zoneName: CloudZoneName.forFarm(secondFarm.id),
                    ownerName: CKCurrentUserDefaultName
                )
            )
        )
        try await FarmPersistenceActor(container: container).confirmSavedRecords(
            [secondRecord],
            scope: .privateDatabase
        )

        let verify = ModelContext(container)
        let values = try verify.fetch(FetchDescriptor<OutboxItem>())
        XCTAssertEqual(values.first { $0.farmID == firstFarm.id }?.status, .pending)
        XCTAssertEqual(values.first { $0.farmID == secondFarm.id }?.status, .confirmed)
        let receipts = try verify.fetch(FetchDescriptor<CloudOperationReceipt>())
        XCTAssertEqual(receipts.map(\.farmID), [secondFarm.id])
    }

    func testExistingReceiptFromAnotherScopeCannotCompleteCurrentSend() async throws {
        let container = try AppSchema.makeContainer(
            name: "sent-record-receipt-scope-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式牧场")
        let entityID = UUID()
        let operation = DomainOperation(
            farmID: farm.id,
            accountID: ownerID,
            kind: .updatePen,
            summary: "更新圈舍",
            entityType: CloudEntityType.pen.rawValue,
            entityID: entityID,
            baseRevision: 1,
            resultingRevision: 2
        )
        let mapper = CloudRecordMapper()
        context.insert(farm)
        context.insert(CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(operation)
        context.insert(OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: entityID,
            baseRevision: operation.baseRevision,
            payloadDigest: operation.payloadDigest
        ))
        context.insert(CloudOperationReceipt(
            farmID: farm.id,
            operationID: operation.id,
            recordName: mapper.entityRecordName(for: entityID),
            serverChangeTag: "wrong-scope",
            databaseScope: .sharedDatabase
        ))
        try context.save()

        let zoneID = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(farm.id),
            ownerName: CKCurrentUserDefaultName
        )
        let operationRecord = CKRecord(
            recordType: CloudRecordType.farmOperation.rawValue,
            recordID: CKRecord.ID(recordName: mapper.recordName(for: operation.id), zoneID: zoneID)
        )
        let persistence = FarmPersistenceActor(container: container)
        try await persistence.confirmSavedRecords([operationRecord], scope: .privateDatabase)

        let verify = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(verify.fetch(FetchDescriptor<OutboxItem>()).first).status, .awaitingConfirmation)
    }

    func testRefreshedReceiptRequiresActiveBindingScopeAndMatchingOutboxDigest() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-receipt-boundary-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        let wrongScopeOperation = try makeRefreshedBootstrapOperation(
            farmID: farm.id,
            ownerID: ownerID,
            entityID: UUID()
        )
        let wrongScopeOutbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: wrongScopeOperation.id,
            entityType: wrongScopeOperation.entityType,
            entityID: wrongScopeOperation.entityID,
            payloadDigest: wrongScopeOperation.payloadDigest
        )
        wrongScopeOutbox.statusRawValue = OutboxStatus.blockedConflict.rawValue
        wrongScopeOutbox.errorMessage = "云端已有不同内容：实体版本 2 与本地操作基线 0 不属于同一已确认操作链，已停止自动覆盖。"

        let digestMismatchOperation = try makeRefreshedBootstrapOperation(
            farmID: farm.id,
            ownerID: ownerID,
            entityID: UUID()
        )
        let digestMismatchOutbox = OutboxItem(
            farmID: farm.id,
            accountID: ownerID,
            operationID: digestMismatchOperation.id,
            entityType: digestMismatchOperation.entityType,
            entityID: digestMismatchOperation.entityID,
            payloadDigest: "tampered-outbox-digest"
        )
        digestMismatchOutbox.statusRawValue = OutboxStatus.blockedConflict.rawValue
        digestMismatchOutbox.errorMessage = wrongScopeOutbox.errorMessage

        context.insert(farm)
        context.insert(CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        ))
        context.insert(wrongScopeOperation)
        context.insert(wrongScopeOutbox)
        context.insert(CloudOperationReceipt(
            farmID: farm.id,
            operationID: wrongScopeOperation.id,
            recordName: CloudRecordMapper().recordName(for: wrongScopeOperation.id),
            serverChangeTag: "wrong-scope",
            databaseScope: .sharedDatabase
        ))
        context.insert(digestMismatchOperation)
        context.insert(digestMismatchOutbox)
        context.insert(CloudOperationReceipt(
            farmID: farm.id,
            operationID: digestMismatchOperation.id,
            recordName: CloudRecordMapper().recordName(for: digestMismatchOperation.id),
            serverChangeTag: "matching-scope",
            databaseScope: .privateDatabase
        ))
        try context.save()

        let reconciled = try await FarmPersistenceActor(container: container)
            .reconcileRefreshedBootstrapOutbox(farmID: farm.id)
        let values = try ModelContext(container).fetch(FetchDescriptor<OutboxItem>())

        XCTAssertEqual(reconciled, 1)
        XCTAssertEqual(values.first { $0.id == wrongScopeOutbox.id }?.status, .pending)
        XCTAssertEqual(values.first { $0.id == digestMismatchOutbox.id }?.status, .blockedConflict)
    }

    func testRecordConstructionAndEntityLookupRejectMismatchedBindingZoneAndScope() async throws {
        let container = try AppSchema.makeContainer(
            name: "cloud-record-zone-boundary-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let firstFarm = FarmRecord(ownerAccountID: ownerID, name: "一号牧场")
        let secondFarm = FarmRecord(ownerAccountID: ownerID, name: "二号牧场")
        let sharedEntityID = UUID()
        let firstOperation = DomainOperation(
            farmID: firstFarm.id,
            accountID: ownerID,
            kind: .createPen,
            summary: "一号建圈",
            entityType: CloudEntityType.pen.rawValue,
            entityID: sharedEntityID,
            baseRevision: 0,
            resultingRevision: 1
        )
        let secondOperation = DomainOperation(
            farmID: secondFarm.id,
            accountID: ownerID,
            kind: .updatePen,
            summary: "二号更新圈",
            entityType: CloudEntityType.pen.rawValue,
            entityID: sharedEntityID,
            baseRevision: 2,
            resultingRevision: 3
        )
        for farm in [firstFarm, secondFarm] {
            context.insert(farm)
            context.insert(CloudFarmBinding(
                farmID: farm.id,
                ownerAccountID: ownerID,
                databaseScope: .privateDatabase,
                state: .active
            ))
        }
        for operation in [firstOperation, secondOperation] {
            context.insert(operation)
            context.insert(OutboxItem(
                farmID: operation.farmID,
                accountID: ownerID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: sharedEntityID,
                baseRevision: operation.baseRevision,
                payloadDigest: operation.payloadDigest
            ))
        }
        try context.save()

        let mapper = CloudRecordMapper()
        let firstZone = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(firstFarm.id),
            ownerName: CKCurrentUserDefaultName
        )
        let secondZone = CKRecordZone.ID(
            zoneName: CloudZoneName.forFarm(secondFarm.id),
            ownerName: CKCurrentUserDefaultName
        )
        let firstEntityRecordID = CKRecord.ID(
            recordName: mapper.entityRecordName(for: sharedEntityID),
            zoneID: firstZone
        )
        let secondEntityRecordID = CKRecord.ID(
            recordName: mapper.entityRecordName(for: sharedEntityID),
            zoneID: secondZone
        )
        let wrongZoneOperationRecordID = CKRecord.ID(
            recordName: mapper.recordName(for: secondOperation.id),
            zoneID: firstZone
        )
        let persistence = FarmPersistenceActor(container: container)

        let firstRequiresFetch = try await persistence.entityRecordRequiresServerFetch(
            firstEntityRecordID,
            scope: .privateDatabase
        )
        let secondRequiresFetch = try await persistence.entityRecordRequiresServerFetch(
            secondEntityRecordID,
            scope: .privateDatabase
        )
        let wrongScopeRequiresFetch = try await persistence.entityRecordRequiresServerFetch(
            firstEntityRecordID,
            scope: .sharedDatabase
        )
        let wrongZoneRecord = await persistence.record(
            for: wrongZoneOperationRecordID,
            scope: .privateDatabase,
            device: .shared
        )
        XCTAssertFalse(firstRequiresFetch)
        XCTAssertTrue(secondRequiresFetch)
        XCTAssertFalse(wrongScopeRequiresFetch)
        XCTAssertNil(wrongZoneRecord)
    }

    func testSupersededLocalMigrationFarmIsDeletedOnlyWhenVerifiedCloudReplacementMatches() async throws {
        let container = try AppSchema.makeContainer(
            name: "purge-superseded-migration-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let legacyOwnerID = UUID()
        let checksum = "same-verified-source"

        let formalFarm = FarmRecord(ownerAccountID: ownerID, name: "吉昊羊场")
        let formalCommit = makeCommit(
            farmID: formalFarm.id,
            ownerID: ownerID,
            sourceChecksum: checksum,
            cloudState: .synced
        )
        let formalBinding = CloudFarmBinding(
            farmID: formalFarm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        )
        let formalPen = PenRecord(farmID: formalFarm.id, name: "正式圈舍")

        let obsoleteFarm = FarmRecord(ownerAccountID: legacyOwnerID, name: "吉昊羊场")
        obsoleteFarm.isLocalOnlyMigration = true
        let obsoleteCommit = makeCommit(
            farmID: obsoleteFarm.id,
            ownerID: legacyOwnerID,
            sourceChecksum: checksum,
            cloudState: .localCommitted
        )
        let obsoletePen = PenRecord(farmID: obsoleteFarm.id, name: "旧圈舍")
        let obsoleteSheep = SheepRecord(
            farmID: obsoleteFarm.id,
            earTag: "OLD-521",
            breed: "湖羊",
            sex: .ewe,
            penID: obsoletePen.id,
            enteredAt: .now
        )
        let obsoleteOperation = DomainOperation(
            farmID: obsoleteFarm.id,
            accountID: legacyOwnerID,
            kind: .createPen,
            summary: "旧本地操作",
            entityType: CloudEntityType.pen.rawValue,
            entityID: obsoletePen.id,
            payload: try FarmCommandCloudPayloadEncoder.encode(.createPen(name: obsoletePen.name, note: ""))
        )
        let obsoleteOutbox = OutboxItem(
            farmID: obsoleteFarm.id,
            accountID: legacyOwnerID,
            operationID: obsoleteOperation.id
        )

        context.insert(formalFarm)
        context.insert(formalCommit)
        context.insert(formalBinding)
        context.insert(formalPen)
        context.insert(obsoleteFarm)
        context.insert(obsoleteCommit)
        context.insert(obsoletePen)
        context.insert(obsoleteSheep)
        context.insert(obsoleteOperation)
        context.insert(obsoleteOutbox)
        try context.save()

        let obsoleteAssetDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(
            path: "MigrationAssets/\(obsoleteFarm.id.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: obsoleteAssetDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: obsoleteAssetDirectory.path))

        let removed = try await FarmPersistenceActor(container: container)
            .purgeSupersededLocalMigrationFarm(
                obsoleteFarmID: obsoleteFarm.id,
                replacementFarmID: formalFarm.id,
                ownerAccountID: ownerID
            )
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsoleteAssetDirectory.path))

        let verify = ModelContext(container)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<FarmRecord>()).map(\.id), [formalFarm.id])
        XCTAssertEqual(try verify.fetch(FetchDescriptor<PenRecord>()).map(\.id), [formalPen.id])
        XCTAssertTrue(try verify.fetch(FetchDescriptor<SheepRecord>()).isEmpty)
        XCTAssertTrue(try verify.fetch(FetchDescriptor<DomainOperation>()).isEmpty)
        XCTAssertTrue(try verify.fetch(FetchDescriptor<OutboxItem>()).isEmpty)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<MigrationCommitRecord>()).map(\.farmID), [formalFarm.id])
        XCTAssertEqual(try verify.fetch(FetchDescriptor<CloudFarmBinding>()).map(\.farmID), [formalFarm.id])
    }

    func testMigrationReadyEvidenceRepairsMissingOutboxThenRequiresExactReceiptAndPhotoDigest() async throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-ready-evidence-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        farm.isLocalOnlyMigration = true
        let commit = MigrationCommitRecord(
            sessionID: UUID(),
            sourceChecksum: "verified-source",
            farmID: farm.id,
            ownerAccountID: ownerID,
            recordCountsJSON: "{}",
            assetsRelativeDirectory: ""
        )
        context.insert(farm)
        context.insert(commit)
        try context.save()
        _ = try MigrationCloudBootstrapService().prepare(
            commit: commit,
            farm: farm,
            accountID: ownerID,
            context: context
        )
        let originalOutbox = try XCTUnwrap(context.fetch(FetchDescriptor<OutboxItem>()).first)
        context.delete(originalOutbox)
        let binding = CloudFarmBinding(
            farmID: farm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        )
        context.insert(binding)
        let photo = PhotoAssetRecord(
            farmID: farm.id,
            sheepID: nil,
            legacySourceKey: "photo-1",
            originalEarTag: "",
            relativePath: "unused.jpg",
            sha256: "photo-digest"
        )
        context.insert(photo)
        commit.baselinePhotoCount = 1
        try context.save()

        let persistence = FarmPersistenceActor(container: container)
        let repairCount = try await persistence.repairMigrationCloudReadyEvidence(farmID: farm.id)
        XCTAssertEqual(repairCount, 1)
        var verify = ModelContext(container)
        var repaired = try XCTUnwrap(verify.fetch(FetchDescriptor<OutboxItem>()).first)
        XCTAssertEqual(repaired.status, .pending)
        do {
            _ = try await persistence.verifiedMigrationCloudBaselineForReady(farmID: farm.id)
            XCTFail("Missing confirmed evidence must not make the root ready.")
        } catch {}

        repaired.statusRawValue = OutboxStatus.confirmed.rawValue
        let operation = try XCTUnwrap(verify.fetch(FetchDescriptor<DomainOperation>()).first)
        let mapper = CloudRecordMapper()
        let recordName = mapper.recordName(for: operation.id)
        repaired.cloudRecordName = recordName
        verify.insert(CloudOperationReceipt(
            farmID: farm.id,
            operationID: operation.id,
            recordName: recordName,
            serverChangeTag: "confirmed",
            databaseScope: .privateDatabase,
            zoneName: binding.zoneName,
            zoneOwnerName: binding.zoneOwnerName
        ))
        let mismatchedUpload = CloudAssetTransfer(
            farmID: farm.id,
            assetID: photo.id,
            localRelativePath: photo.relativePath,
            payloadDigest: "wrong-digest",
            byteCount: 1,
            direction: .upload
        )
        mismatchedUpload.statusRawValue = CloudAssetTransferStatus.completed.rawValue
        verify.insert(mismatchedUpload)
        try verify.save()
        do {
            _ = try await persistence.verifiedMigrationCloudBaselineForReady(farmID: farm.id)
            XCTFail("A completed upload with the wrong digest must not qualify.")
        } catch {}

        let matchingUpload = CloudAssetTransfer(
            farmID: farm.id,
            assetID: photo.id,
            localRelativePath: photo.relativePath,
            payloadDigest: photo.sha256,
            byteCount: 1,
            direction: .upload
        )
        matchingUpload.statusRawValue = CloudAssetTransferStatus.completed.rawValue
        verify.insert(matchingUpload)
        try verify.save()

        let baseline = try await persistence.verifiedMigrationCloudBaselineForReady(farmID: farm.id)
        XCTAssertEqual(baseline?.digest, commit.baselineDigest)
        XCTAssertEqual(baseline?.entityCount, commit.baselineEntityCount)
        XCTAssertEqual(baseline?.photoCount, 1)
        XCTAssertEqual(baseline?.version, 2)
    }

    func testBootstrapPreparationRecreatesMissingOutboxButRejectsChangedExistingPayload() throws {
        let container = try AppSchema.makeContainer(
            name: "baseline-v2-prepare-repair-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let farm = FarmRecord(ownerAccountID: ownerID, name: "正式迁移牧场")
        farm.isLocalOnlyMigration = true
        let commit = MigrationCommitRecord(
            sessionID: UUID(),
            sourceChecksum: "verified-source",
            farmID: farm.id,
            ownerAccountID: ownerID,
            recordCountsJSON: "{}",
            assetsRelativeDirectory: ""
        )
        context.insert(farm)
        context.insert(commit)
        try context.save()
        let service = MigrationCloudBootstrapService()
        _ = try service.prepare(commit: commit, farm: farm, accountID: ownerID, context: context)
        let missing = try XCTUnwrap(context.fetch(FetchDescriptor<OutboxItem>()).first)
        context.delete(missing)
        try context.save()

        _ = try service.prepare(
            commit: commit,
            farm: farm,
            accountID: ownerID,
            context: context,
            forceRefresh: true
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxItem>()).count, 1)

        let operation = try XCTUnwrap(context.fetch(FetchDescriptor<DomainOperation>()).first)
        operation.payload = Data("{}".utf8)
        operation.payloadDigest = CloudPayloadDigest.hex(for: operation.payload)
        try context.save()
        XCTAssertThrowsError(try service.prepare(
            commit: commit,
            farm: farm,
            accountID: ownerID,
            context: context,
            forceRefresh: true
        ))
    }

    func testSupersededMigrationCleanupPreservesLocalFarmsWithoutMatchingActivePrivateReplacement() async throws {
        let container = try AppSchema.makeContainer(
            name: "purge-superseded-safety-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()

        let activeFormalFarm = FarmRecord(ownerAccountID: ownerID, name: "同名但不同来源")
        let activeFormalCommit = makeCommit(
            farmID: activeFormalFarm.id,
            ownerID: ownerID,
            sourceChecksum: "formal-source",
            cloudState: .synced
        )
        let activeBinding = CloudFarmBinding(
            farmID: activeFormalFarm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        )
        let checksumMismatchFarm = FarmRecord(ownerAccountID: ownerID, name: "同名但不同来源")
        checksumMismatchFarm.isLocalOnlyMigration = true
        let checksumMismatchCommit = makeCommit(
            farmID: checksumMismatchFarm.id,
            ownerID: ownerID,
            sourceChecksum: "different-source",
            cloudState: .localCommitted
        )

        let inactiveFormalFarm = FarmRecord(ownerAccountID: ownerID, name: "绑定未激活")
        let inactiveFormalCommit = makeCommit(
            farmID: inactiveFormalFarm.id,
            ownerID: ownerID,
            sourceChecksum: "inactive-source",
            cloudState: .synced
        )
        let inactiveBinding = CloudFarmBinding(
            farmID: inactiveFormalFarm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .failed
        )
        let inactiveMatchFarm = FarmRecord(ownerAccountID: ownerID, name: "绑定未激活")
        inactiveMatchFarm.isLocalOnlyMigration = true
        let inactiveMatchCommit = makeCommit(
            farmID: inactiveMatchFarm.id,
            ownerID: ownerID,
            sourceChecksum: "inactive-source",
            cloudState: .localCommitted
        )

        context.insert(activeFormalFarm)
        context.insert(activeFormalCommit)
        context.insert(activeBinding)
        context.insert(checksumMismatchFarm)
        context.insert(checksumMismatchCommit)
        context.insert(inactiveFormalFarm)
        context.insert(inactiveFormalCommit)
        context.insert(inactiveBinding)
        context.insert(inactiveMatchFarm)
        context.insert(inactiveMatchCommit)
        try context.save()

        let persistence = FarmPersistenceActor(container: container)
        let checksumMismatchRemoved = try await persistence.purgeSupersededLocalMigrationFarm(
            obsoleteFarmID: checksumMismatchFarm.id,
            replacementFarmID: activeFormalFarm.id,
            ownerAccountID: ownerID
        )
        let inactiveBindingRemoved = try await persistence.purgeSupersededLocalMigrationFarm(
            obsoleteFarmID: inactiveMatchFarm.id,
            replacementFarmID: inactiveFormalFarm.id,
            ownerAccountID: ownerID
        )
        XCTAssertFalse(checksumMismatchRemoved)
        XCTAssertFalse(inactiveBindingRemoved)

        let farmIDs = Set(try ModelContext(container).fetch(FetchDescriptor<FarmRecord>()).map(\.id))
        XCTAssertTrue(farmIDs.contains(checksumMismatchFarm.id))
        XCTAssertTrue(farmIDs.contains(inactiveMatchFarm.id))
    }

    func testSupersededMigrationCleanupPreservesLegacyFarmWithActiveBinding() async throws {
        let container = try AppSchema.makeContainer(
            name: "purge-superseded-active-legacy-binding-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let ownerID = UUID()
        let legacyOwnerID = UUID()
        let checksum = "same-verified-source"

        let formalFarm = FarmRecord(ownerAccountID: ownerID, name: "吉昊羊场")
        let formalCommit = makeCommit(
            farmID: formalFarm.id,
            ownerID: ownerID,
            sourceChecksum: checksum,
            cloudState: .synced
        )
        let formalBinding = CloudFarmBinding(
            farmID: formalFarm.id,
            ownerAccountID: ownerID,
            databaseScope: .privateDatabase,
            state: .active
        )

        let legacyFarm = FarmRecord(ownerAccountID: legacyOwnerID, name: "吉昊羊场")
        legacyFarm.isLocalOnlyMigration = true
        let legacyCommit = makeCommit(
            farmID: legacyFarm.id,
            ownerID: legacyOwnerID,
            sourceChecksum: checksum,
            cloudState: .localCommitted
        )
        let legacyBinding = CloudFarmBinding(
            farmID: legacyFarm.id,
            ownerAccountID: legacyOwnerID,
            databaseScope: .privateDatabase,
            state: .active
        )

        context.insert(formalFarm)
        context.insert(formalCommit)
        context.insert(formalBinding)
        context.insert(legacyFarm)
        context.insert(legacyCommit)
        context.insert(legacyBinding)
        try context.save()

        let removed = try await FarmPersistenceActor(container: container)
            .purgeSupersededLocalMigrationFarm(
                obsoleteFarmID: legacyFarm.id,
                replacementFarmID: formalFarm.id,
                ownerAccountID: ownerID
            )
        XCTAssertFalse(removed)

        let verify = ModelContext(container)
        XCTAssertNotNil(try verify.fetch(FetchDescriptor<FarmRecord>()).first { $0.id == legacyFarm.id })
        XCTAssertNotNil(try verify.fetch(FetchDescriptor<MigrationCommitRecord>()).first { $0.farmID == legacyFarm.id })
        XCTAssertNotNil(try verify.fetch(FetchDescriptor<CloudFarmBinding>()).first { $0.farmID == legacyFarm.id })
    }

    private func makeEnvelope(from operation: DomainOperation) throws -> CloudOperationEnvelope {
        CloudOperationEnvelope(
            farmID: operation.farmID,
            entityID: try XCTUnwrap(operation.entityID),
            entityType: operation.entityType,
            schemaVersion: operation.schemaVersion,
            revision: operation.resultingRevision,
            baseRevision: operation.baseRevision,
            operationID: operation.id,
            modifiedAt: operation.occurredAt,
            modifiedByAccountID: operation.accountID,
            modifiedByDeviceID: UUID(),
            payload: operation.payload,
            payloadDigest: operation.payloadDigest,
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
    }

    private func makeRefreshedBootstrapOperation(
        farmID: UUID,
        ownerID: UUID,
        entityID: UUID,
        operationID: UUID = UUID()
    ) throws -> DomainOperation {
        let sourcePayload = try FarmCommandCloudPayloadEncoder.encode(.createPen(name: "当前圈", note: ""))
        let snapshot = BootstrapEntityEnvelopeV1(
            entityType: CloudEntityType.pen.rawValue,
            entityID: entityID,
            sourceRevision: 1,
            sourcePayload: sourcePayload
        )
        var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
        wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(snapshot)
        wrapper.integers["baselineVersion"] = 2
        wrapper.strings["baselineSlot"] = "10"
        wrapper.dates["baselineCutoffAt"] = .now
        return DomainOperation(
            id: operationID,
            farmID: farmID,
            accountID: ownerID,
            kind: .bootstrapEntity,
            summary: "迁移云端基线：pen",
            entityType: CloudEntityType.pen.rawValue,
            entityID: entityID,
            payload: try JSONEncoder.cloud.encode(wrapper)
        )
    }

    private func makeBootstrapEnvelope(
        farmID: UUID,
        entityID: UUID,
        sourcePayload: Data,
        baselineVersion: Int?,
        baselineSlot: String?,
        baselineCutoffAt: Date? = nil,
        modifiedAt: Date
    ) throws -> CloudOperationEnvelope {
        let snapshot = BootstrapEntityEnvelopeV1(
            entityType: CloudEntityType.sheep.rawValue,
            entityID: entityID,
            sourceRevision: 1,
            sourcePayload: sourcePayload
        )
        var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
        wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(snapshot)
        if let baselineVersion { wrapper.integers["baselineVersion"] = baselineVersion }
        if let baselineSlot { wrapper.strings["baselineSlot"] = baselineSlot }
        if let baselineCutoffAt { wrapper.dates["baselineCutoffAt"] = baselineCutoffAt }
        let payload = try JSONEncoder.cloud.encode(wrapper)
        return makeEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: .sheep,
            payload: payload,
            modifiedAt: modifiedAt
        )
    }

    private func makeCommandEnvelope(
        farmID: UUID,
        entityID: UUID,
        entityType: CloudEntityType,
        command: FarmCommand,
        modifiedAt: Date
    ) throws -> CloudOperationEnvelope {
        try makeEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: entityType,
            payload: FarmCommandCloudPayloadEncoder.encode(command),
            modifiedAt: modifiedAt
        )
    }

    private func makeEnvelope(
        farmID: UUID,
        entityID: UUID,
        entityType: CloudEntityType,
        payload: Data,
        modifiedAt: Date
    ) -> CloudOperationEnvelope {
        CloudOperationEnvelope(
            farmID: farmID,
            entityID: entityID,
            entityType: entityType.rawValue,
            schemaVersion: 2,
            revision: 1,
            baseRevision: 0,
            operationID: UUID(),
            modifiedAt: modifiedAt,
            modifiedByAccountID: UUID(),
            modifiedByDeviceID: UUID(),
            payload: payload,
            payloadDigest: CloudPayloadDigest.hex(for: payload),
            capabilityCertificate: "test",
            operationSignature: Data(),
            deletedAt: nil
        )
    }

    private func makeCommit(
        farmID: UUID,
        ownerID: UUID,
        sourceChecksum: String,
        cloudState: MigrationCloudState
    ) -> MigrationCommitRecord {
        let commit = MigrationCommitRecord(
            sessionID: UUID(),
            sourceChecksum: sourceChecksum,
            farmID: farmID,
            ownerAccountID: ownerID,
            recordCountsJSON: "{}",
            assetsRelativeDirectory: ""
        )
        commit.cloudState = cloudState
        return commit
    }
}
