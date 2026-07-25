import CryptoKit
import Foundation
import SwiftData

enum InsightImportKind: String, Codable, Sendable {
    case fullExcel
    case legacyArchive
    case fullBackup
}

struct InsightImportDraftPayload: Codable, Sendable, Equatable {
    let kind: InsightImportKind
    let fileName: String
    let fileExtension: String
    let digest: String
    let byteCount: Int
    let acceptedCount: Int
    let warningCount: Int
    let errorCount: Int
    let sections: [String]
}

@MainActor
enum InsightImportCoordinator {
    static let toolName = "draft_import_file"

    static func prepare(
        fileName: String,
        fileExtension: String,
        data: Data,
        agent: InsightAgentContext,
        farm: FarmRecord,
        context: ModelContext
    ) throws -> InsightActionDraftRecord {
        guard agent.farmID == farm.id,
              agent.farmContext.capabilities.allows(.recordProduction) else {
            throw InsightToolError.permissionDenied
        }
        let payload = try previewPayload(
            fileName: fileName,
            fileExtension: fileExtension,
            data: data,
            farm: farm,
            context: context
        )
        guard payload.acceptedCount > 0, payload.errorCount == 0 else {
            throw FarmDataInterchangeError.malformedFile(
                payload.errorCount > 0
                    ? "预检发现 \(payload.errorCount) 个阻断错误，未生成执行卡片。"
                    : "文件中没有可导入的数据。"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let summary = ([
            payload.fileName,
            "\(payload.acceptedCount) 条待写入",
            payload.warningCount > 0 ? "\(payload.warningCount) 条提醒" : nil,
        ] as [String?])
            .compactMap(\.self)
            .joined(separator: " · ")
        return InsightActionDraftRecord(
            conversationID: agent.conversationID,
            accountID: agent.accountID,
            farmID: agent.farmID,
            originDeviceID: agent.originDeviceID,
            toolName: toolName,
            title: payload.kind == .fullBackup ? "恢复完整备份" : "导入牧场数据",
            summary: summary,
            argumentsJSON: try encoder.encode(payload),
            risk: .high,
            requiredCapability: .recordProduction
        )
    }

    static func execute(
        _ draft: InsightActionDraftRecord,
        account: AccountProfile,
        farm: FarmRecord,
        context: ModelContext
    ) async throws -> UUID {
        let payload = try JSONDecoder().decode(
            InsightImportDraftPayload.self,
            from: draft.argumentsJSON
        )
        let data = try await InsightLocalImportStore.shared.load(
            accountID: account.effectiveAccountID,
            draftID: draft.id
        )
        guard digest(data) == payload.digest, data.count == payload.byteCount else {
            throw InsightToolError.staleRevision
        }

        switch payload.kind {
        case .fullExcel:
            let preview = try FarmExcelImportService.preview(
                data: data,
                farm: farm,
                context: context
            )
            guard preview.canCommit,
                  preview.expandedRecordCount == payload.acceptedCount else {
                throw InsightToolError.staleRevision
            }
            _ = try FarmExcelImportService.commit(
                preview,
                account: account,
                farm: farm,
                context: context
            )
        case .legacyArchive:
            let existingTags = Set(
                try context.fetch(FetchDescriptor<SheepRecord>())
                    .filter { $0.farmID == farm.id && $0.deletedAt == nil }
                    .map(\.earTag)
            )
            let preview = try FarmDataInterchange.preview(
                data: data,
                fileExtension: payload.fileExtension,
                existingEarTags: existingTags
            )
            guard preview.acceptedRows.count == payload.acceptedCount else {
                throw InsightToolError.staleRevision
            }
            _ = try FarmImportCommitService.commit(
                preview,
                account: account,
                farm: farm,
                context: context
            )
        case .fullBackup:
            let preview = try FarmLocalBackupService.preview(data: data)
            guard preview.entityCount == payload.acceptedCount else {
                throw InsightToolError.staleRevision
            }
            _ = try FarmLocalBackupService.restore(
                preview,
                into: farm,
                account: account,
                context: context
            )
        }

        await InsightLocalImportStore.shared.remove(
            accountID: account.effectiveAccountID,
            draftID: draft.id
        )
        return stableOperationID(digest: payload.digest)
    }

    static func payload(for draft: InsightActionDraftRecord) throws -> InsightImportDraftPayload {
        try JSONDecoder().decode(InsightImportDraftPayload.self, from: draft.argumentsJSON)
    }

    private static func previewPayload(
        fileName: String,
        fileExtension: String,
        data: Data,
        farm: FarmRecord,
        context: ModelContext
    ) throws -> InsightImportDraftPayload {
        let fileExtension = fileExtension.lowercased()
        if fileExtension == "json",
           let backup = try? FarmLocalBackupService.preview(data: data) {
            return InsightImportDraftPayload(
                kind: .fullBackup,
                fileName: fileName,
                fileExtension: fileExtension,
                digest: digest(data),
                byteCount: data.count,
                acceptedCount: backup.entityCount,
                warningCount: 0,
                errorCount: 0,
                sections: ["完整备份", backup.summary]
            )
        }

        if fileExtension == "xlsx" {
            let excel = try FarmExcelImportService.preview(
                data: data,
                farm: farm,
                context: context
            )
            if !excel.rows.isEmpty || !excel.summaries.isEmpty {
                return InsightImportDraftPayload(
                    kind: .fullExcel,
                    fileName: fileName,
                    fileExtension: fileExtension,
                    digest: digest(data),
                    byteCount: data.count,
                    acceptedCount: excel.expandedRecordCount,
                    warningCount: excel.warningCount,
                    errorCount: excel.errorCount,
                    sections: excel.summaries.map { "\($0.name) \($0.rowCount) 条" }
                )
            }
        }

        let existingTags = Set(
            try context.fetch(FetchDescriptor<SheepRecord>())
                .filter { $0.farmID == farm.id && $0.deletedAt == nil }
                .map(\.earTag)
        )
        let legacy = try FarmDataInterchange.preview(
            data: data,
            fileExtension: fileExtension,
            existingEarTags: existingTags
        )
        return InsightImportDraftPayload(
            kind: .legacyArchive,
            fileName: fileName,
            fileExtension: fileExtension,
            digest: digest(data),
            byteCount: data.count,
            acceptedCount: legacy.acceptedRows.count,
            warningCount: legacy.duplicateRowNumbers.count,
            errorCount: legacy.errorCount,
            sections: ["旧版羊只档案 \(legacy.acceptedRows.count) 条"]
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stableOperationID(digest: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(digest.utf8)))
        let tuple = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}

actor InsightLocalImportStore {
    static let shared = InsightLocalImportStore()

    func save(data: Data, accountID: UUID, draftID: UUID) throws {
        let url = try fileURL(accountID: accountID, draftID: draftID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func load(accountID: UUID, draftID: UUID) throws -> Data {
        try Data(
            contentsOf: fileURL(accountID: accountID, draftID: draftID),
            options: [.mappedIfSafe]
        )
    }

    func remove(accountID: UUID, draftID: UUID) {
        guard let url = try? fileURL(accountID: accountID, draftID: draftID) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func fileURL(accountID: UUID, draftID: UUID) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appending(path: "InsightImports", directoryHint: .isDirectory)
            .appending(path: accountID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: "\(draftID.uuidString.lowercased()).bin")
    }
}
