import Compression
import CryptoKit
import Foundation
import SwiftData

struct LocalStorageOptimizationResult: Sendable, Equatable {
    let archivedAuditRecordCount: Int
    let removedHotAuditRecordCount: Int
    let compressedMigrationBackupCount: Int
    let removedRebuildDirectoryCount: Int
    let removedBaselineDirectoryCount: Int
    let prunedPersistentHistoryBefore: Date?
}

enum LocalStorageOptimizationError: LocalizedError {
    case authorityNotVerified
    case pendingOutbox
    case auditArchiveCorrupted
    case compressionFailed
    case decompressionFailed
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .authorityNotVerified:
            "Supabase 权威和 checkpoint 尚未完成验证，不能清理本地迁移材料。"
        case .pendingOutbox:
            "仍有待确认的云端操作，暂不清理本地同步历史。"
        case .auditArchiveCorrupted:
            "迁移审计归档回读校验失败，热库记录已保留。"
        case .compressionFailed:
            "迁移审计压缩失败。"
        case .decompressionFailed:
            "迁移审计解压失败。"
        case .unsafePath:
            "拒绝清理不在 App 沙盒允许目录内的路径。"
        }
    }
}

private struct MigrationAuditArchiveV1: Codable, Sendable {
    static let schema = "esheepnext.migration-audit-archive.v1"

    struct Record: Codable, Sendable {
        let id: UUID
        let sessionID: UUID
        let sourceKey: String
        let entityType: String
        let targetEntityIDsJSON: String
        let rawPayloadJSON: String
        let resolution: String
        let exclusionReason: String?
        let createdAt: Date
    }

    let schema: String
    let sessionID: UUID
    let recordCount: Int
    let recordDigest: String
    let createdAt: Date
    let records: [Record]
}

private enum MigrationAuditArchiveCodec {
    private static let magic = Data("ESMA0001".utf8)
    private static let headerByteCount = 16
    private static let maximumUncompressedBytes = 256 * 1_024 * 1_024

