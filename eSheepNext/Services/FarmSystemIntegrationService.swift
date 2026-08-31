import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

struct FarmSpotlightSheep: Identifiable, Sendable, Equatable {
    let id: UUID
    let earTag: String
}

struct FarmSpotlightPen: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
}

struct FarmSpotlightSnapshot: Sendable {
    let farmID: UUID
    let farmName: String
    let sheep: [FarmSpotlightSheep]
    let pens: [FarmSpotlightPen]
    let events: [FarmEventSnapshot]
}

enum FarmSystemNavigationKind: String, Codable, Sendable {
    case home
    case searchSheep
    case openPen
    case recordWeight
    case recordFeed
    case openCareReminder
    case openOperationalAlerts
}

struct FarmSystemNavigationTarget: Codable, Sendable, Equatable {
    let farmID: UUID
    let kind: FarmSystemNavigationKind
    let entityID: UUID?
    let query: String?
}

enum FarmSystemNavigationStore {
    private static let key = "pending-farm-system-navigation"

    static func enqueue(_ target: FarmSystemNavigationTarget) {
        if let data = try? JSONEncoder().encode(target) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func consume() -> FarmSystemNavigationTarget? {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FarmSystemNavigationTarget.self, from: data)
    }
}

enum FarmSystemIntegrationService {
    static func makeSnapshot(
        farms: [FarmRecord],
        sheep: [SheepRecord],
        pens: [PenRecord],
        feeds: [FeedRecord],
        pendingOperationCounts: [UUID: Int],
        selectedFarmID: UUID?
    ) -> FarmWidgetSnapshot {
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let farmSnapshots = farms.filter { $0.deletedAt == nil }.map { farm in
            let occupiedPens = CurrentFarmOccupancy.occupiedPens(farmID: farm.id, sheep: sheep, pens: pens)
            return FarmWidgetSnapshot.Farm(
                farmID: farm.id,
                name: farm.name,
                activeSheepCount: sheep.count { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent },
                activePenCount: occupiedPens.count,
                todayFeedCount: feeds.count { $0.farmID == farm.id && $0.deletedAt == nil && $0.occurredAt >= startOfToday },
                pendingOperationCount: pendingOperationCounts[farm.id, default: 0],
                sheep: sheep.filter {
                    $0.farmID == farm.id && $0.deletedAt == nil
                }.map {
                    .init(farmID: farm.id, sheepID: $0.id, earTag: $0.earTag, breed: $0.breed)
                },
                pens: occupiedPens.map {
                    .init(farmID: farm.id, penID: $0.id, name: $0.name)
                }
            )
        }
        return FarmWidgetSnapshot(
            version: FarmWidgetSnapshot.currentVersion,
            generatedAt: .now,
            selectedFarmID: selectedFarmID,
            farms: farmSnapshots
        )
    }

    static func publish(_ snapshot: FarmWidgetSnapshot) async {
        try? FarmWidgetSnapshotStore.save(snapshot)
    }

    static func refreshSearchIndex(_ snapshot: FarmSpotlightSnapshot?) async {
        // Core Spotlight is a persistent, bundle-scoped local index. Removing
        // CloudKit or replacing the widget snapshot does not remove entries
        // whose old domain identifier is no longer known to this build. Reset
        // the app's index before rebuilding so a retired/local-only farm can
        // never remain visible through an orphaned domain.
        do {
            let index = CSSearchableIndex.default()
            try await index.deleteAllSearchableItems()
            let items = searchableItems(in: snapshot)
            for batch in items.chunked(maximumCount: 500) {
                try Task.checkCancellation()
                try await index.indexSearchableItems(batch)
            }
        } catch {
            #if DEBUG
            print("[CoreSpotlight] Rebuild failed: \(error)")
            #endif
        }
    }

