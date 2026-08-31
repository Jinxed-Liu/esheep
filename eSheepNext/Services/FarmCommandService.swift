import Foundation
import SwiftData

enum FarmCommandError: LocalizedError {
    case missingRequiredValue(String)
    case invalidNumber(String)
    case duplicateEarTag
    case sheepNotFound
    case penNotFound
    case feedPenHasNoSheepOnDate
    case penHasNoSheepAtTime
    case ingredientNotFound
    case feedIngredientBatchNotFound
    case batchNotFound
    case removalNotFound
    case duplicateRemovalRecord
    case invalidRemovalBatch(String)
    case duplicateBatchMembership
    case batchMembershipNotFound
    case batchMembershipNotRestorable
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
    case lambingParityMismatch(current: Int, attempted: Int)
    case lambingCorrectionConflict(String)
    case lambWeightBeforeBirth
    case futureFactDate(String)
    case routineLambWeightRequiresSheepRecord
    case stillbornWeightMustBeBirth
    case weaningDamMustBeEwe
    case transferDestinationUnchanged
    case cloudIdentityLocked
    case invalidFarmCoordinate
    case invalidFarmTimeZone
    case penHasCurrentSheep
    case protectedPenReferences
    case protectedSheepReferences
    case parityBaselineManagedInProfile
    case sourceRecordNotFound
    case tmrCloudProtocolUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredValue(let label): "请填写\(label)。"
        case .invalidNumber(let label): "\(label)必须是有效且大于零的数值。"
        case .duplicateEarTag: "当前牧场已存在相同耳号。耳号在本牧场内永久唯一。"
        case .sheepNotFound: "未找到当前牧场中的羊只。"
        case .penNotFound: "未找到当前牧场中的圈舍。"
        case .feedPenHasNoSheepOnDate: "所选圈舍在投喂发生日期没有羊只，不能记录投喂。"
        case .penHasNoSheepAtTime: "所选圈舍在该发生时间没有羊只。"
        case .ingredientNotFound: "投喂原料不存在或已停用。"
        case .feedIngredientBatchNotFound: "投喂原料批次不存在、已停用，或不属于所选原料。"
        case .batchNotFound: "未找到当前牧场中的生产批次。"
        case .removalNotFound: "未找到可恢复的离场记录。"
        case .duplicateRemovalRecord: "该离场记录已经存在，请勿重复导入。"
        case .invalidRemovalBatch(let detail): "离场批次无效：\(detail)"
        case .duplicateBatchMembership: "该羊已在未结束的生产批次中。"
        case .batchMembershipNotFound: "未找到可结束的批次成员关系。"
        case .batchMembershipNotRestorable: "未找到可撤回的批次移出记录；它可能已被撤回或同步更新。"
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
        case .lambingParityMismatch(let current, let attempted): "母羊当前为第 \(current) 胎，本次产羔必须记录为第 \(current + 1) 胎，不能记录为第 \(attempted) 胎。"
        case .lambingCorrectionConflict(let detail): "产羔修正与后续记录冲突：\(detail)"
        case .lambWeightBeforeBirth: "称重时间不能早于羔羊出生时间。"
        case .futureFactDate(let label): "\(label)不能晚于当前时间。"
        case .routineLambWeightRequiresSheepRecord: "出生 24 小时后的体重属于普通称重，必须先建立羔羊档案。"
        case .stillbornWeightMustBeBirth: "死胎只能记录出生 24 小时内测得的初生重。"
        case .weaningDamMustBeEwe: "断奶记录中的母本必须是母羊。"
        case .transferDestinationUnchanged: "目标圈舍与羊只当时所在圈舍相同，请选择实际调入的圈舍。"
        case .cloudIdentityLocked: "当前云端牧场缺少有效的账号绑定或能力证书，已锁定写入。"
        case .invalidFarmCoordinate: "牧场坐标必须位于有效的经纬度范围内。"
        case .invalidFarmTimeZone: "请选择有效的 IANA 时区。"
        case .penHasCurrentSheep: "圈舍内仍有在场羊只，请先转群后再停用。"
        case .protectedPenReferences: "圈舍仍被羊只或生产历史引用，不能直接删除；可以先停用。"
        case .protectedSheepReferences: "该羊只已有生产历史或亲缘关系，不能直接删除建档事件；请删除或修正关联事实。"
        case .parityBaselineManagedInProfile: "胎次确认由母羊档案管理，不能作为普通繁殖记录修正或删除。"
        case .sourceRecordNotFound: "未找到可修正的原始记录。"
        case .tmrCloudProtocolUnavailable(let detail): "TMR 云端写入暂不可用：\(detail)"
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

struct FeedIngredientDraft: Sendable, Hashable {
    let id: UUID?
    let name: String
    let unit: String
    let category: String
    let dryMatterText: String?
    let nutrientSnapshotJSON: String
    let kind: FeedIngredientKind
    let sourceTemplateID: String?
    let sourceTemplateCode: String?
    let mixtureComponentsJSON: String?
    let note: String

    init(id: UUID? = nil, name: String, unit: String = "千克", category: String = "", dryMatterText: String? = nil, nutrientSnapshotJSON: String = "{}", kind: FeedIngredientKind = .custom, sourceTemplateID: String? = nil, sourceTemplateCode: String? = nil, mixtureComponentsJSON: String? = nil, note: String = "") {
        self.id = id
        self.name = name
        self.unit = unit
        self.category = category
        self.dryMatterText = dryMatterText
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
        self.kind = kind
        self.sourceTemplateID = sourceTemplateID
        self.sourceTemplateCode = sourceTemplateCode
        self.mixtureComponentsJSON = mixtureComponentsJSON
        self.note = note
    }
}

struct FeedBatchDraft: Sendable, Hashable {
    let id: UUID?
    let ingredientID: UUID
    let batchName: String
    let purchaseDate: Date?
    let supplier: String
    let storageLocation: String
    let pricePerKilogramText: String
    let purchasedKilogramsText: String?
    let packagingKind: FeedPackagingKind
    let packageCountText: String?
    let nominalPackageKilogramsText: String?
    let stockWeightConfirmed: Bool
    let initialKilogramsText: String?
    let remainingKilogramsText: String?
    let note: String
    let isActive: Bool

    init(id: UUID? = nil, ingredientID: UUID, batchName: String, purchaseDate: Date? = nil, supplier: String = "", storageLocation: String = "", pricePerKilogramText: String, purchasedKilogramsText: String? = nil, packagingKind: FeedPackagingKind = .bulk, packageCountText: String? = nil, nominalPackageKilogramsText: String? = nil, stockWeightConfirmed: Bool = false, initialKilogramsText: String? = nil, remainingKilogramsText: String? = nil, note: String = "", isActive: Bool = true) {
        self.id = id
        self.ingredientID = ingredientID
        self.batchName = batchName
        self.purchaseDate = purchaseDate
        self.supplier = supplier
        self.storageLocation = storageLocation
        self.pricePerKilogramText = pricePerKilogramText
        self.purchasedKilogramsText = purchasedKilogramsText
        self.packagingKind = packagingKind
        self.packageCountText = packageCountText
        self.nominalPackageKilogramsText = nominalPackageKilogramsText
        self.stockWeightConfirmed = stockWeightConfirmed
        self.initialKilogramsText = initialKilogramsText
        self.remainingKilogramsText = remainingKilogramsText
        self.note = note
        self.isActive = isActive
    }
}

struct FeedRecipeComponentDraft: Sendable, Hashable {
    let id: UUID
    let ingredientID: UUID
    let ingredientBatchID: UUID?
    let kilogramsText: String
    let pricePerKilogramText: String?
    let nutrientSnapshotJSON: String

    init(id: UUID = UUID(), ingredientID: UUID, ingredientBatchID: UUID?, kilogramsText: String, pricePerKilogramText: String? = nil, nutrientSnapshotJSON: String = "{}") {
        self.id = id
        self.ingredientID = ingredientID
        self.ingredientBatchID = ingredientBatchID
        self.kilogramsText = kilogramsText
        self.pricePerKilogramText = pricePerKilogramText
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
    }
}

struct FeedRecipeDraft: Sendable, Hashable {
    let id: UUID?
    let name: String
    let targetPenID: UUID?
    let targetPenName: String?
    let stage: FeedRecipeStage
    let headCount: Int?
    let components: [FeedRecipeComponentDraft]
    let note: String

    init(id: UUID? = nil, name: String, targetPenID: UUID? = nil, targetPenName: String? = nil, stage: FeedRecipeStage = .custom, headCount: Int? = nil, components: [FeedRecipeComponentDraft], note: String = "") {
        self.id = id
        self.name = name
        self.targetPenID = targetPenID
        self.targetPenName = targetPenName
        self.stage = stage
        self.headCount = headCount
        self.components = components
        self.note = note
    }
}

struct FeedEntryDraft: Sendable, Hashable {
    let id: UUID
    let penID: UUID
    let recipeID: UUID?
    let mode: FeedMode
    let occurredAt: Date
    let mealName: String
    let feederName: String
    let remainingKilogramsText: String?
    let discardedKilogramsText: String?
    let remainingCompositionJSON: String?
    let recipeHeadCountSnapshot: Int?
    let actualHeadCountSnapshot: Int?
    let scaleFactorText: String?
    let excludedSheepIDs: [UUID]
    let lines: [FeedLineDraft]
    let note: String

    init(id: UUID = UUID(), penID: UUID, recipeID: UUID? = nil, mode: FeedMode, occurredAt: Date, mealName: String = "", feederName: String = "", remainingKilogramsText: String? = nil, discardedKilogramsText: String? = nil, remainingCompositionJSON: String? = nil, recipeHeadCountSnapshot: Int? = nil, actualHeadCountSnapshot: Int? = nil, scaleFactorText: String? = nil, excludedSheepIDs: [UUID] = [], lines: [FeedLineDraft], note: String = "") {
        self.id = id
        self.penID = penID
        self.recipeID = recipeID
        self.mode = mode
        self.occurredAt = occurredAt
        self.mealName = mealName
        self.feederName = feederName
        self.remainingKilogramsText = remainingKilogramsText
        self.discardedKilogramsText = discardedKilogramsText
        self.remainingCompositionJSON = remainingCompositionJSON
        self.recipeHeadCountSnapshot = recipeHeadCountSnapshot
        self.actualHeadCountSnapshot = actualHeadCountSnapshot
        self.scaleFactorText = scaleFactorText
        self.excludedSheepIDs = Array(Set(excludedSheepIDs)).sorted { $0.uuidString < $1.uuidString }
        self.lines = lines
        self.note = note
    }
}

struct FeedTroughObservationDraft: Sendable, Hashable {
    let id: UUID
    let penID: UUID
    let relatedFeedRecordID: UUID?
    let feederName: String
    let observedAt: Date
    let actualRemainingKilogramsText: String
    let discardedKilogramsText: String?
    let measurementMethod: FeedTroughMeasurementMethod
    let compositionSnapshotJSON: String?
    let note: String

    init(
        id: UUID = UUID(),
        penID: UUID,
        relatedFeedRecordID: UUID? = nil,
        feederName: String,
        observedAt: Date,
        actualRemainingKilogramsText: String,
        discardedKilogramsText: String? = nil,
        measurementMethod: FeedTroughMeasurementMethod,
        compositionSnapshotJSON: String? = nil,
        note: String = ""
    ) {
        self.id = id
        self.penID = penID
        self.relatedFeedRecordID = relatedFeedRecordID
        self.feederName = feederName
        self.observedAt = observedAt
        self.actualRemainingKilogramsText = actualRemainingKilogramsText
        self.discardedKilogramsText = discardedKilogramsText
        self.measurementMethod = measurementMethod
        self.compositionSnapshotJSON = compositionSnapshotJSON
        self.note = note
    }
}

struct HistoricalFeedLineDraft: Sendable, Hashable, Identifiable {
    let id: UUID
    let ingredientID: UUID
    let kilogramsText: String
    let ingredientNameSnapshot: String
    let ingredientBatchNameSnapshot: String?
    let pricePerKilogramTextSnapshot: String?
    let nutrientSnapshotJSON: String
    let unitSnapshot: String
    let dryMatterTextSnapshot: String?

    init(id: UUID, ingredientID: UUID, kilogramsText: String, ingredientNameSnapshot: String, ingredientBatchNameSnapshot: String? = nil, pricePerKilogramTextSnapshot: String? = nil, nutrientSnapshotJSON: String = "{}", unitSnapshot: String = "千克", dryMatterTextSnapshot: String? = nil) {
        self.id = id
        self.ingredientID = ingredientID
        self.kilogramsText = kilogramsText
        self.ingredientNameSnapshot = ingredientNameSnapshot
        self.ingredientBatchNameSnapshot = ingredientBatchNameSnapshot
        self.pricePerKilogramTextSnapshot = pricePerKilogramTextSnapshot
        self.nutrientSnapshotJSON = nutrientSnapshotJSON
        self.unitSnapshot = unitSnapshot
        self.dryMatterTextSnapshot = dryMatterTextSnapshot
    }
}

struct HistoricalFeedEntryDraft: Sendable, Hashable {
    let id: UUID
    let legacySourceKey: String
    let penID: UUID
    let mode: FeedMode
    let occurredAt: Date
    let mealName: String
    let feederName: String
    let remainingKilogramsText: String?
    let discardedKilogramsText: String?
    let remainingCompositionJSON: String?
    let lines: [HistoricalFeedLineDraft]
    let note: String
}

enum FeedPenEligibility {
    static func sheepByPen(
        on date: Date,
        sheep: [SheepRecord],
        transfers: [TransferRecord],
        removals: [RemovalRecord],
        calendar: Calendar = .current
    ) -> [UUID: [SheepRecord]] {
        let selectedDay = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: .now)
        if selectedDay >= today {
            var current: [UUID: [SheepRecord]] = [:]
            for item in sheep where item.deletedAt == nil && item.isCurrentlyPresent {
                guard let penID = item.currentPenID else { continue }
                current[penID, default: []].append(item)
            }
            return current.mapValues { $0.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending } }
        }

        let dayEnd = (calendar.date(byAdding: .day, value: 1, to: selectedDay) ?? date).addingTimeInterval(-0.001)
        let transfersBySheep = Dictionary(grouping: transfers.filter { $0.deletedAt == nil }, by: \.sheepID)
        let removalsBySheep = Dictionary(grouping: removals.filter { $0.deletedAt == nil }, by: \.sheepID)
        var result: [UUID: [SheepRecord]] = [:]
        for item in sheep where item.deletedAt == nil && item.enteredAt <= dayEnd {
            guard FarmHistoryTimeline.removal(for: item.id, at: dayEnd, removals: removalsBySheep[item.id] ?? []) == nil,
                  let penID = FarmHistoryTimeline.pen(for: item, at: dayEnd, transfers: transfersBySheep[item.id] ?? []) else { continue }
            result[penID, default: []].append(item)
        }
        return result.mapValues { $0.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending } }
    }

    static func headCounts(
        on date: Date,
        sheep: [SheepRecord],
        transfers: [TransferRecord],
        removals: [RemovalRecord],
        calendar: Calendar = .current
    ) -> [UUID: Int] {
        sheepByPen(on: date, sheep: sheep, transfers: transfers, removals: removals, calendar: calendar)
            .mapValues(\.count)
    }
}

enum FeedMixtureAllocator {
    static func roundedKilograms(_ value: Decimal) -> Decimal {
        var source = value
        var result = Decimal.zero
        NSDecimalRound(&result, &source, 6, .plain)
        return result
    }

    static func mixtureByPen(totalKilograms: Decimal, weightedHeadCounts: [(penID: UUID, headCount: Int)]) -> [UUID: Decimal] {
        let totalHeadCount = weightedHeadCounts.reduce(0) { $0 + max(0, $1.headCount) }
        guard totalKilograms > 0, totalHeadCount > 0 else { return [:] }
        var result: [UUID: Decimal] = [:]
        var used: Decimal = 0
        for (index, item) in weightedHeadCounts.enumerated() {
            let value = index == weightedHeadCounts.count - 1
                ? totalKilograms - used
                : roundedKilograms(totalKilograms * Decimal(max(0, item.headCount)) / Decimal(totalHeadCount))
            result[item.penID] = value
            used += value
        }
        return result
    }

