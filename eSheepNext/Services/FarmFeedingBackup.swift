import Foundation
import SwiftData

/// 完整备份中的投喂域。直接恢复事实和不可变流水，不重新执行投喂命令，
/// 因而不会在恢复时再次扣减原料库存。
struct FarmFeedingBackupPayload: Codable, Sendable, Equatable {
    struct Ingredient: Codable, Sendable, Equatable {
        let id: UUID
        let name: String
        let category: String
        let legacySourceKey: String?
        let kindRawValue: String
        let sourceTemplateID: String?
        let sourceTemplateCode: String?
        let mixtureComponentsJSON: String?
        let note: String
        let nutrientSnapshotJSON: String
        let unit: String
        let dryMatterText: String?
        let isActive: Bool
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct IngredientBatch: Codable, Sendable, Equatable {
        let id: UUID
        let ingredientID: UUID
        let legacySourceKey: String
        let batchName: String
        let purchaseDate: Date?
        let supplier: String
        let storageLocation: String
        let pricePerKilogramText: String
        let purchasedKilogramsText: String?
        let packagingKindRawValue: String
        let packageCountText: String?
        let nominalPackageKilogramsText: String?
        let stockWeightConfirmed: Bool
        let initialKilogramsText: String?
        let remainingKilogramsText: String?
        let note: String
        let isActive: Bool
        let createdAt: Date
        let updatedAt: Date
        let revision: Int
        let deletedAt: Date?
    }

    struct StockTransaction: Codable, Sendable, Equatable {
        let id: UUID
        let ingredientBatchID: UUID
        let kindRawValue: String
        let quantityText: String
        let occurredAt: Date
        let sourceRecordID: UUID?
        let sourceLineID: UUID?
        let note: String
        let createdAt: Date
        let deletedAt: Date?
    }

    struct StockCount: Codable, Sendable, Equatable {
        let id: UUID
        let ingredientBatchID: UUID
        let bookBalanceText: String
        let actualKilogramsText: String?
        let differenceText: String?
        let methodRawValue: String
        let occurredAt: Date
        let note: String
        let adjustmentTransactionID: UUID?
        let createdAt: Date
        let deletedAt: Date?
    }

