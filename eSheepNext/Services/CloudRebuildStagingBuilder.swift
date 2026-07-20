import Foundation
import SwiftData

struct CloudRebuildStagingResult: Sendable, Equatable {
    let operationCount: Int
    let assetCount: Int
    let dailyPenCount: Int
    let entityDigest: String
}

enum CloudRebuildStagingBuilder {
    private static let storeDirectoryName = "SwiftData"
    private static let storeFileName = "staging.store"

    static func build(bundle: CloudRebuildBundle, workspace: URL) throws -> CloudRebuildStagingResult {
        try CloudRebuildBundleValidator.validate(bundle)
        let storeDirectory = workspace.appending(path: storeDirectoryName, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: storeDirectory.path) {
            try FileManager.default.removeItem(at: storeDirectory)
        }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let storeURL = storeDirectory.appending(path: storeFileName)
        let container = try AppSchema.makeContainer(name: "CloudRebuildStaging", url: storeURL)
        let context = ModelContext(container)
        context.insert(FarmRecord(
            id: bundle.farmID,
            ownerAccountID: bundle.root.ownerAccountID,
            name: bundle.root.name,
            role: bundle.scope == .privateDatabase ? .owner : .worker,
            createdAt: bundle.root.modifiedAt,
            updatedAt: bundle.root.modifiedAt
        ))

        let service = RemoteDomainApplyService()
        let mapper = CloudRecordMapper()
        var earliestHistoryChange: Date?
        for envelope in bundle.operations {
            switch try service.apply(envelope, context: context) {
            case .applied(let changedAt):
                if let changedAt {
                    earliestHistoryChange = min(earliestHistoryChange ?? changedAt, changedAt)
                }
            case .duplicate:
                break
            case .conflict:
                throw CloudRebuildError.stagingValidation("操作 \(envelope.operationID.uuidString) 产生业务冲突。")
            }
            context.insert(CloudOperationReceipt(
                farmID: bundle.farmID,
                operationID: envelope.operationID,
                recordName: mapper.recordName(for: envelope.operationID),
                serverChangeTag: nil,
                databaseScope: bundle.scope
            ))
        }

        for snapshot in bundle.assets {
            let source = workspace.appending(path: snapshot.relativePath)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CloudRebuildError.stagingValidation("照片 \(snapshot.cloudRecordName) 的 staging 文件不存在。")
            }
            let digest = CloudPayloadDigest.hex(for: try Data(contentsOf: source, options: .mappedIfSafe))
            guard digest == snapshot.envelope.payloadDigest else {
                throw CloudRebuildError.stagingValidation("照片 \(snapshot.cloudRecordName) 的摘要发生变化。")
            }
            let photo = PhotoAssetRecord(
                id: snapshot.envelope.assetID,
                farmID: bundle.farmID,
                sheepID: snapshot.envelope.entityID,
                legacySourceKey: "cloud:\(snapshot.cloudRecordName)",
                originalEarTag: "",
                relativePath: snapshot.relativePath,
                sha256: snapshot.envelope.payloadDigest,
                mimeType: snapshot.envelope.mimeType
            )
            photo.sourceSHA256 = snapshot.envelope.sourceDigest
            photo.cloudPixelWidth = snapshot.envelope.pixelWidth
            photo.cloudPixelHeight = snapshot.envelope.pixelHeight
            photo.capturedAt = snapshot.envelope.capturedAt
            photo.cloudRecordName = snapshot.cloudRecordName
            photo.isCloudAuthoritative = true
            context.insert(photo)
        }

        if let snapshot = bundle.membershipSnapshot {
            context.insert(FarmMembershipSnapshotRecord(
                farmID: snapshot.farmID,
                generation: snapshot.generation,
                issuedAt: snapshot.issuedAt,
                payload: snapshot.payload,
                signedByAccountID: snapshot.signedByAccountID,
                signedByDeviceID: snapshot.signedByDeviceID,
                capabilityCertificate: snapshot.capabilityCertificate,
                signature: snapshot.signature
            ))
        }