    static func ingredientsByPen(
        components: [(lineID: UUID, kilograms: Decimal)],
        penMixtures: [(penID: UUID, kilograms: Decimal)]
    ) -> [UUID: [UUID: Decimal]] {
        let mixtureTotal = components.reduce(Decimal.zero) { $0 + $1.kilograms }
        guard mixtureTotal > 0, !penMixtures.isEmpty else { return [:] }
        var result = Dictionary(uniqueKeysWithValues: penMixtures.map { ($0.penID, [UUID: Decimal]()) })
        for component in components {
            var used: Decimal = 0
            for (index, pen) in penMixtures.enumerated() {
                let quantity = index == penMixtures.count - 1
                    ? component.kilograms - used
                    : roundedKilograms(component.kilograms * pen.kilograms / mixtureTotal)
                result[pen.penID, default: [:]][component.lineID] = quantity
                used += quantity
            }
        }
        return result
    }
}

enum FeedExclusionRecommendation {
    /// 只推荐有明确出生日期、投喂日尚未断奶且出生未满 1.5 个月（按 45 日龄）的羔羊。
    /// 推荐结果仅用于界面提示，必须由用户主动选择后才会从均分计数中扣除。
    static func nursingLambIDs(
        on date: Date,
        sheep: [SheepRecord],
        weanings: [WeaningRecord],
        calendar: Calendar = .current
    ) -> Set<UUID> {
        let selectedDay = calendar.startOfDay(for: date)
        let dayEnd = (calendar.date(byAdding: .day, value: 1, to: selectedDay) ?? date).addingTimeInterval(-0.001)
        let weanedIDs = Set(weanings.lazy.filter {
            $0.deletedAt == nil && $0.occurredAt <= dayEnd
        }.map(\.sheepID))
        return Set(sheep.compactMap { item in
            guard let birthAt = item.birthAt,
                  birthAt <= dayEnd,
                  !weanedIDs.contains(item.id) else { return nil }
            let ageDays = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: birthAt),
                to: selectedDay
            ).day ?? -1
            return (0...45).contains(ageDays) ? item.id : nil
        })
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
    case addSheep(earTag: String, breed: String, sex: SheepSex, penID: UUID?, occurredAt: Date, birthAt: Date?, currentParity: Int? = nil, note: String)
    case updateSheepProfile(sheepID: UUID, earTag: String, breed: String, sex: SheepSex, birthAt: Date?, currentParity: Int? = nil, parityRecordedAt: Date? = nil, note: String)
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
    case restoreBatchMembership(membershipID: UUID, restoredAt: Date, reason: String)
    case addIngredient(name: String, unit: String, dryMatterText: String?)
    case createRecipe(name: String, note: String)
    case addRecipeComponent(recipeID: UUID, ingredientID: UUID, kilogramsText: String)
    case recordFeed(penID: UUID, recipeID: UUID?, mode: FeedMode, occurredAt: Date, lines: [FeedLineDraft], note: String)
    case saveFeedIngredient(FeedIngredientDraft)
    case saveFeedBatch(FeedBatchDraft)
    case adjustFeedStock(batchID: UUID, kind: FeedStockTransactionKind, quantityText: String, occurredAt: Date, note: String)
    case countFeedStock(countID: UUID, batchID: UUID, actualKilogramsText: String?, method: FeedStockCountMethod, occurredAt: Date, note: String)
    case saveFeedRecipe(FeedRecipeDraft)
    case recordFeedV2(FeedEntryDraft)
    case recordFeedTroughObservation(FeedTroughObservationDraft)
    case importHistoricalFeed(HistoricalFeedEntryDraft)
    case recordHealth(sheepID: UUID?, penID: UUID?, kind: HealthRecordKind, itemName: String, occurredAt: Date, note: String, inventoryLotID: UUID?, quantityText: String?)
    case receiveInventory(catalogName: String, kind: HealthRecordKind, expiresAt: Date?, quantityText: String, occurredAt: Date, note: String)
    case addSemen(code: String, breed: String, source: String, batchNumber: String, quantityText: String)
    case recordReproduction(eweID: UUID, kind: ReproductionRecordKind, occurredAt: Date, sireID: UUID?, semenName: String?, result: String, lambCount: Int, parity: Int?, birthDeadCount: Int?, offspring: [LambingOffspringDraft], note: String)
    case care(CareCommand)
    case tmr(TMRCommand)
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
        case .addIngredient, .createRecipe, .addRecipeComponent, .saveFeedIngredient, .saveFeedBatch, .adjustFeedStock, .countFeedStock, .saveFeedRecipe, .createBreedingProgram:
            .manageCatalogs
        case .care(let command):
            command.requiredCapability
        case .tmr(let command):
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
        case .restoreBatchMembership: .restoreBatchMembership
        case .addIngredient: .addIngredient
        case .createRecipe: .createRecipe
        case .addRecipeComponent: .addRecipeComponent
        case .recordFeed: .recordFeed
        case .saveFeedIngredient: .saveFeedIngredient
        case .saveFeedBatch: .saveFeedBatch
        case .adjustFeedStock: .adjustFeedStock
        case .countFeedStock: .countFeedStock
        case .saveFeedRecipe: .saveFeedRecipe
        case .recordFeedV2: .recordFeedV2
        case .recordFeedTroughObservation: .recordFeedTroughObservation
        case .importHistoricalFeed: .importHistoricalFeed
        case .recordHealth: .recordHealth
        case .receiveInventory: .receiveInventory
        case .addSemen: .addSemen
        case .recordReproduction: .recordReproduction
        case .care: .care
        case .tmr(let command): command.operationKind
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
        case .addSheep(let earTag, _, _, _, _, _, _, _): "新建羊只：\(earTag)"
        case .updateSheepProfile(_, let earTag, _, _, _, _, _, _): "更新羊只档案：\(earTag)"
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
        case .restoreBatchMembership: "撤回移出生产批次"
        case .addIngredient(let name, _, _): "新增原料：\(name)"
        case .createRecipe(let name, _): "新建配方：\(name)"
        case .addRecipeComponent: "更新配方组成"
        case .recordFeed: "记录投喂"
        case .saveFeedIngredient(let draft): "保存原料：\(draft.name)"
        case .saveFeedBatch(let draft): "保存原料批次：\(draft.batchName)"
        case .adjustFeedStock: "调整原料库存"
        case .countFeedStock: "盘库并校正原料库存"
        case .saveFeedRecipe(let draft): "保存配方：\(draft.name)"
        case .recordFeedV2: "记录投喂并扣减库存"
        case .recordFeedTroughObservation: "记录盘槽"
        case .importHistoricalFeed: "补录 eSheep+ 历史投喂（不扣库存）"
        case .recordHealth: "记录健康事项"
        case .receiveInventory(let catalogName, _, _, _, _, _): "入库：\(catalogName)"
        case .addSemen(let code, _, _, _, _): "新增冻精：\(code)"
        case .recordReproduction(_, let kind, _, _, _, _, _, _, _, _, _): "记录\(kind.displayName)"
        case .care(let command): command.summary
        case .tmr(let command): command.summary
        case .addNote: "添加备注"
        case .tombstoneEntity: "删除权威记录"
        case .restoreTombstonedEntity: "恢复已删除记录"
        }
    }
}

/// A current weaning entry is one farm workflow: record the weaning fact and
/// move the lamb into its post-weaning pen in the same transaction. Dam and
/// litter-size fields remain only for historical records and payload compatibility.
enum WeaningWorkflow {
    static func transferSourceRequestID(for weaningSourceRequestID: UUID) -> UUID {
        StableCloudUUID.derived(
            namespace: weaningSourceRequestID,
            name: "weaning-transfer"
        )
    }

    static func commands(
        sheepID: UUID,
        weanWeightText: String,
        occurredAt: Date,
        birthAt: Date?,
        toPenID: UUID,
        note: String
    ) -> [FarmCommand] {
        [
            .recordWeaning(
                sheepID: sheepID,
                weanWeightText: weanWeightText,
                occurredAt: occurredAt,
                birthAt: birthAt,
                birthWeightText: nil,
                averageDailyGainText: nil,
                damID: nil,
                litterSize: nil,
                note: note
            ),
            .transferSheep(
                sheepID: sheepID,
                toPenID: toPenID,
                occurredAt: occurredAt,
                note: "随断奶事件调舍"
            ),
        ]
    }
}

struct LegacyPhotoFilenameRepairReport: Sendable, Equatable {
    let repairedSheepCount: Int
    let reassignedPhotoCount: Int
    let skippedCandidateCount: Int

    static let empty = LegacyPhotoFilenameRepairReport(
        repairedSheepCount: 0,
        reassignedPhotoCount: 0,
        skippedCandidateCount: 0
    )
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

    private struct StagedCommandResult {
        let historyImpact: HistoryImpact?
        let operation: DomainOperation
    }

    /// A command batch owns one storage route and one sequence counter. The
    /// generic router intentionally tolerates legacy stores, but calling it for
    /// every item repeatedly scans the same sequence/profile tables.
    private final class BatchExecutionState {
        let route: FarmStorageRoute
        private let sequenceCounter: FarmOperationSequenceCounter

        init(
            farmID: UUID,
            route: FarmStorageRoute,
            context: ModelContext
        ) throws {
            self.route = route
            if let existing = try context.fetch(FetchDescriptor<FarmOperationSequenceCounter>())
                .first(where: { $0.farmID == farmID }) {
                sequenceCounter = existing
            } else {
                let highest = try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
                    .lazy
                    .filter { $0.farmID == farmID }
                    .map(\.clientSequence)
                    .max() ?? 0
                let created = FarmOperationSequenceCounter(
                    farmID: farmID,
                    nextSequence: highest + 1
                )
                context.insert(created)
                sequenceCounter = created
            }
        }

        func stageSequence(
            farmID: UUID,
            operationID: UUID,
            context: ModelContext
        ) {
            let sequence = max(1, sequenceCounter.nextSequence)
            sequenceCounter.nextSequence = sequence + 1
            context.insert(FarmOperationSequenceRecord(
                farmID: farmID,
                operationID: operationID,
                clientSequence: sequence
            ))
        }
    }

    private struct RemovalBatchSignature: Equatable {
        let kind: RemovalKind
        let reason: String
        let occurredAt: Date
        let note: String
        let batchTotalAmountText: String?
    }

    /// Removal drafts are the large AI confirmation case. Keep one active-sheep
    /// index and one set of pre-existing batch facts for the whole transaction,
    /// while still validating every command and every batch signature.
    private final class RemovalBatchExecutionState {
        let sheepByID: [UUID: SheepRecord]
        private let existingRecordsByBatchID: [UUID: [RemovalRecord]]
        private var stagedSignatureByBatchID: [UUID: RemovalBatchSignature] = [:]

        init(
            sheepByID: [UUID: SheepRecord],
            existingRecordsByBatchID: [UUID: [RemovalRecord]]
        ) {
            self.sheepByID = sheepByID
            self.existingRecordsByBatchID = existingRecordsByBatchID
        }

        func sheepRecord(id: UUID) throws -> SheepRecord {
            guard let sheep = sheepByID[id] else {
                throw FarmCommandError.sheepNotFound
            }
            return sheep
        }

        func validate(
            batchID: UUID,
            signature: RemovalBatchSignature
        ) throws {
            let existing = existingRecordsByBatchID[batchID] ?? []
            guard existing.allSatisfy({
                $0.kind == signature.kind &&
                    $0.reason == signature.reason &&
                    $0.occurredAt == signature.occurredAt &&
                    $0.note == signature.note &&
                    $0.batchTotalAmountText == signature.batchTotalAmountText
            }) else {
                throw FarmCommandError.invalidRemovalBatch("同一批次的类型、原因、日期、备注和总额必须一致。")
            }
            if let staged = stagedSignatureByBatchID[batchID], staged != signature {
                throw FarmCommandError.invalidRemovalBatch("同一批次的类型、原因、日期、备注和总额必须一致。")
            }
            stagedSignatureByBatchID[batchID] = signature
        }
    }

    private struct LegacyPhotoFilenameRepairPlan {
        let ghost: SheepRecord
        let target: SheepRecord
        let photos: [PhotoAssetRecord]
    }

    private struct CompositeChildSnapshot {
        let sheepIDs: Set<UUID>
        let weightIDs: Set<UUID>

        static let empty = CompositeChildSnapshot(
            sheepIDs: [],
            weightIDs: []
        )
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
        entitlement _: AccountEntitlement,
        context: ModelContext
    ) throws -> FarmRecord {
        let trimmedName = try required(name, label: "牧场名称")
        let farm = FarmRecord(ownerAccountID: account.effectiveAccountID, name: trimmedName)
        context.insert(farm)
        context.insert(FarmStorageProfile(farmID: farm.id, mode: .localOnly))
        var cloudPayload = FarmCommandCloudPayload(kind: .createFarm)
        cloudPayload.strings["name"] = trimmedName
        let payload = try JSONEncoder.cloud.encode(cloudPayload)
        let operationID = UUID()
        let operation = DomainOperation(
            id: operationID,
            farmID: farm.id,
            accountID: account.effectiveAccountID,
            kind: .createFarm,
            summary: "新建牧场：\(trimmedName)",
            entityType: CloudEntityType.farm.rawValue,
            entityID: farm.id,
            payload: payload
        )
        context.insert(operation)
        context.insert(FarmOperationSequenceCounter(farmID: farm.id, nextSequence: 2))
        context.insert(FarmOperationSequenceRecord(
            farmID: farm.id,
            operationID: operationID,
            clientSequence: 1
        ))
        try context.save()
        return farm
    }

    func execute(_ command: FarmCommand, in farm: FarmContext, context: ModelContext) throws {
        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        try validateStorageRoute(in: farm, context: context)
        if let impact = try executeWithoutSaving(command, in: farm, context: context) {
            try rebuildHistoryIfNeeded(for: [impact], farmID: farm.farmID, context: context)
        }
        try context.save()
        committed = true
        FarmOperationalAlertRuntimeNotification.post(farmID: farm.farmID)
        if try FarmStorageRouter.route(farmID: farm.farmID, context: context).requiresOutbox {
            CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        }
    }

    /// Updates only the selected profile photo while preserving the existing
    /// `updateSheepProfile` cloud contract for older clients and providers.
    func setSheepAvatar(
        sheepID: UUID,
        photoAssetID: UUID?,
        in farm: FarmContext,
        context: ModelContext
    ) throws {
        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        try validateStorageRoute(in: farm, context: context)
        let sheep = try sheepRecord(sheepID, farmID: farm.farmID, context: context)
        let update = SheepAvatarPhotoUpdate(photoAssetID: photoAssetID)
        try SheepAvatarSelectionStore.validate(
            update,
            sheepID: sheepID,
            farmID: farm.farmID,
            context: context
        )
        let command = FarmCommand.updateSheepProfile(
            sheepID: sheep.id,
            earTag: sheep.earTag,
            breed: sheep.breed,
            sex: sheep.sex,
            birthAt: sheep.birthAt,
            note: sheep.note
        )
        _ = try executeWithoutSaving(
            command,
            in: farm,
            context: context,
            sheepAvatarUpdate: update
        )
        try context.save()
        committed = true
        FarmOperationalAlertRuntimeNotification.post(farmID: farm.farmID)
        if try FarmStorageRouter.route(farmID: farm.farmID, context: context).requiresOutbox {
            CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        }
    }

    /// Repairs a narrowly identifiable legacy-import artifact: an archived
    /// sheep created only because an image filename such as `S005.jpg` was
    /// mistaken for an ear tag. The photo projection is moved first and the
    /// synthetic sheep is then tombstoned through the normal command pipeline.
    func legacyPhotoFilenameRepairAssetIDs(
        farmID: UUID,
        context: ModelContext
    ) throws -> [UUID] {
        let candidates = try legacyPhotoFilenameRepairPlans(
            farmID: farmID,
            context: context
        )
        return Array(Set(candidates.plans.flatMap { $0.photos.map(\.id) }))
            .sorted { $0.uuidString < $1.uuidString }
    }

