import Foundation
import SwiftData

/// The selected profile photo is a farm-domain preference, not another copy of
/// the image. The photo bytes and deletion/recovery lifecycle remain owned by
/// `PhotoAssetRecord`.
@Model
final class SheepAvatarRecord {
    var id: UUID
    var farmID: UUID
    var sheepID: UUID
    var photoAssetID: UUID?
    var updatedAt: Date

    init(
        id: UUID? = nil,
        farmID: UUID,
        sheepID: UUID,
        photoAssetID: UUID?,
        updatedAt: Date = .now
    ) {
        self.id = id ?? sheepID
        self.farmID = farmID
        self.sheepID = sheepID
        self.photoAssetID = photoAssetID
        self.updatedAt = updatedAt
    }
}

struct SheepAvatarPhotoUpdate: Sendable, Equatable {
    let photoAssetID: UUID?
}

struct SheepPhotoReference: Identifiable, Sendable, Hashable {
    let id: UUID
    let digest: String
}

enum SheepAvatarCloudPayload {
    static let selectionVersionKey = "sheepAvatarSelectionVersion"
    static let photoAssetIDKey = "sheepAvatarPhotoAssetID"

    static func write(
        _ update: SheepAvatarPhotoUpdate,
        to payload: inout FarmCommandCloudPayload
    ) {
        payload.integers[selectionVersionKey] = 1
        payload.optionalIdentifiers[photoAssetIDKey] = update.photoAssetID
    }

    static func update(from payload: FarmCommandCloudPayload) -> SheepAvatarPhotoUpdate? {
        guard payload.integers[selectionVersionKey] == 1 else { return nil }
        return SheepAvatarPhotoUpdate(
            photoAssetID: payload.optionalIdentifiers[photoAssetIDKey] ?? nil
        )
    }
}
