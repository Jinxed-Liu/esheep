import Foundation
import SwiftData

struct ESheepCloudCenterSummary: Sendable, Equatable {
    struct WaitingItem: Identifiable, Sendable, Equatable {
        let id: UUID
        let commandKind: String
        let occurredAt: Date
    }
    var waitingCount = 0
    var rejectedCount = 0
    var waitingItems: [WaitingItem] = []
    var assetCount = 0
    var pendingAssetCount = 0
    var failedAssetCount = 0
}

actor ESheepCloudCenterSummaryReader {
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    func load(farmID: UUID, accountID: UUID, generation: Int) throws -> ESheepCloudCenterSummary {
        let context = ModelContext(container)
        let excluded = ["accepted", "rejected", "supersededLocally", "needsConfirmation"]
        var waiting = FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && $0.accountID == accountID && $0.farmGeneration == generation &&
                !excluded.contains($0.lifecycleRawValue)
        }, sortBy: [SortDescriptor(\.occurredAt, order: .reverse)])
        var result = ESheepCloudCenterSummary()
        result.waitingCount = try context.fetchCount(waiting)
        waiting.fetchLimit = 5
        result.waitingItems = try context.fetch(waiting).map {
            .init(id: $0.id, commandKind: $0.commandKind, occurredAt: $0.occurredAt)
        }
        result.rejectedCount = try context.fetchCount(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && $0.accountID == accountID && $0.farmGeneration == generation && $0.lifecycleRawValue == "rejected"
        }))
        result.assetCount = try context.fetchCount(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        }))
        let pending = ["localOnly", "queued", "transferring", "failed"]
        result.pendingAssetCount = try context.fetchCount(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation &&
                (pending.contains($0.thumbnailStateRawValue) || pending.contains($0.avatarStateRawValue) || pending.contains($0.originalStateRawValue))
        }))
        result.failedAssetCount = try context.fetchCount(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation &&
                ($0.thumbnailStateRawValue == "failed" || $0.avatarStateRawValue == "failed" || $0.originalStateRawValue == "failed")
        }))
        return result
    }
}

struct ESheepCloudLocalSpace: Sendable, Equatable {
    struct Bytes: Sendable, Equatable {
        var logical: Int64 = 0
        var allocated: Int64 = 0
    }
    var database = Bytes()
    var receiving = Bytes()
    var photos = Bytes()
}

actor ESheepCloudSpaceReader {
    func load(databaseURLs: [URL], support: URL, farmID: UUID) throws -> ESheepCloudLocalSpace {
        var result = ESheepCloudLocalSpace()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        func bytes(_ url: URL) throws -> ESheepCloudLocalSpace.Bytes {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return .init() }
            return .init(logical: Int64(values.fileSize ?? 0), allocated: Int64(values.totalFileAllocatedSize ?? 0))
        }
        func tree(_ root: URL) throws -> ESheepCloudLocalSpace.Bytes {
            var total = ESheepCloudLocalSpace.Bytes()
            guard FileManager.default.fileExists(atPath: root.path) else { return total }
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return total }
            for case let url as URL in files {
                try Task.checkCancellation()
                let size = try bytes(url)
                total.logical += size.logical; total.allocated += size.allocated
            }
            return total
        }
        for url in Set(databaseURLs) {
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: file.path) {
                    let size = try bytes(file)
                    result.database.logical += size.logical; result.database.allocated += size.allocated
                }
            }
        }
        for path in ["ESheepCloud/Staging", "ESheepCloud/Checkpoints"] {
            let size = try tree(support.appending(path: path))
            result.receiving.logical += size.logical; result.receiving.allocated += size.allocated
        }
        result.photos = try tree(support.appending(path: "eSheepNext/FarmAssets/\(farmID.uuidString.lowercased())"))
        return result
    }
}
