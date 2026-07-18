import XCTest
@testable import eSheepNext

final class AppleIdentityTests: XCTestCase {
    func testNonceDigestUsesAppleCompatibleLowercaseHexSHA256() {
        XCTAssertEqual(
            AppleIdentityActor.hashedNonce("eSheepNext-apple-nonce"),
            "a2f0cf34065527e259b94f8970fde7cc759092e965eb9a8b8c7c0cc2d96d9087"
        )
    }

    func testOnlyConnectivityFailuresDeferAppleBroker() {
        XCTAssertTrue(
            IdentityWorkerError.networkUnavailable(
                host: "identity.example.com",
                code: .timedOut
            ).canDeferAppleBroker
        )
        XCTAssertFalse(
            IdentityWorkerError.networkUnavailable(
                host: "identity.example.com",
                code: .cancelled
            ).canDeferAppleBroker
        )
        XCTAssertFalse(
            IdentityWorkerError.server(code: "invalid_token", message: "Invalid token").canDeferAppleBroker
        )
    }
}