    static func encode(_ value: MigrationAuditArchiveV1) throws -> Data {
        let clear = try JSONEncoder.cloud.encode(value)
        var capacity = max(64 * 1_024, clear.count / 3)
        while capacity <= clear.count * 2 + 64 * 1_024 {
            var compressed = Data(count: capacity)
            let written = compressed.withUnsafeMutableBytes { destinationBuffer in
                clear.withUnsafeBytes { sourceBuffer in
                    guard let destination = destinationBuffer.bindMemory(
                        to: UInt8.self
                    ).baseAddress,
                    let source = sourceBuffer.bindMemory(
                        to: UInt8.self
                    ).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(
                        destination,
                        capacity,
                        source,
                        clear.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
            }
            if written > 0 {
                compressed.count = written
                var output = Data()
                output.append(magic)
                var size = UInt64(clear.count).bigEndian
                withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
                output.append(compressed)
                return output
            }
            capacity *= 2
        }
        throw LocalStorageOptimizationError.compressionFailed
    }

    static func decode(_ data: Data) throws -> MigrationAuditArchiveV1 {
        guard data.count > headerByteCount,
              data.prefix(magic.count) == magic else {
            throw LocalStorageOptimizationError.auditArchiveCorrupted
        }
        let size = data[magic.count..<headerByteCount].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard size > 0, size <= UInt64(maximumUncompressedBytes) else {
            throw LocalStorageOptimizationError.auditArchiveCorrupted
        }
        var clear = Data(count: Int(size))
        let compressed = data.dropFirst(headerByteCount)
        let decoded = clear.withUnsafeMutableBytes { destinationBuffer in
            compressed.withUnsafeBytes { sourceBuffer in
                guard let destination = destinationBuffer.bindMemory(
                    to: UInt8.self
                ).baseAddress,
                let source = sourceBuffer.bindMemory(
                    to: UInt8.self
                ).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destination,
                    Int(size),
                    source,
                    compressed.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decoded == Int(size) else {
            throw LocalStorageOptimizationError.decompressionFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MigrationAuditArchiveV1.self, from: clear)
    }
}

enum SupabaseMigrationBackupArchiveCodec {
    private static let magic = Data("ESLB0001".utf8)
    private static let headerByteCount = 16
    private static let maximumUncompressedBytes = 512 * 1_024 * 1_024

    static func encode(_ clear: Data) throws -> Data {
        guard !clear.isEmpty,
              clear.count <= maximumUncompressedBytes else {
            throw LocalStorageOptimizationError.compressionFailed
        }
        var capacity = max(64 * 1_024, clear.count / 3)
        while capacity <= clear.count * 2 + 64 * 1_024 {
            var compressed = Data(count: capacity)
            let written = compressed.withUnsafeMutableBytes { destinationBuffer in
                clear.withUnsafeBytes { sourceBuffer in
                    guard let destination = destinationBuffer.bindMemory(
                        to: UInt8.self
                    ).baseAddress,
                    let source = sourceBuffer.bindMemory(
                        to: UInt8.self
                    ).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(
                        destination,
                        capacity,
                        source,
                        clear.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
            }
            if written > 0 {
                compressed.count = written
                var output = Data()
                output.append(magic)
                var size = UInt64(clear.count).bigEndian
                withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
                output.append(compressed)
                return output
            }
            capacity *= 2
        }
        throw LocalStorageOptimizationError.compressionFailed
    }

    static func decode(_ archive: Data) throws -> Data {
        guard archive.count > headerByteCount,
              archive.prefix(magic.count) == magic else {
            throw LocalStorageOptimizationError.decompressionFailed
        }
        let size = archive[magic.count..<headerByteCount].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard size > 0, size <= UInt64(maximumUncompressedBytes) else {
            throw LocalStorageOptimizationError.decompressionFailed
        }
        var clear = Data(count: Int(size))
        let compressed = archive.dropFirst(headerByteCount)
        let decoded = clear.withUnsafeMutableBytes { destinationBuffer in
            compressed.withUnsafeBytes { sourceBuffer in
                guard let destination = destinationBuffer.bindMemory(
                    to: UInt8.self
                ).baseAddress,
                let source = sourceBuffer.bindMemory(
                    to: UInt8.self
                ).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destination,
                    Int(size),
                    source,
                    compressed.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decoded == Int(size) else {
            throw LocalStorageOptimizationError.decompressionFailed
        }
        return clear
    }
}

private actor LocalStorageArchiveWorker {
    static let shared = LocalStorageArchiveWorker()

    func writeVerifiedAuditArchive(
        _ archive: MigrationAuditArchiveV1,
        to url: URL
    ) throws -> MigrationAuditArchiveV1 {
        let encoded = try MigrationAuditArchiveCodec.encode(archive)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
        return try MigrationAuditArchiveCodec.decode(
            Data(contentsOf: url)
        )
    }

    func compressMigrationBackups(
        farmID: UUID,
        directory: URL,
        allowedRoot: URL
    ) throws -> Int {
        guard isDescendant(directory, of: allowedRoot),
              FileManager.default.fileExists(atPath: directory.path) else {
            return 0
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var compressedCount = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for source in files where source.pathExtension.lowercased() == "json" {
            guard isDescendant(source, of: allowedRoot) else {
                throw LocalStorageOptimizationError.unsafePath
            }
            let clear = try Data(contentsOf: source)
            let backup = try decoder.decode(
                FarmBackupEnvelopeV1.self,
                from: clear
            )
            guard backup.schemaVersion == FarmBackupEnvelopeV1.schemaVersion,
                  backup.payload.farm.id == farmID,
                  !backup.checksum.isEmpty else {
                throw LocalStorageOptimizationError.auditArchiveCorrupted
            }
            let archive = try SupabaseMigrationBackupArchiveCodec.encode(clear)
            let destination = source
                .deletingPathExtension()
                .appendingPathExtension("eslb")
            try archive.write(
                to: destination,
                options: [.atomic, .completeFileProtection]
            )
            let decoded = try SupabaseMigrationBackupArchiveCodec.decode(
                Data(contentsOf: destination)
            )
            guard decoded.count == clear.count,
                  FarmCompactBaselineArchive.digest(decoded) ==
                    FarmCompactBaselineArchive.digest(clear) else {
                throw LocalStorageOptimizationError.auditArchiveCorrupted
            }
            try FileManager.default.removeItem(at: source)
            compressedCount += 1
        }
        return compressedCount
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.standardizedFileURL.path.hasPrefix(
            root.standardizedFileURL.path + "/"
        )
    }
}

/// Reclaims only data that is either independently archived or can be rebuilt
/// from a verified authority. Business entities, DomainOperation, Tombstone,
/// photos, remote receipts and security incidents are deliberately excluded.
@MainActor
struct LocalStorageOptimizationService {
    private static let auditArchiveRoot = "MigrationAuditArchives"
    private static let terminalOutboxStatuses: Set<OutboxStatus> = [
        .confirmed,
        .notRequiredLocalOnly,
        .quarantinedMembershipRevoked,
        .supersededRemoteAuthority,
    ]

    func optimizeAfterVerifiedSupabaseActivation(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext,
        historyRetentionDays: Int = 14
    ) async throws -> LocalStorageOptimizationResult {
        try verifyCleanupBoundary(
            farmID: farmID,
            migrationID: migrationID,
            context: context
        )

        let auditResult = try await archiveCompletedMigrationAudits(
            farmID: farmID,
            context: context
        )
        let compressedBackups = try await compressMigrationBackups(
            farmID: farmID
        )
        let removedRebuilds = try removeResolvedCloudRebuildDirectories(
            farmID: farmID,
            context: context
        )
        let removedBaselines = try removeSupersededBaselineDirectories(
            farmID: farmID,
            migrationID: migrationID
        )
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -max(7, historyRetentionDays),
            to: .now
        )
        if let cutoff {
            let descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: #Predicate { transaction in
                    transaction.timestamp < cutoff
                }
            )
            try context.deleteHistory(descriptor)
        }

        return LocalStorageOptimizationResult(
            archivedAuditRecordCount: auditResult.archived,
            removedHotAuditRecordCount: auditResult.removed,
            compressedMigrationBackupCount: compressedBackups,
            removedRebuildDirectoryCount: removedRebuilds,
            removedBaselineDirectoryCount: removedBaselines,
            prunedPersistentHistoryBefore: cutoff
        )
    }

    private func verifyCleanupBoundary(
        farmID: UUID,
        migrationID: UUID,
        context: ModelContext
    ) throws {
        let profile = try context.fetch(FetchDescriptor<FarmStorageProfile>())
            .first { $0.farmID == farmID }
        let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .first {
                $0.farmID == farmID &&
                    $0.provider == .supabase &&
                    $0.state == .active
            }
        let checkpoint = try context
            .fetch(FetchDescriptor<FarmBaselineMigrationRecord>())
            .first {
                $0.farmID == farmID &&
                    $0.migrationID == migrationID &&
                    $0.checkpointID != nil
            }
        guard profile?.mode == .supabase,
              profile?.transitionState == .idle,
              binding != nil,
              checkpoint != nil else {
            throw LocalStorageOptimizationError.authorityNotVerified
        }

        let pending = try context.fetch(FetchDescriptor<OutboxItem>())
            .contains {
                $0.farmID == farmID &&
                    !Self.terminalOutboxStatuses.contains($0.status)
            }
        guard !pending else {
            throw LocalStorageOptimizationError.pendingOutbox
        }
    }

    private func archiveCompletedMigrationAudits(
        farmID: UUID,
        context: ModelContext
    ) async throws -> (archived: Int, removed: Int) {
        let commits = try context.fetch(FetchDescriptor<MigrationCommitRecord>())
            .filter { $0.farmID == farmID && $0.status == .completed }
        var archivedCount = 0
        var removedCount = 0

        for commit in commits {
            let audits = try context.fetch(FetchDescriptor<MigrationAuditRecord>())
                .filter { $0.sessionID == commit.sessionID }
                .sorted {
                    if $0.sourceKey != $1.sourceKey {
                        return $0.sourceKey < $1.sourceKey
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
            guard !audits.isEmpty else { continue }
            let records = audits.map {
                MigrationAuditArchiveV1.Record(
                    id: $0.id,
                    sessionID: $0.sessionID,
                    sourceKey: $0.sourceKey,
                    entityType: $0.entityType,
                    targetEntityIDsJSON: $0.targetEntityIDsJSON,
                    rawPayloadJSON: $0.rawPayloadJSON,
                    resolution: $0.resolution,
                    exclusionReason: $0.exclusionReason,
                    createdAt: $0.createdAt
                )
            }
            let recordDigest = digest(records.map {
                "\($0.id.uuidString.lowercased()):" +
                    FarmCompactBaselineArchive.digest(
                        Data($0.rawPayloadJSON.utf8)
                    )
            })
            let archive = MigrationAuditArchiveV1(
                schema: MigrationAuditArchiveV1.schema,
                sessionID: commit.sessionID,
                recordCount: records.count,
                recordDigest: recordDigest,
                createdAt: .now,
                records: records
            )
            let url = try auditArchiveURL(sessionID: commit.sessionID)
            let roundTrip = try await LocalStorageArchiveWorker.shared
                .writeVerifiedAuditArchive(
                    archive,
                    to: url
            )
            guard roundTrip.schema == MigrationAuditArchiveV1.schema,
                  roundTrip.sessionID == commit.sessionID,
                  roundTrip.recordCount == records.count,
                  roundTrip.recordDigest == recordDigest,
                  Set(roundTrip.records.map(\.id)) == Set(records.map(\.id)) else {
                throw LocalStorageOptimizationError.auditArchiveCorrupted
            }
            archivedCount += records.count

            // Keep non-converted rows in the hot database because the review
            // UI uses them to explain exclusions and reconciliation warnings.
            for audit in audits where
                audit.resolution == "converted" &&
                audit.exclusionReason == nil {
                context.delete(audit)
                removedCount += 1
            }
            try context.save()
        }
        return (archivedCount, removedCount)
    }

    private func removeResolvedCloudRebuildDirectories(
        farmID: UUID,
        context: ModelContext
    ) throws -> Int {
        let sessions = try context
            .fetch(FetchDescriptor<CloudRebuildSessionRecord>())
            .filter {
                $0.farmID == farmID &&
                    [.completed, .cancelled].contains($0.status)
            }
        let support = try applicationSupportURL()
        let allowedRoot = support.appending(
            path: "CloudRebuild",
            directoryHint: .isDirectory
        )
        var removed = 0
        for session in sessions {
            let candidate = support.appending(path: session.stagingRelativePath)
            guard isDescendant(candidate, of: allowedRoot) else {
                throw LocalStorageOptimizationError.unsafePath
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
                removed += 1
            }
        }
        return removed
    }

    private func compressMigrationBackups(farmID: UUID) async throws -> Int {
        let support = try applicationSupportURL()
        let allowedRoot = support.appending(
            path: "SupabaseMigrationBackups",
            directoryHint: .isDirectory
        )
        let directory = allowedRoot.appending(
            path: farmID.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        return try await LocalStorageArchiveWorker.shared
            .compressMigrationBackups(
                farmID: farmID,
                directory: directory,
                allowedRoot: allowedRoot
            )
    }

    private func removeSupersededBaselineDirectories(
        farmID: UUID,
        migrationID: UUID
    ) throws -> Int {
        let support = try applicationSupportURL()
        let candidates = [
            support
                .appending(path: "SupabaseBaselinePackages", directoryHint: .isDirectory)
                .appending(path: farmID.uuidString.lowercased()),
            support
                .appending(path: "SupabaseCompactStaging", directoryHint: .isDirectory)
                .appending(path: farmID.uuidString.lowercased())
                .appending(path: migrationID.uuidString.lowercased()),
            support
                .appending(path: "SupabaseCompactCheckpoints", directoryHint: .isDirectory)
                .appending(path: farmID.uuidString.lowercased())
                .appending(path: "\(migrationID.uuidString.lowercased()).esbc"),
        ]
        let allowedRoots = [
            support.appending(path: "SupabaseBaselinePackages"),
            support.appending(path: "SupabaseCompactStaging"),
            support.appending(path: "SupabaseCompactCheckpoints"),
        ]
        var removed = 0
        for candidate in candidates {
            guard allowedRoots.contains(where: {
                isDescendant(candidate, of: $0)
            }) else {
                throw LocalStorageOptimizationError.unsafePath
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
                removed += 1
            }
        }
        return removed
    }

    private func auditArchiveURL(sessionID: UUID) throws -> URL {
        try applicationSupportURL()
            .appending(path: Self.auditArchiveRoot, directoryHint: .isDirectory)
            .appending(path: "\(sessionID.uuidString.lowercased()).esma")
    }

    private func applicationSupportURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).standardizedFileURL
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private func digest(_ lines: [String]) -> String {
        FarmCompactBaselineArchive.digest(
            Data(lines.sorted().joined(separator: "\n").utf8)
        )
    }
}
