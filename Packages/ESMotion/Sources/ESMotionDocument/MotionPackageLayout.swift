import Foundation

public struct MotionIntegrityEntry: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let byteCount: Int

    public init(path: String, sha256: String, byteCount: Int) {
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public struct MotionIntegrityManifest: Codable, Equatable, Sendable {
    public let algorithm: String
    public let entries: [MotionIntegrityEntry]

    public init(
        algorithm: String = "SHA-256",
        entries: [MotionIntegrityEntry]
    ) {
        self.algorithm = algorithm
        self.entries = entries.sorted { $0.path < $1.path }
    }
}

public struct MotionPackageLayout: Equatable, Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var manifestURL: URL {
        rootURL.appending(path: "manifest.json")
    }

    public var assetsURL: URL {
        rootURL.appending(path: "assets", directoryHint: .isDirectory)
    }

    public var previewsURL: URL {
        rootURL.appending(path: "previews", directoryHint: .isDirectory)
    }

    public var integrityURL: URL {
        rootURL.appending(path: "integrity.json")
    }

    public func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: assetsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: previewsURL,
            withIntermediateDirectories: true
        )
    }
}
