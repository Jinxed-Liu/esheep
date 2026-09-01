import Foundation
import SwiftData

struct SheepDetailSubjectSnapshot: Sendable, Hashable {
    let id: UUID
    let earTag: String
    let breed: String
    let purpose: String
    let sex: SheepSex
    let status: SheepStatus
    let isHistoricalArchive: Bool
    let initialPenID: UUID?
    let currentPenID: UUID?
    let birthAt: Date?
    let enteredAt: Date
    let removedAt: Date?
    let note: String

    init(
        id: UUID,
        earTag: String,
        breed: String,
        purpose: String,
        sex: SheepSex,
        status: SheepStatus,
        isHistoricalArchive: Bool = false,
        initialPenID: UUID?,
        currentPenID: UUID?,
        birthAt: Date?,
        enteredAt: Date,
        removedAt: Date?,
        note: String = ""
    ) {
        self.id = id
        self.earTag = earTag
        self.breed = breed
        self.purpose = purpose
        self.sex = sex
        self.status = status
        self.isHistoricalArchive = isHistoricalArchive
        self.initialPenID = initialPenID
        self.currentPenID = currentPenID
        self.birthAt = birthAt
        self.enteredAt = enteredAt
        self.removedAt = removedAt
        self.note = note
    }

    init(record: SheepRecord) {
        self.init(
            id: record.id,
            earTag: record.earTag,
            breed: record.breed,
            purpose: record.purpose,
            sex: record.sex,
            status: record.status,
            isHistoricalArchive: record.isHistoricalArchive,
            initialPenID: record.initialPenID,
            currentPenID: record.currentPenID,
            birthAt: record.birthAt,
            enteredAt: record.enteredAt,
            removedAt: record.removedAt,
            note: record.note
        )
    }

    var isCurrentlyPresent: Bool {
        status == .active && !isHistoricalArchive
    }

    func currentPenDisplayName(_ penName: String?) -> String {
        isCurrentlyPresent ? (penName ?? "未分圈") : "已离群"
    }

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

struct SheepDetailEntrySnapshot: Sendable, Hashable {
    let subject: SheepDetailSubjectSnapshot
    let penName: String?
    let avatarPhoto: SheepPhotoReference?
}

struct SheepDetailWeightSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let kilogramsText: String
    let kilograms: Double
    let occurredAt: Date
    let source: SheepWeightSource
}

struct SheepDetailWeightGainSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let startKilogramsText: String
    let endKilogramsText: String
    let intervalDays: Int
    let kilogramsPerDay: Double
}

enum SheepDetailWeightGainBuilder {
    static func intervals(from samples: [SheepWeightSample]) -> [SheepDetailWeightGainSnapshot] {
        let canonical = SheepWeightSampleBuilder.dailyCanonical(samples)
        return zip(canonical, canonical.dropFirst()).compactMap { previous, current in
            let intervalDays = FarmAnalyticsDate.days(from: previous.occurredAt, to: current.occurredAt)
            guard intervalDays > 0 else { return nil }
            return SheepDetailWeightGainSnapshot(
                id: current.id,
                startDate: previous.occurredAt,
                endDate: current.occurredAt,
                startKilogramsText: previous.kilogramsText,
                endKilogramsText: current.kilogramsText,
                intervalDays: intervalDays,
                kilogramsPerDay: (current.kilograms - previous.kilograms) / Double(intervalDays)
            )
        }
    }
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
    let weightGainIntervals: [SheepDetailWeightGainSnapshot]
    let photos: [SheepDetailPhotoSnapshot]
    let purposeTimeline: [SheepPurposeTimelineFact]
    let timeline: [SheepDetailTimelineEntry]
    let currentParity: Int?
    let lifecycleInsight: FarmInsight
    let reproductionInsight: FarmInsight
}

struct SheepDetailScreenSnapshot: Sendable {
    let entry: SheepDetailEntrySnapshot
    let detail: SheepDetailSnapshot?
    let detailLoadErrorDescription: String?
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

