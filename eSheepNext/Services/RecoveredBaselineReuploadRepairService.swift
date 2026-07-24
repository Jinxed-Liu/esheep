import Foundation
import SwiftData

struct RecoveredBaselineReuploadRepairPlan: Sendable {
    let farmID: UUID
    let ownerAccountID: UUID
    let commitID: UUID
    let sessionID: UUID
    let scope: CloudDatabaseScope
    let zoneName: String
    let zoneOwnerName: String
    let authoritativeBootstrap: CloudRebuildBootstrapSnapshot
    let interruptedBootstrap: CloudRebuildBootstrapSnapshot
    let operationIDs: [UUID]
    let pendingRecordNames: Set<String>
}

struct RecoveredBaselineStartupRepairResult: Sendable {
    let plans: [RecoveredBaselineReuploadRepairPlan]
    let blockedScopeRawValues: Set<String>
    let errorMessages: [String]

    static let none = Self(plans: [], blockedScopeRawValues: [], errorMessages: [])

    var privatePendingRecordNames: Set<String> {
        plans
            .filter { $0.scope == .privateDatabase }
            .reduce(into: Set<String>()) { $0.formUnion($1.pendingRecordNames) }
    }

    var sharedPendingRecordNames: Set<String> {
        plans
            .filter { $0.scope == .sharedDatabase }
            .reduce(into: Set<String>()) { $0.formUnion($1.pendingRecordNames) }
    }
}

enum RecoveredBaselineReuploadRepairError: LocalizedError {
    case bundleMissing
    case bundleMismatch
    case bindingMismatch
    case interruptedBaselineMismatch
    case operationSetOverlap
    case timestampMismatch
    case outboxMismatch

    var errorDescription: String? {
        switch self {
        case .bundleMissing: "找不到已完成云端重建的权威 bundle。"
        case .bundleMismatch: "已完成重建 bundle 与恢复提交身份不一致。"
        case .bindingMismatch: "恢复牧场缺少唯一、有效的云端绑定。"
        case .interruptedBaselineMismatch: "待撤销的新基线不能通过完整数量、摘要和稳定 ID 校验。"
        case .operationSetOverlap: "待撤销操作与原云端权威操作发生重叠，已停止自动清理。"
        case .timestampMismatch: "待撤销基线不是在已完成重建之后生成的，已停止自动清理。"
        case .outboxMismatch: "待撤销基线与本机上传队列不完全对应，已停止自动清理。"
        }
    }
}

/// Repairs one narrowly identified regression: a cache rebuilt from a ready
/// CloudKit v2 baseline was immediately mistaken for a fresh local migration,
/// producing a second full baseline and Outbox. The first phase runs before a
/// CKSyncEngine delegate is attached, so no serialized save can race cleanup.
enum RecoveredBaselineReuploadRepairService {
    static let pendingCode = "recoveredBaselineReuploadRepairPending"
    static let blockedCode = "recoveredBaselineReuploadRepairBlocked"
    private static let recoveredChecksumPrefix = "cloud-recovered:"

    static func isBlockingCode(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == pendingCode ||
            value == blockedCode ||
            value.hasPrefix("\(blockedCode):")
    }

    /// Returns a durable repair marker from any of the three records that
    /// participate in the recovery transaction. This is intentionally broader
    /// than `pendingPlans`: malformed evidence must remain blocked rather than
    /// falling through to ordinary migration provisioning.
    static func blockingCode(
        farmID: UUID,
        context: ModelContext
    ) throws -> String? {
        if let code = try context.fetch(FetchDescriptor<CloudFarmBinding>())
            .first(where: { $0.farmID == farmID && isBlockingCode($0.lastErrorCode) })?
            .lastErrorCode {
            return code
        }
        if let error = try context.fetch(FetchDescriptor<MigrationCommitRecord>())
            .first(where: { $0.farmID == farmID && isBlockingCode($0.cloudLastError) })?
            .cloudLastError {
            return error
        }
        if let code = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .first(where: { $0.farmID == farmID && isBlockingCode($0.lastErrorCode) })?
            .lastErrorCode {
            return code
        }
        return nil
    }

