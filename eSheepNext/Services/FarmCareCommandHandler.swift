import Foundation
import SwiftData

struct CareApplyResult: Sendable {
    let entityType: CloudEntityType
    let entityID: UUID
    let baseRevision: Int
    let resultingRevision: Int
}

enum FarmCareCommandHandler {
    /// A compact checkpoint can already contain an entity at the operation's
    /// resulting revision while omitting the operation-specific pedigree
    /// audit, or (in older checkpoints) one of the resolved parent links.
    /// Repair only that narrow overlap. A local operation at the same
    /// resulting revision means this is a real divergence and must continue
    /// through the normal conflict path.
    static func repairRemotePedigreeCheckpointOverlapIfNeeded(
        _ command: CareCommand,
        farmID: UUID,
        resultingRevision: Int,
        accountID: UUID,
        modifiedAt: Date,
        context: ModelContext
    ) throws -> Bool {
        guard case .updateSheepPedigree(let draft) = command,
              resultingRevision == draft.expectedRevision + 1,
              let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                .first(where: {
                    $0.id == draft.sheepID &&
                        $0.farmID == farmID &&
                        $0.deletedAt == nil
                }),
              sheep.revision == resultingRevision else {
            return false
        }
        if try context.fetch(FetchDescriptor<PedigreeChangeRecord>())
            .contains(where: {
                $0.id == draft.id &&
                    $0.farmID == farmID &&
                    $0.sheepID == draft.sheepID
            }) {
            return false
        }
        if try context.fetch(FetchDescriptor<DomainOperation>())
            .contains(where: {
                $0.farmID == farmID &&
                    $0.entityID == draft.sheepID &&
                    $0.resultingRevision == resultingRevision
            }) {
            return false
        }

        let validationDraft = CarePedigreeUpdateDraft(
            id: draft.id,
            sheepID: draft.sheepID,
            damID: draft.damID,
            sireID: draft.sireID,
            semenDonorID: draft.semenDonorID,
            reason: draft.reason,
            expectedRevision: sheep.revision
        )
        try validatePedigree(
            validationDraft,
            farmID: farmID,
            context: context
        )
        let donor = try draft.semenDonorID.map {
            try semenDonor(
                $0,
                farmID: farmID,
                context: context,
                requiresActive: false
            )
        }
        let resolvedSireID = donor?.linkedRamID ?? draft.sireID
        context.insert(PedigreeChangeRecord(
            id: draft.id,
            farmID: farmID,
            sheepID: sheep.id,
            beforeDamID: sheep.damID,
            afterDamID: draft.damID,
            beforeSireID: sheep.sireID,
            afterSireID: resolvedSireID,
            beforeSemenDonorID: sheep.semenDonorID,
            afterSemenDonorID: donor?.id,
            beforeDamSourceRawValue: sheep.damProvenanceRawValue,
            afterDamSourceRawValue: draft.damID == nil
                ? nil
                : PedigreeRelationSource.manual.rawValue,
            beforeSireSourceRawValue: sheep.sireProvenanceRawValue,
            afterSireSourceRawValue: (resolvedSireID == nil && donor == nil)
                ? nil
                : PedigreeRelationSource.manual.rawValue,
            reason: draft.reason.trimmed,
            changedByAccountID: accountID,
            sheepRevision: resultingRevision,
            occurredAt: modifiedAt
        ))
        sheep.damID = draft.damID
        sheep.sireID = resolvedSireID
        sheep.damProvenanceRawValue = draft.damID == nil
            ? nil
            : PedigreeRelationSource.manual.rawValue
        sheep.sireProvenanceRawValue = (resolvedSireID == nil && donor == nil)
            ? nil
            : PedigreeRelationSource.manual.rawValue
        sheep.semenDonorID = donor?.id
        sheep.semenDonorNameSnapshot = donor?.name
        sheep.semenDonorRegistrationNumberSnapshot =
            donor?.registrationNumber.nilIfEmpty
        sheep.semenDonorBreedSnapshot = donor?.breed
        sheep.updatedAt = modifiedAt
        return true
    }

