import Foundation
import SwiftData

enum InsightMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

enum InsightMessageStatus: String, Codable, Sendable {
    case pending
    case streaming
    case completed
    case failed
    case cancelled
}

enum InsightActionRisk: String, Codable, Sendable {
    case normal
    case high
}

enum InsightActionStatus: String, Codable, Sendable {
    case proposed
    case approved
    case executed
    case rejected
    case stale
    case failed
}

@Model
final class InsightConversationRecord {
    var id: UUID
    var accountID: UUID
    var farmID: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var revision: Int64

    init(
        id: UUID = UUID(),
        accountID: UUID,
        farmID: UUID,
        title: String = "新对话",
        createdAt: Date = .now,
        revision: Int64 = 1
    ) {
        self.id = id
        self.accountID = accountID
        self.farmID = farmID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.deletedAt = nil
        self.revision = revision
    }
}

@Model
final class InsightMessageRecord {
    var id: UUID
    var conversationID: UUID
    var accountID: UUID
    var farmID: UUID
    var roleRawValue: String
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var statusRawValue: String
    var provider: String
    var model: String
    var errorMessage: String?
    var providerResponseID: String?
    var toolName: String?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        accountID: UUID,
        farmID: UUID,
        role: InsightMessageRole,
        text: String,
        createdAt: Date = .now,
        status: InsightMessageStatus = .completed,
        provider: String = "mimo",
        model: String = "mimo-v2.5-pro",
        toolName: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.accountID = accountID
        self.farmID = farmID
        self.roleRawValue = role.rawValue
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.statusRawValue = status.rawValue
        self.provider = provider
        self.model = model
        self.errorMessage = nil
        self.providerResponseID = nil
        self.toolName = toolName
    }

    var role: InsightMessageRole {
        get { InsightMessageRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    var status: InsightMessageStatus {
        get { InsightMessageStatus(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }
}

@Model
final class InsightAttachmentRecord {
    var id: UUID
    var conversationID: UUID
    var messageID: UUID?
    var accountID: UUID
    var farmID: UUID
    var mimeType: String
    var imageData: Data?
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
    var digest: String
    var createdAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        messageID: UUID? = nil,
        accountID: UUID,
        farmID: UUID,
        mimeType: String = "image/jpeg",
        imageData: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        digest: String
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.accountID = accountID
        self.farmID = farmID
        self.mimeType = mimeType
        self.imageData = imageData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = imageData.count
        self.digest = digest
        self.createdAt = .now
        self.deletedAt = nil
    }
}

@Model
final class InsightActionDraftRecord {
    var id: UUID
    var conversationID: UUID
    var messageID: UUID?
    var accountID: UUID
    var farmID: UUID
    var originDeviceID: UUID
    var toolName: String
    var title: String
    var summary: String
    var argumentsJSON: Data
    var riskRawValue: String
    var requiredCapabilityRawValue: String
    var expectedEntityID: UUID?
    var expectedRevision: Int?
    var reason: String
    var statusRawValue: String
    var createdAt: Date
    var updatedAt: Date
    var executedOperationID: UUID?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        messageID: UUID? = nil,
        accountID: UUID,
        farmID: UUID,
        originDeviceID: UUID,
        toolName: String,
        title: String,
        summary: String,
        argumentsJSON: Data,
        risk: InsightActionRisk,
        requiredCapability: FarmCapability,
        expectedEntityID: UUID? = nil,
        expectedRevision: Int? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.accountID = accountID
        self.farmID = farmID
        self.originDeviceID = originDeviceID
        self.toolName = toolName
        self.title = title
        self.summary = summary
        self.argumentsJSON = argumentsJSON
        self.riskRawValue = risk.rawValue
        self.requiredCapabilityRawValue = requiredCapability.rawValue
        self.expectedEntityID = expectedEntityID
        self.expectedRevision = expectedRevision
        self.reason = ""
        self.statusRawValue = InsightActionStatus.proposed.rawValue
        self.createdAt = .now
        self.updatedAt = .now
        self.executedOperationID = nil
        self.errorMessage = nil
    }

    var risk: InsightActionRisk {
        InsightActionRisk(rawValue: riskRawValue) ?? .high
    }

    var requiredCapability: FarmCapability {
        FarmCapability(rawValue: requiredCapabilityRawValue) ?? .recordProduction
    }

    var status: InsightActionStatus {
        get { InsightActionStatus(rawValue: statusRawValue) ?? .failed }
        set {
            statusRawValue = newValue.rawValue
            updatedAt = .now
        }
    }
}

@Model
final class InsightExecutionReceiptRecord {
    var sourceRequestID: UUID
    var accountID: UUID
    var farmID: UUID
    var operationID: UUID
    var entityType: String
    var entityID: UUID?
    var createdAt: Date

    init(
        sourceRequestID: UUID,
        accountID: UUID,
        farmID: UUID,
        operationID: UUID,
        entityType: String,
        entityID: UUID?
    ) {
        self.sourceRequestID = sourceRequestID
        self.accountID = accountID
        self.farmID = farmID
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.createdAt = .now
    }
}

@Model
final class InsightSyncStateRecord {
    var accountID: UUID
    var cursor: String?
    var lastPulledAt: Date?
    var lastPushedAt: Date?
    var lastErrorMessage: String?

    init(accountID: UUID) {
        self.accountID = accountID
        self.cursor = nil
        self.lastPulledAt = nil
        self.lastPushedAt = nil
        self.lastErrorMessage = nil
    }
}
