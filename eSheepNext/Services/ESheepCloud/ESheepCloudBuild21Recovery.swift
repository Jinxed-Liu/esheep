import Foundation
import SwiftData

/// Owner-authorized incident recovery. Only the 21 immutable request digests
/// captured before repair are eligible; a new rejection never starts a loop.
/// Each original command ID must also be absent from the current cloud ledger.
enum ESheepCloudBuild21Recovery {
    enum PhotoPlan {
        case ready(bundleID: UUID?)
        case deferred(String)
    }

    /// Deleting the selected photo also needs an explicit avatar-clear event.
    /// Only clear the exact photo requested for deletion, with its observed
    /// field version; preserve any newer selection or pending avatar edit.
    static func preparePhoto(_ original: ESheepCloudCommandEnvelopeV2, context: ModelContext) throws -> PhotoPlan {
        guard case .deletion(.tombstone(.photoAsset, let assetID, _)) = original.payload else {
            return .ready(bundleID: nil)
        }
        let farmID = original.farmID
        let generation = original.farmGeneration
        guard let sheepID = try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate {
            $0.id == assetID && $0.farmID == farmID
        })).first?.sheepID else { return .deferred("照片所属羊只尚未核实，已保留原删除请求。") }
        guard let stream = try context.fetch(FetchDescriptor<ESheepCloudStreamState>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation &&
                $0.streamType == "sheepAvatar" && $0.streamID == sheepID
        })).first else { return .deferred("尚未核实这只羊的云端头像，已保留原删除请求。") }
        let entries = try ESheepCloudCanonicalCodec.decode([ESheepCloudFieldVersionEntryV2].self, from: stream.fieldVersionsData)
        guard let avatar = entries.first(where: { $0.field == "avatar" }), let value = avatar.value else {
            return .deferred("云端头像版本信息不完整，已保留原删除请求。")
        }
        guard value == .identifier(assetID) else { return .ready(bundleID: nil) }
        if let changedAt = avatar.occurredAt, changedAt > original.occurredAt {
            return .deferred("这张照片在删除请求之后又被选作头像，需要核对后再删除。")
        }
        let terminal = ["accepted", "rejected", "supersededLocally"]
        let outstanding = try context.fetch(FetchDescriptor<ESheepCloudPendingIntent>(predicate: #Predicate {
            $0.farmID == farmID && $0.farmGeneration == generation && !terminal.contains($0.lifecycleRawValue)
        }))
        for item in outstanding where ["sheepAvatar.set", "sheepAvatar.clear"].contains(item.commandKind) {
            let envelope = try ESheepCloudCanonicalCodec.decode(ESheepCloudCommandEnvelopeV2.self, from: item.commandEnvelopeData)
            if envelope.affectedStreams.contains(where: { $0.type == "sheepAvatar" && $0.id == sheepID }) {
                return .deferred("这只羊还有正在保存的头像变更，原删除请求继续保留。")
            }
        }
        let selections = try context.fetch(FetchDescriptor<SheepAvatarRecord>(predicate: #Predicate {
            $0.farmID == farmID && $0.sheepID == sheepID
        }))
        if let local = selections.max(by: { $0.updatedAt < $1.updatedAt }),
           let selected = local.photoAssetID, selected != assetID {
            return .deferred("本机已选择另一张头像，需先核对头像保存结果。")
        }
        let clearID = StableCloudUUID.derived(namespace: original.commandID, name: "build21-photo-avatar-clear-v1")
        let bundleID = StableCloudUUID.derived(namespace: original.commandID, name: "build21-photo-deletion-bundle-v1")
        let sequence = try FarmStorageRouter.takeNextOperationSequence(farmID: farmID, operationID: clearID, context: context)
        _ = try ESheepCloudIntentWriter.stage(
            draft: ESheepCloudCommandFactoryV2.avatar(sheepID: sheepID, photoAssetID: nil, occurredAt: original.occurredAt),
            commandID: clearID, sourceRequestID: clearID, bundleID: bundleID, farmID: farmID,
            farmGeneration: generation, accountID: original.accountID, deviceID: original.deviceID,
            deviceSequence: sequence, context: context)
        try SheepAvatarSelectionStore.apply(.init(photoAssetID: nil), sheepID: sheepID, farmID: farmID,
            updatedAt: original.occurredAt, context: context)
        return .ready(bundleID: bundleID)
    }

    static let originalDigests: Set<String> = [
        "a80bb7026a9f9c48ce93c2544420425216182bbf478ed7f572973c883014a935",
        "1da55d23556e6d080bc847ab59b08e1735bc2948df8f5c4b1fc86f573880af8c",
        "9d7ca30b2757718040ac73abf346e2c510bce4ec8356d346d0ed8fcb868487fc",
        "c9254a20a6d36e1e01c012b2e6ca386b09d3874225412bdd5e233923b90521c5",
        "8e0583f707cdd79ab54a593ab8668a07115d800b282520195d3c6e822e86b533",
        "0c080d253b1431791a3d022fc1781a2b116de71ba94efdde402cd72d295539fc",
        "ca67ea6c48dcab5d30d706dbdf572425b5a39e6820ddf427eb24c8b403686ee9",
        "44c9fe88ddff83c3b52d12eb136c9fc2af435bc7ec097fd3d1b8f57f8256c85a",
        "85655236eaaf8cdad3323867f8830c63b9f2f0e3aaddbf422c1b8d95d59c2885",
        "a4c970c10b8d54826b8b31f98cc6dc4db37a1eb1639b681cc4e550d310baa997",
        "147f8a386f046b43b19d06caffca0822094d7d1b644884d26a88665bca1559e0",
        "b85bc305e92d56284671fc32801c2ab3124209f8e19d2bfe1747b1ffb5f4c900",
        "6e6981da77d03c1e02d08feb92362286ae4356a5ba4d1f1bd5ab57e17eb84cb4",
        "a5b19a3ce1db8701b5010d697cc63eaa79114e12c6b508af22de47409164e03f",
        "5ff0f54bf1437ce8dd245acea606fbc8cda4d24715c24e7114b42a3ef5bc5518",
        "412f3195888f80398e2e398ef50c4fe4f32d62bd9cae2ff47851288d55d88e7f",
        "61555ee6b359aa5d8cc8ba667ad2785a8611f2e8377850b723f7961f5b6a72a8",
        "c8fa7ff25271562bc86252f265cc7adb9d867b5f299909c73d72b9b13f702ff6",
        "65e50cc4472ad39316b9c6853841464758cbfcebc24c602cc0076afb533a8f76",
        "ff36de3afa887ca7c43e83a53bbe0180bce9f0c4bba3e654c0585163575f3a75",
        "b7f959a2b959af599b1d720ac62b54a68ff28b188d938a62a1fe9ac5e657e312",
    ]
}
