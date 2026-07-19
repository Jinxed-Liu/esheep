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
        let memberIDs = Set(members.map(\.id))
        var samples = weights.compactMap { record -> PenHerdWeightSample? in
            guard memberIDs.contains(record.sheepID) else { return nil }
            return PenHerdWeightSample(
                sheepID: record.sheepID,
                occurredAt: record.occurredAt,
                kilograms: NSDecimalNumber(decimal: record.kilograms).doubleValue,
                sourcePriority: 0
            )
        }
        samples.append(contentsOf: weanings.compactMap { record -> PenHerdWeightSample? in
            guard memberIDs.contains(record.sheepID) else { return nil }
            return PenHerdWeightSample(
                sheepID: record.sheepID,
                occurredAt: record.occurredAt,
                kilograms: NSDecimalNumber(decimal: record.weanWeight).doubleValue,
                sourcePriority: 1
            )
        })
        try Task.checkCancellation()
        return PenHerdInsightBuilder.insight(penName: penName, members: members, weightSamples: samples)
    }
}
