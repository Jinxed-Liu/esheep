import CryptoKit
import Foundation
import SQLite3
import SwiftData

enum ESheepCloudMigrationError: LocalizedError {
    case sourceStoreMissing
    case sourceStoreBusy
    case sourceStoreIntegrityFailed(String)
    case backupAlreadyExistsButIsInvalid
    case backupFailed(String)
    case farmMissing
    case sourceProfileMissing
    case sourceIsNotLegacyCloud
    case accountMismatch
    case migrationAlreadyIrreversible
    case migrationStateMismatch
    case forwardRepairRequired
    case parityEvidenceInvalid
    case unsafeOperationPayload(UUID)
    case unsafeOperationSequence(UUID)

    var errorDescription: String? {
        switch self {
        case .sourceStoreMissing:
            "没有找到当前牧场的本机数据库，已停止升级。"
        case .sourceStoreBusy:
            "本机资料仍在写入，请稍后再试。"
        case .sourceStoreIntegrityFailed:
            "本机牧场资料未通过完整性检查，已保留原数据并停止升级。"
        case .backupAlreadyExistsButIsInvalid:
            "已有的迁移备份未通过校验，已停止升级。"
        case .backupFailed:
            "无法完成可恢复备份，牧场仍保留在原有云端方式。"
        case .farmMissing:
            "本机没有找到这座牧场。"
        case .sourceProfileMissing:
            "没有找到这座牧场的保存方式记录。"
        case .sourceIsNotLegacyCloud:
            "这座牧场不需要执行旧版云端迁移。"
        case .accountMismatch:
            "当前账号不能准备这座牧场的云端迁移。"
        case .migrationAlreadyIrreversible:
            "这座牧场已经产生新的云端业务记录，只能继续向前修复。"
        case .migrationStateMismatch:
            "本机迁移记录与牧场身份不一致，已停止切换。"
        case .forwardRepairRequired:
            "有旧操作无法安全解释，已保留原数据，完成修复前不会切换云端。"
        case .parityEvidenceInvalid:
            "牧场迁移的完整性证明不一致，已停止切换。"
        case .unsafeOperationPayload:
            "有一项旧操作无法可靠解释，已保留原始内容并停止自动切换。"
        case .unsafeOperationSequence:
            "有一项旧操作缺少可信设备顺序，已保留原始内容并停止自动切换。"
        }
    }
}

struct ESheepCloudMigrationResourceEntryV2: Codable, Sendable, Equatable {
    let assetID: UUID
    let relativePath: String
    let declaredSHA256: String
    let observedSHA256: String?
    let byteCount: Int64
    let isPresent: Bool
}

struct ESheepCloudMigrationBackupFileV2: Codable, Sendable, Equatable {
    let relativePath: String
    let byteCount: Int64
    let sha256: String?
    let purpose: String
}

struct ESheepCloudMigrationBackupManifestV2: Codable, Sendable, Equatable {
    let formatVersion: Int
    let farmID: UUID
    let migrationID: UUID
    let sourceStoreFilename: String
    let sourceQuickCheck: String
    let createdAt: Date
    let files: [ESheepCloudMigrationBackupFileV2]
    let resources: [ESheepCloudMigrationResourceEntryV2]
}

struct ESheepCloudMigrationBackupReceiptV2: Sendable, Equatable {
    let directoryRelativePath: String
    let manifestDigest: String
    let quickCheck: String
    let manifest: ESheepCloudMigrationBackupManifestV2
}

enum ESheepCloudV1OperationDispositionV2: String, Codable, Sendable {
    /// The migration worker must map the already accepted V1 operation and its
    /// immutable receipt into the V2 command ledger without producing events a
    /// second time.
    case mapAcceptedReceipt
    /// Safe append/state-machine intent. It can be materialized only after the
    /// verified V2 snapshot supplies its stream and field observations.
    case convertAfterSnapshot
    /// V1 may have processed the request even though the client missed the
    /// response. Query the original operation ID; never generate a new ID.
    case queryV1Result
    /// The operation lacks a trustworthy field-level base or has an explicit
    /// V1 block/rejection. The migration worker must create a durable,
    /// user-readable server attention item.
    case createServerAttention
    /// The photo projection/resource must be reconciled by asset ID and hash.
    /// It must not be re-uploaded if the verified object already exists.
    case reconcilePhotoAsset
    /// The operation was intentionally local-only and has no cloud delivery
    /// result to migrate.
    case retainLocalAuditOnly
    /// The old row is internally inconsistent or cannot be represented by the
    /// frozen V2 protocol. This blocks cutover and requires a forward repair.
    case forwardRepairRequired
}

