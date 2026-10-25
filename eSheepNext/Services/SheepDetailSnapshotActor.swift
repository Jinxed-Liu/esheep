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
            removedAt: removedAt,
            isHistoricalArchive: isHistoricalArchive
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
    var startSource: SheepWeightSource = .weighing
    var endSource: SheepWeightSource = .weighing
    var totalGainKilograms: Double { kilogramsPerDay * Double(intervalDays) }
}

enum SheepDetailWeightGainBuilder {
    static func intervals(from samples: [SheepWeightSample], calendar: Calendar = FarmAnalyticsDate.calendar) -> [SheepDetailWeightGainSnapshot] {
        let canonical = SheepWeightSampleBuilder.dailyCanonical(samples, calendar: calendar)
        return zip(canonical, canonical.dropFirst()).compactMap { previous, current in
            let intervalDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: previous.occurredAt), to: calendar.startOfDay(for: current.occurredAt)).day ?? 0
            guard intervalDays > 0 else { return nil }
            return SheepDetailWeightGainSnapshot(
                id: current.id,
                startDate: previous.occurredAt,
                endDate: current.occurredAt,
                startKilogramsText: previous.kilogramsText,
                endKilogramsText: current.kilogramsText,
                intervalDays: intervalDays,
                kilogramsPerDay: (current.kilograms - previous.kilograms) / Double(intervalDays),
                startSource: previous.source, endSource: current.source
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
    var reproductionState: ReproductionStateSnapshot?
    var canonicalWeights: [SheepDetailWeightSnapshot] = []
    var timeZoneIdentifier: String = "Asia/Shanghai"
    var factsReadAt: Date = .now
    var managementSettings: ReproductionManagementSettings = .init()
    var gestationDays: Int = 150
    var weanedAt: Date?
    var fatteningStartedAt: Date?
    var recordedBreedingCount: Int = 0
    var recordedOffspringCount: Int = 0
    var isPreBreedingLamb = false
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
        let factsReadAt = Date.now
        let farm = try context.fetch(FetchDescriptor<FarmRecord>(predicate: #Predicate { $0.id == farmID })).first
        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: farm?.timeZoneIdentifier ?? "Asia/Shanghai") else { throw FarmCommandError.invalidFarmTimeZone }
        calendar.timeZone = timeZone
        let rules = try context.fetch(FetchDescriptor<FarmCareRuleRecord>(predicate: #Predicate { $0.farmID == farmID })).first
        let settings = try ReproductionManagementSettings.decode(rules?.reproductionSettingsJSON) ?? .init()

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
        let birthDetailsPredicate = Predicate<LambingOffspringRecord> { offspring in
            let farmMatches = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: offspring, keyPath: \LambingOffspringRecord.farmID),
                rhs: PredicateExpressions.build_Arg(farmID)
            )
            let sheepMatches = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: offspring, keyPath: \LambingOffspringRecord.sheepID),
                rhs: PredicateExpressions.build_Arg(Optional<UUID>.some(sheepID))
            )
            let isNotDeleted = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: offspring, keyPath: \LambingOffspringRecord.deletedAt),
                rhs: PredicateExpressions.NilLiteral<Date>()
            )
            let isNotRevoked = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: offspring, keyPath: \LambingOffspringRecord.deletedByLambingRevocation),
                rhs: PredicateExpressions.build_Arg(false)
            )
            let scopeMatches = PredicateExpressions.build_Conjunction(lhs: farmMatches, rhs: sheepMatches)
            let presentScopeMatches = PredicateExpressions.build_Conjunction(lhs: scopeMatches, rhs: isNotDeleted)
            return PredicateExpressions.build_Conjunction(lhs: presentScopeMatches, rhs: isNotRevoked)
        }
        let birthDetailsDescriptor = FetchDescriptor<LambingOffspringRecord>(predicate: birthDetailsPredicate)
        let birthDetails: [LambingOffspringRecord] = try context.fetch(birthDetailsDescriptor)
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
        let recordedBreedingCount: Int
        let recordedOffspringCount: Int
        if subject.sex == .ram {
            recordedBreedingCount = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.sireID == sheepID && $0.kindRawValue == "breeding" && $0.deletedAt == nil && $0.occurredAt <= factsReadAt
            })).count
            recordedOffspringCount = try context.fetchCount(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.farmID == farmID && $0.sireID == sheepID && $0.deletedAt == nil
            }))
        } else { recordedBreedingCount = 0; recordedOffspringCount = 0 }
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
        weightSamples = weightSamples.filter { $0.occurredAt <= factsReadAt }
        let canonicalWeights = SheepWeightSampleBuilder.dailyCanonical(weightSamples, calendar: calendar).map {
            SheepDetailWeightSnapshot(id: $0.id, kilogramsText: $0.kilogramsText, kilograms: $0.kilograms, occurredAt: $0.occurredAt, source: $0.source)
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
        timeline.append(contentsOf: purposeTimeline.map { SheepDetailTimelineEntry(id: $0.id, title: "用途变更", detail: $0.transitionText, date: $0.occurredAt) })
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
            feeds: [], timeZoneIdentifier: timeZone.identifier, factsReadAt: factsReadAt,
            reproductionFacts: ReproductionCycleResolver.facts(records: reproduction)
        )
        let cycle = subject.sex == .ewe ? ReproductionCycleResolver.resolve(eweID: sheepID, snapshot: analyticsSnapshot) : nil
        let currentPurposeStart = purposeTimeline.last(where: { $0.occurredAt <= factsReadAt })
        return SheepDetailSnapshot(
            weights: weightValues,
            weightGainIntervals: SheepDetailWeightGainBuilder.intervals(from: weightSamples, calendar: calendar),
            photos: photoValues,
            purposeTimeline: purposeTimeline,
            timeline: timeline,
            currentParity: cycle?.completedParity,
            lifecycleInsight: SheepAnalyticsEngine.lifecycle(sheepID: sheepID, snapshot: analyticsSnapshot),
            reproductionInsight: SheepAnalyticsEngine.reproduction(sheepID: sheepID, snapshot: analyticsSnapshot),
            reproductionState: cycle, canonicalWeights: canonicalWeights, timeZoneIdentifier: timeZone.identifier,
            factsReadAt: factsReadAt, managementSettings: settings, gestationDays: rules?.gestationDays ?? 150,
            weanedAt: weanings.filter { $0.occurredAt <= factsReadAt }.map(\.occurredAt).max(),
            fatteningStartedAt: currentPurposeStart?.purpose == .fattening ? currentPurposeStart?.occurredAt : nil,
            recordedBreedingCount: recordedBreedingCount, recordedOffspringCount: recordedOffspringCount,
            isPreBreedingLamb: subject.sex == .ewe && ReproductionReviewPolicy.isPreBreedingLamb(
                purpose: subject.purpose, birthAt: subject.birthAt, removedAt: subject.removedAt,
                hasReproductionFacts: reproduction.contains { $0.occurredAt <= factsReadAt },
                asOf: factsReadAt, timeZoneIdentifier: timeZone.identifier, minimumAgeMonths: settings.minimumAgeMonths)
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
            semenDonors: donors,
            detail: try load(farmID: farmID, sheepID: sheepID, subject: SheepDetailSubjectSnapshot(record: sheep))
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
