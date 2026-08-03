import Foundation
import SwiftData
#if canImport(CoreML)
import CoreML
#endif

struct PedigreeSireCandidate: Identifiable, Sendable, Equatable {
    var id: UUID { ramID }
    let ramID: UUID
    let earTag: String
    let breed: String
    /// 按牧场标准妊娠天数得到的基准受胎日。
    let conceptionAt: Date
    /// 在早产容差窗口内，母羊与该种公羊最早出现同舍证据的日期。
    let matchedAt: Date
    let candidateWindowEndAt: Date
    let inferredGestationDays: Int
    let prematurityAllowanceDays: Int
    let historicalPenID: UUID
    let historicalPenName: String?
    let rankingScore: Double
    let isConfirmedBreedingRam: Bool
    let ramRevision: Int

    var isPrematurityWindowMatch: Bool { prematurityAllowanceDays > 0 }
    var configuredGestationDays: Int { inferredGestationDays + prematurityAllowanceDays }
}

struct PedigreeCandidateFeatures: Sendable, Equatable {
    let ramAgeDaysAtConception: Double
    let gestationDays: Int
    let sameHistoricalPen: Bool
    let presentAtConception: Bool
    let explicitlyMarkedBreedingRam: Bool
}

struct PedigreeSheepSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let earTag: String
    let breed: String
    let purpose: String
    let sex: SheepSex
    let isBreedingRam: Bool
    let initialPenID: UUID?
    let currentPenID: UUID?
    let enteredAt: Date
    let removedAt: Date?
    let birthAt: Date?
    let damID: UUID?
    let sireID: UUID?
    let semenDonorID: UUID?
    let damProvenance: PedigreeRelationSource?
    let sireProvenance: PedigreeRelationSource?
    let semenDonorNameSnapshot: String?
    let semenDonorRegistrationNumberSnapshot: String?
    let semenDonorBreedSnapshot: String?
    let revision: Int

    init(
        id: UUID = UUID(),
        earTag: String,
        breed: String = "",
        purpose: String = "未分类",
        sex: SheepSex,
        isBreedingRam: Bool = false,
        initialPenID: UUID? = nil,
        currentPenID: UUID? = nil,
        enteredAt: Date = .distantPast,
        removedAt: Date? = nil,
        birthAt: Date? = nil,
        damID: UUID? = nil,
        sireID: UUID? = nil,
        semenDonorID: UUID? = nil,
        damProvenance: PedigreeRelationSource? = nil,
        sireProvenance: PedigreeRelationSource? = nil,
        semenDonorNameSnapshot: String? = nil,
        semenDonorRegistrationNumberSnapshot: String? = nil,
        semenDonorBreedSnapshot: String? = nil,
        revision: Int = 1
    ) {
        self.id = id
        self.earTag = earTag
        self.breed = breed
        self.purpose = purpose
        self.sex = sex
        self.isBreedingRam = isBreedingRam
        self.initialPenID = initialPenID
        self.currentPenID = currentPenID
        self.enteredAt = enteredAt
        self.removedAt = removedAt
        self.birthAt = birthAt
        self.damID = damID
        self.sireID = sireID
        self.semenDonorID = semenDonorID
        self.damProvenance = damProvenance
        self.sireProvenance = sireProvenance
        self.semenDonorNameSnapshot = semenDonorNameSnapshot
        self.semenDonorRegistrationNumberSnapshot = semenDonorRegistrationNumberSnapshot
        self.semenDonorBreedSnapshot = semenDonorBreedSnapshot
        self.revision = revision
    }

    init(_ record: SheepRecord) {
        self.init(
            id: record.id,
            earTag: record.earTag,
            breed: record.breed,
            purpose: record.purpose,
            sex: record.sex,
            isBreedingRam: record.isBreedingRam,
            initialPenID: record.initialPenID,
            currentPenID: record.currentPenID,
            enteredAt: record.enteredAt,
            removedAt: record.removedAt,
            birthAt: record.birthAt,
            damID: record.damID,
            sireID: record.sireID,
            semenDonorID: record.semenDonorID,
            damProvenance: record.damProvenance,
            sireProvenance: record.sireProvenance,
            semenDonorNameSnapshot: record.semenDonorNameSnapshot,
            semenDonorRegistrationNumberSnapshot: record.semenDonorRegistrationNumberSnapshot,
            semenDonorBreedSnapshot: record.semenDonorBreedSnapshot,
            revision: record.revision
        )
    }
}

struct PedigreeAnalysisInput: Sendable {
    let sheep: [PedigreeSheepSnapshot]
    let transfers: [TransferSnapshot]
}