    /// Resolves a sheep navigation destination once, outside `View.body`.
    ///
    /// A live `@Query` in the navigation stack refetched this row on every
    /// SwiftUI graph update and could keep the main thread in a render loop.
    func loadEntry(farmID: UUID, sheepID: UUID) throws -> SheepDetailEntrySnapshot? {
        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let record = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.id == sheepID && $0.farmID == farmID && $0.deletedAt == nil
        })).first else {
            return nil
        }
        let subject = SheepDetailSubjectSnapshot(record: record)
        let penName: String?
        if let penID = subject.currentPenID {
            penName = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
                $0.id == penID && $0.farmID == farmID && $0.deletedAt == nil
            })).first?.name
        } else {
            penName = nil
        }
        let avatarPhoto = try SheepAvatarSelectionStore.reference(
            sheepID: sheepID,
            farmID: farmID,
            context: context
        )
        try Task.checkCancellation()
        return SheepDetailEntrySnapshot(
            subject: subject,
            penName: penName,
            avatarPhoto: avatarPhoto
        )
    }

    /// Loads the stable navigation landing state before SwiftUI constructs the
    /// detail list. This prevents large record sections from being inserted
    /// while the user has already started scrolling.
    func loadScreen(farmID: UUID, sheepID: UUID) throws -> SheepDetailScreenSnapshot? {
        guard let entry = try loadEntry(farmID: farmID, sheepID: sheepID) else {
            return nil
        }
        do {
            let detail = try load(
                farmID: farmID,
                sheepID: sheepID,
                subject: entry.subject
            )
            return SheepDetailScreenSnapshot(
                entry: entry,
                detail: detail,
                detailLoadErrorDescription: nil
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            return SheepDetailScreenSnapshot(
                entry: entry,
                detail: nil,
                detailLoadErrorDescription: error.localizedDescription
            )
        }
    }

    func load(
        farmID: UUID,
        sheepID: UUID,
        subject: SheepDetailSubjectSnapshot
    ) throws -> SheepDetailSnapshot {
        let interval = PerformanceTrace.begin(.sheepDetailLoad)
        defer { PerformanceTrace.end(interval) }

        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let weights = try context.fetch(FetchDescriptor<WeightRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\WeightRecord.occurredAt, order: .reverse)]
        ))
        let weanings = try context.fetch(FetchDescriptor<WeaningRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\WeaningRecord.occurredAt, order: .reverse)]
        ))
        let birthDetails = try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID && $0.deletedAt == nil && $0.deletedByLambingRevocation == false
        }))
        var birthDateByLambingID: [UUID: Date] = [:]
        for lambingID in Set(birthDetails.map(\.lambingRecordID)) {
            let targetID = lambingID
            if let record = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.id == targetID && $0.deletedAt == nil
            })).first, record.kind == .lambing {
                birthDateByLambingID[lambingID] = record.occurredAt
            }
        }
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
        let purposeOperations = try context.fetch(FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.farmID == farmID && $0.entityID == sheepID
        }))
        let purposeTimeline = SheepPurposeTimeline.facts(from: purposeOperations)
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                return $0.id.uuidString > $1.id.uuidString
            }
        let health = try healthRecords(
            context: context,
            farmID: farmID,
            sheepID: sheepID
        )
        try Task.checkCancellation()

        var weightSamples = weights.map { record in
            SheepWeightSample(
                id: record.id,
                sheepID: record.sheepID,
                kilogramsText: record.kilogramsText,
                kilograms: NSDecimalNumber(decimal: record.kilograms).doubleValue,
                occurredAt: record.occurredAt,
                source: record.note == "初生重" ? .lambingBirth : .weighing
            )
        }
        for record in weanings {
            weightSamples.append(SheepWeightSample(
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
                weightSamples.append(SheepWeightSample(
                    id: StableCloudUUID.derived(namespace: record.id, name: "weight-sample-weaning-birth"),
                    sheepID: record.sheepID,
                    kilogramsText: birthWeightText,
                    kilograms: NSDecimalNumber(decimal: birthWeight).doubleValue,
                    occurredAt: birthAt,
                    source: .weaningBirth
                ))
            }
        }
        let fallbackBirthAt = subject.birthAt ?? weanings.compactMap(\.birthAt).min()
        for detail in birthDetails {
            guard let occurredAt = birthDateByLambingID[detail.lambingRecordID] ?? fallbackBirthAt,
                  let birthWeight = Decimal.stable(detail.birthWeightText) else { continue }
            weightSamples.append(SheepWeightSample(
                id: StableCloudUUID.derived(namespace: detail.id, name: "weight-sample-lambing-birth"),
                sheepID: sheepID,
                kilogramsText: detail.birthWeightText,
                kilograms: NSDecimalNumber(decimal: birthWeight).doubleValue,
                occurredAt: occurredAt,
                source: .lambingBirth
            ))
        }
        let weightValues = SheepWeightSampleBuilder.deduplicatingEquivalentFacts(weightSamples).reversed().map { sample in
            SheepDetailWeightSnapshot(
                id: sample.id,
                kilogramsText: sample.kilogramsText,
                kilograms: sample.kilograms,
                occurredAt: sample.occurredAt,
                source: sample.source
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
            SheepDetailTimelineEntry(id: $0.id, title: $0.source.displayName, detail: "\(WeightPrecision.displayText($0.kilogramsText)) 千克", date: $0.occurredAt)
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
            weightGainIntervals: SheepDetailWeightGainBuilder.intervals(from: weightSamples),
            photos: photoValues,
            purposeTimeline: purposeTimeline,
            timeline: timeline,
            currentParity: LambingEntrySemantics.currentParity(
                eweID: sheepID,
                farmID: farmID,
                before: .distantFuture,
                records: reproduction
            ),
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
        context.autosaveEnabled = false
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
        let health = try healthRecords(
            context: context,
            farmID: farmID,
            sheepID: sheepID
        )
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

    private func healthRecords(
        context: ModelContext,
        farmID: UUID,
        sheepID: UUID
    ) throws -> [HealthRecord] {
        let direct = try context.fetch(FetchDescriptor<HealthRecord>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.sheepID == sheepID &&
                $0.deletedAt == nil
        }))
        let links = try context.fetch(FetchDescriptor<HealthSubjectLink>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        var recordsByID = Dictionary(uniqueKeysWithValues: direct.map { ($0.id, $0) })
        for healthID in Set(links.map(\.healthRecordID)) where recordsByID[healthID] == nil {
            let targetID = healthID
            var descriptor = FetchDescriptor<HealthRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.id == targetID && $0.deletedAt == nil
            })
            descriptor.fetchLimit = 1
            if let linked = try context.fetch(descriptor).first {
                recordsByID[linked.id] = linked
            }
        }
        return recordsByID.values.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id.uuidString < $1.id.uuidString
        }
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
