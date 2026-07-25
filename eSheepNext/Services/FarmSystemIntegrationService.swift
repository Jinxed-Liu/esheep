import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum FarmSystemNavigationKind: String, Codable, Sendable {
    case home
    case searchSheep
    case openPen
    case recordWeight
    case recordFeed
    case openCareReminder
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
            let occupiedPenCount = CurrentFarmOccupancy.occupiedPens(farmID: farm.id, sheep: sheep, pens: pens).count
            return FarmWidgetSnapshot.Farm(
                farmID: farm.id,
                name: farm.name,
                activeSheepCount: sheep.count { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent },
                activePenCount: occupiedPenCount,
                todayFeedCount: feeds.count { $0.farmID == farm.id && $0.deletedAt == nil && $0.occurredAt >= startOfToday },
                pendingOperationCount: pendingOperationCounts[farm.id, default: 0],
                sheep: sheep.filter {
                    $0.farmID == farm.id && $0.deletedAt == nil
                }.map {
                    .init(farmID: farm.id, sheepID: $0.id, earTag: $0.earTag, breed: $0.breed)
                },
                pens: pens.filter {
                    $0.farmID == farm.id && $0.deletedAt == nil && $0.isActive
                }.map {
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

    @discardableResult
    static func publish(
        _ snapshot: FarmWidgetSnapshot,
        refreshSearchIndex shouldRefreshSearchIndex: Bool = true
    ) async -> [String] {
        let previousDomains = FarmWidgetSnapshotStore.load().farms.map { spotlightDomain(farmID: $0.farmID) }
        try? FarmWidgetSnapshotStore.save(snapshot)
        guard shouldRefreshSearchIndex else { return previousDomains }
        await refreshSearchIndex(snapshot, replacingDomains: previousDomains)
        return previousDomains
    }

    static func refreshSearchIndex(
        _ snapshot: FarmWidgetSnapshot,
        replacingDomains previousDomains: [String]
    ) async {
        let currentDomains = snapshot.farms.map { spotlightDomain(farmID: $0.farmID) }
        try? await CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: Array(Set(previousDomains + currentDomains))
        )
        let items = snapshot.farms.flatMap { farm -> [CSSearchableItem] in
            let sheepItems = farm.sheep.map { item in
                let attributes = CSSearchableItemAttributeSet(contentType: .item)
                attributes.title = item.earTag
                attributes.contentDescription = "\(farm.name) · \(item.breed)"
                attributes.keywords = [farm.name, item.earTag, item.breed]
                attributes.contentURL = deepLink(farmID: farm.farmID, kind: "sheep", entityID: item.sheepID, query: item.earTag)
                return CSSearchableItem(
                    uniqueIdentifier: "farm:\(farm.farmID.uuidString.lowercased()):sheep:\(item.sheepID.uuidString.lowercased())",
                    domainIdentifier: spotlightDomain(farmID: farm.farmID),
                    attributeSet: attributes
                )
            }
            let penItems = farm.pens.map { item in
                let attributes = CSSearchableItemAttributeSet(contentType: .item)
                attributes.title = item.name
                attributes.contentDescription = "\(farm.name) · 圈舍"
                attributes.keywords = [farm.name, item.name, "圈舍"]
                attributes.contentURL = deepLink(farmID: farm.farmID, kind: "pen", entityID: item.penID, query: item.name)
                return CSSearchableItem(
                    uniqueIdentifier: "farm:\(farm.farmID.uuidString.lowercased()):pen:\(item.penID.uuidString.lowercased())",
                    domainIdentifier: spotlightDomain(farmID: farm.farmID),
                    attributeSet: attributes
                )
            }
            return sheepItems + penItems
        }
        if !items.isEmpty { try? await CSSearchableIndex.default().indexSearchableItems(items) }
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
