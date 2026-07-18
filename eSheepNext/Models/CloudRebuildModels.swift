import Foundation
import SwiftData

enum CloudRebuildStatus: String, Codable, CaseIterable, Sendable {
    case preparing
    case fetching
    case downloadingAssets
    case validating
    case readyToCommit
    case committing
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .preparing: "正在准备"
        case .fetching: "正在拉取云端记录"
        case .downloadingAssets: "正在下载照片"
        case .validating: "正在校验与重建"
        case .readyToCommit: "可以切换"
        case .committing: "正在切换本地缓存"
        case .completed: "重建完成"
        case .failed: "重建失败"
        case .cancelled: "已取消"
        }
    }

    var isRunning: Bool {
        [.preparing, .fetching, .downloadingAssets, .validating, .committing].contains(self)
    }
}

enum CloudRebuildReason: String, Codable, CaseIterable, Sendable {
    case engineStateCorrupted
    case manualVerification
    case reinstallRecovery
    case accountRecovery

    var displayName: String {
        switch self {
        case .engineStateCorrupted: "同步状态损坏"
        case .manualVerification: "手动完整校验"
        case .reinstallRecovery: "重装后恢复"
        case .accountRecovery: "账号复核恢复"
        }
    }
}

enum CloudRebuildIssueSeverity: String, Codable, Sendable {
    case warning
    case blocking
}

struct CloudRebuildResult: Codable, Sendable, Equatable {
    let sessionID: UUID
    let farmID: UUID
    let fetchedRecordCount: Int
    let fetchedOperationCount: Int
    let fetchedAssetCount: Int
    let appliedOperationCount: Int
    let preservedOutboxCount: Int
    let highestRevision: Int
    let entityDigest: String
    let completedAt: Date
}

@Model
final class CloudRebuildSessionRecord {
    var id: UUID
    var farmID: UUID
    var databaseScopeRawValue: String
    var reasonRawValue: String
    var statusRawValue: String
    var stagingRelativePath: String
    var pageCount: Int
    var fetchedRecordCount: Int
    var fetchedOperationCount: Int
    var fetchedAssetCount: Int
    var downloadedAssetCount: Int
    var appliedOperationCount: Int
    var preservedOutboxCount: Int
    var highestRevision: Int
    var entityDigest: String
    var progress: Double
    var lastErrorCode: String?
    var lastErrorMessage: String?
    var retryAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        databaseScope: CloudDatabaseScope,
        reason: CloudRebuildReason,
        stagingRelativePath: String
    ) {
        self.id = id
        self.farmID = farmID
        self.databaseScopeRawValue = databaseScope.rawValue
        self.reasonRawValue = reason.rawValue
        self.statusRawValue = CloudRebuildStatus.preparing.rawValue
        self.stagingRelativePath = stagingRelativePath
        self.pageCount = 0
        self.fetchedRecordCount = 0
        self.fetchedOperationCount = 0
        self.fetchedAssetCount = 0
        self.downloadedAssetCount = 0
        self.appliedOperationCount = 0
        self.preservedOutboxCount = 0
        self.highestRevision = 0
        self.entityDigest = ""
        self.progress = 0
        self.createdAt = .now
        self.updatedAt = .now
    }

    var status: CloudRebuildStatus {
        CloudRebuildStatus(rawValue: statusRawValue) ?? .failed
    }

    var databaseScope: CloudDatabaseScope {
        CloudDatabaseScope(rawValue: databaseScopeRawValue) ?? .privateDatabase
    }

    var reason: CloudRebuildReason {
        CloudRebuildReason(rawValue: reasonRawValue) ?? .manualVerification
    }
}

@Model
final class CloudRebuildIssueRecord {
    var id: UUID
    var sessionID: UUID
    var farmID: UUID
    var severityRawValue: String
    var code: String
    var recordName: String?
    var detail: String
    var rawPayload: Data?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        farmID: UUID,
        severity: CloudRebuildIssueSeverity,
        code: String,
        recordName: String? = nil,
        detail: String,
        rawPayload: Data? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.farmID = farmID
        self.severityRawValue = severity.rawValue
        self.code = code
        self.recordName = recordName
        self.detail = detail
        self.rawPayload = rawPayload
        self.createdAt = .now
    }

    var severity: CloudRebuildIssueSeverity {
        CloudRebuildIssueSeverity(rawValue: severityRawValue) ?? .blocking
    }
}

@Model
final class CloudSyncDiagnosticSnapshotRecord {
    var id: UUID
    var farmID: UUID
    var workerHealth: String
    var cloudAccount: String
    var zoneName: String
    var databaseScopeRawValue: String
    var engineStateModifiedAt: Date?
    var pendingOutboxCount: Int
    var uploadingOutboxCount: Int
    var blockedOutboxCount: Int
    var membershipGeneration: Int
    var authoritativeEntityCount: Int
    var assetCount: Int
    var entityDigest: String
    var assetDigest: String
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        workerHealth: String,
        cloudAccount: String,
        zoneName: String,
        databaseScope: CloudDatabaseScope,
        engineStateModifiedAt: Date?,
        pendingOutboxCount: Int,
        uploadingOutboxCount: Int,
        blockedOutboxCount: Int,
        membershipGeneration: Int,
        authoritativeEntityCount: Int,
        assetCount: Int,
        entityDigest: String,
        assetDigest: String
    ) {
        self.id = id
        self.farmID = farmID
        self.workerHealth = workerHealth
        self.cloudAccount = cloudAccount
        self.zoneName = zoneName
        self.databaseScopeRawValue = databaseScope.rawValue
        self.engineStateModifiedAt = engineStateModifiedAt
        self.pendingOutboxCount = pendingOutboxCount
        self.uploadingOutboxCount = uploadingOutboxCount
        self.blockedOutboxCount = blockedOutboxCount
        self.membershipGeneration = membershipGeneration
        self.authoritativeEntityCount = authoritativeEntityCount
        self.assetCount = assetCount
        self.entityDigest = entityDigest
        self.assetDigest = assetDigest
        self.capturedAt = .now
    }
}

