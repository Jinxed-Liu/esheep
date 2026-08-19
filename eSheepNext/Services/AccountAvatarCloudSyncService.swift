import CryptoKit
import Foundation
import SwiftData
import Supabase
import UIKit

protocol AccountAvatarRemoteClient: Sendable {
    func accountAvatarMetadata() async throws -> WorkerAccountAvatarResponse
    func accountAvatarContent() async throws -> WorkerAccountAvatarResponse
    func updateAccountAvatar(_ data: Data) async throws -> WorkerAccountAvatarResponse
    func removeAccountAvatar() async throws -> WorkerAccountAvatarResponse
}

extension IdentityWorkerClient: AccountAvatarRemoteClient {}

actor SupabaseAccountAvatarRemoteClient: AccountAvatarRemoteClient {
    private struct ProfileRow: Decodable, Sendable {
        let appAccountID: UUID
        let avatarDigest: String?
        let avatarRevision: Int64

        enum CodingKeys: String, CodingKey {
            case appAccountID = "app_account_id"
            case avatarDigest = "avatar_digest"
            case avatarRevision = "avatar_revision"
        }
    }

    private struct ProfileUpdate: Encodable, Sendable {
        let avatarDigest: String?
        let avatarRevision: Int64
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case avatarDigest = "avatar_digest"
            case avatarRevision = "avatar_revision"
            case updatedAt = "updated_at"
        }
    }

    private static let bucket = "account-avatars"
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func accountAvatarMetadata() async throws -> WorkerAccountAvatarResponse {
        let row = try await profile()
        return response(row: row, data: nil)
    }

    func accountAvatarContent() async throws -> WorkerAccountAvatarResponse {
        let (session, row) = try await sessionAndProfile()
        guard row.avatarDigest != nil else {
            return response(row: row, data: nil)
        }
        let data = try await client.storage
            .from(Self.bucket)
            .download(path: objectPath(userID: session.user.id))
        return response(row: row, data: data)
    }

    func updateAccountAvatar(_ data: Data) async throws -> WorkerAccountAvatarResponse {
        let (session, row) = try await sessionAndProfile()
        let digest = AccountAvatarCloudSyncService.digest(data)
        _ = try await client.storage
            .from(Self.bucket)
            .upload(
                objectPath(userID: session.user.id),
                data: data,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: "image/jpeg",
                    upsert: true
                )
            )
        let updated = try await updateProfile(
            userID: session.user.id,
            accountID: row.appAccountID,
            digest: digest,
            revision: row.avatarRevision + 1
        )
        return response(row: updated, data: nil)
    }

    func removeAccountAvatar() async throws -> WorkerAccountAvatarResponse {
        let (session, row) = try await sessionAndProfile()
        if row.avatarDigest != nil {
            _ = try await client.storage
                .from(Self.bucket)
                .remove(paths: [objectPath(userID: session.user.id)])
        }
        let updated = try await updateProfile(
            userID: session.user.id,
            accountID: row.appAccountID,
            digest: nil,
            revision: row.avatarRevision + 1
        )
        return response(row: updated, data: nil)
    }

    private func profile() async throws -> ProfileRow {
        let session = try await client.auth.session
        return try await profile(userID: session.user.id)
    }

    private func sessionAndProfile() async throws -> (Session, ProfileRow) {
        let session = try await client.auth.session
        return (session, try await profile(userID: session.user.id))
    }

    private func profile(userID: UUID) async throws -> ProfileRow {
        try await client
            .from("profiles")
            .select("app_account_id,avatar_digest,avatar_revision")
            .eq("user_id", value: userID)
            .single()
            .execute()
            .value
    }

    private func updateProfile(
        userID: UUID,
        accountID: UUID,
        digest: String?,
        revision: Int64
    ) async throws -> ProfileRow {
        try await client
            .from("profiles")
            .update(ProfileUpdate(
                avatarDigest: digest,
                avatarRevision: revision,
                updatedAt: .now
            ))
            .eq("user_id", value: userID)
            .select("app_account_id,avatar_digest,avatar_revision")
            .single()
            .execute()
            .value
    }

    private func objectPath(userID: UUID) -> String {
        "\(userID.uuidString.lowercased())/avatar.jpg"
    }

    private func response(row: ProfileRow, data: Data?) -> WorkerAccountAvatarResponse {
        WorkerAccountAvatarResponse(
            accountID: row.appAccountID,
            revision: row.avatarRevision,
            digest: row.avatarDigest,
            hasAvatar: row.avatarDigest != nil,
            dataBase64: data?.base64EncodedString()
        )
    }
}

enum AccountAvatarCloudSyncError: LocalizedError, Equatable {
    case accountMismatch
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .accountMismatch:
            "当前登录会话与本机账户不一致，请退出后重新登录。"
        case .malformedResponse:
            "云端头像内容校验失败，请稍后重试。"
        }
    }
}

@MainActor
final class AccountAvatarCloudSyncService {
    static let shared = AccountAvatarCloudSyncService()

    private let remoteOverride: (any AccountAvatarRemoteClient)?
    private var activeAccountIDs: Set<UUID> = []

    init(remote: (any AccountAvatarRemoteClient)? = nil) {
        remoteOverride = remote
    }

