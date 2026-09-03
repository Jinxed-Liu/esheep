import Foundation

struct ESheepCloudCommandDraftV2: Sendable {
    let payload: ESheepCloudCommandPayloadV2
    let occurredAt: Date
    let affectedStreams: [ESheepCloudStreamReferenceV2]
    let affectedFieldKeys: [String]
    let fieldChanges: [ESheepCloudFieldPatchV2]
    let requiredAssetIDs: [UUID]

    var kind: String { payload.kind }
}

enum ESheepCloudCommandFactoryV2 {
    static func make(
        command: FarmCommand,
        farmID: UUID,
        primaryEntityType: String,
        primaryEntityID: UUID?
    ) throws -> ESheepCloudCommandDraftV2 {
        let primaryStream = ESheepCloudStreamReferenceV2(
            type: normalizedStreamType(primaryEntityType),
            id: primaryEntityID ?? farmID
        )

        switch command {
        case .updateFarmLocation(
            let displayName,
            let latitude,
            let longitude,
            let addressSnapshot,
            let timeZoneIdentifier,
            let source,
            let horizontalAccuracyMeters
        ):
            let changes: [ESheepCloudFieldPatchV2] = [
                .init(field: "displayName", mutation: .set(.string(displayName))),
                .init(field: "latitude", mutation: .set(.decimal(String(latitude)))),
                .init(field: "longitude", mutation: .set(.decimal(String(longitude)))),
                .init(field: "addressSnapshot", mutation: addressSnapshot.map { .set(.string($0)) } ?? .clear),
                .init(field: "timeZoneIdentifier", mutation: .set(.string(timeZoneIdentifier))),
                .init(field: "locationSource", mutation: .set(.string(source.rawValue))),
                .init(
                    field: "horizontalAccuracyMeters",
                    mutation: horizontalAccuracyMeters.map {
                        .set(.decimal(String($0)))
                    } ?? .clear
                ),
            ]
            return draft(
                .farm(.init(action: .updateLocation(
                    displayName: displayName,
                    latitude: latitude,
                    longitude: longitude,
                    addressSnapshot: addressSnapshot,
                    timeZoneIdentifier: timeZoneIdentifier,
                    source: source,
                    horizontalAccuracyMeters: horizontalAccuracyMeters
                ))),
                stream: .init(type: "farm", id: farmID),
                fields: changes.map(\.field),
                changes: changes
            )

        case .createPen(let name, let note):
            return draft(.pen(.create(name: name, note: note)), stream: primaryStream)
        case .updatePen(let penID, let name, let note):
            return draft(
                .pen(.update(penID: penID, name: name, note: note)),
                stream: .init(type: "pen", id: penID),
                fields: ["name", "note"],
                changes: [
                    .init(field: "name", mutation: .set(.string(name))),
                    .init(field: "note", mutation: .set(.string(note))),
                ]
            )
        case .setPenActive(let penID, let isActive):
            return draft(
                .pen(.setActive(penID: penID, isActive: isActive)),
                stream: .init(type: "pen", id: penID),
                fields: ["isActive"],
                changes: [.init(field: "isActive", mutation: .set(.boolean(isActive)))]
            )

        case .addSheep(let earTag, let breed, let sex, let penID, let occurredAt, let birthAt, let currentParity, let note):
            return draft(
                .sheep(.add(
                    earTag: earTag,
                    breed: breed,
                    sex: sex,
                    penID: penID,
                    occurredAt: occurredAt,
                    birthAt: birthAt,
                    currentParity: currentParity,
                    note: note
                )),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .updateSheepProfile(let sheepID, let earTag, let breed, let sex, let birthAt, let currentParity, let parityRecordedAt, let note):
            let patches: [ESheepCloudFieldPatchV2] = [
                .init(field: "earTag", mutation: .set(.string(earTag))),
                .init(field: "breed", mutation: .set(.string(breed))),
                .init(field: "sex", mutation: .set(.string(sex.rawValue))),
                .init(field: "birthAt", mutation: birthAt.map { .set(.date($0)) } ?? .clear),
                .init(field: "currentParity", mutation: currentParity.map { .set(.integer($0)) } ?? .clear),
                .init(field: "parityRecordedAt", mutation: parityRecordedAt.map { .set(.date($0)) } ?? .clear),
                .init(field: "note", mutation: .set(.string(note))),
            ]
            return draft(
                .sheep(.patchProfile(sheepID: sheepID, fields: patches)),
                occurredAt: parityRecordedAt ?? .now,
                stream: .init(type: "sheepProfile", id: sheepID),
                fields: patches.map(\.field),
                changes: patches
            )

        case .recordWeight(let sheepID, let kilogramsText, let occurredAt, let note):
            return draft(
                .fact(.recordWeight(sheepID: sheepID, kilogramsText: kilogramsText, occurredAt: occurredAt, note: note)),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .correctWeight(let originalID, let kilogramsText, let occurredAt, let note, let reason):
            return draft(
                .fact(.correctWeight(originalID: originalID, kilogramsText: kilogramsText, occurredAt: occurredAt, note: note, reason: reason)),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .recordWeaning(let sheepID, let weanWeightText, let occurredAt, let birthAt, let birthWeightText, let averageDailyGainText, let damID, let litterSize, let note):
            return draft(
                .fact(.recordWeaning(
                    sheepID: sheepID,
                    weanWeightText: weanWeightText,
                    occurredAt: occurredAt,
                    birthAt: birthAt,
                    birthWeightText: birthWeightText,
                    averageDailyGainText: averageDailyGainText,
                    damID: damID,
                    litterSize: litterSize,
                    note: note
                )),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .createBreedingProgram(let name, let createdAt, let steps):
            return draft(
                .collection(.createBreedingProgram(name: name, createdAt: createdAt, steps: steps)),
                occurredAt: createdAt,
                stream: primaryStream
            )
        case .transferSheep(let sheepID, let toPenID, let occurredAt, let note):
            return draft(
                .fact(.transferSheep(sheepID: sheepID, toPenID: toPenID, occurredAt: occurredAt, note: note)),
                occurredAt: occurredAt,
                streams: streams(
                    primary: primaryStream,
                    semantic: .init(type: "sheepLocation", id: sheepID)
                )
            )
        case .correctTransfer(let originalID, let toPenID, let occurredAt, let note, let reason):
            return draft(
                .fact(.correctTransfer(originalID: originalID, toPenID: toPenID, occurredAt: occurredAt, note: note, reason: reason)),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .removeSheep(let sheepID, let kind, let reason, let amountText, let occurredAt, let note, let recordID, let removalBatchID, let batchTotalAmountText):
            return draft(
                .fact(.removeSheep(
                    sheepID: sheepID,
                    kind: kind,
                    reason: reason,
                    amountText: amountText,
                    occurredAt: occurredAt,
                    note: note,
                    recordID: recordID,
                    removalBatchID: removalBatchID,
                    batchTotalAmountText: batchTotalAmountText
                )),
                occurredAt: occurredAt,
                streams: streams(
                    primary: primaryStream,
                    semantic: .init(type: "sheepPresence", id: sheepID)
                )
            )
        case .correctRemoval(let originalID, let kind, let reason, let amountText, let occurredAt, let note, let correctionReason):
            return draft(
                .fact(.correctRemoval(
                    originalID: originalID,
                    kind: kind,
                    reason: reason,
                    amountText: amountText,
                    occurredAt: occurredAt,
                    note: note,
                    correctionReason: correctionReason
                )),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .restoreSheep(let removalID):
            return draft(.fact(.restoreSheep(removalID: removalID)), stream: primaryStream)

        case .createBatch(let name, let purpose, let startedAt, let sheepIDs, let note):
            return draft(
                .collection(.createBatch(name: name, purpose: purpose, startedAt: startedAt, sheepIDs: sheepIDs, note: note)),
                occurredAt: startedAt,
                stream: primaryStream
            )
        case .assignSheepToBatch(let batchID, let sheepID, let joinedAt):
            return draft(
                .collection(.assignSheepToBatch(batchID: batchID, sheepID: sheepID, joinedAt: joinedAt)),
                occurredAt: joinedAt,
                stream: .init(type: "batchMembership", id: primaryEntityID ?? sheepID)
            )
        case .leaveBatch(let batchID, let sheepID, let leftAt, let reason):
            return draft(
                .collection(.leaveBatch(batchID: batchID, sheepID: sheepID, leftAt: leftAt, reason: reason)),
                occurredAt: leftAt,
                stream: primaryStream
            )
        case .restoreBatchMembership(let membershipID, let restoredAt, let reason):
            return draft(
                .collection(.restoreBatchMembership(membershipID: membershipID, restoredAt: restoredAt, reason: reason)),
                occurredAt: restoredAt,
                stream: .init(type: "batchMembership", id: membershipID)
            )

        case .addIngredient(let name, let unit, let dryMatterText):
            return draft(.collection(.addIngredient(name: name, unit: unit, dryMatterText: dryMatterText)), stream: primaryStream)
        case .createRecipe(let name, let note):
            return draft(.collection(.createRecipe(name: name, note: note)), stream: primaryStream)
        case .addRecipeComponent(let recipeID, let ingredientID, let kilogramsText):
            return draft(
                .collection(.addRecipeComponent(recipeID: recipeID, ingredientID: ingredientID, kilogramsText: kilogramsText)),
                streams: streams(
                    primary: primaryStream,
                    semantic: .init(type: "feedRecipeMembers", id: recipeID)
                )
            )
        case .recordFeed(let penID, let recipeID, let mode, let occurredAt, let lines, let note):
            return draft(
                .feed(.recordLegacy(penID: penID, recipeID: recipeID, mode: mode, occurredAt: occurredAt, lines: lines, note: note)),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .saveFeedIngredient(let value):
            return draft(
                .feed(.saveIngredient(value)),
                stream: primaryStream,
                fields: value.id == nil ? [] : ["name", "unit", "category", "dryMatter", "nutrients", "note"]
            )
        case .saveFeedBatch(let value):
            return draft(
                .feed(.saveBatch(value)),
                stream: primaryStream,
                fields: value.id == nil ? [] : ["batchName", "supplier", "storageLocation", "price", "isActive"]
            )
        case .adjustFeedStock(let batchID, let kind, let quantityText, let occurredAt, let note):
            return draft(
                .feed(.adjustStock(batchID: batchID, kind: kind, quantityText: quantityText, occurredAt: occurredAt, note: note)),
                occurredAt: occurredAt,
                streams: streams(
                    primary: primaryStream,
                    semantic: .init(type: "feedStockLedger", id: batchID)
                )
            )
        case .countFeedStock(let countID, let batchID, let actualKilogramsText, let method, let occurredAt, let note):
            return draft(
                .feed(.countStock(countID: countID, batchID: batchID, actualKilogramsText: actualKilogramsText, method: method, occurredAt: occurredAt, note: note)),
                occurredAt: occurredAt,
                streams: streams(
                    primary: primaryStream,
                    semantic: .init(type: "feedStockLedger", id: batchID)
                )
            )
        case .saveFeedRecipe(let value):
            return draft(
                .feed(.saveRecipe(value)),
                stream: primaryStream,
                fields: value.id == nil ? [] : ["name", "targetPen", "stage", "headCount", "note"]
            )
        case .recordFeedV2(let value):
            return draft(.feed(.record(value)), occurredAt: value.occurredAt, stream: primaryStream)
        case .recordFeedTroughObservation(let value):
            return draft(.feed(.recordTroughObservation(value)), occurredAt: value.observedAt, stream: primaryStream)
        case .importHistoricalFeed(let value):
            return draft(.feed(.importHistorical(value)), occurredAt: value.occurredAt, stream: primaryStream)

        case .recordHealth(let sheepID, let penID, let kind, let itemName, let occurredAt, let note, let inventoryLotID, let quantityText):
            return draft(
                .fact(.recordHealth(
                    sheepID: sheepID,
                    penID: penID,
                    kind: kind,
                    itemName: itemName,
                    occurredAt: occurredAt,
                    note: note,
                    inventoryLotID: inventoryLotID,
                    quantityText: quantityText
                )),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .receiveInventory(let catalogName, let kind, let expiresAt, let quantityText, let occurredAt, let note):
            return draft(
                .fact(.receiveInventory(catalogName: catalogName, kind: kind, expiresAt: expiresAt, quantityText: quantityText, occurredAt: occurredAt, note: note)),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .addSemen(let code, let breed, let source, let batchNumber, let quantityText):
            return draft(.fact(.addSemen(code: code, breed: breed, source: source, batchNumber: batchNumber, quantityText: quantityText)), stream: primaryStream)
        case .recordReproduction(let eweID, let kind, let occurredAt, let sireID, let semenName, let result, let lambCount, let parity, let birthDeadCount, let offspring, let note):
            return draft(
                .fact(.recordReproduction(
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
                )),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .care(let value):
            return draft(
                .care(value),
                occurredAt: careOccurredAt(value) ?? .now,
                streams: streams(
                    primary: primaryStream,
                    semantic: careStream(value, fallback: primaryStream)
                ),
                fields: careAffectedFields(value)
            )
        case .tmr(let value):
            return draft(
                .tmr(value),
                stream: primaryStream,
                fields: tmrAffectedFields(value)
            )
        case .addNote(let sheepID, let penID, let text, let occurredAt):
            return draft(
                .fact(.addNote(sheepID: sheepID, penID: penID, text: text, occurredAt: occurredAt)),
                occurredAt: occurredAt,
                stream: primaryStream
            )
        case .tombstoneEntity(let entityType, let entityID, let reason):
            return draft(
                .deletion(.tombstone(entityType: entityType, entityID: entityID, reason: reason)),
                stream: .init(type: normalizedStreamType(entityType.rawValue), id: entityID),
                fields: ["lifecycle"]
            )
        case .restoreTombstonedEntity(let tombstoneID):
            return draft(.deletion(.restore(tombstoneID: tombstoneID)), stream: primaryStream, fields: ["lifecycle"])
        }
    }

    static func avatar(
        sheepID: UUID,
        photoAssetID: UUID?,
        occurredAt: Date = .now
    ) -> ESheepCloudCommandDraftV2 {
        let payload: ESheepCloudCommandPayloadV2 = photoAssetID.map {
            .sheep(.setAvatar(sheepID: sheepID, photoAssetID: $0))
        } ?? .sheep(.clearAvatar(sheepID: sheepID))
        return draft(
            payload,
            occurredAt: occurredAt,
            stream: .init(type: "sheepAvatar", id: sheepID),
            fields: ["avatar"],
            changes: [
                .init(
                    field: "avatar",
                    mutation: photoAssetID.map { .set(.identifier($0)) } ?? .clear
                ),
            ],
            requiredAssetIDs: photoAssetID.map { [$0] } ?? []
        )
    }

    static func registerPhoto(
        assetID: UUID,
        sheepID: UUID?,
        capturedAt: Date?,
        mimeType: String,
        contentSHA256: String,
        metadata: [String: String],
        metadataDigest: String,
        thumbnailSHA256: String,
        avatarSHA256: String,
        originalSHA256: String,
        thumbnailByteCount: Int64,
        avatarByteCount: Int64,
        originalByteCount: Int64,
        occurredAt: Date = .now
    ) -> ESheepCloudCommandDraftV2 {
        draft(
            .photo(.register(
                assetID: assetID,
                sheepID: sheepID,
                capturedAt: capturedAt,
                mimeType: mimeType,
                contentSHA256: contentSHA256,
                metadata: metadata,
                metadataDigest: metadataDigest,
                thumbnailSHA256: thumbnailSHA256,
                avatarSHA256: avatarSHA256,
                originalSHA256: originalSHA256,
                thumbnailByteCount: max(0, thumbnailByteCount),
                avatarByteCount: max(0, avatarByteCount),
                originalByteCount: max(0, originalByteCount)
            )),
            occurredAt: occurredAt,
            stream: .init(type: "photoAsset", id: assetID),
            requiredAssetIDs: [assetID]
        )
    }

    private static func draft(
        _ payload: ESheepCloudCommandPayloadV2,
        occurredAt: Date = .now,
        stream: ESheepCloudStreamReferenceV2,
        fields: [String] = [],
        changes: [ESheepCloudFieldPatchV2] = [],
        requiredAssetIDs: [UUID] = []
    ) -> ESheepCloudCommandDraftV2 {
        draft(
            payload,
            occurredAt: occurredAt,
            streams: [stream],
            fields: fields,
            changes: changes,
            requiredAssetIDs: requiredAssetIDs
        )
    }

    private static func draft(
        _ payload: ESheepCloudCommandPayloadV2,
        occurredAt: Date = .now,
        streams: [ESheepCloudStreamReferenceV2],
        fields: [String] = [],
        changes: [ESheepCloudFieldPatchV2] = [],
        requiredAssetIDs: [UUID] = []
    ) -> ESheepCloudCommandDraftV2 {
        ESheepCloudCommandDraftV2(
            payload: payload,
            occurredAt: occurredAt,
            affectedStreams: streams,
            affectedFieldKeys: Array(Set(fields)).sorted(),
            fieldChanges: changes.sorted { $0.field < $1.field },
            requiredAssetIDs: Array(Set(requiredAssetIDs)).sorted { $0.uuidString < $1.uuidString }
        )
    }

    /// The first stream always identifies the concrete business projection
    /// created by the command. Additional semantic streams describe the
    /// ledger, location or state-machine lane without losing the stable record
    /// ID required by a newly installed device.
    private static func streams(
        primary: ESheepCloudStreamReferenceV2,
        semantic: ESheepCloudStreamReferenceV2
    ) -> [ESheepCloudStreamReferenceV2] {
        primary == semantic ? [primary] : [primary, semantic]
    }

    private static func normalizedStreamType(_ value: String) -> String {
        guard !value.isEmpty, value != "FarmRoot" else { return "farm" }
        return value.prefix(1).lowercased() + value.dropFirst()
    }

    private static func careStream(
        _ command: CareCommand,
        fallback: ESheepCloudStreamReferenceV2
    ) -> ESheepCloudStreamReferenceV2 {
        switch command {
        case .updateSheepPedigree(let value):
            .init(type: "sheepPedigree", id: value.sheepID)
        case .setBreedingRam(let sheepID, _, _), .setSheepPurpose(let sheepID, _, _, _):
            .init(type: "sheepProfile", id: sheepID)
        case .setSemenDonor(let semenID, _, _):
            .init(type: "semen", id: semenID)
        case .setInventoryLotActive(let lotID, _):
            .init(type: "inventoryLot", id: lotID)
        case .updateRules(let id, _, _):
            .init(type: "careRules", id: id)
        case .setReminderStatus(let reminderID, _):
            .init(type: "careReminder", id: reminderID)
        default:
            fallback
        }
    }

    private static func careAffectedFields(_ command: CareCommand) -> [String] {
        switch command {
        case .upsertHealthCatalog: ["name", "category", "unit", "defaults", "note", "isActive"]
        case .setInventoryLotActive: ["isActive"]
        case .upsertSemenDonor: ["registration", "profile"]
        case .setSemenDonor: ["donor"]
        case .updateSheepPedigree: ["dam", "sire", "semenDonor"]
        case .setBreedingRam: ["isBreedingRam"]
        case .setSheepPurpose: ["purpose"]
        case .updateRules: ["pregnancyCheckDays", "gestationDays"]
        case .updateOperationalAlertRules: ["rules"]
        case .setReminderStatus: ["status"]
        case .recordHealth, .correctHealth, .receiveInventory, .adjustInventory,
             .adjustSemen, .restorePedigreeAudit, .recordReproductionBatch,
             .recordLambing, .correctReproduction, .correctLambing,
             .revokeLambing, .restoreLambing, .deferOperationalAlert:
            []
        }
    }

    private static func careOccurredAt(_ command: CareCommand) -> Date? {
        switch command {
        case .recordHealth(let value): value.occurredAt
        case .correctHealth(_, let value, _): value.occurredAt
        case .receiveInventory(_, _, _, _, _, _, _, _, _, let occurredAt, _): occurredAt
        case .adjustInventory(_, _, _, let occurredAt, _): occurredAt
        case .adjustSemen(_, _, _, let occurredAt, _): occurredAt
        case .recordReproductionBatch(let value): value.occurredAt
        case .recordLambing(let value): value.occurredAt
        case .correctReproduction(_, let value, _): value.occurredAt
        case .correctLambing(_, let value, _): value.occurredAt
        default: nil
        }
    }

    private static func tmrAffectedFields(_ command: TMRCommand) -> [String] {
        switch command {
        case .saveFormula: ["formula"]
        case .saveMonitoringRule: ["monitoringRule"]
        case .saveFeedingPlan: ["feedingPlan"]
        case .adjustBatch, .closeBatch: ["batchBalance"]
        case .completeMeal, .reopenMeal: ["mealState"]
        case .acknowledgeDeviation: ["acknowledgement"]
        case .produceBatch, .recordFeeding, .correctFeedingRun,
             .reverseFeedingRun, .deleteUnusedBatch:
            []
        }
    }
}
