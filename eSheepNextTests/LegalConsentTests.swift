import XCTest
@testable import eSheepNext

final class LegalConsentTests: XCTestCase {
    func testCurrentLegalReceiptUsesEveryCurrentVersion() {
        let receipt = LegalConsentReceipt(
            consentedAt: Date(timeIntervalSince1970: 1_800_000_000),
            appVersion: "3.1.0 (1)",
            localeIdentifier: "zh_CN"
        )

        XCTAssertEqual(receipt.termsVersion, LegalPolicyVersions.terms)
        XCTAssertEqual(receipt.privacyVersion, LegalPolicyVersions.privacy)
        XCTAssertEqual(receipt.crossBorderVersion, LegalPolicyVersions.crossBorder)
        XCTAssertTrue(receipt.isCurrent)
    }

    func testStaleLegalReceiptIsNotCurrent() throws {
        let json = """
        {
          "termsVersion": "1.0",
          "privacyVersion": "1.0",
          "crossBorderVersion": "1.0",
          "consentedAt": 800000000,
          "appVersion": "1.0",
          "localeIdentifier": "zh_CN"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let receipt = try decoder.decode(LegalConsentReceipt.self, from: json)

        XCTAssertFalse(receipt.isCurrent)
    }

    func testConsentStorageKeysAreAccountScoped() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        XCTAssertNotEqual(
            LegalConsentStore.storageKey(for: first),
            LegalConsentStore.storageKey(for: second)
        )
        XCTAssertNotEqual(
            AIPrivacyConsentStore.storageKey(for: first),
            AIPrivacyConsentStore.storageKey(for: second)
        )
    }

    func testAIConsentVersionMustBeCurrent() {
        XCTAssertTrue(AIPrivacyConsentReceipt().isCurrent)
        XCTAssertFalse(AIPrivacyConsentReceipt(version: "1.0").isCurrent)
    }

    func testLegalWithdrawalEventCarriesTheWithdrawnVersionTuple() {
        let event = LegalConsentWithdrawalEvent(
            occurredAt: Date(timeIntervalSince1970: 1_800_000_001),
            appVersion: "3.1.0 (2)",
            localeIdentifier: "zh_CN"
        )

        XCTAssertEqual(event.termsVersion, LegalPolicyVersions.terms)
        XCTAssertEqual(event.privacyVersion, LegalPolicyVersions.privacy)
        XCTAssertEqual(event.crossBorderVersion, LegalPolicyVersions.crossBorder)
        XCTAssertEqual(event.appVersion, "3.1.0 (2)")
        XCTAssertEqual(event.localeIdentifier, "zh_CN")
    }
}