struct PedigreeRelatedSheep: Identifiable, Sendable, Equatable {
    let id: UUID
    let earTag: String
    let sex: SheepSex
    let currentPenName: String?
}

struct PedigreeDonorSummary: Sendable, Equatable {
    let name: String
    let registrationNumber: String
    let breed: String
}

struct PedigreeAuditSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let reason: String
    let occurredAt: Date
}

struct PedigreeProfileSnapshot: Sendable, Equatable {
    let record: PedigreeSheepSnapshot
    let dam: PedigreeRelatedSheep?
    let sire: PedigreeRelatedSheep?
    let donor: PedigreeDonorSummary?
    let maternalGranddam: PedigreeRelatedSheep?
    let maternalGrandsire: PedigreeRelatedSheep?
    let paternalGranddam: PedigreeRelatedSheep?
    let paternalGrandsire: PedigreeRelatedSheep?
    let grandparents: [PedigreeRelatedSheep]
    /// 与本羊出现在同一条有效产羔记录中的其他已建档羔羊。
    let littermates: [PedigreeRelatedSheep]
    let maternalSiblings: [PedigreeRelatedSheep]
    let paternalSiblings: [PedigreeRelatedSheep]
    let descendants: [PedigreeRelatedSheep]
    let audits: [PedigreeAuditSummary]
}

struct PedigreeScreenSnapshot: Sendable, Equatable {
    let profile: PedigreeProfileSnapshot?
    let sireCandidates: [PedigreeSireCandidate]
    let gestationDays: Int
}

struct PedigreeBatchSireProposal: Identifiable, Sendable, Equatable {
    var id: UUID { child.id }
    let child: PedigreeSheepSnapshot
    let candidate: PedigreeSireCandidate
}

struct PedigreeCheckSnapshot: Sendable, Equatable {
    let issues: [PedigreeIssue]
    let batchSireProposals: [PedigreeBatchSireProposal]
    let earTagsByID: [UUID: String]
    let gestationDays: Int
}

/// Keeps the full-farm SwiftData read off the navigation/render executor.
///
/// A real farm can retain thousands of historical sheep and transfer records.
/// Building the profile and sire-candidate index from the view's `ModelContext`
/// blocks SwiftUI until every model has faulted and been indexed.
actor PedigreeSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func load(sheepID: UUID, farmID: UUID) throws -> PedigreeScreenSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let snapshot = try PedigreeAnalysis.screenSnapshot(
            sheepID: sheepID,
            farmID: farmID,
            context: context
        )
        try Task.checkCancellation()
        return snapshot
    }

    func loadCheck(farmID: UUID) throws -> PedigreeCheckSnapshot {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let snapshot = try PedigreeAnalysis.checkSnapshot(
            farmID: farmID,
            context: context
        )
        try Task.checkCancellation()
        return snapshot
    }
}

protocol PedigreeCandidateRanking: Sendable {
    func score(_ features: PedigreeCandidateFeatures) -> Double
}

struct RuleBasedPedigreeCandidateRanking: PedigreeCandidateRanking {
    func score(_ features: PedigreeCandidateFeatures) -> Double {
        guard features.sameHistoricalPen, features.presentAtConception, features.explicitlyMarkedBreedingRam else { return 0 }
        return features.ramAgeDaysAtConception >= 180 ? 1 : 0.5
    }
}

#if canImport(CoreML)
/// 只有随 App 提供经过验收的 `PedigreeSireRanker.mlmodelc` 时才启用；模型输出只排序候选，不确认父本。
final class BundledCoreMLPedigreeCandidateRanking {
    private let model: MLModel

    private init(model: MLModel) { self.model = model }

    static func load(bundle: Bundle = .main) -> BundledCoreMLPedigreeCandidateRanking? {
        guard let url = bundle.url(forResource: "PedigreeSireRanker", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else { return nil }
        return .init(model: model)
    }

    func score(_ features: PedigreeCandidateFeatures) -> Double? {
        let values: [String: MLFeatureValue] = [
            "ramAgeDaysAtConception": .init(double: features.ramAgeDaysAtConception),
            "gestationDays": .init(int64: Int64(features.gestationDays)),
            "sameHistoricalPen": .init(int64: features.sameHistoricalPen ? 1 : 0),
            "presentAtConception": .init(int64: features.presentAtConception ? 1 : 0),
            "explicitlyMarkedBreedingRam": .init(int64: features.explicitlyMarkedBreedingRam ? 1 : 0),
        ]
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: values),
              let prediction = try? model.prediction(from: provider),
              let value = prediction.featureValue(for: "sireProbability") else { return nil }
        return value.doubleValue
    }
}
#endif

