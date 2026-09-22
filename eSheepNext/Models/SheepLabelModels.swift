import Foundation
import SwiftData

enum SheepLabelColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case yellow, green, red, white, orange, lightBlue = "light-blue", pink, black, purple, darkBlue = "dark-blue"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .yellow: "黄色"; case .green: "绿色"; case .red: "红色"; case .white: "白色"
        case .orange: "橙色"; case .lightBlue: "浅蓝色"; case .pink: "粉色"; case .black: "黑色"
        case .purple: "紫色"; case .darkBlue: "深蓝色"
        }
    }
    var restriction: String { self == .yellow ? "仅公羊" : self == .green ? "仅母羊" : "所有性别" }
    func allows(_ sex: SheepSex) -> Bool {
        switch self { case .yellow: sex == .ram; case .green: sex == .ewe; default: true }
    }
}

struct SheepLabelValue: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var color: SheepLabelColor
    var note: String
    var sortOrder: Int
    var isActive: Bool
    var revision: Int
}

struct SheepLabelDraft: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var changeID: UUID = UUID()
    var name: String = ""
    var color: SheepLabelColor = .red
    var note: String = ""
    var sortOrder: Int = 0
    var isActive: Bool = true
    var expectedRevision: Int = 0
}

struct SheepLabelDeleteDraft: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var changeID: UUID = UUID()
    var expectedRevision: Int
}

struct SheepLabelsEditDraft: Codable, Sendable, Equatable {
    var id: UUID = UUID()
    let sheepID: UUID
    var addIDs: [UUID] = []
    var removeIDs: [UUID] = []
    var primaryLabelID: UUID? = nil
    // Setting a primary is explicit; ordinary additions preserve the current primary.
    var setsPrimary: Bool = false
    var expectedRevision: Int? = nil
}

struct SheepLabelProfileDraft: Codable, Sendable, Equatable {
    var id: UUID = UUID()
    let sheepID: UUID
    let earTag: String
    let breed: String
    let sex: SheepSex
    let birthAt: Date?
    let note: String
    var currentParity: Int? = nil
    var parityRecordedAt: Date? = nil
    let removeLabelIDs: [UUID]
    let expectedRevision: Int
}

enum SheepLabelCommand: Codable, Sendable, Equatable {
    case saveLabel(SheepLabelDraft)
    case deleteLabel(SheepLabelDeleteDraft)
    case editLabels(SheepLabelsEditDraft)
    case patchProfile(SheepLabelProfileDraft)
    var primaryID: UUID {
        switch self {
        case .saveLabel(let d): d.id
        case .deleteLabel(let d): d.id
        case .editLabels(let d): d.sheepID
        case .patchProfile(let d): d.sheepID
        }
    }
    var changeID: UUID {
        switch self {
        case .saveLabel(let d): d.changeID
        case .deleteLabel(let d): d.changeID
        case .editLabels(let d): d.id
        case .patchProfile(let d): d.id
        }
    }
    var kind: String {
        switch self {
        case .saveLabel: "sheepLabel.save"
        case .deleteLabel: "sheepLabel.delete"
        case .editLabels: "sheepLabels.edit"
        case .patchProfile: "sheepLabels.patchProfile"
        }
    }
    var capability: FarmCapability {
        switch self {
        case .saveLabel, .deleteLabel: .manageCatalogs
        case .editLabels, .patchProfile: .recordProduction
        }
    }
    var summary: String {
        switch self {
        case .saveLabel(let d): "维护标签：\(d.name)"
        case .deleteLabel: "彻底删除标签"
        case .editLabels: "修改羊只标签"
        case .patchProfile: "修改羊只档案与标签"
        }
    }
    var streamType: String {
        switch self {
        case .saveLabel, .deleteLabel: "sheepLabel"
        case .editLabels, .patchProfile: "sheepLabels"
        }
    }
}

