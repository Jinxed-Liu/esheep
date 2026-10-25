import Foundation
import SwiftData

/// Runs before applying and signing a local command. Every entry surface,
/// including assistant tools, therefore persists the exact same association
/// that remote replay receives. Authoritative historical replay is unchanged.
enum ReproductionCommandNormalizer {
    static func normalize(_ command: FarmCommand, farmID: UUID, context: ModelContext) throws -> FarmCommand {
        guard case .care(let care) = command else { return command }
        switch care {
        case .recordReproductionBatch, .correctReproduction, .recordLambing, .correctLambing: break
        default: return command
        }
        let records = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate { $0.farmID == farmID }))
        func batch(_ draft: CareReproductionBatchDraft, originalID: UUID? = nil) throws -> CareReproductionBatchDraft {
            let original = originalID.flatMap { id in records.first { $0.id == id } }
            let subjects = try draft.subjects.map { subject in
                let recordID = StableCloudUUID.derived(namespace: draft.id, name: subject.id.uuidString.lowercased())
                let intent = subject.breedingIntent ?? original?.breedingIntentRawValue.flatMap(BreedingIntent.init(rawValue:))
                let relatedID = subject.relatedBreedingRecordID ?? (subject.reproductionCycleID == nil ? original?.relatedBreedingRecordID : nil)
                let round = subject.breedingRoundID ?? original?.breedingRoundID ?? (original?.kind == .breeding ? original?.id : nil)
                let value = try ReproductionEntryAssociation.resolve(eweID: subject.eweID, recordID: recordID,
                    kind: draft.kind, occurredAt: draft.occurredAt, records: records, relatedID: relatedID, intent: intent,
                    expectedCycleID: subject.reproductionCycleID ?? original?.reproductionCycleID,
                    expectedRoundID: round, excludingID: originalID)
                return CareReproductionSubjectDraft(id: subject.id, eweID: subject.eweID, result: subject.result,
                    relatedBreedingRecordID: relatedID, reproductionCycleID: value.cycleID,
                    breedingRoundID: value.roundID, breedingIntent: intent)
            }
            return CareReproductionBatchDraft(id: draft.id, kind: draft.kind, subjects: subjects, occurredAt: draft.occurredAt,
                sireID: draft.sireID, semenID: draft.semenID, semenUnitsPerEweText: draft.semenUnitsPerEweText,
                note: draft.note, reminderAt: draft.reminderAt)
        }
        func lambing(_ draft: CareLambingDraft, originalID: UUID? = nil) throws -> CareLambingDraft {
            let original = originalID.flatMap { id in records.first { $0.id == id } }
            let draft = draft.preservingReproductionAssociation(from: original)
            let value = try ReproductionEntryAssociation.resolve(eweID: draft.eweID, recordID: draft.id, kind: .lambing,
                occurredAt: draft.occurredAt, records: records, relatedID: draft.relatedBreedingRecordID,
                intent: nil, expectedCycleID: draft.reproductionCycleID ?? original?.reproductionCycleID,
                expectedRoundID: draft.breedingRoundID ?? original?.breedingRoundID, excludingID: originalID ?? draft.id)
            return CareLambingDraft(id: draft.id, eweID: draft.eweID, occurredAt: draft.occurredAt,
                sireID: draft.sireID, semenID: draft.semenID, relatedBreedingRecordID: draft.relatedBreedingRecordID,
                reproductionCycleID: value.cycleID, breedingRoundID: value.roundID, parity: draft.parity,
                birthDeadCount: draft.birthDeadCount, offspring: draft.offspring, penID: draft.penID, note: draft.note)
        }
        switch care {
        case .recordReproductionBatch(let value):
            if records.contains(where: { $0.batchID == value.id }) { return command }
            return .care(.recordReproductionBatch(try batch(value)))
        case .correctReproduction(let id, let value, let reason):
            return .care(.correctReproduction(originalID: id, replacement: try batch(value, originalID: id), reason: reason))
        case .recordLambing(let value):
            if records.contains(where: { $0.id == value.id }) { return command }
            return .care(.recordLambing(try lambing(value)))
        case .correctLambing(let id, let value, let reason):
            return .care(.correctLambing(originalID: id, replacement: try lambing(value, originalID: id), reason: reason))
        default: return command
        }
    }
}
