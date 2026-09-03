import Foundation

/// The single, reviewable registry for the V2 wire surface.
///
/// The SQL catalogue, the typed payload decoder, the command factory and the
/// reducer are intentionally checked against this list by the coverage test.
/// Keeping the list in the product target (rather than only in a test or a
/// migration script) prevents a new command from being marked ready by
/// editing a CI fixture while its runtime route is still missing.
enum ESheepCloudCommandRegistryV2 {
    static let allKinds: [String] = [
        "attention.resolve",
        "batchMembership.assign",
        "batchMembership.leave",
        "batchMembership.restore",
        "breedingProgram.create",
        "care.careReminder.setStatus",
        "care.careRules.update",
        "care.health.correct",
        "care.health.recordBatch",
        "care.healthCatalog.upsert",
        "care.inventory.adjust",
        "care.inventory.receive",
        "care.inventoryLot.setActive",
        "care.lambing.correct",
        "care.lambing.record",
        "care.lambing.restore",
        "care.lambing.revoke",
        "care.operationalAlert.defer",
        "care.operationalAlertRules.update",
        "care.reproduction.correct",
        "care.reproduction.recordBatch",
        "care.semen.adjust",
        "care.semen.setDonor",
        "care.semenDonor.upsert",
        "care.sheep.setBreedingRam",
        "care.sheep.setPurpose",
        "care.sheepPedigree.restoreAudit",
        "care.sheepPedigree.update",
        "farm.updateLocation",
        "feed.importHistorical",
        "feed.record",
        "feed.recordLegacy",
        "feedBatch.save",
        "feedIngredient.add",
        "feedIngredient.save",
        "feedRecipe.create",
        "feedRecipe.member.add",
        "feedRecipe.save",
        "feedStock.adjust",
        "feedStock.count",
        "feedTrough.record",
        "health.record",
        "inventory.receive",
        "note.add",
        "pen.create",
        "pen.setActive",
        "pen.update",
        "photoAsset.recycle",
        "photoAsset.register",
        "photoAsset.restore",
        "productionBatch.create",
        "record.restore",
        "record.revoke",
        "removal.correct",
        "removal.record",
        "removal.restore",
        "reproduction.record",
        "semen.add",
        "sheep.add",
        "sheep.patchProfile",
        "sheepAvatar.clear",
        "sheepAvatar.set",
        "tmr.acknowledgeTMRDeviation",
        "tmr.adjustTMRBatch",
        "tmr.closeTMRBatch",
        "tmr.completeTMRMeal",
        "tmr.correctTMRFeedingRun",
        "tmr.deleteUnusedTMRBatch",
        "tmr.produceTMRBatch",
        "tmr.recordTMRFeeding",
        "tmr.reopenTMRMeal",
        "tmr.reverseTMRFeedingRun",
        "tmr.saveTMRFeedingPlan",
        "tmr.saveTMRFormula",
        "tmr.saveTMRMonitoringRule",
        "transfer.correct",
        "transfer.record",
        "weaning.record",
        "weight.correct",
        "weight.record",
    ]

    static let kindSet = Set(allKinds)

    static func contains(_ kind: String) -> Bool {
        kindSet.contains(kind)
    }