    static func isApplied(_ command: CareCommand, farmID: UUID, context: ModelContext) throws -> Bool {
        switch command {
        case .upsertHealthCatalog(let id, let kind, let name, let category, let unit, let dose, let route, let interval, let note, let active):
            return try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).contains { $0.id == id && $0.farmID == farmID && $0.kindRawValue == kind && $0.name == name.trimmed && $0.category == category.trimmed && $0.unit == unit.trimmed && $0.defaultDoseText == dose?.trimmed.nilIfEmpty && $0.defaultRoute == route.trimmed && $0.reminderIntervalDays == interval && $0.note == note.trimmed && $0.isActive == active }
        case .recordHealth(let draft), .correctHealth(_, let draft, _):
            return try context.fetch(FetchDescriptor<HealthRecord>()).contains { $0.id == draft.id && $0.farmID == farmID }
        case .receiveInventory(let id, _, _, _, _, _, _, _, _, _, _):
            return try context.fetch(FetchDescriptor<InventoryLotRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .adjustInventory(let id, _, _, _, _):
            return try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .setInventoryLotActive(let lotID, let active):
            return try context.fetch(FetchDescriptor<InventoryLotRecord>()).contains { $0.id == lotID && $0.farmID == farmID && $0.isActive == active }
        case .adjustSemen(let id, _, _, _, _):
            return try context.fetch(FetchDescriptor<SemenTransactionRecord>()).contains { $0.id == id && $0.farmID == farmID }
        case .upsertSemenDonor(let draft):
            return try context.fetch(FetchDescriptor<SemenDonorRecord>()).contains {
                $0.id == draft.id && $0.farmID == farmID && $0.name == draft.name.trimmed &&
                $0.registrationNumber == draft.registrationNumber.trimmed && $0.breed == draft.breed.trimmed &&
                $0.linkedRamID == draft.linkedRamID && $0.note == draft.note.trimmed && $0.status == draft.status
            }
        case .setSemenDonor(let semenID, let donorID, _):
            return try context.fetch(FetchDescriptor<SemenRecord>()).contains { $0.id == semenID && $0.farmID == farmID && $0.donorID == donorID }
        case .updateSheepPedigree(let draft):
            if try context.fetch(FetchDescriptor<PedigreeChangeRecord>()).contains(where: {
                $0.id == draft.id &&
                    $0.farmID == farmID &&
                    $0.sheepID == draft.sheepID
            }) {
                return true
            }
            guard let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
                .first(where: {
                    $0.id == draft.sheepID &&
                        $0.farmID == farmID &&
                        $0.deletedAt == nil
                }),
                  sheep.revision == draft.expectedRevision + 1,
                  sheep.damID == draft.damID,
                  sheep.semenDonorID == draft.semenDonorID else {
                return false
            }
            let expectedSireID: UUID?
            if let donorID = draft.semenDonorID {
                guard let donor = try context
                    .fetch(FetchDescriptor<SemenDonorRecord>())
                    .first(where: {
                        $0.id == donorID &&
                            $0.farmID == farmID &&
                            $0.deletedAt == nil
                    }) else {
                    return false
                }
                expectedSireID = donor.linkedRamID
            } else {
                expectedSireID = draft.sireID
            }
            return sheep.sireID == expectedSireID
        case .setBreedingRam(let sheepID, let active, let expectedRevision):
            return try context.fetch(FetchDescriptor<SheepRecord>()).contains {
                $0.id == sheepID &&
                    $0.farmID == farmID &&
                    $0.isBreedingRam == active &&
                    $0.revision == expectedRevision + 1
            }
        case .setSheepPurpose(let sheepID, let purpose, _, let expectedRevision):
            return try context.fetch(FetchDescriptor<SheepRecord>()).contains {
                $0.id == sheepID &&
                    $0.farmID == farmID &&
                    $0.purpose == purpose.rawValue &&
                    $0.isBreedingRam == (purpose == .breedingRam) &&
                    $0.revision == expectedRevision + 1
            }
        case .restorePedigreeAudit(let snapshot):
            return try context.fetch(FetchDescriptor<PedigreeChangeRecord>()).contains { $0.id == snapshot.id && $0.farmID == farmID }
        case .recordReproductionBatch(let draft), .correctReproduction(_, let draft, _):
            return try context.fetch(FetchDescriptor<CareBatchRecord>()).contains { $0.id == draft.id && $0.farmID == farmID }
        case .recordLambing(let draft):
            return try context.fetch(FetchDescriptor<ReproductionRecord>()).contains { $0.id == draft.id && $0.farmID == farmID }
        case .correctLambing(let originalID, let draft, _):
            return try lambingStateMatches(originalID: originalID, draft: draft, farmID: farmID, context: context)
        case .revokeLambing(let recordID, _):
            return try context.fetch(FetchDescriptor<ReproductionRecord>()).contains { $0.id == recordID && $0.farmID == farmID && $0.deletedAt != nil }
        case .restoreLambing(let recordID):
            return try context.fetch(FetchDescriptor<ReproductionRecord>()).contains { $0.id == recordID && $0.farmID == farmID && $0.deletedAt == nil && $0.revision > 1 }
        case .updateRules(let id, let checkDays, let gestationDays):
            return try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).contains { $0.id == id && $0.farmID == farmID && $0.pregnancyCheckDays == checkDays && $0.gestationDays == gestationDays }
        case .updateOperationalAlertRules(let draft):
            return try context.fetch(FetchDescriptor<FarmCareRuleRecord>()).contains {
                $0.id == draft.id && $0.farmID == farmID &&
                $0.pregnancyCheckDays == draft.pregnancyCheckDays &&
                $0.gestationDays == draft.gestationDays &&
                $0.weaningAgeDays == draft.weaningAgeDays &&
                $0.warningLeadDays == draft.effectiveWarningLeadDays &&
                $0.alertDigestEnabled == draft.digestEnabled &&
                $0.alertDigestMinuteOfDay == draft.digestMinuteOfDay &&
                $0.operationalAlertsConfiguredAt != nil
            }
        case .deferOperationalAlert(let draft):
            return try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).contains {
                $0.id == draft.id && $0.farmID == farmID &&
                $0.alertID == draft.alertID &&
                $0.conditionFingerprint == draft.conditionFingerprint &&
                $0.deferredUntil == draft.deferredUntil
            }
        case .setReminderStatus(let reminderID, let status):
            return try context.fetch(FetchDescriptor<CareReminderRecord>()).contains { $0.id == reminderID && $0.farmID == farmID && $0.statusRawValue == status.rawValue }
        }
    }

    static func validate(
        _ command: CareCommand,
        farmID: UUID,
        context: ModelContext,
        pedigreeSheepByID: [UUID: SheepRecord]? = nil
    ) throws {
        switch command {
        case .upsertHealthCatalog(_, let kindRawValue, let name, _, let unit, let dose, _, let interval, _, _):
            guard HealthRecordKind(rawValue: kindRawValue) != nil else { throw FarmCommandError.missingRequiredValue("健康目录类型") }
            try require(name, "目录名称")
            try require(unit, "计量单位")
            if let dose, !dose.isEmpty { _ = try positive(dose, "默认剂量") }
            if let interval { guard (1...3650).contains(interval) else { throw FarmCommandError.invalidNumber("复免间隔") } }

        case .recordHealth(let draft):
            try validateHealth(draft, farmID: farmID, inventoryCreditSourceID: nil, context: context)

        case .correctHealth(let originalID, let replacement, let reason):
            guard let original = try context.fetch(FetchDescriptor<HealthRecord>()).first(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try require(reason, "修正原因")
            try validateHealth(replacement, farmID: farmID, inventoryCreditSourceID: original.id, context: context)

        case .receiveInventory(_, let catalogName, let catalogItemID, let kindRawValue, _, _, let unit, _, let quantityText, _, _):
            try require(catalogName, "库存名称")
            try require(unit, "库存单位")
            guard HealthRecordKind(rawValue: kindRawValue) != nil else { throw FarmCommandError.missingRequiredValue("库存类型") }
            _ = try positive(quantityText, "入库数量")
            if let catalogItemID {
                guard try context.fetch(FetchDescriptor<HealthCatalogItemRecord>()).contains(where: { $0.id == catalogItemID && $0.farmID == farmID }) else { throw FarmCommandError.missingRequiredValue("健康目录") }
            }

        case .adjustInventory(_, let lotID, let deltaText, _, _):
            let lot = try inventoryLot(lotID, farmID: farmID, context: context, requiresActive: false)
            guard let delta = Decimal.stable(deltaText), delta != 0 else { throw FarmCommandError.invalidNumber("调整数量") }
            guard try inventoryBalance(lot, context: context) + delta >= 0 else { throw FarmCommandError.insufficientInventory }

        case .setInventoryLotActive(let lotID, _):
            _ = try inventoryLot(lotID, farmID: farmID, context: context, requiresActive: false)

        case .adjustSemen(_, let semenID, let deltaText, _, _):
            let semen = try semen(semenID, farmID: farmID, context: context)
            guard let delta = Decimal.stable(deltaText), delta != 0 else { throw FarmCommandError.invalidNumber("调整数量") }
            guard try semenBalance(semen, context: context) + delta >= 0 else { throw FarmCommandError.insufficientInventory }

        case .upsertSemenDonor(let draft):
            try validateSemenDonor(draft, farmID: farmID, context: context)

        case .setSemenDonor(let semenID, let donorID, let expectedRevision):
            let record = try semen(semenID, farmID: farmID, context: context)
            guard record.revision == expectedRevision else { throw FarmCommandError.pedigreeRevisionConflict }
            if let donorID { _ = try semenDonor(donorID, farmID: farmID, context: context, requiresActive: false) }

        case .updateSheepPedigree(let draft):
            try validatePedigree(
                draft,
                farmID: farmID,
                context: context,
                sheepByID: pedigreeSheepByID
            )

        case .setBreedingRam(let sheepID, let active, let expectedRevision):
            let sheep = try pedigreeSheepByID?[sheepID] ?? context.fetch(
                FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
                })
            ).first
            guard let sheep else { throw FarmCommandError.sheepNotFound }
            guard sheep.revision == expectedRevision else { throw FarmCommandError.pedigreeRevisionConflict }
            if active, sheep.sex != .ram { throw FarmCommandError.reproductionSireMustBeRam }

        case .setSheepPurpose(let sheepID, let purpose, let reason, let expectedRevision):
            let sheep = try context.fetch(
                FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
                })
            ).first
            guard let sheep else { throw FarmCommandError.sheepNotFound }
            guard sheep.revision == expectedRevision else { throw FarmCommandError.pedigreeRevisionConflict }
            guard purpose.isAllowed(for: sheep.sex) else {
                throw purpose == .breedingRam
                    ? FarmCommandError.reproductionSireMustBeRam
                    : FarmCommandError.missingRequiredValue("与羊只性别匹配的用途")
            }
            try require(reason, "用途变更原因")

        case .restorePedigreeAudit(let snapshot):
            let sheepIDs = Set(try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }.map(\.id))
            guard sheepIDs.contains(snapshot.sheepID) else { throw FarmCommandError.sheepNotFound }
            for id in [snapshot.beforeDamID, snapshot.afterDamID, snapshot.beforeSireID, snapshot.afterSireID].compactMap({ $0 }) where !sheepIDs.contains(id) { throw FarmCommandError.sheepNotFound }
            let donorIDs = Set(try context.fetch(FetchDescriptor<SemenDonorRecord>()).filter { $0.farmID == farmID }.map(\.id))
            for id in [snapshot.beforeSemenDonorID, snapshot.afterSemenDonorID].compactMap({ $0 }) where !donorIDs.contains(id) { throw FarmCommandError.semenDonorNotFound }

        case .recordReproductionBatch(let draft):
            try validateReproductionBatch(draft, farmID: farmID, semenCreditSourceID: nil, context: context)

        case .recordLambing(let draft):
            try validateLambing(draft, farmID: farmID, existingRecordID: nil, context: context)

        case .correctReproduction(let originalID, let replacement, let reason):
            guard try context.fetch(FetchDescriptor<ReproductionRecord>()).contains(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try require(reason, "修正原因")
            try validateReproductionBatch(replacement, farmID: farmID, semenCreditSourceID: originalID, context: context)

        case .correctLambing(let originalID, let replacement, let reason):
            guard replacement.id == originalID,
                  let original = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: { $0.id == originalID && $0.farmID == farmID && $0.kind == .lambing && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try require(reason, "修正原因")
            try validateLambing(replacement, farmID: farmID, existingRecordID: original.id, context: context)

        case .revokeLambing(let recordID, let reason):
            guard try context.fetch(FetchDescriptor<ReproductionRecord>()).contains(where: { $0.id == recordID && $0.farmID == farmID && $0.kind == .lambing && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try require(reason, "撤销原因")

        case .restoreLambing(let recordID):
            guard try context.fetch(FetchDescriptor<ReproductionRecord>()).contains(where: { $0.id == recordID && $0.farmID == farmID && $0.kind == .lambing && $0.deletedAt != nil }) else { throw FarmCommandError.sourceRecordNotFound }

        case .updateRules(_, let checkDays, let gestationDays):
            guard (1...365).contains(checkDays), (100...220).contains(gestationDays) else { throw FarmCommandError.invalidNumber("提醒间隔") }

        case .updateOperationalAlertRules(let draft):
            guard (1...365).contains(draft.pregnancyCheckDays),
                  (100...220).contains(draft.gestationDays),
                  (1...365).contains(draft.weaningAgeDays),
                  (0...30).contains(draft.effectiveWarningLeadDays),
                  (0...1_439).contains(draft.digestMinuteOfDay) else {
                throw FarmCommandError.invalidNumber("待办与异常规则")
            }

        case .deferOperationalAlert(let draft):
            guard FarmOperationalAlertKind(rawValue: draft.alertKindRawValue) != nil,
                  !draft.conditionFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FarmCommandError.missingRequiredValue("异常提醒")
            }

        case .setReminderStatus(let reminderID, _):
            guard try context.fetch(FetchDescriptor<CareReminderRecord>()).contains(where: { $0.id == reminderID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
        }
    }

    static func validateAndApply(
        _ command: CareCommand,
        farmID: UUID,
        accountID: UUID,
        context: ModelContext,
        modifiedAt: Date = .now,
        pedigreeSheepByID: [UUID: SheepRecord]? = nil
    ) throws -> CareApplyResult {
        switch command {
        case .recordHealth(let draft):
            let subjects = try healthSubjects(draft, farmID: farmID, context: context)
            try validateHealth(
                draft,
                subjects: subjects,
                farmID: farmID,
                inventoryCreditSourceID: nil,
                context: context
            )
            return try applyHealth(draft, subjects: subjects, farmID: farmID, context: context)

        case .correctHealth(let originalID, let replacement, let reason):
            let descriptor = FetchDescriptor<HealthRecord>(predicate: #Predicate {
                $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil
            })
            guard let original = try context.fetch(descriptor).first else {
                throw FarmCommandError.sourceRecordNotFound
            }
            try require(reason, "修正原因")
            let subjects = try healthSubjects(replacement, farmID: farmID, context: context)
            try validateHealth(
                replacement,
                subjects: subjects,
                farmID: farmID,
                inventoryCreditSourceID: original.id,
                context: context
            )
            return try applyHealthCorrection(
                original: original,
                replacement: replacement,
                subjects: subjects,
                reason: reason,
                accountID: accountID,
                farmID: farmID,
                context: context,
                modifiedAt: modifiedAt
            )

        default:
            try validate(
                command,
                farmID: farmID,
                context: context,
                pedigreeSheepByID: pedigreeSheepByID
            )
            return try apply(
                command,
                farmID: farmID,
                accountID: accountID,
                context: context,
                modifiedAt: modifiedAt,
                pedigreeSheepByID: pedigreeSheepByID
            )
        }
    }

    static func apply(
        _ command: CareCommand,
        farmID: UUID,
        accountID: UUID,
        context: ModelContext,
        modifiedAt: Date = .now,
        pedigreeSheepByID: [UUID: SheepRecord]? = nil
    ) throws -> CareApplyResult {
        switch command {
        case .upsertHealthCatalog(let id, let kindRawValue, let name, let category, let unit, let dose, let route, let interval, let note, let isActive):
            let records = try context.fetch(FetchDescriptor<HealthCatalogItemRecord>())
            if let record = records.first(where: { $0.id == id && $0.farmID == farmID }) {
                record.kindRawValue = kindRawValue; record.name = name.trimmed; record.category = category.trimmed
                record.unit = unit.trimmed; record.defaultDoseText = dose?.trimmed.nilIfEmpty; record.defaultRoute = route.trimmed
                record.reminderIntervalDays = interval; record.note = note.trimmed; record.isActive = isActive
                return CareApplyResult(entityType: .healthCatalogItem, entityID: id, baseRevision: 1, resultingRevision: 2)
            }
            context.insert(HealthCatalogItemRecord(id: id, farmID: farmID, legacySourceKey: "", legacyCatalogID: "", kindRawValue: kindRawValue, name: name.trimmed, category: category.trimmed, unit: unit.trimmed, defaultDoseText: dose?.trimmed.nilIfEmpty, defaultRoute: route.trimmed, reminderIntervalDays: interval, note: note.trimmed, isActive: isActive))
            return CareApplyResult(entityType: .healthCatalogItem, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .recordHealth(let draft):
            return try applyHealth(draft, farmID: farmID, context: context)

        case .correctHealth(let originalID, let replacement, let reason):
            let descriptor = FetchDescriptor<HealthRecord>(predicate: #Predicate {
                $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil
            })
            guard let original = try context.fetch(descriptor).first else {
                throw FarmCommandError.sourceRecordNotFound
            }
            let subjects = try healthSubjects(replacement, farmID: farmID, context: context)
            return try applyHealthCorrection(
                original: original,
                replacement: replacement,
                subjects: subjects,
                reason: reason,
                accountID: accountID,
                farmID: farmID,
                context: context,
                modifiedAt: modifiedAt
            )

        case .receiveInventory(let id, let catalogName, let catalogItemID, let kindRawValue, let batchNumber, let supplier, let unit, let expiresAt, let quantityText, let occurredAt, let note):
            let quantity = Decimal.stable(quantityText) ?? 0
            let lot = InventoryLotRecord(id: id, farmID: farmID, catalogName: catalogName.trimmed, catalogItemID: catalogItemID, kind: HealthRecordKind(rawValue: kindRawValue) ?? .treatment, expiresAt: expiresAt, startingQuantityText: quantity.stableText, batchNumber: batchNumber.trimmed, supplier: supplier.trimmed, receivedAt: occurredAt, unit: unit.trimmed)
            context.insert(lot)
            context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: id, name: "inventory-receipt"), farmID: farmID, inventoryLotID: id, kind: .receipt, quantityText: quantity.stableText, occurredAt: occurredAt, sourceRecordID: id, note: note.trimmed))
            refreshInventoryExpiryReminder(for: lot, context: context)
            return .init(entityType: .inventoryLot, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .adjustInventory(let id, let lotID, let deltaText, let occurredAt, let note):
            if try context.fetch(FetchDescriptor<InventoryTransactionRecord>()).contains(where: { $0.id == id && $0.farmID == farmID }) { return .init(entityType: .inventoryTransaction, entityID: id, baseRevision: 0, resultingRevision: 1) }
            context.insert(InventoryTransactionRecord(id: id, farmID: farmID, inventoryLotID: lotID, kind: .adjustment, quantityText: Decimal.stable(deltaText)!.stableText, occurredAt: occurredAt, note: note.trimmed))
            return .init(entityType: .inventoryTransaction, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .setInventoryLotActive(let lotID, let isActive):
            let lot = try inventoryLot(lotID, farmID: farmID, context: context, requiresActive: false)
            lot.isActive = isActive
            return .init(entityType: .inventoryLot, entityID: lotID, baseRevision: 1, resultingRevision: 2)

        case .adjustSemen(let id, let semenID, let deltaText, let occurredAt, let note):
            if try context.fetch(FetchDescriptor<SemenTransactionRecord>()).contains(where: { $0.id == id && $0.farmID == farmID }) { return .init(entityType: .semenTransaction, entityID: id, baseRevision: 0, resultingRevision: 1) }
            context.insert(SemenTransactionRecord(id: id, farmID: farmID, semenID: semenID, kind: .adjustment, quantityText: Decimal.stable(deltaText)!.stableText, occurredAt: occurredAt, note: note.trimmed))
            return .init(entityType: .semenTransaction, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .upsertSemenDonor(let draft):
            let records = try context.fetch(FetchDescriptor<SemenDonorRecord>())
            if let record = records.first(where: { $0.id == draft.id && $0.farmID == farmID }) {
                let base = record.revision
                record.name = draft.name.trimmed
                record.registrationNumber = draft.registrationNumber.trimmed
                record.breed = draft.breed.trimmed
                record.linkedRamID = draft.linkedRamID
                record.note = draft.note.trimmed
                record.statusRawValue = draft.status.rawValue
                record.updatedAt = modifiedAt
                record.deletedAt = nil
                record.revision += 1
                return .init(entityType: .semenDonor, entityID: record.id, baseRevision: base, resultingRevision: record.revision)
            }
            context.insert(SemenDonorRecord(id: draft.id, farmID: farmID, name: draft.name.trimmed, registrationNumber: draft.registrationNumber.trimmed, breed: draft.breed.trimmed, linkedRamID: draft.linkedRamID, note: draft.note.trimmed, status: draft.status, createdAt: modifiedAt, updatedAt: modifiedAt))
            return .init(entityType: .semenDonor, entityID: draft.id, baseRevision: 0, resultingRevision: 1)

        case .setSemenDonor(let semenID, let donorID, _):
            let record = try semen(semenID, farmID: farmID, context: context)
            let base = record.revision
            record.donorID = donorID
            record.updatedAt = modifiedAt
            record.revision += 1
            return .init(entityType: .semen, entityID: record.id, baseRevision: base, resultingRevision: record.revision)

        case .updateSheepPedigree(let draft):
            let sheep = try pedigreeSheepByID?[draft.sheepID] ?? context.fetch(
                FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.id == draft.sheepID && $0.farmID == farmID && $0.deletedAt == nil
                })
            ).first
            guard let sheep else { throw FarmCommandError.sheepNotFound }
            let donor = try draft.semenDonorID.map { try semenDonor($0, farmID: farmID, context: context, requiresActive: false) }
            let resolvedSireID = donor?.linkedRamID ?? draft.sireID
            let base = sheep.revision
            context.insert(PedigreeChangeRecord(
                id: draft.id,
                farmID: farmID,
                sheepID: sheep.id,
                beforeDamID: sheep.damID,
                afterDamID: draft.damID,
                beforeSireID: sheep.sireID,
                afterSireID: resolvedSireID,
                beforeSemenDonorID: sheep.semenDonorID,
                afterSemenDonorID: donor?.id,
                beforeDamSourceRawValue: sheep.damProvenanceRawValue,
                afterDamSourceRawValue: draft.damID == nil ? nil : PedigreeRelationSource.manual.rawValue,
                beforeSireSourceRawValue: sheep.sireProvenanceRawValue,
                afterSireSourceRawValue: (resolvedSireID == nil && donor == nil) ? nil : PedigreeRelationSource.manual.rawValue,
                reason: draft.reason.trimmed,
                changedByAccountID: accountID,
                sheepRevision: base + 1,
                occurredAt: modifiedAt
            ))
            sheep.damID = draft.damID
            sheep.sireID = resolvedSireID
            sheep.damProvenanceRawValue = draft.damID == nil ? nil : PedigreeRelationSource.manual.rawValue
            sheep.sireProvenanceRawValue = (resolvedSireID == nil && donor == nil) ? nil : PedigreeRelationSource.manual.rawValue
            sheep.semenDonorID = donor?.id
            sheep.semenDonorNameSnapshot = donor?.name
            sheep.semenDonorRegistrationNumberSnapshot = donor?.registrationNumber.nilIfEmpty
            sheep.semenDonorBreedSnapshot = donor?.breed
            sheep.updatedAt = modifiedAt
            sheep.revision += 1
            return .init(entityType: .sheep, entityID: sheep.id, baseRevision: base, resultingRevision: sheep.revision)

        case .setBreedingRam(let sheepID, let active, _):
            let sheep = try pedigreeSheepByID?[sheepID] ?? context.fetch(
                FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
                })
            ).first
            guard let sheep else { throw FarmCommandError.sheepNotFound }
            let base = sheep.revision
            sheep.isBreedingRam = active
            sheep.updatedAt = modifiedAt
            sheep.revision += 1
            return .init(entityType: .sheep, entityID: sheep.id, baseRevision: base, resultingRevision: sheep.revision)

        case .setSheepPurpose(let sheepID, let purpose, _, _):
            let sheep = try context.fetch(
                FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
                })
            ).first
            guard let sheep else { throw FarmCommandError.sheepNotFound }
            let base = sheep.revision
            sheep.purpose = purpose.rawValue
            sheep.isBreedingRam = purpose == .breedingRam
            sheep.updatedAt = modifiedAt
            sheep.revision += 1
            return .init(entityType: .sheep, entityID: sheep.id, baseRevision: base, resultingRevision: sheep.revision)

        case .restorePedigreeAudit(let snapshot):
            if try context.fetch(FetchDescriptor<PedigreeChangeRecord>()).contains(where: { $0.id == snapshot.id && $0.farmID == farmID }) {
                return .init(entityType: .pedigreeChange, entityID: snapshot.id, baseRevision: 0, resultingRevision: 1)
            }
            context.insert(PedigreeChangeRecord(id: snapshot.id, farmID: farmID, sheepID: snapshot.sheepID, beforeDamID: snapshot.beforeDamID, afterDamID: snapshot.afterDamID, beforeSireID: snapshot.beforeSireID, afterSireID: snapshot.afterSireID, beforeSemenDonorID: snapshot.beforeSemenDonorID, afterSemenDonorID: snapshot.afterSemenDonorID, beforeDamSourceRawValue: snapshot.beforeDamSourceRawValue, afterDamSourceRawValue: snapshot.afterDamSourceRawValue, beforeSireSourceRawValue: snapshot.beforeSireSourceRawValue, afterSireSourceRawValue: snapshot.afterSireSourceRawValue, reason: snapshot.reason, changedByAccountID: snapshot.changedByAccountID, sheepRevision: snapshot.sheepRevision, occurredAt: snapshot.occurredAt))
            return .init(entityType: .pedigreeChange, entityID: snapshot.id, baseRevision: 0, resultingRevision: 1)

        case .recordReproductionBatch(let draft):
            if try context.fetch(FetchDescriptor<CareBatchRecord>()).contains(where: { $0.id == draft.id && $0.farmID == farmID }) { return .init(entityType: .careBatch, entityID: draft.id, baseRevision: 0, resultingRevision: 1) }
            let batchKind: CareBatchKind
            switch draft.kind { case .breeding: batchKind = .breeding; case .pregnancyCheck: batchKind = .pregnancyCheck; case .abortion: batchKind = .abortion; case .parityBaseline, .lambing: throw FarmCommandError.invalidReproductionRecord }
            context.insert(CareBatchRecord(id: draft.id, farmID: farmID, kind: batchKind, occurredAt: draft.occurredAt, note: draft.note.trimmed))
            let paternity = draft.kind == .breeding
                ? try resolvePaternity(sireID: draft.sireID, semenID: draft.semenID, farmID: farmID, context: context)
                : ResolvedPaternity.unknown
            let semenRecord = paternity.semen
            let semenPerEwe = draft.semenID == nil ? nil : (Decimal.stable(draft.semenUnitsPerEweText ?? "1") ?? 1)
            for subject in draft.subjects {
                let recordID = StableCloudUUID.derived(namespace: draft.id, name: subject.id.uuidString.lowercased())
                context.insert(ReproductionRecord(id: recordID, farmID: farmID, eweID: subject.eweID, kind: draft.kind, occurredAt: draft.occurredAt, sireID: paternity.sireID, semenID: semenRecord?.id, batchID: draft.id, relatedBreedingRecordID: subject.relatedBreedingRecordID, semenNameSnapshot: semenRecord?.code, semenDonorID: paternity.donorID, semenDonorNameSnapshot: paternity.donorNameSnapshot, semenDonorRegistrationNumberSnapshot: paternity.donorRegistrationNumberSnapshot, semenDonorBreedSnapshot: paternity.donorBreedSnapshot, paternalSource: paternity.source, result: subject.result.trimmed, note: draft.note.trimmed))
                if let reminderAt = draft.reminderAt, draft.kind != .abortion {
                    let reminderKind: CareReminderKind = draft.kind == .breeding ? .pregnancyCheck : .expectedLambing
                    insertReminder(farmID: farmID, kind: reminderKind, sourceType: CloudEntityType.reproduction.rawValue, sourceID: recordID, sheepID: subject.eweID, dueAt: reminderAt, title: "\(subject.result.isEmpty ? "母羊" : subject.result) · \(reminderKind.displayName)", context: context)
                }
                if let semenID = draft.semenID, let semenPerEwe {
                    context.insert(SemenTransactionRecord(id: StableCloudUUID.derived(namespace: recordID, name: "semen-consumption"), farmID: farmID, semenID: semenID, kind: .consumption, quantityText: semenPerEwe.stableText, occurredAt: draft.occurredAt, sourceRecordID: recordID, note: "配种批次 \(draft.id.uuidString.lowercased())"))
                }
                if draft.kind == .abortion {
                    deleteExpectedLambingReminders(eweID: subject.eweID, farmID: farmID, at: modifiedAt, context: context)
                }
            }
            return .init(entityType: .careBatch, entityID: draft.id, baseRevision: 0, resultingRevision: 1)

        case .recordLambing(let draft):
            if try context.fetch(FetchDescriptor<ReproductionRecord>()).contains(where: { $0.id == draft.id && $0.farmID == farmID }) { return .init(entityType: .reproduction, entityID: draft.id, baseRevision: 0, resultingRevision: 1) }
            let paternity = try resolveLambingPaternity(draft, farmID: farmID, context: context)
            let reproduction = ReproductionRecord(id: draft.id, farmID: farmID, eweID: draft.eweID, kind: .lambing, occurredAt: draft.occurredAt, sireID: paternity.sireID, semenID: paternity.semen?.id, relatedBreedingRecordID: draft.relatedBreedingRecordID, semenNameSnapshot: paternity.semen?.code, semenDonorID: paternity.donorID, semenDonorNameSnapshot: paternity.donorNameSnapshot, semenDonorRegistrationNumberSnapshot: paternity.donorRegistrationNumberSnapshot, semenDonorBreedSnapshot: paternity.donorBreedSnapshot, paternalSource: paternity.source, lambCount: draft.offspring.count, parity: draft.parity, birthDeadCount: draft.birthDeadCount, note: draft.note.trimmed)
            context.insert(reproduction)
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            let ewe = sheep.first(where: { $0.id == draft.eweID && $0.farmID == farmID })
            let paternalBreed = resolvedPaternalBreed(paternity, sheep: sheep)
            for lamb in draft.offspring {
                let weightFact = lambWeightFact(lamb, lambingAt: draft.occurredAt)
                let autoWeightID = weightFact.map { newAutoWeightRecordID(for: lamb, fact: $0) }
                if lamb.createSheepRecord {
                    context.insert(SheepRecord(id: lamb.sheepID, farmID: farmID, earTag: lamb.earTag.trimmed, breed: resolvedLambBreed(lamb, paternalBreed: paternalBreed, maternalBreed: ewe?.breed), sex: lamb.sex, penID: draft.penID, enteredAt: draft.occurredAt, birthAt: draft.occurredAt, damID: draft.eweID, sireID: paternity.sireID, damProvenance: .lambing, sireProvenance: paternity.source == .unknown ? nil : .lambing, semenDonorID: paternity.donorID, semenDonorNameSnapshot: paternity.donorNameSnapshot, semenDonorRegistrationNumberSnapshot: paternity.donorRegistrationNumberSnapshot, semenDonorBreedSnapshot: paternity.donorBreedSnapshot, note: "由产羔记录自动建档"))
                    if let weightFact, let autoWeightID {
                        context.insert(WeightRecord(id: autoWeightID, farmID: farmID, sheepID: lamb.sheepID, kilogramsText: weightFact.kilogramsText, occurredAt: weightFact.occurredAt, note: weightFact.note))
                    }
                }
                context.insert(LambingOffspringRecord(id: lamb.id, farmID: farmID, lambingRecordID: draft.id, sheepID: lamb.createSheepRecord ? lamb.sheepID : nil, legacyEarTag: lamb.earTag.trimmed, sexRawValue: lamb.sex.rawValue, birthWeightText: weightFact?.birthWeightText ?? "", isStillborn: lamb.isStillborn, autoCreatedSheep: lamb.createSheepRecord, autoBirthWeightRecordID: lamb.createSheepRecord ? autoWeightID : nil))
            }
            deleteExpectedLambingReminders(eweID: draft.eweID, farmID: farmID, at: modifiedAt, context: context)
            return .init(entityType: .reproduction, entityID: draft.id, baseRevision: 0, resultingRevision: 1)

        case .correctReproduction(let originalID, let replacement, let reason):
            guard let original = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: { $0.id == originalID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            try DomainEntityDeletionService.setDeletedAt(modifiedAt, type: .reproduction, id: original.id, farmID: farmID, context: context)
            context.insert(TombstoneRecord(farmID: farmID, entityType: CloudEntityType.reproduction.rawValue, entityID: originalID, deletedByAccountID: accountID, reason: "修正：\(reason.trimmed)"))
            let result = try apply(.recordReproductionBatch(replacement), farmID: farmID, accountID: accountID, context: context, modifiedAt: modifiedAt)
            return .init(entityType: result.entityType, entityID: result.entityID, baseRevision: 1, resultingRevision: 2)

        case .correctLambing(let originalID, let replacement, let reason):
            return try applyLambingCorrection(originalID: originalID, replacement: replacement, reason: reason.trimmed, accountID: accountID, farmID: farmID, context: context, modifiedAt: modifiedAt)

        case .revokeLambing(let recordID, let reason):
            return try setLambingRevoked(true, recordID: recordID, reason: reason.trimmed, accountID: accountID, farmID: farmID, context: context, modifiedAt: modifiedAt)

        case .restoreLambing(let recordID):
            return try setLambingRevoked(false, recordID: recordID, reason: "恢复产羔记录", accountID: accountID, farmID: farmID, context: context, modifiedAt: modifiedAt)

        case .updateRules(let id, let pregnancyCheckDays, let gestationDays):
            let rules = try context.fetch(FetchDescriptor<FarmCareRuleRecord>())
            if let record = rules.first(where: { $0.farmID == farmID }) {
                let base = record.revision
                record.pregnancyCheckDays = pregnancyCheckDays; record.gestationDays = gestationDays; record.updatedAt = modifiedAt; record.revision += 1
                return .init(entityType: .careRule, entityID: record.id, baseRevision: base, resultingRevision: record.revision)
            }
            context.insert(FarmCareRuleRecord(id: id, farmID: farmID, pregnancyCheckDays: pregnancyCheckDays, gestationDays: gestationDays))
            return .init(entityType: .careRule, entityID: id, baseRevision: 0, resultingRevision: 1)

        case .updateOperationalAlertRules(let draft):
            let rules = try context.fetch(FetchDescriptor<FarmCareRuleRecord>())
            if let record = rules.first(where: { $0.farmID == farmID }) {
                let base = record.revision
                record.pregnancyCheckDays = draft.pregnancyCheckDays
                record.gestationDays = draft.gestationDays
                record.weaningAgeDays = draft.weaningAgeDays
                record.warningLeadDays = draft.effectiveWarningLeadDays
                record.operationalAlertsConfiguredAt = record.operationalAlertsConfiguredAt ?? modifiedAt
                record.alertDigestEnabled = draft.digestEnabled
                record.alertDigestMinuteOfDay = draft.digestMinuteOfDay
                record.updatedAt = modifiedAt
                record.revision += 1
                return .init(entityType: .careRule, entityID: record.id, baseRevision: base, resultingRevision: record.revision)
            }
            context.insert(FarmCareRuleRecord(
                id: draft.id,
                farmID: farmID,
                pregnancyCheckDays: draft.pregnancyCheckDays,
                gestationDays: draft.gestationDays,
                weaningAgeDays: draft.weaningAgeDays,
                warningLeadDays: draft.effectiveWarningLeadDays,
                operationalAlertsConfiguredAt: modifiedAt,
                alertDigestEnabled: draft.digestEnabled,
                alertDigestMinuteOfDay: draft.digestMinuteOfDay
            ))
            return .init(entityType: .careRule, entityID: draft.id, baseRevision: 0, resultingRevision: 1)

        case .deferOperationalAlert(let draft):
            if let record = try context.fetch(FetchDescriptor<FarmAlertDeferralRecord>()).first(where: {
                $0.id == draft.id && $0.farmID == farmID
            }) {
                let base = record.revision
                record.alertID = draft.alertID
                record.alertKindRawValue = draft.alertKindRawValue
                record.subjectID = draft.subjectID
                record.sourceEntityID = draft.sourceEntityID
                record.conditionFingerprint = draft.conditionFingerprint
                record.deferredUntil = draft.deferredUntil
                record.deferredByAccountID = accountID
                record.updatedAt = modifiedAt
                record.revision += 1
                return .init(entityType: .alertDeferral, entityID: record.id, baseRevision: base, resultingRevision: record.revision)
            }
            context.insert(FarmAlertDeferralRecord(
                id: draft.id,
                farmID: farmID,
                alertID: draft.alertID,
                alertKindRawValue: draft.alertKindRawValue,
                subjectID: draft.subjectID,
                sourceEntityID: draft.sourceEntityID,
                conditionFingerprint: draft.conditionFingerprint,
                deferredUntil: draft.deferredUntil,
                deferredByAccountID: accountID,
                createdAt: modifiedAt
            ))
            return .init(entityType: .alertDeferral, entityID: draft.id, baseRevision: 0, resultingRevision: 1)

        case .setReminderStatus(let reminderID, let status):
            guard let reminder = try context.fetch(FetchDescriptor<CareReminderRecord>()).first(where: { $0.id == reminderID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
            let base = reminder.revision
            reminder.statusRawValue = status.rawValue; reminder.completedAt = status == .completed ? modifiedAt : nil; reminder.revision += 1
            return .init(entityType: .careReminder, entityID: reminderID, baseRevision: base, resultingRevision: reminder.revision)
        }
    }

    static func refreshInventoryExpiryReminder(for lot: InventoryLotRecord, context: ModelContext) {
        guard let dueAt = lot.expiresAt else { return }
        insertReminder(farmID: lot.farmID, kind: .inventoryExpiry, sourceType: CloudEntityType.inventoryLot.rawValue, sourceID: lot.id, inventoryLotID: lot.id, dueAt: dueAt, title: "\(lot.catalogName)即将到期", context: context)
    }

    static func inventoryBalance(_ lot: InventoryLotRecord, context: ModelContext) throws -> Decimal {
        let farmID = lot.farmID
        let lotID = lot.id
        let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.inventoryLotID == lotID && $0.deletedAt == nil
        }))
        return transactions.reduce(0) { partial, transaction in
            switch transaction.kind { case .receipt, .adjustment: partial + transaction.quantity; case .consumption: partial - transaction.quantity }
        }
    }

    static func semenBalance(_ semen: SemenRecord, context: ModelContext) throws -> Decimal {
        let initial = Decimal.stable(semen.quantityText) ?? 0
        let farmID = semen.farmID
        let semenID = semen.id
        let transactions = try context.fetch(FetchDescriptor<SemenTransactionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.semenID == semenID && $0.deletedAt == nil
        }))
        return transactions.reduce(initial) { partial, transaction in
            switch transaction.kind { case .receipt, .adjustment: partial + transaction.quantity; case .consumption: partial - transaction.quantity }
        }
    }

    private static func lambingStateMatches(originalID: UUID, draft: CareLambingDraft, farmID: UUID, context: ModelContext) throws -> Bool {
        guard let record = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: {
            $0.id == originalID && $0.farmID == farmID && $0.kind == .lambing && $0.deletedAt == nil
        }),
        record.eweID == draft.eweID,
        record.occurredAt == draft.occurredAt,
        record.relatedBreedingRecordID == draft.relatedBreedingRecordID,
        record.parity == draft.parity,
        record.birthDeadCount == draft.birthDeadCount,
        record.lambCount == draft.offspring.count,
        record.note == draft.note.trimmed else { return false }

        if let sireID = draft.sireID {
            guard record.sireID == sireID, record.semenID == nil, record.semenDonorID == nil else { return false }
        } else if let semenID = draft.semenID {
            guard record.semenID == semenID else { return false }
        } else if draft.relatedBreedingRecordID == nil {
            guard record.sireID == nil, record.semenID == nil, record.semenDonorID == nil else { return false }
        }

        let details = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter {
            $0.farmID == farmID && $0.lambingRecordID == originalID && $0.deletedAt == nil
        }
        guard details.count == draft.offspring.count else { return false }
        let detailByID = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        let weights = try context.fetch(FetchDescriptor<WeightRecord>())
        for lamb in draft.offspring {
            let weightFact = lambWeightFact(lamb, lambingAt: draft.occurredAt)
            guard let detail = detailByID[lamb.id],
                  detail.sheepID == (lamb.createSheepRecord ? lamb.sheepID : nil),
                  EarTag.normalized(detail.legacyEarTag) == EarTag.normalized(lamb.earTag),
                  detail.sexRawValue == lamb.sex.rawValue,
                  detail.birthWeightText == (weightFact?.birthWeightText ?? ""),
                  detail.isStillborn == lamb.isStillborn,
                  detail.autoCreatedSheep == lamb.createSheepRecord else { return false }
            if lamb.createSheepRecord {
                guard let child = sheep.first(where: { $0.id == lamb.sheepID && $0.farmID == farmID && $0.deletedAt == nil }),
                      EarTag.normalized(child.earTag) == EarTag.normalized(lamb.earTag),
                      child.sex == lamb.sex,
                      child.birthAt == draft.occurredAt,
                      child.initialPenID == draft.penID,
                      child.damID == draft.eweID,
                      child.sireID == record.sireID,
                      child.semenDonorID == record.semenDonorID else { return false }
                if let requestedBreed = lamb.breed,
                   child.breed != requestedBreed.trimmed {
                    return false
                }
                let linkedWeight = detail.autoBirthWeightRecordID.flatMap { weightID in
                    weights.first { $0.id == weightID && $0.farmID == farmID }
                }
                if let weightFact {
                    guard let linkedWeight,
                          linkedWeight.deletedAt == nil,
                          linkedWeight.kilogramsText == weightFact.kilogramsText,
                          linkedWeight.occurredAt == weightFact.occurredAt,
                          linkedWeight.note == weightFact.note else { return false }
                } else if linkedWeight?.deletedAt == nil {
                    return false
                }
            }
        }
        return true
    }

    private static func applyHealth(_ draft: CareHealthDraft, farmID: UUID, context: ModelContext) throws -> CareApplyResult {
        let subjects = try healthSubjects(draft, farmID: farmID, context: context)
        return try applyHealth(draft, subjects: subjects, farmID: farmID, context: context)
    }

    private static func applyHealth(
        _ draft: CareHealthDraft,
        subjects: [SheepRecord],
        farmID: UUID,
        context: ModelContext
    ) throws -> CareApplyResult {
        let draftID = draft.id
        if try context.fetch(FetchDescriptor<HealthRecord>(predicate: #Predicate {
            $0.id == draftID && $0.farmID == farmID
        })).isEmpty == false {
            return .init(entityType: .health, entityID: draft.id, baseRevision: 0, resultingRevision: 1)
        }
        context.insert(CareBatchRecord(id: draft.batchID, farmID: farmID, kind: .health, occurredAt: draft.occurredAt, note: draft.note.trimmed))
        let record = HealthRecord(id: draft.id, farmID: farmID, sheepID: subjects.count == 1 ? subjects[0].id : nil, penID: draft.penID, kind: draft.kind, itemNameSnapshot: draft.itemName.trimmed, occurredAt: draft.occurredAt, note: draft.note.trimmed, inventoryLotID: draft.inventoryLotID, catalogItemID: draft.catalogItemID, batchID: draft.batchID, quantityText: draft.dosePerSubjectText?.trimmed.nilIfEmpty, unit: draft.unit.trimmed, route: draft.route.trimmed)
        context.insert(record)
        for sheep in subjects { context.insert(HealthSubjectLink(id: StableCloudUUID.derived(namespace: draft.id, name: sheep.id.uuidString.lowercased()), farmID: farmID, healthRecordID: draft.id, sheepID: sheep.id)) }
        if let lotID = draft.inventoryLotID, let dose = Decimal.stable(draft.dosePerSubjectText ?? "") {
            context.insert(InventoryTransactionRecord(id: StableCloudUUID.derived(namespace: draft.id, name: "inventory-consumption"), farmID: farmID, inventoryLotID: lotID, kind: .consumption, quantityText: (dose * Decimal(subjects.count)).stableText, occurredAt: draft.occurredAt, sourceRecordID: draft.id, note: draft.itemName.trimmed))
        }
        if let dueAt = draft.reminderAt {
            for sheep in subjects { insertReminder(farmID: farmID, kind: .booster, sourceType: CloudEntityType.health.rawValue, sourceID: draft.id, sheepID: sheep.id, dueAt: dueAt, title: "\(sheep.earTag) · \(draft.itemName)复免", context: context) }
        }
        return .init(entityType: .health, entityID: draft.id, baseRevision: 0, resultingRevision: 1)
    }

    private static func applyHealthCorrection(
        original: HealthRecord,
        replacement: CareHealthDraft,
        subjects: [SheepRecord],
        reason: String,
        accountID: UUID,
        farmID: UUID,
        context: ModelContext,
        modifiedAt: Date
    ) throws -> CareApplyResult {
        try DomainEntityDeletionService.setDeletedAt(
            modifiedAt,
            type: .health,
            id: original.id,
            farmID: farmID,
            context: context
        )
        context.insert(TombstoneRecord(
            farmID: farmID,
            entityType: CloudEntityType.health.rawValue,
            entityID: original.id,
            deletedByAccountID: accountID,
            reason: "修正：\(reason.trimmed)"
        ))
        let result = try applyHealth(
            replacement,
            subjects: subjects,
            farmID: farmID,
            context: context
        )
        return CareApplyResult(
            entityType: result.entityType,
            entityID: result.entityID,
            baseRevision: 1,
            resultingRevision: 2
        )
    }

    private static func healthSubjects(_ draft: CareHealthDraft, farmID: UUID, context: ModelContext) throws -> [SheepRecord] {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        if !draft.subjectIDs.isEmpty {
            let ids = Set(draft.subjectIDs)
            guard ids.count == draft.subjectIDs.count else { throw FarmCommandError.invalidReproductionRecord }
            let selected = sheep.filter { ids.contains($0.id) }
            guard selected.count == ids.count else { throw FarmCommandError.sheepNotFound }
            return selected.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
        }
        guard let penID = draft.penID else { throw FarmCommandError.missingRequiredValue("健康记录对象") }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let selectedIDs = FarmPenOccupancyIndex.make(
            farmID: farmID,
            sheep: sheep,
            transfers: transfers,
            removals: removals
        ).sheepIDs(in: penID, at: draft.occurredAt)
        let selected = sheep.filter { record in
            selectedIDs.contains(record.id)
        }
        guard !selected.isEmpty else { throw FarmCommandError.penHasNoSheepAtTime }
        return selected.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }
    }

    private static func inventoryLot(_ id: UUID, farmID: UUID, context: ModelContext, requiresActive: Bool = true) throws -> InventoryLotRecord {
        guard let lot = try context.fetch(FetchDescriptor<InventoryLotRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil && (!requiresActive || $0.isActive) }) else { throw FarmCommandError.inventoryLotNotFound }
        return lot
    }

    private static func semen(_ id: UUID, farmID: UUID, context: ModelContext) throws -> SemenRecord {
        guard let record = try context.fetch(FetchDescriptor<SemenRecord>()).first(where: { $0.id == id && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.missingRequiredValue("冻精批次") }
        return record
    }

    private static func validateHealth(_ draft: CareHealthDraft, farmID: UUID, inventoryCreditSourceID: UUID?, context: ModelContext) throws {
        let subjects = try healthSubjects(draft, farmID: farmID, context: context)
        try validateHealth(
            draft,
            subjects: subjects,
            farmID: farmID,
            inventoryCreditSourceID: inventoryCreditSourceID,
            context: context
        )
    }

    private static func validateHealth(
        _ draft: CareHealthDraft,
        subjects: [SheepRecord],
        farmID: UUID,
        inventoryCreditSourceID: UUID?,
        context: ModelContext
    ) throws {
        try require(draft.itemName, "药品或疫苗名称")
        guard let lotID = draft.inventoryLotID else { return }
        let dose = try positive(draft.dosePerSubjectText ?? "", "每只剂量")
        let lot = try inventoryLot(lotID, farmID: farmID, context: context)
        var available = try inventoryBalance(lot, context: context)
        if let sourceID = inventoryCreditSourceID {
            let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>(predicate: #Predicate {
                $0.farmID == farmID &&
                    $0.inventoryLotID == lotID &&
                    $0.sourceRecordID == sourceID &&
                    $0.deletedAt == nil
            }))
            available += transactions
                .filter { $0.kind == .consumption }
                .reduce(0) { $0 + $1.quantity }
        }
        guard available >= dose * Decimal(subjects.count) else { throw FarmCommandError.insufficientInventory }
    }

    private static func validateReproductionBatch(_ draft: CareReproductionBatchDraft, farmID: UUID, semenCreditSourceID: UUID?, context: ModelContext) throws {
        guard [.breeding, .pregnancyCheck, .abortion].contains(draft.kind), !draft.subjects.isEmpty else { throw FarmCommandError.invalidReproductionRecord }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let eweIDs = Set(draft.subjects.map(\.eweID))
        guard eweIDs.count == draft.subjects.count,
              draft.subjects.allSatisfy({ subject in sheep.contains { $0.id == subject.eweID && $0.farmID == farmID && $0.deletedAt == nil && $0.sex == .ewe } }) else { throw FarmCommandError.reproductionSubjectMustBeEwe }
        if draft.kind != .breeding, draft.sireID != nil || draft.semenID != nil { throw FarmCommandError.pregnancyCheckCannotSetPaternity }
        if let sireID = draft.sireID, !sheep.contains(where: { $0.id == sireID && $0.farmID == farmID && $0.deletedAt == nil && $0.sex == .ram && $0.isBreedingRam }) { throw FarmCommandError.reproductionSireMustBeRam }
        if draft.kind == .breeding {
            guard (draft.sireID == nil) != (draft.semenID == nil), draft.subjects.allSatisfy({ $0.relatedBreedingRecordID == nil }) else { throw FarmCommandError.pedigreePaternalSourceConflict }
            _ = try resolvePaternity(sireID: draft.sireID, semenID: draft.semenID, farmID: farmID, context: context)
        } else {
            for subject in draft.subjects {
                if let relatedID = subject.relatedBreedingRecordID {
                    _ = try linkedBreeding(relatedID, eweID: subject.eweID, eventAt: draft.occurredAt, closesBreeding: draft.kind == .abortion, farmID: farmID, context: context)
                }
            }
        }
        if let semenID = draft.semenID {
            let record = try semen(semenID, farmID: farmID, context: context)
            let perEwe = try positive(draft.semenUnitsPerEweText ?? "1", "每只冻精用量")
            var available = try semenBalance(record, context: context)
            if let sourceID = semenCreditSourceID {
                available += try context.fetch(FetchDescriptor<SemenTransactionRecord>())
                    .filter { $0.farmID == farmID && $0.semenID == semenID && $0.sourceRecordID == sourceID && $0.kind == .consumption && $0.deletedAt == nil }
                    .reduce(0) { $0 + $1.quantity }
            }
            guard available >= perEwe * Decimal(draft.subjects.count) else { throw FarmCommandError.insufficientInventory }
        }
    }

    private struct ResolvedPaternity {
        let sireID: UUID?
        let semen: SemenRecord?
        let donorID: UUID?
        let donorNameSnapshot: String?
        let donorRegistrationNumberSnapshot: String?
        let donorBreedSnapshot: String?
        let source: PaternalIdentitySource

        static var unknown: ResolvedPaternity { ResolvedPaternity(sireID: nil, semen: nil, donorID: nil, donorNameSnapshot: nil, donorRegistrationNumberSnapshot: nil, donorBreedSnapshot: nil, source: .unknown) }
    }

    private static func resolvePaternity(sireID: UUID?, semenID: UUID?, farmID: UUID, context: ModelContext) throws -> ResolvedPaternity {
        guard sireID == nil || semenID == nil else { throw FarmCommandError.pedigreePaternalSourceConflict }
        if let sireID {
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            guard sheep.contains(where: { $0.id == sireID && $0.farmID == farmID && $0.deletedAt == nil && $0.sex == .ram && $0.isBreedingRam }) else { throw FarmCommandError.reproductionSireMustBeRam }
            return .init(sireID: sireID, semen: nil, donorID: nil, donorNameSnapshot: nil, donorRegistrationNumberSnapshot: nil, donorBreedSnapshot: nil, source: .ram)
        }
        if let semenID {
            let semenRecord = try semen(semenID, farmID: farmID, context: context)
            let donor = try semenRecord.donorID.map { try semenDonor($0, farmID: farmID, context: context, requiresActive: true) }
            return .init(
                sireID: donor?.linkedRamID,
                semen: semenRecord,
                donorID: donor?.id,
                donorNameSnapshot: donor?.name,
                donorRegistrationNumberSnapshot: donor?.registrationNumber.nilIfEmpty,
                donorBreedSnapshot: donor?.breed,
                source: donor == nil ? .unknown : .semenDonor
            )
        }
        return .unknown
    }

    private static func resolveLambingPaternity(_ draft: CareLambingDraft, farmID: UUID, context: ModelContext) throws -> ResolvedPaternity {
        let explicit = try resolvePaternity(sireID: draft.sireID, semenID: draft.semenID, farmID: farmID, context: context)
        guard let relatedID = draft.relatedBreedingRecordID else { return explicit }
        let breeding = try linkedBreeding(relatedID, eweID: draft.eweID, eventAt: draft.occurredAt, closesBreeding: true, excludingClosureID: draft.id, farmID: farmID, context: context)
        let inherited = ResolvedPaternity(
            sireID: breeding.sireID,
            semen: try breeding.semenID.map { try semen($0, farmID: farmID, context: context) },
            donorID: breeding.semenDonorID,
            donorNameSnapshot: breeding.semenDonorNameSnapshot,
            donorRegistrationNumberSnapshot: breeding.semenDonorRegistrationNumberSnapshot,
            donorBreedSnapshot: breeding.semenDonorBreedSnapshot,
            source: breeding.paternalSource
        )
        if explicit.source == .unknown { return inherited }
        guard explicit.sireID == inherited.sireID,
              explicit.semen?.id == inherited.semen?.id,
              explicit.donorID == inherited.donorID else { throw FarmCommandError.pedigreePaternalSourceConflict }
        return inherited
    }

    private static func linkedBreeding(_ id: UUID, eweID: UUID, eventAt: Date, closesBreeding: Bool, excludingClosureID: UUID? = nil, farmID: UUID, context: ModelContext) throws -> ReproductionRecord {
        let records = try context.fetch(FetchDescriptor<ReproductionRecord>())
        guard let breeding = records.first(where: { $0.id == id && $0.farmID == farmID && $0.eweID == eweID && $0.kind == .breeding && $0.deletedAt == nil && $0.occurredAt <= eventAt }) else { throw FarmCommandError.linkedBreedingNotFound }
        if closesBreeding, records.contains(where: {
            $0.id != excludingClosureID && $0.farmID == farmID && $0.relatedBreedingRecordID == id && $0.deletedAt == nil && ($0.kind == .lambing || $0.kind == .abortion)
        }) { throw FarmCommandError.linkedBreedingAlreadyClosed }
        return breeding
    }

    private static func validateSemenDonor(_ draft: CareSemenDonorDraft, farmID: UUID, context: ModelContext) throws {
        try require(draft.name, "供体名称")
        try require(draft.breed, "供体品种")
        let donors = try context.fetch(FetchDescriptor<SemenDonorRecord>())
        if let existing = donors.first(where: { $0.id == draft.id && $0.farmID == farmID }) {
            guard existing.revision == draft.expectedRevision else { throw FarmCommandError.pedigreeRevisionConflict }
        } else {
            guard draft.expectedRevision == 0 else { throw FarmCommandError.pedigreeRevisionConflict }
        }
        let registration = draft.registrationNumber.trimmed
        if !registration.isEmpty, donors.contains(where: { $0.id != draft.id && $0.farmID == farmID && $0.deletedAt == nil && $0.registrationNumber.caseInsensitiveCompare(registration) == .orderedSame }) {
            throw FarmCommandError.duplicateSemenDonorRegistration
        }
        if let ramID = draft.linkedRamID {
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            guard sheep.contains(where: { $0.id == ramID && $0.farmID == farmID && $0.deletedAt == nil && $0.sex == .ram && $0.isBreedingRam }) else { throw FarmCommandError.reproductionSireMustBeRam }
        }
    }

    private static func semenDonor(_ id: UUID, farmID: UUID, context: ModelContext, requiresActive: Bool) throws -> SemenDonorRecord {
        guard let donor = try context.fetch(FetchDescriptor<SemenDonorRecord>()).first(where: {
            $0.id == id && $0.farmID == farmID && $0.deletedAt == nil && (!requiresActive || $0.status == .active)
        }) else { throw FarmCommandError.semenDonorNotFound }
        return donor
    }

    private static func validatePedigree(
        _ draft: CarePedigreeUpdateDraft,
        farmID: UUID,
        context: ModelContext,
        sheepByID cachedSheepByID: [UUID: SheepRecord]? = nil
    ) throws {
        guard !draft.reason.trimmed.isEmpty else { throw FarmCommandError.pedigreeReasonRequired }
        let sheepByID: [UUID: SheepRecord]
        if let cachedSheepByID {
            sheepByID = cachedSheepByID
        } else {
            sheepByID = Dictionary(uniqueKeysWithValues: try context.fetch(
                FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.deletedAt == nil
                })
            ).map { ($0.id, $0) })
        }
        guard let child = sheepByID[draft.sheepID] else { throw FarmCommandError.sheepNotFound }
        guard child.revision == draft.expectedRevision else { throw FarmCommandError.pedigreeRevisionConflict }
        guard draft.damID != child.id, draft.sireID != child.id else { throw FarmCommandError.pedigreeSelfReference }
        let dam = draft.damID.flatMap { sheepByID[$0] }
        if draft.damID != nil, dam?.sex != .ewe { throw FarmCommandError.pedigreeParentSexMismatch }
        let directSire = draft.sireID.flatMap { sheepByID[$0] }
        if draft.sireID != nil, directSire?.sex != .ram || directSire?.isBreedingRam != true { throw FarmCommandError.pedigreeParentSexMismatch }
        let donor = try draft.semenDonorID.map { try semenDonor($0, farmID: farmID, context: context, requiresActive: false) }
        if donor != nil, directSire != nil { throw FarmCommandError.pedigreePaternalSourceConflict }
        let resolvedSire = donor?.linkedRamID.flatMap { sheepByID[$0] } ?? directSire
        if let dam, let resolvedSire, dam.id == resolvedSire.id { throw FarmCommandError.pedigreePaternalSourceConflict }
        if let birthAt = child.birthAt {
            if let parentBirth = dam?.birthAt, parentBirth >= birthAt { throw FarmCommandError.pedigreeDateInversion }
            if let parentBirth = resolvedSire?.birthAt, parentBirth >= birthAt { throw FarmCommandError.pedigreeDateInversion }
        }
        if let dam, ancestryContains(child.id, startingAt: dam.id, sheepByID: sheepByID) { throw FarmCommandError.pedigreeCycle }
        if let resolvedSire, ancestryContains(child.id, startingAt: resolvedSire.id, sheepByID: sheepByID) { throw FarmCommandError.pedigreeCycle }
    }

    private static func ancestryContains(
        _ target: UUID,
        startingAt root: UUID,
        sheepByID: [UUID: SheepRecord]
    ) -> Bool {
        var pending = [root]
        var visited = Set<UUID>()
        while let current = pending.popLast() {
            if current == target { return true }
            guard visited.insert(current).inserted, let record = sheepByID[current] else { continue }
            if let damID = record.damID { pending.append(damID) }
            if let sireID = record.sireID { pending.append(sireID) }
        }
        return false
    }

    private struct LambWeightFact {
        let kilogramsText: String
        let occurredAt: Date
        let kind: LambRecordedWeightKind

        var birthWeightText: String { kind == .birth ? kilogramsText : "" }
        var note: String { kind == .birth ? "初生重" : "产羔录入称重" }
    }

    private static func lambWeightFact(_ lamb: CareLambDraft, lambingAt: Date) -> LambWeightFact? {
        guard let value = Decimal.stable(lamb.birthWeightText) else { return nil }
        let occurredAt = lamb.weightOccurredAt ?? lambingAt
        return LambWeightFact(
            kilogramsText: value.stableText,
            occurredAt: occurredAt,
            kind: LambingEntrySemantics.weightKind(lambingAt: lambingAt, weighedAt: occurredAt)
        )
    }

    private static func newAutoWeightRecordID(for lamb: CareLambDraft, fact: LambWeightFact) -> UUID {
        if fact.kind == .birth {
            return StableCloudUUID.derived(namespace: lamb.sheepID, name: "birth-weight")
        }
        return StableCloudUUID.derived(namespace: lamb.id, name: "lambing-recorded-weight")
    }

    private static func resolvedPaternalBreed(
        _ paternity: ResolvedPaternity,
        sheep: [SheepRecord]
    ) -> String? {
        if let donorBreed = normalizedBreed(paternity.donorBreedSnapshot) {
            return donorBreed
        }
        if let sireID = paternity.sireID,
           let sireBreed = normalizedBreed(sheep.first(where: { $0.id == sireID })?.breed) {
            return sireBreed
        }
        return normalizedBreed(paternity.semen?.breed)
    }

    private static func resolvedLambBreed(
        _ lamb: CareLambDraft,
        paternalBreed: String?,
        maternalBreed: String?
    ) -> String {
        if let requestedBreed = lamb.breed {
            return requestedBreed.trimmed
        }
        return LambingEntrySemantics.suggestedLambBreed(
            paternalBreed: paternalBreed,
            maternalBreed: maternalBreed
        )
    }

    private static func normalizedBreed(_ breed: String?) -> String? {
        guard let breed else { return nil }
        let normalized = breed.trimmed
        return normalized.isEmpty ? nil : normalized
    }

    private static func validateLambing(_ draft: CareLambingDraft, farmID: UUID, existingRecordID: UUID?, context: ModelContext) throws {
        guard draft.occurredAt <= Date.now else { throw FarmCommandError.futureFactDate("产羔时间") }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        guard let ewe = sheep.first(where: { $0.id == draft.eweID && $0.farmID == farmID && $0.deletedAt == nil }), ewe.sex == .ewe else { throw FarmCommandError.reproductionSubjectMustBeEwe }
        guard draft.parity > 0, draft.birthDeadCount >= 0, draft.birthDeadCount == draft.offspring.count(where: \.isStillborn), !draft.offspring.isEmpty, draft.offspring.allSatisfy({ !$0.isStillborn || !$0.createSheepRecord }), Set(draft.offspring.map(\.id)).count == draft.offspring.count else { throw FarmCommandError.invalidReproductionRecord }
        let paternity = try resolveLambingPaternity(draft, farmID: farmID, context: context)
        let paternalBreed = resolvedPaternalBreed(paternity, sheep: sheep)
        if let penID = draft.penID {
            guard try context.fetch(FetchDescriptor<PenRecord>()).contains(where: { $0.id == penID && $0.farmID == farmID && $0.deletedAt == nil }) else { throw FarmCommandError.penNotFound }
        }
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>())
        let currentParity = LambingEntrySemantics.priorParityForLambing(
            eweID: draft.eweID,
            farmID: farmID,
            at: draft.occurredAt,
            existingRecordID: existingRecordID,
            records: reproduction
        )
        guard draft.parity == currentParity + 1 else {
            throw FarmCommandError.lambingParityMismatch(current: currentParity, attempted: draft.parity)
        }
        let nextParityFact = reproduction
            .filter {
                $0.id != existingRecordID &&
                    $0.farmID == farmID &&
                    $0.eweID == draft.eweID &&
                    $0.deletedAt == nil &&
                    ($0.kind == .lambing || $0.kind == .parityBaseline) &&
                    $0.occurredAt > draft.occurredAt
            }
            .sorted { $0.occurredAt < $1.occurredAt }
            .first
        if let nextParityFact, nextParityFact.kind == .lambing,
           nextParityFact.parity != draft.parity + 1 {
            throw FarmCommandError.lambingCorrectionConflict("本次胎次会与后续产羔记录冲突")
        }
        let existingOffspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.farmID == farmID && $0.lambingRecordID == existingRecordID }
        let originalLambing = try existingRecordID.flatMap { id in
            try context.fetch(FetchDescriptor<ReproductionRecord>()).first { $0.id == id && $0.farmID == farmID && $0.kind == .lambing }
        }
        let editableSheepIDs = Set(existingOffspring.compactMap(\.sheepID))
        let existingTags = Set(sheep.filter { $0.farmID == farmID && !editableSheepIDs.contains($0.id) }.map { EarTag.normalized($0.earTag) })
        let newTags = draft.offspring.filter(\.createSheepRecord).map { EarTag.normalized($0.earTag) }
        guard newTags.allSatisfy({ !$0.isEmpty }), Set(newTags).count == newTags.count, existingTags.isDisjoint(with: newTags) else { throw FarmCommandError.duplicateEarTag }
        for lamb in draft.offspring {
            if lamb.createSheepRecord {
                try require(
                    resolvedLambBreed(lamb, paternalBreed: paternalBreed, maternalBreed: ewe.breed),
                    "羔羊品种"
                )
            }
            let weightText = lamb.birthWeightText.trimmed
            if weightText.isEmpty {
                guard lamb.weightOccurredAt == nil else { throw FarmCommandError.missingRequiredValue("羔羊体重") }
            } else {
                _ = try positive(weightText, "羔羊体重")
                let weighedAt = lamb.weightOccurredAt ?? draft.occurredAt
                guard weighedAt >= draft.occurredAt else { throw FarmCommandError.lambWeightBeforeBirth }
                guard weighedAt <= Date.now else { throw FarmCommandError.futureFactDate("称重时间") }
                let kind = LambingEntrySemantics.weightKind(lambingAt: draft.occurredAt, weighedAt: weighedAt)
                if lamb.isStillborn, kind != .birth { throw FarmCommandError.stillbornWeightMustBeBirth }
                if kind == .routine, !lamb.createSheepRecord { throw FarmCommandError.routineLambWeightRequiresSheepRecord }
            }
            if let prior = existingOffspring.first(where: { $0.id == lamb.id }), let sheepID = prior.sheepID {
                guard lamb.createSheepRecord, sheepID == lamb.sheepID else { throw FarmCommandError.lambingCorrectionConflict("已建档羔羊不能改成死羔或替换档案") }
                guard let child = sheep.first(where: { $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil }),
                      EarTag.normalized(child.earTag) == EarTag.normalized(prior.legacyEarTag),
                      child.sexRawValue == prior.sexRawValue,
                      originalLambing?.occurredAt == child.birthAt else {
                    throw FarmCommandError.lambingCorrectionConflict("羔羊档案已在产羔记录之外被人工修改")
                }
                if let firstDownstream = try earliestDownstreamDate(sheepID: sheepID, excludingBirthWeightID: prior.autoBirthWeightRecordID, farmID: farmID, context: context), draft.occurredAt > firstDownstream {
                    throw FarmCommandError.lambingCorrectionConflict("修正后的产羔日期晚于羔羊后续记录")
                }
            }
        }
    }

    private static func earliestDownstreamDate(sheepID: UUID, excludingBirthWeightID: UUID?, farmID: UUID, context: ModelContext) throws -> Date? {
        var dates: [Date] = []
        dates += try context.fetch(FetchDescriptor<WeightRecord>()).filter { $0.farmID == farmID && $0.sheepID == sheepID && $0.id != excludingBirthWeightID && $0.deletedAt == nil }.map(\.occurredAt)
        dates += try context.fetch(FetchDescriptor<WeaningRecord>()).filter { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }.map(\.occurredAt)
        dates += try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }.map(\.occurredAt)
        dates += try context.fetch(FetchDescriptor<RemovalRecord>()).filter { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }.map(\.occurredAt)
        dates += try context.fetch(FetchDescriptor<HealthRecord>()).filter { $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil }.map(\.occurredAt)
        dates += try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID && $0.eweID == sheepID && $0.deletedAt == nil }.map(\.occurredAt)
        return dates.min()
    }

    private static func applyLambingCorrection(originalID: UUID, replacement: CareLambingDraft, reason: String, accountID: UUID, farmID: UUID, context: ModelContext, modifiedAt: Date) throws -> CareApplyResult {
        guard let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: { $0.id == originalID && $0.farmID == farmID && $0.kind == .lambing && $0.deletedAt == nil }) else { throw FarmCommandError.sourceRecordNotFound }
        let base = reproduction.revision
        let previousEweID = reproduction.eweID
        let previousSireID = reproduction.sireID
        let previousDonorID = reproduction.semenDonorID
        let paternity = try resolveLambingPaternity(replacement, farmID: farmID, context: context)
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        let ewe = sheep.first(where: { $0.id == replacement.eweID && $0.farmID == farmID })
        let paternalBreed = resolvedPaternalBreed(paternity, sheep: sheep)
        let offspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.farmID == farmID && $0.lambingRecordID == originalID }
        let replacementIDs = Set(replacement.offspring.map(\.id))

        for prior in offspring where !replacementIDs.contains(prior.id) && prior.deletedAt == nil {
            try compensateRemovedOffspring(prior, eweID: previousEweID, sireID: previousSireID, donorID: previousDonorID, reason: reason, accountID: accountID, farmID: farmID, context: context, modifiedAt: modifiedAt)
            prior.deletedByLambingRevocation = false
            prior.deletedAt = modifiedAt
            prior.updatedAt = modifiedAt
            prior.revision += 1
        }

        for lamb in replacement.offspring {
            let weightFact = lambWeightFact(lamb, lambingAt: replacement.occurredAt)
            let suggestedWeightID = weightFact.map { newAutoWeightRecordID(for: lamb, fact: $0) }
            if let prior = offspring.first(where: { $0.id == lamb.id }) {
                prior.legacyEarTag = lamb.earTag.trimmed
                prior.sexRawValue = lamb.sex.rawValue
                prior.birthWeightText = weightFact?.birthWeightText ?? ""
                prior.isStillborn = lamb.isStillborn
                prior.deletedAt = nil
                prior.updatedAt = modifiedAt
                prior.revision += 1
                if prior.autoCreatedSheep, let sheepID = prior.sheepID,
                   let child = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil }) {
                    child.earTag = lamb.earTag.trimmed
                    if let requestedBreed = lamb.breed {
                        child.breed = requestedBreed.trimmed
                    }
                    child.sexRawValue = lamb.sex.rawValue
                    child.birthAt = replacement.occurredAt
                    child.enteredAt = min(child.enteredAt, replacement.occurredAt)
                    child.initialPenID = replacement.penID
                    let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter {
                        $0.farmID == farmID && $0.sheepID == child.id && $0.deletedAt == nil
                    }
                    child.currentPenID = FarmHistoryTimeline.pen(for: child, at: .now, transfers: transfers)
                    try updateLambingPedigree(child: child, damID: replacement.eweID, paternity: paternity, reason: reason, accountID: accountID, auditNamespace: prior.id, farmID: farmID, context: context, modifiedAt: modifiedAt)
                    child.updatedAt = modifiedAt
                    child.revision += 1
                    let linkedWeight = try prior.autoBirthWeightRecordID.flatMap { weightID in
                        try context.fetch(FetchDescriptor<WeightRecord>()).first { $0.id == weightID && $0.farmID == farmID }
                    }
                    if let weightFact {
                        if let linkedWeight {
                            linkedWeight.kilogramsText = weightFact.kilogramsText
                            linkedWeight.occurredAt = weightFact.occurredAt
                            linkedWeight.note = weightFact.note
                            linkedWeight.deletedAt = nil
                            linkedWeight.revision += 1
                        } else if let suggestedWeightID {
                            context.insert(WeightRecord(id: suggestedWeightID, farmID: farmID, sheepID: child.id, kilogramsText: weightFact.kilogramsText, occurredAt: weightFact.occurredAt, note: weightFact.note))
                            prior.autoBirthWeightRecordID = suggestedWeightID
                        }
                        prior.autoBirthWeightRevokedByLambing = false
                    } else if let linkedWeight, linkedWeight.deletedAt == nil {
                        linkedWeight.deletedAt = modifiedAt
                        linkedWeight.revision += 1
                        prior.autoBirthWeightRevokedByLambing = false
                    }
                }
            } else {
                if lamb.createSheepRecord {
                    context.insert(SheepRecord(id: lamb.sheepID, farmID: farmID, earTag: lamb.earTag.trimmed, breed: resolvedLambBreed(lamb, paternalBreed: paternalBreed, maternalBreed: ewe?.breed), sex: lamb.sex, penID: replacement.penID, enteredAt: replacement.occurredAt, birthAt: replacement.occurredAt, damID: replacement.eweID, sireID: paternity.sireID, damProvenance: .lambing, sireProvenance: paternity.source == .unknown ? nil : .lambing, semenDonorID: paternity.donorID, semenDonorNameSnapshot: paternity.donorNameSnapshot, semenDonorRegistrationNumberSnapshot: paternity.donorRegistrationNumberSnapshot, semenDonorBreedSnapshot: paternity.donorBreedSnapshot, note: "由产羔修正补录建档"))
                    if let weightFact, let suggestedWeightID {
                        context.insert(WeightRecord(id: suggestedWeightID, farmID: farmID, sheepID: lamb.sheepID, kilogramsText: weightFact.kilogramsText, occurredAt: weightFact.occurredAt, note: weightFact.note))
                    }
                }
                context.insert(LambingOffspringRecord(id: lamb.id, farmID: farmID, lambingRecordID: originalID, sheepID: lamb.createSheepRecord ? lamb.sheepID : nil, legacyEarTag: lamb.earTag.trimmed, sexRawValue: lamb.sex.rawValue, birthWeightText: weightFact?.birthWeightText ?? "", isStillborn: lamb.isStillborn, autoCreatedSheep: lamb.createSheepRecord, autoBirthWeightRecordID: lamb.createSheepRecord ? suggestedWeightID : nil))
            }
        }

        reproduction.eweID = replacement.eweID
        reproduction.occurredAt = replacement.occurredAt
        reproduction.sireID = paternity.sireID
        reproduction.semenID = paternity.semen?.id
        reproduction.relatedBreedingRecordID = replacement.relatedBreedingRecordID
        reproduction.semenNameSnapshot = paternity.semen?.code
        reproduction.semenDonorID = paternity.donorID
        reproduction.semenDonorNameSnapshot = paternity.donorNameSnapshot
        reproduction.semenDonorRegistrationNumberSnapshot = paternity.donorRegistrationNumberSnapshot
        reproduction.semenDonorBreedSnapshot = paternity.donorBreedSnapshot
        reproduction.paternalSourceRawValue = paternity.source.rawValue
        reproduction.lambCount = replacement.offspring.count
        reproduction.parity = replacement.parity
        reproduction.birthDeadCount = replacement.birthDeadCount
        reproduction.note = replacement.note.trimmed
        reproduction.updatedAt = modifiedAt
        reproduction.revision += 1
        deleteExpectedLambingReminders(eweID: replacement.eweID, farmID: farmID, at: modifiedAt, context: context)
        return .init(entityType: .reproduction, entityID: reproduction.id, baseRevision: base, resultingRevision: reproduction.revision)
    }

    private static func compensateRemovedOffspring(_ offspring: LambingOffspringRecord, eweID: UUID, sireID: UUID?, donorID: UUID?, reason: String, accountID: UUID, farmID: UUID, context: ModelContext, modifiedAt: Date) throws {
        guard offspring.autoCreatedSheep, let sheepID = offspring.sheepID,
              let child = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil }) else { return }
        let beforeDam = child.damID
        let beforeSire = child.sireID
        let beforeDonor = child.semenDonorID
        if child.damID == eweID, child.damProvenance == .lambing { child.damID = nil; child.damProvenanceRawValue = nil }
        if child.sireID == sireID, child.sireProvenance == .lambing { child.sireID = nil; child.sireProvenanceRawValue = nil }
        if child.semenDonorID == donorID, child.sireProvenance != .manual {
            child.semenDonorID = nil; child.semenDonorNameSnapshot = nil; child.semenDonorRegistrationNumberSnapshot = nil; child.semenDonorBreedSnapshot = nil
        }
        if beforeDam != child.damID || beforeSire != child.sireID || beforeDonor != child.semenDonorID {
            context.insert(PedigreeChangeRecord(id: StableCloudUUID.derived(namespace: offspring.id, name: "compensate-\(offspring.revision + 1)"), farmID: farmID, sheepID: child.id, beforeDamID: beforeDam, afterDamID: child.damID, beforeSireID: beforeSire, afterSireID: child.sireID, beforeSemenDonorID: beforeDonor, afterSemenDonorID: child.semenDonorID, beforeDamSourceRawValue: beforeDam == nil ? nil : PedigreeRelationSource.lambing.rawValue, afterDamSourceRawValue: child.damProvenanceRawValue, beforeSireSourceRawValue: beforeSire == nil && beforeDonor == nil ? nil : PedigreeRelationSource.lambing.rawValue, afterSireSourceRawValue: child.sireProvenanceRawValue, reason: reason, changedByAccountID: accountID, sheepRevision: child.revision + 1, occurredAt: modifiedAt))
            child.updatedAt = modifiedAt
            child.revision += 1
            offspring.autoPedigreeRevokedByLambing = true
        }
        if let weightID = offspring.autoBirthWeightRecordID,
           let weight = try context.fetch(FetchDescriptor<WeightRecord>()).first(where: { $0.id == weightID && $0.farmID == farmID && $0.deletedAt == nil }) {
            weight.deletedAt = modifiedAt
            weight.revision += 1
            offspring.autoBirthWeightRevokedByLambing = true
        }
    }

    private static func updateLambingPedigree(child: SheepRecord, damID: UUID, paternity: ResolvedPaternity, reason: String, accountID: UUID, auditNamespace: UUID, farmID: UUID, context: ModelContext, modifiedAt: Date) throws {
        let preservesManualDam = child.damProvenance == .manual
        let preservesManualSire = child.sireProvenance == .manual
        if (preservesManualDam && child.damID != damID) || (preservesManualSire && (child.sireID != paternity.sireID || child.semenDonorID != paternity.donorID)) {
            throw FarmCommandError.lambingCorrectionConflict("羔羊系谱已被人工确认")
        }
        let beforeDam = child.damID
        let beforeSire = child.sireID
        let beforeDonor = child.semenDonorID
        let beforeDamSource = child.damProvenanceRawValue
        let beforeSireSource = child.sireProvenanceRawValue
        if !preservesManualDam {
            child.damID = damID
            child.damProvenanceRawValue = PedigreeRelationSource.lambing.rawValue
        }
        if !preservesManualSire {
            child.sireID = paternity.sireID
            child.sireProvenanceRawValue = paternity.source == .unknown ? nil : PedigreeRelationSource.lambing.rawValue
            child.semenDonorID = paternity.donorID
            child.semenDonorNameSnapshot = paternity.donorNameSnapshot
            child.semenDonorRegistrationNumberSnapshot = paternity.donorRegistrationNumberSnapshot
            child.semenDonorBreedSnapshot = paternity.donorBreedSnapshot
        }
        if beforeDam != child.damID || beforeSire != child.sireID || beforeDonor != child.semenDonorID {
            context.insert(PedigreeChangeRecord(id: StableCloudUUID.derived(namespace: auditNamespace, name: "lambing-correction-\(child.revision + 1)"), farmID: farmID, sheepID: child.id, beforeDamID: beforeDam, afterDamID: child.damID, beforeSireID: beforeSire, afterSireID: child.sireID, beforeSemenDonorID: beforeDonor, afterSemenDonorID: child.semenDonorID, beforeDamSourceRawValue: beforeDamSource, afterDamSourceRawValue: child.damProvenanceRawValue, beforeSireSourceRawValue: beforeSireSource, afterSireSourceRawValue: child.sireProvenanceRawValue, reason: reason, changedByAccountID: accountID, sheepRevision: child.revision + 1, occurredAt: modifiedAt))
        }
    }

    private static func setLambingRevoked(_ revoked: Bool, recordID: UUID, reason: String, accountID: UUID, farmID: UUID, context: ModelContext, modifiedAt: Date) throws -> CareApplyResult {
        guard let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>()).first(where: { $0.id == recordID && $0.farmID == farmID && $0.kind == .lambing }) else { throw FarmCommandError.sourceRecordNotFound }
        let base = reproduction.revision
        let offspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>()).filter { $0.farmID == farmID && $0.lambingRecordID == recordID }
        let paternity = ResolvedPaternity(sireID: reproduction.sireID, semen: try reproduction.semenID.map { try semen($0, farmID: farmID, context: context) }, donorID: reproduction.semenDonorID, donorNameSnapshot: reproduction.semenDonorNameSnapshot, donorRegistrationNumberSnapshot: reproduction.semenDonorRegistrationNumberSnapshot, donorBreedSnapshot: reproduction.semenDonorBreedSnapshot, source: reproduction.paternalSource)
        if revoked {
            reproduction.deletedAt = modifiedAt
            for detail in offspring where detail.deletedAt == nil {
                try compensateRemovedOffspring(detail, eweID: reproduction.eweID, sireID: reproduction.sireID, donorID: reproduction.semenDonorID, reason: reason, accountID: accountID, farmID: farmID, context: context, modifiedAt: modifiedAt)
                detail.deletedByLambingRevocation = true
                detail.deletedAt = modifiedAt
                detail.updatedAt = modifiedAt
                detail.revision += 1
            }
            restoreExpectedLambingReminders(eweID: reproduction.eweID, farmID: farmID, at: modifiedAt, context: context)
        } else {
            reproduction.deletedAt = nil
            for detail in offspring where detail.deletedByLambingRevocation {
                detail.deletedAt = nil
                detail.updatedAt = modifiedAt
                detail.revision += 1
                guard detail.autoCreatedSheep, let sheepID = detail.sheepID,
                      let child = try context.fetch(FetchDescriptor<SheepRecord>()).first(where: { $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil }) else { continue }
                if detail.autoPedigreeRevokedByLambing {
                    guard (child.damID == nil || child.damID == reproduction.eweID),
                          (child.sireID == nil || child.sireID == reproduction.sireID),
                          (child.semenDonorID == nil || child.semenDonorID == reproduction.semenDonorID) else { throw FarmCommandError.lambingCorrectionConflict("羔羊系谱在撤销后已被其他记录占用") }
                    try updateLambingPedigree(child: child, damID: reproduction.eweID, paternity: paternity, reason: reason, accountID: accountID, auditNamespace: detail.id, farmID: farmID, context: context, modifiedAt: modifiedAt)
                    child.updatedAt = modifiedAt
                    child.revision += 1
                    detail.autoPedigreeRevokedByLambing = false
                }
                if detail.autoBirthWeightRevokedByLambing, let weightID = detail.autoBirthWeightRecordID,
                   let weight = try context.fetch(FetchDescriptor<WeightRecord>()).first(where: { $0.id == weightID && $0.farmID == farmID && $0.deletedAt != nil }) {
                    weight.deletedAt = nil
                    weight.revision += 1
                    detail.autoBirthWeightRevokedByLambing = false
                }
                detail.deletedByLambingRevocation = false
            }
            deleteExpectedLambingReminders(eweID: reproduction.eweID, farmID: farmID, at: modifiedAt, context: context)
        }
        reproduction.updatedAt = modifiedAt
        reproduction.revision += 1
        return .init(entityType: .reproduction, entityID: reproduction.id, baseRevision: base, resultingRevision: reproduction.revision)
    }

    private static func insertReminder(farmID: UUID, kind: CareReminderKind, sourceType: String, sourceID: UUID, sheepID: UUID? = nil, inventoryLotID: UUID? = nil, dueAt: Date, title: String, context: ModelContext) {
        let discriminator = [kind.rawValue, sheepID?.uuidString.lowercased() ?? "", inventoryLotID?.uuidString.lowercased() ?? ""].joined(separator: ":")
        let id = StableCloudUUID.derived(namespace: sourceID, name: discriminator)
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>())) ?? []
        if let existing = reminders.first(where: { $0.id == id && $0.farmID == farmID }) {
            existing.dueAt = dueAt; existing.title = title; existing.statusRawValue = CareReminderStatus.pending.rawValue; existing.deletedAt = nil; existing.revision += 1
        } else {
            context.insert(CareReminderRecord(id: id, farmID: farmID, kind: kind, sourceEntityType: sourceType, sourceEntityID: sourceID, sheepID: sheepID, inventoryLotID: inventoryLotID, dueAt: dueAt, title: title))
        }
    }

    private static func deleteReminders(sourceID: UUID, farmID: UUID, at: Date, context: ModelContext) {
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>())) ?? []
        for reminder in reminders where reminder.farmID == farmID && reminder.sourceEntityID == sourceID && reminder.deletedAt == nil { reminder.deletedAt = at; reminder.revision += 1 }
    }

    private static func deleteExpectedLambingReminders(eweID: UUID, farmID: UUID, at: Date, context: ModelContext) {
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>())) ?? []
        for reminder in reminders where reminder.farmID == farmID && reminder.sheepID == eweID && reminder.kind == .expectedLambing && reminder.deletedAt == nil { reminder.statusRawValue = CareReminderStatus.completed.rawValue; reminder.completedAt = at; reminder.revision += 1 }
    }

    private static func restoreExpectedLambingReminders(eweID: UUID, farmID: UUID, at: Date, context: ModelContext) {
        let reminders = (try? context.fetch(FetchDescriptor<CareReminderRecord>())) ?? []
        for reminder in reminders where reminder.farmID == farmID && reminder.sheepID == eweID && reminder.kind == .expectedLambing && reminder.deletedAt == nil && reminder.status == .completed {
            reminder.statusRawValue = CareReminderStatus.pending.rawValue
            reminder.completedAt = nil
            reminder.revision += 1
        }
    }

    private static func require(_ value: String, _ label: String) throws {
        guard !value.trimmed.isEmpty else { throw FarmCommandError.missingRequiredValue(label) }
    }

    private static func positive(_ value: String, _ label: String) throws -> Decimal {
        guard let number = Decimal.stable(value.trimmed), number > 0 else { throw FarmCommandError.invalidNumber(label) }
        return number
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
