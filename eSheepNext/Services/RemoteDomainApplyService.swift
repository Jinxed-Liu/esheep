import CryptoKit
import Foundation
import SwiftData

enum RemoteApplyOutcome: Sendable, Equatable {
    case applied(rebuildHistoryFrom: Date?)
    case duplicate
    case conflict(localRevision: Int)
}

enum RemoteDomainApplyError: LocalizedError {
    case invalidPayload(String)
    case missingReference(String)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let field): "云端命令缺少或无法解析字段：\(field)。"
        case .missingReference(let field): "云端命令引用的本地对象不存在：\(field)。"
        case .unsupportedOperation(let kind): "当前版本不支持云端命令：\(kind)。"
        }
    }
}

struct RemoteDomainApplyService {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func apply(_ envelope: CloudOperationEnvelope, context: ModelContext) throws -> RemoteApplyOutcome {
        let payload = try decoder.decode(FarmCommandCloudPayload.self, from: envelope.payload)
        if let expected = expectedEntityType(for: payload.kind), expected.rawValue != envelope.entityType {
            throw RemoteDomainApplyError.invalidPayload("kind")
        }

        switch payload.kind {
        case .care:
            guard let command = payload.careCommand else { throw RemoteDomainApplyError.invalidPayload("careCommand") }
            if try FarmCareCommandHandler.isApplied(command, farmID: envelope.farmID, context: context) { return .duplicate }
            try FarmCareCommandHandler.validate(command, farmID: envelope.farmID, context: context)
            let result = try FarmCareCommandHandler.apply(command, farmID: envelope.farmID, accountID: envelope.modifiedByAccountID, context: context, modifiedAt: envelope.modifiedAt)
            guard result.entityType.rawValue == envelope.entityType, result.entityID == envelope.entityID else { throw RemoteDomainApplyError.invalidPayload("careCommand.target") }
            return .applied(rebuildHistoryFrom: command.rebuildHistoryFrom)
        case .createFarm:
            return .duplicate
        case .updateFarmLocation:
            guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == envelope.farmID && $0.deletedAt == nil }) else {
                throw RemoteDomainApplyError.missingReference("farmID")
            }
            let localRevision = try context.fetch(FetchDescriptor<DomainOperation>())
                .filter { $0.farmID == envelope.farmID && $0.entityID == farm.id }
                .map(\.resultingRevision)
                .max() ?? 1
            guard localRevision == envelope.baseRevision else { return .conflict(localRevision: localRevision) }
            guard let latitude = Double(try string("latitude", payload)),
                  let longitude = Double(try string("longitude", payload)),
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  let source = FarmLocationSource(rawValue: try string("source", payload)) else {
                throw RemoteDomainApplyError.invalidPayload("location")
            }
            let timeZoneIdentifier = try string("timeZoneIdentifier", payload)
            guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw RemoteDomainApplyError.invalidPayload("timeZoneIdentifier") }
            farm.locationDisplayName = try string("displayName", payload)
            farm.latitude = latitude
            farm.longitude = longitude
            farm.coordinateReferenceSystem = "wgs84"
            farm.addressSnapshot = optionalString("addressSnapshot", payload)
            farm.timeZoneIdentifier = timeZoneIdentifier
            farm.locationSourceRawValue = source.rawValue
            farm.horizontalAccuracyMeters = optionalString("horizontalAccuracyMeters", payload).flatMap(Double.init)
            farm.locationUpdatedAt = envelope.modifiedAt
            farm.updatedAt = envelope.modifiedAt
            return .applied(rebuildHistoryFrom: nil)
        case .createPen:
            if try exists(PenRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(PenRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), note: payload.strings["note"] ?? "", createdAt: envelope.modifiedAt))
            return .applied(rebuildHistoryFrom: nil)
        case .updatePen:
            guard let record = try fetch(PenRecord.self, id: try identifier("penID", payload), context: context) else { throw RemoteDomainApplyError.missingReference("penID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            record.name = try string("name", payload)
            record.note = payload.strings["note"] ?? ""
            record.updatedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: nil)
        case .setPenActive:
            guard let record = try fetch(PenRecord.self, id: try identifier("penID", payload), context: context) else { throw RemoteDomainApplyError.missingReference("penID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            record.isActive = payload.integers["isActive"] == 1
            record.updatedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: nil)
        case .addSheep:
            if try exists(SheepRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let normalizedEarTag = EarTag.normalized(try string("earTag", payload))
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            if sheep.contains(where: {
                $0.farmID == envelope.farmID &&
                $0.id != envelope.entityID &&
                EarTag.normalized($0.earTag) == normalizedEarTag
            }) {
                return .conflict(localRevision: 0)
            }
            let record = SheepRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                earTag: try string("earTag", payload),
                legacyEarTag: optionalString("legacyEarTag", payload),
                legacySourceKey: optionalString("legacySourceKey", payload),
                isHistoricalArchive: payload.integers["isHistoricalArchive"] == 1,
                breed: try string("breed", payload),
                purpose: payload.strings["purpose"] ?? "未分类",
                sex: SheepSex(rawValue: try string("sex", payload)) ?? .unknown,
                penID: optionalID("penID", payload),
                enteredAt: try date("occurredAt", payload),
                birthAt: optionalDate("birthAt", payload),
                damID: optionalID("damID", payload),
                sireID: optionalID("sireID", payload),
                note: payload.strings["note"] ?? ""
            )
            context.insert(record)
            return .applied(rebuildHistoryFrom: record.enteredAt)
        case .updateSheepProfile:
            guard let record = try fetch(SheepRecord.self, id: try identifier("sheepID", payload), context: context) else { throw RemoteDomainApplyError.missingReference("sheepID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            let earTag = try string("earTag", payload)
            let normalized = EarTag.normalized(earTag)
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            guard !sheep.contains(where: { $0.farmID == envelope.farmID && $0.id != record.id && EarTag.normalized($0.earTag) == normalized }) else {
                return .conflict(localRevision: record.revision)
            }
            record.earTag = earTag
            record.breed = try string("breed", payload)
            record.sexRawValue = try string("sex", payload)
            record.birthAt = optionalDate("birthAt", payload)
            record.note = payload.strings["note"] ?? ""
            record.updatedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: nil)
        case .recordWeight:
            if try exists(WeightRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(WeightRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: try identifier("sheepID", payload), kilogramsText: try string("kilogramsText", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""))
            return .applied(rebuildHistoryFrom: nil)
        case .correctWeight:
            if try exists(WeightRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(WeightRecord.self, id: originalID, context: context), original.deletedAt == nil else { throw RemoteDomainApplyError.missingReference("originalID") }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.weight.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["reason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            context.insert(WeightRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: original.sheepID, kilogramsText: try string("kilogramsText", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""))
            return .applied(rebuildHistoryFrom: nil)
        case .recordWeaning:
            if try exists(WeaningRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(WeaningRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                sheepID: try identifier("sheepID", payload),
                occurredAt: try date("occurredAt", payload),
                weanWeightText: try string("weanWeightText", payload),
                birthAt: optionalDate("birthAt", payload),
                birthWeightText: optionalString("birthWeightText", payload),
                averageDailyGainText: optionalString("averageDailyGainText", payload),
                damID: optionalID("damID", payload),
                litterSize: payload.integers["litterSize"],
                note: payload.strings["note"] ?? ""
            ))
            return .applied(rebuildHistoryFrom: nil)
        case .createBreedingProgram:
            if try exists(BreedingProgramRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            guard !payload.breedingProgramSteps.isEmpty else { throw RemoteDomainApplyError.invalidPayload("breedingProgramSteps") }
            let createdAt = try date("createdAt", payload)
            context.insert(BreedingProgramRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), createdAt: createdAt))
            for step in payload.breedingProgramSteps.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                guard step.dayOffset >= 0, !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RemoteDomainApplyError.invalidPayload("breedingProgramSteps")
                }
                context.insert(BreedingProgramStepRecord(id: step.id, farmID: envelope.farmID, programID: envelope.entityID, dayOffset: step.dayOffset, action: step.action, sortOrder: step.sortOrder, createdAt: createdAt))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .transferSheep:
            if try exists(TransferRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let sheepID = try identifier("sheepID", payload)
            guard let sheep = try fetch(SheepRecord.self, id: sheepID, context: context) else { throw RemoteDomainApplyError.missingReference("sheepID") }
            let occurredAt = try date("occurredAt", payload)
            let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == envelope.farmID && $0.sheepID == sheepID && $0.deletedAt == nil }
            let record = TransferRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: sheepID, fromPenID: FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers), toPenID: optionalID("toPenID", payload), occurredAt: occurredAt, note: payload.strings["note"] ?? "")
            context.insert(record)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .correctTransfer:
            if try exists(TransferRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(TransferRecord.self, id: originalID, context: context), original.deletedAt == nil,
                  let sheep = try fetch(SheepRecord.self, id: original.sheepID, context: context) else { throw RemoteDomainApplyError.missingReference("originalID") }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.transfer.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["reason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            let occurredAt = try date("occurredAt", payload)
            let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == envelope.farmID && $0.sheepID == original.sheepID && $0.deletedAt == nil }
            context.insert(TransferRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: original.sheepID, fromPenID: FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers), toPenID: optionalID("toPenID", payload), occurredAt: occurredAt, note: payload.strings["note"] ?? ""))
            return .applied(rebuildHistoryFrom: occurredAt)
        case .removeSheep:
            if try exists(RemovalRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let occurredAt = try date("occurredAt", payload)
            context.insert(RemovalRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: try identifier("sheepID", payload), kind: RemovalKind(rawValue: try string("kind", payload)) ?? .culled, reason: try string("reason", payload), amountText: optionalString("amountText", payload), occurredAt: occurredAt, note: payload.strings["note"] ?? ""))
            return .applied(rebuildHistoryFrom: occurredAt)
        case .correctRemoval:
            if try exists(RemovalRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(RemovalRecord.self, id: originalID, context: context), original.deletedAt == nil else { throw RemoteDomainApplyError.missingReference("originalID") }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.removal.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["correctionReason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            let occurredAt = try date("occurredAt", payload)
            context.insert(RemovalRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: original.sheepID, kind: RemovalKind(rawValue: try string("kind", payload)) ?? .culled, reason: try string("reason", payload), amountText: optionalString("amountText", payload), occurredAt: occurredAt, note: payload.strings["note"] ?? ""))
            return .applied(rebuildHistoryFrom: occurredAt)
        case .restoreSheep:
            guard let record = try fetch(RemovalRecord.self, id: envelope.entityID, context: context) else { throw RemoteDomainApplyError.missingReference("removalID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            record.deletedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: .distantPast)
        case .createBatch:
            if try exists(ProductionBatchRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(ProductionBatchRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), purpose: try string("purpose", payload), startedAt: try date("startedAt", payload), note: payload.strings["note"] ?? ""))
            return .applied(rebuildHistoryFrom: nil)
        case .assignBatchMembership:
            if try exists(BatchMembershipRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(BatchMembershipRecord(id: envelope.entityID, farmID: envelope.farmID, batchID: try identifier("batchID", payload), sheepID: try identifier("sheepID", payload), joinedAt: try date("joinedAt", payload)))
            return .applied(rebuildHistoryFrom: try date("joinedAt", payload))
        case .leaveBatchMembership:
            guard let record = try fetch(BatchMembershipRecord.self, id: envelope.entityID, context: context) else { throw RemoteDomainApplyError.missingReference("batchMembership") }
            if record.leftAt != nil { return .duplicate }
            record.leftAt = try date("leftAt", payload)
            record.leaveReason = payload.strings["reason"] ?? ""
            record.updatedAt = envelope.modifiedAt
            return .applied(rebuildHistoryFrom: record.leftAt)
        case .addIngredient:
            if try exists(FeedIngredientRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(FeedIngredientRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), unit: try string("unit", payload), dryMatterText: optionalString("dryMatterText", payload)))
            return .applied(rebuildHistoryFrom: nil)
        case .createRecipe:
            if try exists(FeedRecipeRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(FeedRecipeRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), note: payload.strings["note"] ?? ""))
            return .applied(rebuildHistoryFrom: nil)
        case .addRecipeComponent:
            if try exists(FeedRecipeComponentRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(FeedRecipeComponentRecord(id: envelope.entityID, farmID: envelope.farmID, recipeID: try identifier("recipeID", payload), ingredientID: try identifier("ingredientID", payload), kilogramsText: try string("kilogramsText", payload)))
            return .applied(rebuildHistoryFrom: nil)
        case .recordFeed:
            if try exists(FeedRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = FeedRecord(id: envelope.entityID, farmID: envelope.farmID, penID: try identifier("penID", payload), recipeID: optionalID("recipeID", payload), mode: FeedMode(rawValue: try string("mode", payload)) ?? .limited, occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? "")
            context.insert(record)
            let ingredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>())
            for line in payload.feedLines {
                guard let ingredient = ingredients.first(where: { $0.id == line.ingredientID && $0.farmID == envelope.farmID }) else { throw RemoteDomainApplyError.missingReference("ingredientID") }
                context.insert(FeedRecordLine(
                    id: line.id,
                    farmID: envelope.farmID,
                    feedRecordID: record.id,
                    ingredientID: line.ingredientID,
                    kilogramsText: line.kilogramsText,
                    ingredientNameSnapshot: line.ingredientNameSnapshot ?? ingredient.name,
                    ingredientBatchID: line.ingredientBatchID,
                    ingredientBatchNameSnapshot: line.ingredientBatchNameSnapshot,
                    pricePerKilogramTextSnapshot: line.pricePerKilogramTextSnapshot,
                    nutrientSnapshotJSON: line.nutrientSnapshotJSON ?? ingredient.nutrientSnapshotJSON,
                    unitSnapshot: line.unitSnapshot ?? ingredient.unit,
                    dryMatterTextSnapshot: line.dryMatterTextSnapshot ?? ingredient.dryMatterText
                ))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .recordHealth:
            if try exists(HealthRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = HealthRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: optionalID("sheepID", payload), penID: optionalID("penID", payload), kind: HealthRecordKind(rawValue: try string("kind", payload)) ?? .treatment, itemNameSnapshot: try string("itemName", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? "", inventoryLotID: optionalID("inventoryLotID", payload), quantityText: optionalString("quantityText", payload))
            context.insert(record)
            if let inventoryLotID = record.inventoryLotID, let quantity = record.quantityText {
                context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: record.id, name: "inventory-consumption"), farmID: envelope.farmID, inventoryLotID: inventoryLotID, kind: .consumption, quantityText: quantity, occurredAt: record.occurredAt, sourceRecordID: record.id, note: record.itemNameSnapshot))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .receiveInventory:
            if try exists(InventoryLotRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let lot = InventoryLotRecord(id: envelope.entityID, farmID: envelope.farmID, catalogName: try string("catalogName", payload), kind: HealthRecordKind(rawValue: try string("kind", payload)) ?? .treatment, expiresAt: optionalDate("expiresAt", payload), startingQuantityText: try string("quantityText", payload))
            context.insert(lot)
            context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: lot.id, name: "inventory-receipt"), farmID: envelope.farmID, inventoryLotID: lot.id, kind: .receipt, quantityText: lot.startingQuantityText, occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""))
            FarmCareCommandHandler.refreshInventoryExpiryReminder(for: lot, context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .addSemen:
            if try exists(SemenRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = SemenRecord(id: envelope.entityID, farmID: envelope.farmID, code: try string("code", payload), breed: try string("breed", payload), source: payload.strings["source"] ?? "", batchNumber: payload.strings["batchNumber"] ?? "", quantityText: "0")
            context.insert(record)
            context.insert(SemenTransactionRecord(id: StableCloudUUID.derived(namespace: record.id, name: "semen-receipt"), farmID: envelope.farmID, semenID: record.id, kind: .receipt, quantityText: try string("quantityText", payload), occurredAt: envelope.modifiedAt, sourceRecordID: record.id, note: "冻精入库"))
            return .applied(rebuildHistoryFrom: nil)
        case .recordReproduction:
            if try exists(ReproductionRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let kind = ReproductionRecordKind(rawValue: try string("kind", payload)) ?? .breeding
            let lambCount = payload.integers["lambCount"] ?? 0
            if kind == .lambing, !payload.lambingOffspring.isEmpty, payload.lambingOffspring.count != lambCount {
                throw RemoteDomainApplyError.invalidPayload("lambingOffspring")
            }
            let record = ReproductionRecord(id: envelope.entityID, farmID: envelope.farmID, eweID: try identifier("eweID", payload), kind: kind, occurredAt: try date("occurredAt", payload), sireID: optionalID("sireID", payload), semenNameSnapshot: optionalString("semenName", payload), result: payload.strings["result"] ?? "", lambCount: lambCount, parity: payload.integers["parity"], birthDeadCount: payload.integers["birthDeadCount"], note: payload.strings["note"] ?? "")
            context.insert(record)
            for detail in payload.lambingOffspring {
                if let sheepID = detail.sheepID, !(try exists(SheepRecord.self, id: sheepID, context: context)) {
                    throw RemoteDomainApplyError.missingReference("lambingOffspring.sheepID")
                }
                context.insert(LambingOffspringRecord(id: detail.id, farmID: envelope.farmID, lambingRecordID: record.id, sheepID: detail.sheepID, legacyEarTag: detail.earTag, sexRawValue: detail.sexRawValue, birthWeightText: detail.birthWeightText))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .addNote:
            if try exists(NoteRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            context.insert(NoteRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: optionalID("sheepID", payload), penID: optionalID("penID", payload), text: try string("text", payload), occurredAt: try date("occurredAt", payload)))
            return .applied(rebuildHistoryFrom: nil)
        case .tombstoneEntity:
            guard let entityTypeText = payload.strings["entityType"], let entityType = CloudEntityType(rawValue: entityTypeText), entityTypeText == envelope.entityType else {
                throw RemoteDomainApplyError.invalidPayload("entityType")
            }
            let entityID = try identifier("entityID", payload)
            guard entityID == envelope.entityID else { throw RemoteDomainApplyError.invalidPayload("entityID") }
            if try context.fetch(FetchDescriptor<TombstoneRecord>()).contains(where: { $0.operationID == envelope.operationID }) { return .duplicate }
            try DomainEntityDeletionService.setDeletedAt(envelope.deletedAt ?? envelope.modifiedAt, type: entityType, id: entityID, farmID: envelope.farmID, context: context)
            context.insert(TombstoneRecord(
                farmID: envelope.farmID,
                entityType: entityType.rawValue,
                entityID: entityID,
                deletedByAccountID: envelope.modifiedByAccountID,
                reason: payload.strings["reason"] ?? "远端删除",
                revision: envelope.revision,
                operationID: envelope.operationID
            ))
            return .applied(rebuildHistoryFrom: .distantPast)
        case .restoreTombstonedEntity:
            let tombstoneID = try identifier("tombstoneID", payload)
            guard let tombstone = try context.fetch(FetchDescriptor<TombstoneRecord>()).first(where: { $0.id == tombstoneID && $0.farmID == envelope.farmID }),
                  let entityType = CloudEntityType(rawValue: tombstone.entityType) else {
                throw RemoteDomainApplyError.missingReference("tombstoneID")
            }
            if tombstone.restoredByOperationID == envelope.operationID { return .duplicate }
            try DomainEntityDeletionService.setDeletedAt(nil, type: entityType, id: tombstone.entityID, farmID: envelope.farmID, context: context)
            tombstone.restoredAt = envelope.modifiedAt
            tombstone.restoredByOperationID = envelope.operationID
            return .applied(rebuildHistoryFrom: .distantPast)
        case .resolveConflict:
            guard let resolvedPayload = payload.dataValues["resolvedPayload"], let entityType = payload.strings["entityType"], entityType == envelope.entityType else {
                throw RemoteDomainApplyError.invalidPayload("resolvedPayload")
            }
            let changedAt = try ConflictDomainMergeService.apply(payload: resolvedPayload, entityType: entityType, entityID: envelope.entityID, farmID: envelope.farmID, revision: envelope.revision, context: context)
            return .applied(rebuildHistoryFrom: changedAt)
        case .recoverEntity:
            guard let sourcePayload = payload.dataValues["resolvedPayload"],
                  let entityType = payload.strings["entityType"],
                  entityType == envelope.entityType,
                  let expectedDigest = payload.strings["sourcePayloadDigest"],
                  CloudPayloadDigest.hex(for: sourcePayload) == expectedDigest else {
                throw RemoteDomainApplyError.invalidPayload("resolvedPayload")
            }
            let sourceEnvelope = CloudOperationEnvelope(
                farmID: envelope.farmID,
                entityID: envelope.entityID,
                entityType: envelope.entityType,
                schemaVersion: envelope.schemaVersion,
                revision: payload.integers["sourceRevision"] ?? envelope.revision,
                baseRevision: max(0, (payload.integers["sourceRevision"] ?? envelope.revision) - 1),
                operationID: StableCloudUUID.derived(namespace: envelope.operationID, name: "checkpoint-source"),
                modifiedAt: envelope.modifiedAt,
                modifiedByAccountID: envelope.modifiedByAccountID,
                modifiedByDeviceID: envelope.modifiedByDeviceID,
                payload: sourcePayload,
                payloadDigest: expectedDigest,
                capabilityCertificate: envelope.capabilityCertificate,
                operationSignature: envelope.operationSignature,
                deletedAt: nil
            )
            return try apply(sourceEnvelope, context: context)
        case .bootstrapEntity:
            guard let snapshotData = payload.dataValues["snapshot"] else {
                throw RemoteDomainApplyError.invalidPayload("snapshot")
            }
            let snapshot = try decoder.decode(BootstrapEntityEnvelopeV1.self, from: snapshotData)
            try snapshot.validate(for: envelope)
            let sourceEnvelope = CloudOperationEnvelope(
                farmID: envelope.farmID,
                entityID: envelope.entityID,
                entityType: envelope.entityType,
                schemaVersion: envelope.schemaVersion,
                revision: snapshot.sourceRevision,
                baseRevision: max(0, snapshot.sourceRevision - 1),
                operationID: StableCloudUUID.derived(namespace: envelope.operationID, name: "migration-bootstrap-source"),
                modifiedAt: envelope.modifiedAt,
                modifiedByAccountID: envelope.modifiedByAccountID,
                modifiedByDeviceID: envelope.modifiedByDeviceID,
                payload: snapshot.sourcePayload,
                payloadDigest: snapshot.sourcePayloadDigest,
                capabilityCertificate: envelope.capabilityCertificate,
                operationSignature: envelope.operationSignature,
                deletedAt: envelope.deletedAt
            )
            return try apply(sourceEnvelope, context: context)
        }
    }

    private func expectedEntityType(for kind: DomainOperationKind) -> CloudEntityType? {
        switch kind {
        case .createFarm: .farm
        case .updateFarmLocation: .farm
        case .createPen, .updatePen, .setPenActive: .pen
        case .addSheep, .updateSheepProfile: .sheep
        case .recordWeight, .correctWeight: .weight
        case .recordWeaning: .weaning
        case .createBreedingProgram: .breedingProgram
        case .transferSheep, .correctTransfer: .transfer
        case .removeSheep, .correctRemoval, .restoreSheep: .removal
        case .createBatch: .productionBatch
        case .assignBatchMembership, .leaveBatchMembership: .batchMembership
        case .addIngredient: .feedIngredient
        case .createRecipe: .feedRecipe
        case .addRecipeComponent: .feedRecipeComponent
        case .recordFeed: .feed
        case .recordHealth: .health
        case .receiveInventory: .inventoryLot
        case .addSemen: .semen
        case .recordReproduction: .reproduction
        case .addNote: .note
        case .care, .tombstoneEntity, .restoreTombstonedEntity, .resolveConflict, .recoverEntity, .bootstrapEntity: nil
        }
    }

    private func string(_ key: String, _ payload: FarmCommandCloudPayload) throws -> String {
        guard let value = payload.strings[key] else { throw RemoteDomainApplyError.invalidPayload(key) }
        return value
    }

    private func optionalString(_ key: String, _ payload: FarmCommandCloudPayload) -> String? {
        payload.optionalStrings[key] ?? nil
    }

    private func identifier(_ key: String, _ payload: FarmCommandCloudPayload) throws -> UUID {
        guard let value = payload.identifiers[key] else { throw RemoteDomainApplyError.invalidPayload(key) }
        return value
    }

    private func optionalID(_ key: String, _ payload: FarmCommandCloudPayload) -> UUID? {
        payload.optionalIdentifiers[key] ?? nil
    }

    private func date(_ key: String, _ payload: FarmCommandCloudPayload) throws -> Date {
        guard let value = payload.dates[key] else { throw RemoteDomainApplyError.invalidPayload(key) }
        return value
    }

    private func optionalDate(_ key: String, _ payload: FarmCommandCloudPayload) -> Date? {
        payload.optionalDates[key] ?? nil
    }

    private func exists<T: PersistentModel>(_ type: T.Type, id: UUID, context: ModelContext) throws -> Bool where T: AnyObject {
        try fetch(type, id: id, context: context) != nil
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, id: UUID, context: ModelContext) throws -> T? where T: AnyObject {
        try context.fetch(FetchDescriptor<T>()).first { record in
            switch record {
            case let value as PenRecord: value.id == id
            case let value as SheepRecord: value.id == id
            case let value as WeightRecord: value.id == id
            case let value as WeaningRecord: value.id == id
            case let value as BreedingProgramRecord: value.id == id
            case let value as TransferRecord: value.id == id
            case let value as RemovalRecord: value.id == id
            case let value as ProductionBatchRecord: value.id == id
            case let value as BatchMembershipRecord: value.id == id
            case let value as FeedIngredientRecord: value.id == id
            case let value as FeedRecipeRecord: value.id == id
            case let value as FeedRecipeComponentRecord: value.id == id
            case let value as FeedRecord: value.id == id
            case let value as InventoryLotRecord: value.id == id
            case let value as HealthRecord: value.id == id
            case let value as ReproductionRecord: value.id == id
            case let value as SemenRecord: value.id == id
            case let value as NoteRecord: value.id == id
            default: false
            }
        }
    }
}

enum StableCloudUUID {
    static func derived(namespace: UUID, name: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace.uuidString.lowercased())\n\(name)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
