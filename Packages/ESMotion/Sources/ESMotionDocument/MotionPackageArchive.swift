import CryptoKit
import Foundation

public enum MotionPackageArchiveError: LocalizedError {
    case missingManifest
    case archiveTooLarge
    case invalidArchive
    case unsupportedCompression
    case unsafePath(String)
    case integrityMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            "The motion package does not contain manifest.json."
        case .archiveTooLarge:
            "The motion package exceeds the ZIP32 size limit."
        case .invalidArchive:
            "The motion package archive is invalid or truncated."
        case .unsupportedCompression:
            "This motion package uses an unsupported compression method."
        case .unsafePath(let path):
            "The motion package contains an unsafe path: \(path)."
        case .integrityMismatch(let path):
            "Integrity verification failed for \(path)."
        }
    }
}

public enum MotionPackageArchive {
    public static func pack(
        directory rootURL: URL,
        to archiveURL: URL
    ) throws {
        let layout = MotionPackageLayout(rootURL: rootURL)
        guard FileManager.default.fileExists(
            atPath: layout.manifestURL.path
        ) else {
            throw MotionPackageArchiveError.missingManifest
        }

        try writeIntegrityManifest(for: layout)
        let files = try packageFiles(in: layout.rootURL)
        var archive = Data()
        var centralDirectory = Data()
        var records: [CentralRecord] = []

        for file in files {
            let contents = try Data(
                contentsOf: file.url,
                options: [.mappedIfSafe]
            )
            guard contents.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw MotionPackageArchiveError.archiveTooLarge
            }
            let nameData = Data(file.path.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw MotionPackageArchiveError.archiveTooLarge
            }
            let checksum = CRC32.checksum(contents)
            let localOffset = UInt32(archive.count)

            archive.appendLittleEndian(UInt32(0x04034B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0x0021))
            archive.appendLittleEndian(checksum)
            archive.appendLittleEndian(UInt32(contents.count))
            archive.appendLittleEndian(UInt32(contents.count))
            archive.appendLittleEndian(UInt16(nameData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(nameData)
            archive.append(contents)

            records.append(
                CentralRecord(
                    nameData: nameData,
                    checksum: checksum,
                    size: UInt32(contents.count),
                    localOffset: localOffset
                )
            )
        }

        for record in records {
            centralDirectory.appendLittleEndian(UInt32(0x02014B50))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(0x0800))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0x0021))
            centralDirectory.appendLittleEndian(record.checksum)
            centralDirectory.appendLittleEndian(record.size)
            centralDirectory.appendLittleEndian(record.size)
            centralDirectory.appendLittleEndian(
                UInt16(record.nameData.count)
            )
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt32(0))
            centralDirectory.appendLittleEndian(record.localOffset)
            centralDirectory.append(record.nameData)
        }

        guard records.count <= Int(UInt16.max),
              archive.count <= Int(UInt32.max),
              centralDirectory.count <= Int(UInt32.max) else {
            throw MotionPackageArchiveError.archiveTooLarge
        }
        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLittleEndian(UInt32(0x06054B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(records.count))
        archive.appendLittleEndian(UInt16(records.count))
        archive.appendLittleEndian(UInt32(centralDirectory.count))
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0))
        try archive.write(to: archiveURL, options: [.atomic])
    }

    public static func unpack(
        _ archiveURL: URL,
        to destinationURL: URL
    ) throws {
        let archive = try Data(
            contentsOf: archiveURL,
            options: [.mappedIfSafe]
        )
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )

        var cursor = 0
        while cursor + 4 <= archive.count {
            let signature: UInt32 = try archive.readLittleEndian(
                at: &cursor
            )
            guard signature == 0x04034B50 else {
                if signature == 0x02014B50 || signature == 0x06054B50 {
                    break
                }
                throw MotionPackageArchiveError.invalidArchive
            }

            _ = try archive.readLittleEndian(at: &cursor) as UInt16
            _ = try archive.readLittleEndian(at: &cursor) as UInt16
            let compression: UInt16 = try archive.readLittleEndian(
                at: &cursor
            )
            guard compression == 0 else {
                throw MotionPackageArchiveError.unsupportedCompression
            }
            _ = try archive.readLittleEndian(at: &cursor) as UInt16
            _ = try archive.readLittleEndian(at: &cursor) as UInt16
            let expectedCRC: UInt32 = try archive.readLittleEndian(
                at: &cursor
            )
            let compressedSize: UInt32 = try archive.readLittleEndian(
                at: &cursor
            )
            let uncompressedSize: UInt32 = try archive.readLittleEndian(
                at: &cursor
            )
            guard compressedSize == uncompressedSize else {
                throw MotionPackageArchiveError.unsupportedCompression
            }
            let nameLength: UInt16 = try archive.readLittleEndian(
                at: &cursor
            )
            let extraLength: UInt16 = try archive.readLittleEndian(
                at: &cursor
            )
            let nameData = try archive.slice(
                at: &cursor,
                count: Int(nameLength)
            )
            guard let path = String(data: nameData, encoding: .utf8) else {
                throw MotionPackageArchiveError.invalidArchive
            }
            try validate(relativePath: path)
            _ = try archive.slice(at: &cursor, count: Int(extraLength))
            let contents = try archive.slice(
                at: &cursor,
                count: Int(uncompressedSize)
            )
            guard CRC32.checksum(contents) == expectedCRC else {
                throw MotionPackageArchiveError.integrityMismatch(path)
            }

            let outputURL = destinationURL.appending(path: path)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: outputURL, options: [.atomic])
        }

        let layout = MotionPackageLayout(rootURL: destinationURL)
        guard FileManager.default.fileExists(
            atPath: layout.manifestURL.path
        ) else {
            throw MotionPackageArchiveError.missingManifest
        }
        try verifyIntegrity(in: layout)
    }

    public static func verifyIntegrity(
        in layout: MotionPackageLayout
    ) throws {
        let data = try Data(contentsOf: layout.integrityURL)
        let integrity = try JSONDecoder().decode(
            MotionIntegrityManifest.self,
            from: data
        )
        guard integrity.algorithm == "SHA-256" else {
            throw MotionPackageArchiveError.invalidArchive
        }

        for entry in integrity.entries {
            try validate(relativePath: entry.path)
            let url = layout.rootURL.appending(path: entry.path)
            let contents = try Data(
                contentsOf: url,
                options: [.mappedIfSafe]
            )
            guard contents.count == entry.byteCount,
                  sha256(contents) == entry.sha256 else {
                throw MotionPackageArchiveError.integrityMismatch(
                    entry.path
                )
            }
        }
    }

    private static func writeIntegrityManifest(
        for layout: MotionPackageLayout
    ) throws {
        let files = try packageFiles(in: layout.rootURL).filter {
            $0.path != "integrity.json"
        }
        let entries = try files.map { file in
            let data = try Data(
                contentsOf: file.url,
                options: [.mappedIfSafe]
            )
            return MotionIntegrityEntry(
                path: file.path,
                sha256: sha256(data),
                byteCount: data.count
            )
        }
        let manifest = MotionIntegrityManifest(entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        try encoder.encode(manifest).write(
            to: layout.integrityURL,
            options: [.atomic]
        )
    }

    private static func packageFiles(
        in rootURL: URL
    ) throws -> [(path: String, url: URL)] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isHiddenKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let rootPath = rootURL.standardizedFileURL.path
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true,
                  values.isHidden != true else {
                continue
            }
            let standardizedPath = url.standardizedFileURL.path
            guard standardizedPath.hasPrefix(rootPath + "/") else {
                throw MotionPackageArchiveError.unsafePath(
                    standardizedPath
                )
            }
            let relative = String(
                standardizedPath.dropFirst(rootPath.count + 1)
            )
            try validate(relativePath: relative)
            files.append((relative, url))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    private static func validate(relativePath: String) throws {
        let components = relativePath.split(separator: "/")
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(".."),
              !components.contains(".") else {
            throw MotionPackageArchiveError.unsafePath(relativePath)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct CentralRecord {
    let nameData: Data
    let checksum: UInt32
    let size: UInt32
    let localOffset: UInt32
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            var current = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0 ..< 8 {
                current = current & 1 == 1
                    ? (current >> 1) ^ 0xEDB88320
                    : current >> 1
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    func readLittleEndian<T: FixedWidthInteger>(
        at cursor: inout Int
    ) throws -> T {
        let byteCount = MemoryLayout<T>.size
        let bytes = try slice(at: &cursor, count: byteCount)
        return bytes.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: T.self).littleEndian
        }
    }

    func slice(
        at cursor: inout Int,
        count: Int
    ) throws -> Data {
        guard count >= 0, cursor >= 0, cursor + count <= self.count else {
            throw MotionPackageArchiveError.invalidArchive
        }
        defer { cursor += count }
        return subdata(in: cursor ..< (cursor + count))
    }
}
