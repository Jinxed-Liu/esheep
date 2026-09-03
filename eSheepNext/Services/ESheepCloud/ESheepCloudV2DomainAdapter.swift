import Foundation
import SwiftData

/// Applies an authoritative V2 business event to the existing SwiftData
/// business projection. This is a one-way local projection boundary: it never
/// creates a V1 network envelope, asks a device for a whole-record revision,
/// or decides which side wins. The server has already accepted the typed
/// command; this adapter only invokes the deterministic local business writer
/// with the event's actor and ordering metadata.
enum ESheepCloudV2DomainAdapter {
    @MainActor
    static func apply(
        event: ESheepCloudEventEnvelopeV2,
        context: ModelContext
    ) throws -> RemoteApplyOutcome {
        guard case .businessCommandApplied(_, let payload) = event.payload else {
            throw ESheepCloudProjectionError.unsupportedEvent
        }
        // The reducer must never accept a typed payload that has no named
        // projection route.  This guard is intentionally independent of the
        // payload enum so adding a new wire kind cannot fall through to a
        // generic event-count update or a guessed model writer.
        guard ESheepCloudCommandRegistryV2.nativeProjectionRoute(for: payload.kind) != nil else {
            throw ESheepCloudProjectionError.unsupportedEvent
        }

        switch payload {
        case .sheep(.setAvatar(let sheepID, let photoAssetID)):
            guard sheepID == event.stream.id else {
                throw ESheepCloudProjectionError.invalidFieldValue("头像")
            }
            try SheepAvatarSelectionStore.apply(
                SheepAvatarPhotoUpdate(photoAssetID: photoAssetID),
                sheepID: sheepID,
                farmID: event.farmID,
                updatedAt: event.occurredAt,
                context: context
            )
            return .applied(rebuildHistoryFrom: nil)

        case .sheep(.clearAvatar(let sheepID)):
            guard sheepID == event.stream.id else {
                throw ESheepCloudProjectionError.invalidFieldValue("头像")
            }
            try SheepAvatarSelectionStore.apply(
                SheepAvatarPhotoUpdate(photoAssetID: nil),
                sheepID: sheepID,
                farmID: event.farmID,
                updatedAt: event.occurredAt,
                context: context
            )
            return .applied(rebuildHistoryFrom: nil)

        case .sheep(.patchProfile):
            // Profile changes are required to travel as `fields_patched` so
            // unrelated fields can merge independently.  Seeing a generic
            // business event for this command would mean the authority or a
            // snapshot producer violated that invariant; fail closed instead
            // of reconstituting a whole profile from a partial patch.
            throw ESheepCloudProjectionError.unsupportedEvent

        case .photo:
            throw ESheepCloudProjectionError.unsupportedEvent

        default:
            guard let command = try payload.domainCommand else {
                throw ESheepCloudProjectionError.unsupportedEvent
            }
            guard let route = ESheepCloudCommandRegistryV2.nativeProjectionRoute(
                for: payload.kind
            ) else {
                throw ESheepCloudProjectionError.unsupportedEvent
            }
            return try ESheepCloudAuthoritativeProjectionWriter.apply(
                command: command,
                route: route,
                event: event,
                entityType: projectionEntityType(for: event.stream.type),
                context: context
            )
        }
    }

    private static func projectionEntityType(for streamType: String) -> String {
        switch streamType {
        case "sheepProfile", "sheepAvatar", "sheepLocation", "sheepPresence":
            return CloudEntityType.sheep.rawValue
        case "feedStockLedger":
            return CloudEntityType.feedStockTransaction.rawValue
        case "feedRecipeMembers":
            return CloudEntityType.feedRecipeComponent.rawValue
        default:
            return streamType
        }
    }
}

private extension ESheepCloudCommandPayloadV2 {
    var isDeletion: Bool {
        if case .deletion = self { return true }
        return false
    }

