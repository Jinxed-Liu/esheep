import Foundation
import SwiftData

struct FarmBootstrapEntitySnapshot: Sendable, Equatable {
    let entityType: CloudEntityType
    let entityID: UUID
    let sourceRevision: Int
    let sourcePayload: Data
    let replayOrder: Int
}

enum FarmBaselineSnapshotError: LocalizedError {
    case farmMissing
    case duplicateEarTag

    var errorDescription: String? {
        switch self {
        case .farmMissing:
            "找不到需要生成基线的牧场。"
        case .duplicateEarTag:
            "牧场存在重复耳号，不能生成云端基线。"
        }
    }
}
@MainActor
struct FarmBaselineSnapshotService {
    /// Builds provider-neutral entity snapshots for Supabase activation and
    /// portable local restore. It never inserts Outbox or remote-binding rows.
    func makeProviderNeutralSnapshots(
        farm: FarmRecord,
        context: ModelContext
    ) throws -> [FarmBootstrapEntitySnapshot] {
        guard farm.deletedAt == nil else {
            throw FarmBaselineSnapshotError.farmMissing
        }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farm.id
        }
        let normalizedTags = sheep.map { EarTag.normalized($0.earTag) }
        guard Set(normalizedTags).count == normalizedTags.count else {
            throw FarmBaselineSnapshotError.duplicateEarTag
        }

        var prepared: [(
            entityType: CloudEntityType,
            entityID: UUID,
            revision: Int,
            sourcePayload: Data,
            order: Int
        )] = []
        try appendFarm(farm, to: &prepared)
        try appendRecords(farmID: farm.id, context: context, to: &prepared)
        return prepared.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.entityID.uuidString < $1.entityID.uuidString
        }.map {
            FarmBootstrapEntitySnapshot(
                entityType: $0.entityType,
                entityID: $0.entityID,
                sourceRevision: max(1, $0.revision),
                sourcePayload: $0.sourcePayload,
                replayOrder: $0.order
            )
        }
    }

    private func appendFarm(
        _ farm: FarmRecord,
        to values: inout [(entityType: CloudEntityType, entityID: UUID, revision: Int, sourcePayload: Data, order: Int)]
    ) throws {
        var payload = FarmCommandCloudPayload(kind: .createFarm)
        payload.strings = ["name": farm.name]
        values.append((.farm, farm.id, 1, try JSONEncoder.cloud.encode(payload), 0))
        if let snapshot = farm.locationSnapshot {
            let command = FarmCommand.updateFarmLocation(
                displayName: snapshot.displayName,
                latitude: snapshot.latitude,
                longitude: snapshot.longitude,
                addressSnapshot: farm.addressSnapshot,
                timeZoneIdentifier: snapshot.timeZoneIdentifier,
                source: snapshot.source,
                horizontalAccuracyMeters: farm.horizontalAccuracyMeters
            )
            values.append((.farm, farm.id, 2, try FarmCommandCloudPayloadEncoder.encode(command), 1))
        }
    }

    private func appendRecords(
        farmID: UUID,
        context: ModelContext,
        to values: inout [(entityType: CloudEntityType, entityID: UUID, revision: Int, sourcePayload: Data, order: Int)]
    ) throws {
        for value in try context.fetch(FetchDescriptor<SemenDonorRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let initial = CareSemenDonorDraft(id: value.id, name: value.name, registrationNumber: value.registrationNumber, breed: value.breed, linkedRamID: nil, note: value.note, status: value.status, expectedRevision: 0)
            values.append((.semenDonor, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.care(.upsertSemenDonor(initial))), 5))
            if let linkedRamID = value.linkedRamID {
                let linked = CareSemenDonorDraft(id: value.id, name: value.name, registrationNumber: value.registrationNumber, breed: value.breed, linkedRamID: linkedRamID, note: value.note, status: value.status, expectedRevision: 1)
                values.append((.semenDonor, value.id, 2, try FarmCommandCloudPayloadEncoder.encode(.care(.upsertSemenDonor(linked))), 25))
            }
        }
        for value in try context.fetch(FetchDescriptor<PenRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.pen, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.createPen(name: value.name, note: value.note)), 10))
        }
        let avatarSelections = try context.fetch(FetchDescriptor<SheepAvatarRecord>())
            .filter { $0.farmID == farmID }
        var latestAvatarBySheepID: [UUID: SheepAvatarRecord] = [:]
        for selection in avatarSelections {
            if let current = latestAvatarBySheepID[selection.sheepID],
               current.updatedAt >= selection.updatedAt {
                continue
            }
            latestAvatarBySheepID[selection.sheepID] = selection
        }
        let activePhotos = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        let activePhotosByID = Dictionary(uniqueKeysWithValues: activePhotos.map { ($0.id, $0) })
        let activeReproduction = try context.fetch(FetchDescriptor<ReproductionRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        for value in try context.fetch(FetchDescriptor<SheepRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let entryParity = activeReproduction.first {
                $0.id == LambingEntrySemantics.entryParityBaselineID(sheepID: value.id)
            }?.parity
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.addSheep(earTag: value.earTag, breed: value.breed, sex: value.sex, penID: value.initialPenID, occurredAt: value.enteredAt, birthAt: value.birthAt, currentParity: entryParity, note: value.note)))
            payload.optionalStrings["legacyEarTag"] = value.legacyEarTag
            payload.optionalStrings["legacySourceKey"] = value.legacySourceKey
            payload.strings["purpose"] = value.purpose
            payload.integers["isHistoricalArchive"] = value.isHistoricalArchive ? 1 : 0
            payload.integers["isBreedingRam"] = value.isBreedingRam ? 1 : 0
            payload.integers["legacyStatusSnapshotIsAuthoritative"] = value.legacyStatusSnapshotIsAuthoritative == true ? 1 : 0
            payload.integers["legacyPenSnapshotIsAuthoritative"] = value.legacyPenSnapshotIsAuthoritative == true ? 1 : 0
            payload.strings["legacyStatusRawValue"] = value.statusRawValue
            payload.optionalIdentifiers["damID"] = value.damID
            payload.optionalIdentifiers["sireID"] = value.sireID
            payload.optionalIdentifiers["legacyCurrentPenID"] = value.currentPenID
            payload.optionalIdentifiers["semenDonorID"] = value.semenDonorID
            payload.optionalDates["legacyRemovedAt"] = value.removedAt
            payload.optionalStrings["damProvenance"] = value.damProvenanceRawValue
            payload.optionalStrings["sireProvenance"] = value.sireProvenanceRawValue
            payload.optionalStrings["semenDonorNameSnapshot"] = value.semenDonorNameSnapshot
            payload.optionalStrings["semenDonorRegistrationNumberSnapshot"] = value.semenDonorRegistrationNumberSnapshot
            payload.optionalStrings["semenDonorBreedSnapshot"] = value.semenDonorBreedSnapshot
            if let selection = latestAvatarBySheepID[value.id] {
                let selectedPhotoID: UUID?
                if let photoID = selection.photoAssetID,
                   activePhotosByID[photoID]?.sheepID == value.id {
                    selectedPhotoID = photoID
                } else {
                    selectedPhotoID = nil
                }
                SheepAvatarCloudPayload.write(
                    SheepAvatarPhotoUpdate(photoAssetID: selectedPhotoID),
                    to: &payload
                )
            }
            values.append((.sheep, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 20))
        }
        for value in try context.fetch(FetchDescriptor<WeightRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.weight, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.recordWeight(sheepID: value.sheepID, kilogramsText: value.kilogramsText, occurredAt: value.occurredAt, note: value.note)), 30))
        }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.weaning, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.recordWeaning(sheepID: value.sheepID, weanWeightText: value.weanWeightText, occurredAt: value.occurredAt, birthAt: value.birthAt, birthWeightText: value.birthWeightText, averageDailyGainText: value.averageDailyGainText, damID: value.damID, litterSize: value.litterSize, note: value.note)), 30))
        }
        let steps = try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let drafts = steps.filter { $0.programID == value.id }.sorted { $0.sortOrder < $1.sortOrder }.map { BreedingProgramStepDraft(id: $0.id, dayOffset: $0.dayOffset, action: $0.action) }
            values.append((.breedingProgram, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.createBreedingProgram(name: value.name, createdAt: value.createdAt, steps: drafts)), 10))
        }
        for value in try context.fetch(FetchDescriptor<TransferRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.transfer, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.transferSheep(sheepID: value.sheepID, toPenID: value.toPenID, occurredAt: value.occurredAt, note: value.note)), 30))
        }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.removal, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.removeSheep(sheepID: value.sheepID, kind: value.kind, reason: value.reason, amountText: value.amountText, occurredAt: value.occurredAt, note: value.note, recordID: value.id, removalBatchID: value.removalBatchID, batchTotalAmountText: value.batchTotalAmountText)), 30))
        }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.productionBatch, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.createBatch(name: value.name, purpose: value.purpose, startedAt: value.startedAt, sheepIDs: [], note: value.note)), 10))
        }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.assignSheepToBatch(batchID: value.batchID, sheepID: value.sheepID, joinedAt: value.joinedAt)))
            payload.optionalDates["leftAt"] = value.leftAt
            payload.optionalStrings["leaveReason"] = value.leaveReason
            values.append((.batchMembership, value.id, value.leftAt == nil ? 1 : 2, try JSONEncoder.cloud.encode(payload), 30))
        }
        let feedIngredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let feedIngredientIDs = Set(feedIngredients.map(\.id))
        for value in feedIngredients {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.saveFeedIngredient(FeedIngredientDraft(
                id: value.id,
                name: value.name,
                unit: value.unit,
                category: value.category,
                dryMatterText: value.dryMatterText,
                nutrientSnapshotJSON: value.nutrientSnapshotJSON,
                kind: value.kind,
                sourceTemplateID: value.sourceTemplateID,
                sourceTemplateCode: value.sourceTemplateCode,
                mixtureComponentsJSON: value.mixtureComponentsJSON,
                note: value.note
            ))))
            payload.strings["isActive"] = value.isActive ? "1" : "0"
            values.append((.feedIngredient, value.id, 1, try JSONEncoder.cloud.encode(payload), 10))
        }

        let feedBatches = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil && feedIngredientIDs.contains($0.ingredientID)
        }
        let feedBatchIDs = Set(feedBatches.map(\.id))
        for value in feedBatches {
            let command = FarmCommand.saveFeedBatch(FeedBatchDraft(
                id: value.id,
                ingredientID: value.ingredientID,
                batchName: value.batchName,
                purchaseDate: value.purchaseDate,
                supplier: value.supplier,
                storageLocation: value.storageLocation,
                pricePerKilogramText: value.pricePerKilogramText,
                purchasedKilogramsText: value.purchasedKilogramsText,
                packagingKind: value.packagingKind,
                packageCountText: value.packageCountText,
                nominalPackageKilogramsText: value.nominalPackageKilogramsText,
                stockWeightConfirmed: value.stockWeightConfirmed,
                initialKilogramsText: value.initialKilogramsText,
                remainingKilogramsText: value.remainingKilogramsText,
                note: value.note,
                isActive: value.isActive
            ))
            values.append((.feedIngredientBatch, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(command), 12))
        }

        // recordFeedV2 deterministically recreates its own consumption rows.
        // Baseline stock snapshots therefore carry every other authoritative
        // ledger row, but deliberately omit feed consumption/reversal rows so
        // a clean-device replay cannot deduct the same delivery twice.
        let allFeedRecords = try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID }
        let allFeedRecordIDs = Set(allFeedRecords.map(\.id))
        let allFeedRecordLines = try context.fetch(FetchDescriptor<FeedRecordLine>()).filter { $0.farmID == farmID }
        var deterministicFeedTransactionIDs = Set(allFeedRecordLines.map { FeedStockLedger.consumptionID(for: $0.id) })
        deterministicFeedTransactionIDs.formUnion(deterministicFeedTransactionIDs.map(FeedStockLedger.reversalID(for:)))
        let stockTransactions = try context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).filter {
            guard $0.farmID == farmID, $0.deletedAt == nil, feedBatchIDs.contains($0.ingredientBatchID) else { return false }
            let hasFeedSource = $0.sourceRecordID.map(allFeedRecordIDs.contains) == true
            let isFeedGenerated = ($0.kind == .consumption || $0.kind == .reversal) &&
                (hasFeedSource || deterministicFeedTransactionIDs.contains($0.id))
            return !isFeedGenerated
        }
        for value in stockTransactions {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.adjustFeedStock(
                batchID: value.ingredientBatchID,
                kind: value.kind,
                quantityText: value.quantityText,
                occurredAt: value.occurredAt,
                note: value.note
            )))
            payload.strings["baselineProjection"] = "1"
            payload.optionalIdentifiers = [
                "sourceRecordID": value.sourceRecordID,
                "sourceLineID": value.sourceLineID,
            ]
            values.append((.feedStockTransaction, value.id, 1, try JSONEncoder.cloud.encode(payload), 14))
        }

        for value in try context.fetch(FetchDescriptor<FeedStockCountRecord>()).filter({
            $0.farmID == farmID && $0.deletedAt == nil && feedBatchIDs.contains($0.ingredientBatchID)
        }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.countFeedStock(
                countID: value.id,
                batchID: value.ingredientBatchID,
                actualKilogramsText: value.actualKilogramsText,
                method: value.method,
                occurredAt: value.occurredAt,
                note: value.note
            )))
            payload.strings["baselineProjection"] = "1"
            payload.strings["bookBalanceText"] = value.bookBalanceText
            payload.optionalStrings["differenceText"] = value.differenceText
            payload.optionalIdentifiers["adjustmentTransactionID"] = value.adjustmentTransactionID
            values.append((.feedStockCount, value.id, 1, try JSONEncoder.cloud.encode(payload), 15))
        }

        let recipeComponents = try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let components = recipeComponents.filter { $0.recipeID == value.id }.map {
                FeedRecipeComponentDraft(
                    id: $0.id,
                    ingredientID: $0.ingredientID,
                    ingredientBatchID: $0.ingredientBatchID,
                    kilogramsText: $0.kilogramsText,
                    pricePerKilogramText: $0.pricePerKilogramText,
                    nutrientSnapshotJSON: $0.nutrientSnapshotJSON
                )
            }
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.saveFeedRecipe(FeedRecipeDraft(
                id: value.id,
                name: value.name,
                targetPenID: value.targetPenID,
                targetPenName: value.targetPenName,
                stage: value.stage,
                headCount: value.headCount,
                components: components,
                note: value.note
            ))))
            payload.strings["isActive"] = value.isActive ? "1" : "0"
            values.append((.feedRecipe, value.id, 1, try JSONEncoder.cloud.encode(payload), 18))
        }
        let feedLines = try context.fetch(FetchDescriptor<FeedRecordLine>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        for value in try context.fetch(FetchDescriptor<FeedRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let records = feedLines.filter { $0.feedRecordID == value.id }
            let lines = records.map { FarmCommandCloudPayload.FeedLine(id: $0.id, ingredientID: $0.ingredientID, kilogramsText: $0.kilogramsText, ingredientBatchID: $0.ingredientBatchID, ingredientNameSnapshot: $0.ingredientNameSnapshot, ingredientBatchNameSnapshot: $0.ingredientBatchNameSnapshot, pricePerKilogramTextSnapshot: $0.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: $0.nutrientSnapshotJSON, unitSnapshot: $0.unitSnapshot, dryMatterTextSnapshot: $0.dryMatterTextSnapshot) }
            let payload: Data
            if value.legacySourceKey != nil || records.contains(where: { $0.ingredientBatchID == nil }) {
                payload = try FarmCommandCloudPayloadEncoder.encode(.importHistoricalFeed(HistoricalFeedEntryDraft(
                    id: value.id,
                    legacySourceKey: value.legacySourceKey ?? "baseline:\(value.id.uuidString.lowercased())",
                    penID: value.penID,
                    mode: value.mode,
                    occurredAt: value.occurredAt,
                    mealName: value.mealName,
                    feederName: value.feederName,
                    remainingKilogramsText: value.remainingKilogramsText,
                    discardedKilogramsText: value.discardedKilogramsText,
                    remainingCompositionJSON: value.remainingCompositionJSON,
                    lines: records.map {
                        HistoricalFeedLineDraft(
                            id: $0.id,
                            ingredientID: $0.ingredientID,
                            kilogramsText: $0.kilogramsText,
                            ingredientNameSnapshot: $0.ingredientNameSnapshot,
                            ingredientBatchNameSnapshot: $0.ingredientBatchNameSnapshot,
                            pricePerKilogramTextSnapshot: $0.pricePerKilogramTextSnapshot,
                            nutrientSnapshotJSON: $0.nutrientSnapshotJSON ?? "{}",
                            unitSnapshot: $0.unitSnapshot ?? "千克",
                            dryMatterTextSnapshot: $0.dryMatterTextSnapshot
                        )
                    },
                    note: value.note
                )))
            } else {
                payload = try FarmCommandCloudPayloadEncoder.encode(.recordFeedV2(FeedEntryDraft(
                    id: value.id,
                    penID: value.penID,
                    recipeID: value.recipeID,
                    mode: value.mode,
                    occurredAt: value.occurredAt,
                    mealName: value.mealName,
                    feederName: value.feederName,
                    remainingKilogramsText: value.remainingKilogramsText,
                    discardedKilogramsText: value.discardedKilogramsText,
                    remainingCompositionJSON: value.remainingCompositionJSON,
                    recipeHeadCountSnapshot: value.recipeHeadCountSnapshot,
                    actualHeadCountSnapshot: value.actualHeadCountSnapshot,
                    scaleFactorText: value.scaleFactorText,
                    excludedSheepIDs: value.excludedSheepIDs,
                    lines: records.map {
                        FeedLineDraft(id: $0.id, ingredientID: $0.ingredientID, ingredientBatchID: $0.ingredientBatchID, kilogramsText: $0.kilogramsText)
                    },
                    note: value.note
                )), resolvedFeedLines: lines)
            }
            values.append((.feed, value.id, value.revision, payload, 30))
        }
        // Raw ingredients, stock ledgers, recipes, and projected FeedRecord
        // facts are restored by the generic feeding baseline above. Restore the
        // relational TMR projection and finished-product ledger only after those
        // dependencies exist so production consumption is never deducted twice.
        let tmrSnapshot = try FarmTMRBackupPayload.capture(farmID: farmID, context: context)
        if !tmrSnapshot.isEmpty {
            let baselineID = StableCloudUUID.derived(
                namespace: farmID,
                name: "tmr-baseline-projection"
            )
            values.append((
                .tmrBaseline,
                baselineID,
                1,
                try FarmCommandCloudPayloadEncoder.encodeTMRBaseline(tmrSnapshot),
                32
            ))
        }
        for value in try context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let payload = try FarmCommandCloudPayloadEncoder.encode(.recordFeedTroughObservation(FeedTroughObservationDraft(
                id: value.id,
                penID: value.penID,
                relatedFeedRecordID: value.relatedFeedRecordID,
                feederName: value.feederName,
                observedAt: value.observedAt,
                actualRemainingKilogramsText: value.actualRemainingKilogramsText,
                discardedKilogramsText: value.discardedKilogramsText,
                measurementMethod: value.measurementMethod,
                compositionSnapshotJSON: value.compositionSnapshotJSON,
                note: value.note
            )))
            values.append((.feedTroughObservation, value.id, value.revision, payload, 35))
        }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.inventoryLot, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.receiveInventory(catalogName: value.catalogName, kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment, expiresAt: value.expiresAt, quantityText: value.startingQuantityText, occurredAt: value.receivedAt ?? value.createdAt, note: "旧版迁移库存")), 10))
        }
        for value in try context.fetch(FetchDescriptor<HealthRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.health, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.recordHealth(sheepID: value.sheepID, penID: value.penID, kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment, itemName: value.itemNameSnapshot, occurredAt: value.occurredAt, note: value.note, inventoryLotID: value.inventoryLotID, quantityText: value.quantityText)), 30))
        }
        let offspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.farmID == farmID }
        for value in activeReproduction where value.id != LambingEntrySemantics.entryParityBaselineID(sheepID: value.eweID) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.recordReproduction(eweID: value.eweID, kind: value.kind, occurredAt: value.occurredAt, sireID: value.sireID, semenName: value.semenNameSnapshot, result: value.result, lambCount: value.lambCount, parity: value.parity, birthDeadCount: value.birthDeadCount, offspring: [], note: value.note)))
            payload.optionalIdentifiers["semenID"] = value.semenID
            payload.optionalIdentifiers["batchID"] = value.batchID
            payload.optionalIdentifiers["relatedBreedingRecordID"] = value.relatedBreedingRecordID
            payload.optionalIdentifiers["semenDonorID"] = value.semenDonorID
            payload.optionalStrings["semenDonorNameSnapshot"] = value.semenDonorNameSnapshot
            payload.optionalStrings["semenDonorRegistrationNumberSnapshot"] = value.semenDonorRegistrationNumberSnapshot
            payload.optionalStrings["semenDonorBreedSnapshot"] = value.semenDonorBreedSnapshot
            payload.optionalStrings["paternalSource"] = value.paternalSourceRawValue
            payload.lambingOffspring = offspring.filter { $0.lambingRecordID == value.id }.map {
                .init(id: $0.id, sheepID: $0.sheepID, earTag: $0.legacyEarTag, sexRawValue: $0.sexRawValue, birthWeightText: $0.birthWeightText, isStillborn: $0.isStillborn, autoCreatedSheep: $0.autoCreatedSheep, autoBirthWeightRecordID: $0.autoBirthWeightRecordID, deletedByLambingRevocation: $0.deletedByLambingRevocation, revision: $0.revision, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            }
            values.append((.reproduction, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 30))
        }
        for value in try context.fetch(FetchDescriptor<SemenRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.addSemen(code: value.code, breed: value.breed, source: value.source, batchNumber: value.batchNumber, quantityText: value.quantityText)))
            payload.optionalIdentifiers["donorID"] = value.donorID
            values.append((.semen, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 10))
        }
        for value in try context.fetch(FetchDescriptor<PedigreeChangeRecord>()).filter({ $0.farmID == farmID }) {
            let snapshot = CarePedigreeAuditSnapshot(id: value.id, sheepID: value.sheepID, beforeDamID: value.beforeDamID, afterDamID: value.afterDamID, beforeSireID: value.beforeSireID, afterSireID: value.afterSireID, beforeSemenDonorID: value.beforeSemenDonorID, afterSemenDonorID: value.afterSemenDonorID, beforeDamSourceRawValue: value.beforeDamSourceRawValue, afterDamSourceRawValue: value.afterDamSourceRawValue, beforeSireSourceRawValue: value.beforeSireSourceRawValue, afterSireSourceRawValue: value.afterSireSourceRawValue, reason: value.reason, changedByAccountID: value.changedByAccountID, sheepRevision: value.sheepRevision, occurredAt: value.occurredAt)
            values.append((.pedigreeChange, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.care(.restorePedigreeAudit(snapshot))), 35))
        }
        for value in try context.fetch(FetchDescriptor<NoteRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.note, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.addNote(sheepID: value.sheepID, penID: value.penID, text: value.text, occurredAt: value.occurredAt)), 30))
        }
        for value in try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).filter({ $0.farmID == farmID }) {
            let command: CareCommand
            if let weaningAgeDays = value.weaningAgeDays,
               value.operationalAlertsConfiguredAt != nil {
                command = .updateOperationalAlertRules(.init(
                    id: value.id,
                    pregnancyCheckDays: value.pregnancyCheckDays,
                    gestationDays: value.gestationDays,
                    weaningAgeDays: weaningAgeDays,
                    warningLeadDays: value.warningLeadDays,
                    digestEnabled: value.alertDigestEnabled,
                    digestMinuteOfDay: value.alertDigestMinuteOfDay
                ))
            } else {
                command = .updateRules(
                    id: value.id,
                    pregnancyCheckDays: value.pregnancyCheckDays,
                    gestationDays: value.gestationDays
                )
            }
            values.append((.careRule, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.care(command)), 10))
        }
        for value in try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).filter({ $0.farmID == farmID }) {
            let draft = FarmAlertDeferralDraft(
                id: value.id,
                alertID: value.alertID,
                alertKindRawValue: value.alertKindRawValue,
                subjectID: value.subjectID,
                sourceEntityID: value.sourceEntityID,
                conditionFingerprint: value.conditionFingerprint,
                deferredUntil: value.deferredUntil
            )
            values.append((.alertDeferral, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.care(.deferOperationalAlert(draft))), 40))
        }
    }

    private func decodePayload(_ data: Data) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }

    private static func assetURL(relativePath: String) -> URL {
        PhotoTransferActor.absoluteURL(for: relativePath)
    }
}