    /// The typed enum case used by the V2 JSON body. This mirrors the server's
    /// discriminator table, so a schema addition must update both sides.
    static func expectedPayloadCase(for kind: String) -> String? {
        switch kind {
        case "farm.updateLocation": "updateLocation"
        case "pen.create": "create"
        case "pen.update": "update"
        case "pen.setActive": "setActive"
        case "sheep.add": "add"
        case "sheep.patchProfile": "patchProfile"
        case "sheepAvatar.set": "setAvatar"
        case "sheepAvatar.clear": "clearAvatar"
        case "weight.record": "recordWeight"
        case "weight.correct": "correctWeight"
        case "weaning.record": "recordWeaning"
        case "transfer.record": "transferSheep"
        case "transfer.correct": "correctTransfer"
        case "removal.record": "removeSheep"
        case "removal.correct": "correctRemoval"
        case "removal.restore": "restoreSheep"
        case "breedingProgram.create": "createBreedingProgram"
        case "productionBatch.create": "createBatch"
        case "batchMembership.assign": "assignSheepToBatch"
        case "batchMembership.leave": "leaveBatch"
        case "batchMembership.restore": "restoreBatchMembership"
        case "feedIngredient.add": "addIngredient"
        case "feedRecipe.create": "createRecipe"
        case "feedRecipe.member.add": "addRecipeComponent"
        case "feed.recordLegacy": "recordLegacy"
        case "feedIngredient.save": "saveIngredient"
        case "feedBatch.save": "saveBatch"
        case "feedStock.adjust": "adjustStock"
        case "feedStock.count": "countStock"
        case "feedRecipe.save": "saveRecipe"
        case "feed.record": "record"
        case "feedTrough.record": "recordTroughObservation"
        case "feed.importHistorical": "importHistorical"
        case "health.record", "care.health.recordBatch": "recordHealth"
        case "inventory.receive", "care.inventory.receive": "receiveInventory"
        case "semen.add": "addSemen"
        case "reproduction.record": "recordReproduction"
        case "note.add": "addNote"
        case "record.revoke": "tombstone"
        case "record.restore": "restore"
        case "photoAsset.register": "register"
        case "photoAsset.recycle": "moveToRecycleBin"
        case "photoAsset.restore": "restore"
        case "care.healthCatalog.upsert": "upsertHealthCatalog"
        case "care.health.correct": "correctHealth"
        case "care.inventory.adjust": "adjustInventory"
        case "care.inventoryLot.setActive": "setInventoryLotActive"
        case "care.semen.adjust": "adjustSemen"
        case "care.semenDonor.upsert": "upsertSemenDonor"
        case "care.semen.setDonor": "setSemenDonor"
        case "care.sheepPedigree.update": "updateSheepPedigree"
        case "care.sheep.setBreedingRam": "setBreedingRam"
        case "care.sheep.setPurpose": "setSheepPurpose"
        case "care.sheepPedigree.restoreAudit": "restorePedigreeAudit"
        case "care.reproduction.recordBatch": "recordReproductionBatch"
        case "care.lambing.record": "recordLambing"
        case "care.reproduction.correct": "correctReproduction"
        case "care.lambing.correct": "correctLambing"
        case "care.lambing.revoke": "revokeLambing"
        case "care.lambing.restore": "restoreLambing"
        case "care.careRules.update": "updateRules"
        case "care.operationalAlertRules.update": "updateOperationalAlertRules"
        case "care.operationalAlert.defer": "deferOperationalAlert"
        case "care.careReminder.setStatus": "setReminderStatus"
        case "tmr.saveTMRFormula": "saveFormula"
        case "tmr.saveTMRMonitoringRule": "saveMonitoringRule"
        case "tmr.saveTMRFeedingPlan": "saveFeedingPlan"
        case "tmr.produceTMRBatch": "produceBatch"
        case "tmr.recordTMRFeeding": "recordFeeding"
        case "tmr.correctTMRFeedingRun": "correctFeedingRun"
        case "tmr.reverseTMRFeedingRun": "reverseFeedingRun"
        case "tmr.completeTMRMeal": "completeMeal"
        case "tmr.reopenTMRMeal": "reopenMeal"
        case "tmr.adjustTMRBatch": "adjustBatch"
        case "tmr.closeTMRBatch": "closeBatch"
        case "tmr.deleteUnusedTMRBatch": "deleteUnusedBatch"
        case "tmr.acknowledgeTMRDeviation": "acknowledgeDeviation"
        case "attention.resolve": "resolve"
        default: nil
        }
    }

