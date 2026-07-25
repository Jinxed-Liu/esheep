import Foundation
import SwiftData

enum FarmCommandError: LocalizedError {
    case missingRequiredValue(String)
    case invalidNumber(String)
    case duplicateEarTag
    case sheepNotFound
    case penNotFound
    case ingredientNotFound
    case feedIngredientBatchNotFound
    case batchNotFound
    case removalNotFound
    case invalidRemovalBatch(String)
    case duplicateBatchMembership
    case batchMembershipNotFound
    case inventoryLotNotFound
    case insufficientInventory
    case invalidReproductionRecord
    case reproductionSubjectMustBeEwe
    case reproductionSireMustBeRam
    case pregnancyCheckCannotSetPaternity
    case pedigreeReasonRequired
    case pedigreeSelfReference
    case pedigreeParentSexMismatch
    case pedigreeCycle
    case pedigreeDateInversion
    case pedigreePaternalSourceConflict
    case pedigreeRevisionConflict
    case semenDonorNotFound
    case duplicateSemenDonorRegistration
    case linkedBreedingNotFound
    case linkedBreedingAlreadyClosed
    case lambingCorrectionConflict(String)
    case weaningDamMustBeEwe
    case cloudIdentityLocked
    case invalidFarmCoordinate
    case invalidFarmTimeZone
    case penHasCurrentSheep
    case protectedPenReferences
    case protectedSheepReferences
    case sourceRecordNotFound

    var errorDescription: String? {
        switch self {
        case .missingRequiredValue(let label): "请填写\(label)。"
        case .invalidNumber(let label): "\(label)必须是有效且大于零的数值。"
        case .duplicateEarTag: "当前牧场已存在相同耳号。耳号在本牧场内永久唯一。"
        case .sheepNotFound: "未找到当前牧场中的羊只。"
        case .penNotFound: "未找到当前牧场中的圈舍。"
        case .ingredientNotFound: "投喂原料不存在或已停用。"
        case .feedIngredientBatchNotFound: "投喂原料批次不存在、已停用，或不属于所选原料。"
        case .batchNotFound: "未找到当前牧场中的生产批次。"
        case .removalNotFound: "未找到可恢复的离场记录。"
        case .invalidRemovalBatch(let detail): "离场批次无效：\(detail)"
        case .duplicateBatchMembership: "该羊已在此批次中。"
        case .batchMembershipNotFound: "未找到可结束的批次成员关系。"
        case .inventoryLotNotFound: "未找到当前牧场中的库存批次。"
        case .insufficientInventory: "库存余量不足，无法完成本次出库。"
        case .invalidReproductionRecord: "繁殖记录缺少必填信息。"
        case .reproductionSubjectMustBeEwe: "繁殖记录的对象必须是母羊。"
        case .reproductionSireMustBeRam: "本交父本必须是已标记的种公羊。"
        case .pregnancyCheckCannotSetPaternity: "孕检只能记录结果，不能确认父本或冻精来源。"
        case .pedigreeReasonRequired: "修改历史系谱必须填写原因。"
        case .pedigreeSelfReference: "羊只不能把自己设为父本或母本。"
        case .pedigreeParentSexMismatch: "母本必须是母羊，父本必须是已标记的种公羊。"
        case .pedigreeCycle: "本次修改会形成循环系谱，已停止保存。"
        case .pedigreeDateInversion: "父母的已知出生日期不能晚于或等于后代。"
        case .pedigreePaternalSourceConflict: "本场种公羊和冻精供体必须二选一；供体关联种公羊只能由供体关系投影。"
        case .pedigreeRevisionConflict: "该档案已在其他位置更新，请刷新后重试。"
        case .semenDonorNotFound: "未找到当前牧场中的冻精供体。"
        case .duplicateSemenDonorRegistration: "当前牧场已存在相同的供体登记号。"
        case .linkedBreedingNotFound: "未找到这只母羊此前可关联的配种记录。"
        case .linkedBreedingAlreadyClosed: "所选配种记录已经由流产或产羔闭合。"
        case .lambingCorrectionConflict(let detail): "产羔修正与后续记录冲突：\(detail)"
        case .weaningDamMustBeEwe: "断奶记录中的母本必须是母羊。"
        case .cloudIdentityLocked: "当前云端牧场缺少有效的账号绑定或能力证书，已锁定写入。"
        case .invalidFarmCoordinate: "牧场坐标必须位于有效的经纬度范围内。"
        case .invalidFarmTimeZone: "请选择有效的 IANA 时区。"
        case .penHasCurrentSheep: "圈舍内仍有在场羊只，请先转群后再停用。"
        case .protectedPenReferences: "圈舍仍被羊只或生产历史引用，不能直接删除；可以先停用。"
        case .protectedSheepReferences: "该羊只已有生产历史或亲缘关系，不能直接删除建档事件；请删除或修正关联事实。"
        case .sourceRecordNotFound: "未找到可修正的原始记录。"
        }
    }
}

struct FeedLineDraft: Sendable, Hashable, Identifiable {
    let id: UUID
    let ingredientID: UUID
    let ingredientBatchID: UUID?
    let kilogramsText: String

    init(id: UUID = UUID(), ingredientID: UUID, ingredientBatchID: UUID? = nil, kilogramsText: String) {
        self.id = id
        self.ingredientID = ingredientID
        self.ingredientBatchID = ingredientBatchID
        self.kilogramsText = kilogramsText
    }
}

struct BreedingProgramStepDraft: Sendable, Hashable, Identifiable {
    let id: UUID
    var dayOffset: Int
    var action: String

    init(id: UUID = UUID(), dayOffset: Int, action: String) {
        self.id = id
        self.dayOffset = dayOffset
        self.action = action
    }
}

enum LambSex: String, CaseIterable, Sendable, Hashable {
    case male = "公"
    case female = "母"

    var displayName: String { rawValue }
}

struct LambingOffspringDraft: Sendable, Hashable, Identifiable {
    let id: UUID
    let sheepID: UUID?
    let earTag: String
    let sex: LambSex
    let birthWeightText: String

    init(id: UUID = UUID(), sheepID: UUID? = nil, earTag: String, sex: LambSex, birthWeightText: String) {
        self.id = id
        self.sheepID = sheepID
        self.earTag = earTag
        self.sex = sex
        self.birthWeightText = birthWeightText
    }
}

enum FarmCommand: Sendable {
    case updateFarmLocation(displayName: String, latitude: Double, longitude: Double, addressSnapshot: String?, timeZoneIdentifier: String, source: FarmLocationSource, horizontalAccuracyMeters: Double?)
    case createPen(name: String, note: String)
    case updatePen(penID: UUID, name: String, note: String)
    case setPenActive(penID: UUID, isActive: Bool)
    case addSheep(earTag: String, breed: String, sex: SheepSex, penID: UUID?, occurredAt: Date, birthAt: Date?, note: String)
    case updateSheepProfile(sheepID: UUID, earTag: String, breed: String, sex: SheepSex, birthAt: Date?, note: String)
    case recordWeight(sheepID: UUID, kilogramsText: String, occurredAt: Date, note: String)
    case correctWeight(originalID: UUID, kilogramsText: String, occurredAt: Date, note: String, reason: String)
    case recordWeaning(sheepID: UUID, weanWeightText: String, occurredAt: Date, birthAt: Date?, birthWeightText: String?, averageDailyGainText: String?, damID: UUID?, litterSize: Int?, note: String)
    case createBreedingProgram(name: String, createdAt: Date, steps: [BreedingProgramStepDraft])
    case transferSheep(sheepID: UUID, toPenID: UUID?, occurredAt: Date, note: String)
    case correctTransfer(originalID: UUID, toPenID: UUID?, occurredAt: Date, note: String, reason: String)
    case removeSheep(
        sheepID: UUID,
        kind: RemovalKind,
        reason: String,
        amountText: String?,
        occurredAt: Date,
        note: String,
        recordID: UUID? = nil,
        removalBatchID: UUID? = nil,
        batchTotalAmountText: String? = nil
    )
    case correctRemoval(originalID: UUID, kind: RemovalKind, reason: String, amountText: String?, occurredAt: Date, note: String, correctionReason: String)
    case restoreSheep(removalID: UUID)
    case createBatch(name: String, purpose: String, startedAt: Date, sheepIDs: [UUID], note: String)
    case assignSheepToBatch(batchID: UUID, sheepID: UUID, joinedAt: Date)
    case leaveBatch(batchID: UUID, sheepID: UUID, leftAt: Date, reason: String)
    case addIngredient(name: String, unit: String, dryMatterText: String?)
    case createRecipe(name: String, note: String)
    case addRecipeComponent(recipeID: UUID, ingredientID: UUID, kilogramsText: String)
    case recordFeed(penID: UUID, recipeID: UUID?, mode: FeedMode, occurredAt: Date, lines: [FeedLineDraft], note: String)
    case recordHealth(sheepID: UUID?, penID: UUID?, kind: HealthRecordKind, itemName: String, occurredAt: Date, note: String, inventoryLotID: UUID?, quantityText: String?)
    case receiveInventory(catalogName: String, kind: HealthRecordKind, expiresAt: Date?, quantityText: String, occurredAt: Date, note: String)
    case addSemen(code: String, breed: String, source: String, batchNumber: String, quantityText: String)
    case recordReproduction(eweID: UUID, kind: ReproductionRecordKind, occurredAt: Date, sireID: UUID?, semenName: String?, result: String, lambCount: Int, parity: Int?, birthDeadCount: Int?, offspring: [LambingOffspringDraft], note: String)
    case care(CareCommand)
    case addNote(sheepID: UUID?, penID: UUID?, text: String, occurredAt: Date)
    case tombstoneEntity(entityType: CloudEntityType, entityID: UUID, reason: String)
    case restoreTombstonedEntity(tombstoneID: UUID)

    var requiredCapability: FarmCapability {
        switch self {
        case .updateFarmLocation:
            .editFarmLocation
        case .restoreSheep, .tombstoneEntity, .restoreTombstonedEntity:
            .deleteProtectedFacts
        case .correctWeight, .correctTransfer, .correctRemoval:
            .editHistoricalFacts
        case .addIngredient, .createRecipe, .addRecipeComponent, .createBreedingProgram:
            .manageCatalogs
        case .care(let command):
            command.requiredCapability
        default:
            .recordProduction
        }
    }

