import Foundation
import SwiftData

struct PenManagementRowSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let note: String
    let isActive: Bool
    let currentSheepCount: Int
}

struct PenSheepRowSnapshot: Identifiable, Sendable, Hashable {
    let id: UUID
    let earTag: String
    let purpose: String
}

struct PenDetailSnapshot: Sendable, Hashable {
    let pen: PenManagementRowSnapshot
    let sheep: [PenSheepRowSnapshot]

    var analysisMembers: [PenHerdMemberSnapshot] {
        sheep.map { PenHerdMemberSnapshot(id: $0.id, purpose: $0.purpose) }
    }
}

/// Projects pen screens into immutable values away from the main actor. The
/// views no longer retain every farm sheep as live SwiftData model objects.
actor PenManagementSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func loadList(farmID: UUID) throws -> [PenManagementRowSnapshot] {
        let interval = PerformanceTrace.begin(.penLoad)
        defer { PerformanceTrace.end(interval) }

        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let activeStatus = SheepStatus.active.rawValue
        let pens = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))
        let presentSheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.deletedAt == nil &&
                $0.statusRawValue == activeStatus &&
                $0.isHistoricalArchive == false &&
                $0.currentPenID != nil
        }))
        let countsByPen = presentSheep.reduce(into: [UUID: Int]()) { result, sheep in
            guard let penID = sheep.currentPenID else { return }
            result[penID, default: 0] += 1
        }
        let rows = pens.map {
            PenManagementRowSnapshot(
                id: $0.id,
                name: $0.name,
                note: $0.note,
                isActive: $0.isActive,
                currentSheepCount: countsByPen[$0.id, default: 0]
            )
        }
        .sorted(by: Self.sortPens)
        try Task.checkCancellation()
        return rows
    }

    func loadDetail(farmID: UUID, penID: UUID) throws -> PenDetailSnapshot? {
        let interval = PerformanceTrace.begin(.penLoad)
        defer { PerformanceTrace.end(interval) }

        try Task.checkCancellation()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var penDescriptor = FetchDescriptor<PenRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.id == penID && $0.deletedAt == nil
        })
        penDescriptor.fetchLimit = 1
        guard let pen = try context.fetch(penDescriptor).first else { return nil }

        let activeStatus = SheepStatus.active.rawValue
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
            $0.farmID == farmID &&
                $0.currentPenID == penID &&
                $0.deletedAt == nil &&
                $0.statusRawValue == activeStatus &&
                $0.isHistoricalArchive == false
        }))
        .map { PenSheepRowSnapshot(id: $0.id, earTag: $0.earTag, purpose: $0.purpose) }
        .sorted {
            let comparison = $0.earTag.localizedStandardCompare($1.earTag)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
        try Task.checkCancellation()
        return PenDetailSnapshot(
            pen: PenManagementRowSnapshot(
                id: pen.id,
                name: pen.name,
                note: pen.note,
                isActive: pen.isActive,
                currentSheepCount: sheep.count
            ),
            sheep: sheep
        )
    }

    private static func sortPens(
        _ lhs: PenManagementRowSnapshot,
        _ rhs: PenManagementRowSnapshot
    ) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : comparison == .orderedAscending
    }
}