    @discardableResult
    func repairLegacyPhotoFilenameSheep(
        in farm: FarmContext,
        context: ModelContext
    ) throws -> LegacyPhotoFilenameRepairReport {
        let candidates = try legacyPhotoFilenameRepairPlans(
            farmID: farm.farmID,
            context: context
        )
        guard !candidates.plans.isEmpty else {
            return LegacyPhotoFilenameRepairReport(
                repairedSheepCount: 0,
                reassignedPhotoCount: 0,
                skippedCandidateCount: candidates.skippedCount
            )
        }
        guard farm.capabilities.allows(.deleteProtectedFacts) else {
            return LegacyPhotoFilenameRepairReport(
                repairedSheepCount: 0,
                reassignedPhotoCount: 0,
                skippedCandidateCount: candidates.skippedCount + candidates.plans.count
            )
        }

        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        try validateStorageRoute(in: farm, context: context)
        let route = try FarmStorageRouter.route(farmID: farm.farmID, context: context)
        let applicablePlans = candidates.plans
        let providerSkippedCount = 0
        guard !applicablePlans.isEmpty else {
            return LegacyPhotoFilenameRepairReport(
                repairedSheepCount: 0,
                reassignedPhotoCount: 0,
                skippedCandidateCount: candidates.skippedCount + providerSkippedCount
            )
        }

        var photoRevisionByID = Dictionary(
            grouping: try context.fetch(FetchDescriptor<DomainOperation>()).filter {
                $0.farmID == farm.farmID &&
                    $0.entityType == CloudEntityType.photoAsset.rawValue &&
                    $0.entityID != nil
            },
            by: { $0.entityID! }
        ).mapValues { operations in
            max(1, operations.map(\.resultingRevision).max() ?? 1)
        }
        var historyImpacts: [HistoryImpact] = []
        var reassignedPhotoCount = 0

        for plan in applicablePlans {
            for photo in plan.photos {
                photo.sheepID = plan.target.id
                photo.originalEarTag = plan.target.earTag
                switch route.deliveryProvider {
                case .supabase:
                    let baseRevision = photoRevisionByID[photo.id] ?? 1
                    try stageSupabasePhotoProjectionRefresh(
                        photo: photo,
                        targetSheep: plan.target,
                        baseRevision: baseRevision,
                        farm: farm,
                        route: route,
                        context: context
                    )
                    photoRevisionByID[photo.id] = baseRevision + 1
                case .retiredAppleCloud:
                    throw FarmCommandError.cloudIdentityLocked
                case nil:
                    break
                }
                reassignedPhotoCount += 1
            }
            if let impact = try executeWithoutSaving(
                .tombstoneEntity(
                    entityType: .sheep,
                    entityID: plan.ghost.id,
                    reason: "修复旧版照片文件名误建羊只：\(plan.ghost.earTag) → \(plan.target.earTag)"
                ),
                in: farm,
                context: context
            ) {
                historyImpacts.append(impact)
            }
        }
        try rebuildHistoryIfNeeded(
            for: historyImpacts,
            farmID: farm.farmID,
            context: context
        )
        try context.save()
        committed = true
        FarmOperationalAlertRuntimeNotification.post(farmID: farm.farmID)
        if route.requiresOutbox {
            CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        }
        return LegacyPhotoFilenameRepairReport(
            repairedSheepCount: applicablePlans.count,
            reassignedPhotoCount: reassignedPhotoCount,
            skippedCandidateCount: candidates.skippedCount + providerSkippedCount
        )
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
        try validateStorageRoute(in: farm, context: context)
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
        FarmOperationalAlertRuntimeNotification.post(farmID: farm.farmID)
        if try FarmStorageRouter.route(farmID: farm.farmID, context: context).requiresOutbox {
            CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        }
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
        let pedigreeSheepByID = try pedigreeBatchSheepByID(
            for: commands,
            farmID: farm.farmID,
            context: context
        )
        var index = 0
        try performBatch(
            in: farm,
            context: context,
            pedigreeSheepByID: pedigreeSheepByID
        ) {
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
        try validateStorageRoute(in: farm, context: context)

        var pendingHistory: [HistoryImpact] = []
        var receiptBySourceRequestID: [UUID: FarmCommandExecutionReceipt] = [:]
        var operationBySourceRequestID: [UUID: DomainOperation] = [:]
        let requestedSourceIDs = Set(requests.map(\.sourceRequestID))
        let farmID = farm.farmID
        let accountID = farm.accountID
        let existingReceipts = try context.fetch(
            FetchDescriptor<InsightExecutionReceiptRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.accountID == accountID
            })
        )
        for existing in existingReceipts where requestedSourceIDs.contains(existing.sourceRequestID) {
            receiptBySourceRequestID[existing.sourceRequestID] = FarmCommandExecutionReceipt(
                sourceRequestID: existing.sourceRequestID,
                operationID: existing.operationID,
                entityType: existing.entityType,
                entityID: existing.entityID,
                createdAt: existing.createdAt
            )
        }
        let route = try FarmStorageRouter.route(farmID: farm.farmID, context: context)
        let commandsToExecute = requests.compactMap { request in
            receiptBySourceRequestID[request.sourceRequestID] == nil
                ? request.command
                : nil
        }
        let batchState = commandsToExecute.isEmpty
            ? nil
            : try BatchExecutionState(
                farmID: farm.farmID,
                route: route,
                context: context
            )
        let pedigreeSheepByID = try pedigreeBatchSheepByID(
            for: commandsToExecute,
            farmID: farm.farmID,
            context: context
        )
        let removalBatchState = try removalBatchExecutionState(
            for: commandsToExecute,
            farmID: farm.farmID,
            context: context
        )

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
            if receiptBySourceRequestID[request.sourceRequestID] != nil {
                continue
            }
            if !affectsHistoryProjection(request.command) {
                try flushHistory()
            }
            let staged = try stageCommandWithoutSaving(
                request.command,
                in: farm,
                context: context,
                sourceRequestID: request.sourceRequestID,
                pedigreeSheepByID: pedigreeSheepByID,
                removalBatchState: removalBatchState,
                batchState: batchState
            )
            operationBySourceRequestID[request.sourceRequestID] = staged.operation
            if let impact = staged.historyImpact {
                pendingHistory.append(impact)
            }
        }
        try flushHistory()

        for request in requests where receiptBySourceRequestID[request.sourceRequestID] == nil {
            guard let operation = operationBySourceRequestID[request.sourceRequestID] else {
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
        FarmOperationalAlertRuntimeNotification.post(farmID: farm.farmID)
        if route.requiresOutbox {
            CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        }
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

    private func performBatch(
        in farm: FarmContext,
        context: ModelContext,
        pedigreeSheepByID: [UUID: SheepRecord]? = nil,
        nextCommand: () throws -> FarmCommand?
    ) throws {
        var committed = false
        defer {
            if !committed { context.rollback() }
        }
        try validateStorageRoute(in: farm, context: context)
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
            if let impact = try executeWithoutSaving(
                command,
                in: farm,
                context: context,
                pedigreeSheepByID: pedigreeSheepByID
            ) {
                pendingHistory.append(impact)
            }
        }
        try flushHistory()
        try context.save()
        committed = true
        FarmOperationalAlertRuntimeNotification.post(farmID: farm.farmID)
        if try FarmStorageRouter.route(farmID: farm.farmID, context: context).requiresOutbox {
            CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        }
    }

    private func legacyPhotoFilenameRepairPlans(
        farmID: UUID,
        context: ModelContext
    ) throws -> (plans: [LegacyPhotoFilenameRepairPlan], skippedCount: Int) {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter {
            $0.farmID == farmID && $0.deletedAt == nil
        }
        let referencedSheepIDs = try legacyPhotoRepairReferencedSheepIDs(
            farmID: farmID,
            sheep: sheep,
            context: context
        )
        var plans: [LegacyPhotoFilenameRepairPlan] = []
        var skippedCount = 0

        for ghost in sheep where ghost.isHistoricalArchive && ghost.status == .removed {
            let sourceName = ghost.legacyEarTag ?? ghost.earTag
            guard let repairedEarTag = LegacyPhotoFilenameIdentity.earTag(from: sourceName),
                  EarTag.normalized(repairedEarTag) != EarTag.normalized(sourceName),
                  ghost.note == "由照片历史记录自动补建",
                  ghost.purpose == "历史归档",
                  let legacySourceKey = ghost.legacySourceKey,
                  legacySourceKey.lowercased().hasPrefix("history.archive.") else {
                continue
            }
            let sourceSuffix = String(legacySourceKey.dropFirst("history.archive.".count))
            guard EarTag.normalized(sourceSuffix) == EarTag.normalized(sourceName) else {
                skippedCount += 1
                continue
            }
            let matchingTargets = sheep.filter {
                $0.id != ghost.id &&
                    !$0.isHistoricalArchive &&
                    (EarTag.normalized($0.earTag) == EarTag.normalized(repairedEarTag) ||
                        EarTag.normalized($0.legacyEarTag ?? "") == EarTag.normalized(repairedEarTag))
            }
            guard matchingTargets.count == 1,
                  let target = matchingTargets.first,
                  !referencedSheepIDs.contains(ghost.id) else {
                skippedCount += 1
                continue
            }
            plans.append(LegacyPhotoFilenameRepairPlan(
                ghost: ghost,
                target: target,
                photos: photos.filter { $0.sheepID == ghost.id }
            ))
        }
        return (plans, skippedCount)
    }

    private func legacyPhotoRepairReferencedSheepIDs(
        farmID: UUID,
        sheep: [SheepRecord],
        context: ModelContext
    ) throws -> Set<UUID> {
        var values = Set<UUID>()
        for value in sheep {
            if let damID = value.damID { values.insert(damID) }
            if let sireID = value.sireID { values.insert(sireID) }
        }
        for value in try context.fetch(FetchDescriptor<WeightRecord>()) where value.farmID == farmID {
            values.insert(value.sheepID)
        }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>()) where value.farmID == farmID {
            values.insert(value.sheepID)
            if let damID = value.damID { values.insert(damID) }
        }
        for value in try context.fetch(FetchDescriptor<TransferRecord>()) where value.farmID == farmID {
            values.insert(value.sheepID)
        }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>()) where value.farmID == farmID {
            values.insert(value.sheepID)
        }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>()) where value.farmID == farmID {
            values.insert(value.sheepID)
        }
        for value in try context.fetch(FetchDescriptor<HealthRecord>()) where value.farmID == farmID {
            if let sheepID = value.sheepID { values.insert(sheepID) }
        }
        for value in try context.fetch(FetchDescriptor<HealthSubjectLink>()) where value.farmID == farmID {
            values.insert(value.sheepID)
        }
        for value in try context.fetch(FetchDescriptor<ReproductionRecord>()) where value.farmID == farmID {
            values.insert(value.eweID)
            if let sireID = value.sireID { values.insert(sireID) }
        }
        for value in try context.fetch(FetchDescriptor<LambingOffspringRecord>()) where value.farmID == farmID {
            if let sheepID = value.sheepID { values.insert(sheepID) }
        }
        for value in try context.fetch(FetchDescriptor<NoteRecord>()) where value.farmID == farmID {
            if let sheepID = value.sheepID { values.insert(sheepID) }
        }
        for value in try context.fetch(FetchDescriptor<CareReminderRecord>()) where value.farmID == farmID {
            if let sheepID = value.sheepID { values.insert(sheepID) }
        }
        for value in try context.fetch(FetchDescriptor<PedigreeChangeRecord>()) where value.farmID == farmID {
            values.insert(value.sheepID)
            for relatedID in [
                value.beforeDamID, value.afterDamID,
                value.beforeSireID, value.afterSireID
            ].compactMap({ $0 }) {
                values.insert(relatedID)
            }
        }
        for value in try context.fetch(FetchDescriptor<SheepAvatarRecord>()) where value.farmID == farmID {
            values.insert(value.sheepID)
        }
        return values
    }

    private func stageSupabasePhotoProjectionRefresh(
        photo: PhotoAssetRecord,
        targetSheep: SheepRecord,
        baseRevision: Int,
        farm: FarmContext,
        route: FarmStorageRoute,
        context: ModelContext
    ) throws {
        var payload = FarmCommandCloudPayload(kind: .addPhoto)
        payload.strings = [
            "sha256": photo.sha256,
            "sourceSHA256": photo.sourceSHA256.isEmpty ? photo.sha256 : photo.sourceSHA256,
            "mimeType": photo.mimeType,
            "originalEarTag": targetSheep.earTag
        ]
        payload.optionalIdentifiers = ["sheepID": targetSheep.id]
        payload.optionalDates = ["capturedAt": photo.capturedAt]
        let transferByteCount = try context.fetch(FetchDescriptor<CloudAssetTransfer>())
            .first(where: { $0.farmID == farm.farmID && $0.assetID == photo.id })?
            .byteCount ?? 0
        payload.integers = [
            "sourcePixelWidth": photo.sourcePixelWidth,
            "sourcePixelHeight": photo.sourcePixelHeight,
            "cloudPixelWidth": photo.cloudPixelWidth,
            "cloudPixelHeight": photo.cloudPixelHeight,
            "byteCount": Int(clamping: transferByteCount)
        ]
        let operationID = UUID()
        _ = try FarmStorageRouter.takeNextOperationSequence(
            farmID: farm.farmID,
            operationID: operationID,
            context: context
        )
        let operation = DomainOperation(
            id: operationID,
            farmID: farm.farmID,
            accountID: farm.accountID,
            kind: .addPhoto,
            summary: "修复照片归属：\(targetSheep.earTag)",
            entityType: CloudEntityType.photoAsset.rawValue,
            entityID: photo.id,
            baseRevision: baseRevision,
            resultingRevision: baseRevision + 1,
            payload: try JSONEncoder.cloud.encode(payload)
        )
        context.insert(operation)
        context.insert(OutboxItem(
            farmID: farm.farmID,
            accountID: farm.accountID,
            operationID: operation.id,
            entityType: operation.entityType,
            entityID: operation.entityID,
            baseRevision: operation.baseRevision,
            payloadDigest: operation.payloadDigest,
            deliveryProvider: .supabase,
            authorityGeneration: route.deliveryAuthorityGeneration
        ))
    }

    private func validateStorageRoute(in farm: FarmContext, context: ModelContext) throws {
        let farmID = farm.farmID
        let route = try FarmStorageRouter.route(farmID: farmID, context: context)
        switch route.mode {
        case .localOnly:
            return
        case .supabase:
            let remoteBinding = try context.fetch(FetchDescriptor<FarmRemoteBinding>()).first {
                $0.farmID == farmID &&
                $0.provider == .supabase
            }
            guard remoteBinding?.state == .active else {
                throw FarmCommandError.cloudIdentityLocked
            }
            return
        case .retiredAppleCloud:
            throw FarmCommandError.cloudIdentityLocked
        }
    }

    private func executeWithoutSaving(
        _ command: FarmCommand,
        in farm: FarmContext,
        context: ModelContext,
        sourceRequestID: UUID? = nil,
        pedigreeSheepByID: [UUID: SheepRecord]? = nil,
        sheepAvatarUpdate: SheepAvatarPhotoUpdate? = nil
    ) throws -> HistoryImpact? {
        try stageCommandWithoutSaving(
            command,
            in: farm,
            context: context,
            sourceRequestID: sourceRequestID,
            pedigreeSheepByID: pedigreeSheepByID,
            sheepAvatarUpdate: sheepAvatarUpdate
        ).historyImpact
    }

    private func stageCommandWithoutSaving(
        _ command: FarmCommand,
        in farm: FarmContext,
        context: ModelContext,
        sourceRequestID: UUID? = nil,
        pedigreeSheepByID: [UUID: SheepRecord]? = nil,
        sheepAvatarUpdate: SheepAvatarPhotoUpdate? = nil,
        removalBatchState: RemovalBatchExecutionState? = nil,
        batchState: BatchExecutionState? = nil
    ) throws -> StagedCommandResult {
        let farmID = farm.farmID
        guard farm.capabilities.allows(command.requiredCapability) else {
            throw FarmPermissionError.denied(command.requiredCapability)
        }

        try validate(
            command,
            farmID: farm.farmID,
            context: context,
            removalBatchState: removalBatchState
        )
        let compositeChildrenBefore = try compositeChildSnapshot(
            for: command,
            farmID: farm.farmID,
            context: context
        )
        let result = try apply(
            command,
            farm: farm,
            context: context,
            pedigreeSheepByID: pedigreeSheepByID,
            sheepAvatarUpdate: sheepAvatarUpdate,
            removalBatchState: removalBatchState
        )
        let projectedHistoryImpact = try historyImpact(for: command, result: result, farmID: farm.farmID, context: context)
        let operationID = UUID()
        if let batchState {
            batchState.stageSequence(
                farmID: farm.farmID,
                operationID: operationID,
                context: context
            )
        } else {
            _ = try FarmStorageRouter.takeNextOperationSequence(
                farmID: farm.farmID,
                operationID: operationID,
                context: context
            )
        }
        let operation = DomainOperation(
            id: operationID,
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
        let route: FarmStorageRoute
        if let batchState {
            route = batchState.route
        } else {
            route = try FarmStorageRouter.route(farmID: farm.farmID, context: context)
        }
        if let deliveryProvider = route.deliveryProvider {
            context.insert(OutboxItem(
                farmID: farm.farmID,
                accountID: farm.accountID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID,
                baseRevision: operation.baseRevision,
                payloadDigest: operation.payloadDigest,
                deliveryProvider: deliveryProvider,
                authorityGeneration: route.deliveryAuthorityGeneration
            ))
        }
        try stageNewCompositeChildOperations(
            for: command,
            parentOperation: operation,
            childrenBefore: compositeChildrenBefore,
            farm: farm,
            route: route,
            batchState: batchState,
            context: context
        )
        return StagedCommandResult(
            historyImpact: projectedHistoryImpact,
            operation: operation
        )
    }

    /// Older clients encoded lambing and its automatically created lamb/weight
    /// projections in one care operation. Replaying that payload rebuilds the
    /// local children, but Supabase's provider-neutral entity table only sees
    /// the operation's primary reproduction entity. Persist explicit child
    /// operations in the same command transaction so later edits have a real
    /// remote revision chain and a compact checkpoint can restore them alone.
    private func compositeChildSnapshot(
        for command: FarmCommand,
        farmID: UUID,
        context: ModelContext
    ) throws -> CompositeChildSnapshot {
        let capturesLambingChildren = Self.lambingDraft(from: command) != nil
        guard capturesLambingChildren else {
            return .empty
        }
        return CompositeChildSnapshot(
            sheepIDs: capturesLambingChildren
                ? Set(try context.fetch(FetchDescriptor<SheepRecord>())
                    .lazy.filter { $0.farmID == farmID }.map(\.id))
                : [],
            weightIDs: capturesLambingChildren
                ? Set(try context.fetch(FetchDescriptor<WeightRecord>())
                    .lazy.filter { $0.farmID == farmID }.map(\.id))
                : []
        )
    }

    private func stageNewCompositeChildOperations(
        for command: FarmCommand,
        parentOperation: DomainOperation,
        childrenBefore: CompositeChildSnapshot,
        farm: FarmContext,
        route: FarmStorageRoute,
        batchState: BatchExecutionState?,
        context: ModelContext
    ) throws {
        if let draft = Self.lambingDraft(from: command) {
            let intendedSheepIDs = Set<UUID>(draft.offspring
                .filter { $0.createSheepRecord }.map { $0.sheepID })
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
                $0.farmID == farm.farmID &&
                    intendedSheepIDs.contains($0.id) &&
                    !childrenBefore.sheepIDs.contains($0.id)
            }
            let offspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter {
                $0.farmID == farm.farmID && $0.lambingRecordID == draft.id
            }
            let intendedWeightIDs = Set<UUID>(offspring.compactMap {
                $0.autoBirthWeightRecordID
            })
            let weights = try context.fetch(FetchDescriptor<WeightRecord>()).filter {
                $0.farmID == farm.farmID &&
                    intendedWeightIDs.contains($0.id) &&
                    !childrenBefore.weightIDs.contains($0.id)
            }
            try stageCompositeChildOperations(
                parentOperation: parentOperation,
                sheep: sheep,
                weights: weights,
                accountID: farm.accountID,
                route: route,
                batchState: batchState,
                context: context
            )
        }

        if case .createBatch(_, _, let startedAt, let sheepIDs, _) = command,
           let batchID = parentOperation.entityID {
            try stageNewBatchMembershipProjectionOperations(
                parentOperation: parentOperation,
                batchID: batchID,
                sheepIDs: sheepIDs,
                joinedAt: startedAt,
                farmID: farm.farmID,
                accountID: farm.accountID,
                route: route,
                batchState: batchState,
                context: context
            )
        }
    }

    /// Build child facts directly from the validated create command. SwiftData
    /// does not guarantee that a fetch made before the transaction is saved
    /// will include every pending membership insert on every runtime.
    private func stageNewBatchMembershipProjectionOperations(
        parentOperation: DomainOperation,
        batchID: UUID,
        sheepIDs: [UUID],
        joinedAt: Date,
        farmID: UUID,
        accountID: UUID,
        route: FarmStorageRoute,
        batchState: BatchExecutionState?,
        context: ModelContext
    ) throws {
        for sheepID in sheepIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            let membershipID = StableCloudUUID.derived(
                namespace: batchID,
                name: "batch-member-\(sheepID.uuidString.lowercased())"
            )
            let operation = DomainOperation(
                id: Self.compositeBatchMembershipOperationID(
                    parentOperationID: parentOperation.id,
                    membershipID: membershipID
                ),
                farmID: farmID,
                accountID: accountID,
                kind: .assignBatchMembership,
                occurredAt: joinedAt,
                summary: "生产批次成员投影",
                entityType: CloudEntityType.batchMembership.rawValue,
                entityID: membershipID,
                baseRevision: 0,
                resultingRevision: 1,
                payload: try FarmCommandCloudPayloadEncoder.encode(
                    .assignSheepToBatch(
                        batchID: batchID,
                        sheepID: sheepID,
                        joinedAt: joinedAt
                    )
                )
            )
            try stageCompositeChildOperation(
                operation,
                route: route,
                batchState: batchState,
                context: context
            )
        }
    }

    /// A create-batch operation also materializes stable membership children.
    /// Supabase stores only the operation's primary entity, so every child
    /// needs its own immutable operation before a later leave/restore can use
    /// a valid remote revision chain.
    private func stageBatchMembershipProjectionOperations(
        parentOperation: DomainOperation,
        memberships: [BatchMembershipRecord],
        accountID: UUID,
        route: FarmStorageRoute,
        batchState: BatchExecutionState?,
        context: ModelContext
    ) throws {
        for membership in memberships.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            var payload = try Self.decodeCloudPayload(
                FarmCommandCloudPayloadEncoder.encode(.assignSheepToBatch(
                    batchID: membership.batchID,
                    sheepID: membership.sheepID,
                    joinedAt: membership.joinedAt
                ))
            )
            payload.optionalDates["leftAt"] = membership.leftAt
            payload.optionalStrings["leaveReason"] = membership.leaveReason
            let operation = DomainOperation(
                id: Self.compositeBatchMembershipOperationID(
                    parentOperationID: parentOperation.id,
                    membershipID: membership.id
                ),
                farmID: membership.farmID,
                accountID: accountID,
                kind: .assignBatchMembership,
                occurredAt: membership.updatedAt,
                summary: "生产批次成员投影",
                entityType: CloudEntityType.batchMembership.rawValue,
                entityID: membership.id,
                baseRevision: 0,
                resultingRevision: 1,
                payload: try JSONEncoder.cloud.encode(payload)
            )
            try stageCompositeChildOperation(
                operation,
                route: route,
                batchState: batchState,
                context: context
            )
        }
    }

    /// Backfills only children of already confirmed Supabase care operations.
    /// Baseline history has no confirmed Supabase Outbox item, so it is never
    /// mistaken for a post-activation operation and cannot be uploaded twice.
    @discardableResult
    func repairMissingCompositeChildDeliveryOperations(
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        let route = try FarmStorageRouter.route(farmID: farmID, context: context)
        guard route.deliveryProvider == .supabase else { return 0 }
        let confirmedParentIDs = Set(try context.fetch(FetchDescriptor<OutboxItem>()).lazy
            .filter {
                $0.farmID == farmID &&
                    $0.deliveryProvider == .supabase &&
                    $0.status == .confirmed
            }
            .map(\.operationID))
        guard !confirmedParentIDs.isEmpty else { return 0 }

        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farmID &&
                confirmedParentIDs.contains($0.id) &&
                $0.kindRawValue == DomainOperationKind.care.rawValue
        }
        let existingOperations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farmID
        }
        let existingOperationsByID = Dictionary(uniqueKeysWithValues:
            existingOperations.map { ($0.id, $0) }
        )
        // Keep legacy-provider rows in scope. A farm can switch authority after
        // the original composite operation was staged, leaving more than one
        // Outbox row for the same operation ID.
        let existingOutboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farmID
        }
        var insertedCount = 0
        for parent in operations {
            guard let payload = try? Self.decodeCloudPayload(parent.payload),
            let careCommand = payload.careCommand,
            let draft = Self.lambingDraft(from: .care(careCommand)) else {
                continue
            }
            let intendedSheepIDs = Set<UUID>(draft.offspring
                .filter { $0.createSheepRecord }.map { $0.sheepID })
            var correctedSheepIDs = Set<UUID>()
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
                $0.farmID == farmID && intendedSheepIDs.contains($0.id)
            }.filter {
                let originalID = Self.compositeSheepOperationID(
                    parentOperationID: parent.id,
                    sheepID: $0.id
                )
                let correctedID = Self.correctedCompositeSheepOperationID(
                    parentOperationID: parent.id,
                    sheepID: $0.id
                )
                guard existingOperationsByID[correctedID] == nil else { return false }
                guard let original = existingOperationsByID[originalID] else { return true }
                let originalOutboxes = existingOutboxes.filter {
                    $0.operationID == originalID
                }
                let hasInvalidRevision = originalOutboxes.contains {
                        $0.status == .retryableFailure &&
                        $0.errorMessage == "resulting_revision_invalid"
                }
                let hasConfirmedAuthoritativeDelivery = originalOutboxes.contains {
                    $0.deliveryProvider == .supabase && $0.status == .confirmed
                }
                guard original.baseRevision == 0,
                      original.resultingRevision != 1,
                      hasInvalidRevision,
                      !hasConfirmedAuthoritativeDelivery else {
                    return false
                }
                // The operation revision is invalid regardless of which
                // authority row received the rejection. Retire every
                // non-terminal duplicate so the corrected operation is the
                // only deliverable fact.
                for item in originalOutboxes where !item.status.isTerminalDelivery {
                    item.statusRawValue = OutboxStatus.supersededRemoteAuthority.rawValue
                    item.errorMessage = "superseded_invalid_child_revision"
                    item.nextRetryAt = nil
                }
                correctedSheepIDs.insert($0.id)
                return true
            }
            let offspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter {
                $0.farmID == farmID && $0.lambingRecordID == draft.id
            }
            let intendedWeightIDs = Set<UUID>(offspring.compactMap {
                $0.autoBirthWeightRecordID
            })
            let weights = try context.fetch(FetchDescriptor<WeightRecord>()).filter {
                $0.farmID == farmID && intendedWeightIDs.contains($0.id)
            }.filter {
                existingOperationsByID[Self.compositeWeightOperationID(
                    parentOperationID: parent.id,
                    weightID: $0.id
                )] == nil
            }
            insertedCount += sheep.count + weights.count
            try stageCompositeChildOperations(
                parentOperation: parent,
                sheep: sheep,
                weights: weights,
                accountID: parent.accountID,
                route: route,
                batchState: nil,
                correctedSheepOperationIDs: correctedSheepIDs,
                context: context
            )
        }
        if insertedCount > 0 { try context.save() }
        return insertedCount
    }

    /// Older create-batch operations materialized membership rows locally and
    /// on replay, but did not give those rows their own provider-neutral cloud
    /// operation. Backfill only children of a confirmed Supabase parent: this
    /// proves the batch was created after activation and that the server saw
    /// the parent while never receiving the missing child entity.
    @discardableResult
    func repairMissingProductionBatchMembershipDeliveryOperations(
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        let route = try FarmStorageRouter.route(farmID: farmID, context: context)
        guard route.deliveryProvider == .supabase else { return 0 }
        let outboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farmID && $0.deliveryProvider == .supabase
        }
        let confirmedOperationIDs = Set(outboxes.lazy
            .filter { $0.status == .confirmed }
            .map(\.operationID))
        guard !confirmedOperationIDs.isEmpty else { return 0 }

        let farmOperations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farmID
        }
        let confirmedParents = farmOperations.filter {
            confirmedOperationIDs.contains($0.id) &&
                $0.kindRawValue == DomainOperationKind.createBatch.rawValue
        }
        guard !confirmedParents.isEmpty else { return 0 }
        let existingMembershipCreationIDs = Set(farmOperations.lazy.compactMap {
            $0.kindRawValue == DomainOperationKind.assignBatchMembership.rawValue
                ? $0.entityID
                : nil
        })
        var insertedCount = 0
        for parent in confirmedParents {
            guard let batchID = parent.entityID else { continue }
            let missing = try context.fetch(
                FetchDescriptor<BatchMembershipRecord>()
            ).filter {
                $0.farmID == farmID &&
                    $0.batchID == batchID &&
                    !existingMembershipCreationIDs.contains($0.id)
            }
            guard !missing.isEmpty else { continue }
            try stageBatchMembershipProjectionOperations(
                parentOperation: parent,
                memberships: missing,
                accountID: parent.accountID,
                route: route,
                batchState: nil,
                context: context
            )
            insertedCount += missing.count
        }
        if insertedCount > 0 { try context.save() }
        return insertedCount
    }

    /// Once a backfilled membership snapshot is confirmed, older leave/restore
    /// attempts that ended in exactly the same local state are audit history,
    /// not deliverable work. Retire them without deleting either operation.
    @discardableResult
    func supersedeBlockedBatchMembershipChainsCoveredByConfirmedProjection(
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        let outboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farmID && $0.deliveryProvider == .supabase
        }
        let confirmedOperationIDs = Set(outboxes.lazy
            .filter { $0.status == .confirmed }
            .map(\.operationID))
        let blocked = outboxes.filter {
            $0.status == .blockedConflict &&
                $0.errorMessage == "base_revision_mismatch" &&
                $0.entityType == CloudEntityType.batchMembership.rawValue
        }
        guard !blocked.isEmpty else { return 0 }
        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farmID
        }
        let confirmedSnapshots = operations.filter {
            confirmedOperationIDs.contains($0.id) &&
                $0.kindRawValue == DomainOperationKind.assignBatchMembership.rawValue
        }
        var snapshotByEntityID: [UUID: DomainOperation] = [:]
        for operation in confirmedSnapshots {
            guard let entityID = operation.entityID else { continue }
            if let existing = snapshotByEntityID[entityID],
               existing.resultingRevision >= operation.resultingRevision {
                continue
            }
            snapshotByEntityID[entityID] = operation
        }
        let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter {
            $0.farmID == farmID
        }
        var membershipByID: [UUID: BatchMembershipRecord] = [:]
        for membership in memberships {
            if let existing = membershipByID[membership.id],
               existing.updatedAt >= membership.updatedAt {
                continue
            }
            membershipByID[membership.id] = membership
        }
        var repairedCount = 0
        for item in blocked {
            guard let entityID = item.entityID,
                  let snapshot = snapshotByEntityID[entityID],
                  let membership = membershipByID[entityID],
                  let payload = try? Self.decodeCloudPayload(snapshot.payload) else {
                continue
            }
            let snapshotLeftAt = payload.optionalDates["leftAt"] ?? nil
            let snapshotLeaveReason = payload.optionalStrings["leaveReason"] ?? nil
            guard snapshotLeftAt == membership.leftAt,
                  snapshotLeaveReason == membership.leaveReason else {
                continue
            }
            item.statusRawValue = OutboxStatus.supersededRemoteAuthority.rawValue
            item.errorMessage = "superseded_by_confirmed_membership_projection:" +
                snapshot.id.uuidString.lowercased()
            item.nextRetryAt = nil
            repairedCount += 1
        }
        if repairedCount > 0 { try context.save() }
        return repairedCount
    }

    /// Re-importing a stable removal ID after the original removal was undone
    /// used to create a second projection and restart at revision zero. Rebase
    /// only when the local immutable history proves a newer confirmed revision
    /// and there is exactly one active projection carrying the blocked intent.
    @discardableResult
    func repairBlockedRecreatedRemovalOperations(
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        let route = try FarmStorageRouter.route(farmID: farmID, context: context)
        guard route.deliveryProvider == .supabase else { return 0 }
        let outboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farmID && $0.deliveryProvider == .supabase
        }
        let blocked = outboxes.filter {
            $0.status == .blockedConflict &&
                $0.errorMessage == "base_revision_mismatch" &&
                $0.entityType == CloudEntityType.removal.rawValue
        }
        guard !blocked.isEmpty else { return 0 }
        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farmID
        }
        let operationsByID = Dictionary(grouping: operations, by: \.id)
        let outboxesByOperationID = Dictionary(grouping: outboxes, by: \.operationID)
        var repairedCount = 0
        var stagedRetryIDs = Set<UUID>()
        for item in blocked {
            guard let entityID = item.entityID,
                  let blockedCandidates = operationsByID[item.operationID],
                  blockedCandidates.count == 1,
                  let blockedOperation = blockedCandidates.first,
                  blockedOperation.kindRawValue == DomainOperationKind.removeSheep.rawValue else {
                continue
            }
            let authoritativeRevision = operations.lazy.filter {
                $0.entityID == entityID &&
                    (outboxesByOperationID[$0.id] == nil ||
                        outboxesByOperationID[$0.id]?.contains(where: {
                            $0.status == .confirmed
                        }) == true)
            }.map(\.resultingRevision).max() ?? 0
            guard authoritativeRevision > blockedOperation.baseRevision else {
                continue
            }
            let projections = try context.fetch(FetchDescriptor<RemovalRecord>()).filter {
                $0.farmID == farmID && $0.id == entityID
            }
            let active = projections.filter { $0.deletedAt == nil }
            guard active.count == 1, let current = active.first else { continue }
            let retryID = StableCloudUUID.derived(
                namespace: blockedOperation.id,
                name: "revision-aware-removal-retry:v1"
            )
            if operationsByID[retryID] == nil,
               stagedRetryIDs.insert(retryID).inserted {
                current.revision = authoritativeRevision + 1
                let retry = DomainOperation(
                    id: retryID,
                    farmID: farmID,
                    accountID: blockedOperation.accountID,
                    kind: .removeSheep,
                    occurredAt: blockedOperation.occurredAt,
                    summary: blockedOperation.summary,
                    entityType: blockedOperation.entityType,
                    entityID: entityID,
                    baseRevision: authoritativeRevision,
                    resultingRevision: authoritativeRevision + 1,
                    payload: blockedOperation.payload
                )
                try stageCompositeChildOperation(
                    retry,
                    route: route,
                    batchState: nil,
                    context: context
                )
            }
            for stale in projections where stale !== current {
                context.delete(stale)
            }
            item.statusRawValue = OutboxStatus.supersededRemoteAuthority.rawValue
            item.errorMessage = "superseded_by_revision_aware_retry:" +
                retryID.uuidString.lowercased()
            item.nextRetryAt = nil
            repairedCount += 1
        }
        if repairedCount > 0 { try context.save() }
        return repairedCount
    }

    /// A compact/baseline projection can carry a local model revision greater
    /// than the provider-neutral entity revision. If the first profile update
    /// is the only operation for that sheep, rebase it to the baseline's 1→2
    /// chain. Any actual remote operation disables this automatic path.
    @discardableResult
    func repairBlockedBaselineSheepProfileRevisionDrift(
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        let route = try FarmStorageRouter.route(farmID: farmID, context: context)
        guard route.deliveryProvider == .supabase else { return 0 }
        let outboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farmID && $0.deliveryProvider == .supabase
        }
        let blocked = outboxes.filter {
            $0.status == .blockedConflict &&
                $0.errorMessage == "base_revision_mismatch" &&
                $0.entityType == CloudEntityType.sheep.rawValue
        }
        guard !blocked.isEmpty else { return 0 }
        let operations = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farmID
        }
        let operationsByID = Dictionary(grouping: operations, by: \.id)
        let outboxesByOperationID = Dictionary(grouping: outboxes, by: \.operationID)
        var repairedCount = 0
        var stagedRetryIDs = Set<UUID>()
        for item in blocked {
            guard let entityID = item.entityID,
                  let blockedCandidates = operationsByID[item.operationID],
                  blockedCandidates.count == 1,
                  let blockedOperation = blockedCandidates.first,
                  blockedOperation.kindRawValue == DomainOperationKind.updateSheepProfile.rawValue,
                  blockedOperation.baseRevision > 1 else {
                continue
            }
            let otherAuthoritativeOperations = operations.filter {
                $0.entityID == entityID &&
                    $0.id != blockedOperation.id &&
                    (outboxesByOperationID[$0.id] == nil ||
                        outboxesByOperationID[$0.id]?.contains(where: {
                            $0.status == .confirmed
                        }) == true)
            }
            guard otherAuthoritativeOperations.isEmpty else { continue }
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter {
                $0.farmID == farmID && $0.id == entityID && $0.deletedAt == nil
            }
            guard sheep.count == 1, let current = sheep.first else { continue }
            let retryID = StableCloudUUID.derived(
                namespace: blockedOperation.id,
                name: "baseline-revision-profile-retry:v1"
            )
            if operationsByID[retryID] == nil,
               stagedRetryIDs.insert(retryID).inserted {
                current.revision = 2
                let retry = DomainOperation(
                    id: retryID,
                    farmID: farmID,
                    accountID: blockedOperation.accountID,
                    kind: .updateSheepProfile,
                    occurredAt: blockedOperation.occurredAt,
                    summary: blockedOperation.summary,
                    entityType: blockedOperation.entityType,
                    entityID: entityID,
                    baseRevision: 1,
                    resultingRevision: 2,
                    payload: blockedOperation.payload
                )
                try stageCompositeChildOperation(
                    retry,
                    route: route,
                    batchState: nil,
                    context: context
                )
            }
            item.statusRawValue = OutboxStatus.supersededRemoteAuthority.rawValue
            item.errorMessage = "superseded_by_baseline_revision_retry:" +
                retryID.uuidString.lowercased()
            item.nextRetryAt = nil
            repairedCount += 1
        }
        if repairedCount > 0 { try context.save() }
        return repairedCount
    }

    /// A legacy photo-name repair created valid local tombstones on clients
    /// restored from compact checkpoints, but older code derived the base
    /// revision only from visible operation history. Retry only the narrowly
    /// proven artifact whose local projection revision equals the rejected
    /// operation's resulting revision. Other conflicts remain blocked.
    @discardableResult
    func repairBlockedLegacyPhotoFilenameTombstones(
        in farm: FarmContext,
        context: ModelContext
    ) throws -> Int {
        let route = try FarmStorageRouter.route(farmID: farm.farmID, context: context)
        guard route.deliveryProvider == .supabase else { return 0 }
        let blockedItems = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
            $0.farmID == farm.farmID &&
                $0.deliveryProvider == .supabase &&
                $0.status == .blockedConflict &&
                $0.errorMessage == "base_revision_mismatch"
        }
        guard !blockedItems.isEmpty else { return 0 }
        let operationIDs = Set(blockedItems.map(\.operationID))
        let operationsByID = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<DomainOperation>()).filter {
                $0.farmID == farm.farmID && operationIDs.contains($0.id)
            }.map { ($0.id, $0) }
        )
        let sheepByID = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<SheepRecord>()).filter {
                $0.farmID == farm.farmID
            }.map { ($0.id, $0) }
        )
        var impacts: [HistoryImpact] = []
        var repairedCount = 0
        for item in blockedItems {
            guard let operation = operationsByID[item.operationID],
                  operation.kindRawValue == DomainOperationKind.tombstoneEntity.rawValue,
                  let entityID = operation.entityID,
                  let sheep = sheepByID[entityID],
                  sheep.deletedAt != nil,
                  sheep.revision == operation.resultingRevision,
                  sheep.isHistoricalArchive,
                  sheep.status == .removed,
                  sheep.note == "由照片历史记录自动补建",
                  LegacyPhotoFilenameIdentity.earTag(
                    from: sheep.legacyEarTag ?? sheep.earTag
                  ) != nil,
                  let payload = try? Self.decodeCloudPayload(operation.payload),
                  payload.kind == DomainOperationKind.tombstoneEntity,
                  payload.strings["entityType"] == CloudEntityType.sheep.rawValue,
                  payload.identifiers["entityID"] == entityID,
                  let reason = payload.strings["reason"],
                  reason.hasPrefix("修复旧版照片文件名误建羊只：") else {
                continue
            }
            if let impact = try executeWithoutSaving(
                .tombstoneEntity(
                    entityType: .sheep,
                    entityID: entityID,
                    reason: reason
                ),
                in: farm,
                context: context
            ) {
                impacts.append(impact)
            }
            item.statusRawValue = OutboxStatus.supersededRemoteAuthority.rawValue
            item.errorMessage = "superseded_by_revision_aware_retry"
            item.nextRetryAt = nil
            repairedCount += 1
        }
        guard repairedCount > 0 else { return 0 }
        try rebuildHistoryIfNeeded(
            for: impacts,
            farmID: farm.farmID,
            context: context
        )
        try context.save()
        return repairedCount
    }

    private func stageCompositeChildOperations(
        parentOperation: DomainOperation,
        sheep: [SheepRecord],
        weights: [WeightRecord],
        accountID: UUID,
        route: FarmStorageRoute,
        batchState: BatchExecutionState?,
        correctedSheepOperationIDs: Set<UUID> = [],
        context: ModelContext
    ) throws {
        for record in sheep.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let payload = try Self.sheepProjectionPayload(record)
            let operationID = correctedSheepOperationIDs.contains(record.id)
                ? Self.correctedCompositeSheepOperationID(
                    parentOperationID: parentOperation.id,
                    sheepID: record.id
                )
                : Self.compositeSheepOperationID(
                    parentOperationID: parentOperation.id,
                    sheepID: record.id
                )
            let operation = DomainOperation(
                id: operationID,
                farmID: record.farmID,
                accountID: accountID,
                kind: .addSheep,
                occurredAt: record.enteredAt,
                summary: "产羔自动建档：\(record.earTag)",
                entityType: CloudEntityType.sheep.rawValue,
                entityID: record.id,
                baseRevision: 0,
                resultingRevision: 1,
                payload: payload
            )
            try stageCompositeChildOperation(
                operation,
                route: route,
                batchState: batchState,
                context: context
            )
        }
        for record in weights.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let payload = try FarmCommandCloudPayloadEncoder.encode(.recordWeight(
                sheepID: record.sheepID,
                kilogramsText: record.kilogramsText,
                occurredAt: record.occurredAt,
                note: record.note
            ))
            let operation = DomainOperation(
                id: Self.compositeWeightOperationID(
                    parentOperationID: parentOperation.id,
                    weightID: record.id
                ),
                farmID: record.farmID,
                accountID: accountID,
                kind: .recordWeight,
                occurredAt: record.occurredAt,
                summary: "产羔自动记录初生重",
                entityType: CloudEntityType.weight.rawValue,
                entityID: record.id,
                baseRevision: 0,
                resultingRevision: 1,
                payload: payload
            )
            try stageCompositeChildOperation(
                operation,
                route: route,
                batchState: batchState,
                context: context
            )
        }
    }

    private func stageCompositeChildOperation(
        _ operation: DomainOperation,
        route: FarmStorageRoute,
        batchState: BatchExecutionState?,
        context: ModelContext
    ) throws {
        if try context.fetch(FetchDescriptor<DomainOperation>()).contains(where: {
            $0.id == operation.id && $0.farmID == operation.farmID
        }) {
            return
        }
        context.insert(operation)
        if let batchState {
            batchState.stageSequence(
                farmID: operation.farmID,
                operationID: operation.id,
                context: context
            )
        } else {
            _ = try FarmStorageRouter.takeNextOperationSequence(
                farmID: operation.farmID,
                operationID: operation.id,
                context: context
            )
        }
        if let provider = route.deliveryProvider {
            context.insert(OutboxItem(
                farmID: operation.farmID,
                accountID: operation.accountID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID,
                baseRevision: operation.baseRevision,
                payloadDigest: operation.payloadDigest,
                deliveryProvider: provider,
                authorityGeneration: route.deliveryAuthorityGeneration
            ))
        }
    }

    private static func lambingDraft(from command: FarmCommand) -> CareLambingDraft? {
        guard case .care(let care) = command else { return nil }
        switch care {
        case .recordLambing(let draft): return draft
        case .correctLambing(_, let replacement, _): return replacement
        default: return nil
        }
    }

    private static func compositeSheepOperationID(
        parentOperationID: UUID,
        sheepID: UUID
    ) -> UUID {
        StableCloudUUID.derived(
            namespace: parentOperationID,
            name: "lambing-child-sheep:\(sheepID.uuidString.lowercased())"
        )
    }

    private static func compositeWeightOperationID(
        parentOperationID: UUID,
        weightID: UUID
    ) -> UUID {
        StableCloudUUID.derived(
            namespace: parentOperationID,
            name: "lambing-child-weight:\(weightID.uuidString.lowercased())"
        )
    }

    private static func compositeBatchMembershipOperationID(
        parentOperationID: UUID,
        membershipID: UUID
    ) -> UUID {
        StableCloudUUID.derived(
            namespace: parentOperationID,
            name: "batch-child-membership:\(membershipID.uuidString.lowercased())"
        )
    }

    private static func correctedCompositeSheepOperationID(
        parentOperationID: UUID,
        sheepID: UUID
    ) -> UUID {
        StableCloudUUID.derived(
            namespace: parentOperationID,
            name: "lambing-child-sheep-v2:\(sheepID.uuidString.lowercased())"
        )
    }

    private static func sheepProjectionPayload(_ record: SheepRecord) throws -> Data {
        var payload = try decodeCloudPayload(
            FarmCommandCloudPayloadEncoder.encode(.addSheep(
                earTag: record.earTag,
                breed: record.breed,
                sex: record.sex,
                penID: record.initialPenID,
                occurredAt: record.enteredAt,
                birthAt: record.birthAt,
                note: record.note
            ))
        )
        payload.optionalStrings["legacyEarTag"] = record.legacyEarTag
        payload.optionalStrings["legacySourceKey"] = record.legacySourceKey
        payload.strings["purpose"] = record.purpose
        payload.integers["isHistoricalArchive"] = record.isHistoricalArchive ? 1 : 0
        payload.integers["isBreedingRam"] = record.isBreedingRam ? 1 : 0
        payload.optionalIdentifiers["damID"] = record.damID
        payload.optionalIdentifiers["sireID"] = record.sireID
        payload.optionalIdentifiers["semenDonorID"] = record.semenDonorID
        payload.optionalStrings["damProvenance"] = record.damProvenanceRawValue
        payload.optionalStrings["sireProvenance"] = record.sireProvenanceRawValue
        payload.optionalStrings["semenDonorNameSnapshot"] = record.semenDonorNameSnapshot
        payload.optionalStrings["semenDonorRegistrationNumberSnapshot"] =
            record.semenDonorRegistrationNumberSnapshot
        payload.optionalStrings["semenDonorBreedSnapshot"] = record.semenDonorBreedSnapshot
        return try JSONEncoder.cloud.encode(payload)
    }

    private static func decodeCloudPayload(_ data: Data) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }

    private func pedigreeBatchSheepByID(
        for commands: [FarmCommand],
        farmID: UUID,
        context: ModelContext
    ) throws -> [UUID: SheepRecord]? {
        guard !commands.isEmpty else { return nil }
        let isPedigreeOnlyBatch = commands.allSatisfy { command in
            switch command {
            case .care(.updateSheepPedigree), .care(.setBreedingRam):
                true
            default:
                false
            }
        }
        guard isPedigreeOnlyBatch else { return nil }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        return Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
    }

    private func removalBatchExecutionState(
        for commands: [FarmCommand],
        farmID: UUID,
        context: ModelContext
    ) throws -> RemovalBatchExecutionState? {
        guard !commands.isEmpty,
              commands.allSatisfy({ command in
                  if case .removeSheep = command { return true }
                  return false
              }) else {
            return nil
        }

        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let batchIDs = Set(commands.compactMap { command -> UUID? in
            guard case .removeSheep(_, _, _, _, _, _, _, let batchID, _) = command else {
                return nil
            }
            return batchID
        })
        var existingRecordsByBatchID: [UUID: [RemovalRecord]] = [:]
        for batchID in batchIDs {
            existingRecordsByBatchID[batchID] = try context.fetch(
                FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                    $0.farmID == farmID &&
                        $0.removalBatchID == batchID &&
                        $0.deletedAt == nil
                })
            )
        }
        return RemovalBatchExecutionState(
            sheepByID: Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) }),
            existingRecordsByBatchID: existingRecordsByBatchID
        )
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
        case .addSheep(_, _, _, _, let occurredAt, _, _, _):
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

    private func releaseLegacyHistoryProjectionAuthority(
        affectedBy entityType: CloudEntityType,
        entityID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws {
        let sheepID: UUID?
        switch entityType {
        case .transfer:
            sheepID = try transferRecord(id: entityID, farmID: farmID, context: context)?.sheepID
        case .removal:
            sheepID = try removalRecord(id: entityID, farmID: farmID, context: context)?.sheepID
        default:
            sheepID = nil
        }
        guard let sheepID,
              let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                  $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
              })).first else {
            return
        }
        sheep.legacyStatusSnapshotIsAuthoritative = false
        sheep.legacyPenSnapshotIsAuthoritative = false
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
        let operationID = UUID()
        _ = try FarmStorageRouter.takeNextOperationSequence(
            farmID: farm.farmID,
            operationID: operationID,
            context: context
        )
        let operation = DomainOperation(
            id: operationID,
            farmID: farm.farmID,
            accountID: farm.accountID,
            kind: .resolveConflict,
            summary: "解决同步冲突",
            entityType: conflict.entityType,
            entityID: conflict.entityID,
            baseRevision: max(conflict.localRevision, conflict.remoteRevision),
            resultingRevision: revision,
            payload: payload
        )
        context.insert(operation)
        let route = try FarmStorageRouter.route(farmID: farm.farmID, context: context)
        if let deliveryProvider = route.deliveryProvider {
            context.insert(OutboxItem(
                farmID: farm.farmID,
                accountID: farm.accountID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID,
                baseRevision: operation.baseRevision,
                payloadDigest: operation.payloadDigest,
                deliveryProvider: deliveryProvider,
                authorityGeneration: route.deliveryAuthorityGeneration
            ))
        }
        conflict.statusRawValue = status.rawValue
        conflict.resolutionNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        conflict.resolutionOperationID = operation.id
        conflict.resolvedByAccountID = farm.accountID
        conflict.resolvedAt = .now
        conflict.resolutionFailureReason = nil
        try context.save()
        if route.requiresOutbox {
            CloudRuntimeNotification.postSyncWake(farmID: farm.farmID)
        }
        return operation.id
    }

    private func validate(
        _ command: FarmCommand,
        farmID: UUID,
        context: ModelContext,
        removalBatchState: RemovalBatchExecutionState? = nil
    ) throws {
        switch command {
        case .care:
            break
        case .tmr:
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
        case .addSheep(let earTag, let breed, let sex, let penID, _, _, let currentParity, _):
            let normalizedTag = try required(earTag, label: "耳号")
            _ = try required(breed, label: "品种")
            if let currentParity {
                guard currentParity >= 0, sex == .ewe else { throw FarmCommandError.invalidNumber("当前胎次") }
            }
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            guard !sheep.contains(where: { $0.farmID == farmID && EarTag.normalized($0.earTag) == EarTag.normalized(normalizedTag) }) else {
                throw FarmCommandError.duplicateEarTag
            }
            if let penID { try assertPen(penID, farmID: farmID, context: context) }
        case .updateSheepProfile(let sheepID, let earTag, let breed, let sex, _, let currentParity, let parityRecordedAt, _):
            let current = try sheepRecord(sheepID, farmID: farmID, context: context)
            let normalizedTag = try required(earTag, label: "耳号")
            _ = try required(breed, label: "品种")
            if let currentParity {
                guard currentParity >= 0, sex == .ewe else { throw FarmCommandError.invalidNumber("当前胎次") }
                guard parityRecordedAt != nil else { throw FarmCommandError.missingRequiredValue("胎次确认时间") }
            }
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
        case .recordWeaning(let sheepID, let weanWeightText, _, _, let birthWeightText, _, let damID, let litterSize, _):
            try assertSheep(sheepID, farmID: farmID, context: context)
            try positiveDecimal(weanWeightText, label: "断奶重")
            if let birthWeightText, !birthWeightText.isEmpty { try positiveDecimal(birthWeightText, label: "出生重") }
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
        case .transferSheep(let sheepID, let toPenID, let occurredAt, _):
            let sheep = try sheepRecord(sheepID, farmID: farmID, context: context)
            if let toPenID { try assertPen(toPenID, farmID: farmID, context: context) }
            let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
            }))
            guard FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers) != toPenID else {
                throw FarmCommandError.transferDestinationUnchanged
            }
        case .correctTransfer(let originalID, let toPenID, _, _, let reason):
            guard try context.fetch(FetchDescriptor<TransferRecord>()).contains(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.sourceRecordNotFound
            }
            if let toPenID { try assertPen(toPenID, farmID: farmID, context: context) }
            _ = try required(reason, label: "修正原因")
        case .removeSheep(let sheepID, let kind, let reason, let amountText, let occurredAt, let note, _, let removalBatchID, let batchTotalAmountText):
            if let removalBatchState {
                _ = try removalBatchState.sheepRecord(id: sheepID)
            } else {
                try assertSheep(sheepID, farmID: farmID, context: context)
            }
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
                let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                let stableTotal = normalizedTotal.flatMap { $0.isEmpty ? nil : Decimal.stable($0)?.stableText }
                if let removalBatchState {
                    try removalBatchState.validate(
                        batchID: removalBatchID,
                        signature: RemovalBatchSignature(
                            kind: kind,
                            reason: normalizedReason,
                            occurredAt: occurredAt,
                            note: normalizedNote,
                            batchTotalAmountText: stableTotal
                        )
                    )
                } else {
                    let existingBatch = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                        $0.farmID == farmID && $0.removalBatchID == removalBatchID && $0.deletedAt == nil
                    }))
                    guard existingBatch.allSatisfy({
                        $0.kind == kind &&
                            $0.reason == normalizedReason &&
                            $0.occurredAt == occurredAt &&
                            $0.note == normalizedNote &&
                            $0.batchTotalAmountText == stableTotal
                    }) else {
                        throw FarmCommandError.invalidRemovalBatch("同一批次的类型、原因、日期、备注和总额必须一致。")
                    }
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
        case .restoreBatchMembership(let membershipID, let restoredAt, let reason):
            let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>())
            guard let membership = memberships.first(where: {
                $0.id == membershipID &&
                    $0.farmID == farmID &&
                    $0.deletedAt == nil &&
                    $0.leftAt != nil
            }), let leftAt = membership.leftAt else {
                throw FarmCommandError.batchMembershipNotRestorable
            }
            guard restoredAt >= leftAt else {
                throw FarmCommandError.missingRequiredValue("不早于移出时间的撤回时间")
            }
            _ = try required(reason, label: "撤回原因")
            let batches = try context.fetch(FetchDescriptor<ProductionBatchRecord>())
            guard batches.contains(where: {
                $0.id == membership.batchID && $0.farmID == farmID && $0.deletedAt == nil
            }) else {
                throw FarmCommandError.batchNotFound
            }
            let sheep = try sheepRecord(membership.sheepID, farmID: farmID, context: context)
            guard sheep.isCurrentlyPresent else { throw FarmCommandError.sheepNotFound }
            guard !memberships.contains(where: {
                $0.id != membership.id &&
                    $0.farmID == farmID &&
                    $0.sheepID == membership.sheepID &&
                    $0.deletedAt == nil &&
                    $0.leftAt == nil
            }) else {
                throw FarmCommandError.duplicateBatchMembership
            }
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
        case .recordFeed(let penID, let recipeID, _, let occurredAt, let lines, _):
            guard occurredAt <= Date.now else { throw FarmCommandError.futureFactDate("投喂时间") }
            try assertPen(penID, farmID: farmID, context: context, includeInactive: true)
            try assertPenHasSheep(penID, on: occurredAt, farmID: farmID, context: context)
            if let recipeID { try assertRecipe(recipeID, farmID: farmID, context: context) }
            guard !lines.isEmpty else { throw FarmCommandError.missingRequiredValue("投喂明细") }
            for line in lines {
                try assertIngredient(line.ingredientID, farmID: farmID, context: context)
                if let batchID = line.ingredientBatchID {
                    _ = try feedIngredientBatchRecord(batchID, ingredientID: line.ingredientID, farmID: farmID, context: context)
                }
                try positiveDecimal(line.kilogramsText, label: "投喂数量")
            }
        case .saveFeedIngredient(let draft):
            _ = try required(draft.name, label: "原料名称")
            _ = try required(draft.unit, label: "单位")
            if let dryMatterText = draft.dryMatterText, !dryMatterText.isEmpty {
                try positiveDecimal(dryMatterText, label: "干物质")
                guard Decimal.stable(dryMatterText)! <= 100 else { throw FarmCommandError.invalidNumber("干物质") }
            }
            if let id = draft.id,
               draft.kind != .legacy,
               try context.fetch(FetchDescriptor<FeedIngredientRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) == nil {
                throw FarmCommandError.ingredientNotFound
            }
        case .saveFeedBatch(let draft):
            try assertIngredient(draft.ingredientID, farmID: farmID, context: context)
            _ = try required(draft.batchName, label: "批次名称")
            try nonNegativeDecimal(draft.pricePerKilogramText, label: "批次单价")
            if let purchased = draft.purchasedKilogramsText, !purchased.isEmpty { try nonNegativeDecimal(purchased, label: "购入量") }
            if let initial = draft.initialKilogramsText, !initial.isEmpty { try nonNegativeDecimal(initial, label: "期初库存") }
            if let remaining = draft.remainingKilogramsText, !remaining.isEmpty { try nonNegativeDecimal(remaining, label: "当前库存") }
            if let packageCount = draft.packageCountText, !packageCount.isEmpty { try positiveDecimal(packageCount, label: "包装数量") }
            if let nominal = draft.nominalPackageKilogramsText, !nominal.isEmpty { try positiveDecimal(nominal, label: "包装规格重量") }
            if let id = draft.id, try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) == nil {
                throw FarmCommandError.feedIngredientBatchNotFound
            }
        case .adjustFeedStock(let batchID, let kind, let quantityText, _, _):
            let batch = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first(where: { $0.id == batchID && $0.farmID == farmID && $0.isActive && $0.deletedAt == nil })
            guard let batch else { throw FarmCommandError.feedIngredientBatchNotFound }
            guard let quantity = Decimal.stable(quantityText) else { throw FarmCommandError.invalidNumber("库存数量") }
            switch kind {
            case .receipt:
                guard quantity > 0 else { throw FarmCommandError.invalidNumber("入库数量") }
            case .adjustment:
                guard quantity != 0 else { throw FarmCommandError.invalidNumber("调整数量") }
            case .openingBalance, .consumption, .reversal, .conflict:
                throw FarmCommandError.invalidNumber("库存流水类型")
            }
            if kind == .adjustment {
                guard let current = try FeedStockLedger.balance(for: batch, context: context) else {
                    throw FarmStockCommandError.batchRequired
                }
                if current + quantity < 0 { throw FarmCommandError.insufficientInventory }
            }
        case .countFeedStock(_, let batchID, let actualKilogramsText, let method, _, _):
            guard let batch = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first(where: { $0.id == batchID && $0.farmID == farmID && $0.isActive && $0.deletedAt == nil }) else { throw FarmCommandError.feedIngredientBatchNotFound }
            guard try FeedStockLedger.balance(for: batch, context: context) != nil else { throw FarmStockCommandError.batchRequired }
            if method == .notMeasured, actualKilogramsText != nil {
                throw FarmCommandError.invalidNumber("暂未称量不能填写公斤数")
            } else if let actualKilogramsText {
                guard let actual = Decimal.stable(actualKilogramsText), actual >= 0 else { throw FarmCommandError.invalidNumber("盘点实际剩余量") }
            } else if method != .notMeasured {
                throw FarmCommandError.missingRequiredValue("盘点实际剩余量")
            }
        case .saveFeedRecipe(let draft):
            _ = try required(draft.name, label: "配方名称")
            guard !draft.components.isEmpty else { throw FarmCommandError.missingRequiredValue("配方原料") }
            if let headCount = draft.headCount, headCount <= 0 { throw FarmCommandError.invalidNumber("设计羊数") }
            if let targetPenID = draft.targetPenID { try assertPen(targetPenID, farmID: farmID, context: context) }
            if let id = draft.id, try context.fetch(FetchDescriptor<FeedRecipeRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) == nil {
                throw FarmCommandError.sourceRecordNotFound
            }
            for component in draft.components {
                try assertIngredient(component.ingredientID, farmID: farmID, context: context)
                if let batchID = component.ingredientBatchID {
                    _ = try feedIngredientBatchRecord(batchID, ingredientID: component.ingredientID, farmID: farmID, context: context)
                }
                try positiveDecimal(component.kilogramsText, label: "配方用量")
            }
        case .recordFeedV2(let draft):
            guard draft.occurredAt <= Date.now else { throw FarmCommandError.futureFactDate("投喂时间") }
            try assertPen(draft.penID, farmID: farmID, context: context, includeInactive: true)
            try assertPenHasSheep(draft.penID, on: draft.occurredAt, farmID: farmID, context: context)
            if let recipeID = draft.recipeID { try assertRecipe(recipeID, farmID: farmID, context: context) }
            guard !draft.lines.isEmpty else { throw FarmCommandError.missingRequiredValue("投喂明细") }
            for line in draft.lines {
                try assertIngredient(line.ingredientID, farmID: farmID, context: context)
                try positiveDecimal(line.kilogramsText, label: "投喂数量")
            }
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }))
            let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }))
            let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }))
            let eligibleIDs = Set(FeedPenEligibility.sheepByPen(
                on: draft.occurredAt,
                sheep: sheep,
                transfers: transfers,
                removals: removals
            )[draft.penID, default: []].map(\.id))
            guard Set(draft.excludedSheepIDs).isSubset(of: eligibleIDs) else {
                throw FarmCommandError.sheepNotFound
            }
            if let actualHeadCount = draft.actualHeadCountSnapshot {
                guard actualHeadCount >= 0,
                      actualHeadCount == eligibleIDs.count - Set(draft.excludedSheepIDs).count else {
                    throw FarmCommandError.invalidNumber("实际参与投喂羊数")
                }
            }
            try FeedStockLedger.validateConsumption(lines: draft.lines, farmID: farmID, context: context)
            if let remaining = draft.remainingKilogramsText, !remaining.isEmpty { try nonNegativeDecimal(remaining, label: "剩料") }
            if let discarded = draft.discardedKilogramsText, !discarded.isEmpty { try nonNegativeDecimal(discarded, label: "清出报废") }
        case .recordFeedTroughObservation(let draft):
            guard draft.observedAt <= Date.now else { throw FarmCommandError.futureFactDate("盘槽时间") }
            try assertPen(draft.penID, farmID: farmID, context: context, includeInactive: true)
            try assertPenOccupied(draft.penID, at: draft.observedAt, farmID: farmID, context: context)
            try nonNegativeDecimal(draft.actualRemainingKilogramsText, label: "实际剩余量")
            let actual = Decimal.stable(draft.actualRemainingKilogramsText) ?? 0
            if let discardedText = draft.discardedKilogramsText, !discardedText.isEmpty {
                try nonNegativeDecimal(discardedText, label: "清出量")
                guard (Decimal.stable(discardedText) ?? 0) <= actual else {
                    throw FarmCommandError.invalidNumber("清出量不能大于盘槽时实际剩余量")
                }
            }
            if let feedID = draft.relatedFeedRecordID {
                guard let feed = try context.fetch(FetchDescriptor<FeedRecord>()).first(where: {
                    $0.id == feedID && $0.farmID == farmID && $0.penID == draft.penID &&
                        $0.occurredAt <= draft.observedAt && $0.deletedAt == nil
                }) else { throw FarmCommandError.sourceRecordNotFound }
                _ = feed
            }
            if let json = draft.compositionSnapshotJSON {
                guard let data = json.data(using: .utf8),
                      let components = try? JSONDecoder().decode([FeedTroughCompositionComponent].self, from: data),
                      !components.isEmpty else {
                    throw FarmCommandError.missingRequiredValue("有效剩料组成")
                }
                let quantities = components.compactMap { Decimal.stable($0.kilogramsText) }
                guard quantities.count == components.count,
                      quantities.allSatisfy({ $0 >= 0 }),
                      abs(NSDecimalNumber(decimal: quantities.reduce(0, +) - actual).doubleValue) <= 0.001 else {
                    throw FarmCommandError.invalidNumber("剩料组成合计")
                }
            }
        case .importHistoricalFeed(let draft):
            try assertPen(draft.penID, farmID: farmID, context: context)
            _ = try required(draft.legacySourceKey, label: "历史投喂来源")
            guard !draft.lines.isEmpty else { throw FarmCommandError.missingRequiredValue("投喂明细") }
            for line in draft.lines {
                try assertIngredient(line.ingredientID, farmID: farmID, context: context)
                try positiveDecimal(line.kilogramsText, label: "投喂数量")
            }
            if let remaining = draft.remainingKilogramsText, !remaining.isEmpty { try nonNegativeDecimal(remaining, label: "剩料") }
            if let discarded = draft.discardedKilogramsText, !discarded.isEmpty { try nonNegativeDecimal(discarded, label: "清出报废") }
        case .recordHealth(let sheepID, let penID, _, let itemName, let occurredAt, _, let inventoryLotID, let quantityText):
            guard sheepID != nil || penID != nil else { throw FarmCommandError.missingRequiredValue("羊只或圈舍") }
            if let sheepID { try assertSheep(sheepID, farmID: farmID, context: context) }
            if let penID {
                try assertPen(penID, farmID: farmID, context: context, includeInactive: true)
                try assertPenOccupied(penID, at: occurredAt, farmID: farmID, context: context)
            }
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
        case .recordReproduction(let eweID, let kind, let occurredAt, let sireID, let semenName, _, let lambCount, let parity, let birthDeadCount, let offspring, _):
            let ewe = try sheepRecord(eweID, farmID: farmID, context: context)
            guard ewe.sex == .ewe else { throw FarmCommandError.reproductionSubjectMustBeEwe }
            guard kind != .parityBaseline else { throw FarmCommandError.invalidReproductionRecord }
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
                guard occurredAt <= Date.now else { throw FarmCommandError.futureFactDate("产羔时间") }
                guard lambCount >= 1,
                      parity.map({ $0 >= 1 }) == true,
                      birthDeadCount.map({ $0 >= 0 && $0 <= lambCount }) == true,
                      offspring.count == lambCount else {
                    throw FarmCommandError.invalidReproductionRecord
                }
                let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>())
                let currentParity = LambingEntrySemantics.currentParity(eweID: eweID, farmID: farmID, before: occurredAt, records: reproduction)
                guard parity == currentParity + 1 else {
                    throw FarmCommandError.lambingParityMismatch(current: currentParity, attempted: parity ?? 0)
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
        case .addNote(let sheepID, let penID, let text, let occurredAt):
            guard sheepID != nil || penID != nil else { throw FarmCommandError.missingRequiredValue("羊只或圈舍") }
            if let sheepID { try assertSheep(sheepID, farmID: farmID, context: context) }
            if let penID {
                try assertPen(penID, farmID: farmID, context: context, includeInactive: true)
                try assertPenOccupied(penID, at: occurredAt, farmID: farmID, context: context)
            }
            _ = try required(text, label: "备注内容")
        case .tombstoneEntity(let entityType, let entityID, let reason):
            _ = try required(reason, label: "删除原因")
            guard try entityExists(type: entityType, id: entityID, farmID: farmID, context: context) else {
                throw FarmCommandError.missingRequiredValue("可删除的权威记录")
            }
            if entityType == .reproduction,
               let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: {
                   $0.id == entityID && $0.farmID == farmID && $0.deletedAt == nil
               }),
               reproduction.kind == .parityBaseline {
                throw FarmCommandError.parityBaselineManagedInProfile
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

    private func apply(
        _ command: FarmCommand,
        farm: FarmContext,
        context: ModelContext,
        pedigreeSheepByID: [UUID: SheepRecord]? = nil,
        sheepAvatarUpdate: SheepAvatarPhotoUpdate? = nil,
        removalBatchState: RemovalBatchExecutionState? = nil
    ) throws -> AppliedCommandResult {
        let defaultPayload = try FarmCommandCloudPayloadEncoder.encode(
            command,
            sheepAvatarUpdate: sheepAvatarUpdate
        )
        func appliedResult(_ type: CloudEntityType, _ id: UUID, baseRevision: Int = 0, revision: Int = 1, payload: Data? = nil) -> AppliedCommandResult {
            AppliedCommandResult(entityType: type.rawValue, entityID: id, baseRevision: baseRevision, resultingRevision: revision, payload: payload ?? defaultPayload)
        }

        switch command {
        case .care(let careCommand):
            let result = try FarmCareCommandHandler.validateAndApply(
                careCommand,
                farmID: farm.farmID,
                accountID: farm.accountID,
                context: context,
                pedigreeSheepByID: pedigreeSheepByID
            )
            return AppliedCommandResult(entityType: result.entityType.rawValue, entityID: result.entityID, baseRevision: result.baseRevision, resultingRevision: result.resultingRevision, payload: defaultPayload)
        case .tmr(let tmrCommand):
            let result = try TMRCommandHandler.validateAndApply(
                tmrCommand,
                farmID: farm.farmID,
                accountID: farm.accountID,
                context: context
            )
            let payload = try FarmCommandCloudPayloadEncoder.encode(.tmr(result.payloadCommand))
            return AppliedCommandResult(
                entityType: result.entityType.rawValue,
                entityID: result.entityID,
                baseRevision: result.baseRevision,
                resultingRevision: result.resultingRevision,
                payload: payload
            )
        case .updateFarmLocation(let displayName, let latitude, let longitude, let addressSnapshot, let timeZoneIdentifier, let source, let accuracy):
            let farms = try context.fetch(FetchDescriptor<FarmRecord>())
            guard let record = farms.first(where: { $0.id == farm.farmID && $0.deletedAt == nil }) else {
                throw FarmCommandError.missingRequiredValue("当前牧场")
            }
            let baseRevision = try latestRevision(
                entityType: .farm,
                entityID: record.id,
                farmID: farm.farmID,
                context: context
            )
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
        case .addSheep(let earTag, let breed, let sex, let penID, let occurredAt, let birthAt, let currentParity, let note):
            let record = SheepRecord(farmID: farm.farmID, earTag: earTag.trimmingCharacters(in: .whitespacesAndNewlines), breed: breed.trimmingCharacters(in: .whitespacesAndNewlines), sex: sex, penID: penID, enteredAt: occurredAt, birthAt: birthAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(record)
            if sex == .ewe, let currentParity {
                context.insert(ReproductionRecord(
                    id: LambingEntrySemantics.entryParityBaselineID(sheepID: record.id),
                    farmID: farm.farmID,
                    eweID: record.id,
                    kind: .parityBaseline,
                    occurredAt: occurredAt,
                    parity: currentParity,
                    note: "建档时当前胎次"
                ))
            }
            return appliedResult(.sheep, record.id)
        case .updateSheepProfile(let sheepID, let earTag, let breed, let sex, let birthAt, let currentParity, let parityRecordedAt, let note):
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
            if let currentParity, let parityRecordedAt {
                context.insert(ReproductionRecord(
                    id: LambingEntrySemantics.parityCorrectionID(sheepID: record.id, sheepRevision: record.revision),
                    farmID: farm.farmID,
                    eweID: record.id,
                    kind: .parityBaseline,
                    occurredAt: parityRecordedAt,
                    parity: currentParity,
                    note: "档案确认当前胎次"
                ))
            }
            if let sheepAvatarUpdate {
                try SheepAvatarSelectionStore.apply(
                    sheepAvatarUpdate,
                    sheepID: record.id,
                    farmID: farm.farmID,
                    updatedAt: record.updatedAt,
                    context: context
                )
            }
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
        case .recordWeaning(let sheepID, let weanWeightText, let occurredAt, let birthAt, let birthWeightText, _, let damID, let litterSize, let note):
            let child = try sheepRecord(sheepID, farmID: farm.farmID, context: context)
            let effectiveBirthAt = birthAt ?? child.birthAt
            let normalizedWeanWeightText = normalizedDecimal(weanWeightText)
            let normalizedBirthWeightText = birthWeightText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }
            let farmID = farm.farmID
            let weightRecords = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
            }))
            let weaningWeight = NSDecimalNumber(decimal: Decimal.stable(normalizedWeanWeightText) ?? 0).doubleValue
            let gain = WeaningGainSemantics.calculate(
                sheepID: sheepID,
                birthAt: effectiveBirthAt,
                weaningAt: occurredAt,
                weaningWeight: weaningWeight,
                samples: WeaningGainSemantics.samples(from: weightRecords, farmID: farmID)
            )
            let record = WeaningRecord(
                farmID: farmID,
                sheepID: sheepID,
                occurredAt: occurredAt,
                weanWeightText: normalizedWeanWeightText,
                birthAt: effectiveBirthAt,
                birthWeightText: normalizedBirthWeightText,
                averageDailyGainText: gain?.kilogramsPerDayText,
                damID: damID,
                litterSize: litterSize,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            context.insert(record)
            let payload = try FarmCommandCloudPayloadEncoder.encode(.recordWeaning(
                sheepID: sheepID,
                weanWeightText: normalizedWeanWeightText,
                occurredAt: occurredAt,
                birthAt: effectiveBirthAt,
                birthWeightText: normalizedBirthWeightText,
                averageDailyGainText: gain?.kilogramsPerDayText,
                damID: damID,
                litterSize: litterSize,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            return appliedResult(.weaning, record.id, payload: payload)
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
            let sheep: SheepRecord
            if let removalBatchState {
                sheep = try removalBatchState.sheepRecord(id: sheepID)
            } else {
                sheep = try sheepRecord(sheepID, farmID: farm.farmID, context: context)
            }
            sheep.legacyStatusSnapshotIsAuthoritative = false
            sheep.legacyPenSnapshotIsAuthoritative = false
            let entityID = recordID ?? UUID()
            let existing = try context.fetch(FetchDescriptor<RemovalRecord>()).filter {
                $0.id == entityID && $0.farmID == farm.farmID
            }
            guard !existing.contains(where: { $0.deletedAt == nil }) else {
                throw FarmCommandError.duplicateRemovalRecord
            }
            let operationRevision = try context.fetch(FetchDescriptor<DomainOperation>()).lazy
                .filter { $0.farmID == farm.farmID && $0.entityID == entityID }
                .map(\.resultingRevision)
                .max() ?? 0
            let tombstoneRevision = try context.fetch(FetchDescriptor<TombstoneRecord>()).lazy
                .filter { $0.farmID == farm.farmID && $0.entityID == entityID }
                .map(\.revision)
                .max() ?? 0
            let projectionRevision = existing.map(\.revision).max() ?? 0
            let baseRevision = max(
                operationRevision,
                max(tombstoneRevision, projectionRevision)
            )
            let record: RemovalRecord
            if let reusable = existing.max(by: { $0.revision < $1.revision }) {
                reusable.sheepID = sheepID
                reusable.kindRawValue = kind.rawValue
                reusable.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                reusable.amountText = amountText.flatMap {
                    $0.isEmpty ? nil : normalizedDecimal($0)
                }
                reusable.removalBatchID = removalBatchID
                reusable.batchTotalAmountText = batchTotalAmountText.flatMap {
                    $0.isEmpty ? nil : normalizedDecimal($0)
                }
                reusable.occurredAt = occurredAt
                reusable.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                reusable.recordedAt = .now
                reusable.deletedAt = nil
                reusable.revision = baseRevision + 1
                record = reusable
            } else {
                let inserted = RemovalRecord(
                    id: entityID,
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
                inserted.revision = max(1, baseRevision + 1)
                context.insert(inserted)
                record = inserted
            }
            return appliedResult(
                .removal,
                record.id,
                baseRevision: baseRevision,
                revision: record.revision
            )
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
            let baseRevision = try latestRevision(
                entityType: .batchMembership,
                entityID: membership.id,
                farmID: farm.farmID,
                context: context
            )
            membership.leftAt = leftAt
            membership.leaveReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            membership.updatedAt = .now
            try ProductionBatchLifecycle.reconcile(batchID: batchID, farmID: farm.farmID, context: context)
            return appliedResult(.batchMembership, membership.id, baseRevision: baseRevision, revision: baseRevision + 1)
        case .restoreBatchMembership(let membershipID, let restoredAt, _):
            let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>())
            guard let membership = memberships.first(where: {
                $0.id == membershipID &&
                    $0.farmID == farm.farmID &&
                    $0.deletedAt == nil &&
                    $0.leftAt != nil
            }) else {
                throw FarmCommandError.batchMembershipNotRestorable
            }
            let baseRevision = try latestRevision(
                entityType: .batchMembership,
                entityID: membership.id,
                farmID: farm.farmID,
                context: context
            )
            membership.leftAt = nil
            membership.leaveReason = nil
            membership.updatedAt = .now
            try ProductionBatchLifecycle.reconcile(
                batchID: membership.batchID,
                farmID: farm.farmID,
                context: context,
                changedAt: restoredAt
            )
            return appliedResult(.batchMembership, membership.id, baseRevision: baseRevision, revision: baseRevision + 1)
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
        case .saveFeedIngredient(let draft):
            let record: FeedIngredientRecord
            let baseRevision: Int
            if let id = draft.id,
               let existing = try context.fetch(FetchDescriptor<FeedIngredientRecord>()).first(where: { $0.id == id && $0.farmID == farm.farmID && $0.deletedAt == nil }) {
                record = existing
                baseRevision = try latestRevision(entityType: .feedIngredient, entityID: id, farmID: farm.farmID, context: context)
            } else {
                record = FeedIngredientRecord(id: draft.id ?? UUID(), farmID: farm.farmID, name: draft.name, unit: draft.unit, dryMatterText: draft.dryMatterText, category: draft.category, nutrientSnapshotJSON: draft.nutrientSnapshotJSON, kind: draft.kind, sourceTemplateID: draft.sourceTemplateID, sourceTemplateCode: draft.sourceTemplateCode, mixtureComponentsJSON: draft.mixtureComponentsJSON, note: draft.note)
                context.insert(record)
                baseRevision = 0
            }
            record.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.unit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            record.category = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
            record.dryMatterText = draft.dryMatterText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }
            record.nutrientSnapshotJSON = draft.nutrientSnapshotJSON.isEmpty ? "{}" : draft.nutrientSnapshotJSON
            record.kindRawValue = draft.kind.rawValue
            record.sourceTemplateID = draft.sourceTemplateID
            record.sourceTemplateCode = draft.sourceTemplateCode
            record.mixtureComponentsJSON = draft.mixtureComponentsJSON
            record.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            record.updatedAt = .now
            return appliedResult(.feedIngredient, record.id, baseRevision: baseRevision, revision: baseRevision + 1)
        case .saveFeedBatch(let draft):
            let record: FeedIngredientBatchRecord
            let baseRevision: Int
            if let id = draft.id,
               let existing = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first(where: { $0.id == id && $0.farmID == farm.farmID && $0.deletedAt == nil }) {
                record = existing
                baseRevision = try latestRevision(entityType: .feedIngredientBatch, entityID: id, farmID: farm.farmID, context: context)
            } else {
                record = FeedIngredientBatchRecord(id: draft.id ?? UUID(), farmID: farm.farmID, ingredientID: draft.ingredientID, batchName: draft.batchName, purchaseDate: draft.purchaseDate, supplier: draft.supplier, storageLocation: draft.storageLocation, pricePerKilogramText: normalizedDecimal(draft.pricePerKilogramText), purchasedKilogramsText: draft.purchasedKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }, packagingKind: draft.packagingKind, packageCountText: draft.packageCountText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }, nominalPackageKilogramsText: draft.nominalPackageKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }, stockWeightConfirmed: draft.stockWeightConfirmed, initialKilogramsText: draft.initialKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }, remainingKilogramsText: draft.remainingKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }, note: draft.note, isActive: draft.isActive)
                context.insert(record)
                baseRevision = 0
            }
            record.ingredientID = draft.ingredientID
            record.batchName = draft.batchName.trimmingCharacters(in: .whitespacesAndNewlines)
            record.purchaseDate = draft.purchaseDate
            record.supplier = draft.supplier.trimmingCharacters(in: .whitespacesAndNewlines)
            record.storageLocation = draft.storageLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            record.pricePerKilogramText = normalizedDecimal(draft.pricePerKilogramText)
            record.purchasedKilogramsText = draft.purchasedKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }
            record.packagingKindRawValue = draft.packagingKind.rawValue
            record.packageCountText = draft.packageCountText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }
            record.nominalPackageKilogramsText = draft.nominalPackageKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }
            record.stockWeightConfirmed = draft.stockWeightConfirmed
            record.initialKilogramsText = draft.initialKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }
            record.remainingKilogramsText = draft.remainingKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) }
            record.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            record.isActive = draft.isActive
            record.updatedAt = .now
            record.revision = max(record.revision + 1, baseRevision + 1)
            return appliedResult(.feedIngredientBatch, record.id, baseRevision: baseRevision, revision: record.revision)
        case .adjustFeedStock(let batchID, let kind, let quantityText, let occurredAt, let note):
            let transaction = FeedStockTransactionRecord(farmID: farm.farmID, ingredientBatchID: batchID, kind: kind, quantityText: normalizedDecimal(quantityText), occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(transaction)
            return appliedResult(.feedStockTransaction, transaction.id)
        case .countFeedStock(let countID, let batchID, let actualKilogramsText, let method, let occurredAt, let note):
            guard let batch = try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>()).first(where: { $0.id == batchID && $0.farmID == farm.farmID && $0.isActive && $0.deletedAt == nil }), let bookBalance = try FeedStockLedger.balance(for: batch, context: context) else {
                throw FarmCommandError.feedIngredientBatchNotFound
            }
            let actual = actualKilogramsText.flatMap(Decimal.stable)
            let difference = actual.map { $0 - bookBalance }
            let adjustmentID = difference.map { _ in StableCloudUUID.derived(namespace: countID, name: "feed-stock-count-adjustment") }
            let count = FeedStockCountRecord(id: countID, farmID: farm.farmID, ingredientBatchID: batchID, bookBalanceText: bookBalance.stableText, actualKilogramsText: actual?.stableText, differenceText: difference?.stableText, method: method, occurredAt: occurredAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines), adjustmentTransactionID: adjustmentID)
            context.insert(count)
            if let difference, let adjustmentID {
                context.insert(FeedStockTransactionRecord(id: adjustmentID, farmID: farm.farmID, ingredientBatchID: batchID, kind: .adjustment, quantityText: difference.stableText, occurredAt: occurredAt, sourceRecordID: count.id, note: "盘库校正（\(method.displayName)）"))
            }
            return appliedResult(.feedStockCount, count.id)
        case .saveFeedRecipe(let draft):
            let recipe: FeedRecipeRecord
            let baseRevision: Int
            if let id = draft.id,
               let existing = try context.fetch(FetchDescriptor<FeedRecipeRecord>()).first(where: { $0.id == id && $0.farmID == farm.farmID && $0.deletedAt == nil }) {
                recipe = existing
                baseRevision = try latestRevision(entityType: .feedRecipe, entityID: id, farmID: farm.farmID, context: context)
            } else {
                recipe = FeedRecipeRecord(id: draft.id ?? UUID(), farmID: farm.farmID, name: draft.name, note: draft.note, targetPenName: draft.targetPenName, targetPenID: draft.targetPenID, stageRawValue: draft.stage.rawValue, headCount: draft.headCount)
                context.insert(recipe)
                baseRevision = 0
            }
            recipe.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            recipe.targetPenID = draft.targetPenID
            recipe.targetPenName = draft.targetPenName
            recipe.stageRawValue = draft.stage.rawValue
            recipe.headCount = draft.headCount
            recipe.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            recipe.updatedAt = .now
            let oldComponents = try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter { $0.farmID == farm.farmID && $0.recipeID == recipe.id && $0.deletedAt == nil }
            let incomingIDs = Set(draft.components.map(\.id))
            for old in oldComponents where !incomingIDs.contains(old.id) { old.deletedAt = .now }
            for component in draft.components {
                let value: FeedRecipeComponentRecord
                if let existing = oldComponents.first(where: { $0.id == component.id }) {
                    value = existing
                } else {
                    value = FeedRecipeComponentRecord(id: component.id, farmID: farm.farmID, recipeID: recipe.id, ingredientID: component.ingredientID, kilogramsText: normalizedDecimal(component.kilogramsText), ingredientBatchID: component.ingredientBatchID, pricePerKilogramText: component.pricePerKilogramText.flatMap { normalizedDecimal($0) }, nutrientSnapshotJSON: component.nutrientSnapshotJSON)
                    context.insert(value)
                }
                value.ingredientID = component.ingredientID
                value.ingredientBatchID = component.ingredientBatchID
                value.kilogramsText = normalizedDecimal(component.kilogramsText)
                value.pricePerKilogramText = component.pricePerKilogramText.flatMap { normalizedDecimal($0) }
                value.nutrientSnapshotJSON = component.nutrientSnapshotJSON
                value.updatedAt = .now
                value.deletedAt = nil
            }
            let payload = try FarmCommandCloudPayloadEncoder.encode(command)
            return appliedResult(.feedRecipe, recipe.id, baseRevision: baseRevision, revision: baseRevision + 1, payload: payload)
        case .recordFeedV2(let draft):
            let feed = FeedRecord(id: draft.id, farmID: farm.farmID, penID: draft.penID, recipeID: draft.recipeID, mode: draft.mode, occurredAt: draft.occurredAt, note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines), mealName: draft.mealName.trimmingCharacters(in: .whitespacesAndNewlines), feederName: draft.feederName.trimmingCharacters(in: .whitespacesAndNewlines), remainingKilogramsText: draft.remainingKilogramsText.flatMap { normalizedDecimal($0) }, discardedKilogramsText: draft.discardedKilogramsText.flatMap { normalizedDecimal($0) }, recipeHeadCountSnapshot: draft.recipeHeadCountSnapshot, actualHeadCountSnapshot: draft.actualHeadCountSnapshot, scaleFactorText: draft.scaleFactorText.flatMap { normalizedDecimal($0) }, remainingCompositionJSON: draft.remainingCompositionJSON, excludedSheepIDs: draft.excludedSheepIDs)
            context.insert(feed)
            let recipeComponents = try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>())
            var resolvedCloudLines: [FarmCommandCloudPayload.FeedLine] = []
            for line in draft.lines {
                let ingredient = try ingredientRecord(line.ingredientID, farmID: farm.farmID, context: context)
                let ingredientBatch = try line.ingredientBatchID.map { try feedIngredientBatchRecord($0, ingredientID: ingredient.id, farmID: farm.farmID, context: context) }
                let recipeComponent = draft.recipeID.flatMap { recipeID in recipeComponents.first { $0.farmID == farm.farmID && $0.recipeID == recipeID && $0.ingredientID == ingredient.id && $0.deletedAt == nil } }
                let nutrientSnapshot = (recipeComponent?.nutrientSnapshotJSON.isEmpty == false ? recipeComponent?.nutrientSnapshotJSON : nil) ?? ingredient.nutrientSnapshotJSON
                let priceSnapshot = ingredientBatch?.pricePerKilogramText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? ingredientBatch?.pricePerKilogramText : recipeComponent?.pricePerKilogramText
                let quantityText = normalizedDecimal(line.kilogramsText)
                let record = FeedRecordLine(id: line.id, farmID: farm.farmID, feedRecordID: feed.id, ingredientID: ingredient.id, kilogramsText: quantityText, stockQuantityText: quantityText, ingredientNameSnapshot: ingredient.name, ingredientBatchID: ingredientBatch?.id, ingredientBatchNameSnapshot: ingredientBatch?.batchName, pricePerKilogramTextSnapshot: priceSnapshot, nutrientSnapshotJSON: nutrientSnapshot, unitSnapshot: ingredient.unit, dryMatterTextSnapshot: ingredient.dryMatterText ?? ingredient.nutrients.dryMatter.map { String($0) })
                context.insert(record)
                FeedStockLedger.insertConsumption(feedID: feed.id, lineID: record.id, batchID: ingredientBatch!.id, quantityText: quantityText, occurredAt: draft.occurredAt, farmID: farm.farmID, context: context)
                resolvedCloudLines.append(.init(id: record.id, ingredientID: record.ingredientID, kilogramsText: record.kilogramsText, ingredientBatchID: record.ingredientBatchID, ingredientNameSnapshot: record.ingredientNameSnapshot, ingredientBatchNameSnapshot: record.ingredientBatchNameSnapshot, pricePerKilogramTextSnapshot: record.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: record.nutrientSnapshotJSON, unitSnapshot: record.unitSnapshot, dryMatterTextSnapshot: record.dryMatterTextSnapshot))
            }
            let payload = try FarmCommandCloudPayloadEncoder.encode(command, resolvedFeedLines: resolvedCloudLines)
            return appliedResult(.feed, feed.id, payload: payload)
        case .recordFeedTroughObservation(let draft):
            let observation = FeedTroughObservationRecord(
                id: draft.id,
                farmID: farm.farmID,
                penID: draft.penID,
                relatedFeedRecordID: draft.relatedFeedRecordID,
                feederName: draft.feederName.trimmingCharacters(in: .whitespacesAndNewlines),
                observedAt: draft.observedAt,
                actualRemainingKilogramsText: normalizedDecimal(draft.actualRemainingKilogramsText),
                discardedKilogramsText: draft.discardedKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) },
                measurementMethod: draft.measurementMethod,
                compositionSnapshotJSON: draft.compositionSnapshotJSON,
                note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            context.insert(observation)
            return appliedResult(.feedTroughObservation, observation.id)
        case .importHistoricalFeed(let draft):
            if let existing = try context.fetch(FetchDescriptor<FeedRecord>()).first(where: {
                $0.id == draft.id && $0.farmID == farm.farmID && $0.deletedAt == nil
            }) {
                return appliedResult(.feed, existing.id, baseRevision: existing.revision, revision: existing.revision)
            }
            let feed = FeedRecord(
                id: draft.id,
                farmID: farm.farmID,
                penID: draft.penID,
                mode: draft.mode,
                occurredAt: draft.occurredAt,
                note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                mealName: draft.mealName,
                feederName: draft.feederName,
                remainingKilogramsText: draft.remainingKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) },
                discardedKilogramsText: draft.discardedKilogramsText.flatMap { $0.isEmpty ? nil : normalizedDecimal($0) },
                remainingCompositionJSON: draft.remainingCompositionJSON,
                legacySourceKey: draft.legacySourceKey
            )
            context.insert(feed)
            for line in draft.lines {
                context.insert(FeedRecordLine(
                    id: line.id,
                    farmID: farm.farmID,
                    feedRecordID: feed.id,
                    ingredientID: line.ingredientID,
                    kilogramsText: normalizedDecimal(line.kilogramsText),
                    ingredientNameSnapshot: line.ingredientNameSnapshot,
                    ingredientBatchNameSnapshot: line.ingredientBatchNameSnapshot,
                    pricePerKilogramTextSnapshot: line.pricePerKilogramTextSnapshot,
                    nutrientSnapshotJSON: line.nutrientSnapshotJSON,
                    unitSnapshot: line.unitSnapshot,
                    dryMatterTextSnapshot: line.dryMatterTextSnapshot
                ))
            }
            let payload = try FarmCommandCloudPayloadEncoder.encode(command)
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
            let baseRevision = try latestRevision(
                entityType: entityType,
                entityID: entityID,
                farmID: farm.farmID,
                context: context
            )
            try releaseLegacyHistoryProjectionAuthority(
                affectedBy: entityType,
                entityID: entityID,
                farmID: farm.farmID,
                context: context
            )
            try DomainEntityDeletionService.setDeletedAt(
                .now,
                type: entityType,
                id: entityID,
                farmID: farm.farmID,
                revision: baseRevision + 1,
                context: context
            )
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
            try DomainEntityDeletionService.setDeletedAt(
                nil,
                type: entityType,
                id: tombstone.entityID,
                farmID: farm.farmID,
                revision: tombstone.revision + 1,
                context: context
            )
            tombstone.restoredAt = .now
            return appliedResult(entityType, tombstone.entityID, baseRevision: tombstone.revision, revision: tombstone.revision + 1)
        }
    }

    private func latestRevision(
        entityType: CloudEntityType,
        entityID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        let operationRevision = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID && $0.entityID == entityID
        }))
            .map(\.resultingRevision)
            .max() ?? 1
        let tombstoneRevision = try context.fetch(FetchDescriptor<TombstoneRecord>()).lazy
            .filter { $0.farmID == farmID && $0.entityID == entityID }
            .map(\.revision)
            .max() ?? 1
        let projectionRevision = try projectionRevision(
            entityType: entityType,
            entityID: entityID,
            farmID: farmID,
            context: context
        ) ?? 1
        return max(operationRevision, max(tombstoneRevision, projectionRevision))
    }

    private func projectionRevision(
        entityType: CloudEntityType,
        entityID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> Int? {
        return switch entityType {
        case .pen:
            try context.fetch(FetchDescriptor<PenRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .sheep:
            try context.fetch(FetchDescriptor<SheepRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .weight:
            try context.fetch(FetchDescriptor<WeightRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .weaning:
            try context.fetch(FetchDescriptor<WeaningRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .breedingProgram:
            try context.fetch(FetchDescriptor<BreedingProgramRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .breedingProgramStep:
            try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .transfer:
            try context.fetch(FetchDescriptor<TransferRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .removal:
            try context.fetch(FetchDescriptor<RemovalRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .feed:
            try context.fetch(FetchDescriptor<FeedRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .feedTroughObservation:
            try context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrFormula:
            try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.formulaRevision
        case .tmrFeedingPlan:
            try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrFeedingPlanPen:
            try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrBatch:
            try context.fetch(FetchDescriptor<TMRBatchRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrFeedingRun:
            try context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrMealCompletion:
            try context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrDeviationAcknowledgement:
            try context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrMonitoringRule:
            try context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .reproduction:
            try context.fetch(FetchDescriptor<ReproductionRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .semen:
            try context.fetch(FetchDescriptor<SemenRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .semenDonor:
            try context.fetch(FetchDescriptor<SemenDonorRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .note:
            try context.fetch(FetchDescriptor<NoteRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .lambingOffspring:
            try context.fetch(FetchDescriptor<LambingOffspringRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .careRule:
            try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .careReminder:
            try context.fetch(FetchDescriptor<CareReminderRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .alertDeferral:
            try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .farm, .productionBatch, .batchMembership, .feedIngredient,
             .feedRecipe, .feedRecipeComponent, .feedLine, .inventoryLot,
             .inventoryTransaction, .health, .pedigreeChange, .photoAsset,
             .feedIngredientBatch, .feedStockTransaction, .feedStockCount, .healthCatalogItem, .healthSubjectLink,
             .careBatch, .semenTransaction, .tmrBatchIngredient,
             .tmrBatchLoadLine, .tmrBatchMovement, .tmrFeedingAllocation,
             .tmrBaseline:
            nil
        }
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
        case .feedTroughObservation: return try context.fetch(FetchDescriptor<FeedTroughObservationRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .feedStockTransaction: return try context.fetch(FetchDescriptor<FeedStockTransactionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .feedStockCount: return try context.fetch(FetchDescriptor<FeedStockCountRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrFormula: return try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrFeedingPlan: return try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrFeedingPlanPen: return try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrBatch: return try context.fetch(FetchDescriptor<TMRBatchRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrBatchIngredient: return try context.fetch(FetchDescriptor<TMRBatchIngredientRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrBatchLoadLine: return try context.fetch(FetchDescriptor<TMRBatchLoadLineRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrBatchMovement: return try context.fetch(FetchDescriptor<TMRBatchMovementRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrFeedingRun: return try context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrFeedingAllocation: return try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrMealCompletion: return try context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrDeviationAcknowledgement: return try context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrMonitoringRule: return try context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .tmrBaseline: return false
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
        case .alertDeferral: return try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).contains { $0.id == id && $0.farmID == farmID }
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

    private func nonNegativeDecimal(_ text: String, label: String) throws {
        guard let value = Decimal.stable(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
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
    private func assertPenHasSheep(_ id: UUID, on date: Date, farmID: UUID, context: ModelContext) throws {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        guard FeedPenEligibility.headCounts(on: date, sheep: sheep, transfers: transfers, removals: removals)[id, default: 0] > 0 else {
            throw FarmCommandError.feedPenHasNoSheepOnDate
        }
    }
    private func assertPenOccupied(_ id: UUID, at instant: Date, farmID: UUID, context: ModelContext) throws {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let occupancy = FarmPenOccupancyIndex.make(
            farmID: farmID,
            sheep: sheep,
            transfers: transfers,
            removals: removals
        )
        guard occupancy.occupiedPenIDs(at: instant).contains(id) else {
            throw FarmCommandError.penHasNoSheepAtTime
        }
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
        if try context.fetch(FetchDescriptor<ReproductionRecord>()).contains(where: {
            $0.farmID == farmID &&
                ($0.eweID == sheepID || $0.sireID == sheepID) &&
                $0.deletedAt == nil &&
                $0.kind != .parityBaseline
        }) { return true }
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

private extension JSONDecoder {
    static var tmrMembership: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum EarTag {
    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
}
