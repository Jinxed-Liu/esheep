import Foundation
import SwiftData

enum FarmStorageTransitionError: LocalizedError, Equatable {
    case profileMissing
    case transitionAlreadyActive
    case retiredProviderUnavailable
    case sameMode
    case sharedFarmCannotBecomeLocal
    case invalidState(
        expected: FarmStorageTransitionState,
        actual: FarmStorageTransitionState
    )
    case migrationIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .profileMissing:
            "当前牧场缺少存储模式配置。"
        case .transitionAlreadyActive:
            "当前牧场已经在执行存储迁移。"
        case .retiredProviderUnavailable:
            "旧云存储已停用；该牧场会在启动清理中删除，不能执行存储迁移。"
        case .sameMode:
            "目标存储模式与当前模式相同。"
        case .sharedFarmCannotBecomeLocal:
            "共享牧场不能直接转为本地牧场，请先移除其他成员或复制为新牧场。"
        case .invalidState(let expected, let actual):
            "迁移状态不匹配：需要 \(expected.rawValue)，当前为 \(actual.rawValue)。"
        case .migrationIdentityMismatch:
            "迁移任务标识不匹配，已拒绝修改存储权威。"
        }
    }
}

@MainActor
enum FarmStorageTransitionCoordinator {
    static func begin(
        farmID: UUID,
        targetMode: FarmStorageMode,
        context: ModelContext,
        migrationID: UUID = UUID()
    ) throws -> UUID {
        let profile = try profile(farmID: farmID, context: context)
        guard profile.transitionState == .idle else {
            throw FarmStorageTransitionError.transitionAlreadyActive
        }
        guard profile.mode != .retiredAppleCloud,
              targetMode != .retiredAppleCloud else {
            throw FarmStorageTransitionError.retiredProviderUnavailable
        }
        guard profile.mode != targetMode else {
            throw FarmStorageTransitionError.sameMode
        }
        if targetMode == .localOnly {
            let activeMembers = try context.fetch(FetchDescriptor<FarmMembershipBinding>()).filter {
                $0.farmID == farmID && $0.status == .active
            }
            let distinctMemberAccounts = Set(activeMembers.map(\.accountID))
            if distinctMemberAccounts.count > 1 {
                throw FarmStorageTransitionError.sharedFarmCannotBecomeLocal
            }
        }

        profile.migrationID = migrationID
        profile.sourceModeRawValue = profile.mode.rawValue
        profile.targetModeRawValue = targetMode.rawValue
        profile.transitionStateRawValue = FarmStorageTransitionState.preparing.rawValue
        profile.updatedAt = .now
        try context.save()
        return migrationID
    }

    static func markBaselineUploading(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        try advance(
            farmID: farmID,
            migrationID: migrationID,
            from: .preparing,
            to: .uploadingBaseline,
            context: context
        )
    }

    static func markStagingRebuild(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        try advance(
            farmID: farmID,
            migrationID: migrationID,
            from: .uploadingBaseline,
            to: .rebuildingStagingStore,
            context: context
        )
    }

    static func markVerifying(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        try advance(
            farmID: farmID,
            migrationID: migrationID,
            from: .rebuildingStagingStore,
            to: .verifying,
            context: context
        )
    }

    static func markReadyToCommit(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        try advance(
            farmID: farmID,
            migrationID: migrationID,
            from: .verifying,
            to: .committingAuthority,
            context: context
        )
    }

    /// This is the only method that changes the active authority. From this
    /// point forward a failure is resumed against the target and never rolls
    /// back to the source automatically.
    static func commitAuthority(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        let profile = try checkedProfile(
            farmID: farmID,
            migrationID: migrationID,
            expected: .committingAuthority,
            context: context
        )
        guard let target = profile.targetMode else {
            throw FarmStorageTransitionError.profileMissing
        }
        profile.modeRawValue = target.rawValue
        profile.authorityGeneration += 1
        profile.transitionStateRawValue = FarmStorageTransitionState.drainingOperations.rawValue
        profile.updatedAt = .now
        try context.save()
    }