enum PedigreeIssueKind: String, Sendable {
    case unknownDam
    case unknownSire
    case candidateSire
    case invalidReference
    case sexMismatch
    case dateInversion
    case cycle
}

struct PedigreeIssue: Identifiable, Sendable, Equatable {
    let id: String
    let kind: PedigreeIssueKind
    let sheepID: UUID
    let title: String
    let detail: String
    let candidateRamIDs: [UUID]
}

enum PedigreeAnalysis {
    /// 羊只可能提前分娩，父本候选因此允许从标准受胎日向出生方向延伸 20 天。
    /// 该窗口只扩大“候选”检索，永远不自动确认父本。
    static let prematureBirthToleranceDays = 20

    @MainActor
    static func loadInput(farmID: UUID, context: ModelContext) throws -> PedigreeAnalysisInput {
        try readInput(farmID: farmID, context: context)
    }

    private nonisolated static func readInput(
        farmID: UUID,
        context: ModelContext
    ) throws -> PedigreeAnalysisInput {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        return PedigreeAnalysisInput(
            sheep: sheep.map(PedigreeSheepSnapshot.init),
            transfers: transfers.map {
                TransferSnapshot(
                    sheepID: $0.sheepID,
                    toPenID: $0.toPenID,
                    occurredAt: $0.occurredAt,
                    recordedAt: $0.recordedAt,
                    stableID: $0.id
                )
            }
        )
    }

    @MainActor
    static func sireCandidates(
        eweID: UUID,
        lambingAt: Date,
        gestationDays: Int,
        farmID: UUID,
        context: ModelContext,
        ranking: any PedigreeCandidateRanking = RuleBasedPedigreeCandidateRanking()
    ) throws -> [PedigreeSireCandidate] {
        let input = try readInput(farmID: farmID, context: context)
        let penNames = try readPenNames(farmID: farmID, context: context)
        return makeSireCandidates(
            input: input,
            eweID: eweID,
            lambingAt: lambingAt,
            gestationDays: gestationDays,
            penNames: penNames,
            ranking: ranking
        )
    }

    /// One immutable read used by the pedigree screen.
    ///
    /// The sheep collection is fetched once and shared by the relationship and
    /// sire-candidate projections. Transfer history is only fetched when the
    /// selected sheep actually needs a sire candidate.
    nonisolated static func screenSnapshot(
        sheepID: UUID,
        farmID: UUID,
        context: ModelContext,
        ranking: any PedigreeCandidateRanking = RuleBasedPedigreeCandidateRanking()
    ) throws -> PedigreeScreenSnapshot {
        try Task.checkCancellation()
        let gestationDays = try context.fetch(FetchDescriptor<FarmCareRuleRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).first?.gestationDays ?? 150
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).map(PedigreeSheepSnapshot.init)
        try Task.checkCancellation()
        let penNames = try readPenNames(farmID: farmID, context: context)
        let profile = try makeProfile(
            sheepID: sheepID,
            farmID: farmID,
            sheep: sheep,
            penNames: penNames,
            context: context
        )
        guard let record = profile?.record,
              record.sireID == nil,
              record.semenDonorID == nil,
              let eweID = record.damID,
              let birthAt = record.birthAt else {
            return PedigreeScreenSnapshot(
                profile: profile,
                sireCandidates: [],
                gestationDays: gestationDays
            )
        }

