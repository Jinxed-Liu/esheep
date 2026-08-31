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

private final class RemoteDomainReplayIndex {
    private struct FarmSheepKey: Hashable {
        let farmID: UUID
        let sheepID: UUID
    }

    private var entities: [ObjectIdentifier: [UUID: any PersistentModel]] = [:]
    private var transfersBySheep: [FarmSheepKey: [TransferRecord]] = [:]
    private var normalizedEarTagOwners: [UUID: [String: Set<UUID>]] = [:]
    /// Farm rows do not carry a revision field. During an empty-store replay,
    /// keep their revision lineage here instead of consulting the retained
    /// local DomainOperation audit log from the cache being replaced.
    private var farmRevisions: [UUID: Int] = [:]
    func rebuildFromPendingInserts(in context: ModelContext) {
        entities.removeAll(keepingCapacity: true)
        transfersBySheep.removeAll(keepingCapacity: true)
        normalizedEarTagOwners.removeAll(keepingCapacity: true)
        for model in context.insertedModelsArray {
            register(model)
        }
    }

    func rebuildFromPersistentStore(
        farmID: UUID,
        in context: ModelContext
    ) throws {
        entities.removeAll(keepingCapacity: true)
        transfersBySheep.removeAll(keepingCapacity: true)
        normalizedEarTagOwners.removeAll(keepingCapacity: true)
        farmRevisions.removeAll(keepingCapacity: true)

        for value in try context.fetch(FetchDescriptor<PenRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<SheepRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<WeightRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<TransferRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedIngredientRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedStockTransactionRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedStockCountRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(
            FetchDescriptor<FeedRecipeComponentRecord>()
        ) where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedRecordLine>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<FeedTroughObservationRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<HealthRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<ReproductionRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<SemenRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<NoteRecord>())
            where value.farmID == farmID {
            register(value)
        }
        for value in try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            where value.farmID == farmID {
            register(value)
        }

        let farmOperations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter {
                $0.farmID == farmID &&
                    $0.entityType == CloudEntityType.farm.rawValue
            }
        setFarmRevision(
            max(1, farmOperations.map(\.resultingRevision).max() ?? 1),
            for: farmID
        )
    }

    func fetch<T: PersistentModel>(_ type: T.Type, id: UUID) -> T? where T: AnyObject {
        entities[ObjectIdentifier(type)]?[id] as? T
    }

    func values<T: PersistentModel>(_ type: T.Type) -> [T] where T: AnyObject {
        entities[ObjectIdentifier(type)]?.values.compactMap { $0 as? T } ?? []
    }

    func transfers(farmID: UUID, sheepID: UUID) -> [TransferRecord] {
        transfersBySheep[FarmSheepKey(farmID: farmID, sheepID: sheepID)] ?? []
    }

    func hasEarTagConflict(farmID: UUID, normalizedEarTag: String, excluding sheepID: UUID) -> Bool {
        normalizedEarTagOwners[farmID]?[normalizedEarTag]?.contains(where: { $0 != sheepID }) == true
    }

    func farmRevision(for farmID: UUID) -> Int {
        farmRevisions[farmID] ?? 1
    }

    func setFarmRevision(_ revision: Int, for farmID: UUID) {
        farmRevisions[farmID] = revision
    }

    func replaceEarTag(for sheep: SheepRecord, with normalizedEarTag: String) {
        let oldTag = EarTag.normalized(sheep.earTag)
        if oldTag != normalizedEarTag {
            normalizedEarTagOwners[sheep.farmID]?[oldTag]?.remove(sheep.id)
        }
        normalizedEarTagOwners[sheep.farmID, default: [:]][normalizedEarTag, default: []].insert(sheep.id)
    }

    fileprivate func register(_ model: any PersistentModel) {
        switch model {
        case let value as PenRecord: register(value, id: value.id)
        case let value as SheepRecord:
            register(value, id: value.id)
            normalizedEarTagOwners[value.farmID, default: [:]][EarTag.normalized(value.earTag), default: []].insert(value.id)
        case let value as WeightRecord: register(value, id: value.id)
        case let value as WeaningRecord: register(value, id: value.id)
        case let value as BreedingProgramRecord: register(value, id: value.id)
        case let value as TransferRecord:
            if register(value, id: value.id) {
                transfersBySheep[FarmSheepKey(farmID: value.farmID, sheepID: value.sheepID), default: []].append(value)
            }
        case let value as RemovalRecord: register(value, id: value.id)
        case let value as ProductionBatchRecord: register(value, id: value.id)
        case let value as BatchMembershipRecord: register(value, id: value.id)
        case let value as FeedIngredientRecord: register(value, id: value.id)
        case let value as FeedIngredientBatchRecord: register(value, id: value.id)
        case let value as FeedStockTransactionRecord: register(value, id: value.id)
        case let value as FeedStockCountRecord: register(value, id: value.id)
        case let value as FeedRecipeRecord: register(value, id: value.id)
        case let value as FeedRecipeComponentRecord: register(value, id: value.id)
        case let value as FeedRecord: register(value, id: value.id)
        case let value as FeedRecordLine: register(value, id: value.id)
        case let value as FeedTroughObservationRecord: register(value, id: value.id)
        case let value as InventoryLotRecord: register(value, id: value.id)
        case let value as HealthRecord: register(value, id: value.id)
        case let value as ReproductionRecord: register(value, id: value.id)
        case let value as SemenRecord: register(value, id: value.id)
        case let value as NoteRecord: register(value, id: value.id)
        case let value as PhotoAssetRecord: register(value, id: value.id)
        default: break
        }
    }

    @discardableResult
    private func register<T: PersistentModel>(_ model: T, id: UUID) -> Bool {
        let typeID = ObjectIdentifier(T.self)
        let inserted = entities[typeID]?[id] == nil
        entities[typeID, default: [:]][id] = model
        return inserted
    }
}

struct RemoteDomainApplyService {
    private let replayIndex: RemoteDomainReplayIndex?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(replayAssumesEmptyBusinessStore: Bool = false) {
        replayIndex = replayAssumesEmptyBusinessStore ? RemoteDomainReplayIndex() : nil
    }

    func prepareResumableReplay(
        farmID: UUID,
        context: ModelContext
    ) throws {
        try replayIndex?.rebuildFromPersistentStore(
            farmID: farmID,
            in: context
        )
    }

    func apply(_ envelope: CloudOperationEnvelope, context: ModelContext) throws -> RemoteApplyOutcome {
        try applyDecoded(
            envelope,
            context: context,
            preservesLegacySnapshotAuthority: false,
            allowsBaselineProjection: false
        )
    }

    func applyBaselineProjection(
        _ envelope: CloudOperationEnvelope,
        context: ModelContext
    ) throws -> RemoteApplyOutcome {
        try applyDecoded(
            envelope,
            context: context,
            preservesLegacySnapshotAuthority: true,
            allowsBaselineProjection: true
        )
    }

