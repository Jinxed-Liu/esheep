import Foundation
import SwiftData

enum LocalStorageCategory: String, Codable, Sendable {
    case businessData
    case backup
    case recoveryEvidence
    case rebuildableWorkspace
    case cache
}

enum StorageCleanupCandidateKind: String, Codable, Sendable {
    case cloudRebuild
    case completedMigrationWorkspace

    var displayName: String {
        switch self {
        case .cloudRebuild: "旧云端重建副本"
        case .completedMigrationWorkspace: "已完成迁移工作区"
        }
    }
}

struct StorageCleanupCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: StorageCleanupCandidateKind
    let farmID: UUID
    let sessionID: UUID
    let status: String
    let relativePath: String
    let byteCount: Int64
    let updatedAt: Date
    let errorCode: String?
    let errorMessage: String?
}

struct LocalStorageInventory: Sendable, Equatable {
    let businessDataBytes: Int64
    let backupBytes: Int64
    let recoveryEvidenceBytes: Int64
    let rebuildableWorkspaceBytes: Int64
    let cacheBytes: Int64
    let cleanupCandidates: [StorageCleanupCandidate]

    var candidateBytes: Int64 {
        cleanupCandidates.reduce(0) { $0 + $1.byteCount }
    }
}

struct LocalStorageCleanupReceipt: Codable, Sendable, Equatable {
    struct FileEvidence: Codable, Sendable, Equatable {
        let relativePath: String
        let byteCount: Int64
        let sha256: String
    }

    struct CandidateEvidence: Codable, Sendable, Equatable {
        let candidate: StorageCleanupCandidate
        let files: [FileEvidence]
    }

    static let schema = "esheepnext.local-storage-cleanup.v1"

    let id: UUID
    let schema: String
    let createdAt: Date
    let candidates: [CandidateEvidence]
    let reclaimedByteCount: Int64
    let diagnosticRelativePath: String
}

enum LocalStorageInventoryError: LocalizedError {
    case externalBackupNotConfirmed
    case unsafePath
    case candidateChanged
    case diagnosticVerificationFailed

    var errorDescription: String? {
        switch self {
        case .externalBackupNotConfirmed:
            "尚未确认外部完整容器备份，拒绝清理。"
        case .unsafePath:
            "清理对象不在允许的可重建目录内。"
        case .candidateChanged:
            "清理对象在确认后发生变化，请重新盘点。"
        case .diagnosticVerificationFailed:
            "清理诊断归档回读校验失败，原目录已保留。"
        }
    }
}

@MainActor
struct LocalStorageInventoryService {
    private static let diagnosticsRoot = "LocalStorageCleanupDiagnostics"

