import Foundation
import XCTest
@testable import eSheepNext

@MainActor
final class IdentityWorkerClientTransportTests: XCTestCase {
    override func tearDown() {
        IdentityWorkerMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testEmptyResponseDecoderAcceptsNoContent() throws {
        XCTAssertNoThrow(try IdentityWorkerResponseDecoder.decodeEmpty(Data()))
    }

    func testEmptyResponseDecoderAcceptsEmptyJSONObject() throws {
        XCTAssertNoThrow(try IdentityWorkerResponseDecoder.decodeEmpty(Data("{}".utf8)))
    }

    func testEmptyResponseDecoderRejectsMalformedBody() {
        XCTAssertThrowsError(
            try IdentityWorkerResponseDecoder.decodeEmpty(Data("not-json".utf8))
        )
    }

    func testNonEmptyResponseDecodesNormally() async throws {
        IdentityWorkerMockURLProtocol.handler = { request in
            Self.response(
                for: request,
                statusCode: 200,
                body: "{\"status\":\"ok\",\"environment\":\"test\",\"version\":\"1\",\"database\":\"ready\"}"
            )
        }

        let response = try await makeClient().health()

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.environment, "test")
        XCTAssertEqual(response.database, "ready")
    }

    func testUnauthorizedErrorBodyIsPreserved() async {
        IdentityWorkerMockURLProtocol.handler = { request in
            Self.response(
                for: request,
                statusCode: 401,
                body: "{\"error\":{\"code\":\"unauthorized\",\"message\":\"session expired\"}}"
            )
        }

        await assertServerError(code: "unauthorized", message: "session expired") {
            _ = try await self.makeClient().health()
        }
    }

    func testForbiddenFlatErrorBodyIsPreserved() async {
        IdentityWorkerMockURLProtocol.handler = { request in
            Self.response(
                for: request,
                statusCode: 403,
                body: "{\"code\":\"forbidden\",\"message\":\"farm access denied\"}"
            )
        }

        await assertServerError(code: "forbidden", message: "farm access denied") {
            _ = try await self.makeClient().health()
        }
    }

    func testCancelledURLRequestPropagatesCancellation() async {
        IdentityWorkerMockURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await makeClient().health()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not be rewritten as a connectivity failure.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testSuccessfulResponseWithInvalidJSONReportsDecodingFailure() async {
        IdentityWorkerMockURLProtocol.handler = { request in
            Self.response(for: request, statusCode: 200, body: "not-json")
        }

        do {
            _ = try await makeClient().health()
            XCTFail("Expected decoding failure")
        } catch is DecodingError {
            // Expected.
        } catch {
            XCTFail("Expected DecodingError, got \(error)")
        }
    }

    private func makeClient() -> IdentityWorkerClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityWorkerMockURLProtocol.self]
        return IdentityWorkerClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://identity.test")!
        )
    }

    private func assertServerError(
        code: String,
        message: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected server error")
        } catch let error as IdentityWorkerError {
            XCTAssertEqual(error, .server(code: code, message: message))
        } catch {
            XCTFail("Expected IdentityWorkerError, got \(error)")
        }
    }

    nonisolated private static func response(
        for request: URLRequest,
        statusCode: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class IdentityWorkerMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