    struct Recipe: Codable, Sendable, Equatable {
        let id: UUID
        let name: String
        let targetPenID: UUID?
        let targetPenName: String?
        let stageRawValue: String
        let headCount: Int?
        let legacySourceKey: String?
        let note: String
        let isActive: Bool
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct RecipeComponent: Codable, Sendable, Equatable {
        let id: UUID
        let recipeID: UUID
        let ingredientID: UUID
        let ingredientBatchID: UUID?
        let kilogramsText: String
        let legacyBatchID: String?
        let pricePerKilogramText: String?
        let nutrientSnapshotJSON: String
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct Feed: Codable, Sendable, Equatable {
        let id: UUID
        let penID: UUID
        let recipeID: UUID?
        let modeRawValue: String
        let occurredAt: Date
        let recordedAt: Date
        let note: String
        let mealName: String
        let feederName: String
        let remainingKilogramsText: String?
        let discardedKilogramsText: String?
        let recipeHeadCountSnapshot: Int?
        let actualHeadCountSnapshot: Int?
        let scaleFactorText: String?
        let remainingCompositionJSON: String?
        let excludedSheepIDsJSON: String
        let legacySourceKey: String?
        let revision: Int
        let deletedAt: Date?
    }

    struct FeedLine: Codable, Sendable, Equatable {
        let id: UUID
        let feedRecordID: UUID
        let ingredientID: UUID
        let kilogramsText: String
        let stockQuantityText: String?
        let ingredientNameSnapshot: String
        let ingredientBatchID: UUID?
        let ingredientBatchNameSnapshot: String?
        let pricePerKilogramTextSnapshot: String?
        let nutrientSnapshotJSON: String?
        let unitSnapshot: String?
        let dryMatterTextSnapshot: String?
        let createdAt: Date
        let deletedAt: Date?
    }

    struct TroughObservation: Codable, Sendable, Equatable {
        let id: UUID
        let penID: UUID
        let relatedFeedRecordID: UUID?
        let feederName: String
        let observedAt: Date
        let actualRemainingKilogramsText: String
        let discardedKilogramsText: String?
        let measurementMethodRawValue: String
        let compositionSnapshotJSON: String?
        let note: String
        let recordedAt: Date
        let revision: Int
        let deletedAt: Date?
    }

    let ingredients: [Ingredient]
    let ingredientBatches: [IngredientBatch]
    let stockTransactions: [StockTransaction]
    let stockCounts: [StockCount]
    let recipes: [Recipe]
    let recipeComponents: [RecipeComponent]
    let feeds: [Feed]
    let feedLines: [FeedLine]
    let troughObservations: [TroughObservation]
    let tmr: FarmTMRBackupPayload?

    var entityCount: Int {
        ingredients.count + ingredientBatches.count + stockTransactions.count + stockCounts.count +
            recipes.count + recipeComponents.count + feeds.count + feedLines.count +
            troughObservations.count + (tmr?.entityCount ?? 0)
    }

    @MainActor
    static func capture(farmID: UUID, context: ModelContext) throws -> Self {
        let tmrPayload = try FarmTMRBackupPayload.capture(farmID: farmID, context: context)
        return .init(
            ingredients: try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, name: $0.name, category: $0.category, legacySourceKey: $0.legacySourceKey, kindRawValue: $0.kindRawValue, sourceTemplateID: $0.sourceTemplateID, sourceTemplateCode: $0.sourceTemplateCode, mixtureComponentsJSON: $0.mixtureComponentsJSON, note: $0.note, nutrientSnapshotJSON: $0.nutrientSnapshotJSON, unit: $0.unit, dryMatterText: $0.dryMatterText, isActive: $0.isActive, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            },
            ingredientBatches: try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, ingredientID: $0.ingredientID, legacySourceKey: $0.legacySourceKey, batchName: $0.batchName, purchaseDate: $0.purchaseDate, supplier: $0.supplier, storageLocation: $0.storageLocation, pricePerKilogramText: $0.pricePerKilogramText, purchasedKilogramsText: $0.purchasedKilogramsText, packagingKindRawValue: $0.packagingKindRawValue, packageCountText: $0.packageCountText, nominalPackageKilogramsText: $0.nominalPackageKilogramsText, stockWeightConfirmed: $0.stockWeightConfirmed, initialKilogramsText: $0.initialKilogramsText, remainingKilogramsText: $0.remainingKilogramsText, note: $0.note, isActive: $0.isActive, createdAt: $0.createdAt, updatedAt: $0.updatedAt, revision: $0.revision, deletedAt: $0.deletedAt)
            },
            stockTransactions: try context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, ingredientBatchID: $0.ingredientBatchID, kindRawValue: $0.kindRawValue, quantityText: $0.quantityText, occurredAt: $0.occurredAt, sourceRecordID: $0.sourceRecordID, sourceLineID: $0.sourceLineID, note: $0.note, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            stockCounts: try context.fetch(FetchDescriptor<FeedStockCountRecord>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, ingredientBatchID: $0.ingredientBatchID, bookBalanceText: $0.bookBalanceText, actualKilogramsText: $0.actualKilogramsText, differenceText: $0.differenceText, methodRawValue: $0.methodRawValue, occurredAt: $0.occurredAt, note: $0.note, adjustmentTransactionID: $0.adjustmentTransactionID, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            recipes: try context.fetch(FetchDescriptor<FeedRecipeRecord>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, name: $0.name, targetPenID: $0.targetPenID, targetPenName: $0.targetPenName, stageRawValue: $0.stageRawValue, headCount: $0.headCount, legacySourceKey: $0.legacySourceKey, note: $0.note, isActive: $0.isActive, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            },
            recipeComponents: try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, recipeID: $0.recipeID, ingredientID: $0.ingredientID, ingredientBatchID: $0.ingredientBatchID, kilogramsText: $0.kilogramsText, legacyBatchID: $0.legacyBatchID, pricePerKilogramText: $0.pricePerKilogramText, nutrientSnapshotJSON: $0.nutrientSnapshotJSON, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            },
            feeds: try context.fetch(FetchDescriptor<FeedRecord>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, penID: $0.penID, recipeID: $0.recipeID, modeRawValue: $0.modeRawValue, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt, note: $0.note, mealName: $0.mealName, feederName: $0.feederName, remainingKilogramsText: $0.remainingKilogramsText, discardedKilogramsText: $0.discardedKilogramsText, recipeHeadCountSnapshot: $0.recipeHeadCountSnapshot, actualHeadCountSnapshot: $0.actualHeadCountSnapshot, scaleFactorText: $0.scaleFactorText, remainingCompositionJSON: $0.remainingCompositionJSON, excludedSheepIDsJSON: $0.excludedSheepIDsJSON, legacySourceKey: $0.legacySourceKey, revision: $0.revision, deletedAt: $0.deletedAt)
            },
            feedLines: try context.fetch(FetchDescriptor<FeedRecordLine>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, feedRecordID: $0.feedRecordID, ingredientID: $0.ingredientID, kilogramsText: $0.kilogramsText, stockQuantityText: $0.stockQuantityText, ingredientNameSnapshot: $0.ingredientNameSnapshot, ingredientBatchID: $0.ingredientBatchID, ingredientBatchNameSnapshot: $0.ingredientBatchNameSnapshot, pricePerKilogramTextSnapshot: $0.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: $0.nutrientSnapshotJSON, unitSnapshot: $0.unitSnapshot, dryMatterTextSnapshot: $0.dryMatterTextSnapshot, createdAt: $0.createdAt, deletedAt: $0.deletedAt)
            },
            troughObservations: try context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).filter { $0.farmID == farmID }.map {
                .init(id: $0.id, penID: $0.penID, relatedFeedRecordID: $0.relatedFeedRecordID, feederName: $0.feederName, observedAt: $0.observedAt, actualRemainingKilogramsText: $0.actualRemainingKilogramsText, discardedKilogramsText: $0.discardedKilogramsText, measurementMethodRawValue: $0.measurementMethodRawValue, compositionSnapshotJSON: $0.compositionSnapshotJSON, note: $0.note, recordedAt: $0.recordedAt, revision: $0.revision, deletedAt: $0.deletedAt)
            },
            tmr: tmrPayload.isEmpty ? nil : tmrPayload
        )
    }

    func validate(penIDs: Set<UUID>) throws {
        try requireUnique(ingredients.map(\.id), "投喂原料")
        try requireUnique(ingredientBatches.map(\.id), "原料库存批次")
        try requireUnique(stockTransactions.map(\.id), "原料库存流水")
        try requireUnique(stockCounts.map(\.id), "原料盘点")
        try requireUnique(recipes.map(\.id), "投喂配方")
        try requireUnique(recipeComponents.map(\.id), "配方原料")
        try requireUnique(feeds.map(\.id), "投喂记录")
        try requireUnique(feedLines.map(\.id), "投喂明细")
        try requireUnique(troughObservations.map(\.id), "盘槽记录")

        let ingredientIDs = Set(ingredients.map(\.id))
        let batchIDs = Set(ingredientBatches.map(\.id))
        let recipeIDs = Set(recipes.map(\.id))
        let feedIDs = Set(feeds.map(\.id))
        for value in ingredientBatches where !ingredientIDs.contains(value.ingredientID) {
            throw FarmLocalBackupError.missingReference("feedBatch.ingredientID")
        }
        for value in stockTransactions where !batchIDs.contains(value.ingredientBatchID) {
            throw FarmLocalBackupError.missingReference("feedStockTransaction.batchID")
        }
        for value in stockCounts where !batchIDs.contains(value.ingredientBatchID) {
            throw FarmLocalBackupError.missingReference("feedStockCount.batchID")
        }
        for value in recipes {
            if let penID = value.targetPenID, !penIDs.contains(penID) {
                throw FarmLocalBackupError.missingReference("feedRecipe.targetPenID")
            }
        }
        for value in recipeComponents {
            guard recipeIDs.contains(value.recipeID), ingredientIDs.contains(value.ingredientID) else {
                throw FarmLocalBackupError.missingReference("feedRecipeComponent")
            }
            if let batchID = value.ingredientBatchID, !batchIDs.contains(batchID) {
                throw FarmLocalBackupError.missingReference("feedRecipeComponent.batchID")
            }
        }
        for value in feeds {
            guard penIDs.contains(value.penID) else {
                throw FarmLocalBackupError.missingReference("feed.penID")
            }
            if let recipeID = value.recipeID, !recipeIDs.contains(recipeID) {
                throw FarmLocalBackupError.missingReference("feed.recipeID")
            }
        }
        for value in feedLines {
            guard feedIDs.contains(value.feedRecordID), ingredientIDs.contains(value.ingredientID) else {
                throw FarmLocalBackupError.missingReference("feedLine")
            }
            if let batchID = value.ingredientBatchID, !batchIDs.contains(batchID) {
                throw FarmLocalBackupError.missingReference("feedLine.batchID")
            }
        }
        for value in troughObservations {
            guard penIDs.contains(value.penID) else {
                throw FarmLocalBackupError.missingReference("feedTrough.penID")
            }
            if let feedID = value.relatedFeedRecordID, !feedIDs.contains(feedID) {
                throw FarmLocalBackupError.missingReference("feedTrough.relatedFeedRecordID")
            }
        }
        try tmr?.validate(recipeIDs: recipeIDs, ingredientIDs: ingredientIDs, ingredientBatchIDs: batchIDs, feedRecordIDs: feedIDs, penIDs: penIDs)
    }

    @MainActor
    func insert(farmID: UUID, context: ModelContext) {
        for value in ingredients {
            let record = FeedIngredientRecord(id: value.id, farmID: farmID, name: value.name, unit: value.unit, dryMatterText: value.dryMatterText, category: value.category, legacySourceKey: value.legacySourceKey, nutrientSnapshotJSON: value.nutrientSnapshotJSON, kind: FeedIngredientKind(rawValue: value.kindRawValue) ?? .legacy, sourceTemplateID: value.sourceTemplateID, sourceTemplateCode: value.sourceTemplateCode, mixtureComponentsJSON: value.mixtureComponentsJSON, note: value.note)
            record.isActive = value.isActive; record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in ingredientBatches {
            let record = FeedIngredientBatchRecord(id: value.id, farmID: farmID, ingredientID: value.ingredientID, legacySourceKey: value.legacySourceKey, batchName: value.batchName, purchaseDate: value.purchaseDate, supplier: value.supplier, storageLocation: value.storageLocation, pricePerKilogramText: value.pricePerKilogramText, purchasedKilogramsText: value.purchasedKilogramsText, packagingKind: FeedPackagingKind(rawValue: value.packagingKindRawValue) ?? .bulk, packageCountText: value.packageCountText, nominalPackageKilogramsText: value.nominalPackageKilogramsText, stockWeightConfirmed: value.stockWeightConfirmed, initialKilogramsText: value.initialKilogramsText, remainingKilogramsText: value.remainingKilogramsText, note: value.note, isActive: value.isActive)
            record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in recipes {
            let record = FeedRecipeRecord(id: value.id, farmID: farmID, name: value.name, note: value.note, targetPenName: value.targetPenName, targetPenID: value.targetPenID, stageRawValue: value.stageRawValue, headCount: value.headCount, legacySourceKey: value.legacySourceKey)
            record.isActive = value.isActive; record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in recipeComponents {
            let record = FeedRecipeComponentRecord(id: value.id, farmID: farmID, recipeID: value.recipeID, ingredientID: value.ingredientID, kilogramsText: value.kilogramsText, ingredientBatchID: value.ingredientBatchID, legacyBatchID: value.legacyBatchID, pricePerKilogramText: value.pricePerKilogramText, nutrientSnapshotJSON: value.nutrientSnapshotJSON)
            record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in feeds {
            let record = FeedRecord(id: value.id, farmID: farmID, penID: value.penID, recipeID: value.recipeID, mode: FeedMode(rawValue: value.modeRawValue) ?? .limited, occurredAt: value.occurredAt, note: value.note, mealName: value.mealName, feederName: value.feederName, remainingKilogramsText: value.remainingKilogramsText, discardedKilogramsText: value.discardedKilogramsText, recipeHeadCountSnapshot: value.recipeHeadCountSnapshot, actualHeadCountSnapshot: value.actualHeadCountSnapshot, scaleFactorText: value.scaleFactorText, remainingCompositionJSON: value.remainingCompositionJSON, excludedSheepIDs: FeedExcludedSheepCodec.decode(value.excludedSheepIDsJSON), legacySourceKey: value.legacySourceKey)
            record.recordedAt = value.recordedAt; record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in feedLines {
            let record = FeedRecordLine(id: value.id, farmID: farmID, feedRecordID: value.feedRecordID, ingredientID: value.ingredientID, kilogramsText: value.kilogramsText, stockQuantityText: value.stockQuantityText, ingredientNameSnapshot: value.ingredientNameSnapshot, ingredientBatchID: value.ingredientBatchID, ingredientBatchNameSnapshot: value.ingredientBatchNameSnapshot, pricePerKilogramTextSnapshot: value.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: value.nutrientSnapshotJSON, unitSnapshot: value.unitSnapshot, dryMatterTextSnapshot: value.dryMatterTextSnapshot)
            record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in stockTransactions {
            let record = FeedStockTransactionRecord(id: value.id, farmID: farmID, ingredientBatchID: value.ingredientBatchID, kind: FeedStockTransactionKind(rawValue: value.kindRawValue) ?? .adjustment, quantityText: value.quantityText, occurredAt: value.occurredAt, sourceRecordID: value.sourceRecordID, sourceLineID: value.sourceLineID, note: value.note)
            record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in stockCounts {
            let record = FeedStockCountRecord(id: value.id, farmID: farmID, ingredientBatchID: value.ingredientBatchID, bookBalanceText: value.bookBalanceText, actualKilogramsText: value.actualKilogramsText, differenceText: value.differenceText, method: FeedStockCountMethod(rawValue: value.methodRawValue) ?? .notMeasured, occurredAt: value.occurredAt, note: value.note, adjustmentTransactionID: value.adjustmentTransactionID)
            record.createdAt = value.createdAt; record.deletedAt = value.deletedAt; context.insert(record)
        }
        for value in troughObservations {
            let record = FeedTroughObservationRecord(id: value.id, farmID: farmID, penID: value.penID, relatedFeedRecordID: value.relatedFeedRecordID, feederName: value.feederName, observedAt: value.observedAt, actualRemainingKilogramsText: value.actualRemainingKilogramsText, discardedKilogramsText: value.discardedKilogramsText, measurementMethod: FeedTroughMeasurementMethod(rawValue: value.measurementMethodRawValue) ?? .visualEstimate, compositionSnapshotJSON: value.compositionSnapshotJSON, note: value.note)
            record.recordedAt = value.recordedAt; record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record)
        }
        tmr?.insert(farmID: farmID, context: context)
    }

    private func requireUnique(_ ids: [UUID], _ type: String) throws {
        guard Set(ids).count == ids.count else {
            throw FarmLocalBackupError.duplicateIdentifier(type)
        }
    }
}
