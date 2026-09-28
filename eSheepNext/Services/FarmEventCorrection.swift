import Foundation
import SwiftData

struct FarmEventCorrectionDraft: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case weaning, feed, note, inventory, semen, departure, purpose, parity }
    let kind: Kind
    let entityID: UUID
    let sourceEventID: UUID
    var occurredAt: Date
    var text: String
    var value: String
    var withdraw: Bool = false

    var entityType: CloudEntityType {
        switch kind {
        case .weaning: .weaning
        case .feed: .feed
        case .note: .note
        case .inventory: .inventoryTransaction
        case .semen: .semenTransaction
        case .departure: .batchMembership
        case .purpose: .sheep
        case .parity: .reproduction
        }
    }

    static func decode(_ payload: FarmCommandCloudPayload) throws -> Self {
        guard let text = payload.strings["eventCorrectionJSON"], let data = text.data(using: .utf8) else {
            throw FarmCommandError.sourceRecordNotFound
        }
        return try ESheepCloudCanonicalCodec.decode(Self.self, from: data)
    }
}

enum FarmEventCorrection {
    static func validate(_ draft: FarmEventCorrectionDraft, farmID: UUID, context: ModelContext) throws {
        // Apply to the transaction only after all required values and resource balances pass.
        guard draft.occurredAt.timeIntervalSince1970.isFinite,
              draft.kind == .purpose || draft.sourceEventID == draft.entityID else { throw FarmCommandError.sourceRecordNotFound }
        switch draft.kind {
        case .weaning:
            guard let record = try context.fetch(FetchDescriptor<WeaningRecord>()).first(where: { $0.farmID == farmID && $0.id == draft.entityID && $0.deletedAt == nil }),
                  let weight = Decimal.stable(draft.value), weight > 0,
                  record.birthAt.map({ draft.occurredAt > $0 }) ?? true else { throw FarmCommandError.invalidNumber("断奶体重或时间") }
        case .feed:
            guard try context.fetch(FetchDescriptor<FeedRecord>()).contains(where: { $0.farmID == farmID && $0.id == draft.entityID && $0.deletedAt == nil }),
                  !(try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>())).contains(where: { $0.farmID == farmID && $0.feedRecordID == draft.entityID }) else { throw FarmCommandError.sourceRecordNotFound }
        case .note:
            guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  try context.fetch(FetchDescriptor<NoteRecord>()).contains(where: { $0.farmID == farmID && $0.id == draft.entityID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
        case .inventory:
            guard let record = try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).first(where: { $0.farmID == farmID && $0.id == draft.entityID && $0.deletedAt == nil }),
                  record.kind != .consumption, let quantity = Decimal.stable(draft.value), record.kind != .receipt || quantity > 0 else { throw FarmCommandError.invalidNumber("库存数量") }
            let balance = try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).filter { $0.farmID == farmID && $0.inventoryLotID == record.inventoryLotID && $0.deletedAt == nil }
                .reduce(Decimal.zero) { $0 + ($1.kind == .consumption ? -$1.quantity : $1.quantity) }
            guard balance - record.quantity + quantity >= 0 else { throw FarmCommandError.insufficientInventory }
        case .semen:
            guard let record = try context.fetch(FetchDescriptor<SemenTransactionRecord>()).first(where: { $0.farmID == farmID && $0.id == draft.entityID && $0.deletedAt == nil }),
                  record.kind != .consumption, let quantity = Decimal.stable(draft.value), record.kind != .receipt || quantity > 0 else { throw FarmCommandError.invalidNumber("冻精数量") }
            let initialText = try context.fetch(FetchDescriptor<SemenRecord>()).first(where: { $0.farmID == farmID && $0.id == record.semenID })?.quantityText ?? "0"
            let initial = Decimal.stable(initialText) ?? 0
            let balance = try context.fetch(FetchDescriptor<SemenTransactionRecord>()).filter { $0.farmID == farmID && $0.semenID == record.semenID && $0.deletedAt == nil }
                .reduce(initial) { $0 + ($1.kind == .consumption ? -$1.quantity : $1.quantity) }
            guard balance - record.quantity + quantity >= 0 else { throw FarmCommandError.insufficientInventory }
        case .departure:
            guard let record = try context.fetch(FetchDescriptor<BatchMembershipRecord>()).first(where: { $0.farmID == farmID && $0.id == draft.entityID && $0.deletedAt == nil && $0.leftAt != nil }), draft.occurredAt >= record.joinedAt,
                  !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FarmCommandError.batchMembershipNotFound }
        case .purpose:
            let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farmID }
            guard let fact = SheepPurposeTimeline.facts(from: operations).first(where: { $0.id == draft.sourceEventID && $0.sheepID == draft.entityID }),
                  let purpose = SheepPurpose(rawValue: draft.value),
                  let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.farmID == farmID && $0.id == fact.sheepID && $0.deletedAt == nil }), draft.occurredAt >= sheep.enteredAt, purpose.isAllowed(for: sheep.sex), !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FarmCommandError.sourceRecordNotFound }
        case .parity:
            guard let record = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: { $0.farmID == farmID && $0.id == draft.entityID && $0.kind == .parityBaseline && $0.deletedAt == nil }),
                  let parity = Int(draft.value), parity >= 0,
                  let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.id == record.eweID && $0.farmID == farmID }), draft.occurredAt >= sheep.enteredAt else { throw FarmCommandError.sourceRecordNotFound }
        }
        guard !draft.withdraw || draft.kind == .purpose || draft.kind == .parity else { throw FarmCommandError.sourceRecordNotFound }
    }

    static func apply(_ draft: FarmEventCorrectionDraft, farmID: UUID, context: ModelContext) throws {
        try validate(draft, farmID: farmID, context: context)
        switch draft.kind {
        case .weaning:
            let record = try context.fetch(FetchDescriptor<WeaningRecord>()).first { $0.farmID == farmID && $0.id == draft.entityID }!
            record.occurredAt = draft.occurredAt; record.weanWeightText = WeightPrecision.storageText(draft.value); record.note = draft.text; record.revision += 1
            let samples = try context.fetch(FetchDescriptor<WeightRecord>())
            record.averageDailyGainText = WeaningGainSemantics.calculate(sheepID: record.sheepID, birthAt: record.birthAt, weaningAt: draft.occurredAt, weaningWeight: NSDecimalNumber(decimal: record.weanWeight).doubleValue, samples: WeaningGainSemantics.samples(from: samples, farmID: farmID))?.kilogramsPerDayText
        case .feed:
            let record = try context.fetch(FetchDescriptor<FeedRecord>()).first { $0.farmID == farmID && $0.id == draft.entityID }!
            record.occurredAt = draft.occurredAt; record.note = draft.text; record.revision += 1
            for transaction in try context.fetch(FetchDescriptor<FeedStockTransactionRecord>()) where transaction.farmID == farmID && transaction.sourceRecordID == record.id && transaction.deletedAt == nil { transaction.occurredAt = draft.occurredAt }
        case .note:
            let record = try context.fetch(FetchDescriptor<NoteRecord>()).first { $0.farmID == farmID && $0.id == draft.entityID }!
            record.occurredAt = draft.occurredAt; record.text = draft.text; record.revision += 1
        case .inventory:
            let record = try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).first { $0.farmID == farmID && $0.id == draft.entityID }!
            record.occurredAt = draft.occurredAt; record.note = draft.text; record.quantityText = Decimal.stable(draft.value)!.stableText
        case .semen:
            let record = try context.fetch(FetchDescriptor<SemenTransactionRecord>()).first { $0.farmID == farmID && $0.id == draft.entityID }!
            record.occurredAt = draft.occurredAt; record.note = draft.text; record.quantityText = Decimal.stable(draft.value)!.stableText
        case .departure:
            let record = try context.fetch(FetchDescriptor<BatchMembershipRecord>()).first { $0.farmID == farmID && $0.id == draft.entityID }!
            record.leftAt = draft.occurredAt; record.leaveReason = draft.text; record.updatedAt = .now
            try ProductionBatchLifecycle.reconcile(batchID: record.batchID, farmID: farmID, context: context)
        case .purpose:
            // The correction operation is folded into the immutable purpose timeline.
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).first { $0.farmID == farmID && $0.id == draft.entityID }!
            sheep.revision += 1; sheep.updatedAt = .now
        case .parity:
            let record = try context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.farmID == farmID && $0.id == draft.entityID }!
            if draft.withdraw { record.deletedAt = .now }
            else { record.occurredAt = draft.occurredAt; record.parity = Int(draft.value); record.note = draft.text }
            record.revision += 1; record.updatedAt = .now
        }
    }
}