    static func searchableItems(in snapshot: FarmSpotlightSnapshot?) -> [CSSearchableItem] {
        guard let snapshot else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = .current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let sheepByID = Dictionary(uniqueKeysWithValues: snapshot.sheep.map { ($0.id, $0) })
        let associationFieldLabels: Set<String> = [
            "对象",
            "母羊",
            "公羊",
            "母本",
            "父本来源",
            "冻精供体",
            "羊只档案ID",
        ]
        var eventsBySheepID: [UUID: [FarmEventSnapshot]] = [:]
        for event in snapshot.events {
            for sheepID in event.relatedSheepIDs where sheepByID[sheepID] != nil {
                eventsBySheepID[sheepID, default: []].append(event)
            }
        }

        var eventItems: [CSSearchableItem] = []
        for sheep in snapshot.sheep.sorted(by: spotlightSheepSort) {
            let events = (eventsBySheepID[sheep.id] ?? []).sorted(by: spotlightEventSort)
            eventItems.reserveCapacity(eventItems.count + events.count)
            for (eventIndex, event) in events.enumerated() {
                let dateText = formatter.string(from: event.occurredAt)
                let otherRelatedEarTags = Set(event.relatedSheepIDs.compactMap { relatedID -> String? in
                    guard relatedID != sheep.id else { return nil }
                    return sheepByID[relatedID]?.earTag
                })
                let trimmedDetail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                let searchableDetail = otherRelatedEarTags.contains(trimmedDetail) ? "" : event.detail
                let searchableFields = event.fields.filter {
                    !associationFieldLabels.contains($0.label)
                }
                let summaryParts = [dateText, searchableDetail, event.note].nonEmptyUniqueValues
                let summary = summaryParts.joined(separator: " · ")
                let title = "\(sheep.earTag) · \(event.title)"
                let fieldLines = searchableFields.compactMap { field -> String? in
                    let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : "\(field.label)：\(value)"
                }
                let attributes = CSSearchableItemAttributeSet(contentType: .item)
                attributes.title = title
                attributes.displayName = title
                attributes.alternateNames = [sheep.earTag]
                attributes.contentDescription = summary
                attributes.subject = "\(snapshot.farmName) · \(event.category.displayName)"
                attributes.kind = "羊只历史事件"
                attributes.containerTitle = snapshot.farmName
                attributes.containerDisplayName = snapshot.farmName
                attributes.textContent = (
                    [
                        "牧场：\(snapshot.farmName)",
                        "耳号：\(sheep.earTag)",
                        "事件：\(event.title)",
                        "发生时间：\(dateText)",
                        searchableDetail.isEmpty ? "" : "内容：\(searchableDetail)",
                        event.note.isEmpty ? "" : "备注：\(event.note)",
                    ] + fieldLines
                ).nonEmptyUniqueValues.joined(separator: "\n")
                attributes.keywords = (
                    [
                        snapshot.farmName,
                        sheep.earTag,
                        event.title,
                        event.category.displayName,
                        searchableDetail,
                        event.note,
                    ] + searchableFields.flatMap { [$0.label, $0.value] }
                ).nonEmptyUniqueValues
                attributes.contentCreationDate = event.occurredAt
                attributes.contentModificationDate = event.recordedAt
                attributes.metadataModificationDate = event.recordedAt
                attributes.userOwned = true
                attributes.rankingHint = NSNumber(value: max(1, 100 - eventIndex))
                attributes.contentURL = deepLink(
                    farmID: snapshot.farmID,
                    kind: "sheep",
                    entityID: sheep.id,
                    query: sheep.earTag
                )
                eventItems.append(CSSearchableItem(
                    uniqueIdentifier: [
                        "farm",
                        snapshot.farmID.uuidString.lowercased(),
                        "sheep",
                        sheep.id.uuidString.lowercased(),
                        "event",
                        event.entityType.rawValue,
                        event.id.uuidString.lowercased(),
                    ].joined(separator: ":"),
                    domainIdentifier: spotlightDomain(farmID: snapshot.farmID),
                    attributeSet: attributes
                ))
            }
        }

        let penItems = snapshot.pens.map { item in
            let title = "\(item.name) · 圈舍"
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = title
            attributes.displayName = title
            attributes.alternateNames = [item.name]
            attributes.contentDescription = snapshot.farmName
            attributes.subject = "\(snapshot.farmName) · 圈舍"
            attributes.kind = "圈舍"
            attributes.containerTitle = snapshot.farmName
            attributes.containerDisplayName = snapshot.farmName
            attributes.textContent = "牧场：\(snapshot.farmName)\n圈舍：\(item.name)"
            attributes.keywords = [snapshot.farmName, item.name, "圈舍"]
            attributes.userOwned = true
            attributes.rankingHint = 20
            attributes.contentURL = deepLink(farmID: snapshot.farmID, kind: "pen", entityID: item.id, query: item.name)
            return CSSearchableItem(
                uniqueIdentifier: "farm:\(snapshot.farmID.uuidString.lowercased()):pen:\(item.id.uuidString.lowercased())",
                domainIdentifier: spotlightDomain(farmID: snapshot.farmID),
                attributeSet: attributes
            )
        }
        return eventItems + penItems
    }

