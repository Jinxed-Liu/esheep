import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import eSheepNext

@MainActor
final class InsightAssistantTests: XCTestCase {
    func testCredentialPrefixSelectsOfficialEndpointAndMasksSecret() throws {
        let standard = try MiMoCredential(apiKey: "sk-1234567890-secret")
        let tokenPlan = try MiMoCredential(apiKey: "tp-1234567890-secret")

        XCTAssertEqual(standard.kind, .payAsYouGo)
        XCTAssertEqual(standard.responsesURL.absoluteString, "https://api.xiaomimimo.com/v1/responses")
        XCTAssertEqual(standard.chatCompletionsURL.absoluteString, "https://api.xiaomimimo.com/v1/chat/completions")
        XCTAssertEqual(tokenPlan.kind, .tokenPlan)
        XCTAssertEqual(tokenPlan.responsesURL.absoluteString, "https://token-plan-cn.xiaomimimo.com/v1/responses")
        XCTAssertFalse(standard.maskedValue.contains("1234567890"))
        XCTAssertEqual(InsightInputOrigin.text.model, "mimo-v2.5-pro")
        XCTAssertEqual(InsightInputOrigin.image.model, "mimo-v2.5")
        XCTAssertEqual(InsightInputOrigin.voiceAudio.model, "mimo-v2.5")
    }

    func testCredentialVaultPersistsAndRemovesCredentialForAccount() async throws {
        let accountID = UUID()
        try await MiMoCredentialVault.shared.remove(for: accountID)

        let saved = try await MiMoCredentialVault.shared.save(
            apiKey: "sk-1234567890-persistence",
            for: accountID
        )
        let loaded = try await MiMoCredentialVault.shared.credential(for: accountID)

        XCTAssertEqual(loaded, saved)

        try await MiMoCredentialVault.shared.remove(for: accountID)
        let removed = try await MiMoCredentialVault.shared.credential(for: accountID)
        XCTAssertNil(removed)

        let suffix = accountID.uuidString.lowercased()
        try SecureAccountStore.remove(account: "insights.mimo-api-key-deleted-at.\(suffix)")
        try SecureAccountStore.remove(account: "insights.mimo-api-key-updated-at.\(suffix)")
    }

    func testResponsesSSEParsesTextToolAndUsageWithoutReasoningText() throws {
        let delta = try XCTUnwrap(MiMoSSEParser.parse(
            line: #"data: {"type":"response.output_text.delta","delta":"当前在场 18 只。"}"#
        ))
        XCTAssertEqual(delta, .textDelta("当前在场 18 只。"))

        let tool = try XCTUnwrap(MiMoSSEParser.parse(
            line: #"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"analyze_farm","arguments":"{\"focus\":\"population\",\"year\":\"\"}"}}"#
        ))
        XCTAssertEqual(
            tool,
            .functionCall(.init(
                callID: "call_1",
                name: "analyze_farm",
                argumentsJSON: #"{"focus":"population","year":""}"#
            ))
        )

        let completed = try XCTUnwrap(MiMoSSEParser.parse(
            line: #"data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":12,"output_tokens":8,"total_tokens":20}}}"#
        ))
        XCTAssertEqual(
            completed,
            .completed(
                responseID: "resp_1",
                usage: .init(inputTokens: 12, outputTokens: 8, totalTokens: 20)
            )
        )
    }

    func testResponsesSSEPreservesIncompleteReason() throws {
        XCTAssertThrowsError(
            try MiMoSSEParser.parse(
                line: #"data: {"type":"response.incomplete","response":{"id":"resp_1","incomplete_details":{"reason":"max_output_tokens"}}}"#
            )
        ) { error in
            XCTAssertEqual(
                error as? MiMoClientError,
                .incomplete(reason: "max_output_tokens")
            )
            XCTAssertTrue(
                (error as? MiMoClientError)?.isOutputLimitIncomplete == true
            )
        }
    }