    /// Convert the strongly typed V2 body into the domain command enum.  This
    /// is intentionally exhaustive; adding a V2 payload family without a
    /// domain writer makes the compiler fail rather than silently dropping a
    /// cloud event.
    var domainCommand: FarmCommand? {
        get throws {
            switch self {
            case .farm(let value):
                guard case .updateLocation(
                    let displayName,
                    let latitude,
                    let longitude,
                    let addressSnapshot,
                    let timeZoneIdentifier,
                    let source,
                    let horizontalAccuracyMeters
                ) = value.action else { return nil }
                return .updateFarmLocation(
                    displayName: displayName,
                    latitude: latitude,
                    longitude: longitude,
                    addressSnapshot: addressSnapshot,
                    timeZoneIdentifier: timeZoneIdentifier,
                    source: source,
                    horizontalAccuracyMeters: horizontalAccuracyMeters
                )

            case .pen(let value):
                switch value {
                case .create(let name, let note):
                    return .createPen(name: name, note: note)
                case .update(let penID, let name, let note):
                    return .updatePen(penID: penID, name: name, note: note)
                case .setActive(let penID, let isActive):
                    return .setPenActive(penID: penID, isActive: isActive)
                }

            case .sheep(let value):
                switch value {
                case .add(
                    let earTag,
                    let breed,
                    let sex,
                    let penID,
                    let occurredAt,
                    let birthAt,
                    let currentParity,
                    let note
                ):
                    return .addSheep(
                        earTag: earTag,
                        breed: breed,
                        sex: sex,
                        penID: penID,
                        occurredAt: occurredAt,
                        birthAt: birthAt,
                        currentParity: currentParity,
                        note: note
                    )
                case .patchProfile:
                    return nil
                case .setAvatar, .clearAvatar:
                    return nil
                }

            case .fact(let value):
                switch value {
                case .recordWeight(let sheepID, let kilogramsText, let occurredAt, let note):
                    return .recordWeight(
                        sheepID: sheepID,
                        kilogramsText: kilogramsText,
                        occurredAt: occurredAt,
                        note: note
                    )
                case .correctWeight(let originalID, let kilogramsText, let occurredAt, let note, let reason):
                    return .correctWeight(
                        originalID: originalID,
                        kilogramsText: kilogramsText,
                        occurredAt: occurredAt,
                        note: note,
                        reason: reason
                    )
                case .recordWeaning(
                    let sheepID,
                    let weanWeightText,
                    let occurredAt,
                    let birthAt,
                    let birthWeightText,
                    let averageDailyGainText,
                    let damID,
                    let litterSize,
                    let note
                ):
                    return .recordWeaning(
                        sheepID: sheepID,
                        weanWeightText: weanWeightText,
                        occurredAt: occurredAt,
                        birthAt: birthAt,
                        birthWeightText: birthWeightText,
                        averageDailyGainText: averageDailyGainText,
                        damID: damID,
                        litterSize: litterSize,
                        note: note
                    )
                case .transferSheep(let sheepID, let toPenID, let occurredAt, let note):
                    return .transferSheep(
                        sheepID: sheepID,
                        toPenID: toPenID,
                        occurredAt: occurredAt,
                        note: note
                    )
                case .correctTransfer(let originalID, let toPenID, let occurredAt, let note, let reason):
                    return .correctTransfer(
                        originalID: originalID,
                        toPenID: toPenID,
                        occurredAt: occurredAt,
                        note: note,
                        reason: reason
                    )
                case .removeSheep(
                    let sheepID,
                    let kind,
                    let reason,
                    let amountText,
                    let occurredAt,
                    let note,
                    let recordID,
                    let removalBatchID,
                    let batchTotalAmountText
                ):
                    return .removeSheep(
                        sheepID: sheepID,
                        kind: kind,
                        reason: reason,
                        amountText: amountText,
                        occurredAt: occurredAt,
                        note: note,
                        recordID: recordID,
                        removalBatchID: removalBatchID,
                        batchTotalAmountText: batchTotalAmountText
                    )
                case .correctRemoval(
                    let originalID,
                    let kind,
                    let reason,
                    let amountText,
                    let occurredAt,
                    let note,
                    let correctionReason
                ):
                    return .correctRemoval(
                        originalID: originalID,
                        kind: kind,
                        reason: reason,
                        amountText: amountText,
                        occurredAt: occurredAt,
                        note: note,
                        correctionReason: correctionReason
                    )
                case .restoreSheep(let removalID):
                    return .restoreSheep(removalID: removalID)
                case .recordHealth(
                    let sheepID,
                    let penID,
                    let kind,
                    let itemName,
                    let occurredAt,
                    let note,
                    let inventoryLotID,
                    let quantityText
                ):
                    return .recordHealth(
                        sheepID: sheepID,
                        penID: penID,
                        kind: kind,
                        itemName: itemName,
                        occurredAt: occurredAt,
                        note: note,
                        inventoryLotID: inventoryLotID,
                        quantityText: quantityText
                    )
                case .receiveInventory(
                    let catalogName,
                    let kind,
                    let expiresAt,
                    let quantityText,
                    let occurredAt,
                    let note
                ):
                    return .receiveInventory(
                        catalogName: catalogName,
                        kind: kind,
                        expiresAt: expiresAt,
                        quantityText: quantityText,
                        occurredAt: occurredAt,
                        note: note
                    )
                case .addSemen(let code, let breed, let source, let batchNumber, let quantityText):
                    return .addSemen(
                        code: code,
                        breed: breed,
                        source: source,
                        batchNumber: batchNumber,
                        quantityText: quantityText
                    )
                case .recordReproduction(
                    let eweID,
                    let kind,
                    let occurredAt,
                    let sireID,
                    let semenName,
                    let result,
                    let lambCount,
                    let parity,
                    let birthDeadCount,
                    let offspring,
                    let note
                ):
                    return .recordReproduction(
                        eweID: eweID,
                        kind: kind,
                        occurredAt: occurredAt,
                        sireID: sireID,
                        semenName: semenName,
                        result: result,
                        lambCount: lambCount,
                        parity: parity,
                        birthDeadCount: birthDeadCount,
                        offspring: offspring,
                        note: note
                    )
                case .addNote(let sheepID, let penID, let text, let occurredAt):
                    return .addNote(
                        sheepID: sheepID,
                        penID: penID,
                        text: text,
                        occurredAt: occurredAt
                    )
                }

            case .collection(let value):
                switch value {
                case .createBreedingProgram(let name, let createdAt, let steps):
                    return .createBreedingProgram(name: name, createdAt: createdAt, steps: steps)
                case .createBatch(let name, let purpose, let startedAt, let sheepIDs, let note):
                    return .createBatch(name: name, purpose: purpose, startedAt: startedAt, sheepIDs: sheepIDs, note: note)
                case .assignSheepToBatch(let batchID, let sheepID, let joinedAt):
                    return .assignSheepToBatch(batchID: batchID, sheepID: sheepID, joinedAt: joinedAt)
                case .leaveBatch(let batchID, let sheepID, let leftAt, let reason):
                    return .leaveBatch(batchID: batchID, sheepID: sheepID, leftAt: leftAt, reason: reason)
                case .restoreBatchMembership(let membershipID, let restoredAt, let reason):
                    return .restoreBatchMembership(membershipID: membershipID, restoredAt: restoredAt, reason: reason)
                case .addIngredient(let name, let unit, let dryMatterText):
                    return .addIngredient(name: name, unit: unit, dryMatterText: dryMatterText)
                case .createRecipe(let name, let note):
                    return .createRecipe(name: name, note: note)
                case .addRecipeComponent(let recipeID, let ingredientID, let kilogramsText):
                    return .addRecipeComponent(recipeID: recipeID, ingredientID: ingredientID, kilogramsText: kilogramsText)
                }

            case .feed(let value):
                switch value {
                case .recordLegacy(let penID, let recipeID, let mode, let occurredAt, let lines, let note):
                    return .recordFeed(penID: penID, recipeID: recipeID, mode: mode, occurredAt: occurredAt, lines: lines, note: note)
                case .saveIngredient(let draft):
                    return .saveFeedIngredient(draft)
                case .saveBatch(let draft):
                    return .saveFeedBatch(draft)
                case .adjustStock(let batchID, let kind, let quantityText, let occurredAt, let note):
                    return .adjustFeedStock(batchID: batchID, kind: kind, quantityText: quantityText, occurredAt: occurredAt, note: note)
                case .countStock(let countID, let batchID, let actualKilogramsText, let method, let occurredAt, let note):
                    return .countFeedStock(countID: countID, batchID: batchID, actualKilogramsText: actualKilogramsText, method: method, occurredAt: occurredAt, note: note)
                case .saveRecipe(let draft):
                    return .saveFeedRecipe(draft)
                case .record(let draft):
                    return .recordFeedV2(draft)
                case .recordTroughObservation(let draft):
                    return .recordFeedTroughObservation(draft)
                case .importHistorical(let draft):
                    return .importHistoricalFeed(draft)
                }

            case .care(let command):
                return .care(command)

            case .tmr(let command):
                return .tmr(command)

            case .deletion(let value):
                switch value {
                case .tombstone(let entityType, let entityID, let reason):
                    return .tombstoneEntity(entityType: entityType, entityID: entityID, reason: reason)
                case .restore(let tombstoneID):
                    return .restoreTombstonedEntity(tombstoneID: tombstoneID)
                }

            case .photo:
                return nil
            }
        }
    }
}
