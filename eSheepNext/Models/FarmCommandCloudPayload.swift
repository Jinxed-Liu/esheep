import Foundation

struct FarmCommandCloudPayload: Codable, Sendable, Equatable {
    struct BreedingProgramStep: Codable, Sendable, Equatable {
        let id: UUID
        let dayOffset: Int
        let action: String
        let sortOrder: Int
    }

    struct FeedLine: Codable, Sendable, Equatable {
        let id: UUID
        let ingredientID: UUID
        let kilogramsText: String
        let ingredientBatchID: UUID?
        let ingredientNameSnapshot: String?
        let ingredientBatchNameSnapshot: String?
        let pricePerKilogramTextSnapshot: String?
        let nutrientSnapshotJSON: String?
        let unitSnapshot: String?
        let dryMatterTextSnapshot: String?

        init(
            id: UUID,
            ingredientID: UUID,
            kilogramsText: String,
            ingredientBatchID: UUID? = nil,
            ingredientNameSnapshot: String? = nil,
            ingredientBatchNameSnapshot: String? = nil,
            pricePerKilogramTextSnapshot: String? = nil,
            nutrientSnapshotJSON: String? = nil,
            unitSnapshot: String? = nil,
            dryMatterTextSnapshot: String? = nil
        ) {
            self.id = id
            self.ingredientID = ingredientID
            self.kilogramsText = kilogramsText
            self.ingredientBatchID = ingredientBatchID
            self.ingredientNameSnapshot = ingredientNameSnapshot
            self.ingredientBatchNameSnapshot = ingredientBatchNameSnapshot
            self.pricePerKilogramTextSnapshot = pricePerKilogramTextSnapshot
            self.nutrientSnapshotJSON = nutrientSnapshotJSON
            self.unitSnapshot = unitSnapshot
            self.dryMatterTextSnapshot = dryMatterTextSnapshot
        }
    }

    struct FeedRecipeComponent: Codable, Sendable, Equatable {
        let id: UUID
        let ingredientID: UUID
        let ingredientBatchID: UUID?
        let kilogramsText: String
        let legacyBatchID: String?
        let pricePerKilogramText: String?
        let nutrientSnapshotJSON: String
    }

    struct LambingOffspring: Codable, Sendable, Equatable {
        let id: UUID
        let sheepID: UUID?
        let earTag: String
        let sexRawValue: String
        let birthWeightText: String
        var isStillborn: Bool? = nil
        var autoCreatedSheep: Bool? = nil
        var autoBirthWeightRecordID: UUID? = nil
        var deletedByLambingRevocation: Bool? = nil
        var revision: Int? = nil
        var updatedAt: Date? = nil
        var deletedAt: Date? = nil
    }

    let kind: DomainOperationKind
    var strings: [String: String] = [:]
    var optionalStrings: [String: String?] = [:]
    var identifiers: [String: UUID] = [:]
    var optionalIdentifiers: [String: UUID?] = [:]
    var dates: [String: Date] = [:]
    var optionalDates: [String: Date?] = [:]
    var integers: [String: Int] = [:]
    var dataValues: [String: Data] = [:]
    var feedLines: [FeedLine] = []
    var recipeComponents: [FeedRecipeComponent] = []
    var breedingProgramSteps: [BreedingProgramStep] = []
    var lambingOffspring: [LambingOffspring] = []
    var careCommand: CareCommand?
    var tmrCommand: TMRCommand?
    var tmrBaselineSnapshot: FarmTMRBackupPayload? = nil

    private enum CodingKeys: String, CodingKey {
        case kind
        case strings
        case optionalStrings
        case identifiers
        case optionalIdentifiers
        case dates
        case optionalDates
        case integers
        case dataValues
        case feedLines
        case recipeComponents
        case breedingProgramSteps
        case lambingOffspring
        case careCommand
        case tmrCommand
        case tmrBaselineSnapshot
    }

    init(kind: DomainOperationKind) {
        self.kind = kind
    }