    func testOfficialMiMoUsageParsesBalanceAndTokenPlan() throws {
        let balance = Data("""
        {"code":0,"data":{"balance":"25.51","currency":"USD","cashBalance":"20","giftBalance":"5.51"}}
        """.utf8)
        let detail = Data("""
        {"code":0,"data":{"planCode":"standard","currentPeriodEnd":"2026-08-01 00:00:00","expired":false}}
        """.utf8)
        let usage = Data("""
        {"code":0,"data":{"monthUsage":{"items":[{"used":10100158,"limit":200000000}]}}}
        """.utf8)

        let snapshot = try MiMoOfficialUsageService.parse(
            balanceData: balance,
            detailData: detail,
            usageData: usage,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(snapshot.balance, Decimal(string: "25.51"))
        XCTAssertEqual(snapshot.cashBalance, Decimal(20))
        XCTAssertEqual(snapshot.giftBalance, Decimal(string: "5.51"))
        XCTAssertEqual(snapshot.planCode, "standard")
        XCTAssertEqual(snapshot.tokenUsed, 10_100_158)
        XCTAssertEqual(snapshot.tokenLimit, 200_000_000)
        XCTAssertEqual(snapshot.tokenRemaining, 189_899_842)
        XCTAssertNotNil(snapshot.planPeriodEnd)
    }

    func testToolRegistryExposesAuthoritativeEntityLookupAndDirectExport() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-entities-export-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let otherFarmID = UUID()
        let farm = FarmRecord(
            id: farmID,
            ownerAccountID: accountID,
            name: "测试牧场"
        )
        context.insert(farm)
        context.insert(PenRecord(farmID: farmID, name: "育肥一圈"))
        context.insert(PenRecord(farmID: otherFarmID, name: "其他牧场圈舍"))
        try context.save()

        let registry = InsightToolRegistry()
        let farmContext = FarmContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner
        )
        let definitions = registry.definitions(for: farmContext)
        XCTAssertTrue(definitions.contains { $0.name == "get_farm_entities" })
        XCTAssertTrue(definitions.contains { $0.name == "create_farm_export" })

        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let entities = try registry.execute(
            .init(
                callID: "entities",
                name: "get_farm_entities",
                argumentsJSON: #"{"category":"pens","query":"","limit":50}"#
            ),
            agent: agent,
            context: context
        )
        XCTAssertTrue(entities.output.contains("育肥一圈"))
        XCTAssertFalse(entities.output.contains("其他牧场圈舍"))

        let export = try registry.execute(
            .init(
                callID: "export",
                name: "create_farm_export",
                argumentsJSON: #"{"format":"xlsx"}"#
            ),
            agent: agent,
            context: context
        )
        XCTAssertEqual(export.generatedFile?.kind, .xlsx)
        XCTAssertTrue(export.generatedFile?.fileName.hasSuffix(".xlsx") == true)
        XCTAssertFalse(export.generatedFile?.data.isEmpty ?? true)
        XCTAssertTrue(export.output.contains(#""status":"file_generated""#))
    }

    func testImportFileCreatesHighRiskConfirmationDraftWithoutWriting() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-import-preview-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farm = FarmRecord(
            ownerAccountID: accountID,
            name: "导入测试牧场"
        )
        context.insert(farm)
        try context.save()
        let csv = Data("""
        耳号,品种,性别,圈舍,入场日期,出生日期,备注
        QA022,湖羊,母羊,,2026-07-22,,AI导入
        """.utf8)
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farm.id,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )

        let draft = try InsightImportCoordinator.prepare(
            fileName: "羊只.csv",
            fileExtension: "csv",
            data: csv,
            agent: agent,
            farm: farm,
            context: context
        )
        let payload = try InsightImportCoordinator.payload(for: draft)

