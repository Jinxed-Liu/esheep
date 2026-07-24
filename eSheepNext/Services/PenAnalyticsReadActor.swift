import Foundation
import SwiftData

struct PenHerdMemberSnapshot: Sendable, Hashable {
    let id: UUID
    let purpose: String
}

struct PenHerdWeightSample: Sendable, Hashable {
    let sheepID: UUID
    let occurredAt: Date
    let kilograms: Double
    let sourcePriority: Int
}

enum PenHerdInsightBuilder {
    static func insight(
        penName: String,
        members: [PenHerdMemberSnapshot],
        weightSamples: [PenHerdWeightSample] = []
    ) -> FarmInsight {
        let purposeRows = Dictionary(grouping: members, by: \.purpose)
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }
            .map { "\($0.key)：\($0.value.count)只" }

        let memberIDs = Set(members.map(\.id))
        var latestBySheep: [UUID: PenHerdWeightSample] = [:]
        for sample in weightSamples where memberIDs.contains(sample.sheepID) {
            guard let current = latestBySheep[sample.sheepID] else {
                latestBySheep[sample.sheepID] = sample
                continue
            }
            if sample.occurredAt > current.occurredAt
                || (sample.occurredAt == current.occurredAt && sample.sourcePriority < current.sourcePriority) {
                latestBySheep[sample.sheepID] = sample
            }
        }

        var details = ["在群 \(members.count) 只"] + purposeRows
        let latestWeights = latestBySheep.values.map(\.kilograms)
        if !latestWeights.isEmpty {
            let average = latestWeights.reduce(0, +) / Double(latestWeights.count)
            details.append("平均体重：\(String(format: "%.1f", average))kg")
        }
        return FarmInsight(
            title: "圈舍分析",
            summary: "\(penName) 在群\(members.count)只",
            details: details
        )
    }
}

actor PenAnalyticsReadActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func insight(
        farmID: UUID,
        penName: String,
        members: [PenHerdMemberSnapshot]
    ) throws -> FarmInsight {
        guard !members.isEmpty else {
            return PenHerdInsightBuilder.insight(penName: penName, members: members)
        }

        try Task.checkCancellation()
        let context = ModelContext(container)
        let weights = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let weanings = try context.fetch(FetchDescriptor<WeaningRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let birthDetails = try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil && $0.deletedByLambingRevocation == false
        }))
        let lambings = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).filter { $0.kind == .lambing }
        let lambingDateByID = Dictionary(uniqueKeysWithValues: lambings.map { ($0.id, $0.occurredAt) })
        let memberIDs = Set(members.map(\.id))
        var unifiedSamples = weights.compactMap { record -> SheepWeightSample? in
            guard memberIDs.contains(record.sheepID) else { return nil }
            return SheepWeightSample(
                id: record.id,
                sheepID: record.sheepID,
                kilogramsText: record.kilogramsText,
                kilograms: NSDecimalNumber(decimal: record.kilograms).doubleValue,
                occurredAt: record.occurredAt,
                source: record.note == "初生重" ? .lambingBirth : .weighing
            )
        }
        for record in weanings where memberIDs.contains(record.sheepID) {
            unifiedSamples.append(SheepWeightSample(
                id: StableCloudUUID.derived(namespace: record.id, name: "weight-sample-weaning"),
                sheepID: record.sheepID,
                kilogramsText: record.weanWeightText,
                kilograms: NSDecimalNumber(decimal: record.weanWeight).doubleValue,
                occurredAt: record.occurredAt,
                source: .weaning
            ))
            if let birthAt = record.birthAt,
               let birthWeightText = record.birthWeightText,
               let birthWeight = Decimal.stable(birthWeightText) {
                unifiedSamples.append(SheepWeightSample(
                    id: StableCloudUUID.derived(namespace: record.id, name: "weight-sample-weaning-birth"),
                    sheepID: record.sheepID,
                    kilogramsText: birthWeightText,
                    kilograms: NSDecimalNumber(decimal: birthWeight).doubleValue,
                    occurredAt: birthAt,
                    source: .weaningBirth
                ))
            }
        }
        for detail in birthDetails {
            guard let sheepID = detail.sheepID,
                  memberIDs.contains(sheepID),
                  let occurredAt = lambingDateByID[detail.lambingRecordID],
                  let birthWeight = Decimal.stable(detail.birthWeightText) else { continue }
            unifiedSamples.append(SheepWeightSample(
                id: StableCloudUUID.derived(namespace: detail.id, name: "weight-sample-lambing-birth"),
                sheepID: sheepID,
                kilogramsText: detail.birthWeightText,
                kilograms: NSDecimalNumber(decimal: birthWeight).doubleValue,
                occurredAt: occurredAt,
                source: .lambingBirth
            ))
        }
        let samples = SheepWeightSampleBuilder.dailyCanonical(unifiedSamples).map { sample in
            PenHerdWeightSample(
                sheepID: sample.sheepID,
                occurredAt: sample.occurredAt,
                kilograms: sample.kilograms,
                sourcePriority: sample.source.rawValue
            )
        }
        try Task.checkCancellation()
        return PenHerdInsightBuilder.insight(penName: penName, members: members, weightSamples: samples)
    }
}