    /// Cloud operations are immutable and outlive individual app versions.
    /// Collections added by later clients therefore decode as their original
    /// empty defaults when an older operation did not encode those keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(DomainOperationKind.self, forKey: .kind)
        strings = try container.decodeIfPresent(
            [String: String].self,
            forKey: .strings
        ) ?? [:]
        optionalStrings = try container.decodeIfPresent(
            [String: String?].self,
            forKey: .optionalStrings
        ) ?? [:]
        identifiers = try container.decodeIfPresent(
            [String: UUID].self,
            forKey: .identifiers
        ) ?? [:]
        optionalIdentifiers = try container.decodeIfPresent(
            [String: UUID?].self,
            forKey: .optionalIdentifiers
        ) ?? [:]
        dates = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .dates
        ) ?? [:]
        optionalDates = try container.decodeIfPresent(
            [String: Date?].self,
            forKey: .optionalDates
        ) ?? [:]
        integers = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .integers
        ) ?? [:]
        dataValues = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .dataValues
        ) ?? [:]
        feedLines = try container.decodeIfPresent(
            [FeedLine].self,
            forKey: .feedLines
        ) ?? []
        recipeComponents = try container.decodeIfPresent(
            [FeedRecipeComponent].self,
            forKey: .recipeComponents
        ) ?? []
        breedingProgramSteps = try container.decodeIfPresent(
            [BreedingProgramStep].self,
            forKey: .breedingProgramSteps
        ) ?? []
        lambingOffspring = try container.decodeIfPresent(
            [LambingOffspring].self,
            forKey: .lambingOffspring
        ) ?? []
        careCommand = try container.decodeIfPresent(
            CareCommand.self,
            forKey: .careCommand
        )
        tmrCommand = try container.decodeIfPresent(
            TMRCommand.self,
            forKey: .tmrCommand
        )
        tmrBaselineSnapshot = try container.decodeIfPresent(
            FarmTMRBackupPayload.self,
            forKey: .tmrBaselineSnapshot
        )
    }
}

enum TMRCloudDataProtocol {
    static let currentVersion = 1
    static let field = "tmrDataProtocolVersion"

    static func isSupported(by payload: FarmCommandCloudPayload) -> Bool {
        payload.integers[field] == currentVersion
    }

}