struct ESheepCloudMigrationIntentDraftV2: Codable, Sendable, Equatable {
    let payload: ESheepCloudCommandPayloadV2
    let occurredAt: Date
    let affectedStreams: [ESheepCloudStreamReferenceV2]
    let affectedFieldKeys: [String]
    let fieldChanges: [ESheepCloudFieldPatchV2]
    let requiredAssetIDs: [UUID]

    init(_ draft: ESheepCloudCommandDraftV2) {
        payload = draft.payload
        occurredAt = draft.occurredAt
        affectedStreams = draft.affectedStreams
        affectedFieldKeys = draft.affectedFieldKeys
        fieldChanges = draft.fieldChanges
        requiredAssetIDs = draft.requiredAssetIDs
    }

    var commandDraft: ESheepCloudCommandDraftV2 {
        ESheepCloudCommandDraftV2(
            payload: payload,
            occurredAt: occurredAt,
            affectedStreams: affectedStreams,
            affectedFieldKeys: affectedFieldKeys,
            fieldChanges: fieldChanges,
            requiredAssetIDs: requiredAssetIDs
        )
    }
}

struct ESheepCloudV1OperationMappingV2: Codable, Sendable, Equatable,
    Identifiable {
    let id: UUID
    let sourceRequestID: UUID
    let accountID: UUID
    let deviceID: UUID
    let deviceSequence: Int64
    let sourceKind: String
    let sourceEntityType: String
    let sourceEntityID: UUID?
    let sourcePayloadDigest: String
    let disposition: ESheepCloudV1OperationDispositionV2
    let draft: ESheepCloudMigrationIntentDraftV2?
    let prerequisiteCommandIDs: [UUID]
    let attentionFieldKey: String?
    let attentionFieldDisplayName: String?
    let attentionDeviceValue: ESheepCloudValueV2?
    let explanation: String?
    let legacyStatuses: [String]
}

struct ESheepCloudV1MappingPlanV2: Codable, Sendable, Equatable {
    let formatVersion: Int
    let farmID: UUID
    let sourceFarmGeneration: Int
    let targetFarmGeneration: Int
    let fallbackDeviceID: UUID
    let createdAt: Date
    let operations: [ESheepCloudV1OperationMappingV2]
    let resources: [ESheepCloudMigrationResourceEntryV2]
    let mappingDigest: String

    var blocksCutover: Bool {
        operations.contains { $0.disposition == .forwardRepairRequired }
    }

    static func make(
        farmID: UUID,
        sourceFarmGeneration: Int,
        targetFarmGeneration: Int,
        fallbackDeviceID: UUID,
        createdAt: Date,
        operations: [ESheepCloudV1OperationMappingV2],
        resources: [ESheepCloudMigrationResourceEntryV2]
    ) throws -> Self {
        let unsigned = Self(
            formatVersion: 1,
            farmID: farmID,
            sourceFarmGeneration: sourceFarmGeneration,
            targetFarmGeneration: targetFarmGeneration,
            fallbackDeviceID: fallbackDeviceID,
            createdAt: createdAt,
            operations: operations,
            resources: resources,
            mappingDigest: ""
        )
        return Self(
            formatVersion: unsigned.formatVersion,
            farmID: unsigned.farmID,
            sourceFarmGeneration: unsigned.sourceFarmGeneration,
            targetFarmGeneration: unsigned.targetFarmGeneration,
            fallbackDeviceID: unsigned.fallbackDeviceID,
            createdAt: unsigned.createdAt,
            operations: unsigned.operations,
            resources: unsigned.resources,
            mappingDigest: try ESheepCloudCanonicalCodec.digest(unsigned)
        )
    }

    func validateDigest() throws {
        let unsigned = Self(
            formatVersion: formatVersion,
            farmID: farmID,
            sourceFarmGeneration: sourceFarmGeneration,
            targetFarmGeneration: targetFarmGeneration,
            fallbackDeviceID: fallbackDeviceID,
            createdAt: createdAt,
            operations: operations,
            resources: resources,
            mappingDigest: ""
        )
        guard mappingDigest == (try ESheepCloudCanonicalCodec.digest(unsigned)) else {
            throw ESheepCloudMigrationError.migrationStateMismatch
        }
    }
}

struct ESheepCloudMigrationParityCheckV2: Codable, Sendable, Equatable {
    let key: String
    let passed: Bool
    let sourceCount: Int?
    let targetCount: Int?
    let sourceDigest: String?
    let targetDigest: String?

