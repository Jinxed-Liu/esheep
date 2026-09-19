import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

@MainActor
final class CheckpointLabelCompatibilityTests: XCTestCase {
    private let labelModels = ["SheepLabelRecord", "SheepLabelAssignmentRecord", "SheepLabelChangeRecord"]

    func testLegacyCheckpointWithoutLabelCountsFinishesAndResumes() async throws {
        try await checkImport(omit: Set(labelModels), shouldPass: true)
    }

    func testCurrentCheckpointAdvertisesEveryTransferredModelCount() throws {
        let farmID = UUID(), accountID = UUID()
        let source = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(source)
        context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "完整清单"))
        let state = ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .active)
        state.integrityState = .passed
        context.insert(state)
        try context.save()

        let root = FileManager.default.temporaryDirectory.appending(path: "CheckpointCountContract-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try ESheepCloudCheckpointArchive.export(farmID: farmID, context: context, directory: root)
        let transferModels = Set(ESheepCloudCheckpointRegistry.adapters
            .filter { $0.disposition == .transfer }.map(\.name))
        XCTAssertEqual(Set(manifest.modelCounts.keys), transferModels)
        for model in labelModels {
            XCTAssertEqual(manifest.modelCounts[model], 0, "New checkpoints must publish an explicit zero for \(model)")
        }
    }

    func testCurrentCheckpointWithLabelsStillVerifies() async throws {
        try await checkImport(includeLabel: true, shouldPass: true)
    }

    func testLegacyCheckpointCannotHideUnadvertisedLabelRows() async throws {
        try await checkImport(omit: Set(labelModels), injectLabel: true, shouldPass: false)
    }

    func testCompatibilityStillRejectsChangedBusinessDigest() async throws {
        try await checkImport(omit: Set(labelModels), corruptDigest: true, shouldPass: false)
    }

    func testCompatibilityDoesNotPermitMissingExistingModel() async throws {
        try await checkImport(omit: Set(labelModels + ["WeightRecord"]), shouldPass: false)
    }

    func testCompatibilityDoesNotPermitUnknownModelEvenWhenEmpty() async throws {
        try await checkImport(unknownModel: true, shouldPass: false)
    }

    private func checkImport(omit: Set<String> = [], includeLabel: Bool = false,
                             injectLabel: Bool = false, corruptDigest: Bool = false,
                             unknownModel: Bool = false, shouldPass: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CheckpointLabels-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let farmID = UUID(), accountID = UUID()
        let source = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(source)
        context.insert(FarmRecord(id: farmID, ownerAccountID: accountID, name: "旧检查点兼容"))
        let state = ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .active)
        state.integrityState = .passed
        context.insert(state)
        if includeLabel {
            context.insert(SheepLabelRecord(farmID: farmID, name: "当前标签"))
        }
        try context.save()
        let archive = root.appending(path: "archive")
        let original = try ESheepCloudCheckpointArchive.export(farmID: farmID, context: context, directory: archive)
        var counts = original.modelCounts.filter { !omit.contains($0.key) }
        if unknownModel { counts["UnknownFutureModel"] = 0 }
        let manifest = ESheepCloudCheckpointManifest(formatVersion: original.formatVersion,
            minimumClientCapability: original.minimumClientCapability, checkpointID: original.checkpointID,
            farmID: farmID, farmGeneration: original.farmGeneration,
            boundaryEventSequence: original.boundaryEventSequence,
            boundaryEventDigest: original.boundaryEventDigest, receiptChainDigest: original.receiptChainDigest,
            businessDigest: corruptDigest ? String(repeating: "f", count: 64) : original.businessDigest,
            modelCounts: counts, chunks: original.chunks)
        let storeURL = root.appending(path: "import.store")
        let importer = try ESheepCloudCheckpointImporter(manifest: manifest, accountID: accountID, storeURL: storeURL)
        for chunk in manifest.chunks {
            try await importer.importChunk(Data(contentsOf: archive.appending(path: String(format: "%05d.json.gz", chunk.index))),
                                           index: chunk.index)
        }
        if injectLabel {
            // Only a disposable verification fixture is changed here: an
            // unadvertised nonempty additive model must still fail closed.
            let tampered = try AppSchema.makeContainer(name: "tampered", url: storeURL)
            let tamperedContext = ModelContext(tampered)
            tamperedContext.insert(SheepLabelRecord(farmID: farmID, name: "未声明标签"))
            try tamperedContext.save()
        }
        do {
            try await importer.finish()
            XCTAssertTrue(shouldPass, "A mismatched checkpoint must remain unverified")
            try await importer.finish()
            let head = try await importer.currentHead()
            XCTAssertEqual(head, original.boundaryEventSequence)
        } catch ESheepCloudCheckpointError.digestMismatch {
            XCTAssertFalse(shouldPass, "Empty additive models must not invalidate a legacy checkpoint")
        }
    }
}
