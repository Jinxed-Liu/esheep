import Foundation
import WidgetKit

struct FarmWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Farm: Codable, Equatable, Sendable, Identifiable {
        let farmID: UUID
        let name: String
        let activeSheepCount: Int
        let activePenCount: Int
        let todayFeedCount: Int
        let pendingOperationCount: Int
        let sheep: [Sheep]
        let pens: [Pen]
        var cards: [FarmWidgetCard]? = nil
        var widgetScopes: [ScopeOption]? = nil
        var timeZoneIdentifier: String? = nil

        var id: UUID { farmID }
    }

    struct ScopeOption: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let name: String
        let kind: FarmWidgetScope
    }

    struct Sheep: Codable, Equatable, Sendable, Identifiable {
        let farmID: UUID
        let sheepID: UUID
        let earTag: String
        let breed: String

        var id: String { "\(farmID.uuidString.lowercased()):\(sheepID.uuidString.lowercased())" }
    }

    struct Pen: Codable, Equatable, Sendable, Identifiable {
        let farmID: UUID
        let penID: UUID
        let name: String

        var id: String { "\(farmID.uuidString.lowercased()):\(penID.uuidString.lowercased())" }
    }

    let version: Int
    let generatedAt: Date
    let selectedFarmID: UUID?
    let farms: [Farm]

    static let empty = FarmWidgetSnapshot(version: currentVersion, generatedAt: .distantPast, selectedFarmID: nil, farms: [])
}

enum AppGroupConfiguration {
    static var identifier: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum FarmWidgetSnapshotStore {
    static let changeNotification = Notification.Name("FarmWidgetSnapshotDidChange")
    private static let key = "farm-widget-snapshot-v1"

    static func load() -> FarmWidgetSnapshot {
        guard let defaults = sharedDefaults(),
              let data = defaults.data(forKey: key),
              let snapshot = try? decoder.decode(FarmWidgetSnapshot.self, from: data),
              snapshot.version == FarmWidgetSnapshot.currentVersion else {
            return .empty
        }
        return snapshot
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func save(_ snapshot: FarmWidgetSnapshot) throws {
        guard let defaults = sharedDefaults() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(snapshot), forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: changeNotification, object: nil)
    }

    private static func sharedDefaults() -> UserDefaults? {
        AppGroupConfiguration.identifier.flatMap(UserDefaults.init(suiteName:))
    }
}
