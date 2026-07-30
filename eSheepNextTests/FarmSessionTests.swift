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

    func testDevelopmentSupabaseFeatureGateMatchesEmbeddedConfiguration() {
        if SupabaseAccountConfiguration.isEnabled {
            XCTAssertTrue(SupabaseAccountConfiguration.isConfigured)
            XCTAssertEqual(AccountIdentityClients.activeProvider, .supabase)
        } else {
            XCTAssertFalse(SupabaseAccountConfiguration.isConfigured)
            XCTAssertEqual(AccountIdentityClients.activeProvider, .cloudBaseLegacy)
        }
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

    func testPersistedSessionOnlyAllowsOfflineResumeBeforeRefreshExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = StoredWorkerSession(accountID: UUID(), accessExpiresAt: 1_799_999_000, refreshExpiresAt: 1_800_000_100)
        let expired = StoredWorkerSession(accountID: UUID(), accessExpiresAt: 1_799_999_000, refreshExpiresAt: 1_800_000_000)

        XCTAssertTrue(active.canResumeOffline(now: now))
        XCTAssertFalse(expired.canResumeOffline(now: now))
    }

    func testSupabaseRegistrationCanCompleteWithEmailVerificationPending() {
        let result = AccountRegistrationResult.verificationRequired(
            email: "member@example.com"
        )

        guard case .verificationRequired(let email) = result else {
            return XCTFail("Email confirmation must be represented as a successful pending state.")
        }
        XCTAssertEqual(email, "member@example.com")
    }

    func testSupabaseDisplayNameNormalizationRemovesControlsAndCapsLength() {
        let value = "  测试\u{0000}用户" + String(repeating: "羊", count: 140)
        let normalized = SupabaseAccountIdentityClient.normalizedDisplayName(value)

        XCTAssertNotNil(normalized)
        XCTAssertFalse(normalized?.contains("\u{0000}") == true)
        XCTAssertEqual(normalized?.count, 120)
        XCTAssertNil(SupabaseAccountIdentityClient.normalizedDisplayName(" \n\t "))
    }

    func testSupabaseSignOutIsScopedToTheCurrentDevice() {
        XCTAssertEqual(SupabaseAccountIdentityClient.signOutScope.rawValue, "local")
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

        let sheepID = UUID()
        AppNavigationRequest.enqueue(.openSheep(sheepID))
        session.consumePendingNavigationRequest()
        XCTAssertEqual(session.selectedTab, .search)
        XCTAssertEqual(session.pendingSheepID, sheepID)
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
        let profile = try XCTUnwrap(
            context.fetch(FetchDescriptor<FarmStorageProfile>()).first(where: { $0.farmID == farm.id })
        )
        XCTAssertEqual(profile.mode, .localOnly)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FarmOperationSequenceCounter>())
                .first(where: { $0.farmID == farm.id })?.nextSequence,
            2
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<OutboxItem>()).isEmpty)
        let createOperation = try XCTUnwrap(
            context.fetch(FetchDescriptor<DomainOperation>())
                .first(where: { $0.farmID == farm.id })
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FarmOperationSequenceRecord>())
                .first(where: { $0.operationID == createOperation.id })?.clientSequence,
            1
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(
            FarmCommandCloudPayload.self,
            from: createOperation.payload
        )
        XCTAssertEqual(payload.kind, DomainOperationKind.createFarm)
        XCTAssertEqual(payload.strings["name"], "北场")
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
        var clearedProfile = false
        let session = AppSession(
            activeAccountProfileID: UUID(),
            clearActiveAccountProfileID: { clearedProfile = true }
        )
        session.selectedFarmID = UUID()
        session.selectedTab = .feeding
        session.isReauthenticationPresented = true
        let revision = session.authenticationRevision

        session.authenticationDidSignOut()

        XCTAssertNil(session.activeAccountProfileID)
        XCTAssertTrue(clearedProfile)
        XCTAssertNil(session.selectedFarmID)
        XCTAssertEqual(session.selectedTab, .home)
        XCTAssertEqual(session.authenticationRevision, revision + 1)
        XCTAssertTrue(session.accountAccessStatus.requiresSignIn)
        XCTAssertFalse(session.isReauthenticationPresented)
        XCTAssertNotNil(session.authenticationNotice)
    }

    func testSuccessfulAuthenticationSelectsTheAccountProfile() {
        var persistedProfileID: UUID?
        let session = AppSession(
            activeAccountProfileID: nil,
            persistActiveAccountProfileID: { persistedProfileID = $0 }
        )
        let profileID = UUID()

        session.authenticationDidSucceed(accountProfileID: profileID)

        XCTAssertEqual(session.activeAccountProfileID, profileID)
        XCTAssertEqual(persistedProfileID, profileID)
        XCTAssertEqual(session.accountAccessStatus, .checking)
        XCTAssertFalse(session.isReauthenticationPresented)
    }

    func testAuthenticationRefreshReturnsToCheckingWithoutBlockingLocalSession() {
        let session = AppSession(activeAccountProfileID: nil)
        session.authenticationCheckDidFinish(
            .localOnly("网络不可用"),
            automaticallyPresentReauthentication: false
        )
        let revision = session.authenticationRevision

        session.requestAuthenticationRefresh()

        XCTAssertEqual(session.accountAccessStatus, .checking)
        XCTAssertEqual(session.authenticationRevision, revision + 1)
    }

    func testReauthenticationSheetOnlyAutoPresentsOnFirstDefinitiveFailure() {
        let session = AppSession(activeAccountProfileID: nil)

        session.authenticationCheckDidFinish(
            .requiresSignIn("会话已失效"),
            automaticallyPresentReauthentication: true
        )
        XCTAssertTrue(session.isReauthenticationPresented)

        session.isReauthenticationPresented = false
        session.authenticationCheckDidFinish(
            .requiresSignIn("会话仍然失效"),
            automaticallyPresentReauthentication: true
        )

        XCTAssertFalse(session.isReauthenticationPresented)
    }

    func testAutomaticCloudRecoveryIsSingleFlightPerAccount() {
        let session = AppSession(activeAccountProfileID: nil)
        let accountID = UUID()

        XCTAssertTrue(session.beginAutomaticCloudRecovery(accountID: accountID))
        XCTAssertFalse(session.beginAutomaticCloudRecovery(accountID: accountID))

        session.finishAutomaticCloudRecovery(accountID: accountID)
        XCTAssertTrue(session.beginAutomaticCloudRecovery(accountID: accountID))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AccountProfile.self,
            FarmRecord.self,
            FarmActivity.self,
            DomainOperation.self,
            OutboxItem.self,
            FarmStorageProfile.self,
            FarmOperationSequenceCounter.self,
            FarmOperationSequenceRecord.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