    static func blockedFarmIDs(
        ownerAccountID: UUID,
        context: ModelContext
    ) throws -> Set<UUID> {
        let ownerFarmIDs = Set(try context.fetch(FetchDescriptor<FarmRecord>())
            .filter { $0.ownerAccountID == ownerAccountID }
            .map(\.id))
        var candidates = Set(try context.fetch(FetchDescriptor<CloudFarmBinding>())
            .filter { ownerFarmIDs.contains($0.farmID) && isBlockingCode($0.lastErrorCode) }
            .map(\.farmID))
        candidates.formUnion(try context.fetch(FetchDescriptor<MigrationCommitRecord>())
            .filter {
                $0.ownerAccountID == ownerAccountID &&
                    isBlockingCode($0.cloudLastError)
            }
            .map(\.farmID))
        candidates.formUnion(try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter { ownerFarmIDs.contains($0.farmID) && isBlockingCode($0.lastErrorCode) }
            .map(\.farmID))
        return candidates
    }

    static func quarantineBeforeCloudEngineStarts(
        container: ModelContainer
    ) -> RecoveredBaselineStartupRepairResult {
        let context = ModelContext(container)
        let commits: [MigrationCommitRecord]
        do {
            commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).filter {
                $0.status == .completed &&
                    $0.sourceChecksum.hasPrefix(recoveredChecksumPrefix) &&
                    $0.cloudSyncedAt != nil
            }
        } catch {
            return .init(
                plans: [],
                blockedScopeRawValues: [CloudDatabaseScope.privateDatabase.rawValue],
                errorMessages: [error.localizedDescription]
            )
        }

        var plans: [RecoveredBaselineReuploadRepairPlan] = []
        var blockedScopes = Set<String>()
        var messages: [String] = []
        var changed = false

        for commit in commits {
            let sessions = (try? context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())) ?? []
            let isAlreadyPending = sessions.contains {
                $0.id == commit.sessionID && $0.lastErrorCode == pendingCode
            }
            let isInterruptedCandidate = commit.cloudState == .baselineReady ||
                commit.cloudState == .provisioning ||
                commit.cloudState == .uploading ||
                commit.cloudState == .verifying ||
                isAlreadyPending
            guard isInterruptedCandidate else { continue }

            do {
                let plan = try makePlan(
                    commit: commit,
                    requiresOutbox: !isAlreadyPending,
                    context: context
                )
                if !isAlreadyPending {
                    let operationIDs = Set(plan.operationIDs)
                    let outboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
                        $0.farmID == plan.farmID && operationIDs.contains($0.operationID)
                    }
                    for item in outboxes { context.delete(item) }

                    let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter {
                        $0.farmID == plan.farmID
                    }
                    let redundantTransferIDs = Set(photos.map {
                        StableMigrationID.uuid(
                            sessionID: plan.sessionID,
                            sourceKey: "cloud-bootstrap-asset:\($0.id.uuidString.lowercased())"
                        )
                    })
                    let completedAt = sessions.first(where: { $0.id == plan.sessionID })?.completedAt ?? .distantFuture
                    let transfers = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).filter {
                        $0.farmID == plan.farmID &&
                            $0.direction == .upload &&
                            redundantTransferIDs.contains($0.id) &&
                            $0.updatedAt >= completedAt
                    }
                    for transfer in transfers { context.delete(transfer) }

