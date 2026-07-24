import CloudKit
import Foundation
import SwiftData

struct OwnerFarmRecoveryBaselineIdentity: Equatable, Sendable {
    let digest: String
    let entityCount: Int
    let photoCount: Int
    let version: Int
    let cutoffAtMilliseconds: Int64
}

enum OwnerFarmRecoveryDecision: Equatable, Sendable {
    case waitForReadyCloud
    case keepCurrentCache
    case stageFullRebuild

    static func evaluate(
        bindingState: CloudFarmBindingState,
        local: OwnerFarmRecoveryBaselineIdentity?,
        readyCloudV2: OwnerFarmRecoveryBaselineIdentity?
    ) -> Self {
        guard bindingState == .active else { return .keepCurrentCache }
        guard let readyCloudV2 else { return .waitForReadyCloud }
        return local == readyCloudV2 ? .keepCurrentCache : .stageFullRebuild
    }
}

/// Performs the fail-closed preflight that must run before owner-farm discovery.
///
/// An old client can leave a binding marked active even though its confirmed
/// cache was reconstructed from migration baseline v1. Once the cloud root
/// advertises a complete v2 identity, only an exact local identity match may
/// keep that binding active. A mismatch is moved into the existing staging
/// rebuild path; no confirmed business rows are changed here.
actor OwnerFarmRecoveryCoordinator {
    private struct Candidate: Sendable {
        let farmID: UUID
        let ownerAccountID: UUID
        let zoneName: String
        let zoneOwnerName: String
    }

    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private let mapper = CloudRecordMapper()

    init(
        modelContainer: ModelContainer,
        containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String
    ) {
        self.modelContainer = modelContainer
        self.cloudContainer = containerIdentifier.flatMap { $0.isEmpty ? nil : CKContainer(identifier: $0) } ?? .default()
    }

    @discardableResult
    func stageMismatchedActiveOwnerFarms(accountID: UUID) async throws -> [UUID] {
        guard AppEnvironment.current == .development, CloudFeatureConfiguration.isEnabled else { return [] }
        let candidates = try activePrivateOwnerCandidates(accountID: accountID)
        var stagedFarmIDs: [UUID] = []

        for candidate in candidates {
            try Task.checkCancellation()
            let recordID = CKRecord.ID(
                recordName: "root_\(candidate.farmID.uuidString.lowercased())",
                zoneID: CKRecordZone.ID(zoneName: candidate.zoneName, ownerName: candidate.zoneOwnerName)
            )
            let rootRecord = try await cloudContainer.privateCloudDatabase.record(for: recordID)
            let root = try mapper.farmRootValue(from: rootRecord)
            guard root.farmID == candidate.farmID,
                  root.ownerAccountID == candidate.ownerAccountID else {
                throw CloudRebuildError.farmMismatch
            }
            guard let cloudIdentity = Self.readyCloudV2Identity(from: rootRecord) else {
                continue
            }

            let localIdentity = try localRecoveryIdentity(farmID: candidate.farmID, ownerAccountID: accountID)
            guard OwnerFarmRecoveryDecision.evaluate(
                bindingState: .active,
                local: localIdentity,
                readyCloudV2: cloudIdentity
            ) == .stageFullRebuild else {
                continue
            }

            // The root fetch is asynchronous. Re-read both the binding and the
            // local baseline before taking the lock so a concurrent successful
            // recovery cannot be downgraded by stale preflight state.
            let context = ModelContext(modelContainer)
            guard let binding = try context.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: {
                $0.farmID == candidate.farmID &&
                    $0.ownerAccountID == accountID &&
                    $0.databaseScope == .privateDatabase &&
                    $0.state == .active
            }) else { continue }
            let refreshedLocalIdentity = try Self.localRecoveryIdentity(
                farmID: candidate.farmID,
                ownerAccountID: accountID,
                context: context
            )
            guard refreshedLocalIdentity != cloudIdentity else { continue }

            binding.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
            binding.lastErrorCode = "baselineIdentityMismatch"
            binding.updatedAt = .now
            try context.save()
            stagedFarmIDs.append(candidate.farmID)
        }

        return stagedFarmIDs
    }

    /// Moves an account-review lock into a fail-closed catch-up state only
    /// after both the private CloudKit root and immutable local v2 baseline
    /// still match. The caller has already verified the same active owner
    /// membership with the identity service. Activation happens only after a
    /// fresh recovery-engine fetch has been ingested successfully.
    func stageReviewedOwnerFarmCatchUpIfUnchanged(farmID: UUID, accountID: UUID) async throws -> Bool {
        guard try await cloudContainer.accountStatus() == .available else { return false }

        let initialContext = ModelContext(modelContainer)
        let farms = try initialContext.fetch(FetchDescriptor<FarmRecord>())
        guard farms.contains(where: {
            $0.id == farmID &&
                $0.ownerAccountID == accountID &&
                $0.role == .owner &&
                $0.membershipStatusRawValue == FarmMembershipStatus.active.rawValue &&
                $0.deletedAt == nil
        }),
        let binding = try initialContext.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: {
            $0.farmID == farmID &&
                $0.ownerAccountID == accountID &&
                $0.databaseScope == .privateDatabase &&
                $0.state == .requiresAccountReview &&
                $0.lastErrorCode == "cloudAccountChanged" &&
                $0.zoneName == CloudZoneName.forFarm(farmID)
        }),
        let initialLocalIdentity = try Self.localRecoveryIdentity(
            farmID: farmID,
            ownerAccountID: accountID,
            context: initialContext
        ) else { return false }

        let recordID = CKRecord.ID(
            recordName: "root_\(farmID.uuidString.lowercased())",
            zoneID: CKRecordZone.ID(zoneName: binding.zoneName, ownerName: binding.zoneOwnerName)
        )
        let rootRecord = try await cloudContainer.privateCloudDatabase.record(for: recordID)
        let root = try mapper.farmRootValue(from: rootRecord)
        guard root.farmID == farmID,
              root.ownerAccountID == accountID,
              Self.readyCloudV2Identity(from: rootRecord) == initialLocalIdentity else {
            return false
        }

        // The remote fetch is asynchronous. Re-read the lock and the local
        // baseline before activation so a concurrent mutation cannot pass on
        // stale evidence.
        let finalContext = ModelContext(modelContainer)
        guard let finalBinding = try finalContext.fetch(FetchDescriptor<CloudFarmBinding>()).first(where: {
            $0.farmID == farmID &&
                $0.ownerAccountID == accountID &&
                $0.databaseScope == .privateDatabase &&
                $0.state == .requiresAccountReview &&
                $0.lastErrorCode == "cloudAccountChanged" &&
                $0.zoneName == binding.zoneName &&
                $0.zoneOwnerName == binding.zoneOwnerName
        }),
        try Self.localRecoveryIdentity(
            farmID: farmID,
            ownerAccountID: accountID,
            context: finalContext
        ) == initialLocalIdentity else { return false }

        finalBinding.stateRawValue = CloudFarmBindingState.rebuildingCache.rawValue
        finalBinding.lastErrorCode = "accountReviewCatchUp"
        finalBinding.updatedAt = .now
        try finalContext.save()
        return true
    }

    private func activePrivateOwnerCandidates(accountID: UUID) throws -> [Candidate] {
        let context = ModelContext(modelContainer)
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        let eligibleFarmIDs = Set(farms.compactMap { farm in
            farm.ownerAccountID == accountID && farm.deletedAt == nil ? farm.id : nil
        })
        return try context.fetch(FetchDescriptor<CloudFarmBinding>()).compactMap { binding in
            guard eligibleFarmIDs.contains(binding.farmID),
                  binding.ownerAccountID == accountID,
                  binding.databaseScope == .privateDatabase,
                  binding.state == .active else { return nil }
            return Candidate(
                farmID: binding.farmID,
                ownerAccountID: binding.ownerAccountID,
                zoneName: binding.zoneName,
                zoneOwnerName: binding.zoneOwnerName
            )
        }
    }

    private func localRecoveryIdentity(
        farmID: UUID,
        ownerAccountID: UUID
    ) throws -> OwnerFarmRecoveryBaselineIdentity? {
        try Self.localRecoveryIdentity(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            context: ModelContext(modelContainer)
        )
    }

    static func localRecoveryIdentity(
        farmID: UUID,
        ownerAccountID: UUID,
        scope: CloudDatabaseScope = .privateDatabase,
        context: ModelContext
    ) throws -> OwnerFarmRecoveryBaselineIdentity? {
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>()).filter {
            $0.farmID == farmID &&
                $0.ownerAccountID == ownerAccountID &&
                !$0.baselineDigest.isEmpty &&
                $0.baselineEntityCount > 0 &&
                $0.baselinePhotoCount >= 0
        }
        guard let commit = commits.max(by: { $0.committedAt < $1.committedAt }) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var version = 1
        var cutoffAt: Date?
        for operation in try context.fetch(FetchDescriptor<DomainOperation>()).filter({ $0.farmID == farmID }) {
            guard let payload = try? decoder.decode(FarmCommandCloudPayload.self, from: operation.payload),
                  payload.kind == .bootstrapEntity else { continue }
            let candidateVersion = payload.integers["baselineVersion"] ?? 1
            let candidateCutoff = payload.dates["baselineCutoffAt"]
            if candidateVersion > version {
                version = candidateVersion
                cutoffAt = candidateCutoff
            } else if candidateVersion == version, let candidateCutoff {
                cutoffAt = max(cutoffAt ?? candidateCutoff, candidateCutoff)
            }
        }
        if version >= 2, let cutoffAt {
            return OwnerFarmRecoveryBaselineIdentity(
                digest: commit.baselineDigest,
                entityCount: commit.baselineEntityCount,
                photoCount: commit.baselinePhotoCount,
                version: version,
                cutoffAtMilliseconds: milliseconds(cutoffAt)
            )
        }

        // Cache replacement intentionally replays bootstrap operations into
        // business rows instead of retaining the wrapper DomainOperation rows.
        // The completed, verified staging bundle is therefore the durable v2
        // identity for a recovered device. Failed/ready sessions never qualify.
        let completed = CloudRebuildStatus.completed.rawValue
        let sessions = try context.fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter { $0.farmID == farmID && $0.statusRawValue == completed }
            .sorted { $0.updatedAt > $1.updatedAt }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for session in sessions {
            let bundleURL = support
                .appending(path: session.stagingRelativePath, directoryHint: .isDirectory)
                .appending(path: "bundle.json")
            guard let data = try? Data(contentsOf: bundleURL),
                  let bundle = try? decoder.decode(CloudRebuildBundle.self, from: data),
                  bundle.sessionID == session.id,
                  bundle.farmID == farmID,
                  bundle.scope == scope,
                  let bootstrap = bundle.bootstrap,
                  bootstrap.digest == commit.baselineDigest,
                  bootstrap.entityCount == commit.baselineEntityCount,
                  bootstrap.photoCount == commit.baselinePhotoCount,
                  let identity = baselineIdentity(from: bootstrap) else { continue }
            return identity
        }
        return nil
    }

    static func baselineIdentity(
        from bootstrap: CloudRebuildBootstrapSnapshot
    ) -> OwnerFarmRecoveryBaselineIdentity? {
        guard bootstrap.normalizedVersion >= 2,
              let cutoffAtMilliseconds = bootstrap.cutoffAtMilliseconds else { return nil }
        return OwnerFarmRecoveryBaselineIdentity(
            digest: bootstrap.digest,
            entityCount: bootstrap.entityCount,
            photoCount: bootstrap.photoCount,
            version: bootstrap.normalizedVersion,
            cutoffAtMilliseconds: cutoffAtMilliseconds
        )
    }

    static func readyCloudV2Identity(from rootRecord: CKRecord) -> OwnerFarmRecoveryBaselineIdentity? {
        guard rootRecord[CloudRecordField.bootstrapState] as? String == "ready",
              let digest = rootRecord[CloudRecordField.bootstrapDigest] as? String,
              !digest.isEmpty,
              let cutoffAt = rootRecord[CloudRecordField.bootstrapCutoffAt] as? Date else {
            return nil
        }
        let version = integer(rootRecord[CloudRecordField.bootstrapVersion])
        let entityCount = integer(rootRecord[CloudRecordField.bootstrapEntityCount])
        let photoCount = integer(rootRecord[CloudRecordField.bootstrapPhotoCount])
        guard version >= 2, entityCount > 0, photoCount >= 0 else { return nil }
        return OwnerFarmRecoveryBaselineIdentity(
            digest: digest,
            entityCount: entityCount,
            photoCount: photoCount,
            version: version,
            cutoffAtMilliseconds: milliseconds(cutoffAt)
        )
    }

    private static func integer(_ value: CKRecordValue?) -> Int {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue ?? -1
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
