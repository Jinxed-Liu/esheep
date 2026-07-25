import CloudKit
import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

enum CloudAccountAvailability: Equatable, Sendable {
    case checking
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable(String)

    var displayName: String {
        switch self {
        case .checking: "正在检查"
        case .available: "iCloud 可用"
        case .noAccount: "未登录 iCloud"
        case .restricted: "iCloud 受系统限制"
        case .couldNotDetermine: "无法确定 iCloud 状态"
        case .temporarilyUnavailable: "iCloud 暂时不可用"
        }
    }
}

enum CloudSyncError: LocalizedError {
    case featureDisabled
    case accountUnavailable
    case farmBindingMissing
    case rootSaveFailed
    case shareSaveFailed
    case participantMissing
    case localBaselineUnsupported
    case verifiedMigrationRequired
    case localOnlyMigration
    case ownerRequired
    case inactiveFarm
    case recoveryCatchUpFailed(String)

    var errorDescription: String? {
        switch self {
        case .featureDisabled: "当前构建未启用云端协作。"
        case .accountUnavailable: "当前 iCloud 账户不可用。"
        case .farmBindingMissing: "当前牧场尚未建立 CloudKit 绑定。"
        case .rootSaveFailed: "无法保存牧场云端根记录。"
        case .shareSaveFailed: "无法创建牧场共享记录。"
        case .participantMissing: "尚未发现已接受系统共享的新参与者。"
        case .localBaselineUnsupported: "该牧场包含旧格式本地操作，必须先完成正式迁移校验并生成云端基线。"
        case .verifiedMigrationRequired: "当前牧场尚未完成可验证的正式迁移提交和云端基线，不能建立云端牧场。"
        case .localOnlyMigration: "该旧迁移牧场尚未通过完整性校验，暂时只能保留在本机。"
        case .ownerRequired: "只有当前牧场的场主可以建立 CloudKit Zone 和共享。"
        case .inactiveFarm: "当前牧场已删除或成员关系无效，不能启用云端协作。"
        case .recoveryCatchUpFailed(let detail): "恢复后云端增量补齐失败：\(detail)"
        }
    }
}

struct MigrationCloudBaselineSnapshot: Sendable, Equatable {
    let digest: String
    let entityCount: Int
    let photoCount: Int
    let version: Int
    let cutoffAt: Date?
}

struct MigrationUploadProgressWatchdog: Sendable {
    let maximumConsecutiveNoProgressPasses: Int
    private(set) var consecutiveNoProgressPasses = 0

    init(maximumConsecutiveNoProgressPasses: Int = 30) {
        precondition(maximumConsecutiveNoProgressPasses > 0)
        self.maximumConsecutiveNoProgressPasses = maximumConsecutiveNoProgressPasses
    }

    mutating func observe(
        scheduledRecordCount: Int,
        unconfirmedBefore: Int,
        unconfirmedAfter: Int
    ) -> Bool {
        guard scheduledRecordCount > 0 else {
            reset()
            return false
        }
        guard unconfirmedAfter >= unconfirmedBefore else {
            reset()
            return false
        }
        consecutiveNoProgressPasses += 1
        return consecutiveNoProgressPasses >= maximumConsecutiveNoProgressPasses
    }

    mutating func reset() {
        consecutiveNoProgressPasses = 0
    }
}

enum CloudSyncHardDeadlineError: LocalizedError, Equatable, Sendable {
    case timedOut

    var errorDescription: String? {
        "CloudKit 本批同步超过硬时限，已请求取消并等待原操作收尾。"
    }
}

