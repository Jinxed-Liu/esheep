import Foundation

public enum MotionDocumentCodec {
    public static func encode(_ document: MotionDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> MotionDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(MotionDocument.self, from: data)
        return try MotionDocumentMigrator.migrate(document)
    }

    public static func load(from url: URL) throws -> MotionDocument {
        try decode(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func save(
        _ document: MotionDocument,
        to url: URL
    ) throws {
        try encode(document).write(to: url, options: [.atomic])
    }
}

public enum MotionDocumentMigrationError: LocalizedError {
    case newerMajorVersion(found: MotionDocumentVersion)

    public var errorDescription: String? {
        switch self {
        case .newerMajorVersion(let found):
            "Document version \(found.major).\(found.minor) is newer than this runtime."
        }
    }
}

public enum MotionDocumentMigrator {
    public static func migrate(
        _ document: MotionDocument
    ) throws -> MotionDocument {
        guard document.version.major <= MotionDocumentVersion.current.major else {
            throw MotionDocumentMigrationError.newerMajorVersion(
                found: document.version
            )
        }

        var migrated = document
        migrated.version = .current
        return migrated
    }
}
