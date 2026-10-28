import Foundation
import SwiftData

struct LambingChildSnapshot: Identifiable, Sendable {
    let id: UUID
    let sheepID: UUID?
    let earTag: String
    let recordedEarTag: String
    let sex: String
    let isStillborn: Bool
    let birthWeight: String?
    let laterWeight: String?
    let weighedAt: Date?
    let currentState: String
    let currentPen: String?
    let removedAt: Date?
}

struct LambingDetailSnapshot: Sendable {
    let children: [LambingChildSnapshot]
    let missingCount: Int
    let countMismatch: Bool
    let readAt: Date
}

/// Fetch only the selected event's explicit offspring links. Never infer a
/// litter from dam ID/date, and never scan the herd on the navigation actor.
actor LambingDetailSnapshotActor {
    let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func load(farmID: UUID, recordID: UUID) throws -> LambingDetailSnapshot? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let event = try context.fetch(FetchDescriptor<ReproductionRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.id == recordID
        })).first, event.kind == .lambing else { return nil }
        let links = try context.fetch(FetchDescriptor<LambingOffspringRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.lambingRecordID == recordID
        })).filter { $0.deletedAt == nil || (event.deletedAt != nil && $0.deletedByLambingRevocation) }
        var rows: [LambingChildSnapshot] = []
        for link in links.sorted(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            try Task.checkCancellation()
            var child: SheepRecord?
            if let childID = link.sheepID {
                child = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.id == childID
                })).first
            }
            var penName: String?
            var removedAt: Date?
            var state = link.sheepID == nil ? "未建档" : "关联档案暂不可用"
            if let child {
                if child.deletedAt != nil { state = "档案已删除" }
                else if child.isCurrentlyPresent {
                    state = "在场"
                    if let penID = child.currentPenID {
                        penName = try context.fetch(FetchDescriptor<PenRecord>(predicate: #Predicate {
                            $0.farmID == farmID && $0.id == penID
                        })).first?.name
                    }
                    penName = penName ?? "未分圈"
                } else {
                    state = child.isHistoricalArchive ? "历史归档" : child.status.displayName
                    removedAt = child.removedAt
                    let childID = child.id
                    var descriptor = FetchDescriptor<RemovalRecord>(predicate: #Predicate {
                        $0.farmID == farmID && $0.sheepID == childID && $0.deletedAt == nil
                    }, sortBy: [SortDescriptor(\.occurredAt, order: .reverse)])
                    descriptor.fetchLimit = 1
                    if let removal = try context.fetch(descriptor).first,
                       !child.isHistoricalArchive, removal.kind.resultingStatus == child.status {
                        state = removal.kind.displayName
                        removedAt = removal.occurredAt
                    }
                }
            }
            var birthWeight = Decimal.stable(link.birthWeightText).flatMap { $0 > 0 ? $0.stableText : nil }
            var laterWeight: String?
            var weighedAt: Date?
            if let weightID = link.autoBirthWeightRecordID {
                // An explicitly linked but removed weight must not reappear via
                // its historical text fallback.
                birthWeight = nil
                if let weight = try context.fetch(FetchDescriptor<WeightRecord>(predicate: #Predicate {
                    $0.farmID == farmID && $0.id == weightID && $0.deletedAt == nil
                })).first, weight.sheepID == link.sheepID,
                   let value = Decimal.stable(weight.kilogramsText), value > 0 {
                    weighedAt = weight.occurredAt
                    if LambingEntrySemantics.weightKind(lambingAt: event.occurredAt, weighedAt: weight.occurredAt) == .birth {
                        birthWeight = value.stableText
                    } else { laterWeight = value.stableText }
                }
            }
            let recorded = link.legacyEarTag.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = child?.earTag.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sex = SheepSex(rawValue: link.sexRawValue)?.displayName
                ?? LambSex(rawValue: link.sexRawValue)?.displayName ?? "未知"
            rows.append(.init(id: link.id,
                sheepID: child?.deletedAt == nil && !link.isStillborn ? child?.id : nil,
                earTag: current.isEmpty ? (recorded.isEmpty ? "未编号羔羊" : recorded) : current,
                recordedEarTag: recorded, sex: sex, isStillborn: link.isStillborn,
                birthWeight: birthWeight, laterWeight: laterWeight, weighedAt: weighedAt,
                currentState: link.isStillborn ? "死胎，未建档" : state,
                currentPen: link.isStillborn ? nil : penName, removedAt: link.isStillborn ? nil : removedAt))
        }
        let stillbornCount = rows.filter(\.isStillborn).count
        let inconsistentOutcomes = event.birthDeadCount.map { dead in
            dead < 0 || dead > event.lambCount || stillbornCount > dead ||
                rows.count - stillbornCount > event.lambCount - dead
        } ?? false
        return .init(children: rows, missingCount: max(0, event.lambCount - rows.count),
                     countMismatch: rows.count > event.lambCount || inconsistentOutcomes, readAt: .now)
    }
}
