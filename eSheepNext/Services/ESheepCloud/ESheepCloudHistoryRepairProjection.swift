import Foundation
import SwiftData

/// These commands are not exposed as normal user editing actions. The server
/// requires an owner identity and an exact, pre-approved command digest/head.
enum ESheepCloudHistoryRepairCommandV2: Codable, Sendable, Equatable {
    case restoreSheepBaseline(ESheepCloudSheepBaselineRepairV2)
    case restoreRemoval(removalID: UUID, sheepID: UUID, revokedByCommandID: UUID,
                        sourceDigest: String, reason: String)
    case restoreBusinessBaseline(ESheepCloudBusinessBaselineRepairV2)
}

struct ESheepCloudSheepBaselineRepairV2: Codable, Sendable, Equatable {
    let sheepID: UUID
    let sourceDigest: String
    let legacyEarTag: String?
    let legacySourceKey: String?
    let purpose: String
    let isBreedingRam: Bool
    let status: SheepStatus
    let currentPenID: UUID?
    let removedAt: Date?
    let legacyStatusSnapshotIsAuthoritative: Bool
    let legacyPenSnapshotIsAuthoritative: Bool
    let damID: UUID?
    let sireID: UUID?
    let damProvenance: PedigreeRelationSource?
    let sireProvenance: PedigreeRelationSource?
}

enum ESheepCloudHistoryRepairProjection {
    static func apply(
        _ repair: ESheepCloudHistoryRepairCommandV2,
        event: ESheepCloudEventEnvelopeV2,
        context: ModelContext,
        replayContext: ESheepCloudProjectionReplayContext?
    ) throws -> RemoteApplyOutcome {
        guard event.stream.type == "migrationRepair" else {
            throw ESheepCloudContractError.malformedPayload
        }
        let index = replayContext ?? ESheepCloudProjectionReplayContext()
        func sheep(_ id: UUID) throws -> SheepRecord {
            guard let value = try index.sheep(id: id, context: context),
                  value.farmID == event.farmID, value.deletedAt == nil else {
                throw RemoteDomainApplyError.missingReference("historyRepair.sheepID")
            }
            return value
        }
        func validDigest(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }
        switch repair {
        case .restoreBusinessBaseline(let baseline):
            guard validDigest(baseline.sourceDigest) else {
                throw RemoteDomainApplyError.invalidPayload("historyRepair.sourceDigest")
            }
            return try ESheepCloudBusinessBaselineProjection.apply(
                baseline, event: event, context: context, index: index
            )
        case .restoreSheepBaseline(let baseline):
            guard validDigest(baseline.sourceDigest), !baseline.purpose.isEmpty,
                  baseline.damID != baseline.sheepID, baseline.sireID != baseline.sheepID,
                  baseline.damID == nil || baseline.damID != baseline.sireID,
                  baseline.status == .active || baseline.currentPenID == nil else {
                throw RemoteDomainApplyError.invalidPayload("historyRepair.baseline")
            }
            let target = try sheep(baseline.sheepID)
            if let id = baseline.damID { _ = try sheep(id) }
            if let id = baseline.sireID { _ = try sheep(id) }
            if let id = baseline.currentPenID {
                guard let pen = try index.pen(id: id, context: context),
                      pen.farmID == event.farmID, pen.deletedAt == nil else {
                    throw RemoteDomainApplyError.missingReference("historyRepair.currentPenID")
                }
            }
            guard !baseline.isBreedingRam || target.sex == .ram else {
                throw FarmCommandError.reproductionSireMustBeRam
            }
            // Retain historical qualification/provenance exactly. This is
            // restoration of a sourced baseline, not a newly inferred mating.
            target.legacyEarTag = baseline.legacyEarTag
            target.legacySourceKey = baseline.legacySourceKey
            target.purpose = baseline.purpose
            target.isBreedingRam = baseline.isBreedingRam
            target.damID = baseline.damID
            target.sireID = baseline.sireID
            target.damProvenanceRawValue = baseline.damProvenance?.rawValue
            target.sireProvenanceRawValue = baseline.sireProvenance?.rawValue
            target.legacyStatusSnapshotIsAuthoritative = baseline.legacyStatusSnapshotIsAuthoritative
            target.legacyPenSnapshotIsAuthoritative = baseline.legacyPenSnapshotIsAuthoritative
            // Non-authoritative status/location must still come from the
            // actual history ledger, including the separately restored deaths.
            if baseline.legacyStatusSnapshotIsAuthoritative {
                target.statusRawValue = baseline.status.rawValue
                target.removedAt = baseline.removedAt
            }
            if baseline.legacyPenSnapshotIsAuthoritative {
                target.currentPenID = baseline.currentPenID
            }
            if target.status != .active { target.currentPenID = nil }
            target.updatedAt = event.receivedAt
            return .applied(rebuildHistoryFrom: .distantPast)

        case .restoreRemoval(let removalID, let sheepID, let revokedByCommandID,
                             let sourceDigest, let reason):
            guard validDigest(sourceDigest), !reason.isEmpty else {
                throw RemoteDomainApplyError.invalidPayload("historyRepair.removal")
            }
            _ = try sheep(sheepID)
            let farmID = event.farmID
            let removals = try context.fetch(FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                $0.id == removalID && $0.farmID == farmID
            }))
            let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>(predicate: #Predicate {
                $0.operationID == revokedByCommandID && $0.farmID == farmID
            }))
            guard let removal = removals.first, removal.sheepID == sheepID,
                  removal.kind == .deceased,
                  let tombstone = tombstones.first,
                  tombstone.entityID == removalID,
                  tombstone.entityType == CloudEntityType.removal.rawValue else {
                throw RemoteDomainApplyError.missingReference("historyRepair.revokedRemoval")
            }
            removal.deletedAt = nil
            tombstone.restoredAt = event.receivedAt
            tombstone.restoredByOperationID = event.commandID
            return .applied(rebuildHistoryFrom: removal.occurredAt)
        }
    }
}
