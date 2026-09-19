#if DEBUG
import CryptoKit
import Foundation
import SwiftData

/// Explicit development launch only. All writes use the ordinary command and
/// cloud receipt pipeline; the audit digest prevents applying an outdated plan.
@MainActor
enum DevelopmentParityRepair {
    enum RepairError: LocalizedError {
        case stopped(String)
        var errorDescription: String? { switch self { case .stopped(let message): return message } }
    }

    struct Candidate: Codable {
        let sheepID: UUID
        let earTag: String
        let revision: Int
        let oldParity: Int?
        let newParity: Int
        let lambingCount: Int
    }

    static func plan(sheep: [SheepRecord], records: [ReproductionRecord], at date: Date) -> [Candidate] {
        let grouped = Dictionary(grouping: records.filter { $0.deletedAt == nil && $0.occurredAt <= date }, by: \.eweID)
        return sheep.filter { $0.deletedAt == nil && $0.sex == .ewe }.compactMap { ewe in
            let facts = (grouped[ewe.id] ?? []).filter { $0.farmID == ewe.farmID }
            let births = facts.filter { $0.kind == .lambing }
            let evidence = facts.filter {
                ($0.kind == .lambing || $0.kind == .parityBaseline) && $0.parity.map { $0 >= 0 } == true
            }.sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let old = evidence.last?.parity
            let target: Int
            if old == nil && births.isEmpty {
                target = 0
            } else if (old == nil || old == 0) && !births.isEmpty {
                // A malformed zero-parity birth still proves at least one birth.
                // Do not lower an earlier recorded positive parity.
                target = max(Set(births.map { FarmAnalyticsDate.day($0.occurredAt) }).count,
                             evidence.compactMap(\.parity).max() ?? 0)
            } else { return nil }
            return Candidate(sheepID: ewe.id, earTag: ewe.earTag, revision: ewe.revision,
                             oldParity: old, newParity: target, lambingCount: births.count)
        }.sorted { $0.sheepID.uuidString < $1.sheepID.uuidString }
    }