        XCTAssertEqual(draft.toolName, InsightImportCoordinator.toolName)
        XCTAssertEqual(draft.risk, .high)
        XCTAssertEqual(draft.status, .proposed)
        XCTAssertEqual(payload.acceptedCount, 1)
        XCTAssertEqual(payload.errorCount, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SheepRecord>()).isEmpty)
    }

    func testConfirmedImportUsesExistingAtomicImportService() async throws {
        let container = try AppSchema.makeContainer(
            name: "insight-import-execute-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let account = AccountProfile(
            appleUserIdentifier: "insight-import-\(UUID().uuidString)",
            displayName: "导入测试"
        )
        let farm = FarmRecord(
            ownerAccountID: account.effectiveAccountID,
            name: "导入执行牧场"
        )
        context.insert(account)
        context.insert(farm)
        try context.save()
        let csv = Data("""
        耳号,品种,性别,圈舍,入场日期,出生日期,备注
        QA022,湖羊,母羊,,2026-07-22,,AI导入
        """.utf8)
        let agent = InsightAgentContext(
            accountID: account.effectiveAccountID,
            farmID: farm.id,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let draft = try InsightImportCoordinator.prepare(
            fileName: "羊只.csv",
            fileExtension: "csv",
            data: csv,
            agent: agent,
            farm: farm,
            context: context
        )
        try await InsightLocalImportStore.shared.save(
            data: csv,
            accountID: account.effectiveAccountID,
            draftID: draft.id
        )

        _ = try await InsightImportCoordinator.execute(
            draft,
            account: account,
            farm: farm,
            context: context
        )

        let imported = try context.fetch(FetchDescriptor<SheepRecord>())
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.earTag, "QA022")
        XCTAssertFalse(imported.first?.earTag.contains("-") ?? true)
        XCTAssertFalse(try context.fetch(FetchDescriptor<DomainOperation>()).isEmpty)
    }

    func testToolRegistryIsFarmScopedAndAnalyticsRequiresCapability() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-tools-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let firstFarmID = UUID()
        let secondFarmID = UUID()
        context.insert(SheepRecord(
            farmID: firstFarmID,
            earTag: "A-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        ))
        context.insert(SheepRecord(
            farmID: secondFarmID,
            earTag: "B-001",
            breed: "杜泊",
            sex: .ram,
            penID: nil,
            enteredAt: .now
        ))
        try context.save()

        let registry = InsightToolRegistry()
        let worker = FarmContext(accountID: accountID, farmID: firstFarmID, role: .worker)
        XCTAssertFalse(registry.definitions(for: worker).contains(where: { $0.name == "analyze_farm" }))
        let owner = FarmContext(accountID: accountID, farmID: firstFarmID, role: .owner)
        XCTAssertTrue(registry.definitions(for: owner).contains(where: { $0.name == "analyze_farm" }))

        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: firstFarmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(callID: "find", name: "find_sheep", argumentsJSON: #"{"query":"001"}"#),
            agent: agent,
            context: context
        )
        XCTAssertTrue(result.output.contains("A-001"))
        XCTAssertFalse(result.output.contains("B-001"))
    }

    func testAssistantInstructionsUseCurrentCalendarYearAndLocalTimeZone() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-07-25T06:50:00Z"))
        let timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        let instructions = InsightConversationController.instructions(
            farmName: "测试牧场",
            now: now,
            timeZone: timeZone
        )

        XCTAssertTrue(instructions.contains("2026-07-25 14:50"))
        XCTAssertTrue(instructions.contains("公历年份是 2026"))
        XCTAssertTrue(instructions.contains("默认使用当前公历年份 2026"))
        XCTAssertTrue(instructions.contains("UTC+08:00"))
        XCTAssertTrue(instructions.contains("多个称重必须一次调用 draft_record_weights"))
        XCTAssertTrue(instructions.contains("必须一次调用 draft_sell_sheep_batch"))
        XCTAssertTrue(instructions.contains("绝不表示已经提交、保存或执行"))
        XCTAssertTrue(instructions.contains("AI 智能牧场助手"))
        XCTAssertFalse(instructions.contains("MiMo 智能牧场助手"))
    }

    func testConversationRequestKeepsMessagesBeyondLegacySixteenMessageLimit() {
        let messages = (0..<24).map {
            MiMoInputMessage(role: .user, text: "消息 \($0)")
        }

        let request = MiMoConversationRequest(
            instructions: "测试",
            messages: messages
        )

        XCTAssertEqual(request.messages, messages)
    }

    func testContextCompressorWaitsFor512KThreshold() {
        let messages = [
            MiMoInputMessage(
                role: .user,
                text: String(repeating: "羊", count: 32_000)
            ),
        ]

        let preparation = InsightContextCompressor.prepare(
            messages: messages,
            additionalEstimatedTokens: 8_192
        )

        XCTAssertFalse(preparation.didCompress)
        XCTAssertEqual(preparation.messages, messages)
        XCTAssertLessThan(
            preparation.originalEstimatedTokens,
            InsightContextCompressor.compressionThresholdTokens
        )
    }

    func testContextCompressorSummarizesOlderMessagesAt512KAndKeepsLatest() {
        let messages = (0..<600).map { index in
            MiMoInputMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "消息 \(index) " + String(repeating: "羊", count: 1_000)
            )
        }

        let preparation = InsightContextCompressor.prepare(
            messages: messages,
            additionalEstimatedTokens: 12_000
        )

        XCTAssertTrue(preparation.didCompress)
        XCTAssertGreaterThan(preparation.compressedMessageCount, 0)
        XCTAssertEqual(preparation.messages.first?.role, .system)
        XCTAssertTrue(preparation.messages.first?.text.contains("512K") == true)
        XCTAssertTrue(preparation.messages.last?.text.contains("消息 599") == true)
        XCTAssertLessThan(
            preparation.preparedEstimatedTokens,
            InsightContextCompressor.compressionThresholdTokens
        )
    }

    func testContextWindowUsageClampsCircularPercentage() {
        let usage = InsightContextWindowUsage(
            estimatedTokens: 600 * 1_024,
            limitTokens: 512 * 1_024,
            lastCompressedAt: nil
        )

        XCTAssertEqual(usage.fraction, 1)
        XCTAssertEqual(usage.percentage, 100)
    }

    func testBatchWeightToolCreatesAllPendingDraftsInOneCall() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-weight-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let first = SheepRecord(
            farmID: farmID,
            earTag: "A001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let second = SheepRecord(
            farmID: farmID,
            earTag: "A002",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        let registry = InsightToolRegistry()
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        XCTAssertTrue(
            registry.definitions(for: farm).contains(where: {
                $0.name == "draft_record_weights"
            })
        )
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "batch-weights",
                name: "draft_record_weights",
                argumentsJSON: """
                {
                  "occurred_at": "2026-07-22T00:00:00+08:00",
                  "note": "",
                  "items": [
                    {"ear_tag": "A001", "kilograms": "52.0"},
                    {"ear_tag": "A002", "kilograms": "51.5"}
                  ]
                }
                """
            ),
            agent: agent,
            context: context
        )

        XCTAssertEqual(result.actionDrafts.count, 2)
        XCTAssertTrue(result.actionDrafts.allSatisfy { $0.status == .proposed })
        XCTAssertTrue(result.output.contains(#""proposal_count":2"#))
        XCTAssertTrue(result.output.contains(#""executed_count":0"#))
        XCTAssertEqual(result.actionDrafts.map(\.summary), [
            "A001 · 52.0 kg",
            "A002 · 51.5 kg",
        ])
        let occurredAt = try XCTUnwrap(
            registry.occurredAt(for: result.actionDrafts[0])
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: occurredAt
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 22)
    }

    func testBatchSaleToolCreatesFifteenPendingDraftsWithSharedTotal() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-sale-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let earTags = (1...15).map { String(format: "SALE%03d", $0) }
        for earTag in earTags {
            context.insert(SheepRecord(
                farmID: farmID,
                earTag: earTag,
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now.addingTimeInterval(-86_400)
            ))
        }
        try context.save()

        let registry = InsightToolRegistry()
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        XCTAssertTrue(
            registry.definitions(for: farm).contains(where: {
                $0.name == "draft_sell_sheep_batch"
            })
        )
        let earTagsJSON = try XCTUnwrap(
            String(
                data: JSONSerialization.data(withJSONObject: earTags),
                encoding: .utf8
            )
        )
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try registry.execute(
            .init(
                callID: "batch-sale",
                name: "draft_sell_sheep_batch",
                argumentsJSON: """
                {
                  "occurred_at": "2026-07-22T08:00:00+08:00",
                  "total_amount": "17100",
                  "note": "",
                  "ear_tags": \(earTagsJSON)
                }
                """
            ),
            agent: agent,
            context: context
        )

        XCTAssertEqual(result.actionDrafts.count, 15)
        XCTAssertTrue(result.actionDrafts.allSatisfy {
            $0.status == .proposed &&
                $0.toolName == "draft_farm_command" &&
                $0.summary.contains("总价 ¥17100")
        })
        XCTAssertTrue(result.output.contains(#""proposal_count":15"#))
        XCTAssertTrue(result.output.contains(#""executed_count":0"#))

        var batchIDs = Set<UUID>()
        var draftedSheepIDs = Set<UUID>()
        let commandDecoder = JSONDecoder()
        commandDecoder.dateDecodingStrategy = .iso8601
        for draft in result.actionDrafts {
            let wrapper = try JSONDecoder().decode(
                CanonicalFarmCommandToolPayload.self,
                from: draft.argumentsJSON
            )
            let payload = try commandDecoder.decode(
                FarmCommandCloudPayload.self,
                from: wrapper.commandPayload
            )
            let command = try FarmCommandCloudPayloadDecoder.decode(payload)
            guard case .removeSheep(
                let sheepID,
                let kind,
                let reason,
                let amountText,
                let occurredAt,
                _,
                _,
                let removalBatchID,
                let batchTotalAmountText
            ) = command else {
                return XCTFail("Expected removeSheep command")
            }
            draftedSheepIDs.insert(sheepID)
            XCTAssertEqual(kind, .sold)
            XCTAssertEqual(reason, "出售")
            XCTAssertNil(amountText)
            XCTAssertEqual(batchTotalAmountText, "17100")
            batchIDs.insert(try XCTUnwrap(removalBatchID))

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: occurredAt
            )
            XCTAssertEqual(components.year, 2026)
            XCTAssertEqual(components.month, 7)
            XCTAssertEqual(components.day, 22)
        }
        XCTAssertEqual(batchIDs.count, 1)
        XCTAssertEqual(draftedSheepIDs.count, 15)
        XCTAssertTrue(result.actionDrafts.allSatisfy {
            registry.removalBatchID(for: $0) == batchIDs.first
        })
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<RemovalRecord>()).isEmpty,
            "Draft creation must not write removal records before confirmation."
        )
    }

    func testBatchDraftExecutionCommitsAllReceiptsOnce() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-execution-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let batchID = UUID()
        let sheep = ["SALE001", "SALE002"].map {
            SheepRecord(
                farmID: farmID,
                earTag: $0,
                breed: "湖羊",
                sex: .ewe,
                penID: nil,
                enteredAt: .now.addingTimeInterval(-86_400)
            )
        }
        sheep.forEach(context.insert)
        try context.save()

        let sourceRequestIDs = [UUID(), UUID()]
        let occurredAt = Date.now
        let requests = zip(sheep, sourceRequestIDs).map { item, sourceRequestID in
            (
                command: FarmCommand.removeSheep(
                    sheepID: item.id,
                    kind: .sold,
                    reason: "出售",
                    amountText: nil,
                    occurredAt: occurredAt,
                    note: "",
                    removalBatchID: batchID,
                    batchTotalAmountText: "17100"
                ),
                sourceRequestID: sourceRequestID
            )
        }
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        let service = FarmCommandService()

        let first = try service.executeBatch(requests, in: farm, context: context)
        let second = try service.executeBatch(requests, in: farm, context: context)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.sourceRequestID), sourceRequestIDs)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RemovalRecord>()).count, 2)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<DomainOperation>()).filter {
                sourceRequestIDs.contains($0.sourceRequestID ?? UUID())
            }.count,
            2
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).filter {
                sourceRequestIDs.contains($0.sourceRequestID)
            }.count,
            2
        )
    }

    func testBatchDraftExecutionRollsBackEveryWriteWhenOneCommandFails() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-batch-rollback-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "SALE001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now.addingTimeInterval(-86_400)
        )
        context.insert(sheep)
        try context.save()

        let batchID = UUID()
        let requests = [
            (
                command: FarmCommand.removeSheep(
                    sheepID: sheep.id,
                    kind: .sold,
                    reason: "出售",
                    amountText: nil,
                    occurredAt: .now,
                    note: "",
                    removalBatchID: batchID,
                    batchTotalAmountText: "17100"
                ),
                sourceRequestID: UUID()
            ),
            (
                command: FarmCommand.removeSheep(
                    sheepID: UUID(),
                    kind: .sold,
                    reason: "出售",
                    amountText: nil,
                    occurredAt: .now,
                    note: "",
                    removalBatchID: batchID,
                    batchTotalAmountText: "17100"
                ),
                sourceRequestID: UUID()
            ),
        ]

        XCTAssertThrowsError(
            try FarmCommandService().executeBatch(
                requests,
                in: FarmContext(accountID: accountID, farmID: farmID, role: .owner),
                context: context
            )
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<RemovalRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DomainOperation>()).isEmpty)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).isEmpty
        )
    }

    func testDraftExecutionIsIdempotentBySourceRequestID() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-idempotency-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let sheep = SheepRecord(
            farmID: farmID,
            earTag: "W-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        context.insert(sheep)
        try context.save()

        let sourceRequestID = UUID()
        let command = FarmCommand.recordWeight(
            sheepID: sheep.id,
            kilogramsText: "42.5",
            occurredAt: .now,
            note: "AI 草案"
        )
        let farm = FarmContext(accountID: accountID, farmID: farmID, role: .owner)
        let service = FarmCommandService()
        let first = try service.execute(
            command,
            in: farm,
            context: context,
            sourceRequestID: sourceRequestID
        )
        let second = try service.execute(
            command,
            in: farm,
            context: context,
            sourceRequestID: sourceRequestID
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WeightRecord>()).count, 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<DomainOperation>()).filter {
                $0.sourceRequestID == sourceRequestID
            }.count,
            1
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<InsightExecutionReceiptRecord>()).filter {
                $0.sourceRequestID == sourceRequestID
            }.count,
            1
        )
    }

    func testCanonicalFarmCommandCodecCoversEveryAuthorizedCommandCase() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<40).map { _ in UUID() }
        let healthDraft = CareHealthDraft(
            id: ids[20],
            batchID: ids[21],
            subjectIDs: [ids[0]],
            penID: ids[1],
            catalogItemID: ids[22],
            kind: .treatment,
            itemName: "青霉素",
            occurredAt: now,
            note: "测试",
            inventoryLotID: ids[23],
            dosePerSubjectText: "1",
            unit: "支",
            route: "肌注",
            reminderAt: now.addingTimeInterval(86_400)
        )
        let reproductionDraft = CareReproductionBatchDraft(
            id: ids[24],
            kind: .breeding,
            subjects: [.init(
                id: ids[25],
                eweID: ids[0],
                result: "完成",
                relatedBreedingRecordID: ids[26]
            )],
            occurredAt: now,
            sireID: ids[2],
            semenID: ids[27],
            semenUnitsPerEweText: "1",
            note: "测试",
            reminderAt: nil
        )
        let lambingDraft = CareLambingDraft(
            id: ids[28],
            eweID: ids[0],
            occurredAt: now,
            sireID: ids[2],
            semenID: nil,
            relatedBreedingRecordID: ids[26],
            parity: 2,
            birthDeadCount: 0,
            offspring: [.init(
                id: ids[29],
                sheepID: ids[30],
                earTag: "L-001",
                sex: .ewe,
                birthWeightText: "3.5"
            )],
            penID: ids[1],
            note: "测试"
        )
        let pedigreeDraft = CarePedigreeUpdateDraft(
            id: ids[31],
            sheepID: ids[0],
            damID: ids[3],
            sireID: ids[2],
            semenDonorID: nil,
            reason: "核对档案",
            expectedRevision: 1
        )
        let donorDraft = CareSemenDonorDraft(
            id: ids[32],
            name: "供体",
            registrationNumber: "D-01",
            breed: "杜泊",
            linkedRamID: ids[2],
            note: "测试",
            status: .active,
            expectedRevision: 0
        )
        let pedigreeSnapshot = CarePedigreeAuditSnapshot(
            id: ids[33],
            sheepID: ids[0],
            beforeDamID: nil,
            afterDamID: ids[3],
            beforeSireID: nil,
            afterSireID: ids[2],
            beforeSemenDonorID: nil,
            afterSemenDonorID: nil,
            beforeDamSourceRawValue: nil,
            afterDamSourceRawValue: PedigreeRelationSource.manual.rawValue,
            beforeSireSourceRawValue: nil,
            afterSireSourceRawValue: PedigreeRelationSource.manual.rawValue,
            reason: "恢复测试",
            changedByAccountID: ids[34],
            sheepRevision: 2,
            occurredAt: now
        )
        let careCommands: [CareCommand] = [
            .upsertHealthCatalog(
                id: ids[22],
                kindRawValue: HealthRecordKind.treatment.rawValue,
                name: "青霉素",
                category: "抗生素",
                unit: "支",
                defaultDoseText: "1",
                defaultRoute: "肌注",
                reminderIntervalDays: 7,
                note: "测试",
                isActive: true
            ),
            .recordHealth(healthDraft),
            .correctHealth(originalID: ids[35], replacement: healthDraft, reason: "录入错误"),
            .receiveInventory(
                id: ids[36],
                catalogName: "青霉素",
                catalogItemID: ids[22],
                kindRawValue: HealthRecordKind.treatment.rawValue,
                batchNumber: "B-1",
                supplier: "供应商",
                unit: "支",
                expiresAt: now,
                quantityText: "10",
                occurredAt: now,
                note: "测试"
            ),
            .adjustInventory(id: ids[36], lotID: ids[23], quantityDeltaText: "-1", occurredAt: now, note: "盘点"),
            .setInventoryLotActive(lotID: ids[23], isActive: false),
            .adjustSemen(id: ids[36], semenID: ids[27], quantityDeltaText: "-1", occurredAt: now, note: "盘点"),
            .upsertSemenDonor(donorDraft),
            .setSemenDonor(semenID: ids[27], donorID: ids[32], expectedRevision: 1),
            .updateSheepPedigree(pedigreeDraft),
            .setBreedingRam(sheepID: ids[2], isBreedingRam: true, expectedRevision: 1),
            .restorePedigreeAudit(pedigreeSnapshot),
            .recordReproductionBatch(reproductionDraft),
            .recordLambing(lambingDraft),
            .correctReproduction(originalID: ids[26], replacement: reproductionDraft, reason: "日期错误"),
            .correctLambing(originalID: ids[37], replacement: lambingDraft, reason: "羔羊信息错误"),
            .revokeLambing(recordID: ids[37], reason: "重复记录"),
            .restoreLambing(recordID: ids[37]),
            .updateRules(id: ids[38], pregnancyCheckDays: 45, gestationDays: 150),
            .setReminderStatus(reminderID: ids[39], status: .completed),
        ]
        let commands: [FarmCommand] = [
            .updateFarmLocation(
                displayName: "测试牧场",
                latitude: 31.2,
                longitude: 121.5,
                addressSnapshot: "上海",
                timeZoneIdentifier: "Asia/Shanghai",
                source: .mapSearch,
                horizontalAccuracyMeters: 5
            ),
            .createPen(name: "一号圈", note: ""),
            .updatePen(penID: ids[1], name: "一号圈", note: "更新"),
            .setPenActive(penID: ids[1], isActive: false),
            .addSheep(earTag: "A-001", breed: "湖羊", sex: .ewe, penID: ids[1], occurredAt: now, birthAt: now, note: ""),
            .updateSheepProfile(sheepID: ids[0], earTag: "A-001", breed: "湖羊", sex: .ewe, birthAt: now, note: ""),
            .recordWeight(sheepID: ids[0], kilogramsText: "42.5", occurredAt: now, note: ""),
            .correctWeight(originalID: ids[4], kilogramsText: "43", occurredAt: now, note: "", reason: "录入错误"),
            .recordWeaning(sheepID: ids[0], weanWeightText: "25", occurredAt: now, birthAt: now, birthWeightText: "3.5", averageDailyGainText: "0.2", damID: ids[3], litterSize: 2, note: ""),
            .createBreedingProgram(name: "同期发情", createdAt: now, steps: [.init(id: ids[5], dayOffset: 0, action: "开始")]),
            .transferSheep(sheepID: ids[0], toPenID: ids[1], occurredAt: now, note: ""),
            .correctTransfer(originalID: ids[6], toPenID: ids[1], occurredAt: now, note: "", reason: "圈舍错误"),
            .removeSheep(sheepID: ids[0], kind: .sold, reason: "出售", amountText: "1000", occurredAt: now, note: ""),
            .correctRemoval(originalID: ids[7], kind: .culled, reason: "淘汰", amountText: nil, occurredAt: now, note: "", correctionReason: "类型错误"),
            .restoreSheep(removalID: ids[7]),
            .createBatch(name: "育肥批次", purpose: "育肥", startedAt: now, sheepIDs: [ids[0]], note: ""),
            .assignSheepToBatch(batchID: ids[8], sheepID: ids[0], joinedAt: now),
            .leaveBatch(batchID: ids[8], sheepID: ids[0], leftAt: now, reason: "完成"),
            .addIngredient(name: "玉米", unit: "kg", dryMatterText: "0.88"),
            .createRecipe(name: "育肥料", note: ""),
            .addRecipeComponent(recipeID: ids[9], ingredientID: ids[10], kilogramsText: "5"),
            .recordFeed(penID: ids[1], recipeID: ids[9], mode: .limited, occurredAt: now, lines: [.init(id: ids[11], ingredientID: ids[10], kilogramsText: "5")], note: ""),
            .recordHealth(sheepID: ids[0], penID: nil, kind: .treatment, itemName: "青霉素", occurredAt: now, note: "", inventoryLotID: ids[23], quantityText: "1"),
            .receiveInventory(catalogName: "青霉素", kind: .treatment, expiresAt: now, quantityText: "10", occurredAt: now, note: ""),
            .addSemen(code: "S-001", breed: "杜泊", source: "供应商", batchNumber: "B-1", quantityText: "10"),
            .recordReproduction(eweID: ids[0], kind: .lambing, occurredAt: now, sireID: ids[2], semenName: nil, result: "完成", lambCount: 1, parity: 2, birthDeadCount: 0, offspring: [.init(id: ids[12], sheepID: ids[13], earTag: "L-001", sex: .female, birthWeightText: "3.5")], note: ""),
            .addNote(sheepID: ids[0], penID: nil, text: "观察", occurredAt: now),
            .tombstoneEntity(entityType: .weight, entityID: ids[4], reason: "重复"),
            .restoreTombstonedEntity(tombstoneID: ids[14]),
        ] + careCommands.map(FarmCommand.care)

        XCTAssertEqual(commands.count, 49)
        for (index, command) in commands.enumerated() {
            let encoded = try FarmCommandCloudPayloadEncoder.encode(command)
            let decoded = try FarmCommandCloudPayloadDecoder.decode(encoded)
            XCTAssertEqual(
                try FarmCommandCloudPayloadEncoder.encode(decoded),
                encoded,
                "Codec mismatch at command index \(index): \(command.summary)"
            )
        }
    }

    func testCareActionSchemaDescribesEveryCareCommandCase() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-care-schema-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let agent = InsightAgentContext(
            accountID: UUID(),
            farmID: UUID(),
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let result = try InsightToolRegistry().execute(
            .init(
                callID: "care-schema",
                name: "get_farm_action_schema",
                argumentsJSON: #"{"operation_kind":"care"}"#
            ),
            agent: agent,
            context: context
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        let payloadRoot = try XCTUnwrap(root["payload_root"] as? [String: Any])
        let careCommand = try XCTUnwrap(payloadRoot["careCommand"] as? [String: Any])
        let cases = try XCTUnwrap(careCommand["cases"] as? [String: Any])

        XCTAssertEqual(cases.count, 20)
        XCTAssertNotNil(cases["recordHealth"])
        XCTAssertNotNil(cases["recordLambing"])
        XCTAssertNotNil(cases["setReminderStatus"])
    }

    func testGenericFarmDraftDerivesHighRiskPolicyAndRejectsCrossFarmReference() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-generic-draft-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let firstFarmID = UUID()
        let secondFarmID = UUID()
        let firstSheep = SheepRecord(
            farmID: firstFarmID,
            earTag: "A-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let secondSheep = SheepRecord(
            farmID: secondFarmID,
            earTag: "B-001",
            breed: "湖羊",
            sex: .ewe,
            penID: nil,
            enteredAt: .now
        )
        let firstWeight = WeightRecord(
            farmID: firstFarmID,
            sheepID: firstSheep.id,
            kilogramsText: "40",
            occurredAt: .now
        )
        let secondWeight = WeightRecord(
            farmID: secondFarmID,
            sheepID: secondSheep.id,
            kilogramsText: "41",
            occurredAt: .now
        )
        [firstSheep, secondSheep].forEach(context.insert)
        [firstWeight, secondWeight].forEach(context.insert)
        try context.save()

        let registry = InsightToolRegistry()
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: firstFarmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let command = FarmCommand.correctWeight(
            originalID: firstWeight.id,
            kilogramsText: "42",
            occurredAt: .now,
            note: "",
            reason: "录入错误"
        )
        let payloadText = String(decoding: try FarmCommandCloudPayloadEncoder.encode(command), as: UTF8.self)
        let callData = try JSONSerialization.data(withJSONObject: [
            "operation_kind": DomainOperationKind.correctWeight.rawValue,
            "payload_json": payloadText,
        ])
        let execution = try registry.execute(
            .init(
                callID: "draft",
                name: "draft_farm_command",
                argumentsJSON: String(decoding: callData, as: UTF8.self)
            ),
            agent: agent,
            context: context
        )
        let draft = try XCTUnwrap(execution.actionDraft)
        XCTAssertEqual(draft.risk, .high)
        XCTAssertEqual(draft.requiredCapability, .editHistoricalFacts)
        XCTAssertEqual(draft.expectedEntityID, firstWeight.id)
        XCTAssertEqual(draft.expectedRevision, firstWeight.revision)

        draft.riskRawValue = InsightActionRisk.normal.rawValue
        XCTAssertThrowsError(try registry.validate(draft, agent: agent, context: context))

        let crossFarmCommand = FarmCommand.correctWeight(
            originalID: secondWeight.id,
            kilogramsText: "43",
            occurredAt: .now,
            note: "",
            reason: "恶意跨场"
        )
        let crossFarmPayload = String(
            decoding: try FarmCommandCloudPayloadEncoder.encode(crossFarmCommand),
            as: UTF8.self
        )
        let crossFarmCall = try JSONSerialization.data(withJSONObject: [
            "operation_kind": DomainOperationKind.correctWeight.rawValue,
            "payload_json": crossFarmPayload,
        ])
        XCTAssertThrowsError(try registry.execute(
            .init(
                callID: "cross-farm",
                name: "draft_farm_command",
                argumentsJSON: String(decoding: crossFarmCall, as: UTF8.self)
            ),
            agent: agent,
            context: context
        )) { error in
            guard let insightError = error as? InsightToolError,
                  case .crossFarmReference = insightError else {
                return XCTFail("Expected crossFarmReference, got \(error)")
            }
        }
    }

    func testExtendedFarmRecordsRequireSingleCallDisclosureAndRemainFarmScoped() throws {
        let container = try AppSchema.makeContainer(
            name: "insight-extended-data-\(UUID().uuidString)",
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let accountID = UUID()
        let farmID = UUID()
        let otherFarmID = UUID()
        context.insert(NoteRecord(
            farmID: farmID,
            text: "当前牧场私密备注",
            occurredAt: .now
        ))
        context.insert(NoteRecord(
            farmID: otherFarmID,
            text: "其他牧场备注",
            occurredAt: .now
        ))
        try context.save()
        let registry = InsightToolRegistry()
        let agent = InsightAgentContext(
            accountID: accountID,
            farmID: farmID,
            role: .owner,
            originDeviceID: UUID(),
            conversationID: UUID()
        )
        let from = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-86_400))
        let to = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(86_400))
        let arguments = #"{"category":"raw_notes","from":"\#(from)","to":"\#(to)","limit":10}"#
        let call = InsightFunctionCall(
            callID: "extended",
            name: "get_extended_farm_records",
            argumentsJSON: arguments
        )

        let disclosure = try XCTUnwrap(registry.extendedDataDisclosure(
            for: call,
            agent: agent,
            context: context
        ))
        XCTAssertEqual(disclosure.rowCount, 1)
        XCTAssertThrowsError(try registry.execute(call, agent: agent, context: context)) { error in
            guard let insightError = error as? InsightToolError,
                  case .extendedDataConsentRequired = insightError else {
                return XCTFail("Expected extendedDataConsentRequired, got \(error)")
            }
        }
        let result = try registry.execute(
            call,
            agent: agent,
            context: context,
            extendedDataAuthorized: true
        )
        XCTAssertTrue(result.output.contains("当前牧场私密备注"))
        XCTAssertFalse(result.output.contains("其他牧场备注"))
    }

    func testImageOptimizationRemovesGPSMetadata() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let sourceData = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            sourceData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2,
                kCGImagePropertyGPSLongitude: 121.5,
            ],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let optimized = try InsightImageOptimizer.optimize(sourceData as Data)
        let optimizedSource = try XCTUnwrap(CGImageSourceCreateWithData(
            optimized.data as CFData,
            nil
        ))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(optimizedSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertLessThanOrEqual(max(optimized.pixelWidth, optimized.pixelHeight), 1_600)
    }

    func testVoiceRetentionPreferenceDefaultsOnAndIsAccountScoped() throws {
        let suiteName = "insight-voice-privacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstAccountID = UUID()
        let secondAccountID = UUID()

        XCTAssertTrue(InsightVoicePrivacyPreference.retainsSentAudio(
            for: firstAccountID,
            defaults: defaults
        ))
        InsightVoicePrivacyPreference.setRetainsSentAudio(
            false,
            for: firstAccountID,
            defaults: defaults
        )

        XCTAssertFalse(InsightVoicePrivacyPreference.retainsSentAudio(
            for: firstAccountID,
            defaults: defaults
        ))
        XCTAssertTrue(InsightVoicePrivacyPreference.retainsSentAudio(
            for: secondAccountID,
            defaults: defaults
        ))
    }

    func testLocalVoiceStoreRoundTripsAndRemovesConversation() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "insight-audio-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let store = InsightLocalAudioStore(rootDirectory: rootDirectory)
        let accountID = UUID()
        let conversationID = UUID()
        let messageID = UUID()
        let audio = PendingInsightAudio(
            data: Data([0, 1, 2, 3, 4, 5]),
            mimeType: "audio/mp4",
            duration: 2.4,
            waveformSamples: [0.1, 0.5, 0.9]
        )

        try await store.save(
            audio,
            messageID: messageID,
            conversationID: conversationID,
            accountID: accountID
        )
        let loaded = try await store.load(
            messageID: messageID,
            conversationID: conversationID,
            accountID: accountID
        )

        XCTAssertEqual(loaded?.messageID, messageID)
        XCTAssertEqual(loaded?.pendingAudio, audio)

        try await store.removeConversation(
            conversationID: conversationID,
            accountID: accountID
        )
        let removed = try await store.load(
            messageID: messageID,
            conversationID: conversationID,
            accountID: accountID
        )
        XCTAssertNil(removed)
    }
}
