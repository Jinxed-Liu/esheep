import XCTest
@testable import eSheepNext

final class AccountLoginTransportTests: XCTestCase {
    func testHealthyGatewayCompletesAfterDirectTLSFailure() async throws {
        let route = try await AccountLoginRoute.firstAvailable { candidate in
            if candidate == .direct { throw URLError(.secureConnectionFailed) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(route, .webGateway)
    }

    func testBadGatewayCannotPreventDirectLogin() async throws {
        let route = try await AccountLoginRoute.firstAvailable { candidate in
            if candidate == .webGateway { throw URLError(.badServerResponse) }
        }
        XCTAssertEqual(route, .direct)
    }

    func testTokenRequestKeepsBodyAndQueryAndOnlyUsesTheFixedProject() throws {
        let directURL = try XCTUnwrap(URL(string: "https://rnqrvthbunrzqtprquqx.supabase.co/auth/v1/token?grant_type=password"))
        var original = URLRequest(url: directURL)
        original.httpMethod = "POST"
        original.httpBody = Data(#"{"email":"fixture@example.invalid","password":"fixture"}"#.utf8)
        original.setValue("fixture-key", forHTTPHeaderField: "apikey")
        let relayed = try AccountLoginRoute.webGateway.routed(original)
        XCTAssertTrue(AccountLoginRoute.isAccountRequest(original))
        XCTAssertEqual(relayed.url?.absoluteString, "https://app.esheepplus.com/api/cloud/auth/v1/token?grant_type=password")
        XCTAssertEqual(relayed.httpBody, original.httpBody)
        XCTAssertEqual(relayed.httpMethod, original.httpMethod)
        XCTAssertEqual(relayed.value(forHTTPHeaderField: "x-esheep-cloud-host"), directURL.host)
        XCTAssertEqual(relayed.value(forHTTPHeaderField: "apikey"), "fixture-key")
        for other in ["https://example.invalid/auth/v1/token", "https://rnqrvthbunrzqtprquqx.supabase.co/rest/v1/rpc/farm_write"] {
            original.url = URL(string: other)
            XCTAssertFalse(AccountLoginRoute.isAccountRequest(original))
        }
    }
}
