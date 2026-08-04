#if DEBUG
import Foundation
import SwiftData

struct DevelopmentFarmCloneResult: Sendable, Equatable {
    let sourceFarmID: UUID
    let targetFarmID: UUID
    let clonedBusinessRecordCount: Int
    let clonedOperationCount: Int
    let clonedPhotoCount: Int
    let activeSheepCount: Int
    let alreadyCompleted: Bool
}

enum DevelopmentFarmCloneError: LocalizedError {
    case sourceAndTargetMatch
    case sourceFarmMissing
    case targetFarmMissing
    case ownerMismatch
    case sourceActiveSheepCountMismatch(expected: Int, actual: Int)
    case targetNotEmpty
    case targetIsNotStrictlyLocal
    case unsupportedOperationKind(String)
    case invalidOperationPayload(UUID)
    case missingPhoto(String)
    case photoDigestMismatch(String)
    case cloneVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceAndTargetMatch:
            "源牧场和目标牧场不能相同。"
        case .sourceFarmMissing:
            "没有找到指定的源牧场。"
        case .targetFarmMissing:
            "没有找到指定的目标牧场。"
        case .ownerMismatch:
            "源牧场、目标牧场与当前本地账号不一致。"
        case .sourceActiveSheepCountMismatch(let expected, let actual):
            "源牧场在场羊只校验失败：预期 \(expected)，实际 \(actual)。"
        case .targetNotEmpty:
            "目标牧场已有养殖业务数据，已停止克隆。"
        case .targetIsNotStrictlyLocal:
            "目标牧场不是严格本地模式，已停止克隆。"
        case .unsupportedOperationKind(let value):
            "源牧场包含当前版本无法识别的操作：\(value)。"
        case .invalidOperationPayload(let operationID):
            "源牧场操作载荷无法安全重写：\(operationID.uuidString.lowercased())。"
        case .missingPhoto(let relativePath):
            "源牧场照片文件缺失：\(relativePath)。"
        case .photoDigestMismatch(let relativePath):
            "源牧场照片摘要不一致：\(relativePath)。"
        case .cloneVerificationFailed(let detail):
            "克隆后的数据校验失败：\(detail)。"
        }
    }
}

/// One-shot Development data preparation used to make a strictly local,
/// independently identified copy of a real farm for later cloud-migration
/// testing. It intentionally does not copy provider bindings, memberships,
/// capability certificates, Outbox delivery state, receipts, conflicts,
/// diagnostics, migration commits, or security incidents.
///
/// Every farm-local UUID is deterministically remapped into the target farm's
/// namespace. This keeps the original farm isolated and makes a repeated launch
/// after an interrupted pre-save attempt produce the same identifiers and photo
/// paths instead of accumulating abandoned copies.
@MainActor
enum DevelopmentFarmCloneService {
    private static let markerTitle = "Development 牧场克隆完成"