extension FarmEventCorrection {
    static func draft(for event: FarmEventSnapshot, farmID: UUID, context: ModelContext) throws -> FarmEventCorrectionDraft {
        let id = event.id
        switch event.entityType {
        case .weaning:
            guard let record = try context.fetch(FetchDescriptor<WeaningRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            return .init(kind: .weaning, entityID: id, sourceEventID: id, occurredAt: record.occurredAt, text: record.note, value: record.weanWeightText)
        case .feed:
            guard let record = try context.fetch(FetchDescriptor<FeedRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            return .init(kind: .feed, entityID: id, sourceEventID: id, occurredAt: record.occurredAt, text: record.note, value: "")
        case .note:
            guard let record = try context.fetch(FetchDescriptor<NoteRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            return .init(kind: .note, entityID: id, sourceEventID: id, occurredAt: record.occurredAt, text: record.text, value: "")
        case .inventoryTransaction:
            guard let record = try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            return .init(kind: .inventory, entityID: id, sourceEventID: id, occurredAt: record.occurredAt, text: record.note, value: record.quantityText)
        case .semenTransaction:
            guard let record = try context.fetch(FetchDescriptor<SemenTransactionRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            return .init(kind: .semen, entityID: id, sourceEventID: id, occurredAt: record.occurredAt, text: record.note, value: record.quantityText)
        case .batchMembership:
            guard let record = try context.fetch(FetchDescriptor<BatchMembershipRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }), let leftAt = record.leftAt else { throw FarmCommandError.sourceRecordNotFound }
            return .init(kind: .departure, entityID: id, sourceEventID: id, occurredAt: leftAt, text: record.leaveReason ?? "", value: "")
        case .sheep where event.title == "用途变更":
            let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farmID }
            guard let fact = SheepPurposeTimeline.facts(from: operations).first(where: { $0.id == id }) else { throw FarmCommandError.sourceRecordNotFound }
            return .init(kind: .purpose, entityID: fact.sheepID, sourceEventID: id, occurredAt: fact.occurredAt, text: fact.reason, value: fact.purpose.rawValue)
        case .reproduction where event.title == ReproductionRecordKind.parityBaseline.displayName:
            guard let record = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            return .init(kind: .parity, entityID: id, sourceEventID: id, occurredAt: record.occurredAt, text: record.note, value: String(record.parity ?? 0))
        default: throw FarmCommandError.sourceRecordNotFound
        }
    }
}
