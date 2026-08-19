import Foundation
import SwiftData

struct FarmBackupEnvelopeV1: Codable, Sendable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let payload: FarmBackupPayloadV1
    let checksum: String
}

struct FarmBackupPayloadV1: Codable, Sendable, Equatable {
    struct Farm: Codable, Sendable, Equatable { let id: UUID; let name: String; let createdAt: Date; let updatedAt: Date }
    struct Pen: Codable, Sendable, Equatable { let id: UUID; let name: String; let note: String; let isActive: Bool; let revision: Int; let createdAt: Date; let updatedAt: Date; let deletedAt: Date? }
    struct Sheep: Codable, Sendable, Equatable { let id: UUID; let earTag: String; let breed: String; let purpose: String; let isBreedingRam: Bool?; let sex: SheepSex; let status: SheepStatus; let currentPenID: UUID?; let initialPenID: UUID?; let damID: UUID?; let sireID: UUID?; let damProvenanceRawValue: String?; let sireProvenanceRawValue: String?; let semenDonorID: UUID?; let semenDonorNameSnapshot: String?; let semenDonorRegistrationNumberSnapshot: String?; let semenDonorBreedSnapshot: String?; let enteredAt: Date; let birthAt: Date?; let removedAt: Date?; let note: String; let isHistoricalArchive: Bool; let revision: Int; let createdAt: Date; let updatedAt: Date; let deletedAt: Date? }
    struct Weight: Codable, Sendable, Equatable { let id: UUID; let sheepID: UUID; let kilogramsText: String; let occurredAt: Date; let recordedAt: Date; let note: String; let revision: Int; let deletedAt: Date? }
    struct Transfer: Codable, Sendable, Equatable { let id: UUID; let sheepID: UUID; let fromPenID: UUID?; let toPenID: UUID?; let occurredAt: Date; let recordedAt: Date; let note: String; let revision: Int; let deletedAt: Date? }
    struct Removal: Codable, Sendable, Equatable { let id: UUID; let sheepID: UUID; let kind: RemovalKind; let reason: String; let amountText: String?; let removalBatchID: UUID?; let batchTotalAmountText: String?; let occurredAt: Date; let recordedAt: Date; let note: String; let revision: Int; let deletedAt: Date? }
    struct Tombstone: Codable, Sendable, Equatable { let id: UUID; let entityType: String; let entityID: UUID; let deletedAt: Date; let reason: String; let revision: Int; let restoredAt: Date? }
    struct Audit: Codable, Sendable, Equatable { let id: UUID; let kind: DomainOperationKind; let occurredAt: Date; let summary: String; let entityType: String; let entityID: UUID?; let baseRevision: Int; let resultingRevision: Int; let payload: Data }
    let exportedAt: Date
    let farm: Farm
    let pens: [Pen]
    let sheep: [Sheep]
    let weights: [Weight]
    let transfers: [Transfer]
    let removals: [Removal]
    let tombstones: [Tombstone]
    let audits: [Audit]
    let care: FarmCareBackupPayload?
    let feeding: FarmFeedingBackupPayload?

    init(
        exportedAt: Date,
        farm: Farm,
        pens: [Pen],
        sheep: [Sheep],
        weights: [Weight],
        transfers: [Transfer],
        removals: [Removal],
        tombstones: [Tombstone],
        audits: [Audit],
        care: FarmCareBackupPayload?,
        feeding: FarmFeedingBackupPayload? = nil
    ) {
        self.exportedAt = exportedAt
        self.farm = farm
        self.pens = pens
        self.sheep = sheep
        self.weights = weights
        self.transfers = transfers
        self.removals = removals
        self.tombstones = tombstones
        self.audits = audits
        self.care = care
        self.feeding = feeding
    }

    private enum CodingKeys: String, CodingKey {
        case exportedAt, farm, pens, sheep, weights, transfers, removals
        case tombstones, audits, care, feeding
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exportedAt = try values.decode(Date.self, forKey: .exportedAt)
        farm = try values.decode(Farm.self, forKey: .farm)
        pens = try values.decode([Pen].self, forKey: .pens)
        sheep = try values.decode([Sheep].self, forKey: .sheep)
        weights = try values.decode([Weight].self, forKey: .weights)
        transfers = try values.decode([Transfer].self, forKey: .transfers)
        removals = try values.decode([Removal].self, forKey: .removals)
        tombstones = try values.decode([Tombstone].self, forKey: .tombstones)
        audits = try values.decode([Audit].self, forKey: .audits)
        care = try values.decodeIfPresent(FarmCareBackupPayload.self, forKey: .care)
        feeding = try values.decodeIfPresent(FarmFeedingBackupPayload.self, forKey: .feeding)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(exportedAt, forKey: .exportedAt)
        try values.encode(farm, forKey: .farm)
        try values.encode(pens, forKey: .pens)
        try values.encode(sheep, forKey: .sheep)
        try values.encode(weights, forKey: .weights)
        try values.encode(transfers, forKey: .transfers)
        try values.encode(removals, forKey: .removals)
        try values.encode(tombstones, forKey: .tombstones)
        try values.encode(audits, forKey: .audits)
        try values.encodeIfPresent(care, forKey: .care)
        try values.encodeIfPresent(feeding, forKey: .feeding)
    }
}

