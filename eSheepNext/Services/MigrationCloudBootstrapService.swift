import Foundation
import SwiftData

struct MigrationCloudBootstrapResult: Sendable, Equatable {
    let operationCount: Int
    let photoCount: Int
    let baselineDigest: String
    let wasAlreadyPrepared: Bool
}

enum MigrationCloudBootstrapError: LocalizedError {
    case farmMissing
    case ownerMismatch
    case commitMissing
    case conflictingCloudBinding
    case duplicateEarTag
    case missingPhoto(String)
    case photoDigestMismatch(String)

    var errorDescription: String? {
        switch self {
        case .farmMissing: "找不到需要准备云端基线的迁移牧场。"
        case .ownerMismatch: "迁移提交与当前牧场主不一致，未升级云端状态。"
        case .commitMissing: "缺少完整迁移提交凭据，未升级云端状态。"
        case .conflictingCloudBinding: "牧场已经绑定其他 iCloud 区域，不能自动升级。"
        case .duplicateEarTag: "迁移牧场存在重复耳号，不能生成云端基线。"
        case .missingPhoto(let key): "迁移照片文件缺失：\(key)。"
        case .photoDigestMismatch(let key): "迁移照片摘要不一致：\(key)。"
        }
    }
}

@MainActor
struct MigrationCloudBootstrapService {
    private static let summaryPrefix = "迁移云端基线："

    func prepare(
        commit: MigrationCommitRecord,
        farm: FarmRecord,
        accountID: UUID,
        context: ModelContext
    ) throws -> MigrationCloudBootstrapResult {
        guard farm.deletedAt == nil else { throw MigrationCloudBootstrapError.farmMissing }
        guard farm.ownerAccountID == accountID, commit.ownerAccountID == accountID else {
            throw MigrationCloudBootstrapError.ownerMismatch
        }
        guard commit.status == .completed, commit.farmID == farm.id else {
            throw MigrationCloudBootstrapError.commitMissing
        }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>()).filter { $0.farmID == farm.id }
        guard bindings.isEmpty else { throw MigrationCloudBootstrapError.conflictingCloudBinding }

