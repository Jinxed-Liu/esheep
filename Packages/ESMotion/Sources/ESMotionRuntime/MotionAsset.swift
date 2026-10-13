import ESMotionDocument
import Foundation

public enum MotionAsset: Hashable, Sendable {
    case lottie(MotionLottieSource)
    case image(name: String)
    case symbol(name: String)
    case text(String)
    case metalScene(id: String)
    case document(URL)
}

public enum MotionLottieSource: Hashable, Sendable {
    case named(String)
    case localFile(URL)
    case remote(URL)
}

public enum MotionLottieLoopMode: Hashable, Sendable {
    case playOnce
    case loop
    case autoReverse
}

public enum MotionLottiePlayback: Hashable, Sendable {
    case paused(progress: Double)
    case playing(
        fromProgress: Double,
        toProgress: Double,
        loopMode: MotionLottieLoopMode
    )

    public static let playOnce = MotionLottiePlayback.playing(
        fromProgress: 0,
        toProgress: 1,
        loopMode: .playOnce
    )
    public static let loop = MotionLottiePlayback.playing(
        fromProgress: 0,
        toProgress: 1,
        loopMode: .loop
    )
}

public actor MotionAssetCache {
    public static let shared = MotionAssetCache()

    private let rootURL: URL
    private var resolvedURLs: [URL: URL] = [:]

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let caches = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.rootURL = caches
                .appending(path: "ESMotion", directoryHint: .isDirectory)
                .appending(path: "Assets", directoryHint: .isDirectory)
        }
    }

    public func prepare(_ source: MotionLottieSource) async throws
        -> MotionLottieSource {
        guard case .remote(let remoteURL) = source else { return source }
        if let cachedURL = resolvedURLs[remoteURL],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            return .localFile(cachedURL)
        }

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: remoteURL
        )
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode) else {
            throw MotionAssetCacheError.invalidResponse
        }

        let fileExtension = remoteURL.pathExtension.isEmpty
            ? "json"
            : remoteURL.pathExtension
        let localURL = rootURL
            .appending(path: stableFileName(for: remoteURL))
            .appendingPathExtension(fileExtension)

        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(
            at: temporaryURL,
            to: localURL
        )
        resolvedURLs[remoteURL] = localURL
        return .localFile(localURL)
    }

    public func clearMemoryIndex() {
        resolvedURLs.removeAll(keepingCapacity: true)
    }

    private func stableFileName(for url: URL) -> String {
        let bytes = Array(url.absoluteString.utf8)
        let hash = bytes.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public enum MotionAssetCacheError: LocalizedError {
    case invalidResponse

    public var errorDescription: String? {
        "The remote motion asset returned an invalid response."
    }
}
