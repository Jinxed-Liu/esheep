import Foundation
import SwiftData

struct ESheepCloudCenterSummary: Sendable, Equatable {
    struct WaitingItem: Identifiable, Sendable, Equatable {
        let id: UUID
        let commandKind: String
        let occurredAt: Date
    }
    struct RejectedItem: Identifiable, Sendable, Equatable {
        let id: UUID
        let commandKind: String
        let occurredAt: Date
        let explanation: String
        let deviceID: UUID
        let deviceSequence: Int64
        let recordDisplayName: String
        let fieldEvidence: String
    }
    var rejectedItems: [RejectedItem] = []
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
        let rejected = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && $0.accountID == accountID && $0.farmGeneration == generation && $0.lifecycleRawValue == "rejected"
        }, sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]))
        let sheep = rejected.isEmpty ? [] : try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.farmID == farmID }))
        let photos = rejected.isEmpty ? [] : try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate { $0.farmID == farmID }))
        let earTags = Dictionary(sheep.map { ($0.id, $0.earTag) }, uniquingKeysWith: { first, _ in first })
        let photoOwners = Dictionary(photos.map { ($0.id, $0.sheepID) }, uniquingKeysWith: { first, _ in first })
        result.rejectedItems = rejected.map { intent in
            let envelope = try? ESheepCloudCanonicalCodec.decode(ESheepCloudCommandEnvelopeV2.self, from: intent.commandEnvelopeData)
            let sheepID: UUID?
            switch envelope?.payload {
            case .fact(.recordWeaning(let id, _, _, _, _, _, _, _, _)), .fact(.transferSheep(let id, _, _, _)):
                sheepID = id
            case .care(.setSheepPurpose(let id, _, _, _)): sheepID = id
            case .deletion(.tombstone(.photoAsset, let id, _)): sheepID = photoOwners[id] ?? nil
            default: sheepID = envelope?.affectedStreams.first(where: { ["sheep", "sheepProfile", "sheepLocation"].contains($0.type) })?.id
            }
            let displayName = sheepID.flatMap { earTags[$0] } ?? "记录详情见核对信息"
            let fieldEvidence = (envelope?.affectedFields ?? []).map {
                "\($0.stream.type)/\($0.stream.id) \($0.field)：本机依据版本 \($0.observedVersion)，值摘要 \($0.baseValueDigest)"
            }.joined(separator: "\n")
            let response = intent.serverResultData.flatMap {
                try? ESheepCloudCanonicalCodec.decode(ESheepCloudCommandResultV2.self, from: $0)
            }
            let reason: ESheepCloudRejectionReasonV2?
            switch response {
            case .rejected(let value): reason = value
            case .duplicate(let original): reason = original.rejection
            default: reason = nil
            }
            let explanation: String
            switch reason {
            case .businessRule(let code, let message, _): explanation = "\(message)（\(code)）"
            case .malformedCommand(let message): explanation = intent.lastTransportMessage ?? message
            case .permissionDenied: explanation = "当前账号没有保存这项内容的权限。"
            case .applicationUpdateRequired: explanation = "需要更新 App 后处理这项内容。"
            default: explanation = intent.lastTransportMessage ?? "云端未接受这项内容，本机记录已保留。"
            }
            return .init(id: intent.id, commandKind: intent.commandKind, occurredAt: intent.occurredAt,
                         explanation: explanation, deviceID: intent.deviceID, deviceSequence: intent.deviceSequence,
                         recordDisplayName: displayName, fieldEvidence: fieldEvidence)
        }
        result.assetCount = try context.fetchCount(FetchDescriptor<ESheepCloudAssetState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation
        }))
        let pending: [String] = ["localOnly", "queued", "transferring", "failed"]
        // Build the same predicate tree in steps to keep each type-checking expression small.
        let pendingAssetPredicate = Predicate<ESheepCloudAssetState> { asset in
            let farmMatches = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.farmID),
                rhs: PredicateExpressions.build_Arg(farmID)
            )
            let generationMatches = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.farmGeneration),
                rhs: PredicateExpressions.build_Arg(generation)
            )
            let scopeMatches = PredicateExpressions.build_Conjunction(lhs: farmMatches, rhs: generationMatches)
            let pendingStates = PredicateExpressions.build_Arg(pending)
            let thumbnailPending = PredicateExpressions.build_contains(
                pendingStates,
                PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.thumbnailStateRawValue)
            )
            let avatarPending = PredicateExpressions.build_contains(
                pendingStates,
                PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.avatarStateRawValue)
            )
            let originalPending = PredicateExpressions.build_contains(
                pendingStates,
                PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.originalStateRawValue)
            )
            let previewPending = PredicateExpressions.build_Disjunction(lhs: thumbnailPending, rhs: avatarPending)
            let renditionPending = PredicateExpressions.build_Disjunction(lhs: previewPending, rhs: originalPending)
            return PredicateExpressions.build_Conjunction(lhs: scopeMatches, rhs: renditionPending)
        }
        let pendingAssets = FetchDescriptor<ESheepCloudAssetState>(predicate: pendingAssetPredicate)
        result.pendingAssetCount = try context.fetchCount(pendingAssets)
        let failedAssetPredicate = Predicate<ESheepCloudAssetState> { asset in
            let farmMatches = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.farmID),
                rhs: PredicateExpressions.build_Arg(farmID)
            )
            let generationMatches = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.farmGeneration),
                rhs: PredicateExpressions.build_Arg(generation)
            )
            let scopeMatches = PredicateExpressions.build_Conjunction(lhs: farmMatches, rhs: generationMatches)
            let failedState = PredicateExpressions.build_Arg("failed")
            let thumbnailFailed = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.thumbnailStateRawValue),
                rhs: failedState
            )
            let avatarFailed = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.avatarStateRawValue),
                rhs: failedState
            )
            let originalFailed = PredicateExpressions.build_Equal(
                lhs: PredicateExpressions.build_KeyPath(root: asset, keyPath: \ESheepCloudAssetState.originalStateRawValue),
                rhs: failedState
            )
            let previewFailed = PredicateExpressions.build_Disjunction(lhs: thumbnailFailed, rhs: avatarFailed)
            let renditionFailed = PredicateExpressions.build_Disjunction(lhs: previewFailed, rhs: originalFailed)
            return PredicateExpressions.build_Conjunction(lhs: scopeMatches, rhs: renditionFailed)
        }
        let failedAssets = FetchDescriptor<ESheepCloudAssetState>(predicate: failedAssetPredicate)
        result.failedAssetCount = try context.fetchCount(failedAssets)
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
