import Foundation
import SwiftData

enum DomainOperationKind: String, Codable, Sendable {
    case createFarm
    case updateFarmLocation
    case createPen
    case updatePen
    case setPenActive
    case addSheep
    case updateSheepProfile
    case recordWeight
    case correctWeight
    case recordWeaning
    case createBreedingProgram
    case transferSheep
    case correctTransfer
    case removeSheep
    case correctRemoval
    case restoreSheep
    case createBatch
    case assignBatchMembership
    case leaveBatchMembership
    case addIngredient
    case createRecipe
    case addRecipeComponent
    case recordFeed
    case recordHealth
    case receiveInventory
    case addSemen
    case recordReproduction
    case care
    case addNote
    case tombstoneEntity
    case restoreTombstonedEntity
    case resolveConflict
    case recoverEntity
    case bootstrapEntity
}

enum OutboxStatus: String, Codable, Sendable {
    case pending
    case uploading
    case awaitingConfirmation
    case confirmed
    case retryableFailure
    case blockedConflict
    case rejectedPermission
}

struct AppliedCommandResult: Sendable {
    let entityType: String
    let entityID: UUID
    let baseRevision: Int
    let resultingRevision: Int
    let payload: Data
}

@Model
final class DomainOperation {
    var id: UUID
    var farmID: UUID
    var accountID: UUID
    var kindRawValue: String
    var occurredAt: Date
    var createdAt: Date
    var summary: String
    var schemaVersion: Int = 1
    var entityType: String = "FarmRoot"
    var entityID: UUID?
    var baseRevision: Int = 0
    var resultingRevision: Int = 1
    var payload: Data = Data("{}".utf8)
    var payloadDigest: String = ""
    var modifiedByDeviceID: UUID?
    var capabilityCertificate: String = ""
    var operationSignature: Data?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        accountID: UUID,
        kind: DomainOperationKind,
        occurredAt: Date = .now,
        summary: String,
        entityType: String = "FarmRoot",
        entityID: UUID? = nil,
        baseRevision: Int = 0,
        resultingRevision: Int = 1,
        payload: Data = Data("{}".utf8)
    ) {
        self.id = id
        self.farmID = farmID
        self.accountID = accountID
        self.kindRawValue = kind.rawValue
        self.occurredAt = occurredAt
        self.createdAt = .now
        self.summary = summary
        self.schemaVersion = 2
        self.entityType = entityType
        self.entityID = entityID
        self.baseRevision = baseRevision
        self.resultingRevision = resultingRevision
        self.payload = payload
        self.payloadDigest = CloudPayloadDigest.hex(for: payload)
        self.capabilityCertificate = ""
    }
}

@Model
final class OutboxItem {
    var id: UUID
    var farmID: UUID
    var accountID: UUID
    var operationID: UUID
    var createdAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
    var statusRawValue: String
    var errorMessage: String?
    var entityType: String = "FarmRoot"
    var entityID: UUID?
    var baseRevision: Int = 0
    var payloadDigest: String = ""
    var operationSignature: Data?
    var capabilityCertificate: String = ""
    var nextRetryAt: Date?
    var cloudRecordName: String?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        accountID: UUID,
        operationID: UUID,
        entityType: String = "FarmRoot",
        entityID: UUID? = nil,
        baseRevision: Int = 0,
        payloadDigest: String = ""
    ) {
        self.id = id
        self.farmID = farmID
        self.accountID = accountID
        self.operationID = operationID
        self.createdAt = .now
        self.lastAttemptAt = nil
        self.attemptCount = 0
        self.statusRawValue = OutboxStatus.pending.rawValue
        self.errorMessage = nil
        self.entityType = entityType
        self.entityID = entityID
        self.baseRevision = baseRevision
        self.payloadDigest = payloadDigest
        self.capabilityCertificate = ""
    }

    var status: OutboxStatus {
        OutboxStatus(rawValue: statusRawValue) ?? .retryableFailure
    }
}

@Model
final class TombstoneRecord {
    var id: UUID
    var farmID: UUID
    var entityType: String
    var entityID: UUID
    var deletedAt: Date
    var deletedByAccountID: UUID
    var reason: String
    var revision: Int = 1
    var operationID: UUID?
    var restoredByOperationID: UUID?
    var restoredAt: Date?

    init(id: UUID = UUID(), farmID: UUID, entityType: String, entityID: UUID, deletedByAccountID: UUID, reason: String, revision: Int = 1, operationID: UUID? = nil) {
        self.id = id
        self.farmID = farmID
        self.entityType = entityType
        self.entityID = entityID
        self.deletedAt = .now
        self.deletedByAccountID = deletedByAccountID
        self.reason = reason
        self.revision = revision
        self.operationID = operationID
    }
}