enum FarmCommandCloudPayloadEncoder {
    static func encode(
        _ command: FarmCommand,
        resolvedFeedLines: [FarmCommandCloudPayload.FeedLine]? = nil,
        sheepAvatarUpdate: SheepAvatarPhotoUpdate? = nil
    ) throws -> Data {
        var payload = FarmCommandCloudPayload(kind: command.operationKind)
        switch command {
        case .care(let careCommand):
            payload.careCommand = careCommand
        case .tmr(let tmrCommand):
            payload.tmrCommand = tmrCommand
            payload.integers[TMRCloudDataProtocol.field] = TMRCloudDataProtocol.currentVersion
        case .updateFarmLocation(let displayName, let latitude, let longitude, let addressSnapshot, let timeZoneIdentifier, let source, let horizontalAccuracyMeters):
            payload.strings = [
                "displayName": displayName,
                "latitude": String(latitude),
                "longitude": String(longitude),
                "timeZoneIdentifier": timeZoneIdentifier,
                "source": source.rawValue,
            ]
            payload.optionalStrings = [
                "addressSnapshot": addressSnapshot,
                "horizontalAccuracyMeters": horizontalAccuracyMeters.map { String($0) },
            ]
        case .createPen(let name, let note):
            payload.strings = ["name": name, "note": note]
        case .updatePen(let penID, let name, let note):
            payload.identifiers = ["penID": penID]
            payload.strings = ["name": name, "note": note]
        case .setPenActive(let penID, let isActive):
            payload.identifiers = ["penID": penID]
            payload.integers = ["isActive": isActive ? 1 : 0]
        case .addSheep(let earTag, let breed, let sex, let penID, let occurredAt, let birthAt, let currentParity, let note):
            payload.strings = ["earTag": earTag, "breed": breed, "sex": sex.rawValue, "note": note]
            payload.optionalIdentifiers = ["penID": penID]
            payload.dates = ["occurredAt": occurredAt]
            payload.optionalDates = ["birthAt": birthAt]
            if let currentParity { payload.integers["currentParity"] = currentParity }
        case .updateSheepProfile(let sheepID, let earTag, let breed, let sex, let birthAt, let currentParity, let parityRecordedAt, let note):
            payload.identifiers = ["sheepID": sheepID]
            payload.strings = ["earTag": earTag, "breed": breed, "sex": sex.rawValue, "note": note]
            payload.optionalDates = ["birthAt": birthAt]
            if let currentParity { payload.integers["currentParity"] = currentParity }
            if let parityRecordedAt { payload.dates["parityRecordedAt"] = parityRecordedAt }
        case .recordWeight(let sheepID, let kilogramsText, let occurredAt, let note):
            payload.identifiers = ["sheepID": sheepID]
            payload.strings = ["kilogramsText": kilogramsText, "note": note]
            payload.dates = ["occurredAt": occurredAt]
        case .correctWeight(let originalID, let kilogramsText, let occurredAt, let note, let reason):
            payload.identifiers = ["originalID": originalID]
            payload.strings = ["kilogramsText": kilogramsText, "note": note, "reason": reason]
            payload.dates = ["occurredAt": occurredAt]
        case .recordWeaning(let sheepID, let weanWeightText, let occurredAt, let birthAt, let birthWeightText, let averageDailyGainText, let damID, let litterSize, let note):
            payload.identifiers = ["sheepID": sheepID]
            payload.optionalIdentifiers = ["damID": damID]
            payload.strings = ["weanWeightText": weanWeightText, "note": note]
            payload.optionalStrings = ["birthWeightText": birthWeightText, "averageDailyGainText": averageDailyGainText]
            payload.dates = ["occurredAt": occurredAt]
            payload.optionalDates = ["birthAt": birthAt]
            if let litterSize { payload.integers = ["litterSize": litterSize] }
        case .createBreedingProgram(let name, let createdAt, let steps):
            payload.strings = ["name": name]
            payload.dates = ["createdAt": createdAt]
            payload.breedingProgramSteps = steps.enumerated().map {
                .init(id: $0.element.id, dayOffset: $0.element.dayOffset, action: $0.element.action, sortOrder: $0.offset)
            }
        case .transferSheep(let sheepID, let toPenID, let occurredAt, let note):
            payload.identifiers = ["sheepID": sheepID]
            payload.optionalIdentifiers = ["toPenID": toPenID]
            payload.dates = ["occurredAt": occurredAt]
            payload.strings = ["note": note]
        case .correctTransfer(let originalID, let toPenID, let occurredAt, let note, let reason):
            payload.identifiers = ["originalID": originalID]
            payload.optionalIdentifiers = ["toPenID": toPenID]
            payload.dates = ["occurredAt": occurredAt]
            payload.strings = ["note": note, "reason": reason]
        case .removeSheep(let sheepID, let kind, let reason, let amountText, let occurredAt, let note, _, let removalBatchID, let batchTotalAmountText):
            payload.identifiers = ["sheepID": sheepID]
            payload.optionalIdentifiers = ["removalBatchID": removalBatchID]
            payload.strings = ["kind": kind.rawValue, "reason": reason, "note": note]
            payload.optionalStrings = [
                "amountText": stableDecimalText(amountText),
                "batchTotalAmountText": stableDecimalText(batchTotalAmountText),
            ]
            payload.dates = ["occurredAt": occurredAt]
        case .correctRemoval(let originalID, let kind, let reason, let amountText, let occurredAt, let note, let correctionReason):
            payload.identifiers = ["originalID": originalID]
            payload.strings = ["kind": kind.rawValue, "reason": reason, "note": note, "correctionReason": correctionReason]
            payload.optionalStrings = ["amountText": stableDecimalText(amountText)]
            payload.dates = ["occurredAt": occurredAt]
        case .restoreSheep(let removalID):
            payload.identifiers = ["removalID": removalID]
        case .createBatch(let name, let purpose, let startedAt, let sheepIDs, let note):
            payload.strings = [
                "name": name,
                "purpose": purpose,
                "note": note,
                "sheepIDs": sheepIDs.map { $0.uuidString.lowercased() }.joined(separator: ","),
            ]
            payload.dates = ["startedAt": startedAt]
        case .assignSheepToBatch(let batchID, let sheepID, let joinedAt):
            payload.identifiers = ["batchID": batchID, "sheepID": sheepID]
            payload.dates = ["joinedAt": joinedAt]
        case .leaveBatch(let batchID, let sheepID, let leftAt, let reason):
            payload.identifiers = ["batchID": batchID, "sheepID": sheepID]
            payload.dates = ["leftAt": leftAt]
            payload.strings = ["reason": reason]
        case .addIngredient(let name, let unit, let dryMatterText):
            payload.strings = ["name": name, "unit": unit]
            payload.optionalStrings = ["dryMatterText": dryMatterText]
        case .createRecipe(let name, let note):
            payload.strings = ["name": name, "note": note]
        case .addRecipeComponent(let recipeID, let ingredientID, let kilogramsText):
            payload.identifiers = ["recipeID": recipeID, "ingredientID": ingredientID]
            payload.strings = ["kilogramsText": kilogramsText]
        case .recordFeed(let penID, let recipeID, let mode, let occurredAt, let lines, let note):
            payload.identifiers = ["penID": penID]
            payload.optionalIdentifiers = ["recipeID": recipeID]
            payload.strings = ["mode": mode.rawValue, "note": note]
            payload.dates = ["occurredAt": occurredAt]
            payload.feedLines = resolvedFeedLines ?? lines.map {
                .init(id: $0.id, ingredientID: $0.ingredientID, kilogramsText: $0.kilogramsText, ingredientBatchID: $0.ingredientBatchID)
            }
        case .saveFeedIngredient(let draft):
            if let id = draft.id { payload.identifiers["ingredientID"] = id }
            payload.strings = [
                "name": draft.name,
                "unit": draft.unit,
                "category": draft.category,
                "kind": draft.kind.rawValue,
                "nutrientSnapshotJSON": draft.nutrientSnapshotJSON,
                "note": draft.note,
            ]
            payload.optionalStrings = [
                "dryMatterText": draft.dryMatterText,
                "sourceTemplateID": draft.sourceTemplateID,
                "sourceTemplateCode": draft.sourceTemplateCode,
                "mixtureComponentsJSON": draft.mixtureComponentsJSON,
            ]
        case .saveFeedBatch(let draft):
            if let id = draft.id { payload.identifiers["batchID"] = id }
            payload.identifiers["ingredientID"] = draft.ingredientID
            payload.strings = [
                "batchName": draft.batchName,
                "supplier": draft.supplier,
                "storageLocation": draft.storageLocation,
                "pricePerKilogramText": draft.pricePerKilogramText,
                "packagingKind": draft.packagingKind.rawValue,
                "stockWeightConfirmed": draft.stockWeightConfirmed ? "1" : "0",
                "note": draft.note,
                "isActive": draft.isActive ? "1" : "0",
            ]
            payload.optionalStrings = [
                "purchasedKilogramsText": draft.purchasedKilogramsText,
                "initialKilogramsText": draft.initialKilogramsText,
                "remainingKilogramsText": draft.remainingKilogramsText,
                "packageCountText": draft.packageCountText,
                "nominalPackageKilogramsText": draft.nominalPackageKilogramsText,
            ]
            payload.optionalDates = ["purchaseDate": draft.purchaseDate]
        case .adjustFeedStock(let batchID, let kind, let quantityText, let occurredAt, let note):
            payload.identifiers = ["batchID": batchID]
            payload.strings = ["kind": kind.rawValue, "quantityText": quantityText, "note": note]
            payload.dates = ["occurredAt": occurredAt]
        case .countFeedStock(let countID, let batchID, let actualKilogramsText, let method, let occurredAt, let note):
            payload.identifiers = ["countID": countID, "batchID": batchID]
            payload.strings = ["method": method.rawValue, "note": note]
            payload.optionalStrings = ["actualKilogramsText": actualKilogramsText]
            payload.dates = ["occurredAt": occurredAt]
        case .saveFeedRecipe(let draft):
            if let id = draft.id { payload.identifiers["recipeID"] = id }
            payload.optionalIdentifiers = ["targetPenID": draft.targetPenID]
            payload.strings = [
                "name": draft.name,
                "stage": draft.stage.rawValue,
                "note": draft.note,
            ]
            payload.optionalStrings = ["targetPenName": draft.targetPenName]
            if let headCount = draft.headCount { payload.integers["headCount"] = headCount }
            payload.recipeComponents = draft.components.map {
                .init(id: $0.id, ingredientID: $0.ingredientID, ingredientBatchID: $0.ingredientBatchID, kilogramsText: $0.kilogramsText, legacyBatchID: nil, pricePerKilogramText: $0.pricePerKilogramText, nutrientSnapshotJSON: $0.nutrientSnapshotJSON)
            }
        case .recordFeedV2(let draft):
            payload.identifiers = ["feedID": draft.id, "penID": draft.penID]
            payload.optionalIdentifiers = ["recipeID": draft.recipeID]
            payload.strings = [
                "mode": draft.mode.rawValue,
                "mealName": draft.mealName,
                "feederName": draft.feederName,
                "note": draft.note,
            ]
            payload.optionalStrings = [
                "remainingKilogramsText": draft.remainingKilogramsText,
                "discardedKilogramsText": draft.discardedKilogramsText,
                "remainingCompositionJSON": draft.remainingCompositionJSON,
                "scaleFactorText": draft.scaleFactorText,
                "excludedSheepIDsJSON": FeedExcludedSheepCodec.encode(draft.excludedSheepIDs),
            ]
            payload.dates = ["occurredAt": draft.occurredAt]
            if let value = draft.recipeHeadCountSnapshot { payload.integers["recipeHeadCountSnapshot"] = value }
            if let value = draft.actualHeadCountSnapshot { payload.integers["actualHeadCountSnapshot"] = value }
            payload.feedLines = resolvedFeedLines ?? draft.lines.map {
                .init(id: $0.id, ingredientID: $0.ingredientID, kilogramsText: $0.kilogramsText, ingredientBatchID: $0.ingredientBatchID)
            }
        case .recordFeedTroughObservation(let draft):
            payload.identifiers = ["observationID": draft.id, "penID": draft.penID]
            payload.optionalIdentifiers = ["relatedFeedRecordID": draft.relatedFeedRecordID]
            payload.strings = [
                "feederName": draft.feederName,
                "actualRemainingKilogramsText": draft.actualRemainingKilogramsText,
                "measurementMethod": draft.measurementMethod.rawValue,
                "note": draft.note,
            ]
            payload.optionalStrings = [
                "discardedKilogramsText": draft.discardedKilogramsText,
                "compositionSnapshotJSON": draft.compositionSnapshotJSON,
            ]
            payload.dates = ["observedAt": draft.observedAt]
        case .importHistoricalFeed(let draft):
            payload.identifiers = ["feedID": draft.id, "penID": draft.penID]
            payload.strings = ["mode": draft.mode.rawValue, "mealName": draft.mealName, "feederName": draft.feederName, "legacySourceKey": draft.legacySourceKey, "note": draft.note]
            payload.optionalStrings = ["remainingKilogramsText": draft.remainingKilogramsText, "discardedKilogramsText": draft.discardedKilogramsText, "remainingCompositionJSON": draft.remainingCompositionJSON]
            payload.dates = ["occurredAt": draft.occurredAt]
            payload.feedLines = draft.lines.map {
                .init(id: $0.id, ingredientID: $0.ingredientID, kilogramsText: $0.kilogramsText, ingredientNameSnapshot: $0.ingredientNameSnapshot, ingredientBatchNameSnapshot: $0.ingredientBatchNameSnapshot, pricePerKilogramTextSnapshot: $0.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: $0.nutrientSnapshotJSON, unitSnapshot: $0.unitSnapshot, dryMatterTextSnapshot: $0.dryMatterTextSnapshot)
            }
        case .recordHealth(let sheepID, let penID, let kind, let itemName, let occurredAt, let note, let inventoryLotID, let quantityText):
            payload.optionalIdentifiers = ["sheepID": sheepID, "penID": penID, "inventoryLotID": inventoryLotID]
            payload.strings = ["kind": kind.rawValue, "itemName": itemName, "note": note]
            payload.optionalStrings = ["quantityText": quantityText]
            payload.dates = ["occurredAt": occurredAt]
        case .receiveInventory(let catalogName, let kind, let expiresAt, let quantityText, let occurredAt, let note):
            payload.strings = ["catalogName": catalogName, "kind": kind.rawValue, "quantityText": quantityText, "note": note]
            payload.optionalDates = ["expiresAt": expiresAt]
            payload.dates = ["occurredAt": occurredAt]
        case .addSemen(let code, let breed, let source, let batchNumber, let quantityText):
            payload.strings = ["code": code, "breed": breed, "source": source, "batchNumber": batchNumber, "quantityText": quantityText]
        case .recordReproduction(let eweID, let kind, let occurredAt, let sireID, let semenName, let result, let lambCount, let parity, let birthDeadCount, let offspring, let note):
            payload.identifiers = ["eweID": eweID]
            payload.optionalIdentifiers = ["sireID": sireID]
            payload.optionalStrings = ["semenName": semenName]
            payload.strings = ["kind": kind.rawValue, "result": result, "note": note]
            payload.integers = ["lambCount": lambCount]
            if let parity { payload.integers["parity"] = parity }
            if let birthDeadCount { payload.integers["birthDeadCount"] = birthDeadCount }
            payload.lambingOffspring = offspring.map {
                .init(id: $0.id, sheepID: $0.sheepID, earTag: $0.earTag, sexRawValue: $0.sex.rawValue, birthWeightText: $0.birthWeightText)
            }
            payload.dates = ["occurredAt": occurredAt]
        case .addNote(let sheepID, let penID, let text, let occurredAt):
            payload.optionalIdentifiers = ["sheepID": sheepID, "penID": penID]
            payload.strings = ["text": text]
            payload.dates = ["occurredAt": occurredAt]
        case .tombstoneEntity(let entityType, let entityID, let reason):
            payload.strings = ["entityType": entityType.rawValue, "reason": reason]
            payload.identifiers = ["entityID": entityID]
            payload.dates = ["deletedAt": .now]
        case .restoreTombstonedEntity(let tombstoneID):
            payload.identifiers = ["tombstoneID": tombstoneID]
        }
        if case .updateSheepProfile = command,
           let sheepAvatarUpdate {
            SheepAvatarCloudPayload.write(sheepAvatarUpdate, to: &payload)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    static func encodeTMRBaseline(_ snapshot: FarmTMRBackupPayload) throws -> Data {
        var payload = FarmCommandCloudPayload(kind: .restoreTMRBaseline)
        payload.tmrBaselineSnapshot = snapshot
        payload.integers[TMRCloudDataProtocol.field] = TMRCloudDataProtocol.currentVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func stableDecimalText(_ value: String?) -> String? {
        value.flatMap {
            Decimal.stable($0.trimmingCharacters(in: .whitespacesAndNewlines))?.stableText
        }
    }
}
