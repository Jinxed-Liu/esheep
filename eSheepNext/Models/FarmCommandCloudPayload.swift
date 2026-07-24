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
    var breedingProgramSteps: [BreedingProgramStep] = []
    var lambingOffspring: [LambingOffspring] = []
    var careCommand: CareCommand?
}

enum FarmCommandCloudPayloadEncoder {
    static func encode(_ command: FarmCommand, resolvedFeedLines: [FarmCommandCloudPayload.FeedLine]? = nil) throws -> Data {
        var payload = FarmCommandCloudPayload(kind: command.operationKind)
        switch command {
        case .care(let careCommand):
            payload.careCommand = careCommand
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
        case .addSheep(let earTag, let breed, let sex, let penID, let occurredAt, let birthAt, let note):
            payload.strings = ["earTag": earTag, "breed": breed, "sex": sex.rawValue, "note": note]
            payload.optionalIdentifiers = ["penID": penID]
            payload.dates = ["occurredAt": occurredAt]
            payload.optionalDates = ["birthAt": birthAt]
        case .updateSheepProfile(let sheepID, let earTag, let breed, let sex, let birthAt, let note):
            payload.identifiers = ["sheepID": sheepID]
            payload.strings = ["earTag": earTag, "breed": breed, "sex": sex.rawValue, "note": note]
            payload.optionalDates = ["birthAt": birthAt]
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
