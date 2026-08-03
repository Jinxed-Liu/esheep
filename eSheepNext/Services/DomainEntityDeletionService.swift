import Foundation
import SwiftData

enum DomainEntityDeletionService {
    private static let healthInventoryReversalPrefix = "删除健康记录反向恢复库存："
    private static let reproductionSemenReversalPrefix = "撤销繁殖记录反向恢复冻精："

    static func setDeletedAt(_ date: Date?, type: CloudEntityType, id: UUID, farmID: UUID, context: ModelContext) throws {
        switch type {
        case .farm: throw FarmPermissionError.denied(.manageFarm)
        case .pen: try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .sheep: try setSheepDeletedAt(date, id: id, farmID: farmID, context: context)
        case .weight: try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .weaning: try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .breedingProgram:
            try context.fetch(FetchDescriptor<BreedingProgramRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
            for step in try context.fetch(FetchDescriptor<BreedingProgramStepRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.programID == id
            })) {
                step.deletedAt = date
            }
        case .transfer: try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .removal: try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .productionBatch: try context.fetch(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .batchMembership: try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .feedIngredient: try context.fetch(FetchDescriptor<FeedIngredientRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .feedRecipe: try context.fetch(FetchDescriptor<FeedRecipeRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .feedRecipeComponent: try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .feed:
            try context.fetch(FetchDescriptor<FeedRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
            for line in try context.fetch(FetchDescriptor<FeedRecordLine>(predicate: #Predicate {
                $0.farmID == farmID && $0.feedRecordID == id
            })) {
                line.deletedAt = date
            }
        case .feedLine: try context.fetch(FetchDescriptor<FeedRecordLine>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .inventoryLot: try context.fetch(FetchDescriptor<InventoryLotRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .inventoryTransaction: try context.fetch(FetchDescriptor<InventoryTransactionRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .health:
            try setHealthDeletedAt(date, id: id, farmID: farmID, context: context)
        case .reproduction: try setReproductionDeletedAt(date, id: id, farmID: farmID, context: context)
        case .semen: try context.fetch(FetchDescriptor<SemenRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .semenDonor: try context.fetch(FetchDescriptor<SemenDonorRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .pedigreeChange: throw FarmPermissionError.denied(.deleteProtectedFacts)
        case .note: try context.fetch(FetchDescriptor<NoteRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .photoAsset:
            // Older live/cloud replay paths could leave more than one local
            // projection row for the same immutable photo ID. Deleting only
            // `.first` allowed another projection to remain visible forever.
            for photo in try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
                $0.id == id && $0.farmID == farmID
            })) {
                photo.deletedAt = date
            }
        case .breedingProgramStep: try context.fetch(FetchDescriptor<BreedingProgramStepRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .feedIngredientBatch:
            if date != nil, let value = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        case .healthCatalogItem:
            if date != nil, let value = try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        case .healthSubjectLink:
            if date != nil, let value = try context.fetch(FetchDescriptor<HealthSubjectLink>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        case .lambingOffspring:
            if date != nil, let value = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        case .careBatch: try context.fetch(FetchDescriptor<CareBatchRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .semenTransaction: try context.fetch(FetchDescriptor<SemenTransactionRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        case .careRule:
            if date != nil, let value = try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first(where: { $0.id == id && $0.farmID == farmID }) { context.delete(value) }
        case .careReminder: try context.fetch(FetchDescriptor<CareReminderRecord>(predicate: #Predicate { $0.id == id && $0.farmID == farmID })).first?.deletedAt = date
        }
    }

    private static func setSheepDeletedAt(_ date: Date?, id: UUID, farmID: UUID, context: ModelContext) throws {
        try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.id == id && $0.farmID == farmID
        })).first?.deletedAt = date

        // Parity confirmations are profile-owned facts. They must not prevent
        // deleting an otherwise unreferenced ewe or remain active as orphans.
        for record in try context.fetch(FetchDescriptor<ReproductionRecord>()) where
            record.farmID == farmID &&
            record.eweID == id &&
            record.kind == .parityBaseline {
            record.deletedAt = date
        }
    }

    private static func setHealthDeletedAt(_ date: Date?, id: UUID, farmID: UUID, context: ModelContext) throws {
        guard let health = try context.fetch(FetchDescriptor<HealthRecord>(predicate: #Predicate {
            $0.id == id && $0.farmID == farmID
        })).first else {
            return
        }

        let wasDeleted = health.deletedAt != nil
        health.deletedAt = date

        let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sourceRecordID == id
        }))
        let reversals = transactions.filter {
            $0.sourceRecordID == health.id &&
            $0.kind == .adjustment &&
            $0.note.hasPrefix(healthInventoryReversalPrefix)
        }

        if date == nil {
            // Restoring the health fact must restore its original consumption as well.
            for reversal in reversals where reversal.deletedAt == nil {
                reversal.deletedAt = .now
            }
            restoreReminders(sourceID: health.id, farmID: farmID, context: context)
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
        deleteReminders(sourceID: health.id, farmID: farmID, at: date ?? .now, context: context)
    }

    private static func setReproductionDeletedAt(_ date: Date?, id: UUID, farmID: UUID, context: ModelContext) throws {
        guard let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.id == id && $0.farmID == farmID
        })).first else { return }
        let wasDeleted = reproduction.deletedAt != nil
        reproduction.deletedAt = date

        let transactions = try context.fetch(FetchDescriptor<SemenTransactionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sourceRecordID == id
        }))
        let reversals = transactions.filter {
            $0.farmID == farmID && $0.sourceRecordID == id && $0.kind == .adjustment && $0.note.hasPrefix(reproductionSemenReversalPrefix)
        }
        if date == nil {
            for reversal in reversals where reversal.deletedAt == nil { reversal.deletedAt = .now }
            restoreReminders(sourceID: id, farmID: farmID, context: context)
            return
        }
        guard !wasDeleted else { return }
        for consumption in transactions where consumption.farmID == farmID && consumption.sourceRecordID == id && consumption.kind == .consumption && consumption.deletedAt == nil {
            let alreadyReversed = reversals.contains { $0.semenID == consumption.semenID && $0.quantityText == consumption.quantityText && $0.deletedAt == nil }
            guard !alreadyReversed else { continue }
            context.insert(SemenTransactionRecord(
                id: StableCloudUUID.derived(namespace: consumption.id, name: "semen-reversal"),
                farmID: farmID,
                semenID: consumption.semenID,
                kind: .adjustment,
                quantityText: consumption.quantityText,
                occurredAt: date ?? .now,
                sourceRecordID: id,
                note: "\(reproductionSemenReversalPrefix) \(id.uuidString.lowercased())"
            ))
        }
        deleteReminders(sourceID: id, farmID: farmID, at: date ?? .now, context: context)
    }

    private static func deleteReminders(sourceID: UUID, farmID: UUID, at: Date, context: ModelContext) {
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sourceEntityID == sourceID
        }))) ?? []
        for reminder in reminders where reminder.farmID == farmID && reminder.sourceEntityID == sourceID && reminder.deletedAt == nil {
            reminder.deletedAt = at
            reminder.revision += 1
        }
    }

    private static func restoreReminders(sourceID: UUID, farmID: UUID, context: ModelContext) {
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sourceEntityID == sourceID
        }))) ?? []
        for reminder in reminders where reminder.farmID == farmID && reminder.sourceEntityID == sourceID && reminder.deletedAt != nil {
            reminder.deletedAt = nil
            reminder.revision += 1
        }
    }
}
