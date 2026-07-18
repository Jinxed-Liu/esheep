import XCTest
@testable import eSheepNext

final class AppleIdentityTests: XCTestCase {
    func testDevelopmentCanEnterLocalWorkspaceWhileAppleCloudBaseBindingIsMigrating() {
        let error = IdentityWorkerError.server(
            code: "apple_cloudbase_migration_pending",
            message: "账号在迁移"
        )

        XCTAssertTrue(AppleLoginCompatibilityPolicy.allowsLocalWorkspace(for: error, environment: .development))
        XCTAssertFalse(AppleLoginCompatibilityPolicy.allowsLocalWorkspace(for: error, environment: .staging))
        XCTAssertFalse(AppleLoginCompatibilityPolicy.allowsLocalWorkspace(for: error, environment: .production))
    }

    func testNonceDigestUsesAppleCompatibleLowercaseHexSHA256() {
        XCTAssertEqual(
            AppleIdentityActor.hashedNonce("eSheepNext-apple-nonce"),
            "a2f0cf34065527e259b94f8970fde7cc759092e965eb9a8b8c7c0cc2d96d9087"
        )
    }
}
