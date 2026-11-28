import XCTest
@testable import eSheepNext

final class AccountLoginTransportTests: XCTestCase {
    func testProductionSelectorRequiresFreshJSONFromThePinnedEndpoint() throws {
        let endpoint = ProductionBackendStatus.endpoint
        func state(_ name: String, url: URL, mime: String = "application/json", status: Int = 200) throws -> ProductionBackend? {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                         headerFields: ["Content-Type": mime]))
            return ProductionBackendStatus.decode(try JSONEncoder().encode(["state": name]), response)
        }
        XCTAssertEqual(try state("maintenance", url: endpoint), .maintenance)
        XCTAssertEqual(try state("mini", url: endpoint), .mini)
        XCTAssertNil(try state("hosted", url: endpoint, mime: "text/html"))
        XCTAssertNil(try state("hosted", url: endpoint, status: 503))
        XCTAssertNil(try state("other", url: endpoint))
        XCTAssertNil(try state("hosted", url: URL(string: "https://other.invalid/api/backend-status")!))
        XCTAssertFalse(ProductionBackend.hosted.matches(URL(string: ProductionBackend.miniOrigin)!))
        XCTAssertFalse(ProductionBackend.maintenance.matches(URL(string: ProductionBackend.hostedOrigin)!))
    }

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