    static func clone(
        sourceFarmID: UUID,
        targetFarmID: UUID,
        account: AccountProfile,
        expectedActiveSheepCount: Int,
        context: ModelContext
    ) throws -> DevelopmentFarmCloneResult {
        guard sourceFarmID != targetFarmID else {
            throw DevelopmentFarmCloneError.sourceAndTargetMatch
        }

        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        guard let source = farms.first(where: {
            $0.id == sourceFarmID && $0.deletedAt == nil
        }) else {
            throw DevelopmentFarmCloneError.sourceFarmMissing
        }
        guard let target = farms.first(where: {
            $0.id == targetFarmID && $0.deletedAt == nil
        }) else {
            throw DevelopmentFarmCloneError.targetFarmMissing
        }
        let accountID = account.effectiveAccountID
        guard source.ownerAccountID == accountID,
              target.ownerAccountID == accountID else {
            throw DevelopmentFarmCloneError.ownerMismatch
        }

        let sheep = try farmRecords(SheepRecord.self, farmID: sourceFarmID, context: context)
        let activeSheepCount = sheep.lazy.filter {
            $0.deletedAt == nil &&
                $0.statusRawValue == SheepStatus.active.rawValue &&
                !$0.isHistoricalArchive
        }.count
        guard activeSheepCount == expectedActiveSheepCount else {
            throw DevelopmentFarmCloneError.sourceActiveSheepCountMismatch(
                expected: expectedActiveSheepCount,
                actual: activeSheepCount
            )
        }

        if let existing = try context.fetch(FetchDescriptor<FarmActivity>()).first(where: {
            $0.farmID == targetFarmID &&
                $0.title == markerTitle &&
                $0.detail == sourceFarmID.uuidString.lowercased()
        }) {
            _ = existing
            let map = CloneIDMap(
                sourceFarmID: sourceFarmID,
                targetFarmID: targetFarmID
            )
            let addedInsightRecords = try cloneInsightContent(
                sourceFarmID: sourceFarmID,
                targetFarmID: targetFarmID,
                accountID: accountID,
                map: map,
                context: context
            )
            if addedInsightRecords > 0 {
                try context.save()
            }
            let targetSheep = try farmRecords(
                SheepRecord.self,
                farmID: targetFarmID,
                context: context
            )
            return DevelopmentFarmCloneResult(
                sourceFarmID: sourceFarmID,
                targetFarmID: targetFarmID,
                clonedBusinessRecordCount: try businessRecordCount(
                    farmID: targetFarmID,
                    context: context
                ),
                clonedOperationCount: try farmRecords(
                    DomainOperation.self,
                    farmID: targetFarmID,
                    context: context
                ).count,
                clonedPhotoCount: try farmRecords(
                    PhotoAssetRecord.self,
                    farmID: targetFarmID,
                    context: context
                ).count,
                activeSheepCount: targetSheep.lazy.filter {
                    $0.deletedAt == nil &&
                        $0.statusRawValue == SheepStatus.active.rawValue &&
                        !$0.isHistoricalArchive
                }.count,
                alreadyCompleted: true
            )
        }

        guard try businessRecordCount(farmID: targetFarmID, context: context) == 0 else {
            throw DevelopmentFarmCloneError.targetNotEmpty
        }
        let storageProfiles = try context.fetch(FetchDescriptor<FarmStorageProfile>())
        let cloudBindings = try context.fetch(FetchDescriptor<CloudFarmBinding>())
        let remoteBindings = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
        guard let targetStorage = storageProfiles.first(where: {
            $0.farmID == targetFarmID
        }),
        targetStorage.mode == .localOnly,
        targetStorage.transitionState == .idle,
        targetStorage.authorityGeneration == 0,
        !cloudBindings.contains(where: {
            $0.farmID == targetFarmID
        }),
        !remoteBindings.contains(where: {
            $0.farmID == targetFarmID
        }) else {
            throw DevelopmentFarmCloneError.targetIsNotStrictlyLocal
        }

        let map = CloneIDMap(
            sourceFarmID: sourceFarmID,
            targetFarmID: targetFarmID
        )
        var createdPhotoURLs: [URL] = []

        do {
            var clonedBusinessRecordCount = 0

            let activities = try farmRecords(FarmActivity.self, farmID: sourceFarmID, context: context)
            for value in activities {
                context.insert(FarmActivity(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    title: value.title,
                    detail: value.detail,
                    occurredAt: value.occurredAt,
                    createdAt: value.createdAt
                ))
                clonedBusinessRecordCount += 1
            }

            let pens = try farmRecords(PenRecord.self, farmID: sourceFarmID, context: context)
            for value in pens {
                let record = PenRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    name: value.name,
                    note: value.note,
                    createdAt: value.createdAt
                )
                record.isActive = value.isActive
                record.revision = value.revision
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            let donors = try farmRecords(SemenDonorRecord.self, farmID: sourceFarmID, context: context)
            for value in donors {
                context.insert(SemenDonorRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    name: value.name,
                    registrationNumber: value.registrationNumber,
                    breed: value.breed,
                    linkedRamID: map.optional(value.linkedRamID),
                    note: value.note,
                    status: value.status,
                    revision: value.revision,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt,
                    deletedAt: value.deletedAt
                ))
                clonedBusinessRecordCount += 1
            }

            for value in sheep {
                let record = SheepRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    earTag: value.earTag,
                    legacyEarTag: value.legacyEarTag,
                    legacySourceKey: value.legacySourceKey,
                    isHistoricalArchive: value.isHistoricalArchive,
                    breed: value.breed,
                    purpose: value.purpose,
                    isBreedingRam: value.isBreedingRam,
                    sex: value.sex,
                    penID: map.optional(value.initialPenID),
                    enteredAt: value.enteredAt,
                    birthAt: value.birthAt,
                    damID: map.optional(value.damID),
                    sireID: map.optional(value.sireID),
                    damProvenance: value.damProvenance,
                    sireProvenance: value.sireProvenance,
                    semenDonorID: map.optional(value.semenDonorID),
                    semenDonorNameSnapshot: value.semenDonorNameSnapshot,
                    semenDonorRegistrationNumberSnapshot: value.semenDonorRegistrationNumberSnapshot,
                    semenDonorBreedSnapshot: value.semenDonorBreedSnapshot,
                    note: value.note
                )
                record.legacyStatusSnapshotIsAuthoritative = value.legacyStatusSnapshotIsAuthoritative
                record.legacyPenSnapshotIsAuthoritative = value.legacyPenSnapshotIsAuthoritative
                record.statusRawValue = value.statusRawValue
                record.currentPenID = map.optional(value.currentPenID)
                record.removedAt = value.removedAt
                record.revision = value.revision
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(WeightRecord.self, farmID: sourceFarmID, context: context) {
                let record = WeightRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    sheepID: map.id(value.sheepID),
                    kilogramsText: value.kilogramsText,
                    occurredAt: value.occurredAt,
                    note: value.note
                )
                record.recordedAt = value.recordedAt
                record.revision = value.revision
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(WeaningRecord.self, farmID: sourceFarmID, context: context) {
                let record = WeaningRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    sheepID: map.id(value.sheepID),
                    occurredAt: value.occurredAt,
                    weanWeightText: value.weanWeightText,
                    birthAt: value.birthAt,
                    birthWeightText: value.birthWeightText,
                    averageDailyGainText: value.averageDailyGainText,
                    damID: map.optional(value.damID),
                    legacyDamEarTag: value.legacyDamEarTag,
                    litterSize: value.litterSize,
                    note: value.note,
                    legacySourceKey: value.legacySourceKey
                )
                record.recordedAt = value.recordedAt
                record.revision = value.revision
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(BreedingProgramRecord.self, farmID: sourceFarmID, context: context) {
                let record = BreedingProgramRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    name: value.name,
                    createdAt: value.createdAt,
                    legacySourceKey: value.legacySourceKey
                )
                record.revision = value.revision
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(BreedingProgramStepRecord.self, farmID: sourceFarmID, context: context) {
                let record = BreedingProgramStepRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    programID: map.id(value.programID),
                    dayOffset: value.dayOffset,
                    action: value.action,
                    sortOrder: value.sortOrder,
                    legacySourceKey: value.legacySourceKey,
                    createdAt: value.createdAt
                )
                record.revision = value.revision
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(TransferRecord.self, farmID: sourceFarmID, context: context) {
                let record = TransferRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    sheepID: map.id(value.sheepID),
                    fromPenID: map.optional(value.fromPenID),
                    toPenID: map.optional(value.toPenID),
                    occurredAt: value.occurredAt,
                    note: value.note
                )
                record.recordedAt = value.recordedAt
                record.revision = value.revision
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(RemovalRecord.self, farmID: sourceFarmID, context: context) {
                let record = RemovalRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    sheepID: map.id(value.sheepID),
                    kind: value.kind,
                    reason: value.reason,
                    amountText: value.amountText,
                    removalBatchID: map.optional(value.removalBatchID),
                    batchTotalAmountText: value.batchTotalAmountText,
                    occurredAt: value.occurredAt,
                    note: value.note
                )
                record.recordedAt = value.recordedAt
                record.revision = value.revision
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(ProductionBatchRecord.self, farmID: sourceFarmID, context: context) {
                let record = ProductionBatchRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    name: value.name,
                    purpose: value.purpose,
                    source: ProductionBatchSource(rawValue: value.sourceRawValue) ?? .manual,
                    startedAt: value.startedAt,
                    note: value.note
                )
                record.statusRawValue = value.statusRawValue
                record.endedAt = value.endedAt
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(BatchMembershipRecord.self, farmID: sourceFarmID, context: context) {
                let record = BatchMembershipRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    batchID: map.id(value.batchID),
                    sheepID: map.id(value.sheepID),
                    joinedAt: value.joinedAt
                )
                record.leftAt = value.leftAt
                record.leaveReason = value.leaveReason
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(DailyPenCountRecord.self, farmID: sourceFarmID, context: context) {
                context.insert(DailyPenCountRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    penID: map.id(value.penID),
                    purpose: value.purpose,
                    date: value.date,
                    count: value.count,
                    rebuiltAt: value.rebuiltAt
                ))
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(FeedIngredientRecord.self, farmID: sourceFarmID, context: context) {
                let record = FeedIngredientRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    name: value.name,
                    unit: value.unit,
                    dryMatterText: value.dryMatterText,
                    category: value.category,
                    legacySourceKey: value.legacySourceKey,
                    nutrientSnapshotJSON: value.nutrientSnapshotJSON
                )
                record.isActive = value.isActive
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(FeedRecipeRecord.self, farmID: sourceFarmID, context: context) {
                let record = FeedRecipeRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    name: value.name,
                    note: value.note,
                    targetPenName: value.targetPenName,
                    stageRawValue: value.stageRawValue,
                    headCount: value.headCount,
                    legacySourceKey: value.legacySourceKey
                )
                record.isActive = value.isActive
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(FeedRecipeComponentRecord.self, farmID: sourceFarmID, context: context) {
                let record = FeedRecipeComponentRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    recipeID: map.id(value.recipeID),
                    ingredientID: map.id(value.ingredientID),
                    kilogramsText: value.kilogramsText,
                    legacyBatchID: value.legacyBatchID,
                    pricePerKilogramText: value.pricePerKilogramText,
                    nutrientSnapshotJSON: value.nutrientSnapshotJSON
                )
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(FeedIngredientBatchRecord.self, farmID: sourceFarmID, context: context) {
                let record = FeedIngredientBatchRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    ingredientID: map.id(value.ingredientID),
                    legacySourceKey: value.legacySourceKey,
                    batchName: value.batchName,
                    purchaseDate: value.purchaseDate,
                    supplier: value.supplier,
                    storageLocation: value.storageLocation,
                    pricePerKilogramText: value.pricePerKilogramText,
                    initialKilogramsText: value.initialKilogramsText,
                    remainingKilogramsText: value.remainingKilogramsText,
                    note: value.note,
                    isActive: value.isActive
                )
                record.createdAt = value.createdAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(FeedRecord.self, farmID: sourceFarmID, context: context) {
                let record = FeedRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    penID: map.id(value.penID),
                    recipeID: map.optional(value.recipeID),
                    mode: value.mode,
                    occurredAt: value.occurredAt,
                    note: value.note,
                    mealName: value.mealName,
                    feederName: value.feederName,
                    remainingKilogramsText: value.remainingKilogramsText,
                    discardedKilogramsText: value.discardedKilogramsText,
                    legacySourceKey: value.legacySourceKey
                )
                record.recordedAt = value.recordedAt
                record.revision = value.revision
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(FeedRecordLine.self, farmID: sourceFarmID, context: context) {
                let record = FeedRecordLine(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    feedRecordID: map.id(value.feedRecordID),
                    ingredientID: map.id(value.ingredientID),
                    kilogramsText: value.kilogramsText,
                    ingredientNameSnapshot: value.ingredientNameSnapshot,
                    ingredientBatchID: map.optional(value.ingredientBatchID),
                    ingredientBatchNameSnapshot: value.ingredientBatchNameSnapshot,
                    pricePerKilogramTextSnapshot: value.pricePerKilogramTextSnapshot,
                    nutrientSnapshotJSON: value.nutrientSnapshotJSON,
                    unitSnapshot: value.unitSnapshot,
                    dryMatterTextSnapshot: value.dryMatterTextSnapshot
                )
                record.createdAt = value.createdAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(HealthCatalogItemRecord.self, farmID: sourceFarmID, context: context) {
                let record = HealthCatalogItemRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    legacySourceKey: value.legacySourceKey,
                    legacyCatalogID: value.legacyCatalogID,
                    kindRawValue: value.kindRawValue,
                    name: value.name,
                    category: value.category,
                    unit: value.unit,
                    defaultDoseText: value.defaultDoseText,
                    defaultRoute: value.defaultRoute,
                    reminderIntervalDays: value.reminderIntervalDays,
                    note: value.note,
                    isActive: value.isActive
                )
                record.createdAt = value.createdAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(InventoryLotRecord.self, farmID: sourceFarmID, context: context) {
                let record = InventoryLotRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    catalogName: value.catalogName,
                    catalogItemID: map.optional(value.catalogItemID),
                    kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment,
                    expiresAt: value.expiresAt,
                    startingQuantityText: value.startingQuantityText,
                    legacySourceKey: value.legacySourceKey,
                    batchNumber: value.batchNumber,
                    supplier: value.supplier,
                    receivedAt: value.receivedAt,
                    unit: value.unit
                )
                record.createdAt = value.createdAt
                record.isActive = value.isActive
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(InventoryTransactionRecord.self, farmID: sourceFarmID, context: context) {
                let record = InventoryTransactionRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    inventoryLotID: map.id(value.inventoryLotID),
                    kind: value.kind,
                    quantityText: value.quantityText,
                    occurredAt: value.occurredAt,
                    sourceRecordID: map.optional(value.sourceRecordID),
                    note: value.note
                )
                record.createdAt = value.createdAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(CareBatchRecord.self, farmID: sourceFarmID, context: context) {
                let record = CareBatchRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    kind: CareBatchKind(rawValue: value.kindRawValue) ?? .health,
                    occurredAt: value.occurredAt,
                    note: value.note
                )
                record.createdAt = value.createdAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(HealthRecord.self, farmID: sourceFarmID, context: context) {
                let record = HealthRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    sheepID: map.optional(value.sheepID),
                    penID: map.optional(value.penID),
                    kind: value.kind,
                    itemNameSnapshot: value.itemNameSnapshot,
                    occurredAt: value.occurredAt,
                    note: value.note,
                    inventoryLotID: map.optional(value.inventoryLotID),
                    catalogItemID: map.optional(value.catalogItemID),
                    batchID: map.optional(value.batchID),
                    quantityText: value.quantityText,
                    unit: value.unit,
                    route: value.route,
                    legacySourceKey: value.legacySourceKey
                )
                record.createdAt = value.createdAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(HealthSubjectLink.self, farmID: sourceFarmID, context: context) {
                let record = HealthSubjectLink(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    healthRecordID: map.id(value.healthRecordID),
                    sheepID: map.id(value.sheepID)
                )
                record.createdAt = value.createdAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(SemenRecord.self, farmID: sourceFarmID, context: context) {
                let record = SemenRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    code: value.code,
                    breed: value.breed,
                    source: value.source,
                    batchNumber: value.batchNumber,
                    quantityText: value.quantityText,
                    donorID: map.optional(value.donorID),
                    legacySourceKey: value.legacySourceKey
                )
                record.revision = value.revision
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(SemenTransactionRecord.self, farmID: sourceFarmID, context: context) {
                let record = SemenTransactionRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    semenID: map.id(value.semenID),
                    kind: value.kind,
                    quantityText: value.quantityText,
                    occurredAt: value.occurredAt,
                    sourceRecordID: map.optional(value.sourceRecordID),
                    note: value.note
                )
                record.createdAt = value.createdAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(ReproductionRecord.self, farmID: sourceFarmID, context: context) {
                let record = ReproductionRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    eweID: map.id(value.eweID),
                    kind: value.kind,
                    occurredAt: value.occurredAt,
                    sireID: map.optional(value.sireID),
                    semenID: map.optional(value.semenID),
                    batchID: map.optional(value.batchID),
                    relatedBreedingRecordID: map.optional(value.relatedBreedingRecordID),
                    semenNameSnapshot: value.semenNameSnapshot,
                    semenDonorID: map.optional(value.semenDonorID),
                    semenDonorNameSnapshot: value.semenDonorNameSnapshot,
                    semenDonorRegistrationNumberSnapshot: value.semenDonorRegistrationNumberSnapshot,
                    semenDonorBreedSnapshot: value.semenDonorBreedSnapshot,
                    paternalSource: value.paternalSource,
                    result: value.result,
                    lambCount: value.lambCount,
                    parity: value.parity,
                    birthDeadCount: value.birthDeadCount,
                    note: value.note,
                    legacySourceKey: value.legacySourceKey
                )
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.revision = value.revision
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(LambingOffspringRecord.self, farmID: sourceFarmID, context: context) {
                let record = LambingOffspringRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    lambingRecordID: map.id(value.lambingRecordID),
                    sheepID: map.optional(value.sheepID),
                    legacyEarTag: value.legacyEarTag,
                    sexRawValue: value.sexRawValue,
                    birthWeightText: value.birthWeightText,
                    isStillborn: value.isStillborn,
                    autoCreatedSheep: value.autoCreatedSheep,
                    autoBirthWeightRecordID: map.optional(value.autoBirthWeightRecordID)
                )
                record.autoPedigreeRevokedByLambing = value.autoPedigreeRevokedByLambing
                record.autoBirthWeightRevokedByLambing = value.autoBirthWeightRevokedByLambing
                record.deletedByLambingRevocation = value.deletedByLambingRevocation
                record.revision = value.revision
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(PedigreeChangeRecord.self, farmID: sourceFarmID, context: context) {
                context.insert(PedigreeChangeRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    sheepID: map.id(value.sheepID),
                    beforeDamID: map.optional(value.beforeDamID),
                    afterDamID: map.optional(value.afterDamID),
                    beforeSireID: map.optional(value.beforeSireID),
                    afterSireID: map.optional(value.afterSireID),
                    beforeSemenDonorID: map.optional(value.beforeSemenDonorID),
                    afterSemenDonorID: map.optional(value.afterSemenDonorID),
                    beforeDamSourceRawValue: value.beforeDamSourceRawValue,
                    afterDamSourceRawValue: value.afterDamSourceRawValue,
                    beforeSireSourceRawValue: value.beforeSireSourceRawValue,
                    afterSireSourceRawValue: value.afterSireSourceRawValue,
                    reason: value.reason,
                    changedByAccountID: accountID,
                    sheepRevision: value.sheepRevision,
                    occurredAt: value.occurredAt
                ))
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(NoteRecord.self, farmID: sourceFarmID, context: context) {
                let record = NoteRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    sheepID: map.optional(value.sheepID),
                    penID: map.optional(value.penID),
                    text: value.text,
                    occurredAt: value.occurredAt
                )
                record.createdAt = value.createdAt
                record.deletedAt = value.deletedAt
                record.revision = value.revision
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(FarmCareRuleRecord.self, farmID: sourceFarmID, context: context) {
                let record = FarmCareRuleRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    pregnancyCheckDays: value.pregnancyCheckDays,
                    gestationDays: value.gestationDays
                )
                record.createdAt = value.createdAt
                record.updatedAt = value.updatedAt
                record.revision = value.revision
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(CareReminderRecord.self, farmID: sourceFarmID, context: context) {
                let record = CareReminderRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    kind: value.kind,
                    sourceEntityType: value.sourceEntityType,
                    sourceEntityID: map.id(value.sourceEntityID),
                    sheepID: map.optional(value.sheepID),
                    inventoryLotID: map.optional(value.inventoryLotID),
                    dueAt: value.dueAt,
                    title: value.title
                )
                record.statusRawValue = value.statusRawValue
                record.createdAt = value.createdAt
                record.completedAt = value.completedAt
                record.deletedAt = value.deletedAt
                record.revision = value.revision
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            let sourcePhotos = try farmRecords(
                PhotoAssetRecord.self,
                farmID: sourceFarmID,
                context: context
            )
            for value in sourcePhotos {
                let clonedID = map.id(value.id)
                let copied = try clonePhoto(
                    value,
                    clonedID: clonedID,
                    targetFarmID: targetFarmID
                )
                if copied.wasCreated {
                    createdPhotoURLs.append(copied.url)
                }
                let record = PhotoAssetRecord(
                    id: clonedID,
                    farmID: targetFarmID,
                    sheepID: map.optional(value.sheepID),
                    legacySourceKey: "development-clone:\(value.id.uuidString.lowercased())",
                    originalEarTag: value.originalEarTag,
                    relativePath: copied.relativePath,
                    sha256: value.sha256,
                    mimeType: value.mimeType
                )
                record.sourceSHA256 = value.sourceSHA256
                record.sourcePixelWidth = value.sourcePixelWidth
                record.sourcePixelHeight = value.sourcePixelHeight
                record.cloudPixelWidth = value.cloudPixelWidth
                record.cloudPixelHeight = value.cloudPixelHeight
                record.capturedAt = value.capturedAt
                record.cloudRecordName = nil
                record.recoveryRecordName = nil
                record.isCloudAuthoritative = false
                record.recoveryBackedUpAt = nil
                record.createdAt = value.createdAt
                record.deletedAt = value.deletedAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            for value in try farmRecords(
                SheepAvatarRecord.self,
                farmID: sourceFarmID,
                context: context
            ) {
                context.insert(SheepAvatarRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    sheepID: map.id(value.sheepID),
                    photoAssetID: map.optional(value.photoAssetID),
                    updatedAt: value.updatedAt
                ))
                clonedBusinessRecordCount += 1
            }

            clonedBusinessRecordCount += try cloneInsightContent(
                sourceFarmID: sourceFarmID,
                targetFarmID: targetFarmID,
                accountID: accountID,
                map: map,
                context: context
            )

            let sourceOperations = try farmRecords(
                DomainOperation.self,
                farmID: sourceFarmID,
                context: context
            )
            let clonedOperationCount = try cloneOperations(
                sourceOperations,
                sourceFarmID: sourceFarmID,
                targetFarmID: targetFarmID,
                accountID: accountID,
                map: map,
                context: context
            )

            for value in try farmRecords(TombstoneRecord.self, farmID: sourceFarmID, context: context) {
                let record = TombstoneRecord(
                    id: map.id(value.id),
                    farmID: targetFarmID,
                    entityType: value.entityType,
                    entityID: map.id(value.entityID),
                    deletedByAccountID: accountID,
                    reason: value.reason,
                    revision: value.revision,
                    operationID: map.optional(value.operationID)
                )
                record.deletedAt = value.deletedAt
                record.restoredByOperationID = map.optional(value.restoredByOperationID)
                record.restoredAt = value.restoredAt
                context.insert(record)
                clonedBusinessRecordCount += 1
            }

            target.locationDisplayName = source.locationDisplayName
            target.latitude = source.latitude
            target.longitude = source.longitude
            target.coordinateReferenceSystem = source.coordinateReferenceSystem
            target.addressSnapshot = source.addressSnapshot
            target.timeZoneIdentifier = source.timeZoneIdentifier
            target.locationSourceRawValue = source.locationSourceRawValue
            target.horizontalAccuracyMeters = source.horizontalAccuracyMeters
            target.locationUpdatedAt = source.locationUpdatedAt
            target.isLocalOnlyMigration = false
            target.updatedAt = .now

            targetStorage.modeRawValue = FarmStorageMode.localOnly.rawValue
            targetStorage.transitionStateRawValue = FarmStorageTransitionState.idle.rawValue
            targetStorage.authorityGeneration = 0
            targetStorage.migrationID = nil
            targetStorage.sourceModeRawValue = nil
            targetStorage.targetModeRawValue = nil
            targetStorage.updatedAt = .now

            context.insert(FarmActivity(
                id: StableMigrationID.uuid(
                    sessionID: targetFarmID,
                    sourceKey: "development-farm-clone-marker:\(sourceFarmID.uuidString.lowercased())"
                ),
                farmID: targetFarmID,
                title: markerTitle,
                detail: sourceFarmID.uuidString.lowercased(),
                occurredAt: .now,
                createdAt: .now
            ))

            try context.save()

            let targetSheep = try farmRecords(
                SheepRecord.self,
                farmID: targetFarmID,
                context: context
            )
            let targetActiveCount = targetSheep.lazy.filter {
                $0.deletedAt == nil &&
                    $0.statusRawValue == SheepStatus.active.rawValue &&
                    !$0.isHistoricalArchive
            }.count
            guard targetSheep.count == sheep.count else {
                throw DevelopmentFarmCloneError.cloneVerificationFailed(
                    "羊只总数 \(targetSheep.count) / \(sheep.count)"
                )
            }
            guard targetActiveCount == activeSheepCount else {
                throw DevelopmentFarmCloneError.cloneVerificationFailed(
                    "在场羊只 \(targetActiveCount) / \(activeSheepCount)"
                )
            }
            let targetPhotos = try farmRecords(
                PhotoAssetRecord.self,
                farmID: targetFarmID,
                context: context
            )
            guard targetPhotos.count == sourcePhotos.count else {
                throw DevelopmentFarmCloneError.cloneVerificationFailed(
                    "照片 \(targetPhotos.count) / \(sourcePhotos.count)"
                )
            }

            return DevelopmentFarmCloneResult(
                sourceFarmID: sourceFarmID,
                targetFarmID: targetFarmID,
                clonedBusinessRecordCount: clonedBusinessRecordCount,
                clonedOperationCount: clonedOperationCount,
                clonedPhotoCount: sourcePhotos.count,
                activeSheepCount: targetActiveCount,
                alreadyCompleted: false
            )
        } catch {
            context.rollback()
            for url in createdPhotoURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private static func cloneInsightContent(
        sourceFarmID: UUID,
        targetFarmID: UUID,
        accountID: UUID,
        map: CloneIDMap,
        context: ModelContext
    ) throws -> Int {
        var insertedCount = 0

        let existingConversationIDs = Set(
            try farmRecords(
                InsightConversationRecord.self,
                farmID: targetFarmID,
                context: context
            ).map(\.id)
        )
        for value in try farmRecords(
            InsightConversationRecord.self,
            farmID: sourceFarmID,
            context: context
        ) {
            let clonedID = map.id(value.id)
            guard !existingConversationIDs.contains(clonedID) else { continue }
            let record = InsightConversationRecord(
                id: clonedID,
                accountID: accountID,
                farmID: targetFarmID,
                title: value.title,
                createdAt: value.createdAt,
                revision: value.revision
            )
            record.updatedAt = value.updatedAt
            record.deletedAt = value.deletedAt
            context.insert(record)
            insertedCount += 1
        }

        let existingMessageIDs = Set(
            try farmRecords(
                InsightMessageRecord.self,
                farmID: targetFarmID,
                context: context
            ).map(\.id)
        )
        for value in try farmRecords(
            InsightMessageRecord.self,
            farmID: sourceFarmID,
            context: context
        ) {
            let clonedID = map.id(value.id)
            guard !existingMessageIDs.contains(clonedID) else { continue }
            let record = InsightMessageRecord(
                id: clonedID,
                conversationID: map.id(value.conversationID),
                accountID: accountID,
                farmID: targetFarmID,
                role: value.role,
                text: value.text,
                createdAt: value.createdAt,
                status: value.status,
                provider: value.provider,
                model: value.model,
                toolName: value.toolName
            )
            record.updatedAt = value.updatedAt
            record.errorMessage = value.errorMessage
            record.providerResponseID = value.providerResponseID
            context.insert(record)
            insertedCount += 1
        }

        let existingAttachmentIDs = Set(
            try farmRecords(
                InsightAttachmentRecord.self,
                farmID: targetFarmID,
                context: context
            ).map(\.id)
        )
        for value in try farmRecords(
            InsightAttachmentRecord.self,
            farmID: sourceFarmID,
            context: context
        ) {
            let clonedID = map.id(value.id)
            guard !existingAttachmentIDs.contains(clonedID) else { continue }
            let record = InsightAttachmentRecord(
                id: clonedID,
                conversationID: map.id(value.conversationID),
                messageID: map.optional(value.messageID),
                accountID: accountID,
                farmID: targetFarmID,
                mimeType: value.mimeType,
                imageData: value.imageData ?? Data(),
                pixelWidth: value.pixelWidth,
                pixelHeight: value.pixelHeight,
                digest: value.digest
            )
            record.imageData = value.imageData
            record.byteCount = value.byteCount
            record.createdAt = value.createdAt
            record.deletedAt = value.deletedAt
            context.insert(record)
            insertedCount += 1
        }

        let existingDraftIDs = Set(
            try farmRecords(
                InsightActionDraftRecord.self,
                farmID: targetFarmID,
                context: context
            ).map(\.id)
        )
        for value in try farmRecords(
            InsightActionDraftRecord.self,
            farmID: sourceFarmID,
            context: context
        ) {
            let clonedID = map.id(value.id)
            guard !existingDraftIDs.contains(clonedID) else { continue }
            let argumentsJSON = try remapOperationPayload(
                value.argumentsJSON,
                operationID: value.id,
                sourceFarmID: sourceFarmID,
                targetFarmID: targetFarmID,
                map: map
            )
            let record = InsightActionDraftRecord(
                id: clonedID,
                conversationID: map.id(value.conversationID),
                messageID: map.optional(value.messageID),
                accountID: accountID,
                farmID: targetFarmID,
                originDeviceID: value.originDeviceID,
                toolName: value.toolName,
                title: value.title,
                summary: value.summary,
                argumentsJSON: argumentsJSON,
                risk: value.risk,
                requiredCapability: value.requiredCapability,
                expectedEntityID: map.optional(value.expectedEntityID),
                expectedRevision: value.expectedRevision
            )
            record.reason = value.reason
            record.statusRawValue = value.statusRawValue
            record.createdAt = value.createdAt
            record.updatedAt = value.updatedAt
            record.executedOperationID = map.optional(value.executedOperationID)
            record.errorMessage = value.errorMessage
            context.insert(record)
            insertedCount += 1
        }

        let existingReceiptIDs = Set(
            try farmRecords(
                InsightExecutionReceiptRecord.self,
                farmID: targetFarmID,
                context: context
            ).map(\.sourceRequestID)
        )
        for value in try farmRecords(
            InsightExecutionReceiptRecord.self,
            farmID: sourceFarmID,
            context: context
        ) {
            let clonedSourceRequestID = map.id(value.sourceRequestID)
            guard !existingReceiptIDs.contains(clonedSourceRequestID) else { continue }
            let record = InsightExecutionReceiptRecord(
                sourceRequestID: clonedSourceRequestID,
                accountID: accountID,
                farmID: targetFarmID,
                operationID: map.id(value.operationID),
                entityType: value.entityType,
                entityID: map.optional(value.entityID)
            )
            record.createdAt = value.createdAt
            context.insert(record)
            insertedCount += 1
        }

        return insertedCount
    }

    private static func cloneOperations(
        _ operations: [DomainOperation],
        sourceFarmID: UUID,
        targetFarmID: UUID,
        accountID: UUID,
        map: CloneIDMap,
        context: ModelContext
    ) throws -> Int {
        let sourceSequences = try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
            .filter { $0.farmID == sourceFarmID }
        let sourceSequenceByOperationID = Dictionary(
            uniqueKeysWithValues: sourceSequences.map {
                ($0.operationID, $0.clientSequence)
            }
        )
        let ordered = operations.sorted {
            let lhs = sourceSequenceByOperationID[$0.id]
            let rhs = sourceSequenceByOperationID[$1.id]
            if let lhs, let rhs, lhs != rhs {
                return lhs < rhs
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        let targetSequences = try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
            .filter { $0.farmID == targetFarmID }
        var nextSequence = (targetSequences.map(\.clientSequence).max() ?? 0) + 1
        let counters = try context.fetch(FetchDescriptor<FarmOperationSequenceCounter>())
        let targetCounter = counters.first(where: { $0.farmID == targetFarmID })
            ?? FarmOperationSequenceCounter(farmID: targetFarmID)
        if targetCounter.modelContext == nil {
            context.insert(targetCounter)
        }

        for value in ordered {
            guard let kind = DomainOperationKind(rawValue: value.kindRawValue) else {
                throw DevelopmentFarmCloneError.unsupportedOperationKind(
                    value.kindRawValue
                )
            }
            let clonedID = map.id(value.id)
            let payload = try remapOperationPayload(
                value.payload,
                operationID: value.id,
                sourceFarmID: sourceFarmID,
                targetFarmID: targetFarmID,
                map: map
            )
            let record = DomainOperation(
                id: clonedID,
                farmID: targetFarmID,
                accountID: accountID,
                kind: kind,
                occurredAt: value.occurredAt,
                summary: value.summary,
                entityType: value.entityType,
                entityID: map.optional(value.entityID),
                baseRevision: value.baseRevision,
                resultingRevision: value.resultingRevision,
                payload: payload,
                sourceRequestID: map.optional(value.sourceRequestID)
            )
            record.createdAt = value.createdAt
            record.schemaVersion = value.schemaVersion
            record.modifiedByDeviceID = nil
            record.capabilityCertificate = ""
            record.operationSignature = nil
            context.insert(record)
            context.insert(FarmOperationSequenceRecord(
                id: StableMigrationID.uuid(
                    sessionID: targetFarmID,
                    sourceKey: "development-farm-clone-sequence:\(value.id.uuidString.lowercased())"
                ),
                farmID: targetFarmID,
                operationID: clonedID,
                clientSequence: nextSequence
            ))
            nextSequence += 1
        }
        targetCounter.nextSequence = nextSequence
        return ordered.count
    }

    private static func remapOperationPayload(
        _ data: Data,
        operationID: UUID,
        sourceFarmID: UUID,
        targetFarmID: UUID,
        map: CloneIDMap
    ) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw DevelopmentFarmCloneError.invalidOperationPayload(operationID)
        }
        let rewritten = remapJSONValue(
            object,
            sourceFarmID: sourceFarmID,
            targetFarmID: targetFarmID,
            map: map
        )
        guard JSONSerialization.isValidJSONObject(rewritten) else {
            throw DevelopmentFarmCloneError.invalidOperationPayload(operationID)
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: rewritten,
                options: [.sortedKeys]
            )
        } catch {
            throw DevelopmentFarmCloneError.invalidOperationPayload(operationID)
        }
    }

    private static func remapJSONValue(
        _ value: Any,
        sourceFarmID: UUID,
        targetFarmID: UUID,
        map: CloneIDMap
    ) -> Any {
        if let string = value as? String, let uuid = UUID(uuidString: string) {
            return (uuid == sourceFarmID ? targetFarmID : map.id(uuid))
                .uuidString
                .lowercased()
        }
        if let values = value as? [Any] {
            return values.map {
                remapJSONValue(
                    $0,
                    sourceFarmID: sourceFarmID,
                    targetFarmID: targetFarmID,
                    map: map
                )
            }
        }
        if let values = value as? [String: Any] {
            return values.mapValues {
                remapJSONValue(
                    $0,
                    sourceFarmID: sourceFarmID,
                    targetFarmID: targetFarmID,
                    map: map
                )
            }
        }
        return value
    }

    private static func clonePhoto(
        _ source: PhotoAssetRecord,
        clonedID: UUID,
        targetFarmID: UUID
    ) throws -> (relativePath: String, url: URL, wasCreated: Bool) {
        let fileManager = FileManager.default
        let sourceURL = PhotoTransferActor.absoluteURL(for: source.relativePath)
        guard let data = try? Data(contentsOf: sourceURL) else {
            throw DevelopmentFarmCloneError.missingPhoto(source.relativePath)
        }
        guard CloudPayloadDigest.hex(for: data) == source.sha256 else {
            throw DevelopmentFarmCloneError.photoDigestMismatch(source.relativePath)
        }

        let fileExtension = sourceURL.pathExtension.isEmpty
            ? fileExtension(for: source.mimeType)
            : sourceURL.pathExtension.lowercased()
        let relativePath = [
            "CloudAssets",
            targetFarmID.uuidString.lowercased(),
            "development-clone",
            "\(clonedID.uuidString.lowercased()).\(fileExtension)",
        ].joined(separator: "/")
        let targetURL = PhotoTransferActor.absoluteURL(for: relativePath)
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: targetURL.path) {
            guard let existing = try? Data(contentsOf: targetURL),
                  CloudPayloadDigest.hex(for: existing) == source.sha256 else {
                throw DevelopmentFarmCloneError.photoDigestMismatch(relativePath)
            }
            return (relativePath, targetURL, false)
        }
        try data.write(to: targetURL, options: [.atomic])
        return (relativePath, targetURL, true)
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/heic", "image/heif":
            "heic"
        case "image/png":
            "png"
        default:
            "jpg"
        }
    }

