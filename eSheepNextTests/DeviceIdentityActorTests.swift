import XCTest
@testable import eSheepNext

final class DeviceIdentityActorTests: XCTestCase {
    func testDeviceIdentityStorageIsSeparatedByAccount() {
        let firstAccount = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondAccount = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let firstName = DeviceIdentityActor.storageAccountName(
            base: "device-id",
            accountID: firstAccount
        )
        let secondName = DeviceIdentityActor.storageAccountName(
            base: "device-id",
            accountID: secondAccount
        )

        XCTAssertEqual(firstName, "device-id.account.11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(secondName, "device-id.account.22222222-2222-2222-2222-222222222222")
        XCTAssertNotEqual(firstName, secondName)
    }

    func testUnauthenticatedIdentityKeepsLegacyStorageName() {
        XCTAssertEqual(
            DeviceIdentityActor.storageAccountName(base: "device-id", accountID: nil),
            "device-id"
        )
    }

    func testSigningKeyUsesTheSameAccountScopeAsDeviceID() {
        let accountID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        XCTAssertEqual(
            DeviceIdentityActor.storageAccountName(
                base: "device-secure-enclave-key",
                accountID: accountID
            ),
            "device-secure-enclave-key.account.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        XCTAssertEqual(
            DeviceIdentityActor.storageAccountName(
                base: "device-software-key",
                accountID: accountID
            ),
            "device-software-key.account.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
    }
}