    var operationKind: DomainOperationKind {
        switch self {
        case .updateFarmLocation: .updateFarmLocation
        case .createPen: .createPen
        case .updatePen: .updatePen
        case .setPenActive: .setPenActive
        case .addSheep: .addSheep
        case .updateSheepProfile: .updateSheepProfile
        case .recordWeight: .recordWeight
        case .correctWeight: .correctWeight
        case .recordWeaning: .recordWeaning
        case .createBreedingProgram: .createBreedingProgram
        case .transferSheep: .transferSheep
        case .correctTransfer: .correctTransfer
        case .removeSheep: .removeSheep
        case .correctRemoval: .correctRemoval
        case .restoreSheep: .restoreSheep
        case .createBatch: .createBatch
        case .assignSheepToBatch: .assignBatchMembership
        case .leaveBatch: .leaveBatchMembership
        case .addIngredient: .addIngredient
        case .createRecipe: .createRecipe
        case .addRecipeComponent: .addRecipeComponent
        case .recordFeed: .recordFeed
        case .recordHealth: .recordHealth
        case .receiveInventory: .receiveInventory
        case .addSemen: .addSemen
        case .recordReproduction: .recordReproduction
        case .care: .care
        case .addNote: .addNote
        case .tombstoneEntity: .tombstoneEntity
        case .restoreTombstonedEntity: .restoreTombstonedEntity
        }
    }

    var summary: String {
        switch self {
        case .updateFarmLocation: "更新牧场固定位置"
        case .createPen(let name, _): "新建圈舍：\(name)"
        case .updatePen(_, let name, _): "更新圈舍：\(name)"
        case .setPenActive(_, let active): active ? "重新启用圈舍" : "停用圈舍"
        case .addSheep(let earTag, _, _, _, _, _, _): "新建羊只：\(earTag)"
        case .updateSheepProfile(_, let earTag, _, _, _, _): "更新羊只档案：\(earTag)"
        case .recordWeight: "记录称重"
        case .correctWeight: "修正称重记录"
        case .recordWeaning: "记录断奶"
        case .createBreedingProgram(let name, _, _): "新建配种方案：\(name)"
        case .transferSheep: "记录转群"
        case .correctTransfer: "修正转群记录"
        case .removeSheep(_, let kind, _, _, _, _, _, _, _): "记录\(kind.displayName)"
        case .correctRemoval(_, let kind, _, _, _, _, _): "修正\(kind.displayName)记录"
        case .restoreSheep: "恢复离场羊只"
        case .createBatch(let name, _, _, _, _): "新建生产批次：\(name)"
        case .assignSheepToBatch: "加入生产批次"
        case .leaveBatch: "离开生产批次"
        case .addIngredient(let name, _, _): "新增原料：\(name)"
        case .createRecipe(let name, _): "新建配方：\(name)"
        case .addRecipeComponent: "更新配方组成"
        case .recordFeed: "记录投喂"
        case .recordHealth: "记录健康事项"
        case .receiveInventory(let catalogName, _, _, _, _, _): "入库：\(catalogName)"
        case .addSemen(let code, _, _, _, _): "新增冻精：\(code)"
        case .recordReproduction(_, let kind, _, _, _, _, _, _, _, _, _): "记录\(kind.displayName)"
        case .care(let command): command.summary
        case .addNote: "添加备注"
        case .tombstoneEntity: "删除权威记录"
        case .restoreTombstonedEntity: "恢复已删除记录"
        }
    }
}

@MainActor
final class FarmCommandService {
    private struct HistoryImpact {
        let sheepID: UUID
        let changedAt: Date
        let deletion: FarmHistoryDeletion?

        init(
            sheepID: UUID,
            changedAt: Date,
            deletion: FarmHistoryDeletion? = nil
        ) {
            self.sheepID = sheepID
            self.changedAt = changedAt
            self.deletion = deletion
        }
    }

    private let historyRebuilder: FarmHistoryRebuilder
    private let historyRebuildObserver: ((Set<UUID>, Date) -> Void)?