    private static func farmRecords<T: PersistentModel>(
        _ type: T.Type,
        farmID: UUID,
        context: ModelContext
    ) throws -> [T] {
        try context.fetch(FetchDescriptor<T>()).filter { value in
            switch value {
            case let value as FarmActivity: value.farmID == farmID
            case let value as PenRecord: value.farmID == farmID
            case let value as SheepRecord: value.farmID == farmID
            case let value as WeightRecord: value.farmID == farmID
            case let value as WeaningRecord: value.farmID == farmID
            case let value as BreedingProgramRecord: value.farmID == farmID
            case let value as BreedingProgramStepRecord: value.farmID == farmID
            case let value as TransferRecord: value.farmID == farmID
            case let value as RemovalRecord: value.farmID == farmID
            case let value as ProductionBatchRecord: value.farmID == farmID
            case let value as BatchMembershipRecord: value.farmID == farmID
            case let value as DailyPenCountRecord: value.farmID == farmID
            case let value as FeedIngredientRecord: value.farmID == farmID
            case let value as FeedRecipeRecord: value.farmID == farmID
            case let value as FeedRecipeComponentRecord: value.farmID == farmID
            case let value as FeedIngredientBatchRecord: value.farmID == farmID
            case let value as FeedRecord: value.farmID == farmID
            case let value as FeedRecordLine: value.farmID == farmID
            case let value as HealthCatalogItemRecord: value.farmID == farmID
            case let value as InventoryLotRecord: value.farmID == farmID
            case let value as InventoryTransactionRecord: value.farmID == farmID
            case let value as CareBatchRecord: value.farmID == farmID
            case let value as HealthRecord: value.farmID == farmID
            case let value as HealthSubjectLink: value.farmID == farmID
            case let value as SemenDonorRecord: value.farmID == farmID
            case let value as SemenRecord: value.farmID == farmID
            case let value as SemenTransactionRecord: value.farmID == farmID
            case let value as ReproductionRecord: value.farmID == farmID
            case let value as LambingOffspringRecord: value.farmID == farmID
            case let value as PedigreeChangeRecord: value.farmID == farmID
            case let value as NoteRecord: value.farmID == farmID
            case let value as FarmCareRuleRecord: value.farmID == farmID
            case let value as CareReminderRecord: value.farmID == farmID
            case let value as PhotoAssetRecord: value.farmID == farmID
            case let value as SheepAvatarRecord: value.farmID == farmID
            case let value as InsightConversationRecord: value.farmID == farmID
            case let value as InsightMessageRecord: value.farmID == farmID
            case let value as InsightAttachmentRecord: value.farmID == farmID
            case let value as InsightActionDraftRecord: value.farmID == farmID
            case let value as InsightExecutionReceiptRecord: value.farmID == farmID
            case let value as DomainOperation: value.farmID == farmID
            case let value as TombstoneRecord: value.farmID == farmID
            default: false
            }
        }
    }

