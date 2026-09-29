import Foundation
import SwiftData
import Supabase
import XCTest
@testable import eSheepNext

@MainActor
final class ESheepCloudIntegratedTests: XCTestCase {
    func testCheckpointPipelineImportsOutOfOrderDownloadsInManifestOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CheckpointPipeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let farmID = UUID(), ownerID = UUID(), memberID = UUID()
        let profile = ESheepCloudFarmProfileV2(farmID: farmID, ownerAccountID: ownerID,
            name: "检查点恢复测试", createdAt: .now, updatedAt: .now,
            locationDisplayName: nil, latitude: nil, longitude: nil, coordinateReferenceSystem: "wgs84",
            addressSnapshot: nil, timeZoneIdentifier: "Asia/Shanghai", locationSourceRawValue: nil,
            horizontalAccuracyMeters: nil, locationUpdatedAt: nil)
        let seed = ESheepCloudFarmSeedV2(profile: profile, memberAccountID: memberID, memberRole: .worker, membershipStatus: "active")
        let baseline = try AppSchema.makeContainer(name: "baseline", isStoredInMemoryOnly: true)
        let context = ModelContext(baseline)
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: profile.name))
        let state = ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .active)
        state.integrityState = .passed
        context.insert(state)
        for _ in 0..<7 {
            context.insert(NoteRecord(farmID: farmID, text: String(repeating: "x", count: 450_000), occurredAt: .now))
        }
        try context.save()
        let manifest = try ESheepCloudCheckpointArchive.export(farmID: farmID, context: context, directory: root.appending(path: "archive"))
        let ticket = ESheepCloudCheckpointTicket(manifest: manifest, downloads: manifest.chunks.map {
            .init(index: $0.index, url: URL(string: "https://example.invalid/\($0.index)")!)
        })
        let transport = CheckpointTransportStub(ticket: ticket, directory: root.appending(path: "archive"))
        let legacy = ESheepCloudSnapshotManifestV2(snapshotID: UUID(), farmID: farmID, farmGeneration: 3,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion, boundaryEventSequence: 0, eventHeadAtCreation: 0,
            recordCounts: [], chunks: [], businessHistoryStartedAt: nil, businessHistoryEndedAt: nil,
            relationshipDigest: String(repeating: "0", count: 64), fieldVersionDigest: String(repeating: "0", count: 64),
            farmProfileDigest: try ESheepCloudCanonicalCodec.digest(profile), assets: [],
            totalDigest: String(repeating: "0", count: 64), createdAt: .now)
        let gateway = InitialSyncGatewayStub(ticket: .init(manifest: legacy, farmProfile: profile,
            memberAccountID: memberID, memberRole: .worker, membershipStatus: "active", expiresAt: .now.addingTimeInterval(1800)))
        let target = try AppSchema.makeContainer(name: "target", isStoredInMemoryOnly: true)
        XCTAssertGreaterThan(manifest.chunks.count, 3)
        await transport.enableOutOfOrderDownloads()
        let receiver = ESheepCloudCheckpointReceiver(container: target, support: root, gateway: gateway, transport: transport)
        _ = try await receiver.receive(ticket: ticket, seed: seed)
        XCTAssertEqual(try ModelContext(target).fetchCount(FetchDescriptor<NoteRecord>()), 7)
        let concurrency = await transport.maxConcurrentDownloads
        let calls = await transport.downloadCount
        XCTAssertGreaterThan(concurrency, 1)
        XCTAssertLessThanOrEqual(concurrency, 3)
        XCTAssertEqual(calls, manifest.chunks.count)
    }

    func testCheckpointReceiverResumesAfterImportAndActivatesForCurrentMember() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CheckpointReceiver-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let farmID = UUID(), ownerID = UUID(), memberID = UUID()
        let profile = ESheepCloudFarmProfileV2(farmID: farmID, ownerAccountID: ownerID,
            name: "检查点恢复测试", createdAt: .now, updatedAt: .now,
            locationDisplayName: nil, latitude: nil, longitude: nil, coordinateReferenceSystem: "wgs84",
            addressSnapshot: nil, timeZoneIdentifier: "Asia/Shanghai", locationSourceRawValue: nil,
            horizontalAccuracyMeters: nil, locationUpdatedAt: nil)
        let seed = ESheepCloudFarmSeedV2(profile: profile, memberAccountID: memberID, memberRole: .worker, membershipStatus: "active")
        let baseline = try AppSchema.makeContainer(name: "baseline", isStoredInMemoryOnly: true)
        let context = ModelContext(baseline)
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: profile.name))
        let state = ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .active)
        state.integrityState = .passed
        context.insert(state)
        try context.save()
        let manifest = try ESheepCloudCheckpointArchive.export(farmID: farmID, context: context, directory: root.appending(path: "archive"))
        let ticket = ESheepCloudCheckpointTicket(manifest: manifest, downloads: manifest.chunks.map {
            .init(index: $0.index, url: URL(string: "https://example.invalid/\($0.index)")!)
        })
        let transport = CheckpointTransportStub(ticket: ticket, directory: root.appending(path: "archive"))
        let legacy = ESheepCloudSnapshotManifestV2(snapshotID: UUID(), farmID: farmID, farmGeneration: 3,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion, boundaryEventSequence: 0, eventHeadAtCreation: 0,
            recordCounts: [], chunks: [], businessHistoryStartedAt: nil, businessHistoryEndedAt: nil,
            relationshipDigest: String(repeating: "0", count: 64), fieldVersionDigest: String(repeating: "0", count: 64),
            farmProfileDigest: try ESheepCloudCanonicalCodec.digest(profile), assets: [],
            totalDigest: String(repeating: "0", count: 64), createdAt: .now)
        let gateway = InitialSyncGatewayStub(ticket: .init(manifest: legacy, farmProfile: profile,
            memberAccountID: memberID, memberRole: .worker, membershipStatus: "active", expiresAt: .now.addingTimeInterval(1800)))
        let target = try AppSchema.makeContainer(name: "target", isStoredInMemoryOnly: true)
        let fullDiskReceiver = ESheepCloudCheckpointReceiver(container: target, support: root,
            gateway: gateway, transport: transport, availableCapacity: { _ in 0 })
        do {
            _ = try await fullDiskReceiver.receive(ticket: ticket, seed: seed)
            XCTFail("Insufficient disk space must fail before downloads or session creation")
        } catch ESheepCloudCheckpointError.insufficientDiskSpace { }
        let untouched = ModelContext(target)
        XCTAssertEqual(try untouched.fetchCount(FetchDescriptor<ESheepCloudInitialSyncSession>()), 0)
        let downloadsBeforeSpace = await transport.downloadCount
        XCTAssertEqual(downloadsBeforeSpace, 0)
        let receiver = ESheepCloudCheckpointReceiver(container: target, support: root, gateway: gateway, transport: transport)
        await transport.corruptNextDownload()
        do {
            _ = try await receiver.receive(ticket: ticket, seed: seed)
            XCTFail("A corrupt checkpoint must never activate or fall back to legacy replay")
        } catch ESheepCloudCheckpointError.digestMismatch { }
        let failed = ModelContext(target)
        XCTAssertEqual(try failed.fetchCount(FetchDescriptor<FarmRecord>()), 0)
        XCTAssertEqual(try failed.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>()).first?.state, .failed)
        await transport.expireNextDownload()
        await gateway.cancelOnePull()
        do {
            _ = try await receiver.receive(ticket: ticket, seed: seed)
            XCTFail("Expected interruption after verified import")
        } catch is CancellationError { }
        let before = ModelContext(target)
        XCTAssertEqual(try before.fetchCount(FetchDescriptor<FarmRecord>()), 0)
        XCTAssertEqual(try before.fetch(FetchDescriptor<ESheepCloudInitialSyncSession>()).first?.state, .paused)
        let switchedGateway = InitialSyncGatewayStub(ticket: .init(manifest: legacy, farmProfile: profile,
            memberAccountID: UUID(), memberRole: .worker, membershipStatus: "active", expiresAt: .now.addingTimeInterval(1800)))
        let switchedReceiver = ESheepCloudCheckpointReceiver(container: target, support: root,
            gateway: switchedGateway, transport: transport)
        do {
            _ = try await switchedReceiver.receive(ticket: ticket, seed: seed)
            XCTFail("An account switch during receipt must not activate the previous account's checkpoint")
        } catch ESheepCloudInitialSyncError.accountMismatch { }
        let rejected = ModelContext(target)
        XCTAssertEqual(try rejected.fetchCount(FetchDescriptor<FarmRecord>()), 0)
        XCTAssertEqual(try rejected.fetchCount(FetchDescriptor<ESheepCloudCheckpointState>()), 0)
        for status in ["revoked", "inactive"] {
            let revokedGateway = InitialSyncGatewayStub(ticket: .init(manifest: legacy, farmProfile: profile,
                memberAccountID: memberID, memberRole: .worker, membershipStatus: status, expiresAt: .now.addingTimeInterval(1800)))
            let revokedReceiver = ESheepCloudCheckpointReceiver(container: target, support: root,
                gateway: revokedGateway, transport: transport)
            do {
                _ = try await revokedReceiver.receive(ticket: ticket, seed: seed)
                XCTFail("An inactive member must never activate a cached checkpoint")
            } catch ESheepCloudInitialSyncError.accountMismatch { }
            XCTAssertEqual(try ModelContext(target).fetchCount(FetchDescriptor<FarmRecord>()), 0)
        }
        let queuedBytes = Data("original command awaiting reconciliation".utf8)
        let queueContext = ModelContext(target)
        let queued = ESheepCloudPendingIntent(commandID: UUID(), farmID: farmID, farmGeneration: 3,
            accountID: memberID, deviceID: UUID(), deviceSequence: 87, sourceRequestID: UUID(),
            commandKind: "record.revoke", commandEnvelopeData: queuedBytes,
            commandDigest: String(repeating: "a", count: 64), affectedStreamsData: Data("[]".utf8),
            affectedFieldsData: Data("[]".utf8), prerequisiteCommandIDsData: Data("[]".utf8),
            requiredAssetIDsData: Data("[]".utf8), lifecycle: .awaitingResult, createdAt: .now, occurredAt: .now)
        queueContext.insert(queued)
        try queueContext.save()
        do {
            _ = try await receiver.receive(ticket: ticket, seed: seed)
            XCTFail("An unresolved original command must prevent business-store replacement")
        } catch ESheepCloudCheckpointError.incomplete { }
        let protected = ModelContext(target)
        XCTAssertEqual(try protected.fetchCount(FetchDescriptor<FarmRecord>()), 0)
        XCTAssertEqual(try protected.fetch(FetchDescriptor<ESheepCloudPendingIntent>()).first?.commandEnvelopeData, queuedBytes)
        // This disposable fixture simulates completing queue reconciliation.
        queueContext.delete(queued)
        try queueContext.save()
        let secondCoordinatorReceiver = ESheepCloudCheckpointReceiver(container: target, support: root,
            gateway: gateway, transport: transport)
        async let firstReceipt = receiver.receive(ticket: ticket, seed: seed)
        async let concurrentReceipt = secondCoordinatorReceiver.receive(ticket: ticket, seed: seed)
        let (report, joinedReport) = try await (firstReceipt, concurrentReceipt)
        XCTAssertEqual(report.snapshotID, joinedReport.snapshotID)
        XCTAssertEqual(report.appliedEventHead, 0)
        let after = ModelContext(target)
        let restored = try XCTUnwrap(try after.fetch(FetchDescriptor<FarmRecord>()).first)
        XCTAssertEqual(restored.ownerAccountID, ownerID)
        XCTAssertEqual(restored.role, .worker)
        XCTAssertEqual(try after.fetch(FetchDescriptor<ESheepCloudCheckpointState>()).first?.accountID, memberID)
        XCTAssertEqual(try after.fetchCount(FetchDescriptor<ESheepCloudEventReceipt>()), 0)
        let calls = await transport.downloadCount
        XCTAssertEqual(calls, manifest.chunks.count + 2, "Corrupt and expired requests are retried; resume reuses verified chunks")
        let renewedIDs = await transport.renewedCheckpointIDs
        XCTAssertEqual(renewedIDs, [manifest.checkpointID], "URL renewal must pin the original checkpoint")
        let maintenance = ESheepCloudCheckpointMaintenance(container: target, support: root)
        let sameProcessRemoved = try await maintenance.removeCompletedReceiveFiles(farmID: farmID, accountID: memberID)
        XCTAssertEqual(sameProcessRemoved, 0, "An active importer process must keep its files")
        let directory = root.appending(path: "ESheepCloud/Checkpoints/\(memberID.uuidString.lowercased())/\(farmID.uuidString.lowercased())/\(manifest.checkpointID.uuidString.lowercased())")
        let proof = ESheepCloudCheckpointActivationProof(processToken: UUID(), checkpointID: manifest.checkpointID,
            accountID: memberID, farmID: farmID, generation: 3, eventHead: 0,
            manifestDigest: try ESheepCloudCanonicalCodec.digest(manifest))
        try JSONEncoder().encode(proof).write(to: directory.appending(path: "activation-complete"), options: .atomic)
        let paused = root.appending(path: "ESheepCloud/Staging/paused")
        try FileManager.default.createDirectory(at: paused, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: paused.appending(path: "evidence"))
        let removed = try await maintenance.removeCompletedReceiveFiles(farmID: farmID, accountID: memberID)
        XCTAssertGreaterThan(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paused.appending(path: "evidence").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "verification.store").path))
    }

    func testActivatedFarmBackfillsOnlyHistoryAfterQueueReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CheckpointHistory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let farmID = UUID(), ownerID = UUID(), memberID = UUID()
        let profile = ESheepCloudFarmProfileV2(farmID: farmID, ownerAccountID: ownerID,
            name: "检查点恢复测试", createdAt: .now, updatedAt: .now,
            locationDisplayName: nil, latitude: nil, longitude: nil, coordinateReferenceSystem: "wgs84",
            addressSnapshot: nil, timeZoneIdentifier: "Asia/Shanghai", locationSourceRawValue: nil,
            horizontalAccuracyMeters: nil, locationUpdatedAt: nil)
        let baseline = try AppSchema.makeContainer(name: "baseline", isStoredInMemoryOnly: true)
        let context = ModelContext(baseline)
        context.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: profile.name))
        let state = ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .active)
        state.integrityState = .passed
        context.insert(state)
        try context.save()
        let sheepID = UUID(), commandID = UUID()
        let genesisDigest = String(repeating: "0", count: 64)
        let firstEventDigest = String(repeating: "a", count: 64)
        let secondEventDigest = String(repeating: "b", count: 64)
        let boundaryEventDigest = String(repeating: "c", count: 64)
        let firstChainDigest = ESheepCloudCheckpointArchive.digest(
            Data("\(genesisDigest)\n\(firstEventDigest)".utf8))
        let secondChainDigest = ESheepCloudCheckpointArchive.digest(
            Data("\(firstChainDigest)\n\(secondEventDigest)".utf8))
        let boundaryChainDigest = ESheepCloudCheckpointArchive.digest(
            Data("\(secondChainDigest)\n\(boundaryEventDigest)".utf8))
        state.lastAppliedEventSequence = 3
        state.projectionDigest = boundaryChainDigest
        let sourceReceipt = ESheepCloudEventReceipt(eventID: UUID(), farmID: farmID, farmGeneration: 3,
            eventSequence: 3, commandID: commandID, eventDigest: boundaryEventDigest,
            appliedProjectionDigest: String(repeating: "f", count: 64))
        context.insert(sourceReceipt)
        context.insert(SheepRecord(id: sheepID, farmID: farmID, earTag: "history-source",
            breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .distantPast))
        try ESheepCloudPurposeHistory.record(command: .care(.setSheepPurpose(sheepID: sheepID,
            purpose: .fattening, reason: "恢复历史", expectedRevision: 1)), commandID: commandID,
            farmID: farmID, accountID: memberID, deviceID: UUID(), occurredAt: .now,
            recordedAt: .now, previousPurpose: "繁殖母羊", context: context)
        try context.save()
        let manifest = try ESheepCloudCheckpointArchive.export(farmID: farmID, context: context, directory: root.appending(path: "archive"))
        let ticket = ESheepCloudCheckpointTicket(manifest: manifest, downloads: manifest.chunks.map {
            .init(index: $0.index, url: URL(string: "https://example.invalid/\($0.index)")!)
        })
        let transport = CheckpointTransportStub(ticket: ticket, directory: root.appending(path: "archive"))
        let legacy = ESheepCloudSnapshotManifestV2(snapshotID: UUID(), farmID: farmID, farmGeneration: 3,
            schemaVersion: ESheepCloudProtocolV2.schemaVersion, boundaryEventSequence: 0, eventHeadAtCreation: 0,
            recordCounts: [], chunks: [], businessHistoryStartedAt: nil, businessHistoryEndedAt: nil,
            relationshipDigest: String(repeating: "0", count: 64), fieldVersionDigest: String(repeating: "0", count: 64),
            farmProfileDigest: try ESheepCloudCanonicalCodec.digest(profile), assets: [],
            totalDigest: String(repeating: "0", count: 64), createdAt: .now)
        let gateway = InitialSyncGatewayStub(ticket: .init(manifest: legacy, farmProfile: profile,
            memberAccountID: memberID, memberRole: .worker, membershipStatus: "active", expiresAt: .now.addingTimeInterval(1800)))
        let target = try AppSchema.makeContainer(name: "target", isStoredInMemoryOnly: true)
        let live = ModelContext(target)
        live.insert(FarmRecord(id: farmID, ownerAccountID: ownerID, name: "Keep current farm"))
        let liveState = ESheepCloudFarmState(farmID: farmID, farmGeneration: 3, activityState: .active)
        liveState.integrityState = .passed
        liveState.lastAppliedEventSequence = 3
        liveState.projectionDigest = state.projectionDigest
        let previousManifest = ESheepCloudCheckpointManifest(formatVersion: 1, minimumClientCapability: 1,
            checkpointID: UUID(), farmID: farmID, farmGeneration: 3, boundaryEventSequence: 1,
            boundaryEventDigest: firstEventDigest, receiptChainDigest: firstChainDigest,
            businessDigest: genesisDigest, modelCounts: ["DomainOperation": 0], chunks: [])
        let previousAnchor = try ESheepCloudCheckpointState(manifest: previousManifest, accountID: memberID)
        previousAnchor.stateRawValue = "active"
        live.insert(previousAnchor)
        let middleReceipt = ESheepCloudEventReceipt(eventID: UUID(), farmID: farmID, farmGeneration: 3,
            eventSequence: 2, commandID: UUID(), eventDigest: secondEventDigest,
            appliedProjectionDigest: String(repeating: "e", count: 64))
        live.insert(middleReceipt)
        let liveReceipt = ESheepCloudEventReceipt(eventID: sourceReceipt.id, farmID: farmID, farmGeneration: 3,
            eventSequence: 3, commandID: commandID, eventDigest: String(repeating: "d", count: 64),
            appliedProjectionDigest: sourceReceipt.appliedProjectionDigest)
        live.insert(liveReceipt)
        live.insert(liveState)
        live.insert(SheepRecord(id: sheepID, farmID: farmID, earTag: "Keep current sheep",
            breed: "湖羊", sex: .ewe, penID: nil, enteredAt: .distantPast))
        let queuedBytes = Data("preserve original pending command".utf8)
        let queued = ESheepCloudPendingIntent(commandID: UUID(), farmID: farmID, farmGeneration: 3,
            accountID: memberID, deviceID: UUID(), deviceSequence: 87, sourceRequestID: UUID(),
            commandKind: "record.revoke", commandEnvelopeData: queuedBytes,
            commandDigest: String(repeating: "a", count: 64), affectedStreamsData: Data("[]".utf8),
            affectedFieldsData: Data("[]".utf8), prerequisiteCommandIDsData: Data("[]".utf8),
            requiredAssetIDsData: Data("[]".utf8), lifecycle: .awaitingResult, createdAt: .now, occurredAt: .now)
        live.insert(queued); try live.save()
        let history = ESheepCloudCheckpointBusinessHistory(container: target)
        let held = try await history.restore(farmID: farmID, accountID: memberID, generation: 3,
            gateway: gateway, transport: transport)
        XCTAssertFalse(held.verified, "Pending commands defer maintenance without reporting a broken checkpoint")
        let blockedDownloads = await transport.downloadCount
        XCTAssertEqual(blockedDownloads, 0)
        XCTAssertEqual(try ModelContext(target).fetch(FetchDescriptor<ESheepCloudPendingIntent>()).first?.commandEnvelopeData, queuedBytes)
        // Disposable fixture only: simulate successful original-command reconciliation.
        live.delete(queued); try live.save()
        do {
            _ = try await history.restore(farmID: farmID, accountID: memberID, generation: 3,
                gateway: gateway, transport: transport)
            XCTFail("The exact verified boundary anchor must match")
        } catch ESheepCloudCheckpointError.digestMismatch { }
        let beforeAnchorRepair = await transport.downloadCount
        XCTAssertEqual(beforeAnchorRepair, 0)
        liveReceipt.eventDigest = sourceReceipt.eventDigest
        liveState.lastAppliedEventSequence = 2; try live.save()
        let catchingUp = try await history.restore(farmID: farmID, accountID: memberID, generation: 3,
            gateway: gateway, transport: transport)
        XCTAssertFalse(catchingUp.verified, "A newer published checkpoint must wait for ordinary sync to catch up")
        let behindDownloads = await transport.downloadCount
        XCTAssertEqual(behindDownloads, 0)
        liveState.lastAppliedEventSequence = 3; try live.save()
        middleReceipt.eventSequence = 4; try live.save()
        do {
            _ = try await history.restore(farmID: farmID, accountID: memberID, generation: 3,
                gateway: gateway, transport: transport)
            XCTFail("Missing receipts between verified checkpoints must stop history backfill")
        } catch ESheepCloudCheckpointError.incomplete { }
        middleReceipt.eventSequence = 2; try live.save()
        await transport.corruptNextDownload()
        do {
            _ = try await history.restore(farmID: farmID, accountID: memberID, generation: 3,
                gateway: gateway, transport: transport)
            XCTFail("Corrupt history must not be inserted")
        } catch ESheepCloudCheckpointError.digestMismatch { }
        XCTAssertEqual(try ModelContext(target).fetchCount(FetchDescriptor<DomainOperation>()), 0)
        let wrongMember = InitialSyncGatewayStub(ticket: .init(manifest: legacy, farmProfile: profile,
            memberAccountID: UUID(), memberRole: .worker, membershipStatus: "active", expiresAt: .now.addingTimeInterval(1800)))
        do {
            _ = try await history.restore(farmID: farmID, accountID: memberID, generation: 3,
                gateway: wrongMember, transport: transport)
            XCTFail("Changed membership must reject history insertion")
        } catch ESheepCloudInitialSyncError.accountMismatch { }
        XCTAssertEqual(try ModelContext(target).fetchCount(FetchDescriptor<DomainOperation>()), 0)
        await transport.expireNextDownload()
        let other = ESheepCloudCheckpointBusinessHistory(container: target)
        async let first = history.restore(farmID: farmID, accountID: memberID, generation: 3,
            gateway: gateway, transport: transport)
        async let second = other.restore(farmID: farmID, accountID: memberID, generation: 3,
            gateway: gateway, transport: transport)
        let results = try await (first, second)
        XCTAssertTrue(results.0.verified && results.1.verified)
        let after = ModelContext(target)
        XCTAssertEqual(try after.fetch(FetchDescriptor<DomainOperation>()).map(\.id), [commandID])
        XCTAssertEqual(try after.fetchCount(FetchDescriptor<ESheepCloudCheckpointState>()), 2)
        XCTAssertEqual(try after.fetch(FetchDescriptor<SheepRecord>()).first?.earTag, "Keep current sheep")
        XCTAssertEqual(try after.fetch(FetchDescriptor<FarmRecord>()).first?.name, "Keep current farm")
        XCTAssertEqual(try after.fetch(FetchDescriptor<ESheepCloudFarmState>()).first?.lastAppliedEventSequence, 3)
        XCTAssertEqual(Set(try after.fetch(FetchDescriptor<ESheepCloudEventReceipt>()).map(\.id)),
            Set([middleReceipt.id, sourceReceipt.id]))
        let downloads = await transport.downloadCount
        let repeatResult = try await ESheepCloudCheckpointBusinessHistory(container: target).restore(
            farmID: farmID, accountID: memberID, generation: 3, gateway: gateway, transport: transport)
        XCTAssertTrue(repeatResult.verified); XCTAssertEqual(repeatResult.inserted, 0)
        let afterRepeat = await transport.downloadCount
        XCTAssertEqual(afterRepeat, downloads)
        let pinned = await transport.renewedCheckpointIDs
        XCTAssertEqual(pinned, [manifest.checkpointID])
    }

    func testGzipRejectsTruncationTrailingDataAndOversizedExpansion() throws {
        let original = Data(repeating: 42, count: 150_000)
        let compressed = try ESheepCloudCheckpointGzip.compress(original)
        XCTAssertEqual(try ESheepCloudCheckpointGzip.decompress(compressed, expected: original.count), original)
        XCTAssertThrowsError(try ESheepCloudCheckpointGzip.decompress(compressed.dropLast(), expected: original.count))
        XCTAssertThrowsError(try ESheepCloudCheckpointGzip.decompress(compressed + Data([0]), expected: original.count))
        XCTAssertThrowsError(try ESheepCloudCheckpointGzip.decompress(compressed, expected: original.count - 1))
    }

    func testRealCloudSourceBuildsCheckpointAndImportsWithoutHistoricalReceipts() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ESHEEP_CHECKPOINT_SOURCE"]
                         ?? "/private/tmp/esheep-checkpoint-source")
        guard FileManager.default.fileExists(atPath: source.appending(path: "inventory.json").path) else {
            throw XCTSkip("Requires a sealed SELECT-only cloud source")
        }
        let output = ProcessInfo.processInfo.environment["ESHEEP_CHECKPOINT_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? source.deletingLastPathComponent().appending(path: "checkpoint-candidate-\(UUID().uuidString)")
        let start = Date()
        let builder = ESheepCloudCheckpointBuilder()
        let manifest: ESheepCloudCheckpointManifest
        if FileManager.default.fileExists(atPath: source.appending(path: "parent.json").path) {
            manifest = try await builder.refresh(sourceURL: source, outputURL: output)
        } else {
            manifest = try await builder.build(sourceURL: source, outputURL: output)
        }
        let importer = try ESheepCloudCheckpointImporter(manifest: manifest, accountID: UUID(),
                                                        storeURL: output.appending(path: "imported.store"))
        for descriptor in manifest.chunks {
            let bytes = try Data(contentsOf: output.appending(path: "archive")
                .appending(path: String(format: "%05d.json.gz", descriptor.index)))
            try await importer.importChunk(bytes, index: descriptor.index)
        }
        try await importer.finish()
        let bytes = manifest.chunks.reduce(0) { $0 + $1.compressedBytes }
        let elapsed = Date().timeIntervalSince(start)
        let receipt: [String: String] = ["boundary": String(manifest.boundaryEventSequence),
            "compressedBytes": String(bytes), "businessDigest": manifest.businessDigest,
            "elapsedSeconds": String(elapsed), "allModelCountsAndFieldsMatch": "true",
            "output": output.path]
        try JSONEncoder().encode(receipt).write(to: output.appending(path: "reconciliation.json"), options: .atomic)
        XCTAssertLessThanOrEqual(bytes, 20_000_000)
    }

    func testMissingWriteFunctionIsNotAnOfflineError() {
        let value = ESheepCloudSyncFailure.classify(FunctionsError.httpError(code: 404, data: Data()))
        XCTAssertEqual(value.kind, .serviceUnavailable)
        XCTAssertEqual(value.retryDelay(attempt: 100), 900)
        XCTAssertTrue(value.localizedDescription.contains("云端保存服务暂不可用"))
        XCTAssertEqual(ESheepCloudSyncFailure.classify(URLError(.notConnectedToInternet)).kind, .network)
        XCTAssertEqual(ESheepCloudSyncFailure(kind: .network).retryDelay(attempt: 100), 300)
    }

    func testCheckpointRegistryCoversEveryCurrentModelAndStoredField() throws {
        try ESheepCloudCheckpointRegistry.validateCoverage()
    }

    func testOfflinePurposeHistoryRoundTripsWithoutTechnicalAudit() throws {
        let source = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(source)
        let farm = UUID(), sheep = UUID(), commandID = UUID(), account = UUID(), device = UUID()
        let occurred = Date(timeIntervalSince1970: 1_800_000_000.123)
        let command = FarmCommand.care(.setSheepPurpose(sheepID: sheep, purpose: .fattening,
            reason: "离线用途历史", expectedRevision: 4))
        for _ in 0..<2 {
            try ESheepCloudPurposeHistory.record(command: command, commandID: commandID,
                farmID: farm, accountID: account, deviceID: device, occurredAt: occurred,
                recordedAt: occurred, previousPurpose: "繁殖母羊", context: context)
        }
        try context.save()
        let operations = try context.fetch(FetchDescriptor<DomainOperation>())
        XCTAssertEqual(operations.count, 1)
        let facts = SheepPurposeTimeline.facts(from: operations)
        XCTAssertEqual(facts.first?.occurredAt, occurred)
        let adapter = try XCTUnwrap(ESheepCloudCheckpointRegistry.adapters.first { $0.name == "DomainOperation" })
        let rows = try adapter.exportRows(farm, context)
        let target = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let restored = ModelContext(target)
        try adapter.insertRow(rows[0], farm, restored)
        try restored.save()
        XCTAssertEqual(SheepPurposeTimeline.facts(from: try restored.fetch(FetchDescriptor<DomainOperation>())), facts)
        context.insert(DomainOperation(farmID: farm, accountID: account, kind: .addSheep,
            summary: "Technical audit is not checkpoint history"))
        try context.save()
        XCTAssertThrowsError(try adapter.exportRows(farm, context))
    }

    func testCheckpointStreamJSONEncodingPreservesExactStoredBytes() throws {
        let source = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let sourceContext = ModelContext(source)
        let destination = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let destinationContext = ModelContext(destination)
        let farmID = UUID()
        let adapter = try XCTUnwrap(ESheepCloudCheckpointRegistry.adapters.first { $0.name == "ESheepCloudStreamState" })
        let canonical = try ESheepCloudCanonicalCodec.encode(["lastCommandKind": "weight.record"])
        let originalValues = [canonical, Data(" { \"older\": 1.0 } ".utf8), Data([0xff, 0x00])]
        for bytes in originalValues {
            let stream = ESheepCloudStreamState(farmID: farmID, farmGeneration: 3,
                streamType: "weight", streamID: UUID(), canonicalStateData: bytes)
            sourceContext.insert(stream)
        }
        try sourceContext.save()
        let records = try adapter.exportRows(farmID, sourceContext)
        for record in records {
            guard case .object(let representation) = record.values["canonicalStateData"] else {
                return XCTFail("Expected an explicit lossless JSON/Data representation")
            }
            XCTAssertEqual(representation.count, 1)
            try adapter.insertRow(record, farmID, destinationContext)
        }
        try destinationContext.save()
        let restored = try destinationContext.fetch(FetchDescriptor<ESheepCloudStreamState>())
        XCTAssertEqual(Set(restored.map(\.canonicalStateData)), Set(originalValues))
        XCTAssertEqual(try adapter.exportRows(farmID, destinationContext), records)
        XCTAssertEqual(records.filter {
            if case .object(let representation) = $0.values["canonicalStateData"] {
                return representation["json"] != nil
            }
            return false
        }.count, 1)
    }

    func testCheckpointRoundTripPreservesHistoricalFieldsWithoutBusinessInitializers() throws {
        let source = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let context = ModelContext(source)
        let farmID = UUID()
        let sheep = SheepRecord(farmID: farmID, earTag: "历史-01", breed: "湖羊", sex: .ewe,
                                penID: nil, enteredAt: Date(timeIntervalSince1970: 1_600_000_000))
        sheep.createdAt = Date(timeIntervalSinceReferenceDate: 810375058.705422)
        sheep.legacySourceKey = "preserved-source"
        sheep.legacyStatusSnapshotIsAuthoritative = true
        sheep.legacyPenSnapshotIsAuthoritative = true
        sheep.isHistoricalArchive = true
        sheep.deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(sheep)
        try context.save()
        let adapter = try XCTUnwrap(ESheepCloudCheckpointRegistry.adapters.first { $0.name == "SheepRecord" })
        let rows = try adapter.exportRows(farmID, context)
        XCTAssertEqual(rows.count, 1)
        let destination = try AppSchema.makeContainer(name: UUID().uuidString, isStoredInMemoryOnly: true)
        let restored = ModelContext(destination)
        try adapter.insertRow(rows[0], farmID, restored)
        try restored.save()
        XCTAssertEqual(try adapter.exportRows(farmID, restored), rows)
        let storedSheep = try XCTUnwrap(try restored.fetch(FetchDescriptor<SheepRecord>()).first)
        XCTAssertEqual(storedSheep.createdAt.timeIntervalSinceReferenceDate.bitPattern,
                       sheep.createdAt.timeIntervalSinceReferenceDate.bitPattern)
        let wrongFarm = UUID()
        XCTAssertThrowsError(try adapter.insertRow(rows[0], wrongFarm, restored))
    }
}

