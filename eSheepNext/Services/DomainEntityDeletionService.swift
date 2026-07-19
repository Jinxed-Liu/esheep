import Foundation
import SwiftData

enum DomainEntityDeletionService {
    private static let healthInventoryReversalPrefix = "删除健康记录反向恢复库存："

    static func setDeletedAt(_ date: Date?, type: CloudEntityType, id: UUID, farmID: UUID, context: ModelContext) throws {
        switch type {
        case .farm: throw FarmPermissionError.denied(.manageFarm)
        case .pen: try context.fetch(FetchDescriptor<PenRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .sheep: try context.fetch(FetchDescriptor<SheepRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .weight: try context.fetch(FetchDescriptor<WeightRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .weaning: try context.fetch(FetchDescriptor<WeaningRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .breedingProgram:
            try context.fetch(FetchDescriptor<BreedingProgramRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
            for step in try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()) where step.farmID == farmID && step.programID == id {
                step.deletedAt = date
            }
        case .transfer: try context.fetch(FetchDescriptor<TransferRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .removal: try context.fetch(FetchDescriptor<RemovalRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .productionBatch: try context.fetch(FetchDescriptor<ProductionBatchRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .batchMembership: try context.fetch(FetchDescriptor<BatchMembershipRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .feedIngredient: try context.fetch(FetchDescriptor<FeedIngredientRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .feedRecipe: try context.fetch(FetchDescriptor<FeedRecipeRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .feedRecipeComponent: try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .feed: try context.fetch(FetchDescriptor<FeedRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .feedLine: try context.fetch(FetchDescriptor<FeedRecordLine>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .inventoryLot: try context.fetch(FetchDescriptor<InventoryLotRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .inventoryTransaction: try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .health:
            try setHealthDeletedAt(date, id: id, farmID: farmID, context: context)
        case .reproduction: try context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .semen: try context.fetch(FetchDescriptor<SemenRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .note: try context.fetch(FetchDescriptor<NoteRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .photoAsset: try context.fetch(FetchDescriptor<PhotoAssetRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .breedingProgramStep: try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).first { $0.id == id && $0.farmID == farmID }?.deletedAt = date
        case .feedIngredientBatch:
            if date != nil, let value = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        case .healthCatalogItem:
            if date != nil, let value = try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        case .healthSubjectLink:
            if date != nil, let value = try context.fetch(FetchDescriptor<HealthSubjectLink>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        case .lambingOffspring:
            if date != nil, let value = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        }
    }

    private static func setHealthDeletedAt(_ date: Date?, id: UUID, farmID: UUID, context: ModelContext) throws {
        guard let health = try context.fetch(FetchDescriptor<HealthRecord>()).first(where: { $0.id == id && $0.farmID == farmID }) else {
            return
        }

        let wasDeleted = health.deletedAt != nil
        health.deletedAt = date

        let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>())
        let reversals = transactions.filter {
            $0.farmID == farmID &&
            $0.sourceRecordID == health.id &&
            $0.kind == .adjustment &&
            $0.note.hasPrefix(healthInventoryReversalPrefix)
        }

        if date == nil {
            // Restoring the health fact must restore its original consumption as well.
            for reversal in reversals where reversal.deletedAt == nil {
                reversal.deletedAt = .now
            }
            return
        }

        guard !wasDeleted else { return }

        // A health fact may contain no inventory deduction. In that case there is
        // nothing to reverse. Each consumption is compensated once, preserving a
        // ledger rather than mutating or deleting the original transaction.
        for consumption in transactions where
            consumption.farmID == farmID &&
            consumption.sourceRecordID == health.id &&
            consumption.kind == .consumption &&
            consumption.deletedAt == nil {
            let alreadyReversed = reversals.contains {
                $0.inventoryLotID == consumption.inventoryLotID &&
                $0.quantityText == consumption.quantityText &&
                $0.deletedAt == nil
            }
            guard !alreadyReversed else { continue }
            context.insert(InventoryTransactionRecord(
                farmID: farmID,
                inventoryLotID: consumption.inventoryLotID,
                kind: .adjustment,
                quantityText: consumption.quantityText,
                occurredAt: date ?? .now,
                sourceRecordID: health.id,
                note: "\(healthInventoryReversalPrefix)\(health.id.uuidString.lowercased())"
            ))
        }
    }
}
