import SwiftData

/// The sole local projection boundary for authoritative eSheep+ Cloud V2
/// business events that still reuse an existing SwiftData business writer.
///
/// This type is intentionally outside the V2 wire adapter and has no gateway
/// or provider dependency. `route` comes from the exhaustive V2 command
/// registry and is required so a newly added command cannot silently fall
/// through to a generic event-count update. The existing writer is invoked
/// only after V2 decoding, digest verification, and route selection have
/// completed; its internal envelope is an implementation detail of the local
/// projection writer, never a V2 transport contract.
enum ESheepCloudAuthoritativeProjectionWriter {
    static func apply(
        command: FarmCommand,
        route: String,
        event: ESheepCloudEventEnvelopeV2,
        entityType: String,
        context: ModelContext
    ) throws -> RemoteApplyOutcome {
        guard !route.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ESheepCloudProjectionError.unsupportedEvent
        }
        return try RemoteDomainApplyService().applyV2AuthoritativeCommand(
            command,
            event: event,
            entityType: entityType,
            context: context
        )
    }
}