    static func mergeMode(for kind: String) -> String? {
        switch kind {
        case "farm.updateLocation", "pen.update", "pen.setActive",
             "sheep.patchProfile", "sheepAvatar.set", "sheepAvatar.clear":
            "field_patch"
        case "weight.record", "weaning.record", "note.add", "photoAsset.register",
             "feed.recordLegacy", "feedTrough.record", "feed.importHistorical",
             "care.operationalAlert.defer", "tmr.acknowledgeTMRDeviation":
            "append_fact"
        case "weight.correct", "transfer.correct", "removal.correct",
             "removal.restore", "record.revoke", "record.restore",
             "photoAsset.recycle", "photoAsset.restore", "care.health.correct",
             "care.sheepPedigree.restoreAudit", "care.reproduction.correct",
             "care.lambing.correct", "care.lambing.revoke", "care.lambing.restore",
             "tmr.correctTMRFeedingRun", "tmr.reverseTMRFeedingRun",
             "tmr.reopenTMRMeal", "tmr.deleteUnusedTMRBatch":
            "lifecycle"
        case "pen.create", "sheep.add", "breedingProgram.create", "productionBatch.create",
             "batchMembership.assign", "batchMembership.leave", "batchMembership.restore",
             "feedIngredient.add", "feedRecipe.create", "feedRecipe.member.add":
            "or_set"
        case "feedStock.adjust", "feedStock.count", "feed.record", "health.record",
             "inventory.receive", "semen.add", "care.health.recordBatch",
             "care.inventory.receive", "care.inventory.adjust", "care.semen.adjust",
             "tmr.produceTMRBatch", "tmr.recordTMRFeeding",
             "tmr.adjustTMRBatch":
            "ledger"
        case "feedIngredient.save", "feedBatch.save", "feedRecipe.save",
             "reproduction.record", "transfer.record", "removal.record",
             "care.healthCatalog.upsert", "care.inventoryLot.setActive",
             "care.semenDonor.upsert", "care.semen.setDonor", "care.sheepPedigree.update",
             "care.sheep.setBreedingRam", "care.sheep.setPurpose", "care.careRules.update",
             "care.operationalAlertRules.update", "care.careReminder.setStatus",
             "tmr.saveTMRFormula", "tmr.saveTMRMonitoringRule", "tmr.saveTMRFeedingPlan",
             "tmr.completeTMRMeal", "tmr.closeTMRBatch":
            "state_machine"
        case "care.reproduction.recordBatch", "care.lambing.record":
            "state_machine"
        case "attention.resolve": "lifecycle"
        default: nil
        }
    }

    static func isFieldPatch(_ kind: String) -> Bool {
        mergeMode(for: kind) == "field_patch"
    }

