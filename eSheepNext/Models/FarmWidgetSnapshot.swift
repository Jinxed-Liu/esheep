import Foundation

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

        var id: UUID { farmID }
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
    private static let key = "farm-widget-snapshot-v1"

    static func load() -> FarmWidgetSnapshot {
        guard let defaults = sharedDefaults(),
              let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(FarmWidgetSnapshot.self, from: data),
              snapshot.version == FarmWidgetSnapshot.currentVersion else {
            return .empty
        }
        return snapshot
    }

    static func save(_ snapshot: FarmWidgetSnapshot) throws {
        guard let defaults = sharedDefaults() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(snapshot), forKey: key)
    }

    private static func sharedDefaults() -> UserDefaults? {
        AppGroupConfiguration.identifier.flatMap(UserDefaults.init(suiteName:))
    }
}