    private enum CodingKeys: String, CodingKey {
        case key, passed
        case sourceCount = "source_count"
        case targetCount = "target_count"
        case sourceDigest = "source_digest"
        case targetDigest = "target_digest"
    }
}

struct ESheepCloudMigrationParityReportV2: Codable, Sendable, Equatable {
    let formatVersion: Int
    let farmID: UUID
    let sourceGeneration: Int
    let targetGeneration: Int
    let sourceManifestDigest: String
    let targetManifestDigest: String
    let targetProjectionDigest: String
    let checks: [ESheepCloudMigrationParityCheckV2]
    let allChecksPassed: Bool

    private enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case farmID = "farm_id"
        case sourceGeneration = "source_generation"
        case targetGeneration = "target_generation"
        case sourceManifestDigest = "source_manifest_digest"
        case targetManifestDigest = "target_manifest_digest"
        case targetProjectionDigest = "target_projection_digest"
        case checks
        case allChecksPassed = "all_checks_passed"
    }

    func validate(
        farmID expectedFarmID: UUID,
        sourceGeneration expectedSourceGeneration: Int,
        targetGeneration expectedTargetGeneration: Int
    ) throws {
        let digestPattern = "^[0-9a-f]{64}$"
        guard formatVersion == 1,
              farmID == expectedFarmID,
              sourceGeneration == expectedSourceGeneration,
              targetGeneration == expectedTargetGeneration,
              sourceManifestDigest == targetManifestDigest,
              sourceManifestDigest.range(
                of: digestPattern,
                options: .regularExpression
              ) != nil,
              targetProjectionDigest.range(
                of: digestPattern,
                options: .regularExpression
              ) != nil,
              !checks.isEmpty,
              Set(checks.map(\.key)).count == checks.count,
              checks.map(\.key) == checks.map(\.key).sorted(),
              checks.allSatisfy(\.passed),
              allChecksPassed else {
            throw ESheepCloudMigrationError.parityEvidenceInvalid
        }
        for check in checks {
            guard (check.sourceCount == nil) == (check.targetCount == nil),
                  (check.sourceDigest == nil) == (check.targetDigest == nil) else {
                throw ESheepCloudMigrationError.parityEvidenceInvalid
            }
            if let sourceCount = check.sourceCount,
               let targetCount = check.targetCount,
               (sourceCount < 0 || targetCount < 0 || sourceCount != targetCount) {
                throw ESheepCloudMigrationError.parityEvidenceInvalid
            }
            if let sourceDigest = check.sourceDigest,
               let targetDigest = check.targetDigest,
               (sourceDigest != targetDigest ||
                sourceDigest.range(of: digestPattern, options: .regularExpression) == nil) {
                throw ESheepCloudMigrationError.parityEvidenceInvalid
            }
        }
    }
}

struct ESheepCloudMigrationPreparationReportV2: Sendable, Equatable {
    let migrationID: UUID
    let backupDirectoryRelativePath: String
    let backupManifestDigest: String
    let mappingDigest: String
    let acceptedReceiptCount: Int
    let convertibleIntentCount: Int
    let unknownResultCount: Int
    let attentionCount: Int
    let photoReconciliationCount: Int
    let forwardRepairCount: Int
}

/// Creates the local half of a V1 -> V2 migration without changing cloud
/// authority. The farm is placed in a durable read-only migration state first,
/// then its exact store is backed up and every legacy operation is classified.
/// No V2 intent is submitted and no remote row is mutated by this coordinator.
@MainActor
final class ESheepCloudMigrationCoordinator {
    private let container: ModelContainer
    private let storeURL: URL
    private let applicationSupportURL: URL

    init(
        container: ModelContainer,
        storeURL: URL = AppSchema.defaultStoreURL(),
        applicationSupportURL: URL? = nil
    ) {
        self.container = container
        self.storeURL = storeURL
        self.applicationSupportURL = applicationSupportURL ?? storeURL
            .deletingLastPathComponent()
    }

    func prepareV1Migration(
        farmID: UUID,
        targetFarmGeneration: Int,
        fallbackDeviceID: UUID,
        now: Date = .now
    ) async throws -> ESheepCloudMigrationPreparationReportV2 {
        let context = ModelContext(container)
        guard !context.hasChanges else {
            throw ESheepCloudMigrationError.sourceStoreBusy
        }
        guard try context.fetch(FetchDescriptor<FarmRecord>())
            .contains(where: { $0.id == farmID }) else {
            throw ESheepCloudMigrationError.farmMissing
        }
        guard let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: { $0.farmID == farmID }) else {
            throw ESheepCloudMigrationError.sourceProfileMissing
        }
        guard profile.mode == .supabase else {
            throw ESheepCloudMigrationError.sourceIsNotLegacyCloud
        }
        let sourceGeneration = profile.authorityGeneration
        guard targetFarmGeneration == sourceGeneration + 1 else {
            throw ESheepCloudMigrationError.migrationStateMismatch
        }