    /// The projection route is deliberately separate from the payload case
    /// and merge mode.  A shared merge primitive does not mean that two
    /// business operations have the same validation or reducer semantics.
    /// Keeping one explicit arm per wire kind makes a newly added command fail
    /// compilation/tests until its domain route is named here.
    static func nativeProjectionRoute(for kind: String) -> String? {
        switch kind {
        case "attention.resolve": "attention.resolve"
        case "farm.updateLocation": "farm.location"
        case "pen.create": "pen.create"
        case "pen.update": "pen.update"
        case "pen.setActive": "pen.setActive"
        case "sheep.add": "sheep.add"
        case "sheep.patchProfile": "sheep.profile"
        case "sheepAvatar.set": "sheep.avatar.set"
        case "sheepAvatar.clear": "sheep.avatar.clear"
        case "weight.record": "weight.record"
        case "weight.correct": "weight.correct"
        case "weaning.record": "weaning.record"
        case "transfer.record": "transfer.record"
        case "transfer.correct": "transfer.correct"
        case "removal.record": "removal.record"
        case "removal.correct": "removal.correct"
        case "removal.restore": "removal.restore"
        case "breedingProgram.create": "breedingProgram.create"
        case "productionBatch.create": "productionBatch.create"
        case "batchMembership.assign": "batchMembership.assign"
        case "batchMembership.leave": "batchMembership.leave"
        case "batchMembership.restore": "batchMembership.restore"
        case "feedIngredient.add": "feedIngredient.add"
        case "feedIngredient.save": "feedIngredient.save"
        case "feedRecipe.create": "feedRecipe.create"
        case "feedRecipe.member.add": "feedRecipe.member.add"
        case "feedRecipe.save": "feedRecipe.save"
        case "feed.record": "feed.record"
        case "feed.recordLegacy": "feed.recordLegacy"
        case "feed.importHistorical": "feed.importHistorical"
        case "feedBatch.save": "feedBatch.save"
        case "feedStock.adjust": "feedStock.adjust"
        case "feedStock.count": "feedStock.count"
        case "feedTrough.record": "feedTrough.record"
        case "health.record": "health.record"
        case "inventory.receive": "inventory.receive"
        case "semen.add": "semen.add"
        case "reproduction.record": "reproduction.record"
        case "note.add": "note.add"
        case "record.revoke": "record.revoke"
        case "record.restore": "record.restore"
        case "photoAsset.register": "photoAsset.register"
        case "photoAsset.recycle": "photoAsset.recycle"
        case "photoAsset.restore": "photoAsset.restore"
        case "care.healthCatalog.upsert": "care.healthCatalog.upsert"
        case "care.health.recordBatch": "care.health.recordBatch"
        case "care.health.correct": "care.health.correct"
        case "care.inventory.receive": "care.inventory.receive"
        case "care.inventory.adjust": "care.inventory.adjust"
        case "care.inventoryLot.setActive": "care.inventoryLot.setActive"
        case "care.semen.adjust": "care.semen.adjust"
        case "care.semenDonor.upsert": "care.semenDonor.upsert"
        case "care.semen.setDonor": "care.semen.setDonor"
        case "care.sheepPedigree.update": "care.sheepPedigree.update"
        case "care.sheep.setBreedingRam": "care.sheep.setBreedingRam"
        case "care.sheep.setPurpose": "care.sheep.setPurpose"
        case "care.sheepPedigree.restoreAudit": "care.sheepPedigree.restoreAudit"
        case "care.reproduction.recordBatch": "care.reproduction.recordBatch"
        case "care.lambing.record": "care.lambing.record"
        case "care.reproduction.correct": "care.reproduction.correct"
        case "care.lambing.correct": "care.lambing.correct"
        case "care.lambing.revoke": "care.lambing.revoke"
        case "care.lambing.restore": "care.lambing.restore"
        case "care.careRules.update": "care.careRules.update"
        case "care.operationalAlertRules.update": "care.operationalAlertRules.update"
        case "care.operationalAlert.defer": "care.operationalAlert.defer"
        case "care.careReminder.setStatus": "care.careReminder.setStatus"
        case "tmr.saveTMRFormula": "tmr.saveTMRFormula"
        case "tmr.saveTMRMonitoringRule": "tmr.saveTMRMonitoringRule"
        case "tmr.saveTMRFeedingPlan": "tmr.saveTMRFeedingPlan"
        case "tmr.produceTMRBatch": "tmr.produceTMRBatch"
        case "tmr.recordTMRFeeding": "tmr.recordTMRFeeding"
        case "tmr.correctTMRFeedingRun": "tmr.correctTMRFeedingRun"
        case "tmr.reverseTMRFeedingRun": "tmr.reverseTMRFeedingRun"
        case "tmr.completeTMRMeal": "tmr.completeTMRMeal"
        case "tmr.reopenTMRMeal": "tmr.reopenTMRMeal"
        case "tmr.adjustTMRBatch": "tmr.adjustTMRBatch"
        case "tmr.closeTMRBatch": "tmr.closeTMRBatch"
        case "tmr.deleteUnusedTMRBatch": "tmr.deleteUnusedTMRBatch"
        case "tmr.acknowledgeTMRDeviation": "tmr.acknowledgeTMRDeviation"
        default: nil
        }
    }

    static func hasDeterministicReplayRoute(_ kind: String) -> Bool {
        contains(kind) && expectedPayloadCase(for: kind) != nil &&
            mergeMode(for: kind) != nil && nativeProjectionRoute(for: kind) != nil
    }
}
