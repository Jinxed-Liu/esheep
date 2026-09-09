import Foundation
import SwiftData

/// Purpose changes are offline business history even though their existing UI
/// model is DomainOperation. Only this closed business subset enters checkpoints;
/// other protocol/audit operations remain online or local-only.
enum ESheepCloudPurposeHistory {
    struct Change {
        let command: FarmCommand
        let previousPurpose: String?
    }

    static func capture(
        payload: ESheepCloudCommandPayloadV2, commandID: UUID, farmID: UUID,
        context: ModelContext, replayContext: ESheepCloudProjectionReplayContext?
    ) throws -> Change? {
        guard case .care(let care) = payload,
              case .setSheepPurpose(let sheepID, _, _, _) = care else { return nil }
        let command = FarmCommand.care(care)
        var query = FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.id == commandID && $0.farmID == farmID
        })
        query.fetchLimit = 1
        if let existing = try context.fetch(query).first {
            guard let fact = SheepPurposeTimeline.facts(from: [existing]).first else {
                throw ESheepCloudCheckpointError.malformedRecord
            }
            return Change(command: command, previousPurpose: fact.previousPurpose)
        }
        let sheep: SheepRecord?
        if let replayContext { sheep = try replayContext.sheep(id: sheepID, context: context) }
        else {
            var sheepQuery = FetchDescriptor<SheepRecord>(predicate: #Predicate {
                $0.id == sheepID && $0.farmID == farmID
            })
            sheepQuery.fetchLimit = 1
            sheep = try context.fetch(sheepQuery).first
        }
        return Change(command: command, previousPurpose: sheep?.purpose)
    }

    static func previousPurpose(from payload: Data) throws -> String? {
        try SheepPurposeTimeline.previousPurpose(from: payload)
    }

    static func record(
        command: FarmCommand, commandID: UUID, farmID: UUID, accountID: UUID,
        deviceID: UUID, occurredAt: Date, recordedAt: Date, previousPurpose: String?,
        context: ModelContext
    ) throws {
        guard case .care(.setSheepPurpose(let sheepID, _, _, let expectedRevision)) = command else { return }
        let bytes = try FarmCommandCloudPayloadEncoder.encode(
            command,
            previousSheepPurpose: previousPurpose
        )
        var query = FetchDescriptor<DomainOperation>(predicate: #Predicate {
            $0.id == commandID && $0.farmID == farmID
        })
        query.fetchLimit = 1
        let operation: DomainOperation
        if let existing = try context.fetch(query).first {
            guard existing.kindRawValue == DomainOperationKind.care.rawValue,
                  existing.entityID == sheepID, existing.accountID == accountID else { throw ESheepCloudCheckpointError.malformedRecord }
            operation = existing
        } else {
            operation = DomainOperation.makePurposeHistoryOperation(
                id: commandID,
                farmID: farmID,
                accountID: accountID,
                occurredAt: occurredAt,
                summary: command.summary,
                sheepID: sheepID,
                sourceRevision: expectedRevision,
                payload: bytes
            )
            context.insert(operation)
        }
        if operation.payload != bytes { operation.payload = bytes }
        let digest = CloudPayloadDigest.hex(for: bytes)
        if operation.payloadDigest != digest { operation.payloadDigest = digest }
        if operation.occurredAt != occurredAt { operation.occurredAt = occurredAt }
        if operation.createdAt != recordedAt { operation.createdAt = recordedAt }
        if operation.modifiedByDeviceID != deviceID { operation.modifiedByDeviceID = deviceID }
    }

    static func validateCheckpointOperation(_ operation: DomainOperation) throws {
        guard SheepPurposeTimeline.facts(from: [operation]).count == 1 else {
            throw ESheepCloudCheckpointError.schemaCoverage("DomainOperation: unregistered offline business history")
        }
    }
}
