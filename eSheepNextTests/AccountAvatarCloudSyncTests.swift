import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class AccountAvatarCloudSyncTests: XCTestCase {
    func testLegacyLocalAvatarUploadsWhenCloudHasNeverStoredAnAvatar() async throws {
        let (container, context, account) = try makeAccount()
        let jpeg = Self.jpeg
        account.avatarImageData = jpeg
        try context.save()
        let digest = AccountAvatarCloudSyncService.digest(jpeg)
        let remote = AvatarRemoteStub(
            metadata: response(accountID: account.effectiveAccountID),
            content: response(accountID: account.effectiveAccountID),
            update: response(
                accountID: account.effectiveAccountID,
                revision: 11,
                digest: digest,
                hasAvatar: true
            ),
            remove: response(accountID: account.effectiveAccountID, revision: 12)
        )
        let service = AccountAvatarCloudSyncService(remote: remote)

        try await service.synchronize(account: account, context: context)

        XCTAssertEqual(account.avatarImageData, jpeg)
        XCTAssertEqual(account.avatarCloudRevision, 11)
        XCTAssertEqual(account.avatarCloudDigest, digest)
        let uploaded = await remote.uploadedData()
        XCTAssertEqual(uploaded, jpeg)
        _ = container
    }

    func testRemoteAvatarDownloadsWhenAnotherDeviceHasANewerRevision() async throws {
        let (container, context, account) = try makeAccount()
        let jpeg = Self.jpeg
        let digest = AccountAvatarCloudSyncService.digest(jpeg)
        let remote = AvatarRemoteStub(
            metadata: response(
                accountID: account.effectiveAccountID,
                revision: 21,
                digest: digest,
                hasAvatar: true
            ),
            content: response(
                accountID: account.effectiveAccountID,
                revision: 21,
                digest: digest,
                hasAvatar: true,
                dataBase64: jpeg.base64EncodedString()
            ),
            update: response(accountID: account.effectiveAccountID, revision: 22),
            remove: response(accountID: account.effectiveAccountID, revision: 23)
        )
        let service = AccountAvatarCloudSyncService(remote: remote)

        try await service.synchronize(account: account, context: context)

        XCTAssertEqual(account.avatarImageData, jpeg)
        XCTAssertEqual(account.avatarCloudRevision, 21)
        XCTAssertEqual(account.avatarCloudDigest, digest)
        _ = container
    }

    func testRemoteRemovalClearsAStaleAvatarInsteadOfUploadingItAgain() async throws {
        let (container, context, account) = try makeAccount()
        account.avatarImageData = Self.jpeg
        account.avatarCloudRevision = 31
        account.avatarCloudDigest = AccountAvatarCloudSyncService.digest(Self.jpeg)
        try context.save()
        let remote = AvatarRemoteStub(
            metadata: response(accountID: account.effectiveAccountID, revision: 32),
            content: response(accountID: account.effectiveAccountID, revision: 32),
            update: response(accountID: account.effectiveAccountID, revision: 33),
            remove: response(accountID: account.effectiveAccountID, revision: 34)
        )
        let service = AccountAvatarCloudSyncService(remote: remote)

        try await service.synchronize(account: account, context: context)

        XCTAssertNil(account.avatarImageData)
        XCTAssertEqual(account.avatarCloudRevision, 32)
        XCTAssertNil(account.avatarCloudDigest)
        let uploaded = await remote.uploadedData()
        XCTAssertNil(uploaded)
        _ = container
    }

    func testMalformedRemoteAvatarDoesNotReplaceLocalData() async throws {
        let (container, context, account) = try makeAccount()
        let existing = Self.jpeg
        account.avatarImageData = existing
        account.avatarCloudRevision = 40
        account.avatarCloudDigest = AccountAvatarCloudSyncService.digest(existing)
        try context.save()
        let remote = AvatarRemoteStub(
            metadata: response(
                accountID: account.effectiveAccountID,
                revision: 41,
                digest: String(repeating: "0", count: 64),
                hasAvatar: true
            ),
            content: response(
                accountID: account.effectiveAccountID,
                revision: 41,
                digest: String(repeating: "0", count: 64),
                hasAvatar: true,
                dataBase64: Self.jpeg.base64EncodedString()
            ),
            update: response(accountID: account.effectiveAccountID, revision: 42),
            remove: response(accountID: account.effectiveAccountID, revision: 43)
        )
        let service = AccountAvatarCloudSyncService(remote: remote)

        do {
            try await service.synchronize(account: account, context: context)
            XCTFail("Expected malformed remote content to fail")
        } catch {
            XCTAssertEqual(error as? AccountAvatarCloudSyncError, .malformedResponse)
        }

        XCTAssertEqual(account.avatarImageData, existing)
        XCTAssertEqual(account.avatarCloudRevision, 40)
        _ = container
    }

    private func makeAccount() throws -> (ModelContainer, ModelContext, AccountProfile) {
        let schema = Schema([AccountProfile.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let account = AccountProfile(appleUserIdentifier: "avatar-sync-user", displayName: "头像同步")
        account.serverAccountID = UUID()
        context.insert(account)
        try context.save()
        return (container, context, account)
    }

    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

    private func response(
        accountID: UUID,
        revision: Int64? = nil,
        digest: String? = nil,
        hasAvatar: Bool = false,
        dataBase64: String? = nil
    ) -> WorkerAccountAvatarResponse {
        WorkerAccountAvatarResponse(
            accountID: accountID,
            revision: revision,
            digest: digest,
            hasAvatar: hasAvatar,
            dataBase64: dataBase64
        )
    }
}

private actor AvatarRemoteStub: AccountAvatarRemoteClient {
    private let metadataResponse: WorkerAccountAvatarResponse
    private let contentResponse: WorkerAccountAvatarResponse
    private let updateResponse: WorkerAccountAvatarResponse
    private let removeResponse: WorkerAccountAvatarResponse
    private var uploaded: Data?

    init(
        metadata: WorkerAccountAvatarResponse,
        content: WorkerAccountAvatarResponse,
        update: WorkerAccountAvatarResponse,
        remove: WorkerAccountAvatarResponse
    ) {
        self.metadataResponse = metadata
        self.contentResponse = content
        self.updateResponse = update
        self.removeResponse = remove
    }

    func accountAvatarMetadata() async throws -> WorkerAccountAvatarResponse {
        metadataResponse
    }

    func accountAvatarContent() async throws -> WorkerAccountAvatarResponse {
        contentResponse
    }

    func updateAccountAvatar(_ data: Data) async throws -> WorkerAccountAvatarResponse {
        uploaded = data
        return updateResponse
    }

    func removeAccountAvatar() async throws -> WorkerAccountAvatarResponse {
        removeResponse
    }

    func uploadedData() -> Data? {
        uploaded
    }
}
