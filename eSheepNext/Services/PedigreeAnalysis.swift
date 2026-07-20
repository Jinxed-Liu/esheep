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
    let conceptionAt: Date
    let historicalPenID: UUID
    let rankingScore: Double
}

struct PedigreeCandidateFeatures: Sendable, Equatable {
    let ramAgeDaysAtConception: Double
    let gestationDays: Int
    let sameHistoricalPen: Bool
    let presentAtConception: Bool
    let explicitlyMarkedBreedingRam: Bool
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
@MainActor
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

@MainActor
enum PedigreeAnalysis {
    static func sireCandidates(
        eweID: UUID,
        lambingAt: Date,
        gestationDays: Int,
        farmID: UUID,
        context: ModelContext,
        ranking: any PedigreeCandidateRanking = RuleBasedPedigreeCandidateRanking()
    ) throws -> [PedigreeSireCandidate] {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let transfers = try context.fetch(FetchDescriptor<TransferRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let presence = sheep.map { SheepPresenceSnapshot(sheepID: $0.id, initialPenID: $0.initialPenID, enteredAt: $0.enteredAt, removedAt: $0.removedAt) }
        let transferSnapshots = transfers.map { TransferSnapshot(sheepID: $0.sheepID, toPenID: $0.toPenID, occurredAt: $0.occurredAt, recordedAt: $0.recordedAt, stableID: $0.id) }
        let breedingRamIDs = Set(sheep.filter { $0.sex == .ram && $0.isBreedingRam }.map(\.id))
        let ids = FarmAnalytics.inferredSireCandidates(for: eweID, lambingAt: lambingAt, gestationDays: gestationDays, sheep: presence, sexes: Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0.sex) }), breedingRamIDs: breedingRamIDs, transfers: transferSnapshots)
        let conceptionAt = Calendar.current.date(byAdding: .day, value: -max(1, gestationDays), to: lambingAt) ?? lambingAt
        guard let ewe = sheep.first(where: { $0.id == eweID }),
              let penID = FarmHistoryTimeline.pen(for: ewe, at: conceptionAt, transfers: transfers) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        let coreMLRanking = BundledCoreMLPedigreeCandidateRanking.load()
        return ids.compactMap { id -> PedigreeSireCandidate? in
            guard let ram = byID[id] else { return nil }
            let ageDays = ram.birthAt.map { max(0, conceptionAt.timeIntervalSince($0) / 86_400) } ?? 365
            let features = PedigreeCandidateFeatures(ramAgeDaysAtConception: ageDays, gestationDays: gestationDays, sameHistoricalPen: true, presentAtConception: true, explicitlyMarkedBreedingRam: true)
            #if canImport(CoreML)
            let score = coreMLRanking?.score(features) ?? ranking.score(features)
            #else
            let score = ranking.score(features)
            #endif
            return .init(ramID: ram.id, earTag: ram.earTag, breed: ram.breed, conceptionAt: conceptionAt, historicalPenID: penID, rankingScore: score)
        }
        .sorted {
            if $0.rankingScore != $1.rankingScore { return $0.rankingScore > $1.rankingScore }
            return $0.earTag.localizedStandardCompare($1.earTag) == .orderedAscending
        }
    }

    static func issues(farmID: UUID, gestationDays: Int, context: ModelContext) throws -> [PedigreeIssue] {
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let byID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        var issues: [PedigreeIssue] = []
        for child in sheep {
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
                    candidates = try sireCandidates(eweID: eweID, lambingAt: birthAt, gestationDays: gestationDays, farmID: farmID, context: context).map(\.ramID)
                }
                issues.append(.init(id: "\(child.id)-unknown-sire", kind: candidates.isEmpty ? .unknownSire : .candidateSire, sheepID: child.id, title: "\(child.earTag) · 父本未确认", detail: candidates.isEmpty ? "没有符合历史边界的同舍种公羊。" : "发现 \(candidates.count) 只历史同舍种公羊，仅作为候选。", candidateRamIDs: candidates))
            } else if let sireID = child.sireID, let sire = byID[sireID] {
                if sire.sex != .ram || !sire.isBreedingRam { issues.append(.init(id: "\(child.id)-sire-sex", kind: .sexMismatch, sheepID: child.id, title: "\(child.earTag) · 父本资格异常", detail: "引用的父本不是已明确标记的种公羊。", candidateRamIDs: [])) }
                if let childBirth = child.birthAt, let parentBirth = sire.birthAt, parentBirth >= childBirth { issues.append(.init(id: "\(child.id)-sire-date", kind: .dateInversion, sheepID: child.id, title: "\(child.earTag) · 父系日期倒置", detail: "父本出生日期不早于后代。", candidateRamIDs: [])) }
            } else if child.sireID != nil {
                issues.append(.init(id: "\(child.id)-sire-missing", kind: .invalidReference, sheepID: child.id, title: "\(child.earTag) · 父本引用失效", detail: "父本 UUID 在当前牧场中不存在。", candidateRamIDs: []))
            }
            if ancestryContains(child.id, startingAt: child.damID, byID: byID) || ancestryContains(child.id, startingAt: child.sireID, byID: byID) {
                issues.append(.init(id: "\(child.id)-cycle", kind: .cycle, sheepID: child.id, title: "\(child.earTag) · 循环系谱", detail: "父系或母系祖先链回到了该羊只。", candidateRamIDs: []))
            }
        }
        return issues.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func ancestryContains(_ target: UUID, startingAt root: UUID?, byID: [UUID: SheepRecord]) -> Bool {
        guard let root else { return false }
        var pending = [root]
        var visited = Set<UUID>()
        while let id = pending.popLast() {
            if id == target { return true }
            guard visited.insert(id).inserted, let record = byID[id] else { continue }
            if let damID = record.damID { pending.append(damID) }
            if let sireID = record.sireID { pending.append(sireID) }
        }
        return false
    }
}
