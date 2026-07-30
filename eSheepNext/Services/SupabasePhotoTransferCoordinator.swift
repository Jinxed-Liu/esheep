import Foundation
import SwiftData
import Supabase

actor SupabasePhotoTransferCoordinator {
    private struct AssetRow: Decodable, Sendable {
        let assetID: UUID
        let farmID: UUID
        let sha256: String
        let storagePath: String
        let byteCount: Int64
        let contentType: String

        enum CodingKeys: String, CodingKey {
            case assetID = "asset_id"
            case farmID = "farm_id"
            case sha256
            case storagePath = "storage_path"
            case byteCount = "byte_count"
            case contentType = "content_type"
        }
    }

    private let container: ModelContainer
    private let client: SupabaseClient
    private let transport: SupabaseFarmTransport
    private let localPhotos: PhotoTransferActor
    private var didRecoverInterruptedTransfers = false

    init(
        container: ModelContainer,
        client: SupabaseClient,
        localPhotos: PhotoTransferActor
    ) {
        self.container = container
        self.client = client
        self.transport = SupabaseFarmTransport(client: client)
        self.localPhotos = localPhotos
    }

    func processPendingTransfers() async {
        let context = ModelContext(container)
        let activeFarmIDs = Set(
            ((try? context.fetch(FetchDescriptor<FarmRemoteBinding>())) ?? [])
                .filter { $0.provider == .supabase && $0.state == .active }
                .map(\.farmID)
        )
        guard !activeFarmIDs.isEmpty else { return }
        if !didRecoverInterruptedTransfers {
            didRecoverInterruptedTransfers = true
            let interrupted = ((try? context.fetch(
                FetchDescriptor<CloudAssetTransfer>()
            )) ?? []).filter {
                activeFarmIDs.contains($0.farmID) &&
                    PhotoTransferInterruptionPolicy.shouldRequeue(status: $0.status)
            }
            for transfer in interrupted {
                transfer.statusRawValue = CloudAssetTransferStatus.pending.rawValue
                transfer.lastErrorCode = "上次 Supabase 照片传输被中断，已自动恢复。"
                transfer.nextRetryAt = nil
                transfer.updatedAt = .now
            }
            if !interrupted.isEmpty { try? context.save() }
        }

        let pending = ((try? context.fetch(
            FetchDescriptor<CloudAssetTransfer>()
        )) ?? []).filter {
            activeFarmIDs.contains($0.farmID) &&
                ($0.status == .pending || $0.status == .failed) &&
                ($0.nextRetryAt == nil || $0.nextRetryAt! <= .now)
        }
        for transfer in pending {
            do {
                try await process(transferID: transfer.id)
            } catch {
                // Persisted retry state is the recovery boundary.
            }
        }
    }

    private func process(transferID: UUID) async throws {
        let context = ModelContext(container)
        guard let transfer = try context.fetch(FetchDescriptor<CloudAssetTransfer>())
            .first(where: { $0.id == transferID }),
              let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                  .first(where: { $0.id == transfer.assetID }),
              let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
                  .first(where: {
                      $0.farmID == transfer.farmID &&
                          $0.provider == .supabase &&
                          $0.state == .active
                  }) else {
            throw PhotoTransferError.assetMissing
        }
        transfer.statusRawValue = transfer.direction == .upload
            ? CloudAssetTransferStatus.uploading.rawValue
            : CloudAssetTransferStatus.downloading.rawValue
        transfer.attemptCount += 1
        transfer.updatedAt = .now
        try context.save()

        do {
            switch transfer.direction {
            case .upload:
                let data = try await localPhotos.localFileData(assetID: asset.id)
                let remote = try await transport.uploadAsset(
                    farmID: asset.farmID,
                    authorityGeneration: binding.authorityGeneration,
                    assetID: asset.id,
                    data: data,
                    sha256: asset.sha256,
                    contentType: asset.mimeType
                )
                asset.cloudRecordName = remote.storagePath
                asset.isCloudAuthoritative = true
                transfer.remoteRecordName = remote.storagePath
                transfer.transferredByteCount = remote.byteCount
            case .download:
                let rows: [AssetRow] = try await client
                    .from("farm_assets")
                    .select("asset_id,farm_id,sha256,storage_path,byte_count,content_type")
                    .eq("farm_id", value: asset.farmID)
                    .eq("asset_id", value: asset.id)
                    .limit(1)
                    .execute()
                    .value
                guard let row = rows.first else {
                    throw PhotoTransferError.remoteAssetMissing
                }
                let remote = FarmRemoteAsset(
                    assetID: row.assetID,
                    farmID: row.farmID,
                    sha256: row.sha256,
                    byteCount: row.byteCount,
                    contentType: row.contentType,
                    storagePath: row.storagePath
                )
                let data = try await transport.downloadAsset(remote)
                let fileExtension = row.contentType == "image/heic" ? "heic" : "jpg"
                let destination = try PhotoTransferActor.assetURL(
                    farmID: asset.farmID,
                    assetID: asset.id,
                    fileExtension: fileExtension
                )
                try data.write(to: destination, options: [.atomic, .completeFileProtection])
                asset.relativePath = PhotoTransferActor.relativePath(for: destination)
                asset.cloudRecordName = remote.storagePath
                asset.isCloudAuthoritative = true
                transfer.localRelativePath = asset.relativePath
                transfer.remoteRecordName = remote.storagePath
                transfer.transferredByteCount = remote.byteCount
            case .recoveryBackup, .recoveryRestore:
                return
            }
            transfer.statusRawValue = CloudAssetTransferStatus.completed.rawValue
            transfer.lastErrorCode = nil
            transfer.nextRetryAt = nil
            transfer.updatedAt = .now
            try context.save()
        } catch {
            transfer.statusRawValue = CloudAssetTransferStatus.failed.rawValue
            transfer.lastErrorCode = error.localizedDescription
            transfer.nextRetryAt = .now.addingTimeInterval(
                Self.retryDelay(attemptCount: transfer.attemptCount)
            )
            transfer.updatedAt = .now
            try? context.save()
            throw error
        }
    }

    private static func retryDelay(attemptCount: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [5, 15, 30, 60, 120, 300]
        return schedule[min(max(0, attemptCount - 1), schedule.count - 1)]
    }
}
