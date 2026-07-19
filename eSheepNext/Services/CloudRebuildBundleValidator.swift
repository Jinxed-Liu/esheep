import Foundation

enum CloudRebuildBundleValidator {
    static func validate(_ bundle: CloudRebuildBundle) throws {
        guard bundle.root.farmID == bundle.farmID,
              bundle.operations.allSatisfy({ $0.farmID == bundle.farmID }),
              bundle.assets.allSatisfy({ $0.envelope.farmID == bundle.farmID }) else {
            throw CloudRebuildError.farmMismatch
        }
        try validateReferences(operations: bundle.operations, assets: bundle.assets)
    }

    static func validateReferences(operations: [CloudOperationEnvelope], assets: [CloudRebuildAssetSnapshot]) throws {
        var entitiesByType: [CloudEntityType: Set<UUID>] = [:]
        for operation in operations {
            if let type = CloudEntityType(rawValue: operation.entityType) {
                entitiesByType[type, default: []].insert(operation.entityID)
            }
        }
        let operationIDs = operations.map(\.operationID)
        guard Set(operationIDs).count == operationIDs.count else { throw CloudContractError.malformedRecord }

        var normalizedEarTags = Set<String>()
        for operation in operations {
            let outerPayload = try JSONDecoder.cloudRebuildValidation.decode(FarmCommandCloudPayload.self, from: operation.payload)
            let payload: FarmCommandCloudPayload
            if outerPayload.kind == .bootstrapEntity {
                guard let snapshotData = outerPayload.dataValues["snapshot"] else {
                    throw RemoteDomainApplyError.invalidPayload("snapshot")
                }
                let snapshot = try JSONDecoder.cloudRebuildValidation.decode(BootstrapEntityEnvelopeV1.self, from: snapshotData)
                try snapshot.validate(for: operation)
                payload = try JSONDecoder.cloudRebuildValidation.decode(FarmCommandCloudPayload.self, from: snapshot.sourcePayload)
            } else {
                payload = outerPayload
            }
            switch payload.kind {
            case .care:
                guard payload.careCommand != nil else { throw RemoteDomainApplyError.invalidPayload("careCommand") }
            case .createFarm, .updateFarmLocation, .createPen, .addIngredient, .createRecipe, .receiveInventory, .addSemen, .createBatch:
                break
            case .updatePen, .setPenActive:
                try require(identifier("penID", payload), in: entitiesByType[.pen], field: "pen.penID")
            case .createBreedingProgram:
                guard !payload.breedingProgramSteps.isEmpty,
                      payload.breedingProgramSteps.allSatisfy({ $0.dayOffset >= 0 && !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw RemoteDomainApplyError.invalidPayload("breedingProgramSteps")
                }
            case .addSheep:
                if let penID = optionalID("penID", payload) { try require(penID, in: entitiesByType[.pen], field: "sheep.penID") }
                guard let earTag = payload.strings["earTag"] else { throw RemoteDomainApplyError.invalidPayload("earTag") }
                guard normalizedEarTags.insert(EarTag.normalized(earTag)).inserted else { throw FarmCommandError.duplicateEarTag }
            case .updateSheepProfile:
                try require(identifier("sheepID", payload), in: entitiesByType[.sheep], field: "sheep.sheepID")
                guard payload.strings["earTag"] != nil else { throw RemoteDomainApplyError.invalidPayload("earTag") }
            case .recordWeight:
                try require(identifier("sheepID", payload), in: entitiesByType[.sheep], field: "weight.sheepID")
            case .correctWeight:
                try require(identifier("originalID", payload), in: entitiesByType[.weight], field: "weight.originalID")
            case .recordWeaning:
                try require(identifier("sheepID", payload), in: entitiesByType[.sheep], field: "weaning.sheepID")
                if let damID = optionalID("damID", payload) { try require(damID, in: entitiesByType[.sheep], field: "weaning.damID") }
            case .transferSheep:
                try require(identifier("sheepID", payload), in: entitiesByType[.sheep], field: "transfer.sheepID")
                if let penID = optionalID("toPenID", payload) { try require(penID, in: entitiesByType[.pen], field: "transfer.toPenID") }
            case .correctTransfer:
                try require(identifier("originalID", payload), in: entitiesByType[.transfer], field: "transfer.originalID")
                if let penID = optionalID("toPenID", payload) { try require(penID, in: entitiesByType[.pen], field: "transfer.toPenID") }
            case .removeSheep:
                try require(identifier("sheepID", payload), in: entitiesByType[.sheep], field: "removal.sheepID")
            case .correctRemoval:
                try require(identifier("originalID", payload), in: entitiesByType[.removal], field: "removal.originalID")
            case .restoreSheep:
                try require(operation.entityID, in: entitiesByType[.removal], field: "restore.removalID")
            case .assignBatchMembership, .leaveBatchMembership:
                try require(identifier("batchID", payload), in: entitiesByType[.productionBatch], field: "membership.batchID")
                try require(identifier("sheepID", payload), in: entitiesByType[.sheep], field: "membership.sheepID")
            case .addRecipeComponent:
                try require(identifier("recipeID", payload), in: entitiesByType[.feedRecipe], field: "component.recipeID")
                try require(identifier("ingredientID", payload), in: entitiesByType[.feedIngredient], field: "component.ingredientID")
            case .recordFeed:
                try require(identifier("penID", payload), in: entitiesByType[.pen], field: "feed.penID")
                if let recipeID = optionalID("recipeID", payload) { try require(recipeID, in: entitiesByType[.feedRecipe], field: "feed.recipeID") }
                for line in payload.feedLines { try require(line.ingredientID, in: entitiesByType[.feedIngredient], field: "feed.ingredientID") }
            case .recordHealth:
                if let sheepID = optionalID("sheepID", payload) { try require(sheepID, in: entitiesByType[.sheep], field: "health.sheepID") }
                if let penID = optionalID("penID", payload) { try require(penID, in: entitiesByType[.pen], field: "health.penID") }
                if let lotID = optionalID("inventoryLotID", payload) { try require(lotID, in: entitiesByType[.inventoryLot], field: "health.inventoryLotID") }
            case .recordReproduction:
                try require(identifier("eweID", payload), in: entitiesByType[.sheep], field: "reproduction.eweID")
                if let sireID = optionalID("sireID", payload) { try require(sireID, in: entitiesByType[.sheep], field: "reproduction.sireID") }
            case .addNote:
                if let sheepID = optionalID("sheepID", payload) { try require(sheepID, in: entitiesByType[.sheep], field: "note.sheepID") }
                if let penID = optionalID("penID", payload) { try require(penID, in: entitiesByType[.pen], field: "note.penID") }
            case .tombstoneEntity, .restoreTombstonedEntity, .resolveConflict, .recoverEntity, .bootstrapEntity:
                break
            }
        }

        let allEntities = Set(operations.map(\.entityID))
        for asset in assets {
            if let entityID = asset.envelope.entityID, !allEntities.contains(entityID) {
                throw RemoteDomainApplyError.missingReference("photo.entityID")
            }
        }
    }

    private static func identifier(_ key: String, _ payload: FarmCommandCloudPayload) throws -> UUID {
        guard let value = payload.identifiers[key] else { throw RemoteDomainApplyError.invalidPayload(key) }
        return value
    }

    private static func optionalID(_ key: String, _ payload: FarmCommandCloudPayload) -> UUID? {
        payload.optionalIdentifiers[key] ?? nil
    }

    private static func require(_ id: UUID, in values: Set<UUID>?, field: String) throws {
        guard values?.contains(id) == true else { throw RemoteDomainApplyError.missingReference(field) }
    }
}

private extension JSONDecoder {
    static var cloudRebuildValidation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
