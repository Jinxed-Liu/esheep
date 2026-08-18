import Foundation
import SwiftData

enum ConflictResolutionError: LocalizedError {
    case conflictMissing
    case alreadyResolved
    case localPayloadMissing
    case unsupportedBusinessMerge
    case invalidResolvedPayload

    var errorDescription: String? {
        switch self {
        case .conflictMissing: "冲突记录不存在。"
        case .alreadyResolved: "该冲突已经处理。"
        case .localPayloadMissing: "冲突缺少可用的本地版本。"
        case .unsupportedBusinessMerge: "库存、繁殖或批次冲突必须通过补偿业务操作处理，不能直接覆盖。"
        case .invalidResolvedPayload: "选定版本无法通过业务校验。"
        }
    }
}

enum ConflictDomainMergeService {
    static func apply(payload data: Data, entityType: String, entityID: UUID, farmID: UUID, revision: Int, context: ModelContext) throws -> Date? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(FarmCommandCloudPayload.self, from: data)
        switch payload.kind {
        case .createPen:
            guard entityType == CloudEntityType.pen.rawValue,
                  let value = try context.fetch(FetchDescriptor<PenRecord>()).first(where: { $0.id == entityID && $0.farmID == farmID }),
                  let name = payload.strings["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw ConflictResolutionError.invalidResolvedPayload }
            value.name = name
            value.note = payload.strings["note"] ?? ""
            value.revision = revision
            value.updatedAt = .now
            return nil
        case .updatePen:
            guard entityType == CloudEntityType.pen.rawValue,
                  payload.identifiers["penID"] == entityID,
                  let value = try context.fetch(FetchDescriptor<PenRecord>()).first(where: { $0.id == entityID && $0.farmID == farmID }),
                  let name = payload.strings["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw ConflictResolutionError.invalidResolvedPayload }
            value.name = name
            value.note = payload.strings["note"] ?? ""
            value.revision = revision
            value.updatedAt = .now
            return nil
        case .addSheep:
            guard entityType == CloudEntityType.sheep.rawValue,
                  let value = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.id == entityID && $0.farmID == farmID }),
                  let earTag = payload.strings["earTag"], let breed = payload.strings["breed"] else { throw ConflictResolutionError.invalidResolvedPayload }
            let normalized = EarTag.normalized(earTag)
            let all = try context.fetch(FetchDescriptor<SheepRecord>())
            guard !all.contains(where: { $0.farmID == farmID && $0.id != entityID && EarTag.normalized($0.earTag) == normalized }) else { throw FarmCommandError.duplicateEarTag }
            value.earTag = earTag.trimmingCharacters(in: .whitespacesAndNewlines)
            value.breed = breed.trimmingCharacters(in: .whitespacesAndNewlines)
            value.sexRawValue = payload.strings["sex"] ?? value.sexRawValue
            value.currentPenID = payload.optionalIdentifiers["penID"] ?? nil
            value.initialPenID = payload.optionalIdentifiers["penID"] ?? nil
            value.enteredAt = payload.dates["occurredAt"] ?? value.enteredAt
            value.birthAt = payload.optionalDates["birthAt"] ?? nil
            value.note = payload.strings["note"] ?? ""
            value.revision = revision
            value.updatedAt = .now
            if let currentParity = payload.integers["currentParity"], currentParity >= 0, value.sex == .ewe {
                let parityID = LambingEntrySemantics.entryParityBaselineID(sheepID: value.id)
                if let baseline = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: { $0.id == parityID && $0.farmID == farmID }) {
                    baseline.parity = currentParity
                    baseline.occurredAt = value.enteredAt
                    baseline.deletedAt = nil
                    baseline.updatedAt = .now
                    baseline.revision += 1
                } else {
                    context.insert(ReproductionRecord(id: parityID, farmID: farmID, eweID: value.id, kind: .parityBaseline, occurredAt: value.enteredAt, parity: currentParity, note: "建档时当前胎次"))
                }
            }
            return value.enteredAt
        case .recordWeight:
            guard entityType == CloudEntityType.weight.rawValue,
                  let value = try context.fetch(FetchDescriptor<WeightRecord>()).first(where: { $0.id == entityID && $0.farmID == farmID }),
                  let kilograms = payload.strings["kilogramsText"], Decimal.stable(kilograms) != nil else { throw ConflictResolutionError.invalidResolvedPayload }
            value.kilogramsText = kilograms
            value.occurredAt = payload.dates["occurredAt"] ?? value.occurredAt
            value.note = payload.strings["note"] ?? ""
            value.revision = revision
            return nil
        case .transferSheep:
            guard entityType == CloudEntityType.transfer.rawValue,
                  let value = try context.fetch(FetchDescriptor<TransferRecord>()).first(where: { $0.id == entityID && $0.farmID == farmID }) else { throw ConflictResolutionError.invalidResolvedPayload }
            value.toPenID = payload.optionalIdentifiers["toPenID"] ?? nil
            value.occurredAt = payload.dates["occurredAt"] ?? value.occurredAt
            value.note = payload.strings["note"] ?? ""
            value.revision = revision
            return value.occurredAt
        case .removeSheep:
            guard entityType == CloudEntityType.removal.rawValue,
                  let value = try context.fetch(FetchDescriptor<RemovalRecord>()).first(where: { $0.id == entityID && $0.farmID == farmID }),
                  let reason = payload.strings["reason"] else { throw ConflictResolutionError.invalidResolvedPayload }
            value.kindRawValue = payload.strings["kind"] ?? value.kindRawValue
            value.reason = reason
            value.amountText = payload.optionalStrings["amountText"] ?? nil
            value.removalBatchID = payload.optionalIdentifiers["removalBatchID"] ?? nil
            value.batchTotalAmountText = payload.optionalStrings["batchTotalAmountText"] ?? nil
            value.occurredAt = payload.dates["occurredAt"] ?? value.occurredAt
            value.note = payload.strings["note"] ?? ""
            value.revision = revision
            return value.occurredAt
        case .addNote:
            guard entityType == CloudEntityType.note.rawValue,
                  let value = try context.fetch(FetchDescriptor<NoteRecord>()).first(where: { $0.id == entityID && $0.farmID == farmID }),
                  let text = payload.strings["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw ConflictResolutionError.invalidResolvedPayload }
            value.text = text
            value.occurredAt = payload.dates["occurredAt"] ?? value.occurredAt
            value.revision = revision
            return nil
        case .recordWeaning, .createBreedingProgram, .receiveInventory, .recordHealth, .recordReproduction, .createBatch, .assignBatchMembership, .leaveBatchMembership:
            throw ConflictResolutionError.unsupportedBusinessMerge
        default:
            throw ConflictResolutionError.unsupportedBusinessMerge
        }
    }

    static func mergedTextPayload(from data: Data, text: String) throws -> Data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var payload = try decoder.decode(FarmCommandCloudPayload.self, from: data)
        guard payload.kind == .addNote else { throw ConflictResolutionError.unsupportedBusinessMerge }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConflictResolutionError.invalidResolvedPayload }
        payload.strings["text"] = trimmed
        return try JSONEncoder.cloud.encode(payload)
    }
}