                    commit.cloudState = .verifying
                    commit.cloudLastError = pendingCode
                    if let session = sessions.first(where: { $0.id == plan.sessionID }) {
                        session.lastErrorCode = pendingCode
                        session.lastErrorMessage = "已阻止恢复缓存整库回传，正在精确撤销误生成的云端操作。"
                        session.updatedAt = .now
                    }
                    changed = true
                }
                plans.append(plan)
            } catch {
                let scopeRawValue = failClosed(
                    commit: commit,
                    error: error,
                    context: context
                )
                if let scopeRawValue { blockedScopes.insert(scopeRawValue) }
                messages.append(error.localizedDescription)
                changed = true
            }
        }

        if changed {
            do {
                try context.save()
            } catch {
                return .init(
                    plans: [],
                    blockedScopeRawValues: [CloudDatabaseScope.privateDatabase.rawValue],
                    errorMessages: [error.localizedDescription]
                )
            }
        }
        return .init(
            plans: plans,
            blockedScopeRawValues: blockedScopes,
            errorMessages: messages
        )
    }

    static func pendingPlans(container: ModelContainer) throws -> [RecoveredBaselineReuploadRepairPlan] {
        let context = ModelContext(container)
        let pendingSessionIDs = Set(try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).compactMap {
            $0.lastErrorCode == pendingCode ? $0.id : nil
        })
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).filter {
            pendingSessionIDs.contains($0.sessionID) &&
                $0.cloudState == .verifying &&
                $0.cloudLastError == pendingCode
        }
        return try commits.map { try makePlan(commit: $0, requiresOutbox: false, context: context) }
    }

    static func completedRecoveryBundle(
        commit: MigrationCommitRecord,
        context: ModelContext
    ) throws -> (CloudRebuildSessionRecord, CloudRebuildBundle)? {
        guard commit.sourceChecksum.hasPrefix(recoveredChecksumPrefix),
              let session = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: {
                  $0.id == commit.sessionID &&
                      $0.farmID == commit.farmID &&
                      $0.status == .completed &&
                      $0.databaseScope == .privateDatabase &&
                      $0.completedAt != nil
              }) else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleURL = support
            .appending(path: session.stagingRelativePath, directoryHint: .isDirectory)
            .appending(path: "bundle.json")
        guard let data = try? Data(contentsOf: bundleURL) else {
            throw RecoveredBaselineReuploadRepairError.bundleMissing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(CloudRebuildBundle.self, from: data)
        try CloudRebuildBundleValidator.validate(bundle)
        guard bundle.sessionID == session.id,
              bundle.farmID == commit.farmID,
              bundle.scope == .privateDatabase,
              bundle.root.ownerAccountID == commit.ownerAccountID,
              let bootstrap = bundle.bootstrap,
              bootstrap.normalizedVersion >= 2,
              bootstrap.cutoffAt != nil,
              commit.sourceChecksum == recoveredChecksumPrefix + bootstrap.digest else {
            throw RecoveredBaselineReuploadRepairError.bundleMismatch
        }
        return (session, bundle)
    }

    static func finalize(
        plan: RecoveredBaselineReuploadRepairPlan,
        container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        guard let commit = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: {
            $0.id == plan.commitID &&
                $0.farmID == plan.farmID &&
                $0.sessionID == plan.sessionID &&
                $0.cloudState == .verifying &&
                $0.cloudLastError == pendingCode
        }), let session = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>()).first(where: {
            $0.id == plan.sessionID && $0.lastErrorCode == pendingCode
        }) else {
            throw RecoveredBaselineReuploadRepairError.interruptedBaselineMismatch
        }
        let targetIDs = Set(plan.operationIDs)
        for operation in try context.fetch(FetchDescriptor<DomainOperation>())
        where operation.farmID == plan.farmID && targetIDs.contains(operation.id) {
            context.delete(operation)
        }
        for receipt in try context.fetch(FetchDescriptor<CloudOperationReceipt>())
        where receipt.farmID == plan.farmID && targetIDs.contains(receipt.operationID) {
            context.delete(receipt)
        }
        commit.baselineDigest = plan.authoritativeBootstrap.digest
        commit.baselineEntityCount = plan.authoritativeBootstrap.entityCount
        commit.baselinePhotoCount = plan.authoritativeBootstrap.photoCount
        commit.cloudState = .synced
        commit.cloudLastError = nil
        session.lastErrorCode = nil
        session.lastErrorMessage = nil
        session.updatedAt = .now
        try context.save()
    }

    private static func makePlan(
        commit: MigrationCommitRecord,
        requiresOutbox: Bool,
        context: ModelContext
    ) throws -> RecoveredBaselineReuploadRepairPlan {
        guard let (session, bundle) = try completedRecoveryBundle(commit: commit, context: context),
              let completedAt = session.completedAt,
              let cloudSyncedAt = commit.cloudSyncedAt,
              let authoritative = bundle.bootstrap else {
            throw RecoveredBaselineReuploadRepairError.bundleMissing
        }
        let bindings = try context.fetch(FetchDescriptor<CloudFarmBinding>()).filter {
            $0.farmID == commit.farmID &&
                $0.ownerAccountID == commit.ownerAccountID &&
                $0.databaseScope == .privateDatabase &&
                $0.state == .active
        }
        guard bindings.count == 1, let binding = bindings.first,
              binding.zoneName == CloudZoneName.forFarm(commit.farmID) else {
            throw RecoveredBaselineReuploadRepairError.bindingMismatch
        }

        let required: MigrationBaselineV2RequiredSet
        do {
            required = try MigrationBaselineV2EvidenceContract.requiredOperations(
                commit: commit,
                farmID: commit.farmID,
                context: context
            )
        } catch {
            throw RecoveredBaselineReuploadRepairError.interruptedBaselineMismatch
        }
        guard required.version >= 2,
              required.operations.count == commit.baselineEntityCount,
              required.operations.allSatisfy({
                  $0.summary.hasPrefix(MigrationBaselineV2EvidenceContract.summaryPrefix) &&
                      $0.createdAt >= completedAt &&
                      $0.createdAt >= cloudSyncedAt
              }),
              required.cutoffAt >= completedAt,
              required.cutoffAt >= cloudSyncedAt,
              commit.cloudUpgradedAt.map({ $0 >= completedAt && $0 >= cloudSyncedAt }) == true else {
            throw RecoveredBaselineReuploadRepairError.timestampMismatch
        }

        let originalOperationIDs = Set(bundle.operations.map(\.operationID))
        let operationIDs = Set(required.operations.map(\.id))
        guard originalOperationIDs.isDisjoint(with: operationIDs) else {
            throw RecoveredBaselineReuploadRepairError.operationSetOverlap
        }

        if requiresOutbox {
            let outboxes = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
                $0.farmID == commit.farmID && operationIDs.contains($0.operationID)
            }
            let grouped = Dictionary(grouping: outboxes, by: \.operationID)
            guard grouped.count == required.operations.count,
                  required.operations.allSatisfy({ operation in
                      guard let item = grouped[operation.id]?.only else { return false }
                      return item.farmID == operation.farmID &&
                          item.accountID == operation.accountID &&
                          item.entityType == operation.entityType &&
                          item.entityID == operation.entityID &&
                          item.baseRevision == operation.baseRevision &&
                          item.payloadDigest == operation.payloadDigest &&
                          item.createdAt >= completedAt &&
                          item.createdAt >= cloudSyncedAt
                  }) else {
                throw RecoveredBaselineReuploadRepairError.outboxMismatch
            }
        }

        let mapper = CloudRecordMapper()
        var pendingRecordNames = Set(required.operations.map { mapper.recordName(for: $0.id) })
        pendingRecordNames.formUnion(required.operations.compactMap(\.entityID).map(mapper.entityRecordName(for:)))
        return RecoveredBaselineReuploadRepairPlan(
            farmID: commit.farmID,
            ownerAccountID: commit.ownerAccountID,
            commitID: commit.id,
            sessionID: commit.sessionID,
            scope: binding.databaseScope,
            zoneName: binding.zoneName,
            zoneOwnerName: binding.zoneOwnerName,
            authoritativeBootstrap: authoritative,
            interruptedBootstrap: CloudRebuildBootstrapSnapshot(
                digest: commit.baselineDigest,
                entityCount: commit.baselineEntityCount,
                photoCount: commit.baselinePhotoCount,
                version: required.version,
                cutoffAt: required.cutoffAt
            ),
            operationIDs: required.operations.map(\.id).sorted { $0.uuidString < $1.uuidString },
            pendingRecordNames: pendingRecordNames
        )
    }

    private static func failClosed(
        commit: MigrationCommitRecord,
        error: Error,
        context: ModelContext
    ) -> String? {
        let bindings = (try? context.fetch(FetchDescriptor<CloudFarmBinding>())) ?? []
        let binding = bindings.first(where: { $0.farmID == commit.farmID })
        binding?.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
        binding?.lastErrorCode = blockedCode
        binding?.updatedAt = .now
        commit.cloudState = .failed
        commit.cloudLastError = "\(blockedCode): \(error.localizedDescription)"
        context.insert(SecurityIncidentRecord(
            farmID: commit.farmID,
            incidentType: blockedCode,
            detail: error.localizedDescription
        ))
        return binding?.databaseScopeRawValue
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