struct FarmBackupPreview: Sendable, Equatable {
    let envelope: FarmBackupEnvelopeV1
    let entityCount: Int
    var summary: String { "圈舍 \(envelope.payload.pens.count) · 羊只 \(envelope.payload.sheep.count) · 称重 \(envelope.payload.weights.count) · 投喂/TMR \(envelope.payload.feeding?.entityCount ?? 0) · 健康繁殖 \(envelope.payload.care?.entityCount ?? 0)" }
}

struct FarmBackupRestoreResult: Sendable, Equatable {
    let restoredCount: Int
    let alreadyRestored: Bool
}

enum FarmLocalBackupError: LocalizedError {
    case unsupportedVersion
    case checksumMismatch
    case farmMismatch
    case duplicateIdentifier(String)
    case duplicateEarTag
    case missingReference(String)
    case targetNotEmpty
    case identifierCollision
    case invalidProjection(String)
    case cloudTargetForbidden

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "备份版本不受支持。"
        case .checksumMismatch: "备份校验失败，文件可能不完整或已被修改。"
        case .farmMismatch: "备份中的牧场标识不一致。"
        case .duplicateIdentifier(let type): "备份包含重复的\(type)标识。"
        case .duplicateEarTag: "备份包含重复耳号。"
        case .missingReference(let field): "备份缺少被引用的数据：\(field)。"
        case .targetNotEmpty: "只能恢复到没有羊群生产数据的空牧场。"
        case .identifierCollision: "备份标识已被其他牧场使用，已停止恢复。"
        case .invalidProjection(let field): "备份中的投喂数据不完整或不一致：\(field)。"
        case .cloudTargetForbidden: "文件备份只能恢复为新的仅本机牧场，不能直接覆盖 iCloud 或 eSheep 云牧场。"
        }
    }
}

