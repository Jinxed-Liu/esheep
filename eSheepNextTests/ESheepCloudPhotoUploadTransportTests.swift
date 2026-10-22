import Foundation
import SwiftData
import Supabase
import XCTest
@testable import eSheepNext

@MainActor
final class ESheepCloudPhotoUploadTransportTests: XCTestCase {
    override func tearDown() {
        PhotoUploadURLProtocol.handler = nil
        super.tearDown()
    }

    /// Uses the production gateway and SDK. The signing endpoint applies the
    /// deployed storage policy: user_metadata.sha256 must match the object key.
    func testEveryPhotoVariantPassesSigningPolicyAndCompletesSignedTUSUpload() async throws {
        for variant in [ESheepCloudAssetVariantV2.thumbnail, .avatar, .original] {
            let assetID = UUID()
            let digest = String(repeating: "a", count: 64)
            let objectKey = "\(UUID().uuidString.lowercased())/3/\(assetID.uuidString.lowercased())/\(digest)/\(variant.rawValue).bin"
            let metadata = ["mimeType": "image/heic", "sourceSHA256": digest]
            let gateway = makeGateway()
            PhotoUploadURLProtocol.handler = { request in
                let url = try XCTUnwrap(request.url)
                switch url.path {
                case "/rest/v1/rpc/esheep_cloud_prepare_asset_transfer_v2":
                    return try Self.reply(request, json: ["asset_id": assetID.uuidString,
                        "variant": variant.rawValue, "object_key": objectKey, "already_verified": false])
                case "/storage/v1/object/upload/sign/esheep-cloud-assets/\(objectKey)":
                    let encoded = request.value(forHTTPHeaderField: "x-metadata") ?? ""
                    let data = Data(base64Encoded: encoded) ?? Data()
                    let supplied = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
                    guard supplied["sha256"] == digest else {
                        return try Self.reply(request, status: 403, json: ["statusCode": "403",
                            "error": "Unauthorized", "message": "new row violates row-level security policy"])
                    }
                    XCTAssertEqual(supplied["mimeType"], metadata["mimeType"])
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-upsert"), "true")
                    return try Self.reply(request, json: ["url":
                        "/object/upload/sign/esheep-cloud-assets/\(objectKey)?token=test-upload-token"])
                case "/storage/v1/upload/resumable/sign":
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-signature"), "test-upload-token")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Upload-Length"), "3")
                    let entries = (request.value(forHTTPHeaderField: "Upload-Metadata") ?? "")
                        .split(separator: ",").map { $0.split(separator: " ", maxSplits: 1) }
                    let headers = Dictionary(uniqueKeysWithValues: entries.compactMap { pair -> (String, Data)? in
                        guard pair.count == 2, let bytes = Data(base64Encoded: String(pair[1])) else { return nil }
                        return (String(pair[0]), bytes)
                    })
                    let uploadMetadata = try JSONDecoder().decode([String: String].self,
                        from: XCTUnwrap(headers["metadata"]))
                    XCTAssertEqual(uploadMetadata["sha256"], digest)
                    XCTAssertEqual(String(data: try XCTUnwrap(headers["objectName"]), encoding: .utf8), objectKey)
                    return try Self.reply(request, status: 201, headers: ["Location":
                        "https://photos.invalid/storage/v1/upload/resumable/sign/session"])
                case "/storage/v1/upload/resumable/sign/session":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-signature"), "test-upload-token")
                    let offset = request.httpMethod == "HEAD" ? "0" : "3"
                    if request.httpMethod == "PATCH" {
                        XCTAssertEqual(request.value(forHTTPHeaderField: "Upload-Offset"), "0")
                        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/offset+octet-stream")
                    }
                    return try Self.reply(request, status: 204, headers: ["Upload-Offset": offset])
                case "/functions/v1/esheep-cloud-v2-writes":
                    return try Self.reply(request, json: ["asset_id": assetID.uuidString,
                        "variant": variant.rawValue, "verified": true])
                default:
                    XCTFail("Unexpected upload endpoint: \(url.path)")
                    return try Self.reply(request, status: 401, json: ["message": "Bearer token required on unsigned TUS route"])
                }
            }
            let farmID = UUID()
            let ticket = try await gateway.prepareAssetTransfer(.init(farmID: farmID, farmGeneration: 3,
                assetID: assetID, sheepID: UUID(), contentSHA256: digest, variantSHA256: digest,
                metadata: metadata, metadataDigest: ESheepCloudCanonicalCodec.digest(metadata),
                variant: variant, direction: .upload, byteOffset: 0, byteCount: 3))
            let session = try await gateway.createResumableUpload(ticket: ticket,
                descriptor: .init(objectKey: objectKey, variantSHA256: digest,
                    contentType: "image/jpeg", byteCount: 3, metadata: metadata))
            let offset = try await gateway.resumableUploadOffset(sessionURL: session.url,
                authorizationToken: try XCTUnwrap(ticket.authorizationToken))
            XCTAssertEqual(offset, 0)
            let completed = try await gateway.uploadResumableChunk(Data([1, 2, 3]), sessionURL: session.url,
                authorizationToken: try XCTUnwrap(ticket.authorizationToken), byteOffset: offset)
            XCTAssertEqual(completed, 3)
            try await gateway.confirmAssetUpload(farmID: farmID, farmGeneration: 3, assetID: assetID, variant: variant)
        }
    }

    func testSignedUploadTicketUsesSignedTUSEndpoint() async throws {
        let gateway = makeGateway()
        PhotoUploadURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/storage/v1/upload/resumable/sign")
            XCTAssertNil(request.url?.query, "Do not copy a signed download/upload query into the TUS URL")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-signature"), "test-upload-token")
            return try Self.reply(request, status: 201,
                headers: ["Location": "/storage/v1/upload/resumable/sign/session"])
        }
        _ = try await gateway.createResumableUpload(ticket: .init(assetID: UUID(), variant: .thumbnail,
            objectKey: "photo.jpg", signedURL: URL(string: "https://photos.invalid/storage/v1/object/upload/sign/bucket/photo.jpg?token=secret")!,
            authorizationToken: "test-upload-token", isAlreadyVerified: false, byteOffset: 0, expiresAt: .distantFuture),
            descriptor: .init(objectKey: "photo.jpg", variantSHA256: String(repeating: "a", count: 64),
                contentType: "image/jpeg", byteCount: 3, metadata: [:]))
    }

    func testStoragePermissionFailureIsNotReportedAsUnknown() {
        let error = StorageError(statusCode: "403", message: "new row violates row-level security policy", error: "Unauthorized")
        let failure = ESheepCloudSyncFailure.classify(error)
        XCTAssertEqual(failure.kind, .permission)
        XCTAssertEqual(failure.statusCode, 403)
        XCTAssertEqual(ESheepCloudSyncFailure.classify(StorageError(statusCode: "503", message: "unavailable")).kind, .server)
    }

    func testFailedPhotoKeepsBytesAndTraceThenRetriesTheSameAsset() async throws {
        let farmID = UUID(), assetID = UUID()
        let bytes = Data([1, 2, 3])
        let digest = CloudPayloadDigest.hex(for: bytes)
        let file = FileManager.default.temporaryDirectory.appending(path: "photo-retry-\(UUID()).jpg")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let container = try AppSchema.makeContainer(name: "photo-retry-\(UUID())", isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let farm = ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .active)
        farm.integrityState = .passed
        context.insert(farm)
        let metadata = ["mimeType": "image/jpeg"]
        let asset = ESheepCloudAssetState(assetID: assetID, farmID: farmID, farmGeneration: 3,
            sheepID: UUID(), contentSHA256: digest, metadataDigest: try ESheepCloudCanonicalCodec.digest(metadata), originalByteCount: 3)
        asset.metadataData = try ESheepCloudCanonicalCodec.encode(metadata)
        asset.thumbnailSHA256 = digest
        asset.thumbnailByteCount = 3
        asset.thumbnailRelativePath = file.path
        asset.thumbnailStateRawValue = ESheepCloudAssetTransferState.queued.rawValue
        asset.avatarStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
        asset.originalStateRawValue = ESheepCloudAssetTransferState.verified.rawValue
        context.insert(asset)
        try context.save()
        let objectKey = "\(farmID.uuidString.lowercased())/3/\(assetID.uuidString.lowercased())/\(digest)/thumbnail.jpg"
        let gateway = makeGateway()
        let coordinator = ESheepCloudAssetCoordinator(container: container, gateway: gateway, transport: gateway)
        PhotoUploadURLProtocol.handler = { request in
            if request.url?.path == "/rest/v1/rpc/esheep_cloud_prepare_asset_transfer_v2" {
                return try Self.reply(request, json: ["asset_id": assetID.uuidString,
                    "variant": "thumbnail", "object_key": objectKey, "already_verified": false])
            }
            return try Self.reply(request, status: 403, json: ["statusCode": "403", "message": "denied"])
        }
        var traceID: String?
        do {
            _ = try await coordinator.processReadyUploads(farmID: farmID)
            XCTFail("A denied upload must not be marked verified")
        } catch let failure as ESheepCloudSyncFailure {
            XCTAssertEqual(failure.kind, .permission)
            traceID = failure.traceID
        }
        let verification = ModelContext(container)
        let failed = try XCTUnwrap(verification.fetch(FetchDescriptor<ESheepCloudAssetState>()).first)
        XCTAssertEqual(failed.thumbnailStateRawValue, ESheepCloudAssetTransferState.failed.rawValue)
        XCTAssertEqual(failed.lastErrorTraceID, try XCTUnwrap(traceID))
        XCTAssertNotNil(failed.nextTransferRetryAt)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        PhotoUploadURLProtocol.handler = { _ in
            XCTFail("Retry backoff must be respected")
            throw URLError(.badServerResponse)
        }
        let waiting = try await coordinator.processReadyUploads(farmID: farmID)
        XCTAssertEqual(waiting, 0)
        failed.nextTransferRetryAt = .distantPast
        try verification.save()
        PhotoUploadURLProtocol.handler = { request in
            switch request.url?.path {
            case "/rest/v1/rpc/esheep_cloud_prepare_asset_transfer_v2":
                return try Self.reply(request, json: ["asset_id": assetID.uuidString,
                    "variant": "thumbnail", "object_key": objectKey, "already_verified": false])
            case "/storage/v1/object/upload/sign/esheep-cloud-assets/\(objectKey)":
                return try Self.reply(request, json: ["url": "/object/upload/sign/esheep-cloud-assets/\(objectKey)?token=retry-token"])
            case "/storage/v1/upload/resumable/sign":
                return try Self.reply(request, status: 201,
                    headers: ["Location": "/storage/v1/upload/resumable/sign/retry-session"])
            case "/storage/v1/upload/resumable/sign/retry-session":
                return try Self.reply(request, status: 204, headers: ["Upload-Offset": "3"])
            case "/functions/v1/esheep-cloud-v2-writes":
                return try Self.reply(request, json: ["asset_id": assetID.uuidString, "variant": "thumbnail", "verified": true])
            default:
                XCTFail("Unexpected retry request")
                throw URLError(.badURL)
            }
        }
        let completed = try await coordinator.processReadyUploads(farmID: farmID)
        XCTAssertEqual(completed, 1)
        let states = try ModelContext(container).fetch(FetchDescriptor<ESheepCloudAssetState>())
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.id, assetID)
        XCTAssertEqual(states.first?.thumbnailStateRawValue, ESheepCloudAssetTransferState.verified.rawValue)
        XCTAssertNil(states.first?.lastErrorTraceID)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    private func makeGateway() -> ESheepCloudInfrastructureGateway {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotoUploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SupabaseClient(supabaseURL: URL(string: "https://photos.invalid")!, supabaseKey: "test-key",
            options: .init(auth: .init(storageKey: "photo-upload-tests-\(UUID())", autoRefreshToken: false),
                global: .init(session: session)))
        return ESheepCloudInfrastructureGateway(client: client, transferSession: session)
    }

    nonisolated private static func reply(_ request: URLRequest, status: Int = 200,
                                         json: [String: Any]? = nil, headers: [String: String] = [:]) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers))
        return (response, try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
    }
}

private final class PhotoUploadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
