import Foundation
import SwiftData

struct FarmCompactBaselineRebuildProgress: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case preparing
        case replayingProjections
        case restoringHistory
        case rebuildingDerivedHistory
        case validating
        case completed

        var displayName: String {
            switch self {
            case .preparing: "准备临时数据库"
            case .replayingProjections: "重建业务实体"
            case .restoringHistory: "恢复原始历史"
            case .rebuildingDerivedHistory: "重算历史统计"
            case .validating: "校验完整摘要"
            case .completed: "本地校验完成"
            }
        }
    }

    let farmID: UUID
    let migrationID: UUID
    let packageDigest: String
    let phase: Phase
    let processedProjectionCount: Int
    let totalProjectionCount: Int
    let updatedAt: Date
}

enum FarmCompactBaselineRebuildProgressStore {
    static func load(
        farmID: UUID,
        migrationID: UUID
    ) -> FarmCompactBaselineRebuildProgress? {
        guard let data = try? Data(
            contentsOf: progressURL(
                farmID: farmID,
                migrationID: migrationID
            )
        ) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(
            FarmCompactBaselineRebuildProgress.self,
            from: data
        )
    }

    static func save(_ progress: FarmCompactBaselineRebuildProgress) throws {
        let url = progressURL(
            farmID: progress.farmID,
            migrationID: progress.migrationID
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder.cloud.encode(progress).write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
    }

    static func remove(
        farmID: UUID,
        migrationID: UUID
    ) throws {
        let directory = stagingDirectory(
            farmID: farmID,
            migrationID: migrationID
        )
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    static func storeURL(
        farmID: UUID,
        migrationID: UUID
    ) -> URL {
        stagingDirectory(
            farmID: farmID,
            migrationID: migrationID
        ).appending(path: "staging.store")
    }

    private static func progressURL(
        farmID: UUID,
        migrationID: UUID
    ) -> URL {
        stagingDirectory(
            farmID: farmID,
            migrationID: migrationID
        ).appending(path: "progress.json")
    }

    private static func stagingDirectory(
        farmID: UUID,
        migrationID: UUID
    ) -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "SupabaseCompactStaging", directoryHint: .isDirectory)
        .appending(
            path: farmID.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        .appending(
            path: migrationID.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
    }
}

struct FarmCompactBaselineSourceCounts: Sendable, Equatable {
    let sheep: Int
    let pens: Int
    let activePhotos: Int
}

enum FarmCompactBaselineRebuildError: LocalizedError {
    case packageMismatch
    case projectionConflict(UUID)
    case markerMismatch
    case countMismatch

    var errorDescription: String? {
        switch self {
        case .packageMismatch:
            "紧凑基线与当前迁移不匹配。"
        case .projectionConflict(let id):
            "紧凑基线实体重建发生冲突：\(id.uuidString.lowercased())。"
        case .markerMismatch:
            "临时数据库的断点标记与紧凑基线不一致。"
        case .countMismatch:
            "临时数据库与本地权威摘要不一致。"
        }
    }
}

actor FarmCompactBaselineRebuildService {
    private static let saveInterval = 250
    private static let discoveryMarkerPrefix = "compact-discovery:"

    func verify(
        package: FarmCompactBaselinePackageV1,
        packageDigest: String,
        sourceCounts: FarmCompactBaselineSourceCounts
    ) throws {
        let manifest = package.manifest
        guard manifest.schema == FarmCompactBaselinePackageV1.schema,
              manifest.farmID == package.farm.id,
              manifest.projectionCount == package.projections.count,
              manifest.historyOperationCount == package.history.count,
              manifest.tombstoneHistoryCount == package.tombstones.count,
              manifest.assetCount == package.assets.count else {
            throw FarmCompactBaselineRebuildError.packageMismatch
        }

        let storeURL = FarmCompactBaselineRebuildProgressStore.storeURL(
            farmID: manifest.farmID,
            migrationID: manifest.migrationID
        )
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let container = try AppSchema.makeContainer(
            name: "SupabaseCompactStaging",
            url: storeURL
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false

        try saveProgress(
            package: package,
            digest: packageDigest,
            phase: .preparing,
            processed: processedProjectionCount(
                package: package,
                context: context
            )
        )
        try ensureFarm(package.farm, context: context)

        let markerIDs = Set(
            try context.fetch(FetchDescriptor<CloudOperationReceipt>())
                .filter {
                    $0.farmID == manifest.farmID &&
                        $0.recordName.hasPrefix("compact-baseline:")
                }
                .map(\.operationID)
        )
        let expectedMarkerIDs = Set(package.projections.map {
            markerID(
                migrationID: manifest.migrationID,
                projection: $0
            )
        })
        guard markerIDs.isSubset(of: expectedMarkerIDs) else {
            throw FarmCompactBaselineRebuildError.markerMismatch
        }

        let applier = RemoteDomainApplyService(
            replayAssumesEmptyBusinessStore: true
        )
        if !markerIDs.isEmpty {
            try applier.prepareResumableReplay(
                farmID: manifest.farmID,
                context: context
            )
        }
        let deterministicDeviceID = StableCloudUUID.derived(
            namespace: manifest.migrationID,
            name: "compact-baseline-device"
        )
        var processed = markerIDs.count
        for (index, projection) in package.projections.enumerated() {
            try Task.checkCancellation()
            let operationID = markerID(
                migrationID: manifest.migrationID,
                projection: projection
            )
            guard !markerIDs.contains(operationID) else { continue }
            let envelope = CloudOperationEnvelope(
                farmID: manifest.farmID,
                entityID: projection.entityID,
                entityType: projection.entityType,
                schemaVersion: 2,
                revision: max(1, projection.revision),
                baseRevision: max(0, projection.revision - 1),
                operationID: operationID,
                modifiedAt: projection.modifiedAt,
                modifiedByAccountID: package.farm.ownerAccountID,
                modifiedByDeviceID: deterministicDeviceID,
                payload: projection.payload,
                payloadDigest: projection.payloadDigest,
                capabilityCertificate: "compact-checkpoint",
                operationSignature: Data(),
                deletedAt: projection.deletedAt
            )
            let outcome = try applier.applyBaselineProjection(
                envelope,
                context: context
            )
            if case .conflict = outcome {
                throw FarmCompactBaselineRebuildError.projectionConflict(
                    projection.entityID
                )
            }
            context.insert(CloudOperationReceipt(
                farmID: manifest.farmID,
                operationID: operationID,
                recordName: "compact-baseline:\(index)",
                serverChangeTag: nil,
                databaseScope: .privateDatabase
            ))
            processed += 1
            if processed.isMultiple(of: Self.saveInterval) ||
                processed == package.projections.count {
                try context.save()
                try saveProgress(
                    package: package,
                    digest: packageDigest,
                    phase: .replayingProjections,
                    processed: processed
                )
            }
        }

        try saveProgress(
            package: package,
            digest: packageDigest,
            phase: .restoringHistory,
            processed: processed
        )
        try replaceTombstoneHistory(
            package.tombstones,
            farmID: manifest.farmID,
            context: context
        )
        try restoreHistory(
            package.history,
            farmID: manifest.farmID,
            context: context
        )
        try context.save()

        try saveProgress(
            package: package,
            digest: packageDigest,
            phase: .rebuildingDerivedHistory,
            processed: processed
        )
        try FarmHistoryRebuilder().rebuild(
            farmID: manifest.farmID,
            context: context
        )
        try context.save()

        try saveProgress(
            package: package,
            digest: packageDigest,
            phase: .validating,
            processed: processed
        )
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
            .filter {
                $0.farmID == manifest.farmID && $0.deletedAt == nil
            }.count
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
            .filter {
                $0.farmID == manifest.farmID && $0.deletedAt == nil
            }.count
        let activePhotos = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter {
                $0.farmID == manifest.farmID && $0.deletedAt == nil
            }.count
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
            .filter {
                $0.farmID == manifest.farmID && $0.restoredAt == nil
            }.count
        let history = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == manifest.farmID }.count
        guard sheep == sourceCounts.sheep,
              pens == sourceCounts.pens,
              activePhotos == sourceCounts.activePhotos,
              tombstones == manifest.tombstoneHistoryCount,
              history == manifest.historyOperationCount else {
            throw FarmCompactBaselineRebuildError.countMismatch
        }

        try saveProgress(
            package: package,
            digest: packageDigest,
            phase: .completed,
            processed: processed
        )
    }

    /// Restores an activated compact checkpoint directly into the app's
    /// authoritative local cache. The active storage profile and remote
    /// binding are created only after the complete package has been rebuilt
    /// and validated, so an interrupted restore cannot expose a partial farm.
    func restoreAuthoritativeCache(
        package: FarmCompactBaselinePackageV1,
        packageDigest: String,
        ownerAccountID: UUID,
        cursor: Int,
        activate: Bool = true,
        container: ModelContainer
    ) throws {
        let manifest = package.manifest
        guard manifest.schema == FarmCompactBaselinePackageV1.schema,
              manifest.farmID == package.farm.id,
              package.farm.ownerAccountID == ownerAccountID,
              manifest.projectionCount == package.projections.count,
              manifest.historyOperationCount == package.history.count,
              manifest.tombstoneHistoryCount == package.tombstones.count,
              manifest.assetCount == package.assets.count else {
            throw FarmCompactBaselineRebuildError.packageMismatch
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        try ensureFarm(package.farm, context: context)
        try ensureDiscoverySentinel(
            package: package,
            digest: packageDigest,
            context: context
        )

        let markerPrefix = discoveryMarkerPrefix(
            migrationID: manifest.migrationID
        )
        let receipts = try context.fetch(FetchDescriptor<CloudOperationReceipt>())
            .filter {
                $0.farmID == manifest.farmID &&
                    $0.recordName.hasPrefix(markerPrefix)
            }
        let markerIDs = Set(
            receipts
                .filter { $0.recordName != "\(markerPrefix)root" }
                .map(\.operationID)
        )
        let expectedMarkerIDs = Set(package.projections.map {
            markerID(
                migrationID: manifest.migrationID,
                projection: $0
            )
        })
        guard markerIDs.isSubset(of: expectedMarkerIDs) else {
            throw FarmCompactBaselineRebuildError.markerMismatch
        }

        let applier = RemoteDomainApplyService(
            replayAssumesEmptyBusinessStore: true
        )
        if !markerIDs.isEmpty {
            try applier.prepareResumableReplay(
                farmID: manifest.farmID,
                context: context
            )
        }
        let deterministicDeviceID = StableCloudUUID.derived(
            namespace: manifest.migrationID,
            name: "compact-discovery-device"
        )
        var processed = markerIDs.count
        for (index, projection) in package.projections.enumerated() {
            try Task.checkCancellation()
            let operationID = markerID(
                migrationID: manifest.migrationID,
                projection: projection
            )
            guard !markerIDs.contains(operationID) else { continue }
            let envelope = CloudOperationEnvelope(
                farmID: manifest.farmID,
                entityID: projection.entityID,
                entityType: projection.entityType,
                schemaVersion: 2,
                revision: max(1, projection.revision),
                baseRevision: max(0, projection.revision - 1),
                operationID: operationID,
                modifiedAt: projection.modifiedAt,
                modifiedByAccountID: ownerAccountID,
                modifiedByDeviceID: deterministicDeviceID,
                payload: projection.payload,
                payloadDigest: projection.payloadDigest,
                capabilityCertificate: "compact-checkpoint",
                operationSignature: Data(),
                deletedAt: projection.deletedAt
            )
            let outcome = try applier.applyBaselineProjection(
                envelope,
                context: context
            )
            if case .conflict = outcome {
                throw FarmCompactBaselineRebuildError.projectionConflict(
                    projection.entityID
                )
            }
            context.insert(CloudOperationReceipt(
                farmID: manifest.farmID,
                operationID: operationID,
                recordName: "\(markerPrefix)\(index)",
                serverChangeTag: nil,
                databaseScope: .privateDatabase
            ))
            processed += 1
            if processed.isMultiple(of: Self.saveInterval) ||
                processed == package.projections.count {
                try context.save()
            }
        }

        try replaceTombstoneHistory(
            package.tombstones,
            farmID: manifest.farmID,
            context: context
        )
        try restoreHistory(
            package.history,
            farmID: manifest.farmID,
            context: context
        )
        try context.save()
        try FarmHistoryRebuilder().rebuild(
            farmID: manifest.farmID,
            context: context
        )
        try context.save()
        try validateRestoredPackage(package, context: context)
        if activate {
            try activateRestoredFarm(
                package: package,
                ownerAccountID: ownerAccountID,
                cursor: cursor,
                context: context
            )
        }
        try context.save()
    }

    func finalizeRestoredFarm(
        package: FarmCompactBaselinePackageV1,
        ownerAccountID: UUID,
        cursor: Int,
        container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try validateRestoredPackage(package, context: context)

        let existingProfile = try context.fetch(
            FetchDescriptor<FarmStorageProfile>()
        ).first { $0.farmID == package.manifest.farmID }
        let existingBinding = try context.fetch(
            FetchDescriptor<FarmRemoteBinding>()
        ).first {
            $0.farmID == package.manifest.farmID &&
                $0.provider == .supabase
        }
        if let existingProfile, let existingBinding {
            guard existingProfile.mode == .supabase,
                  existingProfile.authorityGeneration ==
                    package.manifest.authorityGeneration,
                  existingBinding.authorityGeneration ==
                    package.manifest.authorityGeneration else {
                throw FarmCompactBaselineRebuildError.markerMismatch
            }
            existingProfile.transitionStateRawValue =
                FarmStorageTransitionState.idle.rawValue
            existingProfile.updatedAt = .now
            existingBinding.stateRawValue =
                FarmRemoteBindingState.active.rawValue
            existingBinding.lastPulledRevision = max(
                existingBinding.lastPulledRevision,
                cursor
            )
            existingBinding.lastSuccessfulSyncAt = .now
            existingBinding.updatedAt = .now
            try context.save()
            return
        }
        guard existingProfile == nil, existingBinding == nil else {
            throw FarmCompactBaselineRebuildError.markerMismatch
        }
        try activateRestoredFarm(
            package: package,
            ownerAccountID: ownerAccountID,
            cursor: cursor,
            context: context
        )
        try context.save()
    }

    private func ensureFarm(
        _ snapshot: FarmCompactBaselinePackageV1.FarmSnapshot,
        context: ModelContext
    ) throws {
        if let farm = try context.fetch(FetchDescriptor<FarmRecord>())
            .first(where: { $0.id == snapshot.id }) {
            guard farm.ownerAccountID == snapshot.ownerAccountID else {
                throw FarmCompactBaselineRebuildError.packageMismatch
            }
            return
        }
        let farm = FarmRecord(
            id: snapshot.id,
            ownerAccountID: snapshot.ownerAccountID,
            name: snapshot.name,
            role: snapshot.role,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
        farm.membershipStatusRawValue = snapshot.membershipStatusRawValue
        farm.locationDisplayName = snapshot.locationDisplayName
        farm.latitude = snapshot.latitude
        farm.longitude = snapshot.longitude
        farm.coordinateReferenceSystem = snapshot.coordinateReferenceSystem
        farm.addressSnapshot = snapshot.addressSnapshot
        farm.timeZoneIdentifier = snapshot.timeZoneIdentifier
        farm.locationSourceRawValue = snapshot.locationSourceRawValue
        farm.horizontalAccuracyMeters = snapshot.horizontalAccuracyMeters
        farm.locationUpdatedAt = snapshot.locationUpdatedAt
        context.insert(farm)
        try context.save()
    }

    private func ensureDiscoverySentinel(
        package: FarmCompactBaselinePackageV1,
        digest: String,
        context: ModelContext
    ) throws {
        let prefix = discoveryMarkerPrefix(
            migrationID: package.manifest.migrationID
        )
        let sentinelName = "\(prefix)root"
        let existing = try context.fetch(
            FetchDescriptor<CloudOperationReceipt>()
        ).first {
            $0.farmID == package.manifest.farmID &&
                $0.recordName == sentinelName
        }
        if let existing {
            guard existing.serverChangeTag == digest else {
                throw FarmCompactBaselineRebuildError.markerMismatch
            }
            return
        }
        context.insert(CloudOperationReceipt(
            farmID: package.manifest.farmID,
            operationID: StableCloudUUID.derived(
                namespace: package.manifest.migrationID,
                name: "compact-discovery-root"
            ),
            recordName: sentinelName,
            serverChangeTag: digest,
            databaseScope: .privateDatabase
        ))
        try context.save()
    }

    private func validateRestoredPackage(
        _ package: FarmCompactBaselinePackageV1,
        context: ModelContext
    ) throws {
        let farmID = package.manifest.farmID
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())
            .filter { $0.farmID == farmID && $0.restoredAt == nil }.count
        let history = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == farmID }.count
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }.count
        guard tombstones == package.manifest.tombstoneHistoryCount,
              history == package.manifest.historyOperationCount,
              photos == package.manifest.assetCount else {
            throw FarmCompactBaselineRebuildError.countMismatch
        }
    }

    private func activateRestoredFarm(
        package: FarmCompactBaselinePackageV1,
        ownerAccountID: UUID,
        cursor: Int,
        context: ModelContext
    ) throws {
        let farmID = package.manifest.farmID
        guard try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .allSatisfy({ $0.farmID != farmID }) else {
            throw FarmCompactBaselineRebuildError.markerMismatch
        }
        guard try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .allSatisfy({ $0.farmID != farmID }) else {
            throw FarmCompactBaselineRebuildError.markerMismatch
        }
        context.insert(FarmStorageProfile(
            farmID: farmID,
            mode: .supabase,
            authorityGeneration: package.manifest.authorityGeneration
        ))
        let binding = FarmRemoteBinding(
            farmID: farmID,
            ownerAccountID: ownerAccountID,
            provider: .supabase,
            state: .active,
            authorityGeneration: package.manifest.authorityGeneration,
            remoteFarmID: farmID.uuidString.lowercased()
        )
        binding.lastPulledRevision = max(0, cursor)
        binding.lastSuccessfulSyncAt = .now
        context.insert(binding)
        context.insert(FarmMembershipBinding(
            serverMembershipID: "supabase:" +
                "\(farmID.uuidString.lowercased()):" +
                ownerAccountID.uuidString.lowercased(),
            farmID: farmID,
            accountID: ownerAccountID,
            role: .owner,
            status: .active
        ))
    }

    private func replaceTombstoneHistory(
        _ values: [FarmCompactBaselinePackageV1.Tombstone],
        farmID: UUID,
        context: ModelContext
    ) throws {
        for existing in try context.fetch(FetchDescriptor<TombstoneRecord>())
            where existing.farmID == farmID {
            context.delete(existing)
        }
        for value in values {
            let tombstone = TombstoneRecord(
                id: value.id,
                farmID: farmID,
                entityType: value.entityType,
                entityID: value.entityID,
                deletedByAccountID: value.deletedByAccountID,
                reason: value.reason,
                revision: value.revision,
                operationID: value.operationID
            )
            tombstone.deletedAt = value.deletedAt
            tombstone.restoredAt = value.restoredAt
            tombstone.restoredByOperationID = value.restoredByOperationID
            context.insert(tombstone)
        }
    }

    private func restoreHistory(
        _ values: [FarmCompactBaselinePackageV1.HistoryOperation],
        farmID: UUID,
        context: ModelContext
    ) throws {
        let existingIDs = Set(
            try context.fetch(FetchDescriptor<DomainOperation>())
                .filter { $0.farmID == farmID }
                .map(\.id)
        )
        let existingSequenceOperationIDs = Set(
            try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
                .filter { $0.farmID == farmID }
                .map(\.operationID)
        )
        for value in values {
            guard FarmCompactBaselineArchive.digest(value.payload) ==
                    value.payloadDigest,
                  let kind = DomainOperationKind(
                    rawValue: value.kindRawValue
                  ) else {
                throw FarmCompactBaselineRebuildError.packageMismatch
            }
            if !existingIDs.contains(value.operationID) {
                context.insert(DomainOperation(
                    id: value.operationID,
                    farmID: farmID,
                    accountID: value.accountID,
                    kind: kind,
                    occurredAt: value.occurredAt,
                    summary: value.summary,
                    entityType: value.entityType,
                    entityID: value.entityID,
                    baseRevision: value.baseRevision,
                    resultingRevision: value.resultingRevision,
                    payload: value.payload
                ))
            }
            if !existingSequenceOperationIDs.contains(value.operationID) {
                context.insert(FarmOperationSequenceRecord(
                    farmID: farmID,
                    operationID: value.operationID,
                    clientSequence: value.clientSequence
                ))
            }
        }
        let nextSequence = max(
            1,
            (values.map(\.clientSequence).max() ?? 0) + 1
        )
        if let counter = try context.fetch(
            FetchDescriptor<FarmOperationSequenceCounter>()
        ).first(where: { $0.farmID == farmID }) {
            counter.nextSequence = max(counter.nextSequence, nextSequence)
        } else {
            context.insert(FarmOperationSequenceCounter(
                farmID: farmID,
                nextSequence: nextSequence
            ))
        }
    }

    private func processedProjectionCount(
        package: FarmCompactBaselinePackageV1,
        context: ModelContext
    ) throws -> Int {
        let expected = Set(package.projections.map {
            markerID(
                migrationID: package.manifest.migrationID,
                projection: $0
            )
        })
        return try context.fetch(FetchDescriptor<CloudOperationReceipt>())
            .filter {
                $0.farmID == package.manifest.farmID &&
                    expected.contains($0.operationID)
            }.count
    }

    private func markerID(
        migrationID: UUID,
        projection: FarmCompactBaselinePackageV1.Projection
    ) -> UUID {
        StableCloudUUID.derived(
            namespace: migrationID,
            name: "compact-projection:\(projection.entityType):" +
                projection.entityID.uuidString.lowercased()
        )
    }

    private func discoveryMarkerPrefix(migrationID: UUID) -> String {
        "\(Self.discoveryMarkerPrefix)" +
            "\(migrationID.uuidString.lowercased()):"
    }

    private func saveProgress(
        package: FarmCompactBaselinePackageV1,
        digest: String,
        phase: FarmCompactBaselineRebuildProgress.Phase,
        processed: Int
    ) throws {
        try FarmCompactBaselineRebuildProgressStore.save(.init(
            farmID: package.manifest.farmID,
            migrationID: package.manifest.migrationID,
            packageDigest: digest,
            phase: phase,
            processedProjectionCount: processed,
            totalProjectionCount: package.manifest.projectionCount,
            updatedAt: .now
        ))
    }
}
