import Foundation
import SwiftData
import XCTest
@testable import eSheepNext

/// Opt-in local evidence only. Private farm data never becomes a test resource.
@MainActor
final class RealFarmIsolationAcceptanceTests: XCTestCase {
    func testPrivateDatabaseMigrationAndPageProjections() async throws {
        guard let path = ProcessInfo.processInfo.environment["ESHEEP_PRIVATE_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Supply a private backup directory for isolated real-farm acceptance")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let source = root.appending(path: "database-before", directoryHint: .isDirectory)
        let destination = root.appending(path: "database-after-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for suffix in ["", "-wal", "-shm"] {
            let name = "eSheepNext.store\(suffix)"
            if FileManager.default.fileExists(atPath: source.appending(path: name).path) {
                try FileManager.default.copyItem(at: source.appending(path: name), to: destination.appending(path: name))
            }
        }
        let started = Date.now
        let container = try AppSchema.makeContainer(url: destination.appending(path: "eSheepNext.store"))
        let migrationSeconds = Date.now.timeIntervalSince(started)
        try await verifyPages(container: container, root: root, destination: destination,
                              migrationSeconds: migrationSeconds, started: started)
    }

    private func verifyPages(container: ModelContainer, root: URL, destination: URL,
                             migrationSeconds: TimeInterval, started: Date, reportName: String = "native-acceptance") async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let farms = try context.fetch(FetchDescriptor<FarmRecord>())
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>())
        let reproduction = try context.fetch(FetchDescriptor<ReproductionRecord>())
        let pens = try context.fetch(FetchDescriptor<PenRecord>())
        XCTAssertFalse(farms.isEmpty)
        XCTAssertFalse(sheep.isEmpty)
        var reports: [[String: Any]] = []
        for farm in farms where farm.deletedAt == nil {
            let now = Date.now
            let payload = try await FarmDeepAnalyticsSnapshotActor(container: container).load(farmID: farm.id, now: now)
            let management = try ReproductionManagementEngine.calculate(snapshot: payload.snapshot)
            let members = sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.isCurrentlyPresent && $0.enteredAt <= now }
            XCTAssertEqual(payload.activeSheepCount, members.count)
            let facts = ReproductionCycleResolver.facts(records: reproduction.filter { $0.farmID == farm.id && $0.deletedAt == nil })
            let allEwes = sheep.filter { $0.farmID == farm.id && $0.deletedAt == nil && $0.sex == .ewe }
            let states = Dictionary(uniqueKeysWithValues: allEwes.map { ($0.id, ReproductionCycleResolver.resolve(eweID: $0.id, facts: facts, asOf: now)) })
            var allScopeSnapshot = payload.snapshot
            var allScopeSettings = payload.snapshot.reproductionSettings ?? ReproductionManagementSettings()
            allScopeSettings.scopeConfigured = true
            allScopeSettings.selectedPenIDs = payload.snapshot.pens.filter(\.isActive).map(\.id)
            allScopeSnapshot.reproductionSettings = allScopeSettings
            let allScope = try ReproductionManagementEngine.calculate(snapshot: allScopeSnapshot)
            XCTAssertEqual(Set(allScope.ewes.map(\.id)), Set(members.filter { $0.sex == .ewe && allScopeSettings.selectedPenIDs.contains($0.currentPenID ?? UUID()) }.map(\.id)))
            for row in management.ewes + allScope.ewes {
                XCTAssertEqual(row.pregnancy, states[row.id]?.pregnancy, row.earTag)
                XCTAssertEqual(row.parity, states[row.id]?.completedParity, row.earTag)
            }
            let penActor = PenManagementSnapshotActor(container: container)
            var penMembers = 0
            for pen in pens where pen.farmID == farm.id && pen.deletedAt == nil {
                let loadedPen = try await penActor.loadDetail(farmID: farm.id, penID: pen.id)
                let detail = try XCTUnwrap(loadedPen)
                let expected = members.filter { $0.currentPenID == pen.id }
                XCTAssertEqual(Set(detail.sheep.map(\.id)), Set(expected.map(\.id)), pen.name)
                for row in detail.sheep where states[row.id] != nil {
                    XCTAssertEqual(row.reproductionState, states[row.id]?.displayState, row.earTag)
                }
                penMembers += detail.sheep.count
            }
            let actor = SheepDetailSnapshotActor(container: container)
            let historical = allEwes.filter { !$0.isCurrentlyPresent }.sorted { $0.earTag < $1.earTag }
            let candidates = members + Array(historical.prefix(20)) + Array(sheep.filter(\.isHistoricalArchive).prefix(10))
            let selected = Dictionary(grouping: candidates, by: \.id).values.compactMap(\.first).sorted { $0.earTag < $1.earTag }
            let canonical = SheepWeightSampleBuilder.dailyCanonical(payload.snapshot.weightSamples.filter { $0.occurredAt <= now }, calendar: Calendar.farm(identifier: farm.timeZoneIdentifier))
            let pointsBySheep = Dictionary(grouping: canonical, by: \.sheepID)
            var details: [[String: Any]] = []
            for ewe in selected {
                let subject = SheepDetailSubjectSnapshot(record: ewe)
                XCTAssertEqual(subject.analyticsValue.isHistoricalArchive, ewe.isHistoricalArchive, ewe.earTag)
                let result = try await actor.load(farmID: farm.id, sheepID: ewe.id, subject: SheepDetailSubjectSnapshot(record: ewe))
                XCTAssertEqual(result.reproductionState?.pregnancy, states[ewe.id]?.pregnancy, ewe.earTag)
                XCTAssertEqual(result.currentParity, states[ewe.id]?.completedParity, ewe.earTag)
                let expectedPoints = pointsBySheep[ewe.id] ?? []
                XCTAssertEqual(result.canonicalWeights.count, expectedPoints.count, "Weight point count: \(ewe.earTag)")
                for (actual, expected) in zip(result.canonicalWeights, expectedPoints) {
                    XCTAssertEqual(actual.occurredAt, expected.occurredAt, "Weight date: \(ewe.earTag)")
                    XCTAssertEqual(actual.kilograms, expected.kilograms, accuracy: 0.000001, "Weight value: \(ewe.earTag)")
                }
                let points: [[String: Any]] = result.canonicalWeights.map { ["at": $0.occurredAt.timeIntervalSince1970 * 1000, "kilograms": $0.kilograms, "source": $0.source.rawValue] }
                let intervals: [[String: Any]] = result.weightGainIntervals.map { ["from": $0.startDate.timeIntervalSince1970 * 1000, "to": $0.endDate.timeIntervalSince1970 * 1000, "days": $0.intervalDays, "kgPerDay": $0.kilogramsPerDay] }
                details.append(["id": ewe.id.uuidString.lowercased(), "earTag": ewe.earTag, "state": result.reproductionState?.displayState ?? "", "weightPoints": points.count, "points": points, "intervals": intervals])
            }
            let queryArguments: [String: Any] = ["query_kind": "current_herd", "subject": "sheep", "sex": "ewe", "group_by": "reproduction_state", "metric": "count", "date_field": "none", "date_from": "", "date_to": "", "as_of": "", "ear_tag": "", "status": "", "breed": "", "pen_name": "", "kind": "", "item_name": "", "minimum_value": "", "maximum_value": "", "relations": [], "limit": 100]
            let query = try InsightFarmQueryEngine().execute(arguments: queryArguments, farmID: farm.id, context: context, now: now)
            let grounded = try XCTUnwrap(InsightFarmQueryEngine.GroundedOutput(toolOutput: query))
            let currentEwes = members.filter { $0.sex == .ewe }
            XCTAssertEqual(grounded.totalMatchingCount, currentEwes.count)
            let counts = Dictionary(grouping: currentEwes, by: { states[$0.id]!.pregnancy.rawValue }).mapValues(\.count)
            for (state, count) in counts {
                XCTAssertTrue(grounded.markdown.contains("| \(state) | \(count) |"), "AI count mismatch: \(state) = \(count)")
            }
            try Data(query.utf8).write(to: destination.appending(path: "query-\(farm.id).json"))
            try InHerdSheepExport.csvData(farmID: farm.id, sheep: sheep, pens: pens, reproduction: reproduction).write(to: destination.appending(path: "export-\(farm.id).csv"))
            let alerts = try await FarmOperationalAlertSnapshotActor(container: container).load(farmID: farm.id, now: now)
            var exported: [ESheepCloudCheckpointRecord] = []
            let models: Set<String> = ["FarmRecord", "SheepRecord", "PenRecord", "WeightRecord", "WeaningRecord", "ReproductionRecord", "LambingOffspringRecord", "TransferRecord", "RemovalRecord", "FarmCareRuleRecord", "CareReminderRecord", "FarmAlertDeferralRecord"]
            for adapter in ESheepCloudCheckpointRegistry.adapters where models.contains(adapter.name) {
                exported += try adapter.exportRows(farm.id, context)
            }
            try JSONEncoder().encode(exported).write(to: destination.appending(path: "business-records.json"))
            let stateRows: [[String: Any]] = allEwes.map { ewe in
                let state = states[ewe.id]!
                return ["id": ewe.id.uuidString.lowercased(), "earTag": ewe.earTag, "present": ewe.isCurrentlyPresent,
                        "state": state.displayState, "pregnancy": state.pregnancy.rawValue, "parity": state.completedParity.map { $0 as Any } ?? NSNull(), "targetParity": state.targetParity.map { $0 as Any } ?? NSNull(),
                        "cycleID": state.cycleID.uuidString.lowercased(), "roundID": state.breedingRoundID.map { $0.uuidString.lowercased() as Any } ?? NSNull(), "issues": state.issues]
            }
            let scopedRows: [[String: Any]] = allScope.ewes.map { ["id": $0.id.uuidString.lowercased(), "earTag": $0.earTag, "eligible": $0.isCheckEligible, "pregnancy": $0.pregnancy.rawValue, "stage": $0.stageTitle, "category": $0.category.rawValue] }
            let alertRows: [[String: Any]] = alerts.operationalAlerts.map { ["id": $0.id.uuidString.lowercased(), "kind": $0.kind.rawValue, "subjectID": $0.subjectID.uuidString.lowercased(), "title": $0.title, "dueAt": $0.dueAt.timeIntervalSince1970 * 1000] }
            reports.append(["alerts": alertRows, "asOf": now.timeIntervalSince1970 * 1000, "states": stateRows, "allScopeRows": scopedRows, "allScopeEligible": allScope.eligibleCount, "farmID": farm.id.uuidString, "farmName": farm.name, "currentSheep": members.count, "allEwes": allEwes.count, "analysisEwes": management.ewes.count, "penMembers": penMembers, "details": details, "alertCount": alerts.operationalAlerts.count])
        }
        let report: [String: Any] = ["databaseDirectory": destination.path, "migrationSeconds": migrationSeconds, "totalSeconds": Date.now.timeIntervalSince(started), "sheepRecords": sheep.count, "reproductionRecords": reproduction.count, "farms": reports]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appending(path: "\(reportName).json"))
        print("REAL_FARM_ISOLATED_ACCEPTANCE \(destination.path) \(sheep.count) sheep records")
    }
    func testPrivateAuthoritativeCheckpointAndEventReplay() async throws {
        guard let path = ProcessInfo.processInfo.environment["ESHEEP_PRIVATE_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Supply a private authoritative checkpoint directory")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try JSONDecoder().decode(ESheepCloudCheckpointManifest.self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        let destination = root.appending(path: "cloud-copy-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let url = destination.appending(path: "eSheepNext.store")
        let started = Date.now
        let importer = try ESheepCloudCheckpointImporter(manifest: manifest, accountID: UUID(), storeURL: url)
        for chunk in manifest.chunks {
            try await importer.importChunk(Data(contentsOf: root.appending(path: "checkpoint/" + String(format: "%05d.json.gz", chunk.index))), index: chunk.index)
        }
        try await importer.finish()
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "tail-events.json"))) as? [[String: Any]])
        let events = try raw.map { try event($0, manifest: manifest) }
        for start in stride(from: 0, to: events.count, by: 100) {
            let end = min(start + 100, events.count)
            try await importer.applyRecentPage(.init(events: Array(events[start..<end]), cloudHead: events.last!.eventSequence, hasMore: end < events.count))
        }
        let head = try await importer.currentHead()
        XCTAssertEqual(head, events.last?.eventSequence ?? manifest.boundaryEventSequence)
        let container = try AppSchema.makeContainer(url: url)
        try await verifyPages(container: container, root: root, destination: destination,
                              migrationSeconds: Date.now.timeIntervalSince(started), started: started, reportName: "cloud-native-acceptance")
    }

    private func event(_ row: [String: Any], manifest: ESheepCloudCheckpointManifest) throws -> ESheepCloudEventEnvelopeV2 {
        func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
            try ESheepCloudCanonicalCodec.decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
        }
        let body = try XCTUnwrap(row["event_body"] as? [String: Any])
        let stream = ESheepCloudStreamReferenceV2(type: try decode(row["stream_type"]!), id: try decode(row["stream_id"]!))
        let payload: ESheepCloudEventPayloadV2
        if row["event_kind"] as? String == ESheepCloudEventKindV2.fieldPatch {
            let changes = try XCTUnwrap(body["changes"] as? [[String: Any]])
            payload = .fieldsPatched(stream: stream, changes: try changes.map { value in
                ESheepCloudAppliedFieldChangeV2(field: try decode(value["field"]!), value: try decode(value["value"]!), valueDigest: try decode(value["value_digest"]!), fieldVersion: try decode(value["field_version"]!))
            })
        } else {
            let kind: String = try decode(body["command_kind"]!)
            let command: ESheepCloudCommandPayloadV2 = try decode(body["command_payload"]!)
            XCTAssertEqual(command.kind, kind)
            payload = .businessCommandApplied(commandKind: kind, payload: command)
        }
        let canonical: String = try decode(row["event_body_canonical"]!)
        let bodyDigest: String = try decode(row["event_body_digest"]!)
        try ESheepCloudEventBodyIntegrityV2.validate(canonicalJSON: canonical, expectedDigest: bodyDigest)
        return ESheepCloudEventEnvelopeV2(protocolVersion: ESheepCloudProtocolV2.protocolVersion, schemaVersion: ESheepCloudProtocolV2.schemaVersion,
            farmID: manifest.farmID, farmGeneration: manifest.farmGeneration,
            eventSequence: try decode(row["event_sequence"]!), eventID: try decode(row["event_id"]!), commandID: try decode(row["command_id"]!), sourceCommandDigest: try decode(row["source_command_digest"]!), stream: stream, payload: payload,
            affectedFields: try decode(row["affected_fields"]!), eventBodyDigest: bodyDigest, beforeDigest: try decode(row["before_digest"]!), afterDigest: try decode(row["after_digest"]!), actorAccountID: try decode(row["actor_account_id"]!), sourceDeviceID: try decode(row["source_device_id"]!), sourceDeviceSequence: try decode(row["source_device_sequence"]!), occurredAt: try decode(row["occurred_at_millis"]!), receivedAt: try decode(row["received_at_millis"]!), eventDigest: try decode(row["event_digest"]!), eventBodyCanonical: canonical)
    }

}