    func inventory(context: ModelContext) throws -> LocalStorageInventory {
        let support = try applicationSupportURL()
        let cloudRebuildRoot = support.appending(
            path: "CloudRebuild",
            directoryHint: .isDirectory
        )
        let migrationRoot = support
            .appending(path: "eSheepNext", directoryHint: .isDirectory)
            .appending(
                path: "MigrationWorkspaces",
                directoryHint: .isDirectory
            )

        let cloudCandidates = try context.fetch(
            FetchDescriptor<CloudRebuildSessionRecord>()
        )
        .filter {
            [.completed, .failed, .cancelled].contains($0.status)
        }
        .compactMap { session -> StorageCleanupCandidate? in
            let url = support.appending(path: session.stagingRelativePath)
            guard isDescendant(url, of: cloudRebuildRoot),
                  FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return StorageCleanupCandidate(
                id: "cloud-rebuild:\(session.id.uuidString.lowercased())",
                kind: .cloudRebuild,
                farmID: session.farmID,
                sessionID: session.id,
                status: session.status.rawValue,
                relativePath: relativePath(url, root: support),
                byteCount: allocatedSize(of: url),
                updatedAt: session.updatedAt,
                errorCode: session.lastErrorCode,
                errorMessage: session.lastErrorMessage
            )
        }

        let completedCommits = try context.fetch(
            FetchDescriptor<MigrationCommitRecord>()
        ).filter { $0.status == .completed }
        let migrationCandidates = completedCommits.compactMap {
            commit -> StorageCleanupCandidate? in
            let url = migrationRoot.appending(
                path: commit.sessionID.uuidString,
                directoryHint: .isDirectory
            )
            guard isDescendant(url, of: migrationRoot),
                  FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return StorageCleanupCandidate(
                id: "migration-workspace:" +
                    commit.sessionID.uuidString.lowercased(),
                kind: .completedMigrationWorkspace,
                farmID: commit.farmID,
                sessionID: commit.sessionID,
                status: commit.status.rawValue,
                relativePath: relativePath(url, root: support),
                byteCount: allocatedSize(of: url),
                updatedAt: commit.committedAt,
                errorCode: nil,
                errorMessage: nil
            )
        }

        let candidates = (cloudCandidates + migrationCandidates).sorted {
            if $0.kind != $1.kind {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.updatedAt < $1.updatedAt
        }
        let businessURLs = [
            support.appending(path: "eSheepNext.store"),
            support.appending(path: "eSheepNext.store-wal"),
            support.appending(path: "eSheepNext.store-shm"),
            support.appending(path: "CloudAssets"),
        ]
        let backupURLs = [
            support.appending(path: "SupabaseMigrationBackups"),
            support.appending(path: "MigrationAuditArchives"),
        ]
        let recoveryURLs = [
            support.appending(path: "eSheepNext/Recovery"),
            support.appending(path: "CloudSync"),
            support.appending(path: Self.diagnosticsRoot),
        ]
        let cache = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first

        return LocalStorageInventory(
            businessDataBytes: businessURLs.reduce(0) {
                $0 + allocatedSize(of: $1)
            },
            backupBytes: backupURLs.reduce(0) {
                $0 + allocatedSize(of: $1)
            },
            recoveryEvidenceBytes: recoveryURLs.reduce(0) {
                $0 + allocatedSize(of: $1)
            },
            rebuildableWorkspaceBytes: candidates.reduce(0) {
                $0 + $1.byteCount
            },
            cacheBytes: cache.map(allocatedSize(of:)) ?? 0,
            cleanupCandidates: candidates
        )
    }

    func clean(
        candidates: [StorageCleanupCandidate],
        externalBackupConfirmed: Bool,
        context: ModelContext
    ) throws -> LocalStorageCleanupReceipt {
        guard externalBackupConfirmed else {
            throw LocalStorageInventoryError.externalBackupNotConfirmed
        }
        let fresh = try inventory(context: context)
        let freshByID = Dictionary(
            uniqueKeysWithValues: fresh.cleanupCandidates.map { ($0.id, $0) }
        )
        guard !candidates.isEmpty,
              candidates.allSatisfy({ freshByID[$0.id] == $0 }) else {
            throw LocalStorageInventoryError.candidateChanged
        }

        let support = try applicationSupportURL()
        let evidence = try candidates.map { candidate in
            let url = support.appending(path: candidate.relativePath)
            try validateAllowedCandidate(url, kind: candidate.kind, support: support)
            return LocalStorageCleanupReceipt.CandidateEvidence(
                candidate: candidate,
                files: try fileEvidence(in: url)
            )
        }
        let receiptID = UUID()
        let diagnosticRelativePath =
            "\(Self.diagnosticsRoot)/\(receiptID.uuidString.lowercased()).eslc"
        let receipt = LocalStorageCleanupReceipt(
            id: receiptID,
            schema: LocalStorageCleanupReceipt.schema,
            createdAt: .now,
            candidates: evidence,
            reclaimedByteCount: candidates.reduce(0) {
                $0 + $1.byteCount
            },
            diagnosticRelativePath: diagnosticRelativePath
        )
        let clear = try JSONEncoder.cloud.encode(receipt)
        let compressed = try SupabaseMigrationBackupArchiveCodec.encode(clear)
        let diagnosticURL = support.appending(path: diagnosticRelativePath)
        try FileManager.default.createDirectory(
            at: diagnosticURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try compressed.write(
            to: diagnosticURL,
            options: [.atomic, .completeFileProtection]
        )
        let decoded = try SupabaseMigrationBackupArchiveCodec.decode(
            Data(contentsOf: diagnosticURL)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(
            LocalStorageCleanupReceipt.self,
            from: decoded
        )
        guard decoded == clear,
              roundTrip.id == receipt.id,
              roundTrip.schema == receipt.schema,
              roundTrip.candidates.map(\.candidate.id) ==
                receipt.candidates.map(\.candidate.id),
              roundTrip.candidates.map(\.files) ==
                receipt.candidates.map(\.files),
              roundTrip.reclaimedByteCount == receipt.reclaimedByteCount,
              roundTrip.diagnosticRelativePath ==
                receipt.diagnosticRelativePath else {
            throw LocalStorageInventoryError.diagnosticVerificationFailed
        }

        for candidate in candidates {
            let url = support.appending(path: candidate.relativePath)
            try validateAllowedCandidate(url, kind: candidate.kind, support: support)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LocalStorageInventoryError.candidateChanged
            }
            try FileManager.default.removeItem(at: url)
        }
        return receipt
    }

    private func validateAllowedCandidate(
        _ url: URL,
        kind: StorageCleanupCandidateKind,
        support: URL
    ) throws {
        let root: URL
        switch kind {
        case .cloudRebuild:
            root = support.appending(
                path: "CloudRebuild",
                directoryHint: .isDirectory
            )
        case .completedMigrationWorkspace:
            root = support
                .appending(path: "eSheepNext", directoryHint: .isDirectory)
                .appending(
                    path: "MigrationWorkspaces",
                    directoryHint: .isDirectory
                )
        }
        guard isDescendant(url, of: root) else {
            throw LocalStorageInventoryError.unsafePath
        }
    }

    private func fileEvidence(
        in directory: URL
    ) throws -> [LocalStorageCleanupReceipt.FileEvidence] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
            ],
            options: []
        ) else {
            return []
        }
        var values: [LocalStorageCleanupReceipt.FileEvidence] = []
        for case let file as URL in enumerator {
            let valuesForFile = try file.resourceValues(
                forKeys: [.isRegularFileKey, .fileAllocatedSizeKey]
            )
            guard valuesForFile.isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            values.append(.init(
                relativePath: relativePath(file, root: directory),
                byteCount: Int64(
                    valuesForFile.fileAllocatedSize ?? data.count
                ),
                sha256: FarmCompactBaselineArchive.digest(data)
            ))
        }
        return values.sorted { $0.relativePath < $1.relativePath }
    }

    private func allocatedSize(of url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }
        if let values = try? url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
            ]
        ), values.isRegularFile == true {
            return Int64(
                values.totalFileAllocatedSize ??
                    values.fileAllocatedSize ??
                    0
            )
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
            ],
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                ]
            ), values.isRegularFile == true else {
                continue
            }
            total += Int64(
                values.totalFileAllocatedSize ??
                    values.fileAllocatedSize ??
                    0
            )
        }
        return total
    }

    private func applicationSupportURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).standardizedFileURL
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        String(
            url.standardizedFileURL.path
                .dropFirst(root.standardizedFileURL.path.count + 1)
        )
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.standardizedFileURL.path.hasPrefix(
            root.standardizedFileURL.path + "/"
        )
    }
}
