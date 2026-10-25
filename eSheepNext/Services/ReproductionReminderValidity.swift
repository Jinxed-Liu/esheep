import Foundation

enum ReproductionReminderValidity {
    static func isRelevant(_ reminder: CareReminderRecord, state: ReproductionStateSnapshot?) -> Bool {
        guard reminder.kind == .pregnancyCheck || reminder.kind == .expectedLambing else { return true }
        guard let state else { return false }
        if reminder.kind == .expectedLambing {
            return state.pregnancy == .pregnant && state.check?.id == reminder.sourceEntityID
        }
        return state.pregnancy == .unexamined && state.check == nil && state.breeding != nil && state.associations.contains {
            $0.recordID == reminder.sourceEntityID && $0.roundID == state.breedingRoundID
        }
    }

    static func states(records: [ReproductionRecord], eweIDs: [UUID] = [], now: Date) -> [UUID: ReproductionStateSnapshot] {
        let groups = Dictionary(grouping: ReproductionCycleResolver.facts(records: records), by: \.eweID)
        var states = groups.mapValues { facts in ReproductionCycleResolver.resolve(eweID: facts[0].eweID, facts: facts, asOf: now) }
        for id in eweIDs where states[id] == nil { states[id] = ReproductionCycleResolver.resolve(eweID: id, facts: [], asOf: now) }
        return states
    }
}
