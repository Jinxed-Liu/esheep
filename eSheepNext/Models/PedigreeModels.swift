import Foundation
import SwiftData

enum PedigreeRelationSource: String, Codable, CaseIterable, Sendable {
    case migration
    case lambing
    case manual

    var displayName: String {
        switch self {
        case .migration: "迁移资料"
        case .lambing: "产羔记录"
        case .manual: "人工确认"
        }
    }
}

enum SemenDonorStatus: String, Codable, CaseIterable, Sendable {
    case active
    case inactive

    var displayName: String { self == .active ? "在用" : "停用" }
}

enum PaternalIdentitySource: String, Codable, CaseIterable, Sendable {
    case ram
    case semenDonor
    case unknown

    var displayName: String {
        switch self {
        case .ram: "本场种公羊"
        case .semenDonor: "冻精供体"
        case .unknown: "父本未知"
        }
    }
}

@Model
final class SemenDonorRecord {
    var id: UUID
    var farmID: UUID
    var name: String
    var registrationNumber: String
    var breed: String
    var linkedRamID: UUID?
    var note: String
    var statusRawValue: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        farmID: UUID,
        name: String,
        registrationNumber: String = "",
        breed: String,
        linkedRamID: UUID? = nil,
        note: String = "",
        status: SemenDonorStatus = .active,
        revision: Int = 1,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.farmID = farmID
        self.name = name
        self.registrationNumber = registrationNumber
        self.breed = breed
        self.linkedRamID = linkedRamID
        self.note = note
        self.statusRawValue = status.rawValue
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var status: SemenDonorStatus {
        SemenDonorStatus(rawValue: statusRawValue) ?? .inactive
    }
}

/// 系谱当前状态仍只保存在 `SheepRecord`；本表只记录不可变的关系变更事实。
@Model
final class PedigreeChangeRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID
    var beforeDamID: UUID?
    var afterDamID: UUID?
    var beforeSireID: UUID?
    var afterSireID: UUID?
    var beforeSemenDonorID: UUID?
    var afterSemenDonorID: UUID?
    var beforeDamSourceRawValue: String?
    var afterDamSourceRawValue: String?
    var beforeSireSourceRawValue: String?
    var afterSireSourceRawValue: String?
    var reason: String
    var changedByAccountID: UUID
    var sheepRevision: Int
    var occurredAt: Date

    init(
        id: UUID = UUID(),
        farmID: UUID,
        sheepID: UUID,
        beforeDamID: UUID?,
        afterDamID: UUID?,
        beforeSireID: UUID?,
        afterSireID: UUID?,
        beforeSemenDonorID: UUID?,
        afterSemenDonorID: UUID?,
        beforeDamSourceRawValue: String?,
        afterDamSourceRawValue: String?,
        beforeSireSourceRawValue: String?,
        afterSireSourceRawValue: String?,
        reason: String,
        changedByAccountID: UUID,
        sheepRevision: Int,
        occurredAt: Date = .now
    ) {
        self.id = id
        self.farmID = farmID
        self.sheepID = sheepID
        self.beforeDamID = beforeDamID
        self.afterDamID = afterDamID
        self.beforeSireID = beforeSireID
        self.afterSireID = afterSireID
        self.beforeSemenDonorID = beforeSemenDonorID
        self.afterSemenDonorID = afterSemenDonorID
        self.beforeDamSourceRawValue = beforeDamSourceRawValue
        self.afterDamSourceRawValue = afterDamSourceRawValue
        self.beforeSireSourceRawValue = beforeSireSourceRawValue
        self.afterSireSourceRawValue = afterSireSourceRawValue
        self.reason = reason
        self.changedByAccountID = changedByAccountID
        self.sheepRevision = sheepRevision
        self.occurredAt = occurredAt
    }
}