        if let existing = try context.fetch(FetchDescriptor<ESheepCloudMigrationState>())
            .first(where: { $0.farmID == farmID }) {
            guard existing.sourceFarmGeneration == sourceGeneration,
                  existing.targetFarmGeneration == targetFarmGeneration else {
                throw ESheepCloudMigrationError.migrationStateMismatch
            }
            if existing.firstAcceptedV2CommandID != nil ||
                existing.irreversibleCutoverAt != nil {
                throw ESheepCloudMigrationError.migrationAlreadyIrreversible
            }
            if existing.phase == .forwardRepairRequired {
                // Never create a second migration record for the same farm.
                // A failed conversion is an explicit forward-repair stop and
                // must remain visible to the operator until repaired.
                throw ESheepCloudMigrationError.forwardRepairRequired
            }
            if existing.phase == .v1WriteClosed || existing.phase == .v2Active {
                throw ESheepCloudMigrationError.migrationAlreadyIrreversible
            }
            if existing.phase == .shadowConverted ||
                existing.phase == .parityVerified ||
                existing.phase == .readyToCutOver {
                let plan = try ESheepCloudCanonicalCodec.decode(
                    ESheepCloudV1MappingPlanV2.self,
                    from: existing.mappingData
                )
                try plan.validateDigest()
                return report(
                    migrationID: existing.id,
                    state: existing,
                    plan: plan
                )
            }
        }

        // This transition is deliberately not a delivery transition. Normal
        // commands and both sync engines must treat it as a write barrier while
        // the immutable backup and classification are created.
        profile.transitionStateRawValue = FarmStorageTransitionState.readOnlyMigration.rawValue
        profile.sourceModeRawValue = FarmStorageMode.supabase.rawValue
        profile.targetModeRawValue = FarmStorageMode.eSheepCloud.rawValue
        profile.updatedAt = now
        try context.save()