@Model final class SheepLabelRecord {
    var id: UUID
    var farmID: UUID
    var name: String
    var colorRawValue: String
    var note: String
    var sortOrder: Int
    var isActive: Bool
    var revision: Int
    var updatedAt: Date
    init(id: UUID = UUID(), farmID: UUID, name: String = "", colorRawValue: String = "red", note: String = "", sortOrder: Int = 0, isActive: Bool = true, revision: Int = 0, updatedAt: Date = .now) {
        self.id = id; self.farmID = farmID; self.name = name; self.colorRawValue = colorRawValue; self.note = note
        self.sortOrder = sortOrder; self.isActive = isActive; self.revision = revision; self.updatedAt = updatedAt
    }
    var value: SheepLabelValue { .init(id: id, name: name, color: SheepLabelColor(rawValue: colorRawValue) ?? .red, note: note, sortOrder: sortOrder, isActive: isActive, revision: revision) }
}

@Model final class SheepLabelAssignmentRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID
    var labelIDsJSON: String
    var primaryLabelID: UUID?
    var revision: Int
    var updatedAt: Date
    init(id: UUID, farmID: UUID, sheepID: UUID, labelIDsJSON: String = "[]", primaryLabelID: UUID? = nil, revision: Int = 0, updatedAt: Date = .now) {
        self.id = id; self.farmID = farmID; self.sheepID = sheepID; self.labelIDsJSON = labelIDsJSON
        self.primaryLabelID = primaryLabelID; self.revision = revision; self.updatedAt = updatedAt
    }
    var labelIDs: Set<UUID> { Set((try? JSONDecoder().decode([UUID].self, from: Data(labelIDsJSON.utf8))) ?? []) }
}

@Model final class SheepLabelChangeRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID?
    var accountID: UUID
    var title: String
    var detail: String
    var snapshotsJSON: String
    var occurredAt: Date
    init(id: UUID = UUID(), farmID: UUID, sheepID: UUID? = nil, accountID: UUID, title: String = "", detail: String = "", snapshotsJSON: String = "[]", occurredAt: Date = .now) {
        self.id = id; self.farmID = farmID; self.sheepID = sheepID; self.accountID = accountID
        self.title = title; self.detail = detail; self.snapshotsJSON = snapshotsJSON; self.occurredAt = occurredAt
    }
}

enum SheepLabelError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

enum SheepLabelRules {
    static func ordered(_ labels: [SheepLabelValue], primaryID: UUID? = nil) -> [SheepLabelValue] {
        labels.sorted {
            if ($0.id == primaryID) != ($1.id == primaryID) { return $0.id == primaryID }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    static func primary(_ preferred: UUID?, ids: Set<UUID>, labels: [SheepLabelValue]) -> UUID? {
        let active = labels.filter { ids.contains($0.id) && $0.isActive }
        return active.contains { $0.id == preferred } ? preferred : ordered(active).first?.id
    }
    static func matches(ids: Set<UUID>, selected: Set<UUID>, all: Bool, unlabelled: Bool) -> Bool {
        if unlabelled { return ids.isEmpty }
        return selected.isEmpty || (all ? selected.isSubset(of: ids) : !ids.isDisjoint(with: selected))
    }
    static func validateEdit(_ draft: SheepLabelsEditDraft, sex: SheepSex, ids: Set<UUID>, labels: [SheepLabelValue]) throws -> Set<UUID> {
        guard Set(draft.addIDs).isDisjoint(with: draft.removeIDs) else { throw SheepLabelError.invalid("同一标签不能同时添加和移除。") }
        let byID = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
        for id in draft.addIDs {
            guard let label = byID[id] else { throw SheepLabelError.invalid("标签不存在或不属于当前牧场。") }
            guard label.isActive, label.color.allows(sex) else { throw SheepLabelError.invalid("\(label.name)：\(label.isActive ? label.color.restriction : "已停用")。") }
        }
        let result = ids.subtracting(draft.removeIDs).union(draft.addIDs)
        if draft.setsPrimary, let primary = draft.primaryLabelID {
            guard result.contains(primary), let label = byID[primary], label.isActive, label.color.allows(sex) else { throw SheepLabelError.invalid("主标签必须是已关联且适用于该羊的启用标签。") }
        }
        return result
    }
}
