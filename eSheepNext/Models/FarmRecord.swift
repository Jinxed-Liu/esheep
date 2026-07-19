import Foundation
import SwiftData

enum FarmLocationSource: String, CaseIterable, Codable, Sendable {
    case mapSearch
    case manualCoordinate
    case currentLocation
    case legacyMigration

    var displayName: String {
        switch self {
        case .mapSearch: "地图搜索"
        case .manualCoordinate: "手动坐标"
        case .currentLocation: "当前位置"
        case .legacyMigration: "旧版迁移"
        }
    }
}

struct FarmLocationSnapshot: Sendable, Equatable {
    let displayName: String
    let latitude: Double
    let longitude: Double
    let timeZoneIdentifier: String
    let source: FarmLocationSource
    let updatedAt: Date
}

@Model
final class FarmRecord {
    var id: UUID
    var ownerAccountID: UUID
    var name: String
    var roleRawValue: String
    var membershipStatusRawValue: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// 旧数据库兼容字段。只有完整校验并生成正式云端基线后，升级服务才能解除此限制。
    var isLocalOnlyMigration: Bool = false
    var locationDisplayName: String?
    var latitude: Double?
    var longitude: Double?
    var coordinateReferenceSystem: String = "wgs84"
    var addressSnapshot: String?
    var timeZoneIdentifier: String = "Asia/Shanghai"
    var locationSourceRawValue: String?
    var horizontalAccuracyMeters: Double?
    var locationUpdatedAt: Date?

    init(
        id: UUID = UUID(),
        ownerAccountID: UUID,
        name: String,
        role: FarmRole = .owner,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ownerAccountID = ownerAccountID
        self.name = name
        self.roleRawValue = role.rawValue
        self.membershipStatusRawValue = "active"
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = nil
        self.isLocalOnlyMigration = false
        self.locationDisplayName = nil
        self.latitude = nil
        self.longitude = nil
        self.coordinateReferenceSystem = "wgs84"
        self.addressSnapshot = nil
        self.timeZoneIdentifier = "Asia/Shanghai"
        self.locationSourceRawValue = nil
        self.horizontalAccuracyMeters = nil
        self.locationUpdatedAt = nil
    }

    var role: FarmRole {
        FarmRole(rawValue: roleRawValue) ?? .worker
    }

    var locationSnapshot: FarmLocationSnapshot? {
        guard let latitude,
              let longitude,
              let locationDisplayName,
              let locationSource = locationSourceRawValue.flatMap(FarmLocationSource.init(rawValue:)),
              let locationUpdatedAt else {
            return nil
        }
        return FarmLocationSnapshot(
            displayName: locationDisplayName,
            latitude: latitude,
            longitude: longitude,
            timeZoneIdentifier: timeZoneIdentifier,
            source: locationSource,
            updatedAt: locationUpdatedAt
        )
    }
}

@Model
final class FarmActivity {
    var id: UUID
    var farmID: UUID
    var title: String
    var detail: String
    var occurredAt: Date
    var createdAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        title: String,
        detail: String = "",
        occurredAt: Date = .now,
        createdAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
        self.createdAt = createdAt
    }
}