    static func markSourceArchiving(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        try advance(
            farmID: farmID,
            migrationID: migrationID,
            from: .drainingOperations,
            to: .archivingSource,
            context: context
        )
    }

    static func finish(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        let profile = try checkedProfile(
            farmID: farmID,
            migrationID: migrationID,
            expected: .archivingSource,
            context: context
        )
        profile.transitionStateRawValue = FarmStorageTransitionState.idle.rawValue
        profile.migrationID = nil
        profile.sourceModeRawValue = nil
        profile.targetModeRawValue = nil
        profile.updatedAt = .now
        try context.save()
    }

    static func recordFailure(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        let profile = try profile(farmID: farmID, context: context)
        guard profile.migrationID == migrationID else {
            throw FarmStorageTransitionError.migrationIdentityMismatch
        }
        profile.transitionStateRawValue = FarmStorageTransitionState.failed.rawValue
        profile.updatedAt = .now
        try context.save()
    }

    static func resumeFailedSupabaseUpload(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        let profile = try profile(farmID: farmID, context: context)
        guard profile.migrationID == migrationID else {
            throw FarmStorageTransitionError.migrationIdentityMismatch
        }
        guard profile.transitionState == .failed else {
            throw FarmStorageTransitionError.invalidState(
                expected: .failed,
                actual: profile.transitionState
            )
        }
        guard profile.mode == .localOnly, profile.targetMode == .supabase else {
            throw FarmStorageTransitionError.profileMissing
        }
        profile.transitionStateRawValue =
            FarmStorageTransitionState.uploadingBaseline.rawValue
        profile.updatedAt = .now
        try context.save()
    }

    /// Used only after the provider has atomically confirmed a pre-commit
    /// abort. The local authority never changed, and target-generation Outbox
    /// items are retained so a replacement migration can drain them after its
    /// own commit.
    static func abortBeforeCommit(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        let profile = try profile(farmID: farmID, context: context)
        guard profile.migrationID == migrationID else {
            throw FarmStorageTransitionError.migrationIdentityMismatch
        }
        let abortable: Set<FarmStorageTransitionState> = [
            .preparing,
            .uploadingBaseline,
            .rebuildingStagingStore,
            .verifying,
            .failed,
        ]
        guard profile.mode == .localOnly,
              profile.targetMode == .supabase,
              abortable.contains(profile.transitionState) else {
            throw FarmStorageTransitionError.invalidState(
                expected: .failed,
                actual: profile.transitionState
            )
        }
        for record in try context.fetch(
            FetchDescriptor<FarmBaselineMigrationRecord>()
        ) where record.farmID == farmID &&
            record.migrationID == migrationID {
            context.delete(record)
        }
        profile.transitionStateRawValue = FarmStorageTransitionState.idle.rawValue
        profile.migrationID = nil
        profile.sourceModeRawValue = nil
        profile.targetModeRawValue = nil
        profile.updatedAt = .now
        try context.save()
    }

    private static func advance(
        farmID: UUID,
        migrationID: UUID,
        from: FarmStorageTransitionState,
        to: FarmStorageTransitionState,
        context: ModelContext
    ) throws {
        let profile = try checkedProfile(
            farmID: farmID,
            migrationID: migrationID,
            expected: from,
            context: context
        )
        profile.transitionStateRawValue = to.rawValue
        profile.updatedAt = .now
        try context.save()
    }

    private static func checkedProfile(
        farmID: UUID,
        migrationID: UUID,
        expected: FarmStorageTransitionState,
        context: ModelContext
    ) throws -> FarmStorageProfile {
        let profile = try profile(farmID: farmID, context: context)
        guard profile.migrationID == migrationID else {
            throw FarmStorageTransitionError.migrationIdentityMismatch
        }
        guard profile.transitionState == expected else {
            throw FarmStorageTransitionError.invalidState(
                expected: expected,
                actual: profile.transitionState
            )
        }
        return profile
    }

    private static func profile(
        farmID: UUID,
        context: ModelContext
    ) throws -> FarmStorageProfile {
        guard let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>()).first(where: {
            $0.farmID == farmID
        }) else {
            throw FarmStorageTransitionError.profileMissing
        }
        return profile
    }
}
