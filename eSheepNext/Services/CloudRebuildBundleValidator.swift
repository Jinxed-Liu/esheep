import Foundation

enum CloudRebuildBundleValidator {
    static func validate(_ bundle: CloudRebuildBundle) throws {
        guard bundle.root.farmID == bundle.farmID,
              bundle.operations.allSatisfy({ $0.farmID == bundle.farmID }),
              bundle.assets.allSatisfy({ $0.envelope.farmID == bundle.farmID }) else {
            throw CloudRebuildError.farmMismatch
        }
        if bundle.authorityProofVersion == CloudRebuildActor.currentAuthorityProofVersion {
            guard let proofs = bundle.operationSourceProofs,
                  proofs.allSatisfy({ $0.farmID == bundle.farmID }) else {
                throw CloudContractError.malformedRecord
            }
            let mapper = CloudRecordMapper()
            let proofNames = proofs.map(\.recordName)
            let proofOperationIDs = proofs.map(\.operationID)
            guard Set(proofNames).count == proofNames.count,
                  Set(proofOperationIDs).count == proofOperationIDs.count,
                  proofs.allSatisfy({
                      $0.recordName == mapper.recordName(for: $0.operationID) &&
                          !$0.envelopeDigest.isEmpty
                  }) else {
                throw CloudContractError.malformedRecord
            }
            let proofsByOperationID = Dictionary(uniqueKeysWithValues: proofs.map { ($0.operationID, $0) })
            for operation in bundle.operations {
                guard let proof = proofsByOperationID[operation.operationID],
                      proof.envelopeDigest == (try CloudRebuildOperationSourceProof.digest(operation)) else {
                    throw CloudContractError.malformedRecord
                }
            }
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
        for operation in operations {
            let payload = try effectivePayload(for: operation)
            if case .recordReproductionBatch(let draft) = payload.careCommand {
                for subject in draft.subjects {
                    entitiesByType[.reproduction, default: []].insert(StableCloudUUID.derived(namespace: draft.id, name: subject.id.uuidString.lowercased()))
                }
            }
            switch payload.careCommand {
            case .recordLambing(let draft), .correctLambing(_, let draft, _):
                for lamb in draft.offspring {
                    entitiesByType[.lambingOffspring, default: []].insert(lamb.id)
                    if lamb.createSheepRecord { entitiesByType[.sheep, default: []].insert(lamb.sheepID) }
                }
            default:
                break
            }
        }
        let assetIDs = assets.map { $0.envelope.assetID }
        guard Set(assetIDs).count == assetIDs.count else {
            throw CloudContractError.malformedRecord
        }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.envelope.assetID, $0) })
        let operationIDs = operations.map(\.operationID)
        guard Set(operationIDs).count == operationIDs.count else { throw CloudContractError.malformedRecord }

        var normalizedEarTags = Set<String>()
        for operation in operations {
            let payload = try effectivePayload(for: operation)
            switch payload.kind {
            case .care:
                guard let command = payload.careCommand else { throw RemoteDomainApplyError.invalidPayload("careCommand") }
                try validateCare(command, entitiesByType: entitiesByType)
            case .createFarm, .updateFarmLocation, .createPen, .addIngredient, .createRecipe, .receiveInventory, .createBatch, .saveFeedIngredient:
                break
            case .saveFeedBatch:
                try require(identifier("ingredientID", payload), in: entitiesByType[.feedIngredient], field: "batch.ingredientID")
            case .adjustFeedStock:
                try require(identifier("batchID", payload), in: entitiesByType[.feedIngredientBatch], field: "stock.batchID")
                guard let kind = FeedStockTransactionKind(rawValue: payload.strings["kind"] ?? ""),
                      let quantityText = payload.strings["quantityText"],
                      let quantity = Decimal.stable(quantityText) else {
                    throw RemoteDomainApplyError.invalidPayload("stock.transaction")
                }
                if payload.strings["baselineProjection"] == "1" {
                    switch kind {
                    case .openingBalance, .receipt, .consumption, .reversal, .conflict:
                        guard quantity >= 0 else { throw RemoteDomainApplyError.invalidPayload("stock.quantityText") }
                    case .adjustment:
                        break
                    }
                } else {
                    switch kind {
                    case .receipt:
                        guard quantity > 0 else { throw RemoteDomainApplyError.invalidPayload("stock.quantityText") }
                    case .adjustment:
                        guard quantity != 0 else { throw RemoteDomainApplyError.invalidPayload("stock.quantityText") }
                    case .openingBalance, .consumption, .reversal, .conflict:
                        throw RemoteDomainApplyError.invalidPayload("stock.kind")
                    }
                }
            case .countFeedStock:
                try require(identifier("batchID", payload), in: entitiesByType[.feedIngredientBatch], field: "stockCount.batchID")
                guard let method = FeedStockCountMethod(rawValue: payload.strings["method"] ?? FeedStockCountMethod.notMeasured.rawValue) else { throw RemoteDomainApplyError.invalidPayload("stockCount.method") }
                let actual = payload.optionalStrings["actualKilogramsText"] ?? nil
                if method == .notMeasured, actual != nil { throw RemoteDomainApplyError.invalidPayload("stockCount.actualKilogramsText") }
                if method != .notMeasured, actual == nil { throw RemoteDomainApplyError.invalidPayload("stockCount.actualKilogramsText") }
                if let actual, Decimal.stable(actual).map({ $0 >= 0 }) != true { throw RemoteDomainApplyError.invalidPayload("stockCount.actualKilogramsText") }
                if payload.strings["baselineProjection"] == "1" {
                    guard let bookText = payload.strings["bookBalanceText"],
                          let book = Decimal.stable(bookText), book >= 0 else {
                        throw RemoteDomainApplyError.invalidPayload("stockCount.bookBalanceText")
                    }
                    let differenceText = payload.optionalStrings["differenceText"] ?? nil
                    let adjustmentID = optionalID("adjustmentTransactionID", payload)
                    if let actual, let actualValue = Decimal.stable(actual) {
                        guard let differenceText,
                              let difference = Decimal.stable(differenceText),
                              difference == actualValue - book,
                              adjustmentID != nil else {
                            throw RemoteDomainApplyError.invalidPayload("stockCount.differenceText")
                        }
                    } else if differenceText != nil || adjustmentID != nil {
                        throw RemoteDomainApplyError.invalidPayload("stockCount.differenceText")
                    }
                }
            case .saveFeedRecipe:
                if let targetPenID = optionalID("targetPenID", payload) { try require(targetPenID, in: entitiesByType[.pen], field: "recipe.targetPenID") }
                for component in payload.recipeComponents {
                    try require(component.ingredientID, in: entitiesByType[.feedIngredient], field: "recipe.ingredientID")
                    if let batchID = component.ingredientBatchID { try require(batchID, in: entitiesByType[.feedIngredientBatch], field: "recipe.ingredientBatchID") }
                }
            case .updatePen, .setPenActive:
                try require(identifier("penID", payload), in: entitiesByType[.pen], field: "pen.penID")
            case .createBreedingProgram:
                guard !payload.breedingProgramSteps.isEmpty,
                      payload.breedingProgramSteps.allSatisfy({ $0.dayOffset >= 0 && !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw RemoteDomainApplyError.invalidPayload("breedingProgramSteps")
                }
            case .addSheep:
                if let penID = optionalID("penID", payload) { try require(penID, in: entitiesByType[.pen], field: "sheep.penID") }
                if let damID = optionalID("damID", payload) { try require(damID, in: entitiesByType[.sheep], field: "sheep.damID") }
                if let sireID = optionalID("sireID", payload) { try require(sireID, in: entitiesByType[.sheep], field: "sheep.sireID") }
                if let donorID = optionalID("semenDonorID", payload) { try require(donorID, in: entitiesByType[.semenDonor], field: "sheep.semenDonorID") }
                guard let earTag = payload.strings["earTag"] else { throw RemoteDomainApplyError.invalidPayload("earTag") }
                if let currentParity = payload.integers["currentParity"] {
                    guard currentParity >= 0, payload.strings["sex"] == SheepSex.ewe.rawValue else { throw RemoteDomainApplyError.invalidPayload("currentParity") }
                }
                guard normalizedEarTags.insert(EarTag.normalized(earTag)).inserted else { throw FarmCommandError.duplicateEarTag }
                try validateAvatarReference(
                    in: payload,
                    sheepID: operation.entityID,
                    assetsByID: assetsByID
                )
            case .updateSheepProfile:
                let sheepID = try identifier("sheepID", payload)
                try require(sheepID, in: entitiesByType[.sheep], field: "sheep.sheepID")
                guard payload.strings["earTag"] != nil else { throw RemoteDomainApplyError.invalidPayload("earTag") }
                if let currentParity = payload.integers["currentParity"] {
                    guard currentParity >= 0,
                          payload.strings["sex"] == SheepSex.ewe.rawValue,
                          payload.dates["parityRecordedAt"] != nil else { throw RemoteDomainApplyError.invalidPayload("currentParity") }
                }
                try validateAvatarReference(
                    in: payload,
                    sheepID: sheepID,
                    assetsByID: assetsByID
                )
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
            case .recordFeedV2, .importHistoricalFeed:
                try require(identifier("penID", payload), in: entitiesByType[.pen], field: "feed.penID")
                if let recipeID = optionalID("recipeID", payload) { try require(recipeID, in: entitiesByType[.feedRecipe], field: "feed.recipeID") }
                for line in payload.feedLines {
                    try require(line.ingredientID, in: entitiesByType[.feedIngredient], field: "feed.ingredientID")
                    if let batchID = line.ingredientBatchID { try require(batchID, in: entitiesByType[.feedIngredientBatch], field: "feed.ingredientBatchID") }
                }
                if payload.kind == .recordFeedV2 {
                    for sheepID in FeedExcludedSheepCodec.decode(payload.optionalStrings["excludedSheepIDsJSON"] ?? nil) {
                        try require(sheepID, in: entitiesByType[.sheep], field: "feed.excludedSheepID")
                    }
                }
            case .recordFeedTroughObservation:
                guard try identifier("observationID", payload) == operation.entityID else {
                    throw RemoteDomainApplyError.invalidPayload("trough.observationID")
                }
                try require(identifier("penID", payload), in: entitiesByType[.pen], field: "trough.penID")
                if let feedID = optionalID("relatedFeedRecordID", payload) {
                    try require(feedID, in: entitiesByType[.feed], field: "trough.relatedFeedRecordID")
                }
                guard payload.strings["feederName"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      let actualText = payload.strings["actualRemainingKilogramsText"],
                      let actual = Decimal.stable(actualText), actual >= 0,
                      FeedTroughMeasurementMethod(rawValue: payload.strings["measurementMethod"] ?? "") != nil else {
                    throw RemoteDomainApplyError.invalidPayload("trough")
                }
                if let discardedText = payload.optionalStrings["discardedKilogramsText"] ?? nil {
                    guard let discarded = Decimal.stable(discardedText), discarded >= 0, discarded <= actual else {
                        throw RemoteDomainApplyError.invalidPayload("trough.discardedKilogramsText")
                    }
                }
                if let compositionJSON = payload.optionalStrings["compositionSnapshotJSON"] ?? nil {
                    guard let data = compositionJSON.data(using: .utf8),
                          let components = try? JSONDecoder().decode([FeedTroughCompositionComponent].self, from: data),
                          !components.isEmpty,
                          components.allSatisfy({ (Decimal.stable($0.kilogramsText) ?? -1) >= 0 }),
                          abs(NSDecimalNumber(decimal: components.reduce(Decimal.zero) { $0 + $1.kilograms } - actual).doubleValue) <= 0.001 else {
                        throw RemoteDomainApplyError.invalidPayload("trough.compositionSnapshotJSON")
                    }
                }
            case .recordHealth:
                if let sheepID = optionalID("sheepID", payload) { try require(sheepID, in: entitiesByType[.sheep], field: "health.sheepID") }
                if let penID = optionalID("penID", payload) { try require(penID, in: entitiesByType[.pen], field: "health.penID") }
                if let lotID = optionalID("inventoryLotID", payload) { try require(lotID, in: entitiesByType[.inventoryLot], field: "health.inventoryLotID") }
            case .recordReproduction:
                try require(identifier("eweID", payload), in: entitiesByType[.sheep], field: "reproduction.eweID")
                if let sireID = optionalID("sireID", payload) { try require(sireID, in: entitiesByType[.sheep], field: "reproduction.sireID") }
                if let semenID = optionalID("semenID", payload) { try require(semenID, in: entitiesByType[.semen], field: "reproduction.semenID") }
                if let relatedID = optionalID("relatedBreedingRecordID", payload) { try require(relatedID, in: entitiesByType[.reproduction], field: "reproduction.relatedBreedingRecordID") }
                if let donorID = optionalID("semenDonorID", payload) { try require(donorID, in: entitiesByType[.semenDonor], field: "reproduction.semenDonorID") }
            case .addSemen:
                if let donorID = optionalID("donorID", payload) { try require(donorID, in: entitiesByType[.semenDonor], field: "semen.donorID") }
            case .addNote:
                if let sheepID = optionalID("sheepID", payload) { try require(sheepID, in: entitiesByType[.sheep], field: "note.sheepID") }
                if let penID = optionalID("penID", payload) { try require(penID, in: entitiesByType[.pen], field: "note.penID") }
            case .addPhoto:
                guard payload.strings["sha256"]?.count == 64,
                      payload.strings["mimeType"]?.isEmpty == false else {
                    throw RemoteDomainApplyError.invalidPayload("photo")
                }
                if let sheepID = optionalID("sheepID", payload) {
                    try require(
                        sheepID,
                        in: entitiesByType[.sheep],
                        field: "photo.sheepID"
                    )
                }
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

    private static func validateAvatarReference(
        in payload: FarmCommandCloudPayload,
        sheepID: UUID,
        assetsByID: [UUID: CloudRebuildAssetSnapshot]
    ) throws {
        guard let update = SheepAvatarCloudPayload.update(from: payload),
              let photoAssetID = update.photoAssetID else {
            return
        }
        guard let asset = assetsByID[photoAssetID],
              asset.envelope.entityID == sheepID else {
            throw RemoteDomainApplyError.invalidPayload("sheepAvatarPhotoAssetID")
        }
    }

    private static func effectivePayload(for operation: CloudOperationEnvelope) throws -> FarmCommandCloudPayload {
        var encoded = operation.payload
        for _ in 0..<16 {
            let payload = try JSONDecoder.cloudRebuildValidation.decode(FarmCommandCloudPayload.self, from: encoded)
            switch payload.kind {
            case .bootstrapEntity:
                guard let snapshotData = payload.dataValues["snapshot"] else { throw RemoteDomainApplyError.invalidPayload("snapshot") }
                let snapshot = try JSONDecoder.cloudRebuildValidation.decode(BootstrapEntityEnvelopeV1.self, from: snapshotData)
                try snapshot.validate(for: operation)
                encoded = snapshot.sourcePayload
            case .recoverEntity:
                guard let source = payload.dataValues["resolvedPayload"],
                      payload.strings["entityType"] == operation.entityType,
                      let expectedDigest = payload.strings["sourcePayloadDigest"],
                      CloudPayloadDigest.hex(for: source) == expectedDigest else {
                    throw RemoteDomainApplyError.invalidPayload("resolvedPayload")
                }
                encoded = source
            default:
                return payload
            }
        }
        throw RemoteDomainApplyError.invalidPayload("nestedRecoveryDepth")
    }

    private static func validateCare(_ command: CareCommand, entitiesByType: [CloudEntityType: Set<UUID>]) throws {
        switch command {
        case .upsertHealthCatalog:
            break
        case .recordHealth(let draft), .correctHealth(_, let draft, _):
            for id in draft.subjectIDs { try require(id, in: entitiesByType[.sheep], field: "care.health.sheepID") }
            if let id = draft.penID { try require(id, in: entitiesByType[.pen], field: "care.health.penID") }
            if let id = draft.inventoryLotID { try require(id, in: entitiesByType[.inventoryLot], field: "care.health.inventoryLotID") }
        case .receiveInventory(_, _, let catalogID, _, _, _, _, _, _, _, _):
            if let catalogID { try require(catalogID, in: entitiesByType[.healthCatalogItem], field: "care.inventory.catalogID") }
        case .adjustInventory(_, let lotID, _, _, _), .setInventoryLotActive(let lotID, _):
            try require(lotID, in: entitiesByType[.inventoryLot], field: "care.inventory.lotID")
        case .adjustSemen(_, let semenID, _, _, _):
            try require(semenID, in: entitiesByType[.semen], field: "care.semen.semenID")
        case .upsertSemenDonor(let draft):
            if let ramID = draft.linkedRamID { try require(ramID, in: entitiesByType[.sheep], field: "care.donor.linkedRamID") }
        case .setSemenDonor(let semenID, let donorID, _):
            try require(semenID, in: entitiesByType[.semen], field: "care.semen.semenID")
            if let donorID { try require(donorID, in: entitiesByType[.semenDonor], field: "care.semen.donorID") }
        case .updateSheepPedigree(let draft):
            try require(draft.sheepID, in: entitiesByType[.sheep], field: "care.pedigree.sheepID")
            for id in [draft.damID, draft.sireID].compactMap({ $0 }) { try require(id, in: entitiesByType[.sheep], field: "care.pedigree.parentID") }
            if let donorID = draft.semenDonorID { try require(donorID, in: entitiesByType[.semenDonor], field: "care.pedigree.donorID") }
        case .setBreedingRam(let sheepID, _, _):
            try require(sheepID, in: entitiesByType[.sheep], field: "care.breedingRam.sheepID")
        case .restorePedigreeAudit(let snapshot):
            try require(snapshot.sheepID, in: entitiesByType[.sheep], field: "care.pedigreeAudit.sheepID")
            for id in [snapshot.beforeDamID, snapshot.afterDamID, snapshot.beforeSireID, snapshot.afterSireID].compactMap({ $0 }) { try require(id, in: entitiesByType[.sheep], field: "care.pedigreeAudit.parentID") }
            for id in [snapshot.beforeSemenDonorID, snapshot.afterSemenDonorID].compactMap({ $0 }) { try require(id, in: entitiesByType[.semenDonor], field: "care.pedigreeAudit.donorID") }
        case .recordReproductionBatch(let draft), .correctReproduction(_, let draft, _):
            for subject in draft.subjects {
                try require(subject.eweID, in: entitiesByType[.sheep], field: "care.reproduction.eweID")
                if let relatedID = subject.relatedBreedingRecordID { try require(relatedID, in: entitiesByType[.reproduction], field: "care.reproduction.relatedBreedingRecordID") }
            }
            if let sireID = draft.sireID { try require(sireID, in: entitiesByType[.sheep], field: "care.reproduction.sireID") }
            if let semenID = draft.semenID { try require(semenID, in: entitiesByType[.semen], field: "care.reproduction.semenID") }
        case .recordLambing(let draft), .correctLambing(_, let draft, _):
            try require(draft.eweID, in: entitiesByType[.sheep], field: "care.lambing.eweID")
            if let sireID = draft.sireID { try require(sireID, in: entitiesByType[.sheep], field: "care.lambing.sireID") }
            if let semenID = draft.semenID { try require(semenID, in: entitiesByType[.semen], field: "care.lambing.semenID") }
            if let relatedID = draft.relatedBreedingRecordID { try require(relatedID, in: entitiesByType[.reproduction], field: "care.lambing.relatedBreedingRecordID") }
        case .revokeLambing(let id, _), .restoreLambing(let id):
            try require(id, in: entitiesByType[.reproduction], field: "care.lambing.recordID")
        case .updateRules, .updateOperationalAlertRules:
            break
        case .deferOperationalAlert(let draft):
            if let subjectID = draft.subjectID {
                try require(subjectID, in: entitiesByType[.sheep], field: "care.alertDeferral.subjectID")
            }
        case .setReminderStatus(let id, _):
            try require(id, in: entitiesByType[.careReminder], field: "care.reminderID")
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