private actor CloudSyncHardDeadlineSignal {
    private var result: Result<Void, any Error>?
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func wait() async throws {
        if let result {
            return try result.get()
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    @discardableResult
    func resolve(
        _ result: Result<Void, any Error>,
        beforeResuming: (@Sendable () -> Void)? = nil
    ) -> Bool {
        guard self.result == nil else { return false }
        self.result = result
        beforeResuming?()
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
        return true
    }
}

enum CloudSyncHardDeadline {
    static func wait(
        for task: Task<Void, any Error>,
        timeout: Duration,
        onCancellation: @escaping @Sendable () -> Void
    ) async throws {
        let signal = CloudSyncHardDeadlineSignal()
        let waiter = Task {
            do {
                try await task.value
                _ = await signal.resolve(.success(()))
            } catch {
                _ = await signal.resolve(.failure(error))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            _ = await signal.resolve(.failure(CloudSyncHardDeadlineError.timedOut)) {
                task.cancel()
                onCancellation()
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await signal.wait()
            } onCancel: {
                waiter.cancel()
                timer.cancel()
                Task {
                    _ = await signal.resolve(.failure(CancellationError())) {
                        task.cancel()
                        onCancellation()
                    }
                }
            }
            timer.cancel()
        } catch {
            timer.cancel()
            throw error
        }
    }
}

private final class CloudSyncEngineDelegateProxy: CKSyncEngineDelegate, @unchecked Sendable {
    weak var owner: CloudSyncActor?

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await owner?.handleEvent(event, syncEngine: syncEngine)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await owner?.nextRecordZoneChangeBatch(context, syncEngine: syncEngine)
    }
}

actor CloudSyncActor {
    private struct ActiveManualBatch: Sendable {
        let id: UUID
        let task: Task<Void, any Error>
        let engines: [CKSyncEngine]
    }

    private struct RecoveryFetchContext: Sendable {
        let farmID: UUID
        let scope: CloudDatabaseScope
        var records: [CKRecord] = []
        var deletions: [CKDatabase.RecordZoneChange.Deletion] = []
    }

    private struct ActiveRecoveryReset: Sendable {
        let id: UUID
        let farmID: UUID
        let task: Task<Void, any Error>
    }

    private static let manualBatchTimeout: Duration = .seconds(60)
    private let container: CKContainer
    private let persistence: FarmPersistenceActor
    private let deviceIdentity: DeviceIdentityActor
    private let mapper = CloudRecordMapper()
    private let delegateProxy: CloudSyncEngineDelegateProxy
    private var privateEngine: CKSyncEngine
    private var sharedEngine: CKSyncEngine
    /// CKSyncEngine delegate callbacks can arrive after an engine reset. Keep
    /// an explicit identity map so a retired private engine can never be
    /// mistaken for the current shared engine (or vice versa).
    private var engineScopes: [ObjectIdentifier: CloudDatabaseScope] = [:]
    private var activeManualBatch: ActiveManualBatch?
    private var expectedResetSignInEngineIDs = Set<ObjectIdentifier>()
    private var recoveryFetchContexts: [ObjectIdentifier: RecoveryFetchContext] = [:]
    private var recoveryFetchFailures: [ObjectIdentifier: String] = [:]
    /// Manual fetch/send batches and recovery resets both replace or operate
    /// on the same engine objects. A single FIFO gate closes the preparation
    /// window where one path could capture an engine while the other retires it.
    private var engineOperationGateHeld = false
    private var engineOperationGateWaiters: [CheckedContinuation<Void, Never>] = []
    /// One CKSyncEngine instance serves an entire database scope. Serialize
    /// recovery resets so a second caller cannot retire an engine that the
    /// first caller is still validating.
    private var activeRecoveryResets: [String: ActiveRecoveryReset] = [:]
    /// Prevent a new reset from reclaiming the same persisted in-progress code
    /// while the coordinator is converting a crash-left claim into a required
    /// fresh rebuild.
    private var recoveryResetTakeoverScopes = Set<String>()

    init(
        containerIdentifier: String?,
        persistence: FarmPersistenceActor,
        deviceIdentity: DeviceIdentityActor = .shared,
        startupRepair: RecoveredBaselineStartupRepairResult = .none
    ) {
        let container: CKContainer
        if let containerIdentifier, !containerIdentifier.isEmpty {
            container = CKContainer(identifier: containerIdentifier)
        } else {
            container = .default()
        }
        self.container = container
        self.persistence = persistence
        self.deviceIdentity = deviceIdentity
        let proxy = CloudSyncEngineDelegateProxy()
        self.delegateProxy = proxy

        var privateConfiguration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: CloudEngineStateDiskStore.load(scope: .privateDatabase),
            delegate: proxy
        )
        privateConfiguration.automaticallySync =
            !CloudEngineStateDiskStore.wasCorrupted(scope: .privateDatabase) &&
            !startupRepair.blockedScopeRawValues.contains(CloudDatabaseScope.privateDatabase.rawValue)
        privateConfiguration.subscriptionID = "esheep-next-private"
        self.privateEngine = CKSyncEngine(privateConfiguration)

        var sharedConfiguration = CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase,
            stateSerialization: CloudEngineStateDiskStore.load(scope: .sharedDatabase),
            delegate: proxy
        )
        sharedConfiguration.automaticallySync =
            !CloudEngineStateDiskStore.wasCorrupted(scope: .sharedDatabase) &&
            !startupRepair.blockedScopeRawValues.contains(CloudDatabaseScope.sharedDatabase.rawValue)
        sharedConfiguration.subscriptionID = "esheep-next-shared"
        self.sharedEngine = CKSyncEngine(sharedConfiguration)
        self.engineScopes = [
            ObjectIdentifier(self.privateEngine): .privateDatabase,
            ObjectIdentifier(self.sharedEngine): .sharedDatabase,
        ]

        let privateStaleChanges = self.privateEngine.state.pendingRecordZoneChanges.filter { change in
            guard case .saveRecord(let recordID) = change else { return false }
            return startupRepair.privatePendingRecordNames.contains(recordID.recordName)
        }
        if !privateStaleChanges.isEmpty {
            self.privateEngine.state.remove(pendingRecordZoneChanges: privateStaleChanges)
        }
        let sharedStaleChanges = self.sharedEngine.state.pendingRecordZoneChanges.filter { change in
            guard case .saveRecord(let recordID) = change else { return false }
            return startupRepair.sharedPendingRecordNames.contains(recordID.recordName)
        }
        if !sharedStaleChanges.isEmpty {
            self.sharedEngine.state.remove(pendingRecordZoneChanges: sharedStaleChanges)
        }
        proxy.owner = self
    }

    func accountAvailability() async -> CloudAccountAvailability {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .couldNotDetermine
            case .temporarilyUnavailable: return .temporarilyUnavailable("CloudKit 报告账户暂时不可用。")
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return .temporarilyUnavailable(error.localizedDescription)
        }
    }

    func corruptedStateScopes() -> [CloudDatabaseScope] {
        [.privateDatabase, .sharedDatabase].filter { CloudEngineStateDiskStore.wasCorrupted(scope: $0) }
    }

    func prepareOwnerFarm(farmID: UUID, farmName: String, ownerAccountID: UUID) async throws -> CKShare {
        guard CloudFeatureConfiguration.isEnabled else { throw CloudSyncError.featureDisabled }
        try await persistence.requireCloudAdmission(farmID: farmID, environment: .current)
        guard await accountAvailability() == .available else { throw CloudSyncError.accountUnavailable }
        guard try await persistence.isCloudPreparationReady(farmID: farmID) else {
            throw CloudSyncError.localBaselineUnsupported
        }
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneName.forFarm(farmID), ownerName: CKCurrentUserDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)
        let recoveryZoneID = CKRecordZone.ID(zoneName: CloudZoneName.recovery(for: farmID), ownerName: CKCurrentUserDefaultName)
        let recoveryZone = CKRecordZone(zoneID: recoveryZoneID)
        let zoneResult = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone, recoveryZone], deleting: [])
        _ = try zoneResult.saveResults[zoneID]?.get()
        _ = try zoneResult.saveResults[recoveryZoneID]?.get()

        let root = mapper.rootRecord(farmID: farmID, farmName: farmName, ownerAccountID: ownerAccountID, zoneID: zoneID)
        if let baseline = try await persistence.migrationCloudBaseline(farmID: farmID) {
            root[CloudRecordField.bootstrapState] = "provisioning" as CKRecordValue
            root[CloudRecordField.bootstrapDigest] = baseline.digest as CKRecordValue
            root[CloudRecordField.bootstrapEntityCount] = baseline.entityCount as CKRecordValue
            root[CloudRecordField.bootstrapPhotoCount] = baseline.photoCount as CKRecordValue
            root[CloudRecordField.bootstrapVersion] = baseline.version as CKRecordValue
            if let cutoffAt = baseline.cutoffAt {
                root[CloudRecordField.bootstrapCutoffAt] = cutoffAt as CKRecordValue
            }
        }
        let share = CKShare(recordZoneID: zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = farmName as CKRecordValue
        let result = try await container.privateCloudDatabase.modifyRecords(saving: [root, share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard (try result.saveResults[root.recordID]?.get()) != nil else { throw CloudSyncError.rootSaveFailed }
        guard let savedShare = try result.saveResults[share.recordID]?.get() as? CKShare else { throw CloudSyncError.shareSaveFailed }
        try await persistence.upsertBinding(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            scope: .privateDatabase,
            shareRecordName: savedShare.recordID.recordName,
            state: .active
        )
        return savedShare
    }

    func markMigrationBootstrapUpdating(farmID: UUID, baseline: MigrationCloudBaselineSnapshot) async throws {
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID), binding.databaseScope == .privateDatabase else {
            throw CloudSyncError.farmBindingMissing
        }
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: "root_\(farmID.uuidString.lowercased())", zoneID: zoneID)
        let record = try await container.privateCloudDatabase.record(for: recordID)
        record[CloudRecordField.bootstrapState] = "updating" as CKRecordValue
        record[CloudRecordField.bootstrapDigest] = baseline.digest as CKRecordValue
        record[CloudRecordField.bootstrapEntityCount] = baseline.entityCount as CKRecordValue
        record[CloudRecordField.bootstrapPhotoCount] = baseline.photoCount as CKRecordValue
        record[CloudRecordField.bootstrapVersion] = baseline.version as CKRecordValue
        if let cutoffAt = baseline.cutoffAt {
            record[CloudRecordField.bootstrapCutoffAt] = cutoffAt as CKRecordValue
        } else {
            record[CloudRecordField.bootstrapCutoffAt] = nil
        }
        record[CloudRecordField.modifiedAt] = Date.now as CKRecordValue
        let result = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        _ = try result.saveResults[recordID]?.get()
    }

    func markMigrationBootstrapReady(farmID: UUID, baseline: MigrationCloudBaselineSnapshot) async throws {
        guard let localEvidence = try await persistence.verifiedMigrationCloudBaselineForReady(farmID: farmID),
              localEvidence == baseline else {
            throw CloudSyncError.verifiedMigrationRequired
        }
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID), binding.databaseScope == .privateDatabase else {
            throw CloudSyncError.farmBindingMissing
        }
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: "root_\(farmID.uuidString.lowercased())", zoneID: zoneID)
        let record = try await container.privateCloudDatabase.record(for: recordID)
        guard record[CloudRecordField.bootstrapDigest] as? String == baseline.digest else { throw CloudContractError.invalidPayloadDigest }
        record[CloudRecordField.bootstrapState] = "ready" as CKRecordValue
        record[CloudRecordField.bootstrapEntityCount] = baseline.entityCount as CKRecordValue
        record[CloudRecordField.bootstrapPhotoCount] = baseline.photoCount as CKRecordValue
        record[CloudRecordField.bootstrapVersion] = baseline.version as CKRecordValue
        if let cutoffAt = baseline.cutoffAt {
            record[CloudRecordField.bootstrapCutoffAt] = cutoffAt as CKRecordValue
        } else {
            record[CloudRecordField.bootstrapCutoffAt] = nil
        }
        record[CloudRecordField.modifiedAt] = Date.now as CKRecordValue
        let result = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        _ = try result.saveResults[recordID]?.get()
    }

    /// Removes only the operation records created by the recovered-baseline
    /// reupload regression, then restores the exact ready root captured by the
    /// completed rebuild bundle. Entity and asset records are never deleted.
    func repairRecoveredBaselineReupload(
        _ plan: RecoveredBaselineReuploadRepairPlan
    ) async throws {
        guard await accountAvailability() == .available else {
            throw CloudSyncError.accountUnavailable
        }
        guard let binding = try await persistence.bindingSnapshot(farmID: plan.farmID),
              binding.state == .active,
              binding.ownerAccountID == plan.ownerAccountID,
              binding.databaseScope == plan.scope,
              binding.zoneName == plan.zoneName,
              binding.zoneOwnerName == plan.zoneOwnerName else {
            throw CloudSyncError.farmBindingMissing
        }
        let database = plan.scope == .privateDatabase
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: plan.zoneOwnerName)
        let rootID = CKRecord.ID(
            recordName: "root_\(plan.farmID.uuidString.lowercased())",
            zoneID: zoneID
        )
        let initialRoot = try await database.record(for: rootID)
        try validateRepairableRoot(initialRoot, plan: plan)

        let operationRecordIDs = plan.operationIDs.map {
            CKRecord.ID(recordName: mapper.recordName(for: $0), zoneID: zoneID)
        }
        for start in stride(from: 0, to: operationRecordIDs.count, by: 200) {
            try Task.checkCancellation()
            let end = min(start + 200, operationRecordIDs.count)
            let batch = Array(operationRecordIDs[start..<end])
            let result = try await database.modifyRecords(
                saving: [],
                deleting: batch,
                savePolicy: .changedKeys,
                atomically: false
            )
            for recordID in batch {
                guard let deletion = result.deleteResults[recordID] else {
                    throw CloudSyncError.recoveryCatchUpFailed("云端未返回误上传操作的删除结果。")
                }
                do {
                    try deletion.get()
                } catch let error as CKError where error.code == .unknownItem {
                    // Not uploaded before Air was stopped; already clean.
                }
            }
        }

        let currentRoot = try await database.record(for: rootID)
        try validateRepairableRoot(currentRoot, plan: plan)
        if currentRoot[CloudRecordField.bootstrapState] as? String != "ready" {
            currentRoot[CloudRecordField.bootstrapState] = "ready" as CKRecordValue
            currentRoot[CloudRecordField.bootstrapDigest] = plan.authoritativeBootstrap.digest as CKRecordValue
            currentRoot[CloudRecordField.bootstrapEntityCount] = plan.authoritativeBootstrap.entityCount as CKRecordValue
            currentRoot[CloudRecordField.bootstrapPhotoCount] = plan.authoritativeBootstrap.photoCount as CKRecordValue
            currentRoot[CloudRecordField.bootstrapVersion] = plan.authoritativeBootstrap.normalizedVersion as CKRecordValue
            if let cutoffAt = plan.authoritativeBootstrap.cutoffAt {
                currentRoot[CloudRecordField.bootstrapCutoffAt] = cutoffAt as CKRecordValue
            } else {
                currentRoot[CloudRecordField.bootstrapCutoffAt] = nil
            }
            currentRoot[CloudRecordField.modifiedAt] = Date.now as CKRecordValue
            let result = try await database.modifyRecords(
                saving: [currentRoot],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            _ = try result.saveResults[rootID]?.get()
        }

        let verifiedRoot = try await database.record(for: rootID)
        guard verifiedRoot[CloudRecordField.bootstrapState] as? String == "ready",
              bootstrapSnapshot(from: verifiedRoot) == plan.authoritativeBootstrap else {
            throw CloudSyncError.recoveryCatchUpFailed("云端根记录未恢复到已验证的原 v2 基线。")
        }
    }

    private func validateRepairableRoot(
        _ record: CKRecord,
        plan: RecoveredBaselineReuploadRepairPlan
    ) throws {
        let root = try mapper.farmRootValue(from: record)
        guard root.farmID == plan.farmID,
              root.ownerAccountID == plan.ownerAccountID,
              record.recordID.zoneID.zoneName == plan.zoneName,
              record.recordID.zoneID.ownerName == plan.zoneOwnerName else {
            throw CloudSyncError.recoveryCatchUpFailed("云端根记录不属于待修复牧场。")
        }
        let state = record[CloudRecordField.bootstrapState] as? String
        let identity = bootstrapSnapshot(from: record)
        let isInterruptedRoot = state == "updating" && identity == plan.interruptedBootstrap
        let isAlreadyRestoredRoot = state == "ready" && identity == plan.authoritativeBootstrap
        guard isInterruptedRoot || isAlreadyRestoredRoot else {
            throw CloudSyncError.recoveryCatchUpFailed("云端根记录已发生其他变化，未执行自动删除。")
        }
    }

    private func bootstrapSnapshot(from record: CKRecord) -> CloudRebuildBootstrapSnapshot? {
        guard let digest = record[CloudRecordField.bootstrapDigest] as? String,
              !digest.isEmpty,
              let cutoffAt = record[CloudRecordField.bootstrapCutoffAt] as? Date else { return nil }
        let entityCount = (record[CloudRecordField.bootstrapEntityCount] as? NSNumber)?.intValue ?? -1
        let photoCount = (record[CloudRecordField.bootstrapPhotoCount] as? NSNumber)?.intValue ?? -1
        let version = (record[CloudRecordField.bootstrapVersion] as? NSNumber)?.intValue ?? -1
        guard entityCount > 0, photoCount >= 0, version >= 2 else { return nil }
        return CloudRebuildBootstrapSnapshot(
            digest: digest,
            entityCount: entityCount,
            photoCount: photoCount,
            version: version,
            cutoffAt: cutoffAt
        )
    }

    func attachAcceptedShare(farmID: UUID, ownerAccountID: UUID, zoneID: CKRecordZone.ID, shareRecordName: String) async throws {
        try await persistence.upsertBinding(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            scope: .sharedDatabase,
            shareRecordName: shareRecordName,
            zoneOwnerName: zoneID.ownerName,
            state: .requiresAccountReview
        )
        try await persistence.stageAcceptedSharedFarm(farmID: farmID, temporaryOwnerAccountID: ownerAccountID)
    }

    func ownerShare(farmID: UUID) async throws -> CKShare {
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID),
              binding.databaseScope == .privateDatabase,
              let shareRecordName = binding.shareRecordName else {
            throw CloudSyncError.farmBindingMissing
        }
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: shareRecordName, zoneID: zoneID)
        guard let share = try await container.privateCloudDatabase.record(for: recordID) as? CKShare else {
            throw CloudSyncError.shareSaveFailed
        }
        return share
    }

    func acceptedParticipantRecordNames(farmID: UUID) async throws -> [String] {
        let share = try await ownerShare(farmID: farmID)
        return share.participants.compactMap { participant in
            guard participant.role != .owner,
                  participant.acceptanceStatus == .accepted else { return nil }
            return participant.userIdentity.userRecordID?.recordName
        }
    }

    func removeParticipant(farmID: UUID, participantRecordName: String) async throws {
        let share = try await ownerShare(farmID: farmID)
        guard let participant = share.participants.first(where: {
            $0.userIdentity.userRecordID?.recordName == participantRecordName && $0.role != .owner
        }) else { throw CloudSyncError.participantMissing }
        share.removeParticipant(participant)
        let result = try await container.privateCloudDatabase.modifyRecords(
            saving: [share],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        _ = try result.saveResults[share.recordID]?.get()
    }

    func leaveSharedFarm(farmID: UUID) async throws {
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID),
              binding.databaseScope == .sharedDatabase else {
            throw CloudSyncError.farmBindingMissing
        }
        let zoneID = CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        try await persistence.revokeSharedAccess(farmID: farmID)
    }

    func synchronizeNow() async throws {
        _ = try await synchronizeBatch(maxOutboxItems: 25)
    }

    @discardableResult
    func synchronizeBatch(maxOutboxItems: Int, farmID: UUID? = nil) async throws -> Int {
        guard CloudFeatureConfiguration.isEnabled else { throw CloudSyncError.featureDisabled }
        await acquireEngineOperationGate()
        defer { releaseEngineOperationGate() }
        try Task.checkCancellation()
        try await finishActiveManualBatchIfNeeded()
        let pending = try await persistence.pendingRecordIDs(
            maxOutboxItems: maxOutboxItems,
            farmID: farmID
        )
        let privateRecordIDs = pending.filter { $0.1 == .privateDatabase }.map(\.0)
        let sharedRecordIDs = pending.filter { $0.1 == .sharedDatabase }.map(\.0)
        let privateChanges = privateRecordIDs.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0) }
        let sharedChanges = sharedRecordIDs.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0) }
        if !privateChanges.isEmpty { privateEngine.state.add(pendingRecordZoneChanges: privateChanges) }
        if !sharedChanges.isEmpty { sharedEngine.state.add(pendingRecordZoneChanges: sharedChanges) }
        let privateEngine = self.privateEngine
        let sharedEngine = self.sharedEngine
        let persistence = self.persistence
        let task = Task<Void, any Error> {
            async let privateFetch: Void = privateEngine.fetchChanges()
            async let sharedFetch: Void = sharedEngine.fetchChanges()
            _ = try await (privateFetch, sharedFetch)
            do {
                async let privateSend: Void = Self.sendChanges(
                    with: privateEngine,
                    recordIDs: privateRecordIDs
                )
                async let sharedSend: Void = Self.sendChanges(
                    with: sharedEngine,
                    recordIDs: sharedRecordIDs
                )
                _ = try await (privateSend, sharedSend)
            } catch {
                // CKSyncEngine invokes its completion only after related
                // delegate events finish. Defer only after that completion so
                // a late success cannot race a second transmission.
                try await persistence.deferUnresolvedUploadsAfterBatchError(error, farmID: farmID)
            }
        }
        let active = ActiveManualBatch(
            id: UUID(),
            task: task,
            engines: [privateEngine, sharedEngine]
        )
        activeManualBatch = active
        watchForManualBatchCompletion(active)
        try await waitForManualBatch(active)
        return pending.count
    }

    private static func sendChanges(with engine: CKSyncEngine, recordIDs: [CKRecord.ID]) async throws {
        guard !recordIDs.isEmpty else { return }
        try await engine.sendChanges(.init(scope: .recordIDs(recordIDs)))
    }

    private func finishActiveManualBatchIfNeeded() async throws {
        guard let activeManualBatch else { return }
        do {
            try await waitForManualBatch(activeManualBatch)
            clearActiveManualBatch(id: activeManualBatch.id)
        } catch is CloudSyncHardDeadlineError {
            // The timed-out CKSyncEngine operation can still deliver delegate
            // events. Keep the gate closed until its Task actually completes.
            throw CloudSyncHardDeadlineError.timedOut
        } catch is CancellationError {
            // Caller cancellation also only requests CKSyncEngine cancellation;
            // its delegate may still finish later, so retain the same gate.
            throw CancellationError()
        } catch {
            clearActiveManualBatch(id: activeManualBatch.id)
            throw error
        }
    }

    private func waitForManualBatch(_ active: ActiveManualBatch) async throws {
        try await CloudSyncHardDeadline.wait(
            for: active.task,
            timeout: Self.manualBatchTimeout
        ) {
            for engine in active.engines {
                Task {
                    await engine.cancelOperations()
                }
            }
        }
    }

    private func watchForManualBatchCompletion(_ active: ActiveManualBatch) {
        Task { [weak self] in
            _ = await active.task.result
            await self?.clearActiveManualBatch(id: active.id)
        }
    }

    private func clearActiveManualBatch(id: UUID) {
        guard activeManualBatch?.id == id else { return }
        activeManualBatch = nil
    }

    private func acquireEngineOperationGate() async {
        if !engineOperationGateHeld {
            engineOperationGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            engineOperationGateWaiters.append(continuation)
        }
    }

    private func releaseEngineOperationGate() {
        if engineOperationGateWaiters.isEmpty {
            engineOperationGateHeld = false
        } else {
            engineOperationGateWaiters.removeFirst().resume()
        }
    }

    func resetEngineForLockedFarmAndActivate(scope: CloudDatabaseScope, farmID: UUID) async throws {
        let scopeKey = scope.rawValue
        guard !recoveryResetTakeoverScopes.contains(scopeKey) else {
            throw CloudSyncError.recoveryCatchUpFailed("该云数据库正在接管失效的增量引擎恢复标记。")
        }
        if let active = activeRecoveryResets[scopeKey] {
            if active.farmID == farmID {
                return try await active.task.value
            }
            _ = await active.task.result
            clearRecoveryReset(scopeKey: scopeKey, id: active.id)
            return try await resetEngineForLockedFarmAndActivate(scope: scope, farmID: farmID)
        }

        let attemptID = UUID()
        let task = Task { [self] in
            try await performRecoveryEngineReset(
                scope: scope,
                farmID: farmID,
                attemptID: attemptID
            )
        }
        activeRecoveryResets[scopeKey] = ActiveRecoveryReset(
            id: attemptID,
            farmID: farmID,
            task: task
        )
        do {
            try await task.value
            clearRecoveryReset(scopeKey: scopeKey, id: attemptID)
        } catch {
            clearRecoveryReset(scopeKey: scopeKey, id: attemptID)
            throw error
        }
    }

    /// An `engineResetInProgress` value can survive a process crash. If the
    /// completed cache bundle no longer has the current immutable-operation
    /// proof, join a genuinely active reset in this process; otherwise take
    /// over the stale claim with an exact CAS so the coordinator can perform a
    /// new authoritative rebuild instead of deadlocking on `bindingMissing`.
    func prepareFreshRebuildAfterUnverifiedResetClaim(
        scope: CloudDatabaseScope,
        farmID: UUID
    ) async throws -> Bool {
        let scopeKey = scope.rawValue
        if let active = activeRecoveryResets[scopeKey] {
            if active.farmID == farmID {
                let result = await active.task.result
                clearRecoveryReset(scopeKey: scopeKey, id: active.id)
                switch result {
                case .success: return false
                case .failure: return true
                }
            }
            _ = await active.task.result
            clearRecoveryReset(scopeKey: scopeKey, id: active.id)
            return try await prepareFreshRebuildAfterUnverifiedResetClaim(
                scope: scope,
                farmID: farmID
            )
        }

        guard recoveryResetTakeoverScopes.insert(scopeKey).inserted else {
            throw CloudSyncError.recoveryCatchUpFailed("增量引擎恢复标记正在由另一任务接管。")
        }
        defer { recoveryResetTakeoverScopes.remove(scopeKey) }
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID),
              binding.databaseScope == scope else {
            throw CloudSyncError.farmBindingMissing
        }
        guard binding.state == .rebuildingCache else { return false }
        guard binding.lastErrorCode == "engineResetInProgress" else { return true }
        guard activeRecoveryResets[scopeKey] == nil else {
            throw CloudSyncError.recoveryCatchUpFailed("增量引擎恢复任务在接管期间发生变化。")
        }
        let transitioned = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: farmID,
            expectedState: .rebuildingCache,
            expectedLastErrorCode: "engineResetInProgress",
            newState: .rebuildingCache,
            newLastErrorCode: "rebuildCommitRequiresFreshRebuild"
        )
        guard transitioned else {
            throw CloudSyncError.recoveryCatchUpFailed("增量引擎恢复标记已变化，请重试。")
        }
        return true
    }

    private func performRecoveryEngineReset(
        scope: CloudDatabaseScope,
        farmID: UUID,
        attemptID: UUID
    ) async throws {
        await acquireEngineOperationGate()
        defer { releaseEngineOperationGate() }
        try Task.checkCancellation()
        guard let initialBinding = try await persistence.bindingSnapshot(farmID: farmID),
              initialBinding.databaseScope == scope,
              initialBinding.state == .rebuildingCache,
              Self.isAllowedRecoveryEngineResetCode(initialBinding.lastErrorCode) else {
            throw CloudSyncError.farmBindingMissing
        }
        try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
        let isAccountReviewReset = Self.isAccountReviewEngineResetCode(initialBinding.lastErrorCode)
        let provenOperationSources = try await persistence.provenOperationSourcesForRecovery(
            farmID: farmID,
            scope: scope
        )
        let resetInProgressCode = isAccountReviewReset
            ? "accountReviewEngineResetInProgress"
            : "engineResetInProgress"
        let claimed = try await persistence.transitionRecoveryBindingIfUnchanged(
            farmID: farmID,
            expectedState: .rebuildingCache,
            expectedLastErrorCode: initialBinding.lastErrorCode,
            newState: .rebuildingCache,
            newLastErrorCode: resetInProgressCode
        )
        guard claimed else { throw CloudSyncError.farmBindingMissing }
        try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
        do {
            try await finishActiveManualBatchIfNeeded()
            try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
        } catch {
            try? await recordRetryableRecoveryResetFailure(
                farmID: farmID,
                initialErrorCode: resetInProgressCode,
                scope: scope,
                attemptID: attemptID
            )
            throw error
        }

        let retiredEngine = scope == .privateDatabase ? privateEngine : sharedEngine
        let retiredEngineID = ObjectIdentifier(retiredEngine)
        // Remove the identity before cancellation yields. Any already queued
        // delegate callback from this engine will then fail closed.
        engineScopes.removeValue(forKey: retiredEngineID)
        expectedResetSignInEngineIDs.remove(retiredEngineID)
        recoveryFetchContexts[retiredEngineID] = nil
        recoveryFetchFailures[retiredEngineID] = nil
        await retiredEngine.cancelOperations()
        try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
        do {
            try CloudEngineStateDiskStore.remove(scope: scope)
        } catch {
            try? await recordRetryableRecoveryResetFailure(
                farmID: farmID,
                initialErrorCode: resetInProgressCode,
                scope: scope,
                attemptID: attemptID
            )
            throw error
        }
        let database = scope == .privateDatabase ? container.privateCloudDatabase : container.sharedCloudDatabase
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: nil,
            delegate: delegateProxy
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = scope == .privateDatabase ? "esheep-next-private" : "esheep-next-shared"
        let engine = CKSyncEngine(configuration)
        let engineID = ObjectIdentifier(engine)
        engineScopes[engineID] = scope
        expectedResetSignInEngineIDs.insert(engineID)
        recoveryFetchContexts[engineID] = RecoveryFetchContext(farmID: farmID, scope: scope)
        recoveryFetchFailures[engineID] = nil
        defer {
            expectedResetSignInEngineIDs.remove(engineID)
            recoveryFetchContexts[engineID] = nil
            recoveryFetchFailures[engineID] = nil
        }
        if scope == .privateDatabase {
            privateEngine = engine
        } else {
            sharedEngine = engine
        }
        do {
            do {
                try await engine.fetchChanges()
                try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
            } catch {
                try? await recordRetryableRecoveryResetFailure(
                    farmID: farmID,
                    initialErrorCode: resetInProgressCode,
                    scope: scope,
                    attemptID: attemptID
                )
                throw error
            }
            expectedResetSignInEngineIDs.remove(engineID)
            if let detail = recoveryFetchFailures[engineID] {
                throw CloudSyncError.recoveryCatchUpFailed(detail)
            }
            guard let recoveryBatch = recoveryFetchContexts[engineID],
                  recoveryBatch.farmID == farmID,
                  recoveryBatch.scope == scope else {
                throw CloudSyncError.recoveryCatchUpFailed("增量恢复批次身份已变化。")
            }
            try await refreshMissingDeviceTrust(
                for: recoveryBatch.records,
                scope: scope,
                recoveryFarmID: farmID,
                recoveryOperationRecordNames: Set(provenOperationSources.keys)
            )
            let affectedByGaps = try await persistence.ingest(
                recoveryBatch.records,
                scope: scope,
                recoveryFarmID: farmID,
                recoveryOperationSources: provenOperationSources
            )
            guard affectedByGaps.isEmpty else {
                throw CloudSyncError.recoveryCatchUpFailed("增量恢复仍存在操作 revision 缺口。")
            }
            let affectedByDeletions = try await persistence.recordUnexpectedDeletions(
                recoveryBatch.deletions,
                recoveryFarmID: farmID,
                recoveryAuthoritativeOperationRecordNames: Set(provenOperationSources.keys)
            )
            guard affectedByDeletions.isEmpty else {
                throw CloudSyncError.recoveryCatchUpFailed("增量恢复检测到不可变操作被硬删除。")
            }
            let expectation = try await persistence.recoveryRootExpectation(
                farmID: farmID,
                scope: scope,
                expectedLastErrorCode: resetInProgressCode
            )
            try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
            try await validateRecoveryRoot(expectation)
            try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
            try await persistence.activateAfterRecoveryCatchUp(
                farmID: farmID,
                expected: expectation
            )
            try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
        } catch {
            try? await recordRecoveryValidationFailure(
                farmID: farmID,
                initialErrorCode: resetInProgressCode,
                scope: scope,
                attemptID: attemptID
            )
            throw error
        }
    }

    private func clearRecoveryReset(scopeKey: String, id: UUID) {
        guard activeRecoveryResets[scopeKey]?.id == id else { return }
        activeRecoveryResets[scopeKey] = nil
    }

    private func requireCurrentRecoveryReset(
        scope: CloudDatabaseScope,
        farmID: UUID,
        id: UUID
    ) throws {
        guard let active = activeRecoveryResets[scope.rawValue],
              active.id == id,
              active.farmID == farmID else {
            throw CancellationError()
        }
    }

    private func recordRetryableRecoveryResetFailure(
        farmID: UUID,
        initialErrorCode: String?,
        scope: CloudDatabaseScope,
        attemptID: UUID
    ) async throws {
        try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
        let failureCode = Self.isAccountReviewEngineResetCode(initialErrorCode)
            ? "accountReviewEngineResetFailed"
            : "engineResetFailed"
        _ = try await persistence.recordRecoveryEngineFailureIfUnchanged(
            farmID: farmID,
            expectedLastErrorCode: initialErrorCode,
            failureCode: failureCode
        )
    }

    private func recordRecoveryValidationFailure(
        farmID: UUID,
        initialErrorCode: String?,
        scope: CloudDatabaseScope,
        attemptID: UUID
    ) async throws {
        try requireCurrentRecoveryReset(scope: scope, farmID: farmID, id: attemptID)
        _ = try await persistence.recordRecoveryEngineFailureIfUnchanged(
            farmID: farmID,
            expectedLastErrorCode: initialErrorCode,
            failureCode: "recoveryValidationFailed"
        )
    }

    private static func isAccountReviewEngineResetCode(_ code: String?) -> Bool {
        code == "accountReviewCatchUp" ||
            code == "accountReviewEngineResetInProgress" ||
            code == "accountReviewEngineResetFailed"
    }

    static func isAllowedRecoveryEngineResetCode(_ code: String?) -> Bool {
        switch code {
        case "engineResetPending",
             "engineResetInProgress",
             "engineResetFailed",
             "accountReviewCatchUp",
             "accountReviewEngineResetInProgress",
             "accountReviewEngineResetFailed":
            return true
        default:
            return false
        }
    }

    private func validateRecoveryRoot(_ expectation: CloudRecoveryRootExpectation) async throws {
        let binding = expectation.binding
        let database = binding.databaseScope == .privateDatabase
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(
            zoneName: binding.zoneName,
            ownerName: binding.zoneOwnerName
        )
        let recordID = CKRecord.ID(
            recordName: "root_\(binding.farmID.uuidString.lowercased())",
            zoneID: zoneID
        )
        let record = try await database.record(for: recordID)
        let root = try mapper.farmRootValue(from: record)
        guard record.recordID == recordID,
              root.farmID == binding.farmID,
              root.ownerAccountID == binding.ownerAccountID,
              OwnerFarmRecoveryCoordinator.readyCloudV2Identity(from: record) == expectation.baseline else {
            throw CloudSyncError.recoveryCatchUpFailed(
                "目标牧场根记录缺失，或云端 v2 基线身份与本机已验证基线不一致。"
            )
        }
    }

    func discardRefreshedBootstrapProjectionChanges(farmID: UUID) async throws {
        guard let binding = try await persistence.uniqueActiveBindingSnapshot(
            farmID: farmID,
            scope: .privateDatabase
        ) else {
            throw CloudSyncError.farmBindingMissing
        }
        let candidateChanges = privateEngine.state.pendingRecordZoneChanges.filter { change in
            guard case .saveRecord(let recordID) = change else { return false }
            return recordID.zoneID.zoneName == binding.zoneName &&
                recordID.zoneID.ownerName == binding.zoneOwnerName &&
                mapper.entityID(from: recordID) != nil
        }
        // Most foreground passes have no serialized v2 entity projections.
        // Avoid scanning the farm's operation history unless CKSyncEngine
        // actually carries an entity save in this active owner zone.
        guard !candidateChanges.isEmpty else { return }
        let recordNames = try await persistence.refreshedBootstrapEntityRecordNames(farmID: farmID)
        guard !recordNames.isEmpty else { return }
        let staleChanges = candidateChanges.filter { change in
            guard case .saveRecord(let recordID) = change else { return false }
            return recordNames.contains(recordID.recordName)
        }
        if !staleChanges.isEmpty {
            privateEngine.state.remove(pendingRecordZoneChanges: staleChanges)
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let scope = activeScope(for: syncEngine) else {
            // A reset engine may finish an already queued callback. Its state,
            // records, and receipts belong to the retired engine and must not
            // be persisted under either live database scope.
            return
        }
        let engineID = ObjectIdentifier(syncEngine)
        let recoveryContext = recoveryFetchContexts[engineID]
        do {
            switch event {
            case .stateUpdate(let update):
                try await persistence.saveEngineState(update.stateSerialization, scope: scope)
            case .fetchedRecordZoneChanges(let changes):
                let records = changes.modifications.map(\.record)
                if var bufferedRecovery = recoveryFetchContexts[engineID] {
                    bufferedRecovery.records.append(contentsOf: records)
                    bufferedRecovery.deletions.append(contentsOf: changes.deletions)
                    recoveryFetchContexts[engineID] = bufferedRecovery
                    break
                }
                try await refreshMissingDeviceTrust(
                    for: records,
                    scope: scope,
                    recoveryFarmID: nil
                )
                let operationGapFarmIDs = try await persistence.ingest(
                    records,
                    scope: scope
                )
                let recoveryFarmIDs = try await persistence.recordUnexpectedDeletions(
                    changes.deletions
                )
                for farmID in operationGapFarmIDs.union(recoveryFarmIDs) {
                    CloudRuntimeNotification.postRecoveryRequired(farmID: farmID)
                }
            case .sentRecordZoneChanges(let changes):
                try await persistence.confirmSavedRecords(changes.savedRecords, scope: scope)
                try await persistence.markFailedRecords(changes.failedRecordSaves, scope: scope)
            case .accountChange(let change):
                switch change.changeType {
                case .signIn:
                    // CKSyncEngine emits one signIn when an engine is recreated
                    // from nil state after a verified cache rebuild. Ignore
                    // only that exact engine's one-shot event; every ordinary
                    // sign-in remains fail-closed for account review.
                    if expectedResetSignInEngineIDs.remove(ObjectIdentifier(syncEngine)) == nil {
                        try await persistence.lockAllCloudFarmsForAccountReview()
                    }
                case .signOut, .switchAccounts:
                    expectedResetSignInEngineIDs.remove(ObjectIdentifier(syncEngine))
                    try await persistence.lockAllCloudFarmsForAccountReview()
                @unknown default:
                    expectedResetSignInEngineIDs.remove(ObjectIdentifier(syncEngine))
                    try await persistence.lockAllCloudFarmsForAccountReview()
                }
            default:
                break
            }
        } catch {
            if recoveryContext != nil {
                recoveryFetchFailures[engineID] = error.localizedDescription
            }
            try? await persistence.recordSecurityIncident(
                farmID: nil,
                type: "syncEventFailed",
                detail: "\(scope.rawValue): \(error.localizedDescription)"
            )
        }
    }

    private func refreshMissingDeviceTrust(
        for records: [CKRecord],
        scope: CloudDatabaseScope,
        recoveryFarmID: UUID?,
        recoveryOperationRecordNames: Set<String> = []
    ) async throws {
        let missingTrustFarmIDs = try await persistence.farmIDsRequiringDeviceTrustRefresh(
            for: records,
            scope: scope,
            recoveryFarmID: recoveryFarmID,
            recoveryOperationRecordNames: recoveryOperationRecordNames
        )
        guard !missingTrustFarmIDs.isEmpty else { return }
        do {
            let membership = MembershipActor(persistence: persistence)
            for farmID in missingTrustFarmIDs {
                _ = try await membership.refresh(farmID: farmID)
            }
            let unresolved = try await persistence.farmIDsRequiringDeviceTrustRefresh(
                for: records,
                scope: scope,
                recoveryFarmID: recoveryFarmID,
                recoveryOperationRecordNames: recoveryOperationRecordNames
            )
            guard unresolved.isEmpty else {
                throw CloudSyncError.recoveryCatchUpFailed(
                    "身份服务快照仍不包含云端操作的签名设备。"
                )
            }
        } catch {
            try? await persistence.lockForDeviceTrustRecovery(
                farmIDs: missingTrustFarmIDs,
                detail: error.localizedDescription
            )
            for farmID in missingTrustFarmIDs {
                CloudRuntimeNotification.postRecoveryRequired(farmID: farmID)
            }
            throw error
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let scope = activeScope(for: syncEngine) else { return nil }
        if recoveryFetchContexts[ObjectIdentifier(syncEngine)] != nil {
            return nil
        }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [self] recordID in
            await recordForUpload(recordID, scope: scope)
        }
    }

    private func recordForUpload(_ recordID: CKRecord.ID, scope: CloudDatabaseScope) async -> CKRecord? {
        var existingEntityRecord: CKRecord?
        do {
            if try await persistence.entityRecordRequiresServerFetch(recordID, scope: scope) {
                let database = scope == .privateDatabase ? container.privateCloudDatabase : container.sharedCloudDatabase
                do {
                    existingEntityRecord = try await database.record(for: recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    // A missing projection is recoverable from the immutable
                    // operation stream, so create it with the current value.
                    existingEntityRecord = nil
                } catch {
                    // Returning nil skips this change for the current batch.
                    // Its Outbox row remains unconfirmed and is selected again
                    // after the transient CloudKit lookup failure clears.
                    return nil
                }
            }
        } catch {
            return nil
        }
        return await persistence.record(
            for: recordID,
            scope: scope,
            device: deviceIdentity,
            existingEntityRecord: existingEntityRecord
        )
    }

    private func activeScope(for engine: CKSyncEngine) -> CloudDatabaseScope? {
        let engineID = ObjectIdentifier(engine)
        guard let scope = engineScopes[engineID] else { return nil }
        switch scope {
        case .privateDatabase:
            return engine === privateEngine ? scope : nil
        case .sharedDatabase:
            return engine === sharedEngine ? scope : nil
        }
    }
}

struct CloudCollaborationStartupPreparation: Sendable {
    let recoveredBaselineRepair: RecoveredBaselineStartupRepairResult
    let errorMessages: [String]
}

@MainActor
@Observable
final class CloudCollaborationStore {
    private static let authorizedObsoleteMigrationFarmID = UUID(uuidString: "c3952764-a012-658d-d686-3ac85bb3697c")!
    private static let authorizedFormalMigrationFarmID = UUID(uuidString: "632cf5be-026e-290e-52bb-31b4b8b9c373")!

    var accountAvailability: CloudAccountAvailability = .checking
    var isSynchronizing = false
    var lastSuccessfulSyncAt: Date?
    var lastErrorMessage: String?
    var isIdentityWriteLocked = false
    var workerHealth: WorkerHealthResponse?

    let persistence: FarmPersistenceActor
    let sync: CloudSyncActor
    let photoTransfers: PhotoTransferActor
    let checkpoints: FarmCheckpointActor
    let membershipSnapshots: MembershipSnapshotActor
    let conflicts: ConflictResolutionActor
    let rebuilds: CloudRebuildActor
    private let modelContainer: ModelContainer
    private var isMigrationMaintenanceRunning = false
    private var syncWakeObserver: NSObjectProtocol?
    private var recoveryObserver: NSObjectProtocol?
    private var pendingSyncWakeFarmIDs = Set<UUID>()
    private var pendingRecoveryFarmIDs = Set<UUID>()
    private var syncWakeDebounceTask: Task<Void, Never>?
    private var recoveryDebounceTask: Task<Void, Never>?
    private var isSyncWakeDrainRunning = false
    private var isRecoveryDrainRunning = false

    nonisolated static func prepareStartup(
        container: ModelContainer
    ) -> CloudCollaborationStartupPreparation {
        let startupRepair = RecoveredBaselineReuploadRepairService.quarantineBeforeCloudEngineStarts(
            container: container
        )
        var startupErrorMessages = startupRepair.errorMessages
        do {
            _ = try PostRecoveryHistoryProjectionRepair.repair(container: container)
        } catch {
            startupErrorMessages.append("增量历史投影修复失败：\(error.localizedDescription)")
        }
        return CloudCollaborationStartupPreparation(
            recoveredBaselineRepair: startupRepair,
            errorMessages: startupErrorMessages
        )
    }

    init(
        container: ModelContainer,
        startupPreparation: CloudCollaborationStartupPreparation? = nil
    ) {
        self.modelContainer = container
        let persistence = FarmPersistenceActor(container: container)
        self.persistence = persistence
        let preparation = startupPreparation ?? Self.prepareStartup(container: container)
        let startupRepair = preparation.recoveredBaselineRepair
        let startupErrorMessages = preparation.errorMessages
        let configuredIdentifier = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String
        let identifier = configuredIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!CloudFeatureConfiguration.isEnabled || identifier?.isEmpty == false, "启用 CloudKit 时必须配置 CLOUDKIT_CONTAINER_IDENTIFIER。")
        self.sync = CloudSyncActor(
            containerIdentifier: identifier,
            persistence: persistence,
            startupRepair: startupRepair
        )
        self.photoTransfers = PhotoTransferActor(modelContainer: container, containerIdentifier: identifier)
        self.checkpoints = FarmCheckpointActor(modelContainer: container, containerIdentifier: identifier)
        self.membershipSnapshots = MembershipSnapshotActor(modelContainer: container, persistence: persistence, containerIdentifier: identifier)
        self.conflicts = ConflictResolutionActor(container: container)
        self.rebuilds = CloudRebuildActor(modelContainer: container, persistence: persistence, containerIdentifier: identifier)
        if !startupErrorMessages.isEmpty {
            self.lastErrorMessage = startupErrorMessages.joined(separator: "\n")
        }
        installRuntimeObservers()
    }

    private func installRuntimeObservers() {
        syncWakeObserver = NotificationCenter.default.addObserver(
            forName: CloudRuntimeNotification.syncWake,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let farmID = CloudRuntimeNotification.farmID(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.scheduleSyncWake(farmID: farmID)
            }
        }
        recoveryObserver = NotificationCenter.default.addObserver(
            forName: CloudRuntimeNotification.recoveryRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let farmID = CloudRuntimeNotification.farmID(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.scheduleAuthoritativeRecovery(farmID: farmID)
            }
        }
    }

    private func scheduleSyncWake(farmID: UUID) {
        pendingSyncWakeFarmIDs.insert(farmID)
        guard !isSyncWakeDrainRunning else { return }
        syncWakeDebounceTask?.cancel()
        syncWakeDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            await self?.drainSyncWakes()
        }
    }

    private func drainSyncWakes() async {
        guard !isSyncWakeDrainRunning else { return }
        isSyncWakeDrainRunning = true
        defer {
            isSyncWakeDrainRunning = false
            if !pendingSyncWakeFarmIDs.isEmpty {
                scheduleSyncWake(farmID: pendingSyncWakeFarmIDs.first!)
            }
        }

        while !pendingSyncWakeFarmIDs.isEmpty {
            let farmIDs = pendingSyncWakeFarmIDs
            pendingSyncWakeFarmIDs.removeAll()
            for farmID in farmIDs {
                do {
                    while try await sync.synchronizeBatch(maxOutboxItems: 25, farmID: farmID) > 0 {}
                    lastSuccessfulSyncAt = .now
                } catch is CancellationError {
                    pendingSyncWakeFarmIDs.insert(farmID)
                    return
                } catch {
                    lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func scheduleAuthoritativeRecovery(farmID: UUID) {
        pendingRecoveryFarmIDs.insert(farmID)
        guard !isRecoveryDrainRunning else { return }
        recoveryDebounceTask?.cancel()
        recoveryDebounceTask = Task { @MainActor [weak self] in
            do {
                // A repair can delete operations immediately before restoring
                // the ready root. Coalesce the deletion burst and let that
                // compare-and-save complete before fetching the full zone.
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            await self?.drainAuthoritativeRecoveries()
        }
    }

    private func drainAuthoritativeRecoveries() async {
        guard !isRecoveryDrainRunning else { return }
        isRecoveryDrainRunning = true
        defer { isRecoveryDrainRunning = false }
        let farmIDs = pendingRecoveryFarmIDs
        pendingRecoveryFarmIDs.removeAll()
        for farmID in farmIDs {
            do {
                try await rebuildOwnerFarmAndUnlock(farmID: farmID)
            } catch {
                // The binding remains read-only/rebuilding. Foreground owner
                // discovery retries this same authoritative path later.
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func refreshAccountAvailability() async {
        accountAvailability = await sync.accountAvailability()
        if IdentityWorkerConfiguration.baseURL != nil {
            workerHealth = try? await IdentityWorkerClient.shared.health()
        }
        let corruptedScopes = await sync.corruptedStateScopes()
        if !corruptedScopes.isEmpty {
            let names = corruptedScopes.map(\.rawValue).joined(separator: "、")
            lastErrorMessage = "检测到同步状态损坏（\(names)）。自动同步已暂停，请在云缓存重建中心完成 staging 重建。"
        }
    }

    func synchronizeNow() async {
        guard !isSynchronizing, !isMigrationMaintenanceRunning else { return }
        isSynchronizing = true
        lastErrorMessage = nil
        defer { isSynchronizing = false }
        do {
            let maintenanceContext = ModelContext(modelContainer)
            let ownerFarmIDs = (try? maintenanceContext.fetch(FetchDescriptor<CloudFarmBinding>()))?
                .filter { $0.state == .active && $0.databaseScope == .privateDatabase }
                .map(\.farmID) ?? []
            for farmID in ownerFarmIDs {
                _ = try? await checkpoints.cleanupInterruptedCheckpoints(farmID: farmID)
                // Serialized CKSyncEngine state survives relaunch even after a
                // baseline v2 Outbox row was confirmed. Remove only obsolete
                // mutable projections before the ordinary send pass.
                try? await sync.discardRefreshedBootstrapProjectionChanges(farmID: farmID)
            }
            await photoTransfers.processPendingTransfers()
            try await sync.synchronizeNow()
            await photoTransfers.processPendingTransfers()
            lastSuccessfulSyncAt = .now
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func resumeAutomaticMigrationUploads(accountID: UUID) async {
        guard AppEnvironment.current == .development,
              CloudFeatureConfiguration.isEnabled,
              !isMigrationMaintenanceRunning else { return }
        isMigrationMaintenanceRunning = true
        defer { isMigrationMaintenanceRunning = false }
        while isSynchronizing {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        do {
            let repairPlans = try RecoveredBaselineReuploadRepairService.pendingPlans(
                container: modelContainer
            )
            for plan in repairPlans {
                try await sync.repairRecoveredBaselineReupload(plan)
                try RecoveredBaselineReuploadRepairService.finalize(
                    plan: plan,
                    container: modelContainer
                )
            }
            let repairGateContext = ModelContext(modelContainer)
            let blockedFarmIDs = try RecoveredBaselineReuploadRepairService.blockedFarmIDs(
                ownerAccountID: accountID,
                context: repairGateContext
            )
            guard blockedFarmIDs.isEmpty else {
                lastErrorMessage = "恢复基线修复仍处于安全锁定，已停止迁移上传。"
                return
            }
        } catch {
            // The quarantined Outbox stays empty. Never fall through to the
            // migration uploader while the exact cloud delete/root repair is
            // incomplete; the next foreground pass resumes this repair only.
            lastErrorMessage = error.localizedDescription
            return
        }
        do {
            _ = try await persistence.purgeLegacyCertificateTimestampIncidents()
            _ = try await persistence.purgeSupersededLocalMigrationFarm(
                obsoleteFarmID: Self.authorizedObsoleteMigrationFarmID,
                replacementFarmID: Self.authorizedFormalMigrationFarmID,
                ownerAccountID: accountID
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }

        let initialContext = ModelContext(modelContainer)
        do {
            _ = try MigrationCloudBootstrapService().upgradeEligibleLegacyFarms(accountID: accountID, context: initialContext)
            _ = try MigrationCloudBootstrapService().refreshEligibleSyncedBaselines(accountID: accountID, context: initialContext)
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }

        let activePrivateFarmIDs = (try? initialContext.fetch(FetchDescriptor<CloudFarmBinding>()))?
            .filter { $0.state == .active && $0.databaseScope == .privateDatabase }
            .map(\.farmID) ?? []
        for farmID in activePrivateFarmIDs {
            // A process can be interrupted after sealing a large recovery
            // checkpoint but before CloudKit returns. Clear only unfinished
            // local artifacts before resuming migration maintenance; verified
            // recovery points remain untouched.
            _ = try? await checkpoints.cleanupInterruptedCheckpoints(farmID: farmID)
            // Include already-synced commits: they are intentionally excluded
            // from resumeMigrationUpload below, but an older serialized engine
            // can still contain their baseline v2 entity projections.
            try? await sync.discardRefreshedBootstrapProjectionChanges(farmID: farmID)
        }

        let commits: [MigrationCommitRecord]
        do {
            commits = try initialContext.fetch(FetchDescriptor<MigrationCommitRecord>()).filter {
                $0.ownerAccountID == accountID &&
                !$0.baselineDigest.isEmpty &&
                $0.cloudState != .synced &&
                $0.cloudState != .localCommitted
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }

        for snapshot in commits {
            do {
                try await resumeMigrationUpload(commitID: snapshot.id, accountID: accountID)
            } catch is CancellationError {
                // Scene changes and app suspension legitimately cancel this
                // task. Keep the last durable migration state so the next
                // foreground pass can resume without recording a false cloud
                // failure or creating a retry storm.
                return
            } catch {
                let context = ModelContext(modelContainer)
                if let commit = try? context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == snapshot.id }) {
                    commit.cloudState = .failed
                    commit.cloudLastError = error.localizedDescription
                    commit.cloudRetryCount += 1
                    try? context.save()
                }
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func discoverAndRestoreOwnerFarms(accountID: UUID) async {
        guard AppEnvironment.current == .development, CloudFeatureConfiguration.isEnabled else { return }
        do {
            // A farm already locked in rebuildingCache has passed the local
            // account/binding admission checks. Resume that CloudKit rebuild
            // before consulting the remote identity directory; otherwise a
            // slow CloudBase request can leave an explicitly staged recovery
            // idle indefinitely even though its private Zone is available.
            let localContext = ModelContext(modelContainer)
            let lockedOwnerFarmIDs = try localContext.fetch(FetchDescriptor<CloudFarmBinding>())
                .filter {
                    $0.ownerAccountID == accountID &&
                        $0.databaseScope == .privateDatabase &&
                        $0.state == .rebuildingCache &&
                        !RecoveredBaselineReuploadRepairService.isBlockingCode($0.lastErrorCode) &&
                        $0.zoneName == CloudZoneName.forFarm($0.farmID)
                }
                .map(\.farmID)
            for farmID in lockedOwnerFarmIDs {
                try await rebuildOwnerFarmAndUnlock(farmID: farmID)
            }

            let status = try await IdentityWorkerClient.shared.accountStatus()
            guard status.accountID == accountID, status.status == "active" else { return }
            let recoveryCoordinator = OwnerFarmRecoveryCoordinator(modelContainer: modelContainer)
            for membership in status.memberships where membership.role == .owner && membership.status == "active" {
                guard membership.cloudZoneName == CloudZoneName.forFarm(membership.farm_id) else { continue }
                let existingBinding = try await persistence.bindingSnapshot(farmID: membership.farm_id)
                if existingBinding == nil {
                    try await persistence.stageDiscoveredOwnerFarm(
                        farmID: membership.farm_id,
                        ownerAccountID: membership.ownerAccountID ?? accountID,
                        shareRecordName: membership.shareRecordName
                    )
                } else if existingBinding?.state == .active {
                    continue
                } else if RecoveredBaselineReuploadRepairService.isBlockingCode(existingBinding?.lastErrorCode) {
                    continue
                } else if existingBinding?.state == .requiresAccountReview,
                          try await recoveryCoordinator.stageReviewedOwnerFarmCatchUpIfUnchanged(
                              farmID: membership.farm_id,
                              accountID: accountID
                          ) {
                    try await sync.resetEngineForLockedFarmAndActivate(
                        scope: .privateDatabase,
                        farmID: membership.farm_id
                    )
                    continue
                } else {
                    guard existingBinding?.databaseScope == .privateDatabase,
                          existingBinding?.zoneName == membership.cloudZoneName else { continue }
                }
                try await rebuildOwnerFarmAndUnlock(farmID: membership.farm_id)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func rebuildOwnerFarmAndUnlock(farmID: UUID) async throws {
        let gateContext = ModelContext(modelContainer)
        if let blockingCode = try RecoveredBaselineReuploadRepairService.blockingCode(
            farmID: farmID,
            context: gateContext
        ) {
            throw CloudSyncError.recoveryCatchUpFailed(
                "恢复基线修复仍被安全锁定（\(blockingCode)）。"
            )
        }
        guard var binding = try await persistence.bindingSnapshot(farmID: farmID) else {
            throw CloudSyncError.farmBindingMissing
        }
        let hasVerifiedCompletedSwitch = (try? await rebuilds.verifiedCompletedCacheSwitch(
            farmID: farmID,
            scope: binding.databaseScope
        )) != nil
        if !hasVerifiedCompletedSwitch,
           binding.lastErrorCode == "engineResetInProgress" {
            let needsFreshRebuild = try await sync.prepareFreshRebuildAfterUnverifiedResetClaim(
                scope: binding.databaseScope,
                farmID: farmID
            )
            if !needsFreshRebuild { return }
            guard let refreshed = try await persistence.bindingSnapshot(farmID: farmID) else {
                throw CloudSyncError.farmBindingMissing
            }
            binding = refreshed
        }
        // The authoritative cache switch and the incremental-engine reset are
        // separate fail-closed phases. Skip a new full download only with
        // durable proof for the newest session, or for the distinct account
        // review catch-up path that already performed an exact root check.
        if Self.shouldRetryCompletedRebuildEngineReset(
            binding,
            hasVerifiedCompletedCacheSwitch: hasVerifiedCompletedSwitch
        ) || Self.shouldRetryAccountReviewEngineReset(binding) {
            try await sync.resetEngineForLockedFarmAndActivate(
                scope: binding.databaseScope,
                farmID: farmID
            )
            return
        }
        _ = try await rebuilds.rebuildOrRetryPreparedCommit(
            farmID: farmID,
            scope: binding.databaseScope,
            reason: .reinstallRecovery
        )
        let finalizer = Task { [sync] in
            do {
                try await sync.resetEngineForLockedFarmAndActivate(
                    scope: binding.databaseScope,
                    farmID: farmID
                )
            } catch {
                throw error
            }
        }
        try await finalizer.value
    }

    static func shouldRetryCompletedRebuildEngineReset(
        _ binding: CloudFarmBindingSnapshot,
        hasVerifiedCompletedCacheSwitch: Bool
    ) -> Bool {
        guard binding.state == .rebuildingCache else {
            return false
        }
        guard hasVerifiedCompletedCacheSwitch else { return false }
        // A persisted in-progress claim can only be installed by a reset that
        // already passed the completed-switch gate (or directly followed a
        // successful commit). The completed bundle proof must still exist on
        // every crash retry; otherwise a legacy or deleted staging bundle
        // could unlock an unproven cache.
        switch binding.lastErrorCode {
        case "engineResetPending", "engineResetInProgress", "engineResetFailed":
            return true
        default:
            return false
        }
    }

    static func shouldRetryAccountReviewEngineReset(
        _ binding: CloudFarmBindingSnapshot
    ) -> Bool {
        binding.state == .rebuildingCache &&
            (binding.lastErrorCode == "accountReviewEngineResetInProgress" ||
                binding.lastErrorCode == "accountReviewEngineResetFailed")
    }

    func retryCompletedRebuildEngineReset(farmID: UUID) async throws {
        guard let binding = try await persistence.bindingSnapshot(farmID: farmID) else {
            throw CloudSyncError.farmBindingMissing
        }
        let hasVerifiedSwitch = (try? await rebuilds.verifiedCompletedCacheSwitch(
            farmID: farmID,
            scope: binding.databaseScope
        )) != nil
        guard Self.shouldRetryCompletedRebuildEngineReset(
                binding,
                hasVerifiedCompletedCacheSwitch: hasVerifiedSwitch
              ) else {
            throw CloudSyncError.recoveryCatchUpFailed("当前没有等待重试的增量同步引擎。")
        }
        try await sync.resetEngineForLockedFarmAndActivate(
            scope: binding.databaseScope,
            farmID: farmID
        )
    }

    private func resumeMigrationUpload(commitID: UUID, accountID: UUID) async throws {
        var context = ModelContext(modelContainer)
        guard let commit = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }),
              let farm = try context.fetch(FetchDescriptor<FarmRecord>()).first(where: { $0.id == commit.farmID && $0.ownerAccountID == accountID }),
              !farm.isLocalOnlyMigration else { return }

        if let blockingCode = try RecoveredBaselineReuploadRepairService.blockingCode(
            farmID: farm.id,
            context: context
        ) {
            throw CloudSyncError.recoveryCatchUpFailed(
                "恢复基线修复仍被安全锁定（\(blockingCode)）。"
            )
        }

        var binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farm.id && $0.state == .active })
        if binding == nil {
            commit.cloudState = .provisioning
            commit.cloudLastError = nil
            try context.save()

            let identity = try await DeviceIdentityActor.shared.register()
            let share = try await sync.prepareOwnerFarm(farmID: farm.id, farmName: farm.name, ownerAccountID: accountID)
            try await IdentityWorkerClient.shared.registerFarm(
                farmID: farm.id,
                zoneName: CloudZoneName.forFarm(farm.id),
                shareRecordName: share.recordID.recordName,
                status: "provisioning"
            )
            let capability = try await IdentityWorkerClient.shared.issueCapability(farmID: farm.id, deviceID: identity.deviceID)
            try await persistence.saveCapability(capability, accountID: accountID, farmID: farm.id, deviceID: identity.deviceID)
            _ = try await MembershipActor(persistence: persistence).refresh(farmID: farm.id)
            _ = try await membershipSnapshots.publish(farmID: farm.id, accountID: accountID)

            context = ModelContext(modelContainer)
            binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: { $0.farmID == farm.id && $0.state == .active })
        } else {
            // CloudKit zone creation can succeed before the CloudBase directory
            // registration. Re-register provisioning on every recovery pass so
            // a half-completed setup heals idempotently instead of failing the
            // capability lookup forever.
            try await IdentityWorkerClient.shared.registerFarm(
                farmID: farm.id,
                zoneName: CloudZoneName.forFarm(farm.id),
                shareRecordName: binding?.shareRecordName,
                status: "provisioning"
            )
            let identity = try await DeviceIdentityActor.shared.identity()
            let hasUsableCapability = try await persistence.hasUsableCapability(
                accountID: accountID,
                farmID: farm.id,
                deviceID: identity.deviceID
            )
            if !hasUsableCapability {
                _ = try await InviteServiceActor(persistence: persistence).refreshCapability(accountID: accountID, farmID: farm.id)
            }
        }
        guard binding != nil else { throw CloudSyncError.farmBindingMissing }

        _ = try await persistence.repairMigrationCloudReadyEvidence(farmID: farm.id)
        guard let baseline = try await persistence.migrationCloudBaseline(farmID: farm.id) else {
            throw CloudSyncError.verifiedMigrationRequired
        }
        if baseline.version >= 2 {
            try await sync.markMigrationBootstrapUpdating(farmID: farm.id, baseline: baseline)
        }

        // Older builds treated an idempotent "record already exists" response
        // as a permanent conflict. Requeue once; the failure handler now
        // confirms byte-identical server records and preserves real conflicts.
        _ = try await persistence.requeueBlockedConflicts(farmID: farm.id)
        try await sync.discardRefreshedBootstrapProjectionChanges(farmID: farm.id)
        _ = try await persistence.reconcileRefreshedBootstrapOutbox(farmID: farm.id)

        context = ModelContext(modelContainer)
        guard let uploadingCommit = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }) else { return }
        uploadingCommit.cloudState = .uploading
        uploadingCommit.cloudLastError = nil
        try context.save()

        await photoTransfers.processPendingTransfers()
        let migrationFarmID = farm.id
        var consecutiveBatchFailures = 0
        var emptySchedulePasses = 0
        var progressWatchdog = MigrationUploadProgressWatchdog()
        while !Task.isCancelled {
            context = ModelContext(modelContainer)
            if let active = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }),
               active.cloudLastError?.contains("自动") == true {
                active.cloudLastError = nil
                try context.save()
            }
            let confirmed = OutboxStatus.confirmed.rawValue
            let beforeCount = try context.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
                $0.farmID == migrationFarmID && $0.statusRawValue != confirmed
            }))
            // User-authorized accelerated migration: maximize throughput while
            // retaining CloudKit's own retry-after handling.
            let batchSize = 200
            let interBatchDelay: Duration = .milliseconds(100)
            let scheduled: Int
            do {
                scheduled = try await sync.synchronizeBatch(
                    maxOutboxItems: batchSize,
                    farmID: migrationFarmID
                )
                consecutiveBatchFailures = 0
            } catch {
                // CKSyncEngine can throw for the batch even after its delegate
                // has confirmed the successful/idempotent records. Judge the
                // migration by durable Outbox progress instead of converting a
                // partial batch error into a whole-migration failure.
                context = ModelContext(modelContainer)
                let afterCount = try context.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
                    $0.farmID == migrationFarmID && $0.statusRawValue != confirmed
                }))
                if afterCount < beforeCount {
                    consecutiveBatchFailures = 0
                    progressWatchdog.reset()
                    if let active = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }) {
                        active.cloudState = .uploading
                        active.cloudLastError = nil
                        try context.save()
                    }
                    try await Task.sleep(for: interBatchDelay)
                    continue
                }

                consecutiveBatchFailures += 1
                if let paused = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }) {
                    paused.cloudState = .uploading
                    paused.cloudLastError = "CloudKit 暂时未能发送这一批，已保留本机数据并等待重试：\(error.localizedDescription)"
                    try context.save()
                }
                guard consecutiveBatchFailures < 3 else { return }
                try await Task.sleep(for: .seconds(5 * consecutiveBatchFailures))
                continue
            }
            if scheduled == 0 {
                progressWatchdog.reset()
                context = ModelContext(modelContainer)
                let unresolved = try context.fetch(FetchDescriptor<OutboxItem>()).filter {
                    $0.farmID == migrationFarmID && $0.status != .confirmed
                }
                let hasPermanentBlock = unresolved.contains {
                    $0.status == .blockedConflict || $0.status == .rejectedPermission
                }
                guard !unresolved.isEmpty, !hasPermanentBlock else { break }
                // A rate-limited final batch can leave every row with a future
                // nextRetryAt, yielding no immediately schedulable records.
                // Keep the one-time migration alive instead of requiring
                // another foreground launch merely to finish the tail.
                emptySchedulePasses += 1
                guard emptySchedulePasses <= 120 else {
                    if let stalled = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }) {
                        stalled.cloudLastError = "CloudKit 暂时没有可调度记录，已保留进度并等待下次前台继续。"
                        try context.save()
                    }
                    return
                }
                try await Task.sleep(for: .seconds(1))
                continue
            }

            context = ModelContext(modelContainer)
            let afterCount = try context.fetchCount(FetchDescriptor<OutboxItem>(predicate: #Predicate {
                $0.farmID == migrationFarmID && $0.statusRawValue != confirmed
            }))
            if progressWatchdog.observe(
                scheduledRecordCount: scheduled,
                unconfirmedBefore: beforeCount,
                unconfirmedAfter: afterCount
            ) {
                if let stalled = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }) {
                    stalled.cloudState = .uploading
                    stalled.cloudLastError = "CloudKit 连续 \(progressWatchdog.consecutiveNoProgressPasses) 批没有确认新记录，已保留进度并停止空转；下次前台将继续。"
                    try context.save()
                }
                return
            }
            emptySchedulePasses = 0
            try await Task.sleep(for: interBatchDelay)
        }
        try Task.checkCancellation()
        await photoTransfers.processPendingTransfers()

        context = ModelContext(modelContainer)
        let pendingOutbox = try context.fetch(FetchDescriptor<OutboxItem>()).contains {
            $0.farmID == farm.id && $0.status != .confirmed
        }
        let pendingAssets = try context.fetch(FetchDescriptor<CloudAssetTransfer>()).contains {
            $0.farmID == farm.id && $0.direction == .upload && $0.status != .completed
        }
        guard !pendingOutbox, !pendingAssets else { return }

        guard let verifyingCommit = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }) else { return }
        verifyingCommit.cloudState = .verifying
        try context.save()
        guard let verifiedBaseline = try await persistence.verifiedMigrationCloudBaselineForReady(farmID: farm.id) else {
            throw CloudSyncError.verifiedMigrationRequired
        }
        try await sync.markMigrationBootstrapReady(farmID: farm.id, baseline: verifiedBaseline)
        // The immutable operation zone plus the verified v2 root is the
        // authoritative recovery source used by a new device. A full encrypted
        // checkpoint is an optional recovery optimization (and can be tens of
        // megabytes); it must never delay activation or make a completed
        // baseline look as if it is still uploading.
        try await IdentityWorkerClient.shared.activateFarm(farmID: farm.id)

        context = ModelContext(modelContainer)
        guard let completed = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).first(where: { $0.id == commitID }) else { return }
        completed.cloudState = .synced
        completed.cloudSyncedAt = .now
        completed.cloudLastError = nil
        try context.save()
        lastSuccessfulSyncAt = .now
    }

    func maintainRecovery(farmID: UUID) async {
        do {
            if let reason = try await checkpoints.shouldCreateAutomaticCheckpoint(farmID: farmID) {
                _ = try await checkpoints.createCheckpoint(farmID: farmID, reason: reason)
            }
        } catch FarmCheckpointError.ownerBindingRequired {
            // Shared-database members do not own the private recovery zone.
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func captureDiagnostics(farmID: UUID) async {
        do {
            let health = workerHealth.map { "\($0.environment)/\($0.database)/\($0.version)" } ?? "not-configured"
            try await persistence.captureDiagnosticSnapshot(
                farmID: farmID,
                workerHealth: health,
                cloudAccount: accountAvailability.displayName
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func commitRebuild(sessionID: UUID) async throws -> CloudRebuildResult {
        // A failed final cache switch keeps its fully verified staging bundle.
        // Manual retry must reuse it instead of downloading the whole zone.
        let result = try await rebuilds.commit(sessionID: sessionID, allowsPreparedRetry: true)
        guard let binding = try await persistence.bindingSnapshot(farmID: result.farmID) else {
            throw CloudSyncError.farmBindingMissing
        }
        do {
            try await sync.resetEngineForLockedFarmAndActivate(
                scope: binding.databaseScope,
                farmID: result.farmID
            )
            return result
        } catch {
            throw error
        }
    }

    func acceptShareNotification(_ notification: Notification, accountID: UUID) async {
        guard let userInfo = notification.userInfo,
              let zoneName = userInfo["zoneName"] as? String,
              let zoneOwnerName = userInfo["zoneOwnerName"] as? String,
              let shareRecordName = userInfo["shareRecordName"] as? String,
              let farmID = CloudZoneName.farmID(from: zoneName) else {
            lastErrorMessage = "系统共享信息不完整，无法建立本地牧场绑定。"
            return
        }
        do {
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
            try await sync.attachAcceptedShare(
                farmID: farmID,
                ownerAccountID: accountID,
                zoneID: zoneID,
                shareRecordName: shareRecordName
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func performIdentityMaintenance(accountID: UUID, farmIDs: [UUID]) async {
        guard IdentityWorkerConfiguration.baseURL != nil else { return }
        do {
            let status = try await IdentityWorkerClient.shared.accountStatus()
            guard status.accountID == accountID, status.status == "active" else {
                isIdentityWriteLocked = true
                lastErrorMessage = "身份服务账号与本机账号不一致，云端牧场已锁定写入。"
                return
            }
            isIdentityWriteLocked = false
            let membership = MembershipActor(persistence: persistence)
            let invite = InviteServiceActor(persistence: persistence)
            // Register the current device before fetching the farm trust set;
            // otherwise this maintenance pass can cache a snapshot that omits
            // the very device whose operation is about to be uploaded.
            let identity = try await DeviceIdentityActor.shared.register()
            let ownedFarmIDs = Set(status.memberships.compactMap { membership -> UUID? in
                membership.role == .owner && membership.status == "active"
                    ? membership.farm_id
                    : nil
            })
            for farmID in farmIDs {
                _ = try await membership.refresh(farmID: farmID)
                let hasUsableCapability = try await persistence.hasUsableCapability(
                    accountID: accountID,
                    farmID: farmID,
                    deviceID: identity.deviceID,
                    minimumRemaining: 86_400
                )
                if !hasUsableCapability {
                    _ = try await invite.refreshCapability(accountID: accountID, farmID: farmID)
                }
                if ownedFarmIDs.contains(farmID) {
                    // Publish after registration/capability issuance. Other
                    // devices then receive an owner-signed additive trust
                    // snapshot before or alongside the first business delta.
                    _ = try await membershipSnapshots.publish(
                        farmID: farmID,
                        accountID: accountID
                    )
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}

final class CloudShareAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // CKSyncEngine owns the CloudKit subscriptions, but the process must
        // still register with APNs so a silent CloudKit push can wake the
        // second device and let the system scheduler fetch the new delta.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Persist only success metadata, never the APNs token itself.
        UserDefaults.standard.set(Date.now, forKey: "cloudPushRegisteredAt")
        UserDefaults.standard.removeObject(forKey: "cloudPushRegistrationError")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        UserDefaults.standard.set(error.localizedDescription, forKey: "cloudPushRegistrationError")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = FarmNotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        FarmSystemNavigationStore.enqueue(.init(
            farmID: route.farmID,
            kind: route.kind,
            entityID: route.entityID,
            query: nil
        ))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task {
            do {
                let container = CKContainer(identifier: cloudKitShareMetadata.containerIdentifier)
                let share = try await container.accept(cloudKitShareMetadata)
                let zoneID = share.recordID.zoneID
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .didAcceptFarmCloudShare,
                        object: nil,
                        userInfo: [
                            "zoneName": zoneID.zoneName,
                            "zoneOwnerName": zoneID.ownerName,
                            "shareRecordName": share.recordID.recordName,
                        ]
                    )
                }
            } catch {
                await MainActor.run {
                    NotificationCenter.default.post(name: .didFailToAcceptFarmCloudShare, object: error)
                }
            }
        }
    }
}

extension Notification.Name {
    static let didAcceptFarmCloudShare = Notification.Name("eSheepNext.didAcceptFarmCloudShare")
    static let didFailToAcceptFarmCloudShare = Notification.Name("eSheepNext.didFailToAcceptFarmCloudShare")
}
