import Foundation
import SwiftData

struct SheepDetailSubjectSnapshot: Sendable, Hashable {
    let id: UUID
    let earTag: String
    let breed: String
    let purpose: String
    let sex: SheepSex
    let status: SheepStatus
    let initialPenID: UUID?
    let currentPenID: UUID?
    let birthAt: Date?
    let enteredAt: Date
    let removedAt: Date?

    var analyticsValue: FarmAnalyticsSnapshot.Sheep {
        FarmAnalyticsSnapshot.Sheep(
            id: id,
            earTag: earTag,
            breed: breed,
            purpose: purpose,
            sex: sex,
            status: status,
            initialPenID: initialPenID,
            currentPenID: currentPenID,
            birthAt: birthAt,
            enteredAt: enteredAt,
            removedAt: removedAt
        )
    }
}

struct SheepDetailWeightSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let kilogramsText: String
    let kilograms: Double
    let occurredAt: Date
}

struct SheepDetailPhotoSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let sha256: String
    let capturedAt: Date?
    let createdAt: Date

    var displayedAt: Date { capturedAt ?? createdAt }
}

struct SheepDetailTimelineEntry: Identifiable, Sendable, Hashable {
    let id: UUID
    let title: String
    let detail: String
    let date: Date
}

struct SheepDetailSnapshot: Sendable {
    let weights: [SheepDetailWeightSnapshot]
    let photos: [SheepDetailPhotoSnapshot]
    let timeline: [SheepDetailTimelineEntry]
    let lifecycleInsight: FarmInsight
    let reproductionInsight: FarmInsight
}

/// Reads every secondary detail-page collection off the SwiftUI render path.
///
/// `@Query` performs a synchronous fetch when its value is read. Reading several
/// query-backed arrays from `View.body` caused navigation updates to repeatedly
/// scan the production store. This actor performs one bounded read and returns
/// immutable values, so a navigation tap never starts another SwiftData fetch.
actor SheepDetailSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(
        farmID: UUID,
        sheepID: UUID,
        subject: SheepDetailSubjectSnapshot
    ) throws -> SheepDetailSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)

        let weights = try context.fetch(FetchDescriptor<WeightRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\WeightRecord.occurredAt, order: .reverse)]
        ))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\TransferRecord.occurredAt, order: .reverse)]
        ))
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.eweID == sheepID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\ReproductionRecord.occurredAt, order: .reverse)]
        ))
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\PhotoAssetRecord.createdAt, order: .reverse)]
        ))
        let healthLinks = try context.fetch(FetchDescriptor<HealthSubjectLink>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        let linkedHealthIDs = Set(healthLinks.map(\.healthRecordID))
        let health = try context.fetch(FetchDescriptor<HealthRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).filter { record in
            record.sheepID == sheepID || linkedHealthIDs.contains(record.id)
        }
        try Task.checkCancellation()

        let weightValues = weights.map { record in
            SheepDetailWeightSnapshot(
                id: record.id,
                kilogramsText: record.kilogramsText,
                kilograms: NSDecimalNumber(decimal: record.kilograms).doubleValue,
                occurredAt: record.occurredAt
            )
        }
        let photoValues = photos.map { record in
            SheepDetailPhotoSnapshot(
                id: record.id,
                sha256: record.sha256,
                capturedAt: record.capturedAt,
                createdAt: record.createdAt
            )
        }.sorted { $0.displayedAt > $1.displayedAt }

        var timeline = weightValues.map {
            SheepDetailTimelineEntry(id: $0.id, title: "称重", detail: "\($0.kilogramsText) 千克", date: $0.occurredAt)
        }
        timeline.append(contentsOf: transfers.map {
            SheepDetailTimelineEntry(id: $0.id, title: "转群", detail: $0.note, date: $0.occurredAt)
        })
        timeline.append(contentsOf: health.map {
            SheepDetailTimelineEntry(
                id: $0.id,
                title: $0.kindRawValue == HealthRecordKind.vaccination.rawValue ? "疫苗" : "治疗",
                detail: $0.itemNameSnapshot,
                date: $0.occurredAt
            )
        })
        timeline.append(contentsOf: reproduction.map {
            SheepDetailTimelineEntry(
                id: $0.id,
                title: ReproductionRecordKind(rawValue: $0.kindRawValue)?.displayName ?? "繁殖",
                detail: $0.note,
                date: $0.occurredAt
            )
        })
        timeline.append(contentsOf: photoValues.map {
            SheepDetailTimelineEntry(id: $0.id, title: "照片", detail: "新增羊只影像", date: $0.displayedAt)
        })
        timeline.sort { $0.date > $1.date }

        let analyticsSnapshot = FarmAnalyticsSnapshot(
            farmID: farmID,
            sheep: [subject.analyticsValue],
            pens: [],
            weights: weightValues.map {
                FarmAnalyticsSnapshot.Weight(id: $0.id, sheepID: sheepID, kilograms: $0.kilograms, occurredAt: $0.occurredAt)
            },
            weanings: [],
            lambings: reproduction.compactMap { record in
                guard record.kind == .lambing else { return nil }
                return FarmAnalyticsSnapshot.Lambing(
                    id: record.id,
                    eweID: record.eweID,
                    occurredAt: record.occurredAt,
                    total: record.lambCount,
                    parity: record.parity,
                    birthDeadCount: record.birthDeadCount,
                    offspring: []
                )
            },
            removals: [],
            transfers: [],
            batchMemberships: [],
            feeds: []
        )
        return SheepDetailSnapshot(
            weights: weightValues,
            photos: photoValues,
            timeline: timeline,
            lifecycleInsight: SheepAnalyticsEngine.lifecycle(sheepID: sheepID, snapshot: analyticsSnapshot),
            reproductionInsight: SheepAnalyticsEngine.reproduction(sheepID: sheepID, snapshot: analyticsSnapshot)
        )
    }

    func singleSheepXLSXData(
        farmID: UUID,
        sheepID: UUID,
        penName: String?
    ) throws -> Data {
        try Task.checkCancellation()
        let context = ModelContext(container)
        guard let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.id == sheepID && $0.deletedAt == nil
        })).first else {
            throw SheepDetailSnapshotError.sheepNotFound
        }
        let weights = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
        }))
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.eweID == sheepID && $0.deletedAt == nil
        }))
        let healthLinks = try context.fetch(FetchDescriptor<HealthSubjectLink>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        let linkedHealthIDs = Set(healthLinks.map(\.healthRecordID))
        let health = try context.fetch(FetchDescriptor<HealthRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).filter { record in
            record.sheepID == sheepID || linkedHealthIDs.contains(record.id)
        }
        let allSheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let donors = try context.fetch(FetchDescriptor<SemenDonorRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        try Task.checkCancellation()
        return try FarmDataInterchange.singleSheepXLSXData(
            sheep: sheep,
            penName: penName,
            weights: weights,
            health: health,
            healthRecordIDs: Set(health.map(\.id)),
            reproduction: reproduction,
            transfers: transfers,
            allSheep: allSheep,
            semenDonors: donors
        )
    }
}

enum SheepDetailSnapshotError: LocalizedError {
    case sheepNotFound

    var errorDescription: String? {
        switch self {
        case .sheepNotFound: "羊只档案不存在或已被撤销。"
        }
    }
}
