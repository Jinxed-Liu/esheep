import Foundation
import SwiftData

/// Shared by manual entry, imports and command validation. Existing records are
/// never renamed or merged when these rules are introduced.
enum PenManagementPolicy {
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nameKey(_ name: String) -> String {
        normalizedName(name).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func canManageLifecycle(role: FarmRole) -> Bool {
        role == .owner || role == .administrator
    }

    static func validateName(_ name: String, excluding penID: UUID? = nil,
                             farmID: UUID, context: ModelContext) throws {
        let key = nameKey(name)
        guard !key.isEmpty else { throw FarmCommandError.missingRequiredValue("羊舍名称") }
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        // A legacy duplicate may still have its note edited. Only a new name
        // claims uniqueness; resolving old duplicates remains an explicit edit.
        if let penID, let current = pens.first(where: { $0.id == penID }),
           nameKey(current.name) == key { return }
        guard !pens.contains(where: { $0.id != penID && nameKey($0.name) == key }) else {
            throw PenManagementError.duplicateName(normalizedName(name))
        }
    }

    static func resolve(_ name: String, in pens: [PenRecord]) throws -> PenRecord? {
        let matches = pens.filter { $0.deletedAt == nil && nameKey($0.name) == nameKey(name) }
        guard matches.count <= 1 else { throw PenManagementError.ambiguousName(name) }
        if let pen = matches.first, !pen.isActive { throw PenManagementError.inactiveName(name) }
        return matches.first
    }

    /// Include revoked records: deleting a pen must never orphan recoverable
    /// history. Fetch only one matching row from each business projection.
    static func hasReferences(penID: UUID, farmID: UUID, context: ModelContext) throws -> Bool {
        func exists<T: PersistentModel>(_ predicate: Predicate<T>) throws -> Bool {
            var descriptor = FetchDescriptor<T>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try !context.fetch(descriptor).isEmpty
        }
        if try exists(#Predicate<SheepRecord> { $0.farmID == farmID && ($0.currentPenID == penID || $0.initialPenID == penID) }) { return true }
        if try exists(#Predicate<TransferRecord> { $0.farmID == farmID && ($0.fromPenID == penID || $0.toPenID == penID) }) { return true }
        if try exists(#Predicate<DailyPenCountRecord> { $0.farmID == farmID && $0.penID == penID && $0.count > 0 }) { return true }
        if try exists(#Predicate<FeedRecord> { $0.farmID == farmID && $0.penID == penID }) { return true }
        if try exists(#Predicate<FeedTroughObservationRecord> { $0.farmID == farmID && $0.penID == penID }) { return true }
        if try exists(#Predicate<FeedRecipeRecord> { $0.farmID == farmID && $0.targetPenID == penID }) { return true }
        if try exists(#Predicate<HealthRecord> { $0.farmID == farmID && $0.penID == penID }) { return true }
        if try exists(#Predicate<NoteRecord> { $0.farmID == farmID && $0.penID == penID }) { return true }
        if try exists(#Predicate<TMRFeedingPlanPenRecord> { $0.farmID == farmID && $0.penID == penID }) { return true }
        if try exists(#Predicate<TMRFeedingAllocationRecord> { $0.farmID == farmID && $0.penID == penID }) { return true }
        if try exists(#Predicate<TMRMealCompletionRecord> { $0.farmID == farmID && $0.penID == penID }) { return true }
        if try exists(#Predicate<TMRDeviationAcknowledgementRecord> { $0.farmID == farmID && $0.penID == penID }) { return true }
        // Old corrected facts and not-yet-uploaded commands may no longer have
        // a live projection. Keep their explicit pen references protected too.
        // Bound each fetch so an unused pen does not load the farm's entire
        // immutable command history into memory just to check deletion.
        func anyRow<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, matches: (T) throws -> Bool) throws -> Bool {
            var page = descriptor
            page.fetchLimit = 256
            while true {
                let rows = try context.fetch(page)
                if try rows.contains(where: matches) { return true }
                if rows.count < 256 { return false }
                page.fetchOffset = (page.fetchOffset ?? 0) + rows.count
            }
        }
        if try anyRow(FetchDescriptor<DomainOperation>(predicate: #Predicate { $0.farmID == farmID }), matches: { operation in
            guard operation.entityType != CloudEntityType.pen.rawValue else { return false }
            return try containsReference(in: operation.payload, penID: penID)
        }) { return true }
        return try anyRow(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate { $0.farmID == farmID })) { intent in
            guard !intent.commandKind.hasPrefix("pen.") else { return false }
            return try containsReference(in: intent.commandEnvelopeData, penID: penID)
        }
    }

    private static func containsReference(in data: Data, penID: UUID) throws -> Bool {
        let id = penID.uuidString.lowercased()
        // Avoid decoding unrelated immutable envelopes.
        guard String(data: data, encoding: .utf8)?.lowercased().contains(id) == true else { return false }
        func containsID(_ value: Any) -> Bool {
            if let text = value as? String { return text.lowercased() == id }
            if let array = value as? [Any] { return array.contains(where: containsID) }
            if let object = value as? [String: Any] { return object.values.contains(where: containsID) }
            return false
        }
        func visit(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                if let field = object["field"] as? String,
                   field.lowercased().hasSuffix("penid") || field.lowercased().hasSuffix("penids"),
                   containsID(object["chosen_value"] ?? object["value"] ?? object["mutation"] ?? NSNull()) { return true }
                return object.contains { key, value in
                    let key = key.lowercased()
                    return ((key.hasSuffix("penid") || key.hasSuffix("penids")) && containsID(value)) || visit(value)
                }
            }
            if let array = value as? [Any] { return array.contains(where: visit) }
            return false
        }
        return try visit(JSONSerialization.jsonObject(with: data))
    }
}

enum PenManagementError: LocalizedError {
    case duplicateName(String)
    case ambiguousName(String)
    case inactiveName(String)
    case unconfirmedNewNames

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name): "已有名为“\(name)”的羊舍（包括已停用羊舍），请使用其他名称。"
        case .ambiguousName(let name): "“\(name)”对应多个羊舍，请先在羊舍管理中区分名称后再导入。"
        case .inactiveName(let name): "羊舍“\(name)”已停用，请先重新启用或选择其他羊舍。"
        case .unconfirmedNewNames: "导入包含尚未建立的羊舍，请核对并确认新建羊舍清单。"
        }
    }
}

enum PenDisplayScope: String, CaseIterable, Identifiable, Sendable {
    case all, occupied, empty, inactive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部羊舍"
        case .occupied: "有羊羊舍"
        case .empty: "启用空舍"
        case .inactive: "已停用"
        }
    }
    func includes(_ pen: PenManagementRowSnapshot) -> Bool {
        switch self {
        case .all: true
        case .occupied: pen.currentSheepCount > 0
        case .empty: pen.isActive && pen.currentSheepCount == 0
        case .inactive: !pen.isActive
        }
    }
}
