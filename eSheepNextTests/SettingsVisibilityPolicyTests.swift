import XCTest
@testable import eSheepNext

final class SettingsVisibilityPolicyTests: XCTestCase {
    func testAlwaysVisibleSettingsAreExposedIndividually() {
        let policy = makePolicy(role: .worker)

        XCTAssertEqual(
            policy.mainDestinations,
            [
                .accountAvatar,
                .accountDisplayName,
                .notifications,
                .dataStorage,
                .appearance,
                .powerSaving,
                .language,
                .insightAssistant,
                .privacyAndTerms,
            ]
        )
    }

    func testOwnerSeesAllEnabledFarmTasksAndSubscription() {
        let policy = makePolicy(
            role: .owner,
            subscriptionEnabled: true,
            unresolvedConflictCount: 2
        )

        XCTAssertTrue(policy.shows(.subscription))
        XCTAssertTrue(policy.shows(.farmLocation))
        XCTAssertTrue(policy.shows(.membersAndSharing))
        XCTAssertTrue(policy.shows(.importData))
        XCTAssertTrue(policy.shows(.exportData))
        XCTAssertTrue(policy.shows(.localBackup))
        XCTAssertTrue(policy.shows(.dataConflicts))
    }

    func testAdministratorOnlySeesAllowedFarmTasks() {
        let policy = makePolicy(
            role: .administrator,
            subscriptionEnabled: false,
            unresolvedConflictCount: 3
        )

        XCTAssertTrue(policy.shows(.farmLocation))
        XCTAssertTrue(policy.shows(.membersAndSharing))
        XCTAssertTrue(policy.shows(.importData))
        XCTAssertTrue(policy.shows(.localBackup))
        XCTAssertFalse(policy.shows(.subscription))
        XCTAssertFalse(policy.shows(.exportData))
        XCTAssertFalse(policy.shows(.dataConflicts))
    }

    func testWorkerDoesNotSeeUnavailableRows() {
        let policy = makePolicy(
            role: .worker,
            subscriptionEnabled: false,
            unresolvedConflictCount: 1
        )

        XCTAssertTrue(policy.shows(.membersAndSharing))
        XCTAssertTrue(policy.shows(.importData))
        XCTAssertTrue(policy.shows(.localBackup))
        XCTAssertFalse(policy.shows(.farmLocation))
        XCTAssertFalse(policy.shows(.exportData))
        XCTAssertFalse(policy.shows(.dataConflicts))
    }

    func testGrantedWorkerCapabilitiesRevealOnlyTheirTasks() {
        let policy = makePolicy(
            role: .worker,
            grantedWorkerCapabilities: [.exportFarm, .recoverFarm, .resolveConflicts],
            unresolvedConflictCount: 1
        )

        XCTAssertTrue(policy.shows(.exportData))
        XCTAssertTrue(policy.shows(.dataConflicts))
        XCTAssertFalse(policy.shows(.farmLocation))
    }

    func testFeatureFlagsHideSubscriptionAndMemberSharing() {
        let policy = SettingsVisibilityPolicy(
            role: .owner,
            cloudEnabled: false,
            memberSharingEnabled: false,
            subscriptionEnabled: false,
            unresolvedConflictCount: 1
        )

        XCTAssertFalse(policy.shows(.subscription))
        XCTAssertFalse(policy.shows(.membersAndSharing))
        XCTAssertTrue(policy.shows(.dataConflicts))
    }

    func testConflictDestinationOnlyAppearsWhenActionIsRequired() {
        let withoutConflict = makePolicy(role: .owner, unresolvedConflictCount: 0)
        let withConflict = makePolicy(role: .owner, unresolvedConflictCount: 1)

        XCTAssertFalse(withoutConflict.shows(.dataConflicts))
        XCTAssertTrue(withConflict.shows(.dataConflicts))
    }

    private func makePolicy(
        role: FarmRole,
        grantedWorkerCapabilities: Set<FarmCapability> = [],
        cloudEnabled: Bool = true,
        subscriptionEnabled: Bool = true,
        unresolvedConflictCount: Int = 0
    ) -> SettingsVisibilityPolicy {
        SettingsVisibilityPolicy(
            role: role,
            grantedWorkerCapabilities: grantedWorkerCapabilities,
            cloudEnabled: cloudEnabled,
            subscriptionEnabled: subscriptionEnabled,
            unresolvedConflictCount: unresolvedConflictCount
        )
    }
}