        let transfers = try context.fetch(FetchDescriptor<TransferRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).map {
            TransferSnapshot(
                sheepID: $0.sheepID,
                toPenID: $0.toPenID,
                occurredAt: $0.occurredAt,
                recordedAt: $0.recordedAt,
                stableID: $0.id
            )
        }
        try Task.checkCancellation()
        let candidates = makeSireCandidates(
            input: PedigreeAnalysisInput(sheep: sheep, transfers: transfers),
            eweID: eweID,
            lambingAt: birthAt,
            gestationDays: gestationDays,
            penNames: penNames,
            ranking: ranking
        )
        return PedigreeScreenSnapshot(
            profile: profile,
            sireCandidates: candidates,
            gestationDays: gestationDays
        )
    }

    nonisolated static func checkSnapshot(
        farmID: UUID,
        context: ModelContext,
        ranking: any PedigreeCandidateRanking = RuleBasedPedigreeCandidateRanking()
    ) throws -> PedigreeCheckSnapshot {
        try Task.checkCancellation()
        let gestationDays = try context.fetch(FetchDescriptor<FarmCareRuleRecord>(predicate: #Predicate {
            $0.farmID == farmID
        })).first?.gestationDays ?? 150
        let input = try readInput(farmID: farmID, context: context)
        try Task.checkCancellation()
        let penNames = try readPenNames(farmID: farmID, context: context)
        let issues = issues(input: input, gestationDays: gestationDays)
        try Task.checkCancellation()
        return PedigreeCheckSnapshot(
            issues: issues,
            batchSireProposals: batchSireProposals(
                input: input,
                gestationDays: gestationDays,
                penNames: penNames,
                ranking: ranking
            ),
            earTagsByID: Dictionary(uniqueKeysWithValues: input.sheep.map { ($0.id, $0.earTag) }),
            gestationDays: gestationDays
        )
    }

    /// Only an unambiguous candidate is eligible for batch review.
    ///
    /// This does not confirm anything. It groups the same evidence that the
    /// per-sheep screen already shows, while keeping multi-candidate, date
    /// inversion, and cycle-risk records in the individual review queue.
    static func batchSireProposals(
        input: PedigreeAnalysisInput,
        gestationDays: Int,
        penNames: [UUID: String] = [:],
        ranking: any PedigreeCandidateRanking = RuleBasedPedigreeCandidateRanking()
    ) -> [PedigreeBatchSireProposal] {
        let index = CandidateIndex(input: input)
        let byID = index.sheepByID
        var matchCache: [CandidateLookupKey: CandidateMatch] = [:]
        var missingMatches = Set<CandidateLookupKey>()
        var proposals: [PedigreeBatchSireProposal] = []

        for child in input.sheep where child.sireID == nil && child.semenDonorID == nil {
            guard let eweID = child.damID, let birthAt = child.birthAt else { continue }
            let key = CandidateLookupKey(
                eweID: eweID,
                lambingAt: birthAt,
                gestationDays: gestationDays
            )
            let match: CandidateMatch?
            if let cached = matchCache[key] {
                match = cached
            } else if missingMatches.contains(key) {
                match = nil
            } else if let loaded = index.match(
                eweID: eweID,
                lambingAt: birthAt,
                gestationDays: gestationDays
            ) {
                matchCache[key] = loaded
                match = loaded
            } else {
                missingMatches.insert(key)
                match = nil
            }
            guard let match, match.rams.count == 1, let evidence = match.rams.first,
                  let ram = byID[evidence.ramID] else { continue }
            if let ramBirthAt = ram.birthAt, ramBirthAt >= birthAt { continue }
            if ancestryContains(child.id, startingAt: ram.id, byID: byID) { continue }

            let ageDays = ram.birthAt.map {
                max(0, evidence.matchedAt.timeIntervalSince($0) / 86_400)
            } ?? 365
            let features = PedigreeCandidateFeatures(
                ramAgeDaysAtConception: ageDays,
                gestationDays: gestationDays,
                sameHistoricalPen: true,
                presentAtConception: true,
                explicitlyMarkedBreedingRam: ram.isBreedingRam
            )
            proposals.append(.init(
                child: child,
                candidate: .init(
                    ramID: ram.id,
                    earTag: ram.earTag,
                    breed: ram.breed,
                    conceptionAt: match.standardConceptionAt,
                    matchedAt: evidence.matchedAt,
                    candidateWindowEndAt: match.windowEndAt,
                    inferredGestationDays: evidence.inferredGestationDays,
                    prematurityAllowanceDays: evidence.prematurityAllowanceDays,
                    historicalPenID: evidence.penID,
                    historicalPenName: penNames[evidence.penID],
                    rankingScore: ranking.score(features),
                    isConfirmedBreedingRam: ram.isBreedingRam,
                    ramRevision: ram.revision
                )
            ))
        }
        return proposals.sorted {
            let sireOrder = $0.candidate.earTag.localizedStandardCompare($1.candidate.earTag)
            if sireOrder != .orderedSame { return sireOrder == .orderedAscending }
            return $0.child.earTag.localizedStandardCompare($1.child.earTag) == .orderedAscending
        }
    }

    private nonisolated static func readPenNames(
        farmID: UUID,
        context: ModelContext
    ) throws -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).map { ($0.id, $0.name) })
    }

    private nonisolated static func makeSireCandidates(
        input: PedigreeAnalysisInput,
        eweID: UUID,
        lambingAt: Date,
        gestationDays: Int,
        penNames: [UUID: String],
        ranking: any PedigreeCandidateRanking
    ) -> [PedigreeSireCandidate] {
        let index = CandidateIndex(input: input)
        guard let match = index.match(eweID: eweID, lambingAt: lambingAt, gestationDays: gestationDays) else { return [] }
        #if canImport(CoreML)
        let coreMLRanking = BundledCoreMLPedigreeCandidateRanking.load()
        #endif
        return match.rams.compactMap { evidence -> PedigreeSireCandidate? in
            guard let ram = index.sheepByID[evidence.ramID] else { return nil }
            let ageDays = ram.birthAt.map { max(0, evidence.matchedAt.timeIntervalSince($0) / 86_400) } ?? 365
            let features = PedigreeCandidateFeatures(
                ramAgeDaysAtConception: ageDays,
                gestationDays: gestationDays,
                sameHistoricalPen: true,
                presentAtConception: true,
                explicitlyMarkedBreedingRam: ram.isBreedingRam
            )
            #if canImport(CoreML)
            let score = coreMLRanking?.score(features) ?? ranking.score(features)
            #else
            let score = ranking.score(features)
            #endif
            return .init(
                ramID: ram.id,
                earTag: ram.earTag,
                breed: ram.breed,
                conceptionAt: match.standardConceptionAt,
                matchedAt: evidence.matchedAt,
                candidateWindowEndAt: match.windowEndAt,
                inferredGestationDays: evidence.inferredGestationDays,
                prematurityAllowanceDays: evidence.prematurityAllowanceDays,
                historicalPenID: evidence.penID,
                historicalPenName: penNames[evidence.penID],
                rankingScore: score,
                isConfirmedBreedingRam: ram.isBreedingRam,
                ramRevision: ram.revision
            )
        }
        .sorted {
            if $0.isConfirmedBreedingRam != $1.isConfirmedBreedingRam { return $0.isConfirmedBreedingRam }
            if $0.prematurityAllowanceDays != $1.prematurityAllowanceDays {
                return $0.prematurityAllowanceDays < $1.prematurityAllowanceDays
            }
            if $0.rankingScore != $1.rankingScore { return $0.rankingScore > $1.rankingScore }
            return $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending
        }
    }

    @MainActor
    static func issues(farmID: UUID, gestationDays: Int, context: ModelContext) throws -> [PedigreeIssue] {
        issues(input: try loadInput(farmID: farmID, context: context), gestationDays: gestationDays)
    }

    static func issues(input: PedigreeAnalysisInput, gestationDays: Int) -> [PedigreeIssue] {
        let byID = Dictionary(uniqueKeysWithValues: input.sheep.map { ($0.id, $0) })
        let candidateIndex = CandidateIndex(input: input)
        let cycleIDs = pedigreeCycleIDs(byID: byID)
        var candidateCache: [CandidateLookupKey: [UUID]] = [:]
        var issues: [PedigreeIssue] = []
        issues.reserveCapacity(input.sheep.count * 2)
        for child in input.sheep {
            if child.damID == nil {
                issues.append(.init(id: "\(child.id)-unknown-dam", kind: .unknownDam, sheepID: child.id, title: "\(child.earTag) · 母本未知", detail: "当前档案没有确认母本。", candidateRamIDs: []))
            } else if let damID = child.damID, let dam = byID[damID] {
                if dam.sex != .ewe { issues.append(.init(id: "\(child.id)-dam-sex", kind: .sexMismatch, sheepID: child.id, title: "\(child.earTag) · 母本性别异常", detail: "引用的母本不是母羊。", candidateRamIDs: [])) }
                if let childBirth = child.birthAt, let parentBirth = dam.birthAt, parentBirth >= childBirth { issues.append(.init(id: "\(child.id)-dam-date", kind: .dateInversion, sheepID: child.id, title: "\(child.earTag) · 母系日期倒置", detail: "母本出生日期不早于后代。", candidateRamIDs: [])) }
            } else {
                issues.append(.init(id: "\(child.id)-dam-missing", kind: .invalidReference, sheepID: child.id, title: "\(child.earTag) · 母本引用失效", detail: "母本 UUID 在当前牧场中不存在。", candidateRamIDs: []))
            }
            if child.sireID == nil && child.semenDonorID == nil {
                var candidates: [UUID] = []
                if let eweID = child.damID, let birthAt = child.birthAt {
                    let key = CandidateLookupKey(eweID: eweID, lambingAt: birthAt, gestationDays: gestationDays)
                    if let cached = candidateCache[key] {
                        candidates = cached
                    } else {
                        candidates = candidateIndex.match(eweID: eweID, lambingAt: birthAt, gestationDays: gestationDays)?.ramIDs ?? []
                        candidateCache[key] = candidates
                    }
                }
                let minimumGestationDays = max(1, gestationDays - prematureBirthToleranceDays)
                issues.append(.init(
                    id: "\(child.id)-unknown-sire",
                    kind: candidates.isEmpty ? .unknownSire : .candidateSire,
                    sheepID: child.id,
                    title: "\(child.earTag) · 父本未确认",
                    detail: candidates.isEmpty
                        ? "出生前 \(gestationDays)～\(minimumGestationDays) 天内没有符合历史边界的同舍种公羊。"
                        : "出生前 \(gestationDays)～\(minimumGestationDays) 天内发现 \(candidates.count) 只历史同舍种公羊，仅作为候选。",
                    candidateRamIDs: candidates
                ))
            } else if let sireID = child.sireID, let sire = byID[sireID] {
                if sire.sex != .ram || !sire.isBreedingRam { issues.append(.init(id: "\(child.id)-sire-sex", kind: .sexMismatch, sheepID: child.id, title: "\(child.earTag) · 父本资格异常", detail: "引用的父本不是已明确标记的种公羊。", candidateRamIDs: [])) }
                if let childBirth = child.birthAt, let parentBirth = sire.birthAt, parentBirth >= childBirth { issues.append(.init(id: "\(child.id)-sire-date", kind: .dateInversion, sheepID: child.id, title: "\(child.earTag) · 父系日期倒置", detail: "父本出生日期不早于后代。", candidateRamIDs: [])) }
            } else if child.sireID != nil {
                issues.append(.init(id: "\(child.id)-sire-missing", kind: .invalidReference, sheepID: child.id, title: "\(child.earTag) · 父本引用失效", detail: "父本 UUID 在当前牧场中不存在。", candidateRamIDs: []))
            }
            if cycleIDs.contains(child.id) {
                issues.append(.init(id: "\(child.id)-cycle", kind: .cycle, sheepID: child.id, title: "\(child.earTag) · 循环系谱", detail: "父系或母系祖先链回到了该羊只。", candidateRamIDs: []))
            }
        }
        return issues.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func ancestryContains(
        _ target: UUID,
        startingAt root: UUID,
        byID: [UUID: PedigreeSheepSnapshot]
    ) -> Bool {
        var pending = [root]
        var visited = Set<UUID>()
        while let current = pending.popLast() {
            if current == target { return true }
            guard visited.insert(current).inserted, let record = byID[current] else { continue }
            if let damID = record.damID { pending.append(damID) }
            if let sireID = record.sireID { pending.append(sireID) }
        }
        return false
    }

    @MainActor
    static func profile(sheepID: UUID, farmID: UUID, context: ModelContext) throws -> PedigreeProfileSnapshot? {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        })).map(PedigreeSheepSnapshot.init)
        let penNames = try readPenNames(farmID: farmID, context: context)
        return try makeProfile(
            sheepID: sheepID,
            farmID: farmID,
            sheep: sheep,
            penNames: penNames,
            context: context
        )
    }

    private nonisolated static func makeProfile(
        sheepID: UUID,
        farmID: UUID,
        sheep: [PedigreeSheepSnapshot],
        penNames: [UUID: String],
        context: ModelContext
    ) throws -> PedigreeProfileSnapshot? {
        guard let record = sheep.first(where: { $0.id == sheepID }) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })

        func related(_ item: PedigreeSheepSnapshot) -> PedigreeRelatedSheep {
            PedigreeRelatedSheep(id: item.id, earTag: item.earTag, sex: item.sex, currentPenName: item.currentPenID.flatMap { penNames[$0] })
        }
        func sorted(_ values: [PedigreeSheepSnapshot]) -> [PedigreeRelatedSheep] {
            values.sorted { $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending }.map(related)
        }

        let dam = record.damID.flatMap { byID[$0] }
        let sire = record.sireID.flatMap { byID[$0] }
        let parents = [dam, sire].compactMap { $0 }
        var seenGrandparents = Set<UUID>()
        let grandparents = parents
            .flatMap { [$0.damID, $0.sireID].compactMap { $0.flatMap { byID[$0] } } }
            .filter { seenGrandparents.insert($0.id).inserted }

        let subjectOffspringID: UUID? = record.id
        let subjectOffspringLinks = try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == subjectOffspringID && $0.deletedAt == nil
        }))
        var littermates: [PedigreeSheepSnapshot] = []
        if !subjectOffspringLinks.isEmpty {
            var linkedLambings: [ReproductionRecord] = []
            for lambingID in Set(subjectOffspringLinks.map(\.lambingRecordID)) {
                let matches = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
                    $0.id == lambingID && $0.farmID == farmID && $0.deletedAt == nil
                }))
                linkedLambings.append(contentsOf: matches.filter { $0.kind == .lambing })
            }
            let selectedLambing = linkedLambings.min { lhs, rhs in
                if let birthAt = record.birthAt {
                    let lhsDistance = abs(lhs.occurredAt.timeIntervalSince(birthAt))
                    let rhsDistance = abs(rhs.occurredAt.timeIntervalSince(birthAt))
                    if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                }
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            if let lambingID = selectedLambing?.id {
                let activeOffspring = try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.lambingRecordID == lambingID && $0.deletedAt == nil
                }))
                let littermateIDs = Set(activeOffspring.compactMap(\.sheepID).filter { $0 != record.id })
                littermates = sheep.filter { littermateIDs.contains($0.id) }
            }
        }
        let littermateIDs = Set(littermates.map(\.id))

        let maternalSiblings: [PedigreeSheepSnapshot]
        if let damID = record.damID {
            maternalSiblings = sheep.filter {
                $0.id != record.id && $0.damID == damID && !littermateIDs.contains($0.id)
            }
        } else {
            maternalSiblings = []
        }
        let paternalSiblings: [PedigreeSheepSnapshot]
        if let donorID = record.semenDonorID {
            paternalSiblings = sheep.filter {
                $0.id != record.id && $0.semenDonorID == donorID && !littermateIDs.contains($0.id)
            }
        } else if let sireID = record.sireID {
            paternalSiblings = sheep.filter {
                $0.id != record.id && $0.sireID == sireID && $0.semenDonorID == nil && !littermateIDs.contains($0.id)
            }
        } else {
            paternalSiblings = []
        }
        let descendants = sheep.filter { $0.damID == record.id || $0.sireID == record.id }

        let donor: PedigreeDonorSummary?
        if let donorID = record.semenDonorID {
            let donorRecord = try context.fetch(FetchDescriptor<SemenDonorRecord>(predicate: #Predicate {
                $0.id == donorID && $0.farmID == farmID && $0.deletedAt == nil
            })).first
            donor = PedigreeDonorSummary(
                name: donorRecord?.name ?? record.semenDonorNameSnapshot ?? "未知供体",
                registrationNumber: donorRecord?.registrationNumber ?? record.semenDonorRegistrationNumberSnapshot ?? "",
                breed: donorRecord?.breed ?? record.semenDonorBreedSnapshot ?? ""
            )
        } else {
            donor = nil
        }

        let audits = try context.fetch(FetchDescriptor<PedigreeChangeRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        })).sorted { $0.occurredAt > $1.occurredAt }.map {
            PedigreeAuditSummary(id: $0.id, reason: $0.reason, occurredAt: $0.occurredAt)
        }

        return PedigreeProfileSnapshot(
            record: record,
            dam: dam.map(related),
            sire: sire.map(related),
            donor: donor,
            maternalGranddam: dam?.damID.flatMap { byID[$0] }.map(related),
            maternalGrandsire: dam?.sireID.flatMap { byID[$0] }.map(related),
            paternalGranddam: sire?.damID.flatMap { byID[$0] }.map(related),
            paternalGrandsire: sire?.sireID.flatMap { byID[$0] }.map(related),
            grandparents: sorted(grandparents),
            littermates: sorted(littermates),
            maternalSiblings: sorted(maternalSiblings),
            paternalSiblings: sorted(paternalSiblings),
            descendants: sorted(descendants),
            audits: audits
        )
    }

    private struct CandidateLookupKey: Hashable {
        let eweID: UUID
        let lambingAt: Date
        let gestationDays: Int
    }

    private struct CandidateRamMatch {
        let ramID: UUID
        let matchedAt: Date
        let penID: UUID
        let inferredGestationDays: Int
        let prematurityAllowanceDays: Int
    }

    private struct CandidateMatch {
        let standardConceptionAt: Date
        let windowEndAt: Date
        let rams: [CandidateRamMatch]

        var ramIDs: [UUID] { rams.map(\.ramID) }
    }

    private struct CandidateIndex {
        let sheepByID: [UUID: PedigreeSheepSnapshot]
        private let breedingRamCandidates: [PedigreeSheepSnapshot]
        private let transfersBySheep: [UUID: [TransferSnapshot]]

        init(input: PedigreeAnalysisInput) {
            sheepByID = Dictionary(uniqueKeysWithValues: input.sheep.map { ($0.id, $0) })
            // 新资格标记是权威事实。旧库只有“用途”快照时，它只作为待人工核实的线索，
            // 不能在这里静默升级为已确认种公羊。
            breedingRamCandidates = input.sheep.filter {
                $0.sex == .ram && ($0.isBreedingRam || $0.purpose == "种公羊")
            }
            transfersBySheep = Dictionary(grouping: input.transfers, by: \.sheepID).mapValues { values in
                values.sorted {
                    if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                    if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                    return $0.stableID.uuidString < $1.stableID.uuidString
                }
            }
        }

        func match(eweID: UUID, lambingAt: Date, gestationDays: Int, calendar: Calendar = .current) -> CandidateMatch? {
            // Farm dates are date-only business facts. Keep arithmetic in a
            // fixed Gregorian UTC calendar so a daylight-saving transition on
            // the device cannot shift the inferred conception day by an hour.
            var calendar = calendar
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let normalizedGestationDays = max(1, gestationDays)
            let toleranceDays = min(PedigreeAnalysis.prematureBirthToleranceDays, normalizedGestationDays - 1)
            let standardConceptionAt = calendar.date(byAdding: .day, value: -normalizedGestationDays, to: lambingAt) ?? lambingAt
            let windowEndAt = calendar.date(byAdding: .day, value: toleranceDays, to: standardConceptionAt) ?? standardConceptionAt
            guard let ewe = sheepByID[eweID] else { return nil }

            let rams = breedingRamCandidates.compactMap { ram -> CandidateRamMatch? in
                guard ram.id != eweID,
                      let evidence = firstCoLocation(
                          ewe: ewe,
                          ram: ram,
                          from: standardConceptionAt,
                          through: windowEndAt
                      ) else { return nil }
                let allowanceDays = max(
                    0,
                    calendar.dateComponents(
                        [.day],
                        from: calendar.startOfDay(for: standardConceptionAt),
                        to: calendar.startOfDay(for: evidence.date)
                    ).day ?? 0
                )
                return CandidateRamMatch(
                    ramID: ram.id,
                    matchedAt: evidence.date,
                    penID: evidence.penID,
                    inferredGestationDays: max(1, normalizedGestationDays - allowanceDays),
                    prematurityAllowanceDays: allowanceDays
                )
            }
            return CandidateMatch(
                standardConceptionAt: standardConceptionAt,
                windowEndAt: windowEndAt,
                rams: rams
            )
        }

        /// 羊只的圈舍/在场状态只会在入场或转群时发生变化；检查这些边界点即可，
        /// 不需要把全场记录按 21 个自然日重复扫描。
        private func firstCoLocation(
            ewe: PedigreeSheepSnapshot,
            ram: PedigreeSheepSnapshot,
            from startAt: Date,
            through endAt: Date
        ) -> (date: Date, penID: UUID)? {
            var checkpoints = Set([startAt, endAt])
            for enteredAt in [ewe.enteredAt, ram.enteredAt] where enteredAt > startAt && enteredAt <= endAt {
                checkpoints.insert(enteredAt)
            }
            for sheepID in [ewe.id, ram.id] {
                for transfer in transfersBySheep[sheepID] ?? []
                    where transfer.occurredAt > startAt && transfer.occurredAt <= endAt {
                    checkpoints.insert(transfer.occurredAt)
                }
            }

            for date in checkpoints.sorted() {
                guard isPresent(ewe, at: date),
                      isPresent(ram, at: date),
                      let ewePenID = pen(for: ewe, at: date),
                      pen(for: ram, at: date) == ewePenID else { continue }
                return (date, ewePenID)
            }
            return nil
        }

        private func isPresent(_ sheep: PedigreeSheepSnapshot, at date: Date) -> Bool {
            sheep.enteredAt <= date && (sheep.removedAt.map { $0 > date } ?? true)
        }

        private func pen(for sheep: PedigreeSheepSnapshot, at date: Date) -> UUID? {
            guard let transfers = transfersBySheep[sheep.id], !transfers.isEmpty else { return sheep.initialPenID }
            var lower = 0
            var upper = transfers.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if transfers[middle].occurredAt <= date { lower = middle + 1 } else { upper = middle }
            }
            return lower > 0 ? transfers[lower - 1].toPenID : sheep.initialPenID
        }
    }

    private static func pedigreeCycleIDs(byID: [UUID: PedigreeSheepSnapshot]) -> Set<UUID> {
        var state: [UUID: UInt8] = [:]
        var path: [UUID] = []
        var pathIndex: [UUID: Int] = [:]
        var cycleIDs = Set<UUID>()

        func visit(_ id: UUID) {
            if state[id] == 2 { return }
            if state[id] == 1 {
                if let start = pathIndex[id] { cycleIDs.formUnion(path[start...]) }
                return
            }
            guard let record = byID[id] else { return }
            state[id] = 1
            pathIndex[id] = path.count
            path.append(id)
            if let damID = record.damID { visit(damID) }
            if let sireID = record.sireID { visit(sireID) }
            _ = path.popLast()
            pathIndex[id] = nil
            state[id] = 2
        }

        for id in byID.keys where state[id] == nil { visit(id) }
        return cycleIDs
    }
}
