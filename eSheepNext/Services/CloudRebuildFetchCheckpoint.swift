import CloudKit
import CoreLocation
import Foundation

struct CloudRebuildFetchCheckpointState: @unchecked Sendable {
    let records: [CKRecord]
    let deletedRecordNames: Set<String>
    let changeToken: CKServerChangeToken?
    let pageCount: Int
}

/// Durable, append-only CloudKit page storage used by a full rebuild.
///
/// SwiftData stores the user-visible counters, while this workspace stores the
/// actual records and server change token. A killed app can therefore resume
/// from the last atomically committed page instead of replaying the zone from
/// its beginning. The archive is local-only and every file is digest checked
/// before it may become rebuild input.
struct CloudRebuildFetchCheckpointStore {
    private struct Manifest: Codable {
        struct Page: Codable {
            let index: Int
            let recordsFile: String
            let recordsDigest: String
            let deletionsFile: String
            let deletionsDigest: String
            let tokenFile: String
            let tokenDigest: String
            let recordCount: Int
            let deletionCount: Int
        }

        let version: Int
        let farmID: UUID
        let databaseScope: CloudDatabaseScope
        let zoneName: String
        let zoneOwnerName: String
        var pages: [Page]
    }

    private let root: URL
    private let farmID: UUID
    private let databaseScope: CloudDatabaseScope
    private let zoneID: CKRecordZone.ID
    private let fileManager: FileManager

    init(
        workspace: URL,
        farmID: UUID,
        databaseScope: CloudDatabaseScope,
        zoneID: CKRecordZone.ID,
        fileManager: FileManager = .default
    ) {
        root = workspace.appending(path: "FetchCheckpoint", directoryHint: .isDirectory)
        self.farmID = farmID
        self.databaseScope = databaseScope
        self.zoneID = zoneID
        self.fileManager = fileManager
    }