        if commit.cloudState != .localCommitted,
           !commit.baselineDigest.isEmpty,
           commit.baselineEntityCount > 0 {
            return .init(
                operationCount: commit.baselineEntityCount,
                photoCount: commit.baselinePhotoCount,
                baselineDigest: commit.baselineDigest,
                wasAlreadyPrepared: true
            )
        }

        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farm.id }
        let normalizedTags = sheep.map { EarTag.normalized($0.earTag) }
        guard Set(normalizedTags).count == normalizedTags.count else {
            throw MigrationCloudBootstrapError.duplicateEarTag
        }

        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == farm.id && $0.deletedAt == nil }
        let existingTransfers = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).filter { $0.farmID == farm.id }
        for photo in photos {
            let url = Self.assetURL(relativePath: photo.relativePath)
            guard let data = try? Data(contentsOf: url) else { throw MigrationCloudBootstrapError.missingPhoto(photo.legacySourceKey) }
            guard CloudPayloadDigest.hex(for: data) == photo.sha256 else {
                throw MigrationCloudBootstrapError.photoDigestMismatch(photo.legacySourceKey)
            }
            if !existingTransfers.contains(where: { $0.assetID == photo.id && $0.direction == .upload }) {
                context.insert(CloudAssetTransfer(
                    id: StableMigrationID.uuid(sessionID: commit.sessionID, sourceKey: "cloud-bootstrap-asset:\(photo.id.uuidString.lowercased())"),
                    farmID: farm.id,
                    assetID: photo.id,
                    localRelativePath: photo.relativePath,
                    payloadDigest: photo.sha256,
                    byteCount: Int64(data.count),
                    direction: .upload,
                    sourceDigest: photo.sourceSHA256.isEmpty ? photo.sha256 : photo.sourceSHA256
                ))
            }
        }

        var prepared: [(entityType: CloudEntityType, entityID: UUID, revision: Int, sourcePayload: Data, order: Int)] = []
        try appendFarm(farm, to: &prepared)
        try appendRecords(farmID: farm.id, context: context, to: &prepared)
        prepared.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.entityType.rawValue != $1.entityType.rawValue { return $0.entityType.rawValue < $1.entityType.rawValue }
            return $0.entityID.uuidString < $1.entityID.uuidString
        }

        let existing = try context.fetch(FetchDescriptor<DomainOperation>()).filter {
            $0.farmID == farm.id && $0.summary.hasPrefix(Self.summaryPrefix)
        }
        let existingIDs = Set(existing.map(\.id))
        var digestLines: [String] = []
        var insertedCount = 0
        let bootstrapAuthorizedAt = Date.now
        for item in prepared {
            let sourceDigest = CloudPayloadDigest.hex(for: item.sourcePayload)
            let operationID = StableMigrationID.uuid(
                sessionID: commit.sessionID,
                sourceKey: "cloud-bootstrap:\(item.entityType.rawValue):\(item.entityID.uuidString.lowercased()):\(sourceDigest)"
            )
            digestLines.append("\(item.entityType.rawValue):\(item.entityID.uuidString.lowercased()):\(sourceDigest)")
            guard !existingIDs.contains(operationID) else { continue }

            let snapshot = BootstrapEntityEnvelopeV1(
                entityType: item.entityType.rawValue,
                entityID: item.entityID,
                sourceRevision: item.revision,
                sourcePayload: item.sourcePayload
            )
            var wrapper = FarmCommandCloudPayload(kind: .bootstrapEntity)
            wrapper.dataValues["snapshot"] = try JSONEncoder.cloud.encode(snapshot)
            let payload = try JSONEncoder.cloud.encode(wrapper)
            let operation = DomainOperation(
                id: operationID,
                farmID: farm.id,
                accountID: accountID,
                kind: .bootstrapEntity,
                // This is the cloud bootstrap authorization time. Historical
                // entity dates remain inside sourcePayload and are not rewritten.
                occurredAt: bootstrapAuthorizedAt,
                summary: "\(Self.summaryPrefix)\(item.entityType.rawValue)",
                entityType: item.entityType.rawValue,
                entityID: item.entityID,
                baseRevision: 0,
                resultingRevision: max(1, item.revision),
                payload: payload
            )
            context.insert(operation)
            context.insert(OutboxItem(
                id: StableMigrationID.uuid(sessionID: commit.sessionID, sourceKey: "cloud-bootstrap-outbox:\(operationID.uuidString.lowercased())"),
                farmID: farm.id,
                accountID: accountID,
                operationID: operation.id,
                entityType: operation.entityType,
                entityID: operation.entityID,
                baseRevision: operation.baseRevision,
                payloadDigest: operation.payloadDigest
            ))
            insertedCount += 1
        }

        let digest = CloudPayloadDigest.hex(for: Data(digestLines.sorted().joined(separator: "\n").utf8))
        commit.cloudState = .baselineReady
        commit.baselineDigest = digest
        commit.baselineEntityCount = prepared.count
        commit.baselinePhotoCount = photos.count
        commit.cloudLastError = nil
        commit.cloudUpgradedAt = .now
        farm.isLocalOnlyMigration = false
        farm.updatedAt = .now

        return .init(
            operationCount: prepared.count,
            photoCount: photos.count,
            baselineDigest: digest,
            wasAlreadyPrepared: insertedCount == 0
        )
    }

    func upgradeEligibleLegacyFarms(accountID: UUID, context: ModelContext) throws -> [MigrationCloudBootstrapResult] {
        let farms = try context.fetch(FetchDescriptor<FarmRecord>()).filter {
            $0.ownerAccountID == accountID && $0.isLocalOnlyMigration && $0.deletedAt == nil
        }
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>())
        var results: [MigrationCloudBootstrapResult] = []
        for farm in farms {
            guard let commit = commits.first(where: { $0.farmID == farm.id && $0.ownerAccountID == accountID && $0.status == .completed }) else {
                continue
            }
            do {
                results.append(try prepare(commit: commit, farm: farm, accountID: accountID, context: context))
                try context.save()
            } catch {
                context.rollback()
                if let failedCommit = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commit.id }) {
                    failedCommit.cloudState = .failed
                    failedCommit.cloudLastError = error.localizedDescription
                    failedCommit.cloudRetryCount += 1
                }
                try context.save()
            }
        }
        return results
    }

    private func appendFarm(
        _ farm: FarmRecord,
        to values: inout [(entityType: CloudEntityType, entityID: UUID, revision: Int, sourcePayload: Data, order: Int)]
    ) throws {
        var payload = FarmCommandCloudPayload(kind: .createFarm)
        payload.strings = ["name": farm.name]
        values.append((.farm, farm.id, 1, try JSONEncoder.cloud.encode(payload), 0))
        if let snapshot = farm.locationSnapshot {
            let command = FarmCommand.updateFarmLocation(
                displayName: snapshot.displayName,
                latitude: snapshot.latitude,
                longitude: snapshot.longitude,
                addressSnapshot: farm.addressSnapshot,
                timeZoneIdentifier: snapshot.timeZoneIdentifier,
                source: snapshot.source,
                horizontalAccuracyMeters: farm.horizontalAccuracyMeters
            )
            values.append((.farm, farm.id, 2, try FarmCommandCloudPayloadEncoder.encode(command), 1))
        }
    }

    private func appendRecords(
        farmID: UUID,
        context: ModelContext,
        to values: inout [(entityType: CloudEntityType, entityID: UUID, revision: Int, sourcePayload: Data, order: Int)]
    ) throws {
        for value in try context.fetch(FetchDescriptor<SemenDonorRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let initial = CareSemenDonorDraft(id: value.id, name: value.name, registrationNumber: value.registrationNumber, breed: value.breed, linkedRamID: nil, note: value.note, status: value.status, expectedRevision: 0)
            values.append((.semenDonor, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.care(.upsertSemenDonor(initial))), 5))
            if let linkedRamID = value.linkedRamID {
                let linked = CareSemenDonorDraft(id: value.id, name: value.name, registrationNumber: value.registrationNumber, breed: value.breed, linkedRamID: linkedRamID, note: value.note, status: value.status, expectedRevision: 1)
                values.append((.semenDonor, value.id, 2, try FarmCommandCloudPayloadEncoder.encode(.care(.upsertSemenDonor(linked))), 25))
            }
        }
        for value in try context.fetch(FetchDescriptor<PenRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.pen, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.createPen(name: value.name, note: value.note)), 10))
        }
        for value in try context.fetch(FetchDescriptor<SheepRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.addSheep(earTag: value.earTag, breed: value.breed, sex: value.sex, penID: value.initialPenID, occurredAt: value.enteredAt, birthAt: value.birthAt, note: value.note)))
            payload.optionalStrings["legacyEarTag"] = value.legacyEarTag
            payload.optionalStrings["legacySourceKey"] = value.legacySourceKey
            payload.strings["purpose"] = value.purpose
            payload.integers["isHistoricalArchive"] = value.isHistoricalArchive ? 1 : 0
            payload.integers["isBreedingRam"] = value.isBreedingRam ? 1 : 0
            payload.optionalIdentifiers["damID"] = value.damID
            payload.optionalIdentifiers["sireID"] = value.sireID
            payload.optionalIdentifiers["semenDonorID"] = value.semenDonorID
            payload.optionalStrings["damProvenance"] = value.damProvenanceRawValue
            payload.optionalStrings["sireProvenance"] = value.sireProvenanceRawValue
            payload.optionalStrings["semenDonorNameSnapshot"] = value.semenDonorNameSnapshot
            payload.optionalStrings["semenDonorRegistrationNumberSnapshot"] = value.semenDonorRegistrationNumberSnapshot
            payload.optionalStrings["semenDonorBreedSnapshot"] = value.semenDonorBreedSnapshot
            values.append((.sheep, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 20))
        }
        for value in try context.fetch(FetchDescriptor<WeightRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.weight, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.recordWeight(sheepID: value.sheepID, kilogramsText: value.kilogramsText, occurredAt: value.occurredAt, note: value.note)), 30))
        }
        for value in try context.fetch(FetchDescriptor<WeaningRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.weaning, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.recordWeaning(sheepID: value.sheepID, weanWeightText: value.weanWeightText, occurredAt: value.occurredAt, birthAt: value.birthAt, birthWeightText: value.birthWeightText, averageDailyGainText: value.averageDailyGainText, damID: value.damID, litterSize: value.litterSize, note: value.note)), 30))
        }
        let steps = try context.fetch(FetchDescriptor<BreedingProgramStepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        for value in try context.fetch(FetchDescriptor<BreedingProgramRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let drafts = steps.filter { $0.programID == value.id }.sorted { $0.sortOrder < $1.sortOrder }.map { BreedingProgramStepDraft(id: $0.id, dayOffset: $0.dayOffset, action: $0.action) }
            values.append((.breedingProgram, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.createBreedingProgram(name: value.name, createdAt: value.createdAt, steps: drafts)), 10))
        }
        for value in try context.fetch(FetchDescriptor<TransferRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.transfer, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.transferSheep(sheepID: value.sheepID, toPenID: value.toPenID, occurredAt: value.occurredAt, note: value.note)), 30))
        }
        for value in try context.fetch(FetchDescriptor<RemovalRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.removal, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.removeSheep(sheepID: value.sheepID, kind: value.kind, reason: value.reason, amountText: value.amountText, occurredAt: value.occurredAt, note: value.note)), 30))
        }
        for value in try context.fetch(FetchDescriptor<ProductionBatchRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.productionBatch, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.createBatch(name: value.name, purpose: value.purpose, startedAt: value.startedAt, sheepIDs: [], note: value.note)), 10))
        }
        for value in try context.fetch(FetchDescriptor<BatchMembershipRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.assignSheepToBatch(batchID: value.batchID, sheepID: value.sheepID, joinedAt: value.joinedAt)))
            payload.optionalDates["leftAt"] = value.leftAt
            payload.optionalStrings["leaveReason"] = value.leaveReason
            values.append((.batchMembership, value.id, value.leftAt == nil ? 1 : 2, try JSONEncoder.cloud.encode(payload), 30))
        }
        for value in try context.fetch(FetchDescriptor<FeedIngredientRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.addIngredient(name: value.name, unit: value.unit, dryMatterText: value.dryMatterText)))
            payload.strings["category"] = value.category
            payload.strings["nutrientSnapshotJSON"] = value.nutrientSnapshotJSON
            values.append((.feedIngredient, value.id, 1, try JSONEncoder.cloud.encode(payload), 10))
        }
        for value in try context.fetch(FetchDescriptor<FeedRecipeRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.feedRecipe, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.createRecipe(name: value.name, note: value.note)), 10))
        }
        for value in try context.fetch(FetchDescriptor<FeedRecipeComponentRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.feedRecipeComponent, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.addRecipeComponent(recipeID: value.recipeID, ingredientID: value.ingredientID, kilogramsText: value.kilogramsText)), 20))
        }
        let feedLines = try context.fetch(FetchDescriptor<FeedRecordLine>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        for value in try context.fetch(FetchDescriptor<FeedRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            let lines = feedLines.filter { $0.feedRecordID == value.id }.map { FarmCommandCloudPayload.FeedLine(id: $0.id, ingredientID: $0.ingredientID, kilogramsText: $0.kilogramsText, ingredientBatchID: $0.ingredientBatchID, ingredientNameSnapshot: $0.ingredientNameSnapshot, ingredientBatchNameSnapshot: $0.ingredientBatchNameSnapshot, pricePerKilogramTextSnapshot: $0.pricePerKilogramTextSnapshot, nutrientSnapshotJSON: $0.nutrientSnapshotJSON, unitSnapshot: $0.unitSnapshot, dryMatterTextSnapshot: $0.dryMatterTextSnapshot) }
            values.append((.feed, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.recordFeed(penID: value.penID, recipeID: value.recipeID, mode: value.mode, occurredAt: value.occurredAt, lines: [], note: value.note), resolvedFeedLines: lines), 30))
        }
        for value in try context.fetch(FetchDescriptor<InventoryLotRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.inventoryLot, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.receiveInventory(catalogName: value.catalogName, kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment, expiresAt: value.expiresAt, quantityText: value.startingQuantityText, occurredAt: value.receivedAt ?? value.createdAt, note: "旧版迁移库存")), 10))
        }
        for value in try context.fetch(FetchDescriptor<HealthRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.health, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.recordHealth(sheepID: value.sheepID, penID: value.penID, kind: HealthRecordKind(rawValue: value.kindRawValue) ?? .treatment, itemName: value.itemNameSnapshot, occurredAt: value.occurredAt, note: value.note, inventoryLotID: value.inventoryLotID, quantityText: value.quantityText)), 30))
        }
        let offspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.farmID == farmID }
        for value in try context.fetch(FetchDescriptor<ReproductionRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.recordReproduction(eweID: value.eweID, kind: value.kind, occurredAt: value.occurredAt, sireID: value.sireID, semenName: value.semenNameSnapshot, result: value.result, lambCount: value.lambCount, parity: value.parity, birthDeadCount: value.birthDeadCount, offspring: [], note: value.note)))
            payload.optionalIdentifiers["semenID"] = value.semenID
            payload.optionalIdentifiers["batchID"] = value.batchID
            payload.optionalIdentifiers["relatedBreedingRecordID"] = value.relatedBreedingRecordID
            payload.optionalIdentifiers["semenDonorID"] = value.semenDonorID
            payload.optionalStrings["semenDonorNameSnapshot"] = value.semenDonorNameSnapshot
            payload.optionalStrings["semenDonorRegistrationNumberSnapshot"] = value.semenDonorRegistrationNumberSnapshot
            payload.optionalStrings["semenDonorBreedSnapshot"] = value.semenDonorBreedSnapshot
            payload.optionalStrings["paternalSource"] = value.paternalSourceRawValue
            payload.lambingOffspring = offspring.filter { $0.lambingRecordID == value.id }.map {
                .init(id: $0.id, sheepID: $0.sheepID, earTag: $0.legacyEarTag, sexRawValue: $0.sexRawValue, birthWeightText: $0.birthWeightText, isStillborn: $0.isStillborn, autoCreatedSheep: $0.autoCreatedSheep, autoBirthWeightRecordID: $0.autoBirthWeightRecordID, deletedByLambingRevocation: $0.deletedByLambingRevocation, revision: $0.revision, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt)
            }
            values.append((.reproduction, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 30))
        }
        for value in try context.fetch(FetchDescriptor<SemenRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            var payload = try decodePayload(FarmCommandCloudPayloadEncoder.encode(.addSemen(code: value.code, breed: value.breed, source: value.source, batchNumber: value.batchNumber, quantityText: value.quantityText)))
            payload.optionalIdentifiers["donorID"] = value.donorID
            values.append((.semen, value.id, value.revision, try JSONEncoder.cloud.encode(payload), 10))
        }
        for value in try context.fetch(FetchDescriptor<PedigreeChangeRecord>()).filter({ $0.farmID == farmID }) {
            let snapshot = CarePedigreeAuditSnapshot(id: value.id, sheepID: value.sheepID, beforeDamID: value.beforeDamID, afterDamID: value.afterDamID, beforeSireID: value.beforeSireID, afterSireID: value.afterSireID, beforeSemenDonorID: value.beforeSemenDonorID, afterSemenDonorID: value.afterSemenDonorID, beforeDamSourceRawValue: value.beforeDamSourceRawValue, afterDamSourceRawValue: value.afterDamSourceRawValue, beforeSireSourceRawValue: value.beforeSireSourceRawValue, afterSireSourceRawValue: value.afterSireSourceRawValue, reason: value.reason, changedByAccountID: value.changedByAccountID, sheepRevision: value.sheepRevision, occurredAt: value.occurredAt)
            values.append((.pedigreeChange, value.id, 1, try FarmCommandCloudPayloadEncoder.encode(.care(.restorePedigreeAudit(snapshot))), 35))
        }
        for value in try context.fetch(FetchDescriptor<NoteRecord>()).filter({ $0.farmID == farmID && $0.deletedAt == nil }) {
            values.append((.note, value.id, value.revision, try FarmCommandCloudPayloadEncoder.encode(.addNote(sheepID: value.sheepID, penID: value.penID, text: value.text, occurredAt: value.occurredAt)), 30))
        }
    }

    private func decodePayload(_ data: Data) throws -> FarmCommandCloudPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FarmCommandCloudPayload.self, from: data)
    }

    private static func assetURL(relativePath: String) -> URL {
        if relativePath.hasPrefix("/") { return URL(fileURLWithPath: relativePath) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: relativePath)
    }
}