    private static func spotlightSheepSort(_ lhs: FarmSpotlightSheep, _ rhs: FarmSpotlightSheep) -> Bool {
        let comparison = lhs.earTag.localizedStandardCompare(rhs.earTag)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func spotlightEventSort(_ lhs: FarmEventSnapshot, _ rhs: FarmEventSnapshot) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
        if lhs.entityType != rhs.entityType { return lhs.entityType.rawValue < rhs.entityType.rawValue }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    static func target(from url: URL) -> FarmSystemNavigationTarget? {
        guard url.scheme == "esheep", url.host == "farm" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2, let farmID = UUID(uuidString: components[0]) else { return nil }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let query = queryItems?.first(where: { $0.name == "q" })?.value
        switch components[1] {
        case "home":
            return .init(farmID: farmID, kind: .home, entityID: nil, query: nil)
        case "sheep":
            guard components.count >= 3 else { return nil }
            return .init(farmID: farmID, kind: .searchSheep, entityID: UUID(uuidString: components[2]), query: query)
        case "pen":
            guard components.count >= 3 else { return nil }
            return .init(farmID: farmID, kind: .openPen, entityID: UUID(uuidString: components[2]), query: query)
        default:
            return nil
        }
    }

    private static func spotlightDomain(farmID: UUID) -> String {
        "farm.\(farmID.uuidString.lowercased())"
    }

    private static func deepLink(farmID: UUID, kind: String, entityID: UUID, query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "esheep"
        components.host = "farm"
        components.path = "/\(farmID.uuidString.lowercased())/\(kind)/\(entityID.uuidString.lowercased())"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

private extension Array where Element == String {
    var nonEmptyUniqueValues: [String] {
        var seen: Set<String> = []
        return compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0, !isEmpty else { return [] }
        return stride(from: startIndex, to: endIndex, by: maximumCount).map { start in
            let end = index(start, offsetBy: maximumCount, limitedBy: endIndex) ?? endIndex
            return Array(self[start..<end])
        }
    }
}

actor FarmSystemSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func makeSnapshot(
        farmIDs: [UUID],
        selectedFarmID: UUID?
    ) throws -> FarmWidgetSnapshot {
        let context = ModelContext(container)
        var farmSnapshots: [FarmWidgetSnapshot.Farm] = []

        for farmID in farmIDs {
            guard let farm = try context.fetch(FetchDescriptor<FarmRecord>(
                predicate: #Predicate {
                    $0.id == farmID && $0.deletedAt == nil
                }
            )).first else { continue }
            let sheep = try context.fetch(FetchDescriptor<SheepRecord>(
                predicate: #Predicate {
                    $0.farmID == farmID && $0.deletedAt == nil
                }
            ))
            let pens = try context.fetch(FetchDescriptor<PenRecord>(
                predicate: #Predicate {
                    $0.farmID == farmID && $0.deletedAt == nil
                }
            ))
            let feeds = try context.fetch(FetchDescriptor<FeedRecord>(
                predicate: #Predicate {
                    $0.farmID == farmID && $0.deletedAt == nil
                }
            ))
            let pending = OutboxStatus.pending.rawValue
            let retryable = OutboxStatus.retryableFailure.rawValue
            let pendingOperationCount = try context.fetchCount(FetchDescriptor<OutboxItem>(
                predicate: #Predicate {
                    $0.farmID == farmID &&
                        ($0.statusRawValue == pending || $0.statusRawValue == retryable)
                }
            ))
            let partial = FarmSystemIntegrationService.makeSnapshot(
                farms: [farm],
                sheep: sheep,
                pens: pens,
                feeds: feeds,
                pendingOperationCounts: [farmID: pendingOperationCount],
                selectedFarmID: selectedFarmID
            )
            farmSnapshots.append(contentsOf: partial.farms)
        }

        return FarmWidgetSnapshot(
            version: FarmWidgetSnapshot.currentVersion,
            generatedAt: .now,
            selectedFarmID: selectedFarmID,
            farms: farmSnapshots
        )
    }
}

actor FarmSpotlightSnapshotActor {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func makeSnapshot(farmID: UUID?) async throws -> FarmSpotlightSnapshot? {
        guard let farmID else { return nil }
        let events = try await FarmEventHistoryActor(container: container).load(farmID: farmID)
        try Task.checkCancellation()

        let context = ModelContext(container)
        guard let farm = try context.fetch(FetchDescriptor<FarmRecord>(
            predicate: #Predicate {
                $0.id == farmID && $0.deletedAt == nil
            }
        )).first else { return nil }
        let sheepRecords = try context.fetch(FetchDescriptor<SheepRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }
        )).filter { !$0.isHistoricalArchive }
        let penRecords = try context.fetch(FetchDescriptor<PenRecord>(
            predicate: #Predicate {
                $0.farmID == farmID && $0.deletedAt == nil
            }
        ))
        let occupiedPens = CurrentFarmOccupancy.occupiedPens(
            farmID: farmID,
            sheep: sheepRecords,
            pens: penRecords
        )

        return FarmSpotlightSnapshot(
            farmID: farm.id,
            farmName: farm.name,
            sheep: sheepRecords.map {
                FarmSpotlightSheep(id: $0.id, earTag: $0.earTag)
            },
            pens: occupiedPens.map {
                FarmSpotlightPen(id: $0.id, name: $0.name)
            },
            events: events
        )
    }
}