        try FarmHistoryRebuilder().rebuild(
            farmID: bundle.farmID,
            context: context,
            from: earliestHistoryChange ?? .distantPast
        )
        try validateBusinessState(farmID: bundle.farmID, context: context)
        try context.save()
        let dailyCount = try context.fetch(FetchDescriptor<DailyPenCountRecord>()).filter { $0.farmID == bundle.farmID }.count
        return CloudRebuildStagingResult(
            operationCount: bundle.operations.count,
            assetCount: bundle.assets.count,
            dailyPenCount: dailyCount,
            entityDigest: entityDigest(bundle.operations)
        )
    }

    static func verify(bundle: CloudRebuildBundle, workspace: URL) throws {
        let storeURL = workspace
            .appending(path: storeDirectoryName, directoryHint: .isDirectory)
            .appending(path: storeFileName)
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw CloudRebuildError.stagingValidation("独立 SwiftData Store 不存在。")
        }
        let container = try AppSchema.makeContainer(name: "CloudRebuildStaging", url: storeURL)
        let context = ModelContext(container)
        guard try context.fetch(FetchDescriptor<FarmRecord>()).contains(where: { $0.id == bundle.farmID }) else {
            throw CloudRebuildError.stagingValidation("staging Store 缺少目标牧场。")
        }
        let receiptIDs = Set(try context.fetch(FetchDescriptor<CloudOperationReceipt>())
            .filter { $0.farmID == bundle.farmID }
            .map(\.operationID))
        guard receiptIDs == Set(bundle.operations.map(\.operationID)) else {
            throw CloudRebuildError.stagingValidation("staging 操作回执与 bundle 不一致。")
        }
        let assets = try context.fetch(FetchDescriptor<PhotoAssetRecord>()).filter { $0.farmID == bundle.farmID }
        guard assets.count == bundle.assets.count else {
            throw CloudRebuildError.stagingValidation("staging 照片数量与 bundle 不一致。")
        }
        try validateBusinessState(farmID: bundle.farmID, context: context)
    }

    private static func validateBusinessState(farmID: UUID, context: ModelContext) throws {
        let transactions = try context.fetch(FetchDescriptor<InventoryTransactionRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        for (lotID, values) in Dictionary(grouping: transactions, by: \.inventoryLotID) {
            let balance = values.reduce(Decimal.zero) { partial, transaction in
                switch transaction.kind {
                case .receipt, .adjustment: partial + transaction.quantity
                case .consumption: partial - transaction.quantity
                }
            }
            guard balance >= 0 else {
                throw CloudRebuildError.stagingValidation("库存批次 \(lotID.uuidString) 出现负库存。")
            }
        }

        let memberships = try context.fetch(FetchDescriptor<BatchMembershipRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        for (sheepID, values) in Dictionary(grouping: memberships, by: \.sheepID) {
            let sorted = values.sorted { $0.joinedAt < $1.joinedAt }
            for pair in zip(sorted, sorted.dropFirst()) where (pair.0.leftAt ?? .distantFuture) > pair.1.joinedAt {
                throw CloudRebuildError.stagingValidation("羊只 \(sheepID.uuidString) 的生产批次区间重叠。")
            }
        }

        let reproductions = try context.fetch(FetchDescriptor<ReproductionRecord>())
            .filter { $0.farmID == farmID && $0.deletedAt == nil }
        guard reproductions.allSatisfy({ $0.lambCount >= 0 }) else {
            throw CloudRebuildError.stagingValidation("繁殖记录存在负产羔数。")
        }
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let sheepByID = Dictionary(uniqueKeysWithValues: sheep.map { ($0.id, $0) })
        let donors = try context.fetch(FetchDescriptor<SemenDonorRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        let donorIDs = Set(donors.map(\.id))
        for donor in donors {
            if let ramID = donor.linkedRamID {
                guard let ram = sheepByID[ramID], ram.sex == .ram, ram.isBreedingRam else {
                    throw CloudRebuildError.stagingValidation("冻精供体关联了无效种公羊。")
                }
            }
        }
        for item in sheep {
            if let damID = item.damID, sheepByID[damID]?.sex != .ewe { throw CloudRebuildError.stagingValidation("羊只 \(item.earTag) 的母本引用无效。") }
            if let sireID = item.sireID, sheepByID[sireID]?.sex != .ram { throw CloudRebuildError.stagingValidation("羊只 \(item.earTag) 的父本引用无效。") }
            if let donorID = item.semenDonorID, !donorIDs.contains(donorID) { throw CloudRebuildError.stagingValidation("羊只 \(item.earTag) 的冻精供体引用无效。") }
            if pedigreeCycle(target: item.id, root: item.damID, sheepByID: sheepByID) || pedigreeCycle(target: item.id, root: item.sireID, sheepByID: sheepByID) { throw CloudRebuildError.stagingValidation("羊只 \(item.earTag) 存在循环系谱。") }
            if let birthAt = item.birthAt, let damBirth = item.damID.flatMap({ sheepByID[$0]?.birthAt }), damBirth >= birthAt { throw CloudRebuildError.stagingValidation("羊只 \(item.earTag) 的母系日期倒置。") }
            if let birthAt = item.birthAt, let sireBirth = item.sireID.flatMap({ sheepByID[$0]?.birthAt }), sireBirth >= birthAt { throw CloudRebuildError.stagingValidation("羊只 \(item.earTag) 的父系日期倒置。") }
        }
        let semen = try context.fetch(FetchDescriptor<SemenRecord>()).filter { $0.farmID == farmID && $0.deletedAt == nil }
        guard semen.allSatisfy({ $0.donorID == nil || donorIDs.contains($0.donorID!) }) else { throw CloudRebuildError.stagingValidation("冻精批次存在无效供体引用。") }
        let reproductionIDs = Set(reproductions.map(\.id))
        guard reproductions.allSatisfy({ $0.relatedBreedingRecordID == nil || reproductionIDs.contains($0.relatedBreedingRecordID!) }) else { throw CloudRebuildError.stagingValidation("繁殖链存在无效配种引用。") }
        let dailyCounts = try context.fetch(FetchDescriptor<DailyPenCountRecord>())
            .filter { $0.farmID == farmID }
        guard dailyCounts.allSatisfy({ $0.count >= 0 }) else {
            throw CloudRebuildError.stagingValidation("历史重建产生负圈舍存栏。")
        }
    }

    private static func entityDigest(_ operations: [CloudOperationEnvelope]) -> String {
        let text = operations.sorted { $0.operationID.uuidString < $1.operationID.uuidString }.map {
            "\($0.operationID.uuidString.lowercased()):\($0.revision):\($0.payloadDigest)"
        }.joined(separator: "\n")
        return CloudPayloadDigest.hex(for: Data(text.utf8))
    }

    private static func pedigreeCycle(target: UUID, root: UUID?, sheepByID: [UUID: SheepRecord]) -> Bool {
        guard let root else { return false }
        var pending = [root]
        var visited = Set<UUID>()
        while let id = pending.popLast() {
            if id == target { return true }
            guard visited.insert(id).inserted, let item = sheepByID[id] else { continue }
            if let damID = item.damID { pending.append(damID) }
            if let sireID = item.sireID { pending.append(sireID) }
        }
        return false
    }
}
