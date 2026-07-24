import XCTest
@testable import eSheepNext

@MainActor
final class AppPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsPreserveNormalAppBehavior() {
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertFalse(preferences.powerSavingEnabled)
        XCTAssertTrue(preferences.backgroundRefreshEnabled)
        XCTAssertFalse(preferences.reduceMotionEnabled)
        XCTAssertTrue(preferences.avatarMotionEnabled)
    }

    func testPreferencesPersistWithoutChangingBusinessModels() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.appearance = .dark
        preferences.language = .simplifiedChinese
        preferences.powerSavingEnabled = true
        preferences.backgroundRefreshEnabled = false
        preferences.reduceMotionEnabled = true
        preferences.avatarMotionEnabled = false

        let restored = AppPreferences(defaults: defaults)

        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertEqual(restored.language, .simplifiedChinese)
        XCTAssertTrue(restored.powerSavingEnabled)
        XCTAssertFalse(restored.backgroundRefreshEnabled)
        XCTAssertTrue(restored.reduceMotionEnabled)
        XCTAssertFalse(restored.avatarMotionEnabled)
        XCTAssertTrue(restored.shouldReduceMotion)
        XCTAssertEqual(restored.avatarSyncInterval, .seconds(60))
    }

    func testStorageSnapshotTotalOnlyCombinesUserFacingCategories() {
        let snapshot = AppStorageSnapshot(
            protectedDataBytes: 100,
            documentBytes: 20,
            temporaryBytes: 5
        )

        XCTAssertEqual(snapshot.totalBytes, 125)
    }
}
