import Foundation
import SwiftData

enum FeedStockLedgerError: LocalizedError {
    case baselineMissing(UUID)
    case insufficient(batchID: UUID, available: Decimal, requested: Decimal)
    case invalidQuantity

    var errorDescription: String? {
        switch self {
        case .baselineMissing: "该原料批次尚未补录库存基线，不能用于新投喂。"
        case .insufficient(_, let available, let requested): "原料批次库存不足：可用 \(available.stableText) 千克，需要 \(requested.stableText) 千克。"
        case .invalidQuantity: "库存数量必须是有效的非零数值。"
        }
    }
}

/// Feed-batch stock is an append-only ledger.  The legacy batch's current
/// remaining value is the opening baseline; historical feeds are deliberately
/// not replayed into this ledger.
enum FeedStockLedger {
    static func baseline(for batch: FeedIngredientBatchRecord) -> Decimal? {
        if let remaining = batch.remainingKilogramsText.flatMap(Decimal.stable) {
            return remaining
        }
        if let initial = batch.initialKilogramsText.flatMap(Decimal.stable) {
            return initial
        }
        return nil
    }

    static func balance(for batch: FeedIngredientBatchRecord, transactions: [FeedStockTransactionRecord]) -> Decimal? {
        let relevant = transactions
            .filter { $0.farmID == batch.farmID && $0.ingredientBatchID == batch.id && $0.deletedAt == nil }
        if let baseline = baseline(for: batch) {
            return relevant.reduce(baseline) { $0 + $1.signedQuantity }
        }
        // A newly received batch may establish its opening stock through a
        // receipt transaction instead of the batch editor.  An unresolved
        // conflict alone must not manufacture a zero-kilogram baseline.
        guard relevant.contains(where: { $0.kind != .conflict }) else { return nil }
        return relevant.reduce(0) { $0 + $1.signedQuantity }
    }

    static func balance(for batch: FeedIngredientBatchRecord, context: ModelContext) throws -> Decimal? {
        let transactions = try context.fetch(FetchDescriptor<FeedStockTransactionRecord>())
        return balance(for: batch, transactions: transactions)
    }

    static func validateConsumption(lines: [FeedLineDraft], farmID: UUID, context: ModelContext) throws {
        let batches = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
        let transactions = try context.fetch(FetchDescriptor<FeedStockTransactionRecord>())
        try validateConsumption(
            lines: lines,
            farmID: farmID,
            batches: batches,
            transactions: transactions
        )
    }

    static func validateConsumption(
        lines: [FeedLineDraft],
        farmID: UUID,
        batches: [FeedIngredientBatchRecord],
        transactions: [FeedStockTransactionRecord]
    ) throws {
        var requestedByBatch: [UUID: Decimal] = [:]
        for line in lines {
            guard let batchID = line.ingredientBatchID else {
                throw FarmStockCommandError.batchRequired
            }
            guard let batch = batches.first(where: {
                $0.id == batchID && $0.farmID == farmID && $0.ingredientID == line.ingredientID && $0.isActive && $0.deletedAt == nil
            }) else {
                throw FarmCommandError.feedIngredientBatchNotFound
            }
            guard let quantity = Decimal.stable(line.kilogramsText), quantity > 0 else {
                throw FeedStockLedgerError.invalidQuantity
            }
            guard balance(for: batch, transactions: transactions) != nil else {
                throw FeedStockLedgerError.baselineMissing(batch.id)
            }
            requestedByBatch[batch.id, default: 0] += quantity
        }
        for (batchID, requested) in requestedByBatch {
            guard let batch = batches.first(where: { $0.id == batchID }),
                  let available = balance(for: batch, transactions: transactions) else {
                throw FeedStockLedgerError.baselineMissing(batchID)
            }
            guard available >= requested else {
                throw FeedStockLedgerError.insufficient(batchID: batchID, available: available, requested: requested)
            }
        }
    }

    static func consumptionID(for lineID: UUID) -> UUID {
        StableCloudUUID.derived(namespace: lineID, name: "feed-stock-consumption")
    }

    static func reversalID(for consumptionID: UUID) -> UUID {
        StableCloudUUID.derived(namespace: consumptionID, name: "feed-stock-reversal")
    }

    static func insertConsumption(
        feedID: UUID,
        lineID: UUID,
        batchID: UUID,
        quantityText: String,
        occurredAt: Date,
        farmID: UUID,
        context: ModelContext
    ) {
        let id = consumptionID(for: lineID)
        context.insert(FeedStockTransactionRecord(
            id: id,
            farmID: farmID,
            ingredientBatchID: batchID,
            kind: .consumption,
            quantityText: quantityText,
            occurredAt: occurredAt,
            sourceRecordID: feedID,
            sourceLineID: lineID,
            note: "投喂扣减"
        ))
    }

    static func insertReversal(
        for consumption: FeedStockTransactionRecord,
        at date: Date,
        context: ModelContext
    ) {
        let reversalID = reversalID(for: consumption.id)
        context.insert(FeedStockTransactionRecord(
            id: reversalID,
            farmID: consumption.farmID,
            ingredientBatchID: consumption.ingredientBatchID,
            kind: .reversal,
            quantityText: consumption.quantityText,
            occurredAt: date,
            sourceRecordID: consumption.sourceRecordID,
            sourceLineID: consumption.sourceLineID,
            note: "撤销投喂冲回（\(consumption.id.uuidString.lowercased())）"
        ))
    }
}

enum FarmStockCommandError: LocalizedError {
    case batchRequired

    var errorDescription: String? {
        switch self {
        case .batchRequired: "新投喂必须选择有明确库存基线的原料批次。"
        }
    }
}