private actor CheckpointTransportStub: ESheepCloudCheckpointGateway {
    let ticket: ESheepCloudCheckpointTicket
    let directory: URL
    private(set) var downloadCount = 0
    private var outOfOrder = false
    private var activeDownloads = 0
    private(set) var maxConcurrentDownloads = 0
    func enableOutOfOrderDownloads() { outOfOrder = true }
    private var shouldExpire = false
    private var shouldCorrupt = false
    private(set) var renewedCheckpointIDs: [UUID] = []
    init(ticket: ESheepCloudCheckpointTicket, directory: URL) { self.ticket = ticket; self.directory = directory }
    func expireNextDownload() { shouldExpire = true }
    func corruptNextDownload() { shouldCorrupt = true }
    func openCheckpoint(farmID: UUID, farmGeneration: Int, checkpointID: UUID?) async throws -> ESheepCloudCheckpointTicket {
        guard ticket.manifest?.farmID == farmID, ticket.manifest?.farmGeneration == farmGeneration,
              checkpointID == nil || checkpointID == ticket.manifest?.checkpointID else { throw ESheepCloudCheckpointError.foreignFarm }
        if let checkpointID { renewedCheckpointIDs.append(checkpointID) }
        return ticket
    }
    func downloadCheckpointChunk(_ download: ESheepCloudCheckpointTicket.Download,
                                 descriptor: ESheepCloudCheckpointManifest.Chunk) async throws -> Data {
        downloadCount += 1
        activeDownloads += 1
        maxConcurrentDownloads = max(maxConcurrentDownloads, activeDownloads)
        defer { activeDownloads -= 1 }
        if outOfOrder { try await Task.sleep(for: .milliseconds(descriptor.index == 0 ? 80 : 10)) }

        if shouldExpire {
            shouldExpire = false
            throw ESheepCloudInfrastructureError.transferFailed(403)
        }
        var data = try Data(contentsOf: directory.appending(path: String(format: "%05d.json.gz", descriptor.index)))
        if shouldCorrupt {
            shouldCorrupt = false
            data[0] ^= 1
        }
        return data
    }
}
