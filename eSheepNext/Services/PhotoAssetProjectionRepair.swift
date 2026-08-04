import Foundation
import SwiftData

struct PhotoAssetProjectionRepairReport: Sendable, Equatable {
    let tombstoneRepairedCount: Int
    let duplicateRemovedCount: Int
}

/// Repairs the local photo projection without changing cloud identity or
/// deleting photo bytes. Photo IDs are immutable domain identities; multiple
/// SwiftData rows carrying the same farm/photo ID are projection corruption.
enum PhotoAssetProjectionRepair {
    private struct Key: Hashable {
        let farmID: UUID
        let photoID: UUID
    }

    @discardableResult
    static func repair(container: ModelContainer) throws -> PhotoAssetProjectionRepairReport {
        let context = ModelContext(container)
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
        let tombstones = try context.fetch(FetchDescriptor<TombstoneRecord>())

        var latestStateByKey: [Key: (occurredAt: Date, deletedAt: Date?)] = [:]
        for tombstone in tombstones where
            tombstone.entityType == CloudEntityType.photoAsset.rawValue {
            let key = Key(farmID: tombstone.farmID, photoID: tombstone.entityID)
            if tombstone.deletedAt > (latestStateByKey[key]?.occurredAt ?? .distantPast) {
                latestStateByKey[key] = (tombstone.deletedAt, tombstone.deletedAt)
            }
            if let restoredAt = tombstone.restoredAt,
               restoredAt >= (latestStateByKey[key]?.occurredAt ?? .distantPast) {
                latestStateByKey[key] = (restoredAt, nil)
            }
        }

        var tombstoneRepairedCount = 0
        for photo in photos {
            let key = Key(farmID: photo.farmID, photoID: photo.id)
            guard let state = latestStateByKey[key],
                  photo.deletedAt != state.deletedAt else { continue }
            photo.deletedAt = state.deletedAt
            tombstoneRepairedCount += 1
        }

        let groups = Dictionary(grouping: photos) {
            Key(farmID: $0.farmID, photoID: $0.id)
        }
        var duplicateRemovedCount = 0
        for records in groups.values where records.count > 1 {
            let survivor = preferredRecord(in: records)
            merge(records, into: survivor)
            for duplicate in records where duplicate !== survivor {
                context.delete(duplicate)
                duplicateRemovedCount += 1
            }
        }

        if tombstoneRepairedCount > 0 || duplicateRemovedCount > 0 {
            try context.save()
        }
        return PhotoAssetProjectionRepairReport(
            tombstoneRepairedCount: tombstoneRepairedCount,
            duplicateRemovedCount: duplicateRemovedCount
        )
    }

    private static func preferredRecord(
        in records: [PhotoAssetRecord]
    ) -> PhotoAssetRecord {
        records.sorted { lhs, rhs in
            let lhsScore = preferenceScore(lhs)
            let rhsScore = preferenceScore(rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.createdAt < rhs.createdAt
        }[0]
    }

    private static func preferenceScore(_ photo: PhotoAssetRecord) -> Int {
        var score = 0
        if hasVerifiedLocalFile(photo) { score += 16 }
        if !photo.relativePath.isEmpty { score += 8 }
        if photo.deletedAt == nil { score += 4 }
        if photo.isCloudAuthoritative { score += 2 }
        if photo.cloudRecordName != nil { score += 1 }
        return score
    }

    private static func merge(
        _ records: [PhotoAssetRecord],
        into survivor: PhotoAssetRecord
    ) {
        let hadActiveProjection = records.contains { $0.deletedAt == nil }
        let latestDeletedAt = records.compactMap(\.deletedAt).max()

        for source in records where source !== survivor {
            if survivor.sheepID == nil { survivor.sheepID = source.sheepID }
            if survivor.originalEarTag.isEmpty {
                survivor.originalEarTag = source.originalEarTag
            }
            if survivor.sourceSHA256.isEmpty {
                survivor.sourceSHA256 = source.sourceSHA256
            }
            if survivor.sourcePixelWidth == 0 {
                survivor.sourcePixelWidth = source.sourcePixelWidth
            }
            if survivor.sourcePixelHeight == 0 {
                survivor.sourcePixelHeight = source.sourcePixelHeight
            }
            if survivor.cloudPixelWidth == 0 {
                survivor.cloudPixelWidth = source.cloudPixelWidth
            }
            if survivor.cloudPixelHeight == 0 {
                survivor.cloudPixelHeight = source.cloudPixelHeight
            }
            if survivor.capturedAt == nil { survivor.capturedAt = source.capturedAt }
            if survivor.cloudRecordName == nil {
                survivor.cloudRecordName = source.cloudRecordName
            }
            if survivor.recoveryRecordName == nil {
                survivor.recoveryRecordName = source.recoveryRecordName
            }
            if survivor.recoveryBackedUpAt == nil {
                survivor.recoveryBackedUpAt = source.recoveryBackedUpAt
            }
            survivor.isCloudAuthoritative =
                survivor.isCloudAuthoritative || source.isCloudAuthoritative
            survivor.createdAt = min(survivor.createdAt, source.createdAt)

            if !hasVerifiedLocalFile(survivor), hasVerifiedLocalFile(source) {
                survivor.relativePath = source.relativePath
                survivor.sha256 = source.sha256
                survivor.mimeType = source.mimeType
            }
        }
        survivor.deletedAt = hadActiveProjection ? nil : latestDeletedAt
    }

    private static func hasVerifiedLocalFile(_ photo: PhotoAssetRecord) -> Bool {
        guard !photo.relativePath.isEmpty else { return false }
        let url = PhotoTransferActor.absoluteURL(for: photo.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? PhotoTransferActor.digest(url)) == photo.sha256
    }
}