        let migrationID = UUID()
        do {
            let resourceSources = try Self.resourceSources(
                farmID: farmID,
                context: context
            )
            let storeURL = self.storeURL
            let applicationSupportURL = self.applicationSupportURL
            let backup = try await Task.detached(priority: .userInitiated) {
                try ESheepCloudStoreBackupService.createVerifiedBackup(
                    farmID: farmID,
                    migrationID: migrationID,
                    storeURL: storeURL,
                    applicationSupportURL: applicationSupportURL,
                    resourceSources: resourceSources,
                    now: now
                )
            }.value

            let plan = try Self.mappingPlan(
                farmID: farmID,
                sourceFarmGeneration: sourceGeneration,
                targetFarmGeneration: targetFarmGeneration,
                fallbackDeviceID: fallbackDeviceID,
                resources: backup.manifest.resources,
                context: context,
                now: now
            )
            let state = ESheepCloudMigrationState(
                id: migrationID,
                farmID: farmID,
                sourceFarmGeneration: sourceGeneration,
                targetFarmGeneration: targetFarmGeneration,
                sourceBackupDirectoryRelativePath: backup.directoryRelativePath
            )
            state.sourceStoreQuickCheck = backup.quickCheck
            state.sourceBackupManifestDigest = backup.manifestDigest
            state.mappingData = try ESheepCloudCanonicalCodec.encode(plan)
            state.phase = plan.blocksCutover ? .forwardRepairRequired : .shadowConverted
            context.insert(state)
            profile.migrationID = migrationID
            profile.updatedAt = now
            try context.save()
            return report(migrationID: migrationID, state: state, plan: plan)
        } catch {
            // A failed preflight must not strand a healthy V1 farm. The backup
            // is append-only and may remain for diagnosis, but the source
            // authority resumes exactly as it was.
            profile.transitionStateRawValue = FarmStorageTransitionState.idle.rawValue
            profile.sourceModeRawValue = nil
            profile.targetModeRawValue = nil
            profile.migrationID = nil
            profile.updatedAt = .now
            try? context.save()
            throw error
        }
    }

    func recordVerifiedParity(
        farmID: UUID,
        report: ESheepCloudMigrationParityReportV2,
        parityDigest: String
    ) throws {
        let context = ModelContext(container)
        guard let state = try context.fetch(FetchDescriptor<ESheepCloudMigrationState>())
            .first(where: { $0.farmID == farmID }),
              state.phase == .shadowConverted else {
            throw ESheepCloudMigrationError.migrationStateMismatch
        }
        try report.validate(
            farmID: farmID,
            sourceGeneration: state.sourceFarmGeneration,
            targetGeneration: state.targetFarmGeneration
        )
        let computedDigest = try ESheepCloudCanonicalCodec.digest(report)
        guard parityDigest == computedDigest else {
            throw ESheepCloudMigrationError.parityEvidenceInvalid
        }
        state.sourceManifestDigest = report.sourceManifestDigest
        state.targetManifestDigest = report.targetManifestDigest
        state.targetProjectionDigest = report.targetProjectionDigest
        state.parityReportData = try ESheepCloudCanonicalCodec.encode(report)
        state.parityDigest = parityDigest
        state.phase = .parityVerified
        try context.save()
    }

    private func report(
        migrationID: UUID,
        state: ESheepCloudMigrationState,
        plan: ESheepCloudV1MappingPlanV2
    ) -> ESheepCloudMigrationPreparationReportV2 {
        ESheepCloudMigrationPreparationReportV2(
            migrationID: migrationID,
            backupDirectoryRelativePath: state.sourceBackupDirectoryRelativePath,
            backupManifestDigest: state.sourceBackupManifestDigest,
            mappingDigest: plan.mappingDigest,
            acceptedReceiptCount: plan.operations.count {
                $0.disposition == .mapAcceptedReceipt
            },
            convertibleIntentCount: plan.operations.count {
                $0.disposition == .convertAfterSnapshot
            },
            unknownResultCount: plan.operations.count {
                $0.disposition == .queryV1Result
            },
            attentionCount: plan.operations.count {
                $0.disposition == .createServerAttention
            },
            photoReconciliationCount: plan.operations.count {
                $0.disposition == .reconcilePhotoAsset
            },
            forwardRepairCount: plan.operations.count {
                $0.disposition == .forwardRepairRequired
            }
        )
    }

    fileprivate struct ResourceSource: Sendable {
        let assetID: UUID
        let relativePath: String
        let declaredSHA256: String
    }

    private static func resourceSources(
        farmID: UUID,
        context: ModelContext
    ) throws -> [ResourceSource] {
        try context.fetch(FetchDescriptor<PhotoAssetRecord>())
            .filter { $0.farmID == farmID }
            .map {
                ResourceSource(
                    assetID: $0.id,
                    relativePath: $0.relativePath,
                    declaredSHA256: $0.sha256.lowercased()
                )
            }
            .sorted { $0.assetID.uuidString < $1.assetID.uuidString }
    }

    private static func mappingPlan(
        farmID: UUID,
        sourceFarmGeneration: Int,
        targetFarmGeneration: Int,
        fallbackDeviceID: UUID,
        resources: [ESheepCloudMigrationResourceEntryV2],
        context: ModelContext,
        now: Date
    ) throws -> ESheepCloudV1MappingPlanV2 {
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
            .filter { $0.farmID == farmID }
        let outboxes = try context.fetch(FetchDescriptor<OutboxItem>())
            .filter { $0.farmID == farmID && $0.deliveryProvider == .supabase }
        let outboxesByOperation = Dictionary(grouping: outboxes, by: \.operationID)
        let sequences = try FarmStorageRouter.operationSequences(
            farmID: farmID,
            context: context
        )
        let sorted = operations.sorted {
            let lhsSequence = sequences[$0.id] ?? Int64.max
            let rhsSequence = sequences[$1.id] ?? Int64.max
            if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        var previousPendingByEntity: [String: UUID] = [:]
        var mapped: [ESheepCloudV1OperationMappingV2] = []
        mapped.reserveCapacity(sorted.count)
        for operation in sorted {
            let rows = outboxesByOperation[operation.id] ?? []
            let statuses = rows.map(\.status).sorted { $0.rawValue < $1.rawValue }
            let sequence = sequences[operation.id] ?? 0
            let key = operation.entityType + ":" +
                (operation.entityID?.uuidString.lowercased() ?? farmID.uuidString.lowercased())
            let prerequisite = previousPendingByEntity[key].map { [$0] } ?? []
            let value = map(
                operation: operation,
                statuses: statuses,
                sequence: sequence,
                fallbackDeviceID: fallbackDeviceID,
                prerequisiteCommandIDs: prerequisite
            )
            if value.disposition == .convertAfterSnapshot ||
                value.disposition == .queryV1Result ||
                value.disposition == .createServerAttention ||
                value.disposition == .reconcilePhotoAsset {
                previousPendingByEntity[key] = operation.id
            }
            mapped.append(value)
        }
        return try ESheepCloudV1MappingPlanV2.make(
            farmID: farmID,
            sourceFarmGeneration: sourceFarmGeneration,
            targetFarmGeneration: targetFarmGeneration,
            fallbackDeviceID: fallbackDeviceID,
            createdAt: now,
            operations: mapped,
            resources: resources
        )
    }

    private static func map(
        operation: DomainOperation,
        statuses: [OutboxStatus],
        sequence: Int64,
        fallbackDeviceID: UUID,
        prerequisiteCommandIDs: [UUID]
    ) -> ESheepCloudV1OperationMappingV2 {
        let statusNames = statuses.map(\.rawValue)
        func result(
            _ disposition: ESheepCloudV1OperationDispositionV2,
            draft: ESheepCloudCommandDraftV2? = nil,
            fieldKey: String? = nil,
            fieldName: String? = nil,
            deviceValue: ESheepCloudValueV2? = nil,
            explanation: String? = nil
        ) -> ESheepCloudV1OperationMappingV2 {
            ESheepCloudV1OperationMappingV2(
                id: operation.id,
                sourceRequestID: operation.sourceRequestID ?? operation.id,
                accountID: operation.accountID,
                deviceID: operation.modifiedByDeviceID ?? fallbackDeviceID,
                deviceSequence: max(0, sequence),
                sourceKind: operation.kindRawValue,
                sourceEntityType: operation.entityType,
                sourceEntityID: operation.entityID,
                sourcePayloadDigest: operation.payloadDigest,
                disposition: disposition,
                draft: draft.map(ESheepCloudMigrationIntentDraftV2.init),
                prerequisiteCommandIDs: prerequisiteCommandIDs,
                attentionFieldKey: fieldKey,
                attentionFieldDisplayName: fieldName,
                attentionDeviceValue: deviceValue,
                explanation: explanation,
                legacyStatuses: statusNames
            )
        }

        guard operation.payloadDigest == CloudPayloadDigest.hex(for: operation.payload),
              sequence > 0 else {
            return result(
                .forwardRepairRequired,
                explanation: "旧操作的内容摘要或设备顺序不完整，不能猜测后重放。"
            )
        }
        // A legacy operation without an Outbox row has no durable evidence
        // that the cloud ever accepted it. Treating that absence as an
        // accepted receipt would manufacture a result during migration and
        // could silently drop a real business fact. Keep the operation in the
        // mapping plan and stop cutover until a worker can reconcile it from
        // the V1 operation ledger (or the user can make an explicit choice).
        if statuses.isEmpty {
            return result(
                .forwardRepairRequired,
                explanation: "旧操作没有保存发送记录，无法证明云端是否已接受，迁移前必须核对原始账本。"
            )
        }
        if statuses.allSatisfy({ $0 == .confirmed }) {
            return result(.mapAcceptedReceipt)
        }
        if statuses.allSatisfy({ $0 == .notRequiredLocalOnly }) {
            return result(.retainLocalAuditOnly)
        }
        if statuses.contains(.uploading) || statuses.contains(.awaitingConfirmation) {
            return result(
                .queryV1Result,
                explanation: "旧云端可能已经处理该操作，必须先按原操作编号查询结果。"
            )
        }

        let decodedPayload: FarmCommandCloudPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decodedPayload = try decoder.decode(
                FarmCommandCloudPayload.self,
                from: operation.payload
            )
            guard decodedPayload.kind.rawValue == operation.kindRawValue else {
                return result(
                    .forwardRepairRequired,
                    explanation: "旧操作类型与载荷不一致。"
                )
            }
        } catch {
            return result(
                .forwardRepairRequired,
                explanation: "旧操作载荷无法按冻结协议解码。"
            )
        }

        if let avatar = SheepAvatarCloudPayload.update(from: decodedPayload) {
            return result(
                .createServerAttention,
                fieldKey: "avatar",
                fieldName: "头像",
                deviceValue: avatar.photoAssetID.map(ESheepCloudValueV2.identifier) ?? .null,
                explanation: "旧版只保存了整份羊只资料版本，无法证明头像字段当时的云端基础值。"
            )
        }
        if decodedPayload.kind == .addPhoto {
            return result(
                .reconcilePhotoAsset,
                explanation: "按照片编号和内容哈希核对已上传资源，存在时不得重复上传。"
            )
        }
        if statuses.contains(.blockedConflict) ||
            statuses.contains(.rejectedPermission) ||
            statuses.contains(.quarantinedMembershipRevoked) ||
            statuses.contains(.supersededRemoteAuthority) {
            return result(
                .createServerAttention,
                fieldKey: "operation",
                fieldName: "本次操作",
                explanation: "旧云端没有接受这项操作，必须说明原因并由用户或管理员决定。"
            )
        }

        do {
            let command = try FarmCommandCloudPayloadDecoder.decode(decodedPayload)
            let draft = try ESheepCloudCommandFactoryV2.make(
                command: command,
                farmID: operation.farmID,
                primaryEntityType: operation.entityType,
                primaryEntityID: operation.entityID
            )
            if !draft.affectedFieldKeys.isEmpty {
                let field = draft.affectedFieldKeys.count == 1
                    ? draft.affectedFieldKeys[0]
                    : "fields"
                return result(
                    .createServerAttention,
                    fieldKey: field,
                    fieldName: field == "fields" ? "资料字段" : field,
                    explanation: "旧操作没有可信的字段级基础值，不能把迁移时看到的云端值冒充为原基础值。"
                )
            }
            return result(.convertAfterSnapshot, draft: draft)
        } catch {
            return result(
                .forwardRepairRequired,
                explanation: "这项旧操作尚无完整的强类型 V2 映射。"
            )
        }
    }
}