    init(
        historyRebuilder: FarmHistoryRebuilder = FarmHistoryRebuilder(),
        historyRebuildObserver: ((Set<UUID>, Date) -> Void)? = nil
    ) {
        self.historyRebuilder = historyRebuilder
        self.historyRebuildObserver = historyRebuildObserver
    }
    func createFarm(
        named name: String,
        account: AccountProfile,
        entitlement: AccountEntitlement,
        context: ModelContext
    ) throws -> FarmRecord {
        let trimmedName = try required(name, label: "牧场名称")
        let existingOwnedFarmCount = try context.fetch(FetchDescriptor<FarmRecord>()).count {
            $0.ownerAccountID == account.effectiveAccountID &&
            $0.deletedAt == nil
        }
        guard SubscriptionCapabilityPolicy.canCreateFarm(
            existingOwnedFarmCount: existingOwnedFarmCount,
            entitlement: entitlement
        ) else {
            throw FarmCreationEntitlementError.additionalFarmRequiresFarmPro
        }
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: trimmedName)
        context.insert(farm)
        let payload = try JSONEncoder.cloud.encode(["name": trimmedName])
        let operation = DomainOperation(
            farmID: farm.id,
            accountID: account.effectiveAccountID,
            kind: .createFarm,
            summary: "新建牧场：\(trimmedName)",
            entityType: CloudEntityType.farm.rawValue,
            entityID: farm.id,
            payload: payload
        )
        context.insert(operation)
        context.insert(OutboxItem(
            farmID: farm.id,
            accountID: account.effectiveAccountID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID,
            baseRevision: operation.baseRevision,
            payloadDigest: operation.payloadDigest
        ))
        try context.save()
        CloudRuntimeNotification.postSyncWake(farmID: farm.id)
        return farm
    }

    func execute(_ command: FarmCommand, in farm: FarmContext, context: ModelContext) throws {
        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        try validateCloudIdentity(in: farm, context: context)
        if let impact = try executeWithoutSaving(command, in: farm, context: context) {
            try rebuildHistoryIfNeeded(for: [impact], farmID: farm.farmID, context: context)
        }
        try context.save()
        committed = true
        CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
    }

    func execute(
        _ command: FarmCommand,
        in farm: FarmContext,
        context: ModelContext,
        sourceRequestID: UUID
    ) throws -> FarmCommandExecutionReceipt {
        if let existing = try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).first(where: {
            $0.sourceRequestID == sourceRequestID &&
                $0.accountID == farm.accountID &&
                $0.farmID == farm.farmID
        }) {
            return FarmCommandExecutionReceipt(
                sourceRequestID: existing.sourceRequestID,
                operationID: existing.operationID,
                entityType: existing.entityType,
                entityID: existing.entityID,
                createdAt: existing.createdAt
            )
        }

        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        try validateCloudIdentity(in: farm, context: context)
        if let impact = try executeWithoutSaving(
            command,
            in: farm,
            context: context,
            sourceRequestID: sourceRequestID
        ) {
            try rebuildHistoryIfNeeded(for: [impact], farmID: farm.farmID, context: context)
        }
        guard let operation = try context.fetch(FetchDescriptor<DomainOperation>()).first(where: {
            $0.sourceRequestID == sourceRequestID &&
                $0.accountID == farm.accountID &&
                $0.farmID == farm.farmID
        }) else {
            throw FarmCommandError.sourceRecordNotFound
        }
        let receiptRecord = InsightExecutionReceiptRecord(
            sourceRequestID: sourceRequestID,
            accountID: farm.accountID,
            farmID: farm.farmID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID
        )
        context.insert(receiptRecord)
        try context.save()
        committed = true
        CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        return FarmCommandExecutionReceipt(
            sourceRequestID: sourceRequestID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID,
            createdAt: receiptRecord.createdAt
        )
    }

    /// Excel 等批量入口使用同一个权威写入管道，但整批只保存一次。
    /// 任一命令失败都会回滚本批已插入的事实、审计记录和 Outbox，避免半导入。
    func executeBatch(_ commands: [FarmCommand], in farm: FarmContext, context: ModelContext) throws {
        guard !commands.isEmpty else { return }
        var index = 0
        try performBatch(in: farm, context: context) {
            guard commands.indices.contains(index) else { return nil }
            defer { index += 1 }
            return commands[index]
        }
    }

    /// AI 操作草案批量执行入口。所有命令、幂等回执和 Outbox 在同一次保存中提交；
    /// 任一命令失败都会回滚整批，避免一批草案只执行一部分。
    func executeBatch(
        _ requests: [(command: FarmCommand, sourceRequestID: UUID)],
        in farm: FarmContext,
        context: ModelContext
    ) throws -> [FarmCommandExecutionReceipt] {
        guard !requests.isEmpty else { return [] }
        guard Set(requests.map(\.sourceRequestID)).count == requests.count else {
            throw FarmCommandError.invalidRemovalBatch("操作草案标识重复")
        }

        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        try validateCloudIdentity(in: farm, context: context)

        var pendingHistory: [HistoryImpact] = []
        var receiptBySourceRequestID: [UUID: FarmCommandExecutionReceipt] = [:]

        func flushHistory() throws {
            guard !pendingHistory.isEmpty else { return }
            try rebuildHistoryIfNeeded(
                for: pendingHistory,
                farmID: farm.farmID,
                context: context
            )
            pendingHistory.removeAll(keepingCapacity: true)
        }

        for request in requests {
            if let existing = try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>())
                .first(where: {
                    $0.sourceRequestID == request.sourceRequestID &&
                        $0.accountID == farm.accountID &&
                        $0.farmID == farm.farmID
                }) {
                receiptBySourceRequestID[request.sourceRequestID] = FarmCommandExecutionReceipt(
                    sourceRequestID: existing.sourceRequestID,
                    operationID: existing.operationID,
                    entityType: existing.entityType,
                    entityID: existing.entityID,
                    createdAt: existing.createdAt
                )
                continue
            }
            if !affectsHistoryProjection(request.command) {
                try flushHistory()
            }
            if let impact = try executeWithoutSaving(
                request.command,
                in: farm,
                context: context,
                sourceRequestID: request.sourceRequestID
            ) {
                pendingHistory.append(impact)
            }
        }
        try flushHistory()

        for request in requests where receiptBySourceRequestID[request.sourceRequestID] == nil {
            guard let operation = try context.fetch(FetchDescriptor<DomainOperation>())
                .first(where: {
                    $0.sourceRequestID == request.sourceRequestID &&
                        $0.accountID == farm.accountID &&
                        $0.farmID == farm.farmID
                }) else {
                throw FarmCommandError.sourceRecordNotFound
            }
            let record = InsightExecutionReceiptRecord(
                sourceRequestID: request.sourceRequestID,
                accountID: farm.accountID,
                farmID: farm.farmID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID
            )
            context.insert(record)
            receiptBySourceRequestID[request.sourceRequestID] = FarmCommandExecutionReceipt(
                sourceRequestID: request.sourceRequestID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID,
                createdAt: record.createdAt
            )
        }

        try context.save()
        committed = true
        CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        return try requests.map { request in
            guard let receipt = receiptBySourceRequestID[request.sourceRequestID] else {
                throw FarmCommandError.sourceRecordNotFound
            }
            return receipt
        }
    }

    /// 允许批量导入在上一条主数据命令生效后解析下一条引用，同时仍保持一次保存、整批回滚。
    func executeBatch(in farm: FarmContext, context: ModelContext, nextCommand: () throws -> FarmCommand?) throws {
        try performBatch(in: farm, context: context, nextCommand: nextCommand)
    }

    private func performBatch(in farm: FarmContext, context: ModelContext, nextCommand: () throws -> FarmCommand?) throws {
        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        try validateCloudIdentity(in: farm, context: context)
        var pendingHistory: [HistoryImpact] = []

        func flushHistory() throws {
            guard !pendingHistory.isEmpty else { return }
            try rebuildHistoryIfNeeded(for: pendingHistory, farmID: farm.farmID, context: context)
            pendingHistory.removeAll(keepingCapacity: true)
        }

        while let command = try nextCommand() {
            // 连续的羊只时间线命令共享一次投影重建。遇到其他业务命令时先刷新，
            // 保证后续校验仍能看到与逐条执行一致的在场状态和圈舍投影。
            if !affectsHistoryProjection(command) {
                try flushHistory()
            }
            if let impact = try executeWithoutSaving(command, in: farm, context: context) {
                pendingHistory.append(impact)
            }
        }
        try flushHistory()
        try context.save()
        committed = true
        CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
    }

    private func validateCloudIdentity(in farm: FarmContext, context: ModelContext) throws {
        let farmID = farm.farmID
        let accountID = farm.accountID
        let cloudBinding = try context.fetch(FetchDescriptor<CloudFarmBinding>(predicate: #Predicate {
            $0.farmID == farmID
        })).first
        if let cloudBinding {
            let hasUsableCertificate = try context.fetch(FetchDescriptor<CapabilityCertificateRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.accountID == accountID
            })).contains(where: \.isUsable)
            guard cloudBinding.state == .active, hasUsableCertificate else { throw FarmCommandError.cloudIdentityLocked }
        }
    }

    private func executeWithoutSaving(
        _ command: FarmCommand,
        in farm: FarmContext,
        context: ModelContext,
        sourceRequestID: UUID? = nil
    ) throws -> HistoryImpact? {
        let farmID = farm.farmID
        guard farm.capabilities.allows(command.requiredCapability) else {
            throw FarmPermissionError.denied(command.requiredCapability)
        }

        try validate(command, farmID: farm.farmID, context: context)
        let result = try apply(command, farm: farm, context: context)
        let projectedHistoryImpact = try historyImpact(for: command, result: result, farmID: farm.farmID, context: context)
        let operation = DomainOperation(
            farmID: farm.farmID,
            accountID: farm.accountID,
            kind: command.operationKind,
            summary: command.summary,
            entityType: result.entityType,
            entityID: result.entityID,
            baseRevision: result.baseRevision,
            resultingRevision: result.resultingRevision,
            payload: result.payload,
            sourceRequestID: sourceRequestID
        )
        context.insert(operation)
        switch command {
        case .tombstoneEntity(_, let entityID, _):
            let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.entityID == entityID && $0.operationID == nil
            }))
            if let tombstone = tombstones.first {
                tombstone.operationID = operation.id
            }
        case .restoreTombstonedEntity(let tombstoneID):
            let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
                $0.id == tombstoneID
            }))
            if let tombstone = tombstones.first {
                tombstone.restoredByOperationID = operation.id
                tombstone.restoredAt = Date.now
            }
        case .correctWeight(let originalID, _, _, _, _),
             .correctTransfer(let originalID, _, _, _, _),
             .correctRemoval(let originalID, _, _, _, _, _, _):
            let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.entityID == originalID && $0.operationID == nil
            }))
            if let tombstone = tombstones.first {
                tombstone.operationID = operation.id
            }
        case .care(let careCommand):
            let originalID: UUID?
            switch careCommand {
            case .correctHealth(let id, _, _), .correctReproduction(let id, _, _): originalID = id
            default: originalID = nil
            }
            if let originalID {
                let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.entityID == originalID && $0.operationID == nil
                }))
                if let tombstone = tombstones.first { tombstone.operationID = operation.id }
            }
        default:
            break
        }
        context.insert(OutboxItem(
            farmID: farm.farmID,
            accountID: farm.accountID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID,
            baseRevision: operation.baseRevision,
            payloadDigest: operation.payloadDigest
        ))
        return projectedHistoryImpact
    }

    private func affectsHistoryProjection(_ command: FarmCommand) -> Bool {
        switch command {
        case .addSheep, .transferSheep, .correctTransfer, .removeSheep, .correctRemoval, .restoreSheep:
            true
        case .tombstoneEntity(let entityType, _, _):
            entityType == .sheep || entityType == .transfer || entityType == .removal
        case .restoreTombstonedEntity:
            true
        default:
            false
        }
    }

    private func historyImpact(
        for command: FarmCommand,
        result: AppliedCommandResult,
        farmID: UUID,
        context: ModelContext
    ) throws -> HistoryImpact? {
        let impact: HistoryImpact?
        switch command {
        case .addSheep(_, _, _, _, let occurredAt, _, _):
            impact = HistoryImpact(sheepID: result.entityID, changedAt: occurredAt)
        case .transferSheep(let sheepID, _, let occurredAt, _):
            impact = HistoryImpact(sheepID: sheepID, changedAt: occurredAt)
        case .correctTransfer(let originalID, _, let occurredAt, _, _):
            guard let original = try transferRecord(id: originalID, farmID: farmID, context: context) else { return nil }
            impact = HistoryImpact(sheepID: original.sheepID, changedAt: min(original.occurredAt, occurredAt))
        case .removeSheep(let sheepID, _, _, _, let occurredAt, _, _, _, _):
            impact = HistoryImpact(sheepID: sheepID, changedAt: occurredAt)
        case .correctRemoval(let originalID, _, _, _, let occurredAt, _, _):
            guard let original = try removalRecord(id: originalID, farmID: farmID, context: context) else { return nil }
            impact = HistoryImpact(sheepID: original.sheepID, changedAt: min(original.occurredAt, occurredAt))
        case .restoreSheep(let removalID):
            impact = try historyImpact(entityType: .removal, entityID: removalID, farmID: farmID, context: context)
                .map { HistoryImpact(sheepID: $0.sheepID, changedAt: $0.changedAt) }
        case .tombstoneEntity(let entityType, let entityID, _):
            impact = try historyImpact(entityType: entityType, entityID: entityID, farmID: farmID, context: context)
                .map {
                    HistoryImpact(
                        sheepID: $0.sheepID,
                        changedAt: $0.changedAt,
                        deletion: FarmHistoryDeletion(entityType: entityType, entityID: entityID)
                    )
                }
        case .restoreTombstonedEntity(let tombstoneID):
            guard let tombstone = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
                $0.id == tombstoneID && $0.farmID == farmID
            })).first,
                  let entityType = CloudEntityType(rawValue: tombstone.entityType) else { return nil }
            impact = try historyImpact(entityType: entityType, entityID: tombstone.entityID, farmID: farmID, context: context)
                .map { HistoryImpact(sheepID: $0.sheepID, changedAt: $0.changedAt) }
        default:
            impact = nil
        }

        return impact
    }

    private func rebuildHistoryIfNeeded(
        for impacts: [HistoryImpact],
        farmID: UUID,
        context: ModelContext
    ) throws {
        guard !impacts.isEmpty, let changedAt = impacts.map(\.changedAt).min() else { return }
        let sheepIDs = Set(impacts.map(\.sheepID))
        let deletion = impacts.count == 1 ? impacts[0].deletion : nil
        historyRebuildObserver?(sheepIDs, changedAt)
        try historyRebuilder.rebuildAffectedSheep(
            farmID: farmID,
            sheepIDs: sheepIDs,
            context: context,
            from: changedAt,
            deletion: deletion
        )
    }

    private func historyImpact(
        entityType: CloudEntityType,
        entityID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> (sheepID: UUID, changedAt: Date)? {
        switch entityType {
        case .sheep:
            let records = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.id == entityID && $0.farmID == farmID
            }))
            return records.first.map { ($0.id, $0.enteredAt) }
        case .transfer:
            return try transferRecord(id: entityID, farmID: farmID, context: context)
                .map { ($0.sheepID, $0.occurredAt) }
        case .removal:
            return try removalRecord(id: entityID, farmID: farmID, context: context)
                .map { ($0.sheepID, $0.occurredAt) }
        default:
            return nil
        }
    }

    private func transferRecord(id: UUID, farmID: UUID, context: ModelContext) throws -> TransferRecord? {
        try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.id == id && $0.farmID == farmID
        })).first
    }

    private func removalRecord(id: UUID, farmID: UUID, context: ModelContext) throws -> RemovalRecord? {
        try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.id == id && $0.farmID == farmID
        })).first
    }

    @discardableResult
    func resolveConflict(conflictID: UUID, decision: ConflictResolutionDecision, note: String, in farm: FarmContext, context: ModelContext) throws -> UUID {
        guard farm.capabilities.allows(.resolveConflicts) else { throw FarmPermissionError.denied(.resolveConflicts) }
        guard let conflict = try context.fetch(FetchDescriptor<SyncConflictRecord>()).first(where: { $0.id == conflictID && $0.farmID == farm.farmID }) else { throw ConflictResolutionError.conflictMissing }
        guard conflict.statusRawValue == SyncConflictStatus.unresolved.rawValue || conflict.statusRawValue == SyncConflictStatus.quarantined.rawValue else { throw ConflictResolutionError.alreadyResolved }
        let resolvedPayload: Data
        let status: SyncConflictStatus
        switch decision {
        case .acceptLocal:
            guard !conflict.localPayload.isEmpty else { throw ConflictResolutionError.localPayloadMissing }
            resolvedPayload = conflict.localPayload
            status = .acceptedLocal
        case .acceptRemote:
            resolvedPayload = conflict.remotePayload
            status = .acceptedRemote
        case .mergeText(let text):
            resolvedPayload = try ConflictDomainMergeService.mergedTextPayload(from: conflict.remotePayload, text: text)
            status = .ownerResolved
        }
        let revision = max(conflict.localRevision, conflict.remoteRevision) + 1
        let changedAt = try ConflictDomainMergeService.apply(payload: resolvedPayload, entityType: conflict.entityType, entityID: conflict.entityID, farmID: farm.farmID, revision: revision, context: context)
        if let changedAt { try historyRebuilder.rebuild(farmID: farm.farmID, context: context, from: changedAt) }
        var operationPayload = FarmCommandCloudPayload(kind: .resolveConflict)
        operationPayload.identifiers = ["conflictID": conflict.id, "entityID": conflict.entityID]
        operationPayload.strings = ["entityType": conflict.entityType, "decision": status.rawValue, "note": note]
        operationPayload.integers = ["localRevision": conflict.localRevision, "remoteRevision": conflict.remoteRevision, "resolvedRevision": revision]
        operationPayload.dataValues = ["resolvedPayload": resolvedPayload]
        let payload = try JSONEncoder.cloud.encode(operationPayload)
        let operation = DomainOperation(farmID: farm.farmID, accountID: farm.accountID, kind: .resolveConflict, summary: "解决同步冲突", entityType: conflict.entityType, entityID: conflict.entityID, baseRevision: max(conflict.localRevision, conflict.remoteRevision), resultingRevision: revision, payload: payload)
        context.insert(operation)
        context.insert(OutboxItem(farmID: farm.farmID, accountID: farm.accountID, operationID: operation.id, entityType: operation.entityType, entityID: operation.entityID, baseRevision: operation.baseRevision, payloadDigest: operation.payloadDigest))
        conflict.statusRawValue = status.rawValue
        conflict.resolutionNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        conflict.resolutionOperationID = operation.id
        conflict.resolvedByAccountID = farm.accountID
        conflict.resolvedAt = .now
        conflict.resolutionFailureReason = nil
        try context.save()
        CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        return operation.id
    }

    private func validate(_ command: FarmCommand, farmID: UUID, context: ModelContext) throws {
        switch command {
        case .care:
            break
        case .updateFarmLocation(let displayName, let latitude, let longitude, _, let timeZoneIdentifier, _, let accuracy):
            _ = try required(displayName, label: "牧场地点名称")
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw FarmCommandError.invalidFarmCoordinate }
            guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw FarmCommandError.invalidFarmTimeZone }
            if let accuracy, accuracy < 0 { throw FarmCommandError.invalidNumber("定位精度") }
        case .createPen(let name, _):
            _ = try required(name, label: "圈舍名称")
        case .updatePen(let penID, let name, _):
            try assertPen(penID, farmID: farmID, context: context, includeInactive: true)
            _ = try required(name, label: "圈舍名称")
        case .setPenActive(let penID, let isActive):
            try assertPen(penID, farmID: farmID, context: context, includeInactive: true)
            if !isActive {
                let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                guard !sheep.contains(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.currentPenID == penID }) else {
                    throw FarmCommandError.penHasCurrentSheep
                }
            }
        case .addSheep(let earTag, let breed, _, let penID, _, _, _):
            let normalizedTag = try required(earTag, label: "耳号")
            _ = try required(breed, label: "品种")
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            guard !sheep.contains(where: { $0.farmID == farmID && EarTag.normalized($0.earTag) == EarTag.normalized(normalizedTag) }) else {
                throw FarmCommandError.duplicateEarTag
            }
            if let penID { try assertPen(penID, farmID: farmID, context: context) }
        case .updateSheepProfile(let sheepID, let earTag, let breed, _, _, _):
            let current = try sheepRecord(sheepID, farmID: farmID, context: context)
            let normalizedTag = try required(earTag, label: "耳号")
            _ = try required(breed, label: "品种")
            if EarTag.normalized(current.earTag) != EarTag.normalized(normalizedTag) {
                let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.deletedAt == nil
                }))
                guard !sheep.contains(where: {
                    $0.id != sheepID && EarTag.normalized($0.earTag) == EarTag.normalized(normalizedTag)
                }) else { throw FarmCommandError.duplicateEarTag }
            }
        case .recordWeight(let sheepID, let kilogramsText, _, _):
            try assertSheep(sheepID, farmID: farmID, context: context)
            try positiveDecimal(kilogramsText, label: "体重")
        case .correctWeight(let originalID, let kilogramsText, _, _, let reason):
            guard try context.fetch(FetchDescriptor<WeightRecord>()).contains(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.sourceRecordNotFound
            }
            try positiveDecimal(kilogramsText, label: "体重")
            _ = try required(reason, label: "修正原因")
        case .recordWeaning(let sheepID, let weanWeightText, _, _, let birthWeightText, let averageDailyGainText, let damID, let litterSize, _):
            try assertSheep(sheepID, farmID: farmID, context: context)
            try positiveDecimal(weanWeightText, label: "断奶重")
            if let birthWeightText, !birthWeightText.isEmpty { try positiveDecimal(birthWeightText, label: "出生重") }
            if let averageDailyGainText, !averageDailyGainText.isEmpty { try positiveDecimal(averageDailyGainText, label: "日增重") }
            if let litterSize { guard litterSize > 0 else { throw FarmCommandError.invalidNumber("胎只数") } }
            if let damID {
                guard damID != sheepID else { throw FarmCommandError.weaningDamMustBeEwe }
                let dam = try sheepRecord(damID, farmID: farmID, context: context)
                guard dam.sex == .ewe else { throw FarmCommandError.weaningDamMustBeEwe }
            }
        case .createBreedingProgram(let name, _, let steps):
            _ = try required(name, label: "方案名称")
            guard !steps.isEmpty else { throw FarmCommandError.missingRequiredValue("方案步骤") }
            for step in steps {
                guard step.dayOffset >= 0 else { throw FarmCommandError.invalidNumber("步骤日龄") }
                _ = try required(step.action, label: "步骤操作")
            }
        case .transferSheep(let sheepID, let toPenID, _, _):
            try assertSheep(sheepID, farmID: farmID, context: context)
            if let toPenID { try assertPen(toPenID, farmID: farmID, context: context) }
        case .correctTransfer(let originalID, let toPenID, _, _, let reason):
            guard try context.fetch(FetchDescriptor<TransferRecord>()).contains(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.sourceRecordNotFound
            }
            if let toPenID { try assertPen(toPenID, farmID: farmID, context: context) }
            _ = try required(reason, label: "修正原因")
        case .removeSheep(let sheepID, let kind, let reason, let amountText, let occurredAt, let note, _, let removalBatchID, let batchTotalAmountText):
            try assertSheep(sheepID, farmID: farmID, context: context)
            let normalizedReason = try required(reason, label: "离场原因")
            if let amountText, !amountText.isEmpty { try positiveDecimal(amountText, label: "金额") }
            if let removalBatchID {
                guard amountText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                    throw FarmCommandError.invalidRemovalBatch("同批离场只能记录批次总额，不能填写单羊金额。")
                }
                let normalizedTotal = batchTotalAmountText?.trimmingCharacters(in: .whitespacesAndNewlines)
                if kind == .sold {
                    guard let normalizedTotal, !normalizedTotal.isEmpty else {
                        throw FarmCommandError.missingRequiredValue("总售卖金额")
                    }
                    try positiveDecimal(normalizedTotal, label: "总售卖金额")
                } else if normalizedTotal?.isEmpty == false {
                    throw FarmCommandError.invalidRemovalBatch("只有出售批次可以填写总售卖金额。")
                }
                let existingBatch = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.removalBatchID == removalBatchID && $0.deletedAt == nil
                }))
                let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                let stableTotal = normalizedTotal.flatMap { $0.isEmpty ? nil : Decimal.stable($0)?.stableText }
                guard existingBatch.allSatisfy({
                    $0.kind == kind &&
                        $0.reason == normalizedReason &&
                        $0.occurredAt == occurredAt &&
                        $0.note == normalizedNote &&
                        $0.batchTotalAmountText == stableTotal
                }) else {
                    throw FarmCommandError.invalidRemovalBatch("同一批次的类型、原因、日期、备注和总额必须一致。")
                }
            } else if batchTotalAmountText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                throw FarmCommandError.invalidRemovalBatch("总售卖金额必须关联离场批次。")
            }
        case .correctRemoval(let originalID, _, let reason, let amountText, _, _, let correctionReason):
            guard let original = try context.fetch(FetchDescriptor<RemovalRecord>()).first(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.sourceRecordNotFound
            }
            _ = try required(reason, label: "离场原因")
            _ = try required(correctionReason, label: "修正原因")
            if let amountText, !amountText.isEmpty { try positiveDecimal(amountText, label: "金额") }
            if original.removalBatchID != nil, amountText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                throw FarmCommandError.invalidRemovalBatch("同批出栏总价不能在单羊修正中改写。")
            }
        case .restoreSheep(let removalID):
            let removals = try context.fetch(FetchDescriptor<RemovalRecord>())
            guard removals.contains(where: { $0.id == removalID && $0.farmID == farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.removalNotFound
            }
        case .createBatch(let name, let purpose, let startedAt, let sheepIDs, _):
            _ = try required(name, label: "批次名称")
            _ = try required(purpose, label: "生产目的")
            guard !sheepIDs.isEmpty else { throw FarmCommandError.missingRequiredValue("批次羊只") }
            guard Set(sheepIDs).count == sheepIDs.count else { throw FarmCommandError.duplicateBatchMembership }
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }))
            let sheepByID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
            let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }))
            let unavailableIDs = Set(memberships.lazy.filter { $0.leftAt == nil }.map(\.sheepID))
            for sheepID in sheepIDs {
                guard let item = sheepByID[sheepID], item.isCurrentlyPresent else { throw FarmCommandError.sheepNotFound }
                guard item.enteredAt <= startedAt else { throw FarmCommandError.missingRequiredValue("不早于羊只入场时间的批次开始时间") }
                guard !unavailableIDs.contains(sheepID) else { throw FarmCommandError.duplicateBatchMembership }
            }
        case .assignSheepToBatch(let batchID, let sheepID, _):
            try assertBatch(batchID, farmID: farmID, context: context)
            try assertSheep(sheepID, farmID: farmID, context: context)
            let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>())
            guard !memberships.contains(where: { $0.farmID == farmID && $0.batchID == batchID && $0.sheepID == sheepID && $0.deletedAt == nil && $0.leftAt == nil }) else {
                throw FarmCommandError.duplicateBatchMembership
            }
        case .leaveBatch(let batchID, let sheepID, let leftAt, let reason):
            let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>())
            guard let membership = memberships.first(where: { $0.farmID == farmID && $0.batchID == batchID && $0.sheepID == sheepID && $0.deletedAt == nil && $0.leftAt == nil }) else {
                throw FarmCommandError.batchMembershipNotFound
            }
            guard leftAt >= membership.joinedAt else { throw FarmCommandError.missingRequiredValue("不早于批次开始时间的脱离时间") }
            _ = try required(reason, label: "脱离原因")
        case .addIngredient(let name, let unit, let dryMatterText):
            _ = try required(name, label: "原料名称")
            _ = try required(unit, label: "单位")
            if let dryMatterText, !dryMatterText.isEmpty { try positiveDecimal(dryMatterText, label: "干物质") }
        case .createRecipe(let name, _):
            _ = try required(name, label: "配方名称")
        case .addRecipeComponent(let recipeID, let ingredientID, let kilogramsText):
            try assertRecipe(recipeID, farmID: farmID, context: context)
            try assertIngredient(ingredientID, farmID: farmID, context: context)
            try positiveDecimal(kilogramsText, label: "配方用量")
        case .recordFeed(let penID, let recipeID, _, _, let lines, _):
            try assertPen(penID, farmID: farmID, context: context)
            if let recipeID { try assertRecipe(recipeID, farmID: farmID, context: context) }
            guard !lines.isEmpty else { throw FarmCommandError.missingRequiredValue("投喂明细") }
            for line in lines {
                try assertIngredient(line.ingredientID, farmID: farmID, context: context)
                if let batchID = line.ingredientBatchID {
                    _ = try feedIngredientBatchRecord(batchID, ingredientID: line.ingredientID, farmID: farmID, context: context)
                }
                try positiveDecimal(line.kilogramsText, label: "投喂数量")
            }
        case .recordHealth(let sheepID, let penID, _, let itemName, _, _, let inventoryLotID, let quantityText):
            guard sheepID != nil || penID != nil else { throw FarmCommandError.missingRequiredValue("羊只或圈舍") }
            if let sheepID { try assertSheep(sheepID, farmID: farmID, context: context) }
            if let penID { try assertPen(penID, farmID: farmID, context: context) }
            _ = try required(itemName, label: "药品或疫苗名称")
            if let quantityText, !quantityText.isEmpty { try positiveDecimal(quantityText, label: "用量") }
            if let inventoryLotID {
                let lot = try inventoryLot(inventoryLotID, farmID: farmID, context: context)
                if let quantityText, !quantityText.isEmpty {
                    let balance = try inventoryBalance(for: lot, context: context)
                    let requested = Decimal.stable(quantityText) ?? 0
                    guard balance >= requested else { throw FarmCommandError.insufficientInventory }
                }
            }
        case .receiveInventory(let catalogName, _, _, let quantityText, _, _):
            _ = try required(catalogName, label: "药品或疫苗名称")
            try positiveDecimal(quantityText, label: "入库数量")
        case .addSemen(let code, let breed, _, _, let quantityText):
            let trimmedCode = try required(code, label: "冻精编号")
            _ = try required(breed, label: "品种")
            try positiveDecimal(quantityText, label: "库存数量")
            let semen = try context.fetch(FetchDescriptor<SemenRecord>())
            guard !semen.contains(where: { $0.farmID == farmID && $0.deletedAt == nil && $0.code.caseInsensitiveCompare(trimmedCode) == .orderedSame }) else {
                throw FarmCommandError.missingRequiredValue("唯一冻精编号")
            }
        case .recordReproduction(let eweID, let kind, _, let sireID, let semenName, _, let lambCount, let parity, let birthDeadCount, let offspring, _):
            let ewe = try sheepRecord(eweID, farmID: farmID, context: context)
            guard ewe.sex == .ewe else { throw FarmCommandError.reproductionSubjectMustBeEwe }
            if let sireID {
                let sire = try sheepRecord(sireID, farmID: farmID, context: context)
                guard sire.sex == .ram else { throw FarmCommandError.reproductionSireMustBeRam }
            }
            if kind == .breeding && sireID == nil && (semenName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                throw FarmCommandError.invalidReproductionRecord
            }
            if kind == .pregnancyCheck && (sireID != nil || !(semenName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) {
                throw FarmCommandError.pregnancyCheckCannotSetPaternity
            }
            if kind == .lambing {
                guard lambCount >= 1,
                      parity.map({ $0 >= 1 }) == true,
                      birthDeadCount.map({ $0 >= 0 && $0 <= lambCount }) == true,
                      offspring.count == lambCount else {
                    throw FarmCommandError.invalidReproductionRecord
                }
                let normalizedTags = offspring.map { EarTag.normalized($0.earTag) }
                guard normalizedTags.allSatisfy({ !$0.isEmpty }), Set(normalizedTags).count == normalizedTags.count else {
                    throw FarmCommandError.invalidReproductionRecord
                }
                for detail in offspring {
                    try positiveDecimal(detail.birthWeightText, label: "羔羊初生重")
                    if let sheepID = detail.sheepID {
                        let sheep = try sheepRecord(sheepID, farmID: farmID, context: context)
                        guard EarTag.normalized(sheep.earTag) == EarTag.normalized(detail.earTag) else {
                            throw FarmCommandError.invalidReproductionRecord
                        }
                    }
                }
            } else if !offspring.isEmpty {
                throw FarmCommandError.invalidReproductionRecord
            }
        case .addNote(let sheepID, let penID, let text, _):
            guard sheepID != nil || penID != nil else { throw FarmCommandError.missingRequiredValue("羊只或圈舍") }
            if let sheepID { try assertSheep(sheepID, farmID: farmID, context: context) }
            if let penID { try assertPen(penID, farmID: farmID, context: context) }
            _ = try required(text, label: "备注内容")
        case .tombstoneEntity(let entityType, let entityID, let reason):
            _ = try required(reason, label: "删除原因")
            guard try entityExists(type: entityType, id: entityID, farmID: farmID, context: context) else {
                throw FarmCommandError.missingRequiredValue("可删除的权威记录")
            }
            if entityType == .pen {
                let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                let transfers = try context.fetch(FetchDescriptor<TransferRecord>())
                let hasReferences = sheep.contains { $0.farmID == farmID && ($0.currentPenID == entityID || $0.initialPenID == entityID) }
                    || transfers.contains { $0.farmID == farmID && ($0.fromPenID == entityID || $0.toPenID == entityID) }
                guard !hasReferences else { throw FarmCommandError.protectedPenReferences }
            }
            if entityType == .sheep {
                guard try !hasSheepReferences(entityID, farmID: farmID, context: context) else {
                    throw FarmCommandError.protectedSheepReferences
                }
            }
            if entityType == .inventoryTransaction,
               let transaction = try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).first(where: {
                   $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
               }) {
                let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).filter {
                    $0.farmID == farmID && $0.inventoryLotID == transaction.inventoryLotID && $0.deletedAt == nil
                }
                let balance = transactions.reduce(Decimal.zero) { $0 + inventoryContribution($1) }
                guard balance - inventoryContribution(transaction) >= 0 else {
                    throw FarmCommandError.insufficientInventory
                }
            }
            if entityType == .semenTransaction,
               let transaction = try context.fetch(FetchDescriptor<SemenTransactionRecord>()).first(where: {
                   $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
               }) {
                let semen = try context.fetch(FetchDescriptor<SemenRecord>()).first {
                    $0.id == transaction.semenID && $0.farmID == farmID
                }
                let initial = Decimal.stable(semen?.quantityText ?? "") ?? 0
                let transactions = try context.fetch(FetchDescriptor<SemenTransactionRecord>()).filter {
                    $0.farmID == farmID && $0.semenID == transaction.semenID && $0.deletedAt == nil
                }
                let balance = transactions.reduce(initial) { $0 + semenContribution($1) }
                guard balance - semenContribution(transaction) >= 0 else {
                    throw FarmCommandError.insufficientInventory
                }
            }
        case .restoreTombstonedEntity(let tombstoneID):
            guard let tombstone = try context.fetch(FetchDescriptor<TombstoneRecord>()).first(where: { $0.id == tombstoneID && $0.farmID == farmID && $0.restoredAt == nil }) else {
                throw FarmCommandError.missingRequiredValue("可恢复的删除记录")
            }
            guard CloudEntityType(rawValue: tombstone.entityType) != nil else { throw FarmCommandError.missingRequiredValue("可恢复的实体类型") }
        }
    }

    private func apply(_ command: FarmCommand, farm: FarmContext, context: ModelContext) throws -> AppliedCommandResult {
        let defaultPayload = try FarmCommandCloudPayloadEncoder.encode(command)
        func appliedResult(_ type: CloudEntityType, _ id: UUID, baseRevision: Int = 0, revision: Int = 1, payload: Data? = nil) -> AppliedCommandResult {
            AppliedCommandResult(entityType: type.rawValue, entityID: id, baseRevision: baseRevision, resultingRevision: revision, payload: payload ?? defaultPayload)
        }

        switch command {
        case .care(let careCommand):
            let result = try FarmCareCommandHandler.validateAndApply(
                careCommand,
                farmID: farm.farmID,
                accountID: farm.accountID,
                context: context
            )
            return AppliedCommandResult(entityType: result.entityType.rawValue, entityID: result.entityID, baseRevision: result.baseRevision, resultingRevision: result.resultingRevision, payload: defaultPayload)
        case .updateFarmLocation(let displayName, let latitude, let longitude, let addressSnapshot, let timeZoneIdentifier, let source, let accuracy):
            let farms = try context.fetch(FetchDescriptor<FarmRecord>())
            guard let record = farms.first(where: { $0.id == farm.farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.missingRequiredValue("当前牧场")
            }
            let baseRevision = try latestRevision(entityID: record.id, farmID: farm.farmID, context: context)
            record.locationDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            record.latitude = latitude
            record.longitude = longitude
            record.coordinateReferenceSystem = "wgs84"
            let trimmedAddress = addressSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines)
            record.addressSnapshot = trimmedAddress?.isEmpty == true ? nil : trimmedAddress
            record.timeZoneIdentifier = timeZoneIdentifier
            record.locationSourceRawValue = source.rawValue
            record.horizontalAccuracyMeters = accuracy
            record.locationUpdatedAt = .now
            record.updatedAt = .now
            return appliedResult(.farm, record.id, baseRevision: baseRevision, revision: baseRevision + 1)
        case .createPen(let name, let note):
            let record = PenRecord(farmID: farm.farmID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(record)
            return appliedResult(.pen, record.id)
        case .updatePen(let penID, let name, let note):
            guard let record = try context.fetch(FetchDescriptor<PenRecord>()).first(where: { $0.id == penID && $0.farmID == farm.farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.penNotFound
            }
            let baseRevision = record.revision
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            record.updatedAt = .now
            record.revision += 1
            return appliedResult(.pen, record.id, baseRevision: baseRevision, revision: record.revision)
        case .setPenActive(let penID, let isActive):
            guard let record = try context.fetch(FetchDescriptor<PenRecord>()).first(where: { $0.id == penID && $0.farmID == farm.farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.penNotFound
            }
            let baseRevision = record.revision
            record.isActive = isActive
            record.updatedAt = .now
            record.revision += 1
            return appliedResult(.pen, record.id, baseRevision: baseRevision, revision: record.revision)
        case .addSheep(let earTag, let breed, let sex, let penID, let occurredAt, let birthAt, let note):
            let record = SheepRecord(farmID: farm.farmID, earTag: earTag.trimmingCharacters(in: .whitespacesAndNewlines), breed: breed.trimmingCharacters(in: .whitespacesAndNewlines), sex: sex, penID: penID, enteredAt: occurredAt, birthAt: birthAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(record)
            return appliedResult(.sheep, record.id)
        case .updateSheepProfile(let sheepID, let earTag, let breed, let sex, let birthAt, let note):
            let record = try sheepRecord(sheepID, farmID: farm.farmID, context: context)
            let baseRevision = record.revision
            record.earTag = earTag.trimmingCharacters(in: .whitespacesAndNewlines)
            record.breed = breed.trimmingCharacters(in: .whitespacesAndNewlines)
            record.sexRawValue = sex.rawValue
            if sex != .ram { record.isBreedingRam = false }
            record.birthAt = birthAt
            record.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            record.updatedAt = .now
            record.revision += 1
            return appliedResult(.sheep, record.id, baseRevision: baseRevision, revision: record.revision)
        case .recordWeight(let sheepID, let kilogramsText, let occurredAt, let note):
            let record = WeightRecord(farmID: farm.farmID, sheepID: sheepID, kilogramsText: normalizedDecimal(kilogramsText), occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(record)
            return appliedResult(.weight, record.id)
        case .correctWeight(let originalID, let kilogramsText, let occurredAt, let note, let reason):
            guard let original = try context.fetch(FetchDescriptor<WeightRecord>()).first(where: { $0.id == originalID && $0.farmID == farm.farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.sourceRecordNotFound
            }
            original.deletedAt = .now
            original.revision += 1
            context.insert(TombstoneRecord(farmID: farm.farmID, entityType: CloudEntityType.weight.rawValue, entityID: original.id, deletedByAccountID: farm.accountID, reason: "修正：\(reason.trimmingCharacters(in: .whitespacesAndNewlines))", revision: original.revision))
            let replacement = WeightRecord(farmID: farm.farmID, sheepID: original.sheepID, kilogramsText: normalizedDecimal(kilogramsText), occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(replacement)
            return appliedResult(.weight, replacement.id)
        case .recordWeaning(let sheepID, let weanWeightText, let occurredAt, let birthAt, let birthWeightText, let averageDailyGainText, let damID, let litterSize, let note):
            let record = WeaningRecord(
                farmID: farm.farmID,
                sheepID: sheepID,
                occurredAt: occurredAt,
                weanWeightText: normalizedDecimal(weanWeightText),
                birthAt: birthAt,
                birthWeightText: birthWeightText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) },
                averageDailyGainText: averageDailyGainText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) },
                damID: damID,
                litterSize: litterSize,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            context.insert(record)
            return appliedResult(.weaning, record.id)
        case .createBreedingProgram(let name, let createdAt, let steps):
            let program = BreedingProgramRecord(farmID: farm.farmID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: createdAt)
            context.insert(program)
            for (index, step) in steps.enumerated() {
                context.insert(BreedingProgramStepRecord(
                    id: step.id,
                    farmID: farm.farmID,
                    programID: program.id,
                    dayOffset: step.dayOffset,
                    action: step.action.trimmingCharacters(in: .whitespacesAndNewlines),
                    sortOrder: index,
                    createdAt: createdAt
                ))
            }
            return appliedResult(.breedingProgram, program.id)
        case .transferSheep(let sheepID, let toPenID, let occurredAt, let note):
            let sheep = try sheepRecord(sheepID, farmID: farm.farmID, context: context)
            sheep.legacyStatusSnapshotIsAuthoritative = false
            sheep.legacyPenSnapshotIsAuthoritative = false
            let farmID = farm.farmID
            let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
            }))
            let origin = FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers)
            let record = TransferRecord(farmID: farm.farmID, sheepID: sheepID, fromPenID: origin, toPenID: toPenID, occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(record)
            return appliedResult(.transfer, record.id)
        case .correctTransfer(let originalID, let toPenID, let occurredAt, let note, let reason):
            guard let original = try context.fetch(FetchDescriptor<TransferRecord>()).first(where: { $0.id == originalID && $0.farmID == farm.farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.sourceRecordNotFound
            }
            original.deletedAt = .now
            original.revision += 1
            context.insert(TombstoneRecord(farmID: farm.farmID, entityType: CloudEntityType.transfer.rawValue, entityID: original.id, deletedByAccountID: farm.accountID, reason: "修正：\(reason.trimmingCharacters(in: .whitespacesAndNewlines))", revision: original.revision))
            let sheep = try sheepRecord(original.sheepID, farmID: farm.farmID, context: context)
            sheep.legacyStatusSnapshotIsAuthoritative = false
            sheep.legacyPenSnapshotIsAuthoritative = false
            let remaining = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farm.farmID && $0.sheepID == original.sheepID && $0.deletedAt == nil }
            let fromPenID = FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: remaining)
            let replacement = TransferRecord(farmID: farm.farmID, sheepID: original.sheepID, fromPenID: fromPenID, toPenID: toPenID, occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(replacement)
            return appliedResult(.transfer, replacement.id)
        case .removeSheep(let sheepID, let kind, let reason, let amountText, let occurredAt, let note, let recordID, let removalBatchID, let batchTotalAmountText):
            let sheep = try sheepRecord(sheepID, farmID: farm.farmID, context: context)
            sheep.legacyStatusSnapshotIsAuthoritative = false
            sheep.legacyPenSnapshotIsAuthoritative = false
            let record = RemovalRecord(
                id: recordID ?? UUID(),
                farmID: farm.farmID,
                sheepID: sheepID,
                kind: kind,
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                amountText: amountText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) },
                removalBatchID: removalBatchID,
                batchTotalAmountText: batchTotalAmountText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) },
                occurredAt: occurredAt,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            context.insert(record)
            return appliedResult(.removal, record.id)
        case .correctRemoval(let originalID, let kind, let reason, let amountText, let occurredAt, let note, let correctionReason):
            guard let original = try context.fetch(FetchDescriptor<RemovalRecord>()).first(where: { $0.id == originalID && $0.farmID == farm.farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.sourceRecordNotFound
            }
            original.deletedAt = .now
            original.revision += 1
            context.insert(TombstoneRecord(farmID: farm.farmID, entityType: CloudEntityType.removal.rawValue, entityID: original.id, deletedByAccountID: farm.accountID, reason: "修正：\(correctionReason.trimmingCharacters(in: .whitespacesAndNewlines))", revision: original.revision))
            if let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.id == original.sheepID && $0.farmID == farm.farmID }) {
                sheep.legacyStatusSnapshotIsAuthoritative = false
                sheep.legacyPenSnapshotIsAuthoritative = false
            }
            let retainsBatch = original.removalBatchID != nil && kind == original.kind
            let replacement = RemovalRecord(
                farmID: farm.farmID,
                sheepID: original.sheepID,
                kind: kind,
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                amountText: retainsBatch ? nil : amountText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) },
                removalBatchID: retainsBatch ? original.removalBatchID : nil,
                batchTotalAmountText: retainsBatch ? original.batchTotalAmountText : nil,
                occurredAt: occurredAt,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            context.insert(replacement)
            return appliedResult(.removal, replacement.id)
        case .restoreSheep(let removalID):
            let farmID = farm.farmID
            let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                $0.id == removalID && $0.farmID == farmID && $0.deletedAt == nil
            }))
            guard let removal = removals.first else {
                throw FarmCommandError.removalNotFound
            }
            let baseRevision = removal.revision
            if let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.id == removal.sheepID && $0.farmID == farm.farmID }) {
                sheep.legacyStatusSnapshotIsAuthoritative = false
                sheep.legacyPenSnapshotIsAuthoritative = false
            }
            removal.deletedAt = .now
            removal.revision += 1
            return appliedResult(.removal, removal.id, baseRevision: baseRevision, revision: removal.revision)
        case .createBatch(let name, let purpose, let startedAt, let sheepIDs, let note):
            let record = ProductionBatchRecord(farmID: farm.farmID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: startedAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(record)
            for sheepID in sheepIDs {
                context.insert(BatchMembershipRecord(
                    id: StableCloudUUID.derived(namespace: record.id, name: "batch-member-\(sheepID.uuidString.lowercased())"),
                    farmID: farm.farmID,
                    batchID: record.id,
                    sheepID: sheepID,
                    joinedAt: startedAt
                ))
            }
            return appliedResult(.productionBatch, record.id)
        case .assignSheepToBatch(let batchID, let sheepID, let joinedAt):
            let record = BatchMembershipRecord(farmID: farm.farmID, batchID: batchID, sheepID: sheepID, joinedAt: joinedAt)
            context.insert(record)
            return appliedResult(.batchMembership, record.id)
        case .leaveBatch(let batchID, let sheepID, let leftAt, let reason):
            let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>())
            guard let membership = memberships.first(where: { $0.farmID == farm.farmID && $0.batchID == batchID && $0.sheepID == sheepID && $0.deletedAt == nil && $0.leftAt == nil }) else {
                throw FarmCommandError.batchMembershipNotFound
            }
            membership.leftAt = leftAt
            membership.leaveReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            membership.updatedAt = .now
            try ProductionBatchLifecycle.reconcile(batchID: batchID, farmID: farm.farmID, context: context)
            return appliedResult(.batchMembership, membership.id, baseRevision: 1, revision: 2)
        case .addIngredient(let name, let unit, let dryMatterText):
            let record = FeedIngredientRecord(farmID: farm.farmID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), unit: unit.trimmingCharacters(in: .whitespacesAndNewlines), dryMatterText: dryMatterText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) })
            context.insert(record)
            return appliedResult(.feedIngredient, record.id)
        case .createRecipe(let name, let note):
            let record = FeedRecipeRecord(farmID: farm.farmID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(record)
            return appliedResult(.feedRecipe, record.id)
        case .addRecipeComponent(let recipeID, let ingredientID, let kilogramsText):
            let record = FeedRecipeComponentRecord(farmID: farm.farmID, recipeID: recipeID, ingredientID: ingredientID, kilogramsText: normalizedDecimal(kilogramsText))
            context.insert(record)
            return appliedResult(.feedRecipeComponent, record.id)
        case .recordFeed(let penID, let recipeID, let mode, let occurredAt, let lines, let note):
            let feed = FeedRecord(farmID: farm.farmID, penID: penID, recipeID: recipeID, mode: mode, occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(feed)
            let recipeComponents = try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>())
            var resolvedCloudLines: [FarmCommandCloudPayload.FeedLine] = []
            for line in lines {
                let ingredient = try ingredientRecord(line.ingredientID, farmID: farm.farmID, context: context)
                let ingredientBatch = try line.ingredientBatchID.map {
                    try feedIngredientBatchRecord($0, ingredientID: ingredient.id, farmID: farm.farmID, context: context)
                }
                let recipeComponent = recipeID.flatMap { recipeID in
                    recipeComponents.first {
                        $0.farmID == farm.farmID && $0.recipeID == recipeID && $0.ingredientID == ingredient.id && $0.deletedAt == nil
                    }
                }
                let recipeNutrients = recipeComponent?.nutrientSnapshotJSON ?? "{}"
                let nutrientSnapshot = recipeNutrients == "{}" ? ingredient.nutrientSnapshotJSON : recipeNutrients
                let batchPrice = ingredientBatch?.pricePerKilogramText.trimmingCharacters(in: .whitespacesAndNewlines)
                let recipePrice = recipeComponent?.pricePerKilogramText?.trimmingCharacters(in: .whitespacesAndNewlines)
                let priceSnapshot = (batchPrice?.isEmpty == false ? batchPrice : nil) ?? (recipePrice?.isEmpty == false ? recipePrice : nil)
                let record = FeedRecordLine(
                    id: line.id,
                    farmID: farm.farmID,
                    feedRecordID: feed.id,
                    ingredientID: ingredient.id,
                    kilogramsText: normalizedDecimal(line.kilogramsText),
                    ingredientNameSnapshot: ingredient.name,
                    ingredientBatchID: ingredientBatch?.id,
                    ingredientBatchNameSnapshot: ingredientBatch?.batchName.trimmingCharacters(in: .whitespacesAndNewlines),
                    pricePerKilogramTextSnapshot: priceSnapshot,
                    nutrientSnapshotJSON: nutrientSnapshot,
                    unitSnapshot: ingredient.unit,
                    dryMatterTextSnapshot: ingredient.dryMatterText
                )
                context.insert(record)
                resolvedCloudLines.append(.init(
                    id: record.id,
                    ingredientID: record.ingredientID,
                    kilogramsText: record.kilogramsText,
                    ingredientBatchID: record.ingredientBatchID,
                    ingredientNameSnapshot: record.ingredientNameSnapshot,
                    ingredientBatchNameSnapshot: record.ingredientBatchNameSnapshot,
                    pricePerKilogramTextSnapshot: record.pricePerKilogramTextSnapshot,
                    nutrientSnapshotJSON: record.nutrientSnapshotJSON,
                    unitSnapshot: record.unitSnapshot,
                    dryMatterTextSnapshot: record.dryMatterTextSnapshot
                ))
            }
            let payload = try FarmCommandCloudPayloadEncoder.encode(command, resolvedFeedLines: resolvedCloudLines)
            return appliedResult(.feed, feed.id, payload: payload)
        case .recordHealth(let sheepID, let penID, let kind, let itemName, let occurredAt, let note, let inventoryLotID, let quantityText):
            let health = HealthRecord(farmID: farm.farmID, sheepID: sheepID, penID: penID, kind: kind, itemNameSnapshot: itemName.trimmingCharacters(in: .whitespacesAndNewlines), occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines), inventoryLotID: inventoryLotID, quantityText: quantityText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) })
            context.insert(health)
            if let inventoryLotID, let quantityText, !quantityText.isEmpty {
                context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: health.id, name: "inventory-consumption"), farmID: farm.farmID, inventoryLotID: inventoryLotID, kind: .consumption, quantityText: normalizedDecimal(quantityText), occurredAt: occurredAt, sourceRecordID: health.id, note: health.itemNameSnapshot))
            }
            return appliedResult(.health, health.id)
        case .receiveInventory(let catalogName, let kind, let expiresAt, let quantityText, let occurredAt, let note):
            let lot = InventoryLotRecord(farmID: farm.farmID, catalogName: catalogName.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, expiresAt: expiresAt, startingQuantityText: normalizedDecimal(quantityText))
            context.insert(lot)
            context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: lot.id, name: "inventory-receipt"), farmID: farm.farmID, inventoryLotID: lot.id, kind: .receipt, quantityText: normalizedDecimal(quantityText), occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines)))
            FarmCareCommandHandler.refreshInventoryExpiryReminder(for: lot, context: context)
            return appliedResult(.inventoryLot, lot.id)
        case .addSemen(let code, let breed, let source, let batchNumber, let quantityText):
            let record = SemenRecord(farmID: farm.farmID, code: code.trimmingCharacters(in: .whitespacesAndNewlines), breed: breed.trimmingCharacters(in: .whitespacesAndNewlines), source: source.trimmingCharacters(in: .whitespacesAndNewlines), batchNumber: batchNumber.trimmingCharacters(in: .whitespacesAndNewlines), quantityText: "0")
            context.insert(record)
            context.insert(SemenTransactionRecord(id: StableCloudUUID.derived(namespace: record.id, name: "semen-receipt"), farmID: farm.farmID, semenID: record.id, kind: .receipt, quantityText: normalizedDecimal(quantityText), occurredAt: record.createdAt, sourceRecordID: record.id, note: "冻精入库"))
            return appliedResult(.semen, record.id)
        case .recordReproduction(let eweID, let kind, let occurredAt, let sireID, let semenName, let result, let lambCount, let parity, let birthDeadCount, let offspring, let note):
            let record = ReproductionRecord(farmID: farm.farmID, eweID: eweID, kind: kind, occurredAt: occurredAt, sireID: sireID, semenNameSnapshot: semenName?.trimmingCharacters(in: .whitespacesAndNewlines), result: result.trimmingCharacters(in: .whitespacesAndNewlines), lambCount: lambCount, parity: parity, birthDeadCount: birthDeadCount, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(record)
            for detail in offspring {
                context.insert(LambingOffspringRecord(
                    id: detail.id,
                    farmID: farm.farmID,
                    lambingRecordID: record.id,
                    sheepID: detail.sheepID,
                    legacyEarTag: detail.earTag.trimmingCharacters(in: .whitespacesAndNewlines),
                    sexRawValue: detail.sex.rawValue,
                    birthWeightText: normalizedDecimal(detail.birthWeightText)
                ))
            }
            return appliedResult(.reproduction, record.id)
        case .addNote(let sheepID, let penID, let text, let occurredAt):
            let record = NoteRecord(farmID: farm.farmID, sheepID: sheepID, penID: penID, text: text.trimmingCharacters(in: .whitespacesAndNewlines), occurredAt: occurredAt)
            context.insert(record)
            return appliedResult(.note, record.id)
        case .tombstoneEntity(let entityType, let entityID, let reason):
            let baseRevision = try latestRevision(entityID: entityID, farmID: farm.farmID, context: context)
            try DomainEntityDeletionService.setDeletedAt(.now, type: entityType, id: entityID, farmID: farm.farmID, context: context)
            context.insert(TombstoneRecord(
                farmID: farm.farmID,
                entityType: entityType.rawValue,
                entityID: entityID,
                deletedByAccountID: farm.accountID,
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                revision: baseRevision + 1
            ))
            return appliedResult(entityType, entityID, baseRevision: baseRevision, revision: baseRevision + 1)
        case .restoreTombstonedEntity(let tombstoneID):
            guard let tombstone = try context.fetch(FetchDescriptor<TombstoneRecord>()).first(where: { $0.id == tombstoneID && $0.farmID == farm.farmID }),
                  let entityType = CloudEntityType(rawValue: tombstone.entityType) else {
                throw FarmCommandError.missingRequiredValue("删除记录")
            }
            try DomainEntityDeletionService.setDeletedAt(nil, type: entityType, id: tombstone.entityID, farmID: farm.farmID, context: context)
            tombstone.restoredAt = .now
            return appliedResult(entityType, tombstone.entityID, baseRevision: tombstone.revision, revision: tombstone.revision + 1)
        }
    }

    private func latestRevision(entityID: UUID, farmID: UUID, context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID && $0.entityID == entityID
        }))
            .map(\.resultingRevision)
            .max() ?? 1
    }

    private func entityExists(type: CloudEntityType, id: UUID, farmID: UUID, context: ModelContext) throws -> Bool {
        switch type {
        case .farm: return try context.fetch(FetchDescriptor<FarmRecord>()).contains { $0.id == id }
        case .pen: return try context.fetch(FetchDescriptor<PenRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .sheep: return try context.fetch(FetchDescriptor<SheepRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .weight: return try context.fetch(FetchDescriptor<WeightRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .weaning: return try context.fetch(FetchDescriptor<WeaningRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .breedingProgram: return try context.fetch(FetchDescriptor<BreedingProgramRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .transfer: return try context.fetch(FetchDescriptor<TransferRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .removal: return try context.fetch(FetchDescriptor<RemovalRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .productionBatch: return try context.fetch(FetchDescriptor<ProductionBatchRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .batchMembership: return try context.fetch(FetchDescriptor<BatchMembershipRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .feedIngredient: return try context.fetch(FetchDescriptor<FeedIngredientRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .feedRecipe: return try context.fetch(FetchDescriptor<FeedRecipeRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .feedRecipeComponent: return try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .feed: return try context.fetch(FetchDescriptor<FeedRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .feedLine: return try context.fetch(FetchDescriptor<FeedRecordLine>()).contains { $0.id == id && $0.farmID == farmID }
        case .inventoryLot: return try context.fetch(FetchDescriptor<InventoryLotRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .inventoryTransaction: return try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .health: return try context.fetch(FetchDescriptor<HealthRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .reproduction: return try context.fetch(FetchDescriptor<ReproductionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .semen: return try context.fetch(FetchDescriptor<SemenRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .semenDonor: return try context.fetch(FetchDescriptor<SemenDonorRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .pedigreeChange: return try context.fetch(FetchDescriptor<PedigreeChangeRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .note: return try context.fetch(FetchDescriptor<NoteRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .photoAsset: return try context.fetch(FetchDescriptor<PhotoAssetRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .breedingProgramStep: return try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .feedIngredientBatch: return try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .healthCatalogItem: return try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .healthSubjectLink: return try context.fetch(FetchDescriptor<HealthSubjectLink>()).contains { $0.id == id && $0.farmID == farmID }
        case .lambingOffspring: return try context.fetch(FetchDescriptor<LambingOffspringRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .careBatch: return try context.fetch(FetchDescriptor<CareBatchRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .semenTransaction: return try context.fetch(FetchDescriptor<SemenTransactionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .careRule: return try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .careReminder: return try context.fetch(FetchDescriptor<CareReminderRecord>()).contains { $0.id == id && $0.farmID == farmID }
        }
    }

    private func required(_ value: String, label: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FarmCommandError.missingRequiredValue(label) }
        return trimmed
    }

    private func positiveDecimal(_ text: String, label: String) throws {
        guard let value = Decimal.stable(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            throw FarmCommandError.invalidNumber(label)
        }
    }

    private func normalizedDecimal(_ text: String) -> String {
        (Decimal.stable(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0).stableText
    }

    private func assertSheep(_ id: UUID, farmID: UUID, context: ModelContext) throws { _ = try sheepRecord(id, farmID: farmID, context: context) }
    private func assertPen(_ id: UUID, farmID: UUID, context: ModelContext, includeInactive: Bool = false) throws {
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.id == id && $0.farmID == farmID && $0.deletedAt == nil
        }))
        guard pens.contains(where: {
            includeInactive || $0.isActive
        }) else { throw FarmCommandError.penNotFound }
    }
    private func assertIngredient(_ id: UUID, farmID: UUID, context: ModelContext) throws { _ = try ingredientRecord(id, farmID: farmID, context: context) }

    private func assertRecipe(_ id: UUID, farmID: UUID, context: ModelContext) throws {
        let recipes = try context.fetch(FetchDescriptor<FeedRecipeRecord>())
        guard recipes.contains(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil && $0.isActive }) else {
            throw FarmCommandError.missingRequiredValue("有效配方")
        }
    }

    private func assertBatch(_ id: UUID, farmID: UUID, context: ModelContext) throws {
        let batches = try context.fetch(FetchDescriptor<ProductionBatchRecord>())
        guard batches.contains(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil && $0.status == .active }) else {
            throw FarmCommandError.batchNotFound
        }
    }

    private func sheepRecord(_ id: UUID, farmID: UUID, context: ModelContext) throws -> SheepRecord {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.id == id && $0.farmID == farmID && $0.deletedAt == nil
        }))
        guard let item = sheep.first else { throw FarmCommandError.sheepNotFound }
        return item
    }

    private func penRecord(_ id: UUID, farmID: UUID, context: ModelContext) throws -> PenRecord {
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
        guard let item = pens.first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil && $0.isActive }) else { throw FarmCommandError.penNotFound }
        return item
    }

    private func ingredientRecord(_ id: UUID, farmID: UUID, context: ModelContext) throws -> FeedIngredientRecord {
        let ingredients = try context.fetch(FetchDescriptor<FeedIngredientRecord>())
        guard let item = ingredients.first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil && $0.isActive }) else { throw FarmCommandError.ingredientNotFound }
        return item
    }

    private func feedIngredientBatchRecord(_ id: UUID, ingredientID: UUID, farmID: UUID, context: ModelContext) throws -> FeedIngredientBatchRecord {
        let batches = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
        guard let batch = batches.first(where: {
            $0.id == id && $0.farmID == farmID && $0.ingredientID == ingredientID && $0.isActive
        }) else {
            throw FarmCommandError.feedIngredientBatchNotFound
        }
        return batch
    }

    private func inventoryLot(_ id: UUID, farmID: UUID, context: ModelContext) throws -> InventoryLotRecord {
        let lots = try context.fetch(FetchDescriptor<InventoryLotRecord>())
        guard let lot = lots.first(where: { $0.id == id && $0.farmID == farmID && $0.isActive }) else {
            throw FarmCommandError.inventoryLotNotFound
        }
        return lot
    }

    private func inventoryBalance(for lot: InventoryLotRecord, context: ModelContext) throws -> Decimal {
        let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>())
            .filter { $0.farmID == lot.farmID && $0.inventoryLotID == lot.id && $0.deletedAt == nil }
        return transactions.reduce(Decimal.zero) { partial, transaction in
            switch transaction.kind {
            case .receipt, .adjustment: partial + transaction.quantity
            case .consumption: partial - transaction.quantity
            }
        }
    }

    private func hasSheepReferences(_ sheepID: UUID, farmID: UUID, context: ModelContext) throws -> Bool {
        if try context.fetch(FetchDescriptor<WeightRecord>()).contains(where: { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }) { return true }
        if try context.fetch(FetchDescriptor<WeaningRecord>()).contains(where: { $0.farmID == farmID && ($0.sheepID == sheepID || $0.damID == sheepID) && $0.deletedAt == nil }) { return true }
        if try context.fetch(FetchDescriptor<TransferRecord>()).contains(where: { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }) { return true }
        if try context.fetch(FetchDescriptor<RemovalRecord>()).contains(where: { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }) { return true }
        if try context.fetch(FetchDescriptor<HealthRecord>()).contains(where: { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }) { return true }
        if try context.fetch(FetchDescriptor<HealthSubjectLink>()).contains(where: { $0.farmID == farmID && $0.sheepID == sheepID }) { return true }
        if try context.fetch(FetchDescriptor<ReproductionRecord>()).contains(where: { $0.farmID == farmID && ($0.eweID == sheepID || $0.sireID == sheepID) && $0.deletedAt == nil }) { return true }
        if try context.fetch(FetchDescriptor<NoteRecord>()).contains(where: { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }) { return true }
        if try context.fetch(FetchDescriptor<BatchMembershipRecord>()).contains(where: { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }) { return true }
        if try context.fetch(FetchDescriptor<LambingOffspringRecord>()).contains(where: { $0.farmID == farmID && $0.sheepID == sheepID }) { return true }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        return sheep.contains { $0.farmID == farmID && $0.deletedAt == nil && ($0.damID == sheepID || $0.sireID == sheepID) }
    }

    private func inventoryContribution(_ transaction: InventoryTransactionRecord) -> Decimal {
        switch transaction.kind {
        case .receipt, .adjustment: transaction.quantity
        case .consumption: -transaction.quantity
        }
    }

    private func semenContribution(_ transaction: SemenTransactionRecord) -> Decimal {
        switch transaction.kind {
        case .receipt, .adjustment: transaction.quantity
        case .consumption: -transaction.quantity
        }
    }
}

enum EarTag {
    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
}
