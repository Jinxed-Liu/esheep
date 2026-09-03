import SwiftData

/// V1 migration-only compatibility boundary for the already-tested SwiftData
/// business writer. Normal V2 event replay must use
/// `ESheepCloudAuthoritativeProjectionWriter`; keeping this type separate makes
/// it impossible for a future V2 call site to accidentally depend on a V1
/// compatibility name or transport contract.
enum ESheepCloudLegacyDomainBridge {
    @MainActor
    static func apply(
        command: FarmCommand,
        event: ESheepCloudEventEnvelopeV2,
        entityType: String,
        context: ModelContext
    ) throws -> RemoteApplyOutcome {
        return try RemoteDomainApplyService().applyV2AuthoritativeCommand(
            command,
            event: event,
            entityType: entityType,
            context: context
        )
    }
}