private enum ESheepCloudStoreBackupService {
    static func createVerifiedBackup(
        farmID: UUID,
        migrationID: UUID,
        storeURL: URL,
        applicationSupportURL: URL,
        resourceSources: [ESheepCloudMigrationCoordinator.ResourceSource],
        now: Date
    ) throws -> ESheepCloudMigrationBackupReceiptV2 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw ESheepCloudMigrationError.sourceStoreMissing
        }
        let relativeDirectory = "ESheepCloud/MigrationBackups/" +
            farmID.uuidString.lowercased() + "/" + migrationID.uuidString.lowercased()
        let destination = applicationSupportURL.appending(
            path: relativeDirectory,
            directoryHint: .isDirectory
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ESheepCloudMigrationError.backupAlreadyExistsButIsInvalid
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let building = parent.appending(
            path: ".building-" + migrationID.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: building.path) {
            try fileManager.removeItem(at: building)
        }
        try fileManager.createDirectory(at: building, withIntermediateDirectories: true)
        do {
            let sourceQuickCheck = try quickCheck(storeURL)
            guard sourceQuickCheck == "ok" else {
                throw ESheepCloudMigrationError.sourceStoreIntegrityFailed(sourceQuickCheck)
            }
            let canonicalURL = building.appending(path: "verified.store")
            try onlineBackup(source: storeURL, destination: canonicalURL)
            let backupQuickCheck = try quickCheck(canonicalURL)
            guard backupQuickCheck == "ok" else {
                throw ESheepCloudMigrationError.sourceStoreIntegrityFailed(backupQuickCheck)
            }

            let raw = building.appending(path: "raw", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: raw, withIntermediateDirectories: true)
            var files: [ESheepCloudMigrationBackupFileV2] = [
                try fileEntry(
                    canonicalURL,
                    relativeTo: building,
                    purpose: "sqlite-online-backup"
                ),
            ]
            for source in LocalStoreRecoveryService.relatedStoreURLs(for: storeURL)
                where fileManager.fileExists(atPath: source.path) {
                let target = raw.appending(
                    path: source.lastPathComponent,
                    directoryHint: source.hasDirectoryPath ? .isDirectory : .notDirectory
                )
                try fileManager.copyItem(at: source, to: target)
                files.append(try fileEntry(
                    target,
                    relativeTo: building,
                    purpose: source.hasDirectoryPath
                        ? "raw-store-support"
                        : "raw-store-file"
                ))
            }

            let resources = try resourceSources.map { source in
                let url = applicationSupportURL.appending(path: source.relativePath)
                guard fileManager.fileExists(atPath: url.path) else {
                    return ESheepCloudMigrationResourceEntryV2(
                        assetID: source.assetID,
                        relativePath: source.relativePath,
                        declaredSHA256: source.declaredSHA256,
                        observedSHA256: nil,
                        byteCount: 0,
                        isPresent: false
                    )
                }
                return ESheepCloudMigrationResourceEntryV2(
                    assetID: source.assetID,
                    relativePath: source.relativePath,
                    declaredSHA256: source.declaredSHA256,
                    observedSHA256: try sha256(url),
                    byteCount: try fileSize(url),
                    isPresent: true
                )
            }
            let manifest = ESheepCloudMigrationBackupManifestV2(
                formatVersion: 1,
                farmID: farmID,
                migrationID: migrationID,
                sourceStoreFilename: storeURL.lastPathComponent,
                sourceQuickCheck: sourceQuickCheck,
                createdAt: now,
                files: files.sorted { $0.relativePath < $1.relativePath },
                resources: resources
            )
            let manifestData = try ESheepCloudCanonicalCodec.encode(manifest)
            let manifestDigest = SHA256.hash(data: manifestData)
                .map { String(format: "%02x", $0) }
                .joined()
            try manifestData.write(
                to: building.appending(path: "manifest.json"),
                options: .atomic
            )
            try Data((manifestDigest + "\n").utf8).write(
                to: building.appending(path: "manifest.sha256"),
                options: .atomic
            )
            try fileManager.moveItem(at: building, to: destination)
            return ESheepCloudMigrationBackupReceiptV2(
                directoryRelativePath: relativeDirectory,
                manifestDigest: manifestDigest,
                quickCheck: sourceQuickCheck,
                manifest: manifest
            )
        } catch {
            try? fileManager.removeItem(at: building)
            if error is ESheepCloudMigrationError { throw error }
            throw ESheepCloudMigrationError.backupFailed(error.localizedDescription)
        }
    }

    private static func onlineBackup(source: URL, destination: URL) throws {
        var sourceDatabase: OpaquePointer?
        var destinationDatabase: OpaquePointer?
        guard sqlite3_open_v2(
            source.path,
            &sourceDatabase,
            // An active SwiftData store uses WAL. SQLite must be allowed to
            // participate in WAL/SHM coordination even though every SQL
            // statement on this connection is forced read-only below.
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let sourceDatabase else {
            throw ESheepCloudMigrationError.backupFailed("source_open_failed")
        }
        defer { sqlite3_close_v2(sourceDatabase) }
        try enforceQueryOnly(sourceDatabase, operation: "source_backup")
        guard sqlite3_open_v2(
            destination.path,
            &destinationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let destinationDatabase else {
            throw ESheepCloudMigrationError.backupFailed("destination_open_failed")
        }
        defer { sqlite3_close_v2(destinationDatabase) }
        sqlite3_busy_timeout(sourceDatabase, 5_000)
        sqlite3_busy_timeout(destinationDatabase, 5_000)
        guard let backup = sqlite3_backup_init(
            destinationDatabase,
            "main",
            sourceDatabase,
            "main"
        ) else {
            throw ESheepCloudMigrationError.backupFailed("backup_init_failed")
        }
        var result: Int32
        repeat {
            result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                sqlite3_sleep(20)
            }
        } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw ESheepCloudMigrationError.backupFailed("backup_step_failed")
        }
    }

    private static func quickCheck(_ url: URL) throws -> String {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "no_database_handle"
            if let database { sqlite3_close_v2(database) }
            throw ESheepCloudMigrationError.backupFailed(
                "quick_check_open_failed_\(openResult)_\(message)"
            )
        }
        defer { sqlite3_close_v2(database) }
        try enforceQueryOnly(database, operation: "quick_check")
        sqlite3_busy_timeout(database, 5_000)
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "PRAGMA quick_check;",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw ESheepCloudMigrationError.backupFailed(
                "quick_check_prepare_failed_\(prepareResult)_" +
                    String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let bytes = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: bytes))
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw ESheepCloudMigrationError.backupFailed(
                "quick_check_step_failed_\(stepResult)_" +
                    String(cString: sqlite3_errmsg(database))
            )
        }
        return rows.joined(separator: ";")
    }

    private static func enforceQueryOnly(
        _ database: OpaquePointer,
        operation: String
    ) throws {
        let result = sqlite3_exec(
            database,
            "PRAGMA query_only=ON;",
            nil,
            nil,
            nil
        )
        guard result == SQLITE_OK else {
            throw ESheepCloudMigrationError.backupFailed(
                "\(operation)_query_only_failed_\(result)_" +
                    String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func fileEntry(
        _ url: URL,
        relativeTo root: URL,
        purpose: String
    ) throws -> ESheepCloudMigrationBackupFileV2 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        let relativePath = String(url.path.dropFirst(root.path.count + 1))
        if values.isDirectory == true {
            return .init(
                relativePath: relativePath,
                byteCount: 0,
                sha256: nil,
                purpose: purpose
            )
        }
        return .init(
            relativePath: relativePath,
            byteCount: try fileSize(url),
            sha256: try sha256(url),
            purpose: purpose
        )
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
