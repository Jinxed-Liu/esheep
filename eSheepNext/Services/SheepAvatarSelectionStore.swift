import Foundation
import SwiftData

enum SheepAvatarSelectionError: LocalizedError {
    case photoUnavailable
    case photoBelongsToAnotherSheep

    var errorDescription: String? {
        switch self {
        case .photoUnavailable:
            "所选照片不存在或已经删除。"
        case .photoBelongsToAnotherSheep:
            "只能使用当前羊只自己的照片作为头像。"
        }
    }
}

enum SheepAvatarSelectionStore {
    enum PhotoAdditionPlan: Sendable, Equatable {
        case keepCurrentChoice
        case selectExisting(UUID)
        case selectNewIfOnlyPhoto
    }

    static func validate(
        _ update: SheepAvatarPhotoUpdate,
        sheepID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws {
        guard let photoAssetID = update.photoAssetID else { return }
        guard let photo = try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.id == photoAssetID && $0.farmID == farmID && $0.deletedAt == nil
        })).first else {
            throw SheepAvatarSelectionError.photoUnavailable
        }
        guard photo.sheepID == sheepID else {
            throw SheepAvatarSelectionError.photoBelongsToAnotherSheep
        }
    }

    static func apply(
        _ update: SheepAvatarPhotoUpdate,
        sheepID: UUID,
        farmID: UUID,
        updatedAt: Date = .now,
        context: ModelContext
    ) throws {
        let selections = try context.fetch(FetchDescriptor<SheepAvatarRecord>(predicate: #Predicate {
            $0.sheepID == sheepID && $0.farmID == farmID
        }))
        if let selection = selections.max(by: { $0.updatedAt < $1.updatedAt }) {
            selection.photoAssetID = update.photoAssetID
            selection.updatedAt = updatedAt
            for duplicate in selections where duplicate.id != selection.id {
                context.delete(duplicate)
            }
        } else {
            context.insert(SheepAvatarRecord(
                farmID: farmID,
                sheepID: sheepID,
                photoAssetID: update.photoAssetID,
                updatedAt: updatedAt
            ))
        }
    }

    static func reference(
        sheepID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> SheepPhotoReference? {
        let selections = try context.fetch(FetchDescriptor<SheepAvatarRecord>(predicate: #Predicate {
            $0.sheepID == sheepID && $0.farmID == farmID
        }))
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.sheepID == sheepID && $0.farmID == farmID && $0.deletedAt == nil
        }))
        return resolvedReference(
            selection: latestSelection(in: selections),
            photosByID: uniquePhotosByID(photos)
        )
    }

    static func references(
        farmID: UUID,
        context: ModelContext
    ) throws -> [UUID: SheepPhotoReference] {
        let selections = try context.fetch(FetchDescriptor<SheepAvatarRecord>(predicate: #Predicate {
            $0.farmID == farmID
        }))
        let activePhotos = try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.deletedAt == nil
        }))

        var photosBySheepID: [UUID: [UUID: PhotoAssetRecord]] = [:]
        for photo in activePhotos {
            guard let sheepID = photo.sheepID else { continue }
            photosBySheepID[sheepID, default: [:]][photo.id] = photo
        }
        var latestSelectionBySheepID: [UUID: SheepAvatarRecord] = [:]
        for selection in selections {
            if let current = latestSelectionBySheepID[selection.sheepID],
               !isNewer(selection, than: current) {
                continue
            }
            latestSelectionBySheepID[selection.sheepID] = selection
        }

        var result: [UUID: SheepPhotoReference] = [:]
        let sheepIDs = Set(latestSelectionBySheepID.keys).union(photosBySheepID.keys)
        for sheepID in sheepIDs {
            if let reference = resolvedReference(
                selection: latestSelectionBySheepID[sheepID],
                photosByID: photosBySheepID[sheepID] ?? [:]
            ) {
                result[sheepID] = reference
            }
        }
        return result
    }

    /// Captures the implicit avatar before a new photo is committed. This lets
    /// the first automatically selected photo remain the avatar when a second
    /// photo is later added, while still respecting an explicit system-default
    /// selection.
    static func photoAdditionPlan(
        sheepID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> PhotoAdditionPlan {
        let selections = try context.fetch(FetchDescriptor<SheepAvatarRecord>(predicate: #Predicate {
            $0.sheepID == sheepID && $0.farmID == farmID
        }))
        let selection = latestSelection(in: selections)
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.sheepID == sheepID && $0.farmID == farmID && $0.deletedAt == nil
        }))
        let photosByID = uniquePhotosByID(photos)

        if let selection {
            guard let selectedID = selection.photoAssetID else {
                return .keepCurrentChoice
            }
            if photosByID[selectedID] != nil {
                return .keepCurrentChoice
            }
        }
        if let onlyPhotoID = photosByID.keys.first, photosByID.count == 1 {
            return .selectExisting(onlyPhotoID)
        }
        return photosByID.isEmpty ? .selectNewIfOnlyPhoto : .keepCurrentChoice
    }

    /// Revalidates the pre-addition plan against a fresh context after the
    /// photo actor commits. A concurrent explicit avatar/default choice wins.
    static func automaticSelectionAfterAdding(
        photoAssetID: UUID,
        plan: PhotoAdditionPlan,
        sheepID: UUID,
        farmID: UUID,
        context: ModelContext
    ) throws -> UUID? {
        guard plan != .keepCurrentChoice else { return nil }

        let selections = try context.fetch(FetchDescriptor<SheepAvatarRecord>(predicate: #Predicate {
            $0.sheepID == sheepID && $0.farmID == farmID
        }))
        let selection = latestSelection(in: selections)
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.sheepID == sheepID && $0.farmID == farmID && $0.deletedAt == nil
        }))
        let photosByID = uniquePhotosByID(photos)

        if let selection {
            guard let selectedID = selection.photoAssetID else { return nil }
            if photosByID[selectedID] != nil { return nil }
        }

        switch plan {
        case .keepCurrentChoice:
            return nil
        case .selectExisting(let existingID):
            if photosByID[existingID] != nil { return existingID }
            return photosByID.count == 1 ? photosByID.keys.first : nil
        case .selectNewIfOnlyPhoto:
            guard photosByID.count == 1, photosByID[photoAssetID] != nil else {
                return nil
            }
            return photoAssetID
        }
    }

    private static func resolvedReference(
        selection: SheepAvatarRecord?,
        photosByID: [UUID: PhotoAssetRecord]
    ) -> SheepPhotoReference? {
        if let selection {
            // A nil asset ID is an explicit request to use the system avatar.
            guard let selectedID = selection.photoAssetID else { return nil }
            if let selectedPhoto = photosByID[selectedID] {
                return reference(to: selectedPhoto)
            }
        }
        guard photosByID.count == 1, let onlyPhoto = photosByID.values.first else {
            return nil
        }
        return reference(to: onlyPhoto)
    }

    private static func reference(to photo: PhotoAssetRecord) -> SheepPhotoReference {
        SheepPhotoReference(id: photo.id, digest: photo.sha256)
    }

    private static func uniquePhotosByID(
        _ photos: [PhotoAssetRecord]
    ) -> [UUID: PhotoAssetRecord] {
        var result: [UUID: PhotoAssetRecord] = [:]
        for photo in photos {
            result[photo.id] = photo
        }
        return result
    }

    private static func latestSelection(
        in selections: [SheepAvatarRecord]
    ) -> SheepAvatarRecord? {
        selections.max { lhs, rhs in
            isNewer(rhs, than: lhs)
        }
    }

    private static func isNewer(
        _ candidate: SheepAvatarRecord,
        than current: SheepAvatarRecord
    ) -> Bool {
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }
        return candidate.id.uuidString > current.id.uuidString
    }
}