    private static func businessRecordCount(
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        try farmRecords(FarmActivity.self, farmID: farmID, context: context).count
            + farmRecords(PenRecord.self, farmID: farmID, context: context).count
            + farmRecords(SheepRecord.self, farmID: farmID, context: context).count
            + farmRecords(WeightRecord.self, farmID: farmID, context: context).count
            + farmRecords(WeaningRecord.self, farmID: farmID, context: context).count
            + farmRecords(BreedingProgramRecord.self, farmID: farmID, context: context).count
            + farmRecords(BreedingProgramStepRecord.self, farmID: farmID, context: context).count
            + farmRecords(TransferRecord.self, farmID: farmID, context: context).count
            + farmRecords(RemovalRecord.self, farmID: farmID, context: context).count
            + farmRecords(ProductionBatchRecord.self, farmID: farmID, context: context).count
            + farmRecords(BatchMembershipRecord.self, farmID: farmID, context: context).count
            + farmRecords(DailyPenCountRecord.self, farmID: farmID, context: context).count
            + farmRecords(FeedIngredientRecord.self, farmID: farmID, context: context).count
            + farmRecords(FeedRecipeRecord.self, farmID: farmID, context: context).count
            + farmRecords(FeedRecipeComponentRecord.self, farmID: farmID, context: context).count
            + farmRecords(FeedIngredientBatchRecord.self, farmID: farmID, context: context).count
            + farmRecords(FeedRecord.self, farmID: farmID, context: context).count
            + farmRecords(FeedRecordLine.self, farmID: farmID, context: context).count
            + farmRecords(HealthCatalogItemRecord.self, farmID: farmID, context: context).count
            + farmRecords(InventoryLotRecord.self, farmID: farmID, context: context).count
            + farmRecords(InventoryTransactionRecord.self, farmID: farmID, context: context).count
            + farmRecords(CareBatchRecord.self, farmID: farmID, context: context).count
            + farmRecords(HealthRecord.self, farmID: farmID, context: context).count
            + farmRecords(HealthSubjectLink.self, farmID: farmID, context: context).count
            + farmRecords(SemenDonorRecord.self, farmID: farmID, context: context).count
            + farmRecords(SemenRecord.self, farmID: farmID, context: context).count
            + farmRecords(SemenTransactionRecord.self, farmID: farmID, context: context).count
            + farmRecords(ReproductionRecord.self, farmID: farmID, context: context).count
            + farmRecords(LambingOffspringRecord.self, farmID: farmID, context: context).count
            + farmRecords(PedigreeChangeRecord.self, farmID: farmID, context: context).count
            + farmRecords(NoteRecord.self, farmID: farmID, context: context).count
            + farmRecords(FarmCareRuleRecord.self, farmID: farmID, context: context).count
            + farmRecords(CareReminderRecord.self, farmID: farmID, context: context).count
            + farmRecords(PhotoAssetRecord.self, farmID: farmID, context: context).count
            + farmRecords(SheepAvatarRecord.self, farmID: farmID, context: context).count
            + farmRecords(InsightConversationRecord.self, farmID: farmID, context: context).count
            + farmRecords(InsightMessageRecord.self, farmID: farmID, context: context).count
            + farmRecords(InsightAttachmentRecord.self, farmID: farmID, context: context).count
            + farmRecords(InsightActionDraftRecord.self, farmID: farmID, context: context).count
            + farmRecords(InsightExecutionReceiptRecord.self, farmID: farmID, context: context).count
            + farmRecords(TombstoneRecord.self, farmID: farmID, context: context).count
    }
}

private struct CloneIDMap {
    let sourceFarmID: UUID
    let targetFarmID: UUID

    func id(_ sourceID: UUID) -> UUID {
        if sourceID == sourceFarmID {
            return targetFarmID
        }
        return StableMigrationID.uuid(
            sessionID: targetFarmID,
            sourceKey: "development-farm-clone:\(sourceID.uuidString.lowercased())"
        )
    }

    func optional(_ sourceID: UUID?) -> UUID? {
        sourceID.map(id)
    }
}
#endif
