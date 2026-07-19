import XCTest
@testable import eSheepNext

final class AppleIdentityTests: XCTestCase {
    func testMigrationResponseIsSurfacedAsARealLoginFailure() {
        let error = IdentityWorkerError.server(
            code: "apple_cloudbase_migration_pending",
            message: "账号在迁移"
        )

        XCTAssertEqual(error.errorDescription, "账号在迁移")
    }

    func testNonceDigestUsesAppleCompatibleLowercaseHexSHA256() {
        XCTAssertEqual(
            AppleIdentityActor.hashedNonce("eSheepNext-apple-nonce"),
            "a2f0cf34065527e259b94f8970fde7cc759092e965eb9a8b8c7c0cc2d96d9087"
        )
    }
}