    func load() throws -> CloudRebuildFetchCheckpointState? {
        let manifestURL = root.appending(path: "manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        let manifest = try JSONDecoder.checkpoint.decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try validateIdentity(manifest)

        var recordsByName: [String: CKRecord] = [:]
        var deletedRecordNames = Set<String>()
        var latestToken: CKServerChangeToken?
        var expectedPage = 1

        for page in manifest.pages.sorted(by: { $0.index < $1.index }) {
            guard page.index == expectedPage else {
                throw CloudRebuildError.stagingValidation("CloudKit断点页序号不连续。")
            }
            expectedPage += 1
            let recordsData = try checkedData(
                named: page.recordsFile,
                digest: page.recordsDigest
            )
            let records = try Self.decodeRecords(recordsData)
                .map(rebindPersistedAsset(in:))
            guard records.count == page.recordCount,
                  records.allSatisfy({ $0.recordID.zoneID == zoneID }) else {
                throw CloudRebuildError.stagingValidation("CloudKit断点记录与牧场zone不一致。")
            }

            let deletionData = try checkedData(
                named: page.deletionsFile,
                digest: page.deletionsDigest
            )
            let deletions = try JSONDecoder.checkpoint.decode(
                [String].self,
                from: deletionData
            )
            guard deletions.count == page.deletionCount else {
                throw CloudRebuildError.stagingValidation("CloudKit断点删除数量不一致。")
            }

            let tokenData = try checkedData(
                named: page.tokenFile,
                digest: page.tokenDigest
            )
            latestToken = try Self.decodeToken(tokenData)

            for record in records {
                recordsByName[record.recordID.recordName] = record
                deletedRecordNames.remove(record.recordID.recordName)
            }
            for recordName in deletions {
                recordsByName.removeValue(forKey: recordName)
                deletedRecordNames.insert(recordName)
            }
        }

        return CloudRebuildFetchCheckpointState(
            records: Array(recordsByName.values),
            deletedRecordNames: deletedRecordNames,
            changeToken: latestToken,
            pageCount: manifest.pages.count
        )
    }

    func append(_ page: CloudZoneChangePage) throws {
        guard let changeToken = page.changeToken else {
            throw CloudRebuildError.stagingValidation("CloudKit断点缺少server change token。")
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: root.appending(path: "Assets", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        var manifest = try loadManifest() ?? Manifest(
            version: 1,
            farmID: farmID,
            databaseScope: databaseScope,
            zoneName: zoneID.zoneName,
            zoneOwnerName: zoneID.ownerName,
            pages: []
        )
        try validateIdentity(manifest)
        guard page.index == manifest.pages.count + 1 else {
            throw CloudRebuildError.stagingValidation("CloudKit断点页序号发生回退或跳跃。")
        }

        let persistentRecords = try page.records.map(persistAssets(in:))
        let recordsData = try Self.encodeRecords(persistentRecords)
        let deletionNames = page.deletions.map(\.recordID.recordName).sorted()
        let deletionsData = try JSONEncoder.checkpoint.encode(deletionNames)
        let tokenData = try NSKeyedArchiver.archivedData(
            withRootObject: changeToken,
            requiringSecureCoding: true
        )

        let prefix = String(format: "page-%06d", page.index)
        let recordsFile = "\(prefix).records"
        let deletionsFile = "\(prefix).deletions.json"
        let tokenFile = "\(prefix).token"
        try recordsData.write(to: root.appending(path: recordsFile), options: .atomic)
        try deletionsData.write(to: root.appending(path: deletionsFile), options: .atomic)
        try tokenData.write(to: root.appending(path: tokenFile), options: .atomic)

        manifest.pages.append(Manifest.Page(
            index: page.index,
            recordsFile: recordsFile,
            recordsDigest: CloudPayloadDigest.hex(for: recordsData),
            deletionsFile: deletionsFile,
            deletionsDigest: CloudPayloadDigest.hex(for: deletionsData),
            tokenFile: tokenFile,
            tokenDigest: CloudPayloadDigest.hex(for: tokenData),
            recordCount: persistentRecords.count,
            deletionCount: deletionNames.count
        ))
        try JSONEncoder.checkpoint.encode(manifest).write(
            to: root.appending(path: "manifest.json"),
            options: .atomic
        )
    }

    private func loadManifest() throws -> Manifest? {
        let url = root.appending(path: "manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.checkpoint.decode(
            Manifest.self,
            from: Data(contentsOf: url)
        )
    }

    private func validateIdentity(_ manifest: Manifest) throws {
        guard manifest.version == 1,
              manifest.farmID == farmID,
              manifest.databaseScope == databaseScope,
              manifest.zoneName == zoneID.zoneName,
              manifest.zoneOwnerName == zoneID.ownerName else {
            throw CloudRebuildError.stagingValidation("CloudKit断点不属于当前牧场或zone。")
        }
    }

    private func checkedData(named name: String, digest: String) throws -> Data {
        let data = try Data(contentsOf: root.appending(path: name))
        guard CloudPayloadDigest.hex(for: data) == digest else {
            throw CloudRebuildError.stagingValidation("CloudKit断点文件摘要不一致。")
        }
        return data
    }

    private func persistAssets(in record: CKRecord) throws -> CKRecord {
        guard let asset = record[CloudRecordField.asset] as? CKAsset,
              let sourceURL = asset.fileURL else {
            return record
        }
        let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let suffix = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
        let stableName = CloudPayloadDigest.hex(
            for: Data(record.recordID.recordName.utf8)
        )
        let destination = root
            .appending(path: "Assets", directoryHint: .isDirectory)
            .appending(path: "\(stableName).\(suffix)")
        if !fileManager.fileExists(atPath: destination.path) ||
            (try? Data(contentsOf: destination, options: .mappedIfSafe)) != sourceData {
            try sourceData.write(to: destination, options: .atomic)
        }
        record[CloudRecordField.asset] = CKAsset(fileURL: destination)
        return record
    }

    /// CKAsset archives retain absolute file URLs. iOS may relocate an app's
    /// data container during an ordinary coverage install, so a valid durable
    /// checkpoint must resolve its asset inside the current workspace instead
    /// of trusting the archived container UUID.
    private func rebindPersistedAsset(in record: CKRecord) throws -> CKRecord {
        guard record[CloudRecordField.asset] is CKAsset else { return record }
        let assetsDirectory = root.appending(path: "Assets", directoryHint: .isDirectory)
        let stablePrefix = CloudPayloadDigest.hex(
            for: Data(record.recordID.recordName.utf8)
        ) + "."
        let candidates = try fileManager.contentsOfDirectory(
            at: assetsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix(stablePrefix) }

        let expectedDigest = record[CloudRecordField.payloadDigest] as? String
        let matching = try candidates.filter { candidate in
            guard let expectedDigest, !expectedDigest.isEmpty else { return true }
            let data = try Data(contentsOf: candidate, options: .mappedIfSafe)
            return CloudPayloadDigest.hex(for: data) == expectedDigest
        }
        guard matching.count == 1, let currentURL = matching.first else {
            throw CloudRebuildError.stagingValidation(
                "CloudKit断点附件缺失或摘要不唯一：\(record.recordID.recordName)"
            )
        }
        record[CloudRecordField.asset] = CKAsset(fileURL: currentURL)
        return record
    }

    static func encodeRecords(_ records: [CKRecord]) throws -> Data {
        try NSKeyedArchiver.archivedData(
            withRootObject: records,
            requiringSecureCoding: true
        )
    }

    static func decodeRecords(_ data: Data) throws -> [CKRecord] {
        let classes: [AnyClass] = [
            NSArray.self,
            NSMutableArray.self,
            NSDictionary.self,
            NSMutableDictionary.self,
            NSSet.self,
            NSMutableSet.self,
            NSString.self,
            NSNumber.self,
            NSDate.self,
            NSData.self,
            NSURL.self,
            CKRecord.self,
            CKRecord.ID.self,
            CKRecordZone.ID.self,
            CKRecord.Reference.self,
            CKAsset.self,
            CLLocation.self,
        ]
        guard let records = try NSKeyedUnarchiver.unarchivedObject(
            ofClasses: classes,
            from: data
        ) as? [CKRecord] else {
            throw CloudRebuildError.stagingValidation("CloudKit断点记录无法解码。")
        }
        return records
    }

    private static func decodeToken(_ data: Data) throws -> CKServerChangeToken {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        ) else {
            throw CloudRebuildError.stagingValidation("CloudKit断点token无法解码。")
        }
        return token
    }
}

private extension JSONEncoder {
    static var checkpoint: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var checkpoint: JSONDecoder { JSONDecoder() }
}
