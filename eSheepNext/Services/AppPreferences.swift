import Foundation
import Observation
import SwiftUI

enum AppAppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .simplifiedChinese: "简体中文"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .simplifiedChinese: Locale(identifier: "zh-Hans-CN")
        }
    }
}

enum AppPreferenceStorage {
    static let appearanceKey = "settings.appearance"
    static let languageKey = "settings.language"
    static let powerSavingKey = "settings.power-saving"
    static let backgroundRefreshKey = "settings.background-refresh"
    static let reduceMotionKey = "settings.reduce-motion"
    static let avatarMotionKey = "settings.avatar-motion"

    static func bool(
        forKey key: String,
        default defaultValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    static var isBackgroundRefreshEnabled: Bool {
        bool(forKey: backgroundRefreshKey, default: true)
    }
}

@MainActor
@Observable
final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    var appearance: AppAppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: AppPreferenceStorage.appearanceKey) }
    }

    var language: AppLanguagePreference {
        didSet { defaults.set(language.rawValue, forKey: AppPreferenceStorage.languageKey) }
    }

    var powerSavingEnabled: Bool {
        didSet { defaults.set(powerSavingEnabled, forKey: AppPreferenceStorage.powerSavingKey) }
    }

    var backgroundRefreshEnabled: Bool {
        didSet { defaults.set(backgroundRefreshEnabled, forKey: AppPreferenceStorage.backgroundRefreshKey) }
    }

    var reduceMotionEnabled: Bool {
        didSet { defaults.set(reduceMotionEnabled, forKey: AppPreferenceStorage.reduceMotionKey) }
    }

    var avatarMotionEnabled: Bool {
        didSet { defaults.set(avatarMotionEnabled, forKey: AppPreferenceStorage.avatarMotionKey) }
    }

    private(set) var systemLowPowerModeEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults
            .string(forKey: AppPreferenceStorage.appearanceKey)
            .flatMap(AppAppearancePreference.init(rawValue:)) ?? .system
        language = defaults
            .string(forKey: AppPreferenceStorage.languageKey)
            .flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
        powerSavingEnabled = AppPreferenceStorage.bool(
            forKey: AppPreferenceStorage.powerSavingKey,
            default: false,
            defaults: defaults
        )
        backgroundRefreshEnabled = AppPreferenceStorage.bool(
            forKey: AppPreferenceStorage.backgroundRefreshKey,
            default: true,
            defaults: defaults
        )
        reduceMotionEnabled = AppPreferenceStorage.bool(
            forKey: AppPreferenceStorage.reduceMotionKey,
            default: false,
            defaults: defaults
        )
        avatarMotionEnabled = AppPreferenceStorage.bool(
            forKey: AppPreferenceStorage.avatarMotionKey,
            default: true,
            defaults: defaults
        )
        systemLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var effectivePowerSavingEnabled: Bool {
        powerSavingEnabled || systemLowPowerModeEnabled
    }

    var shouldReduceMotion: Bool {
        reduceMotionEnabled || effectivePowerSavingEnabled
    }

    var avatarSyncInterval: Duration {
        effectivePowerSavingEnabled ? .seconds(60) : .seconds(8)
    }

    func refreshSystemPowerState() {
        systemLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

struct AppStorageSnapshot: Equatable, Sendable {
    let protectedDataBytes: Int64
    let documentBytes: Int64
    let temporaryBytes: Int64

    var totalBytes: Int64 {
        protectedDataBytes + documentBytes + temporaryBytes
    }
}

actor AppStorageUsageService {
    static let shared = AppStorageUsageService()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func snapshot() -> AppStorageSnapshot {
        AppStorageSnapshot(
            protectedDataBytes: directorySize(for: .applicationSupportDirectory),
            documentBytes: directorySize(for: .documentDirectory),
            temporaryBytes: directorySize(for: .cachesDirectory)
        )
    }

    func clearTemporaryData() -> AppStorageSnapshot {
        URLCache.shared.removeAllCachedResponses()
        if let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let children = try? fileManager.contentsOfDirectory(
               at: cacheDirectory,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            for child in children {
                try? fileManager.removeItem(at: child)
            }
        }
        return snapshot()
    }

    private func directorySize(for directory: FileManager.SearchPathDirectory) -> Int64 {
        guard let root = fileManager.urls(for: directory, in: .userDomainMask).first else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
            ],
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var result: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
            ]), values.isRegularFile == true else { continue }
            result += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return result
    }
}
