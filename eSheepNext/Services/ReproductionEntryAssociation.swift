import Foundation

/// Shared by forms, import and command validation. No business write occurs here.
enum ReproductionEntryAssociation {
    struct Value {
        let cycleID: UUID
        let roundID: UUID?
    }

    static func resolve(eweID: UUID, recordID: UUID, kind: ReproductionRecordKind, occurredAt: Date,
                        records: [ReproductionRecord], relatedID: UUID?, intent: BreedingIntent?,
                        expectedCycleID: UUID? = nil, expectedRoundID: UUID? = nil,
                        excludingID: UUID? = nil, requiresExplicitRound: Bool = false) throws -> Value {
        let facts = ReproductionCycleResolver.facts(records: records.filter { $0.id != excludingID })
        let state = ReproductionCycleResolver.resolve(eweID: eweID, facts: facts, asOf: occurredAt)
        if let expectedCycleID, expectedCycleID != state.cycleID {
            throw FarmCommandError.missingRequiredValue("繁殖周期已变更，请重新核对胎次和关联")
        }
        var roundID: UUID?
        if let relatedID {
            guard let related = facts.first(where: { $0.id == relatedID && $0.eweID == eweID && $0.kind == .breeding }),
                  related.occurredAt < occurredAt,
                  !facts.contains(where: { $0.eweID == eweID && ($0.kind == .lambing || $0.kind == .abortion) && $0.occurredAt >= related.occurredAt && $0.occurredAt <= occurredAt }) else {
                throw FarmCommandError.missingRequiredValue("关联配种不属于该发生时间的有效周期")
            }
            roundID = related.breedingRoundID ?? related.id
        }
        if kind == .breeding {
            if intent == .supplement {
                guard roundID != nil else { throw FarmCommandError.missingRequiredValue("本轮补配必须选择关联配种") }
            } else if intent == .newRound {
                guard relatedID == nil else { throw FarmCommandError.missingRequiredValue("新一轮配种不能关联上一轮配种") }
                roundID = expectedRoundID ?? recordID
            } else { roundID = expectedRoundID }
        } else if roundID == nil {
            let roots = Set(state.associations.compactMap(\.roundID))
            if roots.count == 1 { roundID = roots.first }
            else if roots.count > 1 && requiresExplicitRound { throw FarmCommandError.missingRequiredValue("存在多个配种轮次，请明确选择关联配种") }
        }
        if let expectedRoundID, roundID != expectedRoundID {
            throw FarmCommandError.missingRequiredValue("配种轮次已变更，请重新核对关联")
        }
        return Value(cycleID: state.cycleID, roundID: roundID)
    }
}

extension CareLambingDraft {
    /// Old writers omit all cycle metadata. They must not erase an association
    /// confirmed by a newer writer. An explicit cycle permits deliberate clearing.
    func preservingReproductionAssociation(from original: ReproductionRecord?) -> CareLambingDraft {
        guard let original else { return self }
        return CareLambingDraft(id: id, eweID: eweID, occurredAt: occurredAt, sireID: sireID, semenID: semenID,
            relatedBreedingRecordID: relatedBreedingRecordID ?? (reproductionCycleID == nil ? original.relatedBreedingRecordID : nil),
            reproductionCycleID: reproductionCycleID ?? original.reproductionCycleID,
            breedingRoundID: reproductionCycleID == nil ? original.breedingRoundID : breedingRoundID,
            breedingIntent: breedingIntent ?? original.breedingIntentRawValue.flatMap(BreedingIntent.init(rawValue:)),
            parity: parity, birthDeadCount: birthDeadCount, offspring: offspring, penID: penID, note: note)
    }
}
