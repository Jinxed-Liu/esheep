import Foundation
import XCTest
@testable import eSheepNext

final class CheckpointDownloadTests: XCTestCase {
    func testBufferedDownloadRejectsTruncationAndOversize() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CheckpointDownloadProtocol.self]
        let bytes = try await ESheepCloudBoundedDownload(expectedBytes: 6, configuration: config)
            .receive(URL(string: "https://checkpoint.invalid/ok")!)
        XCTAssertEqual(bytes, Data("abcdef".utf8))
        for path in ["short", "large", "denied"] {
            do {
                _ = try await ESheepCloudBoundedDownload(expectedBytes: 6, configuration: config)
                    .receive(URL(string: "https://checkpoint.invalid/\(path)")!)
                XCTFail("Invalid download must fail: \(path)")
            } catch { }
        }
    }

    func testCancelledDownloadCannotReturnData() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CheckpointDownloadProtocol.self]
        let task = Task {
            try await ESheepCloudBoundedDownload(expectedBytes: 6, configuration: config)
                .receive(URL(string: "https://checkpoint.invalid/wait")!)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transfer completed") }
        catch { }
    }
}

private final class CheckpointDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "wait" { return }
        let status = path == "denied" ? 403 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("abc".utf8))
        if path != "short" { client?.urlProtocol(self, didLoad: Data((path == "large" ? "defg" : "def").utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
