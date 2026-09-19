import Foundation
import SwiftData

enum SheepLabelService {
    static func labels(farmID: UUID, context: ModelContext) throws -> [SheepLabelValue] {
        try context.fetch(FetchDescriptor<SheepLabelRecord>(predicate: #Predicate { $0.farmID == farmID })).map(\.value)
    }
    static func assignment(sheepID: UUID, farmID: UUID, context: ModelContext) throws -> SheepLabelAssignmentRecord? {
        try context.fetch(FetchDescriptor<SheepLabelAssignmentRecord>(predicate: #Predicate { $0.farmID == farmID && $0.sheepID == sheepID })).first
    }
    static func conflicts(sheepID: UUID, sex: SheepSex, farmID: UUID, context: ModelContext) throws -> [SheepLabelValue] {
        let ids = try assignment(sheepID: sheepID, farmID: farmID, context: context)?.labelIDs ?? []
        return try labels(farmID: farmID, context: context).filter { ids.contains($0.id) && !$0.color.allows(sex) }
    }
    static func assertSex(sheepID: UUID, sex: SheepSex, farmID: UUID, context: ModelContext) throws {
        let invalid = try conflicts(sheepID: sheepID, sex: sex, farmID: farmID, context: context)
        guard invalid.isEmpty else { throw SheepLabelError.invalid("请先确认移除与新性别冲突的标签：\(invalid.map(\.name).joined(separator: "、"))。") }
    }
    static func alreadyApplied(_ command: SheepLabelCommand, farmID: UUID, context: ModelContext) throws -> Bool {
        let id = command.changeID
        return try context.fetch(FetchDescriptor<SheepLabelChangeRecord>(predicate: #Predicate { $0.farmID == farmID && $0.id == id })).first != nil
    }
    static func validate(_ command: SheepLabelCommand, farmID: UUID, context: ModelContext, enforceRevision: Bool = true) throws {
        let catalog = try labels(farmID: farmID, context: context)
        switch command {
        case .saveLabel(let d):
            guard !d.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, d.name.trimmingCharacters(in: .whitespacesAndNewlines).count <= 40, d.note.count <= 500, d.sortOrder >= 0 else { throw SheepLabelError.invalid("标签名称需为 1–40 字，说明最多 500 字，排序不能为负数。") }
            guard !catalog.contains(where: { $0.id != d.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == d.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) else { throw SheepLabelError.invalid("当前牧场已有同名标签。") }
            if enforceRevision, (catalog.first { $0.id == d.id }?.revision ?? 0) != d.expectedRevision { throw SheepLabelError.invalid("标签已由其他成员修改，请刷新后重试。") }
            let assignments = try context.fetch(FetchDescriptor<SheepLabelAssignmentRecord>(predicate: #Predicate { $0.farmID == farmID }))
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.farmID == farmID }))
            let ids = Set(assignments.filter { $0.labelIDs.contains(d.id) }.map(\.sheepID))
            let invalid = sheep.filter { ids.contains($0.id) && !d.color.allows($0.sex) }
            guard invalid.isEmpty else { throw SheepLabelError.invalid("该颜色与 \(invalid.count) 只羊冲突：\(invalid.prefix(10).map(\.earTag).joined(separator: "、"))。请先移除关联标签。") }
        case .editLabels(let d):
            let sheep = try subject(d.sheepID, farmID: farmID, context: context)
            let a = try assignment(sheepID: d.sheepID, farmID: farmID, context: context)
            if enforceRevision, d.setsPrimary, let expected = d.expectedRevision, expected != (a?.revision ?? 0) { throw SheepLabelError.invalid("主标签已发生变化，请刷新后重试。") }
            _ = try SheepLabelRules.validateEdit(d, sex: sheep.sex, ids: a?.labelIDs ?? [], labels: catalog)
        case .patchProfile(let d):
            let sheep = try subject(d.sheepID, farmID: farmID, context: context)
            if enforceRevision, sheep.revision != d.expectedRevision { throw SheepLabelError.invalid("羊只档案已发生变化，请刷新后重试。") }
            guard !d.earTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !d.breed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SheepLabelError.invalid("请填写耳号和品种。") }
            guard d.currentParity == nil || (d.sex == .ewe && d.currentParity! >= 0 && d.parityRecordedAt != nil) else { throw SheepLabelError.invalid("当前胎次必须为母羊的非负整数，并包含确认时间。") }
            let others = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.farmID == farmID }))
            guard !others.contains(where: { $0.id != d.sheepID && EarTag.normalized($0.earTag) == EarTag.normalized(d.earTag) }) else { throw FarmCommandError.duplicateEarTag }
            let a = try assignment(sheepID: d.sheepID, farmID: farmID, context: context)
            let remaining = (a?.labelIDs ?? []).subtracting(d.removeLabelIDs)
            guard !catalog.contains(where: { remaining.contains($0.id) && !$0.color.allows(d.sex) }) else { throw SheepLabelError.invalid("必须明确移除所有与新性别冲突的标签。") }
        }
    }
    @discardableResult static func apply(_ command: SheepLabelCommand, farmID: UUID, accountID: UUID, at: Date, context: ModelContext) throws -> CareApplyResult {
        if try alreadyApplied(command, farmID: farmID, context: context) {
            return .init(entityType: command.streamType == "sheepLabel" ? .sheepLabel : .sheepLabels, entityID: command.primaryID, baseRevision: 0, resultingRevision: 1)
        }
        let before = try labels(farmID: farmID, context: context)
        var detail = ""
        var sheepID: UUID?
        var revision = 1
        switch command {
        case .saveLabel(let d):
            let id = d.id
            let existing = try context.fetch(FetchDescriptor<SheepLabelRecord>(predicate: #Predicate { $0.farmID == farmID && $0.id == id })).first
            let record = existing ?? SheepLabelRecord(id: id, farmID: farmID)
            if existing == nil { context.insert(record) }
            let old = record.value
            record.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines); record.colorRawValue = d.color.rawValue; record.note = d.note.trimmingCharacters(in: .whitespacesAndNewlines)
            record.sortOrder = d.sortOrder; record.isActive = d.isActive; record.revision += 1; record.updatedAt = at
            revision = record.revision
            detail = "\(old.revision == 0 ? "新建" : "更新") \(record.name) · \(d.color.title) · \(d.isActive ? "启用" : "停用")"
            let updated = try labels(farmID: farmID, context: context)
            for a in try context.fetch(FetchDescriptor<SheepLabelAssignmentRecord>(predicate: #Predicate { $0.farmID == farmID })) where a.labelIDs.contains(id) {
                let next = SheepLabelRules.primary(a.primaryLabelID, ids: a.labelIDs, labels: updated)
                if next != a.primaryLabelID { a.primaryLabelID = next; a.revision += 1; a.updatedAt = at }
            }
        case .editLabels(let d):
            sheepID = d.sheepID
            let sheep = try subject(d.sheepID, farmID: farmID, context: context)
            let a = try ensureAssignment(sheepID: d.sheepID, farmID: farmID, context: context)
            let ids = a.labelIDs.subtracting(d.removeIDs).union(d.addIDs)
            a.labelIDsJSON = try encode(ids.sorted { $0.uuidString < $1.uuidString })
            a.primaryLabelID = SheepLabelRules.primary(d.setsPrimary ? d.primaryLabelID : a.primaryLabelID, ids: ids, labels: before)
            a.revision += 1; a.updatedAt = at; revision = a.revision
            let names: ([UUID]) -> String = { values in before.filter { values.contains($0.id) }.map { "\($0.name)（\($0.color.title)）" }.joined(separator: "、") }
            detail = "\(sheep.earTag) · 添加：\(names(d.addIDs))；移除：\(names(d.removeIDs))"
            if d.setsPrimary { detail += "；主标签：\(before.first { $0.id == a.primaryLabelID }?.name ?? "无")" }
        case .patchProfile(let d):
            sheepID = d.sheepID
            let sheep = try subject(d.sheepID, farmID: farmID, context: context)
            let oldSex = sheep.sex.displayName
            let a = try ensureAssignment(sheepID: d.sheepID, farmID: farmID, context: context)
            let ids = a.labelIDs.subtracting(d.removeLabelIDs)
            a.labelIDsJSON = try encode(ids.sorted { $0.uuidString < $1.uuidString })
            a.primaryLabelID = SheepLabelRules.primary(a.primaryLabelID, ids: ids, labels: before)
            a.revision += 1; a.updatedAt = at
            sheep.earTag = d.earTag.trimmingCharacters(in: .whitespacesAndNewlines); sheep.breed = d.breed.trimmingCharacters(in: .whitespacesAndNewlines); sheep.sexRawValue = d.sex.rawValue
            if d.sex != .ram { sheep.isBreedingRam = false }
            sheep.birthAt = d.birthAt; sheep.note = d.note.trimmingCharacters(in: .whitespacesAndNewlines); sheep.revision += 1; sheep.updatedAt = at
            if let parity = d.currentParity, let recordedAt = d.parityRecordedAt {
                context.insert(ReproductionRecord(id: LambingEntrySemantics.parityCorrectionID(sheepID: sheep.id, sheepRevision: sheep.revision), farmID: farmID, eweID: sheep.id, kind: .parityBaseline, occurredAt: recordedAt, parity: parity, note: "档案确认当前胎次"))
            }
            revision = a.revision
            detail = "\(sheep.earTag) · \(oldSex) → \(d.sex.displayName)；移除：\(before.filter { d.removeLabelIDs.contains($0.id) }.map(\.name).joined(separator: "、"))"
        }
        context.insert(SheepLabelChangeRecord(id: command.changeID, farmID: farmID, sheepID: sheepID, accountID: accountID, title: command.summary, detail: detail, snapshotsJSON: try encode(["before": before, "after": try labels(farmID: farmID, context: context)]), occurredAt: at))
        return .init(entityType: command.streamType == "sheepLabel" ? .sheepLabel : .sheepLabels, entityID: command.primaryID, baseRevision: max(0, revision - 1), resultingRevision: revision)
    }
    static func subject(_ id: UUID, farmID: UUID, context: ModelContext) throws -> SheepRecord {
        guard let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.farmID == farmID && $0.id == id && $0.deletedAt == nil })).first else { throw FarmCommandError.sheepNotFound }
        return sheep
    }
    private static func ensureAssignment(sheepID: UUID, farmID: UUID, context: ModelContext) throws -> SheepLabelAssignmentRecord {
        if let a = try assignment(sheepID: sheepID, farmID: farmID, context: context) { return a }
        let a = SheepLabelAssignmentRecord(id: sheepID, farmID: farmID, sheepID: sheepID); context.insert(a); return a
    }
    static func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
}
