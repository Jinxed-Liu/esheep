import Foundation

enum LegacyPhotoFilenameIdentity {
    private static let imageFileExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    /// Returns an ear tag only when the source name is recognizably an image
    /// filename. Non-image suffixes remain untouched by the importer.
    static func earTag(from sourceName: String) -> String? {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = URL(fileURLWithPath: trimmed).lastPathComponent
        let pathExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard imageFileExtensions.contains(pathExtension) else { return nil }
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? nil : stem
    }
}
