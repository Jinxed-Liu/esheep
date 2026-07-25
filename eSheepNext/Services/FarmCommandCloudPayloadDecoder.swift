import Foundation

enum FarmCommandCloudPayloadDecodingError: LocalizedError {
    case unsupportedKind(DomainOperationKind)
    case missingValue(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedKind(let kind):
            "不支持从 AI 草案执行 \(kind.rawValue) 操作。"
        case .missingValue(let field):
            "AI 草案缺少必填字段：\(field)。"
        case .invalidValue(let field):
            "AI 草案字段无效：\(field)。"
        }
    }
}

/// The inverse of `FarmCommandCloudPayloadEncoder` used only after an AI
/// proposal has passed the local allowlist, farm-scope, capability and revision
/// checks. The model never supplies a `FarmCommand` directly.
enum FarmCommandCloudPayloadDecoder {
    static func decode(_ data: Data) throws -> FarmCommand {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decode(decoder.decode(FarmCommandCloudPayload.self, from: data))
    }

    static func decode(_ payload: FarmCommandCloudPayload) throws -> FarmCommand {
        switch payload.kind {
        case .updateFarmLocation:
            return .updateFarmLocation(
                displayName: try string("displayName", in: payload),
                latitude: try double("latitude", in: payload),
                longitude: try double("longitude", in: payload),
                addressSnapshot: optionalString("addressSnapshot", in: payload),
                timeZoneIdentifier: try string("timeZoneIdentifier", in: payload),
                source: try rawValue(
                    FarmLocationSource.self,
                    field: "source",
                    value: try string("source", in: payload)
                ),
                horizontalAccuracyMeters: try optionalDouble(
                    "horizontalAccuracyMeters",
                    in: payload
                )
            )
        case .createPen:
            return .createPen(
                name: try string("name", in: payload),
                note: try string("note", in: payload)
            )
        case .updatePen:
            return .updatePen(
                penID: try identifier("penID", in: payload),
                name: try string("name", in: payload),
                note: try string("note", in: payload)
            )
        case .setPenActive:
            return .setPenActive(
                penID: try identifier("penID", in: payload),
                isActive: try integer("isActive", in: payload) != 0
            )
        case .addSheep:
            return .addSheep(
                earTag: try string("earTag", in: payload),
                breed: try string("breed", in: payload),
                sex: try rawValue(
                    SheepSex.self,
                    field: "sex",
                    value: try string("sex", in: payload)
                ),
                penID: optionalIdentifier("penID", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                birthAt: optionalDate("birthAt", in: payload),
                note: try string("note", in: payload)
            )
        case .updateSheepProfile:
            return .updateSheepProfile(
                sheepID: try identifier("sheepID", in: payload),
                earTag: try string("earTag", in: payload),
                breed: try string("breed", in: payload),
                sex: try rawValue(
                    SheepSex.self,
                    field: "sex",
                    value: try string("sex", in: payload)
                ),
                birthAt: optionalDate("birthAt", in: payload),
                note: try string("note", in: payload)
            )
        case .recordWeight:
            return .recordWeight(
                sheepID: try identifier("sheepID", in: payload),
                kilogramsText: try string("kilogramsText", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                note: try string("note", in: payload)
            )
        case .correctWeight:
            return .correctWeight(
                originalID: try identifier("originalID", in: payload),
                kilogramsText: try string("kilogramsText", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                note: try string("note", in: payload),
                reason: try string("reason", in: payload)
            )
        case .recordWeaning:
            return .recordWeaning(
                sheepID: try identifier("sheepID", in: payload),
                weanWeightText: try string("weanWeightText", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                birthAt: optionalDate("birthAt", in: payload),
                birthWeightText: optionalString("birthWeightText", in: payload),
                averageDailyGainText: optionalString("averageDailyGainText", in: payload),
                damID: optionalIdentifier("damID", in: payload),
                litterSize: payload.integers["litterSize"],
                note: try string("note", in: payload)
            )
        case .createBreedingProgram:
            return .createBreedingProgram(
                name: try string("name", in: payload),
                createdAt: try date("createdAt", in: payload),
                steps: payload.breedingProgramSteps
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map {
                        BreedingProgramStepDraft(
                            id: $0.id,
                            dayOffset: $0.dayOffset,
                            action: $0.action
                        )
                    }
            )
        case .transferSheep:
            return .transferSheep(
                sheepID: try identifier("sheepID", in: payload),
                toPenID: optionalIdentifier("toPenID", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                note: try string("note", in: payload)
            )
        case .correctTransfer:
            return .correctTransfer(
                originalID: try identifier("originalID", in: payload),
                toPenID: optionalIdentifier("toPenID", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                note: try string("note", in: payload),
                reason: try string("reason", in: payload)
            )
        case .removeSheep:
            return .removeSheep(
                sheepID: try identifier("sheepID", in: payload),
                kind: try rawValue(
                    RemovalKind.self,
                    field: "kind",
                    value: try string("kind", in: payload)
                ),
                reason: try string("reason", in: payload),
                amountText: optionalString("amountText", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                note: try string("note", in: payload),
                removalBatchID: optionalIdentifier("removalBatchID", in: payload),
                batchTotalAmountText: optionalString("batchTotalAmountText", in: payload)
            )
        case .correctRemoval:
            return .correctRemoval(
                originalID: try identifier("originalID", in: payload),
                kind: try rawValue(
                    RemovalKind.self,
                    field: "kind",
                    value: try string("kind", in: payload)
                ),
                reason: try string("reason", in: payload),
                amountText: optionalString("amountText", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                note: try string("note", in: payload),
                correctionReason: try string("correctionReason", in: payload)
            )
        case .restoreSheep:
            return .restoreSheep(removalID: try identifier("removalID", in: payload))
        case .createBatch:
            let sheepIDs = try string("sheepIDs", in: payload)
                .split(separator: ",")
                .map {
                    guard let value = UUID(uuidString: String($0)) else {
                        throw FarmCommandCloudPayloadDecodingError.invalidValue("sheepIDs")
                    }
                    return value
                }
            return .createBatch(
                name: try string("name", in: payload),
                purpose: try string("purpose", in: payload),
                startedAt: try date("startedAt", in: payload),
                sheepIDs: sheepIDs,
                note: try string("note", in: payload)
            )
        case .assignBatchMembership:
            return .assignSheepToBatch(
                batchID: try identifier("batchID", in: payload),
                sheepID: try identifier("sheepID", in: payload),
                joinedAt: try date("joinedAt", in: payload)
            )
        case .leaveBatchMembership:
            return .leaveBatch(
                batchID: try identifier("batchID", in: payload),
                sheepID: try identifier("sheepID", in: payload),
                leftAt: try date("leftAt", in: payload),
                reason: try string("reason", in: payload)
            )
        case .addIngredient:
            return .addIngredient(
                name: try string("name", in: payload),
                unit: try string("unit", in: payload),
                dryMatterText: optionalString("dryMatterText", in: payload)
            )
        case .createRecipe:
            return .createRecipe(
                name: try string("name", in: payload),
                note: try string("note", in: payload)
            )
        case .addRecipeComponent:
            return .addRecipeComponent(
                recipeID: try identifier("recipeID", in: payload),
                ingredientID: try identifier("ingredientID", in: payload),
                kilogramsText: try string("kilogramsText", in: payload)
            )
        case .recordFeed:
            return .recordFeed(
                penID: try identifier("penID", in: payload),
                recipeID: optionalIdentifier("recipeID", in: payload),
                mode: try rawValue(
                    FeedMode.self,
                    field: "mode",
                    value: try string("mode", in: payload)
                ),
                occurredAt: try date("occurredAt", in: payload),
                lines: payload.feedLines.map {
                    FeedLineDraft(
                        id: $0.id,
                        ingredientID: $0.ingredientID,
                        ingredientBatchID: $0.ingredientBatchID,
                        kilogramsText: $0.kilogramsText
                    )
                },
                note: try string("note", in: payload)
            )
        case .recordHealth:
            return .recordHealth(
                sheepID: optionalIdentifier("sheepID", in: payload),
                penID: optionalIdentifier("penID", in: payload),
                kind: try rawValue(
                    HealthRecordKind.self,
                    field: "kind",
                    value: try string("kind", in: payload)
                ),
                itemName: try string("itemName", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                note: try string("note", in: payload),
                inventoryLotID: optionalIdentifier("inventoryLotID", in: payload),
                quantityText: optionalString("quantityText", in: payload)
            )
        case .receiveInventory:
            return .receiveInventory(
                catalogName: try string("catalogName", in: payload),
                kind: try rawValue(
                    HealthRecordKind.self,
                    field: "kind",
                    value: try string("kind", in: payload)
                ),
                expiresAt: optionalDate("expiresAt", in: payload),
                quantityText: try string("quantityText", in: payload),
                occurredAt: try date("occurredAt", in: payload),
                note: try string("note", in: payload)
            )
        case .addSemen:
            return .addSemen(
                code: try string("code", in: payload),
                breed: try string("breed", in: payload),
                source: try string("source", in: payload),
                batchNumber: try string("batchNumber", in: payload),
                quantityText: try string("quantityText", in: payload)
            )
        case .recordReproduction:
            return .recordReproduction(
                eweID: try identifier("eweID", in: payload),
                kind: try rawValue(
                    ReproductionRecordKind.self,
                    field: "kind",
                    value: try string("kind", in: payload)
                ),
                occurredAt: try date("occurredAt", in: payload),
                sireID: optionalIdentifier("sireID", in: payload),
                semenName: optionalString("semenName", in: payload),
                result: try string("result", in: payload),
                lambCount: try integer("lambCount", in: payload),
                parity: payload.integers["parity"],
                birthDeadCount: payload.integers["birthDeadCount"],
                offspring: try payload.lambingOffspring.map {
                    LambingOffspringDraft(
                        id: $0.id,
                        sheepID: $0.sheepID,
                        earTag: $0.earTag,
                        sex: try rawValue(
                            LambSex.self,
                            field: "lambingOffspring.sexRawValue",
                            value: $0.sexRawValue
                        ),
                        birthWeightText: $0.birthWeightText
                    )
                },
                note: try string("note", in: payload)
            )
        case .care:
            guard let careCommand = payload.careCommand else {
                throw FarmCommandCloudPayloadDecodingError.missingValue("careCommand")
            }
            return .care(careCommand)
        case .addNote:
            return .addNote(
                sheepID: optionalIdentifier("sheepID", in: payload),
                penID: optionalIdentifier("penID", in: payload),
                text: try string("text", in: payload),
                occurredAt: try date("occurredAt", in: payload)
            )
        case .tombstoneEntity:
            return .tombstoneEntity(
                entityType: try rawValue(
                    CloudEntityType.self,
                    field: "entityType",
                    value: try string("entityType", in: payload)
                ),
                entityID: try identifier("entityID", in: payload),
                reason: try string("reason", in: payload)
            )
        case .restoreTombstonedEntity:
            return .restoreTombstonedEntity(
                tombstoneID: try identifier("tombstoneID", in: payload)
            )
        case .createFarm, .resolveConflict, .recoverEntity, .bootstrapEntity:
            throw FarmCommandCloudPayloadDecodingError.unsupportedKind(payload.kind)
        }
    }

    private static func string(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) throws -> String {
        guard let value = payload.strings[field] else {
            throw FarmCommandCloudPayloadDecodingError.missingValue(field)
        }
        return value
    }

    private static func optionalString(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) -> String? {
        payload.optionalStrings[field] ?? nil
    }

    private static func identifier(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) throws -> UUID {
        guard let value = payload.identifiers[field] else {
            throw FarmCommandCloudPayloadDecodingError.missingValue(field)
        }
        return value
    }

    private static func optionalIdentifier(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) -> UUID? {
        payload.optionalIdentifiers[field] ?? nil
    }

    private static func date(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) throws -> Date {
        guard let value = payload.dates[field] else {
            throw FarmCommandCloudPayloadDecodingError.missingValue(field)
        }
        return value
    }

    private static func optionalDate(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) -> Date? {
        payload.optionalDates[field] ?? nil
    }

    private static func integer(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) throws -> Int {
        guard let value = payload.integers[field] else {
            throw FarmCommandCloudPayloadDecodingError.missingValue(field)
        }
        return value
    }

    private static func double(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) throws -> Double {
        guard let value = Double(try string(field, in: payload)), value.isFinite else {
            throw FarmCommandCloudPayloadDecodingError.invalidValue(field)
        }
        return value
    }

    private static func optionalDouble(
        _ field: String,
        in payload: FarmCommandCloudPayload
    ) throws -> Double? {
        guard let text = optionalString(field, in: payload) else { return nil }
        guard let value = Double(text), value.isFinite else {
            throw FarmCommandCloudPayloadDecodingError.invalidValue(field)
        }
        return value
    }

    private static func rawValue<Value: RawRepresentable>(
        _ type: Value.Type,
        field: String,
        value: String
    ) throws -> Value where Value.RawValue == String {
        guard let result = Value(rawValue: value) else {
            throw FarmCommandCloudPayloadDecodingError.invalidValue(field)
        }
        return result
    }
}