    func synchronize(account: AccountProfile, context: ModelContext) async throws {
        let remote = try activeRemote()
        let accountID = account.effectiveAccountID
        guard activeAccountIDs.insert(accountID).inserted else { return }
        defer { activeAccountIDs.remove(accountID) }

        let metadata = try await remote.accountAvatarMetadata()
        try validateAccount(metadata, expected: accountID)

        guard let remoteRevision = metadata.revision else {
            if let localData = account.avatarImageData {
                try await uploadUnlocked(
                    localData,
                    account: account,
                    context: context,
                    remote: remote
                )
            }
            return
        }

        let localRevision = account.avatarCloudRevision
        let localDigest = account.avatarImageData.map(Self.digest)
        let remoteChanged = localRevision != remoteRevision ||
            account.avatarCloudDigest != metadata.digest ||
            metadata.hasAvatar != (account.avatarImageData != nil) ||
            (metadata.hasAvatar && localDigest != metadata.digest)
        guard remoteChanged else { return }

        if metadata.hasAvatar {
            let content = try await remote.accountAvatarContent()
            try validateAccount(content, expected: accountID)
            guard content.revision == remoteRevision,
                  content.hasAvatar,
                  let encoded = content.dataBase64,
                  let data = Data(base64Encoded: encoded),
                  Self.isJPEG(data),
                  Self.digest(data) == content.digest else {
                throw AccountAvatarCloudSyncError.malformedResponse
            }
            account.avatarImageData = data
            account.avatarCloudDigest = content.digest
            account.avatarCloudRevision = content.revision
        } else {
            account.avatarImageData = nil
            account.avatarCloudDigest = nil
            account.avatarCloudRevision = remoteRevision
        }
        account.updatedAt = .now
        try context.save()
    }

    func upload(_ data: Data, account: AccountProfile, context: ModelContext) async throws {
        let remote = try activeRemote()
        let accountID = account.effectiveAccountID
        try await acquire(accountID)
        defer { activeAccountIDs.remove(accountID) }
        try await uploadUnlocked(
            data,
            account: account,
            context: context,
            remote: remote
        )
    }

    private func uploadUnlocked(
        _ data: Data,
        account: AccountProfile,
        context: ModelContext,
        remote: any AccountAvatarRemoteClient
    ) async throws {
        guard let cloudData = Self.cloudJPEGData(from: data) else {
            throw AccountAvatarCloudSyncError.malformedResponse
        }
        let response = try await remote.updateAccountAvatar(cloudData)
        try validateAccount(response, expected: account.effectiveAccountID)
        guard response.hasAvatar,
              let revision = response.revision,
              response.digest == Self.digest(cloudData) else {
            throw AccountAvatarCloudSyncError.malformedResponse
        }
        account.avatarImageData = cloudData
        account.avatarCloudDigest = response.digest
        account.avatarCloudRevision = revision
        account.updatedAt = .now
        try context.save()
    }

    func remove(account: AccountProfile, context: ModelContext) async throws {
        let remote = try activeRemote()
        let accountID = account.effectiveAccountID
        try await acquire(accountID)
        defer { activeAccountIDs.remove(accountID) }
        let response = try await remote.removeAccountAvatar()
        try validateAccount(response, expected: account.effectiveAccountID)
        guard !response.hasAvatar, let revision = response.revision else {
            throw AccountAvatarCloudSyncError.malformedResponse
        }
        account.avatarImageData = nil
        account.avatarCloudDigest = nil
        account.avatarCloudRevision = revision
        account.updatedAt = .now
        try context.save()
    }

    private func validateAccount(_ response: WorkerAccountAvatarResponse, expected accountID: UUID) throws {
        guard response.accountID == accountID else {
            throw AccountAvatarCloudSyncError.accountMismatch
        }
    }

    private func activeRemote() throws -> any AccountAvatarRemoteClient {
        if let remoteOverride { return remoteOverride }
        if AccountIdentityClients.activeProvider == .supabase {
            guard let client = AccountIdentityClients.supabaseClient else {
                throw AccountIdentityClientError.notConfigured
            }
            return SupabaseAccountAvatarRemoteClient(client: client)
        }
        return IdentityWorkerClient.shared
    }

    private func acquire(_ accountID: UUID) async throws {
        while activeAccountIDs.contains(accountID) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        activeAccountIDs.insert(accountID)
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count >= 4 &&
            data[data.startIndex] == 0xFF &&
            data[data.index(after: data.startIndex)] == 0xD8 &&
            data[data.index(data.endIndex, offsetBy: -2)] == 0xFF &&
            data[data.index(before: data.endIndex)] == 0xD9
    }

    static func cloudJPEGData(from data: Data, maximumByteCount: Int = 60 * 1024) -> Data? {
        if data.count <= maximumByteCount, isJPEG(data) {
            return data
        }
        guard let source = UIImage(data: data) else { return nil }
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        for side in [384, 320, 256, 192] {
            let targetSide = CGFloat(side)
            let scale = max(targetSide / sourceSize.width, targetSide / sourceSize.height)
            let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let origin = CGPoint(
                x: (targetSide - drawSize.width) / 2,
                y: (targetSide - drawSize.height) / 2
            )
            let format = UIGraphicsImageRendererFormat.preferred()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(
                size: CGSize(width: targetSide, height: targetSide),
                format: format
            ).image { context in
                UIColor.systemBackground.setFill()
                context.fill(CGRect(x: 0, y: 0, width: targetSide, height: targetSide))
                source.draw(in: CGRect(origin: origin, size: drawSize))
            }
            for quality in [0.82, 0.72, 0.62, 0.52] {
                if let candidate = rendered.jpegData(compressionQuality: quality),
                   candidate.count <= maximumByteCount {
                    return candidate
                }
            }
        }
        return nil
    }
}
