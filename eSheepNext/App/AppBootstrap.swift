import Foundation
import Observation
import SwiftData

struct LocalStoreLaunchFailure: Equatable, Sendable {
    let occurredAt: Date
    let errorDomain: String
    let errorCode: Int
    let summary: String
    let storeFilename: String

    init(error: Error, storeURL: URL = AppSchema.defaultStoreURL()) {
        let nsError = error as NSError
        occurredAt = .now
        errorDomain = nsError.domain
        errorCode = nsError.code
        summary = nsError.localizedDescription
            .replacingOccurrences(of: NSHomeDirectory(), with: "<App Sandbox>")
        storeFilename = storeURL.lastPathComponent
    }

    var diagnosticText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return """
        eSheepNext 本地数据库启动诊断
        时间：\(occurredAt.formatted(.iso8601))
        App：\(version) (\(build))
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        Schema：\(AppSchema.currentVersion)
        Store：\(storeFilename)
        错误：\(errorDomain) / \(errorCode)
        摘要：\(summary)

        本报告不包含账号令牌、私钥、牧场名称或养殖业务数据。
        """
    }
}

enum LocalStoreRecoveryError: LocalizedError {
    case noStoreFiles
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .noStoreFiles:
            "没有找到可隔离的本地数据库文件，请直接重试。"
        case .rollbackFailed:
            "数据库隔离未完成，部分文件无法还原。请勿继续操作，并保留当前 App 数据目录。"
        }
    }
}

enum LocalStoreRecoveryService {
    static func relatedStoreURLs(for storeURL: URL) -> [URL] {
        let parent = storeURL.deletingLastPathComponent()
        let filename = storeURL.lastPathComponent
        return [
            storeURL,
            parent.appending(path: "\(filename)-wal"),
            parent.appending(path: "\(filename)-shm"),
            parent.appending(path: "\(filename)_SUPPORT", directoryHint: .isDirectory),
        ]
    }

    static func quarantineCurrentStore(
        storeURL: URL = AppSchema.defaultStoreURL(),
        fileManager: FileManager = .default,
        now: Date = .now
    ) throws -> URL {
        let existing = relatedStoreURLs(for: storeURL).filter {
            fileManager.fileExists(atPath: $0.path)
        }
        guard !existing.isEmpty else {
            throw LocalStoreRecoveryError.noStoreFiles
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let recoveryRoot = storeURL.deletingLastPathComponent()
            .appending(path: "RecoveryQuarantine", directoryHint: .isDirectory)
        let destination = recoveryRoot
            .appending(path: formatter.string(from: now), directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var moved: [(source: URL, destination: URL)] = []
        do {
            for source in existing {
                let target = destination.appending(
                    path: source.lastPathComponent,
                    directoryHint: source.hasDirectoryPath ? .isDirectory : .notDirectory
                )
                try fileManager.moveItem(at: source, to: target)
                moved.append((source, target))
            }
        } catch {
            var rollbackFailed = false
            for item in moved.reversed() {
                do {
                    try fileManager.moveItem(at: item.destination, to: item.source)
                } catch {
                    rollbackFailed = true
                }
            }
            try? fileManager.removeItem(at: destination)
            if rollbackFailed {
                throw LocalStoreRecoveryError.rollbackFailed
            }
            throw error
        }

        return destination
    }
}

@MainActor
@Observable
final class AppBootstrapController {
    private(set) var modelContainer: ModelContainer?
    private(set) var collaboration: CloudCollaborationStore?
    private(set) var failure: LocalStoreLaunchFailure?
    private(set) var quarantinedStoreURL: URL?
    private(set) var isRetrying = false
    @ObservationIgnored private var openTask: Task<Void, Never>?

    init() {}

    func start() {
        guard modelContainer == nil, failure == nil else { return }
        beginOpeningStore()
    }

    func retry() {
        beginOpeningStore()
    }

    func quarantineAndStartFresh() {
        guard !isRetrying else { return }
        isRetrying = true
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else { return }
            defer { isRetrying = false }
            do {
                let quarantinedURL = try await Task.detached(priority: .userInitiated) {
                    try LocalStoreRecoveryService.quarantineCurrentStore()
                }.value
                try Task.checkCancellation()
                quarantinedStoreURL = quarantinedURL
                try await prepareStore()
            } catch is CancellationError {
                return
            } catch {
                failure = LocalStoreLaunchFailure(error: error)
            }
        }
    }

    private func beginOpeningStore() {
        guard !isRetrying else { return }
        isRetrying = true
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else { return }
            defer { isRetrying = false }
            do {
                try await prepareStore()
            } catch is CancellationError {
                return
            } catch {
                modelContainer = nil
                collaboration = nil
                failure = LocalStoreLaunchFailure(error: error)
            }
        }
    }

    private func prepareStore() async throws {
        let prepared = try await Task.detached(priority: .userInitiated) {
            let container = try AppSchema.makeContainer()
            let cloudPreparation = CloudCollaborationStore.prepareStartup(
                container: container
            )
            return AppPreparedStore(
                container: container,
                cloudPreparation: cloudPreparation
            )
        }.value
        try Task.checkCancellation()

        let collaboration = CloudCollaborationStore(
            container: prepared.container,
            startupPreparation: prepared.cloudPreparation
        )
        modelContainer = prepared.container
        self.collaboration = collaboration
        failure = nil
        FarmBackgroundRefresh.register(
            collaboration: collaboration,
            modelContainer: prepared.container
        )
    }
}

private struct AppPreparedStore: Sendable {
    let container: ModelContainer
    let cloudPreparation: CloudCollaborationStartupPreparation
}