    static func runIfRequested(account: AccountProfile, container: ModelContainer,
                               collaboration: CloudCollaborationStore) async {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        guard let farmText = argument("--parity-audit-farm"), let farmID = UUID(uuidString: farmText),
              AppEnvironment.current == .development,
              Bundle.main.bundleIdentifier == "com.sheepfarm.next.dev" else { return }
        let url = URL.documentsDirectory.appending(path: "parity-repair-report.json")
        if let expected = argument("--finalize-parity-digest") {
            await finalize(farmID: farmID, accountID: account.effectiveAccountID, expected: expected,
                           url: url, container: container, collaboration: collaboration)
            return
        }
        if let expected = argument("--resume-parity-digest") {
            await resume(farmID: farmID, accountID: account.effectiveAccountID, expected: expected,
                         url: url, container: container, collaboration: collaboration)
            return
        }
        var report: [String: Any] = ["farmID": farmText, "phase": "starting"]
        func persist() throws {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
        do {
            try persist()
            _ = try await collaboration.synchronizeESheepCloudFarm(farmID: farmID, accountID: account.effectiveAccountID, force: true)
            let context = ModelContext(container)
            guard let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == farmID }),
                  farm.ownerAccountID == account.effectiveAccountID, farm.deletedAt == nil,
                  farm.role == .owner else { throw RepairError.stopped("牧场身份、完整性或云端游标未满足修正条件") }
            guard let state = try context.fetch(FetchDescriptor<ESheepCloudFarmState>()).first(where: { $0.farmID == farmID }),
                  state.activityState == .active, state.integrityState == .passed,
                  state.lastAppliedEventSequence == state.cloudEventHead else { throw RepairError.stopped("牧场身份、完整性或云端游标未满足修正条件") }
            let priorIntents = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>()).filter { $0.farmID == farmID }
            guard priorIntents.allSatisfy({ $0.lifecycle.isTerminal }) else { throw RepairError.stopped("存在尚未确认的云端命令") }
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID }
            let records = try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID }
            let now = Date()
            let candidates = plan(sheep: sheep, records: records, at: now)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(candidates)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            report["farmName"] = farm.name
            report["candidateCount"] = candidates.count
            report["digest"] = digest
            report["candidates"] = try JSONSerialization.jsonObject(with: data)
            report["cloudHeadBefore"] = state.cloudEventHead
            report["phase"] = "audited"
            try persist()
            guard let expected = argument("--apply-parity-digest") else { return }
            guard expected == digest else { throw RepairError.stopped("待改清单已变化，或云端要求处理冲突") }
            let farmContext = FarmContext(accountID: account.effectiveAccountID, farmID: farmID, role: farm.role)
            let byID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
            let commands: [FarmCommand] = candidates.map { candidate in
                let ewe = byID[candidate.sheepID]!
                return .updateSheepProfile(sheepID: ewe.id, earTag: ewe.earTag, breed: ewe.breed,
                    sex: ewe.sex, birthAt: ewe.birthAt, currentParity: candidate.newParity,
                    parityRecordedAt: now, note: ewe.note)
            }
            let previousIDs = Set(priorIntents.map(\.id))
            try FarmCommandService().executeBatch(commands, in: farmContext, context: context)
            let ids = Set(try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>())
                .filter { $0.farmID == farmID && !previousIDs.contains($0.id) }.map(\.id))
            report["commandIDs"] = ids.map(\.uuidString).sorted()
            report["phase"] = "submittedLocally"
            try persist()
            for _ in 0..<60 {
                _ = try await collaboration.synchronizeESheepCloudFarm(farmID: farmID, accountID: account.effectiveAccountID, force: true)
                let check = ModelContext(container)
                let intents = try check.fetch(FetchDescriptor<ESheepCloudPendingIntent>()).filter { ids.contains($0.id) }
                let accepted = intents.filter { $0.lifecycle == .accepted && $0.acceptedEventSequence != nil && $0.serverResultData != nil }
                report["acceptedCount"] = accepted.count
                report["lifecycles"] = Dictionary(grouping: intents, by: \.lifecycleRawValue).mapValues(\.count)
                try persist()
                if intents.contains(where: { $0.lifecycle == .rejected || $0.lifecycle == .needsConfirmation }) {
                    throw RepairError.stopped("待改清单已变化，或云端要求处理冲突")
                }
                if accepted.count == commands.count {
                    let finalState = try check.fetch(FetchDescriptor<ESheepCloudFarmState>()).first { $0.farmID == farmID }!
                    report["cloudHeadAfter"] = finalState.cloudEventHead
                    report["appliedAfter"] = finalState.lastAppliedEventSequence
                    report["integrityAfter"] = finalState.integrityStateRawValue
                    report["phase"] = "cloudAccepted"
                    try persist()
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw RepairError.stopped("存在尚未确认的云端命令")
        } catch {
            report["error"] = error.localizedDescription
            report["phase"] = "stopped"
            try? persist()
        }
    }

    private static func resume(farmID: UUID, accountID: UUID, expected: String, url: URL,
                               container: ModelContainer, collaboration: CloudCollaborationStore) async {
        var report: [String: Any] = [:]
        func persist() throws {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
        do {
            report = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            guard report["digest"] as? String == expected,
                  (report["farmID"] as? String).flatMap(UUID.init(uuidString:)) == farmID,
                  let strings = report["commandIDs"] as? [String] else { throw RepairError.stopped("修正报告不匹配") }
            let ids = Set(strings.compactMap(UUID.init(uuidString:)))
            guard ids.count == report["candidateCount"] as? Int else { throw RepairError.stopped("命令清单不完整") }
            let context = ModelContext(container)
            let rejected = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>()).filter {
                ids.contains($0.id) && $0.farmID == farmID && $0.accountID == accountID && $0.lifecycle == .rejected
            }
            for start in stride(from: 0, to: rejected.count, by: 25) {
                let batch = Array(rejected[start..<min(start + 25, rejected.count)])
                let receipts = try await collaboration.developmentParityCommandStatus(farmID: farmID, commandIDs: batch.map(\.id))
                for intent in batch {
                    guard receipts[intent.id] == nil, let bytes = intent.serverResultData,
                          case .rejected(.malformedCommand) = try ESheepCloudCanonicalCodec.decode(ESheepCloudCommandResultV2.self, from: bytes),
                          intent.commandKind == "sheep.patchProfile" else {
                        throw RepairError.stopped("云端存在回执或失败原因不属于本次时间兼容修复")
                    }
                    let envelope = try ESheepCloudCanonicalCodec.decode(ESheepCloudCommandEnvelopeV2.self, from: intent.commandEnvelopeData)
                    try envelope.validateDigest()
                    intent.lifecycle = .ready
                    intent.nextRetryAt = nil
                    intent.serverResultData = nil
                    intent.lastTransportMessage = "已核对云端无原请求，时间校验修复后按原编号重试"
                }
            }
            try context.save()
            report["phase"] = "resumingOriginalCommands"
            report.removeValue(forKey: "error")
            try persist()
            for _ in 0..<90 {
                _ = try await collaboration.synchronizeESheepCloudFarm(farmID: farmID, accountID: accountID, force: true)
                let check = ModelContext(container)
                let intents = try check.fetch(FetchDescriptor<ESheepCloudPendingIntent>()).filter { ids.contains($0.id) }
                let accepted = intents.filter { $0.lifecycle == .accepted && $0.acceptedEventSequence != nil && $0.serverResultData != nil }
                report["acceptedCount"] = accepted.count
                report["lifecycles"] = Dictionary(grouping: intents, by: \.lifecycleRawValue).mapValues(\.count)
                try persist()
                if intents.contains(where: { $0.lifecycle == .rejected || $0.lifecycle == .needsConfirmation }) {
                    throw RepairError.stopped("原命令重试仍被拒绝或需要处理冲突")
                }
                if accepted.count == ids.count {
                    let state = try check.fetch(FetchDescriptor<ESheepCloudFarmState>()).first { $0.farmID == farmID }!
                    report["cloudHeadAfter"] = state.cloudEventHead
                    report["appliedAfter"] = state.lastAppliedEventSequence
                    report["integrityAfter"] = state.integrityStateRawValue
                    report["phase"] = "cloudAccepted"
                    try persist()
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            throw RepairError.stopped("仍有命令等待云端确认")
        } catch {
            report["error"] = error.localizedDescription
            report["phase"] = "stopped"
            try? persist()
        }
    }

    /// The V2 field reducer appends a canonical baseline on acknowledgement.
    /// Remove only this repair's redundant optimistic baseline, after proving
    /// the matching command receipt and identical canonical business fact.
    static func reconcileConfirmedBaselines(candidates: [Candidate], commandIDs: Set<UUID>,
                                            farmID: UUID, accountID: UUID, context: ModelContext) throws -> Int {
        let intents = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>()).filter {
            commandIDs.contains($0.id) && $0.farmID == farmID && $0.accountID == accountID
        }
        guard intents.count == candidates.count, intents.allSatisfy({ $0.lifecycle == .accepted && $0.serverResultData != nil }) else {
            throw RepairError.stopped("尚未获得全部云端回执，不能归并临时记录")
        }
        let receipts = try context.fetch(FetchDescriptor<ESheepCloudEventReceipt>()).filter { commandIDs.contains($0.commandID) && $0.farmID == farmID }
        let facts = try context.fetch(FetchDescriptor<ReproductionRecord>()).filter { $0.farmID == farmID }
        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        let canonicalIDs = Set(receipts.map { StableCloudUUID.derived(namespace: $0.id, name: "esheep-cloud-profile-parity") })
        var redundant: [ReproductionRecord] = []
        for candidate in candidates {
            let optimisticID = LambingEntrySemantics.parityCorrectionID(sheepID: candidate.sheepID, sheepRevision: candidate.revision + 1)
            guard let optimistic = byID[optimisticID] else { continue }
            guard optimistic.eweID == candidate.sheepID, optimistic.kind == .parityBaseline,
                  optimistic.deletedAt == nil, optimistic.parity == candidate.newParity,
                  facts.contains(where: {
                      canonicalIDs.contains($0.id) && $0.eweID == candidate.sheepID && $0.kind == .parityBaseline &&
                      $0.deletedAt == nil && $0.parity == optimistic.parity && abs($0.occurredAt.timeIntervalSince(optimistic.occurredAt)) < 0.001
                  }) else { throw RepairError.stopped("正式胎次记录与临时记录不一致") }
            redundant.append(optimistic)
        }
        for fact in redundant { context.delete(fact) }
        try context.save()
        return redundant.count
    }

    private static func finalize(farmID: UUID, accountID: UUID, expected: String, url: URL,
                                 container: ModelContainer, collaboration: CloudCollaborationStore) async {
        var report: [String: Any] = [:]
        do {
            report = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            guard report["digest"] as? String == expected,
                  (report["farmID"] as? String).flatMap(UUID.init(uuidString:)) == farmID,
                  report["phase"] as? String == "cloudAccepted",
                  let strings = report["commandIDs"] as? [String], let raw = report["candidates"] else {
                throw RepairError.stopped("已完成修正报告不匹配")
            }
            let candidates = try JSONDecoder().decode([Candidate].self, from: JSONSerialization.data(withJSONObject: raw))
            let count = try reconcileConfirmedBaselines(candidates: candidates,
                commandIDs: Set(strings.compactMap(UUID.init(uuidString:))), farmID: farmID, accountID: accountID,
                context: ModelContext(container))
            report["reconciledOptimisticBaselines"] = count
            _ = try await collaboration.synchronizeESheepCloudFarm(farmID: farmID, accountID: accountID, force: true)
            report["phase"] = "finalized"
        } catch {
            report["error"] = error.localizedDescription
            report["phase"] = "stopped"
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif
