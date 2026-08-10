import CryptoKit
import Foundation
import SwiftData

struct MigrationCommitResult: Sendable, Equatable {
    let farmID: UUID
    let farmName: String
    let committedRecordCount: Int
    let photoCount: Int
    let wasAlreadyCommitted: Bool
}

enum MigrationCommitError: LocalizedError {
    case reconciliationBlocked(Int)
    case destinationFarmExists
    case sourceFarmMissing
    case photoMissing(String)
    case photoDigestMismatch(String)

    var errorDescription: String? {
        switch self {
        case .reconciliationBlocked(let count):
            "迁移对账仍有 \(count) 项阻断，不能写入正式本地牧场。"
        case .destinationFarmExists:
            "正式本地库已经存在相同迁移牧场，但没有完整提交凭据。请先检查本地数据。"
        case .sourceFarmMissing:
            "临时迁移库中没有可提交的牧场。"
        case .photoMissing(let sourceKey):
            "迁移照片文件缺失：\(sourceKey)。"
        case .photoDigestMismatch(let sourceKey):
            "迁移照片校验失败：\(sourceKey)。"
        }
    }
}

@MainActor
struct MigrationCommitService {
    func commit(
        sessionID: UUID,
        account: AccountProfile,
        destinationContext: ModelContext
    ) throws -> MigrationCommitResult {
        let session = try MigrationWorkspaceStore.load(sessionID: sessionID)
        let temporary = try LegacyMigrationImporter.openTemporaryFarm(sessionID: sessionID)
        let blockingCount = temporary.reconciliation.blockingDiscrepancies.count
        guard blockingCount == 0 else { throw MigrationCommitError.reconciliationBlocked(blockingCount) }

        let existingCommits = try destinationContext.fetch(FetchDescriptor<MigrationCommitRecord>())
        if let existing = existingCommits.first(where: {
            ($0.sessionID == sessionID || $0.sourceChecksum == session.manifest.sourceChecksum)
                && $0.ownerAccountID == account.effectiveAccountID
                && $0.status == .completed
        }), let farm = try destinationContext.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == existing.farmID }) {
            do {
                let sourceContext = ModelContext(temporary.container)
                let repairedFeedCount = try repairMissingFeedHistory(
                    sourceFarmID: temporary.farmID,
                    destinationFarmID: farm.id,
                    source: sourceContext,
                    destination: destinationContext
                )
                if repairedFeedCount > 0 {
                    existing.recordCountsJSON = try refreshedRecordCountsJSON(
                        existing.recordCountsJSON,
                        farmID: farm.id,
                        context: destinationContext
                    )
                    _ = try MigrationCloudBootstrapService().prepare(
                        commit: existing,
                        farm: farm,
                        accountID: account.effectiveAccountID,
                        context: destinationContext,
                        allowsExistingBinding: true,
                        forceRefresh: true
                    )
                    try destinationContext.save()
                } else if farm.isLocalOnlyMigration || existing.cloudState == .localCommitted || existing.cloudState == .failed {
                    _ = try MigrationCloudBootstrapService().prepare(
                        commit: existing,
                        farm: farm,
                        accountID: account.effectiveAccountID,
                        context: destinationContext
                    )
                    try destinationContext.save()
                }
            } catch {
                destinationContext.rollback()
                throw error
            }
            return MigrationCommitResult(
                farmID: farm.id,
                farmName: farm.name,
                committedRecordCount: decodedCount(existing.recordCountsJSON),
                photoCount: try destinationContext.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == farm.id }.count,
                wasAlreadyCommitted: true
            )
        }

        let sourceContext = ModelContext(temporary.container)
        guard let sourceFarm = try sourceContext.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == temporary.farmID }) else {
            throw MigrationCommitError.sourceFarmMissing
        }
        let destinationFarms = try destinationContext.fetch(FetchDescriptor<FarmRecord>())
        guard !destinationFarms.contains(where: { $0.id == sourceFarm.id }) else {
            throw MigrationCommitError.destinationFarmExists
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let relativeAssetDirectory = "MigrationAssets/\(sourceFarm.id.uuidString.lowercased())/\(sessionID.uuidString.lowercased())"
        let finalAssetDirectory = support.appending(path: relativeAssetDirectory, directoryHint: .isDirectory)
        let stagingAssetDirectory = support.appending(path: "MigrationAssets/.staging-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingAssetDirectory, withIntermediateDirectories: true)

        do {
            let sourcePhotos = try sourceContext.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == sourceFarm.id }
            var photoRelativePaths: [UUID: String] = [:]
            let sourceWorkspace = MigrationWorkspaceStore.activeWorkspace(for: sessionID)
            for photo in sourcePhotos {
                let sourceURL = sourceWorkspace.directory.appending(path: photo.relativePath)
                guard let data = try? Data(contentsOf: sourceURL) else { throw MigrationCommitError.photoMissing(photo.legacySourceKey) }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == photo.sha256 else { throw MigrationCommitError.photoDigestMismatch(photo.legacySourceKey) }
                let fileName = "\(photo.id.uuidString.lowercased()).bin"
                try data.write(to: stagingAssetDirectory.appending(path: fileName), options: .atomic)
                photoRelativePaths[photo.id] = "\(relativeAssetDirectory)/\(fileName)"
            }

            try FileManager.default.createDirectory(at: finalAssetDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: finalAssetDirectory.path) {
                try FileManager.default.removeItem(at: finalAssetDirectory)
            }
            try FileManager.default.moveItem(at: stagingAssetDirectory, to: finalAssetDirectory)

            let destinationFarm = FarmRecord(
                id: sourceFarm.id,
                ownerAccountID: account.effectiveAccountID,
                name: sourceFarm.name,
                role: .owner,
                createdAt: sourceFarm.createdAt,
                updatedAt: .now
            )
            destinationFarm.isLocalOnlyMigration = false
            destinationContext.insert(destinationFarm)
            try copyFarmRecords(
                farmID: sourceFarm.id,
                sessionID: sessionID,
                source: sourceContext,
                destination: destinationContext,
                photoRelativePaths: photoRelativePaths
            )

            let counts = temporary.reconciliation.convertedByType
            let countsData = try JSONEncoder().encode(counts)
            let countsJSON = String(data: countsData, encoding: .utf8) ?? "{}"
            let commitRecord = MigrationCommitRecord(
                id: StableMigrationID.uuid(sessionID: sessionID, sourceKey: "formal-commit"),
                sessionID: sessionID,
                sourceChecksum: session.manifest.sourceChecksum,
                farmID: sourceFarm.id,
                ownerAccountID: account.effectiveAccountID,
                recordCountsJSON: countsJSON,
                assetsRelativeDirectory: relativeAssetDirectory
            )
            destinationContext.insert(commitRecord)
            _ = try MigrationCloudBootstrapService().prepare(
                commit: commitRecord,
                farm: destinationFarm,
                accountID: account.effectiveAccountID,
                context: destinationContext
            )
            destinationContext.insert(FarmActivity(
                id: StableMigrationID.uuid(sessionID: sessionID, sourceKey: "formal-commit-activity"),
                farmID: sourceFarm.id,
                title: "完成旧版数据迁移",
                detail: "来源校验 \(session.manifest.sourceChecksum.prefix(12))，共提交 \(counts.values.reduce(0, +)) 条迁移记录。"
            ))
            try destinationContext.save()

            return MigrationCommitResult(
                farmID: sourceFarm.id,
                farmName: sourceFarm.name,
                committedRecordCount: counts.values.reduce(0, +),
                photoCount: sourcePhotos.count,
                wasAlreadyCommitted: false
            )
        } catch {
            destinationContext.rollback()
            try? FileManager.default.removeItem(at: stagingAssetDirectory)
            try? FileManager.default.removeItem(at: finalAssetDirectory)
            throw error
        }
    }

    private func copyFarmRecords(
        farmID: UUID,
        sessionID: UUID,
        source: ModelContext,
        destination: ModelContext,
        photoRelativePaths: [UUID: String]
    ) throws {
        for value in try farmValues(PenRecord.self, farmID: farmID, source: source) {
            let copy = PenRecord(id: value.id, farmID: farmID, name: value.name, note: value.note, createdAt: value.createdAt)
            copy.isActive = value.isActive; copy.revision = value.revision; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt
            destination.insert(copy)
        }
        for value in try farmValues(SemenDonorRecord.self, farmID: farmID, source: source) {
            destination.insert(SemenDonorRecord(id: value.id, farmID: farmID, name: value.name, registrationNumber: value.registrationNumber, breed: value.breed, linkedRamID: value.linkedRamID, note: value.note, status: value.status, revision: value.revision, createdAt: value.createdAt, updatedAt: value.updatedAt, deletedAt: value.deletedAt))
        }
        for value in try farmValues(SheepRecord.self, farmID: farmID, source: source) {
            let copy = SheepRecord(id: value.id, farmID: farmID, earTag: value.earTag, legacyEarTag: value.legacyEarTag, legacySourceKey: value.legacySourceKey, isHistoricalArchive: value.isHistoricalArchive, breed: value.breed, purpose: value.purpose, isBreedingRam: value.isBreedingRam, sex: value.sex, penID: value.initialPenID, enteredAt: value.enteredAt, birthAt: value.birthAt, damID: value.damID, sireID: value.sireID, damProvenance: value.damProvenance, sireProvenance: value.sireProvenance, semenDonorID: value.semenDonorID, semenDonorNameSnapshot: value.semenDonorNameSnapshot, semenDonorRegistrationNumberSnapshot: value.semenDonorRegistrationNumberSnapshot, semenDonorBreedSnapshot: value.semenDonorBreedSnapshot, note: value.note)
            copy.statusRawValue = value.statusRawValue; copy.initialPenID = value.initialPenID; copy.removedAt = value.removedAt; copy.legacyStatusSnapshotIsAuthoritative = value.legacyStatusSnapshotIsAuthoritative; copy.legacyPenSnapshotIsAuthoritative = value.legacyPenSnapshotIsAuthoritative; copy.revision = value.revision; copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt
            copy.currentPenID = copy.isCurrentlyPresent ? value.currentPenID : nil
            destination.insert(copy)
        }
        for value in try farmValues(WeightRecord.self, farmID: farmID, source: source) {
            let copy = WeightRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, kilogramsText: value.kilogramsText, occurredAt: value.occurredAt, note: value.note)
            copy.recordedAt = value.recordedAt; copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(WeaningRecord.self, farmID: farmID, source: source) {
            let copy = WeaningRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, occurredAt: value.occurredAt, weanWeightText: value.weanWeightText, birthAt: value.birthAt, birthWeightText: value.birthWeightText, averageDailyGainText: value.averageDailyGainText, damID: value.damID, legacyDamEarTag: value.legacyDamEarTag, litterSize: value.litterSize, note: value.note, legacySourceKey: value.legacySourceKey)
            copy.recordedAt = value.recordedAt; copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(BreedingProgramRecord.self, farmID: farmID, source: source) {
            let copy = BreedingProgramRecord(id: value.id, farmID: farmID, name: value.name, createdAt: value.createdAt, legacySourceKey: value.legacySourceKey)
            copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(BreedingProgramStepRecord.self, farmID: farmID, source: source) {
            let copy = BreedingProgramStepRecord(id: value.id, farmID: farmID, programID: value.programID, dayOffset: value.dayOffset, action: value.action, sortOrder: value.sortOrder, legacySourceKey: value.legacySourceKey, createdAt: value.createdAt)
            copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(TransferRecord.self, farmID: farmID, source: source) {
            let copy = TransferRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, fromPenID: value.fromPenID, toPenID: value.toPenID, occurredAt: value.occurredAt, note: value.note)
            copy.recordedAt = value.recordedAt; copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(RemovalRecord.self, farmID: farmID, source: source) {
            let copy = RemovalRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, kind: value.kind, reason: value.reason, amountText: value.amountText, removalBatchID: value.removalBatchID, batchTotalAmountText: value.batchTotalAmountText, occurredAt: value.occurredAt, note: value.note)
            copy.recordedAt = value.recordedAt; copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(ProductionBatchRecord.self, farmID: farmID, source: source) {
            let sourceKind = ProductionBatchSource(rawValue: value.sourceRawValue) ?? .historicalMigration
            let copy = ProductionBatchRecord(id: value.id, farmID: farmID, name: value.name, purpose: value.purpose, source: sourceKind, startedAt: value.startedAt, note: value.note)
            copy.statusRawValue = value.statusRawValue; copy.endedAt = value.endedAt; copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(BatchMembershipRecord.self, farmID: farmID, source: source) {
            let copy = BatchMembershipRecord(id: value.id, farmID: farmID, batchID: value.batchID, sheepID: value.sheepID, joinedAt: value.joinedAt)
            copy.leftAt = value.leftAt; copy.leaveReason = value.leaveReason; copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(DailyPenCountRecord.self, farmID: farmID, source: source) {
            destination.insert(DailyPenCountRecord(id: value.id, farmID: farmID, penID: value.penID, purpose: value.purpose, date: value.date, count: value.count, rebuiltAt: value.rebuiltAt))
        }
        for value in try farmValues(FeedIngredientRecord.self, farmID: farmID, source: source) {
            let copy = FeedIngredientRecord(id: value.id, farmID: farmID, name: value.name, unit: value.unit, dryMatterText: value.dryMatterText, category: value.category, legacySourceKey: value.legacySourceKey, nutrientSnapshotJSON: value.nutrientSnapshotJSON, kind: value.kind, sourceTemplateID: value.sourceTemplateID, sourceTemplateCode: value.sourceTemplateCode, mixtureComponentsJSON: value.mixtureComponentsJSON, note: value.note)
            copy.isActive = value.isActive; copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(FeedRecipeRecord.self, farmID: farmID, source: source) {
            let copy = FeedRecipeRecord(id: value.id, farmID: farmID, name: value.name, note: value.note, targetPenName: value.targetPenName, targetPenID: value.targetPenID, stageRawValue: value.stageRawValue, headCount: value.headCount, legacySourceKey: value.legacySourceKey)
            copy.isActive = value.isActive; copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(FeedRecipeComponentRecord.self, farmID: farmID, source: source) {
            let copy = FeedRecipeComponentRecord(id: value.id, farmID: farmID, recipeID: value.recipeID, ingredientID: value.ingredientID, kilogramsText: value.kilogramsText, ingredientBatchID: value.ingredientBatchID, legacyBatchID: value.legacyBatchID, pricePerKilogramText: value.pricePerKilogramText, nutrientSnapshotJSON: value.nutrientSnapshotJSON)
            copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(FeedRecord.self, farmID: farmID, source: source) {
            let copy = FeedRecord(id: value.id, farmID: farmID, penID: value.penID, recipeID: value.recipeID, mode: value.mode, occurredAt: value.occurredAt, note: value.note, mealName: value.mealName, feederName: value.feederName, remainingKilogramsText: value.remainingKilogramsText, discardedKilogramsText: value.discardedKilogramsText, recipeHeadCountSnapshot: value.recipeHeadCountSnapshot, actualHeadCountSnapshot: value.actualHeadCountSnapshot, scaleFactorText: value.scaleFactorText, remainingCompositionJSON: value.remainingCompositionJSON, excludedSheepIDs: value.excludedSheepIDs, legacySourceKey: value.legacySourceKey)
            copy.recordedAt = value.recordedAt; copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(FeedRecordLine.self, farmID: farmID, source: source) {
            let copy = FeedRecordLine(
                id: value.id,
                farmID: farmID,
                feedRecordID: value.feedRecordID,
                ingredientID: value.ingredientID,
                kilogramsText: value.kilogramsText,
                stockQuantityText: value.stockQuantityText,
                ingredientNameSnapshot: value.ingredientNameSnapshot,
                ingredientBatchID: value.ingredientBatchID,
                ingredientBatchNameSnapshot: value.ingredientBatchNameSnapshot,
                pricePerKilogramTextSnapshot: value.pricePerKilogramTextSnapshot,
                nutrientSnapshotJSON: value.nutrientSnapshotJSON,
                unitSnapshot: value.unitSnapshot,
                dryMatterTextSnapshot: value.dryMatterTextSnapshot
            )
            copy.createdAt = value.createdAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(FeedTroughObservationRecord.self, farmID: farmID, source: source) {
            let copy = FeedTroughObservationRecord(
                id: value.id,
                farmID: farmID,
                penID: value.penID,
                relatedFeedRecordID: value.relatedFeedRecordID,
                feederName: value.feederName,
                observedAt: value.observedAt,
                actualRemainingKilogramsText: value.actualRemainingKilogramsText,
                discardedKilogramsText: value.discardedKilogramsText,
                measurementMethod: value.measurementMethod,
                compositionSnapshotJSON: value.compositionSnapshotJSON,
                note: value.note
            )
            copy.recordedAt = value.recordedAt; copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(InventoryLotRecord.self, farmID: farmID, source: source) {
            let kind = HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment
            let copy = InventoryLotRecord(id: value.id, farmID: farmID, catalogName: value.catalogName, catalogItemID: value.catalogItemID, kind: kind, expiresAt: value.expiresAt, startingQuantityText: value.startingQuantityText, legacySourceKey: value.legacySourceKey, batchNumber: value.batchNumber, supplier: value.supplier, receivedAt: value.receivedAt, unit: value.unit)
            copy.createdAt = value.createdAt; copy.isActive = value.isActive; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(InventoryTransactionRecord.self, farmID: farmID, source: source) {
            let copy = InventoryTransactionRecord(id: value.id, farmID: farmID, inventoryLotID: value.inventoryLotID, kind: value.kind, quantityText: value.quantityText, occurredAt: value.occurredAt, sourceRecordID: value.sourceRecordID, note: value.note)
            copy.createdAt = value.createdAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(HealthRecord.self, farmID: farmID, source: source) {
            let kind = HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment
            let copy = HealthRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, penID: value.penID, kind: kind, itemNameSnapshot: value.itemNameSnapshot, occurredAt: value.occurredAt, note: value.note, inventoryLotID: value.inventoryLotID, catalogItemID: value.catalogItemID, batchID: value.batchID, quantityText: value.quantityText, unit: value.unit, route: value.route, legacySourceKey: value.legacySourceKey)
            copy.createdAt = value.createdAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(ReproductionRecord.self, farmID: farmID, source: source) {
            let copy = ReproductionRecord(id: value.id, farmID: farmID, eweID: value.eweID, kind: value.kind, occurredAt: value.occurredAt, sireID: value.sireID, semenID: value.semenID, batchID: value.batchID, relatedBreedingRecordID: value.relatedBreedingRecordID, semenNameSnapshot: value.semenNameSnapshot, semenDonorID: value.semenDonorID, semenDonorNameSnapshot: value.semenDonorNameSnapshot, semenDonorRegistrationNumberSnapshot: value.semenDonorRegistrationNumberSnapshot, semenDonorBreedSnapshot: value.semenDonorBreedSnapshot, paternalSource: value.paternalSource, result: value.result, lambCount: value.lambCount, parity: value.parity, birthDeadCount: value.birthDeadCount, note: value.note, legacySourceKey: value.legacySourceKey)
            copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(SemenRecord.self, farmID: farmID, source: source) {
            let copy = SemenRecord(id: value.id, farmID: farmID, code: value.code, breed: value.breed, source: value.source, batchNumber: value.batchNumber, quantityText: value.quantityText, donorID: value.donorID, legacySourceKey: value.legacySourceKey)
            copy.revision = value.revision; copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(NoteRecord.self, farmID: farmID, source: source) {
            let copy = NoteRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, penID: value.penID, text: value.text, occurredAt: value.occurredAt)
            copy.createdAt = value.createdAt; copy.deletedAt = value.deletedAt; copy.revision = value.revision; destination.insert(copy)
        }
        for value in try farmValues(HealthSubjectLink.self, farmID: farmID, source: source) {
            let copy = HealthSubjectLink(id: value.id, farmID: farmID, healthRecordID: value.healthRecordID, sheepID: value.sheepID)
            copy.createdAt = value.createdAt; destination.insert(copy)
        }
        for value in try farmValues(LambingOffspringRecord.self, farmID: farmID, source: source) {
            let copy = LambingOffspringRecord(id: value.id, farmID: farmID, lambingRecordID: value.lambingRecordID, sheepID: value.sheepID, legacyEarTag: value.legacyEarTag, sexRawValue: value.sexRawValue, birthWeightText: value.birthWeightText, isStillborn: value.isStillborn, autoCreatedSheep: value.autoCreatedSheep, autoBirthWeightRecordID: value.autoBirthWeightRecordID)
            copy.autoPedigreeRevokedByLambing = value.autoPedigreeRevokedByLambing; copy.autoBirthWeightRevokedByLambing = value.autoBirthWeightRevokedByLambing; copy.deletedByLambingRevocation = value.deletedByLambingRevocation; copy.revision = value.revision; copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(PedigreeChangeRecord.self, farmID: farmID, source: source) {
            destination.insert(PedigreeChangeRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, beforeDamID: value.beforeDamID, afterDamID: value.afterDamID, beforeSireID: value.beforeSireID, afterSireID: value.afterSireID, beforeSemenDonorID: value.beforeSemenDonorID, afterSemenDonorID: value.afterSemenDonorID, beforeDamSourceRawValue: value.beforeDamSourceRawValue, afterDamSourceRawValue: value.afterDamSourceRawValue, beforeSireSourceRawValue: value.beforeSireSourceRawValue, afterSireSourceRawValue: value.afterSireSourceRawValue, reason: value.reason, changedByAccountID: value.changedByAccountID, sheepRevision: value.sheepRevision, occurredAt: value.occurredAt))
        }
        for value in try farmValues(FeedIngredientBatchRecord.self, farmID: farmID, source: source) {
            let copy = FeedIngredientBatchRecord(id: value.id, farmID: farmID, ingredientID: value.ingredientID, legacySourceKey: value.legacySourceKey, batchName: value.batchName, purchaseDate: value.purchaseDate, supplier: value.supplier, storageLocation: value.storageLocation, pricePerKilogramText: value.pricePerKilogramText, purchasedKilogramsText: value.purchasedKilogramsText, packagingKind: value.packagingKind, packageCountText: value.packageCountText, nominalPackageKilogramsText: value.nominalPackageKilogramsText, stockWeightConfirmed: value.stockWeightConfirmed, initialKilogramsText: value.initialKilogramsText, remainingKilogramsText: value.remainingKilogramsText, note: value.note, isActive: value.isActive)
            copy.createdAt = value.createdAt; copy.updatedAt = value.updatedAt; copy.revision = value.revision; copy.deletedAt = value.deletedAt; destination.insert(copy)
        }
        for value in try farmValues(HealthCatalogItemRecord.self, farmID: farmID, source: source) {
            let copy = HealthCatalogItemRecord(id: value.id, farmID: farmID, legacySourceKey: value.legacySourceKey, legacyCatalogID: value.legacyCatalogID, kindRawValue: value.kindRawValue, name: value.name, category: value.category, unit: value.unit, defaultDoseText: value.defaultDoseText, defaultRoute: value.defaultRoute, reminderIntervalDays: value.reminderIntervalDays, note: value.note, isActive: value.isActive)
            copy.createdAt = value.createdAt; destination.insert(copy)
        }
        for value in try farmValues(PhotoAssetRecord.self, farmID: farmID, source: source) {
            guard let relativePath = photoRelativePaths[value.id] else { throw MigrationCommitError.photoMissing(value.legacySourceKey) }
            let copy = PhotoAssetRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, legacySourceKey: value.legacySourceKey, originalEarTag: value.originalEarTag, relativePath: relativePath, sha256: value.sha256, mimeType: value.mimeType)
            copy.sourceSHA256 = value.sourceSHA256; copy.sourcePixelWidth = value.sourcePixelWidth; copy.sourcePixelHeight = value.sourcePixelHeight; copy.cloudPixelWidth = value.cloudPixelWidth; copy.cloudPixelHeight = value.cloudPixelHeight; copy.capturedAt = value.capturedAt; copy.createdAt = value.createdAt; copy.deletedAt = value.deletedAt
            destination.insert(copy)
        }
        for value in try source.fetch(FetchDescriptor<MigrationAuditRecord>()).filter({ $0.sessionID == sessionID }) {
            let copy = MigrationAuditRecord(id: value.id, sessionID: value.sessionID, sourceKey: value.sourceKey, entityType: value.entityType, targetEntityIDsJSON: value.targetEntityIDsJSON, rawPayloadJSON: value.rawPayloadJSON, resolution: value.resolution, exclusionReason: value.exclusionReason)
            copy.createdAt = value.createdAt; destination.insert(copy)
        }
    }

    private func farmValues<T: PersistentModel>(_ type: T.Type, farmID: UUID, source: ModelContext) throws -> [T] {
        try source.fetch(FetchDescriptor<T>()).filter { value in
            switch value {
            case let item as PenRecord: item.farmID == farmID
            case let item as SheepRecord: item.farmID == farmID
            case let item as WeightRecord: item.farmID == farmID
            case let item as WeaningRecord: item.farmID == farmID
            case let item as BreedingProgramRecord: item.farmID == farmID
            case let item as BreedingProgramStepRecord: item.farmID == farmID
            case let item as TransferRecord: item.farmID == farmID
            case let item as RemovalRecord: item.farmID == farmID
            case let item as ProductionBatchRecord: item.farmID == farmID
            case let item as BatchMembershipRecord: item.farmID == farmID
            case let item as DailyPenCountRecord: item.farmID == farmID
            case let item as FeedIngredientRecord: item.farmID == farmID
            case let item as FeedRecipeRecord: item.farmID == farmID
            case let item as FeedRecipeComponentRecord: item.farmID == farmID
            case let item as FeedRecord: item.farmID == farmID
            case let item as FeedRecordLine: item.farmID == farmID
            case let item as FeedTroughObservationRecord: item.farmID == farmID
            case let item as InventoryLotRecord: item.farmID == farmID
            case let item as InventoryTransactionRecord: item.farmID == farmID
            case let item as HealthRecord: item.farmID == farmID
            case let item as ReproductionRecord: item.farmID == farmID
            case let item as SemenRecord: item.farmID == farmID
            case let item as SemenDonorRecord: item.farmID == farmID
            case let item as PedigreeChangeRecord: item.farmID == farmID
            case let item as NoteRecord: item.farmID == farmID
            case let item as HealthSubjectLink: item.farmID == farmID
            case let item as LambingOffspringRecord: item.farmID == farmID
            case let item as FeedIngredientBatchRecord: item.farmID == farmID
            case let item as HealthCatalogItemRecord: item.farmID == farmID
            case let item as PhotoAssetRecord: item.farmID == farmID
            default: false
            }
        }
    }

    /// Supplements feed history omitted by older importer builds. Historical
    /// feeds intentionally do not create stock transactions: the current stock
    /// baseline remains authoritative from the date the new feed ledger starts.
    private func repairMissingFeedHistory(
        sourceFarmID: UUID,
        destinationFarmID: UUID,
        source: ModelContext,
        destination: ModelContext
    ) throws -> Int {
        var insertedEntities = 0
        let sourceIngredients = try farmValues(FeedIngredientRecord.self, farmID: sourceFarmID, source: source)
        var destinationIngredients = try farmValues(FeedIngredientRecord.self, farmID: destinationFarmID, source: destination)
        var ingredientMap: [UUID: UUID] = [:]
        for value in sourceIngredients {
            let match = destinationIngredients.first {
                ($0.legacySourceKey != nil && $0.legacySourceKey == value.legacySourceKey)
                    || ($0.sourceTemplateID != nil && $0.sourceTemplateID == value.sourceTemplateID)
                    || ($0.name == value.name && $0.category == value.category)
            }
            if let match {
                ingredientMap[value.id] = match.id
                continue
            }
            let copy = FeedIngredientRecord(
                id: value.id,
                farmID: destinationFarmID,
                name: value.name,
                unit: value.unit,
                dryMatterText: value.dryMatterText,
                category: value.category,
                legacySourceKey: value.legacySourceKey,
                nutrientSnapshotJSON: value.nutrientSnapshotJSON,
                kind: value.kind,
                sourceTemplateID: value.sourceTemplateID,
                sourceTemplateCode: value.sourceTemplateCode,
                mixtureComponentsJSON: value.mixtureComponentsJSON,
                note: value.note
            )
            copy.isActive = value.isActive
            copy.createdAt = value.createdAt
            copy.updatedAt = value.updatedAt
            copy.deletedAt = value.deletedAt
            destination.insert(copy)
            insertedEntities += 1
            destinationIngredients.append(copy)
            ingredientMap[value.id] = copy.id
        }

        let sourceBatches = try farmValues(FeedIngredientBatchRecord.self, farmID: sourceFarmID, source: source)
        var destinationBatches = try farmValues(FeedIngredientBatchRecord.self, farmID: destinationFarmID, source: destination)
        var batchMap: [UUID: UUID] = [:]
        for value in sourceBatches {
            guard let ingredientID = ingredientMap[value.ingredientID] else { continue }
            let match = destinationBatches.first {
                ($0.legacySourceKey == value.legacySourceKey && !value.legacySourceKey.isEmpty)
                    || ($0.ingredientID == ingredientID && $0.batchName == value.batchName)
            }
            if let match {
                batchMap[value.id] = match.id
                continue
            }
            let copy = FeedIngredientBatchRecord(
                id: value.id,
                farmID: destinationFarmID,
                ingredientID: ingredientID,
                legacySourceKey: value.legacySourceKey,
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
            )
            copy.createdAt = value.createdAt
            copy.updatedAt = value.updatedAt
            copy.revision = value.revision
            copy.deletedAt = value.deletedAt
            destination.insert(copy)
            insertedEntities += 1
            destinationBatches.append(copy)
            batchMap[value.id] = copy.id
        }

        let sourceRecipes = try farmValues(FeedRecipeRecord.self, farmID: sourceFarmID, source: source)
        var destinationRecipes = try farmValues(FeedRecipeRecord.self, farmID: destinationFarmID, source: destination)
        var recipeMap: [UUID: UUID] = [:]
        let destinationPens = try farmValues(PenRecord.self, farmID: destinationFarmID, source: destination)
        let sourcePens = try farmValues(PenRecord.self, farmID: sourceFarmID, source: source)
        let penMap = Dictionary(uniqueKeysWithValues: sourcePens.compactMap { sourcePen in
            destinationPens.first(where: { $0.name == sourcePen.name }).map { (sourcePen.id, $0.id) }
        })
        for value in sourceRecipes {
            let match = destinationRecipes.first {
                ($0.legacySourceKey != nil && $0.legacySourceKey == value.legacySourceKey)
                    || $0.name == value.name
            }
            if let match {
                recipeMap[value.id] = match.id
                continue
            }
            let copy = FeedRecipeRecord(
                id: value.id,
                farmID: destinationFarmID,
                name: value.name,
                note: value.note,
                targetPenName: value.targetPenName,
                targetPenID: value.targetPenID.flatMap { penMap[$0] },
                stageRawValue: value.stageRawValue,
                headCount: value.headCount,
                legacySourceKey: value.legacySourceKey
            )
            copy.isActive = value.isActive
            copy.createdAt = value.createdAt
            copy.updatedAt = value.updatedAt
            copy.deletedAt = value.deletedAt
            destination.insert(copy)
            insertedEntities += 1
            destinationRecipes.append(copy)
            recipeMap[value.id] = copy.id
        }

        var destinationComponents = try farmValues(FeedRecipeComponentRecord.self, farmID: destinationFarmID, source: destination)
        for value in try farmValues(FeedRecipeComponentRecord.self, farmID: sourceFarmID, source: source) {
            guard let recipeID = recipeMap[value.recipeID], let ingredientID = ingredientMap[value.ingredientID] else { continue }
            let batchID = value.ingredientBatchID.flatMap { batchMap[$0] }
            guard !destinationComponents.contains(where: {
                $0.recipeID == recipeID && $0.ingredientID == ingredientID
                    && $0.kilogramsText == value.kilogramsText && $0.ingredientBatchID == batchID
            }) else { continue }
            let copy = FeedRecipeComponentRecord(
                id: value.id,
                farmID: destinationFarmID,
                recipeID: recipeID,
                ingredientID: ingredientID,
                kilogramsText: value.kilogramsText,
                ingredientBatchID: batchID,
                legacyBatchID: value.legacyBatchID,
                pricePerKilogramText: value.pricePerKilogramText,
                nutrientSnapshotJSON: value.nutrientSnapshotJSON
            )
            copy.createdAt = value.createdAt
            copy.updatedAt = value.updatedAt
            copy.deletedAt = value.deletedAt
            destination.insert(copy)
            destinationComponents.append(copy)
            insertedEntities += 1
        }

        let sourceFeeds = try farmValues(FeedRecord.self, farmID: sourceFarmID, source: source)
        var destinationFeeds = try farmValues(FeedRecord.self, farmID: destinationFarmID, source: destination)
        var feedMap: [UUID: UUID] = [:]
        for value in sourceFeeds {
            let match = destinationFeeds.first {
                ($0.legacySourceKey != nil && $0.legacySourceKey == value.legacySourceKey)
                    || $0.id == value.id
            }
            if let match {
                feedMap[value.id] = match.id
                continue
            }
            guard let penID = penMap[value.penID] else { continue }
            let copy = FeedRecord(
                id: value.id,
                farmID: destinationFarmID,
                penID: penID,
                recipeID: value.recipeID.flatMap { recipeMap[$0] },
                mode: value.mode,
                occurredAt: value.occurredAt,
                note: value.note,
                mealName: value.mealName,
                feederName: value.feederName,
                remainingKilogramsText: value.remainingKilogramsText,
                discardedKilogramsText: value.discardedKilogramsText,
                recipeHeadCountSnapshot: value.recipeHeadCountSnapshot,
                actualHeadCountSnapshot: value.actualHeadCountSnapshot,
                scaleFactorText: value.scaleFactorText,
                remainingCompositionJSON: value.remainingCompositionJSON,
                // This compatibility repair only imports historical feed data;
                // pre-V10 sources never carried stable excluded-sheep UUIDs.
                excludedSheepIDs: [],
                legacySourceKey: value.legacySourceKey
            )
            copy.recordedAt = value.recordedAt
            copy.revision = value.revision
            copy.deletedAt = value.deletedAt
            destination.insert(copy)
            destinationFeeds.append(copy)
            feedMap[value.id] = copy.id
            insertedEntities += 1
        }

        var destinationLines = try farmValues(FeedRecordLine.self, farmID: destinationFarmID, source: destination)
        for value in try farmValues(FeedRecordLine.self, farmID: sourceFarmID, source: source) {
            guard let feedRecordID = feedMap[value.feedRecordID], let ingredientID = ingredientMap[value.ingredientID] else { continue }
            let batchID = value.ingredientBatchID.flatMap { batchMap[$0] }
            guard !destinationLines.contains(where: {
                $0.feedRecordID == feedRecordID && $0.ingredientID == ingredientID
                    && $0.kilogramsText == value.kilogramsText
                    && $0.ingredientBatchNameSnapshot == value.ingredientBatchNameSnapshot
            }) else { continue }
            let copy = FeedRecordLine(
                id: value.id,
                farmID: destinationFarmID,
                feedRecordID: feedRecordID,
                ingredientID: ingredientID,
                kilogramsText: value.kilogramsText,
                stockQuantityText: value.stockQuantityText,
                ingredientNameSnapshot: value.ingredientNameSnapshot,
                ingredientBatchID: batchID,
                ingredientBatchNameSnapshot: value.ingredientBatchNameSnapshot,
                pricePerKilogramTextSnapshot: value.pricePerKilogramTextSnapshot,
                nutrientSnapshotJSON: value.nutrientSnapshotJSON,
                unitSnapshot: value.unitSnapshot,
                dryMatterTextSnapshot: value.dryMatterTextSnapshot
            )
            copy.createdAt = value.createdAt
            copy.deletedAt = value.deletedAt
            destination.insert(copy)
            destinationLines.append(copy)
            insertedEntities += 1
        }
        return insertedEntities
    }

    private func refreshedRecordCountsJSON(
        _ current: String,
        farmID: UUID,
        context: ModelContext
    ) throws -> String {
        var counts = current.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        counts["原料"] = try farmValues(FeedIngredientRecord.self, farmID: farmID, source: context).count
        counts["配方"] = try farmValues(FeedRecipeRecord.self, farmID: farmID, source: context).count
        counts["投喂"] = try farmValues(FeedRecord.self, farmID: farmID, source: context).count
        return String(data: try JSONEncoder().encode(counts), encoding: .utf8) ?? current
    }

    private func decodedCount(_ json: String) -> Int {
        guard let data = json.data(using: .utf8), let counts = try? JSONDecoder().decode([String: Int].self, from: data) else { return 0 }
        return counts.values.reduce(0, +)
    }
}