@MainActor
enum FarmLocalBackupService {
    static func export(farmID: UUID, context: ModelContext, exportedAt: Date = .now) throws -> Data {
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID && $0.deletedAt == nil }) else { throw FarmLocalBackupError.farmMismatch }
        let payload = FarmBackupPayloadV1(
            exportedAt: exportedAt,
            farm: .init(id: farm.id, name: farm.name, createdAt: farm.createdAt, updatedAt: farm.updatedAt),
            pens: try context.fetch(FetchDescriptor<PenRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, name: $0.name, note: $0.note, isActive: $0.isActive, revision: $0.revision, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt) },
            sheep: try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, earTag: $0.earTag, breed: $0.breed, purpose: $0.purpose, isBreedingRam: $0.isBreedingRam, sex: $0.sex, status: $0.status, currentPenID: $0.currentPenID, initialPenID: $0.initialPenID, damID: $0.damID, sireID: $0.sireID, damProvenanceRawValue: $0.damProvenanceRawValue, sireProvenanceRawValue: $0.sireProvenanceRawValue, semenDonorID: $0.semenDonorID, semenDonorNameSnapshot: $0.semenDonorNameSnapshot, semenDonorRegistrationNumberSnapshot: $0.semenDonorRegistrationNumberSnapshot, semenDonorBreedSnapshot: $0.semenDonorBreedSnapshot, enteredAt: $0.enteredAt, birthAt: $0.birthAt, removedAt: $0.removedAt, note: $0.note, isHistoricalArchive: $0.isHistoricalArchive, revision: $0.revision, createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt) },
            weights: try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, sheepID: $0.sheepID, kilogramsText: $0.kilogramsText, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt, note: $0.note, revision: $0.revision, deletedAt: $0.deletedAt) },
            transfers: try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, sheepID: $0.sheepID, fromPenID: $0.fromPenID, toPenID: $0.toPenID, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt, note: $0.note, revision: $0.revision, deletedAt: $0.deletedAt) },
            removals: try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, sheepID: $0.sheepID, kind: $0.kind, reason: $0.reason, amountText: $0.amountText, removalBatchID: $0.removalBatchID, batchTotalAmountText: $0.batchTotalAmountText, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt, note: $0.note, revision: $0.revision, deletedAt: $0.deletedAt) },
            tombstones: try context.fetch(FetchDescriptor<TombstoneRecord>()).filter { $0.farmID == farmID }.map { .init(id: $0.id, entityType: $0.entityType, entityID: $0.entityID, deletedAt: $0.deletedAt, reason: $0.reason, revision: $0.revision, restoredAt: $0.restoredAt) },
            audits: try context.fetch(FetchDescriptor<DomainOperation>()).filter { $0.farmID == farmID }.compactMap { operation in guard let kind = DomainOperationKind(rawValue: operation.kindRawValue) else { return nil }; return .init(id: operation.id, kind: kind, occurredAt: operation.occurredAt, summary: operation.summary, entityType: operation.entityType, entityID: operation.entityID, baseRevision: operation.baseRevision, resultingRevision: operation.resultingRevision, payload: operation.payload) },
            care: try FarmCareBackupPayload.capture(farmID: farmID, context: context),
            feeding: try FarmFeedingBackupPayload.capture(farmID: farmID, context: context)
        )
        let envelope = FarmBackupEnvelopeV1(schemaVersion: FarmBackupEnvelopeV1.schemaVersion, payload: payload, checksum: checksum(payload))
        return try encoder.encode(envelope)
    }

    static func preview(data: Data) throws -> FarmBackupPreview {
        let envelope = try decoder.decode(FarmBackupEnvelopeV1.self, from: data)
        try validate(envelope)
        try validateInTemporaryStore(envelope)
        let count = envelope.payload.pens.count + envelope.payload.sheep.count + envelope.payload.weights.count + envelope.payload.transfers.count + envelope.payload.removals.count + envelope.payload.tombstones.count + (envelope.payload.care?.entityCount ?? 0) + (envelope.payload.feeding?.entityCount ?? 0)
        return .init(envelope: envelope, entityCount: count)
    }

    static func restore(
        _ preview: FarmBackupPreview,
        into farm: FarmRecord,
        account: AccountProfile,
        context: ModelContext,
        additionalRestore: ((UUID, UUID, ModelContext) throws -> Void)? = nil
    ) throws -> FarmBackupRestoreResult {
        if let storageProfile = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: { $0.farmID == farm.id }),
           storageProfile.mode != .localOnly {
            throw FarmLocalBackupError.cloudTargetForbidden
        }
        let marker = "本地备份恢复：\(preview.envelope.checksum)"
        if try context.fetch(FetchDescriptor<DomainOperation>()).contains(where: { $0.farmID == farm.id && $0.summary == marker }) {
            return .init(restoredCount: 0, alreadyRestored: true)
        }
        let hasData = try context.fetch(FetchDescriptor<PenRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<SheepRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<WeightRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<WeaningRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<BreedingProgramRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<TransferRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<RemovalRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<ProductionBatchRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<BatchMembershipRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<DailyPenCountRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<HealthRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<ReproductionRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<InventoryLotRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<SemenRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<FeedIngredientRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<FeedRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<TMRBatchRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<NoteRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<PhotoAssetRecord>()).contains { $0.farmID == farm.id }
            || context.fetch(FetchDescriptor<SheepAvatarRecord>()).contains { $0.farmID == farm.id }
        guard !hasData else { throw FarmLocalBackupError.targetNotEmpty }
        try validateIdentifierCollisions(preview.envelope.payload, targetFarmID: farm.id, context: context)
        insert(preview.envelope.payload, farmID: farm.id, accountID: account.effectiveAccountID, context: context)
        try additionalRestore?(farm.id, account.effectiveAccountID, context)
        farm.name = preview.envelope.payload.farm.name
        farm.updatedAt = .now
        context.insert(DomainOperation(farmID: farm.id, accountID: account.effectiveAccountID, kind: .recoverEntity, summary: marker, entityType: CloudEntityType.farm.rawValue, entityID: farm.id, payload: Data(preview.envelope.checksum.utf8)))
        try FarmHistoryRebuilder().rebuild(farmID: farm.id, context: context, from: .distantPast)
        try context.save()
        return .init(restoredCount: preview.entityCount, alreadyRestored: false)
    }

    private static func validate(_ envelope: FarmBackupEnvelopeV1) throws {
        guard envelope.schemaVersion == FarmBackupEnvelopeV1.schemaVersion else { throw FarmLocalBackupError.unsupportedVersion }
        guard envelope.checksum == checksum(envelope.payload) else { throw FarmLocalBackupError.checksumMismatch }
        try unique(envelope.payload.pens.map(\.id), "圈舍")
        try unique(envelope.payload.sheep.map(\.id), "羊只")
        try unique(envelope.payload.weights.map(\.id), "称重")
        try unique(envelope.payload.transfers.map(\.id), "转群")
        try unique(envelope.payload.removals.map(\.id), "离场")
        let tags = envelope.payload.sheep.map { EarTag.normalized($0.earTag) }
        guard Set(tags).count == tags.count else { throw FarmLocalBackupError.duplicateEarTag }
        let penIDs = Set(envelope.payload.pens.map(\.id)); let sheepIDs = Set(envelope.payload.sheep.map(\.id))
        for sheep in envelope.payload.sheep { if let id = sheep.currentPenID, !penIDs.contains(id) { throw FarmLocalBackupError.missingReference("sheep.currentPenID") }; if let id = sheep.initialPenID, !penIDs.contains(id) { throw FarmLocalBackupError.missingReference("sheep.initialPenID") }; if let id = sheep.damID, !sheepIDs.contains(id) { throw FarmLocalBackupError.missingReference("sheep.damID") }; if let id = sheep.sireID, !sheepIDs.contains(id) { throw FarmLocalBackupError.missingReference("sheep.sireID") } }
        for value in envelope.payload.weights where !sheepIDs.contains(value.sheepID) { throw FarmLocalBackupError.missingReference("weight.sheepID") }
        for value in envelope.payload.transfers { guard sheepIDs.contains(value.sheepID) else { throw FarmLocalBackupError.missingReference("transfer.sheepID") }; if let id = value.fromPenID, !penIDs.contains(id) { throw FarmLocalBackupError.missingReference("transfer.fromPenID") }; if let id = value.toPenID, !penIDs.contains(id) { throw FarmLocalBackupError.missingReference("transfer.toPenID") } }
        for value in envelope.payload.removals where !sheepIDs.contains(value.sheepID) { throw FarmLocalBackupError.missingReference("removal.sheepID") }
        try envelope.payload.care?.validate(penIDs: penIDs, sheepIDs: sheepIDs)
        try envelope.payload.feeding?.validate(penIDs: penIDs)
        let donorIDs = Set((envelope.payload.care?.donors ?? []).map(\.id))
        for sheep in envelope.payload.sheep { if let id = sheep.semenDonorID, !donorIDs.contains(id) { throw FarmLocalBackupError.missingReference("sheep.semenDonorID") } }
    }

    private static func validateInTemporaryStore(_ envelope: FarmBackupEnvelopeV1) throws {
        let container = try AppSchema.makeContainer(name: "BackupValidation", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let accountID = UUID()
        context.insert(FarmRecord(id: envelope.payload.farm.id, ownerAccountID: accountID, name: envelope.payload.farm.name))
        insert(envelope.payload, farmID: envelope.payload.farm.id, accountID: accountID, context: context, includeAudits: false)
        try context.save()
        try FarmHistoryRebuilder().rebuild(farmID: envelope.payload.farm.id, context: context, from: .distantPast)
        try context.save()
    }

    private static func insert(_ payload: FarmBackupPayloadV1, farmID: UUID, accountID: UUID, context: ModelContext, includeAudits: Bool = true) {
        payload.care?.insertDonors(farmID: farmID, context: context)
        for value in payload.pens { let record = PenRecord(id: value.id, farmID: farmID, name: value.name, note: value.note, createdAt: value.createdAt); record.isActive = value.isActive; record.revision = value.revision; record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in payload.sheep { let record = SheepRecord(id: value.id, farmID: farmID, earTag: value.earTag, isHistoricalArchive: value.isHistoricalArchive, breed: value.breed, purpose: value.purpose, isBreedingRam: value.isBreedingRam, sex: value.sex, penID: value.initialPenID, enteredAt: value.enteredAt, birthAt: value.birthAt, damID: value.damID, sireID: value.sireID, damProvenance: value.damProvenanceRawValue.flatMap(PedigreeRelationSource.init(rawValue:)), sireProvenance: value.sireProvenanceRawValue.flatMap(PedigreeRelationSource.init(rawValue:)), semenDonorID: value.semenDonorID, semenDonorNameSnapshot: value.semenDonorNameSnapshot, semenDonorRegistrationNumberSnapshot: value.semenDonorRegistrationNumberSnapshot, semenDonorBreedSnapshot: value.semenDonorBreedSnapshot, note: value.note); record.statusRawValue = value.status.rawValue; record.currentPenID = value.currentPenID; record.removedAt = value.removedAt; record.revision = value.revision; record.createdAt = value.createdAt; record.updatedAt = value.updatedAt; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in payload.weights { let record = WeightRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, kilogramsText: value.kilogramsText, occurredAt: value.occurredAt, note: value.note); record.recordedAt = value.recordedAt; record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in payload.transfers { let record = TransferRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, fromPenID: value.fromPenID, toPenID: value.toPenID, occurredAt: value.occurredAt, note: value.note); record.recordedAt = value.recordedAt; record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in payload.removals { let record = RemovalRecord(id: value.id, farmID: farmID, sheepID: value.sheepID, kind: value.kind, reason: value.reason, amountText: value.amountText, removalBatchID: value.removalBatchID, batchTotalAmountText: value.batchTotalAmountText, occurredAt: value.occurredAt, note: value.note); record.recordedAt = value.recordedAt; record.revision = value.revision; record.deletedAt = value.deletedAt; context.insert(record) }
        for value in payload.tombstones { let record = TombstoneRecord(id: value.id, farmID: farmID, entityType: value.entityType, entityID: value.entityID, deletedByAccountID: accountID, reason: value.reason, revision: value.revision); record.deletedAt = value.deletedAt; record.restoredAt = value.restoredAt; context.insert(record) }
        payload.care?.insert(farmID: farmID, context: context, includeDonors: false)
        payload.feeding?.insert(farmID: farmID, context: context)
        if includeAudits { for value in payload.audits { context.insert(DomainOperation(id: value.id, farmID: farmID, accountID: accountID, kind: value.kind, occurredAt: value.occurredAt, summary: value.summary, entityType: value.entityType, entityID: value.entityID, baseRevision: value.baseRevision, resultingRevision: value.resultingRevision, payload: value.payload)) } }
    }

    private static func validateIdentifierCollisions(_ payload: FarmBackupPayloadV1, targetFarmID: UUID, context: ModelContext) throws {
        var ids = Set(payload.pens.map(\.id) + payload.sheep.map(\.id) + payload.weights.map(\.id) + payload.transfers.map(\.id) + payload.removals.map(\.id))
        if let feeding = payload.feeding {
            ids.formUnion(feeding.ingredients.map(\.id))
            ids.formUnion(feeding.ingredientBatches.map(\.id))
            ids.formUnion(feeding.stockTransactions.map(\.id))
            ids.formUnion(feeding.stockCounts.map(\.id))
            ids.formUnion(feeding.recipes.map(\.id))
            ids.formUnion(feeding.recipeComponents.map(\.id))
            ids.formUnion(feeding.feeds.map(\.id))
            ids.formUnion(feeding.feedLines.map(\.id))
            ids.formUnion(feeding.troughObservations.map(\.id))
            if let tmr = feeding.tmr {
                ids.formUnion(tmr.formulaProfiles.map(\.id))
                ids.formUnion(tmr.plans.map(\.id))
                ids.formUnion(tmr.planPens.map(\.id))
                ids.formUnion(tmr.batches.map(\.id))
                ids.formUnion(tmr.batchIngredients.map(\.id))
                ids.formUnion(tmr.loadLines.map(\.id))
                ids.formUnion(tmr.movements.map(\.id))
                ids.formUnion(tmr.feedingRuns.map(\.id))
                ids.formUnion(tmr.feedingAllocations.map(\.id))
                ids.formUnion(tmr.mealCompletions.map(\.id))
                ids.formUnion(tmr.deviationAcknowledgements.map(\.id))
                ids.formUnion(tmr.monitoringRules.map(\.id))
            }
        }
        let foreign = try context.fetch(FetchDescriptor<PenRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<SheepRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<WeightRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TransferRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<RemovalRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedIngredientRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedStockCountRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedRecipeRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedRecordLine>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRFormulaProfileRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRBatchRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRBatchIngredientRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRBatchLoadLineRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRBatchMovementRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
            || context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>()).contains { $0.farmID != targetFarmID && ids.contains($0.id) }
        guard !foreign else { throw FarmLocalBackupError.identifierCollision }
    }

    private static func unique(_ values: [UUID], _ type: String) throws { guard Set(values).count == values.count else { throw FarmLocalBackupError.duplicateIdentifier(type) } }
    private static func checksum(_ payload: FarmBackupPayloadV1) -> String { CloudPayloadDigest.hex(for: (try? encoder.encode(payload)) ?? Data()) }
    private static var encoder: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.sortedKeys]; return value }
    private static var decoder: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