    private func applyDecoded(
        _ envelope: CloudOperationEnvelope,
        context: ModelContext,
        preservesLegacySnapshotAuthority: Bool,
        allowsBaselineProjection: Bool
    ) throws -> RemoteApplyOutcome {
        let payload = try decoder.decode(FarmCommandCloudPayload.self, from: envelope.payload)
        if let expected = expectedEntityType(for: payload.kind), expected.rawValue != envelope.entityType {
            throw RemoteDomainApplyError.invalidPayload("kind")
        }

        switch payload.kind {
        case .care:
            guard let command = payload.careCommand else { throw RemoteDomainApplyError.invalidPayload("careCommand") }
            if try FarmCareCommandHandler
                .repairRemotePedigreeCheckpointOverlapIfNeeded(
                    command,
                    farmID: envelope.farmID,
                    resultingRevision: envelope.revision,
                    accountID: envelope.modifiedByAccountID,
                    modifiedAt: envelope.modifiedAt,
                    context: context
                ) {
                return .applied(rebuildHistoryFrom: command.rebuildHistoryFrom)
            }
            if try FarmCareCommandHandler.isApplied(command, farmID: envelope.farmID, context: context) {
                if try alignCareProjectionRevision(for: envelope, context: context) {
                    return .applied(rebuildHistoryFrom: command.rebuildHistoryFrom)
                }
                return .duplicate
            }
            let result = try FarmCareCommandHandler.validateAndApply(
                command,
                farmID: envelope.farmID,
                accountID: envelope.modifiedByAccountID,
                context: context,
                modifiedAt: envelope.modifiedAt
            )
            replayIndex?.rebuildFromPendingInserts(in: context)
            guard result.entityType.rawValue == envelope.entityType, result.entityID == envelope.entityID else { throw RemoteDomainApplyError.invalidPayload("careCommand.target") }
            _ = try alignCareProjectionRevision(for: envelope, context: context)
            return .applied(rebuildHistoryFrom: command.rebuildHistoryFrom)
        case .restoreTMRBaseline:
            guard allowsBaselineProjection else {
                throw RemoteDomainApplyError.unsupportedOperation(payload.kind.rawValue)
            }
            guard TMRCloudDataProtocol.isSupported(by: payload),
                  let snapshot = payload.tmrBaselineSnapshot else {
                throw RemoteDomainApplyError.invalidPayload("tmrBaselineSnapshot")
            }
            if try matchesExistingTMRBaseline(snapshot, farmID: envelope.farmID, context: context) {
                return .duplicate
            }
            guard try !Self.containsAnyTMRProjection(farmID: envelope.farmID, context: context) else {
                throw RemoteDomainApplyError.invalidPayload("tmrBaseline.partialProjection")
            }
            let recipes = Set(try context.fetch(FetchDescriptor<FeedRecipeRecord>())
                .filter { $0.farmID == envelope.farmID }.map(\.id))
            let ingredients = Set(try context.fetch(FetchDescriptor<FeedIngredientRecord>())
                .filter { $0.farmID == envelope.farmID }.map(\.id))
            let ingredientBatches = Set(try context.fetch(FetchDescriptor<FeedIngredientBatchRecord>())
                .filter { $0.farmID == envelope.farmID }.map(\.id))
            let feeds = Set(try context.fetch(FetchDescriptor<FeedRecord>())
                .filter { $0.farmID == envelope.farmID }.map(\.id))
            let pens = Set(try context.fetch(FetchDescriptor<PenRecord>())
                .filter { $0.farmID == envelope.farmID }.map(\.id))
            try snapshot.validate(
                recipeIDs: recipes,
                ingredientIDs: ingredients,
                ingredientBatchIDs: ingredientBatches,
                feedRecordIDs: feeds,
                penIDs: pens
            )
            snapshot.insert(farmID: envelope.farmID, context: context)
            replayIndex?.rebuildFromPendingInserts(in: context)
            return .applied(rebuildHistoryFrom: nil)
        case .saveTMRFormula, .saveTMRMonitoringRule, .saveTMRFeedingPlan,
             .produceTMRBatch, .recordTMRFeeding, .correctTMRFeedingRun,
             .reverseTMRFeedingRun, .completeTMRMeal, .reopenTMRMeal,
             .adjustTMRBatch, .closeTMRBatch, .deleteUnusedTMRBatch,
             .acknowledgeTMRDeviation:
            guard let command = payload.tmrCommand,
                  command.operationKind == payload.kind,
                  TMRCloudDataProtocol.isSupported(by: payload) else {
                throw RemoteDomainApplyError.invalidPayload("tmrCommand")
            }
            if let localRevision = try Self.tmrLocalRevision(
                entityType: envelope.entityType,
                entityID: envelope.entityID,
                farmID: envelope.farmID,
                context: context
            ) {
                if localRevision == envelope.revision { return .duplicate }
                guard localRevision == envelope.baseRevision else {
                    return .conflict(localRevision: localRevision)
                }
            } else if envelope.baseRevision != 0 {
                return .conflict(localRevision: 0)
            }
            do {
                let result = try TMRCommandHandler.validateAndApply(
                    command,
                    farmID: envelope.farmID,
                    accountID: envelope.modifiedByAccountID,
                    context: context,
                    modifiedAt: envelope.modifiedAt
                )
                guard result.entityType.rawValue == envelope.entityType,
                      result.entityID == envelope.entityID,
                      result.baseRevision == envelope.baseRevision,
                      result.resultingRevision == envelope.revision else {
                    throw RemoteDomainApplyError.invalidPayload("tmrCommand.target")
                }
                return .applied(rebuildHistoryFrom: nil)
            } catch TMRCommandApplyError.revisionConflict(let current) {
                return .conflict(localRevision: current)
            }
        case .createFarm:
            return .duplicate
        case .updateFarmLocation:
            let farmID = envelope.farmID
            var farmDescriptor = FetchDescriptor<FarmRecord>(
                predicate: #Predicate<FarmRecord> { $0.id == farmID && $0.deletedAt == nil }
            )
            farmDescriptor.fetchLimit = 1
            guard let farm = try context.fetch(farmDescriptor).first else {
                throw RemoteDomainApplyError.missingReference("farmID")
            }
            let localRevision: Int
            if let replayIndex {
                localRevision = replayIndex.farmRevision(for: farmID)
            } else {
                let entityID = farm.id
                let operationDescriptor = FetchDescriptor<DomainOperation>(
                    predicate: #Predicate<DomainOperation> { $0.farmID == farmID && $0.entityID == entityID }
                )
                localRevision = try context.fetch(operationDescriptor)
                    .map(\.resultingRevision)
                    .max() ?? 1
            }
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
            replayIndex?.setFarmRevision(envelope.revision, for: farmID)
            return .applied(rebuildHistoryFrom: nil)
        case .createPen:
            if try exists(PenRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(PenRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), note: payload.strings["note"] ?? "", createdAt: envelope.modifiedAt), context: context)
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
            let hasEarTagConflict: Bool
            if let replayIndex {
                hasEarTagConflict = replayIndex.hasEarTagConflict(
                    farmID: envelope.farmID,
                    normalizedEarTag: normalizedEarTag,
                    excluding: envelope.entityID
                )
            } else {
                let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                hasEarTagConflict = sheep.contains(where: {
                    $0.farmID == envelope.farmID &&
                    $0.id != envelope.entityID &&
                    EarTag.normalized($0.earTag) == normalizedEarTag
                })
            }
            if hasEarTagConflict {
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
                damProvenance: optionalString("damProvenance", payload).flatMap(PedigreeRelationSource.init(rawValue:)),
                sireProvenance: optionalString("sireProvenance", payload).flatMap(PedigreeRelationSource.init(rawValue:)),
                semenDonorID: optionalID("semenDonorID", payload),
                semenDonorNameSnapshot: optionalString("semenDonorNameSnapshot", payload),
                semenDonorRegistrationNumberSnapshot: optionalString("semenDonorRegistrationNumberSnapshot", payload),
                semenDonorBreedSnapshot: optionalString("semenDonorBreedSnapshot", payload),
                note: payload.strings["note"] ?? ""
            )
            record.revision = envelope.revision
            record.isBreedingRam = payload.integers["isBreedingRam"] == 1
            record.legacyStatusSnapshotIsAuthoritative = payload.integers["legacyStatusSnapshotIsAuthoritative"] == 1
            record.legacyPenSnapshotIsAuthoritative = payload.integers["legacyPenSnapshotIsAuthoritative"] == 1
            if record.legacyStatusSnapshotIsAuthoritative == true,
               let status = payload.strings["legacyStatusRawValue"].flatMap(SheepStatus.init(rawValue:)) {
                record.statusRawValue = status.rawValue
                record.removedAt = optionalDate("legacyRemovedAt", payload)
            }
            if record.legacyPenSnapshotIsAuthoritative == true, record.status == .active {
                record.currentPenID = optionalID("legacyCurrentPenID", payload)
            } else if record.status != .active {
                record.currentPenID = nil
            }
            record.updatedAt = envelope.modifiedAt
            if let avatarUpdate = SheepAvatarCloudPayload.update(from: payload) {
                try SheepAvatarSelectionStore.apply(
                    avatarUpdate,
                    sheepID: record.id,
                    farmID: envelope.farmID,
                    updatedAt: envelope.modifiedAt,
                    context: context
                )
            }
            insertIndexed(record, context: context)
            if let currentParity = payload.integers["currentParity"] {
                guard currentParity >= 0, record.sex == .ewe else {
                    throw RemoteDomainApplyError.invalidPayload("currentParity")
                }
                let parityID = LambingEntrySemantics.entryParityBaselineID(sheepID: record.id)
                if !(try exists(ReproductionRecord.self, id: parityID, context: context)) {
                    context.insert(ReproductionRecord(
                        id: parityID,
                        farmID: envelope.farmID,
                        eweID: record.id,
                        kind: .parityBaseline,
                        occurredAt: record.enteredAt,
                        parity: currentParity,
                        note: "建档时当前胎次"
                    ))
                }
            }
            return .applied(rebuildHistoryFrom: record.enteredAt)
        case .updateSheepProfile:
            guard let record = try fetch(SheepRecord.self, id: try identifier("sheepID", payload), context: context) else { throw RemoteDomainApplyError.missingReference("sheepID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            let earTag = try string("earTag", payload)
            let normalized = EarTag.normalized(earTag)
            let hasEarTagConflict: Bool
            if let replayIndex {
                hasEarTagConflict = replayIndex.hasEarTagConflict(
                    farmID: envelope.farmID,
                    normalizedEarTag: normalized,
                    excluding: record.id
                )
            } else {
                let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                hasEarTagConflict = sheep.contains(where: {
                    $0.farmID == envelope.farmID && $0.id != record.id && EarTag.normalized($0.earTag) == normalized
                })
            }
            guard !hasEarTagConflict else {
                return .conflict(localRevision: record.revision)
            }
            replayIndex?.replaceEarTag(for: record, with: normalized)
            record.earTag = earTag
            record.breed = try string("breed", payload)
            record.sexRawValue = try string("sex", payload)
            if record.sex != .ram { record.isBreedingRam = false }
            record.birthAt = optionalDate("birthAt", payload)
            record.note = payload.strings["note"] ?? ""
            record.updatedAt = envelope.modifiedAt
            record.revision = envelope.revision
            if let currentParity = payload.integers["currentParity"] {
                guard currentParity >= 0, record.sex == .ewe else {
                    throw RemoteDomainApplyError.invalidPayload("currentParity")
                }
                let parityID = LambingEntrySemantics.parityCorrectionID(sheepID: record.id, sheepRevision: record.revision)
                if !(try exists(ReproductionRecord.self, id: parityID, context: context)) {
                    context.insert(ReproductionRecord(
                        id: parityID,
                        farmID: envelope.farmID,
                        eweID: record.id,
                        kind: .parityBaseline,
                        occurredAt: payload.dates["parityRecordedAt"] ?? envelope.modifiedAt,
                        parity: currentParity,
                        note: "档案确认当前胎次"
                    ))
                }
            }
            if let avatarUpdate = SheepAvatarCloudPayload.update(from: payload) {
                try SheepAvatarSelectionStore.apply(
                    avatarUpdate,
                    sheepID: record.id,
                    farmID: envelope.farmID,
                    updatedAt: envelope.modifiedAt,
                    context: context
                )
            }
            return .applied(rebuildHistoryFrom: nil)
        case .recordWeight:
            if try exists(WeightRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(WeightRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: try identifier("sheepID", payload), kilogramsText: try string("kilogramsText", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .correctWeight:
            if try exists(WeightRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(WeightRecord.self, id: originalID, context: context), original.deletedAt == nil else { throw RemoteDomainApplyError.missingReference("originalID") }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.weight.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["reason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            insertIndexed(WeightRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: original.sheepID, kilogramsText: try string("kilogramsText", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .recordWeaning:
            if try exists(WeaningRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(WeaningRecord(
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
            ), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .createBreedingProgram:
            if try exists(BreedingProgramRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            guard !payload.breedingProgramSteps.isEmpty else { throw RemoteDomainApplyError.invalidPayload("breedingProgramSteps") }
            let createdAt = try date("createdAt", payload)
            insertIndexed(BreedingProgramRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), createdAt: createdAt), context: context)
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
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            let occurredAt = try date("occurredAt", payload)
            let transfers: [TransferRecord]
            if let replayIndex {
                transfers = replayIndex.transfers(farmID: envelope.farmID, sheepID: sheepID).filter { $0.deletedAt == nil }
            } else {
                let farmID = envelope.farmID
                transfers = try context.fetch(FetchDescriptor<TransferRecord>(
                    predicate: #Predicate<TransferRecord> {
                        $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
                    }
                ))
            }
            let record = TransferRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: sheepID, fromPenID: FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers), toPenID: optionalID("toPenID", payload), occurredAt: occurredAt, note: payload.strings["note"] ?? "")
            insertIndexed(record, context: context)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .correctTransfer:
            if try exists(TransferRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(TransferRecord.self, id: originalID, context: context), original.deletedAt == nil,
                  let sheep = try fetch(SheepRecord.self, id: original.sheepID, context: context) else { throw RemoteDomainApplyError.missingReference("originalID") }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.transfer.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["reason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            let occurredAt = try date("occurredAt", payload)
            let sheepID = original.sheepID
            let transfers: [TransferRecord]
            if let replayIndex {
                transfers = replayIndex.transfers(farmID: envelope.farmID, sheepID: sheepID).filter { $0.deletedAt == nil }
            } else {
                let farmID = envelope.farmID
                transfers = try context.fetch(FetchDescriptor<TransferRecord>(
                    predicate: #Predicate<TransferRecord> {
                        $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
                    }
                ))
            }
            let replacement = TransferRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: original.sheepID, fromPenID: FarmHistoryTimeline.pen(for: sheep, at: occurredAt, transfers: transfers), toPenID: optionalID("toPenID", payload), occurredAt: occurredAt, note: payload.strings["note"] ?? "")
            insertIndexed(replacement, context: context)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .removeSheep:
            if try exists(RemovalRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let sheepID = try identifier("sheepID", payload)
            guard let sheep = try fetch(SheepRecord.self, id: sheepID, context: context) else {
                throw RemoteDomainApplyError.missingReference("sheepID")
            }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            let occurredAt = try date("occurredAt", payload)
            insertIndexed(RemovalRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                sheepID: sheepID,
                kind: RemovalKind(rawValue: try string("kind", payload)) ?? .culled,
                reason: try string("reason", payload),
                amountText: optionalString("amountText", payload),
                removalBatchID: optionalID("removalBatchID", payload),
                batchTotalAmountText: optionalString("batchTotalAmountText", payload),
                occurredAt: occurredAt,
                note: payload.strings["note"] ?? ""
            ), context: context)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .correctRemoval:
            if try exists(RemovalRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let originalID = try identifier("originalID", payload)
            guard let original = try fetch(RemovalRecord.self, id: originalID, context: context), original.deletedAt == nil else { throw RemoteDomainApplyError.missingReference("originalID") }
            guard let sheep = try fetch(SheepRecord.self, id: original.sheepID, context: context) else {
                throw RemoteDomainApplyError.missingReference("sheepID")
            }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            original.deletedAt = envelope.modifiedAt
            original.revision += 1
            context.insert(TombstoneRecord(farmID: envelope.farmID, entityType: CloudEntityType.removal.rawValue, entityID: originalID, deletedByAccountID: envelope.modifiedByAccountID, reason: payload.strings["correctionReason"] ?? "远端修正", revision: original.revision, operationID: envelope.operationID))
            let occurredAt = try date("occurredAt", payload)
            let replacementKind = RemovalKind(rawValue: try string("kind", payload)) ?? .culled
            let retainsBatch = original.removalBatchID != nil && replacementKind == original.kind
            insertIndexed(RemovalRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                sheepID: original.sheepID,
                kind: replacementKind,
                reason: try string("reason", payload),
                amountText: retainsBatch ? nil : optionalString("amountText", payload),
                removalBatchID: retainsBatch ? original.removalBatchID : nil,
                batchTotalAmountText: retainsBatch ? original.batchTotalAmountText : nil,
                occurredAt: occurredAt,
                note: payload.strings["note"] ?? ""
            ), context: context)
            return .applied(rebuildHistoryFrom: occurredAt)
        case .restoreSheep:
            guard let record = try fetch(RemovalRecord.self, id: envelope.entityID, context: context) else { throw RemoteDomainApplyError.missingReference("removalID") }
            guard record.revision == envelope.baseRevision else { return .conflict(localRevision: record.revision) }
            guard let sheep = try fetch(SheepRecord.self, id: record.sheepID, context: context) else {
                throw RemoteDomainApplyError.missingReference("sheepID")
            }
            if !preservesLegacySnapshotAuthority {
                releaseLegacyHistoryProjectionAuthority(for: sheep)
            }
            record.deletedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: .distantPast)
        case .createBatch:
            if try exists(ProductionBatchRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(ProductionBatchRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), purpose: try string("purpose", payload), startedAt: try date("startedAt", payload), note: payload.strings["note"] ?? ""), context: context)
            let sheepIDs = (payload.strings["sheepIDs"] ?? "")
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
            for sheepID in sheepIDs {
                insertIndexed(BatchMembershipRecord(
                    id: StableCloudUUID.derived(namespace: envelope.entityID, name: "batch-member-\(sheepID.uuidString.lowercased())"),
                    farmID: envelope.farmID,
                    batchID: envelope.entityID,
                    sheepID: sheepID,
                    joinedAt: try date("startedAt", payload)
                ), context: context)
            }
            return .applied(rebuildHistoryFrom: nil)
        case .assignBatchMembership:
            if try exists(BatchMembershipRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = BatchMembershipRecord(id: envelope.entityID, farmID: envelope.farmID, batchID: try identifier("batchID", payload), sheepID: try identifier("sheepID", payload), joinedAt: try date("joinedAt", payload))
            record.leftAt = optionalDate("leftAt", payload)
            record.leaveReason = payload.optionalStrings["leaveReason"] ?? nil
            record.updatedAt = envelope.modifiedAt
            insertIndexed(record, context: context)
            if replayIndex == nil, record.leftAt != nil {
                try ProductionBatchLifecycle.reconcile(batchID: record.batchID, farmID: envelope.farmID, context: context, changedAt: envelope.modifiedAt)
            }
            return .applied(rebuildHistoryFrom: try date("joinedAt", payload))
        case .leaveBatchMembership:
            guard let record = try fetch(BatchMembershipRecord.self, id: envelope.entityID, context: context) else { throw RemoteDomainApplyError.missingReference("batchMembership") }
            if record.leftAt != nil { return .duplicate }
            record.leftAt = try date("leftAt", payload)
            record.leaveReason = payload.strings["reason"] ?? ""
            record.updatedAt = envelope.modifiedAt
            if replayIndex == nil {
                try ProductionBatchLifecycle.reconcile(batchID: record.batchID, farmID: envelope.farmID, context: context, changedAt: envelope.modifiedAt)
            }
            return .applied(rebuildHistoryFrom: record.leftAt)
        case .restoreBatchMembership:
            guard let record = try fetch(BatchMembershipRecord.self, id: envelope.entityID, context: context) else { throw RemoteDomainApplyError.missingReference("batchMembership") }
            guard let leftAt = record.leftAt else { return .duplicate }
            record.leftAt = nil
            record.leaveReason = nil
            record.updatedAt = envelope.modifiedAt
            if replayIndex == nil {
                try ProductionBatchLifecycle.reconcile(batchID: record.batchID, farmID: envelope.farmID, context: context, changedAt: envelope.modifiedAt)
            }
            return .applied(rebuildHistoryFrom: leftAt)
        case .addIngredient:
            if try exists(FeedIngredientRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(FeedIngredientRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), unit: try string("unit", payload), dryMatterText: optionalString("dryMatterText", payload)), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .createRecipe:
            if try exists(FeedRecipeRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(FeedRecipeRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), note: payload.strings["note"] ?? ""), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .addRecipeComponent:
            if try exists(FeedRecipeComponentRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(FeedRecipeComponentRecord(id: envelope.entityID, farmID: envelope.farmID, recipeID: try identifier("recipeID", payload), ingredientID: try identifier("ingredientID", payload), kilogramsText: try string("kilogramsText", payload)), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .recordFeed:
            if try exists(FeedRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = FeedRecord(id: envelope.entityID, farmID: envelope.farmID, penID: try identifier("penID", payload), recipeID: optionalID("recipeID", payload), mode: FeedMode(rawValue: try string("mode", payload)) ?? .limited, occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? "")
            insertIndexed(record, context: context)
            for line in payload.feedLines {
                guard let ingredient = try fetch(FeedIngredientRecord.self, id: line.ingredientID, context: context),
                      ingredient.farmID == envelope.farmID else {
                    throw RemoteDomainApplyError.missingReference("ingredientID")
                }
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
        case .saveFeedIngredient:
            let record: FeedIngredientRecord
            if let existing = try fetch(FeedIngredientRecord.self, id: envelope.entityID, context: context) {
                record = existing
            } else {
                record = FeedIngredientRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), unit: payload.strings["unit"] ?? "千克", category: payload.strings["category"] ?? "", nutrientSnapshotJSON: payload.strings["nutrientSnapshotJSON"] ?? "{}", kind: FeedIngredientKind(rawValue: payload.strings["kind"] ?? "legacy") ?? .legacy, sourceTemplateID: payload.optionalStrings["sourceTemplateID"] ?? nil, sourceTemplateCode: payload.optionalStrings["sourceTemplateCode"] ?? nil, mixtureComponentsJSON: payload.optionalStrings["mixtureComponentsJSON"] ?? nil, note: payload.strings["note"] ?? "")
                insertIndexed(record, context: context)
            }
            record.name = try string("name", payload)
            record.unit = payload.strings["unit"] ?? "千克"
            record.category = payload.strings["category"] ?? ""
            record.kindRawValue = payload.strings["kind"] ?? FeedIngredientKind.legacy.rawValue
            record.sourceTemplateID = payload.optionalStrings["sourceTemplateID"] ?? nil
            record.sourceTemplateCode = payload.optionalStrings["sourceTemplateCode"] ?? nil
            record.mixtureComponentsJSON = payload.optionalStrings["mixtureComponentsJSON"] ?? nil
            record.nutrientSnapshotJSON = payload.strings["nutrientSnapshotJSON"] ?? "{}"
            record.dryMatterText = payload.optionalStrings["dryMatterText"] ?? nil
            record.note = payload.strings["note"] ?? ""
            if let isActive = payload.strings["isActive"] {
                record.isActive = isActive != "0"
            }
            record.updatedAt = envelope.modifiedAt
            return .applied(rebuildHistoryFrom: nil)
        case .saveFeedBatch:
            guard let ingredient = try fetch(FeedIngredientRecord.self, id: try identifier("ingredientID", payload), context: context), ingredient.farmID == envelope.farmID else {
                throw RemoteDomainApplyError.missingReference("ingredientID")
            }
            let record: FeedIngredientBatchRecord
            if let existing = try fetch(FeedIngredientBatchRecord.self, id: envelope.entityID, context: context) {
                record = existing
            } else {
                record = FeedIngredientBatchRecord(id: envelope.entityID, farmID: envelope.farmID, ingredientID: ingredient.id, batchName: payload.strings["batchName"] ?? "", purchaseDate: optionalDate("purchaseDate", payload), supplier: payload.strings["supplier"] ?? "", storageLocation: payload.strings["storageLocation"] ?? "", pricePerKilogramText: payload.strings["pricePerKilogramText"] ?? "0", purchasedKilogramsText: payload.optionalStrings["purchasedKilogramsText"] ?? nil, packagingKind: FeedPackagingKind(rawValue: payload.strings["packagingKind"] ?? FeedPackagingKind.bulk.rawValue) ?? .bulk, packageCountText: payload.optionalStrings["packageCountText"] ?? nil, nominalPackageKilogramsText: payload.optionalStrings["nominalPackageKilogramsText"] ?? nil, stockWeightConfirmed: (payload.strings["stockWeightConfirmed"] ?? "0") == "1", initialKilogramsText: payload.optionalStrings["initialKilogramsText"] ?? nil, remainingKilogramsText: payload.optionalStrings["remainingKilogramsText"] ?? nil, note: payload.strings["note"] ?? "", isActive: (payload.strings["isActive"] ?? "1") != "0")
                insertIndexed(record, context: context)
            }
            record.ingredientID = ingredient.id
            record.batchName = payload.strings["batchName"] ?? ""
            record.purchaseDate = optionalDate("purchaseDate", payload)
            record.supplier = payload.strings["supplier"] ?? ""
            record.storageLocation = payload.strings["storageLocation"] ?? ""
            record.pricePerKilogramText = payload.strings["pricePerKilogramText"] ?? "0"
            record.purchasedKilogramsText = payload.optionalStrings["purchasedKilogramsText"] ?? nil
            record.packagingKindRawValue = payload.strings["packagingKind"] ?? FeedPackagingKind.bulk.rawValue
            record.packageCountText = payload.optionalStrings["packageCountText"] ?? nil
            record.nominalPackageKilogramsText = payload.optionalStrings["nominalPackageKilogramsText"] ?? nil
            record.stockWeightConfirmed = (payload.strings["stockWeightConfirmed"] ?? "0") == "1"
            record.initialKilogramsText = payload.optionalStrings["initialKilogramsText"] ?? nil
            record.remainingKilogramsText = payload.optionalStrings["remainingKilogramsText"] ?? nil
            record.note = payload.strings["note"] ?? ""
            record.isActive = (payload.strings["isActive"] ?? "1") != "0"
            record.updatedAt = envelope.modifiedAt
            record.revision = envelope.revision
            return .applied(rebuildHistoryFrom: nil)
        case .adjustFeedStock:
            guard let batch = try fetch(FeedIngredientBatchRecord.self, id: try identifier("batchID", payload), context: context), batch.farmID == envelope.farmID else {
                throw RemoteDomainApplyError.missingReference("batchID")
            }
            if try exists(FeedStockTransactionRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            guard let kind = FeedStockTransactionKind(rawValue: try string("kind", payload)),
                  let quantity = Decimal.stable(try string("quantityText", payload)) else {
                throw RemoteDomainApplyError.invalidPayload("stockTransaction")
            }
            let quantityText = try string("quantityText", payload)
            let isBaselineProjection = payload.strings["baselineProjection"] == "1"
            if isBaselineProjection {
                guard allowsBaselineProjection else {
                    throw RemoteDomainApplyError.invalidPayload("baselineProjection")
                }
                switch kind {
                case .openingBalance, .receipt, .consumption, .reversal, .conflict:
                    guard quantity >= 0 else { throw RemoteDomainApplyError.invalidPayload("quantityText") }
                case .adjustment:
                    break
                }
            } else {
                switch kind {
                case .receipt:
                    guard quantity > 0 else { throw RemoteDomainApplyError.invalidPayload("quantityText") }
                case .adjustment:
                    guard quantity != 0 else { throw RemoteDomainApplyError.invalidPayload("quantityText") }
                    if let balance = try FeedStockLedger.balance(for: batch, context: context), balance + quantity < 0 {
                        return .conflict(localRevision: envelope.baseRevision)
                    }
                case .openingBalance, .consumption, .reversal, .conflict:
                    throw RemoteDomainApplyError.invalidPayload("kind")
                }
            }
            insertIndexed(FeedStockTransactionRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                ingredientBatchID: batch.id,
                kind: kind,
                quantityText: quantityText,
                occurredAt: try date("occurredAt", payload),
                sourceRecordID: isBaselineProjection ? optionalID("sourceRecordID", payload) : nil,
                sourceLineID: isBaselineProjection ? optionalID("sourceLineID", payload) : nil,
                note: payload.strings["note"] ?? ""
            ), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .countFeedStock:
            let countID = envelope.entityID
            guard payload.identifiers["countID"] == countID else { throw RemoteDomainApplyError.invalidPayload("countID") }
            if try exists(FeedStockCountRecord.self, id: countID, context: context) { return .duplicate }
            let isBaselineProjection = payload.strings["baselineProjection"] == "1"
            guard !isBaselineProjection || allowsBaselineProjection else {
                throw RemoteDomainApplyError.invalidPayload("baselineProjection")
            }
            guard let batch = try fetch(FeedIngredientBatchRecord.self, id: try identifier("batchID", payload), context: context),
                  batch.farmID == envelope.farmID,
                  batch.deletedAt == nil,
                  isBaselineProjection || batch.isActive else {
                throw RemoteDomainApplyError.missingReference("batchID")
            }
            let method = FeedStockCountMethod(rawValue: payload.strings["method"] ?? FeedStockCountMethod.notMeasured.rawValue) ?? .notMeasured
            let actualText = optionalString("actualKilogramsText", payload)
            if method == .notMeasured, actualText != nil {
                throw RemoteDomainApplyError.invalidPayload("actualKilogramsText")
            }
            if actualText == nil, method != .notMeasured {
                throw RemoteDomainApplyError.invalidPayload("actualKilogramsText")
            }
            if let actualText, let actual = Decimal.stable(actualText), actual < 0 {
                throw RemoteDomainApplyError.invalidPayload("actualKilogramsText")
            } else if actualText != nil, Decimal.stable(actualText!) == nil {
                throw RemoteDomainApplyError.invalidPayload("actualKilogramsText")
            }
            if isBaselineProjection {
                guard let bookBalanceText = payload.strings["bookBalanceText"],
                      let bookBalance = Decimal.stable(bookBalanceText),
                      bookBalance >= 0 else {
                    throw RemoteDomainApplyError.invalidPayload("bookBalanceText")
                }
                let actual = actualText.flatMap(Decimal.stable)
                let differenceText = optionalString("differenceText", payload)
                let difference = differenceText.flatMap(Decimal.stable)
                let adjustmentID = optionalID("adjustmentTransactionID", payload)
                if let actual {
                    guard let difference,
                          difference == actual - bookBalance,
                          adjustmentID != nil else {
                        throw RemoteDomainApplyError.invalidPayload("differenceText")
                    }
                } else if differenceText != nil || adjustmentID != nil {
                    throw RemoteDomainApplyError.invalidPayload("differenceText")
                }
                insertIndexed(FeedStockCountRecord(
                    id: countID,
                    farmID: envelope.farmID,
                    ingredientBatchID: batch.id,
                    bookBalanceText: bookBalanceText,
                    actualKilogramsText: actualText,
                    differenceText: differenceText,
                    method: method,
                    occurredAt: try date("occurredAt", payload),
                    note: payload.strings["note"] ?? "",
                    adjustmentTransactionID: adjustmentID
                ), context: context)
                return .applied(rebuildHistoryFrom: nil)
            }
            guard let bookBalance = try FeedStockLedger.balance(for: batch, context: context) else {
                throw RemoteDomainApplyError.missingReference("stockBaseline")
            }
            let actual = actualText.flatMap(Decimal.stable)
            let difference = actual.map { $0 - bookBalance }
            let adjustmentID = difference.map { _ in StableCloudUUID.derived(namespace: countID, name: "feed-stock-count-adjustment") }
            insertIndexed(FeedStockCountRecord(id: countID, farmID: envelope.farmID, ingredientBatchID: batch.id, bookBalanceText: bookBalance.stableText, actualKilogramsText: actual?.stableText, differenceText: difference?.stableText, method: method, occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? "", adjustmentTransactionID: adjustmentID), context: context)
            if let difference, let adjustmentID {
                insertIndexed(FeedStockTransactionRecord(id: adjustmentID, farmID: envelope.farmID, ingredientBatchID: batch.id, kind: .adjustment, quantityText: difference.stableText, occurredAt: try date("occurredAt", payload), sourceRecordID: countID, note: "盘库校正（\(method.displayName)）"), context: context)
            }
            return .applied(rebuildHistoryFrom: nil)
        case .saveFeedRecipe:
            let recipe: FeedRecipeRecord
            if let existing = try fetch(FeedRecipeRecord.self, id: envelope.entityID, context: context) {
                recipe = existing
            } else {
                recipe = FeedRecipeRecord(id: envelope.entityID, farmID: envelope.farmID, name: try string("name", payload), note: payload.strings["note"] ?? "", targetPenName: payload.optionalStrings["targetPenName"] ?? nil, targetPenID: optionalID("targetPenID", payload), stageRawValue: payload.strings["stage"] ?? FeedRecipeStage.custom.rawValue, headCount: payload.integers["headCount"])
                insertIndexed(recipe, context: context)
            }
            recipe.name = try string("name", payload)
            recipe.targetPenID = optionalID("targetPenID", payload)
            recipe.targetPenName = payload.optionalStrings["targetPenName"] ?? nil
            recipe.stageRawValue = payload.strings["stage"] ?? FeedRecipeStage.custom.rawValue
            recipe.headCount = payload.integers["headCount"]
            recipe.note = payload.strings["note"] ?? ""
            if let isActive = payload.strings["isActive"] {
                recipe.isActive = isActive != "0"
            }
            recipe.updatedAt = envelope.modifiedAt
            recipe.deletedAt = nil
            let existingComponents = try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter { $0.farmID == envelope.farmID && $0.recipeID == recipe.id && $0.deletedAt == nil }
            let incomingIDs = Set(payload.recipeComponents.map(\.id))
            for component in existingComponents where !incomingIDs.contains(component.id) { component.deletedAt = envelope.modifiedAt }
            for item in payload.recipeComponents {
                guard let ingredient = try fetch(FeedIngredientRecord.self, id: item.ingredientID, context: context) else { throw RemoteDomainApplyError.missingReference("ingredientID") }
                if let batchID = item.ingredientBatchID {
                    guard let batch = try fetch(FeedIngredientBatchRecord.self, id: batchID, context: context), batch.ingredientID == ingredient.id else { throw RemoteDomainApplyError.missingReference("ingredientBatchID") }
                }
                let component = existingComponents.first(where: { $0.id == item.id }) ?? FeedRecipeComponentRecord(id: item.id, farmID: envelope.farmID, recipeID: recipe.id, ingredientID: ingredient.id, kilogramsText: item.kilogramsText, ingredientBatchID: item.ingredientBatchID, pricePerKilogramText: item.pricePerKilogramText, nutrientSnapshotJSON: item.nutrientSnapshotJSON)
                if existingComponents.first(where: { $0.id == item.id }) == nil { context.insert(component) }
                component.ingredientID = ingredient.id
                component.ingredientBatchID = item.ingredientBatchID
                component.kilogramsText = item.kilogramsText
                component.pricePerKilogramText = item.pricePerKilogramText
                component.nutrientSnapshotJSON = item.nutrientSnapshotJSON
                component.updatedAt = envelope.modifiedAt
                component.deletedAt = nil
            }
            return .applied(rebuildHistoryFrom: nil)
        case .recordFeedV2:
            if try exists(FeedRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let lines = payload.feedLines.map { FeedLineDraft(id: $0.id, ingredientID: $0.ingredientID, ingredientBatchID: $0.ingredientBatchID, kilogramsText: $0.kilogramsText) }
            do {
                if let replayIndex {
                    try FeedStockLedger.validateConsumption(
                        lines: lines,
                        farmID: envelope.farmID,
                        batches: replayIndex.values(FeedIngredientBatchRecord.self),
                        transactions: replayIndex.values(FeedStockTransactionRecord.self)
                    )
                } else {
                    try FeedStockLedger.validateConsumption(lines: lines, farmID: envelope.farmID, context: context)
                }
            } catch FeedStockLedgerError.insufficient {
                // Two offline devices may both have seen the same balance. Do
                // not clamp or overwrite the ledger; surface the feed command
                // as a deterministic sync conflict for user reconciliation.
                return .conflict(localRevision: envelope.baseRevision)
            }
            let feed = FeedRecord(id: envelope.entityID, farmID: envelope.farmID, penID: try identifier("penID", payload), recipeID: optionalID("recipeID", payload), mode: FeedMode(rawValue: try string("mode", payload)) ?? .limited, occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? "", mealName: payload.strings["mealName"] ?? "", feederName: payload.strings["feederName"] ?? "", remainingKilogramsText: payload.optionalStrings["remainingKilogramsText"] ?? nil, discardedKilogramsText: payload.optionalStrings["discardedKilogramsText"] ?? nil, recipeHeadCountSnapshot: payload.integers["recipeHeadCountSnapshot"], actualHeadCountSnapshot: payload.integers["actualHeadCountSnapshot"], scaleFactorText: payload.optionalStrings["scaleFactorText"] ?? nil, remainingCompositionJSON: payload.optionalStrings["remainingCompositionJSON"] ?? nil, excludedSheepIDs: FeedExcludedSheepCodec.decode(optionalString("excludedSheepIDsJSON", payload)))
            feed.recordedAt = envelope.modifiedAt
            feed.revision = envelope.revision
            insertIndexed(feed, context: context)
            for line in payload.feedLines {
                guard let ingredient = try fetch(FeedIngredientRecord.self, id: line.ingredientID, context: context) else { throw RemoteDomainApplyError.missingReference("ingredientID") }
                guard let batchID = line.ingredientBatchID,
                      let batch = try fetch(FeedIngredientBatchRecord.self, id: batchID, context: context), batch.ingredientID == ingredient.id else { throw RemoteDomainApplyError.missingReference("ingredientBatchID") }
                let lineRecord = FeedRecordLine(id: line.id, farmID: envelope.farmID, feedRecordID: feed.id, ingredientID: ingredient.id, kilogramsText: line.kilogramsText, stockQuantityText: line.kilogramsText, ingredientNameSnapshot: line.ingredientNameSnapshot ?? ingredient.name, ingredientBatchID: batch.id, ingredientBatchNameSnapshot: line.ingredientBatchNameSnapshot ?? batch.batchName, pricePerKilogramTextSnapshot: line.pricePerKilogramTextSnapshot ?? batch.pricePerKilogramText, nutrientSnapshotJSON: line.nutrientSnapshotJSON ?? ingredient.nutrientSnapshotJSON, unitSnapshot: line.unitSnapshot ?? ingredient.unit, dryMatterTextSnapshot: line.dryMatterTextSnapshot ?? ingredient.dryMatterText)
                insertIndexed(lineRecord, context: context)
                insertIndexed(FeedStockTransactionRecord(id: FeedStockLedger.consumptionID(for: line.id), farmID: envelope.farmID, ingredientBatchID: batch.id, kind: .consumption, quantityText: line.kilogramsText, occurredAt: feed.occurredAt, sourceRecordID: feed.id, sourceLineID: line.id, note: "投喂扣减"), context: context)
            }
            return .applied(rebuildHistoryFrom: nil)
        case .recordFeedTroughObservation:
            let observationID = envelope.entityID
            guard payload.identifiers["observationID"] == observationID else {
                throw RemoteDomainApplyError.invalidPayload("observationID")
            }
            if try exists(FeedTroughObservationRecord.self, id: observationID, context: context) {
                return .duplicate
            }
            let penID = try identifier("penID", payload)
            guard let pen = try fetch(PenRecord.self, id: penID, context: context),
                  pen.farmID == envelope.farmID else {
                throw RemoteDomainApplyError.missingReference("penID")
            }
            let feederName = (payload.strings["feederName"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let actual = Decimal.stable(try string("actualRemainingKilogramsText", payload)),
                  actual >= 0 else {
                throw RemoteDomainApplyError.invalidPayload("actualRemainingKilogramsText")
            }
            let discardedText = optionalString("discardedKilogramsText", payload)
            if let discardedText {
                guard let discarded = Decimal.stable(discardedText), discarded >= 0, discarded <= actual else {
                    throw RemoteDomainApplyError.invalidPayload("discardedKilogramsText")
                }
            }
            let relatedFeedRecordID = optionalID("relatedFeedRecordID", payload)
            if let relatedFeedRecordID {
                guard let feed = try fetch(FeedRecord.self, id: relatedFeedRecordID, context: context),
                      feed.farmID == envelope.farmID,
                      feed.penID == penID else {
                    throw RemoteDomainApplyError.missingReference("relatedFeedRecordID")
                }
            }
            let methodText = try string("measurementMethod", payload)
            guard let method = FeedTroughMeasurementMethod(rawValue: methodText) else {
                throw RemoteDomainApplyError.invalidPayload("measurementMethod")
            }
            let compositionJSON = optionalString("compositionSnapshotJSON", payload)
            if let compositionJSON {
                guard let data = compositionJSON.data(using: .utf8),
                      let components = try? JSONDecoder().decode([FeedTroughCompositionComponent].self, from: data),
                      !components.isEmpty,
                      components.allSatisfy({ (Decimal.stable($0.kilogramsText) ?? -1) >= 0 }),
                      abs(NSDecimalNumber(decimal: components.reduce(Decimal.zero) { $0 + ($1.kilograms) } - actual).doubleValue) <= 0.001 else {
                    throw RemoteDomainApplyError.invalidPayload("compositionSnapshotJSON")
                }
            }
            let observation = FeedTroughObservationRecord(
                id: observationID,
                farmID: envelope.farmID,
                penID: penID,
                relatedFeedRecordID: relatedFeedRecordID,
                feederName: feederName,
                observedAt: try date("observedAt", payload),
                actualRemainingKilogramsText: actual.stableText,
                discardedKilogramsText: discardedText.flatMap(Decimal.stable)?.stableText,
                measurementMethod: method,
                compositionSnapshotJSON: compositionJSON,
                note: payload.strings["note"] ?? ""
            )
            observation.recordedAt = envelope.modifiedAt
            observation.revision = envelope.revision
            insertIndexed(observation, context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .importHistoricalFeed:
            if try exists(FeedRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let feed = FeedRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                penID: try identifier("penID", payload),
                mode: FeedMode(rawValue: try string("mode", payload)) ?? .limited,
                occurredAt: try date("occurredAt", payload),
                note: payload.strings["note"] ?? "",
                mealName: payload.strings["mealName"] ?? "",
                feederName: payload.strings["feederName"] ?? "",
                remainingKilogramsText: optionalString("remainingKilogramsText", payload),
                discardedKilogramsText: optionalString("discardedKilogramsText", payload),
                remainingCompositionJSON: optionalString("remainingCompositionJSON", payload),
                legacySourceKey: payload.strings["legacySourceKey"]
            )
            feed.recordedAt = envelope.modifiedAt
            feed.revision = envelope.revision
            insertIndexed(feed, context: context)
            for line in payload.feedLines {
                guard let ingredient = try fetch(FeedIngredientRecord.self, id: line.ingredientID, context: context), ingredient.farmID == envelope.farmID else {
                    throw RemoteDomainApplyError.missingReference("ingredientID")
                }
                context.insert(FeedRecordLine(id: line.id, farmID: envelope.farmID, feedRecordID: feed.id, ingredientID: ingredient.id, kilogramsText: line.kilogramsText, ingredientNameSnapshot: line.ingredientNameSnapshot ?? ingredient.name, ingredientBatchNameSnapshot: line.ingredientBatchNameSnapshot, pricePerKilogramTextSnapshot: line.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: line.nutrientSnapshotJSON ?? ingredient.nutrientSnapshotJSON, unitSnapshot: line.unitSnapshot ?? ingredient.unit, dryMatterTextSnapshot: line.dryMatterTextSnapshot ?? ingredient.dryMatterText))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .recordHealth:
            if try exists(HealthRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = HealthRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: optionalID("sheepID", payload), penID: optionalID("penID", payload), kind: HealthRecordKind(rawValue: try string("kind", payload)) ?? .treatment, itemNameSnapshot: try string("itemName", payload), occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? "", inventoryLotID: optionalID("inventoryLotID", payload), quantityText: optionalString("quantityText", payload))
            insertIndexed(record, context: context)
            if let inventoryLotID = record.inventoryLotID, let quantity = record.quantityText {
                context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: record.id, name: "inventory-consumption"), farmID: envelope.farmID, inventoryLotID: inventoryLotID, kind: .consumption, quantityText: quantity, occurredAt: record.occurredAt, sourceRecordID: record.id, note: record.itemNameSnapshot))
            }
            return .applied(rebuildHistoryFrom: nil)
        case .receiveInventory:
            if try exists(InventoryLotRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let lot = InventoryLotRecord(id: envelope.entityID, farmID: envelope.farmID, catalogName: try string("catalogName", payload), kind: HealthRecordKind(rawValue: try string("kind", payload)) ?? .treatment, expiresAt: optionalDate("expiresAt", payload), startingQuantityText: try string("quantityText", payload))
            insertIndexed(lot, context: context)
            context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: lot.id, name: "inventory-receipt"), farmID: envelope.farmID, inventoryLotID: lot.id, kind: .receipt, quantityText: lot.startingQuantityText, occurredAt: try date("occurredAt", payload), note: payload.strings["note"] ?? ""))
            FarmCareCommandHandler.refreshInventoryExpiryReminder(for: lot, context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .addSemen:
            if try exists(SemenRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let record = SemenRecord(id: envelope.entityID, farmID: envelope.farmID, code: try string("code", payload), breed: try string("breed", payload), source: payload.strings["source"] ?? "", batchNumber: payload.strings["batchNumber"] ?? "", quantityText: "0", donorID: optionalID("donorID", payload))
            record.revision = envelope.revision
            record.updatedAt = envelope.modifiedAt
            insertIndexed(record, context: context)
            context.insert(SemenTransactionRecord(id: StableCloudUUID.derived(namespace: record.id, name: "semen-receipt"), farmID: envelope.farmID, semenID: record.id, kind: .receipt, quantityText: try string("quantityText", payload), occurredAt: envelope.modifiedAt, sourceRecordID: record.id, note: "冻精入库"))
            return .applied(rebuildHistoryFrom: nil)
        case .recordReproduction:
            if try exists(ReproductionRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            let kind = ReproductionRecordKind(rawValue: try string("kind", payload)) ?? .breeding
            let lambCount = payload.integers["lambCount"] ?? 0
            if kind == .lambing, !payload.lambingOffspring.isEmpty, payload.lambingOffspring.count != lambCount {
                throw RemoteDomainApplyError.invalidPayload("lambingOffspring")
            }
            let record = ReproductionRecord(id: envelope.entityID, farmID: envelope.farmID, eweID: try identifier("eweID", payload), kind: kind, occurredAt: try date("occurredAt", payload), sireID: optionalID("sireID", payload), semenID: optionalID("semenID", payload), batchID: optionalID("batchID", payload), relatedBreedingRecordID: optionalID("relatedBreedingRecordID", payload), semenNameSnapshot: optionalString("semenName", payload), semenDonorID: optionalID("semenDonorID", payload), semenDonorNameSnapshot: optionalString("semenDonorNameSnapshot", payload), semenDonorRegistrationNumberSnapshot: optionalString("semenDonorRegistrationNumberSnapshot", payload), semenDonorBreedSnapshot: optionalString("semenDonorBreedSnapshot", payload), paternalSource: optionalString("paternalSource", payload).flatMap(PaternalIdentitySource.init(rawValue:)), result: payload.strings["result"] ?? "", lambCount: lambCount, parity: payload.integers["parity"], birthDeadCount: payload.integers["birthDeadCount"], note: payload.strings["note"] ?? "")
            record.revision = envelope.revision
            record.updatedAt = envelope.modifiedAt
            insertIndexed(record, context: context)
            for detail in payload.lambingOffspring {
                if let sheepID = detail.sheepID, !(try exists(SheepRecord.self, id: sheepID, context: context)) {
                    throw RemoteDomainApplyError.missingReference("lambingOffspring.sheepID")
                }
                let offspring = LambingOffspringRecord(id: detail.id, farmID: envelope.farmID, lambingRecordID: record.id, sheepID: detail.sheepID, legacyEarTag: detail.earTag, sexRawValue: detail.sexRawValue, birthWeightText: detail.birthWeightText, isStillborn: detail.isStillborn ?? false, autoCreatedSheep: detail.autoCreatedSheep ?? false, autoBirthWeightRecordID: detail.autoBirthWeightRecordID)
                offspring.deletedByLambingRevocation = detail.deletedByLambingRevocation ?? false
                offspring.revision = detail.revision ?? 1
                offspring.updatedAt = detail.updatedAt ?? envelope.modifiedAt
                offspring.deletedAt = detail.deletedAt
                context.insert(offspring)
            }
            return .applied(rebuildHistoryFrom: nil)
        case .addNote:
            if try exists(NoteRecord.self, id: envelope.entityID, context: context) { return .duplicate }
            insertIndexed(NoteRecord(id: envelope.entityID, farmID: envelope.farmID, sheepID: optionalID("sheepID", payload), penID: optionalID("penID", payload), text: try string("text", payload), occurredAt: try date("occurredAt", payload)), context: context)
            return .applied(rebuildHistoryFrom: nil)
        case .addPhoto:
            let sha256 = try string("sha256", payload)
            let mimeType = try string("mimeType", payload)
            guard sha256.count == 64 else {
                throw RemoteDomainApplyError.invalidPayload("sha256")
            }
            let existing: PhotoAssetRecord?
            if let indexed = replayIndex?.fetch(
                PhotoAssetRecord.self,
                id: envelope.entityID
            ) {
                existing = indexed
            } else {
                existing = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                    .first(where: {
                        $0.id == envelope.entityID &&
                            $0.farmID == envelope.farmID
                    })
            }
            if let existing {
                guard existing.sha256 == sha256,
                      existing.mimeType == mimeType else {
                    throw RemoteDomainApplyError.invalidPayload("photo.identity")
                }
                // Base revision zero is the original immutable add. Only a
                // later, explicitly versioned projection refresh may repair a
                // legacy sheep association for the same binary asset.
                guard envelope.baseRevision > 0 else { return .duplicate }
                if let sheepID = optionalID("sheepID", payload) {
                    guard try exists(SheepRecord.self, id: sheepID, context: context) else {
                        throw RemoteDomainApplyError.missingReference("photo.sheepID")
                    }
                    existing.sheepID = sheepID
                }
                if let originalEarTag = payload.strings["originalEarTag"] {
                    existing.originalEarTag = originalEarTag
                }
                existing.sourceSHA256 = payload.strings["sourceSHA256"] ?? existing.sourceSHA256
                existing.sourcePixelWidth = payload.integers["sourcePixelWidth"] ?? existing.sourcePixelWidth
                existing.sourcePixelHeight = payload.integers["sourcePixelHeight"] ?? existing.sourcePixelHeight
                existing.cloudPixelWidth = payload.integers["cloudPixelWidth"] ?? existing.cloudPixelWidth
                existing.cloudPixelHeight = payload.integers["cloudPixelHeight"] ?? existing.cloudPixelHeight
                existing.capturedAt = payload.optionalDates["capturedAt"] ?? existing.capturedAt
                return .applied(rebuildHistoryFrom: nil)
            }
            let asset = PhotoAssetRecord(
                id: envelope.entityID,
                farmID: envelope.farmID,
                sheepID: optionalID("sheepID", payload),
                legacySourceKey: "supabase:\(envelope.entityID.uuidString.lowercased())",
                originalEarTag: payload.strings["originalEarTag"] ?? "",
                relativePath: "",
                sha256: sha256,
                mimeType: mimeType
            )
            asset.sourceSHA256 = payload.strings["sourceSHA256"] ?? sha256
            asset.sourcePixelWidth = payload.integers["sourcePixelWidth"] ?? 0
            asset.sourcePixelHeight = payload.integers["sourcePixelHeight"] ?? 0
            asset.cloudPixelWidth = payload.integers["cloudPixelWidth"] ?? 0
            asset.cloudPixelHeight = payload.integers["cloudPixelHeight"] ?? 0
            asset.capturedAt = payload.optionalDates["capturedAt"] ?? nil
            insertIndexed(asset, context: context)
            context.insert(CloudAssetTransfer(
                farmID: envelope.farmID,
                assetID: asset.id,
                localRelativePath: "",
                payloadDigest: sha256,
                byteCount: Int64(payload.integers["byteCount"] ?? 0),
                direction: .download,
                sourceDigest: asset.sourceSHA256
            ))
            return .applied(rebuildHistoryFrom: nil)
        case .tombstoneEntity:
            guard let entityTypeText = payload.strings["entityType"], let entityType = CloudEntityType(rawValue: entityTypeText), entityTypeText == envelope.entityType else {
                throw RemoteDomainApplyError.invalidPayload("entityType")
            }
            let entityID = try identifier("entityID", payload)
            guard entityID == envelope.entityID else { throw RemoteDomainApplyError.invalidPayload("entityID") }
            let operationID = envelope.operationID
            var tombstoneDescriptor = FetchDescriptor<TombstoneRecord>(
                predicate: #Predicate<TombstoneRecord> { $0.operationID == operationID }
            )
            tombstoneDescriptor.fetchLimit = 1
            if try context.fetch(tombstoneDescriptor).first != nil { return .duplicate }
            if !preservesLegacySnapshotAuthority {
                try releaseLegacyHistoryProjectionAuthority(
                    affectedBy: entityType,
                    entityID: entityID,
                    context: context
                )
            }
            try DomainEntityDeletionService.setDeletedAt(envelope.deletedAt ?? envelope.modifiedAt, type: entityType, id: entityID, farmID: envelope.farmID, context: context)
            let tombstone = TombstoneRecord(
                farmID: envelope.farmID,
                entityType: entityType.rawValue,
                entityID: entityID,
                deletedByAccountID: envelope.modifiedByAccountID,
                reason: payload.strings["reason"] ?? "远端删除",
                revision: envelope.revision,
                operationID: envelope.operationID
            )
            tombstone.deletedAt = envelope.deletedAt ?? envelope.modifiedAt
            context.insert(tombstone)
            return .applied(rebuildHistoryFrom: .distantPast)
        case .restoreTombstonedEntity:
            let tombstoneID = try identifier("tombstoneID", payload)
            let farmID = envelope.farmID
            var tombstoneDescriptor = FetchDescriptor<TombstoneRecord>(
                predicate: #Predicate<TombstoneRecord> { $0.id == tombstoneID && $0.farmID == farmID }
            )
            tombstoneDescriptor.fetchLimit = 1
            guard let tombstone = try context.fetch(tombstoneDescriptor).first,
                  let entityType = CloudEntityType(rawValue: tombstone.entityType) else {
                throw RemoteDomainApplyError.missingReference("tombstoneID")
            }
            if tombstone.restoredByOperationID == envelope.operationID { return .duplicate }
            if !preservesLegacySnapshotAuthority {
                try releaseLegacyHistoryProjectionAuthority(
                    affectedBy: entityType,
                    entityID: tombstone.entityID,
                    context: context
                )
            }
            try DomainEntityDeletionService.setDeletedAt(nil, type: entityType, id: tombstone.entityID, farmID: envelope.farmID, context: context)
            tombstone.restoredAt = envelope.modifiedAt
            tombstone.restoredByOperationID = envelope.operationID
            return .applied(rebuildHistoryFrom: .distantPast)
        case .resolveConflict:
            guard let resolvedPayload = payload.dataValues["resolvedPayload"], let entityType = payload.strings["entityType"], entityType == envelope.entityType else {
                throw RemoteDomainApplyError.invalidPayload("resolvedPayload")
            }
            let changedAt = try ConflictDomainMergeService.apply(payload: resolvedPayload, entityType: entityType, entityID: envelope.entityID, farmID: envelope.farmID, revision: envelope.revision, context: context)
            replayIndex?.rebuildFromPendingInserts(in: context)
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
            return try applyDecoded(
                sourceEnvelope,
                context: context,
                preservesLegacySnapshotAuthority: preservesLegacySnapshotAuthority,
                allowsBaselineProjection: allowsBaselineProjection
            )
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
            return try applyDecoded(
                sourceEnvelope,
                context: context,
                preservesLegacySnapshotAuthority: true,
                allowsBaselineProjection: true
            )
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
        case .assignBatchMembership, .leaveBatchMembership, .restoreBatchMembership: .batchMembership
        case .addIngredient: .feedIngredient
        case .createRecipe: .feedRecipe
        case .addRecipeComponent: .feedRecipeComponent
        case .recordFeed: .feed
        case .saveFeedIngredient: .feedIngredient
        case .saveFeedBatch: .feedIngredientBatch
        case .adjustFeedStock: .feedStockTransaction
        case .countFeedStock: .feedStockCount
        case .saveFeedRecipe: .feedRecipe
        case .recordFeedV2, .importHistoricalFeed: .feed
        case .recordFeedTroughObservation: .feedTroughObservation
        case .restoreTMRBaseline: .tmrBaseline
        case .saveTMRFormula: .tmrFormula
        case .saveTMRMonitoringRule: .tmrMonitoringRule
        case .saveTMRFeedingPlan: .tmrFeedingPlan
        case .produceTMRBatch, .recordTMRFeeding, .correctTMRFeedingRun,
             .reverseTMRFeedingRun, .adjustTMRBatch, .closeTMRBatch,
             .deleteUnusedTMRBatch: .tmrBatch
        case .completeTMRMeal, .reopenTMRMeal: .tmrMealCompletion
        case .acknowledgeTMRDeviation: .tmrDeviationAcknowledgement
        case .recordHealth: .health
        case .receiveInventory: .inventoryLot
        case .addSemen: .semen
        case .recordReproduction: .reproduction
        case .addNote: .note
        case .addPhoto: .photoAsset
        case .care, .tombstoneEntity, .restoreTombstonedEntity, .resolveConflict, .recoverEntity, .bootstrapEntity: nil
        }
    }

    static func tmrLocalRevision(
        entityType: String,
        entityID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> Int? {
        switch CloudEntityType(rawValue: entityType) {
        case .tmrFormula:
            return try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.formulaRevision
        case .tmrMonitoringRule:
            return try context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrFeedingPlan:
            return try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrBatch:
            return try context.fetch(FetchDescriptor<TMRBatchRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrMealCompletion:
            return try context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrDeviationAcknowledgement:
            return try context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>()).first {
                $0.id == entityID && $0.farmID == farmID
            }?.revision
        case .tmrBaseline:
            return nil
        default:
            return nil
        }
    }

    static func containsAnyTMRProjection(farmID: UUID, context: ModelContext) throws -> Bool {
        try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRFeedingPlanRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRBatchRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRBatchIngredientRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRBatchLoadLineRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRBatchMovementRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRFeedingRunRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRMealCompletionRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>()).contains { $0.farmID == farmID }
            || context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>()).contains { $0.farmID == farmID }
    }

    private func matchesExistingTMRBaseline(
        _ snapshot: FarmTMRBackupPayload,
        farmID: UUID,
        context: ModelContext
    ) throws -> Bool {
        let profileIDs = Set(try context.fetch(FetchDescriptor<TMRFormulaProfileRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let planIDs = Set(try context.fetch(FetchDescriptor<TMRFeedingPlanRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let planPenIDs = Set(try context.fetch(FetchDescriptor<TMRFeedingPlanPenRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let batchIDs = Set(try context.fetch(FetchDescriptor<TMRBatchRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let batchIngredientIDs = Set(try context.fetch(FetchDescriptor<TMRBatchIngredientRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let loadLineIDs = Set(try context.fetch(FetchDescriptor<TMRBatchLoadLineRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let movementIDs = Set(try context.fetch(FetchDescriptor<TMRBatchMovementRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let runIDs = Set(try context.fetch(FetchDescriptor<TMRFeedingRunRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let allocationIDs = Set(try context.fetch(FetchDescriptor<TMRFeedingAllocationRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let completionIDs = Set(try context.fetch(FetchDescriptor<TMRMealCompletionRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let acknowledgementIDs = Set(try context.fetch(FetchDescriptor<TMRDeviationAcknowledgementRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let ruleIDs = Set(try context.fetch(FetchDescriptor<TMRMonitoringRuleRecord>())
            .filter { $0.farmID == farmID }.map(\.id))
        let hasAny = !profileIDs.isEmpty || !planIDs.isEmpty || !planPenIDs.isEmpty ||
            !batchIDs.isEmpty || !batchIngredientIDs.isEmpty || !loadLineIDs.isEmpty ||
            !movementIDs.isEmpty || !runIDs.isEmpty || !allocationIDs.isEmpty ||
            !completionIDs.isEmpty || !acknowledgementIDs.isEmpty || !ruleIDs.isEmpty
        guard hasAny else { return false }
        return profileIDs == Set(snapshot.formulaProfiles.map(\.id)) &&
            planIDs == Set(snapshot.plans.map(\.id)) &&
            planPenIDs == Set(snapshot.planPens.map(\.id)) &&
            batchIDs == Set(snapshot.batches.map(\.id)) &&
            batchIngredientIDs == Set(snapshot.batchIngredients.map(\.id)) &&
            loadLineIDs == Set(snapshot.loadLines.map(\.id)) &&
            movementIDs == Set(snapshot.movements.map(\.id)) &&
            runIDs == Set(snapshot.feedingRuns.map(\.id)) &&
            allocationIDs == Set(snapshot.feedingAllocations.map(\.id)) &&
            completionIDs == Set(snapshot.mealCompletions.map(\.id)) &&
            acknowledgementIDs == Set(snapshot.deviationAcknowledgements.map(\.id)) &&
            ruleIDs == Set(snapshot.monitoringRules.map(\.id))
    }

    private func releaseLegacyHistoryProjectionAuthority(for sheep: SheepRecord) {
        sheep.legacyStatusSnapshotIsAuthoritative = false
        sheep.legacyPenSnapshotIsAuthoritative = false
    }

    /// Care commands predate baseline snapshots and normally advance their
    /// projection by one local revision. A compact/migration baseline can
    /// represent a later authoritative revision in a single command, so keep
    /// the two revisioned alert entities aligned with the envelope.
    private func alignCareProjectionRevision(
        for envelope: CloudOperationEnvelope,
        context: ModelContext
    ) throws -> Bool {
        switch CloudEntityType(rawValue: envelope.entityType) {
        case .careRule:
            guard let record = try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).first(where: {
                $0.id == envelope.entityID && $0.farmID == envelope.farmID
            }), record.revision < envelope.revision else { return false }
            record.revision = envelope.revision
            return true
        case .alertDeferral:
            guard let record = try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).first(where: {
                $0.id == envelope.entityID && $0.farmID == envelope.farmID
            }), record.revision < envelope.revision else { return false }
            record.revision = envelope.revision
            return true
        default:
            return false
        }
    }

    private func releaseLegacyHistoryProjectionAuthority(
        affectedBy entityType: CloudEntityType,
        entityID: UUID,
        context: ModelContext
    ) throws {
        let sheepID: UUID?
        switch entityType {
        case .transfer:
            sheepID = try fetch(TransferRecord.self, id: entityID, context: context)?.sheepID
        case .removal:
            sheepID = try fetch(RemovalRecord.self, id: entityID, context: context)?.sheepID
        default:
            sheepID = nil
        }
        guard let sheepID,
              let sheep = try fetch(SheepRecord.self, id: sheepID, context: context) else {
            return
        }
        releaseLegacyHistoryProjectionAuthority(for: sheep)
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

    private func insertIndexed<T: PersistentModel>(_ model: T, context: ModelContext) {
        context.insert(model)
        replayIndex?.register(model)
    }

    private func exists<T: PersistentModel>(_ type: T.Type, id: UUID, context: ModelContext) throws -> Bool where T: AnyObject {
        if let replayIndex {
            // Every entity type queried through exists is registered at its
            // exact insertion site. Because replay starts from an empty/purged
            // business store, a cache miss is authoritative and avoids an
            // unindexed negative SQL scan for every baseline entity.
            return replayIndex.fetch(type, id: id) != nil
        }
        return try fetch(type, id: id, context: context) != nil
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, id: UUID, context: ModelContext) throws -> T? where T: AnyObject {
        if let cached = replayIndex?.fetch(type, id: id) {
            return cached
        }
        let fetched: T? = switch type {
        case is PenRecord.Type:
            try fetchFirst(FetchDescriptor<PenRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is SheepRecord.Type:
            try fetchFirst(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is WeightRecord.Type:
            try fetchFirst(FetchDescriptor<WeightRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is WeaningRecord.Type:
            try fetchFirst(FetchDescriptor<WeaningRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is BreedingProgramRecord.Type:
            try fetchFirst(FetchDescriptor<BreedingProgramRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is TransferRecord.Type:
            try fetchFirst(FetchDescriptor<TransferRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is RemovalRecord.Type:
            try fetchFirst(FetchDescriptor<RemovalRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is ProductionBatchRecord.Type:
            try fetchFirst(FetchDescriptor<ProductionBatchRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is BatchMembershipRecord.Type:
            try fetchFirst(FetchDescriptor<BatchMembershipRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedIngredientRecord.Type:
            try fetchFirst(FetchDescriptor<FeedIngredientRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedIngredientBatchRecord.Type:
            try fetchFirst(FetchDescriptor<FeedIngredientBatchRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedStockTransactionRecord.Type:
            try fetchFirst(FetchDescriptor<FeedStockTransactionRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedStockCountRecord.Type:
            try fetchFirst(FetchDescriptor<FeedStockCountRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedRecipeRecord.Type:
            try fetchFirst(FetchDescriptor<FeedRecipeRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedRecipeComponentRecord.Type:
            try fetchFirst(FetchDescriptor<FeedRecipeComponentRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedRecord.Type:
            try fetchFirst(FetchDescriptor<FeedRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedRecordLine.Type:
            try fetchFirst(FetchDescriptor<FeedRecordLine>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is FeedTroughObservationRecord.Type:
            try fetchFirst(FetchDescriptor<FeedTroughObservationRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is InventoryLotRecord.Type:
            try fetchFirst(FetchDescriptor<InventoryLotRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is HealthRecord.Type:
            try fetchFirst(FetchDescriptor<HealthRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is ReproductionRecord.Type:
            try fetchFirst(FetchDescriptor<ReproductionRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is SemenRecord.Type:
            try fetchFirst(FetchDescriptor<SemenRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        case is NoteRecord.Type:
            try fetchFirst(FetchDescriptor<NoteRecord>(predicate: #Predicate { $0.id == id }), context: context) as? T
        default:
            nil
        }
        if let fetched {
            replayIndex?.register(fetched)
        }
        return fetched
    }

    private func fetchFirst<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, context: ModelContext) throws -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
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
