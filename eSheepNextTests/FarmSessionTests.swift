import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class FarmSessionTests: XCTestCase {
    func testDevelopmentBuildActuallyEmbedsCloudKitRuntimeConfiguration() throws {
        XCTAssertTrue(CloudFeatureConfiguration.isEnabled)
        let container = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CLOUDKIT_CONTAINER_IDENTIFIER") as? String)
        XCTAssertFalse(container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(container, "iCloud.com.sheepfarm.next.dev")
    }

    func testIdentityEndpointPreservesGatewayBasePath() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/identity"))

        let endpoint = IdentityWorkerConfiguration.endpointURL(
            baseURL: baseURL,
            path: "/v1/auth/password"
        )

        XCTAssertEqual(endpoint.absoluteString, "https://example.com/identity/v1/auth/password")
    }

    func testLegacyPasswordAccountCanStillDecodeItsExistingServerIdentity() {
        let serverAccountID = UUID()
        let account = AccountProfile(
            appleUserIdentifier: "password:test-user",
            displayName: "测试账户",
            authenticationMethod: .password
        )

        account.serverAccountID = serverAccountID

        XCTAssertEqual(account.authenticationMethod, .password)
        XCTAssertEqual(account.effectiveAccountID, serverAccountID)
    }

    func testAccountAvatarPersistsWithTheLocalProfile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "avatar-user", displayName: "头像账户")
        let avatarData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        context.insert(account)
        account.avatarImageData = avatarData
        try context.save()

        let saved = try context.fetch(FetchDescriptor<AccountProfile>()).first
        XCTAssertEqual(saved?.avatarImageData, avatarData)
    }

    func testPendingAppIntentNavigationRoutesToTheCorrectEntryPoint() {
        defer { _ = AppNavigationRequest.consume() }
        let session = AppSession()

        AppNavigationRequest.enqueue(.recordWeight)
        session.consumePendingNavigationRequest()
        XCTAssertEqual(session.selectedTab, .records)
        XCTAssertEqual(session.pendingRecordEntry, .weight)

        AppNavigationRequest.enqueue(.recordFeed)
        session.consumePendingNavigationRequest()
        XCTAssertEqual(session.selectedTab, .feeding)
        XCTAssertEqual(session.pendingRecordEntry, .feed)
    }

    func testCreatingFarmSelectsItAndKeepsOwnerScope() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "test-apple-id", displayName: "测试账户")
        context.insert(account)

        let session = AppSession()
        let farm = try session.createFarm(
            named: "北场",
            account: account,
            entitlement: .basic(accountID: account.effectiveAccountID),
            context: context
        )

        XCTAssertEqual(session.selectedFarmID, farm.id)
        XCTAssertEqual(farm.ownerAccountID, account.id)
        XCTAssertEqual(farm.role, .owner)
    }

    func testSwitchingFarmResetsToHome() throws {
        let account = AccountProfile(appleUserIdentifier: "test-apple-id", displayName: "测试账户")
        let north = FarmRecord(ownerAccountID: account.id, name: "北场")
        let south = FarmRecord(ownerAccountID: account.id, name: "南场")
        let session = AppSession()

        session.selectedTab = .assistant
        try session.switchFarm(to: south.id, availableFarms: [north, south])

        XCTAssertEqual(session.selectedFarmID, south.id)
        XCTAssertEqual(session.selectedTab, .home)
    }

    func testSigningOutResetsNavigationAndRequestsAuthenticationRefresh() {
        let session = AppSession()
        session.selectedFarmID = UUID()
        session.selectedTab = .feeding
        let revision = session.authenticationRevision

        session.authenticationDidSignOut()

        XCTAssertNil(session.selectedFarmID)
        XCTAssertEqual(session.selectedTab, .home)
        XCTAssertEqual(session.authenticationRevision, revision + 1)
        XCTAssertNotNil(session.authenticationNotice)
    }

    func testSuccessfulAuthenticationSelectsTheAccountProfile() {
        let session = AppSession()
        let profileID = UUID()

        session.authenticationDidSucceed(accountProfileID: profileID)

        XCTAssertEqual(session.activeAccountProfileID, profileID)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([AccountProfile.self, FarmRecord.self, FarmActivity.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
